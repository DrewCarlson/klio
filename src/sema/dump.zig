//! The resolution of program files in the oracle's line format
//! (tools/sema-oracle/README.md): one line per resolved reference,
//!
//!     path  start  end  kind  target  dispatch  extension
//!
//! sorted by path, then start, end, kind and target, so a dump diffs site by
//! site against `scripts/sema-oracle.sh` with `scripts/sema-oracle-diff.py`.

const std = @import("std");
const span = @import("span");

const lexer = @import("lexer");

const sema_mod = @import("sema.zig");
const records = @import("records.zig");
const render = @import("render.zig");
const names_mod = @import("names.zig");

const Allocator = std.mem.Allocator;
const Sema = sema_mod.Sema;

pub const Line = struct {
    path: []const u8,
    start: u32,
    end: u32,
    kind: []const u8,
    target: []const u8,
    dispatch: []const u8,
    extension: []const u8,

    fn lessThan(_: void, a: Line, b: Line) bool {
        if (!std.mem.eql(u8, a.path, b.path)) return std.mem.lessThan(u8, a.path, b.path);
        if (a.start != b.start) return a.start < b.start;
        if (a.end != b.end) return a.end < b.end;
        if (!std.mem.eql(u8, a.kind, b.kind)) return std.mem.lessThan(u8, a.kind, b.kind);
        return std.mem.lessThan(u8, a.target, b.target);
    }
};

/// The oracle's name for a reference kind. Conventions resolved by name
/// (`plus`, `component2`, `plusAssign`) print the name they resolved.
pub fn kindName(s: *Sema, r: records.Ref) []const u8 {
    return switch (r.kind) {
        .call => "call",
        .read, .object => "read",
        .write => "write",
        .ctor => "ctor",
        .get => "get",
        .set => "set",
        .invoke => "invoke",
        .iterator => "iterator",
        .has_next => "hasNext",
        .next => "next",
        .get_value => "getValue",
        .set_value => "setValue",
        .provide_delegate => "provideDelegate",
        .compare_to => "compareTo",
        .equals => "equals",
        .contains => "contains",
        .range_to => "rangeTo",
        .range_until => "rangeUntil",
        .inc => "inc",
        .dec => "dec",
        .ref => "ref",
        // kotlinc reports no reference for a class literal; the writer
        // skips these.
        .class_literal => "classLiteral",
        // Lowering's records; kotlinc reports none, and the writer skips
        // them.
        .this_ => "this",
        .return_ => "return",
        .decl => "decl",
        .type_test => "typeTest",
        .op, .op_assign, .component => if (r.op != .empty) s.str(r.op) else @tagName(r.kind),
    };
}

/// Kinds anchored on a name rather than on a whole expression.
fn namedKind(k: records.RefKind) bool {
    return switch (k) {
        .call, .read, .write, .ctor, .ref, .object => true,
        else => false,
    };
}

/// A program file's text and code tokens. The parser's spans and kotlinc's
/// PSI disagree in a few places the dump corrects from the text: a
/// declaration's start (modifiers, annotations and bound comments), an
/// operand's parentheses, and the name inside a longer anchor.
pub const FileText = struct {
    text: []const u8,
    toks: []const lexer.Token,
    /// Per token: a line break separates it from the token before.
    line_start: []const bool,

    pub fn init(a: Allocator, file: span.FileId, text: []const u8) Allocator.Error!FileText {
        var lx = try lexer.Lexer.init(a, file, text);
        const lexed = try lx.tokenize();
        var toks: std.ArrayList(lexer.Token) = .empty;
        var line_start: std.ArrayList(bool) = .empty;
        var nl = true;
        for (lexed.tokens) |tk| switch (tk.kind) {
            .Newline => nl = true,
            .Eof => {},
            else => {
                try toks.append(a, tk);
                try line_start.append(a, nl);
                nl = false;
            },
        };
        return .{ .text = text, .toks = toks.items, .line_start = line_start.items };
    }

    /// The index of the first token starting at or after `off`.
    fn lowerBound(self: *const FileText, off: u32) usize {
        var lo: usize = 0;
        var hi: usize = self.toks.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (self.toks[mid].span.start < off) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// The token that starts exactly at `off`.
    fn at(self: *const FileText, off: u32) ?usize {
        const i = self.lowerBound(off);
        if (i < self.toks.len and self.toks[i].span.start == off) return i;
        return null;
    }

    fn word(self: *const FileText, i: usize) []const u8 {
        const sp = self.toks[i].span;
        return self.text[sp.start..sp.end];
    }

    fn isKeyword(self: *const FileText, i: usize, kw: lexer.Keyword) bool {
        return switch (self.toks[i].kind) {
            .Keyword => |k| k == kw,
            else => false,
        };
    }

    fn matchingOpen(self: *const FileText, close: usize) ?usize {
        var depth: usize = 0;
        var i = close + 1;
        while (i > 0) {
            i -= 1;
            switch (self.toks[i].kind) {
                .RParen => depth += 1,
                .LParen => {
                    depth -= 1;
                    if (depth == 0) return i;
                },
                else => {},
            }
        }
        return null;
    }

    fn matchingClose(self: *const FileText, open: usize) ?usize {
        var depth: usize = 0;
        for (self.toks[open..], open..) |tk, i| {
            switch (tk.kind) {
                .LParen => depth += 1,
                .RParen => {
                    depth -= 1;
                    if (depth == 0) return i;
                },
                else => {},
            }
        }
        return null;
    }

    /// The `@` of an annotation whose name ends at token `last`: `@Ann`,
    /// `@a.b.Ann`, `@field:Ann`.
    fn annotationStart(self: *const FileText, last: usize) ?usize {
        if (self.toks[last].kind != .Ident) return null;
        var k = last;
        while (k >= 2 and self.toks[k - 1].kind == .Dot and self.toks[k - 2].kind == .Ident) k -= 2;
        if (k >= 1 and self.toks[k - 1].kind.isAt()) return k - 1;
        if (k >= 3 and self.toks[k - 1].kind == .Colon and self.toks[k - 2].kind == .Ident and self.toks[k - 3].kind.isAt()) return k - 3;
        return null;
    }

    const modifiers = std.StaticStringMap(void).initComptime(.{
        .{"public"},     .{"private"},  .{"protected"}, .{"internal"},
        .{"open"},       .{"final"},    .{"abstract"},  .{"sealed"},
        .{"override"},   .{"inline"},   .{"noinline"},  .{"crossinline"},
        .{"suspend"},    .{"tailrec"},  .{"operator"},  .{"infix"},
        .{"external"},   .{"const"},    .{"lateinit"},  .{"data"},
        .{"inner"},      .{"enum"},     .{"annotation"}, .{"companion"},
        .{"value"},      .{"expect"},   .{"actual"},    .{"vararg"},
    });

    /// Where kotlinc's PSI starts the declaration the parser starts at
    /// `start`: back over its modifiers, annotations and `val`/`var`, then
    /// back over the comments kotlinc's comment binder attaches to it.
    pub fn declStart(self: *const FileText, start: u32, bind: Bind) u32 {
        var i = self.at(start) orelse return start;
        while (i > 0) {
            const j = i - 1;
            // A modifier shares the line of what it modifies; a word ending
            // the line above belongs to the statement before. Annotations
            // may stand on lines of their own.
            const same_line = !self.line_start[i];
            switch (self.toks[j].kind) {
                .Ident => {
                    if (same_line and modifiers.has(self.word(j))) {
                        i = j;
                        continue;
                    }
                    i = self.annotationStart(j) orelse break;
                },
                .Keyword => |kw| {
                    if (!same_line or (kw != .Val and kw != .Var)) break;
                    i = j;
                },
                .RParen => {
                    const open = self.matchingOpen(j) orelse break;
                    if (open == 0) break;
                    i = self.annotationStart(open - 1) orelse break;
                },
                else => break,
            }
        }
        const begin = self.toks[i].span.start;
        if (bind == .none) return begin;
        const gap_start: u32 = if (i == 0) 0 else self.toks[i - 1].span.end;
        return boundComments(self.text, gap_start, begin, bind);
    }
};

/// Which preceding comments a declaration's PSI takes: kotlinc binds a
/// doc comment to every declaration, and plain comments too to local
/// functions and classes (`closeDeclarationWithCommentBinders` with
/// `precedingNonDocComments` false for properties). A parameter binds none.
pub const Bind = enum { none, doc, all };

const Trivia = struct { start: u32, kind: enum { space, comment, doc }, newlines: u32 = 0 };

/// Kotlin's preceding-comment binders over the trivia in `text[gap..decl]`:
/// the nearest doc comment binds wherever it is; otherwise, under `.all`,
/// plain comments that start a line bind, up to a blank line.
fn boundComments(text: []const u8, gap: u32, decl: u32, bind: Bind) u32 {
    var items: [64]Trivia = undefined;
    var n: usize = 0;
    var pos = gap;
    while (pos < decl) {
        if (n == items.len) return decl;
        const c = text[pos];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c) {
            var nl: u32 = 0;
            const s0 = pos;
            while (pos < decl and (text[pos] == ' ' or text[pos] == '\t' or text[pos] == '\n' or text[pos] == '\r' or text[pos] == 0x0c)) : (pos += 1) {
                if (text[pos] == '\n') nl += 1;
            }
            items[n] = .{ .start = s0, .kind = .space, .newlines = nl };
        } else if (std.mem.startsWith(u8, text[pos..decl], "//")) {
            const s0 = pos;
            while (pos < decl and text[pos] != '\n') pos += 1;
            items[n] = .{ .start = s0, .kind = .comment };
        } else if (std.mem.startsWith(u8, text[pos..decl], "/*")) {
            const s0 = pos;
            const doc = std.mem.startsWith(u8, text[pos..decl], "/**") and !std.mem.startsWith(u8, text[pos..decl], "/**/");
            var depth: usize = 0;
            while (pos < decl) {
                if (std.mem.startsWith(u8, text[pos..decl], "/*")) {
                    depth += 1;
                    pos += 2;
                } else if (std.mem.startsWith(u8, text[pos..decl], "*/")) {
                    depth -= 1;
                    pos += 2;
                    if (depth == 0) break;
                } else pos += 1;
            }
            items[n] = .{ .start = s0, .kind = if (doc) .doc else .comment };
        } else return decl;
        n += 1;
    }
    var idx = n;
    while (idx > 0) {
        idx -= 1;
        if (items[idx].kind == .doc) return items[idx].start;
    }
    if (bind != .all) return decl;
    var result: ?u32 = null;
    idx = n;
    while (idx > 0) {
        idx -= 1;
        switch (items[idx].kind) {
            .space => if (items[idx].newlines > 1) break,
            .comment => {
                if (idx == 0 or (items[idx - 1].kind == .space and items[idx - 1].newlines > 0)) result = items[idx].start;
            },
            .doc => unreachable,
        }
    }
    return result orelse decl;
}

/// The texts of the program files, by analysis file index, and the namer
/// that reads declaration starts from them.
const Texts = struct {
    s: *Sema,
    files: std.AutoHashMapUnmanaged(u32, FileText) = .empty,

    fn declStart(ctx: *const anyopaque, sym: sema_mod.Sym, start: u32) u32 {
        const self: *const Texts = @ptrCast(@alignCast(ctx));
        const s = self.s;
        const file = s.syms.get(sym).file;
        const ft = self.files.getPtr(file) orelse return start;
        return switch (s.syms.get(sym).decl) {
            .function, .class, .object => ft.declStart(start, .all),
            .local_prop => ft.declStart(start, .doc),
            // `val x by d` and `when (val v = s)` are properties, spanned
            // by the parser from the name; a `for` variable or a lambda
            // parameter starts at its annotations.
            .ident => blk: {
                const i = ft.at(start) orelse break :blk start;
                // The implicit `it` is spanned by its lambda's `{`.
                if (ft.toks[i].kind == .LBrace) break :blk start;
                const is_prop = i > 0 and (ft.isKeyword(i - 1, .Val) or ft.isKeyword(i - 1, .Var));
                break :blk ft.declStart(start, if (is_prop) .doc else .none);
            },
            .param, .class_param, .context_param => ft.declStart(start, .none),
            else => start,
        };
    }
};

/// Appends a line for every reference resolved in a program file. `map`
/// holds the files' text, which declaration starts and anchors are read
/// from; without it the parser's spans print as they are.
pub fn collect(s: *Sema, arena: Allocator, map: ?*const span.SourceMap, out: *std.ArrayList(Line)) Allocator.Error!void {
    var texts: Texts = .{ .s = s };
    if (map) |m| {
        for (s.files.items, 0..) |fc, i| {
            if (fc.origin != .program) continue;
            const id = fc.ast.?.span.file;
            if (id.int() >= m.files.items.len) continue;
            const ft = try FileText.init(arena, id, m.get(id).source);
            try texts.files.put(arena, @intCast(i), ft);
        }
    }
    const namer: render.Namer = .{ .s = s, .a = arena, .decl_start = &Texts.declStart, .ctx = &texts };
    for (s.refs.items) |r| {
        if (r.kind == .class_literal or r.kind == .this_ or r.kind == .return_ or r.kind == .decl or r.kind == .type_test) continue;
        const fc = s.fileOf(r.file) orelse continue;
        if (fc.origin != .program) continue;
        var start = r.anchor.start;
        var end = r.anchor.end;
        var kind = kindName(s, r);
        var dispatch = try namer.receiver(r.dispatch);
        if (texts.files.getPtr(r.file)) |ft| {
            if (skipped(s, ft, r)) continue;
            anchorFix(s, ft, r, &start, &end);
            // `f(x)` on a value, `obj(x)` with `operator fun invoke`: the
            // analysis records a call of `invoke`, kotlinc an invoke.
            if (r.kind == .call and s.syms.name(r.target) == names_mod.wk.invoke and !std.mem.eql(u8, ft.text[start..end], "invoke")) kind = "invoke";
        }
        // A backing field is read through the property's receiver.
        if (render.backingFieldOf(s, r.target)) |prop| {
            const owner = s.syms.owner(prop);
            if (r.dispatch == .none and owner != .none and s.syms.kind(owner) == .class) dispatch = try namer.classReceiver(owner);
        }
        try out.append(arena, .{
            .path = fc.path,
            .start = start,
            .end = end,
            .kind = kind,
            .target = try namer.target(r.target),
            .dispatch = dispatch,
            // `a.f()` for a value `f: A.() -> B` passes `a` as the first
            // argument of `invoke`, which has no extension receiver.
            .extension = if (render.isFunctionInvoke(s, r.target)) "-" else try namer.receiver(r.extension),
        });
    }
}

/// A reference kotlinc has no site for: a compiler temporary (the parser
/// names its desugaring locals with a `$`), or the enum constructor an
/// entry without arguments calls.
fn skipped(s: *Sema, ft: *const FileText, r: records.Ref) bool {
    switch (s.syms.kind(r.target)) {
        .local, .value_param => {
            const name = s.str(s.syms.name(r.target));
            return name.len != 0 and name[0] == '$';
        },
        else => {},
    }
    if (r.kind != .ctor or s.syms.kind(r.target) != .constructor) return false;
    const cls = s.syms.owner(r.target);
    if (cls == .none or s.syms.kind(cls) != .class or s.syms.classInfo(cls).kind != .enum_class) return false;
    for (s.syms.classInfo(cls).enum_entries) |e| {
        const decl = s.syms.get(e).decl;
        if (decl != .enum_entry or (decl.enum_entry orelse continue).name.span.start != r.anchor.start) continue;
        const i = ft.at(r.anchor.start) orelse return false;
        return i + 1 >= ft.toks.len or ft.toks[i + 1].kind != .LParen;
    }
    return false;
}

/// Moves an anchor from the parser's span to kotlinc's PSI element.
fn anchorFix(s: *Sema, ft: *const FileText, r: records.Ref, start: *u32, end: *u32) void {
    _ = s;
    const text = ft.text;
    if (start.* >= text.len or end.* > text.len or start.* >= end.*) return;
    // `"$name"`, `$$"$$name"`: the entry spans its `$`s; kotlinc anchors
    // the name.
    if (text[start.*] == '$') {
        var p = start.*;
        while (p < end.* and text[p] == '$') p += 1;
        if (p < end.*) start.* = p;
        return;
    }
    if (namedKind(r.kind)) {
        const i = ft.at(start.*) orelse return;
        // `constructor(...) : this(...)`: the delegation call is anchored
        // on its keyword.
        if (r.kind == .ctor and ft.toks[i].kind == .Ident and std.mem.eql(u8, ft.word(i), "constructor")) {
            if (i + 1 < ft.toks.len and ft.toks[i + 1].kind == .LParen) {
                const close = ft.matchingClose(i + 1) orelse return;
                if (close + 2 < ft.toks.len and ft.toks[close + 1].kind == .Colon and
                    (ft.isKeyword(close + 2, .This) or ft.isKeyword(close + 2, .Super)))
                {
                    start.* = ft.toks[close + 2].span.start;
                    end.* = ft.toks[close + 2].span.end;
                }
            }
            return;
        }
        // `ArrayList<String>()`: the anchor is the name alone.
        switch (ft.toks[i].kind) {
            .Ident, .Keyword => if (ft.toks[i].span.end < end.*) {
                end.* = ft.toks[i].span.end;
            },
            else => {},
        }
        return;
    }
    // The parser drops parentheses, so an operand's span stops inside
    // them; kotlinc anchors the whole parenthesized expression.
    var lo = ft.lowerBound(start.*);
    var hi = ft.lowerBound(end.*);
    var open: usize = 0;
    var unmatched_close: usize = 0;
    for (ft.toks[lo..hi]) |tk| switch (tk.kind) {
        .LParen => open += 1,
        .RParen => if (open > 0) {
            open -= 1;
        } else {
            unmatched_close += 1;
        },
        else => {},
    };
    while (unmatched_close > 0 and lo > 0 and ft.toks[lo - 1].kind == .LParen) : (unmatched_close -= 1) lo -= 1;
    while (open > 0 and hi < ft.toks.len and ft.toks[hi].kind == .RParen) : (open -= 1) hi += 1;
    if (lo < ft.toks.len) start.* = @min(start.*, ft.toks[lo].span.start);
    if (hi > 0) end.* = @max(end.*, ft.toks[hi - 1].span.end);
    // `when (x) { in c -> }`: the condition `in c`, `!in c`.
    if (r.kind == .contains and lo > 0 and ft.isKeyword(lo - 1, .In)) {
        var k = lo - 1;
        if (k > 0 and ft.toks[k - 1].kind.isBang() and ft.toks[k - 1].span.end == ft.toks[k].span.start) k -= 1;
        start.* = ft.toks[k].span.start;
    }
}

/// Sorts `lines` and formats them as TSV.
pub fn format(arena: Allocator, lines: []Line) Allocator.Error![]const u8 {
    std.mem.sort(Line, lines, {}, Line.lessThan);
    var buf: std.ArrayList(u8) = .empty;
    for (lines) |l| {
        try buf.print(arena, "{s}\t{d}\t{d}\t{s}\t{s}\t{s}\t{s}\n", .{ l.path, l.start, l.end, l.kind, l.target, l.dispatch, l.extension });
    }
    return buf.items;
}

/// Writes the program files' references to `path`.
pub fn writeTsv(s: *Sema, arena: Allocator, map: ?*const span.SourceMap, path: []const u8) !void {
    var lines: std.ArrayList(Line) = .empty;
    try collect(s, arena, map, &lines);
    const text = try format(arena, lines.items);
    var threaded: std.Io.Threaded = .init(arena, .{});
    defer threaded.deinit();
    try std.Io.Dir.cwd().writeFile(threaded.io(), .{ .sub_path = path, .data = text });
}

fn dumpOf(src: []const u8) ![]const u8 {
    const tests = @import("tests.zig");
    var fx = try tests.fixture(&.{src});
    errdefer fx.deinit();
    const a = fx.arena.allocator();
    try sema_mod.headers.resolveAllHeaders(fx.s);
    try fx.s.resolveBodies(&.{.program});
    var lines: std.ArrayList(Line) = .empty;
    try collect(fx.s, a, &fx.map, &lines);
    const text = try format(a, lines.items);
    const owned = try std.testing.allocator.dupe(u8, text);
    fx.deinit();
    return owned;
}

test "the dump names members, locals and receivers the way the oracle does" {
    const text = try dumpOf(
        \\package demo
        \\class Box(val n: Int) {
        \\    fun twice(): Int = n + n
        \\}
        \\fun Box.more(k: Int): Int = n + k
        \\fun main() {
        \\    val b = Box(1)
        \\    b.twice()
        \\    b.more(2)
        \\}
    );
    defer std.testing.allocator.free(text);
    // What kotlinc's oracle prints for the same source.
    const expect = [_][]const u8{
        "test0.kt\t60\t61\tread\tdemo/Box.n||\tthis@demo/Box\t-\n",
        "test0.kt\t60\t65\tplus\tkotlin/Int.plus||kotlin/Int\texpr\t-\n",
        "test0.kt\t64\t65\tread\tdemo/Box.n||\tthis@demo/Box\t-\n",
        "test0.kt\t96\t97\tread\tdemo/Box.n||\text@demo/more\t-\n",
        "test0.kt\t96\t101\tplus\tkotlin/Int.plus||kotlin/Int\texpr\t-\n",
        "test0.kt\t100\t101\tread\tlocal:k@81\t-\t-\n",
        "test0.kt\t127\t130\tctor\tdemo/Box.<init>||kotlin/Int\t-\t-\n",
        "test0.kt\t138\t139\tread\tlocal:b@119\t-\t-\n",
        "test0.kt\t140\t145\tcall\tdemo/Box.twice||\texpr\t-\n",
        "test0.kt\t152\t153\tread\tlocal:b@119\t-\t-\n",
        "test0.kt\t154\t158\tcall\tdemo/more|demo/Box|kotlin/Int\t-\texpr\n",
    };
    for (expect) |line| {
        if (std.mem.indexOf(u8, text, line) == null) {
            std.debug.print("missing: {s}dump:\n{s}\n", .{ line, text });
            return error.TestExpectedEqual;
        }
    }
}

test "local functions and local classes are named by their declaration offset" {
    const text = try dumpOf(
        \\fun main() {
        \\    fun sq(x: Int): Int = x
        \\    class Loc { fun get1(): Int = 1 }
        \\    sq(2)
        \\    Loc().get1()
        \\}
    );
    defer std.testing.allocator.free(text);
    const expect = [_][]const u8{
        "test0.kt\t39\t40\tread\tlocal:x@24\t-\t-\n",
        "test0.kt\t83\t85\tcall\tlocal:sq@17\t-\t-\n",
        "test0.kt\t93\t96\tctor\tlocal:Loc@45.<init>||\t-\t-\n",
        "test0.kt\t99\t103\tcall\tlocal:Loc@45.get1||\texpr\t-\n",
    };
    for (expect) |line| {
        if (std.mem.indexOf(u8, text, line) == null) {
            std.debug.print("missing: {s}dump:\n{s}\n", .{ line, text });
            return error.TestExpectedEqual;
        }
    }
}
