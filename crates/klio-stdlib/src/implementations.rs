//! Hand-written Kotlin stdlib intrinsics.
//!
//! Each entry binds a fully qualified Kotlin name to a Rust function with
//! the [`StdlibFn`](super::StdlibFn) signature. The interpreter consults
//! [`lookup`] when resolving qualified call expressions
//! (`kotlin.math.abs(-5)`), member access on builtin types
//! (`"hello".length`, `"hi".uppercase()`), and indexing
//! (`s[0]` → `kotlin.String.get`).
//!
//! Adding a new intrinsic: append the FQN + function pointer to [`TABLE`].
//! The slot is then visible to [`coverage`](super::coverage) and to the
//! interpreter at runtime.

use std::io::BufRead;
use std::rc::Rc;

use klio_runtime::{CallCtx, RuntimeError, StdlibFn, Value};

const TABLE: &[(&str, StdlibFn)] = &[
    // ----- scope functions (lambda-driven) -----
    ("kotlin.let", scope_let),
    ("kotlin.run", scope_run),
    ("kotlin.apply", scope_apply),
    ("kotlin.also", scope_also),
    ("kotlin.with", scope_with),
    ("kotlin.takeIf", scope_take_if),
    ("kotlin.takeUnless", scope_take_unless),
    ("kotlin.repeat", scope_repeat),

    // ----- io -----
    ("kotlin.io.print", io_print),
    ("kotlin.io.println", io_println),
    ("kotlin.io.readLine", io_read_line),

    // ----- math (functions) -----
    ("kotlin.math.abs", math_abs),
    ("kotlin.math.ceil", math_ceil),
    ("kotlin.math.cos", math_cos),
    ("kotlin.math.exp", math_exp),
    ("kotlin.math.floor", math_floor),
    ("kotlin.math.hypot", math_hypot),
    ("kotlin.math.ln", math_ln),
    ("kotlin.math.log", math_log),
    ("kotlin.math.log10", math_log10),
    ("kotlin.math.log2", math_log2),
    ("kotlin.math.max", math_max),
    ("kotlin.math.min", math_min),
    ("kotlin.math.round", math_round),
    ("kotlin.math.sign", math_sign),
    ("kotlin.math.sin", math_sin),
    ("kotlin.math.sqrt", math_sqrt),
    ("kotlin.math.tan", math_tan),
    ("kotlin.math.truncate", math_truncate),

    // ----- math (constants) -----
    ("kotlin.math.E", math_e),
    ("kotlin.math.PI", math_pi),

    // ----- String -----
    ("kotlin.String.compareTo", string_compare_to),
    ("kotlin.String.contains", string_contains),
    ("kotlin.String.endsWith", string_ends_with),
    ("kotlin.String.get", string_get),
    ("kotlin.String.indexOf", string_index_of),
    ("kotlin.String.isBlank", string_is_blank),
    ("kotlin.String.isEmpty", string_is_empty),
    ("kotlin.String.isNotBlank", string_is_not_blank),
    ("kotlin.String.isNotEmpty", string_is_not_empty),
    ("kotlin.String.lastIndexOf", string_last_index_of),
    ("kotlin.String.length", string_length),
    ("kotlin.String.lowercase", string_lowercase),
    ("kotlin.String.padEnd", string_pad_end),
    ("kotlin.String.padStart", string_pad_start),
    ("kotlin.String.plus", string_plus),
    ("kotlin.String.repeat", string_repeat),
    ("kotlin.String.replace", string_replace),
    ("kotlin.String.reversed", string_reversed),
    ("kotlin.String.startsWith", string_starts_with),
    ("kotlin.String.substring", string_substring),
    ("kotlin.String.chunked", string_chunked),
    ("kotlin.String.split", string_split),
    ("kotlin.String.toDouble", string_to_double),
    ("kotlin.String.toInt", string_to_int),
    ("kotlin.String.toIntOrNull", string_to_int_or_null),
    ("kotlin.String.toList", string_to_list),
    ("kotlin.String.trim", string_trim),
    ("kotlin.String.windowed", string_windowed),
    ("kotlin.String.trimEnd", string_trim_end),
    ("kotlin.String.trimStart", string_trim_start),
    ("kotlin.String.uppercase", string_uppercase),

    // ----- Char -----
    ("kotlin.Char.code", char_code),
    ("kotlin.Char.digitToInt", char_digit_to_int),
    ("kotlin.Char.isDigit", char_is_digit),
    ("kotlin.Char.isLetter", char_is_letter),
    ("kotlin.Char.isLetterOrDigit", char_is_letter_or_digit),
    ("kotlin.Char.isLowerCase", char_is_lowercase),
    ("kotlin.Char.isUpperCase", char_is_uppercase),
    ("kotlin.Char.isWhitespace", char_is_whitespace),
    ("kotlin.Char.lowercase", char_lowercase),
    ("kotlin.Char.toString", char_to_string),
    ("kotlin.Char.uppercase", char_uppercase),

    // ----- Int -----
    ("kotlin.Int.and", int_and),
    ("kotlin.Int.compareTo", int_compare_to),
    ("kotlin.Int.inv", int_inv),
    ("kotlin.Int.or", int_or),
    ("kotlin.Int.shl", int_shl),
    ("kotlin.Int.shr", int_shr),
    ("kotlin.Int.toByte", int_to_byte),
    ("kotlin.Int.toDouble", int_to_double),
    ("kotlin.Int.toFloat", int_to_float),
    ("kotlin.Int.toInt", int_to_int),
    ("kotlin.Int.toLong", int_to_long),
    ("kotlin.Int.toShort", int_to_short),
    ("kotlin.Int.toString", int_to_string),
    ("kotlin.Int.ushr", int_ushr),
    ("kotlin.Int.xor", int_xor),

    // ----- Long -----
    ("kotlin.Long.and", long_and),
    ("kotlin.Long.compareTo", long_compare_to),
    ("kotlin.Long.inv", long_inv),
    ("kotlin.Long.or", long_or),
    ("kotlin.Long.shl", long_shl),
    ("kotlin.Long.shr", long_shr),
    ("kotlin.Long.toByte", long_to_byte),
    ("kotlin.Long.toDouble", long_to_double),
    ("kotlin.Long.toFloat", long_to_float),
    ("kotlin.Long.toInt", long_to_int),
    ("kotlin.Long.toLong", long_to_long),
    ("kotlin.Long.toShort", long_to_short),
    ("kotlin.Long.toString", long_to_string),
    ("kotlin.Long.ushr", long_ushr),
    ("kotlin.Long.xor", long_xor),

    // ----- Short -----
    ("kotlin.Short.compareTo", int_compare_to),
    ("kotlin.Short.toByte", int_to_byte),
    ("kotlin.Short.toDouble", int_to_double),
    ("kotlin.Short.toFloat", int_to_float),
    ("kotlin.Short.toInt", int_to_int),
    ("kotlin.Short.toLong", int_to_long),
    ("kotlin.Short.toShort", int_to_short),
    ("kotlin.Short.toString", int_to_string),

    // ----- Byte -----
    ("kotlin.Byte.compareTo", int_compare_to),
    ("kotlin.Byte.toByte", int_to_byte),
    ("kotlin.Byte.toDouble", int_to_double),
    ("kotlin.Byte.toFloat", int_to_float),
    ("kotlin.Byte.toInt", int_to_int),
    ("kotlin.Byte.toLong", int_to_long),
    ("kotlin.Byte.toShort", int_to_short),
    ("kotlin.Byte.toString", int_to_string),

    // ----- toU* on signed integer receivers (cross-sign conversions) -----
    ("kotlin.Int.toUByte", to_ubyte),
    ("kotlin.Int.toUShort", to_ushort),
    ("kotlin.Int.toUInt", to_uint),
    ("kotlin.Int.toULong", to_ulong),
    ("kotlin.Long.toUByte", to_ubyte),
    ("kotlin.Long.toUShort", to_ushort),
    ("kotlin.Long.toUInt", to_uint),
    ("kotlin.Long.toULong", to_ulong),
    ("kotlin.Short.toUByte", to_ubyte),
    ("kotlin.Short.toUShort", to_ushort),
    ("kotlin.Short.toUInt", to_uint),
    ("kotlin.Short.toULong", to_ulong),
    ("kotlin.Byte.toUByte", to_ubyte),
    ("kotlin.Byte.toUShort", to_ushort),
    ("kotlin.Byte.toUInt", to_uint),
    ("kotlin.Byte.toULong", to_ulong),

    // ----- UInt -----
    ("kotlin.UInt.toByte", unsigned_to_byte),
    ("kotlin.UInt.toShort", unsigned_to_short),
    ("kotlin.UInt.toInt", unsigned_to_int),
    ("kotlin.UInt.toLong", unsigned_to_long),
    ("kotlin.UInt.toUByte", to_ubyte),
    ("kotlin.UInt.toUShort", to_ushort),
    ("kotlin.UInt.toUInt", to_uint),
    ("kotlin.UInt.toULong", to_ulong),
    ("kotlin.UInt.toDouble", unsigned_to_double),
    ("kotlin.UInt.toFloat", unsigned_to_float),
    ("kotlin.UInt.toString", unsigned_to_string),

    // ----- ULong -----
    ("kotlin.ULong.toByte", unsigned_to_byte),
    ("kotlin.ULong.toShort", unsigned_to_short),
    ("kotlin.ULong.toInt", unsigned_to_int),
    ("kotlin.ULong.toLong", unsigned_to_long),
    ("kotlin.ULong.toUByte", to_ubyte),
    ("kotlin.ULong.toUShort", to_ushort),
    ("kotlin.ULong.toUInt", to_uint),
    ("kotlin.ULong.toULong", to_ulong),
    ("kotlin.ULong.toDouble", unsigned_to_double),
    ("kotlin.ULong.toFloat", unsigned_to_float),
    ("kotlin.ULong.toString", unsigned_to_string),

    // ----- UShort -----
    ("kotlin.UShort.toByte", unsigned_to_byte),
    ("kotlin.UShort.toShort", unsigned_to_short),
    ("kotlin.UShort.toInt", unsigned_to_int),
    ("kotlin.UShort.toLong", unsigned_to_long),
    ("kotlin.UShort.toUByte", to_ubyte),
    ("kotlin.UShort.toUShort", to_ushort),
    ("kotlin.UShort.toUInt", to_uint),
    ("kotlin.UShort.toULong", to_ulong),
    ("kotlin.UShort.toDouble", unsigned_to_double),
    ("kotlin.UShort.toFloat", unsigned_to_float),
    ("kotlin.UShort.toString", unsigned_to_string),

    // ----- UByte -----
    ("kotlin.UByte.toByte", unsigned_to_byte),
    ("kotlin.UByte.toShort", unsigned_to_short),
    ("kotlin.UByte.toInt", unsigned_to_int),
    ("kotlin.UByte.toLong", unsigned_to_long),
    ("kotlin.UByte.toUByte", to_ubyte),
    ("kotlin.UByte.toUShort", to_ushort),
    ("kotlin.UByte.toUInt", to_uint),
    ("kotlin.UByte.toULong", to_ulong),
    ("kotlin.UByte.toDouble", unsigned_to_double),
    ("kotlin.UByte.toFloat", unsigned_to_float),
    ("kotlin.UByte.toString", unsigned_to_string),

    // ----- Double -----
    ("kotlin.Double.compareTo", double_compare_to),
    ("kotlin.Double.isFinite", double_is_finite),
    ("kotlin.Double.isInfinite", double_is_infinite),
    ("kotlin.Double.isNaN", double_is_nan),
    ("kotlin.Double.pow", double_pow),
    ("kotlin.Double.toByte", double_to_byte),
    ("kotlin.Double.toDouble", double_to_double),
    ("kotlin.Double.toFloat", double_to_float),
    ("kotlin.Double.toInt", double_to_int),
    ("kotlin.Double.toLong", double_to_long),
    ("kotlin.Double.toShort", double_to_short),
    ("kotlin.Double.toString", double_to_string),

    // ----- Float -----
    ("kotlin.Float.compareTo", float_compare_to),
    ("kotlin.Float.isFinite", float_is_finite),
    ("kotlin.Float.isInfinite", float_is_infinite),
    ("kotlin.Float.isNaN", float_is_nan),
    ("kotlin.Float.toByte", float_to_byte),
    ("kotlin.Float.toDouble", float_to_double),
    ("kotlin.Float.toFloat", float_to_float),
    ("kotlin.Float.toInt", float_to_int),
    ("kotlin.Float.toLong", float_to_long),
    ("kotlin.Float.toShort", float_to_short),
    ("kotlin.Float.toString", float_to_string),

    // ----- Boolean -----
    ("kotlin.Boolean.toString", bool_to_string),

    // ----- Exception constructors -----
    ("kotlin.ArithmeticException", excn_arithmetic),
    ("kotlin.ClassCastException", excn_class_cast),
    ("kotlin.Error", excn_error),
    ("kotlin.Exception", excn_exception),
    ("kotlin.IllegalArgumentException", excn_illegal_argument),
    ("kotlin.IllegalStateException", excn_illegal_state),
    ("kotlin.IndexOutOfBoundsException", excn_ioob),
    ("kotlin.NullPointerException", excn_npe),
    ("kotlin.NoSuchElementException", excn_no_such_element),
    ("kotlin.RuntimeException", excn_runtime),
    ("kotlin.Throwable", excn_throwable),
    ("kotlin.UnsupportedOperationException", excn_unsupported),

    // ----- Throwable members -----
    ("kotlin.Throwable.message", throwable_message),
    ("kotlin.Throwable.cause", throwable_cause),
    ("kotlin.Throwable.toString", throwable_to_string),

    // ----- Collection constructors -----
    ("kotlin.Pair", coll_pair_ctor),
    ("kotlin.collections.emptyList", coll_empty_list),
    ("kotlin.collections.emptyMap", coll_empty_map),
    ("kotlin.collections.emptySet", coll_empty_set),
    ("kotlin.collections.listOf", coll_list_of),
    ("kotlin.collections.mapOf", coll_map_of),
    ("kotlin.collections.mutableListOf", coll_mutable_list_of),
    ("kotlin.collections.mutableMapOf", coll_mutable_map_of),
    ("kotlin.collections.mutableSetOf", coll_mutable_set_of),
    ("kotlin.collections.setOf", coll_set_of),
    ("kotlin.to", coll_to_infix),
    ("kotlin.collections.ArrayList", coll_array_list_ctor),
    ("kotlin.collections.HashMap", coll_hash_map_ctor),
    ("kotlin.collections.HashSet", coll_hash_set_ctor),
    ("kotlin.collections.LinkedHashMap", coll_hash_map_ctor),
    ("kotlin.collections.LinkedHashSet", coll_hash_set_ctor),

    // ----- List / Set members -----
    ("kotlin.collections.List.contains", coll_list_contains),
    ("kotlin.collections.List.first", coll_list_first),
    ("kotlin.collections.List.get", coll_list_get),
    ("kotlin.collections.List.indexOf", coll_list_index_of),
    ("kotlin.collections.List.isEmpty", coll_list_is_empty),
    ("kotlin.collections.List.isNotEmpty", coll_list_is_not_empty),
    ("kotlin.collections.List.joinToString", coll_list_join_to_string),
    ("kotlin.collections.List.last", coll_list_last),
    ("kotlin.collections.List.average", coll_list_average),
    ("kotlin.collections.List.chunked", coll_list_chunked),
    ("kotlin.collections.List.distinct", coll_list_distinct),
    ("kotlin.collections.List.indices", coll_list_indices),
    ("kotlin.collections.List.lastIndex", coll_list_last_index),
    ("kotlin.collections.List.max", coll_list_max_or_null),
    ("kotlin.collections.List.maxOrNull", coll_list_max_or_null),
    ("kotlin.collections.List.min", coll_list_min_or_null),
    ("kotlin.collections.List.minOrNull", coll_list_min_or_null),
    ("kotlin.collections.List.sum", coll_list_sum),
    ("kotlin.collections.List.toMap", coll_list_to_map),
    ("kotlin.collections.List.drop", coll_list_drop),
    ("kotlin.collections.List.dropLast", coll_list_drop_last),
    ("kotlin.collections.List.lastIndexOf", coll_list_last_index_of),
    ("kotlin.collections.List.minus", coll_list_minus),
    ("kotlin.collections.List.plus", coll_list_plus),
    ("kotlin.collections.List.reversed", coll_list_reversed),
    ("kotlin.collections.List.size", coll_list_size),
    ("kotlin.collections.List.slice", coll_list_slice),
    ("kotlin.collections.List.sorted", coll_list_sorted),
    ("kotlin.collections.List.sortedDescending", coll_list_sorted_descending),
    ("kotlin.collections.List.subList", coll_list_sublist),
    ("kotlin.collections.List.take", coll_list_take),
    ("kotlin.collections.List.takeLast", coll_list_take_last),
    ("kotlin.collections.List.windowed", coll_list_windowed),
    ("kotlin.collections.List.zip", coll_list_zip),
    ("kotlin.collections.List.toString", coll_list_to_string),

    ("kotlin.collections.MutableList.add", coll_mut_list_add),
    ("kotlin.collections.MutableList.clear", coll_mut_list_clear),
    ("kotlin.collections.MutableList.contains", coll_list_contains),
    ("kotlin.collections.MutableList.first", coll_list_first),
    ("kotlin.collections.MutableList.get", coll_list_get),
    ("kotlin.collections.MutableList.indexOf", coll_list_index_of),
    ("kotlin.collections.MutableList.isEmpty", coll_list_is_empty),
    ("kotlin.collections.MutableList.isNotEmpty", coll_list_is_not_empty),
    ("kotlin.collections.MutableList.joinToString", coll_list_join_to_string),
    ("kotlin.collections.MutableList.last", coll_list_last),
    ("kotlin.collections.MutableList.average", coll_list_average),
    ("kotlin.collections.MutableList.chunked", coll_list_chunked),
    ("kotlin.collections.MutableList.indices", coll_list_indices),
    ("kotlin.collections.MutableList.lastIndex", coll_list_last_index),
    ("kotlin.collections.MutableList.max", coll_list_max_or_null),
    ("kotlin.collections.MutableList.maxOrNull", coll_list_max_or_null),
    ("kotlin.collections.MutableList.min", coll_list_min_or_null),
    ("kotlin.collections.MutableList.minOrNull", coll_list_min_or_null),
    ("kotlin.collections.MutableList.sum", coll_list_sum),
    ("kotlin.collections.MutableList.toMap", coll_list_to_map),
    ("kotlin.collections.MutableList.distinct", coll_list_distinct),
    ("kotlin.collections.MutableList.drop", coll_list_drop),
    ("kotlin.collections.MutableList.dropLast", coll_list_drop_last),
    ("kotlin.collections.MutableList.lastIndexOf", coll_list_last_index_of),
    ("kotlin.collections.MutableList.minus", coll_list_minus),
    ("kotlin.collections.MutableList.plus", coll_list_plus),
    ("kotlin.collections.MutableList.removeAt", coll_mut_list_remove_at),
    ("kotlin.collections.MutableList.reversed", coll_list_reversed),
    ("kotlin.collections.MutableList.size", coll_list_size),
    ("kotlin.collections.MutableList.slice", coll_list_slice),
    ("kotlin.collections.MutableList.sorted", coll_list_sorted),
    ("kotlin.collections.MutableList.sortedDescending", coll_list_sorted_descending),
    ("kotlin.collections.MutableList.subList", coll_list_sublist),
    ("kotlin.collections.MutableList.take", coll_list_take),
    ("kotlin.collections.MutableList.takeLast", coll_list_take_last),
    ("kotlin.collections.MutableList.windowed", coll_list_windowed),
    ("kotlin.collections.MutableList.zip", coll_list_zip),
    ("kotlin.collections.MutableList.toString", coll_list_to_string),

    ("kotlin.collections.Set.contains", coll_set_contains),
    ("kotlin.collections.Set.isEmpty", coll_set_is_empty),
    ("kotlin.collections.Set.isNotEmpty", coll_set_is_not_empty),
    ("kotlin.collections.Set.size", coll_set_size),
    ("kotlin.collections.Set.intersect", coll_set_intersect),
    ("kotlin.collections.Set.minus", coll_set_minus),
    ("kotlin.collections.Set.plus", coll_set_plus),
    ("kotlin.collections.Set.subtract", coll_set_subtract),
    ("kotlin.collections.Set.toString", coll_set_to_string),
    ("kotlin.collections.Set.union", coll_set_union),
    ("kotlin.collections.MutableSet.add", coll_mut_set_add),
    ("kotlin.collections.MutableSet.clear", coll_mut_set_clear),
    ("kotlin.collections.MutableSet.contains", coll_set_contains),
    ("kotlin.collections.MutableSet.isEmpty", coll_set_is_empty),
    ("kotlin.collections.MutableSet.isNotEmpty", coll_set_is_not_empty),
    ("kotlin.collections.MutableSet.remove", coll_mut_set_remove),
    ("kotlin.collections.MutableSet.size", coll_set_size),
    ("kotlin.collections.MutableSet.toString", coll_set_to_string),

    // ----- Map members -----
    ("kotlin.collections.Map.containsKey", coll_map_contains_key),
    ("kotlin.collections.Map.containsValue", coll_map_contains_value),
    ("kotlin.collections.Map.entries", coll_map_entries),
    ("kotlin.collections.Map.get", coll_map_get),
    ("kotlin.collections.Map.isEmpty", coll_map_is_empty),
    ("kotlin.collections.Map.isNotEmpty", coll_map_is_not_empty),
    ("kotlin.collections.Map.keys", coll_map_keys),
    ("kotlin.collections.Map.size", coll_map_size),
    ("kotlin.collections.Map.toString", coll_map_to_string),
    ("kotlin.collections.Map.values", coll_map_values),
    ("kotlin.collections.MutableMap.clear", coll_mut_map_clear),
    ("kotlin.collections.MutableMap.containsKey", coll_map_contains_key),
    ("kotlin.collections.MutableMap.containsValue", coll_map_contains_value),
    ("kotlin.collections.MutableMap.entries", coll_map_entries),
    ("kotlin.collections.MutableMap.get", coll_map_get),
    ("kotlin.collections.MutableMap.isEmpty", coll_map_is_empty),
    ("kotlin.collections.MutableMap.isNotEmpty", coll_map_is_not_empty),
    ("kotlin.collections.MutableMap.keys", coll_map_keys),
    ("kotlin.collections.MutableMap.put", coll_mut_map_put),
    ("kotlin.collections.MutableMap.remove", coll_mut_map_remove),
    ("kotlin.collections.MutableMap.size", coll_map_size),
    ("kotlin.collections.MutableMap.toString", coll_map_to_string),
    ("kotlin.collections.MutableMap.values", coll_map_values),

    // ----- Pair members -----
    ("kotlin.Pair.first", pair_first),
    ("kotlin.Pair.second", pair_second),
    ("kotlin.Pair.toString", pair_to_string),

    // ----- Triple -----
    ("kotlin.Triple", coll_triple_ctor),
    ("kotlin.Triple.first", triple_first),
    ("kotlin.Triple.second", triple_second),
    ("kotlin.Triple.third", triple_third),
    ("kotlin.Triple.toString", triple_to_string),
    ("kotlin.Triple.toList", triple_to_list),

    // ----- Comparator factories -----
    // The conventional call shape `Comparator.naturalOrder<T>()` ends up
    // as a `Path("Comparator").Member("naturalOrder")` FQN at the call
    // site — so we register both the rooted-at-kotlin form and the bare
    // dotted form the interpreter actually looks up.
    ("kotlin.Comparator.naturalOrder", comparator_natural_order),
    ("kotlin.Comparator.reverseOrder", comparator_reverse_order),
    ("Comparator.naturalOrder", comparator_natural_order),
    ("Comparator.reverseOrder", comparator_reverse_order),
    ("kotlin.naturalOrder", comparator_natural_order),
    ("kotlin.reverseOrder", comparator_reverse_order),
    ("naturalOrder", comparator_natural_order),
    ("reverseOrder", comparator_reverse_order),

    // ----- Sequence -----
    ("kotlin.collections.List.asSequence", seq_from_list),
    ("kotlin.collections.MutableList.asSequence", seq_from_list),
    ("kotlin.collections.Set.asSequence", seq_from_set),
    ("kotlin.collections.MutableSet.asSequence", seq_from_set),
    ("kotlin.String.asSequence", seq_from_string),
    ("kotlin.ranges.IntRange.asSequence", seq_from_range),
    ("kotlin.ranges.IntProgression.asSequence", seq_from_range),
    ("kotlin.sequences.sequenceOf", seq_of),
    ("kotlin.sequences.emptySequence", seq_empty),
    ("kotlin.sequences.Sequence.toList", seq_to_list),
    ("kotlin.sequences.Sequence.toMutableList", seq_to_mutable_list),
    ("kotlin.sequences.Sequence.toSet", seq_to_set),
    ("kotlin.sequences.Sequence.count", seq_count_no_pred),
    ("kotlin.sequences.Sequence.first", seq_first),
    ("kotlin.sequences.Sequence.last", seq_last),
    ("kotlin.sequences.Sequence.toString", seq_to_string),

    // ----- Map.Entry members -----
    ("kotlin.collections.Map.Entry.key", map_entry_key),
    ("kotlin.collections.Map.Entry.toString", map_entry_to_string),
    ("kotlin.collections.Map.Entry.value", map_entry_value),

    // ----- Range progressions -----
    ("kotlin.ranges.downTo", ranges_down_to),
    ("kotlin.ranges.step", ranges_step),
    ("kotlin.ranges.until", ranges_until),
    ("kotlin.ranges.IntRange.first", range_first),
    ("kotlin.ranges.IntRange.last", range_last),
    ("kotlin.ranges.IntRange.step", range_step_field),
    ("kotlin.ranges.IntRange.toString", range_to_string),
    ("kotlin.ranges.IntRange.contains", range_contains),
    ("kotlin.ranges.IntRange.isEmpty", range_is_empty),
    ("kotlin.ranges.IntProgression.first", range_first),
    ("kotlin.ranges.IntProgression.last", range_last),
    ("kotlin.ranges.IntProgression.step", range_step_field),
    ("kotlin.ranges.IntProgression.toString", range_to_string),
    ("kotlin.ranges.IntRange.reversed", range_reversed),
    ("kotlin.ranges.IntProgression.reversed", range_reversed),
    ("kotlin.ranges.IntRange.toList", range_to_list),
    ("kotlin.ranges.IntProgression.toList", range_to_list),
    ("kotlin.ranges.IntRange.count", range_count),
    ("kotlin.ranges.IntProgression.count", range_count),
    ("kotlin.ranges.IntRange.sum", range_sum),
    ("kotlin.ranges.IntProgression.sum", range_sum),
    ("kotlin.ranges.LongRange.first", range_first),
    ("kotlin.ranges.LongRange.last", range_last),
    ("kotlin.ranges.LongRange.step", range_step_field),
    ("kotlin.ranges.LongRange.toString", range_to_string),
    ("kotlin.ranges.LongRange.contains", range_contains),
    ("kotlin.ranges.LongRange.isEmpty", range_is_empty),
    ("kotlin.ranges.LongProgression.first", range_first),
    ("kotlin.ranges.LongProgression.last", range_last),
    ("kotlin.ranges.LongProgression.step", range_step_field),
    ("kotlin.ranges.LongProgression.toString", range_to_string),
    ("kotlin.ranges.LongRange.reversed", range_reversed),
    ("kotlin.ranges.LongProgression.reversed", range_reversed),
    ("kotlin.ranges.LongRange.toList", range_to_list),
    ("kotlin.ranges.LongProgression.toList", range_to_list),
    ("kotlin.ranges.LongRange.count", range_count),
    ("kotlin.ranges.LongProgression.count", range_count),
    ("kotlin.ranges.LongRange.sum", range_sum),
    ("kotlin.ranges.LongProgression.sum", range_sum),

    // ----- Additional math -----
    ("kotlin.math.asin", math_asin),
    ("kotlin.math.acos", math_acos),
    ("kotlin.math.atan", math_atan),
    ("kotlin.math.atan2", math_atan2),

    // ----- Additional String -----
    ("kotlin.String.substringBefore", string_substring_before),
    ("kotlin.String.substringAfter", string_substring_after),
    ("kotlin.String.substringBeforeLast", string_substring_before_last),
    ("kotlin.String.substringAfterLast", string_substring_after_last),
    ("kotlin.String.replaceFirst", string_replace_first),
    ("kotlin.String.trimIndent", string_trim_indent),
    ("kotlin.String.trimMargin", string_trim_margin),
    ("kotlin.String.lines", string_lines),
    ("kotlin.String.toCharArray", string_to_char_array),
    ("kotlin.String.toLong", string_to_long),
    ("kotlin.String.toLongOrNull", string_to_long_or_null),
    ("kotlin.String.toDoubleOrNull", string_to_double_or_null),
    ("kotlin.String.toBoolean", string_to_boolean),
    ("kotlin.String.toBooleanStrictOrNull", string_to_boolean_strict_or_null),

    // ----- Additional Char -----
    ("kotlin.Char.uppercaseChar", char_uppercase_char),
    ("kotlin.Char.lowercaseChar", char_lowercase_char),
    ("kotlin.Char.digitToIntOrNull", char_digit_to_int_or_null),

    // ----- Additional Int -----
    ("kotlin.Int.coerceIn", int_coerce_in),
    ("kotlin.Int.coerceAtLeast", int_coerce_at_least),
    ("kotlin.Int.coerceAtMost", int_coerce_at_most),
    ("kotlin.Int.toChar", int_to_char),

    // ----- Additional List ops -----
    ("kotlin.collections.List.firstOrNull", coll_list_first_or_null),
    ("kotlin.collections.List.lastOrNull", coll_list_last_or_null),
    ("kotlin.collections.List.single", coll_list_single),
    ("kotlin.collections.List.singleOrNull", coll_list_single_or_null),
    ("kotlin.collections.List.flatten", coll_list_flatten),
    ("kotlin.collections.List.unzip", coll_list_unzip),
    ("kotlin.collections.List.containsAll", coll_list_contains_all),
    ("kotlin.collections.List.toList", coll_list_to_list),
    ("kotlin.collections.List.toMutableList", coll_list_to_mutable_list),
    ("kotlin.collections.List.toSet", coll_list_to_set),
    ("kotlin.collections.List.toMutableSet", coll_list_to_mutable_set),
    ("kotlin.collections.List.count", coll_list_count_no_pred),
    ("kotlin.collections.List.withIndex", coll_list_with_index),
    ("kotlin.collections.MutableList.firstOrNull", coll_list_first_or_null),
    ("kotlin.collections.MutableList.lastOrNull", coll_list_last_or_null),
    ("kotlin.collections.MutableList.single", coll_list_single),
    ("kotlin.collections.MutableList.singleOrNull", coll_list_single_or_null),
    ("kotlin.collections.MutableList.flatten", coll_list_flatten),
    ("kotlin.collections.MutableList.unzip", coll_list_unzip),
    ("kotlin.collections.MutableList.containsAll", coll_list_contains_all),
    ("kotlin.collections.MutableList.toList", coll_list_to_list),
    ("kotlin.collections.MutableList.toMutableList", coll_list_to_mutable_list),
    ("kotlin.collections.MutableList.toSet", coll_list_to_set),
    ("kotlin.collections.MutableList.toMutableSet", coll_list_to_mutable_set),
    ("kotlin.collections.MutableList.count", coll_list_count_no_pred),
    ("kotlin.collections.MutableList.withIndex", coll_list_with_index),
    ("kotlin.collections.MutableList.addAll", coll_mut_list_add_all),
    ("kotlin.collections.MutableList.remove", coll_mut_list_remove),
    ("kotlin.collections.MutableList.removeAll", coll_mut_list_remove_all),
    ("kotlin.collections.MutableList.retainAll", coll_mut_list_retain_all),
    ("kotlin.collections.MutableList.set", coll_mut_list_set),

    // ----- Additional Set ops -----
    ("kotlin.collections.Set.containsAll", coll_set_contains_all),
    ("kotlin.collections.Set.toList", coll_set_to_list),
    ("kotlin.collections.Set.toMutableList", coll_set_to_mutable_list),
    ("kotlin.collections.Set.toSet", coll_set_to_set_),
    ("kotlin.collections.Set.toMutableSet", coll_set_to_mutable_set_),
    ("kotlin.collections.Set.withIndex", coll_set_with_index),
    ("kotlin.collections.Set.count", coll_set_count_no_pred),
    ("kotlin.collections.MutableSet.containsAll", coll_set_contains_all),
    ("kotlin.collections.MutableSet.toList", coll_set_to_list),
    ("kotlin.collections.MutableSet.addAll", coll_mut_set_add_all),

    // ----- Additional Map ops -----
    ("kotlin.collections.Map.getOrDefault", coll_map_get_or_default),
    ("kotlin.collections.Map.getValue", coll_map_get_value),
    ("kotlin.collections.Map.toList", coll_map_to_list),
    ("kotlin.collections.Map.count", coll_map_count_no_pred),
    ("kotlin.collections.MutableMap.getOrDefault", coll_map_get_or_default),
    ("kotlin.collections.MutableMap.getValue", coll_map_get_value),
    ("kotlin.collections.MutableMap.toList", coll_map_to_list),
    ("kotlin.collections.MutableMap.count", coll_map_count_no_pred),
    ("kotlin.collections.MutableMap.putAll", coll_mut_map_put_all),
    ("kotlin.collections.MutableMap.set", coll_mut_map_set),

    // ----- Iterable higher-order (lambda-driven) -----
    ("kotlin.collections.List.forEach", coll_iter_for_each),
    ("kotlin.collections.MutableList.forEach", coll_iter_for_each),
    ("kotlin.collections.Set.forEach", coll_iter_for_each),
    ("kotlin.collections.MutableSet.forEach", coll_iter_for_each),
    ("kotlin.collections.Map.forEach", coll_iter_for_each),
    ("kotlin.collections.MutableMap.forEach", coll_iter_for_each),
    ("kotlin.collections.List.map", coll_iter_map),
    ("kotlin.collections.MutableList.map", coll_iter_map),
    ("kotlin.collections.Set.map", coll_iter_map),
    ("kotlin.collections.MutableSet.map", coll_iter_map),
    ("kotlin.collections.Map.map", coll_iter_map),
    ("kotlin.collections.MutableMap.map", coll_iter_map),
    ("kotlin.collections.List.filter", coll_iter_filter),
    ("kotlin.collections.MutableList.filter", coll_iter_filter),
    ("kotlin.collections.Set.filter", coll_iter_filter),
    ("kotlin.collections.MutableSet.filter", coll_iter_filter),
    ("kotlin.collections.Map.filter", coll_iter_filter),
    ("kotlin.collections.MutableMap.filter", coll_iter_filter),
    ("kotlin.collections.List.filterNot", coll_iter_filter_not),
    ("kotlin.collections.MutableList.filterNot", coll_iter_filter_not),
    ("kotlin.collections.Set.filterNot", coll_iter_filter_not),
    ("kotlin.collections.MutableSet.filterNot", coll_iter_filter_not),
    ("kotlin.collections.Map.filterNot", coll_iter_filter_not),
    ("kotlin.collections.MutableMap.filterNot", coll_iter_filter_not),
    ("kotlin.collections.List.any", coll_iter_any),
    ("kotlin.collections.MutableList.any", coll_iter_any),
    ("kotlin.collections.Set.any", coll_iter_any),
    ("kotlin.collections.MutableSet.any", coll_iter_any),
    ("kotlin.collections.Map.any", coll_iter_any),
    ("kotlin.collections.MutableMap.any", coll_iter_any),
    ("kotlin.collections.List.all", coll_iter_all),
    ("kotlin.collections.MutableList.all", coll_iter_all),
    ("kotlin.collections.Set.all", coll_iter_all),
    ("kotlin.collections.MutableSet.all", coll_iter_all),
    ("kotlin.collections.Map.all", coll_iter_all),
    ("kotlin.collections.MutableMap.all", coll_iter_all),
    ("kotlin.collections.List.none", coll_iter_none),
    ("kotlin.collections.MutableList.none", coll_iter_none),
    ("kotlin.collections.Set.none", coll_iter_none),
    ("kotlin.collections.MutableSet.none", coll_iter_none),
    ("kotlin.collections.Map.none", coll_iter_none),
    ("kotlin.collections.MutableMap.none", coll_iter_none),
    ("kotlin.collections.List.find", coll_iter_find),
    ("kotlin.collections.MutableList.find", coll_iter_find),
    ("kotlin.collections.Set.find", coll_iter_find),
    ("kotlin.collections.MutableSet.find", coll_iter_find),
    ("kotlin.collections.List.fold", coll_iter_fold),
    ("kotlin.collections.MutableList.fold", coll_iter_fold),
    ("kotlin.collections.Set.fold", coll_iter_fold),
    ("kotlin.collections.MutableSet.fold", coll_iter_fold),
    ("kotlin.collections.Map.fold", coll_iter_fold),
    ("kotlin.collections.MutableMap.fold", coll_iter_fold),
    ("kotlin.collections.List.reduce", coll_iter_reduce),
    ("kotlin.collections.MutableList.reduce", coll_iter_reduce),
    ("kotlin.collections.Set.reduce", coll_iter_reduce),
    ("kotlin.collections.MutableSet.reduce", coll_iter_reduce),
    ("kotlin.collections.List.sumOf", coll_iter_sum_of),
    ("kotlin.collections.MutableList.sumOf", coll_iter_sum_of),
    ("kotlin.collections.Set.sumOf", coll_iter_sum_of),
    ("kotlin.collections.MutableSet.sumOf", coll_iter_sum_of),
    ("kotlin.collections.Map.sumOf", coll_iter_sum_of),
    ("kotlin.collections.MutableMap.sumOf", coll_iter_sum_of),
    ("kotlin.collections.List.takeWhile", coll_iter_take_while),
    ("kotlin.collections.MutableList.takeWhile", coll_iter_take_while),
    ("kotlin.collections.Set.takeWhile", coll_iter_take_while),
    ("kotlin.collections.MutableSet.takeWhile", coll_iter_take_while),
    ("kotlin.collections.List.dropWhile", coll_iter_drop_while),
    ("kotlin.collections.MutableList.dropWhile", coll_iter_drop_while),
    ("kotlin.collections.Set.dropWhile", coll_iter_drop_while),
    ("kotlin.collections.MutableSet.dropWhile", coll_iter_drop_while),
    ("kotlin.collections.List.partition", coll_iter_partition),
    ("kotlin.collections.MutableList.partition", coll_iter_partition),
    ("kotlin.collections.Set.partition", coll_iter_partition),
    ("kotlin.collections.MutableSet.partition", coll_iter_partition),
    ("kotlin.collections.List.distinctBy", coll_iter_distinct_by),
    ("kotlin.collections.MutableList.distinctBy", coll_iter_distinct_by),
    ("kotlin.collections.Set.distinctBy", coll_iter_distinct_by),
    ("kotlin.collections.MutableSet.distinctBy", coll_iter_distinct_by),
    ("kotlin.collections.List.flatMap", coll_iter_flat_map),
    ("kotlin.collections.MutableList.flatMap", coll_iter_flat_map),
    ("kotlin.collections.Set.flatMap", coll_iter_flat_map),
    ("kotlin.collections.MutableSet.flatMap", coll_iter_flat_map),
    ("kotlin.collections.List.groupBy", coll_iter_group_by),
    ("kotlin.collections.MutableList.groupBy", coll_iter_group_by),
    ("kotlin.collections.Set.groupBy", coll_iter_group_by),
    ("kotlin.collections.MutableSet.groupBy", coll_iter_group_by),
    ("kotlin.collections.List.associate", coll_iter_associate),
    ("kotlin.collections.MutableList.associate", coll_iter_associate),
    ("kotlin.collections.Set.associate", coll_iter_associate),
    ("kotlin.collections.MutableSet.associate", coll_iter_associate),
    ("kotlin.collections.List.associateBy", coll_iter_associate_by),
    ("kotlin.collections.MutableList.associateBy", coll_iter_associate_by),
    ("kotlin.collections.Set.associateBy", coll_iter_associate_by),
    ("kotlin.collections.MutableSet.associateBy", coll_iter_associate_by),
    ("kotlin.collections.List.associateWith", coll_iter_associate_with),
    ("kotlin.collections.MutableList.associateWith", coll_iter_associate_with),
    ("kotlin.collections.Set.associateWith", coll_iter_associate_with),
    ("kotlin.collections.MutableSet.associateWith", coll_iter_associate_with),
    ("kotlin.collections.List.sortedBy", coll_iter_sorted_by),
    ("kotlin.collections.MutableList.sortedBy", coll_iter_sorted_by),
    ("kotlin.collections.Set.sortedBy", coll_iter_sorted_by),
    ("kotlin.collections.MutableSet.sortedBy", coll_iter_sorted_by),
    ("kotlin.collections.List.sortedByDescending", coll_iter_sorted_by_desc),
    ("kotlin.collections.MutableList.sortedByDescending", coll_iter_sorted_by_desc),
    ("kotlin.collections.Set.sortedByDescending", coll_iter_sorted_by_desc),
    ("kotlin.collections.MutableSet.sortedByDescending", coll_iter_sorted_by_desc),
    ("kotlin.collections.List.maxOf", coll_iter_max_of),
    ("kotlin.collections.MutableList.maxOf", coll_iter_max_of),
    ("kotlin.collections.Set.maxOf", coll_iter_max_of),
    ("kotlin.collections.MutableSet.maxOf", coll_iter_max_of),
    ("kotlin.collections.List.minOf", coll_iter_min_of),
    ("kotlin.collections.MutableList.minOf", coll_iter_min_of),
    ("kotlin.collections.Set.minOf", coll_iter_min_of),
    ("kotlin.collections.MutableSet.minOf", coll_iter_min_of),
    ("kotlin.collections.List.onEach", coll_iter_on_each),
    ("kotlin.collections.MutableList.onEach", coll_iter_on_each),
    ("kotlin.collections.Set.onEach", coll_iter_on_each),
    ("kotlin.collections.MutableSet.onEach", coll_iter_on_each),
    ("kotlin.collections.List.mapNotNull", coll_iter_map_not_null),
    ("kotlin.collections.MutableList.mapNotNull", coll_iter_map_not_null),
    ("kotlin.collections.Set.mapNotNull", coll_iter_map_not_null),
    ("kotlin.collections.MutableSet.mapNotNull", coll_iter_map_not_null),
    ("kotlin.collections.List.mapIndexed", coll_iter_map_indexed),
    ("kotlin.collections.MutableList.mapIndexed", coll_iter_map_indexed),
    ("kotlin.collections.Set.mapIndexed", coll_iter_map_indexed),
    ("kotlin.collections.MutableSet.mapIndexed", coll_iter_map_indexed),
    ("kotlin.collections.List.forEachIndexed", coll_iter_for_each_indexed),
    ("kotlin.collections.MutableList.forEachIndexed", coll_iter_for_each_indexed),
    ("kotlin.collections.Set.forEachIndexed", coll_iter_for_each_indexed),
    ("kotlin.collections.MutableSet.forEachIndexed", coll_iter_for_each_indexed),
    ("kotlin.collections.List.filterIndexed", coll_iter_filter_indexed),
    ("kotlin.collections.MutableList.filterIndexed", coll_iter_filter_indexed),
    ("kotlin.collections.Set.filterIndexed", coll_iter_filter_indexed),
    ("kotlin.collections.MutableSet.filterIndexed", coll_iter_filter_indexed),
    ("kotlin.collections.Map.filterKeys", map_filter_keys),
    ("kotlin.collections.MutableMap.filterKeys", map_filter_keys),
    ("kotlin.collections.Map.filterValues", map_filter_values),
    ("kotlin.collections.MutableMap.filterValues", map_filter_values),
    ("kotlin.collections.Map.mapKeys", map_map_keys),
    ("kotlin.collections.MutableMap.mapKeys", map_map_keys),
    ("kotlin.collections.Map.mapValues", map_map_values),
    ("kotlin.collections.MutableMap.mapValues", map_map_values),

    // ----- Pair extras: toList -----
    ("kotlin.Pair.toList", pair_to_list),

    // ----- Result -----
    ("kotlin.Result.isSuccess", result_is_success),
    ("kotlin.Result.isFailure", result_is_failure),
    ("kotlin.Result.getOrNull", result_get_or_null),
    ("kotlin.Result.exceptionOrNull", result_exception_or_null),
    ("kotlin.Result.getOrDefault", result_get_or_default),
    ("kotlin.Result.toString", result_to_string),

    // ----- Regex -----
    ("kotlin.text.Regex", regex_ctor),
    ("kotlin.text.Regex.pattern", regex_pattern),
    ("kotlin.text.Regex.toString", regex_to_string),
    ("kotlin.text.Regex.matches", regex_matches),
    ("kotlin.text.Regex.containsMatchIn", regex_contains_match_in),
    ("kotlin.text.Regex.find", regex_find),
    ("kotlin.text.Regex.findAll", regex_find_all),
    ("kotlin.text.Regex.matchEntire", regex_match_entire),
    ("kotlin.text.Regex.matchAt", regex_match_at),
    ("kotlin.text.Regex.matchesAt", regex_matches_at),
    ("kotlin.text.Regex.replace", regex_replace),
    ("kotlin.text.Regex.replaceFirst", regex_replace_first),
    ("kotlin.text.Regex.split", regex_split),
    ("kotlin.text.Regex.escape", regex_static_escape),
    ("kotlin.text.Regex.fromLiteral", regex_from_literal),
    ("kotlin.text.Regex.escapeReplacement", regex_static_escape_replacement),
    ("kotlin.text.Regex.Companion.escape", regex_static_escape),
    ("kotlin.text.Regex.Companion.fromLiteral", regex_from_literal),
    ("kotlin.text.Regex.Companion.escapeReplacement", regex_static_escape_replacement),
    // Bare-name forms produced by `try_qualified_name` for `Regex.escape(...)`
    // style calls in source. Mirrors the Comparator.naturalOrder pattern.
    ("Regex.escape", regex_static_escape),
    ("Regex.fromLiteral", regex_from_literal),
    ("Regex.escapeReplacement", regex_static_escape_replacement),

    // ----- MatchResult / MatchGroup -----
    ("kotlin.text.MatchResult.value", match_result_value),
    ("kotlin.text.MatchResult.range", match_result_range),
    ("kotlin.text.MatchResult.groupValues", match_result_group_values),
    ("kotlin.text.MatchResult.groups", match_result_groups),
    ("kotlin.text.MatchResult.next", match_result_next),
    ("kotlin.text.MatchResult.toString", match_result_to_string),
    ("kotlin.text.MatchGroup.value", match_group_value),
    ("kotlin.text.MatchGroup.range", match_group_range),

    // ----- StringBuilder -----
    ("kotlin.text.StringBuilder", string_builder_ctor),
    ("kotlin.StringBuilder", string_builder_ctor),
    ("kotlin.text.StringBuilder.append", string_builder_append),
    ("kotlin.text.StringBuilder.appendLine", string_builder_append_line),
    ("kotlin.text.StringBuilder.length", string_builder_length),
    ("kotlin.text.StringBuilder.toString", string_builder_to_string),
    ("kotlin.text.StringBuilder.get", string_builder_get),
    ("kotlin.text.StringBuilder.isEmpty", string_builder_is_empty),
    ("kotlin.text.StringBuilder.isNotEmpty", string_builder_is_not_empty),
    ("kotlin.text.StringBuilder.clear", string_builder_clear),
    ("kotlin.text.StringBuilder.insert", string_builder_insert),
    ("kotlin.text.StringBuilder.deleteAt", string_builder_delete_at),
    ("kotlin.text.StringBuilder.deleteRange", string_builder_delete_range),
    ("kotlin.text.StringBuilder.setLength", string_builder_set_length),
    ("kotlin.text.StringBuilder.reverse", string_builder_reverse),
    ("kotlin.text.StringBuilder.substring", string_builder_substring),

    // ----- String.format / kotlin.text.format -----
    ("kotlin.text.String.format", string_format_static),
    ("kotlin.text.format", string_format_static),
    ("kotlin.String.format", string_format_member),
    // `String.format("...", x)` resolves through `try_qualified_name` as
    // the bare key "String.format".
    ("String.format", string_format_static),

    // ----- Char title-case -----
    ("kotlin.Char.titlecase", char_titlecase),
    ("kotlin.Char.titlecaseChar", char_titlecase_char),
];

/// Number of hand-implemented intrinsics; surfaced through
/// `klio_stdlib::coverage`.
pub const COUNT: usize = TABLE.len();

/// Parameter names for hand-implemented intrinsics. Keyed by the same FQNs
/// used in `TABLE`. Consulted by `klio_stdlib::param_names` so callers can
/// reorder named arguments to match each intrinsic's declared parameter
/// order — without depending on the upstream mining covering our exact
/// dispatch FQN. Entries omitted here fall through to the upstream lookup.
const PARAM_NAMES: &[(&str, &[&str])] = &[
    ("kotlin.collections.List.chunked", &["size", "transform"]),
    ("kotlin.collections.List.drop", &["n"]),
    ("kotlin.collections.List.dropLast", &["n"]),
    ("kotlin.collections.List.joinToString", &[
        "separator", "prefix", "postfix", "limit", "truncated", "transform",
    ]),
    ("kotlin.collections.List.slice", &["indices"]),
    ("kotlin.collections.List.subList", &["fromIndex", "toIndex"]),
    ("kotlin.collections.List.take", &["n"]),
    ("kotlin.collections.List.takeLast", &["n"]),
    ("kotlin.collections.List.windowed", &[
        "size", "step", "partialWindows", "transform",
    ]),
    ("kotlin.collections.MutableList.chunked", &["size", "transform"]),
    ("kotlin.collections.MutableList.drop", &["n"]),
    ("kotlin.collections.MutableList.dropLast", &["n"]),
    ("kotlin.collections.MutableList.joinToString", &[
        "separator", "prefix", "postfix", "limit", "truncated", "transform",
    ]),
    ("kotlin.collections.MutableList.slice", &["indices"]),
    ("kotlin.collections.MutableList.subList", &["fromIndex", "toIndex"]),
    ("kotlin.collections.MutableList.take", &["n"]),
    ("kotlin.collections.MutableList.takeLast", &["n"]),
    ("kotlin.collections.MutableList.windowed", &[
        "size", "step", "partialWindows", "transform",
    ]),
    ("kotlin.String.chunked", &["size", "transform"]),
    ("kotlin.String.padEnd", &["length", "padChar"]),
    ("kotlin.String.padStart", &["length", "padChar"]),
    ("kotlin.String.repeat", &["n"]),
    ("kotlin.String.replace", &["oldValue", "newValue", "ignoreCase"]),
    ("kotlin.String.split", &["delimiters", "ignoreCase", "limit"]),
    ("kotlin.String.substring", &["startIndex", "endIndex"]),
    ("kotlin.String.windowed", &[
        "size", "step", "partialWindows", "transform",
    ]),
    ("kotlin.String.indexOf", &["string", "startIndex", "ignoreCase"]),
    ("kotlin.String.lastIndexOf", &["string", "startIndex", "ignoreCase"]),
    ("kotlin.String.contains", &["other", "ignoreCase"]),
    ("kotlin.String.startsWith", &["prefix", "ignoreCase"]),
    ("kotlin.String.endsWith", &["suffix", "ignoreCase"]),
    ("kotlin.String.toInt", &["radix"]),
    ("kotlin.String.toIntOrNull", &["radix"]),
    ("kotlin.Int.toString", &["radix"]),

    // Set parallels.
    ("kotlin.collections.Set.joinToString", &[
        "separator", "prefix", "postfix", "limit", "truncated", "transform",
    ]),
    ("kotlin.collections.MutableSet.joinToString", &[
        "separator", "prefix", "postfix", "limit", "truncated", "transform",
    ]),

    // Range / IntProgression.
    ("kotlin.ranges.IntRange.joinToString", &[
        "separator", "prefix", "postfix", "limit", "truncated", "transform",
    ]),
    ("kotlin.ranges.IntProgression.joinToString", &[
        "separator", "prefix", "postfix", "limit", "truncated", "transform",
    ]),

    // Map intrinsics where a default arg is meaningful.
    ("kotlin.collections.Map.getOrDefault", &["key", "defaultValue"]),
    ("kotlin.collections.MutableMap.getOrDefault", &["key", "defaultValue"]),

    // Single-arg intrinsics where the named form is occasionally seen.
    ("kotlin.collections.List.sortedWith", &["comparator"]),
    ("kotlin.collections.MutableList.sortedWith", &["comparator"]),

    // Result.
    ("kotlin.Result.getOrDefault", &["defaultValue"]),
];

// ===== scope functions =====
//
// All scope functions dispatch the user's lambda via
// `ctx.host.invoke_callable`. The intrinsic doesn't see the lambda's
// body — the host wires that back into the interpreter's
// `invoke_callable_value` path.

fn split_receiver_and_block(ctx: &CallCtx) -> Result<(Value, Value), RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity(
            "scope-fn expects (receiver, block)".into(),
        ));
    }
    Ok((ctx.args[0].clone(), ctx.args[1].clone()))
}

fn split_block(ctx: &CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 1 {
        return Err(RuntimeError::Arity("scope-fn expects (block)".into()));
    }
    Ok(ctx.args[0].clone())
}

fn scope_let(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (recv, block) = split_receiver_and_block(ctx)?;
    let CallCtx { out, host, .. } = ctx;
    host.invoke_callable(&block, std::slice::from_ref(&recv), *out)
}

fn scope_run(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() == 2 {
        let (recv, block) = split_receiver_and_block(ctx)?;
        let CallCtx { out, host, .. } = ctx;
        host.invoke_callable_with_this(&block, &[], &recv, *out)
    } else {
        let block = split_block(ctx)?;
        let CallCtx { out, host, .. } = ctx;
        host.invoke_callable(&block, &[], *out)
    }
}

fn scope_apply(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (recv, block) = split_receiver_and_block(ctx)?;
    let CallCtx { out, host, .. } = ctx;
    host.invoke_callable_with_this(&block, &[], &recv, *out)?;
    Ok(recv)
}

fn scope_also(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (recv, block) = split_receiver_and_block(ctx)?;
    let CallCtx { out, host, .. } = ctx;
    host.invoke_callable(&block, std::slice::from_ref(&recv), *out)?;
    Ok(recv)
}

fn scope_with(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (recv, block) = split_receiver_and_block(ctx)?;
    let CallCtx { out, host, .. } = ctx;
    host.invoke_callable_with_this(&block, &[], &recv, *out)
}

fn scope_take_if(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (recv, block) = split_receiver_and_block(ctx)?;
    let CallCtx { out, host, .. } = ctx;
    let pred = host.invoke_callable(&block, std::slice::from_ref(&recv), *out)?;
    Ok(if matches!(pred, Value::Bool(true)) {
        recv
    } else {
        Value::Null
    })
}

fn scope_take_unless(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (recv, block) = split_receiver_and_block(ctx)?;
    let CallCtx { out, host, .. } = ctx;
    let pred = host.invoke_callable(&block, std::slice::from_ref(&recv), *out)?;
    Ok(if matches!(pred, Value::Bool(false)) {
        recv
    } else {
        Value::Null
    })
}

fn iterable_items(v: &Value, what: &str) -> Result<Vec<Value>, RuntimeError> {
    match v {
        Value::List { items, .. } | Value::Set { items, .. } => Ok(items.borrow().clone()),
        Value::Map { entries, .. } => Ok(entries
            .borrow()
            .iter()
            .map(|(k, v)| Value::MapEntry {
                key: Box::new(k.clone()),
                value: Box::new(v.clone()),
            })
            .collect()),
        _ => Err(RuntimeError::Type(format!(
            "{what} requires an iterable receiver"
        ))),
    }
}

fn coll_iter_for_each(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("forEach expects (receiver, block)".into()));
    }
    let items = iterable_items(&ctx.args[0], "forEach")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    for v in items {
        host.invoke_callable(&block, std::slice::from_ref(&v), *out)?;
    }
    Ok(Value::Unit)
}

fn coll_iter_map(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("map expects (receiver, block)".into()));
    }
    let items = iterable_items(&ctx.args[0], "map")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut result = Vec::with_capacity(items.len());
    for v in items {
        result.push(host.invoke_callable(&block, std::slice::from_ref(&v), *out)?);
    }
    Ok(make_list(result, false))
}

fn coll_iter_filter(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("filter expects (receiver, block)".into()));
    }
    let items = iterable_items(&ctx.args[0], "filter")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut result = Vec::new();
    for v in items {
        let r = host.invoke_callable(&block, std::slice::from_ref(&v), *out)?;
        if matches!(r, Value::Bool(true)) {
            result.push(v);
        }
    }
    Ok(make_list(result, false))
}

fn coll_iter_any(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let items = iterable_items(&ctx.args[0], "any")?;
    if ctx.args.len() == 1 {
        return Ok(Value::Bool(!items.is_empty()));
    }
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    for v in items {
        if matches!(host.invoke_callable(&block, std::slice::from_ref(&v), *out)?, Value::Bool(true)) {
            return Ok(Value::Bool(true));
        }
    }
    Ok(Value::Bool(false))
}

fn coll_iter_all(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("all expects (receiver, block)".into()));
    }
    let items = iterable_items(&ctx.args[0], "all")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    for v in items {
        if !matches!(host.invoke_callable(&block, std::slice::from_ref(&v), *out)?, Value::Bool(true)) {
            return Ok(Value::Bool(false));
        }
    }
    Ok(Value::Bool(true))
}

fn coll_iter_none(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let items = iterable_items(&ctx.args[0], "none")?;
    if ctx.args.len() == 1 {
        return Ok(Value::Bool(items.is_empty()));
    }
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    for v in items {
        if matches!(host.invoke_callable(&block, std::slice::from_ref(&v), *out)?, Value::Bool(true)) {
            return Ok(Value::Bool(false));
        }
    }
    Ok(Value::Bool(true))
}

fn coll_iter_fold(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 3 {
        return Err(RuntimeError::Arity("fold expects (receiver, initial, block)".into()));
    }
    let items = iterable_items(&ctx.args[0], "fold")?;
    let mut acc = ctx.args[1].clone();
    let block = ctx.args[2].clone();
    let CallCtx { out, host, .. } = ctx;
    for v in items {
        let lam_args = [acc.clone(), v];
        acc = host.invoke_callable(&block, &lam_args, *out)?;
    }
    Ok(acc)
}

fn coll_iter_reduce(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("reduce expects (receiver, block)".into()));
    }
    let items = iterable_items(&ctx.args[0], "reduce")?;
    let mut iter = items.into_iter();
    let Some(mut acc) = iter.next() else {
        return Err(RuntimeError::Thrown(Value::Exception {
            fqn: Rc::new("kotlin.UnsupportedOperationException".into()),
            message: Some(Rc::new("Empty collection can't be reduced.".into())),
            cause: None,
        }));
    };
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    for v in iter {
        let lam_args = [acc.clone(), v];
        acc = host.invoke_callable(&block, &lam_args, *out)?;
    }
    Ok(acc)
}

fn coll_iter_sum_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("sumOf expects (receiver, block)".into()));
    }
    let items = iterable_items(&ctx.args[0], "sumOf")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut acc_int: Option<i64> = Some(0);
    let mut acc_dbl: Option<f64> = None;
    for v in items {
        let r = host.invoke_callable(&block, std::slice::from_ref(&v), *out)?;
        if r.is_integral() {
            let n = r.as_i64().unwrap();
            if let Some(a) = acc_int.as_mut() {
                *a = a.wrapping_add(n);
            } else if let Some(a) = acc_dbl.as_mut() {
                *a += n as f64;
            }
        } else if r.is_floating() {
            let d = r.as_f64().unwrap();
            if let Some(a) = acc_int.take() {
                acc_dbl = Some(a as f64 + d);
            } else if let Some(a) = acc_dbl.as_mut() {
                *a += d;
            }
        } else {
            return Err(RuntimeError::Type(format!(
                "sumOf selector must return Int or Double, got {r:?}"
            )));
        }
    }
    Ok(match acc_dbl {
        Some(d) => Value::Double(d),
        None => Value::new_int(acc_int.unwrap_or(0)),
    })
}

fn coll_iter_take_while(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("takeWhile expects (receiver, block)".into()));
    }
    let items = iterable_items(&ctx.args[0], "takeWhile")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut result = Vec::new();
    for v in items {
        let r = host.invoke_callable(&block, std::slice::from_ref(&v), *out)?;
        if matches!(r, Value::Bool(true)) {
            result.push(v);
        } else {
            break;
        }
    }
    Ok(make_list(result, false))
}

fn coll_iter_drop_while(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("dropWhile expects (receiver, block)".into()));
    }
    let items = iterable_items(&ctx.args[0], "dropWhile")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut result = Vec::new();
    let mut dropping = true;
    for v in items {
        if dropping {
            let r = host.invoke_callable(&block, std::slice::from_ref(&v), *out)?;
            if matches!(r, Value::Bool(true)) {
                continue;
            }
            dropping = false;
        }
        result.push(v);
    }
    Ok(make_list(result, false))
}

fn coll_iter_partition(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("partition expects (receiver, block)".into()));
    }
    let items = iterable_items(&ctx.args[0], "partition")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut yes = Vec::new();
    let mut no = Vec::new();
    for v in items {
        let r = host.invoke_callable(&block, std::slice::from_ref(&v), *out)?;
        if matches!(r, Value::Bool(true)) {
            yes.push(v);
        } else {
            no.push(v);
        }
    }
    Ok(Value::Pair(Box::new(make_list(yes, false)), Box::new(make_list(no, false))))
}

fn coll_iter_distinct_by(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("distinctBy expects (receiver, block)".into()));
    }
    let items = iterable_items(&ctx.args[0], "distinctBy")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut keys: Vec<Value> = Vec::new();
    let mut result: Vec<Value> = Vec::new();
    for v in items {
        let key = host.invoke_callable(&block, std::slice::from_ref(&v), *out)?;
        if !keys.iter().any(|k| Value::structural_eq(k, &key)) {
            keys.push(key);
            result.push(v);
        }
    }
    Ok(make_list(result, false))
}

fn coll_iter_flat_map(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("flatMap expects (receiver, block)".into()));
    }
    let items = iterable_items(&ctx.args[0], "flatMap")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut result = Vec::new();
    for v in items {
        let r = host.invoke_callable(&block, std::slice::from_ref(&v), *out)?;
        match r {
            Value::List { items, .. } => result.extend(items.borrow().clone()),
            Value::Set { items, .. } => result.extend(items.borrow().clone()),
            other => {
                return Err(RuntimeError::Type(format!(
                    "flatMap selector must return a List/Set, got {other:?}"
                )))
            }
        }
    }
    Ok(make_list(result, false))
}

fn coll_iter_group_by(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("groupBy expects (receiver, block)".into()));
    }
    let items = iterable_items(&ctx.args[0], "groupBy")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut groups: Vec<(Value, Vec<Value>)> = Vec::new();
    for v in items {
        let key = host.invoke_callable(&block, std::slice::from_ref(&v), *out)?;
        if let Some(slot) = groups.iter_mut().find(|(k, _)| Value::structural_eq(k, &key)) {
            slot.1.push(v);
        } else {
            groups.push((key, vec![v]));
        }
    }
    let entries: Vec<(Value, Value)> = groups
        .into_iter()
        .map(|(k, vs)| (k, make_list(vs, false)))
        .collect();
    Ok(make_map(entries, false))
}

fn coll_iter_associate(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("associate expects (receiver, block)".into()));
    }
    let items = iterable_items(&ctx.args[0], "associate")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut entries: Vec<(Value, Value)> = Vec::new();
    for v in items {
        let r = host.invoke_callable(&block, std::slice::from_ref(&v), *out)?;
        let Value::Pair(k, val) = r else {
            return Err(RuntimeError::Type(
                "associate selector must return Pair".into(),
            ));
        };
        let key = *k;
        if let Some(slot) = entries.iter_mut().find(|(kk, _)| Value::structural_eq(kk, &key)) {
            slot.1 = *val;
        } else {
            entries.push((key, *val));
        }
    }
    Ok(make_map(entries, false))
}

fn coll_iter_associate_by(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("associateBy expects (receiver, block)".into()));
    }
    let items = iterable_items(&ctx.args[0], "associateBy")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut entries: Vec<(Value, Value)> = Vec::new();
    for v in items {
        let key = host.invoke_callable(&block, std::slice::from_ref(&v), *out)?;
        if let Some(slot) = entries.iter_mut().find(|(kk, _)| Value::structural_eq(kk, &key)) {
            slot.1 = v;
        } else {
            entries.push((key, v));
        }
    }
    Ok(make_map(entries, false))
}

fn coll_iter_associate_with(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("associateWith expects (receiver, block)".into()));
    }
    let items = iterable_items(&ctx.args[0], "associateWith")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut entries: Vec<(Value, Value)> = Vec::new();
    for v in items {
        let val = host.invoke_callable(&block, std::slice::from_ref(&v), *out)?;
        if let Some(slot) = entries.iter_mut().find(|(kk, _)| Value::structural_eq(kk, &v)) {
            slot.1 = val;
        } else {
            entries.push((v, val));
        }
    }
    Ok(make_map(entries, false))
}

fn coll_iter_sorted_by_impl(ctx: &mut CallCtx, descending: bool, what: &str) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity(format!("{what} expects (receiver, block)")));
    }
    let items = iterable_items(&ctx.args[0], what)?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut keyed: Vec<(Value, Value)> = Vec::with_capacity(items.len());
    for v in items {
        let key = host.invoke_callable(&block, std::slice::from_ref(&v), *out)?;
        keyed.push((key, v));
    }
    let mut err: Option<RuntimeError> = None;
    keyed.sort_by(|a, b| {
        if err.is_some() {
            return std::cmp::Ordering::Equal;
        }
        match compare_values(&a.0, &b.0) {
            Ok(o) => if descending { o.reverse() } else { o },
            Err(e) => {
                err = Some(e);
                std::cmp::Ordering::Equal
            }
        }
    });
    if let Some(e) = err {
        return Err(e);
    }
    Ok(make_list(keyed.into_iter().map(|(_, v)| v).collect(), false))
}

fn coll_iter_sorted_by(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    coll_iter_sorted_by_impl(ctx, false, "sortedBy")
}

fn coll_iter_sorted_by_desc(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    coll_iter_sorted_by_impl(ctx, true, "sortedByDescending")
}

fn coll_iter_extreme(ctx: &mut CallCtx, want_max: bool, what: &str) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity(format!("{what} expects (receiver, block)")));
    }
    let items = iterable_items(&ctx.args[0], what)?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut best: Option<Value> = None;
    for v in items {
        let r = host.invoke_callable(&block, std::slice::from_ref(&v), *out)?;
        best = Some(match best {
            None => r,
            Some(a) => {
                let ord = compare_values(&a, &r)?;
                match (want_max, ord) {
                    (true, std::cmp::Ordering::Less) => r,
                    (true, _) => a,
                    (false, std::cmp::Ordering::Greater) => r,
                    (false, _) => a,
                }
            }
        });
    }
    best.ok_or_else(|| RuntimeError::Thrown(Value::Exception {
        fqn: Rc::new("kotlin.NoSuchElementException".into()),
        message: Some(Rc::new("Collection is empty.".into())),
        cause: None,
    }))
}

fn coll_iter_max_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    coll_iter_extreme(ctx, true, "maxOf")
}

fn coll_iter_min_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    coll_iter_extreme(ctx, false, "minOf")
}

fn coll_iter_on_each(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("onEach expects (receiver, block)".into()));
    }
    let recv = ctx.args[0].clone();
    let items = iterable_items(&recv, "onEach")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    for v in items {
        host.invoke_callable(&block, std::slice::from_ref(&v), *out)?;
    }
    Ok(recv)
}

fn coll_iter_map_not_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("mapNotNull expects (receiver, block)".into()));
    }
    let items = iterable_items(&ctx.args[0], "mapNotNull")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut result = Vec::new();
    for v in items {
        let r = host.invoke_callable(&block, std::slice::from_ref(&v), *out)?;
        if !matches!(r, Value::Null) {
            result.push(r);
        }
    }
    Ok(make_list(result, false))
}

fn coll_iter_map_indexed(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("mapIndexed expects (receiver, block)".into()));
    }
    let items = iterable_items(&ctx.args[0], "mapIndexed")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut result = Vec::with_capacity(items.len());
    for (i, v) in items.into_iter().enumerate() {
        let lam_args = [Value::new_int(i as i64), v];
        result.push(host.invoke_callable(&block, &lam_args, *out)?);
    }
    Ok(make_list(result, false))
}

fn coll_iter_for_each_indexed(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("forEachIndexed expects (receiver, block)".into()));
    }
    let items = iterable_items(&ctx.args[0], "forEachIndexed")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    for (i, v) in items.into_iter().enumerate() {
        let lam_args = [Value::new_int(i as i64), v];
        host.invoke_callable(&block, &lam_args, *out)?;
    }
    Ok(Value::Unit)
}

fn coll_iter_filter_indexed(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("filterIndexed expects (receiver, block)".into()));
    }
    let items = iterable_items(&ctx.args[0], "filterIndexed")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut result = Vec::new();
    for (i, v) in items.into_iter().enumerate() {
        let lam_args = [Value::new_int(i as i64), v.clone()];
        let r = host.invoke_callable(&block, &lam_args, *out)?;
        if matches!(r, Value::Bool(true)) {
            result.push(v);
        }
    }
    Ok(make_list(result, false))
}

fn map_entries_clone(v: &Value, what: &str) -> Result<Vec<(Value, Value)>, RuntimeError> {
    match v {
        Value::Map { entries, .. } => Ok(entries.borrow().clone()),
        _ => Err(RuntimeError::Type(format!("{what} requires a Map receiver"))),
    }
}

fn map_filter_keys(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("filterKeys expects (receiver, block)".into()));
    }
    let entries = map_entries_clone(&ctx.args[0], "filterKeys")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut result = Vec::new();
    for (k, v) in entries {
        let r = host.invoke_callable(&block, std::slice::from_ref(&k), *out)?;
        if matches!(r, Value::Bool(true)) {
            result.push((k, v));
        }
    }
    Ok(make_map(result, false))
}

fn map_filter_values(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("filterValues expects (receiver, block)".into()));
    }
    let entries = map_entries_clone(&ctx.args[0], "filterValues")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut result = Vec::new();
    for (k, v) in entries {
        let r = host.invoke_callable(&block, std::slice::from_ref(&v), *out)?;
        if matches!(r, Value::Bool(true)) {
            result.push((k, v));
        }
    }
    Ok(make_map(result, false))
}

fn map_map_keys(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("mapKeys expects (receiver, block)".into()));
    }
    let entries = map_entries_clone(&ctx.args[0], "mapKeys")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut result = Vec::new();
    for (k, v) in entries {
        let entry = Value::MapEntry { key: Box::new(k.clone()), value: Box::new(v.clone()) };
        let new_k = host.invoke_callable(&block, std::slice::from_ref(&entry), *out)?;
        result.push((new_k, v));
    }
    Ok(make_map(result, false))
}

fn map_map_values(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("mapValues expects (receiver, block)".into()));
    }
    let entries = map_entries_clone(&ctx.args[0], "mapValues")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut result = Vec::new();
    for (k, v) in entries {
        let entry = Value::MapEntry { key: Box::new(k.clone()), value: Box::new(v.clone()) };
        let new_v = host.invoke_callable(&block, std::slice::from_ref(&entry), *out)?;
        result.push((k, new_v));
    }
    Ok(make_map(result, false))
}

fn coll_iter_find(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("find expects (receiver, block)".into()));
    }
    let items = iterable_items(&ctx.args[0], "find")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    for v in items {
        if matches!(host.invoke_callable(&block, std::slice::from_ref(&v), *out)?, Value::Bool(true)) {
            return Ok(v);
        }
    }
    Ok(Value::Null)
}

fn coll_iter_filter_not(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("filterNot expects (receiver, block)".into()));
    }
    let items = iterable_items(&ctx.args[0], "filterNot")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut result = Vec::new();
    for v in items {
        let r = host.invoke_callable(&block, std::slice::from_ref(&v), *out)?;
        if matches!(r, Value::Bool(false)) {
            result.push(v);
        }
    }
    Ok(make_list(result, false))
}

fn scope_repeat(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("repeat expects (times, block)".into()));
    }
    let times = ctx.args[0]
        .as_i64()
        .ok_or_else(|| RuntimeError::Type("repeat: first arg must be Int".into()))?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    for i in 0..times {
        let arg = Value::new_int(i);
        host.invoke_callable(&block, std::slice::from_ref(&arg), *out)?;
    }
    Ok(Value::Unit)
}

#[must_use]
pub fn lookup_param_names(fqn: &str) -> Option<&'static [&'static str]> {
    PARAM_NAMES
        .iter()
        .find_map(|(k, v)| if *k == fqn { Some(*v) } else { None })
}

#[must_use]
pub fn lookup(fqn: &str) -> Option<StdlibFn> {
    TABLE.iter().find(|(k, _)| *k == fqn).map(|(_, f)| *f)
}

pub fn all_fqns() -> impl Iterator<Item = &'static str> {
    TABLE.iter().map(|(k, _)| *k)
}

// ============================================================
// io
// ============================================================

fn io_println(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    match ctx.args {
        [] => {
            ctx.out.writeln("");
            Ok(Value::Unit)
        }
        [v] => {
            ctx.out.writeln(&format!("{v}"));
            Ok(Value::Unit)
        }
        _ => Err(RuntimeError::Arity(format!(
            "println expects 0 or 1 arguments, got {}",
            ctx.args.len()
        ))),
    }
}

fn io_print(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    match ctx.args {
        [] => Ok(Value::Unit),
        [v] => {
            ctx.out.write(&format!("{v}"));
            Ok(Value::Unit)
        }
        _ => Err(RuntimeError::Arity(format!(
            "print expects 0 or 1 arguments, got {}",
            ctx.args.len()
        ))),
    }
}

fn io_read_line(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let mut buf = String::new();
    match std::io::stdin().lock().read_line(&mut buf) {
        Ok(0) => Ok(Value::Null),
        Ok(_) => {
            if buf.ends_with('\n') {
                buf.pop();
                if buf.ends_with('\r') {
                    buf.pop();
                }
            }
            Ok(Value::String(Rc::new(buf)))
        }
        Err(e) => Err(RuntimeError::Type(format!("readLine failed: {e}"))),
    }
}

// ============================================================
// math
// ============================================================

fn as_double(v: &Value, what: &str) -> Result<f64, RuntimeError> {
    match v {
        Value::Double(d) => Ok(*d),
        Value::Int(n) => Ok(*n as f64),
        other => Err(RuntimeError::Type(format!("{what} requires a number, got {other:?}"))),
    }
}

fn math_abs(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    match ctx.args {
        [Value::Int(n)] => Ok(Value::Int(n.wrapping_abs())),
        [Value::Double(n)] => Ok(Value::Double(n.abs())),
        _ => Err(RuntimeError::Type("abs requires Int or Double".into())),
    }
}

fn math_min(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    match ctx.args {
        [Value::Int(a), Value::Int(b)] => Ok(Value::Int((*a).min(*b))),
        [Value::Double(a), Value::Double(b)] => Ok(Value::Double(a.min(*b))),
        _ => Err(RuntimeError::Type("min requires two Int or two Double args".into())),
    }
}

fn math_max(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    match ctx.args {
        [Value::Int(a), Value::Int(b)] => Ok(Value::Int((*a).max(*b))),
        [Value::Double(a), Value::Double(b)] => Ok(Value::Double(a.max(*b))),
        _ => Err(RuntimeError::Type("max requires two Int or two Double args".into())),
    }
}

fn math_sqrt(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let [v] = ctx.args else {
        return Err(RuntimeError::Arity("sqrt expects 1 argument".into()));
    };
    Ok(Value::Double(as_double(v, "sqrt")?.sqrt()))
}

/// `Double.pow(Double)` and `Double.pow(Int)` — Kotlin's only `pow` shape.
/// Receiver is `args[0]`, exponent is `args[1]`.
fn double_pow(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("Double.pow expects 1 argument".into()));
    }
    let base = recv_double(ctx.args, "Double.pow")?;
    let exp = as_double(&ctx.args[1], "Double.pow")?;
    Ok(Value::Double(base.powf(exp)))
}

fn math_sin(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(as_double(arg1(ctx, "sin")?, "sin")?.sin()))
}
fn math_cos(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(as_double(arg1(ctx, "cos")?, "cos")?.cos()))
}
fn math_tan(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(as_double(arg1(ctx, "tan")?, "tan")?.tan()))
}
fn math_ln(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(as_double(arg1(ctx, "ln")?, "ln")?.ln()))
}
fn math_log(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (x, base) = arg2(ctx, "log")?;
    Ok(Value::Double(as_double(x, "log")?.log(as_double(base, "log")?)))
}
fn math_log10(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(as_double(arg1(ctx, "log10")?, "log10")?.log10()))
}
fn math_log2(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(as_double(arg1(ctx, "log2")?, "log2")?.log2()))
}
fn math_exp(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(as_double(arg1(ctx, "exp")?, "exp")?.exp()))
}
fn math_floor(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(as_double(arg1(ctx, "floor")?, "floor")?.floor()))
}
fn math_ceil(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(as_double(arg1(ctx, "ceil")?, "ceil")?.ceil()))
}
fn math_round(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(as_double(arg1(ctx, "round")?, "round")?.round()))
}
fn math_truncate(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(as_double(arg1(ctx, "truncate")?, "truncate")?.trunc()))
}
fn math_hypot(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (a, b) = arg2(ctx, "hypot")?;
    Ok(Value::Double(as_double(a, "hypot")?.hypot(as_double(b, "hypot")?)))
}
fn math_sign(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = arg1(ctx, "sign")?;
    match v {
        Value::Int(n) => Ok(Value::Int(n.signum())),
        Value::Double(n) => Ok(Value::Double(n.signum())),
        other => Err(RuntimeError::Type(format!("sign requires a number, got {other:?}"))),
    }
}

fn math_pi(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(std::f64::consts::PI))
}
fn math_e(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(std::f64::consts::E))
}

fn arg1<'a>(ctx: &'a CallCtx<'_>, what: &str) -> Result<&'a Value, RuntimeError> {
    if ctx.args.len() != 1 {
        return Err(RuntimeError::Arity(format!("{what} expects 1 argument")));
    }
    Ok(&ctx.args[0])
}

fn arg2<'a>(ctx: &'a CallCtx<'_>, what: &str) -> Result<(&'a Value, &'a Value), RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity(format!("{what} expects 2 arguments")));
    }
    Ok((&ctx.args[0], &ctx.args[1]))
}

// ============================================================
// String members (receiver in args[0])
// ============================================================

fn recv_string<'a>(args: &'a [Value], what: &str) -> Result<&'a Rc<String>, RuntimeError> {
    match args.first() {
        Some(Value::String(s)) => Ok(s),
        Some(other) => Err(RuntimeError::Type(format!(
            "{what} requires a String receiver, got {other:?}"
        ))),
        None => Err(RuntimeError::Type(format!("{what} requires a receiver"))),
    }
}

fn arg_as_string(v: &Value, what: &str) -> Result<String, RuntimeError> {
    match v {
        Value::String(s) => Ok((**s).clone()),
        Value::Char(c) => Ok(c.to_string()),
        Value::Int(n) => Ok(n.to_string()),
        Value::Double(d) => Ok(d.to_string()),
        Value::Bool(b) => Ok(b.to_string()),
        other => Err(RuntimeError::Type(format!(
            "{what} requires a String-like argument, got {other:?}"
        ))),
    }
}

fn string_length(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.length")?;
    Ok(Value::new_int(s.chars().count()))
}

fn string_is_empty(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.isEmpty")?;
    Ok(Value::Bool(s.is_empty()))
}

fn string_is_not_empty(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.isNotEmpty")?;
    Ok(Value::Bool(!s.is_empty()))
}

fn string_is_blank(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.isBlank")?;
    Ok(Value::Bool(s.chars().all(char::is_whitespace)))
}

fn string_is_not_blank(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.isNotBlank")?;
    Ok(Value::Bool(s.chars().any(|c| !c.is_whitespace())))
}

fn string_uppercase(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.uppercase")?;
    Ok(Value::String(Rc::new(s.to_uppercase())))
}

fn string_lowercase(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.lowercase")?;
    Ok(Value::String(Rc::new(s.to_lowercase())))
}

fn string_plus(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.plus")?;
    let other = ctx
        .args
        .get(1)
        .ok_or_else(|| RuntimeError::Arity("String.plus requires one argument".into()))?;
    let mut joined = String::with_capacity(s.len());
    joined.push_str(s);
    joined.push_str(&format!("{other}"));
    Ok(Value::String(Rc::new(joined)))
}

fn string_get(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.get")?;
    let Some(Value::Int(idx)) = ctx.args.get(1) else {
        return Err(RuntimeError::Type("String.get requires an Int index".into()));
    };
    if *idx < 0 {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IndexOutOfBoundsException",
            Some(format!("index {idx} out of bounds")),
        )));
    }
    let i = *idx as usize;
    match s.chars().nth(i) {
        Some(c) => Ok(Value::Char(c)),
        None => Err(RuntimeError::Thrown(make_exception(
            "kotlin.IndexOutOfBoundsException",
            Some(format!("index {idx} out of bounds (length {})", s.chars().count())),
        ))),
    }
}

fn string_substring(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.substring")?;
    let chars: Vec<char> = s.chars().collect();
    let len = chars.len() as i64;
    let (start, end) = match &ctx.args[1..] {
        [s] if s.is_integral() => (s.as_i64().unwrap(), len),
        [a, b] if a.is_integral() && b.is_integral() => {
            (a.as_i64().unwrap(), b.as_i64().unwrap())
        }
        _ => return Err(RuntimeError::Arity("substring requires 1 or 2 Int args".into())),
    };
    if start < 0 || end > len || start > end {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IndexOutOfBoundsException",
            Some(format!("substring({start},{end}) on length {len}")),
        )));
    }
    let out: String = chars[start as usize..end as usize].iter().collect();
    Ok(Value::String(Rc::new(out)))
}

fn string_starts_with(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.startsWith")?;
    let prefix = arg_as_string(
        ctx.args
            .get(1)
            .ok_or_else(|| RuntimeError::Arity("startsWith requires an argument".into()))?,
        "startsWith",
    )?;
    Ok(Value::Bool(s.starts_with(&prefix)))
}

fn string_ends_with(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.endsWith")?;
    let suffix = arg_as_string(
        ctx.args
            .get(1)
            .ok_or_else(|| RuntimeError::Arity("endsWith requires an argument".into()))?,
        "endsWith",
    )?;
    Ok(Value::Bool(s.ends_with(&suffix)))
}

fn string_contains(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.contains")?;
    let needle = arg_as_string(
        ctx.args
            .get(1)
            .ok_or_else(|| RuntimeError::Arity("contains requires an argument".into()))?,
        "contains",
    )?;
    Ok(Value::Bool(s.contains(&needle)))
}

fn string_index_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.indexOf")?;
    let needle = arg_as_string(
        ctx.args
            .get(1)
            .ok_or_else(|| RuntimeError::Arity("indexOf requires an argument".into()))?,
        "indexOf",
    )?;
    Ok(Value::new_int(byte_to_char_index(s, s.find(&needle))))
}

fn string_last_index_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.lastIndexOf")?;
    let needle = arg_as_string(
        ctx.args
            .get(1)
            .ok_or_else(|| RuntimeError::Arity("lastIndexOf requires an argument".into()))?,
        "lastIndexOf",
    )?;
    Ok(Value::new_int(byte_to_char_index(s, s.rfind(&needle))))
}

fn byte_to_char_index(s: &str, byte: Option<usize>) -> i64 {
    let Some(b) = byte else { return -1 };
    s[..b].chars().count() as i64
}

fn string_replace(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.replace")?;
    if let Some(Value::Regex(r)) = ctx.args.get(1) {
        let repl = match ctx.args.get(2) {
            Some(Value::String(s)) => (**s).clone(),
            _ => return Err(RuntimeError::Type(
                "replace(Regex, replacement: String) — lambda form not supported".into(),
            )),
        };
        return Ok(Value::String(Rc::new(
            r.re.replace_all(s, repl.as_str()).into_owned(),
        )));
    }
    let old = arg_as_string(
        ctx.args
            .get(1)
            .ok_or_else(|| RuntimeError::Arity("replace requires old".into()))?,
        "replace",
    )?;
    let new = arg_as_string(
        ctx.args
            .get(2)
            .ok_or_else(|| RuntimeError::Arity("replace requires new".into()))?,
        "replace",
    )?;
    Ok(Value::String(Rc::new(s.replace(&old, &new))))
}

fn string_trim(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.trim")?;
    Ok(Value::String(Rc::new(s.trim().to_string())))
}
fn string_trim_start(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.trimStart")?;
    Ok(Value::String(Rc::new(s.trim_start().to_string())))
}
fn string_trim_end(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.trimEnd")?;
    Ok(Value::String(Rc::new(s.trim_end().to_string())))
}

fn string_repeat(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.repeat")?;
    let Some(Value::Int(n)) = ctx.args.get(1) else {
        return Err(RuntimeError::Type("repeat requires an Int count".into()));
    };
    if *n < 0 {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IllegalArgumentException",
            Some(format!("Count `n` must be non-negative, but was {n}")),
        )));
    }
    Ok(Value::String(Rc::new(s.repeat(*n as usize))))
}

fn string_reversed(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.reversed")?;
    Ok(Value::String(Rc::new(s.chars().rev().collect())))
}

fn string_pad_start(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (s, target, pad) = string_pad_args(ctx, "padStart")?;
    let cur = s.chars().count();
    if cur >= target {
        return Ok(Value::String(Rc::new((**s).clone())));
    }
    let needed = target - cur;
    let mut out = String::with_capacity(s.len() + needed);
    for _ in 0..needed {
        out.push(pad);
    }
    out.push_str(s);
    Ok(Value::String(Rc::new(out)))
}

fn string_pad_end(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (s, target, pad) = string_pad_args(ctx, "padEnd")?;
    let cur = s.chars().count();
    if cur >= target {
        return Ok(Value::String(Rc::new((**s).clone())));
    }
    let needed = target - cur;
    let mut out = String::with_capacity(s.len() + needed);
    out.push_str(s);
    for _ in 0..needed {
        out.push(pad);
    }
    Ok(Value::String(Rc::new(out)))
}

#[allow(clippy::type_complexity)]
fn string_pad_args<'a>(
    ctx: &'a CallCtx<'_>,
    what: &str,
) -> Result<(&'a Rc<String>, usize, char), RuntimeError> {
    let s = recv_string(ctx.args, what)?;
    let target = match ctx.args.get(1) {
        Some(Value::Int(n)) if *n >= 0 => *n as usize,
        _ => return Err(RuntimeError::Type(format!("{what} requires non-negative Int length"))),
    };
    let pad = match ctx.args.get(2) {
        None => ' ',
        Some(Value::Char(c)) => *c,
        Some(other) => {
            return Err(RuntimeError::Type(format!(
                "{what} pad must be a Char, got {other:?}"
            )))
        }
    };
    Ok((s, target, pad))
}

fn string_compare_to(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.compareTo")?;
    let Some(Value::String(other)) = ctx.args.get(1) else {
        return Err(RuntimeError::Type("compareTo requires a String".into()));
    };
    let r = crate::text::compare_utf16(s, other);
    Ok(Value::Int(match r {
        std::cmp::Ordering::Less => -1,
        std::cmp::Ordering::Equal => 0,
        std::cmp::Ordering::Greater => 1,
    }))
}

fn string_to_int(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.toInt")?;
    let radix = recv_int_radix(ctx.args.get(1), "String.toInt")?;
    if !(2..=36).contains(&radix) {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IllegalArgumentException",
            Some(format!("radix {radix} was not in valid range 2..36")),
        )));
    }
    parse_int_radix(&s, radix as u32).map(Value::new_int).map_err(|_| {
        RuntimeError::Thrown(make_exception(
            "kotlin.NumberFormatException",
            Some(format!("For input string: \"{s}\"")),
        ))
    })
}

fn string_to_int_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.toIntOrNull")?;
    let radix = match recv_int_radix(ctx.args.get(1), "String.toIntOrNull") {
        Ok(r) => r,
        Err(_) => return Ok(Value::Null),
    };
    if !(2..=36).contains(&radix) {
        return Ok(Value::Null);
    }
    Ok(parse_int_radix(&s, radix as u32).map(Value::new_int).unwrap_or(Value::Null))
}

fn parse_int_radix(s: &str, radix: u32) -> Result<i64, ()> {
    let s = s.trim();
    if s.is_empty() {
        return Err(());
    }
    let (negative, body) = if let Some(rest) = s.strip_prefix('-') {
        (true, rest)
    } else if let Some(rest) = s.strip_prefix('+') {
        (false, rest)
    } else {
        (false, s)
    };
    if body.is_empty() {
        return Err(());
    }
    let mut acc: i64 = 0;
    for ch in body.chars() {
        let d = ch.to_digit(radix).ok_or(())?;
        acc = acc.checked_mul(radix as i64).ok_or(())?;
        acc = acc.checked_add(d as i64).ok_or(())?;
    }
    if negative { acc = acc.checked_neg().ok_or(())?; }
    Ok(acc)
}

fn string_to_list(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.toList")?;
    let items: Vec<Value> = s.chars().map(Value::Char).collect();
    Ok(make_list(items, false))
}

fn string_split(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.split")?;
    if let Some(Value::Regex(r)) = ctx.args.get(1) {
        let limit = match ctx.args.get(2) {
            None => 0i64,
            Some(v) if v.is_integral() => v.as_i64().unwrap(),
            _ => return Err(RuntimeError::Type("split limit must be Int".into())),
        };
        let parts: Vec<&str> = if limit <= 0 {
            r.re.split(s).collect()
        } else {
            r.re.splitn(s, limit as usize).collect()
        };
        let items: Vec<Value> = parts
            .into_iter()
            .map(|p| Value::String(Rc::new(p.to_string())))
            .collect();
        return Ok(make_list(items, false));
    }
    let delim = match ctx.args.get(1) {
        Some(Value::String(d)) => (**d).clone(),
        Some(Value::Char(c)) => c.to_string(),
        _ => {
            return Err(RuntimeError::Type(
                "String.split requires a String, Char, or Regex delimiter".into(),
            ))
        }
    };
    let parts: Vec<Value> = if delim.is_empty() {
        s.chars().map(|c| Value::String(Rc::new(c.to_string()))).collect()
    } else {
        s.split(&delim)
            .map(|p| Value::String(Rc::new(p.to_string())))
            .collect()
    };
    Ok(make_list(parts, false))
}

fn string_chunked(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.chunked")?;
    let Some(Value::Int(size)) = ctx.args.get(1) else {
        return Err(RuntimeError::Type("chunked requires an Int size".into()));
    };
    if *size <= 0 {
        return Err(RuntimeError::Thrown(Value::Exception {
            fqn: Rc::new("kotlin.IllegalArgumentException".into()),
            message: Some(Rc::new(format!("Size {size} must be greater than zero."))),
            cause: None,
        }));
    }
    let size = *size as usize;
    let chars: Vec<char> = s.chars().collect();
    let mut out: Vec<Value> = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        let end = (i + size).min(chars.len());
        let chunk: String = chars[i..end].iter().collect();
        out.push(Value::String(Rc::new(chunk)));
        i += size;
    }
    Ok(make_list(out, false))
}

fn string_windowed(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.windowed")?;
    let Some(Value::Int(size)) = ctx.args.get(1) else {
        return Err(RuntimeError::Type("windowed requires an Int size".into()));
    };
    if *size <= 0 {
        return Err(RuntimeError::Thrown(Value::Exception {
            fqn: Rc::new("kotlin.IllegalArgumentException".into()),
            message: Some(Rc::new(format!("size {size} must be greater than zero."))),
            cause: None,
        }));
    }
    let step = match ctx.args.get(2) {
        None => 1i64,
        Some(v) if v.is_integral() => v.as_i64().unwrap(),
        _ => return Err(RuntimeError::Type("windowed step must be Int".into())),
    };
    let partial = match ctx.args.get(3) {
        None => false,
        Some(Value::Bool(b)) => *b,
        _ => return Err(RuntimeError::Type("windowed partialWindows must be Bool".into())),
    };
    if step <= 0 {
        return Err(RuntimeError::Thrown(Value::Exception {
            fqn: Rc::new("kotlin.IllegalArgumentException".into()),
            message: Some(Rc::new(format!("step {step} must be greater than zero."))),
            cause: None,
        }));
    }
    let chars: Vec<char> = s.chars().collect();
    let size = *size as usize;
    let step = step as usize;
    let mut out: Vec<Value> = Vec::new();
    let mut i = 0usize;
    while i < chars.len() {
        let end = i + size;
        if end <= chars.len() {
            let win: String = chars[i..end].iter().collect();
            out.push(Value::String(Rc::new(win)));
        } else if partial {
            let win: String = chars[i..].iter().collect();
            out.push(Value::String(Rc::new(win)));
        } else {
            break;
        }
        i += step;
    }
    Ok(make_list(out, false))
}

fn string_to_double(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.toDouble")?;
    s.parse::<f64>()
        .map(Value::Double)
        .map_err(|_| {
            RuntimeError::Thrown(make_exception(
                "kotlin.NumberFormatException",
                Some(format!("For input string: \"{s}\"")),
            ))
        })
}

// ============================================================
// Char members
// ============================================================

fn recv_char(args: &[Value], what: &str) -> Result<char, RuntimeError> {
    match args.first() {
        Some(Value::Char(c)) => Ok(*c),
        Some(other) => Err(RuntimeError::Type(format!(
            "{what} requires a Char receiver, got {other:?}"
        ))),
        None => Err(RuntimeError::Type(format!("{what} requires a receiver"))),
    }
}

fn char_code(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::new_int(u32::from(recv_char(ctx.args, "Char.code")?)))
}
// Char predicates follow kotlinc-native 2.3.21 semantics, driven by Unicode
// general categories rather than Rust's `char::is_*` (which differ on a
// handful of historic scripts, special whitespace, and digit ranges).

fn kt_is_letter(c: char) -> bool {
    use unicode_general_category::GeneralCategory as G;
    matches!(
        unicode_general_category::get_general_category(c),
        G::UppercaseLetter | G::LowercaseLetter | G::TitlecaseLetter | G::ModifierLetter | G::OtherLetter
    )
}

fn kt_is_digit(c: char) -> bool {
    use unicode_general_category::GeneralCategory as G;
    unicode_general_category::get_general_category(c) == G::DecimalNumber
}

// kotlinc-native 2.3.21 whitespace table (from stdlib/native-wasm
// _WhitespaceChars.kt). This is a fixed enumerated set — not Java's
// Character.isWhitespace (which excludes NBSP) and not Rust's
// char::is_whitespace (which excludes 0x1C..=0x1F).
fn kt_is_whitespace(c: char) -> bool {
    let code = c as u32;
    matches!(
        code,
        0x0009..=0x000D
            | 0x001C..=0x0020
            | 0x00A0
            | 0x1680
            | 0x2000..=0x200A
            | 0x2028
            | 0x2029
            | 0x202F
            | 0x205F
            | 0x3000
    )
}

fn is_other_uppercase(code: u32) -> bool {
    matches!(code, 0x2160..=0x216F | 0x24B6..=0x24CF | 0x1F130..=0x1F149 | 0x1F150..=0x1F169 | 0x1F170..=0x1F189)
}

// Other_Lowercase contributory property (Unicode 15.x snapshot used by kotlinc-native 2.3.21).
fn is_other_lowercase(code: u32) -> bool {
    const RANGES: &[(u32, u32)] = &[
        (0x00AA, 0x00AA), (0x00BA, 0x00BA), (0x02B0, 0x02B8), (0x02C0, 0x02C1),
        (0x02E0, 0x02E4), (0x0345, 0x0345), (0x037A, 0x037A), (0x1D2C, 0x1D6A),
        (0x1D78, 0x1D78), (0x1D9B, 0x1DBF), (0x2071, 0x2071), (0x207F, 0x207F),
        (0x2090, 0x209C), (0x2170, 0x217F), (0x24D0, 0x24E9), (0x2C7C, 0x2C7D),
        (0xA69C, 0xA69D), (0xA770, 0xA770), (0xA7F8, 0xA7F9), (0xAB5C, 0xAB5F),
    ];
    RANGES.iter().any(|&(lo, hi)| code >= lo && code <= hi)
}

fn kt_is_upper_case(c: char) -> bool {
    use unicode_general_category::GeneralCategory as G;
    unicode_general_category::get_general_category(c) == G::UppercaseLetter
        || is_other_uppercase(c as u32)
}

fn kt_is_lower_case(c: char) -> bool {
    use unicode_general_category::GeneralCategory as G;
    unicode_general_category::get_general_category(c) == G::LowercaseLetter
        || is_other_lowercase(c as u32)
}

fn char_is_digit(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Bool(kt_is_digit(recv_char(ctx.args, "Char.isDigit")?)))
}
fn char_is_letter(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Bool(kt_is_letter(recv_char(ctx.args, "Char.isLetter")?)))
}
fn char_is_letter_or_digit(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let c = recv_char(ctx.args, "Char.isLetterOrDigit")?;
    Ok(Value::Bool(kt_is_letter(c) || kt_is_digit(c)))
}
fn char_is_whitespace(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Bool(kt_is_whitespace(recv_char(ctx.args, "Char.isWhitespace")?)))
}
fn char_is_uppercase(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Bool(kt_is_upper_case(recv_char(ctx.args, "Char.isUpperCase")?)))
}
fn char_is_lowercase(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Bool(kt_is_lower_case(recv_char(ctx.args, "Char.isLowerCase")?)))
}
fn char_uppercase(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let c = recv_char(ctx.args, "Char.uppercase")?;
    let mut up = c.to_uppercase();
    Ok(Value::String(Rc::new(up.next().map_or(String::new(), |x| {
        let rest: String = up.collect();
        format!("{x}{rest}")
    }))))
}
fn char_lowercase(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let c = recv_char(ctx.args, "Char.lowercase")?;
    let mut lo = c.to_lowercase();
    Ok(Value::String(Rc::new(lo.next().map_or(String::new(), |x| {
        let rest: String = lo.collect();
        format!("{x}{rest}")
    }))))
}
fn char_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::String(Rc::new(recv_char(ctx.args, "Char.toString")?.to_string())))
}
fn char_digit_to_int(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let c = recv_char(ctx.args, "Char.digitToInt")?;
    match c.to_digit(10) {
        Some(d) => Ok(Value::new_int(d)),
        None => Err(RuntimeError::Thrown(make_exception(
            "kotlin.IllegalArgumentException",
            Some(format!("Char {c:?} is not a digit")),
        ))),
    }
}

// ============================================================
// Int members
// ============================================================

fn recv_int(args: &[Value], what: &str) -> Result<i64, RuntimeError> {
    args.first()
        .and_then(Value::as_i64)
        .ok_or_else(|| RuntimeError::Type(format!("{what} requires an integer receiver")))
}

fn recv_int_radix(v: Option<&Value>, what: &str) -> Result<i64, RuntimeError> {
    match v {
        None => Ok(10),
        Some(v) => v.as_i64().ok_or_else(|| {
            RuntimeError::Type(format!("{what} radix must be Int"))
        }),
    }
}

fn int_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let n = recv_int(ctx.args, "Int.toString")?;
    let radix = recv_int_radix(ctx.args.get(1), "Int.toString")?;
    if !(2..=36).contains(&radix) {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IllegalArgumentException",
            Some(format!("radix {radix} was not in valid range 2..36")),
        )));
    }
    Ok(Value::String(Rc::new(int_to_radix_string(n, radix as u32))))
}

fn int_to_radix_string(n: i64, radix: u32) -> String {
    if n == 0 {
        return "0".to_string();
    }
    let negative = n < 0;
    let mut x = if negative {
        // Cast through i128 to handle i64::MIN. Kotlin renders the absolute
        // digit run with a leading `-`.
        (n as i128).unsigned_abs()
    } else {
        n as u128
    };
    let mut digits = Vec::new();
    while x > 0 {
        let d = (x % radix as u128) as u32;
        x /= radix as u128;
        digits.push(std::char::from_digit(d, radix).unwrap());
    }
    if negative {
        digits.push('-');
    }
    digits.iter().rev().collect()
}

fn int_to_long(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Long(recv_int(ctx.args, "Int.toLong")?))
}
fn int_to_double(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(recv_int(ctx.args, "Int.toDouble")? as f64))
}
fn int_to_float(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Float(recv_int(ctx.args, "Int.toFloat")? as f32))
}
fn int_to_int(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    // Identity for Int receivers; truncates Long/Short/Byte if any caller
    // routes through this slot.
    Ok(Value::new_int((recv_int(ctx.args, "Int.toInt")?) as i32))
}
fn int_to_short(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::new_short(recv_int(ctx.args, "Int.toShort")?))
}
fn int_to_byte(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::new_byte(recv_int(ctx.args, "Int.toByte")?))
}

// Long-only conversion methods (when the receiver is `Value::Long`).
// These intentionally mirror the Int-family — `recv_int` widens any
// integral receiver to i64, so they cover Long, Int, Short, Byte.
fn long_to_long(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Long(recv_int(ctx.args, "Long.toLong")?))
}
fn long_to_int(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::new_int(recv_int(ctx.args, "Long.toInt")?))
}
fn long_to_short(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::new_short(recv_int(ctx.args, "Long.toShort")?))
}
fn long_to_byte(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::new_byte(recv_int(ctx.args, "Long.toByte")?))
}
fn long_to_double(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(recv_int(ctx.args, "Long.toDouble")? as f64))
}
fn long_to_float(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Float(recv_int(ctx.args, "Long.toFloat")? as f32))
}

fn recv_unsigned(args: &[Value], what: &str) -> Result<u64, RuntimeError> {
    args.first()
        .and_then(Value::as_u64)
        .ok_or_else(|| RuntimeError::Type(format!("{what} requires an integer receiver")))
}

fn to_ubyte(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::UByte(recv_unsigned(ctx.args, "toUByte")? as u8))
}
fn to_ushort(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::UShort(recv_unsigned(ctx.args, "toUShort")? as u16))
}
fn to_uint(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::UInt(recv_unsigned(ctx.args, "toUInt")? as u32))
}
fn to_ulong(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::ULong(recv_unsigned(ctx.args, "toULong")?))
}
fn unsigned_to_int(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::new_int(recv_unsigned(ctx.args, "toInt")? as i64))
}
fn unsigned_to_long(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Long(recv_unsigned(ctx.args, "toLong")? as i64))
}
fn unsigned_to_short(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::new_short(recv_unsigned(ctx.args, "toShort")? as i64))
}
fn unsigned_to_byte(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::new_byte(recv_unsigned(ctx.args, "toByte")? as i64))
}
fn unsigned_to_double(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(recv_unsigned(ctx.args, "toDouble")? as f64))
}
fn unsigned_to_float(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Float(recv_unsigned(ctx.args, "toFloat")? as f32))
}
fn unsigned_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = recv_unsigned(ctx.args, "toString")?;
    Ok(Value::String(std::rc::Rc::new(v.to_string())))
}

// Float receiver conversions.
fn float_to_double(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(recv_float(ctx.args, "Float.toDouble")? as f64))
}
fn float_to_float(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Float(recv_float(ctx.args, "Float.toFloat")?))
}
fn float_to_int(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::new_int(f32_to_i32_kotlin(recv_float(ctx.args, "Float.toInt")?)))
}
fn float_to_long(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Long(f32_to_i64_kotlin(recv_float(ctx.args, "Float.toLong")?)))
}
fn float_to_short(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::new_short(f32_to_i32_kotlin(recv_float(ctx.args, "Float.toShort")?)))
}
fn float_to_byte(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::new_byte(f32_to_i32_kotlin(recv_float(ctx.args, "Float.toByte")?)))
}

fn float_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let d = recv_float(ctx.args, "Float.toString")?;
    Ok(Value::String(Rc::new(klio_runtime::kotlin_float_to_string(d))))
}
fn float_is_nan(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Bool(recv_float(ctx.args, "Float.isNaN")?.is_nan()))
}
fn float_is_infinite(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Bool(recv_float(ctx.args, "Float.isInfinite")?.is_infinite()))
}
fn float_is_finite(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Bool(recv_float(ctx.args, "Float.isFinite")?.is_finite()))
}
fn float_compare_to(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let a = recv_float(ctx.args, "Float.compareTo")?;
    let b = ctx.args.get(1).and_then(Value::as_f32).ok_or_else(|| {
        RuntimeError::Type("Float.compareTo requires a number".into())
    })?;
    Ok(Value::new_int(a.partial_cmp(&b).map_or(0, |o| match o {
        std::cmp::Ordering::Less => -1,
        std::cmp::Ordering::Equal => 0,
        std::cmp::Ordering::Greater => 1,
    })))
}

// Double additional conversions (Float).
fn double_to_float(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Float(recv_double(ctx.args, "Double.toFloat")? as f32))
}
fn double_to_double(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(recv_double(ctx.args, "Double.toDouble")?))
}
fn double_to_short(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::new_short(f64_to_i32_kotlin(recv_double(ctx.args, "Double.toShort")?)))
}
fn double_to_byte(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::new_byte(f64_to_i32_kotlin(recv_double(ctx.args, "Double.toByte")?)))
}

fn int_binop<F: Fn(i32, i32) -> i32>(
    ctx: &CallCtx<'_>,
    what: &str,
    op: F,
) -> Result<Value, RuntimeError> {
    let a = recv_int(ctx.args, what)? as i32;
    let Some(b) = ctx.args.get(1).and_then(Value::as_i64) else {
        return Err(RuntimeError::Type(format!("{what} requires an Int argument")));
    };
    Ok(Value::new_int(op(a, b as i32)))
}

fn int_and(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    int_binop(ctx, "Int.and", |a, b| a & b)
}
fn int_or(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    int_binop(ctx, "Int.or", |a, b| a | b)
}
fn int_xor(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    int_binop(ctx, "Int.xor", |a, b| a ^ b)
}
fn int_inv(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::new_int(!recv_int(ctx.args, "Int.inv")?))
}
fn int_shl(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    int_binop(ctx, "Int.shl", |a, b| a.wrapping_shl((b & 31) as u32))
}
fn int_shr(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    int_binop(ctx, "Int.shr", |a, b| a.wrapping_shr((b & 31) as u32))
}
fn int_ushr(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    int_binop(ctx, "Int.ushr", |a, b| ((a as u32).wrapping_shr((b & 31) as u32)) as i32)
}

fn long_binop<F: Fn(i64, i64) -> i64>(
    ctx: &CallCtx<'_>,
    what: &str,
    op: F,
) -> Result<Value, RuntimeError> {
    let a = recv_int(ctx.args, what)?;
    let Some(b) = ctx.args.get(1).and_then(Value::as_i64) else {
        return Err(RuntimeError::Type(format!("{what} requires a Long argument")));
    };
    Ok(Value::Long(op(a, b)))
}
fn long_and(ctx: &mut CallCtx) -> Result<Value, RuntimeError> { long_binop(ctx, "Long.and", |a, b| a & b) }
fn long_or(ctx: &mut CallCtx) -> Result<Value, RuntimeError> { long_binop(ctx, "Long.or", |a, b| a | b) }
fn long_xor(ctx: &mut CallCtx) -> Result<Value, RuntimeError> { long_binop(ctx, "Long.xor", |a, b| a ^ b) }
fn long_inv(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Long(!recv_int(ctx.args, "Long.inv")?))
}
fn long_shl(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    long_binop(ctx, "Long.shl", |a, b| a.wrapping_shl((b & 63) as u32))
}
fn long_shr(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    long_binop(ctx, "Long.shr", |a, b| a.wrapping_shr((b & 63) as u32))
}
fn long_ushr(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    long_binop(ctx, "Long.ushr", |a, b| ((a as u64).wrapping_shr((b & 63) as u32)) as i64)
}
fn long_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let n = recv_int(ctx.args, "Long.toString")?;
    let radix = recv_int_radix(ctx.args.get(1), "Long.toString")?;
    if !(2..=36).contains(&radix) {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IllegalArgumentException",
            Some(format!("radix {radix} was not in valid range 2..36")),
        )));
    }
    Ok(Value::String(Rc::new(int_to_radix_string(n, radix as u32))))
}
fn long_compare_to(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let a = recv_int(ctx.args, "Long.compareTo")?;
    let Some(b) = ctx.args.get(1).and_then(Value::as_i64) else {
        return Err(RuntimeError::Type("Long.compareTo requires a Long".into()));
    };
    Ok(Value::Int(if a < b { -1 } else if a > b { 1 } else { 0 }))
}
fn int_compare_to(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let a = recv_int(ctx.args, "Int.compareTo")?;
    let Some(b) = ctx.args.get(1).and_then(Value::as_i64) else {
        return Err(RuntimeError::Type("Int.compareTo requires an Int".into()));
    };
    Ok(Value::Int(if a < b { -1 } else if a > b { 1 } else { 0 }))
}

// ============================================================
// Double members
// ============================================================

fn recv_double(args: &[Value], what: &str) -> Result<f64, RuntimeError> {
    args.first()
        .and_then(Value::as_f64)
        .ok_or_else(|| RuntimeError::Type(format!("{what} requires a numeric receiver")))
}

fn recv_float(args: &[Value], what: &str) -> Result<f32, RuntimeError> {
    args.first()
        .and_then(Value::as_f32)
        .ok_or_else(|| RuntimeError::Type(format!("{what} requires a numeric receiver")))
}

fn double_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let d = recv_double(ctx.args, "Double.toString")?;
    Ok(Value::String(Rc::new(klio_runtime::kotlin_double_to_string(d))))
}
fn double_to_int(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::new_int(f64_to_i32_kotlin(recv_double(ctx.args, "Double.toInt")?)))
}
fn double_to_long(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Long(f64_to_i64_kotlin(recv_double(ctx.args, "Double.toLong")?)))
}

/// Kotlin's `Double.toInt` semantics: truncate toward zero, saturate at
/// `Int.MIN_VALUE`/`Int.MAX_VALUE` for out-of-range, `NaN → 0`.
fn f64_to_i32_kotlin(d: f64) -> i32 {
    if d.is_nan() {
        return 0;
    }
    if d >= i32::MAX as f64 {
        return i32::MAX;
    }
    if d <= i32::MIN as f64 {
        return i32::MIN;
    }
    d as i32
}

fn f64_to_i64_kotlin(d: f64) -> i64 {
    if d.is_nan() {
        return 0;
    }
    if d >= i64::MAX as f64 {
        return i64::MAX;
    }
    if d <= i64::MIN as f64 {
        return i64::MIN;
    }
    d as i64
}

fn f32_to_i32_kotlin(d: f32) -> i32 {
    if d.is_nan() {
        return 0;
    }
    if d >= i32::MAX as f32 {
        return i32::MAX;
    }
    if d <= i32::MIN as f32 {
        return i32::MIN;
    }
    d as i32
}

fn f32_to_i64_kotlin(d: f32) -> i64 {
    if d.is_nan() {
        return 0;
    }
    if d >= i64::MAX as f32 {
        return i64::MAX;
    }
    if d <= i64::MIN as f32 {
        return i64::MIN;
    }
    d as i64
}
fn double_is_nan(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Bool(recv_double(ctx.args, "Double.isNaN")?.is_nan()))
}
fn double_is_infinite(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Bool(recv_double(ctx.args, "Double.isInfinite")?.is_infinite()))
}
fn double_is_finite(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Bool(recv_double(ctx.args, "Double.isFinite")?.is_finite()))
}
fn double_compare_to(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let a = recv_double(ctx.args, "Double.compareTo")?;
    let b = ctx.args.get(1).and_then(Value::as_f64).ok_or_else(|| {
        RuntimeError::Type("Double.compareTo requires a number".into())
    })?;
    Ok(Value::Int(a.partial_cmp(&b).map_or(0, |o| match o {
        std::cmp::Ordering::Less => -1,
        std::cmp::Ordering::Equal => 0,
        std::cmp::Ordering::Greater => 1,
    })))
}

// ============================================================
// Boolean members
// ============================================================

fn bool_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(Value::Bool(b)) = ctx.args.first() else {
        return Err(RuntimeError::Type("Boolean.toString requires a Boolean".into()));
    };
    Ok(Value::String(Rc::new(b.to_string())))
}

// ============================================================
// Exceptions
// ============================================================

fn make_exception(fqn: &str, message: Option<String>) -> Value {
    Value::Exception {
        fqn: Rc::new(fqn.to_string()),
        message: message.map(Rc::new),
        cause: None,
    }
}

fn build_exception(ctx: &CallCtx<'_>, fqn: &str) -> Result<Value, RuntimeError> {
    // Throwable accepts up to two arguments per spec §3.12:
    //   (), (message), (cause), (message, cause).
    // A single Throwable-typed argument is treated as `cause`; anything else
    // becomes `message`.
    let (message, cause) = match (ctx.args.first(), ctx.args.get(1)) {
        (None, _) => (None, None),
        (Some(v), None) => {
            if matches!(v, Value::Exception { .. }) {
                (None, Some(Box::new(v.clone())))
            } else {
                let m = match v {
                    Value::Null => None,
                    Value::String(s) => Some((**s).clone()),
                    other => Some(format!("{other}")),
                };
                (m, None)
            }
        }
        (Some(m), Some(c)) => {
            let msg = match m {
                Value::Null => None,
                Value::String(s) => Some((**s).clone()),
                other => Some(format!("{other}")),
            };
            let cause = match c {
                Value::Null => None,
                Value::Exception { .. } => Some(Box::new(c.clone())),
                _ => return Err(RuntimeError::Type(
                    "Throwable cause must be a Throwable or null".into(),
                )),
            };
            (msg, cause)
        }
    };
    Ok(Value::Exception {
        fqn: Rc::new(fqn.to_string()),
        message: message.map(Rc::new),
        cause,
    })
}

fn excn_throwable(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    build_exception(ctx, "kotlin.Throwable")
}
fn excn_exception(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    build_exception(ctx, "kotlin.Exception")
}
fn excn_error(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    build_exception(ctx, "kotlin.Error")
}
fn excn_runtime(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    build_exception(ctx, "kotlin.RuntimeException")
}
fn excn_illegal_argument(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    build_exception(ctx, "kotlin.IllegalArgumentException")
}
fn excn_illegal_state(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    build_exception(ctx, "kotlin.IllegalStateException")
}
fn excn_npe(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    build_exception(ctx, "kotlin.NullPointerException")
}
fn excn_ioob(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    build_exception(ctx, "kotlin.IndexOutOfBoundsException")
}
fn excn_arithmetic(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    build_exception(ctx, "kotlin.ArithmeticException")
}
fn excn_class_cast(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    build_exception(ctx, "kotlin.ClassCastException")
}
fn excn_no_such_element(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    build_exception(ctx, "kotlin.NoSuchElementException")
}
fn excn_unsupported(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    build_exception(ctx, "kotlin.UnsupportedOperationException")
}

fn throwable_message(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(Value::Exception { message, .. }) = ctx.args.first() else {
        return Err(RuntimeError::Type("message requires a Throwable receiver".into()));
    };
    Ok(message
        .as_ref()
        .map_or(Value::Null, |m| Value::String(Rc::clone(m))))
}

fn throwable_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(v @ Value::Exception { .. }) = ctx.args.first() else {
        return Err(RuntimeError::Type("toString requires a Throwable receiver".into()));
    };
    Ok(Value::String(Rc::new(format!("{v}"))))
}

fn throwable_cause(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(Value::Exception { cause, .. }) = ctx.args.first() else {
        return Err(RuntimeError::Type("cause requires a Throwable receiver".into()));
    };
    Ok(cause.as_ref().map_or(Value::Null, |c| (**c).clone()))
}

// ============================================================
// Collections
// ============================================================

use std::cell::RefCell;

fn make_list(items: Vec<Value>, mutable: bool) -> Value {
    Value::List { items: Rc::new(RefCell::new(items)), mutable, enum_class: None }
}

fn make_set(items: Vec<Value>, mutable: bool) -> Value {
    let mut deduped: Vec<Value> = Vec::with_capacity(items.len());
    for v in items {
        if !deduped.iter().any(|x| Value::structural_eq(x, &v)) {
            deduped.push(v);
        }
    }
    Value::Set { items: Rc::new(RefCell::new(deduped)), mutable }
}

fn make_map(entries: Vec<(Value, Value)>, mutable: bool) -> Value {
    // Deduplicate keys, last write wins (matches `mapOf("a" to 1, "a" to 2)`).
    let mut out: Vec<(Value, Value)> = Vec::with_capacity(entries.len());
    for (k, v) in entries {
        if let Some(slot) = out.iter_mut().find(|(kk, _)| Value::structural_eq(kk, &k)) {
            slot.1 = v;
        } else {
            out.push((k, v));
        }
    }
    Value::Map { entries: Rc::new(RefCell::new(out)), mutable }
}

fn pair_args(ctx: &CallCtx<'_>) -> Result<(Value, Value), RuntimeError> {
    match ctx.args {
        [a, b] => Ok((a.clone(), b.clone())),
        _ => Err(RuntimeError::Arity("Pair expects 2 arguments".into())),
    }
}

fn coll_pair_ctor(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (a, b) = pair_args(ctx)?;
    Ok(Value::Pair(Box::new(a), Box::new(b)))
}

fn coll_to_infix(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    coll_pair_ctor(ctx)
}

fn coll_list_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(make_list(ctx.args.to_vec(), false))
}
fn coll_mutable_list_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(make_list(ctx.args.to_vec(), true))
}
fn coll_empty_list(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(make_list(Vec::new(), false))
}

fn coll_set_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(make_set(ctx.args.to_vec(), false))
}
fn coll_mutable_set_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(make_set(ctx.args.to_vec(), true))
}
fn coll_empty_set(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(make_set(Vec::new(), false))
}

fn coll_map_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let mut entries = Vec::with_capacity(ctx.args.len());
    for v in ctx.args {
        let Value::Pair(k, v) = v else {
            return Err(RuntimeError::Type(
                "mapOf expects Pair arguments (use `key to value` or `Pair(k, v)`)".into(),
            ));
        };
        entries.push(((**k).clone(), (**v).clone()));
    }
    Ok(make_map(entries, false))
}
fn coll_mutable_map_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let mut entries = Vec::with_capacity(ctx.args.len());
    for v in ctx.args {
        let Value::Pair(k, v) = v else {
            return Err(RuntimeError::Type(
                "mutableMapOf expects Pair arguments".into(),
            ));
        };
        entries.push(((**k).clone(), (**v).clone()));
    }
    Ok(make_map(entries, true))
}
fn coll_empty_map(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(make_map(Vec::new(), false))
}

/// `ArrayList()` / `ArrayList(initialCapacity)` — same storage as our
/// `MutableList`; the capacity arg is accepted and ignored.
fn coll_array_list_ctor(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    match ctx.args {
        [] => Ok(make_list(Vec::new(), true)),
        [Value::Int(_n)] => Ok(make_list(Vec::new(), true)),
        [other] => {
            // ArrayList(Collection) shape — copy items.
            match other {
                Value::List { items, .. } | Value::Set { items, .. } => {
                    Ok(make_list(items.borrow().clone(), true))
                }
                _ => Err(RuntimeError::Type(
                    "ArrayList expects no args, an Int capacity, or a Collection".into(),
                )),
            }
        }
        _ => Err(RuntimeError::Arity("ArrayList expects 0 or 1 args".into())),
    }
}

fn coll_hash_map_ctor(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    match ctx.args {
        [] | [Value::Int(_)] => Ok(make_map(Vec::new(), true)),
        [Value::Map { entries, .. }] => Ok(make_map(entries.borrow().clone(), true)),
        _ => Err(RuntimeError::Type(
            "HashMap expects no args, an Int capacity, or a Map".into(),
        )),
    }
}

fn coll_hash_set_ctor(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    match ctx.args {
        [] | [Value::Int(_)] => Ok(make_set(Vec::new(), true)),
        [Value::List { items, .. } | Value::Set { items, .. }] => {
            Ok(make_set(items.borrow().clone(), true))
        }
        _ => Err(RuntimeError::Type(
            "HashSet expects no args, an Int capacity, or a Collection".into(),
        )),
    }
}

// ----- List / MutableList helpers -----

fn recv_list_items<'a>(args: &'a [Value], what: &str) -> Result<Rc<RefCell<Vec<Value>>>, RuntimeError> {
    match args.first() {
        Some(Value::List { items, .. }) => Ok(Rc::clone(items)),
        _ => Err(RuntimeError::Type(format!("{what} requires a List receiver"))),
    }
}

fn coll_list_size(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.size")?;
    Ok(Value::new_int(it.borrow().len()))
}
fn coll_list_is_empty(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.isEmpty")?;
    Ok(Value::Bool(it.borrow().is_empty()))
}
fn coll_list_is_not_empty(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.isNotEmpty")?;
    Ok(Value::Bool(!it.borrow().is_empty()))
}
fn coll_list_get(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.get")?;
    let Some(Value::Int(idx)) = ctx.args.get(1) else {
        return Err(RuntimeError::Type("List.get requires an Int index".into()));
    };
    let borrow = it.borrow();
    let i = *idx;
    if i < 0 || (i as usize) >= borrow.len() {
        return Err(RuntimeError::Thrown(Value::Exception {
            fqn: Rc::new("kotlin.IndexOutOfBoundsException".into()),
            message: Some(Rc::new(format!(
                "Index {i} out of bounds for length {}",
                borrow.len()
            ))),
            cause: None,
        }));
    }
    Ok(borrow[i as usize].clone())
}
fn coll_list_first(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() >= 2 {
        let items = iterable_items(&ctx.args[0], "first")?;
        let block = ctx.args[1].clone();
        let CallCtx { out, host, .. } = ctx;
        for v in items {
            if matches!(host.invoke_callable(&block, std::slice::from_ref(&v), *out)?, Value::Bool(true)) {
                return Ok(v);
            }
        }
        return Err(RuntimeError::Thrown(Value::Exception {
            fqn: Rc::new("kotlin.NoSuchElementException".into()),
            message: Some(Rc::new("Collection contains no element matching the predicate.".into())),
            cause: None,
        }));
    }
    let it = recv_list_items(ctx.args, "List.first")?;
    it.borrow().first().cloned().ok_or_else(|| {
        RuntimeError::Thrown(Value::Exception {
            fqn: Rc::new("kotlin.NoSuchElementException".into()),
            message: Some(Rc::new("List is empty.".into())),
            cause: None,
        })
    })
}
fn coll_list_last(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() >= 2 {
        let items = iterable_items(&ctx.args[0], "last")?;
        let block = ctx.args[1].clone();
        let CallCtx { out, host, .. } = ctx;
        let mut found: Option<Value> = None;
        for v in items {
            if matches!(host.invoke_callable(&block, std::slice::from_ref(&v), *out)?, Value::Bool(true)) {
                found = Some(v);
            }
        }
        return found.ok_or_else(|| RuntimeError::Thrown(Value::Exception {
            fqn: Rc::new("kotlin.NoSuchElementException".into()),
            message: Some(Rc::new("Collection contains no element matching the predicate.".into())),
            cause: None,
        }));
    }
    let it = recv_list_items(ctx.args, "List.last")?;
    it.borrow().last().cloned().ok_or_else(|| {
        RuntimeError::Thrown(Value::Exception {
            fqn: Rc::new("kotlin.NoSuchElementException".into()),
            message: Some(Rc::new("List is empty.".into())),
            cause: None,
        })
    })
}
fn coll_list_contains(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.contains")?;
    let Some(needle) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("contains requires an argument".into()));
    };
    Ok(Value::Bool(it.borrow().iter().any(|v| Value::structural_eq(v, needle))))
}
fn coll_list_index_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.indexOf")?;
    let Some(needle) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("indexOf requires an argument".into()));
    };
    let pos = it.borrow().iter().position(|v| Value::structural_eq(v, needle));
    Ok(Value::new_int(pos.map(|p| p as i64).unwrap_or(-1)))
}
fn coll_list_last_index_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.lastIndexOf")?;
    let Some(needle) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("lastIndexOf requires an argument".into()));
    };
    let borrow = it.borrow();
    let pos = borrow.iter().rposition(|v| Value::structural_eq(v, needle));
    Ok(Value::new_int(pos.map(|p| p as i64).unwrap_or(-1)))
}
fn coll_list_join_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.joinToString")?;
    // Slot map (after the receiver):
    //   1 separator, 2 prefix, 3 postfix, 4 limit, 5 truncated.
    // Named-arg reordering populates missing slots with `Value::Null`.
    fn opt_str<'a>(args: &'a [Value], idx: usize, default: &'a str) -> String {
        match args.get(idx) {
            None | Some(Value::Null) => default.to_string(),
            Some(Value::String(s)) => (**s).clone(),
            Some(other) => format!("{other}"),
        }
    }
    let sep = opt_str(ctx.args, 1, ", ");
    let prefix = opt_str(ctx.args, 2, "");
    let postfix = opt_str(ctx.args, 3, "");
    let limit: i64 = match ctx.args.get(4) {
        None | Some(Value::Null) => -1,
        Some(v) => v.as_i64().unwrap_or(-1),
    };
    let truncated = opt_str(ctx.args, 5, "...");
    let mut out = String::new();
    out.push_str(&prefix);
    let items = it.borrow();
    let n = items.len();
    let take = if limit < 0 { n } else { (limit as usize).min(n) };
    for (i, v) in items.iter().enumerate().take(take) {
        if i > 0 {
            out.push_str(&sep);
        }
        out.push_str(&format!("{v}"));
    }
    if limit >= 0 && n > take {
        if take > 0 {
            out.push_str(&sep);
        }
        out.push_str(&truncated);
    }
    out.push_str(&postfix);
    Ok(Value::String(Rc::new(out)))
}
fn coll_list_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = ctx.args.first().ok_or_else(|| RuntimeError::Type("List.toString requires a receiver".into()))?;
    Ok(Value::String(Rc::new(format!("{v}"))))
}

fn coll_mut_list_add(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "MutableList.add")?;
    // `add(item)` — single user arg → append, returns Boolean.
    // `add(index, item)` — two user args → insert at index, returns Unit.
    let user = ctx.args.len() - 1;
    if user == 1 {
        let arg = ctx.args.get(1).unwrap().clone();
        it.borrow_mut().push(arg);
        return Ok(Value::Bool(true));
    }
    if user >= 2 {
        let Some(Value::Int(i)) = ctx.args.get(1) else {
            return Err(RuntimeError::Type(
                "add(index, item) requires an Int index".into(),
            ));
        };
        let item = ctx.args.get(2).unwrap().clone();
        let mut borrow = it.borrow_mut();
        let idx = *i as usize;
        if *i < 0 || idx > borrow.len() {
            return Err(RuntimeError::Thrown(Value::Exception {
                fqn: Rc::new("kotlin.IndexOutOfBoundsException".into()),
                message: Some(Rc::new(format!(
                    "Index {i} out of bounds for length {}",
                    borrow.len()
                ))),
                cause: None,
            }));
        }
        borrow.insert(idx, item);
        return Ok(Value::Unit);
    }
    Err(RuntimeError::Arity("add requires an argument".into()))
}
fn coll_mut_list_remove_at(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "MutableList.removeAt")?;
    let Some(Value::Int(i)) = ctx.args.get(1) else {
        return Err(RuntimeError::Type("removeAt requires an Int index".into()));
    };
    let mut borrow = it.borrow_mut();
    if *i < 0 || (*i as usize) >= borrow.len() {
        return Err(RuntimeError::Thrown(Value::Exception {
            fqn: Rc::new("kotlin.IndexOutOfBoundsException".into()),
            message: Some(Rc::new(format!(
                "Index {i} out of bounds for length {}",
                borrow.len()
            ))),
            cause: None,
        }));
    }
    Ok(borrow.remove(*i as usize))
}
fn coll_mut_list_clear(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "MutableList.clear")?;
    it.borrow_mut().clear();
    Ok(Value::Unit)
}

/// Natural order for the Kotlin types we currently support as `Comparable`.
/// Returns an `Ordering`, or an error when the types can't be compared.
pub fn compare_values(a: &Value, b: &Value) -> Result<std::cmp::Ordering, RuntimeError> {
    use std::cmp::Ordering::*;
    if a.is_numeric() && b.is_numeric() {
        if a.is_integral() && b.is_integral() {
            return Ok(a.as_i64().unwrap().cmp(&b.as_i64().unwrap()));
        }
        return Ok(a
            .as_f64()
            .unwrap()
            .partial_cmp(&b.as_f64().unwrap())
            .unwrap_or(Equal));
    }
    Ok(match (a, b) {
        (Value::String(x), Value::String(y)) => crate::text::compare_utf16(x, y),
        (Value::Char(x), Value::Char(y)) => x.cmp(y),
        (Value::Bool(x), Value::Bool(y)) => x.cmp(y),
        _ => {
            return Err(RuntimeError::Type(format!(
                "values are not comparable: {a:?}, {b:?}"
            )))
        }
    })
}

fn coll_list_sorted(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.sorted")?;
    let mut copy: Vec<Value> = it.borrow().clone();
    // Stable sort by natural order. Returns the first comparison error if any.
    let mut err: Option<RuntimeError> = None;
    copy.sort_by(|a, b| {
        if err.is_some() {
            return std::cmp::Ordering::Equal;
        }
        match compare_values(a, b) {
            Ok(o) => o,
            Err(e) => {
                err = Some(e);
                std::cmp::Ordering::Equal
            }
        }
    });
    if let Some(e) = err {
        return Err(e);
    }
    Ok(make_list(copy, false))
}

fn coll_list_sorted_descending(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = coll_list_sorted(ctx)?;
    let Value::List { items, .. } = v else { unreachable!() };
    let mut out: Vec<Value> = items.borrow().clone();
    out.reverse();
    Ok(make_list(out, false))
}

fn coll_list_reversed(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.reversed")?;
    let mut out: Vec<Value> = it.borrow().clone();
    out.reverse();
    Ok(make_list(out, false))
}

fn coll_list_indices(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.indices")?;
    let len = it.borrow().len() as i64;
    Ok(Value::Range { start: 0, end: len - 1, step: 1, kind: klio_runtime::RangeKind::Int })
}

fn coll_list_last_index(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.lastIndex")?;
    Ok(Value::new_int(it.borrow().len() as i64 - 1))
}

fn coll_list_sum(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.sum")?;
    let mut acc_int: Option<i64> = Some(0);
    let mut acc_dbl: Option<f64> = None;
    for v in it.borrow().iter() {
        if v.is_integral() {
            let n = v.as_i64().unwrap();
            if let Some(a) = acc_int.as_mut() {
                *a = a.wrapping_add(n);
            } else if let Some(a) = acc_dbl.as_mut() {
                *a += n as f64;
            }
        } else if v.is_floating() {
            let d = v.as_f64().unwrap();
            if let Some(a) = acc_int.take() {
                acc_dbl = Some(a as f64 + d);
            } else if let Some(a) = acc_dbl.as_mut() {
                *a += d;
            }
        } else {
            return Err(RuntimeError::Type(format!(
                "List.sum requires numeric elements, got {v:?}"
            )));
        }
    }
    Ok(match acc_dbl {
        Some(d) => Value::Double(d),
        None => Value::new_int(acc_int.unwrap_or(0)),
    })
}

fn coll_list_average(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.average")?;
    let borrow = it.borrow();
    if borrow.is_empty() {
        return Ok(Value::Double(f64::NAN));
    }
    let mut sum = 0.0;
    let mut n = 0i64;
    for v in borrow.iter() {
        sum += match v {
            Value::Int(x) => *x as f64,
            Value::Double(x) => *x,
            other => {
                return Err(RuntimeError::Type(format!(
                    "List.average requires numeric elements, got {other:?}"
                )))
            }
        };
        n += 1;
    }
    Ok(Value::Double(sum / n as f64))
}

fn coll_list_max_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.maxOrNull")?;
    let borrow = it.borrow();
    if borrow.is_empty() {
        return Ok(Value::Null);
    }
    let mut best = borrow[0].clone();
    for v in borrow.iter().skip(1) {
        if compare_values(v, &best)? == std::cmp::Ordering::Greater {
            best = v.clone();
        }
    }
    Ok(best)
}

fn coll_list_min_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.minOrNull")?;
    let borrow = it.borrow();
    if borrow.is_empty() {
        return Ok(Value::Null);
    }
    let mut best = borrow[0].clone();
    for v in borrow.iter().skip(1) {
        if compare_values(v, &best)? == std::cmp::Ordering::Less {
            best = v.clone();
        }
    }
    Ok(best)
}

fn coll_list_to_map(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.toMap")?;
    let mut entries: Vec<(Value, Value)> = Vec::new();
    for v in it.borrow().iter() {
        let Value::Pair(k, val) = v else {
            return Err(RuntimeError::Type(
                "List.toMap requires a List<Pair<K, V>>".into(),
            ));
        };
        let key = (**k).clone();
        if let Some(slot) = entries.iter_mut().find(|(kk, _)| Value::structural_eq(kk, &key)) {
            slot.1 = (**val).clone();
        } else {
            entries.push((key, (**val).clone()));
        }
    }
    Ok(make_map(entries, false))
}

fn coll_list_distinct(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.distinct")?;
    let mut out: Vec<Value> = Vec::new();
    for v in it.borrow().iter() {
        if !out.iter().any(|x| Value::structural_eq(x, v)) {
            out.push(v.clone());
        }
    }
    Ok(make_list(out, false))
}

fn list_take_count(ctx: &CallCtx<'_>, what: &str) -> Result<i64, RuntimeError> {
    let Some(n) = ctx.args.get(1).and_then(Value::as_i64) else {
        return Err(RuntimeError::Type(format!("{what} requires an Int")));
    };
    if n < 0 {
        return Err(RuntimeError::Thrown(Value::Exception {
            fqn: Rc::new("kotlin.IllegalArgumentException".into()),
            message: Some(Rc::new(format!("Requested element count {n} is less than zero."))),
            cause: None,
        }));
    }
    Ok(n)
}

fn coll_list_take(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.take")?;
    let n = list_take_count(ctx, "take")? as usize;
    let borrow = it.borrow();
    let end = n.min(borrow.len());
    Ok(make_list(borrow[..end].to_vec(), false))
}
fn coll_list_drop(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.drop")?;
    let n = list_take_count(ctx, "drop")? as usize;
    let borrow = it.borrow();
    let start = n.min(borrow.len());
    Ok(make_list(borrow[start..].to_vec(), false))
}
fn coll_list_take_last(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.takeLast")?;
    let n = list_take_count(ctx, "takeLast")? as usize;
    let borrow = it.borrow();
    let start = borrow.len().saturating_sub(n);
    Ok(make_list(borrow[start..].to_vec(), false))
}
fn coll_list_drop_last(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.dropLast")?;
    let n = list_take_count(ctx, "dropLast")? as usize;
    let borrow = it.borrow();
    let end = borrow.len().saturating_sub(n);
    Ok(make_list(borrow[..end].to_vec(), false))
}

fn coll_list_slice(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.slice")?;
    let borrow = it.borrow();
    let len = borrow.len() as i64;
    let out_items: Vec<Value> = match ctx.args.get(1) {
        Some(Value::Range { start, end, step, .. }) => {
            let mut v = Vec::new();
            for i in range_iter_int(*start, *end, *step) {
                if i < 0 || i >= len {
                    return Err(RuntimeError::Thrown(Value::Exception {
                        fqn: Rc::new("kotlin.IndexOutOfBoundsException".into()),
                        message: Some(Rc::new(format!(
                            "Index {i} out of bounds for length {len}"
                        ))),
                        cause: None,
                    }));
                }
                v.push(borrow[i as usize].clone());
            }
            v
        }
        Some(Value::List { items, .. }) => {
            let mut v = Vec::new();
            for idx_val in items.borrow().iter() {
                let Some(i) = idx_val.as_i64() else {
                    return Err(RuntimeError::Type(
                        "slice indices must be Int".into(),
                    ));
                };
                if i < 0 || i >= len {
                    return Err(RuntimeError::Thrown(Value::Exception {
                        fqn: Rc::new("kotlin.IndexOutOfBoundsException".into()),
                        message: Some(Rc::new(format!(
                            "Index {i} out of bounds for length {len}"
                        ))),
                        cause: None,
                    }));
                }
                v.push(borrow[i as usize].clone());
            }
            v
        }
        _ => return Err(RuntimeError::Type(
            "slice requires an IntRange or List<Int>".into(),
        )),
    };
    Ok(make_list(out_items, false))
}

fn coll_list_sublist(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.subList")?;
    let Some(from) = ctx.args.get(1).and_then(Value::as_i64) else {
        return Err(RuntimeError::Type("subList requires Int fromIndex".into()));
    };
    let Some(to) = ctx.args.get(2).and_then(Value::as_i64) else {
        return Err(RuntimeError::Type("subList requires Int toIndex".into()));
    };
    let borrow = it.borrow();
    let len = borrow.len() as i64;
    if from < 0 || to > len || from > to {
        return Err(RuntimeError::Thrown(Value::Exception {
            fqn: Rc::new("kotlin.IndexOutOfBoundsException".into()),
            message: Some(Rc::new(format!(
                "fromIndex: {from}, toIndex: {to}, size: {len}"
            ))),
            cause: None,
        }));
    }
    Ok(make_list(borrow[from as usize..to as usize].to_vec(), false))
}

fn coll_list_plus(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.plus")?;
    let mut out: Vec<Value> = it.borrow().clone();
    let Some(arg) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("plus requires an argument".into()));
    };
    match arg {
        Value::List { items, .. } => out.extend(items.borrow().clone()),
        Value::Set { items, .. } => out.extend(items.borrow().clone()),
        single => out.push(single.clone()),
    }
    Ok(make_list(out, false))
}

fn coll_list_minus(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.minus")?;
    let Some(arg) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("minus requires an argument".into()));
    };
    let removals: Vec<Value> = match arg {
        Value::List { items, .. } => items.borrow().clone(),
        Value::Set { items, .. } => items.borrow().clone(),
        single => vec![single.clone()],
    };
    let mut out: Vec<Value> = Vec::new();
    let mut remaining = removals.clone();
    for v in it.borrow().iter() {
        if let Some(pos) = remaining.iter().position(|r| Value::structural_eq(r, v)) {
            remaining.remove(pos);
        } else {
            out.push(v.clone());
        }
    }
    Ok(make_list(out, false))
}

fn coll_list_chunked(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.chunked")?;
    let Some(Value::Int(size)) = ctx.args.get(1) else {
        return Err(RuntimeError::Type("chunked requires an Int size".into()));
    };
    if *size <= 0 {
        return Err(RuntimeError::Thrown(Value::Exception {
            fqn: Rc::new("kotlin.IllegalArgumentException".into()),
            message: Some(Rc::new(format!("Size {size} must be greater than zero."))),
            cause: None,
        }));
    }
    let size = *size as usize;
    let borrow = it.borrow();
    let mut groups: Vec<Value> = Vec::new();
    let mut i = 0;
    while i < borrow.len() {
        let end = (i + size).min(borrow.len());
        groups.push(make_list(borrow[i..end].to_vec(), false));
        i += size;
    }
    Ok(make_list(groups, false))
}

fn coll_list_windowed(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.windowed")?;
    let Some(Value::Int(size)) = ctx.args.get(1) else {
        return Err(RuntimeError::Type("windowed requires an Int size".into()));
    };
    if *size <= 0 {
        return Err(RuntimeError::Thrown(Value::Exception {
            fqn: Rc::new("kotlin.IllegalArgumentException".into()),
            message: Some(Rc::new(format!("size {size} must be greater than zero."))),
            cause: None,
        }));
    }
    let step = match ctx.args.get(2) {
        None => 1i64,
        Some(v) if v.is_integral() => v.as_i64().unwrap(),
        _ => return Err(RuntimeError::Type("windowed step must be Int".into())),
    };
    if step <= 0 {
        return Err(RuntimeError::Thrown(Value::Exception {
            fqn: Rc::new("kotlin.IllegalArgumentException".into()),
            message: Some(Rc::new(format!("step {step} must be greater than zero."))),
            cause: None,
        }));
    }
    let partial_windows = match ctx.args.get(3) {
        None => false,
        Some(Value::Bool(b)) => *b,
        _ => return Err(RuntimeError::Type("windowed partialWindows must be Bool".into())),
    };
    let borrow = it.borrow();
    let size = *size as usize;
    let step = step as usize;
    let mut out: Vec<Value> = Vec::new();
    let mut i = 0usize;
    while i < borrow.len() {
        let end = i + size;
        if end <= borrow.len() {
            out.push(make_list(borrow[i..end].to_vec(), false));
        } else if partial_windows {
            out.push(make_list(borrow[i..].to_vec(), false));
        } else {
            break;
        }
        i += step;
    }
    Ok(make_list(out, false))
}

fn coll_list_zip(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let lhs = recv_list_items(ctx.args, "List.zip")?;
    let Some(rhs_val) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("zip requires a second collection".into()));
    };
    let rhs: Vec<Value> = match rhs_val {
        Value::List { items, .. } => items.borrow().clone(),
        Value::Set { items, .. } => items.borrow().clone(),
        Value::Range { start, end, step, .. } => range_iter_int(*start, *end, *step)
            .map(Value::new_int)
            .collect(),
        other => {
            return Err(RuntimeError::Type(format!(
                "zip requires a collection, got {other:?}"
            )))
        }
    };
    let lhs_borrow = lhs.borrow();
    let out: Vec<Value> = lhs_borrow
        .iter()
        .zip(rhs.iter())
        .map(|(a, b)| Value::Pair(Box::new(a.clone()), Box::new(b.clone())))
        .collect();
    Ok(make_list(out, false))
}

fn range_iter_int(start: i64, end: i64, step: i64) -> Box<dyn Iterator<Item = i64>> {
    if step == 0 {
        return Box::new(std::iter::empty());
    }
    if step > 0 {
        if start > end {
            return Box::new(std::iter::empty());
        }
        let mut cur = start;
        Box::new(std::iter::from_fn(move || {
            if cur > end {
                None
            } else {
                let v = cur;
                cur = cur.saturating_add(step);
                Some(v)
            }
        }))
    } else {
        if start < end {
            return Box::new(std::iter::empty());
        }
        let mut cur = start;
        Box::new(std::iter::from_fn(move || {
            if cur < end {
                None
            } else {
                let v = cur;
                cur = cur.saturating_add(step);
                Some(v)
            }
        }))
    }
}

fn coll_set_plus(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "Set.plus")?;
    let mut out: Vec<Value> = it.borrow().clone();
    let push = |out: &mut Vec<Value>, v: Value| {
        if !out.iter().any(|x| Value::structural_eq(x, &v)) {
            out.push(v);
        }
    };
    let Some(arg) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("plus requires an argument".into()));
    };
    match arg {
        Value::List { items, .. } | Value::Set { items, .. } => {
            for v in items.borrow().iter() {
                push(&mut out, v.clone());
            }
        }
        single => push(&mut out, single.clone()),
    }
    Ok(Value::Set { items: Rc::new(std::cell::RefCell::new(out)), mutable: false })
}

fn coll_set_minus(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "Set.minus")?;
    let Some(arg) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("minus requires an argument".into()));
    };
    let removals: Vec<Value> = match arg {
        Value::List { items, .. } | Value::Set { items, .. } => items.borrow().clone(),
        single => vec![single.clone()],
    };
    let out: Vec<Value> = it
        .borrow()
        .iter()
        .filter(|v| !removals.iter().any(|r| Value::structural_eq(r, v)))
        .cloned()
        .collect();
    Ok(Value::Set { items: Rc::new(std::cell::RefCell::new(out)), mutable: false })
}

fn coll_set_union(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    coll_set_plus(ctx)
}
fn coll_set_intersect(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "Set.intersect")?;
    let Some(arg) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("intersect requires an argument".into()));
    };
    let other: Vec<Value> = match arg {
        Value::List { items, .. } | Value::Set { items, .. } => items.borrow().clone(),
        _ => return Err(RuntimeError::Type("intersect requires a collection".into())),
    };
    let out: Vec<Value> = it
        .borrow()
        .iter()
        .filter(|v| other.iter().any(|o| Value::structural_eq(o, v)))
        .cloned()
        .collect();
    Ok(Value::Set { items: Rc::new(std::cell::RefCell::new(out)), mutable: false })
}
fn coll_set_subtract(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    coll_set_minus(ctx)
}

// ----- Set helpers -----

fn recv_set_items<'a>(args: &'a [Value], what: &str) -> Result<Rc<RefCell<Vec<Value>>>, RuntimeError> {
    match args.first() {
        Some(Value::Set { items, .. }) => Ok(Rc::clone(items)),
        _ => Err(RuntimeError::Type(format!("{what} requires a Set receiver"))),
    }
}

fn coll_set_size(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "Set.size")?;
    Ok(Value::new_int(it.borrow().len()))
}
fn coll_set_is_empty(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Bool(recv_set_items(ctx.args, "Set.isEmpty")?.borrow().is_empty()))
}
fn coll_set_is_not_empty(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Bool(!recv_set_items(ctx.args, "Set.isNotEmpty")?.borrow().is_empty()))
}
fn coll_set_contains(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "Set.contains")?;
    let Some(needle) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("contains requires an argument".into()));
    };
    Ok(Value::Bool(it.borrow().iter().any(|v| Value::structural_eq(v, needle))))
}
fn coll_set_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = ctx.args.first().ok_or_else(|| RuntimeError::Type("Set.toString requires a receiver".into()))?;
    Ok(Value::String(Rc::new(format!("{v}"))))
}
fn coll_mut_set_add(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "MutableSet.add")?;
    let Some(arg) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("add requires an argument".into()));
    };
    let mut borrow = it.borrow_mut();
    if borrow.iter().any(|v| Value::structural_eq(v, arg)) {
        return Ok(Value::Bool(false));
    }
    borrow.push(arg.clone());
    Ok(Value::Bool(true))
}
fn coll_mut_set_remove(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "MutableSet.remove")?;
    let Some(arg) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("remove requires an argument".into()));
    };
    let mut borrow = it.borrow_mut();
    if let Some(pos) = borrow.iter().position(|v| Value::structural_eq(v, arg)) {
        borrow.remove(pos);
        Ok(Value::Bool(true))
    } else {
        Ok(Value::Bool(false))
    }
}
fn coll_mut_set_clear(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    recv_set_items(ctx.args, "MutableSet.clear")?.borrow_mut().clear();
    Ok(Value::Unit)
}

// ----- Map helpers -----

fn recv_map_entries<'a>(
    args: &'a [Value],
    what: &str,
) -> Result<Rc<RefCell<Vec<(Value, Value)>>>, RuntimeError> {
    match args.first() {
        Some(Value::Map { entries, .. }) => Ok(Rc::clone(entries)),
        _ => Err(RuntimeError::Type(format!("{what} requires a Map receiver"))),
    }
}

fn coll_map_size(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::new_int(recv_map_entries(ctx.args, "Map.size")?.borrow().len()))
}
fn coll_map_is_empty(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Bool(recv_map_entries(ctx.args, "Map.isEmpty")?.borrow().is_empty()))
}
fn coll_map_is_not_empty(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Bool(!recv_map_entries(ctx.args, "Map.isNotEmpty")?.borrow().is_empty()))
}
fn coll_map_get(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = recv_map_entries(ctx.args, "Map.get")?;
    let Some(key) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("get requires a key".into()));
    };
    Ok(entries
        .borrow()
        .iter()
        .find(|(k, _)| Value::structural_eq(k, key))
        .map(|(_, v)| v.clone())
        .unwrap_or(Value::Null))
}
fn coll_map_contains_key(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = recv_map_entries(ctx.args, "Map.containsKey")?;
    let Some(key) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("containsKey requires a key".into()));
    };
    Ok(Value::Bool(
        entries.borrow().iter().any(|(k, _)| Value::structural_eq(k, key)),
    ))
}
fn coll_map_contains_value(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = recv_map_entries(ctx.args, "Map.containsValue")?;
    let Some(value) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("containsValue requires a value".into()));
    };
    Ok(Value::Bool(
        entries.borrow().iter().any(|(_, v)| Value::structural_eq(v, value)),
    ))
}
fn coll_map_keys(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = recv_map_entries(ctx.args, "Map.keys")?;
    let keys: Vec<Value> = entries.borrow().iter().map(|(k, _)| k.clone()).collect();
    Ok(make_set(keys, false))
}
fn coll_map_values(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = recv_map_entries(ctx.args, "Map.values")?;
    let values: Vec<Value> = entries.borrow().iter().map(|(_, v)| v.clone()).collect();
    Ok(make_list(values, false))
}
fn coll_map_entries(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = recv_map_entries(ctx.args, "Map.entries")?;
    let map_entries: Vec<Value> = entries
        .borrow()
        .iter()
        .map(|(k, v)| Value::MapEntry {
            key: Box::new(k.clone()),
            value: Box::new(v.clone()),
        })
        .collect();
    Ok(make_set(map_entries, false))
}
fn coll_map_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = ctx.args.first().ok_or_else(|| RuntimeError::Type("Map.toString requires a receiver".into()))?;
    Ok(Value::String(Rc::new(format!("{v}"))))
}
fn coll_mut_map_put(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = recv_map_entries(ctx.args, "MutableMap.put")?;
    let Some(key) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("put requires a key".into()));
    };
    let Some(value) = ctx.args.get(2) else {
        return Err(RuntimeError::Arity("put requires a value".into()));
    };
    let mut borrow = entries.borrow_mut();
    if let Some(slot) = borrow.iter_mut().find(|(k, _)| Value::structural_eq(k, key)) {
        let prev = std::mem::replace(&mut slot.1, value.clone());
        Ok(prev)
    } else {
        borrow.push((key.clone(), value.clone()));
        Ok(Value::Null)
    }
}
fn coll_mut_map_remove(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = recv_map_entries(ctx.args, "MutableMap.remove")?;
    let Some(key) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("remove requires a key".into()));
    };
    let mut borrow = entries.borrow_mut();
    if let Some(pos) = borrow.iter().position(|(k, _)| Value::structural_eq(k, key)) {
        let (_, v) = borrow.remove(pos);
        Ok(v)
    } else {
        Ok(Value::Null)
    }
}
fn coll_mut_map_clear(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    recv_map_entries(ctx.args, "MutableMap.clear")?.borrow_mut().clear();
    Ok(Value::Unit)
}

// ----- Pair members -----

fn recv_pair<'a>(args: &'a [Value], what: &str) -> Result<&'a Value, RuntimeError> {
    args.first()
        .filter(|v| matches!(v, Value::Pair(_, _)))
        .ok_or_else(|| RuntimeError::Type(format!("{what} requires a Pair receiver")))
}
fn pair_first(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Value::Pair(a, _) = recv_pair(ctx.args, "Pair.first")? else { unreachable!() };
    Ok((**a).clone())
}
fn pair_second(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Value::Pair(_, b) = recv_pair(ctx.args, "Pair.second")? else { unreachable!() };
    Ok((**b).clone())
}
fn pair_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = recv_pair(ctx.args, "Pair.toString")?;
    Ok(Value::String(Rc::new(format!("{v}"))))
}

// ============================================================
// Sequence (eager; same observable output as List)
// ============================================================

/// Build an items-only Sequence from a `Vec`. Used by `asSequence`,
/// `sequenceOf`, and `emptySequence`.
fn make_sequence(items: Vec<Value>) -> Value {
    Value::Sequence(Rc::new(klio_runtime::SequenceData {
        source: klio_runtime::SequenceSource::Items(Rc::new(items)),
        ops: Vec::new(),
    }))
}

fn seq_from_list(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "asSequence")?;
    Ok(make_sequence(it.borrow().clone()))
}
fn seq_from_set(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "asSequence")?;
    Ok(make_sequence(it.borrow().clone()))
}
fn seq_from_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "asSequence")?;
    Ok(make_sequence(s.chars().map(Value::Char).collect()))
}
fn seq_from_range(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(Value::Range { start, end, step, .. }) = ctx.args.first() else {
        return Err(RuntimeError::Type("asSequence requires an IntRange".into()));
    };
    let items: Vec<Value> = range_iter_int(*start, *end, *step).map(Value::new_int).collect();
    Ok(make_sequence(items))
}
fn seq_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(make_sequence(ctx.args.to_vec()))
}
fn seq_empty(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(make_sequence(Vec::new()))
}

/// Fast-path Sequence terminal ops handle the special case of an
/// `Items`-source Sequence with no ops. Anything more (intermediate ops,
/// generator sources) goes through `klio-interp`'s lazy materialize path.
fn recv_seq_eager(args: &[Value], what: &str) -> Result<Option<Rc<Vec<Value>>>, RuntimeError> {
    let Some(Value::Sequence(data)) = args.first() else {
        return Err(RuntimeError::Type(format!("{what} requires a Sequence receiver")));
    };
    if !data.ops.is_empty() {
        return Ok(None);
    }
    match &data.source {
        klio_runtime::SequenceSource::Items(items) => Ok(Some(Rc::clone(items))),
        _ => Ok(None),
    }
}

fn seq_to_list(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(items) = recv_seq_eager(ctx.args, "Sequence.toList")? else {
        // Has ops or a non-Items source — caller should have routed this
        // through the interpreter's lazy materializer.
        return Err(RuntimeError::Unimplemented(
            "Sequence.toList on a non-trivial source/op chain (dispatch via the interpreter)".into(),
        ));
    };
    Ok(make_list((*items).clone(), false))
}
fn seq_to_mutable_list(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(items) = recv_seq_eager(ctx.args, "Sequence.toMutableList")? else {
        return Err(RuntimeError::Unimplemented(
            "Sequence.toMutableList on a non-trivial source/op chain".into(),
        ));
    };
    Ok(make_list((*items).clone(), true))
}
fn seq_to_set(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(items) = recv_seq_eager(ctx.args, "Sequence.toSet")? else {
        return Err(RuntimeError::Unimplemented(
            "Sequence.toSet on a non-trivial source/op chain".into(),
        ));
    };
    Ok(make_set((*items).clone(), false))
}
fn seq_count_no_pred(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(items) = recv_seq_eager(ctx.args, "Sequence.count")? else {
        return Err(RuntimeError::Unimplemented(
            "Sequence.count on a non-trivial source/op chain".into(),
        ));
    };
    Ok(Value::new_int(items.len()))
}
fn seq_first(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(items) = recv_seq_eager(ctx.args, "Sequence.first")? else {
        return Err(RuntimeError::Unimplemented(
            "Sequence.first on a non-trivial source/op chain".into(),
        ));
    };
    items.first().cloned().ok_or_else(|| {
        RuntimeError::Thrown(Value::Exception {
            fqn: Rc::new("kotlin.NoSuchElementException".into()),
            message: Some(Rc::new("Sequence is empty.".into())),
            cause: None,
        })
    })
}
fn seq_last(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(items) = recv_seq_eager(ctx.args, "Sequence.last")? else {
        return Err(RuntimeError::Unimplemented(
            "Sequence.last on a non-trivial source/op chain".into(),
        ));
    };
    items.last().cloned().ok_or_else(|| {
        RuntimeError::Thrown(Value::Exception {
            fqn: Rc::new("kotlin.NoSuchElementException".into()),
            message: Some(Rc::new("Sequence is empty.".into())),
            cause: None,
        })
    })
}
fn seq_to_string(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    // Kotlin returns an opaque id like `kotlin.sequences.TransformingSequence@…`.
    // Stable parity for that string is meaningless (it embeds the heap
    // address), so we emit a deterministic placeholder. Programs that need
    // a useful value should call `.toList()` before printing.
    Ok(Value::String(Rc::new("kotlin.sequences.Sequence".to_string())))
}

fn map_entry_key(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(Value::MapEntry { key, .. }) = ctx.args.first() else {
        return Err(RuntimeError::Type("Map.Entry.key requires a Map.Entry receiver".into()));
    };
    Ok((**key).clone())
}
fn map_entry_value(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(Value::MapEntry { value, .. }) = ctx.args.first() else {
        return Err(RuntimeError::Type("Map.Entry.value requires a Map.Entry receiver".into()));
    };
    Ok((**value).clone())
}
fn map_entry_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(v @ Value::MapEntry { .. }) = ctx.args.first() else {
        return Err(RuntimeError::Type(
            "Map.Entry.toString requires a Map.Entry receiver".into(),
        ));
    };
    Ok(Value::String(Rc::new(format!("{v}"))))
}

// ============================================================
// Range progressions
// ============================================================

fn ranges_down_to(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (a, b) = pair_int_args(ctx, "downTo")?;
    Ok(Value::Range { start: a, end: b, step: -1, kind: klio_runtime::RangeKind::Int })
}

fn ranges_until(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (a, b) = pair_int_args(ctx, "until")?;
    Ok(Value::Range {
        start: a,
        end: b.saturating_sub(1),
        step: 1,
        kind: klio_runtime::RangeKind::Int,
    })
}

fn ranges_step(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    match ctx.args {
        [Value::Range { start, end, step, kind }, step_arg] if step_arg.is_integral() => {
            let n = step_arg.as_i64().unwrap();
            if n <= 0 {
                return Err(RuntimeError::Thrown(Value::Exception {
                    fqn: Rc::new("kotlin.IllegalArgumentException".into()),
                    message: Some(Rc::new(format!(
                        "Step must be positive, was: {n}."
                    ))),
                    cause: None,
                }));
            }
            let signed = if *step < 0 { -n } else { n };
            let normalized_end = normalize_progression_end(*start, *end, signed);
            Ok(Value::Range { start: *start, end: normalized_end, step: signed, kind: *kind })
        }
        _ => Err(RuntimeError::Type("step requires IntRange . step(Int)".into())),
    }
}

/// Match Kotlin's `IntProgression.fromClosedRange`: the stored `end` is the
/// last element that's actually reachable from `start` with the given
/// `step`. For `1..10 step 2` this normalizes 10 → 9 because 9 is the last
/// reachable value.
fn normalize_progression_end(start: i64, end: i64, step: i64) -> i64 {
    if step == 0 {
        return end;
    }
    if step > 0 {
        if start > end {
            return start - 1;
        }
        let diff = end - start;
        let rem = diff % step;
        end - rem
    } else {
        if start < end {
            return start + 1;
        }
        let diff = start - end;
        let mag = -step;
        let rem = diff % mag;
        end + rem
    }
}

fn pair_int_args(ctx: &CallCtx<'_>, what: &str) -> Result<(i64, i64), RuntimeError> {
    match ctx.args {
        [a, b] if a.is_integral() && b.is_integral() => {
            Ok((a.as_i64().unwrap(), b.as_i64().unwrap()))
        }
        _ => Err(RuntimeError::Type(format!("{what} requires two Int operands"))),
    }
}

fn range_endpoint(kind: klio_runtime::RangeKind, v: i64) -> Value {
    match kind {
        klio_runtime::RangeKind::Long => Value::Long(v),
        klio_runtime::RangeKind::Int => Value::Int(v as i32),
        klio_runtime::RangeKind::Char => char::from_u32(v as u32)
            .map(Value::Char)
            .unwrap_or(Value::Char('\0')),
    }
}

fn range_first(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(Value::Range { start, kind, .. }) = ctx.args.first() else {
        return Err(RuntimeError::Type("first requires a Range receiver".into()));
    };
    Ok(range_endpoint(*kind, *start))
}

fn range_last(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(Value::Range { end, kind, .. }) = ctx.args.first() else {
        return Err(RuntimeError::Type("last requires a Range receiver".into()));
    };
    Ok(range_endpoint(*kind, *end))
}

fn range_step_field(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(Value::Range { step, kind, .. }) = ctx.args.first() else {
        return Err(RuntimeError::Type("step requires a Range receiver".into()));
    };
    Ok(range_endpoint(*kind, step.abs()))
}

fn range_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(v @ Value::Range { .. }) = ctx.args.first() else {
        return Err(RuntimeError::Type("toString requires a Range receiver".into()));
    };
    Ok(Value::String(Rc::new(format!("{v}"))))
}

fn range_contains(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(Value::Range { start, end, step, .. }) = ctx.args.first() else {
        return Err(RuntimeError::Type("contains requires a Range receiver".into()));
    };
    let Some(n) = ctx.args.get(1).and_then(Value::as_i64) else {
        return Err(RuntimeError::Type("Range.contains requires an Int argument".into()));
    };
    let (lo, hi) = if *step > 0 { (*start, *end) } else { (*end, *start) };
    let in_bounds = n >= lo && n <= hi;
    if !in_bounds {
        return Ok(Value::Bool(false));
    }
    let s = step.abs();
    Ok(Value::Bool(((n - start) % s).abs() == 0 || s == 1))
}

fn range_is_empty(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(Value::Range { start, end, step, .. }) = ctx.args.first() else {
        return Err(RuntimeError::Type("isEmpty requires a Range receiver".into()));
    };
    let empty = if *step > 0 { start > end } else { start < end };
    Ok(Value::Bool(empty))
}

fn range_reversed(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(Value::Range { start, end, step, .. }) = ctx.args.first() else {
        return Err(RuntimeError::Type("reversed requires a Range receiver".into()));
    };
    Ok(Value::Range { start: *end, end: *start, step: -*step, kind: klio_runtime::RangeKind::Int })
}

fn range_to_list(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(Value::Range { start, end, step, .. }) = ctx.args.first() else {
        return Err(RuntimeError::Type("toList requires a Range receiver".into()));
    };
    let items: Vec<Value> = range_iter_int(*start, *end, *step).map(Value::new_int).collect();
    Ok(make_list(items, false))
}

fn range_count(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(Value::Range { start, end, step, .. }) = ctx.args.first() else {
        return Err(RuntimeError::Type("count requires a Range receiver".into()));
    };
    let n = range_iter_int(*start, *end, *step).count() as i64;
    Ok(Value::new_int(n))
}

fn range_sum(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(Value::Range { start, end, step, kind }) = ctx.args.first() else {
        return Err(RuntimeError::Type("sum requires a Range receiver".into()));
    };
    let s: i64 = range_iter_int(*start, *end, *step).sum();
    Ok(match kind {
        klio_runtime::RangeKind::Long => Value::Long(s),
        klio_runtime::RangeKind::Int => Value::new_int(s),
        klio_runtime::RangeKind::Char => Value::new_int(s),
    })
}

// ============================================================
// Additional math
// ============================================================

fn math_asin(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(as_double(arg1(ctx, "asin")?, "asin")?.asin()))
}
fn math_acos(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(as_double(arg1(ctx, "acos")?, "acos")?.acos()))
}
fn math_atan(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(as_double(arg1(ctx, "atan")?, "atan")?.atan()))
}
fn math_atan2(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (y, x) = arg2(ctx, "atan2")?;
    Ok(Value::Double(as_double(y, "atan2")?.atan2(as_double(x, "atan2")?)))
}

// ============================================================
// Additional String members
// ============================================================

fn string_substring_before(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.substringBefore")?;
    let delim = arg_as_string(
        ctx.args.get(1).ok_or_else(|| RuntimeError::Arity("substringBefore requires a delimiter".into()))?,
        "substringBefore",
    )?;
    let missing = match ctx.args.get(2) {
        Some(Value::String(d)) => (**d).clone(),
        Some(Value::Char(c)) => c.to_string(),
        _ => (**s).clone(),
    };
    let out = match s.find(&delim) {
        Some(i) => s[..i].to_string(),
        None => missing,
    };
    Ok(Value::String(Rc::new(out)))
}

fn string_substring_after(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.substringAfter")?;
    let delim = arg_as_string(
        ctx.args.get(1).ok_or_else(|| RuntimeError::Arity("substringAfter requires a delimiter".into()))?,
        "substringAfter",
    )?;
    let missing = match ctx.args.get(2) {
        Some(Value::String(d)) => (**d).clone(),
        Some(Value::Char(c)) => c.to_string(),
        _ => (**s).clone(),
    };
    let out = match s.find(&delim) {
        Some(i) => s[i + delim.len()..].to_string(),
        None => missing,
    };
    Ok(Value::String(Rc::new(out)))
}

fn string_substring_before_last(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.substringBeforeLast")?;
    let delim = arg_as_string(
        ctx.args.get(1).ok_or_else(|| RuntimeError::Arity("substringBeforeLast requires a delimiter".into()))?,
        "substringBeforeLast",
    )?;
    let missing = match ctx.args.get(2) {
        Some(Value::String(d)) => (**d).clone(),
        Some(Value::Char(c)) => c.to_string(),
        _ => (**s).clone(),
    };
    let out = match s.rfind(&delim) {
        Some(i) => s[..i].to_string(),
        None => missing,
    };
    Ok(Value::String(Rc::new(out)))
}

fn string_substring_after_last(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.substringAfterLast")?;
    let delim = arg_as_string(
        ctx.args.get(1).ok_or_else(|| RuntimeError::Arity("substringAfterLast requires a delimiter".into()))?,
        "substringAfterLast",
    )?;
    let missing = match ctx.args.get(2) {
        Some(Value::String(d)) => (**d).clone(),
        Some(Value::Char(c)) => c.to_string(),
        _ => (**s).clone(),
    };
    let out = match s.rfind(&delim) {
        Some(i) => s[i + delim.len()..].to_string(),
        None => missing,
    };
    Ok(Value::String(Rc::new(out)))
}

fn string_replace_first(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.replaceFirst")?;
    let old = arg_as_string(
        ctx.args.get(1).ok_or_else(|| RuntimeError::Arity("replaceFirst requires old".into()))?,
        "replaceFirst",
    )?;
    let new = arg_as_string(
        ctx.args.get(2).ok_or_else(|| RuntimeError::Arity("replaceFirst requires new".into()))?,
        "replaceFirst",
    )?;
    Ok(Value::String(Rc::new(s.replacen(&old, &new, 1))))
}

fn string_trim_indent(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.trimIndent")?;
    let lines: Vec<&str> = s.split('\n').collect();
    // Compute the minimum indent of non-blank lines.
    let min_indent = lines
        .iter()
        .filter(|l| !l.chars().all(char::is_whitespace))
        .map(|l| l.chars().take_while(|c| *c == ' ' || *c == '\t').count())
        .min()
        .unwrap_or(0);
    let mut out_lines: Vec<String> = lines
        .iter()
        .map(|l| {
            if l.chars().all(char::is_whitespace) {
                String::new()
            } else {
                l.chars().skip(min_indent).collect()
            }
        })
        .collect();
    // Trim leading and trailing blank lines.
    while out_lines.first().map_or(false, |l| l.is_empty()) {
        out_lines.remove(0);
    }
    while out_lines.last().map_or(false, |l| l.is_empty()) {
        out_lines.pop();
    }
    Ok(Value::String(Rc::new(out_lines.join("\n"))))
}

fn string_trim_margin(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.trimMargin")?;
    let prefix = match ctx.args.get(1) {
        None => "|".to_string(),
        Some(Value::String(p)) => (**p).clone(),
        Some(Value::Char(c)) => c.to_string(),
        Some(other) => format!("{other}"),
    };
    let lines: Vec<&str> = s.split('\n').collect();
    let mut out_lines: Vec<String> = Vec::with_capacity(lines.len());
    for l in &lines {
        let trimmed_start = l.trim_start_matches(|c: char| c == ' ' || c == '\t');
        if let Some(rest) = trimmed_start.strip_prefix(&prefix) {
            out_lines.push(rest.to_string());
        } else {
            out_lines.push((*l).to_string());
        }
    }
    // Trim a single leading/trailing blank line (matching Kotlin behavior).
    if out_lines.first().map_or(false, |l| l.chars().all(char::is_whitespace) && l.is_empty()) {
        out_lines.remove(0);
    }
    if out_lines.last().map_or(false, |l| l.chars().all(char::is_whitespace) && l.is_empty()) {
        out_lines.pop();
    }
    Ok(Value::String(Rc::new(out_lines.join("\n"))))
}

fn string_lines(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.lines")?;
    // Kotlin lines() splits on \r\n, \r, and \n.
    let normalized = s.replace("\r\n", "\n").replace('\r', "\n");
    let items: Vec<Value> = normalized
        .split('\n')
        .map(|p| Value::String(Rc::new(p.to_string())))
        .collect();
    Ok(make_list(items, false))
}

fn string_to_char_array(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.toCharArray")?;
    Ok(make_list(s.chars().map(Value::Char).collect(), false))
}

fn string_to_long(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.toLong")?;
    s.parse::<i64>()
        .map(Value::Long)
        .map_err(|_| {
            RuntimeError::Thrown(make_exception(
                "kotlin.NumberFormatException",
                Some(format!("For input string: \"{s}\"")),
            ))
        })
}

fn string_to_long_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.toLongOrNull")?;
    Ok(s.parse::<i64>().map(Value::Long).unwrap_or(Value::Null))
}

fn string_to_double_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.toDoubleOrNull")?;
    Ok(s.parse::<f64>().map(Value::Double).unwrap_or(Value::Null))
}

fn string_to_boolean(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.toBoolean")?;
    Ok(Value::Bool(s.eq_ignore_ascii_case("true")))
}

fn string_to_boolean_strict_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.toBooleanStrictOrNull")?;
    let r: &str = s;
    Ok(match r {
        "true" => Value::Bool(true),
        "false" => Value::Bool(false),
        _ => Value::Null,
    })
}

// ============================================================
// Additional Char
// ============================================================

fn char_uppercase_char(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let c = recv_char(ctx.args, "Char.uppercaseChar")?;
    let up = c.to_uppercase().next().unwrap_or(c);
    Ok(Value::Char(up))
}
fn char_lowercase_char(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let c = recv_char(ctx.args, "Char.lowercaseChar")?;
    let lo = c.to_lowercase().next().unwrap_or(c);
    Ok(Value::Char(lo))
}
fn char_digit_to_int_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let c = recv_char(ctx.args, "Char.digitToIntOrNull")?;
    Ok(c.to_digit(10).map(|d| Value::new_int(d)).unwrap_or(Value::Null))
}

// ============================================================
// Additional Int
// ============================================================

fn int_coerce_in(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = recv_int(ctx.args, "Int.coerceIn")?;
    match &ctx.args[1..] {
        [Value::Range { start, end, .. }] => {
            Ok(Value::new_int(v.max(*start).min(*end)))
        }
        [a, b] if a.is_integral() && b.is_integral() => {
            let lo = a.as_i64().unwrap();
            let hi = b.as_i64().unwrap();
            Ok(Value::new_int(v.max(lo).min(hi)))
        }
        _ => Err(RuntimeError::Type("coerceIn requires (min, max) or a range".into())),
    }
}

fn int_coerce_at_least(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = recv_int(ctx.args, "Int.coerceAtLeast")?;
    let Some(lo) = ctx.args.get(1).and_then(Value::as_i64) else {
        return Err(RuntimeError::Type("coerceAtLeast requires an Int".into()));
    };
    Ok(Value::new_int(v.max(lo)))
}

fn int_coerce_at_most(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = recv_int(ctx.args, "Int.coerceAtMost")?;
    let Some(hi) = ctx.args.get(1).and_then(Value::as_i64) else {
        return Err(RuntimeError::Type("coerceAtMost requires an Int".into()));
    };
    Ok(Value::new_int(v.min(hi)))
}

fn int_to_char(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = recv_int(ctx.args, "Int.toChar")?;
    let c = char::from_u32(v as u32).ok_or_else(|| {
        RuntimeError::Thrown(make_exception(
            "kotlin.IllegalArgumentException",
            Some(format!("Invalid Char code: {v}")),
        ))
    })?;
    Ok(Value::Char(c))
}

// ============================================================
// Additional List ops
// ============================================================

fn coll_list_first_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() >= 2 {
        let items = iterable_items(&ctx.args[0], "firstOrNull")?;
        let block = ctx.args[1].clone();
        let CallCtx { out, host, .. } = ctx;
        for v in items {
            if matches!(host.invoke_callable(&block, std::slice::from_ref(&v), *out)?, Value::Bool(true)) {
                return Ok(v);
            }
        }
        return Ok(Value::Null);
    }
    let it = recv_list_items(ctx.args, "List.firstOrNull")?;
    Ok(it.borrow().first().cloned().unwrap_or(Value::Null))
}
fn coll_list_last_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() >= 2 {
        let items = iterable_items(&ctx.args[0], "lastOrNull")?;
        let block = ctx.args[1].clone();
        let CallCtx { out, host, .. } = ctx;
        let mut found: Option<Value> = None;
        for v in items {
            if matches!(host.invoke_callable(&block, std::slice::from_ref(&v), *out)?, Value::Bool(true)) {
                found = Some(v);
            }
        }
        return Ok(found.unwrap_or(Value::Null));
    }
    let it = recv_list_items(ctx.args, "List.lastOrNull")?;
    Ok(it.borrow().last().cloned().unwrap_or(Value::Null))
}
fn coll_list_single(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.single")?;
    let b = it.borrow();
    match b.len() {
        0 => Err(RuntimeError::Thrown(make_exception(
            "kotlin.NoSuchElementException",
            Some("List is empty.".into()),
        ))),
        1 => Ok(b[0].clone()),
        _ => Err(RuntimeError::Thrown(make_exception(
            "kotlin.IllegalArgumentException",
            Some("List has more than one element.".into()),
        ))),
    }
}
fn coll_list_single_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.singleOrNull")?;
    let b = it.borrow();
    Ok(if b.len() == 1 { b[0].clone() } else { Value::Null })
}

fn coll_list_flatten(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.flatten")?;
    let mut out: Vec<Value> = Vec::new();
    for v in it.borrow().iter() {
        match v {
            Value::List { items, .. } | Value::Set { items, .. } => {
                out.extend(items.borrow().clone());
            }
            other => {
                return Err(RuntimeError::Type(format!(
                    "flatten requires nested collections, got {other:?}"
                )))
            }
        }
    }
    Ok(make_list(out, false))
}

fn coll_list_unzip(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.unzip")?;
    let mut firsts: Vec<Value> = Vec::new();
    let mut seconds: Vec<Value> = Vec::new();
    for v in it.borrow().iter() {
        let Value::Pair(a, b) = v else {
            return Err(RuntimeError::Type("unzip requires List<Pair<A, B>>".into()));
        };
        firsts.push((**a).clone());
        seconds.push((**b).clone());
    }
    Ok(Value::Pair(
        Box::new(make_list(firsts, false)),
        Box::new(make_list(seconds, false)),
    ))
}

fn coll_list_contains_all(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.containsAll")?;
    let other = match ctx.args.get(1) {
        Some(Value::List { items, .. }) | Some(Value::Set { items, .. }) => items.borrow().clone(),
        _ => return Err(RuntimeError::Type("containsAll requires a collection".into())),
    };
    let me = it.borrow();
    Ok(Value::Bool(
        other.iter().all(|o| me.iter().any(|m| Value::structural_eq(m, o))),
    ))
}

fn coll_list_to_list(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.toList")?;
    Ok(make_list(it.borrow().clone(), false))
}

fn coll_list_to_mutable_list(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.toMutableList")?;
    Ok(make_list(it.borrow().clone(), true))
}

fn coll_list_to_set(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.toSet")?;
    Ok(make_set(it.borrow().clone(), false))
}

fn coll_list_to_mutable_set(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.toMutableSet")?;
    Ok(make_set(it.borrow().clone(), true))
}

fn coll_list_count_no_pred(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() >= 2 {
        let items = iterable_items(&ctx.args[0], "count")?;
        let block = ctx.args[1].clone();
        let CallCtx { out, host, .. } = ctx;
        let mut n = 0i64;
        for v in items {
            if matches!(host.invoke_callable(&block, std::slice::from_ref(&v), *out)?, Value::Bool(true)) {
                n += 1;
            }
        }
        return Ok(Value::new_int(n));
    }
    let it = recv_list_items(ctx.args, "List.count")?;
    Ok(Value::new_int(it.borrow().len()))
}

fn coll_list_with_index(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.withIndex")?;
    let indexed: Vec<Value> = it
        .borrow()
        .iter()
        .enumerate()
        .map(|(i, v)| Value::Pair(Box::new(Value::new_int(i)), Box::new(v.clone())))
        .collect();
    Ok(make_list(indexed, false))
}

fn coll_mut_list_add_all(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "MutableList.addAll")?;
    let Some(arg) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("addAll requires an argument".into()));
    };
    let to_add: Vec<Value> = match arg {
        Value::List { items, .. } | Value::Set { items, .. } => items.borrow().clone(),
        other => {
            return Err(RuntimeError::Type(format!(
                "addAll requires a collection, got {other:?}"
            )))
        }
    };
    let changed = !to_add.is_empty();
    it.borrow_mut().extend(to_add);
    Ok(Value::Bool(changed))
}

fn coll_mut_list_remove(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "MutableList.remove")?;
    let Some(arg) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("remove requires an argument".into()));
    };
    let mut b = it.borrow_mut();
    if let Some(pos) = b.iter().position(|v| Value::structural_eq(v, arg)) {
        b.remove(pos);
        Ok(Value::Bool(true))
    } else {
        Ok(Value::Bool(false))
    }
}

fn coll_mut_list_remove_all(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "MutableList.removeAll")?;
    let other: Vec<Value> = match ctx.args.get(1) {
        Some(Value::List { items, .. }) | Some(Value::Set { items, .. }) => items.borrow().clone(),
        _ => return Err(RuntimeError::Type("removeAll requires a collection".into())),
    };
    let mut b = it.borrow_mut();
    let before = b.len();
    b.retain(|v| !other.iter().any(|o| Value::structural_eq(v, o)));
    Ok(Value::Bool(b.len() != before))
}

fn coll_mut_list_retain_all(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "MutableList.retainAll")?;
    let other: Vec<Value> = match ctx.args.get(1) {
        Some(Value::List { items, .. }) | Some(Value::Set { items, .. }) => items.borrow().clone(),
        _ => return Err(RuntimeError::Type("retainAll requires a collection".into())),
    };
    let mut b = it.borrow_mut();
    let before = b.len();
    b.retain(|v| other.iter().any(|o| Value::structural_eq(v, o)));
    Ok(Value::Bool(b.len() != before))
}

fn coll_mut_list_set(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "MutableList.set")?;
    let Some(Value::Int(i)) = ctx.args.get(1) else {
        return Err(RuntimeError::Type("set requires an Int index".into()));
    };
    let Some(value) = ctx.args.get(2) else {
        return Err(RuntimeError::Arity("set requires (index, value)".into()));
    };
    let mut b = it.borrow_mut();
    if *i < 0 || (*i as usize) >= b.len() {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IndexOutOfBoundsException",
            Some(format!("Index {i} out of bounds for length {}", b.len())),
        )));
    }
    let prev = std::mem::replace(&mut b[*i as usize], value.clone());
    Ok(prev)
}

// ============================================================
// Additional Set ops
// ============================================================

fn coll_set_contains_all(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "Set.containsAll")?;
    let other = match ctx.args.get(1) {
        Some(Value::List { items, .. }) | Some(Value::Set { items, .. }) => items.borrow().clone(),
        _ => return Err(RuntimeError::Type("containsAll requires a collection".into())),
    };
    let me = it.borrow();
    Ok(Value::Bool(
        other.iter().all(|o| me.iter().any(|m| Value::structural_eq(m, o))),
    ))
}

fn coll_set_to_list(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "Set.toList")?;
    Ok(make_list(it.borrow().clone(), false))
}

fn coll_set_to_mutable_list(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "Set.toMutableList")?;
    Ok(make_list(it.borrow().clone(), true))
}

fn coll_set_to_set_(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "Set.toSet")?;
    Ok(make_set(it.borrow().clone(), false))
}

fn coll_set_to_mutable_set_(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "Set.toMutableSet")?;
    Ok(make_set(it.borrow().clone(), true))
}

fn coll_set_with_index(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "Set.withIndex")?;
    let indexed: Vec<Value> = it
        .borrow()
        .iter()
        .enumerate()
        .map(|(i, v)| Value::Pair(Box::new(Value::new_int(i)), Box::new(v.clone())))
        .collect();
    Ok(make_list(indexed, false))
}

fn coll_set_count_no_pred(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() >= 2 {
        let items = iterable_items(&ctx.args[0], "count")?;
        let block = ctx.args[1].clone();
        let CallCtx { out, host, .. } = ctx;
        let mut n = 0i64;
        for v in items {
            if matches!(host.invoke_callable(&block, std::slice::from_ref(&v), *out)?, Value::Bool(true)) {
                n += 1;
            }
        }
        return Ok(Value::new_int(n));
    }
    let it = recv_set_items(ctx.args, "Set.count")?;
    Ok(Value::new_int(it.borrow().len()))
}

fn coll_mut_set_add_all(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "MutableSet.addAll")?;
    let to_add: Vec<Value> = match ctx.args.get(1) {
        Some(Value::List { items, .. }) | Some(Value::Set { items, .. }) => items.borrow().clone(),
        _ => return Err(RuntimeError::Type("addAll requires a collection".into())),
    };
    let mut b = it.borrow_mut();
    let mut changed = false;
    for v in to_add {
        if !b.iter().any(|x| Value::structural_eq(x, &v)) {
            b.push(v);
            changed = true;
        }
    }
    Ok(Value::Bool(changed))
}

// ============================================================
// Additional Map ops
// ============================================================

fn coll_map_get_or_default(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = recv_map_entries(ctx.args, "Map.getOrDefault")?;
    let Some(key) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("getOrDefault requires (key, default)".into()));
    };
    let Some(default) = ctx.args.get(2) else {
        return Err(RuntimeError::Arity("getOrDefault requires (key, default)".into()));
    };
    Ok(entries
        .borrow()
        .iter()
        .find(|(k, _)| Value::structural_eq(k, key))
        .map(|(_, v)| v.clone())
        .unwrap_or_else(|| default.clone()))
}

fn coll_map_get_value(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = recv_map_entries(ctx.args, "Map.getValue")?;
    let Some(key) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("getValue requires a key".into()));
    };
    entries
        .borrow()
        .iter()
        .find(|(k, _)| Value::structural_eq(k, key))
        .map(|(_, v)| v.clone())
        .ok_or_else(|| {
            RuntimeError::Thrown(make_exception(
                "kotlin.NoSuchElementException",
                Some(format!("Key {key} is missing in the map.")),
            ))
        })
}

fn coll_map_to_list(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = recv_map_entries(ctx.args, "Map.toList")?;
    let pairs: Vec<Value> = entries
        .borrow()
        .iter()
        .map(|(k, v)| Value::Pair(Box::new(k.clone()), Box::new(v.clone())))
        .collect();
    Ok(make_list(pairs, false))
}

fn coll_map_count_no_pred(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() >= 2 {
        let items = iterable_items(&ctx.args[0], "count")?;
        let block = ctx.args[1].clone();
        let CallCtx { out, host, .. } = ctx;
        let mut n = 0i64;
        for v in items {
            if matches!(host.invoke_callable(&block, std::slice::from_ref(&v), *out)?, Value::Bool(true)) {
                n += 1;
            }
        }
        return Ok(Value::new_int(n));
    }
    let entries = recv_map_entries(ctx.args, "Map.count")?;
    Ok(Value::new_int(entries.borrow().len()))
}

fn coll_mut_map_put_all(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = recv_map_entries(ctx.args, "MutableMap.putAll")?;
    let Some(arg) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("putAll requires a Map".into()));
    };
    let to_add: Vec<(Value, Value)> = match arg {
        Value::Map { entries, .. } => entries.borrow().clone(),
        _ => return Err(RuntimeError::Type("putAll requires a Map".into())),
    };
    let mut b = entries.borrow_mut();
    for (k, v) in to_add {
        if let Some(slot) = b.iter_mut().find(|(kk, _)| Value::structural_eq(kk, &k)) {
            slot.1 = v;
        } else {
            b.push((k, v));
        }
    }
    Ok(Value::Unit)
}

fn coll_mut_map_set(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    // Same as put but returns Unit (operator form `m[k] = v`).
    let _ = coll_mut_map_put(ctx)?;
    Ok(Value::Unit)
}

// ============================================================
// Pair extras
// ============================================================

fn pair_to_list(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Value::Pair(a, b) = recv_pair(ctx.args, "Pair.toList")? else { unreachable!() };
    Ok(make_list(vec![(**a).clone(), (**b).clone()], false))
}

// ============================================================
// Triple
// ============================================================

fn recv_triple<'a>(args: &'a [Value], what: &str) -> Result<&'a Value, RuntimeError> {
    args.first()
        .filter(|v| matches!(v, Value::Triple(_, _, _)))
        .ok_or_else(|| RuntimeError::Type(format!("{what} requires a Triple receiver")))
}

fn coll_triple_ctor(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    match ctx.args {
        [a, b, c] => Ok(Value::Triple(
            Box::new(a.clone()),
            Box::new(b.clone()),
            Box::new(c.clone()),
        )),
        _ => Err(RuntimeError::Arity("Triple expects 3 arguments".into())),
    }
}

fn triple_first(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Value::Triple(a, _, _) = recv_triple(ctx.args, "Triple.first")? else { unreachable!() };
    Ok((**a).clone())
}
fn triple_second(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Value::Triple(_, b, _) = recv_triple(ctx.args, "Triple.second")? else { unreachable!() };
    Ok((**b).clone())
}
fn triple_third(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Value::Triple(_, _, c) = recv_triple(ctx.args, "Triple.third")? else { unreachable!() };
    Ok((**c).clone())
}
fn triple_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = recv_triple(ctx.args, "Triple.toString")?;
    Ok(Value::String(Rc::new(format!("{v}"))))
}
fn triple_to_list(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Value::Triple(a, b, c) = recv_triple(ctx.args, "Triple.toList")? else { unreachable!() };
    Ok(make_list(vec![(**a).clone(), (**b).clone(), (**c).clone()], false))
}

// ============================================================
// Comparator factories
// ============================================================

fn comparator_natural_order(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    // Empty step chain — the interp's sort path treats an empty-step
    // Comparator as "compare items directly via the natural order".
    Ok(Value::Comparator { steps: Rc::new(Vec::new()), descending: false })
}

fn comparator_reverse_order(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Comparator { steps: Rc::new(Vec::new()), descending: true })
}

// ============================================================
// Result
// ============================================================

fn recv_result<'a>(args: &'a [Value], what: &str) -> Result<(bool, &'a Value), RuntimeError> {
    match args.first() {
        Some(Value::Result { ok, payload }) => Ok((*ok, payload.as_ref())),
        _ => Err(RuntimeError::Type(format!("{what} requires a Result receiver"))),
    }
}

fn result_is_success(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (ok, _) = recv_result(ctx.args, "Result.isSuccess")?;
    Ok(Value::Bool(ok))
}

fn result_is_failure(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (ok, _) = recv_result(ctx.args, "Result.isFailure")?;
    Ok(Value::Bool(!ok))
}

fn result_get_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (ok, payload) = recv_result(ctx.args, "Result.getOrNull")?;
    if ok { Ok(payload.clone()) } else { Ok(Value::Null) }
}

fn result_exception_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (ok, payload) = recv_result(ctx.args, "Result.exceptionOrNull")?;
    if ok { Ok(Value::Null) } else { Ok(payload.clone()) }
}

fn result_get_or_default(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (ok, payload) = recv_result(ctx.args, "Result.getOrDefault")?;
    let default = ctx
        .args
        .get(1)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("Result.getOrDefault requires a default".into()))?;
    if ok { Ok(payload.clone()) } else { Ok(default) }
}

fn result_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (ok, payload) = recv_result(ctx.args, "Result.toString")?;
    let s = if ok {
        format!("Success({})", payload)
    } else {
        format!("Failure({})", payload)
    };
    Ok(Value::String(Rc::new(s)))
}

// ============================================================
// Regex / MatchResult / MatchGroup
// ============================================================

use klio_runtime::{MatchData, MatchGroupData, RegexData};

fn regex_arg(args: &[Value], what: &str) -> Result<Rc<RegexData>, RuntimeError> {
    match args.first() {
        Some(Value::Regex(r)) => Ok(Rc::clone(r)),
        _ => Err(RuntimeError::Type(format!("{what} requires a Regex receiver"))),
    }
}

/// Preprocess a Kotlin / Java-flavored pattern into a Rust-regex-compatible
/// pattern. Today: expand `\Q...\E` literal blocks (which Rust's `regex`
/// doesn't support) into byte-by-byte escaped equivalents.
fn preprocess_pattern(src: &str) -> String {
    let mut out = String::with_capacity(src.len());
    let mut chars = src.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.peek() {
                Some('Q') => {
                    chars.next();
                    let mut lit = String::new();
                    while let Some(&nc) = chars.peek() {
                        if nc == '\\' {
                            let mut clone = chars.clone();
                            clone.next();
                            if let Some('E') = clone.peek() {
                                chars.next();
                                chars.next();
                                break;
                            }
                        }
                        lit.push(nc);
                        chars.next();
                    }
                    out.push_str(&regex::escape(&lit));
                    continue;
                }
                Some(_) => {
                    out.push('\\');
                    out.push(chars.next().unwrap());
                    continue;
                }
                None => {
                    out.push('\\');
                    continue;
                }
            }
        }
        out.push(c);
    }
    out
}

fn compile_regex(pattern: &str) -> Result<Rc<RegexData>, RuntimeError> {
    let prepared = preprocess_pattern(pattern);
    match regex::Regex::new(&prepared) {
        Ok(re) => Ok(Rc::new(RegexData {
            pattern: Rc::new(pattern.to_string()),
            re,
        })),
        Err(e) => Err(RuntimeError::Thrown(make_exception(
            "kotlin.text.PatternSyntaxException",
            Some(format!("invalid regex: {e}")),
        ))),
    }
}

fn byte_to_char(s: &str, byte: usize) -> i64 {
    s[..byte].chars().count() as i64
}

fn build_match(re: &Rc<RegexData>, input: &Rc<String>, caps: regex::Captures<'_>) -> MatchData {
    let mut groups: Vec<Option<MatchGroupData>> = Vec::with_capacity(caps.len());
    for i in 0..caps.len() {
        match caps.get(i) {
            Some(m) => {
                let start = byte_to_char(input, m.start());
                let end = m.end();
                let end_char = byte_to_char(input, end);
                let end_inclusive = if end_char == 0 && start == 0 && m.as_str().is_empty() {
                    -1
                } else {
                    end_char - 1
                };
                groups.push(Some(MatchGroupData {
                    value: Rc::new(m.as_str().to_string()),
                    start,
                    end_inclusive,
                }));
            }
            None => groups.push(None),
        }
    }
    let end_byte = caps.get(0).map_or(0, |m| m.end());
    MatchData {
        input: Rc::clone(input),
        groups,
        end_byte,
        regex: Rc::clone(re),
    }
}

fn regex_ctor(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let pat = match ctx.args.first() {
        Some(Value::String(s)) => (**s).clone(),
        _ => return Err(RuntimeError::Type("Regex requires a String pattern".into())),
    };
    Ok(Value::Regex(compile_regex(&pat)?))
}

fn regex_pattern(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let r = regex_arg(ctx.args, "Regex.pattern")?;
    Ok(Value::String(Rc::clone(&r.pattern)))
}

fn regex_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let r = regex_arg(ctx.args, "Regex.toString")?;
    Ok(Value::String(Rc::clone(&r.pattern)))
}

fn regex_matches(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let r = regex_arg(ctx.args, "Regex.matches")?;
    let s = match ctx.args.get(1) {
        Some(Value::String(s)) => s.clone(),
        _ => return Err(RuntimeError::Type("Regex.matches requires a String input".into())),
    };
    Ok(Value::Bool(
        r.re.find(&s).is_some_and(|m| m.start() == 0 && m.end() == s.len()),
    ))
}

fn regex_contains_match_in(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let r = regex_arg(ctx.args, "Regex.containsMatchIn")?;
    let s = match ctx.args.get(1) {
        Some(Value::String(s)) => s.clone(),
        _ => return Err(RuntimeError::Type(
            "Regex.containsMatchIn requires a String".into(),
        )),
    };
    Ok(Value::Bool(r.re.is_match(&s)))
}

fn regex_find(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let r = regex_arg(ctx.args, "Regex.find")?;
    let s = match ctx.args.get(1) {
        Some(Value::String(s)) => s.clone(),
        _ => return Err(RuntimeError::Type("Regex.find requires a String".into())),
    };
    let start = match ctx.args.get(2) {
        None => 0usize,
        Some(v) if v.is_integral() => {
            let n = v.as_i64().unwrap();
            let mut bi = 0usize;
            for (i, (b, _)) in s.char_indices().enumerate() {
                if i as i64 == n {
                    bi = b;
                    break;
                }
                bi = s.len();
            }
            if n == 0 { 0 } else { bi }
        }
        _ => return Err(RuntimeError::Type("Regex.find startIndex must be Int".into())),
    };
    let caps = r.re.captures_at(&s, start);
    match caps {
        Some(c) => Ok(Value::Match(Rc::new(build_match(&r, &s, c)))),
        None => Ok(Value::Null),
    }
}

fn regex_find_all(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let r = regex_arg(ctx.args, "Regex.findAll")?;
    let s = match ctx.args.get(1) {
        Some(Value::String(s)) => s.clone(),
        _ => return Err(RuntimeError::Type("Regex.findAll requires a String".into())),
    };
    let mut items = Vec::new();
    for caps in r.re.captures_iter(&s) {
        items.push(Value::Match(Rc::new(build_match(&r, &s, caps))));
    }
    Ok(make_sequence(items))
}

fn regex_match_entire(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let r = regex_arg(ctx.args, "Regex.matchEntire")?;
    let s = match ctx.args.get(1) {
        Some(Value::String(s)) => s.clone(),
        _ => return Err(RuntimeError::Type("Regex.matchEntire requires a String".into())),
    };
    let Some(caps) = r.re.captures(&s) else { return Ok(Value::Null) };
    let m0 = caps.get(0).unwrap();
    if m0.start() == 0 && m0.end() == s.len() {
        Ok(Value::Match(Rc::new(build_match(&r, &s, caps))))
    } else {
        Ok(Value::Null)
    }
}

fn regex_match_at(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let r = regex_arg(ctx.args, "Regex.matchAt")?;
    let s = match ctx.args.get(1) {
        Some(Value::String(s)) => s.clone(),
        _ => return Err(RuntimeError::Type("Regex.matchAt requires a String".into())),
    };
    let idx = match ctx.args.get(2).and_then(Value::as_i64) {
        Some(n) => n,
        _ => return Err(RuntimeError::Type("Regex.matchAt requires Int index".into())),
    };
    let mut byte = s.len();
    for (i, (b, _)) in s.char_indices().enumerate() {
        if i as i64 == idx {
            byte = b;
            break;
        }
    }
    let Some(caps) = r.re.captures_at(&s, byte) else { return Ok(Value::Null) };
    if caps.get(0).is_some_and(|m| m.start() == byte) {
        Ok(Value::Match(Rc::new(build_match(&r, &s, caps))))
    } else {
        Ok(Value::Null)
    }
}

fn regex_matches_at(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    match regex_match_at(ctx)? {
        Value::Null => Ok(Value::Bool(false)),
        _ => Ok(Value::Bool(true)),
    }
}

fn regex_replace(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let r = regex_arg(ctx.args, "Regex.replace")?;
    let s = match ctx.args.get(1) {
        Some(Value::String(s)) => s.clone(),
        _ => return Err(RuntimeError::Type("Regex.replace requires a String".into())),
    };
    let repl = match ctx.args.get(2) {
        Some(Value::String(s)) => (**s).clone(),
        _ => return Err(RuntimeError::Type(
            "Regex.replace lambda form not supported here".into(),
        )),
    };
    Ok(Value::String(Rc::new(r.re.replace_all(&s, repl.as_str()).into_owned())))
}

fn regex_replace_first(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let r = regex_arg(ctx.args, "Regex.replaceFirst")?;
    let s = match ctx.args.get(1) {
        Some(Value::String(s)) => s.clone(),
        _ => return Err(RuntimeError::Type("Regex.replaceFirst requires a String".into())),
    };
    let repl = match ctx.args.get(2) {
        Some(Value::String(s)) => (**s).clone(),
        _ => return Err(RuntimeError::Type(
            "Regex.replaceFirst requires a String replacement".into(),
        )),
    };
    Ok(Value::String(Rc::new(r.re.replace(&s, repl.as_str()).into_owned())))
}

fn regex_split(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let r = regex_arg(ctx.args, "Regex.split")?;
    let s = match ctx.args.get(1) {
        Some(Value::String(s)) => s.clone(),
        _ => return Err(RuntimeError::Type("Regex.split requires a String".into())),
    };
    let limit = match ctx.args.get(2) {
        None => 0i64,
        Some(v) if v.is_integral() => v.as_i64().unwrap(),
        _ => return Err(RuntimeError::Type("Regex.split limit must be Int".into())),
    };
    let parts: Vec<&str> = if limit <= 0 {
        r.re.split(&s).collect()
    } else {
        r.re.splitn(&s, limit as usize).collect()
    };
    let items: Vec<Value> = parts
        .into_iter()
        .map(|p| Value::String(Rc::new(p.to_string())))
        .collect();
    Ok(make_list(items, false))
}

fn kotlin_literal_escape(s: &str) -> String {
    // Kotlin renders Regex.escape("x") as `\Qx\E`. The `\E` sentinel inside
    // the source itself needs to terminate and re-open the literal block.
    let parts: Vec<&str> = s.split("\\E").collect();
    let mut out = String::with_capacity(s.len() + 4);
    for (i, part) in parts.iter().enumerate() {
        if i > 0 {
            out.push_str("\\E\\\\E\\Q");
        }
        out.push_str("\\Q");
        out.push_str(part);
        out.push_str("\\E");
    }
    if out.is_empty() {
        "\\Q\\E".into()
    } else {
        out
    }
}

fn regex_static_escape(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = match ctx.args.first() {
        Some(Value::String(s)) => (**s).clone(),
        _ => return Err(RuntimeError::Type(
            "Regex.escape requires a String literal".into(),
        )),
    };
    Ok(Value::String(Rc::new(kotlin_literal_escape(&s))))
}

fn regex_from_literal(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = match ctx.args.first() {
        Some(Value::String(s)) => (**s).clone(),
        _ => return Err(RuntimeError::Type(
            "Regex.fromLiteral requires a String".into(),
        )),
    };
    Ok(Value::Regex(compile_regex(&kotlin_literal_escape(&s))?))
}

fn regex_static_escape_replacement(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = match ctx.args.first() {
        Some(Value::String(s)) => (**s).clone(),
        _ => return Err(RuntimeError::Type(
            "Regex.escapeReplacement requires a String".into(),
        )),
    };
    // Rust's regex replacement only needs `$` escaped; `\` is literal.
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        if c == '$' || c == '\\' {
            out.push('\\');
        }
        out.push(c);
    }
    Ok(Value::String(Rc::new(out)))
}

fn match_arg(args: &[Value], what: &str) -> Result<Rc<MatchData>, RuntimeError> {
    match args.first() {
        Some(Value::Match(m)) => Ok(Rc::clone(m)),
        _ => Err(RuntimeError::Type(format!(
            "{what} requires a MatchResult receiver"
        ))),
    }
}

fn match_result_value(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let m = match_arg(ctx.args, "MatchResult.value")?;
    let g0 = m.groups.first().and_then(|g| g.as_ref()).ok_or_else(|| {
        RuntimeError::Type("MatchResult has no whole-match group".into())
    })?;
    Ok(Value::String(Rc::clone(&g0.value)))
}

fn match_result_range(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let m = match_arg(ctx.args, "MatchResult.range")?;
    let g0 = m.groups.first().and_then(|g| g.as_ref()).ok_or_else(|| {
        RuntimeError::Type("MatchResult has no whole-match group".into())
    })?;
    Ok(Value::Range { start: g0.start, end: g0.end_inclusive, step: 1, kind: klio_runtime::RangeKind::Int })
}

fn match_result_group_values(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let m = match_arg(ctx.args, "MatchResult.groupValues")?;
    let items: Vec<Value> = m
        .groups
        .iter()
        .map(|g| match g {
            Some(gd) => Value::String(Rc::clone(&gd.value)),
            None => Value::String(Rc::new(String::new())),
        })
        .collect();
    Ok(make_list(items, false))
}

fn match_result_groups(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let m = match_arg(ctx.args, "MatchResult.groups")?;
    let items: Vec<Value> = m
        .groups
        .iter()
        .map(|g| match g {
            Some(gd) => Value::MatchGroup {
                value: Rc::clone(&gd.value),
                start: gd.start,
                end_inclusive: gd.end_inclusive,
            },
            None => Value::Null,
        })
        .collect();
    Ok(make_list(items, false))
}

fn match_result_next(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let m = match_arg(ctx.args, "MatchResult.next")?;
    let mut start = m.end_byte;
    // Avoid infinite loops on zero-width matches: advance one char.
    let g0 = m.groups.first().and_then(|g| g.as_ref());
    if let Some(g) = g0 {
        if g.end_inclusive < g.start {
            if let Some((next_b, _)) = m.input[start..].char_indices().nth(1) {
                start += next_b;
            } else {
                start = m.input.len();
            }
        }
    }
    if start > m.input.len() {
        return Ok(Value::Null);
    }
    match m.regex.re.captures_at(&m.input, start) {
        Some(c) => Ok(Value::Match(Rc::new(build_match(&m.regex, &m.input, c)))),
        None => Ok(Value::Null),
    }
}

fn match_result_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let m = match_arg(ctx.args, "MatchResult.toString")?;
    let g0 = m.groups.first().and_then(|g| g.as_ref());
    Ok(Value::String(Rc::new(
        g0.map(|g| (*g.value).clone()).unwrap_or_default(),
    )))
}

fn match_group_value(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    match ctx.args.first() {
        Some(Value::MatchGroup { value, .. }) => Ok(Value::String(Rc::clone(value))),
        _ => Err(RuntimeError::Type(
            "MatchGroup.value requires a MatchGroup receiver".into(),
        )),
    }
}

fn match_group_range(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    match ctx.args.first() {
        Some(Value::MatchGroup { start, end_inclusive, .. }) => Ok(Value::Range {
            start: *start,
            end: *end_inclusive,
            step: 1,
            kind: klio_runtime::RangeKind::Int,
        }),
        _ => Err(RuntimeError::Type(
            "MatchGroup.range requires a MatchGroup receiver".into(),
        )),
    }
}

// ============================================================
// StringBuilder
// ============================================================

fn sb_arg(args: &[Value], what: &str) -> Result<Rc<RefCell<String>>, RuntimeError> {
    match args.first() {
        Some(Value::StringBuilder(s)) => Ok(Rc::clone(s)),
        _ => Err(RuntimeError::Type(format!(
            "{what} requires a StringBuilder receiver"
        ))),
    }
}

fn string_builder_ctor(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let seed = match ctx.args {
        [] => String::new(),
        [Value::String(s)] => (**s).clone(),
        [Value::Int(n)] => {
            if *n < 0 {
                return Err(RuntimeError::Thrown(make_exception(
                    "kotlin.NegativeArraySizeException",
                    Some(format!("{n}")),
                )));
            }
            String::with_capacity(*n as usize)
        }
        _ => return Err(RuntimeError::Type(
            "StringBuilder takes 0 or 1 argument".into(),
        )),
    };
    Ok(Value::StringBuilder(Rc::new(RefCell::new(seed))))
}

fn append_value(buf: &mut String, v: &Value) {
    match v {
        Value::Null => buf.push_str("null"),
        Value::String(s) => buf.push_str(s),
        Value::Char(c) => buf.push(*c),
        other => {
            use std::fmt::Write;
            let _ = write!(buf, "{other}");
        }
    }
}

fn string_builder_append(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.append")?;
    {
        let mut buf = sb.borrow_mut();
        for v in &ctx.args[1..] {
            append_value(&mut buf, v);
        }
    }
    Ok(Value::StringBuilder(sb))
}

fn string_builder_append_line(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.appendLine")?;
    {
        let mut buf = sb.borrow_mut();
        for v in &ctx.args[1..] {
            append_value(&mut buf, v);
        }
        buf.push('\n');
    }
    Ok(Value::StringBuilder(sb))
}

fn string_builder_length(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.length")?;
    Ok(Value::new_int(sb.borrow().chars().count()))
}

fn string_builder_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.toString")?;
    Ok(Value::String(Rc::new(sb.borrow().clone())))
}

fn string_builder_get(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.get")?;
    let idx = match ctx.args.get(1).and_then(Value::as_i64) {
        Some(n) => n,
        _ => return Err(RuntimeError::Type(
            "StringBuilder[index] requires Int".into(),
        )),
    };
    let buf = sb.borrow();
    let n = buf.chars().count() as i64;
    if idx < 0 || idx >= n {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IndexOutOfBoundsException",
            Some(format!("index: {idx}, length: {n}")),
        )));
    }
    Ok(Value::Char(buf.chars().nth(idx as usize).unwrap()))
}

fn string_builder_is_empty(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.isEmpty")?;
    Ok(Value::Bool(sb.borrow().is_empty()))
}

fn string_builder_is_not_empty(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.isNotEmpty")?;
    Ok(Value::Bool(!sb.borrow().is_empty()))
}

fn string_builder_clear(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.clear")?;
    sb.borrow_mut().clear();
    Ok(Value::StringBuilder(sb))
}

fn sb_char_byte(buf: &str, idx: i64) -> Option<usize> {
    if idx < 0 {
        return None;
    }
    if idx as usize == buf.chars().count() {
        return Some(buf.len());
    }
    buf.char_indices().nth(idx as usize).map(|(b, _)| b)
}

fn string_builder_insert(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.insert")?;
    let idx = match ctx.args.get(1).and_then(Value::as_i64) {
        Some(n) => n,
        _ => return Err(RuntimeError::Type("insert index must be Int".into())),
    };
    let v = ctx.args.get(2).ok_or_else(|| {
        RuntimeError::Arity("insert requires a value".into())
    })?;
    let mut piece = String::new();
    append_value(&mut piece, v);
    let mut buf = sb.borrow_mut();
    let n = buf.chars().count() as i64;
    if idx < 0 || idx > n {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IndexOutOfBoundsException",
            Some(format!("index: {idx}, length: {n}")),
        )));
    }
    let byte = sb_char_byte(&buf, idx).unwrap();
    buf.insert_str(byte, &piece);
    drop(buf);
    Ok(Value::StringBuilder(sb))
}

fn string_builder_delete_at(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.deleteAt")?;
    let idx = match ctx.args.get(1).and_then(Value::as_i64) {
        Some(n) => n,
        _ => return Err(RuntimeError::Type("deleteAt index must be Int".into())),
    };
    let mut buf = sb.borrow_mut();
    let n = buf.chars().count() as i64;
    if idx < 0 || idx >= n {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IndexOutOfBoundsException",
            Some(format!("index: {idx}, length: {n}")),
        )));
    }
    let byte = sb_char_byte(&buf, idx).unwrap();
    let ch = buf[byte..].chars().next().unwrap();
    buf.replace_range(byte..byte + ch.len_utf8(), "");
    drop(buf);
    Ok(Value::StringBuilder(sb))
}

fn string_builder_delete_range(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.deleteRange")?;
    let start = match ctx.args.get(1).and_then(Value::as_i64) {
        Some(n) => n,
        _ => return Err(RuntimeError::Type("deleteRange start must be Int".into())),
    };
    let end = match ctx.args.get(2).and_then(Value::as_i64) {
        Some(n) => n,
        _ => return Err(RuntimeError::Type("deleteRange end must be Int".into())),
    };
    let mut buf = sb.borrow_mut();
    let n = buf.chars().count() as i64;
    if start < 0 || end > n || start > end {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IndexOutOfBoundsException",
            Some(format!("startIndex: {start}, endIndex: {end}, length: {n}")),
        )));
    }
    let sb_byte = sb_char_byte(&buf, start).unwrap();
    let eb_byte = sb_char_byte(&buf, end).unwrap();
    buf.replace_range(sb_byte..eb_byte, "");
    drop(buf);
    Ok(Value::StringBuilder(sb))
}

fn string_builder_set_length(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.setLength")?;
    let new_len = match ctx.args.get(1).and_then(Value::as_i64) {
        Some(n) => n,
        _ => return Err(RuntimeError::Type("setLength requires Int".into())),
    };
    if new_len < 0 {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IndexOutOfBoundsException",
            Some(format!("newLength: {new_len}")),
        )));
    }
    let mut buf = sb.borrow_mut();
    let cur = buf.chars().count() as i64;
    if new_len <= cur {
        let byte = sb_char_byte(&buf, new_len).unwrap();
        buf.truncate(byte);
    } else {
        for _ in cur..new_len {
            buf.push('\u{0}');
        }
    }
    drop(buf);
    Ok(Value::Unit)
}

fn string_builder_reverse(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.reverse")?;
    let rev: String = sb.borrow().chars().rev().collect();
    *sb.borrow_mut() = rev;
    Ok(Value::StringBuilder(sb))
}

fn string_builder_substring(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.substring")?;
    let start = match ctx.args.get(1).and_then(Value::as_i64) {
        Some(n) => n,
        _ => return Err(RuntimeError::Type("substring start must be Int".into())),
    };
    let buf = sb.borrow();
    let n = buf.chars().count() as i64;
    let end = match ctx.args.get(2) {
        None => n,
        Some(v) if v.is_integral() => v.as_i64().unwrap(),
        _ => return Err(RuntimeError::Type("substring end must be Int".into())),
    };
    if start < 0 || end > n || start > end {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IndexOutOfBoundsException",
            Some(format!("startIndex: {start}, endIndex: {end}, length: {n}")),
        )));
    }
    let sb_byte = sb_char_byte(&buf, start).unwrap();
    let eb_byte = sb_char_byte(&buf, end).unwrap();
    Ok(Value::String(Rc::new(buf[sb_byte..eb_byte].to_string())))
}

// ============================================================
// String.format / kotlin.text.format
// ============================================================

fn string_format_static(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let fmt = match ctx.args.first() {
        Some(Value::String(s)) => (**s).clone(),
        _ => return Err(RuntimeError::Type("format requires a format String".into())),
    };
    let args: Vec<Value> = ctx.args[1..].to_vec();
    Ok(Value::String(Rc::new(format_kotlin(&fmt, &args)?)))
}

fn string_format_member(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    // Receiver-style `"%d".format(x)` — receiver is args[0], format args follow.
    string_format_static(ctx)
}

/// Render a format string in the printf subset Kotlin commonly uses:
/// `%[flags][width][.precision]conversion` for d, x, X, o, s, c, b, f, e, E, g, G, %, n.
fn format_kotlin(fmt: &str, args: &[Value]) -> Result<String, RuntimeError> {
    let mut out = String::with_capacity(fmt.len());
    let bytes: Vec<char> = fmt.chars().collect();
    let mut i = 0;
    let mut arg_idx = 0usize;
    while i < bytes.len() {
        let c = bytes[i];
        if c != '%' {
            out.push(c);
            i += 1;
            continue;
        }
        i += 1;
        if i >= bytes.len() {
            return Err(RuntimeError::Thrown(make_exception(
                "java.util.UnknownFormatConversionException",
                Some("trailing %".into()),
            )));
        }
        // Optional argument index `n$`.
        let start_i = i;
        let mut idx_override: Option<usize> = None;
        let mut j = i;
        while j < bytes.len() && bytes[j].is_ascii_digit() {
            j += 1;
        }
        if j > i && j < bytes.len() && bytes[j] == '$' {
            let n: usize = bytes[i..j].iter().collect::<String>().parse().unwrap_or(0);
            if n > 0 {
                idx_override = Some(n - 1);
            }
            i = j + 1;
        } else {
            i = start_i;
        }
        // Flags.
        let mut flag_left = false;
        let mut flag_zero = false;
        let mut flag_plus = false;
        let mut flag_space = false;
        let mut flag_hash = false;
        let mut flag_comma = false;
        while i < bytes.len() {
            match bytes[i] {
                '-' => flag_left = true,
                '0' => flag_zero = true,
                '+' => flag_plus = true,
                ' ' => flag_space = true,
                '#' => flag_hash = true,
                ',' => flag_comma = true,
                _ => break,
            }
            i += 1;
        }
        // Width.
        let mut width: Option<usize> = None;
        let wstart = i;
        while i < bytes.len() && bytes[i].is_ascii_digit() {
            i += 1;
        }
        if i > wstart {
            width = Some(bytes[wstart..i].iter().collect::<String>().parse().unwrap_or(0));
        }
        // Precision.
        let mut precision: Option<usize> = None;
        if i < bytes.len() && bytes[i] == '.' {
            i += 1;
            let pstart = i;
            while i < bytes.len() && bytes[i].is_ascii_digit() {
                i += 1;
            }
            if i > pstart {
                precision =
                    Some(bytes[pstart..i].iter().collect::<String>().parse().unwrap_or(0));
            }
        }
        if i >= bytes.len() {
            return Err(RuntimeError::Thrown(make_exception(
                "java.util.UnknownFormatConversionException",
                Some("incomplete format specifier".into()),
            )));
        }
        let conv = bytes[i];
        i += 1;
        if conv == '%' {
            out.push('%');
            continue;
        }
        if conv == 'n' {
            out.push('\n');
            continue;
        }
        let consumed_idx = idx_override.unwrap_or(arg_idx);
        if idx_override.is_none() {
            arg_idx += 1;
        }
        let arg = args.get(consumed_idx).cloned().unwrap_or(Value::Null);
        let body = format_conv(
            conv, &arg, flag_plus, flag_space, flag_hash, flag_zero, flag_comma, precision,
        )?;
        let padded = pad_spec(&body, width, flag_left, flag_zero && !is_string_like(conv));
        out.push_str(&padded);
    }
    Ok(out)
}

fn is_string_like(c: char) -> bool {
    matches!(c, 's' | 'S' | 'c' | 'C' | 'b' | 'B')
}

fn pad_spec(body: &str, width: Option<usize>, left: bool, zero: bool) -> String {
    let Some(w) = width else { return body.to_string() };
    let cur = body.chars().count();
    if cur >= w {
        return body.to_string();
    }
    let pad = w - cur;
    let ch = if zero { '0' } else { ' ' };
    let pad_str: String = std::iter::repeat(ch).take(pad).collect();
    if zero {
        // Zero-pad after any sign / prefix.
        if let Some(rest) = body.strip_prefix('-') {
            return format!("-{}{rest}", pad_str);
        }
        if let Some(rest) = body.strip_prefix('+') {
            return format!("+{}{rest}", pad_str);
        }
    }
    if left {
        format!("{body}{pad_str}")
    } else {
        format!("{pad_str}{body}")
    }
}

#[allow(clippy::too_many_arguments)]
fn format_conv(
    conv: char,
    arg: &Value,
    plus: bool,
    space: bool,
    hash: bool,
    _zero: bool,
    comma: bool,
    precision: Option<usize>,
) -> Result<String, RuntimeError> {
    match conv {
        'd' | 'i' => {
            let n = as_long_for_format(arg)?;
            let mut s = if comma {
                fmt_with_commas(n)
            } else {
                n.unsigned_abs().to_string()
            };
            if n < 0 {
                s = format!("-{s}");
            } else if plus {
                s = format!("+{s}");
            } else if space {
                s = format!(" {s}");
            }
            Ok(s)
        }
        'x' | 'X' => {
            let n = as_long_for_format(arg)?;
            let raw = if conv == 'X' {
                format!("{:X}", n as u64)
            } else {
                format!("{:x}", n as u64)
            };
            let prefixed = if hash {
                if conv == 'X' { format!("0X{raw}") } else { format!("0x{raw}") }
            } else {
                raw
            };
            Ok(prefixed)
        }
        'o' => {
            let n = as_long_for_format(arg)?;
            Ok(format!("{:o}", n as u64))
        }
        'b' | 'B' => {
            // Kotlin: %b is "false" for null, "true" for non-null non-boolean;
            // booleans render literally.
            let s = match arg {
                Value::Null => "false".to_string(),
                Value::Bool(b) => b.to_string(),
                _ => "true".to_string(),
            };
            Ok(if conv == 'B' { s.to_uppercase() } else { s })
        }
        's' | 'S' => {
            let mut s = match arg {
                Value::String(v) => (**v).clone(),
                Value::Null => "null".to_string(),
                other => format!("{other}"),
            };
            if let Some(p) = precision {
                let truncated: String = s.chars().take(p).collect();
                s = truncated;
            }
            Ok(if conv == 'S' { s.to_uppercase() } else { s })
        }
        'c' | 'C' => {
            let s = match arg {
                Value::Char(c) => c.to_string(),
                Value::Int(n) => char::from_u32(*n as u32)
                    .ok_or_else(|| {
                        RuntimeError::Type(format!(
                            "%c: invalid code point {n}"
                        ))
                    })?
                    .to_string(),
                _ => return Err(RuntimeError::Type(
                    "%c requires Char or Int code point".into(),
                )),
            };
            Ok(if conv == 'C' { s.to_uppercase() } else { s })
        }
        'f' => {
            let d = as_double_for_format(arg)?;
            let p = precision.unwrap_or(6);
            let raw = format!("{:.*}", p, d.abs());
            let mut s = if comma { insert_commas_decimal(&raw) } else { raw };
            if d.is_sign_negative() && !d.is_nan() {
                s = format!("-{s}");
            } else if plus {
                s = format!("+{s}");
            } else if space {
                s = format!(" {s}");
            }
            Ok(s)
        }
        'e' | 'E' => {
            let d = as_double_for_format(arg)?;
            let p = precision.unwrap_or(6);
            let raw = format!("{:.*e}", p, d.abs());
            // Rust gives e.g. `1.234e2`; Java wants `1.234e+02`.
            let s = normalize_scientific(&raw, conv == 'E');
            let mut out = s;
            if d.is_sign_negative() {
                out = format!("-{out}");
            } else if plus {
                out = format!("+{out}");
            } else if space {
                out = format!(" {out}");
            }
            Ok(out)
        }
        'g' | 'G' => {
            let d = as_double_for_format(arg)?;
            let p = precision.unwrap_or(6).max(1);
            let exp = if d == 0.0 { 0 } else { d.abs().log10().floor() as i32 };
            let use_scientific = exp < -4 || exp >= p as i32;
            if use_scientific {
                format_conv(if conv == 'G' { 'E' } else { 'e' }, arg, plus, space, hash, false, comma, Some(p - 1))
            } else {
                let prec = (p as i32 - 1 - exp).max(0) as usize;
                format_conv('f', arg, plus, space, hash, false, comma, Some(prec))
            }
        }
        _ => Err(RuntimeError::Thrown(make_exception(
            "java.util.UnknownFormatConversionException",
            Some(format!("conversion: {conv}")),
        ))),
    }
}

fn as_long_for_format(v: &Value) -> Result<i64, RuntimeError> {
    if let Some(n) = v.as_i64() {
        return Ok(n);
    }
    match v {
        Value::Char(c) => Ok(i64::from(u32::from(*c))),
        Value::Bool(b) => Ok(if *b { 1 } else { 0 }),
        _ => Err(RuntimeError::Type(format!(
            "integer format spec requires Int-like, got {v:?}"
        ))),
    }
}

fn as_double_for_format(v: &Value) -> Result<f64, RuntimeError> {
    match v {
        Value::Double(d) => Ok(*d),
        Value::Int(n) => Ok(*n as f64),
        _ => Err(RuntimeError::Type(format!(
            "float format spec requires Number, got {v:?}"
        ))),
    }
}

fn fmt_with_commas(n: i64) -> String {
    let s = n.unsigned_abs().to_string();
    let mut out = String::with_capacity(s.len() + s.len() / 3);
    for (i, ch) in s.chars().enumerate() {
        if i > 0 && (s.len() - i) % 3 == 0 {
            out.push(',');
        }
        out.push(ch);
    }
    out
}

fn insert_commas_decimal(s: &str) -> String {
    let (whole, frac) = match s.split_once('.') {
        Some((w, f)) => (w, Some(f)),
        None => (s, None),
    };
    let mut out = String::new();
    for (i, ch) in whole.chars().enumerate() {
        if i > 0 && (whole.len() - i) % 3 == 0 {
            out.push(',');
        }
        out.push(ch);
    }
    if let Some(f) = frac {
        out.push('.');
        out.push_str(f);
    }
    out
}

fn normalize_scientific(s: &str, upper: bool) -> String {
    let (mantissa, exp) = s.split_once('e').unwrap_or((s, "0"));
    let mut exp_n: i32 = exp.parse().unwrap_or(0);
    let exp_sign = if exp_n < 0 { '-' } else { '+' };
    exp_n = exp_n.abs();
    let e_letter = if upper { 'E' } else { 'e' };
    format!("{mantissa}{e_letter}{exp_sign}{exp_n:02}")
}

// ============================================================
// Char title-case
// ============================================================

fn char_titlecase(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let c = match ctx.args.first() {
        Some(Value::Char(c)) => *c,
        _ => return Err(RuntimeError::Type(
            "Char.titlecase requires a Char receiver".into(),
        )),
    };
    // Most chars: titlecase == uppercase. Three diacritic ligatures (U+01C5,
    // U+01C8, U+01CB, U+01F2) and a handful of compatibility lowercase chars
    // map to a multi-char title form; we approximate via uppercase().
    let s: String = c.to_uppercase().collect();
    Ok(Value::String(Rc::new(s)))
}

fn char_titlecase_char(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let c = match ctx.args.first() {
        Some(Value::Char(c)) => *c,
        _ => return Err(RuntimeError::Type(
            "Char.titlecaseChar requires a Char receiver".into(),
        )),
    };
    // Title-case 1:1 mapping — for chars without a specific title form,
    // this is the uppercase mapping.
    let upper: String = c.to_uppercase().collect();
    let titled = upper.chars().next().unwrap_or(c);
    Ok(Value::Char(titled))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(fn_: StdlibFn, args: &[Value]) -> Result<Value, RuntimeError> {
        let mut out = klio_runtime::CaptureOutput::default();
        fn_(&mut CallCtx { args, out: &mut out })
    }

    #[test]
    fn table_has_no_duplicates() {
        let mut seen = std::collections::HashSet::new();
        for (k, _) in TABLE {
            assert!(seen.insert(*k), "duplicate FQN in TABLE: {k}");
        }
    }

    #[test]
    fn lookup_returns_none_for_unknown() {
        assert!(lookup("kotlin.foo.bar").is_none());
    }

    #[test]
    fn math_abs_int_and_double() {
        assert!(matches!(call(math_abs, &[Value::Int(-5)]), Ok(Value::Int(5))));
        let Ok(Value::Double(d)) = call(math_abs, &[Value::Double(-1.5)]) else { panic!() };
        assert!((d - 1.5).abs() < 1e-12);
    }

    #[test]
    fn math_sin_cos_identities() {
        let Ok(Value::Double(s)) = call(math_sin, &[Value::Double(0.0)]) else { panic!() };
        let Ok(Value::Double(c)) = call(math_cos, &[Value::Double(0.0)]) else { panic!() };
        assert!(s.abs() < 1e-12);
        assert!((c - 1.0).abs() < 1e-12);
    }

    #[test]
    fn math_floor_ceil_round() {
        assert!(matches!(call(math_floor, &[Value::Double(1.7)]), Ok(Value::Double(d)) if (d - 1.0).abs() < 1e-12));
        assert!(matches!(call(math_ceil, &[Value::Double(1.2)]), Ok(Value::Double(d)) if (d - 2.0).abs() < 1e-12));
        assert!(matches!(call(math_round, &[Value::Double(1.5)]), Ok(Value::Double(d)) if (d - 2.0).abs() < 1e-12));
    }

    #[test]
    fn string_length_counts_chars_not_bytes() {
        let s = Value::String(Rc::new("héllo".to_string()));
        assert!(matches!(call(string_length, &[s]), Ok(Value::Int(5))));
    }

    #[test]
    fn string_get_returns_char() {
        let s = Value::String(Rc::new("abc".to_string()));
        assert!(matches!(call(string_get, &[s, Value::Int(1)]), Ok(Value::Char('b'))));
    }

    #[test]
    fn string_get_out_of_bounds_throws() {
        let s = Value::String(Rc::new("abc".to_string()));
        let err = call(string_get, &[s, Value::Int(99)]).unwrap_err();
        assert!(matches!(err, RuntimeError::Thrown(Value::Exception { .. })));
    }

    #[test]
    fn string_substring_two_args() {
        let s = Value::String(Rc::new("abcdef".to_string()));
        let Ok(Value::String(out)) = call(string_substring, &[s, Value::Int(1), Value::Int(4)]) else { panic!() };
        assert_eq!(*out, "bcd");
    }

    #[test]
    fn string_repeat_and_reversed() {
        let s = Value::String(Rc::new("ab".to_string()));
        let Ok(Value::String(r)) = call(string_repeat, &[s.clone(), Value::Int(3)]) else { panic!() };
        assert_eq!(*r, "ababab");
        let Ok(Value::String(rev)) = call(string_reversed, &[s]) else { panic!() };
        assert_eq!(*rev, "ba");
    }

    #[test]
    fn char_is_digit_letter_whitespace() {
        assert!(matches!(call(char_is_digit, &[Value::Char('5')]), Ok(Value::Bool(true))));
        assert!(matches!(call(char_is_letter, &[Value::Char('a')]), Ok(Value::Bool(true))));
        assert!(matches!(call(char_is_whitespace, &[Value::Char(' ')]), Ok(Value::Bool(true))));
    }

    #[test]
    fn char_unicode_category_predicates() {
        // ASCII baseline.
        assert!(matches!(call(char_is_letter, &[Value::Char('A')]), Ok(Value::Bool(true))));
        assert!(matches!(call(char_is_letter, &[Value::Char('z')]), Ok(Value::Bool(true))));
        assert!(matches!(call(char_is_digit, &[Value::Char('0')]), Ok(Value::Bool(true))));
        assert!(matches!(call(char_is_whitespace, &[Value::Char('\t')]), Ok(Value::Bool(true))));
        assert!(matches!(call(char_is_whitespace, &[Value::Char('\n')]), Ok(Value::Bool(true))));

        // Non-ASCII letters.
        assert!(matches!(call(char_is_letter, &[Value::Char('α')]), Ok(Value::Bool(true))));
        assert!(matches!(call(char_is_letter, &[Value::Char('я')]), Ok(Value::Bool(true))));
        assert!(matches!(call(char_is_uppercase, &[Value::Char('Я')]), Ok(Value::Bool(true))));

        // kotlinc-native treats NBSP-family code points as whitespace
        // (matches its built-in whitespace table; this also happens to match
        // Rust's `char::is_whitespace` here, so no divergence).
        assert!(matches!(call(char_is_whitespace, &[Value::Char('\u{00A0}')]), Ok(Value::Bool(true))));
        assert!(matches!(call(char_is_whitespace, &[Value::Char('\u{202F}')]), Ok(Value::Bool(true))));
        assert!(matches!(call(char_is_whitespace, &[Value::Char('\u{2007}')]), Ok(Value::Bool(true))));
        // Divergence: ASCII control 0x1C..=0x1F. Kotlin -> true (in the
        // kotlinc-native whitespace table), Rust -> false.
        assert!(matches!(call(char_is_whitespace, &[Value::Char('\u{001F}')]), Ok(Value::Bool(true))));
        assert!(matches!(call(char_is_whitespace, &[Value::Char('\u{001C}')]), Ok(Value::Bool(true))));

        // Divergence: Arabic-Indic digit five (U+0665). Both true under Nd,
        // but it's a non-ASCII digit guarded by the old `is_ascii_digit` call
        // which returned false. New code matches kotlinc.
        assert!(matches!(call(char_is_digit, &[Value::Char('\u{0665}')]), Ok(Value::Bool(true))));

        // Divergence: Roman numeral V (U+2164). Other_Uppercase contributory
        // property -> Kotlin treats as uppercase; Rust `is_uppercase` -> false.
        assert!(matches!(call(char_is_uppercase, &[Value::Char('\u{2164}')]), Ok(Value::Bool(true))));

        // ZWSP (U+200B): neither Rust nor Kotlin treat as whitespace; sanity.
        assert!(matches!(call(char_is_whitespace, &[Value::Char('\u{200B}')]), Ok(Value::Bool(false))));
    }

    #[test]
    fn int_bitwise_ops() {
        assert!(matches!(call(int_and, &[Value::Int(0b1100), Value::Int(0b1010)]), Ok(Value::Int(0b1000))));
        assert!(matches!(call(int_or,  &[Value::Int(0b1100), Value::Int(0b1010)]), Ok(Value::Int(0b1110))));
        assert!(matches!(call(int_xor, &[Value::Int(0b1100), Value::Int(0b1010)]), Ok(Value::Int(0b0110))));
        assert!(matches!(call(int_shl, &[Value::Int(1), Value::Int(3)]), Ok(Value::Int(8))));
        assert!(matches!(call(int_shr, &[Value::Int(8), Value::Int(2)]), Ok(Value::Int(2))));
    }

    #[test]
    fn double_predicates() {
        assert!(matches!(call(double_is_nan, &[Value::Double(f64::NAN)]), Ok(Value::Bool(true))));
        assert!(matches!(call(double_is_infinite, &[Value::Double(f64::INFINITY)]), Ok(Value::Bool(true))));
        assert!(matches!(call(double_is_finite, &[Value::Double(1.0)]), Ok(Value::Bool(true))));
    }

    #[test]
    fn string_substring_before_after() {
        let s = Value::String(Rc::new("a.b.c".to_string()));
        let Ok(Value::String(before)) = call(string_substring_before, &[s.clone(), Value::String(Rc::new(".".into()))]) else { panic!() };
        assert_eq!(*before, "a");
        let Ok(Value::String(after)) = call(string_substring_after_last, &[s, Value::String(Rc::new(".".into()))]) else { panic!() };
        assert_eq!(*after, "c");
    }

    #[test]
    fn list_first_or_null_handles_empty() {
        let empty = make_list(Vec::new(), false);
        assert!(matches!(call(coll_list_first_or_null, &[empty]), Ok(Value::Null)));
        let one = make_list(vec![Value::Int(7)], false);
        assert!(matches!(call(coll_list_first_or_null, &[one]), Ok(Value::Int(7))));
    }

    #[test]
    fn list_single_throws_when_multi() {
        let multi = make_list(vec![Value::Int(1), Value::Int(2)], false);
        let err = call(coll_list_single, &[multi]).unwrap_err();
        assert!(matches!(err, RuntimeError::Thrown(_)));
    }

    #[test]
    fn map_get_or_default_falls_back() {
        let m = make_map(vec![(Value::String(Rc::new("a".into())), Value::Int(1))], false);
        let Ok(v) = call(coll_map_get_or_default, &[m.clone(), Value::String(Rc::new("a".into())), Value::Int(99)]) else { panic!() };
        assert!(matches!(v, Value::Int(1)));
        let Ok(v) = call(coll_map_get_or_default, &[m, Value::String(Rc::new("z".into())), Value::Int(99)]) else { panic!() };
        assert!(matches!(v, Value::Int(99)));
    }

    #[test]
    fn int_coerce_in_range_and_pair() {
        assert!(matches!(call(int_coerce_in, &[Value::Int(5), Value::Int(0), Value::Int(3)]), Ok(Value::Int(3))));
        assert!(matches!(call(int_coerce_in, &[Value::Int(-1), Value::Int(0), Value::Int(3)]), Ok(Value::Int(0))));
        assert!(matches!(call(int_coerce_in, &[Value::Int(2), Value::Range { start: 0, end: 5, step: 1, kind: klio_runtime::RangeKind::Int }]), Ok(Value::Int(2))));
    }

    #[test]
    fn string_lines_splits_on_all_line_separators() {
        let s = Value::String(Rc::new("a\nb\r\nc\rd".to_string()));
        let Ok(Value::List { items, .. }) = call(string_lines, &[s]) else { panic!() };
        assert_eq!(items.borrow().len(), 4);
    }

    #[test]
    fn regex_find_returns_match() {
        let re = call(regex_ctor, &[Value::String(Rc::new(r"\d+".into()))]).unwrap();
        let v = call(regex_find, &[re, Value::String(Rc::new("abc 123 def".into()))]).unwrap();
        let Value::Match(m) = v else { panic!() };
        assert_eq!(*m.groups[0].as_ref().unwrap().value, "123");
    }

    #[test]
    fn string_builder_append_and_length() {
        let sb = call(string_builder_ctor, &[]).unwrap();
        call(string_builder_append, &[sb.clone(), Value::String(Rc::new("ab".into()))]).unwrap();
        call(string_builder_append, &[sb.clone(), Value::Int(7)]).unwrap();
        let Value::Int(n) = call(string_builder_length, &[sb.clone()]).unwrap() else { panic!() };
        assert_eq!(n, 3);
        let Value::String(s) = call(string_builder_to_string, &[sb]).unwrap() else { panic!() };
        assert_eq!(&*s, "ab7");
    }

    #[test]
    fn format_basic_specifiers() {
        let fmt = Value::String(Rc::new("%d-%s".into()));
        let Value::String(s) = call(
            string_format_static,
            &[fmt, Value::Int(7), Value::String(Rc::new("x".into()))],
        ).unwrap() else { panic!() };
        assert_eq!(&*s, "7-x");
    }

    #[test]
    fn excn_constructors_carry_message() {
        let Ok(Value::Exception { fqn, message, .. }) = call(
            excn_illegal_argument,
            &[Value::String(Rc::new("bad".into()))],
        ) else { panic!() };
        assert_eq!(*fqn, "kotlin.IllegalArgumentException");
        assert_eq!(message.as_deref().map(|s| s.as_str()), Some("bad"));
    }
}
