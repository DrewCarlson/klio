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

pub(crate) use std::io::BufRead;
pub(crate) use std::sync::Arc;

pub(crate) use klio_runtime::{
    CallCtx, ObjRef, RuntimeError, StdlibFn, Value, char_unit_to_string, char_units_to_string,
};

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
    (
        "kotlin.concurrent.Thread.currentThread",
        concurrent_thread_current,
    ),
    // ----- kotlin.time platform clock bindings -----
    // Backing for the klio `actual`s of kotlin.time's `internal expect`
    // wall/monotonic clock (kotlin-time/Actuals.kt). The rest of
    // kotlin.time is consumed verbatim from upstream commonMain.
    ("kotlin.time.__klio_time_systemMillis", time_system_millis),
    (
        "kotlin.time.__klio_time_monotonicNanos",
        time_monotonic_nanos,
    ),
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
    // String <-> ByteArray (UTF-8). Upstream declares these without a
    // klio-runnable body; without them every `encodeToByteArray` /
    // `toByteArray` returns the receiver and ByteString construction
    // silently no-ops.
    ("kotlin.String.toByteArray", string_to_byte_array),
    ("kotlin.String.encodeToByteArray", string_to_byte_array),
    (
        "kotlin.ByteArray.decodeToString",
        byte_array_decode_to_string,
    ),
    ("kotlin.String.lastIndexOf", string_last_index_of),
    ("kotlin.String.length", string_length),
    ("kotlin.String.lowercase", string_lowercase),
    ("kotlin.String.plus", string_plus),
    ("kotlin.String.equals", string_equals),
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
    (
        "kotlin.CharSequence.splitToSequence",
        string_split_to_sequence,
    ),
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
    (
        "kotlin.internal.getProgressionLastElement",
        internal_get_progression_last_element,
    ),
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
    ("kotlin.Double.toRawBits", double_to_raw_bits),
    ("kotlin.Double.toBits", double_to_bits),
    ("kotlin.Double.fromBits", double_from_bits),
    ("kotlin.Double.Companion.fromBits", double_from_bits),
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
    ("kotlin.Float.toRawBits", float_to_raw_bits),
    ("kotlin.Float.toBits", float_to_bits),
    ("kotlin.Float.fromBits", float_from_bits),
    ("kotlin.Float.Companion.fromBits", float_from_bits),
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
    (
        "kotlin.ConcurrentModificationException",
        excn_concurrent_mod,
    ),
    ("kotlin.AssertionError", excn_assertion_error),
    // ----- Throwable members -----
    ("kotlin.Throwable.message", throwable_message),
    ("kotlin.Throwable.cause", throwable_cause),
    ("kotlin.Throwable.toString", throwable_to_string),
    ("kotlin.Throwable.addSuppressed", throwable_add_suppressed),
    ("kotlin.Throwable.getSuppressed", throwable_suppressed),
    (
        "kotlin.Throwable.suppressedExceptions",
        throwable_suppressed,
    ),
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
    (
        "kotlin.collections.Collection.toTypedArray",
        coll_to_typed_array,
    ),
    (
        "kotlin.collections.Iterable.toTypedArray",
        coll_to_typed_array,
    ),
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
    (
        "kotlin.collections.List.indexOfFirst",
        coll_iter_index_of_first,
    ),
    ("kotlin.collections.List.foldRight", coll_list_fold_right),
    ("kotlin.collections.Array.foldRight", coll_list_fold_right),
    ("kotlin.Array.foldRight", coll_list_fold_right),
    (
        "kotlin.collections.List.reduceRight",
        coll_list_reduce_right,
    ),
    (
        "kotlin.collections.Array.reduceRight",
        coll_list_reduce_right,
    ),
    ("kotlin.Array.reduceRight", coll_list_reduce_right),
    (
        "kotlin.collections.List.reduceRightOrNull",
        coll_list_reduce_right_or_null,
    ),
    (
        "kotlin.Array.reduceRightOrNull",
        coll_list_reduce_right_or_null,
    ),
    ("kotlin.collections.List.last", coll_list_last),
    ("kotlin.collections.Set.last", coll_list_last),
    ("kotlin.collections.Iterable.last", coll_list_last),
    ("kotlin.Array.last", coll_list_last),
    ("kotlin.collections.List.lastOrNull", coll_list_last_or_null),
    ("kotlin.collections.Set.lastOrNull", coll_list_last_or_null),
    (
        "kotlin.collections.Iterable.lastOrNull",
        coll_list_last_or_null,
    ),
    ("kotlin.Array.lastOrNull", coll_list_last_or_null),
    ("kotlin.collections.List.findLast", coll_list_last_or_null),
    ("kotlin.collections.Set.findLast", coll_list_last_or_null),
    (
        "kotlin.collections.Iterable.findLast",
        coll_list_last_or_null,
    ),
    ("kotlin.Array.findLast", coll_list_last_or_null),
    (
        "kotlin.collections.List.indexOfLast",
        coll_iter_index_of_last,
    ),
    (
        "kotlin.collections.MutableList.indexOfFirst",
        coll_iter_index_of_first,
    ),
    (
        "kotlin.collections.MutableList.indexOfLast",
        coll_iter_index_of_last,
    ),
    (
        "kotlin.collections.Iterable.indexOfFirst",
        coll_iter_index_of_first,
    ),
    (
        "kotlin.collections.Iterable.indexOfLast",
        coll_iter_index_of_last,
    ),
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
    // Bulk array copy / fill. Upstream declares these `expect` with no
    // body for klio to supply; without these actuals every ByteArray
    // copy (and kotlinx-io's segment data path) silently no-ops.
    ("kotlin.Array.copyInto", array_copy_into),
    ("kotlin.IntArray.copyInto", array_copy_into),
    ("kotlin.LongArray.copyInto", array_copy_into),
    ("kotlin.DoubleArray.copyInto", array_copy_into),
    ("kotlin.FloatArray.copyInto", array_copy_into),
    ("kotlin.ShortArray.copyInto", array_copy_into),
    ("kotlin.ByteArray.copyInto", array_copy_into),
    ("kotlin.CharArray.copyInto", array_copy_into),
    ("kotlin.BooleanArray.copyInto", array_copy_into),
    ("kotlin.UIntArray.copyInto", array_copy_into),
    ("kotlin.ULongArray.copyInto", array_copy_into),
    ("kotlin.UShortArray.copyInto", array_copy_into),
    ("kotlin.UByteArray.copyInto", array_copy_into),
    ("kotlin.Array.copyOf", array_copy_of),
    ("kotlin.IntArray.copyOf", array_copy_of),
    ("kotlin.LongArray.copyOf", array_copy_of),
    ("kotlin.DoubleArray.copyOf", array_copy_of),
    ("kotlin.FloatArray.copyOf", array_copy_of),
    ("kotlin.ShortArray.copyOf", array_copy_of),
    ("kotlin.ByteArray.copyOf", array_copy_of),
    ("kotlin.CharArray.copyOf", array_copy_of),
    ("kotlin.BooleanArray.copyOf", array_copy_of),
    ("kotlin.UIntArray.copyOf", array_copy_of),
    ("kotlin.ULongArray.copyOf", array_copy_of),
    ("kotlin.UShortArray.copyOf", array_copy_of),
    ("kotlin.UByteArray.copyOf", array_copy_of),
    ("kotlin.Array.copyOfRange", array_copy_of_range),
    ("kotlin.IntArray.copyOfRange", array_copy_of_range),
    ("kotlin.LongArray.copyOfRange", array_copy_of_range),
    ("kotlin.DoubleArray.copyOfRange", array_copy_of_range),
    ("kotlin.FloatArray.copyOfRange", array_copy_of_range),
    ("kotlin.ShortArray.copyOfRange", array_copy_of_range),
    ("kotlin.ByteArray.copyOfRange", array_copy_of_range),
    ("kotlin.CharArray.copyOfRange", array_copy_of_range),
    ("kotlin.BooleanArray.copyOfRange", array_copy_of_range),
    ("kotlin.UIntArray.copyOfRange", array_copy_of_range),
    ("kotlin.ULongArray.copyOfRange", array_copy_of_range),
    ("kotlin.UShortArray.copyOfRange", array_copy_of_range),
    ("kotlin.UByteArray.copyOfRange", array_copy_of_range),
    ("kotlin.Array.fill", array_fill),
    ("kotlin.IntArray.fill", array_fill),
    ("kotlin.LongArray.fill", array_fill),
    ("kotlin.DoubleArray.fill", array_fill),
    ("kotlin.FloatArray.fill", array_fill),
    ("kotlin.ShortArray.fill", array_fill),
    ("kotlin.ByteArray.fill", array_fill),
    ("kotlin.CharArray.fill", array_fill),
    ("kotlin.BooleanArray.fill", array_fill),
    ("kotlin.UIntArray.fill", array_fill),
    ("kotlin.ULongArray.fill", array_fill),
    ("kotlin.UShortArray.fill", array_fill),
    ("kotlin.UByteArray.fill", array_fill),
    // Structural content equality / rendering. Also unimplemented
    // `expect`/`infix` extensions; without these `a.contentEquals(b)` and
    // `a.contentToString()` no-op to `Unit`.
    ("kotlin.Array.contentEquals", array_content_equals),
    ("kotlin.IntArray.contentEquals", array_content_equals),
    ("kotlin.LongArray.contentEquals", array_content_equals),
    ("kotlin.DoubleArray.contentEquals", array_content_equals),
    ("kotlin.FloatArray.contentEquals", array_content_equals),
    ("kotlin.ShortArray.contentEquals", array_content_equals),
    ("kotlin.ByteArray.contentEquals", array_content_equals),
    ("kotlin.CharArray.contentEquals", array_content_equals),
    ("kotlin.BooleanArray.contentEquals", array_content_equals),
    ("kotlin.UIntArray.contentEquals", array_content_equals),
    ("kotlin.ULongArray.contentEquals", array_content_equals),
    ("kotlin.UShortArray.contentEquals", array_content_equals),
    ("kotlin.UByteArray.contentEquals", array_content_equals),
    ("kotlin.Array.contentToString", array_content_to_string),
    ("kotlin.IntArray.contentToString", array_content_to_string),
    ("kotlin.LongArray.contentToString", array_content_to_string),
    ("kotlin.DoubleArray.contentToString", array_content_to_string),
    ("kotlin.FloatArray.contentToString", array_content_to_string),
    ("kotlin.ShortArray.contentToString", array_content_to_string),
    ("kotlin.ByteArray.contentToString", array_content_to_string),
    ("kotlin.CharArray.contentToString", array_content_to_string),
    ("kotlin.BooleanArray.contentToString", array_content_to_string),
    ("kotlin.UIntArray.contentToString", array_content_to_string),
    ("kotlin.ULongArray.contentToString", array_content_to_string),
    ("kotlin.UShortArray.contentToString", array_content_to_string),
    ("kotlin.UByteArray.contentToString", array_content_to_string),
    // Indexed access / concatenation. Also unimplemented `expect`s; a
    // missing actual made `elementAt` no-op and `plus` fall through to a
    // raw `BinOp::Add` error.
    ("kotlin.Array.elementAt", array_element_at),
    ("kotlin.IntArray.elementAt", array_element_at),
    ("kotlin.LongArray.elementAt", array_element_at),
    ("kotlin.DoubleArray.elementAt", array_element_at),
    ("kotlin.FloatArray.elementAt", array_element_at),
    ("kotlin.ShortArray.elementAt", array_element_at),
    ("kotlin.ByteArray.elementAt", array_element_at),
    ("kotlin.CharArray.elementAt", array_element_at),
    ("kotlin.BooleanArray.elementAt", array_element_at),
    ("kotlin.UIntArray.elementAt", array_element_at),
    ("kotlin.ULongArray.elementAt", array_element_at),
    ("kotlin.UShortArray.elementAt", array_element_at),
    ("kotlin.UByteArray.elementAt", array_element_at),
    ("kotlin.Array.plus", array_plus),
    ("kotlin.IntArray.plus", array_plus),
    ("kotlin.LongArray.plus", array_plus),
    ("kotlin.DoubleArray.plus", array_plus),
    ("kotlin.FloatArray.plus", array_plus),
    ("kotlin.ShortArray.plus", array_plus),
    ("kotlin.ByteArray.plus", array_plus),
    ("kotlin.CharArray.plus", array_plus),
    ("kotlin.BooleanArray.plus", array_plus),
    ("kotlin.UIntArray.plus", array_plus),
    ("kotlin.ULongArray.plus", array_plus),
    ("kotlin.UShortArray.plus", array_plus),
    ("kotlin.UByteArray.plus", array_plus),
    ("kotlin.Array.plusElement", array_plus_element),
    // In-place natural-order sort (no-arg and (fromIndex, toIndex)).
    // Also an unimplemented `expect`; without it `sort()` no-ops and
    // `sortedArray`/`sortDescending`, which delegate to it, are wrong.
    ("kotlin.Array.sort", array_sort),
    ("kotlin.IntArray.sort", array_sort),
    ("kotlin.LongArray.sort", array_sort),
    ("kotlin.DoubleArray.sort", array_sort),
    ("kotlin.FloatArray.sort", array_sort),
    ("kotlin.ShortArray.sort", array_sort),
    ("kotlin.ByteArray.sort", array_sort),
    ("kotlin.CharArray.sort", array_sort),
    ("kotlin.UIntArray.sort", array_sort),
    ("kotlin.ULongArray.sort", array_sort),
    ("kotlin.UShortArray.sort", array_sort),
    ("kotlin.UByteArray.sort", array_sort),
    // Comparator-ordered in-place sort. Only Array<T> has sortWith in
    // the stdlib (primitive arrays take a natural order); register the
    // generic form plus the typed-name klio may resolve it under.
    ("kotlin.Array.sortWith", array_sort_with),
    ("kotlin.collections.Array.sortWith", array_sort_with),
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
    (
        "kotlin.BooleanArray.joinToString",
        coll_array_join_to_string,
    ),
    ("kotlin.LongArray.isEmpty", array_is_empty),
    ("kotlin.LongArray.isNotEmpty", array_is_not_empty),
    ("kotlin.ByteArray.isEmpty", array_is_empty),
    ("kotlin.ByteArray.isNotEmpty", array_is_not_empty),
    ("kotlin.CharArray.isEmpty", array_is_empty),
    ("kotlin.CharArray.isNotEmpty", array_is_not_empty),
    ("kotlin.collections.List.isEmpty", coll_list_is_empty),
    ("kotlin.collections.List.isNotEmpty", coll_list_is_not_empty),
    (
        "kotlin.collections.List.joinToString",
        coll_list_join_to_string,
    ),
    (
        "kotlin.collections.Set.joinToString",
        coll_list_join_to_string,
    ),
    (
        "kotlin.collections.MutableSet.joinToString",
        coll_list_join_to_string,
    ),
    (
        "kotlin.collections.Iterable.joinToString",
        coll_list_join_to_string,
    ),
    (
        "kotlin.collections.Collection.joinToString",
        coll_list_join_to_string,
    ),
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
    (
        "kotlin.collections.List.lastIndexOf",
        coll_list_last_index_of,
    ),
    ("kotlin.collections.List.minus", coll_list_minus),
    ("kotlin.collections.List.plus", coll_list_plus),
    ("kotlin.collections.List.reversed", coll_list_reversed),
    ("kotlin.collections.List.size", coll_list_size),
    ("kotlin.collections.List.slice", coll_list_slice),
    ("kotlin.collections.List.sorted", coll_list_sorted),
    (
        "kotlin.collections.List.sortedDescending",
        coll_list_sorted_descending,
    ),
    ("kotlin.collections.List.subList", coll_list_sublist),
    ("kotlin.collections.List.takeLast", coll_list_take_last),
    ("kotlin.collections.List.windowed", coll_list_windowed),
    ("kotlin.collections.List.zip", coll_list_zip),
    ("kotlin.collections.List.toString", coll_list_to_string),
    ("kotlin.collections.MutableList.add", coll_mut_list_add),
    ("kotlin.collections.MutableList.clear", coll_mut_list_clear),
    (
        "kotlin.collections.MutableList.contains",
        coll_list_contains,
    ),
    ("kotlin.collections.MutableList.get", coll_list_get),
    ("kotlin.collections.MutableList.indexOf", coll_list_index_of),
    ("kotlin.collections.MutableList.isEmpty", coll_list_is_empty),
    (
        "kotlin.collections.MutableList.isNotEmpty",
        coll_list_is_not_empty,
    ),
    (
        "kotlin.collections.MutableList.joinToString",
        coll_list_join_to_string,
    ),
    ("kotlin.collections.MutableList.average", coll_list_average),
    ("kotlin.collections.MutableList.chunked", coll_list_chunked),
    ("kotlin.collections.MutableList.indices", coll_list_indices),
    (
        "kotlin.collections.MutableList.lastIndex",
        coll_list_last_index,
    ),
    ("kotlin.collections.MutableList.max", coll_list_max_or_null),
    (
        "kotlin.collections.MutableList.maxOrNull",
        coll_list_max_or_null,
    ),
    ("kotlin.collections.MutableList.min", coll_list_min_or_null),
    (
        "kotlin.collections.MutableList.minOrNull",
        coll_list_min_or_null,
    ),
    ("kotlin.collections.MutableList.sum", coll_list_sum),
    ("kotlin.collections.MutableList.toMap", coll_list_to_map),
    (
        "kotlin.collections.MutableList.distinct",
        coll_list_distinct,
    ),
    (
        "kotlin.collections.MutableList.dropLast",
        coll_list_drop_last,
    ),
    (
        "kotlin.collections.MutableList.lastIndexOf",
        coll_list_last_index_of,
    ),
    ("kotlin.collections.MutableList.minus", coll_list_minus),
    ("kotlin.collections.MutableList.plus", coll_list_plus),
    (
        "kotlin.collections.MutableList.removeAt",
        coll_mut_list_remove_at,
    ),
    (
        "kotlin.collections.MutableList.addFirst",
        coll_mut_list_add_first,
    ),
    ("kotlin.collections.MutableList.addLast", coll_mut_list_add),
    (
        "kotlin.collections.MutableList.removeFirst",
        coll_mut_list_remove_first,
    ),
    (
        "kotlin.collections.MutableList.removeLast",
        coll_mut_list_remove_last,
    ),
    (
        "kotlin.collections.MutableList.reversed",
        coll_list_reversed,
    ),
    ("kotlin.collections.MutableList.size", coll_list_size),
    ("kotlin.collections.MutableList.slice", coll_list_slice),
    ("kotlin.collections.MutableList.sorted", coll_list_sorted),
    (
        "kotlin.collections.MutableList.sortedDescending",
        coll_list_sorted_descending,
    ),
    ("kotlin.collections.MutableList.subList", coll_list_sublist),
    (
        "kotlin.collections.MutableList.takeLast",
        coll_list_take_last,
    ),
    (
        "kotlin.collections.MutableList.windowed",
        coll_list_windowed,
    ),
    ("kotlin.collections.MutableList.zip", coll_list_zip),
    (
        "kotlin.collections.MutableList.toString",
        coll_list_to_string,
    ),
    ("kotlin.collections.Set.contains", coll_set_contains),
    ("kotlin.collections.Set.isEmpty", coll_set_is_empty),
    ("kotlin.collections.Set.isNotEmpty", coll_set_is_not_empty),
    ("kotlin.collections.Set.size", coll_set_size),
    ("kotlin.collections.Set.intersect", coll_set_intersect),
    ("kotlin.collections.Set.minus", coll_set_minus),
    ("kotlin.collections.Set.plus", coll_set_plus),
    ("kotlin.collections.Map.plus", coll_map_plus),
    ("kotlin.collections.Map.minus", coll_map_minus),
    (
        "kotlin.collections.Map.toMutableMap",
        coll_map_to_mutable_map,
    ),
    ("kotlin.collections.Map.toMap", coll_map_to_map),
    ("kotlin.collections.Map.toSortedMap", coll_map_to_sorted_map),
    (
        "kotlin.collections.MutableMap.toSortedMap",
        coll_map_to_sorted_map,
    ),
    (
        "kotlin.collections.MutableMap.toMutableMap",
        coll_map_to_mutable_map,
    ),
    ("kotlin.collections.MutableMap.toMap", coll_map_to_map),
    ("kotlin.collections.MutableMap.plus", coll_map_plus),
    ("kotlin.collections.MutableMap.minus", coll_map_minus),
    ("kotlin.collections.Set.subtract", coll_set_subtract),
    ("kotlin.collections.Set.toString", coll_set_to_string),
    ("kotlin.collections.Set.union", coll_set_union),
    ("kotlin.collections.Set.sorted", coll_set_sorted),
    (
        "kotlin.collections.Set.sortedDescending",
        coll_set_sorted_descending,
    ),
    ("kotlin.collections.MutableSet.add", coll_mut_set_add),
    ("kotlin.collections.MutableSet.clear", coll_mut_set_clear),
    ("kotlin.collections.MutableSet.contains", coll_set_contains),
    ("kotlin.collections.MutableSet.isEmpty", coll_set_is_empty),
    (
        "kotlin.collections.MutableSet.isNotEmpty",
        coll_set_is_not_empty,
    ),
    ("kotlin.collections.MutableSet.remove", coll_mut_set_remove),
    (
        "kotlin.collections.MutableSet.removeAll",
        coll_mut_set_remove_all,
    ),
    (
        "kotlin.collections.MutableSet.retainAll",
        coll_mut_set_retain_all,
    ),
    ("kotlin.collections.MutableSet.size", coll_set_size),
    ("kotlin.collections.MutableSet.toString", coll_set_to_string),
    // ----- Map members -----
    ("kotlin.collections.Map.containsKey", coll_map_contains_key),
    (
        "kotlin.collections.Map.containsValue",
        coll_map_contains_value,
    ),
    ("kotlin.collections.Map.entries", coll_map_entries),
    ("kotlin.collections.Map.get", coll_map_get),
    ("kotlin.collections.Map.isEmpty", coll_map_is_empty),
    ("kotlin.collections.Map.isNotEmpty", coll_map_is_not_empty),
    ("kotlin.collections.Map.keys", coll_map_keys),
    ("kotlin.collections.Map.size", coll_map_size),
    ("kotlin.collections.Map.toString", coll_map_to_string),
    ("kotlin.collections.Map.values", coll_map_values),
    ("kotlin.collections.MutableMap.clear", coll_mut_map_clear),
    (
        "kotlin.collections.MutableMap.containsKey",
        coll_map_contains_key,
    ),
    (
        "kotlin.collections.MutableMap.containsValue",
        coll_map_contains_value,
    ),
    ("kotlin.collections.MutableMap.entries", coll_map_entries),
    ("kotlin.collections.MutableMap.get", coll_map_get),
    ("kotlin.collections.MutableMap.isEmpty", coll_map_is_empty),
    (
        "kotlin.collections.MutableMap.isNotEmpty",
        coll_map_is_not_empty,
    ),
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
    (
        "kotlin.sequences.SequenceScope.yieldAll",
        seq_scope_yield_all,
    ),
    ("kotlin.sequences.Sequence.toList", seq_to_list),
    (
        "kotlin.sequences.Sequence.toMutableList",
        seq_to_mutable_list,
    ),
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
    (
        "kotlin.String.substringBeforeLast",
        string_substring_before_last,
    ),
    (
        "kotlin.String.substringAfterLast",
        string_substring_after_last,
    ),
    ("kotlin.String.replaceFirst", string_replace_first),
    ("kotlin.String.trimIndent", string_trim_indent),
    ("kotlin.String.trimMargin", string_trim_margin),
    ("kotlin.String.lines", string_lines),
    ("kotlin.String.toCharArray", string_to_char_array),
    ("kotlin.String.toLong", string_to_long),
    ("kotlin.String.toLongOrNull", string_to_long_or_null),
    ("kotlin.String.toDoubleOrNull", string_to_double_or_null),
    ("kotlin.String.toBoolean", string_to_boolean),
    (
        "kotlin.String.toBooleanStrictOrNull",
        string_to_boolean_strict_or_null,
    ),
    // ----- Additional Char -----
    ("kotlin.Char.uppercaseChar", char_uppercase_char),
    ("kotlin.Char.lowercaseChar", char_lowercase_char),
    ("kotlin.Char.isHighSurrogate", char_is_high_surrogate),
    ("kotlin.Char.isLowSurrogate", char_is_low_surrogate),
    ("kotlin.Char.isSurrogate", char_is_surrogate),
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
    (
        "kotlin.Int.countLeadingZeroBits",
        num_count_leading_zero_bits,
    ),
    (
        "kotlin.Long.countLeadingZeroBits",
        num_count_leading_zero_bits,
    ),
    (
        "kotlin.Short.countLeadingZeroBits",
        num_count_leading_zero_bits,
    ),
    (
        "kotlin.Byte.countLeadingZeroBits",
        num_count_leading_zero_bits,
    ),
    (
        "kotlin.Int.countTrailingZeroBits",
        num_count_trailing_zero_bits,
    ),
    (
        "kotlin.Long.countTrailingZeroBits",
        num_count_trailing_zero_bits,
    ),
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
    (
        "kotlin.collections.List.containsAll",
        coll_list_contains_all,
    ),
    ("kotlin.collections.List.toList", coll_list_to_list),
    (
        "kotlin.collections.List.toMutableList",
        coll_list_to_mutable_list,
    ),
    ("kotlin.collections.List.toSet", coll_list_to_set),
    (
        "kotlin.collections.List.toMutableSet",
        coll_list_to_mutable_set,
    ),
    ("kotlin.collections.List.withIndex", coll_list_with_index),
    ("kotlin.collections.MutableList.flatten", coll_list_flatten),
    ("kotlin.collections.MutableList.unzip", coll_list_unzip),
    (
        "kotlin.collections.MutableList.containsAll",
        coll_list_contains_all,
    ),
    ("kotlin.collections.MutableList.toList", coll_list_to_list),
    (
        "kotlin.collections.MutableList.toMutableList",
        coll_list_to_mutable_list,
    ),
    ("kotlin.collections.MutableList.toSet", coll_list_to_set),
    (
        "kotlin.collections.MutableList.toMutableSet",
        coll_list_to_mutable_set,
    ),
    (
        "kotlin.collections.MutableList.withIndex",
        coll_list_with_index,
    ),
    (
        "kotlin.collections.MutableList.addAll",
        coll_mut_list_add_all,
    ),
    (
        "kotlin.collections.MutableList.remove",
        coll_mut_list_remove,
    ),
    (
        "kotlin.collections.MutableList.removeAll",
        coll_mut_list_remove_all,
    ),
    (
        "kotlin.collections.MutableList.retainAll",
        coll_mut_list_retain_all,
    ),
    ("kotlin.collections.MutableList.set", coll_mut_list_set),
    // ----- Additional Set ops -----
    ("kotlin.collections.Set.containsAll", coll_set_contains_all),
    ("kotlin.collections.Set.toList", coll_set_to_list),
    (
        "kotlin.collections.Set.toMutableList",
        coll_set_to_mutable_list,
    ),
    ("kotlin.collections.Set.toSet", coll_set_to_set_),
    (
        "kotlin.collections.Set.toMutableSet",
        coll_set_to_mutable_set_,
    ),
    ("kotlin.collections.Set.withIndex", coll_set_with_index),
    (
        "kotlin.collections.MutableSet.containsAll",
        coll_set_contains_all,
    ),
    ("kotlin.collections.MutableSet.toList", coll_set_to_list),
    ("kotlin.collections.MutableSet.addAll", coll_mut_set_add_all),
    // ----- Additional Map ops -----
    (
        "kotlin.collections.Map.getOrDefault",
        coll_map_get_or_default,
    ),
    ("kotlin.collections.Map.getValue", coll_map_get_value),
    ("kotlin.collections.Map.toList", coll_map_to_list),
    ("kotlin.collections.Map.count", coll_map_count_no_pred),
    (
        "kotlin.collections.MutableMap.getOrDefault",
        coll_map_get_or_default,
    ),
    ("kotlin.collections.MutableMap.getValue", coll_map_get_value),
    ("kotlin.collections.MutableMap.toList", coll_map_to_list),
    (
        "kotlin.collections.MutableMap.count",
        coll_map_count_no_pred,
    ),
    ("kotlin.collections.MutableMap.putAll", coll_mut_map_put_all),
    ("kotlin.collections.MutableMap.set", coll_mut_map_set),
    ("kotlin.collections.MutableMap.merge", map_merge),
    (
        "kotlin.collections.MutableMap.putIfAbsent",
        map_put_if_absent,
    ),
    ("kotlin.collections.MutableMap.replace", map_replace),
    (
        "kotlin.collections.MutableMap.computeIfAbsent",
        map_compute_if_absent,
    ),
    (
        "kotlin.collections.MutableMap.computeIfPresent",
        map_compute_if_present,
    ),
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
    (
        "kotlin.collections.List.maxOfOrNull",
        coll_iter_max_of_or_null,
    ),
    (
        "kotlin.collections.MutableList.maxOfOrNull",
        coll_iter_max_of_or_null,
    ),
    (
        "kotlin.collections.Set.maxOfOrNull",
        coll_iter_max_of_or_null,
    ),
    (
        "kotlin.collections.Iterable.maxOfOrNull",
        coll_iter_max_of_or_null,
    ),
    (
        "kotlin.collections.List.minOfOrNull",
        coll_iter_min_of_or_null,
    ),
    (
        "kotlin.collections.MutableList.minOfOrNull",
        coll_iter_min_of_or_null,
    ),
    (
        "kotlin.collections.Set.minOfOrNull",
        coll_iter_min_of_or_null,
    ),
    (
        "kotlin.collections.Iterable.minOfOrNull",
        coll_iter_min_of_or_null,
    ),
    ("kotlin.collections.List.distinctBy", coll_iter_distinct_by),
    (
        "kotlin.collections.MutableList.distinctBy",
        coll_iter_distinct_by,
    ),
    ("kotlin.collections.Set.distinctBy", coll_iter_distinct_by),
    (
        "kotlin.collections.MutableSet.distinctBy",
        coll_iter_distinct_by,
    ),
    ("kotlin.collections.List.groupBy", coll_iter_group_by),
    ("kotlin.collections.MutableList.groupBy", coll_iter_group_by),
    ("kotlin.collections.Set.groupBy", coll_iter_group_by),
    ("kotlin.collections.MutableSet.groupBy", coll_iter_group_by),
    ("kotlin.collections.List.groupingBy", coll_iter_grouping_by),
    (
        "kotlin.collections.MutableList.groupingBy",
        coll_iter_grouping_by,
    ),
    ("kotlin.collections.Set.groupingBy", coll_iter_grouping_by),
    (
        "kotlin.collections.MutableSet.groupingBy",
        coll_iter_grouping_by,
    ),
    (
        "kotlin.collections.Grouping.eachCount",
        coll_grouping_each_count,
    ),
    ("kotlin.collections.Grouping.fold", coll_grouping_fold),
    ("kotlin.collections.Grouping.reduce", coll_grouping_reduce),
    ("kotlin.collections.List.associate", coll_iter_associate),
    (
        "kotlin.collections.MutableList.associate",
        coll_iter_associate,
    ),
    ("kotlin.collections.Set.associate", coll_iter_associate),
    (
        "kotlin.collections.MutableSet.associate",
        coll_iter_associate,
    ),
    (
        "kotlin.collections.List.associateBy",
        coll_iter_associate_by,
    ),
    (
        "kotlin.collections.MutableList.associateBy",
        coll_iter_associate_by,
    ),
    ("kotlin.collections.Set.associateBy", coll_iter_associate_by),
    (
        "kotlin.collections.MutableSet.associateBy",
        coll_iter_associate_by,
    ),
    (
        "kotlin.collections.List.associateWith",
        coll_iter_associate_with,
    ),
    (
        "kotlin.collections.MutableList.associateWith",
        coll_iter_associate_with,
    ),
    (
        "kotlin.collections.Set.associateWith",
        coll_iter_associate_with,
    ),
    (
        "kotlin.collections.MutableSet.associateWith",
        coll_iter_associate_with,
    ),
    ("kotlin.collections.List.sortedBy", coll_iter_sorted_by),
    (
        "kotlin.collections.MutableList.sortedBy",
        coll_iter_sorted_by,
    ),
    ("kotlin.collections.Set.sortedBy", coll_iter_sorted_by),
    (
        "kotlin.collections.MutableSet.sortedBy",
        coll_iter_sorted_by,
    ),
    ("kotlin.collections.List.sortedWith", coll_iter_sorted_with),
    (
        "kotlin.collections.MutableList.sortedWith",
        coll_iter_sorted_with,
    ),
    ("kotlin.collections.Set.sortedWith", coll_iter_sorted_with),
    (
        "kotlin.collections.MutableSet.sortedWith",
        coll_iter_sorted_with,
    ),
    (
        "kotlin.collections.List.sortedByDescending",
        coll_iter_sorted_by_desc,
    ),
    (
        "kotlin.collections.List.maxByOrNull",
        coll_iter_max_by_or_null,
    ),
    (
        "kotlin.collections.List.minByOrNull",
        coll_iter_min_by_or_null,
    ),
    (
        "kotlin.collections.MutableList.maxByOrNull",
        coll_iter_max_by_or_null,
    ),
    (
        "kotlin.collections.MutableList.minByOrNull",
        coll_iter_min_by_or_null,
    ),
    (
        "kotlin.collections.Iterable.maxByOrNull",
        coll_iter_max_by_or_null,
    ),
    (
        "kotlin.collections.Iterable.minByOrNull",
        coll_iter_min_by_or_null,
    ),
    ("kotlin.collections.MutableList.sort", coll_mut_list_sort),
    (
        "kotlin.collections.MutableList.reverse",
        coll_mut_list_reverse,
    ),
    (
        "kotlin.collections.MutableList.sortedByDescending",
        coll_iter_sorted_by_desc,
    ),
    (
        "kotlin.collections.Set.sortedByDescending",
        coll_iter_sorted_by_desc,
    ),
    (
        "kotlin.collections.MutableSet.sortedByDescending",
        coll_iter_sorted_by_desc,
    ),
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
    (
        "kotlin.collections.MutableList.mapNotNull",
        coll_iter_map_not_null,
    ),
    ("kotlin.collections.Set.mapNotNull", coll_iter_map_not_null),
    (
        "kotlin.collections.MutableSet.mapNotNull",
        coll_iter_map_not_null,
    ),
    ("kotlin.collections.Map.getOrElse", map_get_or_else),
    ("kotlin.collections.MutableMap.getOrElse", map_get_or_else),
    ("kotlin.collections.MutableMap.getOrPut", map_get_or_put),
    ("kotlin.comparisons.minOf", math_min),
    ("kotlin.comparisons.maxOf", math_max),
    ("kotlin.comparisons.compareBy", cmp_compare_by),
    (
        "kotlin.comparisons.compareByDescending",
        cmp_compare_by_descending,
    ),
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
    (
        "kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED",
        coroutine_suspended_sentinel,
    ),
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
    (
        "kotlin.text.Regex.escapeReplacement",
        regex_static_escape_replacement,
    ),
    ("kotlin.text.Regex.Companion.escape", regex_static_escape),
    (
        "kotlin.text.Regex.Companion.fromLiteral",
        regex_from_literal,
    ),
    (
        "kotlin.text.Regex.Companion.escapeReplacement",
        regex_static_escape_replacement,
    ),
    // Bare-name forms produced by `try_qualified_name` for `Regex.escape(...)`
    // style calls in source. Mirrors the Comparator.naturalOrder pattern.
    ("Regex.escape", regex_static_escape),
    ("Regex.fromLiteral", regex_from_literal),
    ("Regex.escapeReplacement", regex_static_escape_replacement),
    // ----- MatchResult / MatchGroup -----
    ("kotlin.text.MatchResult.value", match_result_value),
    ("kotlin.text.MatchResult.range", match_result_range),
    (
        "kotlin.text.MatchResult.groupValues",
        match_result_group_values,
    ),
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
    (
        "kotlin.text.StringBuilder.appendLine",
        string_builder_append_line,
    ),
    ("kotlin.text.StringBuilder.length", string_builder_length),
    (
        "kotlin.text.StringBuilder.toString",
        string_builder_to_string,
    ),
    ("kotlin.text.StringBuilder.get", string_builder_get),
    ("kotlin.text.StringBuilder.isEmpty", string_builder_is_empty),
    (
        "kotlin.text.StringBuilder.isNotEmpty",
        string_builder_is_not_empty,
    ),
    ("kotlin.text.StringBuilder.clear", string_builder_clear),
    ("kotlin.text.StringBuilder.insert", string_builder_insert),
    (
        "kotlin.text.StringBuilder.deleteAt",
        string_builder_delete_at,
    ),
    (
        "kotlin.text.StringBuilder.deleteRange",
        string_builder_delete_range,
    ),
    (
        "kotlin.text.StringBuilder.setLength",
        string_builder_set_length,
    ),
    ("kotlin.text.StringBuilder.reverse", string_builder_reverse),
    (
        "kotlin.text.StringBuilder.substring",
        string_builder_substring,
    ),
    (
        "kotlin.text.StringBuilder.subSequence",
        string_builder_substring,
    ),
    (
        "kotlin.text.StringBuilder.delete",
        string_builder_delete_range,
    ),
    (
        "kotlin.text.StringBuilder.setCharAt",
        string_builder_set_char_at,
    ),
    ("kotlin.text.StringBuilder.replace", string_builder_replace),
    (
        "kotlin.text.StringBuilder.lastIndex",
        string_builder_last_index,
    ),
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
    (
        "kotlin.collections.List.joinToString",
        &[
            "separator",
            "prefix",
            "postfix",
            "limit",
            "truncated",
            "transform",
        ],
    ),
    ("kotlin.collections.List.slice", &["indices"]),
    ("kotlin.collections.List.subList", &["fromIndex", "toIndex"]),
    ("kotlin.collections.List.take", &["n"]),
    ("kotlin.collections.List.takeLast", &["n"]),
    (
        "kotlin.collections.List.windowed",
        &["size", "step", "partialWindows", "transform"],
    ),
    (
        "kotlin.collections.MutableList.chunked",
        &["size", "transform"],
    ),
    ("kotlin.collections.MutableList.drop", &["n"]),
    ("kotlin.collections.MutableList.dropLast", &["n"]),
    (
        "kotlin.collections.MutableList.joinToString",
        &[
            "separator",
            "prefix",
            "postfix",
            "limit",
            "truncated",
            "transform",
        ],
    ),
    ("kotlin.collections.MutableList.slice", &["indices"]),
    (
        "kotlin.collections.MutableList.subList",
        &["fromIndex", "toIndex"],
    ),
    ("kotlin.collections.MutableList.take", &["n"]),
    ("kotlin.collections.MutableList.takeLast", &["n"]),
    (
        "kotlin.collections.MutableList.windowed",
        &["size", "step", "partialWindows", "transform"],
    ),
    ("kotlin.String.chunked", &["size", "transform"]),
    ("kotlin.String.repeat", &["n"]),
    (
        "kotlin.String.replace",
        &["oldValue", "newValue", "ignoreCase"],
    ),
    (
        "kotlin.String.split",
        &["delimiters", "ignoreCase", "limit"],
    ),
    ("kotlin.String.substring", &["startIndex", "endIndex"]),
    ("kotlin.String.subSequence", &["startIndex", "endIndex"]),
    (
        "kotlin.CharSequence.subSequence",
        &["startIndex", "endIndex"],
    ),
    ("kotlin.String.padStart", &["length", "padChar"]),
    ("kotlin.CharSequence.padStart", &["length", "padChar"]),
    ("kotlin.String.padEnd", &["length", "padChar"]),
    ("kotlin.CharSequence.padEnd", &["length", "padChar"]),
    (
        "kotlin.String.windowed",
        &["size", "step", "partialWindows", "transform"],
    ),
    (
        "kotlin.String.indexOf",
        &["string", "startIndex", "ignoreCase"],
    ),
    (
        "kotlin.String.lastIndexOf",
        &["string", "startIndex", "ignoreCase"],
    ),
    ("kotlin.String.equals", &["other", "ignoreCase"]),
    ("kotlin.String.contains", &["other", "ignoreCase"]),
    ("kotlin.String.startsWith", &["prefix", "ignoreCase"]),
    ("kotlin.String.endsWith", &["suffix", "ignoreCase"]),
    (
        "kotlin.String.regionMatches",
        &["thisOffset", "other", "otherOffset", "length", "ignoreCase"],
    ),
    ("kotlin.String.toInt", &["radix"]),
    ("kotlin.String.toIntOrNull", &["radix"]),
    ("kotlin.String.toLong", &["radix"]),
    ("kotlin.String.toLongOrNull", &["radix"]),
    ("kotlin.Int.toString", &["radix"]),
    // Set parallels.
    (
        "kotlin.collections.Set.joinToString",
        &[
            "separator",
            "prefix",
            "postfix",
            "limit",
            "truncated",
            "transform",
        ],
    ),
    (
        "kotlin.collections.MutableSet.joinToString",
        &[
            "separator",
            "prefix",
            "postfix",
            "limit",
            "truncated",
            "transform",
        ],
    ),
    // Range / IntProgression.
    (
        "kotlin.ranges.IntRange.joinToString",
        &[
            "separator",
            "prefix",
            "postfix",
            "limit",
            "truncated",
            "transform",
        ],
    ),
    (
        "kotlin.ranges.IntProgression.joinToString",
        &[
            "separator",
            "prefix",
            "postfix",
            "limit",
            "truncated",
            "transform",
        ],
    ),
    // Map intrinsics where a default arg is meaningful.
    (
        "kotlin.collections.Map.getOrDefault",
        &["key", "defaultValue"],
    ),
    (
        "kotlin.collections.MutableMap.getOrDefault",
        &["key", "defaultValue"],
    ),
    // Single-arg intrinsics where the named form is occasionally seen.
    ("kotlin.collections.List.sortedWith", &["comparator"]),
    ("kotlin.collections.MutableList.sortedWith", &["comparator"]),
    // Result.
    ("kotlin.Result.getOrDefault", &["defaultValue"]),
    // Threads / monitors.
    ("kotlin.synchronized", &["lock", "block"]),
    (
        "kotlin.concurrent.thread",
        &[
            "start",
            "isDaemon",
            "contextClassLoader",
            "name",
            "priority",
            "block",
        ],
    ),
    ("kotlin.concurrent.Thread.sleep", &["millis"]),
];

pub(crate) mod collections;
pub(crate) use collections::*;
pub(crate) mod comparisons;
pub(crate) use comparisons::*;
pub(crate) mod control;
pub(crate) use control::*;
pub(crate) mod concurrent;
pub(crate) use concurrent::*;
pub(crate) mod time;
pub(crate) use time::*;
pub(crate) mod io;
pub(crate) use io::*;
pub(crate) mod math;
pub(crate) use math::*;
pub(crate) mod string;
pub(crate) use string::*;
pub(crate) mod char;
pub(crate) use char::*;
pub(crate) mod numeric;
pub(crate) use numeric::*;
pub(crate) mod exceptions;
pub(crate) use exceptions::*;
pub(crate) mod sequence;
pub(crate) use sequence::*;
pub(crate) mod ranges;
pub(crate) use ranges::*;
pub(crate) mod result;
pub(crate) use result::*;
pub(crate) mod regexp;
pub(crate) use regexp::*;
pub(crate) mod stringbuilder;
pub(crate) use stringbuilder::*;

pub use collections::compare_values;
pub use collections::materialise_sequence;
pub use collections::primitive_companion_const;
pub use concurrent::concurrent_synchronized;

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

#[cfg(test)]
mod tests {
    use super::*;

    fn call(fn_: StdlibFn, args: &[Value]) -> Result<Value, RuntimeError> {
        let mut out = klio_runtime::CaptureOutput::default();
        let mut host = klio_runtime::NoopHost::default();
        fn_(&mut CallCtx {
            args,
            out: &mut out,
            host: &mut host,
        })
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
        assert!(matches!(
            call(math_abs, &[Value::Int(-5)]),
            Ok(Value::Int(5))
        ));
        let Ok(Value::Double(d)) = call(math_abs, &[Value::Double(-1.5)]) else {
            panic!()
        };
        assert!((d - 1.5).abs() < 1e-12);
    }

    #[test]
    fn math_sin_cos_identities() {
        let Ok(Value::Double(s)) = call(math_sin, &[Value::Double(0.0)]) else {
            panic!()
        };
        let Ok(Value::Double(c)) = call(math_cos, &[Value::Double(0.0)]) else {
            panic!()
        };
        assert!(s.abs() < 1e-12);
        assert!((c - 1.0).abs() < 1e-12);
    }

    #[test]
    fn math_floor_ceil_round() {
        assert!(
            matches!(call(math_floor, &[Value::Double(1.7)]), Ok(Value::Double(d)) if (d - 1.0).abs() < 1e-12)
        );
        assert!(
            matches!(call(math_ceil, &[Value::Double(1.2)]), Ok(Value::Double(d)) if (d - 2.0).abs() < 1e-12)
        );
        assert!(
            matches!(call(math_round, &[Value::Double(1.5)]), Ok(Value::Double(d)) if (d - 2.0).abs() < 1e-12)
        );
    }

    #[test]
    fn string_length_counts_chars_not_bytes() {
        let s = Value::String(Arc::new("héllo".to_string()));
        assert!(matches!(call(string_length, &[s]), Ok(Value::Int(5))));
    }

    fn byte_array(bytes: &[i8]) -> Value {
        Value::Array {
            items: ObjRef::new(bytes.iter().map(|b| Value::Byte(*b)).collect()),
            prim: Some(klio_runtime::PrimitiveArrayKind::Byte),
        }
    }
    fn int_array(ints: &[i32]) -> Value {
        Value::Array {
            items: ObjRef::new(ints.iter().map(|i| Value::Int(*i)).collect()),
            prim: Some(klio_runtime::PrimitiveArrayKind::Int),
        }
    }
    fn array_ints(v: &Value) -> Vec<i32> {
        match v {
            Value::Array { items, .. } | Value::List { items, .. } => items
                .borrow()
                .iter()
                .map(|e| match e {
                    Value::Int(i) => *i,
                    Value::Byte(b) => i32::from(*b),
                    _ => -1,
                })
                .collect(),
            _ => panic!("not an array or list"),
        }
    }

    #[test]
    fn array_copy_into_copies_range_in_place() {
        let src = byte_array(&[1, 2, 3, 4, 5]);
        let dst = byte_array(&[0, 0, 0, 0, 0]);
        let Value::Array { items: dst_ref, .. } = &dst else {
            unreachable!()
        };
        let dst_ref = dst_ref.clone();
        let ret = call(
            array_copy_into,
            &[src, dst, Value::Int(1), Value::Int(0), Value::Int(3)],
        )
        .expect("copyInto");
        // Returns the destination, and mutated it in place.
        assert!(matches!(ret, Value::Array { .. }));
        let got: Vec<i8> = dst_ref
            .borrow()
            .iter()
            .map(|v| match v {
                Value::Byte(b) => *b,
                _ => -1,
            })
            .collect();
        assert_eq!(got, vec![0, 1, 2, 3, 0]);
    }

    #[test]
    fn array_copy_into_handles_self_overlap() {
        let arr = int_array(&[1, 2, 3, 4, 5]);
        let Value::Array { items: r, .. } = &arr else {
            unreachable!()
        };
        let r = r.clone();
        // copy [0,3) onto offset 2 — overlapping forward.
        call(
            array_copy_into,
            &[
                arr.clone(),
                arr,
                Value::Int(2),
                Value::Int(0),
                Value::Int(3),
            ],
        )
        .expect("copyInto overlap");
        let got: Vec<i32> = r
            .borrow()
            .iter()
            .map(|v| match v {
                Value::Int(i) => *i,
                _ => -1,
            })
            .collect();
        assert_eq!(got, vec![1, 2, 1, 2, 3]);
    }

    #[test]
    fn array_copy_into_out_of_bounds_throws() {
        let src = byte_array(&[1, 2, 3]);
        let dst = byte_array(&[0, 0]);
        assert!(matches!(
            call(
                array_copy_into,
                &[src, dst, Value::Int(0), Value::Int(0), Value::Int(3)]
            ),
            Err(RuntimeError::Thrown(_))
        ));
    }

    #[test]
    fn array_copy_of_same_size_and_grow_pads_zero() {
        assert_eq!(
            array_ints(&call(array_copy_of, &[int_array(&[7, 8, 9])]).unwrap()),
            vec![7, 8, 9]
        );
        assert_eq!(
            array_ints(&call(array_copy_of, &[int_array(&[7, 8]), Value::Int(4)]).unwrap()),
            vec![7, 8, 0, 0]
        );
        assert_eq!(
            array_ints(&call(array_copy_of, &[int_array(&[7, 8, 9]), Value::Int(2)]).unwrap()),
            vec![7, 8]
        );
    }

    #[test]
    fn array_copy_of_range_slices() {
        assert_eq!(
            array_ints(
                &call(
                    array_copy_of_range,
                    &[int_array(&[1, 2, 3, 4]), Value::Int(1), Value::Int(3)]
                )
                .unwrap()
            ),
            vec![2, 3]
        );
    }

    #[test]
    fn array_fill_overwrites_range_and_returns_unit() {
        let arr = int_array(&[0, 0, 0, 0]);
        let Value::Array { items: r, .. } = &arr else {
            unreachable!()
        };
        let r = r.clone();
        let ret = call(
            array_fill,
            &[arr, Value::Int(9), Value::Int(1), Value::Int(3)],
        )
        .unwrap();
        assert!(matches!(ret, Value::Unit));
        let got: Vec<i32> = r
            .borrow()
            .iter()
            .map(|v| match v {
                Value::Int(i) => *i,
                _ => -1,
            })
            .collect();
        assert_eq!(got, vec![0, 9, 9, 0]);
    }

    #[test]
    fn array_sort_orders_in_place_and_range() {
        let arr = int_array(&[3, 1, 2]);
        call(array_sort, std::slice::from_ref(&arr)).unwrap();
        assert_eq!(array_ints(&arr), vec![1, 2, 3]);
        // Range [1,4) of [5,4,3,2,1] sorts only the middle.
        let arr = int_array(&[5, 4, 3, 2, 1]);
        call(array_sort, &[arr.clone(), Value::Int(1), Value::Int(4)]).unwrap();
        assert_eq!(array_ints(&arr), vec![5, 2, 3, 4, 1]);
    }

    #[test]
    fn mutable_list_reverse_in_place() {
        let list = make_list(vec![Value::Int(1), Value::Int(2), Value::Int(3)], true);
        let ret = call(coll_mut_list_reverse, std::slice::from_ref(&list)).unwrap();
        assert!(matches!(ret, Value::Unit));
        assert_eq!(array_ints(&list), vec![3, 2, 1]);
    }

    #[test]
    fn string_to_byte_array_is_utf8() {
        let s = Value::String(Arc::new("Hé".to_string()));
        let Ok(Value::Array { items, prim }) = call(string_to_byte_array, &[s]) else {
            panic!("expected ByteArray")
        };
        assert_eq!(prim, Some(klio_runtime::PrimitiveArrayKind::Byte));
        let got: Vec<u8> = items
            .borrow()
            .iter()
            .map(|v| match v {
                Value::Byte(b) => b.cast_unsigned(),
                _ => 0,
            })
            .collect();
        assert_eq!(got, "Hé".as_bytes().to_vec());
    }

    #[test]
    fn byte_array_decode_to_string_round_trips_and_slices() {
        let bytes = byte_array(&[72, 105, 33]);
        let Ok(Value::String(s)) = call(byte_array_decode_to_string, &[bytes]) else {
            panic!("expected String")
        };
        assert_eq!(s.as_str(), "Hi!");
        let bytes = byte_array(&[72, 105, 33]);
        let Ok(Value::String(s)) = call(
            byte_array_decode_to_string,
            &[bytes, Value::Int(0), Value::Int(2)],
        ) else {
            panic!("expected String")
        };
        assert_eq!(s.as_str(), "Hi");
    }

    #[test]
    fn string_get_returns_char() {
        let s = Value::String(Arc::new("abc".to_string()));
        assert!(
            matches!(call(string_get, &[s, Value::Int(1)]), Ok(Value::Char(c)) if c == u16::from(b'b'))
        );
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
        let Ok(Value::String(out)) = call(string_substring, &[s, Value::Int(1), Value::Int(4)])
        else {
            panic!()
        };
        assert_eq!(*out, "bcd");
    }

    #[test]
    fn string_repeat_and_reversed() {
        let s = Value::String(Arc::new("ab".to_string()));
        let Ok(Value::String(r)) = call(string_repeat, &[s.clone(), Value::Int(3)]) else {
            panic!()
        };
        assert_eq!(*r, "ababab");
        let Ok(Value::String(rev)) = call(string_reversed, &[s]) else {
            panic!()
        };
        assert_eq!(*rev, "ba");
    }

    #[test]
    fn char_is_digit_letter_whitespace() {
        assert!(matches!(
            call(char_is_digit, &[Value::Char('5' as u16)]),
            Ok(Value::Bool(true))
        ));
        assert!(matches!(
            call(char_is_letter, &[Value::Char('a' as u16)]),
            Ok(Value::Bool(true))
        ));
        assert!(matches!(
            call(char_is_whitespace, &[Value::Char(' ' as u16)]),
            Ok(Value::Bool(true))
        ));
    }

    #[test]
    fn char_unicode_category_predicates() {
        // ASCII baseline.
        assert!(matches!(
            call(char_is_letter, &[Value::Char('A' as u16)]),
            Ok(Value::Bool(true))
        ));
        assert!(matches!(
            call(char_is_letter, &[Value::Char('z' as u16)]),
            Ok(Value::Bool(true))
        ));
        assert!(matches!(
            call(char_is_digit, &[Value::Char('0' as u16)]),
            Ok(Value::Bool(true))
        ));
        assert!(matches!(
            call(char_is_whitespace, &[Value::Char('\t' as u16)]),
            Ok(Value::Bool(true))
        ));
        assert!(matches!(
            call(char_is_whitespace, &[Value::Char('\n' as u16)]),
            Ok(Value::Bool(true))
        ));

        // Non-ASCII letters.
        assert!(matches!(
            call(char_is_letter, &[Value::Char('α' as u16)]),
            Ok(Value::Bool(true))
        ));
        assert!(matches!(
            call(char_is_letter, &[Value::Char('я' as u16)]),
            Ok(Value::Bool(true))
        ));
        assert!(matches!(
            call(char_is_uppercase, &[Value::Char('Я' as u16)]),
            Ok(Value::Bool(true))
        ));

        // kotlinc-native treats NBSP-family code points as whitespace
        // (matches its built-in whitespace table; this also happens to match
        // Rust's `char::is_whitespace` here, so no divergence).
        assert!(matches!(
            call(char_is_whitespace, &[Value::Char('\u{00A0}' as u16)]),
            Ok(Value::Bool(true))
        ));
        assert!(matches!(
            call(char_is_whitespace, &[Value::Char('\u{202F}' as u16)]),
            Ok(Value::Bool(true))
        ));
        assert!(matches!(
            call(char_is_whitespace, &[Value::Char('\u{2007}' as u16)]),
            Ok(Value::Bool(true))
        ));
        // Divergence: ASCII control 0x1C..=0x1F. Kotlin -> true (in the
        // kotlinc-native whitespace table), Rust -> false.
        assert!(matches!(
            call(char_is_whitespace, &[Value::Char('\u{001F}' as u16)]),
            Ok(Value::Bool(true))
        ));
        assert!(matches!(
            call(char_is_whitespace, &[Value::Char('\u{001C}' as u16)]),
            Ok(Value::Bool(true))
        ));

        // Divergence: Arabic-Indic digit five (U+0665). Both true under Nd,
        // but it's a non-ASCII digit guarded by the old `is_ascii_digit` call
        // which returned false. New code matches kotlinc.
        assert!(matches!(
            call(char_is_digit, &[Value::Char('\u{0665}' as u16)]),
            Ok(Value::Bool(true))
        ));

        // Divergence: Roman numeral V (U+2164). Other_Uppercase contributory
        // property -> Kotlin treats as uppercase; Rust `is_uppercase` -> false.
        assert!(matches!(
            call(char_is_uppercase, &[Value::Char('\u{2164}' as u16)]),
            Ok(Value::Bool(true))
        ));

        // ZWSP (U+200B): neither Rust nor Kotlin treat as whitespace; sanity.
        assert!(matches!(
            call(char_is_whitespace, &[Value::Char('\u{200B}' as u16)]),
            Ok(Value::Bool(false))
        ));
    }

    #[test]
    fn int_bitwise_ops() {
        assert!(matches!(
            call(int_and, &[Value::Int(0b1100), Value::Int(0b1010)]),
            Ok(Value::Int(0b1000))
        ));
        assert!(matches!(
            call(int_or, &[Value::Int(0b1100), Value::Int(0b1010)]),
            Ok(Value::Int(0b1110))
        ));
        assert!(matches!(
            call(int_xor, &[Value::Int(0b1100), Value::Int(0b1010)]),
            Ok(Value::Int(0b0110))
        ));
        assert!(matches!(
            call(int_shl, &[Value::Int(1), Value::Int(3)]),
            Ok(Value::Int(8))
        ));
        assert!(matches!(
            call(int_shr, &[Value::Int(8), Value::Int(2)]),
            Ok(Value::Int(2))
        ));
    }

    #[test]
    fn double_predicates() {
        assert!(matches!(
            call(double_is_nan, &[Value::Double(f64::NAN)]),
            Ok(Value::Bool(true))
        ));
        assert!(matches!(
            call(double_is_infinite, &[Value::Double(f64::INFINITY)]),
            Ok(Value::Bool(true))
        ));
        assert!(matches!(
            call(double_is_finite, &[Value::Double(1.0)]),
            Ok(Value::Bool(true))
        ));
    }

    #[test]
    fn string_substring_before_after() {
        let s = Value::String(Arc::new("a.b.c".to_string()));
        let Ok(Value::String(before)) = call(
            string_substring_before,
            &[s.clone(), Value::String(Arc::new(".".into()))],
        ) else {
            panic!()
        };
        assert_eq!(*before, "a");
        let Ok(Value::String(after)) = call(
            string_substring_after_last,
            &[s, Value::String(Arc::new(".".into()))],
        ) else {
            panic!()
        };
        assert_eq!(*after, "c");
    }

    #[test]
    fn map_get_or_default_falls_back() {
        let m = make_map(
            vec![(Value::String(Arc::new("a".into())), Value::Int(1))],
            false,
        );
        let Ok(v) = call(
            coll_map_get_or_default,
            &[
                m.clone(),
                Value::String(Arc::new("a".into())),
                Value::Int(99),
            ],
        ) else {
            panic!()
        };
        assert!(matches!(v, Value::Int(1)));
        let Ok(v) = call(
            coll_map_get_or_default,
            &[m, Value::String(Arc::new("z".into())), Value::Int(99)],
        ) else {
            panic!()
        };
        assert!(matches!(v, Value::Int(99)));
    }

    #[test]
    fn int_coerce_in_range_and_pair() {
        assert!(matches!(
            call(
                int_coerce_in,
                &[Value::Int(5), Value::Int(0), Value::Int(3)]
            ),
            Ok(Value::Int(3))
        ));
        assert!(matches!(
            call(
                int_coerce_in,
                &[Value::Int(-1), Value::Int(0), Value::Int(3)]
            ),
            Ok(Value::Int(0))
        ));
        assert!(matches!(
            call(
                int_coerce_in,
                &[
                    Value::Int(2),
                    Value::Range {
                        start: 0,
                        end: 5,
                        step: 1,
                        kind: klio_runtime::RangeKind::Int
                    }
                ]
            ),
            Ok(Value::Int(2))
        ));
    }

    #[test]
    fn string_lines_splits_on_all_line_separators() {
        let s = Value::String(Arc::new("a\nb\r\nc\rd".to_string()));
        let Ok(Value::List { items, .. }) = call(string_lines, &[s]) else {
            panic!()
        };
        assert_eq!(items.borrow().len(), 4);
    }

    #[test]
    fn regex_find_returns_match() {
        let re = call(regex_ctor, &[Value::String(Arc::new(r"\d+".into()))]).unwrap();
        let v = call(
            regex_find,
            &[re, Value::String(Arc::new("abc 123 def".into()))],
        )
        .unwrap();
        let Value::Match(m) = v else { panic!() };
        assert_eq!(*m.groups[0].as_ref().unwrap().value, "123");
    }

    #[test]
    fn string_builder_append_and_length() {
        let sb = call(string_builder_ctor, &[]).unwrap();
        call(
            string_builder_append,
            &[sb.clone(), Value::String(Arc::new("ab".into()))],
        )
        .unwrap();
        call(string_builder_append, &[sb.clone(), Value::Int(7)]).unwrap();
        let Value::Int(n) = call(string_builder_length, std::slice::from_ref(&sb)).unwrap() else {
            panic!()
        };
        assert_eq!(n, 3);
        let Value::String(s) = call(string_builder_to_string, &[sb]).unwrap() else {
            panic!()
        };
        assert_eq!(&*s, "ab7");
    }

    #[test]
    fn format_basic_specifiers() {
        let fmt = Value::String(Arc::new("%d-%s".into()));
        let Value::String(s) = call(
            string_format_static,
            &[fmt, Value::Int(7), Value::String(Arc::new("x".into()))],
        )
        .unwrap() else {
            panic!()
        };
        assert_eq!(&*s, "7-x");
    }

    #[test]
    fn excn_constructors_carry_message() {
        let Ok(Value::Exception { fqn, message, .. }) = call(
            excn_illegal_argument,
            &[Value::String(Arc::new("bad".into()))],
        ) else {
            panic!()
        };
        assert_eq!(*fqn, "kotlin.IllegalArgumentException");
        assert_eq!(
            message.as_deref().map(std::string::String::as_str),
            Some("bad")
        );
    }
}
