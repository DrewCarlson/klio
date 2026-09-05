//! Control-flow expression parsing: `if`/`else`, `when`, `for`,
//! `while`/`do-while`, `try`/`catch`/`finally`, `throw`, `return`,
//! `break`, `continue`, labels, and lambda literals.
//!
//! Free functions over `*Parser`.

const std = @import("std");

const ast = @import("ast");
const span = @import("span");
const lexerKeyword = @import("lexer").Keyword;

const root = @import("parser.zig");
const support = @import("support.zig");

const Parser = root.Parser;

const AssignOp = ast.AssignOp;
const Block = ast.Block;
const Catch = ast.Catch;
const Expr = ast.Expr;
const TokenKind = @import("lexer").TokenKind;
const Ident = ast.Ident;
const Stmt = ast.Stmt;
const WhenBinding = ast.WhenBinding;
const WhenBranch = ast.WhenBranch;
const WhenPattern = ast.WhenPattern;
const WhenPatternKind = ast.WhenPatternKind;
const TypeRef = ast.TypeRef;
const Annotation = ast.Annotation;
const Span = span.Span;

// Cross-module parse entry points live in sibling files. Until each sibling
// exposes its public function the calls below resolve to local no-op
// fallbacks, keeping the module compiling; once the sibling lands the real
// implementation is used automatically.

fn parseExpr(p: *Parser) ?Expr {
    if (@hasDecl(root.expr, "parseExpr")) return root.expr.parseExpr(p);
    return null;
}

fn parsePrefix(p: *Parser) ?Expr {
    if (@hasDecl(root.expr, "parsePrefix")) return root.expr.parsePrefix(p);
    return null;
}

fn skipLeadingExprAnnotation(p: *Parser) void {
    if (@hasDecl(root.expr, "skipLeadingExprAnnotation")) root.expr.skipLeadingExprAnnotation(p);
}

fn parseBlock(p: *Parser) ?Block {
    if (@hasDecl(root.stmt, "parseBlock")) return root.stmt.parseBlock(p);
    return null;
}

fn parseStmt(p: *Parser) ?Stmt {
    if (@hasDecl(root.stmt, "parseStmt")) return root.stmt.parseStmt(p);
    return null;
}

fn skipStmtSeparators(p: *Parser) void {
    if (@hasDecl(root.stmt, "skipStmtSeparators")) root.stmt.skipStmtSeparators(p);
}

fn parseType(p: *Parser) ?TypeRef {
    if (@hasDecl(root.types, "parseType")) return root.types.parseType(p);
    return null;
}

fn parseQualifiedType(p: *Parser) ?TypeRef {
    if (@hasDecl(root.types, "parseQualifiedType")) return root.types.parseQualifiedType(p);
    return null;
}

fn parseAnnotations(p: *Parser) []Annotation {
    if (@hasDecl(root.file, "parseAnnotations")) return root.file.parseAnnotations(p);
    return &.{};
}

// Heap helpers --------------------------------------------------------------

/// Allocate a single `Expr` on the parser arena.
fn box(p: *Parser, e: Expr) *Expr {
    const ptr = p.allocator.create(Expr) catch @panic("OOM in parser");
    ptr.* = e;
    return ptr;
}

/// Build a one-element `[]Stmt` on the arena.
fn singleStmt(p: *Parser, s: Stmt) []Stmt {
    const buf = p.allocator.alloc(Stmt, 1) catch @panic("OOM in parser");
    buf[0] = s;
    return buf;
}

/// Build a one-element `[]Ident` on the arena.
fn singleIdent(p: *Parser, id: Ident) []Ident {
    const buf = p.allocator.alloc(Ident, 1) catch @panic("OOM in parser");
    buf[0] = id;
    return buf;
}

/// Parses a `controlStructureBody` per the spec: a statement (which
/// may be an assignment) wrapped as a single-statement block, or an
/// expression. Used for `if` / `else` / `while` / `for` / `do-while`
/// bodies so a non-block body can be an assignment like
/// `if (c) x = v`.
pub fn parseControlStructureBody(p: *Parser) ?Expr {
    // Kotlin grammar: `controlStructureBody : block | statement`.
    // An annotation may prefix the body expression
    // (`NaturalOrderComparator -> @Suppress("UNCHECKED_CAST") (x as T)`
    // in `Comparator.reversed()`); strip it (runtime no-op) first.
    skipLeadingExprAnnotation(p);
    // A leading `{` here is the body *block*, not a lambda — the
    // lambda reading only applies in true expression position
    // (`val f = { … }`), which `parsePrimary` handles.
    if (std.meta.activeTag(support.peekKind(p).*) == .LBrace) {
        // A `{ params -> body }` shape at branch position is a
        // lambda literal (the branch evaluates to a function
        // value); a `{` without a top-level `->` is the body
        // block.
        const next = p.pos + 1;
        const save_pos = p.pos;
        p.pos = next;
        const has_header = lambdaHasHeader(p);
        p.pos = save_pos;
        if (has_header) {
            return parseLambdaLiteral(p);
        }
        const blk = parseBlock(p) orelse return null;
        return Expr{ .Block = blk };
    }
    const save = p.pos;
    const expr = parseExpr(p) orelse return null;
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
        const rhs = parseExpr(p) orelse return null;
        const sp = expr.span().join(rhs.span());
        const st = Stmt{ .Assign = .{
            .target = expr,
            .op = o,
            .value = rhs,
            .span = sp,
        } };
        return Expr{ .Block = .{
            .stmts = singleStmt(p, st),
            .span = sp,
        } };
    }
    _ = save;
    return expr;
}

pub fn parseIf(p: *Parser) ?Expr {
    const kw = support.bump(p);
    _ = support.expect(p, .LParen, "`(`") orelse return null;
    support.skipNl(p);
    const cond = parseExpr(p) orelse return null;
    support.skipNl(p);
    support.rejectTrailingAssignment(p);
    support.skipNl(p);
    _ = support.expect(p, .RParen, "`)`") orelse return null;
    support.skipNl(p);
    // The then-branch may be omitted (`;` or `else` immediately following
    // the closing paren). The branchless form `if (c) else ;` is valid and
    // evaluates to Unit.
    const cond_span = cond.span();
    const then_branch: Expr = switch (support.peekKind(p).*) {
        .Semicolon => blk: {
            const semi = support.bump(p);
            break :blk Expr{ .Block = .{
                .stmts = &.{},
                .span = semi.span,
            } };
        },
        .Keyword => |kw_kind| if (kw_kind == .Else) Expr{ .Block = .{
            .stmts = &.{},
            .span = cond_span,
        } } else (parseControlStructureBody(p) orelse return null),
        else => parseControlStructureBody(p) orelse return null,
    };
    // `else` may follow on the next line.
    const save = p.pos;
    support.skipNl(p);
    // A following `else ->` is a `when`-arm else, not this `if`'s
    // else branch — do not consume it (upstream kotlinx-coroutines
    // `when { ... cond -> if (c) return X; else -> ... }`).
    const else_is_when_arm = blk: {
        const is_else = switch (support.peekKind(p).*) {
            .Keyword => |k| k == .Else,
            else => false,
        };
        if (!is_else) break :blk false;
        var j = p.pos + 1;
        while (j < p.tokens.len and std.meta.activeTag(p.tokens[j].kind) == .Newline) {
            j += 1;
        }
        break :blk j < p.tokens.len and std.meta.activeTag(p.tokens[j].kind) == .Arrow;
    };
    const at_else = switch (support.peekKind(p).*) {
        .Keyword => |k| k == .Else,
        else => false,
    };
    var else_branch: ?*Expr = null;
    if (!else_is_when_arm and at_else) {
        _ = support.bump(p);
        support.skipNl(p);
        if (std.meta.activeTag(support.peekKind(p).*) == .Semicolon) {
            const semi = support.bump(p);
            else_branch = box(p, Expr{ .Block = .{
                .stmts = &.{},
                .span = semi.span,
            } });
        } else {
            const e = parseControlStructureBody(p) orelse return null;
            else_branch = box(p, e);
        }
    } else {
        p.pos = save;
        else_branch = null;
    }
    const end = if (else_branch) |e| e.span() else then_branch.span();
    return Expr{ .If = .{
        .cond = box(p, cond),
        .then_branch = box(p, then_branch),
        .else_branch = else_branch,
        .span = kw.span.join(end),
    } };
}

pub fn parseWhile(p: *Parser) ?Expr {
    const kw = support.bump(p);
    _ = support.expect(p, .LParen, "`(`") orelse return null;
    support.skipNl(p);
    const cond = parseExpr(p) orelse return null;
    support.skipNl(p);
    support.rejectTrailingAssignment(p);
    support.skipNl(p);
    _ = support.expect(p, .RParen, "`)`") orelse return null;
    support.skipNl(p);
    // An empty body (`while (cond) ;`) is a valid loop with no statements.
    const body: Expr = switch (support.peekKind(p).*) {
        .Semicolon => blk: {
            const semi = support.bump(p);
            break :blk Expr{ .Block = .{ .stmts = &.{}, .span = semi.span } };
        },
        else => parseControlStructureBody(p) orelse return null,
    };
    return Expr{ .While = .{
        .cond = box(p, cond),
        .body = box(p, body),
        .span = kw.span.join(body.span()),
    } };
}

pub fn parseDoWhile(p: *Parser) ?Expr {
    const kw = support.bump(p);
    support.skipNl(p);
    // Body is optional: `do { ... } while(c)` or `do; while(c)`.
    const is_while = switch (support.peekKind(p).*) {
        .Keyword => |k| k == .While,
        else => false,
    };
    var body: ?*Expr = null;
    if (!is_while) {
        const b = parseControlStructureBody(p) orelse return null;
        body = box(p, b);
    }
    support.skipNl(p);
    _ = support.expect(p, .{ .Keyword = .While }, "`while`") orelse return null;
    support.skipNl(p);
    _ = support.expect(p, .LParen, "`(`") orelse return null;
    support.skipNl(p);
    const cond = parseExpr(p) orelse return null;
    support.skipNl(p);
    support.rejectTrailingAssignment(p);
    support.skipNl(p);
    const rp = support.expect(p, .RParen, "`)`") orelse return null;
    return Expr{ .DoWhile = .{
        .body = body,
        .cond = box(p, cond),
        .span = kw.span.join(rp.span),
    } };
}

pub const DestructEntries = struct {
    names: []Ident,
    /// The property each name reads in the name-based form; empty otherwise.
    sources: []Ident,
    by_name: bool,
    /// Any entry declared `var` (the name-based form declares per entry).
    any_var: bool,
};

/// The entries of a destructuring group after its opener, up to and
/// including `close`: positional `a, b: T, _` (each name reads
/// `componentN`; inside `[ ]` an entry may also carry `val`/`var`), or the
/// name-based form `val a, var n: T = prop` inside `( )`, where each name
/// reads the property it names, or the one written after `=`.
pub fn parseDestructEntries(p: *Parser, close: TokenKind, positional: bool, what: []const u8) ?DestructEntries {
    var names: std.ArrayList(Ident) = .empty;
    var sources: std.ArrayList(Ident) = .empty;
    // Under `+NameBasedDestructuring` the parenthesized short form binds
    // by name too (`(a, b = prop)`); `[a, b]` is the positional form.
    var by_name = !positional and root.language.name_based_short_form;
    var any_var = false;
    while (true) {
        support.skipNl(p);
        if (std.meta.activeTag(support.peekKind(p).*) == std.meta.activeTag(close)) break;
        _ = parseAnnotations(p);
        if (std.meta.activeTag(support.peekKind(p).*) == .Keyword) {
            const kw = support.peekKind(p).Keyword;
            if (kw == .Val or kw == .Var) {
                _ = support.bump(p);
                if (kw == .Var) any_var = true;
                if (!positional) by_name = true;
            }
        }
        const id_span = support.currentSpan(p);
        const id_text = support.text(p, id_span);
        const id: Ident = if (std.mem.eql(u8, id_text, "_") and std.meta.activeTag(support.peekKind(p).*) == .Ident) blk: {
            _ = support.bump(p);
            break :blk Ident{ .name = "_", .span = id_span };
        } else (support.parseIdent(p, what) orelse return null);
        if (std.meta.activeTag(support.peekKind(p).*) == .Colon) {
            _ = support.bump(p);
            _ = parseType(p);
        }
        var source = id;
        if (std.meta.activeTag(support.peekKind(p).*) == .Eq) {
            if (!by_name) {
                _ = support.expect(p, close, "`,` or the closing bracket (renaming needs the name-based form `(val n = prop)`)") orelse return null;
                return null;
            }
            _ = support.bump(p);
            support.skipNl(p);
            source = support.parseIdent(p, "property name") orelse return null;
        }
        names.append(p.allocator, id) catch @panic("OOM in parser");
        sources.append(p.allocator, source) catch @panic("OOM in parser");
        support.skipNl(p);
        if (std.meta.activeTag(support.peekKind(p).*) == .Comma) {
            _ = support.bump(p);
            continue;
        }
        break;
    }
    _ = support.expect(p, close, if (std.meta.activeTag(close) == .RBracket) "`]`" else "`)`") orelse return null;
    return .{
        .names = names.toOwnedSlice(p.allocator) catch @panic("OOM in parser"),
        .sources = sources.toOwnedSlice(p.allocator) catch @panic("OOM in parser"),
        .by_name = by_name,
        .any_var = any_var,
    };
}

pub fn parseFor(p: *Parser) ?Expr {
    const kw = support.bump(p);
    _ = support.expect(p, .LParen, "`(`") orelse return null;
    support.skipNl(p);
    // `{annotation} (variableDeclaration | multiVariableDeclaration)`.
    // Annotations on the iteration variable are accepted and consumed
    // syntactically; no semantics yet.
    _ = parseAnnotations(p);
    // Destructuring: `for ((a, b) in iter)`, `for ([a, b] in iter)`, or the
    // name-based `for ((val k, val v) in iter)`. Plain: `for (x in iter)`.
    var vars: []Ident = undefined;
    var for_by_name = false;
    var var_sources: []Ident = &.{};
    const opener = std.meta.activeTag(support.peekKind(p).*);
    if (opener == .LParen or opener == .LBracket) {
        _ = support.bump(p);
        const entries = parseDestructEntries(
            p,
            if (opener == .LBracket) .RBracket else .RParen,
            opener == .LBracket,
            "destructured loop variable",
        ) orelse return null;
        vars = entries.names;
        for_by_name = entries.by_name;
        var_sources = entries.sources;
    } else {
        const id = support.parseIdent(p, "loop variable") orelse return null;
        vars = singleIdent(p, id);
    }
    var var_ty: ?TypeRef = null;
    if (std.meta.activeTag(support.peekKind(p).*) == .Colon) {
        _ = support.bump(p);
        var_ty = parseType(p);
    }
    support.skipNl(p);
    _ = support.expect(p, .{ .Keyword = .In }, "`in`") orelse return null;
    support.skipNl(p);
    const iter = parseExpr(p) orelse return null;
    support.skipNl(p);
    support.rejectTrailingAssignment(p);
    support.skipNl(p);
    _ = support.expect(p, .RParen, "`)`") orelse return null;
    support.skipNl(p);
    const body = parseControlStructureBody(p) orelse return null;
    return Expr{ .For = .{
        .vars = vars,
        .by_name = for_by_name,
        .var_sources = var_sources,
        .var_ty = var_ty,
        .iter = box(p, iter),
        .body = box(p, body),
        .span = kw.span.join(body.span()),
    } };
}

pub fn parseReturn(p: *Parser) ?Expr {
    const kw = support.bump(p);
    const label = consumeJumpLabel(p);
    if (support.atNewlineOrSemiOrClose(p)) {
        const sp = if (label) |l| kw.span.join(l.span) else kw.span;
        return Expr{ .Return = .{
            .value = null,
            .label = label,
            .span = sp,
        } };
    }
    const value = parseExpr(p) orelse return null;
    const sp = kw.span.join(value.span());
    return Expr{ .Return = .{
        .value = box(p, value),
        .label = label,
        .span = sp,
    } };
}

/// `label@ <expr>` at expression position. The label name is a bare
/// identifier; the `@` may be `AtNoWs` (`foo@`) or `AtPostWs`
/// (`foo@ for(...)` with trailing whitespace before the labeled form),
/// matching the spec's `simpleIdentifier (AT_NO_WS | AT_POST_WS)` rule.
pub fn tryParseLabelBinding(p: *Parser) ?Expr {
    if (std.meta.activeTag(support.peekKind(p).*) != .Ident) {
        return null;
    }
    const at_ok = p.pos + 1 < p.tokens.len and switch (p.tokens[p.pos + 1].kind) {
        .AtNoWs, .AtPostWs => true,
        else => false,
    };
    if (!at_ok) {
        return null;
    }
    const name_span = support.currentSpan(p);
    const label = Ident{
        .name = support.identName(p, name_span),
        .span = name_span,
    };
    _ = support.bump(p);
    _ = support.bump(p);
    support.skipNl(p);
    const inner = parseUnaryForLabel(p) orelse return null;
    const sp = label.span.join(inner.span());
    return Expr{ .Labeled = .{
        .label = label,
        .expr = box(p, inner),
        .span = sp,
    } };
}

/// Parse the body of a `label@ <body>` binding. We re-enter the prefix
/// rung so the labeled inner expression captures call-chains and
/// trailing-lambda arguments as usual.
pub fn parseUnaryForLabel(p: *Parser) ?Expr {
    return parsePrefix(p);
}

/// After a `return` / `break` / `continue` keyword, consume an optional
/// `@label` suffix. The lexer emits `AtNoWs` when the `@` is directly
/// attached to the keyword (`return@foo`), so we only accept that shape.
pub fn consumeJumpLabel(p: *Parser) ?Ident {
    if (std.meta.activeTag(support.peekKind(p).*) != .AtNoWs) {
        return null;
    }
    _ = support.bump(p);
    return support.parseIdent(p, "jump label");
}

pub fn parseThrow(p: *Parser) ?Expr {
    const kw = support.bump(p);
    support.skipNl(p);
    const value = parseExpr(p) orelse return null;
    const sp = kw.span.join(value.span());
    return Expr{ .Throw = .{
        .value = box(p, value),
        .span = sp,
    } };
}

pub fn parseTry(p: *Parser) ?Expr {
    const kw = support.bump(p);
    support.skipNl(p);
    const body = parseBlock(p) orelse return null;
    var catches: std.ArrayList(Catch) = .empty;
    while (true) {
        const save = p.pos;
        support.skipNl(p);
        if (!support.peekKeywordIdent(p, "catch")) {
            p.pos = save;
            break;
        }
        _ = support.bump(p);
        _ = support.expect(p, .LParen, "`(`") orelse return null;
        support.skipNl(p);
        const binding = support.parseIdent(p, "catch binding") orelse return null;
        _ = support.expect(p, .Colon, "`:`") orelse return null;
        const ty = parseQualifiedType(p) orelse return null;
        support.skipNl(p);
        _ = support.expect(p, .RParen, "`)`") orelse return null;
        support.skipNl(p);
        const catch_body = parseBlock(p) orelse return null;
        const sp = binding.span.join(catch_body.span);
        catches.append(p.allocator, .{
            .binding = binding,
            .ty = ty,
            .body = catch_body,
            .span = sp,
        }) catch @panic("OOM in parser");
    }
    var finally: ?Block = null;
    {
        const save = p.pos;
        support.skipNl(p);
        if (support.peekKeywordIdent(p, "finally")) {
            _ = support.bump(p);
            support.skipNl(p);
            finally = parseBlock(p);
        } else {
            p.pos = save;
            finally = null;
        }
    }
    const catches_slice = catches.toOwnedSlice(p.allocator) catch @panic("OOM in parser");
    const end = if (finally) |b|
        b.span
    else if (catches_slice.len > 0)
        catches_slice[catches_slice.len - 1].body.span
    else
        body.span;
    return Expr{ .Try = .{
        .body = body,
        .catches = catches_slice,
        .finally = finally,
        .span = kw.span.join(end),
    } };
}

pub fn parseWhen(p: *Parser) ?Expr {
    const kw = support.bump(p); // `when`
    support.skipNl(p);
    var subject: ?*Expr = null;
    var subject_binding: ?WhenBinding = null;
    if (std.meta.activeTag(support.peekKind(p).*) == .LParen) {
        _ = support.bump(p);
        support.skipNl(p);
        if (tryParseWhenBinding(p)) |bound| {
            subject_binding = bound.binding;
            subject = box(p, bound.expr);
        } else {
            const e = parseExpr(p) orelse return null;
            subject = box(p, e);
        }
        support.skipNl(p);
        support.rejectTrailingAssignment(p);
        support.skipNl(p);
        _ = support.expect(p, .RParen, "`)`") orelse return null;
    }
    support.skipNl(p);
    _ = support.expect(p, .LBrace, "`{`") orelse return null;
    var branches: std.ArrayList(WhenBranch) = .empty;
    while (true) {
        skipStmtSeparators(p);
        switch (support.peekKind(p).*) {
            .RBrace, .Eof => break,
            else => {},
        }
        const branch = parseWhenBranch(p, subject != null) orelse {
            support.recoverToStmtEnd(p);
            continue;
        };
        branches.append(p.allocator, branch) catch @panic("OOM in parser");
    }
    const rbrace = support.expect(p, .RBrace, "`}`") orelse return null;
    return Expr{ .When = .{
        .subject = subject,
        .subject_binding = subject_binding,
        .branches = branches.toOwnedSlice(p.allocator) catch @panic("OOM in parser"),
        .span = kw.span.join(rbrace.span),
    } };
}

const WhenBindingResult = struct {
    binding: WhenBinding,
    expr: Expr,
};

/// Look ahead inside `when (` for the `{annotation}* val name (: Ty)? =`
/// shape that introduces a subject-bound variable. Commits and parses the
/// binding + subject expression on a positive match; leaves the cursor
/// unchanged otherwise so the caller can fall back to a bare subject.
pub fn tryParseWhenBinding(p: *Parser) ?WhenBindingResult {
    const save = p.pos;
    const annotations = parseAnnotations(p);
    support.skipNl(p);
    const at_val = switch (support.peekKind(p).*) {
        .Keyword => |k| k == .Val,
        else => false,
    };
    if (!at_val) {
        p.pos = save;
        return null;
    }
    // Peek further: val NAME (':' …)? '='
    var i = p.pos + 1;
    while (i < p.tokens.len and std.meta.activeTag(p.tokens[i].kind) == .Newline) {
        i += 1;
    }
    if (!(i < p.tokens.len and std.meta.activeTag(p.tokens[i].kind) == .Ident)) {
        p.pos = save;
        return null;
    }
    // Skip past the name and optional `: Type` to look for `=`.
    var j = i + 1;
    while (j < p.tokens.len and std.meta.activeTag(p.tokens[j].kind) == .Newline) {
        j += 1;
    }
    const next_j = if (j < p.tokens.len) std.meta.activeTag(p.tokens[j].kind) else .Eof;
    if (next_j == .Colon) {
        // Type follows; scanning for `=` past an arbitrary type list is
        // fragile, so commit and let the recovery path handle ill-formed
        // bindings.
    } else if (next_j != .Eq) {
        p.pos = save;
        return null;
    }
    const val_span = support.bump(p).span; // `val`
    support.skipNl(p);
    const name = support.parseIdent(p, "when-binding name") orelse {
        p.pos = save;
        return null;
    };
    var ty: ?TypeRef = null;
    support.skipNl(p);
    if (std.meta.activeTag(support.peekKind(p).*) == .Colon) {
        _ = support.bump(p);
        support.skipNl(p);
        ty = parseType(p);
    }
    support.skipNl(p);
    _ = support.expect(p, .Eq, "`=`") orelse return null;
    support.skipNl(p);
    const expr = parseExpr(p) orelse return null;
    const end = if (ty) |t| t.span else name.span;
    const binding = WhenBinding{
        .name = name,
        .ty = ty,
        .annotations = annotations,
        .span = val_span.join(end),
    };
    return WhenBindingResult{ .binding = binding, .expr = expr };
}

pub fn parseWhenBranch(p: *Parser, has_subject: bool) ?WhenBranch {
    support.skipNl(p);
    const start = support.currentSpan(p);
    var patterns: std.ArrayList(WhenPattern) = .empty;
    while (true) {
        support.skipNl(p);
        const pat = parseWhenPattern(p, has_subject) orelse return null;
        patterns.append(p.allocator, pat) catch @panic("OOM in parser");
        support.skipNl(p);
        if (std.meta.activeTag(support.peekKind(p).*) == .Comma) {
            _ = support.bump(p);
            continue;
        }
        break;
    }
    support.skipNl(p);
    _ = support.expect(p, .Arrow, "`->`") orelse return null;
    support.skipNl(p);
    // Branch bodies are control-structure bodies: an assignment statement
    // (`sum += item`) is allowed alongside expressions.
    const body = parseControlStructureBody(p) orelse return null;
    const sp = start.join(body.span());
    return WhenBranch{
        .patterns = patterns.toOwnedSlice(p.allocator) catch @panic("OOM in parser"),
        .body = body,
        .span = sp,
    };
}

pub fn parseWhenPattern(p: *Parser, has_subject: bool) ?WhenPattern {
    const start = support.currentSpan(p);
    // `else` — always valid as a pattern.
    const at_else = switch (support.peekKind(p).*) {
        .Keyword => |k| k == .Else,
        else => false,
    };
    if (at_else) {
        const tok = support.bump(p);
        return WhenPattern{
            .kind = .Else,
            .span = tok.span,
        };
    }
    // Subject-bound patterns can use `is Type`, `!is Type`, `in expr`,
    // `!in expr`. Subject-free `when` only accepts Boolean conditions
    // (Value patterns) — but we still parse the keyword forms and let the
    // interpreter reject them; this keeps recovery simple.
    if (has_subject) {
        switch (support.peekKind(p).*) {
            .Keyword => |k| switch (k) {
                .Is => {
                    _ = support.bump(p);
                    const ty = parseQualifiedType(p) orelse return null;
                    const sp = start.join(ty.span);
                    return WhenPattern{
                        .kind = .{ .IsType = ty },
                        .span = sp,
                    };
                },
                .In => {
                    _ = support.bump(p);
                    support.skipNl(p);
                    const e = parseExpr(p) orelse return null;
                    const sp = start.join(e.span());
                    return WhenPattern{
                        .kind = .{ .InRange = e },
                        .span = sp,
                    };
                },
                else => {},
            },
            else => {
                if (support.peekKind(p).isBang()) {
                    const next_kind: ?lexerKeyword = blk: {
                        if (p.pos + 1 < p.tokens.len) {
                            switch (p.tokens[p.pos + 1].kind) {
                                .Keyword => |k| break :blk k,
                                else => break :blk null,
                            }
                        }
                        break :blk null;
                    };
                    if (next_kind) |nk| {
                        if (nk == .Is) {
                            _ = support.bump(p);
                            _ = support.bump(p);
                            const ty = parseQualifiedType(p) orelse return null;
                            const sp = start.join(ty.span);
                            return WhenPattern{
                                .kind = .{ .NotIsType = ty },
                                .span = sp,
                            };
                        } else if (nk == .In) {
                            _ = support.bump(p);
                            _ = support.bump(p);
                            support.skipNl(p);
                            const e = parseExpr(p) orelse return null;
                            const sp = start.join(e.span());
                            return WhenPattern{
                                .kind = .{ .NotInRange = e },
                                .span = sp,
                            };
                        }
                    }
                }
            },
        }
    }
    const e = parseExpr(p) orelse return null;
    const sp = start.join(e.span());
    return WhenPattern{
        .kind = .{ .Value = e },
        .span = sp,
    };
}

pub fn parseLambdaLiteral(p: *Parser) ?Expr {
    // We're at `{`. Header is `params ->` (optional). Body is a
    // statement list.
    const lbrace = support.bump(p);
    var header = parseLambdaHeader(p);
    // A header-less lambda (`{ … }`) gets the implicit single `it` parameter,
    // exactly as a trailing lambda does — otherwise a non-trailing lambda
    // argument (`f({ it.x }, y)` / `Op("d", { member() }, …)`) loses both its
    // `it` and the arity-0 receiver-lambda treatment.
    var implicit_it = false;
    if (header.params.len == 0) {
        implicit_it = true;
        header.params = singleIdent(p, .{
            .name = "it",
            .span = lbrace.span,
        });
    }
    var stmts: std.ArrayList(Stmt) = .empty;
    for (header.dest_stmts) |s| stmts.append(p.allocator, s) catch @panic("OOM in parser");
    while (true) {
        skipStmtSeparators(p);
        switch (support.peekKind(p).*) {
            .RBrace, .Eof => break,
            else => {},
        }
        if (parseStmt(p)) |s| {
            stmts.append(p.allocator, s) catch @panic("OOM in parser");
        } else {
            support.recoverToStmtEnd(p);
        }
        const sep_ok = switch (support.peekKind(p).*) {
            .Newline, .Semicolon, .RBrace, .Eof => true,
            else => false,
        };
        if (!sep_ok) {
            const sp = support.currentSpan(p);
            support.err(p, "E0004", "expected newline or `;` between statements", sp);
            support.recoverToStmtEnd(p);
        }
    }
    const rbrace = support.expect(p, .RBrace, "`}`") orelse return null;
    const sp = lbrace.span.join(rbrace.span);
    const body = Block{
        .stmts = stmts.toOwnedSlice(p.allocator) catch @panic("OOM in parser"),
        .span = sp,
    };
    return Expr{ .Lambda = .{ .params = header.params, .param_tys = header.param_tys, .body = body, .span = sp, .implicit_it = implicit_it } };
}

pub fn parseTrailingLambda(p: *Parser) ?Expr {
    // Same shape; if no `->` is present, default to a single `it` param.
    const lbrace = support.bump(p);
    var header = parseLambdaHeader(p);
    var implicit_it = false;
    if (header.params.len == 0) {
        implicit_it = true;
        header.params = singleIdent(p, .{
            .name = "it",
            .span = lbrace.span,
        });
    }
    var stmts: std.ArrayList(Stmt) = .empty;
    for (header.dest_stmts) |s| stmts.append(p.allocator, s) catch @panic("OOM in parser");
    while (true) {
        skipStmtSeparators(p);
        switch (support.peekKind(p).*) {
            .RBrace, .Eof => break,
            else => {},
        }
        if (parseStmt(p)) |s| {
            stmts.append(p.allocator, s) catch @panic("OOM in parser");
        } else {
            support.recoverToStmtEnd(p);
        }
        const sep_ok = switch (support.peekKind(p).*) {
            .Newline, .Semicolon, .RBrace, .Eof => true,
            else => false,
        };
        if (!sep_ok) {
            const sp = support.currentSpan(p);
            support.err(p, "E0004", "expected newline or `;` between statements", sp);
            support.recoverToStmtEnd(p);
        }
    }
    const rbrace = support.expect(p, .RBrace, "`}`") orelse return null;
    const sp = lbrace.span.join(rbrace.span);
    const body = Block{
        .stmts = stmts.toOwnedSlice(p.allocator) catch @panic("OOM in parser"),
        .span = sp,
    };
    return Expr{ .Lambda = .{ .params = header.params, .param_tys = header.param_tys, .body = body, .span = sp, .implicit_it = implicit_it } };
}

/// Does the `{ … }` at the cursor have a `params ->` header?
/// True iff an `Arrow` token occurs at the lambda's own nesting
/// level (depth 0) before its closing `}`. Nested lambdas /
/// function types / `when` arrows sit at depth > 0 and are
/// ignored. Non-mutating.
///
/// A depth-0 `->` that belongs to a *function type* rather than a
/// lambda header does not count. The unambiguous signal is an `as` /
/// `as?` cast keyword at depth 0 before the arrow: a lambda parameter
/// list never contains `as`, so `{ x as () -> T; … }` is a block whose
/// first statement casts `x` to a function type, not a lambda
/// `{ params -> body }`. Without this, the function-type arrow in the
/// cast target is mistaken for a lambda header and the surrounding
/// `{ }` is parsed as a function value.
pub fn lambdaHasHeader(p: *const Parser) bool {
    var depth: i32 = 0;
    var i = p.pos;
    while (i < p.tokens.len) : (i += 1) {
        switch (p.tokens[i].kind) {
            .Arrow => if (depth == 0) return true,
            .Keyword => |kw| if (depth == 0 and kw == .As) return false,
            .LParen, .LBracket, .LBrace => {
                depth += 1;
            },
            .RParen, .RBracket => {
                depth -= 1;
            },
            .RBrace => {
                if (depth == 0) {
                    return false;
                }
                depth -= 1;
            },
            .Eof => return false,
            else => {},
        }
    }
    return false;
}

const LambdaHeader = struct {
    params: []Ident,
    /// Declared type annotations aligned with `params` (`null` per
    /// unannotated slot); empty when no header was parsed.
    param_tys: []?TypeRef = &.{},
    dest_stmts: []Stmt,
};

/// Reads the optional `params ->` header inside a `{ ... }` lambda.
/// Returns the param list (empty if no `->` is present) and a list of
/// destructuring statements that the caller should prepend to the body
/// — one `val (a, b, …) = $$dest_<i>` per destructured slot.
pub fn parseLambdaHeader(p: *Parser) LambdaHeader {
    const empty = LambdaHeader{ .params = &.{}, .param_tys = &.{}, .dest_stmts = &.{} };
    const save = p.pos;
    support.skipNl(p);
    // Empty `{ -> ... }` form: arrow at front, no params.
    if (std.meta.activeTag(support.peekKind(p).*) == .Arrow) {
        _ = support.bump(p);
        return empty;
    }
    // A header exists only if a `->` appears at the lambda's top level
    // before its closing `}`. Without this guard a body that opens with
    // `(` — e.g. `{ ((if (c) a else b) + x) }` — is misparsed as a
    // destructuring parameter list, emitting diagnostics that can't be
    // unwound on backtrack.
    if (!lambdaHasHeader(p)) {
        return empty;
    }
    // `(ident (: Type)?, …)` destructured param OR
    // `ident (: Type)?, ident (: Type)?, … ->`
    const at_param_start = switch (support.peekKind(p).*) {
        .Ident, .LParen, .LBracket => true,
        else => false,
    };
    if (at_param_start) {
        var local: std.ArrayList(Ident) = .empty;
        var local_tys: std.ArrayList(?TypeRef) = .empty;
        const Pending = struct {
            idx: usize,
            names: []Ident,
            sources: []Ident,
            by_name: bool,
            span: Span,
        };
        var pending_dest: std.ArrayList(Pending) = .empty;
        loop: while (true) {
            switch (support.peekKind(p).*) {
                .Ident => {
                    const tok = support.bump(p);
                    local.append(p.allocator, .{
                        .name = support.identName(p, tok.span),
                        .span = tok.span,
                    }) catch @panic("OOM in parser");
                    support.skipNl(p);
                    var pty: ?TypeRef = null;
                    if (std.meta.activeTag(support.peekKind(p).*) == .Colon) {
                        _ = support.bump(p);
                        pty = parseType(p);
                        support.skipNl(p);
                    }
                    local_tys.append(p.allocator, pty) catch @panic("OOM in parser");
                },
                .LParen, .LBracket => {
                    const lparen = support.bump(p);
                    const bracket = std.meta.activeTag(lparen.kind) == .LBracket;
                    const entries = parseDestructEntries(
                        p,
                        if (bracket) .RBracket else .RParen,
                        bracket,
                        "destructured lambda param",
                    ) orelse {
                        p.pos = save;
                        return empty;
                    };
                    const rparen = p.tokens[p.pos - 1];
                    const sp = lparen.span.join(rparen.span);
                    const outer = std.fmt.allocPrint(p.allocator, "$$dest_{d}", .{local.items.len}) catch @panic("OOM in parser");
                    local.append(p.allocator, .{ .name = outer, .span = sp }) catch @panic("OOM in parser");
                    local_tys.append(p.allocator, null) catch @panic("OOM in parser");
                    pending_dest.append(p.allocator, .{
                        .idx = local.items.len - 1,
                        .names = entries.names,
                        .sources = entries.sources,
                        .by_name = entries.by_name,
                        .span = sp,
                    }) catch @panic("OOM in parser");
                    support.skipNl(p);
                },
                else => break :loop,
            }
            if (std.meta.activeTag(support.peekKind(p).*) == .Comma) {
                _ = support.bump(p);
                support.skipNl(p);
                continue;
            }
            break;
        }
        support.skipNl(p);
        if (std.meta.activeTag(support.peekKind(p).*) == .Arrow) {
            _ = support.bump(p);
            const params = local.toOwnedSlice(p.allocator) catch @panic("OOM in parser");
            const param_tys = local_tys.toOwnedSlice(p.allocator) catch @panic("OOM in parser");
            var dest_stmts: std.ArrayList(Stmt) = .empty;
            for (pending_dest.items) |pd| {
                const init = Expr{ .Path = .{
                    .segments = singleIdent(p, params[pd.idx]),
                    .span = pd.span,
                } };
                dest_stmts.append(p.allocator, .{ .DestructuringDecl = .{
                    .mutable = false,
                    .names = pd.names,
                    .by_name = pd.by_name,
                    .sources = pd.sources,
                    .init = init,
                    .span = pd.span,
                } }) catch @panic("OOM in parser");
            }
            return LambdaHeader{
                .params = params,
                .param_tys = param_tys,
                .dest_stmts = dest_stmts.toOwnedSlice(p.allocator) catch @panic("OOM in parser"),
            };
        }
        // No arrow — the idents we consumed are actually body expression
        // tokens. Rewind so parseStmt sees them.
        p.pos = save;
    }
    return empty;
}

comptime {
    _ = Parser;
}
