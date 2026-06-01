use super::*;

impl<'src, 'tok> Parser<'src, 'tok> {
    pub fn parse_expr(&mut self) -> Option<Expr> {
        self.parse_disjunction()
    }

    /// Consume and discard a leading expression annotation, if present.
    /// Kotlin allows annotations to prefix an expression
    /// (`@Suppress("UNCHECKED_CAST") (x as T)`, as in the stdlib's
    /// `Comparator.reversed()` when-branches); they are runtime no-ops.
    /// Applied only at control-structure-body / when-branch position so
    /// it never shadows the label / `this@` / `return@` uses of `@` that
    /// the unary and primary layers parse.
    pub(crate) fn skip_leading_expr_annotation(&mut self) {
        if self.at_expression_annotation() {
            let _ = self.parse_annotations();
            self.skip_nl();
        }
    }

    /// True when the cursor is at an annotation that prefixes an
    /// expression — `@Foo`, `@Foo(...)`, `@[Foo Bar]` — as opposed to a
    /// label (`loop@`), where the `@` follows an identifier and so is not
    /// in leading position.
    pub(crate) fn at_expression_annotation(&self) -> bool {
        self.peek_kind().is_at()
            && matches!(
                self.tokens.get(self.pos + 1).map(|t| &t.kind),
                Some(TokenKind::Ident | TokenKind::LBracket)
            )
    }

    /// Parse a function expression body (`fun f() = <expr>`). Kotlin
    /// allows annotations on the body expression itself
    /// (`= @Suppress("UNCHECKED_CAST") if (…) this as E else null`,
    /// as in the stdlib `CoroutineContext.Element.get`). Annotations
    /// are runtime no-ops here; consume and discard them before the
    /// expression.
    pub(crate) fn parse_expr_body(&mut self) -> Option<Expr> {
        if self.peek_kind().is_at() {
            let _ = self.parse_annotations();
            self.skip_nl();
        }
        self.parse_expr()
    }

    pub(crate) fn parse_disjunction(&mut self) -> Option<Expr> {
        let mut lhs = self.parse_conjunction()?;
        loop {
            self.skip_soft_nl();
            // A wrapped line may begin with `||`; it cannot start a
            // statement, so this is an unambiguous continuation.
            if self.newline_then(&TokenKind::PipePipe) {
                self.skip_nl();
            }
            if !matches!(self.peek_kind(), TokenKind::PipePipe) {
                break;
            }
            self.bump();
            self.skip_nl();
            let rhs = self.parse_conjunction()?;
            let span = lhs.span().join(rhs.span());
            lhs = Expr::Binary { op: BinOp::Or, lhs: Box::new(lhs), rhs: Box::new(rhs), span };
        }
        Some(lhs)
    }

    pub(crate) fn parse_conjunction(&mut self) -> Option<Expr> {
        let mut lhs = self.parse_equality()?;
        loop {
            self.skip_soft_nl();
            // A wrapped line may begin with `&&` (an unambiguous
            // continuation — it cannot start a statement).
            if self.newline_then(&TokenKind::AmpAmp) {
                self.skip_nl();
            }
            if !matches!(self.peek_kind(), TokenKind::AmpAmp) {
                break;
            }
            self.bump();
            self.skip_nl();
            let rhs = self.parse_equality()?;
            let span = lhs.span().join(rhs.span());
            lhs = Expr::Binary { op: BinOp::And, lhs: Box::new(lhs), rhs: Box::new(rhs), span };
        }
        Some(lhs)
    }

    pub(crate) fn parse_equality(&mut self) -> Option<Expr> {
        let mut lhs = self.parse_comparison()?;
        loop {
            self.skip_soft_nl();
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

    pub(crate) fn parse_comparison(&mut self) -> Option<Expr> {
        let mut lhs = self.parse_named_checks()?;
        loop {
            self.skip_soft_nl();
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
    pub(crate) fn parse_named_checks(&mut self) -> Option<Expr> {
        let mut lhs = self.parse_elvis()?;
        loop {
            self.skip_soft_nl();
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

    pub(crate) fn parse_elvis(&mut self) -> Option<Expr> {
        let mut lhs = self.parse_infix_fn()?;
        loop {
            self.skip_soft_nl();
            // A line beginning with `?:` continues the expression
            // (Kotlin allows the elvis operator to lead a wrapped
            // line); `?:` can never start a statement, so this is
            // unambiguous.
            if self.newline_then(&TokenKind::QuestionColon) {
                self.skip_nl();
            }
            if !matches!(self.peek_kind(), TokenKind::QuestionColon) {
                break;
            }
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
    pub(crate) fn parse_infix_fn(&mut self) -> Option<Expr> {
        let mut lhs = self.parse_range()?;
        loop {
            self.skip_soft_nl();
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

    /// After tentatively reading an infix-candidate identifier, peek
    /// ahead to confirm an expression continues. A Newline normally
    /// ends the statement, but inside `(`/`[` (soft newlines) the
    /// right operand may legally start on the following line, so we
    /// look past soft newlines there.
    pub(crate) fn lookahead_infix_rhs_starter(&self) -> bool {
        // We have already read a valid infix-function name on this
        // line; it demands a right operand, so a following newline is
        // a continuation (`(a) or\n (b)`), not a statement boundary —
        // look past it regardless of bracket nesting.
        let mut i = self.pos + 1;
        while matches!(self.tokens.get(i).map(|t| &t.kind), Some(TokenKind::Newline)) {
            i += 1;
        }
        let next = self.tokens.get(i).map(|t| &t.kind);
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

    pub(crate) fn parse_range(&mut self) -> Option<Expr> {
        let mut lhs = self.parse_additive()?;
        loop {
            self.skip_soft_nl();
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

    pub(crate) fn parse_additive(&mut self) -> Option<Expr> {
        let mut lhs = self.parse_multiplicative()?;
        loop {
            self.skip_soft_nl();
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

    pub(crate) fn parse_multiplicative(&mut self) -> Option<Expr> {
        let mut lhs = self.parse_as()?;
        loop {
            self.skip_soft_nl();
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
    pub(crate) fn parse_as(&mut self) -> Option<Expr> {
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

    pub(crate) fn parse_prefix(&mut self) -> Option<Expr> {
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

    pub(crate) fn parse_postfix(&mut self) -> Option<Expr> {
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
                // Labeled trailing lambda: `call lbl@ { ... }`. The
                // label binds the lambda (for `return@lbl`); upstream
                // kotlinx-coroutines uses this pervasively
                // (`suspendCoroutineUninterceptedOrReturn sc@ { ... }`).
                TokenKind::Ident
                    if !self.suppress_trailing_lambda
                        && is_trailing_lambda_callable(&expr)
                        && matches!(
                            self.tokens.get(self.pos + 1).map(|t| &t.kind),
                            Some(TokenKind::AtNoWs | TokenKind::AtPostWs)
                        )
                        && matches!(
                            self.tokens.get(self.pos + 2).map(|t| &t.kind),
                            Some(TokenKind::LBrace)
                        ) =>
                {
                    let name_span = self.current_span();
                    let label = Ident { name: self.ident_name(name_span), span: name_span };
                    self.bump(); // label ident
                    self.bump(); // `@`
                    let lam = self.parse_trailing_lambda()?;
                    let lspan = label.span.join(lam.span());
                    let lam = Expr::Labeled {
                        label,
                        expr: Box::new(lam),
                        span: lspan,
                    };
                    let span = expr.span().join(lspan);
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
    pub(crate) fn parse_value_argument(&mut self) -> Option<Expr> {
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

    pub(crate) fn try_consume_named_arg_name(&mut self) -> Option<String> {
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
    pub(crate) fn next_non_newline_is_chain_continuation(&self) -> bool {
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

}
