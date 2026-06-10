//! Object-initialization parity: lazy first-access `object` / companion
//! construction, once-only initialization (including under racing OS
//! threads), declaration-order interleaving of init blocks and property
//! initializers in object literals, and init-failure propagation
//! (`FileFailedToInitializeException` at the access site, no retry).
//! Every expectation here is pinned against kotlinc-native 2.3.10.

const std = @import("std");
const parity = @import("parity");

const TMP_DIR = "/tmp/klio_itest_object_init";

// One file-scoped arena over the page allocator backs every run here, same
// as the sibling parity suites: the pipeline installs process-global
// lowering/VM state backed by the run's allocator, so a per-test arena
// would be torn down while those globals still point into it.
var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

fn runProgram(name: []const u8, src: []const u8) !parity.SResult([]u8) {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();

    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    std.Io.Dir.cwd().createDirPath(io, TMP_DIR) catch {};
    const path = try std.fmt.allocPrint(a, "{s}/{s}.kt", .{ TMP_DIR, name });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = src });

    return parity.runWithPacks(a, io, path);
}

/// Run `src` and assert stdout equals `expected` byte-for-byte.
fn assertKlio(name: []const u8, src: []const u8, expected: []const u8) !void {
    const res = try runProgram(name, src);
    switch (res) {
        .ok => |got| try std.testing.expectEqualStrings(expected, got),
        .err => |m| {
            std.debug.print("klio run failed for `{s}`: {s}\n", .{ name, m });
            return error.KlioRunFailed;
        },
    }
}

/// Run `src` and assert it fails with an error message containing
/// `expected_fragment`.
fn assertKlioError(name: []const u8, src: []const u8, expected_fragment: []const u8) !void {
    const res = try runProgram(name, src);
    switch (res) {
        .ok => |got| {
            std.debug.print("expected `{s}` to fail, got output:\n{s}\n", .{ name, got });
            return error.ExpectedRunFailure;
        },
        .err => |m| {
            if (std.mem.indexOf(u8, m, expected_fragment) == null) {
                std.debug.print("error for `{s}` missing `{s}`:\n{s}\n", .{ name, expected_fragment, m });
                return error.WrongRunError;
            }
        },
    }
}

// kotlinc-native: an object the program never references never runs its
// init blocks or property initializers; a referenced one initializes at
// its first access, after `main` has already started.
test "unused_object_never_initializes" {
    const src =
        \\
        \\object Unused { init { println("UNUSED-INIT") } }
        \\object Used { init { println("USED-INIT") }; val v = 7 }
        \\fun main() { println("main-start"); println(Used.v) }
        \\
    ;
    try assertKlio("unused_never_inits", src, "main-start\nUSED-INIT\n7\n");
}

// kotlinc-native: repeated access never re-runs the initializer, and the
// interleaving of property initializers and init blocks inside the object
// follows declaration order.
test "object_initializes_once_at_first_access" {
    const src =
        \\
        \\object Counter {
        \\    val a = run { println("prop:a"); 1 }
        \\    init { println("init1 a=" + a) }
        \\    val b = run { println("prop:b"); 2 }
        \\    init { println("init2 b=" + b) }
        \\}
        \\fun main() {
        \\    println("before")
        \\    println(Counter.a)
        \\    println(Counter.b)
        \\    println(Counter.a + Counter.b)
        \\}
        \\
    ;
    try assertKlio(
        "object_once_first_access",
        src,
        "before\nprop:a\ninit1 a=1\nprop:b\ninit2 b=2\n1\n2\n3\n",
    );
}

// Kotlin guarantees once-only initialization across threads: two workers
// racing the first access observe one construction. `once-init` prints
// exactly once, before either read completes.
test "object_init_once_under_racing_threads" {
    const src =
        \\import kotlin.concurrent.thread
        \\
        \\object Once { init { println("once-init") }; val v = 5 }
        \\fun main() {
        \\    var a = 0
        \\    var b = 0
        \\    val t1 = thread { a = Once.v }
        \\    val t2 = thread { b = Once.v }
        \\    t1.join()
        \\    t2.join()
        \\    println(a + b)
        \\}
        \\
    ;
    try assertKlio("object_once_threads", src, "once-init\n10\n");
}

// kotlinc-native: an object expression's init blocks run during
// construction, interleaved with the property initializers in declaration
// order (`prop:y`, init, `prop:z`).
test "anon_object_init_interleaves_with_props" {
    const src =
        \\
        \\fun log(s: String): String { println("prop:" + s); return s }
        \\fun main() {
        \\    println("main")
        \\    val anon = object {
        \\        val y = log("y")
        \\        init { println("anon-init y=" + y) }
        \\        val z = log("z")
        \\    }
        \\    println("done " + anon.z)
        \\}
        \\
    ;
    try assertKlio("anon_init_interleave", src, "main\nprop:y\nanon-init y=y\nprop:z\ndone z\n");
}

// Object-literal init blocks close over enclosing locals like method
// bodies do.
test "anon_object_init_sees_captured_locals" {
    const src =
        \\
        \\fun main() {
        \\    val n = 5
        \\    val o = object {
        \\        val a = n + 1
        \\        init { println("init sees n=" + n + " a=" + a) }
        \\        val b = a * 2
        \\        init { println("second init b=" + b) }
        \\    }
        \\    println(o.a + o.b)
        \\}
        \\
    ;
    try assertKlio("anon_init_captures", src, "init sees n=5 a=6\nsecond init b=12\n18\n");
}

// kotlinc-native: constructing an object literal over a superclass runs
// the superclass's init blocks and property initializers (in declaration
// order) before the literal's own.
test "anon_object_runs_parent_init_blocks" {
    const src =
        \\
        \\open class Base(val tag: String) {
        \\    init { println("base-init " + tag) }
        \\    val b = run { println("base-prop"); 1 }
        \\}
        \\fun main() {
        \\    println("start")
        \\    val o = object : Base("x") { init { println("anon-init") } }
        \\    println("done " + o.b)
        \\}
        \\
    ;
    try assertKlio("anon_parent_init", src, "start\nbase-init x\nbase-prop\nanon-init\ndone 1\n");
}

// kotlinc-native: a throw inside an object initializer surfaces at the
// access site as FileFailedToInitializeException with the user exception
// as its cause; a second access throws the same wrapper without the cause
// (the initializer is never retried) and partial init state is never
// observable.
test "object_init_throw_propagates_and_is_not_retried" {
    const src =
        \\
        \\object O {
        \\    val items = mutableListOf("a")
        \\    init { if (items.size == 1) throw IllegalStateException("boom") }
        \\}
        \\fun main() {
        \\    println("main-start")
        \\    try { println(O.items) } catch (e: Throwable) {
        \\        println("c1: " + e::class.simpleName + " cause=" + (e.cause?.let { it::class.simpleName } ?: "none"))
        \\    }
        \\    try { println(O.items) } catch (e: Throwable) {
        \\        println("c2: " + e::class.simpleName + " cause=" + (e.cause?.let { it::class.simpleName } ?: "none"))
        \\    }
        \\    println("main-end")
        \\}
        \\
    ;
    try assertKlio(
        "object_init_throw",
        src,
        "main-start\nc1: FileFailedToInitializeException cause=IllegalStateException\nc2: FileFailedToInitializeException cause=none\nmain-end\n",
    );
}

// kotlinc-native: the init-failure wrapper is on the `Error` side of the
// throwable hierarchy — `catch (e: Exception)` does not match it,
// `catch (e: Error)` does.
test "object_init_failure_is_error_not_exception" {
    const src =
        \\
        \\object O { init { throw IllegalStateException("boom") } }
        \\fun main() {
        \\    try { println(O) } catch (e: Exception) { println("caught Exception") } catch (e: Throwable) { println("first: Throwable, not Exception") }
        \\    try { println(O) } catch (e: Error) { println("caught Error") } catch (e: Throwable) { println("second: Throwable, not Error") }
        \\    println("end")
        \\}
        \\
    ;
    try assertKlio(
        "object_init_error_side",
        src,
        "first: Throwable, not Exception\ncaught Error\nend\n",
    );
}

// An uncaught init failure aborts the program with the wrapper exception
// (kotlinc-native exits non-zero with FileFailedToInitializeException).
test "object_init_failure_uncaught_aborts" {
    const src =
        \\
        \\object O { init { throw IllegalStateException("boom") } }
        \\fun main() { println("main-start"); println(O) }
        \\
    ;
    try assertKlioError(
        "object_init_uncaught",
        src,
        "uncaught kotlin.native.internal.FileFailedToInitializeException",
    );
}

// kotlinc-native: the first instantiation of a class initializes its
// companion (property initializers + init blocks, declaration order)
// before the instance's own initialization; a later companion-member
// access does not re-run it.
test "companion_initializes_at_first_instantiation" {
    const src =
        \\
        \\class WithComp {
        \\    init { println("inst-init") }
        \\    companion object {
        \\        val x = run { println("comp-prop-x"); 41 }
        \\        init { println("comp-init") }
        \\    }
        \\}
        \\fun main() {
        \\    println("main-start")
        \\    val w = WithComp()
        \\    println("constructed")
        \\    println(WithComp.x)
        \\}
        \\
    ;
    try assertKlio(
        "companion_at_instantiation",
        src,
        "main-start\ncomp-prop-x\ncomp-init\ninst-init\nconstructed\n41\n",
    );
}

// kotlinc-native: instantiating a subclass initializes the subclass's
// companion first, then its superclass's.
test "subclass_instantiation_initializes_companion_chain" {
    const src =
        \\
        \\open class Base { companion object { init { println("base-comp-init") }; val k = 1 } }
        \\class Sub : Base() { companion object { init { println("sub-comp-init") }; val m = 2 } }
        \\fun main() { println("start"); val s = Sub(); println("made " + (s is Base)) }
        \\
    ;
    try assertKlio(
        "companion_chain",
        src,
        "start\nsub-comp-init\nbase-comp-init\nmade true\n",
    );
}

// kotlinc-native: a companion member access initializes the companion at
// that point, and an object the companion's initializer reads initializes
// nested-first-access during it.
test "companion_lazy_at_member_access_drives_nested_object" {
    const src =
        \\
        \\object Holder { init { println("holder-init") }; val base = 10 }
        \\class Owner {
        \\    companion object { init { println("comp-init") }; val k = Holder.base + 1 }
        \\}
        \\fun main() { println("start"); println(Owner.k) }
        \\
    ;
    try assertKlio("companion_lazy_nested", src, "start\ncomp-init\nholder-init\n11\n");
}

// kotlinc-native: a companion init failure surfaces at the owning class's
// first instantiation; subsequent access throws the no-cause wrapper.
test "companion_init_failure_at_instantiation_site" {
    const src =
        \\
        \\class C { companion object { init { throw IllegalStateException("x") } } }
        \\fun main() {
        \\    try { C() } catch (e: Throwable) { println("ctor: " + e::class.simpleName + " cause=" + (e.cause?.let { it::class.simpleName } ?: "none")) }
        \\    try { println(C) } catch (e: Throwable) { println("again: " + e::class.simpleName + " cause=" + (e.cause?.let { it::class.simpleName } ?: "none")) }
        \\    println("end")
        \\}
        \\
    ;
    try assertKlio(
        "companion_init_failure",
        src,
        "ctor: FileFailedToInitializeException cause=IllegalStateException\nagain: FileFailedToInitializeException cause=none\nend\n",
    );
}

// kotlinc-native: a nested object initializes lazily at its first
// qualified access.
test "nested_object_lazy_at_qualified_access" {
    const src =
        \\
        \\class Outer { object Nested { init { println("nested-init") }; val v = 3 } }
        \\fun main() { println("main"); println(Outer.Nested.v) }
        \\
    ;
    try assertKlio("nested_object_lazy", src, "main\nnested-init\n3\n");
}

// A nested object whose simple name collides with a top-level type is
// lifted under a mangled name; the qualified access still constructs it
// lazily, once.
test "mangled_nested_object_lazy_once" {
    const src =
        \\
        \\class Box { object Item { init { println("item-init") }; val v = 9 } }
        \\class Item
        \\fun main() { println("start"); println(Box.Item.v); println(Box.Item.v + 1) }
        \\
    ;
    try assertKlio("mangled_nested_lazy", src, "start\nitem-init\n9\n10\n");
}

// kotlinc-native: `data object` follows the same lazy first-access rule.
test "data_object_lazy" {
    const src =
        \\
        \\data object D { init { println("d-init") } }
        \\fun main() { println("start"); println(D) }
        \\
    ;
    try assertKlio("data_object_lazy", src, "start\nd-init\nD\n");
}

// kotlinc-native: an object used only as an extension receiver still
// initializes when the receiver expression is evaluated.
test "object_as_extension_receiver_initializes" {
    const src =
        \\
        \\object E { init { println("e-init") } }
        \\fun Any.tag() = "tagged"
        \\fun main() { println("main"); println(E.tag()) }
        \\
    ;
    try assertKlio("object_ext_receiver", src, "main\ne-init\ntagged\n");
}

// kotlinc-native: one object's initializer reading another drives the
// dependency at that point; each initializes exactly once.
test "cross_object_dependency_initializes_in_access_order" {
    const src =
        \\
        \\object A { init { println("a-init") }; val v = 1 }
        \\object B { init { println("b-init: " + A.v) }; val w = A.v + 1 }
        \\fun main() { println("main"); println(B.w) }
        \\
    ;
    try assertKlio("cross_object_dep", src, "main\na-init\nb-init: 1\n2\n");
}

// Top-level property initializers stay eager (file order at program
// start, kotlinc main-file semantics); an object they construct on the
// way initializes nested-first-access during them, before `main`.
test "top_level_prop_init_stays_eager_and_drives_object" {
    const src =
        \\
        \\object O { init { println("o-init") }; val v = 1 }
        \\val t = run { println("t-init"); O.v }
        \\fun main() { println("main " + t) }
        \\
    ;
    try assertKlio("top_level_drives_object", src, "t-init\no-init\nmain 1\n");
}

// A top-level property initializer driven on demand by an earlier
// initializer (through an object's init reading a later property) runs
// exactly once — the startup pass does not re-run it. kotlinc-native
// reads the pre-init default (0) instead of driving the later
// initializer, so the values diverge (klio: 11, kotlinc: 1); the side
// effects and their order match.
test "forward_referenced_top_level_prop_initializes_once" {
    const src =
        \\
        \\val a = run { println("a-init"); O.v }
        \\object O { val v = b + 1 }
        \\val b = run { println("b-init"); 10 }
        \\fun main() { println("main " + a + " " + b) }
        \\
    ;
    try assertKlio("forward_ref_once", src, "a-init\nb-init\nmain 11 10\n");
}
