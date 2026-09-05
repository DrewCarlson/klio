//! Type-reference parsing: simple/qualified types, nullable markers,
//! generic arguments, function types, and type parameters.
//!
//! Free functions over `*Parser`.

const std = @import("std");

const ast = @import("ast");
const lexer = @import("lexer");
const span = @import("span");

const root = @import("parser.zig");
const support = @import("support.zig");
const file = @import("file.zig");

const Parser = root.Parser;

const FunctionTypeRef = ast.FunctionTypeRef;
const Ident = ast.Ident;
const TypeArg = ast.TypeArg;
const TypeParam = ast.TypeParam;
const TypeRef = ast.TypeRef;
const Variance = ast.Variance;
const WhereBound = ast.WhereBound;

const Keyword = lexer.Keyword;
const Token = lexer.Token;
const TokenKind = lexer.TokenKind;
const Span = span.Span;

fn peekKind(p: *const Parser) TokenKind {
    return support.peekKind(p).*;
}

fn isKind(k: TokenKind, tag: std.meta.Tag(TokenKind)) bool {
    return std.meta.activeTag(k) == tag;
}

/// Parse a `<T, out U : Foo, reified V>`-style type-parameter list.
/// Caller has verified the cursor is at `<`. Returns the parsed params;
/// `reified` is only accepted when `allow_reified` is set (i.e. on
/// functions, not classes).
pub fn parseTypeParams(p: *Parser, allow_reified: bool) []TypeParam {
    if (!isKind(peekKind(p), .Lt)) {
        return &.{};
    }
    _ = support.bump(p);
    var params: std.ArrayList(TypeParam) = .empty;
    while (true) {
        support.skipNl(p);
        const annotations = file.parseAnnotations(p);
        switch (peekKind(p)) {
            .Gt, .Eof => break,
            else => {},
        }
        const start = support.currentSpan(p);
        var variance = Variance.Invariant;
        var is_reified = false;
        while (true) {
            if (peekKind(p) == .Keyword and peekKind(p).Keyword == .In) {
                _ = support.bump(p);
                support.skipNl(p);
                variance = .In;
                continue;
            }
            const id_text = support.peekIdentText(p);
            if (id_text != null and std.mem.eql(u8, id_text.?, "out")) {
                _ = support.bump(p);
                support.skipNl(p);
                variance = .Out;
            } else if (allow_reified and id_text != null and std.mem.eql(u8, id_text.?, "reified")) {
                _ = support.bump(p);
                support.skipNl(p);
                is_reified = true;
            } else {
                break;
            }
        }
        const name = support.parseIdent(p, "type parameter name") orelse break;
        var upper_bound: ?TypeRef = null;
        support.skipNl(p);
        if (isKind(peekKind(p), .Colon)) {
            _ = support.bump(p);
            support.skipNl(p);
            upper_bound = parseType(p);
        }
        const end = if (upper_bound) |ub| ub.span else name.span;
        params.append(p.allocator, .{
            .name = name,
            .variance = variance,
            .upper_bound = upper_bound,
            .is_reified = is_reified,
            .annotations = annotations,
            .span = start.join(end),
        }) catch @panic("OOM in parseTypeParams");
        support.skipNl(p);
        if (isKind(peekKind(p), .Comma)) {
            _ = support.bump(p);
        } else {
            break;
        }
    }
    _ = support.expect(p, .Gt, "`>`");
    return params.toOwnedSlice(p.allocator) catch @panic("OOM in parseTypeParams");
}

/// Parse a `where T : Foo, T : Bar` clause. Returns an empty slice when
/// the cursor is not at `where`.
pub fn parseWhereClause(p: *Parser) []WhereBound {
    var bounds: std.ArrayList(WhereBound) = .empty;
    // Look across leading newlines without committing — `where` may sit
    // on the next line, but if it isn't there we must leave the newlines
    // alone so they continue serving as statement separators.
    var i = p.pos;
    while (i < p.tokens.len and isKind(p.tokens[i].kind, .Newline)) {
        i += 1;
    }
    const is_where = i < p.tokens.len and
        isKind(p.tokens[i].kind, .Ident) and
        std.mem.eql(u8, support.text(p, p.tokens[i].span), "where");
    if (!is_where) {
        return &.{};
    }
    p.pos = i;
    _ = support.bump(p);
    while (true) {
        support.skipNl(p);
        const name = support.parseIdent(p, "type parameter name") orelse break;
        const start = name.span;
        _ = support.expect(p, .Colon, "`:`");
        support.skipNl(p);
        const ty = parseType(p) orelse break;
        const sp = start.join(ty.span);
        bounds.append(p.allocator, .{
            .name = name,
            .bound = ty,
            .span = sp,
        }) catch @panic("OOM in parseWhereClause");
        support.skipNl(p);
        if (isKind(peekKind(p), .Comma)) {
            _ = support.bump(p);
        } else {
            break;
        }
    }
    return bounds.toOwnedSlice(p.allocator) catch @panic("OOM in parseWhereClause");
}

/// Parse `<TypeArg, …>` (with optional `*`, `out`, `in` projection on
/// each arg). Caller has verified the cursor is at `<`. Used by
/// `parseSimpleType` to capture generic instantiations like
/// `List<out Any>`.
pub fn parseTypeArgs(p: *Parser) []TypeArg {
    if (!isKind(peekKind(p), .Lt)) {
        return &.{};
    }
    // Type arguments are fully bracketed by `<...>`, so a qualified path inside
    // one (`Vec<A.B>`, `MutableVector<Modifier.Node>`) never conflicts with a
    // trailing `.method` the caller is holding `suppress_qualified_path` for
    // (an extension receiver). Always allow qualified paths within the args.
    const saved_sqp = p.suppress_qualified_path;
    p.suppress_qualified_path = false;
    defer p.suppress_qualified_path = saved_sqp;
    _ = support.bump(p);
    var args: std.ArrayList(TypeArg) = .empty;
    while (true) {
        support.skipNl(p);
        switch (peekKind(p)) {
            .Gt, .Eof => break,
            else => {},
        }
        const start = support.currentSpan(p);
        if (isKind(peekKind(p), .Star)) {
            const s = support.bump(p);
            args.append(p.allocator, .{
                .variance = .Invariant,
                .is_star = true,
                .ty = .{
                    .name = .{ .name = "*", .span = s.span },
                    .nullable = false,
                    .span = s.span,
                    .type_args = &.{},
                    .function = null,
                    .definitely_non_null = false,
                    .annotations = &.{},
                    .qualified_path = null,
                },
                .span = s.span,
            }) catch @panic("OOM in parseTypeArgs");
        } else {
            var variance = Variance.Invariant;
            if (peekKind(p) == .Keyword and peekKind(p).Keyword == .In) {
                _ = support.bump(p);
                support.skipNl(p);
                variance = .In;
            } else {
                const id_text = support.peekIdentText(p);
                if (id_text != null and std.mem.eql(u8, id_text.?, "out")) {
                    _ = support.bump(p);
                    support.skipNl(p);
                    variance = .Out;
                }
            }
            const t = parseType(p) orelse break;
            const sp = start.join(t.span);
            args.append(p.allocator, .{
                .variance = variance,
                .is_star = false,
                .ty = t,
                .span = sp,
            }) catch @panic("OOM in parseTypeArgs");
        }
        support.skipNl(p);
        if (isKind(peekKind(p), .Comma)) {
            _ = support.bump(p);
        } else {
            break;
        }
    }
    _ = support.expect(p, .Gt, "`>`");
    return args.toOwnedSlice(p.allocator) catch @panic("OOM in parseTypeArgs");
}

/// Parse a call-site type-arg list like `foo<String>(…)`. Variance
/// markers (`in`/`out`) on call-site type args are nonsensical and
/// silently dropped (Kotlin rejects them as a separate diagnostic). `*`
/// star-projection at a call site is also dropped — call-site star is
/// only meaningful in *types*, not in invocation generics.
pub fn parseCallTypeArgs(p: *Parser) []TypeRef {
    if (!isKind(peekKind(p), .Lt)) {
        return &.{};
    }
    _ = support.bump(p);
    var args: std.ArrayList(TypeRef) = .empty;
    while (true) {
        support.skipNl(p);
        switch (peekKind(p)) {
            .Gt, .Eof => break,
            else => {},
        }
        if (isKind(peekKind(p), .Star)) {
            const s = support.bump(p);
            args.append(p.allocator, .{
                .name = .{ .name = "*", .span = s.span },
                .nullable = false,
                .span = s.span,
                .type_args = &.{},
                .function = null,
                .definitely_non_null = false,
                .annotations = &.{},
                .qualified_path = null,
            }) catch @panic("OOM in parseCallTypeArgs");
        } else if (isKind(peekKind(p), .Ident) and
            std.mem.eql(u8, support.text(p, support.currentSpan(p)), "_"))
        {
            // Underscore type argument — placeholder for partial
            // inference. Recorded as a TypeRef whose name is `_`;
            // downstream typeck treats this as Type::Unresolved and lets
            // the surrounding inference flow set it.
            const s = support.bump(p);
            args.append(p.allocator, .{
                .name = .{ .name = "_", .span = s.span },
                .nullable = false,
                .span = s.span,
                .type_args = &.{},
                .function = null,
                .definitely_non_null = false,
                .annotations = &.{},
                .qualified_path = null,
            }) catch @panic("OOM in parseCallTypeArgs");
        } else {
            const id_text = support.peekIdentText(p);
            if ((peekKind(p) == .Keyword and peekKind(p).Keyword == .In) or
                (id_text != null and std.mem.eql(u8, id_text.?, "out")))
            {
                _ = support.bump(p);
                support.skipNl(p);
            }
            const t = parseType(p) orelse break;
            args.append(p.allocator, t) catch @panic("OOM in parseCallTypeArgs");
        }
        support.skipNl(p);
        if (isKind(peekKind(p), .Comma)) {
            _ = support.bump(p);
        } else {
            break;
        }
    }
    _ = support.expect(p, .Gt, "`>`");
    return args.toOwnedSlice(p.allocator) catch @panic("OOM in parseCallTypeArgs");
}

pub fn parseType(p: *Parser) ?TypeRef {
    support.skipNl(p);
    // Contextual function type: `context(A, B) [suspend] [R.](P) -> T`. The
    // leading `context(...)` block carries types only (named entries are
    // rejected); the whole type is equivalent to the flattened function type.
    if (support.peekKeywordIdent(p, "context") and
        p.pos + 1 < p.tokens.len and isKind(p.tokens[p.pos + 1].kind, .LParen))
    {
        const ctx = parseFunctionTypeContextBlock(p);
        support.skipNl(p);
        const rest = parseType(p) orelse return null;
        if (rest.function) |ft| {
            ft.context_params = ctx;
        }
        return rest;
    }
    // Soft-keyword `suspend` before a function type — accepted on the
    // type-reference syntax even when downstream enforcement of the
    // suspending colouring at this site is a future addition.
    var is_suspend = false;
    if (support.peekIdentText(p)) |it| {
        if (std.mem.eql(u8, it, "suspend")) {
            // Only consume as a type modifier when followed by `(` or by an
            // identifier that begins a receiver type — otherwise we'd eat a
            // type literally named `suspend`.
            const next: ?TokenKind = if (p.pos + 1 < p.tokens.len) p.tokens[p.pos + 1].kind else null;
            if (next) |n| {
                if (isKind(n, .LParen) or isKind(n, .Ident)) {
                    _ = support.bump(p);
                    support.skipNl(p);
                    is_suspend = true;
                }
            }
        }
    }
    // `suspend context(A) (P) -> R`: the context block may follow the
    // `suspend` modifier as well as precede it.
    if (is_suspend and support.peekKeywordIdent(p, "context") and
        p.pos + 1 < p.tokens.len and isKind(p.tokens[p.pos + 1].kind, .LParen))
    {
        const ctx = parseFunctionTypeContextBlock(p);
        support.skipNl(p);
        const rest = parseType(p) orelse return null;
        if (rest.function) |ft| {
            ft.context_params = ctx;
            ft.is_suspend = true;
        }
        return rest;
    }
    // Type-use-site annotations: `@Foo @Bar Baz` / `@UnsafeVariance T`.
    // Accept zero or more annotation sets and stash them on the
    // resulting TypeRef. A `(` after the annotation name belongs to a
    // function type (`@Composable () -> Unit`), not annotation args.
    const type_annotations = file.parseTypeAnnotations(p);
    support.skipNl(p);
    const start_span = support.currentSpan(p);
    var ty: TypeRef = if (isKind(peekKind(p), .LParen))
        (parseParensOrFunctionType(p, start_span) orelse return null)
    else
        (parseSimpleType(p) orelse return null);
    if (type_annotations.len != 0) {
        if (ty.annotations.len == 0) {
            ty.annotations = type_annotations;
        } else {
            const combined = p.allocator.alloc(ast.Annotation, ty.annotations.len + type_annotations.len) catch @panic("OOM in parseType");
            @memcpy(combined[0..ty.annotations.len], ty.annotations);
            @memcpy(combined[ty.annotations.len..], type_annotations);
            ty.annotations = combined;
        }
    }
    // Trailing `?` makes the whole type nullable.
    if (peekKind(p).isQuestion()) {
        const q = support.bump(p);
        ty.nullable = true;
        ty.span = ty.span.join(q.span);
    }
    // Definitely-non-nullable type: `T & Any`. Per the language rules only
    // valid when T is a type parameter, but we accept the shape here and
    // let typeck diagnose non-type-parameter receivers.
    {
        const save_pos = p.pos;
        var i = p.pos;
        while (i < p.tokens.len and isKind(p.tokens[i].kind, .Newline)) {
            i += 1;
        }
        if (i < p.tokens.len and isKind(p.tokens[i].kind, .Amp)) {
            p.pos = i;
            _ = support.bump(p); // `&`
            support.skipNl(p);
            const rhs_start = support.currentSpan(p);
            const rhs = parseSimpleType(p) orelse {
                p.pos = save_pos;
                return ty;
            };
            if (!std.mem.eql(u8, rhs.name.name, "Any") or rhs.nullable) {
                support.err(
                    p,
                    "E0015",
                    "right-hand side of `&` in a definitely-non-nullable type must be `Any`",
                    rhs_start.join(rhs.span),
                );
            }
            ty.definitely_non_null = true;
            ty.span = ty.span.join(rhs.span);
        }
    }
    // Receiver-typed function type: `T.(params) -> R`. We look for `.`
    // immediately followed by `(`; bare `.` after a type would be a path
    // continuation handled elsewhere. A nullable receiver `T?.(params) -> R`
    // lexes its `?.` as a single `QuestionDot`; accept that form too and
    // record the receiver as nullable.
    const recv_qdot = isKind(peekKind(p), .QuestionDot);
    if ((isKind(peekKind(p), .Dot) or recv_qdot) and
        p.pos + 1 < p.tokens.len and isKind(p.tokens[p.pos + 1].kind, .LParen))
    {
        if (recv_qdot) ty.nullable = true;
        _ = support.bump(p); // '.' or '?.'
        const parsed = parseFunctionTypeParams(p) orelse return null;
        const params = parsed.params;
        const rp = parsed.rp;
        support.skipNl(p);
        const arrow = support.expect(p, .Arrow, "`->`") orelse return null;
        support.skipNl(p);
        const ret = parseType(p) orelse return null;
        const ret_span = ret.span;
        const sp = ty.span.join(ret_span);
        const func = p.allocator.create(FunctionTypeRef) catch @panic("OOM in parseType");
        // Annotations written before the receiver head annotate the whole
        // function type (`@Composable R.() -> Unit`), not the receiver:
        // hoist them onto the outer TypeRef so `isComposable`-style
        // consumers see them.
        var recv_ty = ty;
        recv_ty.annotations = &.{};
        func.* = .{
            .receiver = recv_ty,
            .params = params,
            .ret = ret,
            .is_suspend = is_suspend,
            .span = rp.span.join(arrow.span).join(ret_span),
        };
        return TypeRef{
            .name = .{ .name = "<function>", .span = sp },
            .nullable = false,
            .span = sp,
            .type_args = &.{},
            .function = func,
            .definitely_non_null = false,
            .annotations = ty.annotations,
            .qualified_path = null,
        };
    }
    // Propagate `suspend` onto the parens-form function type when one
    // was produced. If `suspend` was claimed but no function type
    // materialised, we silently drop it (parity-safe; lambdas don't
    // care).
    if (is_suspend) {
        if (ty.function) |f| {
            f.is_suspend = true;
        }
    }
    return ty;
}

/// Parse a simple (named) type with optional generic arguments. Does
/// NOT consume a trailing `?` — that's the caller's job so function-type
/// nullability composes correctly.
pub fn parseSimpleType(p: *Parser) ?TypeRef {
    const first = support.parseIdent(p, "type") orelse return null;
    var name = first;
    var path: std.ArrayList(u8) = .empty;
    path.appendSlice(p.allocator, first.name) catch @panic("OOM in parseSimpleType");
    var segments: usize = 1;
    var type_args: []TypeArg = if (isKind(peekKind(p), .Lt))
        parseTypeArgs(p)
    else
        &.{};
    // Qualified / nested type path: `A.B.C` (each segment may carry
    // its own type arguments, e.g. `Outer<T>.Inner`). klio resolves
    // types by simple name against imports + known packages, so the
    // path collapses to its last segment (the package / outer-class
    // qualifier is the namespace the resolver already keys on); the
    // full dotted path is retained in `qualified_path` for the cases
    // that need it (a nested supertype vs a same-named top-level class).
    // Stop before `.(` — that is a receiver-function type
    // (`A.B.() -> R`), consumed by `parseType`.
    while (!p.suppress_qualified_path and
        isKind(peekKind(p), .Dot) and
        p.pos + 1 < p.tokens.len and isKind(p.tokens[p.pos + 1].kind, .Ident))
    {
        _ = support.bump(p); // '.'
        name = support.parseIdent(p, "type") orelse return null;
        path.append(p.allocator, '.') catch @panic("OOM in parseSimpleType");
        path.appendSlice(p.allocator, name.name) catch @panic("OOM in parseSimpleType");
        segments += 1;
        type_args = if (isKind(peekKind(p), .Lt))
            parseTypeArgs(p)
        else
            &.{};
    }
    const end = p.tokens[if (p.pos == 0) 0 else p.pos - 1].span;
    const qualified_path: ?[]const u8 = if (segments > 1)
        (path.toOwnedSlice(p.allocator) catch @panic("OOM in parseSimpleType"))
    else
        null;
    return TypeRef{
        .name = name,
        .nullable = false,
        .span = first.span.join(end),
        .type_args = type_args,
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = qualified_path,
    };
}

/// userType form `simpleUserType ('.' simpleUserType)*`. Used at sites
/// that may name a nested classifier (`is Outer.Inner`, `as
/// Outer.Inner`, `catch (e: Outer.Inner)`). Calls `parseType` for the
/// leading head (which handles nullability, function-type shape, and
/// type arguments) then folds any trailing `.Ident` segments into the
/// name. Regular `parseType` returns the bare leading segment so that
/// extension-function syntax like `operator fun Foo.bar()` keeps the
/// trailing name as the function's identity.
pub fn parseQualifiedType(p: *Parser) ?TypeRef {
    var head = parseType(p) orelse return null;
    // Function types and nullable suffixes block further dot folding.
    if (head.function != null or head.nullable) {
        return head;
    }
    var start = head.span;
    while (isKind(peekKind(p), .Dot)) {
        const next: ?TokenKind = if (p.pos + 1 < p.tokens.len) p.tokens[p.pos + 1].kind else null;
        if (next == null or !isKind(next.?, .Ident)) {
            break;
        }
        _ = support.bump(p); // '.'
        const seg = support.parseIdent(p, "type segment") orelse break;
        const dotted = std.fmt.allocPrint(p.allocator, "{s}.{s}", .{ head.name.name, seg.name }) catch @panic("OOM in parseQualifiedType");
        const new_name = Ident{
            .name = dotted,
            .span = start.join(seg.span),
        };
        start = new_name.span;
        const type_args: []TypeArg = if (isKind(peekKind(p), .Lt))
            parseTypeArgs(p)
        else
            &.{};
        head = TypeRef{
            .name = new_name,
            .nullable = false,
            .span = start,
            .type_args = type_args,
            .function = null,
            .definitely_non_null = false,
            .annotations = &.{},
            .qualified_path = dotted,
        };
    }
    // Trailing nullable suffix after dotted form: `S.A?`.
    if (peekKind(p).isQuestion()) {
        const q = support.bump(p);
        head.nullable = true;
        head.span = head.span.join(q.span);
    }
    return head;
}

/// At `(`. Either:
///   - `(T)` — parenthesized type (returns the inner type).
///   - `(T1, T2, ...) -> R` — function type parameters.
pub fn parseParensOrFunctionType(p: *Parser, start: Span) ?TypeRef {
    const lp = support.bump(p); // '('
    var items: std.ArrayList(TypeRef) = .empty;
    var saw_comma = false;
    while (true) {
        support.skipNl(p);
        if (isKind(peekKind(p), .RParen)) {
            break;
        }
        // Allow `name: Type` shape inside function-type params by
        // tolerating an identifier followed by `:`.
        if (isKind(peekKind(p), .Ident)) {
            const save = p.pos;
            _ = support.bump(p);
            support.skipNl(p);
            if (isKind(peekKind(p), .Colon)) {
                _ = support.bump(p);
                support.skipNl(p);
            } else {
                p.pos = save;
            }
        }
        const t = parseType(p) orelse break;
        items.append(p.allocator, t) catch @panic("OOM in parseParensOrFunctionType");
        support.skipNl(p);
        if (isKind(peekKind(p), .Comma)) {
            _ = support.bump(p);
            saw_comma = true;
        } else {
            break;
        }
    }
    const rp = support.expect(p, .RParen, "`)`") orelse return null;
    support.skipNl(p);
    if (isKind(peekKind(p), .Arrow)) {
        // Function type.
        const arrow = support.bump(p);
        support.skipNl(p);
        const ret = parseType(p) orelse return null;
        const ret_span = ret.span;
        const sp = start.join(ret_span);
        const params = items.toOwnedSlice(p.allocator) catch @panic("OOM in parseParensOrFunctionType");
        const func = p.allocator.create(FunctionTypeRef) catch @panic("OOM in parseParensOrFunctionType");
        func.* = .{
            .receiver = null,
            .params = params,
            .ret = ret,
            .is_suspend = false,
            .span = lp.span.join(arrow.span).join(ret_span),
        };
        return TypeRef{
            .name = .{ .name = "<function>", .span = sp },
            .nullable = false,
            .span = sp,
            .type_args = &.{},
            .function = func,
            .definitely_non_null = false,
            .annotations = &.{},
            .qualified_path = null,
        };
    } else if (items.items.len == 1 and !saw_comma) {
        // Parenthesized type.
        var inner = items.items[0];
        inner.span = lp.span.join(rp.span);
        return inner;
    } else {
        const sp = lp.span.join(rp.span);
        support.err(
            p,
            "E0003",
            "expected `->` after function-type parameter list",
            sp,
        );
        return null;
    }
}

/// Result of `parseFunctionTypeParams`: the parameter type list plus
/// both paren tokens.
pub const FunctionTypeParams = struct {
    params: []TypeRef,
    lp: Token,
    rp: Token,
};

/// Parse the leading `context(A, B)` block of a contextual function type.
/// Types only — a named entry (`name: Type`, `_: Type`) is rejected with
/// `NAMED_CONTEXT_PARAMETER_IN_FUNCTION_TYPE` but its type is still parsed.
/// The cursor is at `context`; the `(` follows.
pub fn parseFunctionTypeContextBlock(p: *Parser) []TypeRef {
    _ = support.bump(p); // `context`
    _ = support.bump(p); // `(`
    var items: std.ArrayList(TypeRef) = .empty;
    while (true) {
        support.skipNl(p);
        if (isKind(peekKind(p), .RParen)) break;
        // Reject a named entry `name : Type` / `_ : Type`.
        if (isKind(peekKind(p), .Ident)) {
            var j = p.pos + 1;
            while (j < p.tokens.len and isKind(p.tokens[j].kind, .Newline)) j += 1;
            if (j < p.tokens.len and isKind(p.tokens[j].kind, .Colon)) {
                const nm = support.currentSpan(p);
                _ = support.bump(p); // name
                support.skipNl(p);
                _ = support.bump(p); // `:`
                support.skipNl(p);
                const ty = parseType(p) orelse break;
                support.errWithFactory(
                    p,
                    &@import("diagnostics").generated.NAMED_CONTEXT_PARAMETER_IN_FUNCTION_TYPE,
                    "E0306",
                    "Named context parameters in function types are unsupported. Use syntax 'context(Type)' instead.",
                    nm.join(ty.span),
                );
                items.append(p.allocator, ty) catch @panic("OOM");
                support.skipNl(p);
                if (isKind(peekKind(p), .Comma)) {
                    _ = support.bump(p);
                    continue;
                }
                break;
            }
        }
        const t = parseType(p) orelse break;
        items.append(p.allocator, t) catch @panic("OOM");
        support.skipNl(p);
        if (isKind(peekKind(p), .Comma)) {
            _ = support.bump(p);
        } else break;
    }
    _ = support.expect(p, .RParen, "`)`");
    return items.toOwnedSlice(p.allocator) catch @panic("OOM");
}

/// Parse `( T1, T2, ... )` returning the list of parameter types and
/// both paren spans. Used for the receiver-typed function-type tail.
pub fn parseFunctionTypeParams(p: *Parser) ?FunctionTypeParams {
    const lp = support.expect(p, .LParen, "`(`") orelse return null;
    var items: std.ArrayList(TypeRef) = .empty;
    while (true) {
        support.skipNl(p);
        if (isKind(peekKind(p), .RParen)) {
            break;
        }
        if (isKind(peekKind(p), .Ident)) {
            const save = p.pos;
            _ = support.bump(p);
            support.skipNl(p);
            if (isKind(peekKind(p), .Colon)) {
                _ = support.bump(p);
                support.skipNl(p);
            } else {
                p.pos = save;
            }
        }
        const t = parseType(p) orelse break;
        items.append(p.allocator, t) catch @panic("OOM in parseFunctionTypeParams");
        support.skipNl(p);
        if (isKind(peekKind(p), .Comma)) {
            _ = support.bump(p);
        } else {
            break;
        }
    }
    const rp = support.expect(p, .RParen, "`)`") orelse return null;
    const params = items.toOwnedSlice(p.allocator) catch @panic("OOM in parseFunctionTypeParams");
    return FunctionTypeParams{ .params = params, .lp = lp, .rp = rp };
}

// ---------- identifiers ----------

/// Generic type arguments at a call site (`f<T>(...)` or `f<T> { … }`).
/// We don't model the type args, just consume them so the trailing call
/// or trailing-lambda parses. The disambiguator: scan from `<` for a
/// matching `>` (tracking `<`/`>` depth and bailing on tokens that
/// can't appear inside a type list), and only accept when the `>` is
/// immediately followed by `(`, `{`, `.`, `?.`, or `::`.
pub fn trySkipGenericCallArgs(p: *const Parser) bool {
    if (!isKind(peekKind(p), .Lt)) {
        return false;
    }
    var depth: i32 = 0;
    var i = p.pos;
    const max = p.tokens.len;
    while (i < max) {
        const kind = p.tokens[i].kind;
        switch (kind) {
            .Lt => depth += 1,
            .Gt => {
                depth -= 1;
                if (depth == 0) {
                    const next: ?TokenKind = if (i + 1 < p.tokens.len) p.tokens[i + 1].kind else null;
                    if (next) |n| {
                        return switch (n) {
                            .LParen, .LBrace, .Dot, .QuestionDot, .ColonColon => true,
                            // `Array<*>?::member` — a nullable-receiver
                            // callable reference: `>` then `?` then `::`.
                            .QuestNoWs, .QuestWs => blk: {
                                const after: ?TokenKind = if (i + 2 < p.tokens.len) p.tokens[i + 2].kind else null;
                                break :blk after != null and std.meta.activeTag(after.?) == .ColonColon;
                            },
                            // `f<T> label@{ … }` — a generic call whose
                            // trailing lambda carries a label (`>` then an
                            // identifier, an `@`, and the lambda `{`).
                            // Without this the `<`/`>` are read as comparison
                            // operators (`suspendCancellableCoroutine<Unit>
                            // sc@{ … }`).
                            .Ident => blk: {
                                const t1: ?TokenKind = if (i + 2 < p.tokens.len) p.tokens[i + 2].kind else null;
                                const t2: ?TokenKind = if (i + 3 < p.tokens.len) p.tokens[i + 3].kind else null;
                                break :blk t1 != null and t1.?.isAt() and
                                    t2 != null and std.meta.activeTag(t2.?) == .LBrace;
                            },
                            // `f<A, B>` then a line break then the trailing
                            // lambda. Kotlin lets a trailing lambda start on
                            // the following line, so the `<`/`>` still open a
                            // type-argument list — reading them as comparisons
                            // makes the type list itself (`Map.Entry<K, V>`,
                            // `out T`) unparseable.
                            .Newline => blk: {
                                var j = i + 1;
                                while (j < p.tokens.len and std.meta.activeTag(p.tokens[j].kind) == .Newline) j += 1;
                                break :blk j < p.tokens.len and std.meta.activeTag(p.tokens[j].kind) == .LBrace;
                            },
                            else => false,
                        };
                    }
                    return false;
                }
            },
            // Tokens that wouldn't appear in a type list — bail out.
            // `*` inside the angle brackets is a star projection
            // (`Foo<List<*>>()`), not multiplication; only bail on
            // it at depth 0 where it would be an arithmetic op.
            .Star => if (depth == 0) return false,
            .Eq,
            .Semicolon,
            .Plus,
            .Minus,
            .Slash,
            .Percent,
            .EqEq,
            .BangEq,
            .EqEqEq,
            .BangEqEq,
            .Le,
            .Ge,
            .AmpAmp,
            .PipePipe,
            .Newline,
            .Eof,
            => return false,
            else => {},
        }
        i += 1;
    }
    return false;
}

comptime {
    _ = Parser;
}
