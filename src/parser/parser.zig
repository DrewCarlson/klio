//! Kotlin parser.
//!
//! Hand-written recursive descent over a `Token` stream produced by the
//! `lexer` module. The expression grammar is a Pratt parser with
//! precedence levels:
//!
//!   disjunction      ||
//!   conjunction      &&
//!   equality         == != === !==
//!   comparison       < > <= >=
//!   named_checks     in !in is !is
//!   elvis            ?:
//!   range            .. ..<
//!   additive         + -
//!   multiplicative   * / %
//!   prefix           + - ! ++ --
//!   postfix          ++ -- . ?. !! () []
//!   primary
//!
//! Assignment is parsed at the statement level (Kotlin assignments are not
//! expressions). Newlines act as soft separators: inside parens/braces/
//! brackets they are skipped freely; at statement positions they terminate
//! a statement.
//!
//! The recursive-descent methods live in sibling files as free functions
//! over `*Parser` (e.g. `expr.parseExpr(p)`, `file.parseFile(p)`). This
//! root file owns the `Parser` struct, the modifier-flag helpers, the
//! top-level entry point, and the module-level tests.

const std = @import("std");

const ast = @import("ast");
const diagnostics = @import("diagnostics");
const lexer = @import("lexer");
const span = @import("span");

pub const support = @import("support.zig");
pub const file = @import("file.zig");
pub const class = @import("class.zig");
pub const types = @import("types.zig");
pub const members = @import("members.zig");
pub const stmt = @import("stmt.zig");
pub const expr = @import("expr.zig");
pub const primary = @import("primary.zig");
pub const control = @import("control.zig");

const DiagnosticSink = diagnostics.DiagnosticSink;
const Annotation = ast.Annotation;
const Expr = ast.Expr;
const KotlinFile = ast.KotlinFile;
const Visibility = ast.Visibility;
const FileId = span.FileId;
const Token = lexer.Token;
const TokenKind = lexer.TokenKind;

pub const Parser = struct {
    /// Arena used for every AST node and for owned diagnostic-message
    /// strings produced during the parse.
    allocator: std.mem.Allocator,
    file: FileId,
    src: []const u8,
    tokens: []const Token,
    pos: usize,
    diagnostics: DiagnosticSink,
    /// When `true`, postfix expression parsing will not attach a trailing
    /// `{ … }` lambda. Set while reading the delegate expression in a
    /// supertype-list entry of the form `: I by expr`, so the class body's
    /// opening brace isn't swallowed as `expr { … }`.
    suppress_trailing_lambda: bool,
    /// When `true`, `parseSimpleType` does NOT fold trailing `.Ident`
    /// segments into a qualified type path. Set while parsing an
    /// extension / anonymous-function *receiver* type, where the
    /// trailing `.name` is the function name (the receiver-fold loop
    /// separates the qualifier itself). Keeps qualified type refs
    /// working everywhere else.
    suppress_qualified_path: bool,
    /// When `true`, the cursor is inside a property accessor body, where
    /// `field` is the backing-field expression. Local-property parsing
    /// then never mistakes a `field = value` assignment statement for an
    /// explicit-backing-field clause.
    in_accessor_body: bool,
    /// Per-token flag: `true` when the token sits inside an unclosed
    /// `(` or `[` (not `{`). Kotlin treats newlines as soft inside
    /// round/square brackets — an expression may break before or after
    /// a binary/infix operator there — but significant inside `{ … }`
    /// blocks. Precomputed so it is O(1) regardless of how the cursor
    /// advances. Allocated from `allocator`.
    nl_soft: []bool,

    /// Build a parser over a freshly lexed token stream.
    ///
    /// A newline is *soft* (an expression may wrap across it) only when
    /// the innermost still-open bracket is `(` or `[`. Inside a `{ … }` —
    /// a block, lambda, or `when` body — newlines stay significant
    /// (statement / when-entry separators) even when that `{}` is itself
    /// nested inside `(…)`, e.g. `f(when { a -> x \n b -> y })`. Tracked
    /// with a bracket stack so the *innermost* context wins.
    pub fn new(
        allocator: std.mem.Allocator,
        file_id: FileId,
        src: []const u8,
        tokens: []const Token,
    ) *Parser {
        const nl_soft = allocator.alloc(bool, tokens.len) catch @panic("OOM in Parser.new");
        var stack: std.ArrayList(u8) = .empty;
        defer stack.deinit(allocator);
        const soft = struct {
            fn f(s: []const u8) bool {
                if (s.len == 0) return false;
                return s[s.len - 1] == '(' or s[s.len - 1] == '[';
            }
        }.f;
        for (tokens, 0..) |t, i| {
            switch (t.kind) {
                .RParen, .RBracket, .RBrace => {
                    if (stack.items.len > 0) _ = stack.pop();
                    nl_soft[i] = soft(stack.items);
                },
                .LParen => {
                    nl_soft[i] = soft(stack.items);
                    stack.append(allocator, '(') catch @panic("OOM in Parser.new");
                },
                .LBracket => {
                    nl_soft[i] = soft(stack.items);
                    stack.append(allocator, '[') catch @panic("OOM in Parser.new");
                },
                .LBrace => {
                    nl_soft[i] = soft(stack.items);
                    stack.append(allocator, '{') catch @panic("OOM in Parser.new");
                },
                else => nl_soft[i] = soft(stack.items),
            }
        }
        const p = allocator.create(Parser) catch @panic("OOM in Parser.new");
        p.* = .{
            .allocator = allocator,
            .file = file_id,
            .src = src,
            .tokens = tokens,
            .pos = 0,
            .diagnostics = DiagnosticSink.init(),
            .suppress_trailing_lambda = false,
            .suppress_qualified_path = false,
            .in_accessor_body = false,
            .nl_soft = nl_soft,
        };
        return p;
    }

    /// Parse the whole compilation unit. The diagnostics produced are left
    /// on `self.diagnostics`.
    pub fn parseFile(self: *Parser) KotlinFile {
        return file.parseFile(self);
    }
};

/// Modifier flags map one-to-one to Kotlin declaration modifiers and are
/// constructed/destructured field-by-field across several parse modules.
pub const ClassModifiers = struct {
    is_data: bool = false,
    is_companion: bool = false,
    is_enum: bool = false,
    is_sealed: bool = false,
    is_open: bool = false,
    is_abstract: bool = false,
    is_inner: bool = false,
    is_fun_interface: bool = false,
    is_value: bool = false,
    is_annotation: bool = false,
    is_expect: bool = false,
    is_actual: bool = false,
};

/// Modifier flags map one-to-one to Kotlin declaration modifiers and are
/// constructed/destructured field-by-field across several parse modules.
pub const ModifierFlags = struct {
    is_data: bool = false,
    is_companion: bool = false,
    is_enum: bool = false,
    is_sealed: bool = false,
    is_open: bool = false,
    is_override: bool = false,
    is_final: bool = false,
    is_abstract: bool = false,
    is_inner: bool = false,
    is_lateinit: bool = false,
    is_operator: bool = false,
    is_inline: bool = false,
    is_infix: bool = false,
    is_const: bool = false,
    is_tailrec: bool = false,
    is_value: bool = false,
    is_annotation: bool = false,
    is_suspend: bool = false,
    is_expect: bool = false,
    is_actual: bool = false,
    /// Span of the `suspend` modifier when one was consumed. Used to point
    /// the user at the modifier when emitting the rejection diagnostic on
    /// constructors / accessors / anonymous functions / delegation
    /// operators.
    suspend_span: ?span.Span = null,
    /// Span of the `inline` modifier when one was consumed. Used to emit a
    /// deprecation warning when the source wrote `inline class`, since
    /// `inline class` is an alias for `value class`.
    inline_span: ?span.Span = null,
    /// Parsed `context(name: Type, ...)` modifier clause. Attached to the
    /// following function/property declaration; rejected on classes,
    /// objects, type aliases, and constructors.
    context_params: []ast.ContextParam = &.{},
    /// Span of the `context(...)` clause when one was consumed. Used both
    /// for rejection diagnostics on invalid positions and to detect a
    /// second clause (`MULTIPLE_CONTEXT_LISTS`).
    context_span: ?span.Span = null,
    visibility: Visibility = Visibility.default,
    annotations: std.ArrayList(Annotation) = .empty,
};

/// Identifiers that are reserved soft modifiers / contextual keywords and
/// must never be tentatively consumed as infix function names. Without this
/// guard, declarations like `val x = foo\nprivate fun ...` could be misread
/// because the previous statement has no newline separator.
pub fn isValidInfixName(name: []const u8) bool {
    const reserved = [_][]const u8{
        "private",  "public",      "protected", "internal", "open",
        "abstract", "final",       "override",  "sealed",   "inner",
        "lateinit", "operator",    "infix",     "inline",   "tailrec",
        "external", "suspend",     "annotation","const",    "companion",
        "data",     "enum",        "by",        "where",    "get",
        "set",      "field",       "value",     "actual",   "expect",
        "vararg",   "crossinline", "noinline",  "reified",  "out",
    };
    for (reserved) |r| {
        if (std.mem.eql(u8, name, r)) return false;
    }
    return true;
}

pub fn isTrailingLambdaCallable(e: *const Expr) bool {
    return switch (e.*) {
        .Path, .Call, .Member => true,
        else => false,
    };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

/// True while the sibling parse modules are still stubs. Full-pipeline
/// tests (which drive the whole recursive-descent grammar) are skipped
/// until the fill agents complete the siblings; flip this to `false` once
/// they do and the tests below run for real.
const siblings_stubbed = false;

const ParseOut = struct {
    file: KotlinFile,
    parser: *Parser,
};

fn parse(arena: std.mem.Allocator, src: []const u8) !ParseOut {
    const id = span.FileId.from(0);
    var lx = try lexer.Lexer.init(arena, id, src);
    const lexed = try lx.tokenize();
    try testing.expect(!lexed.diagnostics.hasErrors());
    const p = Parser.new(arena, id, src, lexed.tokens);
    const kf = p.parseFile();
    return .{ .file = kf, .parser = p };
}

fn skipIfStubbed() !void {
    if (siblings_stubbed) return error.SkipZigTest;
}

test "foundation: nl_soft precomputes bracket softness" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "f(a\n{ b\nc })";
    const id = span.FileId.from(0);
    var lx = try lexer.Lexer.init(a, id, src);
    const lexed = try lx.tokenize();
    const p = Parser.new(a, id, src, lexed.tokens);

    // Find the two newline tokens and assert softness: the first newline
    // sits inside `(` (soft), the second sits inside `{` (hard).
    var seen: usize = 0;
    for (p.tokens, 0..) |t, i| {
        if (std.meta.activeTag(t.kind) == .Newline) {
            if (seen == 0) {
                try testing.expect(p.nl_soft[i]);
            } else if (seen == 1) {
                try testing.expect(!p.nl_soft[i]);
            }
            seen += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), seen);
}

test "foundation: is_valid_infix_name rejects soft modifiers" {
    try testing.expect(isValidInfixName("plus2"));
    try testing.expect(isValidInfixName("foo"));
    try testing.expect(!isValidInfixName("private"));
    try testing.expect(!isValidInfixName("operator"));
    try testing.expect(!isValidInfixName("out"));
}

test "foundation: is_trailing_lambda_callable" {
    const f = span.FileId.from(0);
    const sp = span.Span.init(f, 0, 1);
    var path = Expr{ .Path = .{ .segments = &.{}, .span = sp } };
    try testing.expect(isTrailingLambdaCallable(&path));
    var lit = Expr{ .IntLit = .{ .value = 1, .kind = .Int, .span = sp } };
    try testing.expect(!isTrailingLambdaCallable(&lit));
}

test "foundation: modifier flag defaults" {
    const cm = ClassModifiers{};
    try testing.expect(!cm.is_data);
    try testing.expect(!cm.is_value);
    const mf = ModifierFlags{};
    try testing.expectEqual(Visibility.Public, mf.visibility);
    try testing.expect(mf.suspend_span == null);
    try testing.expectEqual(@as(usize, 0), mf.annotations.items.len);
}

test "destructuring: bracket positional and name-based forms parse everywhere" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        \\data class P(val x: Int, val y: Int)
        \\fun f(ps: List<P>) {
        \\    val [a, b] = P(1, 2)
        \\    var [c, _] = P(3, 4)
        \\    (val y, val x) = P(5, 6)
        \\    (val n = x, var m: Int = y) = P(7, 8)
        \\    for ([i, p] in ps.withIndex()) println(i)
        \\    for ((val x, val y) in ps) println(x + y)
        \\    ps.map { [q, r] -> q + r }
        \\    ps.map { (val total: Int = x) -> total }
        \\    ps.map { [val u, val v] -> u }
        \\}
    ;
    const out = try parse(arena.allocator(), src);
    try testing.expect(!out.parser.diagnostics.hasErrors());
}

test "destructuring: a renamed entry needs the name-based form" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "fun f() { val [a = b] = P() }");
    try testing.expect(out.parser.diagnostics.hasErrors());
}

test "a lambda value argument takes postfix operators" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "fun f() { test(b = { r += \"2\"; \"b\" }(), a = { \"a\" }().length) }");
    try testing.expect(!out.parser.diagnostics.hasErrors());
}

test "parses_hello_world" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "fun main() { println(1 + 1) }");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    try testing.expectEqual(@as(usize, 1), out.file.decls.len);
    try testing.expect(out.file.decls[0] == .Function);
    try testing.expectEqualStrings("main", out.file.decls[0].Function.name.name);
}

test "package_and_imports" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(
        arena.allocator(),
        "package a.b.c\nimport kotlin.math.PI\nimport kotlin.collections.*\n",
    );
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const pkg = out.file.package.?;
    try testing.expectEqual(@as(usize, 3), pkg.path.len);
    try testing.expectEqualStrings("a", pkg.path[0].name);
    try testing.expectEqualStrings("b", pkg.path[1].name);
    try testing.expectEqualStrings("c", pkg.path[2].name);
    try testing.expectEqual(@as(usize, 2), out.file.imports.len);
    try testing.expect(out.file.imports[1].wildcard);
    try testing.expect(out.file.imports[1].alias == null);
}

test "import_with_backticked_segment" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "import kotlin.collections.`Map`\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const imp = out.file.imports[0];
    try testing.expectEqual(@as(usize, 3), imp.path.len);
    try testing.expectEqualStrings("kotlin", imp.path[0].name);
    try testing.expectEqualStrings("collections", imp.path[1].name);
    try testing.expectEqualStrings("Map", imp.path[2].name);
}

test "import_with_backticked_alias" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "import kotlin.math.PI as `tau-ish`\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    try testing.expectEqualStrings("tau-ish", out.file.imports[0].alias.?.name);
}

fn hasCode(p: *const Parser, want: []const u8) bool {
    for (p.diagnostics.diags()) |d| {
        if (d.code()) |c| {
            if (std.mem.eql(u8, c, want)) return true;
        }
    }
    return false;
}

test "import_wildcard_with_alias_is_rejected" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "import kotlin.collections.* as col\n");
    try testing.expect(hasCode(out.parser, "P0044"));
}

test "class_literal_with_type_arguments_is_rejected" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "fun main() { val k = Box<Int>::class }\n");
    try testing.expect(hasCode(out.parser, "T0104"));
}

test "expression_body_function" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "fun sq(x: Int): Int = x * x\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const f = out.file.decls[0].Function;
    try testing.expect(f.body.? == .Expr);
}

test "pratt_precedence" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "fun f() { val x = 2 + 3 * 4 }");
    const f = out.file.decls[0].Function;
    const b = f.body.?.Block;
    const p = b.stmts[0].Decl.Property;
    const init = p.init.?;
    try testing.expectEqual(ast.BinOp.Add, init.Binary.op);
    try testing.expectEqual(ast.BinOp.Mul, init.Binary.rhs.Binary.op);
}

test "assignment_is_a_statement" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "fun f() { var x = 0; x = 5 }");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const f = out.file.decls[0].Function;
    const b = f.body.?.Block;
    try testing.expect(b.stmts[b.stmts.len - 1] == .Assign);
}

test "compound_assignment_recognized" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "fun f() { var x = 0; x += 5 }");
    const f = out.file.decls[0].Function;
    const b = f.body.?.Block;
    const last = b.stmts[b.stmts.len - 1];
    try testing.expectEqual(ast.AssignOp.Add, last.Assign.op);
}

test "string_template_parts" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "fun f() { val s = \"x=$x and ${x + 1}\" }");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const f = out.file.decls[0].Function;
    const b = f.body.?.Block;
    const p = b.stmts[0].Decl.Property;
    const parts = p.init.?.StringTemplate.parts;
    try testing.expectEqual(@as(usize, 4), parts.len);
    try testing.expect(parts[0] == .Text);
    try testing.expect(parts[1] == .ShortInterp);
    try testing.expect(parts[2] == .Text);
    try testing.expect(parts[3] == .Interp);
}

test "if_else_chain" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(
        arena.allocator(),
        "\n            fun f(x: Int): Int {\n                return if (x < 0) -1 else if (x == 0) 0 else 1\n            }\n        ",
    );
    try testing.expect(!out.parser.diagnostics.hasErrors());
}

test "while_with_break_and_continue" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(
        arena.allocator(),
        "\n            fun f() {\n                var i = 0\n                while (i < 10) {\n                    if (i == 3) { i = i + 1; continue }\n                    if (i == 7) break\n                    i = i + 1\n                }\n            }\n        ",
    );
    try testing.expect(!out.parser.diagnostics.hasErrors());
}

test "for_loop_parses" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "fun f() { for (k in 1..3) { println(k) } }");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const f = out.file.decls[0].Function;
    const b = f.body.?.Block;
    try testing.expect(b.stmts[0] == .Expr);
    try testing.expect(b.stmts[0].Expr == .For);
}

test "member_chain_and_safe_call" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "fun f() { val x = a.b?.c }");
    const f = out.file.decls[0].Function;
    const b = f.body.?.Block;
    const p = b.stmts[0].Decl.Property;
    try testing.expect(p.init.?.Member.safe);
}

test "diagnostic_on_missing_close_paren" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "fun main() { println(1 + 2 \n}\n");
    try testing.expect(out.parser.diagnostics.hasErrors());
}

fn propertyType(kf: KotlinFile) *const ast.TypeRef {
    return &kf.decls[0].Property.ty.?;
}

test "function_type_simple" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "val f: (Int) -> Int = { it * 2 }\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const ty = propertyType(out.file);
    const ftr = ty.function.?;
    try testing.expect(ftr.receiver == null);
    try testing.expect(!ftr.is_suspend);
    try testing.expect(!ty.nullable);
    try testing.expectEqual(@as(usize, 1), ftr.params.len);
    try testing.expectEqualStrings("Int", ftr.params[0].name.name);
    try testing.expectEqualStrings("Int", ftr.ret.name.name);
}

test "function_type_empty_params" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "val f: () -> Unit = { }\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const ty = propertyType(out.file);
    const ftr = ty.function.?;
    try testing.expectEqual(@as(usize, 0), ftr.params.len);
    try testing.expectEqualStrings("Unit", ftr.ret.name.name);
}

test "function_type_multi_param" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(
        arena.allocator(),
        "fun apply(f: (Int, String) -> Boolean): Boolean = f(1, \"x\")\n",
    );
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const f = out.file.decls[0].Function;
    const ftr = f.params[0].ty.function.?;
    try testing.expectEqual(@as(usize, 2), ftr.params.len);
    try testing.expectEqualStrings("Int", ftr.params[0].name.name);
    try testing.expectEqualStrings("String", ftr.params[1].name.name);
    try testing.expectEqualStrings("Boolean", ftr.ret.name.name);
}

test "function_type_nullable_whole" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "val g: ((Int) -> Int)? = null\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const ty = propertyType(out.file);
    try testing.expect(ty.nullable);
    const ftr = ty.function.?;
    try testing.expectEqual(@as(usize, 1), ftr.params.len);
    try testing.expectEqualStrings("Int", ftr.ret.name.name);
}

test "function_type_right_associative" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(
        arena.allocator(),
        "val h: (Int) -> (Int) -> Int = { x -> { y -> x + y } }\n",
    );
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const ty = propertyType(out.file);
    const outer = ty.function.?;
    try testing.expectEqual(@as(usize, 1), outer.params.len);
    const inner = outer.ret.function.?;
    try testing.expectEqual(@as(usize, 1), inner.params.len);
    try testing.expectEqualStrings("Int", inner.ret.name.name);
}

test "function_type_with_receiver" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "val r: String.(Int) -> Int = { 0 }\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const ty = propertyType(out.file);
    const ftr = ty.function.?;
    try testing.expectEqualStrings("String", ftr.receiver.?.name.name);
    try testing.expectEqual(@as(usize, 1), ftr.params.len);
    try testing.expectEqualStrings("Int", ftr.params[0].name.name);
}

test "suspend_modifier_on_fun_sets_flag" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "suspend fun f() {}\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    try testing.expect(out.file.decls[0].Function.is_suspend);
}

test "suspend_modifier_on_non_suspend_fun_absent" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "fun f() {}\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    try testing.expect(!out.file.decls[0].Function.is_suspend);
}

test "suspend_modifier_on_secondary_ctor_rejected" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "class C { suspend constructor() {} }\n");
    try testing.expect(hasCode(out.parser, "T0114"));
}

test "suspend_modifier_on_property_accepted_inert" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "suspend val x = 1\n");
    try testing.expect(!hasCode(out.parser, "T0114"));
    try testing.expect(out.file.decls[0] == .Property);
}

test "function_type_suspend_accepted" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "val s: suspend (Int) -> Int = { it }\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const ty = propertyType(out.file);
    const ftr = ty.function.?;
    try testing.expect(ftr.is_suspend);
    try testing.expectEqual(@as(usize, 1), ftr.params.len);
}

test "function_type_named_params_allowed" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "val f: (x: Int, y: Int) -> Int = { a, b -> a + b }\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const ty = propertyType(out.file);
    const ftr = ty.function.?;
    try testing.expectEqual(@as(usize, 2), ftr.params.len);
    try testing.expectEqualStrings("Int", ftr.params[0].name.name);
}

test "function_type_malformed_empty_arrow" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "val f: () = 1\n");
    try testing.expect(out.parser.diagnostics.hasErrors());
}

test "function_type_parenthesized_single_type_still_parses" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "val x: (Int) = 1\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const ty = propertyType(out.file);
    try testing.expect(ty.function == null);
    try testing.expectEqualStrings("Int", ty.name.name);
}

test "recovers_from_top_level_garbage" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "@@@@\nfun main() { println(1) }\n");
    try testing.expect(out.parser.diagnostics.hasErrors());
    var found = false;
    for (out.file.decls) |d| {
        if (d == .Function and std.mem.eql(u8, d.Function.name.name, "main")) found = true;
    }
    try testing.expect(found);
}

test "visibility_modifiers_round_trip" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(
        arena.allocator(),
        "private fun a() {}\ninternal class B\nprotected val c: Int = 1\npublic fun d() {}\n",
    );
    try testing.expect(!out.parser.diagnostics.hasErrors());
    try testing.expectEqual(Visibility.Private, out.file.decls[0].Function.visibility);
    try testing.expectEqual(Visibility.Internal, out.file.decls[1].Class.visibility);
    try testing.expectEqual(Visibility.Protected, out.file.decls[2].Property.visibility);
    try testing.expectEqual(Visibility.Public, out.file.decls[3].Function.visibility);
}

test "visibility_defaults_to_public" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "fun a() {}\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    try testing.expectEqual(Visibility.Public, out.file.decls[0].Function.visibility);
}

test "declaration_site_annotations_captured" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "@Suppress(\"x\") @JvmStatic fun main() {}\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const f = out.file.decls[0].Function;
    try testing.expectEqual(@as(usize, 2), f.annotations.len);
    try testing.expectEqualStrings("Suppress", f.annotations[0].path[0].name);
    try testing.expectEqual(@as(usize, 1), f.annotations[0].args.len);
    try testing.expectEqualStrings("JvmStatic", f.annotations[1].path[0].name);
}

test "annotation_use_site_target" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "class C(@field:Foo val x: Int)\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const cp = out.file.decls[0].Class.primary_params[0];
    try testing.expectEqual(@as(usize, 1), cp.annotations.len);
    try testing.expectEqual(ast.AnnotationUseSite.Field, cp.annotations[0].use_site.?);
    try testing.expectEqualStrings("Foo", cp.annotations[0].path[0].name);
}

test "annotation_array_form" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "@field:[A B] val x: Int = 1\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const p = out.file.decls[0].Property;
    try testing.expectEqual(@as(usize, 2), p.annotations.len);
    for (p.annotations) |a| {
        try testing.expectEqual(ast.AnnotationUseSite.Field, a.use_site.?);
    }
    try testing.expectEqualStrings("A", p.annotations[0].path[0].name);
    try testing.expectEqualStrings("B", p.annotations[1].path[0].name);
}

test "annotation_all_use_site_target" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "class C(@all:Foo val x: Int)\n@all:Bar(\"v\") val top: Int = 1\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const cp = out.file.decls[0].Class.primary_params[0];
    try testing.expectEqual(@as(usize, 1), cp.annotations.len);
    try testing.expectEqual(ast.AnnotationUseSite.All, cp.annotations[0].use_site.?);
    try testing.expectEqualStrings("Foo", cp.annotations[0].path[0].name);
    const tp = out.file.decls[1].Property;
    try testing.expectEqual(ast.AnnotationUseSite.All, tp.annotations[0].use_site.?);
    try testing.expectEqual(@as(usize, 1), tp.annotations[0].args.len);
}

test "annotation_all_multi_bracket_rejected" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "class C(@all:[A B] val x: Int)\n");
    try testing.expect(out.parser.diagnostics.hasErrors());
    var found = false;
    for (out.parser.diagnostics.diags()) |d| {
        const f = d.factory orelse continue;
        if (std.mem.eql(u8, f.name, "INAPPLICABLE_ALL_TARGET_IN_MULTI_ANNOTATION")) {
            try testing.expectEqualStrings(
                "Multiple annotation syntax with '@all:' use-site target is forbidden, use '@all:A1 @all:A2 ...' instead.",
                d.message,
            );
            found = true;
        }
    }
    try testing.expect(found);
    // Recovery: both bracketed annotations still parse onto the param.
    const cp = out.file.decls[0].Class.primary_params[0];
    try testing.expectEqual(@as(usize, 2), cp.annotations.len);
}

test "when_subject_binding_parsed" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(
        arena.allocator(),
        "fun f(x: Any): Int = when (val v = x) { is Int -> v; else -> 0 }\n",
    );
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const e = out.file.decls[0].Function.body.?.Expr;
    try testing.expect(e.When.subject != null);
    const bnd = e.When.subject_binding.?;
    try testing.expectEqualStrings("v", bnd.name.name);
    try testing.expect(bnd.ty == null);
}

test "when_without_binding_still_parses" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "fun f(x: Int): Int = when (x) { 1 -> 1; else -> 0 }\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const e = out.file.decls[0].Function.body.?.Expr;
    try testing.expect(e.When.subject != null);
    try testing.expect(e.When.subject_binding == null);
}

test "as_basic" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "fun f(x: Any): String = x as String\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const e = out.file.decls[0].Function.body.?.Expr;
    try testing.expect(!e.As.safe);
    try testing.expectEqualStrings("String", e.As.ty.name.name);
}

test "as_safe" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "fun f(x: Any): String? = x as? String\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const e = out.file.decls[0].Function.body.?.Expr;
    try testing.expect(e.As.safe);
    try testing.expectEqualStrings("String", e.As.ty.name.name);
}

test "as_chains_left_associative" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "fun f(x: Any): Any = x as A as B\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const e = out.file.decls[0].Function.body.?.Expr;
    try testing.expectEqualStrings("B", e.As.ty.name.name);
    try testing.expectEqualStrings("A", e.As.expr.As.ty.name.name);
}

test "anon_fun_expr_body" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "fun main() { val f = fun(x: Int): Int = x + 1 }\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const b = out.file.decls[0].Function.body.?.Block;
    const p = b.stmts[0].Decl.Property;
    const af = p.init.?.AnonFun;
    try testing.expectEqual(@as(usize, 1), af.params.len);
    try testing.expectEqualStrings("Int", af.return_ty.?.name.name);
    try testing.expect(af.body.?.* == .Expr);
}

test "anon_fun_block_body" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "fun main() { val f = fun(x: Int): Int { return x * 2 } }\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const b = out.file.decls[0].Function.body.?.Block;
    const p = b.stmts[0].Decl.Property;
    try testing.expect(p.init.?.AnonFun.body.?.* == .Block);
}

test "anon_fun_optional_param_types" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "fun main() { val f = fun(x: Int, y: Int) = x + y }\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const b = out.file.decls[0].Function.body.?.Block;
    const p = b.stmts[0].Decl.Property;
    try testing.expectEqual(@as(usize, 2), p.init.?.AnonFun.params.len);
}

test "anon_fun_with_receiver" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "fun main() { val f = fun Int.(): Int = this + 1 }\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const b = out.file.decls[0].Function.body.?.Block;
    const p = b.stmts[0].Decl.Property;
    const af = p.init.?.AnonFun;
    try testing.expect(af.receiver_ty != null);
    try testing.expectEqualStrings("Int", af.receiver_ty.?.name.name);
}

test "definitely_non_nullable_type_parsed" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "fun <T> id(x: T & Any): T & Any = x\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const f = out.file.decls[0].Function;
    try testing.expect(f.params[0].ty.definitely_non_null);
    try testing.expect(f.return_type.?.definitely_non_null);
}

fn bodyStmts(f: ast.Function) []const ast.Stmt {
    return f.body.?.Block.stmts;
}

test "infix_call_user_defined" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(
        arena.allocator(),
        "infix fun Int.plus2(o: Int): Int = this + o\nfun main() { val r = 1 plus2 2 }\n",
    );
    try testing.expect(!out.parser.diagnostics.hasErrors());
    try testing.expect(out.file.decls[0].Function.is_infix);
    const stmts = bodyStmts(out.file.decls[1].Function);
    const p = stmts[0].Decl.Property;
    const call = p.init.?.Call;
    try testing.expect(call.is_infix);
    try testing.expectEqual(@as(usize, 2), call.args.len);
    try testing.expectEqualStrings("plus2", call.callee.Path.segments[0].name);
}

test "infix_call_no_newline_break" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "fun main() { val a = 1\nfoo(2) }\n");
    const stmts = bodyStmts(out.file.decls[0].Function);
    try testing.expectEqual(@as(usize, 2), stmts.len);
    try testing.expect(stmts[0] == .Decl);
    try testing.expect(!stmts[1].Expr.Call.is_infix);
}

test "infix_call_chain_left_assoc" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(
        arena.allocator(),
        "infix fun Int.f(o: Int): Int = this\nfun main() { val r = 1 f 2 f 3 }\n",
    );
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const stmts = bodyStmts(out.file.decls[1].Function);
    const p = stmts[0].Decl.Property;
    try testing.expect(p.init.?.Call.args[0] == .Call);
}

test "a trailing lambda invokes a parenthesized call result" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "fun main() { (factory()) { 1 } }\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const stmts = bodyStmts(out.file.decls[0].Function);
    const outer = stmts[0].Expr.Call;
    try testing.expect(outer.has_trailing_lambda);
    try testing.expectEqual(@as(usize, 1), outer.args.len);
    try testing.expect(outer.callee.* == .Call);
    try testing.expect(outer.callee.Call.grouped);
    try testing.expectEqual(@as(usize, 0), outer.callee.Call.args.len);
}

test "return_with_label" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "fun main() { foo@ run { return@foo 1 } }\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const stmts = bodyStmts(out.file.decls[0].Function);
    try testing.expectEqualStrings("foo", stmts[0].Expr.Labeled.label.name);
}

test "break_with_label" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "fun main() { outer@ for (i in 1..3) { break@outer } }\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const stmts = bodyStmts(out.file.decls[0].Function);
    try testing.expectEqualStrings("outer", stmts[0].Expr.Labeled.label.name);
}

test "continue_with_label" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "fun main() { outer@ for (i in 1..3) { continue@outer } }\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
}

test "labeled_loop" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "fun main() { L@ while (true) { break@L } }\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const stmts = bodyStmts(out.file.decls[0].Function);
    try testing.expectEqualStrings("L", stmts[0].Expr.Labeled.label.name);
    try testing.expect(stmts[0].Expr.Labeled.expr.* == .While);
}

test "labeled_lambda_via_run" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "fun main() { foo@ run { return@foo } }\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const stmts = bodyStmts(out.file.decls[0].Function);
    try testing.expectEqualStrings("foo", stmts[0].Expr.Labeled.label.name);
    try testing.expect(stmts[0].Expr.Labeled.expr.* == .Call);
}

test "generic_call_with_labeled_trailing_lambda" {
    // `f<Unit> sc@{ … }` is a generic call whose trailing lambda carries a
    // label, not the comparison `f < Unit > sc`. Without the labeled-lambda
    // case in `trySkipGenericCallArgs` the `<`/`>` parse as operators and
    // `suspendCancellableCoroutine<Unit> sc@{ … }` mis-lowers.
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "fun main() { val r = f<Unit> sc@{ it } }\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const stmts = bodyStmts(out.file.decls[0].Function);
    // `val r = <Call>` — the initializer is a Call, not a comparison Binary.
    const init = stmts[0].Decl.Property.init.?;
    try testing.expect(init == .Call);
    try testing.expect(init.Call.type_args.len == 1);
}

test "const_val_flag_captured" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "const val PI: Double = 3.14\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const p = out.file.decls[0].Property;
    try testing.expect(p.is_const);
    try testing.expect(!p.mutable);
}

test "value_class_flag_captured" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "value class Boxed(val n: Int)\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const c = out.file.decls[0].Class;
    try testing.expect(c.is_value);
    try testing.expect(!c.is_annotation);
}

test "inline_class_promotes_to_value_with_warning" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "inline class Boxed(val n: Int)\n");
    try testing.expect(out.file.decls[0].Class.is_value);
    try testing.expect(hasCode(out.parser, "W0001"));
}

test "annotation_class_flag_captured" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "annotation class Marker(val name: String)\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const c = out.file.decls[0].Class;
    try testing.expect(c.is_annotation);
    try testing.expectEqual(@as(usize, 1), c.primary_params.len);
    try testing.expectEqualStrings("name", c.primary_params[0].name.name);
}

test "tailrec_flag_captured" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "tailrec fun loop(n: Int): Int = if (n == 0) 0 else loop(n - 1)\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    try testing.expect(out.file.decls[0].Function.is_tailrec);
}

test "typealias_top_level" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "typealias IntList = List<Int>\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const a = out.file.decls[0].TypeAlias;
    try testing.expectEqualStrings("IntList", a.name.name);
    try testing.expectEqualStrings("List", a.target.name.name);
    try testing.expectEqual(@as(usize, 1), a.target.type_args.len);
    try testing.expectEqualStrings("Int", a.target.type_args[0].ty.name.name);
    try testing.expectEqual(@as(usize, 0), a.type_params.len);
}

test "typealias_with_type_params" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "typealias Pair2<A> = Pair<A, A>\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const a = out.file.decls[0].TypeAlias;
    try testing.expectEqualStrings("Pair2", a.name.name);
    try testing.expectEqual(@as(usize, 1), a.type_params.len);
    try testing.expectEqualStrings("A", a.type_params[0].name.name);
    try testing.expectEqualStrings("Pair", a.target.name.name);
    try testing.expectEqual(@as(usize, 2), a.target.type_args.len);
}

test "typealias_function_type" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "typealias Pred<T> = (T) -> Boolean\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const a = out.file.decls[0].TypeAlias;
    try testing.expectEqualStrings("Pred", a.name.name);
    try testing.expect(a.target.function != null);
    const func = a.target.function.?;
    try testing.expectEqual(@as(usize, 1), func.params.len);
    try testing.expectEqualStrings("T", func.params[0].name.name);
    try testing.expectEqualStrings("Boolean", func.ret.name.name);
}

test "extension_property_val_parses" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "val Int.cubed: Int get() = this * this * this\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const p = out.file.decls[0].Property;
    try testing.expectEqualStrings("cubed", p.name.name);
    try testing.expect(!p.mutable);
    try testing.expectEqualStrings("Int", p.receiver_type.?.name.name);
    try testing.expect(p.getter != null);
    try testing.expect(p.setter == null);
    try testing.expect(p.init == null);
}

test "extension_property_var_parses" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "var Holder.doubled: Int\n    get() = 0\n    set(value) { }\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const p = out.file.decls[0].Property;
    try testing.expect(p.mutable);
    try testing.expectEqualStrings("Holder", p.receiver_type.?.name.name);
    try testing.expect(p.getter != null);
    try testing.expect(p.setter != null);
}

test "extension_property_on_user_class" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "class Box(val n: Int)\nval Box.doubled: Int get() = n * 2\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const p = out.file.decls[1].Property;
    try testing.expectEqualStrings("Box", p.receiver_type.?.name.name);
    try testing.expect(p.getter != null);
}

test "typealias_in_class_body_parses" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "class Outer { typealias Inner = Int }\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const c = out.file.decls[0].Class;
    try testing.expectEqual(@as(usize, 1), c.members.len);
    try testing.expect(c.members[0] == .TypeAlias);
}

test "delegation_supertype_parsed" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "interface I { fun f(): Int }\nclass C(d: I) : I by d\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const c = out.file.decls[1].Class;
    try testing.expectEqual(@as(usize, 1), c.supertypes.len);
    try testing.expectEqual(@as(usize, 1), c.supertype_delegates.len);
    try testing.expect(c.supertype_args[0] == null);
    try testing.expect(c.supertype_delegates[0].? == .Path);
}

test "delegation_with_class_body_not_consumed_as_lambda" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(
        arena.allocator(),
        "interface I { fun f(): Int }\nclass C(d: I) : I by d { fun extra() = 1 }\n",
    );
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const c = out.file.decls[1].Class;
    try testing.expectEqual(@as(usize, 1), c.members.len);
    try testing.expect(c.members[0] == .Function);
    try testing.expectEqualStrings("extra", c.members[0].Function.name.name);
}

test "data_object_parsed" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "data object Foo { val n: Int = 0 }\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const o = out.file.decls[0].Object;
    try testing.expect(o.is_data);
    try testing.expectEqualStrings("Foo", o.name.name);
}

test "plain_object_not_data" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "object Bar { val n: Int = 0 }\n");
    try testing.expect(!out.parser.diagnostics.hasErrors());
}

test "spread_arg_parsed" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(
        arena.allocator(),
        "fun show(vararg ns: Int) {}\nfun main() { val a = intArrayOf(1); show(*a) }\n",
    );
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const b = out.file.decls[1].Function.body.?.Block;
    const call = b.stmts[1].Expr.Call;
    try testing.expect(call.args[0] == .Spread);
}

test "integer_form_float_literal_parses" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(
        arena.allocator(),
        "val a = 2f\nval b = 16777218F\nval c = (0f..3f)\n",
    );
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const a = out.file.decls[0].Property.init.?.FloatLit;
    try testing.expectEqual(ast.FloatLitKind.Float, a.kind);
    try testing.expectEqual(@as(f64, 2.0), a.value);
}

test "empty_while_body_via_semicolon" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(
        arena.allocator(),
        "fun f() { while (true); }\n",
    );
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const b = out.file.decls[0].Function.body.?.Block;
    const w = b.stmts[0].Expr.While;
    try testing.expectEqual(@as(usize, 0), w.body.Block.stmts.len);
}

test "annotated_trailing_lambda_parses" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(
        arena.allocator(),
        "val a = run @Suppress(\"x\") { 1 }\n",
    );
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const call = out.file.decls[0].Property.init.?.Call;
    try testing.expect(call.args.len == 1);
    try testing.expect(call.args[0] == .Lambda);
}

test "annotated_lambda_literal_keeps_its_annotations" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(
        arena.allocator(),
        "val content = @Composable { x() }\n",
    );
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const lam = out.file.decls[0].Property.init.?.Lambda;
    try testing.expectEqual(@as(usize, 1), lam.annotations.len);
    try testing.expectEqualStrings("Composable", lam.annotations[0].path[lam.annotations[0].path.len - 1].name);
}

test "consecutive_local_class_declarations" {
    try skipIfStubbed();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(
        arena.allocator(),
        "fun f() {\n    class A\n    class B\n    val x = 1\n}\n",
    );
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const b = out.file.decls[0].Function.body.?.Block;
    try testing.expectEqual(@as(usize, 3), b.stmts.len);
    try testing.expectEqualStrings("A", b.stmts[0].Decl.Class.name.name);
    try testing.expectEqualStrings("B", b.stmts[1].Decl.Class.name.name);
}

test {
    testing.refAllDecls(@This());
    _ = support;
    _ = file;
    _ = class;
    _ = types;
    _ = members;
    _ = stmt;
    _ = expr;
    _ = primary;
    _ = control;
}

// -------------------------------------------------------------------------
// Explicit backing fields
// -------------------------------------------------------------------------

test "ebf: member property field clause with initializer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(),
        \\class Cart {
        \\    val items: List<String>
        \\        field = mutableListOf<String>()
        \\}
    );
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const p = out.file.decls[0].Class.members[0].Property;
    const ef = p.explicit_field.?;
    try testing.expect(ef.ty == null);
    try testing.expect(ef.init != null);
    try testing.expect(p.init == null);
}

test "ebf: field clause with type and initializer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(),
        \\class C {
        \\    val n: Number
        \\        field: Int = 1
        \\}
    );
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const p = out.file.decls[0].Class.members[0].Property;
    const ef = p.explicit_field.?;
    try testing.expectEqualStrings("Int", ef.ty.?.name.name);
    try testing.expect(ef.init != null);
}

test "ebf: deferred field clause (type only)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(),
        \\class C {
        \\    val ns: List<Int>
        \\        field: MutableList<Int>
        \\    init { ns = mutableListOf(1) }
        \\}
    );
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const p = out.file.decls[0].Class.members[0].Property;
    const ef = p.explicit_field.?;
    try testing.expectEqualStrings("MutableList", ef.ty.?.name.name);
    try testing.expect(ef.init == null);
}

test "ebf: bare field clause" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(),
        \\class C {
        \\    val n: Int
        \\        field
        \\    init { n = 1 }
        \\}
    );
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const p = out.file.decls[0].Class.members[0].Property;
    const ef = p.explicit_field.?;
    try testing.expect(ef.ty == null);
    try testing.expect(ef.init == null);
}

test "ebf: top-level property field clause" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(),
        \\val top: List<Int>
        \\    field = mutableListOf(1)
        \\fun main() { println(top) }
    );
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const p = out.file.decls[0].Property;
    try testing.expect(p.explicit_field != null);
    try testing.expect(out.file.decls[1] == .Function);
}

test "ebf: initializer plus field clause both recorded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(),
        \\class C {
        \\    val n: Int = 5
        \\        field = 6
        \\}
    );
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const p = out.file.decls[0].Class.members[0].Property;
    try testing.expect(p.init != null);
    try testing.expect(p.explicit_field != null);
}

test "ebf: field clause followed by delegate both recorded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(),
        \\class C {
        \\    val n: Number
        \\        field: Int = 1
        \\        by lazy { 2 }
        \\}
    );
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const p = out.file.decls[0].Class.members[0].Property;
    try testing.expect(p.explicit_field != null);
    try testing.expect(p.delegate != null);
}

test "ebf: getter after field clause still parses" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(),
        \\class C {
        \\    val n: Number
        \\        field: Int = 1
        \\        get() = 5
        \\}
    );
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const p = out.file.decls[0].Class.members[0].Property;
    try testing.expect(p.explicit_field != null);
    try testing.expect(p.getter != null);
}

test "ebf: constructor property field clause is a syntax error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(
        arena.allocator(),
        "class C(val xs: List<Int> field: MutableList<Int> = mutableListOf())",
    );
    try testing.expect(out.parser.diagnostics.hasErrors());
    var found = false;
    for (out.parser.diagnostics.diags()) |d| {
        if (std.mem.indexOf(u8, d.message, "constructor properties") != null) found = true;
    }
    try testing.expect(found);
}

test "ebf: local property field clause is a syntax error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(),
        \\fun f() {
        \\    val xs: List<Int>
        \\        field = mutableListOf<Int>()
        \\}
    );
    try testing.expect(out.parser.diagnostics.hasErrors());
    var found = false;
    for (out.parser.diagnostics.diags()) |d| {
        if (std.mem.indexOf(u8, d.message, "local properties") != null) found = true;
    }
    try testing.expect(found);
}

test "ebf: modifier ahead of field clause rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(),
        \\class C {
        \\    val n: Number
        \\        internal field = 1
        \\}
    );
    try testing.expect(out.parser.diagnostics.hasErrors());
    var found = false;
    for (out.parser.diagnostics.diags()) |d| {
        if (d.factory) |f| {
            if (std.mem.eql(u8, f.name, "WRONG_MODIFIER_TARGET")) found = true;
        }
    }
    try testing.expect(found);
    // The clause itself still lands on the property.
    const p = out.file.decls[0].Class.members[0].Property;
    try testing.expect(p.explicit_field != null);
}

test "ebf: backing-field assignment in accessor body is not a clause" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(),
        \\class K {
        \\    var w: Int = 1
        \\        set(v) {
        \\            val old: Int
        \\            field = v
        \\            old = field
        \\        }
        \\}
    );
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const p = out.file.decls[0].Class.members[0].Property;
    try testing.expect(p.explicit_field == null);
    try testing.expect(p.setter != null);
}

// -------- context parameters --------

test "ctx: named context clause on a top-level function" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(),
        \\context(logger: Logger) fun say(m: String) = logger.log(m)
    );
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const f = out.file.decls[0].Function;
    try testing.expectEqual(@as(usize, 1), f.context_params.len);
    try testing.expectEqualStrings("logger", f.context_params[0].name.name);
    try testing.expectEqualStrings("Logger", f.context_params[0].ty.name.name);
}

test "ctx: anonymous and multi-param context clause" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(),
        \\context(a: String, _: Any) fun f() {}
    );
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const f = out.file.decls[0].Function;
    try testing.expectEqual(@as(usize, 2), f.context_params.len);
    try testing.expectEqualStrings("a", f.context_params[0].name.name);
    try testing.expectEqualStrings("_", f.context_params[1].name.name);
}

test "ctx: context clause on a property with accessor" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(),
        \\context(u: Users) val firstUser: String get() = u.byId(1)
    );
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const p = out.file.decls[0].Property;
    try testing.expectEqual(@as(usize, 1), p.context_params.len);
    try testing.expectEqualStrings("u", p.context_params[0].name.name);
}

test "accessor annotations are parsed onto the accessor" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(),
        \\val current: Int
        \\    @ReadOnlyComposable
        \\    @Composable
        \\    get() = 1
    );
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const p = out.file.decls[0].Property;
    const g = p.getter.?;
    try testing.expectEqual(@as(usize, 2), g.annotations.len);
    const a0 = g.annotations[0].path;
    try testing.expectEqualStrings("ReadOnlyComposable", a0[a0.len - 1].name);
    const a1 = g.annotations[1].path;
    try testing.expectEqualStrings("Composable", a1[a1.len - 1].name);
}

test "ctx: bare-type entry rejected as CONTEXT_PARAMETER_WITHOUT_NAME" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(),
        \\context(String) fun f() {}
    );
    var found = false;
    for (out.parser.diagnostics.diags()) |d| {
        if (d.factory) |fac| {
            if (std.mem.eql(u8, fac.name, "CONTEXT_PARAMETER_WITHOUT_NAME")) found = true;
        }
    }
    try testing.expect(found);
}

test "ctx: default value rejected as CONTEXT_PARAMETER_WITH_DEFAULT" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(),
        \\context(a: A = A()) fun f() {}
    );
    var found = false;
    for (out.parser.diagnostics.diags()) |d| {
        if (d.factory) |fac| {
            if (std.mem.eql(u8, fac.name, "CONTEXT_PARAMETER_WITH_DEFAULT")) found = true;
        }
    }
    try testing.expect(found);
}

test "ctx: vararg modifier rejected as WRONG_MODIFIER_TARGET" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(),
        \\context(vararg a: String) fun f() {}
    );
    var found = false;
    for (out.parser.diagnostics.diags()) |d| {
        if (d.factory) |fac| {
            if (std.mem.eql(u8, fac.name, "WRONG_MODIFIER_TARGET")) found = true;
        }
    }
    try testing.expect(found);
}

test "ctx: two context lists rejected as MULTIPLE_CONTEXT_LISTS" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(),
        \\context(a: A) context(b: A) fun f() {}
    );
    var found = false;
    for (out.parser.diagnostics.diags()) |d| {
        if (d.factory) |fac| {
            if (std.mem.eql(u8, fac.name, "MULTIPLE_CONTEXT_LISTS")) found = true;
        }
    }
    try testing.expect(found);
}

test "ctx: statement-level call is not a context clause" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(),
        \\fun main() {
        \\    context("v") { println(contextOf<String>()) }
        \\}
    );
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const body = out.file.decls[0].Function.body.?.Block;
    // The single statement is an expression (the call), not a declaration.
    try testing.expect(body.stmts.len == 1);
    try testing.expect(body.stmts[0] != .Decl);
}

test "ctx: statement-level local contextual function" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(),
        \\fun main() {
        \\    context(c: Int) fun local() = println(c)
        \\    context(7) { local() }
        \\}
    );
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const body = out.file.decls[0].Function.body.?.Block;
    try testing.expect(body.stmts[0] == .Decl);
    const local = body.stmts[0].Decl.Function;
    try testing.expectEqual(@as(usize, 1), local.context_params.len);
    try testing.expectEqualStrings("c", local.context_params[0].name.name);
    // The second statement is the stdlib `context(...)` call.
    try testing.expect(body.stmts[1] != .Decl);
}

test "ctx: contextual function type parses context block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(),
        \\fun call(f: context(String, Int) (Boolean) -> Unit) {}
    );
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const f = out.file.decls[0].Function;
    const pty = f.params[0].ty;
    try testing.expect(pty.function != null);
    try testing.expectEqual(@as(usize, 2), pty.function.?.context_params.len);
    try testing.expectEqual(@as(usize, 1), pty.function.?.params.len);
}

test "ctx: named entry in function-type context block rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(),
        \\fun call(f: context(s: String) () -> Unit) {}
    );
    var found = false;
    for (out.parser.diagnostics.diags()) |d| {
        if (d.factory) |fac| {
            if (std.mem.eql(u8, fac.name, "NAMED_CONTEXT_PARAMETER_IN_FUNCTION_TYPE")) found = true;
        }
    }
    try testing.expect(found);
}

test "extension receiver with qualified type inside generic args" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(),
        \\internal fun Set<Map.Entry<String, List<String>>>.formUrlEncodeTo(out: Appendable) {}
    );
    try testing.expect(!out.parser.diagnostics.hasErrors());
    try testing.expectEqual(@as(usize, 1), out.file.decls.len);
    const f = out.file.decls[0].Function;
    try testing.expectEqualStrings("formUrlEncodeTo", f.name.name);
    const recv = f.receiver_type.?;
    try testing.expectEqualStrings("Set", recv.name.name);
    try testing.expectEqual(@as(usize, 1), recv.type_args.len);
    try testing.expectEqualStrings("Entry", recv.type_args[0].ty.name.name);
}

test "annotation on a receiver function type annotates the function type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(),
        \\fun mount(content: @Composable Int.(String) -> Unit) {}
    );
    try testing.expect(!out.parser.diagnostics.hasErrors());
    const f = out.file.decls[0].Function;
    const ty = f.params[0].ty;
    try testing.expect(ty.function != null);
    // The annotation written before the receiver head belongs to the
    // FUNCTION type, not the receiver.
    try testing.expectEqual(@as(usize, 1), ty.annotations.len);
    try testing.expectEqualStrings("Composable", ty.annotations[0].path[ty.annotations[0].path.len - 1].name);
    const recv = ty.function.?.receiver.?;
    try testing.expectEqual(@as(usize, 0), recv.annotations.len);
    try testing.expectEqualStrings("Int", recv.name.name);
    try testing.expectEqual(@as(usize, 1), ty.function.?.params.len);
}
