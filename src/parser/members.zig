//! Member declaration parsing: functions, properties with accessors, secondary
//! constructors, value and function parameters. Free functions over `*Parser`.

const std = @import("std");

const ast = @import("ast");
const diagnostics = @import("diagnostics");
const lexer = @import("lexer");
const span = @import("span");

const root = @import("parser.zig");
const support = @import("support.zig");
const types = @import("types.zig");
const exprmod = @import("expr.zig");
const stmt = @import("stmt.zig");
const file = @import("file.zig");

const Parser = root.Parser;
const ModifierFlags = root.ModifierFlags;

const Accessor = ast.Accessor;
const Expr = ast.Expr;
const Function = ast.Function;
const FunctionBody = ast.FunctionBody;
const Ident = ast.Ident;
const Param = ast.Param;
const Property = ast.Property;
const TypeRef = ast.TypeRef;
const Visibility = ast.Visibility;

const Keyword = lexer.Keyword;
const TokenKind = lexer.TokenKind;

const peek = support.peek;
const peekKind = support.peekKind;
const bump = support.bump;
const skipNl = support.skipNl;
const expect = support.expect;
const parseIdent = support.parseIdent;
const peekIdentText = support.peekIdentText;
const text = support.text;

/// Compares active tags, so a payload-carrying variant matches on tag alone.
fn is(k: *const TokenKind, comptime tag: std.meta.Tag(TokenKind)) bool {
    return std.meta.activeTag(k.*) == tag;
}

/// `null` past the end of the stream.
fn kindAt(p: *const Parser, idx: usize) ?TokenKind {
    if (idx >= p.tokens.len) return null;
    return p.tokens[idx].kind;
}

pub fn parseFun(p: *Parser, flags: ModifierFlags) ?Function {
    const kw = bump(p); // `fun`
    skipNl(p);
    var type_params: []ast.TypeParam = &.{};
    if (is(peekKind(p), .Lt)) {
        type_params = types.parseTypeParams(p, true);
        skipNl(p);
    }
    const receiver_type = parseFunReceiver(p) orelse return null;
    const name = parseIdent(p, "function name") orelse return null;
    _ = expect(p, .LParen, "`(`") orelse return null;
    const params = parseParamList(p);
    _ = expect(p, .RParen, "`)`") orelse return null;
    const return_type = if (is(peekKind(p), .Colon)) blk: {
        _ = bump(p);
        break :blk types.parseType(p);
    } else null;
    const where_bounds = types.parseWhereClause(p);
    skipNl(p);
    const body: ?FunctionBody = switch (peekKind(p).*) {
        .LBrace => if (stmt.parseBlock(p)) |b| FunctionBody{ .Block = b } else null,
        .Eq => blk: {
            _ = bump(p);
            skipNl(p);
            break :blk if (exprmod.parseExprBody(p)) |e| FunctionBody{ .Expr = e } else null;
        },
        else => null,
    };
    const end = p.tokens[p.pos -| 1].span;
    return Function{
        .name = name,
        .receiver_type = receiver_type,
        .context_params = flags.context_params,
        .type_params = type_params,
        .where_bounds = where_bounds,
        .params = params,
        .return_type = return_type,
        .body = body,
        .is_open = flags.is_open or flags.is_abstract,
        .is_override = flags.is_override,
        .is_final = flags.is_final,
        .is_abstract = flags.is_abstract,
        .is_operator = flags.is_operator,
        .is_inline = flags.is_inline,
        .is_infix = flags.is_infix,
        .is_tailrec = flags.is_tailrec,
        .is_suspend = flags.is_suspend,
        .is_expect = flags.is_expect,
        .is_actual = flags.is_actual,
        .visibility = flags.visibility,
        .annotations = flags.annotations.items,
        .span = kw.span.join(end),
    };
}

/// `present(null)` is no receiver, `failure` a parse failure; a flat `??TypeRef`
/// would conflate the two.
const ReceiverResult = union(enum) {
    failure,
    present: ?TypeRef,
};

fn parseFunReceiverResult(p: *Parser) ReceiverResult {
    // Pre-scanning `Ident (?)? . Ident` keeps the non-extension path on
    // `parseIdent` for the function name.
    if (looksLikeExtensionReceiver(p)) {
        const saved_sqp = p.suppress_qualified_path;
        p.suppress_qualified_path = true;
        var ty = types.parseType(p);
        p.suppress_qualified_path = saved_sqp;
        // Fold further `.Ident` segments in; the last one is the function name.
        while (ty) |*t| {
            if (t.function != null or t.nullable) break;
            const after = kindAt(p, p.pos);
            const after_next = kindAt(p, p.pos + 1);
            const after_2 = kindAt(p, p.pos + 2);
            // Fold only while at least two `.Ident` pairs remain.
            if (after != null and is(&after.?, .Dot) and
                after_next != null and is(&after_next.?, .Ident) and
                after_2 != null and is(&after_2.?, .Dot))
            {
                _ = bump(p); // '.'
                const seg = parseIdent(p, "type segment") orelse break;
                t.name = Ident{
                    .name = std.fmt.allocPrint(p.allocator, "{s}.{s}", .{ t.name.name, seg.name }) catch @panic("OOM"),
                    .span = t.name.span.join(seg.span),
                };
                t.span = t.span.join(seg.span);
            } else if (after != null and is(&after.?, .Dot) and
                after_next != null and is(&after_next.?, .Ident) and
                after_2 != null and is(&after_2.?, .Lt))
            {
                // `.Ident<...>`: fold only when a following `.Ident` supplies the function name.
                const save_pos = p.pos;
                _ = bump(p); // '.'
                const seg = parseIdent(p, "type segment") orelse {
                    p.pos = save_pos;
                    break;
                };
                const args: []ast.TypeArg = if (is(peekKind(p), .Lt)) types.parseTypeArgs(p) else &.{};
                const next0 = kindAt(p, p.pos);
                const next1 = kindAt(p, p.pos + 1);
                if (!(next0 != null and is(&next0.?, .Dot)) or
                    !(next1 != null and is(&next1.?, .Ident)))
                {
                    p.pos = save_pos;
                    break;
                }
                t.name = Ident{
                    .name = std.fmt.allocPrint(p.allocator, "{s}.{s}", .{ t.name.name, seg.name }) catch @panic("OOM"),
                    .span = t.name.span.join(seg.span),
                };
                t.type_args = args;
                t.span = t.span.join(seg.span);
            } else if (after != null and is(&after.?, .Dot) and
                after_next != null and is(&after_next.?, .Ident) and after_2 != null and
                (is(&after_2.?, .QuestionDot) or after_2.?.isQuestion()))
            {
                // Nullable qualified receiver `Modifier.Node?.hit`: the loop
                // breaks on the `?` / `?.`, consumed below.
                _ = bump(p); // '.'
                const seg = parseIdent(p, "type segment") orelse break;
                t.name = Ident{
                    .name = std.fmt.allocPrint(p.allocator, "{s}.{s}", .{ t.name.name, seg.name }) catch @panic("OOM"),
                    .span = t.name.span.join(seg.span),
                };
                t.span = t.span.join(seg.span);
                // A plain `?` is its own token: consume it here, leaving the `.` for the name.
                if (peekKind(p).*.isQuestion()) {
                    t.nullable = true;
                    _ = bump(p);
                }
                break;
            } else {
                break;
            }
        }
        // `T?.foo` lexes `?.` as one `QuestionDot`, which marks the receiver
        // nullable and serves as the dot before the function name.
        if (is(peekKind(p), .QuestionDot)) {
            if (ty) |*t| {
                t.nullable = true;
                const qd = bump(p);
                t.span = t.span.join(qd.span);
            } else {
                _ = bump(p);
            }
        } else {
            _ = expect(p, .Dot, "`.`") orelse return .failure;
        }
        skipNl(p);
        return .{ .present = ty };
    } else if (looksLikeParenExtensionReceiver(p)) {
        const ty = types.parseType(p);
        if (is(peekKind(p), .QuestionDot)) {
            _ = bump(p);
        } else {
            _ = expect(p, .Dot, "`.`") orelse return .failure;
        }
        skipNl(p);
        return .{ .present = ty };
    } else {
        return .{ .present = null };
    }
}

fn parseFunReceiver(p: *Parser) ??TypeRef {
    return switch (parseFunReceiverResult(p)) {
        .failure => null,
        .present => |ty| @as(??TypeRef, ty),
    };
}

/// Anonymous function `fun [<T>] [Receiver.](...) [: Ret] [body]`. A `return`
/// leaves this function, not the enclosing one.
pub fn parseAnonFun(p: *Parser) ?Expr {
    const kw = bump(p); // `fun`
    skipNl(p);
    if (is(peekKind(p), .Lt)) {
        _ = types.parseTypeParams(p, false);
        skipNl(p);
    }
    const receiver_ty = if (looksLikeAnonFunReceiver(p)) blk: {
        var ty = types.parseSimpleType(p);
        if (ty) |*t| {
            if (peekKind(p).isQuestion()) {
                const q = bump(p);
                t.nullable = true;
                t.span = t.span.join(q.span);
            }
        }
        _ = expect(p, .Dot, "`.`") orelse return null;
        skipNl(p);
        break :blk ty;
    } else null;
    _ = expect(p, .LParen, "`(`") orelse return null;
    const params = parseParamListWith(p, true);
    _ = expect(p, .RParen, "`)`") orelse return null;
    const return_ty = if (is(peekKind(p), .Colon)) blk: {
        _ = bump(p);
        break :blk types.parseType(p);
    } else null;
    _ = types.parseWhereClause(p);
    skipNl(p);
    const body: ?*FunctionBody = switch (peekKind(p).*) {
        .LBrace => if (stmt.parseBlock(p)) |b| boxBody(p, FunctionBody{ .Block = b }) else null,
        .Eq => blk: {
            _ = bump(p);
            skipNl(p);
            break :blk if (exprmod.parseExprBody(p)) |e| boxBody(p, FunctionBody{ .Expr = e }) else null;
        },
        else => null,
    };
    const end = p.tokens[p.pos -| 1].span;
    return Expr{ .AnonFun = .{
        .receiver_ty = receiver_ty,
        .params = params,
        .return_ty = return_ty,
        .body = body,
        .is_suspend = false,
        .span = kw.span.join(end),
    } };
}

fn boxBody(p: *Parser, b: FunctionBody) *FunctionBody {
    const ptr = p.allocator.create(FunctionBody) catch @panic("OOM");
    ptr.* = b;
    return ptr;
}

/// Look-ahead for `Ident (?)? . (`: an anonymous-function receiver has no name
/// after the dot.
pub fn looksLikeAnonFunReceiver(p: *const Parser) bool {
    const t0 = kindAt(p, p.pos) orelse return false;
    if (!is(&t0, .Ident)) return false;
    var j = p.pos + 1;
    if (kindAt(p, j)) |k| {
        if (k.isQuestion()) j += 1;
    }
    const at_j = kindAt(p, j);
    const at_j1 = kindAt(p, j + 1);
    return at_j != null and is(&at_j.?, .Dot) and
        at_j1 != null and is(&at_j1.?, .LParen);
}

/// Look-ahead for `Ident (?)? . Ident`, an extension receiver. Commits nothing.
pub fn looksLikeExtensionReceiver(p: *const Parser) bool {
    const t0 = kindAt(p, p.pos) orelse return false;
    if (!is(&t0, .Ident)) return false;
    var j = p.pos + 1;
    if (kindAt(p, j)) |k| {
        if (is(&k, .Lt)) {
            var depth: usize = 1;
            j += 1;
            while (depth > 0) {
                const kk = kindAt(p, j);
                if (kk == null) return false;
                switch (kk.?) {
                    .Lt => depth += 1,
                    .Gt => depth -= 1,
                    .Eof => return false,
                    else => {},
                }
                j += 1;
            }
        }
    }
    if (kindAt(p, j)) |k| {
        if (k.isQuestion()) j += 1;
    }
    // `T?.foo` lexes `?.` as one `QuestionDot`: nullable receiver plus separator.
    const at_j = kindAt(p, j);
    if (at_j != null and is(&at_j.?, .QuestionDot)) {
        const at_j1 = kindAt(p, j + 1);
        return at_j1 != null and is(&at_j1.?, .Ident);
    }
    const at_j1b = kindAt(p, j + 1);
    return at_j != null and is(&at_j.?, .Dot) and
        at_j1b != null and is(&at_j1b.?, .Ident);
}

/// Look-ahead for `( ... ) (?)? . Ident`, which the `Ident`-led scan misses.
pub fn looksLikeParenExtensionReceiver(p: *const Parser) bool {
    const first = kindAt(p, p.pos);
    if (!(first != null and is(&first.?, .LParen))) return false;
    var depth: usize = 0;
    var j = p.pos;
    while (true) {
        const k = kindAt(p, j);
        if (k == null) return false;
        switch (k.?) {
            .LParen => depth += 1,
            .RParen => {
                depth -= 1;
                if (depth == 0) {
                    j += 1;
                    break;
                }
            },
            .Eof => return false,
            else => {},
        }
        j += 1;
    }
    if (kindAt(p, j)) |k| {
        if (k.isQuestion()) j += 1;
    }
    const at_j = kindAt(p, j);
    if (at_j != null and is(&at_j.?, .QuestionDot)) {
        const at_j1 = kindAt(p, j + 1);
        return at_j1 != null and is(&at_j1.?, .Ident);
    }
    const at_j1b = kindAt(p, j + 1);
    return at_j != null and is(&at_j.?, .Dot) and
        at_j1b != null and is(&at_j1b.?, .Ident);
}

pub fn parseParamList(p: *Parser) []Param {
    return parseParamListWith(p, false);
}

fn anyPlaceholder(name_span: span.Span) TypeRef {
    return TypeRef{
        .name = Ident{ .name = "Any", .span = name_span },
        .nullable = true,
        .span = name_span,
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
}

/// Under `allow_no_type` the annotation is optional, as an anonymous function
/// takes it from the context.
pub fn parseParamListWith(p: *Parser, allow_no_type: bool) []Param {
    var params: std.ArrayList(Param) = .empty;
    while (true) {
        skipNl(p);
        switch (peekKind(p).*) {
            .RParen, .Eof => break,
            else => {},
        }
        const annotations = file.parseAnnotations(p);
        // `val`/`var` markers are allowed here and ignored.
        if (peekKind(p).* == .Keyword and
            (peekKind(p).Keyword == .Val or peekKind(p).Keyword == .Var))
        {
            _ = bump(p);
            skipNl(p);
        }
        var is_vararg = false;
        var is_crossinline = false;
        var is_noinline = false;
        while (true) {
            const t = peekIdentText(p) orelse break;
            if (std.mem.eql(u8, t, "vararg")) {
                _ = bump(p);
                skipNl(p);
                is_vararg = true;
            } else if (std.mem.eql(u8, t, "crossinline")) {
                _ = bump(p);
                skipNl(p);
                is_crossinline = true;
            } else if (std.mem.eql(u8, t, "noinline")) {
                _ = bump(p);
                skipNl(p);
                is_noinline = true;
            } else {
                break;
            }
        }
        const name = parseIdent(p, "parameter name") orelse {
            recoverUntilParen(p);
            break;
        };
        const start = name.span;
        const has_colon = is(peekKind(p), .Colon);
        if (has_colon) {
            _ = bump(p);
        } else if (!allow_no_type) {
            _ = expect(p, .Colon, "`:`");
        }
        const ty = if (has_colon or !allow_no_type)
            (types.parseType(p) orelse anyPlaceholder(name.span))
        else
            anyPlaceholder(name.span);
        var default: ?Expr = null;
        if (is(peekKind(p), .Eq)) {
            _ = bump(p);
            skipNl(p);
            default = exprmod.parseExpr(p);
        }
        const end = if (default) |d| d.span() else ty.span;
        const default_boxed: ?*ast.Expr = if (default) |dv| blk: {
            const e = p.allocator.create(ast.Expr) catch @panic("OOM");
            e.* = dv;
            break :blk e;
        } else null;
        params.append(p.allocator, Param{
            .name = name,
            .ty = ty,
            .default = default_boxed,
            .is_vararg = is_vararg,
            .is_crossinline = is_crossinline,
            .is_noinline = is_noinline,
            .annotations = annotations,
            .span = start.join(end),
        }) catch @panic("OOM");
        skipNl(p);
        if (is(peekKind(p), .Comma)) {
            _ = bump(p);
        } else {
            break;
        }
    }
    return params.toOwnedSlice(p.allocator) catch @panic("OOM");
}

pub fn recoverUntilParen(p: *Parser) void {
    while (true) {
        switch (peekKind(p).*) {
            .RParen, .Eof, .LBrace => return,
            else => {},
        }
        _ = bump(p);
    }
}

pub fn parseProperty(p: *Parser) ?Property {
    return parsePropertyWithFlags(p, ModifierFlags{});
}

/// Local properties cannot declare accessors, so a following `get(...)` /
/// `set(...)` is a separate statement and must not be consumed.
pub fn parseLocalProperty(p: *Parser, flags: ModifierFlags) ?Property {
    return parsePropertyInner(p, flags, false);
}

pub fn parsePropertyWithFlags(p: *Parser, flags: ModifierFlags) ?Property {
    return parsePropertyInner(p, flags, true);
}

fn parsePropertyInner(p: *Parser, flags: ModifierFlags, allow_accessors: bool) ?Property {
    // `suspend` is not a property modifier, but the stdlib `coroutineContext`
    // carries it, and suspend bodies run inline, so it is inert here.
    _ = flags.suspend_span;
    const kw_tok = bump(p);
    const mutable = kw_tok.kind == .Keyword and kw_tok.kind.Keyword == .Var;
    skipNl(p);
    // Generics are erased, so the type parameters serve one purpose: a bare
    // type-parameter receiver is rewritten below to its bound.
    var prop_type_params: []ast.TypeParam = &.{};
    if (is(peekKind(p), .Lt)) {
        prop_type_params = types.parseTypeParams(p, true);
        skipNl(p);
    }
    // A use-site-targeted annotation may prefix the receiver; discard it.
    if (peekKind(p).isAt()) {
        _ = file.parseAnnotations(p);
        skipNl(p);
    }
    var receiver_type = parsePropertyReceiver(p) orelse return null;
    // A bare type-parameter receiver extends its upper bound; an unbounded
    // parameter extends `Any`.
    if (receiver_type) |*rt| {
        if (rt.type_args.len == 0) {
            for (prop_type_params) |tp| {
                if (std.mem.eql(u8, tp.name.name, rt.name.name)) {
                    if (tp.upper_bound) |bound| {
                        receiver_type = bound;
                    } else {
                        rt.name = .{ .name = "Any", .span = rt.name.span };
                    }
                    break;
                }
            }
        }
    }
    const name = parseIdent(p, "property name") orelse return null;
    const ty = if (is(peekKind(p), .Colon)) blk: {
        _ = bump(p);
        break :blk types.parseType(p);
    } else null;
    var init: ?Expr = null;
    var delegate: ?Expr = null;
    var explicit_field: ?ast.ExplicitField = null;
    // Explicit backing-field clause in the initializer slot, ahead of any `=` or
    // `by`, on the same line or the next. A local property cannot declare one,
    // so the shape is recognized and rejected to report the misuse rather than a
    // stray assignment.
    if (scanFieldClause(p, !allow_accessors)) |scan| {
        explicit_field = parseFieldClause(p, scan, allow_accessors);
    }
    if (explicit_field == null and is(peekKind(p), .Eq)) {
        _ = bump(p);
        skipNl(p);
        init = exprmod.parseExpr(p);
    } else if (explicit_field == null) {
        if (peekIdentText(p)) |t| {
            if (std.mem.eql(u8, t, "by")) {
                _ = bump(p);
                skipNl(p);
                delegate = exprmod.parseExpr(p);
            }
        }
    }
    if (allow_accessors and explicit_field == null and (init != null or delegate != null)) {
        if (scanFieldClause(p, false)) |scan| {
            explicit_field = parseFieldClause(p, scan, allow_accessors);
        }
    }
    if (explicit_field != null and delegate == null) {
        // A delegate after the field clause still parses; the checker rejects the pair.
        if (nextSignificantIsBy(p)) {
            skipNl(p);
            _ = bump(p); // `by`
            skipNl(p);
            delegate = exprmod.parseExpr(p);
        }
    }
    const accessors = if (allow_accessors)
        (parsePropertyAccessors(p) orelse return null)
    else
        PropertyAccessors{ .getter = null, .setter = null, .setter_visibility = null };
    const end = p.tokens[p.pos -| 1].span;
    const ef_boxed: ?*ast.ExplicitField = if (explicit_field) |efv| blk: {
        const e = p.allocator.create(ast.ExplicitField) catch @panic("OOM");
        e.* = efv;
        break :blk e;
    } else null;
    const delegate_boxed: ?*Expr = if (delegate) |dv| blk: {
        const e = p.allocator.create(Expr) catch @panic("OOM");
        e.* = dv;
        break :blk e;
    } else null;
    const getter_boxed: ?*Accessor = if (accessors.getter) |gv| blk: {
        const acc = p.allocator.create(Accessor) catch @panic("OOM");
        acc.* = gv;
        break :blk acc;
    } else null;
    const setter_boxed: ?*Accessor = if (accessors.setter) |sv| blk: {
        const acc = p.allocator.create(Accessor) catch @panic("OOM");
        acc.* = sv;
        break :blk acc;
    } else null;
    return Property{
        .mutable = mutable,
        .name = name,
        .context_params = flags.context_params,
        .receiver_type = receiver_type,
        .ty = ty,
        .init = init,
        .delegate = delegate_boxed,
        .getter = getter_boxed,
        .setter = setter_boxed,
        .is_abstract = flags.is_abstract,
        .is_open = flags.is_open,
        .is_override = flags.is_override,
        .is_lateinit = flags.is_lateinit,
        .is_const = flags.is_const,
        .is_inline = flags.is_inline,
        .is_expect = flags.is_expect,
        .is_actual = flags.is_actual,
        .setter_visibility = accessors.setter_visibility,
        .explicit_field = ef_boxed,
        .visibility = flags.visibility,
        .annotations = flags.annotations.items,
        .span = kw_tok.span.join(end),
    };
}

/// Where the `field` keyword sits, and where any illegal modifier run ahead of it begins.
const FieldScan = struct {
    field_idx: usize,
    first_mod_idx: ?usize,
};

/// None are legal ahead of a `field` clause; each is reported.
fn isFieldClauseModifier(t: []const u8) bool {
    const mods = [_][]const u8{
        "public", "private", "protected", "internal", "lateinit",
        "open",   "final",   "abstract",  "const",    "inline",
    };
    for (mods) |m| {
        if (std.mem.eql(u8, t, m)) return true;
    }
    return false;
}

/// Lookahead (across newlines, skipping modifier soft keywords) for `field` in
/// the initializer slot; does not advance `p.pos`. `require_marker` demands a
/// `:` or `=` after it, for local properties, where a bare `field` line is an
/// ordinary expression statement.
fn scanFieldClause(p: *const Parser, require_marker: bool) ?FieldScan {
    if (require_marker and p.in_accessor_body) return null;
    var i = p.pos;
    while (kindAt(p, i)) |k| {
        if (!is(&k, .Newline)) break;
        i += 1;
    }
    var first_mod: ?usize = null;
    while (kindAt(p, i)) |k| {
        if (!is(&k, .Ident)) break;
        const t = text(p, p.tokens[i].span);
        if (!isFieldClauseModifier(t)) break;
        if (first_mod == null) first_mod = i;
        i += 1;
        while (kindAt(p, i)) |k2| {
            if (!is(&k2, .Newline)) break;
            i += 1;
        }
    }
    const k = kindAt(p, i) orelse return null;
    if (!is(&k, .Ident)) return null;
    if (!std.mem.eql(u8, text(p, p.tokens[i].span), "field")) return null;
    const next = kindAt(p, i + 1) orelse return null;
    const has_marker = is(&next, .Colon) or is(&next, .Eq);
    if (!has_marker) {
        if (require_marker) return null;
        // A bare `field` reads as a clause only when it clearly ends there.
        switch (next) {
            .Newline, .Semicolon, .RBrace, .Eof => {},
            else => return null,
        }
    }
    return .{ .field_idx = i, .first_mod_idx = first_mod };
}

/// On a local property the clause is a syntax error: reported, consumed for
/// recovery, and dropped.
fn parseFieldClause(p: *Parser, scan: FieldScan, allow_accessors: bool) ?ast.ExplicitField {
    skipNl(p);
    while (p.pos < scan.field_idx) {
        const tok = bump(p);
        if (is(&tok.kind, .Ident)) {
            const t = text(p, tok.span);
            if (isFieldClauseModifier(t)) {
                const msg = std.fmt.allocPrint(
                    p.allocator,
                    "Modifier '{s}' is not applicable to 'backing field'",
                    .{t},
                ) catch "modifier is not applicable to 'backing field'";
                support.errWithFactory(
                    p,
                    &diagnostics.generated.WRONG_MODIFIER_TARGET,
                    "E0016",
                    msg,
                    tok.span,
                );
            }
        }
        skipNl(p);
    }
    const field_tok = bump(p); // `field`
    if (!allow_accessors) {
        support.err(
            p,
            "E0015",
            "explicit backing fields are not allowed on local properties",
            field_tok.span,
        );
    }
    var fty: ?TypeRef = null;
    if (is(peekKind(p), .Colon)) {
        _ = bump(p);
        fty = types.parseType(p);
    }
    var finit: ?Expr = null;
    if (is(peekKind(p), .Eq)) {
        _ = bump(p);
        skipNl(p);
        finit = exprmod.parseExpr(p);
    }
    if (!allow_accessors) return null;
    return .{ .ty = fty, .init = finit, .span = field_tok.span };
}

/// Does not advance `p.pos`.
fn nextSignificantIsBy(p: *const Parser) bool {
    var i = p.pos;
    while (kindAt(p, i)) |k| {
        if (!is(&k, .Newline)) break;
        i += 1;
    }
    const k = kindAt(p, i) orelse return false;
    if (!is(&k, .Ident)) return false;
    return std.mem.eql(u8, text(p, p.tokens[i].span), "by");
}

/// At `(`: whether the balanced group is followed by `.` `Ident`, making it a
/// parenthesized function-type extension receiver.
fn parenReceiverAhead(p: *const Parser) bool {
    if (!is(peekKind(p), .LParen)) return false;
    var j = p.pos;
    var depth: usize = 0;
    while (j < p.tokens.len) : (j += 1) {
        switch (std.meta.activeTag(p.tokens[j].kind)) {
            .LParen => depth += 1,
            .RParen => {
                depth -= 1;
                if (depth == 0) {
                    j += 1;
                    break;
                }
            },
            .Eof => return false,
            else => {},
        }
    }
    if (j >= p.tokens.len or std.meta.activeTag(p.tokens[j].kind) != .Dot) return false;
    return j + 1 < p.tokens.len and std.meta.activeTag(p.tokens[j + 1].kind) == .Ident;
}

fn parsePropertyReceiverResult(p: *Parser) ReceiverResult {
    // The group is a type when a `.` and the property name follow its `)`.
    if (parenReceiverAhead(p)) {
        const ty = types.parseType(p) orelse return .failure;
        _ = expect(p, .Dot, "`.`") orelse return .failure;
        skipNl(p);
        return .{ .present = ty };
    }
    if (looksLikeExtensionReceiver(p)) {
        const saved_sqp = p.suppress_qualified_path;
        p.suppress_qualified_path = true;
        var ty = types.parseType(p);
        p.suppress_qualified_path = saved_sqp;
        // `parseType` under suppression takes only the first segment, so a
        // nested receiver would lose its middle segments and mis-parse the name.
        var path: std.ArrayList(u8) = .empty;
        defer path.deinit(p.allocator);
        if (ty) |t| path.appendSlice(p.allocator, t.name.name) catch @panic("OOM");
        if (is(peekKind(p), .QuestionDot)) {
            if (ty) |*t| {
                t.nullable = true;
                const qd = bump(p);
                t.span = t.span.join(qd.span);
            } else {
                _ = bump(p);
            }
        } else {
            _ = expect(p, .Dot, "`.`") orelse return .failure;
            // An ident followed by `.<ident>` belongs to the class path, not the
            // property name. Stop at `Companion` and at the final segment.
            while (true) {
                const here = peekIdentText(p) orelse break;
                if (std.mem.eql(u8, here, "Companion")) break;
                const k1 = kindAt(p, p.pos + 1) orelse break;
                // `Ident<...>.` is a nested segment; fold it with its arguments.
                if (is(&k1, .Lt)) {
                    const save_pos = p.pos;
                    const seg = parseIdent(p, "type") orelse break;
                    const args: []ast.TypeArg = if (is(peekKind(p), .Lt)) types.parseTypeArgs(p) else &.{};
                    const n0 = kindAt(p, p.pos);
                    const n1 = kindAt(p, p.pos + 1);
                    if (!(n0 != null and is(&n0.?, .Dot)) or !(n1 != null and is(&n1.?, .Ident))) {
                        p.pos = save_pos;
                        break;
                    }
                    _ = bump(p); // `.`
                    path.append(p.allocator, '.') catch @panic("OOM");
                    path.appendSlice(p.allocator, seg.name) catch @panic("OOM");
                    if (ty) |*t| {
                        t.name = seg;
                        t.type_args = args;
                    }
                    continue;
                }
                const k2 = kindAt(p, p.pos + 2) orelse break;
                if (!is(&k1, .Dot) or !is(&k2, .Ident)) break;
                const seg = parseIdent(p, "type") orelse break;
                _ = bump(p); // `.`
                path.append(p.allocator, '.') catch @panic("OOM");
                path.appendSlice(p.allocator, seg.name) catch @panic("OOM");
                if (ty) |*t| t.name = seg;
            }
        }
        // Companion-qualified receiver (`String.Companion.CASE_INSENSITIVE_ORDER`):
        // the type collapses to the class, but `qualified_path` keeps
        // `<Class>.Companion` so registration keys it apart from a plain
        // `val <Class>.foo`, which targets instances rather than the companion.
        const next1 = kindAt(p, p.pos + 1);
        const is_companion = blk: {
            const t = peekIdentText(p) orelse break :blk false;
            break :blk std.mem.eql(u8, t, "Companion");
        };
        if (is_companion and next1 != null and is(&next1.?, .Dot)) {
            _ = bump(p); // `Companion`
            _ = bump(p); // `.`
            skipNl(p);
            path.appendSlice(p.allocator, ".Companion") catch @panic("OOM");
            if (ty) |*t| {
                t.qualified_path = p.allocator.dupe(u8, path.items) catch @panic("OOM");
            }
        } else if (std.mem.findScalar(u8, path.items, '.') != null) {
            // Keep the full path of `A.B.foo` so the resolver targets the nested class.
            if (ty) |*t| {
                t.qualified_path = p.allocator.dupe(u8, path.items) catch @panic("OOM");
            }
        }
        skipNl(p);
        return .{ .present = ty };
    } else {
        return .{ .present = null };
    }
}

fn parsePropertyReceiver(p: *Parser) ??TypeRef {
    return switch (parsePropertyReceiverResult(p)) {
        .failure => null,
        .present => |ty| @as(??TypeRef, ty),
    };
}

const AccessorScan = struct {
    index: usize,
    visibility: ?Visibility,
    inlined: bool,
    had_annotation: bool,
};

/// Lookahead from `from` past newlines and any `inline` or visibility modifiers
/// to a `get` / `set` keyword. Does not advance `p.pos`.
fn scanAccessorModifiers(p: *const Parser, from: usize) AccessorScan {
    var i = from;
    while (kindAt(p, i)) |k| {
        if (!is(&k, .Newline)) break;
        i += 1;
    }
    var acc_visibility: ?Visibility = null;
    var acc_inline = false;
    var had_annotation = false;
    // Kotlin accepts `inline get()` and `private inline set(v)`, so either order.
    while (i < p.tokens.len) {
        const tok = p.tokens[i];
        // The commit path re-parses this annotation run into the accessor's `annotations`.
        if (tok.kind.isAt()) {
            had_annotation = true;
            i += 1; // `@`
            const a = kindAt(p, i);
            const b = kindAt(p, i + 1);
            if (a != null and is(&a.?, .Ident) and b != null and is(&b.?, .Colon)) {
                i += 2;
            }
            while (kindAt(p, i)) |k| {
                if (!is(&k, .Ident)) break;
                i += 1;
                if (kindAt(p, i)) |d| {
                    if (is(&d, .Dot)) {
                        i += 1;
                    } else {
                        break;
                    }
                } else {
                    break;
                }
            }
            if (kindAt(p, i)) |k| {
                if (is(&k, .LParen)) {
                    var depth: i32 = 0;
                    while (kindAt(p, i)) |t2| {
                        switch (t2) {
                            .LParen => depth += 1,
                            .RParen => depth -= 1,
                            else => {},
                        }
                        i += 1;
                        if (depth == 0) break;
                    }
                }
            }
            while (kindAt(p, i)) |k| {
                if (!is(&k, .Newline)) break;
                i += 1;
            }
            continue;
        }
        if (!is(&tok.kind, .Ident)) break;
        const txt = text(p, tok.span);
        const v: ?Visibility = if (std.mem.eql(u8, txt, "public"))
            .Public
        else if (std.mem.eql(u8, txt, "private"))
            .Private
        else if (std.mem.eql(u8, txt, "protected"))
            .Protected
        else if (std.mem.eql(u8, txt, "internal"))
            .Internal
        else
            null;
        if (v != null and acc_visibility == null) {
            acc_visibility = v;
            i += 1;
            while (kindAt(p, i)) |k| {
                if (!is(&k, .Newline)) break;
                i += 1;
            }
            continue;
        }
        if (std.mem.eql(u8, txt, "inline") and !acc_inline) {
            acc_inline = true;
            i += 1;
            while (kindAt(p, i)) |k| {
                if (!is(&k, .Newline)) break;
                i += 1;
            }
            continue;
        }
        break;
    }
    return .{ .index = i, .visibility = acc_visibility, .inlined = acc_inline, .had_annotation = had_annotation };
}

const PropertyAccessors = struct {
    getter: ?Accessor,
    setter: ?Accessor,
    setter_visibility: ?Visibility,
};

/// In either order and across newlines; `null` propagates a parse failure.
fn parsePropertyAccessors(p: *Parser) ?PropertyAccessors {
    var getter: ?Accessor = null;
    var setter: ?Accessor = null;
    var setter_visibility: ?Visibility = null;
    while (true) {
        const save = p.pos;
        // An accessor may follow a `;` (`var x = "OK"; private set`).
        var scan_from = p.pos;
        if (kindAt(p, scan_from)) |k| if (is(&k, .Semicolon)) {
            var j = scan_from + 1;
            while (kindAt(p, j)) |kk| : (j += 1) {
                if (!is(&kk, .Newline)) break;
            }
            const after_mods = scanAccessorModifiers(p, j);
            if (kindAt(p, after_mods.index)) |ak| if (is(&ak, .Ident)) {
                const t = text(p, p.tokens[after_mods.index].span);
                if (std.mem.eql(u8, t, "get") or std.mem.eql(u8, t, "set")) scan_from = j;
            };
        };
        const scan = scanAccessorModifiers(p, scan_from);
        const i = scan.index;
        const acc_visibility = scan.visibility;
        const acc_inline = scan.inlined;
        const tok_kind = kindAt(p, i) orelse break;
        if (!is(&tok_kind, .Ident)) break;
        const ident_text = text(p, p.tokens[i].span);
        const is_get = std.mem.eql(u8, ident_text, "get");
        const is_set = std.mem.eql(u8, ident_text, "set");
        if (!is_get and !is_set) break;
        const next = kindAt(p, i + 1);
        // Bare `private set` keeps the default accessor and only restricts
        // visibility, so the synthesized accessor is bodyless.
        const is_bodyless = !(next != null and is(&next.?, .LParen));
        if (is_bodyless and acc_visibility == null and !acc_inline and !scan.had_annotation) {
            // A bare `get` / `set` is the default accessor only when nothing
            // follows it on the line: `set = 5` is an identifier named `set`.
            const after = kindAt(p, i + 1);
            const alone = after == null or is(&after.?, .Newline) or is(&after.?, .Semicolon) or
                is(&after.?, .RBrace) or is(&after.?, .Eof);
            if (!alone) break;
        }
        // The annotations are parsed for real: `@Composable get()` marks an
        // accessor the compose pass transforms.
        p.pos = save;
        skipNl(p);
        const acc_annotations = file.parseAnnotations(p);
        p.pos = i;
        const start_span = bump(p).span; // get / set
        if (is_bodyless) {
            // Bodyless: `private set` only restricts visibility, and an abstract
            // `get` has no body.
            if (is_set) {
                if (acc_visibility) |v| setter_visibility = v;
            }
            continue;
        }
        _ = expect(p, .LParen, "`(`") orelse return null;
        var acc_params: std.ArrayList(Ident) = .empty;
        if (!is(peekKind(p), .RParen)) {
            _ = file.parseAnnotations(p);
            const par = parseIdent(p, "setter parameter") orelse return null;
            acc_params.append(p.allocator, par) catch @panic("OOM");
            if (is(peekKind(p), .Colon)) {
                _ = bump(p);
                _ = types.parseType(p);
            }
        }
        _ = expect(p, .RParen, "`)`") orelse return null;
        const return_type = if (is(peekKind(p), .Colon)) blk: {
            _ = bump(p);
            break :blk types.parseType(p);
        } else null;
        skipNl(p);
        const saved_iab = p.in_accessor_body;
        p.in_accessor_body = true;
        defer p.in_accessor_body = saved_iab;
        const body: FunctionBody = if (is(peekKind(p), .Eq)) blk: {
            _ = bump(p);
            skipNl(p);
            const e = exprmod.parseExprBody(p) orelse return null;
            break :blk FunctionBody{ .Expr = e };
        } else if (is(peekKind(p), .LBrace)) blk: {
            const b = stmt.parseBlock(p) orelse return null;
            break :blk FunctionBody{ .Block = b };
        } else {
            p.pos = save;
            break;
        };
        const end = p.tokens[p.pos -| 1].span;
        const acc = Accessor{
            .params = acc_params.toOwnedSlice(p.allocator) catch @panic("OOM"),
            .return_type = return_type,
            .body = body,
            .visibility = acc_visibility,
            .is_inline = acc_inline,
            .annotations = acc_annotations,
            .span = start_span.join(end),
        };
        if (is_get) {
            getter = acc;
        } else {
            setter = acc;
        }
    }
    return .{ .getter = getter, .setter = setter, .setter_visibility = setter_visibility };
}

comptime {
    _ = Parser;
}
