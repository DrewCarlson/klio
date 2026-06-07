//! kotlinx.atomicfu atomic-array surface. The array types' bare simple
//! names (`AtomicIntArray` etc.) used to ambiguate with the unimplemented
//! `kotlin.concurrent.atomics` `expect` classes the stdlib pack carried,
//! so a user import failed at runtime; the stdlib pack no longer bundles
//! those array `expect`s.
//!
//! Port of the Rust suite.

const std = @import("std");
const parity = @import("parity");

const TMP_DIR = "/tmp/klio_itest_atomicfu_arrays";

// The klio pipeline installs process-global lowering/VM state (inline-fn
// tables, the enclosing-`this` stack) backed by the run's allocator. A
// per-test arena would be torn down while those globals still point into it,
// so one file-scoped arena over the page allocator backs every run here (the
// leak-checking test allocator is never used, matching the e2e harness).
var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);


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

test "atomic_int_array_get_set_and_size" {
    const src =
        \\
        \\import kotlinx.atomicfu.AtomicIntArray
        \\fun main() {
        \\    val a = AtomicIntArray(3)
        \\    a[0].value = 42
        \\    a[2].value = 7
        \\    println("${a[0].value},${a[1].value},${a[2].value},${a.size}")
        \\}
        \\
    ;
    try assertKlio("atomic_int_array", src, "42,0,7,3\n");
}

test "atomic_array_of_nulls" {
    const src =
        \\
        \\import kotlinx.atomicfu.atomicArrayOfNulls
        \\fun main() {
        \\    val a = atomicArrayOfNulls<String>(4)
        \\    a[0].value = "x"
        \\    println("${a[0].value},${a[1].value},${a.size}")
        \\}
        \\
    ;
    try assertKlio("atomic_array_of_nulls", src, "x,null,4\n");
}

test "locks_run_uncontended" {
    const src =
        \\
        \\import kotlinx.atomicfu.locks.reentrantLock
        \\import kotlinx.atomicfu.locks.withLock
        \\import kotlinx.atomicfu.locks.SynchronizedObject
        \\import kotlinx.atomicfu.locks.synchronized
        \\import kotlinx.atomicfu.locks.SynchronousMutex
        \\fun main() {
        \\    val lock = reentrantLock()
        \\    println(lock.withLock { 42 })
        \\    println(synchronized(SynchronizedObject()) { "ok" })
        \\    println(SynchronousMutex().withLock { "done" })
        \\}
        \\
    ;
    try assertKlio("atomicfu_locks", src, "42\nok\ndone\n");
}

test "scalar_atomic_still_works" {
    const src =
        \\
        \\import kotlinx.atomicfu.atomic
        \\fun main() {
        \\    val a = atomic(0)
        \\    a.value = 7
        \\    println(a.compareAndSet(7, 9))
        \\    println(a.value)
        \\}
        \\
    ;
    try assertKlio("scalar_atomic", src, "true\n9\n");
}
