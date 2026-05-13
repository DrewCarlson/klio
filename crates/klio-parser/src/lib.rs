//! Kotlin parser.
//!
//! Hand-written recursive descent over a [`Token`] stream produced by
//! `klio-lexer`. Expression grammar is implemented as a Pratt parser with
//! precedence levels lifted directly from spec §7 (Expressions):
//!
//! ```text
//!   disjunction      ||
//!   conjunction      &&
//!   equality         == != === !==
//!   comparison       < > <= >=
//!   named_checks     in !in is !is        (in/is wired; type-RHS deferred)
//!   elvis            ?:
//!   infix_function   (deferred)
//!   range            .. ..<
//!   additive         + -
//!   multiplicative   * / %
//!   type_rhs         as as?                (deferred)
//!   prefix           + - ! ++ --
//!   postfix          ++ -- . ?. !! () []
//!   primary
//! ```
//!
//! Assignment is parsed at the statement level (Kotlin assignments are not
//! expressions). Newlines act as soft separators: inside parens/braces/brackets
//! they are skipped freely; at statement positions they terminate a statement.

use klio_ast::{
    Accessor, Annotation, AnnotationUseSite, AssignOp, BinOp, Block, Catch, Class, ClassParam,
    CtorDelegation, Decl, EnumEntry, Expr, FunctionBody, Function, FunctionTypeRef, Ident,
    ImportDecl, KotlinFile, ObjectDecl, PackageHeader, Param, PostfixOp, Property, SecondaryCtor,
    Stmt, StringPart, TypeAlias, TypeArg, TypeParam, TypeRef, UnOp, Variance, Visibility,
    WhenBinding, WhenBranch, WhenPattern, WhenPatternKind, WhereBound,
};
use klio_diagnostics::{Diagnostic, DiagnosticSink};
use klio_lexer::{Keyword, Token, TokenKind};
use klio_span::{FileId, Span};

pub struct Parser<'src, 'tok> {
    src: &'src str,
    tokens: &'tok [Token],
    pos: usize,
    pub diagnostics: DiagnosticSink,
    /// When `true`, postfix expression parsing will not attach a trailing
    /// `{ … }` lambda. Set while reading the delegate expression in a
    /// supertype-list entry of the form `: I by expr`, so the class body's
    /// opening brace isn't swallowed as `expr { … }`.
    suppress_trailing_lambda: bool,
}

impl<'src, 'tok> Parser<'src, 'tok> {
    #[must_use]
    pub fn new(_file: FileId, src: &'src str, tokens: &'tok [Token]) -> Self {
        Self {
            src,
            tokens,
            pos: 0,
            diagnostics: DiagnosticSink::new(),
            suppress_trailing_lambda: false,
        }
    }

    // ---------- cursor helpers ----------

    fn peek(&self) -> &Token {
        &self.tokens[self.pos]
    }

    fn peek_kind(&self) -> &TokenKind {
        &self.tokens[self.pos].kind
    }

    fn bump(&mut self) -> Token {
        let t = self.tokens[self.pos].clone();
        if !matches!(t.kind, TokenKind::Eof) {
            self.pos += 1;
        }
        t
    }

    /// Skip soft newlines — newlines that don't terminate a statement.
    fn skip_nl(&mut self) {
        while matches!(self.peek_kind(), TokenKind::Newline) {
            self.pos += 1;
        }
    }

    /// Spec §7.1: assignments are statements, not expressions. After parsing
    /// an expression in a value-context (paren, `if`/`while`/`do-while`/`when`
    /// condition, `for` range, value-argument), reject a trailing assignment
    /// operator with a clear diagnostic and consume the RHS to recover.
    fn reject_trailing_assignment(&mut self) {
        let is_assign = matches!(
            self.peek_kind(),
            TokenKind::Eq
                | TokenKind::PlusEq
                | TokenKind::MinusEq
                | TokenKind::StarEq
                | TokenKind::SlashEq
                | TokenKind::PercentEq
        );
        if !is_assign {
            return;
        }
        let span = self.current_span();
        self.error(
            "T0117",
            "assignments are not expressions, and only expressions are allowed in this context",
            span,
        );
        self.bump();
        self.skip_nl();
        let _ = self.parse_expr();
    }

    fn at_newline_or_semi_or_close(&self) -> bool {
        matches!(
            self.peek_kind(),
            TokenKind::Newline | TokenKind::Semicolon | TokenKind::Eof | TokenKind::RBrace
        )
    }

    fn text(&self, span: Span) -> &str {
        &self.src[span.range()]
    }

    /// Read the identifier name stored in the token's span, stripping the
    /// surrounding backticks when the source uses an escaped identifier
    /// (`` `foo bar` ``). For unescaped identifiers this is a plain slice.
    fn ident_name(&self, span: Span) -> String {
        let raw = self.text(span);
        if raw.len() >= 2 && raw.starts_with('`') && raw.ends_with('`') {
            raw[1..raw.len() - 1].to_string()
        } else {
            raw.to_string()
        }
    }

    fn current_span(&self) -> Span {
        self.peek().span
    }

    fn error(&mut self, code: &'static str, msg: impl Into<String>, span: Span) {
        self.diagnostics.emit(Diagnostic::error(msg, span).with_code(code));
    }

    fn expect(&mut self, kind: &TokenKind, what: &str) -> Option<Token> {
        self.skip_nl();
        if std::mem::discriminant(self.peek_kind()) == std::mem::discriminant(kind) {
            Some(self.bump())
        } else {
            let span = self.current_span();
            self.error("E0001", format!("expected {what}"), span);
            None
        }
    }

    // ---------- top-level ----------

    pub fn parse_file(mut self) -> (KotlinFile, DiagnosticSink) {
        self.skip_nl();
        let start = self.current_span();

        let package = self.parse_package_header();
        let imports = self.parse_imports();

        let mut decls = Vec::new();
        loop {
            self.skip_stmt_separators();
            if matches!(self.peek_kind(), TokenKind::Eof) {
                break;
            }
            if matches!(self.peek_kind(), TokenKind::Keyword(Keyword::Package)) {
                let kw_span = self.current_span();
                let code = if package.is_some() { "P0045" } else { "P0045" };
                let msg = if package.is_some() {
                    "duplicate `package` header; a file may declare at most one package"
                } else {
                    "`package` header must come before any import or declaration"
                };
                self.error(code, msg, kw_span);
                // Consume the stray header so parsing can continue.
                let _ = self.parse_package_header();
                continue;
            }
            if matches!(self.peek_kind(), TokenKind::Keyword(Keyword::Import)) {
                let kw_span = self.current_span();
                self.error(
                    "P0046",
                    "`import` directives must appear before any declaration",
                    kw_span,
                );
                // Consume the stray import header(s) so parsing can continue.
                let _ = self.parse_imports();
                continue;
            }
            if let Some(d) = self.parse_top_decl() {
                decls.push(d);
            } else {
                self.recover_to_top_level();
            }
        }
        let end = self.current_span();
        (
            KotlinFile { package, imports, decls, span: start.join(end) },
            self.diagnostics,
        )
    }

    fn parse_package_header(&mut self) -> Option<PackageHeader> {
        self.skip_nl();
        if !matches!(self.peek_kind(), TokenKind::Keyword(Keyword::Package)) {
            return None;
        }
        let pkg_tok = self.bump();
        let mut path = Vec::new();
        if let Some(first) = self.parse_ident("package name") {
            path.push(first);
        }
        while matches!(self.peek_kind(), TokenKind::Dot) {
            self.bump();
            if let Some(part) = self.parse_ident("package segment") {
                path.push(part);
            } else {
                break;
            }
        }
        let span = pkg_tok.span.join(path.last().map_or(pkg_tok.span, |p| p.span));
        Some(PackageHeader { path, span })
    }

    fn parse_imports(&mut self) -> Vec<ImportDecl> {
        let mut imports = Vec::new();
        loop {
            self.skip_nl();
            if !matches!(self.peek_kind(), TokenKind::Keyword(Keyword::Import)) {
                break;
            }
            let kw = self.bump();
            let mut path = Vec::new();
            let mut wildcard = false;
            self.skip_nl();
            if matches!(self.peek_kind(), TokenKind::Ident) {
                let tok = self.bump();
                path.push(Ident { name: self.ident_name(tok.span), span: tok.span });
            } else {
                self.error("P0047", "malformed import: missing path", kw.span);
            }
            while matches!(self.peek_kind(), TokenKind::Dot) {
                let dot = self.bump();
                if matches!(self.peek_kind(), TokenKind::Star) {
                    self.bump();
                    wildcard = true;
                    break;
                }
                self.skip_nl();
                if matches!(self.peek_kind(), TokenKind::Ident) {
                    let tok = self.bump();
                    path.push(Ident { name: self.ident_name(tok.span), span: tok.span });
                } else {
                    self.error("P0047", "malformed import: trailing `.` with no segment", dot.span);
                    break;
                }
            }
            let alias = if matches!(self.peek_kind(), TokenKind::Keyword(Keyword::As)) {
                let as_tok = self.bump();
                let alias_ident = self.parse_ident("import alias");
                if wildcard {
                    let span = alias_ident.as_ref().map_or(as_tok.span, |i| as_tok.span.join(i.span));
                    self.error(
                        "P0044",
                        "wildcard import cannot be renamed; remove `as` or replace `*` with a name",
                        span,
                    );
                }
                alias_ident
            } else {
                None
            };
            let end = self.tokens[self.pos.saturating_sub(1)].span;
            imports.push(ImportDecl { path, alias, wildcard, span: kw.span.join(end) });
        }
        imports
    }

    fn parse_top_decl(&mut self) -> Option<Decl> {
        let flags = self.skip_modifiers_with_flags();
        match self.peek_kind() {
            TokenKind::Keyword(Keyword::Fun) => {
                // `fun interface Foo { … }` — SAM-conversion-eligible interface.
                let next = self.tokens.get(self.pos + 1).map(|t| &t.kind);
                if matches!(next, Some(TokenKind::Keyword(Keyword::Interface))) {
                    self.bump(); // `fun`
                    let visibility = flags.visibility;
                    let annotations = flags.annotations.clone();
                    return self
                        .parse_class(
                            ClassModifiers {
                                is_data: false,
                                is_companion: false,
                                is_enum: false,
                                is_sealed: flags.is_sealed,
                                is_open: false,
                                is_abstract: false,
                                is_inner: false,
                                is_fun_interface: true,
                                is_value: false,
                                is_annotation: false,
                            },
                            visibility,
                            annotations,
                        )
                        .map(Decl::Class);
                }
                self.parse_fun(flags).map(Decl::Function)
            }
            TokenKind::Keyword(Keyword::Val) | TokenKind::Keyword(Keyword::Var) => {
                self.parse_property_with_flags(flags).map(Decl::Property)
            }
            TokenKind::Keyword(Keyword::Class) | TokenKind::Keyword(Keyword::Interface) => {
                let visibility = flags.visibility;
                let annotations = flags.annotations.clone();
                // `inline class` is the deprecated alias for `value class`.
                // When the user wrote `inline` on a class declaration, promote
                // it to `is_value` and emit a deprecation warning.
                let is_value = flags.is_value || flags.is_inline;
                if flags.is_inline && !flags.is_value {
                    if let Some(span) = flags.inline_span {
                        self.diagnostics.emit(
                            Diagnostic::warning(
                                "`inline class` is deprecated; use `value class` instead",
                                span,
                            )
                            .with_code("W0001"),
                        );
                    }
                }
                self.parse_class(
                    ClassModifiers {
                        is_data: flags.is_data,
                        is_companion: false,
                        is_enum: flags.is_enum,
                        is_sealed: flags.is_sealed,
                        is_open: flags.is_open,
                        is_abstract: flags.is_abstract,
                        is_inner: flags.is_inner,
                        is_fun_interface: false,
                        is_value,
                        is_annotation: flags.is_annotation,
                    },
                    visibility,
                    annotations,
                )
                .map(Decl::Class)
            }
            TokenKind::Keyword(Keyword::Object) => {
                if flags.is_companion {
                    self.parse_companion_object_as_class(flags.visibility, flags.annotations)
                        .map(Decl::Class)
                } else {
                    self.parse_object(flags.is_data).map(Decl::Object)
                }
            }
            TokenKind::Keyword(Keyword::Typealias) => {
                self.parse_typealias(flags.visibility, flags.annotations)
                    .map(Decl::TypeAlias)
            }
            _ => {
                let span = self.current_span();
                self.error("E0002", "expected top-level declaration", span);
                None
            }
        }
    }

    fn parse_typealias(
        &mut self,
        visibility: Visibility,
        annotations: Vec<Annotation>,
    ) -> Option<TypeAlias> {
        let kw = self.bump(); // `typealias`
        let name = self.parse_ident("typealias name")?;
        self.skip_nl();
        let type_params = if matches!(self.peek_kind(), TokenKind::Lt) {
            self.parse_type_params(false)
        } else {
            Vec::new()
        };
        self.skip_nl();
        self.expect(&TokenKind::Eq, "`=`")?;
        self.skip_nl();
        let target = self.parse_type()?;
        let span = kw.span.join(target.span);
        Some(TypeAlias {
            name,
            type_params,
            target,
            visibility,
            annotations,
            span,
        })
    }

    /// Recognize leading annotations and soft modifiers, capturing the flags
    /// that affect how the declaration is parsed (`data`, `companion`).
    fn skip_modifiers_with_flags(&mut self) -> ModifierFlags {
        let mut flags = ModifierFlags::default();
        loop {
            self.skip_nl();
            if self.peek_kind().is_at() {
                if let Some(anns) = self.parse_annotation_set() {
                    flags.annotations.extend(anns);
                    continue;
                }
                return flags;
            }
            match self.peek_kind() {
                TokenKind::Ident => {
                    let text = self.text(self.current_span());
                    if text == "data" {
                        flags.is_data = true;
                        self.bump();
                    } else if text == "companion" {
                        flags.is_companion = true;
                        self.bump();
                    } else if text == "enum" {
                        flags.is_enum = true;
                        self.bump();
                    } else if text == "sealed" {
                        flags.is_sealed = true;
                        self.bump();
                    } else if text == "open" {
                        flags.is_open = true;
                        self.bump();
                    } else if text == "override" {
                        flags.is_override = true;
                        self.bump();
                    } else if text == "abstract" {
                        flags.is_abstract = true;
                        self.bump();
                    } else if text == "inner" {
                        flags.is_inner = true;
                        self.bump();
                    } else if text == "lateinit" {
                        flags.is_lateinit = true;
                        self.bump();
                    } else if text == "operator" {
                        flags.is_operator = true;
                        self.bump();
                    } else if text == "inline" {
                        flags.is_inline = true;
                        flags.inline_span = Some(self.current_span());
                        self.bump();
                    } else if text == "const" {
                        flags.is_const = true;
                        self.bump();
                    } else if text == "tailrec" {
                        flags.is_tailrec = true;
                        self.bump();
                    } else if text == "value" {
                        flags.is_value = true;
                        self.bump();
                    } else if text == "annotation" {
                        flags.is_annotation = true;
                        self.bump();
                    } else if text == "public" {
                        flags.visibility = Visibility::Public;
                        self.bump();
                    } else if text == "private" {
                        flags.visibility = Visibility::Private;
                        self.bump();
                    } else if text == "protected" {
                        flags.visibility = Visibility::Protected;
                        self.bump();
                    } else if text == "internal" {
                        flags.visibility = Visibility::Internal;
                        self.bump();
                    } else if text == "infix" {
                        flags.is_infix = true;
                        self.bump();
                    } else if text == "suspend" {
                        flags.is_suspend = true;
                        flags.suspend_span = Some(self.current_span());
                        self.bump();
                    } else if matches!(text, "final" | "external") {
                        self.bump();
                    } else {
                        return flags;
                    }
                }
                _ => return flags,
            }
        }
    }

    /// Parse one annotation set at the cursor. The cursor must be at an
    /// `@` token. Returns `None` if no annotation was consumed (the leading
    /// `@` could not be followed by an identifier or use-site target).
    /// Supports:
    ///   - `@Foo`
    ///   - `@Foo(args)`
    ///   - `@Foo.Bar`
    ///   - `@field:Foo` (use-site target)
    ///   - `@field:[A B C]` (array form with use-site target)
    fn parse_annotation_set(&mut self) -> Option<Vec<Annotation>> {
        let at_span = if self.peek_kind().is_at() {
            self.bump().span
        } else {
            return None;
        };
        let use_site = self.try_parse_annotation_use_site();
        if matches!(self.peek_kind(), TokenKind::LBracket) {
            self.bump();
            let mut anns = Vec::new();
            loop {
                self.skip_nl();
                if matches!(self.peek_kind(), TokenKind::RBracket | TokenKind::Eof) {
                    break;
                }
                if let Some(a) = self.parse_unescaped_annotation(use_site, at_span) {
                    anns.push(a);
                } else {
                    break;
                }
                self.skip_nl();
            }
            self.expect(&TokenKind::RBracket, "`]`");
            return Some(anns);
        }
        self.parse_unescaped_annotation(use_site, at_span).map(|a| vec![a])
    }

    /// Try to consume an annotation use-site target like `field:` / `get:`.
    /// Returns the parsed target or `None` if the cursor wasn't at a
    /// recognized target followed by `:`.
    fn try_parse_annotation_use_site(&mut self) -> Option<AnnotationUseSite> {
        if !matches!(self.peek_kind(), TokenKind::Ident) {
            return None;
        }
        let next = self.tokens.get(self.pos + 1).map(|t| &t.kind);
        if !matches!(next, Some(TokenKind::Colon)) {
            return None;
        }
        let text = self.text(self.current_span()).to_string();
        let site = match text.as_str() {
            "field" => AnnotationUseSite::Field,
            "property" => AnnotationUseSite::Property,
            "get" => AnnotationUseSite::Get,
            "set" => AnnotationUseSite::Set,
            "receiver" => AnnotationUseSite::Receiver,
            "param" => AnnotationUseSite::Param,
            "setparam" => AnnotationUseSite::SetParam,
            "delegate" => AnnotationUseSite::Delegate,
            "file" => AnnotationUseSite::File,
            _ => return None,
        };
        self.bump();
        self.bump();
        Some(site)
    }

    fn parse_unescaped_annotation(
        &mut self,
        use_site: Option<AnnotationUseSite>,
        at_span: Span,
    ) -> Option<Annotation> {
        let first = self.parse_ident("annotation name")?;
        let mut path = vec![first];
        while matches!(self.peek_kind(), TokenKind::Dot) {
            let save = self.pos;
            self.bump();
            if let Some(seg) = self.parse_ident("annotation segment") {
                path.push(seg);
            } else {
                self.pos = save;
                break;
            }
        }
        let mut type_args = Vec::new();
        if matches!(self.peek_kind(), TokenKind::Lt) && self.try_skip_generic_call_args() {
            type_args = self.parse_call_type_args();
        }
        let mut args: Vec<Expr> = Vec::new();
        let mut arg_names: Vec<Option<String>> = Vec::new();
        if matches!(self.peek_kind(), TokenKind::LParen) {
            self.bump();
            loop {
                self.skip_nl();
                if matches!(self.peek_kind(), TokenKind::RParen | TokenKind::Eof) {
                    break;
                }
                let name = self.try_consume_named_arg_name();
                let Some(e) = self.parse_expr() else { break };
                args.push(e);
                arg_names.push(name);
                self.skip_nl();
                if matches!(self.peek_kind(), TokenKind::Comma) {
                    self.bump();
                } else {
                    break;
                }
            }
            self.expect(&TokenKind::RParen, "`)`");
        }
        let end = self.tokens[self.pos.saturating_sub(1)].span;
        Some(Annotation {
            use_site,
            path,
            type_args,
            args,
            arg_names,
            span: at_span.join(end),
        })
    }

    /// Parse zero or more annotation sets at the cursor. Returns the
    /// flattened annotation list. Useful at sites that don't go through
    /// `skip_modifiers_with_flags` (params, type parameters, type-refs,
    /// enum entries, when-bindings).
    fn parse_annotations(&mut self) -> Vec<Annotation> {
        let mut out = Vec::new();
        loop {
            self.skip_nl();
            if !self.peek_kind().is_at() {
                break;
            }
            let Some(set) = self.parse_annotation_set() else { break };
            out.extend(set);
        }
        out
    }

    fn parse_class(
        &mut self,
        mods: ClassModifiers,
        visibility: Visibility,
        annotations: Vec<Annotation>,
    ) -> Option<Class> {
        let ClassModifiers {
            is_data,
            is_companion,
            is_enum,
            is_sealed,
            is_open,
            is_abstract,
            is_inner,
            is_fun_interface,
            is_value,
            is_annotation,
        } = mods;
        let kw = self.bump(); // `class` / `interface`
        let is_interface = matches!(kw.kind, TokenKind::Keyword(Keyword::Interface));
        let name = self.parse_ident("class name")?;
        self.skip_nl();
        let type_params = if matches!(self.peek_kind(), TokenKind::Lt) {
            self.parse_type_params(false)
        } else {
            Vec::new()
        };
        self.skip_nl();
        // Optional primary-ctor visibility: `class Foo (private)? constructor(...)`.
        let mut primary_ctor_visibility: Option<Visibility> = None;
        let save = self.pos;
        let mut peek_vis: Option<Visibility> = None;
        if matches!(self.peek_kind(), TokenKind::Ident) {
            let txt = self.text(self.current_span());
            peek_vis = match txt {
                "public" => Some(Visibility::Public),
                "private" => Some(Visibility::Private),
                "protected" => Some(Visibility::Protected),
                "internal" => Some(Visibility::Internal),
                _ => None,
            };
        }
        if peek_vis.is_some() {
            // Only commit if the next non-newline token is `constructor`.
            let saved = self.pos;
            self.bump();
            self.skip_nl();
            if matches!(self.peek_kind(), TokenKind::Ident)
                && self.text(self.current_span()) == "constructor"
            {
                primary_ctor_visibility = peek_vis;
                self.bump(); // constructor
                self.skip_nl();
            } else {
                self.pos = saved;
            }
        } else if matches!(self.peek_kind(), TokenKind::Ident)
            && self.text(self.current_span()) == "constructor"
        {
            self.bump();
            self.skip_nl();
        }
        let _ = save;
        let primary_params = if matches!(self.peek_kind(), TokenKind::LParen) {
            self.bump();
            let params = self.parse_class_param_list();
            self.expect(&TokenKind::RParen, "`)`");
            params
        } else {
            Vec::new()
        };
        let (supertypes, supertype_args, supertype_delegates) =
            self.parse_optional_supertypes_full();
        let where_bounds = self.parse_where_clause();
        let (members, init_blocks, enum_entries, secondary_ctors) = if is_enum {
            let (m, i, e) = self.parse_enum_class_body();
            (m, i, e, Vec::new())
        } else {
            let (m, i, s) = self.parse_class_body();
            (m, i, Vec::new(), s)
        };
        let end = self.tokens[self.pos.saturating_sub(1)].span;
        Some(Class {
            name,
            type_params,
            where_bounds,
            primary_params,
            primary_ctor_visibility,
            init_blocks,
            supertypes,
            supertype_args,
            supertype_delegates,
            is_data,
            is_companion,
            is_enum,
            is_sealed,
            // `abstract` implies `open`.
            is_open: is_open || is_abstract,
            is_abstract,
            is_inner,
            secondary_ctors,
            is_interface,
            is_fun_interface,
            is_value,
            is_annotation,
            enum_entries,
            members,
            visibility,
            annotations,
            span: kw.span.join(end),
        })
    }

    /// Parse an enum class body: optional entry list (comma-separated, with
    /// optional `(...)` ctor args and optional `{...}` per-entry body),
    /// optional `;` then regular class-body members.
    fn parse_enum_class_body(&mut self) -> (Vec<Decl>, Vec<Block>, Vec<EnumEntry>) {
        // Helper: enum-class body content (after the optional `;`) shares the
        // member-parsing shape of a regular class body, minus secondary
        // constructors.
        let mut members = Vec::new();
        let mut init_blocks = Vec::new();
        let mut entries = Vec::new();
        self.skip_nl();
        if !matches!(self.peek_kind(), TokenKind::LBrace) {
            return (members, init_blocks, entries);
        }
        self.bump();
        // Parse entries until `;`, `}`, or EOF.
        loop {
            self.skip_nl();
            match self.peek_kind() {
                TokenKind::RBrace | TokenKind::Eof | TokenKind::Semicolon => break,
                _ => {}
            }
            let annotations = self.parse_annotations();
            let Some(name) = self.parse_ident("enum entry name") else {
                break;
            };
            let start = name.span;
            let mut args = Vec::new();
            self.skip_nl();
            if matches!(self.peek_kind(), TokenKind::LParen) {
                self.bump();
                loop {
                    self.skip_nl();
                    if matches!(self.peek_kind(), TokenKind::RParen) {
                        break;
                    }
                    let Some(a) = self.parse_expr() else { break };
                    args.push(a);
                    self.skip_nl();
                    if matches!(self.peek_kind(), TokenKind::Comma) {
                        self.bump();
                    } else {
                        break;
                    }
                }
                self.expect(&TokenKind::RParen, "`)`");
            }
            let mut body_members = Vec::new();
            self.skip_nl();
            if matches!(self.peek_kind(), TokenKind::LBrace) {
                let (m, _i, _s) = self.parse_class_body();
                body_members = m;
            }
            let end = self.tokens[self.pos.saturating_sub(1)].span;
            entries.push(EnumEntry {
                name,
                args,
                body_members,
                annotations,
                span: start.join(end),
            });
            self.skip_nl();
            if matches!(self.peek_kind(), TokenKind::Comma) {
                self.bump();
                continue;
            }
            break;
        }
        self.skip_nl();
        if matches!(self.peek_kind(), TokenKind::Semicolon) {
            self.bump();
            // Continue with regular class-body members until `}`.
            loop {
                self.skip_nl();
                if matches!(self.peek_kind(), TokenKind::RBrace | TokenKind::Eof) {
                    break;
                }
                if matches!(self.peek_kind(), TokenKind::Ident)
                    && self.text(self.current_span()) == "init"
                {
                    self.bump();
                    self.skip_nl();
                    if let Some(b) = self.parse_block() {
                        init_blocks.push(b);
                    }
                    continue;
                }
                if let Some(d) = self.parse_top_decl() {
                    members.push(d);
                } else {
                    self.bump();
                }
            }
        }
        self.expect(&TokenKind::RBrace, "`}`");
        (members, init_blocks, entries)
    }

    fn parse_companion_object_as_class(
        &mut self,
        visibility: Visibility,
        annotations: Vec<Annotation>,
    ) -> Option<Class> {
        let kw = self.bump(); // `object`
        // Optional companion name. If absent, name as "Companion".
        let name = if matches!(self.peek_kind(), TokenKind::Ident) {
            self.parse_ident("companion name")?
        } else {
            Ident { name: "Companion".into(), span: kw.span }
        };
        let (supertypes, supertype_args, supertype_delegates) =
            self.parse_optional_supertypes_full();
        let (members, init_blocks, _sec) = self.parse_class_body();
        let end = self.tokens[self.pos.saturating_sub(1)].span;
        Some(Class {
            name,
            type_params: Vec::new(),
            where_bounds: Vec::new(),
            primary_params: Vec::new(),
            init_blocks,
            supertypes,
            supertype_args,
            supertype_delegates,
            is_data: false,
            is_companion: true,
            is_enum: false,
            is_sealed: false,
            is_open: false,
            is_abstract: false,
            is_inner: false,
            secondary_ctors: Vec::new(),
            is_interface: false,
            is_fun_interface: false,
            is_value: false,
            is_annotation: false,
            enum_entries: Vec::new(),
            members,
            visibility,
            primary_ctor_visibility: None,
            annotations,
            span: kw.span.join(end),
        })
    }

    fn parse_object(&mut self, is_data: bool) -> Option<ObjectDecl> {
        let kw = self.bump(); // `object`
        let name = self.parse_ident("object name")?;
        let (supertypes, _args) = self.parse_optional_supertypes();
        let (members, _init, _sec) = self.parse_class_body();
        let end = self.tokens[self.pos.saturating_sub(1)].span;
        Some(ObjectDecl { name, supertypes, members, is_data, span: kw.span.join(end) })
    }

    fn parse_optional_supertypes(&mut self) -> (Vec<TypeRef>, Vec<Option<Vec<Expr>>>) {
        let (t, a, _d) = self.parse_optional_supertypes_full();
        (t, a)
    }

    fn parse_optional_supertypes_full(
        &mut self,
    ) -> (Vec<TypeRef>, Vec<Option<Vec<Expr>>>, Vec<Option<Expr>>) {
        let mut types = Vec::new();
        let mut args_list: Vec<Option<Vec<Expr>>> = Vec::new();
        let mut delegates: Vec<Option<Expr>> = Vec::new();
        let save = self.pos;
        self.skip_nl();
        if !matches!(self.peek_kind(), TokenKind::Colon) {
            self.pos = save;
            return (types, args_list, delegates);
        }
        self.bump();
        loop {
            self.skip_nl();
            let Some(t) = self.parse_type() else { break };
            types.push(t);
            // Optional constructor call `Bar(args)` after the type name.
            if matches!(self.peek_kind(), TokenKind::LParen) {
                self.bump();
                let mut args = Vec::new();
                loop {
                    self.skip_nl();
                    if matches!(self.peek_kind(), TokenKind::RParen) {
                        break;
                    }
                    if matches!(self.peek_kind(), TokenKind::Ident) {
                        let save = self.pos;
                        let _ = self.parse_ident("arg label");
                        if !matches!(self.peek_kind(), TokenKind::Eq) {
                            self.pos = save;
                        } else {
                            self.bump();
                            self.skip_nl();
                        }
                    }
                    let Some(a) = self.parse_expr() else { break };
                    args.push(a);
                    self.skip_nl();
                    if matches!(self.peek_kind(), TokenKind::Comma) {
                        self.bump();
                    } else {
                        break;
                    }
                }
                self.expect(&TokenKind::RParen, "`)`");
                args_list.push(Some(args));
                delegates.push(None);
            } else if self.peek_ident_text() == Some("by") {
                self.bump();
                self.skip_nl();
                let prev = self.suppress_trailing_lambda;
                self.suppress_trailing_lambda = true;
                let de = self.parse_expr();
                self.suppress_trailing_lambda = prev;
                args_list.push(None);
                delegates.push(de);
            } else {
                args_list.push(None);
                delegates.push(None);
            }
            self.skip_nl();
            if matches!(self.peek_kind(), TokenKind::Comma) {
                self.bump();
                continue;
            }
            break;
        }
        (types, args_list, delegates)
    }

    fn parse_class_body(&mut self) -> (Vec<Decl>, Vec<Block>, Vec<SecondaryCtor>) {
        let mut members = Vec::new();
        let mut init_blocks = Vec::new();
        let mut secondary_ctors = Vec::new();
        let save = self.pos;
        self.skip_nl();
        if !matches!(self.peek_kind(), TokenKind::LBrace) {
            // Body absent — preserve any newlines for the enclosing
            // statement-separator check.
            self.pos = save;
            return (members, init_blocks, secondary_ctors);
        }
        self.bump();
        loop {
            self.skip_stmt_separators();
            if matches!(self.peek_kind(), TokenKind::RBrace | TokenKind::Eof) {
                break;
            }
            // `init { … }` blocks — detected before modifier scanning so the
            // soft `init` ident isn't accidentally consumed.
            if matches!(self.peek_kind(), TokenKind::Ident)
                && self.text(self.current_span()) == "init"
            {
                self.bump();
                self.skip_nl();
                if let Some(b) = self.parse_block() {
                    init_blocks.push(b);
                }
                continue;
            }
            // Skip any modifiers in front of the next member. After that we
            // can detect a `constructor` keyword to branch to secondary-ctor
            // parsing.
            let save = self.pos;
            let flags = self.skip_modifiers_with_flags();
            if matches!(self.peek_kind(), TokenKind::Ident)
                && self.text(self.current_span()) == "constructor"
            {
                if let Some(sp) = flags.suspend_span {
                    self.error(
                        "T0114",
                        "`suspend` modifier is not allowed on a constructor",
                        sp,
                    );
                }
                if let Some(sc) = self.parse_secondary_ctor(flags.visibility, flags.annotations) {
                    secondary_ctors.push(sc);
                }
                continue;
            }
            // Roll back the modifier consumption so `parse_top_decl` can do
            // it itself (it depends on flags for the member it sees).
            self.pos = save;
            if let Some(d) = self.parse_top_decl() {
                members.push(d);
            } else {
                self.bump();
            }
        }
        self.expect(&TokenKind::RBrace, "`}`");
        (members, init_blocks, secondary_ctors)
    }

    fn parse_secondary_ctor(
        &mut self,
        visibility: Visibility,
        annotations: Vec<Annotation>,
    ) -> Option<SecondaryCtor> {
        let kw = self.bump(); // `constructor`
        self.expect(&TokenKind::LParen, "`(`")?;
        let params = self.parse_param_list();
        self.expect(&TokenKind::RParen, "`)`")?;
        self.skip_nl();
        let delegation = if matches!(self.peek_kind(), TokenKind::Colon) {
            self.bump();
            self.skip_nl();
            // Either `this` or `super` keyword, followed by `(args)`.
            let kind = match self.peek_kind() {
                TokenKind::Keyword(Keyword::This) => Some(true),
                TokenKind::Keyword(Keyword::Super) => Some(false),
                _ => None,
            };
            if let Some(is_this) = kind {
                self.bump();
                self.expect(&TokenKind::LParen, "`(`");
                let mut args = Vec::new();
                loop {
                    self.skip_nl();
                    if matches!(self.peek_kind(), TokenKind::RParen) {
                        break;
                    }
                    let Some(a) = self.parse_expr() else { break };
                    args.push(a);
                    self.skip_nl();
                    if matches!(self.peek_kind(), TokenKind::Comma) {
                        self.bump();
                    } else {
                        break;
                    }
                }
                self.expect(&TokenKind::RParen, "`)`");
                if is_this {
                    CtorDelegation::This(args)
                } else {
                    CtorDelegation::Super(args)
                }
            } else {
                CtorDelegation::None
            }
        } else {
            CtorDelegation::None
        };
        self.skip_nl();
        let body = if matches!(self.peek_kind(), TokenKind::LBrace) {
            self.parse_block()
        } else {
            None
        };
        let end = self.tokens[self.pos.saturating_sub(1)].span;
        Some(SecondaryCtor {
            params,
            delegation,
            body,
            visibility,
            annotations,
            span: kw.span.join(end),
        })
    }

    fn parse_class_param_list(&mut self) -> Vec<ClassParam> {
        let mut params = Vec::new();
        loop {
            self.skip_nl();
            let annotations = self.parse_annotations();
            // Visibility modifiers in front of a param.
            let mut visibility = Visibility::Public;
            while matches!(self.peek_kind(), TokenKind::Ident) {
                let text = self.text(self.current_span());
                match text {
                    "public" => { visibility = Visibility::Public; self.bump(); self.skip_nl(); }
                    "private" => { visibility = Visibility::Private; self.bump(); self.skip_nl(); }
                    "protected" => { visibility = Visibility::Protected; self.bump(); self.skip_nl(); }
                    "internal" => { visibility = Visibility::Internal; self.bump(); self.skip_nl(); }
                    "override" => { self.bump(); self.skip_nl(); }
                    _ => break,
                }
            }
            if matches!(self.peek_kind(), TokenKind::RParen | TokenKind::Eof) {
                break;
            }
            // Optional `vararg` modifier on a primary-ctor parameter.
            let mut is_vararg = false;
            if matches!(self.peek_kind(), TokenKind::Ident)
                && self.text(self.current_span()) == "vararg"
            {
                self.bump();
                self.skip_nl();
                is_vararg = true;
            }
            let property = match self.peek_kind() {
                TokenKind::Keyword(Keyword::Val) => {
                    self.bump();
                    Some(false)
                }
                TokenKind::Keyword(Keyword::Var) => {
                    self.bump();
                    Some(true)
                }
                _ => None,
            };
            let Some(name) = self.parse_ident("parameter name") else {
                self.recover_until_paren();
                break;
            };
            let start = name.span;
            self.expect(&TokenKind::Colon, "`:`");
            let ty = self.parse_type().unwrap_or_else(|| TypeRef {
                name: Ident { name: "Any".into(), span: name.span },
                nullable: true,
                span: name.span,
                type_args: Vec::new(),
                function: None,
                definitely_non_null: false,
                annotations: Vec::new(),
            });
            let mut default = None;
            self.skip_nl();
            if matches!(self.peek_kind(), TokenKind::Eq) {
                self.bump();
                self.skip_nl();
                default = self.parse_expr();
            }
            let end = default.as_ref().map_or(ty.span, |d| d.span());
            params.push(ClassParam {
                property,
                name,
                ty,
                default,
                visibility,
                is_vararg,
                annotations,
                span: start.join(end),
            });
            self.skip_nl();
            if matches!(self.peek_kind(), TokenKind::Comma) {
                self.bump();
            } else {
                break;
            }
        }
        params
    }

    /// Parse a `<T, out U : Foo, reified V>`-style type-parameter list.
    /// Caller has verified the cursor is at `<`. Returns the parsed params;
    /// `reified` is only accepted when `allow_reified` is set (i.e. on
    /// functions, not classes).
    fn parse_type_params(&mut self, allow_reified: bool) -> Vec<TypeParam> {
        if !matches!(self.peek_kind(), TokenKind::Lt) {
            return Vec::new();
        }
        self.bump();
        let mut params = Vec::new();
        loop {
            self.skip_nl();
            let annotations = self.parse_annotations();
            if matches!(self.peek_kind(), TokenKind::Gt | TokenKind::Eof) {
                break;
            }
            let start = self.current_span();
            let mut variance = Variance::Invariant;
            let mut is_reified = false;
            loop {
                if matches!(self.peek_kind(), TokenKind::Keyword(Keyword::In)) {
                    self.bump();
                    self.skip_nl();
                    variance = Variance::In;
                    continue;
                }
                match self.peek_ident_text() {
                    Some("out") => {
                        self.bump();
                        self.skip_nl();
                        variance = Variance::Out;
                        continue;
                    }
                    Some("reified") if allow_reified => {
                        self.bump();
                        self.skip_nl();
                        is_reified = true;
                        continue;
                    }
                    _ => break,
                }
            }
            let Some(name) = self.parse_ident("type parameter name") else {
                break;
            };
            let mut upper_bound = None;
            self.skip_nl();
            if matches!(self.peek_kind(), TokenKind::Colon) {
                self.bump();
                self.skip_nl();
                upper_bound = self.parse_type();
            }
            let end = upper_bound.as_ref().map_or(name.span, |t| t.span);
            params.push(TypeParam {
                name,
                variance,
                upper_bound,
                is_reified,
                annotations,
                span: start.join(end),
            });
            self.skip_nl();
            if matches!(self.peek_kind(), TokenKind::Comma) {
                self.bump();
            } else {
                break;
            }
        }
        self.expect(&TokenKind::Gt, "`>`");
        params
    }

    /// Parse a `where T : Foo, T : Bar` clause. Returns an empty vec when
    /// the cursor is not at `where`.
    fn parse_where_clause(&mut self) -> Vec<WhereBound> {
        let mut bounds = Vec::new();
        // Look across leading newlines without committing — `where` may sit
        // on the next line, but if it isn't there we must leave the newlines
        // alone so they continue serving as statement separators.
        let mut i = self.pos;
        while matches!(self.tokens.get(i).map(|t| &t.kind), Some(TokenKind::Newline)) {
            i += 1;
        }
        let next = self.tokens.get(i);
        let is_where = matches!(next.map(|t| &t.kind), Some(TokenKind::Ident))
            && next.map(|t| self.text(t.span)) == Some("where");
        if !is_where {
            return bounds;
        }
        self.pos = i;
        self.bump();
        loop {
            self.skip_nl();
            let Some(name) = self.parse_ident("type parameter name") else {
                break;
            };
            let start = name.span;
            self.expect(&TokenKind::Colon, "`:`");
            self.skip_nl();
            let Some(ty) = self.parse_type() else { break };
            let span = start.join(ty.span);
            bounds.push(WhereBound { name, bound: ty, span });
            self.skip_nl();
            if matches!(self.peek_kind(), TokenKind::Comma) {
                self.bump();
            } else {
                break;
            }
        }
        bounds
    }

    /// Parse `<TypeArg, …>` (with optional `*`, `out`, `in` projection on
    /// each arg). Caller has verified the cursor is at `<`. Used by
    /// `parse_simple_type` to capture generic instantiations like
    /// `List<out Any>`.
    fn parse_type_args(&mut self) -> Vec<TypeArg> {
        if !matches!(self.peek_kind(), TokenKind::Lt) {
            return Vec::new();
        }
        self.bump();
        let mut args = Vec::new();
        loop {
            self.skip_nl();
            if matches!(self.peek_kind(), TokenKind::Gt | TokenKind::Eof) {
                break;
            }
            let start = self.current_span();
            if matches!(self.peek_kind(), TokenKind::Star) {
                let s = self.bump();
                args.push(TypeArg {
                    variance: Variance::Invariant,
                    is_star: true,
                    ty: TypeRef {
                        name: Ident { name: "*".into(), span: s.span },
                        nullable: false,
                        span: s.span,
                        type_args: Vec::new(),
                        function: None,
                        definitely_non_null: false,
                        annotations: Vec::new(),
                    },
                    span: s.span,
                });
            } else {
                let mut variance = Variance::Invariant;
                if matches!(self.peek_kind(), TokenKind::Keyword(Keyword::In)) {
                    self.bump();
                    self.skip_nl();
                    variance = Variance::In;
                } else if self.peek_ident_text() == Some("out") {
                    self.bump();
                    self.skip_nl();
                    variance = Variance::Out;
                }
                let Some(t) = self.parse_type() else { break };
                let span = start.join(t.span);
                args.push(TypeArg { variance, is_star: false, ty: t, span });
            }
            self.skip_nl();
            if matches!(self.peek_kind(), TokenKind::Comma) {
                self.bump();
            } else {
                break;
            }
        }
        self.expect(&TokenKind::Gt, "`>`");
        args
    }

    /// Parse a call-site type-arg list like `foo<String>(…)`. Variance
    /// markers (`in`/`out`) on call-site type args are nonsensical and
    /// silently dropped (Kotlin rejects them as a separate diagnostic). `*`
    /// star-projection at a call site is also dropped — call-site star is
    /// only meaningful in *types*, not in invocation generics.
    fn parse_call_type_args(&mut self) -> Vec<TypeRef> {
        if !matches!(self.peek_kind(), TokenKind::Lt) {
            return Vec::new();
        }
        self.bump();
        let mut args = Vec::new();
        loop {
            self.skip_nl();
            if matches!(self.peek_kind(), TokenKind::Gt | TokenKind::Eof) {
                break;
            }
            if matches!(self.peek_kind(), TokenKind::Star) {
                let s = self.bump();
                args.push(TypeRef {
                    name: Ident { name: "*".into(), span: s.span },
                    nullable: false,
                    span: s.span,
                    type_args: Vec::new(),
                    function: None,
                    definitely_non_null: false,
                    annotations: Vec::new(),
                });
            } else if matches!(self.peek_kind(), TokenKind::Ident)
                && self.text(self.current_span()) == "_"
            {
                // Spec §4.5.3 underscore type argument — placeholder for
                // partial inference. Recorded as a TypeRef whose name is
                // `_`; downstream typeck treats this as Type::Unresolved
                // and lets the surrounding inference flow set it.
                let s = self.bump();
                args.push(TypeRef {
                    name: Ident { name: "_".into(), span: s.span },
                    nullable: false,
                    span: s.span,
                    type_args: Vec::new(),
                    function: None,
                    definitely_non_null: false,
                    annotations: Vec::new(),
                });
            } else {
                if matches!(self.peek_kind(), TokenKind::Keyword(Keyword::In)) {
                    self.bump();
                    self.skip_nl();
                } else if self.peek_ident_text() == Some("out") {
                    self.bump();
                    self.skip_nl();
                }
                let Some(t) = self.parse_type() else { break };
                args.push(t);
            }
            self.skip_nl();
            if matches!(self.peek_kind(), TokenKind::Comma) {
                self.bump();
            } else {
                break;
            }
        }
        self.expect(&TokenKind::Gt, "`>`");
        args
    }

    fn parse_fun(&mut self, flags: ModifierFlags) -> Option<Function> {
        let kw = self.bump(); // `fun`
        self.skip_nl();
        let type_params = if matches!(self.peek_kind(), TokenKind::Lt) {
            let tp = self.parse_type_params(true);
            self.skip_nl();
            tp
        } else {
            Vec::new()
        };
        // Receiver-typed extension function: `fun T.foo(...)` or
        // `fun T?.foo(...)`. We pre-scan for the pattern
        // `Ident (?)? . Ident` so the regular non-extension path can
        // continue using `parse_ident` for the function name.
        let receiver_type = if self.looks_like_extension_receiver() {
            let ty = self.parse_type();
            // `parse_type` already consumed the `Ident` and any trailing
            // `?`; now consume the dot before the function name.
            self.expect(&TokenKind::Dot, "`.`")?;
            self.skip_nl();
            ty
        } else {
            None
        };
        let name = self.parse_ident("function name")?;
        self.expect(&TokenKind::LParen, "`(`")?;
        let params = self.parse_param_list();
        self.expect(&TokenKind::RParen, "`)`")?;
        let return_type = if matches!(self.peek_kind(), TokenKind::Colon) {
            self.bump();
            self.parse_type()
        } else {
            None
        };
        let where_bounds = self.parse_where_clause();
        self.skip_nl();
        let body = match self.peek_kind() {
            TokenKind::LBrace => self.parse_block().map(FunctionBody::Block),
            TokenKind::Eq => {
                self.bump();
                self.skip_nl();
                self.parse_expr().map(FunctionBody::Expr)
            }
            _ => None, // Function declaration without body (abstract / external).
        };
        let end = self.tokens[self.pos.saturating_sub(1)].span;
        Some(Function {
            name,
            receiver_type,
            type_params,
            where_bounds,
            params,
            return_type,
            body,
            is_open: flags.is_open || flags.is_abstract,
            is_override: flags.is_override,
            is_abstract: flags.is_abstract,
            is_operator: flags.is_operator,
            is_inline: flags.is_inline,
            is_infix: flags.is_infix,
            is_tailrec: flags.is_tailrec,
            is_suspend: flags.is_suspend,
            visibility: flags.visibility,
            annotations: flags.annotations,
            span: kw.span.join(end),
        })
    }

    /// Anonymous-function expression: `fun [<T>] [Receiver.](...) [: Ret] [body]`.
    /// No name follows the `fun` keyword. `return` inside the body is a local
    /// return out of this function, not the enclosing one.
    fn parse_anon_fun(&mut self) -> Option<Expr> {
        let kw = self.bump(); // `fun`
        self.skip_nl();
        if matches!(self.peek_kind(), TokenKind::Lt) {
            let _ = self.parse_type_params(false);
            self.skip_nl();
        }
        let receiver_ty = if self.looks_like_anon_fun_receiver() {
            let mut ty = self.parse_simple_type();
            if let Some(t) = ty.as_mut() {
                if self.peek_kind().is_question() {
                    let q = self.bump();
                    t.nullable = true;
                    t.span = t.span.join(q.span);
                }
            }
            self.expect(&TokenKind::Dot, "`.`")?;
            self.skip_nl();
            ty
        } else {
            None
        };
        self.expect(&TokenKind::LParen, "`(`")?;
        let params = self.parse_param_list();
        self.expect(&TokenKind::RParen, "`)`")?;
        let return_ty = if matches!(self.peek_kind(), TokenKind::Colon) {
            self.bump();
            self.parse_type()
        } else {
            None
        };
        let _ = self.parse_where_clause();
        self.skip_nl();
        let body = match self.peek_kind() {
            TokenKind::LBrace => self.parse_block().map(|b| Box::new(FunctionBody::Block(b))),
            TokenKind::Eq => {
                self.bump();
                self.skip_nl();
                self.parse_expr().map(|e| Box::new(FunctionBody::Expr(e)))
            }
            _ => None,
        };
        let end = self.tokens[self.pos.saturating_sub(1)].span;
        Some(Expr::AnonFun {
            receiver_ty,
            params,
            return_ty,
            body,
            is_suspend: false,
            span: kw.span.join(end),
        })
    }

    /// Look-ahead for `Ident (?)? . (` — anonymous-function receiver shape.
    /// Distinct from named-fun extension receivers because no name follows
    /// the dot.
    fn looks_like_anon_fun_receiver(&self) -> bool {
        let Some(t0) = self.tokens.get(self.pos) else { return false };
        if !matches!(t0.kind, TokenKind::Ident) {
            return false;
        }
        let mut j = self.pos + 1;
        if self.tokens.get(j).map(|t| t.kind.is_question()).unwrap_or(false) {
            j += 1;
        }
        matches!(self.tokens.get(j).map(|t| &t.kind), Some(TokenKind::Dot))
            && matches!(self.tokens.get(j + 1).map(|t| &t.kind), Some(TokenKind::LParen))
    }

    /// Look-ahead for `Ident (?)? . Ident` at the current cursor — the
    /// shape that introduces an extension-function's receiver type.
    /// Avoids parser commitment so the regular non-extension declaration
    /// path stays unaffected when no receiver is present.
    fn looks_like_extension_receiver(&self) -> bool {
        let Some(t0) = self.tokens.get(self.pos) else { return false };
        if !matches!(t0.kind, TokenKind::Ident) {
            return false;
        }
        let mut j = self.pos + 1;
        // Skip a balanced generic-argument list (`<T>` / `<A, B<C>>`).
        if matches!(self.tokens.get(j).map(|t| &t.kind), Some(TokenKind::Lt)) {
            let mut depth = 1;
            j += 1;
            while depth > 0 {
                match self.tokens.get(j).map(|t| &t.kind) {
                    Some(TokenKind::Lt) => depth += 1,
                    Some(TokenKind::Gt) => depth -= 1,
                    None | Some(TokenKind::Eof) => return false,
                    _ => {}
                }
                j += 1;
            }
        }
        if self.tokens.get(j).map(|t| t.kind.is_question()).unwrap_or(false) {
            j += 1;
        }
        matches!(self.tokens.get(j).map(|t| &t.kind), Some(TokenKind::Dot))
            && matches!(self.tokens.get(j + 1).map(|t| &t.kind), Some(TokenKind::Ident))
    }

    fn parse_param_list(&mut self) -> Vec<Param> {
        let mut params = Vec::new();
        loop {
            self.skip_nl();
            if matches!(self.peek_kind(), TokenKind::RParen | TokenKind::Eof) {
                break;
            }
            let annotations = self.parse_annotations();
            // Allow `val`/`var` markers in constructor-like params; ignore.
            if matches!(
                self.peek_kind(),
                TokenKind::Keyword(Keyword::Val) | TokenKind::Keyword(Keyword::Var)
            ) {
                self.bump();
                self.skip_nl();
            }
            let mut is_vararg = false;
            let mut is_crossinline = false;
            let mut is_noinline = false;
            loop {
                match self.peek_ident_text() {
                    Some("vararg") => {
                        self.bump();
                        self.skip_nl();
                        is_vararg = true;
                    }
                    Some("crossinline") => {
                        self.bump();
                        self.skip_nl();
                        is_crossinline = true;
                    }
                    Some("noinline") => {
                        self.bump();
                        self.skip_nl();
                        is_noinline = true;
                    }
                    _ => break,
                }
            }
            let Some(name) = self.parse_ident("parameter name") else {
                self.recover_until_paren();
                break;
            };
            let start = name.span;
            self.expect(&TokenKind::Colon, "`:`");
            let ty = self.parse_type().unwrap_or_else(|| TypeRef {
                name: Ident { name: "Any".into(), span: name.span },
                nullable: true,
                span: name.span,
                type_args: Vec::new(),
                function: None,
                definitely_non_null: false,
                annotations: Vec::new(),
            });
            let mut default = None;
            if matches!(self.peek_kind(), TokenKind::Eq) {
                self.bump();
                self.skip_nl();
                default = self.parse_expr();
            }
            let end = default.as_ref().map_or(ty.span, |d| d.span());
            params.push(Param {
                name,
                ty,
                default,
                is_vararg,
                is_crossinline,
                is_noinline,
                annotations,
                span: start.join(end),
            });
            self.skip_nl();
            if matches!(self.peek_kind(), TokenKind::Comma) {
                self.bump();
            } else {
                break;
            }
        }
        params
    }

    fn recover_until_paren(&mut self) {
        while !matches!(
            self.peek_kind(),
            TokenKind::RParen | TokenKind::Eof | TokenKind::LBrace
        ) {
            self.bump();
        }
    }

    fn parse_property(&mut self) -> Option<Property> {
        self.parse_property_with_flags(ModifierFlags::default())
    }

    fn parse_property_with_flags(&mut self, flags: ModifierFlags) -> Option<Property> {
        if let Some(sp) = flags.suspend_span {
            self.error(
                "T0114",
                "`suspend` modifier is not allowed on a property declaration",
                sp,
            );
        }
        let kw_tok = self.bump();
        let mutable = matches!(kw_tok.kind, TokenKind::Keyword(Keyword::Var));
        self.skip_nl();
        let receiver_type = if self.looks_like_extension_receiver() {
            let ty = self.parse_type();
            self.expect(&TokenKind::Dot, "`.`")?;
            self.skip_nl();
            ty
        } else {
            None
        };
        let name = self.parse_ident("property name")?;
        let ty = if matches!(self.peek_kind(), TokenKind::Colon) {
            self.bump();
            self.parse_type()
        } else {
            None
        };
        let mut init: Option<Expr> = None;
        let mut delegate: Option<Expr> = None;
        if matches!(self.peek_kind(), TokenKind::Eq) {
            self.bump();
            self.skip_nl();
            init = self.parse_expr();
        } else if self.peek_ident_text() == Some("by") {
            self.bump();
            self.skip_nl();
            delegate = self.parse_expr();
        }
        // Optional get()/set(value) accessors. They may follow on the next
        // line or after newlines. Both can appear in either order.
        let mut getter: Option<Accessor> = None;
        let mut setter: Option<Accessor> = None;
        let mut setter_visibility: Option<Visibility> = None;
        loop {
            let save = self.pos;
            // Peek across newlines for an optional visibility modifier
            // followed by `get` / `set`. Accepts forms like `private set`
            // (no body) and `private get() = ...`.
            let mut i = self.pos;
            while matches!(self.tokens.get(i).map(|t| &t.kind), Some(TokenKind::Newline)) {
                i += 1;
            }
            let mut acc_visibility: Option<Visibility> = None;
            if let Some(tok) = self.tokens.get(i) {
                if matches!(tok.kind, TokenKind::Ident) {
                    let txt = self.text(tok.span);
                    let v = match txt {
                        "public" => Some(Visibility::Public),
                        "private" => Some(Visibility::Private),
                        "protected" => Some(Visibility::Protected),
                        "internal" => Some(Visibility::Internal),
                        _ => None,
                    };
                    if v.is_some() {
                        acc_visibility = v;
                        i += 1;
                        while matches!(self.tokens.get(i).map(|t| &t.kind), Some(TokenKind::Newline)) {
                            i += 1;
                        }
                    }
                }
            }
            let Some(tok) = self.tokens.get(i) else { break };
            if !matches!(tok.kind, TokenKind::Ident) {
                break;
            }
            let ident_text = self.text(tok.span);
            let is_get = ident_text == "get";
            let is_set = ident_text == "set";
            if !is_get && !is_set {
                break;
            }
            let next = self.tokens.get(i + 1).map(|t| &t.kind);
            // Bare `private set` (no parens) is valid: it leaves the default
            // accessor in place but restricts visibility. We synthesize a
            // bodyless accessor whose presence carries only the visibility.
            let is_bodyless = !matches!(next, Some(TokenKind::LParen));
            if is_bodyless && acc_visibility.is_none() {
                // No modifier and no `(` — not an accessor, bail.
                break;
            }
            // Commit — consume the newlines, optional vis, and accessor.
            self.pos = i;
            let start_span = self.bump().span; // get / set
            if is_bodyless {
                // `private set` (no `(...)`): record visibility on the
                // Property itself; do NOT synthesize a custom accessor —
                // the default one stays in effect.
                if is_set {
                    if let Some(v) = acc_visibility {
                        setter_visibility = Some(v);
                    }
                }
                continue;
            }
            self.expect(&TokenKind::LParen, "`(`")?;
            let mut params: Vec<Ident> = Vec::new();
            if !matches!(self.peek_kind(), TokenKind::RParen) {
                let p = self.parse_ident("setter parameter")?;
                params.push(p);
                if matches!(self.peek_kind(), TokenKind::Colon) {
                    self.bump();
                    let _ = self.parse_type();
                }
            }
            self.expect(&TokenKind::RParen, "`)`")?;
            let return_type = if matches!(self.peek_kind(), TokenKind::Colon) {
                self.bump();
                self.parse_type()
            } else {
                None
            };
            self.skip_nl();
            let body = if matches!(self.peek_kind(), TokenKind::Eq) {
                self.bump();
                self.skip_nl();
                let e = self.parse_expr()?;
                FunctionBody::Expr(e)
            } else if matches!(self.peek_kind(), TokenKind::LBrace) {
                let b = self.parse_block()?;
                FunctionBody::Block(b)
            } else {
                self.pos = save;
                break;
            };
            let end = self.tokens[self.pos.saturating_sub(1)].span;
            let acc = Accessor {
                params,
                return_type,
                body,
                visibility: acc_visibility,
                annotations: Vec::new(),
                span: start_span.join(end),
            };
            if is_get {
                getter = Some(acc);
            } else {
                setter = Some(acc);
            }
        }
        let end = self.tokens[self.pos.saturating_sub(1)].span;
        Some(Property {
            mutable,
            name,
            receiver_type,
            ty,
            init,
            delegate,
            getter,
            setter,
            is_abstract: flags.is_abstract,
            is_open: flags.is_open,
            is_override: flags.is_override,
            is_lateinit: flags.is_lateinit,
            is_const: flags.is_const,
            is_inline: flags.is_inline,
            setter_visibility,
            visibility: flags.visibility,
            annotations: flags.annotations,
            span: kw_tok.span.join(end),
        })
    }

    /// Returns the text of the next token if it is an `Ident`, without
    /// consuming.
    fn peek_ident_text(&self) -> Option<&str> {
        let tok = self.tokens.get(self.pos)?;
        if matches!(tok.kind, TokenKind::Ident) {
            Some(self.text(tok.span))
        } else {
            None
        }
    }

    // ---------- types ----------

    fn parse_type(&mut self) -> Option<TypeRef> {
        self.skip_nl();
        // Soft-keyword `suspend` before a function type — accepted but not
        // yet enforced anywhere (M31 territory).
        let mut is_suspend = false;
        if self.peek_ident_text() == Some("suspend") {
            // Only consume as a type modifier when followed by `(` or by an
            // identifier that begins a receiver type — otherwise we'd eat a
            // type literally named `suspend`.
            let next = self.tokens.get(self.pos + 1).map(|t| &t.kind);
            if matches!(next, Some(TokenKind::LParen) | Some(TokenKind::Ident)) {
                self.bump();
                self.skip_nl();
                is_suspend = true;
            }
        }
        // Type-use-site annotations: `@Foo @Bar Baz` / `@UnsafeVariance T`.
        // Accept zero or more annotation sets and stash them on the
        // resulting TypeRef.
        let type_annotations = self.parse_annotations();
        self.skip_nl();
        let start_span = self.current_span();
        let mut ty = if matches!(self.peek_kind(), TokenKind::LParen) {
            self.parse_parens_or_function_type(start_span)?
        } else {
            self.parse_simple_type()?
        };
        if !type_annotations.is_empty() {
            ty.annotations.extend(type_annotations);
        }
        // Trailing `?` makes the whole type nullable.
        if self.peek_kind().is_question() {
            let q = self.bump();
            ty.nullable = true;
            ty.span = ty.span.join(q.span);
        }
        // Definitely-non-nullable type: `T & Any`. Per spec only valid when
        // T is a type parameter, but we accept the shape here and let typeck
        // diagnose non-type-parameter receivers.
        {
            let save_pos = self.pos;
            let mut i = self.pos;
            while matches!(self.tokens.get(i).map(|t| &t.kind), Some(TokenKind::Newline)) {
                i += 1;
            }
            if matches!(self.tokens.get(i).map(|t| &t.kind), Some(TokenKind::Amp)) {
                self.pos = i;
                self.bump(); // `&`
                self.skip_nl();
                let rhs_start = self.current_span();
                let Some(rhs) = self.parse_simple_type() else {
                    self.pos = save_pos;
                    return Some(ty);
                };
                if rhs.name.name != "Any" || rhs.nullable {
                    self.error(
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
        // continuation handled elsewhere.
        if matches!(self.peek_kind(), TokenKind::Dot)
            && matches!(self.tokens.get(self.pos + 1).map(|t| &t.kind), Some(TokenKind::LParen))
        {
            self.bump(); // '.'
            let (params, _lp, rp) = self.parse_function_type_params()?;
            self.skip_nl();
            let arrow = self.expect(&TokenKind::Arrow, "`->`")?;
            self.skip_nl();
            let ret = self.parse_type()?;
            let ret_span = ret.span;
            let span = ty.span.join(ret_span);
            let func = FunctionTypeRef {
                receiver: Some(ty),
                params,
                ret,
                is_suspend,
                span: rp.span.join(arrow.span).join(ret_span),
            };
            return Some(TypeRef {
                name: Ident { name: "<function>".into(), span },
                nullable: false,
                span,
                type_args: Vec::new(),
                function: Some(Box::new(func)),
                definitely_non_null: false,
                annotations: Vec::new(),
            });
        }
        // Propagate `suspend` onto the parens-form function type when one
        // was produced. If `suspend` was claimed but no function type
        // materialised, we silently drop it (parity-safe; lambdas don't
        // care).
        if is_suspend {
            if let Some(f) = ty.function.as_mut() {
                f.is_suspend = true;
            }
        }
        Some(ty)
    }

    /// Parse a simple (named) type with optional generic arguments. Does
    /// NOT consume a trailing `?` — that's the caller's job so function-type
    /// nullability composes correctly.
    fn parse_simple_type(&mut self) -> Option<TypeRef> {
        let name = self.parse_ident("type")?;
        let type_args = if matches!(self.peek_kind(), TokenKind::Lt) {
            self.parse_type_args()
        } else {
            Vec::new()
        };
        let end = self.tokens[self.pos.saturating_sub(1)].span;
        Some(TypeRef {
            name: name.clone(),
            nullable: false,
            span: name.span.join(end),
            type_args,
            function: None,
            definitely_non_null: false,
            annotations: Vec::new(),
        })
    }

    /// Spec userType form `simpleUserType ('.' simpleUserType)*`. Used at
    /// sites that may name a nested classifier (`is Outer.Inner`, `as
    /// Outer.Inner`, `catch (e: Outer.Inner)`). Calls `parse_type` for the
    /// leading head (which handles nullability, function-type shape, and
    /// type arguments) then folds any trailing `.Ident` segments into the
    /// name. Regular `parse_type` returns the bare leading segment so that
    /// extension-function syntax like `operator fun Foo.bar()` keeps the
    /// trailing name as the function's identity.
    fn parse_qualified_type(&mut self) -> Option<TypeRef> {
        let mut head = self.parse_type()?;
        // Function types and nullable suffixes block further dot folding.
        if head.function.is_some() || head.nullable {
            return Some(head);
        }
        let mut start = head.span;
        while matches!(self.peek_kind(), TokenKind::Dot) {
            let next = self.tokens.get(self.pos + 1).map(|t| &t.kind);
            if !matches!(next, Some(TokenKind::Ident)) {
                break;
            }
            self.bump(); // '.'
            let Some(seg) = self.parse_ident("type segment") else { break };
            let new_name = Ident {
                name: format!("{}.{}", head.name.name, seg.name),
                span: start.join(seg.span),
            };
            start = new_name.span;
            let type_args = if matches!(self.peek_kind(), TokenKind::Lt) {
                self.parse_type_args()
            } else {
                Vec::new()
            };
            head = TypeRef {
                name: new_name,
                nullable: false,
                span: start,
                type_args,
                function: None,
                definitely_non_null: false,
                annotations: Vec::new(),
            };
        }
        // Trailing nullable suffix after dotted form: `S.A?`.
        if self.peek_kind().is_question() {
            let q = self.bump();
            head.nullable = true;
            head.span = head.span.join(q.span);
        }
        Some(head)
    }


    /// At `(`. Either:
    ///   - `(T)` — parenthesized type (returns the inner type).
    ///   - `(T1, T2, ...) -> R` — function type parameters.
    fn parse_parens_or_function_type(&mut self, start: Span) -> Option<TypeRef> {
        let lp = self.bump(); // '('
        let mut items: Vec<TypeRef> = Vec::new();
        let mut saw_comma = false;
        loop {
            self.skip_nl();
            if matches!(self.peek_kind(), TokenKind::RParen) {
                break;
            }
            // Allow `name: Type` shape inside function-type params per spec
            // by tolerating an identifier followed by `:`.
            if matches!(self.peek_kind(), TokenKind::Ident) {
                let save = self.pos;
                let _id = self.bump();
                self.skip_nl();
                if matches!(self.peek_kind(), TokenKind::Colon) {
                    self.bump();
                    self.skip_nl();
                } else {
                    self.pos = save;
                }
            }
            let Some(t) = self.parse_type() else { break };
            items.push(t);
            self.skip_nl();
            if matches!(self.peek_kind(), TokenKind::Comma) {
                self.bump();
                saw_comma = true;
            } else {
                break;
            }
        }
        let rp = self.expect(&TokenKind::RParen, "`)`")?;
        self.skip_nl();
        if matches!(self.peek_kind(), TokenKind::Arrow) {
            // Function type.
            let arrow = self.bump();
            self.skip_nl();
            let ret = self.parse_type()?;
            let ret_span = ret.span;
            let span = start.join(ret_span);
            let func = FunctionTypeRef {
                receiver: None,
                params: items,
                ret,
                is_suspend: false,
                span: lp.span.join(arrow.span).join(ret_span),
            };
            Some(TypeRef {
                name: Ident { name: "<function>".into(), span },
                nullable: false,
                span,
                type_args: Vec::new(),
                function: Some(Box::new(func)),
                definitely_non_null: false,
                annotations: Vec::new(),
            })
        } else if items.len() == 1 && !saw_comma {
            // Parenthesized type.
            let mut inner = items.remove(0);
            inner.span = lp.span.join(rp.span);
            Some(inner)
        } else {
            let span = lp.span.join(rp.span);
            self.error(
                "E0003",
                "expected `->` after function-type parameter list",
                span,
            );
            None
        }
    }

    /// Parse `( T1, T2, ... )` returning the list of parameter types and
    /// both paren spans. Used for the receiver-typed function-type tail.
    fn parse_function_type_params(&mut self) -> Option<(Vec<TypeRef>, Token, Token)> {
        let lp = self.expect(&TokenKind::LParen, "`(`")?;
        let mut items: Vec<TypeRef> = Vec::new();
        loop {
            self.skip_nl();
            if matches!(self.peek_kind(), TokenKind::RParen) {
                break;
            }
            if matches!(self.peek_kind(), TokenKind::Ident) {
                let save = self.pos;
                let _id = self.bump();
                self.skip_nl();
                if matches!(self.peek_kind(), TokenKind::Colon) {
                    self.bump();
                    self.skip_nl();
                } else {
                    self.pos = save;
                }
            }
            let Some(t) = self.parse_type() else { break };
            items.push(t);
            self.skip_nl();
            if matches!(self.peek_kind(), TokenKind::Comma) {
                self.bump();
            } else {
                break;
            }
        }
        let rp = self.expect(&TokenKind::RParen, "`)`")?;
        Some((items, lp, rp))
    }

    // ---------- identifiers ----------

    fn parse_ident(&mut self, what: &str) -> Option<Ident> {
        self.skip_nl();
        if matches!(self.peek_kind(), TokenKind::Ident) {
            let tok = self.bump();
            Some(Ident { name: self.ident_name(tok.span), span: tok.span })
        } else {
            let span = self.current_span();
            self.error("E0003", format!("expected {what}"), span);
            None
        }
    }

    // ---------- recovery ----------

    fn recover_to_top_level(&mut self) {
        while !matches!(
            self.peek_kind(),
            TokenKind::Eof
                | TokenKind::Keyword(Keyword::Fun)
                | TokenKind::Keyword(Keyword::Val)
                | TokenKind::Keyword(Keyword::Var)
                | TokenKind::Keyword(Keyword::Class)
                | TokenKind::Keyword(Keyword::Object)
                | TokenKind::Keyword(Keyword::Interface)
                | TokenKind::Keyword(Keyword::Package)
                | TokenKind::Keyword(Keyword::Import)
        ) {
            self.bump();
        }
    }

    fn recover_to_stmt_end(&mut self) {
        while !matches!(
            self.peek_kind(),
            TokenKind::Newline
                | TokenKind::Semicolon
                | TokenKind::RBrace
                | TokenKind::Eof
        ) {
            self.bump();
        }
    }

    // ---------- blocks / statements ----------

    fn parse_block(&mut self) -> Option<Block> {
        let lbrace = self.expect(&TokenKind::LBrace, "`{`")?;
        let mut stmts = Vec::new();
        loop {
            self.skip_stmt_separators();
            if matches!(self.peek_kind(), TokenKind::RBrace | TokenKind::Eof) {
                break;
            }
            if let Some(s) = self.parse_stmt() {
                stmts.push(s);
            } else {
                self.recover_to_stmt_end();
            }
            // After a statement, a newline or `;` is the separator.
            if !matches!(
                self.peek_kind(),
                TokenKind::Newline | TokenKind::Semicolon | TokenKind::RBrace | TokenKind::Eof
            ) {
                let span = self.current_span();
                self.error("E0004", "expected newline or `;` between statements", span);
                self.recover_to_stmt_end();
            }
        }
        let rbrace = self.expect(&TokenKind::RBrace, "`}`")?;
        Some(Block { stmts, span: lbrace.span.join(rbrace.span) })
    }

    fn skip_stmt_separators(&mut self) {
        while matches!(self.peek_kind(), TokenKind::Newline | TokenKind::Semicolon) {
            self.pos += 1;
        }
    }

    fn parse_stmt(&mut self) -> Option<Stmt> {
        let save = self.pos;
        let flags = self.skip_modifiers_with_flags();
        match self.peek_kind() {
            TokenKind::Keyword(Keyword::Val) | TokenKind::Keyword(Keyword::Var) => {
                // `val (a, b) = expr` — destructuring declaration. Falls through
                // to plain property parsing on a single name.
                let next = self.tokens.get(self.pos + 1).map(|t| &t.kind);
                if matches!(next, Some(TokenKind::LParen)) {
                    return self.parse_destructuring_decl();
                }
                self.parse_property().map(|p| Stmt::Decl(Decl::Property(p)))
            }
            TokenKind::Keyword(Keyword::Fun) => {
                let next = self.tokens.get(self.pos + 1).map(|t| &t.kind);
                if matches!(next, Some(TokenKind::Keyword(Keyword::Interface))) {
                    self.bump(); // `fun`
                    let visibility = flags.visibility;
                    let annotations = flags.annotations.clone();
                    return self
                        .parse_class(
                            ClassModifiers {
                                is_data: false,
                                is_companion: false,
                                is_enum: false,
                                is_sealed: flags.is_sealed,
                                is_open: false,
                                is_abstract: false,
                                is_inner: false,
                                is_fun_interface: true,
                                is_value: false,
                                is_annotation: false,
                            },
                            visibility,
                            annotations,
                        )
                        .map(|c| Stmt::Decl(Decl::Class(c)));
                }
                // Anonymous-function expression statement: `fun(...) ...`
                // or `fun <T>(...) ...`. No name follows the `fun` keyword.
                if matches!(next, Some(TokenKind::LParen) | Some(TokenKind::Lt)) {
                    self.pos = save;
                    return self.parse_expr_or_assign_stmt();
                }
                self.parse_fun(flags).map(|f| Stmt::Decl(Decl::Function(f)))
            }
            TokenKind::Keyword(Keyword::Class) | TokenKind::Keyword(Keyword::Interface) => {
                let visibility = flags.visibility;
                let annotations = flags.annotations.clone();
                let is_value = flags.is_value || flags.is_inline;
                if flags.is_inline && !flags.is_value {
                    if let Some(span) = flags.inline_span {
                        self.diagnostics.emit(
                            Diagnostic::warning(
                                "`inline class` is deprecated; use `value class` instead",
                                span,
                            )
                            .with_code("W0001"),
                        );
                    }
                }
                self.parse_class(
                    ClassModifiers {
                        is_data: flags.is_data,
                        is_companion: false,
                        is_enum: flags.is_enum,
                        is_sealed: flags.is_sealed,
                        is_open: flags.is_open,
                        is_abstract: flags.is_abstract,
                        is_inner: flags.is_inner,
                        is_fun_interface: false,
                        is_value,
                        is_annotation: flags.is_annotation,
                    },
                    visibility,
                    annotations,
                )
                .map(|c| Stmt::Decl(Decl::Class(c)))
            }
            TokenKind::Keyword(Keyword::Object) => {
                // `object Name { … }` — local singleton. `object { … }` /
                // `object : Super { … }` is an anonymous-object *expression*
                // and falls through to expression parsing.
                let next = self.tokens.get(self.pos + 1).map(|t| &t.kind);
                if matches!(next, Some(TokenKind::Ident)) {
                    self.parse_object(flags.is_data).map(|o| Stmt::Decl(Decl::Object(o)))
                } else {
                    // Roll back modifiers so the expression parser sees
                    // `object` at the head.
                    self.pos = save;
                    self.parse_expr_or_assign_stmt()
                }
            }
            TokenKind::Keyword(Keyword::Typealias) => {
                self.parse_typealias(flags.visibility, flags.annotations)
                    .map(|a| Stmt::Decl(Decl::TypeAlias(a)))
            }
            _ => {
                // No declaration matched — roll back so unrelated modifiers
                // (annotations on expressions, etc.) don't get swallowed.
                self.pos = save;
                self.parse_expr_or_assign_stmt()
            }
        }
    }

    fn parse_destructuring_decl(&mut self) -> Option<Stmt> {
        let kw = self.bump(); // val/var
        let mutable = matches!(kw.kind, TokenKind::Keyword(Keyword::Var));
        self.expect(&TokenKind::LParen, "`(`")?;
        let mut names: Vec<Ident> = Vec::new();
        loop {
            self.skip_nl();
            if matches!(self.peek_kind(), TokenKind::RParen) {
                break;
            }
            let span = self.current_span();
            let text = self.text(span);
            // Underscore-discard binding is parsed as an ident named `_`.
            let id = if text == "_" && matches!(self.peek_kind(), TokenKind::Ident) {
                self.bump();
                Ident { name: "_".into(), span }
            } else {
                self.parse_ident("destructured name")?
            };
            // Optional type annotation per name — consumed and discarded.
            if matches!(self.peek_kind(), TokenKind::Colon) {
                self.bump();
                let _ = self.parse_type();
            }
            names.push(id);
            self.skip_nl();
            if matches!(self.peek_kind(), TokenKind::Comma) {
                self.bump();
            } else {
                break;
            }
        }
        self.expect(&TokenKind::RParen, "`)`")?;
        self.expect(&TokenKind::Eq, "`=`")?;
        self.skip_nl();
        let init = self.parse_expr()?;
        let span = kw.span.join(init.span());
        Some(Stmt::DestructuringDecl { mutable, names, init, span })
    }

    fn parse_expr_or_assign_stmt(&mut self) -> Option<Stmt> {
        let lhs = self.parse_expr()?;
        // Assignment forms (statement-level only).
        let op = match self.peek_kind() {
            TokenKind::Eq => Some(AssignOp::Assign),
            TokenKind::PlusEq => Some(AssignOp::Add),
            TokenKind::MinusEq => Some(AssignOp::Sub),
            TokenKind::StarEq => Some(AssignOp::Mul),
            TokenKind::SlashEq => Some(AssignOp::Div),
            TokenKind::PercentEq => Some(AssignOp::Rem),
            _ => None,
        };
        if let Some(op) = op {
            self.bump();
            self.skip_nl();
            let rhs = self.parse_expr()?;
            let span = lhs.span().join(rhs.span());
            return Some(Stmt::Assign { target: lhs, op, value: rhs, span });
        }
        Some(Stmt::Expr(lhs))
    }

    // ---------- expressions (Pratt) ----------

    pub fn parse_expr(&mut self) -> Option<Expr> {
        self.parse_disjunction()
    }

    fn parse_disjunction(&mut self) -> Option<Expr> {
        let mut lhs = self.parse_conjunction()?;
        while matches!(self.peek_kind(), TokenKind::PipePipe) {
            self.bump();
            self.skip_nl();
            let rhs = self.parse_conjunction()?;
            let span = lhs.span().join(rhs.span());
            lhs = Expr::Binary { op: BinOp::Or, lhs: Box::new(lhs), rhs: Box::new(rhs), span };
        }
        Some(lhs)
    }

    fn parse_conjunction(&mut self) -> Option<Expr> {
        let mut lhs = self.parse_equality()?;
        while matches!(self.peek_kind(), TokenKind::AmpAmp) {
            self.bump();
            self.skip_nl();
            let rhs = self.parse_equality()?;
            let span = lhs.span().join(rhs.span());
            lhs = Expr::Binary { op: BinOp::And, lhs: Box::new(lhs), rhs: Box::new(rhs), span };
        }
        Some(lhs)
    }

    fn parse_equality(&mut self) -> Option<Expr> {
        let mut lhs = self.parse_comparison()?;
        loop {
            let op = match self.peek_kind() {
                TokenKind::EqEq => BinOp::Eq,
                TokenKind::BangEq => BinOp::Neq,
                TokenKind::EqEqEq => BinOp::IdentEq,
                TokenKind::BangEqEq => BinOp::IdentNeq,
                _ => break,
            };
            self.bump();
            self.skip_nl();
            let rhs = self.parse_comparison()?;
            let span = lhs.span().join(rhs.span());
            lhs = Expr::Binary { op, lhs: Box::new(lhs), rhs: Box::new(rhs), span };
        }
        Some(lhs)
    }

    fn parse_comparison(&mut self) -> Option<Expr> {
        let mut lhs = self.parse_named_checks()?;
        loop {
            // `in` / `!in` live at the comparison precedence level (Kotlin spec).
            // `!in` is the two tokens `!` then `in`. Recognized only when not
            // followed by a type — `!is` is handled inside parse_named_checks.
            let op = match self.peek_kind() {
                TokenKind::Lt => BinOp::Lt,
                TokenKind::Le => BinOp::Le,
                TokenKind::Gt => BinOp::Gt,
                TokenKind::Ge => BinOp::Ge,
                TokenKind::Keyword(Keyword::In) => BinOp::In,
                k if k.is_bang() => {
                    let next = self.tokens.get(self.pos + 1).map(|t| &t.kind);
                    if matches!(next, Some(TokenKind::Keyword(Keyword::In))) {
                        self.bump(); // `!`
                        BinOp::NotIn
                    } else {
                        break;
                    }
                }
                _ => break,
            };
            self.bump();
            self.skip_nl();
            let rhs = self.parse_named_checks()?;
            let span = lhs.span().join(rhs.span());
            lhs = Expr::Binary { op, lhs: Box::new(lhs), rhs: Box::new(rhs), span };
        }
        Some(lhs)
    }

    /// `expr is Type` and `expr !is Type`. Lower precedence than comparison,
    /// higher than elvis. `is` is a hard keyword in the lexer; `!is` is the
    /// two tokens `!` and `is`. We don't currently parse `in`/`!in` as binary
    /// ops — those forms appear inside `when` patterns and `for` headers,
    /// which parse them specifically. (Future work: surface `in`/`!in` as
    /// general binary ops once collection membership is wired.)
    fn parse_named_checks(&mut self) -> Option<Expr> {
        let mut lhs = self.parse_elvis()?;
        loop {
            let negated = match self.peek_kind() {
                TokenKind::Keyword(Keyword::Is) => false,
                k if k.is_bang() => {
                    let next = self.tokens.get(self.pos + 1).map(|t| &t.kind);
                    if !matches!(next, Some(TokenKind::Keyword(Keyword::Is))) {
                        break;
                    }
                    self.bump(); // `!`
                    true
                }
                _ => break,
            };
            self.bump(); // `is`
            self.skip_nl();
            let Some(ty) = self.parse_qualified_type() else { break };
            let span = lhs.span().join(ty.span);
            lhs = Expr::IsCheck { expr: Box::new(lhs), ty, negated, span };
        }
        Some(lhs)
    }

    fn parse_elvis(&mut self) -> Option<Expr> {
        let mut lhs = self.parse_infix_fn()?;
        while matches!(self.peek_kind(), TokenKind::QuestionColon) {
            self.bump();
            self.skip_nl();
            let rhs = self.parse_infix_fn()?;
            let span = lhs.span().join(rhs.span());
            lhs = Expr::Binary { op: BinOp::Elvis, lhs: Box::new(lhs), rhs: Box::new(rhs), span };
        }
        Some(lhs)
    }

    /// Infix function calls: `lhs <name> rhs` where `<name>` is any bare
    /// identifier resolvable to a function declared with the `infix`
    /// modifier. Desugars to `Call(Path[name], [lhs, rhs])`. Whether the
    /// resolved function actually carries `infix` is enforced later by the
    /// type checker (diagnostic T0029).
    fn parse_infix_fn(&mut self) -> Option<Expr> {
        let mut lhs = self.parse_range()?;
        loop {
            if !matches!(self.peek_kind(), TokenKind::Ident) {
                break;
            }
            let name_span = self.current_span();
            let name = self.text(name_span);
            if !is_valid_infix_name(name) {
                break;
            }
            if !self.lookahead_infix_rhs_starter() {
                break;
            }
            let name_str = name.to_string();
            self.bump();
            self.skip_nl();
            let rhs = self.parse_range()?;
            let span = lhs.span().join(rhs.span());
            let callee = Expr::Path {
                segments: vec![Ident { name: name_str, span: name_span }],
                span: name_span,
            };
            lhs = Expr::Call {
                callee: Box::new(callee),
                args: vec![lhs, rhs],
                arg_names: vec![None, None],
                type_args: Vec::new(),
                is_infix: true,
                span,
            };
        }
        Some(lhs)
    }

    /// After tentatively reading an infix-candidate identifier, peek one
    /// token ahead to confirm an expression continues on the same line.
    /// We do not cross a Newline (statement boundary), and we reject
    /// trailing punctuation that cannot begin an expression.
    fn lookahead_infix_rhs_starter(&self) -> bool {
        let next = self.tokens.get(self.pos + 1).map(|t| &t.kind);
        match next {
            None
            | Some(TokenKind::Newline)
            | Some(TokenKind::Semicolon)
            | Some(TokenKind::Eof)
            | Some(TokenKind::RBrace)
            | Some(TokenKind::RParen)
            | Some(TokenKind::RBracket)
            | Some(TokenKind::Comma)
            | Some(TokenKind::Eq)
            | Some(TokenKind::Colon)
            | Some(TokenKind::Arrow)
            | Some(TokenKind::Dot)
            | Some(TokenKind::QuestionDot) => false,
            Some(_) => true,
        }
    }

    fn parse_range(&mut self) -> Option<Expr> {
        let mut lhs = self.parse_additive()?;
        loop {
            let op = match self.peek_kind() {
                TokenKind::DotDot => BinOp::Range,
                TokenKind::DotDotLess => BinOp::RangeUntil,
                _ => break,
            };
            self.bump();
            self.skip_nl();
            let rhs = self.parse_additive()?;
            let span = lhs.span().join(rhs.span());
            lhs = Expr::Binary { op, lhs: Box::new(lhs), rhs: Box::new(rhs), span };
        }
        Some(lhs)
    }

    fn parse_additive(&mut self) -> Option<Expr> {
        let mut lhs = self.parse_multiplicative()?;
        loop {
            let op = match self.peek_kind() {
                TokenKind::Plus => BinOp::Add,
                TokenKind::Minus => BinOp::Sub,
                _ => break,
            };
            self.bump();
            self.skip_nl();
            let rhs = self.parse_multiplicative()?;
            let span = lhs.span().join(rhs.span());
            lhs = Expr::Binary { op, lhs: Box::new(lhs), rhs: Box::new(rhs), span };
        }
        Some(lhs)
    }

    fn parse_multiplicative(&mut self) -> Option<Expr> {
        let mut lhs = self.parse_as()?;
        loop {
            let op = match self.peek_kind() {
                TokenKind::Star => BinOp::Mul,
                TokenKind::Slash => BinOp::Div,
                TokenKind::Percent => BinOp::Rem,
                _ => break,
            };
            self.bump();
            self.skip_nl();
            let rhs = self.parse_as()?;
            let span = lhs.span().join(rhs.span());
            lhs = Expr::Binary { op, lhs: Box::new(lhs), rhs: Box::new(rhs), span };
        }
        Some(lhs)
    }

    /// `expr as Type` / `expr as? Type`, left-associative. The lexer emits
    /// `?` as `QuestNoWs` only when adjacent to `as`, so we accept that
    /// exact shape for the safe form.
    fn parse_as(&mut self) -> Option<Expr> {
        let mut lhs = self.parse_prefix()?;
        while matches!(self.peek_kind(), TokenKind::Keyword(Keyword::As)) {
            self.bump(); // `as`
            let safe = self.peek_kind().is_question();
            if safe {
                self.bump();
            }
            self.skip_nl();
            let Some(ty) = self.parse_qualified_type() else { break };
            let span = lhs.span().join(ty.span);
            lhs = Expr::As { expr: Box::new(lhs), ty, safe, span };
        }
        Some(lhs)
    }

    fn parse_prefix(&mut self) -> Option<Expr> {
        let start = self.current_span();
        let op = match self.peek_kind() {
            TokenKind::Minus => Some(UnOp::Neg),
            TokenKind::Plus => Some(UnOp::Pos),
            k if k.is_bang() => Some(UnOp::Not),
            TokenKind::PlusPlus => Some(UnOp::PreInc),
            TokenKind::MinusMinus => Some(UnOp::PreDec),
            _ => None,
        };
        if let Some(op) = op {
            self.bump();
            let expr = self.parse_prefix()?;
            let span = start.join(expr.span());
            return Some(Expr::Unary { op, expr: Box::new(expr), span });
        }
        self.parse_postfix()
    }

    fn parse_postfix(&mut self) -> Option<Expr> {
        let mut expr = self.parse_primary()?;
        // Generic type args at a call site (`foo<String>(…)`) are captured
        // here and attached to the next `Call` constructed in this loop.
        let mut pending_type_args: Vec<TypeRef> = Vec::new();
        loop {
            match self.peek_kind() {
                TokenKind::PlusPlus => {
                    let tok = self.bump();
                    let span = expr.span().join(tok.span);
                    expr = Expr::Postfix { op: PostfixOp::Inc, expr: Box::new(expr), span };
                }
                TokenKind::MinusMinus => {
                    let tok = self.bump();
                    let span = expr.span().join(tok.span);
                    expr = Expr::Postfix { op: PostfixOp::Dec, expr: Box::new(expr), span };
                }
                TokenKind::BangBang => {
                    let tok = self.bump();
                    let span = expr.span().join(tok.span);
                    expr = Expr::Postfix { op: PostfixOp::NotNull, expr: Box::new(expr), span };
                }
                TokenKind::Dot | TokenKind::QuestionDot => {
                    let safe = matches!(self.peek_kind(), TokenKind::QuestionDot);
                    self.bump();
                    self.skip_nl();
                    let Some(name) = self.parse_ident("member name") else { return Some(expr); };
                    let span = expr.span().join(name.span);
                    expr = Expr::Member { receiver: Box::new(expr), name, safe, span };
                }
                TokenKind::ColonColon => {
                    self.bump();
                    self.skip_nl();
                    // `Foo::class` — class literal. Accept the soft `class`
                    // keyword as the right-hand name; otherwise expect an
                    // identifier (member name).
                    let name = if matches!(self.peek_kind(), TokenKind::Keyword(Keyword::Class)) {
                        let tok = self.bump();
                        Ident { name: "class".to_string(), span: tok.span }
                    } else {
                        self.parse_ident("callable reference name")?
                    };
                    if name.name == "class" && !pending_type_args.is_empty() {
                        // Spec §15.1: class literals erase their type
                        // arguments, so writing them is rejected.
                        let span_first = pending_type_args.first().map(|t| t.span).unwrap_or(name.span);
                        let span_last = pending_type_args.last().map(|t| t.span).unwrap_or(name.span);
                        self.error(
                            "T0104",
                            "class literal does not take type arguments — type arguments are erased on `::class`.",
                            span_first.join(span_last),
                        );
                    }
                    pending_type_args.clear();
                    let span = expr.span().join(name.span);
                    expr = Expr::MemberRef { receiver: Box::new(expr), name, span };
                }
                TokenKind::Lt => {
                    // Generic call type args like `ArrayList<Int>()` or
                    // `compareBy<String> { … }`. We disambiguate against
                    // less-than via `try_skip_generic_call_args` (look-ahead
                    // for a matching `>` followed by `(`/`{`/`.`/`?.`/`::`);
                    // if it doesn't look like a generic-call form, we treat
                    // `<` as a binary operator and break out of the postfix
                    // loop. Otherwise we parse the type args for real and
                    // hold them for the next `Call`.
                    if self.try_skip_generic_call_args() {
                        let args = self.parse_call_type_args();
                        pending_type_args = args;
                        continue;
                    }
                    break;
                }
                TokenKind::LParen => {
                    self.bump();
                    let mut args = Vec::new();
                    let mut arg_names: Vec<Option<String>> = Vec::new();
                    loop {
                        self.skip_nl();
                        if matches!(self.peek_kind(), TokenKind::RParen) { break; }
                        // Capture `name` part of `name = expr` for reorder.
                        let name = self.try_consume_named_arg_name();
                        let arg = self.parse_value_argument()?;
                        args.push(arg);
                        arg_names.push(name);
                        self.skip_nl();
                        if matches!(self.peek_kind(), TokenKind::Comma) {
                            self.bump();
                        } else {
                            break;
                        }
                    }
                    let rparen = self.expect(&TokenKind::RParen, "`)`")?;
                    let span = expr.span().join(rparen.span);
                    let type_args = std::mem::take(&mut pending_type_args);
                    expr = Expr::Call {
                        callee: Box::new(expr),
                        args,
                        arg_names,
                        type_args,
                        is_infix: false,
                        span,
                    };
                }
                TokenKind::LBracket => {
                    self.bump();
                    let mut args = Vec::new();
                    loop {
                        self.skip_nl();
                        if matches!(self.peek_kind(), TokenKind::RBracket) { break; }
                        let arg = self.parse_expr()?;
                        args.push(arg);
                        self.skip_nl();
                        if matches!(self.peek_kind(), TokenKind::Comma) {
                            self.bump();
                        } else {
                            break;
                        }
                    }
                    let rbr = self.expect(&TokenKind::RBracket, "`]`")?;
                    let span = expr.span().join(rbr.span);
                    expr = Expr::Index { receiver: Box::new(expr), args, span };
                }
                TokenKind::LBrace
                    if is_trailing_lambda_callable(&expr) && !self.suppress_trailing_lambda =>
                {
                    let lam = self.parse_trailing_lambda()?;
                    let span = expr.span().join(lam.span());
                    let extra_type_args = std::mem::take(&mut pending_type_args);
                    expr = match expr {
                        Expr::Call { callee, mut args, mut arg_names, mut type_args, is_infix, .. } => {
                            args.push(lam);
                            arg_names.push(None);
                            if type_args.is_empty() {
                                type_args = extra_type_args;
                            }
                            Expr::Call { callee, args, arg_names, type_args, is_infix, span }
                        }
                        other => Expr::Call {
                            callee: Box::new(other),
                            args: vec![lam],
                            arg_names: vec![None],
                            type_args: extra_type_args,
                            is_infix: false,
                            span,
                        },
                    };
                }
                TokenKind::Newline => {
                    // Kotlin allows a postfix chain to continue across a
                    // newline if the first non-whitespace on the next line
                    // is `.`, `?.`, `!!`, or `[`. Peek past newlines; if
                    // we land on one of those continuation tokens, swallow
                    // the newlines and keep going. Otherwise the chain
                    // ends here.
                    if self.next_non_newline_is_chain_continuation() {
                        self.skip_nl();
                        continue;
                    }
                    break;
                }
                _ => break,
            }
        }
        Some(expr)
    }

    /// If the next two tokens are `Ident =`, consume both and return the
    /// identifier text — the label of a named argument that callers can
    /// use for reorder dispatch against a callable's parameter list.
    /// Parse a single value-argument at a call site. Accepts a leading
    /// `*` as a spread marker (`foo(*arr)`); otherwise delegates to the
    /// regular expression parser.
    fn parse_value_argument(&mut self) -> Option<Expr> {
        if matches!(self.peek_kind(), TokenKind::Star) {
            let star = self.bump();
            self.skip_nl();
            let e = self.parse_expr()?;
            self.reject_trailing_assignment();
            let span = star.span.join(e.span());
            return Some(Expr::Spread { expr: Box::new(e), span });
        }
        // A `{ ... }` value-argument is always a lambda literal, even
        // without an explicit `->` header (binds an implicit `it`).
        if matches!(self.peek_kind(), TokenKind::LBrace) {
            let lam = self.parse_lambda_literal()?;
            self.reject_trailing_assignment();
            return Some(lam);
        }
        let e = self.parse_expr()?;
        self.reject_trailing_assignment();
        Some(e)
    }

    fn try_consume_named_arg_name(&mut self) -> Option<String> {
        if !matches!(self.peek_kind(), TokenKind::Ident) {
            return None;
        }
        let next = self.tokens.get(self.pos + 1).map(|t| &t.kind);
        if !matches!(next, Some(TokenKind::Eq)) {
            return None;
        }
        let tok = self.bump(); // ident
        let name = self.ident_name(tok.span);
        self.bump(); // `=`
        self.skip_nl();
        Some(name)
    }

    /// Peek forward past any number of `Newline` tokens. Returns `true`
    /// when the next non-newline token is one of the postfix-chain
    /// continuation starters.
    fn next_non_newline_is_chain_continuation(&self) -> bool {
        let mut i = self.pos;
        while matches!(self.tokens.get(i).map(|t| &t.kind), Some(TokenKind::Newline)) {
            i += 1;
        }
        matches!(
            self.tokens.get(i).map(|t| &t.kind),
            Some(TokenKind::Dot)
                | Some(TokenKind::QuestionDot)
                | Some(TokenKind::BangBang)
                | Some(TokenKind::LBracket)
        )
    }

    fn parse_primary(&mut self) -> Option<Expr> {
        self.skip_nl();
        let kind = self.peek_kind().clone();
        match kind {
            TokenKind::IntLiteral { base, suffix: _ } => Some(self.parse_int_literal(base)),
            TokenKind::FloatLiteral { suffix: _ } => Some(self.parse_float_literal()),
            TokenKind::BoolLiteral(v) => {
                let tok = self.bump();
                Some(Expr::BoolLit { value: v, span: tok.span })
            }
            TokenKind::NullLiteral => {
                let tok = self.bump();
                Some(Expr::NullLit { span: tok.span })
            }
            TokenKind::CharLiteral(c) => {
                let tok = self.bump();
                Some(Expr::CharLit { value: c, span: tok.span })
            }
            TokenKind::StringQuote { .. } => self.parse_string_template(),
            TokenKind::Ident => {
                if let Some(label_expr) = self.try_parse_label_binding() {
                    return Some(label_expr);
                }
                let tok = self.bump();
                let ident = Ident { name: self.ident_name(tok.span), span: tok.span };
                Some(Expr::Path { segments: vec![ident], span: tok.span })
            }
            TokenKind::LParen => {
                self.bump();
                self.skip_nl();
                let inner = self.parse_expr()?;
                self.skip_nl();
                self.reject_trailing_assignment();
                self.skip_nl();
                self.expect(&TokenKind::RParen, "`)`")?;
                Some(inner)
            }
            TokenKind::LBrace => {
                if self.looks_like_lambda() {
                    self.parse_lambda_literal()
                } else {
                    self.parse_block().map(Expr::Block)
                }
            }
            TokenKind::Keyword(Keyword::Fun) => self.parse_anon_fun(),
            TokenKind::Keyword(Keyword::If) => self.parse_if(),
            TokenKind::Keyword(Keyword::While) => self.parse_while(),
            TokenKind::Keyword(Keyword::Do) => self.parse_do_while(),
            TokenKind::Keyword(Keyword::For) => self.parse_for(),
            TokenKind::Keyword(Keyword::Return) => self.parse_return(),
            TokenKind::Keyword(Keyword::Throw) => self.parse_throw(),
            TokenKind::Keyword(Keyword::Try) => self.parse_try(),
            TokenKind::Keyword(Keyword::When) => self.parse_when(),
            TokenKind::Keyword(Keyword::This) => {
                let tok = self.bump();
                let mut qualifier = None;
                let mut end = tok.span;
                if self.peek_kind().is_at() {
                    self.bump();
                    if let Some(n) = self.parse_ident("`this@` label") {
                        end = n.span;
                        qualifier = Some(n);
                    }
                }
                Some(Expr::This { qualifier, span: tok.span.join(end) })
            }
            TokenKind::ColonColon => {
                let start = self.bump().span;
                let name = self.parse_ident("property/function reference name")?;
                let span = start.join(name.span);
                Some(Expr::PropertyRef { name, span })
            }
            TokenKind::Keyword(Keyword::Object) => {
                // Anonymous object expression: `object { … }` or
                // `object : Super(args), Iface { … }`. A named `object Foo`
                // is a declaration, not an expression; the statement-level
                // parser handles that form before reaching here.
                let kw = self.bump();
                let (supertypes, supertype_args, supertype_delegates) =
                    self.parse_optional_supertypes_full();
                let (members, _init, _sec) = self.parse_class_body();
                let end = self.tokens[self.pos.saturating_sub(1)].span;
                Some(Expr::ObjectExpr {
                    supertypes,
                    supertype_args,
                    supertype_delegates,
                    members,
                    span: kw.span.join(end),
                })
            }
            TokenKind::Keyword(Keyword::Super) => {
                let tok = self.bump();
                let qualifier = if matches!(self.peek_kind(), TokenKind::Lt) {
                    self.bump();
                    let ty = self.parse_type();
                    if matches!(self.peek_kind(), TokenKind::Gt) {
                        self.bump();
                    }
                    ty
                } else {
                    None
                };
                let label = self.consume_jump_label();
                let mut end = tok.span;
                if let Some(q) = &qualifier {
                    end = end.join(q.span);
                }
                if let Some(l) = &label {
                    end = end.join(l.span);
                }
                Some(Expr::Super { qualifier, label, span: tok.span.join(end) })
            }
            TokenKind::Keyword(Keyword::Break) => {
                let tok = self.bump();
                let label = self.consume_jump_label();
                let span = label.as_ref().map_or(tok.span, |l| tok.span.join(l.span));
                Some(Expr::Break { label, span })
            }
            TokenKind::Keyword(Keyword::Continue) => {
                let tok = self.bump();
                let label = self.consume_jump_label();
                let span = label.as_ref().map_or(tok.span, |l| tok.span.join(l.span));
                Some(Expr::Continue { label, span })
            }
            _ => {
                let span = self.current_span();
                self.error("E0011", "expected expression", span);
                None
            }
        }
    }

    fn parse_int_literal(&mut self, base: klio_lexer::NumBase) -> Expr {
        let tok = self.bump();
        let raw_text = self.text(tok.span);
        let (digits, radix): (&str, u32) = match base {
            klio_lexer::NumBase::Decimal => (raw_text.trim_end_matches(['L', 'u', 'U']), 10),
            klio_lexer::NumBase::Hex => (
                raw_text.trim_start_matches("0x").trim_start_matches("0X")
                    .trim_end_matches(['L', 'u', 'U']),
                16,
            ),
            klio_lexer::NumBase::Binary => (
                raw_text.trim_start_matches("0b").trim_start_matches("0B")
                    .trim_end_matches(['L', 'u', 'U']),
                2,
            ),
        };
        let has_l_suffix = raw_text.ends_with('L');
        let cleaned: String = digits.chars().filter(|c| *c != '_').collect();
        let value: i64 = i64::from_str_radix(&cleaned, radix).unwrap_or_else(|_| {
            self.error("E0010", "integer literal out of range", tok.span);
            0
        });
        let kind = if has_l_suffix {
            klio_ast::IntLitKind::Long
        } else {
            klio_ast::IntLitKind::Int
        };
        Expr::IntLit { value, kind, span: tok.span }
    }

    fn parse_float_literal(&mut self) -> Expr {
        let tok = self.bump();
        let raw_text = self.text(tok.span);
        let has_f_suffix = raw_text.ends_with('f') || raw_text.ends_with('F');
        let cleaned: String = raw_text.chars().filter(|c| *c != '_' && !matches!(c, 'f' | 'F')).collect();
        let span = tok.span;
        let value: f64 = cleaned.parse().unwrap_or_else(|_| {
            self.error("E0012", "invalid float literal", span);
            0.0
        });
        let kind = if has_f_suffix {
            klio_ast::FloatLitKind::Float
        } else {
            klio_ast::FloatLitKind::Double
        };
        Expr::FloatLit { value, kind, span: tok.span }
    }

    fn parse_string_template(&mut self) -> Option<Expr> {
        let open = self.bump(); // StringQuote
        let triple = matches!(open.kind, TokenKind::StringQuote { triple: true });
        let mut parts = Vec::new();
        loop {
            let kind = self.peek_kind().clone();
            match kind {
                TokenKind::StringQuote { triple: t } if t == triple => {
                    let close = self.bump();
                    return Some(Expr::StringTemplate { parts, span: open.span.join(close.span) });
                }
                TokenKind::StringText(s) => {
                    self.bump();
                    parts.push(StringPart::Text(s));
                }
                TokenKind::ShortInterp(name) => {
                    let tok = self.bump();
                    parts.push(StringPart::ShortInterp(Ident { name, span: tok.span }));
                }
                TokenKind::InterpStart => {
                    self.bump();
                    let expr = self.parse_expr()?;
                    self.skip_nl();
                    self.expect(&TokenKind::InterpEnd, "`}` to close string interpolation")?;
                    parts.push(StringPart::Interp(expr));
                }
                TokenKind::Eof => {
                    self.error("E0013", "unterminated string template", open.span);
                    return Some(Expr::StringTemplate { parts, span: open.span });
                }
                _ => {
                    let span = self.current_span();
                    self.error("E0014", "unexpected token inside string template", span);
                    self.bump();
                }
            }
        }
    }

    /// Parses a `controlStructureBody` per the spec: a statement (which
    /// may be an assignment) wrapped as a single-statement block, or an
    /// expression. Used for `if` / `else` / `while` / `for` / `do-while`
    /// bodies so a non-block body can be an assignment like
    /// `if (c) x = v`.
    fn parse_control_structure_body(&mut self) -> Option<Expr> {
        let save = self.pos;
        let expr = self.parse_expr()?;
        let op = match self.peek_kind() {
            TokenKind::Eq => Some(AssignOp::Assign),
            TokenKind::PlusEq => Some(AssignOp::Add),
            TokenKind::MinusEq => Some(AssignOp::Sub),
            TokenKind::StarEq => Some(AssignOp::Mul),
            TokenKind::SlashEq => Some(AssignOp::Div),
            TokenKind::PercentEq => Some(AssignOp::Rem),
            _ => None,
        };
        if let Some(op) = op {
            self.bump();
            self.skip_nl();
            let rhs = self.parse_expr()?;
            let span = expr.span().join(rhs.span());
            let stmt = Stmt::Assign { target: expr, op, value: rhs, span };
            return Some(Expr::Block(Block { stmts: vec![stmt], span }));
        }
        let _ = save;
        Some(expr)
    }

    fn parse_if(&mut self) -> Option<Expr> {
        let kw = self.bump();
        self.expect(&TokenKind::LParen, "`(`")?;
        self.skip_nl();
        let cond = self.parse_expr()?;
        self.skip_nl();
        self.reject_trailing_assignment();
        self.skip_nl();
        self.expect(&TokenKind::RParen, "`)`")?;
        self.skip_nl();
        // Spec §8.5: the then-branch may be omitted (`;` or `else`
        // immediately following the closing paren). The branchless form
        // `if (c) else ;` is valid and evaluates to Unit.
        let cond_span = cond.span();
        let then_branch = match self.peek_kind() {
            TokenKind::Semicolon => {
                let semi = self.bump();
                Expr::Block(Block { stmts: Vec::new(), span: semi.span })
            }
            TokenKind::Keyword(Keyword::Else) => {
                Expr::Block(Block { stmts: Vec::new(), span: cond_span })
            }
            _ => self.parse_control_structure_body()?,
        };
        // `else` may follow on the next line.
        let save = self.pos;
        self.skip_nl();
        let else_branch = if matches!(self.peek_kind(), TokenKind::Keyword(Keyword::Else)) {
            self.bump();
            self.skip_nl();
            if matches!(self.peek_kind(), TokenKind::Semicolon) {
                let semi = self.bump();
                Some(Box::new(Expr::Block(Block { stmts: Vec::new(), span: semi.span })))
            } else {
                self.parse_control_structure_body().map(Box::new)
            }
        } else {
            self.pos = save;
            None
        };
        let end = else_branch.as_ref().map_or(then_branch.span(), |e| e.span());
        Some(Expr::If {
            cond: Box::new(cond),
            then_branch: Box::new(then_branch),
            else_branch,
            span: kw.span.join(end),
        })
    }

    fn parse_while(&mut self) -> Option<Expr> {
        let kw = self.bump();
        self.expect(&TokenKind::LParen, "`(`")?;
        self.skip_nl();
        let cond = self.parse_expr()?;
        self.skip_nl();
        self.reject_trailing_assignment();
        self.skip_nl();
        self.expect(&TokenKind::RParen, "`)`")?;
        self.skip_nl();
        let body = self.parse_control_structure_body()?;
        Some(Expr::While {
            cond: Box::new(cond),
            body: Box::new(body.clone()),
            span: kw.span.join(body.span()),
        })
    }

    fn parse_do_while(&mut self) -> Option<Expr> {
        let kw = self.bump();
        self.skip_nl();
        // Body is optional per spec: `do { ... } while(c)` or `do; while(c)`.
        let body = if matches!(self.peek_kind(), TokenKind::Keyword(Keyword::While)) {
            None
        } else {
            let b = self.parse_control_structure_body()?;
            Some(Box::new(b))
        };
        self.skip_nl();
        self.expect(&TokenKind::Keyword(Keyword::While), "`while`")?;
        self.skip_nl();
        self.expect(&TokenKind::LParen, "`(`")?;
        self.skip_nl();
        let cond = self.parse_expr()?;
        self.skip_nl();
        self.reject_trailing_assignment();
        self.skip_nl();
        let rp = self.expect(&TokenKind::RParen, "`)`")?;
        Some(Expr::DoWhile {
            body,
            cond: Box::new(cond),
            span: kw.span.join(rp.span),
        })
    }

    fn parse_for(&mut self) -> Option<Expr> {
        let kw = self.bump();
        self.expect(&TokenKind::LParen, "`(`")?;
        self.skip_nl();
        // §7.2.3: `{annotation} (variableDeclaration | multiVariableDeclaration)`.
        // Annotations on the iteration variable are accepted and consumed
        // syntactically; no semantics yet.
        let _ann = self.parse_annotations();
        // Destructuring: `for ((a, b) in iter)`. Plain: `for (x in iter)`.
        let vars = if matches!(self.peek_kind(), TokenKind::LParen) {
            self.bump();
            let mut names = Vec::new();
            loop {
                self.skip_nl();
                if matches!(self.peek_kind(), TokenKind::RParen) {
                    break;
                }
                // Per-component annotations + optional type ascription.
                let _comp_ann = self.parse_annotations();
                let Some(id) = self.parse_ident("destructured loop variable") else {
                    break;
                };
                // Type ascription on individual component is consumed and
                // discarded — the AST currently models one type slot for
                // the whole destructuring binding.
                if matches!(self.peek_kind(), TokenKind::Colon) {
                    self.bump();
                    let _ = self.parse_type();
                }
                names.push(id);
                self.skip_nl();
                if matches!(self.peek_kind(), TokenKind::Comma) {
                    self.bump();
                } else {
                    break;
                }
            }
            self.expect(&TokenKind::RParen, "`)`")?;
            names
        } else {
            vec![self.parse_ident("loop variable")?]
        };
        let var_ty = if matches!(self.peek_kind(), TokenKind::Colon) {
            self.bump();
            self.parse_type()
        } else {
            None
        };
        self.skip_nl();
        self.expect(&TokenKind::Keyword(Keyword::In), "`in`")?;
        self.skip_nl();
        let iter = self.parse_expr()?;
        self.skip_nl();
        self.reject_trailing_assignment();
        self.skip_nl();
        self.expect(&TokenKind::RParen, "`)`")?;
        self.skip_nl();
        let body = self.parse_control_structure_body()?;
        Some(Expr::For {
            vars,
            var_ty,
            iter: Box::new(iter),
            body: Box::new(body.clone()),
            span: kw.span.join(body.span()),
        })
    }

    fn parse_return(&mut self) -> Option<Expr> {
        let kw = self.bump();
        let label = self.consume_jump_label();
        if self.at_newline_or_semi_or_close() {
            let span = label.as_ref().map_or(kw.span, |l| kw.span.join(l.span));
            return Some(Expr::Return { value: None, label, span });
        }
        let value = self.parse_expr()?;
        let span = kw.span.join(value.span());
        Some(Expr::Return { value: Some(Box::new(value)), label, span })
    }

    /// `label@ <expr>` at expression position. The label name is a bare
    /// identifier; the `@` may be `AtNoWs` (`foo@`) or `AtPostWs`
    /// (`foo@ for(...)` with trailing whitespace before the labeled form),
    /// matching the spec's `simpleIdentifier (AT_NO_WS | AT_POST_WS)` rule.
    fn try_parse_label_binding(&mut self) -> Option<Expr> {
        let name_kind = self.peek_kind();
        if !matches!(name_kind, TokenKind::Ident) {
            return None;
        }
        let at_kind = self.tokens.get(self.pos + 1).map(|t| &t.kind);
        if !matches!(at_kind, Some(TokenKind::AtNoWs | TokenKind::AtPostWs)) {
            return None;
        }
        let name_span = self.current_span();
        let label = Ident { name: self.ident_name(name_span), span: name_span };
        self.bump();
        self.bump();
        self.skip_nl();
        let inner = self.parse_unary_for_label()?;
        let span = label.span.join(inner.span());
        Some(Expr::Labeled { label, expr: Box::new(inner), span })
    }

    /// Parse the body of a `label@ <body>` binding. We re-enter the prefix
    /// rung so the labeled inner expression captures call-chains and
    /// trailing-lambda arguments as usual.
    fn parse_unary_for_label(&mut self) -> Option<Expr> {
        self.parse_prefix()
    }

    /// After a `return` / `break` / `continue` keyword, consume an optional
    /// `@label` suffix. The lexer emits `AtNoWs` when the `@` is directly
    /// attached to the keyword (`return@foo`), so we only accept that shape.
    fn consume_jump_label(&mut self) -> Option<Ident> {
        if !matches!(self.peek_kind(), TokenKind::AtNoWs) {
            return None;
        }
        self.bump();
        self.parse_ident("jump label")
    }

    fn parse_throw(&mut self) -> Option<Expr> {
        let kw = self.bump();
        self.skip_nl();
        let value = self.parse_expr()?;
        let span = kw.span.join(value.span());
        Some(Expr::Throw { value: Box::new(value), span })
    }

    fn parse_try(&mut self) -> Option<Expr> {
        let kw = self.bump();
        self.skip_nl();
        let body = self.parse_block()?;
        let mut catches = Vec::new();
        loop {
            let save = self.pos;
            self.skip_nl();
            if !self.peek_keyword_ident("catch") {
                self.pos = save;
                break;
            }
            self.bump();
            self.expect(&TokenKind::LParen, "`(`")?;
            self.skip_nl();
            let binding = self.parse_ident("catch binding")?;
            self.expect(&TokenKind::Colon, "`:`")?;
            let ty = self.parse_qualified_type()?;
            self.skip_nl();
            self.expect(&TokenKind::RParen, "`)`")?;
            self.skip_nl();
            let catch_body = self.parse_block()?;
            let span = binding.span.join(catch_body.span);
            catches.push(Catch { binding, ty, body: catch_body, span });
        }
        let finally = {
            let save = self.pos;
            self.skip_nl();
            if self.peek_keyword_ident("finally") {
                self.bump();
                self.skip_nl();
                self.parse_block()
            } else {
                self.pos = save;
                None
            }
        };
        let end = finally
            .as_ref()
            .map(|b| b.span)
            .or_else(|| catches.last().map(|c| c.body.span))
            .unwrap_or(body.span);
        Some(Expr::Try {
            body,
            catches,
            finally,
            span: kw.span.join(end),
        })
    }

    fn parse_when(&mut self) -> Option<Expr> {
        let kw = self.bump(); // `when`
        self.skip_nl();
        let mut subject: Option<Box<Expr>> = None;
        let mut subject_binding: Option<WhenBinding> = None;
        if matches!(self.peek_kind(), TokenKind::LParen) {
            self.bump();
            self.skip_nl();
            if let Some((binding, expr)) = self.try_parse_when_binding() {
                subject_binding = Some(binding);
                subject = Some(Box::new(expr));
            } else {
                let e = self.parse_expr()?;
                subject = Some(Box::new(e));
            }
            self.skip_nl();
            self.reject_trailing_assignment();
            self.skip_nl();
            self.expect(&TokenKind::RParen, "`)`")?;
        }
        self.skip_nl();
        self.expect(&TokenKind::LBrace, "`{`")?;
        let mut branches = Vec::new();
        loop {
            self.skip_stmt_separators();
            if matches!(self.peek_kind(), TokenKind::RBrace | TokenKind::Eof) {
                break;
            }
            let Some(branch) = self.parse_when_branch(subject.is_some()) else {
                self.recover_to_stmt_end();
                continue;
            };
            branches.push(branch);
        }
        let rbrace = self.expect(&TokenKind::RBrace, "`}`")?;
        Some(Expr::When {
            subject,
            subject_binding,
            branches,
            span: kw.span.join(rbrace.span),
        })
    }

    /// Look ahead inside `when (` for the `{annotation}* val name (: Ty)? =`
    /// shape that introduces a subject-bound variable. Commits and parses the
    /// binding + subject expression on a positive match; leaves the cursor
    /// unchanged otherwise so the caller can fall back to a bare subject.
    fn try_parse_when_binding(&mut self) -> Option<(WhenBinding, Expr)> {
        let save = self.pos;
        let annotations = self.parse_annotations();
        self.skip_nl();
        if !matches!(self.peek_kind(), TokenKind::Keyword(Keyword::Val)) {
            self.pos = save;
            return None;
        }
        // Peek further: val NAME (':' …)? '='
        let mut i = self.pos + 1;
        while matches!(self.tokens.get(i).map(|t| &t.kind), Some(TokenKind::Newline)) {
            i += 1;
        }
        if !matches!(self.tokens.get(i).map(|t| &t.kind), Some(TokenKind::Ident)) {
            self.pos = save;
            return None;
        }
        // Skip past the name and optional `: Type` to look for `=`.
        let mut j = i + 1;
        while matches!(self.tokens.get(j).map(|t| &t.kind), Some(TokenKind::Newline)) {
            j += 1;
        }
        if matches!(self.tokens.get(j).map(|t| &t.kind), Some(TokenKind::Colon)) {
            // Type follows; scanning for `=` past an arbitrary type list is
            // fragile, so commit and let the recovery path handle ill-formed
            // bindings.
        } else if !matches!(self.tokens.get(j).map(|t| &t.kind), Some(TokenKind::Eq)) {
            self.pos = save;
            return None;
        }
        let val_span = self.bump().span; // `val`
        self.skip_nl();
        let Some(name) = self.parse_ident("when-binding name") else {
            self.pos = save;
            return None;
        };
        let mut ty = None;
        self.skip_nl();
        if matches!(self.peek_kind(), TokenKind::Colon) {
            self.bump();
            self.skip_nl();
            ty = self.parse_type();
        }
        self.skip_nl();
        self.expect(&TokenKind::Eq, "`=`")?;
        self.skip_nl();
        let expr = self.parse_expr()?;
        let end = ty.as_ref().map_or(name.span, |t| t.span);
        let binding = WhenBinding {
            name,
            ty,
            annotations,
            span: val_span.join(end),
        };
        Some((binding, expr))
    }

    fn parse_when_branch(&mut self, has_subject: bool) -> Option<WhenBranch> {
        self.skip_nl();
        let start = self.current_span();
        let mut patterns = Vec::new();
        loop {
            self.skip_nl();
            let p = self.parse_when_pattern(has_subject)?;
            patterns.push(p);
            self.skip_nl();
            if matches!(self.peek_kind(), TokenKind::Comma) {
                self.bump();
                continue;
            }
            break;
        }
        self.skip_nl();
        self.expect(&TokenKind::Arrow, "`->`")?;
        self.skip_nl();
        let body = self.parse_expr()?;
        let span = start.join(body.span());
        Some(WhenBranch { patterns, body, span })
    }

    fn parse_when_pattern(&mut self, has_subject: bool) -> Option<WhenPattern> {
        let start = self.current_span();
        // `else` — always valid as a pattern.
        if matches!(self.peek_kind(), TokenKind::Keyword(Keyword::Else)) {
            let tok = self.bump();
            return Some(WhenPattern { kind: WhenPatternKind::Else, span: tok.span });
        }
        // Subject-bound patterns can use `is Type`, `!is Type`, `in expr`,
        // `!in expr`. Subject-free `when` only accepts Boolean conditions
        // (Value patterns) — but we still parse the keyword forms and let
        // the interpreter reject them; this keeps recovery simple.
        if has_subject {
            match self.peek_kind() {
                TokenKind::Keyword(Keyword::Is) => {
                    self.bump();
                    let ty = self.parse_qualified_type()?;
                    let span = start.join(ty.span);
                    return Some(WhenPattern { kind: WhenPatternKind::IsType(ty), span });
                }
                TokenKind::Keyword(Keyword::In) => {
                    self.bump();
                    self.skip_nl();
                    let e = self.parse_expr()?;
                    let span = start.join(e.span());
                    return Some(WhenPattern { kind: WhenPatternKind::InRange(e), span });
                }
                k if k.is_bang() => {
                    let next = self.tokens.get(self.pos + 1).map(|t| &t.kind);
                    match next {
                        Some(TokenKind::Keyword(Keyword::Is)) => {
                            self.bump();
                            self.bump();
                            let ty = self.parse_qualified_type()?;
                            let span = start.join(ty.span);
                            return Some(WhenPattern { kind: WhenPatternKind::NotIsType(ty), span });
                        }
                        Some(TokenKind::Keyword(Keyword::In)) => {
                            self.bump();
                            self.bump();
                            self.skip_nl();
                            let e = self.parse_expr()?;
                            let span = start.join(e.span());
                            return Some(WhenPattern { kind: WhenPatternKind::NotInRange(e), span });
                        }
                        _ => {}
                    }
                }
                _ => {}
            }
        }
        let e = self.parse_expr()?;
        let span = start.join(e.span());
        Some(WhenPattern { kind: WhenPatternKind::Value(e), span })
    }

    fn peek_keyword_ident(&self, name: &str) -> bool {
        matches!(self.peek_kind(), TokenKind::Ident) && self.text(self.current_span()) == name
    }

    /// Generic type arguments at a call site (`f<T>(...)` or `f<T> { … }`).
    /// We don't model the type args, just consume them so the trailing call
    /// or trailing-lambda parses. The disambiguator: scan from `<` for a
    /// matching `>` (tracking `<`/`>` depth and bailing on tokens that
    /// can't appear inside a type list), and only accept when the `>` is
    /// immediately followed by `(`, `{`, `.`, `?.`, or `::`.
    fn try_skip_generic_call_args(&self) -> bool {
        if !matches!(self.peek_kind(), TokenKind::Lt) {
            return false;
        }
        let mut depth = 0i32;
        let mut i = self.pos;
        let max = self.tokens.len();
        while i < max {
            let kind = &self.tokens[i].kind;
            match kind {
                TokenKind::Lt => depth += 1,
                TokenKind::Gt => {
                    depth -= 1;
                    if depth == 0 {
                        let next = self.tokens.get(i + 1).map(|t| &t.kind);
                        return matches!(
                            next,
                            Some(TokenKind::LParen)
                                | Some(TokenKind::LBrace)
                                | Some(TokenKind::Dot)
                                | Some(TokenKind::QuestionDot)
                                | Some(TokenKind::ColonColon)
                        );
                    }
                }
                // Tokens that wouldn't appear in a type list — bail out.
                TokenKind::Eq
                | TokenKind::Semicolon
                | TokenKind::Plus
                | TokenKind::Minus
                | TokenKind::Star
                | TokenKind::Slash
                | TokenKind::Percent
                | TokenKind::EqEq
                | TokenKind::BangEq
                | TokenKind::EqEqEq
                | TokenKind::BangEqEq
                | TokenKind::Le
                | TokenKind::Ge
                | TokenKind::AmpAmp
                | TokenKind::PipePipe
                | TokenKind::Newline
                | TokenKind::Eof => return false,
                _ => {}
            }
            i += 1;
        }
        false
    }

    /// `{` is at the cursor. Decide whether this is a lambda (has `->` at
    fn looks_like_lambda(&self) -> bool {
        if !matches!(self.peek_kind(), TokenKind::LBrace) {
            return false;
        }
        let mut depth = 1i32;
        let mut i = self.pos + 1;
        while let Some(tok) = self.tokens.get(i) {
            match &tok.kind {
                TokenKind::LBrace => depth += 1,
                TokenKind::RBrace => {
                    depth -= 1;
                    if depth == 0 {
                        return false;
                    }
                }
                TokenKind::Arrow if depth == 1 => return true,
                TokenKind::Eof => return false,
                _ => {}
            }
            i += 1;
        }
        false
    }

    fn parse_lambda_literal(&mut self) -> Option<Expr> {
        // We're at `{`. Header is `params ->` (optional). Body is a
        // statement list.
        let lbrace = self.bump();
        let (params, dest_stmts) = self.parse_lambda_header();
        let mut stmts = dest_stmts;
        loop {
            self.skip_stmt_separators();
            if matches!(self.peek_kind(), TokenKind::RBrace | TokenKind::Eof) {
                break;
            }
            if let Some(s) = self.parse_stmt() {
                stmts.push(s);
            } else {
                self.recover_to_stmt_end();
            }
            if !matches!(
                self.peek_kind(),
                TokenKind::Newline | TokenKind::Semicolon | TokenKind::RBrace | TokenKind::Eof
            ) {
                let span = self.current_span();
                self.error("E0004", "expected newline or `;` between statements", span);
                self.recover_to_stmt_end();
            }
        }
        let rbrace = self.expect(&TokenKind::RBrace, "`}`")?;
        let span = lbrace.span.join(rbrace.span);
        let body = Block { stmts, span };
        Some(Expr::Lambda { params, body, span })
    }

    fn parse_trailing_lambda(&mut self) -> Option<Expr> {
        // Same shape; if no `->` is present, default to a single `it` param.
        let lbrace = self.bump();
        let (mut params, dest_stmts) = self.parse_lambda_header();
        if params.is_empty() {
            params.push(Ident { name: "it".into(), span: lbrace.span });
        }
        let mut stmts = dest_stmts;
        loop {
            self.skip_stmt_separators();
            if matches!(self.peek_kind(), TokenKind::RBrace | TokenKind::Eof) {
                break;
            }
            if let Some(s) = self.parse_stmt() {
                stmts.push(s);
            } else {
                self.recover_to_stmt_end();
            }
            if !matches!(
                self.peek_kind(),
                TokenKind::Newline | TokenKind::Semicolon | TokenKind::RBrace | TokenKind::Eof
            ) {
                let span = self.current_span();
                self.error("E0004", "expected newline or `;` between statements", span);
                self.recover_to_stmt_end();
            }
        }
        let rbrace = self.expect(&TokenKind::RBrace, "`}`")?;
        let span = lbrace.span.join(rbrace.span);
        let body = Block { stmts, span };
        Some(Expr::Lambda { params, body, span })
    }

    /// Reads the optional `params ->` header inside a `{ ... }` lambda.
    /// Returns the param list (empty if no `->` is present) and a list of
    /// destructuring statements that the caller should prepend to the body
    /// — one `val (a, b, …) = $$dest_<i>` per destructured slot.
    fn parse_lambda_header(&mut self) -> (Vec<Ident>, Vec<Stmt>) {
        let save = self.pos;
        let mut params = Vec::new();
        let mut dest_stmts: Vec<Stmt> = Vec::new();
        self.skip_nl();
        // Empty `{ -> ... }` form: arrow at front, no params.
        if matches!(self.peek_kind(), TokenKind::Arrow) {
            self.bump();
            return (params, dest_stmts);
        }
        // `(ident (: Type)?, …)` destructured param OR
        // `ident (: Type)?, ident (: Type)?, … ->`
        if matches!(self.peek_kind(), TokenKind::Ident | TokenKind::LParen) {
            let mut local: Vec<Ident> = Vec::new();
            let mut pending_dest: Vec<(usize, Vec<Ident>, Span)> = Vec::new();
            loop {
                match self.peek_kind() {
                    TokenKind::Ident => {
                        let tok = self.bump();
                        local.push(Ident { name: self.ident_name(tok.span), span: tok.span });
                        self.skip_nl();
                        if matches!(self.peek_kind(), TokenKind::Colon) {
                            self.bump();
                            let _ = self.parse_type();
                            self.skip_nl();
                        }
                    }
                    TokenKind::LParen => {
                        let lparen = self.bump();
                        let mut names: Vec<Ident> = Vec::new();
                        loop {
                            self.skip_nl();
                            if matches!(self.peek_kind(), TokenKind::RParen) {
                                break;
                            }
                            let id_span = self.current_span();
                            let text = self.text(id_span);
                            let id = if text == "_" && matches!(self.peek_kind(), TokenKind::Ident) {
                                self.bump();
                                Ident { name: "_".into(), span: id_span }
                            } else if let Some(id) = self.parse_ident("destructured lambda param") {
                                id
                            } else {
                                break;
                            };
                            // Optional per-slot type annotation — recorded
                            // by the parser but not yet typeck-enforced.
                            if matches!(self.peek_kind(), TokenKind::Colon) {
                                self.bump();
                                let _ = self.parse_type();
                            }
                            names.push(id);
                            self.skip_nl();
                            if matches!(self.peek_kind(), TokenKind::Comma) {
                                self.bump();
                                continue;
                            }
                            break;
                        }
                        let Some(rparen) = self.expect(&TokenKind::RParen, "`)`") else {
                            self.pos = save;
                            return (Vec::new(), Vec::new());
                        };
                        let span = lparen.span.join(rparen.span);
                        let outer = format!("$$dest_{}", local.len());
                        local.push(Ident { name: outer, span });
                        pending_dest.push((local.len() - 1, names, span));
                        self.skip_nl();
                    }
                    _ => break,
                }
                if matches!(self.peek_kind(), TokenKind::Comma) {
                    self.bump();
                    self.skip_nl();
                    continue;
                }
                break;
            }
            self.skip_nl();
            if matches!(self.peek_kind(), TokenKind::Arrow) {
                self.bump();
                for (idx, names, span) in pending_dest {
                    let init = Expr::Path {
                        segments: vec![local[idx].clone()],
                        span,
                    };
                    dest_stmts.push(Stmt::DestructuringDecl { mutable: false, names, init, span });
                }
                params = local;
                return (params, dest_stmts);
            }
            // No arrow — the idents we consumed are actually body expression
            // tokens. Rewind so parse_stmt sees them.
            self.pos = save;
        }
        (params, dest_stmts)
    }
}

#[derive(Default, Clone, Copy)]
struct ClassModifiers {
    is_data: bool,
    is_companion: bool,
    is_enum: bool,
    is_sealed: bool,
    is_open: bool,
    is_abstract: bool,
    is_inner: bool,
    is_fun_interface: bool,
    is_value: bool,
    is_annotation: bool,
}

#[derive(Default, Clone)]
struct ModifierFlags {
    is_data: bool,
    is_companion: bool,
    is_enum: bool,
    is_sealed: bool,
    is_open: bool,
    is_override: bool,
    is_abstract: bool,
    is_inner: bool,
    is_lateinit: bool,
    is_operator: bool,
    is_inline: bool,
    is_infix: bool,
    is_const: bool,
    is_tailrec: bool,
    is_value: bool,
    is_annotation: bool,
    is_suspend: bool,
    /// Span of the `suspend` modifier when one was consumed. Used to point
    /// the user at the modifier when emitting the rejection diagnostic on
    /// constructors / accessors / anonymous functions / delegation
    /// operators.
    suspend_span: Option<Span>,
    /// Span of the `inline` modifier when one was consumed. Used to emit a
    /// deprecation warning when the source wrote `inline class`, since
    /// `inline class` is an alias for `value class`.
    inline_span: Option<Span>,
    visibility: Visibility,
    annotations: Vec<Annotation>,
}

/// Identifiers that are reserved soft modifiers / contextual keywords and
/// must never be tentatively consumed as infix function names. Without this
/// guard, declarations like `val x = foo\nprivate fun ...` could be misread
/// because the previous statement has no newline separator.
fn is_valid_infix_name(name: &str) -> bool {
    !matches!(
        name,
        "private" | "public" | "protected" | "internal"
            | "open" | "abstract" | "final" | "override" | "sealed"
            | "inner" | "lateinit" | "operator" | "infix" | "inline"
            | "tailrec" | "external" | "suspend" | "annotation" | "const"
            | "companion" | "data" | "enum" | "by" | "where" | "get" | "set"
            | "field" | "value" | "actual" | "expect" | "vararg" | "crossinline"
            | "noinline" | "reified" | "out"
    )
}

fn is_trailing_lambda_callable(expr: &Expr) -> bool {
    matches!(
        expr,
        Expr::Path { .. } | Expr::Call { .. } | Expr::Member { .. }
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use klio_lexer::Lexer;
    use klio_span::SourceMap;

    fn parse(src: &str) -> (klio_ast::KotlinFile, DiagnosticSink) {
        let mut map = SourceMap::new();
        let id = map.add("t.kt", src);
        let owned = map.get(id).source.clone();
        let lexed = Lexer::new(id, &owned).tokenize();
        assert!(!lexed.diagnostics.has_errors(),
            "lex diagnostics: {:?}", lexed.diagnostics.diagnostics());
        Parser::new(id, &owned, &lexed.tokens).parse_file()
    }

    #[test]
    fn parses_hello_world() {
        let (file, diags) = parse("fun main() { println(1 + 1) }");
        assert!(!diags.has_errors());
        assert_eq!(file.decls.len(), 1);
        assert!(matches!(file.decls[0], klio_ast::Decl::Function(ref f) if f.name.name == "main"));
    }

    #[test]
    fn package_and_imports() {
        let (file, diags) = parse(
            "package a.b.c\nimport kotlin.math.PI\nimport kotlin.collections.*\n"
        );
        assert!(!diags.has_errors());
        let pkg = file.package.expect("package");
        assert_eq!(pkg.path.iter().map(|s| s.name.as_str()).collect::<Vec<_>>(), vec!["a", "b", "c"]);
        assert_eq!(file.imports.len(), 2);
        assert!(file.imports[1].wildcard);
        assert!(file.imports[1].alias.is_none());
    }

    #[test]
    fn import_with_backticked_segment() {
        let src = "import kotlin.collections.`Map`\n";
        let (file, diags) = parse(src);
        assert!(!diags.has_errors(), "diags: {:?}", diags.diagnostics());
        let imp = &file.imports[0];
        let segs: Vec<_> = imp.path.iter().map(|i| i.name.as_str()).collect();
        assert_eq!(segs, vec!["kotlin", "collections", "Map"]);
    }

    #[test]
    fn import_with_backticked_alias() {
        let src = "import kotlin.math.PI as `tau-ish`\n";
        let (file, diags) = parse(src);
        assert!(!diags.has_errors(), "diags: {:?}", diags.diagnostics());
        let alias = file.imports[0].alias.as_ref().expect("alias");
        assert_eq!(alias.name, "tau-ish");
    }

    #[test]
    fn import_wildcard_with_alias_is_rejected() {
        let (_file, diags) = parse("import kotlin.collections.* as col\n");
        let codes: Vec<_> = diags.diagnostics().iter().filter_map(|d| d.code()).collect();
        assert!(codes.contains(&"P0044"), "expected P0044, got {codes:?}");
    }

    #[test]
    fn class_literal_with_type_arguments_is_rejected() {
        let (_file, diags) = parse("fun main() { val k = Box<Int>::class }\n");
        let codes: Vec<_> = diags.diagnostics().iter().filter_map(|d| d.code()).collect();
        assert!(codes.contains(&"T0104"), "expected T0104, got {codes:?}");
    }

    #[test]
    fn expression_body_function() {
        let (file, diags) = parse("fun sq(x: Int): Int = x * x\n");
        assert!(!diags.has_errors());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        assert!(matches!(f.body, Some(klio_ast::FunctionBody::Expr(_))));
    }

    #[test]
    fn pratt_precedence() {
        // `2 + 3 * 4` must parse as `2 + (3 * 4)`.
        let (file, _) = parse("fun f() { val x = 2 + 3 * 4 }");
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        let Some(klio_ast::FunctionBody::Block(b)) = &f.body else { panic!() };
        let klio_ast::Stmt::Decl(klio_ast::Decl::Property(p)) = &b.stmts[0] else { panic!() };
        let init = p.init.as_ref().unwrap();
        let klio_ast::Expr::Binary { op: outer, rhs, .. } = init else { panic!() };
        assert_eq!(*outer, klio_ast::BinOp::Add);
        assert!(matches!(**rhs, klio_ast::Expr::Binary { op: klio_ast::BinOp::Mul, .. }));
    }

    #[test]
    fn assignment_is_a_statement() {
        let (file, diags) = parse("fun f() { var x = 0; x = 5 }");
        assert!(!diags.has_errors());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        let Some(klio_ast::FunctionBody::Block(b)) = &f.body else { panic!() };
        assert!(matches!(b.stmts.last().unwrap(), klio_ast::Stmt::Assign { .. }));
    }

    #[test]
    fn compound_assignment_recognized() {
        let (file, _) = parse("fun f() { var x = 0; x += 5 }");
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        let Some(klio_ast::FunctionBody::Block(b)) = &f.body else { panic!() };
        let klio_ast::Stmt::Assign { op, .. } = b.stmts.last().unwrap() else { panic!() };
        assert_eq!(*op, klio_ast::AssignOp::Add);
    }

    #[test]
    fn string_template_parts() {
        let (file, diags) = parse(r#"fun f() { val s = "x=$x and ${x + 1}" }"#);
        assert!(!diags.has_errors());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        let Some(klio_ast::FunctionBody::Block(b)) = &f.body else { panic!() };
        let klio_ast::Stmt::Decl(klio_ast::Decl::Property(p)) = &b.stmts[0] else { panic!() };
        let klio_ast::Expr::StringTemplate { parts, .. } = p.init.as_ref().unwrap() else { panic!() };
        assert_eq!(parts.len(), 4);
        assert!(matches!(parts[0], klio_ast::StringPart::Text(_)));
        assert!(matches!(parts[1], klio_ast::StringPart::ShortInterp(_)));
        assert!(matches!(parts[2], klio_ast::StringPart::Text(_)));
        assert!(matches!(parts[3], klio_ast::StringPart::Interp(_)));
    }

    #[test]
    fn if_else_chain() {
        let (file, diags) = parse(r#"
            fun f(x: Int): Int {
                return if (x < 0) -1 else if (x == 0) 0 else 1
            }
        "#);
        assert!(!diags.has_errors());
    }

    #[test]
    fn while_with_break_and_continue() {
        let (file, diags) = parse(r#"
            fun f() {
                var i = 0
                while (i < 10) {
                    if (i == 3) { i = i + 1; continue }
                    if (i == 7) break
                    i = i + 1
                }
            }
        "#);
        assert!(!diags.has_errors());
        let _ = file;
    }

    #[test]
    fn for_loop_parses() {
        let (file, diags) = parse("fun f() { for (k in 1..3) { println(k) } }");
        assert!(!diags.has_errors());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        let Some(klio_ast::FunctionBody::Block(b)) = &f.body else { panic!() };
        assert!(matches!(b.stmts[0], klio_ast::Stmt::Expr(klio_ast::Expr::For { .. })));
    }

    #[test]
    fn member_chain_and_safe_call() {
        let (file, _) = parse("fun f() { val x = a.b?.c }");
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        let Some(klio_ast::FunctionBody::Block(b)) = &f.body else { panic!() };
        let klio_ast::Stmt::Decl(klio_ast::Decl::Property(p)) = &b.stmts[0] else { panic!() };
        let klio_ast::Expr::Member { safe, .. } = p.init.as_ref().unwrap() else { panic!() };
        assert!(*safe);
    }

    #[test]
    fn diagnostic_on_missing_close_paren() {
        let (_file, diags) = parse("fun main() { println(1 + 2 \n}\n");
        assert!(diags.has_errors());
    }

    fn property_type<'a>(file: &'a klio_ast::KotlinFile) -> &'a klio_ast::TypeRef {
        let klio_ast::Decl::Property(p) = &file.decls[0] else { panic!("expected property") };
        p.ty.as_ref().expect("property type annotation")
    }

    #[test]
    fn function_type_simple() {
        let (file, diags) = parse("val f: (Int) -> Int = { it * 2 }\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let ty = property_type(&file);
        let f = ty.function.as_ref().expect("function-type metadata");
        assert!(f.receiver.is_none());
        assert!(!f.is_suspend);
        assert!(!ty.nullable);
        assert_eq!(f.params.len(), 1);
        assert_eq!(f.params[0].name.name, "Int");
        assert_eq!(f.ret.name.name, "Int");
    }

    #[test]
    fn function_type_empty_params() {
        let (file, diags) = parse("val f: () -> Unit = { }\n");
        assert!(!diags.has_errors());
        let ty = property_type(&file);
        let f = ty.function.as_ref().unwrap();
        assert!(f.params.is_empty());
        assert_eq!(f.ret.name.name, "Unit");
    }

    #[test]
    fn function_type_multi_param() {
        let (file, diags) =
            parse("fun apply(f: (Int, String) -> Boolean): Boolean = f(1, \"x\")\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(fn_) = &file.decls[0] else { panic!() };
        let p_ty = &fn_.params[0].ty;
        let f = p_ty.function.as_ref().unwrap();
        assert_eq!(f.params.len(), 2);
        assert_eq!(f.params[0].name.name, "Int");
        assert_eq!(f.params[1].name.name, "String");
        assert_eq!(f.ret.name.name, "Boolean");
    }

    #[test]
    fn function_type_nullable_whole() {
        let (file, diags) = parse("val g: ((Int) -> Int)? = null\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let ty = property_type(&file);
        assert!(ty.nullable);
        let f = ty.function.as_ref().unwrap();
        assert_eq!(f.params.len(), 1);
        assert_eq!(f.ret.name.name, "Int");
    }

    #[test]
    fn function_type_right_associative() {
        let (file, diags) = parse("val h: (Int) -> (Int) -> Int = { x -> { y -> x + y } }\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let ty = property_type(&file);
        let outer = ty.function.as_ref().unwrap();
        assert_eq!(outer.params.len(), 1);
        let inner = outer.ret.function.as_ref().expect("nested function type");
        assert_eq!(inner.params.len(), 1);
        assert_eq!(inner.ret.name.name, "Int");
    }

    #[test]
    fn function_type_with_receiver() {
        let (file, diags) = parse("val r: String.(Int) -> Int = { 0 }\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let ty = property_type(&file);
        let f = ty.function.as_ref().unwrap();
        let recv = f.receiver.as_ref().expect("receiver type");
        assert_eq!(recv.name.name, "String");
        assert_eq!(f.params.len(), 1);
        assert_eq!(f.params[0].name.name, "Int");
    }

    #[test]
    fn suspend_modifier_on_fun_sets_flag() {
        let (file, diags) = parse("suspend fun f() {}\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        assert!(f.is_suspend);
    }

    #[test]
    fn suspend_modifier_on_non_suspend_fun_absent() {
        let (file, diags) = parse("fun f() {}\n");
        assert!(!diags.has_errors());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        assert!(!f.is_suspend);
    }

    #[test]
    fn suspend_modifier_on_secondary_ctor_rejected() {
        let (_file, diags) = parse(
            "class C { suspend constructor() {} }\n",
        );
        assert!(
            diags.diagnostics().iter().any(|d| d.code() == Some("T0114")),
            "expected T0114: {:?}", diags.diagnostics()
        );
    }

    #[test]
    fn suspend_modifier_on_property_rejected() {
        let (_file, diags) = parse("suspend val x = 1\n");
        assert!(
            diags.diagnostics().iter().any(|d| d.code() == Some("T0114")),
            "expected T0114: {:?}", diags.diagnostics()
        );
    }

    #[test]
    fn function_type_suspend_accepted() {
        let (file, diags) = parse("val s: suspend (Int) -> Int = { it }\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let ty = property_type(&file);
        let f = ty.function.as_ref().unwrap();
        assert!(f.is_suspend);
        assert_eq!(f.params.len(), 1);
    }

    #[test]
    fn function_type_named_params_allowed() {
        let (file, diags) = parse("val f: (x: Int, y: Int) -> Int = { a, b -> a + b }\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let ty = property_type(&file);
        let f = ty.function.as_ref().unwrap();
        assert_eq!(f.params.len(), 2);
        assert_eq!(f.params[0].name.name, "Int");
    }

    #[test]
    fn function_type_malformed_empty_arrow() {
        // A parenthesized empty type list without `->` is ill-formed.
        let (_file, diags) = parse("val f: () = 1\n");
        assert!(diags.has_errors());
    }

    #[test]
    fn function_type_parenthesized_single_type_still_parses() {
        // `(Int)` without `->` is a parenthesized type — should round-trip
        // to a plain `Int` ref.
        let (file, diags) = parse("val x: (Int) = 1\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let ty = property_type(&file);
        assert!(ty.function.is_none());
        assert_eq!(ty.name.name, "Int");
    }

    #[test]
    fn recovers_from_top_level_garbage() {
        let (file, diags) = parse("@@@@\nfun main() { println(1) }\n");
        assert!(diags.has_errors());
        // We still recovered to parse `main`.
        assert!(file.decls.iter().any(|d| matches!(d, klio_ast::Decl::Function(f) if f.name.name == "main")));
    }

    // ---------- Phase B: visibility / annotations / when-binding / T & Any.

    #[test]
    fn visibility_modifiers_round_trip() {
        let (file, diags) = parse(
            "private fun a() {}\n\
             internal class B\n\
             protected val c: Int = 1\n\
             public fun d() {}\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let mut vis = Vec::new();
        for d in &file.decls {
            match d {
                klio_ast::Decl::Function(f) => vis.push((f.name.name.as_str(), f.visibility)),
                klio_ast::Decl::Class(c) => vis.push((c.name.name.as_str(), c.visibility)),
                klio_ast::Decl::Property(p) => vis.push((p.name.name.as_str(), p.visibility)),
                _ => {}
            }
        }
        assert_eq!(
            vis,
            vec![
                ("a", klio_ast::Visibility::Private),
                ("B", klio_ast::Visibility::Internal),
                ("c", klio_ast::Visibility::Protected),
                ("d", klio_ast::Visibility::Public),
            ]
        );
    }

    #[test]
    fn visibility_defaults_to_public() {
        let (file, diags) = parse("fun a() {}\n");
        assert!(!diags.has_errors());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        assert_eq!(f.visibility, klio_ast::Visibility::Public);
    }

    #[test]
    fn declaration_site_annotations_captured() {
        let (file, diags) = parse(
            "@Suppress(\"x\") @JvmStatic fun main() {}\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        assert_eq!(f.annotations.len(), 2);
        assert_eq!(f.annotations[0].path[0].name, "Suppress");
        assert_eq!(f.annotations[0].args.len(), 1);
        assert_eq!(f.annotations[1].path[0].name, "JvmStatic");
    }

    #[test]
    fn annotation_use_site_target() {
        let (file, diags) = parse(
            "class C(@field:Foo val x: Int)\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Class(c) = &file.decls[0] else { panic!() };
        let cp = &c.primary_params[0];
        assert_eq!(cp.annotations.len(), 1);
        assert_eq!(cp.annotations[0].use_site, Some(klio_ast::AnnotationUseSite::Field));
        assert_eq!(cp.annotations[0].path[0].name, "Foo");
    }

    #[test]
    fn annotation_array_form() {
        let (file, diags) = parse(
            "@field:[A B] val x: Int = 1\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Property(p) = &file.decls[0] else { panic!() };
        assert_eq!(p.annotations.len(), 2);
        assert!(p.annotations.iter().all(|a| a.use_site == Some(klio_ast::AnnotationUseSite::Field)));
        assert_eq!(p.annotations[0].path[0].name, "A");
        assert_eq!(p.annotations[1].path[0].name, "B");
    }

    #[test]
    fn when_subject_binding_parsed() {
        let (file, diags) = parse(
            "fun f(x: Any): Int = when (val v = x) { is Int -> v; else -> 0 }\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        let Some(klio_ast::FunctionBody::Expr(e)) = &f.body else { panic!() };
        let klio_ast::Expr::When { subject, subject_binding, .. } = e else { panic!() };
        assert!(subject.is_some());
        let b = subject_binding.as_ref().expect("binding");
        assert_eq!(b.name.name, "v");
        assert!(b.ty.is_none());
    }

    #[test]
    fn when_without_binding_still_parses() {
        let (file, diags) = parse(
            "fun f(x: Int): Int = when (x) { 1 -> 1; else -> 0 }\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        let Some(klio_ast::FunctionBody::Expr(e)) = &f.body else { panic!() };
        let klio_ast::Expr::When { subject, subject_binding, .. } = e else { panic!() };
        assert!(subject.is_some());
        assert!(subject_binding.is_none());
    }

    #[test]
    fn as_basic() {
        let (file, diags) = parse("fun f(x: Any): String = x as String\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        let Some(klio_ast::FunctionBody::Expr(e)) = &f.body else { panic!() };
        let klio_ast::Expr::As { ty, safe, .. } = e else { panic!("got {e:?}") };
        assert!(!*safe);
        assert_eq!(ty.name.name, "String");
    }

    #[test]
    fn as_safe() {
        let (file, diags) = parse("fun f(x: Any): String? = x as? String\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        let Some(klio_ast::FunctionBody::Expr(e)) = &f.body else { panic!() };
        let klio_ast::Expr::As { safe, ty, .. } = e else { panic!() };
        assert!(*safe);
        assert_eq!(ty.name.name, "String");
    }

    #[test]
    fn as_chains_left_associative() {
        let (file, diags) = parse("fun f(x: Any): Any = x as A as B\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        let Some(klio_ast::FunctionBody::Expr(e)) = &f.body else { panic!() };
        let klio_ast::Expr::As { expr: outer_expr, ty: outer_ty, .. } = e else { panic!() };
        assert_eq!(outer_ty.name.name, "B");
        let klio_ast::Expr::As { ty: inner_ty, .. } = outer_expr.as_ref() else { panic!() };
        assert_eq!(inner_ty.name.name, "A");
    }

    #[test]
    fn anon_fun_expr_body() {
        let (file, diags) = parse("fun main() { val f = fun(x: Int): Int = x + 1 }\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        let Some(klio_ast::FunctionBody::Block(b)) = &f.body else { panic!() };
        let klio_ast::Stmt::Decl(klio_ast::Decl::Property(p)) = &b.stmts[0] else { panic!() };
        let init = p.init.as_ref().unwrap();
        let klio_ast::Expr::AnonFun { params, return_ty, body, .. } = init else { panic!() };
        assert_eq!(params.len(), 1);
        assert_eq!(return_ty.as_ref().unwrap().name.name, "Int");
        assert!(matches!(body.as_deref(), Some(klio_ast::FunctionBody::Expr(_))));
    }

    #[test]
    fn anon_fun_block_body() {
        let (file, diags) = parse(
            "fun main() { val f = fun(x: Int): Int { return x * 2 } }\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        let Some(klio_ast::FunctionBody::Block(b)) = &f.body else { panic!() };
        let klio_ast::Stmt::Decl(klio_ast::Decl::Property(p)) = &b.stmts[0] else { panic!() };
        let klio_ast::Expr::AnonFun { body, .. } = p.init.as_ref().unwrap() else { panic!() };
        assert!(matches!(body.as_deref(), Some(klio_ast::FunctionBody::Block(_))));
    }

    #[test]
    fn anon_fun_optional_param_types() {
        let (file, diags) = parse(
            "fun main() { val f = fun(x: Int, y: Int) = x + y }\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        let Some(klio_ast::FunctionBody::Block(b)) = &f.body else { panic!() };
        let klio_ast::Stmt::Decl(klio_ast::Decl::Property(p)) = &b.stmts[0] else { panic!() };
        let klio_ast::Expr::AnonFun { params, .. } = p.init.as_ref().unwrap() else { panic!() };
        assert_eq!(params.len(), 2);
    }

    #[test]
    fn anon_fun_with_receiver() {
        let (file, diags) = parse(
            "fun main() { val f = fun Int.(): Int = this + 1 }\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        let Some(klio_ast::FunctionBody::Block(b)) = &f.body else { panic!() };
        let klio_ast::Stmt::Decl(klio_ast::Decl::Property(p)) = &b.stmts[0] else { panic!() };
        let klio_ast::Expr::AnonFun { receiver_ty, .. } = p.init.as_ref().unwrap() else { panic!() };
        assert!(receiver_ty.is_some());
        assert_eq!(receiver_ty.as_ref().unwrap().name.name, "Int");
    }

    #[test]
    fn definitely_non_nullable_type_parsed() {
        let (file, diags) = parse(
            "fun <T> id(x: T & Any): T & Any = x\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        assert!(f.params[0].ty.definitely_non_null);
        assert!(f.return_type.as_ref().unwrap().definitely_non_null);
    }

    fn body_stmts(f: &klio_ast::Function) -> &[klio_ast::Stmt] {
        match f.body.as_ref().unwrap() {
            klio_ast::FunctionBody::Block(b) => &b.stmts,
            klio_ast::FunctionBody::Expr(_) => panic!("not block-bodied"),
        }
    }

    #[test]
    fn infix_call_user_defined() {
        let (file, diags) = parse(
            "infix fun Int.plus2(o: Int): Int = this + o\nfun main() { val r = 1 plus2 2 }\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(f0) = &file.decls[0] else { panic!() };
        assert!(f0.is_infix);
        let klio_ast::Decl::Function(main) = &file.decls[1] else { panic!() };
        let stmts = body_stmts(main);
        let klio_ast::Stmt::Decl(klio_ast::Decl::Property(p)) = &stmts[0] else { panic!() };
        let init = p.init.as_ref().unwrap();
        let Expr::Call { callee, args, is_infix, .. } = init else { panic!("{init:?}") };
        assert!(*is_infix);
        assert_eq!(args.len(), 2);
        let Expr::Path { segments, .. } = callee.as_ref() else { panic!() };
        assert_eq!(segments[0].name, "plus2");
    }

    #[test]
    fn infix_call_no_newline_break() {
        // `a\nfoo b` MUST NOT parse as infix: the newline ends the
        // statement before the candidate ident.
        let (file, _) = parse("fun main() { val a = 1\nfoo(2) }\n");
        let klio_ast::Decl::Function(main) = &file.decls[0] else { panic!() };
        let stmts = body_stmts(main);
        assert_eq!(stmts.len(), 2);
        let klio_ast::Stmt::Decl(_) = &stmts[0] else { panic!() };
        let klio_ast::Stmt::Expr(Expr::Call { is_infix, .. }) = &stmts[1] else { panic!() };
        assert!(!*is_infix);
    }

    #[test]
    fn infix_call_chain_left_assoc() {
        let (file, diags) = parse(
            "infix fun Int.f(o: Int): Int = this\nfun main() { val r = 1 f 2 f 3 }\n",
        );
        assert!(!diags.has_errors());
        let klio_ast::Decl::Function(main) = &file.decls[1] else { panic!() };
        let stmts = body_stmts(main);
        let klio_ast::Stmt::Decl(klio_ast::Decl::Property(p)) = &stmts[0] else { panic!() };
        let init = p.init.as_ref().unwrap();
        // Expect ((1 f 2) f 3).
        let Expr::Call { args, .. } = init else { panic!() };
        assert!(matches!(&args[0], Expr::Call { .. }));
    }

    #[test]
    fn return_with_label() {
        let (file, diags) = parse("fun main() { foo@ run { return@foo 1 } }\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(main) = &file.decls[0] else { panic!() };
        let stmts = body_stmts(main);
        let klio_ast::Stmt::Expr(Expr::Labeled { label, .. }) = &stmts[0] else { panic!() };
        assert_eq!(label.name, "foo");
    }

    #[test]
    fn break_with_label() {
        let (file, diags) = parse("fun main() { outer@ for (i in 1..3) { break@outer } }\n");
        assert!(!diags.has_errors());
        let klio_ast::Decl::Function(main) = &file.decls[0] else { panic!() };
        let stmts = body_stmts(main);
        let klio_ast::Stmt::Expr(Expr::Labeled { label, .. }) = &stmts[0] else { panic!() };
        assert_eq!(label.name, "outer");
    }

    #[test]
    fn continue_with_label() {
        let (file, diags) = parse("fun main() { outer@ for (i in 1..3) { continue@outer } }\n");
        assert!(!diags.has_errors());
    }

    #[test]
    fn labeled_loop() {
        let (file, diags) = parse(
            "fun main() { L@ while (true) { break@L } }\n",
        );
        assert!(!diags.has_errors());
        let klio_ast::Decl::Function(main) = &file.decls[0] else { panic!() };
        let stmts = body_stmts(main);
        let klio_ast::Stmt::Expr(Expr::Labeled { label, expr, .. }) = &stmts[0] else { panic!() };
        assert_eq!(label.name, "L");
        assert!(matches!(expr.as_ref(), Expr::While { .. }));
    }

    #[test]
    fn labeled_lambda_via_run() {
        let (file, diags) = parse(
            "fun main() { foo@ run { return@foo } }\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(main) = &file.decls[0] else { panic!() };
        let stmts = body_stmts(main);
        let klio_ast::Stmt::Expr(Expr::Labeled { label, expr, .. }) = &stmts[0] else { panic!() };
        assert_eq!(label.name, "foo");
        // The inner expression is `run { ... }` — a Call.
        assert!(matches!(expr.as_ref(), Expr::Call { .. }));
    }

    #[test]
    fn const_val_flag_captured() {
        let (file, diags) = parse("const val PI: Double = 3.14\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Property(p) = &file.decls[0] else { panic!() };
        assert!(p.is_const);
        assert!(!p.mutable);
    }

    #[test]
    fn value_class_flag_captured() {
        let (file, diags) = parse("value class Boxed(val n: Int)\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Class(c) = &file.decls[0] else { panic!() };
        assert!(c.is_value);
        assert!(!c.is_annotation);
    }

    #[test]
    fn inline_class_promotes_to_value_with_warning() {
        let (file, diags) = parse("inline class Boxed(val n: Int)\n");
        let klio_ast::Decl::Class(c) = &file.decls[0] else { panic!() };
        assert!(c.is_value);
        let codes: Vec<_> = diags.diagnostics().iter().filter_map(|d| d.code()).collect();
        assert!(codes.iter().any(|c| *c == "W0001"), "expected deprecation warning: {codes:?}");
    }

    #[test]
    fn annotation_class_flag_captured() {
        let (file, diags) = parse("annotation class Marker(val name: String)\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Class(c) = &file.decls[0] else { panic!() };
        assert!(c.is_annotation);
        assert_eq!(c.primary_params.len(), 1);
        assert_eq!(c.primary_params[0].name.name, "name");
    }

    #[test]
    fn tailrec_flag_captured() {
        let (file, diags) = parse(
            "tailrec fun loop(n: Int): Int = if (n == 0) 0 else loop(n - 1)\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        assert!(f.is_tailrec);
    }

    #[test]
    fn typealias_top_level() {
        let (file, diags) = parse("typealias IntList = List<Int>\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::TypeAlias(a) = &file.decls[0] else { panic!() };
        assert_eq!(a.name.name, "IntList");
        assert_eq!(a.target.name.name, "List");
        assert_eq!(a.target.type_args.len(), 1);
        assert_eq!(a.target.type_args[0].ty.name.name, "Int");
        assert!(a.type_params.is_empty());
    }

    #[test]
    fn typealias_with_type_params() {
        let (file, diags) = parse("typealias Pair2<A> = Pair<A, A>\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::TypeAlias(a) = &file.decls[0] else { panic!() };
        assert_eq!(a.name.name, "Pair2");
        assert_eq!(a.type_params.len(), 1);
        assert_eq!(a.type_params[0].name.name, "A");
        assert_eq!(a.target.name.name, "Pair");
        assert_eq!(a.target.type_args.len(), 2);
    }

    #[test]
    fn typealias_function_type() {
        let (file, diags) = parse("typealias Pred<T> = (T) -> Boolean\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::TypeAlias(a) = &file.decls[0] else { panic!() };
        assert_eq!(a.name.name, "Pred");
        assert!(a.target.function.is_some());
        let func = a.target.function.as_ref().unwrap();
        assert_eq!(func.params.len(), 1);
        assert_eq!(func.params[0].name.name, "T");
        assert_eq!(func.ret.name.name, "Boolean");
    }

    #[test]
    fn extension_property_val_parses() {
        let (file, diags) = parse("val Int.cubed: Int get() = this * this * this\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Property(p) = &file.decls[0] else { panic!() };
        assert_eq!(p.name.name, "cubed");
        assert!(!p.mutable);
        let recv = p.receiver_type.as_ref().expect("receiver");
        assert_eq!(recv.name.name, "Int");
        assert!(p.getter.is_some());
        assert!(p.setter.is_none());
        assert!(p.init.is_none());
    }

    #[test]
    fn extension_property_var_parses() {
        let (file, diags) = parse(
            "var Holder.doubled: Int\n    get() = 0\n    set(value) { }\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Property(p) = &file.decls[0] else { panic!() };
        assert!(p.mutable);
        assert_eq!(p.receiver_type.as_ref().unwrap().name.name, "Holder");
        assert!(p.getter.is_some());
        assert!(p.setter.is_some());
    }

    #[test]
    fn extension_property_on_user_class() {
        let (file, diags) = parse(
            "class Box(val n: Int)\nval Box.doubled: Int get() = n * 2\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Property(p) = &file.decls[1] else { panic!() };
        assert_eq!(p.receiver_type.as_ref().unwrap().name.name, "Box");
        assert!(p.getter.is_some());
    }

    #[test]
    fn typealias_in_class_body_parses() {
        // Parser accepts the form; typeck emits T0039 elsewhere.
        let (file, diags) = parse(
            "class Outer { typealias Inner = Int }\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Class(c) = &file.decls[0] else { panic!() };
        assert_eq!(c.members.len(), 1);
        assert!(matches!(&c.members[0], klio_ast::Decl::TypeAlias(_)));
    }

    #[test]
    fn delegation_supertype_parsed() {
        let (file, diags) = parse(
            "interface I { fun f(): Int }\nclass C(d: I) : I by d\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Class(c) = &file.decls[1] else { panic!() };
        assert_eq!(c.supertypes.len(), 1);
        assert_eq!(c.supertype_delegates.len(), 1);
        assert!(c.supertype_args[0].is_none());
        assert!(matches!(&c.supertype_delegates[0], Some(klio_ast::Expr::Path { .. })));
    }

    #[test]
    fn delegation_with_class_body_not_consumed_as_lambda() {
        // The class body's `{ … }` must not be swallowed as a trailing
        // lambda of the delegate expression.
        let (file, diags) = parse(
            "interface I { fun f(): Int }\nclass C(d: I) : I by d { fun extra() = 1 }\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Class(c) = &file.decls[1] else { panic!() };
        assert_eq!(c.members.len(), 1);
        assert!(matches!(&c.members[0], klio_ast::Decl::Function(f) if f.name.name == "extra"));
    }

    #[test]
    fn data_object_parsed() {
        let (file, diags) = parse("data object Foo { val n: Int = 0 }\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Object(o) = &file.decls[0] else { panic!() };
        assert!(o.is_data);
        assert_eq!(o.name.name, "Foo");
    }

    #[test]
    fn plain_object_not_data() {
        let (_file, diags) = parse("object Bar { val n: Int = 0 }\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
    }

    #[test]
    fn spread_arg_parsed() {
        let (file, diags) = parse(
            "fun show(vararg ns: Int) {}\nfun main() { val a = intArrayOf(1); show(*a) }\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(main) = &file.decls[1] else { panic!() };
        let Some(klio_ast::FunctionBody::Block(b)) = &main.body else { panic!() };
        // The second statement is the call show(*a).
        let klio_ast::Stmt::Expr(klio_ast::Expr::Call { args, .. }) = &b.stmts[1] else {
            panic!("expected call");
        };
        assert!(matches!(&args[0], klio_ast::Expr::Spread { .. }));
    }
}
