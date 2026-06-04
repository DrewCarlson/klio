use super::{
    FunctionTypeRef, Ident, Keyword, Parser, Span, Token, TokenKind, TypeArg, TypeParam, TypeRef,
    Variance, WhereBound,
};

impl Parser<'_, '_> {
    /// Parse a `<T, out U : Foo, reified V>`-style type-parameter list.
    /// Caller has verified the cursor is at `<`. Returns the parsed params;
    /// `reified` is only accepted when `allow_reified` is set (i.e. on
    /// functions, not classes).
    pub(crate) fn parse_type_params(&mut self, allow_reified: bool) -> Vec<TypeParam> {
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
                    }
                    Some("reified") if allow_reified => {
                        self.bump();
                        self.skip_nl();
                        is_reified = true;
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
    pub(crate) fn parse_where_clause(&mut self) -> Vec<WhereBound> {
        let mut bounds = Vec::new();
        // Look across leading newlines without committing — `where` may sit
        // on the next line, but if it isn't there we must leave the newlines
        // alone so they continue serving as statement separators.
        let mut i = self.pos;
        while matches!(
            self.tokens.get(i).map(|t| &t.kind),
            Some(TokenKind::Newline)
        ) {
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
            bounds.push(WhereBound {
                name,
                bound: ty,
                span,
            });
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
    pub(crate) fn parse_type_args(&mut self) -> Vec<TypeArg> {
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
                        name: Ident {
                            name: "*".into(),
                            span: s.span,
                        },
                        nullable: false,
                        span: s.span,
                        type_args: Vec::new(),
                        function: None,
                        definitely_non_null: false,
                        annotations: Vec::new(),
                        qualified_path: None,
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
                args.push(TypeArg {
                    variance,
                    is_star: false,
                    ty: t,
                    span,
                });
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
    pub(crate) fn parse_call_type_args(&mut self) -> Vec<TypeRef> {
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
                    name: Ident {
                        name: "*".into(),
                        span: s.span,
                    },
                    nullable: false,
                    span: s.span,
                    type_args: Vec::new(),
                    function: None,
                    definitely_non_null: false,
                    annotations: Vec::new(),
                    qualified_path: None,
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
                    name: Ident {
                        name: "_".into(),
                        span: s.span,
                    },
                    nullable: false,
                    span: s.span,
                    type_args: Vec::new(),
                    function: None,
                    definitely_non_null: false,
                    annotations: Vec::new(),
                    qualified_path: None,
                });
            } else {
                if matches!(self.peek_kind(), TokenKind::Keyword(Keyword::In))
                    || self.peek_ident_text() == Some("out")
                {
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

    pub(crate) fn parse_type(&mut self) -> Option<TypeRef> {
        self.skip_nl();
        // Soft-keyword `suspend` before a function type — accepted on the
        // type-reference syntax even when downstream enforcement of the
        // suspending colouring at this site is a future addition.
        let mut is_suspend = false;
        if self.peek_ident_text() == Some("suspend") {
            // Only consume as a type modifier when followed by `(` or by an
            // identifier that begins a receiver type — otherwise we'd eat a
            // type literally named `suspend`.
            let next = self.tokens.get(self.pos + 1).map(|t| &t.kind);
            if matches!(next, Some(TokenKind::LParen | TokenKind::Ident)) {
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
            while matches!(
                self.tokens.get(i).map(|t| &t.kind),
                Some(TokenKind::Newline)
            ) {
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
            && matches!(
                self.tokens.get(self.pos + 1).map(|t| &t.kind),
                Some(TokenKind::LParen)
            )
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
                name: Ident {
                    name: "<function>".into(),
                    span,
                },
                nullable: false,
                span,
                type_args: Vec::new(),
                function: Some(Box::new(func)),
                definitely_non_null: false,
                annotations: Vec::new(),
                qualified_path: None,
            });
        }
        // Propagate `suspend` onto the parens-form function type when one
        // was produced. If `suspend` was claimed but no function type
        // materialised, we silently drop it (parity-safe; lambdas don't
        // care).
        if is_suspend && let Some(f) = ty.function.as_mut() {
            f.is_suspend = true;
        }
        Some(ty)
    }

    /// Parse a simple (named) type with optional generic arguments. Does
    /// NOT consume a trailing `?` — that's the caller's job so function-type
    /// nullability composes correctly.
    pub(crate) fn parse_simple_type(&mut self) -> Option<TypeRef> {
        let first = self.parse_ident("type")?;
        let mut name = first.clone();
        let mut path = first.name.clone();
        let mut segments = 1usize;
        let mut type_args = if matches!(self.peek_kind(), TokenKind::Lt) {
            self.parse_type_args()
        } else {
            Vec::new()
        };
        // Qualified / nested type path: `A.B.C` (each segment may carry
        // its own type arguments, e.g. `Outer<T>.Inner`). klio resolves
        // types by simple name against imports + known packages, so the
        // path collapses to its last segment (the package / outer-class
        // qualifier is the namespace the resolver already keys on); the
        // full dotted path is retained in `qualified_path` for the cases
        // that need it (a nested supertype vs a same-named top-level class).
        // Stop before `.(` — that is a receiver-function type
        // (`A.B.() -> R`), consumed by `parse_type`.
        while !self.suppress_qualified_path
            && matches!(self.peek_kind(), TokenKind::Dot)
            && matches!(
                self.tokens.get(self.pos + 1).map(|t| &t.kind),
                Some(TokenKind::Ident)
            )
        {
            self.bump(); // '.'
            name = self.parse_ident("type")?;
            path.push('.');
            path.push_str(&name.name);
            segments += 1;
            type_args = if matches!(self.peek_kind(), TokenKind::Lt) {
                self.parse_type_args()
            } else {
                Vec::new()
            };
        }
        let end = self.tokens[self.pos.saturating_sub(1)].span;
        Some(TypeRef {
            name: name.clone(),
            nullable: false,
            span: first.span.join(end),
            type_args,
            function: None,
            definitely_non_null: false,
            annotations: Vec::new(),
            qualified_path: (segments > 1).then_some(path),
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
    pub(crate) fn parse_qualified_type(&mut self) -> Option<TypeRef> {
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
            let Some(seg) = self.parse_ident("type segment") else {
                break;
            };
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
            let dotted = new_name.name.clone();
            head = TypeRef {
                name: new_name,
                nullable: false,
                span: start,
                type_args,
                function: None,
                definitely_non_null: false,
                annotations: Vec::new(),
                qualified_path: Some(dotted),
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
    pub(crate) fn parse_parens_or_function_type(&mut self, start: Span) -> Option<TypeRef> {
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
                name: Ident {
                    name: "<function>".into(),
                    span,
                },
                nullable: false,
                span,
                type_args: Vec::new(),
                function: Some(Box::new(func)),
                definitely_non_null: false,
                annotations: Vec::new(),
                qualified_path: None,
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
    pub(crate) fn parse_function_type_params(&mut self) -> Option<(Vec<TypeRef>, Token, Token)> {
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

    /// Generic type arguments at a call site (`f<T>(...)` or `f<T> { … }`).
    /// We don't model the type args, just consume them so the trailing call
    /// or trailing-lambda parses. The disambiguator: scan from `<` for a
    /// matching `>` (tracking `<`/`>` depth and bailing on tokens that
    /// can't appear inside a type list), and only accept when the `>` is
    /// immediately followed by `(`, `{`, `.`, `?.`, or `::`.
    pub(crate) fn try_skip_generic_call_args(&self) -> bool {
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
                            Some(
                                TokenKind::LParen
                                    | TokenKind::LBrace
                                    | TokenKind::Dot
                                    | TokenKind::QuestionDot
                                    | TokenKind::ColonColon
                            )
                        );
                    }
                }
                // Tokens that wouldn't appear in a type list — bail out.
                // `*` inside the angle brackets is a star projection
                // (`Foo<List<*>>()`), not multiplication; only bail on
                // it at depth 0 where it would be an arithmetic op.
                TokenKind::Star if depth == 0 => return false,
                TokenKind::Eq
                | TokenKind::Semicolon
                | TokenKind::Plus
                | TokenKind::Minus
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
}
