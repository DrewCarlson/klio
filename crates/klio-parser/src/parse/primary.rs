use super::{Expr, Ident, Keyword, Parser, StringPart, TokenKind};

impl Parser<'_, '_> {
    // Single match-dispatch over primary tokens; splitting would fragment it.
    #[allow(clippy::too_many_lines)]
    pub(crate) fn parse_primary(&mut self) -> Option<Expr> {
        self.skip_nl();
        let kind = self.peek_kind().clone();
        match kind {
            TokenKind::IntLiteral { base, suffix } => Some(self.parse_int_literal(base, suffix)),
            TokenKind::FloatLiteral { suffix: _ } => Some(self.parse_float_literal()),
            TokenKind::BoolLiteral(v) => {
                let tok = self.bump();
                Some(Expr::BoolLit {
                    value: v,
                    span: tok.span,
                })
            }
            TokenKind::NullLiteral => {
                let tok = self.bump();
                Some(Expr::NullLit { span: tok.span })
            }
            TokenKind::CharLiteral(c) => {
                let tok = self.bump();
                Some(Expr::CharLit {
                    value: c,
                    span: tok.span,
                })
            }
            // Collection-literal `[a, b, ...]`. Kotlin permits this
            // only as an annotation argument
            // (`@Foo(imports = ["a", "b"])`); klio accepts it as a
            // `listOf(...)` expression — annotation arguments are
            // runtime-inert, so the representation only needs to
            // parse and carry the elements.
            TokenKind::LBracket => {
                let lb = self.bump();
                self.skip_nl();
                let mut elems = Vec::new();
                while !matches!(self.peek_kind(), TokenKind::RBracket | TokenKind::Eof) {
                    let Some(e) = self.parse_expr() else { break };
                    elems.push(e);
                    self.skip_nl();
                    if matches!(self.peek_kind(), TokenKind::Comma) {
                        self.bump();
                        self.skip_nl();
                    } else {
                        break;
                    }
                }
                let rb = self.expect(&TokenKind::RBracket, "`]`")?;
                let span = lb.span.join(rb.span);
                let n = elems.len();
                let callee = Expr::Path {
                    segments: vec![Ident {
                        name: "listOf".into(),
                        span: lb.span,
                    }],
                    span: lb.span,
                };
                Some(Expr::Call {
                    callee: Box::new(callee),
                    args: elems,
                    arg_names: vec![None; n],
                    type_args: Vec::new(),
                    is_infix: false,
                    span,
                })
            }
            TokenKind::StringQuote { .. } => self.parse_string_template(),
            TokenKind::Ident => {
                if let Some(label_expr) = self.try_parse_label_binding() {
                    return Some(label_expr);
                }
                let tok = self.bump();
                let ident = Ident {
                    name: self.ident_name(tok.span),
                    span: tok.span,
                };
                Some(Expr::Path {
                    segments: vec![ident],
                    span: tok.span,
                })
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
                // A brace in expression position is always a function
                // literal in Kotlin (there is no block-expression);
                // `{ it + 1 }` assigned to a function-typed val is a
                // lambda, not a block. `parse_lambda_literal` handles
                // the no-`->` (implicit `it` / zero-arg) form.
                { self.parse_lambda_literal() }
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
                Some(Expr::This {
                    qualifier,
                    span: tok.span.join(end),
                })
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
                let (members, _init, _ipos, _sec) = self.parse_class_body();
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
                Some(Expr::Super {
                    qualifier,
                    label,
                    span: tok.span.join(end),
                })
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

    pub(crate) fn parse_int_literal(
        &mut self,
        base: klio_lexer::NumBase,
        suffix: klio_lexer::IntSuffix,
    ) -> Expr {
        let tok = self.bump();
        let raw_text = self.text(tok.span);
        let (digits, radix): (&str, u32) = match base {
            klio_lexer::NumBase::Decimal => (raw_text.trim_end_matches(['L', 'u', 'U']), 10),
            klio_lexer::NumBase::Hex => (
                raw_text
                    .trim_start_matches("0x")
                    .trim_start_matches("0X")
                    .trim_end_matches(['L', 'u', 'U']),
                16,
            ),
            klio_lexer::NumBase::Binary => (
                raw_text
                    .trim_start_matches("0b")
                    .trim_start_matches("0B")
                    .trim_end_matches(['L', 'u', 'U']),
                2,
            ),
        };
        let cleaned: String = digits.chars().filter(|c| *c != '_').collect();
        let value: i64 = i64::from_str_radix(&cleaned, radix).unwrap_or_else(|_| {
            self.error("E0010", "integer literal out of range", tok.span);
            0
        });
        let kind = match suffix {
            klio_lexer::IntSuffix::Long => klio_ast::IntLitKind::Long,
            klio_lexer::IntSuffix::UInt => klio_ast::IntLitKind::UInt,
            klio_lexer::IntSuffix::ULong => klio_ast::IntLitKind::ULong,
            klio_lexer::IntSuffix::None => klio_ast::IntLitKind::Int,
        };
        Expr::IntLit {
            value,
            kind,
            span: tok.span,
        }
    }

    pub(crate) fn parse_float_literal(&mut self) -> Expr {
        let tok = self.bump();
        let raw_text = self.text(tok.span);
        let has_f_suffix = raw_text.ends_with('f') || raw_text.ends_with('F');
        let cleaned: String = raw_text
            .chars()
            .filter(|c| *c != '_' && !matches!(c, 'f' | 'F'))
            .collect();
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
        Expr::FloatLit {
            value,
            kind,
            span: tok.span,
        }
    }

    pub(crate) fn parse_string_template(&mut self) -> Option<Expr> {
        let open = self.bump(); // StringQuote
        let triple = matches!(open.kind, TokenKind::StringQuote { triple: true });
        let mut parts = Vec::new();
        loop {
            let kind = self.peek_kind().clone();
            match kind {
                TokenKind::StringQuote { triple: t } if t == triple => {
                    let close = self.bump();
                    return Some(Expr::StringTemplate {
                        parts,
                        span: open.span.join(close.span),
                    });
                }
                TokenKind::StringText(s) => {
                    self.bump();
                    parts.push(StringPart::Text(s));
                }
                TokenKind::ShortInterp(name) => {
                    let tok = self.bump();
                    parts.push(StringPart::ShortInterp(Ident {
                        name,
                        span: tok.span,
                    }));
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
                    return Some(Expr::StringTemplate {
                        parts,
                        span: open.span,
                    });
                }
                _ => {
                    let span = self.current_span();
                    self.error("E0014", "unexpected token inside string template", span);
                    self.bump();
                }
            }
        }
    }
}
