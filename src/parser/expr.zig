//! Pratt expression parser (precedence climbing) and operator handling. Free
//! functions over `*Parser`; the entry point is `expr.parseExpr(p)`.

const std = @import("std");

const ast = @import("ast");
const lexer = @import("lexer");
const span = @import("span");

const root = @import("parser.zig");
const support = @import("support.zig");
const types_mod = @import("types.zig");
const file_mod = @import("file.zig");
const control_mod = @import("control.zig");
const primary_mod = @import("primary.zig");

const Parser = root.Parser;
const Expr = ast.Expr;
const Ident = ast.Ident;
const TypeRef = ast.TypeRef;
const Annotation = ast.Annotation;
const BinOp = ast.BinOp;
const UnOp = ast.UnOp;
const PostfixOp = ast.PostfixOp;
const Keyword = lexer.Keyword;
const TokenKind = lexer.TokenKind;
const Span = span.Span;

fn boxExpr(p: *Parser, e: Expr) *Expr {
    const ptr = p.allocator.create(Expr) catch @panic("OOM boxing expr");
    ptr.* = e;
    return ptr;
}

fn kindAt(p: *const Parser, i: usize) ?TokenKind {
    if (i >= p.tokens.len) return null;
    return p.tokens[i].kind;
}

/// Look ahead from an `@` at index `i` past one or more annotation forms, to
/// spot an annotation prefixing a trailing lambda.
fn skipAnnotationTokens(p: *const Parser, i: usize) usize {
    var j = i;
    while (j < p.tokens.len and p.tokens[j].kind.isAt()) {
        j += 1;
        if (j < p.tokens.len and std.meta.activeTag(p.tokens[j].kind) == .LBracket) {
            var depth: i32 = 1;
            j += 1;
            while (j < p.tokens.len and depth > 0) : (j += 1) {
                switch (p.tokens[j].kind) {
                    .LBracket => depth += 1,
                    .RBracket => depth -= 1,
                    .Eof => break,
                    else => {},
                }
            }
        } else {
            while (j < p.tokens.len and std.meta.activeTag(p.tokens[j].kind) == .Ident) {
                j += 1;
                if (j < p.tokens.len and std.meta.activeTag(p.tokens[j].kind) == .Dot) {
                    j += 1;
                } else break;
            }
            if (j < p.tokens.len and std.meta.activeTag(p.tokens[j].kind) == .LParen) {
                var depth: i32 = 1;
                j += 1;
                while (j < p.tokens.len and depth > 0) : (j += 1) {
                    switch (p.tokens[j].kind) {
                        .LParen => depth += 1,
                        .RParen => depth -= 1,
                        .Eof => break,
                        else => {},
                    }
                }
            }
        }
        while (j < p.tokens.len and std.meta.activeTag(p.tokens[j].kind) == .Newline) j += 1;
    }
    return j;
}

// These parse routines live in sibling modules, reached through a `@hasDecl`
// gate that yields an empty result when the declaration is absent.

fn parseQualifiedType(p: *Parser) ?TypeRef {
    if (@hasDecl(types_mod, "parseQualifiedType")) return types_mod.parseQualifiedType(p);
    return null;
}

fn parseCallTypeArgs(p: *Parser) []TypeRef {
    if (@hasDecl(types_mod, "parseCallTypeArgs")) return types_mod.parseCallTypeArgs(p);
    return &.{};
}

fn trySkipGenericCallArgs(p: *const Parser) bool {
    if (@hasDecl(types_mod, "trySkipGenericCallArgs")) return types_mod.trySkipGenericCallArgs(p);
    return false;
}

fn parseAnnotations(p: *Parser) []Annotation {
    if (@hasDecl(file_mod, "parseAnnotations")) return file_mod.parseAnnotations(p);
    return &.{};
}

fn parseLambdaLiteral(p: *Parser) ?Expr {
    if (@hasDecl(control_mod, "parseLambdaLiteral")) return control_mod.parseLambdaLiteral(p);
    return null;
}

fn parseTrailingLambda(p: *Parser) ?Expr {
    if (@hasDecl(control_mod, "parseTrailingLambda")) return control_mod.parseTrailingLambda(p);
    return null;
}

fn parsePrimary(p: *Parser) ?Expr {
    if (@hasDecl(primary_mod, "parsePrimary")) return primary_mod.parsePrimary(p);
    return null;
}

pub fn parseExpr(p: *Parser) ?Expr {
    return parseDisjunction(p);
}

/// Consume and discard a leading expression annotation, which Kotlin allows
/// (`@Suppress("UNCHECKED_CAST") (x as T)`) and which is a runtime no-op.
/// Applied only at control-structure-body and when-branch position, so it never
/// shadows the label, `this@` and `return@` uses of `@`.
pub fn skipLeadingExprAnnotation(p: *Parser) void {
    if (atExpressionAnnotation(p)) {
        _ = parseAnnotations(p);
        support.skipNl(p);
    }
}

pub fn atExpressionAnnotation(p: *const Parser) bool {
    if (!support.peekKind(p).isAt()) return false;
    return switch (kindAt(p, p.pos + 1) orelse return false) {
        .Ident, .LBracket => true,
        else => false,
    };
}

/// Kotlin allows an annotation on the body expression; it is discarded.
pub fn parseExprBody(p: *Parser) ?Expr {
    if (support.peekKind(p).isAt()) {
        _ = parseAnnotations(p);
        support.skipNl(p);
    }
    return parseExpr(p);
}

pub fn parseDisjunction(p: *Parser) ?Expr {
    var lhs = parseConjunction(p) orelse return null;
    while (true) {
        support.skipSoftNl(p);
        // `||` cannot start a statement, so a line beginning with it continues the expression.
        if (support.newlineThen(p, .PipePipe)) {
            support.skipNl(p);
        }
        if (std.meta.activeTag(support.peekKind(p).*) != .PipePipe) {
            break;
        }
        _ = support.bump(p);
        support.skipNl(p);
        const rhs = parseConjunction(p) orelse return null;
        const sp = lhs.span().join(rhs.span());
        lhs = Expr{ .Binary = .{
            .op = .Or,
            .lhs = boxExpr(p, lhs),
            .rhs = boxExpr(p, rhs),
            .span = sp,
        } };
    }
    return lhs;
}

pub fn parseConjunction(p: *Parser) ?Expr {
    var lhs = parseEquality(p) orelse return null;
    while (true) {
        support.skipSoftNl(p);
        // `&&` cannot start a statement, so a line beginning with it continues the expression.
        if (support.newlineThen(p, .AmpAmp)) {
            support.skipNl(p);
        }
        if (std.meta.activeTag(support.peekKind(p).*) != .AmpAmp) {
            break;
        }
        _ = support.bump(p);
        support.skipNl(p);
        const rhs = parseEquality(p) orelse return null;
        const sp = lhs.span().join(rhs.span());
        lhs = Expr{ .Binary = .{
            .op = .And,
            .lhs = boxExpr(p, lhs),
            .rhs = boxExpr(p, rhs),
            .span = sp,
        } };
    }
    return lhs;
}

pub fn parseEquality(p: *Parser) ?Expr {
    var lhs = parseComparison(p) orelse return null;
    while (true) {
        support.skipSoftNl(p);
        const op: BinOp = switch (support.peekKind(p).*) {
            .EqEq => .Eq,
            .BangEq => .Neq,
            .EqEqEq => .IdentEq,
            .BangEqEq => .IdentNeq,
            else => break,
        };
        _ = support.bump(p);
        support.skipNl(p);
        const rhs = parseComparison(p) orelse return null;
        const sp = lhs.span().join(rhs.span());
        lhs = Expr{ .Binary = .{
            .op = op,
            .lhs = boxExpr(p, lhs),
            .rhs = boxExpr(p, rhs),
            .span = sp,
        } };
    }
    return lhs;
}

pub fn parseComparison(p: *Parser) ?Expr {
    var lhs = parseNamedChecks(p) orelse return null;
    while (true) {
        support.skipSoftNl(p);
        // `in` / `!in` sit at comparison precedence, `!in` being two tokens;
        // `!is` is handled inside `parseNamedChecks`.
        const op: BinOp = switch (support.peekKind(p).*) {
            .Lt => .Lt,
            .Le => .Le,
            .Gt => .Gt,
            .Ge => .Ge,
            .Keyword => |kw| if (kw == .In) BinOp.In else break,
            else => |k| blk: {
                if (k.isBang()) {
                    const next = kindAt(p, p.pos + 1);
                    if (next != null and std.meta.activeTag(next.?) == .Keyword and next.?.Keyword == .In) {
                        _ = support.bump(p); // `!`
                        break :blk BinOp.NotIn;
                    }
                    break;
                }
                break;
            },
        };
        _ = support.bump(p);
        support.skipNl(p);
        const rhs = parseNamedChecks(p) orelse return null;
        const sp = lhs.span().join(rhs.span());
        lhs = Expr{ .Binary = .{
            .op = op,
            .lhs = boxExpr(p, lhs),
            .rhs = boxExpr(p, rhs),
            .span = sp,
        } };
    }
    return lhs;
}

/// Lower precedence than comparison, higher than elvis. `!is` is two tokens.
pub fn parseNamedChecks(p: *Parser) ?Expr {
    var lhs = parseElvis(p) orelse return null;
    while (true) {
        support.skipSoftNl(p);
        const negated = switch (support.peekKind(p).*) {
            .Keyword => |kw| if (kw == .Is) false else break,
            else => |k| blk: {
                if (k.isBang()) {
                    const next = kindAt(p, p.pos + 1);
                    if (!(next != null and std.meta.activeTag(next.?) == .Keyword and next.?.Keyword == .Is)) {
                        break;
                    }
                    _ = support.bump(p); // `!`
                    break :blk true;
                }
                break;
            },
        };
        _ = support.bump(p); // `is`
        support.skipNl(p);
        const ty = parseQualifiedType(p) orelse break;
        const sp = lhs.span().join(ty.span);
        lhs = Expr{ .IsCheck = .{
            .expr = boxExpr(p, lhs),
            .ty = ty,
            .negated = negated,
            .span = sp,
        } };
    }
    return lhs;
}

pub fn parseElvis(p: *Parser) ?Expr {
    var lhs = parseInfixFn(p) orelse return null;
    while (true) {
        support.skipSoftNl(p);
        // `?:` cannot start a statement, so a line beginning with it continues the expression.
        if (support.newlineThen(p, .QuestionColon)) {
            support.skipNl(p);
        }
        if (std.meta.activeTag(support.peekKind(p).*) != .QuestionColon) {
            break;
        }
        _ = support.bump(p);
        support.skipNl(p);
        const rhs = parseInfixFn(p) orelse return null;
        const sp = lhs.span().join(rhs.span());
        lhs = Expr{ .Binary = .{
            .op = .Elvis,
            .lhs = boxExpr(p, lhs),
            .rhs = boxExpr(p, rhs),
            .span = sp,
        } };
    }
    return lhs;
}

/// Desugared to `Call(Path[name], [lhs, rhs])`; typeck enforces the `infix`
/// modifier (T0029).
pub fn parseInfixFn(p: *Parser) ?Expr {
    var lhs = parseRange(p) orelse return null;
    while (true) {
        support.skipSoftNl(p);
        if (std.meta.activeTag(support.peekKind(p).*) != .Ident) {
            break;
        }
        const name_span = support.currentSpan(p);
        const name = support.text(p, name_span);
        if (!root.isValidInfixName(name)) {
            break;
        }
        if (!lookaheadInfixRhsStarter(p)) {
            break;
        }
        _ = support.bump(p);
        support.skipNl(p);
        const rhs = parseRange(p) orelse return null;
        const sp = lhs.span().join(rhs.span());
        const callee = Expr{ .Path = .{
            .segments = blk: {
                const segs = p.allocator.alloc(Ident, 1) catch @panic("OOM");
                segs[0] = .{ .name = name, .span = name_span };
                break :blk segs;
            },
            .span = name_span,
        } };
        const args = p.allocator.alloc(Expr, 2) catch @panic("OOM");
        args[0] = lhs;
        args[1] = rhs;
        const arg_names = p.allocator.alloc(?[]const u8, 2) catch @panic("OOM");
        arg_names[0] = null;
        arg_names[1] = null;
        lhs = Expr{ .Call = .{
            .callee = boxExpr(p, callee),
            .args = args,
            .arg_names = arg_names,
            .type_args = &.{},
            .is_infix = true,
            .span = sp,
        } };
    }
    return lhs;
}

/// After tentatively reading an infix-candidate identifier, confirm an
/// expression continues: inside `(`/`[` the right operand may start on the next
/// line.
pub fn lookaheadInfixRhsStarter(p: *const Parser) bool {
    // A valid infix name demands a right operand, so a following newline is a
    // continuation, whatever the bracket nesting.
    var i = p.pos + 1;
    while (kindAt(p, i)) |k| {
        if (std.meta.activeTag(k) != .Newline) break;
        i += 1;
    }
    const next = kindAt(p, i);
    if (next == null) return false;
    return switch (next.?) {
        .Newline,
        .Semicolon,
        .Eof,
        .RBrace,
        .RParen,
        .RBracket,
        .Comma,
        .Eq,
        .Colon,
        .Arrow,
        .Dot,
        .QuestionDot,
        => false,
        else => true,
    };
}

pub fn parseRange(p: *Parser) ?Expr {
    var lhs = parseAdditive(p) orelse return null;
    while (true) {
        support.skipSoftNl(p);
        const op: BinOp = switch (support.peekKind(p).*) {
            .DotDot => .Range,
            .DotDotLess => .RangeUntil,
            else => break,
        };
        _ = support.bump(p);
        support.skipNl(p);
        const rhs = parseAdditive(p) orelse return null;
        const sp = lhs.span().join(rhs.span());
        lhs = Expr{ .Binary = .{
            .op = op,
            .lhs = boxExpr(p, lhs),
            .rhs = boxExpr(p, rhs),
            .span = sp,
        } };
    }
    return lhs;
}

pub fn parseAdditive(p: *Parser) ?Expr {
    var lhs = parseMultiplicative(p) orelse return null;
    while (true) {
        support.skipSoftNl(p);
        const op: BinOp = switch (support.peekKind(p).*) {
            .Plus => .Add,
            .Minus => .Sub,
            else => break,
        };
        _ = support.bump(p);
        support.skipNl(p);
        const rhs = parseMultiplicative(p) orelse return null;
        const sp = lhs.span().join(rhs.span());
        lhs = Expr{ .Binary = .{
            .op = op,
            .lhs = boxExpr(p, lhs),
            .rhs = boxExpr(p, rhs),
            .span = sp,
        } };
    }
    return lhs;
}

pub fn parseMultiplicative(p: *Parser) ?Expr {
    var lhs = parseAs(p) orelse return null;
    while (true) {
        support.skipSoftNl(p);
        const op: BinOp = switch (support.peekKind(p).*) {
            .Star => .Mul,
            .Slash => .Div,
            .Percent => .Rem,
            else => break,
        };
        _ = support.bump(p);
        support.skipNl(p);
        const rhs = parseAs(p) orelse return null;
        const sp = lhs.span().join(rhs.span());
        lhs = Expr{ .Binary = .{
            .op = op,
            .lhs = boxExpr(p, lhs),
            .rhs = boxExpr(p, rhs),
            .span = sp,
        } };
    }
    return lhs;
}

/// Left-associative. The lexer emits `?` as `QuestNoWs` only next to `as`, so
/// the safe form needs that shape.
pub fn parseAs(p: *Parser) ?Expr {
    var lhs = parsePrefix(p) orelse return null;
    while (true) {
        // `as` cannot begin a statement, so a leading `as` on a continuation
        // line applies to the preceding expression.
        if (!peekIsAsAcrossNewlines(p)) break;
        support.skipNl(p);
        _ = support.bump(p); // `as`
        const safe = support.peekKind(p).isQuestion();
        if (safe) {
            _ = support.bump(p);
        }
        support.skipNl(p);
        const ty = parseQualifiedType(p) orelse break;
        const sp = lhs.span().join(ty.span);
        lhs = Expr{ .As = .{
            .expr = boxExpr(p, lhs),
            .ty = ty,
            .safe = safe,
            .span = sp,
        } };
    }
    return lhs;
}

pub fn parsePrefix(p: *Parser) ?Expr {
    const start = support.currentSpan(p);
    const op: ?UnOp = switch (support.peekKind(p).*) {
        .Minus => .Neg,
        .Plus => .Pos,
        .PlusPlus => .PreInc,
        .MinusMinus => .PreDec,
        else => |k| if (k.isBang()) UnOp.Not else null,
    };
    if (op) |o| {
        _ = support.bump(p);
        const e = parsePrefix(p) orelse return null;
        const sp = start.join(e.span());
        return Expr{ .Unary = .{
            .op = o,
            .expr = boxExpr(p, e),
            .span = sp,
        } };
    }
    // The lexer folds `!!` into one token for the postfix assertion, so in
    // prefix position it is two negations.
    if (std.meta.activeTag(support.peekKind(p).*) == .BangBang) {
        _ = support.bump(p);
        const e = parsePrefix(p) orelse return null;
        const inner_sp = start.join(e.span());
        const inner = Expr{ .Unary = .{ .op = .Not, .expr = boxExpr(p, e), .span = inner_sp } };
        return Expr{ .Unary = .{ .op = .Not, .expr = boxExpr(p, inner), .span = inner_sp } };
    }
    return parsePostfix(p);
}

pub fn parsePostfix(p: *Parser) ?Expr {
    const first = parsePrimary(p) orelse return null;
    return parsePostfixFrom(p, first);
}

/// The postfix tail applied to an already-parsed primary. A `{ ... }` value
/// argument arrives here as a lambda literal, so `f(b = { ... }())` invokes the
/// literal instead of ending the argument at its `}`.
/// What one postfix operator did to the chain: read another operator, end the
/// chain with what is built so far, or abandon the parse.
const Step = enum { advance, stop, fail };

/// The state every postfix operator reads and updates: the expression built so
/// far, and the call-site type arguments waiting for the next `Call`.
const PostfixChain = struct {
    p: *Parser,
    expr: Expr,
    pending_type_args: []TypeRef = &.{},

    /// The pending type arguments, cleared so a later call cannot reuse them.
    fn takeTypeArgs(chain: *PostfixChain) []TypeRef {
        const t = chain.pending_type_args;
        chain.pending_type_args = &.{};
        return t;
    }

    /// Fold `lam` into the receiver as its trailing-lambda argument.
    fn attachTrailingLambda(chain: *PostfixChain, lam: Expr, lam_span: Span) void {
        const sp = chain.expr.span().join(lam_span);
        const extra_type_args = chain.takeTypeArgs();
        chain.expr = appendTrailingLambda(chain.p, chain.expr, lam, extra_type_args, sp);
    }
};

pub fn parsePostfixFrom(p: *Parser, first: Expr) ?Expr {
    var chain: PostfixChain = .{ .p = p, .expr = first };
    while (true) {
        const step: Step = switch (support.peekKind(p).*) {
            .PlusPlus => postfixOperator(&chain, .Inc),
            .MinusMinus => postfixOperator(&chain, .Dec),
            .BangBang => postfixOperator(&chain, .NotNull),
            .Dot, .QuestionDot => memberOrParenthesizedCallee(&chain),
            .QuestNoWs, .QuestWs => nullableReceiverMark(&chain),
            .ColonColon => callableReference(&chain),
            .Lt => callTypeArguments(&chain),
            .LParen => callArguments(&chain),
            .LBracket => indexArguments(&chain),
            .Ident => labeledTrailingLambda(&chain),
            .AtNoWs, .AtPostWs, .AtPreWs, .AtBothWs => annotatedTrailingLambda(&chain),
            .LBrace => braceTrailingLambda(&chain),
            .Newline => chainContinuation(&chain),
            else => .stop,
        };
        switch (step) {
            .advance => {},
            .stop => break,
            .fail => return null,
        }
    }
    return chain.expr;
}

/// `x++`, `x--` and `x!!`.
fn postfixOperator(chain: *PostfixChain, op: PostfixOp) Step {
    const p = chain.p;
    const tok = support.bump(p);
    const sp = chain.expr.span().join(tok.span);
    chain.expr = Expr{ .Postfix = .{
        .op = op,
        .expr = boxExpr(p, chain.expr),
        .span = sp,
    } };
    return .advance;
}

/// `a.b` and `a?.b`, plus the parenthesized callee Kotlin defines as an
/// extension receiver: `a.(f)(args)` is `f(a, args)`.
fn memberOrParenthesizedCallee(chain: *PostfixChain) Step {
    const p = chain.p;
    const safe = std.meta.activeTag(support.peekKind(p).*) == .QuestionDot;
    _ = support.bump(p);
    support.skipNl(p);
    if (!safe and std.meta.activeTag(support.peekKind(p).*) == .LParen) {
        const callee = parsePrimary(p) orelse return .fail;
        support.skipNl(p);
        if (std.meta.activeTag(support.peekKind(p).*) != .LParen) {
            _ = support.expect(p, .LParen, "`(` (a parenthesized callee after `.` must be invoked)") orelse return .fail;
            return .fail;
        }
        _ = support.bump(p);
        var args: std.ArrayList(Expr) = .empty;
        var arg_names: std.ArrayList(?[]const u8) = .empty;
        args.append(p.allocator, chain.expr) catch @panic("OOM");
        arg_names.append(p.allocator, null) catch @panic("OOM");
        if (!parseCallArgs(p, &args, &arg_names)) return .fail;
        const rparen = support.expect(p, .RParen, "`)`") orelse return .fail;
        const sp = chain.expr.span().join(rparen.span);
        chain.expr = Expr{ .Call = .{
            .callee = boxExpr(p, callee),
            .args = args.toOwnedSlice(p.allocator) catch @panic("OOM"),
            .arg_names = arg_names.toOwnedSlice(p.allocator) catch @panic("OOM"),
            .type_args = &.{},
            .is_infix = false,
            .span = sp,
        } };
        return .advance;
    }
    const name = support.parseIdent(p, "member name") orelse return .stop;
    const sp = chain.expr.span().join(name.span);
    chain.expr = Expr{ .Member = .{
        .receiver = boxExpr(p, chain.expr),
        .name = name,
        .safe = safe,
        .span = sp,
    } };
    return .advance;
}

/// `Any?::toString`: the `?` makes the receiver type nullable without changing
/// member resolution, and is valid only before `::`.
fn nullableReceiverMark(chain: *PostfixChain) Step {
    const p = chain.p;
    const after = kindAt(p, p.pos + 1);
    if (after == null or std.meta.activeTag(after.?) != .ColonColon) return .stop;
    _ = support.bump(p);
    return .advance;
}

/// `a::b`, including the `::class` literal.
fn callableReference(chain: *PostfixChain) Step {
    const p = chain.p;
    _ = support.bump(p);
    support.skipNl(p);
    // The soft `class` keyword is accepted as the right-hand name.
    const name: Ident = if (std.meta.activeTag(support.peekKind(p).*) == .Keyword and
        support.peekKind(p).Keyword == .Class)
    blk: {
        const tok = support.bump(p);
        break :blk Ident{ .name = "class", .span = tok.span };
    } else (support.parseIdent(p, "callable reference name") orelse return .fail);
    if (std.mem.eql(u8, name.name, "class") and chain.pending_type_args.len != 0) {
        const args = chain.pending_type_args;
        const span_first = if (args.len > 0) args[0].span else name.span;
        const span_last = if (args.len > 0) args[args.len - 1].span else name.span;
        support.err(
            p,
            "T0104",
            "class literal does not take type arguments — type arguments are erased on `::class`.",
            span_first.join(span_last),
        );
    }
    chain.pending_type_args = &.{};
    const sp = chain.expr.span().join(name.span);
    chain.expr = Expr{ .MemberRef = .{
        .receiver = boxExpr(p, chain.expr),
        .name = name,
        .span = sp,
    } };
    return .advance;
}

/// `<` after a callee starts type arguments only when `trySkipGenericCallArgs`
/// finds a matching `>` followed by `(`/`{`/`.`/`?.`/`::`; otherwise it is a
/// binary operator and the chain ends here.
fn callTypeArguments(chain: *PostfixChain) Step {
    const p = chain.p;
    if (!trySkipGenericCallArgs(p)) return .stop;
    chain.pending_type_args = parseCallTypeArgs(p);
    skipNewlineBeforeTrailingLambda(p);
    return .advance;
}

/// `f(...)`, consuming any type arguments the chain is holding.
fn callArguments(chain: *PostfixChain) Step {
    const p = chain.p;
    _ = support.bump(p);
    var args: std.ArrayList(Expr) = .empty;
    var arg_names: std.ArrayList(?[]const u8) = .empty;
    if (!parseCallArgs(p, &args, &arg_names)) return .fail;
    const rparen = support.expect(p, .RParen, "`)`") orelse return .fail;
    const sp = chain.expr.span().join(rparen.span);
    const type_args = chain.takeTypeArgs();
    chain.expr = Expr{ .Call = .{
        .callee = boxExpr(p, chain.expr),
        .args = args.toOwnedSlice(p.allocator) catch @panic("OOM"),
        .arg_names = arg_names.toOwnedSlice(p.allocator) catch @panic("OOM"),
        .type_args = type_args,
        .is_infix = false,
        .span = sp,
    } };
    if (!p.suppress_trailing_lambda) skipNewlineBeforeTrailingLambda(p);
    return .advance;
}

/// `a[i]`, `a[i, j]`.
fn indexArguments(chain: *PostfixChain) Step {
    const p = chain.p;
    _ = support.bump(p);
    var args: std.ArrayList(Expr) = .empty;
    while (true) {
        support.skipNl(p);
        if (std.meta.activeTag(support.peekKind(p).*) == .RBracket) {
            break;
        }
        const arg = parseExpr(p) orelse return .fail;
        args.append(p.allocator, arg) catch @panic("OOM");
        support.skipNl(p);
        if (std.meta.activeTag(support.peekKind(p).*) == .Comma) {
            _ = support.bump(p);
        } else {
            break;
        }
    }
    const rbr = support.expect(p, .RBracket, "`]`") orelse return .fail;
    const sp = chain.expr.span().join(rbr.span);
    chain.expr = Expr{ .Index = .{
        .receiver = boxExpr(p, chain.expr),
        .args = args.toOwnedSlice(p.allocator) catch @panic("OOM"),
        .span = sp,
    } };
    return .advance;
}

/// `call lbl@ { ... }`: the label binds the lambda for `return@lbl`.
fn labeledTrailingLambda(chain: *PostfixChain) Step {
    const p = chain.p;
    if (p.suppress_trailing_lambda or !root.isTrailingLambdaCallable(&chain.expr)) {
        return .stop;
    }
    const at_next = kindAt(p, p.pos + 1);
    const at_ok = at_next != null and switch (at_next.?) {
        .AtNoWs, .AtPostWs => true,
        else => false,
    };
    const brace_next = kindAt(p, p.pos + 2);
    const brace_ok = brace_next != null and std.meta.activeTag(brace_next.?) == .LBrace;
    if (!(at_ok and brace_ok)) {
        return .stop;
    }
    const name_span = support.currentSpan(p);
    const label = Ident{
        .name = support.identName(p, name_span),
        .span = name_span,
    };
    _ = support.bump(p); // label ident
    _ = support.bump(p); // `@`
    const lam = parseTrailingLambda(p) orelse return .fail;
    const lspan = label.span.join(lam.span());
    const labeled = Expr{ .Labeled = .{
        .label = label,
        .expr = boxExpr(p, lam),
        .span = lspan,
    } };
    chain.attachTrailingLambda(labeled, lspan);
    return .advance;
}

/// `call @Ann { ... }`.
fn annotatedTrailingLambda(chain: *PostfixChain) Step {
    const p = chain.p;
    if (p.suppress_trailing_lambda or !root.isTrailingLambdaCallable(&chain.expr)) {
        return .stop;
    }
    const past = skipAnnotationTokens(p, p.pos);
    const after = kindAt(p, past);
    if (after == null or std.meta.activeTag(after.?) != .LBrace) {
        return .stop;
    }
    _ = parseAnnotations(p);
    support.skipNl(p);
    const lam = parseTrailingLambda(p) orelse return .fail;
    chain.attachTrailingLambda(lam, lam.span());
    return .advance;
}

/// `call { ... }`.
fn braceTrailingLambda(chain: *PostfixChain) Step {
    const p = chain.p;
    if (!root.isTrailingLambdaCallable(&chain.expr) or p.suppress_trailing_lambda) {
        return .stop;
    }
    const lam = parseTrailingLambda(p) orelse return .fail;
    chain.attachTrailingLambda(lam, lam.span());
    return .advance;
}

/// Kotlin continues a postfix chain across a newline when the next line starts
/// with `.`, `?.`, `!!` or `[`.
fn chainContinuation(chain: *PostfixChain) Step {
    const p = chain.p;
    if (!nextNonNewlineIsChainContinuation(p)) return .stop;
    support.skipNl(p);
    return .advance;
}

/// Value arguments up to the closing `)`, which is left unconsumed. False when
/// an argument failed to parse.
fn parseCallArgs(p: *Parser, args: *std.ArrayList(Expr), arg_names: *std.ArrayList(?[]const u8)) bool {
    while (true) {
        support.skipNl(p);
        if (std.meta.activeTag(support.peekKind(p).*) == .RParen) break;
        const name = tryConsumeNamedArgName(p);
        const arg = parseValueArgument(p) orelse return false;
        args.append(p.allocator, arg) catch @panic("OOM");
        arg_names.append(p.allocator, name) catch @panic("OOM");
        support.skipNl(p);
        if (std.meta.activeTag(support.peekKind(p).*) == .Comma) {
            _ = support.bump(p);
        } else break;
    }
    return true;
}

/// A trailing lambda may start on the next line; consume the break so the chain
/// reaches the `{`.
fn skipNewlineBeforeTrailingLambda(p: *Parser) void {
    if (std.meta.activeTag(support.peekKind(p).*) != .Newline) return;
    const save = p.pos;
    support.skipNl(p);
    if (std.meta.activeTag(support.peekKind(p).*) != .LBrace) p.pos = save;
}

/// Attach `lam` as the trailing-lambda argument, folding into an ungrouped
/// `Call` so `f(a) { ... }` stays one call. A grouped `(factory()) { ... }` is
/// wrapped instead, since the lambda invokes its result.
fn appendTrailingLambda(
    p: *Parser,
    expr: Expr,
    lam: Expr,
    extra_type_args: []TypeRef,
    sp: Span,
) Expr {
    switch (expr) {
        .Call => |c| {
            if (!c.grouped) {
                var args: std.ArrayList(Expr) = .empty;
                args.appendSlice(p.allocator, c.args) catch @panic("OOM");
                args.append(p.allocator, lam) catch @panic("OOM");
                var arg_names: std.ArrayList(?[]const u8) = .empty;
                arg_names.appendSlice(p.allocator, c.arg_names) catch @panic("OOM");
                arg_names.append(p.allocator, null) catch @panic("OOM");
                const type_args = if (c.type_args.len == 0) extra_type_args else c.type_args;
                return Expr{ .Call = .{
                    .callee = c.callee,
                    .args = args.toOwnedSlice(p.allocator) catch @panic("OOM"),
                    .arg_names = arg_names.toOwnedSlice(p.allocator) catch @panic("OOM"),
                    .type_args = type_args,
                    .is_infix = c.is_infix,
                    .has_trailing_lambda = true,
                    .span = sp,
                } };
            }
        },
        else => {},
    }
    const args = p.allocator.alloc(Expr, 1) catch @panic("OOM");
    args[0] = lam;
    const arg_names = p.allocator.alloc(?[]const u8, 1) catch @panic("OOM");
    arg_names[0] = null;
    return Expr{ .Call = .{
        .callee = boxExpr(p, expr),
        .args = args,
        .arg_names = arg_names,
        .type_args = extra_type_args,
        .is_infix = false,
        .has_trailing_lambda = true,
        .span = sp,
    } };
}

/// A leading `*` is the spread marker; everything else goes to the regular expression parser.
pub fn parseValueArgument(p: *Parser) ?Expr {
    if (std.meta.activeTag(support.peekKind(p).*) == .Star) {
        const star = support.bump(p);
        support.skipNl(p);
        const e = parseExpr(p) orelse return null;
        support.rejectTrailingAssignment(p);
        const sp = star.span.join(e.span());
        return Expr{ .Spread = .{
            .expr = boxExpr(p, e),
            .span = sp,
        } };
    }
    // A `{ ... }` value argument is always a lambda literal, implicit `it` and all.
    if (std.meta.activeTag(support.peekKind(p).*) == .LBrace) {
        const lam = parseLambdaLiteral(p) orelse return null;
        const e = parsePostfixFrom(p, lam) orelse return null;
        support.rejectTrailingAssignment(p);
        return e;
    }
    const e = parseExpr(p) orelse return null;
    support.rejectTrailingAssignment(p);
    return e;
}

/// Consume `Ident =` and return the identifier: a named argument's label, used
/// to reorder against the parameter list.
pub fn tryConsumeNamedArgName(p: *Parser) ?[]const u8 {
    if (std.meta.activeTag(support.peekKind(p).*) != .Ident) {
        return null;
    }
    const next = kindAt(p, p.pos + 1);
    if (!(next != null and std.meta.activeTag(next.?) == .Eq)) {
        return null;
    }
    const tok = support.bump(p); // ident
    const name = support.identName(p, tok.span);
    _ = support.bump(p); // `=`
    support.skipNl(p);
    return name;
}

fn peekIsAsAcrossNewlines(p: *const Parser) bool {
    var i = p.pos;
    while (kindAt(p, i)) |k| {
        if (std.meta.activeTag(k) != .Newline) break;
        i += 1;
    }
    const next = kindAt(p, i) orelse return false;
    return std.meta.activeTag(next) == .Keyword and next.Keyword == .As;
}

pub fn nextNonNewlineIsChainContinuation(p: *const Parser) bool {
    var i = p.pos;
    while (kindAt(p, i)) |k| {
        if (std.meta.activeTag(k) != .Newline) break;
        i += 1;
    }
    const next = kindAt(p, i);
    if (next == null) return false;
    return switch (next.?) {
        .Dot, .QuestionDot, .BangBang, .LBracket => true,
        else => false,
    };
}
