//! Strip the bodies of non-inline stdlib functions from the lifted AST, which
//! never run from the AST. Two readers keep theirs: `inline` bodies, spliced
//! into user code by the lowerer, and bodies the lowered code points into: an
//! `ObjectExpr` behind an `Inst.BuildObject`, a local class or object behind
//! an `Inst.RegisterClass`. Dispatch reads `body != null` as a
//! concrete-versus-abstract sentinel, so a stripped body is an empty block.
//!
//! A stripped body's trees are freed unless an instruction still points into
//! them: `collectPinned` gathers those addresses from the lowered module (an
//! `Inst.AstLambda` keeps its lambda's block to lower again at runtime), and a
//! body holding one is blanked but left allocated.

const std = @import("std");
const builtin = @import("builtin");
const ast = @import("ast");
const ir = @import("ir");
const runtime = @import("runtime");
const Allocator = std.mem.Allocator;

const Decl = ast.Decl;
const Function = ast.Function;
const FunctionBody = ast.FunctionBody;
const Block = ast.Block;
const Stmt = ast.Stmt;
const Expr = ast.Expr;

/// What `stripDeadBodies` cut loose: the trees under the stripped bodies,
/// freed when an allocator was given and counted either way. `pinned_bodies`
/// were blanked but kept allocated because lowered code points into them.
pub const Released = struct { bodies: usize = 0, nodes: usize = 0, bytes: usize = 0, pinned_bodies: usize = 0 };

/// Addresses of AST nodes and node slices the lowered module points into.
pub const Pinned = std.AutoHashMapUnmanaged(usize, void);

/// Every AST address reachable from an instruction of `module`: a lambda
/// block kept for a runtime re-lowering, an object expression, a local class,
/// and everything under them. The bake encodes those trees inline, and the
/// block an instruction holds may be one lowering synthesised around nodes
/// of the body, so the nodes are pinned, not only the root.
pub fn collectPinned(a: Allocator, module: *const ir.Module, out: *Pinned) Allocator.Error!void {
    var rel = BodyRelease{ .allocator = null, .collect = .{ .a = a, .out = out } };
    defer rel.deinit();
    for (module.funcs.items) |*f| collectPinnedFunc(&rel, f);
    for (module.late_funcs.items) |f| collectPinnedFunc(&rel, f);
}

fn collectPinnedFunc(rel: *BodyRelease, f: *const ir.Func) void {
    for (f.blocks) |*b| {
        for (b.insts) |*inst| switch (inst.*) {
            .AstLambda => |al| rel.release(ast.Block, &al.body_ast),
            .RegisterClass => |*rc| switch (rc.class) {
                .ptr => |p| rel.release(ast.Class, p),
                .ref => {},
            },
            .BuildObject => |bo| switch (bo.ast) {
                .ptr => |p| rel.release(Expr, p),
                .ref => {},
            },
            else => {},
        };
    }
}

/// Replace the bodies of non-inline, object-free functions across `decls` with
/// an empty block, recursing into members. Such a top-level function also drops
/// its signature: resolution binds through the baked symbol index and calls
/// dispatch by `FuncId`, so only class members are read back through
/// `MethodDef.decl`. `keep_composable_sigs` spares the signature of a
/// `@Composable` function, which the plugin's oracle reads from the base.
/// With `allocator`, the AST's own, each stripped body's trees are freed
/// unless `pinned` holds an address inside them; a file whose declarations
/// were copied into `decls` still points at the freed trees.
pub fn stripDeadBodies(decls: []Decl, keep_composable_sigs: bool, allocator: ?Allocator, pinned: ?*const Pinned) Released {
    return stripDeadBodiesDeferring(decls, keep_composable_sigs, allocator, pinned, null);
}

/// The bodies a strip detached but did not free: `releaseDetached` frees them
/// later, off the path that is waiting on the strip.
pub const Detached = std.ArrayList(FunctionBody);

/// `stripDeadBodies` that hands the stripped bodies to `deferred` instead of
/// freeing them, so the walk that frees can run beside later work. The
/// declarations are left as the strip leaves them either way. A debug build
/// frees in place, where its walk over the kept declarations then refuses a
/// pointer into what was freed.
pub fn stripDeadBodiesDeferring(decls: []Decl, keep_composable_sigs: bool, allocator: ?Allocator, pinned: ?*const Pinned, deferred: ?*Detached) Released {
    if (builtin.mode != .Debug) {
        if (deferred) |out| {
            if (allocator) |a| {
                if (stripOnThreads(decls, keep_composable_sigs, a, pinned, out)) |stats| return stats;
            }
        }
    }
    var rel = BodyRelease{ .allocator = allocator, .pinned = pinned, .deferred = if (builtin.mode == .Debug) null else deferred };
    defer rel.deinit();
    for (decls) |*d| pruneDecl(d, true, keep_composable_sigs, &rel);
    // A debug build then walks everything that stays and refuses a pointer
    // into what was freed: a pass that copied a subtree between declarations
    // shows up here by name rather than as a later crash.
    if (builtin.mode == .Debug and allocator != null) {
        rel.verify = true;
        for (decls) |*d| {
            rel.current_decl = declName(d);
            rel.release(Decl, d);
        }
    }
    return rel.stats;
}

/// The strip over contiguous runs of the declarations on threads: each walks
/// its own declarations against the shared, read-only pinned set and
/// detaches into its own list, which the caller's list then takes over. Null
/// when there is too little to share out, so the caller strips in place.
fn stripOnThreads(decls: []Decl, keep_composable_sigs: bool, allocator: Allocator, pinned: ?*const Pinned, out: *Detached) ?Released {
    const threads = stripThreads(decls.len);
    if (threads < 2) return null;
    const Part = struct {
        decls: []Decl,
        keep_sigs: bool,
        allocator: Allocator,
        pinned: ?*const Pinned,
        detached: Detached = .empty,
        stats: Released = .{},
        thread: ?std.Thread = null,

        fn run(self: *@This()) void {
            defer runtime.slab.flushMagazines();
            var rel = BodyRelease{ .allocator = self.allocator, .pinned = self.pinned, .deferred = &self.detached };
            defer rel.deinit();
            for (self.decls) |*d| pruneDecl(d, true, self.keep_sigs, &rel);
            self.stats = rel.stats;
        }
    };
    const parts = allocator.alloc(Part, threads) catch return null;
    defer allocator.free(parts);
    const per = (decls.len + threads - 1) / threads;
    for (parts, 0..) |*part, i| {
        const lo = @min(i * per, decls.len);
        const hi = @min(lo + per, decls.len);
        part.* = .{ .decls = decls[lo..hi], .keep_sigs = keep_composable_sigs, .allocator = allocator, .pinned = pinned };
    }
    for (parts[1..]) |*part| part.thread = std.Thread.spawn(.{}, Part.run, .{part}) catch null;
    parts[0].run();
    var total: Released = .{};
    for (parts) |*part| {
        if (part.thread) |t| t.join() else if (part != &parts[0]) part.run();
        total.bodies += part.stats.bodies;
        total.nodes += part.stats.nodes;
        total.bytes += part.stats.bytes;
        total.pinned_bodies += part.stats.pinned_bodies;
        out.appendSlice(allocator, part.detached.items) catch {
            // Out of room for the list: free these now rather than leak them.
            _ = releaseDetached(allocator, part.detached.items);
        };
        part.detached.deinit(allocator);
    }
    return total;
}

/// One thread per sixty-four declarations, at most one per CPU, under the
/// `KLIO_MAX_WORKERS` ceiling every pool honours.
fn stripThreads(n_decls: usize) usize {
    var n: usize = std.Thread.getCpuCount() catch 1;
    if (runtime.envOnce("KLIO_MAX_WORKERS")) |v| {
        if (std.fmt.parseInt(usize, v, 10)) |x| {
            if (x != 0) n = @min(n, x);
        } else |_| {}
    }
    n = @min(n, n_decls / 64);
    return @max(n, 1);
}

/// Frees the bodies a deferring strip detached.
pub fn releaseDetached(allocator: Allocator, bodies: []const FunctionBody) Released {
    var rel = BodyRelease{ .allocator = allocator };
    defer rel.deinit();
    for (bodies) |*b| rel.release(FunctionBody, b);
    return rel.stats;
}

fn declName(d: *const Decl) []const u8 {
    return switch (d.*) {
        .Function => |*f| f.name.name,
        .Property => |p| p.name.name,
        .Class => |*c| c.name.name,
        .Object => |*o| o.name.name,
        .TypeAlias => |*t| t.name.name,
    };
}

fn pruneDecl(d: *Decl, top_level: bool, keep_composable_sigs: bool, rel: *BodyRelease) void {
    switch (d.*) {
        .Function => |*f| pruneFunction(f, top_level, keep_composable_sigs, rel),
        .Class => |*c| {
            for (c.members) |*m| pruneDecl(m, false, keep_composable_sigs, rel);
        },
        .Object => |*o| {
            for (o.members) |*m| pruneDecl(m, false, keep_composable_sigs, rel);
        },
        .Property, .TypeAlias => {},
    }
}

/// Frees the trees a stripped body owned. The walk is over the node types:
/// every pointer and slice under the body is the body's own, except strings,
/// which are slices of the source text, and a `TypeRef`, `TypeArg` or
/// `Annotation`, whose children the lowered module shares through by-value
/// copies. A class or object declaration never sits in a stripped body.
const BodyRelease = struct {
    allocator: ?Allocator,
    pinned: ?*const Pinned = null,
    stats: Released = .{},
    /// A first pass over a body only looks for pinned addresses.
    dry: bool = false,
    hit: bool = false,
    /// The debug pass over the kept declarations: nothing is freed or counted,
    /// and a node the strip freed is reported.
    verify: bool = false,
    current_decl: []const u8 = "",
    /// `collectPinned`'s pass: every address visited goes into the set.
    collect: ?struct { a: Allocator, out: *Pinned } = null,
    /// A stripped body goes here instead of being freed.
    deferred: ?*Detached = null,
    /// A subtree reached twice would be shared between bodies, which no pass
    /// produces; debug builds refuse rather than free it twice.
    seen: Seen = if (builtin.mode == .Debug) .empty else {},

    const Seen = if (builtin.mode == .Debug) std.AutoHashMapUnmanaged(usize, void) else void;

    fn deinit(self: *BodyRelease) void {
        if (builtin.mode == .Debug) self.seen.deinit(std.heap.page_allocator);
    }

    /// Never freed: shared by value with the lowered module, or a declaration.
    fn keep(comptime T: type) bool {
        return T == ast.TypeRef or T == ast.FunctionTypeRef or T == ast.TypeArg or T == ast.Annotation;
    }

    /// A declaration never sits in a stripped body; the verify pass descends
    /// into these to reach the member bodies that stay.
    fn isDecl(comptime T: type) bool {
        return T == ast.Class or T == ast.ObjectDecl or T == ast.TypeAlias;
    }

    fn releaseBody(self: *BodyRelease, body: *const FunctionBody) void {
        if (self.pinned != null) {
            self.dry = true;
            self.hit = false;
            const saved = self.stats;
            self.release(FunctionBody, body);
            self.dry = false;
            self.stats = saved;
            if (self.hit) {
                self.stats.pinned_bodies += 1;
                return;
            }
        }
        self.stats.bodies += 1;
        if (self.deferred) |d| {
            if (self.allocator) |a| {
                if (d.append(a, body.*)) |_| return else |_| {}
            }
        }
        self.release(FunctionBody, body);
    }

    fn note(self: *BodyRelease, ptr: usize, bytes: usize, comptime what: []const u8) void {
        if (self.collect) |c| {
            c.out.put(c.a, ptr, {}) catch {};
            return;
        }
        if (self.verify) {
            if (builtin.mode == .Debug and self.seen.contains(ptr)) {
                std.debug.panic("prune: kept declaration `{s}` points into a freed body ({s})", .{ self.current_decl, what });
            }
            return;
        }
        self.stats.nodes += 1;
        self.stats.bytes += bytes;
        if (self.dry) {
            if (self.pinned.?.contains(ptr)) self.hit = true;
            return;
        }
        if (builtin.mode == .Debug) {
            const gop = self.seen.getOrPut(std.heap.page_allocator, ptr) catch return;
            if (gop.found_existing) @panic("prune: a stripped body shares a subtree with another");
        }
    }

    fn freeing(self: *const BodyRelease) ?Allocator {
        return if (self.dry or self.verify or self.collect != null) null else self.allocator;
    }

    /// The verify and collect passes read declarations too.
    fn descendsDecls(self: *const BodyRelease) bool {
        return self.verify or self.collect != null;
    }

    fn release(self: *BodyRelease, comptime T: type, v: *const T) void {
        if (comptime keep(T)) return;
        if (comptime isDecl(T)) {
            if (!self.descendsDecls()) return;
        }
        switch (@typeInfo(T)) {
            .pointer => |p| switch (p.size) {
                .one => {
                    if (comptime keep(p.child)) return;
                    if (comptime isDecl(p.child)) {
                        if (!self.descendsDecls()) return;
                    }
                    self.release(p.child, v.*);
                    self.note(@intFromPtr(v.*), @sizeOf(p.child), @typeName(p.child));
                    if (self.freeing()) |a| a.destroy(v.*);
                },
                .slice => {
                    if (comptime (p.child == u8 or keep(p.child))) return;
                    if (comptime isDecl(p.child)) {
                        if (!self.descendsDecls()) return;
                    }
                    for (v.*) |*e| self.release(p.child, e);
                    if (v.len == 0) return;
                    self.note(@intFromPtr(v.ptr), v.len * @sizeOf(p.child), "[]" ++ @typeName(p.child));
                    if (self.freeing()) |a| a.free(v.*);
                },
                else => {},
            },
            .optional => |o| if (v.*) |*inner| self.release(o.child, inner),
            .@"struct" => |s| inline for (s.fields) |f| self.release(f.type, &@field(v.*, f.name)),
            .@"union" => |u| {
                if (u.tag_type == null) return;
                switch (v.*) {
                    inline else => |*payload| self.release(@TypeOf(payload.*), payload),
                }
            },
            .array => |a| for (v) |*e| self.release(a.child, e),
            else => {},
        }
    }
};

/// An annotation path ending in `Composable`; mirrors `compose_pass`.
fn annotationsHaveComposable(annotations: []const ast.Annotation) bool {
    for (annotations) |ann| {
        if (ann.path.len == 0) continue;
        if (std.mem.eql(u8, ann.path[ann.path.len - 1].name, "Composable")) return true;
    }
    return false;
}

/// `@Composable`, or declaring a `@Composable`-typed lambda parameter.
fn composeOracleNeedsSig(f: *const Function) bool {
    if (annotationsHaveComposable(f.annotations)) return true;
    for (f.params) |p| {
        if (p.ty.function != null and annotationsHaveComposable(p.ty.x().annotations)) return true;
    }
    return false;
}

fn pruneFunction(f: *Function, top_level: bool, keep_composable_sigs: bool, rel: *BodyRelease) void {
    const keep_sig = keep_composable_sigs and composeOracleNeedsSig(f);
    if (f.body) |*body| {
        // Inline bodies splice at lower time; the lowered code points into the others.
        if (f.is_inline or fnBodyKeepsAst(body)) return;
        // Copy first: `body` aliases the storage about to be written.
        const old = body.*;
        const sp = fnBodySpan(&old);
        // Keep `body != null` so dispatch still treats the method as concrete.
        f.body = .{ .Block = .{ .stmts = &.{}, .span = sp } };
        rel.releaseBody(&old);
        if (top_level and !keep_sig) {
            f.receiver_type = null;
            f.type_params = &.{};
            f.where_bounds = &.{};
            f.params = &.{};
            f.return_type = null;
            f.annotations = &.{};
        }
    }
}

fn fnBodySpan(b: *const FunctionBody) ast.Span {
    return switch (b.*) {
        .Block => |*blk| blk.span,
        .Expr => |*e| e.span(),
    };
}

/// Every `inline` function across `decls` whose body the lowered code does not
/// point into: the bodies the image can defer to a lazily-decoded side section.
pub fn collectDeferrable(allocator: std.mem.Allocator, decls: []const Decl, out: *std.ArrayList(*Function)) std.mem.Allocator.Error!void {
    for (decls) |*d| try collectDeferrableDecl(allocator, d, out);
}

fn collectDeferrableDecl(allocator: std.mem.Allocator, d: *const Decl, out: *std.ArrayList(*Function)) std.mem.Allocator.Error!void {
    switch (d.*) {
        .Function => |*f| {
            if (f.body) |*body| {
                if (f.is_inline and !fnBodyKeepsAst(body)) try out.append(allocator, @constCast(f));
            }
        },
        .Class => |*c| for (c.members) |*m| try collectDeferrableDecl(allocator, m, out),
        .Object => |*o| for (o.members) |*m| try collectDeferrableDecl(allocator, m, out),
        .Property, .TypeAlias => {},
    }
}

// Detection of what the lowered code points into, exhaustive over every
// `Expr` and `Stmt` case: an object expression, or a local class or object.

pub fn fnBodyKeepsAst(b: *const FunctionBody) bool {
    return switch (b.*) {
        .Block => |*blk| blockKeepsAst(blk),
        .Expr => |*e| exprKeepsAst(e),
    };
}

fn blockKeepsAst(b: *const Block) bool {
    for (b.stmts) |*s| if (stmtKeepsAst(s)) return true;
    return false;
}

fn stmtKeepsAst(s: *const Stmt) bool {
    return switch (s.*) {
        .Expr => |*e| exprKeepsAst(e),
        .Decl => |d| declKeepsAst(d),
        .Assign => |a| exprKeepsAst(&a.target) or exprKeepsAst(&a.value),
        .DestructuringDecl => |dd| exprKeepsAst(&dd.init),
    };
}

fn declKeepsAst(d: *const Decl) bool {
    return switch (d.*) {
        .Function => |*f| if (f.body) |*b| fnBodyKeepsAst(b) else false,
        .Property => |p| {
            if (p.init) |e| if (exprKeepsAst(e)) return true;
            if (p.explicit_field) |ef| {
                if (ef.init) |e| if (exprKeepsAst(e)) return true;
            }
            if (p.delegate) |e| if (exprKeepsAst(e)) return true;
            if (p.getter) |acc| if (fnBodyKeepsAst(&acc.body)) return true;
            if (p.setter) |acc| if (fnBodyKeepsAst(&acc.body)) return true;
            return false;
        },
        // Declared inside a body: an `Inst.RegisterClass` points at it.
        .Class, .Object => true,
        .TypeAlias => false,
    };
}

fn optExprKeepsAst(e: ?*const Expr) bool {
    return if (e) |x| exprKeepsAst(x) else false;
}

fn exprKeepsAst(e: *const Expr) bool {
    return switch (e.*) {
        .ObjectExpr => true,
        .IntLit, .FloatLit, .BoolLit, .NullLit, .CharLit, .Path, .This, .Super, .PropertyRef, .Break, .Continue => false,
        .StringTemplate => |*x| {
            for (x.parts) |*p| switch (p.*) {
                .Interp => |ie| if (exprKeepsAst(ie)) return true,
                .Text, .ShortInterp => {},
            };
            return false;
        },
        .Member => |*x| exprKeepsAst(x.receiver),
        .Call => |*x| {
            if (exprKeepsAst(x.callee)) return true;
            for (x.args) |*a| if (exprKeepsAst(a)) return true;
            return false;
        },
        .Index => |*x| {
            if (exprKeepsAst(x.receiver)) return true;
            for (x.args) |*a| if (exprKeepsAst(a)) return true;
            return false;
        },
        .Binary => |*x| exprKeepsAst(x.lhs) or exprKeepsAst(x.rhs),
        .Unary => |*x| exprKeepsAst(x.expr),
        .Postfix => |*x| exprKeepsAst(x.expr),
        .If => |*x| exprKeepsAst(x.cond) or exprKeepsAst(x.then_branch) or optExprKeepsAst(x.else_branch),
        .While => |*x| exprKeepsAst(x.cond) or exprKeepsAst(x.body),
        .DoWhile => |*x| optExprKeepsAst(x.body) or exprKeepsAst(x.cond),
        .For => |x| exprKeepsAst(x.iter) or exprKeepsAst(x.body),
        .Return => |*x| optExprKeepsAst(x.value),
        .Labeled => |*x| exprKeepsAst(x.expr),
        .Block => |*x| blockKeepsAst(x),
        .Throw => |*x| exprKeepsAst(x.value),
        .Try => |x| {
            if (blockKeepsAst(&x.body)) return true;
            for (x.catches) |*c| if (blockKeepsAst(&c.body)) return true;
            if (x.finally) |*fb| if (blockKeepsAst(fb)) return true;
            return false;
        },
        .Lambda => |x| blockKeepsAst(&x.body),
        .MemberRef => |*x| exprKeepsAst(x.receiver),
        .When => |x| {
            if (optExprKeepsAst(x.subject)) return true;
            for (x.branches) |*br| {
                if (exprKeepsAst(&br.body)) return true;
                for (br.patterns) |*p| switch (p.kind) {
                    .Value => |*ve| if (exprKeepsAst(ve)) return true,
                    .InRange => |*ie| if (exprKeepsAst(ie)) return true,
                    .NotInRange => |*ie| if (exprKeepsAst(ie)) return true,
                    .IsType, .NotIsType, .Else => {},
                };
            }
            return false;
        },
        .IsCheck => |x| exprKeepsAst(x.expr),
        .As => |x| exprKeepsAst(x.expr),
        .AnonFun => |x| if (x.body) |b| fnBodyKeepsAst(b) else false,
        .Spread => |*x| exprKeepsAst(x.expr),
    };
}

const testing = std.testing;

fn tSpan(s: u32, e: u32) ast.Span {
    return .{ .file = @enumFromInt(0), .start = s, .end = e };
}

fn tIdent(n: []const u8) ast.Ident {
    return .{ .name = n, .span = tSpan(0, 0) };
}

fn tFn(body: ?FunctionBody, is_inline: bool) Function {
    return .{
        .name = tIdent("f"),
        .receiver_type = null,
        .type_params = &.{},
        .where_bounds = &.{},
        .params = &.{},
        .return_type = null,
        .body = body,
        .is_open = false,
        .is_override = false,
        .is_abstract = false,
        .is_operator = false,
        .is_inline = is_inline,
        .is_infix = false,
        .is_tailrec = false,
        .is_suspend = false,
        .is_expect = false,
        .is_actual = false,
        .visibility = .Public,
        .annotations = &.{},
        .span = tSpan(100, 200),
    };
}

fn tIntStmt() Stmt {
    return .{ .Expr = .{ .IntLit = .{ .value = 7, .kind = .Int, .span = tSpan(10, 11) } } };
}

/// The tests build bodies on the stack, so the release only counts.
fn tPrune(f: *Function, top_level: bool, keep_composable_sigs: bool) void {
    var rel = BodyRelease{ .allocator = null };
    defer rel.deinit();
    pruneFunction(f, top_level, keep_composable_sigs, &rel);
}

fn tClass() ast.Class {
    return .{
        .name = .{ .name = "Local", .span = tSpan(3, 4) },
        .type_params = &.{},
        .primary_params = &.{},
        .supertypes = &.{},
        .supertype_args = &.{},
        .supertype_delegates = &.{},
        .is_data = false,
        .is_companion = false,
        .is_enum = false,
        .is_sealed = false,
        .is_open = false,
        .is_abstract = false,
        .is_inner = false,
        .is_interface = false,
        .is_fun_interface = false,
        .is_value = false,
        .is_annotation = false,
        .is_expect = false,
        .is_actual = false,
        .members = &.{},
        .visibility = .Public,
        .primary_ctor_visibility = null,
        .annotations = &.{},
        .span = tSpan(3, 4),
    };
}

test "a body declaring a local class is left intact" {
    var decl_decl = Decl{ .Class = tClass() };
    var stmts = [_]Stmt{.{ .Decl = &decl_decl }};
    var f = tFn(.{ .Block = .{ .stmts = &stmts, .span = tSpan(1, 2) } }, false);
    tPrune(&f, true, false);
    try testing.expectEqual(@as(usize, 1), f.body.?.Block.stmts.len);
}

test "stripping frees exactly the trees the body owned" {
    const a = testing.allocator;
    const callee = try a.create(Expr);
    callee.* = .{ .Path = .{ .segments = try a.dupe(ast.Ident, &.{.{ .name = "f", .span = tSpan(0, 1) }}), .span = tSpan(0, 1) } };
    const recv = try a.create(Expr);
    recv.* = .{ .IntLit = .{ .value = 2, .kind = .Int, .span = tSpan(2, 3) } };
    const in_tpl = try a.create(Expr);
    in_tpl.* = .{ .IntLit = .{ .value = 3, .kind = .Int, .span = tSpan(5, 6) } };
    const parts = try a.alloc(ast.StringPart, 2);
    parts[0] = .{ .Text = "lit" };
    parts[1] = .{ .Interp = in_tpl };
    const args = try a.alloc(Expr, 2);
    args[0] = .{ .Member = .{ .receiver = recv, .name = .{ .name = "x", .span = tSpan(3, 4) }, .safe = false, .span = tSpan(2, 4) } };
    args[1] = .{ .StringTemplate = .{ .parts = parts, .span = tSpan(5, 8) } };
    const arg_names = try a.alloc(?[]const u8, 2);
    arg_names[0] = null;
    arg_names[1] = "n";
    const stmts = try a.alloc(Stmt, 1);
    stmts[0] = .{ .Expr = .{ .Call = .{
        .callee = callee,
        .args = args,
        .arg_names = arg_names,
        .type_args = &.{},
        .is_infix = false,
        .span = tSpan(0, 9),
    } } };
    var decls = [_]Decl{.{ .Function = tFn(.{ .Block = .{ .stmts = stmts, .span = tSpan(0, 9) } }, false) }};
    const released = stripDeadBodies(&decls, false, a, null);
    // The three boxed expressions and the five slices; the testing allocator
    // reports anything left over, and a second free of any of them.
    try testing.expectEqual(@as(usize, 1), released.bodies);
    try testing.expectEqual(@as(usize, 8), released.nodes);
    try testing.expectEqual(@as(usize, 0), decls[0].Function.body.?.Block.stmts.len);
}

test "a body an instruction points into is blanked but kept allocated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const inner = try a.alloc(Stmt, 1);
    inner[0] = tIntStmt();
    const stmts = try a.alloc(Stmt, 1);
    var lam_node_645 = ast.LambdaExpr{
        .params = &.{},
        .body = .{ .stmts = inner, .span = tSpan(2, 3) },
        .span = tSpan(1, 4),
    };
    stmts[0] = .{ .Expr = .{ .Lambda = &lam_node_645 } };
    var decls = [_]Decl{.{ .Function = tFn(.{ .Block = .{ .stmts = stmts, .span = tSpan(0, 5) } }, false) }};
    var pinned: Pinned = .empty;
    defer pinned.deinit(testing.allocator);
    try pinned.put(testing.allocator, @intFromPtr(inner.ptr), {});
    const released = stripDeadBodies(&decls, false, a, &pinned);
    try testing.expectEqual(@as(usize, 1), released.pinned_bodies);
    try testing.expectEqual(@as(usize, 0), released.bodies);
    try testing.expectEqual(@as(usize, 0), released.nodes);
    try testing.expectEqual(@as(usize, 0), decls[0].Function.body.?.Block.stmts.len);
    // The lambda's block is still readable through the pinned address.
    try testing.expectEqual(@as(i64, 7), inner[0].Expr.IntLit.value);
}

test "non-inline body is stripped, span preserved" {
    var stmts = [_]Stmt{tIntStmt()};
    var f = tFn(.{ .Block = .{ .stmts = &stmts, .span = tSpan(42, 99) } }, false);
    tPrune(&f, true, false);
    try testing.expect(f.body != null);
    try testing.expect(f.body.? == .Block);
    try testing.expectEqual(@as(usize, 0), f.body.?.Block.stmts.len);
    // The empty block carries the original body's span verbatim.
    try testing.expectEqual(@as(u32, 42), f.body.?.Block.span.start);
    try testing.expectEqual(@as(u32, 99), f.body.?.Block.span.end);
}

test "expression body is stripped, its span preserved" {
    var f = tFn(.{ .Expr = .{ .IntLit = .{ .value = 1, .kind = .Int, .span = tSpan(7, 13) } } }, false);
    tPrune(&f, true, false);
    try testing.expect(f.body.? == .Block);
    try testing.expectEqual(@as(usize, 0), f.body.?.Block.stmts.len);
    try testing.expectEqual(@as(u32, 7), f.body.?.Block.span.start);
    try testing.expectEqual(@as(u32, 13), f.body.?.Block.span.end);
}

test "inline body is left intact" {
    var stmts = [_]Stmt{tIntStmt()};
    var f = tFn(.{ .Block = .{ .stmts = &stmts, .span = tSpan(1, 2) } }, true);
    tPrune(&f, true, false);
    try testing.expectEqual(@as(usize, 1), f.body.?.Block.stmts.len);
}

test "object-bearing body is left intact" {
    var obj_node = ast.ObjectLiteral{
        .supertypes = &.{},
        .supertype_args = &.{},
        .supertype_delegates = &.{},
        .members = &.{},
        .init_blocks = &.{},
        .init_block_positions = &.{},
        .span = tSpan(5, 6),
    };
    const obj: Expr = .{ .ObjectExpr = &obj_node };
    var stmts = [_]Stmt{.{ .Expr = obj }};
    var f = tFn(.{ .Block = .{ .stmts = &stmts, .span = tSpan(1, 2) } }, false);
    tPrune(&f, true, false);
    try testing.expectEqual(@as(usize, 1), f.body.?.Block.stmts.len);
}

test "abstract body (null) stays null" {
    var f = tFn(null, false);
    tPrune(&f, true, false);
    try testing.expect(f.body == null);
}

test "a @Composable function keeps its signature when composable sigs are kept" {
    // The oracle reads composable signatures from the lifted decls.
    var stmts = [_]Stmt{tIntStmt()};
    var f = tFn(.{ .Block = .{ .stmts = &stmts, .span = tSpan(1, 2) } }, false);
    var composable_path = [_]ast.Ident{tIdent("Composable")};
    var anns = [_]ast.Annotation{.{ .use_site = null, .path = &composable_path, .type_args = &.{}, .args = &.{}, .arg_names = &.{}, .span = tSpan(0, 0) }};
    f.annotations = &anns;
    var params = [_]ast.Param{.{
        .name = tIdent("content"),
        .ty = .{ .name = tIdent("Function0"), .nullable = false, .span = tSpan(0, 0), .type_args = &.{}, .function = null, .definitely_non_null = false },
        .default = null,
        .is_vararg = false,
        .is_crossinline = false,
        .is_noinline = false,
        .annotations = &.{},
        .span = tSpan(0, 0),
    }};
    f.params = &params;
    tPrune(&f, true, true);
    try testing.expectEqual(@as(usize, 0), f.body.?.Block.stmts.len);
    try testing.expectEqual(@as(usize, 1), f.annotations.len);
    try testing.expectEqual(@as(usize, 1), f.params.len);
    try testing.expect(annotationsHaveComposable(f.annotations));
}

test "a plain function still drops its signature even when composable sigs are kept" {
    var stmts = [_]Stmt{tIntStmt()};
    var f = tFn(.{ .Block = .{ .stmts = &stmts, .span = tSpan(1, 2) } }, false);
    tPrune(&f, true, true);
    try testing.expectEqual(@as(usize, 0), f.params.len);
    try testing.expectEqual(@as(usize, 0), f.annotations.len);
}
