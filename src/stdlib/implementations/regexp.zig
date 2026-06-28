//! Regex / MatchResult / MatchGroup stdlib intrinsics.
//!
//! Kotlin's `kotlin.text.Regex` family. The Rust port leaned on the `regex`
//! crate; Zig has no such engine in std, so a self-contained backtracking
//! matcher lives here behind the opaque `RegexData.engine` handle. It
//! supports the constructs Kotlin programs actually reach: literals,
//! escapes, character classes, anchors, word boundaries, alternation,
//! greedy/lazy quantifiers, and (named) capture groups. Matching is
//! Unicode-codepoint aware and reports byte offsets, mirroring the crate.

const std = @import("std");
const runtime = @import("runtime");

const Value = runtime.Value;
const CallCtx = runtime.CallCtx;
const EvalResult = runtime.EvalResult;
const RuntimeError = runtime.RuntimeError;
const RangeKind = runtime.RangeKind;
const ObjRef = runtime.ObjRef;
const StringRef = runtime.StringRef;
const ValueList = runtime.ValueList;
const ValueSlice = runtime.ValueSlice;
const RegexData = runtime.RegexData;
const MatchData = runtime.MatchData;
const MatchGroupData = runtime.MatchGroupData;
const SequenceData = runtime.SequenceData;
const charUnitToString = runtime.charUnitToString;

// ============================================================
// Small Value / RuntimeError helpers
// ============================================================

fn ok(v: Value) EvalResult {
    return .{ .ok = v };
}

fn typeErr(msg: []const u8) EvalResult {
    return .{ .err = .{ .Type = msg } };
}

fn arityErr(msg: []const u8) EvalResult {
    return .{ .err = .{ .Arity = msg } };
}

fn makeString(allocator: std.mem.Allocator, bytes: []const u8) !Value {
    const owned = try allocator.dupe(u8, bytes);
    return .{ .String = try runtime.strInitOwned(allocator, owned) };
}

/// Wrap an already-owned byte slice as a `String` without re-copying.
fn makeStringOwned(allocator: std.mem.Allocator, owned: []const u8) !Value {
    return .{ .String = try runtime.strInitOwned(allocator, owned) };
}

fn makeException(allocator: std.mem.Allocator, fqn: []const u8, message: ?[]const u8) !Value {
    const owned_fqn = try allocator.dupe(u8, fqn);
    const msg_ref: ?StringRef = if (message) |m|
        try runtime.strInitOwned(allocator, try allocator.dupe(u8, m))
    else
        null;
    return .{ .Exception = .{
        .fqn = try runtime.strInitOwned(allocator, owned_fqn),
        .message = msg_ref,
        .cause = null,
    } };
}

fn makeList(allocator: std.mem.Allocator, items: []const Value, mutable: bool) !Value {
    var list = try ValueList.init(allocator, .empty);
    {
        const g = list.borrowMut();
        defer g.deinit();
        try g.get().appendSlice(allocator, items);
    }
    return .{ .List = .{ .items = list, .mutable = mutable, .enum_entries = false, .backing = null } };
}

fn makeSequence(allocator: std.mem.Allocator, items: []const Value) !Value {
    const owned = try allocator.dupe(Value, items);
    const slice_ref = try ValueSlice.init(allocator, owned);
    const data = SequenceData{
        .source = .{ .Items = slice_ref },
        .ops = &.{},
    };
    return .{ .Sequence = try ObjRef(SequenceData).init(allocator, data) };
}

/// Borrow the bytes behind a `Value::String`.
fn stringBytes(v: Value) ?[]const u8 {
    return switch (v) {
        .String => |s| s.asPtr().bytes,
        else => null,
    };
}

// ============================================================
// Regex engine
// ============================================================

/// Compiled pattern AST. Owned (via the supplied allocator) and reachable
/// from `RegexData.engine` for the life of the `Regex` value.
const Program = struct {
    root: *Node,
    /// Number of capture groups including the implicit whole-match (group 0).
    group_count: usize,
    /// `names[i]` is the name of group `i`, or null for an unnamed group.
    names: []const ?[]const u8,
    /// `RegexOption` flags this pattern was compiled with.
    flags: Flags = .{},
    allocator: std.mem.Allocator,
};

/// The subset of `kotlin.text.RegexOption` that affects matching here.
const Flags = struct {
    /// `RegexOption.IGNORE_CASE` — literals and character classes fold case.
    case_insensitive: bool = false,
    /// `RegexOption.MULTILINE` — `^`/`$` also match at line terminators.
    multiline: bool = false,
};

const Quant = struct {
    min: usize,
    /// `null` = unbounded.
    max: ?usize,
    greedy: bool,
};

const ClassRange = struct { lo: u21, hi: u21 };

const ClassItem = union(enum) {
    range: ClassRange,
    /// A built-in escape class (`\d`, `\w`, `\s`, negated forms).
    builtin: BuiltinClass,
};

const BuiltinClass = enum { digit, not_digit, word, not_word, space, not_space };

const Node = union(enum) {
    /// Match a single literal codepoint.
    literal: u21,
    /// `.` — any codepoint except newline (Rust's default; no `(?s)`).
    any,
    /// A bracket character class.
    class: struct { items: []ClassItem, negated: bool },
    builtin: BuiltinClass,
    anchor_start,
    anchor_end,
    /// `\b` / `\B`.
    word_boundary: bool,
    /// A capture group: index into the capture array.
    group: struct { index: usize, child: *Node },
    /// A non-capturing group `(?:...)`.
    noncap: *Node,
    concat: []*Node,
    alternate: []*Node,
    repeat: struct { child: *Node, quant: Quant },
    /// Always succeeds, consuming nothing.
    empty,
};

const ParseError = error{ OutOfMemory, InvalidPattern };

const Parser = struct {
    src: []const u21,
    pos: usize,
    allocator: std.mem.Allocator,
    next_group: usize,
    names: std.ArrayList(?[]const u8),

    fn peek(self: *Parser) ?u21 {
        if (self.pos < self.src.len) return self.src[self.pos];
        return null;
    }

    fn bump(self: *Parser) ?u21 {
        if (self.pos < self.src.len) {
            const c = self.src[self.pos];
            self.pos += 1;
            return c;
        }
        return null;
    }

    fn node(self: *Parser, n: Node) ParseError!*Node {
        const p = try self.allocator.create(Node);
        p.* = n;
        return p;
    }

    fn parseAlternation(self: *Parser) ParseError!*Node {
        var branches: std.ArrayList(*Node) = .empty;
        try branches.append(self.allocator, try self.parseConcat());
        while (self.peek() == '|') {
            _ = self.bump();
            try branches.append(self.allocator, try self.parseConcat());
        }
        if (branches.items.len == 1) return branches.items[0];
        return self.node(.{ .alternate = try branches.toOwnedSlice(self.allocator) });
    }

    fn parseConcat(self: *Parser) ParseError!*Node {
        var parts: std.ArrayList(*Node) = .empty;
        while (self.peek()) |c| {
            if (c == '|' or c == ')') break;
            try parts.append(self.allocator, try self.parseRepeat());
        }
        if (parts.items.len == 0) return self.node(.empty);
        if (parts.items.len == 1) return parts.items[0];
        return self.node(.{ .concat = try parts.toOwnedSlice(self.allocator) });
    }

    fn parseRepeat(self: *Parser) ParseError!*Node {
        const atom = try self.parseAtom();
        const c = self.peek() orelse return atom;
        var quant: Quant = undefined;
        switch (c) {
            '*' => {
                _ = self.bump();
                quant = .{ .min = 0, .max = null, .greedy = true };
            },
            '+' => {
                _ = self.bump();
                quant = .{ .min = 1, .max = null, .greedy = true };
            },
            '?' => {
                _ = self.bump();
                quant = .{ .min = 0, .max = 1, .greedy = true };
            },
            '{' => {
                if (try self.tryParseBounded()) |q| {
                    quant = q;
                } else {
                    return atom;
                }
            },
            else => return atom,
        }
        // A trailing `?` flips greedy quantifiers to lazy.
        if (self.peek() == '?') {
            _ = self.bump();
            quant.greedy = false;
        } else if (self.peek() == '+') {
            // Possessive `++` etc. — treat as greedy (no backtracking
            // semantics modeled; faithful enough for Kotlin programs).
            _ = self.bump();
        }
        return self.node(.{ .repeat = .{ .child = atom, .quant = quant } });
    }

    /// Parse a `{m}`, `{m,}`, or `{m,n}` counted quantifier. Returns null
    /// (and rewinds) when the brace does not open a valid count, so a bare
    /// `{` stays a literal.
    fn tryParseBounded(self: *Parser) ParseError!?Quant {
        const save = self.pos;
        _ = self.bump(); // '{'
        const min = self.parseInt();
        if (min == null) {
            self.pos = save;
            return null;
        }
        var max: ?usize = min;
        if (self.peek() == ',') {
            _ = self.bump();
            if (self.peek() == '}') {
                max = null;
            } else {
                const m = self.parseInt();
                if (m == null) {
                    self.pos = save;
                    return null;
                }
                max = m;
            }
        }
        if (self.peek() != '}') {
            self.pos = save;
            return null;
        }
        _ = self.bump(); // '}'
        return .{ .min = min.?, .max = max, .greedy = true };
    }

    fn parseInt(self: *Parser) ?usize {
        var any_digit = false;
        var n: usize = 0;
        while (self.peek()) |c| {
            if (c < '0' or c > '9') break;
            any_digit = true;
            n = n * 10 + @as(usize, c - '0');
            _ = self.bump();
        }
        if (!any_digit) return null;
        return n;
    }

    fn parseAtom(self: *Parser) ParseError!*Node {
        const c = self.peek() orelse return self.node(.empty);
        switch (c) {
            '(' => return self.parseGroup(),
            '[' => return self.parseClass(),
            '.' => {
                _ = self.bump();
                return self.node(.any);
            },
            '^' => {
                _ = self.bump();
                return self.node(.anchor_start);
            },
            '$' => {
                _ = self.bump();
                return self.node(.anchor_end);
            },
            '\\' => return self.parseEscape(),
            else => {
                _ = self.bump();
                return self.node(.{ .literal = c });
            },
        }
    }

    fn parseGroup(self: *Parser) ParseError!*Node {
        _ = self.bump(); // '('
        var capturing = true;
        var name: ?[]const u8 = null;
        if (self.peek() == '?') {
            _ = self.bump();
            switch (self.peek() orelse return ParseError.InvalidPattern) {
                ':' => {
                    _ = self.bump();
                    capturing = false;
                },
                '<' => {
                    _ = self.bump();
                    name = try self.parseGroupName('>');
                },
                'P' => {
                    _ = self.bump();
                    if (self.bump() != '<') return ParseError.InvalidPattern;
                    name = try self.parseGroupName('>');
                },
                else => {
                    // Inline flags / other groups are not modeled; treat as
                    // non-capturing scope to stay total.
                    capturing = false;
                    while (self.peek()) |fc| {
                        if (fc == ':' or fc == ')') break;
                        _ = self.bump();
                    }
                    if (self.peek() == ':') _ = self.bump();
                },
            }
        }

        var index: usize = 0;
        if (capturing) {
            index = self.next_group;
            self.next_group += 1;
            try self.names.append(self.allocator, name);
        }

        const inner = try self.parseAlternation();
        if (self.peek() != ')') return ParseError.InvalidPattern;
        _ = self.bump(); // ')'

        if (capturing) {
            return self.node(.{ .group = .{ .index = index, .child = inner } });
        }
        return self.node(.{ .noncap = inner });
    }

    fn parseGroupName(self: *Parser, close: u21) ParseError![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        while (self.peek()) |c| {
            if (c == close) break;
            var enc: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(@intCast(c), &enc) catch return ParseError.InvalidPattern;
            try buf.appendSlice(self.allocator, enc[0..n]);
            _ = self.bump();
        }
        if (self.peek() != close) return ParseError.InvalidPattern;
        _ = self.bump();
        return buf.toOwnedSlice(self.allocator);
    }

    fn parseClass(self: *Parser) ParseError!*Node {
        _ = self.bump(); // '['
        var negated = false;
        if (self.peek() == '^') {
            _ = self.bump();
            negated = true;
        }
        var items: std.ArrayList(ClassItem) = .empty;
        // A `]` as the first member is a literal.
        var first = true;
        while (self.peek()) |c| {
            if (c == ']' and !first) {
                _ = self.bump();
                return self.node(.{ .class = .{ .items = try items.toOwnedSlice(self.allocator), .negated = negated } });
            }
            first = false;
            if (c == '\\') {
                _ = self.bump();
                const e = self.bump() orelse return ParseError.InvalidPattern;
                if (classBuiltin(e)) |b| {
                    try items.append(self.allocator, .{ .builtin = b });
                    continue;
                }
                const lo = escapeChar(e);
                try self.appendClassMember(&items, lo);
                continue;
            }
            _ = self.bump();
            try self.appendClassMember(&items, c);
        }
        return ParseError.InvalidPattern;
    }

    /// Append a member starting at `lo`, consuming a `-hi` range if present.
    fn appendClassMember(self: *Parser, items: *std.ArrayList(ClassItem), lo: u21) ParseError!void {
        if (self.peek() == '-' and self.pos + 1 < self.src.len and self.src[self.pos + 1] != ']') {
            _ = self.bump(); // '-'
            var hi = self.bump().?;
            if (hi == '\\') {
                hi = escapeChar(self.bump() orelse return ParseError.InvalidPattern);
            }
            try items.append(self.allocator, .{ .range = .{ .lo = lo, .hi = hi } });
        } else {
            try items.append(self.allocator, .{ .range = .{ .lo = lo, .hi = lo } });
        }
    }

    fn parseEscape(self: *Parser) ParseError!*Node {
        _ = self.bump(); // '\\'
        const e = self.bump() orelse return ParseError.InvalidPattern;
        if (classBuiltin(e)) |b| return self.node(.{ .builtin = b });
        switch (e) {
            'b' => return self.node(.{ .word_boundary = true }),
            'B' => return self.node(.{ .word_boundary = false }),
            'A' => return self.node(.anchor_start),
            'z', 'Z' => return self.node(.anchor_end),
            else => return self.node(.{ .literal = escapeChar(e) }),
        }
    }
};

fn classBuiltin(c: u21) ?BuiltinClass {
    return switch (c) {
        'd' => .digit,
        'D' => .not_digit,
        'w' => .word,
        'W' => .not_word,
        's' => .space,
        'S' => .not_space,
        else => null,
    };
}

fn escapeChar(c: u21) u21 {
    return switch (c) {
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        'f' => 0x0C,
        'v' => 0x0B,
        '0' => 0,
        'a' => 0x07,
        'e' => 0x1B,
        else => c,
    };
}

fn isWordChar(c: u21) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_';
}

fn isSpaceChar(c: u21) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0B or c == 0x0C;
}

fn matchBuiltin(b: BuiltinClass, c: u21) bool {
    return switch (b) {
        .digit => c >= '0' and c <= '9',
        .not_digit => !(c >= '0' and c <= '9'),
        .word => isWordChar(c),
        .not_word => !isWordChar(c),
        .space => isSpaceChar(c),
        .not_space => !isSpaceChar(c),
    };
}

fn matchClass(items: []const ClassItem, negated: bool, c: u21) bool {
    var hit = false;
    for (items) |it| {
        switch (it) {
            .range => |r| if (c >= r.lo and c <= r.hi) {
                hit = true;
                break;
            },
            .builtin => |b| if (matchBuiltin(b, c)) {
                hit = true;
                break;
            },
        }
    }
    return hit != negated;
}

/// Compile a (already preprocessed) pattern into a `Program`. Returns null
/// on a syntax error.
fn compileProgram(allocator: std.mem.Allocator, pattern: []const u8) !?*Program {
    // Decode the pattern into codepoints for parsing.
    var cps: std.ArrayList(u21) = .empty;
    defer cps.deinit(allocator);
    {
        var view = std.unicode.Utf8View.initUnchecked(pattern);
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            try cps.append(allocator, cp);
        }
    }

    var parser = Parser{
        .src = cps.items,
        .pos = 0,
        .allocator = allocator,
        .next_group = 1,
        .names = .empty,
    };
    try parser.names.append(allocator, null); // group 0 is the whole match

    const root = parser.parseAlternation() catch |e| switch (e) {
        ParseError.InvalidPattern => return null,
        else => |oom| return oom,
    };
    if (parser.pos != parser.src.len) return null; // trailing `)` etc.

    const prog = try allocator.create(Program);
    prog.* = .{
        .root = root,
        .group_count = parser.next_group,
        .names = try parser.names.toOwnedSlice(allocator),
        .allocator = allocator,
    };
    return prog;
}

/// One capture slot: byte offsets into the input, or `null` if unset.
const Capture = struct { start: ?usize = null, end: ?usize = null };

/// ASCII case fold (lowercase). Kotlin/Native folds Unicode too, but the
/// programs reached here are ASCII-cased; this keeps `IGNORE_CASE` correct
/// for the common case without a full case table.
fn foldCp(c: u21) u21 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

fn upperCp(c: u21) u21 {
    if (c >= 'a' and c <= 'z') return c - 32;
    return c;
}

fn cpEq(a: u21, b: u21, fold: bool) bool {
    if (a == b) return true;
    return fold and foldCp(a) == foldCp(b);
}

/// `matchClass`, honoring case-insensitivity. Membership in the positive
/// item set is tested against the input codepoint and (under `fold`) its
/// lower/upper case forms; negation is applied once over that membership so
/// `[^a-z]` correctly rejects `A` under IGNORE_CASE.
fn matchClassFold(items: []const ClassItem, negated: bool, c: u21, fold: bool) bool {
    var member = matchClass(items, false, c);
    if (fold and !member) {
        const lo = foldCp(c);
        const up = upperCp(c);
        if (lo != c and matchClass(items, false, lo)) member = true;
        if (!member and up != c and matchClass(items, false, up)) member = true;
    }
    return member != negated;
}

/// True when codepoint `c` is a line terminator for `^`/`$` in MULTILINE.
fn isLineTerminator(c: u21) bool {
    return c == '\n' or c == '\r';
}

/// Backtracking matcher over the UTF-8 input bytes.
const Matcher = struct {
    input: []const u8,
    caps: []Capture,
    flags: Flags = .{},

    /// Decode the codepoint at byte offset `at`. Returns the codepoint and
    /// its byte length, or null at end-of-input / on a bad byte.
    fn decode(self: *const Matcher, at: usize) ?struct { cp: u21, len: usize } {
        if (at >= self.input.len) return null;
        const len = std.unicode.utf8ByteSequenceLength(self.input[at]) catch return null;
        if (at + len > self.input.len) return null;
        const cp = std.unicode.utf8Decode(self.input[at .. at + len]) catch return null;
        return .{ .cp = cp, .len = len };
    }

    /// Codepoint immediately before byte offset `at`, for word boundaries.
    fn prevCodepoint(self: *const Matcher, at: usize) ?u21 {
        if (at == 0) return null;
        var i = at;
        while (i > 0) {
            i -= 1;
            // Find a UTF-8 lead byte.
            if (self.input[i] & 0xC0 != 0x80) {
                return self.decode(i).?.cp;
            }
        }
        return null;
    }

    fn atWordBoundary(self: *const Matcher, at: usize) bool {
        const before = self.prevCodepoint(at);
        const after = if (self.decode(at)) |d| d.cp else null;
        const bw = if (before) |c| isWordChar(c) else false;
        const aw = if (after) |c| isWordChar(c) else false;
        return bw != aw;
    }

    /// Match `node` starting at byte offset `at`, calling `k` (the
    /// continuation) with each candidate end offset. Returns the offset
    /// where the whole tail matched, or null to backtrack.
    fn match(self: *Matcher, node: *const Node, at: usize, k: *const Cont) ?usize {
        switch (node.*) {
            .empty => return k.run(self, at),
            .literal => |lit| {
                const d = self.decode(at) orelse return null;
                if (!cpEq(d.cp, lit, self.flags.case_insensitive)) return null;
                return k.run(self, at + d.len);
            },
            .any => {
                const d = self.decode(at) orelse return null;
                if (d.cp == '\n') return null;
                return k.run(self, at + d.len);
            },
            .builtin => |b| {
                const d = self.decode(at) orelse return null;
                if (!matchBuiltin(b, d.cp)) return null;
                return k.run(self, at + d.len);
            },
            .class => |cl| {
                const d = self.decode(at) orelse return null;
                if (!matchClassFold(cl.items, cl.negated, d.cp, self.flags.case_insensitive)) return null;
                return k.run(self, at + d.len);
            },
            .anchor_start => {
                if (at == 0) return k.run(self, at);
                if (self.flags.multiline) {
                    if (self.prevCodepoint(at)) |p| {
                        if (isLineTerminator(p)) return k.run(self, at);
                    }
                }
                return null;
            },
            .anchor_end => {
                if (at == self.input.len) return k.run(self, at);
                if (self.flags.multiline) {
                    if (self.decode(at)) |d| {
                        if (isLineTerminator(d.cp)) return k.run(self, at);
                    }
                }
                return null;
            },
            .word_boundary => |want| {
                if (self.atWordBoundary(at) != want) return null;
                return k.run(self, at);
            },
            .noncap => |child| return self.match(child, at, k),
            .group => |g| {
                const saved = self.caps[g.index];
                self.caps[g.index].start = at;
                const gk = GroupCont{ .base = .{ .vtable = GroupCont.vt }, .index = g.index, .next = k };
                if (self.match(g.child, at, &gk.base)) |e| return e;
                // Restore on backtrack.
                self.caps[g.index] = saved;
                return null;
            },
            .concat => |parts| {
                const cc = ConcatCont{ .base = .{ .vtable = ConcatCont.vt }, .parts = parts, .idx = 0, .next = k };
                return cc.run(self, at);
            }, // cc.run takes *const ConcatCont via method-call autoref
            .alternate => |branches| {
                for (branches) |b| {
                    if (self.match(b, at, k)) |e| return e;
                }
                return null;
            },
            .repeat => |rep| {
                return self.matchRepeat(rep.child, rep.quant, at, 0, k);
            },
        }
    }

    fn matchRepeat(self: *Matcher, child: *const Node, quant: Quant, at: usize, count: usize, k: *const Cont) ?usize {
        const reached_min = count >= quant.min;
        const can_more = quant.max == null or count < quant.max.?;

        if (quant.greedy) {
            if (can_more) {
                const rc = RepeatCont{
                    .base = .{ .vtable = RepeatCont.vt },
                    .child = child,
                    .quant = quant,
                    .count = count + 1,
                    .start = at,
                    .next = k,
                };
                if (self.match(child, at, &rc.base)) |e| return e;
            }
            if (reached_min) return k.run(self, at);
            return null;
        } else {
            if (reached_min) {
                if (k.run(self, at)) |e| return e;
            }
            if (can_more) {
                const rc = RepeatCont{
                    .base = .{ .vtable = RepeatCont.vt },
                    .child = child,
                    .quant = quant,
                    .count = count + 1,
                    .start = at,
                    .next = k,
                };
                return self.match(child, at, &rc.base);
            }
            return null;
        }
    }
};

/// A continuation in the backtracking matcher. `run(matcher, at)` resumes
/// matching the remainder of the pattern from byte offset `at`.
const Cont = struct {
    vtable: *const fn (self: *const Cont, m: *Matcher, at: usize) ?usize,

    fn run(self: *const Cont, m: *Matcher, at: usize) ?usize {
        return self.vtable(self, m, at);
    }
};

const TopCont = struct {
    base: Cont,

    fn vt(self: *const Cont, m: *Matcher, at: usize) ?usize {
        _ = self;
        _ = m;
        return at;
    }
};

const ConcatCont = struct {
    base: Cont,
    parts: []const *Node,
    idx: usize,
    next: *const Cont,

    const vt: *const fn (self: *const Cont, m: *Matcher, at: usize) ?usize = vtImpl;

    fn run(self: *const ConcatCont, m: *Matcher, at: usize) ?usize {
        if (self.idx >= self.parts.len) return self.next.run(m, at);
        const tail = ConcatCont{
            .base = .{ .vtable = ConcatCont.vt },
            .parts = self.parts,
            .idx = self.idx + 1,
            .next = self.next,
        };
        return m.match(self.parts[self.idx], at, &tail.base);
    }

    fn vtImpl(base: *const Cont, m: *Matcher, at: usize) ?usize {
        const self: *const ConcatCont = @fieldParentPtr("base", base);
        return self.run(m, at);
    }
};

const GroupCont = struct {
    base: Cont,
    index: usize,
    next: *const Cont,

    const vt: *const fn (self: *const Cont, m: *Matcher, at: usize) ?usize = vtImpl;

    fn vtImpl(base: *const Cont, m: *Matcher, at: usize) ?usize {
        const self: *const GroupCont = @fieldParentPtr("base", base);
        const saved_end = m.caps[self.index].end;
        m.caps[self.index].end = at;
        if (self.next.run(m, at)) |e| return e;
        m.caps[self.index].end = saved_end;
        return null;
    }
};

const RepeatCont = struct {
    base: Cont,
    child: *const Node,
    quant: Quant,
    count: usize,
    start: usize,
    next: *const Cont,

    const vt: *const fn (self: *const Cont, m: *Matcher, at: usize) ?usize = vtImpl;

    fn vtImpl(base: *const Cont, m: *Matcher, at: usize) ?usize {
        const self: *const RepeatCont = @fieldParentPtr("base", base);
        // Guard against zero-width infinite loops: if the child matched
        // nothing, stop expanding and fall through to the continuation.
        if (at == self.start) return self.next.run(m, at);
        return m.matchRepeat(self.child, self.quant, at, self.count, self.next);
    }
};

/// Find the leftmost match of `prog` in `input` starting the scan at byte
/// offset `from`. Mirrors `regex::captures_at`. Returns the filled capture
/// array (caller owns via `allocator`) or null.
fn runMatch(allocator: std.mem.Allocator, prog: *const Program, input: []const u8, from: usize) !?[]Capture {
    var caps = try allocator.alloc(Capture, prog.group_count);
    errdefer allocator.free(caps);

    var pos = from;
    while (true) {
        for (caps) |*c| c.* = .{};
        var matcher = Matcher{ .input = input, .caps = caps, .flags = prog.flags };
        const top = TopCont{ .base = .{ .vtable = TopCont.vt } };
        if (matcher.match(prog.root, pos, &top.base)) |end| {
            caps[0] = .{ .start = pos, .end = end };
            return caps;
        }
        if (pos >= input.len) break;
        // Advance one codepoint and retry (leftmost scan).
        const len = std.unicode.utf8ByteSequenceLength(input[pos]) catch 1;
        pos += if (pos + len <= input.len) len else 1;
    }
    allocator.free(caps);
    return null;
}

/// `is_match` — does the pattern match anywhere?
fn programIsMatch(allocator: std.mem.Allocator, prog: *const Program, input: []const u8) !bool {
    if (try runMatch(allocator, prog, input, 0)) |caps| {
        allocator.free(caps);
        return true;
    }
    return false;
}

fn progFromRegex(r: ObjRef(RegexData)) ?*Program {
    const eng = r.asPtr().engine orelse return null;
    return @ptrCast(@alignCast(eng));
}

// ============================================================
// Pattern preprocessing & literal escaping
// ============================================================

/// Escape a literal string into a regex that matches it verbatim (the
/// effect of Rust's `regex::escape`).
fn regexEscapeLiteral(allocator: std.mem.Allocator, lit: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (lit) |b| {
        switch (b) {
            '\\', '.', '+', '*', '?', '(', ')', '|', '[', ']', '{', '}', '^', '$', '#', '&', '-', '~' => {
                try out.append(allocator, '\\');
                try out.append(allocator, b);
            },
            else => try out.append(allocator, b),
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Expand `\Q...\E` literal blocks into escaped equivalents. Other escapes
/// pass through unchanged.
fn preprocessPattern(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == '\\') {
            if (i + 1 < src.len) {
                const nc = src[i + 1];
                if (nc == 'Q') {
                    i += 2;
                    const lit_start = i;
                    while (i < src.len) {
                        if (src[i] == '\\' and i + 1 < src.len and src[i + 1] == 'E') break;
                        i += 1;
                    }
                    const lit = src[lit_start..i];
                    const escaped = try regexEscapeLiteral(allocator, lit);
                    defer allocator.free(escaped);
                    try out.appendSlice(allocator, escaped);
                    if (i < src.len) i += 2; // consume `\E`
                    continue;
                } else {
                    try out.append(allocator, '\\');
                    try out.append(allocator, nc);
                    i += 2;
                    continue;
                }
            } else {
                try out.append(allocator, '\\');
                i += 1;
                continue;
            }
        }
        try out.append(allocator, c);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// Build a `Value::Regex` from a pattern, compiling the engine. Returns a
/// `PatternSyntaxException` (as a thrown value) on a syntax error.
fn compileRegex(allocator: std.mem.Allocator, pattern: []const u8) !EvalResult {
    return compileRegexFlags(allocator, pattern, .{});
}

/// `compileRegex`, with the `RegexOption` flags to bake into the program.
fn compileRegexFlags(allocator: std.mem.Allocator, pattern: []const u8, flags: Flags) !EvalResult {
    const prepared = try preprocessPattern(allocator, pattern);
    defer allocator.free(prepared);
    const prog = (try compileProgram(allocator, prepared)) orelse {
        const msg = try std.fmt.allocPrint(allocator, "invalid regex: {s}", .{pattern});
        const ex = try makeException(allocator, "kotlin.text.PatternSyntaxException", msg);
        return .{ .err = .{ .Thrown = ex } };
    };
    prog.flags = flags;
    const owned_pat = try allocator.dupe(u8, pattern);
    const data = RegexData{
        .pattern = try runtime.strInitOwned(allocator, owned_pat),
        .engine = @ptrCast(prog),
    };
    return ok(.{ .Regex = try ObjRef(RegexData).init(allocator, data) });
}

/// `kotlin.text.Regex.escape` rendering — `\Qx\E`, splitting on an embedded
/// `\E` sentinel so it re-opens the literal block.
fn kotlinLiteralEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var first = true;
    var rest = s;
    while (true) {
        const idx = std.mem.indexOf(u8, rest, "\\E");
        const part = if (idx) |k| rest[0..k] else rest;
        if (!first) try out.appendSlice(allocator, "\\E\\\\E\\Q");
        first = false;
        try out.appendSlice(allocator, "\\Q");
        try out.appendSlice(allocator, part);
        try out.appendSlice(allocator, "\\E");
        if (idx) |k| {
            rest = rest[k + 2 ..];
        } else break;
    }
    if (out.items.len == 0) {
        out.deinit(allocator);
        return allocator.dupe(u8, "\\Q\\E");
    }
    return out.toOwnedSlice(allocator);
}

// ============================================================
// Receiver helpers
// ============================================================

fn regexArg(args: []const Value, comptime what: []const u8) union(enum) { ok: ObjRef(RegexData), err: EvalResult } {
    if (args.len > 0) {
        switch (args[0]) {
            .Regex => |r| return .{ .ok = r },
            else => {},
        }
    }
    return .{ .err = typeErr(what ++ " requires a Regex receiver") };
}

fn matchArg(args: []const Value, comptime what: []const u8) union(enum) { ok: ObjRef(MatchData), err: EvalResult } {
    if (args.len > 0) {
        switch (args[0]) {
            .Match => |m| return .{ .ok = m },
            else => {},
        }
    }
    return .{ .err = typeErr(what ++ " requires a MatchResult receiver") };
}

// ============================================================
// byte <-> char index conversion
// ============================================================

/// Count UTF-16 code units in the prefix `s[0..byte]` — the Kotlin char
/// index for a byte offset.
fn byteToChar(s: []const u8, byte: usize) i64 {
    var count: i64 = 0;
    var view = std.unicode.Utf8View.initUnchecked(s[0..byte]);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        count += if (cp > 0xFFFF) 2 else 1;
    }
    return count;
}

/// Byte offset of the char (codepoint) at Kotlin index `n`. Returns the
/// string length when `n` is past the end.
fn charIndexToByte(s: []const u8, n: i64) usize {
    if (n <= 0) return 0;
    var i: i64 = 0;
    var byte: usize = 0;
    var view = std.unicode.Utf8View.initUnchecked(s);
    var it = view.iterator();
    while (it.nextCodepoint()) |_| {
        if (i == n) return byte;
        byte = it.i;
        i += 1;
    }
    return s.len;
}

// ============================================================
// MatchData construction
// ============================================================

fn buildMatch(
    allocator: std.mem.Allocator,
    r: ObjRef(RegexData),
    input: StringRef,
    caps: []const Capture,
) !MatchData {
    const s = input.asPtr().bytes;
    var groups = try allocator.alloc(?MatchGroupData, caps.len);
    for (caps, 0..) |c, i| {
        if (c.start) |start_b| {
            const end_b = c.end orelse start_b;
            const start = byteToChar(s, start_b);
            const end_char = byteToChar(s, end_b);
            const value_bytes = s[start_b..end_b];
            const end_inclusive: i64 = if (end_char == 0 and start == 0 and value_bytes.len == 0)
                -1
            else
                end_char - 1;
            const owned = try allocator.dupe(u8, value_bytes);
            groups[i] = .{
                .value = try runtime.strInitOwned(allocator, owned),
                .start = start,
                .end_inclusive = end_inclusive,
            };
        } else {
            groups[i] = null;
        }
    }
    const end_byte = if (caps.len > 0 and caps[0].end != null) caps[0].end.? else 0;
    return .{
        .input = input.clone(),
        .groups = groups,
        .end_byte = end_byte,
        .regex = r.clone(),
    };
}

fn matchValue(allocator: std.mem.Allocator, md: MatchData) !Value {
    return .{ .Match = try ObjRef(MatchData).init(allocator, md) };
}

// ============================================================
// Replacement template expansion
// ============================================================

/// Expand a Kotlin replacement template against one match's groups. `$n` /
/// `${n}` reference a group by index, `${name}` a named group, `\` escapes
/// the next character. Returns owned bytes.
fn expandKotlinReplacement(
    allocator: std.mem.Allocator,
    template: []const u8,
    prog: *const Program,
    groups: []const ?MatchGroupData,
) ![]u8 {
    // Operate on codepoints to mirror the Rust char-vector logic.
    var cps: std.ArrayList(u21) = .empty;
    defer cps.deinit(allocator);
    {
        var view = std.unicode.Utf8View.initUnchecked(template);
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| try cps.append(allocator, cp);
    }
    const chars = cps.items;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const groupText = struct {
        fn get(gs: []const ?MatchGroupData, idx: usize) []const u8 {
            if (idx < gs.len) {
                if (gs[idx]) |g| return g.value.asPtr().bytes;
            }
            return "";
        }
    }.get;

    const pushCp = struct {
        fn run(o: *std.ArrayList(u8), a: std.mem.Allocator, cp: u21) !void {
            var enc: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(@intCast(cp), &enc) catch {
                try o.append(a, '?');
                return;
            };
            try o.appendSlice(a, enc[0..n]);
        }
    }.run;

    var i: usize = 0;
    while (i < chars.len) {
        const c = chars[i];
        if (c == '\\') {
            if (i + 1 < chars.len) {
                try pushCp(&out, allocator, chars[i + 1]);
                i += 2;
            } else {
                i += 1;
            }
        } else if (c == '$') {
            i += 1;
            if (i < chars.len and chars[i] == '{') {
                i += 1;
                var key: std.ArrayList(u8) = .empty;
                defer key.deinit(allocator);
                while (i < chars.len and chars[i] != '}') {
                    try pushCp(&key, allocator, chars[i]);
                    i += 1;
                }
                if (i < chars.len) i += 1; // consume '}'
                if (std.fmt.parseInt(usize, key.items, 10)) |idx| {
                    try out.appendSlice(allocator, groupText(groups, idx));
                } else |_| {
                    if (groupIndexByName(prog, key.items)) |idx| {
                        try out.appendSlice(allocator, groupText(groups, idx));
                    }
                }
            } else {
                var num: std.ArrayList(u8) = .empty;
                defer num.deinit(allocator);
                while (i < chars.len and chars[i] >= '0' and chars[i] <= '9') {
                    try num.append(allocator, @intCast(chars[i]));
                    i += 1;
                }
                if (std.fmt.parseInt(usize, num.items, 10)) |idx| {
                    try out.appendSlice(allocator, groupText(groups, idx));
                } else |_| {
                    try out.append(allocator, '$');
                }
            }
        } else {
            try pushCp(&out, allocator, c);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn groupIndexByName(prog: *const Program, name: []const u8) ?usize {
    for (prog.names, 0..) |n, i| {
        if (n) |nm| {
            if (std.mem.eql(u8, nm, name)) return i;
        }
    }
    return null;
}

// ============================================================
// Intrinsics — Regex
// ============================================================

/// Apply a single `RegexOption` enum entry (a `Value::Instance` whose class is
/// `RegexOption`) onto `flags`. Unrecognized options are ignored.
fn applyRegexOption(opt: Value, flags: *Flags) void {
    switch (opt) {
        .Instance => |inst| {
            const data = inst.asPtr();
            // Only honor entries declared by `RegexOption`.
            const cls = data.class.asPtr();
            const is_regex_option =
                std.mem.eql(u8, cls.name, "RegexOption") or
                std.mem.endsWith(u8, cls.fqn, ".RegexOption");
            if (!is_regex_option) return;
            const name_v = data.get("name") orelse return;
            const name = stringBytes(name_v) orelse return;
            if (std.mem.eql(u8, name, "IGNORE_CASE")) {
                flags.case_insensitive = true;
            } else if (std.mem.eql(u8, name, "MULTILINE")) {
                flags.multiline = true;
            }
        },
        else => {},
    }
}

/// Parse the option argument of `Regex(pattern, options)` / `toRegex` — either
/// a single `RegexOption` enum value or a `Set`/`List`/`Array` of them — into
/// the compile/match `Flags`.
fn optionsToFlags(opt_arg: ?Value) Flags {
    var flags: Flags = .{};
    const arg = opt_arg orelse return flags;
    switch (arg) {
        .Set => |s| {
            const g = s.items.borrow();
            defer g.deinit();
            for (g.get().items) |it| applyRegexOption(it, &flags);
        },
        .List => |l| {
            const g = l.items.borrow();
            defer g.deinit();
            for (g.get().items) |it| applyRegexOption(it, &flags);
        },
        .Array => |a| switch (a.storage) {
            .boxed => |vl| {
                const g = vl.borrow();
                defer g.deinit();
                for (g.get().items) |it| applyRegexOption(it, &flags);
            },
            .scalars => {},
        },
        .Instance => applyRegexOption(arg, &flags),
        else => {},
    }
    return flags;
}

pub fn regex_ctor(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const pat = if (ctx.args.len > 0) stringBytes(ctx.args[0]) else null;
    if (pat == null) return typeErr("Regex requires a String pattern");
    const flags = optionsToFlags(if (ctx.args.len > 1) ctx.args[1] else null);
    return compileRegexFlags(ctx.allocator, pat.?, flags);
}

pub fn regex_pattern(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const r = switch (regexArg(ctx.args, "Regex.pattern")) {
        .ok => |v| v,
        .err => |e| return e,
    };
    return ok(.{ .String = r.asPtr().pattern.clone() });
}

pub fn regex_to_string(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const r = switch (regexArg(ctx.args, "Regex.toString")) {
        .ok => |v| v,
        .err => |e| return e,
    };
    return ok(.{ .String = r.asPtr().pattern.clone() });
}

pub fn regex_matches(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const r = switch (regexArg(ctx.args, "Regex.matches")) {
        .ok => |v| v,
        .err => |e| return e,
    };
    const s = if (ctx.args.len > 1) stringBytes(ctx.args[1]) else null;
    if (s == null) return typeErr("Regex.matches requires a String input");
    const prog = progFromRegex(r) orelse return typeErr("Regex.matches requires a Regex receiver");
    if (try runMatch(ctx.allocator, prog, s.?, 0)) |caps| {
        defer ctx.allocator.free(caps);
        const full = caps[0].start == 0 and caps[0].end == s.?.len;
        return ok(.{ .Bool = full });
    }
    return ok(.{ .Bool = false });
}

pub fn regex_contains_match_in(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const r = switch (regexArg(ctx.args, "Regex.containsMatchIn")) {
        .ok => |v| v,
        .err => |e| return e,
    };
    const s = if (ctx.args.len > 1) stringBytes(ctx.args[1]) else null;
    if (s == null) return typeErr("Regex.containsMatchIn requires a String");
    const prog = progFromRegex(r) orelse return typeErr("Regex.containsMatchIn requires a Regex receiver");
    return ok(.{ .Bool = try programIsMatch(ctx.allocator, prog, s.?) });
}

pub fn regex_find(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const r = switch (regexArg(ctx.args, "Regex.find")) {
        .ok => |v| v,
        .err => |e| return e,
    };
    if (ctx.args.len < 2 or stringBytes(ctx.args[1]) == null) {
        return typeErr("Regex.find requires a String");
    }
    const sr = ctx.args[1].String;
    const s = sr.asPtr().bytes;
    var start: usize = 0;
    if (ctx.args.len > 2) {
        const v = ctx.args[2];
        if (v.isIntegral()) {
            const n = v.asI64().?;
            start = if (n == 0) 0 else charIndexToByte(s, n);
        } else {
            return typeErr("Regex.find startIndex must be Int");
        }
    }
    const prog = progFromRegex(r) orelse return typeErr("Regex.find requires a Regex receiver");
    if (try runMatch(ctx.allocator, prog, s, start)) |caps| {
        defer ctx.allocator.free(caps);
        const md = try buildMatch(ctx.allocator, r, sr, caps);
        return ok(try matchValue(ctx.allocator, md));
    }
    return ok(.Null);
}

pub fn regex_find_all(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const r = switch (regexArg(ctx.args, "Regex.findAll")) {
        .ok => |v| v,
        .err => |e| return e,
    };
    if (ctx.args.len < 2 or stringBytes(ctx.args[1]) == null) {
        return typeErr("Regex.findAll requires a String");
    }
    const sr = ctx.args[1].String;
    const s = sr.asPtr().bytes;
    const prog = progFromRegex(r) orelse return typeErr("Regex.findAll requires a Regex receiver");

    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(ctx.allocator);
    var pos: usize = 0;
    while (true) {
        const caps = (try runMatch(ctx.allocator, prog, s, pos)) orelse break;
        defer ctx.allocator.free(caps);
        const m_start = caps[0].start.?;
        const m_end = caps[0].end.?;
        const md = try buildMatch(ctx.allocator, r, sr, caps);
        try items.append(ctx.allocator, try matchValue(ctx.allocator, md));
        // Advance: past the match, or one codepoint on a zero-width match.
        if (m_end > m_start) {
            pos = m_end;
        } else {
            if (m_end >= s.len) break;
            const len = std.unicode.utf8ByteSequenceLength(s[m_end]) catch 1;
            pos = m_end + (if (m_end + len <= s.len) len else 1);
        }
    }
    return ok(try makeSequence(ctx.allocator, items.items));
}

pub fn regex_match_entire(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const r = switch (regexArg(ctx.args, "Regex.matchEntire")) {
        .ok => |v| v,
        .err => |e| return e,
    };
    if (ctx.args.len < 2 or stringBytes(ctx.args[1]) == null) {
        return typeErr("Regex.matchEntire requires a String");
    }
    const sr = ctx.args[1].String;
    const s = sr.asPtr().bytes;
    const prog = progFromRegex(r) orelse return typeErr("Regex.matchEntire requires a Regex receiver");
    if (try runMatch(ctx.allocator, prog, s, 0)) |caps| {
        defer ctx.allocator.free(caps);
        if (caps[0].start == 0 and caps[0].end == s.len) {
            const md = try buildMatch(ctx.allocator, r, sr, caps);
            return ok(try matchValue(ctx.allocator, md));
        }
    }
    return ok(.Null);
}

pub fn regex_match_at(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const r = switch (regexArg(ctx.args, "Regex.matchAt")) {
        .ok => |v| v,
        .err => |e| return e,
    };
    if (ctx.args.len < 2 or stringBytes(ctx.args[1]) == null) {
        return typeErr("Regex.matchAt requires a String");
    }
    const sr = ctx.args[1].String;
    const s = sr.asPtr().bytes;
    const idx = if (ctx.args.len > 2) ctx.args[2].asI64() else null;
    if (idx == null) return typeErr("Regex.matchAt requires Int index");
    const byte = charIndexToByte(s, idx.?);
    const prog = progFromRegex(r) orelse return typeErr("Regex.matchAt requires a Regex receiver");
    if (try runMatch(ctx.allocator, prog, s, byte)) |caps| {
        defer ctx.allocator.free(caps);
        if (caps[0].start == byte) {
            const md = try buildMatch(ctx.allocator, r, sr, caps);
            return ok(try matchValue(ctx.allocator, md));
        }
    }
    return ok(.Null);
}

pub fn regex_matches_at(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const res = try regex_match_at(ctx);
    switch (res) {
        .err => return res,
        .ok => |v| return ok(.{ .Bool = v != .Null }),
    }
}

const RegexReplace = struct {
    first_only: bool,
    who: []const u8,
};

/// Shared engine for `Regex.replace` / `Regex.replaceFirst`.
fn performRegexReplace(
    ctx: *CallCtx,
    r: ObjRef(RegexData),
    sr: StringRef,
    repl: ?Value,
    cfg: RegexReplace,
) std.mem.Allocator.Error!EvalResult {
    const s = sr.asPtr().bytes;
    const prog = progFromRegex(r) orelse return typeErr("Regex.replace requires a Regex receiver");
    const allocator = ctx.allocator;

    if (repl == null) {
        return arityErr(try std.fmt.allocPrint(allocator, "{s} requires a replacement", .{cfg.who}));
    }

    if (repl.? == .String) {
        const template = repl.?.String.asPtr().bytes;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        var last: usize = 0;
        var pos: usize = 0;
        while (true) {
            const caps = (try runMatch(allocator, prog, s, pos)) orelse break;
            defer allocator.free(caps);
            const m_start = caps[0].start.?;
            const m_end = caps[0].end.?;
            try out.appendSlice(allocator, s[last..m_start]);
            last = m_end;
            const md = try buildMatch(allocator, r, sr, caps);
            const expanded = try expandKotlinReplacement(allocator, template, prog, md.groups);
            defer allocator.free(expanded);
            try out.appendSlice(allocator, expanded);
            if (cfg.first_only) break;
            if (m_end > m_start) {
                pos = m_end;
            } else {
                if (m_end >= s.len) break;
                const len = std.unicode.utf8ByteSequenceLength(s[m_end]) catch 1;
                pos = m_end + (if (m_end + len <= s.len) len else 1);
            }
        }
        try out.appendSlice(allocator, s[last..]);
        return ok(try makeStringOwned(allocator, try out.toOwnedSlice(allocator)));
    }

    // Callable replacement. Collect spans + match values first, then invoke.
    const block = repl.?;
    const Span = struct { start: usize, end: usize, match_value: Value };
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(allocator);
    var pos: usize = 0;
    while (true) {
        const caps = (try runMatch(allocator, prog, s, pos)) orelse break;
        defer allocator.free(caps);
        const m_start = caps[0].start.?;
        const m_end = caps[0].end.?;
        const md = try buildMatch(allocator, r, sr, caps);
        try spans.append(allocator, .{ .start = m_start, .end = m_end, .match_value = try matchValue(allocator, md) });
        if (cfg.first_only) break;
        if (m_end > m_start) {
            pos = m_end;
        } else {
            if (m_end >= s.len) break;
            const len = std.unicode.utf8ByteSequenceLength(s[m_end]) catch 1;
            pos = m_end + (if (m_end + len <= s.len) len else 1);
        }
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var last: usize = 0;
    for (spans.items) |span| {
        try out.appendSlice(allocator, s[last..span.start]);
        last = span.end;
        const rv = try ctx.host.invokeCallable(&block, &.{span.match_value}, ctx.out);
        switch (rv) {
            .err => return rv,
            .ok => |val| switch (val) {
                .String => |rs| try out.appendSlice(allocator, rs.asPtr().bytes),
                .Char => |c| {
                    const cs = try charUnitToString(allocator, c);
                    defer allocator.free(cs);
                    try out.appendSlice(allocator, cs);
                },
                else => return typeErr(try std.fmt.allocPrint(allocator, "{s} transform must return a CharSequence", .{cfg.who})),
            },
        }
    }
    try out.appendSlice(allocator, s[last..]);
    return ok(try makeStringOwned(allocator, try out.toOwnedSlice(allocator)));
}

pub fn regex_replace(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const r = switch (regexArg(ctx.args, "Regex.replace")) {
        .ok => |v| v,
        .err => |e| return e,
    };
    if (ctx.args.len < 2 or stringBytes(ctx.args[1]) == null) {
        return typeErr("Regex.replace requires a String");
    }
    const sr = ctx.args[1].String;
    const repl = if (ctx.args.len > 2) ctx.args[2] else null;
    return performRegexReplace(ctx, r, sr, repl, .{ .first_only = false, .who = "Regex.replace" });
}

pub fn regex_replace_first(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const r = switch (regexArg(ctx.args, "Regex.replaceFirst")) {
        .ok => |v| v,
        .err => |e| return e,
    };
    if (ctx.args.len < 2 or stringBytes(ctx.args[1]) == null) {
        return typeErr("Regex.replaceFirst requires a String");
    }
    const sr = ctx.args[1].String;
    const repl = if (ctx.args.len > 2) ctx.args[2] else null;
    return performRegexReplace(ctx, r, sr, repl, .{ .first_only = true, .who = "Regex.replaceFirst" });
}

pub fn regex_split(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const r = switch (regexArg(ctx.args, "Regex.split")) {
        .ok => |v| v,
        .err => |e| return e,
    };
    if (ctx.args.len < 2 or stringBytes(ctx.args[1]) == null) {
        return typeErr("Regex.split requires a String");
    }
    const sr = ctx.args[1].String;
    const s = sr.asPtr().bytes;
    var limit: i64 = 0;
    if (ctx.args.len > 2) {
        const v = ctx.args[2];
        if (v.isIntegral()) {
            limit = v.asI64().?;
        } else {
            return typeErr("Regex.split limit must be Int");
        }
    }
    const prog = progFromRegex(r) orelse return typeErr("Regex.split requires a Regex receiver");
    const parts = try splitItems(ctx.allocator, prog, s, limit);
    return ok(try makeList(ctx.allocator, parts, false));
}

pub fn regex_split_to_sequence(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const r = switch (regexArg(ctx.args, "Regex.splitToSequence")) {
        .ok => |v| v,
        .err => |e| return e,
    };
    if (ctx.args.len < 2 or stringBytes(ctx.args[1]) == null) {
        return typeErr("Regex.splitToSequence requires a String");
    }
    const sr = ctx.args[1].String;
    const s = sr.asPtr().bytes;
    var limit: i64 = 0;
    if (ctx.args.len > 2) {
        const v = ctx.args[2];
        if (v.isIntegral()) {
            limit = v.asI64().?;
        } else {
            return typeErr("Regex.splitToSequence limit must be Int");
        }
    }
    const prog = progFromRegex(r) orelse return typeErr("Regex.splitToSequence requires a Regex receiver");
    const parts = try splitItems(ctx.allocator, prog, s, limit);
    defer ctx.allocator.free(parts);
    return ok(try makeSequence(ctx.allocator, parts));
}

/// Split `s` on every match of `prog`, mirroring the `regex` crate's
/// `split` / `splitn`. `limit <= 0` is unbounded; `limit > 0` caps the
/// result at `limit` parts. Caller owns the returned slice.
fn splitItems(allocator: std.mem.Allocator, prog: *const Program, s: []const u8, limit: i64) ![]Value {
    var items: std.ArrayList(Value) = .empty;
    errdefer items.deinit(allocator);
    var last: usize = 0;
    var pos: usize = 0;
    while (true) {
        if (limit > 0 and @as(i64, @intCast(items.items.len)) >= limit - 1) break;
        const caps = (try runMatch(allocator, prog, s, pos)) orelse break;
        defer allocator.free(caps);
        const m_start = caps[0].start.?;
        const m_end = caps[0].end.?;
        // Rust's split skips an empty match at the very start.
        if (m_end == 0 and m_start == 0) {
            if (s.len == 0) break;
            const len = std.unicode.utf8ByteSequenceLength(s[0]) catch 1;
            pos = if (len <= s.len) len else 1;
            continue;
        }
        try items.append(allocator, try makeString(allocator, s[last..m_start]));
        last = m_end;
        if (m_end > m_start) {
            pos = m_end;
        } else {
            if (m_end >= s.len) break;
            const len = std.unicode.utf8ByteSequenceLength(s[m_end]) catch 1;
            pos = m_end + (if (m_end + len <= s.len) len else 1);
        }
    }
    try items.append(allocator, try makeString(allocator, s[last..]));
    return items.toOwnedSlice(allocator);
}

// ============================================================
// Entry points for `String.split/replace/replaceFirst(Regex, …)`
// ============================================================

/// `String.split(Regex)` / `splitToSequence(Regex)`: the receiver string
/// `sr` split on `r`, honoring the optional `limit`. Returns the part
/// values so the caller can wrap them as a List or Sequence.
pub fn stringRegexSplitItems(
    ctx: *CallCtx,
    sr: StringRef,
    r: ObjRef(RegexData),
    limit: i64,
) std.mem.Allocator.Error!union(enum) { ok: []Value, err: RuntimeError } {
    const prog = progFromRegex(r) orelse return .{ .err = .{ .Type = "split requires a Regex" } };
    const parts = try splitItems(ctx.allocator, prog, sr.asPtr().bytes, limit);
    return .{ .ok = parts };
}

/// `String.replace(Regex, …)` / `String.replaceFirst(Regex, …)`: the
/// receiver string `sr` with matches of `r` rewritten by `repl` (a Kotlin
/// `$group` template, or a `(MatchResult) -> CharSequence` callable).
pub fn stringRegexReplace(
    ctx: *CallCtx,
    sr: StringRef,
    r: ObjRef(RegexData),
    repl: ?Value,
    first_only: bool,
    comptime who: []const u8,
) std.mem.Allocator.Error!EvalResult {
    return performRegexReplace(ctx, r, sr, repl, .{ .first_only = first_only, .who = who });
}

pub fn regex_static_escape(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const s = if (ctx.args.len > 0) stringBytes(ctx.args[0]) else null;
    if (s == null) return typeErr("Regex.escape requires a String literal");
    const escaped = try kotlinLiteralEscape(ctx.allocator, s.?);
    return ok(try makeStringOwned(ctx.allocator, escaped));
}

pub fn regex_from_literal(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const s = if (ctx.args.len > 0) stringBytes(ctx.args[0]) else null;
    if (s == null) return typeErr("Regex.fromLiteral requires a String");
    const escaped = try kotlinLiteralEscape(ctx.allocator, s.?);
    defer ctx.allocator.free(escaped);
    return compileRegex(ctx.allocator, escaped);
}

pub fn regex_static_escape_replacement(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const s = if (ctx.args.len > 0) stringBytes(ctx.args[0]) else null;
    if (s == null) return typeErr("Regex.escapeReplacement requires a String");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ctx.allocator);
    for (s.?) |c| {
        if (c == '$' or c == '\\') try out.append(ctx.allocator, '\\');
        try out.append(ctx.allocator, c);
    }
    return ok(try makeStringOwned(ctx.allocator, try out.toOwnedSlice(ctx.allocator)));
}

// ============================================================
// Intrinsics — MatchResult
// ============================================================

pub fn match_result_value(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const m = switch (matchArg(ctx.args, "MatchResult.value")) {
        .ok => |v| v,
        .err => |e| return e,
    };
    const groups = m.asPtr().groups;
    if (groups.len == 0 or groups[0] == null) {
        return typeErr("MatchResult has no whole-match group");
    }
    return ok(.{ .String = groups[0].?.value.clone() });
}

pub fn match_result_range(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const m = switch (matchArg(ctx.args, "MatchResult.range")) {
        .ok => |v| v,
        .err => |e| return e,
    };
    const groups = m.asPtr().groups;
    if (groups.len == 0 or groups[0] == null) {
        return typeErr("MatchResult has no whole-match group");
    }
    const g0 = groups[0].?;
    return ok(.{ .Range = .{ .start = g0.start, .end = g0.end_inclusive, .step = 1, .kind = RangeKind.Int } });
}

pub fn match_result_group_values(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const m = switch (matchArg(ctx.args, "MatchResult.groupValues")) {
        .ok => |v| v,
        .err => |e| return e,
    };
    const groups = m.asPtr().groups;
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(ctx.allocator);
    for (groups) |g| {
        if (g) |gd| {
            try items.append(ctx.allocator, .{ .String = gd.value.clone() });
        } else {
            try items.append(ctx.allocator, try makeString(ctx.allocator, ""));
        }
    }
    return ok(try makeList(ctx.allocator, items.items, false));
}

pub fn match_result_groups(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const m = switch (matchArg(ctx.args, "MatchResult.groups")) {
        .ok => |v| v,
        .err => |e| return e,
    };
    const groups = m.asPtr().groups;
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(ctx.allocator);
    for (groups) |g| {
        if (g) |gd| {
            try items.append(ctx.allocator, .{ .MatchGroup = .{
                .value = gd.value.clone(),
                .start = gd.start,
                .end_inclusive = gd.end_inclusive,
            } });
        } else {
            try items.append(ctx.allocator, .Null);
        }
    }
    return ok(try makeList(ctx.allocator, items.items, false));
}

pub fn match_result_next(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const m = switch (matchArg(ctx.args, "MatchResult.next")) {
        .ok => |v| v,
        .err => |e| return e,
    };
    const md = m.asPtr();
    const input = md.input.asPtr().bytes;
    var start = md.end_byte;
    // Avoid infinite loops on zero-width matches: advance one codepoint.
    if (md.groups.len > 0) {
        if (md.groups[0]) |g| {
            if (g.end_inclusive < g.start) {
                if (start < input.len) {
                    const len = std.unicode.utf8ByteSequenceLength(input[start]) catch 1;
                    start = if (start + len <= input.len) start + len else input.len;
                } else {
                    start = input.len;
                }
            }
        }
    }
    if (start > input.len) return ok(.Null);
    const prog = progFromRegex(md.regex) orelse return typeErr("MatchResult.next requires a Regex");
    if (try runMatch(ctx.allocator, prog, input, start)) |caps| {
        defer ctx.allocator.free(caps);
        const next_md = try buildMatch(ctx.allocator, md.regex, md.input, caps);
        return ok(try matchValue(ctx.allocator, next_md));
    }
    return ok(.Null);
}

pub fn match_result_to_string(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const m = switch (matchArg(ctx.args, "MatchResult.toString")) {
        .ok => |v| v,
        .err => |e| return e,
    };
    const groups = m.asPtr().groups;
    if (groups.len > 0) {
        if (groups[0]) |g| {
            return ok(.{ .String = g.value.clone() });
        }
    }
    return ok(try makeString(ctx.allocator, ""));
}

// ============================================================
// Intrinsics — MatchGroup
// ============================================================

pub fn match_group_value(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len > 0) {
        switch (ctx.args[0]) {
            .MatchGroup => |g| return ok(.{ .String = g.value.clone() }),
            else => {},
        }
    }
    return typeErr("MatchGroup.value requires a MatchGroup receiver");
}

pub fn match_group_range(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len > 0) {
        switch (ctx.args[0]) {
            .MatchGroup => |g| return ok(.{ .Range = .{
                .start = g.start,
                .end = g.end_inclusive,
                .step = 1,
                .kind = RangeKind.Int,
            } }),
            else => {},
        }
    }
    return typeErr("MatchGroup.range requires a MatchGroup receiver");
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn compileForTest(a: std.mem.Allocator, pattern: []const u8) !*Program {
    return compileForTestFlags(a, pattern, .{});
}

fn compileForTestFlags(a: std.mem.Allocator, pattern: []const u8, flags: Flags) !*Program {
    const prepared = try preprocessPattern(a, pattern);
    defer a.free(prepared);
    const prog = (try compileProgram(a, prepared)).?;
    prog.flags = flags;
    return prog;
}

test "literal match and offsets" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prog = try compileForTest(a, "ab");
    const caps = (try runMatch(a, prog, "xxabxx", 0)).?;
    try testing.expectEqual(@as(?usize, 2), caps[0].start);
    try testing.expectEqual(@as(?usize, 4), caps[0].end);
}

test "no match returns null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prog = try compileForTest(a, "zzz");
    try testing.expect((try runMatch(a, prog, "abc", 0)) == null);
}

test "greedy quantifier consumes maximally" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prog = try compileForTest(a, "a+");
    const caps = (try runMatch(a, prog, "aaab", 0)).?;
    try testing.expectEqual(@as(?usize, 0), caps[0].start);
    try testing.expectEqual(@as(?usize, 3), caps[0].end);
}

test "lazy quantifier consumes minimally" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prog = try compileForTest(a, "a+?");
    const caps = (try runMatch(a, prog, "aaab", 0)).?;
    try testing.expectEqual(@as(?usize, 0), caps[0].start);
    try testing.expectEqual(@as(?usize, 1), caps[0].end);
}

test "capture groups" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prog = try compileForTest(a, "(a)(b)");
    try testing.expectEqual(@as(usize, 3), prog.group_count);
    const caps = (try runMatch(a, prog, "ab", 0)).?;
    try testing.expectEqual(@as(?usize, 0), caps[1].start);
    try testing.expectEqual(@as(?usize, 1), caps[1].end);
    try testing.expectEqual(@as(?usize, 1), caps[2].start);
    try testing.expectEqual(@as(?usize, 2), caps[2].end);
}

test "named group lookup" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prog = try compileForTest(a, "(?<year>\\d+)");
    try testing.expectEqual(@as(?usize, 1), groupIndexByName(prog, "year"));
}

test "alternation prefers first branch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prog = try compileForTest(a, "ab|abc");
    const caps = (try runMatch(a, prog, "abc", 0)).?;
    try testing.expectEqual(@as(?usize, 2), caps[0].end);
}

test "character class and digit shorthand" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prog = try compileForTest(a, "[a-c]\\d");
    const caps = (try runMatch(a, prog, "b7", 0)).?;
    try testing.expectEqual(@as(?usize, 0), caps[0].start);
    try testing.expectEqual(@as(?usize, 2), caps[0].end);
    try testing.expect((try runMatch(a, prog, "d7", 0)) == null);
}

test "negated class" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prog = try compileForTest(a, "[^0-9]+");
    const caps = (try runMatch(a, prog, "abc123", 0)).?;
    try testing.expectEqual(@as(?usize, 3), caps[0].end);
}

test "anchors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prog = try compileForTest(a, "^abc$");
    try testing.expect((try runMatch(a, prog, "abc", 0)) != null);
    try testing.expect((try runMatch(a, prog, "xabc", 0)) == null);
}

test "word boundary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prog = try compileForTest(a, "\\bcat\\b");
    const caps = (try runMatch(a, prog, "a cat sat", 0)).?;
    try testing.expectEqual(@as(?usize, 2), caps[0].start);
    try testing.expect((try runMatch(a, prog, "category", 0)) == null);
}

test "counted quantifier" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prog = try compileForTest(a, "a{2,3}");
    const caps = (try runMatch(a, prog, "aaaa", 0)).?;
    try testing.expectEqual(@as(?usize, 3), caps[0].end);
}

test "dot does not match newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prog = try compileForTest(a, "a.b");
    try testing.expect((try runMatch(a, prog, "a\nb", 0)) == null);
    try testing.expect((try runMatch(a, prog, "axb", 0)) != null);
}

test "preprocess Q E literal block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prepared = try preprocessPattern(a, "\\Qa.b\\E");
    try testing.expectEqualStrings("a\\.b", prepared);
}

test "kotlin literal escape wraps in Q E" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e = try kotlinLiteralEscape(a, "abc");
    try testing.expectEqualStrings("\\Qabc\\E", e);
    const empty = try kotlinLiteralEscape(a, "");
    try testing.expectEqualStrings("\\Q\\E", empty);
}

test "kotlin literal escape splits on embedded E sentinel" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e = try kotlinLiteralEscape(a, "a\\Eb");
    try testing.expectEqualStrings("\\Qa\\E\\E\\\\E\\Q\\Qb\\E", e);
}

test "byte to char counts utf16 units" {
    // 'a' + U+1F600 (4 UTF-8 bytes, 2 UTF-16 units) + 'b'.
    const s = "a\u{1F600}b";
    try testing.expectEqual(@as(i64, 0), byteToChar(s, 0));
    try testing.expectEqual(@as(i64, 1), byteToChar(s, 1));
    try testing.expectEqual(@as(i64, 3), byteToChar(s, 5));
}

test "char index to byte" {
    const s = "a\u{1F600}b";
    try testing.expectEqual(@as(usize, 0), charIndexToByte(s, 0));
    try testing.expectEqual(@as(usize, 1), charIndexToByte(s, 1));
    try testing.expectEqual(@as(usize, 5), charIndexToByte(s, 2));
}

test "expand kotlin replacement by index and name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prog = try compileForTest(a, "(?<w>\\w+)");
    const caps = (try runMatch(a, prog, "hi", 0)).?;
    var groups = try a.alloc(?MatchGroupData, caps.len);
    for (caps, 0..) |c, i| {
        if (c.start) |st| {
            const en = c.end.?;
            groups[i] = .{ .value = try runtime.strInitOwned(a, try a.dupe(u8, "hi"[st..en])), .start = 0, .end_inclusive = 1 };
        } else groups[i] = null;
    }
    const out1 = try expandKotlinReplacement(a, "[$1]", prog, groups);
    try testing.expectEqualStrings("[hi]", out1);
    const out2 = try expandKotlinReplacement(a, "[${w}]", prog, groups);
    try testing.expectEqualStrings("[hi]", out2);
    const out3 = try expandKotlinReplacement(a, "\\$1", prog, groups);
    try testing.expectEqualStrings("$1", out3);
}

test "escape replacement escapes dollar and backslash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    for ("a$b\\c") |c| {
        if (c == '$' or c == '\\') try out.append(a, '\\');
        try out.append(a, c);
    }
    try testing.expectEqualStrings("a\\$b\\\\c", out.items);
}

test "compile invalid pattern returns null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prepared = try preprocessPattern(a, "(unclosed");
    try testing.expect((try compileProgram(a, prepared)) == null);
}

test "IGNORE_CASE folds literals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cs = try compileForTest(a, "hi");
    try testing.expect((try runMatch(a, cs, "Hi", 0)) == null);
    const ci = try compileForTestFlags(a, "hi", .{ .case_insensitive = true });
    const caps = (try runMatch(a, ci, "Hi", 0)).?;
    try testing.expectEqual(@as(?usize, 0), caps[0].start);
    try testing.expectEqual(@as(?usize, 2), caps[0].end);
}

test "IGNORE_CASE folds character classes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ci = try compileForTestFlags(a, "[a-z]+", .{ .case_insensitive = true });
    const caps = (try runMatch(a, ci, "ABC", 0)).?;
    try testing.expectEqual(@as(?usize, 3), caps[0].end);
    // Negation still rejects a case-variant.
    const neg = try compileForTestFlags(a, "[^a-z]", .{ .case_insensitive = true });
    try testing.expect((try runMatch(a, neg, "A", 0)) == null);
}

test "MULTILINE anchors match at line boundaries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const single = try compileForTest(a, "^b");
    try testing.expect((try runMatch(a, single, "a\nb", 0)) == null);
    const ml = try compileForTestFlags(a, "^b", .{ .multiline = true });
    const caps = (try runMatch(a, ml, "a\nb", 0)).?;
    try testing.expectEqual(@as(?usize, 2), caps[0].start);
    try testing.expectEqual(@as(?usize, 3), caps[0].end);
    // `$` at a line terminator under MULTILINE.
    const eol = try compileForTestFlags(a, "b$", .{ .multiline = true });
    const ecaps = (try runMatch(a, eol, "ab\ncb", 0)).?;
    try testing.expectEqual(@as(?usize, 1), ecaps[0].start);
}
