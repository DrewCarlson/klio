//! Kotlin lexer.
//!
//! Covers the lexical structure of Kotlin 2.3.21 (spec §1) needed by the
//! parser: trivia (line + nested block comments), identifiers and keywords,
//! numeric literals across all four bases with suffixes, character literals,
//! template-aware string literals (regular and triple-quoted/raw), and the
//! operator/punctuation set.
//!
//! String templates are produced as a structured token sequence:
//! `StringQuote StringText InterpStart … InterpEnd StringText StringQuote`.
//! Inside `${…}` the lexer returns to the normal mode and tracks brace depth
//! so nested braces stay balanced.

use klio_diagnostics::{generated::factories as kf, Diagnostic, DiagnosticSink};
use klio_span::{FileId, Span};
use unicode_xid::UnicodeXID;

#[derive(Debug, Clone, PartialEq)]
pub enum TokenKind {
    // Trivia
    Whitespace,
    Newline,
    LineComment,
    BlockComment,

    // Literals (text-bearing; cooked numeric value is parsed downstream)
    IntLiteral { base: NumBase, suffix: IntSuffix },
    FloatLiteral { suffix: FloatSuffix },
    BoolLiteral(bool),
    NullLiteral,
    CharLiteral(char),

    // String tokens (template-aware)
    StringQuote { triple: bool },
    StringText(String),
    InterpStart,
    InterpEnd,
    ShortInterp(String),

    // Identifiers and keywords
    Ident,
    Keyword(Keyword),

    // Punctuation and operators
    LParen, RParen, LBrace, RBrace, LBracket, RBracket,
    Comma, Semicolon, Colon, ColonColon,
    AtNoWs, AtPostWs, AtPreWs, AtBothWs,
    Dot, DotDot, DotDotLess, Arrow, FatArrow,
    Eq, EqEq, EqEqEq, BangEq, BangEqEq,
    Lt, Le, Gt, Ge,
    Plus, Minus, Star, Slash, Percent,
    PlusEq, MinusEq, StarEq, SlashEq, PercentEq,
    PlusPlus, MinusMinus,
    Amp, AmpAmp, Pipe, PipePipe, BangBang,
    ExclNoWs, ExclWs,
    QuestNoWs, QuestWs, QuestionDot, QuestionColon,

    // Reserved / shebang
    Reserved,
    DoubleSemicolon,
    Hash,
    ShebangLine,

    Unknown,
    Eof,
}

impl TokenKind {
    #[must_use]
    pub fn is_at(&self) -> bool {
        matches!(self, TokenKind::AtNoWs | TokenKind::AtPostWs | TokenKind::AtPreWs | TokenKind::AtBothWs)
    }
    #[must_use]
    pub fn is_question(&self) -> bool {
        matches!(self, TokenKind::QuestNoWs | TokenKind::QuestWs)
    }
    #[must_use]
    pub fn is_bang(&self) -> bool {
        matches!(self, TokenKind::ExclNoWs | TokenKind::ExclWs)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NumBase {
    Decimal,
    Hex,
    Binary,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IntSuffix {
    None,
    Long,
    UInt,
    ULong,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FloatSuffix {
    None, // Double
    Float,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Keyword {
    // Hard keywords (spec §1.4.1)
    As, Break, Class, Continue, Do, Else, For, Fun, If, In, Interface, Is,
    Object, Package, Return, Super, This, Throw, Try, Typealias, Typeof,
    Val, Var, When, While, Import,
}

impl Keyword {
    #[must_use]
    pub fn from_ident(s: &str) -> Option<Self> {
        Some(match s {
            "as" => Self::As,
            "break" => Self::Break,
            "class" => Self::Class,
            "continue" => Self::Continue,
            "do" => Self::Do,
            "else" => Self::Else,
            "for" => Self::For,
            "fun" => Self::Fun,
            "if" => Self::If,
            "in" => Self::In,
            "interface" => Self::Interface,
            "is" => Self::Is,
            "object" => Self::Object,
            "package" => Self::Package,
            "return" => Self::Return,
            "super" => Self::Super,
            "this" => Self::This,
            "throw" => Self::Throw,
            "try" => Self::Try,
            "typealias" => Self::Typealias,
            "typeof" => Self::Typeof,
            "val" => Self::Val,
            "var" => Self::Var,
            "when" => Self::When,
            "while" => Self::While,
            "import" => Self::Import,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone)]
pub struct Token {
    pub kind: TokenKind,
    pub span: Span,
}

#[derive(Debug)]
pub struct LexResult {
    pub tokens: Vec<Token>,
    pub diagnostics: DiagnosticSink,
}

#[derive(Debug, Clone, Copy)]
enum Mode {
    Normal,
    StringRegular,
    StringRaw,
    Interp { brace_depth: u32 },
}

pub struct Lexer<'src> {
    file: FileId,
    src: &'src str,
    pos: u32,
    modes: Vec<Mode>,
    diagnostics: DiagnosticSink,
    ws_before: bool,
    nl_before: bool,
}

impl<'src> Lexer<'src> {
    #[must_use]
    pub fn new(file: FileId, src: &'src str) -> Self {
        Self {
            file,
            src,
            pos: 0,
            modes: vec![Mode::Normal],
            diagnostics: DiagnosticSink::new(),
            ws_before: false,
            nl_before: false,
        }
    }

    pub fn tokenize(mut self) -> LexResult {
        let mut tokens = Vec::new();
        loop {
            match self.current_mode() {
                Mode::Normal | Mode::Interp { .. } => {
                    if let Some(tok) = self.next_normal_token(&mut tokens) {
                        match tok.kind {
                            TokenKind::Whitespace
                            | TokenKind::LineComment
                            | TokenKind::BlockComment
                            | TokenKind::ShebangLine => {
                                self.ws_before = true;
                            }
                            TokenKind::Newline => {
                                self.ws_before = true;
                                self.nl_before = true;
                                tokens.push(tok);
                            }
                            TokenKind::Eof => {
                                tokens.push(tok);
                                break;
                            }
                            _ => {
                                tokens.push(tok);
                                self.ws_before = false;
                                self.nl_before = false;
                            }
                        }
                    }
                }
                Mode::StringRegular => {
                    self.lex_string_body(&mut tokens, false);
                    self.ws_before = false;
                    self.nl_before = false;
                }
                Mode::StringRaw => {
                    self.lex_string_body(&mut tokens, true);
                    self.ws_before = false;
                    self.nl_before = false;
                }
            }
        }
        LexResult { tokens, diagnostics: self.diagnostics }
    }

    fn current_mode(&self) -> Mode {
        *self.modes.last().expect("mode stack never empties")
    }

    fn peek_byte(&self, off: usize) -> Option<u8> {
        self.src.as_bytes().get(self.pos as usize + off).copied()
    }

    fn peek_char(&self) -> Option<char> {
        self.src[self.pos as usize..].chars().next()
    }

    fn bump_char(&mut self) -> Option<char> {
        let c = self.peek_char()?;
        self.pos += c.len_utf8() as u32;
        Some(c)
    }

    fn span(&self, start: u32) -> Span {
        Span::new(self.file, start, self.pos)
    }

    fn slice(&self, start: u32) -> &str {
        &self.src[start as usize..self.pos as usize]
    }

    // ---------- normal mode ----------

    fn next_normal_token(&mut self, _tokens: &mut Vec<Token>) -> Option<Token> {
        let start = self.pos;
        let Some(b) = self.peek_byte(0) else {
            return Some(Token { kind: TokenKind::Eof, span: self.span(start) });
        };

        // Shebang line at file position 0.
        if start == 0 && b == b'#' && self.peek_byte(1) == Some(b'!') {
            while let Some(c) = self.peek_byte(0) {
                if c == b'\n' { break; }
                self.pos += 1;
            }
            return Some(Token { kind: TokenKind::ShebangLine, span: self.span(start) });
        }

        // Trivia.
        if matches!(b, b' ' | b'\t' | b'\r') {
            while matches!(self.peek_byte(0), Some(b' ' | b'\t' | b'\r')) {
                self.pos += 1;
            }
            return Some(Token { kind: TokenKind::Whitespace, span: self.span(start) });
        }
        if b == b'\n' {
            self.pos += 1;
            return Some(Token { kind: TokenKind::Newline, span: self.span(start) });
        }
        if b == b'/' && self.peek_byte(1) == Some(b'/') {
            while let Some(c) = self.peek_byte(0) {
                if c == b'\n' { break; }
                self.pos += 1;
            }
            return Some(Token { kind: TokenKind::LineComment, span: self.span(start) });
        }
        if b == b'/' && self.peek_byte(1) == Some(b'*') {
            self.pos += 2;
            let mut depth: u32 = 1;
            while depth > 0 {
                match (self.peek_byte(0), self.peek_byte(1)) {
                    (Some(b'/'), Some(b'*')) => { self.pos += 2; depth += 1; }
                    (Some(b'*'), Some(b'/')) => { self.pos += 2; depth -= 1; }
                    (Some(_), _) => { self.bump_char(); }
                    (None, _) => {
                        self.diagnostics.emit(
                            Diagnostic::error("unterminated block comment", self.span(start))
                                .with_code("E0020"),
                        );
                        break;
                    }
                }
            }
            return Some(Token { kind: TokenKind::BlockComment, span: self.span(start) });
        }

        // Strings.
        if b == b'"' {
            // triple-quoted raw string?
            if self.peek_byte(1) == Some(b'"') && self.peek_byte(2) == Some(b'"') {
                self.pos += 3;
                self.modes.push(Mode::StringRaw);
                return Some(Token { kind: TokenKind::StringQuote { triple: true }, span: self.span(start) });
            }
            self.pos += 1;
            self.modes.push(Mode::StringRegular);
            return Some(Token { kind: TokenKind::StringQuote { triple: false }, span: self.span(start) });
        }

        // Char literal.
        if b == b'\'' {
            return Some(self.lex_char_literal(start));
        }

        // Interp mode: track braces so a closing `}` can leave the template.
        if let Mode::Interp { brace_depth } = self.current_mode() {
            if b == b'}' && brace_depth == 0 {
                self.pos += 1;
                self.modes.pop();
                return Some(Token { kind: TokenKind::InterpEnd, span: self.span(start) });
            }
            if b == b'{' {
                self.bump_interp_brace(1);
            } else if b == b'}' {
                self.bump_interp_brace(-1);
            }
        }

        // Numbers.
        if b.is_ascii_digit() {
            return Some(self.lex_number(start));
        }

        // Punctuation / operators.
        if let Some(tok) = self.lex_punct(start) {
            return Some(tok);
        }

        // Backtick-escaped identifier: `…` admits any character except backtick,
        // newline, CR, or NUL. The identifier carries the backticks in its span;
        // the parser strips them when materializing names.
        if b == b'`' {
            return Some(self.lex_backtick_ident(start));
        }

        // Identifiers / keywords. Unicode XID for the start; ASCII fast path first.
        if is_ident_start_byte(b) || self.peek_char().is_some_and(UnicodeXID::is_xid_start) {
            return Some(self.lex_ident_or_keyword(start));
        }

        // Unknown.
        self.bump_char();
        self.diagnostics.emit(
            Diagnostic::error(format!("unexpected character `{}`", self.slice(start)), self.span(start))
                .with_code("E0021"),
        );
        Some(Token { kind: TokenKind::Unknown, span: self.span(start) })
    }

    fn bump_interp_brace(&mut self, delta: i32) {
        if let Some(Mode::Interp { brace_depth }) = self.modes.last_mut() {
            if delta > 0 {
                *brace_depth = brace_depth.saturating_add(delta as u32);
            } else {
                *brace_depth = brace_depth.saturating_sub((-delta) as u32);
            }
        }
    }

    // ---------- identifiers ----------

    fn lex_backtick_ident(&mut self, start: u32) -> Token {
        // Consume opening backtick.
        self.bump_char();
        let mut closed = false;
        while let Some(c) = self.peek_char() {
            if c == '`' {
                self.bump_char();
                closed = true;
                break;
            }
            if c == '\n' || c == '\r' || c == '\0' {
                break;
            }
            self.bump_char();
        }
        let span = self.span(start);
        if !closed {
            self.diagnostics.emit(
                Diagnostic::error("unterminated backtick identifier", span).with_code("E0022"),
            );
        }
        Token { kind: TokenKind::Ident, span }
    }

    fn lex_ident_or_keyword(&mut self, start: u32) -> Token {
        // Consume one start char.
        self.bump_char();
        while let Some(c) = self.peek_char() {
            if is_ident_cont_byte(c as u32) || UnicodeXID::is_xid_continue(c) {
                self.bump_char();
            } else {
                break;
            }
        }
        let text = self.slice(start);
        let kind = match text {
            "true" => TokenKind::BoolLiteral(true),
            "false" => TokenKind::BoolLiteral(false),
            "null" => TokenKind::NullLiteral,
            _ => Keyword::from_ident(text).map_or(TokenKind::Ident, TokenKind::Keyword),
        };
        Token { kind, span: self.span(start) }
    }

    // ---------- numbers ----------

    fn lex_number(&mut self, start: u32) -> Token {
        // Hex / binary?
        if self.peek_byte(0) == Some(b'0') {
            match self.peek_byte(1) {
                Some(b'x' | b'X') => return self.lex_radix_int(start, NumBase::Hex),
                Some(b'b' | b'B') => return self.lex_radix_int(start, NumBase::Binary),
                _ => {}
            }
        }

        // Decimal integer or float.
        self.eat_digits_with_underscores(10);

        let mut is_float = false;
        // Fractional part — only if followed by a digit (so `1.toString()` still works).
        if self.peek_byte(0) == Some(b'.')
            && self.peek_byte(1).is_some_and(|b| b.is_ascii_digit())
        {
            is_float = true;
            self.pos += 1; // consume `.`
            self.eat_digits_with_underscores(10);
        }
        // Exponent.
        if matches!(self.peek_byte(0), Some(b'e' | b'E')) {
            is_float = true;
            self.pos += 1;
            if matches!(self.peek_byte(0), Some(b'+' | b'-')) {
                self.pos += 1;
            }
            let exp_start = self.pos;
            self.eat_digits_with_underscores(10);
            if self.pos == exp_start {
                self.diagnostics.emit(
                    Diagnostic::error("missing digits in exponent", self.span(start))
                        .with_code("E0030"),
                );
            }
        }

        if is_float {
            let suffix = match self.peek_byte(0) {
                Some(b'f' | b'F') => { self.pos += 1; FloatSuffix::Float }
                _ => FloatSuffix::None,
            };
            Token { kind: TokenKind::FloatLiteral { suffix }, span: self.span(start) }
        } else {
            let suffix = self.lex_int_suffix();
            Token { kind: TokenKind::IntLiteral { base: NumBase::Decimal, suffix }, span: self.span(start) }
        }
    }

    fn lex_radix_int(&mut self, start: u32, base: NumBase) -> Token {
        self.pos += 2; // 0x / 0b
        let digits_start = self.pos;
        let radix = match base { NumBase::Hex => 16, NumBase::Binary => 2, NumBase::Decimal => 10 };
        self.eat_digits_with_underscores(radix);
        if self.pos == digits_start {
            self.diagnostics.emit(
                Diagnostic::error("missing digits after radix prefix", self.span(start))
                    .with_code("E0031"),
            );
        }
        let suffix = self.lex_int_suffix();
        Token { kind: TokenKind::IntLiteral { base, suffix }, span: self.span(start) }
    }

    fn lex_int_suffix(&mut self) -> IntSuffix {
        match self.peek_byte(0) {
            Some(b'L') => { self.pos += 1; IntSuffix::Long }
            Some(b'u' | b'U') => {
                self.pos += 1;
                if self.peek_byte(0) == Some(b'L') {
                    self.pos += 1;
                    IntSuffix::ULong
                } else {
                    IntSuffix::UInt
                }
            }
            _ => IntSuffix::None,
        }
    }

    fn eat_digits_with_underscores(&mut self, radix: u32) {
        while let Some(b) = self.peek_byte(0) {
            if b == b'_' || (b as char).is_digit(radix) {
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    // ---------- char literal ----------

    fn lex_char_literal(&mut self, start: u32) -> Token {
        self.pos += 1; // opening '
        let ch = match self.peek_byte(0) {
            Some(b'\\') => self.lex_escape(start),
            Some(b'\'') | None => {
                self.diagnostics.emit(
                    Diagnostic::error("empty character literal", self.span(start))
                        .with_code("E0040").with_factory(&kf::EMPTY_CHARACTER_LITERAL),
                );
                '\u{FFFD}'
            }
            Some(b'\n') => {
                self.diagnostics.emit(
                    Diagnostic::error("character literal cannot contain newline", self.span(start))
                        .with_code("E0041").with_factory(&kf::INCORRECT_CHARACTER_LITERAL),
                );
                '\u{FFFD}'
            }
            Some(_) => self.bump_char().unwrap_or('\u{FFFD}'),
        };
        if self.peek_byte(0) == Some(b'\'') {
            self.pos += 1;
        } else {
            self.diagnostics.emit(
                Diagnostic::error("unterminated character literal", self.span(start))
                    .with_code("E0042").with_factory(&kf::INCORRECT_CHARACTER_LITERAL),
            );
        }
        Token { kind: TokenKind::CharLiteral(ch), span: self.span(start) }
    }

    fn lex_escape(&mut self, diag_anchor: u32) -> char {
        let esc_start = self.pos;
        self.pos += 1; // backslash
        let Some(b) = self.peek_byte(0) else {
            self.diagnostics.emit(
                Diagnostic::error("trailing backslash", self.span(diag_anchor)).with_code("E0050").with_factory(&kf::ILLEGAL_ESCAPE),
            );
            return '\u{FFFD}';
        };
        self.pos += 1;
        match b {
            b'n' => '\n',
            b't' => '\t',
            b'r' => '\r',
            b'b' => '\u{0008}',
            b'\\' => '\\',
            b'\'' => '\'',
            b'"' => '"',
            b'$' => '$',
            b'0' => '\0',
            b'u' => self.lex_unicode_escape(esc_start),
            _ => {
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!("invalid escape sequence `\\{}`", b as char),
                        Span::new(self.file, esc_start, self.pos),
                    )
                    .with_code("E0051").with_factory(&kf::ILLEGAL_ESCAPE),
                );
                '\u{FFFD}'
            }
        }
    }

    fn lex_unicode_escape(&mut self, esc_start: u32) -> char {
        let mut value: u32 = 0;
        let mut count = 0;
        while count < 4 {
            match self.peek_byte(0) {
                Some(b) if (b as char).is_ascii_hexdigit() => {
                    value = (value << 4) | u32::from((b as char).to_digit(16).unwrap());
                    self.pos += 1;
                    count += 1;
                }
                _ => break,
            }
        }
        if count != 4 {
            self.diagnostics.emit(
                Diagnostic::error(
                    "expected 4 hex digits after `\\u`",
                    Span::new(self.file, esc_start, self.pos),
                )
                .with_code("E0052").with_factory(&kf::ILLEGAL_ESCAPE),
            );
            return '\u{FFFD}';
        }
        char::from_u32(value).unwrap_or_else(|| {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!("invalid unicode scalar value U+{value:04X}"),
                    Span::new(self.file, esc_start, self.pos),
                )
                .with_code("E0053").with_factory(&kf::ILLEGAL_ESCAPE),
            );
            '\u{FFFD}'
        })
    }

    // ---------- punctuation ----------

    fn lex_punct(&mut self, start: u32) -> Option<Token> {
        let b0 = self.peek_byte(0)?;
        let b1 = self.peek_byte(1);
        let b2 = self.peek_byte(2);

        // 3-char ops first.
        let three = match (b0, b1, b2) {
            (b'=', Some(b'='), Some(b'=')) => Some(TokenKind::EqEqEq),
            (b'!', Some(b'='), Some(b'=')) => Some(TokenKind::BangEqEq),
            (b'.', Some(b'.'), Some(b'<')) => Some(TokenKind::DotDotLess),
            (b'.', Some(b'.'), Some(b'.')) => Some(TokenKind::Reserved),
            _ => None,
        };
        if let Some(k) = three {
            self.pos += 3;
            return Some(Token { kind: k, span: self.span(start) });
        }

        let two = match (b0, b1) {
            (b'=', Some(b'=')) => Some(TokenKind::EqEq),
            (b'!', Some(b'=')) => Some(TokenKind::BangEq),
            (b'<', Some(b'=')) => Some(TokenKind::Le),
            (b'>', Some(b'=')) => Some(TokenKind::Ge),
            (b'&', Some(b'&')) => Some(TokenKind::AmpAmp),
            (b'|', Some(b'|')) => Some(TokenKind::PipePipe),
            (b'+', Some(b'+')) => Some(TokenKind::PlusPlus),
            (b'-', Some(b'-')) => Some(TokenKind::MinusMinus),
            (b'+', Some(b'=')) => Some(TokenKind::PlusEq),
            (b'-', Some(b'=')) => Some(TokenKind::MinusEq),
            (b'*', Some(b'=')) => Some(TokenKind::StarEq),
            (b'/', Some(b'=')) => Some(TokenKind::SlashEq),
            (b'%', Some(b'=')) => Some(TokenKind::PercentEq),
            (b'-', Some(b'>')) => Some(TokenKind::Arrow),
            (b'=', Some(b'>')) => Some(TokenKind::FatArrow),
            (b'.', Some(b'.')) => Some(TokenKind::DotDot),
            (b':', Some(b':')) => Some(TokenKind::ColonColon),
            (b'?', Some(b'.')) => Some(TokenKind::QuestionDot),
            (b'?', Some(b':')) => Some(TokenKind::QuestionColon),
            (b'!', Some(b'!')) => Some(TokenKind::BangBang),
            (b';', Some(b';')) => Some(TokenKind::DoubleSemicolon),
            _ => None,
        };
        if let Some(k) = two {
            self.pos += 2;
            return Some(Token { kind: k, span: self.span(start) });
        }

        // WS-sensitive single-char tokens.
        if b0 == b'@' {
            self.pos += 1;
            let pre = self.ws_before || self.nl_before;
            let post = self.is_at_ws_after();
            let kind = match (pre, post) {
                (false, false) => TokenKind::AtNoWs,
                (false, true) => TokenKind::AtPostWs,
                (true, false) => TokenKind::AtPreWs,
                (true, true) => TokenKind::AtBothWs,
            };
            return Some(Token { kind, span: self.span(start) });
        }
        if b0 == b'?' {
            self.pos += 1;
            let kind = if self.is_quest_excl_ws_after() { TokenKind::QuestWs } else { TokenKind::QuestNoWs };
            return Some(Token { kind, span: self.span(start) });
        }
        if b0 == b'!' {
            self.pos += 1;
            let kind = if self.is_quest_excl_ws_after() { TokenKind::ExclWs } else { TokenKind::ExclNoWs };
            return Some(Token { kind, span: self.span(start) });
        }

        let one = match b0 {
            b'(' => TokenKind::LParen,
            b')' => TokenKind::RParen,
            b'{' => TokenKind::LBrace,
            b'}' => TokenKind::RBrace,
            b'[' => TokenKind::LBracket,
            b']' => TokenKind::RBracket,
            b',' => TokenKind::Comma,
            b';' => TokenKind::Semicolon,
            b':' => TokenKind::Colon,
            b'.' => TokenKind::Dot,
            b'=' => TokenKind::Eq,
            b'<' => TokenKind::Lt,
            b'>' => TokenKind::Gt,
            b'+' => TokenKind::Plus,
            b'-' => TokenKind::Minus,
            b'*' => TokenKind::Star,
            b'/' => TokenKind::Slash,
            b'%' => TokenKind::Percent,
            b'&' => TokenKind::Amp,
            b'|' => TokenKind::Pipe,
            b'#' => TokenKind::Hash,
            _ => return None,
        };
        self.pos += 1;
        Some(Token { kind: one, span: self.span(start) })
    }

    fn is_at_ws_after(&self) -> bool {
        match self.peek_byte(0) {
            None => true,
            Some(b' ' | b'\t' | b'\r' | b'\n') => true,
            Some(b'/') => matches!(self.peek_byte(1), Some(b'/' | b'*')),
            _ => false,
        }
    }

    fn is_quest_excl_ws_after(&self) -> bool {
        match self.peek_byte(0) {
            None => true,
            Some(b' ' | b'\t' | b'\r') => true,
            Some(b'/') => matches!(self.peek_byte(1), Some(b'/' | b'*')),
            _ => false,
        }
    }

    // ---------- strings ----------

    fn lex_string_body(&mut self, tokens: &mut Vec<Token>, raw: bool) {
        let mut text = String::new();
        let segment_start = self.pos;

        loop {
            let pos = self.pos;
            let Some(b) = self.peek_byte(0) else {
                if !text.is_empty() {
                    tokens.push(Token {
                        kind: TokenKind::StringText(std::mem::take(&mut text)),
                        span: Span::new(self.file, segment_start, self.pos),
                    });
                }
                self.diagnostics.emit(
                    Diagnostic::error("unterminated string literal", self.span(pos))
                        .with_code("E0060"),
                );
                self.modes.pop();
                return;
            };

            // Closing quote(s).
            if b == b'"' {
                if raw {
                    if self.peek_byte(1) == Some(b'"') && self.peek_byte(2) == Some(b'"') {
                        if !text.is_empty() {
                            tokens.push(Token {
                                kind: TokenKind::StringText(std::mem::take(&mut text)),
                                span: Span::new(self.file, segment_start, self.pos),
                            });
                        }
                        self.pos += 3;
                        tokens.push(Token {
                            kind: TokenKind::StringQuote { triple: true },
                            span: Span::new(self.file, self.pos - 3, self.pos),
                        });
                        self.modes.pop();
                        return;
                    }
                    text.push('"');
                    self.pos += 1;
                    continue;
                } else {
                    if !text.is_empty() {
                        tokens.push(Token {
                            kind: TokenKind::StringText(std::mem::take(&mut text)),
                            span: Span::new(self.file, segment_start, self.pos),
                        });
                    }
                    self.pos += 1;
                    tokens.push(Token {
                        kind: TokenKind::StringQuote { triple: false },
                        span: Span::new(self.file, self.pos - 1, self.pos),
                    });
                    self.modes.pop();
                    return;
                }
            }

            // Newline: error in regular strings, allowed in raw.
            if b == b'\n' && !raw {
                if !text.is_empty() {
                    tokens.push(Token {
                        kind: TokenKind::StringText(std::mem::take(&mut text)),
                        span: Span::new(self.file, segment_start, self.pos),
                    });
                }
                self.diagnostics.emit(
                    Diagnostic::error("newline in regular string literal", self.span(pos))
                        .with_code("E0061"),
                );
                self.modes.pop();
                return;
            }

            // Escapes (regular strings only; raw strings keep `\` verbatim).
            if b == b'\\' && !raw {
                let ch = self.lex_escape(pos);
                text.push(ch);
                continue;
            }

            // Templates.
            if b == b'$' {
                // `${expr}` form.
                if self.peek_byte(1) == Some(b'{') {
                    if !text.is_empty() {
                        tokens.push(Token {
                            kind: TokenKind::StringText(std::mem::take(&mut text)),
                            span: Span::new(self.file, segment_start, self.pos),
                        });
                    }
                    let interp_start = self.pos;
                    self.pos += 2;
                    tokens.push(Token {
                        kind: TokenKind::InterpStart,
                        span: Span::new(self.file, interp_start, self.pos),
                    });
                    self.modes.push(Mode::Interp { brace_depth: 0 });
                    return;
                }
                // `$ident` short form.
                if self
                    .peek_byte(1)
                    .map(|c| is_ident_start_byte(c))
                    .unwrap_or(false)
                {
                    if !text.is_empty() {
                        tokens.push(Token {
                            kind: TokenKind::StringText(std::mem::take(&mut text)),
                            span: Span::new(self.file, segment_start, self.pos),
                        });
                    }
                    let short_start = self.pos;
                    self.pos += 1; // consume `$`
                    let ident_start = self.pos;
                    while matches!(self.peek_byte(0), Some(c) if is_ident_cont_byte(c as u32)) {
                        self.pos += 1;
                    }
                    let name = self.src[ident_start as usize..self.pos as usize].to_string();
                    tokens.push(Token {
                        kind: TokenKind::ShortInterp(name),
                        span: Span::new(self.file, short_start, self.pos),
                    });
                    return;
                }
                // Lone `$` — literal dollar sign.
                text.push('$');
                self.pos += 1;
                continue;
            }

            // Plain char.
            let c = self.bump_char().unwrap();
            text.push(c);
        }
    }
}

fn is_ident_start_byte(b: u8) -> bool {
    b.is_ascii_alphabetic() || b == b'_'
}

fn is_ident_cont_byte(b: u32) -> bool {
    matches!(b, 0x30..=0x39 | 0x41..=0x5A | 0x61..=0x7A | 0x5F)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kinds(src: &str) -> Vec<TokenKind> {
        let r = Lexer::new(FileId(0), src).tokenize();
        r.tokens.into_iter().map(|t| t.kind).collect()
    }

    fn lex(src: &str) -> LexResult {
        Lexer::new(FileId(0), src).tokenize()
    }

    #[test]
    fn empty_input_emits_eof() {
        assert_eq!(kinds(""), vec![TokenKind::Eof]);
    }

    #[test]
    fn fun_main_println_one_plus_one() {
        let r = lex("fun main() { println(1 + 1) }");
        assert!(!r.diagnostics.has_errors());
        let drop_trivia: Vec<_> = r
            .tokens
            .into_iter()
            .filter(|t| !matches!(
                t.kind,
                TokenKind::Whitespace | TokenKind::Newline | TokenKind::LineComment | TokenKind::BlockComment
            ))
            .map(|t| t.kind)
            .collect();
        use TokenKind::*;
        assert!(matches!(drop_trivia[0], Keyword(self::Keyword::Fun)));
        assert!(matches!(drop_trivia[1], Ident));
        assert!(matches!(drop_trivia[7], IntLiteral { .. }));
        assert!(matches!(drop_trivia[8], Plus));
        assert!(matches!(drop_trivia[9], IntLiteral { .. }));
    }

    #[test]
    fn nested_block_comment() {
        let r = lex("/* outer /* inner */ still outer */ 1");
        assert!(!r.diagnostics.has_errors());
        let last = r.tokens.iter().rev().find(|t| !matches!(t.kind,
            TokenKind::Whitespace | TokenKind::BlockComment | TokenKind::Eof));
        assert!(matches!(last.unwrap().kind, TokenKind::IntLiteral { .. }));
    }

    #[test]
    fn unterminated_block_comment_diag() {
        let r = lex("/* never closes");
        assert!(r.diagnostics.has_errors());
    }

    #[test]
    fn numeric_suffixes_and_bases() {
        let k = kinds("0xFF 0b1010 1_000 42L 7u 9UL 3.14 1.5e-3 2.0f");
        let intish: Vec<_> = k
            .iter()
            .filter(|t| matches!(t, TokenKind::IntLiteral { .. } | TokenKind::FloatLiteral { .. }))
            .collect();
        assert_eq!(intish.len(), 9);
        // Spot-check a few specifics.
        assert!(matches!(intish[0], TokenKind::IntLiteral { base: NumBase::Hex, suffix: IntSuffix::None }));
        assert!(matches!(intish[1], TokenKind::IntLiteral { base: NumBase::Binary, suffix: IntSuffix::None }));
        assert!(matches!(intish[3], TokenKind::IntLiteral { base: NumBase::Decimal, suffix: IntSuffix::Long }));
        assert!(matches!(intish[4], TokenKind::IntLiteral { base: NumBase::Decimal, suffix: IntSuffix::UInt }));
        assert!(matches!(intish[5], TokenKind::IntLiteral { base: NumBase::Decimal, suffix: IntSuffix::ULong }));
        assert!(matches!(intish[6], TokenKind::FloatLiteral { suffix: FloatSuffix::None }));
        assert!(matches!(intish[7], TokenKind::FloatLiteral { suffix: FloatSuffix::None }));
        assert!(matches!(intish[8], TokenKind::FloatLiteral { suffix: FloatSuffix::Float }));
    }

    #[test]
    fn ops_lex_greedily() {
        use TokenKind::*;
        let k: Vec<_> = kinds("== === != !== <= >= && || ++ -- += -> ?. ?: !! .. ..< ::");
        let non_trivia: Vec<_> = k.into_iter().filter(|t| !matches!(t,
            Whitespace | Newline | Eof)).collect();
        assert_eq!(
            non_trivia,
            vec![
                EqEq, EqEqEq, BangEq, BangEqEq, Le, Ge, AmpAmp, PipePipe,
                PlusPlus, MinusMinus, PlusEq, Arrow, QuestionDot, QuestionColon,
                BangBang, DotDot, DotDotLess, ColonColon,
            ]
        );
    }

    #[test]
    fn unicode_identifier_lexes() {
        let r = lex("val π = 3");
        assert!(!r.diagnostics.has_errors());
        let names: Vec<_> = r.tokens.iter().filter(|t| matches!(t.kind, TokenKind::Ident)).collect();
        assert_eq!(names.len(), 1);
    }

    #[test]
    fn char_literal_with_escape() {
        let r = lex(r"'\n'");
        assert!(!r.diagnostics.has_errors());
        assert!(matches!(r.tokens[0].kind, TokenKind::CharLiteral('\n')));
    }

    #[test]
    fn char_literal_unicode_escape() {
        let r = lex(r"'é'"); // é
        assert!(!r.diagnostics.has_errors());
        assert!(matches!(r.tokens[0].kind, TokenKind::CharLiteral('\u{00e9}')));
    }

    #[test]
    fn invalid_escape_diagnostic() {
        let r = lex(r#""bad \q escape""#);
        assert!(r.diagnostics.has_errors());
    }

    #[test]
    fn regular_string_template_short_and_full() {
        let r = lex(r#""hi $name, age=${age + 1}!""#);
        assert!(!r.diagnostics.has_errors());
        let kinds: Vec<_> = r.tokens.iter().map(|t| &t.kind).collect();
        // expected: " hi  $name , age=  ${  age + 1  }  ! "
        let mut iter = kinds.into_iter();
        assert!(matches!(iter.next().unwrap(), TokenKind::StringQuote { triple: false }));
        assert!(matches!(iter.next().unwrap(), TokenKind::StringText(s) if s == "hi "));
        assert!(matches!(iter.next().unwrap(), TokenKind::ShortInterp(s) if s == "name"));
        assert!(matches!(iter.next().unwrap(), TokenKind::StringText(s) if s == ", age="));
        assert!(matches!(iter.next().unwrap(), TokenKind::InterpStart));
        assert!(matches!(iter.next().unwrap(), TokenKind::Ident));
        assert!(matches!(iter.next().unwrap(), TokenKind::Plus));
        assert!(matches!(iter.next().unwrap(), TokenKind::IntLiteral { .. }));
        assert!(matches!(iter.next().unwrap(), TokenKind::InterpEnd));
        assert!(matches!(iter.next().unwrap(), TokenKind::StringText(s) if s == "!"));
        assert!(matches!(iter.next().unwrap(), TokenKind::StringQuote { triple: false }));
    }

    #[test]
    fn interp_with_nested_braces() {
        // Inner `{}` inside `${...}` must not close the template.
        let r = lex(r#""${ if (b) { 1 } else { 2 } }""#);
        assert!(!r.diagnostics.has_errors());
        let interp_ends = r.tokens.iter().filter(|t| matches!(t.kind, TokenKind::InterpEnd)).count();
        assert_eq!(interp_ends, 1);
        let starts = r.tokens.iter().filter(|t| matches!(t.kind, TokenKind::InterpStart)).count();
        assert_eq!(starts, 1);
    }

    #[test]
    fn triple_quoted_raw_string_keeps_backslashes_and_newlines() {
        let src = "\"\"\"raw \\n\nliteral $x\"\"\"";
        let r = lex(src);
        assert!(!r.diagnostics.has_errors());
        let texts: Vec<_> = r.tokens.iter().filter_map(|t| match &t.kind {
            TokenKind::StringText(s) => Some(s.as_str()),
            _ => None,
        }).collect();
        // Backslash-n stays as two characters; newline literal is preserved.
        assert_eq!(texts, vec!["raw \\n\nliteral "]);
        assert!(r.tokens.iter().any(|t| matches!(&t.kind, TokenKind::ShortInterp(s) if s == "x")));
    }

    #[test]
    fn unterminated_string_diag() {
        let r = lex("\"never ends");
        assert!(r.diagnostics.has_errors());
    }

    #[test]
    fn newline_in_regular_string_is_error() {
        let r = lex("\"line1\nline2\"");
        assert!(r.diagnostics.has_errors());
    }

    fn first_non_trivia(src: &str) -> TokenKind {
        let r = lex(src);
        r.tokens
            .into_iter()
            .map(|t| t.kind)
            .find(|k| !matches!(k, TokenKind::Whitespace | TokenKind::Newline | TokenKind::LineComment | TokenKind::BlockComment | TokenKind::ShebangLine))
            .unwrap()
    }

    fn find_kind(src: &str, pred: impl Fn(&TokenKind) -> bool) -> TokenKind {
        let r = lex(src);
        r.tokens.into_iter().map(|t| t.kind).find(|k| pred(k)).unwrap()
    }

    #[test]
    fn at_ws_variants() {
        assert!(matches!(find_kind("@foo", |k| k.is_at()), TokenKind::AtNoWs));
        assert!(matches!(find_kind("@ foo", |k| k.is_at()), TokenKind::AtPostWs));
        assert!(matches!(find_kind("x @foo", |k| k.is_at()), TokenKind::AtPreWs));
        assert!(matches!(find_kind("x @ foo", |k| k.is_at()), TokenKind::AtBothWs));
        assert!(matches!(find_kind("@\nfoo", |k| k.is_at()), TokenKind::AtPostWs));
        assert!(matches!(find_kind("x\n@foo", |k| k.is_at()), TokenKind::AtPreWs));
    }

    #[test]
    fn question_ws_variants() {
        assert!(matches!(find_kind("a?b", |k| k.is_question()), TokenKind::QuestNoWs));
        assert!(matches!(find_kind("a? b", |k| k.is_question()), TokenKind::QuestWs));
        assert!(matches!(find_kind("a?", |k| k.is_question()), TokenKind::QuestWs));
    }

    #[test]
    fn excl_ws_variants() {
        assert!(matches!(find_kind("!a", |k| k.is_bang()), TokenKind::ExclNoWs));
        assert!(matches!(find_kind("! a", |k| k.is_bang()), TokenKind::ExclWs));
    }

    #[test]
    fn as_safe_glue() {
        // `as?` => Keyword(As) directly followed by a Quest* variant with no
        // intervening trivia. Trailing-WS distinguishes QuestNoWs vs QuestWs.
        let r = lex("x as? Int");
        let kinds: Vec<_> = r.tokens.iter().map(|t| t.kind.clone()).collect();
        let i = kinds.iter().position(|k| matches!(k, TokenKind::Keyword(Keyword::As))).unwrap();
        assert!(kinds[i + 1].is_question());

        let r = lex("x as?Int");
        let kinds: Vec<_> = r.tokens.iter().map(|t| t.kind.clone()).collect();
        let i = kinds.iter().position(|k| matches!(k, TokenKind::Keyword(Keyword::As))).unwrap();
        assert!(matches!(kinds[i + 1], TokenKind::QuestNoWs));
    }

    #[test]
    fn bang_is_emits_excl_no_ws_before_is() {
        let r = lex("x !is Int");
        let non_trivia: Vec<_> = r.tokens.iter().filter(|t| !matches!(t.kind, TokenKind::Whitespace | TokenKind::Newline | TokenKind::Eof)).map(|t| t.kind.clone()).collect();
        let i = non_trivia.iter().position(|k| k.is_bang()).unwrap();
        assert!(matches!(non_trivia[i], TokenKind::ExclNoWs));
        assert!(matches!(non_trivia[i + 1], TokenKind::Keyword(Keyword::Is)));
    }

    #[test]
    fn reserved_three_dots() {
        assert!(matches!(first_non_trivia("..."), TokenKind::Reserved));
    }

    #[test]
    fn double_semicolon() {
        assert!(matches!(first_non_trivia(";;"), TokenKind::DoubleSemicolon));
    }

    #[test]
    fn hash_token() {
        assert!(matches!(first_non_trivia("#"), TokenKind::Hash));
    }

    #[test]
    fn shebang_consumed_as_trivia_at_file_start() {
        let r = lex("#!/usr/bin/env kotlin\nfun main(){}");
        let first = r.tokens.iter().find(|t| !matches!(t.kind, TokenKind::Whitespace | TokenKind::Newline | TokenKind::LineComment | TokenKind::BlockComment | TokenKind::ShebangLine)).unwrap();
        assert!(matches!(first.kind, TokenKind::Keyword(Keyword::Fun)));
    }

    #[test]
    fn shebang_not_at_start_is_hash_then_excl() {
        let r = lex("foo #!bar");
        let kinds: Vec<_> = r.tokens.iter().map(|t| t.kind.clone()).collect();
        assert!(kinds.iter().any(|k| matches!(k, TokenKind::Hash)));
        assert!(kinds.iter().any(|k| k.is_bang()));
    }

    #[test]
    fn this_at_label_emits_at_no_ws() {
        let r = lex("this@Outer");
        let kinds: Vec<_> = r.tokens.iter().map(|t| t.kind.clone()).collect();
        let i = kinds.iter().position(|k| matches!(k, TokenKind::Keyword(Keyword::This))).unwrap();
        assert!(matches!(kinds[i + 1], TokenKind::AtNoWs));
        assert!(matches!(kinds[i + 2], TokenKind::Ident));
    }

    #[test]
    fn line_comment_is_trivia() {
        assert_eq!(
            kinds("// hi\n1")
                .into_iter()
                .filter(|t| !matches!(t, TokenKind::Whitespace | TokenKind::Newline | TokenKind::LineComment))
                .collect::<Vec<_>>(),
            vec![TokenKind::IntLiteral { base: NumBase::Decimal, suffix: IntSuffix::None }, TokenKind::Eof],
        );
    }
}
