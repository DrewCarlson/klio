//! Unit tests for the Compose lowering pass.

const std = @import("std");
const ast = @import("ast");
const span_mod = @import("span");
const root = @import("../compose_pass.zig");

const Span = span_mod.Span;
const Ident = ast.Ident;
const Decl = ast.Decl;
const Expr = ast.Expr;
const Function = ast.Function;
const FunctionBody = ast.FunctionBody;
const Param = ast.Param;
const Stmt = ast.Stmt;
const TypeRef = ast.TypeRef;

const composer_param = root.composer_param;
const changed_param = root.changed_param;
const dirty_local = root.dirty_local;
const isComposable = root.isComposable;
const positionalKey = root.positionalKey;

const builder = @import("builder.zig");
const B = builder.B;

const collect = @import("collect.zig");
const collectComposableNames = collect.collectComposableNames;
const collectComposableGetterProps = collect.collectComposableGetterProps;

const epilogue = @import("epilogue.zig");
const isComposerCallStmt = epilogue.isComposerCallStmt;

const stability = @import("stability.zig");
const Stability = stability.Stability;
const collectClassStability = stability.collectClassStability;

const transform = @import("transform.zig");
const transformDecls = transform.transformDecls;
const transformComposableFunction = transform.transformComposableFunction;
const transformThreadedComposable = transform.transformThreadedComposable;

const walker = @import("walker.zig");
const Walker = walker.Walker;

const testing = std.testing;

fn allComposable(_: *anyopaque, _: []const u8) bool {
    return true;
}

test "a composable-lambda-sink argument is transformed to (…, composer, changed)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gsp = Span.init(span_mod.FileId.from(0), 0, 0);

    // Body: Column { Text("hi") }; Column is a lambda sink, Text is composable.
    var text_segs = [_]Ident{dummyIdent("Text")};
    var text_callee = Expr{ .Path = .{ .segments = &text_segs, .span = gsp } };
    var str_parts = [_]ast.StringPart{.{ .Text = "hi" }};
    var text_args = [_]Expr{.{ .StringTemplate = .{ .parts = &str_parts, .span = gsp } }};
    var text_names = [_]?[]const u8{null};
    var lam_body_stmts = [_]Stmt{.{ .Expr = .{ .Call = .{
        .callee = &text_callee,
        .args = &text_args,
        .arg_names = &text_names,
        .type_args = &.{},
        .is_infix = false,
        .has_trailing_lambda = false,
        .span = gsp,
    } } }};
    var lam_params: [0]Ident = .{};
    var lam_ptys: [0]?TypeRef = .{};
    var col_args = [_]Expr{.{ .Lambda = .{
        .params = &lam_params,
        .param_tys = &lam_ptys,
        .body = .{ .stmts = &lam_body_stmts, .span = gsp },
        .implicit_it = true,
        .span = gsp,
    } }};
    var col_segs = [_]Ident{dummyIdent("Column")};
    var col_callee = Expr{ .Path = .{ .segments = &col_segs, .span = gsp } };
    var col_names = [_]?[]const u8{null};
    var body_stmts = [_]Stmt{.{ .Expr = .{ .Call = .{
        .callee = &col_callee,
        .args = &col_args,
        .arg_names = &col_names,
        .type_args = &.{},
        .is_infix = false,
        .has_trailing_lambda = true,
        .span = gsp,
    } } }};
    var noparams: [0]Param = .{};
    const host = emptyFn("Host", &noparams, .{ .Block = .{ .stmts = &body_stmts, .span = gsp } }, true);

    var sinks = std.StringHashMap(void).init(a);
    try sinks.put("Column", {});
    var ctx: u8 = 0;
    const out = try transformComposableFunction(a, &host, allComposable, &ctx, &sinks, false, null, null);
    const col = wrappedBodyStmts(&out)[0].Expr.Call;
    // Column gains its own pair; the sink lambda is memoized by rememberComposableLambda.
    const memo = col.args[0].Call;
    const memo_path = memo.callee.Path;
    try testing.expectEqualStrings("rememberComposableLambda", memo_path.segments[memo_path.segments.len - 1].name);
    try testing.expectEqual(@as(usize, 5), memo.args.len);
    try testing.expectEqualStrings(composer_param, memo.args[3].Path.segments[0].name);
    const lam = memo.args[2].Labeled.expr.Lambda;
    // The sink lambda's synthetic `it` is REPLACED by ($composer, $changed), not appended.
    try testing.expectEqual(@as(usize, 2), lam.params.len);
    try testing.expectEqualStrings(composer_param, lam.params[0].name);
    try testing.expectEqualStrings(changed_param, lam.params[1].name);
    try testing.expect(!lam.implicit_it);
    // Bare declaration calls stay source-shaped for the IR resolver.
    const gate = lam.body.stmts[0].Expr.If;
    try testing.expectEqualStrings("shouldExecute", gate.cond.Call.callee.Member.name.name);
    const inner = gate.then_branch.Block.stmts[0].Expr.Call;
    try testing.expectEqual(@as(usize, 1), inner.args.len);
}

fn noneComposable(_: *anyopaque, _: []const u8) bool {
    return false;
}

/// The restart-wrapped body statements: the then-block of the skip `if`.
fn wrappedBodyStmts(out: *const Function) []const Stmt {
    const stmts = out.body.?.Block.stmts;
    return stmts[stmts.len - 2].Expr.If.then_branch.Block.stmts;
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

test "bodyless composable declarations keep their header and gain the threaded ABI" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var readonly_path = [_]Ident{dummyIdent("ReadOnlyComposable")};
    var annotations = [_]ast.Annotation{
        composableAnno[0],
        .{
            .use_site = null,
            .path = &readonly_path,
            .type_args = &.{},
            .args = &.{},
            .arg_names = &.{},
            .span = Span.init(span_mod.FileId.from(0), 0, 0),
        },
    };
    var f = emptyFn("readValue", &.{}, null, false);
    f.annotations = &annotations;
    f.is_expect = true;
    var decls = [_]Decl{.{ .Function = f }};

    var names = try collectComposableNames(a, &decls);
    defer names.deinit();
    var sinks = std.StringHashMap(void).init(a);
    defer sinks.deinit();
    try transformDecls(a, &decls, &names, &sinks);

    const out = decls[0].Function;
    try testing.expect(out.body == null);
    try testing.expect(out.is_expect);
    try testing.expectEqual(@as(usize, 2), out.params.len);
    try testing.expectEqualStrings(composer_param, out.params[0].name.name);
    try testing.expectEqualStrings(changed_param, out.params[1].name.name);
}

fn noComposable(_: *anyopaque, _: []const u8) bool {
    return false;
}

fn getterProp(name: []const u8, getter: ?*ast.Accessor, comp_on_decl: bool) ast.Property {
    return .{
        .mutable = false,
        .name = dummyIdent(name),
        .receiver_type = null,
        .ty = null,
        .init = null,
        .delegate = null,
        .getter = getter,
        .setter = null,
        .is_abstract = false,
        .is_open = false,
        .is_override = false,
        .is_lateinit = false,
        .is_const = false,
        .is_inline = false,
        .is_expect = false,
        .is_actual = false,
        .setter_visibility = null,
        .visibility = .Public,
        .annotations = if (comp_on_decl) &composableAnno else &.{},
        .span = Span.init(span_mod.FileId.from(0), 0, 0),
    };
}

test "a @Composable getter property is collected and detected as composable content" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gsp = Span.init(span_mod.FileId.from(0), 0, 0);

    // `val currentRecomposeScope: … @Composable get() { … }`
    var comp_getter = ast.Accessor{
        .params = &.{},
        .return_type = null,
        .body = .{ .Block = .{ .stmts = &.{}, .span = gsp } },
        .visibility = null,
        .is_inline = false,
        .annotations = &composableAnno,
        .span = gsp,
    };
    var plain_getter = ast.Accessor{
        .params = &.{},
        .return_type = null,
        .body = .{ .Block = .{ .stmts = &.{}, .span = gsp } },
        .visibility = null,
        .is_inline = false,
        .annotations = &.{},
        .span = gsp,
    };
    var crs = getterProp("currentRecomposeScope", &comp_getter, false);
    var plain = getterProp("ordinaryProp", &plain_getter, false);
    var decls = [_]ast.Decl{ .{ .Property = &crs }, .{ .Property = &plain } };

    var set = try collectComposableGetterProps(a, &decls);
    defer set.deinit();
    try testing.expect(set.contains("currentRecomposeScope"));
    try testing.expect(!set.contains("ordinaryProp"));

    root.active_composable_getter_props = &set;
    defer root.active_composable_getter_props = null;

    // `record` is not composable, so the getter property read is the only signal.
    var crs_ref = [_]Ident{dummyIdent("currentRecomposeScope")};
    var rec_callee_segs = [_]Ident{dummyIdent("record")};
    var rec_callee = Expr{ .Path = .{ .segments = &rec_callee_segs, .span = gsp } };
    var rec_args = [_]Expr{.{ .Path = .{ .segments = &crs_ref, .span = gsp } }};
    var rec_names = [_]?[]const u8{null};
    var lam_stmts = [_]Stmt{.{ .Expr = .{ .Call = .{
        .callee = &rec_callee,
        .args = &rec_args,
        .arg_names = &rec_names,
        .type_args = &.{},
        .is_infix = false,
        .has_trailing_lambda = false,
        .span = gsp,
    } } }};
    const lam = Expr{ .Lambda = .{
        .params = &.{},
        .body = .{ .stmts = &lam_stmts, .span = gsp },
        .implicit_it = false,
        .span = gsp,
    } };

    var ctx: u8 = 0;
    var w = Walker{ .a = a, .b = .{ .a = a, .gen_span = gsp }, .oracle = noComposable, .oracle_ctx = &ctx };
    try testing.expect(w.branchHasComposable(&lam));

    root.active_composable_getter_props = null;
    try testing.expect(!w.branchHasComposable(&lam));
}

test "walker replaces currentComposer with the threaded composer inside a nested call" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gsp = Span.init(span_mod.FileId.from(0), 0, 0);

    // @Composable fun Host() { Emit(currentComposer) }
    var cc_segs = [_]Ident{dummyIdent("currentComposer")};
    var emit_segs = [_]Ident{dummyIdent("Emit")};
    var emit_callee = Expr{ .Path = .{ .segments = &emit_segs, .span = gsp } };
    var emit_args = [_]Expr{.{ .Path = .{ .segments = &cc_segs, .span = gsp } }};
    var emit_names = [_]?[]const u8{null};
    var body_stmts = [_]Stmt{.{ .Expr = .{ .Call = .{
        .callee = &emit_callee,
        .args = &emit_args,
        .arg_names = &emit_names,
        .type_args = &.{},
        .is_infix = false,
        .has_trailing_lambda = false,
        .span = gsp,
    } } }};
    var noparams: [0]Param = .{};
    const host = emptyFn("Host", &noparams, .{ .Block = .{ .stmts = &body_stmts, .span = gsp } }, true);

    var ctx: u8 = 0;
    const out = try transformComposableFunction(a, &host, allComposable, &ctx, null, false, null, null);
    const emit = wrappedBodyStmts(&out)[0].Expr.Call;
    // The bare call stays source-shaped; `currentComposer` becomes the threaded `$composer`.
    try testing.expectEqual(@as(usize, 1), emit.args.len);
    try testing.expectEqualStrings(composer_param, emit.args[0].Path.segments[0].name);
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
    const out = try transformComposableFunction(a, &app, allComposable, &ctx, null, false, null, null);

    try testing.expectEqual(@as(usize, 3), out.params.len);
    try testing.expectEqualStrings("x", out.params[0].name.name);
    try testing.expectEqualStrings(composer_param, out.params[1].name.name);
    try testing.expectEqualStrings("Composer", out.params[1].ty.name.name);
    try testing.expectEqualStrings(changed_param, out.params[2].name.name);

    const stmts = out.body.?.Block.stmts;
    // startRestartGroup + $dirty decl + probe(x) + skip-if + endRestartGroup.
    try testing.expectEqual(@as(usize, 5), stmts.len);
    try testing.expectEqualStrings("startRestartGroup", stmts[0].Expr.Call.callee.Member.name.name);
    try testing.expectEqualStrings(composer_param, stmts[0].Expr.Call.callee.Member.receiver.Path.segments[0].name);
    // Skip calculus: `var $dirty = $changed and 1`, then one probe per param.
    try testing.expectEqualStrings(dirty_local, stmts[1].Decl.Property.name.name);
    try testing.expect(stmts[1].Decl.Property.mutable);
    // The probe is guarded by `if ($changed and 0b110 == 0)`.
    const probe_guard = stmts[2].Expr.If;
    try testing.expect(probe_guard.cond.Binary.op == .Eq);
    const probe = probe_guard.then_branch.Block.stmts[0].Assign.value.Call;
    try testing.expectEqualStrings("or", probe.callee.Member.name.name);
    try testing.expectEqualStrings("changed", probe.args[0].If.cond.Call.callee.Member.name.name);
    try testing.expectEqualStrings("x", probe.args[0].If.cond.Call.args[0].Path.segments[0].name);
    const skip_if = stmts[3].Expr.If;
    try testing.expectEqualStrings(
        "skipToGroupEnd",
        skip_if.else_branch.?.Block.stmts[0].Expr.Call.callee.Member.name.name,
    );
    const text_call = wrappedBodyStmts(&out)[0].Expr.Call;
    try testing.expectEqual(@as(usize, 1), text_call.args.len);
    const upd = stmts[4].Expr.Call;
    try testing.expect(upd.callee.Member.safe);
    try testing.expectEqualStrings("updateScope", upd.callee.Member.name.name);
    try testing.expectEqualStrings("endRestartGroup", upd.callee.Member.receiver.Call.callee.Member.name.name);
}

test "defaulted composable param becomes marker-guarded prologue" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // @Composable fun App(x: Int = 5) { }
    const gsp = Span.init(span_mod.FileId.from(0), 0, 0);
    var five = Expr{ .IntLit = .{ .value = 5, .kind = .Int, .span = gsp } };
    var app_params = [_]Param{.{
        .name = dummyIdent("x"),
        .ty = .{ .name = dummyIdent("Int"), .nullable = false, .span = gsp, .type_args = &.{}, .function = null, .definitely_non_null = false, .annotations = &.{}, .qualified_path = null },
        .default = &five,
        .is_vararg = false,
        .is_crossinline = false,
        .is_noinline = false,
        .annotations = &.{},
        .span = gsp,
    }};
    var body_stmts = [_]Stmt{};
    const app = emptyFn("App", &app_params, .{ .Block = .{ .stmts = &body_stmts, .span = gsp } }, true);

    var ctx: u8 = 0;
    const out = try transformComposableFunction(a, &app, allComposable, &ctx, null, false, null, null);

    try testing.expectEqualStrings("x$arg", out.params[0].name.name);
    const marker = out.params[0].default.?.Call;
    const seg = marker.callee.Path.segments;
    try testing.expectEqualStrings("klioComposableDefaultMarker", seg[seg.len - 1].name);

    // Body: startRestartGroup, `val x = if (x$arg === marker()) 5 else x$arg`, $dirty,
    // probe(x), skip-if, endRestartGroup?.updateScope.
    const stmts = out.body.?.Block.stmts;
    try testing.expectEqual(@as(usize, 6), stmts.len);
    const prop = stmts[1].Decl.Property;
    try testing.expectEqualStrings("x", prop.name.name);
    try testing.expectEqualStrings("Int", prop.ty.?.name.name);
    const pick = prop.init.?.If;
    try testing.expect(pick.cond.Binary.op == .IdentEq);
    try testing.expectEqualStrings("x$arg", pick.cond.Binary.lhs.Path.segments[0].name);
    try testing.expectEqual(@as(i64, 5), pick.then_branch.IntLit.value);
    try testing.expectEqualStrings("x$arg", pick.else_branch.?.Path.segments[0].name);

    // A defaulted param's probe is also guarded by `if (x$arg !== marker())`.
    const cguard = stmts[3].Expr.If;
    try testing.expect(cguard.cond.Binary.op == .Eq);
    const guard = cguard.then_branch.Block.stmts[0].Expr.If;
    try testing.expect(guard.cond.Binary.op == .IdentNeq);
    try testing.expectEqualStrings("x$arg", guard.cond.Binary.lhs.Path.segments[0].name);
    const probe = guard.then_branch.Block.stmts[0];
    // The probe reads the RESOLVED value `x`, not the renamed argument.
    try testing.expectEqualStrings("x", probe.Assign.value.Call.args[0].If.cond.Call.args[0].Path.segments[0].name);
    // The restart re-call passes the RENAMED param (marker flows through).
    const upd = stmts[5].Expr.Call;
    const lam = upd.args[0].Lambda;
    const reinvoke = lam.body.stmts[0].Expr.Call;
    try testing.expectEqualStrings("x$arg", reinvoke.args[0].Path.segments[0].name);
}

test "threadCall appends the composer pair as named args" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const gsp = Span.init(span_mod.FileId.from(0), 0, 0);
    var text_segs = [_]Ident{dummyIdent("Text")};
    var text_callee = Expr{ .Path = .{ .segments = &text_segs, .span = gsp } };
    var text_argnames = [_]?[]const u8{};
    var call = Expr{ .Call = .{
        .callee = &text_callee,
        .args = &.{},
        .arg_names = &text_argnames,
        .type_args = &.{},
        .is_infix = false,
        .has_trailing_lambda = false,
        .span = gsp,
    } };
    var ctx: u8 = 0;
    var w = Walker{ .a = a, .b = .{ .a = a, .gen_span = gsp }, .oracle = allComposable, .oracle_ctx = &ctx };
    try w.threadCall(&call.Call, false);
    const c = call.Call;
    try testing.expectEqual(@as(usize, 2), c.args.len);
    try testing.expectEqualStrings(composer_param, c.arg_names[0].?);
    try testing.expectEqualStrings(changed_param, c.arg_names[1].?);
}

test "a conditional initializer propagates its composable function type to lambda branches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gsp = Span.init(span_mod.FileId.from(0), 0, 0);
    const b = B{ .a = a, .gen_span = gsp };

    var lambda_params: [0]Ident = .{};
    var lambda_param_tys: [0]?TypeRef = .{};
    var body_stmts = [_]Stmt{.{ .Expr = b.call(
        b.pathExpr("ReusableContentHost"),
        a.alloc(Expr, 0) catch @panic("oom"),
    ) }};
    const lambda = Expr{ .Lambda = .{
        .params = &lambda_params,
        .param_tys = &lambda_param_tys,
        .body = .{ .stmts = &body_stmts, .span = gsp },
        .implicit_it = true,
        .span = gsp,
    } };
    var value = Expr{ .If = .{
        .cond = b.box(.{ .BoolLit = .{ .value = true, .span = gsp } }),
        .then_branch = b.box(b.pathExpr("content")),
        .else_branch = b.box(lambda),
        .span = gsp,
    } };

    var ctx: u8 = 0;
    var w = Walker{
        .a = a,
        .b = b,
        .oracle = allComposable,
        .oracle_ctx = &ctx,
        .thread = false,
    };
    try w.walkComposableValueExpr(&value, 0);

    const transformed = value.If.else_branch.?.Lambda;
    try testing.expectEqual(@as(usize, 2), transformed.params.len);
    try testing.expectEqualStrings(composer_param, transformed.params[0].name);
    try testing.expectEqualStrings(changed_param, transformed.params[1].name);
    const call = transformed.body.stmts[0].Expr.Call;
    try testing.expectEqual(@as(usize, 0), call.args.len);
}

test "remember propagates a composable result type into its calculation result" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gsp = Span.init(span_mod.FileId.from(0), 0, 0);
    const b = B{ .a = a, .gen_span = gsp };

    var content_params: [0]Ident = .{};
    var content_param_tys: [0]?TypeRef = .{};
    var content_stmts = [_]Stmt{.{ .Expr = b.call(
        b.pathExpr("Box"),
        a.alloc(Expr, 0) catch @panic("oom"),
    ) }};
    const content = Expr{ .Lambda = .{
        .params = &content_params,
        .param_tys = &content_param_tys,
        .body = .{ .stmts = &content_stmts, .span = gsp },
        .implicit_it = true,
        .span = gsp,
    } };

    var calculation_params: [0]Ident = .{};
    var calculation_param_tys: [0]?TypeRef = .{};
    var calculation_stmts = [_]Stmt{.{ .Expr = content }};
    const calculation = Expr{ .Lambda = .{
        .params = &calculation_params,
        .param_tys = &calculation_param_tys,
        .body = .{ .stmts = &calculation_stmts, .span = gsp },
        .implicit_it = true,
        .span = gsp,
    } };
    const remember_args = try a.alloc(Expr, 1);
    remember_args[0] = calculation;
    var value = b.call(b.pathExprSegs(&.{ "androidx", "compose", "runtime", "remember" }), remember_args);
    value.Call.has_trailing_lambda = true;

    var ctx: u8 = 0;
    var w = Walker{
        .a = a,
        .b = b,
        .oracle = allComposable,
        .oracle_ctx = &ctx,
        .thread = true,
    };
    try w.walkComposableValueExpr(&value, 0);

    const transformed = value.Call.args[0].Lambda.body.stmts[0].Expr.Lambda;
    try testing.expectEqual(@as(usize, 2), transformed.params.len);
    try testing.expectEqualStrings(composer_param, transformed.params[0].name);
    try testing.expectEqualStrings(changed_param, transformed.params[1].name);
    const box_call = transformed.body.stmts[0].Expr.Call;
    try testing.expectEqual(@as(usize, 0), box_call.args.len);
    try testing.expectEqual(@as(usize, 1), value.Call.args.len);
}

test "threadCall re-names a trailing lambda across a defaulted gap" {
    // Threading appends the composer pair and clears `has_trailing_lambda`, so the lambda
    // is re-emitted by name to rejoin `content` rather than the defaulted `insertGroup`.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gsp = Span.init(span_mod.FileId.from(0), 0, 0);

    var callee_segs = [_]Ident{dummyIdent("ExplicitStartReplaceGroup")};
    var callee = Expr{ .Path = .{ .segments = &callee_segs, .span = gsp } };
    var lam_params: [0]Ident = .{};
    var lam_ptys: [0]?TypeRef = .{};
    var args = [_]Expr{
        .{ .IntLit = .{ .value = 42, .kind = .Int, .span = gsp } },
        .{ .Lambda = .{
            .params = &lam_params,
            .param_tys = &lam_ptys,
            .body = .{ .stmts = &.{}, .span = gsp },
            .implicit_it = false,
            .span = gsp,
        } },
    };
    var arg_names = [_]?[]const u8{ null, null };
    var call = Expr{ .Call = .{
        .callee = &callee,
        .args = &args,
        .arg_names = &arg_names,
        .type_args = &.{},
        .is_infix = false,
        .has_trailing_lambda = true,
        .span = gsp,
    } };
    var ctx: u8 = 0;
    var w = Walker{ .a = a, .b = .{ .a = a, .gen_span = gsp }, .oracle = allComposable, .oracle_ctx = &ctx };
    try w.threadCall(&call.Call, false);
    const c = call.Call;
    try testing.expectEqual(@as(usize, 4), c.args.len);
    try testing.expect(c.arg_names[0] == null); // key stays positional
    // The trailing argument stays POSITIONAL for the runtime binders.
    try testing.expect(c.arg_names[1] == null);
    try testing.expectEqualStrings(composer_param, c.arg_names[2].?);
    try testing.expectEqualStrings(changed_param, c.arg_names[3].?);
    try testing.expect(!c.has_trailing_lambda);
}

test "threadCall leaves a non-content overload's trailing lambda positional" {
    // This 2-arg call binds the `(factory, update)` overload whose trailing lambda IS
    // `update`, already at its slot, so naming it `content=` would misbind.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gsp = Span.init(span_mod.FileId.from(0), 0, 0);

    var callee_segs = [_]Ident{dummyIdent("ComposeNode")};
    var callee = Expr{ .Path = .{ .segments = &callee_segs, .span = gsp } };
    var lam_params: [0]Ident = .{};
    var lam_ptys: [0]?TypeRef = .{};
    var args = [_]Expr{
        .{ .IntLit = .{ .value = 7, .kind = .Int, .span = gsp } },
        .{ .Lambda = .{
            .params = &lam_params,
            .param_tys = &lam_ptys,
            .body = .{ .stmts = &.{}, .span = gsp },
            .implicit_it = false,
            .span = gsp,
        } },
    };
    var arg_names = [_]?[]const u8{ null, null };
    var call = Expr{ .Call = .{
        .callee = &callee,
        .args = &args,
        .arg_names = &arg_names,
        .type_args = &.{},
        .is_infix = false,
        .has_trailing_lambda = true,
        .span = gsp,
    } };
    var ctx: u8 = 0;
    var w = Walker{ .a = a, .b = .{ .a = a, .gen_span = gsp }, .oracle = allComposable, .oracle_ctx = &ctx };
    try w.threadCall(&call.Call, false);
    const c = call.Call;
    try testing.expectEqual(@as(usize, 4), c.args.len);
    try testing.expect(c.arg_names[0] == null); // factory stays positional
    try testing.expect(c.arg_names[1] == null); // update lambda stays positional (NOT `content`)
    try testing.expectEqualStrings(composer_param, c.arg_names[2].?);
    try testing.expectEqualStrings(changed_param, c.arg_names[3].?);
    try testing.expect(!c.has_trailing_lambda);
}


test "a sink lambda is shaped with the bare pair; slots come from resolution" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gsp = Span.init(span_mod.FileId.from(0), 0, 0);

    // Bar(title = { }): the pass appends only the composer pair, no synthetic `it`.
    var segs = [_]Ident{dummyIdent("Bar")};
    var callee = Expr{ .Path = .{ .segments = &segs, .span = gsp } };
    var args = [_]Expr{.{ .Lambda = .{
        .params = &.{},
        .param_tys = &.{},
        .body = .{ .stmts = &.{}, .span = gsp },
        .implicit_it = true,
        .span = gsp,
    } }};
    var arg_names = [_]?[]const u8{"title"};
    var call = Expr{ .Call = .{
        .callee = &callee,
        .args = &args,
        .arg_names = &arg_names,
        .type_args = &.{},
        .is_infix = false,
        .has_trailing_lambda = false,
        .span = gsp,
    } };
    var sinks = std.StringHashMap(void).init(a);
    defer sinks.deinit();
    try sinks.put("Bar", {});
    var ctx: u8 = 0;
    var w = Walker{ .a = a, .b = .{ .a = a, .gen_span = gsp }, .oracle = allComposable, .oracle_ctx = &ctx, .sinks = &sinks, .thread = true };
    try w.walkExpr(&call);
    const wrapped = call.Call.args[0].Call;
    const lam = wrapped.args[2].Labeled.expr.Lambda;
    try testing.expectEqual(@as(usize, 2), lam.params.len);
    try testing.expectEqualStrings(composer_param, lam.params[0].name);
    try testing.expectEqualStrings(changed_param, lam.params[1].name);
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
    const out = try transformComposableFunction(a, &fnp, noneComposable, &ctx, null, false, null, null);
    try testing.expectEqual(@as(usize, 0), wrappedBodyStmts(&out)[0].Expr.Call.args.len);
}

test "movableContentWithReceiverOf type args pick the headerless lambda's overload arity" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gsp = Span.init(span_mod.FileId.from(0), 0, 0);
    // mcwro<Int>() { … }: one type arg means receiver only, so the block gains exactly
    // ($composer, $changed) and no `it`.
    var lam_params: [0]Ident = .{};
    var lam_ptys: [0]?TypeRef = .{};
    var call_args = [_]Expr{.{ .Lambda = .{
        .params = &lam_params,
        .param_tys = &lam_ptys,
        .body = .{ .stmts = &.{}, .span = gsp },
        .implicit_it = true,
        .span = gsp,
    } }};
    var segs = [_]Ident{dummyIdent("movableContentWithReceiverOf")};
    var callee = Expr{ .Path = .{ .segments = &segs, .span = gsp } };
    var names = [_]?[]const u8{null};
    var tas = [_]TypeRef{.{
        .name = dummyIdent("Int"),
        .nullable = false,
        .span = gsp,
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    }};
    var body_stmts = [_]Stmt{.{ .Expr = .{ .Call = .{
        .callee = &callee,
        .args = &call_args,
        .arg_names = &names,
        .type_args = &tas,
        .is_infix = false,
        .has_trailing_lambda = true,
        .span = gsp,
    } } }};
    var noparams: [0]Param = .{};
    const host = emptyFn("Host", &noparams, .{ .Block = .{ .stmts = &body_stmts, .span = gsp } }, true);
    var sinks = std.StringHashMap(void).init(a);
    try sinks.put("movableContentWithReceiverOf", {});
    var ctx: u8 = 0;
    const out = try transformComposableFunction(a, &host, noneComposable, &ctx, &sinks, false, null, null);
    const call = wrappedBodyStmts(&out)[0].Expr.Call;
    const wrapped = call.args[call.args.len - 1].Call;
    const lam = wrapped.args[2].Labeled.expr.Lambda;
    try testing.expectEqual(@as(usize, 2), lam.params.len);
    try testing.expectEqualStrings(composer_param, lam.params[0].name);
    try testing.expectEqualStrings(changed_param, lam.params[1].name);
}

fn testTypeRef(name: []const u8) TypeRef {
    return .{
        .name = dummyIdent(name),
        .nullable = false,
        .span = Span.init(span_mod.FileId.from(0), 0, 0),
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
}

fn testClassParam(name: []const u8, ty_name: []const u8, mutable_prop: ?bool) ast.ClassParam {
    return .{
        .property = mutable_prop,
        .name = dummyIdent(name),
        .ty = testTypeRef(ty_name),
        .default = null,
        .visibility = .Public,
        .is_vararg = false,
        .annotations = &.{},
        .span = Span.init(span_mod.FileId.from(0), 0, 0),
    };
}

fn testClass(name: []const u8, primary_params: []ast.ClassParam) ast.Class {
    return .{
        .name = dummyIdent(name),
        .type_params = &.{},
        .where_bounds = &.{},
        .primary_params = primary_params,
        .init_blocks = &.{},
        .init_block_positions = &.{},
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
        .secondary_ctors = &.{},
        .is_interface = false,
        .is_fun_interface = false,
        .is_value = false,
        .is_annotation = false,
        .is_expect = false,
        .is_actual = false,
        .enum_entries = &.{},
        .members = &.{},
        .visibility = .Public,
        .primary_ctor_visibility = null,
        .annotations = &.{},
        .span = Span.init(span_mod.FileId.from(0), 0, 0),
    };
}

test "stability: a var-bearing class is unstable, a val-only class is stable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // class Model(var contacts: String); class Point(val x: Int, val y: Int)
    var model_params = [_]ast.ClassParam{testClassParam("contacts", "String", true)};
    var point_params = [_]ast.ClassParam{
        testClassParam("x", "Int", false),
        testClassParam("y", "Int", false),
    };
    var decls = [_]Decl{
        .{ .Class = testClass("Model", &model_params) },
        .{ .Class = testClass("Point", &point_params) },
    };
    var map = try collectClassStability(a, &decls, &.{});
    defer map.deinit();
    try testing.expectEqual(Stability.unstable, map.get("Model").?);
    try testing.expectEqual(Stability.stable, map.get("Point").?);
}

test "stability: an unstable param drops the skip calculus, a stable one keeps it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gsp = Span.init(span_mod.FileId.from(0), 0, 0);

    var model_params = [_]ast.ClassParam{testClassParam("contacts", "String", true)};
    var decls = [_]Decl{.{ .Class = testClass("Model", &model_params) }};
    var map = try collectClassStability(a, &decls, &.{});
    defer map.deinit();
    root.active_stability = &map;
    defer root.active_stability = null;

    var body_stmts = [_]Stmt{};
    var ctx: u8 = 0;

    // Under strong skipping an unstable param probes by identity (changedInstance).
    var unstable_params = [_]Param{.{
        .name = dummyIdent("m"),
        .ty = testTypeRef("Model"),
        .default = null,
        .is_vararg = false,
        .is_crossinline = false,
        .is_noinline = false,
        .annotations = &.{},
        .span = gsp,
    }};
    const show = emptyFn("Show", &unstable_params, .{ .Block = .{ .stmts = &body_stmts, .span = gsp } }, true);
    const out = try transformComposableFunction(a, &show, allComposable, &ctx, null, false, null, null);
    const stmts = out.body.?.Block.stmts;
    // startRestartGroup + $dirty + changedInstance probe + skip-if + endRestartGroup.
    try testing.expectEqual(@as(usize, 5), stmts.len);
    try testing.expectEqualStrings(dirty_local, stmts[1].Decl.Property.name.name);
    const probe_call = stmts[2].Expr.If.then_branch.Block.stmts[0].Assign.value.Call.args[0].If.cond.Call;
    try testing.expectEqualStrings("changedInstance", probe_call.callee.Member.name.name);
    try testing.expectEqualStrings("updateScope", stmts[4].Expr.Call.callee.Member.name.name);

    // @Composable fun ShowInt(x: Int) keeps the probe and $dirty calculus.
    var stable_params = [_]Param{.{
        .name = dummyIdent("x"),
        .ty = testTypeRef("Int"),
        .default = null,
        .is_vararg = false,
        .is_crossinline = false,
        .is_noinline = false,
        .annotations = &.{},
        .span = gsp,
    }};
    var body_stmts2 = [_]Stmt{};
    const show_int = emptyFn("ShowInt", &stable_params, .{ .Block = .{ .stmts = &body_stmts2, .span = gsp } }, true);
    const out2 = try transformComposableFunction(a, &show_int, allComposable, &ctx, null, false, null, null);
    const stmts2 = out2.body.?.Block.stmts;
    try testing.expectEqual(@as(usize, 5), stmts2.len);
    try testing.expectEqualStrings(dirty_local, stmts2[1].Decl.Property.name.name);
}

test "key(k) { } gains a movable-group bracket with the dynamic key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gsp = Span.init(span_mod.FileId.from(0), 40, 60);

    // @Composable fun Host() { key(k) { Text("hi") } }
    var text_segs = [_]Ident{dummyIdent("Text")};
    var text_callee = Expr{ .Path = .{ .segments = &text_segs, .span = gsp } };
    var str_parts = [_]ast.StringPart{.{ .Text = "hi" }};
    var text_args = [_]Expr{.{ .StringTemplate = .{ .parts = &str_parts, .span = gsp } }};
    var text_names = [_]?[]const u8{null};
    var lam_body_stmts = [_]Stmt{.{ .Expr = .{ .Call = .{
        .callee = &text_callee,
        .args = &text_args,
        .arg_names = &text_names,
        .type_args = &.{},
        .is_infix = false,
        .has_trailing_lambda = false,
        .span = gsp,
    } } }};
    var lam_params: [0]Ident = .{};
    var lam_ptys: [0]?TypeRef = .{};
    var k_segs = [_]Ident{dummyIdent("k")};
    var key_args = [_]Expr{
        .{ .Path = .{ .segments = &k_segs, .span = gsp } },
        .{ .Lambda = .{
            .params = &lam_params,
            .param_tys = &lam_ptys,
            .body = .{ .stmts = &lam_body_stmts, .span = gsp },
            .implicit_it = true,
            .span = gsp,
        } },
    };
    var key_segs = [_]Ident{dummyIdent("key")};
    var key_callee = Expr{ .Path = .{ .segments = &key_segs, .span = gsp } };
    var key_names = [_]?[]const u8{ null, null };
    var body_stmts = [_]Stmt{.{ .Expr = .{ .Call = .{
        .callee = &key_callee,
        .args = &key_args,
        .arg_names = &key_names,
        .type_args = &.{},
        .is_infix = false,
        .has_trailing_lambda = true,
        .span = gsp,
    } } }};
    var noparams: [0]Param = .{};
    const host = emptyFn("Host", &noparams, .{ .Block = .{ .stmts = &body_stmts, .span = gsp } }, true);
    var sinks = std.StringHashMap(void).init(a);
    try sinks.put("key", {});
    var ctx: u8 = 0;
    const out = try transformComposableFunction(a, &host, allComposable, &ctx, &sinks, false, null, null);
    // The key call became { startMovableGroup(site, k); val $key$v = key(...);
    // endMovableGroup(); $key$v }.
    const blk = wrappedBodyStmts(&out)[0].Expr.Block;
    try testing.expectEqual(@as(usize, 4), blk.stmts.len);
    const start = blk.stmts[0].Expr.Call;
    try testing.expectEqualStrings("startMovableGroup", start.callee.Member.name.name);
    try testing.expectEqual(@as(usize, 2), start.args.len);
    try testing.expectEqualStrings("k", start.args[1].Path.segments[0].name);
    const kcall = blk.stmts[1].Decl.Property.init.?.Call;
    try testing.expectEqualStrings("key", kcall.callee.Path.segments[0].name);
    try testing.expectEqual(@as(usize, 2), kcall.args.len);
    try testing.expectEqualStrings("endMovableGroup", blk.stmts[2].Expr.Call.callee.Member.name.name);
    try testing.expectEqualStrings("$key$v", blk.stmts[3].Expr.Path.segments[0].name);
}

test "a non-local return through a sink lambda closes groups via endToMarker" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gsp = Span.init(span_mod.FileId.from(0), 0, 0);

    // The inner `return@outer` is non-local, so it closes the inner group before unwinding.
    const ret = try a.create(Expr);
    ret.* = .{ .Return = .{ .value = null, .label = dummyIdent("outer"), .span = gsp } };
    const inner_body = try a.alloc(Stmt, 1);
    inner_body[0] = .{ .Expr = ret.* };
    var noparams_l: [0]Ident = .{};
    var noptys_l: [0]?TypeRef = .{};
    const inner_lam = try a.create(Expr);
    inner_lam.* = .{ .Lambda = .{
        .params = &noparams_l,
        .param_tys = &noptys_l,
        .body = .{ .stmts = inner_body, .span = gsp },
        .implicit_it = true,
        .span = gsp,
    } };
    const il_segs = try a.alloc(Ident, 1);
    il_segs[0] = dummyIdent("InlineLinear");
    const inner_callee = try a.create(Expr);
    inner_callee.* = .{ .Path = .{ .segments = il_segs, .span = gsp } };
    const inner_args = try a.alloc(Expr, 1);
    inner_args[0] = inner_lam.*;
    const inner_names = try a.alloc(?[]const u8, 1);
    inner_names[0] = null;
    const inner_call = try a.create(Expr);
    inner_call.* = .{ .Call = .{
        .callee = inner_callee,
        .args = inner_args,
        .arg_names = inner_names,
        .type_args = &.{},
        .is_infix = false,
        .has_trailing_lambda = true,
        .span = gsp,
    } };

    const outer_body = try a.alloc(Stmt, 1);
    outer_body[0] = .{ .Expr = inner_call.* };
    const outer_lam = try a.create(Expr);
    outer_lam.* = .{ .Lambda = .{
        .params = &noparams_l,
        .param_tys = &noptys_l,
        .body = .{ .stmts = outer_body, .span = gsp },
        .implicit_it = true,
        .span = gsp,
    } };
    const outer_labeled = try a.create(Expr);
    outer_labeled.* = .{ .Labeled = .{ .label = dummyIdent("outer"), .expr = outer_lam, .span = gsp } };
    const ol_segs = try a.alloc(Ident, 1);
    ol_segs[0] = dummyIdent("InlineLinear");
    const outer_callee = try a.create(Expr);
    outer_callee.* = .{ .Path = .{ .segments = ol_segs, .span = gsp } };
    const outer_args = try a.alloc(Expr, 1);
    outer_args[0] = outer_labeled.*;
    const outer_names = try a.alloc(?[]const u8, 1);
    outer_names[0] = null;
    var body_stmts = [_]Stmt{.{ .Expr = .{ .Call = .{
        .callee = outer_callee,
        .args = outer_args,
        .arg_names = outer_names,
        .type_args = &.{},
        .is_infix = false,
        .has_trailing_lambda = true,
        .span = gsp,
    } } }};
    var noparams: [0]Param = .{};
    const host = emptyFn("Host", &noparams, .{ .Block = .{ .stmts = &body_stmts, .span = gsp } }, true);

    var sinks = std.StringHashMap(void).init(a);
    try sinks.put("InlineLinear", {});
    // `InlineLinear` inlines, so its lambda is spliced, never wrapped, and stays raw.
    var inline_fns = std.StringHashMap(void).init(a);
    try inline_fns.put("InlineLinear", {});
    root.active_inline_fns = &inline_fns;
    defer root.active_inline_fns = null;
    var ctx: u8 = 0;
    const out = try transformComposableFunction(a, &host, allComposable, &ctx, &sinks, false, null, null);

    const ocall = wrappedBodyStmts(&out)[0].Expr.Call;
    const olam = ocall.args[0].Labeled.expr.Lambda;
    try testing.expectEqual(@as(usize, 2), olam.params.len);
    try testing.expectEqualStrings(composer_param, olam.params[0].name);
    // The outer lambda body gains a leading `val <marker> = $composer.currentMarker`.
    try testing.expect(olam.body.stmts[0] == .Decl);
    const marker_prop = olam.body.stmts[0].Decl.Property;
    try testing.expect(!marker_prop.mutable);
    try testing.expect(marker_prop.init.? == .Member);
    try testing.expectEqualStrings("currentMarker", marker_prop.init.?.Member.name.name);
    const marker_name = marker_prop.name.name;
    // The inner sink lambda's `return@outer` became `{ endToMarker(m); return }`.
    const inner_lam_out = olam.body.stmts[1].Expr.Call.args[0].Lambda;
    const wrapped = inner_lam_out.body.stmts[0].Expr;
    try testing.expect(wrapped == .Block);
    const cleanup = wrapped.Block.stmts[0].Expr.Call;
    try testing.expectEqualStrings("endToMarker", cleanup.callee.Member.name.name);
    try testing.expectEqualStrings(marker_name, cleanup.args[0].Path.segments[0].name);
    try testing.expect(wrapped.Block.stmts[1].Expr == .Return);
}

var explicitGroupsAnno = [_]ast.Annotation{
    .{
        .use_site = null,
        .path = &composablePath,
        .type_args = &.{},
        .args = &.{},
        .arg_names = &.{},
        .span = Span.init(span_mod.FileId.from(0), 0, 0),
    },
    .{
        .use_site = null,
        .path = &explicitGroupsPath,
        .type_args = &.{},
        .args = &.{},
        .arg_names = &.{},
        .span = Span.init(span_mod.FileId.from(0), 0, 0),
    },
};
var explicitGroupsPath = [_]Ident{dummyIdent("ExplicitGroupsComposable")};

// A statement-position `if` in an @ExplicitGroupsComposable body must NOT gain the
// per-branch replace-group: one there makes `ReusableContentHost` mis-key its groups.
test "an @ExplicitGroupsComposable body skips per-branch replace-groups" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gsp = Span.init(span_mod.FileId.from(0), 40, 60);

    // `buildBody` re-runs per fixture so the two transforms share no mutated AST.
    const S = struct {
        fn buildBody(al: std.mem.Allocator, sp: Span) ![]Stmt {
            const foo_segs = try al.alloc(Ident, 1);
            foo_segs[0] = dummyIdent("Foo");
            const foo_callee = try al.create(Expr);
            foo_callee.* = .{ .Path = .{ .segments = foo_segs, .span = sp } };
            const foo_call = try al.create(Expr);
            foo_call.* = .{ .Call = .{
                .callee = foo_callee,
                .args = &.{},
                .arg_names = &.{},
                .type_args = &.{},
                .is_infix = false,
                .has_trailing_lambda = false,
                .span = sp,
            } };
            const then_stmts = try al.alloc(Stmt, 1);
            then_stmts[0] = .{ .Expr = foo_call.* };
            const then_branch = try al.create(Expr);
            then_branch.* = .{ .Block = .{ .stmts = then_stmts, .span = sp } };
            const cond = try al.create(Expr);
            cond.* = .{ .BoolLit = .{ .value = true, .span = sp } };
            const if_expr = Expr{ .If = .{
                .cond = cond,
                .then_branch = then_branch,
                .else_branch = null,
                .span = sp,
            } };
            const body = try al.alloc(Stmt, 1);
            body[0] = .{ .Expr = if_expr };
            return body;
        }
    };

    var ctx: u8 = 0;

    const eg_body = try S.buildBody(a, gsp);
    var eg = emptyFn("EgHost", &.{}, .{ .Block = .{ .stmts = eg_body, .span = gsp } }, true);
    eg.is_inline = true;
    eg.annotations = &explicitGroupsAnno;
    const eg_out = try transformThreadedComposable(a, &eg, allComposable, &ctx, null, null);
    const eg_if = eg_out.body.?.Block.stmts[0].Expr.If;
    const eg_then = eg_if.then_branch.Block.stmts;
    try testing.expect(!isComposerCallStmt(&eg_then[0], "startReplaceGroup"));
    try testing.expectEqualStrings("Foo", eg_then[0].Expr.Call.callee.Path.segments[0].name);
    try testing.expect(eg_if.else_branch == null);

    const plain_body = try S.buildBody(a, gsp);
    var plain = emptyFn("PlainHost", &.{}, .{ .Block = .{ .stmts = plain_body, .span = gsp } }, true);
    plain.is_inline = true;
    const plain_out = try transformThreadedComposable(a, &plain, allComposable, &ctx, null, null);
    const plain_if = plain_out.body.?.Block.stmts[0].Expr.If;
    const plain_then = plain_if.then_branch.Block.stmts;
    try testing.expectEqual(@as(usize, 4), plain_then.len);
    try testing.expect(isComposerCallStmt(&plain_then[0], "startReplaceGroup"));
    try testing.expect(plain_then[1] == .Decl);
    const branch_result = plain_then[1].Decl.Property;
    try testing.expect(branch_result.init.? == .Call);
    try testing.expectEqualStrings("Foo", branch_result.init.?.Call.callee.Path.segments[0].name);
    try testing.expect(isComposerCallStmt(&plain_then[2], "endReplaceGroup"));
    try testing.expect(plain_then[3] == .Expr);
    try testing.expect(plain_then[3].Expr == .Path);
    try testing.expectEqualStrings(branch_result.name.name, plain_then[3].Expr.Path.segments[0].name);
    // A no-else composable `if` gains a synthesized empty else to stay position-stable.
    try testing.expect(plain_if.else_branch != null);
    const plain_else = plain_if.else_branch.?.Block.stmts;
    try testing.expect(isComposerCallStmt(&plain_else[0], "startReplaceGroup"));
    try testing.expect(isComposerCallStmt(&plain_else[plain_else.len - 1], "endReplaceGroup"));
}
