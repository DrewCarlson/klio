//! Explicit backing fields (Kotlin 2.4): the full acceptance matrix.
//!
//! `val`-only member/top-level properties may declare `field[: Type][= init]`
//! in the initializer slot. Reads inside the declaring scope (class body or
//! declaring file for top-level) see the FIELD type; outside they see the
//! property type. Runtime rows run through the real parity pipeline and
//! assert stdout; diagnostic rows run lexer -> parser -> resolver -> typeck
//! and assert the compiler-named diagnostic and its message.

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

const TMP_DIR = "/tmp/klio_itest_explicit_backing_fields";

// The klio pipeline installs process-global lowering/VM state backed by the
// run's allocator; one file-scoped arena over the page allocator backs every
// run here (matching the other parity itests).
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

/// Every diagnostic (parser + typeck) the front-end emits for `src`.
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

/// Assert `src` produces a diagnostic whose message contains `msg_needle`
/// (for parser rows, which carry no compiler-named factory).
fn assertDiagMsg(src: []const u8, msg_needle: []const u8) !void {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const diags = try frontendDiags(a, src);
    for (diags) |d| {
        if (std.mem.indexOf(u8, d.message, msg_needle) != null) return;
    }
    std.debug.print("expected message containing `{s}`; got:\n", .{msg_needle});
    for (diags) |d| std.debug.print("  {s}\n", .{d.message});
    return error.MissingExpectedDiagnostic;
}

/// Assert `src` type-checks with no error diagnostics.
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

// C1: narrowing inside the declaring class — `items` is MutableList there.
test "c01_mutable_inside_read_only_outside" {
    const src =
        \\class Cart {
        \\    val items: List<String>
        \\        field = mutableListOf<String>()
        \\    fun add(s: String) { items.add(s) }
        \\}
        \\fun main() {
        \\    val c = Cart()
        \\    c.add("a")
        \\    println(c.items)
        \\}
        \\
    ;
    try assertNoErrors(src);
    try assertKlio("c01", src, "[a]\n");
}

// C2: no narrowing outside the class — `add` does not exist on List<String>.
test "c02_no_narrowing_outside_class" {
    try assertDiag(
        \\class Cart {
        \\    val items: List<String>
        \\        field = mutableListOf<String>()
        \\    fun add(s: String) { items.add(s) }
        \\}
        \\fun main() {
        \\    val c = Cart()
        \\    c.add("a")
        \\    c.items.add("b")
        \\    println(c.items)
        \\}
        \\
    , "UNRESOLVED_REFERENCE", "unresolved reference `add` on `List<String>`");
}

// C3: field-typed reads inside the class (`n` is Int in `inc`).
test "c03_field_type_inside_class" {
    const src =
        \\class C {
        \\    val n: Number
        \\        field: Int = 1
        \\    fun inc() = n + 1
        \\}
        \\fun main() {
        \\    println(C().inc())
        \\}
        \\
    ;
    try assertNoErrors(src);
    try assertKlio("c03", src, "2\n");
}

// C4: `var` cannot declare an explicit backing field.
test "c04_var_rejected" {
    try assertDiag(
        \\class C {
        \\    var n: Number
        \\        field: Int = 1
        \\}
        \\fun main() { println(C().n) }
        \\
    , "VAR_PROPERTY_WITH_EXPLICIT_BACKING_FIELD", "Only 'val' properties with explicit backing fields are supported.");
}

// C5: no accessor bodies alongside a field clause.
test "c05_accessor_rejected" {
    try assertDiag(
        \\class C {
        \\    val n: Number
        \\        field: Int = 1
        \\        get() = 5
        \\}
        \\fun main() { println(C().n) }
        \\
    , "PROPERTY_WITH_EXPLICIT_FIELD_AND_ACCESSORS", "Properties with explicit backing fields cannot have accessors.");
}

// C6: the field type must be a subtype of the property type.
test "c06_inconsistent_field_type" {
    try assertDiag(
        \\class C {
        \\    val n: Int
        \\        field: String = "x"
        \\}
        \\fun main() { println(C().n) }
        \\
    , "INCONSISTENT_BACKING_FIELD_TYPE", "The type of the backing field must be a subtype of the property's type.");
}

// C7: equal field/property types warn but the program still runs.
test "c07_redundant_field_warns_and_runs" {
    const src =
        \\class C {
        \\    val n: Int
        \\        field: Int = 1
        \\}
        \\fun main() { println(C().n) }
        \\
    ;
    try assertDiag(src, "REDUNDANT_EXPLICIT_BACKING_FIELD", "Explicit backing field declaration is unnecessary if it has the same type as the property.");
    try assertKlio("c07", src, "1\n");
}

// C8: the property must be effectively final.
test "c08_open_property_rejected" {
    try assertDiag(
        \\open class C {
        \\    open val n: Number
        \\        field: Int = 1
        \\}
        \\fun main() { println(C().n) }
        \\
    , "NON_FINAL_PROPERTY_WITH_EXPLICIT_BACKING_FIELD", "Properties with explicit backing fields must be final.");
}

// C9: no backing fields inside interfaces.
test "c09_interface_rejected" {
    try assertDiag(
        \\interface I {
        \\    val n: Number
        \\        field: Int = 1
        \\}
        \\fun main() { println("i") }
        \\
    , "EXPLICIT_BACKING_FIELD_IN_INTERFACE", "Backing fields inside interfaces are prohibited.");
}

// C10: a private property cannot be less visible than its (private) field.
test "c10_private_property_rejected" {
    try assertDiag(
        \\class C {
        \\    private val n: Number
        \\        field: Int = 1
        \\}
        \\fun main() { println("p") }
        \\
    , "EXPLICIT_FIELD_VISIBILITY_MUST_BE_LESS_PERMISSIVE", "Private properties cannot have explicit backing fields.");
}

// C11: no modifiers on the field clause.
test "c11_modifier_on_field_rejected" {
    try assertDiag(
        \\class C {
        \\    val n: Number
        \\        internal field = 1
        \\}
        \\fun main() { println(C().n) }
        \\
    , "WRONG_MODIFIER_TARGET", "Modifier 'internal' is not applicable to 'backing field'");
}

// C12: deferred field initialization in an init block.
test "c12_deferred_field_init" {
    const src =
        \\class C {
        \\    val ns: List<Int>
        \\        field: MutableList<Int>
        \\    init { ns = mutableListOf(1) }
        \\    fun peek() = ns[0]
        \\}
        \\fun main() { println(C().peek()) }
        \\
    ;
    try assertNoErrors(src);
    try assertKlio("c12", src, "1\n");
}

// C13: a field with no initializer must be definitely assigned.
test "c13_field_must_be_initialized" {
    try assertDiag(
        \\class C {
        \\    val ns: List<Int>
        \\        field: MutableList<Int>
        \\}
        \\fun main() { println("x") }
        \\
    , "EXPLICIT_FIELD_MUST_BE_INITIALIZED", "Field must be initialized.");
}

// C14: field clauses are a syntax error on constructor properties.
test "c14_constructor_property_syntax_error" {
    try assertDiagMsg(
        \\class C(val xs: List<Int> field: MutableList<Int> = mutableListOf())
        \\fun main() { println("x") }
        \\
    , "explicit backing fields are not allowed on constructor properties");
}

// C15: field clauses are a syntax error on local properties.
test "c15_local_property_syntax_error" {
    try assertDiagMsg(
        \\fun f() {
        \\    val xs: List<Int>
        \\        field = mutableListOf<Int>()
        \\}
        \\fun main() { f(); println("x") }
        \\
    , "explicit backing fields are not allowed on local properties");
}

// C16: no delegate alongside a field clause.
test "c16_delegate_rejected" {
    try assertDiag(
        \\class C {
        \\    val n: Number
        \\        field: Int = 1
        \\        by lazy { 2 }
        \\}
        \\fun main() { println("x") }
        \\
    , "BACKING_FIELD_FOR_DELEGATED_PROPERTY", "Delegated properties cannot have explicit backing field declarations.");
}

// C17: narrowing holds in inner classes of the declaring class.
test "c17_narrowing_in_inner_class" {
    const src =
        \\class C {
        \\    val n: Number
        \\        field = 1
        \\    inner class I {
        \\        fun g() = n + 1
        \\    }
        \\}
        \\fun main() { println(C().I().g()) }
        \\
    ;
    try assertNoErrors(src);
    try assertKlio("c17", src, "2\n");
}

// C18: top-level narrowing is file-scoped.
test "c18_top_level_narrowing" {
    const src =
        \\val top: List<Int>
        \\    field = mutableListOf(1)
        \\fun main() {
        \\    top.add(2)
        \\    println(top)
        \\}
        \\
    ;
    try assertNoErrors(src);
    try assertKlio("c18", src, "[1, 2]\n");
}
