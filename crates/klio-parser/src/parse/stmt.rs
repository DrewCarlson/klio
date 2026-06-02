use super::{
    AssignOp, Block, ClassModifiers, Decl, Diagnostic, Ident, Keyword, Parser, Stmt, TokenKind,
};

impl Parser<'_, '_> {
    pub(crate) fn parse_block(&mut self) -> Option<Block> {
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
        Some(Block {
            stmts,
            span: lbrace.span.join(rbrace.span),
        })
    }

    pub(crate) fn skip_stmt_separators(&mut self) {
        while matches!(self.peek_kind(), TokenKind::Newline | TokenKind::Semicolon) {
            self.pos += 1;
        }
    }

    // Single match-dispatch over statement-leading tokens; splitting would fragment it.
    #[allow(clippy::too_many_lines)]
    pub(crate) fn parse_stmt(&mut self) -> Option<Stmt> {
        let save = self.pos;
        let flags = self.skip_modifiers_with_flags();
        match self.peek_kind() {
            TokenKind::Keyword(Keyword::Val | Keyword::Var) => {
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
                                is_expect: flags.is_expect,
                                is_actual: flags.is_actual,
                            },
                            visibility,
                            annotations,
                        )
                        .map(|c| Stmt::Decl(Decl::Class(c)));
                }
                // Anonymous-function expression statement: `fun(...) ...`
                // or `fun <T>(...) ...`. No name follows the `fun` keyword.
                // For `fun <...> Ident(...)`, this is a local generic
                // function declaration — fall through to `parse_fun`.
                let after_generics = if matches!(next, Some(TokenKind::Lt)) {
                    // Skip a balanced generic param list to peek at what
                    // follows: `(` → anonymous; `Ident` → local fn.
                    let mut depth = 1i32;
                    let mut i = self.pos + 2;
                    while let Some(tok) = self.tokens.get(i) {
                        match &tok.kind {
                            TokenKind::Lt => depth += 1,
                            TokenKind::Gt => {
                                depth -= 1;
                                if depth == 0 {
                                    i += 1;
                                    break;
                                }
                            }
                            TokenKind::Eof => break,
                            _ => {}
                        }
                        i += 1;
                    }
                    self.tokens.get(i).map(|t| &t.kind)
                } else {
                    None
                };
                let is_anon = matches!(next, Some(TokenKind::LParen))
                    || matches!(after_generics, Some(TokenKind::LParen));
                if is_anon {
                    self.pos = save;
                    return self.parse_expr_or_assign_stmt();
                }
                self.parse_fun(flags).map(|f| Stmt::Decl(Decl::Function(f)))
            }
            TokenKind::Keyword(Keyword::Class | Keyword::Interface) => {
                let visibility = flags.visibility;
                let annotations = flags.annotations.clone();
                let is_value = flags.is_value || flags.is_inline;
                if flags.is_inline
                    && !flags.is_value
                    && let Some(span) = flags.inline_span
                {
                    self.diagnostics.emit(
                        Diagnostic::warning(
                            "`inline class` is deprecated; use `value class` instead",
                            span,
                        )
                        .with_code("W0001"),
                    );
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
                .map(|c| Stmt::Decl(Decl::Class(c)))
            }
            TokenKind::Keyword(Keyword::Object) => {
                // `object Name { … }` — local singleton. `object { … }` /
                // `object : Super { … }` is an anonymous-object *expression*
                // and falls through to expression parsing.
                let next = self.tokens.get(self.pos + 1).map(|t| &t.kind);
                if matches!(next, Some(TokenKind::Ident)) {
                    self.parse_object(
                        flags.is_data,
                        flags.is_expect,
                        flags.is_actual,
                        flags.visibility,
                    )
                    .map(|o| Stmt::Decl(Decl::Object(o)))
                } else {
                    // Roll back modifiers so the expression parser sees
                    // `object` at the head.
                    self.pos = save;
                    self.parse_expr_or_assign_stmt()
                }
            }
            TokenKind::Keyword(Keyword::Typealias) => self
                .parse_typealias(flags.visibility, flags.annotations)
                .map(|a| Stmt::Decl(Decl::TypeAlias(a))),
            _ => {
                // No declaration matched — roll back so unrelated modifiers
                // (annotations on expressions, etc.) don't get swallowed.
                self.pos = save;
                // A statement may carry leading annotations (`@Suppress(...)`
                // before a `return`/expression statement). They are runtime
                // no-ops here; consume and discard so the expression parser
                // sees the statement itself.
                let _ = self.parse_annotations();
                self.skip_nl();
                self.parse_expr_or_assign_stmt()
            }
        }
    }

    pub(crate) fn parse_destructuring_decl(&mut self) -> Option<Stmt> {
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
                Ident {
                    name: "_".into(),
                    span,
                }
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
        Some(Stmt::DestructuringDecl {
            mutable,
            names,
            init,
            span,
        })
    }

    pub(crate) fn parse_expr_or_assign_stmt(&mut self) -> Option<Stmt> {
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
            return Some(Stmt::Assign {
                target: lhs,
                op,
                value: rhs,
                span,
            });
        }
        Some(Stmt::Expr(lhs))
    }

    // ---------- expressions (Pratt) ----------
}
