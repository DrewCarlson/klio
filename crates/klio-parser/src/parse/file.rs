use super::*;

impl<'src, 'tok> Parser<'src, 'tok> {
    pub fn parse_file(mut self) -> (KotlinFile, DiagnosticSink) {
        self.skip_nl();
        let start = self.current_span();

        // File-use-site annotations (`@file:Suppress(...)`,
        // `@file:OptIn(...)`, `@file:JvmName(...)`) precede the
        // package header in Kotlin. Consume them up front; klio
        // doesn't act on them, but the parser must not treat them as
        // a declaration sitting before `package`.
        self.skip_file_annotations();

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

    pub(crate) fn parse_package_header(&mut self) -> Option<PackageHeader> {
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

    pub(crate) fn parse_imports(&mut self) -> Vec<ImportDecl> {
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

    pub(crate) fn parse_top_decl(&mut self) -> Option<Decl> {
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
                                is_expect: flags.is_expect,
                                is_actual: flags.is_actual,
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
                        is_expect: flags.is_expect,
                        is_actual: flags.is_actual,
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
                    self.parse_object(flags.is_data, flags.is_expect, flags.is_actual, flags.visibility)
                        .map(Decl::Object)
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

    pub(crate) fn parse_typealias(
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
    pub(crate) fn skip_modifiers_with_flags(&mut self) -> ModifierFlags {
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
                    } else if text == "expect" {
                        flags.is_expect = true;
                        self.bump();
                    } else if text == "actual" {
                        flags.is_actual = true;
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
    pub(crate) fn parse_annotation_set(&mut self) -> Option<Vec<Annotation>> {
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
    pub(crate) fn try_parse_annotation_use_site(&mut self) -> Option<AnnotationUseSite> {
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

    pub(crate) fn parse_unescaped_annotation(
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
    /// Consume leading `@file:...` annotations (only file-use-site
    /// ones, so a leading `@JvmName fun` on a package-less file keeps
    /// its annotation). Result is discarded — klio doesn't act on
    /// file annotations.
    pub(crate) fn skip_file_annotations(&mut self) {
        loop {
            self.skip_nl();
            if !self.peek_kind().is_at() {
                break;
            }
            let is_file = matches!(
                self.tokens.get(self.pos + 1).map(|t| &t.kind),
                Some(TokenKind::Ident)
            ) && self.text(self.tokens[self.pos + 1].span) == "file"
                && matches!(
                    self.tokens.get(self.pos + 2).map(|t| &t.kind),
                    Some(TokenKind::Colon)
                );
            if !is_file {
                break;
            }
            if self.parse_annotation_set().is_none() {
                break;
            }
        }
    }

    pub(crate) fn parse_annotations(&mut self) -> Vec<Annotation> {
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

}
