//! Bulk array copy/fill intrinsics and String <-> `ByteArray` (UTF-8)
//! conversions, plus the kotlinx-io byte surface that rides on top of
//! them. Upstream declares `copyInto` / `copyOf` / `copyOfRange` /
//! `fill` and `encodeToByteArray` / `toByteArray` / `decodeToString`
//! without a klio-runnable body; before the host actuals landed every
//! one silently no-opped (a `ByteArray` copy left the destination zeroed).
//! Also ranges, progressions, and primitive array specializations
//! (IntArray init, step/downTo/until, char ranges, sliceArray,
//! arrayOfNulls, withIndex, DoubleArray aggregates).

const std = @import("std");
const parity = @import("parity");

const TMP_DIR = "/tmp/klio_itest_array_bulk_ops";

// The klio pipeline installs process-global lowering/VM state (inline-fn
// tables, the enclosing-`this` stack) backed by the run's allocator. A
// per-test arena would be torn down while those globals still point into it,
// so one file-scoped arena over the page allocator backs every run here (the
// leak-checking test allocator is never used, matching the e2e harness).
var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);


fn assertKlio(name: []const u8, src: []const u8, expected: []const u8) !void {
    // Reset the per-program arena so each program's ASTs/IR/packs/VM graph
    // is reclaimed instead of accumulating across this file's tests. Safe:
    // the cross-program globals are page_allocator-backed, not this arena.
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    std.Io.Dir.cwd().createDirPath(io, TMP_DIR) catch {};
    const path = try std.fmt.allocPrint(a, "{s}/{s}.kt", .{ TMP_DIR, name });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = src });

    const res = try parity.runWithPacks(a, io, path);
    switch (res) {
        .ok => |got| try std.testing.expectEqualStrings(expected, got),
        .err => |m| {
            std.debug.print("klio run failed for `{s}`: {s}\n", .{ name, m });
            return error.KlioRunFailed;
        },
    }
}

test "byte_array_copy_into_round_trips" {
    const src =
        \\
        \\fun main() {
        \\    val src = byteArrayOf(72, 101, 108, 108, 111)
        \\    val dst = ByteArray(5)
        \\    src.copyInto(dst)
        \\    println(dst.joinToString(","))
        \\}
        \\
    ;
    try assertKlio("copy_into_bytes", src, "72,101,108,108,111\n");
}

test "copy_into_with_offsets_and_overlap" {
    const src =
        \\
        \\fun main() {
        \\    val a = intArrayOf(1, 2, 3, 4, 5)
        \\    val b = IntArray(5)
        \\    a.copyInto(b, 1, 0, 3)
        \\    println(b.joinToString(","))
        \\    // Overlapping self-copy must behave like a snapshot-then-write.
        \\    a.copyInto(a, 2, 0, 3)
        \\    println(a.joinToString(","))
        \\}
        \\
    ;
    try assertKlio("copy_into_offsets", src, "0,1,2,3,0\n1,2,1,2,3\n");
}

test "copy_of_grows_and_pads" {
    const src =
        \\
        \\fun main() {
        \\    val a = intArrayOf(7, 8, 9)
        \\    println(a.copyOf().joinToString(","))
        \\    println(a.copyOf(5).joinToString(","))
        \\    println(a.copyOf(2).joinToString(","))
        \\    println(a.copyOfRange(1, 3).joinToString(","))
        \\}
        \\
    ;
    try assertKlio("copy_of", src, "7,8,9\n7,8,9,0,0\n7,8\n8,9\n");
}

test "array_fill_overwrites_range" {
    const src =
        \\
        \\fun main() {
        \\    val a = IntArray(5)
        \\    a.fill(9)
        \\    println(a.joinToString(","))
        \\    val b = IntArray(5)
        \\    b.fill(1, 1, 4)
        \\    println(b.joinToString(","))
        \\}
        \\
    ;
    try assertKlio("array_fill", src, "9,9,9,9,9\n0,1,1,1,0\n");
}

test "array_sort_family_in_place_and_copies" {
    const src =
        \\
        \\fun main() {
        \\    val a = intArrayOf(3, 1, 4, 1, 5, 9, 2, 6)
        \\    a.sort()
        \\    println(a.joinToString(","))
        \\    val b = intArrayOf(5, 4, 3, 2, 1)
        \\    b.sort(1, 4)
        \\    println(b.joinToString(","))
        \\    val c = intArrayOf(3, 1, 2)
        \\    println(c.sortedArray().joinToString(",") + " | " + c.joinToString(","))
        \\    val d = intArrayOf(1, 3, 2)
        \\    d.sortDescending()
        \\    println(d.joinToString(","))
        \\    val e = arrayOf("banana", "apple", "cherry")
        \\    e.sort()
        \\    println(e.joinToString(","))
        \\}
        \\
    ;
    try assertKlio(
        "array_sort",
        src,
        "1,1,2,3,4,5,6,9\n5,2,3,4,1\n1,2,3 | 3,1,2\n3,2,1\napple,banana,cherry\n",
    );
}

test "array_sort_with_comparator_and_user_comparable" {
    const src =
        \\
        \\data class Person(val name: String, val age: Int) : Comparable<Person> {
        \\    override fun compareTo(other: Person): Int = age - other.age
        \\}
        \\fun main() {
        \\    val people = arrayOf(Person("A", 30), Person("B", 20), Person("C", 25))
        \\    people.sort()
        \\    println(people.joinToString(",") { it.name })
        \\    people.sortWith(compareByDescending { it.age })
        \\    println(people.joinToString(",") { it.name })
        \\}
        \\
    ;
    try assertKlio("array_sort_with", src, "B,C,A\nA,C,B\n");
}

test "array_and_mutable_list_reversed" {
    const src =
        \\
        \\fun main() {
        \\    println(intArrayOf(1, 2, 3, 4).reversed())
        \\    println(arrayOf("a", "b", "c").reversed())
        \\    val m = mutableListOf(1, 2, 3)
        \\    m.reverse()
        \\    println(m)
        \\    println(intArrayOf(5, 1, 4, 2).sortedDescending())
        \\}
        \\
    ;
    try assertKlio(
        "array_reversed",
        src,
        "[4, 3, 2, 1]\n[c, b, a]\n[3, 2, 1]\n[5, 4, 2, 1]\n",
    );
}

test "string_byte_array_utf8_round_trip" {
    const src =
        \\
        \\fun main() {
        \\    val bytes = "Héllo".encodeToByteArray()
        \\    println(bytes.size)
        \\    println(bytes.decodeToString())
        \\    val again = "Héllo".toByteArray()
        \\    println(again.decodeToString())
        \\}
        \\
    ;
    // "Héllo" is 6 UTF-8 bytes (é is 2).
    try assertKlio("string_bytes", src, "6\nHéllo\nHéllo\n");
}

test "string_from_byte_array_decodes_utf8" {
    const src =
        \\
        \\fun main() {
        \\    println(String(byteArrayOf(72, 105, 33)))
        \\    println(String(byteArrayOf(65, 66, 67, 68), 1, 2))
        \\    println(String("café".encodeToByteArray()))
        \\    // CharArray constructor must still build from code units.
        \\    println(String(charArrayOf('h', 'i')))
        \\}
        \\
    ;
    try assertKlio("string_from_bytes", src, "Hi!\nBC\ncafé\nhi\n");
}

test "kotlinx_io_read_byte_array" {
    // readByteArray / readTo(ByteArray) bottom out on the extension
    // `Source.readTo(ByteArray, ...)`; the member `Buffer.readTo(RawSink,
    // byteCount)` must not shadow it (it's inapplicable by arity).
    const src =
        \\import kotlinx.io.Buffer
        \\import kotlinx.io.readByteArray
        \\import kotlinx.io.readTo
        \\
        \\fun main() {
        \\    val b = Buffer()
        \\    b.write(byteArrayOf(65, 66, 67))
        \\    println(b.readByteArray().joinToString(","))
        \\
        \\    val c = Buffer()
        \\    c.write(byteArrayOf(72, 105))
        \\    val dst = ByteArray(2)
        \\    c.readTo(dst)
        \\    println(dst.joinToString(","))
        \\}
        \\
    ;
    try assertKlio("kxio_read_byte_array", src, "65,66,67\n72,105\n");
}

test "kotlinx_io_bytestring_encode_decode" {
    const src =
        \\import kotlinx.io.bytestring.encodeToByteString
        \\import kotlinx.io.bytestring.decodeToString
        \\import kotlinx.io.bytestring.substring
        \\
        \\fun main() {
        \\    val bs = "hello".encodeToByteString()
        \\    println(bs.size)
        \\    println(bs.decodeToString())
        \\    println(bs.substring(0, 3).decodeToString())
        \\}
        \\
    ;
    try assertKlio("kxio_bytestring", src, "5\nhello\nhel\n");
}

test "int_array_init_pattern" {
    const src =
        \\
        \\fun main() {
        \\    val xs = IntArray(5) { it * it }
        \\    println(xs.joinToString(","))
        \\}
        \\
    ;
    try assertKlio("intArray_init", src, "0,1,4,9,16\n");
}

test "array_of_primitives_sum" {
    const src =
        \\
        \\fun main() {
        \\    val xs = intArrayOf(3,1,4,1,5,9,2,6)
        \\    println("sum=${xs.sum()} max=${xs.max()} avg=${xs.average()}")
        \\}
        \\
    ;
    try assertKlio("prim_arr", src, "sum=31 max=9 avg=3.875\n");
}

test "range_step_explicit" {
    const src =
        \\
        \\fun main() {
        \\    val sb = StringBuilder()
        \\    for (i in 1..15 step 2) sb.append("$i,")
        \\    sb.append("|")
        \\    for (i in 10 downTo 1 step 3) sb.append("$i,")
        \\    println(sb)
        \\}
        \\
    ;
    try assertKlio("range_step", src, "1,3,5,7,9,11,13,15,|10,7,4,1,\n");
}

test "until_range_exclusive" {
    const src =
        \\
        \\fun main() {
        \\    val sb = StringBuilder()
        \\    for (i in 0 until 5) sb.append("$i,")
        \\    println(sb)
        \\}
        \\
    ;
    try assertKlio("until", src, "0,1,2,3,4,\n");
}

test "char_range_iteration" {
    const src =
        \\
        \\fun main() {
        \\    val sb = StringBuilder()
        \\    for (c in 'a'..'e') sb.append(c)
        \\    println(sb)
        \\}
        \\
    ;
    try assertKlio("char_range", src, "abcde\n");
}

test "array_copy_and_slice" {
    const src =
        \\
        \\fun main() {
        \\    val xs = intArrayOf(10,20,30,40,50)
        \\    val slice = xs.sliceArray(1..3)
        \\    println(slice.joinToString(","))
        \\}
        \\
    ;
    try assertKlio("slice", src, "20,30,40\n");
}

test "array_of_nulls_works" {
    const src =
        \\
        \\fun main() {
        \\    val arr = arrayOfNulls<String>(3)
        \\    arr[0] = "a"; arr[2] = "c"
        \\    println(arr.joinToString(",") { it ?: "_" })
        \\}
        \\
    ;
    try assertKlio("arr_nulls", src, "a,_,c\n");
}

test "range_contains_check" {
    const src =
        \\
        \\fun main() {
        \\    val r = 1..10
        \\    println("${5 in r},${15 in r},${(1..3).contains(2)}")
        \\}
        \\
    ;
    try assertKlio("range_in", src, "true,false,true\n");
}

test "int_array_indexed_iter" {
    const src =
        \\
        \\fun main() {
        \\    val xs = intArrayOf(10,20,30)
        \\    val sb = StringBuilder()
        \\    for ((i, v) in xs.withIndex()) sb.append("$i=$v;")
        \\    println(sb)
        \\}
        \\
    ;
    try assertKlio("withIndex", src, "0=10;1=20;2=30;\n");
}

test "double_array_operations" {
    const src =
        \\
        \\fun main() {
        \\    val xs = doubleArrayOf(1.5, 2.5, 3.5, 4.5)
        \\    println("sum=${xs.sum()} avg=${xs.average()}")
        \\}
        \\
    ;
    try assertKlio("double_arr", src, "sum=12.0 avg=3.0\n");
}
