use super::{Parser, FileId, Token, TokenKind, DiagnosticSink, Span, Diagnostic, Ident, Keyword};

impl<'src, 'tok> Parser<'src, 'tok> {
    #[must_use]
    pub fn new(_file: FileId, src: &'src str, tokens: &'tok [Token]) -> Self {
        // A newline is *soft* (an expression may wrap across it) only
        // when the innermost still-open bracket is `(` or `[`. Inside
        // a `{ … }` — a block, lambda, or `when` body — newlines stay
        // significant (statement / when-entry separators) even when
        // that `{}` is itself nested inside `(…)`, e.g.
        // `f(when { a -> x \n b -> y })`. Tracked with a bracket
        // stack so the *innermost* context wins; a counter that
        // ignored `{` mis-softened newlines inside such nested blocks.
        let mut nl_soft = Vec::with_capacity(tokens.len());
        let mut stack: Vec<u8> = Vec::new();
        let soft = |s: &[u8]| matches!(s.last(), Some(b'(' | b'['));
        for t in tokens {
            match t.kind {
                TokenKind::RParen | TokenKind::RBracket | TokenKind::RBrace => {
                    stack.pop();
                    nl_soft.push(soft(&stack));
                }
                TokenKind::LParen => {
                    nl_soft.push(soft(&stack));
                    stack.push(b'(');
                }
                TokenKind::LBracket => {
                    nl_soft.push(soft(&stack));
                    stack.push(b'[');
                }
                TokenKind::LBrace => {
                    nl_soft.push(soft(&stack));
                    stack.push(b'{');
                }
                _ => nl_soft.push(soft(&stack)),
            }
        }
        Self {
            src,
            tokens,
            pos: 0,
            diagnostics: DiagnosticSink::new(),
            suppress_trailing_lambda: false,
            suppress_qualified_path: false,
            nl_soft,
        }
    }

    /// Are newlines soft at the cursor (inside `(`/`[`)? When true,
    /// the expression grammar may continue across a line break
    /// before or after a binary/infix operator.
    pub(crate) fn nl_is_soft(&self) -> bool {
        self.nl_soft.get(self.pos).copied().unwrap_or(false)
    }

    /// Skip newline tokens, but only where they are soft (inside
    /// round/square brackets). A no-op elsewhere, so block-level
    /// statement separation is unaffected.
    pub(crate) fn skip_soft_nl(&mut self) {
        while matches!(self.peek_kind(), TokenKind::Newline) && self.nl_is_soft() {
            self.pos += 1;
        }
    }

    // ---------- cursor helpers ----------

    pub(crate) fn peek(&self) -> &Token {
        &self.tokens[self.pos]
    }

    pub(crate) fn peek_kind(&self) -> &TokenKind {
        &self.tokens[self.pos].kind
    }

    pub(crate) fn bump(&mut self) -> Token {
        let t = self.tokens[self.pos].clone();
        if !matches!(t.kind, TokenKind::Eof) {
            self.pos += 1;
        }
        t
    }

    /// Skip soft newlines — newlines that don't terminate a statement.
    pub(crate) fn skip_nl(&mut self) {
        while matches!(self.peek_kind(), TokenKind::Newline) {
            self.pos += 1;
        }
    }

    /// Spec §7.1: assignments are statements, not expressions. After parsing
    /// an expression in a value-context (paren, `if`/`while`/`do-while`/`when`
    /// condition, `for` range, value-argument), reject a trailing assignment
    /// operator with a clear diagnostic and consume the RHS to recover.
    pub(crate) fn reject_trailing_assignment(&mut self) {
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

    pub(crate) fn at_newline_or_semi_or_close(&self) -> bool {
        matches!(
            self.peek_kind(),
            TokenKind::Newline | TokenKind::Semicolon | TokenKind::Eof | TokenKind::RBrace
        )
    }

    pub(crate) fn text(&self, span: Span) -> &str {
        &self.src[span.range()]
    }

    /// Read the identifier name stored in the token's span, stripping the
    /// surrounding backticks when the source uses an escaped identifier
    /// (`` `foo bar` ``). For unescaped identifiers this is a plain slice.
    pub(crate) fn ident_name(&self, span: Span) -> String {
        let raw = self.text(span);
        if raw.len() >= 2 && raw.starts_with('`') && raw.ends_with('`') {
            raw[1..raw.len() - 1].to_string()
        } else {
            raw.to_string()
        }
    }

    pub(crate) fn current_span(&self) -> Span {
        self.peek().span
    }

    pub(crate) fn error(&mut self, code: &'static str, msg: impl Into<String>, span: Span) {
        self.diagnostics.emit(Diagnostic::error(msg, span).with_code(code));
    }

    pub(crate) fn expect(&mut self, kind: &TokenKind, what: &str) -> Option<Token> {
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

    pub(crate) fn parse_ident(&mut self, what: &str) -> Option<Ident> {
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

    pub(crate) fn recover_to_top_level(&mut self) {
        while !matches!(
            self.peek_kind(),
            TokenKind::Eof |
TokenKind::Keyword(Keyword::Fun | Keyword::Val | Keyword::Var | Keyword::Class
| Keyword::Object | Keyword::Interface | Keyword::Package | Keyword::Import)
        ) {
            self.bump();
        }
    }

    pub(crate) fn recover_to_stmt_end(&mut self) {
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

    /// Returns the text of the next token if it is an `Ident`, without
    /// consuming.
    pub(crate) fn peek_ident_text(&self) -> Option<&str> {
        let tok = self.tokens.get(self.pos)?;
        if matches!(tok.kind, TokenKind::Ident) {
            Some(self.text(tok.span))
        } else {
            None
        }
    }

    // ---------- types ----------

    pub(crate) fn peek_keyword_ident(&self, name: &str) -> bool {
        matches!(self.peek_kind(), TokenKind::Ident) && self.text(self.current_span()) == name
    }

    /// True when, skipping any newlines from the cursor, the next
    /// significant token is `kind`. Used so a line that *starts* with
    /// a binary continuation operator (e.g. `?:`) joins the previous
    /// expression rather than ending it.
    pub(crate) fn newline_then(&self, kind: &TokenKind) -> bool {
        if !matches!(self.peek_kind(), TokenKind::Newline) {
            return false;
        }
        let mut i = self.pos;
        while matches!(self.tokens.get(i).map(|t| &t.kind), Some(TokenKind::Newline)) {
            i += 1;
        }
        self.tokens.get(i).map(|t| &t.kind) == Some(kind)
    }

}
