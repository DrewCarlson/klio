//! Shared cursor / peek / expect / recovery helpers for the parser.
//!
//! In Rust these were inherent `impl` methods on `Parser` living in
//! `parse/support.rs`. Here they are free functions over `*Parser`,
//! matching the calling convention used across the parser's sibling
//! files (e.g. `support.peekKind(p)`).

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

/// Are newlines soft at the cursor (inside `(`/`[`)? When true,
/// the expression grammar may continue across a line break
/// before or after a binary/infix operator.
pub fn nlIsSoft(p: *const Parser) bool {
    if (p.pos < p.nl_soft.len) return p.nl_soft[p.pos];
    return false;
}

/// Skip newline tokens, but only where they are soft (inside
/// round/square brackets). A no-op elsewhere, so block-level
/// statement separation is unaffected.
pub fn skipSoftNl(p: *Parser) void {
    while (std.meta.activeTag(peekKind(p).*) == .Newline and nlIsSoft(p)) {
        p.pos += 1;
    }
}

// ---------- cursor helpers ----------

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

/// Skip soft newlines — newlines that don't terminate a statement.
pub fn skipNl(p: *Parser) void {
    while (std.meta.activeTag(peekKind(p).*) == .Newline) {
        p.pos += 1;
    }
}

/// Assignments are statements, not expressions. After parsing an
/// expression in a value-context (paren, `if`/`while`/`do-while`/`when`
/// condition, `for` range, value-argument), reject a trailing assignment
/// operator with a clear diagnostic and consume the RHS to recover.
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

pub fn atNewlineOrSemiOrClose(p: *const Parser) bool {
    return switch (peekKind(p).*) {
        .Newline, .Semicolon, .Eof, .RBrace => true,
        else => false,
    };
}

pub fn text(p: *const Parser, sp: Span) []const u8 {
    return p.src[sp.start..sp.end];
}

/// Read the identifier name stored in the token's span, stripping the
/// surrounding backticks when the source uses an escaped identifier
/// (`` `foo bar` ``). For unescaped identifiers this is a plain slice.
///
/// The result borrows from the parser's source buffer for the unescaped
/// case and from the arena for the stripped case; callers must not free it.
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

/// Like `err`, but also tags the diagnostic with a compiler-named factory
/// so downstream consumers can match on the stable diagnostic name.
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

// ---------- top-level ----------

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

// ---------- recovery ----------

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

// ---------- blocks / statements ----------

/// Returns the text of the next token if it is an `Ident`, without
/// consuming.
pub fn peekIdentText(p: *const Parser) ?[]const u8 {
    if (p.pos >= p.tokens.len) return null;
    const tok = p.tokens[p.pos];
    if (std.meta.activeTag(tok.kind) == .Ident) {
        return text(p, tok.span);
    }
    return null;
}

// ---------- types ----------

pub fn peekKeywordIdent(p: *const Parser, name: []const u8) bool {
    return std.meta.activeTag(peekKind(p).*) == .Ident and
        std.mem.eql(u8, text(p, currentSpan(p)), name);
}

/// True when, skipping any newlines from the cursor, the next
/// significant token is `kind`. Used so a line that *starts* with
/// a binary continuation operator (e.g. `?:`) joins the previous
/// expression rather than ending it.
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

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

fn lexAndMake(arena: std.mem.Allocator, src: []const u8) !*Parser {
    const id = span.FileId.from(0);
    var lx = try lexer.Lexer.init(arena, id, src);
    const res = try lx.tokenize();
    // Leak the lex result's allocations into the arena; freed by the caller.
    return Parser.new(arena, id, src, res.tokens);
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
