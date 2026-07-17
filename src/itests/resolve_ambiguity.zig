//! Bare-call resolution tightening: an unqualified call whose candidate
//! set holds two same-package same-arity functions with identical FULL
//! parameter signatures (generic arguments and function-type shapes
//! included) is rejected at lowering. Two declarations sharing one FQN
//! report as conflicting overloads naming both declaration sites;
//! cross-package ties report as an ambiguous reference the caller can
//! qualify or import. Type-distinguishable overload sets,
//! cast-disambiguated calls, and default-parameter shapes keep
//! resolving — the last order-independently.

const std = @import("std");
const parity = @import("parity");

const TMP_DIR = "/tmp/klio_itest_resolve_ambiguity";

// One file-scoped arena over the page allocator backs every run here:
// the pipeline installs process-global lowering/VM state backed by the
// run's allocator, so the leak-checking test allocator is never used.
var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

const RunResult = union(enum) {
    ok: []u8,
    err: []u8,
};

fn runKlio(name: []const u8, src: []const u8) !RunResult {
    return runKlioFiles(name, &.{src});
}

/// Write each source as `{name}_{i}.kt` and run them as one program, in
/// order — the in-process mirror of `klio run a.kt b.kt`, for the
/// cross-package shapes that need one package header per file.
fn runKlioFiles(name: []const u8, srcs: []const []const u8) !RunResult {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();

    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    std.Io.Dir.cwd().createDirPath(io, TMP_DIR) catch {};
    var paths: std.ArrayList([]const u8) = .empty;
    for (srcs, 0..) |src, i| {
        const path = if (srcs.len == 1)
            try std.fmt.allocPrint(a, "{s}/{s}.kt", .{ TMP_DIR, name })
        else
            try std.fmt.allocPrint(a, "{s}/{s}_{d}.kt", .{ TMP_DIR, name, i });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = src });
        try paths.append(a, path);
    }

    return switch (try parity.runFilesWithPacks(a, io, paths.items)) {
        .ok => |got| .{ .ok = got },
        .err => |m| .{ .err = m },
    };
}

fn expectFilesOutput(name: []const u8, srcs: []const []const u8, expected: []const u8) !void {
    switch (try runKlioFiles(name, srcs)) {
        .ok => |got| try std.testing.expectEqualStrings(expected, got),
        .err => |m| {
            std.debug.print("klio run failed for `{s}`: {s}\n", .{ name, m });
            return error.KlioRunFailed;
        },
    }
}

fn expectFilesErrContains(name: []const u8, srcs: []const []const u8, needle: []const u8) !void {
    switch (try runKlioFiles(name, srcs)) {
        .ok => |got| {
            std.debug.print("expected a lowering diagnostic for `{s}`, program ran: {s}\n", .{ name, got });
            return error.ExpectedResolutionDiagnostic;
        },
        .err => |m| {
            if (std.mem.indexOf(u8, m, needle) == null) {
                std.debug.print("diagnostic for `{s}` missing `{s}`:\n{s}\n", .{ name, needle, m });
                return error.WrongDiagnostic;
            }
        },
    }
}

fn expectOutput(name: []const u8, src: []const u8, expected: []const u8) !void {
    switch (try runKlio(name, src)) {
        .ok => |got| try std.testing.expectEqualStrings(expected, got),
        .err => |m| {
            std.debug.print("klio run failed for `{s}`: {s}\n", .{ name, m });
            return error.KlioRunFailed;
        },
    }
}

/// Assert the program is rejected at lowering with EXACTLY the expected
/// diagnostic. `expected_fmt` receives the program's on-disk path once
/// per `{s}` placeholder so the test pins the rendered file:line
/// locations.
fn expectExactErr(name: []const u8, src: []const u8, comptime expected_fmt: []const u8) !void {
    const a = file_arena.allocator();
    switch (try runKlio(name, src)) {
        .ok => |got| {
            std.debug.print("expected a lowering diagnostic for `{s}`, program ran: {s}\n", .{ name, got });
            return error.ExpectedResolutionDiagnostic;
        },
        .err => |m| {
            const path = try std.fmt.allocPrint(a, "{s}/{s}.kt", .{ TMP_DIR, name });
            const expected = try replaceAll(a, expected_fmt, path);
            try std.testing.expectEqualStrings(expected, m);
        },
    }
}

fn replaceAll(a: std.mem.Allocator, comptime fmt: []const u8, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var rest: []const u8 = fmt;
    while (std.mem.indexOf(u8, rest, "%PATH%")) |i| {
        try out.appendSlice(a, rest[0..i]);
        try out.appendSlice(a, path);
        rest = rest[i + "%PATH%".len ..];
    }
    try out.appendSlice(a, rest);
    return out.toOwnedSlice(a);
}

test "two same-package same-signature funcs are conflicting overloads" {
    const src =
        \\package app
        \\fun greet(who: String): String = "hi " + who
        \\fun greet(name: String): String = "yo " + name
        \\fun main() { println(greet("k")) }
        \\
    ;
    try expectExactErr(
        "same_sig_same_pkg",
        src,
        "%PATH%:4: error: conflicting overloads of `greet`: identical signatures declared at %PATH%:2 and %PATH%:3 — rename or remove one of the declarations",
    );
}

test "two same-signature funcs in the default package conflict" {
    const src =
        \\fun pick(n: Int): Int = n + 1
        \\fun pick(m: Int): Int = m + 2
        \\fun main() { println(pick(1)) }
        \\
    ;
    try expectExactErr(
        "same_sig_default_pkg",
        src,
        "%PATH%:3: error: conflicting overloads of `pick`: identical signatures declared at %PATH%:1 and %PATH%:2 — rename or remove one of the declarations",
    );
}

test "the conflicting-overloads diagnostic fires for a forward reference too" {
    const src =
        \\fun main() { println(tag(7)) }
        \\fun tag(a: Int): String = "a" + a
        \\fun tag(b: Int): String = "b" + b
        \\
    ;
    try expectExactErr(
        "same_sig_forward",
        src,
        "%PATH%:1: error: conflicting overloads of `tag`: identical signatures declared at %PATH%:2 and %PATH%:3 — rename or remove one of the declarations",
    );
}

test "same-arity different-type overloads keep resolving by argument type" {
    const src =
        \\fun describe(x: Int): String = "int:" + x
        \\fun describe(x: String): String = "str:" + x
        \\fun main() {
        \\    println(describe(1))
        \\    println(describe("a"))
        \\}
        \\
    ;
    try expectOutput("type_overloads_ok", src, "int:1\nstr:a\n");
}

test "overloads differing only in generic arguments keep resolving" {
    // `List<Int>` vs `List<String>` is a legal Kotlin overload set —
    // signature identity is judged on the FULL declared type, so this
    // classifies as a type overload, never an ambiguity.
    const src =
        \\fun pick(xs: List<Int>): String = "li:" + xs.size
        \\fun pick(xs: List<String>): String = "ls:" + xs.size
        \\fun main() { println(pick(listOf(1, 2))) }
        \\
    ;
    try expectOutput("generic_arg_overloads_ok", src, "li:2\n");
}

test "overloads differing only in function-type shapes keep resolving" {
    // `(Int) -> Int` vs `(String) -> String`: same arity, same head
    // (`Function1`), different component types — a legal Kotlin
    // overload set, never a duplicate. The call exercises the first
    // declaration so the assertion is independent of the runtime's
    // overload pick for the other shape.
    const src =
        \\fun call(f: (Int) -> Int): String = "int-fn:" + f(1)
        \\fun call(f: (String) -> String): String = "str-fn:" + f("a")
        \\fun main() { println(call({ n: Int -> n + 1 })) }
        \\
    ;
    try expectOutput("fn_shape_overloads_ok", src, "int-fn:2\n");
}

test "overloads differing in a generic vs concrete array keep resolving" {
    const src =
        \\fun h(x: Array<Int>): String = "arrInt:" + x.size
        \\fun <T> h(x: Array<T>): String = "arrT:" + x.size
        \\fun main() { println(h(arrayOf(1, 2))) }
        \\
    ;
    try expectOutput("generic_param_overloads_ok", src, "arrInt:2\n");
}

test "different arities of the same name keep resolving" {
    const src =
        \\fun area(w: Int): Int = w * w
        \\fun area(w: Int, h: Int): Int = w * h
        \\fun main() { println(area(3) + area(2, 5)) }
        \\
    ;
    try expectOutput("arity_overloads_ok", src, "19\n");
}

test "exact-arity overload outranks a reified vararg inline sibling" {
    // Kotlin specificity: the fixed-arity declaration wins over the
    // vararg one. The inline-fn fold must not pre-empt this — the
    // simple-name inline table only ever holds the inline overloads
    // (the kotlinx `Migration.kt` `combineLatest` mis-bind). The second
    // call is the fold-sensitive pin: its arity equals the inline
    // vararg sibling's parameter count, so a name-first pick splices
    // the reified body with `xs` bound to the scalar `5` and crashes on
    // `xs.size`; only the index-first pick — with the vararg shape
    // skipped at ANY parameter position, not just the last — binds the
    // exact `(Int, transform)` overload kotlinc binds. The first call's
    // 3-scalar shape never splices under either picker (the vararg body
    // cannot bind two extra positionals) and pins the plain-ladder
    // binding instead.
    const src =
        \\inline fun <reified T> pick(vararg xs: T, transform: (Int) -> Int): String = "vararg " + transform(xs.size)
        \\fun pick(a: Int, b: Int, c: Int): String = "exact " + (a + b + c)
        \\fun pick(a: Int, transform: (Int) -> Int): String = "exact " + transform(a)
        \\fun main() {
        \\    println(pick(1, 2, 3))
        \\    println(pick(5) { it * 10 })
        \\}
        \\
    ;
    try expectOutput("inline_vararg_vs_exact", src, "exact 6\nexact 50\n");
}

test "a named import outranks a same-package reified inline namesake, and strict mode accepts it" {
    // kotlinc: the file's explicit `import lib2.greet` outranks the
    // caller's own-package declaration, so the non-inline import wins
    // and prints "lib-noninline". The index resolves it at the named-
    // import tier and the non-inline winner suppresses the splice; the
    // resolve audit must grade the simple-name table's reified pick as
    // a TIER correction — a program property, not a divergence — so
    // KLIO_RESOLVE_STRICT (forced on here) accepts the program instead
    // of panicking on valid Kotlin.
    const ir = @import("ir");
    ir.lower.expr.setResolveStrictForTest(true);
    defer ir.lower.expr.resetResolveStrictForTest();
    const lib2 =
        \\package lib2
        \\fun greet(): String = "lib-noninline"
        \\
    ;
    const app =
        \\package app
        \\import lib2.greet
        \\inline fun <reified T> greet(): String = "app-inline"
        \\fun main() { println(greet()) }
        \\
    ;
    try expectFilesOutput("named_import_vs_inline_strict", &.{ app, lib2 }, "lib-noninline\n");
}

test "a cast-disambiguated overload call keeps resolving" {
    const src =
        \\fun show(x: Int): String = "int"
        \\fun show(x: Any): String = "any"
        \\fun main() {
        \\    val v: Any = 3
        \\    println(show(v as Int))
        \\}
        \\
    ;
    try expectOutput("cast_pick_ok", src, "int\n");
}

test "expect/actual top-level pair binds the actual body" {
    // The build drops a top-level `expect` superseded by its `actual`,
    // so the call set holds exactly one candidate and the symbol index
    // resolves it (an expect/actual pair must never report as
    // conflicting overloads). kotlinc cannot compile this standalone
    // (multiplatform-only), so it lives here rather than in examples/.
    const src =
        \\expect fun platformName(): String
        \\actual fun platformName(): String = "klio"
        \\expect fun greet(who: String): String
        \\actual fun greet(who: String): String = "hello, " + who
        \\expect val answer: Int
        \\actual val answer: Int = 42
        \\fun main() {
        \\    println(platformName())
        \\    println(greet("expect/actual"))
        \\    println(answer)
        \\}
        \\
    ;
    try expectOutput("expect_actual_toplevel", src, "klio\nhello, expect/actual\n42\n");
}

test "an expect decl over an embedded intrinsic is dropped at build and the call binds the intrinsic" {
    // What this pins: the BUILD-side drop (`retainDecl` removes an
    // `expect` whose `kotlin.{name}` FQN is an embedded intrinsic) plus
    // the link-settled bare-name map edge for `intArrayOf`. The decl
    // does NOT survive to the VM, so the bodyless redirect / native-form
    // machinery is never consulted here — that seam is pinned by the
    // `resolvedRedirectTarget` unit tests in `interp_ir.zig`.
    const src =
        \\expect fun intArrayOf(vararg elements: Int): IntArray
        \\fun main() {
        \\    val xs = intArrayOf(3, 1, 2)
        \\    println(xs.size)
        \\    println(xs[0] + xs[2])
        \\}
        \\
    ;
    try expectOutput("expect_native_backed", src, "3\n5\n");
}

test "default-param twins resolve the same in either declaration order" {
    // A candidate with a default parameter is deferred by the stub gate
    // AND the body gate, so the verdict cannot flip on whether the
    // bodies lowered before the call site. (kotlinc rejects this pair
    // as conflicting overloads; klio's diagnostic does not yet cover
    // default-param shapes — both orders defer to the heuristic pick.)
    const decls_first =
        \\fun g(x: Int, y: Int = 0): Int = x + y
        \\fun g(a: Int, b: Int = 1): Int = a + b
        \\fun main() { println(g(1, 2)) }
        \\
    ;
    const decls_last =
        \\fun main() { println(g(1, 2)) }
        \\fun g(x: Int, y: Int = 0): Int = x + y
        \\fun g(a: Int, b: Int = 1): Int = a + b
        \\
    ;
    try expectOutput("default_twins_decls_first", decls_first, "3\n");
    try expectOutput("default_twins_decls_last", decls_last, "3\n");
}

test "expect-fn default parameter values transfer to the superseding actual" {
    // Kotlin: defaults are declared on the `expect` only; the `actual`
    // inherits them. The build transplants the expect's defaults onto
    // the retained actual before the expect is dropped.
    const src =
        \\expect fun greet(who: String = "world"): String
        \\actual fun greet(who: String): String = "hello, " + who
        \\expect fun twice(x: Int = 21): Int
        \\actual fun twice(x: Int): Int = x * 2
        \\fun main() {
        \\    println(greet())
        \\    println(greet("kotlin"))
        \\    println(twice())
        \\}
        \\
    ;
    try expectOutput("expect_defaults", src, "hello, world\nhello, kotlin\n42\n");
}

test "a bare value reference never binds the extension twin, in either order" {
    // `fun String.deco` and `fun deco` share the receiverless FQN string;
    // the reference must bind the plain form regardless of declaration
    // order (the resolved FuncId is carried on the LoadGlobal).
    const ext_first =
        \\package app
        \\fun String.deco(): String = "ext:" + this
        \\fun deco(): String = "plain"
        \\fun main() {
        \\    val g = ::deco
        \\    println(g())
        \\}
        \\
    ;
    const plain_first =
        \\package app
        \\fun deco(): String = "plain"
        \\fun String.deco(): String = "ext:" + this
        \\fun main() {
        \\    val g = ::deco
        \\    println(g())
        \\}
        \\
    ;
    try expectOutput("ext_twin_ref_a", ext_first, "plain\n");
    try expectOutput("ext_twin_ref_b", plain_first, "plain\n");
}

const xpkg_lib =
    \\package liba
    \\fun tag(): String = "liba"
    \\
;
const xpkg_main =
    \\fun tag(): String = "app"
    \\fun main() {
    \\    println(tag())
    \\    val f = ::tag
    \\    println(f())
    \\    println(run(::tag))
    \\}
    \\
;

test "::name binds from the caller's scope, not declaration order" {
    // kotlinc: app / app / app in both file orders.
    try expectFilesOutput("xpkg_ref_lib_first", &.{ xpkg_lib, xpkg_main }, "app\napp\napp\n");
    try expectFilesOutput("xpkg_ref_main_first", &.{ xpkg_main, xpkg_lib }, "app\napp\napp\n");
}

const xcls_lib =
    \\package libc
    \\class Box(val v: Int) { fun tag(): String = "libc:" + v }
    \\
;
const xcls_main =
    \\class Box(val v: Int) { fun tag(): String = "root:" + v }
    \\fun main() {
    \\    println(Box(1).tag())
    \\    val f = ::Box
    \\    println(f(2).tag())
    \\    println(listOf(3).map(::Box).map { it.tag() })
    \\}
    \\
;

test "cross-package class collision constructs the caller's class in either order" {
    // kotlinc: root:* for all three forms regardless of file order.
    const want = "root:1\nroot:2\n[root:3]\n";
    try expectFilesOutput("xpkg_cls_main_first", &.{ xcls_main, xcls_lib }, want);
    try expectFilesOutput("xpkg_cls_lib_first", &.{ xcls_lib, xcls_main }, want);
}

const xobj_ga_decl =
    \\package com.ga
    \\sealed class Operation(val n: Int) {
    \\    object Marker : Operation(1) { val tag = "A" }
    \\}
    \\
;
const xobj_gb_decl =
    \\package com.gb
    \\sealed class Operation(val n: Int) {
    \\    object Marker : Operation(2) { val tag = "B" }
    \\}
    \\
;
const xobj_ga_use =
    \\package com.ga
    \\import com.ga.Operation.Marker
    \\class Ops {
    \\    var last: Operation? = null
    \\    fun push(op: Operation) { last = op }
    \\}
    \\class ChangeList {
    \\    val operations = Ops()
    \\    fun pushMarker() { operations.push(Marker) }
    \\}
    \\fun runA(): String {
    \\    val cl = ChangeList()
    \\    cl.pushMarker()
    \\    val pushed = cl.operations.last
    \\    return "" + pushed?.n + (pushed === Marker) + (pushed is Marker)
    \\}
    \\
;
const xobj_gb_use =
    \\package com.gb
    \\import com.gb.Operation.Marker
    \\class Ops {
    \\    var last: Operation? = null
    \\    fun push(op: Operation) { last = op }
    \\}
    \\class ChangeList {
    \\    val operations = Ops()
    \\    fun pushMarker() { operations.push(Marker) }
    \\}
    \\fun runB(): String {
    \\    val cl = ChangeList()
    \\    cl.pushMarker()
    \\    val pushed = cl.operations.last
    \\    return "" + pushed?.n + (pushed === Marker) + (pushed is Marker)
    \\}
    \\
;
const xobj_main =
    \\import com.ga.runA
    \\import com.gb.runB
    \\fun main() {
    \\    println(runA())
    \\    println(runB())
    \\}
    \\
;

test "same-simple-name nested object twins bind own-package singletons in either order" {
    // Two packages each declare `object Marker` nested in a same-named
    // sealed class (the gapbuffer/linkbuffer `Operation.*` op shape): both
    // lift to the same `Operation$Marker` simple name, so every read must
    // resolve through the declaring class's FQN — a name-keyed pick binds
    // whichever twin registered the name. The `is` check must compare the
    // imported class's identity, not the unregistered bare simple name.
    const want = "1truetrue\n2truetrue\n";
    try expectFilesOutput("xpkg_obj_ga_first", &.{ xobj_main, xobj_ga_decl, xobj_ga_use, xobj_gb_decl, xobj_gb_use }, want);
    try expectFilesOutput("xpkg_obj_gb_first", &.{ xobj_main, xobj_gb_decl, xobj_gb_use, xobj_ga_decl, xobj_ga_use }, want);
}

test "cross-package data-class twins keep their own arity and copy() in either order" {
    const root_p =
        \\data class P(val x: Int, val y: Int)
        \\fun main() {
        \\    println(P(1, 2))
        \\    println(P(3, 4).copy(y = 9))
        \\    println(libd.mk())
        \\}
        \\
    ;
    const libd_p =
        \\package libd
        \\data class P(val x: Int)
        \\fun mk(): P = P(7).copy(x = 8)
        \\
    ;
    const want = "P(x=1, y=2)\nP(x=3, y=9)\nP(x=8)\n";
    try expectFilesOutput("xpkg_data_main_first", &.{ root_p, libd_p }, want);
    try expectFilesOutput("xpkg_data_libd_first", &.{ libd_p, root_p }, want);
}

test "a cross-package bare call without an import is an unresolved reference" {
    // kotlinc rejects this shape outright; the diagnostic names the
    // candidates and how to import one. Both file orders.
    const liba =
        \\package liba
        \\fun f(): String = "liba.f"
        \\
    ;
    const libb =
        \\package libb
        \\fun f(): String = "libb.f"
        \\
    ;
    const caller =
        \\package app
        \\fun main() { println(f()) }
        \\
    ;
    try expectFilesErrContains("xpkg_unresolved_ab", &.{ liba, libb, caller }, "unresolved reference `f`");
    try expectFilesErrContains("xpkg_unresolved_ba", &.{ libb, liba, caller }, "unresolved reference `f`");
    // A single out-of-scope candidate is unresolved too, and the
    // diagnostic says how to import it.
    try expectFilesErrContains("xpkg_unresolved_one", &.{ liba, caller }, "add `import liba.f`");
    // An explicit import resolves the same call.
    const caller_imp =
        \\package app
        \\import liba.f
        \\fun main() { println(f()) }
        \\
    ;
    try expectFilesOutput("xpkg_imported_ok", &.{ liba, libb, caller_imp }, "liba.f\n");
}

// An `actual` implements the `expect` that shares its package. Matching the
// pair by SIMPLE NAME let any actual supersede every same-named expect in the
// program, whatever package it lived in: `p2`'s actual deleted `p1`'s expect
// from the symbol table, and `p1`'s importers — who name it explicitly — were
// left with no candidate but `p2`'s, in a package they do not import. The
// expect survives now, so the call binds it and reports the missing actual.
test "an actual supersedes only the expect in its own package" {
    try expectFilesErrContains(
        "expect_actual_pkg",
        &.{
            \\package p1
            \\
            \\expect fun greet(n: Int): String
            ,
            \\package p2
            \\
            \\expect fun greet(n: Int): String
            ,
            \\package p2
            \\
            \\actual fun greet(n: Int): String = "p2-actual-$n"
            ,
            \\package app
            \\
            \\import p1.greet
            \\
            \\fun main() {
            \\    println(greet(7))
            \\}
        },
        "`p1.greet` is an `expect` with no `actual`",
    );
}

// The runtime overload re-pick ranks the candidates lowering could not tell
// apart from argument shapes; it is not a second scope resolution. A BODYLESS
// target (an `expect` with no `actual` here) has no signature to score, so
// every body-bearing namesake in the program used to outrank it and the call
// silently ran an unrelated package's function instead of reporting the
// missing actual.
test "an unimplemented expect reports itself, not a same-named function elsewhere" {
    try expectFilesErrContains(
        "expect_no_actual",
        &.{
            \\package p1
            \\
            \\expect fun render(n: Int): String
            ,
            \\package p2
            \\
            \\fun render(n: Int): String = "p2-$n"
            ,
            \\package app
            \\
            \\import p1.render
            \\
            \\fun main() {
            \\    println(render(3))
            \\}
        },
        "`p1.render` is an `expect` with no `actual`",
    );
}
