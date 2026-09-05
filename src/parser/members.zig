//! Member declaration parsing: functions, properties (with accessors),
//! secondary constructors, value/function parameters.
//!
//! Free functions over `*Parser`.

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

/// True when the token kind tag matches `tag`. The lexer's `TokenKind` is a
/// tagged union, so equality is by active tag (payload-carrying variants like
/// `Keyword` compare on tag here; callers that need the payload destructure
/// it themselves).
fn is(k: *const TokenKind, comptime tag: std.meta.Tag(TokenKind)) bool {
    return std.meta.activeTag(k.*) == tag;
}

/// The token kind at `idx`, or `null` past the end of the stream.
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
        // Function declaration without body (abstract / external).
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

/// Result of `parseFunReceiver` / `parsePropertyReceiver`. The three states
/// (parse failure / no receiver / receiver type) are all meaningful, so a
/// flat `??TypeRef` would be ambiguous; an explicit union keeps them apart.
/// `failure` propagates a parse failure to the caller, `present` carries the
/// optional receiver type (`null` = no receiver).
const ReceiverResult = union(enum) {
    failure,
    present: ?TypeRef,
};

/// Parse the optional extension receiver preceding a function name.
/// Returns `.present(null)` when there is no receiver, `.present(ty)` for a
/// receiver, and `.failure` to propagate a parse failure to the caller.
fn parseFunReceiverResult(p: *Parser) ReceiverResult {
    // Receiver-typed extension function: `fun T.foo(...)` or
    // `fun T?.foo(...)`. We pre-scan for the pattern
    // `Ident (?)? . Ident` so the regular non-extension path can
    // continue using `parseIdent` for the function name.
    if (looksLikeExtensionReceiver(p)) {
        const saved_sqp = p.suppress_qualified_path;
        p.suppress_qualified_path = true;
        var ty = types.parseType(p);
        p.suppress_qualified_path = saved_sqp;
        // Fold additional `.Ident` segments into the receiver type for
        // qualified extension receivers like `Foo.Companion.bar()` — keep
        // the final `.Ident` as the function name itself.
        while (ty) |*t| {
            if (t.function != null or t.nullable) break;
            const after = kindAt(p, p.pos);
            const after_next = kindAt(p, p.pos + 1);
            const after_2 = kindAt(p, p.pos + 2);
            // Pattern: `.Ident .Ident` (more segments left). Fold only when
            // at least two more `.Ident` pairs remain — the very last one is
            // the function name.
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
                // Pattern: `.Ident<...>` — nested type with generic args (e.g.
                // `Map.Entry<K, V>.component1()`). Fold the `.Ident<...>` into
                // receiver only when a following `.Ident` exists for the
                // function name.
                const save_pos = p.pos;
                _ = bump(p); // '.'
                const seg = parseIdent(p, "type segment") orelse {
                    p.pos = save_pos;
                    break;
                };
                const args: []ast.TypeArg = if (is(peekKind(p), .Lt)) types.parseTypeArgs(p) else &.{};
                // Require following `.Ident` (the function name).
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
                // Pattern: `.Ident ?. …` / `.Ident ? . …` — a NULLABLE qualified
                // receiver (`Modifier.Node?.hit`). Fold the `.Ident` segment; the
                // trailing `?` and the separating `.` before the function name are
                // consumed below (the loop breaks on the `?`/`?.`, then the
                // QuestionDot / expect-`.` logic runs).
                _ = bump(p); // '.'
                const seg = parseIdent(p, "type segment") orelse break;
                t.name = Ident{
                    .name = std.fmt.allocPrint(p.allocator, "{s}.{s}", .{ t.name.name, seg.name }) catch @panic("OOM"),
                    .span = t.name.span.join(seg.span),
                };
                t.span = t.span.join(seg.span);
                // A plain `?` (not the combined `?.`) is its own token: mark the
                // receiver nullable + consume it here, leaving `.` for the name.
                if (peekKind(p).*.isQuestion()) {
                    t.nullable = true;
                    _ = bump(p);
                }
                break;
            } else {
                break;
            }
        }
        // `parseType` already consumed the `Ident` and any trailing `?`; now
        // consume the dot before the function name. `T?.foo` lexes the `?.`
        // as one `QuestionDot` token — handle that case by flagging the
        // receiver nullable and treating the same token as the separating dot.
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
        // Parenthesized / function-type extension receiver:
        // `fun (suspend () -> T).startCoroutine(...)`.
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

/// Thin tri-state wrapper: returns `null` on parse failure, otherwise the
/// optional receiver type.
fn parseFunReceiver(p: *Parser) ??TypeRef {
    return switch (parseFunReceiverResult(p)) {
        .failure => null,
        .present => |ty| @as(??TypeRef, ty),
    };
}

/// Anonymous-function expression: `fun [<T>] [Receiver.](...) [: Ret] [body]`.
/// No name follows the `fun` keyword. `return` inside the body is a local
/// return out of this function, not the enclosing one.
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

/// Look-ahead for `Ident (?)? . (` — anonymous-function receiver shape.
/// Distinct from named-fun extension receivers because no name follows the dot.
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

/// Look-ahead for `Ident (?)? . Ident` at the current cursor — the shape that
/// introduces an extension-function's receiver type. Avoids parser commitment
/// so the regular non-extension declaration path stays unaffected when no
/// receiver is present.
pub fn looksLikeExtensionReceiver(p: *const Parser) bool {
    const t0 = kindAt(p, p.pos) orelse return false;
    if (!is(&t0, .Ident)) return false;
    var j = p.pos + 1;
    // Skip a balanced generic-argument list (`<T>` / `<A, B<C>>`).
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
    // `T?.foo` lexes the `?.` as a single `QuestionDot` token; treat it as
    // nullable-receiver followed by the member separator.
    const at_j = kindAt(p, j);
    if (at_j != null and is(&at_j.?, .QuestionDot)) {
        const at_j1 = kindAt(p, j + 1);
        return at_j1 != null and is(&at_j1.?, .Ident);
    }
    const at_j1b = kindAt(p, j + 1);
    return at_j != null and is(&at_j.?, .Dot) and
        at_j1b != null and is(&at_j1b.?, .Ident);
}

/// Look-ahead for a parenthesized extension receiver:
/// `( … ) (?)? . Ident` — the shape of `fun (suspend () -> T).f()` or
/// `fun ((A) -> B).f()`. The receiver is a function/grouped type, so the
/// `Ident`-led `looksLikeExtensionReceiver` scan does not apply.
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

/// Synthesise the `Any?` placeholder used when a param's type is missing or
/// elided.
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

/// Same as `parseParamList`, but with `allow_no_type` the param's type
/// annotation is optional — used for anonymous function expressions
/// (`fun(n) = …`) where the function-type context supplies the param type.
pub fn parseParamListWith(p: *Parser, allow_no_type: bool) []Param {
    var params: std.ArrayList(Param) = .empty;
    while (true) {
        skipNl(p);
        switch (peekKind(p).*) {
            .RParen, .Eof => break,
            else => {},
        }
        const annotations = file.parseAnnotations(p);
        // Allow `val`/`var` markers in constructor-like params; ignore.
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
            // Required type annotation missing — produce the standard
            // "expected `:`" diagnostic. Anon-fn params legally omit the
            // annotation; the caller passes `allow_no_type = true` for that
            // context.
            _ = expect(p, .Colon, "`:`");
        }
        const ty = if (has_colon or !allow_no_type)
            (types.parseType(p) orelse anyPlaceholder(name.span))
        else
            // No colon and the caller allows it: synthesise an `Any?`
            // placeholder without trying to parse a type.
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

/// Parse a local `val`/`var`. Local properties cannot declare `get`/`set`
/// accessors, so a following `get(...)`/`set(...)` is a separate statement
/// (e.g. a call to a function named `set`) and must not be consumed.
pub fn parseLocalProperty(p: *Parser, flags: ModifierFlags) ?Property {
    return parsePropertyInner(p, flags, false);
}

pub fn parsePropertyWithFlags(p: *Parser, flags: ModifierFlags) ?Property {
    return parsePropertyInner(p, flags, true);
}

fn parsePropertyInner(p: *Parser, flags: ModifierFlags, allow_accessors: bool) ?Property {
    // `suspend` is not a meaningful property modifier, but the stdlib
    // `coroutineContext` intrinsic carries it (under a `@Suppress`). klio runs
    // suspend bodies inline, so the modifier is simply inert on a property
    // rather than an error — accept and ignore it.
    _ = flags.suspend_span;
    const kw_tok = bump(p);
    const mutable = kw_tok.kind == .Keyword and kw_tok.kind.Keyword == .Var;
    skipNl(p);
    // Type parameters on an extension property: `var <T> Box<T>.value: T`.
    // klio erases generics, so the list is parsed for one purpose: when the
    // receiver is a bare type parameter (`val <A : Pipeline<*, …>>
    // A.pluginRegistry`), the property applies to the parameter's upper bound
    // (`Pipeline`), so the receiver is rewritten to that bound below.
    var prop_type_params: []ast.TypeParam = &.{};
    if (is(peekKind(p), .Lt)) {
        prop_type_params = types.parseTypeParams(p, true);
        skipNl(p);
    }
    // A use-site-targeted annotation may prefix the extension receiver
    // (`val @receiver:AccessibleLateinitPropertyLiteral KProperty0<*>.isInitialized`,
    // stdlib Lateinit.kt). Annotations are runtime no-ops here — consume and
    // discard before the receiver type.
    if (peekKind(p).isAt()) {
        _ = file.parseAnnotations(p);
        skipNl(p);
    }
    var receiver_type = parsePropertyReceiver(p) orelse return null;
    // A bare type-parameter receiver resolves to its declared upper bound:
    // `<A : Pipeline<*, …>> A.x` is an extension on `Pipeline`, not on a type
    // named `A`. An unbounded parameter (`<T> T.x`) applies to `Any`.
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
    // Explicit-backing-field clause in the initializer slot, ahead of any
    // `=` / `by`: `field[: Type][= init]`, same line or the next. Local
    // properties (`allow_accessors == false`) cannot declare one — the
    // clause shape is recognized and rejected so `val xs: List<Int>` +
    // `field = …` reports the misuse instead of a stray assignment.
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
        // Initializer-first order: `val x: Int = 5` + `field = 6`. Parsed
        // so the property-initializer-with-field diagnostic can name both.
        if (scanFieldClause(p, false)) |scan| {
            explicit_field = parseFieldClause(p, scan, allow_accessors);
        }
    }
    if (explicit_field != null and delegate == null) {
        // A delegate written after the field clause (`field: Int = 1` +
        // `by lazy { 2 }`) still parses; the checker rejects the pair.
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

/// Result of `scanFieldClause`: where the `field` keyword sits and where
/// any (illegal) modifier list ahead of it begins.
const FieldScan = struct {
    field_idx: usize,
    first_mod_idx: ?usize,
};

/// Modifier soft keywords that users plausibly write ahead of a `field`
/// clause. None are legal there; the parser reports each and moves on.
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

/// Lookahead (across newlines, skipping modifier soft keywords) for an
/// explicit-backing-field clause: the contextual keyword `field` in the
/// initializer slot. Does not advance `p.pos`.
///
/// `require_marker` demands a `:` or `=` right after `field` — used for
/// local properties, where a bare `field` line is an ordinary expression
/// statement (and inside accessor bodies the name is the backing-field
/// expression, so the clause is never recognized there).
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
        // A bare `field` (the field takes the property's type) only reads
        // as a clause when it clearly ends there.
        switch (next) {
            .Newline, .Semicolon, .RBrace, .Eof => {},
            else => return null,
        }
    }
    return .{ .field_idx = i, .first_mod_idx = first_mod };
}

/// Consume and build the field clause `scanFieldClause` located. On a local
/// property the clause is a syntax error: it is reported at the `field`
/// token, consumed for recovery, and dropped (`null`). Modifiers written
/// ahead of `field` are each rejected — the stable surface admits none.
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

/// True when, skipping newlines from the cursor, the next significant
/// token is the soft keyword `by`. Does not advance `p.pos`.
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

/// Parse the optional extension receiver preceding a property name.
/// Returns `.present(null)` when there is no receiver, `.present(ty)` for a
/// receiver, and `.failure` to propagate a parse failure to the caller.
/// At `(`: whether the balanced group is followed by `.` `Ident` — a
/// parenthesized (function-type) extension receiver rather than anything
/// else a declaration could start with.
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
    // A parenthesized function-type receiver: `val (Int.() -> String).baz`,
    // `var <T> (List<T>.() -> T).bar`. The group is a type when a `.` and
    // the property name follow its closing `)`.
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
        // Accumulate the receiver's full dotted class path. `parseType` under
        // suppression takes only the first segment, so a nested receiver
        // (`LineHeightStyle.Alignment.Companion.Saver`) would otherwise lose
        // the middle segments and mis-parse the property name.
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
            // Consume intermediate qualifier segments: an ident followed by
            // `.<ident>` is part of the receiver's class path, not the property
            // name. Stop at `Companion` (handled below) and at the final
            // segment (the property name, followed by the declaration body).
            while (true) {
                const here = peekIdentText(p) orelse break;
                if (std.mem.eql(u8, here, "Companion")) break;
                const k1 = kindAt(p, p.pos + 1) orelse break;
                // `Ident<...>.` — a nested segment carrying generic arguments
                // (`val Map.Entry<K, V>.key`). Fold it like a plain segment,
                // keeping the arguments on the receiver type.
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
        // A Companion-qualified receiver (`String.Companion.foo`, stdlib
        // TextH.kt's `String.Companion.CASE_INSENSITIVE_ORDER`): the receiver
        // type is `<Class>.Companion`, so consume the `Companion .` and keep
        // the following ident as the property name. The receiver collapses to
        // the class type, but the `qualified_path` records `<Class>.Companion`
        // so registration keys it apart from a plain `val <Class>.foo` type
        // extension (which targets instances of `<Class>`, not its companion).
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
        } else if (std.mem.indexOfScalar(u8, path.items, '.') != null) {
            // A multi-segment receiver with no companion (`A.B.foo`): retain the
            // full path so the resolver targets the nested class, not just `A`.
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

/// Result of `scanAccessorModifiers`: the token index of the keyword
/// candidate plus the modifiers seen ahead of it.
const AccessorScan = struct {
    index: usize,
    visibility: ?Visibility,
    inlined: bool,
    had_annotation: bool,
};

/// Lookahead from `from`, skipping newlines and any leading `inline` /
/// visibility modifiers ahead of a `get` / `set` keyword. Returns the token
/// index of the keyword candidate plus the modifiers seen. Does not advance
/// `p.pos`.
fn scanAccessorModifiers(p: *const Parser, from: usize) AccessorScan {
    var i = from;
    while (kindAt(p, i)) |k| {
        if (!is(&k, .Newline)) break;
        i += 1;
    }
    var acc_visibility: ?Visibility = null;
    var acc_inline = false;
    var had_annotation = false;
    // Accept `inline` and / or a visibility modifier in either order ahead of
    // the `get` / `set` keyword. Kotlin allows `inline get()` and
    // `private inline set(v)`; both combinations parse here.
    while (i < p.tokens.len) {
        const tok = p.tokens[i];
        // Scan past an annotation on the accessor (`@InternalAPI set(value)`,
        // `@Composable get()`); the commit path re-parses the leading run into
        // the accessor's `annotations`.
        if (tok.kind.isAt()) {
            had_annotation = true;
            i += 1; // `@`
            // Optional use-site target `@set:Foo` / `@get:Foo`.
            const a = kindAt(p, i);
            const b = kindAt(p, i + 1);
            if (a != null and is(&a.?, .Ident) and b != null and is(&b.?, .Colon)) {
                i += 2;
            }
            // Qualified annotation name: `Ident ('.' Ident)*`.
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
            // Optional `(args)` — skip the balanced parens.
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

/// Getter, setter, and bare-`set` visibility produced by
/// `parsePropertyAccessors`.
const PropertyAccessors = struct {
    getter: ?Accessor,
    setter: ?Accessor,
    setter_visibility: ?Visibility,
};

/// Parse the optional `get` / `set` accessors that may follow a property, in
/// either order and across newlines. Returns the getter, setter, and any
/// bare-`set` visibility, or `null` to propagate a parse failure.
fn parsePropertyAccessors(p: *Parser) ?PropertyAccessors {
    var getter: ?Accessor = null;
    var setter: ?Accessor = null;
    var setter_visibility: ?Visibility = null;
    while (true) {
        const save = p.pos;
        const scan = scanAccessorModifiers(p, p.pos);
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
        // Bare `private set` (no parens) is valid: it leaves the default
        // accessor in place but restricts visibility. We synthesize a bodyless
        // accessor whose presence carries only the visibility.
        const is_bodyless = !(next != null and is(&next.?, .LParen));
        if (is_bodyless and acc_visibility == null and !acc_inline and !scan.had_annotation) {
            // No modifier, no annotation, and no `(` — not an accessor
            // (e.g. a following statement that calls a `get`/`set`
            // function). Bail.
            break;
        }
        // Commit — consume the newlines, optional vis/annotation, and accessor.
        // The leading annotations are parsed for real (`@Composable get()`
        // marks a composable accessor the compose pass must transform); the
        // scanner's index then lands on the `get`/`set` ident regardless of
        // any modifier interleaving.
        p.pos = save;
        skipNl(p);
        const acc_annotations = file.parseAnnotations(p);
        p.pos = i;
        const start_span = bump(p).span; // get / set
        if (is_bodyless) {
            // Bodyless accessor (no `(...)`):
            //   - `private set` restricts the setter's visibility while the
            //     default accessor stays in effect;
            //   - an abstract `@TestOnly get` / `get` (interface member or
            //     `abstract`/`expect` property) declares the accessor without
            //     a body. Either way there is nothing to synthesize here.
            if (is_set) {
                if (acc_visibility) |v| setter_visibility = v;
            }
            continue;
        }
        _ = expect(p, .LParen, "`(`") orelse return null;
        var acc_params: std.ArrayList(Ident) = .empty;
        if (!is(peekKind(p), .RParen)) {
            // A setter parameter may carry annotations:
            // `set(@Suppress("AutoBoxing") dateMillis) { ... }`.
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
