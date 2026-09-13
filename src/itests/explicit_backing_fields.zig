//! Explicit backing fields (Kotlin 2.4): a `val` member or top-level property
//! may declare `field[: Type][= init]` in the initializer slot. Reads inside
//! the declaring class body, or the declaring file for a top-level property,
//! see the field type; reads outside it see the property type.

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

// One file-scoped arena: the pipeline's process-global state points into it.
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

/// Message-only form, for parser rows that carry no factory name.
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

test "c14_constructor_property_syntax_error" {
    try assertDiagMsg(
        \\class C(val xs: List<Int> field: MutableList<Int> = mutableListOf())
        \\fun main() { println("x") }
        \\
    , "explicit backing fields are not allowed on constructor properties");
}

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
