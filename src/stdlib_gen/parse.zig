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

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const ParsedFile = struct {
    package: []const u8,
    decls: []Decl,

    pub fn deinit(self: *ParsedFile, allocator: Allocator) void {
        allocator.free(self.package);
        for (self.decls) |*d| d.deinit(allocator);
        allocator.free(self.decls);
        self.* = undefined;
    }

    pub fn eql(self: ParsedFile, other: ParsedFile) bool {
        if (!std.mem.eql(u8, self.package, other.package)) return false;
        if (self.decls.len != other.decls.len) return false;
        for (self.decls, other.decls) |a, b| {
            if (!a.eql(b)) return false;
        }
        return true;
    }
};

pub const Decl = struct {
    kind: DeclKind,
    name: []const u8,
    /// `kotlin.collections.listOf`. For class members:
    /// `kotlin.collections.List.size`.
    fqn: []const u8,
    /// Containing simple name (class) if any. None for top-level.
    parent: ?[]const u8,
    /// Extension receiver as it appears in source, e.g. `List<T>`.
    receiver: ?[]const u8,
    /// Modifier bitset (mirrors `stdlib.Modifiers`).
    modifiers: u32,
    /// Trimmed single-line signature text.
    signature: []const u8,
    /// Parameter names in declaration order. Empty for properties /
    /// classes / etc. The interpreter uses these to reorder named-arg
    /// calls before dispatching.
    param_names: [][]const u8,
    line: u32,
    column: u32,

    pub fn deinit(self: *Decl, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.fqn);
        if (self.parent) |p| allocator.free(p);
        if (self.receiver) |r| allocator.free(r);
        allocator.free(self.signature);
        for (self.param_names) |p| allocator.free(p);
        allocator.free(self.param_names);
        self.* = undefined;
    }

    pub fn eql(self: Decl, other: Decl) bool {
        if (self.kind != other.kind) return false;
        if (!std.mem.eql(u8, self.name, other.name)) return false;
        if (!std.mem.eql(u8, self.fqn, other.fqn)) return false;
        if (!eqlOptStr(self.parent, other.parent)) return false;
        if (!eqlOptStr(self.receiver, other.receiver)) return false;
        if (self.modifiers != other.modifiers) return false;
        if (!std.mem.eql(u8, self.signature, other.signature)) return false;
        if (self.param_names.len != other.param_names.len) return false;
        for (self.param_names, other.param_names) |a, b| {
            if (!std.mem.eql(u8, a, b)) return false;
        }
        if (self.line != other.line) return false;
        if (self.column != other.column) return false;
        return true;
    }
};

pub const DeclKind = enum {
    Function,
    Property,
    Class,
    Interface,
    Object,
    TypeAlias,
};

pub const Visibility = enum {
    Public,
    Internal,
    Protected,
    Private,
};

// Modifier flag bits (must match `stdlib.Modifiers`).
pub const modflag = struct {
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
};

fn modifierBit(word: []const u8) ?u32 {
    const map = .{
        .{ "public", modflag.PUBLIC },
        .{ "internal", modflag.INTERNAL },
        .{ "protected", modflag.PROTECTED },
        .{ "private", modflag.PRIVATE },
        .{ "open", modflag.OPEN },
        .{ "abstract", modflag.ABSTRACT },
        .{ "final", modflag.FINAL },
        .{ "sealed", modflag.SEALED },
        .{ "inline", modflag.INLINE },
        .{ "infix", modflag.INFIX },
        .{ "operator", modflag.OPERATOR },
        .{ "tailrec", modflag.TAILREC },
        .{ "expect", modflag.EXPECT },
        .{ "actual", modflag.ACTUAL },
        .{ "external", modflag.EXTERNAL },
        .{ "suspend", modflag.SUSPEND },
        .{ "override", modflag.OVERRIDE },
        .{ "data", modflag.DATA },
        .{ "value", modflag.VALUE },
        .{ "enum", modflag.ENUM },
        .{ "annotation", modflag.ANNOTATION },
        .{ "companion", modflag.COMPANION },
        .{ "const", modflag.CONST },
    };
    inline for (map) |pair| {
        if (std.mem.eql(u8, word, pair[0])) return pair[1];
    }
    return null;
}

/// Strip comments, string contents, and char-literal contents from `src`. We
/// replace removed regions with spaces so byte offsets and line numbers are
/// preserved. Newlines are kept verbatim. The caller owns the returned bytes.
fn scrub(allocator: Allocator, src: []const u8) Allocator.Error![]u8 {
    const bytes = src;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, bytes.len);
    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        // Line comment
        if (b == '/' and i + 1 < bytes.len and bytes[i + 1] == '/') {
            while (i < bytes.len and bytes[i] != '\n') {
                try out.append(allocator, ' ');
                i += 1;
            }
            continue;
        }
        // Block comment (nested)
        if (b == '/' and i + 1 < bytes.len and bytes[i + 1] == '*') {
            var depth: i32 = 1;
            try out.append(allocator, ' ');
            try out.append(allocator, ' ');
            i += 2;
            while (i < bytes.len and depth > 0) {
                if (i + 1 < bytes.len and bytes[i] == '/' and bytes[i + 1] == '*') {
                    depth += 1;
                    try out.append(allocator, ' ');
                    try out.append(allocator, ' ');
                    i += 2;
                } else if (i + 1 < bytes.len and bytes[i] == '*' and bytes[i + 1] == '/') {
                    depth -= 1;
                    try out.append(allocator, ' ');
                    try out.append(allocator, ' ');
                    i += 2;
                } else {
                    try out.append(allocator, if (bytes[i] == '\n') '\n' else ' ');
                    i += 1;
                }
            }
            continue;
        }
        // Triple-quoted string
        if (b == '"' and i + 2 < bytes.len and bytes[i + 1] == '"' and bytes[i + 2] == '"') {
            try out.append(allocator, '"');
            try out.append(allocator, '"');
            try out.append(allocator, '"');
            i += 3;
            while (i + 2 < bytes.len and
                !(bytes[i] == '"' and bytes[i + 1] == '"' and bytes[i + 2] == '"'))
            {
                try out.append(allocator, if (bytes[i] == '\n') '\n' else ' ');
                i += 1;
            }
            if (i + 2 < bytes.len) {
                try out.append(allocator, '"');
                try out.append(allocator, '"');
                try out.append(allocator, '"');
                i += 3;
            }
            continue;
        }
        // Regular string
        if (b == '"') {
            try out.append(allocator, '"');
            i += 1;
            while (i < bytes.len and bytes[i] != '"') {
                if (bytes[i] == '\\' and i + 1 < bytes.len) {
                    try out.append(allocator, ' ');
                    try out.append(allocator, ' ');
                    i += 2;
                    continue;
                }
                if (bytes[i] == '\n') {
                    // Unterminated; break to avoid running off.
                    break;
                }
                try out.append(allocator, ' ');
                i += 1;
            }
            if (i < bytes.len and bytes[i] == '"') {
                try out.append(allocator, '"');
                i += 1;
            }
            continue;
        }
        // Char literal
        if (b == '\'') {
            try out.append(allocator, '\'');
            i += 1;
            while (i < bytes.len and bytes[i] != '\'') {
                if (bytes[i] == '\\' and i + 1 < bytes.len) {
                    try out.append(allocator, ' ');
                    try out.append(allocator, ' ');
                    i += 2;
                    continue;
                }
                if (bytes[i] == '\n') {
                    break;
                }
                try out.append(allocator, ' ');
                i += 1;
            }
            if (i < bytes.len and bytes[i] == '\'') {
                try out.append(allocator, '\'');
                i += 1;
            }
            continue;
        }
        try out.append(allocator, b);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

const Tok = union(enum) {
    Ident: []const u8,
    Op: u8,
    /// Multi-char operator we care about.
    OpStr: []const u8,
    /// A balanced `@Annotation(...)` or `@Annotation`. We collapse annotations
    /// into a single token so they don't disturb modifier scanning.
    Annotation,
    /// `<...>` generic block (matched). Used so we can skip type parameter lists.
    Angle: []const u8,
    /// `(...)` parenthesized group, balanced. Used to recognise parameter lists.
    Paren: []const u8,
    /// `[...]` bracket group, balanced.
    Bracket: []const u8,
    /// Number literal (unused but kept for completeness).
    Number: []const u8,
    Newline,
};

const PosTok = struct {
    tok: Tok,
    line: u32,
    col: u32,
};

/// Tokenize scrubbed source into the coarse stream described above. Balanced
/// `()`, `[]`, and (heuristically) `<>` groups are collapsed into a single
/// token containing their raw inner text. We do NOT collapse `{}` so the decl
/// walker can track class bodies.
///
/// Token strings either borrow `src` directly or reference scratch storage
/// owned by `arena`; both outlive the returned slice.
fn tokenize(arena: Allocator, src: []const u8) Allocator.Error![]PosTok {
    const bytes = src;
    var out: std.ArrayList(PosTok) = .empty;
    var i: usize = 0;
    var line: u32 = 1;
    var col: u32 = 1;

    while (i < bytes.len) {
        const b = bytes[i];
        if (b == '\n') {
            try out.append(arena, .{ .tok = .Newline, .line = line, .col = col });
            line += 1;
            col = 1;
            i += 1;
            continue;
        }
        if (std.ascii.isWhitespace(b)) {
            i += 1;
            col += 1;
            continue;
        }
        if (b == '@') {
            const r = consumeAnnotation(bytes, i, line, col);
            i = r.consumed;
            line = r.lines;
            col = r.end_col;
            try out.append(arena, .{ .tok = .Annotation, .line = line, .col = col });
            continue;
        }
        if (isIdentStart(b)) {
            const start = i;
            while (i < bytes.len and isIdentContinue(bytes[i])) {
                i += 1;
                col += 1;
            }
            // Backtick identifiers `foo bar` (not generated by stdlib but cheap).
            const text = src[start..i];
            try out.append(arena, .{
                .tok = .{ .Ident = text },
                .line = line,
                .col = col - @as(u32, @intCast(i - start)),
            });
            continue;
        }
        if (b == '`') {
            const start = i;
            i += 1;
            col += 1;
            while (i < bytes.len and bytes[i] != '`') {
                if (bytes[i] == '\n') break;
                i += 1;
                col += 1;
            }
            if (i < bytes.len and bytes[i] == '`') {
                i += 1;
                col += 1;
            }
            const text = src[start..i];
            try out.append(arena, .{ .tok = .{ .Ident = text }, .line = line, .col = col });
            continue;
        }
        if (std.ascii.isDigit(b)) {
            const start = i;
            while (i < bytes.len and
                (std.ascii.isAlphanumeric(bytes[i]) or bytes[i] == '_' or bytes[i] == '.'))
            {
                i += 1;
                col += 1;
            }
            try out.append(arena, .{ .tok = .{ .Number = src[start..i] }, .line = line, .col = col });
            continue;
        }
        if (b == '(') {
            const r = try balanced(arena, bytes, i, '(', ')', line, col);
            i = r.end;
            line = r.lines;
            col = r.end_col;
            try out.append(arena, .{ .tok = .{ .Paren = r.inner }, .line = line, .col = col });
            continue;
        }
        if (b == '[') {
            const r = try balanced(arena, bytes, i, '[', ']', line, col);
            i = r.end;
            line = r.lines;
            col = r.end_col;
            try out.append(arena, .{ .tok = .{ .Bracket = r.inner }, .line = line, .col = col });
            continue;
        }
        if (b == '<') {
            // Heuristic: only treat as generic-angle if it looks like one. We
            // attempt to find a matching `>` on the same line or within a few
            // identifiers; if not, fall back to an operator.
            if (try tryBalanceAngles(arena, bytes, i, line, col)) |r| {
                i = r.end;
                line = r.end_line;
                col = r.end_col;
                try out.append(arena, .{ .tok = .{ .Angle = r.inner }, .line = line, .col = col });
                continue;
            }
            try out.append(arena, .{ .tok = .{ .Op = '<' }, .line = line, .col = col });
            i += 1;
            col += 1;
            continue;
        }
        // Multi-char operators we care about.
        if (i + 1 < bytes.len) {
            const two = src[i .. i + 2];
            if (std.mem.eql(u8, two, "->") or std.mem.eql(u8, two, "::") or std.mem.eql(u8, two, "..")) {
                const tag: []const u8 = if (std.mem.eql(u8, two, "->"))
                    "->"
                else if (std.mem.eql(u8, two, "::"))
                    "::"
                else
                    "..";
                try out.append(arena, .{ .tok = .{ .OpStr = tag }, .line = line, .col = col });
                i += 2;
                col += 2;
                continue;
            }
        }
        try out.append(arena, .{ .tok = .{ .Op = b }, .line = line, .col = col });
        i += 1;
        col += 1;
    }
    return out.toOwnedSlice(arena);
}

/// Pull parameter names out of a balanced parameter-list body. The
/// tokenizer already gave us the content between `(` and `)`; we split on
/// top-level commas (respecting nested `()`/`[]`/`<>`/`{}`) and for each
/// piece take the last whitespace-separated word before the `:`. The caller
/// owns each returned string and the slice itself.
fn extractParamNames(allocator: Allocator, content: []const u8) Allocator.Error![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    const bytes = content;
    var start: usize = 0;
    var depth_paren: i32 = 0;
    var depth_bracket: i32 = 0;
    var depth_angle: i32 = 0;
    var depth_brace: i32 = 0;
    var i: usize = 0;
    while (i <= bytes.len) : (i += 1) {
        const boundary = i == bytes.len or
            (bytes[i] == ',' and
                depth_paren == 0 and
                depth_bracket == 0 and
                depth_angle == 0 and
                depth_brace == 0);
        if (boundary) {
            if (extractOneParamName(content[start..i])) |name| {
                try names.append(allocator, try allocator.dupe(u8, name));
            }
            start = i + 1;
        } else {
            switch (bytes[i]) {
                '(' => depth_paren += 1,
                ')' => depth_paren -= 1,
                '[' => depth_bracket += 1,
                ']' => depth_bracket -= 1,
                '<' => depth_angle += 1,
                '>' => depth_angle -= 1,
                '{' => depth_brace += 1,
                '}' => depth_brace -= 1,
                else => {},
            }
        }
    }
    return names.toOwnedSlice(allocator);
}

/// Returns a borrowed slice of `piece` (the last name token), or null.
fn extractOneParamName(piece: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, piece, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    // Find the `:` separating the name from the type, ignoring nested
    // generics / function-type arrow brackets.
    var depth: i32 = 0;
    var colon_at: ?usize = null;
    var idx: usize = 0;
    while (idx < trimmed.len) : (idx += 1) {
        const ch = trimmed[idx];
        switch (ch) {
            '<', '[', '(', '{' => depth += 1,
            '>', ']', ')', '}' => depth -= 1,
            ':' => {
                if (depth == 0) {
                    colon_at = idx;
                    break;
                }
            },
            else => {},
        }
    }
    const left = if (colon_at) |c| trimmed[0..c] else trimmed;
    // Last whitespace-separated token is the name (modifiers like
    // `vararg`/`crossinline`/`noinline` may precede it).
    var it = std.mem.tokenizeAny(u8, left, &std.ascii.whitespace);
    var last: ?[]const u8 = null;
    while (it.next()) |w| last = w;
    const word = last orelse return null;
    if (word.len == 0) return null;
    const first = word[0];
    if (std.ascii.isAlphabetic(first) or first == '_') {
        return word;
    }
    return null;
}

fn isIdentStart(b: u8) bool {
    return std.ascii.isAlphabetic(b) or b == '_';
}

fn isIdentContinue(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}

const AnnotationResult = struct {
    consumed: usize,
    lines: u32,
    end_col: u32,
};

fn consumeAnnotation(bytes: []const u8, start: usize, line0: u32, col0: u32) AnnotationResult {
    var i = start;
    var line = line0;
    var col = col0;
    // Eat `@`
    i += 1;
    col += 1;
    // Optional site target: `@file:`, `@get:`, etc.
    var j = i;
    while (j < bytes.len and isIdentContinue(bytes[j])) {
        j += 1;
    }
    if (j < bytes.len and bytes[j] == ':') {
        col += @as(u32, @intCast(j - i)) + 1;
        i = j + 1;
    }
    // Eat a dotted name and possibly an argument list / angle block.
    while (i < bytes.len) {
        const b = bytes[i];
        if (isIdentContinue(b) or b == '.') {
            i += 1;
            col += 1;
        } else {
            break;
        }
    }
    // Possible `<...>` (rare in annotations) or `(...)` argument list.
    if (i < bytes.len and bytes[i] == '(') {
        const r = balancedSpan(bytes, i, '(', ')', line, col);
        i = r.end;
        line = r.lines;
        col = r.end_col;
    }
    return .{ .consumed = i, .lines = line, .end_col = col };
}

const BalancedResult = struct {
    inner: []const u8,
    end: usize,
    lines: u32,
    end_col: u32,
};

fn balanced(
    arena: Allocator,
    bytes: []const u8,
    start: usize,
    open: u8,
    close: u8,
    line0: u32,
    col0: u32,
) Allocator.Error!BalancedResult {
    std.debug.assert(bytes[start] == open);
    var depth: i32 = 0;
    var i = start;
    var line = line0;
    var col = col0;
    const inner_start = start + 1;
    while (i < bytes.len) {
        const b = bytes[i];
        if (b == open) {
            depth += 1;
        } else if (b == close) {
            depth -= 1;
            if (depth == 0) {
                const inner = try arena.dupe(u8, bytes[inner_start..i]);
                return .{ .inner = inner, .end = i + 1, .lines = line, .end_col = col + 1 };
            }
        }
        if (b == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
        i += 1;
    }
    return .{ .inner = try arena.dupe(u8, ""), .end = bytes.len, .lines = line, .end_col = col };
}

const SpanResult = struct {
    end: usize,
    lines: u32,
    end_col: u32,
};

/// Like `balanced` but does not capture the inner text. Used for annotation
/// argument lists where only the end position matters.
fn balancedSpan(
    bytes: []const u8,
    start: usize,
    open: u8,
    close: u8,
    line0: u32,
    col0: u32,
) SpanResult {
    std.debug.assert(bytes[start] == open);
    var depth: i32 = 0;
    var i = start;
    var line = line0;
    var col = col0;
    while (i < bytes.len) {
        const b = bytes[i];
        if (b == open) {
            depth += 1;
        } else if (b == close) {
            depth -= 1;
            if (depth == 0) {
                return .{ .end = i + 1, .lines = line, .end_col = col + 1 };
            }
        }
        if (b == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
        i += 1;
    }
    return .{ .end = bytes.len, .lines = line, .end_col = col };
}

const AngleResult = struct {
    inner: []const u8,
    end: usize,
    end_line: u32,
    end_col: u32,
};

/// Try to read a balanced `<...>` group. We give up if we hit `;`, `{`, `}`, or
/// a newline-with-zero-depth before closing. Required so `a < b` doesn't get
/// misread as a generic.
fn tryBalanceAngles(
    arena: Allocator,
    bytes: []const u8,
    start: usize,
    line0: u32,
    col0: u32,
) Allocator.Error!?AngleResult {
    var depth: i32 = 0;
    var paren: i32 = 0;
    var i = start;
    var line = line0;
    var col = col0;
    const inner_start = start + 1;
    var saw_letter = false;
    while (i < bytes.len) {
        const b = bytes[i];
        switch (b) {
            '<' => depth += 1,
            '>' => {
                depth -= 1;
                if (depth == 0) {
                    if (!saw_letter) return null;
                    const inner = try arena.dupe(u8, bytes[inner_start..i]);
                    return AngleResult{ .inner = inner, .end = i + 1, .end_line = line, .end_col = col + 1 };
                }
            },
            '(' => paren += 1,
            ')' => {
                paren -= 1;
                if (paren < 0) return null;
            },
            '{', '}', ';' => return null,
            '\n' => {
                line += 1;
                col = 1;
                i += 1;
                continue;
            },
            ' ', '\t' => {},
            else => {
                if (std.ascii.isAlphabetic(b) or b == '_') saw_letter = true;
            },
        }
        col += 1;
        i += 1;
    }
    return null;
}

/// Parse `src` into a `ParsedFile`. The returned file (and every string it
/// owns) is allocated with `allocator`; call `ParsedFile.deinit`.
pub fn parseFile(allocator: Allocator, src: []const u8) Allocator.Error!ParsedFile {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const scrubbed = try scrub(arena, src);
    const toks = try tokenize(arena, scrubbed);

    var p = Parser{
        .allocator = allocator,
        .toks = toks,
        .pos = 0,
        .package = "",
        .package_owned = false,
        .decls = .empty,
    };
    errdefer p.cleanup();
    try p.parseTop();

    const package = if (p.package_owned) p.package else try allocator.dupe(u8, p.package);
    return .{
        .package = package,
        .decls = try p.decls.toOwnedSlice(allocator),
    };
}

const Parser = struct {
    allocator: Allocator,
    toks: []const PosTok,
    pos: usize,
    package: []const u8,
    package_owned: bool,
    decls: std.ArrayList(Decl),

    fn cleanup(self: *Parser) void {
        if (self.package_owned) self.allocator.free(self.package);
        for (self.decls.items) |*d| d.deinit(self.allocator);
        self.decls.deinit(self.allocator);
    }

    fn peek(self: *const Parser) ?*const PosTok {
        if (self.pos < self.toks.len) return &self.toks[self.pos];
        return null;
    }

    fn skipNewlines(self: *Parser) void {
        while (self.peek()) |t| {
            if (t.tok == .Newline) {
                self.pos += 1;
            } else break;
        }
    }

    fn skipAnnotationsAndNewlines(self: *Parser) void {
        while (self.peek()) |t| {
            switch (t.tok) {
                .Newline, .Annotation => self.pos += 1,
                else => break,
            }
        }
    }

    fn parseTop(self: *Parser) Allocator.Error!void {
        // Look for `package <dotted>`.
        self.skipAnnotationsAndNewlines();
        if (self.peek()) |t| {
            if (t.tok == .Ident and std.mem.eql(u8, t.tok.Ident, "package")) {
                self.pos += 1;
                self.package = try self.readDottedName();
                self.package_owned = true;
            }
        }
        try self.parseDecls(null);
    }

    fn readDottedName(self: *Parser) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        // names are on one line generally, so no newline/annotation skipping.
        while (self.peek()) |t| {
            switch (t.tok) {
                .Ident => |s| {
                    if (out.items.len != 0 and out.items[out.items.len - 1] != '.') {
                        // Two identifiers in a row -> stop.
                        break;
                    }
                    try out.appendSlice(self.allocator, s);
                    self.pos += 1;
                },
                .Op => |c| {
                    if (c != '.') break;
                    if (out.items.len == 0) break;
                    try out.append(self.allocator, '.');
                    self.pos += 1;
                },
                else => break,
            }
        }
        return out.toOwnedSlice(self.allocator);
    }

    /// Parse declarations until we hit end-of-stream or a `}` (the latter pops
    /// the caller back out of a class body).
    fn parseDecls(self: *Parser, parent: ?[]const u8) Allocator.Error!void {
        while (true) {
            self.skipAnnotationsAndNewlines();
            const t = self.peek() orelse return;
            if (t.tok == .Op and t.tok.Op == '}') {
                self.pos += 1;
                return;
            }
            if (!try self.parseOneDecl(parent)) {
                // Couldn't parse — advance one token to make progress.
                self.pos += 1;
            }
        }
    }

    /// Attempt to parse one declaration starting at the current position.
    /// Returns true on success (cursor advanced past the decl) and false to
    /// indicate the caller should bump and retry.
    fn parseOneDecl(self: *Parser, parent: ?[]const u8) Allocator.Error!bool {
        const start_pos = self.pos;
        var modifiers: u32 = 0;

        // Collect modifiers (idents that are modifier keywords). We stop at
        // the first ident that is not a modifier.
        while (true) {
            self.skipAnnotationsAndNewlines();
            const t = self.peek() orelse return false;
            if (t.tok == .Ident) {
                if (modifierBit(t.tok.Ident)) |bit| {
                    modifiers |= bit;
                    self.pos += 1;
                    continue;
                }
            }
            break;
        }

        const t = self.peek() orelse {
            self.pos = start_pos;
            return false;
        };
        const line = t.line;
        const col = t.col;

        if (t.tok == .Ident) {
            const kw = t.tok.Ident;
            if (std.mem.eql(u8, kw, "fun")) {
                self.pos += 1;
                return self.parseFun(modifiers, line, col, parent);
            } else if (std.mem.eql(u8, kw, "val") or std.mem.eql(u8, kw, "var")) {
                const is_var = std.mem.eql(u8, kw, "var");
                self.pos += 1;
                return self.parseProperty(modifiers, line, col, parent, is_var);
            } else if (std.mem.eql(u8, kw, "class")) {
                self.pos += 1;
                return self.parseClassLike(modifiers, line, col, parent, .Class);
            } else if (std.mem.eql(u8, kw, "interface")) {
                self.pos += 1;
                return self.parseClassLike(modifiers, line, col, parent, .Interface);
            } else if (std.mem.eql(u8, kw, "object")) {
                self.pos += 1;
                return self.parseClassLike(modifiers, line, col, parent, .Object);
            } else if (std.mem.eql(u8, kw, "typealias")) {
                self.pos += 1;
                return self.parseTypealias(modifiers, line, col, parent);
            } else if (std.mem.eql(u8, kw, "constructor")) {
                // Class secondary constructor. Skip parens and any body.
                self.pos += 1;
                self.skipSignatureTail();
                self.skipOptionalBody();
                return true;
            } else if (std.mem.eql(u8, kw, "init")) {
                // Init block. Skip body.
                self.pos += 1;
                self.skipOptionalBody();
                return true;
            } else if (std.mem.eql(u8, kw, "import") or std.mem.eql(u8, kw, "package")) {
                // Eat to newline.
                while (self.peek()) |tk| {
                    if (tk.tok == .Newline) {
                        self.pos += 1;
                        break;
                    }
                    self.pos += 1;
                }
                return true;
            }
            self.pos = start_pos;
            return false;
        }
        if (t.tok == .Op) {
            switch (t.tok.Op) {
                ';' => {
                    self.pos += 1;
                    return true;
                },
                '{' => {
                    // Stray block. Skip it.
                    self.skipBraceBlock();
                    return true;
                },
                else => {},
            }
        }
        self.pos = start_pos;
        return false;
    }

    fn parseFun(self: *Parser, modifiers: u32, line: u32, col: u32, parent: ?[]const u8) Allocator.Error!bool {
        // Optional `<T, ...>` generic params.
        if (self.peek()) |t| {
            if (t.tok == .Angle) self.pos += 1;
        }
        // Optional receiver. Format: `ReceiverType.name(...)` or `ReceiverType<T>.name(...)`.
        const pre_recv = self.pos;
        const rn = try self.readOptionalReceiverAndName();
        const name = rn.name orelse {
            if (rn.receiver) |r| self.allocator.free(r);
            self.pos = pre_recv;
            return false;
        };
        errdefer self.allocator.free(name);
        const receiver = rn.receiver;
        errdefer if (receiver) |r| self.allocator.free(r);

        // Capture the parameter list before walking the rest of the signature.
        // Tokenizer already collapses balanced `(...)` into `Tok::Paren(inner)`.
        var param_names: [][]const u8 = &.{};
        if (self.peek()) |t| {
            if (t.tok == .Paren) {
                param_names = try extractParamNames(self.allocator, t.tok.Paren);
                self.pos += 1;
            }
        }
        errdefer {
            for (param_names) |pn| self.allocator.free(pn);
            self.allocator.free(param_names);
        }

        // Skip the rest of the signature up to either a function body `{...}`,
        // an `= expr` (eaten to newline), or just newline / next decl.
        self.skipSignatureTail();
        self.skipOptionalBody();

        const fqn = try self.buildFqn(parent, name);
        errdefer self.allocator.free(fqn);

        var signature: std.ArrayList(u8) = .empty;
        errdefer signature.deinit(self.allocator);
        try signature.appendSlice(self.allocator, "fun ");
        if (receiver) |r| {
            try signature.appendSlice(self.allocator, r);
            try signature.append(self.allocator, '.');
        }
        try signature.appendSlice(self.allocator, name);

        try self.decls.append(self.allocator, .{
            .kind = .Function,
            .name = name,
            .fqn = fqn,
            .parent = try self.dupParent(parent),
            .receiver = receiver,
            .modifiers = modifiers,
            .signature = try signature.toOwnedSlice(self.allocator),
            .param_names = param_names,
            .line = line,
            .column = col,
        });
        return true;
    }

    fn parseProperty(
        self: *Parser,
        modifiers: u32,
        line: u32,
        col: u32,
        parent: ?[]const u8,
        is_var: bool,
    ) Allocator.Error!bool {
        // Optional `<T>` generic params.
        if (self.peek()) |t| {
            if (t.tok == .Angle) self.pos += 1;
        }
        const pre = self.pos;
        const rn = try self.readOptionalReceiverAndName();
        const name = rn.name orelse {
            if (rn.receiver) |r| self.allocator.free(r);
            self.pos = pre;
            return false;
        };
        errdefer self.allocator.free(name);
        const receiver = rn.receiver;
        errdefer if (receiver) |r| self.allocator.free(r);

        self.skipSignatureTail();
        // A property may also have `get()/set()` accessors as following decls
        // at the same brace level, but the upstream stdlib mostly leaves them
        // as `expect` declarations without bodies. We skip an optional body.
        self.skipOptionalBody();
        // Skip optional accessor blocks. Accessors must literally start with
        // `get` or `set` (a leading visibility on the accessor is uncommon and
        // matching greedy here would steal the next declaration).
        while (true) {
            self.skipAnnotationsAndNewlines();
            const t = self.peek() orelse break;
            if (t.tok == .Ident and (std.mem.eql(u8, t.tok.Ident, "get") or std.mem.eql(u8, t.tok.Ident, "set"))) {
                self.pos += 1;
                if (self.peek()) |t2| {
                    if (t2.tok == .Paren) self.pos += 1;
                }
                self.skipSignatureTail();
                self.skipOptionalBody();
            } else break;
        }

        const kind_word = if (is_var) "var" else "val";
        const fqn = try self.buildFqn(parent, name);
        errdefer self.allocator.free(fqn);

        var signature: std.ArrayList(u8) = .empty;
        errdefer signature.deinit(self.allocator);
        try signature.appendSlice(self.allocator, kind_word);
        try signature.append(self.allocator, ' ');
        if (receiver) |r| {
            try signature.appendSlice(self.allocator, r);
            try signature.append(self.allocator, '.');
        }
        try signature.appendSlice(self.allocator, name);

        try self.decls.append(self.allocator, .{
            .kind = .Property,
            .name = name,
            .fqn = fqn,
            .parent = try self.dupParent(parent),
            .receiver = receiver,
            .modifiers = modifiers,
            .signature = try signature.toOwnedSlice(self.allocator),
            .param_names = &.{},
            .line = line,
            .column = col,
        });
        return true;
    }

    fn parseClassLike(
        self: *Parser,
        modifiers: u32,
        line: u32,
        col: u32,
        parent: ?[]const u8,
        kind: DeclKind,
    ) Allocator.Error!bool {
        // Class name.
        self.skipNewlines();
        const name_tok = self.peek() orelse return false;
        if (name_tok.tok != .Ident) return false;
        const name = try self.allocator.dupe(u8, name_tok.tok.Ident);
        errdefer self.allocator.free(name);
        self.pos += 1;

        // Optional `<T,...>`.
        if (self.peek()) |t| {
            if (t.tok == .Angle) self.pos += 1;
        }
        // Optional primary constructor `(...)`.
        if (self.peek()) |t| {
            if (t.tok == .Paren) self.pos += 1;
        }
        // Skip until `{` or end of decl (newline at brace depth 0).
        self.skipSignatureTail();

        const fqn = try self.buildFqn(parent, name);
        errdefer self.allocator.free(fqn);

        const kind_word: []const u8 = switch (kind) {
            .Class => "class",
            .Interface => "interface",
            .Object => "object",
            else => "?",
        };
        const signature = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ kind_word, name });
        errdefer self.allocator.free(signature);

        try self.decls.append(self.allocator, .{
            .kind = kind,
            .name = name,
            .fqn = fqn,
            .parent = try self.dupParent(parent),
            .receiver = null,
            .modifiers = modifiers,
            .signature = signature,
            .param_names = &.{},
            .line = line,
            .column = col,
        });

        // Optional body.
        self.skipNewlines();
        if (self.peek()) |t| {
            if (t.tok == .Op and t.tok.Op == '{') {
                self.pos += 1;
                try self.parseDecls(name);
            }
        }
        return true;
    }

    fn parseTypealias(
        self: *Parser,
        modifiers: u32,
        line: u32,
        col: u32,
        parent: ?[]const u8,
    ) Allocator.Error!bool {
        self.skipNewlines();
        const name_tok = self.peek() orelse return false;
        if (name_tok.tok != .Ident) return false;
        const name = try self.allocator.dupe(u8, name_tok.tok.Ident);
        errdefer self.allocator.free(name);
        self.pos += 1;

        if (self.peek()) |t| {
            if (t.tok == .Angle) self.pos += 1;
        }
        self.skipSignatureTail();

        const fqn = try self.buildFqn(parent, name);
        errdefer self.allocator.free(fqn);

        const signature = try std.fmt.allocPrint(self.allocator, "typealias {s}", .{name});
        errdefer self.allocator.free(signature);

        try self.decls.append(self.allocator, .{
            .kind = .TypeAlias,
            .name = name,
            .fqn = fqn,
            .parent = try self.dupParent(parent),
            .receiver = null,
            .modifiers = modifiers,
            .signature = signature,
            .param_names = &.{},
            .line = line,
            .column = col,
        });
        return true;
    }

    const ReceiverAndName = struct {
        receiver: ?[]const u8,
        name: ?[]const u8,
    };

    /// Read `Recv[.Recv2][<T>][?].name`. Returns (receiver, name).
    /// If only a plain `name` is present, returns (None, Some(name)).
    /// Both returned strings are owned by `self.allocator`.
    fn readOptionalReceiverAndName(self: *Parser) Allocator.Error!ReceiverAndName {
        // Walk ahead, gathering ident / `.` / Angle / `?` until we find an
        // ident followed by `(` (function) or by `:` / newline / `=` (property).
        // The *last* ident before that terminator is the name; everything before
        // (joined with `.`) is the receiver.
        var pieces: std.ArrayList([]u8) = .empty;
        defer {
            for (pieces.items) |p| self.allocator.free(p);
            pieces.deinit(self.allocator);
        }
        while (self.peek()) |t| {
            switch (t.tok) {
                .Ident => |s| {
                    try pieces.append(self.allocator, try self.allocator.dupe(u8, s));
                    self.pos += 1;
                },
                .Op => |c| {
                    if (c == '.') {
                        try pieces.append(self.allocator, try self.allocator.dupe(u8, "."));
                        self.pos += 1;
                    } else if (c == '?') {
                        if (pieces.items.len > 0) {
                            const last_idx = pieces.items.len - 1;
                            const last = pieces.items[last_idx];
                            const grown = try self.allocator.realloc(last, last.len + 1);
                            grown[grown.len - 1] = '?';
                            pieces.items[last_idx] = grown;
                        }
                        self.pos += 1;
                    } else break;
                },
                .Angle => |s| {
                    if (pieces.items.len > 0) {
                        const last_idx = pieces.items.len - 1;
                        const last = pieces.items[last_idx];
                        const grown = try std.fmt.allocPrint(self.allocator, "{s}<{s}>", .{ last, s });
                        self.allocator.free(last);
                        pieces.items[last_idx] = grown;
                    }
                    self.pos += 1;
                },
                else => break,
            }
        }
        if (pieces.items.len == 0) {
            return .{ .receiver = null, .name = null };
        }
        // The "name" is the last non-dot piece. Build receiver from earlier pieces.
        // Drop trailing dot if any.
        while (pieces.items.len > 0 and std.mem.eql(u8, pieces.items[pieces.items.len - 1], ".")) {
            const popped = pieces.pop().?;
            self.allocator.free(popped);
        }
        const name: ?[]u8 = if (pieces.items.len > 0) pieces.pop().? else null;
        errdefer if (name) |n| self.allocator.free(n);
        // Drop trailing dot between receiver and name.
        if (pieces.items.len > 0 and std.mem.eql(u8, pieces.items[pieces.items.len - 1], ".")) {
            const popped = pieces.pop().?;
            self.allocator.free(popped);
        }
        const receiver: ?[]const u8 = if (pieces.items.len == 0)
            null
        else
            try std.mem.concat(self.allocator, u8, pieces.items);
        return .{ .receiver = receiver, .name = name };
    }

    /// Build the fully qualified name for `name` under `parent`, honouring the
    /// file package. Owned by `self.allocator`.
    fn buildFqn(self: *Parser, parent: ?[]const u8, name: []const u8) Allocator.Error![]const u8 {
        if (parent) |p| {
            if (self.package.len == 0) {
                return std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ p, name });
            }
            return std.fmt.allocPrint(self.allocator, "{s}.{s}.{s}", .{ self.package, p, name });
        }
        if (self.package.len == 0) {
            return self.allocator.dupe(u8, name);
        }
        return std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ self.package, name });
    }

    fn dupParent(self: *Parser, parent: ?[]const u8) Allocator.Error!?[]const u8 {
        if (parent) |p| return try self.allocator.dupe(u8, p);
        return null;
    }

    /// Skip up to and including the next `{` body, `= ...` expression body, or
    /// a top-level newline-terminator.
    fn skipSignatureTail(self: *Parser) void {
        var paren_depth: i32 = 0;
        var bracket_depth: i32 = 0;
        while (true) {
            const t = self.peek() orelse return;
            if (t.tok == .Op) {
                switch (t.tok.Op) {
                    '{' => return,
                    ';' => {
                        self.pos += 1;
                        return;
                    },
                    '=' => {
                        if (paren_depth == 0 and bracket_depth == 0) {
                            // Expression body. Eat to newline at depth 0.
                            self.pos += 1;
                            self.skipToNewlineOrDedent();
                            return;
                        }
                        self.pos += 1;
                    },
                    '(' => {
                        paren_depth += 1;
                        self.pos += 1;
                    },
                    ')' => {
                        paren_depth -= 1;
                        self.pos += 1;
                    },
                    '[' => {
                        bracket_depth += 1;
                        self.pos += 1;
                    },
                    ']' => {
                        bracket_depth -= 1;
                        self.pos += 1;
                    },
                    else => self.pos += 1,
                }
            } else if (t.tok == .Newline and paren_depth == 0 and bracket_depth == 0) {
                self.pos += 1;
                return;
            } else {
                self.pos += 1;
            }
        }
    }

    fn skipToNewlineOrDedent(self: *Parser) void {
        var paren_depth: i32 = 0;
        var brace_depth: i32 = 0;
        while (true) {
            const t = self.peek() orelse return;
            if (t.tok == .Newline and paren_depth == 0 and brace_depth == 0) {
                self.pos += 1;
                return;
            }
            if (t.tok == .Op) {
                switch (t.tok.Op) {
                    '(' => paren_depth += 1,
                    ')' => paren_depth -= 1,
                    '{' => brace_depth += 1,
                    '}' => {
                        if (brace_depth == 0) return;
                        brace_depth -= 1;
                    },
                    else => {},
                }
            }
            self.pos += 1;
        }
    }

    fn skipOptionalBody(self: *Parser) void {
        self.skipNewlines();
        if (self.peek()) |t| {
            if (t.tok == .Op and t.tok.Op == '{') {
                self.skipBraceBlock();
            }
        }
    }

    fn skipBraceBlock(self: *Parser) void {
        const t = self.peek() orelse return;
        if (!(t.tok == .Op and t.tok.Op == '{')) return;
        self.pos += 1;
        var depth: i32 = 1;
        while (depth > 0) {
            const tk = self.peek() orelse return;
            self.pos += 1;
            if (tk.tok == .Op) {
                switch (tk.tok.Op) {
                    '{' => depth += 1,
                    '}' => depth -= 1,
                    else => {},
                }
            }
        }
    }
};

fn eqlOptStr(a: ?[]const u8, b: ?[]const u8) bool {
    if ((a == null) != (b == null)) return false;
    if (a == null) return true;
    return std.mem.eql(u8, a.?, b.?);
}

const testing = std.testing;

test "parses simple function" {
    const src = "package kotlin\npublic fun foo(): Int = 1\n";
    var pf = try parseFile(testing.allocator, src);
    defer pf.deinit(testing.allocator);
    try testing.expectEqualStrings("kotlin", pf.package);
    try testing.expectEqual(@as(usize, 1), pf.decls.len);
    try testing.expectEqualStrings("foo", pf.decls[0].name);
    try testing.expectEqualStrings("kotlin.foo", pf.decls[0].fqn);
    try testing.expect(pf.decls[0].modifiers & modflag.PUBLIC != 0);
}

test "parses extension function with generics" {
    const src = "package kotlin.collections\npublic fun <T> List<T>.first(): T = get(0)\n";
    var pf = try parseFile(testing.allocator, src);
    defer pf.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), pf.decls.len);
    const d = &pf.decls[0];
    try testing.expectEqualStrings("first", d.name);
    try testing.expect(d.receiver != null);
    try testing.expectEqualStrings("List<T>", d.receiver.?);
    try testing.expectEqualStrings("kotlin.collections.first", d.fqn);
}

test "parses property in class" {
    const src = "package kotlin\npublic class Foo {\n  public val x: Int = 0\n  public fun bar(): Int = x\n}\n";
    var pf = try parseFile(testing.allocator, src);
    defer pf.deinit(testing.allocator);
    var has_foo = false;
    var has_x = false;
    var has_bar = false;
    for (pf.decls) |d| {
        if (std.mem.eql(u8, d.name, "Foo") and d.parent == null) has_foo = true;
        if (std.mem.eql(u8, d.name, "x") and d.parent != null and std.mem.eql(u8, d.parent.?, "Foo")) has_x = true;
        if (std.mem.eql(u8, d.name, "bar") and d.parent != null and std.mem.eql(u8, d.parent.?, "Foo")) has_bar = true;
    }
    try testing.expect(has_foo);
    try testing.expect(has_x);
    try testing.expect(has_bar);
}

test "handles expect decl without body" {
    const src = "package kotlin\npublic expect fun Double.isNaN(): Boolean\n";
    var pf = try parseFile(testing.allocator, src);
    defer pf.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), pf.decls.len);
    try testing.expectEqualStrings("isNaN", pf.decls[0].name);
    try testing.expect(pf.decls[0].receiver != null);
    try testing.expectEqualStrings("Double", pf.decls[0].receiver.?);
    try testing.expect(pf.decls[0].modifiers & modflag.EXPECT != 0);
}

test "parses typealias" {
    const src = "package kotlin\npublic typealias Foo = Int\n";
    var pf = try parseFile(testing.allocator, src);
    defer pf.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), pf.decls.len);
    try testing.expectEqual(DeclKind.TypeAlias, pf.decls[0].kind);
    try testing.expectEqualStrings("Foo", pf.decls[0].name);
}

test "ignores string braces" {
    const src = "package kotlin\npublic fun foo(): String = \"}{{\"\npublic fun bar(): Int = 1\n";
    var pf = try parseFile(testing.allocator, src);
    defer pf.deinit(testing.allocator);
    var has_foo = false;
    var has_bar = false;
    for (pf.decls) |d| {
        if (std.mem.eql(u8, d.name, "foo")) has_foo = true;
        if (std.mem.eql(u8, d.name, "bar")) has_bar = true;
    }
    try testing.expect(has_foo);
    try testing.expect(has_bar);
}

test "ignores comments and annotations" {
    const src =
        \\
        \\package kotlin
        \\
        \\/**
        \\ * docs
        \\ */
        \\@SinceKotlin("1.2")
        \\@kotlin.internal.InlineOnly
        \\public inline operator fun <T> List<T>.component1(): T = get(0)
        \\
    ;
    var pf = try parseFile(testing.allocator, src);
    defer pf.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), pf.decls.len);
    const d = &pf.decls[0];
    try testing.expectEqualStrings("component1", d.name);
    try testing.expect(d.modifiers & modflag.INLINE != 0);
    try testing.expect(d.modifiers & modflag.OPERATOR != 0);
}
