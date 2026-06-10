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
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();

    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    std.Io.Dir.cwd().createDirPath(io, TMP_DIR) catch {};
    const path = try std.fmt.allocPrint(a, "{s}/{s}.kt", .{ TMP_DIR, name });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = src });

    return switch (try parity.runWithPacks(a, io, path)) {
        .ok => |got| .{ .ok = got },
        .err => |m| .{ .err = m },
    };
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
