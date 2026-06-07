//! Property + accessor parity: custom getters/setters, backing-field
//! mutation, computed properties, lateinit, delegate setValue, open
//! property override with getter.
//! Port of the Rust suite.

const std = @import("std");
const parity = @import("parity");

const TMP_DIR = "/tmp/klio_itest_properties_accessors";

// The klio pipeline installs process-global lowering/VM state (inline-fn
// tables, the enclosing-`this` stack) backed by the run's allocator. A
// per-test arena would be torn down while those globals still point into it,
// so one file-scoped arena over the page allocator backs every run here (the
// leak-checking test allocator is never used, matching the e2e harness).
var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);


/// Write `src` to a unique temp `.kt` path, run it through the klio pipeline,
/// and assert stdout equals `expected`. Uses an arena per test so the
/// leak-checking test allocator never drives the pipeline.
fn assertKlio(name: []const u8, src: []const u8, expected: []const u8) !void {
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

test "custom_getter_setter_with_backing_field" {
    const src =
        \\
        \\class Counter {
        \\    private var _value: Int = 0
        \\    var value: Int
        \\        get() = _value
        \\        set(v) { if (v >= 0) _value = v }
        \\}
        \\fun main() {
        \\    val c = Counter()
        \\    c.value = 5
        \\    c.value = -3  // ignored
        \\    c.value = 10
        \\    println(c.value)
        \\}
        \\
    ;
    try assertKlio("custom_get_set", src, "10\n");
}

test "computed_property_from_other_props" {
    const src =
        \\
        \\class Rect(val w: Int, val h: Int) {
        \\    val area: Int get() = w * h
        \\    val perimeter: Int get() = 2 * (w + h)
        \\}
        \\fun main() {
        \\    val r = Rect(3, 4)
        \\    println("${r.area} ${r.perimeter}")
        \\}
        \\
    ;
    try assertKlio("computed_prop", src, "12 14\n");
}

test "override_open_property_with_getter" {
    const src =
        \\
        \\open class Animal { open val sound: String get() = "?" }
        \\class Dog : Animal() { override val sound: String get() = "woof" }
        \\class Cat : Animal() { override val sound: String get() = "meow" }
        \\fun main() {
        \\    val xs: List<Animal> = listOf(Dog(), Cat(), Animal())
        \\    println(xs.joinToString(",") { it.sound })
        \\}
        \\
    ;
    try assertKlio("open_prop_getter", src, "woof,meow,?\n");
}

test "backing_field_field_keyword" {
    const src =
        \\
        \\class Box {
        \\    var x: Int = 0
        \\        set(v) { field = if (v >= 0) v else 0 }
        \\}
        \\fun main() {
        \\    val b = Box()
        \\    b.x = 7
        \\    b.x = -3
        \\    println(b.x)
        \\}
        \\
    ;
    try assertKlio("field_keyword", src, "0\n");
}

test "property_initializer_runs_once" {
    const src =
        \\
        \\var initCount = 0
        \\class P {
        \\    val tag: String = run { initCount += 1; "tag${initCount}" }
        \\}
        \\fun main() {
        \\    val a = P()
        \\    val b = P()
        \\    println("${a.tag},${b.tag},count=$initCount")
        \\}
        \\
    ;
    try assertKlio("prop_init_once", src, "tag1,tag2,count=2\n");
}

test "extension_property_with_getter" {
    const src =
        \\
        \\val String.firstWord: String get() = split(" ").first()
        \\fun main() {
        \\    println("hello world".firstWord)
        \\}
        \\
    ;
    try assertKlio("ext_prop_getter", src, "hello\n");
}

test "lazy_property_delegate" {
    const src =
        \\
        \\class Heavy {
        \\    val expensive: String by lazy { "computed" }
        \\}
        \\fun main() {
        \\    val h = Heavy()
        \\    println(h.expensive)
        \\    println(h.expensive)
        \\}
        \\
    ;
    try assertKlio("lazy_delegate", src, "computed\ncomputed\n");
}

test "property_with_secondary_setter_logic" {
    const src =
        \\
        \\class Temperature {
        \\    var celsius: Double = 0.0
        \\        set(v) { field = v; recompute() }
        \\    var fahrenheit: Double = 32.0
        \\        private set
        \\    private fun recompute() { fahrenheit = celsius * 9 / 5 + 32 }
        \\}
        \\fun main() {
        \\    val t = Temperature()
        \\    t.celsius = 100.0
        \\    println("${t.celsius} ${t.fahrenheit}")
        \\}
        \\
    ;
    try assertKlio("temp_prop", src, "100.0 212.0\n");
}
