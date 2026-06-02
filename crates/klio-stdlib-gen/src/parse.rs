//! Declaration-only Kotlin parser.
//!
//! Approach: tokenize the source into a coarse stream that drops comments and
//! string / char literal contents, then walk the token stream looking for
//! declaration headers at "interesting" brace depths. We track:
//!
//! * package declaration (single per file).
//! * top-level decls (brace depth 0).
//! * decls inside class / interface / object bodies (depth 1 relative to that
//!   body, fqn-prefixed with the enclosing class name).
//!
//! Anonymous-object bodies, function bodies, and property initializers are
//! treated as opaque brace groups. We deliberately do not descend into them.

use std::fmt::Write;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedFile {
    pub package: String,
    pub decls: Vec<Decl>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Decl {
    pub kind: DeclKind,
    pub name: String,
    /// `kotlin.collections.listOf`. For class members:
    /// `kotlin.collections.List.size`.
    pub fqn: String,
    /// Containing simple name (class) if any. None for top-level.
    pub parent: Option<String>,
    /// Extension receiver as it appears in source, e.g. `List<T>`.
    pub receiver: Option<String>,
    /// Modifier bitset (mirrors `klio_stdlib::Modifiers`).
    pub modifiers: u32,
    /// Trimmed single-line signature text.
    pub signature: String,
    /// Parameter names in declaration order. Empty for properties /
    /// classes / etc. The interpreter uses these to reorder named-arg
    /// calls before dispatching.
    pub param_names: Vec<String>,
    pub line: u32,
    pub column: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeclKind {
    Function,
    Property,
    Class,
    Interface,
    Object,
    TypeAlias,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Visibility {
    Public,
    Internal,
    Protected,
    Private,
}

// Modifier flag bits (must match `klio_stdlib::Modifiers`).
pub mod modflag {
    pub const PUBLIC: u32 = 1 << 0;
    pub const INTERNAL: u32 = 1 << 1;
    pub const PROTECTED: u32 = 1 << 2;
    pub const PRIVATE: u32 = 1 << 3;
    pub const OPEN: u32 = 1 << 4;
    pub const ABSTRACT: u32 = 1 << 5;
    pub const FINAL: u32 = 1 << 6;
    pub const SEALED: u32 = 1 << 7;
    pub const INLINE: u32 = 1 << 8;
    pub const INFIX: u32 = 1 << 9;
    pub const OPERATOR: u32 = 1 << 10;
    pub const TAILREC: u32 = 1 << 11;
    pub const EXPECT: u32 = 1 << 12;
    pub const ACTUAL: u32 = 1 << 13;
    pub const EXTERNAL: u32 = 1 << 14;
    pub const SUSPEND: u32 = 1 << 15;
    pub const OVERRIDE: u32 = 1 << 16;
    pub const DATA: u32 = 1 << 17;
    pub const VALUE: u32 = 1 << 18;
    pub const ENUM: u32 = 1 << 19;
    pub const ANNOTATION: u32 = 1 << 20;
    pub const COMPANION: u32 = 1 << 21;
    pub const CONST: u32 = 1 << 22;
}

fn modifier_bit(word: &str) -> Option<u32> {
    Some(match word {
        "public" => modflag::PUBLIC,
        "internal" => modflag::INTERNAL,
        "protected" => modflag::PROTECTED,
        "private" => modflag::PRIVATE,
        "open" => modflag::OPEN,
        "abstract" => modflag::ABSTRACT,
        "final" => modflag::FINAL,
        "sealed" => modflag::SEALED,
        "inline" => modflag::INLINE,
        "infix" => modflag::INFIX,
        "operator" => modflag::OPERATOR,
        "tailrec" => modflag::TAILREC,
        "expect" => modflag::EXPECT,
        "actual" => modflag::ACTUAL,
        "external" => modflag::EXTERNAL,
        "suspend" => modflag::SUSPEND,
        "override" => modflag::OVERRIDE,
        "data" => modflag::DATA,
        "value" => modflag::VALUE,
        "enum" => modflag::ENUM,
        "annotation" => modflag::ANNOTATION,
        "companion" => modflag::COMPANION,
        "const" => modflag::CONST,
        _ => return None,
    })
}

/// Strip comments, string contents, and char-literal contents from `src`. We
/// replace removed regions with spaces so byte offsets and line numbers are
/// preserved. Newlines are kept verbatim.
fn scrub(src: &str) -> String {
    let bytes = src.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        // Line comment
        if b == b'/' && i + 1 < bytes.len() && bytes[i + 1] == b'/' {
            while i < bytes.len() && bytes[i] != b'\n' {
                out.push(b' ');
                i += 1;
            }
            continue;
        }
        // Block comment (nested)
        if b == b'/' && i + 1 < bytes.len() && bytes[i + 1] == b'*' {
            let mut depth = 1;
            out.push(b' ');
            out.push(b' ');
            i += 2;
            while i < bytes.len() && depth > 0 {
                if i + 1 < bytes.len() && bytes[i] == b'/' && bytes[i + 1] == b'*' {
                    depth += 1;
                    out.push(b' ');
                    out.push(b' ');
                    i += 2;
                } else if i + 1 < bytes.len() && bytes[i] == b'*' && bytes[i + 1] == b'/' {
                    depth -= 1;
                    out.push(b' ');
                    out.push(b' ');
                    i += 2;
                } else {
                    out.push(if bytes[i] == b'\n' { b'\n' } else { b' ' });
                    i += 1;
                }
            }
            continue;
        }
        // Triple-quoted string
        if b == b'"' && i + 2 < bytes.len() && bytes[i + 1] == b'"' && bytes[i + 2] == b'"' {
            out.push(b'"');
            out.push(b'"');
            out.push(b'"');
            i += 3;
            while i + 2 < bytes.len()
                && !(bytes[i] == b'"' && bytes[i + 1] == b'"' && bytes[i + 2] == b'"')
            {
                out.push(if bytes[i] == b'\n' { b'\n' } else { b' ' });
                i += 1;
            }
            if i + 2 < bytes.len() {
                out.push(b'"');
                out.push(b'"');
                out.push(b'"');
                i += 3;
            }
            continue;
        }
        // Regular string
        if b == b'"' {
            out.push(b'"');
            i += 1;
            while i < bytes.len() && bytes[i] != b'"' {
                if bytes[i] == b'\\' && i + 1 < bytes.len() {
                    out.push(b' ');
                    out.push(b' ');
                    i += 2;
                    continue;
                }
                if bytes[i] == b'\n' {
                    // Unterminated; break to avoid running off.
                    break;
                }
                out.push(b' ');
                i += 1;
            }
            if i < bytes.len() && bytes[i] == b'"' {
                out.push(b'"');
                i += 1;
            }
            continue;
        }
        // Char literal
        if b == b'\'' {
            out.push(b'\'');
            i += 1;
            while i < bytes.len() && bytes[i] != b'\'' {
                if bytes[i] == b'\\' && i + 1 < bytes.len() {
                    out.push(b' ');
                    out.push(b' ');
                    i += 2;
                    continue;
                }
                if bytes[i] == b'\n' {
                    break;
                }
                out.push(b' ');
                i += 1;
            }
            if i < bytes.len() && bytes[i] == b'\'' {
                out.push(b'\'');
                i += 1;
            }
            continue;
        }
        out.push(b);
        i += 1;
    }
    // SAFETY-equivalent: we only ever pushed ASCII or original bytes. Original
    // bytes already form valid UTF-8 in `src`, so the result is valid UTF-8.
    String::from_utf8(out).unwrap_or_default()
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Tok {
    Ident(String),
    Op(char),
    /// Multi-char operator we care about.
    OpStr(&'static str),
    /// A balanced `@Annotation(...)` or `@Annotation`. We collapse annotations
    /// into a single token so they don't disturb modifier scanning.
    Annotation,
    /// `<...>` generic block (matched). Used so we can skip type parameter lists.
    Angle(String),
    /// `(...)` parenthesized group, balanced. Used to recognise parameter lists.
    Paren(String),
    /// `[...]` bracket group, balanced.
    Bracket(String),
    /// Number literal (unused but kept for completeness).
    Number(String),
    Newline,
}

#[derive(Debug, Clone)]
struct PosTok {
    tok: Tok,
    line: u32,
    col: u32,
}

/// Tokenize scrubbed source into the coarse stream described above. Balanced
/// `()`, `[]`, and (heuristically) `<>` groups are collapsed into a single
/// token containing their raw inner text. We do NOT collapse `{}` so the decl
/// walker can track class bodies.
// Single byte-dispatch scanner loop; splitting it would fragment the dispatch.
// Column offsets stay within a u32; token spans never reach 4 GiB.
#[allow(clippy::too_many_lines, clippy::cast_possible_truncation)]
fn tokenize(src: &str) -> Vec<PosTok> {
    let bytes = src.as_bytes();
    let mut out = Vec::new();
    let mut i = 0usize;
    let mut line = 1u32;
    let mut col = 1u32;

    while i < bytes.len() {
        let b = bytes[i];
        if b == b'\n' {
            out.push(PosTok {
                tok: Tok::Newline,
                line,
                col,
            });
            line += 1;
            col = 1;
            i += 1;
            continue;
        }
        if b.is_ascii_whitespace() {
            i += 1;
            col += 1;
            continue;
        }
        if b == b'@' {
            let (consumed, lines, end_col) = consume_annotation(bytes, i, line, col);
            i = consumed;
            line = lines;
            col = end_col;
            out.push(PosTok {
                tok: Tok::Annotation,
                line,
                col,
            });
            continue;
        }
        if is_ident_start(b) {
            let start = i;
            while i < bytes.len() && is_ident_continue(bytes[i]) {
                i += 1;
                col += 1;
            }
            // Backtick identifiers `foo bar` (not generated by stdlib but cheap).
            let text = src[start..i].to_string();
            out.push(PosTok {
                tok: Tok::Ident(text),
                line,
                col: col - (i - start) as u32,
            });
            continue;
        }
        if b == b'`' {
            let start = i;
            i += 1;
            col += 1;
            while i < bytes.len() && bytes[i] != b'`' {
                if bytes[i] == b'\n' {
                    break;
                }
                i += 1;
                col += 1;
            }
            if i < bytes.len() && bytes[i] == b'`' {
                i += 1;
                col += 1;
            }
            let text = src[start..i].to_string();
            out.push(PosTok {
                tok: Tok::Ident(text),
                line,
                col,
            });
            continue;
        }
        if b.is_ascii_digit() {
            let start = i;
            while i < bytes.len()
                && (bytes[i].is_ascii_alphanumeric() || bytes[i] == b'_' || bytes[i] == b'.')
            {
                i += 1;
                col += 1;
            }
            out.push(PosTok {
                tok: Tok::Number(src[start..i].to_string()),
                line,
                col,
            });
            continue;
        }
        if b == b'(' {
            let (inner, end, lines, end_col) = balanced(bytes, i, b'(', b')', line, col);
            i = end;
            line = lines;
            col = end_col;
            out.push(PosTok {
                tok: Tok::Paren(inner),
                line,
                col,
            });
            continue;
        }
        if b == b'[' {
            let (inner, end, lines, end_col) = balanced(bytes, i, b'[', b']', line, col);
            i = end;
            line = lines;
            col = end_col;
            out.push(PosTok {
                tok: Tok::Bracket(inner),
                line,
                col,
            });
            continue;
        }
        if b == b'<' {
            // Heuristic: only treat as generic-angle if it looks like one. We
            // attempt to find a matching `>` on the same line or within a few
            // identifiers; if not, fall back to an operator.
            if let Some((inner, end, end_line, end_col)) = try_balance_angles(bytes, i, line, col) {
                i = end;
                line = end_line;
                col = end_col;
                out.push(PosTok {
                    tok: Tok::Angle(inner),
                    line,
                    col,
                });
                continue;
            }
            out.push(PosTok {
                tok: Tok::Op('<'),
                line,
                col,
            });
            i += 1;
            col += 1;
            continue;
        }
        // Multi-char operators we care about.
        if i + 1 < bytes.len() {
            let two = &src[i..i + 2];
            if matches!(two, "->" | "::" | "..") {
                let tag = match two {
                    "->" => "->",
                    "::" => "::",
                    ".." => "..",
                    _ => unreachable!(),
                };
                out.push(PosTok {
                    tok: Tok::OpStr(tag),
                    line,
                    col,
                });
                i += 2;
                col += 2;
                continue;
            }
        }
        out.push(PosTok {
            tok: Tok::Op(b as char),
            line,
            col,
        });
        i += 1;
        col += 1;
    }
    out
}

/// Pull parameter names out of a balanced parameter-list body. The
/// tokenizer already gave us the content between `(` and `)`; we split on
/// top-level commas (respecting nested `()`/`[]`/`<>`/`{}`) and for each
/// piece take the last whitespace-separated word before the `:`.
fn extract_param_names(content: &str) -> Vec<String> {
    let mut names = Vec::new();
    let bytes = content.as_bytes();
    let mut start = 0usize;
    let mut depth_paren = 0i32;
    let mut depth_bracket = 0i32;
    let mut depth_angle = 0i32;
    let mut depth_brace = 0i32;
    for i in 0..=bytes.len() {
        let boundary = i == bytes.len()
            || (bytes[i] == b','
                && depth_paren == 0
                && depth_bracket == 0
                && depth_angle == 0
                && depth_brace == 0);
        if boundary {
            if let Some(name) = extract_one_param_name(&content[start..i]) {
                names.push(name);
            }
            start = i + 1;
        } else {
            match bytes[i] {
                b'(' => depth_paren += 1,
                b')' => depth_paren -= 1,
                b'[' => depth_bracket += 1,
                b']' => depth_bracket -= 1,
                b'<' => depth_angle += 1,
                b'>' => depth_angle -= 1,
                b'{' => depth_brace += 1,
                b'}' => depth_brace -= 1,
                _ => {}
            }
        }
    }
    names
}

fn extract_one_param_name(piece: &str) -> Option<String> {
    let trimmed = piece.trim();
    if trimmed.is_empty() {
        return None;
    }
    // Find the `:` separating the name from the type, ignoring nested
    // generics / function-type arrow brackets.
    let mut depth = 0i32;
    let mut colon_at: Option<usize> = None;
    for (idx, ch) in trimmed.char_indices() {
        match ch {
            '<' | '[' | '(' | '{' => depth += 1,
            '>' | ']' | ')' | '}' => depth -= 1,
            ':' if depth == 0 => {
                colon_at = Some(idx);
                break;
            }
            _ => {}
        }
    }
    let left = match colon_at {
        Some(c) => &trimmed[..c],
        None => trimmed,
    };
    // Last whitespace-separated token is the name (modifiers like
    // `vararg`/`crossinline`/`noinline` may precede it).
    let last = left.split_whitespace().last()?;
    if last.chars().next()?.is_alphabetic() || last.starts_with('_') {
        Some(last.to_string())
    } else {
        None
    }
}

fn is_ident_start(b: u8) -> bool {
    b.is_ascii_alphabetic() || b == b'_'
}

fn is_ident_continue(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_'
}

// Column offset stays within a u32; an annotation span never reaches 4 GiB.
#[allow(clippy::cast_possible_truncation)]
fn consume_annotation(
    bytes: &[u8],
    mut i: usize,
    mut line: u32,
    mut col: u32,
) -> (usize, u32, u32) {
    // Eat `@`
    i += 1;
    col += 1;
    // Optional site target: `@file:`, `@get:`, etc.
    let mut j = i;
    while j < bytes.len() && is_ident_continue(bytes[j]) {
        j += 1;
    }
    if j < bytes.len() && bytes[j] == b':' {
        col += (j - i) as u32 + 1;
        i = j + 1;
    }
    // Eat a dotted name and possibly an argument list / angle block.
    while i < bytes.len() {
        let b = bytes[i];
        if is_ident_continue(b) || b == b'.' {
            i += 1;
            col += 1;
        } else {
            break;
        }
    }
    // Possible `<...>` (rare in annotations) or `(...)` argument list.
    if i < bytes.len() && bytes[i] == b'(' {
        let (_, end, end_line, end_col) = balanced(bytes, i, b'(', b')', line, col);
        i = end;
        line = end_line;
        col = end_col;
    }
    (i, line, col)
}

fn balanced(
    bytes: &[u8],
    start: usize,
    open: u8,
    close: u8,
    line0: u32,
    col0: u32,
) -> (String, usize, u32, u32) {
    debug_assert_eq!(bytes[start], open);
    let mut depth = 0i32;
    let mut i = start;
    let mut line = line0;
    let mut col = col0;
    let inner_start = start + 1;
    while i < bytes.len() {
        let b = bytes[i];
        if b == open {
            depth += 1;
        } else if b == close {
            depth -= 1;
            if depth == 0 {
                let inner = String::from_utf8_lossy(&bytes[inner_start..i]).to_string();
                return (inner, i + 1, line, col + 1);
            }
        }
        if b == b'\n' {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
        i += 1;
    }
    (String::new(), bytes.len(), line, col)
}

/// Try to read a balanced `<...>` group. We give up if we hit `;`, `{`, `}`, or
/// a newline-with-zero-depth before closing. Required so `a < b` doesn't get
/// misread as a generic.
fn try_balance_angles(
    bytes: &[u8],
    start: usize,
    line0: u32,
    col0: u32,
) -> Option<(String, usize, u32, u32)> {
    let mut depth = 0i32;
    let mut paren = 0i32;
    let mut i = start;
    let mut line = line0;
    let mut col = col0;
    let inner_start = start + 1;
    let mut saw_letter = false;
    while i < bytes.len() {
        let b = bytes[i];
        match b {
            b'<' => depth += 1,
            b'>' => {
                depth -= 1;
                if depth == 0 {
                    if !saw_letter {
                        return None;
                    }
                    let inner = String::from_utf8_lossy(&bytes[inner_start..i]).to_string();
                    return Some((inner, i + 1, line, col + 1));
                }
            }
            b'(' => paren += 1,
            b')' => {
                paren -= 1;
                if paren < 0 {
                    return None;
                }
            }
            b'{' | b'}' | b';' => return None,
            b'\n' => {
                line += 1;
                col = 1;
                i += 1;
                continue;
            }
            b' ' | b'\t' => {}
            c if c.is_ascii_alphabetic() || c == b'_' => saw_letter = true,
            _ => {}
        }
        col += 1;
        i += 1;
    }
    None
}

#[must_use]
pub fn parse_file(src: &str) -> ParsedFile {
    let scrubbed = scrub(src);
    let toks = tokenize(&scrubbed);
    let mut p = Parser {
        toks: &toks,
        pos: 0,
        package: String::new(),
        decls: Vec::new(),
    };
    p.parse_top();
    ParsedFile {
        package: p.package,
        decls: p.decls,
    }
}

struct Parser<'a> {
    toks: &'a [PosTok],
    pos: usize,
    package: String,
    decls: Vec<Decl>,
}

impl<'a> Parser<'a> {
    fn peek(&self) -> Option<&PosTok> {
        self.toks.get(self.pos)
    }

    fn bump(&mut self) -> Option<&'a PosTok> {
        let t = self.toks.get(self.pos);
        if t.is_some() {
            self.pos += 1;
        }
        t
    }

    fn skip_newlines(&mut self) {
        while let Some(t) = self.peek() {
            if matches!(t.tok, Tok::Newline) {
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    fn skip_annotations_and_newlines(&mut self) {
        while let Some(t) = self.peek() {
            match &t.tok {
                Tok::Newline | Tok::Annotation => self.pos += 1,
                _ => break,
            }
        }
    }

    fn parse_top(&mut self) {
        // Look for `package <dotted>`.
        self.skip_annotations_and_newlines();
        if let Some(t) = self.peek()
            && let Tok::Ident(s) = &t.tok
            && s == "package"
        {
            self.pos += 1;
            self.package = self.read_dotted_name();
        }
        self.parse_decls(None);
    }

    fn read_dotted_name(&mut self) -> String {
        let mut out = String::new();
        // names are on one line generally, so no newline/annotation skipping.
        while let Some(t) = self.peek() {
            match &t.tok {
                Tok::Ident(s) => {
                    if !out.is_empty() && !out.ends_with('.') {
                        // Two identifiers in a row -> stop.
                        break;
                    }
                    out.push_str(s);
                    self.pos += 1;
                }
                Tok::Op('.') => {
                    if out.is_empty() {
                        break;
                    }
                    out.push('.');
                    self.pos += 1;
                }
                _ => break,
            }
        }
        out
    }

    /// Parse declarations until we hit end-of-stream or a `}` (the latter pops
    /// the caller back out of a class body).
    fn parse_decls(&mut self, parent: Option<&str>) {
        loop {
            self.skip_annotations_and_newlines();
            let Some(t) = self.peek() else { return };
            if matches!(t.tok, Tok::Op('}')) {
                self.pos += 1;
                return;
            }
            if !self.parse_one_decl(parent) {
                // Couldn't parse — advance one token to make progress.
                self.pos += 1;
            }
        }
    }

    /// Attempt to parse one declaration starting at the current position.
    /// Returns true on success (cursor advanced past the decl) and false to
    /// indicate the caller should bump and retry.
    fn parse_one_decl(&mut self, parent: Option<&str>) -> bool {
        let start_pos = self.pos;
        let mut modifiers: u32 = 0;

        // Collect modifiers (idents that are modifier keywords). We stop at
        // the first ident that is not a modifier.
        loop {
            self.skip_annotations_and_newlines();
            let Some(t) = self.peek() else { return false };
            if let Tok::Ident(s) = &t.tok
                && let Some(bit) = modifier_bit(s)
            {
                modifiers |= bit;
                self.pos += 1;
                continue;
            }
            break;
        }

        let Some(t) = self.peek().cloned() else {
            self.pos = start_pos;
            return false;
        };
        let line = t.line;
        let col = t.col;

        match &t.tok {
            Tok::Ident(kw) if kw == "fun" => {
                self.pos += 1;
                self.parse_fun(modifiers, line, col, parent)
            }
            Tok::Ident(kw) if kw == "val" || kw == "var" => {
                self.pos += 1;
                self.parse_property(modifiers, line, col, parent, kw == "var")
            }
            Tok::Ident(kw) if kw == "class" => {
                self.pos += 1;
                self.parse_class_like(modifiers, line, col, parent, DeclKind::Class)
            }
            Tok::Ident(kw) if kw == "interface" => {
                self.pos += 1;
                self.parse_class_like(modifiers, line, col, parent, DeclKind::Interface)
            }
            Tok::Ident(kw) if kw == "object" => {
                self.pos += 1;
                self.parse_class_like(modifiers, line, col, parent, DeclKind::Object)
            }
            Tok::Ident(kw) if kw == "typealias" => {
                self.pos += 1;
                self.parse_typealias(modifiers, line, col, parent)
            }
            Tok::Ident(kw) if kw == "constructor" => {
                // Class secondary constructor. Skip parens and any body.
                self.pos += 1;
                self.skip_signature_tail();
                self.skip_optional_body();
                true
            }
            Tok::Ident(kw) if kw == "init" => {
                // Init block. Skip body.
                self.pos += 1;
                self.skip_optional_body();
                true
            }
            Tok::Ident(kw) if kw == "import" || kw == "package" => {
                // Eat to newline.
                while let Some(t) = self.peek() {
                    if matches!(t.tok, Tok::Newline) {
                        self.pos += 1;
                        break;
                    }
                    self.pos += 1;
                }
                true
            }
            Tok::Op(';') => {
                self.pos += 1;
                true
            }
            Tok::Op('{') => {
                // Stray block. Skip it.
                self.skip_brace_block();
                true
            }
            _ => {
                self.pos = start_pos;
                false
            }
        }
    }

    fn parse_fun(&mut self, modifiers: u32, line: u32, col: u32, parent: Option<&str>) -> bool {
        // Optional `<T, ...>` generic params.
        if let Some(t) = self.peek()
            && matches!(t.tok, Tok::Angle(_))
        {
            self.pos += 1;
        }
        // Optional receiver. Format: `ReceiverType.name(...)` or `ReceiverType<T>.name(...)`.
        // We look ahead: read an ident, possibly followed by `<...>` / `.` / `?` chunks
        // until we see `.<name>(`, treating the leading run as the receiver.
        let pre_recv = self.pos;
        let (receiver, name) = self.read_optional_receiver_and_name();
        let Some(name) = name else {
            self.pos = pre_recv;
            return false;
        };
        // Capture the parameter list before walking the rest of the signature.
        // Tokenizer already collapses balanced `(...)` into `Tok::Paren(inner)`.
        let param_names: Vec<String> = match self.peek().map(|t| &t.tok) {
            Some(Tok::Paren(inner)) => {
                let names = extract_param_names(inner);
                self.pos += 1;
                names
            }
            _ => Vec::new(),
        };
        // Skip the rest of the signature up to either a function body `{...}`,
        // an `= expr` (eaten to newline), or just newline / next decl.
        let () = self.skip_signature_tail();
        self.skip_optional_body();

        let fqn = match parent {
            Some(p) => format!(
                "{}{}.{}",
                if self.package.is_empty() {
                    String::new()
                } else {
                    format!("{}.", self.package)
                },
                p,
                name
            ),
            None => format!(
                "{}{}",
                if self.package.is_empty() {
                    String::new()
                } else {
                    format!("{}.", self.package)
                },
                name
            ),
        };
        let mut signature = String::new();
        write!(&mut signature, "fun ").ok();
        if let Some(r) = &receiver {
            write!(&mut signature, "{r}.").ok();
        }
        write!(&mut signature, "{name}").ok();

        self.decls.push(Decl {
            kind: DeclKind::Function,
            name,
            fqn,
            parent: parent.map(str::to_string),
            receiver,
            modifiers,
            signature,
            param_names,
            line,
            column: col,
        });
        true
    }

    fn parse_property(
        &mut self,
        modifiers: u32,
        line: u32,
        col: u32,
        parent: Option<&str>,
        is_var: bool,
    ) -> bool {
        // Optional `<T>` generic params.
        if let Some(t) = self.peek()
            && matches!(t.tok, Tok::Angle(_))
        {
            self.pos += 1;
        }
        let pre = self.pos;
        let (receiver, name) = self.read_optional_receiver_and_name();
        let Some(name) = name else {
            self.pos = pre;
            return false;
        };
        self.skip_signature_tail();
        // A property may also have `get()/set()` accessors as following decls
        // at the same brace level, but the upstream stdlib mostly leaves them
        // as `expect` declarations without bodies. We skip an optional body.
        self.skip_optional_body();
        // Skip optional accessor blocks. Accessors must literally start with
        // `get` or `set` (a leading visibility on the accessor is uncommon and
        // matching greedy here would steal the next declaration).
        loop {
            self.skip_annotations_and_newlines();
            let Some(t) = self.peek() else { break };
            match &t.tok {
                Tok::Ident(s) if s == "get" || s == "set" => {
                    self.pos += 1;
                    if let Some(t) = self.peek()
                        && matches!(t.tok, Tok::Paren(_))
                    {
                        self.pos += 1;
                    }
                    self.skip_signature_tail();
                    self.skip_optional_body();
                }
                _ => break,
            }
        }

        let kind_word = if is_var { "var" } else { "val" };
        let fqn = match parent {
            Some(p) => format!(
                "{}{}.{}",
                if self.package.is_empty() {
                    String::new()
                } else {
                    format!("{}.", self.package)
                },
                p,
                name
            ),
            None => format!(
                "{}{}",
                if self.package.is_empty() {
                    String::new()
                } else {
                    format!("{}.", self.package)
                },
                name
            ),
        };
        let mut signature = String::new();
        write!(&mut signature, "{kind_word} ").ok();
        if let Some(r) = &receiver {
            write!(&mut signature, "{r}.").ok();
        }
        write!(&mut signature, "{name}").ok();
        self.decls.push(Decl {
            kind: DeclKind::Property,
            name,
            fqn,
            parent: parent.map(str::to_string),
            receiver,
            modifiers,
            signature,
            param_names: Vec::new(),
            line,
            column: col,
        });
        true
    }

    fn parse_class_like(
        &mut self,
        modifiers: u32,
        line: u32,
        col: u32,
        parent: Option<&str>,
        kind: DeclKind,
    ) -> bool {
        // Class name.
        self.skip_newlines();
        let name = match self.peek() {
            Some(t) => match &t.tok {
                Tok::Ident(s) => {
                    let n = s.clone();
                    self.pos += 1;
                    n
                }
                _ => return false,
            },
            None => return false,
        };
        // Optional `<T,...>`.
        if let Some(t) = self.peek()
            && matches!(t.tok, Tok::Angle(_))
        {
            self.pos += 1;
        }
        // Optional primary constructor `(...)`.
        if let Some(t) = self.peek()
            && matches!(t.tok, Tok::Paren(_))
        {
            self.pos += 1;
        }
        // Skip until `{` or end of decl (newline at brace depth 0).
        self.skip_signature_tail();

        let fqn = match parent {
            Some(p) => format!(
                "{}{}.{}",
                if self.package.is_empty() {
                    String::new()
                } else {
                    format!("{}.", self.package)
                },
                p,
                name
            ),
            None => format!(
                "{}{}",
                if self.package.is_empty() {
                    String::new()
                } else {
                    format!("{}.", self.package)
                },
                name
            ),
        };
        let signature = format!(
            "{} {}",
            match kind {
                DeclKind::Class => "class",
                DeclKind::Interface => "interface",
                DeclKind::Object => "object",
                _ => "?",
            },
            name
        );

        self.decls.push(Decl {
            kind,
            name: name.clone(),
            fqn,
            parent: parent.map(str::to_string),
            receiver: None,
            modifiers,
            signature,
            param_names: Vec::new(),
            line,
            column: col,
        });

        // Optional body.
        self.skip_newlines();
        if let Some(t) = self.peek()
            && matches!(t.tok, Tok::Op('{'))
        {
            self.pos += 1;
            self.parse_decls(Some(&name));
        }
        true
    }

    fn parse_typealias(
        &mut self,
        modifiers: u32,
        line: u32,
        col: u32,
        parent: Option<&str>,
    ) -> bool {
        self.skip_newlines();
        let name = match self.peek() {
            Some(t) => match &t.tok {
                Tok::Ident(s) => {
                    let n = s.clone();
                    self.pos += 1;
                    n
                }
                _ => return false,
            },
            None => return false,
        };
        if let Some(t) = self.peek()
            && matches!(t.tok, Tok::Angle(_))
        {
            self.pos += 1;
        }
        self.skip_signature_tail();
        let fqn = match parent {
            Some(p) => format!(
                "{}{}.{}",
                if self.package.is_empty() {
                    String::new()
                } else {
                    format!("{}.", self.package)
                },
                p,
                name
            ),
            None => format!(
                "{}{}",
                if self.package.is_empty() {
                    String::new()
                } else {
                    format!("{}.", self.package)
                },
                name
            ),
        };
        let signature = format!("typealias {name}");
        self.decls.push(Decl {
            kind: DeclKind::TypeAlias,
            name,
            fqn,
            parent: parent.map(str::to_string),
            receiver: None,
            modifiers,
            signature,
            param_names: Vec::new(),
            line,
            column: col,
        });
        true
    }

    /// Read `Recv[.Recv2][<T>][?].name`. Returns (receiver, name).
    /// If only a plain `name` is present, returns (None, Some(name)).
    fn read_optional_receiver_and_name(&mut self) -> (Option<String>, Option<String>) {
        // Walk ahead, gathering ident / `.` / Angle / `?` until we find an
        // ident followed by `(` (function) or by `:` / newline / `=` (property).
        // The *last* ident before that terminator is the name; everything before
        // (joined with `.`) is the receiver.
        let mut pieces: Vec<String> = Vec::new();
        while let Some(t) = self.peek() {
            match &t.tok {
                Tok::Ident(s) => {
                    pieces.push(s.clone());
                    self.pos += 1;
                }
                Tok::Op('.') => {
                    pieces.push(".".to_string());
                    self.pos += 1;
                }
                Tok::Op('?') => {
                    if let Some(last) = pieces.last_mut() {
                        last.push('?');
                    }
                    self.pos += 1;
                }
                Tok::Angle(s) => {
                    if let Some(last) = pieces.last_mut() {
                        *last = format!("{last}<{s}>");
                    }
                    self.pos += 1;
                }
                _ => break,
            }
        }
        if pieces.is_empty() {
            return (None, None);
        }
        // The "name" is the last non-dot piece. Build receiver from earlier pieces.
        // Drop trailing dot if any.
        while pieces.last().is_some_and(|s| s == ".") {
            pieces.pop();
        }
        let name = pieces.pop();
        // Drop trailing dot between receiver and name.
        if pieces.last().is_some_and(|s| s == ".") {
            pieces.pop();
        }
        let receiver = if pieces.is_empty() {
            None
        } else {
            Some(pieces.join(""))
        };
        (receiver, name)
    }

    /// Skip up to and including the next `{` body, `= ...` expression body, or
    /// a top-level newline-terminator. Returns the signature text consumed (we
    /// don't currently use it).
    fn skip_signature_tail(&mut self) {
        let mut paren_depth = 0i32;
        let mut bracket_depth = 0i32;
        loop {
            let Some(t) = self.peek() else { return };
            match &t.tok {
                Tok::Op('{') => return,
                Tok::Op(';') => {
                    self.pos += 1;
                    return;
                }
                Tok::Op('=') if paren_depth == 0 && bracket_depth == 0 => {
                    // Expression body. Eat to newline at depth 0.
                    self.pos += 1;
                    self.skip_to_newline_or_dedent();
                    return;
                }
                Tok::Newline if paren_depth == 0 && bracket_depth == 0 => {
                    self.pos += 1;
                    return;
                }
                Tok::Op('(') => {
                    paren_depth += 1;
                    self.pos += 1;
                }
                Tok::Op(')') => {
                    paren_depth -= 1;
                    self.pos += 1;
                }
                Tok::Op('[') => {
                    bracket_depth += 1;
                    self.pos += 1;
                }
                Tok::Op(']') => {
                    bracket_depth -= 1;
                    self.pos += 1;
                }
                _ => self.pos += 1,
            }
        }
    }

    fn skip_to_newline_or_dedent(&mut self) {
        let mut paren_depth = 0i32;
        let mut brace_depth = 0i32;
        loop {
            let Some(t) = self.peek() else { return };
            match &t.tok {
                Tok::Newline if paren_depth == 0 && brace_depth == 0 => {
                    self.pos += 1;
                    return;
                }
                Tok::Op('(') => paren_depth += 1,
                Tok::Op(')') => paren_depth -= 1,
                Tok::Op('{') => brace_depth += 1,
                Tok::Op('}') => {
                    if brace_depth == 0 {
                        return;
                    }
                    brace_depth -= 1;
                }
                _ => {}
            }
            self.pos += 1;
        }
    }

    fn skip_optional_body(&mut self) {
        self.skip_newlines();
        if let Some(t) = self.peek()
            && matches!(t.tok, Tok::Op('{'))
        {
            self.skip_brace_block();
        }
    }

    fn skip_brace_block(&mut self) {
        let Some(t) = self.peek() else { return };
        if !matches!(t.tok, Tok::Op('{')) {
            return;
        }
        self.pos += 1;
        let mut depth = 1i32;
        while depth > 0 {
            let Some(t) = self.bump() else { return };
            match t.tok {
                Tok::Op('{') => depth += 1,
                Tok::Op('}') => depth -= 1,
                _ => {}
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_simple_function() {
        let src = "package kotlin\npublic fun foo(): Int = 1\n";
        let pf = parse_file(src);
        assert_eq!(pf.package, "kotlin");
        assert_eq!(pf.decls.len(), 1);
        assert_eq!(pf.decls[0].name, "foo");
        assert_eq!(pf.decls[0].fqn, "kotlin.foo");
        assert!(pf.decls[0].modifiers & modflag::PUBLIC != 0);
    }

    #[test]
    fn parses_extension_function_with_generics() {
        let src = "package kotlin.collections\npublic fun <T> List<T>.first(): T = get(0)\n";
        let pf = parse_file(src);
        assert_eq!(pf.decls.len(), 1);
        let d = &pf.decls[0];
        assert_eq!(d.name, "first");
        assert_eq!(d.receiver.as_deref(), Some("List<T>"));
        assert_eq!(d.fqn, "kotlin.collections.first");
    }

    #[test]
    fn parses_property_in_class() {
        let src = "package kotlin\npublic class Foo {\n  public val x: Int = 0\n  public fun bar(): Int = x\n}\n";
        let pf = parse_file(src);
        let names: Vec<_> = pf
            .decls
            .iter()
            .map(|d| (d.name.as_str(), d.parent.as_deref()))
            .collect();
        assert!(names.contains(&("Foo", None)));
        assert!(names.contains(&("x", Some("Foo"))));
        assert!(names.contains(&("bar", Some("Foo"))));
    }

    #[test]
    fn handles_expect_decl_without_body() {
        let src = "package kotlin\npublic expect fun Double.isNaN(): Boolean\n";
        let pf = parse_file(src);
        assert_eq!(pf.decls.len(), 1);
        assert_eq!(pf.decls[0].name, "isNaN");
        assert_eq!(pf.decls[0].receiver.as_deref(), Some("Double"));
        assert!(pf.decls[0].modifiers & modflag::EXPECT != 0);
    }

    #[test]
    fn parses_typealias() {
        let src = "package kotlin\npublic typealias Foo = Int\n";
        let pf = parse_file(src);
        assert_eq!(pf.decls.len(), 1);
        assert_eq!(pf.decls[0].kind, DeclKind::TypeAlias);
        assert_eq!(pf.decls[0].name, "Foo");
    }

    #[test]
    fn ignores_string_braces() {
        let src = "package kotlin\npublic fun foo(): String = \"}{{\"\npublic fun bar(): Int = 1\n";
        let pf = parse_file(src);
        let names: Vec<_> = pf.decls.iter().map(|d| d.name.as_str()).collect();
        assert!(names.contains(&"foo"));
        assert!(names.contains(&"bar"));
    }

    #[test]
    fn ignores_comments_and_annotations() {
        let src = r#"
package kotlin

/**
 * docs
 */
@SinceKotlin("1.2")
@kotlin.internal.InlineOnly
public inline operator fun <T> List<T>.component1(): T = get(0)
"#;
        let pf = parse_file(src);
        assert_eq!(pf.decls.len(), 1);
        let d = &pf.decls[0];
        assert_eq!(d.name, "component1");
        assert!(d.modifiers & modflag::INLINE != 0);
        assert!(d.modifiers & modflag::OPERATOR != 0);
    }
}
