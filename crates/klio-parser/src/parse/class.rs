use super::*;

impl<'src, 'tok> Parser<'src, 'tok> {
    pub(crate) fn parse_class(
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
            is_expect,
            is_actual,
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
        // Optional primary-constructor annotations:
        // `class Foo @Inject @Deprecated(...) internal constructor(...)`.
        // Kotlin requires the `constructor` keyword when the primary
        // constructor is annotated/modified, so only consume a leading
        // `@…` run when it is actually followed by `[visibility]
        // constructor` — otherwise the `@` belongs to the *next*
        // top-level declaration (e.g. `annotation class A` then
        // `@A fun f()`) and must be left untouched. klio treats
        // primary-ctor annotations as runtime no-ops.
        if self.peek_kind().is_at() {
            let ann_save = self.pos;
            while self.peek_kind().is_at() {
                if self.parse_annotation_set().is_none() {
                    break;
                }
                self.skip_nl();
            }
            // Skip an optional visibility ident, then require
            // `constructor`.
            let mut probe = self.pos;
            let probe_is_vis = matches!(
                self.tokens.get(probe).map(|t| &t.kind),
                Some(TokenKind::Ident)
            ) && {
                let t = self.text(self.tokens[probe].span);
                t == "public" || t == "private" || t == "protected" || t == "internal"
            };
            if probe_is_vis {
                probe += 1;
                while matches!(
                    self.tokens.get(probe).map(|t| &t.kind),
                    Some(TokenKind::Newline)
                ) {
                    probe += 1;
                }
            }
            let is_primary_ctor = matches!(
                self.tokens.get(probe).map(|t| &t.kind),
                Some(TokenKind::Ident)
            ) && self.text(self.tokens[probe].span) == "constructor";
            if !is_primary_ctor {
                self.pos = ann_save; // the `@` annotates the next decl
            }
        }
        // Optional explicit primary constructor:
        // `class Foo [visibility] [actual|expect]* constructor(...)`.
        // Scan a run of soft-keyword constructor modifiers (in any
        // order) that must terminate in `constructor`; commit only
        // then. `actual`/`expect` are runtime-inert here (klio's
        // expect/actual is name-keyed), visibility is recorded.
        let mut primary_ctor_visibility: Option<Visibility> = None;
        {
            let saved = self.pos;
            let mut vis: Option<Visibility> = None;
            let mut consumed_modifier = false;
            loop {
                if !matches!(self.peek_kind(), TokenKind::Ident) {
                    break;
                }
                match self.text(self.current_span()) {
                    "public" => vis = Some(Visibility::Public),
                    "private" => vis = Some(Visibility::Private),
                    "protected" => vis = Some(Visibility::Protected),
                    "internal" => vis = Some(Visibility::Internal),
                    "actual" | "expect" => {}
                    _ => break,
                }
                self.bump();
                self.skip_nl();
                consumed_modifier = true;
            }
            let at_ctor = matches!(self.peek_kind(), TokenKind::Ident)
                && self.text(self.current_span()) == "constructor";
            if at_ctor {
                primary_ctor_visibility = vis;
                self.bump(); // `constructor`
                self.skip_nl();
            } else if consumed_modifier {
                // The run was not a constructor header — restore.
                self.pos = saved;
            }
        }
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
        let (members, init_blocks, init_block_positions, enum_entries, secondary_ctors) =
            if is_enum {
                let (m, i, p, e) = self.parse_enum_class_body();
                (m, i, p, e, Vec::new())
            } else {
                let (m, i, p, s) = self.parse_class_body();
                (m, i, p, Vec::new(), s)
            };
        let end = self.tokens[self.pos.saturating_sub(1)].span;
        Some(Class {
            name,
            type_params,
            where_bounds,
            primary_params,
            primary_ctor_visibility,
            init_blocks,
            init_block_positions,
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
            is_expect,
            is_actual,
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
    pub(crate) fn parse_enum_class_body(
        &mut self,
    ) -> (Vec<Decl>, Vec<Block>, Vec<usize>, Vec<EnumEntry>) {
        // Helper: enum-class body content (after the optional `;`) shares the
        // member-parsing shape of a regular class body, minus secondary
        // constructors.
        let mut members = Vec::new();
        let mut init_blocks = Vec::new();
        let mut init_block_positions: Vec<usize> = Vec::new();
        let mut entries = Vec::new();
        self.skip_nl();
        if !matches!(self.peek_kind(), TokenKind::LBrace) {
            return (members, init_blocks, init_block_positions, entries);
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
                let (m, _i, _p, _s) = self.parse_class_body();
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
                        init_block_positions.push(members.len());
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
        (members, init_blocks, init_block_positions, entries)
    }

    pub(crate) fn parse_companion_object_as_class(
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
        let (members, init_blocks, init_block_positions, _sec) = self.parse_class_body();
        let end = self.tokens[self.pos.saturating_sub(1)].span;
        Some(Class {
            name,
            type_params: Vec::new(),
            where_bounds: Vec::new(),
            primary_params: Vec::new(),
            init_blocks,
            init_block_positions,
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
            is_expect: false,
            is_actual: false,
            enum_entries: Vec::new(),
            members,
            visibility,
            primary_ctor_visibility: None,
            annotations,
            span: kw.span.join(end),
        })
    }

    pub(crate) fn parse_object(
        &mut self,
        is_data: bool,
        is_expect: bool,
        is_actual: bool,
        visibility: Visibility,
    ) -> Option<ObjectDecl> {
        let kw = self.bump(); // `object`
        let name = self.parse_ident("object name")?;
        let (supertypes, supertype_args) = self.parse_optional_supertypes();
        let (members, _init, _ipos, _sec) = self.parse_class_body();
        let end = self.tokens[self.pos.saturating_sub(1)].span;
        Some(ObjectDecl {
            name,
            supertypes,
            supertype_args,
            members,
            is_data,
            is_expect,
            is_actual,
            visibility,
            span: kw.span.join(end),
        })
    }

    pub(crate) fn parse_optional_supertypes(&mut self) -> (Vec<TypeRef>, Vec<Option<Vec<Expr>>>) {
        let (t, a, _d) = self.parse_optional_supertypes_full();
        (t, a)
    }

    pub(crate) fn parse_optional_supertypes_full(
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

    pub(crate) fn parse_class_body(&mut self) -> (Vec<Decl>, Vec<Block>, Vec<usize>, Vec<SecondaryCtor>) {
        let mut members = Vec::new();
        let mut init_blocks = Vec::new();
        let mut init_block_positions: Vec<usize> = Vec::new();
        let mut secondary_ctors = Vec::new();
        let save = self.pos;
        self.skip_nl();
        if !matches!(self.peek_kind(), TokenKind::LBrace) {
            self.pos = save;
            return (members, init_blocks, init_block_positions, secondary_ctors);
        }
        self.bump();
        loop {
            self.skip_stmt_separators();
            if matches!(self.peek_kind(), TokenKind::RBrace | TokenKind::Eof) {
                break;
            }
            if matches!(self.peek_kind(), TokenKind::Ident)
                && self.text(self.current_span()) == "init"
            {
                self.bump();
                self.skip_nl();
                if let Some(b) = self.parse_block() {
                    // Record the init block's position as the number of
                    // members already seen — runs before the next member
                    // (and after earlier ones).
                    init_block_positions.push(members.len());
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
        (members, init_blocks, init_block_positions, secondary_ctors)
    }

    pub(crate) fn parse_secondary_ctor(
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

    pub(crate) fn parse_class_param_list(&mut self) -> Vec<ClassParam> {
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
                    "override" | "final" | "open" | "abstract" | "lateinit"
                    | "actual" | "expect" => {
                        self.bump();
                        self.skip_nl();
                    }
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

}
