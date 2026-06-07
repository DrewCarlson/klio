//! kotlinx-io string-read surface through the real pack pipeline.
//!
//! `readString(byteCount)` reads a bounded prefix; `readString()` drains
//! the buffer. Both run `commonReadUtf8`, whose body constructs arrays
//! (`byteArrayOf`) and calls `min(limit, …)`. Bare `min(a, b)` here is
//! `kotlin.math.min`. These tests pin the fixed behavior.
//!
//! Ported from the Rust suite.
const std = @import("std");
const parity = @import("parity");

const TMP_DIR = "/tmp/klio_itest_kotlinx_io_read";

// The klio pipeline installs process-global lowering/VM state (inline-fn
// tables, the enclosing-`this` stack) backed by the run's allocator. A
// per-test arena would be torn down while those globals still point into it,
// so one file-scoped arena over the page allocator backs every run here (the
// leak-checking test allocator is never used, matching the e2e harness).
var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);


/// Run an embedded program through the real pack pipeline and assert its
/// stdout equals `expected`. Uses an arena per test so the leak-checking
/// test allocator never backs the pipeline.
fn run(name: []const u8, src: []const u8, expected: []const u8) !void {
    const a = file_arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, TMP_DIR) catch |e| {
        std.debug.print("kotlinx_io_read {s}: mkdir failed {s}\n", .{ name, @errorName(e) });
        return error.KlioRunFailed;
    };
    const path = try std.fmt.allocPrint(a, "{s}/{s}.kt", .{ TMP_DIR, name });
    cwd.writeFile(io, .{ .sub_path = path, .data = src }) catch |e| {
        std.debug.print("kotlinx_io_read {s}: write failed {s}\n", .{ name, @errorName(e) });
        return error.KlioRunFailed;
    };

    const res = try parity.runWithPacks(a, io, path);
    switch (res) {
        .ok => |got| try std.testing.expectEqualStrings(expected, got),
        .err => |m| {
            std.debug.print("kotlinx_io_read {s}: klio run failed: {s}\n", .{ name, m });
            return error.KlioRunFailed;
        },
    }
}

test "read_string_bounded_then_full" {
    const src =
        \\
        \\import kotlinx.io.Buffer
        \\import kotlinx.io.readString
        \\import kotlinx.io.writeString
        \\fun main() {
        \\    val b = Buffer()
        \\    b.writeString("hello world")
        \\    println(b.readString(5L))
        \\    println(b.readString())
        \\}
        \\
    ;
    try run("read_bounded_then_full", src, "hello\n world\n");
}

test "read_string_partial_prefix" {
    const src =
        \\
        \\import kotlinx.io.Buffer
        \\import kotlinx.io.readString
        \\import kotlinx.io.writeString
        \\fun main() {
        \\    val b = Buffer()
        \\    b.writeString("hello")
        \\    println(b.readString(3L))
        \\}
        \\
    ;
    try run("read_partial_prefix", src, "hel\n");
}

// Bare `min(Int, Int)` / `maxOf` resolve to the top-level math/comparison
// functions even when the full kotlinx-io corpus has registered every
// same-named array/collection receiver-extension intrinsic.
test "bare_min_max_resolve_to_toplevel_under_full_corpus" {
    const src =
        \\
        \\import kotlinx.io.Buffer
        \\import kotlin.math.min
        \\import kotlin.math.max
        \\fun main() {
        \\    val b = Buffer()
        \\    println(min(5, 3))
        \\    println(max(5, 3))
        \\    println(minOf(2, 9))
        \\    println(maxOf(2, 9))
        \\}
        \\
    ;
    try run("bare_min_max_corpus", src, "3\n5\n2\n9\n");
}

// `b.readLine()` dispatches the `Source.readLine()` extension, not the
// top-level `kotlin.io.readLine` console reader (which the member probe
// matched via `kotlin.io.{name}` and would have run against empty stdin,
// returning null). A genuine source extension on the receiver's type
// chain outranks a same-named non-extension top-level io function.
test "read_line_dispatches_source_extension_not_console" {
    const src =
        \\
        \\import kotlinx.io.Buffer
        \\import kotlinx.io.readLine
        \\import kotlinx.io.writeString
        \\fun main() {
        \\    val b = Buffer()
        \\    b.writeString("line1\nline2\n")
        \\    println(b.readLine())
        \\    println(b.readLine())
        \\    println(b.readLine())
        \\}
        \\
    ;
    try run("read_line_source_ext", src, "line1\nline2\nnull\n");
}
