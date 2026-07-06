//! Parser corpus tests. Each `.kt`
//! snippet is parsed end-to-end and the pretty-printed AST + any diagnostics are
//! compared against the checked-in expected rendering; the embedded source
//! string and its expected output are kept inline per test.

const std = @import("std");
const ast = @import("ast");
const lexer = @import("lexer");
const parser = @import("parser");
const span = @import("span");
const diagnostics = @import("diagnostics");

const Allocator = std.mem.Allocator;

const KotlinFile = ast.KotlinFile;
const Decl = ast.Decl;
const Stmt = ast.Stmt;
const Expr = ast.Expr;
const Block = ast.Block;
const StringPart = ast.StringPart;
const TypeRef = ast.TypeRef;
const BinOp = ast.BinOp;
const UnOp = ast.UnOp;
const PostfixOp = ast.PostfixOp;
const AssignOp = ast.AssignOp;
const FunctionBody = ast.FunctionBody;
const WhenPatternKind = ast.WhenPatternKind;

/// Lex + parse `src` and produce the pretty-printed AST followed by any
/// diagnostics. Allocates into `arena`.
fn render(arena: Allocator, src: []const u8) ![]u8 {
    const id = span.FileId.from(0);
    var lx = try lexer.Lexer.init(arena, id, src);
    const lexed = try lx.tokenize();
    const p = parser.Parser.new(arena, id, src, lexed.tokens);
    const file_ast = p.parseFile();

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "# ast\n");
    var printer = Printer{ .out = &out, .arena = arena, .indent = 0 };
    try printer.file(&file_ast);

    // Lexer diagnostics first, then parser diagnostics: `lexed.diagnostics`
    // extended with the parser diagnostics.
    const lex_diags = lexed.diagnostics.diags();
    const parse_diags = p.diagnostics.diags();
    if (lex_diags.len + parse_diags.len != 0) {
        try out.appendSlice(arena, "\n# diagnostics\n");
        for (lex_diags) |*d| try renderDiag(arena, &out, d);
        for (parse_diags) |*d| try renderDiag(arena, &out, d);
    }
    return out.toOwnedSlice(arena);
}

fn renderDiag(arena: Allocator, out: *std.ArrayList(u8), d: *const diagnostics.Diagnostic) !void {
    const code = d.code() orelse "";
    const line = try std.fmt.allocPrint(arena, "[{s}] {s} {s} @{d}..{d}\n", .{
        code,
        @tagName(d.severity),
        d.message,
        d.primary.span.start,
        d.primary.span.end,
    });
    try out.appendSlice(arena, line);
}

const Printer = struct {
    out: *std.ArrayList(u8),
    arena: Allocator,
    indent: usize,

    fn pad(self: *Printer) Allocator.Error!void {
        var i: usize = 0;
        while (i < self.indent) : (i += 1) {
            try self.out.appendSlice(self.arena, "  ");
        }
    }

    fn line(self: *Printer, s: []const u8) Allocator.Error!void {
        try self.pad();
        try self.out.appendSlice(self.arena, s);
        try self.out.append(self.arena, '\n');
    }

    fn file(self: *Printer, f: *const KotlinFile) Allocator.Error!void {
        if (f.package) |pkg| {
            const segs = try joinIdents(self.arena, pkg.path, ".");
            try self.line(try std.fmt.allocPrint(self.arena, "package {s}", .{segs}));
        }
        for (f.imports) |imp| {
            const segs = try joinIdents(self.arena, imp.path, ".");
            const star: []const u8 = if (imp.wildcard) ".*" else "";
            const alias = if (imp.alias) |a|
                try std.fmt.allocPrint(self.arena, " as {s}", .{a.name})
            else
                "";
            try self.line(try std.fmt.allocPrint(self.arena, "import {s}{s}{s}", .{ segs, star, alias }));
        }
        for (f.decls) |*d| try self.decl(d);
    }

    fn decl(self: *Printer, d: *const Decl) Allocator.Error!void {
        switch (d.*) {
            .Function => |fn_| {
                var params: std.ArrayList(u8) = .empty;
                for (fn_.params, 0..) |param, i| {
                    if (i != 0) try params.append(self.arena, ',');
                    const ps = try std.fmt.allocPrint(self.arena, "{s}:{s}", .{ param.name.name, try renderType(self.arena, &param.ty) });
                    try params.appendSlice(self.arena, ps);
                }
                const ret = if (fn_.return_type) |t|
                    try std.fmt.allocPrint(self.arena, ":{s}", .{try renderType(self.arena, &t)})
                else
                    "";
                try self.line(try std.fmt.allocPrint(self.arena, "fun {s}({s}){s}", .{ fn_.name.name, params.items, ret }));
                self.indent += 1;
                if (fn_.body) |body| {
                    switch (body) {
                        .Block => |b| {
                            try self.line("body=block");
                            self.indent += 1;
                            for (b.stmts) |*s| try self.stmt(s);
                            self.indent -= 1;
                        },
                        .Expr => |e| {
                            try self.line("body=expr");
                            self.indent += 1;
                            try self.expr(&e);
                            self.indent -= 1;
                        },
                    }
                } else {
                    try self.line("body=<none>");
                }
                self.indent -= 1;
            },
            .Property => |prop| {
                const kw: []const u8 = if (prop.mutable) "var" else "val";
                const ty = if (prop.ty) |t|
                    try std.fmt.allocPrint(self.arena, ":{s}", .{try renderType(self.arena, &t)})
                else
                    "";
                try self.line(try std.fmt.allocPrint(self.arena, "{s} {s}{s}", .{ kw, prop.name.name, ty }));
                if (prop.init) |init| {
                    self.indent += 1;
                    try self.line("init=");
                    self.indent += 1;
                    try self.expr(&init);
                    self.indent -= 1;
                    self.indent -= 1;
                }
            },
            .Class => |c| {
                try self.line(try std.fmt.allocPrint(self.arena, "class {s}", .{c.name.name}));
                self.indent += 1;
                for (c.members) |*m| try self.decl(m);
                self.indent -= 1;
            },
            .Object => |o| {
                try self.line(try std.fmt.allocPrint(self.arena, "object {s}", .{o.name.name}));
                self.indent += 1;
                for (o.members) |*m| try self.decl(m);
                self.indent -= 1;
            },
            .TypeAlias => |a| {
                try self.line(try std.fmt.allocPrint(self.arena, "typealias {s}={s}", .{ a.name.name, try renderType(self.arena, &a.target) }));
            },
        }
    }

    fn stmt(self: *Printer, s: *const Stmt) Allocator.Error!void {
        switch (s.*) {
            .Expr => |e| {
                try self.line("stmt-expr");
                self.indent += 1;
                try self.expr(&e);
                self.indent -= 1;
            },
            .Decl => |d| {
                try self.line("stmt-decl");
                self.indent += 1;
                try self.decl(&d);
                self.indent -= 1;
            },
            .Assign => |asg| {
                try self.line(try std.fmt.allocPrint(self.arena, "assign {s}", .{renderAssignOp(asg.op)}));
                self.indent += 1;
                try self.line("target=");
                self.indent += 1;
                try self.expr(&asg.target);
                self.indent -= 1;
                try self.line("value=");
                self.indent += 1;
                try self.expr(&asg.value);
                self.indent -= 1;
                self.indent -= 1;
            },
            .DestructuringDecl => |dd| {
                const kw: []const u8 = if (dd.mutable) "var" else "val";
                const joined = try joinIdents(self.arena, dd.names, ", ");
                try self.line(try std.fmt.allocPrint(self.arena, "{s} ({s}) =", .{ kw, joined }));
                self.indent += 1;
                try self.expr(&dd.init);
                self.indent -= 1;
            },
        }
    }

    fn expr(self: *Printer, e: *const Expr) Allocator.Error!void {
        switch (e.*) {
            .IntLit => |x| try self.line(try std.fmt.allocPrint(self.arena, "int {d}", .{x.value})),
            .FloatLit => |x| try self.line(try std.fmt.allocPrint(self.arena, "float {d}", .{x.value})),
            .BoolLit => |x| try self.line(try std.fmt.allocPrint(self.arena, "bool {}", .{x.value})),
            .NullLit => try self.line("null"),
            .CharLit => |x| try self.line(try std.fmt.allocPrint(self.arena, "char {s}", .{try debugChar(self.arena, x.value)})),
            .StringTemplate => |x| {
                try self.line("string-template");
                self.indent += 1;
                for (x.parts) |part| {
                    switch (part) {
                        .Text => |t| try self.line(try std.fmt.allocPrint(self.arena, "text {s}", .{try debugStr(self.arena, t)})),
                        .ShortInterp => |id| try self.line(try std.fmt.allocPrint(self.arena, "short-interp ${s}", .{id.name})),
                        .Interp => |ie| {
                            try self.line("interp");
                            self.indent += 1;
                            try self.expr(ie);
                            self.indent -= 1;
                        },
                    }
                }
                self.indent -= 1;
            },
            .Path => |x| {
                const names = try joinIdents(self.arena, x.segments, ".");
                try self.line(try std.fmt.allocPrint(self.arena, "path {s}", .{names}));
            },
            .Member => |x| {
                const safe: []const u8 = if (x.safe) "?" else "";
                try self.line(try std.fmt.allocPrint(self.arena, "member{s} .{s}", .{ safe, x.name.name }));
                self.indent += 1;
                try self.expr(x.receiver);
                self.indent -= 1;
            },
            .Call => |x| {
                try self.line(try std.fmt.allocPrint(self.arena, "call (#args={d})", .{x.args.len}));
                self.indent += 1;
                try self.line("callee=");
                self.indent += 1;
                try self.expr(x.callee);
                self.indent -= 1;
                for (x.args, 0..) |*a, i| {
                    try self.line(try std.fmt.allocPrint(self.arena, "arg[{d}]=", .{i}));
                    self.indent += 1;
                    try self.expr(a);
                    self.indent -= 1;
                }
                self.indent -= 1;
            },
            .Index => |x| {
                try self.line(try std.fmt.allocPrint(self.arena, "index (#args={d})", .{x.args.len}));
                self.indent += 1;
                try self.line("recv=");
                self.indent += 1;
                try self.expr(x.receiver);
                self.indent -= 1;
                for (x.args, 0..) |*a, i| {
                    try self.line(try std.fmt.allocPrint(self.arena, "arg[{d}]=", .{i}));
                    self.indent += 1;
                    try self.expr(a);
                    self.indent -= 1;
                }
                self.indent -= 1;
            },
            .Binary => |x| {
                try self.line(try std.fmt.allocPrint(self.arena, "binop {s}", .{renderBinop(x.op)}));
                self.indent += 1;
                try self.expr(x.lhs);
                try self.expr(x.rhs);
                self.indent -= 1;
            },
            .Unary => |x| {
                try self.line(try std.fmt.allocPrint(self.arena, "unop {s}", .{renderUnop(x.op)}));
                self.indent += 1;
                try self.expr(x.expr);
                self.indent -= 1;
            },
            .Postfix => |x| {
                try self.line(try std.fmt.allocPrint(self.arena, "postfix {s}", .{renderPostfix(x.op)}));
                self.indent += 1;
                try self.expr(x.expr);
                self.indent -= 1;
            },
            .If => |x| {
                try self.line("if");
                self.indent += 1;
                try self.line("cond=");
                self.indent += 1;
                try self.expr(x.cond);
                self.indent -= 1;
                try self.line("then=");
                self.indent += 1;
                try self.expr(x.then_branch);
                self.indent -= 1;
                if (x.else_branch) |eb| {
                    try self.line("else=");
                    self.indent += 1;
                    try self.expr(eb);
                    self.indent -= 1;
                }
                self.indent -= 1;
            },
            .While => |x| {
                try self.line("while");
                self.indent += 1;
                try self.line("cond=");
                self.indent += 1;
                try self.expr(x.cond);
                self.indent -= 1;
                try self.line("body=");
                self.indent += 1;
                try self.expr(x.body);
                self.indent -= 1;
                self.indent -= 1;
            },
            .DoWhile => |x| {
                try self.line("do-while");
                self.indent += 1;
                try self.line("body=");
                self.indent += 1;
                if (x.body) |b| try self.expr(b);
                self.indent -= 1;
                try self.line("cond=");
                self.indent += 1;
                try self.expr(x.cond);
                self.indent -= 1;
                self.indent -= 1;
            },
            .For => |x| {
                const ty = if (x.var_ty) |t|
                    try std.fmt.allocPrint(self.arena, ":{s}", .{try renderType(self.arena, &t)})
                else
                    "";
                const names = try joinIdents(self.arena, x.vars, ",");
                try self.line(try std.fmt.allocPrint(self.arena, "for ({s}){s}", .{ names, ty }));
                self.indent += 1;
                try self.line("iter=");
                self.indent += 1;
                try self.expr(x.iter);
                self.indent -= 1;
                try self.line("body=");
                self.indent += 1;
                try self.expr(x.body);
                self.indent -= 1;
                self.indent -= 1;
            },
            .Return => |x| {
                const lbl = if (x.label) |l|
                    try std.fmt.allocPrint(self.arena, "@{s}", .{l.name})
                else
                    "";
                try self.line(try std.fmt.allocPrint(self.arena, "return{s}", .{lbl}));
                if (x.value) |v| {
                    self.indent += 1;
                    try self.expr(v);
                    self.indent -= 1;
                }
            },
            .Break => |x| {
                const lbl = if (x.label) |l|
                    try std.fmt.allocPrint(self.arena, "@{s}", .{l.name})
                else
                    "";
                try self.line(try std.fmt.allocPrint(self.arena, "break{s}", .{lbl}));
            },
            .Continue => |x| {
                const lbl = if (x.label) |l|
                    try std.fmt.allocPrint(self.arena, "@{s}", .{l.name})
                else
                    "";
                try self.line(try std.fmt.allocPrint(self.arena, "continue{s}", .{lbl}));
            },
            .Labeled => |x| {
                try self.line(try std.fmt.allocPrint(self.arena, "labeled {s}@", .{x.label.name}));
                self.indent += 1;
                try self.expr(x.expr);
                self.indent -= 1;
            },
            .Block => |b| {
                try self.line("block");
                self.indent += 1;
                for (b.stmts) |*s| try self.stmt(s);
                self.indent -= 1;
            },
            .Throw => |x| {
                try self.line("throw");
                self.indent += 1;
                try self.expr(x.value);
                self.indent -= 1;
            },
            .Try => |x| {
                try self.line("try");
                self.indent += 1;
                try self.line("body=block");
                self.indent += 1;
                for (x.body.stmts) |*s| try self.stmt(s);
                self.indent -= 1;
                for (x.catches) |c| {
                    try self.line(try std.fmt.allocPrint(self.arena, "catch {s}:{s}", .{ c.binding.name, try renderType(self.arena, &c.ty) }));
                    self.indent += 1;
                    for (c.body.stmts) |*s| try self.stmt(s);
                    self.indent -= 1;
                }
                if (x.finally) |fb| {
                    try self.line("finally=block");
                    self.indent += 1;
                    for (fb.stmts) |*s| try self.stmt(s);
                    self.indent -= 1;
                }
                self.indent -= 1;
            },
            .Lambda => |x| {
                const names = try joinIdents(self.arena, x.params, ",");
                try self.line(try std.fmt.allocPrint(self.arena, "lambda ({s})", .{names}));
                self.indent += 1;
                for (x.body.stmts) |*s| try self.stmt(s);
                self.indent -= 1;
            },
            .This => try self.line("this"),
            .Super => try self.line("super"),
            .IsCheck => |x| {
                const kw: []const u8 = if (x.negated) "!is" else "is";
                try self.line(try std.fmt.allocPrint(self.arena, "{s} {s}", .{ kw, try renderType(self.arena, &x.ty) }));
                self.indent += 1;
                try self.expr(x.expr);
                self.indent -= 1;
            },
            .When => |x| {
                try self.line("when");
                self.indent += 1;
                if (x.subject) |s| {
                    try self.line("subject");
                    self.indent += 1;
                    try self.expr(s);
                    self.indent -= 1;
                }
                for (x.branches) |b| {
                    try self.line("branch");
                    self.indent += 1;
                    for (b.patterns) |pat| {
                        switch (pat.kind) {
                            .Else => try self.line("else"),
                            .Value => |ve| {
                                try self.line("value");
                                self.indent += 1;
                                try self.expr(&ve);
                                self.indent -= 1;
                            },
                            .InRange => |ie| {
                                try self.line("in");
                                self.indent += 1;
                                try self.expr(&ie);
                                self.indent -= 1;
                            },
                            .NotInRange => |ie| {
                                try self.line("!in");
                                self.indent += 1;
                                try self.expr(&ie);
                                self.indent -= 1;
                            },
                            .IsType => |t| try self.line(try std.fmt.allocPrint(self.arena, "is {s}", .{try renderType(self.arena, &t)})),
                            .NotIsType => |t| try self.line(try std.fmt.allocPrint(self.arena, "!is {s}", .{try renderType(self.arena, &t)})),
                        }
                    }
                    try self.line("body");
                    self.indent += 1;
                    try self.expr(&b.body);
                    self.indent -= 1;
                    self.indent -= 1;
                }
                self.indent -= 1;
            },
            .PropertyRef => |x| try self.line(try std.fmt.allocPrint(self.arena, "property-ref ::{s}", .{x.name.name})),
            .MemberRef => |x| {
                try self.line(try std.fmt.allocPrint(self.arena, "member-ref ::{s}", .{x.name.name}));
                self.indent += 1;
                try self.expr(x.receiver);
                self.indent -= 1;
            },
            .ObjectExpr => |x| {
                var supers: std.ArrayList(u8) = .empty;
                for (x.supertypes, 0..) |*t, i| {
                    if (i != 0) try supers.append(self.arena, ',');
                    try supers.appendSlice(self.arena, try renderType(self.arena, t));
                }
                try self.line(try std.fmt.allocPrint(self.arena, "object-expr [{s}]", .{supers.items}));
                self.indent += 1;
                for (x.members) |*m| try self.decl(m);
                self.indent -= 1;
            },
            .As => |x| {
                const op: []const u8 = if (x.safe) "as?" else "as";
                try self.line(try std.fmt.allocPrint(self.arena, "{s} {s}", .{ op, try renderType(self.arena, &x.ty) }));
                self.indent += 1;
                try self.expr(x.expr);
                self.indent -= 1;
            },
            .AnonFun => |x| {
                var ps: std.ArrayList(u8) = .empty;
                for (x.params, 0..) |param, i| {
                    if (i != 0) try ps.append(self.arena, ',');
                    try ps.appendSlice(self.arena, param.name.name);
                }
                const rt = if (x.return_ty) |t| try renderType(self.arena, &t) else "";
                const tail = if (rt.len == 0)
                    ""
                else
                    try std.fmt.allocPrint(self.arena, ": {s}", .{rt});
                try self.line(try std.fmt.allocPrint(self.arena, "anon-fun ({s}){s}", .{ ps.items, tail }));
            },
            .Spread => |x| {
                try self.line("spread *");
                self.indent += 1;
                try self.expr(x.expr);
                self.indent -= 1;
            },
        }
    }
};

fn joinIdents(arena: Allocator, idents: []const ast.Ident, sep: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (idents, 0..) |id, i| {
        if (i != 0) try out.appendSlice(arena, sep);
        try out.appendSlice(arena, id.name);
    }
    return out.toOwnedSlice(arena);
}

fn renderType(arena: Allocator, t: *const TypeRef) ![]u8 {
    if (t.nullable) {
        return std.fmt.allocPrint(arena, "{s}?", .{t.name.name});
    }
    return arena.dupe(u8, t.name.name);
}

fn renderBinop(op: BinOp) []const u8 {
    return switch (op) {
        .Add => "+",
        .Sub => "-",
        .Mul => "*",
        .Div => "/",
        .Rem => "%",
        .Eq => "==",
        .Neq => "!=",
        .IdentEq => "===",
        .IdentNeq => "!==",
        .Lt => "<",
        .Le => "<=",
        .Gt => ">",
        .Ge => ">=",
        .And => "&&",
        .Or => "||",
        .Range => "..",
        .RangeUntil => "..<",
        .Elvis => "?:",
        .Assign => "=",
        .In => "in",
        .NotIn => "!in",
    };
}

fn renderUnop(op: UnOp) []const u8 {
    return switch (op) {
        .Neg => "-",
        .Pos => "+",
        .Not => "!",
        .PreInc => "++",
        .PreDec => "--",
    };
}

fn renderPostfix(op: PostfixOp) []const u8 {
    return switch (op) {
        .Inc => "++",
        .Dec => "--",
        .NotNull => "!!",
    };
}

fn renderAssignOp(op: AssignOp) []const u8 {
    return switch (op) {
        .Assign => "=",
        .Add => "+=",
        .Sub => "-=",
        .Mul => "*=",
        .Div => "/=",
        .Rem => "%=",
    };
}

/// Render a string wrapped in double quotes with `\`, `"`, newline, tab,
/// carriage-return and other control characters escaped.
fn debugStr(arena: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(arena, "\\\""),
            '\\' => try out.appendSlice(arena, "\\\\"),
            '\n' => try out.appendSlice(arena, "\\n"),
            '\t' => try out.appendSlice(arena, "\\t"),
            '\r' => try out.appendSlice(arena, "\\r"),
            else => {
                if (c < 0x20) {
                    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "\\u{{{x}}}", .{c}));
                } else {
                    try out.append(arena, c);
                }
            },
        }
    }
    try out.append(arena, '"');
    return out.toOwnedSlice(arena);
}

/// Render a char wrapped in single quotes with common escapes.
fn debugChar(arena: Allocator, value: u16) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '\'');
    switch (value) {
        '\'' => try out.appendSlice(arena, "\\'"),
        '\\' => try out.appendSlice(arena, "\\\\"),
        '\n' => try out.appendSlice(arena, "\\n"),
        '\t' => try out.appendSlice(arena, "\\t"),
        '\r' => try out.appendSlice(arena, "\\r"),
        else => {
            if (value < 0x20) {
                try out.appendSlice(arena, try std.fmt.allocPrint(arena, "\\u{{{x}}}", .{value}));
            } else if (value < 0x80) {
                try out.append(arena, @intCast(value));
            } else {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(value, &buf) catch 0;
                try out.appendSlice(arena, buf[0..n]);
            }
        },
    }
    try out.append(arena, '\'');
    return out.toOwnedSlice(arena);
}

/// Each test uses an arena over the page allocator so the leak-checking test
/// allocator is never used for the parse pipeline.
fn check(src: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try render(a, src);
    try std.testing.expectEqualStrings(expected, got);
}

test "hello" {
    const src =
        \\fun main() {
        \\    println(1 + 1)
        \\}
        \\
    ;
    const expected =
        \\# ast
        \\fun main()
        \\  body=block
        \\    stmt-expr
        \\      call (#args=1)
        \\        callee=
        \\          path println
        \\        arg[0]=
        \\          binop +
        \\            int 1
        \\            int 1
        \\
    ;
    try check(src, expected);
}

test "arithmetic_precedence" {
    const src =
        \\fun main() {
        \\    val a = 1 + 2 * 3
        \\    val b = (1 + 2) * 3
        \\    val c = 10 - 4 - 2
        \\    val d = -1 + +2
        \\    val e = !true && false || true
        \\    val f = 1 < 2 && 3 >= 2
        \\    val g = a == b || a != c
        \\    val h = 1..10
        \\    val i = 1..<10
        \\    val j = a ?: b
        \\}
        \\
    ;
    const expected =
        \\# ast
        \\fun main()
        \\  body=block
        \\    stmt-decl
        \\      val a
        \\        init=
        \\          binop +
        \\            int 1
        \\            binop *
        \\              int 2
        \\              int 3
        \\    stmt-decl
        \\      val b
        \\        init=
        \\          binop *
        \\            binop +
        \\              int 1
        \\              int 2
        \\            int 3
        \\    stmt-decl
        \\      val c
        \\        init=
        \\          binop -
        \\            binop -
        \\              int 10
        \\              int 4
        \\            int 2
        \\    stmt-decl
        \\      val d
        \\        init=
        \\          binop +
        \\            unop -
        \\              int 1
        \\            unop +
        \\              int 2
        \\    stmt-decl
        \\      val e
        \\        init=
        \\          binop ||
        \\            binop &&
        \\              unop !
        \\                bool true
        \\              bool false
        \\            bool true
        \\    stmt-decl
        \\      val f
        \\        init=
        \\          binop &&
        \\            binop <
        \\              int 1
        \\              int 2
        \\            binop >=
        \\              int 3
        \\              int 2
        \\    stmt-decl
        \\      val g
        \\        init=
        \\          binop ||
        \\            binop ==
        \\              path a
        \\              path b
        \\            binop !=
        \\              path a
        \\              path c
        \\    stmt-decl
        \\      val h
        \\        init=
        \\          binop ..
        \\            int 1
        \\            int 10
        \\    stmt-decl
        \\      val i
        \\        init=
        \\          binop ..<
        \\            int 1
        \\            int 10
        \\    stmt-decl
        \\      val j
        \\        init=
        \\          binop ?:
        \\            path a
        \\            path b
        \\
    ;
    try check(src, expected);
}

test "strings_templates" {
    const src =
        \\fun main() {
        \\    val name = "world"
        \\    val greeting = "hello $name, today is ${1 + 1}"
        \\    val raw = """multi
        \\line $name end"""
        \\    println(greeting)
        \\    println(raw)
        \\}
        \\
    ;
    const expected =
        "# ast\n" ++
        "fun main()\n" ++
        "  body=block\n" ++
        "    stmt-decl\n" ++
        "      val name\n" ++
        "        init=\n" ++
        "          string-template\n" ++
        "            text \"world\"\n" ++
        "    stmt-decl\n" ++
        "      val greeting\n" ++
        "        init=\n" ++
        "          string-template\n" ++
        "            text \"hello \"\n" ++
        "            short-interp $name\n" ++
        "            text \", today is \"\n" ++
        "            interp\n" ++
        "              binop +\n" ++
        "                int 1\n" ++
        "                int 1\n" ++
        "    stmt-decl\n" ++
        "      val raw\n" ++
        "        init=\n" ++
        "          string-template\n" ++
        "            text \"multi\\nline \"\n" ++
        "            short-interp $name\n" ++
        "            text \" end\"\n" ++
        "    stmt-expr\n" ++
        "      call (#args=1)\n" ++
        "        callee=\n" ++
        "          path println\n" ++
        "        arg[0]=\n" ++
        "          path greeting\n" ++
        "    stmt-expr\n" ++
        "      call (#args=1)\n" ++
        "        callee=\n" ++
        "          path println\n" ++
        "        arg[0]=\n" ++
        "          path raw\n";
    try check(src, expected);
}

test "declarations" {
    const src =
        \\val topProp: Int = 1
        \\var mutTop = "hi"
        \\
        \\fun add(a: Int, b: Int): Int {
        \\    return a + b
        \\}
        \\
        \\fun greet(name: String = "world"): String {
        \\    val message = "hi $name"
        \\    return message
        \\}
        \\
    ;
    const expected =
        "# ast\n" ++
        "val topProp:Int\n" ++
        "  init=\n" ++
        "    int 1\n" ++
        "var mutTop\n" ++
        "  init=\n" ++
        "    string-template\n" ++
        "      text \"hi\"\n" ++
        "fun add(a:Int,b:Int):Int\n" ++
        "  body=block\n" ++
        "    stmt-expr\n" ++
        "      return\n" ++
        "        binop +\n" ++
        "          path a\n" ++
        "          path b\n" ++
        "fun greet(name:String):String\n" ++
        "  body=block\n" ++
        "    stmt-decl\n" ++
        "      val message\n" ++
        "        init=\n" ++
        "          string-template\n" ++
        "            text \"hi \"\n" ++
        "            short-interp $name\n" ++
        "    stmt-expr\n" ++
        "      return\n" ++
        "        path message\n";
    try check(src, expected);
}

test "control_flow" {
    const src =
        \\fun main() {
        \\    val x = 5
        \\    val sign = if (x > 0) 1 else if (x < 0) -1 else 0
        \\
        \\    var i = 0
        \\    while (i < 10) {
        \\        if (i == 5) break
        \\        if (i == 3) {
        \\            i = i + 1
        \\            continue
        \\        }
        \\        i = i + 1
        \\    }
        \\
        \\    for (k in 1..3) {
        \\        println(k)
        \\    }
        \\
        \\    fun early(): Int {
        \\        return 7
        \\    }
        \\}
        \\
    ;
    const expected =
        \\# ast
        \\fun main()
        \\  body=block
        \\    stmt-decl
        \\      val x
        \\        init=
        \\          int 5
        \\    stmt-decl
        \\      val sign
        \\        init=
        \\          if
        \\            cond=
        \\              binop >
        \\                path x
        \\                int 0
        \\            then=
        \\              int 1
        \\            else=
        \\              if
        \\                cond=
        \\                  binop <
        \\                    path x
        \\                    int 0
        \\                then=
        \\                  unop -
        \\                    int 1
        \\                else=
        \\                  int 0
        \\    stmt-decl
        \\      var i
        \\        init=
        \\          int 0
        \\    stmt-expr
        \\      while
        \\        cond=
        \\          binop <
        \\            path i
        \\            int 10
        \\        body=
        \\          block
        \\            stmt-expr
        \\              if
        \\                cond=
        \\                  binop ==
        \\                    path i
        \\                    int 5
        \\                then=
        \\                  break
        \\            stmt-expr
        \\              if
        \\                cond=
        \\                  binop ==
        \\                    path i
        \\                    int 3
        \\                then=
        \\                  block
        \\                    assign =
        \\                      target=
        \\                        path i
        \\                      value=
        \\                        binop +
        \\                          path i
        \\                          int 1
        \\                    stmt-expr
        \\                      continue
        \\            assign =
        \\              target=
        \\                path i
        \\              value=
        \\                binop +
        \\                  path i
        \\                  int 1
        \\    stmt-expr
        \\      for (k)
        \\        iter=
        \\          binop ..
        \\            int 1
        \\            int 3
        \\        body=
        \\          block
        \\            stmt-expr
        \\              call (#args=1)
        \\                callee=
        \\                  path println
        \\                arg[0]=
        \\                  path k
        \\    stmt-decl
        \\      fun early():Int
        \\        body=block
        \\          stmt-expr
        \\            return
        \\              int 7
        \\
    ;
    try check(src, expected);
}

test "package_and_imports" {
    const src =
        \\package com.example.app
        \\
        \\import kotlin.math.PI
        \\import kotlin.collections.List as KList
        \\import kotlin.text.*
        \\
        \\fun main() {
        \\    println(PI)
        \\}
        \\
    ;
    const expected =
        \\# ast
        \\package com.example.app
        \\import kotlin.math.PI
        \\import kotlin.collections.List as KList
        \\import kotlin.text.*
        \\fun main()
        \\  body=block
        \\    stmt-expr
        \\      call (#args=1)
        \\        callee=
        \\          path println
        \\        arg[0]=
        \\          path PI
        \\
    ;
    try check(src, expected);
}

test "expression_body_fun" {
    const src =
        \\fun square(x: Int): Int = x * x
        \\
        \\fun double(x: Int) = x + x
        \\
        \\val computed = 1 + 2 * 3
        \\
    ;
    const expected =
        \\# ast
        \\fun square(x:Int):Int
        \\  body=expr
        \\    binop *
        \\      path x
        \\      path x
        \\fun double(x:Int)
        \\  body=expr
        \\    binop +
        \\      path x
        \\      path x
        \\val computed
        \\  init=
        \\    binop +
        \\      int 1
        \\      binop *
        \\        int 2
        \\        int 3
        \\
    ;
    try check(src, expected);
}

test "member_and_calls" {
    const src =
        \\fun main() {
        \\    val s = "hello"
        \\    val n = s.length
        \\    val u = s?.length
        \\    val first = s[0]
        \\    val x = obj.method(1, 2, 3)
        \\    val y = a.b.c.d
        \\    val z = a!!.b
        \\}
        \\
    ;
    const expected =
        "# ast\n" ++
        "fun main()\n" ++
        "  body=block\n" ++
        "    stmt-decl\n" ++
        "      val s\n" ++
        "        init=\n" ++
        "          string-template\n" ++
        "            text \"hello\"\n" ++
        "    stmt-decl\n" ++
        "      val n\n" ++
        "        init=\n" ++
        "          member .length\n" ++
        "            path s\n" ++
        "    stmt-decl\n" ++
        "      val u\n" ++
        "        init=\n" ++
        "          member? .length\n" ++
        "            path s\n" ++
        "    stmt-decl\n" ++
        "      val first\n" ++
        "        init=\n" ++
        "          index (#args=1)\n" ++
        "            recv=\n" ++
        "              path s\n" ++
        "            arg[0]=\n" ++
        "              int 0\n" ++
        "    stmt-decl\n" ++
        "      val x\n" ++
        "        init=\n" ++
        "          call (#args=3)\n" ++
        "            callee=\n" ++
        "              member .method\n" ++
        "                path obj\n" ++
        "            arg[0]=\n" ++
        "              int 1\n" ++
        "            arg[1]=\n" ++
        "              int 2\n" ++
        "            arg[2]=\n" ++
        "              int 3\n" ++
        "    stmt-decl\n" ++
        "      val y\n" ++
        "        init=\n" ++
        "          member .d\n" ++
        "            member .c\n" ++
        "              member .b\n" ++
        "                path a\n" ++
        "    stmt-decl\n" ++
        "      val z\n" ++
        "        init=\n" ++
        "          member .b\n" ++
        "            postfix !!\n" ++
        "              path a\n";
    try check(src, expected);
}

test "diag_missing_paren" {
    const src =
        \\fun main() {
        \\    println(1 + 2
        \\    val ok = 3
        \\}
        \\
    ;
    const expected =
        "# ast\n" ++
        "fun main()\n" ++
        "  body=block\n" ++
        "\n" ++
        "# diagnostics\n" ++
        "[E0001] Error expected `)` @35..38\n";
    try check(src, expected);
}

test "diag_top_level_garbage" {
    const src =
        \\+ + +
        \\fun main() { println(1) }
        \\
    ;
    const expected =
        "# ast\n" ++
        "fun main()\n" ++
        "  body=block\n" ++
        "    stmt-expr\n" ++
        "      call (#args=1)\n" ++
        "        callee=\n" ++
        "          path println\n" ++
        "        arg[0]=\n" ++
        "          int 1\n" ++
        "\n" ++
        "# diagnostics\n" ++
        "[E0002] Error expected top-level declaration @0..1\n";
    try check(src, expected);
}

test "diag_import_wildcard_alias" {
    const src =
        \\import kotlin.collections.* as col
        \\
        \\fun main() {}
        \\
    ;
    const expected =
        "# ast\n" ++
        "import kotlin.collections.* as col\n" ++
        "fun main()\n" ++
        "  body=block\n" ++
        "\n" ++
        "# diagnostics\n" ++
        "[P0044] Error wildcard import cannot be renamed; remove `as` or replace `*` with a name @28..34\n";
    try check(src, expected);
}

test "diag_import_empty" {
    const src =
        \\import
        \\fun main() {}
        \\
    ;
    const expected =
        "# ast\n" ++
        "import \n" ++
        "fun main()\n" ++
        "  body=block\n" ++
        "\n" ++
        "# diagnostics\n" ++
        "[P0047] Error malformed import: missing path @0..6\n";
    try check(src, expected);
}

test "diag_import_trailing_dot" {
    const src =
        \\import kotlin.
        \\
        \\fun main() {}
        \\
    ;
    const expected =
        "# ast\n" ++
        "import kotlin\n" ++
        "fun main()\n" ++
        "  body=block\n" ++
        "\n" ++
        "# diagnostics\n" ++
        "[P0047] Error malformed import: trailing `.` with no segment @13..14\n";
    try check(src, expected);
}

test "diag_package_after_imports" {
    const src =
        \\import kotlin.math.PI
        \\package foo
        \\
        \\fun main() {}
        \\
    ;
    const expected =
        "# ast\n" ++
        "import kotlin.math.PI\n" ++
        "fun main()\n" ++
        "  body=block\n" ++
        "\n" ++
        "# diagnostics\n" ++
        "[P0045] Error `package` header must come before any import or declaration @22..29\n";
    try check(src, expected);
}

test "diag_duplicate_package" {
    const src =
        \\package foo
        \\package bar
        \\
        \\fun main() {}
        \\
    ;
    const expected =
        "# ast\n" ++
        "package foo\n" ++
        "fun main()\n" ++
        "  body=block\n" ++
        "\n" ++
        "# diagnostics\n" ++
        "[P0045] Error duplicate `package` header; a file may declare at most one package @12..19\n";
    try check(src, expected);
}

test "diag_import_after_decl" {
    const src =
        \\package foo
        \\
        \\fun main() {}
        \\
        \\import kotlin.math.PI
        \\
    ;
    const expected =
        "# ast\n" ++
        "package foo\n" ++
        "fun main()\n" ++
        "  body=block\n" ++
        "\n" ++
        "# diagnostics\n" ++
        "[P0046] Error `import` directives must appear before any declaration @28..34\n";
    try check(src, expected);
}

test "diag_assignment_in_expression" {
    const src =
        \\fun main() {
        \\    var x = 0
        \\    val y = (x = 1)
        \\    if (x = 2) {
        \\        println("a")
        \\    }
        \\}
        \\
    ;
    const expected =
        "# ast\n" ++
        "fun main()\n" ++
        "  body=block\n" ++
        "    stmt-decl\n" ++
        "      var x\n" ++
        "        init=\n" ++
        "          int 0\n" ++
        "    stmt-decl\n" ++
        "      val y\n" ++
        "        init=\n" ++
        "          path x\n" ++
        "    stmt-expr\n" ++
        "      if\n" ++
        "        cond=\n" ++
        "          path x\n" ++
        "        then=\n" ++
        "          block\n" ++
        "            stmt-expr\n" ++
        "              call (#args=1)\n" ++
        "                callee=\n" ++
        "                  path println\n" ++
        "                arg[0]=\n" ++
        "                  string-template\n" ++
        "                    text \"a\"\n" ++
        "\n" ++
        "# diagnostics\n" ++
        "[T0117] Error assignments are not expressions, and only expressions are allowed in this context @42..43\n" ++
        "[T0117] Error assignments are not expressions, and only expressions are allowed in this context @57..58\n";
    try check(src, expected);
}
