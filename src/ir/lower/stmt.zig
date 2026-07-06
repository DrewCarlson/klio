//! Statement lowering. Free functions over the shared `FuncBuilder`;
//! filled in alongside the expression dispatch.

const std = @import("std");
const ast = @import("ast");
const ir = @import("../ir.zig");
const runtime = @import("runtime");
const FF = runtime.forest.ForestField;
const build = @import("../build.zig");

const expr_mod = @import("expr.zig");
const helpers = @import("helpers.zig");
const literals = @import("literals.zig");
const ast_scan = @import("ast_scan.zig");
const lambda_body = @import("lambda_body.zig");
const thunks = @import("thunks.zig");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Stmt = ast.Stmt;
const Expr = ast.Expr;
const Reg = ir.Reg;
const Inst = ir.Inst;
const Const = ir.Const;
const BinOp = ir.BinOp;
const FuncId = ir.FuncId;
const Terminator = ir.Terminator;
const StringSet = std.StringHashMap(void);

const lowerExpr = expr_mod.lowerExpr;
const lowerReceiver = expr_mod.lowerReceiver;
const exprSpan = helpers.exprSpan;
const boxedCellReg = helpers.boxedCellReg;
const widenNumericLiteral = literals.widenNumericLiteral;
const collectPathIdentsStmt = ast_scan.collectPathIdentsStmt;
const lowerLambdaBodyCapturingKindWith = lambda_body.lowerLambdaBodyCapturingKindWith;
const resolveCapture = lambda_body.resolveCapture;
const lowerExprAsParamThunk = thunks.lowerExprAsParamThunk;

/// Lower a statement. Returns the register holding the statement's value
/// when it is an expression statement in tail position, else `null`.
pub fn lowerStmt(b: *FuncBuilder, stmt: *const Stmt) Allocator.Error!?Reg {
    // Record the executing source position for stack-trace capture: a `Trace`
    // marks each statement so a throw (here or in any call it makes) reports the
    // line each frame is on. Cheap (a single span store at eval time); the JIT
    // hot loops bypass the eval dispatch entirely.
    switch (stmt.*) {
        .Expr => |*e| try b.push(.{ .Trace = .{ .span = helpers.exprSpan(e) } }),
        .Assign => |a| try b.push(.{ .Trace = .{ .span = a.span } }),
        .DestructuringDecl => |dd| try b.push(.{ .Trace = .{ .span = dd.span } }),
        // A `val x = expr` initializer can throw (or call something that does),
        // so mark its line too; other declarations carry no executable head.
        .Decl => |*d| switch (d.*) {
            .Property => |p| try b.push(.{ .Trace = .{ .span = p.span } }),
            else => {},
        },
    }
    switch (stmt.*) {
        .Expr => |*e| return try lowerExpr(b, e),
        .Decl => |*d| switch (d.*) {
            .Property => |p| return lowerPropertyDecl(b, p),
            .Function => |*f| return lowerLocalFnDecl(b, f),
            .Class => |*c| return lowerLocalClassDecl(b, c),
            else => return null,
        },
        .Assign => |a| {
            if (isSafeIndexTarget(&a.target)) {
                return lowerSafeIndexAssign(b, &a.target, a.op, &a.value);
            }
            if (isSafeMemberTarget(&a.target)) {
                return lowerSafeMemberAssign(b, &a.target, a.op, &a.value);
            }
            return lowerAssign(b, &a.target, a.op, &a.value);
        },
        .DestructuringDecl => |dd| return lowerDestructuringDecl(b, dd.names, &dd.init),
    }
}

/// `obj?.items[i] = v` — an `Index` target whose receiver chain is a
/// safe-`Member`.
fn isSafeIndexTarget(target: *const Expr) bool {
    return switch (target.*) {
        .Index => |idx| switch (idx.receiver.*) {
            .Member => |m| m.safe,
            else => false,
        },
        else => false,
    };
}

/// `obj?.field = v` — a safe-`Member` target.
fn isSafeMemberTarget(target: *const Expr) bool {
    return switch (target.*) {
        .Member => |m| m.safe,
        else => false,
    };
}

fn lowerPropertyDecl(b: *FuncBuilder, p: *const ast.Property) Allocator.Error!?Reg {
    // `val x = expr` / `var x = expr`. The init is lowered
    // into a fresh register and bound in the current scope;
    // mutability is enforced by typeck, not the IR.
    const init: Reg = if (p.delegate) |de| blk: {
        // `val x by D` — lower the delegate, then invoke its
        // `getValue(null, ::x)` once at decl time. For a
        // `lazy { producer }` this drives the producer; for
        // any custom delegate the dispatched method runs.
        // Each subsequent path read of `x` returns the bound
        // value, so this is eager-once semantics (sufficient
        // for `val`-style use; a `var x by D` mutating
        // delegate would need a true read-through dispatch
        // and is tracked separately).
        const delegate = try lowerExpr(b, de);
        const null_arg = try b.emitConst(.Null);
        const prop_ref = b.allocReg();
        const pname = try b.module.internConst(b.allocator, .{ .String = p.name.name });
        try b.push(.{ .PropertyRef = .{ .dst = prop_ref, .name = pname } });
        const args_start = b.allocReg();
        try b.push(.{ .Move = .{ .dst = args_start, .src = null_arg } });
        _ = b.allocReg();
        try b.push(.{ .Move = .{ .dst = Reg.from(args_start.int() + 1), .src = prop_ref } });
        const dst = b.allocReg();
        const name_c = try b.module.internConst(b.allocator, .{ .String = "getValue" });
        try b.push(.{ .CallMember = .{
            .dst = dst,
            .receiver = delegate,
            .name = name_c,
            .args = args_start,
            .n_args = 2,
            .arg_names = &.{},
        } });
        break :blk dst;
    } else switch (p.init != null) {
        true => blk: {
            const e = &p.init.?;
            const widened: ?Expr = if (p.ty) |*ty| widenNumericLiteral(e, ty) else null;
            // A type-annotated initializer puts its declared type in
            // tail position so a reified inline call (`val u: User =
            // resp.body()`) can infer its type argument.
            const prev = b.pushExpected(p.ty);
            const r = try lowerExpr(b, if (widened) |*w| w else e);
            b.restoreExpected(prev);
            break :blk r;
        },
        false => try b.emitConst(.Unit),
    };
    // Allocate a "home" register and Move the init value
    // into it for `var`, or for `val` declared without an
    // initializer (deferred init — multiple branches assign
    // before the first read). This gives reads through the
    // home reg slot semantics under the flat block IR.
    // For a `val foo = expr` the binding is fixed at decl
    // time and can skip the slot.
    // Track `: Any` annotations so subsequent `==` against
    // this var routes through the boxed-equality path.
    if (p.ty) |ty| {
        if (std.mem.eql(u8, ty.name.name, "Any")) {
            try b.markAnyTyped(p.name.name);
        }
    }
    // Record the local's declared type (or its initializer expression when
    // un-annotated) so inline-overload receiver narrowing can type a plain
    // local receiver (`val resp = client.get(url); resp.body<T>()`).
    if (p.ty) |ty| {
        try b.setLocalDeclType(p.name.name, ty.name.name);
        if (ty.nullable) try b.setLocalDeclNullable(p.name.name);
        if (ty.function == null and helpers.isBroadCollectionTypeName(ty.name.name)) {
            try b.markBroadCollectionLocal(p.name.name);
        }
    } else if (p.init) |*e| {
        if (e.* == .Call) try b.setLocalInitExpr(p.name.name, e);
        if (e.* == .ObjectExpr) try b.markObjectInitLocal(p.name.name);
    }
    if (b.isBoxed(p.name.name)) {
        // Captured `var` — box into a shared cell so writes
        // from a nested closure / coroutine are visible
        // here (Kotlin `Ref` semantics).
        const home = b.allocReg();
        try b.push(.{ .MakeCell = .{ .dst = home, .src = init } });
        try b.setMutableHome(p.name.name, home);
        try b.markMutable(p.name.name);
        try b.bind(p.name.name, home);
    } else if (p.mutable or p.init == null) {
        const home = b.allocReg();
        try b.push(.{ .Move = .{ .dst = home, .src = init } });
        try b.setMutableHome(p.name.name, home);
        if (p.mutable) {
            try b.markMutable(p.name.name);
        }
        try b.bind(p.name.name, home);
    } else {
        // `val x = y` where `y` is a reassignable var reads `y`'s home register
        // directly; a later write to `y` (`y = …`) Moves into that home and
        // would alias into `x`. Snapshot the value into a fresh register so the
        // val is an independent binding (Kotlin: a val captures the value, not
        // the variable).
        if (p.init) |*ie| {
            if (ie.* == .Path and ie.Path.segments.len == 1 and
                b.mutableHome(ie.Path.segments[0].name) != null)
            {
                const fresh = b.allocReg();
                try b.push(.{ .Move = .{ .dst = fresh, .src = init } });
                try b.bind(p.name.name, fresh);
                return null;
            }
        }
        try b.bind(p.name.name, init);
    }
    return null;
}

fn lowerLocalFnDecl(b: *FuncBuilder, f: *const ast.Function) Allocator.Error!?Reg {
    // Local fn: lower as a closure whose body captures the
    // enclosing scope's visible names. Bound to its
    // declared name so subsequent calls resolve to the
    // closure Value. Equivalent to `val name = { ... }`.
    // Both block-body (`fun foo() { ... }`) and
    // expression-body (`fun foo() = expr`) forms map to a
    // synthetic Block carrying the expression as its only
    // statement.
    const span_mod = @import("span");
    const dummy_span = span_mod.Span.init(span_mod.FileId.from(0), 0, 0);
    const body_block: ?ast.Block = if (f.body) |fb| switch (fb) {
        .Block => |blk| blk,
        .Expr => |e| body: {
            const stmts = try b.allocator.alloc(Stmt, 1);
            stmts[0] = .{ .Expr = e };
            break :body ast.Block{ .stmts = stmts, .span = dummy_span };
        },
    } else null;
    if (body_block) |body| {
        const self_cell = try localFnSelfCell(b, f, &body);
        // Same-named sibling declarations are OVERLOADS, not rebindings.
        // Register this declaration's signature and bind its mangled
        // sibling name to a dedicated cell BEFORE the body lowers, so a
        // call inside any sibling's body (including this one) selects
        // the applicable overload — the second `assertCompareResult`
        // must reach the first, not recurse into itself through the
        // shared plain-name self-cell. The closure lands in the cell
        // after it is built, below.
        const mangled_cell: Reg = mangled_blk: {
            const ov_tys = try b.allocator.alloc(?[]const u8, f.params.len);
            const ov_names = try b.allocator.alloc([]const u8, f.params.len);
            var n_required: usize = 0;
            var has_vararg = false;
            for (f.params, 0..) |p, j| {
                ov_tys[j] = if (p.is_vararg) null else p.ty.name.name;
                ov_names[j] = p.name.name;
                if (p.is_vararg) has_vararg = true else if (p.default == null) n_required += 1;
            }
            const ordinal = if (b.local_fn_overloads.getPtr(f.name.name)) |l| l.items.len else 0;
            // Module-lifetime: the mangled name ships inside the AstLambda
            // instruction's captured-name list, read at runtime.
            const mangled = try std.fmt.allocPrint(b.module.func_name_index.allocator, "{s}$ovl{d}", .{ f.name.name, ordinal });
            const null_v = try b.emitConst(.Null);
            const home = b.allocReg();
            try b.push(.{ .MakeCell = .{ .dst = home, .src = null_v } });
            try b.bind(mangled, home);
            try b.markBoxed(mangled);
            try b.markLocalFn(mangled);
            if (f.receiver_type != null) try b.markLocalExtFn(mangled);
            if (f.params.len != 0) try b.setLocalFnParamTys(mangled, ov_tys);
            try b.addLocalFnOverload(f.name.name, .{
                .mangled = mangled,
                .param_tys = ov_tys,
                .param_names = ov_names,
                .n_required = n_required,
                .has_vararg = has_vararg,
            });
            break :mangled_blk home;
        };
        const outer_names: StringSet = try b.visibleNames();
        const inherited_rlp: StringSet = try b.receiverLambdaParamNames();
        var outer_boxed = try b.boxedVarsSnapshot();
        defer outer_boxed.deinit();
        // A local *extension* function (`fun List<T>.mid() =
        // …`) binds its receiver as the implicit first `this`
        // param, so the body's bare member refs (`sorted()`,
        // `size`) resolve. Call sites prepend the receiver.
        const is_ext = f.receiver_type != null;
        var param_idents = try b.allocator.alloc(ast.Ident, f.params.len + @intFromBool(is_ext));
        defer b.allocator.free(param_idents);
        const param_tys = try b.allocator.alloc(?ast.TypeRef, f.params.len + @intFromBool(is_ext));
        defer b.allocator.free(param_tys);
        {
            const offset = @intFromBool(is_ext);
            if (is_ext) {
                param_idents[0] = .{ .name = "this", .span = dummy_span };
                param_tys[0] = f.receiver_type;
            }
            for (f.params, 0..) |p, i| {
                param_idents[offset + i] = p.name;
                param_tys[offset + i] = p.ty;
            }
        }
        const tailrec_self: ?[]const u8 = if (f.is_tailrec) f.name.name else null;
        const enclosing_owner: ?lambda_body.EnclosingOwner = if (b.ownerClass()) |o|
            .{ .class = o, .members = try b.enclosingMembersForChild() }
        else
            null;
        const inherited_lef = try b.localExtFnNames();
        const encl_recv = b.capturesThisSlot() or
            (!b.this_is_plain_param and b.resolve("this") != null) or
            b.ownerClass() != null or b.isParamThunk() or b.recvTy() != null;
        // A local contextual function binds its context parameters in the
        // body; stash them for the shared lambda-body lowering to consume.
        if (f.context_params.len != 0) {
            b.module.has_context_decls = true;
            b.module.pending_ctx = .{ .params = f.context_params, .type_params = f.type_params };
        }
        const lowered = try lowerLambdaBodyCapturingKindWith(
            b.module,
            param_idents,
            param_tys,
            &body,
            outer_names,
            true,
            &outer_boxed,
            tailrec_self,
            true,
            encl_recv,
            inherited_rlp,
            inherited_lef,
            &b.local_fn_overloads,
            enclosing_owner,
        );
        const body_func = lowered.func;
        // The lambda-body lowering builds params with `is_vararg = false`
        // (lambdas cannot declare varargs) — a local FUNCTION can, and the
        // closure invocation's vararg packing keys on the flag. Stamp the
        // declared flags back onto the lowered body func.
        {
            const offset = @intFromBool(is_ext);
            if (b.module.funcByIdMut(body_func)) |bf| {
                for (f.params, 0..) |p, i| {
                    const pi = offset + i;
                    if (pi < bf.params.len) bf.params[pi].is_vararg = p.is_vararg;
                }
            }
        }
        const captured_names = lowered.captures;
        const captures = try b.allocator.alloc(Reg, captured_names.len);
        for (captured_names, captures) |n, *slot| slot.* = try resolveCapture(b, n);
        var param_names = try b.allocator.alloc([]const u8, f.params.len + @intFromBool(is_ext));
        {
            const offset = @intFromBool(is_ext);
            if (is_ext) param_names[0] = "this";
            for (f.params, 0..) |p, i| param_names[offset + i] = p.name.name;
        }
        try registerLocalFnDefaults(b, f, is_ext, param_names, body_func);
        const dst = b.allocReg();
        try b.push(.{ .AstLambda = .{
            .dst = dst,
            .params = param_names,
            .body_ast = body,
            .captures = captures,
            .captured_names = captured_names,
            .absorb_return = true,
            .body_func = body_func,
        } });
        if (self_cell) |home| {
            try b.push(.{ .CellSet = .{ .cell = home, .value = dst } });
        } else {
            try b.bind(f.name.name, dst);
        }
        try b.markLocalFn(f.name.name);
        if (is_ext) {
            try b.markLocalExtFn(f.name.name);
        }
        // Record positional parameter type names (drop a leading `this`
        // receiver) so a literal argument coerces to a numeric primitive
        // parameter at the call site.
        {
            const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name.name, "this")) 1 else 0;
            if (f.params.len > recv_off) {
                const tys = try b.allocator.alloc(?[]const u8, f.params.len - recv_off);
                defer b.allocator.free(tys);
                for (tys, 0..) |*t, j| {
                    const p = f.params[recv_off + j];
                    t.* = if (p.is_vararg) null else p.ty.name.name;
                }
                try b.setLocalFnParamTys(f.name.name, tys);
            }
        }
        // The overload's mangled sibling binding (registered above, before
        // the body lowered) receives the built closure.
        try b.push(.{ .CellSet = .{ .cell = mangled_cell, .value = dst } });
    }
    return null;
}

// A local function that calls itself is desugared like
// `var name = null; name = { … name(…) … }`: a shared cell is created
// first so the body can capture it and the closure stores itself into
// it once built. This is the same boxed-self-reference path a recursive
// `lateinit var f = { … f(…) … }` already uses. A cell pre-hoisted by
// `lower_block` (so sibling local fns can capture each other) is reused.
fn localFnSelfCell(
    b: *FuncBuilder,
    f: *const ast.Function,
    body: *const ast.Block,
) Allocator.Error!?Reg {
    var self_refs = StringSet.init(b.allocator);
    defer self_refs.deinit();
    for (body.stmts) |*s| try collectPathIdentsStmt(s, &self_refs);
    if (b.mutableHome(f.name.name)) |home| {
        return home;
    } else if (self_refs.contains(f.name.name)) {
        const null_v = try b.emitConst(.Null);
        const home = b.allocReg();
        try b.push(.{ .MakeCell = .{ .dst = home, .src = null_v } });
        try b.setMutableHome(f.name.name, home);
        try b.markMutable(f.name.name);
        try b.markBoxed(f.name.name);
        try b.bind(f.name.name, home);
        return home;
    } else {
        return null;
    }
}

// Per-param defaults: lower each default expression as a thunk binding
// the lowered param prefix (so `b = a + 1` can read an earlier param)
// and register it under the body FuncId. The Vm pads missing trailing
// args from these the same way it does for top-level functions.
fn registerLocalFnDefaults(
    b: *FuncBuilder,
    f: *const ast.Function,
    is_ext: bool,
    param_names: []const []const u8,
    body_func: FuncId,
) Allocator.Error!void {
    var any_default = false;
    for (f.params) |p| {
        if (p.default != null) {
            any_default = true;
            break;
        }
    }
    if (!any_default) return;

    const offset: usize = @intFromBool(is_ext);
    var slots: std.ArrayList(?FuncId) = .empty;
    errdefer slots.deinit(b.module.registry.allocator);
    const reg_alloc = b.module.registry.allocator;
    var i: usize = 0;
    while (i < offset) : (i += 1) try slots.append(reg_alloc, null);
    for (f.params, 0..) |p, idx| {
        if (p.default) |default_expr| {
            const bind_upto = @min(offset + idx, param_names.len);
            const widened = widenNumericLiteral(default_expr, &p.ty);
            const name = try std.fmt.allocPrint(
                b.allocator,
                "__default_local_{s}_{s}",
                .{ f.name.name, p.name.name },
            );
            const fid = try lowerExprAsParamThunk(
                b.module,
                param_names[0..bind_upto],
                if (widened) |*w| w else default_expr,
                name,
            );
            try slots.append(reg_alloc, fid);
        } else {
            try slots.append(reg_alloc, null);
        }
    }
    try b.module.registry.local_fn_defaults.put(body_func, slots);
}

fn lowerSafeIndexAssign(
    b: *FuncBuilder,
    target: *const Expr,
    op: ast.AssignOp,
    value: *const Expr,
) Allocator.Error!?Reg {
    // `obj?.items[i] = v` — null-guard the outer Index
    // assignment when the receiver chain is a safe-Member.
    const idx = target.Index;
    const receiver = idx.receiver;
    const idx_args = idx.args;
    const idx_span = idx.span;
    const member = receiver.Member;
    const outer = member.receiver;
    const mname = member.name;
    const mspan = member.span;

    const outer_r = try lowerExpr(b, outer);
    const null_r = try b.emitConst(.Null);
    const is_null = b.allocReg();
    try b.push(.{ .BinOp = .{
        .dst = is_null,
        .op = .Eq,
        .lhs = outer_r,
        .rhs = null_r,
    } });
    const skip = try b.allocBlock();
    const do_set = try b.allocBlock();
    const join = try b.allocBlock();
    b.terminate(.{ .Branch = .{ .cond = is_null, .t = skip, .f = do_set } });
    b.switchTo(do_set);
    // Synthesize the non-safe equivalent and recurse.
    const inner_recv = try b.allocator.create(Expr);
    inner_recv.* = .{ .Member = .{
        .receiver = outer,
        .name = mname,
        .safe = false,
        .span = mspan,
    } };
    const inner_target = Expr{ .Index = .{
        .receiver = inner_recv,
        .args = idx_args,
        .span = idx_span,
    } };
    const synth = Stmt{ .Assign = .{
        .target = inner_target,
        .op = op,
        .value = value.*,
        .span = idx_span,
    } };
    _ = try lowerStmt(b, &synth);
    b.terminate(.{ .Goto = join });
    b.switchTo(skip);
    b.terminate(.{ .Goto = join });
    b.switchTo(join);
    return null;
}

fn lowerSafeMemberAssign(
    b: *FuncBuilder,
    target: *const Expr,
    op: ast.AssignOp,
    value: *const Expr,
) Allocator.Error!?Reg {
    // `obj?.field = v` (or compound `?.field += v`):
    //   if obj is null → skip the assignment entirely.
    //   otherwise → fall through to the regular non-safe
    //              assign path with the safe flag cleared.
    const member = target.Member;
    const receiver = member.receiver;
    const name = member.name;
    const member_span = member.span;

    const recv_r = try lowerExpr(b, receiver);
    const null_r = try b.emitConst(.Null);
    const is_null = b.allocReg();
    try b.push(.{ .BinOp = .{
        .dst = is_null,
        .op = .Eq,
        .lhs = recv_r,
        .rhs = null_r,
    } });
    const skip = try b.allocBlock();
    const do_set = try b.allocBlock();
    const join = try b.allocBlock();
    b.terminate(.{ .Branch = .{ .cond = is_null, .t = skip, .f = do_set } });
    b.switchTo(do_set);
    // Synthesize an equivalent non-safe assign and recurse
    // through Stmt::Assign so compound semantics, setters,
    // and class property setters reuse the existing path.
    const inner_target = Expr{ .Member = .{
        .receiver = receiver,
        .name = name,
        .safe = false,
        .span = member_span,
    } };
    const synth = Stmt{ .Assign = .{
        .target = inner_target,
        .op = op,
        .value = value.*,
        .span = member_span,
    } };
    _ = try lowerStmt(b, &synth);
    b.terminate(.{ .Goto = join });
    b.switchTo(skip);
    b.terminate(.{ .Goto = join });
    b.switchTo(join);
    return null;
}

fn lowerAssign(
    b: *FuncBuilder,
    target: *const Expr,
    op: ast.AssignOp,
    value: *const Expr,
) Allocator.Error!?Reg {
    const v = try lowerExpr(b, value);
    // Compound assigns first try `<op>Assign` as a member
    // call on the target — covers user types declaring
    // `operator fun plusAssign(...)` and built-in mutable
    // collections (MutableList += elem). When the call
    // raises (no method, immutable target), fall through
    // to the rebind path below. Today this fires only
    // when the target is a Path-bound local — Member /
    // Index targets need their own routing.
    // Only attempt `plusAssign`-style member dispatch when the
    // target is NOT a mutable local Path. For a `var` local the
    // primitive rebind path below is what Kotlin actually does
    // (Int has no plusAssign). For a `val` Path the value's type
    // declares plusAssign (operator on a class, or built-in
    // collection mutation), so CallMember is correct.
    // The plusAssign / minusAssign-style member dispatch only
    // fires for a Path target naming a `val` LOCAL (e.g.
    // `val h = Histogram(); h += w` or `val xs = mutableListOf<Int>(); xs += 1`).
    // A Path target whose name doesn't resolve locally is a
    // top-level binding; route it through the BinOp +
    // StoreGlobal path below so top-level `var` compound
    // assigns + delegated-property setters fire.
    // A boxed var or a captured outer binding is an
    // assignable variable, not a `val` whose value type
    // declares an `<op>Assign` operator. Excluding both
    // keeps a second compound-assign (after the first
    // rebinds the name to a plain reg) on the rebind path
    // instead of mis-dispatching `plusAssign` on the Int.
    const path_is_val = switch (target.*) {
        .Path => |p| p.segments.len == 1 and
            !b.isMutable(p.segments[0].name) and
            !b.isBoxed(p.segments[0].name) and
            !b.knowsOuter(p.segments[0].name) and
            b.resolve(p.segments[0].name) != null,
        else => false,
    };
    if (op != .Assign and path_is_val) {
        const method_name = switch (op) {
            .Add => "plusAssign",
            .Sub => "minusAssign",
            .Mul => "timesAssign",
            .Div => "divAssign",
            .Rem => "remAssign",
            .Assign => unreachable,
        };
        const recv = try lowerExpr(b, target);
        const args_start = b.allocReg();
        try b.push(.{ .Move = .{ .dst = args_start, .src = v } });
        const dst = b.allocReg();
        const nm = try b.module.internConst(b.allocator, .{ .String = method_name });
        try b.push(.{ .CallMember = .{
            .dst = dst,
            .receiver = recv,
            .name = nm,
            .args = args_start,
            .n_args = 1,
            .arg_names = &.{},
        } });
        return null;
    }
    // Compound assign to a property (`recv.field += x`). Kotlin resolves
    // this in place when the field's type carries the `<op>Assign` operator
    // (built-in mutable collections, a user `operator fun plusAssign`),
    // mutating the field value and NOT reassigning the property — so
    // `map.entries += e` dispatches `entries.plusAssign(e)` on the read-only
    // view (which throws) rather than trying to SET the read-only `entries`.
    // The current value's type is only known at runtime, so emit a single
    // `CompoundField` that reads the field, dispatches `<op>Assign` when the
    // value supports it, and otherwise falls back to read-modify-write
    // (needed for scalar properties like `obj.count += 1`).
    if (op != .Assign) {
        if (target.* == .Member and !target.Member.safe) {
            const m = target.Member;
            const recv = try lowerReceiver(b, m.receiver);
            const bin: BinOp = switch (op) {
                .Add => .Add,
                .Sub => .Sub,
                .Mul => .Mul,
                .Div => .Div,
                .Rem => .Mod,
                .Assign => unreachable,
            };
            const field = try b.module.internConst(b.allocator, .{ .String = m.name.name });
            try b.push(.{ .CompoundField = .{
                .receiver = recv,
                .field = field,
                .op = bin,
                .value = v,
            } });
            return null;
        }
    }
    const combined: Reg = switch (op) {
        .Assign => v,
        .Add, .Sub, .Mul, .Div, .Rem => blk: {
            const cur0 = try lowerExpr(b, target);
            // `xs += y` / `xs -= y` on a statically broad collection
            // (`Iterable`/`Collection`) rebinds to a `List`; coerce a `Set`
            // runtime value to a list first so the `List`-returning operator
            // is dispatched (mirrors the `lowerBinary` receiver coercion).
            const cur = if (op == .Add or op == .Sub)
                try helpers.coerceBroadCollectionToList(b, target, cur0)
            else
                cur0;
            const bin: BinOp = switch (op) {
                .Add => .Add,
                .Sub => .Sub,
                .Mul => .Mul,
                .Div => .Div,
                .Rem => .Mod,
                .Assign => unreachable,
            };
            // Mark the combine step so a mutable-collection left operand can
            // mutate in place via `<op>Assign`. Only do so when the rebind is
            // NOT viable: a reassignable local (`var`/boxed) target follows
            // Kotlin's `a = a.plus(b)` form, which for a read-only-typed local
            // holding a mutable value (`var x: List = mutableListOf()`) must
            // produce a fresh list and leave the original untouched. A val /
            // member / global target cannot be rebound, so the in-place
            // operator is what Kotlin uses there.
            const target_reassignable_local = switch (target.*) {
                .Path => |p| p.segments.len == 1 and
                    b.resolve(p.segments[0].name) != null and
                    (b.isMutable(p.segments[0].name) or b.isBoxed(p.segments[0].name)),
                else => false,
            };
            const dst = b.allocReg();
            try b.push(.{ .BinOp = .{
                .dst = dst,
                .op = bin,
                .lhs = cur,
                .rhs = v,
                .compound = !target_reassignable_local,
            } });
            break :blk dst;
        },
    };
    try storeCombinedToTarget(b, target, combined);
    return null;
}

// Route the already-combined value to the assignment target: a single
// Path name (local / cell / capture / member / global), a Member field,
// or an Index `set` call. Shared by compound-assign, prefix ++/--, and
// postfix ++/-- so the write-back decision lives in exactly one place.
pub fn storeCombinedToTarget(b: *FuncBuilder, target: *const Expr, combined: Reg) Allocator.Error!void {
    switch (target.*) {
        .Path => |p| {
            if (p.segments.len != 1) {
                try b.push(.{ .Trace = .{ .span = exprSpan(target) } });
                return;
            }
            const seg = p.segments[0].name;
            if (b.isBoxed(seg)) {
                // A captured-and-written outer var is boxed into a shared
                // `Value.Cell` at its binding site (var decl, function /
                // lambda parameter, or inline-splice parameter), so the
                // write lands on the cell and is visible at the declaration
                // site on every closure-execution path. This subsumes the
                // former captured-outer `StoreGlobal` fallback.
                const cell = try boxedCellReg(b, seg);
                try b.push(.{ .CellSet = .{ .cell = cell, .value = combined } });
            } else if (b.mutableHome(seg)) |home| {
                try b.push(.{ .Move = .{ .dst = home, .src = combined } });
            } else if (b.resolve(seg) != null) {
                try b.rebind(seg, combined);
            } else if (b.hasOwnMember(seg) and b.resolve("this") != null) {
                // Method-body `this.field` write — route
                // SetField on the receiver so the bare-
                // name assign reaches the instance, not
                // a synthetic global. A private SHADOW of a
                // supertype's same-name property writes ITS OWN
                // owner-mangled cell, never the base class's.
                const this_reg = b.resolve("this").?;
                const store_name: []const u8 = blk: {
                    const oc = b.ownerClass() orelse break :blk seg;
                    var kb: [256]u8 = undefined;
                    const probe = std.fmt.bufPrint(&kb, "{s}\x1f{s}", .{ oc, seg }) catch break :blk seg;
                    break :blk b.module.registry.private_shadow_props.getKey(probe) orelse seg;
                };
                const field = try b.module.internConst(b.allocator, .{ .String = store_name });
                try b.push(.{ .SetField = .{
                    .receiver = this_reg,
                    .field = field,
                    .value = combined,
                } });
            } else if (b.capturesThisSlot() or b.resolve("this") != null) {
                // Unqualified write inside a lambda body or a
                // method/extension body whose name is not a local/
                // param/captured-outer/own-member. By Kotlin scoping
                // it is either a property of the receiver — a member,
                // or an extension-property setter (`var T.x set(…)`)
                // on the receiver's type or a supertype
                // (`receiveType = …` inside `PipelineCall.receiveNullable`)
                // — or a genuine top-level binding. Decide at runtime,
                // symmetric to the read side's LoadFromThisOrGlobal:
                // capture `this` on demand so a receiver-binding invoke
                // populates the slot, then StoreToThisOrGlobal sets the
                // receiver's property when present, else globals.
                const this_idx = try b.recordCapture("this");
                const name_c = try b.module.internConst(b.allocator, .{ .String = seg });
                expr_mod.orEmitAudit(b, "bare_name_assign", "StoreToThisOrGlobal", seg);
                try b.push(.{ .StoreToThisOrGlobal = .{
                    .this_idx = this_idx,
                    .name = name_c,
                    .value = combined,
                } });
            } else {
                // Top-level binding: route through StoreGlobal so
                // the tree-walker setter / delegate fires. A renamed
                // file-private property writes its per-file global.
                const target_name = expr_mod.filePrivatePropRename(b, seg, p.segments[0].span.file.int()) orelse seg;
                const n = try b.module.internConst(b.allocator, .{ .String = target_name });
                try b.push(.{ .StoreGlobal = .{ .name = n, .value = combined } });
            }
        },
        .Member => |m| {
            if (m.safe) return;
            const recv = try lowerReceiver(b, m.receiver);
            const field = try b.module.internConst(b.allocator, .{ .String = m.name.name });
            try b.push(.{ .SetField = .{
                .receiver = recv,
                .field = field,
                .value = combined,
            } });
        },
        .Index => |idx| {
            // `m[k] = v` lowers to receiver.set(k, v) so
            // map / mutable-list assignment dispatches
            // through the same call_member path that
            // handles built-in collection mutation.
            const recv = try lowerReceiver(b, idx.receiver);
            // Reserve a contiguous run of slots for keys +
            // value BEFORE lowering the key expressions,
            // since lowering each key may allocate auxiliary
            // registers (e.g. for Const literals) and we
            // need the run to stay tight so read_arg_run
            // picks up the value reg right after the keys.
            const n_keys = idx.args.len;
            const key_start = b.allocReg();
            var key_slots = try b.allocator.alloc(Reg, if (n_keys == 0) 1 else n_keys);
            defer b.allocator.free(key_slots);
            key_slots[0] = key_start;
            var i: usize = 1;
            while (i < n_keys) : (i += 1) key_slots[i] = b.allocReg();
            const val_slot = b.allocReg();
            for (key_slots[0..n_keys], idx.args) |slot, *arg| {
                const r = try lowerExpr(b, arg);
                try b.push(.{ .Move = .{ .dst = slot, .src = r } });
            }
            try b.push(.{ .Move = .{ .dst = val_slot, .src = combined } });
            const dst = b.allocReg();
            const nm = try b.module.internConst(b.allocator, .{ .String = "set" });
            try b.push(.{ .CallMember = .{
                .dst = dst,
                .receiver = recv,
                .name = nm,
                .args = key_start,
                .n_args = @as(u32, @intCast(n_keys)) + 1,
                .arg_names = &.{},
            } });
        },
        else => {
            try b.push(.{ .Trace = .{ .span = exprSpan(target) } });
        },
    }
}

fn lowerLocalClassDecl(b: *FuncBuilder, c: *const ast.Class) Allocator.Error!?Reg {
    // Local class declaration inside a function body. Capture
    // the visible scope so the class methods can read names
    // from the enclosing fn (`val factor = 10; class Scaled { … n * factor … }`).
    var visible = try b.visibleNames();
    defer visible.deinit();
    const captured_names = try b.allocator.alloc([]const u8, visible.count());
    var it = visible.keyIterator();
    var i: usize = 0;
    while (it.next()) |k| : (i += 1) captured_names[i] = k.*;
    const captures = try b.allocator.alloc(Reg, captured_names.len);
    for (captured_names, captures) |n, *slot| slot.* = try resolveCapture(b, n);
    try b.push(.{ .RegisterClass = .{
        .class = FF(ast.Class).fromPtr(c),
        .captured_names = captured_names,
        .captures = captures,
    } });
    return null;
}

fn lowerDestructuringDecl(
    b: *FuncBuilder,
    names: []const ast.Ident,
    init: *const Expr,
) Allocator.Error!?Reg {
    // `val (a, b, ...) = expr` desugars to repeated
    // `expr.componentN()` calls. `_` placeholders skip the
    // call entirely. Tree walker handles this via
    // eval_stmt; the IR's CallMember + Host dispatch covers
    // the same surface, so we lower it inline.
    const recv = try lowerExpr(b, init);
    for (names, 0..) |name, i| {
        if (std.mem.eql(u8, name.name, "_")) continue;
        const comp_name = try std.fmt.allocPrint(b.allocator, "component{d}", .{i + 1});
        const nm = try b.module.internConst(b.allocator, .{ .String = comp_name });
        const args_start = b.allocReg();
        const dst = b.allocReg();
        try b.push(.{ .CallMember = .{
            .dst = dst,
            .receiver = recv,
            .name = nm,
            .args = args_start,
            .n_args = 0,
            .arg_names = &.{},
        } });
        try b.bind(name.name, dst);
    }
    return null;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;
const span = @import("span");
const Module = ir.Module;

test {
    testing.refAllDecls(@This());
}

fn dummySpan() span.Span {
    return span.Span.init(span.FileId.from(0), 0, 0);
}

fn intLit(v: i64) Expr {
    return .{ .IntLit = .{ .value = v, .kind = .Int, .span = dummySpan() } };
}

fn freeFunc(func: ir.Func) void {
    for (func.blocks) |blk| {
        if (blk.insts.len != 0) testing.allocator.free(blk.insts);
        if (blk.catches.len != 0) testing.allocator.free(blk.catches);
    }
    testing.allocator.free(func.blocks);
    if (func.capture_order.len != 0) testing.allocator.free(func.capture_order);
}

fn pathExpr(segs: []ast.Ident) Expr {
    return .{ .Path = .{ .segments = segs, .span = dummySpan() } };
}

test "expr statement returns its register" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const s = Stmt{ .Expr = intLit(7) };
    const r = try lowerStmt(&b, &s);
    try testing.expect(r != null);
    b.terminate(.{ .Return = r.? });
    const func = try b.finish("f", "test.f", build.typeInt());
    defer freeFunc(func);
    // The statement is preceded by a `Trace` position marker (stack-trace
    // support); the value materializes in the following `Const`.
    try testing.expect(func.blocks[0].insts[0] == .Trace);
    try testing.expect(func.blocks[0].insts[1] == .Const);
}

test "val without annotation binds directly" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    var p = ast.Property{
        .mutable = false,
        .name = .{ .name = "x", .span = dummySpan() },
        .receiver_type = null,
        .ty = null,
        .init = intLit(3),
        .delegate = null,
        .getter = null,
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
        .annotations = &.{},
        .span = dummySpan(),
    };
    const s = Stmt{ .Decl = .{ .Property = &p } };
    const r = try lowerStmt(&b, &s);
    try testing.expect(r == null);
    // `val x = 3` binds `x` to the init register without a home slot.
    try testing.expect(b.resolve("x") != null);
    try testing.expect(b.mutableHome("x") == null);
}

test "var declaration gets a mutable home slot" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    var p = ast.Property{
        .mutable = true,
        .name = .{ .name = "n", .span = dummySpan() },
        .receiver_type = null,
        .ty = null,
        .init = intLit(0),
        .delegate = null,
        .getter = null,
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
        .annotations = &.{},
        .span = dummySpan(),
    };
    const s = Stmt{ .Decl = .{ .Property = &p } };
    _ = try lowerStmt(&b, &s);
    try testing.expect(b.isMutable("n"));
    try testing.expect(b.mutableHome("n") != null);
    b.terminate(.{ .Return = null });
    const func = try b.finish("f", "test.f", build.typeUnit());
    defer freeFunc(func);
    // Trace position marker, then the const fused straight into the home
    // slot (the single-use `Const T; Move home <- T` pair coalesces at
    // `finish`).
    try testing.expect(func.blocks[0].insts[0] == .Trace);
    try testing.expect(func.blocks[0].insts.len == 2);
    try testing.expect(func.blocks[0].insts[1] == .Const);
}

test "any-typed val is marked" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const any_ty = ast.TypeRef{
        .name = .{ .name = "Any", .span = dummySpan() },
        .nullable = false,
        .span = dummySpan(),
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
    var p = ast.Property{
        .mutable = false,
        .name = .{ .name = "a", .span = dummySpan() },
        .receiver_type = null,
        .ty = any_ty,
        .init = intLit(1),
        .delegate = null,
        .getter = null,
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
        .annotations = &.{},
        .span = dummySpan(),
    };
    const s = Stmt{ .Decl = .{ .Property = &p } };
    _ = try lowerStmt(&b, &s);
    try testing.expect(b.isAnyTyped("a"));
}

test "assign to var rebinds through the home slot" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    // Set up `var n = 0` first.
    var p = ast.Property{
        .mutable = true,
        .name = .{ .name = "n", .span = dummySpan() },
        .receiver_type = null,
        .ty = null,
        .init = intLit(0),
        .delegate = null,
        .getter = null,
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
        .annotations = &.{},
        .span = dummySpan(),
    };
    const decl = Stmt{ .Decl = .{ .Property = &p } };
    _ = try lowerStmt(&b, &decl);
    const home = b.mutableHome("n").?;
    // `n = 5`
    var segs = [_]ast.Ident{.{ .name = "n", .span = dummySpan() }};
    const target = pathExpr(&segs);
    const assign = Stmt{ .Assign = .{
        .target = target,
        .op = .Assign,
        .value = intLit(5),
        .span = dummySpan(),
    } };
    _ = try lowerStmt(&b, &assign);
    b.terminate(.{ .Return = null });
    const func = try b.finish("f", "test.f", build.typeUnit());
    defer freeFunc(func);
    // Last instruction is a Move into the home register.
    const insts = func.blocks[0].insts;
    // The assignment's value fuses straight into the home register (the
    // single-use `Const T; Move home <- T` pair coalesces at `finish`).
    const last = insts[insts.len - 1];
    try testing.expect(last == .Const);
    try testing.expectEqual(home, last.Const.dst);
}

test "assign to top-level name emits store global" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    var segs = [_]ast.Ident{.{ .name = "g", .span = dummySpan() }};
    const target = pathExpr(&segs);
    const assign = Stmt{ .Assign = .{
        .target = target,
        .op = .Assign,
        .value = intLit(9),
        .span = dummySpan(),
    } };
    _ = try lowerStmt(&b, &assign);
    b.terminate(.{ .Return = null });
    const func = try b.finish("f", "test.f", build.typeUnit());
    defer freeFunc(func);
    const insts = func.blocks[0].insts;
    try testing.expect(insts[insts.len - 1] == .StoreGlobal);
}

test "compound assign to top-level emits binop then store global" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    var segs = [_]ast.Ident{.{ .name = "g", .span = dummySpan() }};
    const target = pathExpr(&segs);
    const assign = Stmt{ .Assign = .{
        .target = target,
        .op = .Add,
        .value = intLit(1),
        .span = dummySpan(),
    } };
    _ = try lowerStmt(&b, &assign);
    b.terminate(.{ .Return = null });
    const func = try b.finish("f", "test.f", build.typeUnit());
    defer freeFunc(func);
    const insts = func.blocks[0].insts;
    var saw_binop = false;
    for (insts) |inst| {
        if (inst == .BinOp) saw_binop = true;
    }
    try testing.expect(saw_binop);
    try testing.expect(insts[insts.len - 1] == .StoreGlobal);
}

test "compound assign to val local dispatches plusAssign" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    // `val xs = <reg>` (immutable local bound directly).
    const r = b.allocReg();
    try b.bind("xs", r);
    var segs = [_]ast.Ident{.{ .name = "xs", .span = dummySpan() }};
    const target = pathExpr(&segs);
    const assign = Stmt{ .Assign = .{
        .target = target,
        .op = .Add,
        .value = intLit(1),
        .span = dummySpan(),
    } };
    _ = try lowerStmt(&b, &assign);
    b.terminate(.{ .Return = null });
    const func = try b.finish("f", "test.f", build.typeUnit());
    defer freeFunc(func);
    const insts = func.blocks[0].insts;
    try testing.expect(insts[insts.len - 1] == .CallMember);
}

test "member assign emits set field" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const r = b.allocReg();
    try b.bind("obj", r);
    var recv_segs = [_]ast.Ident{.{ .name = "obj", .span = dummySpan() }};
    var recv = pathExpr(&recv_segs);
    const target = Expr{ .Member = .{
        .receiver = &recv,
        .name = .{ .name = "field", .span = dummySpan() },
        .safe = false,
        .span = dummySpan(),
    } };
    const assign = Stmt{ .Assign = .{
        .target = target,
        .op = .Assign,
        .value = intLit(2),
        .span = dummySpan(),
    } };
    _ = try lowerStmt(&b, &assign);
    b.terminate(.{ .Return = null });
    const func = try b.finish("f", "test.f", build.typeUnit());
    defer freeFunc(func);
    const insts = func.blocks[0].insts;
    try testing.expect(insts[insts.len - 1] == .SetField);
}

test "compound assign to member emits compound field" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const r = b.allocReg();
    try b.bind("obj", r);
    var recv_segs = [_]ast.Ident{.{ .name = "obj", .span = dummySpan() }};
    var recv = pathExpr(&recv_segs);
    const target = Expr{ .Member = .{
        .receiver = &recv,
        .name = .{ .name = "field", .span = dummySpan() },
        .safe = false,
        .span = dummySpan(),
    } };
    const assign = Stmt{ .Assign = .{
        .target = target,
        .op = .Add,
        .value = intLit(2),
        .span = dummySpan(),
    } };
    _ = try lowerStmt(&b, &assign);
    b.terminate(.{ .Return = null });
    const func = try b.finish("f", "test.f", build.typeUnit());
    defer freeFunc(func);
    const insts = func.blocks[0].insts;
    // A property compound-assign defers the plusAssign-vs-rewrite decision to
    // runtime: a single `CompoundField`, never a read-modify-`SetField`.
    try testing.expect(insts[insts.len - 1] == .CompoundField);
    for (insts) |inst| try testing.expect(inst != .SetField);
}

test "index assign emits set call" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const r = b.allocReg();
    try b.bind("xs", r);
    var recv_segs = [_]ast.Ident{.{ .name = "xs", .span = dummySpan() }};
    var recv = pathExpr(&recv_segs);
    var idx_args = [_]Expr{intLit(0)};
    const target = Expr{ .Index = .{
        .receiver = &recv,
        .args = &idx_args,
        .span = dummySpan(),
    } };
    const assign = Stmt{ .Assign = .{
        .target = target,
        .op = .Assign,
        .value = intLit(42),
        .span = dummySpan(),
    } };
    _ = try lowerStmt(&b, &assign);
    b.terminate(.{ .Return = null });
    const func = try b.finish("f", "test.f", build.typeUnit());
    defer freeFunc(func);
    const insts = func.blocks[0].insts;
    const last = insts[insts.len - 1];
    try testing.expect(last == .CallMember);
    try testing.expectEqual(@as(u8, 2), last.CallMember.n_args);
}

test "safe member assign branches on null" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const r = b.allocReg();
    try b.bind("obj", r);
    var recv_segs = [_]ast.Ident{.{ .name = "obj", .span = dummySpan() }};
    var recv = pathExpr(&recv_segs);
    const target = Expr{ .Member = .{
        .receiver = &recv,
        .name = .{ .name = "field", .span = dummySpan() },
        .safe = true,
        .span = dummySpan(),
    } };
    const assign = Stmt{ .Assign = .{
        .target = target,
        .op = .Assign,
        .value = intLit(7),
        .span = dummySpan(),
    } };
    const out = try lowerStmt(&b, &assign);
    try testing.expect(out == null);
    const func = try b.finish("f", "test.f", build.typeUnit());
    defer freeFunc(func);
    // Entry block branches; extra blocks were allocated for skip / do / join.
    try testing.expect(func.blocks.len >= 4);
    try testing.expect(func.blocks[0].terminator == .Branch);
}
