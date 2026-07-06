//! Context parameters (Kotlin 2.4): the acceptance matrix.
//!
//! Declarations and implicit resolution. Runtime rows run the full parity
//! pipeline and assert stdout; diagnostic rows run lexer -> parser ->
//! resolver -> typeck and assert the compiler-named diagnostic plus its
//! message. The two carve-outs excluded from 2.4 (explicit context
//! arguments, callable references to contextual declarations) are asserted
//! to produce their rejection diagnostics.
//!
//! All 24 matrix rows are covered, including T14's fully-positional
//! invocation of a multi-context contextual function-type value, which
//! splits its leading context arguments onto the context stack (`CtxCall`).

const std = @import("std");
const parity = @import("parity");
const lexer = @import("lexer");
const parser = @import("parser");
const resolver = @import("resolver");
const typeck = @import("typeck");
const span = @import("span");
const diagnostics = @import("diagnostics");

const FileId = span.FileId;
const Diagnostic = diagnostics.Diagnostic;

const TMP_DIR = "/tmp/klio_itest_context_parameters";

var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

fn assertKlio(name: []const u8, src: []const u8, expected: []const u8) !void {
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

fn frontendDiags(a: std.mem.Allocator, src: []const u8) ![]const Diagnostic {
    var lx = try lexer.Lexer.init(a, FileId.from(0), src);
    const lexed = try lx.tokenize();
    const p = parser.Parser.new(a, FileId.from(0), src, lexed.tokens);
    const kf = p.parseFile();
    var out: std.ArrayList(Diagnostic) = .empty;
    try out.appendSlice(a, p.diagnostics.diags());
    if (!p.diagnostics.hasErrors()) {
        var r = try resolver.resolve(a, &kf);
        var tc = try typeck.typecheck(a, &kf, &r);
        try out.appendSlice(a, tc.diagnostics.diags());
    }
    return out.items;
}

/// Assert `src` produces a diagnostic whose factory name is `factory_name`
/// and whose message contains `msg_needle`.
fn assertDiag(src: []const u8, factory_name: []const u8, msg_needle: []const u8) !void {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const diags = try frontendDiags(a, src);
    for (diags) |d| {
        const fname = if (d.factory) |f| f.name else continue;
        if (!std.mem.eql(u8, fname, factory_name)) continue;
        if (std.mem.indexOf(u8, d.message, msg_needle) != null) return;
    }
    std.debug.print("expected `{s}` containing `{s}`; got:\n", .{ factory_name, msg_needle });
    for (diags) |d| {
        const fname = if (d.factory) |f| f.name else "-";
        std.debug.print("  [{s}] {s}\n", .{ fname, d.message });
    }
    return error.MissingExpectedDiagnostic;
}

/// Count how many diagnostics carry the given factory name.
fn countDiag(src: []const u8, factory_name: []const u8) !usize {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const diags = try frontendDiags(a, src);
    var n: usize = 0;
    for (diags) |d| {
        if (d.factory) |f| {
            if (std.mem.eql(u8, f.name, factory_name)) n += 1;
        }
    }
    return n;
}

fn assertNoErrors(src: []const u8) !void {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const diags = try frontendDiags(a, src);
    for (diags) |d| {
        if (d.severity == .Error) {
            std.debug.print("unexpected error: {s}\n", .{d.message});
            return error.UnexpectedError;
        }
    }
}

// T1 — happy path, named parameter + stdlib `context`.
test "t01_named_parameter_stdlib_context" {
    const src =
        \\interface Logger { fun log(m: String) }
        \\context(logger: Logger) fun say(m: String) = logger.log("L: $m")
        \\fun main() = context(object : Logger { override fun log(m: String) = println(m) }) {
        \\    say("hi")
        \\}
        \\
    ;
    try assertKlio("t01", src, "L: hi\n");
}

// T2 — `_` parameter + bridge via named forwarder.
test "t02_anonymous_param_bridge" {
    const src =
        \\class Scope { fun greet() = println("hello") }
        \\context(s: Scope) fun greet() = s.greet()
        \\context(_: Scope) fun run2() = greet()
        \\fun main() = context(Scope()) { run2() }
        \\
    ;
    try assertKlio("t02", src, "hello\n");
}

// T3 — contextual property (getter), receiver-as-context source.
test "t03_contextual_property_getter" {
    const src =
        \\class Users { fun byId(i: Int) = "User $i" }
        \\context(u: Users) val firstUser: String get() = u.byId(1)
        \\fun main() = with(Users()) { println(firstUser) }
        \\
    ;
    try assertKlio("t03", src, "User 1\n");
}

// T4 — contextual `var` with both accessors.
test "t04_contextual_var_both_accessors" {
    const src =
        \\class Store { var cell = "" }
        \\context(s: Store) var slot: String
        \\    get() = s.cell
        \\    set(value) { s.cell = value }
        \\fun main() = context(Store()) { slot = "x"; println(slot) }
        \\
    ;
    try assertKlio("t04", src, "x\n");
}

// T5 — nesting: inner context value shadows outer.
test "t05_nested_inner_shadows_outer" {
    const src =
        \\context(s: String) fun show() = println(s)
        \\context(_: String) fun main2() = context("inner") { show() }
        \\fun main() = context("outer") { main2() }
        \\
    ;
    try assertKlio("t05", src, "inner\n");
}

// T6 — ambiguity at one level.
test "t06_ambiguous_context_argument" {
    try assertDiag(
        \\context(s: String) fun show() = println(s)
        \\fun main() = context("a", "b") { show() }
        \\
    , "AMBIGUOUS_CONTEXT_ARGUMENT", "Multiple potential context arguments for 's' in scope.");
}

// T7 — missing context.
test "t07_no_context_argument" {
    try assertDiag(
        \\context(s: String) fun show() = println(s)
        \\fun main() { show() }
        \\
    , "NO_CONTEXT_ARGUMENT", "No context argument for 's' found.");
}

// T8 — two same-type params on one declaration: named use OK, resolved use ambiguous.
test "t08_two_same_type_params" {
    // Without the resolved use, one value fills both `a` and `b`: prints `xx`.
    try assertKlio("t08",
        \\context(a: String, b: String) fun f() { println(a + b) }
        \\fun main() = context("x") { f() }
        \\
    , "xx\n");
    // With a use that needs the type by resolution, it is ambiguous.
    try assertDiag(
        \\context(s: String) fun show() = println(s)
        \\context(a: String, b: String) fun f() { println(a + b); show() }
        \\fun main() = context("x") { f() }
        \\
    , "AMBIGUOUS_CONTEXT_ARGUMENT", "Multiple potential context arguments for 's' in scope.");
}

// T9 — extension receiver vs same-declaration context param are one level.
test "t09_receiver_and_context_same_level" {
    try assertDiag(
        \\class A
        \\context(ctx: T) fun <T> implicit(): T = ctx
        \\context(a: A) fun A.f() { implicit<A>() }
        \\fun main() = with(A()) { context(A()) { } }
        \\
    , "AMBIGUOUS_CONTEXT_ARGUMENT", "Multiple potential context arguments for 'ctx' in scope.");
}

// T10 — dispatch receiver satisfies a member's context (single source).
test "t10_dispatch_receiver_satisfies_member_context" {
    const src =
        \\class A {
        \\    context(a: A) fun m() = println("m")
        \\    fun go() = m()
        \\}
        \\fun main() = A().go()
        \\
    ;
    try assertKlio("t10", src, "m\n");
}

// T11 — receiver shadowed by context.
test "t11_receiver_shadowed_by_context" {
    try assertDiag(
        \\class Cow { fun moo() {}
        \\    fun test() = context(Cow()) { moo() } }
        \\fun main() { Cow().test() }
        \\
    , "RECEIVER_SHADOWED_BY_CONTEXT_PARAMETER", "moo");
}

// T12 — generic context parameter, explicit type argument.
test "t12_generic_context_parameter" {
    const src =
        \\context(ctx: T) fun <T> implicit(): T = ctx
        \\fun main() = context(21) { println(implicit<Int>() * 2) }
        \\
    ;
    try assertKlio("t12", src, "42\n");
}

// T13 — `contextOf` through a contextual-function-type lambda.
test "t13_contextof_through_contextual_function_type" {
    const src =
        \\interface Logger { fun log(m: String) }
        \\fun <A> withLog(block: context(Logger) () -> A): A =
        \\    context(object : Logger { override fun log(m: String) = println(m) }) { block() }
        \\fun main() { withLog { contextOf<Logger>().log("go") } }
        \\
    ;
    try assertKlio("t13", src, "go\n");
}

// T14 — invocation of a contextual function-type value both ways: the
// fully-positional call `f("s", 1, true)` splits its leading context args
// onto the context stack, and the implicit call `f(false)` resolves its
// contexts from the enclosing scope.
test "t14_invocation_contextual_function_type" {
    const src =
        \\fun call(f: context(String, Int) (Boolean) -> Unit) {
        \\    f("s", 1, true)
        \\    context("t") { with(2) { f(false) } }
        \\}
        \\fun main() = call { b -> println("$b ${contextOf<String>()} ${contextOf<Int>()}") }
        \\
    ;
    try assertKlio("t14", src, "true s 1\nfalse t 2\n");
}

// T15 — overloads differing only in context: shadow warning + call ambiguity.
test "t15_contextual_overload_shadowed_and_ambiguous" {
    const src =
        \\fun f() = println("plain")
        \\context(_: Any) fun f() = println("ctx")
        \\fun main() { f(); context("x" as Any) { f() } }
        \\
    ;
    try assertDiag(src, "CONTEXTUAL_OVERLOAD_SHADOWED", "context arguments are not used for overload resolution");
    try assertDiag(src, "OVERLOAD_RESOLUTION_AMBIGUITY", "f");
}

// T16 — smart cast on a context parameter.
test "t16_smart_cast_context_parameter" {
    const src =
        \\context(s: String) fun bar() = println(s.length)
        \\context(ctx: Any) fun foo() { if (ctx is String) bar() }
        \\fun main() = context("abcd" as Any) { foo() }
        \\
    ;
    try assertKlio("t16", src, "4\n");
}

// T17 — constructor context list rejected.
test "t17_constructor_context_rejected" {
    try assertDiag(
        \\class A
        \\class T context(c: A) constructor(x: Int)
        \\
    , "UNSUPPORTED", "Context parameters on constructors are unsupported.");
}

// T18 — contextual property with initializer rejected.
test "t18_contextual_property_initializer_rejected" {
    try assertDiag(
        \\class A
        \\context(c: A) val p: String = ""
        \\
    , "CONTEXT_PARAMETERS_WITH_BACKING_FIELD", "no backing field");
}

// T19 — multiple lists / default value / vararg / bare type rejected.
test "t19_structural_rejections" {
    try assertDiag(
        \\class A
        \\context(a: A) context(b: A) fun f1() {}
        \\
    , "MULTIPLE_CONTEXT_LISTS", "Multiple context parameter lists are forbidden");
    try assertDiag(
        \\class A
        \\context(a: A = A()) fun f2() {}
        \\
    , "CONTEXT_PARAMETER_WITH_DEFAULT", "Context parameters cannot have default values.");
    try assertDiag(
        \\context(vararg a: String) fun f3() {}
        \\
    , "WRONG_MODIFIER_TARGET", "'vararg' is not applicable");
    try assertDiag(
        \\context(String) fun f4() {}
        \\
    , "CONTEXT_PARAMETER_WITHOUT_NAME", "Context parameters must be named.");
}

// T20 — statement-level disambiguation (call vs local declaration).
test "t20_statement_level_disambiguation" {
    const src =
        \\fun main() {
        \\    context("v") { println(contextOf<String>()) }
        \\    context(c: Int) fun local() = println(c)
        \\    context(7) { local() }
        \\}
        \\
    ;
    try assertKlio("t20", src, "v\n7\n");
}

// T21 — override must match; name change allowed.
test "t21_override_must_match_context" {
    // A missing context list on the override overrides nothing.
    try assertDiag(
        \\class A
        \\open class Base { context(a: A) open fun foo() = println("base") }
        \\class D1 : Base() { override fun foo() = println("d1") }
        \\
    , "NOTHING_TO_OVERRIDE", "overrides nothing");
    // A matching context list (name change allowed) overrides and runs.
    try assertKlio("t21",
        \\class A
        \\open class Base { context(a: A) open fun foo() = println("base") }
        \\class D2 : Base() { context(x: A) override fun foo() = println("d2") }
        \\fun main() = with(A()) { D2().foo() }
        \\
    , "d2\n");
}

// T22 — excluded: explicit context argument.
test "t22_explicit_context_argument_rejected" {
    const src =
        \\class A
        \\context(a: A) fun needsA() = println("x")
        \\fun main() { needsA(a = A()) }
        \\
    ;
    try assertDiag(src, "UNSUPPORTED", "Explicit context arguments are not supported.");
    try assertDiag(src, "NO_CONTEXT_ARGUMENT", "No context argument for 'a' found.");
}

// T23 — excluded: callable reference to a contextual declaration.
test "t23_callable_reference_rejected" {
    try assertDiag(
        \\class A
        \\context(a: A) fun save(x: Int) {}
        \\fun main() = context(A()) { val r = ::save }
        \\
    , "CALLABLE_REFERENCE_TO_CONTEXTUAL_DECLARATION", "Callable reference to 'save' is unsupported because it has context parameters.");
}

// T24 — `NO_CONTEXT_ARGUMENT` reported per missing parameter.
test "t24_no_context_argument_per_parameter" {
    const src =
        \\context(a: String, b: Int) fun f() {}
        \\fun main() { f() }
        \\
    ;
    try std.testing.expectEqual(@as(usize, 2), try countDiag(src, "NO_CONTEXT_ARGUMENT"));
}
