//! Expression lowering — the central recursive dispatch. Every sibling
//! lower file calls back into `lowerExpr`. Faithful port of the Rust
//! `lower/expr.rs`: literals, binary / unary primitive operations, paths,
//! member access, calls (including the overload-resolution ladder),
//! when / if / try as expressions, lambdas, and the remaining grammar.

const std = @import("std");
const ast = @import("ast");
const runtime = @import("runtime");
const ir = @import("../ir.zig");
const applicability = @import("applicability");
const build = @import("../build.zig");

const helpers = @import("helpers.zig");
const literals = @import("literals.zig");
const inline_state = @import("inline_state.zig");
const decl_mod = @import("decl.zig");
const ast_scan = @import("ast_scan.zig");
const inline_call = @import("inline_call.zig");
const lambda_body = @import("lambda_body.zig");
const for_loop = @import("for_loop.zig");
const when_expr = @import("when_expr.zig");
const stmt_mod = @import("stmt.zig");

const Allocator = std.mem.Allocator;

const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const AstBlock = ast.Block;
const AstBinOp = ast.BinOp;
const AstUnOp = ast.UnOp;
const BinOp = ir.BinOp;
const Const = ir.Const;
const ConstId = ir.ConstId;
const Inst = ir.Inst;
const Reg = ir.Reg;
const UnOp = ir.UnOp;
const FuncId = ir.FuncId;
const BlockId = ir.BlockId;
const Func = ir.Func;
const Terminator = ir.Terminator;
const SpreadPart = ir.SpreadPart;
const CatchHandler = ir.CatchHandler;
const TypeRef = ir.TypeRef;
const StringSet = std.StringHashMap(void);

// Helper re-aliases for the sibling free functions used below.
const astBinop = helpers.astBinop;
const boxedCellReg = helpers.boxedCellReg;
const calleeLabel = helpers.calleeLabel;
const lowerArgRun = helpers.lowerArgRun;
const lowerArgRunWithArity = helpers.lowerArgRunWithArity;
const lowerArgRunFull = helpers.lowerArgRunFull;
const internArgNames = helpers.internArgNames;
const internTypeArgs = helpers.internTypeArgs;
const exprSpan = helpers.exprSpan;
const isAnyTypedPath = helpers.isAnyTypedPath;
const isGenericTypedPath = helpers.isGenericTypedPath;
const lambdaWritesOuterVar = helpers.lambdaWritesOuterVar;

const isBoxedToAnyForm = ast_scan.isBoxedToAnyForm;
const collectDottedFqn = ast_scan.collectDottedFqn;
const collectPathIdents = ast_scan.collectPathIdents;
const collectPathIdentsStmt = ast_scan.collectPathIdentsStmt;

const isPackageHead = literals.isPackageHead;
const isPkgRoot = literals.isPkgRoot;

const isTopLevelProp = inline_state.isTopLevelProp;
const inlineFnAst = inline_state.inlineFnAst;
const inlineFnAstForRecv = inline_state.inlineFnAstForRecv;
const CallShape = inline_state.CallShape;

const isLowerAnonCapture = decl_mod.isLowerAnonCapture;

const argLambdaHasNonlocalReturn = inline_call.argLambdaHasNonlocalReturn;
const spliceInlineLambda = inline_call.spliceInlineLambda;
const tryInlineCallWithTypeArgs = inline_call.tryInlineCallWithTypeArgs;

const lowerLambdaBodyCapturing = lambda_body.lowerLambdaBodyCapturing;
const lowerLambdaBodyCapturingKind = lambda_body.lowerLambdaBodyCapturingKind;
const resolveCapture = lambda_body.resolveCapture;
const EnclosingOwner = lambda_body.EnclosingOwner;

const lowerFor = for_loop.lowerFor;
const lowerForLabeled = for_loop.lowerForLabeled;
const lowerWhen = when_expr.lowerWhen;
const lowerStmt = stmt_mod.lowerStmt;

/// The single lowering-time `this`-register resolver shared by the bare
/// `::name`/member-ref site and the bare-extension-call sites. A bound
/// local `this` always wins; otherwise `this` is recovered from an outer
/// capture when it is a known outer name — and, when `in_lambda_body` is
/// set, also for any lambda body (whose implicit `this` arrives via the
/// closure's own capture slot even without a `knowsOuter` record). When
/// `bind_local` is set the recovered capture register is bound as the
/// frame's `this` so later references reuse it. Returns `null` at top
/// level / in a non-receiver context.
fn resolveThisRegKind(b: *FuncBuilder, in_lambda_body: bool, bind_local: bool) Allocator.Error!?Reg {
    if (b.resolve("this")) |r| return r;
    if (b.knowsOuter("this") or (in_lambda_body and b.capturesThisSlot())) {
        const idx = try b.recordCapture("this");
        const dst = b.allocReg();
        try b.push(.{ .LoadCapture = .{ .dst = dst, .idx = idx } });
        if (bind_local) try b.bind("this", dst);
        return dst;
    }
    return null;
}

/// The register holding the current implicit receiver (`this`), if one is
/// in scope: either bound directly (a method / extension / receiver lambda
/// body) or reachable as an outer capture. Returns `null` at top level / in
/// a non-receiver context. Used to bind a bare `::name` member reference to
/// its receiver at creation time.
fn resolveThisReg(b: *FuncBuilder) Allocator.Error!?Reg {
    return resolveThisRegKind(b, false, false);
}

/// Lower an expression that appears as the *receiver / qualifier head* of a
/// member access or call. A bare single-segment class/interface name here
/// is a *qualifier* — it stays the class value so nested-class
/// (`Outer.Inner`) and companion-member forwarding work — unlike the same
/// Path in value position, which resolves to the companion object.
/// Everything else defers to `lowerExpr`.
pub fn lowerReceiver(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    if (expr.* == .Path and expr.Path.segments.len == 1) {
        const segments = expr.Path.segments;
        const n = segments[0].name;
        // Skip the class-name shortcut when the scope renames this name to
        // a (mangled) nested class/object or a file-private type: a bare
        // `Inner` inside `Outer` must reach `Outer$Inner` even though a
        // same-named top-level class owns the bare `class_id`. Falling
        // through to `lowerExpr` applies the rewrite in the `Path` arm.
        const aliased = scopeTypeRename(b, n, segments[0].span.file.int()) != null;
        if (!aliased and b.resolve(n) == null and !b.knowsOuter(n) and
            b.module.classId(n) != null and !enclosingMemberShadowsClass(b, n))
        {
            const dst = b.allocReg();
            const nm = try b.module.internConst(b.allocator, .{ .String = n });
            // The index-resolved class rides as the exact identity so a
            // same-simple-name class/object from an invisible package
            // cannot swap in at runtime (a nested `State` inside the
            // caller's class must not resolve to another package's
            // file-private `object State`). A same-named top-level
            // property keeps the name-keyed read — the property wins in
            // value position.
            const cls_pick: ?ir.ClassId = if (isTopLevelProp(n))
                b.module.classIdExactImport(n, segments[0].span.file)
            else
                b.module.classIdIndexed(n, b.self_package, segments[0].span.file);
            try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = nm, .class = cls_pick } });
            return dst;
        }
    }
    // A receiver is not in the call's tail position; drop the
    // expected-type hint so it does not reach a reified inline call here.
    const prev_expected = b.pushExpected(null);
    const r = try lowerExpr(b, expr);
    b.restoreExpected(prev_expected);
    return r;
}

/// Among same-name overload candidates, prefer the one whose parameter type
/// at an explicitly-cast argument position (`x as T`) matches the cast
/// target `T`. Returns `null` when no cast argument disambiguates an
/// arity-matching candidate, so the caller falls back to its arity-first
/// pick.
fn overloadPickByCast(
    b: *FuncBuilder,
    cands: []const FuncId,
    args: []const Expr,
    want: usize,
) Allocator.Error!?FuncId {
    // Collect (arg index, cast simple-name) pairs.
    var casts: std.ArrayList(struct { i: usize, name: []const u8 }) = .empty;
    defer casts.deinit(b.allocator);
    for (args, 0..) |a, i| {
        if (a == .As) {
            const full = a.As.ty.name.name;
            const simple = rsplitLast(full, '.');
            try casts.append(b.allocator, .{ .i = i, .name = simple });
        }
    }
    if (casts.items.len == 0) return null;

    var best: ?FuncId = null;
    var best_score: i32 = 0;
    for (cands) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        if (!f.hasBody() or (f.params.len != 0 and f.params[f.params.len - 1].is_vararg)) continue;
        const base: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        if (f.params.len -| base != want) continue;
        var score: i32 = 0;
        for (casts.items) |c| {
            if (base + c.i < f.params.len) {
                const p = f.params[base + c.i];
                const pn = rsplitLast(p.ty.name, '.');
                if (std.mem.eql(u8, pn, c.name)) score += 2;
            }
        }
        if (score > 0 and (best == null or score > best_score)) {
            best = fid;
            best_score = score;
        }
    }
    return best;
}

/// Lower one expression into the current block, returning the register
/// holding its value. Value-less forms (assignments, declarations) return a
/// synthetic `Unit` register so downstream code stays uniform.
pub fn lowerExpr(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    // Arm the implicit-label for a call's argument lambdas with the
    // callee's simple name (`with(n) { … }` → "with"). `lowerArgRun`
    // consumes and re-arms it per argument; `Lambda` reads it.
    if (expr.* == .Call) {
        b.pending_lambda_label = calleeLabel(expr.Call.callee);
    }
    switch (expr.*) {
        .IntLit => |lit| {
            // Honour the literal's declared kind (`1L`, `1U`, `1uL`)
            // rather than letting the value range pick.
            return switch (lit.kind) {
                .Long => b.emitConst(.{ .Long = lit.value }),
                .UInt => b.emitConst(.{ .UInt = @intCast(lit.value) }),
                .ULong => b.emitConst(.{ .ULong = @bitCast(lit.value) }),
                .Int => blk: {
                    if (lit.value >= std.math.minInt(i32) and lit.value <= std.math.maxInt(i32)) {
                        break :blk b.emitConst(.{ .Int = @intCast(lit.value) });
                    } else {
                        break :blk b.emitConst(.{ .Long = lit.value });
                    }
                },
            };
        },
        .FloatLit => |lit| return switch (lit.kind) {
            .Float => b.emitConst(.{ .Float = @floatCast(lit.value) }),
            .Double => b.emitConst(.{ .Double = lit.value }),
        },
        .BoolLit => |lit| return b.emitConst(.{ .Bool = lit.value }),
        .NullLit => return b.emitConst(.Null),
        .CharLit => |lit| return b.emitConst(.{ .Char = lit.value }),

        .Binary => |bin| return lowerBinary(b, bin),

        .Unary => |u| {
            // `-2147483648` parses as Neg(IntLit(2147483648)); the operand's
            // value doesn't fit in i32 so general IntLit-lowering would widen
            // to Long. Special-case Int.MIN_VALUE so it stays Int.
            if (u.op == .Neg and u.expr.* == .IntLit) {
                const il = u.expr.IntLit;
                if (il.kind == .Int and il.value == @as(i64, std.math.maxInt(i32)) + 1) {
                    return b.emitConst(.{ .Int = std.math.minInt(i32) });
                }
            }
            // Prefix ++ / -- need both an Inc/Dec UnOp AND a write-back to
            // the lvalue; return the NEW value.
            if (u.op == .PreInc or u.op == .PreDec) {
                const operand = try lowerExpr(b, u.expr);
                const dst = b.allocReg();
                const uo: UnOp = if (u.op == .PreInc) .Inc else .Dec;
                try b.push(.{ .UnOp = .{ .dst = dst, .op = uo, .operand = operand } });
                try writeBackLvalue(b, u.expr, dst);
                return dst;
            }
            const operand = try lowerExpr(b, u.expr);
            const dst = b.allocReg();
            switch (u.op) {
                .Not => try b.push(.{ .Not = .{ .dst = dst, .src = operand } }),
                .Neg => try b.push(.{ .UnOp = .{ .dst = dst, .op = .Neg, .operand = operand } }),
                .Pos => try b.push(.{ .UnOp = .{ .dst = dst, .op = .Plus, .operand = operand } }),
                .PreInc, .PreDec => unreachable,
            }
            return dst;
        },
        .If => |f| {
            // A single destination register both arms write into via Move
            // before jumping to the join.
            const cond_r = try lowerExpr(b, f.cond);
            const t_block = try b.allocBlock();
            const f_block = try b.allocBlock();
            const join = try b.allocBlock();
            const dst = b.allocReg();
            b.terminate(.{ .Branch = .{ .cond = cond_r, .t = t_block, .f = f_block } });
            // Then arm.
            b.switchTo(t_block);
            const t_val = try lowerExpr(b, f.then_branch);
            try b.push(.{ .Move = .{ .dst = dst, .src = t_val } });
            b.terminate(.{ .Goto = join });
            // Else arm.
            b.switchTo(f_block);
            const f_val = if (f.else_branch) |e| try lowerExpr(b, e) else try b.emitConst(.Unit);
            try b.push(.{ .Move = .{ .dst = dst, .src = f_val } });
            b.terminate(.{ .Goto = join });
            b.switchTo(join);
            return dst;
        },
        .Block => |block| return lowerBlock(b, &block),
        .Path => return lowerPath(b, expr),
        .StringTemplate => |st| return lowerStringTemplate(b, st.parts),
        .While => |w| {
            const header = try b.allocBlock();
            const body_blk = try b.allocBlock();
            const exit = try b.allocBlock();
            b.terminate(.{ .Goto = header });

            b.switchTo(header);
            const c = try lowerExpr(b, w.cond);
            b.terminate(.{ .Branch = .{ .cond = c, .t = body_blk, .f = exit } });

            b.switchTo(body_blk);
            try b.pushLoop(null, header, exit);
            _ = try lowerExpr(b, w.body);
            b.popLoop();
            b.terminate(.{ .Goto = header });

            b.switchTo(exit);
            return b.emitConst(.Unit);
        },
        .Member => return lowerMember(b, expr),
        .Index => |ix| {
            // `r[a, b, ...]` → r.get(a, b, ...).
            const recv = try lowerReceiver(b, ix.receiver);
            const run = try lowerArgRun(b, ix.args);
            const dst = b.allocReg();
            const nm = try b.module.internConst(b.allocator, .{ .String = "get" });
            try b.push(.{ .CallMember = .{
                .dst = dst,
                .receiver = recv,
                .name = nm,
                .args = run[0],
                .n_args = run[1],
                .arg_names = &.{},
            } });
            return dst;
        },
        .Call => return lowerCall(b, expr),
        .DoWhile => |w| {
            const body_blk = try b.allocBlock();
            const exit = try b.allocBlock();
            b.terminate(.{ .Goto = body_blk });

            b.switchTo(body_blk);
            try b.pushLoop(null, body_blk, exit);
            // Kotlin scopes the do-body's declarations into the `while`
            // condition; when the body is a block, lower its statements and the
            // condition in one shared scope so `do { val x = … } while (x …)`
            // resolves `x` instead of treating it as a stray global.
            if (w.body) |body| {
                if (body.* == .Block) {
                    const block = &body.Block;
                    try b.pushScope();
                    try hoistMutualLocalFns(b, block);
                    for (block.stmts) |*stmt| _ = try lowerStmt(b, stmt);
                    b.popLoop();
                    const c = try lowerExpr(b, w.cond);
                    try b.popScope();
                    b.terminate(.{ .Branch = .{ .cond = c, .t = body_blk, .f = exit } });
                    b.switchTo(exit);
                    return b.emitConst(.Unit);
                }
                _ = try lowerExpr(b, body);
            }
            b.popLoop();
            const c = try lowerExpr(b, w.cond);
            b.terminate(.{ .Branch = .{ .cond = c, .t = body_blk, .f = exit } });

            b.switchTo(exit);
            return b.emitConst(.Unit);
        },
        .Return => return lowerReturn(b, expr),
        .Throw => |t| {
            const r = try lowerExpr(b, t.value);
            b.terminate(.{ .Throw = r });
            const dead = try b.allocBlock();
            b.switchTo(dead);
            return b.emitConst(.Unit);
        },
        .When => |w| {
            // `when (val v = subject) { ... }` binds `v` to the subject's
            // value so pattern arms can refer to it.
            if (w.subject != null and w.subject_binding != null) {
                try b.pushScope();
                const sv = try lowerExpr(b, w.subject.?);
                try b.bind(w.subject_binding.?.name.name, sv);
                // The subject is evaluated exactly once: the bound register
                // doubles as the when's subject (re-lowering would re-run a
                // side-effecting subject like a queue poll).
                const r = try when_expr.lowerWhenWithSubjectReg(b, w.subject, sv, w.branches, exprSpan(expr));
                try b.popScope();
                return r;
            }
            return lowerWhen(b, w.subject, w.branches, exprSpan(expr));
        },
        .Try => return lowerTry(b, expr),
        .Lambda => return lowerLambda(b, expr),
        .Break => |brk| {
            const lbl: ?[]const u8 = if (brk.label) |i| i.name else null;
            if (b.loopFor(lbl)) |frame| {
                b.terminate(.{ .Goto = frame.break_target });
                const dead = try b.allocBlock();
                b.switchTo(dead);
            } else {
                try b.push(.{ .Trace = .{ .span = exprSpan(expr) } });
            }
            return b.emitConst(.Unit);
        },
        .Continue => |cont| {
            const lbl: ?[]const u8 = if (cont.label) |i| i.name else null;
            if (b.loopFor(lbl)) |frame| {
                b.terminate(.{ .Goto = frame.continue_target });
                const dead = try b.allocBlock();
                b.switchTo(dead);
            } else {
                try b.push(.{ .Trace = .{ .span = exprSpan(expr) } });
            }
            return b.emitConst(.Unit);
        },
        .For => |f| return lowerFor(b, f.vars, f.iter, f.body),
        .IsCheck => |ck| {
            const s = try lowerExpr(b, ck.expr);
            const dst = b.allocReg();
            try b.push(.{ .InstanceOf = .{
                .dst = dst,
                .src = s,
                .ty = .{ .name = loweredTypeName(b, &ck.ty), .nullable = ck.ty.nullable, .args = &.{} },
            } });
            if (ck.negated) {
                const neg = b.allocReg();
                try b.push(.{ .Not = .{ .dst = neg, .src = dst } });
                return neg;
            }
            return dst;
        },
        .As => |cast| {
            const s = try lowerExpr(b, cast.expr);
            const dst = b.allocReg();
            try b.push(.{ .Cast = .{
                .dst = dst,
                .src = s,
                .ty = .{ .name = loweredTypeName(b, &cast.ty), .nullable = cast.ty.nullable, .args = &.{} },
                .safe = cast.safe,
            } });
            return dst;
        },
        .Postfix => return lowerPostfix(b, expr),
        .Labeled => return lowerLabeled(b, expr),
        .PropertyRef => |pr| {
            // `::greet` — a registered top-level fn loads the function value;
            // a tracked local / top-level prop keeps the unbound PropertyRef;
            // an untracked own-receiver member binds a MemberRef. The symbol
            // index resolves the name from this file's package and imports,
            // and a unique pick is carried as an exact identity — a class
            // first (`::Ctor`; the runtime gives a class value precedence
            // over a same-named function), then a non-extension function —
            // so a same-simple-name declaration from another package cannot
            // swap in at runtime. Deferred shapes (overload sets, extension
            // forms) keep the name-keyed emission.
            const dst = b.allocReg();
            const nm = try b.module.internConst(b.allocator, .{ .String = pr.name.name });
            // `::localFn` names a local function, which is lowered to a closure
            // value bound to a register. The reference loads that closure — it
            // is the referenced callable, not an unbound property of whatever
            // the use site later applies it to.
            if (b.isLocalFn(pr.name.name)) {
                if (b.resolve(pr.name.name)) |reg| {
                    try b.push(.{ .Move = .{ .dst = dst, .src = reg } });
                    return dst;
                }
            }
            const is_tracked = b.resolve(pr.name.name) != null or isTopLevelProp(pr.name.name);
            // A same-named enclosing member only shadows the global for `::name`
            // when it could actually be the referenced callable: if the use
            // site expects a specific arity (a function-typed parameter slot)
            // and the member cannot accept it, the global wins — e.g.
            // `propagateOf2(::minOf, …)` from a `@Test fun minOf()` references
            // the stdlib `minOf`, not the zero-arg test method.
            const ref_arity = b.pending_lambda_arity;
            const member_shadows_ref = enclosingDeclaresMember(b, pr.name.name) and
                (ref_arity < 0 or b.ownMemberApplicable(pr.name.name, @intCast(ref_arity)));
            const class_pick: ?ir.ClassId = b.module.classIdIndexed(pr.name.name, b.self_package, pr.name.span.file);
            const ref_pick: ?FuncId = if (class_pick != null)
                null
            else
                b.module.resolveBareRefIndexed(pr.name.name, b.self_package, pr.name.span.file);
            refAudit(b, pr.name.name, ref_pick);
            // A callable reference whose only declaration is in an
            // unimported package is unresolved (kotlinc rejects `::name` /
            // `::Ctor` the same as a bare call to it). Record the
            // diagnostic before binding the lenient pick.
            if (class_pick) |cid| {
                _ = try recordOutOfScopeRef(b, pr.name.name, pr.name.span, classFqnOf(b, cid), b.module.classRefTier(pr.name.name, b.self_package, pr.name.span.file));
            } else if (ref_pick) |fid| {
                _ = try recordOutOfScopeRef(b, pr.name.name, pr.name.span, fqnOf(b, fid), b.module.bareRefTier(pr.name.name, b.self_package, pr.name.span.file));
            }
            // `::name` in a slot whose declared function type is written
            // entirely in the callee's type parameters
            // (`totalOrderMinOf2<Comparable<Any>>(::minOf)` against
            // `f2t: (T, T) -> T`) denotes the GENERIC overload: kotlinc
            // substitutes the call-site type argument, so only the generic
            // candidate is applicable. Bind the reference by id; a numeric
            // or otherwise-typed slot keeps the plain alias/global forms.
            if (class_pick == null and ref_pick == null and b.pending_ref_fn_generic and
                !member_shadows_ref and ref_arity >= 0)
            {
                if (genericRefTarget(b, pr.name.name, @intCast(ref_arity))) |fid| {
                    const fqn_n = if (b.module.funcById(fid)) |f|
                        try b.module.internConst(b.allocator, .{ .String = f.fqn })
                    else
                        nm;
                    try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = fqn_n, .func = fid } });
                    return dst;
                }
            }
            if (class_pick) |cid| {
                try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = nm, .class = cid, .ctor_ref = true } });
            } else if (ref_pick) |fid| {
                const n = blk: {
                    if (b.module.funcById(fid)) |f| {
                        break :blk try b.module.internConst(b.allocator, .{ .String = f.fqn });
                    }
                    break :blk nm;
                };
                try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = n, .func = fid } });
            } else if (b.module.funcId(pr.name.name) != null or b.module.classId(pr.name.name) != null) {
                try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = nm } });
            } else if (ir.isAliasName(pr.name.name) and !member_shadows_ref) {
                // `::minOf` / `::maxOf` / `::listOf` … name a stdlib host
                // intrinsic. A bare `LoadGlobal` resolves it to its
                // `.Intrinsic` callable value; binding it to the enclosing
                // `this` (the `!is_tracked` branch below) would emit a
                // `this.<name>` member ref that misses at runtime. The member
                // test is scoped to the ENCLOSING class's hierarchy — a
                // program-wide member-name set is poisoned by an unrelated
                // sibling class that happens to declare a `minOf`/`maxOf`
                // `@Test`, which `::minOf` here can never refer to.
                try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = nm } });
            } else if (!is_tracked) {
                if (try resolveThisReg(b)) |this_reg| {
                    try b.push(.{ .MemberRef = .{ .dst = dst, .receiver = this_reg, .name = nm } });
                } else {
                    try b.push(.{ .PropertyRef = .{ .dst = dst, .name = nm } });
                }
            } else {
                try b.push(.{ .PropertyRef = .{ .dst = dst, .name = nm } });
            }
            return dst;
        },
        .MemberRef => |mr| {
            // `String::countVowels` where the member names an in-scope
            // LOCAL extension function: kotlinc resolves the reference to
            // that local, not to a member of the type. The local lowered
            // as a closure bound to its name; the closure takes the
            // receiver as its first param, exactly the callable shape a
            // `Type::ext` reference must have.
            if (!std.mem.eql(u8, mr.name.name, "class") and
                mr.receiver.* == .Path and mr.receiver.Path.segments.len == 1 and
                b.isLocalExtFn(mr.name.name))
            {
                if (b.resolve(mr.name.name)) |r| return r;
                if (b.knowsOuter(mr.name.name)) {
                    const idx = try b.recordCapture(mr.name.name);
                    const dst = b.allocReg();
                    try b.push(.{ .LoadCapture = .{ .dst = dst, .idx = idx } });
                    return dst;
                }
            }
            // `Outer::Nested` where `Nested` is a class is a constructor
            // reference, not a bound member ref — load the class value.
            if (!std.mem.eql(u8, mr.name.name, "class") and
                mr.receiver.* == .Path and
                b.module.classId(mr.name.name) != null)
            {
                const dst = b.allocReg();
                const nm = try b.module.internConst(b.allocator, .{ .String = mr.name.name });
                try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = nm } });
                return dst;
            }
            // `X::member` where `X` is a bare type/constructor name that has
            // no IR classId (e.g. an unsigned array `ULongArray`) must load
            // the type reference directly. Routing it through
            // `lowerReceiver` -> the implicit-`this` path inside a method
            // would emit `this.X(...)` and invoke the constructor instead of
            // taking the type value (`UIntArray::copyInto` inside a test
            // class constructed a UIntArray from the ref's first use).
            if (mr.receiver.* == .Path and mr.receiver.Path.segments.len == 1) {
                const rn = mr.receiver.Path.segments[0].name;
                if (b.resolve(rn) == null and !b.knowsOuter(rn) and
                    b.module.classId(rn) == null and !b.hasOwnMember(rn) and
                    !isTopLevelProp(rn))
                {
                    const rr = b.allocReg();
                    const rnm = try b.module.internConst(b.allocator, .{ .String = rn });
                    try b.push(.{ .LoadGlobal = .{ .dst = rr, .name = rnm } });
                    const dst = b.allocReg();
                    const cnm = try b.module.internConst(b.allocator, .{ .String = mr.name.name });
                    try b.push(.{ .MemberRef = .{ .dst = dst, .receiver = rr, .name = cnm } });
                    return dst;
                }
            }
            const recv = try lowerReceiver(b, mr.receiver);
            const dst = b.allocReg();
            const nm = try b.module.internConst(b.allocator, .{ .String = mr.name.name });
            try b.push(.{ .MemberRef = .{ .dst = dst, .receiver = recv, .name = nm } });
            return dst;
        },
        .ObjectExpr => {
            // Anonymous-object expressions carry rich AST shape; emit a
            // `BuildObject` Inst whose host synthesises a fresh ClassDef
            // with the snapshotted env on each call.
            var outer_names = try b.visibleNames();
            defer outer_names.deinit();
            const captured_names = try setToSlice(b.allocator, &outer_names);
            const captures = try b.allocator.alloc(Reg, captured_names.len);
            for (captured_names, captures) |n, *c| c.* = try resolveCapture(b, n);
            const dst = b.allocReg();
            const ast_box = try b.allocator.create(Expr);
            ast_box.* = expr.*;
            try b.push(.{ .BuildObject = .{
                .dst = dst,
                .ast = runtime.forest.ForestField(Expr).fromPtr(ast_box),
                .captured_names = captured_names,
                .captures = captures,
                .scope_renames = try collectScopeRenames(b, expr.ObjectExpr.span.file.int()),
            } });
            return dst;
        },
        .AnonFun => return lowerAnonFun(b, expr),
        .This => |t| {
            if (t.qualifier) |q| {
                // A labeled receiver `this@fn` for an enclosing (extension)
                // function: resolve / capture the `this@<fn>` slot bound at
                // that function's entry — possibly through nested lambdas — so
                // it is the function's receiver, not the lambda's own `this`.
                const label = try std.fmt.allocPrint(b.allocator, "this@{s}", .{q.name});
                if (b.resolve(label)) |r| return r;
                if (b.knowsOuter(label)) {
                    const idx = try b.recordCapture(label);
                    const dst2 = b.allocReg();
                    try b.push(.{ .LoadCapture = .{ .dst = dst2, .idx = idx } });
                    try b.bind(label, dst2);
                    return dst2;
                }
                // The enclosing ANON OBJECT closed over the labeled
                // receiver (`this@minus` inside an anon method): read the
                // capture. The class-label walk below would resolve to the
                // anon instance itself. No scope bind: a read inside a
                // conditional branch must not cache its register for reads
                // on paths where the branch never ran.
                if (decl_mod.isLowerAnonCapture(label)) {
                    const idx = try b.recordCapture(label);
                    const dst2 = b.allocReg();
                    try b.push(.{ .LoadCapture = .{ .dst = dst2, .idx = idx } });
                    return dst2;
                }
                // Otherwise a class-name label (`this@Outer`): walk at runtime
                // from the nearest `this` over the class/outer chain.
                const this_reg = b.resolve("this") orelse blk: {
                    const idx = try b.recordCapture("this");
                    const dst = b.allocReg();
                    try b.push(.{ .LoadCapture = .{ .dst = dst, .idx = idx } });
                    break :blk dst;
                };
                const nm = try b.module.internConst(b.allocator, .{ .String = q.name });
                const dst = b.allocReg();
                try b.push(.{ .QualifiedThis = .{ .dst = dst, .receiver = this_reg, .qualifier = nm } });
                return dst;
            }
            // `this` bare resolves to the implicit first param, or the
            // captured `this` slot inside a lambda body.
            const this_reg = b.resolve("this") orelse blk: {
                const idx = try b.recordCapture("this");
                const dst = b.allocReg();
                try b.push(.{ .LoadCapture = .{ .dst = dst, .idx = idx } });
                break :blk dst;
            };
            return this_reg;
        },
        .Super => {
            // `super` bare reads the same instance value as `this`.
            if (b.resolve("this")) |this_reg| return this_reg;
            try b.push(.{ .Trace = .{ .span = exprSpan(expr) } });
            return b.emitConst(.Unit);
        },
        .Spread => {
            // A bare spread outside a call argument list has no lowering yet.
            try b.push(.{ .Trace = .{ .span = exprSpan(expr) } });
            return b.emitConst(.Unit);
        },
    }
}

/// `Binary` lowering: the short-circuiting operators (`&&`, `||`, `?:`),
/// the `in`/`!in` desugars, generic-operand comparisons, and the eager
/// primitive operators.
fn lowerBinary(b: *FuncBuilder, bin: anytype) Allocator.Error!Reg {
    const op = bin.op;
    const lhs = bin.lhs;
    const rhs = bin.rhs;

    // `==` on a boxed operand (an `Any`-typed or generic type-parameter value,
    // e.g. `assertEquals(expected: T, actual: T)`) uses total-order equality —
    // `NaN == NaN` is true and `0.0 != -0.0`, matching boxed `Double.equals`.
    if ((op == .Eq or op == .Neq) and
        (isBoxedToAnyForm(lhs) or isBoxedToAnyForm(rhs) or
            isAnyTypedPath(b, lhs) or isAnyTypedPath(b, rhs) or
            isGenericTypedPath(b, lhs) or isGenericTypedPath(b, rhs)))
    {
        const l = try lowerExpr(b, lhs);
        const r = try lowerExpr(b, rhs);
        const dst = b.allocReg();
        const ir_op: BinOp = if (op == .Eq) .BoxedEq else .BoxedNotEq;
        try b.push(.{ .BinOp = .{ .dst = dst, .op = ir_op, .lhs = l, .rhs = r } });
        return dst;
    }

    // `x in haystack` / `x !in haystack`.
    if (op == .In or op == .NotIn) {
        // `x in lo..hi` / `x in lo..<hi` with a range *literal* on the right
        // lowers to `lo <= x && x <(=) hi`.
        if (rhs.* == .Binary and (rhs.Binary.op == .Range or rhs.Binary.op == .RangeUntil)) {
            const r_op = rhs.Binary.op;
            const lo = rhs.Binary.lhs;
            const hi = rhs.Binary.rhs;
            const x = try lowerExpr(b, lhs);
            const lo_r = try lowerExpr(b, lo);
            const hi_r = try lowerExpr(b, hi);
            const ge = b.allocReg();
            try b.push(.{ .BinOp = .{ .dst = ge, .op = .LessEq, .lhs = lo_r, .rhs = x } });
            const upper: BinOp = if (r_op == .RangeUntil) .Less else .LessEq;
            const le = b.allocReg();
            try b.push(.{ .BinOp = .{ .dst = le, .op = upper, .lhs = x, .rhs = hi_r } });
            const both = b.allocReg();
            try b.push(.{ .BinOp = .{ .dst = both, .op = .And, .lhs = ge, .rhs = le } });
            if (op == .NotIn) {
                const dst = b.allocReg();
                try b.push(.{ .Not = .{ .dst = dst, .src = both } });
                return dst;
            }
            return both;
        }
        const recv = try lowerExpr(b, rhs);
        const arg_slot = b.allocReg();
        const l = try lowerExpr(b, lhs);
        try b.push(.{ .Move = .{ .dst = arg_slot, .src = l } });
        const contains = b.allocReg();
        const nm = try b.module.internConst(b.allocator, .{ .String = "contains" });
        try b.push(.{ .CallMember = .{
            .dst = contains,
            .receiver = recv,
            .name = nm,
            .args = arg_slot,
            .n_args = 1,
            .arg_names = &.{},
        } });
        if (op == .NotIn) {
            const dst = b.allocReg();
            try b.push(.{ .Not = .{ .dst = dst, .src = contains } });
            return dst;
        }
        return contains;
    }

    // Elvis `a ?: b` short-circuits.
    if (op == .Elvis) {
        const l = try lowerExpr(b, lhs);
        const null_r = try b.emitConst(.Null);
        const is_null = b.allocReg();
        try b.push(.{ .BinOp = .{ .dst = is_null, .op = .Eq, .lhs = l, .rhs = null_r } });
        const then_b = try b.allocBlock();
        const else_b = try b.allocBlock();
        const join = try b.allocBlock();
        const dst = b.allocReg();
        b.terminate(.{ .Branch = .{ .cond = is_null, .t = then_b, .f = else_b } });
        b.switchTo(then_b);
        const rv = try lowerExpr(b, rhs);
        try b.push(.{ .Move = .{ .dst = dst, .src = rv } });
        b.terminate(.{ .Goto = join });
        b.switchTo(else_b);
        try b.push(.{ .Move = .{ .dst = dst, .src = l } });
        b.terminate(.{ .Goto = join });
        b.switchTo(join);
        return dst;
    }

    // Logical `&&` / `||`.
    if (op == .And or op == .Or) {
        const l = try lowerExpr(b, lhs);
        const then_b = try b.allocBlock();
        const else_b = try b.allocBlock();
        const join = try b.allocBlock();
        const dst = b.allocReg();
        b.terminate(.{ .Branch = .{ .cond = l, .t = then_b, .f = else_b } });
        if (op == .And) {
            b.switchTo(then_b);
            const rv = try lowerExpr(b, rhs);
            try b.push(.{ .Move = .{ .dst = dst, .src = rv } });
            b.terminate(.{ .Goto = join });
            b.switchTo(else_b);
            const false_r = try b.emitConst(.{ .Bool = false });
            try b.push(.{ .Move = .{ .dst = dst, .src = false_r } });
            b.terminate(.{ .Goto = join });
        } else {
            b.switchTo(then_b);
            const true_r = try b.emitConst(.{ .Bool = true });
            try b.push(.{ .Move = .{ .dst = dst, .src = true_r } });
            b.terminate(.{ .Goto = join });
            b.switchTo(else_b);
            const rv = try lowerExpr(b, rhs);
            try b.push(.{ .Move = .{ .dst = dst, .src = rv } });
            b.terminate(.{ .Goto = join });
        }
        b.switchTo(join);
        return dst;
    }

    // Comparison on a generic type-parameter operand → `a.compareTo(b) <op> 0`.
    // Inside a function that declares its own type parameters, an operand
    // with no concrete static type (`var min = iterator.next()` in the
    // generic `minOrNull` body) is `T`-typed under Kotlin's inference, so
    // the comparison also follows the `compareTo` total order — the IEEE
    // primitive comparison applies only where a numeric static type is
    // established (a literal, or a local with a numeric declared type or
    // literal initializer).
    if ((op == .Lt or op == .Le or op == .Gt or op == .Ge) and
        (isGenericOperand(b, lhs) or isGenericOperand(b, rhs) or
            (b.hasOwnTypeParams() and
                !staticallyOrderedOperand(b, lhs) and !staticallyOrderedOperand(b, rhs))))
    {
        const recv = try lowerExpr(b, lhs);
        const arg_slot = b.allocReg();
        const r = try lowerExpr(b, rhs);
        try b.push(.{ .Move = .{ .dst = arg_slot, .src = r } });
        const cmp = b.allocReg();
        const nm = try b.module.internConst(b.allocator, .{ .String = "compareTo" });
        try b.push(.{ .CallMember = .{
            .dst = cmp,
            .receiver = recv,
            .name = nm,
            .args = arg_slot,
            .n_args = 1,
            .arg_names = &.{},
        } });
        const zero = try b.emitConst(.{ .Int = 0 });
        const dst = b.allocReg();
        try b.push(.{ .BinOp = .{ .dst = dst, .op = astBinop(op), .lhs = cmp, .rhs = zero } });
        return dst;
    }

    const l0 = try lowerExpr(b, lhs);
    // `it + x` / `it - x` where `it` is statically a broad collection
    // (`Iterable`/`Collection`) produces a `List` even when the runtime value
    // is a `Set`; coerce the receiver to a list so the `List`-returning
    // `plus`/`minus` is dispatched rather than the `Set`-returning one.
    const l = if (op == .Add or op == .Sub)
        try helpers.coerceBroadCollectionToList(b, lhs, l0)
    else
        l0;
    const r = try lowerExpr(b, rhs);
    const dst = b.allocReg();
    try b.push(.{ .BinOp = .{ .dst = dst, .op = astBinop(op), .lhs = l, .rhs = r } });
    return dst;
}

fn isGenericOperand(b: *FuncBuilder, e: *const Expr) bool {
    return e.* == .Path and e.Path.segments.len == 1 and
        b.isGenericTypedParam(e.Path.segments[0].name);
}

/// A comparison operand with an established concrete static type: a literal,
/// or a plain local/param whose declared type is a known builtin value head
/// or whose recorded initializer is a literal. Such an operand keeps the
/// primitive `BinOp` comparison inside a generic function; everything else
/// there is `T`-typed under Kotlin's inference and dispatches `compareTo`.
fn staticallyOrderedOperand(b: *FuncBuilder, e: *const Expr) bool {
    if (argLitKind(e) != null) return true;
    if (e.* == .Path and e.Path.segments.len == 1) {
        const n = e.Path.segments[0].name;
        if (b.localDeclType(n)) |t| return paramLitKind(t) != null;
        if (b.localInitExpr(n)) |ie| return argLitKind(ie) != null;
    }
    return false;
}

/// Write `val` back to the lvalue `target` (shared by prefix ++/-- and the
/// postfix path's pre-snapshot path). Delegates to the single write-back
/// decision in `stmt_mod.storeCombinedToTarget` so compound-assign, prefix,
/// and postfix never diverge on where a bare name lands (local / cell /
/// capture / own-member / lambda-this / top-level global).
fn writeBackLvalue(b: *FuncBuilder, target: *const Expr, val: Reg) Allocator.Error!void {
    try stmt_mod.storeCombinedToTarget(b, target, val);
}

/// A bare `name` an enclosing class declares as a value member (an enclosing
/// companion's `Default`) shadows an unrelated global classifier of the same
/// simple name. True when `name` is an enclosing member and is NOT a nested
/// Whether `name` is a known class that has a registered companion object.
/// Such a name in value position is its companion singleton (Kotlin: `C`
/// yields `C.Companion`), which must win over a folded classifier name that
/// would otherwise route the read to a non-existent `this.<name>` field.
fn classWithCompanion(b: *const FuncBuilder, name: []const u8) bool {
    return b.module.classId(name) != null and
        b.module.registry.companion_singletons.contains(name);
}

/// type reachable along the enclosing-owner chain (a nested type keeps the
/// classifier path so it names a class value).
fn enclosingMemberShadowsClass(b: *const FuncBuilder, name: []const u8) bool {
    if (!b.hasEnclosingMember(name)) return false;
    var owner = b.ownerClass();
    var hops: usize = 0;
    while (owner) |o| : (hops += 1) {
        if (hops > 32) break;
        if (b.module.registry.nested_object_aliases.get(o)) |m| {
            if (m.contains(name)) return false;
        }
        owner = b.module.registry.enclosing_class.get(o);
    }
    return true;
}

/// The mangled lift name a type reference `name` resolves to in the
/// current scope: a (mangled) nested class/object aliased anywhere along
/// the enclosing-class chain — Kotlin makes a private nested class
/// visible throughout its declaring class's subtree, and a lifted
/// sibling/nested member keeps the outer on its chain — or a renamed
/// file-private class/typealias declared by the reference's own file.
/// Returns null when no rename applies.
pub fn scopeTypeRename(b: *const FuncBuilder, name: []const u8, file: u32) ?[]const u8 {
    var owner = b.ownerClass();
    var hops: usize = 0;
    while (owner) |o| : (hops += 1) {
        if (hops > 32) break;
        if (b.module.registry.nested_object_aliases.get(o)) |m| {
            if (m.get(name)) |renamed| return renamed;
        }
        owner = b.module.registry.enclosing_class.get(o);
    }
    // An anon-object member body lowering at runtime carries its lexical
    // site's flattened renames (the side module's registries are empty).
    if (build.anonScopeRename(name)) |renamed| return renamed;
    return build.fileTypeRename(name, file);
}

/// Flatten every scope-true type rename visible at the current lexical
/// site — the enclosing-class chain's alias maps (nearest scope first),
/// the anon-scope renames when this site itself sits inside an anon-object
/// body lowering, and the declaring file's file-private type renames —
/// into one slice for a `BuildObject` instruction. First entry per name
/// wins on lookup, so nearer scopes shadow outer ones.
fn collectScopeRenames(b: *FuncBuilder, file: u32) Allocator.Error![]const ir.ScopeRename {
    var out: std.ArrayList(ir.ScopeRename) = .empty;
    var owner = b.ownerClass();
    var hops: usize = 0;
    while (owner) |o| : (hops += 1) {
        if (hops > 32) break;
        if (b.module.registry.nested_object_aliases.get(o)) |m| {
            var it = m.iterator();
            while (it.next()) |e| {
                try out.append(b.allocator, .{ .name = e.key_ptr.*, .renamed = e.value_ptr.* });
            }
        }
        owner = b.module.registry.enclosing_class.get(o);
    }
    for (build.anonScopeRenames()) |r| try out.append(b.allocator, r);
    if (build.fileTypeRenamesFor(file)) |m| {
        var it = m.iterator();
        while (it.next()) |e| {
            try out.append(b.allocator, .{ .name = e.key_ptr.*, .renamed = e.value_ptr.* });
        }
    }
    return out.toOwnedSlice(b.allocator);
}

/// Reduce a dotted path to its last two segments (`a.b.C` -> `b.C`);
/// null when the path has fewer than two.
fn lastTwoSegments(path: []const u8) ?[]const u8 {
    var last: ?usize = null;
    var prev: ?usize = null;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] == '.') {
            prev = last;
            last = i;
        }
    }
    if (last == null) return null;
    const start = if (prev) |p| p + 1 else 0;
    return path[start..];
}

/// The lowered name for a type position (`as T` / `is T` / catch type):
/// a qualified nested reference (`Outer.Inner`) whose target the lift
/// mangled resolves to the mangled lift name, then the scope-true
/// rename ladder (`scopeTypeRename`), then the bare simple name.
pub fn loweredTypeName(b: *const FuncBuilder, ty: *const ast.TypeRef) []const u8 {
    if (ty.qualified_path) |qp| {
        if (lastTwoSegments(qp)) |key| {
            if (b.module.registry.mangled_nested.get(key)) |m| return m;
        }
    }
    return scopeTypeRename(b, ty.name.name, ty.span.file.int()) orelse ty.name.name;
}

/// The mangled per-file global for a bare `name` referenced from the file
/// `file`, or null when the reference is not a read of a renamed
/// file-private top-level property. Locals, lambda/anon-object captures,
/// and own class members shadow the property (Kotlin scope order), so the
/// rename only applies when none of them bind the name.
pub fn filePrivatePropRename(b: *FuncBuilder, name: []const u8, file: u32) ?[]const u8 {
    const renamed = build.filePrivateRename(name, file) orelse return null;
    if (b.resolve(name) != null) return null;
    if (b.knowsOuter(name)) return null;
    if (decl_mod.isLowerAnonCapture(name)) return null;
    if (b.hasOwnMember(name)) return null;
    return renamed;
}

/// `Path` lowering — the full bare-name resolution ladder.
fn lowerPath(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    const segments = expr.Path.segments;
    const span0 = expr.Path.span;

    // File-private top-level property rename: a bare reference from the
    // declaring file resolves to the per-file mangled global. Locals,
    // captures, and own members keep shadowing it (Kotlin scope order).
    if (filePrivatePropRename(b, segments[0].name, segments[0].span.file.int())) |renamed| {
        const new_segs = try b.allocator.dupe(ast.Ident, segments);
        defer b.allocator.free(new_segs);
        new_segs[0] = .{ .name = renamed, .span = segments[0].span };
        const rewritten = Expr{ .Path = .{ .segments = new_segs, .span = span0 } };
        return lowerExpr(b, &rewritten);
    }

    // `const val name = <literal>` inline.
    if (segments.len == 1 and b.ownerClass() != null and b.resolve(segments[0].name) == null) {
        const owner = b.ownerClass().?;
        if (b.module.registry.class_const_inits.get(.{ .a = owner, .b = segments[0].name })) |c| {
            return b.emitConst(c);
        }
    }
    // Mangled nested-class/object alias and file-private type rewrite.
    {
        const renamed = scopeTypeRename(b, segments[0].name, segments[0].span.file.int());
        if (renamed != null and b.resolve(segments[0].name) == null) {
            const new_segs = try b.allocator.dupe(ast.Ident, segments);
            defer b.allocator.free(new_segs);
            new_segs[0] = .{ .name = renamed.?, .span = segments[0].span };
            const rewritten = Expr{ .Path = .{ .segments = new_segs, .span = span0 } };
            return lowerExpr(b, &rewritten);
        }
    }

    if (segments.len == 1) {
        const name0 = segments[0].name;
        // Bare `Unit` is the Unit singleton value.
        if (std.mem.eql(u8, name0, "Unit") and b.resolve("Unit") == null) {
            return b.emitConst(.Unit);
        }
        if (b.resolve(name0)) |r| {
            if (b.isBoxed(name0)) {
                const dst = b.allocReg();
                try b.push(.{ .CellGet = .{ .dst = dst, .cell = r } });
                return dst;
            }
            return r;
        }
        // A bare read of a name the enclosing anon object closes over reads
        // the captured value.
        if (isLowerAnonCapture(name0)) {
            const idx = try b.recordCapture(name0);
            const cell = b.allocReg();
            try b.push(.{ .LoadCapture = .{ .dst = cell, .idx = idx } });
            if (b.isBoxed(name0)) {
                const dst = b.allocReg();
                try b.push(.{ .CellGet = .{ .dst = dst, .cell = cell } });
                return dst;
            }
            return cell;
        }
        // Lambda-body capture.
        if (b.knowsOuter(name0)) {
            const idx = try b.recordCapture(name0);
            const cell = b.allocReg();
            try b.push(.{ .LoadCapture = .{ .dst = cell, .idx = idx } });
            if (b.isBoxed(name0)) {
                const dst = b.allocReg();
                try b.push(.{ .CellGet = .{ .dst = dst, .cell = cell } });
                return dst;
            }
            return cell;
        }
        // An `it` written in a zero-parameter / receiver lambda whose
        // implicit `it` was suppressed, with no enclosing lambda supplying
        // one: kotlinc rejects this as an unresolved reference. Record the
        // diagnostic so the build driver fails the program before it runs.
        if (b.it_suppressed and std.mem.eql(u8, name0, "it")) {
            try b.module.resolve_diags.append(b.allocator, .{
                .name = "it",
                .fqn_a = "",
                .fqn_b = "",
                .span = segments[0].span,
                .kind = .unresolved_local,
            });
            return b.emitConst(.Unit);
        }
        // A bare `coroutineContext` member of the implicit receiver.
        if (std.mem.eql(u8, name0, "coroutineContext") and b.hasOwnMember("coroutineContext")) {
            if (b.resolve("this")) |this_reg| {
                const dst = b.allocReg();
                const field = try b.module.internConst(b.allocator, .{ .String = "$coroutineContext$explicit" });
                try b.push(.{ .GetField = .{ .dst = dst, .receiver = this_reg, .field = field } });
                return dst;
            }
        }
        // Member read on `this` via GetField when the owning class declares
        // this name. A companioned class name is excepted: it is its companion
        // singleton, resolved by the classifier sentinel below, not a field.
        if (b.hasOwnMember(name0) and !classWithCompanion(b, name0)) {
            if (b.resolve("this")) |this_reg| {
                const dst = b.allocReg();
                const nm = try sgetterName(b, name0);
                try b.push(.{ .GetField = .{ .dst = dst, .receiver = this_reg, .field = nm } });
                return dst;
            }
            // Superclass-ctor delegation thunk: a bare own-member is a
            // companion access.
            if (b.isParamThunk()) {
                if (b.ownerClass()) |owner| {
                    const cls = b.allocReg();
                    const on = try b.module.internConst(b.allocator, .{ .String = owner });
                    try b.push(.{ .LoadGlobal = .{ .dst = cls, .name = on } });
                    const dst = b.allocReg();
                    const nm = try b.module.internConst(b.allocator, .{ .String = name0 });
                    try b.push(.{ .GetField = .{ .dst = dst, .receiver = cls, .field = nm } });
                    return dst;
                }
            }
        }
        // A bare reference to the enclosing type's own companion object
        // (`Key` inside `interface I { companion object Key; … = Key }`)
        // resolves to that companion singleton via the qualified `I.Key`
        // form. Needed because a companion that has a supertype (e.g.
        // `companion object Key : CoroutineContext.Key<I>`) is also
        // registered as a classId under its simple name, which would
        // otherwise route the bare name to the class reference below
        // instead of the singleton.
        if (b.ownerClass()) |owner| {
            const comp_mangled: ?[]const u8 = b.module.registry.companion_singletons.get(owner);
            if (comp_mangled) |cm| {
                const simple = if (std.mem.lastIndexOfScalar(u8, cm, '$')) |i| cm[i + 1 ..] else cm;
                if (std.mem.eql(u8, simple, name0)) {
                    const sp = segments[0].span;
                    var rsegs = [_]ast.Ident{
                        .{ .name = owner, .span = sp },
                        .{ .name = name0, .span = sp },
                    };
                    const qualified = Expr{ .Path = .{ .segments = &rsegs, .span = sp } };
                    return lowerExpr(b, &qualified);
                }
            }
        }
        // A bare name that is a known class is a class reference. In a
        // receiver context a runtime receiver member shadows the
        // classifier (kotlinc: a property named like a class wins in
        // expression position), so the read decides at runtime with the
        // index-resolved class riding as the exact global arm; the
        // companion sentinel passes a member value through unchanged.
        if (b.module.classId(name0) != null and
            (!enclosingMemberShadowsClass(b, name0) or classWithCompanion(b, name0)))
        {
            const n = try b.module.internConst(b.allocator, .{ .String = name0 });
            const cls = b.allocReg();
            if (inReceiverContext(b)) {
                const this_idx = try b.recordCapture("this");
                orEmitAudit(b, "class_name_value", "LoadFromThisOrGlobal", name0);
                try b.push(.{ .LoadFromThisOrGlobal = .{
                    .dst = cls,
                    .this_idx = this_idx,
                    .name = n,
                    .class = scopedClassIdForRead(b, name0, segments[0].span.file),
                } });
            } else {
                orEmitAudit(b, "class_name_value", "LoadGlobal", name0);
                try b.push(.{ .LoadGlobal = .{
                    .dst = cls,
                    .name = n,
                    .class = scopedClassIdForRead(b, name0, segments[0].span.file),
                } });
            }
            const dst = b.allocReg();
            const sentinel = try b.module.internConst(b.allocator, .{ .String = "<class-companion-or-self>" });
            try b.push(.{ .GetField = .{ .dst = dst, .receiver = cls, .field = sentinel } });
            return dst;
        }
        // A bare builtin type name used as a qualifier. Outside any
        // receiver context no member can shadow it, so the read is a
        // static global.
        if (isBuiltinTypeName(name0)) {
            const name = try b.module.internConst(b.allocator, .{ .String = name0 });
            const dst = b.allocReg();
            if (inReceiverContext(b)) {
                const this_idx = try b.recordCapture("this");
                orEmitAudit(b, "builtin_type_name", "LoadFromThisOrGlobal", name0);
                try b.push(.{ .LoadFromThisOrGlobal = .{ .dst = dst, .this_idx = this_idx, .name = name } });
            } else {
                orEmitAudit(b, "builtin_type_name", "LoadGlobal", name0);
                try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = name } });
            }
            return dst;
        }
        // An imported member of a (possibly named) companion object →
        // rewrite to the qualified `C.MEMBER` companion access.
        if (b.resolve(name0) == null) {
            if (importCompanionRewrite(b, segments[0].span.file, name0)) |rw| {
                const sp = segments[0].span;
                var rsegs = [_]ast.Ident{
                    .{ .name = rw.cls, .span = sp },
                    .{ .name = rw.member, .span = sp },
                };
                const qualified = Expr{ .Path = .{ .segments = &rsegs, .span = sp } };
                return lowerExpr(b, &qualified);
            }
            // A member brought in bare by `import EnumOrObject.*`
            // (`import DurationUnit.*` → `MINUTES` == `DurationUnit.MINUTES`).
            // An implicit-receiver member shadows a star-import: a bare name
            // that is a member of `this` — or of any lexically enclosing
            // receiver, which is the case inside a lambda whose enclosing class
            // declares the name — resolves against that receiver, not the
            // star-imported class. `hasOwnMember` alone misses the lambda case
            // (a lambda body has no own class), so a bare `state` inside a
            // method's lambda was wrongly rewritten to `Enum.state`.
            // A same-scope top-level declaration also outranks a star-import:
            // a bare `STATE_COMPLETED` that names a top-level `val`/`fun` is
            // that declaration, not `Enum.STATE_COMPLETED` for some unrelated
            // `import Enum.*` whose enum does not even declare it (which would
            // wrongly qualify it onto the enum and read a bogus field).
            if (!b.hasEnclosingMember(name0) and !isTopLevelProp(name0) and b.module.funcId(name0) == null) {
                if (wildcardClassMemberRewrite(b, segments[0].span.file)) |cls| {
                    const sp = segments[0].span;
                    var rsegs = [_]ast.Ident{
                        .{ .name = cls, .span = sp },
                        .{ .name = name0, .span = sp },
                    };
                    const qualified = Expr{ .Path = .{ .segments = &rsegs, .span = sp } };
                    return lowerExpr(b, &qualified);
                }
            }
        }
        // A bare reference to a known top-level property is a global read
        // — unless a runtime implicit receiver could shadow it: kotlinc
        // resolves implicit-receiver members ahead of package-scope
        // properties, so where some class declares a member of this name
        // and a receiver is (or may be bound) in scope, the read decides
        // at runtime instead.
        if (isTopLevelProp(name0) and !b.hasOwnMember(name0) and !b.hasEnclosingMember(name0) and
            b.module.classIdExactImport(name0, segments[0].span.file) == null and
            !(inReceiverContext(b) and anyReceiverClassDeclares(b, name0)))
        {
            // A bare read whose only declaration is an unimported
            // cross-package property is unresolved (kotlinc rejects it).
            if (b.module.topLevelPropFqn(name0)) |pfqn| {
                _ = try recordOutOfScopeRef(b, name0, segments[0].span, pfqn, b.module.topLevelPropRefTier(name0, b.self_package, segments[0].span.file));
            }
            orEmitAudit(b, "top_level_prop", "LoadGlobal", name0);
            const dst = b.allocReg();
            const nm = try b.module.internConst(b.allocator, .{ .String = name0 });
            try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = nm } });
            return dst;
        }
        // Value-position bare reference to a top-level function, in a
        // context no receiver can shadow (no reachable `this`, no
        // enclosing member, no owner-class getter qualification): the
        // symbol index resolves it from the caller's scope and a unique
        // pick loads by exact FQN, so a same-simple-name function from
        // another package cannot swap in at runtime.
        if (!inReceiverContext(b) and
            !b.hasOwnMember(name0) and !b.hasEnclosingMember(name0) and !isTopLevelProp(name0))
        {
            const ref_pick = b.module.resolveBareRefIndexed(name0, b.self_package, segments[0].span.file);
            refAudit(b, name0, ref_pick);
            if (ref_pick) |fid| {
                if (b.module.funcById(fid)) |f| {
                    _ = try recordOutOfScopeRef(b, name0, segments[0].span, f.fqn, b.module.bareRefTier(name0, b.self_package, segments[0].span.file));
                    const dst = b.allocReg();
                    const n = try b.module.internConst(b.allocator, .{ .String = f.fqn });
                    try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = n, .func = fid } });
                    return dst;
                }
            }
        }
        if (b.resolve("this")) |this_reg| {
            // A bare name resolving to a known top-level fn is a
            // value-position function reference; skip the GetField shortcut.
            // A known top-level *property* skips it too: the shortcut's
            // lenient field resolution would adopt outer-chain members a
            // plain extension receiver does not lexically see — the
            // runtime walk below resolves member-vs-global with the right
            // receiver scope.
            const is_known_global = b.module.funcId(name0) != null or isTopLevelProp(name0);
            // Inside a lambda body the lexical `this` is the lambda's own
            // receiver, which for a scope function (`buildString { … }`,
            // `with(x) { … }`) is the scope receiver — not the enclosing class
            // instance. A bare read of an enclosing-class member must not bind
            // directly to that scope receiver: defer to the implicit-receiver
            // walk below, which carries the owner-qualified getter and tries
            // the scope receiver before the captured enclosing `this`. A member
            // the scope receiver itself owns still resolves there (it is the
            // innermost candidate), so a non-scope lambda is unaffected.
            const lambda_encl_member = b.isLambdaBody() and b.hasEnclosingMember(name0);
            if (!is_known_global and !lambda_encl_member) {
                const dst = b.allocReg();
                const nm = try b.module.internConst(b.allocator, .{ .String = name0 });
                try b.push(.{ .GetField = .{ .dst = dst, .receiver = this_reg, .field = nm } });
                return dst;
            }
        }
        // Outside any receiver context no member can shadow the name, so
        // the read is a static global (kotlinc rejects resolving it
        // against a caller's receiver).
        if (!inReceiverContext(b)) {
            orEmitAudit(b, "bare_name_fallthrough", "LoadGlobal", name0);
            const dst = b.allocReg();
            const nm = try b.module.internConst(b.allocator, .{ .String = name0 });
            try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = nm } });
            return dst;
        }
        const this_idx = try b.recordCapture("this");
        const dst = b.allocReg();
        const name = try sgetterName(b, name0);
        // The index's unique pick rides as the exact global arm; the
        // runtime member probe still runs first, and a runtime-scoped
        // shadowing capture re-routes to the name lookup.
        const ref_pick = b.module.resolveBareRefIndexed(name0, b.self_package, segments[0].span.file);
        orEmitAudit(b, "bare_name_fallthrough", "LoadFromThisOrGlobal", name0);
        try b.push(.{ .LoadFromThisOrGlobal = .{
            .dst = dst,
            .this_idx = this_idx,
            .name = name,
            .func = ref_pick,
        } });
        return dst;
    }

    // Multi-segment paths. Try the full FQN against the host first.
    if (segments.len >= 2 and
        isPackageHead(segments[0].name) and
        headIsPackage(b, segments[0].name) and
        b.resolve(segments[0].name) == null and
        !b.knowsOuter(segments[0].name) and
        !b.hasEnclosingMember(segments[0].name) and
        b.module.classId(segments[0].name) == null)
    {
        // The const pool stores the slice by reference, so the joined FQN
        // must live for the module's lifetime — let the module allocator
        // own it rather than freeing it here.
        const fqn = try joinSegments(b.allocator, segments);
        const dst = b.allocReg();
        const n = try b.module.internConst(b.allocator, .{ .String = fqn });
        try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = n } });
        return dst;
    }

    const first = segments[0];
    var cur: Reg = undefined;
    if (b.resolve(first.name)) |r| {
        cur = r;
    } else if (inReceiverContext(b)) {
        // Unresolved head: route through `this` / the enclosing receiver.
        // A head naming a known class carries the index-resolved class as
        // the exact global arm (a runtime receiver member still shadows
        // it, innermost first).
        const this_idx = try b.recordCapture("this");
        const dst = b.allocReg();
        const n = try b.module.internConst(b.allocator, .{ .String = first.name });
        orEmitAudit(b, "multi_seg_head", "LoadFromThisOrGlobal", first.name);
        try b.push(.{ .LoadFromThisOrGlobal = .{
            .dst = dst,
            .this_idx = this_idx,
            .name = n,
            .class = b.module.classIdIndexed(first.name, b.self_package, first.span.file),
        } });
        cur = dst;
    } else {
        // No receiver context: the head is a static global.
        const dst = b.allocReg();
        const n = try b.module.internConst(b.allocator, .{ .String = first.name });
        orEmitAudit(b, "multi_seg_head", "LoadGlobal", first.name);
        try b.push(.{ .LoadGlobal = .{
            .dst = dst,
            .name = n,
            .class = b.module.classIdIndexed(first.name, b.self_package, first.span.file),
        } });
        cur = dst;
    }
    for (segments[1..]) |seg| {
        const next = b.allocReg();
        const field = try b.module.internConst(b.allocator, .{ .String = seg.name });
        try b.push(.{ .GetField = .{ .dst = next, .receiver = cur, .field = field } });
        cur = next;
    }
    return cur;
}

/// Intern the scope-qualified getter field name `$sgetter$<owner>\u{1f}<name>`
/// when an enclosing class is known, else the plain name.
fn sgetterName(b: *FuncBuilder, name: []const u8) Allocator.Error!ConstId {
    if (b.ownerClass()) |owner| {
        // The const pool stores the slice by reference, so the buffer must
        // live for the module's lifetime — let the module allocator own it
        // rather than freeing it here (which would leave a dangling field
        // name read back at dispatch time).
        const qual = try std.fmt.allocPrint(b.allocator, "$sgetter${s}\u{1f}{s}", .{ owner, name });
        return b.module.internConst(b.allocator, .{ .String = qual });
    }
    return b.module.internConst(b.allocator, .{ .String = name });
}

const ImportRewrite = struct { cls: []const u8, member: []const u8 };

/// Resolve a bare name imported via `import a.b.C.MEMBER` into the
/// `(C, MEMBER)` companion access pair, when the import path names a class
/// this module declares.
fn importCompanionRewrite(b: *FuncBuilder, file: ir.FileId, name: []const u8) ?ImportRewrite {
    const segs = b.module.importAliasIn(file, name) orelse return null;
    // Find the rightmost segment naming a class the module declares.
    var cls_idx: ?usize = null;
    var i = segs.len;
    while (i > 0) {
        i -= 1;
        if (b.module.classId(segs[i]) != null) {
            cls_idx = i;
            break;
        }
    }
    const ci = cls_idx orelse return null;
    if (ci + 1 < segs.len) {
        return .{ .cls = segs[ci], .member = segs[segs.len - 1] };
    }
    return null;
}

/// A bare name brought into scope by `import EnumOrObject.*` resolves to that
/// class's member (`import DurationUnit.*` makes `MINUTES` mean
/// `DurationUnit.MINUTES`). Returns the simple class name to qualify with, or
/// null when no wildcard import targets a declared class with this surface.
/// The runtime `GetField` resolves the enum entry / companion member exactly as
/// it does for the written-out `Class.name`.
fn wildcardClassMemberRewrite(b: *FuncBuilder, file: ir.FileId) ?[]const u8 {
    const list = b.module.registry.import_wildcards.get(file) orelse return null;
    for (list.items) |path| {
        // The wildcard target names a class (enum / object) rather than a
        // package: its members are visible under their bare names. Match the
        // full FQN first, then the simple tail.
        if (b.module.classIdByFqn(path) != null) return lastPathSegment(path);
        const tail = lastPathSegment(path);
        if (b.module.classId(tail) != null) return tail;
    }
    return null;
}

fn lastPathSegment(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '.')) |dot| return path[dot + 1 ..];
    return path;
}

fn isBuiltinTypeName(name: []const u8) bool {
    const names = [_][]const u8{
        "Int",   "Long",    "Short",  "Byte", "Double", "Float",
        "Char",  "Boolean", "String", "UInt", "ULong",  "UShort",
        "UByte",
    };
    for (names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

fn lowerStringTemplate(b: *FuncBuilder, parts: []const ast.StringPart) Allocator.Error!Reg {
    var cur = try b.emitConst(.{ .String = "" });
    for (parts) |part| {
        const piece = switch (part) {
            .Text => |s| try b.emitConst(.{ .String = s }),
            .ShortInterp => |ident| try lowerShortInterp(b, ident),
            .Interp => |e| try lowerExpr(b, e),
        };
        const dst = b.allocReg();
        try b.push(.{ .BinOp = .{ .dst = dst, .op = .StringConcat, .lhs = cur, .rhs = piece } });
        cur = dst;
    }
    return cur;
}

fn lowerShortInterp(b: *FuncBuilder, ident: ast.Ident) Allocator.Error!Reg {
    // `$this` denotes the receiver itself — `this` is a keyword, never a
    // member or global name — so it lowers exactly like a bare `this`
    // expression: the bound `this`, or the captured slot in a lambda body.
    if (std.mem.eql(u8, ident.name, "this")) {
        if (b.resolve("this")) |r| return r;
        const idx = try b.recordCapture("this");
        const dst = b.allocReg();
        try b.push(.{ .LoadCapture = .{ .dst = dst, .idx = idx } });
        return dst;
    }
    if (b.resolve(ident.name)) |r| return r;
    if (b.knowsOuter(ident.name)) {
        const idx = try b.recordCapture(ident.name);
        const dst = b.allocReg();
        try b.push(.{ .LoadCapture = .{ .dst = dst, .idx = idx } });
        try b.bind(ident.name, dst);
        return dst;
    }
    if (b.hasOwnMember(ident.name) and b.resolve("this") != null) {
        const this_reg = b.resolve("this").?;
        const dst = b.allocReg();
        const nm = try b.module.internConst(b.allocator, .{ .String = ident.name });
        try b.push(.{ .GetField = .{ .dst = dst, .receiver = this_reg, .field = nm } });
        return dst;
    }
    if (b.resolve("this")) |this_reg| {
        const dst = b.allocReg();
        const n = try b.module.internConst(b.allocator, .{ .String = ident.name });
        try b.push(.{ .GetField = .{ .dst = dst, .receiver = this_reg, .field = n } });
        return dst;
    }
    const n = try b.module.internConst(b.allocator, .{ .String = ident.name });
    const dst = b.allocReg();
    if (inReceiverContext(b)) {
        const this_idx = try b.recordCapture("this");
        orEmitAudit(b, "short_interp", "LoadFromThisOrGlobal", ident.name);
        try b.push(.{ .LoadFromThisOrGlobal = .{ .dst = dst, .this_idx = this_idx, .name = n } });
    } else {
        orEmitAudit(b, "short_interp", "LoadGlobal", ident.name);
        try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = n } });
    }
    return dst;
}

/// `Member` lowering: safe member access (`recv?.x`), `super.<prop>`, FQN
/// flatten, explicit `coroutineContext`, and the plain GetField.
fn lowerMember(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    const m = expr.Member;
    const receiver = m.receiver;
    const name = m.name;

    if (m.safe) {
        // `recv?.x` — null-guard.
        const recv = try lowerReceiver(b, receiver);
        const null_r = try b.emitConst(.Null);
        const is_null = b.allocReg();
        try b.push(.{ .BinOp = .{ .dst = is_null, .op = .Eq, .lhs = recv, .rhs = null_r } });
        const then_b = try b.allocBlock();
        const else_b = try b.allocBlock();
        const join = try b.allocBlock();
        const dst = b.allocReg();
        b.terminate(.{ .Branch = .{ .cond = is_null, .t = then_b, .f = else_b } });
        b.switchTo(then_b);
        const n = try b.emitConst(.Null);
        try b.push(.{ .Move = .{ .dst = dst, .src = n } });
        b.terminate(.{ .Goto = join });
        b.switchTo(else_b);
        const field = try b.module.internConst(b.allocator, .{ .String = name.name });
        const v = b.allocReg();
        try b.push(.{ .GetField = .{ .dst = v, .receiver = recv, .field = field } });
        try b.push(.{ .Move = .{ .dst = dst, .src = v } });
        b.terminate(.{ .Goto = join });
        b.switchTo(join);
        return dst;
    }

    // `super.<prop>` — dispatch its getter via the parent chain.
    if (receiver.* == .Super) {
        if (b.resolve("this")) |this_reg| {
            if (b.ownerClass()) |owner| {
                const sup = receiver.Super;
                const dst = b.allocReg();
                const nm = try b.module.internConst(b.allocator, .{ .String = name.name });
                const oc = try b.module.internConst(b.allocator, .{ .String = owner });
                const qual_const = try superQualifier(b, sup.qualifier, sup.label);
                const args_start = b.allocReg();
                try b.push(.{ .CallSuper = .{
                    .dst = dst,
                    .receiver = this_reg,
                    .owner_class = oc,
                    .qualifier = qual_const,
                    .name = nm,
                    .args = args_start,
                    .n_args = 0,
                    .arg_names = &.{},
                } });
                return dst;
            }
        }
    }

    // Flatten chains like `kotlin.math.PI` into a single FQN lookup.
    if (try collectDottedFqn(b.allocator, expr)) |fqn| {
        defer b.allocator.free(fqn);
        const head = firstSegment(fqn);
        // A real package root (`kotlin.math.PI`) flattens to an FQN LoadGlobal
        // even inside a class method; only an ambiguous head defers to a member
        // when `this` is in scope. Mirrors the call path (lowerFqnGlobalCall).
        const head_is_real_pkg = isPkgRoot(head);
        if (isPackageHead(head) and
            headIsPackage(b, head) and
            b.resolve(head) == null and
            !b.knowsOuter(head) and
            !b.hasEnclosingMember(head) and
            b.module.classId(head) == null and
            (head_is_real_pkg or b.resolve("this") == null))
        {
            const dst = b.allocReg();
            const n = try b.module.internConst(b.allocator, .{ .String = fqn });
            try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = n } });
            return dst;
        }
    }

    // An explicit `recv.coroutineContext` is a literal field read.
    if (std.mem.eql(u8, name.name, "coroutineContext")) {
        const recv = try lowerReceiver(b, receiver);
        const dst = b.allocReg();
        const field = try b.module.internConst(b.allocator, .{ .String = "$coroutineContext$explicit" });
        try b.push(.{ .GetField = .{ .dst = dst, .receiver = recv, .field = field } });
        return dst;
    }

    const recv = try lowerReceiver(b, receiver);
    const dst = b.allocReg();
    const field = try b.module.internConst(b.allocator, .{ .String = name.name });
    try b.push(.{ .GetField = .{ .dst = dst, .receiver = recv, .field = field } });
    return dst;
}

/// Intern the `super<Q>` qualifier (type ref) or `super@Q` label (ident).
fn superQualifier(b: *FuncBuilder, qualifier: ?ast.TypeRef, label: ?ast.Ident) Allocator.Error!?ConstId {
    if (qualifier) |t| {
        return try b.module.internConst(b.allocator, .{ .String = t.name.name });
    }
    if (label) |id| {
        return try b.module.internConst(b.allocator, .{ .String = id.name });
    }
    return null;
}

fn lowerReturn(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    const ret = expr.Return;
    const label = ret.label;
    var r: ?Reg = null;
    if (ret.value) |e| {
        // `return …` puts the declared return type in tail position; only a
        // bare `return` targets the enclosing fn.
        var prev: ?(?ast.TypeRef) = null;
        if (label == null) prev = b.pushExpected(b.declaredReturn());
        const lowered = try lowerExpr(b, e);
        if (prev) |p| b.restoreExpected(p);
        r = lowered;
    }
    // An unlabeled `return` inside an inlined body returns from that inline
    // fn — the call's value.
    if (label == null) {
        if (b.inlineActiveReturn()) |ar| {
            if (r) |rr| try b.push(.{ .Move = .{ .dst = ar.reg, .src = rr } });
            // Replay every active `finally { … }` block inline before exiting.
            const pending = try b.activeFinallys();
            defer b.allocator.free(pending);
            if (pending.len != 0) {
                const prior = try b.swapFinallyStack(&.{});
                defer b.allocator.free(prior);
                var idx: usize = 0;
                while (idx < pending.len) : (idx += 1) {
                    const blk = &pending[pending.len - 1 - idx];
                    const outer = try b.allocator.dupe(ast.Block, prior[0 .. prior.len - (idx + 1)]);
                    const dropped = try b.swapFinallyStack(outer);
                    b.allocator.free(dropped);
                    _ = try lowerBlock(b, blk);
                }
                const restore = try b.allocator.dupe(ast.Block, prior);
                const dropped2 = try b.swapFinallyStack(restore);
                b.allocator.free(dropped2);
            }
            b.terminate(.{ .Goto = ar.join });
            const dead = try b.allocBlock();
            b.switchTo(dead);
            return b.emitConst(.Unit);
        }
    }
    // `return@<inlineFnName>` inside a spliced inline-argument lambda.
    if (label) |lbl| {
        if (b.inlineLambdaRetFor(lbl.name)) |lr| {
            if (r) |rr| try b.push(.{ .Move = .{ .dst = lr.reg, .src = rr } });
            b.terminate(.{ .Goto = lr.join });
            const dead = try b.allocBlock();
            b.switchTo(dead);
            return b.emitConst(.Unit);
        }
    }
    if (label) |lbl| {
        // A labeled return unwinds at runtime to the frame whose function /
        // lambda carries this label (`frameMatchesLabel`). That is correct
        // whether the target is the current lambda (a local `return@self`,
        // absorbed at this frame) or an enclosing one reached through a
        // non-inlined call — e.g. `run sc@{ once { return@sc } }`, where the
        // lambda passed to the inline `once` is itself lowered outside any
        // inline context. Emitting a plain `Return` there returned from the
        // lambda locally and silently dropped the non-local return.
        b.terminate(.{ .LabeledReturn = .{ .label = lbl.name, .value = r } });
    } else if (b.isLambdaBody() and !b.isNamedLocalFn()) {
        b.terminate(.{ .NonLocalReturn = r });
    } else {
        b.terminate(.{ .Return = r });
    }
    const dead = try b.allocBlock();
    b.switchTo(dead);
    return b.emitConst(.Unit);
}

fn lowerTry(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    const t = expr.Try;
    const result = b.allocReg();
    const exit = try b.allocBlock();
    const finally_entry: ?BlockId = if (t.finally != null) try b.allocBlock() else null;
    // The post-finally sentinel is allocated up front so catch handlers can be
    // protected by the finally before their bodies are lowered (a throw in a
    // catch must run the finally, then re-raise past this sentinel).
    const finally_done: ?BlockId = if (finally_entry != null) try b.allocBlock() else null;

    // Pre-allocate each catch handler's entry block + exception register.
    const Handler = struct { c: ast.Catch, blk: BlockId, exc: Reg };
    const handlers = try b.allocator.alloc(Handler, t.catches.len);
    defer b.allocator.free(handlers);
    for (t.catches, handlers) |c, *h| {
        const blk = try b.allocBlock();
        const exc = b.allocReg();
        h.* = .{ .c = c, .blk = blk, .exc = exc };
    }

    const body_entry = try b.allocBlock();
    b.terminate(.{ .Goto = body_entry });
    b.switchTo(body_entry);
    const cur_id = b.cur;
    const catch_handlers = try b.allocator.alloc(CatchHandler, handlers.len);
    for (handlers, catch_handlers) |h, *ch| {
        ch.* = .{ .type_name = loweredTypeName(b, &h.c.ty), .handler = h.blk, .exception_reg = h.exc };
    }
    b.attachCatches(cur_id, catch_handlers, finally_entry);
    if (finally_done) |done| b.setFinallyDoneFor(cur_id, done);
    if (t.finally) |blk| try b.pushFinally(blk);
    const body_val = try lowerBlock(b, &t.body);
    try b.push(.{ .Move = .{ .dst = result, .src = body_val } });
    if (finally_entry) |fin| {
        b.terminate(.{ .Goto = fin });
    } else {
        b.terminate(.{ .Goto = exit });
    }

    // Each handler body. A catch body is itself protected by the finally so a
    // throw from within it still runs the finally before propagating.
    for (handlers) |h| {
        b.switchTo(h.blk);
        if (finally_entry) |fin| b.protectCatchWithFinally(h.blk, fin, finally_done.?);
        try b.pushScope();
        try b.bind(h.c.binding.name, h.exc);
        const v = try lowerBlock(b, &h.c.body);
        try b.push(.{ .Move = .{ .dst = result, .src = v } });
        try b.popScope();
        if (finally_entry) |fin| {
            b.terminate(.{ .Goto = fin });
        } else {
            b.terminate(.{ .Goto = exit });
        }
    }

    // Finally body.
    if (finally_entry) |fin| {
        if (t.finally != null) b.popFinally();
        const done = finally_done.?;
        b.switchTo(fin);
        if (t.finally) |blk| _ = try lowerBlock(b, &blk);
        b.terminate(.{ .Goto = done });
        b.switchTo(done);
        b.terminate(.{ .Goto = exit });
    }

    b.switchTo(exit);
    return result;
}

fn lowerLambda(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    const lam = expr.Lambda;
    // Consume the per-argument expected lambda arity set by the call
    // lowering for this argument slot before the body recurses (which
    // re-arms it for the body's own nested calls).
    var expected_arity = b.pending_lambda_arity;
    b.pending_lambda_arity = -1;
    // Broad-collection mask for this lambda's params (set by the call lowering
    // from the callee parameter's function type). Consumed before the body
    // recurses so a nested lambda does not inherit it.
    const lambda_broad_mask = b.pending_lambda_broad_mask;
    b.pending_lambda_broad_mask = 0;
    // Callee-generic slot flag: the expected function type's parameters are
    // all the callee's own type parameters, so this lambda's params carry
    // Kotlin's generic static typing. Consumed the same way.
    const lambda_fn_generic = b.pending_ref_fn_generic;
    b.pending_ref_fn_generic = false;
    // A lambda assigned to a typed binding (`val h: Ctx.() -> Unit = { … }`)
    // never reaches the call-argument arity path; derive the arity from the
    // binding's functional type so a `T.() -> R` receiver lambda (zero value
    // parameters) drops its `it` and resolves bare members through the
    // receiver bound at invocation, rather than a spurious `it` parameter.
    if (expected_arity == -1) {
        if (b.peekExpected()) |exp| {
            if (exp.function) |ft| {
                expected_arity = @intCast(ft.params.len);
            }
        }
    }
    // A zero-`->` lambda gets its implicit `it` only when its own
    // functional type takes exactly one parameter. A `() -> R` and a
    // `T.() -> R` receiver lambda both encode arity 0, so the
    // parser-injected `it` is dropped and an `it` reference inside resolves
    // to the nearest enclosing lambda's `it` (or is rejected when none
    // exists). Suppression applies only to the arity-0 shapes; an unknown
    // arity (-1, an unconstrained value position) keeps the single-`it`
    // binding unchanged.
    const suppress_it = lam.implicit_it and expected_arity == 0;
    if (orAuditOn() and lam.implicit_it)
        std.debug.print("[IT-AUDIT] lambda span={d}..{d} expected_arity={d} suppress={}\n", .{ lam.body.span.start, lam.body.span.end, expected_arity, suppress_it });
    const eff_params: []const ast.Ident = if (suppress_it) &.{} else lam.params;
    const eff_param_tys: []const ?ast.TypeRef = if (suppress_it) &.{} else lam.param_tys;
    // Names of lambda params (including the implicit `it`) whose effective
    // static type — the lambda's own annotation, else the expected functional
    // type's parameter — is a broad collection (`Iterable`/`Collection`).
    // Recorded on the body builder so `it + x` over a runtime `Set` produces a
    // `List`. Derived here (not via the body's `param_tys`) so the implicit
    // `it`'s runtime overload-dispatch placeholder type is left untouched.
    var broad_names: std.ArrayList([]const u8) = .empty;
    defer broad_names.deinit(b.allocator);
    if (!suppress_it and eff_params.len != 0) {
        const ft = if (b.peekExpected()) |exp| exp.function else null;
        for (eff_params, 0..) |p, i| {
            const ty: ?ast.TypeRef = if (i < eff_param_tys.len and eff_param_tys[i] != null)
                eff_param_tys[i]
            else if (ft != null and i < ft.?.params.len)
                ft.?.params[i]
            else
                null;
            const by_ty = ty != null and ty.?.function == null and helpers.isBroadCollectionTypeName(ty.?.name.name);
            // Also honor the callee-parameter mask: a call-argument lambda has
            // no expected functional type on the stack, so its `it`'s declared
            // `Iterable` type lives only in the callee's parameter signature.
            const by_mask = i < 32 and (lambda_broad_mask >> @intCast(i)) & 1 != 0;
            if (by_ty or by_mask) {
                try broad_names.append(b.allocator, p.name);
            }
        }
    }
    // Params of a callee-generic slot (unannotated only — an explicit
    // annotation is the stronger static fact and wins).
    var generic_names: std.ArrayList([]const u8) = .empty;
    defer generic_names.deinit(b.allocator);
    if (lambda_fn_generic and !suppress_it) {
        for (eff_params, 0..) |p, i| {
            const annotated = i < eff_param_tys.len and eff_param_tys[i] != null;
            if (!annotated) try generic_names.append(b.allocator, p.name);
        }
    }
    // `outer_names` / `inherited_rlp` ownership passes into the lambda lower.
    const outer_names = try b.visibleNames();
    const inherited_rlp = try b.receiverLambdaParamNames();
    var outer_boxed = try b.boxedVarsSnapshot();
    defer outer_boxed.deinit();
    const enclosing_owner = try enclosingOwnerFor(b);

    const inherited_lef = try b.localExtFnNames();
    const lowered = try lambda_body.lowerLambdaBodyCapturingKindWithIt(
        b.module,
        eff_params,
        eff_param_tys,
        &lam.body,
        outer_names,
        true,
        &outer_boxed,
        null,
        false,
        false,
        inherited_rlp,
        inherited_lef,
        enclosing_owner,
        suppress_it,
        if (suppress_it) lam.span else null,
        broad_names.items,
        generic_names.items,
    );
    const body_func = lowered.func;
    const captured_names = lowered.captures;

    // Record the implicit label.
    if (b.pending_lambda_label) |label| {
        b.pending_lambda_label = null;
        if (b.module.funcByIdMut(body_func)) |f| {
            f.implicit_label = label;
        }
    }
    // A `suspend { … }` literal: the body is a suspend function value.
    if (b.pending_suspend_lambda) {
        b.pending_suspend_lambda = false;
        if (b.module.funcByIdMut(body_func)) |f| {
            f.is_suspend = true;
        }
    }
    const captures = try b.allocator.alloc(Reg, captured_names.len);
    for (captured_names, captures) |n, *c| c.* = try resolveCapture(b, n);

    const param_names = if (suppress_it)
        try b.allocator.alloc([]const u8, 0)
    else
        try lambdaParamNames(b.allocator, lam.params);
    const body_ast = lam.body;
    const dst = b.allocReg();
    try b.push(.{ .AstLambda = .{
        .dst = dst,
        .params = param_names,
        .body_ast = body_ast,
        .captures = captures,
        .captured_names = captured_names,
        .absorb_return = false,
        .body_func = body_func,
    } });
    return dst;
}

fn lowerAnonFun(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    const af = expr.AnonFun;
    const body_block: ast.Block = blk: {
        if (af.body) |body| {
            switch (body.*) {
                .Block => |bl| break :blk bl,
                .Expr => |e| {
                    const stmts = try b.allocator.alloc(ast.Stmt, 1);
                    stmts[0] = .{ .Expr = e };
                    break :blk .{ .stmts = stmts, .span = exprSpan(expr) };
                },
            }
        }
        break :blk .{ .stmts = &.{}, .span = exprSpan(expr) };
    };
    const param_names = try b.allocator.alloc([]const u8, af.params.len);
    const param_idents = try b.allocator.alloc(ast.Ident, af.params.len);
    defer b.allocator.free(param_idents);
    const param_tys = try b.allocator.alloc(?ast.TypeRef, af.params.len);
    defer b.allocator.free(param_tys);
    for (af.params, param_names, param_idents, param_tys) |p, *pn, *pi, *pt| {
        pn.* = p.name.name;
        pi.* = p.name;
        pt.* = p.ty;
    }
    // `outer_names` / `inherited_rlp` ownership passes into the lambda lower.
    const outer_names = try b.visibleNames();
    const inherited_rlp = try b.receiverLambdaParamNames();
    var outer_boxed = try b.boxedVarsSnapshot();
    defer outer_boxed.deinit();
    const enclosing_owner = try enclosingOwnerFor(b);

    const inherited_lef = try b.localExtFnNames();
    const lowered = try lowerLambdaBodyCapturingKind(
        b.module,
        param_idents,
        param_tys,
        &body_block,
        outer_names,
        false,
        &outer_boxed,
        null,
        inherited_rlp,
        inherited_lef,
        enclosing_owner,
    );
    const captured_names = lowered.captures;
    const captures = try b.allocator.alloc(Reg, captured_names.len);
    for (captured_names, captures) |n, *c| c.* = try resolveCapture(b, n);
    const dst = b.allocReg();
    try b.push(.{ .AstLambda = .{
        .dst = dst,
        .params = param_names,
        .body_ast = body_block,
        .captures = captures,
        .captured_names = captured_names,
        .absorb_return = true,
        .body_func = lowered.func,
    } });
    return dst;
}

/// Build the lexically enclosing class context handed to a lambda body.
fn enclosingOwnerFor(b: *FuncBuilder) Allocator.Error!?EnclosingOwner {
    if (b.ownerClass()) |o| {
        return EnclosingOwner{ .class = o, .members = try b.enclosingMembersForChild() };
    }
    return null;
}

fn lambdaParamNames(allocator: Allocator, params: []const ast.Ident) Allocator.Error![][]const u8 {
    if (params.len == 0) {
        const out = try allocator.alloc([]const u8, 1);
        out[0] = "it";
        return out;
    }
    const out = try allocator.alloc([]const u8, params.len);
    for (params, out) |p, *o| o.* = p.name;
    return out;
}

/// The non-receiver parameter count encoded in a lowered function-type
/// head (`Function{N}` from `decl.loweredTypeRef`), or null when the type
/// is not a function type. A `T.() -> R` receiver lambda and a `() -> R`
/// lambda both encode `Function0`; a `(T) -> R` lambda encodes `Function1`.
fn fnTypeArity(ty: ir.TypeRef) ?i16 {
    const head = ty.name;
    if (!std.mem.startsWith(u8, head, "Function")) return null;
    const digits = head["Function".len..];
    if (digits.len == 0) return null;
    const n = std.fmt.parseInt(i16, digits, 10) catch return null;
    return n;
}

/// `fnTypeArity` resolving an aliased function-typed parameter
/// (`RoutingHandler = RoutingContext.() -> Unit` → `Function0`) through the
/// typealias registry before reading the `Function{N}` tag.
fn fnTypeArityAlias(b: *FuncBuilder, ty: ir.TypeRef) ?i16 {
    if (fnTypeArity(ty)) |n| return n;
    if (b.module.registry.type_aliases.get(ty.name)) |resolved| {
        if (std.mem.startsWith(u8, resolved, "Function")) {
            const digits = resolved["Function".len..];
            if (digits.len != 0) return std.fmt.parseInt(i16, digits, 10) catch null;
        }
    }
    return null;
}

/// Per-argument expected lambda arity for a call dispatched to the
/// resolved runtime `func`, parallel to `args`. Each entry is the
/// non-receiver parameter count of the matching parameter's function type,
/// or `-1` when the parameter is not a function type or cannot be aligned.
/// `recv_offset` skips a leading implicit `this` parameter (member /
/// extension calls). Positional alignment only: a named or spread argument
/// list yields all-unknown so a misaligned guess never suppresses an `it`.
/// The extension overload named `name` that hosts a trailing lambda for a
/// call of `user_arg_count` arguments: an extension (leading `this`) whose
/// last parameter is function-typed and whose non-receiver arity equals
/// `user_arg_count`. The bare-call heuristic resolves one FuncId by
/// declaration order, which for an overloaded name (`get` — `List.get`,
/// `Map.get`, `Route.get(path, body)`) may not be the overload the trailing
/// lambda lands on; the per-argument arity readout must read the lambda's
/// expected arity from the hosting overload so a `T.() -> R` handler drops
/// its synthetic `it`.
/// Whether `f`'s trailing function-typed parameter declares more
/// parameters than the call's trailing lambda supplies, leaving a reified
/// type parameter that appears in that lambda-parameter list unbound. Used
/// to reject a reified inline overload a bare/underfilled lambda cannot
/// instantiate (`post<reified R>(path, RoutingContext.(R) -> Unit)` for a
/// zero-parameter handler). Conservative: only fires when the last
/// parameter resolves to a function type whose arity exceeds the lambda's.
fn reifiedNeedsLambdaArity(b: *FuncBuilder, f: *const ast.Function, lambda_arity: usize) bool {
    if (f.params.len == 0) return false;
    const ty = f.params[f.params.len - 1].ty;
    const fn_arity: usize = blk: {
        if (ty.function) |ft| break :blk ft.params.len;
        const tag = b.module.registry.type_aliases.get(ty.name.name) orelse return false;
        if (!std.mem.startsWith(u8, tag, "Function")) return false;
        break :blk std.fmt.parseInt(usize, tag["Function".len..], 10) catch return false;
    };
    return fn_arity > lambda_arity;
}

/// Whether any same-named lowered candidate is an extension whose value-
/// parameter shape can bind this call's argument count through an implicit
/// receiver — `to(x)` inside a class is `this.to(x)`, so the receiver-bound
/// candidate keeps the bare call on the member/extension dispatch path. The
/// host global serves the call only when no receiver-bound binding is
/// possible (no such candidate, or none fits the arity: `iterator { … }`
/// against the zero-arg `Map.iterator()` family).
fn extensionCandidateFitsArity(b: *FuncBuilder, name: []const u8, user_arg_count: usize) bool {
    for (b.module.funcsBySimpleName(name)) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) continue;
        const user_params = f.params.len - 1;
        var required: usize = 0;
        var has_vararg = false;
        for (f.params[1..]) |*p| {
            if (p.is_vararg) {
                has_vararg = true;
                continue;
            }
            if (!p.has_default) required += 1;
        }
        if (has_vararg) {
            if (user_arg_count >= required) return true;
        } else if (user_arg_count >= required and user_arg_count <= user_params) {
            return true;
        }
    }
    return false;
}

fn overloadHostingTrailingLambda(b: *FuncBuilder, name: []const u8, user_arg_count: usize) ?FuncId {
    const list = b.module.func_name_index.get(name) orelse return null;
    for (list.items) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        if (!f.hasBody()) continue;
        // Both shapes host a trailing lambda: an extension/member (leading
        // `this`) and a plain top-level fn — the offset generalizes.
        const off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        const user_params = f.params.len - off;
        if (user_params < user_arg_count) continue;
        const last = f.params[f.params.len - 1];
        if (last.is_vararg) continue;
        if (fnTypeArityAlias(b, last.ty) == null) continue;
        // Under-applied (`launch { … }` against `launch(context = …,
        // start = …, block)`): the trailing lambda binds the last param
        // out of sequence, so every skipped parameter must be defaulted.
        if (user_params != user_arg_count) {
            var i: usize = off + user_arg_count - 1; // leading args fill params[off..]
            var gap_defaulted = true;
            while (i < f.params.len - 1) : (i += 1) {
                if (!f.params[i].has_default) {
                    gap_defaulted = false;
                    break;
                }
            }
            if (!gap_defaulted) continue;
        }
        return fid;
    }
    return null;
}

fn argFnArities(b: *FuncBuilder, func: *const Func, args: []const Expr, arg_names: []const ?[]const u8, recv_offset: usize) Allocator.Error!?[]i16 {
    if (args.len == 0) return null;
    for (arg_names) |an| if (an != null) return null;
    for (args) |*a| if (a.* == .Spread) return null;
    if (func.params.len < recv_offset) return null;
    const params = func.params[recv_offset..];
    // A trailing lambda fills the last function-typed parameter even when
    // earlier defaulted parameters are omitted; align the trailing lambda
    // with the last parameter and the leading args from the front.
    const out = try b.allocator.alloc(i16, args.len);
    for (out) |*o| o.* = -1;
    const trailing_lambda = args[args.len - 1] == .Lambda or args[args.len - 1] == .AnonFun;
    if (trailing_lambda and args.len <= params.len) {
        // Leading positional args map 1:1 from the front.
        var i: usize = 0;
        while (i + 1 < args.len) : (i += 1) {
            out[i] = fnTypeArityAlias(b, params[i].ty) orelse -1;
        }
        // The trailing lambda maps to the last parameter.
        out[args.len - 1] = fnTypeArityAlias(b, params[params.len - 1].ty) orelse -1;
    } else if (args.len == params.len) {
        for (params, out) |p, *o| o.* = fnTypeArityAlias(b, p.ty) orelse -1;
    } else {
        return null;
    }
    return out;
}

/// A bitmask of which of a `FunctionN`-typed parameter's `arity` value
/// parameters are declared as a broad collection (`Iterable`/`Collection`).
/// Used so a lambda bound to that parameter marks those of its own params
/// broad — then `it + x` over a runtime `Set` produces a `List`, matching the
/// declared (not runtime) receiver type. Only direct `Function{N}` types are
/// decoded (a typealias gives arity but not parameter types → mask 0).
fn fnTypeBroadMask(ty: ir.TypeRef, arity: i16) u32 {
    if (arity <= 0) return 0;
    const n: usize = @intCast(arity);
    if (!std.mem.startsWith(u8, ty.name, "Function")) return 0;
    // The lowered encoding is `[#suspend?] [receiver?] params… ret [#markers]`.
    var hi: usize = ty.args.len;
    while (hi > 0 and ty.args[hi - 1].name.len != 0 and ty.args[hi - 1].name[0] == '#') hi -= 1;
    var lo: usize = 0;
    if (lo < hi and std.mem.eql(u8, ty.args[lo].name, "#suspend")) lo += 1;
    const remaining = hi - lo; // [receiver?] params(n) ret(1)
    var pstart = lo;
    if (remaining == n + 2) {
        pstart = lo + 1; // an explicit receiver precedes the value params
    } else if (remaining != n + 1) {
        return 0; // cannot align
    }
    var mask: u32 = 0;
    var i: usize = 0;
    while (i < n and i < 32 and pstart + i < hi) : (i += 1) {
        if (helpers.isBroadCollectionTypeName(ty.args[pstart + i].name)) {
            mask |= (@as(u32, 1) << @intCast(i));
        }
    }
    return mask;
}

/// Per-argument broad-collection lambda-parameter masks for a call dispatched
/// to `func`, parallel to `args` and aligned exactly like `argFnArities`.
fn argLambdaBroadMasks(b: *FuncBuilder, func: *const Func, args: []const Expr, arg_names: []const ?[]const u8, recv_offset: usize) Allocator.Error!?[]u32 {
    if (args.len == 0) return null;
    for (arg_names) |an| if (an != null) return null;
    for (args) |*a| if (a.* == .Spread) return null;
    if (func.params.len < recv_offset) return null;
    const params = func.params[recv_offset..];
    const out = try b.allocator.alloc(u32, args.len);
    for (out) |*o| o.* = 0;
    const trailing_lambda = args[args.len - 1] == .Lambda or args[args.len - 1] == .AnonFun;
    if (trailing_lambda and args.len <= params.len) {
        var i: usize = 0;
        while (i + 1 < args.len) : (i += 1) {
            out[i] = fnTypeBroadMask(params[i].ty, fnTypeArityAlias(b, params[i].ty) orelse -1);
        }
        out[args.len - 1] = fnTypeBroadMask(params[params.len - 1].ty, fnTypeArityAlias(b, params[params.len - 1].ty) orelse -1);
    } else if (args.len == params.len) {
        for (params, out) |p, *o| o.* = fnTypeBroadMask(p.ty, fnTypeArityAlias(b, p.ty) orelse -1);
    } else {
        b.allocator.free(out);
        return null;
    }
    return out;
}

/// Whether a callee parameter's declared function type takes only values
/// typed by the callee's own type parameters (`f2t: (T, T) -> T` inside
/// `fun <T : Comparable<T>> ...`). A callable reference in such a slot
/// denotes the GENERIC overload of the referenced name: kotlinc substitutes
/// the call-site type argument, so only the generic candidate applies.
fn fnTypeIsCalleeGeneric(b: *FuncBuilder, func: *const Func, ty: ir.TypeRef, arity: i16) bool {
    if (arity <= 0) return false;
    const tps = b.module.registry.func_type_params.get(func.id) orelse return false;
    if (tps.items.len == 0) return false;
    if (!std.mem.startsWith(u8, ty.name, "Function")) return false;
    const n: usize = @intCast(arity);
    // The lowered encoding is `[#suspend?] [receiver?] params… ret [#markers]`.
    var hi: usize = ty.args.len;
    while (hi > 0 and ty.args[hi - 1].name.len != 0 and ty.args[hi - 1].name[0] == '#') hi -= 1;
    var lo: usize = 0;
    if (lo < hi and std.mem.eql(u8, ty.args[lo].name, "#suspend")) lo += 1;
    const remaining = hi - lo;
    var pstart = lo;
    if (remaining == n + 2) {
        pstart = lo + 1;
    } else if (remaining != n + 1) {
        return false;
    }
    var i: usize = 0;
    while (i < n and pstart + i < hi) : (i += 1) {
        var hit = false;
        for (tps.items) |tp| {
            if (std.mem.eql(u8, ty.args[pstart + i].name, tp)) {
                hit = true;
                break;
            }
        }
        if (!hit) return false;
    }
    return true;
}

/// Per-argument callee-generic function-type flags for a call dispatched to
/// `func`, parallel to `args` and aligned exactly like `argFnArities`.
fn argFnGenericFlags(b: *FuncBuilder, func: *const Func, args: []const Expr, arg_names: []const ?[]const u8, recv_offset: usize) Allocator.Error!?[]bool {
    if (args.len == 0) return null;
    for (arg_names) |an| if (an != null) return null;
    for (args) |*a| if (a.* == .Spread) return null;
    if (func.params.len < recv_offset) return null;
    const params = func.params[recv_offset..];
    const out = try b.allocator.alloc(bool, args.len);
    for (out) |*o| o.* = false;
    const trailing_lambda = args[args.len - 1] == .Lambda or args[args.len - 1] == .AnonFun;
    if (trailing_lambda and args.len <= params.len) {
        var i: usize = 0;
        while (i + 1 < args.len) : (i += 1) {
            out[i] = fnTypeIsCalleeGeneric(b, func, params[i].ty, fnTypeArityAlias(b, params[i].ty) orelse -1);
        }
        out[args.len - 1] = fnTypeIsCalleeGeneric(b, func, params[params.len - 1].ty, fnTypeArityAlias(b, params[params.len - 1].ty) orelse -1);
    } else if (args.len == params.len) {
        for (params, out) |p, *o| o.* = fnTypeIsCalleeGeneric(b, func, p.ty, fnTypeArityAlias(b, p.ty) orelse -1);
    } else {
        b.allocator.free(out);
        return null;
    }
    return out;
}

/// The unique body-bearing generic overload of `name` with `arity` value
/// params (every one typed by the func's own type parameters), or null when
/// none or several exist. The target a callee-generic `::name` slot binds.
///
/// Reads the placed `Func` when phase 2 has lowered the body, else the
/// phase-1 header metadata (`decl_user_sig` + `decl_ast_body`) — the
/// in-memory two-phase build lowers user files while the stdlib funcs are
/// still header stubs, and the answer must not depend on that state.
fn genericRefTarget(b: *FuncBuilder, name: []const u8, arity: usize) ?FuncId {
    var found: ?FuncId = null;
    cands: for (b.module.funcsBySimpleName(name)) |id| {
        const f = b.module.funcById(id) orelse continue;
        // An extension (a placed leading `this`, or a header stub's
        // synthesized receiver param) never binds a bare `::name`.
        if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) continue;
        const tps = b.module.registry.func_type_params.get(id) orelse continue;
        if (tps.items.len == 0) continue;
        if (f.hasBody()) {
            if (f.params.len != arity or arity == 0) continue;
            if (f.params[f.params.len - 1].is_vararg) continue;
            for (f.params) |*p| {
                if (!nameInList(p.ty.name, tps.items)) continue :cands;
            }
        } else {
            // Phase-1 header stub: judge by the declared metadata, so the
            // answer is the same whether the body is placed yet or not.
            if (!b.module.decl_ast_body.contains(id.int())) continue;
            const sig = b.module.decl_user_sig.get(id.int()) orelse continue;
            if (sig.len != arity or arity == 0) continue;
            if (b.module.decl_user_arity.get(id.int())) |da| {
                if (da.has_vararg) continue;
            }
            for (sig) |*ty| {
                if (!nameInList(ty.name, tps.items)) continue :cands;
            }
        }
        if (found != null) return null;
        found = id;
    }
    return found;
}

fn nameInList(name: []const u8, list: []const []const u8) bool {
    for (list) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

/// The container head of a receiver that is a stdlib factory call over
/// statically generic-typed values (`arrayOf(a, b)` where every arg is a
/// generic-typed param), or null. Such a receiver's element type is the
/// enclosing type parameter, so a member call on it resolves against the
/// GENERIC extension overload — the concrete-element specializations
/// (`Array<out Double>`) are statically inapplicable.
fn receiverGenericElemHead(b: *FuncBuilder, receiver: *const Expr) ?[]const u8 {
    if (receiver.* != .Call) return null;
    const rc = receiver.Call;
    if (rc.callee.* != .Path or rc.callee.Path.segments.len != 1) return null;
    const factory = rc.callee.Path.segments[0].name;
    if (b.resolve(factory) != null or b.isLocalFn(factory)) return null;
    const head: []const u8 = if (std.mem.eql(u8, factory, "arrayOf"))
        "Array"
    else if (std.mem.eql(u8, factory, "listOf") or std.mem.eql(u8, factory, "mutableListOf") or
        std.mem.eql(u8, factory, "arrayListOf"))
        "List"
    else if (std.mem.eql(u8, factory, "setOf") or std.mem.eql(u8, factory, "mutableSetOf"))
        "Set"
    else if (std.mem.eql(u8, factory, "sequenceOf"))
        "Sequence"
    else
        return null;
    if (rc.args.len == 0) return null;
    for (rc.args) |*a| {
        if (a.* != .Path or a.Path.segments.len != 1) return null;
        if (!b.isGenericTypedParam(a.Path.segments[0].name)) return null;
    }
    return head;
}

/// The unique generic extension overload of `name` applicable to a
/// `recv_head` receiver with `user_arity` value args: a candidate with its
/// own type parameters whose declared receiver head equals `recv_head`
/// (or one of its builtin supertypes when no exact head exists). Judged
/// from the placed `Func` or the phase-1 header metadata, like
/// `genericRefTarget`.
fn genericExtTarget(b: *FuncBuilder, name: []const u8, recv_head: []const u8, user_arity: usize) ?FuncId {
    var exact: ?FuncId = null;
    var exact_n: usize = 0;
    var sup: ?FuncId = null;
    var sup_n: usize = 0;
    for (b.module.funcsBySimpleName(name)) |id| {
        const f = b.module.funcById(id) orelse continue;
        const tps = b.module.registry.func_type_params.get(id) orelse continue;
        if (tps.items.len == 0) continue;
        if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) continue;
        const arity_ok = blk: {
            if (f.hasBody()) break :blk f.params.len - 1 == user_arity;
            if (!b.module.decl_ast_body.contains(id.int())) break :blk false;
            const n = b.module.decl_user_params.get(id.int()) orelse break :blk false;
            break :blk n == user_arity;
        };
        if (!arity_ok) continue;
        const cand_head = typeHead(f.params[0].ty.name);
        if (std.mem.eql(u8, cand_head, recv_head)) {
            exact = id;
            exact_n += 1;
            continue;
        }
        for (applicability.builtinSupersOf(recv_head)) |s| {
            if (std.mem.eql(u8, cand_head, s)) {
                sup = id;
                sup_n += 1;
                break;
            }
        }
    }
    if (exact_n == 1) return exact;
    if (exact_n == 0 and sup_n == 1) return sup;
    return null;
}

/// `argFnArities` for a constructor call: the per-argument expected lambda
/// arity from the class's primary-constructor parameters. A `T.() -> R`
/// receiver-lambda parameter reports arity 0 so the lambda drops its `it` and
/// resolves bare members through the receiver bound at invocation (the same as
/// a function-call argument).
fn ctorArgFnArities(b: *FuncBuilder, class_id: ir.ClassId, args: []const Expr, arg_names: []const ?[]const u8) Allocator.Error!?[]i16 {
    if (args.len == 0) return null;
    for (args) |*a| if (a.* == .Spread) return null;
    if (class_id.int() >= b.module.classes.items.len) return null;
    const params = b.module.classes.items[class_id.int()].primary_params;
    const out = try b.allocator.alloc(i16, args.len);
    for (out) |*o| o.* = -1;
    const trailing_lambda = args[args.len - 1] == .Lambda or args[args.len - 1] == .AnonFun;
    if (trailing_lambda) {
        // An unnamed trailing lambda binds the LAST function-typed parameter
        // (intervening defaulted/named params are skipped) — find it and take
        // its arity, so `Op(desc, named = x) { member() }` still detects the
        // receiver lambda.
        var pi = params.len;
        while (pi > 0) : (pi -= 1) {
            if (fnTypeArityAlias(b, params[pi - 1].ty)) |ar| {
                out[args.len - 1] = ar;
                break;
            }
        }
    }
    // Leading positional args map 1:1 only when there are no named args.
    if (allNull(arg_names) and args.len <= params.len) {
        var i: usize = 0;
        const lead: usize = if (trailing_lambda) args.len - 1 else args.len;
        while (i < lead) : (i += 1) out[i] = fnTypeArityAlias(b, params[i].ty) orelse -1;
    }
    return out;
}

/// When an unnamed trailing lambda binds a constructor's function-typed
/// parameter that sits *after* one or more defaulted parameters (`Op("d") {…}`
/// for `Op(d: String, flag: Boolean = true, f: C.() -> Unit)`), positional
/// binding would put the lambda in the defaulted slot. Returns an arg-name
/// vector that names the trailing lambda with the function parameter so the
/// named-arg constructor path realigns it (the gap params take their defaults).
/// Null when no realignment is needed.
fn ctorRealignedArgNames(b: *FuncBuilder, class_id: ir.ClassId, args: []const Expr, arg_names: []const ?[]const u8) Allocator.Error!?[]?[]const u8 {
    if (args.len == 0 or !allNull(arg_names)) return null;
    if (!(args[args.len - 1] == .Lambda or args[args.len - 1] == .AnonFun)) return null;
    if (class_id.int() >= b.module.classes.items.len) return null;
    const params = b.module.classes.items[class_id.int()].primary_params;
    if (args.len > params.len) return null;
    var fn_idx: ?usize = null;
    var pi = params.len;
    while (pi > 0) : (pi -= 1) {
        if (fnTypeArityAlias(b, params[pi - 1].ty) != null) {
            fn_idx = pi - 1;
            break;
        }
    }
    const fi = fn_idx orelse return null;
    const lead = args.len - 1; // positional args preceding the trailing lambda
    if (fi <= lead) return null; // the lambda already aligns with (or past) the fn param
    // Every skipped parameter must be defaultable.
    var k = lead;
    while (k < fi) : (k += 1) if (!params[k].has_default and params[k].default == null) return null;
    const out = try b.allocator.alloc(?[]const u8, args.len);
    for (out) |*o| o.* = null;
    out[args.len - 1] = params[fi].name;
    return out;
}

fn lowerPostfix(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    const pf = expr.Postfix;
    const inner = pf.expr;
    switch (pf.op) {
        .NotNull => {
            const s = try lowerExpr(b, inner);
            const dst = b.allocReg();
            try b.push(.{ .NotNullAssert = .{ .dst = dst, .src = s } });
            return dst;
        },
        .Inc, .Dec => {
            const uo: UnOp = if (pf.op == .Inc) .Inc else .Dec;
            // Index target: evaluate receiver + keys once.
            if (inner.* == .Index) {
                const ix = inner.Index;
                const recv = try lowerReceiver(b, ix.receiver);
                const n_keys = ix.args.len;
                const key_start = b.allocReg();
                const key_slots = try b.allocator.alloc(Reg, if (n_keys == 0) 1 else n_keys);
                defer b.allocator.free(key_slots);
                key_slots[0] = key_start;
                var k: usize = 1;
                while (k < n_keys) : (k += 1) key_slots[k] = b.allocReg();
                const val_slot = b.allocReg();
                for (ix.args, 0..) |*arg, i| {
                    const r = try lowerExpr(b, arg);
                    try b.push(.{ .Move = .{ .dst = key_slots[i], .src = r } });
                }
                const old = b.allocReg();
                const get_nm = try b.module.internConst(b.allocator, .{ .String = "get" });
                try b.push(.{ .CallMember = .{
                    .dst = old,
                    .receiver = recv,
                    .name = get_nm,
                    .args = key_start,
                    .n_args = @intCast(n_keys),
                    .arg_names = &.{},
                } });
                const new = b.allocReg();
                try b.push(.{ .UnOp = .{ .dst = new, .op = uo, .operand = old } });
                try b.push(.{ .Move = .{ .dst = val_slot, .src = new } });
                const set_dst = b.allocReg();
                const set_nm = try b.module.internConst(b.allocator, .{ .String = "set" });
                try b.push(.{ .CallMember = .{
                    .dst = set_dst,
                    .receiver = recv,
                    .name = set_nm,
                    .args = key_start,
                    .n_args = @as(u32, @intCast(n_keys)) + 1,
                    .arg_names = &.{},
                } });
                return old;
            }
            const s = try lowerExpr(b, inner);
            // Snapshot the old value before mutating the storage slot.
            const old = b.allocReg();
            try b.push(.{ .Move = .{ .dst = old, .src = s } });
            const new = b.allocReg();
            try b.push(.{ .UnOp = .{ .dst = new, .op = uo, .operand = old } });
            // Postfix `x++` evaluates to the OLD value but writes the NEW
            // value back through the shared write-back decision.
            try stmt_mod.storeCombinedToTarget(b, inner, new);
            return old;
        },
    }
}

fn lowerLabeled(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    const lab = expr.Labeled;
    const inner = lab.expr;
    const label = lab.label;
    switch (inner.*) {
        .While => |w| {
            const header = try b.allocBlock();
            const body_blk = try b.allocBlock();
            const exit = try b.allocBlock();
            b.terminate(.{ .Goto = header });
            b.switchTo(header);
            const c = try lowerExpr(b, w.cond);
            b.terminate(.{ .Branch = .{ .cond = c, .t = body_blk, .f = exit } });
            b.switchTo(body_blk);
            try b.pushLoop(label.name, header, exit);
            _ = try lowerExpr(b, w.body);
            b.popLoop();
            b.terminate(.{ .Goto = header });
            b.switchTo(exit);
            return b.emitConst(.Unit);
        },
        .For => |f| return lowerForLabeled(b, f.vars, f.iter, f.body, label.name),
        .DoWhile => |w| {
            const body_blk = try b.allocBlock();
            const exit = try b.allocBlock();
            b.terminate(.{ .Goto = body_blk });
            b.switchTo(body_blk);
            try b.pushLoop(label.name, body_blk, exit);
            // Kotlin scopes the do-body's declarations into the `while`
            // condition, so when the body is a block, lower its statements and
            // the condition in one shared scope; otherwise the block's own
            // scope closes first and a `do { val x = … } while (x …)` local
            // resolves as a stray global.
            if (w.body) |body| {
                if (body.* == .Block) {
                    const block = &body.Block;
                    try b.pushScope();
                    try hoistMutualLocalFns(b, block);
                    for (block.stmts) |*stmt| _ = try lowerStmt(b, stmt);
                    b.popLoop();
                    const c = try lowerExpr(b, w.cond);
                    try b.popScope();
                    b.terminate(.{ .Branch = .{ .cond = c, .t = body_blk, .f = exit } });
                    b.switchTo(exit);
                    return b.emitConst(.Unit);
                }
                _ = try lowerExpr(b, body);
            }
            b.popLoop();
            const c = try lowerExpr(b, w.cond);
            b.terminate(.{ .Branch = .{ .cond = c, .t = body_blk, .f = exit } });
            b.switchTo(exit);
            return b.emitConst(.Unit);
        },
        // An explicit label on a lambda / anonymous function literal
        // (`sc@ { … }`) names that body for `return@sc`. It overrides any
        // implicit callee-derived label `lowerExpr` would otherwise arm,
        // so the lambda's own `implicit_label` is the explicit one.
        .Lambda, .AnonFun => {
            b.pending_lambda_label = label.name;
            return lowerExpr(b, inner);
        },
        else => return lowerExpr(b, inner),
    }
}

// -------------------------------------------------------------------------
// Call lowering — the long overload-resolution ladder.
// -------------------------------------------------------------------------

fn lastArgIsLambda(args: []const Expr) bool {
    if (args.len == 0) return false;
    return args[args.len - 1] == .Lambda;
}

/// Last `.`-separated segment of a (possibly qualified) type name.
fn lastTypeSegment(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| return name[i + 1 ..];
    return name;
}

/// Whether any same-simple-name function is an extension whose declared
/// receiver type is compatible with the spliced receiver's type chain
/// (`chain`, the receiver simple-name plus its supertypes). Distinguishes
/// a bare member/extension call on the spliced receiver
/// (`receiveNullable(...)` — applies to that receiver) from a bare call
/// whose extension namesakes target unrelated types (`maxOf(a, b)` inside
/// `Buffer.indexOf` — its only extension overloads are `Iterable.maxOf` /
/// array `maxOf`, none applies to `Buffer`, so the call binds the
/// package-level `maxOf(Int, Int)`). Only the former dispatches on the
/// splice's bound `this`; the latter falls through to the bare-name path.
/// A null `chain` (no receiver type narrowing available) admits any
/// extension namesake, preserving the prior receiver-agnostic behavior.
fn nameHasReceiverCandidate(b: *FuncBuilder, name: []const u8, chain: ?[]const []const u8) bool {
    for (b.module.funcsBySimpleName(name)) |fid| {
        const idx = fid.int();
        const f = b.module.funcById(FuncId.from(idx)) orelse continue;
        if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) continue;
        const recv_ty = lastTypeSegment(f.params[0].ty.name);
        const ch = chain orelse return true;
        for (ch) |c| {
            if (std.mem.eql(u8, lastTypeSegment(c), recv_ty)) return true;
        }
    }
    return false;
}

fn lastArgIsLambdaOrAnon(args: []const Expr) bool {
    if (args.len == 0) return false;
    const last = args[args.len - 1];
    return last == .Lambda or last == .AnonFun;
}

/// Declared parameter arity of a trailing lambda/anon-fun argument, or
/// `null` when the last argument is neither. A zero-`->` `{ … }` (its `it`
/// injected by the parser) reports 0 — the literal declares no parameters,
/// so overload resolution treats it as a `() -> R` handler.
fn trailingLambdaArity(args: []const Expr) ?usize {
    if (args.len == 0) return null;
    return switch (args[args.len - 1]) {
        .Lambda => |l| if (l.implicit_it) 0 else l.params.len,
        .AnonFun => |af| af.params.len,
        else => null,
    };
}

fn lowerCall(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    const call = expr.Call;
    const callee = call.callee;
    const args = call.args;
    const ast_arg_names = call.arg_names;
    const ast_type_args = call.type_args;
    const is_infix = call.is_infix;

    // Scope-true callee rewrite: a bare ctor/factory head naming a mangled
    // nested class (`Node(...)` inside its declaring class's subtree) or a
    // renamed file-private class/typealias resolves to the mangled lift
    // name. Locals and own members keep shadowing it (Kotlin scope order).
    if (callee.* == .Path and callee.Path.segments.len == 1) {
        const head = callee.Path.segments[0];
        if (scopeTypeRename(b, head.name, head.span.file.int())) |renamed| {
            if (b.resolve(head.name) == null and !b.knowsOuter(head.name)) {
                var new_segs = [_]ast.Ident{.{ .name = renamed, .span = head.span }};
                var new_callee = Expr{ .Path = .{ .segments = &new_segs, .span = callee.Path.span } };
                var rewritten = expr.*;
                rewritten.Call.callee = &new_callee;
                return lowerCall(b, &rewritten);
            }
        }
    }

    // Empty stdlib container creator (`emptyList()`, `setOf()`, `mapOf()`)
    // typed only by its binding annotation. With no explicit creation-site
    // type argument the runtime value cannot carry its element head, so a
    // receiver proof (`List<String>.describe()`) cannot bind. When the
    // tail-position expected type names the container's element/entry heads
    // (`val xs: List<String> = emptyList()`), synthesize those heads as the
    // call's type args so the existing creation-site path stamps
    // `declared_elem` on the built value, exactly as an explicit
    // `emptyList<String>()` would.
    if (!is_infix and ast_type_args.len == 0 and args.len == 0 and
        callee.* == .Path and callee.Path.segments.len == 1)
    {
        const cname = callee.Path.segments[0].name;
        if (b.resolve(cname) == null and !b.knowsOuter(cname)) {
            const want_heads = emptyContainerCreatorArity(cname);
            if (want_heads != 0) {
                if (b.peekExpected()) |exp| {
                    if (try synthesizeContainerTypeArgs(b, exp, want_heads)) |synth| {
                        var rewritten = expr.*;
                        rewritten.Call.type_args = synth;
                        return lowerCallGeneral(b, &rewritten);
                    }
                }
            }
        }
    }

    // A member call onto an inline `reified` extension (`xs.filterIsInstance<T>()`).
    // Explicit type args or an expected type let the splice bind the
    // reified parameters. Without either — a lambda body has no expected
    // type, the `Json.encodeToString(user)` hook shape — a call through a
    // companioned class name still splices; the splice itself declines
    // when the body reads a reified parameter it cannot bind, falling
    // back to runtime dispatch.
    if (!is_infix and callee.* == .Member and !callee.Member.safe and gate: {
        if (ast_type_args.len != 0 or b.peekExpected() != null) break :gate true;
        const recv = callee.Member.receiver;
        if (recv.* != .Path or recv.Path.segments.len != 1) break :gate false;
        const n = recv.Path.segments[0].name;
        if (b.resolve(n) != null or b.knowsOuter(n)) break :gate false;
        break :gate b.module.registry.companion_singletons.contains(n);
    }) {
        const mname = callee.Member.name.name;
        const reified_ext = blk: {
            if (inlineFnAst(mname)) |f| {
                if (f.receiver_type != null and anyReified(f.type_params)) break :blk true;
            }
            break :blk false;
        };
        if (reified_ext and !b.inlineInProgress(mname)) {
            const receiver = callee.Member.receiver;
            const expected = b.peekExpected();
            const exp_ptr: ?*const ast.TypeRef = if (expected) |*_e| _e else null;
            if (try tryInlineCallWithTypeArgs(b, mname, null, args, ast_arg_names, receiver, ast_type_args, exp_ptr)) |r| {
                return r;
            }
            // Splice bailed: fall back to a plain member dispatch.
            const recv = try lowerReceiver(b, receiver);
            const run = try lowerArgRun(b, args);
            const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
            const nm = try b.module.internConst(b.allocator, .{ .String = mname });
            const dst = b.allocReg();
            try b.push(.{ .CallMember = .{
                .dst = dst,
                .receiver = recv,
                .name = nm,
                .args = run[0],
                .n_args = run[1],
                .arg_names = arg_names,
            } });
            return dst;
        }
    }

    // `recv?.m(args)` — null-guard the whole call.
    if (callee.* == .Member and callee.Member.safe) {
        const receiver = callee.Member.receiver;
        const name = callee.Member.name;
        const recv = try lowerReceiver(b, receiver);
        const null_r = try b.emitConst(.Null);
        const is_null = b.allocReg();
        try b.push(.{ .BinOp = .{ .dst = is_null, .op = .Eq, .lhs = recv, .rhs = null_r } });
        const then_b = try b.allocBlock();
        const else_b = try b.allocBlock();
        const join = try b.allocBlock();
        const dst = b.allocReg();
        b.terminate(.{ .Branch = .{ .cond = is_null, .t = then_b, .f = else_b } });
        b.switchTo(then_b);
        const n = try b.emitConst(.Null);
        try b.push(.{ .Move = .{ .dst = dst, .src = n } });
        b.terminate(.{ .Goto = join });
        b.switchTo(else_b);
        const run = try lowerArgRun(b, args);
        const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
        const nm = try b.module.internConst(b.allocator, .{ .String = name.name });
        const v = b.allocReg();
        try b.push(.{ .CallMember = .{
            .dst = v,
            .receiver = recv,
            .name = nm,
            .args = run[0],
            .n_args = run[1],
            .arg_names = arg_names,
        } });
        try b.push(.{ .Move = .{ .dst = dst, .src = v } });
        b.terminate(.{ .Goto = join });
        b.switchTo(join);
        return dst;
    }

    // `repeat(n) { … }` — inline-desugar to a counted loop.
    if (!is_infix and args.len == 2 and args[1] == .Lambda and
        callee.* == .Path and callee.Path.segments.len == 1 and
        std.mem.eql(u8, callee.Path.segments[0].name, "repeat") and
        b.resolve("repeat") == null and b.module.funcId("repeat") == null)
    {
        return lowerRepeat(b, &args[0], &args[1]);
    }

    // Call passing a lambda that assigns to an outer-scope var, member callee.
    if (callee.* == .Member and !is_infix and try anyLambdaWritesOuter(b, args)) {
        return lowerCallWithWritebackMember(b, callee, args, ast_arg_names);
    }
    // Top-level fn call passing a closure-mutating lambda, path callee.
    // An inline callee that must be spliced keeps its splice: the lambda
    // body lowers in the caller's own frame (a compound assign on a
    // captured `val` is a `plusAssign` member call, not a write, and a
    // real `var` write lands on the boxed cell), and routing the call
    // through the writeback dispatch instead would drop the reified
    // type-argument binding (`assertFailsWith<E> { ts += d }`).
    if (callee.* == .Path and try anyLambdaWritesOuter(b, args)) {
        if (try tryBareInlineExpansion(b, expr)) |r| {
            return r;
        }
        return lowerCallWithWritebackPath(b, callee, args, ast_arg_names, ast_type_args);
    }

    // Calls containing a `*spread` argument.
    if (anySpread(args)) {
        return lowerCallSpread(b, callee, args, ast_arg_names);
    }

    return lowerCallGeneral(b, expr);
}

fn anyReified(type_params: []const ast.TypeParam) bool {
    for (type_params) |tp| {
        if (tp.is_reified) return true;
    }
    return false;
}

/// Number of element/entry heads a bare stdlib container creator carries
/// (`emptyList` -> 1, `emptyMap` -> 2), or 0 when the name is not one of
/// them. Mirrors `runtime.attachDeclaredElemTypes`'s creator sets so a
/// binding-typed empty creation stamps the same `declared_elem`/`declared_*`
/// fields an explicit creation-site type argument would.
fn emptyContainerCreatorArity(name: []const u8) u8 {
    const elem_creators = [_][]const u8{
        "listOf",      "mutableListOf", "emptyList",     "arrayListOf",
        "setOf",       "mutableSetOf",  "emptySet",      "hashSetOf",
        "linkedSetOf", "sortedSetOf",   "arrayOf",       "emptyArray",
        "sequenceOf",  "emptySequence",
    };
    const pair_creators = [_][]const u8{
        "mapOf", "mutableMapOf", "emptyMap", "hashMapOf", "linkedMapOf", "sortedMapOf",
    };
    for (elem_creators) |c| {
        if (std.mem.eql(u8, c, name)) return 1;
    }
    for (pair_creators) |c| {
        if (std.mem.eql(u8, c, name)) return 2;
    }
    return 0;
}

/// True when `name` is a concrete type head (a stdlib value type or a
/// lowered user class) rather than an erased type-parameter name. Used to
/// gate the binding-typed empty-container element stamp so the
/// erased-generic-return shape (`List<T>`) is left to on-demand dispatch.
fn isConcreteTypeHead(b: *FuncBuilder, name: []const u8) bool {
    const value_type_heads = [_][]const u8{
        "Int",     "Long",       "Short",  "Byte",    "UInt",      "ULong",
        "UShort",  "UByte",      "Double", "Float",   "Boolean",   "Char",
        "String",  "Any",        "Number", "Unit",    "CharObject", "List",
        "Set",     "Map",        "MutableList", "MutableSet", "MutableMap",
        "Array",   "Collection", "Iterable",    "Sequence",  "Pair",  "Triple",
    };
    for (value_type_heads) |h| {
        if (std.mem.eql(u8, h, name)) return true;
    }
    return b.module.classId(name) != null;
}

/// Build `want` synthetic call-site type-arg `TypeRef`s from the expected
/// container type `exp` (`List<String>` -> `[String]`). Returns null when
/// `exp` does not name `want` concrete (non-star, non-type-parameter) heads,
/// so an unannotated or partially-erased binding keeps the on-demand path.
fn synthesizeContainerTypeArgs(
    b: *FuncBuilder,
    exp: ast.TypeRef,
    want: u8,
) Allocator.Error!?[]ast.TypeRef {
    if (exp.type_args.len < want) return null;
    const out = try b.allocator.alloc(ast.TypeRef, want);
    var i: usize = 0;
    while (i < want) : (i += 1) {
        const ta = exp.type_args[i];
        if (ta.is_star) return null;
        if (ta.ty.name.name.len == 0) return null;
        // Only a concrete head carries runtime element identity. A bare
        // type-parameter head (`List<T>` from a generic function's declared
        // return) is erased — stamping the parameter name would forge a
        // proof — so that erased-generic-return shape keeps the on-demand
        // path rather than a synthesized element type.
        if (!isConcreteTypeHead(b, ta.ty.name.name)) return null;
        out[i] = ta.ty;
    }
    return out;
}

fn anyLambdaWritesOuter(b: *FuncBuilder, args: []const Expr) Allocator.Error!bool {
    for (args) |*a| {
        if (try lambdaWritesOuterVar(b, a)) return true;
    }
    return false;
}

fn anySpread(args: []const Expr) bool {
    for (args) |a| {
        if (a == .Spread) return true;
    }
    return false;
}

fn lowerRepeat(b: *FuncBuilder, n_arg: *const Expr, lam_arg: *const Expr) Allocator.Error!Reg {
    const lam = lam_arg.Lambda;
    const n_reg = try lowerExpr(b, n_arg);
    const i_reg = b.allocReg();
    const zero = try b.emitConst(.{ .Int = 0 });
    try b.push(.{ .Move = .{ .dst = i_reg, .src = zero } });
    const header = try b.allocBlock();
    const body_blk = try b.allocBlock();
    const exit = try b.allocBlock();
    b.terminate(.{ .Goto = header });
    b.switchTo(header);
    const cond = b.allocReg();
    try b.push(.{ .BinOp = .{ .dst = cond, .op = .Less, .lhs = i_reg, .rhs = n_reg } });
    b.terminate(.{ .Branch = .{ .cond = cond, .t = body_blk, .f = exit } });
    b.switchTo(body_blk);
    try b.pushScope();
    const pname: []const u8 = if (lam.params.len != 0) lam.params[0].name else "it";
    try b.bind(pname, i_reg);
    try b.pushLoop(null, header, exit);
    _ = try lowerBlock(b, &lam.body);
    b.popLoop();
    try b.popScope();
    const one = try b.emitConst(.{ .Int = 1 });
    const nexti = b.allocReg();
    try b.push(.{ .BinOp = .{ .dst = nexti, .op = .Add, .lhs = i_reg, .rhs = one } });
    try b.push(.{ .Move = .{ .dst = i_reg, .src = nexti } });
    b.terminate(.{ .Goto = header });
    b.switchTo(exit);
    return b.emitConst(.Unit);
}

fn lowerCallWithWritebackMember(
    b: *FuncBuilder,
    callee: *const Expr,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
) Allocator.Error!Reg {
    const receiver = callee.Member.receiver;
    const name = callee.Member.name;
    const recv = try lowerReceiver(b, receiver);
    const arg_regs = try b.allocator.alloc(Reg, args.len);
    defer b.allocator.free(arg_regs);
    for (args, arg_regs) |*a, *ar| ar.* = try lowerExpr(b, a);
    const args_start = try packContiguous(b, arg_regs);
    const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
    const dst = b.allocReg();
    const nm = try b.module.internConst(b.allocator, .{ .String = name.name });
    try b.push(.{ .CallMember = .{
        .dst = dst,
        .receiver = recv,
        .name = nm,
        .args = args_start,
        .n_args = @intCast(args.len),
        .arg_names = arg_names,
    } });
    return dst;
}

fn lowerCallWithWritebackPath(
    b: *FuncBuilder,
    callee: *const Expr,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
    ast_type_args: []const ast.TypeRef,
) Allocator.Error!Reg {
    const arg_regs = try b.allocator.alloc(Reg, args.len);
    defer b.allocator.free(arg_regs);
    for (args, arg_regs) |*a, *ar| ar.* = try lowerExpr(b, a);

    // An extension/member fn lowers `this` as its implicit first param.
    var run_regs: std.ArrayList(Reg) = .empty;
    defer run_regs.deinit(b.allocator);
    const segments = callee.Path.segments;
    // Bind the callee through the symbol index where it resolves
    // uniquely (caller package + imports over the complete header set);
    // the order-based `funcId` pick remains the fallback for the shapes
    // the index defers on (extensions, overload sets).
    var bound_id: ?FuncId = null;
    if (segments.len == 1) {
        const ires = b.module.resolveBareCallIndexed(
            segments[0].name,
            b.self_package,
            segments[0].span.file,
            args.len,
            lastArgIsLambda(args),
        );
        bound_id = if (b.module.funcId(segments[0].name)) |heur|
            preferredBareTarget(b, heur, ires.pick())
        else
            ires.pick();
        if (bound_id) |bid| {
            _ = try recordOutOfScopeCall(b, segments[0].name, segments[0].span, bid, ires);
        }
        var needs_this = false;
        if (bound_id) |fid| {
            if (b.module.funcById(fid)) |f| {
                needs_this = f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this");
            }
        }
        if (needs_this) {
            // The bound target is an extension taking an implicit receiver.
            // The nearest `this` is NOT necessarily that receiver — a bare
            // `collect { … }` inside a `FlowCollector.()` flow-builder lambda
            // (whose collect-lambda mutates an outer var, which is what routes
            // the call through this writeback path) must reach the enclosing
            // `Flow` receiver, not dispatch on the collector. Resolve it with
            // the same receiver-walking dispatch the general path uses
            // (`CallMemberOrGlobal`, which tries each implicit receiver
            // innermost-first before any global), not a static `this`-pinned
            // `Call`. Mirrors the `ext_bare_call_lambda` arm in
            // `lowerCallGeneral`.
            const args_start = try packContiguous(b, arg_regs);
            const an = try internArgNames(b.allocator, b.module, ast_arg_names);
            const nmc = try b.module.internConst(b.allocator, .{ .String = segments[0].name });
            if (b.capturesThisSlot()) {
                const this_idx = try b.recordCapture("this");
                const dst = b.allocReg();
                orEmitAudit(b, "writeback_ext_bare_call", "CallMemberOrGlobal", segments[0].name);
                try b.push(.{ .CallMemberOrGlobal = .{
                    .dst = dst,
                    .this_idx = this_idx,
                    .name = nmc,
                    .args = args_start,
                    .n_args = @intCast(arg_regs.len),
                    .arg_names = an,
                    .func = bound_id,
                    .static_recv = try cmgStaticRecv(b),
                } });
                return dst;
            }
            if (try resolveThisForBareCallNoBind(b)) |tr| {
                const dst = b.allocReg();
                orEmitAudit(b, "writeback_ext_bare_call", "CallMemberOrGlobal", segments[0].name);
                try b.push(.{ .CallMemberOrGlobal = .{
                    .dst = dst,
                    .this_idx = 0,
                    .name = nmc,
                    .args = args_start,
                    .n_args = @intCast(arg_regs.len),
                    .arg_names = an,
                    .func = bound_id,
                    .recv = tr,
                    .static_recv = try cmgStaticRecv(b),
                } });
                return dst;
            }
        }
    }
    try run_regs.appendSlice(b.allocator, arg_regs);
    const n_args: u32 = @intCast(run_regs.items.len);
    const args_start = try packContiguous(b, run_regs.items);

    var arg_names_list: std.ArrayList(?ConstId) = .empty;
    defer arg_names_list.deinit(b.allocator);
    const interned = try internArgNames(b.allocator, b.module, ast_arg_names);
    defer if (interned.len != 0) b.allocator.free(interned);
    try arg_names_list.appendSlice(b.allocator, interned);
    while (arg_names_list.items.len < run_regs.items.len) {
        try arg_names_list.insert(b.allocator, 0, null);
    }
    const arg_names = try arg_names_list.toOwnedSlice(b.allocator);

    const dst = b.allocReg();
    if (segments.len == 1) {
        if (bound_id) |func_id| {
            const type_args = try internTypeArgs(b.allocator, b.module, ast_type_args);
            try b.push(.{ .Call = .{
                .dst = dst,
                .func = func_id,
                .args = args_start,
                .n_args = n_args,
                .arg_names = arg_names,
                .type_args = type_args,
                .exact = false,
            } });
        } else if (b.resolve(segments[0].name) == null and
            b.hasOwnMember(segments[0].name) and b.resolve("this") != null)
        {
            // A member of the enclosing class — e.g. an inherited inline fn
            // (`forEachSlotLocked`) whose trailing lambda mutates a captured
            // local, routing the call through this writeback path — dispatches
            // on `this`. The index never resolves members (`bound_id` is null),
            // so without this it falls to an unresolved global LoadGlobal.
            const this_reg = b.resolve("this").?;
            try b.push(.{ .CallMember = .{
                .dst = dst,
                .receiver = this_reg,
                .name = try b.module.internConst(b.allocator, .{ .String = segments[0].name }),
                .args = args_start,
                .n_args = n_args,
                .arg_names = arg_names,
            } });
        } else {
            const callee_r = blk: {
                if (b.resolve(segments[0].name) != null) {
                    break :blk try lowerExpr(b, callee);
                } else {
                    const r = b.allocReg();
                    const n = try b.module.internConst(b.allocator, .{ .String = segments[0].name });
                    try b.push(.{ .LoadGlobal = .{ .dst = r, .name = n } });
                    break :blk r;
                }
            };
            try b.push(.{ .CallValue = .{
                .dst = dst,
                .callee = callee_r,
                .args = args_start,
                .n_args = n_args,
                .arg_names = arg_names,
            } });
        }
    } else {
        const callee_r = try lowerExpr(b, callee);
        try b.push(.{ .CallValue = .{
            .dst = dst,
            .callee = callee_r,
            .args = args_start,
            .n_args = n_args,
            .arg_names = arg_names,
        } });
    }
    return dst;
}

/// Compact a list of registers into a contiguous run, returning the start
/// reg (or reg 0 when empty).
fn packContiguous(b: *FuncBuilder, regs: []const Reg) Allocator.Error!Reg {
    if (regs.len == 0) return Reg.from(0);
    const start = b.allocReg();
    try b.push(.{ .Move = .{ .dst = start, .src = regs[0] } });
    for (regs[1..]) |r| {
        const slot = b.allocReg();
        try b.push(.{ .Move = .{ .dst = slot, .src = r } });
    }
    return start;
}

/// Resolve a `this` reg for a bare extension call: bound local, else a
/// capture inside a lambda body, else null. Binds the recovered capture
/// locally so later references reuse it.
fn resolveThisForBareCall(b: *FuncBuilder) Allocator.Error!?Reg {
    return resolveThisRegKind(b, true, true);
}

/// Like `resolveThisForBareCall` but does not bind `this` locally.
fn resolveThisForBareCallNoBind(b: *FuncBuilder) Allocator.Error!?Reg {
    return resolveThisRegKind(b, true, false);
}

fn lowerCallSpread(
    b: *FuncBuilder,
    callee: *const Expr,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
) Allocator.Error!Reg {
    // `recv.method(*array)` dispatches the spread-flattened args through
    // member resolution on the receiver, not by invoking `recv.method` as a
    // first-class value (which a member like `split` is not). Lower the
    // receiver and carry the method name so the evaluator routes through
    // `callMemberNamed`.
    var member_id: ?ConstId = null;
    const callee_reg = blk: {
        if (callee.* == .Member) {
            const m = callee.Member;
            if (b.resolve(m.name.name) == null and !b.knowsOuter(m.name.name) and !b.isLocalFn(m.name.name)) {
                member_id = try b.module.internConst(b.allocator, .{ .String = m.name.name });
                break :blk try lowerReceiver(b, m.receiver);
            }
        }
        break :blk try lowerExpr(b, callee);
    };
    const parts = try b.allocator.alloc(SpreadPart, args.len);
    for (args, parts) |*a, *p| {
        if (a.* == .Spread) {
            const r = try lowerExpr(b, a.Spread.expr);
            p.* = .{ .reg = r, .is_spread = true };
        } else {
            const r = try lowerExpr(b, a);
            p.* = .{ .reg = r, .is_spread = false };
        }
    }
    const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
    const dst = b.allocReg();
    try b.push(.{ .CallSpread = .{
        .dst = dst,
        .callee = callee_reg,
        .parts = parts,
        .arg_names = arg_names,
        .member = member_id,
    } });
    return dst;
}

/// The general call path: inline expansion, infix, scope-fn markers, tailrec,
/// value invocation, class constructors, member dispatch, and the long
/// overload-selection ladder.
/// True when the enclosing class declares a primary-ctor *property* param
/// named `name` and also a same-named `vararg` method. In that case a bare
/// call `name(args)` inside the class body (notably a field initializer, where
/// the param is in scope as a local) must resolve by argument shape — the
/// vararg method for several args, the property's `invoke` for one matching
/// array — rather than blindly invoking the param's lambda. Routing such calls
/// through member dispatch lets `varargShadowedFieldInvoke` make that pick.
fn ctorParamShadowsVarargMethod(b: *FuncBuilder, name: []const u8) bool {
    const owner = b.ownerClass() orelse return false;
    const cid = b.module.classId(owner) orelse return false;
    const idx = cid.int();
    if (idx >= b.module.classes.items.len) return false;
    const cls = &b.module.classes.items[idx];
    var has_prop_param = false;
    for (cls.primary_params) |p| {
        if (p.is_property and std.mem.eql(u8, p.name, name)) {
            has_prop_param = true;
            break;
        }
    }
    if (!has_prop_param) return false;
    for (cls.methods) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        if (std.mem.eql(u8, f.name, name) and
            f.params.len != 0 and f.params[f.params.len - 1].is_vararg) return true;
    }
    return false;
}

/// Bare-path inline expansion: splice an inline-lambda parameter's body,
/// the reified overload an explicit `<T>` argument binds, or the resolved
/// inline target of a bare call. Returns null when the callee is not a
/// bare path or no splice applies, leaving the call to the normal
/// dispatch paths. Called from `lowerCallGeneral` and, first, from the
/// outer-writing-lambda arm of `lowerCall`: an inline function that must
/// be spliced (reified, suspend, non-local return) keeps its splice even
/// when a lambda argument assigns to an outer name, because the spliced
/// body lowers the write in the caller's own frame, and skipping the
/// splice would drop the reified type-argument binding entirely.
fn tryBareInlineExpansion(b: *FuncBuilder, expr: *const Expr) Allocator.Error!?Reg {
    const call = expr.Call;
    const callee = call.callee;
    const args = call.args;
    const ast_arg_names = call.arg_names;
    const ast_type_args = call.type_args;
    if (call.is_infix or callee.* != .Path or callee.Path.segments.len != 1) return null;
    const nm = callee.Path.segments[0].name;
    if (b.inlineLambdaFor(nm)) |lam| {
        return try spliceInlineLambda(b, lam, args);
    }
    const inline_call_shape = CallShape{
        .want = args.len,
        .last_is_lambda = lastArgIsLambdaOrAnon(args),
        .trailing_lambda_arity = trailingLambdaArity(args),
    };
    // An explicit `<T>` argument binds a reified parameter, so a reified
    // inline overload of this shape outranks a non-reified `KClass<T>`
    // namesake (which would lower `<T>` as a constructor value instead of
    // binding `T::class`). Splice the reified overload directly.
    if (ast_type_args.len != 0) {
        if (inline_state.reifiedInlineFnAstFor(nm, inline_call_shape)) |rf| {
            if (bareInlineNeedsSplice(b, nm, rf, args)) {
                const expected = b.peekExpected();
                const exp_ptr: ?*const ast.TypeRef = if (expected) |*_e| _e else null;
                if (try tryInlineCallWithTypeArgs(b, nm, rf, args, ast_arg_names, null, ast_type_args, exp_ptr)) |r| {
                    return r;
                }
            }
        }
    }
    if (try inlineTargetForBareCall(b, &callee.Path.segments[0], args, inline_call_shape)) |f| {
        // A reified inline overload whose type parameter lives only in
        // the trailing lambda's parameter list (`T.(R) -> Unit`) cannot
        // bind that parameter from a lambda that declares fewer
        // arguments — `post("/p") { … }` against
        // `post<reified R>(path, RoutingContext.(R) -> Unit)`. Kotlin
        // drops such an overload (R unconstrained) and resolves the call
        // to a non-reified namesake; decline the splice so the normal
        // call path picks the plain `post(path, RoutingHandler)`.
        const reified_underfilled = ast_type_args.len == 0 and
            anyReified(f.type_params) and
            inline_call_shape.trailing_lambda_arity != null and
            reifiedNeedsLambdaArity(b, f, inline_call_shape.trailing_lambda_arity.?);
        if (!reified_underfilled and bareInlineNeedsSplice(b, nm, f, args)) {
            const expected = b.peekExpected();
            const exp_ptr: ?*const ast.TypeRef = if (expected) |*_e| _e else null;
            if (try tryInlineCallWithTypeArgs(b, nm, f, args, ast_arg_names, null, ast_type_args, exp_ptr)) |r| {
                return r;
            }
        }
    }
    return null;
}


/// Whether any registered class's fqn ends in `.{name}` or `${name}` (a
/// nested/companion class reachable by simple name from some scope).
/// The nesting tree's conservative complement: splice windows whose owner
/// chain is unknown cannot walk the tree, so this module-wide probe keeps
/// a capitalized bare call from being mis-claimed as a member call.
fn anyClassNamed(b: *FuncBuilder, name: []const u8) bool {
    for (b.module.classes.items) |*c| {
        const fqn = c.fqn;
        if (fqn.len > name.len and std.mem.endsWith(u8, fqn, name)) {
            const sep = fqn[fqn.len - name.len - 1];
            if (sep == '.' or sep == '$') return true;
        }
        if (std.mem.eql(u8, c.name, name)) return true;
    }
    return false;
}


/// Whether the eager-vs-lazy audit is enabled (`KLIO_EAGER_AUDIT=1`).
fn eagerAuditOn() bool {
    const S = struct {
        var cached: ?bool = null;
    };
    if (S.cached) |v| return v;
    const on = runtime.getenvSlice("KLIO_EAGER_AUDIT") != null;
    S.cached = on;
    return on;
}

fn lowerCallGeneral(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    const call = expr.Call;
    const callee = call.callee;
    const args = call.args;
    const ast_arg_names = call.arg_names;
    const ast_type_args = call.type_args;
    const is_infix = call.is_infix;

    // A bare ctor callee naming a nested class must bind the one in THIS
    // enclosing-class chain, not a same-simple-name nested class in a sibling
    // outer class. Walk the owner's FQN, and for each prefix that is itself a
    // CLASS (never a package — so a same-package top-level is left alone),
    // check for a nested `<prefix>.<name>`. Only rewrite when it differs from
    // the bare resolution (a genuine collision), to the qualified path.
    if (!is_infix and ast_type_args.len == 0 and callee.* == .Path and
        callee.Path.segments.len == 1 and b.resolve(callee.Path.segments[0].name) == null)
    {
        const cname = callee.Path.segments[0].name;
        if (b.ownerClass()) |owner| resolve: {
            const ocid = b.module.classId(owner) orelse break :resolve;
            if (ocid.int() >= b.module.classes.items.len) break :resolve;
            const bare = b.module.classIdIndexed(cname, b.self_package, callee.Path.segments[0].span.file);
            var prefix: []const u8 = b.module.classes.items[ocid.int()].fqn;
            while (std.mem.lastIndexOfScalar(u8, prefix, '.')) |dot| {
                prefix = prefix[0..dot];
                if (b.module.classIdByFqn(prefix) == null) continue; // package, not a class
                const cand = try std.fmt.allocPrint(b.allocator, "{s}.{s}", .{ prefix, cname });
                const cand_cid = b.module.classIdByFqn(cand);
                if (cand_cid != null and (bare == null or cand_cid.?.int() != bare.?.int())) {
                    var segs: std.ArrayList(ast.Ident) = .empty;
                    var it = std.mem.splitScalar(u8, cand, '.');
                    while (it.next()) |seg| try segs.append(b.allocator, .{ .name = seg, .span = callee.Path.segments[0].span });
                    const new_callee = try b.allocator.create(Expr);
                    new_callee.* = Expr{ .Path = .{ .segments = try segs.toOwnedSlice(b.allocator), .span = callee.Path.span } };
                    var new_call = call;
                    new_call.callee = new_callee;
                    const rewritten = Expr{ .Call = new_call };
                    return lowerCallGeneral(b, &rewritten);
                }
                b.allocator.free(cand);
            }
        }
    }

    // Inline expansion (suspend-inline only).
    if (try tryBareInlineExpansion(b, expr)) |r| {
        return r;
    }

    // Inside an inline-extension splice, a bare call to a member of the
    // spliced extension's bound receiver (`receiveNullable(...)` inside a
    // spliced `ApplicationCall.receive`) is `this.member(...)` on that
    // receiver. Resolve it here, before the bare-name paths below treat the
    // member as a top-level function (which would lose the receiver). The
    // bound `this` is a local register (the splice's receiver binding), not a
    // captured frame slot, so dispatch it as an explicit `CallMember`.
    if (!is_infix and callee.* == .Path and callee.Path.segments.len == 1 and
        b.currentInlineFn() != null)
    {
        const nm = callee.Path.segments[0].name;
        // Only route to the spliced receiver when the bare name is a member
        // of it or names an extension whose declared receiver type is
        // compatible with the spliced receiver's type chain. A bare call
        // whose only extension namesakes target unrelated types (`maxOf(a,
        // b)` inside `Buffer.indexOf`, whose extension overloads are
        // `Iterable.maxOf` / array `maxOf`) is the package-level function,
        // not a receiver member — it must fall through to the bare-name path.
        const recv_chain = try narrowingRecvChain(b);
        // A captured crossinline param shadows a same-named member of the
        // anonymous object being lowered (`object : Iterable<T> { override fun
        // iterator() = iterator() }` — the bare `iterator()` is the captured
        // lambda, not the override, which would recurse). Let it fall through
        // to the anon-capture invocation below.
        if (b.resolve(nm) == null and !b.knowsOuter(nm) and !isLowerAnonCapture(nm)) {
            // Confident the call binds to the spliced `this`: the name is a
            // member of its class, or an extension whose declared receiver is
            // compatible with the *known* receiver-type chain. Dispatch it
            // straight onto the bound receiver register.
            // A NESTED CLASS's name sits in the own-member set but a
            // capitalized bare call to it is a CONSTRUCTOR, never a
            // method on `this` — leave it to the ctor resolution.
            const is_scoped_class = nm.len > 0 and std.ascii.isUpper(nm[0]) and
                (scopedClassIdForRead(b, nm, callee.Path.segments[0].span.file) != null or
                    b.module.classId(nm) != null or anyClassNamed(b, nm));
            const binds_this = !is_scoped_class and (b.hasOwnMember(nm) or
                (recv_chain != null and nameHasReceiverCandidate(b, nm, recv_chain)));
            if (binds_this) {
                if (b.resolve("this")) |bound_this| {
                    const run = try lowerArgRun(b, args);
                    const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
                    const dst = b.allocReg();
                    const nmc = try b.module.internConst(b.allocator, .{ .String = nm });
                    try b.push(.{ .CallMember = .{
                        .dst = dst,
                        .receiver = bound_this,
                        .name = nmc,
                        .args = run[0],
                        .n_args = run[1],
                        .arg_names = arg_names,
                    } });
                    return dst;
                }
            } else if (recv_chain == null and nameHasReceiverCandidate(b, nm, null)) {
                // The name is an extension namesake but the spliced receiver's
                // type is unknown here, so we cannot prove it binds to the
                // innermost `this`. Emit the receiver-walking form rather than
                // pinning it to `this`: a bare `collect` inside a nested
                // `FlowCollector.()` lambda must reach the outer `Flow`
                // receiver (`this@unsafeTransform`), not dispatch on the
                // collector. `CallMemberOrGlobal` tries the bound receiver,
                // then each enclosing receiver innermost-first, before any
                // global. Pass the bound `this` register directly so the splice
                // receiver (`filterIsInstanceTo` on the bound `List`) is the
                // innermost candidate even though it is a local register, not a
                // capture. Still handled here so the bare-name paths below
                // cannot grab it as a top-level function and drop the receiver.
                if (b.resolve("this")) |bound_this| {
                    const run = try lowerArgRun(b, args);
                    const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
                    const dst = b.allocReg();
                    const nmc = try b.module.internConst(b.allocator, .{ .String = nm });
                    orEmitAudit(b, "inline_splice_unknown_recv", "CallMemberOrGlobal", nm);
                    try b.push(.{ .CallMemberOrGlobal = .{
                        .dst = dst,
                        .this_idx = 0,
                        .name = nmc,
                        .args = run[0],
                        .n_args = run[1],
                        .arg_names = arg_names,
                        .recv = bound_this,
                        .static_recv = try cmgStaticRecv(b),
                    } });
                    return dst;
                } else if (b.knowsOuter("this") or b.capturesThisSlot()) {
                    const run = try lowerArgRun(b, args);
                    const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
                    const this_idx = try b.recordCapture("this");
                    const dst = b.allocReg();
                    const nmc = try b.module.internConst(b.allocator, .{ .String = nm });
                    orEmitAudit(b, "inline_splice_unknown_recv", "CallMemberOrGlobal", nm);
                    try b.push(.{ .CallMemberOrGlobal = .{
                        .dst = dst,
                        .this_idx = this_idx,
                        .name = nmc,
                        .args = run[0],
                        .n_args = run[1],
                        .arg_names = arg_names,
                        .static_recv = try cmgStaticRecv(b),
                    } });
                    return dst;
                }
            }
        }
    }

    // Bare call to a name the enclosing anon object closes over.
    if (!is_infix and callee.* == .Path and callee.Path.segments.len == 1 and
        b.resolve(callee.Path.segments[0].name) == null and
        isLowerAnonCapture(callee.Path.segments[0].name))
    {
        const idx = try b.recordCapture(callee.Path.segments[0].name);
        const callee_r = b.allocReg();
        try b.push(.{ .LoadCapture = .{ .dst = callee_r, .idx = idx } });
        const run = try lowerArgRun(b, args);
        const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
        const dst = b.allocReg();
        try b.push(.{ .CallValue = .{
            .dst = dst,
            .callee = callee_r,
            .args = run[0],
            .n_args = run[1],
            .arg_names = arg_names,
        } });
        return dst;
    }

    // Infix call `a fn b` → `a.fn(b)`.
    if (is_infix and args.len == 2 and callee.* == .Path and callee.Path.segments.len == 1) {
        const recv = try lowerExpr(b, &args[0]);
        const run = try lowerArgRun(b, args[1..]);
        const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
        const dst = b.allocReg();
        const nm = try b.module.internConst(b.allocator, .{ .String = callee.Path.segments[0].name });
        try b.push(.{ .CallMember = .{
            .dst = dst,
            .receiver = recv,
            .name = nm,
            .args = run[0],
            .n_args = run[1],
            .arg_names = arg_names,
        } });
        return dst;
    }

    // `suspend { … }` builder: the value is the lambda itself, with its
    // body marked suspend so dispatch can distinguish it from a plain
    // function value.
    if (callee.* == .Path and callee.Path.segments.len == 1 and
        std.mem.eql(u8, callee.Path.segments[0].name, "suspend") and
        args.len == 1 and args[0] == .Lambda)
    {
        b.pending_suspend_lambda = true;
        return lowerExpr(b, &args[0]);
    }
    // `contract { … }` — compile-time marker with no runtime effect.
    if (callee.* == .Path and callee.Path.segments.len == 1 and
        std.mem.eql(u8, callee.Path.segments[0].name, "contract") and
        args.len == 1 and args[0] == .Lambda)
    {
        return b.emitConst(.Unit);
    }
    // Self-call inside a tailrec fn → TailJump terminator. The jump
    // re-binds the function's parameters in place; an instance/extension
    // tailrec function carries its receiver as the leading implicit
    // param, and a bare recursive call keeps the same receiver, so the
    // arg run must lead with `this` — dropping it would shift every
    // re-bound parameter by one.
    if (callee.* == .Path and callee.Path.segments.len == 1) {
        if (b.tailrecSelf()) |ts| {
            if (std.mem.eql(u8, ts, callee.Path.segments[0].name)) {
                const run = if (b.tailrecSelfHasThis()) blk: {
                    const sp = exprSpan(callee);
                    const all = try b.allocator.alloc(Expr, args.len + 1);
                    defer b.allocator.free(all);
                    const synth_segs = try b.allocator.alloc(ast.Ident, 1);
                    defer b.allocator.free(synth_segs);
                    synth_segs[0] = .{ .name = "this", .span = sp };
                    all[0] = .{ .Path = .{ .segments = synth_segs, .span = sp } };
                    for (args, 0..) |arg, i| all[i + 1] = arg;
                    break :blk try lowerArgRun(b, all);
                } else try lowerArgRun(b, args);
                b.terminate(.{ .TailJump = .{ .args = run[0], .n_args = run[1] } });
                const dead = try b.allocBlock();
                b.switchTo(dead);
                return b.emitConst(.Unit);
            }
        }
    }

    // A ctor-property param shadowing a same-named vararg method must dispatch
    // by argument shape: a field initializer `val data = createFrom("a", "b")`
    // has the param in scope as a local, but the call belongs to the vararg
    // method, not the property lambda invoked with two arguments. Route to
    // member dispatch so `varargShadowedFieldInvoke` makes the pick.
    if (callee.* == .Path and callee.Path.segments.len == 1 and
        b.resolve(callee.Path.segments[0].name) != null and
        ctorParamShadowsVarargMethod(b, callee.Path.segments[0].name))
    {
        if (b.resolve("this")) |this_reg| {
            const run = try lowerArgRun(b, args);
            const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
            const dst = b.allocReg();
            const nmc = try b.module.internConst(b.allocator, .{ .String = callee.Path.segments[0].name });
            try b.push(.{ .CallMember = .{
                .dst = dst,
                .receiver = this_reg,
                .name = nmc,
                .args = run[0],
                .n_args = run[1],
                .arg_names = arg_names,
            } });
            return dst;
        }
    }

    // A `name<T>(…)` call whose name resolves to a value parameter/local that
    // is not a local function names the SHADOWED global function/builder: a
    // value takes no call-site type arguments. `iterator<List<T>> { … }` inside
    // `windowedIterator(iterator: Iterator<T>, …)` binds the `iterator {}`
    // builder, not the `iterator` parameter. Load the global so the runtime
    // resolves the intrinsic builder rather than invoking the parameter.
    if (callee.* == .Path and callee.Path.segments.len == 1 and ast_type_args.len != 0) {
        const nm0 = callee.Path.segments[0].name;
        if (b.resolve(nm0) != null and !b.isLocalFn(nm0) and
            b.module.classIdIndexed(nm0, b.self_package, callee.Path.segments[0].span.file) == null)
        {
            const gv = b.allocReg();
            const cn = try b.module.internConst(b.allocator, .{ .String = nm0 });
            orEmitAudit(b, "typed_call_shadowed_global", "LoadGlobal", nm0);
            try b.push(.{ .LoadGlobal = .{ .dst = gv, .name = cn } });
            const run = try lowerArgRun(b, args);
            const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
            const type_args = try internTypeArgs(b.allocator, b.module, ast_type_args);
            const dst = b.allocReg();
            try b.push(.{ .CallValue = .{
                .dst = dst,
                .callee = gv,
                .args = run[0],
                .n_args = run[1],
                .arg_names = arg_names,
                .type_args = type_args,
            } });
            return dst;
        }
    }

    // A single-name callee resolving to a local binding / parameter is a
    // value invocation.
    if (callee.* == .Path and callee.Path.segments.len == 1) {
        if (try lowerValueInvocation(b, callee, args, ast_arg_names)) |r| return r;
    }

    // Whether a single-segment class-name call resolves to the constructor.
    const shadowed_by_class = try shadowedByClass(b, callee, args);
    // A constructible same-named class competing with the function
    // candidates: a static commit to the function is only sound when the
    // pick is type-proven; otherwise the deferred class-carrying form
    // below lets the runtime decide ctor-vs-factory on the actual
    // argument types (`Box(s.length)` constructs `Box(Int)`, not the
    // `fun Box(s: String)` factory the arity-only view would pick).
    const class_competes = callee.* == .Path and callee.Path.segments.len == 1 and
        !shadowed_by_class and blk: {
            const cid = b.module.classIdIndexed(callee.Path.segments[0].name, b.self_package, callee.Path.segments[0].span.file) orelse break :blk false;
            if (cid.int() >= b.module.classes.items.len) break :blk false;
            const cls = &b.module.classes.items[cid.int()];
            // An abstract/interface/sealed class never constructs, so it
            // does not compete with the function candidates.
            if (cls.is_abstract) break :blk false;
            // The class competes only when its primary constructor can
            // actually take this argument count — a `HexFormat { … }`
            // builder call beside a multi-param internal constructor has
            // no constructor candidate and commits statically.
            var required: usize = 0;
            var has_vararg = false;
            for (cls.primary_params) |*p| {
                if (p.is_vararg) {
                    has_vararg = true;
                    continue;
                }
                if (!p.has_default) required += 1;
            }
            break :blk args.len >= required and (has_vararg or args.len <= cls.primary_params.len);
        };

    // Path-callee with a registered top-level fn → Call{func}.
    if (callee.* == .Path and callee.Path.segments.len == 1) {
        if (try lowerPathCall(b, expr, shadowed_by_class, class_competes)) |r| return r;
    }

    // Path-callee with a registered class name. The indexed lookup binds
    // the class visible from the caller's package and imports, so a
    // cross-package simple-name collision constructs the right class.
    if (callee.* == .Path and callee.Path.segments.len == 1) {
        if (b.module.classIdIndexed(callee.Path.segments[0].name, b.self_package, callee.Path.segments[0].span.file)) |class_id| {
            const ctor_arity = try ctorArgFnArities(b, class_id, args, ast_arg_names);
            defer if (ctor_arity) |ca| b.allocator.free(ca);
            const run = try lowerArgRunFull(b, args, ctor_arity, null);
            const realigned = try ctorRealignedArgNames(b, class_id, args, ast_arg_names);
            defer if (realigned) |r| b.allocator.free(r);
            const arg_names = try internArgNames(b.allocator, b.module, realigned orelse ast_arg_names);
            const dst = b.allocReg();
            if (shadowed_by_class) {
                // A bare `Inner()` uses the enclosing `this` as the new
                // instance's outer. Inside a lambda body that `this` is
                // only reachable through the closure's capture set, so
                // record the capture (kotlinc does the same: the inner
                // ctor's outer argument forces a `this$0` capture).
                if (class_id.int() < b.module.classes.items.len and
                    b.module.classes.items[class_id.int()].is_inner and
                    b.resolve("this") == null and b.capturesThisSlot())
                {
                    _ = try b.recordCapture("this");
                }
                try b.push(.{ .NewInstance = .{
                    .dst = dst,
                    .class = class_id,
                    .args = run[0],
                    .n_args = run[1],
                    .arg_names = arg_names,
                } });
            } else {
                const this_idx = try b.recordCapture("this");
                const nmc = try b.module.internConst(b.allocator, .{ .String = callee.Path.segments[0].name });
                orEmitAudit(b, "class_or_factory_call", "CallMemberOrGlobal", callee.Path.segments[0].name);
                try b.push(.{ .CallMemberOrGlobal = .{
                    .dst = dst,
                    .this_idx = this_idx,
                    .name = nmc,
                    .args = run[0],
                    .n_args = run[1],
                    .arg_names = arg_names,
                    .class = class_id,
                    .static_recv = try cmgStaticRecv(b),
                } });
            }
            return dst;
        }
    }

    // Inside a method/extension body: unqualified `name(...)` that didn't
    // match a local / top-level fn / class is a method call on `this`.
    if (callee.* == .Path) {
        if (try lowerImplicitThisCall(b, callee, args, ast_arg_names)) |r| return r;
    }

    // Unresolved bare-name call. Reaching here means the resolver above
    // declined to commit a target, so in a receiver context the call must
    // still dispatch member-first even when a same-named top-level function
    // exists in the index (a bare `close(permission)` inside a NodeList
    // member-extension reaches the receiver's inherited member, not a
    // same-named extension elsewhere); a bare-name value load would miss
    // receiver METHODS entirely. Outside a receiver context an indexed name
    // keeps the value-call fallback, which binds the resolved global.
    if (callee.* == .Path and callee.Path.segments.len == 1 and
        b.resolve(callee.Path.segments[0].name) == null and
        !b.knowsOuter(callee.Path.segments[0].name) and
        b.module.classId(callee.Path.segments[0].name) == null and
        (b.module.funcId(callee.Path.segments[0].name) == null or inReceiverContext(b)))
    {
        if (try lowerUnresolvedBareCall(b, callee, args, ast_arg_names, ast_type_args, null)) |r| return r;
    }

    // Built-in stdlib companion shortcuts: `Result.success(x)` etc.
    if (try lowerCompanionShortcut(b, callee, args, ast_arg_names)) |r| return r;

    // Package-qualified call to a user / pack top-level function.
    if (callee.* == .Member) {
        if (try lowerFqnFlattenCall(b, callee, args, ast_arg_names, ast_type_args)) |r| return r;
    }
    // Fully-qualified callee resolved as a global, CallValue.
    if (callee.* == .Member) {
        if (try lowerFqnGlobalCall(b, callee, args, ast_arg_names)) |r| return r;
    }

    // The catch-all member / value call.
    if (callee.* == .Member) {
        return lowerMemberCallFallback(b, expr);
    }
    // A bare single-name call that no earlier path resolved, but whose name
    // could be a member of an implicit receiver (a lambda's captured outer
    // `this`), must dispatch member-first — not fall to a bare-name value load
    // that binds a same-named top-level global. Otherwise `error(msg)` inside a
    // `runCatching { }` binds `kotlin.error` instead of the enclosing class's
    // own `error`.
    if (callee.* == .Path and callee.Path.segments.len == 1) {
        const nm0 = callee.Path.segments[0].name;
        // Only reroute a name that is ACTUALLY an own/enclosing member — not
        // merely "an unknown receiver could have it" — so a top-level helper
        // (`testEquals`) called in a lambda is left on the global path.
        if (b.resolve(nm0) == null and inReceiverContext(b) and b.hasEnclosingMember(nm0)) {
            if (try lowerUnresolvedBareCall(b, callee, args, ast_arg_names, ast_type_args, null)) |r| return r;
        }
    }
    // A bare call whose name is a bound local / captured outer does not
    // shadow an implicit receiver's member unless the local is actually
    // invokable: `subList = subList(0, 4)` inside `buildList { }` calls
    // the receiver's subList; the captured non-callable `val subList` is
    // not a candidate. Emit the runtime-arbitrated form (value when
    // callable, else the member on `this`) — the same arbitration
    // `redirect_to_member` applies inside a method body.
    if (callee.* == .Path and callee.Path.segments.len == 1 and call.type_args.len == 0) {
        const nm0 = callee.Path.segments[0].name;
        if (!b.isLocalFn(nm0) and !b.isLocalExtFn(nm0) and
            (b.knowsOuter(nm0) or b.resolve(nm0) != null))
        {
            if (try resolveThisForBareCallNoBind(b)) |this_reg| {
                const cv = try lowerExpr(b, callee);
                const run0 = try lowerArgRun(b, args);
                const an0 = try internArgNames(b.allocator, b.module, ast_arg_names);
                const nmc = try b.module.internConst(b.allocator, .{ .String = nm0 });
                const d0 = b.allocReg();
                try b.push(.{ .CallValueOrMember = .{
                    .dst = d0,
                    .callee = cv,
                    .this_recv = this_reg,
                    .name = nmc,
                    .args = run0[0],
                    .n_args = run0[1],
                    .arg_names = an0,
                } });
                return d0;
            }
        }
    }
    const callee_r = try lowerExpr(b, callee);
    const run = try lowerArgRun(b, args);
    const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
    // Carry explicit call-site type arguments so an intrinsic container
    // creator (`listOf<Byte>(…)`) stamps and coerces its element type.
    const type_args = try internTypeArgs(b.allocator, b.module, call.type_args);
    const dst = b.allocReg();
    try b.push(.{ .CallValue = .{
        .dst = dst,
        .callee = callee_r,
        .args = run[0],
        .n_args = run[1],
        .arg_names = arg_names,
        .type_args = type_args,
    } });
    return dst;
}

/// True when a bodied same-name function already accepts this call's arity.
fn aFuncFits(b: *FuncBuilder, nm: []const u8, want: usize) bool {
    for (b.module.funcsBySimpleName(nm)) |fid| {
        const mf = b.module.funcById(fid) orelse continue;
        if (!mf.hasBody()) continue;
        const has_this = mf.params.len != 0 and std.mem.eql(u8, mf.params[0].name, "this");
        const base: usize = if (has_this) 1 else 0;
        const user = mf.params.len - base;
        if (user == want) return true;
        if (want < user) {
            var all_optional = true;
            for (mf.params[base + want ..]) |p| {
                if (p.default == null and !p.is_vararg) {
                    all_optional = false;
                    break;
                }
            }
            if (all_optional) return true;
        }
        if (want > user and mf.params.len != 0 and mf.params[mf.params.len - 1].is_vararg) return true;
    }
    return false;
}

/// The receiver type a bare extension call inside this builder's body
/// narrows against — the enclosing extension's declared receiver, or
/// inside a class method (no extension receiver) the enclosing class
/// itself, since `this` is the implicit receiver Kotlin resolves the
/// call's extension on — followed by its transitive supertype names,
/// most-derived first. Null when no receiver is in scope.
fn narrowingRecvChain(b: *FuncBuilder) Allocator.Error!?[]const []const u8 {
    const cur = b.recvTy() orelse b.ownerClass() orelse return null;
    return try recvChainOf(b, cur);
}

/// `cur` followed by its transitive supertype simple names (nearest
/// first), from the hierarchy recorded at build time. A type with no
/// recorded hierarchy (a built-in, a generic parameter) yields just
/// itself.
pub fn recvChainOf(b: *FuncBuilder, cur: []const u8) Allocator.Error![]const []const u8 {
    const supers: []const []const u8 =
        b.module.registry.class_super_names.get(cur) orelse &.{};
    const chain = try b.allocator.alloc([]const u8, supers.len + 1);
    chain[0] = cur;
    @memcpy(chain[1..], supers);
    return chain;
}

/// The inline-fn declaration a bare call may splice, resolved through
/// the symbol index FIRST: a unique top-level winner decides — an
/// inline winner splices its registered AST, a non-inline winner
/// suppresses the splice so the normal call path binds it. The
/// shape/receiver narrowing over the simple-name candidate table
/// survives only as the tie-break for the shapes the index defers on
/// (extension forms, overload sets, default/vararg/trailing-lambda
/// shapes, and bodies lowered before the phase-1 headers exist — class
/// method bodies). Default-import-owned names never splice. The
/// KLIO_RESOLVE_AUDIT `inline` records compare this pick against the
/// simple-name narrowing's per call, a permanent regression detector
/// for the fold (zero unexplained divergences over the corpus).
fn inlineTargetForBareCall(
    b: *FuncBuilder,
    seg: *const ast.Ident,
    args: []const Expr,
    shape: CallShape,
) Allocator.Error!?*const ast.Function {
    const nm = seg.name;
    if (inline_state.isShadowedInlineName(nm)) return null;
    const narrowed = inlineFnAstForRecv(nm, shape, try narrowingRecvChain(b));
    const ires = b.module.resolveBareCallIndexed(
        nm,
        b.self_package,
        seg.span.file,
        args.len,
        shape.last_is_lambda,
    );
    const pick: ?*const ast.Function = switch (ires.outcome) {
        .resolved => |fid| blk: {
            // Receiver preference, mirroring `preferredBareTarget`: an
            // extension the receiver narrowing matched (and that the
            // splice gate accepts) outranks the index's receiverless
            // namesake — Kotlin resolves the in-scope receiver's
            // extension over the top-level function, and the index
            // never models receivers.
            if (narrowed) |nf| {
                if (nf.receiver_type != null and bareInlineNeedsSplice(b, nm, nf, args)) {
                    break :blk nf;
                }
            }
            break :blk inline_state.inlineAstById(fid.int());
        },
        .deferred => narrowed,
    };
    // An inline overload whose last parameter is a function type does not
    // apply when its matching argument is an object instance — e.g. a
    // `FlowCollector` passed to `Flow.collect`, where the real target is the
    // member `collect(collector)`, not the inline `collect(action: (T) -> Unit)`
    // extension. Splicing it would bind the object to the function parameter and
    // invoke it as `obj.invoke(...)`. Decline the splice so the member wins.
    if (pick) |pf| {
        const inline_takes_fn = pf.params.len != 0 and pf.params[pf.params.len - 1].ty.function != null;
        if (inline_takes_fn and lastArgIsObjectNotFunction(b, args) and
            b.resolve(nm) == null and b.hasOwnMember(nm))
        {
            return null;
        }
    }
    inlineResolveAudit(b, nm, seg.span.file, narrowed, pick, args, shape.last_is_lambda, ires);
    return pick;
}

/// Whether a bare call to inline fn `f` must be spliced at the call
/// site rather than dispatched: a `suspend inline` builder (its
/// `suspendCoroutineUninterceptedOrReturn` must capture the caller's
/// continuation), a lambda argument performing a non-local return, a
/// reified type parameter, or a member shadowing the trailing-lambda
/// shape. A receiver mismatch vetoes the splice (the call belongs to a
/// different receiver's overload). The receiver judged is the
/// innermost one in scope — the enclosing extension's declared
/// receiver, or inside a class method the enclosing class itself — and
/// matching is subtype-aware: an extension declared on a base class
/// accepts a subclass receiver.
/// Whether the last argument is definitely an object instance, not a
/// function value: an `object : Foo {}` expression, or a local bound to
/// one. Such an argument cannot satisfy a function-typed parameter, so an
/// inline overload that wants a lambda there is the wrong target.
fn lastArgIsObjectNotFunction(b: *FuncBuilder, args: []const Expr) bool {
    if (args.len == 0) return false;
    switch (args[args.len - 1]) {
        .ObjectExpr => return true,
        .Path => |p| {
            if (p.segments.len != 1) return false;
            return b.isObjectInitLocal(p.segments[0].name);
        },
        else => return false,
    }
}

fn bareInlineNeedsSplice(b: *FuncBuilder, nm: []const u8, f: *const ast.Function, args: []const Expr) bool {
    const has_reified = anyReified(f.type_params);
    const want = args.len;
    const trailing_lambda = lastArgIsLambdaOrAnon(args);
    const inline_takes_fn = f.params.len != 0 and f.params[f.params.len - 1].ty.function != null;
    const drops_trailing_lambda = trailing_lambda and want >= 2;
    const a_func_fits = aFuncFits(b, nm, want);
    const shadowed_by_member = drops_trailing_lambda and inline_takes_fn and
        !a_func_fits and b.resolve(nm) == null and b.hasOwnMember(nm);
    const recv_mismatch = blk: {
        if (f.receiver_type) |rt| {
            const rn = rt.name.name;
            const owner_accepts = if (b.ownerClass()) |oc| b.module.classIsOrExtends(oc, rn) else false;
            const positive = if (b.recvTy() orelse b.ownerClass()) |cur|
                (!b.module.classIsOrExtends(cur, rn) and !owner_accepts)
            else
                false;
            const member_wins = b.hasEnclosingMember(nm) and
                (if (b.ownerClass()) |oc| !std.mem.eql(u8, oc, rn) else false);
            break :blk positive or member_wins;
        }
        break :blk false;
    };
    return !recv_mismatch and
        (f.is_suspend or argLambdaHasNonlocalReturn(args) or has_reified or shadowed_by_member);
}

/// Audit one inline-target resolution (the `inline` records of
/// KLIO_RESOLVE_AUDIT): the simple-name narrowing's pick against the
/// index-first pick, compared on the splice that would actually occur —
/// a candidate failing the needs-splice gate never splices, so a
/// difference confined to non-splicing picks is not a divergence.
/// Divergences are graded like the bare-call audit's: the index
/// resolving an exact-arity overload where the simple-name table —
/// which only ever holds the inline overloads — fell back to a
/// vararg/default/arity-mismatched candidate is a `shape_correction`
/// (the pick takes the index's exact target), and the index resolving
/// in a strictly better scope tier than the simple-name pick ranks in
/// is a `tier_correction` (Kotlin's scope order — a named import
/// outranks even a same-package inline declaration — is a program
/// property the simple-name table cannot see). Anything else is
/// unexplained: an interpreter bug. KLIO_RESOLVE_STRICT turns an
/// unexplained divergence into a hard failure.
fn inlineResolveAudit(
    b: *FuncBuilder,
    nm: []const u8,
    file: ir.FileId,
    narrowed: ?*const ast.Function,
    pick: ?*const ast.Function,
    args: []const Expr,
    last_is_lambda: bool,
    ires: ir.Module.BareCallResolution,
) void {
    const audit_on = resolveAuditOn();
    const strict_on = resolveStrictOn();
    if (!audit_on and !strict_on) return;
    const old_eff: ?*const ast.Function = if (narrowed) |f|
        (if (bareInlineNeedsSplice(b, nm, f, args)) f else null)
    else
        null;
    const new_eff: ?*const ast.Function = if (pick) |f|
        (if (bareInlineNeedsSplice(b, nm, f, args)) f else null)
    else
        null;
    const divergent = old_eff != new_eff;
    const tier_corrected = divergent and ires.pick() != null and old_eff != null and blk: {
        const old_id = inline_state.inlineIdByAst(old_eff.?) orelse break :blk false;
        const old_tier = b.module.bareCallTierOf(FuncId.from(old_id), nm, b.self_package, file) orelse break :blk false;
        break :blk ires.tier < old_tier;
    };
    const explained = divergent and ires.pick() != null and
        (old_eff == null or tier_corrected or astPickInexact(old_eff.?, args.len, last_is_lambda));
    if (audit_on) {
        const outcome: []const u8 = switch (ires.outcome) {
            .resolved => "resolved",
            .deferred => "deferred",
        };
        const reason: []const u8 = switch (ires.outcome) {
            .resolved => "-",
            .deferred => |r| @tagName(r),
        };
        const old_np: usize = if (narrowed) |f| f.params.len else 0;
        const new_np: usize = if (pick) |f| f.params.len else 0;
        std.debug.print(
            "[KLIO_RESOLVE_AUDIT] inline name={s} pkg={s} arity={d} outcome={s} reason={s} old={s}/{d} new={s}/{d} splice_old={d} splice_new={d} divergent={d} correction={d}\n",
            .{
                nm,                            b.self_package,                args.len,
                outcome,                       reason,                        inlineCandLabel(narrowed),
                old_np,                        inlineCandLabel(pick),         new_np,
                @intFromBool(old_eff != null), @intFromBool(new_eff != null), @intFromBool(divergent),
                @intFromBool(explained),
            },
        );
    }
    if (strict_on and divergent and !explained) {
        std.debug.panic(
            "KLIO_RESOLVE_STRICT: unexplained inline-target divergence on '{s}' (pkg='{s}' arity={d}): simple-name pick {s} vs index pick {s}",
            .{ nm, b.self_package, args.len, inlineCandLabel(old_eff), inlineCandLabel(new_eff) },
        );
    }
}

/// Whether an inline candidate matches the call less exactly than any
/// index pick can: a vararg at any position, a default parameter, or a
/// declared arity differing from the call's (a trailing-lambda gap the
/// candidate's fn-typed last parameter absorbs is exact enough). The
/// AST-side mirror of `heurPickInexact`.
fn astPickInexact(f: *const ast.Function, want: usize, last_is_lambda: bool) bool {
    for (f.params) |p| {
        if (p.is_vararg) return true;
    }
    if (f.params.len != want) {
        const tl_fits = last_is_lambda and f.params.len != 0 and
            f.params[f.params.len - 1].ty.function != null and want >= 1 and
            f.params.len > want;
        if (!tl_fits) return true;
    }
    for (f.params) |p| {
        if (p.default != null) return true;
    }
    return false;
}

/// Audit label classifying an inline candidate's declaration shape
/// (overloads share the simple name; receiver-ness, suspend-ness, and
/// the printed parameter count identify the declaration).
fn inlineCandLabel(f: ?*const ast.Function) []const u8 {
    const fp = f orelse return "-";
    if (fp.receiver_type != null) {
        return if (fp.is_suspend) "ext+suspend" else "ext";
    }
    return if (fp.is_suspend) "plain+suspend" else "plain";
}

/// A single-name callee bound as a local / parameter / receiver-lambda-param.
fn lowerValueInvocation(
    b: *FuncBuilder,
    callee: *const Expr,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
) Allocator.Error!?Reg {
    const name0 = callee.Path.segments[0].name;

    // A bare call to a receiver-lambda param reached as a capture.
    if (b.isReceiverLambdaParam(name0) and b.resolve(name0) == null and b.knowsOuter(name0)) {
        const this_reg: ?Reg = if (b.knowsOuter("this") or b.capturesThisSlot())
            try resolveCapture(b, "this")
        else
            b.resolve("this");
        if (this_reg) |tr| {
            const callee_r = try resolveCapture(b, name0);
            const run = try lowerArgRun(b, args);
            const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
            const dst = b.allocReg();
            try b.push(.{ .CallValueWithThis = .{
                .dst = dst,
                .callee = callee_r,
                .receiver = tr,
                .args = run[0],
                .n_args = run[1],
                .arg_names = arg_names,
            } });
            return dst;
        }
    }

    // A bare call to a local *extension* function reached as a capture:
    // prepend the enclosing receiver as the closure's leading `this`
    // param, mirroring the declaring-scope arm below (`handleCall(...)`
    // inside an `on(Send) { ... }` lambda binds the Sender receiver).
    if (b.isLocalExtFn(name0) and b.resolve(name0) == null and b.knowsOuter(name0)) {
        const this_reg: ?Reg = if (b.knowsOuter("this") or b.capturesThisSlot())
            try resolveCapture(b, "this")
        else
            b.resolve("this");
        if (this_reg) |tr| {
            const callee_r = try resolveCapture(b, name0);
            const recv = b.allocReg();
            try b.push(.{ .Move = .{ .dst = recv, .src = tr } });
            const vals = try b.allocator.alloc(Reg, args.len + 1);
            defer b.allocator.free(vals);
            vals[0] = recv;
            for (args, 0..) |*a, i| vals[i + 1] = try lowerExpr(b, a);
            const args_start = try packContiguous(b, vals);
            const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
            const dst = b.allocReg();
            try b.push(.{ .CallValue = .{
                .dst = dst,
                .callee = callee_r,
                .args = args_start,
                .n_args = @intCast(vals.len),
                .arg_names = arg_names,
            } });
            return dst;
        }
    }

    // Member-function precedence over a same-named value/param.
    const redirect_to_member = blk: {
        var is_hierarchy_method = false;
        if (b.ownerClass()) |oc| {
            if (b.module.registry.hierarchy_methods.get(oc)) |s| {
                is_hierarchy_method = s.contains(name0);
            }
        }
        break :blk is_hierarchy_method and b.resolve(name0) != null and
            !b.isLocalFn(name0) and !b.isLocalExtFn(name0) and b.resolve("this") != null;
    };
    if (redirect_to_member) {
        const this_reg = b.resolve("this").?;
        var callee_reg = b.resolve(name0).?;
        if (b.isBoxed(name0)) {
            const c = b.allocReg();
            try b.push(.{ .CellGet = .{ .dst = c, .cell = callee_reg } });
            callee_reg = c;
        }
        const run = try lowerArgRun(b, args);
        const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
        const dst = b.allocReg();
        const nm = try b.module.internConst(b.allocator, .{ .String = name0 });
        try b.push(.{ .CallValueOrMember = .{
            .dst = dst,
            .callee = callee_reg,
            .this_recv = this_reg,
            .name = nm,
            .args = run[0],
            .n_args = run[1],
            .arg_names = arg_names,
        } });
        return dst;
    }

    if (b.resolve(name0)) |reg| {
        // A non-function-typed param does not shadow a same-named top-level
        // function for a *call*: `flow { … }` inside
        // `fun Flow<T>.combine(flow: Flow<T2>, …)` resolves to the `flow {}`
        // builder, not the `flow: Flow<T2>` parameter (a `Flow` is not
        // invokable). Defer to the bare-function path so the builder binds.
        if (b.isNonFnParam(name0) and b.module.funcId(name0) != null) {
            return null;
        }
        var callee_reg = reg;
        if (b.isBoxed(name0)) {
            const c = b.allocReg();
            try b.push(.{ .CellGet = .{ .dst = c, .cell = reg } });
            callee_reg = c;
        }
        // A bare call to a receiver-typed function param. With explicit
        // positional args the FIRST one is the receiver (`f: T.() -> R`
        // called `f(x)` means `x.f()`); with none, the enclosing `this`.
        if (b.isReceiverLambdaParam(name0) and args.len >= 1 and
            ast_arg_names.len >= 1 and ast_arg_names[0] == null and blk: {
                const ar = b.receiverLambdaArity(name0) orelse break :blk false;
                break :blk args.len == ar + 1;
            })
        {
            const recv_r = try lowerExpr(b, &args[0]);
            const run = try lowerArgRun(b, args[1..]);
            const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names[1..]);
            const dst = b.allocReg();
            try b.push(.{ .CallValueWithThis = .{
                .dst = dst,
                .callee = callee_reg,
                .receiver = recv_r,
                .args = run[0],
                .n_args = run[1],
                .arg_names = arg_names,
            } });
            return dst;
        }
        if (b.isReceiverLambdaParam(name0)) {
            const this_reg = try resolveThisForBareCallNoBind(b);
            if (this_reg) |tr| {
                const run = try lowerArgRun(b, args);
                const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
                const dst = b.allocReg();
                try b.push(.{ .CallValueWithThis = .{
                    .dst = dst,
                    .callee = callee_reg,
                    .receiver = tr,
                    .args = run[0],
                    .n_args = run[1],
                    .arg_names = arg_names,
                } });
                return dst;
            }
        }
        // A bare call to a *local extension* function.
        if (b.isLocalExtFn(name0)) {
            const this_reg = try resolveThisForBareCallNoBind(b);
            if (this_reg) |tr| {
                const recv = b.allocReg();
                try b.push(.{ .Move = .{ .dst = recv, .src = tr } });
                const vals = try b.allocator.alloc(Reg, args.len + 1);
                defer b.allocator.free(vals);
                vals[0] = recv;
                for (args, 0..) |*a, i| vals[i + 1] = try lowerExpr(b, a);
                const args_start = try packContiguous(b, vals);
                const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
                const dst = b.allocReg();
                try b.push(.{ .CallValue = .{
                    .dst = dst,
                    .callee = callee_reg,
                    .args = args_start,
                    .n_args = @intCast(vals.len),
                    .arg_names = arg_names,
                } });
                return dst;
            }
        }
        const lfp: ?[]const ?[]const u8 = if (allNull(ast_arg_names)) b.localFnParamTys(name0) else null;
        const run = try lowerArgRunFull(b, args, null, lfp);
        const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
        const dst = b.allocReg();
        try b.push(.{ .CallValue = .{
            .dst = dst,
            .callee = callee_reg,
            .args = run[0],
            .n_args = run[1],
            .arg_names = arg_names,
        } });
        return dst;
    }
    return null;
}

/// Whether a single-segment class-name call resolves to the constructor
/// rather than a same-named factory function.
const LitKind = enum { numeric, string, boolean, char };

/// Definite builtin value kind of a literal argument expression, or null when
/// the argument's type is not a known literal (so it can never *disprove* a
/// candidate parameter type).
fn argLitKind(e: *const Expr) ?LitKind {
    return switch (e.*) {
        .IntLit, .FloatLit => .numeric,
        .BoolLit => .boolean,
        .CharLit => .char,
        .StringTemplate => .string,
        else => null,
    };
}

/// Declared parameter arity of a single lambda / anon-fun argument
/// expression, or null when it is neither. A zero-`->` `{ … }` (its `it`
/// injected by the parser) reports 0 — the literal declares no parameters,
/// so overload resolution treats it as a `() -> R` handler.
fn astArgLambdaArity(arg: *const Expr) ?u8 {
    return switch (arg.*) {
        .Lambda => |l| if (l.implicit_it) @as(u8, 0) else @intCast(l.params.len),
        .AnonFun => |af| @intCast(af.params.len),
        else => null,
    };
}

/// One argument's applicability `ArgShape` at LOWERING time. Only the
/// fields lowering can prove cheaply and soundly are populated — named /
/// spread / lambda binding shape, a literal kind, and the declared-type
/// head of a plain local/param argument; `runtime_class` /
/// `lambda_param_types` / `value` stay null, so the shared scorer treats
/// the arg as UNKNOWN (base points, never disproven) wherever the type is
/// not statically decidable. Declared-type evidence is additive-only in
/// the scorer: it can promote a head-matching candidate but never
/// disqualify one.
fn shapeOfAstArg(b: *FuncBuilder, arg: *const Expr, name: ?[]const u8) applicability.ArgShape {
    return .{
        .named = name,
        .is_spread = arg.* == .Spread,
        .is_lambda = arg.* == .Lambda or arg.* == .AnonFun,
        .lambda_arity = astArgLambdaArity(arg),
        .literal_kind = if (argEvidenceLitKind(b, arg)) |k| switch (k) {
            .numeric => .numeric,
            .string => .string,
            .boolean => .boolean,
            .char => .char,
        } else null,
        .ty = argDeclTypeRef(b, arg),
    };
}

/// Literal-kind evidence for an argument: the argument itself is a literal,
/// or it names a local whose recorded initializer is one (`val x = 1.0;
/// f(x)`). Evidence only, never disproving.
fn argEvidenceLitKind(b: *FuncBuilder, arg: *const Expr) ?LitKind {
    if (argLitKind(arg)) |k| return k;
    if (arg.* == .Path and arg.Path.segments.len == 1) {
        if (b.localInitExpr(arg.Path.segments[0].name)) |init_e| {
            return argLitKind(init_e);
        }
    }
    return null;
}

/// Declared-type head of a single-segment Path argument naming a local /
/// parameter whose declared type is known (`b.localDeclType`), as a `TypeRef`
/// for the shared scorer's declared-type evidence. Null for anything else.
fn argDeclTypeRef(b: *FuncBuilder, arg: *const Expr) ?ir.TypeRef {
    // The E2.1 type-head channel exists (Module.eagerTypeOf) but does
    // NOT feed evidence yet: typeck's permissive inference can hand back
    // a wrong container head (a ByteArray value typed Iterable), and a
    // wrong head DISPROVES valid candidates downstream. The seam flips
    // only after the type-head audit below reaches zero disagreement,
    // mirroring the call channel's per-class trust discipline.
    var lazy_ans = argDeclTypeRefLazy(b, arg);
    // E2.1, ADDITIVE-ONLY: typeck's head fills in where the AST probes
    // have no answer; the declared (AST) answer always wins when both
    // exist — kotlinc resolves overloads against the STATIC DECLARED
    // type, and the audit shows the only both-exist deltas are the
    // legitimate declared-wider-vs-inferred-narrower class.
    if (lazy_ans == null) {
        if (b.module.eagerTypeOf(arg.span())) |th| {
            if (typeheadAuditOn()) {
                const sp = arg.span();
                std.debug.print("[TYPEHEAD-FILL] f{d}:{d} typeck={s}{s}\n", .{ sp.file.int(), sp.start, th.name, if (th.nullable) @as([]const u8, "?") else "" });
            }
            lazy_ans = .{ .name = th.name, .nullable = th.nullable, .args = &.{} };
        }
    }
    if (typeheadAuditOn()) {
        if (b.module.eagerTypeOf(arg.span())) |th| {
            if (lazy_ans) |la| {
                if (!std.mem.eql(u8, la.name, th.name) or la.nullable != th.nullable) {
                    const sp = arg.span();
                    std.debug.print("[TYPEHEAD-AUDIT] f{d}:{d} ast={s}{s} typeck={s}{s}\n", .{
                        sp.file.int(),           sp.start,
                        la.name,                 if (la.nullable) @as([]const u8, "?") else "",
                        th.name,                 if (th.nullable) @as([]const u8, "?") else "",
                    });
                }
            }
        }
    }
    return lazy_ans;
}

fn typeheadAuditOn() bool {
    const S = struct {
        var cached: ?bool = null;
    };
    if (S.cached) |v| return v;
    const on = runtime.getenvSlice("KLIO_TYPEHEAD_AUDIT") != null;
    S.cached = on;
    return on;
}

fn argDeclTypeRefLazy(b: *FuncBuilder, arg: *const Expr) ?ir.TypeRef {
    // An unsafe cast fixes the argument's static type for overload
    // resolution — kotlinc sees exactly the cast target. That is the
    // documented way to force a sibling overload (ktor's deprecated
    // `P.install` delegates with `install(plugin as Plugin<P, B, F>,
    // configure)`; without the cast evidence the call binds itself and
    // recurses forever).
    if (arg.* == .As and !arg.As.safe) {
        return .{ .name = loweredTypeName(b, &arg.As.ty), .nullable = arg.As.ty.nullable, .args = &.{} };
    }
    if (arg.* != .Path) return null;
    const p = arg.Path;
    if (p.segments.len != 1) return null;
    if (b.localDeclType(p.segments[0].name)) |t| {
        return .{ .name = t, .nullable = b.localDeclNullable(p.segments[0].name), .args = &.{} };
    }
    // A bare class name used as a value is its companion object: carry the
    // owner class's head as type evidence so `install(RoutingRoot, ...)`
    // cannot bind an overload whose parameter is an unrelated object type.
    const nm = p.segments[0].name;
    if (b.resolve(nm) == null and !b.knowsOuter(nm) and b.module.classId(nm) != null) {
        return .{ .name = nm, .nullable = false, .args = &.{} };
    }
    return null;
}

/// Build the `[]ArgShape` for a call's argument list once, before the
/// `resolveCall` query, replacing the per-rung `findCand` / `arityMatch`
/// walks. Borrows from `b.allocator` (a lowering scratch arena).
fn buildArgShapes(b: *FuncBuilder, args: []const Expr, arg_names: []const ?[]const u8) Allocator.Error![]applicability.ArgShape {
    const shapes = try b.allocator.alloc(applicability.ArgShape, args.len);
    for (args, 0..) |*a, i| {
        const nm: ?[]const u8 = if (i < arg_names.len) arg_names[i] else null;
        shapes[i] = shapeOfAstArg(b, a, nm);
    }
    return shapes;
}

/// Builtin value kind a declared parameter type accepts, or null when unknown
/// (a user class, a type parameter, `Any`, …) — those never disprove.
fn paramLitKind(type_name: []const u8) ?LitKind {
    const n = std.mem.trimEnd(u8, type_name, "?");
    const eq = std.mem.eql;
    if (eq(u8, n, "Int") or eq(u8, n, "Long") or eq(u8, n, "Short") or eq(u8, n, "Byte") or
        eq(u8, n, "UInt") or eq(u8, n, "ULong") or eq(u8, n, "UShort") or eq(u8, n, "UByte") or
        eq(u8, n, "Double") or eq(u8, n, "Float") or eq(u8, n, "Number")) return .numeric;
    if (eq(u8, n, "String") or eq(u8, n, "CharSequence")) return .string;
    if (eq(u8, n, "Boolean")) return .boolean;
    if (eq(u8, n, "Char")) return .char;
    return null;
}

/// True when a same-name factory's declared parameter types DEFINITELY cannot
/// accept the argument kinds — so the bare `Name(args)` constructs the class
/// rather than calling the factory. The argument kind comes from the same
/// evidence the shared scorer sees: a literal (direct or through a recorded
/// local initializer), a declared local/param type head, or the typeck
/// type-head channel (`Box(s.length)` inside `fun Box(s: String)` proves Int
/// against the factory's String and constructs the class). Conservative: an
/// unknown argument or parameter kind never disproves, so only a
/// known-kind-vs-builtin mismatch flips the decision.
fn factorySigRejectsArgs(b: *FuncBuilder, sig: []const ir.TypeRef, args: []const Expr) bool {
    for (args, 0..) |*a, i| {
        if (i >= sig.len) break;
        var ak_opt = argEvidenceLitKind(b, a);
        if (ak_opt == null) {
            if (argDeclTypeRef(b, a)) |ty| ak_opt = paramLitKind(ty.name);
        }
        const ak = ak_opt orelse continue;
        const pk = paramLitKind(sig[i].name) orelse continue;
        if (ak != pk) return true;
    }
    return false;
}

fn shadowedByClass(b: *FuncBuilder, callee: *const Expr, args: []const Expr) Allocator.Error!bool {
    if (callee.* != .Path or callee.Path.segments.len != 1) return false;
    const name = callee.Path.segments[0].name;
    // Resolve the class the SAME way the construct path below does — through
    // the scope-aware index (file imports, then self package, then global) —
    // not the simple-name-global `classId`, which picks an arbitrary winner on
    // a cross-package simple-name collision. Otherwise a bare `Name(args)` here
    // can be judged against the wrong same-named class (e.g. an abstract
    // `kotlinx.coroutines.internal.Segment` shadowing the concrete
    // `kotlinx.io.Segment` at its own construction site), inverting the
    // ctor-vs-factory decision.
    const cid = b.module.classIdIndexed(name, b.self_package, callee.Path.segments[0].span.file) orelse return false;
    // An abstract/interface/sealed class cannot be constructed, so a bare
    // `Name(args)` is never a constructor call — it is a same-named factory
    // function (`fun Random(seed): Random`). Resolve it as a function (the
    // runtime global lookup finds the factory) rather than emitting a
    // `NewInstance` that aborts on the abstract class at run time.
    if (cid.int() < b.module.classes.items.len and b.module.classes.items[cid.int()].is_abstract) return false;
    const nargs = args.len;
    // Scope rule (spec: overload resolution walks scopes inside-out): inside
    // the class's own body — including its companion — the class's
    // constructor is a nearer-scope candidate than any same-named
    // package-level factory, so an applicable constructor decides the call.
    // `Path(normalized)` inside `Path.of` binds the private constructor; the
    // `fun Path(String)` factory calling back into `of` would recurse.
    if (b.ownerClass()) |oc| {
        // A companion body's owner is the lifted companion class; its name is
        // the class name with one or more `$Companion` suffixes. Stripping
        // them recovers the class whose scope the call sits in.
        var oc_base: []const u8 = oc;
        while (std.mem.endsWith(u8, oc_base, "$Companion")) {
            oc_base = oc_base[0 .. oc_base.len - "$Companion".len];
        }
        const in_own_scope = std.mem.eql(u8, oc_base, name) or blk: {
            if (cid.int() < b.module.classes.items.len) {
                if (b.module.classes.items[cid.int()].companion) |comp| {
                    if (comp.int() < b.module.classes.items.len) {
                        break :blk std.mem.eql(u8, b.module.classes.items[comp.int()].name, oc);
                    }
                }
            }
            break :blk false;
        };
        if (in_own_scope and cid.int() < b.module.classes.items.len) {
            const ps = b.module.classes.items[cid.int()].primary_params;
            var required: usize = 0;
            var has_vararg = false;
            for (ps) |*p| {
                if (p.is_vararg) {
                    has_vararg = true;
                    continue;
                }
                if (!p.has_default) required += 1;
            }
            if (nargs >= required and (has_vararg or nargs <= ps.len)) return true;
        }
    }
    if (lastArgIsLambda(args)) {
        // A trailing lambda routes to a same-named factory with a
        // function-typed param to receive it; only when none fits is it a ctor.
        var factory_takes_lambda = false;
        for (b.module.func_index.items) |entry| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            const f = b.module.funcById(entry.id) orelse continue;
            const last_vararg = f.params.len != 0 and f.params[f.params.len - 1].is_vararg;
            const arity_ok = last_vararg or nargs <= f.params.len;
            if (arity_ok and anyFunctionParam(f.params)) {
                factory_takes_lambda = true;
                break;
            }
        }
        return !factory_takes_lambda;
    }
    // No lambda — ctor when the canonical factory can't take that many args,
    // or no same-named factory is applicable to the positional count.
    var canonical_cant_take = false;
    if (b.module.funcId(name)) |fid| {
        if (b.module.funcById(fid)) |f| {
            const last_vararg = f.params.len != 0 and f.params[f.params.len - 1].is_vararg;
            canonical_cant_take = !last_vararg and nargs > f.params.len;
        }
    }
    var any_factory_applicable = false;
    for (b.module.func_index.items) |entry| {
        if (!std.mem.eql(u8, entry.name, name)) continue;
        if (b.module.decl_user_arity.get(entry.id.int())) |arity| {
            const n: u32 = @intCast(nargs);
            if (n >= arity.required and (arity.has_vararg or n <= arity.total)) {
                // A same-arity factory whose declared parameter types
                // definitely cannot accept the literal argument types is not
                // applicable — the call constructs the class instead. This is
                // what tells `Box(5)` (ctor `Box(Int)`) from the same-arity
                // factory `fun Box(s: String)`.
                if (b.module.decl_user_sig.get(entry.id.int())) |sig| {
                    if (factorySigRejectsArgs(b, sig, args)) continue;
                }
                any_factory_applicable = true;
                break;
            }
        }
    }
    return canonical_cant_take or !any_factory_applicable;
}

fn anyFunctionParam(params: []const ir.Param) bool {
    for (params) |p| {
        if (std.mem.startsWith(u8, p.ty.name, "Function")) return true;
    }
    return false;
}

/// Path-callee bare-name → Call ladder. Returns null when no top-level fn /
/// the class path should handle it instead.
fn lowerPathCall(b: *FuncBuilder, expr: *const Expr, shadowed_by_class: bool, class_competes: bool) Allocator.Error!?Reg {
    const call = expr.Call;
    const callee = call.callee;
    const args = call.args;
    const ast_arg_names = call.arg_names;
    const ast_type_args = call.type_args;
    const segments = callee.Path.segments;
    const name0 = segments[0].name;

    // A captured outer that also names a top-level fn: route through value.
    const shadowed_by_local = b.knowsOuter(name0) and b.resolve(name0) == null and
        b.module.funcId(name0) != null;
    if (shadowed_by_local) {
        const callee_r = try resolveCapture(b, name0);
        // Only a captured local *extension* function or a receiver-lambda param
        // takes the enclosing receiver as a leading `this`; a plain captured
        // local function (`fun check(a, b)` called from inside a `repeat { }`
        // lambda) must dispatch as a bare value, or `callValueWithThis`'s
        // receiver-fills-param heuristic shifts the enclosing `this` into the
        // first value parameter.
        const wants_this = b.isLocalExtFn(name0) or b.isReceiverLambdaParam(name0);
        const this_reg: ?Reg = if (wants_this)
            (if (b.knowsOuter("this") or b.capturesThisSlot())
                try resolveCapture(b, "this")
            else
                b.resolve("this"))
        else
            null;
        const run = try lowerArgRun(b, args);
        const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
        const dst = b.allocReg();
        if (this_reg) |recv| {
            try b.push(.{ .CallValueWithThis = .{
                .dst = dst,
                .callee = callee_r,
                .receiver = recv,
                .args = run[0],
                .n_args = run[1],
                .arg_names = arg_names,
            } });
        } else {
            try b.push(.{ .CallValue = .{
                .dst = dst,
                .callee = callee_r,
                .args = run[0],
                .n_args = run[1],
                .arg_names = arg_names,
            } });
        }
        return dst;
    }

    // FQN-precedence: a UNIQUE explicit import routes a collision call.
    // Two same-leaf imports are no shadow — Kotlin keeps both in scope —
    // so a collision among the imports themselves falls through to the
    // symbol index, which classifies the tie (ambiguous when the
    // signatures are identical, type-dispatched otherwise).
    const collision = b.module.funcsBySimpleName(name0).len > 1;
    var imported_func_id: ?FuncId = null;
    if (collision) {
        const alias_paths = b.module.importAliasPathsIn(segments[0].span.file, name0);
        if (alias_paths.len == 1 and alias_paths[0].segs.len >= 2) {
            imported_func_id = b.module.funcIdByFqn(alias_paths[0].fqn);
        }
    }
    if (imported_func_id) |func_id| {
        if (!shadowed_by_class) {
            const needs_this = blk: {
                if (b.module.funcById(func_id)) |f| {
                    break :blk f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this");
                }
                break :blk false;
            };
            if (!needs_this) {
                // Import-routed binds run the index + audit too, so the
                // detector keeps one line per bare call and a unique
                // index pick (the exact-arity overload behind the
                // imported FQN) is preferred over the first FQN match.
                const ires = b.module.resolveBareCallIndexed(
                    name0,
                    b.self_package,
                    segments[0].span.file,
                    args.len,
                    lastArgIsLambda(args),
                );
                resolveAudit(b, name0, segments[0].span.file, args.len, lastArgIsLambda(args), func_id, .imported, ires, shadowed_by_class, false);
                if (indexDeferReason(ires) == .ambiguous_tier) {
                    try recordAmbiguousCall(b, name0, segments[0].span, ires);
                }
                const bind_id = ires.pick() orelse func_id;
                const run = try lowerArgRun(b, args);
                const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
                const type_args = try internTypeArgs(b.allocator, b.module, ast_type_args);
                const dst = b.allocReg();
                try b.push(.{ .Call = .{
                    .dst = dst,
                    .func = bind_id,
                    .args = run[0],
                    .n_args = run[1],
                    .arg_names = arg_names,
                    .type_args = type_args,
                    .exact = false,
                } });
                return dst;
            }
        }
    }

    // Bare-call resolution through the unified resolver. `resolveCall` folds
    // the scope index, the applicability ladder and the member-vs-global emit
    // decision into one query; the switch below routes its verdict to a single
    // emitter.
    const want = args.len;
    const cands = b.module.funcsBySimpleName(name0);
    const last_arg_lambda = lastArgIsLambda(args);

    // An own member applicable to this call outranks a same-named top-level
    // function: defer to the member-dispatch path (`lowerImplicitThisCall`). A
    // cast at the call site commits to a specific overload and overrides.
    const prefer_member = b.resolve("this") != null and b.hasOwnMember(name0) and
        b.ownMemberApplicable(name0, args.len) and
        b.resolve(name0) == null and !b.isLocalFn(name0) and !b.isLocalExtFn(name0);

    const cast_pick: ?FuncId = try overloadPickByCast(b, cands, args, want);

    // The index classification, for the ambiguity / out-of-scope diagnostics.
    // A cast at the call site pre-picks a same-tier overload, so an ambiguity
    // or type-overload deferral is not reported.
    var index_res = b.module.resolveBareCallIndexed(
        name0,
        b.self_package,
        segments[0].span.file,
        want,
        last_arg_lambda,
    );
    if (cast_pick != null) {
        const r = indexDeferReason(index_res);
        if (r == .ambiguous_tier or r == .type_overload) {
            index_res.outcome = .{ .deferred = .cast_disambiguated };
        }
    }

    if (prefer_member and cast_pick == null) return null;

    const shapes = try buildArgShapes(b, args, ast_arg_names);
    defer b.allocator.free(shapes);
    const ctx = resolveCtxFor(b, name0, ast_type_args, cast_pick);
    const res = try b.module.resolveCall(b.allocator, name0, b.self_package, segments[0].span.file, shapes, last_arg_lambda, ctx);
    // Eager audit: where typeck recorded a pick for this call site,
    // compare it against the engine's answer. Audit-only — behavior
    // flips seam by seam once disagreement is at zero.
    if (eagerAuditOn() and runtime.getenvSlice("KLIO_EAGER_HITS") != null) {
        std.debug.print("[EAGER-PROBE] '{s}' f{d}:{d}-{d} map={}\n", .{ name0, segments[0].span.file.int(), segments[0].span.start, segments[0].span.end, b.module.eager_calls != null });
    }
    var res_final = res;
    if (b.module.eagerCallTarget(segments[0].span)) |eager_fid| eager: {
        // A pick that resolves the call back to the ENCLOSING declaration
        // while the lazy engine chose otherwise is distrusted: stdlib
        // overload families delegate to same-name siblings, and a
        // mis-picked self-target recurses forever.
        if (b.self_decl_span) |sds| {
            const ec = &(b.module.eager_calls.?);
            if (ec.get(segments[0].span)) |decl| {
                if (decl.file.int() == sds.file.int() and decl.start == sds.start and decl.end == sds.end and
                    (res.target == null or res.target.?.int() != eager_fid.int()))
                {
                    break :eager;
                }
            }
        }
        // Consumption: the typeck-decided target is type-derived and
        // overload-precise where the lazy engine is shape-based; prefer
        // it. `ty_proven` pins the pick against runtime value-typed
        // re-picks, matching a cast-disambiguated call.
        if (res.target == null or res.target.?.int() != eager_fid.int()) {
            res_final.target = eager_fid;
            res_final.ty_proven = true;
            if (res_final.emit_form != .Call) res_final.emit_form = .Call;
        }
        if (eagerAuditOn()) {
            const lazy: ?FuncId = res.target;
            if (runtime.getenvSlice("KLIO_EAGER_HITS") != null) {
                std.debug.print("[EAGER-HIT] '{s}'\n", .{name0});
            }
            if (lazy == null or lazy.?.int() != eager_fid.int()) {
                const lazy_str: i64 = if (lazy) |l| @intCast(l.int()) else -1;
                const efqn: []const u8 = if (b.module.funcById(eager_fid)) |f| f.fqn else "?";
                const lfqn: []const u8 = if (lazy) |l| (if (b.module.funcById(l)) |f| f.fqn else "?") else "-";
                std.debug.print("[EAGER-AUDIT] call '{s}': eager={d}({s}) lazy={d}({s})\n", .{ name0, eager_fid.int(), efqn, lazy_str, lfqn });
            }
        }
    }
    defer b.allocator.free(res_final.candidate_set);
    const was_cast = cast_pick != null and res_final.target != null and cast_pick.?.int() == res_final.target.?.int();

    // A known stdlib host-intrinsic global (alias) whose user overloads do not
    // apply to this call still resolves to the intrinsic global. In a receiver
    // context, bind it directly — no class declares the name as a member, so a
    // `this.<name>` redispatch would invoke the receiver itself.
    if (res_final.target == null and !shadowed_by_class and inReceiverContext(b) and
        ir.isAliasName(name0) and !anyReceiverClassDeclares(b, name0) and
        !extensionCandidateFitsArity(b, name0, args.len) and
        b.resolve(name0) == null and !b.knowsOuter(name0))
    {
        return try emitValueCall(b, args, ast_arg_names, ast_type_args, name0);
    }

    if (res_final.target) |target| {
        if (!shadowed_by_class) {
            // A constructible same-named class competes with this pick and
            // the pick is not type-proven: yield to the class arm's deferred
            // class-carrying emission, where the runtime decides
            // ctor-vs-factory on the actual argument types.
            if (class_competes and !res_final.ty_proven and !was_cast) return null;
            if (indexDeferReason(index_res) == .ambiguous_tier) {
                try recordAmbiguousCall(b, name0, segments[0].span, index_res);
            }
            // A target in a package the caller cannot see is an unresolved
            // reference (kotlinc rejects the call); the diagnostic fails the
            // program before it runs.
            _ = try recordOutOfScopeCall(b, name0, segments[0].span, target, index_res);
            return switch (res_final.emit_form) {
                // A fully type-proven pick is as final as a cast pick: the
                // runtime's value-typed overload re-pick must not override it.
                .Call => try emitCall(b, expr, target, was_cast or res_final.ty_proven),
                .CallMember => try emitCallMember(b, expr, target, was_cast),
                .CallMemberOrGlobal => try emitMemberOrGlobal(b, expr, target, was_cast),
                // Phase C never emits a value call with a committed target.
                .CallValue => unreachable,
            };
        }
    }
    return null;
}

/// The receiver-context bits `resolveCall` folds into its emit-form decision,
/// read once from the builder. Shared by the live path and the audit shadow so
/// both query `resolveCall` identically.
fn resolveCtxFor(b: *FuncBuilder, name0: []const u8, ast_type_args: []const ast.TypeRef, cast_pick: ?FuncId) ir.Module.ResolveCtx {
    return .{
        .in_receiver_context = inReceiverContext(b),
        .unknown_receiver = b.capturesThisSlot() or b.isParamThunk() or
            (b.recvTy() != null and !fnTypedRecvCannotShadow(b, name0)),
        .enclosing_has_member = b.hasEnclosingMember(name0) or blk: {
            const oc = b.ownerClass() orelse break :blk false;
            break :blk (ownerChainShadowContains(b, oc, name0) orelse false);
        },
        .receiver_known = receiverTypeKnown(b, name0),
        .has_type_args = ast_type_args.len != 0,
        .cast_pick = cast_pick,
        .recv_ty = b.recvTy(),
        .is_value_capture = b.knowsOuter(name0) and b.resolve(name0) == null,
        .in_tailrec_body = b.tailrecSelf() != null,
    };
}

fn indexDeferReason(res: ir.Module.BareCallResolution) ?ir.Module.ResolveDeferReason {
    return switch (res.outcome) {
        .resolved => null,
        .deferred => |r| r,
    };
}

/// Kotlin does not resolve a value-position reference — `::name`, a
/// `::Ctor`, or a bare read — whose only declaration lives in a package
/// the caller neither declares, imports, nor sees by default. Record the
/// unresolved diagnostic (the same one the bare-call path emits) when the
/// reference would otherwise bind such an out-of-scope declaration. A
/// reference denotes the declaration itself, so there is no arity or
/// member-redispatch shape to defer on: a tier-5 verdict is final, exactly
/// as for the call form. Returns true when the diagnostic was recorded so
/// the caller can suppress the lenient bind.
fn recordOutOfScopeRef(
    b: *FuncBuilder,
    name: []const u8,
    ref_span: ir.Span,
    fqn: []const u8,
    tier: ?u8,
) Allocator.Error!bool {
    if (tier != ir.Module.other_package_tier) return false;
    // The verdict is trustworthy only when the declaration carries a real
    // package: a bare FQN (no package prefix) is a lift artifact whose
    // scoping metadata is unreliable — an upstream class such as
    // `io.ktor.utils.io.ClosedByteChannelException` can lose its package
    // during the lift and read as the empty package even when the
    // reference is same-package and genuinely in scope. The resolver still
    // binds it (`classIdIndexed`/`resolveBareRefIndexed` return the best
    // pick); rejecting it would be a false positive, so a bare-FQN
    // declaration is never reported out of scope.
    if (std.mem.indexOfScalar(u8, fqn, '.') == null) return false;
    try b.module.resolve_diags.append(b.allocator, .{
        .name = name,
        .fqn_a = fqn,
        .fqn_b = "",
        .span = ref_span,
        .kind = .unresolved,
    });
    return true;
}

/// The FQN of a class by id, for an out-of-scope value-reference
/// diagnostic.
fn classFqnOf(b: *FuncBuilder, id: ir.ClassId) []const u8 {
    if (idGet(ir.Class, b.module.classes.items, id.int())) |c| return c.fqn;
    return "<invalid>";
}

/// The target a bare call binds when both the heuristic and the index
/// produced one: the index's exact-FQN pick wins, EXCEPT when the
/// heuristic chose an extension (implicit `this`) and the index a plain
/// top-level sibling. The index never models receivers, so an extension
/// the receiver ladder matched must not be overridden by its
/// non-extension namesake (Kotlin resolves the in-scope receiver's
/// extension over the top-level function).
fn preferredBareTarget(b: *FuncBuilder, heuristic: FuncId, index_pick: ?FuncId) FuncId {
    const idx = index_pick orelse return heuristic;
    if (!isNonExt(b, heuristic) and isNonExt(b, idx)) return heuristic;
    return idx;
}

/// Record an ambiguous bare call into the module's lowering diagnostics.
/// The build driver reports these before the program runs. Each
/// candidate carries its declaration span (from the phase-1 header
/// record) so a true duplicate's report can point at both declarations.
fn recordAmbiguousCall(b: *FuncBuilder, name: []const u8, call_span: ir.Span, res: ir.Module.BareCallResolution) Allocator.Error!void {
    const fqn_a = if (res.first) |f| fqnOf(b, f) else "?";
    const fqn_b = if (res.second) |s| fqnOf(b, s) else "?";
    const span_a: ?ir.Span = if (res.first) |f| b.module.decl_span.get(f.int()) else null;
    const span_b: ?ir.Span = if (res.second) |s| b.module.decl_span.get(s.int()) else null;
    try b.module.resolve_diags.append(b.allocator, .{
        .name = name,
        .fqn_a = fqn_a,
        .fqn_b = fqn_b,
        .span = call_span,
        .span_a = span_a,
        .span_b = span_b,
    });
}

/// Kotlin does not resolve an unqualified call whose every candidate
/// lives in a package the caller neither declares, imports, nor sees by
/// default (kotlinc: "unresolved reference"). When the bound target is a
/// plain top-level function in such a package, record the unresolved
/// diagnostic — naming the candidates and how to import them — and tell
/// the caller to suppress the bind. Receiver-bound extensions are the
/// heuristic's domain and never classify as out of scope here. The
/// corpus sweep (examples + coroutine fixtures + the lowered stdlib and
/// pack sources, KLIO_RESOLVE_AUDIT) resolves zero calls at this tier,
/// so the error only fires on programs kotlinc already rejects.
fn recordOutOfScopeCall(
    b: *FuncBuilder,
    name: []const u8,
    call_span: ir.Span,
    final_id: FuncId,
    index_res: ir.Module.BareCallResolution,
) Allocator.Error!bool {
    const file = call_span.file;
    // A bare call whose name is a known class member and that sits in a
    // receiver context is routed to runtime member-or-global dispatch by
    // `emitBareFuncCall` (`CallMemberOrGlobal`): the implicit receiver may
    // supply the member, so the reference is not out of scope even when
    // the only package-scope candidate is unimported. kotlinc resolves
    // `fun Source.discard() { request(count) }` to the receiver's
    // `request` member, not the package-scope `request` function.
    if (inReceiverContext(b) and anyReceiverClassDeclares(b, name)) return false;
    // Only the index's own out-of-scope verdicts count: a unique
    // exact-arity match, or a tier-5 candidate set (identical or
    // type-distinct). Loose-shape deferrals (arity/default/vararg/
    // bodyless) stay with the heuristic — those binds are provisional
    // and the runtime may still dispatch a member or re-pick an
    // overload (`list.apply { add(x) }` must not error because a
    // user file declares a top-level `add`).
    const precise = switch (index_res.outcome) {
        .resolved => true,
        .deferred => |r| r == .unimported_set or r == .type_overload,
    };
    // A loose-shape deferral (default/vararg/trailing-lambda arity, an
    // unmatched arity, a low-priority-only or bodyless-only set) is
    // unresolved too WHEN every rankable candidate is out of scope — the
    // winning tier is `other_package_tier`, i.e. there is no in-scope
    // candidate of any shape the runtime could re-pick. The member-
    // redispatch guard is `inReceiverContext`: inside a receiver context a
    // runtime member of the same name may still bind (kotlinc resolves
    // `g.apply { greet() }` to `g`'s member even when a top-level `greet`
    // is out of scope), so the loose-shape rejection only fires outside
    // any receiver context, where no implicit receiver can supply the
    // call. The bare-call member-shadowable routing already sends those
    // receiver-context calls to `CallMemberOrGlobal` rather than here.
    const loose_out_of_scope = switch (index_res.outcome) {
        .resolved => false,
        .deferred => |r| switch (r) {
            .default_param_shape,
            .vararg_only,
            .trailing_lambda_shape,
            .arity_mismatch,
            .low_priority_only,
            .bodyless_only,
            => index_res.tier == ir.Module.other_package_tier and !inReceiverContext(b),
            // The index defers a vararg/default call to `extension_form`
            // when an in-scope extension namesake exists, since it cannot
            // tell whether the receiver applies. Outside any receiver
            // context no receiver can supply such an extension, so a
            // heuristic that landed on a tier-5 NON-extension top-level
            // function is the same unresolved reference kotlinc rejects.
            // The `isNonExt(final_id)` + tier-5 checks below confirm the
            // bound target is out of scope before this fires.
            .extension_form => !inReceiverContext(b),
            else => false,
        },
    };
    if (!precise and !loose_out_of_scope) return false;
    if (!isNonExt(b, final_id)) return false;
    const tier = b.module.bareCallTierOf(final_id, name, b.self_package, file) orelse return false;
    if (tier != ir.Module.other_package_tier) return false;
    // A bare-FQN target (no package prefix) is a lift artifact with
    // unreliable scoping metadata; never report it out of scope (see
    // `recordOutOfScopeRef`).
    if (std.mem.indexOfScalar(u8, fqnOf(b, final_id), '.') == null) return false;
    const fqn_a = if (index_res.first) |f| fqnOf(b, f) else fqnOf(b, final_id);
    const fqn_b = if (index_res.second) |s2| fqnOf(b, s2) else "";
    try b.module.resolve_diags.append(b.allocator, .{
        .name = name,
        .fqn_a = fqn_a,
        .fqn_b = fqn_b,
        .span = call_span,
        .kind = .unresolved,
    });
    return true;
}

/// How a bare-call index/heuristic divergence is explained. Anything
/// but `unexplained` is a classified structural shape, not a mis-bind.
const DivergenceGrade = enum {
    /// The index pick ranks in a strictly better preference tier: the
    /// heuristic's declaration-order pick missed a named-import /
    /// own-package candidate whose body lowers later. Binding takes the
    /// index pick.
    tier_correction,
    /// Same tier, but the heuristic fell back to a candidate that does
    /// not match the call exactly (trailing vararg, default parameters,
    /// arity mismatch, or an unrankable stub) while the index resolved
    /// an exact overload. Binding takes the index pick.
    shape_correction,
    /// The heuristic bound a receiver-matched extension; the index — by
    /// contract blind to receivers — resolved the plain top-level
    /// namesake. Binding keeps the heuristic's extension (Kotlin
    /// resolves the in-scope receiver's extension over the top-level
    /// function).
    receiver_pref,
    /// No classified shape explains the divergence: an interpreter bug,
    /// never a program property.
    unexplained,
};

/// Opt-in consistency detector for the symbol index (`KLIO_RESOLVE_AUDIT`).
/// Emits one machine-readable line per bare call — name, caller package,
/// file, requested arity, index outcome + deferral reason, winning tier
/// and its candidate count, the heuristic's pick, the emitted call
/// shape, and (for a divergence) its grade — plus a `divergence:` line
/// whenever the index and the heuristic resolve the same call to
/// different targets without a classified explanation
/// (`DivergenceGrade`). A non-zero unexplained divergence count means
/// the index mis-binds on the audited program.
///
/// `KLIO_RESOLVE_STRICT` (independent of the audit) turns an
/// unexplained divergence into a hard failure: the index and the
/// heuristic binding different same-tier same-shape targets for one
/// bare call is an interpreter bug, never a program property.
fn resolveAudit(
    b: *FuncBuilder,
    name: []const u8,
    file: ir.FileId,
    want: usize,
    last_arg_lambda: bool,
    heuristic: ?FuncId,
    rung: HeurRung,
    index_res: ir.Module.BareCallResolution,
    shadowed_by_class: bool,
    prefer_member: bool,
) void {
    const audit_on = resolveAuditOn();
    const strict_on = resolveStrictOn();
    if (!audit_on and !strict_on) return;

    const final: ?FuncId = if (heuristic) |h|
        preferredBareTarget(b, h, index_res.pick())
    else
        index_res.pick();
    const shape: []const u8 = if (heuristic == null and prefer_member)
        "member_pref"
    else if (heuristic == null)
        "fallthrough"
    else if (shadowed_by_class)
        "shadowed_class"
    else if (final != null and !isNonExt(b, final.?))
        "ext_bound"
    else
        "bound";

    // A divergence is the index and the heuristic resolving the SAME
    // call to DIFFERENT targets. Each one is graded: a tier or shape
    // correction (the index fixing the heuristic's declaration-order /
    // fallback-shape blind spots, binding the index pick), a receiver
    // preference (the heuristic's extension pick retained), or
    // unexplained — an interpreter bug. The index resolving where the
    // heuristic declined is none of these: the binding is gated on the
    // heuristic, so the pick is discarded (the readout records it as
    // `shape=fallthrough outcome=resolved`).
    const divergent = switch (index_res.outcome) {
        .deferred => false,
        .resolved => |idx| if (heuristic) |heur| idx.int() != heur.int() else false,
    };
    const grade: ?DivergenceGrade = if (!divergent) null else blk: {
        const heur_id = heuristic.?;
        const idx_id = index_res.pick().?;
        if (!isNonExt(b, heur_id) and isNonExt(b, idx_id)) break :blk .receiver_pref;
        const heur_tier = b.module.bareCallTierOf(heur_id, name, b.self_package, file) orelse 255;
        if (index_res.tier < heur_tier) break :blk .tier_correction;
        if (heurPickInexact(b, heur_id, want)) break :blk .shape_correction;
        break :blk .unexplained;
    };
    const explained = grade != null and grade.? != .unexplained;

    if (audit_on) {
        const outcome: []const u8 = switch (index_res.outcome) {
            .resolved => "resolved",
            .deferred => "deferred",
        };
        const reason: []const u8 = switch (index_res.outcome) {
            .resolved => "-",
            .deferred => |r| @tagName(r),
        };
        const idx_fqn: []const u8 = switch (index_res.outcome) {
            .resolved => |id| fqnOf(b, id),
            .deferred => "-",
        };
        const heur_fqn: []const u8 = if (heuristic) |h| fqnOf(b, h) else "-";
        const grade_tag: []const u8 = if (grade) |g| @tagName(g) else "-";
        std.debug.print(
            "[KLIO_RESOLVE_AUDIT] call name={s} pkg={s} file={d} arity={d} tl={d} outcome={s} reason={s} index_fqn={s} tier={d} tier_count={d} heur_fqn={s} rung={s} shape={s} divergent={d} correction={d} grade={s}\n",
            .{
                name,                    b.self_package,                file.int(),
                want,                    @intFromBool(last_arg_lambda), outcome,
                reason,                  idx_fqn,                       index_res.tier,
                index_res.tier_count,    heur_fqn,                      @tagName(rung),
                shape,                   @intFromBool(divergent),       @intFromBool(explained),
                grade_tag,
            },
        );
        if (divergent and !explained) resolveAuditLog(b, name, heuristic, index_res.pick().?);
    }

    if (strict_on and divergent and !explained) {
        const heur_id = heuristic.?;
        const heur_tier = b.module.bareCallTierOf(heur_id, name, b.self_package, file) orelse 255;
        std.debug.panic(
            "KLIO_RESOLVE_STRICT: unexplained bare-call divergence on '{s}' (pkg='{s}' file={d} arity={d}): heuristic={s} (tier {d}) index={s} (tier {d})",
            .{ name, b.self_package, file.int(), want, fqnOf(b, heur_id), heur_tier, fqnOf(b, index_res.pick().?), index_res.tier },
        );
    }
}

/// Whether the heuristic's pick matches the call less exactly than any
/// index pick can: an unrankable stub, a vararg at any position, a
/// default parameter, or a declared arity differing from the call's.
/// The index only ever resolves an exact-arity no-default no-vararg
/// candidate, so a same-tier divergence onto such a heuristic pick is
/// the index correcting a fallback shape, not a mis-bind.
fn heurPickInexact(b: *FuncBuilder, fid: FuncId, want: usize) bool {
    const f = b.module.funcById(fid) orelse return true;
    if (!f.hasBody()) {
        const da = b.module.decl_user_arity.get(fid.int()) orelse return true;
        return da.has_vararg or da.required != da.total or da.total != want;
    }
    for (f.params) |p| {
        if (p.is_vararg) return true;
    }
    if (userParams(f) != want) return true;
    const off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
    for (f.params[off..]) |p| {
        if (p.has_default) return true;
    }
    return false;
}

/// True when a bare name in this builder's context can be shadowed by a
/// runtime implicit receiver: lambda bodies (the bound receiver is only
/// known at invoke time), method / extension / ctor-thunk bodies (`this`
/// in scope). In every other context — a plain top-level function body —
/// no implicit receiver exists, so member-vs-global is statically
/// decidable: kotlinc rejects resolving a bare name against a *caller's*
/// receiver (dynamic scope), so those sites emit the static global form.
fn inReceiverContext(b: *const FuncBuilder) bool {
    // A binding named `this` that is an ordinary user parameter (backtick-
    // quoted on a receiver-less function) is not a dispatch receiver.
    const this_binding = !b.this_is_plain_param and b.resolve("this") != null;
    return b.capturesThisSlot() or this_binding or b.ownerClass() != null or
        b.isParamThunk() or b.recvTy() != null;
}

/// An extension declared on a *function type* (`(suspend () -> T).start…`)
/// has a receiver with no members a bare call could bind: a function value's
/// only member surface is `invoke`/`call`. Deferring a resolved top-level call
/// to the runtime member-first walk from such a body is not just unnecessary,
/// it is wrong — the runtime's SAM arm invokes a callable receiver for any
/// member name no extension claims, so `runSafely(completion) { … }` inside
/// `startCoroutineCancellable` would call the suspend block itself instead of
/// the same-file top-level `runSafely`, silently discarding the completion.
fn fnTypedRecvCannotShadow(b: *const FuncBuilder, name: []const u8) bool {
    const rt = b.recvTy() orelse return false;
    if (!std.mem.eql(u8, rt, "<function>")) return false;
    return !std.mem.eql(u8, name, "invoke") and !std.mem.eql(u8, name, "call");
}

/// Whether a bare name in an implicit-receiver context could bind to a member
/// of that receiver, so a static bind to a same-named top-level function would
/// wrongly shadow it. Used to decide whether to defer a resolved bare call to
/// the runtime member-first walk (`CallMemberOrGlobal`).
///
/// A lambda / scope-function / parameter-thunk / extension body has an implicit
/// receiver whose concrete type is unknown at lowering time — it may be a
/// builtin (e.g. `StringBuilder`) whose members are not in `class_member_names`
/// — so such a body always defers. A plain method body's receiver type IS
/// known: its own hierarchy (cross-file supertypes included, through the
/// transitive per-class member set) decides precisely — a member of some
/// unrelated class elsewhere in the program cannot shadow this call. Only a
/// receiver whose type is genuinely unknown falls back to the program-wide
/// member-name set.
/// The E2.3 precise answer for a lambda/thunk context: does the
/// typeck-recorded receiver head's hierarchy declare `name`? Null when
/// no head is recorded or its shadow set is missing/incomplete — the
/// caller stays conservative.
fn lambdaRecvHeadDeclares(b: *const FuncBuilder, name: []const u8) ?bool {
    const h = eagerLambdaRecvHead(b) orelse return null;
    const hs = b.module.registry.hierarchy_shadow_names.get(h) orelse return null;
    if (!hs.complete) return null;
    return hs.names.contains(name);
}

fn memberShadowPossible(b: *const FuncBuilder, name: []const u8) bool {
    if (b.capturesThisSlot() or b.isParamThunk() or
        (b.recvTy() != null and !fnTypedRecvCannotShadow(b, name))) {
        // E2.3: the recorded receiver head answers precisely; when it
        // does NOT declare the name, the remaining implicit receivers
        // (enclosing class, outer chain) are checked below instead of
        // answering a blanket true.
        if (lambdaRecvHeadDeclares(b, name)) |ans| {
            if (ans) return true;
        } else {
            return true;
        }
    }
    if (b.hasEnclosingMember(name)) return true;
    if (b.ownerClass()) |oc| {
        if (ownerChainShadowContains(b, oc, name)) |shadowed| return shadowed;
    }
    return b.module.registry.class_member_names.contains(name);
}

/// Whether `name` is a member anywhere along the owner class's hierarchy
/// OR any of its lifted outer classes' hierarchies (`A$B$C` also checks
/// `A$B` and `A` — a nested class's method body sees the outer classes as
/// implicit receivers). Null when any set along the chain is missing or
/// incomplete: the caller must then stay conservative.
fn ownerChainShadowContains(b: *const FuncBuilder, owner: []const u8, name: []const u8) ?bool {
    var found = false;
    var end = owner.len;
    while (true) {
        const hs = b.module.registry.hierarchy_shadow_names.get(owner[0..end]) orelse return null;
        if (!hs.complete) return null;
        if (name.len != 0 and hs.names.contains(name)) found = true;
        const dollar = std.mem.lastIndexOfScalar(u8, owner[0..end], '$') orelse break;
        end = dollar;
    }
    return found;
}

/// The receiver type at this body is statically known (a plain method
/// body with no unknown-receiver context layered on top), so the
/// member-shadow question is answered by its own hierarchy rather than
/// the program-wide name universe. Mirrored into `ResolveCtx` so
/// `resolveCall`'s Phase C asks the identical question.
/// The direct-bind guards' question — "does any class this context's
/// receiver could be declare `name` as a member". Unlike
/// `memberShadowPossible`, an unknown-receiver context (lambda, thunk,
/// extension body) does NOT answer true: the alias / container-creator /
/// prop-read guards bind DIRECT precisely when no class declares the name,
/// and only a plain method body (receiver types statically known) may
/// narrow the program-wide universe to its own+outer hierarchies.
fn anyReceiverClassDeclares(b: *const FuncBuilder, name: []const u8) bool {
    if (receiverTypeKnown(b, name)) {
        if (b.ownerClass()) |oc| {
            if (ownerChainShadowContains(b, oc, name)) |ans| return ans;
        }
    }
    // E2.3: a lambda context whose receiver head is recorded answers from
    // that head plus the enclosing chain — the program-wide name universe
    // is the fallback only when neither is known.
    if (lambdaRecvHeadDeclares(b, name)) |ans| {
        if (ans) return true;
        if (b.ownerClass()) |oc| {
            if (ownerChainShadowContains(b, oc, name)) |a2| return a2;
        }
        return false;
    }
    return b.module.registry.class_member_names.contains(name);
}

fn receiverTypeKnown(b: *const FuncBuilder, name0: []const u8) bool {
    if (b.capturesThisSlot() or b.isParamThunk() or
        (b.recvTy() != null and !fnTypedRecvCannotShadow(b, name0))) {
        // E2.3: a receiver-LAMBDA body whose receiver head typeck
        // recorded is a known-receiver context — the membership walk can
        // answer from that head instead of the conservative fallback.
        // Audit-only until the sweep is adjudicated.
        if (recvheadAuditOn()) {
            if (eagerLambdaRecvHead(b)) |h| {
                const precise = b.module.registry.hierarchy_shadow_names.get(h) != null;
                std.debug.print("[RECVHEAD-AUDIT] '{s}' head={s} hier={}\n", .{ name0, h, precise });
            }
        }
        return false;
    }
    const oc = b.ownerClass() orelse return false;
    return ownerChainShadowContains(b, oc, "") != null;
}

/// The typeck-recorded receiver head for this builder's lambda body.
fn eagerLambdaRecvHead(b: *const FuncBuilder) ?[]const u8 {
    const sp = b.body_span orelse return null;
    return b.module.eagerRecvHeadOf(sp);
}

fn recvheadAuditOn() bool {
    const S = struct {
        var cached: ?bool = null;
    };
    if (S.cached) |v| return v;
    const on = runtime.getenvSlice("KLIO_RECVHEAD_AUDIT") != null;
    S.cached = on;
    return on;
}

var or_audit_checked: bool = false;
var or_audit_enabled: bool = false;

/// Compile-side half of the `KLIO_OR_AUDIT` detector (the runtime half
/// lives in `ir/eval.zig`): logs every member-vs-global emission decision
/// so a corpus sweep can join emit context against the runtime arm that
/// actually won.
fn orAuditOn() bool {
    if (!or_audit_checked) {
        or_audit_checked = true;
        const a = std.heap.page_allocator;
        if (runtime.procEnvGetVar(a, "KLIO_OR_AUDIT") catch null) |v| {
            defer a.free(v);
            or_audit_enabled = v.len != 0 and !std.mem.eql(u8, v, "0");
        }
    }
    return or_audit_enabled;
}

pub fn orEmitAudit(b: *const FuncBuilder, site: []const u8, inst: []const u8, name: []const u8) void {
    if (!orAuditOn()) return;
    std.debug.print(
        "[KLIO_OR_AUDIT] emit site={s} inst={s} name={s} recvctx={d} pkg={s}\n",
        .{ site, inst, name, @intFromBool(inReceiverContext(b)), b.self_package },
    );
}

var resolve_audit_checked: bool = false;
var resolve_audit_enabled: bool = false;

fn resolveAuditOn() bool {
    if (!resolve_audit_checked) {
        resolve_audit_checked = true;
        const a = std.heap.page_allocator;
        if (runtime.procEnvGetVar(a, "KLIO_RESOLVE_AUDIT") catch null) |v| {
            a.free(v);
            resolve_audit_enabled = true;
        }
    }
    return resolve_audit_enabled;
}

var resolve_strict_checked: bool = false;
var resolve_strict_enabled: bool = false;

/// Test hook: force KLIO_RESOLVE_STRICT on for the current process,
/// bypassing the once-per-process environment read, so an in-process
/// integration test can pin strict mode's verdict on a specific
/// program.
pub fn setResolveStrictForTest(on: bool) void {
    resolve_strict_checked = true;
    resolve_strict_enabled = on;
}

/// Test hook: undo `setResolveStrictForTest` — the next strict-mode
/// read consults the environment again, so a forced setting never
/// leaks past the test that installed it (including under a
/// KLIO_RESOLVE_STRICT=1 suite run).
pub fn resetResolveStrictForTest() void {
    resolve_strict_checked = false;
    resolve_strict_enabled = false;
}

fn resolveStrictOn() bool {
    if (!resolve_strict_checked) {
        resolve_strict_checked = true;
        const a = std.heap.page_allocator;
        if (runtime.procEnvGetVar(a, "KLIO_RESOLVE_STRICT") catch null) |v| {
            defer a.free(v);
            resolve_strict_enabled = v.len != 0 and !std.mem.eql(u8, v, "0");
        }
    }
    return resolve_strict_enabled;
}

/// Audit one value-position bare reference: the index's pick against
/// the order-based `funcId` pick the runtime's bare-name closure path
/// binds. A divergence where both resolve is the index correcting (or,
/// unexplained, mis-binding) the reference target; the corpus sweep
/// proves zero unexplained before the FQN emission is trusted.
fn refAudit(b: *FuncBuilder, name: []const u8, index_pick: ?FuncId) void {
    if (!resolveAuditOn()) return;
    const heur = b.module.funcId(name);
    const divergent = index_pick != null and heur != null and index_pick.?.int() != heur.?.int();
    const idx_fqn: []const u8 = if (index_pick) |i| fqnOf(b, i) else "-";
    const heur_fqn: []const u8 = if (heur) |h| fqnOf(b, h) else "-";
    std.debug.print(
        "[KLIO_RESOLVE_AUDIT] ref name={s} pkg={s} index_fqn={s} heur_fqn={s} divergent={d}\n",
        .{ name, b.self_package, idx_fqn, heur_fqn, @intFromBool(divergent) },
    );
}

fn resolveAuditLog(b: *FuncBuilder, name: []const u8, heuristic: ?FuncId, index: FuncId) void {
    const heur_fqn = if (heuristic) |h| fqnOf(b, h) else "<none>";
    const idx_fqn = fqnOf(b, index);
    std.debug.print("[KLIO_RESOLVE_AUDIT] divergence: bare '{s}' heuristic={s} index={s}\n", .{ name, heur_fqn, idx_fqn });
}

fn fqnOf(b: *FuncBuilder, id: FuncId) []const u8 {
    if (b.module.funcById(id)) |f| return f.fqn;
    return "<invalid>";
}

/// Which rung of the order-based bare-call heuristic produced the pick.
/// Carried into the resolve audit so a corpus sweep counts per-rung
/// reachability — the survey evidence behind keeping (or deleting) each
/// rung of the fallback ladder.
const HeurRung = enum {
    none,
    imported,
    cast,
    non_ext_arity,
    ext_arity,
    ext_arity_tl,
    non_ext_arity_tl,
    decl_arity_order,
    decl_arity_non_ext,
    decl_arity_ext,
    recv_rebind,
};

fn userParams(f: *const Func) usize {
    if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) {
        return f.params.len - 1;
    }
    return f.params.len;
}

fn isNonExt(b: *FuncBuilder, fid: FuncId) bool {
    const f = b.module.funcById(fid) orelse return true;
    return f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this");
}

/// Whether the enclosing class (or any of its supertypes) declares a member
/// named `name`. Scoped to the current `owner_class` — a bare `::name` /
/// `this.name` can only resolve to the enclosing class's members or a global,
/// never an unrelated class's member, so a program-wide member-name set would
/// over-suppress the global-alias path.
fn enclosingDeclaresMember(b: *const FuncBuilder, name: []const u8) bool {
    const oc = b.ownerClass() orelse return false;
    const methods = b.module.registry.hierarchy_methods.get(oc) orelse return false;
    return methods.contains(name);
}

/// True when `f` shares its simple name and arity with another overload whose
/// parameter at `pidx` has a different declared type. A bare call is lowered to
/// one (arbitrarily-picked) overload before the runtime types its arguments, so
/// when the overloads disagree on a parameter's type that pick is not an
/// authoritative coercion target — re-typing a numeric literal to it (e.g.
/// turning the `Int` literal `50` into `UInt` because the lowering happened to
/// pick `minOf(UInt, UInt)`) is wrong. Leaving the literal at its natural type
/// lets the runtime overload resolver select the right form.
fn overloadParamTypeConflicts(module: *const Module, f: *const Func, pidx: usize) bool {
    if (pidx >= f.params.len) return false;
    const want_ty = f.params[pidx].ty.name;
    const cands = module.funcsBySimpleName(f.name);
    if (cands.len < 2) return false;
    for (cands) |cid| {
        const g = module.funcById(cid) orelse continue;
        if (g.params.len != f.params.len) continue;
        if (pidx >= g.params.len) continue;
        if (!std.mem.eql(u8, g.params[pidx].ty.name, want_ty)) return true;
    }
    return false;
}

/// The `Call` emit form: a resolved bare-name static call. A committed
/// non-extension target lowers to a direct `Call` (or a `TailCallFunc` in a
/// tailrec body); an extension target routes through `emitExtBareCall`, which
/// prepends `this`. `resolveCall` has already decided this is a static call, so
/// the member-vs-global walk lives in `emitMemberOrGlobal`, not here.
fn emitCall(b: *FuncBuilder, expr: *const Expr, func_id: FuncId, was_cast: bool) Allocator.Error!Reg {
    const call = expr.Call;
    const args = call.args;
    const ast_arg_names = call.arg_names;
    const ast_type_args = call.type_args;

    const needs_this = blk: {
        if (b.module.funcById(func_id)) |f| {
            break :blk f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this");
        }
        break :blk false;
    };
    if (needs_this) {
        const this_reg_opt = try resolveThisForBareCall(b);
        if (this_reg_opt) |this_reg| {
            return emitExtBareCall(b, expr, func_id, this_reg, was_cast);
        }
        // No `this` in scope — fall through to the unmodified Call below.
    }

    const callee_is_tailrec = blk: {
        if (b.module.funcById(func_id)) |f| {
            if (f.is_tailrec) break :blk true;
        }
        break :blk false;
    };
    if (b.tailrecSelf() != null and callee_is_tailrec and allNull(ast_arg_names)) {
        const run = try lowerArgRun(b, args);
        b.terminate(.{ .TailCallFunc = .{ .func = func_id, .args = run[0], .n_args = run[1] } });
        const dead = try b.allocBlock();
        b.switchTo(dead);
        return b.emitConst(.Unit);
    }
    // A bare call a runtime implicit receiver could shadow is routed by
    // `resolveCall` to the `CallMemberOrGlobal` emit form (`emitMemberOrGlobal`),
    // never here: reaching `emitCall` means the resolver already committed to the
    // static call, so this emitter only ever emits the direct `Call`.
    const arg_arity: ?[]const i16 = blk: {
        if (b.module.funcById(func_id)) |f| {
            const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
            break :blk try argFnArities(b, f, args, ast_arg_names, recv_off);
        }
        break :blk null;
    };
    const param_ty_names: ?[]const ?[]const u8 = blk: {
        const f = b.module.funcById(func_id) orelse break :blk null;
        if (!allNull(ast_arg_names)) break :blk null;
        const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        const names = try b.allocator.alloc(?[]const u8, args.len);
        for (names, 0..) |*t, j| {
            const pidx = recv_off + j;
            if (pidx < f.params.len and !f.params[pidx].is_vararg and
                !overloadParamTypeConflicts(b.module, f, pidx))
            {
                t.* = f.params[pidx].ty.name;
            } else {
                t.* = null;
            }
        }
        break :blk names;
    };
    defer if (param_ty_names) |pt| b.allocator.free(pt);
    const broad_masks: ?[]u32 = blk: {
        const f = b.module.funcById(func_id) orelse break :blk null;
        const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        break :blk try argLambdaBroadMasks(b, f, args, ast_arg_names, recv_off);
    };
    defer if (broad_masks) |m| b.allocator.free(m);
    b.pending_arg_broad_masks = broad_masks;
    const fn_generic: ?[]bool = blk: {
        const f = b.module.funcById(func_id) orelse break :blk null;
        const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        break :blk try argFnGenericFlags(b, f, args, ast_arg_names, recv_off);
    };
    defer if (fn_generic) |m| b.allocator.free(m);
    b.pending_arg_fn_generic = fn_generic;
    const run = try lowerArgRunFull(b, args, arg_arity, param_ty_names);
    // A trailing lambda always binds the target's last (function-typed)
    // parameter. When a vararg parameter precedes it, positional binding
    // would otherwise pack the lambda into the vararg and leave the last
    // parameter unfilled (Kotlin forbids a positional argument after a
    // vararg, so the trailing lambda is the only filler). Name the lambda
    // to the last parameter so the runtime binds it correctly.
    const arg_names = try trailingLambdaArgNames(b, func_id, args, ast_arg_names);
    var type_args = try internTypeArgs(b.allocator, b.module, ast_type_args);
    if (type_args.len == 0) {
        if (try spliceReifiedTypeArgs(b, func_id)) |stamped| type_args = stamped;
    }
    const dst = b.allocReg();
    try b.push(.{ .Call = .{
        .dst = dst,
        .func = func_id,
        .args = run[0],
        .n_args = run[1],
        .arg_names = arg_names,
        .type_args = type_args,
        .exact = was_cast,
    } });
    return dst;
}

/// Static type args synthesized from the enclosing splice's reified
/// substitution: when the call site wrote none and every declared
/// type-parameter name of `func_id` is bound in the active reified name
/// map, the substituted names stamp the call (`enumEntriesIntrinsic()`
/// inside a spliced `enumEntries<E>()` body gets `<E>` — the runtime
/// typed dispatch is blind otherwise). Null when not fully bound.
fn spliceReifiedTypeArgs(b: *FuncBuilder, func_id: FuncId) Allocator.Error!?[]ConstId {
    if (b.reified_type_names.count() == 0) return null;
    const tps = b.module.registry.func_type_params.get(func_id) orelse return null;
    if (tps.items.len == 0) return null;
    const out = try b.allocator.alloc(ConstId, tps.items.len);
    for (tps.items, out) |tp, *slot| {
        const actual = b.resolveReifiedTypeName(tp) orelse {
            b.allocator.free(out);
            return null;
        };
        slot.* = try b.module.internConst(b.allocator, .{ .String = actual });
    }
    return out;
}

/// The `CallMember` emit form: a resolved extension bound on the implicit
/// `this` with member precedence — a member of the receiver outranks the
/// same-named top-level extension. Routes through `emitExtBareCall`, which
/// selects the static-receiver `CallMember` (or, for a vararg trailing-lambda
/// gap / cast, the prepended static `Call`). With no `this` in scope the bind
/// degrades to the static `Call` of `emitCall`.
fn emitCallMember(b: *FuncBuilder, expr: *const Expr, func_id: FuncId, was_cast: bool) Allocator.Error!Reg {
    if (try resolveThisForBareCall(b)) |this_reg| {
        return emitExtBareCall(b, expr, func_id, this_reg, was_cast);
    }
    return emitCall(b, expr, func_id, was_cast);
}

/// The `CallMemberOrGlobal` emit form: the bare name dispatches member-first on
/// the runtime implicit receiver, falling back to the resolved global. A
/// non-extension target carries its resolved `func` as the global arm; a
/// resolved extension a member could shadow defers to the pure member-first
/// walk (`lowerUnresolvedBareCall`), which carries no static arm.
fn emitMemberOrGlobal(b: *FuncBuilder, expr: *const Expr, func_id: FuncId, was_cast: bool) Allocator.Error!Reg {
    const call = expr.Call;
    const callee = call.callee;
    const args = call.args;
    const ast_arg_names = call.arg_names;
    const ast_type_args = call.type_args;
    const name0 = callee.Path.segments[0].name;

    if (!isNonExt(b, func_id)) {
        if (try lowerUnresolvedBareCall(b, callee, args, ast_arg_names, ast_type_args, func_id)) |r| return r;
        return emitCall(b, expr, func_id, was_cast);
    }

    const this_idx = try b.recordCapture("this");
    const broad_masks: ?[]u32 = blk: {
        const f = b.module.funcById(func_id) orelse break :blk null;
        const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        break :blk try argLambdaBroadMasks(b, f, args, ast_arg_names, recv_off);
    };
    defer if (broad_masks) |m| b.allocator.free(m);
    b.pending_arg_broad_masks = broad_masks;
    // The dispatch is deferred, but the trailing lambda's static shape comes
    // from the committed global candidate: read the per-arg lambda arities
    // from it so a `T.() -> R` receiver lambda drops its synthetic `it` here
    // exactly as on the static-call path (`it` then resolves to the
    // enclosing lambda's, matching kotlinc).
    const arg_arity: ?[]const i16 = blk: {
        if (b.module.funcById(func_id)) |f| {
            const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
            break :blk try argFnArities(b, f, args, ast_arg_names, recv_off);
        }
        break :blk null;
    };
    const run = try lowerArgRunWithArity(b, args, arg_arity);
    const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
    const nm = try b.module.internConst(b.allocator, .{ .String = name0 });
    const dst = b.allocReg();
    orEmitAudit(b, "bare_call_member_shadowable", "CallMemberOrGlobal", name0);
    const cmg_static_recv: ?ConstId = try cmgStaticRecv(b);
    try b.push(.{ .CallMemberOrGlobal = .{
        .dst = dst,
        .this_idx = this_idx,
        .name = nm,
        .args = run[0],
        .n_args = run[1],
        .arg_names = arg_names,
        .func = func_id,
        .static_recv = cmg_static_recv,
    } });
    return dst;
}


/// The receiver-type tag for a deferred member-or-global bare call: the
/// enclosing extension's declared receiver head, when this body has one.

/// The class id a bare classifier read binds, innermost first: a NESTED
/// class/object of the enclosing class chain (registered under its lifted
/// `Outer$Name` key, invisible to the flat index) beats the package-scope
/// pick — `object E : Base(Key)` inside a class declaring `object Key`
/// reads ITS OWN Key, not `CoroutineContext.Key` from a wildcard import.
fn scopedClassIdForRead(b: *FuncBuilder, name0: []const u8, file: anytype) ?ir.ClassId {
    if (b.ownerClass()) |oc| {
        // Resolve the OWNER to an id once (its lifted simple name is in the
        // class index), then answer through the nesting tree — the one
        // scoped classifier lookup, no string-mangled probing.
        if (b.module.classId(oc)) |owner_id| {
            if (b.module.classIdNestedIn(owner_id, name0)) |cid| return cid;
        }
    }
    // A receiver context whose owner chain is unknown here (a super-arg /
    // default-value thunk, a lambda) may still see a NESTED classifier the
    // flat index cannot rank; committing the package-scope pick would
    // override the runtime's scope walk with the wrong declaration
    // (CoroutineContext.Key shadowing a nested `object Key`). Decline —
    // the name-keyed runtime path owns the scoped resolution.
    if (inReceiverContext(b)) return null;
    return b.module.classIdIndexed(name0, b.self_package, file);
}

fn cmgStaticRecv(b: *FuncBuilder) Allocator.Error!?ConstId {
    const rt = b.recvTy() orelse return null;
    return try b.module.internConst(b.allocator, .{ .String = rt });
}

/// The `CallValue` emit form for a bare name with no committed target: load the
/// global by name and invoke it. Used for a host-intrinsic alias whose user
/// overloads do not apply (no class declares the name as a member).
fn emitValueCall(
    b: *FuncBuilder,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
    ast_type_args: []const ast.TypeRef,
    name0: []const u8,
) Allocator.Error!Reg {
    orEmitAudit(b, "alias_global_no_overload", "LoadGlobal", name0);
    const callee_r = b.allocReg();
    const nm = try b.module.internConst(b.allocator, .{ .String = name0 });
    try b.push(.{ .LoadGlobal = .{ .dst = callee_r, .name = nm } });
    const run = try lowerArgRun(b, args);
    const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
    const type_args = try internTypeArgs(b.allocator, b.module, ast_type_args);
    const dst = b.allocReg();
    try b.push(.{ .CallValue = .{
        .dst = dst,
        .callee = callee_r,
        .args = run[0],
        .n_args = run[1],
        .arg_names = arg_names,
        .type_args = type_args,
    } });
    return dst;
}

/// Arg names for a bare `Call`, synthesizing a name for a trailing lambda
/// that follows a vararg parameter so it binds the target's last
/// (function-typed) parameter rather than being packed into the vararg.
/// Returns the plain interned names otherwise.
fn trailingLambdaArgNames(
    b: *FuncBuilder,
    func_id: FuncId,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
) Allocator.Error![]?ConstId {
    if (args.len != 0 and allNull(ast_arg_names) and lastArgIsLambda(args)) {
        if (b.module.funcById(func_id)) |f| {
            const last_is_fn = f.params.len != 0 and
                std.mem.startsWith(u8, f.params[f.params.len - 1].ty.name, "Function");
            var has_vararg = false;
            for (f.params) |p| {
                if (p.is_vararg) has_vararg = true;
            }
            // Only the vararg-before-trailing-lambda shape needs the
            // synthesized name; a plain positional trailing lambda already
            // lands on the last parameter. A vararg may absorb any number
            // of leading positional args, so the count is not bounded by
            // the parameter count here.
            if (last_is_fn and has_vararg) {
                const tagged = try b.allocator.alloc(?ConstId, args.len);
                for (tagged) |*t| t.* = null;
                const cid = try b.module.internConst(b.allocator, .{ .String = f.params[f.params.len - 1].name });
                tagged[tagged.len - 1] = cid;
                return tagged;
            }
        }
    }
    return internArgNames(b.allocator, b.module, ast_arg_names);
}

/// The extension-fn bare-call path: prepend `this`, with trailing-lambda
/// arg-name synthesis and the member-precedence routing.
fn emitExtBareCall(b: *FuncBuilder, expr: *const Expr, func_id: FuncId, this_reg: Reg, was_cast: bool) Allocator.Error!Reg {
    const call = expr.Call;
    const callee = call.callee;
    const args = call.args;
    const ast_arg_names = call.arg_names;
    const ast_type_args = call.type_args;


    // Synthesise a Path("this") arg expr then lower the run.
    const sp = exprSpan(callee);
    const all = try b.allocator.alloc(Expr, args.len + 1);
    defer b.allocator.free(all);
    const synth_segs = try b.allocator.alloc(ast.Ident, 1);
    defer b.allocator.free(synth_segs);
    synth_segs[0] = .{ .name = "this", .span = sp };
    all[0] = .{ .Path = .{ .segments = synth_segs, .span = sp } };
    for (args, 0..) |a, i| all[i + 1] = a;
    const arg_arity: ?[]const i16 = blk: {
        if (allNull(ast_arg_names)) {
            // The trailing lambda lands on whichever same-name overload
            // declares a function-typed last parameter of the call's user
            // arity — the bare-call heuristic may have resolved a sibling
            // (`List.get(index)`) that cannot host the lambda, leaving the
            // receiver lambda's `it` unsuppressed. Prefer the overload that
            // actually hosts the trailing lambda for the arity readout.
            const arity_fid: ?FuncId = if (lastArgIsLambda(args))
                (overloadHostingTrailingLambda(b, callee.Path.segments[0].name, args.len) orelse func_id)
            else
                func_id;
            if (arity_fid) |fid| {
                if (b.module.funcById(fid)) |f| {
                    // `all` leads with the synthesized `this`, aligned with
                    // the function's own leading `this` parameter, so no
                    // offset.
                    break :blk try argFnArities(b, f, all, &.{}, 0);
                }
            }
        }
        break :blk null;
    };

    // Target params for trailing-lambda arg-name synthesis.
    var target_params: [][]const u8 = &.{};
    if (b.module.funcById(func_id)) |f| {
        target_params = try b.allocator.alloc([]const u8, f.params.len);
        for (f.params, target_params) |p, *tp| tp.* = p.name;
    }
    defer if (target_params.len != 0) b.allocator.free(target_params);
    const user_arg_count = all.len - 1;
    const trailing_lambda_call = lastArgIsLambda(args);
    const synth_names_needed = target_params.len != 0 and user_arg_count >= 1 and
        (1 + user_arg_count) < target_params.len and allNull(ast_arg_names) and trailing_lambda_call;

    var arg_names: []?ConstId = undefined;
    if (synth_names_needed) {
        const tagged = try b.allocator.alloc(?ConstId, all.len);
        for (tagged) |*t| t.* = null;
        const p_name = target_params[target_params.len - 1];
        const cid = try b.module.internConst(b.allocator, .{ .String = p_name });
        tagged[tagged.len - 1] = cid;
        arg_names = tagged;
    } else {
        arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
    }
    const type_args = try internTypeArgs(b.allocator, b.module, ast_type_args);

    if (!synth_names_needed and !was_cast) {
        // Member-of-receiver precedence: route through call_member on `this`.
        // Carry the trailing lambda's expected arity (from the overload that
        // hosts it) so a `T.() -> R` receiver handler drops its synthetic
        // `it` and resolves bare members through the receiver bound at
        // invocation, even on this member-dispatch arm.
        const uarg_arity: ?[]const i16 = ablk: {
            if (allNull(ast_arg_names) and lastArgIsLambda(args)) {
                if (overloadHostingTrailingLambda(b, callee.Path.segments[0].name, args.len)) |fid| {
                    if (b.module.funcById(fid)) |f| {
                        break :ablk try argFnArities(b, f, args, &.{}, 1);
                    }
                }
            }
            break :ablk null;
        };
        const uargs = try lowerArgRunWithArity(b, args, uarg_arity);
        const uarg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
        const nmc = try b.module.internConst(b.allocator, .{ .String = callee.Path.segments[0].name });
        const dst = b.allocReg();
        // A captured-`this` receiver context routes through `emitMemberOrGlobal`
        // (the `CallMemberOrGlobal` emit form), never here — `resolveCall` never
        // reaches the static-receiver `CallMember` bind for such a call.
        //
        // Inside an extension body the implicit `this` has the
        // extension's declared receiver type; record it so dispatch
        // resolves extensions against the STATIC type, as kotlinc does.
        const static_recv: ?ConstId = if (b.recvTy()) |rt|
            try b.module.internConst(b.allocator, .{ .String = rt })
        else
            null;
        try b.push(.{ .CallMember = .{
            .dst = dst,
            .receiver = this_reg,
            .name = nmc,
            .args = uargs[0],
            .n_args = uargs[1],
            .arg_names = uarg_names,
            .static_recv = static_recv,
        } });
        return dst;
    }
    // The member-precedence branch above lowers its own argument run and
    // returns; only the static-call path reaches here, so the `this`-prepended
    // run is lowered now — lowering it earlier would emit (and execute) every
    // argument's side effects a second time on the member path.
    const run = try lowerArgRunWithArity(b, all, arg_arity);
    const dst = b.allocReg();
    try b.push(.{ .Call = .{
        .dst = dst,
        .func = func_id,
        .args = run[0],
        .n_args = run[1],
        .arg_names = arg_names,
        .type_args = type_args,
        .exact = was_cast,
    } });
    return dst;
}

fn allNull(names: []const ?[]const u8) bool {
    for (names) |n| {
        if (n != null) return false;
    }
    return true;
}

/// Whether the statically-bound private method `fid` can accept a call
/// supplying `n_args` positional arguments. The fid map keeps one entry
/// per name, so an overloaded private method may bind a sibling of the
/// wrong arity; declining here routes the call through dynamic member
/// dispatch, which picks the right overload. A named-argument call binds
/// by parameter name, which only the dynamic path models, so accept it
/// only when the positional arity already fits the bound fid.
fn privateFidAcceptsArity(b: *FuncBuilder, fid: FuncId, n_args: usize, arg_names: []const ?[]const u8) bool {
    const f = b.module.funcById(fid) orelse return true;
    const params = f.params;
    const skip: usize = if (params.len > 0 and std.mem.eql(u8, params[0].name, "this")) 1 else 0;
    const user = params[skip..];
    // A vararg tail absorbs any number of trailing positional args.
    if (user.len > 0 and user[user.len - 1].is_vararg) return n_args + 1 >= user.len;
    if (n_args > user.len) return false;
    if (n_args == user.len) return true;
    // Fewer args than params: every unsupplied trailing parameter must be
    // defaulted. Named args may fill a gap, so only decline when a clearly
    // unfilled positional tail has no default.
    _ = arg_names;
    const defaults = b.module.registry.local_fn_defaults.get(fid);
    var i = skip + n_args;
    while (i < params.len) : (i += 1) {
        const has = defaults != null and i < defaults.?.items.len and defaults.?.items[i] != null;
        if (!has) return false;
    }
    return true;
}

/// Inside a method body: unqualified `name(...)` is a method call on `this`.
fn lowerImplicitThisCall(
    b: *FuncBuilder,
    callee: *const Expr,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
) Allocator.Error!?Reg {
    const segments = callee.Path.segments;
    if (segments.len != 1) return null;
    const name0 = segments[0].name;
    if (b.resolve(name0) != null or b.knowsOuter(name0) or !b.hasOwnMember(name0)) return null;
    // E4: when the eager channel committed this call to a PLAIN top-level
    // function, the same-named own member does not shadow it — kotlin
    // scoping resolved the other way, and the record gate now checks the
    // full declared+inherited member surface, so a surviving record means
    // no member (own or inherited) shadows. The redirect stands where the
    // channel is silent or names a method.
    if (b.module.eagerCallTarget(segments[0].span)) |efid| {
        if (b.module.funcById(efid)) |ef| {
            if (ef.kind == .plain) return null;
        }
    }
    // A same-named member that cannot bind this call's arity (a 0-arg
    // `requireNotNull()` for a 1-arg `requireNotNull(x)`) does not shadow the
    // top-level function: defer to the global-resolution path instead of
    // emitting a `this.<member>` call that can't dispatch.
    if (!b.ownMemberApplicable(name0, args.len)) return null;
    const this_reg = b.resolve("this") orelse return null;

    // Broad-collection mask: a trailing lambda bound to this member's
    // function-typed parameter whose declared type is `Iterable`/`Collection`
    // marks the lambda's matching params broad, so `it + x` over a runtime
    // `Set` yields a `List` (the declared, not runtime, receiver type).
    const itc_broad: ?[]u32 = blk: {
        // Only a trailing lambda can be marked broad. Resolve the SIBLING member
        // method statically and owner-scoped via the `member_method_fids` index
        // (keyed by class + name + arity): the call target is `this.<name>`, and
        // `this`'s static class is the enclosing owner, so this is the exact
        // method — never a same-named member of an unrelated class.
        if (args.len == 0) break :blk null;
        const last = args[args.len - 1];
        if (last != .Lambda and last != .AnonFun) break :blk null;
        const owner = b.ownerClass() orelse break :blk null;
        const key = try std.fmt.allocPrint(b.allocator, "{s}\x00{s}\x00{d}", .{ owner, name0, args.len });
        defer b.allocator.free(key);
        const fid = b.module.registry.member_method_fids.get(key) orelse break :blk null;
        const f = b.module.funcById(fid) orelse break :blk null;
        const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        break :blk try argLambdaBroadMasks(b, f, args, ast_arg_names, recv_off);
    };
    defer if (itc_broad) |m| b.allocator.free(m);

    // Private own-class methods bind statically. The fid map records one
    // entry per name, so an overloaded private method (two `helper`s of
    // different arity) keeps only one of them. Take the static bind only
    // when that fid can actually accept this call's arity; otherwise fall
    // through to the dynamic member dispatch below, whose
    // `pickMethodOverload` selects the right private sibling from the
    // class method table.
    if (b.privateMethodFid(name0)) |fid| if (privateFidAcceptsArity(b, fid, args.len, ast_arg_names)) {
        // Reserve the receiver slot first, then lower the arguments into a
        // contiguous run immediately after it. `lowerArgRun` reserves every
        // argument slot before lowering any argument, so an argument's own
        // scratch registers can never clobber an already-lowered slot (a bug
        // the previous hand-rolled loop had, dropping local-variable args).
        const args_start = b.allocReg();
        b.pending_arg_broad_masks = itc_broad;
        const priv_arity: ?[]const i16 = if (b.module.funcById(fid)) |pf|
            (try argFnArities(b, pf, args, ast_arg_names, if (pf.params.len != 0 and std.mem.eql(u8, pf.params[0].name, "this")) 1 else 0))
        else
            null;
        const priv_fn_generic: ?[]bool = if (b.module.funcById(fid)) |pf|
            (try argFnGenericFlags(b, pf, args, ast_arg_names, if (pf.params.len != 0 and std.mem.eql(u8, pf.params[0].name, "this")) 1 else 0))
        else
            null;
        defer if (priv_fn_generic) |m| b.allocator.free(m);
        b.pending_arg_fn_generic = priv_fn_generic;
        const run = try lowerArgRunWithArity(b, args, priv_arity);
        try b.push(.{ .Move = .{ .dst = args_start, .src = this_reg } });
        var user_arg_names = try b.allocator.alloc(?[]const u8, ast_arg_names.len + 1);
        defer b.allocator.free(user_arg_names);
        user_arg_names[0] = null;
        for (ast_arg_names, 0..) |n, i| user_arg_names[i + 1] = n;
        const arg_names = try internArgNames(b.allocator, b.module, user_arg_names);
        const dst = b.allocReg();
        try b.push(.{ .Call = .{
            .dst = dst,
            .func = fid,
            .args = args_start,
            .n_args = run[1] + 1,
            .arg_names = arg_names,
            .type_args = &.{},
            .exact = false,
        } });
        return dst;
    };
    b.pending_arg_broad_masks = itc_broad;
    const run = try lowerArgRun(b, args);
    const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
    const dst = b.allocReg();
    const nm = try b.module.internConst(b.allocator, .{ .String = name0 });
    // When a same-named top-level function exists, the own member may be a
    // non-callable *property* (`val allStatusCodes = allStatusCodes()`),
    // which kotlinc skips for a call — emit the OrGlobal form so member
    // dispatch still wins when callable but a miss falls through to the
    // function instead of erroring. The same applies when the name is a
    // known top-level stdlib function (a host intrinsic, absent from
    // `funcsBySimpleName`): a `@Test fun listOfNotNull()` method calling the
    // top-level `listOfNotNull(...)` must fall through on the arity miss.
    if (b.module.funcsBySimpleName(name0).len != 0 or ir.isAliasName(name0)) {
        const this_idx = try b.recordCapture("this");
        orEmitAudit(b, "implicit_this_call_global_fallback", "CallMemberOrGlobal", name0);
        try b.push(.{ .CallMemberOrGlobal = .{
            .dst = dst,
            .this_idx = this_idx,
            .recv = this_reg,
            .name = nm,
            .args = run[0],
            .n_args = run[1],
            .arg_names = arg_names,
            .static_recv = try cmgStaticRecv(b),
        } });
        return dst;
    }
    try b.push(.{ .CallMember = .{
        .dst = dst,
        .receiver = this_reg,
        .name = nm,
        .args = run[0],
        .n_args = run[1],
        .arg_names = arg_names,
    } });
    return dst;
}

/// Unresolved bare-name call: anon capture, primitive conversion, or
/// CallMemberOrGlobal.
fn lowerUnresolvedBareCall(
    b: *FuncBuilder,
    callee: *const Expr,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
    ast_type_args: []const ast.TypeRef,
    static_ext: ?FuncId,
) Allocator.Error!?Reg {
    const name0 = callee.Path.segments[0].name;
    // A bare call to a name the enclosing anon object closes over.
    if (isLowerAnonCapture(name0)) {
        const idx = try b.recordCapture(name0);
        const callee_r = b.allocReg();
        try b.push(.{ .LoadCapture = .{ .dst = callee_r, .idx = idx } });
        const run = try lowerArgRun(b, args);
        const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
        const dst = b.allocReg();
        try b.push(.{ .CallValue = .{
            .dst = dst,
            .callee = callee_r,
            .args = run[0],
            .n_args = run[1],
            .arg_names = arg_names,
        } });
        return dst;
    }
    // A stdlib container creator (`emptyList<String>()`) called with type
    // args inside a method body. The name is a host-intrinsic global, never
    // a class member, so the runtime `this.<name>()` redispatch the general
    // receiver-context path would emit cannot apply — and that path drops
    // the type args, losing the element head the value needs for receiver
    // proofs. Bind the global value directly and carry the type args so the
    // creation-site stamp (`runtime.attachDeclaredElemTypes`) runs.
    if (ast_type_args.len != 0 and emptyContainerCreatorArity(name0) != 0 and
        b.module.funcId(name0) == null and !anyReceiverClassDeclares(b, name0))
    {
        orEmitAudit(b, "container_creator_typed", "LoadGlobal", name0);
        const callee_r = b.allocReg();
        const nm = try b.module.internConst(b.allocator, .{ .String = name0 });
        try b.push(.{ .LoadGlobal = .{ .dst = callee_r, .name = nm } });
        const run = try lowerArgRun(b, args);
        const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
        const type_args = try internTypeArgs(b.allocator, b.module, ast_type_args);
        const dst = b.allocReg();
        try b.push(.{ .CallValue = .{
            .dst = dst,
            .callee = callee_r,
            .args = run[0],
            .n_args = run[1],
            .arg_names = arg_names,
            .type_args = type_args,
        } });
        return dst;
    }
    // Outside any receiver context no member can serve the call (kotlinc
    // rejects resolving a bare call against a caller's receiver), and
    // `funcId == null` here means the overload tier has no candidates
    // either — the callee is a static global value.
    if (!inReceiverContext(b)) {
        orEmitAudit(b, "unresolved_bare_call", "LoadGlobal", name0);
        const callee_r = b.allocReg();
        const nm = try b.module.internConst(b.allocator, .{ .String = name0 });
        try b.push(.{ .LoadGlobal = .{ .dst = callee_r, .name = nm } });
        const run = try lowerArgRun(b, args);
        const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
        const type_args = try internTypeArgs(b.allocator, b.module, ast_type_args);
        const dst = b.allocReg();
        try b.push(.{ .CallValue = .{
            .dst = dst,
            .callee = callee_r,
            .args = run[0],
            .n_args = run[1],
            .arg_names = arg_names,
            .type_args = type_args,
        } });
        return dst;
    }
    // A known top-level stdlib function (`listOfNotNull`, `buildList`,
    // `compareBy`, …) that no class declares as a member is never a member of
    // the implicit receiver. Bind the global directly: routing it through
    // `CallMemberOrGlobal` would let the member/extension probe treat it as an
    // extension on `this` and prepend the receiver into its varargs.
    if (ir.isAliasName(name0) and !anyReceiverClassDeclares(b, name0) and
        !extensionCandidateFitsArity(b, name0, args.len))
    {
        orEmitAudit(b, "unresolved_bare_call", "LoadGlobal", name0);
        const callee_r = b.allocReg();
        const nm0 = try b.module.internConst(b.allocator, .{ .String = name0 });
        try b.push(.{ .LoadGlobal = .{ .dst = callee_r, .name = nm0 } });
        const run0 = try lowerArgRun(b, args);
        const arg_names0 = try internArgNames(b.allocator, b.module, ast_arg_names);
        const type_args0 = try internTypeArgs(b.allocator, b.module, ast_type_args);
        const dst0 = b.allocReg();
        try b.push(.{ .CallValue = .{
            .dst = dst0,
            .callee = callee_r,
            .args = run0[0],
            .n_args = run0[1],
            .arg_names = arg_names0,
            .type_args = type_args0,
        } });
        return dst0;
    }
    // When `this` is bound locally (the frame's own receiver param — a
    // top-level/member extension's receiver, not an outer closure capture),
    // pass it as the explicit innermost receiver. A `recordCapture("this")`
    // here is wrong: a non-closure extension function has no capture frame,
    // so the capture slot is empty and the bare member misses its own
    // receiver. This is the `is JobSupport -> invokeOnCompletionInternal(…)`
    // shape — a bare member call on the extension's smart-cast receiver.
    // The only `this` in scope is an ordinary user parameter named `this`:
    // no implicit receiver exists, so the bare name binds a global or is an
    // unresolved reference at runtime — never a member of the parameter.
    if (b.this_is_plain_param and b.recvTy() == null and b.ownerClass() == null and
        !b.capturesThisSlot())
    {
        return try emitValueCall(b, args, ast_arg_names, ast_type_args, name0);
    }
    const nm = try b.module.internConst(b.allocator, .{ .String = name0 });
    const dst = b.allocReg();
    orEmitAudit(b, "unresolved_bare_call", "CallMemberOrGlobal", name0);
    // No committed target, but a trailing lambda's expected shape still has
    // a static answer: read the per-arg lambda arities from the same-name
    // overload that hosts it at this arity, so a `T.() -> R` handler drops
    // its synthetic `it` here too (`launch { … }` deferred inside a
    // receiver context) and `it` resolves to the enclosing lambda's.
    const bare_arity: ?[]const i16 = blk: {
        if (allNull(ast_arg_names) and lastArgIsLambda(args)) {
            if (overloadHostingTrailingLambda(b, name0, args.len)) |fid| {
                if (b.module.funcById(fid)) |f| {
                    // The receiver offset depends on the candidate's own
                    // shape: a top-level fn has no leading `this`, and a
                    // blanket offset misaligned every arity (the trailing
                    // `() -> T` block read past the params, kept its
                    // synthetic `it`, and shadowed the enclosing one).
                    const off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
                    break :blk try argFnArities(b, f, args, ast_arg_names, off);
                }
            }
        }
        break :blk null;
    };
    if (b.resolve("this")) |this_reg| {
        const run = try lowerArgRunWithArity(b, args, bare_arity);
        const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
        try b.push(.{ .CallMemberOrGlobal = .{
            .dst = dst,
            .this_idx = 0,
            .name = nm,
            .args = run[0],
            .n_args = run[1],
            .arg_names = arg_names,
            .recv = this_reg,
            .func = static_ext,
            .static_recv = try cmgStaticRecv(b),
            .type_args = try internTypeArgs(b.allocator, b.module, ast_type_args),
        } });
        return dst;
    }
    const this_idx = try b.recordCapture("this");
    const run = try lowerArgRunWithArity(b, args, bare_arity);
    const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
    try b.push(.{ .CallMemberOrGlobal = .{
        .dst = dst,
        .this_idx = this_idx,
        .name = nm,
        .args = run[0],
        .n_args = run[1],
        .arg_names = arg_names,
        .static_recv = try cmgStaticRecv(b),
        .type_args = try internTypeArgs(b.allocator, b.module, ast_type_args),
    } });
    return dst;
}

/// Built-in stdlib companion shortcuts: `Result.success(x)`, `Result.failure(e)`.
fn lowerCompanionShortcut(
    b: *FuncBuilder,
    callee: *const Expr,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
) Allocator.Error!?Reg {
    if (callee.* != .Member) return null;
    const recv_box = callee.Member.receiver;
    const mname = callee.Member.name;
    if (recv_box.* != .Path or recv_box.Path.segments.len != 1) return null;
    const head = recv_box.Path.segments[0].name;
    if (b.resolve(head) != null or b.knowsOuter(head)) return null;

    const Shortcut = struct { cls: []const u8, method: []const u8, fqn: []const u8 };
    const shortcuts = [_]Shortcut{
        .{ .cls = "Result", .method = "success", .fqn = "kotlin.Result.Companion.success" },
        .{ .cls = "Result", .method = "failure", .fqn = "kotlin.Result.Companion.failure" },
    };
    for (shortcuts) |sc| {
        if (std.mem.eql(u8, head, sc.cls) and std.mem.eql(u8, mname.name, sc.method)) {
            const callee_r = b.allocReg();
            const n = try b.module.internConst(b.allocator, .{ .String = sc.fqn });
            try b.push(.{ .LoadGlobal = .{ .dst = callee_r, .name = n } });
            const run = try lowerArgRun(b, args);
            const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
            const dst = b.allocReg();
            try b.push(.{ .CallValue = .{
                .dst = dst,
                .callee = callee_r,
                .args = run[0],
                .n_args = run[1],
                .arg_names = arg_names,
            } });
            return dst;
        }
    }
    return null;
}

/// Package-qualified call to a user / pack top-level function (FQN flatten).
fn lowerFqnFlattenCall(
    b: *FuncBuilder,
    callee: *const Expr,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
    ast_type_args: []const ast.TypeRef,
) Allocator.Error!?Reg {
    const fqn = (try collectDottedFqn(b.allocator, callee)) orelse return null;
    defer b.allocator.free(fqn);
    const head = firstSegment(fqn);
    const tail = rsplitLast(fqn, '.');
    const head_is_real_pkg = isPkgRoot(head);
    if (std.mem.eql(u8, tail, fqn)) return null;
    if (isPackageHead(head) and
        headIsPackage(b, head) and
        b.resolve(head) == null and
        !b.knowsOuter(head) and
        !b.hasEnclosingMember(head) and
        b.module.classId(head) == null and
        (head_is_real_pkg or !isTopLevelProp(head)) and
        (head_is_real_pkg or b.resolve("this") == null))
    {
        const want = args.len;
        const cands = b.module.funcsBySimpleName(tail);
        // A fully-qualified callee binds the one declaration whose FQN
        // matches exactly. It must never fall back to a same-tail-named
        // function in another package (a user `println` cannot answer a
        // `kotlin.io.println` call) — when no lowered declaration owns the
        // FQN the call belongs to global/intrinsic resolution, so decline
        // the flatten and let `lowerFqnGlobalCall` load it by FQN.
        var pick: ?FuncId = null;
        for (cands) |fid| {
            const f = b.module.funcById(fid) orelse continue;
            if (std.mem.eql(u8, f.fqn, fqn) and f.params.len == want) {
                pick = fid;
                break;
            }
        }
        if (pick) |func_id| {
            const run = try lowerArgRun(b, args);
            const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
            const type_args = try internTypeArgs(b.allocator, b.module, ast_type_args);
            const dst = b.allocReg();
            try b.push(.{ .Call = .{
                .dst = dst,
                .func = func_id,
                .args = run[0],
                .n_args = run[1],
                .arg_names = arg_names,
                .type_args = type_args,
                .exact = false,
            } });
            return dst;
        }
    }
    return null;
}

/// Fully-qualified callee resolved as a global, CallValue.
fn lowerFqnGlobalCall(
    b: *FuncBuilder,
    callee: *const Expr,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
) Allocator.Error!?Reg {
    const fqn = (try collectDottedFqn(b.allocator, callee)) orelse return null;
    defer b.allocator.free(fqn);
    const head = firstSegment(fqn);
    const head_is_real_pkg = isPkgRoot(head);
    // A fully-qualified property access followed by a member call
    // (`kotlin.math.PI.toFloat()`): the prefix names a top-level property, so
    // the call is a member call on that property's value, not a global
    // function whose FQN is the whole dotted path. Decline and let the
    // member-call fallback lower the property load + `CallMember`.
    if (std.mem.lastIndexOfScalar(u8, fqn, '.')) |dot| {
        const prefix = fqn[0..dot];
        const prefix_name = rsplitLast(prefix, '.');
        if (b.module.topLevelPropFqn(prefix_name)) |pfqn| {
            if (std.mem.eql(u8, pfqn, prefix)) {
                // Load the property value by its package-qualified FQN, then
                // member-call the trailing segment on it.
                const recv = b.allocReg();
                const pn = try b.module.internConst(b.allocator, .{ .String = prefix });
                try b.push(.{ .LoadGlobal = .{ .dst = recv, .name = pn } });
                const last = fqn[dot + 1 ..];
                const run = try lowerArgRun(b, args);
                const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
                const dst = b.allocReg();
                const mname = try b.module.internConst(b.allocator, .{ .String = last });
                try b.push(.{ .CallMember = .{
                    .dst = dst,
                    .receiver = recv,
                    .name = mname,
                    .args = run[0],
                    .n_args = run[1],
                    .arg_names = arg_names,
                } });
                return dst;
            }
        }
    }
    if (isPackageHead(head) and
        headIsPackage(b, head) and
        b.resolve(head) == null and
        !b.knowsOuter(head) and
        !b.hasEnclosingMember(head) and
        b.module.classId(head) == null and
        (head_is_real_pkg or !isTopLevelProp(head)) and
        (head_is_real_pkg or b.resolve("this") == null))
    {
        const callee_r = b.allocReg();
        const n = try b.module.internConst(b.allocator, .{ .String = fqn });
        try b.push(.{ .LoadGlobal = .{ .dst = callee_r, .name = n } });
        const run = try lowerArgRun(b, args);
        const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
        const dst = b.allocReg();
        try b.push(.{ .CallValue = .{
            .dst = dst,
            .callee = callee_r,
            .args = run[0],
            .n_args = run[1],
            .arg_names = arg_names,
        } });
        return dst;
    }
    return null;
}

/// The simple head of a type name: drop a package qualifier and any generic
/// arguments (`kotlin.collections.Iterable<Int>` -> `Iterable`).
fn typeHead(s: []const u8) []const u8 {
    var t = s;
    if (std.mem.indexOfScalar(u8, t, '<')) |lt| t = t[0..lt];
    if (std.mem.lastIndexOfScalar(u8, t, '.')) |dot| t = t[dot + 1 ..];
    return std.mem.trim(u8, t, " ");
}

/// The static-type head of a call argument when it is a plain local whose
/// declared type is known — used to disambiguate cast-rebound overloads by
/// parameter type (an `Iterable<Int>` arg must not bind an `IntRange` param).
fn argStaticHead(b: *FuncBuilder, a: *const Expr) ?[]const u8 {
    if (a.* != .Path) return null;
    const p = a.Path;
    if (p.segments.len != 1) return null;
    if (b.localDeclType(p.segments[0].name)) |t| return typeHead(t);
    return null;
}

/// The fallback member-call path: local-callable shadowing, super, cast-receiver
/// static dispatch, and plain CallMember.
fn lowerMemberCallFallback(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    const call = expr.Call;
    const callee = call.callee;
    const args = call.args;
    const ast_arg_names = call.arg_names;
    const ast_type_args = call.type_args;
    const receiver = callee.Member.receiver;
    const name = callee.Member.name;

    // A bound local/param/captured-outer of this name shadows the member.
    // A plain bound local (`for (module in modules) { application.module() }`,
    // a `T.() -> R` value invoked with receiver syntax) is included too: the
    // member is still tried first at runtime, with the local as the fallback.
    const anon_cap = isLowerAnonCapture(name.name) and b.resolve(name.name) == null and
        !b.isLocalFn(name.name) and !b.isParam(name.name) and !b.knowsOuter(name.name);
    const local_callable = b.isLocalFn(name.name) or b.isParam(name.name) or
        b.knowsOuter(name.name) or anon_cap or b.resolve(name.name) != null;
    if (local_callable) {
        const local_reg = blk: {
            if (anon_cap) {
                const idx = try b.recordCapture(name.name);
                const r = b.allocReg();
                try b.push(.{ .LoadCapture = .{ .dst = r, .idx = idx } });
                break :blk r;
            }
            // A directly-bound local (a loop variable / `val`) uses its own
            // register; `resolveCapture` would mint a bogus capture slot
            // (resolving to `Nothing`) for a name that is not actually
            // closed over.
            if (b.resolve(name.name)) |reg| {
                if (b.isBoxed(name.name)) {
                    const c = b.allocReg();
                    try b.push(.{ .CellGet = .{ .dst = c, .cell = reg } });
                    break :blk c;
                }
                break :blk reg;
            }
            break :blk try resolveCapture(b, name.name);
        };
        const recv = try lowerReceiver(b, receiver);
        const run = try lowerArgRun(b, args);
        const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
        const nm = try b.module.internConst(b.allocator, .{ .String = name.name });
        const dst = b.allocReg();
        orEmitAudit(b, "member_or_local_callable", "CallMemberOrValue", name.name);
        try b.push(.{ .CallMemberOrValue = .{
            .dst = dst,
            .receiver = recv,
            .name = nm,
            .fallback = local_reg,
            .args = run[0],
            .n_args = run[1],
            .arg_names = arg_names,
        } });
        return dst;
    }

    // `super.method(...)`.
    if (receiver.* == .Super) {
        if (b.resolve("this")) |this_reg| {
            if (b.ownerClass()) |owner| {
                const sup = receiver.Super;
                const run = try lowerArgRun(b, args);
                const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
                const dst = b.allocReg();
                const nm = try b.module.internConst(b.allocator, .{ .String = name.name });
                const oc = try b.module.internConst(b.allocator, .{ .String = owner });
                const qual_const = try superQualifier(b, sup.qualifier, sup.label);
                try b.push(.{ .CallSuper = .{
                    .dst = dst,
                    .receiver = this_reg,
                    .owner_class = oc,
                    .qualifier = qual_const,
                    .name = nm,
                    .args = run[0],
                    .n_args = run[1],
                    .arg_names = arg_names,
                } });
                return dst;
            }
        }
    }

    // Statically rebind `(e as T).f(args)` to the `f` overload whose
    // first-param type is `T`. The universal `Any` members are virtual and
    // dispatch on the runtime type, so never rebind them to a declared-`T`
    // namesake — `(x as Any).toString()` must reach `String.toString`, not a
    // `fun Any?.toString()` namesake.
    if (receiver.* == .As and !receiver.As.safe and
        !std.mem.eql(u8, name.name, "toString") and
        !std.mem.eql(u8, name.name, "equals") and
        !std.mem.eql(u8, name.name, "hashCode"))
    {
        const cast_ty = receiver.As.ty;
        const want_user = args.len;
        var chosen: ?FuncId = null;
        // Among candidates matching the cast receiver type and arity, prefer the
        // one whose parameter-type heads match the argument static-type heads.
        // A bare first-match would bind e.g. an `Iterable<Int>` argument to an
        // `IntRange` parameter (distinct, non-assignable types) when both slice
        // overloads share the receiver type and arity.
        var chosen_score: i32 = -1;
        for (b.module.funcsBySimpleName(name.name)) |fid| {
            const f = b.module.funcById(fid) orelse continue;
            if (!f.hasBody()) continue;
            if (f.params.len == 0) continue;
            const p0 = f.params[0];
            if (!std.mem.eql(u8, p0.name, "this") or !std.mem.eql(u8, p0.ty.name, cast_ty.name.name)) continue;
            const user = f.params.len - 1;
            const arity_ok = blk: {
                if (user == want_user) break :blk true;
                if (want_user < user) {
                    var all_opt = true;
                    for (f.params[1 + want_user ..]) |p| {
                        if (p.default == null and !p.is_vararg) {
                            all_opt = false;
                            break;
                        }
                    }
                    break :blk all_opt;
                }
                if (want_user > user) break :blk f.params.len != 0 and f.params[f.params.len - 1].is_vararg;
                break :blk false;
            };
            if (!arity_ok) continue;
            var score: i32 = 0;
            for (args, 0..) |*a, i| {
                if (i + 1 >= f.params.len) break;
                const at = argStaticHead(b, a) orelse continue;
                if (std.mem.eql(u8, at, typeHead(f.params[i + 1].ty.name))) score += 2;
            }
            if (score > chosen_score) {
                chosen = fid;
                chosen_score = score;
            }
        }
        if (chosen) |func_id| {
            const recv_reg = try lowerReceiver(b, receiver);
            const arg_regs = try b.allocator.alloc(Reg, args.len + 1);
            defer b.allocator.free(arg_regs);
            arg_regs[0] = recv_reg;
            for (args, 0..) |*a, i| arg_regs[i + 1] = try lowerExpr(b, a);
            const start = try packContiguous(b, arg_regs);
            const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
            const type_args = try internTypeArgs(b.allocator, b.module, ast_type_args);
            const dst = b.allocReg();
            // The cast picked this overload by its declared receiver type;
            // mark the call exact so the runtime overload re-resolution
            // (which keys on the receiver's runtime type) cannot flip a
            // `(this as CharSequence).f()` back onto the `String.f` namesake
            // and recurse.
            try b.push(.{ .Call = .{
                .dst = dst,
                .func = func_id,
                .args = start,
                .n_args = @intCast(arg_regs.len),
                .arg_names = arg_names,
                .type_args = type_args,
                .exact = true,
            } });
            return dst;
        }
    }

    // A member call on a factory receiver over statically generic-typed
    // values (`arrayOf(a, b).minOrNull()` with `a: T` inside
    // `fun <T : Comparable<T>> ...`) binds the GENERIC extension overload
    // statically. The runtime receiver (a boxed array of Doubles) is
    // byte-identical to a concrete `Array<Double>`, so only this static
    // bind can keep the generic call site on its `compareTo` total-order
    // path while the concrete sites keep the specialized (NaN-propagating)
    // intrinsic form. kotlinc resolves exactly this way: with `T` elements
    // the `Array<out Double>` overload is not applicable.
    if (receiverGenericElemHead(b, receiver)) |recv_head| {
        if (genericExtTarget(b, name.name, recv_head, args.len)) |func_id| {
            const recv_reg = try lowerReceiver(b, receiver);
            const arg_regs = try b.allocator.alloc(Reg, args.len + 1);
            defer b.allocator.free(arg_regs);
            arg_regs[0] = recv_reg;
            for (args, 0..) |*a, i| arg_regs[i + 1] = try lowerExpr(b, a);
            const start = try packContiguous(b, arg_regs);
            const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
            const type_args = try internTypeArgs(b.allocator, b.module, ast_type_args);
            const dst = b.allocReg();
            try b.push(.{ .Call = .{
                .dst = dst,
                .func = func_id,
                .args = start,
                .n_args = @intCast(arg_regs.len),
                .arg_names = arg_names,
                .type_args = type_args,
                .exact = true,
            } });
            return dst;
        }
    }

    const recv = try lowerReceiver(b, receiver);
    const run = try lowerArgRun(b, args);
    const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
    const dst = b.allocReg();
    const nm = try b.module.internConst(b.allocator, .{ .String = name.name });
    // Kotlin resolves the member-vs-extension question against the
    // receiver's DECLARED type; carry it for the extension-selection
    // filter (a channel separate from static_recv, whose meaning is the
    // extension-body receiver). A nullable declared receiver carries its
    // HEAD too: null-accepting extensions overload by the underlying
    // type (`String?.orEmpty()` vs `List?.orEmpty()`), and a Null
    // runtime receiver offers the filter nothing else to go on.
    const declared_recv: ?ConstId = blk: {
        const t = argDeclTypeRef(b, receiver) orelse break :blk null;
        const head = std.mem.trimEnd(u8, t.name, "?");
        if (head.len == 0) break :blk null;
        break :blk try b.module.internConst(b.allocator, .{ .String = head });
    };
    try b.push(.{ .CallMember = .{
        .dst = dst,
        .receiver = recv,
        .name = nm,
        .args = run[0],
        .n_args = run[1],
        .arg_names = arg_names,
        .declared_recv = declared_recv,
    } });
    return dst;
}

// -------------------------------------------------------------------------
// Block lowering.
// -------------------------------------------------------------------------

/// Lower a block expression, returning the register holding its tail value.
pub fn lowerBlock(b: *FuncBuilder, block: *const AstBlock) Allocator.Error!Reg {
    try b.pushScope();
    // Hoist the local-fn names an earlier-declared sibling references, so a
    // mutually-recursive forward reference resolves through a shared cell.
    try hoistMutualLocalFns(b, block);
    var last: ?Reg = null;
    for (block.stmts) |*stmt| {
        last = try lowerStmt(b, stmt);
    }
    const result = last orelse try b.emitConst(.Unit);
    try b.popScope();
    return result;
}

fn hoistMutualLocalFns(b: *FuncBuilder, block: *const AstBlock) Allocator.Error!void {
    // Collect (stmt index, function) for each local-fn decl in this block.
    const LocalFn = struct { pos: usize, func: *const ast.Function };
    var local_fns: std.ArrayList(LocalFn) = .empty;
    defer local_fns.deinit(b.allocator);
    for (block.stmts, 0..) |*s, i| {
        if (s.* == .Decl and s.Decl == .Function) {
            local_fns.append(b.allocator, .{ .pos = i, .func = &s.Decl.Function }) catch return error.OutOfMemory;
        }
    }
    for (local_fns.items, 0..) |k, k_idx| {
        _ = k_idx;
        const k_pos = k.pos;
        const k_fn = k.func;
        var needs_hoist = false;
        for (local_fns.items) |i_entry| {
            if (i_entry.pos >= k_pos) break;
            const i_fn = i_entry.func;
            if (i_fn.body) |body| {
                var refs = StringSet.init(b.allocator);
                defer refs.deinit();
                switch (body) {
                    .Block => |blk| {
                        for (blk.stmts) |*s| try collectPathIdentsStmt(s, &refs);
                    },
                    .Expr => |*e| try collectPathIdents(e, &refs),
                }
                if (refs.contains(k_fn.name.name)) {
                    needs_hoist = true;
                    break;
                }
            }
        }
        if (needs_hoist and b.mutableHome(k_fn.name.name) == null) {
            const null_v = try b.emitConst(.Null);
            const home = b.allocReg();
            try b.push(.{ .MakeCell = .{ .dst = home, .src = null_v } });
            try b.setMutableHome(k_fn.name.name, home);
            try b.markMutable(k_fn.name.name);
            try b.markBoxed(k_fn.name.name);
            try b.bind(k_fn.name.name, home);
        }
    }
}

// -------------------------------------------------------------------------
// Small generic utilities.
// -------------------------------------------------------------------------

/// Index into a slice by a `u32` id, returning a const pointer or null.
fn idGet(comptime T: type, items: []const T, idx: u32) ?*const T {
    if (idx >= items.len) return null;
    return &items[idx];
}

/// Mutable variant of `idGet`.
fn idGetMut(comptime T: type, items: []T, idx: u32) ?*T {
    if (idx >= items.len) return null;
    return &items[idx];
}

/// Decide whether a dotted head `head` is a package-qualified global
/// (flatten the dotted path to a `LoadGlobal`-of-FQN) rather than a member
/// of an implicit receiver (walk `this`).
///
/// A head is a package head when it is a real package root (`kotlin`, `io`,
/// `org`, …) or names a package the program contributes a top-level symbol
/// to (`head.<rest>` is a declared FQN prefix). This is the one principled
/// predicate that replaces the former `isLambdaBody()` resolution axis: a
/// member/captured/local name shadows a package head (the caller filters
/// those with `resolve`/`knowsOuter`/`classId` guards at the use site), and
/// a name resolving to a package/imported/stdlib FQN resolves globally —
/// the same answer whether or not the reference is lexically inside a
/// lambda.
fn headIsPackage(b: *FuncBuilder, head: []const u8) bool {
    return isPkgRoot(head) or b.module.packageHeadDeclared(head);
}

/// The last segment after the final `sep`, or the whole string when absent.
fn rsplitLast(s: []const u8, sep: u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, s, sep)) |i| return s[i + 1 ..];
    return s;
}

/// The first segment before the first `.`, or the whole string when absent.
fn firstSegment(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '.')) |i| return s[0..i];
    return s;
}

/// Join `segments[*].name` with `.`. The caller owns the returned slice.
fn joinSegments(allocator: Allocator, segments: []const ast.Ident) Allocator.Error![]u8 {
    var total: usize = 0;
    for (segments, 0..) |s, i| {
        total += s.name.len;
        if (i != 0) total += 1;
    }
    var out = try allocator.alloc(u8, total);
    var off: usize = 0;
    for (segments, 0..) |s, i| {
        if (i != 0) {
            out[off] = '.';
            off += 1;
        }
        @memcpy(out[off .. off + s.name.len], s.name);
        off += s.name.len;
    }
    return out;
}

/// Snapshot a string set into an owned slice of its keys (borrowed slices).
fn setToSlice(allocator: Allocator, set: *const StringSet) Allocator.Error![][]const u8 {
    const out = try allocator.alloc([]const u8, set.count());
    var i: usize = 0;
    var it = set.keyIterator();
    while (it.next()) |k| : (i += 1) out[i] = k.*;
    return out;
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

fn freeFunc(func: Func) void {
    for (func.blocks) |b| {
        if (b.insts.len != 0) testing.allocator.free(b.insts);
        if (b.catches.len != 0) testing.allocator.free(b.catches);
    }
    testing.allocator.free(func.blocks);
    if (func.capture_order.len != 0) testing.allocator.free(func.capture_order);
}

test "buildArgShapes: literal, lambda, spread, and named argument shapes" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();

    const lit = Expr{ .IntLit = .{ .value = 7, .kind = .Int, .span = dummySpan() } };
    var lam_params = [_]ast.Ident{.{ .name = "x", .span = dummySpan() }};
    const lam = Expr{ .Lambda = .{
        .params = &lam_params,
        .body = .{ .stmts = &.{}, .span = dummySpan() },
        .span = dummySpan(),
    } };
    var spread_inner = Expr{ .IntLit = .{ .value = 0, .kind = .Int, .span = dummySpan() } };
    const spread = Expr{ .Spread = .{ .expr = &spread_inner, .span = dummySpan() } };

    const args = [_]Expr{ lit, lam, spread };
    const names = [_]?[]const u8{ null, "block", null };
    const shapes = try buildArgShapes(&b, &args, &names);
    defer b.allocator.free(shapes);

    try testing.expectEqual(@as(usize, 3), shapes.len);
    // Literal Int argument: numeric literal kind, not a lambda / spread.
    try testing.expect(shapes[0].literal_kind == .numeric);
    try testing.expect(!shapes[0].is_lambda);
    try testing.expect(!shapes[0].is_spread);
    try testing.expect(shapes[0].named == null);
    try testing.expect(shapes[0].lambda_arity == null);
    // Named lambda argument: one declared param, bound to name "block".
    try testing.expect(shapes[1].is_lambda);
    try testing.expectEqual(@as(?u8, 1), shapes[1].lambda_arity);
    try testing.expectEqualStrings("block", shapes[1].named.?);
    try testing.expect(shapes[1].literal_kind == null);
    // Spread argument.
    try testing.expect(shapes[2].is_spread);
    try testing.expect(!shapes[2].is_lambda);
    try testing.expect(shapes[2].named == null);
}

test "lowers null literal" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const e = Expr{ .NullLit = .{ .span = dummySpan() } };
    const r = try lowerExpr(&b, &e);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "f", build.typeUnit());
    defer freeFunc(func);
    try testing.expect(func.blocks[0].insts[0] == .Const);
}

test "lowers unary negation" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    var lit = Expr{ .IntLit = .{ .value = 5, .kind = .Int, .span = dummySpan() } };
    const e = Expr{ .Unary = .{ .op = .Neg, .expr = &lit, .span = dummySpan() } };
    const r = try lowerExpr(&b, &e);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "f", build.typeInt());
    defer freeFunc(func);
    try testing.expect(func.blocks[0].insts[1] == .UnOp);
    try testing.expectEqual(UnOp.Neg, func.blocks[0].insts[1].UnOp.op);
}

test "unbound path in a plain body is a static global read" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    var seg = [_]ast.Ident{.{ .name = "println", .span = dummySpan() }};
    const e = Expr{ .Path = .{ .segments = &seg, .span = dummySpan() } };
    const r = try lowerExpr(&b, &e);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "f", build.typeUnit());
    defer freeFunc(func);
    // No receiver context: nothing can shadow the global, so the read
    // is statically classified.
    try testing.expect(func.blocks[0].insts[0] == .LoadGlobal);
}

test "unbound path in a lambda body resolves member-vs-global at runtime" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    b.setOuterNames(StringSet.init(testing.allocator));
    var seg = [_]ast.Ident{.{ .name = "println", .span = dummySpan() }};
    const e = Expr{ .Path = .{ .segments = &seg, .span = dummySpan() } };
    const r = try lowerExpr(&b, &e);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "f", build.typeUnit());
    defer freeFunc(func);
    // The lambda's bound receiver is unknowable statically; the Or form
    // keeps the runtime member arm.
    try testing.expect(func.blocks[0].insts[0] == .LoadFromThisOrGlobal);
}

test "lowers int min value as int" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    // -2147483648 parses as Neg(IntLit(2147483648)).
    var lit = Expr{ .IntLit = .{ .value = @as(i64, std.math.maxInt(i32)) + 1, .kind = .Int, .span = dummySpan() } };
    const e = Expr{ .Unary = .{ .op = .Neg, .expr = &lit, .span = dummySpan() } };
    const r = try lowerExpr(&b, &e);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "f", build.typeInt());
    defer freeFunc(func);
    try testing.expect(func.blocks[0].insts[0] == .Const);
    const cid = func.blocks[0].insts[0].Const.value;
    try testing.expect(m.consts.items[cid.int()] == .Int);
    try testing.expectEqual(@as(i32, std.math.minInt(i32)), m.consts.items[cid.int()].Int);
}

test "lowers if expression with both arms" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    var cond = Expr{ .BoolLit = .{ .value = true, .span = dummySpan() } };
    var t_branch = Expr{ .IntLit = .{ .value = 1, .kind = .Int, .span = dummySpan() } };
    var e_branch = Expr{ .IntLit = .{ .value = 2, .kind = .Int, .span = dummySpan() } };
    const e = Expr{ .If = .{
        .cond = &cond,
        .then_branch = &t_branch,
        .else_branch = &e_branch,
        .span = dummySpan(),
    } };
    const r = try lowerExpr(&b, &e);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "f", build.typeInt());
    defer freeFunc(func);
    // The entry block ends in a Branch terminator.
    try testing.expect(func.blocks[0].terminator == .Branch);
}

test "lowers string template as concat chain" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    var parts = [_]ast.StringPart{
        .{ .Text = "hi " },
        .{ .Text = "there" },
    };
    const e = Expr{ .StringTemplate = .{ .parts = &parts, .span = dummySpan() } };
    const r = try lowerExpr(&b, &e);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "f", build.typeString());
    defer freeFunc(func);
    // The final instruction is a StringConcat BinOp.
    const insts = func.blocks[0].insts;
    try testing.expect(insts[insts.len - 1] == .BinOp);
    try testing.expectEqual(BinOp.StringConcat, insts[insts.len - 1].BinOp.op);
}

test "lowers elvis as branch with null check" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    var lhs = Expr{ .NullLit = .{ .span = dummySpan() } };
    var rhs = Expr{ .IntLit = .{ .value = 3, .kind = .Int, .span = dummySpan() } };
    const e = Expr{ .Binary = .{ .op = .Elvis, .lhs = &lhs, .rhs = &rhs, .span = dummySpan() } };
    const r = try lowerExpr(&b, &e);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "f", build.typeInt());
    defer freeFunc(func);
    try testing.expect(func.blocks[0].terminator == .Branch);
}

test "lowers is-check to instance-of" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    var inner = Expr{ .IntLit = .{ .value = 1, .kind = .Int, .span = dummySpan() } };
    const ty = ast.TypeRef{
        .name = .{ .name = "Int", .span = dummySpan() },
        .nullable = false,
        .span = dummySpan(),
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
    const e = Expr{ .IsCheck = .{ .expr = &inner, .ty = ty, .negated = false, .span = dummySpan() } };
    const r = try lowerExpr(&b, &e);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "f", build.typeBool());
    defer freeFunc(func);
    const insts = func.blocks[0].insts;
    try testing.expect(insts[insts.len - 1] == .InstanceOf);
}

test "lowers postfix not-null assert" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    var inner = Expr{ .NullLit = .{ .span = dummySpan() } };
    const e = Expr{ .Postfix = .{ .op = .NotNull, .expr = &inner, .span = dummySpan() } };
    const r = try lowerExpr(&b, &e);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "f", build.typeUnit());
    defer freeFunc(func);
    const insts = func.blocks[0].insts;
    try testing.expect(insts[insts.len - 1] == .NotNullAssert);
}
