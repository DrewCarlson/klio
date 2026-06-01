use super::*;

impl<'src, 'tok> Parser<'src, 'tok> {
    pub(crate) fn parse_fun(&mut self, flags: ModifierFlags) -> Option<Function> {
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
            let saved_sqp = self.suppress_qualified_path;
            self.suppress_qualified_path = true;
            let mut ty = self.parse_type();
            self.suppress_qualified_path = saved_sqp;
            // Fold additional `.Ident` segments into the receiver type
            // for qualified extension receivers like `Foo.Companion.bar()`
            // — keep the final `.Ident` as the function name itself.
            while let Some(ref mut t) = ty {
                if t.function.is_some() || t.nullable {
                    break;
                }
                let after = self.tokens.get(self.pos).map(|tok| &tok.kind);
                let after_next = self.tokens.get(self.pos + 1).map(|tok| &tok.kind);
                let after_2 = self.tokens.get(self.pos + 2).map(|tok| &tok.kind);
                // Pattern: `.Ident .Ident` (more segments left). Fold only
                // when at least two more `.Ident` pairs remain — the very
                // last one is the function name.
                if matches!(after, Some(TokenKind::Dot))
                    && matches!(after_next, Some(TokenKind::Ident))
                    && matches!(after_2, Some(TokenKind::Dot))
                {
                    self.bump(); // '.'
                    let Some(seg) = self.parse_ident("type segment") else { break };
                    t.name = Ident {
                        name: format!("{}.{}", t.name.name, seg.name),
                        span: t.name.span.join(seg.span),
                    };
                    t.span = t.span.join(seg.span);
                } else if matches!(after, Some(TokenKind::Dot))
                    && matches!(after_next, Some(TokenKind::Ident))
                    && matches!(after_2, Some(TokenKind::Lt))
                {
                    // Pattern: `.Ident<...>` — nested type with generic
                    // args (e.g. `Map.Entry<K, V>.component1()`). Fold
                    // the `.Ident<...>` into receiver only when a
                    // following `.Ident` exists for the function name.
                    let save_pos = self.pos;
                    self.bump(); // '.'
                    let Some(seg) = self.parse_ident("type segment") else {
                        self.pos = save_pos;
                        break;
                    };
                    let args = if matches!(self.peek_kind(), TokenKind::Lt) {
                        self.parse_type_args()
                    } else {
                        Vec::new()
                    };
                    // Require following `.Ident` (the function name).
                    if !matches!(self.peek_kind(), TokenKind::Dot)
                        || !matches!(
                            self.tokens.get(self.pos + 1).map(|tk| &tk.kind),
                            Some(TokenKind::Ident)
                        )
                    {
                        self.pos = save_pos;
                        break;
                    }
                    t.name = Ident {
                        name: format!("{}.{}", t.name.name, seg.name),
                        span: t.name.span.join(seg.span),
                    };
                    t.type_args = args;
                    t.span = t.span.join(seg.span);
                } else {
                    break;
                }
            }
            // `parse_type` already consumed the `Ident` and any trailing
            // `?`; now consume the dot before the function name. `T?.foo`
            // lexes the `?.` as one `QuestionDot` token — handle that case
            // by flagging the receiver nullable and treating the same token
            // as the separating dot.
            if matches!(self.peek_kind(), TokenKind::QuestionDot) {
                if let Some(ref mut t) = ty {
                    t.nullable = true;
                    let qd = self.bump();
                    t.span = t.span.join(qd.span);
                } else {
                    self.bump();
                }
            } else {
                self.expect(&TokenKind::Dot, "`.`")?;
            }
            self.skip_nl();
            ty
        } else if self.looks_like_paren_extension_receiver() {
            // Parenthesized / function-type extension receiver:
            // `fun (suspend () -> T).startCoroutine(...)`.
            let ty = self.parse_type();
            if matches!(self.peek_kind(), TokenKind::QuestionDot) {
                self.bump();
            } else {
                self.expect(&TokenKind::Dot, "`.`")?;
            }
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
                self.parse_expr_body().map(FunctionBody::Expr)
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
            is_expect: flags.is_expect,
            is_actual: flags.is_actual,
            visibility: flags.visibility,
            annotations: flags.annotations,
            span: kw.span.join(end),
        })
    }

    /// Anonymous-function expression: `fun [<T>] [Receiver.](...) [: Ret] [body]`.
    /// No name follows the `fun` keyword. `return` inside the body is a local
    /// return out of this function, not the enclosing one.
    pub(crate) fn parse_anon_fun(&mut self) -> Option<Expr> {
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
        let params = self.parse_param_list_with(true);
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
                self.parse_expr_body().map(|e| Box::new(FunctionBody::Expr(e)))
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
    pub(crate) fn looks_like_anon_fun_receiver(&self) -> bool {
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
    pub(crate) fn looks_like_extension_receiver(&self) -> bool {
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
        // `T?.foo` lexes the `?.` as a single `QuestionDot` token; treat it
        // as nullable-receiver followed by the member separator.
        if matches!(self.tokens.get(j).map(|t| &t.kind), Some(TokenKind::QuestionDot)) {
            return matches!(self.tokens.get(j + 1).map(|t| &t.kind), Some(TokenKind::Ident));
        }
        matches!(self.tokens.get(j).map(|t| &t.kind), Some(TokenKind::Dot))
            && matches!(self.tokens.get(j + 1).map(|t| &t.kind), Some(TokenKind::Ident))
    }

    /// Look-ahead for a parenthesized extension receiver:
    /// `( … ) (?)? . Ident` — the shape of `fun (suspend () -> T).f()`
    /// or `fun ((A) -> B).f()`. The receiver is a function/grouped
    /// type, so the `Ident`-led [`looks_like_extension_receiver`]
    /// scan does not apply.
    pub(crate) fn looks_like_paren_extension_receiver(&self) -> bool {
        if !matches!(self.tokens.get(self.pos).map(|t| &t.kind), Some(TokenKind::LParen)) {
            return false;
        }
        let mut depth = 0usize;
        let mut j = self.pos;
        loop {
            match self.tokens.get(j).map(|t| &t.kind) {
                Some(TokenKind::LParen) => depth += 1,
                Some(TokenKind::RParen) => {
                    depth -= 1;
                    if depth == 0 {
                        j += 1;
                        break;
                    }
                }
                None | Some(TokenKind::Eof) => return false,
                _ => {}
            }
            j += 1;
        }
        if self.tokens.get(j).map(|t| t.kind.is_question()).unwrap_or(false) {
            j += 1;
        }
        if matches!(self.tokens.get(j).map(|t| &t.kind), Some(TokenKind::QuestionDot)) {
            return matches!(self.tokens.get(j + 1).map(|t| &t.kind), Some(TokenKind::Ident));
        }
        matches!(self.tokens.get(j).map(|t| &t.kind), Some(TokenKind::Dot))
            && matches!(self.tokens.get(j + 1).map(|t| &t.kind), Some(TokenKind::Ident))
    }

    pub(crate) fn parse_param_list(&mut self) -> Vec<Param> {
        self.parse_param_list_with(false)
    }

    /// Same as `parse_param_list`, but with `allow_no_type` the
    /// param's type annotation is optional — used for anonymous
    /// function expressions (`fun(n) = …`) where the function-type
    /// context supplies the param type.
    pub(crate) fn parse_param_list_with(&mut self, allow_no_type: bool) -> Vec<Param> {
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
            let has_colon = matches!(self.peek_kind(), TokenKind::Colon);
            if has_colon {
                self.bump();
            } else if !allow_no_type {
                // Required type annotation missing — produce the
                // standard "expected `:`" diagnostic. Anon-fn params
                // legally omit the annotation; the caller passes
                // `allow_no_type = true` for that context.
                self.expect(&TokenKind::Colon, "`:`");
            }
            let ty = if has_colon || !allow_no_type {
                self.parse_type().unwrap_or_else(|| TypeRef {
                    name: Ident { name: "Any".into(), span: name.span },
                    nullable: true,
                    span: name.span,
                    type_args: Vec::new(),
                    function: None,
                    definitely_non_null: false,
                    annotations: Vec::new(),
                })
            } else {
                // No colon and the caller allows it: synthesise an
                // `Any?` placeholder without trying to parse a type.
                TypeRef {
                    name: Ident { name: "Any".into(), span: name.span },
                    nullable: true,
                    span: name.span,
                    type_args: Vec::new(),
                    function: None,
                    definitely_non_null: false,
                    annotations: Vec::new(),
                }
            };
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

    pub(crate) fn recover_until_paren(&mut self) {
        while !matches!(
            self.peek_kind(),
            TokenKind::RParen | TokenKind::Eof | TokenKind::LBrace
        ) {
            self.bump();
        }
    }

    pub(crate) fn parse_property(&mut self) -> Option<Property> {
        self.parse_property_with_flags(ModifierFlags::default())
    }

    pub(crate) fn parse_property_with_flags(&mut self, flags: ModifierFlags) -> Option<Property> {
        // `suspend` is not a meaningful property modifier, but the
        // stdlib `coroutineContext` intrinsic carries it (under a
        // `@Suppress`). klio runs suspend bodies inline, so the
        // modifier is simply inert on a property rather than an
        // error — accept and ignore it.
        let _ = flags.suspend_span;
        let kw_tok = self.bump();
        let mutable = matches!(kw_tok.kind, TokenKind::Keyword(Keyword::Var));
        self.skip_nl();
        // Type parameters on an extension property:
        // `var <T> Box<T>.value: T`. klio erases generics, so the
        // list is parsed and discarded — `T` resolves structurally
        // in the receiver / type / accessors.
        if matches!(self.peek_kind(), TokenKind::Lt) {
            let _ = self.parse_type_params(true);
            self.skip_nl();
        }
        // A use-site-targeted annotation may prefix the extension
        // receiver (`val @receiver:AccessibleLateinitPropertyLiteral
        // KProperty0<*>.isInitialized`, stdlib Lateinit.kt). Annotations
        // are runtime no-ops here — consume and discard before the
        // receiver type.
        if self.peek_kind().is_at() {
            let _ = self.parse_annotations();
            self.skip_nl();
        }
        let receiver_type = if self.looks_like_extension_receiver() {
            let saved_sqp = self.suppress_qualified_path;
            self.suppress_qualified_path = true;
            let mut ty = self.parse_type();
            self.suppress_qualified_path = saved_sqp;
            if matches!(self.peek_kind(), TokenKind::QuestionDot) {
                if let Some(ref mut t) = ty {
                    t.nullable = true;
                    let qd = self.bump();
                    t.span = t.span.join(qd.span);
                } else {
                    self.bump();
                }
            } else {
                self.expect(&TokenKind::Dot, "`.`")?;
            }
            // A Companion-qualified receiver (`String.Companion.foo`,
            // stdlib TextH.kt's `String.Companion.CASE_INSENSITIVE_ORDER`):
            // the receiver type is `<Class>.Companion`, so consume the
            // `Companion .` and keep the following ident as the property
            // name. klio resolves the property against the class's
            // companion, so the receiver collapses to the class type.
            if self.peek_ident_text() == Some("Companion")
                && matches!(
                    self.tokens.get(self.pos + 1).map(|t| &t.kind),
                    Some(TokenKind::Dot)
                )
            {
                self.bump(); // `Companion`
                self.bump(); // `.`
                self.skip_nl();
            }
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
            let mut acc_inline = false;
            // Accept `inline` and / or a visibility modifier in either
            // order ahead of the `get` / `set` keyword. Kotlin allows
            // `inline get()` and `private inline set(v)`; both
            // combinations parse here. Lookahead-only: the `pos` is
            // committed below once the accessor is confirmed.
            loop {
                let Some(tok) = self.tokens.get(i) else { break };
                if !matches!(tok.kind, TokenKind::Ident) {
                    break;
                }
                let txt = self.text(tok.span);
                let v = match txt {
                    "public" => Some(Visibility::Public),
                    "private" => Some(Visibility::Private),
                    "protected" => Some(Visibility::Protected),
                    "internal" => Some(Visibility::Internal),
                    _ => None,
                };
                if v.is_some() && acc_visibility.is_none() {
                    acc_visibility = v;
                    i += 1;
                    while matches!(self.tokens.get(i).map(|t| &t.kind), Some(TokenKind::Newline)) {
                        i += 1;
                    }
                    continue;
                }
                if txt == "inline" && !acc_inline {
                    acc_inline = true;
                    i += 1;
                    while matches!(self.tokens.get(i).map(|t| &t.kind), Some(TokenKind::Newline)) {
                        i += 1;
                    }
                    continue;
                }
                break;
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
            if is_bodyless && acc_visibility.is_none() && !acc_inline {
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
                let e = self.parse_expr_body()?;
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
                is_inline: acc_inline,
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
            is_expect: flags.is_expect,
            is_actual: flags.is_actual,
            setter_visibility,
            visibility: flags.visibility,
            annotations: flags.annotations,
            span: kw_tok.span.join(end),
        })
    }

}
