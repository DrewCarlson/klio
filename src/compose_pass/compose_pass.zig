//! Compose compiler-plugin-equivalent lowering pass (Phase 1).
//!
//! A pluggable AST-to-AST transform that rewrites `@Composable` functions the
//! way androidx's Compose compiler plugin does, so that upstream's real
//! `Composer` / `SlotTable` / `Recomposer` can run unchanged. This module is
//! deliberately self-contained (depends only on `ast` + `span`) so the core
//! lowerer stays oblivious — the transform is registered as a pass, not baked
//! into `src/ir/lower`.
//!
//! Phase 1 emits the restartable-group skeleton without `$changed`-based
//! skipping (that is Phase 2). A `@Composable fun App(x: Int) { Body }`:
//!
//!     fun App(x: Int, $composer: Composer, $changed: Int) {
//!         $composer.startRestartGroup(<key>)
//!         Body                                     // @Composable calls threaded
//!         $composer.endRestartGroup()?.updateScope { c, f -> App(x, c, $changed or 1) }
//!     }
//!
//! Each `@Composable` call in the body gains two trailing arguments — the
//! threaded `$composer` and a child `$changed` (0 in Phase 1). Positional group
//! keys are derived from the call's source span (stable per call site), the same
//! role the plugin's compile-time key constant plays.
//!
//! See plans/compose-plugin-lowering.md.

const std = @import("std");
const ast = @import("ast");
const span_mod = @import("span");

const Span = span_mod.Span;
const Ident = ast.Ident;
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const Param = ast.Param;
const TypeRef = ast.TypeRef;
const Function = ast.Function;
const Block = ast.Block;
const FunctionBody = ast.FunctionBody;

/// Synthetic name of the injected composer parameter.
pub const composer_param = "$composer";
/// Synthetic name of the injected changed-flags parameter.
pub const changed_param = "$changed";

/// Whether a declaration's annotations include `@Composable`. Matches both the
/// bare `Composable` and any dotted path ending in `Composable`.
pub fn isComposable(annotations: []const ast.Annotation) bool {
    for (annotations) |a| {
        if (a.path.len == 0) continue;
        if (std.mem.eql(u8, a.path[a.path.len - 1].name, "Composable")) return true;
    }
    return false;
}

/// A stable positional group key for a call site, derived from its span. The
/// Compose plugin emits a compile-time constant here; a span hash plays the
/// same role — identical across recompositions, distinct per source location.
pub fn positionalKey(sp: Span) i64 {
    var h: u64 = 0xcbf29ce484222325;
    inline for (.{ @as(u64, sp.file.int()), @as(u64, sp.start), @as(u64, sp.end) }) |v| {
        h ^= v;
        h *%= 0x100000001b3;
    }
    // Fold to a signed 32-bit key (the ABI key type is `Int`).
    return @as(i64, @as(i32, @truncate(@as(i64, @bitCast(h)))));
}

// --------------------------------------------------------------------------
// Small AST builders (arena-allocated). Generated nodes carry `gen_span`.
// --------------------------------------------------------------------------

const B = struct {
    a: std.mem.Allocator,
    gen_span: Span,

    fn ident(self: B, name: []const u8) Ident {
        return .{ .name = name, .span = self.gen_span };
    }

    fn box(self: B, e: Expr) *Expr {
        const p = self.a.create(Expr) catch @panic("oom");
        p.* = e;
        return p;
    }

    /// `name` as a single-segment path expression.
    fn pathExpr(self: B, name: []const u8) Expr {
        const segs = self.a.alloc(Ident, 1) catch @panic("oom");
        segs[0] = self.ident(name);
        return .{ .Path = .{ .segments = segs, .span = self.gen_span } };
    }

    fn intLit(self: B, v: i64) Expr {
        return .{ .IntLit = .{ .value = v, .kind = .Int, .span = self.gen_span } };
    }

    /// `receiver.name`.
    fn member(self: B, receiver: Expr, name: []const u8) Expr {
        return .{ .Member = .{
            .receiver = self.box(receiver),
            .name = self.ident(name),
            .safe = false,
            .span = self.gen_span,
        } };
    }

    /// `receiver.name(args)` (positional args, no trailing lambda).
    fn callMember(self: B, receiver: Expr, name: []const u8, args: []Expr) Expr {
        return self.call(self.member(receiver, name), args);
    }

    /// `callee(args)` with all-positional args.
    fn call(self: B, callee: Expr, args: []Expr) Expr {
        const names = self.a.alloc(?[]const u8, args.len) catch @panic("oom");
        for (names) |*n| n.* = null;
        return .{ .Call = .{
            .callee = self.box(callee),
            .args = args,
            .arg_names = names,
            .type_args = &.{},
            .is_infix = false,
            .has_trailing_lambda = false,
            .span = self.gen_span,
        } };
    }

    fn slice1(self: B, e: Expr) []Expr {
        const s = self.a.alloc(Expr, 1) catch @panic("oom");
        s[0] = e;
        return s;
    }

    /// A named user type reference (`Composer`, `Int`) with no generics.
    fn typeRef(self: B, name: []const u8) TypeRef {
        return .{
            .name = self.ident(name),
            .nullable = false,
            .span = self.gen_span,
            .type_args = &.{},
            .function = null,
            .definitely_non_null = false,
            .annotations = &.{},
            .qualified_path = null,
        };
    }

    fn param(self: B, name: []const u8, ty: TypeRef) Param {
        return .{
            .name = self.ident(name),
            .ty = ty,
            .default = null,
            .is_vararg = false,
            .is_crossinline = false,
            .is_noinline = false,
            .annotations = &.{},
            .span = self.gen_span,
        };
    }
};

/// Callback deciding whether a call whose callee is the given simple name binds
/// a `@Composable` function (and so must be threaded the composer). Real
/// integration supplies this from resolution; unit tests supply a fixed set.
pub const ComposableOracle = *const fn (ctx: *anyopaque, callee_name: []const u8) bool;

/// A name-set oracle: a call is composable when its callee's simple name is a
/// declared `@Composable` function. This is the integration oracle (the plugin
/// resolves precisely by symbol; a simple-name set covers the compose API, whose
/// composable functions are consistently named — `Text`, `Column`, `Linear`).
pub const NameSetOracle = struct {
    names: *const std.StringHashMap(void),

    fn isComposableCall(ctx: *anyopaque, callee_name: []const u8) bool {
        const self: *const NameSetOracle = @ptrCast(@alignCast(ctx));
        return self.names.contains(callee_name);
    }
};

/// Collect the simple names of every `@Composable` function declared across a
/// decl slice (top level + class/object members). The result feeds the
/// integration oracle. Caller owns the returned map.
pub fn collectComposableNames(
    a: std.mem.Allocator,
    decls: []const ast.Decl,
) std.mem.Allocator.Error!std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(a);
    try collectInto(&set, decls);
    return set;
}

fn collectInto(set: *std.StringHashMap(void), decls: []const ast.Decl) std.mem.Allocator.Error!void {
    for (decls) |*d| switch (d.*) {
        .Function => |*f| {
            if (isComposable(f.annotations)) try set.put(f.name.name, {});
        },
        .Class => |*c| try collectInto(set, c.members),
        .Object => |*o| try collectInto(set, o.members),
        else => {},
    };
}

/// Transform every `@Composable` top-level function in `decls` in place,
/// threading the composer per the plugin ABI. `composable_names` is the oracle
/// set (built with `collectComposableNames`, optionally extended with names from
/// a baked base). Class/object members and composable lambdas are handled by a
/// later phase.
pub fn transformDecls(
    a: std.mem.Allocator,
    decls: []ast.Decl,
    composable_names: *const std.StringHashMap(void),
) std.mem.Allocator.Error!void {
    var oracle = NameSetOracle{ .names = composable_names };
    for (decls) |*d| switch (d.*) {
        .Function => |*f| {
            if (!isComposable(f.annotations)) continue;
            if (f.body == null) continue;
            const nf = try transformComposableFunction(a, f, NameSetOracle.isComposableCall, &oracle);
            f.* = nf;
        },
        else => {},
    };
}

/// The Phase-1 transform. Returns a NEW `Function` (the input is not mutated);
/// all fresh nodes are arena-allocated. `oracle`/`oracle_ctx` classify callees.
pub fn transformComposableFunction(
    a: std.mem.Allocator,
    f: *const Function,
    oracle: ComposableOracle,
    oracle_ctx: *anyopaque,
) std.mem.Allocator.Error!Function {
    const b = B{ .a = a, .gen_span = f.span };

    // 1. Signature: append `$composer: Composer` and `$changed: Int`.
    var params = try a.alloc(Param, f.params.len + 2);
    @memcpy(params[0..f.params.len], f.params);
    params[f.params.len] = b.param(composer_param, b.typeRef("Composer"));
    params[f.params.len + 1] = b.param(changed_param, b.typeRef("Int"));

    // 2. Body: thread the composer through @Composable calls, then bracket.
    const orig_stmts: []const Stmt = switch (f.body orelse return signatureOnly(f, params)) {
        .Block => |blk| blk.stmts,
        .Expr => |e| blk: {
            // Single-expression body becomes a one-statement block.
            const s = try a.alloc(Stmt, 1);
            s[0] = .{ .Expr = e };
            break :blk s;
        },
    };

    var out: std.ArrayList(Stmt) = .empty;
    // `$composer.startRestartGroup(<key>)`
    try out.append(a, .{ .Expr = b.callMember(
        b.pathExpr(composer_param),
        "startRestartGroup",
        b.slice1(b.intLit(positionalKey(f.span))),
    ) });
    // Threaded body.
    for (orig_stmts) |*s| {
        try out.append(a, try threadStmt(a, b, s, oracle, oracle_ctx));
    }
    // `$composer.endRestartGroup()?.updateScope { c, f -> App(args, c, $changed or 1) }`
    try out.append(a, .{ .Expr = try endRestartGroupExpr(a, b, f) });

    const new_body = Block{ .stmts = try out.toOwnedSlice(a), .span = f.span };
    return withBody(f, params, .{ .Block = new_body });
}

/// Rewrite one statement, threading the composer into any @Composable call.
fn threadStmt(
    a: std.mem.Allocator,
    b: B,
    s: *const Stmt,
    oracle: ComposableOracle,
    ctx: *anyopaque,
) std.mem.Allocator.Error!Stmt {
    return switch (s.*) {
        .Expr => |e| .{ .Expr = try threadExpr(a, b, &e, oracle, ctx) },
        else => s.*,
    };
}

/// Thread the composer into a @Composable call. Non-call / non-composable
/// expressions pass through unchanged (deeper nesting is Phase-2 work).
fn threadExpr(
    a: std.mem.Allocator,
    b: B,
    e: *const Expr,
    oracle: ComposableOracle,
    ctx: *anyopaque,
) std.mem.Allocator.Error!Expr {
    switch (e.*) {
        .Call => |c| {
            const name = calleeSimpleName(c.callee) orelse return e.*;
            if (!oracle(ctx, name)) return e.*;
            // Append `$composer` and a child `$changed` (0 in Phase 1).
            var new_args = try a.alloc(Expr, c.args.len + 2);
            @memcpy(new_args[0..c.args.len], c.args);
            new_args[c.args.len] = b.pathExpr(composer_param);
            new_args[c.args.len + 1] = b.intLit(0);
            const new_names = try a.alloc(?[]const u8, new_args.len);
            for (new_names, 0..) |*n, i| n.* = if (i < c.arg_names.len) c.arg_names[i] else null;
            return .{ .Call = .{
                .callee = c.callee,
                .args = new_args,
                .arg_names = new_names,
                .type_args = c.type_args,
                .is_infix = false,
                .has_trailing_lambda = false,
                .span = c.span,
            } };
        },
        else => return e.*,
    }
}

/// `$composer.endRestartGroup()?.updateScope { c, f -> Self(origArgs, c, $changed or 1) }`
/// — Phase 1 emits the recompose lambda that re-invokes the function with the
/// same value arguments, the recompose composer, and `$changed or 1`.
fn endRestartGroupExpr(a: std.mem.Allocator, b: B, f: *const Function) std.mem.Allocator.Error!Expr {
    // `$composer.endRestartGroup()`
    const end_call = b.callMember(b.pathExpr(composer_param), "endRestartGroup", &.{});
    // `?.updateScope(<lambda>)` — safe member call.
    const lambda = try recomposeLambda(a, b, f);
    return .{ .Call = .{
        .callee = b.box(.{ .Member = .{
            .receiver = b.box(end_call),
            .name = b.ident("updateScope"),
            .safe = true,
            .span = b.gen_span,
        } }),
        .args = b.slice1(lambda),
        .arg_names = try oneNull(a),
        .type_args = &.{},
        .is_infix = false,
        .has_trailing_lambda = true,
        .span = b.gen_span,
    } };
}

/// `{ c, _f -> Self(origValueArgs, c, $changed or 1) }`
fn recomposeLambda(a: std.mem.Allocator, b: B, f: *const Function) std.mem.Allocator.Error!Expr {
    // Re-invoke the function: original value params by name + (recompose
    // composer, $changed or 1).
    var call_args = try a.alloc(Expr, f.params.len + 2);
    for (f.params, 0..) |p, i| call_args[i] = b.pathExpr(p.name.name);
    call_args[f.params.len] = b.pathExpr("$rc"); // recompose composer lambda param
    // `$changed or 1`
    call_args[f.params.len + 1] = .{ .Binary = .{
        .op = .Or,
        .lhs = b.box(b.pathExpr(changed_param)),
        .rhs = b.box(b.intLit(1)),
        .span = b.gen_span,
    } };
    const reinvoke = b.call(b.pathExpr(f.name.name), call_args);

    const lam_params = try a.alloc(Ident, 2);
    lam_params[0] = b.ident("$rc");
    lam_params[1] = b.ident("$rf");
    const lam_ptys = try a.alloc(?TypeRef, 2);
    lam_ptys[0] = null;
    lam_ptys[1] = null;
    const body_stmts = try a.alloc(Stmt, 1);
    body_stmts[0] = .{ .Expr = reinvoke };
    return .{ .Lambda = .{
        .params = lam_params,
        .param_tys = lam_ptys,
        .body = .{ .stmts = body_stmts, .span = b.gen_span },
        .implicit_it = false,
        .span = b.gen_span,
    } };
}

fn oneNull(a: std.mem.Allocator) std.mem.Allocator.Error![]?[]const u8 {
    const s = try a.alloc(?[]const u8, 1);
    s[0] = null;
    return s;
}

/// The simple (last-segment) name a call's callee denotes, or null when the
/// callee is not a plain name / member (Phase 1 only threads those shapes).
fn calleeSimpleName(callee: *const Expr) ?[]const u8 {
    return switch (callee.*) {
        .Path => |p| if (p.segments.len >= 1) p.segments[p.segments.len - 1].name else null,
        .Member => |m| m.name.name,
        else => null,
    };
}

fn signatureOnly(f: *const Function, params: []Param) Function {
    return withBody(f, params, f.body orelse .{ .Block = .{ .stmts = &.{}, .span = f.span } });
}

/// A copy of `f` with new params + body; all other fields preserved. Clears
/// the `@Composable` annotation is left to a later pass — Phase 1 keeps it so
/// downstream still recognises the function during migration.
fn withBody(f: *const Function, params: []Param, body: FunctionBody) Function {
    var out = f.*;
    out.params = params;
    out.body = body;
    return out;
}

// --------------------------------------------------------------------------
// Tests
// --------------------------------------------------------------------------

const testing = std.testing;

fn allComposable(_: *anyopaque, _: []const u8) bool {
    return true;
}

fn noneComposable(_: *anyopaque, _: []const u8) bool {
    return false;
}

fn dummyIdent(name: []const u8) Ident {
    return .{ .name = name, .span = Span.init(span_mod.FileId.from(0), 0, 0) };
}

fn emptyFn(name: []const u8, params: []Param, body: ?FunctionBody, comp: bool) Function {
    return .{
        .name = dummyIdent(name),
        .receiver_type = null,
        .type_params = &.{},
        .where_bounds = &.{},
        .params = params,
        .return_type = null,
        .body = body,
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
        .annotations = if (comp) &composableAnno else &.{},
        .span = Span.init(span_mod.FileId.from(0), 100, 200),
    };
}

var composableAnno = [_]ast.Annotation{.{
    .use_site = null,
    .path = &composablePath,
    .type_args = &.{},
    .args = &.{},
    .arg_names = &.{},
    .span = Span.init(span_mod.FileId.from(0), 0, 0),
}};
var composablePath = [_]Ident{dummyIdent("Composable")};

test "isComposable detects the annotation" {
    var noargs: [0]Param = .{};
    const cf = emptyFn("App", &noargs, null, true);
    const pf = emptyFn("plain", &noargs, null, false);
    try testing.expect(isComposable(cf.annotations));
    try testing.expect(!isComposable(pf.annotations));
}

test "positionalKey is stable per span and fits Int" {
    const s1 = Span.init(span_mod.FileId.from(3), 10, 20);
    const s2 = Span.init(span_mod.FileId.from(3), 10, 21);
    try testing.expectEqual(positionalKey(s1), positionalKey(s1));
    try testing.expect(positionalKey(s1) != positionalKey(s2));
    try testing.expect(positionalKey(s1) >= std.math.minInt(i32) and positionalKey(s1) <= std.math.maxInt(i32));
}

test "transform injects composer/changed params and brackets the body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // @Composable fun App(x: Int) { Text("hi") }
    const gsp = Span.init(span_mod.FileId.from(0), 0, 0);
    var app_params = [_]Param{.{
        .name = dummyIdent("x"),
        .ty = .{ .name = dummyIdent("Int"), .nullable = false, .span = gsp, .type_args = &.{}, .function = null, .definitely_non_null = false, .annotations = &.{}, .qualified_path = null },
        .default = null,
        .is_vararg = false,
        .is_crossinline = false,
        .is_noinline = false,
        .annotations = &.{},
        .span = gsp,
    }};
    // body: Text("hi")
    var text_segs = [_]Ident{dummyIdent("Text")};
    var text_callee = Expr{ .Path = .{ .segments = &text_segs, .span = gsp } };
    var str_parts = [_]ast.StringPart{.{ .Text = "hi" }};
    var text_args = [_]Expr{.{ .StringTemplate = .{ .parts = &str_parts, .span = gsp } }};
    var text_argnames = [_]?[]const u8{null};
    var body_stmts = [_]Stmt{.{ .Expr = .{ .Call = .{
        .callee = &text_callee,
        .args = &text_args,
        .arg_names = &text_argnames,
        .type_args = &.{},
        .is_infix = false,
        .has_trailing_lambda = false,
        .span = Span.init(span_mod.FileId.from(0), 300, 310),
    } } }};
    const app = emptyFn("App", &app_params, .{ .Block = .{ .stmts = &body_stmts, .span = gsp } }, true);

    var ctx: u8 = 0;
    const out = try transformComposableFunction(a, &app, allComposable, &ctx);

    // Signature gained the two synthetic params.
    try testing.expectEqual(@as(usize, 3), out.params.len);
    try testing.expectEqualStrings("x", out.params[0].name.name);
    try testing.expectEqualStrings(composer_param, out.params[1].name.name);
    try testing.expectEqualStrings("Composer", out.params[1].ty.name.name);
    try testing.expectEqualStrings(changed_param, out.params[2].name.name);

    const stmts = out.body.?.Block.stmts;
    // startRestartGroup + Text(...) + endRestartGroup?.updateScope{}
    try testing.expectEqual(@as(usize, 3), stmts.len);
    // First stmt: $composer.startRestartGroup(<key>)
    try testing.expectEqualStrings("startRestartGroup", stmts[0].Expr.Call.callee.Member.name.name);
    try testing.expectEqualStrings(composer_param, stmts[0].Expr.Call.callee.Member.receiver.Path.segments[0].name);
    // Middle stmt: the Text call gained 2 trailing args (composer + changed).
    const text_call = stmts[1].Expr.Call;
    try testing.expectEqual(@as(usize, 3), text_call.args.len);
    try testing.expectEqualStrings(composer_param, text_call.args[1].Path.segments[0].name);
    try testing.expectEqual(@as(i64, 0), text_call.args[2].IntLit.value);
    // Last stmt: endRestartGroup()?.updateScope { ... }
    const upd = stmts[2].Expr.Call;
    try testing.expect(upd.callee.Member.safe);
    try testing.expectEqualStrings("updateScope", upd.callee.Member.name.name);
    try testing.expectEqualStrings("endRestartGroup", upd.callee.Member.receiver.Call.callee.Member.name.name);
}

test "non-composable callees are not threaded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gsp = Span.init(span_mod.FileId.from(0), 0, 0);
    var segs = [_]Ident{dummyIdent("println")};
    var callee = Expr{ .Path = .{ .segments = &segs, .span = gsp } };
    var no_args = [_]Expr{};
    var no_names = [_]?[]const u8{};
    var body_stmts = [_]Stmt{.{ .Expr = .{ .Call = .{
        .callee = &callee,
        .args = &no_args,
        .arg_names = &no_names,
        .type_args = &.{},
        .is_infix = false,
        .has_trailing_lambda = false,
        .span = gsp,
    } } }};
    var noparams: [0]Param = .{};
    const fnp = emptyFn("Host", &noparams, .{ .Block = .{ .stmts = &body_stmts, .span = gsp } }, true);
    var ctx: u8 = 0;
    const out = try transformComposableFunction(a, &fnp, noneComposable, &ctx);
    const stmts = out.body.?.Block.stmts;
    // println keeps 0 args (not threaded).
    try testing.expectEqual(@as(usize, 0), stmts[1].Expr.Call.args.len);
}
