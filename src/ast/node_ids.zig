//! Node ids, the per-file key sema's records are addressed by.
//!
//! `assign` numbers every id-bearing node of a file in source order: a node
//! before its children, children in the order the source writes them. `check`
//! walks every `NodeId` a file reaches, by reflection over the node types, and
//! reports the first id seen twice or at or above `node_count`; with
//! `require_all` it also reports a node the numbering missed.

const std = @import("std");
const builtin = @import("builtin");
const ast = @import("ast.zig");
const span_mod = @import("span");

const Allocator = std.mem.Allocator;
const Span = span_mod.Span;
const NodeId = ast.NodeId;
const KotlinFile = ast.KotlinFile;
const Decl = ast.Decl;
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const Block = ast.Block;
const TypeRef = ast.TypeRef;
const Annotation = ast.Annotation;

/// Number every node of `file` from `file.node_count` (or 1 when it is 0) and
/// leave the next free id in `file.node_count`.
pub fn assign(file: *KotlinFile) void {
    var n = Numbering{ .next = @max(file.node_count, 1) };
    n.annotations(file.file_annotations);
    for (file.decls) |*d| n.decl(d);
    file.node_count = n.next;
}

/// Numbers nodes from `next` in source order; see `assign`.
pub const Numbering = struct {
    next: u32,

    fn take(self: *Numbering, id: *NodeId) void {
        id.* = .from(self.next);
        self.next += 1;
    }

    pub fn decl(self: *Numbering, d: *Decl) void {
        switch (d.*) {
            .Function => |*f| self.function(f),
            .Property => |p| self.property(p),
            .Class => |*c| self.class(c),
            .Object => |*o| self.object(o),
            .TypeAlias => |*t| {
                self.take(&t.id);
                self.annotations(t.annotations);
                self.typeParams(t.type_params);
                self.typeRef(&t.target);
            },
        }
    }

    fn function(self: *Numbering, f: *ast.Function) void {
        self.take(&f.id);
        self.annotations(f.annotations);
        self.contextParams(f.context_params);
        self.typeParams(f.type_params);
        if (f.receiver_type) |t| self.typeRef(t);
        self.params(f.params);
        if (f.return_type) |t| self.typeRef(t);
        for (f.where_bounds) |*w| self.typeRef(&w.bound);
        if (f.body) |*b| self.functionBody(b);
    }

    fn functionBody(self: *Numbering, b: *ast.FunctionBody) void {
        switch (b.*) {
            .Block => |*blk| self.block(blk),
            .Expr => |*e| self.expr(e),
        }
    }

    fn property(self: *Numbering, p: *ast.Property) void {
        self.take(&p.id);
        self.annotations(p.annotations);
        self.contextParams(p.context_params);
        self.typeParams(p.type_params);
        // `receiver_type` is a copy of the written receiver or of a type
        // parameter's bound, sharing their annotation arguments.
        if (p.receiver_written orelse p.receiver_type) |t| self.typeRef(t);
        if (p.ty) |t| self.typeRef(t);
        if (p.init) |e| self.expr(e);
        if (p.delegate) |e| self.expr(e);
        if (p.explicit_field) |f| {
            if (f.ty) |t| self.typeRef(t);
            if (f.init) |e| self.expr(e);
        }
        const g = p.getter;
        const s = p.setter;
        if (g != null and s != null and s.?.span.start < g.?.span.start) {
            self.accessor(s.?);
            self.accessor(g.?);
        } else {
            if (g) |a| self.accessor(a);
            if (s) |a| self.accessor(a);
        }
    }

    fn accessor(self: *Numbering, a: *ast.Accessor) void {
        self.take(&a.id);
        self.annotations(a.annotations);
        if (a.return_type) |t| self.typeRef(t);
        self.functionBody(&a.body);
    }

    fn class(self: *Numbering, c: *ast.Class) void {
        self.take(&c.id);
        self.annotations(c.annotations);
        self.typeParams(c.type_params);
        self.annotations(c.x().primary_ctor_annotations);
        for (c.primary_params) |*cp| {
            self.take(&cp.id);
            self.annotations(cp.annotations);
            self.typeRef(&cp.ty);
            if (cp.default) |*e| self.expr(e);
        }
        self.supertypes(c.supertypes, c.supertype_args, c.supertype_delegates);
        const x = c.x();
        for (x.where_bounds) |*w| self.typeRef(&w.bound);
        for (x.enum_entries) |*entry| {
            self.take(&entry.id);
            self.annotations(entry.annotations);
            for (entry.args) |*e| self.expr(e);
            if (entry.body_members.len != 0) {
                for (c.members) |*m| if (m.* == .Class and isEntryBody(&m.Class) and m.Class.members.ptr == entry.body_members.ptr) {
                    self.entryBody(&m.Class);
                    break;
                };
            }
        }
        self.body(c.members, x.init_blocks, x.secondary_ctors);
    }

    /// An entry's body class, numbered after the entry's arguments, which it
    /// shares; see `isEntryBody`.
    fn entryBody(self: *Numbering, c: *ast.Class) void {
        self.take(&c.id);
        self.annotations(c.annotations);
        for (c.supertypes) |*t| self.typeRef(t);
        self.body(c.members, c.x().init_blocks, c.x().secondary_ctors);
    }

    fn object(self: *Numbering, o: *ast.ObjectDecl) void {
        self.take(&o.id);
        self.annotations(o.annotations);
        self.supertypes(o.supertypes, o.supertype_args, o.supertype_delegates);
        self.body(o.members, o.init_blocks, &.{});
    }

    fn supertypes(self: *Numbering, types: []TypeRef, args: []?[]Expr, delegates: []?Expr) void {
        for (types, 0..) |*t, i| {
            self.typeRef(t);
            if (i < args.len) if (args[i]) |a| for (a) |*e| self.expr(e);
            if (i < delegates.len) if (delegates[i]) |*e| self.expr(e);
        }
    }

    /// A class body's members, init blocks and secondary constructors are
    /// stored apart; each list is in source order, so a merge by start offset
    /// restores the order they were written in.
    fn body(self: *Numbering, members: []Decl, inits: []Block, ctors: []ast.SecondaryCtor) void {
        var m: usize = 0;
        var i: usize = 0;
        var k: usize = 0;
        const none = std.math.maxInt(u32);
        while (m < members.len or i < inits.len or k < ctors.len) {
            const ms = if (m < members.len) declStart(&members[m]) else none;
            const bs = if (i < inits.len) inits[i].span.start else none;
            const cs = if (k < ctors.len) ctors[k].span.start else none;
            if (m < members.len and ms <= bs and ms <= cs) {
                // An entry's body class was numbered with its entry.
                if (!(members[m] == .Class and isEntryBody(&members[m].Class))) self.decl(&members[m]);
                m += 1;
            } else if (i < inits.len and bs <= cs) {
                self.block(&inits[i]);
                i += 1;
            } else {
                self.secondaryCtor(&ctors[k]);
                k += 1;
            }
        }
    }

    fn secondaryCtor(self: *Numbering, sc: *ast.SecondaryCtor) void {
        self.take(&sc.id);
        self.annotations(sc.annotations);
        self.params(sc.params);
        switch (sc.delegation) {
            .This, .Super => |args| for (args) |*e| self.expr(e),
            .None => {},
        }
        if (sc.body) |*b| self.block(b);
    }

    fn params(self: *Numbering, ps: []ast.Param) void {
        for (ps) |*p| {
            self.take(&p.id);
            self.annotations(p.annotations);
            self.typeRef(&p.ty);
            if (p.default) |e| self.expr(e);
        }
    }

    fn contextParams(self: *Numbering, cps: []ast.ContextParam) void {
        for (cps) |*cp| self.typeRef(&cp.ty);
    }

    fn typeParams(self: *Numbering, tps: []ast.TypeParam) void {
        for (tps) |*tp| {
            self.annotations(tp.annotations);
            if (tp.upper_bound) |*t| self.typeRef(t);
        }
    }

    pub fn annotations(self: *Numbering, anns: []Annotation) void {
        for (anns) |*a| {
            for (a.type_args) |*t| self.typeRef(t);
            for (a.args) |*e| self.expr(e);
        }
    }

    /// A type holds no id of its own; an annotation argument inside one does.
    fn typeRef(self: *Numbering, t: *TypeRef) void {
        if (t.extra) |x| self.annotations(@constCast(x).annotations);
        if (t.function) |f| {
            for (f.context_params) |*c| self.typeRef(c);
            if (f.receiver) |*r| self.typeRef(r);
            for (f.params) |*p| self.typeRef(p);
            self.typeRef(&f.ret);
        }
        for (t.type_args) |*a| if (!a.is_star) self.typeRef(&a.ty);
    }

    pub fn block(self: *Numbering, b: *Block) void {
        self.take(&b.id);
        for (b.stmts) |*s| self.stmt(s);
    }

    fn stmt(self: *Numbering, s: *Stmt) void {
        switch (s.*) {
            .Expr => |*e| self.expr(e),
            .Decl => |d| self.decl(d),
            .Assign => |a| {
                self.take(&a.id);
                self.expr(&a.target);
                self.expr(&a.value);
            },
            .DestructuringDecl => |dd| {
                self.take(&dd.id);
                self.expr(&dd.init);
            },
        }
    }

    pub fn expr(self: *Numbering, e: *Expr) void {
        switch (e.*) {
            .IntLit, .FloatLit, .BoolLit, .NullLit, .CharLit, .Path, .Break, .Continue, .This, .PropertyRef => {
                self.take(e.idPtr());
            },
            .StringTemplate => |*x| {
                self.take(&x.id);
                for (x.parts) |*part| switch (part.*) {
                    .Text => {},
                    .ShortInterp => |*ident| self.take(&ident.id),
                    .Interp => |ie| self.expr(ie),
                };
            },
            .Member => |*x| {
                self.take(&x.id);
                self.expr(x.receiver);
            },
            .Call => |*x| {
                self.take(&x.id);
                if (x.is_infix and x.args.len == 2) {
                    // `a f b`: the operand before the name comes first.
                    self.expr(&x.args[0]);
                    self.expr(x.callee);
                    self.expr(&x.args[1]);
                    return;
                }
                self.expr(x.callee);
                for (x.typeArgs()) |*t| self.typeRef(t);
                for (x.args) |*a| self.expr(a);
            },
            .Index => |*x| {
                self.take(&x.id);
                self.expr(x.receiver);
                for (x.args) |*a| self.expr(a);
            },
            .Binary => |*x| {
                self.take(&x.id);
                self.expr(x.lhs);
                self.expr(x.rhs);
            },
            .Unary => |*x| {
                self.take(&x.id);
                self.expr(x.expr);
            },
            .Postfix => |*x| {
                self.take(&x.id);
                self.expr(x.expr);
            },
            .If => |*x| {
                self.take(&x.id);
                self.expr(x.cond);
                self.expr(x.then_branch);
                if (x.else_branch) |eb| self.expr(eb);
            },
            .While => |*x| {
                self.take(&x.id);
                self.expr(x.cond);
                self.expr(x.body);
            },
            .DoWhile => |*x| {
                self.take(&x.id);
                if (x.body) |b| self.expr(b);
                self.expr(x.cond);
            },
            .For => |x| {
                self.take(&x.id);
                if (x.var_ty) |*t| self.typeRef(t);
                self.expr(x.iter);
                self.expr(x.body);
            },
            .Return => |*x| {
                self.take(&x.id);
                if (x.value) |v| self.expr(v);
            },
            .Labeled => |*x| {
                self.take(&x.id);
                self.expr(x.expr);
            },
            .Block => |*b| self.block(b),
            .Throw => |*x| {
                self.take(&x.id);
                self.expr(x.value);
            },
            .Try => |x| {
                self.take(&x.id);
                self.block(&x.body);
                for (x.catches) |*c| {
                    self.take(&c.id);
                    self.typeRef(&c.ty);
                    self.block(&c.body);
                }
                if (x.finally) |*f| self.block(f);
            },
            .Lambda => |x| {
                self.take(&x.id);
                self.annotations(x.annotations);
                for (x.param_tys) |*t| if (t.*) |*ty| self.typeRef(ty);
                self.block(&x.body);
            },
            .Super => |x| {
                self.take(&x.id);
                if (x.qualifier) |*t| self.typeRef(t);
            },
            .MemberRef => |x| {
                self.take(&x.id);
                self.expr(x.receiver);
                for (x.qualifier_type_args) |*t| self.typeRef(t);
            },
            .When => |x| {
                self.take(&x.id);
                if (x.subject_binding) |*sb| {
                    self.annotations(sb.annotations);
                    if (sb.ty) |*t| self.typeRef(t);
                }
                if (x.subject) |s| self.expr(s);
                for (x.branches) |*br| {
                    for (br.patterns) |*pat| switch (pat.kind) {
                        .Value, .InRange, .NotInRange => |*pe| self.expr(pe),
                        .IsType, .NotIsType => |*t| self.typeRef(t),
                        .Else => {},
                    };
                    if (br.guard) |g| self.expr(&g.expr);
                    self.expr(&br.body);
                }
            },
            .IsCheck => |x| {
                self.take(&x.id);
                self.expr(x.expr);
                self.typeRef(&x.ty);
            },
            .As => |x| {
                self.take(&x.id);
                self.expr(x.expr);
                self.typeRef(&x.ty);
            },
            .AnonFun => |x| {
                self.take(&x.id);
                self.contextParams(x.context_params);
                if (x.receiver_ty) |*t| self.typeRef(t);
                self.params(x.params);
                if (x.return_ty) |*t| self.typeRef(t);
                if (x.body) |b| self.functionBody(b);
            },
            .Spread => |*x| {
                self.take(&x.id);
                self.expr(x.expr);
            },
            .ObjectExpr => |x| {
                self.take(&x.id);
                self.supertypes(x.supertypes, x.supertype_args, x.supertype_delegates);
                self.body(x.members, x.init_blocks, &.{});
            },
        }
    }
};

fn declStart(d: *const Decl) u32 {
    return switch (d.*) {
        .Function => |*f| f.span.start,
        .Property => |p| p.span.start,
        .Class => |*c| c.span.start,
        .Object => |*o| o.span.start,
        .TypeAlias => |*t| t.span.start,
    };
}

pub const Problem = struct {
    kind: Kind,
    id: NodeId,
    /// The span of the node holding the id, when it has one.
    span: ?Span,

    pub const Kind = enum { duplicate, out_of_range, missing };
};

pub const CheckOptions = struct {
    /// Report a node whose id is `none`. An identifier's id is optional
    /// except on a `$name` template part.
    require_all: bool = false,
};

/// The first id in `file` that appears twice, is at or above
/// `file.node_count`, or (under `require_all`) is missing; null when there is
/// none. `none` ids are otherwise ignored.
pub fn check(allocator: Allocator, file: *const KotlinFile, opts: CheckOptions) Allocator.Error!?Problem {
    var seen = try std.DynamicBitSetUnmanaged.initEmpty(allocator, file.node_count);
    defer seen.deinit(allocator);
    var c = Checker{ .seen = &seen, .count = file.node_count, .require_all = opts.require_all };
    c.walk(KotlinFile, file, null);
    return c.problem;
}

/// One id a file holds, in the order `collect` meets it.
pub const Entry = struct {
    id: NodeId,
    /// The span of the node holding the id, when it has one.
    span: ?Span,
    /// The name of the type the id is a field of.
    holder: []const u8,
};

/// Every id `file` holds other than `none`, in field order; for tests and
/// dumps.
pub fn collect(allocator: Allocator, file: *const KotlinFile) Allocator.Error![]Entry {
    var seen = try std.DynamicBitSetUnmanaged.initEmpty(allocator, file.node_count);
    defer seen.deinit(allocator);
    var out: std.ArrayList(Entry) = .empty;
    errdefer out.deinit(allocator);
    var c = Checker{ .seen = &seen, .count = file.node_count, .require_all = false, .out = &out, .out_allocator = allocator };
    c.walk(KotlinFile, file, null);
    if (c.oom) return error.OutOfMemory;
    return out.toOwnedSlice(allocator);
}

/// In Debug builds, panic naming `stage` when `check` finds a problem in
/// `file`. Nothing runs in other builds.
pub fn assertValid(file: *const KotlinFile, stage: []const u8) void {
    if (builtin.mode != .Debug) return;
    var fallback = std.heap.stackFallback(8192, std.heap.page_allocator);
    const problem = (check(fallback.get(), file, .{ .require_all = true }) catch return) orelse return;
    if (problem.span) |s| {
        std.debug.panic("node id {d} {s} after {s} (file {d}, offsets {d}..{d}, node_count {d})", .{
            problem.id.int(), @tagName(problem.kind), stage, s.file.int(), s.start, s.end, file.node_count,
        });
    }
    std.debug.panic("node id {d} {s} after {s} (node_count {d})", .{ problem.id.int(), @tagName(problem.kind), stage, file.node_count });
}

const Checker = struct {
    seen: *std.DynamicBitSetUnmanaged,
    count: u32,
    require_all: bool,
    problem: ?Problem = null,
    /// `collect`'s list; problems are not recorded while it is set.
    out: ?*std.ArrayList(Entry) = null,
    out_allocator: Allocator = undefined,
    oom: bool = false,
    holder: []const u8 = "",

    fn see(self: *Checker, id: NodeId, required: bool, sp: ?Span) void {
        if (self.out) |out| {
            if (id != .none) out.append(self.out_allocator, .{ .id = id, .span = sp, .holder = self.holder }) catch {
                self.oom = true;
            };
            return;
        }
        if (self.problem != null) return;
        if (id == .none) {
            if (required and self.require_all) self.problem = .{ .kind = .missing, .id = id, .span = sp };
            return;
        }
        const v = id.int();
        if (v >= self.count) {
            self.problem = .{ .kind = .out_of_range, .id = id, .span = sp };
            return;
        }
        if (self.seen.isSet(v)) {
            self.problem = .{ .kind = .duplicate, .id = id, .span = sp };
            return;
        }
        self.seen.set(v);
    }

    fn walk(self: *Checker, comptime T: type, v: *const T, sp: ?Span) void {
        if (self.problem != null) return;
        if (comptime isPlain(T)) return;
        if (T == NodeId) {
            self.see(v.*, true, sp);
            return;
        }
        if (T == ast.Ident) {
            self.holder = @typeName(T);
            self.see(v.id, false, v.span);
            return;
        }
        if (T == ast.StringPart) {
            switch (v.*) {
                .Text => {},
                .ShortInterp => |*ident| {
                    self.holder = "ast.StringPart.ShortInterp";
                    self.see(ident.id, true, ident.span);
                },
                .Interp => |ie| self.walk(Expr, ie, null),
            }
            return;
        }
        switch (@typeInfo(T)) {
            .@"struct" => self.walkFields(T, v, sp),
            .@"union" => switch (v.*) {
                inline else => |*payload| self.walk(@TypeOf(payload.*), payload, sp),
            },
            .optional => |o| if (v.*) |*x| self.walk(o.child, x, sp),
            .pointer => |p| switch (p.size) {
                .one => self.walk(p.child, v.*, sp),
                .slice => for (v.*) |*x| self.walk(p.child, x, sp),
                else => @compileError("unexpected pointer in an AST node: " ++ @typeName(T)),
            },
            else => @compileError("unexpected type in an AST node: " ++ @typeName(T)),
        }
    }

    fn walkFields(self: *Checker, comptime T: type, v: *const T, sp: ?Span) void {
        const here: ?Span = if (@hasField(T, "span") and @FieldType(T, "span") == Span) v.span else sp;
        inline for (@typeInfo(T).@"struct".fields) |f| {
            if (!aliased(T, v, f.name)) {
                if (f.type == NodeId) self.holder = @typeName(T);
                self.walk(f.type, &@field(v.*, f.name), here);
            }
        }
    }
};

/// A field the parser fills with nodes another field also holds; the nodes
/// are numbered and checked through the other one.
fn aliased(comptime T: type, v: *const T, comptime field: []const u8) bool {
    if (T == ast.Property and comptime std.mem.eql(u8, field, "receiver_type")) return v.receiver_written != null;
    if (T == ast.EnumEntry and comptime std.mem.eql(u8, field, "body_members")) return true;
    if (T == ast.Class and comptime std.mem.eql(u8, field, "supertype_args")) return isEntryBody(v);
    return false;
}

/// The member class `$Name` the parser declares for an enum entry with a
/// body. It shares the entry's arguments as its supertype arguments, and its
/// members are the entry's `body_members`.
fn isEntryBody(c: *const ast.Class) bool {
    return c.is_enum and c.name.name.len > 1 and c.name.name[0] == '$';
}

/// Holds no node: scalars, strings and lists of optional strings.
fn isPlain(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum", .void => T != NodeId,
        .optional => |o| isPlain(o.child),
        .pointer => |p| p.size == .slice and isPlain(p.child),
        else => false,
    };
}

const testing = std.testing;

fn tSpan(start: u32, end: u32) Span {
    return .init(span_mod.FileId.from(0), start, end);
}

fn tFunction(stmts: []Stmt) ast.Function {
    return .{
        .name = .{ .name = "f", .span = tSpan(4, 5) },
        .receiver_type = null,
        .type_params = &.{},
        .where_bounds = &.{},
        .params = &.{},
        .return_type = null,
        .body = .{ .Block = .{ .stmts = stmts, .span = tSpan(8, 40) } },
        .is_open = false,
        .is_override = false,
        .is_abstract = false,
        .is_operator = false,
        .is_inline = false,
        .is_infix = false,
        .is_tailrec = false,
        .is_suspend = false,
        .is_expect = false,
        .is_actual = false,
        .visibility = .Public,
        .annotations = &.{},
        .span = tSpan(0, 40),
    };
}

fn tFile(decls: []Decl) KotlinFile {
    return .{ .package = null, .imports = &.{}, .decls = decls, .span = tSpan(0, 40) };
}

test "assign numbers a node before its children, in source order" {
    // fun f() { g(1 + 2) }
    var one = Expr{ .IntLit = .{ .value = 1, .kind = .Int, .span = tSpan(12, 13) } };
    var two = Expr{ .IntLit = .{ .value = 2, .kind = .Int, .span = tSpan(16, 17) } };
    var segs = [_]ast.Ident{.{ .name = "g", .span = tSpan(10, 11) }};
    var callee = Expr{ .Path = .{ .segments = &segs, .span = tSpan(10, 11) } };
    var args = [_]Expr{.{ .Binary = .{ .op = .Add, .lhs = &one, .rhs = &two, .span = tSpan(12, 17) } }};
    var stmts = [_]Stmt{.{ .Expr = .{ .Call = .{ .callee = &callee, .args = &args, .is_infix = false, .span = tSpan(10, 18) } } }};
    var decls = [_]Decl{.{ .Function = tFunction(&stmts) }};
    var file = tFile(&decls);
    assign(&file);

    const f = &decls[0].Function;
    try testing.expectEqual(NodeId.from(1), f.id);
    try testing.expectEqual(NodeId.from(2), f.body.?.Block.id);
    try testing.expectEqual(NodeId.from(3), stmts[0].Expr.id());
    try testing.expectEqual(NodeId.from(4), callee.id());
    try testing.expectEqual(NodeId.from(5), args[0].id());
    try testing.expectEqual(NodeId.from(6), one.id());
    try testing.expectEqual(NodeId.from(7), two.id());
    try testing.expectEqual(@as(u32, 8), file.node_count);
    try testing.expect(try check(testing.allocator, &file, .{ .require_all = true }) == null);
}

test "an infix call numbers its left operand before the name" {
    // a shl b
    var segs_a = [_]ast.Ident{.{ .name = "a", .span = tSpan(10, 11) }};
    var segs_f = [_]ast.Ident{.{ .name = "shl", .span = tSpan(12, 15) }};
    var segs_b = [_]ast.Ident{.{ .name = "b", .span = tSpan(16, 17) }};
    var callee = Expr{ .Path = .{ .segments = &segs_f, .span = tSpan(12, 15) } };
    var args = [_]Expr{
        .{ .Path = .{ .segments = &segs_a, .span = tSpan(10, 11) } },
        .{ .Path = .{ .segments = &segs_b, .span = tSpan(16, 17) } },
    };
    var stmts = [_]Stmt{.{ .Expr = .{ .Call = .{ .callee = &callee, .args = &args, .is_infix = true, .span = tSpan(10, 17) } } }};
    var decls = [_]Decl{.{ .Function = tFunction(&stmts) }};
    var file = tFile(&decls);
    assign(&file);
    try testing.expect(args[0].id().int() < callee.id().int());
    try testing.expect(callee.id().int() < args[1].id().int());
}

test "a template's short interpolation is numbered; other identifiers are not" {
    var parts = [_]ast.StringPart{ .{ .Text = "x=" }, .{ .ShortInterp = .{ .name = "x", .span = tSpan(13, 14) } } };
    var stmts = [_]Stmt{.{ .Expr = .{ .StringTemplate = .{ .parts = &parts, .span = tSpan(10, 15) } } }};
    var decls = [_]Decl{.{ .Function = tFunction(&stmts) }};
    var file = tFile(&decls);
    assign(&file);
    try testing.expectEqual(NodeId.from(3), stmts[0].Expr.id());
    try testing.expectEqual(NodeId.from(4), parts[1].ShortInterp.id);
    try testing.expectEqual(NodeId.none, decls[0].Function.name.id);
    try testing.expect(try check(testing.allocator, &file, .{ .require_all = true }) == null);
}

test "assign continues from the file's node_count" {
    var stmts = [_]Stmt{.{ .Expr = .{ .NullLit = .{ .span = tSpan(10, 14) } } }};
    var decls = [_]Decl{.{ .Function = tFunction(&stmts) }};
    var file = tFile(&decls);
    file.node_count = 50;
    assign(&file);
    try testing.expectEqual(NodeId.from(50), decls[0].Function.id);
    try testing.expectEqual(NodeId.from(52), stmts[0].Expr.id());
    try testing.expectEqual(@as(u32, 53), file.node_count);
}

test "check catches a copied expression, an id past node_count, and an unnumbered node" {
    var stmts = [_]Stmt{
        .{ .Expr = .{ .IntLit = .{ .value = 1, .kind = .Int, .span = tSpan(10, 11) } } },
        .{ .Expr = .{ .IntLit = .{ .value = 2, .kind = .Int, .span = tSpan(12, 13) } } },
    };
    var decls = [_]Decl{.{ .Function = tFunction(&stmts) }};
    var file = tFile(&decls);
    assign(&file);
    try testing.expect(try check(testing.allocator, &file, .{ .require_all = true }) == null);

    // A pass that copies an expression leaves two nodes with one id.
    const second = stmts[1];
    stmts[1] = stmts[0];
    const dup = (try check(testing.allocator, &file, .{})).?;
    try testing.expectEqual(Problem.Kind.duplicate, dup.kind);
    try testing.expectEqual(stmts[0].Expr.id(), dup.id);
    try testing.expectEqual(@as(u32, 10), dup.span.?.start);
    stmts[1] = second;

    file.node_count -= 1;
    const past = (try check(testing.allocator, &file, .{})).?;
    try testing.expectEqual(Problem.Kind.out_of_range, past.kind);
    try testing.expectEqual(stmts[1].Expr.id(), past.id);
    file.node_count += 1;

    // A node a later pass built carries `none`: only `require_all` objects.
    stmts[1].Expr.idPtr().* = .none;
    try testing.expect(try check(testing.allocator, &file, .{}) == null);
    const missing = (try check(testing.allocator, &file, .{ .require_all = true })).?;
    try testing.expectEqual(Problem.Kind.missing, missing.kind);
    try testing.expectEqual(@as(u32, 12), missing.span.?.start);
}

test "collect lists every id with its holder" {
    var stmts = [_]Stmt{.{ .Expr = .{ .BoolLit = .{ .value = true, .span = tSpan(10, 14) } } }};
    var decls = [_]Decl{.{ .Function = tFunction(&stmts) }};
    var file = tFile(&decls);
    assign(&file);
    const entries = try collect(testing.allocator, &file);
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 3), entries.len);
    var saw_bool = false;
    for (entries) |e| {
        if (e.id == stmts[0].Expr.id()) {
            saw_bool = true;
            try testing.expectEqual(@as(u32, 10), e.span.?.start);
        }
    }
    try testing.expect(saw_bool);
}
