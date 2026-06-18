//! Harvest package-rooted fully-qualified reference prefixes from a parsed
//! program.
//!
//! Kotlin needs no `import` to use a name by its fully-qualified path
//! (`kotlin.coroutines.EmptyCoroutineContext`, `kotlinx.coroutines.launch(…)`).
//! The stdlib/pack load gate keyed only on `import` lines, so a qualified-only
//! program never opened the gated curated sources / selected the matching pack.
//! This walk recovers the package prefixes such qualified uses imply, so the
//! gate sees them exactly as if the program had imported them.
//!
//! Conservative on purpose: a dotted chain contributes a prefix only when its
//! head segment is one of the well-known package roots (`kotlin`, `kotlinx`,
//! `java`, `javax`). A member access on a local (`obj.a.b`) is rooted at the
//! local's name, never a package root, so it does not widen the gate. A missed
//! position only fails to widen — never a false positive — so the walk is safe
//! even where it is not exhaustive.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ast = @import("ast");
const KotlinFile = ast.KotlinFile;
const Expr = ast.Expr;
const Decl = ast.Decl;
const Block = ast.Block;
const Stmt = ast.Stmt;
const FunctionBody = ast.FunctionBody;

/// Top-level package roots a dotted chain must start with to count as a
/// fully-qualified reference (rather than member access on a value).
const PACKAGE_ROOTS = [_][]const u8{ "kotlin", "kotlinx", "java", "javax" };

fn isPackageRoot(name: []const u8) bool {
    for (PACKAGE_ROOTS) |r| {
        if (std.mem.eql(u8, name, r)) return true;
    }
    return false;
}

/// Collect every package-rooted qualified-reference prefix the files use, as
/// a set of dotted strings. Each key is owned by the returned map's
/// allocator; free the keys and `deinit` the map (the loader's `freeStringSet`
/// does both).
pub fn collect(
    allocator: Allocator,
    files: []const KotlinFile,
) Allocator.Error!std.StringHashMap(void) {
    var out = std.StringHashMap(void).init(allocator);
    errdefer {
        var it = out.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        out.deinit();
    }
    for (files) |f| {
        for (f.decls) |d| try walkDecl(allocator, &out, d);
    }
    return out;
}

/// If `e` is a package-rooted dotted chain, record its package prefix (all
/// segments except the trailing symbol). Walks the chain only when it is a
/// `Member`/`Path` spine; any non-name link aborts the attempt.
fn recordChainPrefix(
    allocator: Allocator,
    out: *std.StringHashMap(void),
    e: *const Expr,
) Allocator.Error!void {
    var segs: [16][]const u8 = undefined;
    var n: usize = 0;
    var cur: *const Expr = e;
    // Unwind the chain right-to-left into `segs` (reversed), bounded by the
    // buffer; longer chains are not package qualifiers worth gating on.
    while (true) {
        switch (cur.*) {
            .Member => |m| {
                if (m.safe) return; // `a?.b` is never a package qualifier
                if (n == segs.len) return;
                segs[n] = m.name.name;
                n += 1;
                cur = m.receiver;
            },
            .Path => |p| {
                for (p.segments) |s| {
                    if (n == segs.len) return;
                    segs[n] = s.name;
                    n += 1;
                }
                break;
            },
            else => return,
        }
    }
    // Reversed: segs[n-1] is the head, segs[0] is the trailing symbol.
    if (n < 2) return;
    const head = segs[n - 1];
    if (!isPackageRoot(head)) return;

    // Build the package prefix: head .. second-to-last (drop segs[0]).
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var i: usize = n - 1;
    while (i >= 1) : (i -= 1) {
        if (i != n - 1) try buf.append(allocator, '.');
        try buf.appendSlice(allocator, segs[i]);
    }
    if (buf.items.len == 0) return;
    const key = try allocator.dupe(u8, buf.items);
    const gop = try out.getOrPut(key);
    if (gop.found_existing) allocator.free(key);
}

fn walkExpr(
    allocator: Allocator,
    out: *std.StringHashMap(void),
    e: *const Expr,
) Allocator.Error!void {
    // A Member/Path spine may itself be a package qualifier.
    try recordChainPrefix(allocator, out, e);

    switch (e.*) {
        .IntLit, .FloatLit, .BoolLit, .NullLit, .CharLit, .Path, .This, .Super, .PropertyRef, .Break, .Continue => {},
        .StringTemplate => |t| {
            for (t.parts) |part| switch (part) {
                .Interp => |ie| try walkExpr(allocator, out, &ie),
                .Text, .ShortInterp => {},
            };
        },
        .Member => |m| try walkExpr(allocator, out, m.receiver),
        .Call => |c| {
            try walkExpr(allocator, out, c.callee);
            for (c.args) |*a| try walkExpr(allocator, out, a);
        },
        .Index => |x| {
            try walkExpr(allocator, out, x.receiver);
            for (x.args) |*a| try walkExpr(allocator, out, a);
        },
        .Binary => |b| {
            try walkExpr(allocator, out, b.lhs);
            try walkExpr(allocator, out, b.rhs);
        },
        .Unary => |u| try walkExpr(allocator, out, u.expr),
        .Postfix => |pf| try walkExpr(allocator, out, pf.expr),
        .If => |x| {
            try walkExpr(allocator, out, x.cond);
            try walkExpr(allocator, out, x.then_branch);
            if (x.else_branch) |eb| try walkExpr(allocator, out, eb);
        },
        .While => |w| {
            try walkExpr(allocator, out, w.cond);
            try walkExpr(allocator, out, w.body);
        },
        .DoWhile => |w| {
            if (w.body) |body| try walkExpr(allocator, out, body);
            try walkExpr(allocator, out, w.cond);
        },
        .For => |fr| {
            try walkExpr(allocator, out, fr.iter);
            try walkExpr(allocator, out, fr.body);
        },
        .Return => |r| {
            if (r.value) |v| try walkExpr(allocator, out, v);
        },
        .Labeled => |l| try walkExpr(allocator, out, l.expr),
        .Block => |b| try walkBlock(allocator, out, b),
        .Throw => |t| try walkExpr(allocator, out, t.value),
        .Try => |t| {
            try walkBlock(allocator, out, t.body);
            for (t.catches) |c| try walkBlock(allocator, out, c.body);
            if (t.finally) |fb| try walkBlock(allocator, out, fb);
        },
        .Lambda => |l| try walkBlock(allocator, out, l.body),
        .MemberRef => |mr| try walkExpr(allocator, out, mr.receiver),
        .When => |w| {
            if (w.subject) |s| try walkExpr(allocator, out, s);
            for (w.branches) |br| {
                for (br.patterns) |p| switch (p.kind) {
                    .Value => |ve| try walkExpr(allocator, out, &ve),
                    .InRange => |ie| try walkExpr(allocator, out, &ie),
                    .NotInRange => |ie| try walkExpr(allocator, out, &ie),
                    .IsType, .NotIsType, .Else => {},
                };
                try walkExpr(allocator, out, &br.body);
            }
        },
        .IsCheck => |c| try walkExpr(allocator, out, c.expr),
        .As => |c| try walkExpr(allocator, out, c.expr),
        .AnonFun => |fdef| {
            if (fdef.body) |body| try walkFunctionBody(allocator, out, body.*);
        },
        .Spread => |s| try walkExpr(allocator, out, s.expr),
        .ObjectExpr => |o| {
            for (o.members) |m| try walkDecl(allocator, out, m);
            for (o.init_blocks) |ib| try walkBlock(allocator, out, ib);
        },
    }
}

fn walkBlock(
    allocator: Allocator,
    out: *std.StringHashMap(void),
    b: Block,
) Allocator.Error!void {
    for (b.stmts) |s| switch (s) {
        .Expr => |e| try walkExpr(allocator, out, &e),
        .Decl => |d| try walkDecl(allocator, out, d),
        .Assign => |a| {
            try walkExpr(allocator, out, &a.target);
            try walkExpr(allocator, out, &a.value);
        },
        .DestructuringDecl => |dd| try walkExpr(allocator, out, &dd.init),
    };
}

fn walkFunctionBody(
    allocator: Allocator,
    out: *std.StringHashMap(void),
    body: FunctionBody,
) Allocator.Error!void {
    switch (body) {
        .Block => |b| try walkBlock(allocator, out, b),
        .Expr => |e| try walkExpr(allocator, out, &e),
    }
}

fn walkDecl(
    allocator: Allocator,
    out: *std.StringHashMap(void),
    d: Decl,
) Allocator.Error!void {
    switch (d) {
        .Function => |fun| {
            for (fun.params) |p| {
                if (p.default) |def| try walkExpr(allocator, out, def);
            }
            if (fun.body) |body| try walkFunctionBody(allocator, out, body);
        },
        .Property => |prop| {
            if (prop.init) |e| try walkExpr(allocator, out, &e);
            if (prop.delegate) |e| try walkExpr(allocator, out, &e);
            if (prop.getter) |g| try walkFunctionBody(allocator, out, g.body);
            if (prop.setter) |s| try walkFunctionBody(allocator, out, s.body);
        },
        .Class => |cls| {
            for (cls.primary_params) |p| {
                if (p.default) |def| try walkExpr(allocator, out, &def);
            }
            for (cls.supertype_args) |maybe_args| {
                if (maybe_args) |args| for (args) |*a| try walkExpr(allocator, out, a);
            }
            for (cls.supertype_delegates) |maybe_del| {
                if (maybe_del) |del| try walkExpr(allocator, out, &del);
            }
            for (cls.init_blocks) |ib| try walkBlock(allocator, out, ib);
            for (cls.secondary_ctors) |ctor| {
                switch (ctor.delegation) {
                    .This => |args| for (args) |*a| try walkExpr(allocator, out, a),
                    .Super => |args| for (args) |*a| try walkExpr(allocator, out, a),
                    .None => {},
                }
                if (ctor.body) |b| try walkBlock(allocator, out, b);
            }
            for (cls.enum_entries) |entry| {
                for (entry.args) |*a| try walkExpr(allocator, out, a);
                for (entry.body_members) |m| try walkDecl(allocator, out, m);
            }
            for (cls.members) |m| try walkDecl(allocator, out, m);
        },
        .Object => |obj| {
            for (obj.supertype_args) |maybe_args| {
                if (maybe_args) |args| for (args) |*a| try walkExpr(allocator, out, a);
            }
            for (obj.init_blocks) |ib| try walkBlock(allocator, out, ib);
            for (obj.members) |m| try walkDecl(allocator, out, m);
        },
        .TypeAlias => {},
    }
}

// ---------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------

const lexer = @import("lexer");
const parser = @import("parser");
const span = @import("span");

/// Parse `src` and collect the prefixes. The parse allocations live on an
/// arena passed by the caller; the returned set is owned by `out_alloc`.
fn collectFromSource(arena: Allocator, out_alloc: Allocator, src: []const u8) !std.StringHashMap(void) {
    var sm = span.SourceMap.init(arena);
    const fid = try sm.add("test.kt", src);
    const s = sm.get(fid).source;
    var lx = try lexer.Lexer.init(arena, fid, s);
    const lexed = try lx.tokenize();
    const p = parser.Parser.new(arena, fid, s, lexed.tokens);
    const file = p.parseFile();
    const files = [_]KotlinFile{file};
    return collect(out_alloc, &files);
}

fn freeSet(set: *std.StringHashMap(void)) void {
    var it = set.keyIterator();
    while (it.next()) |k| set.allocator.free(k.*);
    set.deinit();
}

test "qualified read harvests package prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var set = try collectFromSource(arena.allocator(), std.testing.allocator,
        \\fun main() { println(kotlin.coroutines.EmptyCoroutineContext) }
    );
    defer freeSet(&set);
    try std.testing.expect(set.contains("kotlin.coroutines"));
}

test "qualified call harvests package prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var set = try collectFromSource(arena.allocator(), std.testing.allocator,
        \\fun main() { kotlinx.coroutines.runBlocking { } }
    );
    defer freeSet(&set);
    try std.testing.expect(set.contains("kotlinx.coroutines"));
}

test "non-package member access does not widen" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var set = try collectFromSource(arena.allocator(), std.testing.allocator,
        \\fun main() { val obj = A(); println(obj.a.b) }
    );
    defer freeSet(&set);
    try std.testing.expectEqual(@as(usize, 0), set.count());
}

test "deep qualified path harvests full package" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var set = try collectFromSource(arena.allocator(), std.testing.allocator,
        \\fun main() { println(kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED) }
    );
    defer freeSet(&set);
    try std.testing.expect(set.contains("kotlin.coroutines.intrinsics"));
}

test {
    std.testing.refAllDecls(@This());
}
