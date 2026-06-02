use super::{
    AssignOp, Block, Catch, Expr, Ident, Keyword, Parser, Span, Stmt, TokenKind, WhenBinding,
    WhenBranch, WhenPattern, WhenPatternKind,
};

impl Parser<'_, '_> {
    /// Parses a `controlStructureBody` per the spec: a statement (which
    /// may be an assignment) wrapped as a single-statement block, or an
    /// expression. Used for `if` / `else` / `while` / `for` / `do-while`
    /// bodies so a non-block body can be an assignment like
    /// `if (c) x = v`.
    pub(crate) fn parse_control_structure_body(&mut self) -> Option<Expr> {
        // Kotlin grammar: `controlStructureBody : block | statement`.
        // An annotation may prefix the body expression
        // (`NaturalOrderComparator -> @Suppress("UNCHECKED_CAST") (x as T)`
        // in `Comparator.reversed()`); strip it (runtime no-op) first.
        self.skip_leading_expr_annotation();
        // A leading `{` here is the body *block*, not a lambda — the
        // lambda reading only applies in true expression position
        // (`val f = { … }`), which `parse_primary` handles.
        if matches!(self.peek_kind(), TokenKind::LBrace) {
            // A `{ params -> body }` shape at branch position is a
            // lambda literal (the branch evaluates to a function
            // value); a `{` without a top-level `->` is the body
            // block.
            let next = self.pos + 1;
            let save_pos = self.pos;
            self.pos = next;
            let has_header = self.lambda_has_header();
            self.pos = save_pos;
            if has_header {
                return self.parse_lambda_literal();
            }
            return self.parse_block().map(Expr::Block);
        }
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
            let stmt = Stmt::Assign {
                target: expr,
                op,
                value: rhs,
                span,
            };
            return Some(Expr::Block(Block {
                stmts: vec![stmt],
                span,
            }));
        }
        let _ = save;
        Some(expr)
    }

    pub(crate) fn parse_if(&mut self) -> Option<Expr> {
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
                Expr::Block(Block {
                    stmts: Vec::new(),
                    span: semi.span,
                })
            }
            TokenKind::Keyword(Keyword::Else) => Expr::Block(Block {
                stmts: Vec::new(),
                span: cond_span,
            }),
            _ => self.parse_control_structure_body()?,
        };
        // `else` may follow on the next line.
        let save = self.pos;
        self.skip_nl();
        // A following `else ->` is a `when`-arm else, not this `if`'s
        // else branch — do not consume it (upstream kotlinx-coroutines
        // `when { ... cond -> if (c) return X; else -> ... }`).
        let else_is_when_arm = matches!(self.peek_kind(), TokenKind::Keyword(Keyword::Else)) && {
            let mut j = self.pos + 1;
            while matches!(
                self.tokens.get(j).map(|t| &t.kind),
                Some(TokenKind::Newline)
            ) {
                j += 1;
            }
            matches!(self.tokens.get(j).map(|t| &t.kind), Some(TokenKind::Arrow))
        };
        let else_branch =
            if !else_is_when_arm && matches!(self.peek_kind(), TokenKind::Keyword(Keyword::Else)) {
                self.bump();
                self.skip_nl();
                if matches!(self.peek_kind(), TokenKind::Semicolon) {
                    let semi = self.bump();
                    Some(Box::new(Expr::Block(Block {
                        stmts: Vec::new(),
                        span: semi.span,
                    })))
                } else {
                    self.parse_control_structure_body().map(Box::new)
                }
            } else {
                self.pos = save;
                None
            };
        let end = else_branch
            .as_ref()
            .map_or(then_branch.span(), |e| e.span());
        Some(Expr::If {
            cond: Box::new(cond),
            then_branch: Box::new(then_branch),
            else_branch,
            span: kw.span.join(end),
        })
    }

    pub(crate) fn parse_while(&mut self) -> Option<Expr> {
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

    pub(crate) fn parse_do_while(&mut self) -> Option<Expr> {
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

    pub(crate) fn parse_for(&mut self) -> Option<Expr> {
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

    pub(crate) fn parse_return(&mut self) -> Option<Expr> {
        let kw = self.bump();
        let label = self.consume_jump_label();
        if self.at_newline_or_semi_or_close() {
            let span = label.as_ref().map_or(kw.span, |l| kw.span.join(l.span));
            return Some(Expr::Return {
                value: None,
                label,
                span,
            });
        }
        let value = self.parse_expr()?;
        let span = kw.span.join(value.span());
        Some(Expr::Return {
            value: Some(Box::new(value)),
            label,
            span,
        })
    }

    /// `label@ <expr>` at expression position. The label name is a bare
    /// identifier; the `@` may be `AtNoWs` (`foo@`) or `AtPostWs`
    /// (`foo@ for(...)` with trailing whitespace before the labeled form),
    /// matching the spec's `simpleIdentifier (AT_NO_WS | AT_POST_WS)` rule.
    pub(crate) fn try_parse_label_binding(&mut self) -> Option<Expr> {
        let name_kind = self.peek_kind();
        if !matches!(name_kind, TokenKind::Ident) {
            return None;
        }
        let at_kind = self.tokens.get(self.pos + 1).map(|t| &t.kind);
        if !matches!(at_kind, Some(TokenKind::AtNoWs | TokenKind::AtPostWs)) {
            return None;
        }
        let name_span = self.current_span();
        let label = Ident {
            name: self.ident_name(name_span),
            span: name_span,
        };
        self.bump();
        self.bump();
        self.skip_nl();
        let inner = self.parse_unary_for_label()?;
        let span = label.span.join(inner.span());
        Some(Expr::Labeled {
            label,
            expr: Box::new(inner),
            span,
        })
    }

    /// Parse the body of a `label@ <body>` binding. We re-enter the prefix
    /// rung so the labeled inner expression captures call-chains and
    /// trailing-lambda arguments as usual.
    pub(crate) fn parse_unary_for_label(&mut self) -> Option<Expr> {
        self.parse_prefix()
    }

    /// After a `return` / `break` / `continue` keyword, consume an optional
    /// `@label` suffix. The lexer emits `AtNoWs` when the `@` is directly
    /// attached to the keyword (`return@foo`), so we only accept that shape.
    pub(crate) fn consume_jump_label(&mut self) -> Option<Ident> {
        if !matches!(self.peek_kind(), TokenKind::AtNoWs) {
            return None;
        }
        self.bump();
        self.parse_ident("jump label")
    }

    pub(crate) fn parse_throw(&mut self) -> Option<Expr> {
        let kw = self.bump();
        self.skip_nl();
        let value = self.parse_expr()?;
        let span = kw.span.join(value.span());
        Some(Expr::Throw {
            value: Box::new(value),
            span,
        })
    }

    pub(crate) fn parse_try(&mut self) -> Option<Expr> {
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
            catches.push(Catch {
                binding,
                ty,
                body: catch_body,
                span,
            });
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

    pub(crate) fn parse_when(&mut self) -> Option<Expr> {
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
    pub(crate) fn try_parse_when_binding(&mut self) -> Option<(WhenBinding, Expr)> {
        let save = self.pos;
        let annotations = self.parse_annotations();
        self.skip_nl();
        if !matches!(self.peek_kind(), TokenKind::Keyword(Keyword::Val)) {
            self.pos = save;
            return None;
        }
        // Peek further: val NAME (':' …)? '='
        let mut i = self.pos + 1;
        while matches!(
            self.tokens.get(i).map(|t| &t.kind),
            Some(TokenKind::Newline)
        ) {
            i += 1;
        }
        if !matches!(self.tokens.get(i).map(|t| &t.kind), Some(TokenKind::Ident)) {
            self.pos = save;
            return None;
        }
        // Skip past the name and optional `: Type` to look for `=`.
        let mut j = i + 1;
        while matches!(
            self.tokens.get(j).map(|t| &t.kind),
            Some(TokenKind::Newline)
        ) {
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

    pub(crate) fn parse_when_branch(&mut self, has_subject: bool) -> Option<WhenBranch> {
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
        // Branch bodies are control-structure bodies: an assignment
        // statement (`sum += item`) is allowed alongside expressions.
        let body = self.parse_control_structure_body()?;
        let span = start.join(body.span());
        Some(WhenBranch {
            patterns,
            body,
            span,
        })
    }

    pub(crate) fn parse_when_pattern(&mut self, has_subject: bool) -> Option<WhenPattern> {
        let start = self.current_span();
        // `else` — always valid as a pattern.
        if matches!(self.peek_kind(), TokenKind::Keyword(Keyword::Else)) {
            let tok = self.bump();
            return Some(WhenPattern {
                kind: WhenPatternKind::Else,
                span: tok.span,
            });
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
                    return Some(WhenPattern {
                        kind: WhenPatternKind::IsType(ty),
                        span,
                    });
                }
                TokenKind::Keyword(Keyword::In) => {
                    self.bump();
                    self.skip_nl();
                    let e = self.parse_expr()?;
                    let span = start.join(e.span());
                    return Some(WhenPattern {
                        kind: WhenPatternKind::InRange(e),
                        span,
                    });
                }
                k if k.is_bang() => {
                    let next = self.tokens.get(self.pos + 1).map(|t| &t.kind);
                    match next {
                        Some(TokenKind::Keyword(Keyword::Is)) => {
                            self.bump();
                            self.bump();
                            let ty = self.parse_qualified_type()?;
                            let span = start.join(ty.span);
                            return Some(WhenPattern {
                                kind: WhenPatternKind::NotIsType(ty),
                                span,
                            });
                        }
                        Some(TokenKind::Keyword(Keyword::In)) => {
                            self.bump();
                            self.bump();
                            self.skip_nl();
                            let e = self.parse_expr()?;
                            let span = start.join(e.span());
                            return Some(WhenPattern {
                                kind: WhenPatternKind::NotInRange(e),
                                span,
                            });
                        }
                        _ => {}
                    }
                }
                _ => {}
            }
        }
        let e = self.parse_expr()?;
        let span = start.join(e.span());
        Some(WhenPattern {
            kind: WhenPatternKind::Value(e),
            span,
        })
    }

    pub(crate) fn parse_lambda_literal(&mut self) -> Option<Expr> {
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

    pub(crate) fn parse_trailing_lambda(&mut self) -> Option<Expr> {
        // Same shape; if no `->` is present, default to a single `it` param.
        let lbrace = self.bump();
        let (mut params, dest_stmts) = self.parse_lambda_header();
        if params.is_empty() {
            params.push(Ident {
                name: "it".into(),
                span: lbrace.span,
            });
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
    /// Does the `{ … }` at the cursor have a `params ->` header?
    /// True iff an `Arrow` token occurs at the lambda's own nesting
    /// level (depth 0) before its closing `}`. Nested lambdas /
    /// function types / `when` arrows sit at depth > 0 and are
    /// ignored. Non-mutating.
    pub(crate) fn lambda_has_header(&self) -> bool {
        let mut depth: i32 = 0;
        let mut i = self.pos;
        while let Some(t) = self.tokens.get(i) {
            match &t.kind {
                TokenKind::Arrow if depth == 0 => return true,
                TokenKind::LParen | TokenKind::LBracket | TokenKind::LBrace => {
                    depth += 1;
                }
                TokenKind::RParen | TokenKind::RBracket => {
                    depth -= 1;
                }
                TokenKind::RBrace => {
                    if depth == 0 {
                        return false;
                    }
                    depth -= 1;
                }
                TokenKind::Eof => return false,
                _ => {}
            }
            i += 1;
        }
        false
    }

    pub(crate) fn parse_lambda_header(&mut self) -> (Vec<Ident>, Vec<Stmt>) {
        let save = self.pos;
        let mut params = Vec::new();
        let mut dest_stmts: Vec<Stmt> = Vec::new();
        self.skip_nl();
        // Empty `{ -> ... }` form: arrow at front, no params.
        if matches!(self.peek_kind(), TokenKind::Arrow) {
            self.bump();
            return (params, dest_stmts);
        }
        // A header exists only if a `->` appears at the lambda's top
        // level before its closing `}`. Without this guard a body
        // that opens with `(` — e.g. `{ ((if (c) a else b) + x) }` —
        // is misparsed as a destructuring parameter list, emitting
        // diagnostics that can't be unwound on backtrack.
        if !self.lambda_has_header() {
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
                        local.push(Ident {
                            name: self.ident_name(tok.span),
                            span: tok.span,
                        });
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
                            let id = if text == "_" && matches!(self.peek_kind(), TokenKind::Ident)
                            {
                                self.bump();
                                Ident {
                                    name: "_".into(),
                                    span: id_span,
                                }
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
                    dest_stmts.push(Stmt::DestructuringDecl {
                        mutable: false,
                        names,
                        init,
                        span,
                    });
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
