//! Top-level file parsing: package header, imports, top-level
//! declarations, modifier/annotation scanning, and `typealias`.
//!
//! Ported from `parse/file.rs`. The Rust inherent `impl` methods become
//! free functions over `*Parser`; the entry point is `file.parseFile(p)`.

const std = @import("std");

const ast = @import("ast");
const diagnostics = @import("diagnostics");
const lexer = @import("lexer");
const span = @import("span");

const root = @import("parser.zig");
const support = @import("support.zig");
const class = @import("class.zig");
const types = @import("types.zig");
const members = @import("members.zig");
const stmt = @import("stmt.zig");
const expr = @import("expr.zig");

const Parser = root.Parser;
const ClassModifiers = root.ClassModifiers;
const ModifierFlags = root.ModifierFlags;

const Annotation = ast.Annotation;
const AnnotationUseSite = ast.AnnotationUseSite;
const Decl = ast.Decl;
const Expr = ast.Expr;
const Ident = ast.Ident;
const ImportDecl = ast.ImportDecl;
const KotlinFile = ast.KotlinFile;
const PackageHeader = ast.PackageHeader;
const TypeAlias = ast.TypeAlias;
const TypeParam = ast.TypeParam;
const TypeRef = ast.TypeRef;
const Visibility = ast.Visibility;
const Span = span.Span;

const Diagnostic = diagnostics.Diagnostic;
const Keyword = lexer.Keyword;
const TokenKind = lexer.TokenKind;

/// True when the cursor is at `Keyword(want)`.
fn atKeyword(p: *const Parser, want: Keyword) bool {
    return switch (support.peekKind(p).*) {
        .Keyword => |kw| kw == want,
        else => false,
    };
}

/// The kind of the token at offset `off` from the cursor, or `null` when
/// out of range. Mirrors Rust's `self.tokens.get(self.pos + off)`.
fn kindAt(p: *const Parser, off: usize) ?TokenKind {
    const idx = p.pos + off;
    if (idx >= p.tokens.len) return null;
    return p.tokens[idx].kind;
}

/// Span of the last consumed token, mirroring
/// `self.tokens[self.pos.saturating_sub(1)].span`.
fn prevSpan(p: *const Parser) Span {
    const idx = if (p.pos == 0) 0 else p.pos - 1;
    return p.tokens[idx].span;
}

/// Parse the whole compilation unit. Diagnostics accumulate on
/// `p.diagnostics`. Mirrors the Rust `parse_file`, which consumed `self`
/// and returned `(KotlinFile, DiagnosticSink)`.
pub fn parseFile(p: *Parser) KotlinFile {
    support.skipNl(p);
    const start = support.currentSpan(p);

    // File-use-site annotations (`@file:Suppress(...)`,
    // `@file:OptIn(...)`, `@file:JvmName(...)`) precede the
    // package header in Kotlin. Consume them up front; klio
    // doesn't act on them, but the parser must not treat them as
    // a declaration sitting before `package`.
    skipFileAnnotations(p);

    const package = parsePackageHeader(p);
    const imports = parseImports(p);

    var decls: std.ArrayList(Decl) = .empty;
    while (true) {
        stmt.skipStmtSeparators(p);
        if (std.meta.activeTag(support.peekKind(p).*) == .Eof) {
            break;
        }
        if (atKeyword(p, .Package)) {
            const kw_span = support.currentSpan(p);
            const msg = if (package != null)
                "duplicate `package` header; a file may declare at most one package"
            else
                "`package` header must come before any import or declaration";
            support.err(p, "P0045", msg, kw_span);
            // Consume the stray header so parsing can continue.
            _ = parsePackageHeader(p);
            continue;
        }
        if (atKeyword(p, .Import)) {
            const kw_span = support.currentSpan(p);
            support.err(
                p,
                "P0046",
                "`import` directives must appear before any declaration",
                kw_span,
            );
            // Consume the stray import header(s) so parsing can continue.
            _ = parseImports(p);
            continue;
        }
        if (parseTopDecl(p)) |d| {
            decls.append(p.allocator, d) catch @panic("OOM in parseFile");
        } else {
            support.recoverToTopLevel(p);
        }
    }
    const end = support.currentSpan(p);
    return .{
        .package = package,
        .imports = imports,
        .decls = decls.toOwnedSlice(p.allocator) catch @panic("OOM in parseFile"),
        .span = start.join(end),
    };
}

pub fn parsePackageHeader(p: *Parser) ?PackageHeader {
    support.skipNl(p);
    if (!atKeyword(p, .Package)) {
        return null;
    }
    const pkg_tok = support.bump(p);
    var path: std.ArrayList(Ident) = .empty;
    if (support.parseIdent(p, "package name")) |first| {
        path.append(p.allocator, first) catch @panic("OOM");
    }
    while (std.meta.activeTag(support.peekKind(p).*) == .Dot) {
        _ = support.bump(p);
        if (support.parseIdent(p, "package segment")) |part| {
            path.append(p.allocator, part) catch @panic("OOM");
        } else {
            break;
        }
    }
    const last_span = if (path.items.len > 0) path.items[path.items.len - 1].span else pkg_tok.span;
    const sp = pkg_tok.span.join(last_span);
    return .{
        .path = path.toOwnedSlice(p.allocator) catch @panic("OOM"),
        .span = sp,
    };
}

pub fn parseImports(p: *Parser) []ImportDecl {
    var imports: std.ArrayList(ImportDecl) = .empty;
    while (true) {
        support.skipNl(p);
        if (!atKeyword(p, .Import)) {
            break;
        }
        const kw = support.bump(p);
        var path: std.ArrayList(Ident) = .empty;
        var wildcard = false;
        support.skipNl(p);
        if (std.meta.activeTag(support.peekKind(p).*) == .Ident) {
            const tok = support.bump(p);
            path.append(p.allocator, .{
                .name = support.identName(p, tok.span),
                .span = tok.span,
            }) catch @panic("OOM");
        } else {
            support.err(p, "P0047", "malformed import: missing path", kw.span);
        }
        while (std.meta.activeTag(support.peekKind(p).*) == .Dot) {
            const dot = support.bump(p);
            if (std.meta.activeTag(support.peekKind(p).*) == .Star) {
                _ = support.bump(p);
                wildcard = true;
                break;
            }
            support.skipNl(p);
            if (std.meta.activeTag(support.peekKind(p).*) == .Ident) {
                const tok = support.bump(p);
                path.append(p.allocator, .{
                    .name = support.identName(p, tok.span),
                    .span = tok.span,
                }) catch @panic("OOM");
            } else {
                support.err(
                    p,
                    "P0047",
                    "malformed import: trailing `.` with no segment",
                    dot.span,
                );
                break;
            }
        }
        var alias: ?Ident = null;
        if (atKeyword(p, .As)) {
            const as_tok = support.bump(p);
            const alias_ident = support.parseIdent(p, "import alias");
            if (wildcard) {
                const sp = if (alias_ident) |i| as_tok.span.join(i.span) else as_tok.span;
                support.err(
                    p,
                    "P0044",
                    "wildcard import cannot be renamed; remove `as` or replace `*` with a name",
                    sp,
                );
            }
            alias = alias_ident;
        }
        const end = prevSpan(p);
        imports.append(p.allocator, .{
            .path = path.toOwnedSlice(p.allocator) catch @panic("OOM"),
            .alias = alias,
            .wildcard = wildcard,
            .span = kw.span.join(end),
        }) catch @panic("OOM");
    }
    return imports.toOwnedSlice(p.allocator) catch @panic("OOM");
}

pub fn parseTopDecl(p: *Parser) ?Decl {
    const flags = skipModifiersWithFlags(p);
    switch (support.peekKind(p).*) {
        .Keyword => |kw| switch (kw) {
            .Fun => {
                // `fun interface Foo { … }` — SAM-conversion-eligible interface.
                const next = kindAt(p, 1);
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
                    );
                    if (c) |cls| return Decl{ .Class = cls };
                    return null;
                }
                if (members.parseFun(p, flags)) |f| return Decl{ .Function = f };
                return null;
            },
            .Val, .Var => {
                if (members.parsePropertyWithFlags(p, flags)) |prop| {
                    const pp = p.allocator.create(ast.Property) catch @panic("OOM");
                    pp.* = prop;
                    return Decl{ .Property = pp };
                }
                return null;
            },
            .Class, .Interface => {
                const visibility = flags.visibility;
                const annotations = flags.annotations.items;
                // `inline class` is the deprecated alias for `value class`.
                // When the user wrote `inline` on a class declaration, promote
                // it to `is_value` and emit a deprecation warning.
                const is_value = flags.is_value or flags.is_inline;
                if (flags.is_inline and !flags.is_value) {
                    if (flags.inline_span) |sp| {
                        var d = Diagnostic.warning(
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
                );
                if (c) |cls| return Decl{ .Class = cls };
                return null;
            },
            .Object => {
                if (flags.is_companion) {
                    const c = class.parseCompanionObjectAsClass(p, flags.visibility, flags.annotations.items);
                    if (c) |cls| return Decl{ .Class = cls };
                    return null;
                } else {
                    const o = class.parseObject(
                        p,
                        flags.is_data,
                        flags.is_expect,
                        flags.is_actual,
                        flags.visibility,
                    );
                    if (o) |obj| return Decl{ .Object = obj };
                    return null;
                }
            },
            .Typealias => {
                if (parseTypealias(p, flags.visibility, flags.annotations.items)) |ta| {
                    return Decl{ .TypeAlias = ta };
                }
                return null;
            },
            else => {
                const sp = support.currentSpan(p);
                support.err(p, "E0002", "expected top-level declaration", sp);
                return null;
            },
        },
        else => {
            const sp = support.currentSpan(p);
            support.err(p, "E0002", "expected top-level declaration", sp);
            return null;
        },
    }
}

pub fn parseTypealias(
    p: *Parser,
    visibility: Visibility,
    annotations: []Annotation,
) ?TypeAlias {
    const kw = support.bump(p); // `typealias`
    const name = support.parseIdent(p, "typealias name") orelse return null;
    support.skipNl(p);
    var type_params: []TypeParam = &.{};
    if (std.meta.activeTag(support.peekKind(p).*) == .Lt) {
        type_params = types.parseTypeParams(p, false);
    }
    support.skipNl(p);
    _ = support.expect(p, .Eq, "`=`") orelse return null;
    support.skipNl(p);
    const target = types.parseType(p) orelse return null;
    const sp = kw.span.join(target.span);
    return .{
        .name = name,
        .type_params = type_params,
        .target = target,
        .visibility = visibility,
        .annotations = annotations,
        .span = sp,
    };
}

/// Recognize leading annotations and soft modifiers, capturing the flags
/// that affect how the declaration is parsed (`data`, `companion`).
pub fn skipModifiersWithFlags(p: *Parser) ModifierFlags {
    var flags = ModifierFlags{};
    while (true) {
        support.skipNl(p);
        if (support.peekKind(p).*.isAt()) {
            if (parseAnnotationSet(p)) |anns| {
                flags.annotations.appendSlice(p.allocator, anns) catch @panic("OOM");
                continue;
            }
            return flags;
        }
        switch (support.peekKind(p).*) {
            .Ident => {
                const t = support.text(p, support.currentSpan(p));
                if (std.mem.eql(u8, t, "data")) {
                    flags.is_data = true;
                    _ = support.bump(p);
                } else if (std.mem.eql(u8, t, "companion")) {
                    flags.is_companion = true;
                    _ = support.bump(p);
                } else if (std.mem.eql(u8, t, "enum")) {
                    flags.is_enum = true;
                    _ = support.bump(p);
                } else if (std.mem.eql(u8, t, "sealed")) {
                    flags.is_sealed = true;
                    _ = support.bump(p);
                } else if (std.mem.eql(u8, t, "open")) {
                    flags.is_open = true;
                    _ = support.bump(p);
                } else if (std.mem.eql(u8, t, "override")) {
                    flags.is_override = true;
                    _ = support.bump(p);
                } else if (std.mem.eql(u8, t, "abstract")) {
                    flags.is_abstract = true;
                    _ = support.bump(p);
                } else if (std.mem.eql(u8, t, "inner")) {
                    flags.is_inner = true;
                    _ = support.bump(p);
                } else if (std.mem.eql(u8, t, "lateinit")) {
                    flags.is_lateinit = true;
                    _ = support.bump(p);
                } else if (std.mem.eql(u8, t, "operator")) {
                    flags.is_operator = true;
                    _ = support.bump(p);
                } else if (std.mem.eql(u8, t, "inline")) {
                    flags.is_inline = true;
                    flags.inline_span = support.currentSpan(p);
                    _ = support.bump(p);
                } else if (std.mem.eql(u8, t, "const")) {
                    flags.is_const = true;
                    _ = support.bump(p);
                } else if (std.mem.eql(u8, t, "tailrec")) {
                    flags.is_tailrec = true;
                    _ = support.bump(p);
                } else if (std.mem.eql(u8, t, "value")) {
                    flags.is_value = true;
                    _ = support.bump(p);
                } else if (std.mem.eql(u8, t, "annotation")) {
                    flags.is_annotation = true;
                    _ = support.bump(p);
                } else if (std.mem.eql(u8, t, "public")) {
                    flags.visibility = Visibility.Public;
                    _ = support.bump(p);
                } else if (std.mem.eql(u8, t, "private")) {
                    flags.visibility = Visibility.Private;
                    _ = support.bump(p);
                } else if (std.mem.eql(u8, t, "protected")) {
                    flags.visibility = Visibility.Protected;
                    _ = support.bump(p);
                } else if (std.mem.eql(u8, t, "internal")) {
                    flags.visibility = Visibility.Internal;
                    _ = support.bump(p);
                } else if (std.mem.eql(u8, t, "infix")) {
                    flags.is_infix = true;
                    _ = support.bump(p);
                } else if (std.mem.eql(u8, t, "suspend")) {
                    flags.is_suspend = true;
                    flags.suspend_span = support.currentSpan(p);
                    _ = support.bump(p);
                } else if (std.mem.eql(u8, t, "expect")) {
                    flags.is_expect = true;
                    _ = support.bump(p);
                } else if (std.mem.eql(u8, t, "actual")) {
                    flags.is_actual = true;
                    _ = support.bump(p);
                } else if (std.mem.eql(u8, t, "final") or std.mem.eql(u8, t, "external")) {
                    _ = support.bump(p);
                } else {
                    return flags;
                }
            },
            else => return flags,
        }
    }
}

/// Parse one annotation set at the cursor. The cursor must be at an
/// `@` token. Returns `null` if no annotation was consumed (the leading
/// `@` could not be followed by an identifier or use-site target).
/// Supports:
///   - `@Foo`
///   - `@Foo(args)`
///   - `@Foo.Bar`
///   - `@field:Foo` (use-site target)
///   - `@field:[A B C]` (array form with use-site target)
pub fn parseAnnotationSet(p: *Parser) ?[]Annotation {
    return parseAnnotationSetCtx(p, false);
}

fn parseAnnotationSetCtx(p: *Parser, in_type_position: bool) ?[]Annotation {
    const at_span = if (support.peekKind(p).*.isAt())
        support.bump(p).span
    else
        return null;
    const use_site = tryParseAnnotationUseSite(p);
    if (std.meta.activeTag(support.peekKind(p).*) == .LBracket) {
        if (use_site != null and use_site.? == .All) {
            support.errWithFactory(
                p,
                &diagnostics.generated.INAPPLICABLE_ALL_TARGET_IN_MULTI_ANNOTATION,
                "E0017",
                "Multiple annotation syntax with '@all:' use-site target is forbidden, use '@all:A1 @all:A2 ...' instead.",
                support.currentSpan(p),
            );
        }
        _ = support.bump(p);
        var anns: std.ArrayList(Annotation) = .empty;
        while (true) {
            support.skipNl(p);
            switch (support.peekKind(p).*) {
                .RBracket, .Eof => break,
                else => {},
            }
            if (parseUnescapedAnnotationCtx(p, use_site, at_span, in_type_position)) |a| {
                anns.append(p.allocator, a) catch @panic("OOM");
            } else {
                break;
            }
            support.skipNl(p);
        }
        _ = support.expect(p, .RBracket, "`]`");
        return anns.toOwnedSlice(p.allocator) catch @panic("OOM");
    }
    if (parseUnescapedAnnotationCtx(p, use_site, at_span, in_type_position)) |a| {
        const out = p.allocator.alloc(Annotation, 1) catch @panic("OOM");
        out[0] = a;
        return out;
    }
    return null;
}

/// Try to consume an annotation use-site target like `field:` / `get:`.
/// Returns the parsed target or `null` if the cursor wasn't at a
/// recognized target followed by `:`.
pub fn tryParseAnnotationUseSite(p: *Parser) ?AnnotationUseSite {
    if (std.meta.activeTag(support.peekKind(p).*) != .Ident) {
        return null;
    }
    const next = kindAt(p, 1);
    if (next == null or std.meta.activeTag(next.?) != .Colon) {
        return null;
    }
    const t = support.text(p, support.currentSpan(p));
    const site: AnnotationUseSite = if (std.mem.eql(u8, t, "field"))
        .Field
    else if (std.mem.eql(u8, t, "property"))
        .Property
    else if (std.mem.eql(u8, t, "get"))
        .Get
    else if (std.mem.eql(u8, t, "set"))
        .Set
    else if (std.mem.eql(u8, t, "receiver"))
        .Receiver
    else if (std.mem.eql(u8, t, "param"))
        .Param
    else if (std.mem.eql(u8, t, "setparam"))
        .SetParam
    else if (std.mem.eql(u8, t, "delegate"))
        .Delegate
    else if (std.mem.eql(u8, t, "file"))
        .File
    else if (std.mem.eql(u8, t, "all"))
        .All
    else
        return null;
    _ = support.bump(p);
    _ = support.bump(p);
    return site;
}

pub fn parseUnescapedAnnotation(
    p: *Parser,
    use_site: ?AnnotationUseSite,
    at_span: Span,
) ?Annotation {
    return parseUnescapedAnnotationCtx(p, use_site, at_span, false);
}

pub fn parseUnescapedAnnotationCtx(
    p: *Parser,
    use_site: ?AnnotationUseSite,
    at_span: Span,
    in_type_position: bool,
) ?Annotation {
    const first = support.parseIdent(p, "annotation name") orelse return null;
    var path: std.ArrayList(Ident) = .empty;
    path.append(p.allocator, first) catch @panic("OOM");
    while (std.meta.activeTag(support.peekKind(p).*) == .Dot) {
        const save = p.pos;
        _ = support.bump(p);
        if (support.parseIdent(p, "annotation segment")) |seg| {
            path.append(p.allocator, seg) catch @panic("OOM");
        } else {
            p.pos = save;
            break;
        }
    }
    var type_args: []TypeRef = &.{};
    if (std.meta.activeTag(support.peekKind(p).*) == .Lt and types.trySkipGenericCallArgs(p)) {
        type_args = types.parseCallTypeArgs(p);
    }
    var args: std.ArrayList(Expr) = .empty;
    var arg_names: std.ArrayList(?[]const u8) = .empty;
    const consume_args = std.meta.activeTag(support.peekKind(p).*) == .LParen and
        !(in_type_position and parenStartsFunctionType(p));
    if (consume_args) {
        _ = support.bump(p);
        while (true) {
            support.skipNl(p);
            switch (support.peekKind(p).*) {
                .RParen, .Eof => break,
                else => {},
            }
            const name = expr.tryConsumeNamedArgName(p);
            const e = expr.parseExpr(p) orelse break;
            args.append(p.allocator, e) catch @panic("OOM");
            arg_names.append(p.allocator, name) catch @panic("OOM");
            support.skipNl(p);
            if (std.meta.activeTag(support.peekKind(p).*) == .Comma) {
                _ = support.bump(p);
            } else {
                break;
            }
        }
        _ = support.expect(p, .RParen, "`)`");
    }
    const end = prevSpan(p);
    return .{
        .use_site = use_site,
        .path = path.toOwnedSlice(p.allocator) catch @panic("OOM"),
        .type_args = type_args,
        .args = args.toOwnedSlice(p.allocator) catch @panic("OOM"),
        .arg_names = arg_names.toOwnedSlice(p.allocator) catch @panic("OOM"),
        .span = at_span.join(end),
    };
}

/// Consume leading `@file:...` annotations (only file-use-site
/// ones, so a leading `@JvmName fun` on a package-less file keeps
/// its annotation). Result is discarded — klio doesn't act on
/// file annotations.
pub fn skipFileAnnotations(p: *Parser) void {
    while (true) {
        support.skipNl(p);
        if (!support.peekKind(p).*.isAt()) {
            break;
        }
        const next = kindAt(p, 1);
        const after = kindAt(p, 2);
        const is_file = next != null and std.meta.activeTag(next.?) == .Ident and
            std.mem.eql(u8, support.text(p, p.tokens[p.pos + 1].span), "file") and
            after != null and std.meta.activeTag(after.?) == .Colon;
        if (!is_file) {
            break;
        }
        if (parseAnnotationSet(p) == null) {
            break;
        }
    }
}

/// Parse zero or more annotation sets at the cursor. Returns the
/// flattened annotation list. Useful at sites that don't go through
/// `skipModifiersWithFlags` (params, type parameters, type-refs,
/// enum entries, when-bindings).
pub fn parseAnnotations(p: *Parser) []Annotation {
    return parseAnnotationsCtx(p, false);
}

/// Like `parseAnnotations` but for type-use position, where a `(` after
/// the annotation name may begin a function-type parameter list
/// (`@Composable () -> Unit`) rather than annotation arguments.
pub fn parseTypeAnnotations(p: *Parser) []Annotation {
    return parseAnnotationsCtx(p, true);
}

fn parseAnnotationsCtx(p: *Parser, in_type_position: bool) []Annotation {
    var out: std.ArrayList(Annotation) = .empty;
    while (true) {
        support.skipNl(p);
        if (!support.peekKind(p).*.isAt()) {
            break;
        }
        const set = parseAnnotationSetCtx(p, in_type_position) orelse break;
        out.appendSlice(p.allocator, set) catch @panic("OOM");
    }
    return out.toOwnedSlice(p.allocator) catch @panic("OOM");
}

/// In type-use position, a `(` immediately following the annotation name
/// belongs to a function type (`@Composable () -> Unit`,
/// `@Composable (P) -> Unit`) and must not be eaten as annotation
/// arguments. We treat the `(...)` as a function-type parameter list when
/// the matching `)` is followed by `->`. Empty `()` followed by `->` and
/// non-empty lists are both covered.
fn parenStartsFunctionType(p: *Parser) bool {
    if (std.meta.activeTag(support.peekKind(p).*) != .LParen) return false;
    var depth: usize = 0;
    var i = p.pos;
    while (i < p.tokens.len) : (i += 1) {
        switch (std.meta.activeTag(p.tokens[i].kind)) {
            .LParen => depth += 1,
            .RParen => {
                depth -= 1;
                if (depth == 0) {
                    var j = i + 1;
                    while (j < p.tokens.len and std.meta.activeTag(p.tokens[j].kind) == .Newline) j += 1;
                    return j < p.tokens.len and std.meta.activeTag(p.tokens[j].kind) == .Arrow;
                }
            },
            .Eof => return false,
            else => {},
        }
    }
    return false;
}
