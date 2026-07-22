//! Object-initialization parity: lazy first-access `object` / companion
//! construction, once-only initialization (including under racing OS
//! threads), declaration-order interleaving of init blocks and property
//! initializers in object literals, and init-failure propagation
//! (`FileFailedToInitializeException` at the access site, no retry).
//! Every expectation here is pinned against kotlinc-native 2.3.10,
//! except where a test notes kotlinc JVM 2.3.21 explicitly.

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

// A thrown exception captures the call stack at the throw site: the uncaught
// report names each frame and resolves its source position to a file + line.
test "uncaught exception reports a stack trace with source positions" {
    const src =
        \\
        \\fun inner() { throw RuntimeException("boom") }
        \\fun outer() { inner() }
        \\fun main() { outer() }
        \\
    ;
    const res = try runProgram("stack_trace_capture", src);
    switch (res) {
        .ok => |got| {
            std.debug.print("expected a failing run, got:\n{s}\n", .{got});
            return error.ExpectedRunFailure;
        },
        .err => |m| {
            const needles = [_][]const u8{
                "uncaught kotlin.RuntimeException: boom",
                "at inner (",
                "at outer (",
                "at main (",
                ".kt:",
            };
            for (needles) |n| {
                if (std.mem.indexOf(u8, m, n) == null) {
                    std.debug.print("trace missing `{s}`:\n{s}\n", .{ n, m });
                    return error.MissingTraceFragment;
                }
            }
        },
    }
}

// The trace is captured at construction (JVM `fillInStackTrace`), not at the
// throw: an exception built in one function and thrown from another reports the
// construction site, and the (later) throw site is absent.
test "stack trace is captured at construction, not at throw" {
    const src =
        \\
        \\fun make(): RuntimeException = RuntimeException("x")
        \\fun thrower(e: RuntimeException) { throw e }
        \\fun main() { val e = make(); thrower(e) }
        \\
    ;
    const res = try runProgram("stack_trace_construct", src);
    switch (res) {
        .ok => |got| {
            std.debug.print("expected a failing run, got:\n{s}\n", .{got});
            return error.ExpectedRunFailure;
        },
        .err => |m| {
            if (std.mem.indexOf(u8, m, "at make (") == null) {
                std.debug.print("trace missing construction frame `at make (`:\n{s}\n", .{m});
                return error.MissingConstructionFrame;
            }
            if (std.mem.indexOf(u8, m, "thrower") != null) {
                std.debug.print("trace should not contain the throw site `thrower`:\n{s}\n", .{m});
                return error.CapturedAtThrowNotConstruction;
            }
        },
    }
}

// A user Throwable subclass also captures at construction (its parent chain
// bottoms out at a builtin Throwable), not at the later throw site.
test "user exception subclass captures at construction" {
    const src =
        \\
        \\class AppError(msg: String) : RuntimeException(msg)
        \\fun make(): AppError = AppError("x")
        \\fun thrower(e: AppError) { throw e }
        \\fun main() { val e = make(); thrower(e) }
        \\
    ;
    const res = try runProgram("stack_trace_user_construct", src);
    switch (res) {
        .ok => |got| {
            std.debug.print("expected a failing run, got:\n{s}\n", .{got});
            return error.ExpectedRunFailure;
        },
        .err => |m| {
            if (std.mem.indexOf(u8, m, "at make (") == null) {
                std.debug.print("trace missing construction frame `at make (`:\n{s}\n", .{m});
                return error.MissingConstructionFrame;
            }
            if (std.mem.indexOf(u8, m, "thrower") != null) {
                std.debug.print("trace should not contain the throw site `thrower`:\n{s}\n", .{m});
                return error.CapturedAtThrowNotConstruction;
            }
        },
    }
}

// A wrapped exception reports its cause chain in the uncaught render.
test "uncaught exception reports the cause chain" {
    const src =
        \\
        \\fun root() { throw NumberFormatException("bad") }
        \\fun wrap() { try { root() } catch (e: Exception) { throw IllegalStateException("outer", e) } }
        \\fun main() { wrap() }
        \\
    ;
    const res = try runProgram("stack_trace_cause", src);
    switch (res) {
        .ok => |got| {
            std.debug.print("expected a failing run, got:\n{s}\n", .{got});
            return error.ExpectedRunFailure;
        },
        .err => |m| {
            const needles = [_][]const u8{
                "uncaught kotlin.IllegalStateException: outer",
                "Caused by: kotlin.NumberFormatException: bad",
                "at root (",
            };
            for (needles) |n| {
                if (std.mem.indexOf(u8, m, n) == null) {
                    std.debug.print("cause-chain trace missing `{s}`:\n{s}\n", .{ n, m });
                    return error.MissingTraceFragment;
                }
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

// Every superclass delegation in an anonymous object's constructor chain
// receives the preceding class's primary-constructor arguments.
test "anon_object_evaluates_transitive_parent_ctor_args" {
    const src =
        \\
        \\open class Root(active: Boolean) {
        \\    val state = if (active) "active" else "new"
        \\    init { println("root " + state) }
        \\}
        \\open class Middle(enabled: Boolean, val label: String) : Root(enabled)
        \\fun main() {
        \\    val item = object : Middle(false, "ready") {}
        \\    println(item.state)
        \\    println(item.label)
        \\}
        \\
    ;
    try assertKlio(
        "anon_transitive_parent_ctor_args",
        src,
        "root new\nnew\nready\n",
    );
}

// An anonymous method retains every implicit receiver visible at the object
// expression, including an outer class receiver displaced by a receiver
// lambda's subject.
test "anon_object_method_retains_lexical_receiver_chain" {
    const src =
        \\
        \\open class Action { open fun fire() {} }
        \\class Scope
        \\class Owner(private val prefix: String) {
        \\    private fun emit(value: String) { println(prefix + value) }
        \\    fun make(): Action = Scope().run {
        \\        object : Action() {
        \\            override fun fire() { emit("ready") }
        \\        }
        \\    }
        \\}
        \\fun main() { Owner("outer ").make().fire() }
        \\
    ;
    try assertKlio(
        "anon_lexical_receiver_chain",
        src,
        "outer ready\n",
    );
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
// exactly once — the startup pass does not re-run it. Here `b`'s
// initializer is a HOF call (`run { … }`) whose inferred type the lowering
// cannot recover without a type checker, so the forward read drives it
// (klio: 11) where kotlinc reads the inferred field default (1). The side
// effects and their order match. An unannotated property with a
// trivially-typed LITERAL initializer is now kotlinc-faithful (see
// `forward_read_of_unannotated_literal_through_function_sees_typed_default`);
// only this non-literal, inference-required shape remains divergent.
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

// kotlinc (JVM 2.3.21): a forward read of a NOT-yet-initialized top-level
// property with an explicit `Int` annotation observes the typed field
// default 0 (so `O.v` is 1), the read does not drive `b`'s initializer
// out of order, and `b` still initializes exactly once at its file-order
// turn (`b-init` after `a-init`, `b` is 10 in main).
test "forward_read_of_annotated_int_prop_sees_typed_default" {
    const src =
        \\
        \\val a = run { println("a-init"); O.v }
        \\object O { val v = b + 1 }
        \\val b: Int = run { println("b-init"); 10 }
        \\fun main() { println("main " + a + " " + b) }
        \\
    ;
    try assertKlio("forward_ref_int_default", src, "a-init\nb-init\nmain 1 10\n");
}

// kotlinc (JVM 2.3.21): a `String`-annotated forward read observes the
// reference default null (printed "null"), with the initializer still
// running once in file order.
test "forward_read_of_annotated_string_prop_sees_null_default" {
    const src =
        \\
        \\val a = run { println("a-init"); O.v }
        \\object O { val v = "" + s }
        \\val s: String = run { println("s-init"); "hello" }
        \\fun main() { println("main " + a + " " + s) }
        \\
    ;
    try assertKlio("forward_ref_string_default", src, "a-init\ns-init\nmain null hello\n");
}

// kotlinc (JVM 2.3.21): a `Boolean`-annotated forward read observes false.
test "forward_read_of_annotated_boolean_prop_sees_false_default" {
    const src =
        \\
        \\val a = run { println("a-init"); O.v }
        \\object O { val v = flag }
        \\val flag: Boolean = run { println("flag-init"); true }
        \\fun main() { println("main " + a + " " + flag) }
        \\
    ;
    try assertKlio("forward_ref_bool_default", src, "a-init\nflag-init\nmain false true\n");
}

// kotlinc (JVM 2.3.21): an UNANNOTATED property whose initializer is a
// trivially-typed literal (`val n = 5` -> Int) defaults a forward read from
// the inferred field type just like an explicit annotation. `peek()` runs
// during `a`'s init and reads `n` before its turn, observing the inferred
// default 0; `n` then initializes normally for main. The lowering infers the
// typed default from the literal without a type checker.
test "forward_read_of_unannotated_literal_through_function_sees_typed_default" {
    const src =
        \\
        \\val a = peek()
        \\fun peek(): Int = n
        \\val n = 5
        \\fun main() { println(a); println(n) }
        \\
    ;
    try assertKlio("forward_ref_unannot_literal", src, "0\n5\n");
}

// kotlinc (JVM 2.3.21): the forward read may be mediated by a function
// call — `peek()` runs during `a`'s initializer and reads `b` before its
// turn, observing 0; `b` then initializes normally for main.
test "forward_read_through_function_call_sees_typed_default" {
    const src =
        \\
        \\val a = peek()
        \\fun peek(): Int = b
        \\val b: Int = computeB()
        \\fun computeB(): Int { println("init b"); return 42 }
        \\fun main() { println(a); println(b) }
        \\
    ;
    try assertKlio("forward_ref_fn_default", src, "init b\n0\n42\n");
}

/// Run `src` under both in-process load modes (`EmbeddedOnly` and
/// `SourcePacks`) and assert stdout equals `expected` in each. Pins
/// behavior the two stdlib assemblies must agree on.
fn assertKlioBothModes(name: []const u8, src: []const u8, expected: []const u8) !void {
    const modes = [_]parity.LoadMode{ .EmbeddedOnly, .SourcePacks };
    for (modes) |mode| {
        _ = file_arena.reset(.retain_capacity);
        const a = file_arena.allocator();

        var threaded: std.Io.Threaded = .init(a, .{});
        defer threaded.deinit();
        const io = threaded.io();

        std.Io.Dir.cwd().createDirPath(io, TMP_DIR) catch {};
        const path = try std.fmt.allocPrint(a, "{s}/{s}.kt", .{ TMP_DIR, name });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = src });

        const res = try parity.runInMode(a, io, path, mode);
        switch (res) {
            .ok => |got| std.testing.expectEqualStrings(expected, got) catch |e| {
                std.debug.print("mode {s}: output mismatch for `{s}`\n", .{ @tagName(mode), name });
                return e;
            },
            .err => |m| {
                std.debug.print("mode {s}: klio run failed for `{s}`: {s}\n", .{ @tagName(mode), name, m });
                return error.KlioRunFailed;
            },
        }
    }
}

// An anonymous object's property initializer that calls an inline
// stdlib HOF (`run`): the lambda is a closure created inside the
// runtime-lowered init thunk's sub-module, so its body must resolve
// against that sub-module, never the main func table (kotlinc:
// "anon: first" then "1").
test "anon_object_prop_init_through_inline_hof" {
    const src =
        \\fun main() {
        \\    val probe = object {
        \\        val first = run { println("anon: first"); 1 }
        \\    }
        \\    println(probe.first)
        \\}
        \\
    ;
    try assertKlioBothModes("anon_prop_init_inline_hof", src, "anon: first\n1\n");
}

// An anonymous Continuation whose overridden `context` property is
// initialized from the `EmptyCoroutineContext` singleton by bare name:
// the initializer must bind the object singleton, not null and not the
// bare class value (kotlinc: "hi").
test "anon_continuation_context_initializer_binds_singleton" {
    const src =
        \\import kotlin.coroutines.*
        \\
        \\fun runIt(block: suspend () -> Unit) {
        \\    block.startCoroutine(object : Continuation<Unit> {
        \\        override val context = EmptyCoroutineContext
        \\        override fun resumeWith(result: Result<Unit>) {}
        \\    })
        \\}
        \\fun main() {
        \\    runIt { println("hi") }
        \\}
        \\
    ;
    try assertKlioBothModes("anon_continuation_ctx_init", src, "hi\n");
}

// Anonymous-object property initializers reading enclosing-scope names
// by bare identifier: a top-level `val`, a user `object` singleton (the
// value is the singleton — its `toString` override dispatches), and a
// stdlib singleton, alongside a call and a constructor (kotlinc:
// 7 / 9 / true / MyObj! / EmptyCoroutineContext).
test "anon_object_prop_init_reads_globals_and_singletons" {
    const src =
        \\import kotlin.coroutines.*
        \\object MyObj { override fun toString() = "MyObj!" }
        \\val g = 7
        \\fun f() = 9
        \\class C
        \\fun main() {
        \\    val a = object {
        \\        val fromGlobal = g
        \\        val fromFun = f()
        \\        val fromCtor = C()
        \\        val fromObj = MyObj
        \\        val fromStdlibObj = EmptyCoroutineContext
        \\    }
        \\    println(a.fromGlobal)
        \\    println(a.fromFun)
        \\    println(a.fromCtor != null)
        \\    println(a.fromObj)
        \\    println(a.fromStdlibObj)
        \\}
        \\
    ;
    try assertKlioBothModes(
        "anon_prop_init_globals_singletons",
        src,
        "7\n9\ntrue\nMyObj!\nEmptyCoroutineContext\n",
    );
}

// Supertype constructor args of an object expression evaluate for real
// in the enclosing scope: a top-level `val` by bare name, a compound
// expression over it, and a captured local (kotlinc: 5 / 6 / 4).
test "anon_object_super_ctor_args_evaluate_in_enclosing_scope" {
    const src =
        \\val g = 5
        \\open class Base(val n: Int)
        \\fun main() {
        \\    val a = object : Base(g) {}
        \\    println(a.n)
        \\    val b = object : Base(g + 1) {}
        \\    println(b.n)
        \\    val lc = 3
        \\    val c = object : Base(lc + 1) {}
        \\    println(c.n)
        \\}
        \\
    ;
    try assertKlioBothModes("anon_super_ctor_args", src, "5\n6\n4\n");
}
