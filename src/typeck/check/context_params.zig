//! Context parameters (Kotlin 2.4): declaration-position rules plus the
//! static context-argument resolution behind the missing, ambiguous and
//! excluded-form diagnostics. This pass is the compile-time contract; runtime
//! resolution runs off the lowered `CtxLoad`/`CtxScope` ops.
//!
//! Free functions over `*Checker`, driven from `phases.run`.

const std = @import("std");

const ast = @import("ast");
const diagnostics = @import("diagnostics");
const span = @import("span");

const root = @import("../check.zig");

const Allocator = std.mem.Allocator;
const Checker = root.Checker;
const Diagnostic = diagnostics.Diagnostic;
const g = diagnostics.generated;

const KotlinFile = ast.KotlinFile;
const Decl = ast.Decl;
const Class = ast.Class;
const Function = ast.Function;
const Property = ast.Property;
const Block = ast.Block;
const Stmt = ast.Stmt;
const Expr = ast.Expr;
const ContextParam = ast.ContextParam;
const Span = span.Span;

/// One implicit source available for context resolution at a lexical level.
const Source = struct {
    ty: []const u8,
    is_receiver: bool,
};

const Level = std.ArrayListUnmanaged(Source);

/// A contextual callee's declared context parameters, keyed by simple name.
const CalleeSig = struct {
    names: []const []const u8,
    types: []const []const u8,
    /// So a context parameter typed by one resolves against the call-site
    /// type argument.
    type_params: []const []const u8,
    /// A plain overload with the same value signature exists, so an unresolved
    /// context is an overload ambiguity, not a missing argument.
    has_plain_sibling: bool = false,
};

const Ctx = struct {
    self: *Checker,
    callees: std.StringHashMap(CalleeSig),
    class_map: *std.StringHashMap(*const Class),
    levels: std.ArrayListUnmanaged(Level) = .empty,

    fn pushLevel(c: *Ctx, srcs: []const Source) Allocator.Error!void {
        var lvl: Level = .empty;
        try lvl.appendSlice(c.self.allocator, srcs);
        try c.levels.append(c.self.allocator, lvl);
    }

    fn popLevel(c: *Ctx) void {
        var lvl = c.levels.pop().?;
        lvl.deinit(c.self.allocator);
    }
};

/// Driven from `phases.run` after the body checks.
pub fn checkContextParameters(self: *Checker, file: *const KotlinFile) Allocator.Error!void {
    var class_map = std.StringHashMap(*const Class).init(self.allocator);
    defer class_map.deinit();
    try collectClasses(&class_map, file.decls);

    var ctx = Ctx{
        .self = self,
        .callees = std.StringHashMap(CalleeSig).init(self.allocator),
        .class_map = &class_map,
    };
    defer ctx.callees.deinit();
    var plain_names = std.StringHashMap(void).init(self.allocator);
    defer plain_names.deinit();
    try collectPlainNames(&plain_names, file.decls);
    try collectCallees(&ctx, file.decls);
    // Mark contextual callees with a plain sibling overload.
    var cit = ctx.callees.iterator();
    while (cit.next()) |e| {
        if (plain_names.contains(e.key_ptr.*)) e.value_ptr.has_plain_sibling = true;
    }

    // Declaration-position rules.
    for (file.decls) |*d| try checkDeclPositions(self, d);

    // An override's context types must match, in order.
    for (file.decls) |*d| try checkOverrides(self, &class_map, d);

    // Call-site resolution; the file scope has no implicit sources.
    try ctx.pushLevel(&.{});
    defer ctx.popLevel();
    for (file.decls) |*d| try walkDecl(&ctx, d);
}

/// Names of functions declared with no context clause.
fn collectPlainNames(out: *std.StringHashMap(void), decls: []const Decl) Allocator.Error!void {
    for (decls) |*d| {
        switch (d.*) {
            .Function => |f| if (f.context_params.len == 0) try out.put(f.name.name, {}),
            .Class => |c| {
                for (c.members) |*m| try collectPlainNames(out, m[0..1]);
            },
            .Object => |o| {
                for (o.members) |*m| try collectPlainNames(out, m[0..1]);
            },
            else => {},
        }
    }
}

fn collectCallees(ctx: *Ctx, decls: []const Decl) Allocator.Error!void {
    for (decls) |*d| {
        switch (d.*) {
            .Function => |f| if (f.context_params.len != 0) try putCallee(ctx, f.name.name, f.context_params, f.type_params),
            .Property => |p| if (p.context_params.len != 0) try putCallee(ctx, p.name.name, p.context_params, &.{}),
            .Class => |c| {
                for (c.members) |*m| try collectCallees(ctx, m[0..1]);
            },
            .Object => |o| {
                for (o.members) |*m| try collectCallees(ctx, m[0..1]);
            },
            else => {},
        }
    }
}

fn putCallee(ctx: *Ctx, name: []const u8, cps: []const ContextParam, tps: []const ast.TypeParam) Allocator.Error!void {
    // These intrinsics resolve through dedicated lowering, not this walk.
    if (std.mem.eql(u8, name, "context") or std.mem.eql(u8, name, "contextOf")) return;
    if (ctx.callees.contains(name)) return;
    const names = try ctx.self.allocator.alloc([]const u8, cps.len);
    const types = try ctx.self.allocator.alloc([]const u8, cps.len);
    for (cps, 0..) |*cp, i| {
        names[i] = cp.name.name;
        types[i] = cp.ty.name.name;
    }
    const tp_names = try ctx.self.allocator.alloc([]const u8, tps.len);
    for (tps, 0..) |*tp, i| tp_names[i] = tp.name.name;
    try ctx.callees.put(name, .{ .names = names, .types = types, .type_params = tp_names });
}

fn emit(self: *Checker, factory: *const diagnostics.DiagnosticFactory, msg: []const u8, sp: Span) Allocator.Error!void {
    var d = Diagnostic.err(msg, sp);
    _ = d.withFactory(factory);
    try self.diagnostics.emit(self.allocator, d);
}

fn checkDeclPositions(self: *Checker, d: *const Decl) Allocator.Error!void {
    switch (d.*) {
        .Property => |p| {
            if (p.context_params.len != 0) try checkContextualProperty(self, p);
        },
        .Class => |*c| {
            for (c.members) |*m| try checkDeclPositions(self, m);
        },
        .Object => |*o| {
            for (o.members) |*m| try checkDeclPositions(self, m);
        },
        else => {},
    }
}

fn checkContextualProperty(self: *Checker, p: *const Property) Allocator.Error!void {
    const sp = if (p.context_params.len != 0) p.context_params[0].span else p.name.span;
    // No backing field, so no initializer or `lateinit`.
    if (p.init) |_| {
        try emit(self, &g.CONTEXT_PARAMETERS_WITH_BACKING_FIELD, "Property with context parameters cannot be initialized because it has no backing field.", sp);
    } else if (p.is_lateinit) {
        try emit(self, &g.CONTEXT_PARAMETERS_WITH_BACKING_FIELD, "Property with context parameters cannot be 'lateinit' because it has no backing field.", sp);
    }
    if (p.delegate != null) {
        try emit(self, &g.UNSUPPORTED, "Context parameters on delegated properties are unsupported.", sp);
    }
}

fn collectClasses(map: *std.StringHashMap(*const Class), decls: []const Decl) Allocator.Error!void {
    for (decls) |*d| {
        switch (d.*) {
            .Class => |*c| {
                try map.put(c.name.name, c);
                for (c.members) |*m| try collectClasses(map, m[0..1]);
            },
            else => {},
        }
    }
}

fn checkOverrides(self: *Checker, map: *std.StringHashMap(*const Class), d: *const Decl) Allocator.Error!void {
    switch (d.*) {
        .Class => |*c| {
            for (c.members) |*m| {
                if (m.* == .Function) {
                    const f = &m.Function;
                    if (f.is_override) try checkOneOverride(self, map, c, f);
                }
                try checkOverrides(self, map, m);
            }
        },
        else => {},
    }
}

fn checkOneOverride(self: *Checker, map: *std.StringHashMap(*const Class), c: *const Class, f: *const Function) Allocator.Error!void {
    // By name, through the transitive supertypes.
    if (findOverridden(self, map, c, f.name.name)) |base| {
        if (!contextTypesMatch(base.context_params, f.context_params)) {
            const msg = try std.fmt.allocPrint(self.allocator, "'{s}' overrides nothing.", .{f.name.name});
            try emit(self, &g.NOTHING_TO_OVERRIDE, msg, f.name.span);
        } else if (base.context_params.len != 0 and namesDiffer(base.context_params, f.context_params)) {
            var dd = Diagnostic.warning("The corresponding parameter in the supertype is named differently.", f.name.span);
            _ = dd.withFactory(&g.PARAMETER_NAME_CHANGED_ON_OVERRIDE);
            try self.diagnostics.emit(self.allocator, dd);
        }
    }
}

fn findOverridden(self: *Checker, map: *std.StringHashMap(*const Class), c: *const Class, name: []const u8) ?*const Function {
    var seen = std.StringHashMap(void).init(self.allocator);
    defer seen.deinit();
    return findOverriddenRec(map, c, name, &seen);
}

fn findOverriddenRec(map: *std.StringHashMap(*const Class), c: *const Class, name: []const u8, seen: *std.StringHashMap(void)) ?*const Function {
    if ((seen.getOrPut(c.name.name) catch return null).found_existing) return null;
    for (c.supertypes) |*s| {
        if (map.get(s.name.name)) |sc| {
            for (sc.members) |*m| {
                if (m.* == .Function and std.mem.eql(u8, m.Function.name.name, name)) return &m.Function;
            }
            if (findOverriddenRec(map, sc, name, seen)) |f| return f;
        }
    }
    return null;
}

fn contextTypesMatch(a: []const ContextParam, b: []const ContextParam) bool {
    if (a.len != b.len) return false;
    for (a, b) |*x, *y| {
        if (!std.mem.eql(u8, x.ty.name.name, y.ty.name.name)) return false;
    }
    return true;
}

fn namesDiffer(a: []const ContextParam, b: []const ContextParam) bool {
    for (a, b) |*x, *y| {
        if (!std.mem.eql(u8, x.name.name, y.name.name)) return true;
    }
    return false;
}

/// Null when unknown, which counts as compatible so the walk never reports a
/// spurious missing context argument.
fn staticTypeName(e: *const Expr) ?[]const u8 {
    return switch (e.*) {
        .StringTemplate => "String",
        .IntLit => |l| switch (l.kind) {
            .Int => "Int",
            .Long => "Long",
            .UInt => "UInt",
            .ULong => "ULong",
        },
        .BoolLit => "Boolean",
        .CharLit => "Char",
        .As => |a| a.ty.name.name,
        .ObjectExpr => |o| if (o.supertypes.len != 0) o.supertypes[0].name.name else "Any",
        .Call => |c| blk: {
            // A capitalised single-segment callee reads as a constructor.
            if (c.callee.* == .Path and c.callee.Path.segments.len == 1) {
                const nm = c.callee.Path.segments[0].name;
                if (nm.len != 0 and std.ascii.isUpper(nm[0])) break :blk nm;
            }
            break :blk null;
        },
        else => null,
    };
}

fn subtypeOf(self: *Checker, a: []const u8, b: []const u8) bool {
    const at = std.mem.trimEnd(u8, a, "?");
    const bt = std.mem.trimEnd(u8, b, "?");
    if (std.mem.eql(u8, at, bt)) return true;
    if (std.mem.eql(u8, bt, "Any")) return true;
    var seen = std.StringHashMap(void).init(self.allocator);
    defer seen.deinit();
    var stack: std.ArrayListUnmanaged([]const u8) = .empty;
    defer stack.deinit(self.allocator);
    stack.append(self.allocator, at) catch return false;
    while (stack.pop()) |cur| {
        if (seen.contains(cur)) continue;
        seen.put(cur, {}) catch return false;
        if (std.mem.eql(u8, cur, bt)) return true;
        if (root.classNamed(self, cur)) |info| {
            for (info.supertypes.items) |s| stack.append(self.allocator, s) catch return false;
        }
    }
    return false;
}

/// An unknown source, null or the empty sentinel, satisfies anything.
fn sourceMatches(self: *Checker, src: ?[]const u8, want: []const u8) bool {
    const s = src orelse return true;
    if (s.len == 0) return true;
    return subtypeOf(self, s, want);
}

fn walkDecl(ctx: *Ctx, d: *const Decl) Allocator.Error!void {
    switch (d.*) {
        .Function => |*f| try walkFunction(ctx, f, null),
        .Property => |p| try walkProperty(ctx, p, null),
        .Class => |*c| try walkClass(ctx, c),
        .Object => |*o| {
            var srcs: std.ArrayListUnmanaged(Source) = .empty;
            defer srcs.deinit(ctx.self.allocator);
            try srcs.append(ctx.self.allocator, .{ .ty = o.name.name, .is_receiver = true });
            try ctx.pushLevel(srcs.items);
            defer ctx.popLevel();
            for (o.members) |*m| try walkDecl(ctx, m);
        },
        else => {},
    }
}

fn walkClass(ctx: *Ctx, c: *const Class) Allocator.Error!void {
    // `this` is an outer level for every member body.
    var srcs: std.ArrayListUnmanaged(Source) = .empty;
    defer srcs.deinit(ctx.self.allocator);
    try srcs.append(ctx.self.allocator, .{ .ty = c.name.name, .is_receiver = true });
    try ctx.pushLevel(srcs.items);
    defer ctx.popLevel();
    for (c.members) |*m| {
        switch (m.*) {
            .Function => |*f| try walkFunction(ctx, f, c.name.name),
            .Property => |p| try walkProperty(ctx, p, c.name.name),
            .Class => |*cc| try walkClass(ctx, cc),
            .Object => |*o| {
                for (o.members) |*om| try walkDecl(ctx, om);
            },
            else => {},
        }
    }
}

/// Its extension receiver and every context parameter share one level.
fn ownLevelSources(self: *Checker, receiver: ?[]const u8, cps: []const ContextParam) Allocator.Error![]Source {
    var srcs: std.ArrayListUnmanaged(Source) = .empty;
    if (receiver) |r| try srcs.append(self.allocator, .{ .ty = r, .is_receiver = true });
    for (cps) |*cp| try srcs.append(self.allocator, .{ .ty = cp.ty.name.name, .is_receiver = false });
    return srcs.toOwnedSlice(self.allocator);
}

fn walkFunction(ctx: *Ctx, f: *const Function, _: ?[]const u8) Allocator.Error!void {
    const recv: ?[]const u8 = if (f.receiver_type) |r| r.name.name else null;
    const srcs = try ownLevelSources(ctx.self, recv, f.context_params);
    defer ctx.self.allocator.free(srcs);
    try ctx.pushLevel(srcs);
    defer ctx.popLevel();
    if (f.body) |*body| switch (body.*) {
        .Block => |*b| try walkBlock(ctx, b),
        .Expr => |*e| try walkExpr(ctx, e),
    };
}

fn walkProperty(ctx: *Ctx, p: *const Property, _: ?[]const u8) Allocator.Error!void {
    const recv: ?[]const u8 = if (p.receiver_type) |r| r.name.name else null;
    const srcs = try ownLevelSources(ctx.self, recv, p.context_params);
    defer ctx.self.allocator.free(srcs);
    if (p.getter) |acc| {
        try ctx.pushLevel(srcs);
        defer ctx.popLevel();
        try walkAccessorBody(ctx, acc);
    }
    if (p.setter) |acc| {
        try ctx.pushLevel(srcs);
        defer ctx.popLevel();
        try walkAccessorBody(ctx, acc);
    }
}

fn walkAccessorBody(ctx: *Ctx, acc: *const ast.Accessor) Allocator.Error!void {
    switch (acc.body) {
        .Block => |*b| try walkBlock(ctx, b),
        .Expr => |*e| try walkExpr(ctx, e),
    }
}

fn walkBlock(ctx: *Ctx, b: *const Block) Allocator.Error!void {
    for (b.stmts) |*s| try walkStmt(ctx, s);
}

fn walkStmt(ctx: *Ctx, s: *const Stmt) Allocator.Error!void {
    switch (s.*) {
        .Expr => |*e| try walkExpr(ctx, e),
        .Decl => |*d| switch (d.*) {
            .Function => |*f| try walkFunction(ctx, f, null),
            .Property => |p| {
                if (p.init) |*e| try walkExpr(ctx, e);
                try walkProperty(ctx, p, null);
            },
            else => {},
        },
        .Assign => |*a| {
            try walkExpr(ctx, &a.target);
            try walkExpr(ctx, &a.value);
        },
        else => {},
    }
}

fn walkExpr(ctx: *Ctx, e: *const Expr) Allocator.Error!void {
    switch (e.*) {
        .Call => |*c| try walkCall(ctx, c, e.span()),
        .Member => |*m| try walkExpr(ctx, m.receiver),
        .Binary => |*b| {
            try walkExpr(ctx, b.lhs);
            try walkExpr(ctx, b.rhs);
        },
        .Unary => |*u| try walkExpr(ctx, u.expr),
        .Postfix => |*p| try walkExpr(ctx, p.expr),
        .If => |*i| {
            try walkExpr(ctx, i.cond);
            // A narrowed value is a context source for the then-branch.
            if (i.cond.* == .IsCheck and !i.cond.IsCheck.negated) {
                var srcs = [_]Source{.{ .ty = i.cond.IsCheck.ty.name.name, .is_receiver = false }};
                try ctx.pushLevel(&srcs);
                try walkExpr(ctx, i.then_branch);
                ctx.popLevel();
            } else {
                try walkExpr(ctx, i.then_branch);
            }
            if (i.else_branch) |eb| try walkExpr(ctx, eb);
        },
        .Block => |*b| try walkBlock(ctx, b),
        .Lambda => |*l| try walkBlock(ctx, &l.body),
        .Index => |*ix| {
            try walkExpr(ctx, ix.receiver);
            for (ix.args) |*a| try walkExpr(ctx, a);
        },
        .As => |*a| try walkExpr(ctx, a.expr),
        .IsCheck => |*i| try walkExpr(ctx, i.expr),
        .When => |*w| {
            if (w.subject) |sub| try walkExpr(ctx, sub);
            for (w.branches) |*br| try walkExpr(ctx, &br.body);
        },
        .PropertyRef => |*r| try checkCallableRef(ctx, r.name.name, r.span),
        .MemberRef => |*r| try checkCallableRef(ctx, r.name.name, r.span),
        else => {},
    }
}

fn walkCall(ctx: *Ctx, c: anytype, call_span: Span) Allocator.Error!void {
    const callee_name: ?[]const u8 = if (c.callee.* == .Path and c.callee.Path.segments.len == 1)
        c.callee.Path.segments[0].name
    else if (c.callee.* == .Member)
        c.callee.Member.name.name
    else
        null;

    // The trailing lambda gets a level of the leading values' static types.
    if (callee_name) |nm| {
        if (std.mem.eql(u8, nm, "context") and c.args.len >= 2 and c.args[c.args.len - 1] == .Lambda) {
            for (c.args[0 .. c.args.len - 1]) |*a| try walkExpr(ctx, a);
            var srcs: std.ArrayListUnmanaged(Source) = .empty;
            defer srcs.deinit(ctx.self.allocator);
            for (c.args[0 .. c.args.len - 1]) |*a| {
                const ty = staticTypeName(a) orelse "";
                try srcs.append(ctx.self.allocator, .{ .ty = ty, .is_receiver = false });
            }
            try ctx.pushLevel(srcs.items);
            defer ctx.popLevel();
            try walkBlock(ctx, &c.args[c.args.len - 1].Lambda.body);
            return;
        }
        // `with(recv) { block }` gives the block a receiver level.
        if (std.mem.eql(u8, nm, "with") and c.args.len == 2 and c.args[1] == .Lambda) {
            try walkExpr(ctx, &c.args[0]);
            const ty = staticTypeName(&c.args[0]) orelse "";
            var srcs = [_]Source{.{ .ty = ty, .is_receiver = true }};
            try ctx.pushLevel(&srcs);
            defer ctx.popLevel();
            try walkBlock(ctx, &c.args[1].Lambda.body);
            return;
        }
    }

    try walkExpr(ctx, c.callee);
    for (c.args) |*a| try walkExpr(ctx, a);

    // A named argument targeting a context parameter is the explicit form,
    // which 2.4 excludes without the opt-in flag.
    if (callee_name) |nm| {
        if (ctx.callees.get(nm)) |sig| {
            try resolveContextArgs(ctx, sig, nm, c.type_args, call_span);
            for (c.arg_names) |maybe| {
                if (maybe) |an| {
                    for (sig.names) |pn| {
                        if (std.mem.eql(u8, pn, an)) {
                            try emit(ctx.self, &g.UNSUPPORTED, "Explicit context arguments are not supported.", call_span);
                            break;
                        }
                    }
                }
            }
        } else if (c.callee.* == .Path and hasContextValueInScope(ctx)) {
            // Only meaningful with a context value actually in scope.
            try checkReceiverShadowed(ctx, nm, call_span);
        }
    }
}

/// A context value at a strictly more nested level than the implicit receiver,
/// and compatible with it, shadows it (context-parameters KEEP, §7.10(a)).
fn checkReceiverShadowed(ctx: *Ctx, nm: []const u8, call_span: Span) Allocator.Error!void {
    var recv_level: ?usize = null;
    var recv_ty: []const u8 = "";
    var i = ctx.levels.items.len;
    while (i > 0 and recv_level == null) {
        i -= 1;
        for (ctx.levels.items[i].items) |src| {
            if (src.is_receiver and classHasMember(ctx, src.ty, nm)) {
                recv_level = i;
                recv_ty = src.ty;
                break;
            }
        }
    }
    const lr = recv_level orelse return;
    var j = ctx.levels.items.len;
    while (j > lr + 1) {
        j -= 1;
        for (ctx.levels.items[j].items) |src| {
            if (!src.is_receiver and sourceMatches(ctx.self, src.ty, recv_ty)) {
                const msg = try std.fmt.allocPrint(ctx.self.allocator, "Call to '{s}' uses an implicit receiver shadowed by a context parameter. Use 'this.{s}()' or a qualified access.", .{ nm, nm });
                try emit(ctx.self, &g.RECEIVER_SHADOWED_BY_CONTEXT_PARAMETER, msg, call_span);
                return;
            }
        }
    }
}

/// Whether any level holds a non-receiver context value.
fn hasContextValueInScope(ctx: *Ctx) bool {
    for (ctx.levels.items) |lvl| {
        for (lvl.items) |src| if (!src.is_receiver) return true;
    }
    return false;
}

fn classHasMember(ctx: *Ctx, class_name: []const u8, member: []const u8) bool {
    var seen = std.StringHashMap(void).init(ctx.self.allocator);
    defer seen.deinit();
    return classHasMemberRec(ctx, class_name, member, &seen);
}

fn classHasMemberRec(ctx: *Ctx, class_name: []const u8, member: []const u8, seen: *std.StringHashMap(void)) bool {
    if ((seen.getOrPut(class_name) catch return false).found_existing) return false;
    const c = ctx.class_map.get(class_name) orelse return false;
    for (c.members) |*m| {
        switch (m.*) {
            .Function => |f| if (std.mem.eql(u8, f.name.name, member)) return true,
            .Property => |p| if (std.mem.eql(u8, p.name.name, member)) return true,
            else => {},
        }
    }
    for (c.supertypes) |*s| {
        if (classHasMemberRec(ctx, s.name.name, member, seen)) return true;
    }
    return false;
}

fn resolveContextArgs(ctx: *Ctx, sig: CalleeSig, callee_name: []const u8, type_args: []const ast.TypeRef, call_span: Span) Allocator.Error!void {
    // With a plain sibling, either every context resolves and the call is
    // ambiguous, or the plain overload simply applies.
    if (sig.has_plain_sibling) {
        var all_resolved = true;
        for (sig.types, 0..) |raw, pi| {
            const want = substituteTypeParam(sig, raw, type_args);
            _ = pi;
            if (!contextResolves(ctx, want)) all_resolved = false;
        }
        if (all_resolved) {
            const msg = try std.fmt.allocPrint(ctx.self.allocator, "Overload resolution ambiguity for '{s}': context parameters do not participate in overload resolution.", .{callee_name});
            try emit(ctx.self, &g.OVERLOAD_RESOLUTION_AMBIGUITY, msg, call_span);
        }
        return;
    }
    for (sig.types, 0..) |raw, pi| {
        const want = substituteTypeParam(sig, raw, type_args);
        const pname = sig.names[pi];
        var resolved = false;
        var i = ctx.levels.items.len;
        while (i > 0) {
            i -= 1;
            const lvl = ctx.levels.items[i];
            var count: usize = 0;
            for (lvl.items) |src| {
                if (sourceMatches(ctx.self, src.ty, want)) count += 1;
            }
            if (count >= 2) {
                const msg = try std.fmt.allocPrint(ctx.self.allocator, "Multiple potential context arguments for '{s}' in scope.", .{pname});
                try emit(ctx.self, &g.AMBIGUOUS_CONTEXT_ARGUMENT, msg, call_span);
                resolved = true;
                break;
            }
            if (count == 1) {
                resolved = true;
                break;
            }
        }
        if (!resolved) {
            const msg = try std.fmt.allocPrint(ctx.self.allocator, "No context argument for '{s}' found.", .{pname});
            try emit(ctx.self, &g.NO_CONTEXT_ARGUMENT, msg, call_span);
        }
    }
}

/// The innermost level with a non-zero count decides.
fn contextResolves(ctx: *Ctx, want: []const u8) bool {
    var i = ctx.levels.items.len;
    while (i > 0) {
        i -= 1;
        for (ctx.levels.items[i].items) |src| {
            if (sourceMatches(ctx.self, src.ty, want)) return true;
        }
    }
    return false;
}

/// Substitutes the callee's own type-parameter names.
fn substituteTypeParam(sig: CalleeSig, raw: []const u8, type_args: []const ast.TypeRef) []const u8 {
    for (sig.type_params, 0..) |tp, i| {
        if (std.mem.eql(u8, tp, raw) and i < type_args.len) return type_args[i].name.name;
    }
    return raw;
}

fn checkCallableRef(ctx: *Ctx, name: []const u8, sp: Span) Allocator.Error!void {
    if (ctx.callees.get(name)) |_| {
        const msg = try std.fmt.allocPrint(ctx.self.allocator, "Callable reference to '{s}' is unsupported because it has context parameters.", .{name});
        try emit(ctx.self, &g.CALLABLE_REFERENCE_TO_CONTEXTUAL_DECLARATION, msg, sp);
    }
}
