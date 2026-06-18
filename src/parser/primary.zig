//! Primary-expression parsing: literals, paths, parenthesized
//! expressions, lambdas, string templates, `this`/`super`, callable and
//! member references, object/anonymous-function expressions.
//!
//! Ported from `parse/primary.rs`. Free functions over `*Parser`.

const std = @import("std");

const ast = @import("ast");
const lexer = @import("lexer");
const span = @import("span");

const root = @import("parser.zig");
const support = @import("support.zig");
const exprmod = @import("expr.zig");
const control = @import("control.zig");
const members = @import("members.zig");
const class = @import("class.zig");
const types = @import("types.zig");

const Parser = root.Parser;
const Expr = ast.Expr;
const Ident = ast.Ident;
const StringPart = ast.StringPart;
const Keyword = lexer.Keyword;
const TokenKind = lexer.TokenKind;
const NumBase = lexer.NumBase;
const IntSuffix = lexer.IntSuffix;

/// Allocate an `Expr` on the parser arena and return a pointer to it.
fn box(p: *Parser, e: Expr) *Expr {
    const ptr = p.allocator.create(Expr) catch @panic("OOM in primary");
    ptr.* = e;
    return ptr;
}

pub fn parsePrimary(p: *Parser) ?Expr {
    support.skipNl(p);
    const kind = support.peekKind(p).*;
    switch (kind) {
        .IntLiteral => |lit| return parseIntLiteral(p, lit.base, lit.suffix),
        .FloatLiteral => return parseFloatLiteral(p),
        .BoolLiteral => |v| {
            const tok = support.bump(p);
            return Expr{ .BoolLit = .{ .value = v, .span = tok.span } };
        },
        .NullLiteral => {
            const tok = support.bump(p);
            return Expr{ .NullLit = .{ .span = tok.span } };
        },
        .CharLiteral => |c| {
            const tok = support.bump(p);
            return Expr{ .CharLit = .{ .value = c, .span = tok.span } };
        },
        // Collection-literal `[a, b, ...]`. Kotlin permits this
        // only as an annotation argument
        // (`@Foo(imports = ["a", "b"])`); klio accepts it as a
        // `listOf(...)` expression — annotation arguments are
        // runtime-inert, so the representation only needs to
        // parse and carry the elements.
        .LBracket => {
            const lb = support.bump(p);
            support.skipNl(p);
            var elems: std.ArrayList(Expr) = .empty;
            while (true) {
                switch (support.peekKind(p).*) {
                    .RBracket, .Eof => break,
                    else => {},
                }
                const e = exprmod.parseExpr(p) orelse break;
                elems.append(p.allocator, e) catch @panic("OOM in primary");
                support.skipNl(p);
                if (std.meta.activeTag(support.peekKind(p).*) == .Comma) {
                    _ = support.bump(p);
                    support.skipNl(p);
                } else {
                    break;
                }
            }
            const rb = support.expect(p, .RBracket, "`]`") orelse return null;
            const sp = lb.span.join(rb.span);
            const n = elems.items.len;
            const seg = p.allocator.alloc(Ident, 1) catch @panic("OOM in primary");
            seg[0] = Ident{ .name = "listOf", .span = lb.span };
            const callee = box(p, Expr{ .Path = .{ .segments = seg, .span = lb.span } });
            const arg_names = p.allocator.alloc(?[]const u8, n) catch @panic("OOM in primary");
            for (arg_names) |*an| an.* = null;
            return Expr{ .Call = .{
                .callee = callee,
                .args = elems.toOwnedSlice(p.allocator) catch @panic("OOM in primary"),
                .arg_names = arg_names,
                .type_args = &.{},
                .is_infix = false,
                .span = sp,
            } };
        },
        .StringQuote => return parseStringTemplate(p),
        .Ident => {
            if (control.tryParseLabelBinding(p)) |label_expr| {
                return label_expr;
            }
            const tok = support.bump(p);
            const ident = Ident{
                .name = support.identName(p, tok.span),
                .span = tok.span,
            };
            const seg = p.allocator.alloc(Ident, 1) catch @panic("OOM in primary");
            seg[0] = ident;
            return Expr{ .Path = .{ .segments = seg, .span = tok.span } };
        },
        .LParen => {
            _ = support.bump(p);
            support.skipNl(p);
            const inner = exprmod.parseExpr(p) orelse return null;
            support.skipNl(p);
            support.rejectTrailingAssignment(p);
            support.skipNl(p);
            _ = support.expect(p, .RParen, "`)`") orelse return null;
            return inner;
        },
        .LBrace => {
            // A brace in expression position is always a function
            // literal in Kotlin (there is no block-expression);
            // `{ it + 1 }` assigned to a function-typed val is a
            // lambda, not a block. `parseLambdaLiteral` handles
            // the no-`->` (implicit `it` / zero-arg) form.
            return control.parseLambdaLiteral(p);
        },
        .Keyword => |kw| switch (kw) {
            .Fun => return members.parseAnonFun(p),
            .If => return control.parseIf(p),
            .While => return control.parseWhile(p),
            .Do => return control.parseDoWhile(p),
            .For => return control.parseFor(p),
            .Return => return control.parseReturn(p),
            .Throw => return control.parseThrow(p),
            .Try => return control.parseTry(p),
            .When => return control.parseWhen(p),
            .This => {
                const tok = support.bump(p);
                var qualifier: ?Ident = null;
                var end = tok.span;
                if (support.peekKind(p).isAt()) {
                    _ = support.bump(p);
                    if (support.parseIdent(p, "`this@` label")) |nm| {
                        end = nm.span;
                        qualifier = nm;
                    }
                }
                return Expr{ .This = .{
                    .qualifier = qualifier,
                    .span = tok.span.join(end),
                } };
            },
            .Object => {
                // Anonymous object expression: `object { … }` or
                // `object : Super(args), Iface { … }`. A named `object Foo`
                // is a declaration, not an expression; the statement-level
                // parser handles that form before reaching here.
                const kw_tok = support.bump(p);
                const st = class.parseOptionalSupertypesFull(p);
                const body = class.parseClassBody(p);
                const end = p.tokens[p.pos -| 1].span;
                return Expr{ .ObjectExpr = .{
                    .supertypes = st.types,
                    .supertype_args = st.args,
                    .supertype_delegates = st.delegates,
                    .members = body.members,
                    .init_blocks = body.init_blocks,
                    .init_block_positions = body.init_block_positions,
                    .span = kw_tok.span.join(end),
                } };
            },
            .Super => {
                const tok = support.bump(p);
                var qualifier: ?ast.TypeRef = null;
                if (std.meta.activeTag(support.peekKind(p).*) == .Lt) {
                    _ = support.bump(p);
                    qualifier = types.parseType(p);
                    if (std.meta.activeTag(support.peekKind(p).*) == .Gt) {
                        _ = support.bump(p);
                    }
                }
                const label = control.consumeJumpLabel(p);
                var end = tok.span;
                if (qualifier) |q| {
                    end = end.join(q.span);
                }
                if (label) |l| {
                    end = end.join(l.span);
                }
                return Expr{ .Super = .{
                    .qualifier = qualifier,
                    .label = label,
                    .span = tok.span.join(end),
                } };
            },
            .Break => {
                const tok = support.bump(p);
                const label = control.consumeJumpLabel(p);
                const sp = if (label) |l| tok.span.join(l.span) else tok.span;
                return Expr{ .Break = .{ .label = label, .span = sp } };
            },
            .Continue => {
                const tok = support.bump(p);
                const label = control.consumeJumpLabel(p);
                const sp = if (label) |l| tok.span.join(l.span) else tok.span;
                return Expr{ .Continue = .{ .label = label, .span = sp } };
            },
            else => {
                const sp = support.currentSpan(p);
                support.err(p, "E0011", "expected expression", sp);
                return null;
            },
        },
        .ColonColon => {
            const start = support.bump(p).span;
            const name = support.parseIdent(p, "property/function reference name") orelse return null;
            const sp = start.join(name.span);
            return Expr{ .PropertyRef = .{ .name = name, .span = sp } };
        },
        else => {
            const sp = support.currentSpan(p);
            support.err(p, "E0011", "expected expression", sp);
            return null;
        },
    }
}

pub fn parseIntLiteral(p: *Parser, base: NumBase, suffix: IntSuffix) Expr {
    const tok = support.bump(p);
    const raw_text = support.text(p, tok.span);
    var digits: []const u8 = undefined;
    var radix: u8 = undefined;
    switch (base) {
        .Decimal => {
            digits = trimEndAny(raw_text, "LuU");
            radix = 10;
        },
        .Hex => {
            const stripped = trimStartPrefix(trimStartPrefix(raw_text, "0x"), "0X");
            digits = trimEndAny(stripped, "LuU");
            radix = 16;
        },
        .Binary => {
            const stripped = trimStartPrefix(trimStartPrefix(raw_text, "0b"), "0B");
            digits = trimEndAny(stripped, "LuU");
            radix = 2;
        },
    }
    const cleaned = filterOut(p, digits, '_');
    const value: i64 = parseI64Radix(cleaned, radix) orelse blk: {
        support.err(p, "E0010", "integer literal out of range", tok.span);
        break :blk 0;
    };
    const kind: ast.IntLitKind = switch (suffix) {
        .Long => .Long,
        .UInt => .UInt,
        .ULong => .ULong,
        .None => .Int,
    };
    return Expr{ .IntLit = .{ .value = value, .kind = kind, .span = tok.span } };
}

pub fn parseFloatLiteral(p: *Parser) Expr {
    const tok = support.bump(p);
    const raw_text = support.text(p, tok.span);
    const has_f_suffix = raw_text.len > 0 and
        (raw_text[raw_text.len - 1] == 'f' or raw_text[raw_text.len - 1] == 'F');
    const cleaned = filterOutChars(p, raw_text, "_fF");
    const sp = tok.span;
    const value: f64 = std.fmt.parseFloat(f64, cleaned) catch blk: {
        support.err(p, "E0012", "invalid float literal", sp);
        break :blk 0.0;
    };
    const kind: ast.FloatLitKind = if (has_f_suffix) .Float else .Double;
    return Expr{ .FloatLit = .{ .value = value, .kind = kind, .span = tok.span } };
}

pub fn parseStringTemplate(p: *Parser) ?Expr {
    const open = support.bump(p); // StringQuote
    const triple = switch (open.kind) {
        .StringQuote => |sq| sq.triple,
        else => false,
    };
    var parts: std.ArrayList(StringPart) = .empty;
    while (true) {
        const kind = support.peekKind(p).*;
        switch (kind) {
            .StringQuote => |sq| {
                if (sq.triple == triple) {
                    const close = support.bump(p);
                    return Expr{ .StringTemplate = .{
                        .parts = parts.toOwnedSlice(p.allocator) catch @panic("OOM in primary"),
                        .span = open.span.join(close.span),
                    } };
                } else {
                    const sp = support.currentSpan(p);
                    support.err(p, "E0014", "unexpected token inside string template", sp);
                    _ = support.bump(p);
                }
            },
            .StringText => |s| {
                _ = support.bump(p);
                // Own the text in the AST allocator: the lexer's StringText is an
                // owned token buffer that callers free after parsing, so borrowing
                // it would dangle once tokens are released (before lowering).
                const owned = p.allocator.dupe(u8, s) catch @panic("OOM in primary");
                parts.append(p.allocator, StringPart{ .Text = owned }) catch @panic("OOM in primary");
            },
            .ShortInterp => |name| {
                const tok = support.bump(p);
                // Own the name in the AST allocator for the same reason as
                // StringText below: the token's buffer is freed with the
                // token stream, which can happen before resolution.
                const owned_name = p.allocator.dupe(u8, name) catch @panic("OOM in primary");
                parts.append(p.allocator, StringPart{ .ShortInterp = Ident{
                    .name = owned_name,
                    .span = tok.span,
                } }) catch @panic("OOM in primary");
            },
            .InterpStart => {
                _ = support.bump(p);
                const e = exprmod.parseExpr(p) orelse return null;
                support.skipNl(p);
                _ = support.expect(p, .InterpEnd, "`}` to close string interpolation") orelse return null;
                const ep = p.allocator.create(Expr) catch @panic("OOM in primary");
                ep.* = e;
                parts.append(p.allocator, StringPart{ .Interp = ep }) catch @panic("OOM in primary");
            },
            .Eof => {
                support.err(p, "E0013", "unterminated string template", open.span);
                return Expr{ .StringTemplate = .{
                    .parts = parts.toOwnedSlice(p.allocator) catch @panic("OOM in primary"),
                    .span = open.span,
                } };
            },
            else => {
                const sp = support.currentSpan(p);
                support.err(p, "E0014", "unexpected token inside string template", sp);
                _ = support.bump(p);
            },
        }
    }
}

// ---------- small text helpers ----------

/// Trim every trailing character that appears in `chars` (Rust
/// `trim_end_matches(['L', 'u', 'U'])`).
fn trimEndAny(s: []const u8, chars: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and std.mem.indexOfScalar(u8, chars, s[end - 1]) != null) {
        end -= 1;
    }
    return s[0..end];
}

/// Strip a single leading `prefix` if present (Rust `trim_start_matches`
/// on a fixed two-char prefix, which matches at most once here).
fn trimStartPrefix(s: []const u8, prefix: []const u8) []const u8 {
    if (std.mem.startsWith(u8, s, prefix)) {
        return s[prefix.len..];
    }
    return s;
}

/// Copy `s` into the arena dropping every occurrence of `drop`.
fn filterOut(p: *Parser, s: []const u8, drop: u8) []const u8 {
    var buf = p.allocator.alloc(u8, s.len) catch @panic("OOM in primary");
    var n: usize = 0;
    for (s) |c| {
        if (c != drop) {
            buf[n] = c;
            n += 1;
        }
    }
    return buf[0..n];
}

/// Copy `s` into the arena dropping every character contained in `drop`.
fn filterOutChars(p: *Parser, s: []const u8, drop: []const u8) []const u8 {
    var buf = p.allocator.alloc(u8, s.len) catch @panic("OOM in primary");
    var n: usize = 0;
    for (s) |c| {
        if (std.mem.indexOfScalar(u8, drop, c) == null) {
            buf[n] = c;
            n += 1;
        }
    }
    return buf[0..n];
}

/// Parse `s` as a signed 64-bit integer in `radix`, returning `null` on
/// overflow / invalid digits (Rust `i64::from_str_radix(...).unwrap_or_else`).
/// Mirrors the Rust path where the digit text is unsigned but stored as
/// `i64`: values up to `u64::MAX` that overflow `i64` are rejected, same as
/// `from_str_radix` for a target without the magnitude.
fn parseI64Radix(s: []const u8, radix: u8) ?i64 {
    return std.fmt.parseInt(i64, s, radix) catch null;
}
