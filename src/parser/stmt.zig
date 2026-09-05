//! Statement and block parsing: local declarations, assignments,
//! destructuring declarations, and statement-separator handling.
//!
//! Free functions over `*Parser`.

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
        // After a statement, a newline or `;` is the separator.
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

// Single match-dispatch over statement-leading tokens; splitting would fragment it.
pub fn parseStmt(p: *Parser) ?Stmt {
    const save = p.pos;
    const flags = file.skipModifiersWithFlagsLevel(p, true);
    switch (support.peekKind(p).*) {
        .LParen => {
            // `(val a, val b) = expr` — the name-based destructuring form,
            // which carries no leading keyword. Anything else that opens
            // with `(` is an expression statement.
            const next: ?TokenKind = if (p.pos + 1 < p.tokens.len) p.tokens[p.pos + 1].kind else null;
            if (next != null and std.meta.activeTag(next.?) == .Keyword and (next.?.Keyword == .Val or next.?.Keyword == .Var)) {
                return parseNameBasedDestructuringStmt(p);
            }
            return parseFallthroughStmt(p, save);
        },
        .Keyword => |kw| switch (kw) {
            .Val, .Var => {
                // `val (a, b) = expr` — destructuring declaration. Falls through
                // to plain property parsing on a single name.
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
                // Anonymous-function expression statement: `fun(...) ...`
                // or `fun <T>(...) ...`. No name follows the `fun` keyword.
                // For `fun <...> Ident(...)`, this is a local generic
                // function declaration — fall through to `parseFun`.
                const after_generics: ?TokenKind = blk: {
                    if (next != null and std.meta.activeTag(next.?) == .Lt) {
                        // Skip a balanced generic param list to peek at what
                        // follows: `(` → anonymous; `Ident` → local fn.
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
                // `object Name { … }` — local singleton. `object { … }` /
                // `object : Super { … }` is an anonymous-object *expression*
                // and falls through to expression parsing.
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
                    // Roll back modifiers so the expression parser sees
                    // `object` at the head.
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

/// No declaration matched — roll back so unrelated modifiers
/// (annotations on expressions, etc.) don't get swallowed.
fn parseFallthroughStmt(p: *Parser, save: usize) ?Stmt {
    p.pos = save;
    // A statement may carry leading annotations (`@Suppress(...)`
    // before a `return`/expression statement). They are runtime
    // no-ops here; consume and discard so the expression parser
    // sees the statement itself.
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

/// The name-based full form at statement level, `(val a, var n = prop) = x`,
/// which opens with `(` followed by `val`/`var`.
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

pub fn parseExprOrAssignStmt(p: *Parser) ?Stmt {
    const lhs = expr.parseExpr(p) orelse return null;
    // Assignment forms (statement-level only).
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
