//! Visibility modifiers parity: private/internal/protected access
//! constraints, file-private top-level, package-private (internal).

const std = @import("std");
const parity = @import("parity");

const TMP_DIR = "/tmp/klio_itest_visibility_modifiers";

// The klio pipeline installs process-global lowering/VM state (inline-fn
// tables, the enclosing-`this` stack) backed by the run's allocator. A
// per-test arena would be torn down while those globals still point into it,
// so one file-scoped arena over the page allocator backs every run here (the
// leak-checking test allocator is never used, matching the e2e harness).
var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);


/// Write `src` to a unique temp `.kt` file, run it through the klio pipeline,
/// and assert the captured stdout equals `expected`.
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

test "protected_access_through_subclass" {
    const src =
        \\
        \\open class Base {
        \\    protected open fun helper(): String = "base"
        \\    fun publicEntry(): String = helper()
        \\}
        \\class Sub : Base() {
        \\    override fun helper(): String = "sub:" + super.helper()
        \\}
        \\fun main() {
        \\    println("${Base().publicEntry()}|${Sub().publicEntry()}")
        \\}
        \\
    ;
    try assertKlio("protected", src, "base|sub:base\n");
}

test "internal_property_visible_in_module" {
    const src =
        \\
        \\class Bag {
        \\    internal var count: Int = 0
        \\    fun bump() { count += 1 }
        \\}
        \\fun main() {
        \\    val b = Bag()
        \\    b.bump(); b.bump(); b.bump()
        \\    println(b.count)
        \\}
        \\
    ;
    try assertKlio("internal_prop", src, "3\n");
}

test "private_top_level_used_in_main" {
    const src =
        \\
        \\private fun secret(x: Int): Int = x * 100
        \\fun main() {
        \\    println(secret(7))
        \\}
        \\
    ;
    try assertKlio("private_toplevel", src, "700\n");
}

test "private_property_only_accessed_within_class" {
    const src =
        \\
        \\class Vault {
        \\    private var balance: Int = 100
        \\    fun deposit(n: Int) { balance += n }
        \\    fun statement(): String = "balance=$balance"
        \\}
        \\fun main() {
        \\    val v = Vault()
        \\    v.deposit(50)
        \\    v.deposit(25)
        \\    println(v.statement())
        \\}
        \\
    ;
    try assertKlio("private_prop", src, "balance=175\n");
}

test "protected_with_secondary_constructors" {
    const src =
        \\
        \\open class P {
        \\    protected var label: String
        \\    constructor(s: String) { label = s }
        \\    constructor() : this("default")
        \\    fun show(): String = "label=$label"
        \\}
        \\class Q : P {
        \\    constructor() : super()
        \\    constructor(s: String) : super(s)
        \\    fun mutate(s: String) { label = "q:$s" }
        \\}
        \\fun main() {
        \\    val q = Q()
        \\    val r = Q("init")
        \\    q.mutate("hello")
        \\    println("${q.show()}|${r.show()}")
        \\}
        \\
    ;
    try assertKlio("protected_ctor", src, "label=q:hello|label=init\n");
}

test "private_setter_with_public_getter" {
    const src =
        \\
        \\class Counter {
        \\    var n: Int = 0
        \\        private set
        \\    fun bump() { n += 1 }
        \\}
        \\fun main() {
        \\    val c = Counter()
        \\    c.bump(); c.bump()
        \\    println(c.n)
        \\}
        \\
    ;
    try assertKlio("private_set", src, "2\n");
}
