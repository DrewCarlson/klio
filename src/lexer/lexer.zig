//! Kotlin lexer.
//!
//! Covers the lexical structure of Kotlin needed by the parser: trivia
//! (line + nested block comments), identifiers and keywords, numeric
//! literals across all four bases with suffixes, character literals,
//! template-aware string literals (regular and triple-quoted/raw), and the
//! operator/punctuation set.
//!
//! String templates are produced as a structured token sequence:
//! `StringQuote StringText InterpStart … InterpEnd StringText StringQuote`.
//! Inside `${…}` the lexer returns to the normal mode and tracks brace depth
//! so nested braces stay balanced.

const std = @import("std");
const diagnostics = @import("diagnostics");
const span = @import("span");

const Diagnostic = diagnostics.Diagnostic;
const DiagnosticSink = diagnostics.DiagnosticSink;
const kf = diagnostics.generated;
const FileId = span.FileId;
const Span = span.Span;

pub const NumBase = enum {
    Decimal,
    Hex,
    Binary,
};

pub const IntSuffix = enum {
    None,
    Long,
    UInt,
    ULong,
};

pub const FloatSuffix = enum {
    None, // Double
    Float,
};

pub const Keyword = enum {
    // Hard keywords
    As,
    Break,
    Class,
    Continue,
    Do,
    Else,
    For,
    Fun,
    If,
    In,
    Interface,
    Is,
    Object,
    Package,
    Return,
    Super,
    This,
    Throw,
    Try,
    Typealias,
    Typeof,
    Val,
    Var,
    When,
    While,
    Import,

    pub fn fromIdent(s: []const u8) ?Keyword {
        const map = std.StaticStringMap(Keyword).initComptime(.{
            .{ "as", .As },
            .{ "break", .Break },
            .{ "class", .Class },
            .{ "continue", .Continue },
            .{ "do", .Do },
            .{ "else", .Else },
            .{ "for", .For },
            .{ "fun", .Fun },
            .{ "if", .If },
            .{ "in", .In },
            .{ "interface", .Interface },
            .{ "is", .Is },
            .{ "object", .Object },
            .{ "package", .Package },
            .{ "return", .Return },
            .{ "super", .Super },
            .{ "this", .This },
            .{ "throw", .Throw },
            .{ "try", .Try },
            .{ "typealias", .Typealias },
            .{ "typeof", .Typeof },
            .{ "val", .Val },
            .{ "var", .Var },
            .{ "when", .When },
            .{ "while", .While },
            .{ "import", .Import },
        });
        return map.get(s);
    }
};

pub const TokenKind = union(enum) {
    // Trivia
    Whitespace,
    Newline,
    LineComment,
    BlockComment,

    // Literals (text-bearing; cooked numeric value is parsed downstream)
    IntLiteral: struct { base: NumBase, suffix: IntSuffix },
    FloatLiteral: struct { suffix: FloatSuffix },
    BoolLiteral: bool,
    NullLiteral,
    CharLiteral: u16,

    // String tokens (template-aware)
    StringQuote: struct { triple: bool },
    /// Owned UTF-8 text; freed via `Token.deinit`.
    StringText: []const u8,
    InterpStart,
    InterpEnd,
    /// Owned identifier name; freed via `Token.deinit`.
    ShortInterp: []const u8,

    // Identifiers and keywords
    Ident,
    Keyword: Keyword,

    // Punctuation and operators
    LParen,
    RParen,
    LBrace,
    RBrace,
    LBracket,
    RBracket,
    Comma,
    Semicolon,
    Colon,
    ColonColon,
    AtNoWs,
    AtPostWs,
    AtPreWs,
    AtBothWs,
    Dot,
    DotDot,
    DotDotLess,
    Arrow,
    FatArrow,
    Eq,
    EqEq,
    EqEqEq,
    BangEq,
    BangEqEq,
    Lt,
    Le,
    Gt,
    Ge,
    Plus,
    Minus,
    Star,
    Slash,
    Percent,
    PlusEq,
    MinusEq,
    StarEq,
    SlashEq,
    PercentEq,
    PlusPlus,
    MinusMinus,
    Amp,
    AmpAmp,
    Pipe,
    PipePipe,
    BangBang,
    ExclNoWs,
    ExclWs,
    QuestNoWs,
    QuestWs,
    QuestionDot,
    QuestionColon,

    // Reserved / shebang
    Reserved,
    DoubleSemicolon,
    Hash,
    ShebangLine,

    Unknown,
    Eof,

    pub fn isAt(self: TokenKind) bool {
        return switch (self) {
            .AtNoWs, .AtPostWs, .AtPreWs, .AtBothWs => true,
            else => false,
        };
    }

    pub fn isQuestion(self: TokenKind) bool {
        return switch (self) {
            .QuestNoWs, .QuestWs => true,
            else => false,
        };
    }

    pub fn isBang(self: TokenKind) bool {
        return switch (self) {
            .ExclNoWs, .ExclWs => true,
            else => false,
        };
    }
};

pub const Token = struct {
    kind: TokenKind,
    span: Span,

    /// Frees any heap text owned by this token's kind.
    pub fn deinit(self: *Token, allocator: std.mem.Allocator) void {
        switch (self.kind) {
            .StringText => |s| allocator.free(s),
            .ShortInterp => |s| allocator.free(s),
            else => {},
        }
    }
};

pub const LexResult = struct {
    tokens: []Token,
    diagnostics: DiagnosticSink,
    /// Heap-allocated diagnostic message strings whose lifetime the
    /// `DiagnosticSink` borrows. Freed alongside the diagnostics.
    owned_messages: []const []const u8,

    pub fn deinit(self: *LexResult, allocator: std.mem.Allocator) void {
        for (self.tokens) |*t| t.deinit(allocator);
        allocator.free(self.tokens);
        self.diagnostics.deinit(allocator);
        for (self.owned_messages) |m| allocator.free(m);
        allocator.free(self.owned_messages);
    }
};

const Mode = union(enum) {
    Normal,
    StringRegular,
    StringRaw,
    Interp: struct { brace_depth: u32 },
};

pub const Lexer = struct {
    allocator: std.mem.Allocator,
    file: FileId,
    src: []const u8,
    pos: u32,
    modes: std.ArrayList(Mode),
    diagnostics: DiagnosticSink,
    owned_messages: std.ArrayList([]const u8),
    ws_before: bool,
    nl_before: bool,

    pub fn init(allocator: std.mem.Allocator, file: FileId, src: []const u8) !Lexer {
        var modes: std.ArrayList(Mode) = .empty;
        try modes.append(allocator, .Normal);
        return .{
            .allocator = allocator,
            .file = file,
            .src = src,
            .pos = 0,
            .modes = modes,
            .diagnostics = DiagnosticSink.init(),
            .owned_messages = .empty,
            .ws_before = false,
            .nl_before = false,
        };
    }

    /// Consumes the lexer and returns the tokens plus diagnostics. The
    /// returned `LexResult` owns both; free it with `LexResult.deinit`.
    pub fn tokenize(self: *Lexer) !LexResult {
        var tokens: std.ArrayList(Token) = .empty;
        loop: while (true) {
            switch (self.currentMode()) {
                .Normal, .Interp => {
                    const tok = try self.nextNormalToken();
                    switch (tok.kind) {
                        .Whitespace, .LineComment, .BlockComment, .ShebangLine => {
                            self.ws_before = true;
                        },
                        .Newline => {
                            self.ws_before = true;
                            self.nl_before = true;
                            try tokens.append(self.allocator, tok);
                        },
                        .Eof => {
                            try tokens.append(self.allocator, tok);
                            break :loop;
                        },
                        else => {
                            try tokens.append(self.allocator, tok);
                            self.ws_before = false;
                            self.nl_before = false;
                        },
                    }
                },
                .StringRegular => {
                    try self.lexStringBody(&tokens, false);
                    self.ws_before = false;
                    self.nl_before = false;
                },
                .StringRaw => {
                    try self.lexStringBody(&tokens, true);
                    self.ws_before = false;
                    self.nl_before = false;
                },
            }
        }
        self.modes.deinit(self.allocator);
        return .{
            .tokens = try tokens.toOwnedSlice(self.allocator),
            .diagnostics = self.diagnostics,
            .owned_messages = try self.owned_messages.toOwnedSlice(self.allocator),
        };
    }

    /// Format a diagnostic message and record it for later cleanup. The
    /// returned slice is borrowed by the `DiagnosticSink` and freed when
    /// the `LexResult` is deinitialized.
    fn allocMessage(self: *Lexer, comptime fmt: []const u8, args: anytype) ![]const u8 {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.owned_messages.append(self.allocator, msg);
        return msg;
    }

    fn currentMode(self: *const Lexer) Mode {
        return self.modes.items[self.modes.items.len - 1];
    }

    fn peekByte(self: *const Lexer, off: usize) ?u8 {
        const i = @as(usize, self.pos) + off;
        if (i >= self.src.len) return null;
        return self.src[i];
    }

    fn peekChar(self: *const Lexer) ?u21 {
        if (self.pos >= self.src.len) return null;
        const rest = self.src[self.pos..];
        const len = std.unicode.utf8ByteSequenceLength(rest[0]) catch return rest[0];
        if (len > rest.len) return rest[0];
        return std.unicode.utf8Decode(rest[0..len]) catch rest[0];
    }

    fn bumpChar(self: *Lexer) ?u21 {
        if (self.pos >= self.src.len) return null;
        const rest = self.src[self.pos..];
        const seq = std.unicode.utf8ByteSequenceLength(rest[0]) catch {
            // Not a valid UTF-8 lead byte: consume one byte.
            self.pos += 1;
            return rest[0];
        };
        if (seq > rest.len) {
            self.pos += 1;
            return rest[0];
        }
        const c = std.unicode.utf8Decode(rest[0..seq]) catch {
            self.pos += 1;
            return rest[0];
        };
        self.pos += seq;
        return c;
    }

    fn span(self: *const Lexer, start: u32) Span {
        return Span.init(self.file, start, self.pos);
    }

    fn slice(self: *const Lexer, start: u32) []const u8 {
        return self.src[start..self.pos];
    }

    fn emit(self: *Lexer, d: Diagnostic) !void {
        try self.diagnostics.emit(self.allocator, d);
    }

    // ---------- normal mode ----------

    fn nextNormalToken(self: *Lexer) !Token {
        const start = self.pos;
        const b = self.peekByte(0) orelse {
            return .{ .kind = .Eof, .span = self.span(start) };
        };

        // Shebang line at file position 0.
        if (start == 0 and b == '#' and self.peekByte(1) == @as(?u8, '!')) {
            while (self.peekByte(0)) |c| {
                if (c == '\n') break;
                self.pos += 1;
            }
            return .{ .kind = .ShebangLine, .span = self.span(start) };
        }

        // Trivia.
        if (b == ' ' or b == '\t' or b == '\r') {
            while (true) {
                const c = self.peekByte(0) orelse break;
                if (c == ' ' or c == '\t' or c == '\r') {
                    self.pos += 1;
                } else break;
            }
            return .{ .kind = .Whitespace, .span = self.span(start) };
        }
        if (b == '\n') {
            self.pos += 1;
            return .{ .kind = .Newline, .span = self.span(start) };
        }
        if (b == '/' and self.peekByte(1) == @as(?u8, '/')) {
            while (self.peekByte(0)) |c| {
                if (c == '\n') break;
                self.pos += 1;
            }
            return .{ .kind = .LineComment, .span = self.span(start) };
        }
        if (b == '/' and self.peekByte(1) == @as(?u8, '*')) {
            self.pos += 2;
            var depth: u32 = 1;
            while (depth > 0) {
                const c0 = self.peekByte(0);
                const c1 = self.peekByte(1);
                if (c0 == @as(?u8, '/') and c1 == @as(?u8, '*')) {
                    self.pos += 2;
                    depth += 1;
                } else if (c0 == @as(?u8, '*') and c1 == @as(?u8, '/')) {
                    self.pos += 2;
                    depth -= 1;
                } else if (c0 != null) {
                    _ = self.bumpChar();
                } else {
                    var d = Diagnostic.err("unterminated block comment", self.span(start));
                    _ = d.withCode("E0020");
                    try self.emit(d);
                    break;
                }
            }
            return .{ .kind = .BlockComment, .span = self.span(start) };
        }

        // Strings.
        if (b == '"') {
            // triple-quoted raw string?
            if (self.peekByte(1) == @as(?u8, '"') and self.peekByte(2) == @as(?u8, '"')) {
                self.pos += 3;
                try self.modes.append(self.allocator, .StringRaw);
                return .{ .kind = .{ .StringQuote = .{ .triple = true } }, .span = self.span(start) };
            }
            self.pos += 1;
            try self.modes.append(self.allocator, .StringRegular);
            return .{ .kind = .{ .StringQuote = .{ .triple = false } }, .span = self.span(start) };
        }

        // Char literal.
        if (b == '\'') {
            return self.lexCharLiteral(start);
        }

        // Interp mode: track braces so a closing `}` can leave the template.
        switch (self.currentMode()) {
            .Interp => |interp| {
                if (b == '}' and interp.brace_depth == 0) {
                    self.pos += 1;
                    _ = self.modes.pop();
                    return .{ .kind = .InterpEnd, .span = self.span(start) };
                }
                if (b == '{') {
                    self.bumpInterpBrace(1);
                } else if (b == '}') {
                    self.bumpInterpBrace(-1);
                }
            },
            else => {},
        }

        // Numbers.
        if (std.ascii.isDigit(b)) {
            return self.lexNumber(start);
        }

        // Punctuation / operators.
        if (try self.lexPunct(start)) |tok| {
            return tok;
        }

        // Backtick-escaped identifier: `…` admits any character except backtick,
        // newline, CR, or NUL. The identifier carries the backticks in its span;
        // the parser strips them when materializing names.
        if (b == '`') {
            return self.lexBacktickIdent(start);
        }

        // Identifiers / keywords. Unicode XID for the start; ASCII fast path first.
        if (isIdentStartByte(b) or isXidStartChar(self.peekChar())) {
            return self.lexIdentOrKeyword(start);
        }

        // Unknown.
        _ = self.bumpChar();
        const msg = try self.allocMessage("unexpected character `{s}`", .{self.slice(start)});
        var d = Diagnostic.err(msg, self.span(start));
        _ = d.withCode("E0021");
        try self.emit(d);
        return .{ .kind = .Unknown, .span = self.span(start) };
    }

    fn bumpInterpBrace(self: *Lexer, delta: i32) void {
        const top = &self.modes.items[self.modes.items.len - 1];
        switch (top.*) {
            .Interp => |*interp| {
                if (delta > 0) {
                    interp.brace_depth +|= @intCast(@abs(delta));
                } else {
                    interp.brace_depth -|= @intCast(@abs(delta));
                }
            },
            else => {},
        }
    }

    // ---------- identifiers ----------

    fn lexBacktickIdent(self: *Lexer, start: u32) !Token {
        // Consume opening backtick.
        _ = self.bumpChar();
        var closed = false;
        while (self.peekChar()) |c| {
            if (c == '`') {
                _ = self.bumpChar();
                closed = true;
                break;
            }
            if (c == '\n' or c == '\r' or c == 0) break;
            _ = self.bumpChar();
        }
        const sp = self.span(start);
        if (!closed) {
            var d = Diagnostic.err("unterminated backtick identifier", sp);
            _ = d.withCode("E0022");
            try self.emit(d);
        }
        return .{ .kind = .Ident, .span = sp };
    }

    fn lexIdentOrKeyword(self: *Lexer, start: u32) Token {
        // Consume one start char.
        _ = self.bumpChar();
        while (self.peekChar()) |c| {
            if (isIdentContByte(c) or isXidContinue(c)) {
                _ = self.bumpChar();
            } else break;
        }
        const text = self.slice(start);
        const kind: TokenKind = blk: {
            if (std.mem.eql(u8, text, "true")) break :blk .{ .BoolLiteral = true };
            if (std.mem.eql(u8, text, "false")) break :blk .{ .BoolLiteral = false };
            if (std.mem.eql(u8, text, "null")) break :blk .NullLiteral;
            if (Keyword.fromIdent(text)) |kw| break :blk .{ .Keyword = kw };
            break :blk .Ident;
        };
        return .{ .kind = kind, .span = self.span(start) };
    }

    // ---------- numbers ----------

    fn lexNumber(self: *Lexer, start: u32) !Token {
        // Hex / binary?
        if (self.peekByte(0) == @as(?u8, '0')) {
            switch (self.peekByte(1) orelse 0) {
                'x', 'X' => return self.lexRadixInt(start, .Hex),
                'b', 'B' => return self.lexRadixInt(start, .Binary),
                else => {},
            }
        }

        // Decimal integer or float.
        self.eatDigitsWithUnderscores(10);

        var is_float = false;
        // Fractional part, only if followed by a digit (so `1.toString()` still works).
        if (self.peekByte(0) == @as(?u8, '.')) {
            if (self.peekByte(1)) |b1| {
                if (std.ascii.isDigit(b1)) {
                    is_float = true;
                    self.pos += 1; // consume `.`
                    self.eatDigitsWithUnderscores(10);
                }
            }
        }
        // Exponent.
        if (self.peekByte(0) == @as(?u8, 'e') or self.peekByte(0) == @as(?u8, 'E')) {
            is_float = true;
            self.pos += 1;
            if (self.peekByte(0) == @as(?u8, '+') or self.peekByte(0) == @as(?u8, '-')) {
                self.pos += 1;
            }
            const exp_start = self.pos;
            self.eatDigitsWithUnderscores(10);
            if (self.pos == exp_start) {
                var d = Diagnostic.err("missing digits in exponent", self.span(start));
                _ = d.withCode("E0030");
                try self.emit(d);
            }
        }

        // A trailing `f`/`F` (not part of a longer identifier) makes this a Float
        // literal even with no decimal point, e.g. `2f`. Require the next byte to
        // not continue an identifier so `1foo` stays an error rather than `1f`+`oo`.
        if (!is_float) {
            switch (self.peekByte(0) orelse 0) {
                'f', 'F' => {
                    if (!isIdentContByte(self.peekByte(1) orelse 0)) is_float = true;
                },
                else => {},
            }
        }

        if (is_float) {
            const suffix: FloatSuffix = switch (self.peekByte(0) orelse 0) {
                'f', 'F' => blk: {
                    self.pos += 1;
                    break :blk .Float;
                },
                else => .None,
            };
            return .{ .kind = .{ .FloatLiteral = .{ .suffix = suffix } }, .span = self.span(start) };
        } else {
            const suffix = self.lexIntSuffix();
            return .{
                .kind = .{ .IntLiteral = .{ .base = .Decimal, .suffix = suffix } },
                .span = self.span(start),
            };
        }
    }

    fn lexRadixInt(self: *Lexer, start: u32, base: NumBase) !Token {
        self.pos += 2; // 0x / 0b
        const digits_start = self.pos;
        const radix: u8 = switch (base) {
            .Hex => 16,
            .Binary => 2,
            .Decimal => 10,
        };
        self.eatDigitsWithUnderscores(radix);
        if (self.pos == digits_start) {
            var d = Diagnostic.err("missing digits after radix prefix", self.span(start));
            _ = d.withCode("E0031");
            try self.emit(d);
        }
        const suffix = self.lexIntSuffix();
        return .{ .kind = .{ .IntLiteral = .{ .base = base, .suffix = suffix } }, .span = self.span(start) };
    }

    fn lexIntSuffix(self: *Lexer) IntSuffix {
        switch (self.peekByte(0) orelse 0) {
            'L' => {
                self.pos += 1;
                return .Long;
            },
            'u', 'U' => {
                self.pos += 1;
                if (self.peekByte(0) == @as(?u8, 'L')) {
                    self.pos += 1;
                    return .ULong;
                }
                return .UInt;
            },
            else => return .None,
        }
    }

    fn eatDigitsWithUnderscores(self: *Lexer, radix: u8) void {
        while (self.peekByte(0)) |b| {
            if (b == '_' or isDigitRadix(b, radix)) {
                self.pos += 1;
            } else break;
        }
    }

    // ---------- char literal ----------

    fn lexCharLiteral(self: *Lexer, start: u32) !Token {
        self.pos += 1; // opening '
        var ch: u16 = 0xFFFD;
        const first = self.peekByte(0);
        if (first == @as(?u8, '\\')) {
            ch = try self.lexEscape(start);
        } else if (first == @as(?u8, '\'') or first == null) {
            var d = Diagnostic.err("empty character literal", self.span(start));
            _ = d.withCode("E0040").withFactory(&kf.EMPTY_CHARACTER_LITERAL);
            try self.emit(d);
        } else if (first == @as(?u8, '\n')) {
            var d = Diagnostic.err("character literal cannot contain newline", self.span(start));
            _ = d.withCode("E0041").withFactory(&kf.INCORRECT_CHARACTER_LITERAL);
            try self.emit(d);
        } else {
            const c = self.bumpChar() orelse 0xFFFD;
            const cp: u32 = c;
            if (cp > 0xFFFF) {
                // A Kotlin `Char` is one UTF-16 code unit; an astral
                // scalar (e.g. an emoji) cannot be a single `Char`
                // literal, it would need a surrogate pair.
                var d = Diagnostic.err(
                    "character literal must be a single UTF-16 code unit",
                    self.span(start),
                );
                _ = d.withCode("E0041").withFactory(&kf.INCORRECT_CHARACTER_LITERAL);
                try self.emit(d);
            } else {
                // `cp <= 0xFFFF` here, so it is a single UTF-16 code unit.
                ch = @intCast(cp);
            }
        }
        if (self.peekByte(0) == @as(?u8, '\'')) {
            self.pos += 1;
        } else {
            var d = Diagnostic.err("unterminated character literal", self.span(start));
            _ = d.withCode("E0042").withFactory(&kf.INCORRECT_CHARACTER_LITERAL);
            try self.emit(d);
        }
        return .{ .kind = .{ .CharLiteral = ch }, .span = self.span(start) };
    }

    /// Append one UTF-16 code unit produced by a string escape to the
    /// UTF-8 `text` buffer. A high surrogate immediately followed by a
    /// `\uXXXX` low-surrogate escape combines into the astral scalar; an
    /// unpaired surrogate is emitted lossily as U+FFFD, since a UTF-8
    /// string cannot store a lone surrogate.
    fn pushStringUnit(self: *Lexer, text: *std.ArrayList(u8), unit: u16) !void {
        if (unit >= 0xD800 and unit <= 0xDBFF) {
            // High surrogate: try to pair with a following escape.
            if (self.peekByte(0) == @as(?u8, '\\')) {
                const lo = try self.lexEscape(self.pos);
                if (lo >= 0xDC00 and lo <= 0xDFFF) {
                    const c: u32 = 0x10000 + ((@as(u32, unit) - 0xD800) << 10) + (@as(u32, lo) - 0xDC00);
                    try appendCodepoint(text, self.allocator, c);
                } else {
                    try appendCodepoint(text, self.allocator, 0xFFFD);
                    try self.pushStringUnit(text, lo);
                }
            } else {
                try appendCodepoint(text, self.allocator, 0xFFFD);
            }
        } else if (unit >= 0xDC00 and unit <= 0xDFFF) {
            try appendCodepoint(text, self.allocator, 0xFFFD);
        } else {
            try appendCodepoint(text, self.allocator, unit);
        }
    }

    fn lexEscape(self: *Lexer, diag_anchor: u32) !u16 {
        const esc_start = self.pos;
        self.pos += 1; // backslash
        const b = self.peekByte(0) orelse {
            var d = Diagnostic.err("trailing backslash", self.span(diag_anchor));
            _ = d.withCode("E0050").withFactory(&kf.ILLEGAL_ESCAPE);
            try self.emit(d);
            return 0xFFFD;
        };
        self.pos += 1;
        return switch (b) {
            'n' => @as(u16, '\n'),
            't' => @as(u16, '\t'),
            'r' => @as(u16, '\r'),
            'b' => 0x0008,
            '\\' => @as(u16, '\\'),
            '\'' => @as(u16, '\''),
            '"' => @as(u16, '"'),
            '$' => @as(u16, '$'),
            '0' => 0x0000,
            'u' => self.lexUnicodeEscape(esc_start),
            else => blk: {
                const msg = try self.allocMessage("invalid escape sequence `\\{c}`", .{b});
                var d = Diagnostic.err(msg, Span.init(self.file, esc_start, self.pos));
                _ = d.withCode("E0051").withFactory(&kf.ILLEGAL_ESCAPE);
                try self.emit(d);
                break :blk 0xFFFD;
            },
        };
    }

    /// `\uXXXX` is exactly four hex digits, so the value is always in
    /// `0x0000..=0xFFFF`, a single UTF-16 code unit. Surrogates
    /// (`\uD800`..`\uDFFF`) are valid `Char` literals (a Kotlin `Char` is
    /// a code unit, not a scalar), so no scalar-validity check is applied.
    fn lexUnicodeEscape(self: *Lexer, esc_start: u32) !u16 {
        var value: u32 = 0;
        var count: u32 = 0;
        while (count < 4) {
            const b = self.peekByte(0) orelse break;
            if (std.ascii.isHex(b)) {
                value = (value << 4) | hexDigitValue(b);
                self.pos += 1;
                count += 1;
            } else break;
        }
        if (count != 4) {
            var d = Diagnostic.err(
                "expected 4 hex digits after `\\u`",
                Span.init(self.file, esc_start, self.pos),
            );
            _ = d.withCode("E0052").withFactory(&kf.ILLEGAL_ESCAPE);
            try self.emit(d);
            return 0xFFFD;
        }
        return @intCast(value);
    }

    // ---------- punctuation ----------

    fn lexPunct(self: *Lexer, start: u32) !?Token {
        const b0 = self.peekByte(0) orelse return null;
        const b1 = self.peekByte(1);
        const b2 = self.peekByte(2);

        // 3-char ops first.
        const three: ?TokenKind = blk: {
            if (b0 == '=' and b1 == @as(?u8, '=') and b2 == @as(?u8, '=')) break :blk .EqEqEq;
            if (b0 == '!' and b1 == @as(?u8, '=') and b2 == @as(?u8, '=')) break :blk .BangEqEq;
            if (b0 == '.' and b1 == @as(?u8, '.') and b2 == @as(?u8, '<')) break :blk .DotDotLess;
            if (b0 == '.' and b1 == @as(?u8, '.') and b2 == @as(?u8, '.')) break :blk .Reserved;
            break :blk null;
        };
        if (three) |k| {
            self.pos += 3;
            return .{ .kind = k, .span = self.span(start) };
        }

        const two: ?TokenKind = blk: {
            if (b0 == '=' and b1 == @as(?u8, '=')) break :blk .EqEq;
            if (b0 == '!' and b1 == @as(?u8, '=')) break :blk .BangEq;
            if (b0 == '<' and b1 == @as(?u8, '=')) break :blk .Le;
            if (b0 == '>' and b1 == @as(?u8, '=')) break :blk .Ge;
            if (b0 == '&' and b1 == @as(?u8, '&')) break :blk .AmpAmp;
            if (b0 == '|' and b1 == @as(?u8, '|')) break :blk .PipePipe;
            if (b0 == '+' and b1 == @as(?u8, '+')) break :blk .PlusPlus;
            if (b0 == '-' and b1 == @as(?u8, '-')) break :blk .MinusMinus;
            if (b0 == '+' and b1 == @as(?u8, '=')) break :blk .PlusEq;
            if (b0 == '-' and b1 == @as(?u8, '=')) break :blk .MinusEq;
            if (b0 == '*' and b1 == @as(?u8, '=')) break :blk .StarEq;
            if (b0 == '/' and b1 == @as(?u8, '=')) break :blk .SlashEq;
            if (b0 == '%' and b1 == @as(?u8, '=')) break :blk .PercentEq;
            if (b0 == '-' and b1 == @as(?u8, '>')) break :blk .Arrow;
            if (b0 == '=' and b1 == @as(?u8, '>')) break :blk .FatArrow;
            if (b0 == '.' and b1 == @as(?u8, '.')) break :blk .DotDot;
            if (b0 == ':' and b1 == @as(?u8, ':')) break :blk .ColonColon;
            if (b0 == '?' and b1 == @as(?u8, '.')) break :blk .QuestionDot;
            // `?:` is the elvis operator, but `?::` is a `?` (nullable
            // receiver) followed by `::` (callable reference), e.g.
            // `Any?::toString` — do not swallow it as elvis.
            if (b0 == '?' and b1 == @as(?u8, ':') and b2 != @as(?u8, ':')) break :blk .QuestionColon;
            if (b0 == '!' and b1 == @as(?u8, '!')) break :blk .BangBang;
            if (b0 == ';' and b1 == @as(?u8, ';')) break :blk .DoubleSemicolon;
            break :blk null;
        };
        if (two) |k| {
            self.pos += 2;
            return .{ .kind = k, .span = self.span(start) };
        }

        // WS-sensitive single-char tokens.
        if (b0 == '@') {
            self.pos += 1;
            const pre = self.ws_before or self.nl_before;
            const post = self.isAtWsAfter();
            const kind: TokenKind = if (!pre and !post)
                .AtNoWs
            else if (!pre and post)
                .AtPostWs
            else if (pre and !post)
                .AtPreWs
            else
                .AtBothWs;
            return .{ .kind = kind, .span = self.span(start) };
        }
        if (b0 == '?') {
            self.pos += 1;
            const kind: TokenKind = if (self.isQuestExclWsAfter()) .QuestWs else .QuestNoWs;
            return .{ .kind = kind, .span = self.span(start) };
        }
        if (b0 == '!') {
            self.pos += 1;
            const kind: TokenKind = if (self.isQuestExclWsAfter()) .ExclWs else .ExclNoWs;
            return .{ .kind = kind, .span = self.span(start) };
        }

        const one: TokenKind = switch (b0) {
            '(' => .LParen,
            ')' => .RParen,
            '{' => .LBrace,
            '}' => .RBrace,
            '[' => .LBracket,
            ']' => .RBracket,
            ',' => .Comma,
            ';' => .Semicolon,
            ':' => .Colon,
            '.' => .Dot,
            '=' => .Eq,
            '<' => .Lt,
            '>' => .Gt,
            '+' => .Plus,
            '-' => .Minus,
            '*' => .Star,
            '/' => .Slash,
            '%' => .Percent,
            '&' => .Amp,
            '|' => .Pipe,
            '#' => .Hash,
            else => return null,
        };
        self.pos += 1;
        return .{ .kind = one, .span = self.span(start) };
    }

    fn isAtWsAfter(self: *const Lexer) bool {
        const b = self.peekByte(0) orelse return true;
        return switch (b) {
            ' ', '\t', '\r', '\n' => true,
            '/' => self.peekByte(1) == @as(?u8, '/') or self.peekByte(1) == @as(?u8, '*'),
            else => false,
        };
    }

    fn isQuestExclWsAfter(self: *const Lexer) bool {
        const b = self.peekByte(0) orelse return true;
        return switch (b) {
            ' ', '\t', '\r' => true,
            '/' => self.peekByte(1) == @as(?u8, '/') or self.peekByte(1) == @as(?u8, '*'),
            else => false,
        };
    }

    // ---------- strings ----------

    fn flushStringText(
        self: *Lexer,
        tokens: *std.ArrayList(Token),
        text: *std.ArrayList(u8),
        segment_start: u32,
    ) !void {
        if (text.items.len != 0) {
            const owned = try text.toOwnedSlice(self.allocator);
            try tokens.append(self.allocator, .{
                .kind = .{ .StringText = owned },
                .span = Span.init(self.file, segment_start, self.pos),
            });
        }
    }

    fn lexStringBody(self: *Lexer, tokens: *std.ArrayList(Token), raw: bool) !void {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.allocator);
        const segment_start = self.pos;

        while (true) {
            const pos = self.pos;
            const b = self.peekByte(0) orelse {
                try self.flushStringText(tokens, &text, segment_start);
                var d = Diagnostic.err("unterminated string literal", self.span(pos));
                _ = d.withCode("E0060");
                try self.emit(d);
                _ = self.modes.pop();
                return;
            };

            // Closing quote(s).
            if (b == '"') {
                if (raw) {
                    if (self.peekByte(1) == @as(?u8, '"') and self.peekByte(2) == @as(?u8, '"')) {
                        try self.flushStringText(tokens, &text, segment_start);
                        self.pos += 3;
                        try tokens.append(self.allocator, .{
                            .kind = .{ .StringQuote = .{ .triple = true } },
                            .span = Span.init(self.file, self.pos - 3, self.pos),
                        });
                        _ = self.modes.pop();
                        return;
                    }
                    try text.append(self.allocator, '"');
                    self.pos += 1;
                    continue;
                }
                try self.flushStringText(tokens, &text, segment_start);
                self.pos += 1;
                try tokens.append(self.allocator, .{
                    .kind = .{ .StringQuote = .{ .triple = false } },
                    .span = Span.init(self.file, self.pos - 1, self.pos),
                });
                _ = self.modes.pop();
                return;
            }

            // Newline: error in regular strings, allowed in raw.
            if (b == '\n' and !raw) {
                try self.flushStringText(tokens, &text, segment_start);
                var d = Diagnostic.err("newline in regular string literal", self.span(pos));
                _ = d.withCode("E0061");
                try self.emit(d);
                _ = self.modes.pop();
                return;
            }

            // Escapes (regular strings only; raw strings keep `\` verbatim).
            if (b == '\\' and !raw) {
                const ch = try self.lexEscape(pos);
                try self.pushStringUnit(&text, ch);
                continue;
            }

            // Templates.
            if (b == '$') {
                // `${expr}` form.
                if (self.peekByte(1) == @as(?u8, '{')) {
                    try self.flushStringText(tokens, &text, segment_start);
                    const interp_start = self.pos;
                    self.pos += 2;
                    try tokens.append(self.allocator, .{
                        .kind = .InterpStart,
                        .span = Span.init(self.file, interp_start, self.pos),
                    });
                    try self.modes.append(self.allocator, .{ .Interp = .{ .brace_depth = 0 } });
                    return;
                }
                // `$ident` short form.
                if (self.peekByte(1)) |b1| {
                    if (isIdentStartByte(b1)) {
                        try self.flushStringText(tokens, &text, segment_start);
                        const short_start = self.pos;
                        self.pos += 1; // consume `$`
                        const ident_start = self.pos;
                        while (self.peekByte(0)) |c| {
                            if (isIdentContByte(c)) {
                                self.pos += 1;
                            } else break;
                        }
                        const name = try self.allocator.dupe(u8, self.src[ident_start..self.pos]);
                        try tokens.append(self.allocator, .{
                            .kind = .{ .ShortInterp = name },
                            .span = Span.init(self.file, short_start, self.pos),
                        });
                        return;
                    }
                }
                // Lone `$`, literal dollar sign.
                try text.append(self.allocator, '$');
                self.pos += 1;
                continue;
            }

            // Plain char.
            const c = self.bumpChar().?;
            try appendCodepoint(&text, self.allocator, c);
        }
    }
};

fn appendCodepoint(text: *std.ArrayList(u8), allocator: std.mem.Allocator, cp: u32) !void {
    var buf: [4]u8 = undefined;
    const scalar: u21 = if (cp <= 0x10FFFF and !(cp >= 0xD800 and cp <= 0xDFFF))
        @intCast(cp)
    else
        0xFFFD;
    const n = std.unicode.utf8Encode(scalar, &buf) catch blk: {
        const m = std.unicode.utf8Encode(0xFFFD, &buf) catch unreachable;
        break :blk m;
    };
    try text.appendSlice(allocator, buf[0..n]);
}

fn hexDigitValue(b: u8) u32 {
    return switch (b) {
        '0'...'9' => b - '0',
        'a'...'f' => b - 'a' + 10,
        'A'...'F' => b - 'A' + 10,
        else => 0,
    };
}

fn isDigitRadix(b: u8, radix: u8) bool {
    const v: u8 = switch (b) {
        '0'...'9' => b - '0',
        'a'...'z' => b - 'a' + 10,
        'A'...'Z' => b - 'A' + 10,
        else => return false,
    };
    return v < radix;
}

fn isIdentStartByte(b: u8) bool {
    return std.ascii.isAlphabetic(b) or b == '_';
}

fn isIdentContByte(b: u32) bool {
    return switch (b) {
        0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F => true,
        else => false,
    };
}

// ---------- Unicode XID (mirrors unicode-xid 0.2.6, Unicode 16.0.0) ----------

const Range = struct { u32, u32 };

fn bsearchRangeTable(c: u32, table: []const Range) bool {
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = table[mid];
        if (c < r[0]) {
            hi = mid;
        } else if (c > r[1]) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

fn isXidStart(c: u32) bool {
    // Fast-path for ascii idents.
    if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')) return true;
    return c > 0x7F and bsearchRangeTable(c, &xid_start_table);
}

fn isXidContinue(c: u32) bool {
    // Fast-path for ascii idents.
    if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_') return true;
    return c > 0x7F and bsearchRangeTable(c, &xid_continue_table);
}

fn isXidStartChar(c: ?u21) bool {
    return if (c) |cp| isXidStart(cp) else false;
}

const xid_start_table = [_]Range{
    .{ 0x41, 0x5A }, .{ 0x61, 0x7A }, .{ 0xAA, 0xAA }, .{ 0xB5, 0xB5 },
    .{ 0xBA, 0xBA }, .{ 0xC0, 0xD6 }, .{ 0xD8, 0xF6 }, .{ 0xF8, 0x2C1 },
    .{ 0x2C6, 0x2D1 }, .{ 0x2E0, 0x2E4 }, .{ 0x2EC, 0x2EC }, .{ 0x2EE, 0x2EE },
    .{ 0x370, 0x374 }, .{ 0x376, 0x377 }, .{ 0x37B, 0x37D }, .{ 0x37F, 0x37F },
    .{ 0x386, 0x386 }, .{ 0x388, 0x38A }, .{ 0x38C, 0x38C }, .{ 0x38E, 0x3A1 },
    .{ 0x3A3, 0x3F5 }, .{ 0x3F7, 0x481 }, .{ 0x48A, 0x52F }, .{ 0x531, 0x556 },
    .{ 0x559, 0x559 }, .{ 0x560, 0x588 }, .{ 0x5D0, 0x5EA }, .{ 0x5EF, 0x5F2 },
    .{ 0x620, 0x64A }, .{ 0x66E, 0x66F }, .{ 0x671, 0x6D3 }, .{ 0x6D5, 0x6D5 },
    .{ 0x6E5, 0x6E6 }, .{ 0x6EE, 0x6EF }, .{ 0x6FA, 0x6FC }, .{ 0x6FF, 0x6FF },
    .{ 0x710, 0x710 }, .{ 0x712, 0x72F }, .{ 0x74D, 0x7A5 }, .{ 0x7B1, 0x7B1 },
    .{ 0x7CA, 0x7EA }, .{ 0x7F4, 0x7F5 }, .{ 0x7FA, 0x7FA }, .{ 0x800, 0x815 },
    .{ 0x81A, 0x81A }, .{ 0x824, 0x824 }, .{ 0x828, 0x828 }, .{ 0x840, 0x858 },
    .{ 0x860, 0x86A }, .{ 0x870, 0x887 }, .{ 0x889, 0x88E }, .{ 0x8A0, 0x8C9 },
    .{ 0x904, 0x939 }, .{ 0x93D, 0x93D }, .{ 0x950, 0x950 }, .{ 0x958, 0x961 },
    .{ 0x971, 0x980 }, .{ 0x985, 0x98C }, .{ 0x98F, 0x990 }, .{ 0x993, 0x9A8 },
    .{ 0x9AA, 0x9B0 }, .{ 0x9B2, 0x9B2 }, .{ 0x9B6, 0x9B9 }, .{ 0x9BD, 0x9BD },
    .{ 0x9CE, 0x9CE }, .{ 0x9DC, 0x9DD }, .{ 0x9DF, 0x9E1 }, .{ 0x9F0, 0x9F1 },
    .{ 0x9FC, 0x9FC }, .{ 0xA05, 0xA0A }, .{ 0xA0F, 0xA10 }, .{ 0xA13, 0xA28 },
    .{ 0xA2A, 0xA30 }, .{ 0xA32, 0xA33 }, .{ 0xA35, 0xA36 }, .{ 0xA38, 0xA39 },
    .{ 0xA59, 0xA5C }, .{ 0xA5E, 0xA5E }, .{ 0xA72, 0xA74 }, .{ 0xA85, 0xA8D },
    .{ 0xA8F, 0xA91 }, .{ 0xA93, 0xAA8 }, .{ 0xAAA, 0xAB0 }, .{ 0xAB2, 0xAB3 },
    .{ 0xAB5, 0xAB9 }, .{ 0xABD, 0xABD }, .{ 0xAD0, 0xAD0 }, .{ 0xAE0, 0xAE1 },
    .{ 0xAF9, 0xAF9 }, .{ 0xB05, 0xB0C }, .{ 0xB0F, 0xB10 }, .{ 0xB13, 0xB28 },
    .{ 0xB2A, 0xB30 }, .{ 0xB32, 0xB33 }, .{ 0xB35, 0xB39 }, .{ 0xB3D, 0xB3D },
    .{ 0xB5C, 0xB5D }, .{ 0xB5F, 0xB61 }, .{ 0xB71, 0xB71 }, .{ 0xB83, 0xB83 },
    .{ 0xB85, 0xB8A }, .{ 0xB8E, 0xB90 }, .{ 0xB92, 0xB95 }, .{ 0xB99, 0xB9A },
    .{ 0xB9C, 0xB9C }, .{ 0xB9E, 0xB9F }, .{ 0xBA3, 0xBA4 }, .{ 0xBA8, 0xBAA },
    .{ 0xBAE, 0xBB9 }, .{ 0xBD0, 0xBD0 }, .{ 0xC05, 0xC0C }, .{ 0xC0E, 0xC10 },
    .{ 0xC12, 0xC28 }, .{ 0xC2A, 0xC39 }, .{ 0xC3D, 0xC3D }, .{ 0xC58, 0xC5A },
    .{ 0xC5D, 0xC5D }, .{ 0xC60, 0xC61 }, .{ 0xC80, 0xC80 }, .{ 0xC85, 0xC8C },
    .{ 0xC8E, 0xC90 }, .{ 0xC92, 0xCA8 }, .{ 0xCAA, 0xCB3 }, .{ 0xCB5, 0xCB9 },
    .{ 0xCBD, 0xCBD }, .{ 0xCDD, 0xCDE }, .{ 0xCE0, 0xCE1 }, .{ 0xCF1, 0xCF2 },
    .{ 0xD04, 0xD0C }, .{ 0xD0E, 0xD10 }, .{ 0xD12, 0xD3A }, .{ 0xD3D, 0xD3D },
    .{ 0xD4E, 0xD4E }, .{ 0xD54, 0xD56 }, .{ 0xD5F, 0xD61 }, .{ 0xD7A, 0xD7F },
    .{ 0xD85, 0xD96 }, .{ 0xD9A, 0xDB1 }, .{ 0xDB3, 0xDBB }, .{ 0xDBD, 0xDBD },
    .{ 0xDC0, 0xDC6 }, .{ 0xE01, 0xE30 }, .{ 0xE32, 0xE32 }, .{ 0xE40, 0xE46 },
    .{ 0xE81, 0xE82 }, .{ 0xE84, 0xE84 }, .{ 0xE86, 0xE8A }, .{ 0xE8C, 0xEA3 },
    .{ 0xEA5, 0xEA5 }, .{ 0xEA7, 0xEB0 }, .{ 0xEB2, 0xEB2 }, .{ 0xEBD, 0xEBD },
    .{ 0xEC0, 0xEC4 }, .{ 0xEC6, 0xEC6 }, .{ 0xEDC, 0xEDF }, .{ 0xF00, 0xF00 },
    .{ 0xF40, 0xF47 }, .{ 0xF49, 0xF6C }, .{ 0xF88, 0xF8C }, .{ 0x1000, 0x102A },
    .{ 0x103F, 0x103F }, .{ 0x1050, 0x1055 }, .{ 0x105A, 0x105D }, .{ 0x1061, 0x1061 },
    .{ 0x1065, 0x1066 }, .{ 0x106E, 0x1070 }, .{ 0x1075, 0x1081 }, .{ 0x108E, 0x108E },
    .{ 0x10A0, 0x10C5 }, .{ 0x10C7, 0x10C7 }, .{ 0x10CD, 0x10CD }, .{ 0x10D0, 0x10FA },
    .{ 0x10FC, 0x1248 }, .{ 0x124A, 0x124D }, .{ 0x1250, 0x1256 }, .{ 0x1258, 0x1258 },
    .{ 0x125A, 0x125D }, .{ 0x1260, 0x1288 }, .{ 0x128A, 0x128D }, .{ 0x1290, 0x12B0 },
    .{ 0x12B2, 0x12B5 }, .{ 0x12B8, 0x12BE }, .{ 0x12C0, 0x12C0 }, .{ 0x12C2, 0x12C5 },
    .{ 0x12C8, 0x12D6 }, .{ 0x12D8, 0x1310 }, .{ 0x1312, 0x1315 }, .{ 0x1318, 0x135A },
    .{ 0x1380, 0x138F }, .{ 0x13A0, 0x13F5 }, .{ 0x13F8, 0x13FD }, .{ 0x1401, 0x166C },
    .{ 0x166F, 0x167F }, .{ 0x1681, 0x169A }, .{ 0x16A0, 0x16EA }, .{ 0x16EE, 0x16F8 },
    .{ 0x1700, 0x1711 }, .{ 0x171F, 0x1731 }, .{ 0x1740, 0x1751 }, .{ 0x1760, 0x176C },
    .{ 0x176E, 0x1770 }, .{ 0x1780, 0x17B3 }, .{ 0x17D7, 0x17D7 }, .{ 0x17DC, 0x17DC },
    .{ 0x1820, 0x1878 }, .{ 0x1880, 0x18A8 }, .{ 0x18AA, 0x18AA }, .{ 0x18B0, 0x18F5 },
    .{ 0x1900, 0x191E }, .{ 0x1950, 0x196D }, .{ 0x1970, 0x1974 }, .{ 0x1980, 0x19AB },
    .{ 0x19B0, 0x19C9 }, .{ 0x1A00, 0x1A16 }, .{ 0x1A20, 0x1A54 }, .{ 0x1AA7, 0x1AA7 },
    .{ 0x1B05, 0x1B33 }, .{ 0x1B45, 0x1B4C }, .{ 0x1B83, 0x1BA0 }, .{ 0x1BAE, 0x1BAF },
    .{ 0x1BBA, 0x1BE5 }, .{ 0x1C00, 0x1C23 }, .{ 0x1C4D, 0x1C4F }, .{ 0x1C5A, 0x1C7D },
    .{ 0x1C80, 0x1C8A }, .{ 0x1C90, 0x1CBA }, .{ 0x1CBD, 0x1CBF }, .{ 0x1CE9, 0x1CEC },
    .{ 0x1CEE, 0x1CF3 }, .{ 0x1CF5, 0x1CF6 }, .{ 0x1CFA, 0x1CFA }, .{ 0x1D00, 0x1DBF },
    .{ 0x1E00, 0x1F15 }, .{ 0x1F18, 0x1F1D }, .{ 0x1F20, 0x1F45 }, .{ 0x1F48, 0x1F4D },
    .{ 0x1F50, 0x1F57 }, .{ 0x1F59, 0x1F59 }, .{ 0x1F5B, 0x1F5B }, .{ 0x1F5D, 0x1F5D },
    .{ 0x1F5F, 0x1F7D }, .{ 0x1F80, 0x1FB4 }, .{ 0x1FB6, 0x1FBC }, .{ 0x1FBE, 0x1FBE },
    .{ 0x1FC2, 0x1FC4 }, .{ 0x1FC6, 0x1FCC }, .{ 0x1FD0, 0x1FD3 }, .{ 0x1FD6, 0x1FDB },
    .{ 0x1FE0, 0x1FEC }, .{ 0x1FF2, 0x1FF4 }, .{ 0x1FF6, 0x1FFC }, .{ 0x2071, 0x2071 },
    .{ 0x207F, 0x207F }, .{ 0x2090, 0x209C }, .{ 0x2102, 0x2102 }, .{ 0x2107, 0x2107 },
    .{ 0x210A, 0x2113 }, .{ 0x2115, 0x2115 }, .{ 0x2118, 0x211D }, .{ 0x2124, 0x2124 },
    .{ 0x2126, 0x2126 }, .{ 0x2128, 0x2128 }, .{ 0x212A, 0x2139 }, .{ 0x213C, 0x213F },
    .{ 0x2145, 0x2149 }, .{ 0x214E, 0x214E }, .{ 0x2160, 0x2188 }, .{ 0x2C00, 0x2CE4 },
    .{ 0x2CEB, 0x2CEE }, .{ 0x2CF2, 0x2CF3 }, .{ 0x2D00, 0x2D25 }, .{ 0x2D27, 0x2D27 },
    .{ 0x2D2D, 0x2D2D }, .{ 0x2D30, 0x2D67 }, .{ 0x2D6F, 0x2D6F }, .{ 0x2D80, 0x2D96 },
    .{ 0x2DA0, 0x2DA6 }, .{ 0x2DA8, 0x2DAE }, .{ 0x2DB0, 0x2DB6 }, .{ 0x2DB8, 0x2DBE },
    .{ 0x2DC0, 0x2DC6 }, .{ 0x2DC8, 0x2DCE }, .{ 0x2DD0, 0x2DD6 }, .{ 0x2DD8, 0x2DDE },
    .{ 0x3005, 0x3007 }, .{ 0x3021, 0x3029 }, .{ 0x3031, 0x3035 }, .{ 0x3038, 0x303C },
    .{ 0x3041, 0x3096 }, .{ 0x309D, 0x309F }, .{ 0x30A1, 0x30FA }, .{ 0x30FC, 0x30FF },
    .{ 0x3105, 0x312F }, .{ 0x3131, 0x318E }, .{ 0x31A0, 0x31BF }, .{ 0x31F0, 0x31FF },
    .{ 0x3400, 0x4DBF }, .{ 0x4E00, 0xA48C }, .{ 0xA4D0, 0xA4FD }, .{ 0xA500, 0xA60C },
    .{ 0xA610, 0xA61F }, .{ 0xA62A, 0xA62B }, .{ 0xA640, 0xA66E }, .{ 0xA67F, 0xA69D },
    .{ 0xA6A0, 0xA6EF }, .{ 0xA717, 0xA71F }, .{ 0xA722, 0xA788 }, .{ 0xA78B, 0xA7CD },
    .{ 0xA7D0, 0xA7D1 }, .{ 0xA7D3, 0xA7D3 }, .{ 0xA7D5, 0xA7DC }, .{ 0xA7F2, 0xA801 },
    .{ 0xA803, 0xA805 }, .{ 0xA807, 0xA80A }, .{ 0xA80C, 0xA822 }, .{ 0xA840, 0xA873 },
    .{ 0xA882, 0xA8B3 }, .{ 0xA8F2, 0xA8F7 }, .{ 0xA8FB, 0xA8FB }, .{ 0xA8FD, 0xA8FE },
    .{ 0xA90A, 0xA925 }, .{ 0xA930, 0xA946 }, .{ 0xA960, 0xA97C }, .{ 0xA984, 0xA9B2 },
    .{ 0xA9CF, 0xA9CF }, .{ 0xA9E0, 0xA9E4 }, .{ 0xA9E6, 0xA9EF }, .{ 0xA9FA, 0xA9FE },
    .{ 0xAA00, 0xAA28 }, .{ 0xAA40, 0xAA42 }, .{ 0xAA44, 0xAA4B }, .{ 0xAA60, 0xAA76 },
    .{ 0xAA7A, 0xAA7A }, .{ 0xAA7E, 0xAAAF }, .{ 0xAAB1, 0xAAB1 }, .{ 0xAAB5, 0xAAB6 },
    .{ 0xAAB9, 0xAABD }, .{ 0xAAC0, 0xAAC0 }, .{ 0xAAC2, 0xAAC2 }, .{ 0xAADB, 0xAADD },
    .{ 0xAAE0, 0xAAEA }, .{ 0xAAF2, 0xAAF4 }, .{ 0xAB01, 0xAB06 }, .{ 0xAB09, 0xAB0E },
    .{ 0xAB11, 0xAB16 }, .{ 0xAB20, 0xAB26 }, .{ 0xAB28, 0xAB2E }, .{ 0xAB30, 0xAB5A },
    .{ 0xAB5C, 0xAB69 }, .{ 0xAB70, 0xABE2 }, .{ 0xAC00, 0xD7A3 }, .{ 0xD7B0, 0xD7C6 },
    .{ 0xD7CB, 0xD7FB }, .{ 0xF900, 0xFA6D }, .{ 0xFA70, 0xFAD9 }, .{ 0xFB00, 0xFB06 },
    .{ 0xFB13, 0xFB17 }, .{ 0xFB1D, 0xFB1D }, .{ 0xFB1F, 0xFB28 }, .{ 0xFB2A, 0xFB36 },
    .{ 0xFB38, 0xFB3C }, .{ 0xFB3E, 0xFB3E }, .{ 0xFB40, 0xFB41 }, .{ 0xFB43, 0xFB44 },
    .{ 0xFB46, 0xFBB1 }, .{ 0xFBD3, 0xFC5D }, .{ 0xFC64, 0xFD3D }, .{ 0xFD50, 0xFD8F },
    .{ 0xFD92, 0xFDC7 }, .{ 0xFDF0, 0xFDF9 }, .{ 0xFE71, 0xFE71 }, .{ 0xFE73, 0xFE73 },
    .{ 0xFE77, 0xFE77 }, .{ 0xFE79, 0xFE79 }, .{ 0xFE7B, 0xFE7B }, .{ 0xFE7D, 0xFE7D },
    .{ 0xFE7F, 0xFEFC }, .{ 0xFF21, 0xFF3A }, .{ 0xFF41, 0xFF5A }, .{ 0xFF66, 0xFF9D },
    .{ 0xFFA0, 0xFFBE }, .{ 0xFFC2, 0xFFC7 }, .{ 0xFFCA, 0xFFCF }, .{ 0xFFD2, 0xFFD7 },
    .{ 0xFFDA, 0xFFDC }, .{ 0x10000, 0x1000B }, .{ 0x1000D, 0x10026 }, .{ 0x10028, 0x1003A },
    .{ 0x1003C, 0x1003D }, .{ 0x1003F, 0x1004D }, .{ 0x10050, 0x1005D }, .{ 0x10080, 0x100FA },
    .{ 0x10140, 0x10174 }, .{ 0x10280, 0x1029C }, .{ 0x102A0, 0x102D0 }, .{ 0x10300, 0x1031F },
    .{ 0x1032D, 0x1034A }, .{ 0x10350, 0x10375 }, .{ 0x10380, 0x1039D }, .{ 0x103A0, 0x103C3 },
    .{ 0x103C8, 0x103CF }, .{ 0x103D1, 0x103D5 }, .{ 0x10400, 0x1049D }, .{ 0x104B0, 0x104D3 },
    .{ 0x104D8, 0x104FB }, .{ 0x10500, 0x10527 }, .{ 0x10530, 0x10563 }, .{ 0x10570, 0x1057A },
    .{ 0x1057C, 0x1058A }, .{ 0x1058C, 0x10592 }, .{ 0x10594, 0x10595 }, .{ 0x10597, 0x105A1 },
    .{ 0x105A3, 0x105B1 }, .{ 0x105B3, 0x105B9 }, .{ 0x105BB, 0x105BC }, .{ 0x105C0, 0x105F3 },
    .{ 0x10600, 0x10736 }, .{ 0x10740, 0x10755 }, .{ 0x10760, 0x10767 }, .{ 0x10780, 0x10785 },
    .{ 0x10787, 0x107B0 }, .{ 0x107B2, 0x107BA }, .{ 0x10800, 0x10805 }, .{ 0x10808, 0x10808 },
    .{ 0x1080A, 0x10835 }, .{ 0x10837, 0x10838 }, .{ 0x1083C, 0x1083C }, .{ 0x1083F, 0x10855 },
    .{ 0x10860, 0x10876 }, .{ 0x10880, 0x1089E }, .{ 0x108E0, 0x108F2 }, .{ 0x108F4, 0x108F5 },
    .{ 0x10900, 0x10915 }, .{ 0x10920, 0x10939 }, .{ 0x10980, 0x109B7 }, .{ 0x109BE, 0x109BF },
    .{ 0x10A00, 0x10A00 }, .{ 0x10A10, 0x10A13 }, .{ 0x10A15, 0x10A17 }, .{ 0x10A19, 0x10A35 },
    .{ 0x10A60, 0x10A7C }, .{ 0x10A80, 0x10A9C }, .{ 0x10AC0, 0x10AC7 }, .{ 0x10AC9, 0x10AE4 },
    .{ 0x10B00, 0x10B35 }, .{ 0x10B40, 0x10B55 }, .{ 0x10B60, 0x10B72 }, .{ 0x10B80, 0x10B91 },
    .{ 0x10C00, 0x10C48 }, .{ 0x10C80, 0x10CB2 }, .{ 0x10CC0, 0x10CF2 }, .{ 0x10D00, 0x10D23 },
    .{ 0x10D4A, 0x10D65 }, .{ 0x10D6F, 0x10D85 }, .{ 0x10E80, 0x10EA9 }, .{ 0x10EB0, 0x10EB1 },
    .{ 0x10EC2, 0x10EC4 }, .{ 0x10F00, 0x10F1C }, .{ 0x10F27, 0x10F27 }, .{ 0x10F30, 0x10F45 },
    .{ 0x10F70, 0x10F81 }, .{ 0x10FB0, 0x10FC4 }, .{ 0x10FE0, 0x10FF6 }, .{ 0x11003, 0x11037 },
    .{ 0x11071, 0x11072 }, .{ 0x11075, 0x11075 }, .{ 0x11083, 0x110AF }, .{ 0x110D0, 0x110E8 },
    .{ 0x11103, 0x11126 }, .{ 0x11144, 0x11144 }, .{ 0x11147, 0x11147 }, .{ 0x11150, 0x11172 },
    .{ 0x11176, 0x11176 }, .{ 0x11183, 0x111B2 }, .{ 0x111C1, 0x111C4 }, .{ 0x111DA, 0x111DA },
    .{ 0x111DC, 0x111DC }, .{ 0x11200, 0x11211 }, .{ 0x11213, 0x1122B }, .{ 0x1123F, 0x11240 },
    .{ 0x11280, 0x11286 }, .{ 0x11288, 0x11288 }, .{ 0x1128A, 0x1128D }, .{ 0x1128F, 0x1129D },
    .{ 0x1129F, 0x112A8 }, .{ 0x112B0, 0x112DE }, .{ 0x11305, 0x1130C }, .{ 0x1130F, 0x11310 },
    .{ 0x11313, 0x11328 }, .{ 0x1132A, 0x11330 }, .{ 0x11332, 0x11333 }, .{ 0x11335, 0x11339 },
    .{ 0x1133D, 0x1133D }, .{ 0x11350, 0x11350 }, .{ 0x1135D, 0x11361 }, .{ 0x11380, 0x11389 },
    .{ 0x1138B, 0x1138B }, .{ 0x1138E, 0x1138E }, .{ 0x11390, 0x113B5 }, .{ 0x113B7, 0x113B7 },
    .{ 0x113D1, 0x113D1 }, .{ 0x113D3, 0x113D3 }, .{ 0x11400, 0x11434 }, .{ 0x11447, 0x1144A },
    .{ 0x1145F, 0x11461 }, .{ 0x11480, 0x114AF }, .{ 0x114C4, 0x114C5 }, .{ 0x114C7, 0x114C7 },
    .{ 0x11580, 0x115AE }, .{ 0x115D8, 0x115DB }, .{ 0x11600, 0x1162F }, .{ 0x11644, 0x11644 },
    .{ 0x11680, 0x116AA }, .{ 0x116B8, 0x116B8 }, .{ 0x11700, 0x1171A }, .{ 0x11740, 0x11746 },
    .{ 0x11800, 0x1182B }, .{ 0x118A0, 0x118DF }, .{ 0x118FF, 0x11906 }, .{ 0x11909, 0x11909 },
    .{ 0x1190C, 0x11913 }, .{ 0x11915, 0x11916 }, .{ 0x11918, 0x1192F }, .{ 0x1193F, 0x1193F },
    .{ 0x11941, 0x11941 }, .{ 0x119A0, 0x119A7 }, .{ 0x119AA, 0x119D0 }, .{ 0x119E1, 0x119E1 },
    .{ 0x119E3, 0x119E3 }, .{ 0x11A00, 0x11A00 }, .{ 0x11A0B, 0x11A32 }, .{ 0x11A3A, 0x11A3A },
    .{ 0x11A50, 0x11A50 }, .{ 0x11A5C, 0x11A89 }, .{ 0x11A9D, 0x11A9D }, .{ 0x11AB0, 0x11AF8 },
    .{ 0x11BC0, 0x11BE0 }, .{ 0x11C00, 0x11C08 }, .{ 0x11C0A, 0x11C2E }, .{ 0x11C40, 0x11C40 },
    .{ 0x11C72, 0x11C8F }, .{ 0x11D00, 0x11D06 }, .{ 0x11D08, 0x11D09 }, .{ 0x11D0B, 0x11D30 },
    .{ 0x11D46, 0x11D46 }, .{ 0x11D60, 0x11D65 }, .{ 0x11D67, 0x11D68 }, .{ 0x11D6A, 0x11D89 },
    .{ 0x11D98, 0x11D98 }, .{ 0x11EE0, 0x11EF2 }, .{ 0x11F02, 0x11F02 }, .{ 0x11F04, 0x11F10 },
    .{ 0x11F12, 0x11F33 }, .{ 0x11FB0, 0x11FB0 }, .{ 0x12000, 0x12399 }, .{ 0x12400, 0x1246E },
    .{ 0x12480, 0x12543 }, .{ 0x12F90, 0x12FF0 }, .{ 0x13000, 0x1342F }, .{ 0x13441, 0x13446 },
    .{ 0x13460, 0x143FA }, .{ 0x14400, 0x14646 }, .{ 0x16100, 0x1611D }, .{ 0x16800, 0x16A38 },
    .{ 0x16A40, 0x16A5E }, .{ 0x16A70, 0x16ABE }, .{ 0x16AD0, 0x16AED }, .{ 0x16B00, 0x16B2F },
    .{ 0x16B40, 0x16B43 }, .{ 0x16B63, 0x16B77 }, .{ 0x16B7D, 0x16B8F }, .{ 0x16D40, 0x16D6C },
    .{ 0x16E40, 0x16E7F }, .{ 0x16F00, 0x16F4A }, .{ 0x16F50, 0x16F50 }, .{ 0x16F93, 0x16F9F },
    .{ 0x16FE0, 0x16FE1 }, .{ 0x16FE3, 0x16FE3 }, .{ 0x17000, 0x187F7 }, .{ 0x18800, 0x18CD5 },
    .{ 0x18CFF, 0x18D08 }, .{ 0x1AFF0, 0x1AFF3 }, .{ 0x1AFF5, 0x1AFFB }, .{ 0x1AFFD, 0x1AFFE },
    .{ 0x1B000, 0x1B122 }, .{ 0x1B132, 0x1B132 }, .{ 0x1B150, 0x1B152 }, .{ 0x1B155, 0x1B155 },
    .{ 0x1B164, 0x1B167 }, .{ 0x1B170, 0x1B2FB }, .{ 0x1BC00, 0x1BC6A }, .{ 0x1BC70, 0x1BC7C },
    .{ 0x1BC80, 0x1BC88 }, .{ 0x1BC90, 0x1BC99 }, .{ 0x1D400, 0x1D454 }, .{ 0x1D456, 0x1D49C },
    .{ 0x1D49E, 0x1D49F }, .{ 0x1D4A2, 0x1D4A2 }, .{ 0x1D4A5, 0x1D4A6 }, .{ 0x1D4A9, 0x1D4AC },
    .{ 0x1D4AE, 0x1D4B9 }, .{ 0x1D4BB, 0x1D4BB }, .{ 0x1D4BD, 0x1D4C3 }, .{ 0x1D4C5, 0x1D505 },
    .{ 0x1D507, 0x1D50A }, .{ 0x1D50D, 0x1D514 }, .{ 0x1D516, 0x1D51C }, .{ 0x1D51E, 0x1D539 },
    .{ 0x1D53B, 0x1D53E }, .{ 0x1D540, 0x1D544 }, .{ 0x1D546, 0x1D546 }, .{ 0x1D54A, 0x1D550 },
    .{ 0x1D552, 0x1D6A5 }, .{ 0x1D6A8, 0x1D6C0 }, .{ 0x1D6C2, 0x1D6DA }, .{ 0x1D6DC, 0x1D6FA },
    .{ 0x1D6FC, 0x1D714 }, .{ 0x1D716, 0x1D734 }, .{ 0x1D736, 0x1D74E }, .{ 0x1D750, 0x1D76E },
    .{ 0x1D770, 0x1D788 }, .{ 0x1D78A, 0x1D7A8 }, .{ 0x1D7AA, 0x1D7C2 }, .{ 0x1D7C4, 0x1D7CB },
    .{ 0x1DF00, 0x1DF1E }, .{ 0x1DF25, 0x1DF2A }, .{ 0x1E030, 0x1E06D }, .{ 0x1E100, 0x1E12C },
    .{ 0x1E137, 0x1E13D }, .{ 0x1E14E, 0x1E14E }, .{ 0x1E290, 0x1E2AD }, .{ 0x1E2C0, 0x1E2EB },
    .{ 0x1E4D0, 0x1E4EB }, .{ 0x1E5D0, 0x1E5ED }, .{ 0x1E5F0, 0x1E5F0 }, .{ 0x1E7E0, 0x1E7E6 },
    .{ 0x1E7E8, 0x1E7EB }, .{ 0x1E7ED, 0x1E7EE }, .{ 0x1E7F0, 0x1E7FE }, .{ 0x1E800, 0x1E8C4 },
    .{ 0x1E900, 0x1E943 }, .{ 0x1E94B, 0x1E94B }, .{ 0x1EE00, 0x1EE03 }, .{ 0x1EE05, 0x1EE1F },
    .{ 0x1EE21, 0x1EE22 }, .{ 0x1EE24, 0x1EE24 }, .{ 0x1EE27, 0x1EE27 }, .{ 0x1EE29, 0x1EE32 },
    .{ 0x1EE34, 0x1EE37 }, .{ 0x1EE39, 0x1EE39 }, .{ 0x1EE3B, 0x1EE3B }, .{ 0x1EE42, 0x1EE42 },
    .{ 0x1EE47, 0x1EE47 }, .{ 0x1EE49, 0x1EE49 }, .{ 0x1EE4B, 0x1EE4B }, .{ 0x1EE4D, 0x1EE4F },
    .{ 0x1EE51, 0x1EE52 }, .{ 0x1EE54, 0x1EE54 }, .{ 0x1EE57, 0x1EE57 }, .{ 0x1EE59, 0x1EE59 },
    .{ 0x1EE5B, 0x1EE5B }, .{ 0x1EE5D, 0x1EE5D }, .{ 0x1EE5F, 0x1EE5F }, .{ 0x1EE61, 0x1EE62 },
    .{ 0x1EE64, 0x1EE64 }, .{ 0x1EE67, 0x1EE6A }, .{ 0x1EE6C, 0x1EE72 }, .{ 0x1EE74, 0x1EE77 },
    .{ 0x1EE79, 0x1EE7C }, .{ 0x1EE7E, 0x1EE7E }, .{ 0x1EE80, 0x1EE89 }, .{ 0x1EE8B, 0x1EE9B },
    .{ 0x1EEA1, 0x1EEA3 }, .{ 0x1EEA5, 0x1EEA9 }, .{ 0x1EEAB, 0x1EEBB }, .{ 0x20000, 0x2A6DF },
    .{ 0x2A700, 0x2B739 }, .{ 0x2B740, 0x2B81D }, .{ 0x2B820, 0x2CEA1 }, .{ 0x2CEB0, 0x2EBE0 },
    .{ 0x2EBF0, 0x2EE5D }, .{ 0x2F800, 0x2FA1D }, .{ 0x30000, 0x3134A }, .{ 0x31350, 0x323AF },
};

const xid_continue_table = [_]Range{
    .{ 0x30, 0x39 }, .{ 0x41, 0x5A }, .{ 0x5F, 0x5F }, .{ 0x61, 0x7A },
    .{ 0xAA, 0xAA }, .{ 0xB5, 0xB5 }, .{ 0xB7, 0xB7 }, .{ 0xBA, 0xBA },
    .{ 0xC0, 0xD6 }, .{ 0xD8, 0xF6 }, .{ 0xF8, 0x2C1 }, .{ 0x2C6, 0x2D1 },
    .{ 0x2E0, 0x2E4 }, .{ 0x2EC, 0x2EC }, .{ 0x2EE, 0x2EE }, .{ 0x300, 0x374 },
    .{ 0x376, 0x377 }, .{ 0x37B, 0x37D }, .{ 0x37F, 0x37F }, .{ 0x386, 0x38A },
    .{ 0x38C, 0x38C }, .{ 0x38E, 0x3A1 }, .{ 0x3A3, 0x3F5 }, .{ 0x3F7, 0x481 },
    .{ 0x483, 0x487 }, .{ 0x48A, 0x52F }, .{ 0x531, 0x556 }, .{ 0x559, 0x559 },
    .{ 0x560, 0x588 }, .{ 0x591, 0x5BD }, .{ 0x5BF, 0x5BF }, .{ 0x5C1, 0x5C2 },
    .{ 0x5C4, 0x5C5 }, .{ 0x5C7, 0x5C7 }, .{ 0x5D0, 0x5EA }, .{ 0x5EF, 0x5F2 },
    .{ 0x610, 0x61A }, .{ 0x620, 0x669 }, .{ 0x66E, 0x6D3 }, .{ 0x6D5, 0x6DC },
    .{ 0x6DF, 0x6E8 }, .{ 0x6EA, 0x6FC }, .{ 0x6FF, 0x6FF }, .{ 0x710, 0x74A },
    .{ 0x74D, 0x7B1 }, .{ 0x7C0, 0x7F5 }, .{ 0x7FA, 0x7FA }, .{ 0x7FD, 0x7FD },
    .{ 0x800, 0x82D }, .{ 0x840, 0x85B }, .{ 0x860, 0x86A }, .{ 0x870, 0x887 },
    .{ 0x889, 0x88E }, .{ 0x897, 0x8E1 }, .{ 0x8E3, 0x963 }, .{ 0x966, 0x96F },
    .{ 0x971, 0x983 }, .{ 0x985, 0x98C }, .{ 0x98F, 0x990 }, .{ 0x993, 0x9A8 },
    .{ 0x9AA, 0x9B0 }, .{ 0x9B2, 0x9B2 }, .{ 0x9B6, 0x9B9 }, .{ 0x9BC, 0x9C4 },
    .{ 0x9C7, 0x9C8 }, .{ 0x9CB, 0x9CE }, .{ 0x9D7, 0x9D7 }, .{ 0x9DC, 0x9DD },
    .{ 0x9DF, 0x9E3 }, .{ 0x9E6, 0x9F1 }, .{ 0x9FC, 0x9FC }, .{ 0x9FE, 0x9FE },
    .{ 0xA01, 0xA03 }, .{ 0xA05, 0xA0A }, .{ 0xA0F, 0xA10 }, .{ 0xA13, 0xA28 },
    .{ 0xA2A, 0xA30 }, .{ 0xA32, 0xA33 }, .{ 0xA35, 0xA36 }, .{ 0xA38, 0xA39 },
    .{ 0xA3C, 0xA3C }, .{ 0xA3E, 0xA42 }, .{ 0xA47, 0xA48 }, .{ 0xA4B, 0xA4D },
    .{ 0xA51, 0xA51 }, .{ 0xA59, 0xA5C }, .{ 0xA5E, 0xA5E }, .{ 0xA66, 0xA75 },
    .{ 0xA81, 0xA83 }, .{ 0xA85, 0xA8D }, .{ 0xA8F, 0xA91 }, .{ 0xA93, 0xAA8 },
    .{ 0xAAA, 0xAB0 }, .{ 0xAB2, 0xAB3 }, .{ 0xAB5, 0xAB9 }, .{ 0xABC, 0xAC5 },
    .{ 0xAC7, 0xAC9 }, .{ 0xACB, 0xACD }, .{ 0xAD0, 0xAD0 }, .{ 0xAE0, 0xAE3 },
    .{ 0xAE6, 0xAEF }, .{ 0xAF9, 0xAFF }, .{ 0xB01, 0xB03 }, .{ 0xB05, 0xB0C },
    .{ 0xB0F, 0xB10 }, .{ 0xB13, 0xB28 }, .{ 0xB2A, 0xB30 }, .{ 0xB32, 0xB33 },
    .{ 0xB35, 0xB39 }, .{ 0xB3C, 0xB44 }, .{ 0xB47, 0xB48 }, .{ 0xB4B, 0xB4D },
    .{ 0xB55, 0xB57 }, .{ 0xB5C, 0xB5D }, .{ 0xB5F, 0xB63 }, .{ 0xB66, 0xB6F },
    .{ 0xB71, 0xB71 }, .{ 0xB82, 0xB83 }, .{ 0xB85, 0xB8A }, .{ 0xB8E, 0xB90 },
    .{ 0xB92, 0xB95 }, .{ 0xB99, 0xB9A }, .{ 0xB9C, 0xB9C }, .{ 0xB9E, 0xB9F },
    .{ 0xBA3, 0xBA4 }, .{ 0xBA8, 0xBAA }, .{ 0xBAE, 0xBB9 }, .{ 0xBBE, 0xBC2 },
    .{ 0xBC6, 0xBC8 }, .{ 0xBCA, 0xBCD }, .{ 0xBD0, 0xBD0 }, .{ 0xBD7, 0xBD7 },
    .{ 0xBE6, 0xBEF }, .{ 0xC00, 0xC0C }, .{ 0xC0E, 0xC10 }, .{ 0xC12, 0xC28 },
    .{ 0xC2A, 0xC39 }, .{ 0xC3C, 0xC44 }, .{ 0xC46, 0xC48 }, .{ 0xC4A, 0xC4D },
    .{ 0xC55, 0xC56 }, .{ 0xC58, 0xC5A }, .{ 0xC5D, 0xC5D }, .{ 0xC60, 0xC63 },
    .{ 0xC66, 0xC6F }, .{ 0xC80, 0xC83 }, .{ 0xC85, 0xC8C }, .{ 0xC8E, 0xC90 },
    .{ 0xC92, 0xCA8 }, .{ 0xCAA, 0xCB3 }, .{ 0xCB5, 0xCB9 }, .{ 0xCBC, 0xCC4 },
    .{ 0xCC6, 0xCC8 }, .{ 0xCCA, 0xCCD }, .{ 0xCD5, 0xCD6 }, .{ 0xCDD, 0xCDE },
    .{ 0xCE0, 0xCE3 }, .{ 0xCE6, 0xCEF }, .{ 0xCF1, 0xCF3 }, .{ 0xD00, 0xD0C },
    .{ 0xD0E, 0xD10 }, .{ 0xD12, 0xD44 }, .{ 0xD46, 0xD48 }, .{ 0xD4A, 0xD4E },
    .{ 0xD54, 0xD57 }, .{ 0xD5F, 0xD63 }, .{ 0xD66, 0xD6F }, .{ 0xD7A, 0xD7F },
    .{ 0xD81, 0xD83 }, .{ 0xD85, 0xD96 }, .{ 0xD9A, 0xDB1 }, .{ 0xDB3, 0xDBB },
    .{ 0xDBD, 0xDBD }, .{ 0xDC0, 0xDC6 }, .{ 0xDCA, 0xDCA }, .{ 0xDCF, 0xDD4 },
    .{ 0xDD6, 0xDD6 }, .{ 0xDD8, 0xDDF }, .{ 0xDE6, 0xDEF }, .{ 0xDF2, 0xDF3 },
    .{ 0xE01, 0xE3A }, .{ 0xE40, 0xE4E }, .{ 0xE50, 0xE59 }, .{ 0xE81, 0xE82 },
    .{ 0xE84, 0xE84 }, .{ 0xE86, 0xE8A }, .{ 0xE8C, 0xEA3 }, .{ 0xEA5, 0xEA5 },
    .{ 0xEA7, 0xEBD }, .{ 0xEC0, 0xEC4 }, .{ 0xEC6, 0xEC6 }, .{ 0xEC8, 0xECE },
    .{ 0xED0, 0xED9 }, .{ 0xEDC, 0xEDF }, .{ 0xF00, 0xF00 }, .{ 0xF18, 0xF19 },
    .{ 0xF20, 0xF29 }, .{ 0xF35, 0xF35 }, .{ 0xF37, 0xF37 }, .{ 0xF39, 0xF39 },
    .{ 0xF3E, 0xF47 }, .{ 0xF49, 0xF6C }, .{ 0xF71, 0xF84 }, .{ 0xF86, 0xF97 },
    .{ 0xF99, 0xFBC }, .{ 0xFC6, 0xFC6 }, .{ 0x1000, 0x1049 }, .{ 0x1050, 0x109D },
    .{ 0x10A0, 0x10C5 }, .{ 0x10C7, 0x10C7 }, .{ 0x10CD, 0x10CD }, .{ 0x10D0, 0x10FA },
    .{ 0x10FC, 0x1248 }, .{ 0x124A, 0x124D }, .{ 0x1250, 0x1256 }, .{ 0x1258, 0x1258 },
    .{ 0x125A, 0x125D }, .{ 0x1260, 0x1288 }, .{ 0x128A, 0x128D }, .{ 0x1290, 0x12B0 },
    .{ 0x12B2, 0x12B5 }, .{ 0x12B8, 0x12BE }, .{ 0x12C0, 0x12C0 }, .{ 0x12C2, 0x12C5 },
    .{ 0x12C8, 0x12D6 }, .{ 0x12D8, 0x1310 }, .{ 0x1312, 0x1315 }, .{ 0x1318, 0x135A },
    .{ 0x135D, 0x135F }, .{ 0x1369, 0x1371 }, .{ 0x1380, 0x138F }, .{ 0x13A0, 0x13F5 },
    .{ 0x13F8, 0x13FD }, .{ 0x1401, 0x166C }, .{ 0x166F, 0x167F }, .{ 0x1681, 0x169A },
    .{ 0x16A0, 0x16EA }, .{ 0x16EE, 0x16F8 }, .{ 0x1700, 0x1715 }, .{ 0x171F, 0x1734 },
    .{ 0x1740, 0x1753 }, .{ 0x1760, 0x176C }, .{ 0x176E, 0x1770 }, .{ 0x1772, 0x1773 },
    .{ 0x1780, 0x17D3 }, .{ 0x17D7, 0x17D7 }, .{ 0x17DC, 0x17DD }, .{ 0x17E0, 0x17E9 },
    .{ 0x180B, 0x180D }, .{ 0x180F, 0x1819 }, .{ 0x1820, 0x1878 }, .{ 0x1880, 0x18AA },
    .{ 0x18B0, 0x18F5 }, .{ 0x1900, 0x191E }, .{ 0x1920, 0x192B }, .{ 0x1930, 0x193B },
    .{ 0x1946, 0x196D }, .{ 0x1970, 0x1974 }, .{ 0x1980, 0x19AB }, .{ 0x19B0, 0x19C9 },
    .{ 0x19D0, 0x19DA }, .{ 0x1A00, 0x1A1B }, .{ 0x1A20, 0x1A5E }, .{ 0x1A60, 0x1A7C },
    .{ 0x1A7F, 0x1A89 }, .{ 0x1A90, 0x1A99 }, .{ 0x1AA7, 0x1AA7 }, .{ 0x1AB0, 0x1ABD },
    .{ 0x1ABF, 0x1ACE }, .{ 0x1B00, 0x1B4C }, .{ 0x1B50, 0x1B59 }, .{ 0x1B6B, 0x1B73 },
    .{ 0x1B80, 0x1BF3 }, .{ 0x1C00, 0x1C37 }, .{ 0x1C40, 0x1C49 }, .{ 0x1C4D, 0x1C7D },
    .{ 0x1C80, 0x1C8A }, .{ 0x1C90, 0x1CBA }, .{ 0x1CBD, 0x1CBF }, .{ 0x1CD0, 0x1CD2 },
    .{ 0x1CD4, 0x1CFA }, .{ 0x1D00, 0x1F15 }, .{ 0x1F18, 0x1F1D }, .{ 0x1F20, 0x1F45 },
    .{ 0x1F48, 0x1F4D }, .{ 0x1F50, 0x1F57 }, .{ 0x1F59, 0x1F59 }, .{ 0x1F5B, 0x1F5B },
    .{ 0x1F5D, 0x1F5D }, .{ 0x1F5F, 0x1F7D }, .{ 0x1F80, 0x1FB4 }, .{ 0x1FB6, 0x1FBC },
    .{ 0x1FBE, 0x1FBE }, .{ 0x1FC2, 0x1FC4 }, .{ 0x1FC6, 0x1FCC }, .{ 0x1FD0, 0x1FD3 },
    .{ 0x1FD6, 0x1FDB }, .{ 0x1FE0, 0x1FEC }, .{ 0x1FF2, 0x1FF4 }, .{ 0x1FF6, 0x1FFC },
    .{ 0x200C, 0x200D }, .{ 0x203F, 0x2040 }, .{ 0x2054, 0x2054 }, .{ 0x2071, 0x2071 },
    .{ 0x207F, 0x207F }, .{ 0x2090, 0x209C }, .{ 0x20D0, 0x20DC }, .{ 0x20E1, 0x20E1 },
    .{ 0x20E5, 0x20F0 }, .{ 0x2102, 0x2102 }, .{ 0x2107, 0x2107 }, .{ 0x210A, 0x2113 },
    .{ 0x2115, 0x2115 }, .{ 0x2118, 0x211D }, .{ 0x2124, 0x2124 }, .{ 0x2126, 0x2126 },
    .{ 0x2128, 0x2128 }, .{ 0x212A, 0x2139 }, .{ 0x213C, 0x213F }, .{ 0x2145, 0x2149 },
    .{ 0x214E, 0x214E }, .{ 0x2160, 0x2188 }, .{ 0x2C00, 0x2CE4 }, .{ 0x2CEB, 0x2CF3 },
    .{ 0x2D00, 0x2D25 }, .{ 0x2D27, 0x2D27 }, .{ 0x2D2D, 0x2D2D }, .{ 0x2D30, 0x2D67 },
    .{ 0x2D6F, 0x2D6F }, .{ 0x2D7F, 0x2D96 }, .{ 0x2DA0, 0x2DA6 }, .{ 0x2DA8, 0x2DAE },
    .{ 0x2DB0, 0x2DB6 }, .{ 0x2DB8, 0x2DBE }, .{ 0x2DC0, 0x2DC6 }, .{ 0x2DC8, 0x2DCE },
    .{ 0x2DD0, 0x2DD6 }, .{ 0x2DD8, 0x2DDE }, .{ 0x2DE0, 0x2DFF }, .{ 0x3005, 0x3007 },
    .{ 0x3021, 0x302F }, .{ 0x3031, 0x3035 }, .{ 0x3038, 0x303C }, .{ 0x3041, 0x3096 },
    .{ 0x3099, 0x309A }, .{ 0x309D, 0x309F }, .{ 0x30A1, 0x30FF }, .{ 0x3105, 0x312F },
    .{ 0x3131, 0x318E }, .{ 0x31A0, 0x31BF }, .{ 0x31F0, 0x31FF }, .{ 0x3400, 0x4DBF },
    .{ 0x4E00, 0xA48C }, .{ 0xA4D0, 0xA4FD }, .{ 0xA500, 0xA60C }, .{ 0xA610, 0xA62B },
    .{ 0xA640, 0xA66F }, .{ 0xA674, 0xA67D }, .{ 0xA67F, 0xA6F1 }, .{ 0xA717, 0xA71F },
    .{ 0xA722, 0xA788 }, .{ 0xA78B, 0xA7CD }, .{ 0xA7D0, 0xA7D1 }, .{ 0xA7D3, 0xA7D3 },
    .{ 0xA7D5, 0xA7DC }, .{ 0xA7F2, 0xA827 }, .{ 0xA82C, 0xA82C }, .{ 0xA840, 0xA873 },
    .{ 0xA880, 0xA8C5 }, .{ 0xA8D0, 0xA8D9 }, .{ 0xA8E0, 0xA8F7 }, .{ 0xA8FB, 0xA8FB },
    .{ 0xA8FD, 0xA92D }, .{ 0xA930, 0xA953 }, .{ 0xA960, 0xA97C }, .{ 0xA980, 0xA9C0 },
    .{ 0xA9CF, 0xA9D9 }, .{ 0xA9E0, 0xA9FE }, .{ 0xAA00, 0xAA36 }, .{ 0xAA40, 0xAA4D },
    .{ 0xAA50, 0xAA59 }, .{ 0xAA60, 0xAA76 }, .{ 0xAA7A, 0xAAC2 }, .{ 0xAADB, 0xAADD },
    .{ 0xAAE0, 0xAAEF }, .{ 0xAAF2, 0xAAF6 }, .{ 0xAB01, 0xAB06 }, .{ 0xAB09, 0xAB0E },
    .{ 0xAB11, 0xAB16 }, .{ 0xAB20, 0xAB26 }, .{ 0xAB28, 0xAB2E }, .{ 0xAB30, 0xAB5A },
    .{ 0xAB5C, 0xAB69 }, .{ 0xAB70, 0xABEA }, .{ 0xABEC, 0xABED }, .{ 0xABF0, 0xABF9 },
    .{ 0xAC00, 0xD7A3 }, .{ 0xD7B0, 0xD7C6 }, .{ 0xD7CB, 0xD7FB }, .{ 0xF900, 0xFA6D },
    .{ 0xFA70, 0xFAD9 }, .{ 0xFB00, 0xFB06 }, .{ 0xFB13, 0xFB17 }, .{ 0xFB1D, 0xFB28 },
    .{ 0xFB2A, 0xFB36 }, .{ 0xFB38, 0xFB3C }, .{ 0xFB3E, 0xFB3E }, .{ 0xFB40, 0xFB41 },
    .{ 0xFB43, 0xFB44 }, .{ 0xFB46, 0xFBB1 }, .{ 0xFBD3, 0xFC5D }, .{ 0xFC64, 0xFD3D },
    .{ 0xFD50, 0xFD8F }, .{ 0xFD92, 0xFDC7 }, .{ 0xFDF0, 0xFDF9 }, .{ 0xFE00, 0xFE0F },
    .{ 0xFE20, 0xFE2F }, .{ 0xFE33, 0xFE34 }, .{ 0xFE4D, 0xFE4F }, .{ 0xFE71, 0xFE71 },
    .{ 0xFE73, 0xFE73 }, .{ 0xFE77, 0xFE77 }, .{ 0xFE79, 0xFE79 }, .{ 0xFE7B, 0xFE7B },
    .{ 0xFE7D, 0xFE7D }, .{ 0xFE7F, 0xFEFC }, .{ 0xFF10, 0xFF19 }, .{ 0xFF21, 0xFF3A },
    .{ 0xFF3F, 0xFF3F }, .{ 0xFF41, 0xFF5A }, .{ 0xFF65, 0xFFBE }, .{ 0xFFC2, 0xFFC7 },
    .{ 0xFFCA, 0xFFCF }, .{ 0xFFD2, 0xFFD7 }, .{ 0xFFDA, 0xFFDC }, .{ 0x10000, 0x1000B },
    .{ 0x1000D, 0x10026 }, .{ 0x10028, 0x1003A }, .{ 0x1003C, 0x1003D }, .{ 0x1003F, 0x1004D },
    .{ 0x10050, 0x1005D }, .{ 0x10080, 0x100FA }, .{ 0x10140, 0x10174 }, .{ 0x101FD, 0x101FD },
    .{ 0x10280, 0x1029C }, .{ 0x102A0, 0x102D0 }, .{ 0x102E0, 0x102E0 }, .{ 0x10300, 0x1031F },
    .{ 0x1032D, 0x1034A }, .{ 0x10350, 0x1037A }, .{ 0x10380, 0x1039D }, .{ 0x103A0, 0x103C3 },
    .{ 0x103C8, 0x103CF }, .{ 0x103D1, 0x103D5 }, .{ 0x10400, 0x1049D }, .{ 0x104A0, 0x104A9 },
    .{ 0x104B0, 0x104D3 }, .{ 0x104D8, 0x104FB }, .{ 0x10500, 0x10527 }, .{ 0x10530, 0x10563 },
    .{ 0x10570, 0x1057A }, .{ 0x1057C, 0x1058A }, .{ 0x1058C, 0x10592 }, .{ 0x10594, 0x10595 },
    .{ 0x10597, 0x105A1 }, .{ 0x105A3, 0x105B1 }, .{ 0x105B3, 0x105B9 }, .{ 0x105BB, 0x105BC },
    .{ 0x105C0, 0x105F3 }, .{ 0x10600, 0x10736 }, .{ 0x10740, 0x10755 }, .{ 0x10760, 0x10767 },
    .{ 0x10780, 0x10785 }, .{ 0x10787, 0x107B0 }, .{ 0x107B2, 0x107BA }, .{ 0x10800, 0x10805 },
    .{ 0x10808, 0x10808 }, .{ 0x1080A, 0x10835 }, .{ 0x10837, 0x10838 }, .{ 0x1083C, 0x1083C },
    .{ 0x1083F, 0x10855 }, .{ 0x10860, 0x10876 }, .{ 0x10880, 0x1089E }, .{ 0x108E0, 0x108F2 },
    .{ 0x108F4, 0x108F5 }, .{ 0x10900, 0x10915 }, .{ 0x10920, 0x10939 }, .{ 0x10980, 0x109B7 },
    .{ 0x109BE, 0x109BF }, .{ 0x10A00, 0x10A03 }, .{ 0x10A05, 0x10A06 }, .{ 0x10A0C, 0x10A13 },
    .{ 0x10A15, 0x10A17 }, .{ 0x10A19, 0x10A35 }, .{ 0x10A38, 0x10A3A }, .{ 0x10A3F, 0x10A3F },
    .{ 0x10A60, 0x10A7C }, .{ 0x10A80, 0x10A9C }, .{ 0x10AC0, 0x10AC7 }, .{ 0x10AC9, 0x10AE6 },
    .{ 0x10B00, 0x10B35 }, .{ 0x10B40, 0x10B55 }, .{ 0x10B60, 0x10B72 }, .{ 0x10B80, 0x10B91 },
    .{ 0x10C00, 0x10C48 }, .{ 0x10C80, 0x10CB2 }, .{ 0x10CC0, 0x10CF2 }, .{ 0x10D00, 0x10D27 },
    .{ 0x10D30, 0x10D39 }, .{ 0x10D40, 0x10D65 }, .{ 0x10D69, 0x10D6D }, .{ 0x10D6F, 0x10D85 },
    .{ 0x10E80, 0x10EA9 }, .{ 0x10EAB, 0x10EAC }, .{ 0x10EB0, 0x10EB1 }, .{ 0x10EC2, 0x10EC4 },
    .{ 0x10EFC, 0x10F1C }, .{ 0x10F27, 0x10F27 }, .{ 0x10F30, 0x10F50 }, .{ 0x10F70, 0x10F85 },
    .{ 0x10FB0, 0x10FC4 }, .{ 0x10FE0, 0x10FF6 }, .{ 0x11000, 0x11046 }, .{ 0x11066, 0x11075 },
    .{ 0x1107F, 0x110BA }, .{ 0x110C2, 0x110C2 }, .{ 0x110D0, 0x110E8 }, .{ 0x110F0, 0x110F9 },
    .{ 0x11100, 0x11134 }, .{ 0x11136, 0x1113F }, .{ 0x11144, 0x11147 }, .{ 0x11150, 0x11173 },
    .{ 0x11176, 0x11176 }, .{ 0x11180, 0x111C4 }, .{ 0x111C9, 0x111CC }, .{ 0x111CE, 0x111DA },
    .{ 0x111DC, 0x111DC }, .{ 0x11200, 0x11211 }, .{ 0x11213, 0x11237 }, .{ 0x1123E, 0x11241 },
    .{ 0x11280, 0x11286 }, .{ 0x11288, 0x11288 }, .{ 0x1128A, 0x1128D }, .{ 0x1128F, 0x1129D },
    .{ 0x1129F, 0x112A8 }, .{ 0x112B0, 0x112EA }, .{ 0x112F0, 0x112F9 }, .{ 0x11300, 0x11303 },
    .{ 0x11305, 0x1130C }, .{ 0x1130F, 0x11310 }, .{ 0x11313, 0x11328 }, .{ 0x1132A, 0x11330 },
    .{ 0x11332, 0x11333 }, .{ 0x11335, 0x11339 }, .{ 0x1133B, 0x11344 }, .{ 0x11347, 0x11348 },
    .{ 0x1134B, 0x1134D }, .{ 0x11350, 0x11350 }, .{ 0x11357, 0x11357 }, .{ 0x1135D, 0x11363 },
    .{ 0x11366, 0x1136C }, .{ 0x11370, 0x11374 }, .{ 0x11380, 0x11389 }, .{ 0x1138B, 0x1138B },
    .{ 0x1138E, 0x1138E }, .{ 0x11390, 0x113B5 }, .{ 0x113B7, 0x113C0 }, .{ 0x113C2, 0x113C2 },
    .{ 0x113C5, 0x113C5 }, .{ 0x113C7, 0x113CA }, .{ 0x113CC, 0x113D3 }, .{ 0x113E1, 0x113E2 },
    .{ 0x11400, 0x1144A }, .{ 0x11450, 0x11459 }, .{ 0x1145E, 0x11461 }, .{ 0x11480, 0x114C5 },
    .{ 0x114C7, 0x114C7 }, .{ 0x114D0, 0x114D9 }, .{ 0x11580, 0x115B5 }, .{ 0x115B8, 0x115C0 },
    .{ 0x115D8, 0x115DD }, .{ 0x11600, 0x11640 }, .{ 0x11644, 0x11644 }, .{ 0x11650, 0x11659 },
    .{ 0x11680, 0x116B8 }, .{ 0x116C0, 0x116C9 }, .{ 0x116D0, 0x116E3 }, .{ 0x11700, 0x1171A },
    .{ 0x1171D, 0x1172B }, .{ 0x11730, 0x11739 }, .{ 0x11740, 0x11746 }, .{ 0x11800, 0x1183A },
    .{ 0x118A0, 0x118E9 }, .{ 0x118FF, 0x11906 }, .{ 0x11909, 0x11909 }, .{ 0x1190C, 0x11913 },
    .{ 0x11915, 0x11916 }, .{ 0x11918, 0x11935 }, .{ 0x11937, 0x11938 }, .{ 0x1193B, 0x11943 },
    .{ 0x11950, 0x11959 }, .{ 0x119A0, 0x119A7 }, .{ 0x119AA, 0x119D7 }, .{ 0x119DA, 0x119E1 },
    .{ 0x119E3, 0x119E4 }, .{ 0x11A00, 0x11A3E }, .{ 0x11A47, 0x11A47 }, .{ 0x11A50, 0x11A99 },
    .{ 0x11A9D, 0x11A9D }, .{ 0x11AB0, 0x11AF8 }, .{ 0x11BC0, 0x11BE0 }, .{ 0x11BF0, 0x11BF9 },
    .{ 0x11C00, 0x11C08 }, .{ 0x11C0A, 0x11C36 }, .{ 0x11C38, 0x11C40 }, .{ 0x11C50, 0x11C59 },
    .{ 0x11C72, 0x11C8F }, .{ 0x11C92, 0x11CA7 }, .{ 0x11CA9, 0x11CB6 }, .{ 0x11D00, 0x11D06 },
    .{ 0x11D08, 0x11D09 }, .{ 0x11D0B, 0x11D36 }, .{ 0x11D3A, 0x11D3A }, .{ 0x11D3C, 0x11D3D },
    .{ 0x11D3F, 0x11D47 }, .{ 0x11D50, 0x11D59 }, .{ 0x11D60, 0x11D65 }, .{ 0x11D67, 0x11D68 },
    .{ 0x11D6A, 0x11D8E }, .{ 0x11D90, 0x11D91 }, .{ 0x11D93, 0x11D98 }, .{ 0x11DA0, 0x11DA9 },
    .{ 0x11EE0, 0x11EF6 }, .{ 0x11F00, 0x11F10 }, .{ 0x11F12, 0x11F3A }, .{ 0x11F3E, 0x11F42 },
    .{ 0x11F50, 0x11F5A }, .{ 0x11FB0, 0x11FB0 }, .{ 0x12000, 0x12399 }, .{ 0x12400, 0x1246E },
    .{ 0x12480, 0x12543 }, .{ 0x12F90, 0x12FF0 }, .{ 0x13000, 0x1342F }, .{ 0x13440, 0x13455 },
    .{ 0x13460, 0x143FA }, .{ 0x14400, 0x14646 }, .{ 0x16100, 0x16139 }, .{ 0x16800, 0x16A38 },
    .{ 0x16A40, 0x16A5E }, .{ 0x16A60, 0x16A69 }, .{ 0x16A70, 0x16ABE }, .{ 0x16AC0, 0x16AC9 },
    .{ 0x16AD0, 0x16AED }, .{ 0x16AF0, 0x16AF4 }, .{ 0x16B00, 0x16B36 }, .{ 0x16B40, 0x16B43 },
    .{ 0x16B50, 0x16B59 }, .{ 0x16B63, 0x16B77 }, .{ 0x16B7D, 0x16B8F }, .{ 0x16D40, 0x16D6C },
    .{ 0x16D70, 0x16D79 }, .{ 0x16E40, 0x16E7F }, .{ 0x16F00, 0x16F4A }, .{ 0x16F4F, 0x16F87 },
    .{ 0x16F8F, 0x16F9F }, .{ 0x16FE0, 0x16FE1 }, .{ 0x16FE3, 0x16FE4 }, .{ 0x16FF0, 0x16FF1 },
    .{ 0x17000, 0x187F7 }, .{ 0x18800, 0x18CD5 }, .{ 0x18CFF, 0x18D08 }, .{ 0x1AFF0, 0x1AFF3 },
    .{ 0x1AFF5, 0x1AFFB }, .{ 0x1AFFD, 0x1AFFE }, .{ 0x1B000, 0x1B122 }, .{ 0x1B132, 0x1B132 },
    .{ 0x1B150, 0x1B152 }, .{ 0x1B155, 0x1B155 }, .{ 0x1B164, 0x1B167 }, .{ 0x1B170, 0x1B2FB },
    .{ 0x1BC00, 0x1BC6A }, .{ 0x1BC70, 0x1BC7C }, .{ 0x1BC80, 0x1BC88 }, .{ 0x1BC90, 0x1BC99 },
    .{ 0x1BC9D, 0x1BC9E }, .{ 0x1CCF0, 0x1CCF9 }, .{ 0x1CF00, 0x1CF2D }, .{ 0x1CF30, 0x1CF46 },
    .{ 0x1D165, 0x1D169 }, .{ 0x1D16D, 0x1D172 }, .{ 0x1D17B, 0x1D182 }, .{ 0x1D185, 0x1D18B },
    .{ 0x1D1AA, 0x1D1AD }, .{ 0x1D242, 0x1D244 }, .{ 0x1D400, 0x1D454 }, .{ 0x1D456, 0x1D49C },
    .{ 0x1D49E, 0x1D49F }, .{ 0x1D4A2, 0x1D4A2 }, .{ 0x1D4A5, 0x1D4A6 }, .{ 0x1D4A9, 0x1D4AC },
    .{ 0x1D4AE, 0x1D4B9 }, .{ 0x1D4BB, 0x1D4BB }, .{ 0x1D4BD, 0x1D4C3 }, .{ 0x1D4C5, 0x1D505 },
    .{ 0x1D507, 0x1D50A }, .{ 0x1D50D, 0x1D514 }, .{ 0x1D516, 0x1D51C }, .{ 0x1D51E, 0x1D539 },
    .{ 0x1D53B, 0x1D53E }, .{ 0x1D540, 0x1D544 }, .{ 0x1D546, 0x1D546 }, .{ 0x1D54A, 0x1D550 },
    .{ 0x1D552, 0x1D6A5 }, .{ 0x1D6A8, 0x1D6C0 }, .{ 0x1D6C2, 0x1D6DA }, .{ 0x1D6DC, 0x1D6FA },
    .{ 0x1D6FC, 0x1D714 }, .{ 0x1D716, 0x1D734 }, .{ 0x1D736, 0x1D74E }, .{ 0x1D750, 0x1D76E },
    .{ 0x1D770, 0x1D788 }, .{ 0x1D78A, 0x1D7A8 }, .{ 0x1D7AA, 0x1D7C2 }, .{ 0x1D7C4, 0x1D7CB },
    .{ 0x1D7CE, 0x1D7FF }, .{ 0x1DA00, 0x1DA36 }, .{ 0x1DA3B, 0x1DA6C }, .{ 0x1DA75, 0x1DA75 },
    .{ 0x1DA84, 0x1DA84 }, .{ 0x1DA9B, 0x1DA9F }, .{ 0x1DAA1, 0x1DAAF }, .{ 0x1DF00, 0x1DF1E },
    .{ 0x1DF25, 0x1DF2A }, .{ 0x1E000, 0x1E006 }, .{ 0x1E008, 0x1E018 }, .{ 0x1E01B, 0x1E021 },
    .{ 0x1E023, 0x1E024 }, .{ 0x1E026, 0x1E02A }, .{ 0x1E030, 0x1E06D }, .{ 0x1E08F, 0x1E08F },
    .{ 0x1E100, 0x1E12C }, .{ 0x1E130, 0x1E13D }, .{ 0x1E140, 0x1E149 }, .{ 0x1E14E, 0x1E14E },
    .{ 0x1E290, 0x1E2AE }, .{ 0x1E2C0, 0x1E2F9 }, .{ 0x1E4D0, 0x1E4F9 }, .{ 0x1E5D0, 0x1E5FA },
    .{ 0x1E7E0, 0x1E7E6 }, .{ 0x1E7E8, 0x1E7EB }, .{ 0x1E7ED, 0x1E7EE }, .{ 0x1E7F0, 0x1E7FE },
    .{ 0x1E800, 0x1E8C4 }, .{ 0x1E8D0, 0x1E8D6 }, .{ 0x1E900, 0x1E94B }, .{ 0x1E950, 0x1E959 },
    .{ 0x1EE00, 0x1EE03 }, .{ 0x1EE05, 0x1EE1F }, .{ 0x1EE21, 0x1EE22 }, .{ 0x1EE24, 0x1EE24 },
    .{ 0x1EE27, 0x1EE27 }, .{ 0x1EE29, 0x1EE32 }, .{ 0x1EE34, 0x1EE37 }, .{ 0x1EE39, 0x1EE39 },
    .{ 0x1EE3B, 0x1EE3B }, .{ 0x1EE42, 0x1EE42 }, .{ 0x1EE47, 0x1EE47 }, .{ 0x1EE49, 0x1EE49 },
    .{ 0x1EE4B, 0x1EE4B }, .{ 0x1EE4D, 0x1EE4F }, .{ 0x1EE51, 0x1EE52 }, .{ 0x1EE54, 0x1EE54 },
    .{ 0x1EE57, 0x1EE57 }, .{ 0x1EE59, 0x1EE59 }, .{ 0x1EE5B, 0x1EE5B }, .{ 0x1EE5D, 0x1EE5D },
    .{ 0x1EE5F, 0x1EE5F }, .{ 0x1EE61, 0x1EE62 }, .{ 0x1EE64, 0x1EE64 }, .{ 0x1EE67, 0x1EE6A },
    .{ 0x1EE6C, 0x1EE72 }, .{ 0x1EE74, 0x1EE77 }, .{ 0x1EE79, 0x1EE7C }, .{ 0x1EE7E, 0x1EE7E },
    .{ 0x1EE80, 0x1EE89 }, .{ 0x1EE8B, 0x1EE9B }, .{ 0x1EEA1, 0x1EEA3 }, .{ 0x1EEA5, 0x1EEA9 },
    .{ 0x1EEAB, 0x1EEBB }, .{ 0x1FBF0, 0x1FBF9 }, .{ 0x20000, 0x2A6DF }, .{ 0x2A700, 0x2B739 },
    .{ 0x2B740, 0x2B81D }, .{ 0x2B820, 0x2CEA1 }, .{ 0x2CEB0, 0x2EBE0 }, .{ 0x2EBF0, 0x2EE5D },
    .{ 0x2F800, 0x2FA1D }, .{ 0x30000, 0x3134A }, .{ 0x31350, 0x323AF }, .{ 0xE0100, 0xE01EF },
};


// ---------- tests ----------

const testing = std.testing;

fn lex(src: []const u8) !LexResult {
    var lexer = try Lexer.init(testing.allocator, FileId.from(0), src);
    return lexer.tokenize();
}

fn kindsAlloc(src: []const u8) !std.ArrayList(TokenKind) {
    var r = try lex(src);
    defer r.deinit(testing.allocator);
    var out: std.ArrayList(TokenKind) = .empty;
    for (r.tokens) |t| try out.append(testing.allocator, t.kind);
    return out;
}

fn isTrivia(k: TokenKind) bool {
    return switch (k) {
        .Whitespace, .Newline, .LineComment, .BlockComment => true,
        else => false,
    };
}

test "empty input emits eof" {
    var r = try lex("");
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), r.tokens.len);
    try testing.expect(r.tokens[0].kind == .Eof);
}

test "fun main println one plus one" {
    var r = try lex("fun main() { println(1 + 1) }");
    defer r.deinit(testing.allocator);
    try testing.expect(!r.diagnostics.hasErrors());
    var drop_trivia: std.ArrayList(TokenKind) = .empty;
    defer drop_trivia.deinit(testing.allocator);
    for (r.tokens) |t| {
        if (!isTrivia(t.kind)) try drop_trivia.append(testing.allocator, t.kind);
    }
    const dt = drop_trivia.items;
    try testing.expect(dt[0] == .Keyword and dt[0].Keyword == .Fun);
    try testing.expect(dt[1] == .Ident);
    try testing.expect(dt[7] == .IntLiteral);
    try testing.expect(dt[8] == .Plus);
    try testing.expect(dt[9] == .IntLiteral);
}

test "nested block comment" {
    var r = try lex("/* outer /* inner */ still outer */ 1");
    defer r.deinit(testing.allocator);
    try testing.expect(!r.diagnostics.hasErrors());
    var last: ?TokenKind = null;
    var i: usize = r.tokens.len;
    while (i > 0) {
        i -= 1;
        const k = r.tokens[i].kind;
        const skip = switch (k) {
            .Whitespace, .BlockComment, .Eof => true,
            else => false,
        };
        if (!skip) {
            last = k;
            break;
        }
    }
    try testing.expect(last.? == .IntLiteral);
}

test "unterminated block comment diag" {
    var r = try lex("/* never closes");
    defer r.deinit(testing.allocator);
    try testing.expect(r.diagnostics.hasErrors());
}

test "numeric suffixes and bases" {
    var ks = try kindsAlloc("0xFF 0b1010 1_000 42L 7u 9UL 3.14 1.5e-3 2.0f");
    defer ks.deinit(testing.allocator);
    var intish: std.ArrayList(TokenKind) = .empty;
    defer intish.deinit(testing.allocator);
    for (ks.items) |k| {
        switch (k) {
            .IntLiteral, .FloatLiteral => try intish.append(testing.allocator, k),
            else => {},
        }
    }
    const it = intish.items;
    try testing.expectEqual(@as(usize, 9), it.len);
    try testing.expect(it[0] == .IntLiteral and it[0].IntLiteral.base == .Hex and it[0].IntLiteral.suffix == .None);
    try testing.expect(it[1] == .IntLiteral and it[1].IntLiteral.base == .Binary and it[1].IntLiteral.suffix == .None);
    try testing.expect(it[3] == .IntLiteral and it[3].IntLiteral.base == .Decimal and it[3].IntLiteral.suffix == .Long);
    try testing.expect(it[4] == .IntLiteral and it[4].IntLiteral.base == .Decimal and it[4].IntLiteral.suffix == .UInt);
    try testing.expect(it[5] == .IntLiteral and it[5].IntLiteral.base == .Decimal and it[5].IntLiteral.suffix == .ULong);
    try testing.expect(it[6] == .FloatLiteral and it[6].FloatLiteral.suffix == .None);
    try testing.expect(it[7] == .FloatLiteral and it[7].FloatLiteral.suffix == .None);
    try testing.expect(it[8] == .FloatLiteral and it[8].FloatLiteral.suffix == .Float);
}

test "integer-form float suffix" {
    // `2f` / `16777218F` (no decimal point) are Float literals.
    var ks = try kindsAlloc("2f 0F 16777218F");
    defer ks.deinit(testing.allocator);
    var fl: std.ArrayList(TokenKind) = .empty;
    defer fl.deinit(testing.allocator);
    for (ks.items) |k| switch (k) {
        .IntLiteral, .FloatLiteral => try fl.append(testing.allocator, k),
        else => {},
    };
    const it = fl.items;
    try testing.expectEqual(@as(usize, 3), it.len);
    for (it) |t| try testing.expect(t == .FloatLiteral and t.FloatLiteral.suffix == .Float);
}

test "digits then identifier is not a float suffix" {
    // `1foo` must not lex as `1f` + `oo`: the trailing `f` continues an
    // identifier, so the number stays an integer and `foo` follows.
    var ks = try kindsAlloc("1foo");
    defer ks.deinit(testing.allocator);
    var sig: std.ArrayList(TokenKind) = .empty;
    defer sig.deinit(testing.allocator);
    for (ks.items) |k| {
        if (!isTrivia(k) and k != .Eof) try sig.append(testing.allocator, k);
    }
    try testing.expectEqual(@as(usize, 2), sig.items.len);
    try testing.expect(sig.items[0] == .IntLiteral);
    try testing.expect(sig.items[1] == .Ident);
}

test "float range literal lexes" {
    // `0f..3f` — float literals around a range operator.
    var ks = try kindsAlloc("0f..3f");
    defer ks.deinit(testing.allocator);
    var sig: std.ArrayList(TokenKind) = .empty;
    defer sig.deinit(testing.allocator);
    for (ks.items) |k| {
        if (!isTrivia(k) and k != .Eof) try sig.append(testing.allocator, k);
    }
    try testing.expectEqual(@as(usize, 3), sig.items.len);
    try testing.expect(sig.items[0] == .FloatLiteral and sig.items[0].FloatLiteral.suffix == .Float);
    try testing.expect(sig.items[1] == .DotDot);
    try testing.expect(sig.items[2] == .FloatLiteral and sig.items[2].FloatLiteral.suffix == .Float);
}

test "ops lex greedily" {
    var ks = try kindsAlloc("== === != !== <= >= && || ++ -- += -> ?. ?: !! .. ..< ::");
    defer ks.deinit(testing.allocator);
    var non_trivia: std.ArrayList(TokenKind) = .empty;
    defer non_trivia.deinit(testing.allocator);
    for (ks.items) |k| {
        switch (k) {
            .Whitespace, .Newline, .Eof => {},
            else => try non_trivia.append(testing.allocator, k),
        }
    }
    const expected = [_]std.meta.Tag(TokenKind){
        .EqEq,       .EqEqEq,        .BangEq, .BangEqEq, .Le,    .Ge,
        .AmpAmp,     .PipePipe,      .PlusPlus, .MinusMinus, .PlusEq, .Arrow,
        .QuestionDot, .QuestionColon, .BangBang, .DotDot, .DotDotLess, .ColonColon,
    };
    try testing.expectEqual(expected.len, non_trivia.items.len);
    for (non_trivia.items, expected) |k, e| {
        try testing.expectEqual(e, std.meta.activeTag(k));
    }
}

test "unicode identifier lexes" {
    var r = try lex("val π = 3");
    defer r.deinit(testing.allocator);
    try testing.expect(!r.diagnostics.hasErrors());
    var count: usize = 0;
    for (r.tokens) |t| {
        if (t.kind == .Ident) count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "char literal with escape" {
    var r = try lex("'\\n'");
    defer r.deinit(testing.allocator);
    try testing.expect(!r.diagnostics.hasErrors());
    try testing.expect(r.tokens[0].kind == .CharLiteral and r.tokens[0].kind.CharLiteral == 0x000A);
}

test "char literal unicode escape" {
    var r = try lex("'é'");
    defer r.deinit(testing.allocator);
    try testing.expect(!r.diagnostics.hasErrors());
    try testing.expect(r.tokens[0].kind == .CharLiteral and r.tokens[0].kind.CharLiteral == 0x00E9);
}

test "invalid escape diagnostic" {
    var r = try lex("\"bad \\q escape\"");
    defer r.deinit(testing.allocator);
    try testing.expect(r.diagnostics.hasErrors());
}

test "regular string template short and full" {
    var r = try lex("\"hi $name, age=${age + 1}!\"");
    defer r.deinit(testing.allocator);
    try testing.expect(!r.diagnostics.hasErrors());
    const t = r.tokens;
    var i: usize = 0;
    try testing.expect(t[i].kind == .StringQuote and !t[i].kind.StringQuote.triple);
    i += 1;
    try testing.expect(t[i].kind == .StringText and std.mem.eql(u8, t[i].kind.StringText, "hi "));
    i += 1;
    try testing.expect(t[i].kind == .ShortInterp and std.mem.eql(u8, t[i].kind.ShortInterp, "name"));
    i += 1;
    try testing.expect(t[i].kind == .StringText and std.mem.eql(u8, t[i].kind.StringText, ", age="));
    i += 1;
    try testing.expect(t[i].kind == .InterpStart);
    i += 1;
    try testing.expect(t[i].kind == .Ident);
    i += 1;
    try testing.expect(t[i].kind == .Plus);
    i += 1;
    try testing.expect(t[i].kind == .IntLiteral);
    i += 1;
    try testing.expect(t[i].kind == .InterpEnd);
    i += 1;
    try testing.expect(t[i].kind == .StringText and std.mem.eql(u8, t[i].kind.StringText, "!"));
    i += 1;
    try testing.expect(t[i].kind == .StringQuote and !t[i].kind.StringQuote.triple);
}

test "interp with nested braces" {
    var r = try lex("\"${ if (b) { 1 } else { 2 } }\"");
    defer r.deinit(testing.allocator);
    try testing.expect(!r.diagnostics.hasErrors());
    var interp_ends: usize = 0;
    var starts: usize = 0;
    for (r.tokens) |t| {
        switch (t.kind) {
            .InterpEnd => interp_ends += 1,
            .InterpStart => starts += 1,
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 1), interp_ends);
    try testing.expectEqual(@as(usize, 1), starts);
}

test "triple quoted raw string keeps backslashes and newlines" {
    const src = "\"\"\"raw \\n\nliteral $x\"\"\"";
    var r = try lex(src);
    defer r.deinit(testing.allocator);
    try testing.expect(!r.diagnostics.hasErrors());
    var texts: std.ArrayList([]const u8) = .empty;
    defer texts.deinit(testing.allocator);
    for (r.tokens) |t| {
        if (t.kind == .StringText) try texts.append(testing.allocator, t.kind.StringText);
    }
    try testing.expectEqual(@as(usize, 1), texts.items.len);
    try testing.expectEqualStrings("raw \\n\nliteral ", texts.items[0]);
    var has_x = false;
    for (r.tokens) |t| {
        if (t.kind == .ShortInterp and std.mem.eql(u8, t.kind.ShortInterp, "x")) has_x = true;
    }
    try testing.expect(has_x);
}

test "unterminated string diag" {
    var r = try lex("\"never ends");
    defer r.deinit(testing.allocator);
    try testing.expect(r.diagnostics.hasErrors());
}

test "newline in regular string is error" {
    var r = try lex("\"line1\nline2\"");
    defer r.deinit(testing.allocator);
    try testing.expect(r.diagnostics.hasErrors());
}

fn firstNonTrivia(src: []const u8) !std.meta.Tag(TokenKind) {
    var r = try lex(src);
    defer r.deinit(testing.allocator);
    for (r.tokens) |t| {
        const skip = switch (t.kind) {
            .Whitespace, .Newline, .LineComment, .BlockComment, .ShebangLine => true,
            else => false,
        };
        if (!skip) return std.meta.activeTag(t.kind);
    }
    unreachable;
}

const KindPred = *const fn (TokenKind) bool;

fn findKind(src: []const u8, pred: KindPred) !TokenKind {
    var r = try lex(src);
    defer r.deinit(testing.allocator);
    for (r.tokens) |t| {
        if (pred(t.kind)) return t.kind;
    }
    unreachable;
}

test "at ws variants" {
    try testing.expectEqual(std.meta.Tag(TokenKind).AtNoWs, std.meta.activeTag(try findKind("@foo", TokenKind.isAt)));
    try testing.expectEqual(std.meta.Tag(TokenKind).AtPostWs, std.meta.activeTag(try findKind("@ foo", TokenKind.isAt)));
    try testing.expectEqual(std.meta.Tag(TokenKind).AtPreWs, std.meta.activeTag(try findKind("x @foo", TokenKind.isAt)));
    try testing.expectEqual(std.meta.Tag(TokenKind).AtBothWs, std.meta.activeTag(try findKind("x @ foo", TokenKind.isAt)));
    try testing.expectEqual(std.meta.Tag(TokenKind).AtPostWs, std.meta.activeTag(try findKind("@\nfoo", TokenKind.isAt)));
    try testing.expectEqual(std.meta.Tag(TokenKind).AtPreWs, std.meta.activeTag(try findKind("x\n@foo", TokenKind.isAt)));
}

test "question ws variants" {
    try testing.expectEqual(std.meta.Tag(TokenKind).QuestNoWs, std.meta.activeTag(try findKind("a?b", TokenKind.isQuestion)));
    try testing.expectEqual(std.meta.Tag(TokenKind).QuestWs, std.meta.activeTag(try findKind("a? b", TokenKind.isQuestion)));
    try testing.expectEqual(std.meta.Tag(TokenKind).QuestWs, std.meta.activeTag(try findKind("a?", TokenKind.isQuestion)));
}

test "excl ws variants" {
    try testing.expectEqual(std.meta.Tag(TokenKind).ExclNoWs, std.meta.activeTag(try findKind("!a", TokenKind.isBang)));
    try testing.expectEqual(std.meta.Tag(TokenKind).ExclWs, std.meta.activeTag(try findKind("! a", TokenKind.isBang)));
}

test "as safe glue" {
    {
        var r = try lex("x as? Int");
        defer r.deinit(testing.allocator);
        var idx: ?usize = null;
        for (r.tokens, 0..) |t, j| {
            if (t.kind == .Keyword and t.kind.Keyword == .As) idx = j;
        }
        const i = idx.?;
        try testing.expect(r.tokens[i + 1].kind.isQuestion());
    }
    {
        var r = try lex("x as?Int");
        defer r.deinit(testing.allocator);
        var idx: ?usize = null;
        for (r.tokens, 0..) |t, j| {
            if (t.kind == .Keyword and t.kind.Keyword == .As) idx = j;
        }
        const i = idx.?;
        try testing.expect(r.tokens[i + 1].kind == .QuestNoWs);
    }
}

test "bang is emits excl no ws before is" {
    var r = try lex("x !is Int");
    defer r.deinit(testing.allocator);
    var non_trivia: std.ArrayList(TokenKind) = .empty;
    defer non_trivia.deinit(testing.allocator);
    for (r.tokens) |t| {
        switch (t.kind) {
            .Whitespace, .Newline, .Eof => {},
            else => try non_trivia.append(testing.allocator, t.kind),
        }
    }
    var idx: ?usize = null;
    for (non_trivia.items, 0..) |k, j| {
        if (k.isBang()) idx = j;
    }
    const i = idx.?;
    try testing.expect(non_trivia.items[i] == .ExclNoWs);
    try testing.expect(non_trivia.items[i + 1] == .Keyword and non_trivia.items[i + 1].Keyword == .Is);
}

test "reserved three dots" {
    try testing.expectEqual(std.meta.Tag(TokenKind).Reserved, try firstNonTrivia("..."));
}

test "double semicolon" {
    try testing.expectEqual(std.meta.Tag(TokenKind).DoubleSemicolon, try firstNonTrivia(";;"));
}

test "hash token" {
    try testing.expectEqual(std.meta.Tag(TokenKind).Hash, try firstNonTrivia("#"));
}

test "shebang consumed as trivia at file start" {
    var r = try lex("#!/usr/bin/env kotlin\nfun main(){}");
    defer r.deinit(testing.allocator);
    var first: ?TokenKind = null;
    for (r.tokens) |t| {
        const skip = switch (t.kind) {
            .Whitespace, .Newline, .LineComment, .BlockComment, .ShebangLine => true,
            else => false,
        };
        if (!skip) {
            first = t.kind;
            break;
        }
    }
    try testing.expect(first.? == .Keyword and first.?.Keyword == .Fun);
}

test "shebang not at start is hash then excl" {
    var r = try lex("foo #!bar");
    defer r.deinit(testing.allocator);
    var has_hash = false;
    var has_bang = false;
    for (r.tokens) |t| {
        if (t.kind == .Hash) has_hash = true;
        if (t.kind.isBang()) has_bang = true;
    }
    try testing.expect(has_hash);
    try testing.expect(has_bang);
}

test "this at label emits at no ws" {
    var r = try lex("this@Outer");
    defer r.deinit(testing.allocator);
    var idx: ?usize = null;
    for (r.tokens, 0..) |t, j| {
        if (t.kind == .Keyword and t.kind.Keyword == .This) idx = j;
    }
    const i = idx.?;
    try testing.expect(r.tokens[i + 1].kind == .AtNoWs);
    try testing.expect(r.tokens[i + 2].kind == .Ident);
}

test "line comment is trivia" {
    var ks = try kindsAlloc("// hi\n1");
    defer ks.deinit(testing.allocator);
    var filtered: std.ArrayList(TokenKind) = .empty;
    defer filtered.deinit(testing.allocator);
    for (ks.items) |k| {
        switch (k) {
            .Whitespace, .Newline, .LineComment => {},
            else => try filtered.append(testing.allocator, k),
        }
    }
    try testing.expectEqual(@as(usize, 2), filtered.items.len);
    try testing.expect(filtered.items[0] == .IntLiteral and
        filtered.items[0].IntLiteral.base == .Decimal and
        filtered.items[0].IntLiteral.suffix == .None);
    try testing.expect(filtered.items[1] == .Eof);
}
