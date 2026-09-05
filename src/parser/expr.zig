//! Pratt expression parser (precedence climbing) and operator handling.
//!
//! Free functions over `*Parser`; the entry point is `expr.parseExpr(p)`,
//! returning `?Expr`.

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

/// Box an expression onto the parser arena.
fn boxExpr(p: *Parser, e: Expr) *Expr {
    const ptr = p.allocator.create(Expr) catch @panic("OOM boxing expr");
    ptr.* = e;
    return ptr;
}

/// The token kind `i` positions ahead of the cursor, or `null` past the
/// end. Mirrors `self.tokens.get(self.pos + n).map(|t| &t.kind)`.
fn kindAt(p: *const Parser, i: usize) ?TokenKind {
    if (i >= p.tokens.len) return null;
    return p.tokens[i].kind;
}

/// Look ahead from index `i`, which must sit on an `@`, and skip one or more
/// annotation forms (`@Foo`, `@Foo(...)`, `@Foo.Bar`, `@[Foo Bar]`), returning
/// the index of the first token past them. Used to detect an annotation that
/// prefixes a trailing lambda (`run @Suppress("x") { … }`).
fn skipAnnotationTokens(p: *const Parser, i: usize) usize {
    var j = i;
    while (j < p.tokens.len and p.tokens[j].kind.isAt()) {
        j += 1;
        // `@[Foo Bar]` bracketed form: skip to matching `]`.
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
            // `Foo`, dotted `Foo.Bar`, then optional `(...)` arg list.
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

// ---- cross-module helpers (resolved against sibling modules once filled in) ----
//
// These functions live in sibling parse files (`types`, `file`, `control`,
// `primary`). Until those modules are filled they are gated through
// `@hasDecl` so this module still compiles; the gate vanishes once the real
// implementations land and the calls dispatch straight to them.

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

/// Consume and discard a leading expression annotation, if present.
/// Kotlin allows annotations to prefix an expression
/// (`@Suppress("UNCHECKED_CAST") (x as T)`, as in the stdlib's
/// `Comparator.reversed()` when-branches); they are runtime no-ops.
/// Applied only at control-structure-body / when-branch position so
/// it never shadows the label / `this@` / `return@` uses of `@` that
/// the unary and primary layers parse.
pub fn skipLeadingExprAnnotation(p: *Parser) void {
    if (atExpressionAnnotation(p)) {
        _ = parseAnnotations(p);
        support.skipNl(p);
    }
}

/// True when the cursor is at an annotation that prefixes an
/// expression — `@Foo`, `@Foo(...)`, `@[Foo Bar]` — as opposed to a
/// label (`loop@`), where the `@` follows an identifier and so is not
/// in leading position.
pub fn atExpressionAnnotation(p: *const Parser) bool {
    if (!support.peekKind(p).isAt()) return false;
    return switch (kindAt(p, p.pos + 1) orelse return false) {
        .Ident, .LBracket => true,
        else => false,
    };
}

/// Parse a function expression body (`fun f() = <expr>`). Kotlin
/// allows annotations on the body expression itself
/// (`= @Suppress("UNCHECKED_CAST") if (…) this as E else null`,
/// as in the stdlib `CoroutineContext.Element.get`). Annotations
/// are runtime no-ops here; consume and discard them before the
/// expression.
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
        // A wrapped line may begin with `||`; it cannot start a
        // statement, so this is an unambiguous continuation.
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
        // A wrapped line may begin with `&&` (an unambiguous
        // continuation — it cannot start a statement).
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
        // `in` / `!in` live at the comparison precedence level. `!in` is
        // the two tokens `!` then `in`. Recognized only when not followed
        // by a type — `!is` is handled inside parseNamedChecks.
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

/// `expr is Type` and `expr !is Type`. Lower precedence than comparison,
/// higher than elvis. `is` is a hard keyword in the lexer; `!is` is the
/// two tokens `!` and `is`.
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
        // A line beginning with `?:` continues the expression (Kotlin
        // allows the elvis operator to lead a wrapped line); `?:` can
        // never start a statement, so this is unambiguous.
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

/// Infix function calls: `lhs <name> rhs` where `<name>` is any bare
/// identifier resolvable to a function declared with the `infix`
/// modifier. Desugars to `Call(Path[name], [lhs, rhs])`. Whether the
/// resolved function actually carries `infix` is enforced later by the
/// type checker (diagnostic T0029).
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

/// After tentatively reading an infix-candidate identifier, peek
/// ahead to confirm an expression continues. A Newline normally
/// ends the statement, but inside `(`/`[` (soft newlines) the
/// right operand may legally start on the following line, so we
/// look past soft newlines there.
pub fn lookaheadInfixRhsStarter(p: *const Parser) bool {
    // We have already read a valid infix-function name on this line; it
    // demands a right operand, so a following newline is a continuation
    // (`(a) or\n (b)`), not a statement boundary — look past it regardless
    // of bracket nesting.
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

/// `expr as Type` / `expr as? Type`, left-associative. The lexer emits
/// `?` as `QuestNoWs` only when adjacent to `as`, so we accept that
/// exact shape for the safe form.
pub fn parseAs(p: *Parser) ?Expr {
    var lhs = parsePrefix(p) orelse return null;
    while (true) {
        // `as` / `as?` is an infix operator that can never begin a
        // statement, so a leading `as` on a continuation line always
        // applies to the preceding expression. Look past newlines for it.
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
    return parsePostfix(p);
}

// Single match-dispatch loop over postfix tokens; splitting would fragment it.
pub fn parsePostfix(p: *Parser) ?Expr {
    const first = parsePrimary(p) orelse return null;
    return parsePostfixFrom(p, first);
}

/// The postfix tail (`++`, `!!`, calls, indexing, member access, trailing
/// lambdas) applied to an already-parsed primary. A `{ … }` value argument
/// is parsed as a lambda literal directly and comes through here so that
/// `f(b = { … }())` invokes the literal instead of ending the argument at
/// its `}`.
pub fn parsePostfixFrom(p: *Parser, first: Expr) ?Expr {
    var expr = first;
    // Generic type args at a call site (`foo<String>(…)`) are captured here
    // and attached to the next `Call` constructed in this loop.
    var pending_type_args: []TypeRef = &.{};
    loop: while (true) {
        switch (support.peekKind(p).*) {
            .PlusPlus => {
                const tok = support.bump(p);
                const sp = expr.span().join(tok.span);
                expr = Expr{ .Postfix = .{
                    .op = .Inc,
                    .expr = boxExpr(p, expr),
                    .span = sp,
                } };
            },
            .MinusMinus => {
                const tok = support.bump(p);
                const sp = expr.span().join(tok.span);
                expr = Expr{ .Postfix = .{
                    .op = .Dec,
                    .expr = boxExpr(p, expr),
                    .span = sp,
                } };
            },
            .BangBang => {
                const tok = support.bump(p);
                const sp = expr.span().join(tok.span);
                expr = Expr{ .Postfix = .{
                    .op = .NotNull,
                    .expr = boxExpr(p, expr),
                    .span = sp,
                } };
            },
            .Dot, .QuestionDot => {
                const safe = std.meta.activeTag(support.peekKind(p).*) == .QuestionDot;
                _ = support.bump(p);
                support.skipNl(p);
                const name = support.parseIdent(p, "member name") orelse return expr;
                const sp = expr.span().join(name.span);
                expr = Expr{ .Member = .{
                    .receiver = boxExpr(p, expr),
                    .name = name,
                    .safe = safe,
                    .span = sp,
                } };
            },
            .QuestNoWs, .QuestWs => {
                // Nullable-receiver callable reference: `Any?::toString`,
                // `ByteArray?::contentEquals`, `Array<*>?::contentToString`.
                // The `?` makes the reference's receiver type nullable, which
                // does not change member resolution; consume it and let the
                // `::` branch build the reference. Only valid immediately
                // before `::` — otherwise the chain ends here.
                const after = kindAt(p, p.pos + 1);
                if (after == null or std.meta.activeTag(after.?) != .ColonColon) break;
                _ = support.bump(p);
            },
            .ColonColon => {
                _ = support.bump(p);
                support.skipNl(p);
                // `Foo::class` — class literal. Accept the soft `class`
                // keyword as the right-hand name; otherwise expect an
                // identifier (member name).
                const name: Ident = if (std.meta.activeTag(support.peekKind(p).*) == .Keyword and
                    support.peekKind(p).Keyword == .Class)
                blk: {
                    const tok = support.bump(p);
                    break :blk Ident{ .name = "class", .span = tok.span };
                } else (support.parseIdent(p, "callable reference name") orelse return null);
                if (std.mem.eql(u8, name.name, "class") and pending_type_args.len != 0) {
                    // Class literals erase their type arguments, so writing
                    // them is rejected.
                    const span_first = if (pending_type_args.len > 0) pending_type_args[0].span else name.span;
                    const span_last = if (pending_type_args.len > 0) pending_type_args[pending_type_args.len - 1].span else name.span;
                    support.err(
                        p,
                        "T0104",
                        "class literal does not take type arguments — type arguments are erased on `::class`.",
                        span_first.join(span_last),
                    );
                }
                pending_type_args = &.{};
                const sp = expr.span().join(name.span);
                expr = Expr{ .MemberRef = .{
                    .receiver = boxExpr(p, expr),
                    .name = name,
                    .span = sp,
                } };
            },
            .Lt => {
                // Generic call type args like `ArrayList<Int>()` or
                // `compareBy<String> { … }`. We disambiguate against
                // less-than via `trySkipGenericCallArgs` (look-ahead for a
                // matching `>` followed by `(`/`{`/`.`/`?.`/`::`); if it
                // doesn't look like a generic-call form, we treat `<` as a
                // binary operator and break out of the postfix loop.
                // Otherwise we parse the type args for real and hold them
                // for the next `Call`.
                if (trySkipGenericCallArgs(p)) {
                    pending_type_args = parseCallTypeArgs(p);
                    // The trailing lambda may start on the next line
                    // (`x.aggregate<K, V, R>\n{ … }`); consume the break so
                    // the postfix loop reaches the `{`.
                    if (std.meta.activeTag(support.peekKind(p).*) == .Newline) {
                        const save = p.pos;
                        support.skipNl(p);
                        if (std.meta.activeTag(support.peekKind(p).*) != .LBrace) p.pos = save;
                    }
                    continue;
                }
                break;
            },
            .LParen => {
                _ = support.bump(p);
                var args: std.ArrayList(Expr) = .empty;
                var arg_names: std.ArrayList(?[]const u8) = .empty;
                while (true) {
                    support.skipNl(p);
                    if (std.meta.activeTag(support.peekKind(p).*) == .RParen) {
                        break;
                    }
                    // Capture `name` part of `name = expr` for reorder.
                    const name = tryConsumeNamedArgName(p);
                    const arg = parseValueArgument(p) orelse return null;
                    args.append(p.allocator, arg) catch @panic("OOM");
                    arg_names.append(p.allocator, name) catch @panic("OOM");
                    support.skipNl(p);
                    if (std.meta.activeTag(support.peekKind(p).*) == .Comma) {
                        _ = support.bump(p);
                    } else {
                        break;
                    }
                }
                const rparen = support.expect(p, .RParen, "`)`") orelse return null;
                const sp = expr.span().join(rparen.span);
                const type_args = pending_type_args;
                pending_type_args = &.{};
                expr = Expr{ .Call = .{
                    .callee = boxExpr(p, expr),
                    .args = args.toOwnedSlice(p.allocator) catch @panic("OOM"),
                    .arg_names = arg_names.toOwnedSlice(p.allocator) catch @panic("OOM"),
                    .type_args = type_args,
                    .is_infix = false,
                    .span = sp,
                } };
                // A trailing lambda may start on the next line
                // (`assertFailsWith("x")\n{ ... }`): Kotlin's call suffix
                // allows line breaks before the lambda literal. Consume the
                // break so the postfix loop reaches the `{`.
                if (!p.suppress_trailing_lambda and std.meta.activeTag(support.peekKind(p).*) == .Newline) {
                    const save = p.pos;
                    support.skipNl(p);
                    if (std.meta.activeTag(support.peekKind(p).*) != .LBrace) p.pos = save;
                }
            },
            .LBracket => {
                _ = support.bump(p);
                var args: std.ArrayList(Expr) = .empty;
                while (true) {
                    support.skipNl(p);
                    if (std.meta.activeTag(support.peekKind(p).*) == .RBracket) {
                        break;
                    }
                    const arg = parseExpr(p) orelse return null;
                    args.append(p.allocator, arg) catch @panic("OOM");
                    support.skipNl(p);
                    if (std.meta.activeTag(support.peekKind(p).*) == .Comma) {
                        _ = support.bump(p);
                    } else {
                        break;
                    }
                }
                const rbr = support.expect(p, .RBracket, "`]`") orelse return null;
                const sp = expr.span().join(rbr.span);
                expr = Expr{ .Index = .{
                    .receiver = boxExpr(p, expr),
                    .args = args.toOwnedSlice(p.allocator) catch @panic("OOM"),
                    .span = sp,
                } };
            },
            // Labeled trailing lambda: `call lbl@ { ... }`. The label binds
            // the lambda (for `return@lbl`); upstream kotlinx-coroutines uses
            // this pervasively (`suspendCoroutineUninterceptedOrReturn sc@ {
            // ... }`).
            .Ident => {
                if (p.suppress_trailing_lambda or !root.isTrailingLambdaCallable(&expr)) {
                    break;
                }
                const at_next = kindAt(p, p.pos + 1);
                const at_ok = at_next != null and switch (at_next.?) {
                    .AtNoWs, .AtPostWs => true,
                    else => false,
                };
                const brace_next = kindAt(p, p.pos + 2);
                const brace_ok = brace_next != null and std.meta.activeTag(brace_next.?) == .LBrace;
                if (!(at_ok and brace_ok)) {
                    break;
                }
                const name_span = support.currentSpan(p);
                const label = Ident{
                    .name = support.identName(p, name_span),
                    .span = name_span,
                };
                _ = support.bump(p); // label ident
                _ = support.bump(p); // `@`
                const lam = parseTrailingLambda(p) orelse return null;
                const lspan = label.span.join(lam.span());
                const labeled = Expr{ .Labeled = .{
                    .label = label,
                    .expr = boxExpr(p, lam),
                    .span = lspan,
                } };
                const sp = expr.span().join(lspan);
                const extra_type_args = pending_type_args;
                pending_type_args = &.{};
                expr = appendTrailingLambda(p, expr, labeled, extra_type_args, sp);
            },
            // Annotated trailing lambda: `run @Suppress("x") { … }`. The
            // annotation prefixes the lambda argument; it is a runtime no-op
            // here, so consume and discard it, then parse the trailing lambda.
            .AtNoWs, .AtPostWs, .AtPreWs, .AtBothWs => {
                if (p.suppress_trailing_lambda or !root.isTrailingLambdaCallable(&expr)) {
                    break;
                }
                const past = skipAnnotationTokens(p, p.pos);
                const after = kindAt(p, past);
                if (after == null or std.meta.activeTag(after.?) != .LBrace) {
                    break;
                }
                _ = parseAnnotations(p);
                support.skipNl(p);
                const lam = parseTrailingLambda(p) orelse return null;
                const sp = expr.span().join(lam.span());
                const extra_type_args = pending_type_args;
                pending_type_args = &.{};
                expr = appendTrailingLambda(p, expr, lam, extra_type_args, sp);
            },
            .LBrace => {
                if (!root.isTrailingLambdaCallable(&expr) or p.suppress_trailing_lambda) {
                    break;
                }
                const lam = parseTrailingLambda(p) orelse return null;
                const sp = expr.span().join(lam.span());
                const extra_type_args = pending_type_args;
                pending_type_args = &.{};
                expr = appendTrailingLambda(p, expr, lam, extra_type_args, sp);
            },
            .Newline => {
                // Kotlin allows a postfix chain to continue across a newline
                // if the first non-whitespace on the next line is `.`, `?.`,
                // `!!`, or `[`. Peek past newlines; if we land on one of those
                // continuation tokens, swallow the newlines and keep going.
                // Otherwise the chain ends here.
                if (nextNonNewlineIsChainContinuation(p)) {
                    support.skipNl(p);
                    continue :loop;
                }
                break;
            },
            else => break,
        }
    }
    return expr;
}

/// Attach `lam` as the trailing-lambda argument of `expr`, folding into an
/// ungrouped `Call` so `f(a) { … }` stays a single call. A grouped call such
/// as `(factory()) { … }` is wrapped because the lambda invokes its result.
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

/// Parse a single value-argument at a call site. Accepts a leading `*` as
/// a spread marker (`foo(*arr)`); otherwise delegates to the regular
/// expression parser.
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
    // A `{ ... }` value-argument is always a lambda literal, even without an
    // explicit `->` header (binds an implicit `it`).
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

/// If the next two tokens are `Ident =`, consume both and return the
/// identifier text — the label of a named argument that callers can use for
/// reorder dispatch against a callable's parameter list.
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

/// Peek forward past any number of `Newline` tokens. Returns `true` when
/// the next non-newline token is the `as` keyword (the start of an
/// `as`/`as?` cast).
fn peekIsAsAcrossNewlines(p: *const Parser) bool {
    var i = p.pos;
    while (kindAt(p, i)) |k| {
        if (std.meta.activeTag(k) != .Newline) break;
        i += 1;
    }
    const next = kindAt(p, i) orelse return false;
    return std.meta.activeTag(next) == .Keyword and next.Keyword == .As;
}

/// Peek forward past any number of `Newline` tokens. Returns `true` when
/// the next non-newline token is one of the postfix-chain continuation
/// starters.
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
