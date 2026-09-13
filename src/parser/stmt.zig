//! Statement and block parsing: local declarations, assignments, destructuring
//! declarations, and statement-separator handling. Free functions over
//! `*Parser`.

const std = @import("std");

const ast = @import("ast");
const diagnostics = @import("diagnostics");
const lexer = @import("lexer");

const root = @import("parser.zig");
const support = @import("support.zig");
const expr = @import("expr.zig");
const file = @import("file.zig");
const class = @import("class.zig");
const members = @import("members.zig");
const types = @import("types.zig");
const control = @import("control.zig");

const Parser = root.Parser;
const ClassModifiers = root.ClassModifiers;

const AssignOp = ast.AssignOp;
const Block = ast.Block;
const Decl = ast.Decl;
const Ident = ast.Ident;
const Stmt = ast.Stmt;
const Keyword = lexer.Keyword;
const TokenKind = lexer.TokenKind;

pub fn parseBlock(p: *Parser) ?Block {
    const lbrace = support.expect(p, .LBrace, "`{`") orelse return null;
    var stmts: std.ArrayList(Stmt) = .empty;
    while (true) {
        skipStmtSeparators(p);
        switch (support.peekKind(p).*) {
            .RBrace, .Eof => break,
            else => {},
        }
        if (parseStmt(p)) |s| {
            stmts.append(p.allocator, s) catch @panic("OOM in parseBlock");
        } else {
            support.recoverToStmtEnd(p);
        }
        switch (support.peekKind(p).*) {
            .Newline, .Semicolon, .RBrace, .Eof => {},
            else => {
                const sp = support.currentSpan(p);
                support.err(p, "E0004", "expected newline or `;` between statements", sp);
                support.recoverToStmtEnd(p);
            },
        }
    }
    const rbrace = support.expect(p, .RBrace, "`}`") orelse return null;
    return Block{
        .stmts = stmts.toOwnedSlice(p.allocator) catch @panic("OOM in parseBlock"),
        .span = lbrace.span.join(rbrace.span),
    };
}

pub fn skipStmtSeparators(p: *Parser) void {
    while (switch (support.peekKind(p).*) {
        .Newline, .Semicolon => true,
        else => false,
    }) {
        p.pos += 1;
    }
}

pub fn parseStmt(p: *Parser) ?Stmt {
    const save = p.pos;
    // A label before a local DECLARATION is a runtime no-op, so the `ident@` is
    // consumed. Before an expression or loop it keeps its meaning and belongs
    // to the expression path, so strip it only when a declaration follows.
    if (std.meta.activeTag(support.peekKind(p).*) == .Ident and
        p.pos + 2 < p.tokens.len and
        (std.meta.activeTag(p.tokens[p.pos + 1].kind) == .AtNoWs or
            std.meta.activeTag(p.tokens[p.pos + 1].kind) == .AtPostWs) and
        std.meta.activeTag(p.tokens[p.pos + 2].kind) == .Keyword and
        switch (p.tokens[p.pos + 2].kind.Keyword) {
            .Val, .Var, .Fun => true,
            else => false,
        })
    {
        _ = support.bump(p); // label ident
        _ = support.bump(p); // `@`
        support.skipNl(p);
    }
    const before_mods = p.pos;
    const flags = file.skipModifiersWithFlagsLevel(p, true);
    switch (support.peekKind(p).*) {
        .LParen => {
            // `(val a, val b) = expr` carries no leading keyword; anything else
            // opening with `(` is an expression statement.
            const next: ?TokenKind = if (p.pos + 1 < p.tokens.len) p.tokens[p.pos + 1].kind else null;
            if (next != null and std.meta.activeTag(next.?) == .Keyword and (next.?.Keyword == .Val or next.?.Keyword == .Var)) {
                return parseNameBasedDestructuringStmt(p);
            }
            return parseFallthroughStmt(p, save);
        },
        .LBracket => {
            // A statement-leading `[` is only ever a positional destructuring,
            // Kotlin having no array-literal expression. But a soft-keyword
            // identifier (`data`, `value`) is eaten as a modifier above,
            // leaving its `[` index access here: when modifiers were consumed
            // this `[` is a postfix index, so parse an expression instead.
            if (p.pos != before_mods) return parseFallthroughStmt(p, save);
            return parseBracketDestructuringStmt(p);
        },
        .Keyword => |kw| switch (kw) {
            .Val, .Var => {
                // `val (a, b) = expr`; a single name falls through to plain property parsing.
                const next: ?TokenKind = if (p.pos + 1 < p.tokens.len) p.tokens[p.pos + 1].kind else null;
                if (next != null and (std.meta.activeTag(next.?) == .LParen or std.meta.activeTag(next.?) == .LBracket)) {
                    return parseDestructuringDecl(p);
                }
                const prop = members.parseLocalProperty(p, flags) orelse return null;
                const pp = p.allocator.create(ast.Property) catch @panic("OOM");
                pp.* = prop;
                return Stmt{ .Decl = Decl{ .Property = pp } };
            },
            .Fun => {
                const next: ?TokenKind = if (p.pos + 1 < p.tokens.len) p.tokens[p.pos + 1].kind else null;
                if (next != null and std.meta.activeTag(next.?) == .Keyword and next.?.Keyword == .Interface) {
                    _ = support.bump(p); // `fun`
                    const visibility = flags.visibility;
                    const annotations = flags.annotations.items;
                    const c = class.parseClass(
                        p,
                        ClassModifiers{
                            .is_data = false,
                            .is_companion = false,
                            .is_enum = false,
                            .is_sealed = flags.is_sealed,
                            .is_open = false,
                            .is_abstract = false,
                            .is_inner = false,
                            .is_fun_interface = true,
                            .is_value = false,
                            .is_annotation = false,
                            .is_expect = flags.is_expect,
                            .is_actual = flags.is_actual,
                        },
                        visibility,
                        annotations,
                    ) orelse return null;
                    return Stmt{ .Decl = Decl{ .Class = c } };
                }
                // No name after `fun`. A `fun <...> Ident(...)` is a local
                // generic declaration and falls through to `parseFun`.
                const after_generics: ?TokenKind = blk: {
                    if (next != null and std.meta.activeTag(next.?) == .Lt) {
                        // `(` means anonymous, `Ident` a local fn.
                        var depth: i32 = 1;
                        var i = p.pos + 2;
                        while (i < p.tokens.len) {
                            switch (p.tokens[i].kind) {
                                .Lt => depth += 1,
                                .Gt => {
                                    depth -= 1;
                                    if (depth == 0) {
                                        i += 1;
                                        break;
                                    }
                                },
                                .Eof => break,
                                else => {},
                            }
                            i += 1;
                        }
                        break :blk if (i < p.tokens.len) p.tokens[i].kind else null;
                    }
                    break :blk null;
                };
                const is_anon = (next != null and std.meta.activeTag(next.?) == .LParen) or
                    (after_generics != null and std.meta.activeTag(after_generics.?) == .LParen);
                if (is_anon) {
                    p.pos = save;
                    return parseExprOrAssignStmt(p);
                }
                const f = members.parseFun(p, flags) orelse return null;
                return Stmt{ .Decl = Decl{ .Function = f } };
            },
            .Class, .Interface => {
                const visibility = flags.visibility;
                const annotations = flags.annotations.items;
                const is_value = flags.is_value or flags.is_inline;
                if (flags.is_inline and !flags.is_value) {
                    if (flags.inline_span) |sp| {
                        var d = diagnostics.Diagnostic.warning(
                            "`inline class` is deprecated; use `value class` instead",
                            sp,
                        );
                        _ = d.withCode("W0001");
                        p.diagnostics.emit(p.allocator, d) catch {};
                    }
                }
                const c = class.parseClass(
                    p,
                    ClassModifiers{
                        .is_data = flags.is_data,
                        .is_companion = false,
                        .is_enum = flags.is_enum,
                        .is_sealed = flags.is_sealed,
                        .is_open = flags.is_open,
                        .is_abstract = flags.is_abstract,
                        .is_inner = flags.is_inner,
                        .is_fun_interface = false,
                        .is_value = is_value,
                        .is_annotation = flags.is_annotation,
                        .is_expect = flags.is_expect,
                        .is_actual = flags.is_actual,
                    },
                    visibility,
                    annotations,
                ) orelse return null;
                return Stmt{ .Decl = Decl{ .Class = c } };
            },
            .Object => {
                // `object Name { ... }` is a local singleton; `object { ... }`
                // and `object : Super { ... }` are EXPRESSIONS and fall through.
                const next: ?TokenKind = if (p.pos + 1 < p.tokens.len) p.tokens[p.pos + 1].kind else null;
                if (next != null and std.meta.activeTag(next.?) == .Ident) {
                    const o = class.parseObject(
                        p,
                        flags.is_data,
                        flags.is_expect,
                        flags.is_actual,
                        flags.visibility,
                        flags.annotations.items,
                    ) orelse return null;
                    return Stmt{ .Decl = Decl{ .Object = o } };
                } else {
                    p.pos = save;
                    return parseExprOrAssignStmt(p);
                }
            },
            .Typealias => {
                const a = file.parseTypealias(p, flags.visibility, flags.annotations.items) orelse return null;
                return Stmt{ .Decl = Decl{ .TypeAlias = a } };
            },
            else => return parseFallthroughStmt(p, save),
        },
        else => return parseFallthroughStmt(p, save),
    }
}

/// Rolls back so unrelated modifiers, such as annotations on expressions, are not swallowed.
fn parseFallthroughStmt(p: *Parser, save: usize) ?Stmt {
    p.pos = save;
    // A statement may carry leading annotations; they are runtime no-ops, so
    // discard them and let the expression parser see the statement.
    _ = file.parseAnnotations(p);
    support.skipNl(p);
    return parseExprOrAssignStmt(p);
}

pub fn parseDestructuringDecl(p: *Parser) ?Stmt {
    const kw = support.bump(p); // val/var
    var mutable = std.meta.activeTag(kw.kind) == .Keyword and kw.kind.Keyword == .Var;
    const bracket = std.meta.activeTag(support.peekKind(p).*) == .LBracket;
    if (!bracket) _ = support.expect(p, .LParen, "`(` or `[`") orelse return null else _ = support.bump(p);
    const entries = control.parseDestructEntries(
        p,
        if (bracket) .RBracket else .RParen,
        bracket,
        "destructured name",
    ) orelse return null;
    if (entries.any_var) mutable = true;
    _ = support.expect(p, .Eq, "`=`") orelse return null;
    support.skipNl(p);
    const init = expr.parseExpr(p) orelse return null;
    const sp = kw.span.join(init.span());
    return Stmt{ .DestructuringDecl = .{
        .mutable = mutable,
        .names = entries.names,
        .by_name = entries.by_name,
        .sources = entries.sources,
        .init = init,
        .span = sp,
    } };
}

/// Opens with `(` followed by `val`/`var`.
pub fn parseNameBasedDestructuringStmt(p: *Parser) ?Stmt {
    const open = support.bump(p); // `(`
    const entries = control.parseDestructEntries(p, .RParen, false, "destructured name") orelse return null;
    _ = support.expect(p, .Eq, "`=`") orelse return null;
    support.skipNl(p);
    const init = expr.parseExpr(p) orelse return null;
    const sp = open.span.join(init.span());
    return Stmt{ .DestructuringDecl = .{
        .mutable = entries.any_var,
        .names = entries.names,
        .by_name = entries.by_name,
        .sources = entries.sources,
        .init = init,
        .span = sp,
    } };
}

/// Opens with `[` and carries no leading keyword.
pub fn parseBracketDestructuringStmt(p: *Parser) ?Stmt {
    const open = support.bump(p); // `[`
    const entries = control.parseDestructEntries(p, .RBracket, true, "destructured name") orelse return null;
    _ = support.expect(p, .Eq, "`=`") orelse return null;
    support.skipNl(p);
    const init = expr.parseExpr(p) orelse return null;
    const sp = open.span.join(init.span());
    return Stmt{ .DestructuringDecl = .{
        .mutable = entries.any_var,
        .names = entries.names,
        .by_name = entries.by_name,
        .sources = entries.sources,
        .init = init,
        .span = sp,
    } };
}

pub fn parseExprOrAssignStmt(p: *Parser) ?Stmt {
    const lhs = expr.parseExpr(p) orelse return null;
    const op: ?AssignOp = switch (support.peekKind(p).*) {
        .Eq => AssignOp.Assign,
        .PlusEq => AssignOp.Add,
        .MinusEq => AssignOp.Sub,
        .StarEq => AssignOp.Mul,
        .SlashEq => AssignOp.Div,
        .PercentEq => AssignOp.Rem,
        else => null,
    };
    if (op) |o| {
        _ = support.bump(p);
        support.skipNl(p);
        const rhs = expr.parseExpr(p) orelse return null;
        const sp = lhs.span().join(rhs.span());
        return Stmt{ .Assign = .{
            .target = lhs,
            .op = o,
            .value = rhs,
            .span = sp,
        } };
    }
    return Stmt{ .Expr = lhs };
}
