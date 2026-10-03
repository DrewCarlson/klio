//! Shared cursor, peek, expect and recovery helpers, as free functions over
//! `*Parser`.

const std = @import("std");

const ast = @import("ast");
const diagnostics = @import("diagnostics");
const lexer = @import("lexer");
const span = @import("span");

const root = @import("parser.zig");
const expr = @import("expr.zig");

const Parser = root.Parser;

const Diagnostic = diagnostics.Diagnostic;
const Ident = ast.Ident;
const Keyword = lexer.Keyword;
const Token = lexer.Token;
const TokenKind = lexer.TokenKind;
const Span = span.Span;

/// Newlines are soft inside `(` or `[`, where an expression may continue across
/// a line break around a binary or infix operator.
pub fn nlIsSoft(p: *const Parser) bool {
    if (p.pos < p.nl_soft.len) return p.nl_soft[p.pos];
    return false;
}

pub fn skipSoftNl(p: *Parser) void {
    while (std.meta.activeTag(peekKind(p).*) == .Newline and nlIsSoft(p)) {
        p.pos += 1;
    }
}

pub fn peek(p: *const Parser) *const Token {
    return &p.tokens[p.pos];
}

pub fn peekKind(p: *const Parser) *const TokenKind {
    return &p.tokens[p.pos].kind;
}

pub fn bump(p: *Parser) Token {
    const t = p.tokens[p.pos];
    if (std.meta.activeTag(t.kind) != .Eof) {
        p.pos += 1;
    }
    return t;
}

pub fn skipNl(p: *Parser) void {
    while (std.meta.activeTag(peekKind(p).*) == .Newline) {
        p.pos += 1;
    }
}

/// Assignments are statements, not expressions. After an expression in value
/// context, reject a trailing assignment operator and consume the RHS to
/// recover.
pub fn rejectTrailingAssignment(p: *Parser) void {
    const is_assign = switch (peekKind(p).*) {
        .Eq, .PlusEq, .MinusEq, .StarEq, .SlashEq, .PercentEq => true,
        else => false,
    };
    if (!is_assign) return;
    const sp = currentSpan(p);
    err(
        p,
        "T0117",
        "assignments are not expressions, and only expressions are allowed in this context",
        sp,
    );
    _ = bump(p);
    skipNl(p);
    _ = expr.parseExpr(p);
}

/// True at a token that cannot begin an expression, so a preceding `return` /
/// `break` / `continue` carries no value. Besides a statement boundary this
/// covers `)`, `]` and `,`, so `f(x ?: return)` parses.
pub fn atNewlineOrSemiOrClose(p: *const Parser) bool {
    return switch (peekKind(p).*) {
        .Newline, .Semicolon, .Eof, .RBrace, .RParen, .RBracket, .Comma => true,
        else => false,
    };
}

pub fn text(p: *const Parser, sp: Span) []const u8 {
    return p.src[sp.start..sp.end];
}

/// Strips the backticks of an escaped identifier. The result borrows from the
/// source buffer when unescaped and from the arena when stripped; callers must
/// not free it.
pub fn identName(p: *Parser, sp: Span) []const u8 {
    const raw = text(p, sp);
    if (raw.len >= 2 and raw[0] == '`' and raw[raw.len - 1] == '`') {
        return raw[1 .. raw.len - 1];
    }
    return raw;
}

pub fn currentSpan(p: *const Parser) Span {
    return peek(p).span;
}

pub fn err(p: *Parser, code: []const u8, msg: []const u8, sp: Span) void {
    var d = Diagnostic.err(msg, sp);
    _ = d.withCode(code);
    p.diagnostics.emit(p.allocator, d) catch {};
}

/// Like `err`, but tags the diagnostic with a factory so consumers can match on the stable name.
pub fn errWithFactory(
    p: *Parser,
    factory: *const diagnostics.DiagnosticFactory,
    code: []const u8,
    msg: []const u8,
    sp: Span,
) void {
    var d = Diagnostic.err(msg, sp);
    _ = d.withCode(code);
    _ = d.withFactory(factory);
    p.diagnostics.emit(p.allocator, d) catch {};
}

/// A type reference's boxed extras, null when both are at their defaults.
pub fn typeRefExtra(p: *Parser, e: ast.TypeRefExtra) ?*const ast.TypeRefExtra {
    return ast.typeRefExtra(p.allocator, e) catch @panic("OOM in parser");
}

/// A call's boxed labels and type arguments. An all-positional label list
/// is the shared one, and with no type arguments so is the box.
pub fn callExtra(p: *Parser, arg_names: []const ?[]const u8, name_spans: []const Span, type_args: []ast.TypeRef) ?*const ast.CallExtra {
    const positional = for (arg_names) |n| {
        if (n != null) break false;
    } else true;
    var names = arg_names;
    if (positional) {
        if (type_args.len == 0) if (ast.positionalExtra(arg_names.len)) |shared| return shared;
        if (ast.positionalNames(arg_names.len)) |shared| names = shared;
    }
    return ast.callExtra(p.allocator, .{
        .arg_names = names,
        .arg_name_spans = if (positional) &.{} else name_spans,
        .type_args = type_args,
    }) catch @panic("OOM in parser");
}

/// The extras of a call of `n` positional arguments and no type arguments.
pub fn positionalCallExtra(p: *Parser, n: usize) ?*const ast.CallExtra {
    if (n == 0) return null;
    if (ast.positionalExtra(n)) |shared| return shared;
    const names = p.allocator.alloc(?[]const u8, n) catch @panic("OOM in parser");
    @memset(names, null);
    return callExtra(p, names, &.{}, &.{});
}

pub fn classExtra(p: *Parser, e: ast.ClassExtra) ?*const ast.ClassExtra {
    return ast.classExtra(p.allocator, e) catch @panic("OOM in parser");
}

/// `boxed` over an optional: null stays null.
pub fn boxedOpt(p: *Parser, value: anytype) ?*@TypeOf(value.?) {
    return if (value) |v| boxed(p, v) else null;
}

/// A boxed node for a pointer payload of the AST, on the parser's allocator.
pub fn boxed(p: *Parser, value: anytype) *@TypeOf(value) {
    const ptr = p.allocator.create(@TypeOf(value)) catch @panic("OOM in parser");
    ptr.* = value;
    return ptr;
}

pub fn expect(p: *Parser, kind: TokenKind, what: []const u8) ?Token {
    skipNl(p);
    if (std.meta.activeTag(peekKind(p).*) == std.meta.activeTag(kind)) {
        return bump(p);
    }
    const sp = currentSpan(p);
    const msg = std.fmt.allocPrint(p.allocator, "expected {s}", .{what}) catch "expected token";
    err(p, "E0001", msg, sp);
    return null;
}

pub fn parseIdent(p: *Parser, what: []const u8) ?Ident {
    skipNl(p);
    if (std.meta.activeTag(peekKind(p).*) == .Ident) {
        const tok = bump(p);
        return Ident{
            .name = identName(p, tok.span),
            .span = tok.span,
        };
    }
    const sp = currentSpan(p);
    const msg = std.fmt.allocPrint(p.allocator, "expected {s}", .{what}) catch "expected identifier";
    err(p, "E0003", msg, sp);
    return null;
}

pub fn recoverToTopLevel(p: *Parser) void {
    while (true) {
        switch (peekKind(p).*) {
            .Eof => return,
            .Keyword => |kw| switch (kw) {
                .Fun, .Val, .Var, .Class, .Object, .Interface, .Package, .Import => return,
                else => {},
            },
            else => {},
        }
        _ = bump(p);
    }
}

pub fn recoverToStmtEnd(p: *Parser) void {
    while (true) {
        switch (peekKind(p).*) {
            .Newline, .Semicolon, .RBrace, .Eof => return,
            else => {},
        }
        _ = bump(p);
    }
}

pub fn peekIdentText(p: *const Parser) ?[]const u8 {
    if (p.pos >= p.tokens.len) return null;
    const tok = p.tokens[p.pos];
    if (std.meta.activeTag(tok.kind) == .Ident) {
        return text(p, tok.span);
    }
    return null;
}

/// Whether the soft keyword at the cursor names a value parameter rather
/// than modifying it: a name is what `,`, `:`, `=` or `)` follows, so
/// `actual: Double?` and `vararg: Int` are parameters named `actual` and
/// `vararg`.
pub fn softKeywordIsParamName(p: *const Parser) bool {
    var i = p.pos + 1;
    while (i < p.tokens.len and std.meta.activeTag(p.tokens[i].kind) == .Newline) i += 1;
    if (i >= p.tokens.len) return true;
    return switch (p.tokens[i].kind) {
        .Comma, .Colon, .Eq, .RParen => true,
        else => false,
    };
}

pub fn peekKeywordIdent(p: *const Parser, name: []const u8) bool {
    return std.meta.activeTag(peekKind(p).*) == .Ident and
        std.mem.eql(u8, text(p, currentSpan(p)), name);
}

/// True when the next significant token, newlines skipped, is `kind`. Lets a
/// line STARTING with a continuation operator such as `?:` join the previous
/// expression.
pub fn newlineThen(p: *const Parser, kind: TokenKind) bool {
    if (std.meta.activeTag(peekKind(p).*) != .Newline) {
        return false;
    }
    var i = p.pos;
    while (i < p.tokens.len and std.meta.activeTag(p.tokens[i].kind) == .Newline) {
        i += 1;
    }
    if (i >= p.tokens.len) return false;
    return std.meta.activeTag(p.tokens[i].kind) == std.meta.activeTag(kind);
}

// Tests

const testing = std.testing;

fn lexAndMake(arena: std.mem.Allocator, src: []const u8) !*Parser {
    const id = span.FileId.from(0);
    var lx = try lexer.Lexer.init(arena, id, src);
    const res = try lx.tokenize();
    // The lex result's allocations leak into the arena, freed by the caller.
    return Parser.new(arena, id, src, res.tokens, res.strings);
}

test "peek and bump advance the cursor" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try lexAndMake(arena.allocator(), "fun x");

    try testing.expectEqual(@as(usize, 0), p.pos);
    const first = bump(p);
    try testing.expectEqual(Keyword.Fun, first.kind.Keyword);
    try testing.expectEqual(@as(usize, 1), p.pos);
}

test "bump does not advance past eof" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try lexAndMake(arena.allocator(), "");
    try testing.expectEqual(TokenKind.Eof, std.meta.activeTag(peekKind(p).*));
    _ = bump(p);
    _ = bump(p);
    try testing.expectEqual(TokenKind.Eof, std.meta.activeTag(peekKind(p).*));
}

test "ident name strips backticks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try lexAndMake(arena.allocator(), "`a b`");
    const sp = currentSpan(p);
    try testing.expectEqualStrings("a b", identName(p, sp));
}

test "parse ident reads name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try lexAndMake(arena.allocator(), "hello");
    const id = parseIdent(p, "name").?;
    try testing.expectEqualStrings("hello", id.name);
    try testing.expect(!p.diagnostics.hasErrors());
}

test "expect emits diagnostic on mismatch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try lexAndMake(arena.allocator(), "fun");
    const got = expect(p, .LParen, "`(`");
    try testing.expect(got == null);
    try testing.expect(p.diagnostics.hasErrors());
}

test "recover to top level stops at keyword" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try lexAndMake(arena.allocator(), "+ + + fun f");
    recoverToTopLevel(p);
    try testing.expectEqual(Keyword.Fun, peekKind(p).Keyword);
}

test "recover to stmt end stops at newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try lexAndMake(arena.allocator(), "a b c\nd");
    recoverToStmtEnd(p);
    try testing.expectEqual(TokenKind.Newline, std.meta.activeTag(peekKind(p).*));
}

test "peek ident text without consuming" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try lexAndMake(arena.allocator(), "foo");
    try testing.expectEqualStrings("foo", peekIdentText(p).?);
    try testing.expectEqual(@as(usize, 0), p.pos);
}

test "peek keyword ident matches soft keyword" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try lexAndMake(arena.allocator(), "data");
    try testing.expect(peekKeywordIdent(p, "data"));
    try testing.expect(!peekKeywordIdent(p, "enum"));
}
