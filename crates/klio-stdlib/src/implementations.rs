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
use std::sync::Arc;

use klio_runtime::{CallCtx, ObjRef, RuntimeError, StdlibFn, Value};

const TABLE: &[(&str, StdlibFn)] = &[
    // ----- non-scope lambda-driven utilities still on the Rust path -----
    // `error` and `TODO` rely on `Nothing`-return throw flow; the
    // collection/text builders bridge to Rust-native Value containers;
    // `lazy` / `lazyOf` need the Lazy<T> interface and field-stored
    // callables — both moves planned in the intrinsics-to-Kotlin
    // migration's later tiers.
    ("kotlin.error", contract_error),
    ("kotlin.TODO", contract_todo),
    ("kotlin.collections.buildList", builders_build_list),
    ("kotlin.collections.buildSet", builders_build_set),
    ("kotlin.collections.buildMap", builders_build_map),
    ("kotlin.text.buildString", builders_build_string),

    // ----- threads / monitors (serialized-interpreter semantics) -----
    ("kotlin.synchronized", concurrent_synchronized),
    ("kotlin.concurrent.thread", concurrent_thread),
    ("kotlin.concurrent.Thread.sleep", concurrent_thread_sleep),
    ("kotlin.concurrent.Thread.currentThread", concurrent_thread_current),

    // ----- kotlin.time platform clock bindings -----
    // Backing for the klio `actual`s of kotlin.time's `internal expect`
    // wall/monotonic clock (kotlin-time/Actuals.kt). The rest of
    // kotlin.time is consumed verbatim from upstream commonMain.
    ("kotlin.time.__klio_time_systemMillis", time_system_millis),
    ("kotlin.time.__klio_time_monotonicNanos", time_monotonic_nanos),

    // ----- io -----
    ("kotlin.io.print", io_print),
    ("kotlin.io.println", io_println),
    ("kotlin.io.readLine", io_read_line),

    // ----- math (functions) -----
    ("kotlin.math.abs", math_abs),
    ("kotlin.math.absoluteValue", math_abs),
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
    ("kotlin.math.cbrt", math_cbrt),
    ("kotlin.math.sign", math_sign),
    ("kotlin.Double.roundToInt", num_round_to_int),
    ("kotlin.Float.roundToInt", num_round_to_int),
    ("kotlin.Double.roundToLong", num_round_to_long),
    ("kotlin.Float.roundToLong", num_round_to_long),
    ("kotlin.Double.mod", num_float_mod),
    ("kotlin.Float.mod", num_float_mod),
    ("kotlin.Double.rem", num_float_rem),
    ("kotlin.Float.rem", num_float_rem),
    ("kotlin.Int.takeHighestOneBit", num_take_highest_one_bit),
    ("kotlin.Long.takeHighestOneBit", num_take_highest_one_bit),
    ("kotlin.Int.takeLowestOneBit", num_take_lowest_one_bit),
    ("kotlin.Long.takeLowestOneBit", num_take_lowest_one_bit),
    ("kotlin.Int.rotateLeft", num_rotate_left),
    ("kotlin.Long.rotateLeft", num_rotate_left),
    ("kotlin.Int.rotateRight", num_rotate_right),
    ("kotlin.Long.rotateRight", num_rotate_right),
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
    ("kotlin.String.filter", string_filter),
    ("kotlin.String.count", string_count),
    ("kotlin.String.map", string_map),
    ("kotlin.String.any", string_any),
    ("kotlin.String.all", string_all),
    ("kotlin.String.none", string_none),
    ("kotlin.String.endsWith", string_ends_with),
    ("kotlin.String.get", string_get),
    ("kotlin.String.indexOf", string_index_of),
    ("kotlin.String.toString", string_to_string),
    ("kotlin.String.lastIndexOf", string_last_index_of),
    ("kotlin.String.length", string_length),
    ("kotlin.String.lowercase", string_lowercase),
    ("kotlin.String.plus", string_plus),
    ("kotlin.String.repeat", string_repeat),
    ("kotlin.String.replace", string_replace),
    ("kotlin.String.reversed", string_reversed),
    ("kotlin.String.startsWith", string_starts_with),
    ("kotlin.String.regionMatches", string_region_matches),
    ("kotlin.CharSequence.regionMatches", string_region_matches),
    ("kotlin.String.skipWhile", string_skip_while),
    ("kotlin.text.skipWhile", string_skip_while),
    ("kotlin.CharSequence.skipWhile", string_skip_while),
    ("kotlin.String.substring", string_substring),
    // `subSequence(start, end)` shares `substring`'s semantics (klio
    // represents a CharSequence as a String). A host impl is required:
    // the abstract `CharSequence.subSequence` member otherwise falls to
    // upstream's deprecated `inline fun String.subSequence(s,e) =
    // subSequence(s,e)`, which re-binds itself in klio and recurses
    // forever (stack overflow; padStart/padEnd then never terminate).
    ("kotlin.String.subSequence", string_substring),
    ("kotlin.CharSequence.subSequence", string_substring),
    ("kotlin.String.padStart", string_pad_start),
    ("kotlin.CharSequence.padStart", string_pad_start),
    ("kotlin.String.padEnd", string_pad_end),
    ("kotlin.CharSequence.padEnd", string_pad_end),
    ("kotlin.String.chunked", string_chunked),
    ("kotlin.String.split", string_split),
    ("kotlin.String.splitToSequence", string_split_to_sequence),
    ("kotlin.CharSequence.splitToSequence", string_split_to_sequence),
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
    ("kotlin.Char.toInt", char_code),
    ("kotlin.internal.getProgressionLastElement", internal_get_progression_last_element),
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
    ("kotlin.NoWhenBranchMatchedException", excn_no_when),
    ("kotlin.NumberFormatException", excn_number_format),
    ("kotlin.ConcurrentModificationException", excn_concurrent_mod),
    ("kotlin.AssertionError", excn_assertion_error),

    // ----- Throwable members -----
    ("kotlin.Throwable.message", throwable_message),
    ("kotlin.Throwable.cause", throwable_cause),
    ("kotlin.Throwable.toString", throwable_to_string),
    ("kotlin.Throwable.addSuppressed", throwable_add_suppressed),
    ("kotlin.Throwable.getSuppressed", throwable_suppressed),
    ("kotlin.Throwable.suppressedExceptions", throwable_suppressed),

    // ----- Collection constructors -----
    ("kotlin.Pair", coll_pair_ctor),
    ("kotlin.collections.emptyList", coll_empty_list),
    ("kotlin.collections.emptyMap", coll_empty_map),
    ("kotlin.collections.emptySet", coll_empty_set),
    ("kotlin.collections.listOf", coll_list_of),
    ("kotlin.collections.listOfNotNull", coll_list_of_not_null),
    ("kotlin.arrayOf", coll_array_of),
    ("kotlin.arrayOfNulls", coll_array_of_nulls),
    ("kotlin.emptyArray", coll_empty_array),
    ("kotlin.intArrayOf", coll_int_array_of),
    ("kotlin.longArrayOf", coll_long_array_of),
    ("kotlin.shortArrayOf", coll_short_array_of),
    ("kotlin.byteArrayOf", coll_byte_array_of),
    ("kotlin.doubleArrayOf", coll_double_array_of),
    ("kotlin.floatArrayOf", coll_float_array_of),
    ("kotlin.booleanArrayOf", coll_bool_array_of),
    ("kotlin.charArrayOf", coll_char_array_of),
    ("kotlin.uintArrayOf", coll_uint_array_of),
    ("kotlin.ulongArrayOf", coll_ulong_array_of),
    ("kotlin.ushortArrayOf", coll_ushort_array_of),
    ("kotlin.ubyteArrayOf", coll_ubyte_array_of),
    ("kotlin.collections.mapOf", coll_map_of),
    ("kotlin.collections.mutableListOf", coll_mutable_list_of),
    ("kotlin.collections.mutableMapOf", coll_mutable_map_of),
    ("kotlin.collections.mutableSetOf", coll_mutable_set_of),
    ("kotlin.collections.arrayListOf", coll_mutable_list_of),
    ("kotlin.collections.linkedMapOf", coll_mutable_map_of),
    ("kotlin.collections.hashMapOf", coll_mutable_map_of),
    ("kotlin.collections.linkedStringMapOf", coll_mutable_map_of),
    ("kotlin.collections.hashSetOf", coll_mutable_set_of),
    ("kotlin.collections.linkedSetOf", coll_mutable_set_of),
    ("kotlin.collections.sortedSetOf", coll_sorted_set_of),
    ("kotlin.collections.sortedMapOf", coll_sorted_map_of),
    ("kotlin.collections.setOfNotNull", coll_set_of_not_null),
    ("kotlin.collections.Set.toTypedArray", coll_to_typed_array),
    ("kotlin.collections.Collection.toTypedArray", coll_to_typed_array),
    ("kotlin.collections.Iterable.toTypedArray", coll_to_typed_array),
    ("kotlin.collections.setOf", coll_set_of),
    ("kotlin.to", coll_to_infix),
    ("kotlin.collections.ArrayList", coll_array_list_ctor),
    ("kotlin.collections.ArrayDeque", coll_array_list_ctor),
    ("kotlin.collections.HashMap", coll_hash_map_ctor),
    ("kotlin.collections.HashSet", coll_hash_set_ctor),
    ("kotlin.collections.LinkedHashMap", coll_hash_map_ctor),
    ("kotlin.collections.LinkedHashSet", coll_hash_set_ctor),

    // ----- List / Set members -----
    ("kotlin.collections.List.contains", coll_list_contains),
    // first / firstOrNull / last / lastOrNull / single / singleOrNull /
    // find / fold / reduce / filterNot / filterIndexed / mapIndexed /
    // forEachIndexed / takeWhile / dropWhile / flatMap / partition
    // are shipped from kotlin-collections/Iterable.kt (Iterable<T>
    // extensions cover all list/set receivers via the runtime
    // extension-fn fallback's receiver-type scoring).
    ("kotlin.collections.List.get", coll_list_get),
    ("kotlin.collections.List.indexOf", coll_list_index_of),
    ("kotlin.collections.List.indexOfFirst", coll_iter_index_of_first),
    ("kotlin.collections.List.foldRight", coll_list_fold_right),
    ("kotlin.collections.Array.foldRight", coll_list_fold_right),
    ("kotlin.Array.foldRight", coll_list_fold_right),
    ("kotlin.collections.List.reduceRight", coll_list_reduce_right),
    ("kotlin.collections.Array.reduceRight", coll_list_reduce_right),
    ("kotlin.Array.reduceRight", coll_list_reduce_right),
    ("kotlin.collections.List.reduceRightOrNull", coll_list_reduce_right_or_null),
    ("kotlin.Array.reduceRightOrNull", coll_list_reduce_right_or_null),
    ("kotlin.collections.List.last", coll_list_last),
    ("kotlin.collections.Set.last", coll_list_last),
    ("kotlin.collections.Iterable.last", coll_list_last),
    ("kotlin.Array.last", coll_list_last),
    ("kotlin.collections.List.lastOrNull", coll_list_last_or_null),
    ("kotlin.collections.Set.lastOrNull", coll_list_last_or_null),
    ("kotlin.collections.Iterable.lastOrNull", coll_list_last_or_null),
    ("kotlin.Array.lastOrNull", coll_list_last_or_null),
    ("kotlin.collections.List.findLast", coll_list_last_or_null),
    ("kotlin.collections.Set.findLast", coll_list_last_or_null),
    ("kotlin.collections.Iterable.findLast", coll_list_last_or_null),
    ("kotlin.Array.findLast", coll_list_last_or_null),
    ("kotlin.collections.List.indexOfLast", coll_iter_index_of_last),
    ("kotlin.collections.MutableList.indexOfFirst", coll_iter_index_of_first),
    ("kotlin.collections.MutableList.indexOfLast", coll_iter_index_of_last),
    ("kotlin.collections.Iterable.indexOfFirst", coll_iter_index_of_first),
    ("kotlin.collections.Iterable.indexOfLast", coll_iter_index_of_last),
    ("kotlin.Array.isEmpty", array_is_empty),
    ("kotlin.Array.isNotEmpty", array_is_not_empty),
    ("kotlin.collections.Array.isEmpty", array_is_empty),
    ("kotlin.collections.Array.isNotEmpty", array_is_not_empty),
    ("kotlin.IntArray.isEmpty", array_is_empty),
    ("kotlin.IntArray.isNotEmpty", array_is_not_empty),
    ("kotlin.IntArray.sum", array_sum_int),
    ("kotlin.Array.withIndex", coll_array_with_index),
    ("kotlin.Array.sliceArray", array_slice_impl),
    ("kotlin.IntArray.sliceArray", array_slice_impl),
    ("kotlin.LongArray.sliceArray", array_slice_impl),
    ("kotlin.DoubleArray.sliceArray", array_slice_impl),
    ("kotlin.FloatArray.sliceArray", array_slice_impl),
    ("kotlin.ShortArray.sliceArray", array_slice_impl),
    ("kotlin.ByteArray.sliceArray", array_slice_impl),
    ("kotlin.CharArray.sliceArray", array_slice_impl),
    ("kotlin.BooleanArray.sliceArray", array_slice_impl),
    ("kotlin.IntArray.withIndex", coll_array_with_index),
    ("kotlin.LongArray.withIndex", coll_array_with_index),
    ("kotlin.DoubleArray.withIndex", coll_array_with_index),
    ("kotlin.FloatArray.withIndex", coll_array_with_index),
    ("kotlin.ShortArray.withIndex", coll_array_with_index),
    ("kotlin.ByteArray.withIndex", coll_array_with_index),
    ("kotlin.CharArray.withIndex", coll_array_with_index),
    ("kotlin.BooleanArray.withIndex", coll_array_with_index),
    ("kotlin.LongArray.sum", array_sum_int),
    ("kotlin.DoubleArray.sum", array_sum_int),
    ("kotlin.FloatArray.sum", array_sum_int),
    ("kotlin.ShortArray.sum", array_sum_int),
    ("kotlin.ByteArray.sum", array_sum_int),
    ("kotlin.IntArray.average", array_average_impl),
    ("kotlin.LongArray.average", array_average_impl),
    ("kotlin.DoubleArray.average", array_average_impl),
    ("kotlin.FloatArray.average", array_average_impl),
    ("kotlin.ShortArray.average", array_average_impl),
    ("kotlin.ByteArray.average", array_average_impl),
    ("kotlin.IntArray.max", array_max),
    ("kotlin.IntArray.min", array_min),
    ("kotlin.LongArray.max", array_max),
    ("kotlin.LongArray.min", array_min),
    ("kotlin.DoubleArray.max", array_max),
    ("kotlin.DoubleArray.min", array_min),
    ("kotlin.Array.joinToString", coll_array_join_to_string),
    ("kotlin.IntArray.joinToString", coll_array_join_to_string),
    ("kotlin.LongArray.joinToString", coll_array_join_to_string),
    ("kotlin.DoubleArray.joinToString", coll_array_join_to_string),
    ("kotlin.FloatArray.joinToString", coll_array_join_to_string),
    ("kotlin.ShortArray.joinToString", coll_array_join_to_string),
    ("kotlin.ByteArray.joinToString", coll_array_join_to_string),
    ("kotlin.CharArray.joinToString", coll_array_join_to_string),
    ("kotlin.BooleanArray.joinToString", coll_array_join_to_string),
    ("kotlin.LongArray.isEmpty", array_is_empty),
    ("kotlin.LongArray.isNotEmpty", array_is_not_empty),
    ("kotlin.ByteArray.isEmpty", array_is_empty),
    ("kotlin.ByteArray.isNotEmpty", array_is_not_empty),
    ("kotlin.CharArray.isEmpty", array_is_empty),
    ("kotlin.CharArray.isNotEmpty", array_is_not_empty),
    ("kotlin.collections.List.isEmpty", coll_list_is_empty),
    ("kotlin.collections.List.isNotEmpty", coll_list_is_not_empty),
    ("kotlin.collections.List.joinToString", coll_list_join_to_string),
    ("kotlin.collections.Set.joinToString", coll_list_join_to_string),
    ("kotlin.collections.MutableSet.joinToString", coll_list_join_to_string),
    ("kotlin.collections.Iterable.joinToString", coll_list_join_to_string),
    ("kotlin.collections.Collection.joinToString", coll_list_join_to_string),
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
    ("kotlin.collections.Iterable.toMap", coll_list_to_map),
    ("kotlin.collections.Set.toMap", coll_list_to_map),
    ("kotlin.Array.toMap", coll_list_to_map),
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
    ("kotlin.collections.List.takeLast", coll_list_take_last),
    ("kotlin.collections.List.windowed", coll_list_windowed),
    ("kotlin.collections.List.zip", coll_list_zip),
    ("kotlin.collections.List.toString", coll_list_to_string),

    ("kotlin.collections.MutableList.add", coll_mut_list_add),
    ("kotlin.collections.MutableList.clear", coll_mut_list_clear),
    ("kotlin.collections.MutableList.contains", coll_list_contains),
    ("kotlin.collections.MutableList.get", coll_list_get),
    ("kotlin.collections.MutableList.indexOf", coll_list_index_of),
    ("kotlin.collections.MutableList.isEmpty", coll_list_is_empty),
    ("kotlin.collections.MutableList.isNotEmpty", coll_list_is_not_empty),
    ("kotlin.collections.MutableList.joinToString", coll_list_join_to_string),
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
    ("kotlin.collections.MutableList.dropLast", coll_list_drop_last),
    ("kotlin.collections.MutableList.lastIndexOf", coll_list_last_index_of),
    ("kotlin.collections.MutableList.minus", coll_list_minus),
    ("kotlin.collections.MutableList.plus", coll_list_plus),
    ("kotlin.collections.MutableList.removeAt", coll_mut_list_remove_at),
    ("kotlin.collections.MutableList.addFirst", coll_mut_list_add_first),
    ("kotlin.collections.MutableList.addLast", coll_mut_list_add),
    ("kotlin.collections.MutableList.removeFirst", coll_mut_list_remove_first),
    ("kotlin.collections.MutableList.removeLast", coll_mut_list_remove_last),
    ("kotlin.collections.MutableList.reversed", coll_list_reversed),
    ("kotlin.collections.MutableList.size", coll_list_size),
    ("kotlin.collections.MutableList.slice", coll_list_slice),
    ("kotlin.collections.MutableList.sorted", coll_list_sorted),
    ("kotlin.collections.MutableList.sortedDescending", coll_list_sorted_descending),
    ("kotlin.collections.MutableList.subList", coll_list_sublist),
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
    ("kotlin.collections.Map.plus", coll_map_plus),
    ("kotlin.collections.Map.minus", coll_map_minus),
    ("kotlin.collections.Map.toMutableMap", coll_map_to_mutable_map),
    ("kotlin.collections.Map.toMap", coll_map_to_map),
    ("kotlin.collections.Map.toSortedMap", coll_map_to_sorted_map),
    ("kotlin.collections.MutableMap.toSortedMap", coll_map_to_sorted_map),
    ("kotlin.collections.MutableMap.toMutableMap", coll_map_to_mutable_map),
    ("kotlin.collections.MutableMap.toMap", coll_map_to_map),
    ("kotlin.collections.MutableMap.plus", coll_map_plus),
    ("kotlin.collections.MutableMap.minus", coll_map_minus),
    ("kotlin.collections.Set.subtract", coll_set_subtract),
    ("kotlin.collections.Set.toString", coll_set_to_string),
    ("kotlin.collections.Set.union", coll_set_union),
    ("kotlin.collections.Set.sorted", coll_set_sorted),
    ("kotlin.collections.Set.sortedDescending", coll_set_sorted_descending),
    ("kotlin.collections.MutableSet.add", coll_mut_set_add),
    ("kotlin.collections.MutableSet.clear", coll_mut_set_clear),
    ("kotlin.collections.MutableSet.contains", coll_set_contains),
    ("kotlin.collections.MutableSet.isEmpty", coll_set_is_empty),
    ("kotlin.collections.MutableSet.isNotEmpty", coll_set_is_not_empty),
    ("kotlin.collections.MutableSet.remove", coll_mut_set_remove),
    ("kotlin.collections.MutableSet.removeAll", coll_mut_set_remove_all),
    ("kotlin.collections.MutableSet.retainAll", coll_mut_set_retain_all),
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
    ("kotlin.sequences.generateSequence", seq_generate_sequence),
    ("kotlin.sequences.sequence", seq_builder),
    ("kotlin.sequences.iterator", seq_iterator_builder),
    ("kotlin.sequences.SequenceScope.yield", seq_scope_yield),
    ("kotlin.sequences.SequenceScope.yieldAll", seq_scope_yield_all),
    ("kotlin.sequences.Sequence.toList", seq_to_list),
    ("kotlin.sequences.Sequence.toMutableList", seq_to_mutable_list),
    ("kotlin.sequences.Sequence.toSet", seq_to_set),
    ("kotlin.sequences.Sequence.count", seq_count_no_pred),
    ("kotlin.sequences.Sequence.first", seq_first),
    ("kotlin.sequences.Sequence.firstOrNull", seq_first_or_null),
    ("kotlin.sequences.Sequence.find", seq_first_or_null),
    ("kotlin.sequences.Sequence.any", seq_any),
    ("kotlin.sequences.Sequence.none", seq_none),
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
    ("kotlin.Char.isHighSurrogate", char_false),
    ("kotlin.Char.isLowSurrogate", char_false),
    ("kotlin.Char.isSurrogate", char_false),
    ("kotlin.Char.digitToIntOrNull", char_digit_to_int_or_null),

    // ----- Additional Int -----
    ("kotlin.Int.coerceIn", int_coerce_in),
    ("kotlin.Int.coerceAtLeast", int_coerce_at_least),
    ("kotlin.Int.coerceAtMost", int_coerce_at_most),
    ("kotlin.Long.coerceIn", num_coerce_in),
    ("kotlin.Long.coerceAtLeast", num_coerce_at_least),
    ("kotlin.Long.coerceAtMost", num_coerce_at_most),
    ("kotlin.Double.coerceIn", num_coerce_in),
    ("kotlin.Double.coerceAtLeast", num_coerce_at_least),
    ("kotlin.Double.coerceAtMost", num_coerce_at_most),
    ("kotlin.Float.coerceIn", num_coerce_in),
    ("kotlin.Float.coerceAtLeast", num_coerce_at_least),
    ("kotlin.Float.coerceAtMost", num_coerce_at_most),
    ("kotlin.Int.countLeadingZeroBits", num_count_leading_zero_bits),
    ("kotlin.Long.countLeadingZeroBits", num_count_leading_zero_bits),
    ("kotlin.Short.countLeadingZeroBits", num_count_leading_zero_bits),
    ("kotlin.Byte.countLeadingZeroBits", num_count_leading_zero_bits),
    ("kotlin.Int.countTrailingZeroBits", num_count_trailing_zero_bits),
    ("kotlin.Long.countTrailingZeroBits", num_count_trailing_zero_bits),
    ("kotlin.Int.countOneBits", num_count_one_bits),
    ("kotlin.Long.countOneBits", num_count_one_bits),
    ("kotlin.Int.floorDiv", num_floor_div),
    ("kotlin.Long.floorDiv", num_floor_div),
    ("kotlin.Short.floorDiv", num_floor_div),
    ("kotlin.Byte.floorDiv", num_floor_div),
    ("kotlin.Int.mod", num_mod),
    ("kotlin.Long.mod", num_mod),
    ("kotlin.Short.mod", num_mod),
    ("kotlin.Byte.mod", num_mod),
    ("kotlin.Int.toChar", int_to_char),

    // ----- Additional List ops -----
    ("kotlin.collections.List.flatten", coll_list_flatten),
    ("kotlin.collections.List.unzip", coll_list_unzip),
    ("kotlin.collections.List.containsAll", coll_list_contains_all),
    ("kotlin.collections.List.toList", coll_list_to_list),
    ("kotlin.collections.List.toMutableList", coll_list_to_mutable_list),
    ("kotlin.collections.List.toSet", coll_list_to_set),
    ("kotlin.collections.List.toMutableSet", coll_list_to_mutable_set),
    ("kotlin.collections.List.withIndex", coll_list_with_index),
    ("kotlin.collections.MutableList.flatten", coll_list_flatten),
    ("kotlin.collections.MutableList.unzip", coll_list_unzip),
    ("kotlin.collections.MutableList.containsAll", coll_list_contains_all),
    ("kotlin.collections.MutableList.toList", coll_list_to_list),
    ("kotlin.collections.MutableList.toMutableList", coll_list_to_mutable_list),
    ("kotlin.collections.MutableList.toSet", coll_list_to_set),
    ("kotlin.collections.MutableList.toMutableSet", coll_list_to_mutable_set),
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
    ("kotlin.collections.MutableMap.merge", map_merge),
    ("kotlin.collections.MutableMap.putIfAbsent", map_put_if_absent),
    ("kotlin.collections.MutableMap.replace", map_replace),
    ("kotlin.collections.MutableMap.computeIfAbsent", map_compute_if_absent),
    ("kotlin.collections.MutableMap.computeIfPresent", map_compute_if_present),
    ("kotlin.collections.MutableMap.compute", map_compute),

    // ----- Iterable higher-order (lambda-driven) -----
    // forEach / map / filter / filterNotNull / any / all / none on
    // List / Set / Iterable migrated to common-Kotlin shims in
    // crates/klio-stdlib/kotlin-collections/Iterable.kt. Map.forEach
    // (entry-typed) and Array.filterNotNull stay on the intrinsic
    // path until the Map.Entry / kotlin.Array surface is shipped
    // as Kotlin too.
    ("kotlin.Array.filterNotNull", coll_iter_filter_not_null),
    ("kotlin.collections.List.sumOf", coll_iter_sum_of),
    ("kotlin.collections.MutableList.sumOf", coll_iter_sum_of),
    ("kotlin.collections.Set.sumOf", coll_iter_sum_of),
    ("kotlin.collections.MutableSet.sumOf", coll_iter_sum_of),
    ("kotlin.collections.Map.sumOf", coll_iter_sum_of),
    ("kotlin.collections.MutableMap.sumOf", coll_iter_sum_of),
    ("kotlin.collections.List.maxOfOrNull", coll_iter_max_of_or_null),
    ("kotlin.collections.MutableList.maxOfOrNull", coll_iter_max_of_or_null),
    ("kotlin.collections.Set.maxOfOrNull", coll_iter_max_of_or_null),
    ("kotlin.collections.Iterable.maxOfOrNull", coll_iter_max_of_or_null),
    ("kotlin.collections.List.minOfOrNull", coll_iter_min_of_or_null),
    ("kotlin.collections.MutableList.minOfOrNull", coll_iter_min_of_or_null),
    ("kotlin.collections.Set.minOfOrNull", coll_iter_min_of_or_null),
    ("kotlin.collections.Iterable.minOfOrNull", coll_iter_min_of_or_null),
    ("kotlin.collections.List.distinctBy", coll_iter_distinct_by),
    ("kotlin.collections.MutableList.distinctBy", coll_iter_distinct_by),
    ("kotlin.collections.Set.distinctBy", coll_iter_distinct_by),
    ("kotlin.collections.MutableSet.distinctBy", coll_iter_distinct_by),
    ("kotlin.collections.List.groupBy", coll_iter_group_by),
    ("kotlin.collections.MutableList.groupBy", coll_iter_group_by),
    ("kotlin.collections.Set.groupBy", coll_iter_group_by),
    ("kotlin.collections.MutableSet.groupBy", coll_iter_group_by),
    ("kotlin.collections.List.groupingBy", coll_iter_grouping_by),
    ("kotlin.collections.MutableList.groupingBy", coll_iter_grouping_by),
    ("kotlin.collections.Set.groupingBy", coll_iter_grouping_by),
    ("kotlin.collections.MutableSet.groupingBy", coll_iter_grouping_by),
    ("kotlin.collections.Grouping.eachCount", coll_grouping_each_count),
    ("kotlin.collections.Grouping.fold", coll_grouping_fold),
    ("kotlin.collections.Grouping.reduce", coll_grouping_reduce),
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
    ("kotlin.collections.List.sortedWith", coll_iter_sorted_with),
    ("kotlin.collections.MutableList.sortedWith", coll_iter_sorted_with),
    ("kotlin.collections.Set.sortedWith", coll_iter_sorted_with),
    ("kotlin.collections.MutableSet.sortedWith", coll_iter_sorted_with),
    ("kotlin.collections.List.sortedByDescending", coll_iter_sorted_by_desc),
    ("kotlin.collections.List.maxByOrNull", coll_iter_max_by_or_null),
    ("kotlin.collections.List.minByOrNull", coll_iter_min_by_or_null),
    ("kotlin.collections.MutableList.maxByOrNull", coll_iter_max_by_or_null),
    ("kotlin.collections.MutableList.minByOrNull", coll_iter_min_by_or_null),
    ("kotlin.collections.Iterable.maxByOrNull", coll_iter_max_by_or_null),
    ("kotlin.collections.Iterable.minByOrNull", coll_iter_min_by_or_null),
    ("kotlin.collections.MutableList.sort", coll_mut_list_sort),
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
    ("kotlin.collections.Map.getOrElse", map_get_or_else),
    ("kotlin.collections.MutableMap.getOrElse", map_get_or_else),
    ("kotlin.collections.MutableMap.getOrPut", map_get_or_put),
    ("kotlin.comparisons.minOf", math_min),
    ("kotlin.comparisons.maxOf", math_max),
    ("kotlin.comparisons.compareBy", cmp_compare_by),
    ("kotlin.comparisons.compareByDescending", cmp_compare_by_descending),
    ("kotlin.comparisons.compareValues", cmp_compare_values),
    ("kotlin.comparisons.compareValuesBy", cmp_compare_values_by),
    ("kotlin.Comparator", cmp_comparator_sam),
    ("kotlin.Array", array_ctor_generic),
    ("kotlin.IntArray", array_ctor_int),
    ("kotlin.LongArray", array_ctor_long),
    ("kotlin.DoubleArray", array_ctor_double),
    ("kotlin.FloatArray", array_ctor_float),
    ("kotlin.ShortArray", array_ctor_short),
    ("kotlin.ByteArray", array_ctor_byte),
    ("kotlin.BooleanArray", array_ctor_boolean),
    ("kotlin.CharArray", array_ctor_char),

    // ----- Pair extras: toList -----
    ("kotlin.Pair.toList", pair_to_list),

    // ----- Result -----
    ("kotlin.Result.Companion.success", result_success),
    ("kotlin.Result.Companion.failure", result_failure),
    ("kotlin.runCatching", result_run_catching),
    ("kotlin.Result.runCatching", result_run_catching),
    ("kotlin.Result.fold", result_fold),
    ("kotlin.Result.map", result_map),
    ("kotlin.Result.mapCatching", result_map_catching),
    ("kotlin.Result.onSuccess", result_on_success),
    ("kotlin.Result.onFailure", result_on_failure),
    ("kotlin.Result.isSuccess", result_is_success),
    ("kotlin.Result.isFailure", result_is_failure),
    ("kotlin.Result.getOrThrow", result_get_or_throw),
    ("kotlin.Result.getOrNull", result_get_or_null),
    ("kotlin.Result.exceptionOrNull", result_exception_or_null),
    ("kotlin.Result.getOrDefault", result_get_or_default),
    ("kotlin.Result.getOrElse", result_get_or_else),
    ("kotlin.Result.toString", result_to_string),

    // ----- kotlin.coroutines intrinsics -----
    ("kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED", coroutine_suspended_sentinel),
    ("kotlin.coroutines.__klio_co_newSlot", coro_new_slot),
    ("kotlin.coroutines.__klio_co_armSlot", coro_arm_slot),
    ("kotlin.coroutines.__klio_co_disarmSlot", coro_disarm_slot),
    ("kotlin.coroutines.__klio_co_park", coro_park),
    ("kotlin.coroutines.__klio_co_resume", coro_resume),
    ("kotlin.coroutines.__klio_co_runRoot", coro_run_root),

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
    ("kotlin.String", string_ctor),
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
    ("kotlin.text.StringBuilder.subSequence", string_builder_substring),
    ("kotlin.text.StringBuilder.delete", string_builder_delete_range),
    ("kotlin.text.StringBuilder.setCharAt", string_builder_set_char_at),
    ("kotlin.text.StringBuilder.replace", string_builder_replace),
    ("kotlin.text.StringBuilder.lastIndex", string_builder_last_index),

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
    ("kotlin.String.repeat", &["n"]),
    ("kotlin.String.replace", &["oldValue", "newValue", "ignoreCase"]),
    ("kotlin.String.split", &["delimiters", "ignoreCase", "limit"]),
    ("kotlin.String.substring", &["startIndex", "endIndex"]),
    ("kotlin.String.subSequence", &["startIndex", "endIndex"]),
    ("kotlin.CharSequence.subSequence", &["startIndex", "endIndex"]),
    ("kotlin.String.padStart", &["length", "padChar"]),
    ("kotlin.CharSequence.padStart", &["length", "padChar"]),
    ("kotlin.String.padEnd", &["length", "padChar"]),
    ("kotlin.CharSequence.padEnd", &["length", "padChar"]),
    ("kotlin.String.windowed", &[
        "size", "step", "partialWindows", "transform",
    ]),
    ("kotlin.String.indexOf", &["string", "startIndex", "ignoreCase"]),
    ("kotlin.String.lastIndexOf", &["string", "startIndex", "ignoreCase"]),
    ("kotlin.String.contains", &["other", "ignoreCase"]),
    ("kotlin.String.startsWith", &["prefix", "ignoreCase"]),
    ("kotlin.String.endsWith", &["suffix", "ignoreCase"]),
    ("kotlin.String.regionMatches", &[
        "thisOffset", "other", "otherOffset", "length", "ignoreCase",
    ]),
    ("kotlin.String.toInt", &["radix"]),
    ("kotlin.String.toIntOrNull", &["radix"]),
    ("kotlin.String.toLong", &["radix"]),
    ("kotlin.String.toLongOrNull", &["radix"]),
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

    // Threads / monitors.
    ("kotlin.synchronized", &["lock", "block"]),
    ("kotlin.concurrent.thread", &[
        "start", "isDaemon", "contextClassLoader", "name", "priority", "block",
    ]),
    ("kotlin.concurrent.Thread.sleep", &["millis"]),
];

// ===== scope functions =====
//
// All scope functions dispatch the user's lambda via
// `ctx.host.invoke_callable`. The intrinsic doesn't see the lambda's
// body — the host wires that back into the interpreter's
// `invoke_callable_value` path.

fn iterable_items(v: &Value, what: &str) -> Result<Vec<Value>, RuntimeError> {
    match v {
        Value::List { items, .. } | Value::Set { items, .. } => Ok(items.borrow().clone()),
        Value::Array { items, .. } => Ok(items.borrow().clone()),
        Value::Map { entries, .. } => Ok(entries
            .borrow()
            .iter()
            .map(|(k, v)| Value::MapEntry {
                key: Box::new(k.clone()),
                value: Box::new(v.clone()),
                backing: None,
            })
            .collect()),
        _ => Err(RuntimeError::Type(format!(
            "{what} requires an iterable receiver"
        ))),
    }
}

fn coll_iter_filter_not_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let items = iterable_items(&ctx.args[0], "filterNotNull")?;
    let result: Vec<Value> = items
        .into_iter()
        .filter(|v| !matches!(v, Value::Null))
        .collect();
    Ok(make_list(result, false))
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

fn coll_iter_max_of_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity(
            "maxOfOrNull expects (receiver, block)".into(),
        ));
    }
    let items = iterable_items(&ctx.args[0], "maxOfOrNull")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut best: Option<Value> = None;
    for v in items {
        let r = host.invoke_callable(&block, std::slice::from_ref(&v), *out)?;
        match &best {
            None => best = Some(r),
            Some(b) => {
                if compare_values(&r, b)? == std::cmp::Ordering::Greater {
                    best = Some(r);
                }
            }
        }
    }
    Ok(best.unwrap_or(Value::Null))
}

fn coll_iter_min_of_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity(
            "minOfOrNull expects (receiver, block)".into(),
        ));
    }
    let items = iterable_items(&ctx.args[0], "minOfOrNull")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut best: Option<Value> = None;
    for v in items {
        let r = host.invoke_callable(&block, std::slice::from_ref(&v), *out)?;
        match &best {
            None => best = Some(r),
            Some(b) => {
                if compare_values(&r, b)? == std::cmp::Ordering::Less {
                    best = Some(r);
                }
            }
        }
    }
    Ok(best.unwrap_or(Value::Null))
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
        if !keys.iter().any(|k| Value::structural_eq_boxed(k, &key)) {
            keys.push(key);
            result.push(v);
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
        if let Some(slot) = groups.iter_mut().find(|(k, _)| Value::structural_eq_boxed(k, &key)) {
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

/// `Iterable.groupingBy(keySelector)` — klio represents the lazy
/// `Grouping<T, K>` as a synthetic instance carrying the source items and
/// the key selector. The `Grouping.*` terminals below consume it.
fn coll_iter_grouping_by(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("groupingBy expects (receiver, keySelector)".into()));
    }
    let items = iterable_items(&ctx.args[0], "groupingBy")?;
    let block = ctx.args[1].clone();
    let id = ctx.host.alloc_instance_id();
    Ok(ctx.host.new_synth_instance(
        "kotlin.collections.Grouping",
        id,
        vec![
            ("__grouping_src".to_string(), make_list(items, false)),
            ("__grouping_key".to_string(), block),
        ],
    ))
}

/// Extract the (source items, key selector) a `groupingBy` stashed in its
/// synthetic Grouping instance.
fn grouping_parts(v: &Value) -> Result<(Vec<Value>, Value), RuntimeError> {
    if let Value::Instance(inst) = v {
        let b = inst.borrow();
        if let (Some(Value::List { items, .. }), Some(key)) =
            (b.get("__grouping_src"), b.get("__grouping_key"))
        {
            return Ok((items.borrow().clone(), key));
        }
    }
    Err(RuntimeError::Type("expected a Grouping receiver".into()))
}

fn coll_grouping_each_count(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (items, key) = grouping_parts(&ctx.args[0])?;
    let CallCtx { out, host, .. } = ctx;
    let mut counts: Vec<(Value, i64)> = Vec::new();
    for v in items {
        let k = host.invoke_callable(&key, std::slice::from_ref(&v), *out)?;
        if let Some(slot) = counts.iter_mut().find(|(kk, _)| Value::structural_eq_boxed(kk, &k)) {
            slot.1 += 1;
        } else {
            counts.push((k, 1));
        }
    }
    let entries: Vec<(Value, Value)> =
        counts.into_iter().map(|(k, c)| (k, Value::new_int(c))).collect();
    Ok(make_map(entries, false))
}

/// `Grouping.fold(initial) { acc, e -> ... }` and
/// `Grouping.fold(initialSelector, operation)`. The two-arg form's first
/// argument is the constant initial value; klio also accepts a callable
/// initial selector `(key, element) -> R`.
fn coll_grouping_fold(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (items, key) = grouping_parts(&ctx.args[0])?;
    let initial = ctx.args.get(1).cloned().unwrap_or(Value::Null);
    let op = ctx
        .args
        .get(2)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("fold expects (initial, operation)".into()))?;
    let CallCtx { out, host, .. } = ctx;
    // entry order follows first appearance of each key
    let mut acc: Vec<(Value, Value)> = Vec::new();
    for v in items {
        let k = host.invoke_callable(&key, std::slice::from_ref(&v), *out)?;
        let pos = acc.iter().position(|(kk, _)| Value::structural_eq_boxed(kk, &k));
        let cur = match pos {
            Some(p) => acc[p].1.clone(),
            None => {
                // initial may be a constant or a (key, element) selector
                if is_callable(&initial) {
                    host.invoke_callable(&initial, &[k.clone(), v.clone()], *out)?
                } else {
                    initial.clone()
                }
            }
        };
        let next = host.invoke_callable(&op, &[cur, v.clone()], *out)?;
        match pos {
            Some(p) => acc[p].1 = next,
            None => acc.push((k, next)),
        }
    }
    Ok(make_map(acc, false))
}

fn coll_grouping_reduce(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (items, key) = grouping_parts(&ctx.args[0])?;
    let op = ctx
        .args
        .get(1)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("reduce expects (operation)".into()))?;
    let CallCtx { out, host, .. } = ctx;
    let mut acc: Vec<(Value, Value)> = Vec::new();
    for v in items {
        let k = host.invoke_callable(&key, std::slice::from_ref(&v), *out)?;
        match acc.iter().position(|(kk, _)| Value::structural_eq_boxed(kk, &k)) {
            Some(p) => {
                let cur = acc[p].1.clone();
                // reduce operation is (key, accumulator, element)
                acc[p].1 = host.invoke_callable(&op, &[k, cur, v], *out)?;
            }
            None => acc.push((k, v)),
        }
    }
    Ok(make_map(acc, false))
}

fn is_callable(v: &Value) -> bool {
    matches!(
        v,
        Value::Lambda { .. }
            | Value::IrClosure { .. }
            | Value::Function { .. }
            | Value::Intrinsic { .. }
            | Value::Instance(_)
    )
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
        if let Some(slot) = entries.iter_mut().find(|(kk, _)| Value::structural_eq_boxed(kk, &key)) {
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
        if let Some(slot) = entries.iter_mut().find(|(kk, _)| Value::structural_eq_boxed(kk, &key)) {
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
        if let Some(slot) = entries.iter_mut().find(|(kk, _)| Value::structural_eq_boxed(kk, &v)) {
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

fn coll_iter_max_min_by_impl(
    ctx: &mut CallCtx,
    descending: bool,
    what: &str,
) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity(format!("{what} expects (receiver, block)")));
    }
    let items = iterable_items(&ctx.args[0], what)?;
    if items.is_empty() {
        return Ok(Value::Null);
    }
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut best_key = host.invoke_callable(&block, std::slice::from_ref(&items[0]), *out)?;
    let mut best = items[0].clone();
    for v in items.iter().skip(1) {
        let key = host.invoke_callable(&block, std::slice::from_ref(v), *out)?;
        let ord = compare_values(&key, &best_key)?;
        let take = if descending {
            ord == std::cmp::Ordering::Less
        } else {
            ord == std::cmp::Ordering::Greater
        };
        if take {
            best_key = key;
            best = v.clone();
        }
    }
    Ok(best)
}

fn coll_iter_max_by_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    coll_iter_max_min_by_impl(ctx, false, "maxByOrNull")
}

fn coll_iter_min_by_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    coll_iter_max_min_by_impl(ctx, true, "minByOrNull")
}

fn coll_mut_list_sort(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "MutableList.sort")?;
    let mut copy: Vec<Value> = it.borrow().clone();
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
    *it.borrow_mut() = copy;
    Ok(Value::Unit)
}

fn coll_iter_sorted_with(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity(
            "sortedWith expects (receiver, comparator)".into(),
        ));
    }
    let items = iterable_items(&ctx.args[0], "sortedWith")?;
    let comparator = ctx.args[1].clone();
    let Value::Comparator { steps, descending } = comparator else {
        return Err(RuntimeError::Type(
            "sortedWith expects a Comparator argument".into(),
        ));
    };
    let CallCtx { out, host, .. } = ctx;
    let mut items: Vec<Value> = items;
    let mut err: Option<RuntimeError> = None;
    // Empty step list — Comparator.naturalOrder() / reverseOrder():
    // sort items directly using value-level comparison.
    if steps.is_empty() {
        items.sort_by(|a, b| {
            if err.is_some() {
                return std::cmp::Ordering::Equal;
            }
            match compare_values(a, b) {
                Ok(o) => if descending { o.reverse() } else { o },
                Err(e) => {
                    err = Some(e);
                    std::cmp::Ordering::Equal
                }
            }
        });
    } else {
        // Insertion sort so callbacks can invoke through host.
        for i in 1..items.len() {
            let mut j = i;
            while j > 0 && err.is_none() {
                let mut ord = std::cmp::Ordering::Equal;
                for (sel, step_desc) in steps.iter() {
                    let lhs_arg = items[j - 1].clone();
                    let rhs_arg = items[j].clone();
                    let ka = match host.invoke_callable(sel, std::slice::from_ref(&lhs_arg), *out) {
                        Ok(v) => v,
                        Err(e) => { err = Some(e); break; }
                    };
                    let kb = match host.invoke_callable(sel, std::slice::from_ref(&rhs_arg), *out) {
                        Ok(v) => v,
                        Err(e) => { err = Some(e); break; }
                    };
                    let o = match compare_values(&ka, &kb) {
                        Ok(o) => o,
                        Err(e) => { err = Some(e); break; }
                    };
                    let flipped = if *step_desc { o.reverse() } else { o };
                    if flipped != std::cmp::Ordering::Equal {
                        ord = flipped;
                        break;
                    }
                }
                if descending {
                    ord = ord.reverse();
                }
                if matches!(ord, std::cmp::Ordering::Greater) {
                    items.swap(j - 1, j);
                    j -= 1;
                } else {
                    break;
                }
            }
        }
    }
    if let Some(e) = err {
        return Err(e);
    }
    Ok(make_list(items, false))
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
        fqn: Arc::new("kotlin.NoSuchElementException".into()),
        message: Some(Arc::new("Collection is empty.".into())),
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

fn map_entries_clone(v: &Value, what: &str) -> Result<Vec<(Value, Value)>, RuntimeError> {
    match v {
        Value::Map { entries, .. } => Ok(entries.borrow().clone()),
        _ => Err(RuntimeError::Type(format!("{what} requires a Map receiver"))),
    }
}

fn map_get_or_else(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 3 {
        return Err(RuntimeError::Arity("getOrElse expects (receiver, key, block)".into()));
    }
    let entries = map_entries_clone(&ctx.args[0], "getOrElse")?;
    let key = ctx.args[1].clone();
    if let Some((_, v)) = entries.iter().find(|(k, _)| Value::structural_eq_boxed(k, &key)) {
        return Ok(v.clone());
    }
    let block = ctx.args[2].clone();
    let CallCtx { out, host, .. } = ctx;
    host.invoke_callable(&block, &[], *out)
}

fn map_get_or_put(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 3 {
        return Err(RuntimeError::Arity("getOrPut expects (receiver, key, block)".into()));
    }
    let recv = ctx.args[0].clone();
    let Value::Map { entries, .. } = &recv else {
        return Err(RuntimeError::Type("getOrPut requires a MutableMap receiver".into()));
    };
    let entries_rc = entries.clone();
    let key = ctx.args[1].clone();
    if let Some((_, v)) = entries_rc.borrow().iter().find(|(k, _)| Value::structural_eq_boxed(k, &key)) {
        return Ok(v.clone());
    }
    let block = ctx.args[2].clone();
    let CallCtx { out, host, .. } = ctx;
    let new_v = host.invoke_callable(&block, &[], *out)?;
    entries_rc.borrow_mut().push((key, new_v.clone()));
    Ok(new_v)
}

/// `Array<T>.isEmpty()` / `isNotEmpty()` (and the primitive-array
/// variants) — `size == 0`. Stdlib extensions, not member fns.
fn array_len(recv: &Value) -> Option<usize> {
    match recv {
        Value::Array { items, .. } => Some(items.borrow().len()),
        Value::List { items, .. } => Some(items.borrow().len()),
        _ => None,
    }
}
fn array_is_empty(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let r = ctx
        .args
        .first()
        .and_then(array_len)
        .ok_or_else(|| RuntimeError::Type("isEmpty requires an array".into()))?;
    Ok(Value::Bool(r == 0))
}
fn array_is_not_empty(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let r = ctx
        .args
        .first()
        .and_then(array_len)
        .ok_or_else(|| RuntimeError::Type("isNotEmpty requires an array".into()))?;
    Ok(Value::Bool(r != 0))
}

fn array_size_arg(v: &Value, what: &str) -> Result<i64, RuntimeError> {
    let n = v.as_i64().ok_or_else(|| RuntimeError::Type(format!("{what} expects an Int size")))?;
    if n < 0 {
        return Err(RuntimeError::Type(format!("{what}: negative array size {n}")));
    }
    Ok(n)
}

fn array_ctor_impl(
    ctx: &mut CallCtx,
    name: &str,
    prim: Option<klio_runtime::PrimitiveArrayKind>,
    default: Value,
) -> Result<Value, RuntimeError> {
    if ctx.args.is_empty() || ctx.args.len() > 2 {
        return Err(RuntimeError::Arity(format!("{name} expects (size) or (size, init)")));
    }
    let n = array_size_arg(&ctx.args[0], name)?;
    if ctx.args.len() == 1 {
        let items: Vec<Value> = (0..n).map(|_| default.clone()).collect();
        return Ok(Value::Array { items: ObjRef::new(items), prim });
    }
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut items = Vec::with_capacity(n as usize);
    for i in 0..n {
        let v = host.invoke_callable(&block, &[Value::Int(i as i32)], *out)?;
        items.push(v);
    }
    Ok(Value::Array { items: ObjRef::new(items), prim })
}

fn array_ctor_generic(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    array_ctor_impl(ctx, "Array", None, Value::Null)
}
fn array_ctor_int(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    array_ctor_impl(ctx, "IntArray", Some(klio_runtime::PrimitiveArrayKind::Int), Value::Int(0))
}
fn array_ctor_long(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    array_ctor_impl(ctx, "LongArray", Some(klio_runtime::PrimitiveArrayKind::Long), Value::Long(0))
}
fn array_ctor_double(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    array_ctor_impl(ctx, "DoubleArray", Some(klio_runtime::PrimitiveArrayKind::Double), Value::Double(0.0))
}
fn array_ctor_float(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    array_ctor_impl(ctx, "FloatArray", Some(klio_runtime::PrimitiveArrayKind::Float), Value::Float(0.0))
}
fn array_ctor_short(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    array_ctor_impl(ctx, "ShortArray", Some(klio_runtime::PrimitiveArrayKind::Short), Value::Short(0))
}
fn array_ctor_byte(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    array_ctor_impl(ctx, "ByteArray", Some(klio_runtime::PrimitiveArrayKind::Byte), Value::Byte(0))
}
fn array_ctor_boolean(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    array_ctor_impl(ctx, "BooleanArray", Some(klio_runtime::PrimitiveArrayKind::Boolean), Value::Bool(false))
}
fn array_ctor_char(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    array_ctor_impl(ctx, "CharArray", Some(klio_runtime::PrimitiveArrayKind::Char), Value::Char('\u{0}'))
}

fn cmp_compare_values_by(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() < 3 {
        return Err(RuntimeError::Arity("compareValuesBy expects (a, b, selector, ...)".into()));
    }
    let a = ctx.args[0].clone();
    let b = ctx.args[1].clone();
    let selectors: Vec<Value> = ctx.args[2..].to_vec();
    let CallCtx { out, host, .. } = ctx;
    for sel in selectors {
        if !matches!(&sel, Value::Lambda { .. } | Value::IrClosure { .. }) {
            return Err(RuntimeError::Type(
                "compareValuesBy expects key-selector lambdas".into(),
            ));
        }
        let ka = host.invoke_callable(&sel, std::slice::from_ref(&a), *out)?;
        let kb = host.invoke_callable(&sel, std::slice::from_ref(&b), *out)?;
        let ord = match (matches!(ka, Value::Null), matches!(kb, Value::Null)) {
            (true, true) => std::cmp::Ordering::Equal,
            (true, false) => std::cmp::Ordering::Less,
            (false, true) => std::cmp::Ordering::Greater,
            (false, false) => compare_values(&ka, &kb)?,
        };
        if !matches!(ord, std::cmp::Ordering::Equal) {
            return Ok(Value::new_int(match ord {
                std::cmp::Ordering::Less => -1,
                std::cmp::Ordering::Greater => 1,
                std::cmp::Ordering::Equal => 0,
            }));
        }
    }
    Ok(Value::new_int(0))
}

fn cmp_comparator_sam(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 1 {
        return Err(RuntimeError::Arity("Comparator { … } expects a 2-arg comparison lambda".into()));
    }
    let lam = ctx.args[0].clone();
    if !matches!(&lam, Value::Lambda { .. } | Value::IrClosure { .. }) {
        return Err(RuntimeError::Type(
            "Comparator { … } expects a 2-arg comparison lambda".into(),
        ));
    }
    Ok(Value::Comparator {
        steps: Arc::new(vec![(lam, false)]),
        descending: false,
    })
}

fn cmp_compare_by(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let mut steps: Vec<(Value, bool)> = Vec::with_capacity(ctx.args.len());
    for a in ctx.args {
        steps.push((a.clone(), false));
    }
    Ok(Value::Comparator { steps: Arc::new(steps), descending: false })
}

fn cmp_compare_by_descending(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let mut steps: Vec<(Value, bool)> = Vec::with_capacity(ctx.args.len());
    for a in ctx.args {
        steps.push((a.clone(), true));
    }
    Ok(Value::Comparator { steps: Arc::new(steps), descending: false })
}

fn cmp_compare_values(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("compareValues expects two arguments".into()));
    }
    let a = &ctx.args[0];
    let b = &ctx.args[1];
    let n: i32 = match (matches!(a, Value::Null), matches!(b, Value::Null)) {
        (true, true) => 0,
        (true, false) => -1,
        (false, true) => 1,
        (false, false) => match compare_values(a, b)? {
            std::cmp::Ordering::Less => -1,
            std::cmp::Ordering::Equal => 0,
            std::cmp::Ordering::Greater => 1,
        },
    };
    Ok(Value::new_int(n as i64))
}

fn builders_build_list(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.is_empty() || ctx.args.len() > 2 {
        return Err(RuntimeError::Arity("buildList expects (block) or (capacity, block)".into()));
    }
    let block = ctx.args[ctx.args.len() - 1].clone();
    let buildable = Value::List {
        items: ObjRef::new(Vec::new()),
        mutable: true,
        enum_class: None,
        backing: None,
    };
    {
        let CallCtx { out, host, .. } = ctx;
        host.invoke_callable_with_this(&block, &[], &buildable, *out)?;
    }
    let Value::List { items, .. } = buildable else { unreachable!() };
    Ok(Value::List { items, mutable: false, enum_class: None, backing: None })
}

fn builders_build_set(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.is_empty() || ctx.args.len() > 2 {
        return Err(RuntimeError::Arity("buildSet expects (block) or (capacity, block)".into()));
    }
    let block = ctx.args[ctx.args.len() - 1].clone();
    let buildable = Value::List {
        items: ObjRef::new(Vec::new()),
        mutable: true,
        enum_class: None,
        backing: None,
    };
    {
        let CallCtx { out, host, .. } = ctx;
        host.invoke_callable_with_this(&block, &[], &buildable, *out)?;
    }
    let Value::List { items, .. } = buildable else { unreachable!() };
    let mut deduped: Vec<Value> = Vec::new();
    for v in items.borrow().iter() {
        if !deduped.iter().any(|x| Value::structural_eq_boxed(x, v)) {
            deduped.push(v.clone());
        }
    }
    Ok(Value::Set { items: ObjRef::new(deduped), mutable: false, backing: None })
}

fn builders_build_map(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.is_empty() || ctx.args.len() > 2 {
        return Err(RuntimeError::Arity("buildMap expects (block) or (capacity, block)".into()));
    }
    let block = ctx.args[ctx.args.len() - 1].clone();
    let buildable = Value::Map {
        entries: ObjRef::new(Vec::new()),
        mutable: true,
    };
    {
        let CallCtx { out, host, .. } = ctx;
        host.invoke_callable_with_this(&block, &[], &buildable, *out)?;
    }
    let Value::Map { entries, .. } = buildable else { unreachable!() };
    Ok(Value::Map { entries, mutable: false })
}

fn builders_build_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 1 {
        return Err(RuntimeError::Arity("buildString expects (block)".into()));
    }
    let block = ctx.args[0].clone();
    let sb = Value::StringBuilder(ObjRef::new(String::new()));
    {
        let CallCtx { out, host, .. } = ctx;
        host.invoke_callable_with_this(&block, &[], &sb, *out)?;
    }
    let Value::StringBuilder(s) = sb else { unreachable!() };
    Ok(Value::String(Arc::new(s.borrow().clone())))
}

fn contract_error(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = ctx.args.first().cloned().unwrap_or(Value::Null);
    let msg = match v {
        Value::String(s) => (*s).clone(),
        other => format!("{other}"),
    };
    Err(RuntimeError::Thrown(Value::Exception {
        fqn: Arc::new("kotlin.IllegalStateException".into()),
        message: Some(Arc::new(msg)),
        cause: None,
    }))
}

fn contract_todo(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let msg = match ctx.args.first().cloned() {
        Some(Value::String(s)) => format!("An operation is not implemented: {s}"),
        Some(other) => format!("An operation is not implemented: {other}"),
        None => "An operation is not implemented.".to_string(),
    };
    Err(RuntimeError::Thrown(Value::Exception {
        fqn: Arc::new("kotlin.NotImplementedError".into()),
        message: Some(Arc::new(msg)),
        cause: None,
    }))
}

/// State of one reentrant monitor: which thread (if any) currently
/// owns it and how deep its nesting is.
struct MonitorState {
    owner: Option<std::thread::ThreadId>,
    depth: usize,
}

/// Process-wide monitor table keyed by the lock value's object
/// identity. Value-type locks (no identity) all share a single
/// monitor under the sentinel key `0`.
fn monitor_for(key: usize) -> Arc<(std::sync::Mutex<MonitorState>, std::sync::Condvar)> {
    use std::collections::HashMap;
    use std::sync::OnceLock;
    type Reg = std::sync::Mutex<
        HashMap<usize, Arc<(std::sync::Mutex<MonitorState>, std::sync::Condvar)>>,
    >;
    static REGISTRY: OnceLock<Reg> = OnceLock::new();
    let reg = REGISTRY.get_or_init(|| std::sync::Mutex::new(HashMap::new()));
    let mut g = reg.lock().unwrap_or_else(|e| e.into_inner());
    g.entry(key)
        .or_insert_with(|| {
            Arc::new((
                std::sync::Mutex::new(MonitorState { owner: None, depth: 0 }),
                std::sync::Condvar::new(),
            ))
        })
        .clone()
}

/// `synchronized(lock) { body }` / `synchronized(lock, { body })`.
///
/// A real reentrant monitor keyed by the `lock` argument's object
/// identity: distinct locks run concurrently, the same lock
/// serializes, and the same thread re-entering the same lock does
/// not self-deadlock (Kotlin/JVM monitors are reentrant). The body
/// runs with the monitor held; it is released (even on a thrown
/// exception) before returning. `fence_and_publish` marks the
/// monitor enter and exit boundaries.
pub fn concurrent_synchronized(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let lock = ctx.args.first().cloned().unwrap_or(Value::Unit);
    let block = ctx
        .args
        .last()
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("synchronized expects (lock, block)".into()))?;
    let key = lock.lock_identity().unwrap_or(0);
    let mon = monitor_for(key);
    let me = std::thread::current().id();

    // Acquire (reentrant): block until the monitor is free or already
    // owned by this thread, then take/deepen ownership.
    {
        let mut st = mon.0.lock().unwrap_or_else(|e| e.into_inner());
        loop {
            match st.owner {
                Some(o) if o == me => {
                    st.depth += 1;
                    break;
                }
                None => {
                    st.owner = Some(me);
                    st.depth = 1;
                    break;
                }
                Some(_) => {
                    st = mon.1.wait(st).unwrap_or_else(|e| e.into_inner());
                }
            }
        }
    }
    klio_runtime::fence_and_publish(); // monitor enter

    let CallCtx { out, host, .. } = ctx;
    let result = host.invoke_callable(&block, &[], *out);

    klio_runtime::fence_and_publish(); // monitor exit
    // Release one level; wake a waiter when fully released.
    {
        let mut st = mon.0.lock().unwrap_or_else(|e| e.into_inner());
        if st.depth > 0 {
            st.depth -= 1;
        }
        if st.depth == 0 {
            st.owner = None;
            mon.1.notify_one();
        }
    }
    result
}

/// `kotlin.concurrent.thread(start, isDaemon, contextClassLoader,
/// name, priority) { block }`.
///
/// On a single serialized interpreter a started thread's body runs to
/// completion immediately on the calling stack: the body's every
/// action happens-before the call returns, which is exactly the
/// happens-before edge `Thread.start` would give, only stronger
/// (total order). The returned handle is a `Thread` sentinel whose
/// `join()` is a no-op (the body already completed, so its writes are
/// already visible — join-happens-before holds trivially), `isAlive`
/// is `false`, and `name` is a stable string. This is observably
/// correct for every race-free program, which is the only class
/// Kotlin defines behaviour for.
fn concurrent_thread(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let block = ctx
        .args
        .iter()
        .rev()
        .find(|v| {
            matches!(
                v,
                Value::Function { .. }
                    | Value::Lambda { .. }
                    | Value::IrClosure { .. }
                    | Value::Intrinsic { .. }
                    | Value::BoundMethod { .. }
                    | Value::BoundUserMethod { .. }
            )
        })
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("thread expects a block".into()))?;
    // `thread(start = false) { … }` — leading boolean positional /
    // named arg of `false` means the caller will `.start()` it
    // explicitly. Without a real deferred-start handle we still spawn
    // (the body runs concurrently regardless); a later `.start()` is
    // a no-op. Defaulting to start=true matches the common case.
    let CallCtx { out, host, .. } = ctx;
    klio_runtime::fence_and_publish(); // thread start
    let id = host.spawn_os_thread(&block, *out)?;
    Ok(Value::BoundMethod {
        fqn: "kotlin.concurrent.Thread",
        func: thread_handle_stub,
        receiver: Box::new(Value::Long(id as i64)),
    })
}

/// `Thread.sleep(millis: Long)` / `Thread.sleep(millis: Int)`.
///
/// A real `std::thread::sleep`: the calling OS thread blocks for the
/// requested duration. Combined with `kotlin.concurrent.thread`'s real
/// `std::thread::spawn`, N threads each sleeping for D run in ~D wall
/// time, not ~N·D — genuine parallel suspension, not a busy spin.
fn concurrent_thread_sleep(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let millis = match ctx.args.first() {
        Some(Value::Long(v)) => *v,
        Some(Value::Int(v)) => i64::from(*v),
        Some(Value::Short(v)) => i64::from(*v),
        Some(Value::Byte(v)) => i64::from(*v),
        _ => {
            return Err(RuntimeError::Type(
                "Thread.sleep expects a Long or Int millisecond argument".into(),
            ))
        }
    };
    if millis > 0 {
        std::thread::sleep(std::time::Duration::from_millis(millis as u64));
    }
    Ok(Value::Unit)
}

/// `Thread.currentThread()` — a `Thread` sentinel for the calling OS
/// thread. Its `.name` is a stable per-thread string derived from the
/// OS thread id, so two calls on the same thread report the same name
/// and distinct threads report distinct names; `.isAlive` is `true`
/// (the calling thread is, by definition, running).
fn concurrent_thread_current(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let raw = format!("{:?}", std::thread::current().id());
    // `ThreadId(N)` -> N; fall back to a hash of the debug string.
    let id: u64 = raw
        .trim_start_matches("ThreadId(")
        .trim_end_matches(')')
        .parse()
        .unwrap_or_else(|_| {
            use std::hash::{Hash, Hasher};
            let mut h = std::collections::hash_map::DefaultHasher::new();
            raw.hash(&mut h);
            h.finish()
        });
    Ok(Value::BoundMethod {
        fqn: "kotlin.concurrent.Thread",
        func: thread_handle_stub,
        receiver: Box::new(Value::Long(id as i64)),
    })
}

/// Wall-clock time in milliseconds since the Unix epoch. Backs the
/// `systemClockNow()` / `serializedInstant` klio `actual`s for the
/// upstream `kotlin.time` commonMain `Clock.System` / `Instant`.
fn time_system_millis(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let millis = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);
    Ok(Value::Long(millis))
}

/// A monotonically non-decreasing reading in nanoseconds. Only
/// differences between readings are meaningful; the upstream
/// `MonotonicTimeSource` actual fixes a "zero" on first read. Backs
/// `TimeSource.Monotonic` / `markNow()`.
fn time_monotonic_nanos(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    use std::sync::OnceLock;
    use std::time::Instant;
    static ORIGIN: OnceLock<Instant> = OnceLock::new();
    let origin = *ORIGIN.get_or_init(Instant::now);
    let nanos = origin.elapsed().as_nanos();
    Ok(Value::Long(i64::try_from(nanos).unwrap_or(i64::MAX)))
}

/// Placeholder dispatch for a bare `Thread` sentinel value. Member
/// access (`join`, `name`, `isAlive`) is intercepted by the
/// interpreter before this is ever called; invoking the handle itself
/// is not a valid Kotlin operation.
fn thread_handle_stub(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Err(RuntimeError::Type(
        "Thread handle is not callable; use .join() / .name / .isAlive".into(),
    ))
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

/// Render a value via its user-overridden `toString()` when one
/// exists, falling back to the runtime's structural Display
/// rendering. Used by `println` / `print` so plain-class instances
/// pick up `override fun toString()` rather than always landing on
/// the default `ClassName@<hex>` shape.
fn render_via_user_to_string(
    ctx: &mut CallCtx,
    v: &Value,
) -> String {
    if matches!(v, Value::Instance(_)) {
        let CallCtx { out, host, .. } = ctx;
        if let Some(Ok(Value::String(s))) =
            host.invoke_method(v, "toString", &[], *out)
        {
            return (*s).clone();
        }
    }
    format!("{v}")
}

fn io_println(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    match ctx.args.len() {
        0 => {
            ctx.out.writeln("");
            Ok(Value::Unit)
        }
        1 => {
            let v = ctx.args[0].clone();
            let rendered = render_via_user_to_string(ctx, &v);
            ctx.out.writeln(&rendered);
            Ok(Value::Unit)
        }
        _ => Err(RuntimeError::Arity(format!(
            "println expects 0 or 1 arguments, got {}",
            ctx.args.len()
        ))),
    }
}

fn io_print(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    match ctx.args.len() {
        0 => Ok(Value::Unit),
        1 => {
            let v = ctx.args[0].clone();
            let rendered = render_via_user_to_string(ctx, &v);
            ctx.out.write(&rendered);
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
            Ok(Value::String(Arc::new(buf)))
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
        [Value::Long(n)] => Ok(Value::Long(n.wrapping_abs())),
        [Value::Double(n)] => Ok(Value::Double(n.abs())),
        [Value::Float(n)] => Ok(Value::Float(n.abs())),
        _ => Err(RuntimeError::Type("abs requires a number".into())),
    }
}

/// Numeric `min`/`max` over any Kotlin number pair (Byte/Short/Int/
/// Long/Float/Double, including mixed). Doubles as the
/// `kotlin.comparisons.minOf`/`maxOf` and `kotlin.math.min`/`max`
/// implementation. Integral pairs keep an integral result (widened
/// to the larger of the two so e.g. `minOf(Long, Int)` is a Long);
/// any floating operand promotes the result to Double.
fn num_extreme(args: &[Value], want_min: bool, what: &str) -> Result<Value, RuntimeError> {
    let [a, b] = args else {
        return Err(RuntimeError::Arity(format!("{what} expects 2 arguments")));
    };
    fn as_f(v: &Value) -> Option<f64> {
        match v {
            Value::Int(x) => Some(*x as f64),
            Value::Long(x) => Some(*x as f64),
            Value::Short(x) => Some(*x as f64),
            Value::Byte(x) => Some(*x as f64),
            Value::Float(x) => Some(*x as f64),
            Value::Double(x) => Some(*x),
            _ => None,
        }
    }
    fn as_i(v: &Value) -> Option<i64> {
        match v {
            Value::Int(x) => Some(*x as i64),
            Value::Long(x) => Some(*x),
            Value::Short(x) => Some(*x as i64),
            Value::Byte(x) => Some(*x as i64),
            _ => None,
        }
    }
    let floating = matches!(a, Value::Double(_) | Value::Float(_))
        || matches!(b, Value::Double(_) | Value::Float(_));
    if floating {
        let (x, y) = (
            as_f(a).ok_or_else(|| RuntimeError::Type(format!("{what}: non-numeric arg")))?,
            as_f(b).ok_or_else(|| RuntimeError::Type(format!("{what}: non-numeric arg")))?,
        );
        // Kotlin's minOf/maxOf use Math.min/max, which propagate NaN — unlike
        // Rust's f64::min/max which return the non-NaN operand.
        return Ok(Value::Double(if x.is_nan() || y.is_nan() {
            f64::NAN
        } else if want_min {
            x.min(y)
        } else {
            x.max(y)
        }));
    }
    let (x, y) = (
        as_i(a).ok_or_else(|| RuntimeError::Type(format!("{what}: non-numeric arg")))?,
        as_i(b).ok_or_else(|| RuntimeError::Type(format!("{what}: non-numeric arg")))?,
    );
    let r = if want_min { x.min(y) } else { x.max(y) };
    // Widen to Long if either operand was Long; otherwise Int.
    if matches!(a, Value::Long(_)) || matches!(b, Value::Long(_)) {
        Ok(Value::Long(r))
    } else {
        Ok(Value::Int(r as i32))
    }
}

fn math_min(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    cmp_extreme(ctx, true, "min")
}

fn math_max(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    cmp_extreme(ctx, false, "max")
}

fn cmp_extreme(
    ctx: &mut CallCtx,
    want_min: bool,
    what: &str,
) -> Result<Value, RuntimeError> {
    // Instance-aware path: a user receiver implementing Comparable
    // (`operator fun compareTo`) reaches min/max via call_member,
    // falling back to the primitive num_extreme for plain numbers.
    if let [a, b] = ctx.args {
        if matches!(a, Value::Instance(_)) || matches!(b, Value::Instance(_)) {
            let CallCtx { out, host, .. } = ctx;
            let ord = compare_host_aware(a, b, host, *out)?;
            let pick_first = if want_min {
                ord != std::cmp::Ordering::Greater
            } else {
                ord != std::cmp::Ordering::Less
            };
            return Ok(if pick_first { a.clone() } else { b.clone() });
        }
    }
    num_extreme(ctx.args, want_min, what)
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
    // Kotlin's kotlin.math.round rounds half to even (IEEE rint), unlike
    // Rust's round() which rounds half away from zero.
    Ok(Value::Double(as_double(arg1(ctx, "round")?, "round")?.round_ties_even()))
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
    // Kotlin's sign preserves a signed/NaN zero: sign(0.0)=0.0, sign(-0.0)=-0.0,
    // sign(NaN)=NaN. Rust's signum() returns ±1.0 for zero, so special-case it.
    fn fsign(n: f64) -> f64 {
        if n == 0.0 || n.is_nan() {
            n
        } else {
            n.signum()
        }
    }
    match v {
        Value::Int(n) => Ok(Value::Int(n.signum())),
        Value::Long(n) => Ok(Value::Int(n.signum() as i32)),
        Value::Float(n) => Ok(Value::Float(fsign(*n as f64) as f32)),
        Value::Double(n) => Ok(Value::Double(fsign(*n))),
        other => Err(RuntimeError::Type(format!("sign requires a number, got {other:?}"))),
    }
}

fn math_cbrt(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(as_double(arg1(ctx, "cbrt")?, "cbrt")?.cbrt()))
}

/// `roundToInt()` / `roundToLong()`: round half toward +∞ (Java `Math.round`),
/// throw on NaN, clamp out-of-range to the type's MIN/MAX.
fn num_round_to_int(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let d = as_double(arg1(ctx, "roundToInt")?, "roundToInt")?;
    if d.is_nan() {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IllegalArgumentException",
            Some("Cannot round NaN value.".into()),
        )));
    }
    let r = (d + 0.5).floor();
    let v = if r >= i32::MAX as f64 {
        i32::MAX
    } else if r <= i32::MIN as f64 {
        i32::MIN
    } else {
        r as i32
    };
    Ok(Value::Int(v))
}

fn num_round_to_long(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let d = as_double(arg1(ctx, "roundToLong")?, "roundToLong")?;
    if d.is_nan() {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IllegalArgumentException",
            Some("Cannot round NaN value.".into()),
        )));
    }
    let r = (d + 0.5).floor();
    let v = if r >= i64::MAX as f64 {
        i64::MAX
    } else if r <= i64::MIN as f64 {
        i64::MIN
    } else {
        r as i64
    };
    Ok(Value::Long(v))
}

fn num_take_highest_one_bit(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    match arg1(ctx, "takeHighestOneBit")? {
        Value::Int(n) => {
            let u = *n as u32;
            Ok(Value::Int(if u == 0 { 0 } else { (1u32 << (31 - u.leading_zeros())) as i32 }))
        }
        Value::Long(n) => {
            let u = *n as u64;
            Ok(Value::Long(if u == 0 { 0 } else { (1u64 << (63 - u.leading_zeros())) as i64 }))
        }
        other => Err(RuntimeError::Type(format!(
            "takeHighestOneBit requires an integer, got {other:?}"
        ))),
    }
}

fn num_take_lowest_one_bit(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    match arg1(ctx, "takeLowestOneBit")? {
        Value::Int(n) => Ok(Value::Int(n & n.wrapping_neg())),
        Value::Long(n) => Ok(Value::Long(n & n.wrapping_neg())),
        other => Err(RuntimeError::Type(format!(
            "takeLowestOneBit requires an integer, got {other:?}"
        ))),
    }
}

fn num_rotate_left(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (a, b) = arg2(ctx, "rotateLeft")?;
    let n = b
        .as_i64()
        .ok_or_else(|| RuntimeError::Type("rotateLeft bitCount must be Int".into()))?;
    match a {
        Value::Int(x) => Ok(Value::Int(x.rotate_left(n.rem_euclid(32) as u32))),
        Value::Long(x) => Ok(Value::Long(x.rotate_left(n.rem_euclid(64) as u32))),
        other => Err(RuntimeError::Type(format!(
            "rotateLeft requires an integer, got {other:?}"
        ))),
    }
}

fn num_rotate_right(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (a, b) = arg2(ctx, "rotateRight")?;
    let n = b
        .as_i64()
        .ok_or_else(|| RuntimeError::Type("rotateRight bitCount must be Int".into()))?;
    match a {
        Value::Int(x) => Ok(Value::Int(x.rotate_right(n.rem_euclid(32) as u32))),
        Value::Long(x) => Ok(Value::Long(x.rotate_right(n.rem_euclid(64) as u32))),
        other => Err(RuntimeError::Type(format!(
            "rotateRight requires an integer, got {other:?}"
        ))),
    }
}

/// `Double.rem(Double)` / `Float.rem` — IEEE remainder (sign of dividend),
/// same as the `%` operator.
fn num_float_rem(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (a, b) = arg2(ctx, "rem")?;
    let r = as_double(a, "rem")? % as_double(b, "rem")?;
    Ok(if matches!(a, Value::Float(_)) {
        Value::Float(r as f32)
    } else {
        Value::Double(r)
    })
}

/// `Double.mod(Double)` / `Float.mod` — floored modulus (sign of divisor).
fn num_float_mod(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (a, b) = arg2(ctx, "mod")?;
    let (x, y) = (as_double(a, "mod")?, as_double(b, "mod")?);
    let mut r = x % y;
    if r != 0.0 && (r < 0.0) != (y < 0.0) {
        r += y;
    }
    Ok(if matches!(a, Value::Float(_)) {
        Value::Float(r as f32)
    } else {
        Value::Double(r)
    })
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

fn recv_string<'a>(args: &'a [Value], what: &str) -> Result<&'a Arc<String>, RuntimeError> {
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

/// `String.toString()` — the receiver itself.
fn string_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.toString")?.clone();
    Ok(Value::String(s))
}

fn string_uppercase(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.uppercase")?;
    Ok(Value::String(Arc::new(s.to_uppercase())))
}

fn string_lowercase(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.lowercase")?;
    Ok(Value::String(Arc::new(s.to_lowercase())))
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
    Ok(Value::String(Arc::new(joined)))
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
    Ok(Value::String(Arc::new(out)))
}

/// `CharSequence.padStart(length, padChar = ' ')` / `padEnd`. Host
/// impls so the call doesn't route to upstream's `String.padStart =
/// (this as CharSequence).padStart(...)`, whose explicit upcast klio
/// ignores in overload selection — it re-dispatches to `String.padStart`
/// and recurses forever, allocating a StringBuilder each level (OOM).
fn string_pad(ctx: &mut CallCtx, at_start: bool, who: &str) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, who)?;
    let chars: Vec<char> = s.chars().collect();
    let cur_len = chars.len() as i64;
    let length = ctx
        .args
        .get(1)
        .and_then(Value::as_i64)
        .ok_or_else(|| RuntimeError::Arity(format!("{who} requires an Int length")))?;
    if length < 0 {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IllegalArgumentException",
            Some(format!("Desired length {length} is less than zero.")),
        )));
    }
    let pad = match ctx.args.get(2) {
        Some(Value::Char(c)) => *c,
        None => ' ',
        Some(other) => {
            return Err(RuntimeError::Type(format!(
                "{who}: padChar must be a Char, got {other}"
            )))
        }
    };
    if length <= cur_len {
        return Ok(Value::String(Arc::clone(s)));
    }
    let pad_count = (length - cur_len) as usize;
    let padding: String = std::iter::repeat(pad).take(pad_count).collect();
    let out = if at_start {
        format!("{padding}{s}")
    } else {
        format!("{s}{padding}")
    };
    Ok(Value::String(Arc::new(out)))
}

fn string_pad_start(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    string_pad(ctx, true, "padStart")
}

fn string_pad_end(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    string_pad(ctx, false, "padEnd")
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

/// `String.regionMatches(thisOffset, other, otherOffset, length,
/// ignoreCase = false)` — true when the `length`-char regions match.
/// Out-of-range offsets/lengths yield `false` (Kotlin semantics).
fn string_region_matches(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.regionMatches")?;
    let this_off = ctx
        .args
        .get(1)
        .and_then(Value::as_i64)
        .ok_or_else(|| RuntimeError::Type("regionMatches: thisOffset".into()))?;
    let other = arg_as_string(
        ctx.args
            .get(2)
            .ok_or_else(|| RuntimeError::Arity("regionMatches: other".into()))?,
        "regionMatches",
    )?;
    let other_off = ctx
        .args
        .get(3)
        .and_then(Value::as_i64)
        .ok_or_else(|| RuntimeError::Type("regionMatches: otherOffset".into()))?;
    let length = ctx
        .args
        .get(4)
        .and_then(Value::as_i64)
        .ok_or_else(|| RuntimeError::Type("regionMatches: length".into()))?;
    let ignore_case = matches!(ctx.args.get(5), Some(Value::Bool(true)));
    let sc: Vec<char> = s.chars().collect();
    let oc: Vec<char> = other.chars().collect();
    if length < 0
        || this_off < 0
        || other_off < 0
        || this_off + length > sc.len() as i64
        || other_off + length > oc.len() as i64
    {
        return Ok(Value::Bool(false));
    }
    for i in 0..length as usize {
        let a = sc[this_off as usize + i];
        let b = oc[other_off as usize + i];
        let eq = if ignore_case {
            a.eq_ignore_ascii_case(&b)
                || a.to_lowercase().eq(b.to_lowercase())
        } else {
            a == b
        };
        if !eq {
            return Ok(Value::Bool(false));
        }
    }
    Ok(Value::Bool(true))
}

/// `internal inline fun String.skipWhile(startIndex, predicate)` —
/// kotlin.text helper used by Duration's parser. Returns the first
/// index >= startIndex whose char fails `predicate` (or `length`).
fn string_skip_while(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.skipWhile")?;
    let start = ctx
        .args
        .get(1)
        .and_then(Value::as_i64)
        .ok_or_else(|| RuntimeError::Type("skipWhile: startIndex".into()))?;
    let block = ctx
        .args
        .get(2)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("skipWhile: predicate".into()))?;
    let chars: Vec<char> = s.chars().collect();
    let CallCtx { out, host, .. } = ctx;
    let mut i = if start < 0 { 0i64 } else { start };
    while (i as usize) < chars.len() {
        let c = Value::Char(chars[i as usize]);
        let keep = host.invoke_callable(&block, std::slice::from_ref(&c), *out)?;
        if !matches!(keep, Value::Bool(true)) {
            break;
        }
        i += 1;
    }
    Ok(Value::new_int(i))
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

fn string_filter(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.filter")?.clone();
    if ctx.args.len() < 2 {
        return Err(RuntimeError::Arity("filter requires a block".into()));
    }
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut result = String::new();
    for ch in s.chars() {
        let v = Value::Char(ch);
        if matches!(host.invoke_callable(&block, std::slice::from_ref(&v), *out)?, Value::Bool(true)) {
            result.push(ch);
        }
    }
    Ok(Value::String(Arc::new(result)))
}

fn string_count(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.count")?.clone();
    if ctx.args.len() == 1 {
        return Ok(Value::new_int(s.chars().count() as i64));
    }
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut n: i64 = 0;
    for ch in s.chars() {
        let v = Value::Char(ch);
        if matches!(host.invoke_callable(&block, std::slice::from_ref(&v), *out)?, Value::Bool(true)) {
            n += 1;
        }
    }
    Ok(Value::new_int(n))
}

fn string_map(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.map")?.clone();
    if ctx.args.len() < 2 {
        return Err(RuntimeError::Arity("map requires a block".into()));
    }
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut result: Vec<Value> = Vec::with_capacity(s.chars().count());
    for ch in s.chars() {
        let v = Value::Char(ch);
        let r = host.invoke_callable(&block, std::slice::from_ref(&v), *out)?;
        result.push(r);
    }
    Ok(make_list(result, false))
}

fn string_any(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.any")?.clone();
    if ctx.args.len() == 1 {
        return Ok(Value::Bool(!s.is_empty()));
    }
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    for ch in s.chars() {
        let v = Value::Char(ch);
        if matches!(host.invoke_callable(&block, std::slice::from_ref(&v), *out)?, Value::Bool(true)) {
            return Ok(Value::Bool(true));
        }
    }
    Ok(Value::Bool(false))
}

fn string_all(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.all")?.clone();
    let block = ctx.args.get(1).cloned();
    let Some(block) = block else {
        return Err(RuntimeError::Arity("all requires a block".into()));
    };
    let CallCtx { out, host, .. } = ctx;
    for ch in s.chars() {
        let v = Value::Char(ch);
        if !matches!(host.invoke_callable(&block, std::slice::from_ref(&v), *out)?, Value::Bool(true)) {
            return Ok(Value::Bool(false));
        }
    }
    Ok(Value::Bool(true))
}

fn string_none(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let r = string_any(ctx)?;
    Ok(Value::Bool(matches!(r, Value::Bool(false))))
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
        let (r, s) = (Arc::clone(r), Arc::clone(s));
        let repl = ctx.args.get(2).cloned();
        return perform_regex_replace(ctx, &r, &s, repl, false, "replace");
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
    Ok(Value::String(Arc::new(s.replace(&old, &new))))
}

/// trim / trimStart / trimEnd, honoring the optional argument: a vararg Char
/// set, a `(Char)->Boolean` predicate, or nothing (whitespace).
fn string_trim_generic(
    ctx: &mut CallCtx,
    trim_start: bool,
    trim_end: bool,
    who: &str,
) -> Result<Value, RuntimeError> {
    let cs: Vec<char> = recv_string(ctx.args, who)?.chars().collect();
    let extra: Vec<Value> = ctx.args[1..].to_vec();
    // `keep[i]` = char i is NOT trimmable.
    let keep: Vec<bool> = if extra.is_empty() {
        cs.iter().map(|c| !c.is_whitespace()).collect()
    } else if extra.iter().all(|v| matches!(v, Value::Char(_))) {
        let set: Vec<char> = extra
            .iter()
            .map(|v| match v {
                Value::Char(c) => *c,
                _ => unreachable!(),
            })
            .collect();
        cs.iter().map(|c| !set.contains(c)).collect()
    } else {
        let block = extra[0].clone();
        let CallCtx { out, host, .. } = ctx;
        let mut keep = Vec::with_capacity(cs.len());
        for c in &cs {
            let trimmable = matches!(
                host.invoke_callable(&block, &[Value::Char(*c)], *out)?,
                Value::Bool(true)
            );
            keep.push(!trimmable);
        }
        keep
    };
    let lo = if trim_start {
        keep.iter().position(|&k| k).unwrap_or(cs.len())
    } else {
        0
    };
    let hi = if trim_end {
        keep.iter().rposition(|&k| k).map(|p| p + 1).unwrap_or(0)
    } else {
        cs.len()
    };
    let hi = hi.max(lo);
    Ok(Value::String(Arc::new(cs[lo..hi].iter().collect::<String>())))
}
fn string_trim(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    string_trim_generic(ctx, true, true, "String.trim")
}
fn string_trim_start(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    string_trim_generic(ctx, true, false, "String.trimStart")
}
fn string_trim_end(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    string_trim_generic(ctx, false, true, "String.trimEnd")
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
    Ok(Value::String(Arc::new(s.repeat(*n as usize))))
}

fn string_reversed(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.reversed")?;
    Ok(Value::String(Arc::new(s.chars().rev().collect())))
}

#[allow(clippy::type_complexity)]
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
    parse_int_radix(&s, radix as u32)
        .ok()
        .filter(|v| (i32::MIN as i64..=i32::MAX as i64).contains(v))
        .map(Value::new_int)
        .ok_or_else(|| {
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
    // Bounds-check against the Int range: a value that fits i64 but overflows
    // i32 must return null, not a truncated Int.
    Ok(parse_int_radix(&s, radix as u32)
        .ok()
        .filter(|v| (i32::MIN as i64..=i32::MAX as i64).contains(v))
        .map(Value::new_int)
        .unwrap_or(Value::Null))
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
    Ok(make_list(string_split_items(ctx, "String.split")?, false))
}

/// `splitToSequence(...)` shares `split`'s delimiter handling and
/// yields the same substrings as a `Sequence<String>`. klio collects
/// eagerly and wraps the result (faithful for finite inputs, which is
/// every `String`).
fn string_split_to_sequence(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(make_sequence(string_split_items(ctx, "String.splitToSequence")?))
}

fn string_split_items(ctx: &mut CallCtx, who: &str) -> Result<Vec<Value>, RuntimeError> {
    let s = recv_string(ctx.args, who)?;
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
        return Ok(parts
            .into_iter()
            .map(|p| Value::String(Arc::new(p.to_string())))
            .collect());
    }
    // `split(vararg delimiters: String/Char, ignoreCase = false, limit = 0)`:
    // collect every String/Char delimiter, plus a trailing Bool (ignoreCase)
    // and Int (limit). Splitting on the FIRST delimiter only, or ignoring the
    // limit, were both bugs.
    let mut delims: Vec<String> = Vec::new();
    let mut ignore_case = false;
    let mut limit = 0i64;
    let mut push_delim = |v: &Value, delims: &mut Vec<String>| -> bool {
        match v {
            Value::String(d) => {
                delims.push((**d).clone());
                true
            }
            Value::Char(c) => {
                delims.push(c.to_string());
                true
            }
            _ => false,
        }
    };
    for a in &ctx.args[1..] {
        match a {
            Value::String(_) | Value::Char(_) => {
                push_delim(a, &mut delims);
            }
            Value::Bool(b) => ignore_case = *b,
            // The vararg `delimiters` may arrive packed into an Array/List
            // (named-argument call form, e.g. `split(",", limit = 2)`).
            Value::Array { items, .. } | Value::List { items, .. } => {
                for it in items.borrow().iter() {
                    if !push_delim(it, &mut delims) {
                        return Err(RuntimeError::Type(
                            "String.split delimiters must be String or Char".into(),
                        ));
                    }
                }
            }
            v if v.is_integral() => limit = v.as_i64().unwrap(),
            // A skipped default parameter (e.g. ignoreCase when only limit is
            // named) arrives as Null — ignore it.
            Value::Null => {}
            _ => {
                return Err(RuntimeError::Type(
                    "String.split requires String, Char, or Regex delimiters".into(),
                ))
            }
        }
    }
    if delims.is_empty() {
        return Err(RuntimeError::Type(
            "String.split requires at least one delimiter".into(),
        ));
    }
    Ok(split_on_any(&s, &delims, ignore_case, limit))
}

/// Split `s` on any of `delims` (left-to-right, non-overlapping), honoring a
/// positive `limit` (max substrings) and ASCII `ignore_case`. An empty
/// delimiter is skipped.
fn split_on_any(s: &str, delims: &[String], ignore_case: bool, limit: i64) -> Vec<Value> {
    let nonempty: Vec<&str> = delims.iter().map(String::as_str).filter(|d| !d.is_empty()).collect();
    if nonempty.is_empty() {
        return vec![Value::String(Arc::new(s.to_string()))];
    }
    let mut out: Vec<Value> = Vec::new();
    let mut seg_start = 0usize;
    let mut i = 0usize;
    while i < s.len() {
        if limit > 0 && out.len() as i64 == limit - 1 {
            break;
        }
        if !s.is_char_boundary(i) {
            i += 1;
            continue;
        }
        let mut matched: Option<usize> = None;
        for d in &nonempty {
            let end = i + d.len();
            if end <= s.len() && s.is_char_boundary(end) {
                let cand = &s[i..end];
                let eq = if ignore_case {
                    cand.eq_ignore_ascii_case(d)
                } else {
                    cand == *d
                };
                if eq {
                    matched = Some(d.len());
                    break;
                }
            }
        }
        if let Some(dlen) = matched {
            out.push(Value::String(Arc::new(s[seg_start..i].to_string())));
            i += dlen;
            seg_start = i;
        } else {
            i += 1;
        }
    }
    out.push(Value::String(Arc::new(s[seg_start..].to_string())));
    out
}

fn string_chunked(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.chunked")?;
    let Some(Value::Int(size)) = ctx.args.get(1) else {
        return Err(RuntimeError::Type("chunked requires an Int size".into()));
    };
    if *size <= 0 {
        return Err(RuntimeError::Thrown(Value::Exception {
            fqn: Arc::new("kotlin.IllegalArgumentException".into()),
            message: Some(Arc::new(format!("Size {size} must be greater than zero."))),
            cause: None,
        }));
    }
    let size = *size as usize;
    let transform = match ctx.args.get(2) {
        Some(Value::Null) | None => None,
        Some(v) => Some(v.clone()),
    };
    let chars: Vec<char> = s.chars().collect();
    let mut pieces: Vec<String> = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        let end = (i + size).min(chars.len());
        pieces.push(chars[i..end].iter().collect());
        i += size;
    }
    let mut out: Vec<Value> = Vec::with_capacity(pieces.len());
    match transform {
        None => {
            for p in pieces {
                out.push(Value::String(Arc::new(p)));
            }
        }
        Some(block) => {
            let CallCtx { out: sink, host, .. } = ctx;
            for p in pieces {
                let arg = Value::String(Arc::new(p));
                let r = host.invoke_callable(&block, std::slice::from_ref(&arg), *sink)?;
                out.push(r);
            }
        }
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
            fqn: Arc::new("kotlin.IllegalArgumentException".into()),
            message: Some(Arc::new(format!("size {size} must be greater than zero."))),
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
            fqn: Arc::new("kotlin.IllegalArgumentException".into()),
            message: Some(Arc::new(format!("step {step} must be greater than zero."))),
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
            out.push(Value::String(Arc::new(win)));
        } else if partial {
            let win: String = chars[i..].iter().collect();
            out.push(Value::String(Arc::new(win)));
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

fn internal_get_progression_last_element(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let args = ctx.args;
    if args.len() != 3 {
        return Err(RuntimeError::Type(
            "getProgressionLastElement expects (start, end, step)".into(),
        ));
    }
    fn imod(a: i64, b: i64) -> i64 {
        let m = a.rem_euclid(b);
        if m >= 0 { m } else { m + b }
    }
    let (start, end, step, is_long) = match (&args[0], &args[1], &args[2]) {
        (Value::Long(s), Value::Long(e), Value::Long(p)) => (*s, *e, *p, true),
        (Value::Int(s), Value::Int(e), Value::Int(p)) => {
            (i64::from(*s), i64::from(*e), i64::from(*p), false)
        }
        _ => {
            return Err(RuntimeError::Type(
                "getProgressionLastElement: args must be all Int or all Long".into(),
            ));
        }
    };
    let last = if step > 0 {
        if start >= end {
            end
        } else {
            let diff = imod(imod(end, step) - imod(start, step), step);
            end - diff
        }
    } else if step < 0 {
        if start <= end {
            end
        } else {
            let neg = -step;
            let diff = imod(imod(start, neg) - imod(end, neg), neg);
            end + diff
        }
    } else {
        return Err(RuntimeError::Type("Step is zero.".into()));
    };
    if is_long {
        Ok(Value::Long(last))
    } else {
        Ok(Value::new_int(last as i32))
    }
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
    Ok(Value::String(Arc::new(up.next().map_or(String::new(), |x| {
        let rest: String = up.collect();
        format!("{x}{rest}")
    }))))
}
fn char_lowercase(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let c = recv_char(ctx.args, "Char.lowercase")?;
    let mut lo = c.to_lowercase();
    Ok(Value::String(Arc::new(lo.next().map_or(String::new(), |x| {
        let rest: String = lo.collect();
        format!("{x}{rest}")
    }))))
}
fn char_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::String(Arc::new(recv_char(ctx.args, "Char.toString")?.to_string())))
}
/// The radix argument of `digitToInt(radix)` / `digitToIntOrNull(radix)`,
/// validated to Kotlin's 2..36 range (default 10). Returns the radix or an
/// IllegalArgumentException.
fn char_digit_radix(args: &[Value]) -> Result<u32, RuntimeError> {
    let radix = args.get(1).and_then(Value::as_i64).unwrap_or(10);
    if !(2..=36).contains(&radix) {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IllegalArgumentException",
            Some(format!("radix {radix} is not in valid range 2..36")),
        )));
    }
    Ok(radix as u32)
}

fn char_digit_to_int(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let c = recv_char(ctx.args, "Char.digitToInt")?;
    let radix = char_digit_radix(ctx.args)?;
    match c.to_digit(radix) {
        Some(d) => Ok(Value::new_int(d)),
        None => Err(RuntimeError::Thrown(make_exception(
            "kotlin.IllegalArgumentException",
            Some(format!("Char {c:?} is not a digit in the given radix={radix}")),
        ))),
    }
}

/// klio's `Value::Char` is a Rust `char`, which cannot hold a lone UTF-16
/// surrogate, so a surrogate-ness test is always false for any representable
/// char. (Used by e.g. commonPrefixWith.)
fn char_false(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Bool(false))
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
    Ok(Value::String(Arc::new(int_to_radix_string(n, radix as u32))))
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
    Ok(Value::String(std::sync::Arc::new(v.to_string())))
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
    Ok(Value::String(Arc::new(klio_runtime::kotlin_float_to_string(d))))
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
    // `compareTo` is a total order (NaN greatest, -0.0 < 0.0), unlike the
    // IEEE `<`/`>` operators.
    Ok(Value::new_int(kotlin_float_total_cmp(a as f64, b as f64) as i64))
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
    Ok(Value::String(Arc::new(int_to_radix_string(n, radix as u32))))
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
    Ok(Value::String(Arc::new(klio_runtime::kotlin_double_to_string(d))))
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
    // `compareTo` is a total order (NaN greatest, -0.0 < 0.0), unlike the
    // IEEE `<`/`>` operators.
    Ok(Value::Int(kotlin_float_total_cmp(a, b) as i32))
}

// ============================================================
// Boolean members
// ============================================================

fn bool_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(Value::Bool(b)) = ctx.args.first() else {
        return Err(RuntimeError::Type("Boolean.toString requires a Boolean".into()));
    };
    Ok(Value::String(Arc::new(b.to_string())))
}

// ============================================================
// Exceptions
// ============================================================

fn make_exception(fqn: &str, message: Option<String>) -> Value {
    Value::Exception {
        fqn: Arc::new(fqn.to_string()),
        message: message.map(Arc::new),
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
                // A builtin exception is `Value::Exception`; a user /
                // pack exception subclass is a `Value::Instance` of a
                // Throwable-derived class. Both are valid causes.
                Value::Exception { .. } | Value::Instance(_) => {
                    Some(Box::new(c.clone()))
                }
                _ => return Err(RuntimeError::Type(
                    "Throwable cause must be a Throwable or null".into(),
                )),
            };
            (msg, cause)
        }
    };
    Ok(Value::Exception {
        fqn: Arc::new(fqn.to_string()),
        message: message.map(Arc::new),
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
fn excn_no_when(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    build_exception(ctx, "kotlin.NoWhenBranchMatchedException")
}
fn excn_number_format(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    build_exception(ctx, "kotlin.NumberFormatException")
}
fn excn_concurrent_mod(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    build_exception(ctx, "kotlin.ConcurrentModificationException")
}
fn excn_assertion_error(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    build_exception(ctx, "kotlin.AssertionError")
}

fn throwable_message(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(Value::Exception { message, .. }) = ctx.args.first() else {
        return Err(RuntimeError::Type("message requires a Throwable receiver".into()));
    };
    Ok(message
        .as_ref()
        .map_or(Value::Null, |m| Value::String(Arc::clone(m))))
}

fn throwable_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(v @ Value::Exception { .. }) = ctx.args.first() else {
        return Err(RuntimeError::Type("toString requires a Throwable receiver".into()));
    };
    Ok(Value::String(Arc::new(format!("{v}"))))
}

/// `Throwable.addSuppressed(other)` — klio is single-threaded and
/// does not surface suppressed-exception chains in diagnostics, so
/// this records nothing. Accepts any throwable-shaped receiver.
fn throwable_add_suppressed(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Unit)
}

/// `Throwable.suppressedExceptions` / `getSuppressed()` — always
/// empty (see [`throwable_add_suppressed`]).
fn throwable_suppressed(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(make_list(Vec::new(), false))
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

fn make_list(items: Vec<Value>, mutable: bool) -> Value {
    Value::List { items: ObjRef::new(items), mutable, enum_class: None, backing: None }
}

fn make_set(items: Vec<Value>, mutable: bool) -> Value {
    let mut deduped: Vec<Value> = Vec::with_capacity(items.len());
    for v in items {
        if !deduped.iter().any(|x| Value::structural_eq_boxed(x, &v)) {
            deduped.push(v);
        }
    }
    Value::Set { items: ObjRef::new(deduped), mutable, backing: None }
}

fn make_map(entries: Vec<(Value, Value)>, mutable: bool) -> Value {
    // Deduplicate keys, last write wins (matches `mapOf("a" to 1, "a" to 2)`).
    let mut out: Vec<(Value, Value)> = Vec::with_capacity(entries.len());
    for (k, v) in entries {
        if let Some(slot) = out.iter_mut().find(|(kk, _)| Value::structural_eq_boxed(kk, &k)) {
            slot.1 = v;
        } else {
            out.push((k, v));
        }
    }
    Value::Map { entries: ObjRef::new(out), mutable }
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
fn coll_list_of_not_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let items: Vec<Value> = ctx
        .args
        .iter()
        .filter(|v| !matches!(v, Value::Null))
        .cloned()
        .collect();
    Ok(make_list(items, false))
}
fn coll_array_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Array {
        items: ObjRef::new(ctx.args.to_vec()),
        prim: None,
    })
}
fn coll_array_of_nulls(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    // Two shapes resolve to this intrinsic:
    //   public  fun <reified T> arrayOfNulls(size: Int): Array<T?>
    //   internal fun <T> arrayOfNulls(reference: Array<T>, size: Int): Array<T>
    // The 2-arg internal form (used by toTypedArray / ArrayDeque) passes
    // an existing array as the reified-type carrier; only the trailing
    // `size` matters here, so build `size` nulls regardless of shape.
    if ctx.args.len() == 2 && matches!(ctx.args.first(), Some(Value::Array { .. })) {
        let n = array_size_arg(&ctx.args[1], "arrayOfNulls")?;
        let items: Vec<Value> = (0..n).map(|_| Value::Null).collect();
        return Ok(Value::Array { items: ObjRef::new(items), prim: None });
    }
    array_ctor_impl(ctx, "arrayOfNulls", None, Value::Null)
}
fn coll_empty_array(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Array { items: ObjRef::new(Vec::new()), prim: None })
}
fn coll_int_array_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Array {
        items: ObjRef::new(ctx.args.to_vec()),
        prim: Some(klio_runtime::PrimitiveArrayKind::Int),
    })
}
fn coll_long_array_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Array {
        items: ObjRef::new(ctx.args.to_vec()),
        prim: Some(klio_runtime::PrimitiveArrayKind::Long),
    })
}
fn coll_short_array_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Array {
        items: ObjRef::new(ctx.args.to_vec()),
        prim: Some(klio_runtime::PrimitiveArrayKind::Short),
    })
}
fn coll_byte_array_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Array {
        items: ObjRef::new(ctx.args.to_vec()),
        prim: Some(klio_runtime::PrimitiveArrayKind::Byte),
    })
}
fn coll_double_array_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Array {
        items: ObjRef::new(ctx.args.to_vec()),
        prim: Some(klio_runtime::PrimitiveArrayKind::Double),
    })
}
fn coll_float_array_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Array {
        items: ObjRef::new(ctx.args.to_vec()),
        prim: Some(klio_runtime::PrimitiveArrayKind::Float),
    })
}
fn coll_bool_array_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Array {
        items: ObjRef::new(ctx.args.to_vec()),
        prim: Some(klio_runtime::PrimitiveArrayKind::Boolean),
    })
}
fn coll_char_array_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Array {
        items: ObjRef::new(ctx.args.to_vec()),
        prim: Some(klio_runtime::PrimitiveArrayKind::Char),
    })
}
fn coll_uint_array_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Array {
        items: ObjRef::new(ctx.args.to_vec()),
        prim: Some(klio_runtime::PrimitiveArrayKind::UInt),
    })
}
fn coll_ulong_array_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Array {
        items: ObjRef::new(ctx.args.to_vec()),
        prim: Some(klio_runtime::PrimitiveArrayKind::ULong),
    })
}
fn coll_ushort_array_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Array {
        items: ObjRef::new(ctx.args.to_vec()),
        prim: Some(klio_runtime::PrimitiveArrayKind::UShort),
    })
}
fn coll_ubyte_array_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Array {
        items: ObjRef::new(ctx.args.to_vec()),
        prim: Some(klio_runtime::PrimitiveArrayKind::UByte),
    })
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

fn coll_to_typed_array(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let items = iterable_items(
        ctx.args
            .first()
            .ok_or_else(|| RuntimeError::Type("toTypedArray requires a receiver".into()))?,
        "toTypedArray",
    )?;
    Ok(Value::Array { items: ObjRef::new(items), prim: None })
}

fn coll_set_of_not_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let items: Vec<Value> = ctx
        .args
        .iter()
        .filter(|v| !matches!(v, Value::Null))
        .cloned()
        .collect();
    Ok(make_set(items, false))
}

/// `sortedSetOf(vararg elements)` — a (mutable) set with keys in natural order.
fn coll_sorted_set_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let mut items = ctx.args.to_vec();
    let mut err: Option<RuntimeError> = None;
    items.sort_by(|a, b| match compare_values(a, b) {
        Ok(o) => o,
        Err(e) => {
            err = Some(e);
            std::cmp::Ordering::Equal
        }
    });
    if let Some(e) = err {
        return Err(e);
    }
    Ok(make_set(items, true))
}

/// `sortedMapOf(vararg pairs)` — a (mutable) map with entries in natural key order.
fn coll_sorted_map_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let mut entries: Vec<(Value, Value)> = Vec::with_capacity(ctx.args.len());
    for v in ctx.args {
        let Value::Pair(k, val) = v else {
            return Err(RuntimeError::Type("sortedMapOf expects Pair arguments".into()));
        };
        entries.push(((**k).clone(), (**val).clone()));
    }
    let mut err: Option<RuntimeError> = None;
    entries.sort_by(|a, b| match compare_values(&a.0, &b.0) {
        Ok(o) => o,
        Err(e) => {
            err = Some(e);
            std::cmp::Ordering::Equal
        }
    });
    if let Some(e) = err {
        return Err(e);
    }
    Ok(make_map(entries, true))
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

fn recv_list_items<'a>(args: &'a [Value], what: &str) -> Result<ObjRef<Vec<Value>>, RuntimeError> {
    match args.first() {
        Some(Value::List { items, .. }) => Ok(items.clone()),
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
            fqn: Arc::new("kotlin.IndexOutOfBoundsException".into()),
            message: Some(Arc::new(format!(
                "Index {i} out of bounds for length {}",
                borrow.len()
            ))),
            cause: None,
        }));
    }
    Ok(borrow[i as usize].clone())
}
fn coll_list_contains(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.contains")?;
    let Some(needle) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("contains requires an argument".into()));
    };
    Ok(Value::Bool(it.borrow().iter().any(|v| Value::structural_eq_boxed(v, needle))))
}
fn coll_list_index_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.indexOf")?;
    let Some(needle) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("indexOf requires an argument".into()));
    };
    let pos = it.borrow().iter().position(|v| Value::structural_eq_boxed(v, needle));
    Ok(Value::new_int(pos.map(|p| p as i64).unwrap_or(-1)))
}
fn coll_iter_index_of_first(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let items = iterable_items(&ctx.args[0], "indexOfFirst")?;
    let block = ctx.args.get(1).cloned().ok_or_else(|| {
        RuntimeError::Arity("indexOfFirst requires a block".into())
    })?;
    let CallCtx { out, host, .. } = ctx;
    for (i, v) in items.iter().enumerate() {
        if matches!(host.invoke_callable(&block, std::slice::from_ref(v), *out)?, Value::Bool(true)) {
            return Ok(Value::new_int(i as i64));
        }
    }
    Ok(Value::new_int(-1))
}
fn coll_iter_index_of_last(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let items = iterable_items(&ctx.args[0], "indexOfLast")?;
    let block = ctx.args.get(1).cloned().ok_or_else(|| {
        RuntimeError::Arity("indexOfLast requires a block".into())
    })?;
    let CallCtx { out, host, .. } = ctx;
    let mut found: i64 = -1;
    for (i, v) in items.iter().enumerate() {
        if matches!(host.invoke_callable(&block, std::slice::from_ref(v), *out)?, Value::Bool(true)) {
            found = i as i64;
        }
    }
    Ok(Value::new_int(found))
}
/// `foldRight(initial) { elem, acc -> … }` — fold from the end. Upstream uses
/// a backward ListIterator (hasPrevious) klio doesn't model, so iterate in
/// reverse directly.
fn coll_list_fold_right(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let items = iterable_items(&ctx.args[0], "foldRight")?;
    let mut acc = ctx
        .args
        .get(1)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("foldRight requires an initial value".into()))?;
    let block = ctx
        .args
        .get(2)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("foldRight requires a block".into()))?;
    let CallCtx { out, host, .. } = ctx;
    for v in items.iter().rev() {
        acc = host.invoke_callable(&block, &[v.clone(), acc.clone()], *out)?;
    }
    Ok(acc)
}

/// `reduceRight { elem, acc -> … }` — reduce from the end; throws on empty.
/// `or_null` true for reduceRightOrNull (returns null on empty).
fn reduce_right_impl(ctx: &mut CallCtx, or_null: bool) -> Result<Value, RuntimeError> {
    let items = iterable_items(&ctx.args[0], "reduceRight")?;
    let block = ctx
        .args
        .get(1)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("reduceRight requires a block".into()))?;
    if items.is_empty() {
        return if or_null {
            Ok(Value::Null)
        } else {
            Err(RuntimeError::Thrown(make_exception(
                "kotlin.UnsupportedOperationException",
                Some("Empty collection can't be reduced.".into()),
            )))
        };
    }
    let CallCtx { out, host, .. } = ctx;
    let mut acc = items[items.len() - 1].clone();
    for i in (0..items.len() - 1).rev() {
        acc = host.invoke_callable(&block, &[items[i].clone(), acc.clone()], *out)?;
    }
    Ok(acc)
}

fn coll_list_reduce_right(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    reduce_right_impl(ctx, false)
}

fn coll_list_reduce_right_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    reduce_right_impl(ctx, true)
}

/// `last()` / `last { predicate }` / `lastOrNull { predicate }` /
/// `findLast { predicate }`. With no block, returns the last element (throwing
/// on empty for `last`). With a block, scans in reverse for the last match.
/// `or_null` controls the empty/no-match behavior.
fn coll_list_last_impl(ctx: &mut CallCtx, or_null: bool) -> Result<Value, RuntimeError> {
    let items = iterable_items(&ctx.args[0], "last")?;
    if ctx.args.len() >= 2 {
        let block = ctx.args[1].clone();
        let CallCtx { out, host, .. } = ctx;
        for v in items.iter().rev() {
            if matches!(
                host.invoke_callable(&block, std::slice::from_ref(v), *out)?,
                Value::Bool(true)
            ) {
                return Ok(v.clone());
            }
        }
        return if or_null {
            Ok(Value::Null)
        } else {
            Err(RuntimeError::Thrown(make_exception(
                "kotlin.NoSuchElementException",
                Some("Collection contains no element matching the predicate.".into()),
            )))
        };
    }
    match items.last() {
        Some(v) => Ok(v.clone()),
        None if or_null => Ok(Value::Null),
        None => Err(RuntimeError::Thrown(make_exception(
            "kotlin.NoSuchElementException",
            Some("Collection is empty.".into()),
        ))),
    }
}

fn coll_list_last(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    coll_list_last_impl(ctx, false)
}

fn coll_list_last_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    coll_list_last_impl(ctx, true)
}

fn coll_list_last_index_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.lastIndexOf")?;
    let Some(needle) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("lastIndexOf requires an argument".into()));
    };
    let borrow = it.borrow();
    let pos = borrow.iter().rposition(|v| Value::structural_eq_boxed(v, needle));
    Ok(Value::new_int(pos.map(|p| p as i64).unwrap_or(-1)))
}
fn coll_list_join_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let items: Vec<Value> = match ctx.args.first() {
        Some(v) => iterable_items(v, "joinToString")?,
        None => return Err(RuntimeError::Arity(
            "joinToString expects an iterable receiver".into(),
        )),
    };
    // Detect a trailing callable: a lambda/closure appearing as
    // the last positional arg slots into `transform`, leaving the
    // earlier args as separator/prefix/postfix/limit/truncated.
    let mut effective: Vec<Value> = ctx.args[1..].to_vec();
    let mut transform_slot: Option<Value> = None;
    if let Some(last) = effective.last() {
        let is_bound_ref = if let Value::Instance(inst) = last {
            inst.borrow().class.name.starts_with("$bound_ref$")
        } else {
            false
        };
        if matches!(last, Value::IrClosure { .. } | Value::Lambda { .. } | Value::BoundMethod { .. })
            || is_bound_ref
        {
            transform_slot = effective.pop();
        }
    }
    fn opt_str<'a>(args: &'a [Value], idx: usize, default: &'a str) -> String {
        match args.get(idx) {
            None | Some(Value::Null) => default.to_string(),
            Some(Value::String(s)) => (**s).clone(),
            Some(other) => format!("{other}"),
        }
    }
    let sep = opt_str(&effective, 0, ", ");
    let prefix = opt_str(&effective, 1, "");
    let postfix = opt_str(&effective, 2, "");
    let limit: i64 = match effective.get(3) {
        None | Some(Value::Null) => -1,
        Some(v) => v.as_i64().unwrap_or(-1),
    };
    let truncated = opt_str(&effective, 4, "...");
    let n = items.len();
    let take = if limit < 0 { n } else { (limit as usize).min(n) };
    let mut out = String::new();
    out.push_str(&prefix);
    let CallCtx { out: writer, host, .. } = ctx;
    for (i, v) in items.iter().enumerate().take(take) {
        if i > 0 {
            out.push_str(&sep);
        }
        let piece = if let Some(t) = &transform_slot {
            let r = host.invoke_callable(t, std::slice::from_ref(v), *writer)?;
            match r {
                Value::String(s) => (*s).clone(),
                other => format!("{other}"),
            }
        } else if matches!(v, Value::Instance(_)) {
            // Honour a user-declared `override fun toString()` on an
            // Instance receiver — the structural Display path would
            // otherwise print `ClassName@<id>`.
            match host.invoke_method(v, "toString", &[], *writer) {
                Some(Ok(Value::String(s))) => (*s).clone(),
                _ => format!("{v}"),
            }
        } else {
            format!("{v}")
        };
        out.push_str(&piece);
    }
    if limit >= 0 && n > take {
        if take > 0 {
            out.push_str(&sep);
        }
        out.push_str(&truncated);
    }
    out.push_str(&postfix);
    Ok(Value::String(Arc::new(out)))
}
fn coll_array_join_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    // Reuses the List join logic on the array's items vector. An
    // array argument carries its items in the same `RefCell<Vec<Value>>`
    // as a List, so the implementation works untouched once we route
    // the receiver through `iterable_items`.
    let recv = ctx.args.first().ok_or_else(|| {
        RuntimeError::Type("Array.joinToString requires a receiver".into())
    })?;
    let items = iterable_items(recv, "Array.joinToString")?;
    let mut effective: Vec<Value> = ctx.args[1..].to_vec();
    let mut transform_slot: Option<Value> = None;
    if let Some(last) = effective.last() {
        let is_bound_ref = if let Value::Instance(inst) = last {
            inst.borrow().class.name.starts_with("$bound_ref$")
        } else {
            false
        };
        if matches!(last, Value::IrClosure { .. } | Value::Lambda { .. } | Value::BoundMethod { .. })
            || is_bound_ref
        {
            transform_slot = effective.pop();
        }
    }
    fn opt_str<'a>(args: &'a [Value], idx: usize, default: &'a str) -> String {
        match args.get(idx) {
            None | Some(Value::Null) => default.to_string(),
            Some(Value::String(s)) => (**s).clone(),
            Some(other) => format!("{other}"),
        }
    }
    let sep = opt_str(&effective, 0, ", ");
    let prefix = opt_str(&effective, 1, "");
    let postfix = opt_str(&effective, 2, "");
    let limit: i64 = match effective.get(3) {
        None | Some(Value::Null) => -1,
        Some(v) => v.as_i64().unwrap_or(-1),
    };
    let truncated = opt_str(&effective, 4, "...");
    let n = items.len();
    let take = if limit < 0 { n } else { (limit as usize).min(n) };
    let mut out = String::new();
    out.push_str(&prefix);
    let CallCtx { out: writer, host, .. } = ctx;
    for (i, v) in items.iter().enumerate().take(take) {
        if i > 0 {
            out.push_str(&sep);
        }
        let piece = if let Some(t) = &transform_slot {
            let r = host.invoke_callable(t, std::slice::from_ref(v), *writer)?;
            match r {
                Value::String(s) => (*s).clone(),
                other => format!("{other}"),
            }
        } else {
            format!("{v}")
        };
        out.push_str(&piece);
    }
    if limit >= 0 && n > take {
        if take > 0 {
            out.push_str(&sep);
        }
        out.push_str(&truncated);
    }
    out.push_str(&postfix);
    Ok(Value::String(Arc::new(out)))
}

fn coll_list_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = ctx.args.first().ok_or_else(|| RuntimeError::Type("List.toString requires a receiver".into()))?;
    Ok(Value::String(Arc::new(format!("{v}"))))
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
                fqn: Arc::new("kotlin.IndexOutOfBoundsException".into()),
                message: Some(Arc::new(format!(
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
fn coll_mut_list_add_first(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "MutableList.addFirst")?;
    let Some(v) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("addFirst requires an argument".into()));
    };
    it.borrow_mut().insert(0, v.clone());
    Ok(Value::Unit)
}

fn coll_mut_list_remove_first(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "MutableList.removeFirst")?;
    let mut b = it.borrow_mut();
    if b.is_empty() {
        return Err(RuntimeError::Thrown(Value::Exception {
            fqn: Arc::new("kotlin.NoSuchElementException".into()),
            message: Some(Arc::new("ArrayDeque is empty.".into())),
            cause: None,
        }));
    }
    Ok(b.remove(0))
}

fn coll_mut_list_remove_last(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "MutableList.removeLast")?;
    let mut b = it.borrow_mut();
    b.pop().ok_or_else(|| RuntimeError::Thrown(Value::Exception {
        fqn: Arc::new("kotlin.NoSuchElementException".into()),
        message: Some(Arc::new("ArrayDeque is empty.".into())),
        cause: None,
    }))
}

fn coll_mut_list_remove_at(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "MutableList.removeAt")?;
    let Some(Value::Int(i)) = ctx.args.get(1) else {
        return Err(RuntimeError::Type("removeAt requires an Int index".into()));
    };
    let mut borrow = it.borrow_mut();
    if *i < 0 || (*i as usize) >= borrow.len() {
        return Err(RuntimeError::Thrown(Value::Exception {
            fqn: Arc::new("kotlin.IndexOutOfBoundsException".into()),
            message: Some(Arc::new(format!(
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
    sync_map_view(&ctx.args[0]);
    Ok(Value::Unit)
}

/// Natural order for the Kotlin types we currently support as `Comparable`.
/// Returns an `Ordering`, or an error when the types can't be compared.
pub fn primitive_companion_const(ty: &str, name: &str) -> Option<Value> {
    match (ty, name) {
        ("Int", "MAX_VALUE") => Some(Value::new_int(i32::MAX as i64)),
        ("Int", "MIN_VALUE") => Some(Value::new_int(i32::MIN as i64)),
        ("Int", "SIZE_BITS") => Some(Value::new_int(32)),
        ("Int", "SIZE_BYTES") => Some(Value::new_int(4)),
        ("Long", "MAX_VALUE") => Some(Value::Long(i64::MAX)),
        ("Long", "MIN_VALUE") => Some(Value::Long(i64::MIN)),
        ("Long", "SIZE_BITS") => Some(Value::new_int(64)),
        ("Long", "SIZE_BYTES") => Some(Value::new_int(8)),
        ("Short", "MAX_VALUE") => Some(Value::Short(i16::MAX)),
        ("Short", "MIN_VALUE") => Some(Value::Short(i16::MIN)),
        ("Short", "SIZE_BITS") => Some(Value::new_int(16)),
        ("Short", "SIZE_BYTES") => Some(Value::new_int(2)),
        ("Byte", "MAX_VALUE") => Some(Value::Byte(i8::MAX)),
        ("Byte", "MIN_VALUE") => Some(Value::Byte(i8::MIN)),
        ("Byte", "SIZE_BITS") => Some(Value::new_int(8)),
        ("Byte", "SIZE_BYTES") => Some(Value::new_int(1)),
        ("Double", "MAX_VALUE") => Some(Value::Double(f64::MAX)),
        ("Double", "MIN_VALUE") => Some(Value::Double(f64::MIN_POSITIVE)),
        ("Double", "POSITIVE_INFINITY") => Some(Value::Double(f64::INFINITY)),
        ("Double", "NEGATIVE_INFINITY") => Some(Value::Double(f64::NEG_INFINITY)),
        ("Double", "NaN") => Some(Value::Double(f64::NAN)),
        ("Double", "SIZE_BITS") => Some(Value::new_int(64)),
        ("Double", "SIZE_BYTES") => Some(Value::new_int(8)),
        ("Float", "MAX_VALUE") => Some(Value::Float(f32::MAX)),
        ("Float", "MIN_VALUE") => Some(Value::Float(f32::MIN_POSITIVE)),
        ("Float", "POSITIVE_INFINITY") => Some(Value::Float(f32::INFINITY)),
        ("Float", "NEGATIVE_INFINITY") => Some(Value::Float(f32::NEG_INFINITY)),
        ("Float", "NaN") => Some(Value::Float(f32::NAN)),
        ("Float", "SIZE_BITS") => Some(Value::new_int(32)),
        ("Float", "SIZE_BYTES") => Some(Value::new_int(4)),
        ("Char", "MAX_VALUE") => Some(Value::Char('\u{FFFF}')),
        ("Char", "MIN_VALUE") => Some(Value::Char('\u{0}')),
        ("Char", "SIZE_BITS") => Some(Value::new_int(16)),
        ("Char", "SIZE_BYTES") => Some(Value::new_int(2)),
        _ => None,
    }
}

/// Drive a lazy `Value::Sequence` to completion. Each pipeline op
/// invokes its user lambda through the [`IntrinsicHost`] callback
/// surface (not the interpreter's internal call path), so the HOF
/// dispatch lives entirely in the standard library. Sorting ops
/// buffer-then-emit; `SortedWith` dispatches the comparator's
/// `compare` through `invoke_method`.
pub fn materialise_sequence(
    seq_val: &Value,
    host: &mut dyn klio_runtime::IntrinsicHost,
    out: &mut dyn klio_runtime::Output,
) -> Result<Vec<Value>, RuntimeError> {
    materialise_sequence_bounded(seq_val, host, out, None)
}

/// Materialize a Sequence, optionally stopping once `max` items have been
/// produced. The bound makes short-circuiting terminals (`first`, `find`,
/// `any`, `take(n).toList()`) pull only as far as needed instead of running
/// the whole (possibly infinite) source — true Kotlin Sequence laziness.
/// The bound applies on the streaming fast path; ops that must buffer (sort,
/// flatMap, distinct) fall back to full materialization, as in Kotlin.
pub fn materialise_sequence_bounded(
    seq_val: &Value,
    host: &mut dyn klio_runtime::IntrinsicHost,
    out: &mut dyn klio_runtime::Output,
    max: Option<usize>,
) -> Result<Vec<Value>, RuntimeError> {
    use klio_runtime::{SeqOp, SequenceSource};
    let Value::Sequence(seq) = seq_val else {
        return Err(RuntimeError::Type("materialise_sequence: not a Sequence".into()));
    };
    let call = |host: &mut dyn klio_runtime::IntrinsicHost,
                f: &Value,
                args: &[Value],
                out: &mut dyn klio_runtime::Output|
     -> Result<Value, RuntimeError> { host.invoke_callable(f, args, out) };
    // Streaming fast path: when every op is a per-item stage (no
    // sort, no flatmap, no distinct) we can pump source items
    // through the pipeline one at a time so a `take(n)` short-
    // circuits upstream side effects.
    let all_streaming = seq.ops.iter().all(|op| {
        matches!(
            op,
            SeqOp::Map(_)
                | SeqOp::Filter(_)
                | SeqOp::FilterNot(_)
                | SeqOp::Take(_)
                | SeqOp::Drop(_)
                | SeqOp::TakeWhile(_)
                | SeqOp::DropWhile(_)
                | SeqOp::OnEach(_)
                | SeqOp::MapIndexed(_)
                | SeqOp::FilterIndexed(_)
        )
    });
    if all_streaming {
        // Per-op streaming state.
        let n_ops = seq.ops.len();
        let mut taken: Vec<usize> = vec![0; n_ops];
        let mut dropped: Vec<usize> = vec![0; n_ops];
        let mut take_while_live: Vec<bool> = vec![true; n_ops];
        let mut drop_while_live: Vec<bool> = vec![true; n_ops];
        let mut indices: Vec<usize> = vec![0; n_ops];
        let mut output: Vec<Value> = Vec::new();
        let pump = |host: &mut dyn klio_runtime::IntrinsicHost,
                    out: &mut dyn klio_runtime::Output,
                    mut current: Value,
                    seq_ops: &[SeqOp],
                    taken: &mut [usize],
                    dropped: &mut [usize],
                    take_while_live: &mut [bool],
                    drop_while_live: &mut [bool],
                    indices: &mut [usize],
                    output: &mut Vec<Value>|
         -> Result<bool, RuntimeError> {
            for (idx, op) in seq_ops.iter().enumerate() {
                match op {
                    SeqOp::Map(f) => {
                        current = call(host, f, std::slice::from_ref(&current), out)?;
                    }
                    SeqOp::OnEach(f) => {
                        call(host, f, std::slice::from_ref(&current), out)?;
                    }
                    SeqOp::MapIndexed(f) => {
                        let i = indices[idx];
                        indices[idx] += 1;
                        current = call(
                            host,
                            f,
                            &[Value::new_int(i as i64), current.clone()],
                            out,
                        )?;
                    }
                    SeqOp::FilterIndexed(f) => {
                        let i = indices[idx];
                        indices[idx] += 1;
                        if !matches!(
                            call(host, f, &[Value::new_int(i as i64), current.clone()], out)?,
                            Value::Bool(true)
                        ) {
                            return Ok(true);
                        }
                    }
                    SeqOp::Filter(f) => {
                        if !matches!(call(host, f, std::slice::from_ref(&current), out)?, Value::Bool(true)) {
                            return Ok(true);
                        }
                    }
                    SeqOp::FilterNot(f) => {
                        if matches!(call(host, f, std::slice::from_ref(&current), out)?, Value::Bool(true)) {
                            return Ok(true);
                        }
                    }
                    SeqOp::Take(n) => {
                        if taken[idx] >= *n as usize {
                            return Ok(false);
                        }
                        taken[idx] += 1;
                    }
                    SeqOp::Drop(n) => {
                        if dropped[idx] < *n as usize {
                            dropped[idx] += 1;
                            return Ok(true);
                        }
                    }
                    SeqOp::TakeWhile(f) => {
                        if !take_while_live[idx] {
                            return Ok(false);
                        }
                        if !matches!(call(host, f, std::slice::from_ref(&current), out)?, Value::Bool(true)) {
                            take_while_live[idx] = false;
                            return Ok(false);
                        }
                    }
                    SeqOp::DropWhile(f) => {
                        if drop_while_live[idx] {
                            if matches!(call(host, f, std::slice::from_ref(&current), out)?, Value::Bool(true)) {
                                return Ok(true);
                            }
                            drop_while_live[idx] = false;
                        }
                    }
                    _ => unreachable!("filtered above"),
                }
            }
            output.push(current);
            Ok(true)
        };
        // Has any Take stage reached its cap? If so, the pipeline
        // is exhausted and the source must NOT be pulled again — a
        // subsequent `map { side-effect }` would otherwise fire for
        // an item that take(N) has already excluded.
        let take_cap_reached = |taken: &[usize]| -> bool {
            seq.ops.iter().zip(taken.iter()).any(|(op, &t)| {
                matches!(op, SeqOp::Take(n) if t >= *n as usize)
            })
        };
        match &seq.source {
            SequenceSource::Items(v) => {
                for v in v.iter() {
                    if take_cap_reached(&taken) {
                        break;
                    }
                    let cont = pump(
                        host, out, v.clone(), &seq.ops,
                        &mut taken, &mut dropped,
                        &mut take_while_live, &mut drop_while_live,
                        &mut indices, &mut output,
                    )?;
                    if !cont {
                        break;
                    }
                    if let Some(m) = max {
                        if output.len() >= m {
                            break;
                        }
                    }
                }
            }
            SequenceSource::Generate { seed, next } => {
                let mut cur = seed.as_ref().map(|b| (**b).clone());
                let limit = 1_000_000usize;
                let mut produced = 0usize;
                loop {
                    if take_cap_reached(&taken) {
                        break;
                    }
                    let candidate = match &cur {
                        Some(v) => v.clone(),
                        None => {
                            let r = call(host, next, &[], out)?;
                            if matches!(r, Value::Null) {
                                break;
                            }
                            r
                        }
                    };
                    produced += 1;
                    if produced > limit {
                        return Err(RuntimeError::Type(
                            "Sequence: generator exceeded 1,000,000 items".into(),
                        ));
                    }
                    let cont = pump(
                        host, out, candidate.clone(), &seq.ops,
                        &mut taken, &mut dropped,
                        &mut take_while_live, &mut drop_while_live,
                        &mut indices, &mut output,
                    )?;
                    if !cont {
                        break;
                    }
                    if let Some(m) = max {
                        if output.len() >= m {
                            break;
                        }
                    }
                    let r = call(host, next, std::slice::from_ref(&candidate), out)?;
                    if matches!(r, Value::Null) {
                        break;
                    }
                    cur = Some(r);
                }
            }
        }
        return Ok(output);
    }
    let mut items: Vec<Value> = match &seq.source {
        SequenceSource::Items(v) => (**v).clone(),
        SequenceSource::Generate { seed, next } => {
            let mut acc: Vec<Value> = Vec::new();
            let limit = 1024usize;
            let mut cur = seed.as_ref().map(|b| (**b).clone());
            while acc.len() < limit {
                let candidate = match &cur {
                    Some(v) => v.clone(),
                    None => {
                        let r = call(host, next, &[], out)?;
                        if matches!(r, Value::Null) {
                            break;
                        }
                        r
                    }
                };
                acc.push(candidate.clone());
                let r = call(host, next, std::slice::from_ref(&candidate), out)?;
                if matches!(r, Value::Null) {
                    break;
                }
                cur = Some(r);
            }
            acc
        }
    };
    for op in seq.ops.iter() {
        match op {
            SeqOp::Map(f) => {
                let mut nx: Vec<Value> = Vec::with_capacity(items.len());
                for v in &items {
                    nx.push(call(host, f, std::slice::from_ref(v), out)?);
                }
                items = nx;
            }
            SeqOp::OnEach(f) => {
                for v in &items {
                    call(host, f, std::slice::from_ref(v), out)?;
                }
            }
            SeqOp::MapIndexed(f) => {
                let mut nx: Vec<Value> = Vec::with_capacity(items.len());
                for (i, v) in items.iter().enumerate() {
                    nx.push(call(host, f, &[Value::new_int(i as i64), v.clone()], out)?);
                }
                items = nx;
            }
            SeqOp::FilterIndexed(f) => {
                let mut nx: Vec<Value> = Vec::new();
                for (i, v) in items.iter().enumerate() {
                    if matches!(
                        call(host, f, &[Value::new_int(i as i64), v.clone()], out)?,
                        Value::Bool(true)
                    ) {
                        nx.push(v.clone());
                    }
                }
                items = nx;
            }
            SeqOp::Filter(f) => {
                let mut nx: Vec<Value> = Vec::new();
                for v in &items {
                    if matches!(call(host, f, std::slice::from_ref(v), out)?, Value::Bool(true)) {
                        nx.push(v.clone());
                    }
                }
                items = nx;
            }
            SeqOp::FilterNot(f) => {
                let mut nx: Vec<Value> = Vec::new();
                for v in &items {
                    if !matches!(call(host, f, std::slice::from_ref(v), out)?, Value::Bool(true)) {
                        nx.push(v.clone());
                    }
                }
                items = nx;
            }
            SeqOp::Take(n) => {
                let n = *n as usize;
                if n < items.len() {
                    items.truncate(n);
                }
            }
            SeqOp::Drop(n) => {
                let n = (*n as usize).min(items.len());
                items.drain(..n);
            }
            SeqOp::TakeWhile(f) => {
                let mut cutoff = items.len();
                for (i, v) in items.iter().enumerate() {
                    if !matches!(call(host, f, std::slice::from_ref(v), out)?, Value::Bool(true)) {
                        cutoff = i;
                        break;
                    }
                }
                items.truncate(cutoff);
            }
            SeqOp::DropWhile(f) => {
                let mut start = 0usize;
                while start < items.len() {
                    let v = items[start].clone();
                    if !matches!(call(host, f, std::slice::from_ref(&v), out)?, Value::Bool(true)) {
                        break;
                    }
                    start += 1;
                }
                items.drain(..start);
            }
            SeqOp::FlatMap(f) => {
                let mut nx: Vec<Value> = Vec::new();
                for v in &items {
                    let mapped = call(host, f, std::slice::from_ref(v), out)?;
                    match mapped {
                        Value::List { items: xs, .. } | Value::Set { items: xs, .. } => {
                            nx.extend(xs.borrow().iter().cloned());
                        }
                        Value::Sequence(_) => {
                            nx.extend(materialise_sequence(&mapped, host, out)?);
                        }
                        other => nx.push(other),
                    }
                }
                items = nx;
            }
            SeqOp::Distinct => {
                let mut seen: Vec<Value> = Vec::new();
                let mut nx: Vec<Value> = Vec::new();
                for v in &items {
                    if !seen.iter().any(|s| Value::structural_eq_boxed(s, v)) {
                        seen.push(v.clone());
                        nx.push(v.clone());
                    }
                }
                items = nx;
            }
            SeqOp::DistinctBy(f) => {
                let mut seen: Vec<Value> = Vec::new();
                let mut nx: Vec<Value> = Vec::new();
                for v in &items {
                    let key = call(host, f, std::slice::from_ref(v), out)?;
                    if !seen.iter().any(|s| Value::structural_eq_boxed(s, &key)) {
                        seen.push(key);
                        nx.push(v.clone());
                    }
                }
                items = nx;
            }
            SeqOp::Sorted(descending) => {
                let descending = *descending;
                let mut err: Option<RuntimeError> = None;
                items.sort_by(|a, b| {
                    if err.is_some() {
                        return std::cmp::Ordering::Equal;
                    }
                    match compare_values(a, b) {
                        Ok(o) => {
                            if descending {
                                o.reverse()
                            } else {
                                o
                            }
                        }
                        Err(e) => {
                            err = Some(e);
                            std::cmp::Ordering::Equal
                        }
                    }
                });
                if let Some(e) = err {
                    return Err(e);
                }
            }
            SeqOp::SortedBy(f, descending) => {
                let descending = *descending;
                let mut keyed: Vec<(Value, Value)> = Vec::with_capacity(items.len());
                for v in items.drain(..) {
                    let k = call(host, f, std::slice::from_ref(&v), out)?;
                    keyed.push((k, v));
                }
                let mut err: Option<RuntimeError> = None;
                keyed.sort_by(|a, b| {
                    if err.is_some() {
                        return std::cmp::Ordering::Equal;
                    }
                    match compare_values(&a.0, &b.0) {
                        Ok(o) => {
                            if descending {
                                o.reverse()
                            } else {
                                o
                            }
                        }
                        Err(e) => {
                            err = Some(e);
                            std::cmp::Ordering::Equal
                        }
                    }
                });
                if let Some(e) = err {
                    return Err(e);
                }
                items = keyed.into_iter().map(|(_, v)| v).collect();
            }
            SeqOp::SortedWith(comparator) => {
                let comp = comparator.clone();
                // Insertion sort so the comparator callback can
                // dispatch back through the host.
                for i in 1..items.len() {
                    let mut j = i;
                    while j > 0 {
                        let a = items[j - 1].clone();
                        let b = items[j].clone();
                        let ord_val = match host.invoke_method(&comp, "compare", &[a, b], out) {
                            Some(Ok(v)) => v,
                            Some(Err(e)) => return Err(e),
                            None => {
                                return Err(RuntimeError::Type(
                                    "SortedWith: comparator has no `compare` method".into(),
                                ))
                            }
                        };
                        let n = ord_val.as_i64().unwrap_or(0);
                        if n > 0 {
                            items.swap(j - 1, j);
                            j -= 1;
                        } else {
                            break;
                        }
                    }
                }
            }
        }
    }
    Ok(items)
}

/// Kotlin's `Double`/`Float` total order (matching `java.lang.Double.compare`):
/// every `NaN` is greater than all other values (including `+Infinity`) and all
/// `NaN`s are equal, and `-0.0 < 0.0`. Implemented via the bit ordering Java's
/// `doubleToLongBits` defines, with `NaN` canonicalised so klio's negative-NaN
/// bit pattern still sorts as the greatest value. (The IEEE `<`/`>` operators
/// keep their own non-total semantics elsewhere.)
fn kotlin_float_total_cmp(a: f64, b: f64) -> std::cmp::Ordering {
    use std::cmp::Ordering;
    if a < b {
        Ordering::Less
    } else if a > b {
        Ordering::Greater
    } else {
        let bits = |x: f64| -> i64 {
            if x.is_nan() {
                0x7ff8_0000_0000_0000u64 as i64
            } else {
                x.to_bits() as i64
            }
        };
        bits(a).cmp(&bits(b))
    }
}

pub fn compare_values(a: &Value, b: &Value) -> Result<std::cmp::Ordering, RuntimeError> {
    use std::cmp::Ordering::*;
    if a.is_numeric() && b.is_numeric() {
        if a.is_integral() && b.is_integral() {
            return Ok(a.as_i64().unwrap().cmp(&b.as_i64().unwrap()));
        }
        return Ok(kotlin_float_total_cmp(a.as_f64().unwrap(), b.as_f64().unwrap()));
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
    // For Instance items, defer to a user-declared
    // `override fun compareTo(...)` via the host. Build a parallel
    // scores array of pairwise comparisons up-front to keep
    // sort_by's closure side-effect-free.
    let needs_host = copy
        .iter()
        .any(|v| matches!(v, Value::Instance(_)));
    let mut err: Option<RuntimeError> = None;
    if needs_host {
        let CallCtx { out, host, .. } = ctx;
        let mut indexed: Vec<(usize, Value)> =
            copy.iter().cloned().enumerate().collect();
        indexed.sort_by(|(ia, a), (ib, b)| {
            if err.is_some() {
                return ia.cmp(ib);
            }
            let ord = if matches!(a, Value::Instance(_)) {
                match host.invoke_method(a, "compareTo", std::slice::from_ref(b), *out) {
                    Some(Ok(Value::Int(n))) => i32_to_ordering(n as i32),
                    Some(Err(e)) => {
                        err = Some(e);
                        std::cmp::Ordering::Equal
                    }
                    _ => match compare_values(a, b) {
                        Ok(o) => o,
                        Err(e) => {
                            err = Some(e);
                            std::cmp::Ordering::Equal
                        }
                    },
                }
            } else {
                match compare_values(a, b) {
                    Ok(o) => o,
                    Err(e) => {
                        err = Some(e);
                        std::cmp::Ordering::Equal
                    }
                }
            };
            if ord != std::cmp::Ordering::Equal {
                ord
            } else {
                ia.cmp(ib)
            }
        });
        if let Some(e) = err {
            return Err(e);
        }
        return Ok(make_list(
            indexed.into_iter().map(|(_, v)| v).collect(),
            false,
        ));
    }
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

fn i32_to_ordering(n: i32) -> std::cmp::Ordering {
    if n < 0 {
        std::cmp::Ordering::Less
    } else if n > 0 {
        std::cmp::Ordering::Greater
    } else {
        std::cmp::Ordering::Equal
    }
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
    let items: Vec<Value> = it.borrow().clone();
    if items.is_empty() {
        return Ok(Value::Null);
    }
    let mut best = items[0].clone();
    let CallCtx { out, host, .. } = ctx;
    for v in items.iter().skip(1) {
        let ord = compare_host_aware(v, &best, host, *out)?;
        if ord == std::cmp::Ordering::Greater {
            best = v.clone();
        }
    }
    Ok(best)
}

fn coll_list_min_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.minOrNull")?;
    let items: Vec<Value> = it.borrow().clone();
    if items.is_empty() {
        return Ok(Value::Null);
    }
    let mut best = items[0].clone();
    let CallCtx { out, host, .. } = ctx;
    for v in items.iter().skip(1) {
        let ord = compare_host_aware(v, &best, host, *out)?;
        if ord == std::cmp::Ordering::Less {
            best = v.clone();
        }
    }
    Ok(best)
}

fn compare_host_aware(
    a: &Value,
    b: &Value,
    host: &mut &mut dyn klio_runtime::IntrinsicHost,
    out: &mut dyn klio_runtime::Output,
) -> Result<std::cmp::Ordering, RuntimeError> {
    if matches!(a, Value::Instance(_)) {
        if let Some(Ok(Value::Int(n))) =
            host.invoke_method(a, "compareTo", std::slice::from_ref(b), out)
        {
            return Ok(i32_to_ordering(n as i32));
        }
    }
    compare_values(a, b)
}

/// Collect `(key, value)` entries from a slice of `Value::Pair`s,
/// last-write-wins on duplicate keys (matching `toMap`/`putAll`).
fn pairs_from_values(items: &[Value], who: &str) -> Result<Vec<(Value, Value)>, RuntimeError> {
    let mut entries: Vec<(Value, Value)> = Vec::new();
    for v in items {
        let Value::Pair(k, val) = v else {
            return Err(RuntimeError::Type(format!(
                "{who} requires a collection of Pair<K, V>"
            )));
        };
        let key = (**k).clone();
        if let Some(slot) = entries.iter_mut().find(|(kk, _)| Value::structural_eq_boxed(kk, &key)) {
            slot.1 = (**val).clone();
        } else {
            entries.push((key, (**val).clone()));
        }
    }
    Ok(entries)
}

fn coll_list_to_map(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    // Accept List/Set (recv_list_items) and Array receivers uniformly:
    // upstream `Array<out Pair>.toMap()` and `Iterable<Pair>.toMap()`
    // share this body.
    let items: Vec<Value> = match ctx.args.first() {
        Some(Value::Array { items, .. }) => items.borrow().clone(),
        _ => recv_list_items(ctx.args, "toMap")?.borrow().clone(),
    };
    Ok(make_map(pairs_from_values(&items, "toMap")?, false))
}

fn coll_list_distinct(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.distinct")?;
    let mut out: Vec<Value> = Vec::new();
    for v in it.borrow().iter() {
        if !out.iter().any(|x| Value::structural_eq_boxed(x, v)) {
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
            fqn: Arc::new("kotlin.IllegalArgumentException".into()),
            message: Some(Arc::new(format!("Requested element count {n} is less than zero."))),
            cause: None,
        }));
    }
    Ok(n)
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
                        fqn: Arc::new("kotlin.IndexOutOfBoundsException".into()),
                        message: Some(Arc::new(format!(
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
                        fqn: Arc::new("kotlin.IndexOutOfBoundsException".into()),
                        message: Some(Arc::new(format!(
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
            fqn: Arc::new("kotlin.IndexOutOfBoundsException".into()),
            message: Some(Arc::new(format!(
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
        if let Some(pos) = remaining.iter().position(|r| Value::structural_eq_boxed(r, v)) {
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
            fqn: Arc::new("kotlin.IllegalArgumentException".into()),
            message: Some(Arc::new(format!("Size {size} must be greater than zero."))),
            cause: None,
        }));
    }
    let size = *size as usize;
    let transform = match ctx.args.get(2) {
        Some(Value::Null) | None => None,
        Some(v) => Some(v.clone()),
    };
    let chunks: Vec<Vec<Value>> = {
        let borrow = it.borrow();
        let mut chunks: Vec<Vec<Value>> = Vec::new();
        let mut i = 0;
        while i < borrow.len() {
            let end = (i + size).min(borrow.len());
            chunks.push(borrow[i..end].to_vec());
            i += size;
        }
        chunks
    };
    let mut groups: Vec<Value> = Vec::with_capacity(chunks.len());
    match transform {
        None => {
            for c in chunks {
                groups.push(make_list(c, false));
            }
        }
        Some(block) => {
            let CallCtx { out, host, .. } = ctx;
            for c in chunks {
                let window = make_list(c, false);
                let r = host.invoke_callable(&block, std::slice::from_ref(&window), *out)?;
                groups.push(r);
            }
        }
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
            fqn: Arc::new("kotlin.IllegalArgumentException".into()),
            message: Some(Arc::new(format!("size {size} must be greater than zero."))),
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
            fqn: Arc::new("kotlin.IllegalArgumentException".into()),
            message: Some(Arc::new(format!("step {step} must be greater than zero."))),
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
    let Some(rhs_val) = ctx.args.get(1).cloned() else {
        return Err(RuntimeError::Arity("zip requires a second collection".into()));
    };
    // Optional transform: `xs.zip(ys) { x, y -> … }` packs the
    // result via the lambda instead of producing Pair values.
    let transform = ctx.args.get(2).cloned().filter(|v| {
        matches!(
            v,
            Value::IrClosure { .. }
                | Value::Lambda { .. }
                | Value::BoundMethod { .. }
                | Value::Instance(_)
        )
    });
    let rhs: Vec<Value> = match &rhs_val {
        Value::List { items, .. } => items.borrow().clone(),
        Value::Set { items, .. } => items.borrow().clone(),
        Value::Array { items, .. } => items.borrow().clone(),
        Value::Range { start, end, step, .. } => range_iter_int(*start, *end, *step)
            .map(Value::new_int)
            .collect(),
        other => {
            return Err(RuntimeError::Type(format!(
                "zip requires a collection, got {other:?}"
            )))
        }
    };
    let lhs_items: Vec<Value> = lhs.borrow().clone();
    let CallCtx { out, host, .. } = ctx;
    let mut result: Vec<Value> = Vec::with_capacity(lhs_items.len().min(rhs.len()));
    for (a, b) in lhs_items.iter().zip(rhs.iter()) {
        if let Some(t) = &transform {
            let r = host.invoke_callable(t, &[a.clone(), b.clone()], *out)?;
            result.push(r);
        } else {
            result.push(Value::Pair(Box::new(a.clone()), Box::new(b.clone())));
        }
    }
    Ok(make_list(result, false))
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
        if !out.iter().any(|x| Value::structural_eq_boxed(x, &v)) {
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
    Ok(Value::Set { items: ObjRef::new(out), mutable: false, backing: None })
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
        .filter(|v| !removals.iter().any(|r| Value::structural_eq_boxed(r, v)))
        .cloned()
        .collect();
    Ok(Value::Set { items: ObjRef::new(out), mutable: false, backing: None })
}

/// `Map + Pair` / `Map + Map` / `Map + Iterable<Pair>` — returns a
/// new map with the entries added (existing keys overwritten,
/// last-write-wins via `make_map`).
fn coll_map_to_mutable_map(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = match ctx.args.first() {
        Some(Value::Map { entries, .. }) => entries.borrow().clone(),
        _ => return Err(RuntimeError::Type("toMutableMap requires a Map receiver".into())),
    };
    Ok(make_map(entries, true))
}

fn coll_map_to_map(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = match ctx.args.first() {
        Some(Value::Map { entries, .. }) => entries.borrow().clone(),
        _ => return Err(RuntimeError::Type("toMap requires a Map receiver".into())),
    };
    Ok(make_map(entries, false))
}

fn coll_map_plus(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = recv_map_entries(ctx.args, "Map.plus")?;
    let mut out: Vec<(Value, Value)> = entries.borrow().clone();
    let Some(arg) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("plus requires an argument".into()));
    };
    let add_pair = |out: &mut Vec<(Value, Value)>, p: &Value| {
        if let Value::Pair(k, v) = p {
            out.push(((**k).clone(), (**v).clone()));
        }
    };
    match arg {
        Value::Pair(_, _) => add_pair(&mut out, arg),
        Value::Map { entries: e, .. } => out.extend(e.borrow().clone()),
        Value::List { items, .. } | Value::Set { items, .. } => {
            for p in items.borrow().iter() {
                add_pair(&mut out, p);
            }
        }
        _ => {
            return Err(RuntimeError::Type(
                "Map.plus expects a Pair, Map, or Iterable<Pair>".into(),
            ))
        }
    }
    Ok(make_map(out, false))
}

/// `Map - key` / `Map - Iterable<key>` — returns a new map without
/// the given key(s).
fn coll_map_minus(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = recv_map_entries(ctx.args, "Map.minus")?;
    let Some(arg) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("minus requires an argument".into()));
    };
    let keys: Vec<Value> = match arg {
        Value::List { items, .. } | Value::Set { items, .. } => items.borrow().clone(),
        single => vec![single.clone()],
    };
    let out: Vec<(Value, Value)> = entries
        .borrow()
        .iter()
        .filter(|(k, _)| !keys.iter().any(|rk| Value::structural_eq_boxed(rk, k)))
        .cloned()
        .collect();
    Ok(make_map(out, false))
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
        .filter(|v| other.iter().any(|o| Value::structural_eq_boxed(o, v)))
        .cloned()
        .collect();
    Ok(Value::Set { items: ObjRef::new(out), mutable: false, backing: None })
}
fn coll_set_subtract(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    coll_set_minus(ctx)
}

// ----- Set helpers -----

/// After a live `MutableMap.keys`/`.values`/`.entries` view has had its
/// `items` mutated (remove/removeAll/retainAll/clear), rebuild the backing
/// map's entries to mirror the surviving elements. Order-preserving;
/// value-multiplicity-aware for the `values` view.
fn sync_map_view(receiver: &Value) {
    let (items, backing) = match receiver {
        Value::Set { items, backing: Some(b), .. }
        | Value::List { items, backing: Some(b), .. } => (items.clone(), b.clone()),
        _ => return,
    };
    let items_b = items.borrow();
    let kind = backing.kind;
    let mut entries = backing.entries.borrow_mut();
    // The surviving `items` are an order-preserving subsequence of the
    // pre-mutation projection of the entries (keys / values / entry-keys).
    // Walk both in lockstep: keep an entry when its projection matches the
    // next surviving item, advancing the item cursor; drop it otherwise.
    // Subsequence (not multiset) matching keeps the right entry when values
    // repeat — `values.remove(v)` drops the entry of the *first* matching
    // value, exactly as the JVM view does.
    let mut j = 0usize;
    entries.retain(|(k, v)| {
        let proj = match kind {
            klio_runtime::MapViewKind::Values => v,
            _ => k,
        };
        let matched = items_b.get(j).is_some_and(|it| {
            let target = match (kind, it) {
                (klio_runtime::MapViewKind::Entries, Value::MapEntry { key, .. }) => key.as_ref(),
                _ => it,
            };
            Value::structural_eq_boxed(proj, target)
        });
        if matched {
            j += 1;
            true
        } else {
            false
        }
    });
}

fn recv_set_items<'a>(args: &'a [Value], what: &str) -> Result<ObjRef<Vec<Value>>, RuntimeError> {
    match args.first() {
        Some(Value::Set { items, .. }) => Ok(items.clone()),
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
    Ok(Value::Bool(it.borrow().iter().any(|v| Value::structural_eq_boxed(v, needle))))
}
fn array_slice_impl(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let recv = ctx.args.first().ok_or_else(|| {
        RuntimeError::Type("sliceArray requires a receiver".into())
    })?;
    let (items, prim) = match recv {
        Value::Array { items, prim } => (items.clone(), prim.clone()),
        _ => return Err(RuntimeError::Type(
            "sliceArray requires an array receiver".into()
        )),
    };
    let arg = ctx.args.get(1).ok_or_else(|| {
        RuntimeError::Arity("sliceArray expects (receiver, range)".into())
    })?;
    let (start, end) = match arg {
        Value::Range { start, end, step: _, kind: _ } => (*start as usize, *end as usize),
        _ => return Err(RuntimeError::Type(
            "sliceArray expects an IntRange argument".into()
        )),
    };
    let src = items.borrow();
    let lo = start.min(src.len());
    let hi = (end + 1).min(src.len());
    let slice: Vec<Value> = if lo <= hi { src[lo..hi].to_vec() } else { Vec::new() };
    Ok(Value::Array {
        items: klio_runtime::ObjRef::new(slice),
        prim,
    })
}

fn array_sum_impl(ctx: &mut CallCtx, what: &str) -> Result<Value, RuntimeError> {
    let items = iterable_items(
        ctx.args.first().ok_or_else(|| RuntimeError::Type(format!("{what} requires a receiver")))?,
        what,
    )?;
    let mut int_acc: i64 = 0;
    let mut dbl_acc: f64 = 0.0;
    let mut as_double = false;
    for v in &items {
        match v {
            Value::Int(_) | Value::Long(_) | Value::Short(_) | Value::Byte(_) => {
                int_acc += v.as_i64().unwrap_or(0);
            }
            Value::Double(d) => {
                if !as_double {
                    dbl_acc = int_acc as f64;
                    as_double = true;
                }
                dbl_acc += *d;
            }
            Value::Float(f) => {
                if !as_double {
                    dbl_acc = int_acc as f64;
                    as_double = true;
                }
                dbl_acc += *f as f64;
            }
            _ => return Err(RuntimeError::Type(format!(
                "{what}: non-numeric element"
            ))),
        }
    }
    if as_double {
        Ok(Value::Double(dbl_acc))
    } else {
        Ok(Value::new_int(int_acc))
    }
}

fn array_sum_int(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    array_sum_impl(ctx, "Array.sum")
}

fn array_average_impl(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let items = iterable_items(
        ctx.args.first().ok_or_else(|| RuntimeError::Type("Array.average requires a receiver".into()))?,
        "Array.average",
    )?;
    if items.is_empty() {
        return Ok(Value::Double(f64::NAN));
    }
    let mut acc: f64 = 0.0;
    for v in &items {
        let n: f64 = match v {
            Value::Int(_) | Value::Long(_) | Value::Short(_) | Value::Byte(_) => v.as_i64().unwrap_or(0) as f64,
            Value::Double(d) => *d,
            Value::Float(f) => *f as f64,
            _ => return Err(RuntimeError::Type(
                "Array.average: non-numeric element".into()
            )),
        };
        acc += n;
    }
    Ok(Value::Double(acc / items.len() as f64))
}

fn array_max_impl(ctx: &mut CallCtx, what: &str) -> Result<Value, RuntimeError> {
    let items = iterable_items(
        ctx.args.first().ok_or_else(|| RuntimeError::Type(format!("{what} requires a receiver")))?,
        what,
    )?;
    if items.is_empty() {
        return Err(RuntimeError::Thrown(Value::Exception {
            fqn: Arc::new("kotlin.NoSuchElementException".into()),
            message: Some(Arc::new(format!("{what}: empty"))),
            cause: None,
        }));
    }
    let mut best = items[0].clone();
    for v in items.iter().skip(1) {
        if compare_values(v, &best)? == std::cmp::Ordering::Greater {
            best = v.clone();
        }
    }
    Ok(best)
}

fn array_max(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    array_max_impl(ctx, "Array.max")
}

fn array_min_impl(ctx: &mut CallCtx, what: &str) -> Result<Value, RuntimeError> {
    let items = iterable_items(
        ctx.args.first().ok_or_else(|| RuntimeError::Type(format!("{what} requires a receiver")))?,
        what,
    )?;
    if items.is_empty() {
        return Err(RuntimeError::Thrown(Value::Exception {
            fqn: Arc::new("kotlin.NoSuchElementException".into()),
            message: Some(Arc::new(format!("{what}: empty"))),
            cause: None,
        }));
    }
    let mut best = items[0].clone();
    for v in items.iter().skip(1) {
        if compare_values(v, &best)? == std::cmp::Ordering::Less {
            best = v.clone();
        }
    }
    Ok(best)
}

fn array_min(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    array_min_impl(ctx, "Array.min")
}

fn coll_set_sorted(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "Set.sorted")?;
    let mut copy: Vec<Value> = it.borrow().clone();
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

fn coll_set_sorted_descending(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = coll_set_sorted(ctx)?;
    let Value::List { items, .. } = v else { unreachable!() };
    let mut out: Vec<Value> = items.borrow().clone();
    out.reverse();
    Ok(make_list(out, false))
}

fn coll_set_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = ctx.args.first().ok_or_else(|| RuntimeError::Type("Set.toString requires a receiver".into()))?;
    Ok(Value::String(Arc::new(format!("{v}"))))
}
fn coll_mut_set_add(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "MutableSet.add")?;
    let Some(arg) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("add requires an argument".into()));
    };
    let mut borrow = it.borrow_mut();
    if borrow.iter().any(|v| Value::structural_eq_boxed(v, arg)) {
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
    let removed = {
        let mut borrow = it.borrow_mut();
        if let Some(pos) = borrow.iter().position(|v| Value::structural_eq_boxed(v, arg)) {
            borrow.remove(pos);
            true
        } else {
            false
        }
    };
    if removed {
        sync_map_view(&ctx.args[0]);
    }
    Ok(Value::Bool(removed))
}
fn coll_mut_set_clear(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    recv_set_items(ctx.args, "MutableSet.clear")?.borrow_mut().clear();
    sync_map_view(&ctx.args[0]);
    Ok(Value::Unit)
}
fn coll_mut_set_remove_all(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "MutableSet.removeAll")?;
    let other: Vec<Value> = match ctx.args.get(1) {
        Some(Value::List { items, .. }) | Some(Value::Set { items, .. }) => items.borrow().clone(),
        Some(Value::Array { items, .. }) => items.borrow().clone(),
        _ => return Err(RuntimeError::Type("removeAll requires a collection".into())),
    };
    let changed = {
        let mut b = it.borrow_mut();
        let before = b.len();
        b.retain(|v| !other.iter().any(|o| Value::structural_eq_boxed(v, o)));
        b.len() != before
    };
    if changed {
        sync_map_view(&ctx.args[0]);
    }
    Ok(Value::Bool(changed))
}
fn coll_mut_set_retain_all(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "MutableSet.retainAll")?;
    let other: Vec<Value> = match ctx.args.get(1) {
        Some(Value::List { items, .. }) | Some(Value::Set { items, .. }) => items.borrow().clone(),
        Some(Value::Array { items, .. }) => items.borrow().clone(),
        _ => return Err(RuntimeError::Type("retainAll requires a collection".into())),
    };
    let changed = {
        let mut b = it.borrow_mut();
        let before = b.len();
        b.retain(|v| other.iter().any(|o| Value::structural_eq_boxed(v, o)));
        b.len() != before
    };
    if changed {
        sync_map_view(&ctx.args[0]);
    }
    Ok(Value::Bool(changed))
}

// ----- Map helpers -----

fn recv_map_entries<'a>(
    args: &'a [Value],
    what: &str,
) -> Result<ObjRef<Vec<(Value, Value)>>, RuntimeError> {
    match args.first() {
        Some(Value::Map { entries, .. }) => Ok(entries.clone()),
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
        .find(|(k, _)| Value::structural_eq_boxed(k, key))
        .map(|(_, v)| v.clone())
        .unwrap_or(Value::Null))
}
fn coll_map_contains_key(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = recv_map_entries(ctx.args, "Map.containsKey")?;
    let Some(key) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("containsKey requires a key".into()));
    };
    Ok(Value::Bool(
        entries.borrow().iter().any(|(k, _)| Value::structural_eq_boxed(k, key)),
    ))
}
fn coll_map_contains_value(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = recv_map_entries(ctx.args, "Map.containsValue")?;
    let Some(value) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("containsValue requires a value".into()));
    };
    Ok(Value::Bool(
        entries.borrow().iter().any(|(_, v)| Value::structural_eq_boxed(v, value)),
    ))
}
fn coll_map_keys(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = recv_map_entries(ctx.args, "Map.keys")?;
    let keys: Vec<Value> = entries.borrow().iter().map(|(k, _)| k.clone()).collect();
    Ok(Value::Set {
        items: ObjRef::new(keys),
        mutable: true,
        backing: Some(Box::new(klio_runtime::MapBacking {
            entries,
            kind: klio_runtime::MapViewKind::Keys,
        })),
    })
}
fn coll_map_values(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = recv_map_entries(ctx.args, "Map.values")?;
    let values: Vec<Value> = entries.borrow().iter().map(|(_, v)| v.clone()).collect();
    Ok(Value::List {
        items: ObjRef::new(values),
        mutable: true,
        enum_class: None,
        backing: Some(Box::new(klio_runtime::MapBacking {
            entries,
            kind: klio_runtime::MapViewKind::Values,
        })),
    })
}
fn coll_map_entries(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = recv_map_entries(ctx.args, "Map.entries")?;
    let map_entries: Vec<Value> = entries
        .borrow()
        .iter()
        .map(|(k, v)| Value::MapEntry {
            key: Box::new(k.clone()),
            value: Box::new(v.clone()),
            backing: Some(entries.clone()),
        })
        .collect();
    Ok(Value::Set {
        items: ObjRef::new(map_entries),
        mutable: true,
        backing: Some(Box::new(klio_runtime::MapBacking {
            entries,
            kind: klio_runtime::MapViewKind::Entries,
        })),
    })
}
fn coll_map_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = ctx.args.first().ok_or_else(|| RuntimeError::Type("Map.toString requires a receiver".into()))?;
    Ok(Value::String(Arc::new(format!("{v}"))))
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
    if let Some(slot) = borrow.iter_mut().find(|(k, _)| Value::structural_eq_boxed(k, key)) {
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
    if let Some(pos) = borrow.iter().position(|(k, _)| Value::structural_eq_boxed(k, key)) {
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

/// Shared accessor: the entries ObjRef of a `Value::Map` receiver.
fn mut_map_entries_rc(
    recv: &Value,
    who: &str,
) -> Result<ObjRef<Vec<(Value, Value)>>, RuntimeError> {
    match recv {
        Value::Map { entries, .. } => Ok(entries.clone()),
        _ => Err(RuntimeError::Type(format!("{who} requires a MutableMap receiver"))),
    }
}

fn map_find(entries: &ObjRef<Vec<(Value, Value)>>, key: &Value) -> Option<Value> {
    entries
        .borrow()
        .iter()
        .find(|(k, _)| Value::structural_eq_boxed(k, key))
        .map(|(_, v)| v.clone())
}

fn map_set(entries: &ObjRef<Vec<(Value, Value)>>, key: Value, value: Value) {
    let mut b = entries.borrow_mut();
    if let Some(slot) = b.iter_mut().find(|(k, _)| Value::structural_eq_boxed(k, &key)) {
        slot.1 = value;
    } else {
        b.push((key, value));
    }
}

fn map_remove_key(entries: &ObjRef<Vec<(Value, Value)>>, key: &Value) {
    let mut b = entries.borrow_mut();
    if let Some(pos) = b.iter().position(|(k, _)| Value::structural_eq_boxed(k, key)) {
        b.remove(pos);
    }
}

/// `merge(key, value) { old, new -> … }`: insert `value` if absent, else store
/// the remapping result (or remove the key if it returns null). Returns the new
/// value, or null if removed.
fn map_merge(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = mut_map_entries_rc(&ctx.args[0].clone(), "merge")?;
    let key = ctx.args.get(1).cloned().ok_or_else(|| RuntimeError::Arity("merge requires a key".into()))?;
    let value = ctx.args.get(2).cloned().ok_or_else(|| RuntimeError::Arity("merge requires a value".into()))?;
    let block = ctx.args.get(3).cloned().ok_or_else(|| RuntimeError::Arity("merge requires a remapping block".into()))?;
    let existing = map_find(&entries, &key);
    let CallCtx { out, host, .. } = ctx;
    let new_val = match existing {
        None => value,
        Some(old) => host.invoke_callable(&block, &[old, value], *out)?,
    };
    if matches!(new_val, Value::Null) {
        map_remove_key(&entries, &key);
    } else {
        map_set(&entries, key, new_val.clone());
    }
    Ok(new_val)
}

/// `putIfAbsent(key, value)`: store only if absent; return the previous value
/// (or null).
fn map_put_if_absent(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = mut_map_entries_rc(&ctx.args[0].clone(), "putIfAbsent")?;
    let key = ctx.args.get(1).cloned().ok_or_else(|| RuntimeError::Arity("putIfAbsent requires a key".into()))?;
    let value = ctx.args.get(2).cloned().ok_or_else(|| RuntimeError::Arity("putIfAbsent requires a value".into()))?;
    match map_find(&entries, &key) {
        Some(old) => Ok(old),
        None => {
            map_set(&entries, key, value);
            Ok(Value::Null)
        }
    }
}

/// `replace(key, value)`: replace only if the key is present; return the
/// previous value (or null). The 3-arg `replace(key, old, new): Boolean` form
/// is handled when a third arg is supplied.
fn map_replace(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = mut_map_entries_rc(&ctx.args[0].clone(), "replace")?;
    let key = ctx.args.get(1).cloned().ok_or_else(|| RuntimeError::Arity("replace requires a key".into()))?;
    if ctx.args.len() >= 4 {
        // replace(key, oldValue, newValue): Boolean
        let old = ctx.args[2].clone();
        let new = ctx.args[3].clone();
        match map_find(&entries, &key) {
            Some(cur) if Value::structural_eq_boxed(&cur, &old) => {
                map_set(&entries, key, new);
                Ok(Value::Bool(true))
            }
            _ => Ok(Value::Bool(false)),
        }
    } else {
        let value = ctx.args.get(2).cloned().ok_or_else(|| RuntimeError::Arity("replace requires a value".into()))?;
        match map_find(&entries, &key) {
            Some(old) => {
                map_set(&entries, key, value);
                Ok(old)
            }
            None => Ok(Value::Null),
        }
    }
}

/// `computeIfAbsent(key) { key -> value }`: compute & store a value only if the
/// key is absent; returns the present-or-computed value.
fn map_compute_if_absent(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = mut_map_entries_rc(&ctx.args[0].clone(), "computeIfAbsent")?;
    let key = ctx.args.get(1).cloned().ok_or_else(|| RuntimeError::Arity("computeIfAbsent requires a key".into()))?;
    if let Some(v) = map_find(&entries, &key) {
        return Ok(v);
    }
    let block = ctx.args.get(2).cloned().ok_or_else(|| RuntimeError::Arity("computeIfAbsent requires a block".into()))?;
    let CallCtx { out, host, .. } = ctx;
    let v = host.invoke_callable(&block, std::slice::from_ref(&key), *out)?;
    map_set(&entries, key, v.clone());
    Ok(v)
}

/// `computeIfPresent(key) { key, old -> new? }`: recompute only if present;
/// remove on null. Returns the new value (or null).
fn map_compute_if_present(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = mut_map_entries_rc(&ctx.args[0].clone(), "computeIfPresent")?;
    let key = ctx.args.get(1).cloned().ok_or_else(|| RuntimeError::Arity("computeIfPresent requires a key".into()))?;
    let block = ctx.args.get(2).cloned().ok_or_else(|| RuntimeError::Arity("computeIfPresent requires a block".into()))?;
    let Some(old) = map_find(&entries, &key) else {
        return Ok(Value::Null);
    };
    let CallCtx { out, host, .. } = ctx;
    let new_val = host.invoke_callable(&block, &[key.clone(), old], *out)?;
    if matches!(new_val, Value::Null) {
        map_remove_key(&entries, &key);
    } else {
        map_set(&entries, key, new_val.clone());
    }
    Ok(new_val)
}

/// `compute(key) { key, old? -> new? }`: recompute from the (possibly null)
/// current value; remove on null. Returns the new value (or null).
fn map_compute(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = mut_map_entries_rc(&ctx.args[0].clone(), "compute")?;
    let key = ctx.args.get(1).cloned().ok_or_else(|| RuntimeError::Arity("compute requires a key".into()))?;
    let block = ctx.args.get(2).cloned().ok_or_else(|| RuntimeError::Arity("compute requires a block".into()))?;
    let old = map_find(&entries, &key).unwrap_or(Value::Null);
    let CallCtx { out, host, .. } = ctx;
    let new_val = host.invoke_callable(&block, &[key.clone(), old], *out)?;
    if matches!(new_val, Value::Null) {
        map_remove_key(&entries, &key);
    } else {
        map_set(&entries, key, new_val.clone());
    }
    Ok(new_val)
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
    Ok(Value::String(Arc::new(format!("{v}"))))
}

// ============================================================
// Sequence (eager; same observable output as List)
// ============================================================

/// Build an items-only Sequence from a `Vec`. Used by `asSequence`,
/// `sequenceOf`, and `emptySequence`.
fn make_sequence(items: Vec<Value>) -> Value {
    Value::Sequence(Arc::new(klio_runtime::SequenceData {
        source: klio_runtime::SequenceSource::Items(Arc::new(items)),
        ops: Vec::new(),
    }))
}

/// `sequence { yield(...) ; yieldAll(...) }` builder. klio runs the
/// `suspend SequenceScope<T>.() -> Unit` block eagerly: a host
/// SequenceScope instance carries a shared mutable buffer that the
/// `yield`/`yieldAll` intrinsics append to; the collected items become
/// a `Value::Sequence`. Faithful for finite builders (the common case);
/// an unbounded `while (true) { yield(..) }` would grow the buffer and
/// is bounded by the dev memory guard rather than truly lazy.
fn seq_scope_buffer(scope: &Value) -> Option<ObjRef<Vec<Value>>> {
    if let Value::Instance(inst) = scope {
        if let Some(Value::List { items, .. }) = inst.borrow().get("__seq_buffer") {
            return Some(items);
        }
    }
    None
}

fn run_seq_builder(ctx: &mut CallCtx, who: &str) -> Result<ObjRef<Vec<Value>>, RuntimeError> {
    let block = ctx
        .args
        .first()
        .cloned()
        .ok_or_else(|| RuntimeError::Arity(format!("{who} expects a block")))?;
    let buffer: ObjRef<Vec<Value>> = ObjRef::new(Vec::new());
    let scope = {
        let id = ctx.host.alloc_instance_id();
        ctx.host.new_synth_instance(
            "kotlin.sequences.SequenceScope",
            id,
            vec![(
                "__seq_buffer".to_string(),
                Value::List { items: buffer.clone(), mutable: true, enum_class: None, backing: None },
            )],
        )
    };
    let CallCtx { out, host, .. } = ctx;
    host.invoke_callable_with_this(&block, &[], &scope, *out)?;
    Ok(buffer)
}

fn seq_builder(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let buffer = run_seq_builder(ctx, "sequence")?;
    let items = buffer.borrow().clone();
    Ok(make_sequence(items))
}

fn seq_iterator_builder(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let buffer = run_seq_builder(ctx, "iterator")?;
    let items = buffer.borrow().clone();
    Ok(Value::Iterator { items: ObjRef::new(items), pos: ObjRef::new(0), prim: None })
}

fn seq_scope_yield(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let buffer = seq_scope_buffer(&ctx.args[0])
        .ok_or_else(|| RuntimeError::Type("yield: not a SequenceScope".into()))?;
    if let Some(v) = ctx.args.get(1) {
        buffer.borrow_mut().push(v.clone());
    }
    Ok(Value::Unit)
}

fn seq_scope_yield_all(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let buffer = seq_scope_buffer(&ctx.args[0])
        .ok_or_else(|| RuntimeError::Type("yieldAll: not a SequenceScope".into()))?;
    let elems: Vec<Value> = match ctx.args.get(1) {
        Some(Value::List { items, .. })
        | Some(Value::Set { items, .. })
        | Some(Value::Array { items, .. })
        | Some(Value::Iterator { items, .. }) => items.borrow().clone(),
        Some(Value::Sequence(_)) => {
            let seq = ctx.args[1].clone();
            let CallCtx { out, host, .. } = ctx;
            materialise_sequence(&seq, *host, *out)?
        }
        Some(other) => {
            return Err(RuntimeError::Type(format!(
                "yieldAll: expected an Iterable/Iterator/Sequence, got {other}"
            )))
        }
        None => return Ok(Value::Unit),
    };
    buffer.borrow_mut().extend(elems);
    Ok(Value::Unit)
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

fn seq_generate_sequence(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    use klio_runtime::{SequenceData, SequenceSource};
    match ctx.args {
        [lam @ (Value::Lambda { .. } | Value::IrClosure { .. })] => Ok(Value::Sequence(Arc::new(SequenceData {
            source: SequenceSource::Generate {
                seed: None,
                next: Box::new(lam.clone()),
            },
            ops: Vec::new(),
        }))),
        [seed, lam @ (Value::Lambda { .. } | Value::IrClosure { .. })] => {
            let seeded = if matches!(seed, Value::Null) {
                None
            } else {
                Some(Box::new(seed.clone()))
            };
            Ok(Value::Sequence(Arc::new(SequenceData {
                source: SequenceSource::Generate {
                    seed: seeded,
                    next: Box::new(lam.clone()),
                },
                ops: Vec::new(),
            })))
        }
        _ => Err(RuntimeError::Type(
            "generateSequence expects `(seed, next)` or `(next)` with `next` a lambda".into(),
        )),
    }
}

/// Fast-path Sequence terminal ops handle the special case of an
/// `Items`-source Sequence with no ops. Anything more (intermediate ops,
/// generator sources) goes through `klio-interp`'s lazy materialize path.
fn recv_seq_eager(args: &[Value], what: &str) -> Result<Option<Arc<Vec<Value>>>, RuntimeError> {
    let Some(Value::Sequence(data)) = args.first() else {
        return Err(RuntimeError::Type(format!("{what} requires a Sequence receiver")));
    };
    if !data.ops.is_empty() {
        return Ok(None);
    }
    match &data.source {
        klio_runtime::SequenceSource::Items(items) => Ok(Some(Arc::clone(items))),
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
/// Append one more op to a Sequence, returning a new lazy Sequence value. Used
/// by predicate terminals (`first { p }` == `filter { p }.first()`) so they
/// short-circuit through the same bounded materializer rather than each
/// reimplementing the pull loop.
fn seq_with_extra_op(seq_val: &Value, op: klio_runtime::SeqOp) -> Value {
    match seq_val {
        Value::Sequence(d) => {
            let mut ops = d.ops.clone();
            ops.push(op);
            Value::Sequence(Arc::new(klio_runtime::SequenceData {
                source: d.source.clone(),
                ops,
            }))
        }
        other => other.clone(),
    }
}

/// The receiver Sequence, with a trailing `Filter(predicate)` op when the call
/// supplies one (the `first { p }` / `find { p }` / `any { p }` shape).
fn seq_with_optional_filter(ctx: &CallCtx, who: &str) -> Result<Value, RuntimeError> {
    let seq = ctx
        .args
        .first()
        .filter(|v| matches!(v, Value::Sequence(_)))
        .cloned()
        .ok_or_else(|| RuntimeError::Type(format!("{who} requires a Sequence receiver")))?;
    Ok(match ctx.args.get(1) {
        Some(pred) => seq_with_extra_op(&seq, klio_runtime::SeqOp::Filter(pred.clone())),
        None => seq,
    })
}

fn seq_first(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let target = seq_with_optional_filter(ctx, "Sequence.first")?;
    let CallCtx { out, host, .. } = ctx;
    materialise_sequence_bounded(&target, *host, *out, Some(1))?
        .into_iter()
        .next()
        .ok_or_else(|| {
            RuntimeError::Thrown(Value::Exception {
                fqn: Arc::new("kotlin.NoSuchElementException".into()),
                message: Some(Arc::new(
                    "Sequence contains no element matching the predicate.".into(),
                )),
                cause: None,
            })
        })
}

fn seq_first_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let target = seq_with_optional_filter(ctx, "Sequence.firstOrNull")?;
    let CallCtx { out, host, .. } = ctx;
    Ok(materialise_sequence_bounded(&target, *host, *out, Some(1))?
        .into_iter()
        .next()
        .unwrap_or(Value::Null))
}

fn seq_any(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let target = seq_with_optional_filter(ctx, "Sequence.any")?;
    let CallCtx { out, host, .. } = ctx;
    Ok(Value::Bool(
        !materialise_sequence_bounded(&target, *host, *out, Some(1))?.is_empty(),
    ))
}

fn seq_none(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let target = seq_with_optional_filter(ctx, "Sequence.none")?;
    let CallCtx { out, host, .. } = ctx;
    Ok(Value::Bool(
        materialise_sequence_bounded(&target, *host, *out, Some(1))?.is_empty(),
    ))
}
fn seq_last(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(items) = recv_seq_eager(ctx.args, "Sequence.last")? else {
        return Err(RuntimeError::Unimplemented(
            "Sequence.last on a non-trivial source/op chain".into(),
        ));
    };
    items.last().cloned().ok_or_else(|| {
        RuntimeError::Thrown(Value::Exception {
            fqn: Arc::new("kotlin.NoSuchElementException".into()),
            message: Some(Arc::new("Sequence is empty.".into())),
            cause: None,
        })
    })
}
fn seq_to_string(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    // Kotlin returns an opaque id like `kotlin.sequences.TransformingSequence@…`.
    // Stable parity for that string is meaningless (it embeds the heap
    // address), so we emit a deterministic placeholder. Programs that need
    // a useful value should call `.toList()` before printing.
    Ok(Value::String(Arc::new("kotlin.sequences.Sequence".to_string())))
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
    Ok(Value::String(Arc::new(format!("{v}"))))
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
                    fqn: Arc::new("kotlin.IllegalArgumentException".into()),
                    message: Some(Arc::new(format!(
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

/// View a receiver as a range's `(start, end, step, kind)`.
///
/// klio represents a range two ways: the host `Value::Range`, and — when the
/// upstream `kotlin.ranges.{Int,Long,Char}{Range,Progression}` constructor is
/// invoked as a class (e.g. `Array<T>.indices`'s getter does `IntRange(0,
/// lastIndex)`) — a generic `Value::Instance` carrying the same `first`/`last`/
/// `step` fields. Range intrinsics accept either so an op like `reversed` works
/// regardless of which form a range value took, without a caller having to
/// normalize first.
fn as_range_view(v: &Value) -> Option<(i64, i64, i64, klio_runtime::RangeKind)> {
    use klio_runtime::RangeKind;
    match v {
        Value::Range { start, end, step, kind } => Some((*start, *end, *step, *kind)),
        Value::Instance(inst) => {
            let b = inst.borrow();
            let fqn = b.class.fqn.as_str();
            if !fqn.starts_with("kotlin.ranges.") {
                return None;
            }
            let kind = if fqn.contains("Long") {
                RangeKind::Long
            } else if fqn.contains("Char") {
                RangeKind::Char
            } else if fqn.contains("Int") {
                RangeKind::Int
            } else {
                return None;
            };
            // IntProgression stores first/last/step; IntRange also exposes
            // start/endInclusive — accept whichever the lowered fields carry.
            let num = |names: &[&str]| -> Option<i64> {
                for n in names {
                    if let Some(val) = b.get(n) {
                        if let Some(i) = val.as_i64() {
                            return Some(i);
                        }
                        if let Value::Char(c) = val {
                            return Some(c as i64);
                        }
                    }
                }
                None
            };
            let start = num(&["first", "start"])?;
            let end = num(&["last", "endInclusive"])?;
            let step = num(&["step"]).unwrap_or(1);
            Some((start, end, step, kind))
        }
        _ => None,
    }
}

fn range_view_arg(ctx: &CallCtx, op: &str) -> Result<(i64, i64, i64, klio_runtime::RangeKind), RuntimeError> {
    ctx.args
        .first()
        .and_then(as_range_view)
        .ok_or_else(|| RuntimeError::Type(format!("{op} requires a Range receiver")))
}

fn range_first(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (start, _end, _step, kind) = range_view_arg(ctx, "first")?;
    Ok(range_endpoint(kind, start))
}

fn range_last(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (_start, end, _step, kind) = range_view_arg(ctx, "last")?;
    Ok(range_endpoint(kind, end))
}

fn range_step_field(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (_start, _end, step, kind) = range_view_arg(ctx, "step")?;
    Ok(range_endpoint(kind, step.abs()))
}

fn range_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (start, end, step, kind) = range_view_arg(ctx, "toString")?;
    let r = Value::Range { start, end, step, kind };
    Ok(Value::String(Arc::new(format!("{r}"))))
}

fn range_contains(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (start, end, step, _kind) = range_view_arg(ctx, "contains")?;
    let Some(n) = ctx.args.get(1).and_then(Value::as_i64) else {
        return Err(RuntimeError::Type("Range.contains requires an Int argument".into()));
    };
    let (lo, hi) = if step > 0 { (start, end) } else { (end, start) };
    let in_bounds = n >= lo && n <= hi;
    if !in_bounds {
        return Ok(Value::Bool(false));
    }
    let s = step.abs();
    Ok(Value::Bool(((n - start) % s).abs() == 0 || s == 1))
}

fn range_is_empty(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (start, end, step, _kind) = range_view_arg(ctx, "isEmpty")?;
    let empty = if step > 0 { start > end } else { start < end };
    Ok(Value::Bool(empty))
}

fn range_reversed(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (start, end, step, kind) = range_view_arg(ctx, "reversed")?;
    Ok(Value::Range { start: end, end: start, step: -step, kind })
}

fn range_to_list(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (start, end, step, kind) = range_view_arg(ctx, "toList")?;
    let items: Vec<Value> = range_iter_int(start, end, step)
        .map(|v| range_endpoint(kind, v))
        .collect();
    Ok(make_list(items, false))
}

fn range_count(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (start, end, step, _kind) = range_view_arg(ctx, "count")?;
    let n = range_iter_int(start, end, step).count() as i64;
    Ok(Value::new_int(n))
}

fn range_sum(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (start, end, step, kind) = range_view_arg(ctx, "sum")?;
    let s: i64 = range_iter_int(start, end, step).sum();
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
    Ok(Value::String(Arc::new(out)))
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
    Ok(Value::String(Arc::new(out)))
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
    Ok(Value::String(Arc::new(out)))
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
    Ok(Value::String(Arc::new(out)))
}

fn string_replace_first(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.replaceFirst")?;
    if let Some(Value::Regex(r)) = ctx.args.get(1) {
        let (r, s) = (Arc::clone(r), Arc::clone(s));
        let repl = ctx.args.get(2).cloned();
        return perform_regex_replace(ctx, &r, &s, repl, true, "replaceFirst");
    }
    let old = arg_as_string(
        ctx.args.get(1).ok_or_else(|| RuntimeError::Arity("replaceFirst requires old".into()))?,
        "replaceFirst",
    )?;
    let new = arg_as_string(
        ctx.args.get(2).ok_or_else(|| RuntimeError::Arity("replaceFirst requires new".into()))?,
        "replaceFirst",
    )?;
    Ok(Value::String(Arc::new(s.replacen(&old, &new, 1))))
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
    Ok(Value::String(Arc::new(out_lines.join("\n"))))
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
    Ok(Value::String(Arc::new(out_lines.join("\n"))))
}

fn string_lines(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.lines")?;
    // Kotlin lines() splits on \r\n, \r, and \n.
    let normalized = s.replace("\r\n", "\n").replace('\r', "\n");
    let items: Vec<Value> = normalized
        .split('\n')
        .map(|p| Value::String(Arc::new(p.to_string())))
        .collect();
    Ok(make_list(items, false))
}

fn string_to_char_array(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.toCharArray")?;
    Ok(make_list(s.chars().map(Value::Char).collect(), false))
}

fn string_to_long(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.toLong")?;
    let radix = recv_int_radix(ctx.args.get(1), "String.toLong")?;
    if !(2..=36).contains(&radix) {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IllegalArgumentException",
            Some(format!("radix {radix} was not in valid range 2..36")),
        )));
    }
    parse_int_radix(&s, radix as u32).map(Value::Long).map_err(|_| {
        RuntimeError::Thrown(make_exception(
            "kotlin.NumberFormatException",
            Some(format!("For input string: \"{s}\"")),
        ))
    })
}

fn string_to_long_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.toLongOrNull")?;
    let radix = match recv_int_radix(ctx.args.get(1), "String.toLongOrNull") {
        Ok(r) => r,
        Err(_) => return Ok(Value::Null),
    };
    if !(2..=36).contains(&radix) {
        return Ok(Value::Null);
    }
    Ok(parse_int_radix(&s, radix as u32).map(Value::Long).unwrap_or(Value::Null))
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

/// Single-Char case mapping: Kotlin's uppercaseChar()/lowercaseChar() return
/// the original char when the full case mapping isn't a single character
/// (e.g. 'ß'.uppercaseChar() == 'ß', not 'S' — only the multi-char
/// uppercase() yields "SS").
fn single_case_char(c: char, mut mapping: impl Iterator<Item = char>) -> char {
    let first = mapping.next().unwrap_or(c);
    if mapping.next().is_some() {
        c
    } else {
        first
    }
}
fn char_uppercase_char(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let c = recv_char(ctx.args, "Char.uppercaseChar")?;
    Ok(Value::Char(single_case_char(c, c.to_uppercase())))
}
fn char_lowercase_char(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let c = recv_char(ctx.args, "Char.lowercaseChar")?;
    Ok(Value::Char(single_case_char(c, c.to_lowercase())))
}
fn char_digit_to_int_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let c = recv_char(ctx.args, "Char.digitToIntOrNull")?;
    let radix = char_digit_radix(ctx.args)?;
    Ok(c.to_digit(radix).map(|d| Value::new_int(d)).unwrap_or(Value::Null))
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

/// `coerceIn` / `coerceAtLeast` / `coerceAtMost` for Long and Double
/// receivers (the Int forms have their own arms above). Composed from
/// `num_extreme` so the result keeps the receiver's numeric kind and
/// the same widening rules as `minOf`/`maxOf`.
/// `Int`/`Long`/… `floorDiv` — integer division rounded toward
/// negative infinity (Kotlin's `floorDiv`, distinct from `/` which
/// truncates toward zero). Result widens to `Long` if either operand
/// is `Long`, else `Int`.
/// `Int`/`Long`.countLeadingZeroBits() — leading zeros in the
/// two's-complement bit pattern (32 / 64 wide). Result is Int.
fn num_count_leading_zero_bits(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let recv = ctx
        .args
        .first()
        .ok_or_else(|| RuntimeError::Arity("countLeadingZeroBits".into()))?;
    let n = match recv {
        Value::Long(v) => (*v as u64).leading_zeros() as i32,
        Value::Int(v) => (*v as u32).leading_zeros() as i32,
        Value::Short(v) => (*v as u16).leading_zeros() as i32,
        Value::Byte(v) => (*v as u8).leading_zeros() as i32,
        other => {
            return Err(RuntimeError::Type(format!(
                "countLeadingZeroBits requires an integer, got {other:?}"
            )))
        }
    };
    Ok(Value::new_int(n as i64))
}

/// `Int`/`Long`.countTrailingZeroBits().
fn num_count_trailing_zero_bits(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let recv = ctx
        .args
        .first()
        .ok_or_else(|| RuntimeError::Arity("countTrailingZeroBits".into()))?;
    let n = match recv {
        Value::Long(v) => (*v as u64).trailing_zeros() as i32,
        Value::Int(v) => (*v as u32).trailing_zeros() as i32,
        Value::Short(v) => (*v as u16).trailing_zeros().min(16) as i32,
        Value::Byte(v) => (*v as u8).trailing_zeros().min(8) as i32,
        other => {
            return Err(RuntimeError::Type(format!(
                "countTrailingZeroBits requires an integer, got {other:?}"
            )))
        }
    };
    Ok(Value::new_int(n as i64))
}

/// `Int`/`Long`.countOneBits() (population count).
fn num_count_one_bits(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let recv = ctx
        .args
        .first()
        .ok_or_else(|| RuntimeError::Arity("countOneBits".into()))?;
    let n = match recv {
        Value::Long(v) => (*v as u64).count_ones() as i32,
        Value::Int(v) => (*v as u32).count_ones() as i32,
        Value::Short(v) => (*v as u16).count_ones() as i32,
        Value::Byte(v) => (*v as u8).count_ones() as i32,
        other => {
            return Err(RuntimeError::Type(format!(
                "countOneBits requires an integer, got {other:?}"
            )))
        }
    };
    Ok(Value::new_int(n as i64))
}

fn num_floor_div(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (a, b) = arg2(ctx, "floorDiv")?;
    let (x, y) = (
        a.as_i64()
            .ok_or_else(|| RuntimeError::Type("floorDiv requires integers".into()))?,
        b.as_i64()
            .ok_or_else(|| RuntimeError::Type("floorDiv requires integers".into()))?,
    );
    if y == 0 {
        return Err(RuntimeError::Thrown(Value::Exception {
            fqn: std::sync::Arc::new("kotlin.ArithmeticException".to_string()),
            message: Some(std::sync::Arc::new("/ by zero".to_string())),
            cause: None,
        }));
    }
    let mut q = x / y;
    let r = x % y;
    if r != 0 && ((r < 0) != (y < 0)) {
        q -= 1;
    }
    let wide = matches!(a, Value::Long(_)) || matches!(b, Value::Long(_));
    Ok(if wide {
        Value::Long(q)
    } else {
        Value::new_int(q)
    })
}

/// `Int`/`Long`/… `mod` — remainder whose sign follows the divisor
/// (Kotlin's `mod`, distinct from `%` whose sign follows the
/// dividend). Result widens to `Long` if either operand is `Long`.
fn num_mod(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (a, b) = arg2(ctx, "mod")?;
    let (x, y) = (
        a.as_i64()
            .ok_or_else(|| RuntimeError::Type("mod requires integers".into()))?,
        b.as_i64()
            .ok_or_else(|| RuntimeError::Type("mod requires integers".into()))?,
    );
    if y == 0 {
        return Err(RuntimeError::Thrown(Value::Exception {
            fqn: std::sync::Arc::new("kotlin.ArithmeticException".to_string()),
            message: Some(std::sync::Arc::new("/ by zero".to_string())),
            cause: None,
        }));
    }
    let mut r = x % y;
    if r != 0 && ((r < 0) != (y < 0)) {
        r += y;
    }
    let wide = matches!(a, Value::Long(_)) || matches!(b, Value::Long(_));
    Ok(if wide {
        Value::Long(r)
    } else {
        Value::new_int(r)
    })
}

fn num_coerce_in(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let recv = ctx
        .args
        .first()
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("coerceIn: missing receiver".into()))?;
    match &ctx.args[1..] {
        [Value::Range { start, end, .. }] => {
            let lo = num_extreme(&[recv, Value::Long(*start)], false, "coerceIn")?;
            num_extreme(&[lo, Value::Long(*end)], true, "coerceIn")
        }
        [min, max] => {
            let lo = num_extreme(&[recv, min.clone()], false, "coerceIn")?;
            num_extreme(&[lo, max.clone()], true, "coerceIn")
        }
        _ => Err(RuntimeError::Type(
            "coerceIn requires (min, max) or a range".into(),
        )),
    }
}

fn num_coerce_at_least(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let recv = ctx
        .args
        .first()
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("coerceAtLeast: missing receiver".into()))?;
    let min = ctx
        .args
        .get(1)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("coerceAtLeast requires a minimum".into()))?;
    num_extreme(&[recv, min], false, "coerceAtLeast")
}

fn num_coerce_at_most(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let recv = ctx
        .args
        .first()
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("coerceAtMost: missing receiver".into()))?;
    let max = ctx
        .args
        .get(1)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("coerceAtMost requires a maximum".into()))?;
    num_extreme(&[recv, max], true, "coerceAtMost")
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
        other.iter().all(|o| me.iter().any(|m| Value::structural_eq_boxed(m, o))),
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

fn coll_array_with_index(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let items = iterable_items(
        ctx.args.first().ok_or_else(|| RuntimeError::Type("Array.withIndex requires a receiver".into()))?,
        "Array.withIndex",
    )?;
    let indexed: Vec<Value> = items
        .into_iter()
        .enumerate()
        .map(|(i, v)| Value::Pair(Box::new(Value::new_int(i)), Box::new(v)))
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
    let removed = {
        let mut b = it.borrow_mut();
        if let Some(pos) = b.iter().position(|v| Value::structural_eq_boxed(v, arg)) {
            b.remove(pos);
            true
        } else {
            false
        }
    };
    if removed {
        sync_map_view(&ctx.args[0]);
    }
    Ok(Value::Bool(removed))
}

fn coll_mut_list_remove_all(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "MutableList.removeAll")?;
    let other: Vec<Value> = match ctx.args.get(1) {
        Some(Value::List { items, .. }) | Some(Value::Set { items, .. }) => items.borrow().clone(),
        _ => return Err(RuntimeError::Type("removeAll requires a collection".into())),
    };
    let changed = {
        let mut b = it.borrow_mut();
        let before = b.len();
        b.retain(|v| !other.iter().any(|o| Value::structural_eq_boxed(v, o)));
        b.len() != before
    };
    if changed {
        sync_map_view(&ctx.args[0]);
    }
    Ok(Value::Bool(changed))
}

fn coll_mut_list_retain_all(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "MutableList.retainAll")?;
    let other: Vec<Value> = match ctx.args.get(1) {
        Some(Value::List { items, .. }) | Some(Value::Set { items, .. }) => items.borrow().clone(),
        _ => return Err(RuntimeError::Type("retainAll requires a collection".into())),
    };
    let changed = {
        let mut b = it.borrow_mut();
        let before = b.len();
        b.retain(|v| other.iter().any(|o| Value::structural_eq_boxed(v, o)));
        b.len() != before
    };
    if changed {
        sync_map_view(&ctx.args[0]);
    }
    Ok(Value::Bool(changed))
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
        other.iter().all(|o| me.iter().any(|m| Value::structural_eq_boxed(m, o))),
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

fn coll_mut_set_add_all(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "MutableSet.addAll")?;
    let to_add: Vec<Value> = match ctx.args.get(1) {
        Some(Value::List { items, .. }) | Some(Value::Set { items, .. }) => items.borrow().clone(),
        _ => return Err(RuntimeError::Type("addAll requires a collection".into())),
    };
    let mut b = it.borrow_mut();
    let mut changed = false;
    for v in to_add {
        if !b.iter().any(|x| Value::structural_eq_boxed(x, &v)) {
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
        .find(|(k, _)| Value::structural_eq_boxed(k, key))
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
        .find(|(k, _)| Value::structural_eq_boxed(k, key))
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

/// `Map.toSortedMap()` / `toSortedMap(comparator)` — a map whose entries are
/// ordered by key. klio's Map preserves insertion order, so we return a new
/// Map with entries pre-sorted by key. The no-arg form sorts by natural key
/// order; a `naturalOrder()`/`reverseOrder()` Comparator is honored directly.
fn coll_map_to_sorted_map(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let recv = ctx
        .args
        .first()
        .ok_or_else(|| RuntimeError::Type("toSortedMap requires a Map receiver".into()))?;
    let mut entries = map_entries_clone(recv, "toSortedMap")?;
    // Optional comparator: support naturalOrder/reverseOrder (no selector
    // steps). A selector-based Comparator (compareBy { … }) would need to run
    // the selector lambda per key; not yet handled.
    let descending = match ctx.args.get(1) {
        None => false,
        Some(Value::Comparator { steps, descending }) if steps.is_empty() => *descending,
        Some(Value::Comparator { .. }) => {
            return Err(RuntimeError::Type(
                "toSortedMap with a selector comparator is not yet supported".into(),
            ));
        }
        Some(_) => {
            return Err(RuntimeError::Type(
                "toSortedMap expects a Comparator argument".into(),
            ));
        }
    };
    let mut err: Option<RuntimeError> = None;
    entries.sort_by(|a, b| {
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
    Ok(make_map(entries, false))
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
    // Upstream has four putAll overloads: putAll(Map) and
    // putAll(Array/Iterable/Sequence<Pair>). Accept a Map's entries
    // directly, or any Pair-bearing collection.
    let to_add: Vec<(Value, Value)> = match arg {
        Value::Map { entries, .. } => entries.borrow().clone(),
        Value::Array { items, .. }
        | Value::List { items, .. }
        | Value::Set { items, .. } => {
            pairs_from_values(&items.borrow(), "putAll")?
        }
        Value::Sequence(_) => {
            let seq = ctx.args[1].clone();
            let CallCtx { out, host, .. } = ctx;
            let items = materialise_sequence(&seq, *host, *out)?;
            pairs_from_values(&items, "putAll")?
        }
        _ => return Err(RuntimeError::Type(
            "putAll requires a Map or a collection of Pairs".into(),
        )),
    };
    let mut b = entries.borrow_mut();
    for (k, v) in to_add {
        if let Some(slot) = b.iter_mut().find(|(kk, _)| Value::structural_eq_boxed(kk, &k)) {
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
    Ok(Value::String(Arc::new(format!("{v}"))))
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
    Ok(Value::Comparator { steps: Arc::new(Vec::new()), descending: false })
}

fn comparator_reverse_order(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Comparator { steps: Arc::new(Vec::new()), descending: true })
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

fn result_success(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = ctx.args.first().cloned().unwrap_or(Value::Unit);
    Ok(Value::Result { ok: true, payload: Box::new(v) })
}

fn result_failure(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = ctx.args.first().cloned().unwrap_or(Value::Unit);
    Ok(Value::Result { ok: false, payload: Box::new(v) })
}

fn run_catching_impl(block: Value, ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let CallCtx { out, host, .. } = ctx;
    match host.invoke_callable(&block, &[], *out) {
        Ok(v) => Ok(Value::Result { ok: true, payload: Box::new(v) }),
        Err(RuntimeError::Thrown(e)) => Ok(Value::Result { ok: false, payload: Box::new(e) }),
        Err(e) => Err(e),
    }
}

fn result_run_catching(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    // Two forms:
    //   runCatching { … }    -> 1 arg (block)
    //   x.runCatching { … }  -> 2 args (receiver, block); receiver bound as `this`
    if ctx.args.len() == 1 {
        let block = ctx.args[0].clone();
        return run_catching_impl(block, ctx);
    }
    if ctx.args.len() == 2 {
        let recv = ctx.args[0].clone();
        let block = ctx.args[1].clone();
        let CallCtx { out, host, .. } = ctx;
        return match host.invoke_callable_with_this(&block, &[], &recv, *out) {
            Ok(v) => Ok(Value::Result { ok: true, payload: Box::new(v) }),
            Err(RuntimeError::Thrown(e)) => Ok(Value::Result { ok: false, payload: Box::new(e) }),
            Err(e) => Err(e),
        };
    }
    Err(RuntimeError::Arity("runCatching expects (block) or (receiver, block)".into()))
}

fn result_fold(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 3 {
        return Err(RuntimeError::Arity("Result.fold expects (receiver, onSuccess, onFailure)".into()));
    }
    let (ok, payload) = recv_result(ctx.args, "Result.fold")?;
    let payload = payload.clone();
    let on_success = ctx.args[1].clone();
    let on_failure = ctx.args[2].clone();
    let CallCtx { out, host, .. } = ctx;
    if ok {
        host.invoke_callable(&on_success, std::slice::from_ref(&payload), *out)
    } else {
        host.invoke_callable(&on_failure, std::slice::from_ref(&payload), *out)
    }
}

fn result_map(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("Result.map expects (receiver, block)".into()));
    }
    let (ok, payload) = recv_result(ctx.args, "Result.map")?;
    let payload = payload.clone();
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    if !ok {
        return Ok(Value::Result { ok: false, payload: Box::new(payload) });
    }
    let v = host.invoke_callable(&block, std::slice::from_ref(&payload), *out)?;
    Ok(Value::Result { ok: true, payload: Box::new(v) })
}

fn result_map_catching(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("Result.mapCatching expects (receiver, block)".into()));
    }
    let (ok, payload) = recv_result(ctx.args, "Result.mapCatching")?;
    let payload = payload.clone();
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    if !ok {
        return Ok(Value::Result { ok: false, payload: Box::new(payload) });
    }
    match host.invoke_callable(&block, std::slice::from_ref(&payload), *out) {
        Ok(v) => Ok(Value::Result { ok: true, payload: Box::new(v) }),
        Err(RuntimeError::Thrown(e)) => Ok(Value::Result { ok: false, payload: Box::new(e) }),
        Err(e) => Err(e),
    }
}

fn result_on_success(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("Result.onSuccess expects (receiver, block)".into()));
    }
    let recv = ctx.args[0].clone();
    let (ok, payload) = recv_result(ctx.args, "Result.onSuccess")?;
    let payload = payload.clone();
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    if ok {
        host.invoke_callable(&block, std::slice::from_ref(&payload), *out)?;
    }
    Ok(recv)
}

fn result_on_failure(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("Result.onFailure expects (receiver, block)".into()));
    }
    let recv = ctx.args[0].clone();
    let (ok, payload) = recv_result(ctx.args, "Result.onFailure")?;
    let payload = payload.clone();
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    if !ok {
        host.invoke_callable(&block, std::slice::from_ref(&payload), *out)?;
    }
    Ok(recv)
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

/// `kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED` — the
/// singleton a `suspendCoroutineUninterceptedOrReturn` block
/// returns to signal it parked rather than producing a value.
/// One logical instance, so `x === COROUTINE_SUSPENDED` holds for
/// any sentinel `x`.
fn coroutine_suspended_sentinel(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::CoroutineSuspended)
}

/// Process-global monotonic rendezvous-slot counter for the
/// `kotlin.coroutines` language layer. Process-global so cross-thread
/// resume routing (slot → owning runBlocking driver) cannot alias a
/// slot id minted on a different thread.
static CO_NEXT_SLOT: std::sync::atomic::AtomicI64 = std::sync::atomic::AtomicI64::new(1);

/// `__klio_co_newSlot()` — a fresh slot id for a `suspendCoroutine`
/// rendezvous.
fn coro_new_slot(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let id = CO_NEXT_SLOT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    Ok(Value::Long(id))
}

fn slot_arg(args: &[Value], who: &str) -> Result<i64, RuntimeError> {
    match args.first() {
        Some(Value::Long(l)) => Ok(*l),
        Some(Value::Int(i)) => Ok(i64::from(*i)),
        _ => Err(RuntimeError::Type(format!("{who}: slot must be Long"))),
    }
}

/// `__klio_co_park(slot)` — record the current activation as waiting
/// on `slot`, then suspend indefinitely. On resume the call yields
/// the `Result` delivered by `__klio_co_resume`.
fn coro_park(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let slot = slot_arg(ctx.args, "__klio_co_park")?;
    ctx.host.coroutine_park_slot(slot);
    Err(RuntimeError::Suspend(-1))
}

/// `__klio_co_armSlot(slot)` — bind the next suspension (even a
/// timed one) to `slot` without suspending now, so a suspend inside
/// a `suspendCoroutineUninterceptedOrReturn` block stays reachable
/// via the continuation's slot for preemptive cancellation.
fn coro_arm_slot(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let slot = slot_arg(ctx.args, "__klio_co_armSlot")?;
    ctx.host.coroutine_arm_slot(slot);
    Ok(Value::Unit)
}

/// `__klio_co_disarmSlot()` — cancel a pending arm (the block
/// returned a value without suspending).
fn coro_disarm_slot(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    ctx.host.coroutine_disarm_slot();
    Ok(Value::Unit)
}

/// `__klio_co_resume(slot, ok, value)` — deliver a `Result` to the
/// activation parked on `slot` and make it ready.
fn coro_resume(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let slot = slot_arg(ctx.args, "__klio_co_resume")?;
    let ok = matches!(ctx.args.get(1), Some(Value::Bool(true)));
    let payload = ctx.args.get(2).cloned().unwrap_or(Value::Null);
    let result = Value::Result { ok, payload: Box::new(payload) };
    ctx.host.coroutine_resume_external(slot, result, ctx.out);
    Ok(Value::Unit)
}

/// `__klio_co_runRoot(block)` — drive `block` as a cooperative
/// coroutine root to quiescence, returning its terminal value.
fn coro_run_root(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let block = match ctx.args.first() {
        Some(v) => v.clone(),
        None => {
            return Err(RuntimeError::Type(
                "__klio_co_runRoot: missing block".into(),
            ))
        }
    };
    ctx.host.coroutine_run_root(&block, ctx.out)
}

/// `Result.getOrThrow()` — the success value, or rethrow the
/// captured failure. Core to `Continuation.resumeWith`.
fn result_get_or_throw(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (ok, payload) = recv_result(ctx.args, "Result.getOrThrow")?;
    if ok {
        Ok(payload.clone())
    } else {
        Err(RuntimeError::Thrown(payload.clone()))
    }
}

fn result_get_or_else(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity(
            "Result.getOrElse expects (receiver, onFailure)".into(),
        ));
    }
    let (ok, payload) = recv_result(&ctx.args[..1], "Result.getOrElse")?;
    if ok {
        return Ok(payload.clone());
    }
    let payload = payload.clone();
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    host.invoke_callable(&block, std::slice::from_ref(&payload), *out)
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
    Ok(Value::String(Arc::new(s)))
}

// ============================================================
// Regex / MatchResult / MatchGroup
// ============================================================

use klio_runtime::{MatchData, MatchGroupData, RegexData};

fn regex_arg(args: &[Value], what: &str) -> Result<Arc<RegexData>, RuntimeError> {
    match args.first() {
        Some(Value::Regex(r)) => Ok(Arc::clone(r)),
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

fn compile_regex(pattern: &str) -> Result<Arc<RegexData>, RuntimeError> {
    let prepared = preprocess_pattern(pattern);
    match regex::Regex::new(&prepared) {
        Ok(re) => Ok(Arc::new(RegexData {
            pattern: Arc::new(pattern.to_string()),
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

fn build_match(re: &Arc<RegexData>, input: &Arc<String>, caps: regex::Captures<'_>) -> MatchData {
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
                    value: Arc::new(m.as_str().to_string()),
                    start,
                    end_inclusive,
                }));
            }
            None => groups.push(None),
        }
    }
    let end_byte = caps.get(0).map_or(0, |m| m.end());
    MatchData {
        input: Arc::clone(input),
        groups,
        end_byte,
        regex: Arc::clone(re),
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
    Ok(Value::String(Arc::clone(&r.pattern)))
}

fn regex_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let r = regex_arg(ctx.args, "Regex.toString")?;
    Ok(Value::String(Arc::clone(&r.pattern)))
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
        Some(c) => Ok(Value::Match(Arc::new(build_match(&r, &s, c)))),
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
        items.push(Value::Match(Arc::new(build_match(&r, &s, caps))));
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
        Ok(Value::Match(Arc::new(build_match(&r, &s, caps))))
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
        Ok(Value::Match(Arc::new(build_match(&r, &s, caps))))
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

/// Expand a Kotlin replacement template against a single match's
/// groups. Kotlin's syntax differs from Rust's: `$n` / `${n}` reference
/// a group by index, `${name}` references a named group, and `\`
/// escapes the next character (`\$` is a literal `$`, `\\` a literal
/// `\`). A `$` not followed by a digit or `{` is itself an error in
/// Kotlin; we emit it literally to stay total.
fn expand_kotlin_replacement(
    template: &str,
    regex: &RegexData,
    groups: &[Option<MatchGroupData>],
) -> String {
    let group_text = |idx: usize| -> &str {
        groups
            .get(idx)
            .and_then(|g| g.as_ref())
            .map(|g| g.value.as_str())
            .unwrap_or("")
    };
    let chars: Vec<char> = template.chars().collect();
    let mut out = String::with_capacity(template.len());
    let mut i = 0;
    while i < chars.len() {
        match chars[i] {
            '\\' => {
                if i + 1 < chars.len() {
                    out.push(chars[i + 1]);
                    i += 2;
                } else {
                    i += 1;
                }
            }
            '$' => {
                i += 1;
                if i < chars.len() && chars[i] == '{' {
                    i += 1;
                    let mut key = String::new();
                    while i < chars.len() && chars[i] != '}' {
                        key.push(chars[i]);
                        i += 1;
                    }
                    if i < chars.len() {
                        i += 1; // consume '}'
                    }
                    if let Ok(idx) = key.parse::<usize>() {
                        out.push_str(group_text(idx));
                    } else if let Some(idx) =
                        regex.re.capture_names().position(|n| n == Some(key.as_str()))
                    {
                        out.push_str(group_text(idx));
                    }
                } else {
                    let mut num = String::new();
                    while i < chars.len() && chars[i].is_ascii_digit() {
                        num.push(chars[i]);
                        i += 1;
                    }
                    if let Ok(idx) = num.parse::<usize>() {
                        out.push_str(group_text(idx));
                    } else {
                        out.push('$');
                    }
                }
            }
            c => {
                out.push(c);
                i += 1;
            }
        }
    }
    out
}

/// Shared engine for `Regex.replace` / `Regex.replaceFirst` and the
/// `String.replace(Regex, …)` family. `repl` is either a `String`
/// template (Kotlin `$group` substitution) or a callable
/// `(MatchResult) -> CharSequence`.
fn perform_regex_replace(
    ctx: &mut CallCtx,
    r: &Arc<RegexData>,
    s: &Arc<String>,
    repl: Option<Value>,
    first_only: bool,
    who: &str,
) -> Result<Value, RuntimeError> {
    match repl {
        Some(Value::String(template)) => {
            let mut out = String::with_capacity(s.len());
            let mut last = 0usize;
            for caps in r.re.captures_iter(s) {
                let m0 = caps.get(0).unwrap();
                out.push_str(&s[last..m0.start()]);
                last = m0.end();
                let md = build_match(r, s, caps);
                out.push_str(&expand_kotlin_replacement(&template, r, &md.groups));
                if first_only {
                    break;
                }
            }
            out.push_str(&s[last..]);
            Ok(Value::String(Arc::new(out)))
        }
        Some(block) => {
            // Collect match spans first so the call-back borrow of `ctx`
            // does not overlap the regex iterator's borrow of `s`.
            let mut spans: Vec<(usize, usize, MatchData)> = Vec::new();
            for caps in r.re.captures_iter(s) {
                let m0 = caps.get(0).unwrap();
                let (start, end) = (m0.start(), m0.end());
                spans.push((start, end, build_match(r, s, caps)));
                if first_only {
                    break;
                }
            }
            let mut out = String::with_capacity(s.len());
            let mut last = 0usize;
            let CallCtx { out: sink, host, .. } = ctx;
            for (start, end, md) in spans {
                out.push_str(&s[last..start]);
                last = end;
                let mr = Value::Match(Arc::new(md));
                let rv = host.invoke_callable(&block, std::slice::from_ref(&mr), *sink)?;
                match rv {
                    Value::String(rs) => out.push_str(&rs),
                    Value::Char(c) => out.push(c),
                    other => {
                        return Err(RuntimeError::Type(format!(
                            "{who} transform must return a CharSequence, got {other:?}"
                        )))
                    }
                }
            }
            out.push_str(&s[last..]);
            Ok(Value::String(Arc::new(out)))
        }
        None => Err(RuntimeError::Arity(format!("{who} requires a replacement"))),
    }
}

fn regex_replace(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let r = regex_arg(ctx.args, "Regex.replace")?;
    let s = match ctx.args.get(1) {
        Some(Value::String(s)) => s.clone(),
        _ => return Err(RuntimeError::Type("Regex.replace requires a String".into())),
    };
    let repl = ctx.args.get(2).cloned();
    perform_regex_replace(ctx, &r, &s, repl, false, "Regex.replace")
}

fn regex_replace_first(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let r = regex_arg(ctx.args, "Regex.replaceFirst")?;
    let s = match ctx.args.get(1) {
        Some(Value::String(s)) => s.clone(),
        _ => return Err(RuntimeError::Type("Regex.replaceFirst requires a String".into())),
    };
    let repl = ctx.args.get(2).cloned();
    perform_regex_replace(ctx, &r, &s, repl, true, "Regex.replaceFirst")
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
        .map(|p| Value::String(Arc::new(p.to_string())))
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
    Ok(Value::String(Arc::new(kotlin_literal_escape(&s))))
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
    Ok(Value::String(Arc::new(out)))
}

fn match_arg(args: &[Value], what: &str) -> Result<Arc<MatchData>, RuntimeError> {
    match args.first() {
        Some(Value::Match(m)) => Ok(Arc::clone(m)),
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
    Ok(Value::String(Arc::clone(&g0.value)))
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
            Some(gd) => Value::String(Arc::clone(&gd.value)),
            None => Value::String(Arc::new(String::new())),
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
                value: Arc::clone(&gd.value),
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
        Some(c) => Ok(Value::Match(Arc::new(build_match(&m.regex, &m.input, c)))),
        None => Ok(Value::Null),
    }
}

fn match_result_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let m = match_arg(ctx.args, "MatchResult.toString")?;
    let g0 = m.groups.first().and_then(|g| g.as_ref());
    Ok(Value::String(Arc::new(
        g0.map(|g| (*g.value).clone()).unwrap_or_default(),
    )))
}

fn match_group_value(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    match ctx.args.first() {
        Some(Value::MatchGroup { value, .. }) => Ok(Value::String(Arc::clone(value))),
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

fn sb_arg(args: &[Value], what: &str) -> Result<ObjRef<String>, RuntimeError> {
    match args.first() {
        Some(Value::StringBuilder(s)) => Ok(s.clone()),
        _ => Err(RuntimeError::Type(format!(
            "{what} requires a StringBuilder receiver"
        ))),
    }
}

/// `String()` / `String(chars: CharArray)` / `String(chars, offset, length)`
/// / `String(other: CharSequence)`. klio registers `String` as a host ctor so
/// these shapes don't hit a 0-arg-only declaration.
fn string_ctor(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = match ctx.args.first() {
        None => String::new(),
        // CharArray is a Value::Array, but some producers (e.g. toCharArray)
        // yield a Value::List of chars — accept either.
        Some(Value::Array { items, .. }) | Some(Value::List { items, .. }) => {
            let chars = items.borrow();
            let (start, count) = if ctx.args.len() >= 3 {
                let off = ctx.args[1].as_i64().unwrap_or(0).max(0) as usize;
                let cnt = ctx.args[2].as_i64().unwrap_or(0).max(0) as usize;
                (off, cnt)
            } else {
                (0, chars.len())
            };
            let end = start.saturating_add(count).min(chars.len());
            if start > chars.len() || end > chars.len() {
                return Err(RuntimeError::Thrown(make_exception(
                    "kotlin.IndexOutOfBoundsException",
                    Some(format!("offset {start}, count {count}, size {}", chars.len())),
                )));
            }
            chars[start..end]
                .iter()
                .map(|v| match v {
                    Value::Char(c) => *c,
                    _ => '\u{0}',
                })
                .collect()
        }
        Some(Value::String(s)) => (**s).clone(),
        Some(Value::StringBuilder(sb)) => sb.borrow().clone(),
        Some(other) => format!("{other}"),
    };
    Ok(Value::String(Arc::new(s)))
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
    Ok(Value::StringBuilder(ObjRef::new(seed)))
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
    Ok(Value::String(Arc::new(sb.borrow().clone())))
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
    Ok(Value::String(Arc::new(buf[sb_byte..eb_byte].to_string())))
}

fn string_builder_set_char_at(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.setCharAt")?;
    let idx = match ctx.args.get(1).and_then(Value::as_i64) {
        Some(n) => n,
        _ => return Err(RuntimeError::Type("setCharAt index must be Int".into())),
    };
    let ch = match ctx.args.get(2) {
        Some(Value::Char(c)) => *c,
        _ => return Err(RuntimeError::Type("setCharAt requires a Char".into())),
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
    let old = buf[byte..].chars().next().unwrap();
    buf.replace_range(byte..byte + old.len_utf8(), &ch.to_string());
    drop(buf);
    Ok(Value::Unit)
}

/// `replace(startIndex, endIndex, newString)` — splice `newString` over the
/// `[start, end)` char range. Returns the builder (Kotlin/JVM semantics).
fn string_builder_replace(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.replace")?;
    let start = match ctx.args.get(1).and_then(Value::as_i64) {
        Some(n) => n,
        _ => return Err(RuntimeError::Type("replace start must be Int".into())),
    };
    let end = match ctx.args.get(2).and_then(Value::as_i64) {
        Some(n) => n,
        _ => return Err(RuntimeError::Type("replace end must be Int".into())),
    };
    let repl = match ctx.args.get(3) {
        Some(Value::String(s)) => (**s).clone(),
        Some(other) => format!("{other}"),
        None => return Err(RuntimeError::Type("replace requires a replacement string".into())),
    };
    let mut buf = sb.borrow_mut();
    let n = buf.chars().count() as i64;
    if start < 0 || start > n || start > end {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IndexOutOfBoundsException",
            Some(format!("start {start}, end {end}, length {n}")),
        )));
    }
    // Kotlin/JVM clamps the end to the current length.
    let end = end.min(n);
    let sb_byte = sb_char_byte(&buf, start).unwrap();
    let eb_byte = sb_char_byte(&buf, end).unwrap();
    buf.replace_range(sb_byte..eb_byte, &repl);
    drop(buf);
    Ok(Value::StringBuilder(sb))
}

fn string_builder_last_index(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.lastIndex")?;
    let n = sb.borrow().chars().count() as i64;
    Ok(Value::new_int(n - 1))
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
    Ok(Value::String(Arc::new(format_kotlin(&fmt, &args)?)))
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
    Ok(Value::String(Arc::new(s)))
}

fn char_titlecase_char(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let c = match ctx.args.first() {
        Some(Value::Char(c)) => *c,
        _ => return Err(RuntimeError::Type(
            "Char.titlecaseChar requires a Char receiver".into(),
        )),
    };
    // Title-case 1:1 mapping — for chars without a specific title form this
    // is the uppercase mapping, and (like uppercaseChar) the original char
    // when the uppercase mapping isn't a single character ('ß' -> 'ß').
    Ok(Value::Char(single_case_char(c, c.to_uppercase())))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(fn_: StdlibFn, args: &[Value]) -> Result<Value, RuntimeError> {
        let mut out = klio_runtime::CaptureOutput::default();
        let mut host = klio_runtime::NoopHost::default();
        fn_(&mut CallCtx { args, out: &mut out, host: &mut host })
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
        let s = Value::String(Arc::new("héllo".to_string()));
        assert!(matches!(call(string_length, &[s]), Ok(Value::Int(5))));
    }

    #[test]
    fn string_get_returns_char() {
        let s = Value::String(Arc::new("abc".to_string()));
        assert!(matches!(call(string_get, &[s, Value::Int(1)]), Ok(Value::Char('b'))));
    }

    #[test]
    fn string_get_out_of_bounds_throws() {
        let s = Value::String(Arc::new("abc".to_string()));
        let err = call(string_get, &[s, Value::Int(99)]).unwrap_err();
        assert!(matches!(err, RuntimeError::Thrown(Value::Exception { .. })));
    }

    #[test]
    fn string_substring_two_args() {
        let s = Value::String(Arc::new("abcdef".to_string()));
        let Ok(Value::String(out)) = call(string_substring, &[s, Value::Int(1), Value::Int(4)]) else { panic!() };
        assert_eq!(*out, "bcd");
    }

    #[test]
    fn string_repeat_and_reversed() {
        let s = Value::String(Arc::new("ab".to_string()));
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
        let s = Value::String(Arc::new("a.b.c".to_string()));
        let Ok(Value::String(before)) = call(string_substring_before, &[s.clone(), Value::String(Arc::new(".".into()))]) else { panic!() };
        assert_eq!(*before, "a");
        let Ok(Value::String(after)) = call(string_substring_after_last, &[s, Value::String(Arc::new(".".into()))]) else { panic!() };
        assert_eq!(*after, "c");
    }

    #[test]
    fn map_get_or_default_falls_back() {
        let m = make_map(vec![(Value::String(Arc::new("a".into())), Value::Int(1))], false);
        let Ok(v) = call(coll_map_get_or_default, &[m.clone(), Value::String(Arc::new("a".into())), Value::Int(99)]) else { panic!() };
        assert!(matches!(v, Value::Int(1)));
        let Ok(v) = call(coll_map_get_or_default, &[m, Value::String(Arc::new("z".into())), Value::Int(99)]) else { panic!() };
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
        let s = Value::String(Arc::new("a\nb\r\nc\rd".to_string()));
        let Ok(Value::List { items, .. }) = call(string_lines, &[s]) else { panic!() };
        assert_eq!(items.borrow().len(), 4);
    }

    #[test]
    fn regex_find_returns_match() {
        let re = call(regex_ctor, &[Value::String(Arc::new(r"\d+".into()))]).unwrap();
        let v = call(regex_find, &[re, Value::String(Arc::new("abc 123 def".into()))]).unwrap();
        let Value::Match(m) = v else { panic!() };
        assert_eq!(*m.groups[0].as_ref().unwrap().value, "123");
    }

    #[test]
    fn string_builder_append_and_length() {
        let sb = call(string_builder_ctor, &[]).unwrap();
        call(string_builder_append, &[sb.clone(), Value::String(Arc::new("ab".into()))]).unwrap();
        call(string_builder_append, &[sb.clone(), Value::Int(7)]).unwrap();
        let Value::Int(n) = call(string_builder_length, &[sb.clone()]).unwrap() else { panic!() };
        assert_eq!(n, 3);
        let Value::String(s) = call(string_builder_to_string, &[sb]).unwrap() else { panic!() };
        assert_eq!(&*s, "ab7");
    }

    #[test]
    fn format_basic_specifiers() {
        let fmt = Value::String(Arc::new("%d-%s".into()));
        let Value::String(s) = call(
            string_format_static,
            &[fmt, Value::Int(7), Value::String(Arc::new("x".into()))],
        ).unwrap() else { panic!() };
        assert_eq!(&*s, "7-x");
    }

    #[test]
    fn excn_constructors_carry_message() {
        let Ok(Value::Exception { fqn, message, .. }) = call(
            excn_illegal_argument,
            &[Value::String(Arc::new("bad".into()))],
        ) else { panic!() };
        assert_eq!(*fqn, "kotlin.IllegalArgumentException");
        assert_eq!(message.as_deref().map(|s| s.as_str()), Some("bad"));
    }
}
