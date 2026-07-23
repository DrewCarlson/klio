//! Expression lowering — the central recursive dispatch. Every sibling
//! lower file calls back into `lowerExpr`. Covers literals, binary /
//! unary primitive operations, paths, member access, calls (including
//! the overload-resolution ladder), when / if / try as expressions,
//! lambdas, and the remaining grammar.

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
        const dst = try b.loadCaptureHoisted("this");
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

/// Resolve the instance selected by `super`. A lambda nested in a class
/// member keeps the member's lexical receiver in its closure capture slot,
/// even though the lambda frame has no locally bound `this` parameter.
fn resolveSuperThisReg(b: *FuncBuilder) Allocator.Error!?Reg {
    return resolveThisRegKind(b, true, false);
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
        // A class whose bare simple name is unregistered because it
        // collision-mangled (two `internal` classes named `TrieNode` in
        // different packages) is still pinned by the file's named import:
        // resolve `import …immutableMap.TrieNode` through its FQN. Without
        // this the receiver of `TrieNode.EMPTY` in an importing file falls to
        // a member access on the implicit receiver (`get_field TrieNode on
        // Companion`).
        var imported_fqn: ?[]const u8 = null;
        const imported_cid: ?ir.ClassId = if (!aliased and b.module.classId(n) == null) blk: {
            for (b.module.importAliasPathsIn(segments[0].span.file, n)) |p| {
                if (b.module.classIdByFqn(p.fqn)) |cid| {
                    imported_fqn = p.fqn;
                    break :blk cid;
                }
            }
            break :blk null;
        } else null;
        if (!aliased and b.resolve(n) == null and !b.knowsOuter(n) and
            (b.module.classId(n) != null or imported_cid != null) and !enclosingMemberShadowsClass(b, n))
        {
            const dst = b.allocReg();
            // A collision-mangled import has no name-published singleton under
            // its bare simple name; key the load on the FQN so the name-keyed
            // fallback (used when the singleton is not yet published) drives
            // the object/companion init by its fully-qualified name instead of
            // missing on the bare simple name.
            const nm = try b.module.internConst(b.allocator, .{ .String = imported_fqn orelse n });
            // The index-resolved class rides as the exact identity so a
            // same-simple-name class/object from an invisible package
            // cannot swap in at runtime (a nested `State` inside the
            // caller's class must not resolve to another package's
            // file-private `object State`). A same-named top-level
            // property keeps the name-keyed read — the property wins in
            // value position — but only when it is at least as visible
            // as the class at this site: a materialised stdlib property
            // from an unimported package (`kotlin.math.E` at the shipped
            // tier) must not outrank a user classifier named `E`.
            const cls_pick: ?ir.ClassId = blk: {
                if (imported_cid) |cid| break :blk cid;
                if (isTopLevelProp(n)) {
                    const pt = b.module.topLevelPropRefTier(n, b.self_package, segments[0].span.file) orelse 255;
                    const ct = b.module.classRefTier(n, b.self_package, segments[0].span.file) orelse 255;
                    if (pt <= ct) break :blk b.module.classIdExactImport(n, segments[0].span.file);
                }
                break :blk b.module.classIdIndexed(n, b.self_package, segments[0].span.file);
            };
            // A collision-mangled import target has no name-published singleton
            // to fall back on (`TrieNode` is registered only under its mangled
            // simple name), so load the class value by id directly — the
            // subsequent `.EMPTY` reads its companion off that value.
            try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = nm, .class = cls_pick, .ctor_ref = imported_cid != null } });
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
            // Then arm. An `if (x is T)` guard smart-casts `x` to `T` for the
            // arm, and extension resolution is static — see `narrowIsCheck`.
            b.switchTo(t_block);
            const narrowed = try narrowIsCheck(b, f.cond);
            const t_val = try lowerExpr(b, f.then_branch);
            if (narrowed) |n| b.restoreLocal(n);
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
            // `r[a, b, ...]` → r.get(a, b, ...). The `get` resolves against
            // the receiver's STATIC type, as kotlinc does: carry the declared
            // head so a runtime subtype's own generic `get<T>` cannot shadow
            // the statically-visible member. `map[local]` on a
            // `PersistentMap<CompositionLocal, ValueHolder>`-typed local must
            // bind the plain map `get` (returning the holder), never
            // `PersistentCompositionLocalHashMap.get<T>` (the composition-
            // local READ, which returns the resolved value). A head that is
            // not an ancestor of the runtime receiver disengages the static
            // scope, so an imprecise head degrades to the unhinted walk.
            const recv = try lowerReceiver(b, ix.receiver);
            const run = try lowerArgRun(b, ix.args);
            const dst = b.allocReg();
            const nm = try b.module.internConst(b.allocator, .{ .String = "get" });
            const static_recv: ?ConstId = blk: {
                const t = argDeclTypeRef(b, ix.receiver) orelse break :blk null;
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
                .arg_names = &.{},
                .static_recv = static_recv,
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
                const target = frame.break_target;
                try replayFinallysForJump(b, frame.finally_base);
                b.terminate(.{ .Goto = target });
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
                const target = frame.continue_target;
                try replayFinallysForJump(b, frame.finally_base);
                b.terminate(.{ .Goto = target });
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
                .ty = .{ .name = loweredCheckTypeName(b, &ck.ty), .nullable = ck.ty.nullable, .args = &.{} },
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
            // A cast to a NON-reified type parameter (`x as T`) is erased: the
            // JVM `checkcast` targets the bound and passes any value (including
            // null), so it is a runtime no-op — a genuine mismatch surfaces
            // only when the value is later used as `T`. Return the value as-is,
            // so a type parameter named like a concrete class (`class
            // ScopeMap<Key, Scope>` alongside a test's `class Scope`) is not
            // checked against that class and a nullable instantiation does not
            // throw. Reified type params are excluded (the reified splice
            // substitutes the concrete type before this point).
            if (b.isTypeParam(cast.ty.name.name)) return s;
            const dst = b.allocReg();
            try b.push(.{ .Cast = .{
                .dst = dst,
                .src = s,
                .ty = .{ .name = loweredCheckTypeName(b, &cast.ty), .nullable = cast.ty.nullable, .args = &.{} },
                .safe = cast.safe,
            } });
            return dst;
        },
        .Postfix => return lowerPostfix(b, expr),
        .Labeled => return lowerLabeled(b, expr),
        .PropertyRef => |pr| {
            // `::enumEntries` against a declared `() -> Head<E>` function
            // type: the expected return solves the target's single reified
            // type parameter, and the plain fn VALUE cannot carry it —
            // lower the reference as a zero-arg closure over the stamped
            // call instead.
            if (try reifiedRefClosure(b, pr.name.name, pr.name.span)) |r| return r;
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
            // `::rec` referencing the ENCLOSING local fn from inside its own
            // body (or a lambda nested in it): the plain name is unbound here
            // — and a later same-named sibling would rebind it — so the
            // reference loads the fn's own closure through its mangled cell,
            // the same binding a bare self-call uses. Extension locals need a
            // bound receiver and keep the member/property forms below.
            if (b.selfLocalFn()) |slf| {
                if (std.mem.eql(u8, slf.name, pr.name.name) and !b.isLocalExtFn(slf.mangled)) {
                    const cell: ?Reg = if (b.resolve(slf.mangled)) |r|
                        r
                    else if (b.knowsOuter(slf.mangled))
                        try resolveCapture(b, slf.mangled)
                    else
                        null;
                    if (cell) |c| {
                        try b.push(.{ .CellGet = .{ .dst = dst, .cell = c } });
                        return dst;
                    }
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
            if (class_pick != null and !member_shadows_ref) {
                try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = nm, .class = class_pick.?, .ctor_ref = true } });
            } else if (ref_pick != null and !member_shadows_ref) {
                const fid = ref_pick.?;
                const n = blk: {
                    if (b.module.funcById(fid)) |f| {
                        break :blk try b.module.internConst(b.allocator, .{ .String = f.fqn });
                    }
                    break :blk nm;
                };
                try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = n, .func = fid } });
            } else if ((b.module.funcId(pr.name.name) != null or b.module.classId(pr.name.name) != null) and !member_shadows_ref) {
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
                    // Inside a MEMBER EXTENSION the frame's `this` is the
                    // extension receiver; a `::name` referencing an OWNER
                    // member must bind the dispatch receiver instead
                    // (`::requestFocus` inside `SemanticsPropertyReceiver.
                    // applySemantics()` of FocusableNode). Route through
                    // the qualified-this runtime walk, which resolves the
                    // enclosing owner instance over the outer/receiver
                    // chains.
                    var recv_reg = this_reg;
                    if (member_shadows_ref) {
                        if (b.ownerClass()) |own| {
                            const ext_recv = b.recvTy();
                            if (ext_recv != null and !std.mem.eql(u8, ext_recv.?, own)) {
                                const qnm = try b.module.internConst(b.allocator, .{ .String = own });
                                const qreg = b.allocReg();
                                try b.push(.{ .QualifiedThis = .{ .dst = qreg, .receiver = this_reg, .qualifier = qnm } });
                                recv_reg = qreg;
                            }
                        }
                    }
                    try b.push(.{ .MemberRef = .{ .dst = dst, .receiver = recv_reg, .name = nm } });
                } else {
                    try b.push(.{ .PropertyRef = .{ .dst = dst, .name = nm } });
                }
            } else {
                try b.push(.{ .PropertyRef = .{ .dst = dst, .name = nm } });
            }
            return dst;
        },
        .MemberRef => |mr| {
            // `TypeName::class` on a bare type name: load the receiver with
            // constructor-reference semantics so a class that declares a
            // `companion object` yields the CLASS value, not its companion
            // singleton. Without `ctor_ref` a class-name read resolves to the
            // published companion (Kotlin's `C` ⇒ `C.Companion` value rule),
            // and `.class` then takes the companion's class — so once the
            // companion is constructed, `C::class` degrades to
            // `C$Companion$Companion` and `isInstance` / the name diverge.
            // `.class` is the identity on the resulting class value (and the
            // object's class for an `object` singleton), so it is kept.
            if (std.mem.eql(u8, mr.name.name, "class") and
                mr.receiver.* == .Path and mr.receiver.Path.segments.len == 1)
            {
                const rn = mr.receiver.Path.segments[0].name;
                if (b.resolve(rn) == null and !b.knowsOuter(rn)) {
                    if (b.module.classId(rn)) |cid| {
                        const recv = b.allocReg();
                        const rnm = try b.module.internConst(b.allocator, .{ .String = rn });
                        try b.push(.{ .LoadGlobal = .{ .dst = recv, .name = rnm, .class = cid, .ctor_ref = true } });
                        const dst = b.allocReg();
                        const cnm = try b.module.internConst(b.allocator, .{ .String = "class" });
                        try b.push(.{ .MemberRef = .{ .dst = dst, .receiver = recv, .name = cnm } });
                        return dst;
                    }
                }
            }
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
            // A receiver lambda binds `this` through the closure's capture
            // slot rather than a scope binding, so `visibleNames` misses it
            // (a method body binds it as a param and includes it). The
            // enclosing receiver is part of the anon's closed-over env: a
            // supertype ctor arg (`object : Prov(this)`) evaluates against
            // this snapshot before the object exists.
            if (!outer_names.contains("this") and
                (b.resolve("this") != null or b.capturesThisSlot() or b.knowsOuter("this")))
            {
                try outer_names.put("this", {});
            }
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
                .scope_classes = try collectScopeClasses(b, expr),
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
                    const dst2 = try b.loadCaptureHoisted(label);
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
                    break :blk try b.loadCaptureHoisted("this");
                };
                const nm = try b.module.internConst(b.allocator, .{ .String = q.name });
                const dst = b.allocReg();
                try b.push(.{ .QualifiedThis = .{ .dst = dst, .receiver = this_reg, .qualifier = nm } });
                return dst;
            }
            // `this` bare resolves to the implicit first param, or the
            // captured `this` slot inside a lambda body.
            const this_reg = b.resolve("this") orelse blk: {
                break :blk try b.loadCaptureHoisted("this");
            };
            return this_reg;
        },
        .Super => {
            // `super` bare reads the same instance value as `this`.
            if (try resolveSuperThisReg(b)) |this_reg| return this_reg;
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
/// Numeric/string/char/bool simple type heads whose `+`/`-` stay primitive.
fn isPrimitiveTypeName(name: []const u8) bool {
    const prims = [_][]const u8{ "Int", "Long", "Short", "Byte", "Double", "Float", "Char", "Boolean", "String", "UInt", "ULong", "UShort", "UByte", "Number" };
    for (prims) |p2| {
        if (std.mem.eql(u8, name, p2)) return true;
    }
    return false;
}

/// Resolve a non-primitive binary operator through the same member/extension
/// declaration engine as its explicit-call form (`a + b` is `a.plus(b)`).
/// The static argument type is essential for overloads such as
/// `Collection<T>.plus(element: T)` versus `.plus(elements: Sequence<T>)`.
fn lowerResolvedBinaryOperator(
    b: *FuncBuilder,
    op: AstBinOp,
    lhs: *const Expr,
    rhs: *const Expr,
    call_span: ast.Span,
) Allocator.Error!?Reg {
    const method: []const u8 = switch (op) {
        .Add => "plus",
        .Sub => "minus",
        else => return null,
    };

    var inferred_lhs_ty: ?ir.TypeRef = null;
    defer if (inferred_lhs_ty) |*ty| ty.deinit(b.allocator);
    const declared_lhs_ty = argDeclTypeRef(b, lhs) orelse blk: {
        inferred_lhs_ty = try staticCallReturnTypeRef(b, lhs);
        break :blk inferred_lhs_ty orelse return null;
    };
    if (isPrimitiveTypeName(typeHead(declared_lhs_ty.name))) return null;

    const args = rhs[0..1];
    const ident = ast.Ident{ .name = method, .span = call_span };
    if (try lowerResolvedMemberCall(
        b,
        lhs,
        ident,
        args,
        &.{},
        &.{},
        declared_lhs_ty,
    )) |reg| return reg;
    return try lowerResolvedExtensionCall(
        b,
        lhs,
        ident,
        method,
        null,
        args,
        &.{},
        &.{},
        declared_lhs_ty,
    );
}

fn lowerBinary(b: *FuncBuilder, bin: anytype) Allocator.Error!Reg {
    const op = bin.op;
    const lhs = bin.lhs;
    const rhs = bin.rhs;

    if (try lowerResolvedBinaryOperator(b, op, lhs, rhs, bin.span)) |reg| {
        return reg;
    }

    // Compatibility path for a known `this` receiver whose declaration set
    // is not yet complete enough for exact resolution. The shared resolver
    // runs first so smart casts and overload applicability can select the
    // precise static extension before this name-based fallback.
    if ((op == .Add or op == .Sub) and lhs.* == .This and lhs.This.qualifier == null) {
        const sty: ?[]const u8 = b.recvTy() orelse b.enclosingRecvTy();
        if (sty) |ty| {
            if (!isPrimitiveTypeName(ty)) {
                const l = try lowerExpr(b, lhs);
                const r = try lowerExpr(b, rhs);
                const args_start = try packContiguous(b, &.{r});
                const dst = b.allocReg();
                const nm = try b.module.internConst(b.allocator, .{ .String = if (op == .Add) "plus" else "minus" });
                try b.push(.{ .CallMember = .{
                    .dst = dst,
                    .receiver = l,
                    .name = nm,
                    .static_recv = try b.module.internConst(b.allocator, .{ .String = ty }),
                    .args = args_start,
                    .n_args = 1,
                    .arg_names = &.{},
                } });
                return dst;
            }
        }
    }

    // `list + (x as Any)`: kotlinc resolves `plus(element: T)` from the
    // RHS's STATIC type, appending the value as one element even when it
    // is itself a list at runtime. Route a statically list-headed LHS
    // with an Any-cast RHS through `plusElement`.
    if (op == .Add and staticListHead(lhs) and ast_scan.isBoxedToAnyForm(rhs)) {
        const l = try lowerExpr(b, lhs);
        const r = try lowerExpr(b, rhs);
        const args_start = try packContiguous(b, &.{r});
        const dst = b.allocReg();
        const nm = try b.module.internConst(b.allocator, .{ .String = "plusElement" });
        try b.push(.{ .CallMember = .{
            .dst = dst,
            .receiver = l,
            .name = nm,
            .args = args_start,
            .n_args = 1,
        } });
        return dst;
    }

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
        // lowers to `lo <= x && x <(=) hi` — but only when `x` is provably a
        // scalar element. A range-valued `x` dispatches `contains` instead
        // (an in-scope `operator LongRange.contains(LongRange)` decides
        // range-in-range; the element compare would be wrong for it).
        if (rhs.* == .Binary and (rhs.Binary.op == .Range or rhs.Binary.op == .RangeUntil) and
            !lhsIsRangeShaped(b, lhs))
        {
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
    if (build.fileTypeRename(name, file)) |renamed| return renamed;
    // Same-package cross-file reference to a package-renamed internal
    // top-level classifier.
    if (b.module.packageOfFile(ir.FileId.from(file))) |pkg| {
        if (build.pkgTypeRename(name, pkg)) |renamed| return renamed;
    }
    return null;
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
    if (b.module.packageOfFile(ir.FileId.from(file))) |pkg| {
        if (build.pkgTypeRenamesFor(pkg)) |m| {
            var it = m.iterator();
            while (it.next()) |e| {
                try out.append(b.allocator, .{ .name = e.key_ptr.*, .renamed = e.value_ptr.* });
            }
        }
    }
    return out.toOwnedSlice(b.allocator);
}

/// Resolve every bare classifier referenced by an anonymous-object subtree at
/// its lexical site. The object's bodies lower later in a side module, so these
/// exact identities must travel with the object instruction.
fn collectScopeClasses(b: *FuncBuilder, expr: *const Expr) Allocator.Error![]const ir.ScopeClassRef {
    var names = StringSet.init(b.allocator);
    defer names.deinit();
    try collectPathIdents(expr, &names);

    var out: std.ArrayList(ir.ScopeClassRef) = .empty;
    var it = names.keyIterator();
    while (it.next()) |name_ptr| {
        const name = name_ptr.*;
        const cid = classIdAtLexicalSite(b, name, expr.span().file) orelse continue;
        if (cid.int() >= b.module.classes.items.len) continue;
        const cls = b.module.classes.items[cid.int()];
        const has_companion = b.module.registry.companion_singletons.contains(name) or
            b.module.registry.companion_singletons.contains(cls.name) or
            b.module.registry.companion_singletons.contains(cls.fqn);
        try out.append(b.allocator, .{
            .name = name,
            .fqn = cls.fqn,
            .has_companion = has_companion,
        });
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

/// Lower a source type into an owned structural type for builder metadata.
/// The top-level head follows the same scope-aware classifier rename as
/// expression type positions.
pub fn loweredOwnedLocalTypeRef(b: *const FuncBuilder, ty: *const ast.TypeRef) Allocator.Error!TypeRef {
    var lowered = try decl_mod.loweredTypeRef(b.allocator, ty, true);
    errdefer lowered.deinit(b.allocator);
    const resolved_head = loweredTypeName(b, ty);
    if (!std.mem.eql(u8, lowered.name, resolved_head)) {
        const owned_head = try b.allocator.dupe(u8, resolved_head);
        b.allocator.free(lowered.name);
        lowered.name = owned_head;
    }
    if (ty.qualified_path == null) {
        var alias_fqn: ?[]const u8 = null;
        const imports = b.module.importAliasPathsIn(ty.span.file, ty.name.name);
        for (imports) |imported| {
            if (!b.module.registry.type_alias_types.contains(imported.fqn)) continue;
            if (alias_fqn != null and !std.mem.eql(u8, alias_fqn.?, imported.fqn)) {
                alias_fqn = null;
                break;
            }
            alias_fqn = imported.fqn;
        }
        const package = b.module.packageOfFile(ty.span.file) orelse b.self_package;
        const own_fqn = if (package.len == 0)
            try b.allocator.dupe(u8, ty.name.name)
        else
            try std.fmt.allocPrint(b.allocator, "{s}.{s}", .{ package, ty.name.name });
        defer b.allocator.free(own_fqn);
        if (alias_fqn == null and b.module.registry.type_alias_types.contains(own_fqn)) {
            alias_fqn = own_fqn;
        }
        if (alias_fqn) |fqn| {
            const marker = try std.fmt.allocPrint(b.allocator, "#qual:{s}", .{fqn});
            errdefer b.allocator.free(marker);
            const args = try b.allocator.alloc(ir.TypeRef, lowered.args.len + 1);
            errdefer b.allocator.free(args);
            @memcpy(args[0..lowered.args.len], lowered.args);
            args[args.len - 1] = .{
                .name = marker,
                .nullable = false,
                .args = &.{},
            };
            b.allocator.free(lowered.args);
            lowered.args = args;
        }
    }
    return lowered;
}

/// Type name for an `is` / `as` check. Like `loweredTypeName`, but a
/// package-qualified reference (`b.Shape`) keeps its dotted path (normalised
/// to the class FQN when it resolves) instead of being stripped to the simple
/// name, so the runtime hierarchy walk can compare class identity and reject a
/// same-simple-name class from another package. A nested-class path
/// (`Outer.Inner`) still maps to its lifted/mangled name.
pub fn loweredCheckTypeName(b: *const FuncBuilder, ty: *const ast.TypeRef) []const u8 {
    if (ty.qualified_path) |qp| {
        if (lastTwoSegments(qp)) |key| {
            if (b.module.registry.mangled_nested.get(key)) |m| return m;
        }
        // Normalise to the canonical FQN when the dotted path resolves to a
        // registered class; otherwise carry the dotted path through so the
        // runtime resolves (or strips) it once every class is registered.
        if (b.module.classIdByFqn(qp)) |cid| {
            if (cid.int() < b.module.classes.items.len) return b.module.classes.items[cid.int()].fqn;
        }
        return qp;
    }
    if (scopeTypeRename(b, ty.name.name, ty.span.file.int())) |renamed| return renamed;
    // A bare check type this file's explicit import names (`import
    // …Operation.Marker`; `x is Marker`) normalises to the imported class's
    // canonical FQN, so the runtime compares class identity — the simple
    // name alone cannot resolve a nested member two packages both declare
    // (its lifted name is shared, so a name compare matches either twin).
    // An enclosing class's own nested classifier still wins over the
    // import (inner scope first), keeping the simple-name compare.
    if (!enclosingDeclaresNestedClassifier(b, ty.name.name)) {
        if (b.module.classIdExactImport(ty.name.name, ty.span.file)) |cid| {
            if (cid.int() < b.module.classes.items.len) return b.module.classes.items[cid.int()].fqn;
        }
    }
    return ty.name.name;
}

/// Whether any class in the enclosing-class chain declares a NESTED
/// classifier named `name` — the scope where a bare check-type name binds
/// before the file's imports are consulted.
fn enclosingDeclaresNestedClassifier(b: *const FuncBuilder, name: []const u8) bool {
    const oc = b.ownerClass() orelse return false;
    const owner_id = b.module.classId(oc) orelse return false;
    return b.module.classIdNestedIn(owner_id, name) != null;
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

    // `var x by D` reads THROUGH the delegate: `D.getValue(null, ::x)` at every
    // read, not once at the declaration. A `MutableState` delegate hands back the
    // state's current value that way — and, in a composition, records the read on
    // the snapshot, which is what makes a later write invalidate the group that
    // read it. Reading a value cached at the declaration recorded no read at all,
    // so `var name by mutableStateOf(…)` never recomposed.
    if (segments.len == 1) {
        if (try lowerDelegateRead(b, segments[0].name)) |r| return r;
    }

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
        // Splice hygiene for the suspend-implicit `coroutineContext`: inside a
        // SPLICED inline-fn body (not an inline-argument lambda, whose source
        // lives at the caller), the bare name means the intrinsic — the callee
        // could not see a caller local/param that happens to share it. Without
        // this, `currentCoroutineContext()` (body: bare `coroutineContext`)
        // spliced into a function with a `coroutineContext` PARAMETER answered
        // with the parameter.
        if (std.mem.eql(u8, name0, "coroutineContext") and b.lambda_splice_resolve == null) {
            if (b.inlineLambdaCallerDepth()) |base| {
                if (b.resolveSpliceLocal(name0, base) == null) {
                    const dst = b.allocReg();
                    const n = try b.module.internConst(b.allocator, .{ .String = "coroutineContext" });
                    try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = n } });
                    return dst;
                }
            }
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
        // the captured value. Whether the capture is a shared Cell (a
        // written-through outer `var`) is decided by the CAPTURE SITE's
        // builder, invisible here — so always read through CellGet, which
        // passes a non-cell value unchanged. Without this a captured
        // counter's `++` handed the raw Cell to UnOp.
        if (isLowerAnonCapture(name0)) {
            const cell = try b.loadCaptureHoisted(name0);
            const dst = b.allocReg();
            try b.push(.{ .CellGet = .{ .dst = dst, .cell = cell } });
            return dst;
        }
        // Lambda-body capture.
        if (b.knowsOuter(name0)) {
            const cell = try b.loadCaptureHoisted(name0);
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
        // A NESTED classifier of the enclosing class (`enum LayoutState` inside
        // `LayoutNode`, referenced bare) is also excepted: it is a class
        // reference, not an instance member, so it falls to the class-ref
        // lowering below (which loads the nested class and reads the enum entry).
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
        // Runtime-lowered anonymous-object bodies carry the exact classifier
        // identities visible at their lexical site. Their side modules do not
        // contain the program class index, so bind the classifier directly by
        // FQN after locals, captures, and receiver members have had priority.
        if (build.anonScopeClass(name0)) |class_ref| {
            const cls = b.allocReg();
            const fqn = try b.module.internConst(b.allocator, .{ .String = class_ref.fqn });
            try b.push(.{ .LoadGlobal = .{ .dst = cls, .name = fqn } });
            if (!class_ref.has_companion) return cls;
            const dst = b.allocReg();
            const sentinel = try b.module.internConst(b.allocator, .{ .String = "<class-companion-or-self>" });
            try b.push(.{ .GetField = .{ .dst = dst, .receiver = cls, .field = sentinel } });
            return dst;
        }
        // A visible top-level `const val` outranks a class binding from a
        // less-visible scope: inside ScatterMap.kt the bare `Empty` is the
        // file's compile-time constant, never kotlinx-atomicfu's file-private
        // `object Empty` that shares the simple name in the flat class table.
        // Compare scope tiers and inline the literal when the constant wins
        // (Kotlin inlines const vals at every reference).
        if (b.resolve(name0) == null and !b.knowsOuter(name0) and
            !b.hasOwnMember(name0) and !b.hasEnclosingMember(name0))
        {
            if (b.module.topLevelConstLiteral(name0, b.self_package, segments[0].span.file)) |cv| {
                const ptier = b.module.topLevelPropRefTier(name0, b.self_package, segments[0].span.file) orelse 255;
                const ctier = b.module.classRefTier(name0, b.self_package, segments[0].span.file) orelse 255;
                if (ptier < ctier) {
                    orEmitAudit(b, "top_level_prop", "ConstInline", name0);
                    return try b.emitConst(cv);
                }
            }
        }
        // A NAMED companion-member import outranks a same-named class in
        // expression position (kotlinc: `import Layout.Companion.Marker`
        // binds the value `Marker` even when an `interface Marker` is in
        // scope — the classifier only matters in type position). Rewrite
        // to the qualified companion access before the class arm below
        // can capture the name.
        if (b.resolve(name0) == null and !b.knowsOuter(name0) and
            !b.hasOwnMember(name0) and !b.hasEnclosingMember(name0))
        {
            if (importCompanionRewrite(b, segments[0].span.file, name0)) |rw| {
                const sp = segments[0].span;
                const rsegs = try b.allocator.alloc(ast.Ident, rw.segs.len);
                for (rw.segs, 0..) |s2, k| rsegs[k] = .{ .name = s2, .span = sp };
                const qualified = Expr{ .Path = .{ .segments = rsegs, .span = sp } };
                return lowerExpr(b, &qualified);
            }
        }
        // A bare name that is a known class is a class reference. In a
        // receiver context a runtime receiver member shadows the
        // classifier (kotlinc: a property named like a class wins in
        // expression position), so the read decides at runtime with the
        // index-resolved class riding as the exact global arm; the
        // companion sentinel passes a member value through unchanged.
        // The flat `classId` is null when a same-simple-name class in another
        // package forced collision-mangling (both `gapbuffer` and `linkbuffer`
        // `InsertSlotsWithFixups` leave the simple name out of the index). An
        // explicit `import pkg.Outer.Name` in THIS file still names exactly one
        // of them, so treat the bare name as that class reference rather than
        // letting it fall to a by-name global read that binds first-registered.
        if ((b.module.classId(name0) != null or
            b.module.classIdExactImport(name0, segments[0].span.file) != null) and
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
                const rsegs = try b.allocator.alloc(ast.Ident, rw.segs.len);
                for (rw.segs, 0..) |s, k| rsegs[k] = .{ .name = s, .span = sp };
                const qualified = Expr{ .Path = .{ .segments = rsegs, .span = sp } };
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
            // Kotlin `const val` semantics: a reference to a visible
            // top-level compile-time constant inlines its literal value.
            // This also makes the read immune to the flat runtime global
            // table, where a same-simple-name value published by another
            // module can capture the name (androidx.collection's `Empty`
            // sentinel vs compose's `LocaleList.Empty`).
            if (b.module.topLevelConstLiteral(name0, b.self_package, segments[0].span.file)) |cv| {
                orEmitAudit(b, "top_level_prop", "ConstInline", name0);
                return try b.emitConst(cv);
            }
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
            // A name declared only by an outer class must not become a plain
            // field read on the inner `this`. Defer it to the implicit-receiver
            // walk below, which carries the declaring class in the scoped
            // getter name. The same rule handles receiver lambdas, where the
            // innermost candidate may instead be a scope-function receiver.
            const enclosing_only_member = !b.hasOwnMember(name0) and b.hasEnclosingMember(name0);
            if (!is_known_global and !enclosing_only_member) {
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
        // Ride the exact class id of the longest FQN prefix that names a class
        // so the runtime binds that declaration rather than re-resolving the
        // tail by simple name (two packages with a same-simple-name
        // `Operation.Ins` would otherwise both bind the first-registered one).
        if (try emitFqnWithClassPrefix(b, fqn)) |r| return r;
        const dst = b.allocReg();
        const n = try b.module.internConst(b.allocator, .{ .String = fqn });
        try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = n } });
        // A fully-qualified class-with-companion in value position resolves to
        // its companion singleton (Kotlin: `C` yields `C.Companion`), the same
        // forwarding the bare-name arm applies. Without it `pkg.C` loaded the
        // class value while bare `C` loaded the companion, so `pkg.C === C`
        // was false and `context[ContinuationInterceptor]` (an interface with a
        // named companion Key) missed the dispatcher element. The
        // `<class-companion-or-self>` sentinel returns the companion when one
        // exists and the class/object value otherwise, so a plain object or a
        // companion-less class is unaffected.
        const fqn_simple = if (std.mem.lastIndexOfScalar(u8, fqn, '.')) |d| fqn[d + 1 ..] else fqn;
        if (classWithCompanion(b, fqn_simple) and b.module.funcIdByFqn(fqn) == null) {
            const comp = b.allocReg();
            const sentinel = try b.module.internConst(b.allocator, .{ .String = "<class-companion-or-self>" });
            try b.push(.{ .GetField = .{ .dst = comp, .receiver = dst, .field = sentinel } });
            return comp;
        }
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

/// The nearest lexical class whose hierarchy declares `name`. A lambda keeps
/// its enclosing class as `ownerClass`, while a lifted inner class reaches its
/// outer classes through `enclosing_class`; consulting both gives a scoped
/// getter the class that actually contributes the bare property.
fn sgetterOwner(b: *const FuncBuilder, name: []const u8) ?[]const u8 {
    const lexical_owner = b.ownerClass() orelse return null;
    var owner: ?[]const u8 = lexical_owner;
    var hops: usize = 0;
    while (owner) |o| : (hops += 1) {
        if (hops > 32) break;
        const own = std.mem.eql(u8, o, lexical_owner) and b.hasOwnMember(name);
        const hierarchy_has = if (b.module.registry.hierarchy_shadow_names.get(o)) |hierarchy|
            hierarchy.names.contains(name)
        else
            false;
        if (own) return o;
        if (hierarchy_has) return o;
        owner = b.module.registry.enclosing_class.get(o);
    }
    return lexical_owner;
}

/// Intern the scope-qualified getter field name `$sgetter$<owner>\u{1f}<name>`
/// when an enclosing class is known, else the plain name.
fn sgetterName(b: *FuncBuilder, name: []const u8) Allocator.Error!ConstId {
    if (sgetterOwner(b, name)) |owner| {
        // The const pool stores the slice by reference, so the buffer must
        // live for the module's lifetime — let the module allocator own it
        // rather than freeing it here (which would leave a dangling field
        // name read back at dispatch time).
        const qual = try std.fmt.allocPrint(b.allocator, "$sgetter${s}\u{1f}{s}", .{ owner, name });
        return b.module.internConst(b.allocator, .{ .String = qual });
    }
    return b.module.internConst(b.allocator, .{ .String = name });
}

const ImportRewrite = struct { segs: []const []const u8 };

/// Resolve a bare name imported via `import a.b.C…MEMBER` into the qualified
/// access path starting at the rightmost segment naming a class this module
/// declares (dropping the leading package). Intermediate segments between the
/// class and the member are preserved (`import Outer.State.Idle` → the nested
/// `Outer.State.Idle`), EXCEPT an explicit `Companion` hop, which is dropped
/// because a companion member is reached through the class itself
/// (`import X.Companion.member` → `X.member`). Returns null when the path names
/// no declared class, or the class is the leaf (a bare type reference).
fn importCompanionRewrite(b: *FuncBuilder, file: ir.FileId, name: []const u8) ?ImportRewrite {
    const segs = b.module.importAliasIn(file, name) orelse return null;
    // Find the rightmost segment naming a class the module declares (skips the
    // leading package), then extend left across any enclosing-class chain so the
    // path starts at the OUTERMOST (top-level, globally loadable) class — a bare
    // nested class name (`LayoutState`) is not itself loadable, but the qualified
    // `Outer.LayoutState.Idle` resolves the nested classifier then the entry.
    // The scan excludes the LEAF segment: the leaf is the imported member,
    // and a same-named CLASS elsewhere in scope must not capture it —
    // `import Layout.Companion.Marker` next to an `interface Marker` still
    // rewrites to `Layout.Marker`. (A bare `import a.b.SomeClass` type
    // reference has no member segment and simply finds no class here.)
    var cls_idx: ?usize = null;
    var i = segs.len - 1;
    while (i > 0) {
        i -= 1;
        if (b.module.classId(segs[i]) != null) {
            cls_idx = i;
            break;
        }
    }
    const ci = cls_idx orelse return null;

    var start = ci;
    while (start > 0 and b.module.classId(segs[start - 1]) != null) start -= 1;

    // Keep the leading package segments when the class named by the import's
    // FQN is NOT the one its simple name resolves to in the flat class index
    // — either the simple name was collision-mangled out (two packages declare
    // a same-simple-name nested member, gapbuffer vs linkbuffer `Operation`)
    // or it resolves to a different, first-registered declaration. Dropping the
    // package would bind that wrong one; the full `pkg.Outer.Member` path
    // resolves the exact declaration the import named.
    if (start > 0) {
        const fqn_parts = segs[0 .. ci + 1];
        const fqn = std.mem.join(b.allocator, ".", fqn_parts) catch return null;
        if (b.module.classIdByFqn(fqn)) |fqn_cid| {
            const simple_cid = b.module.classId(segs[ci]);
            if (simple_cid == null or simple_cid.?.int() != fqn_cid.int()) start = 0;
        }
    }

    const last = segs.len - 1;
    var out = b.allocator.alloc([]const u8, segs.len - start) catch return null;
    var n: usize = 0;
    var j = start;
    while (j < segs.len) : (j += 1) {
        // Drop an intermediate `Companion` hop — `X.member` resolves the
        // companion member — but keep a nested classifier (`Outer.State`).
        if (j != last and std.mem.eql(u8, segs[j], "Companion")) continue;
        out[n] = segs[j];
        n += 1;
    }
    return .{ .segs = out[0..n] };
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
        return b.loadCaptureHoisted("this");
    }
    // `"… $x …"` where `x` is a `var x by D` local reads THROUGH the delegate,
    // exactly as a bare `x` does.
    if (try lowerDelegateRead(b, ident.name)) |r| return r;
    if (b.resolve(ident.name)) |r| {
        if (b.isBoxed(ident.name)) {
            const dst = b.allocReg();
            try b.push(.{ .CellGet = .{ .dst = dst, .cell = r } });
            return dst;
        }
        return r;
    }
    if (b.knowsOuter(ident.name)) {
        const cell = try b.loadCaptureHoisted(ident.name);
        if (b.isBoxed(ident.name)) {
            const dst = b.allocReg();
            try b.push(.{ .CellGet = .{ .dst = dst, .cell = cell } });
            return dst;
        }
        return cell;
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
        // `recv?.x` — null-guard. An explicit `recv?.coroutineContext` is a
        // literal member read exactly like the non-safe arm below: without the
        // sentinel the runtime's suspend-implicit redirect served the AMBIENT
        // coroutine's context instead of the receiver's own.
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
        const field_name: []const u8 = if (std.mem.eql(u8, name.name, "coroutineContext"))
            "$coroutineContext$explicit"
        else
            name.name;
        const field = try b.module.internConst(b.allocator, .{ .String = field_name });
        const v = b.allocReg();
        try b.push(.{ .GetField = .{ .dst = v, .receiver = recv, .field = field } });
        try b.push(.{ .Move = .{ .dst = dst, .src = v } });
        b.terminate(.{ .Goto = join });
        b.switchTo(join);
        return dst;
    }

    // `super.<prop>` — dispatch its getter via the parent chain.
    if (receiver.* == .Super) {
        if (try resolveSuperThisReg(b)) |this_reg| {
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
            if (try emitFqnWithClassPrefix(b, fqn)) |r| return r;
            const dst = b.allocReg();
            const n = try b.module.internConst(b.allocator, .{ .String = fqn });
            try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = n } });
            // A fully-qualified class-with-companion in value position yields its
            // companion singleton (Kotlin: `C` yields `C.Companion`), matching the
            // bare-name arm. Without it `pkg.C` loaded the class value while bare
            // `C` loaded the companion, so `pkg.C === C` was false and
            // `context[ContinuationInterceptor]` (an interface with a named
            // companion Key) missed the dispatcher element. The
            // `<class-companion-or-self>` sentinel returns the companion when one
            // exists and the class/object value otherwise, leaving a plain object
            // or a companion-less class unchanged.
            const fqn_simple = if (std.mem.lastIndexOfScalar(u8, fqn, '.')) |d| fqn[d + 1 ..] else fqn;
            // A same-FQN factory function (`kotlinx.coroutines.Job` is both an
            // interface with a companion `Key` AND a `fun Job()` factory) keeps
            // the class value: as a call callee it is the factory, and a bare
            // reference reaches its companion through explicit `.Key`. Only a
            // companioned classifier with no such function forwards.
            if (classWithCompanion(b, fqn_simple) and b.module.funcIdByFqn(fqn) == null) {
                const comp = b.allocReg();
                const sentinel = try b.module.internConst(b.allocator, .{ .String = "<class-companion-or-self>" });
                try b.push(.{ .GetField = .{ .dst = comp, .receiver = dst, .field = sentinel } });
                return comp;
            }
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

    // Static-type-directed extension-property read. When the receiver's
    // STATIC type resolves `name` to an in-scope member-extension property
    // rather than a member of that type, Kotlin runs the extension getter —
    // a same-named stored field the runtime object happens to carry is
    // irrelevant. Emit an extension-read marker so dispatch resolves the
    // extension property instead of that accidental field.
    if (try staticExtPropReadField(b, receiver, name.name)) |marker| {
        const recv = try lowerReceiver(b, receiver);
        const dst = b.allocReg();
        try b.push(.{ .GetField = .{ .dst = dst, .receiver = recv, .field = marker } });
        return dst;
    }

    // Explicit `this.x` where the enclosing class declares `x` as a private
    // SHADOW of a supertype's same-name stored property reads ITS OWN
    // owner-mangled cell, matching the bare-name read and the shadow write.
    if (receiver.* == .This and receiver.This.qualifier == null) {
        if (b.ownerClass()) |owner| {
            var kb: [256]u8 = undefined;
            if (std.fmt.bufPrint(&kb, "{s}\u{1f}{s}", .{ owner, name.name })) |probe| {
                if (b.module.registry.private_shadow_props.getKey(probe)) |key| {
                    const trecv = try lowerReceiver(b, receiver);
                    const tdst = b.allocReg();
                    const tfield = try b.module.internConst(b.allocator, .{ .String = key });
                    try b.push(.{ .GetField = .{ .dst = tdst, .receiver = trecv, .field = tfield } });
                    return tdst;
                }
            } else |_| {}
        }
    }

    const recv = try lowerReceiver(b, receiver);
    const dst = b.allocReg();
    const field = try b.module.internConst(b.allocator, .{ .String = name.name });
    try b.push(.{ .GetField = .{ .dst = dst, .receiver = recv, .field = field } });
    return dst;
}

/// The statically known type-head of a bare single-name receiver: a typed
/// local/param, else an enclosing-class member (property / constructor-
/// parameter property) walked over the owner's supertype chain. Null when the
/// name has no statically known type here (an untyped local, an outer
/// capture, or a name the enclosing class does not declare as a typed member).
fn staticBareReceiverType(b: *const FuncBuilder, recv_name: []const u8) ?[]const u8 {
    // A local/param binding shadows an enclosing member of the same name.
    if (b.resolve(recv_name) != null) return b.localDeclType(recv_name);
    if (b.knowsOuter(recv_name)) return null;
    const owner = b.ownerClass() orelse return null;
    const heads = b.module.registry.class_prop_type_heads;
    if (heads.get(.{ .a = owner, .b = recv_name })) |h| return h;
    const chain: []const []const u8 = b.module.registry.class_super_names.get(owner) orelse &.{};
    for (chain) |cls| {
        if (heads.get(.{ .a = cls, .b = recv_name })) |h| return h;
    }
    return null;
}

/// Whether `ty` (or a supertype) declares a member property named `name`.
/// Keyed on `class_prop_type_heads`, which records member and constructor-
/// parameter properties by declaring class.
fn staticTypeDeclaresProp(b: *const FuncBuilder, ty: []const u8, name: []const u8) bool {
    const heads = b.module.registry.class_prop_type_heads;
    if (heads.get(.{ .a = ty, .b = name }) != null) return true;
    const chain: []const []const u8 = b.module.registry.class_super_names.get(ty) orelse return false;
    for (chain) |cls| {
        if (heads.get(.{ .a = cls, .b = name }) != null) return true;
    }
    return false;
}

/// When a qualified read `recv.name` resolves — by the STATIC type of `recv`
/// — to an in-scope member-extension property whose getter must win over any
/// same-named stored field on the runtime object, return the interned
/// `$extread$<name>` marker. Null when the ordinary field read applies.
fn staticExtPropReadField(b: *FuncBuilder, receiver: *const Expr, name: []const u8) Allocator.Error!?ConstId {
    const recv_name = switch (receiver.*) {
        .Path => |p| if (p.segments.len == 1) p.segments[0].name else return null,
        else => return null,
    };
    const static_ty = staticBareReceiverType(b, recv_name) orelse return null;
    const owner = b.ownerClass() orelse return null;
    // An in-scope member-extension property `name` on the enclosing class
    // whose extension-receiver type the static type satisfies.
    const ext_recv = inline_state.memberExtPropRecv(owner, name) orelse return null;
    if (!b.module.classIsOrExtends(static_ty, ext_recv)) return null;
    // A member of the static type outranks the extension (Kotlin); the
    // ordinary field read is then correct.
    if (staticTypeDeclaresProp(b, static_ty, name)) return null;
    const marker = try std.fmt.allocPrint(b.allocator, "$extread${s}", .{name});
    return try b.module.internConst(b.allocator, .{ .String = marker });
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

/// Replay the `finally { … }` bodies pushed above `base` inline, innermost
/// first, ahead of a jump that leaves their try regions (an inline `return`
/// to its join, a `break`/`continue` crossing a `try`). While one finally
/// replays, only the finallys strictly outside it stay active, so a jump
/// within the finally body still unwinds correctly. The bypassed try
/// regions' runtime `TryFrame`s are popped when the current block exits —
/// the jump bypasses the finally sentinel that would pop them.
fn replayFinallysForJump(b: *FuncBuilder, base_raw: usize) Allocator.Error!void {
    const base = @min(base_raw, b.finally_stack.items.len);
    const pop_bodies = try b.finallyBodiesFrom(base);
    if (b.finally_stack.items.len > base) {
        const prior = try b.swapFinallyStack(&.{});
        defer b.allocator.free(prior);
        var idx: usize = prior.len;
        while (idx > base) {
            idx -= 1;
            const blk = &prior[idx];
            const outer = try b.allocator.dupe(ast.Block, prior[0..idx]);
            const dropped = try b.swapFinallyStack(outer);
            b.allocator.free(dropped);
            _ = try lowerBlock(b, blk);
        }
        const restore = try b.allocator.dupe(ast.Block, prior);
        const dropped2 = try b.swapFinallyStack(restore);
        b.allocator.free(dropped2);
    }
    if (pop_bodies.len != 0) {
        b.setPopOnExit(b.cur, pop_bodies);
    } else {
        b.allocator.free(pop_bodies);
    }
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
            // Replay the `finally { … }` blocks pushed *inside* this inline
            // frame before jumping to its join. Finallys from an enclosing
            // inline frame belong to that frame's own return and must not run
            // here: `composing { try { return snap.enter(block) } finally { apply } }`
            // inlines `enter { try { return block() } finally { restore } }`, so
            // at `return block()` the stack holds [apply, restore]; replaying
            // both would apply the snapshot twice.
            try replayFinallysForJump(b, ar.finally_base);
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
        // A bare `return` in an argument lambda returns from the function
        // the lambda is WRITTEN in. When the enclosing inline callee runs
        // as a real frame (image-deferred / cross-pack body), the labeled
        // form unwinds exactly to that frame (`frameMatchesLabel`); an
        // untargeted non-local return would be absorbed by the first HOF
        // boundary — `fastFirstOrNull`'s `return it` escaped its own body
        // and became its CALLER's return value.
        if (build.currentRealFn()) |ename| {
            b.terminate(.{ .LabeledReturn = .{ .label = ename, .value = r } });
        } else {
            b.terminate(.{ .NonLocalReturn = r });
        }
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
    if (finally_entry == null and t.catches.len != 0) b.setCatchDoneFor(cur_id, exit);
    if (t.finally) |blk| try b.pushFinally(blk, cur_id);
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
    const eager_shape = b.module.eagerParamShapeOf(lam.body.span);
    const recorded_recv = b.lambdaArgRecv(expr.span());
    var expected_recv_owned: ?ir.TypeRef = null;
    defer if (expected_recv_owned) |receiver| {
        var cleanup = receiver;
        cleanup.deinit(b.allocator);
    };
    const expected_recv: ?ir.TypeRef = blk: {
        if (b.peekExpected()) |exp| {
            if (exp.function) |ft| {
                if (ft.receiver) |*receiver| {
                    expected_recv_owned = try loweredOwnedLocalTypeRef(b, receiver);
                    break :blk expected_recv_owned.?;
                }
            }
        }
        break :blk null;
    };
    const expected_shape_known = if (b.peekExpected()) |exp|
        exp.function != null
    else
        false;
    const receiver_type = recorded_recv orelse expected_recv;
    const receiver_head = if (receiver_type) |receiver|
        receiver.name
    else
        b.module.eagerRecvHeadOf(lam.body.span);
    const lambda_receiver_shape_known = expected_shape_known or
        recorded_recv != null or eager_shape != null;
    const lambda_has_receiver = receiver_head != null or
        (eager_shape != null and eager_shape.?.has_receiver);
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
    // The arity recorded at the call site (by span), authoritative when the
    // per-argument `pending_lambda_arity` was not set on this emit path.
    if (expected_arity == -1) {
        if (b.lambdaArgArity(expr.span())) |ar| expected_arity = ar;
    }
    if (expected_arity == -1) {
        if (b.peekExpected()) |exp| {
            if (exp.function) |ft| {
                expected_arity = @intCast(ft.params.len);
            }
        }
    }
    // Last resort: typeck's own answer for this lambda, keyed by its body span.
    // The AST-side sources above all need the callee's signature, which a
    // CROSS-PACK member call does not have — the callee is absent from the
    // lowering module's name index (`onDrawWithContent { … }` on a
    // `CacheDrawScope` declared in another pack). Typeck resolved the expected
    // type across packs, so it knows the value arity even when the lowering
    // cannot see the declaration.
    if (expected_arity == -1) {
        if (eager_shape) |shape| {
            expected_arity = @intCast(shape.arity);
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
    const inherited_erp = try b.erasedRecvParamNames();
    // The implicit label this lambda carries (`runTest { … }` → "runTest").
    // The body binds `this@<label>` to its receiver.
    b.module.pending_lambda_this_label = b.pending_lambda_label;
    // The receiver type in scope at the body's site: a receiver lambda
    // (`T.() -> R`) rebinds the implicit `this` to `T`, otherwise a plain
    // block captures the enclosing `this`. Carried into the body so a bare
    // call there can still disambiguate a receiver-lambda argument's arity.
    // A receiver-lambda ARGUMENT whose receiver type the resolved callee made
    // concrete (recorded by `recordLambdaArgReceivers`) — reached when the
    // call is deferred so no expected type carries the receiver to lowerLambda.
    b.module.pending_lambda_receiver_tower = try b.collectImplicitReceiverTower(b.allocator, receiver_head);
    b.module.pending_lambda_enclosing_recv = blk: {
        if (receiver_head) |rr| break :blk rr;
        break :blk b.enclosingRecvTy();
    };
    // The body owns that receiver as its extension receiver, so a bare call
    // there prefers an extension on it over a same-file plain namesake —
    // `validate { contact(c) }` binds `MockViewValidator.contact`, not the
    // same-file `@Composable contact`.
    if (receiver_head) |rr| b.module.pending_lambda_own_recv = rr;
    if (receiver_type) |receiver| {
        b.module.pending_lambda_own_recv_type = try receiver.clone(b.allocator);
    }
    if (!suppress_it) {
        if (b.pending_ref_lambda_param_types) |types| {
            const value_param_count: usize = if (lam.implicit_it and
                eff_params.len == 0) 1 else eff_params.len;
            const count = @min(types.len, value_param_count);
            const owned = try b.allocator.alloc(ir.TypeRef, count);
            var initialized: usize = 0;
            errdefer {
                for (owned[0..initialized]) |*ty| ty.deinit(b.allocator);
                b.allocator.free(owned);
            }
            for (types[0..count], owned) |src, *dst| {
                dst.* = try src.clone(b.allocator);
                initialized += 1;
            }
            b.module.pending_lambda_param_types = owned;
        }
    }
    // Carry the enclosing non-reified type-parameter names so an `x as T`
    // cast inside the lambda body is still erased.
    b.module.pending_lambda_type_params = try b.typeParamNamesSlice();
    b.module.pending_lambda_type_param_bounds = try b.typeParamBoundsSlice();
    // A lambda inside a local fn's body keeps that fn's self-identity (a
    // named local fn overrides this with its own before its body lowers).
    if (b.module.pending_lambda_self_fn == null) b.module.pending_lambda_self_fn = b.selfLocalFn();
    // Non-callable-local evidence flows into the body (transitively — this
    // builder's set already includes what it inherited).
    b.module.pending_lambda_nonfn_locals = try b.nonFnLocalNames();
    b.module.pending_lambda_local_decl_types = try b.localDeclTypesSnapshot();
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
        inherited_erp,
        &b.local_fn_overloads,
        enclosing_owner,
        suppress_it,
        if (suppress_it) lam.span else null,
        broad_names.items,
        generic_names.items,
    );
    const body_func = lowered.func;
    const captured_names = lowered.captures;
    if (b.module.funcByIdMut(body_func)) |f| {
        f.lambda_receiver_shape_known = lambda_receiver_shape_known;
        f.lambda_has_receiver = lambda_has_receiver;
    }

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
    const receiver_head: ?[]const u8 = if (af.receiver_ty) |r| r.name.name else null;
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
    const inherited_erp = try b.erasedRecvParamNames();
    b.module.pending_lambda_receiver_tower = try b.collectImplicitReceiverTower(b.allocator, receiver_head);
    if (receiver_head) |head| {
        b.module.pending_lambda_enclosing_recv = head;
        b.module.pending_lambda_own_recv = head;
    }
    if (af.receiver_ty) |*receiver| {
        b.module.pending_lambda_own_recv_type = try loweredOwnedLocalTypeRef(b, receiver);
    }
    b.module.pending_lambda_nonfn_locals = try b.nonFnLocalNames();
    b.module.pending_lambda_local_decl_types = try b.localDeclTypesSnapshot();
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
        inherited_erp,
        enclosing_owner,
    );
    const captured_names = lowered.captures;
    if (b.module.funcByIdMut(lowered.func)) |f| {
        f.lambda_receiver_shape_known = true;
        f.lambda_has_receiver = receiver_head != null;
    }
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

/// The class MEMBER that hosts a trailing lambda for a bare call, reached
/// owner-scoped through `member_method_fids`. `Module.func_name_index` indexes
/// only TOP-LEVEL functions, so a bare call to a member (`onDrawWithContent { … }`
/// inside a `CacheDrawScope` extension) could not reach its signature at lower
/// time: the trailing lambda's expected arity came back unknown and a
/// `T.() -> R` receiver lambda kept the parser's synthetic `it`, which then
/// swallowed the receiver at invocation.
///
/// The candidate classes are the enclosing owner and the declared extension
/// receiver, each walked up its supertype chain — the member may be declared on
/// a supertype of the receiver we are lowering against.
fn memberHostingTrailingLambda(b: *FuncBuilder, name: []const u8, user_arg_count: usize) ?FuncId {
    var roots: [2]?[]const u8 = .{ b.ownerClass(), null };
    if (b.recvTy()) |rt| roots[1] = rsplitLast(rt, '.');
    for (roots) |root_opt| {
        const root = root_opt orelse continue;
        // The class itself, then its transitive supertype names (nearest first).
        const supers: []const []const u8 = b.module.registry.class_super_names.get(root) orelse &.{};
        var i: usize = 0;
        while (i < 1 + supers.len) : (i += 1) {
            const cls = if (i == 0) root else supers[i - 1];
            const prefix = std.fmt.allocPrint(b.allocator, "{s}\x00{s}\x00", .{ cls, name }) catch return null;
            defer b.allocator.free(prefix);
            var found: ?FuncId = null;
            var found_arity: ?i16 = null;
            var found_recv: ?[]const u8 = null;
            var it = b.module.registry.member_method_fids.iterator();
            while (it.next()) |entry| {
                if (!std.mem.startsWith(u8, entry.key_ptr.*, prefix)) continue;
                const fid = entry.value_ptr.*;
                const f = b.module.funcById(fid) orelse continue;
                const hosts = memberHostsTrailingLambdaAtArity(b, cls, f, fid, user_arg_count);
                if (!hosts) continue;
                const last = f.params[f.params.len - 1];
                const arity = fnTypeArityAlias(b, last.ty) orelse continue;
                const recv = fnTypeReceiverHead(b, last.ty);
                if (found_arity) |fa| {
                    if (fa != arity or !optionalStringEql(found_recv, recv)) return null;
                } else {
                    found = fid;
                    found_arity = arity;
                    found_recv = recv;
                }
            }
            if (found) |fid| return fid;
        }
    }
    return null;
}

fn predeclaredMemberTrailingLambdaShape(b: *FuncBuilder, name: []const u8, user_arg_count: usize) ?ir.ModuleRegistry.MemberTrailingLambdaShape {
    if (user_arg_count >= 63) return null;
    const bit = @as(u64, 1) << @intCast(user_arg_count);
    var roots: [2]?[]const u8 = .{ b.ownerClass(), null };
    if (b.recvTy()) |rt| roots[1] = rsplitLast(rt, '.');
    for (roots) |root_opt| {
        const root = root_opt orelse continue;
        const supers: []const []const u8 = b.module.registry.class_super_names.get(root) orelse &.{};
        var i: usize = 0;
        while (i < 1 + supers.len) : (i += 1) {
            const cls = if (i == 0) root else supers[i - 1];
            const shapes = b.module.registry.member_trailing_lambda_shapes.get(.{ .a = cls, .b = name }) orelse continue;
            var agreed: ?ir.ModuleRegistry.MemberTrailingLambdaShape = null;
            for (shapes.items) |shape| {
                if (shape.accepted_arities & bit == 0) continue;
                if (agreed) |old| {
                    if (old.value_arity != shape.value_arity or
                        !optionalStringEql(old.receiver_head, shape.receiver_head)) return null;
                } else {
                    agreed = shape;
                }
            }
            if (agreed) |shape| return shape;
        }
    }
    return null;
}

fn optionalStringEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn memberParamHasDefault(b: *FuncBuilder, cls: []const u8, fid: FuncId, param_index: usize) bool {
    const f = b.module.funcById(fid) orelse return false;
    if (param_index < f.params.len and f.params[param_index].has_default) return true;
    if (b.module.registry.local_fn_defaults.get(fid)) |slots| {
        if (param_index < slots.items.len and slots.items[param_index] != null) return true;
    }
    if (b.module.registry.abstract_member_defaults.get(.{ .a = cls, .b = f.name })) |slots| {
        if (param_index < slots.items.len and slots.items[param_index] != null) return true;
    }
    const supers: []const []const u8 = b.module.registry.class_super_names.get(cls) orelse &.{};
    for (supers) |owner| {
        if (b.module.registry.abstract_member_defaults.get(.{ .a = owner, .b = f.name })) |slots| {
            if (param_index < slots.items.len and slots.items[param_index] != null) return true;
        }
    }
    return false;
}

fn memberHostsTrailingLambdaAtArity(b: *FuncBuilder, cls: []const u8, f: *const Func, fid: FuncId, user_arg_count: usize) bool {
    if (user_arg_count == 0 or f.params.len == 0) return false;
    const off: usize = if (std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
    const user_params = f.params.len - off;
    if (user_arg_count > user_params or user_params == 0) return false;
    const last = f.params[f.params.len - 1];
    if (last.is_vararg or fnTypeArityAlias(b, last.ty) == null) return false;
    // Positional arguments before a trailing lambda fill parameters from the
    // front. Every gap before the last parameter must therefore have a
    // declaration-site default, including one inherited from an expect or
    // abstract member by its concrete implementation.
    var pi = off + user_arg_count - 1;
    while (pi < f.params.len - 1) : (pi += 1) {
        if (!memberParamHasDefault(b, cls, fid, pi)) return false;
    }
    return true;
}

fn overloadHostingTrailingLambda(b: *FuncBuilder, name: []const u8, user_arg_count: usize) ?FuncId {
    const ohtl_trace = if (runtime.getenvSlice("KLIO_MISS_TRACE")) |w| std.mem.eql(u8, w, name) else false;
    const list = b.module.func_name_index.get(name) orelse {
        if (ohtl_trace) std.debug.print("[ohtl] {s}: no func_name_index entry\n", .{name});
        return memberHostingTrailingLambda(b, name, user_arg_count);
    };
    if (ohtl_trace) std.debug.print("[ohtl] {s}: {d} candidates argc={d}\n", .{ name, list.items.len, user_arg_count });
    // With several same-named overloads that all host a trailing lambda
    // (`SnapshotStateList.withCurrent(block: T.() -> R)` and
    // `StateRecord.withCurrent(block: (r: T) -> R)`), declaration order is not
    // evidence: the block's arity differs per overload (0 vs 1), and picking
    // the wrong one records the wrong arity, so a receiver-lambda argument
    // keeps a spurious `it` and its bare member reads fall through to globals.
    // Prefer the overload whose leading `this` matches the enclosing receiver
    // type; only fall back to declaration order when none matches.
    const recv_simple: ?[]const u8 = if (b.enclosingRecvTy()) |r| simpleTypeHead(r) else null;
    var fallback: ?FuncId = null;
    // A candidate whose body has not been attached yet still answers the
    // arity question — its SIGNATURE is what the lambda shape needs. A file
    // lowered before the file that declares its callee (a user file whose
    // package places it ahead of a pack's own sources) sees the callee
    // body-less at this point; skipping it left the trailing receiver-lambda
    // with a spurious implicit `it` bound to the invocation argument
    // (`launch(Dispatchers.Default) { it }` read the StandaloneCoroutine).
    // With-body candidates still outrank body-less ones: an `expect`
    // declaration shadowed by its actual keeps losing to the real one.
    var bodyless: ?FuncId = null;
    for (list.items) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        if (ohtl_trace) std.debug.print("[ohtl] {s}: cand #{d} params={d} body={} last_ty={s} last_arity={?d}\n", .{ name, fid.int(), f.params.len, f.hasBody(), if (f.params.len != 0) f.params[f.params.len - 1].ty.name else "-", if (f.params.len != 0) fnTypeArityAlias(b, f.params[f.params.len - 1].ty) else null });
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
        if (!f.hasBody()) {
            if (bodyless == null) bodyless = fid;
            continue;
        }
        // Receiver match wins outright; otherwise remember the first valid
        // candidate as the declaration-order fallback.
        if (recv_simple) |rs| {
            if (off == 1 and std.mem.eql(u8, simpleTypeHead(f.params[0].ty.name), rs))
                return fid;
        }
        if (fallback == null) fallback = fid;
    }
    if (fallback) |fid| return fid;
    // A member on the enclosing/receiver class outranks a SIGNATURE-ONLY
    // top-level namesake: at pack bake the StateRecord.withCurrent extension
    // is still body-less while SnapshotStateMap.mutate's call to its own
    // private withCurrent lowers, and letting the extension's (r: T) -> R
    // arity re-shape the member call's `{ this }` block made a fresh engine
    // pack return the outer map from every mutate (the get_field-map
    // family). A WITH-BODY top-level (the fallback above) still wins as
    // before.
    if (memberHostingTrailingLambda(b, name, user_arg_count)) |fid| return fid;
    if (bodyless) |fid| return fid;
    return null;
}

/// Whether any argument in the call is passed by name.
fn anyNamedArg(arg_names: []const ?[]const u8) bool {
    for (arg_names) |an| if (an != null) return true;
    return false;
}

/// Map each argument to the callee parameter it fills, honoring Kotlin's
/// named-argument rules: a named argument matches the parameter of that name; an
/// unnamed trailing lambda binds the last parameter; the remaining unnamed
/// (positional) arguments fill the still-unassigned parameters left to right.
/// `params` is the callee's parameter slice with any receiver already removed.
/// Returns a per-argument target index (parallel to `args`), null for an
/// argument whose parameter can't be determined. Caller frees the slice.
fn mapArgsToParams(
    b: *FuncBuilder,
    params: []const ir.Param,
    args: []const Expr,
    arg_names: []const ?[]const u8,
) Allocator.Error!?[]?usize {
    const out = try b.allocator.alloc(?usize, args.len);
    for (out) |*o| o.* = null;
    const used = try b.allocator.alloc(bool, params.len);
    defer b.allocator.free(used);
    for (used) |*u| u.* = false;
    // 1. Named arguments bind their same-named parameter.
    for (args, 0..) |_, j| {
        const an = if (j < arg_names.len) arg_names[j] else null;
        if (an) |name| {
            for (params, 0..) |p, idx| {
                if (std.mem.eql(u8, p.name, name)) {
                    out[j] = idx;
                    used[idx] = true;
                    break;
                }
            }
        }
    }
    // 2. An unnamed trailing lambda binds the last (still-free) parameter.
    var trailing_done = false;
    if (args.len != 0) {
        const last = args.len - 1;
        const last_named = last < arg_names.len and arg_names[last] != null;
        const last_lambda = args[last] == .Lambda or args[last] == .AnonFun;
        if (!last_named and last_lambda and params.len != 0 and !used[params.len - 1]) {
            out[last] = params.len - 1;
            used[params.len - 1] = true;
            trailing_done = true;
        }
    }
    // 3. Remaining unnamed arguments fill the free parameters front to back.
    var pidx: usize = 0;
    for (args, 0..) |_, j| {
        const an = if (j < arg_names.len) arg_names[j] else null;
        if (an != null) continue;
        if (trailing_done and j == args.len - 1) continue;
        while (pidx < params.len and used[pidx]) pidx += 1;
        if (pidx < params.len) {
            out[j] = pidx;
            if (!params[pidx].is_vararg) {
                used[pidx] = true;
                pidx += 1;
            }
        }
    }
    return out;
}

fn argFnArities(b: *FuncBuilder, func: *const Func, args: []const Expr, arg_names: []const ?[]const u8, recv_offset: usize) Allocator.Error!?[]i16 {
    if (args.len == 0) return null;
    for (args) |*a| if (a.* == .Spread) return null;
    if (func.params.len < recv_offset) return null;
    const params = func.params[recv_offset..];
    const out = try b.allocator.alloc(i16, args.len);
    for (out) |*o| o.* = -1;
    // Named arguments: resolve each lambda's expected arity through its target
    // parameter (by name) so a receiver lambda passed by name is still detected
    // as arity-0 — otherwise it is mistaken for an `it`-lambda and its bare
    // member accesses fall through to unresolved globals.
    if (anyNamedArg(arg_names)) {
        const map = (try mapArgsToParams(b, params, args, arg_names)) orelse {
            b.allocator.free(out);
            return null;
        };
        defer b.allocator.free(map);
        for (out, map) |*o, m| {
            if (m) |pi| o.* = fnTypeArityAlias(b, params[pi].ty) orelse -1;
        }
        return out;
    }
    // A trailing lambda fills the last function-typed parameter even when
    // earlier defaulted parameters are omitted; align the trailing lambda
    // with the last parameter and the leading args from the front.
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
        b.allocator.free(out);
        return null;
    }
    return out;
}

/// The declared receiver-type head of a receiver-lambda parameter type
/// (`MockViewValidator.() -> Unit`), or null when the type is not a direct
/// receiver function. The lowered encoding is
/// `[#suspend?] [receiver?] params(n) ret(1) [#markers]`; a receiver is present
/// when the non-marker, non-suspend arg count is `n + 2`.
fn fnTypeReceiver(b: *FuncBuilder, ty: ir.TypeRef) ?ir.TypeRef {
    if (!std.mem.startsWith(u8, ty.name, "Function")) return null;
    const arity = fnTypeArityAlias(b, ty) orelse return null;
    const n: usize = if (arity < 0) 0 else @intCast(arity);
    var hi: usize = ty.args.len;
    while (hi > 0 and ty.args[hi - 1].name.len != 0 and ty.args[hi - 1].name[0] == '#') hi -= 1;
    var lo: usize = 0;
    if (lo < hi and std.mem.eql(u8, ty.args[lo].name, "#suspend")) lo += 1;
    const remaining = hi - lo; // [receiver?] params(n) ret(1)
    if (remaining == n + 2 and lo < hi) {
        const receiver = ty.args[lo];
        if (receiver.name.len != 0 and receiver.name[0] != '#') return receiver;
    }
    return null;
}

fn fnTypeReceiverHead(b: *FuncBuilder, ty: ir.TypeRef) ?[]const u8 {
    return if (fnTypeReceiver(b, ty)) |receiver| receiver.name else null;
}

fn funcDeclaresTypeParam(b: *const FuncBuilder, func: *const Func, name: []const u8) bool {
    const params = b.module.registry.func_type_params.get(func.id) orelse return false;
    for (params.items) |param| {
        if (std.mem.eql(u8, param, name)) return true;
    }
    return false;
}

/// Substitute a receiver-function parameter's direct function type parameter
/// from authoritative call-argument evidence. This is the common
/// `with(receiver, block: T.() -> R)` shape: the block's implicit receiver is
/// the static type of `receiver`, not the unbound declaration name `T`.
fn callBoundLambdaReceiverType(
    b: *FuncBuilder,
    func: *const Func,
    declared_receiver: ir.TypeRef,
    params: []const ir.Param,
    args: []const Expr,
    arg_names: []const ?[]const u8,
    type_args: []const ast.TypeRef,
) Allocator.Error!ir.TypeRef {
    const head = declared_receiver.name;
    if (!funcDeclaresTypeParam(b, func, head)) {
        return declared_receiver.clone(b.allocator);
    }
    if (b.module.registry.func_type_params.get(func.id)) |declared_params| {
        for (declared_params.items, 0..) |param, index| {
            if (!std.mem.eql(u8, param, head)) continue;
            if (index < type_args.len) {
                return loweredOwnedLocalTypeRef(b, &type_args[index]);
            }
            break;
        }
    }

    var mapping: ?[]const ?usize = null;
    defer if (mapping) |items| b.allocator.free(items);
    if (anyNamedArg(arg_names)) {
        mapping = try mapArgsToParams(b, params, args, arg_names);
        if (mapping == null) return declared_receiver.clone(b.allocator);
    }

    const trailing_lambda = args.len != 0 and
        (args[args.len - 1] == .Lambda or args[args.len - 1] == .AnonFun);
    var bound: ?ir.TypeRef = null;
    for (args, 0..) |*arg, i| {
        if (arg.* == .Lambda or arg.* == .AnonFun or arg.* == .Spread) continue;
        const param_index: ?usize = if (mapping) |items|
            items[i]
        else if (trailing_lambda and i + 1 == args.len and args.len <= params.len)
            params.len - 1
        else if (i < params.len)
            i
        else
            null;
        const pi = param_index orelse continue;
        if (pi >= params.len) continue;
        const param_ty = params[pi].ty;
        if (param_ty.nullable or param_ty.args.len != 0 or
            !std.mem.eql(u8, param_ty.name, head)) continue;
        const actual = argDeclTypeRefLazy(b, arg) orelse continue;
        if (b.isTypeParam(actual.name)) continue;
        if (bound) |existing| {
            if (!existing.eql(actual)) return declared_receiver.clone(b.allocator);
        } else {
            bound = actual;
        }
    }
    return if (bound) |actual|
        actual.clone(b.allocator)
    else
        declared_receiver.clone(b.allocator);
}

fn recordCallBoundLambdaReceiver(
    b: *FuncBuilder,
    func: *const Func,
    call_span: ast.Span,
    declared_receiver: ir.TypeRef,
    params: []const ir.Param,
    args: []const Expr,
    arg_names: []const ?[]const u8,
    type_args: []const ast.TypeRef,
) Allocator.Error!void {
    const resolved = try callBoundLambdaReceiverType(
        b,
        func,
        declared_receiver,
        params,
        args,
        arg_names,
        type_args,
    );
    if (resolved.eql(declared_receiver) and
        funcDeclaresTypeParam(b, func, declared_receiver.name) and
        b.lambdaArgRecv(call_span) != null)
    {
        var cleanup = resolved;
        cleanup.deinit(b.allocator);
        return;
    }
    try b.recordLambdaArgRecvOwned(call_span, resolved);
}

/// Record the receiver-type head of each receiver-lambda ARGUMENT so its body
/// owns that receiver even when the call is deferred and no expected type
/// reaches `lowerLambda`. Mirrors `argFnArities`' arg→param alignment.
fn recordLambdaArgReceivers(
    b: *FuncBuilder,
    func: *const Func,
    args: []const Expr,
    arg_names: []const ?[]const u8,
    type_args: []const ast.TypeRef,
    recv_offset: usize,
) Allocator.Error!void {
    if (args.len == 0 or func.params.len < recv_offset) return;
    for (args) |*a| if (a.* == .Spread) return;
    const params = func.params[recv_offset..];
    if (anyNamedArg(arg_names)) {
        const map = (try mapArgsToParams(b, params, args, arg_names)) orelse return;
        defer b.allocator.free(map);
        for (args, map) |*a, m| {
            if (a.* != .Lambda and a.* != .AnonFun) continue;
            if (m) |pi| if (pi < params.len) {
                if (fnTypeReceiver(b, params[pi].ty)) |receiver| {
                    try recordCallBoundLambdaReceiver(b, func, a.span(), receiver, params, args, arg_names, type_args);
                }
            };
        }
        return;
    }
    const trailing_lambda = args[args.len - 1] == .Lambda or args[args.len - 1] == .AnonFun;
    if (trailing_lambda and args.len <= params.len) {
        var i: usize = 0;
        while (i + 1 < args.len) : (i += 1) {
            if ((args[i] == .Lambda or args[i] == .AnonFun)) {
                if (fnTypeReceiver(b, params[i].ty)) |receiver| {
                    try recordCallBoundLambdaReceiver(b, func, args[i].span(), receiver, params, args, arg_names, type_args);
                }
            }
        }
        if (fnTypeReceiver(b, params[params.len - 1].ty)) |receiver| {
            try recordCallBoundLambdaReceiver(
                b,
                func,
                args[args.len - 1].span(),
                receiver,
                params,
                args,
                arg_names,
                type_args,
            );
        }
    } else if (args.len == params.len) {
        for (args, params) |*a, p| {
            if (a.* != .Lambda and a.* != .AnonFun) continue;
            if (fnTypeReceiver(b, p.ty)) |receiver| {
                try recordCallBoundLambdaReceiver(b, func, a.span(), receiver, params, args, arg_names, type_args);
            }
        }
    }
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

fn instantiatedLambdaValueParams(
    b: *FuncBuilder,
    func: *const Func,
    fn_ty: ir.TypeRef,
    type_args: []const ast.TypeRef,
) Allocator.Error!?[]ir.TypeRef {
    const arity = fnTypeArityAlias(b, fn_ty) orelse return null;
    if (arity <= 0) return null;
    const n: usize = @intCast(arity);

    const explicit = try b.allocator.alloc(ir.TypeRef, type_args.len);
    defer {
        for (explicit) |*ty| ty.deinit(b.allocator);
        b.allocator.free(explicit);
    }
    for (type_args, explicit) |*src, *dst| {
        dst.* = try loweredOwnedLocalTypeRef(b, src);
    }
    var instantiated = (try b.module.instantiatedDeclarationType(
        b.allocator,
        func.id,
        fn_ty,
        explicit,
    )) orelse return null;
    defer instantiated.deinit(b.allocator);

    var hi = instantiated.args.len;
    while (hi > 0 and instantiated.args[hi - 1].name.len != 0 and
        instantiated.args[hi - 1].name[0] == '#') hi -= 1;
    var lo: usize = 0;
    if (lo < hi and std.mem.eql(u8, instantiated.args[lo].name, "#suspend")) lo += 1;
    const remaining = hi - lo;
    const start = if (remaining == n + 2)
        lo + 1
    else if (remaining == n + 1)
        lo
    else
        return null;

    const out = try b.allocator.alloc(ir.TypeRef, n);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |*ty| ty.deinit(b.allocator);
        b.allocator.free(out);
    }
    for (out, instantiated.args[start .. start + n]) |*dst, src| {
        dst.* = try src.clone(b.allocator);
        initialized += 1;
    }
    return out;
}

fn deinitArgLambdaParamTypes(
    allocator: Allocator,
    types: []?[]ir.TypeRef,
) void {
    for (types) |maybe_params| {
        if (maybe_params) |params| {
            for (params) |*ty| ty.deinit(allocator);
            allocator.free(params);
        }
    }
    allocator.free(types);
}

/// Instantiated expected value-parameter types for each lambda argument,
/// aligned through the same positional/named/trailing-lambda map as arity.
fn argLambdaParamTypes(
    b: *FuncBuilder,
    func: *const Func,
    args: []const Expr,
    arg_names: []const ?[]const u8,
    type_args: []const ast.TypeRef,
    recv_offset: usize,
) Allocator.Error!?[]?[]ir.TypeRef {
    if (args.len == 0 or func.params.len < recv_offset) return null;
    for (args) |*arg| if (arg.* == .Spread) return null;
    const params = func.params[recv_offset..];
    const out = try b.allocator.alloc(?[]ir.TypeRef, args.len);
    for (out) |*slot| slot.* = null;
    errdefer deinitArgLambdaParamTypes(b.allocator, out);
    var any = false;

    if (anyNamedArg(arg_names)) {
        const mapping = (try mapArgsToParams(b, params, args, arg_names)) orelse {
            b.allocator.free(out);
            return null;
        };
        defer b.allocator.free(mapping);
        for (args, mapping, out) |*arg, mapped, *slot| {
            if (arg.* != .Lambda and arg.* != .AnonFun) continue;
            const pi = mapped orelse continue;
            slot.* = try instantiatedLambdaValueParams(b, func, params[pi].ty, type_args);
            any = any or slot.* != null;
        }
    } else {
        const trailing_lambda = args[args.len - 1] == .Lambda or
            args[args.len - 1] == .AnonFun;
        for (args, out, 0..) |*arg, *slot, i| {
            if (arg.* != .Lambda and arg.* != .AnonFun) continue;
            const pi: ?usize = if (trailing_lambda and i + 1 == args.len and
                args.len <= params.len)
                params.len - 1
            else if (i < params.len)
                i
            else
                null;
            if (pi) |param_index| {
                slot.* = try instantiatedLambdaValueParams(
                    b,
                    func,
                    params[param_index].ty,
                    type_args,
                );
                any = any or slot.* != null;
            }
        }
    }
    if (!any) {
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
            // Safe-target postfix (`parent?.count++`): the receiver
            // evaluates ONCE and a null receiver skips the whole
            // get/inc/store (Kotlin's `?.` short-circuit) — running the
            // unguarded sequence incremented `null` at the chain's root.
            if (inner.* == .Member and inner.Member.safe) {
                const m = inner.Member;
                const recv = try lowerReceiver(b, m.receiver);
                const null_r = try b.emitConst(.Null);
                const is_null = b.allocReg();
                try b.push(.{ .BinOp = .{ .dst = is_null, .op = .Eq, .lhs = recv, .rhs = null_r } });
                const then_b = try b.allocBlock();
                const else_b = try b.allocBlock();
                const join = try b.allocBlock();
                const old = b.allocReg();
                b.terminate(.{ .Branch = .{ .cond = is_null, .t = then_b, .f = else_b } });
                b.switchTo(then_b);
                const n0 = try b.emitConst(.Null);
                try b.push(.{ .Move = .{ .dst = old, .src = n0 } });
                b.terminate(.{ .Goto = join });
                b.switchTo(else_b);
                const field = try b.module.internConst(b.allocator, .{ .String = m.name.name });
                const got = b.allocReg();
                try b.push(.{ .GetField = .{ .dst = got, .receiver = recv, .field = field } });
                const new = b.allocReg();
                try b.push(.{ .UnOp = .{ .dst = new, .op = uo, .operand = got } });
                try b.push(.{ .SetField = .{ .receiver = recv, .field = field, .value = new } });
                try b.push(.{ .Move = .{ .dst = old, .src = got } });
                b.terminate(.{ .Goto = join });
                b.switchTo(join);
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
    // Sibling-arg expected type: `assertEquals(EmptyEnum.entries,
    // enumEntries())` — a sibling argument bound to the same declared type
    // variable statically names an enum, which solves the nested reified
    // call's expected type. Recorded per-arg-node; the arg-lowering loops
    // surface it as THAT argument's expected type so the nested inline
    // splice's return-type unification (the existing reified oracle)
    // stamps the type argument.
    const sib_prev_site = b.sib_expected_site;
    const sib_prev_ty = b.sib_expected_ty;
    if (solveSiblingExpected(b, expr.Call.callee, expr.Call.args)) |solved| {
        b.sib_expected_site = @ptrCast(solved.site);
        b.sib_expected_ty = solved.ty;
    }
    defer {
        b.sib_expected_site = sib_prev_site;
        b.sib_expected_ty = sib_prev_ty;
    }
    const call = expr.Call;
    const prev_trailing = b.setCallTrailingLambda(call.has_trailing_lambda);
    defer _ = b.setCallTrailingLambda(prev_trailing);
    // `dep!!()` calls the value a not-null-asserted BARE NAME holds: keep
    // the bare-name call machinery (member-vs-global walk, and with it the
    // receiver-function-typed property arm) by unwrapping the assertion at
    // the callee — a null value still fails at the invoke, matching the
    // assertion's intent.
    const callee = blk: {
        var c = call.callee;
        while (c.* == .Postfix and c.Postfix.op == .NotNull and
            (c.Postfix.expr.* == .Path or c.Postfix.expr.* == .Member))
        {
            c = c.Postfix.expr;
        }
        break :blk c;
    };
    const prev_call_label = b.current_call_label;
    b.current_call_label = helpers.calleeLabel(callee);
    defer b.current_call_label = prev_call_label;
    const args = call.args;
    const ast_arg_names = call.arg_names;
    const ast_type_args = call.type_args;
    const is_infix = call.is_infix;
    // Record each lambda argument's expected value-parameter arity by span,
    // taken from the resolved callee's parameter types, BEFORE the args are
    // lowered. `lowerLambda` reads it authoritatively, so a receiver lambda
    // (`T.() -> R`, arity 0) drops its `it` no matter which emit branch lowers
    // the argument — the per-arg `pending_lambda_arity` is set only on some
    // paths, which is why a non-trailing receiver-lambda argument otherwise
    // stays an `it`-lambda and its bare member calls fall through to globals.
    if (callee.* == .Path and callee.Path.segments.len == 1) {
        const cnm = callee.Path.segments[0].name;
        // Only when the callee name is UNAMBIGUOUS (a single same-named
        // function): the arity then definitely matches the resolved overload.
        // With overloads, `funcId` is a heuristic that may name the wrong one,
        // whose arity would wrongly drop a needed `it`.
        const unambiguous = if (b.module.func_name_index.get(cnm)) |ids| ids.items.len == 1 else false;
        const chosen: ?FuncId = if (unambiguous)
            b.module.funcId(cnm)
        else
            // Ambiguous name (`withCurrent` has a `SnapshotStateList.() ->` and a
            // `StateRecord.() ->` overload): disambiguate by the enclosing
            // receiver type so a receiver-lambda argument's arity (0) is still
            // recorded and its `it` dropped — otherwise its bare member reads
            // fall through to globals.
            disambiguateByReceiver(b, cnm);
        if (chosen) |fid| {
            if (b.module.funcById(fid)) |f| {
                const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
                const arr = try argFnArities(b, f, args, ast_arg_names, recv_off);
                if (arr) |ar| {
                    defer b.allocator.free(ar);
                    for (args, 0..) |*a, i| {
                        if ((a.* == .Lambda or a.* == .AnonFun) and i < ar.len and ar[i] >= 0) {
                            b.recordLambdaArgArity(a.span(), ar[i]);
                        }
                    }
                }
                try recordLambdaArgReceivers(b, f, args, ast_arg_names, ast_type_args, recv_off);
            }
        } else if (args.len != 0 and (args[args.len - 1] == .Lambda or args[args.len - 1] == .AnonFun)) {
            // Ambiguous name, no receiver disambiguation: when EVERY overload
            // declares the SAME receiver head for its trailing function-typed
            // parameter (`runTest`'s block is `TestScope.() -> Unit` in every
            // overload), that head is safe to record — `this + dispatcher`
            // inside the lambda then dispatches against the static type.
            if (b.module.func_name_index.get(cnm)) |ids| {
                var common: ?ir.TypeRef = null;
                defer if (common) |receiver| {
                    var cleanup = receiver;
                    cleanup.deinit(b.allocator);
                };
                var ok = ids.items.len >= 2;
                for (ids.items) |fid2| {
                    const f2 = b.module.funcById(fid2) orelse {
                        ok = false;
                        break;
                    };
                    if (f2.params.len == 0) {
                        ok = false;
                        break;
                    }
                    const declared_receiver = fnTypeReceiver(b, f2.params[f2.params.len - 1].ty) orelse {
                        ok = false;
                        break;
                    };
                    const recv_off: usize = if (std.mem.eql(u8, f2.params[0].name, "this")) 1 else 0;
                    var bound_receiver = try callBoundLambdaReceiverType(
                        b,
                        f2,
                        declared_receiver,
                        f2.params[recv_off..],
                        args,
                        ast_arg_names,
                        ast_type_args,
                    );
                    if (common) |c0| {
                        if (!c0.eql(bound_receiver)) {
                            bound_receiver.deinit(b.allocator);
                            ok = false;
                            break;
                        }
                        bound_receiver.deinit(b.allocator);
                    } else common = bound_receiver;
                }
                if (ok) {
                    if (common) |receiver| {
                        common = null;
                        try b.recordLambdaArgRecvOwned(args[args.len - 1].span(), receiver);
                    }
                }
            }
        }
    }

    // Context parameters: the stdlib `context(v..., block)` scope function
    // and `contextOf<T>()` accessor lower to dedicated context-stack ops so
    // implicit resolution is driven by the runtime stack, not overload
    // resolution. Only when the name is not shadowed by a local/outer.
    if (!is_infix and callee.* == .Path and callee.Path.segments.len == 1) {
        const cname = callee.Path.segments[0].name;
        if (b.resolve(cname) == null and !b.knowsOuter(cname)) {
            if (std.mem.eql(u8, cname, "contextOf") and args.len == 0 and ast_type_args.len == 1) {
                b.module.has_context_decls = true;
                const dst = b.allocReg();
                const ty_const = try b.module.internConst(b.allocator, .{ .String = ast_type_args[0].name.name });
                try b.push(.{ .CtxLoad = .{ .dst = dst, .ty = ty_const, .erased = false } });
                return dst;
            }
            if (std.mem.eql(u8, cname, "context") and args.len >= 2 and lastArgIsLambda(args)) {
                b.module.has_context_decls = true;
                const run = try lowerArgRun(b, args);
                const n_ctx: u32 = @intCast(args.len - 1);
                const block_reg = Reg.from(run[0].int() + n_ctx);
                const dst = b.allocReg();
                try b.push(.{ .CtxScope = .{
                    .dst = dst,
                    .ctx_args = run[0],
                    .n_ctx = n_ctx,
                    .block = block_reg,
                } });
                return dst;
            }
        }
    }

    // Fully-positional call of a contextual function-type value:
    // `f(c0, c1, a0)` where `f: context(C0, C1) (A0) -> R`. When the arg
    // count matches the flattened `n_ctx + n_regular`, split the leading
    // context args onto the context stack (`CtxCall`); the implicit form
    // `f(a0)` (contexts from scope) has only `n_regular` args and falls
    // through to the ordinary value-call path.
    if (!is_infix and callee.* == .Path and callee.Path.segments.len == 1 and ast_type_args.len == 0) {
        const cname = callee.Path.segments[0].name;
        if (b.contextFnParam(cname)) |shape| {
            if (b.resolve(cname)) |callee_reg| {
                if (args.len == shape.n_ctx + shape.n_regular and !lastArgIsLambda(args)) {
                    b.module.has_context_decls = true;
                    const run = try lowerArgRun(b, args);
                    const dst = b.allocReg();
                    try b.push(.{ .CtxCall = .{
                        .dst = dst,
                        .callee = callee_reg,
                        .args = run[0],
                        .n_args = run[1],
                        .n_ctx = @intCast(shape.n_ctx),
                    } });
                    return dst;
                }
            }
        }
    }

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

    // A bare call to a file-private top-level function mangled per file (two
    // files in one package each declaring the same-signature `private fun`)
    // resolves to the calling file's mangled name. Locals / outer captures /
    // own members still shadow it (Kotlin scope order). An applicable
    // EXTENSION on an in-scope implicit receiver also shadows it: Kotlin
    // resolves the implicit-receiver candidate group before any no-receiver
    // candidate, so `Text(…)` inside `fun MockViewValidator.value()` binds
    // the validator extension, never the file's private plain fn.
    if (callee.* == .Path and callee.Path.segments.len == 1) {
        const head = callee.Path.segments[0];
        if (build.filePrivateFuncRename(head.name, head.span.file.int())) |renamed| {
            if (b.resolve(head.name) == null and !b.knowsOuter(head.name) and !b.hasOwnMember(head.name) and
                !extOnEnclosingReceiverApplies(b, head.name, call.args.len))
            {
                var new_segs = [_]ast.Ident{.{ .name = renamed, .span = head.span }};
                var new_callee = Expr{ .Path = .{ .segments = &new_segs, .span = callee.Path.span } };
                var rewritten = expr.*;
                rewritten.Call.callee = &new_callee;
                return lowerCall(b, &rewritten);
            }
        }
    }

    // A bare call to a companion member imported by name
    // (`import X.Companion.member` then `member(args)`) dispatches on X's
    // companion: rewrite the callee to the qualified `X.member` the same way a
    // bare companion-imported name expression is rewritten, so the call reaches
    // the companion method instead of an unresolved global. A local / captured /
    // own-member binding of the name shadows the import (Kotlin scope order).
    if (callee.* == .Path and callee.Path.segments.len == 1) {
        const head = callee.Path.segments[0];
        if (b.resolve(head.name) == null and !b.knowsOuter(head.name) and !b.hasOwnMember(head.name)) {
            if (importCompanionRewrite(b, head.span.file, head.name)) |rw| {
                const sp = head.span;
                const recv_segs = try b.allocator.alloc(ast.Ident, rw.segs.len - 1);
                for (rw.segs[0 .. rw.segs.len - 1], 0..) |s, k| recv_segs[k] = .{ .name = s, .span = sp };
                var recv = Expr{ .Path = .{ .segments = recv_segs, .span = sp } };
                var new_callee = Expr{ .Member = .{
                    .receiver = &recv,
                    .name = .{ .name = rw.segs[rw.segs.len - 1], .span = sp },
                    .safe = false,
                    .span = callee.Path.span,
                } };
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
        // Statement position with no type args: splice anyway when the value
        // arguments alone bind every reified parameter (a generic-class
        // argument like `Nodes.Draw : NodeKind<DrawModifierNode>`), so the
        // spliced `is T` checks the real class — runtime dispatch of the
        // inline body would read a stale/unbound `T`.
        if (inline_call.argsBindAllReified(b.allocator, callee.Member.name.name, args, b)) break :gate true;
        const recv = callee.Member.receiver;
        if (recv.* != .Path or recv.Path.segments.len != 1) break :gate false;
        const n = recv.Path.segments[0].name;
        if (b.resolve(n) != null or b.knowsOuter(n)) break :gate false;
        break :gate b.module.registry.companion_singletons.contains(n);
    }) {
        const mname = callee.Member.name.name;
        if (runtime.getenvSlice("KLIO_SAM_TRACE") != null) std.debug.print("[marm] {s} cands={d}\n", .{ mname, if (inline_state.candidatesForName(mname)) |c| c.len else 0 });
        const reified_ext = blk: {
            if (inlineFnAst(mname)) |f| {
                if (f.receiver_type != null and anyReified(f.type_params)) break :blk true;
            }
            // A reified MEMBER-inline fn is invisible to the top-level
            // stub index: a qualified call (`CC(e, a).pfw<E> { … }`) must
            // still splice, or the reified parameter dies at runtime.
            if (inline_state.candidatesForName(mname)) |cands| {
                for (cands) |cf| {
                    if (anyReified(cf.type_params) and cf.receiver_type == null and
                        inline_state.inlineMemberOwner(cf) != null)
                    {
                        break :blk true;
                    }
                }
            }
            break :blk false;
        };
        if (reified_ext and !b.inlineInProgress(mname)) {
            const receiver = callee.Member.receiver;
            const expected = b.peekExpected();
            const exp_ptr: ?*const ast.TypeRef = if (expected) |*_e| _e else null;
            // A member-inline overload set is invisible to the stub index
            // the general resolution consults, and its receiver-blind
            // shape pick cannot tell `visitNodes(mask: Int, block)` from
            // the reified `visitNodes(type: NodeKind<T>, block)`. Pick
            // here: the reified candidate whose type parameters the call
            // can actually bind (explicit `<…>`, or inference from the
            // value arguments) wins; otherwise leave the resolution to
            // the general path.
            var member_target: ?*const ast.Function = null;
            if (ast_type_args.len != 0) {
                if (inline_state.candidatesForName(mname)) |cands| {
                    for (cands) |cf| {
                        if (cf.receiver_type != null or inline_state.inlineMemberOwner(cf) == null) continue;
                        if (!anyReified(cf.type_params)) continue;
                        if (!try memberOwnerOnReceiverChain(b, receiver, cf)) continue;
                        member_target = cf;
                        break;
                    }
                }
            }
            if (ast_type_args.len == 0) blk_mit: {
                const cands = inline_state.candidatesForName(mname) orelse break :blk_mit;
                // Inference-bound reified MEMBER-inline call: the splice's
                // runtime-enclosing parity is not established, so dispatch
                // it as a statically-bound TYPED member call instead — the
                // lowered instance method runs framed with its reified
                // parameters bound from the inferred type-argument names
                // (`c.visitNodes(Kinds.OnRe) { … }` binds `T = Lw`).
                for (cands) |cf| {
                    if (cf.receiver_type != null or inline_state.inlineMemberOwner(cf) == null) continue;
                    if (!anyReified(cf.type_params)) continue;
                    if (!try memberOwnerOnReceiverChain(b, receiver, cf)) continue;
                    const names = inline_call.inferReifiedNamesForCall(b, cf, args, ast_arg_names, callee.Member.name.span.file.int()) orelse {
                        if (runtime.getenvSlice("KLIO_SAM_TRACE") != null) std.debug.print("[marm] {s}: names=null\n", .{mname});
                        continue;
                    };
                    const fid = blk: {
                        for (b.module.funcsBySimpleName(mname)) |cand_fid| {
                            const ds = b.module.decl_span.get(cand_fid.int()) orelse continue;
                            if (ds.file.int() == cf.name.span.file.int() and ds.start == cf.name.span.start) {
                                break :blk cand_fid;
                            }
                        }
                        // Instance methods are not in the simple-name index;
                        // match by declaration span over the full table.
                        // User-file instance methods carry no decl-span
                        // record; identify the overload by its declared
                        // parameter-name sequence (`type, block` vs
                        // `mask, block`) behind the implicit `this`.
                        for (b.module.funcs.items) |*mf| {
                            if (!std.mem.eql(u8, mf.name, mname)) continue;
                            if (mf.kind != .instance_method) continue;
                            if (mf.params.len != cf.params.len + 1) continue;
                            var all_match = mf.params.len > 0 and std.mem.eql(u8, mf.params[0].name, "this");
                            if (all_match) {
                                for (cf.params, 0..) |*cp, pi| {
                                    if (!std.mem.eql(u8, mf.params[pi + 1].name, cp.name.name)) {
                                        all_match = false;
                                        break;
                                    }
                                }
                            }
                            if (all_match) break :blk mf.id;
                        }
                        break :blk null;
                    } orelse {
                        if (runtime.getenvSlice("KLIO_SAM_TRACE") != null) std.debug.print("[marm] {s}: fid=null\n", .{mname});
                        continue;
                    };
                    const recv = try lowerReceiver(b, receiver);
                    const run = try lowerArgRun(b, args);
                    const arg_names_c = try internArgNames(b.allocator, b.module, ast_arg_names);
                    var ta_ids = try b.allocator.alloc(ir.ConstId, names.len);
                    for (names, 0..) |n, i| ta_ids[i] = try b.module.internConst(b.allocator, .{ .String = n });
                    const nm = try b.module.internConst(b.allocator, .{ .String = mname });
                    const dst = b.allocReg();
                    orEmitAudit(b, "member_inline_typed", "CallMemberOrGlobal", mname);
                    try b.push(.{ .CallMemberOrGlobal = .{
                        .dst = dst,
                        .this_idx = 0,
                        .name = nm,
                        .trailing_lambda = b.callTrailingLambda(),
                        .args = run[0],
                        .n_args = run[1],
                        .arg_names = arg_names_c,
                        .recv = recv,
                        .func = fid,
                        .candidates = try cmgCandidates(b, mname, callee.Member.name.span.file, run[1]),
                        .type_args = ta_ids,
                    } });
                    return dst;
                }
            }
            if (try tryInlineCallWithTypeArgs(b, mname, member_target, args, ast_arg_names, receiver, ast_type_args, exp_ptr)) |r| {
                return r;
            }
            // Splice bailed: fall back to a plain member dispatch.
            const recv = try lowerReceiver(b, receiver);
            const bail_arity: ?[]const i16 = try memberCallArgArities(b, receiver, mname, args, ast_arg_names);
            const run = try lowerArgRunWithArity(b, args, bail_arity);
            const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
            const nm = try b.module.internConst(b.allocator, .{ .String = mname });
            const dst = b.allocReg();
            try b.push(.{ .CallMember = .{
                .dst = dst,
                .receiver = recv,
                .name = nm,
                .trailing_lambda = b.callTrailingLambda(),
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
            .trailing_lambda = b.callTrailingLambda(),
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
        if (callee.* == .Member and !callee.Member.safe) {
            const member = callee.Member;
            if (try lowerResolvedMemberCall(
                b,
                member.receiver,
                member.name,
                args,
                ast_arg_names,
                ast_type_args,
                argDeclTypeRef(b, member.receiver),
            )) |reg| return reg;
        }
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
        "listOf",      "mutableListOf", "emptyList", "arrayListOf",
        "setOf",       "mutableSetOf",  "emptySet",  "hashSetOf",
        "linkedSetOf", "sortedSetOf",   "arrayOf",   "emptyArray",
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
        "Int",        "Long",     "Short",       "Byte",       "UInt",       "ULong",
        "UShort",     "UByte",    "Double",      "Float",      "Boolean",    "Char",
        "String",     "Any",      "Number",      "Unit",       "CharObject", "List",
        "Set",        "Map",      "MutableList", "MutableSet", "MutableMap", "Array",
        "Collection", "Iterable", "Sequence",    "Pair",       "Triple",
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
    const uarg_arity: ?[]const i16 = try memberCallArgArities(b, receiver, name.name, args, ast_arg_names);
    const arg_regs = try b.allocator.alloc(Reg, args.len);
    defer b.allocator.free(arg_regs);
    for (args, arg_regs, 0..) |*a, *ar, i| {
        if (uarg_arity) |ar_list| {
            if (i < ar_list.len) b.pending_lambda_arity = ar_list[i];
        }
        ar.* = try lowerExpr(b, a);
        b.pending_lambda_arity = -1;
    }
    const args_start = try packContiguous(b, arg_regs);
    const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
    const dst = b.allocReg();
    const nm = try b.module.internConst(b.allocator, .{ .String = name.name });
    try b.push(.{ .CallMember = .{
        .dst = dst,
        .receiver = recv,
        .name = nm,
        .trailing_lambda = b.callTrailingLambda(),
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
        // A DEFERRED resolution must never statically bind a low-priority
        // heuristic. `@LowPriorityInOverloadResolution` / deprecated stubs are
        // outranked by a same-name class constructor and by any ordinary
        // overload; the index defers (e.g. `default_param_shape` when the
        // constructor carries defaults, or `low_priority_only`) precisely
        // because runtime must decide. Binding the stub statically makes a
        // stub whose body re-calls the name self-recurse (kotlinx-datetime's
        // `fun LocalDateTime`). Leave unbound so a dynamic `CallMemberOrGlobal`
        // resolves the constructor / intended overload.
        if (bound_id) |bid| {
            if (ires.pick() == null) {
                const same_class = b.module.classId(segments[0].name) != null;
                if (b.module.funcById(bid)) |bf| {
                    // A low-priority stub is outranked by the constructor and by
                    // any ordinary overload. A same-named class constructor is
                    // part of the overload set too: when the index defers and a
                    // class exists, never let a factory function bind statically
                    // (a `vararg` factory would otherwise absorb the args a
                    // constructor should take, e.g. `ByteString(bytes, 0, n)`
                    // binding `fun ByteString(vararg Byte)`). Leave it for the
                    // runtime `CallMemberOrGlobal`, which scores the constructor.
                    if (bf.low_priority or same_class) bound_id = null;
                }
            }
        }
        // A trailing-lambda call must bind an overload whose last parameter is
        // function-typed. The bare-call index can pick a same-named sibling
        // (`group(metadata: LongArray, offset: Int)`) that cannot host the
        // lambda; when the trailing lambda mutates an outer var the call routes
        // through this writeback path instead of the general one, so apply the
        // same trailing-lambda-hosting preference here — otherwise a static
        // `Call` binds the wrong overload and the lambda lands on a scalar
        // parameter. Only override when the current pick genuinely cannot host
        // the lambda, to leave a correct index resolution untouched.
        if (lastArgIsLambda(args)) {
            const cur_hosts = if (bound_id) |bid| blk: {
                const f = b.module.funcById(bid) orelse break :blk false;
                if (f.params.len == 0) break :blk false;
                const last = f.params[f.params.len - 1];
                break :blk !last.is_vararg and fnTypeArityAlias(b, last.ty) != null;
            } else false;
            if (!cur_hosts) {
                if (overloadHostingTrailingLambda(b, segments[0].name, args.len)) |fid|
                    bound_id = fid;
            }
        }
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
                    .trailing_lambda = b.callTrailingLambda(),
                    .args = args_start,
                    .n_args = @intCast(arg_regs.len),
                    .arg_names = an,
                    .func = bound_id,
                    .candidates = try cmgCandidates(b, segments[0].name, segments[0].span.file, arg_regs.len),
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
                    .candidates = try cmgCandidates(b, segments[0].name, segments[0].span.file, arg_regs.len),
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
            const type_args = try helpers.internTypeArgsScoped(b, ast_type_args);
            try b.push(.{ .Call = .{
                .dst = dst,
                .func = func_id,
                .trailing_lambda = b.callTrailingLambda(),
                .args = args_start,
                .n_args = n_args,
                .arg_names = arg_names,
                .type_args = type_args,
                .exact = false,
            } });
        } else if (b.resolve(segments[0].name) == null and
            !b.hasOwnMember(segments[0].name) and
            !calleeRecvFnFlag(b, callee) and
            (b.capturesThisSlot() or b.resolve("this") != null))
        {
            // A bare call that is a member of an IMPLICIT receiver — a receiver
            // lambda's receiver (`compose { … }` inside a
            // `CompositionTestScope.() -> Unit` block) whose trailing lambda
            // mutates an outer var, routing the call through this writeback
            // path. The name is neither a top-level function (bound_id null) nor
            // an enclosing-class own-member, so probe the implicit receiver at
            // runtime: `CallMemberOrGlobal` tries each implicit receiver
            // innermost-first, then globals. Without this the callee loaded as
            // an unresolved global.
            const nmc = try b.module.internConst(b.allocator, .{ .String = segments[0].name });
            if (b.resolve("this")) |this_reg| {
                orEmitAudit(b, "writeback_member_call", "CallMemberOrGlobal", segments[0].name);
                try b.push(.{ .CallMemberOrGlobal = .{
                    .dst = dst,
                    .this_idx = 0,
                    .name = nmc,
                    .trailing_lambda = b.callTrailingLambda(),
                    .args = args_start,
                    .n_args = n_args,
                    .arg_names = arg_names,
                    .recv = this_reg,
                    .candidates = try cmgCandidates(b, segments[0].name, segments[0].span.file, n_args),
                    .static_recv = try cmgStaticRecv(b),
                } });
            } else {
                const this_idx = try b.recordCapture("this");
                orEmitAudit(b, "writeback_member_call", "CallMemberOrGlobal", segments[0].name);
                try b.push(.{ .CallMemberOrGlobal = .{
                    .dst = dst,
                    .this_idx = this_idx,
                    .name = nmc,
                    .trailing_lambda = b.callTrailingLambda(),
                    .args = args_start,
                    .n_args = n_args,
                    .arg_names = arg_names,
                    .candidates = try cmgCandidates(b, segments[0].name, segments[0].span.file, n_args),
                    .static_recv = try cmgStaticRecv(b),
                } });
            }
        } else if (b.resolve(segments[0].name) == null and
            b.hasOwnMember(segments[0].name) and b.resolve("this") != null)
        {
            // A member of the enclosing class — e.g. an inherited inline fn
            // (`forEachSlotLocked`) whose trailing lambda mutates a captured
            // local, routing the call through this writeback path — dispatches
            // on `this`. The index never resolves members (`bound_id` is null),
            // so without this it falls to an unresolved global LoadGlobal.
            const this_reg = b.resolve("this").?;
            if (calleeRecvFnFlag(b, callee)) {
                // A receiver-function-typed property invoked bare: read the
                // stored callable and run it with `this` as its receiver.
                const cal = b.allocReg();
                const fld = try b.module.internConst(b.allocator, .{ .String = segments[0].name });
                try b.push(.{ .GetField = .{ .dst = cal, .receiver = this_reg, .field = fld } });
                try b.push(.{ .CallValueWithThis = .{
                    .dst = dst,
                    .callee = cal,
                    .receiver = this_reg,
                    .args = args_start,
                    .n_args = n_args,
                    .arg_names = arg_names,
                } });
            } else {
                try b.push(.{ .CallMember = .{
                    .dst = dst,
                    .receiver = this_reg,
                    .name = try b.module.internConst(b.allocator, .{ .String = segments[0].name }),
                    .args = args_start,
                    .n_args = n_args,
                    .arg_names = arg_names,
                } });
            }
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
            if (calleeRecvFnFlag(b, callee) and inReceiverContext(b)) {
                const this_idx = try b.recordCapture("this");
                const this_r = b.allocReg();
                try b.push(.{ .LoadCapture = .{ .dst = this_r, .idx = this_idx } });
                try b.push(.{ .CallValueWithThis = .{
                    .dst = dst,
                    .callee = callee_r,
                    .receiver = this_r,
                    .args = args_start,
                    .n_args = n_args,
                    .arg_names = arg_names,
                } });
            } else {
                try b.push(.{ .CallValue = .{
                    .dst = dst,
                    .callee = callee_r,
                    .args = args_start,
                    .n_args = n_args,
                    .arg_names = arg_names,
                } });
            }
        }
    } else {
        const callee_r = try lowerExpr(b, callee);
        if (calleeRecvFnFlag(b, callee) and inReceiverContext(b)) {
            const this_idx = try b.recordCapture("this");
            const this_r = b.allocReg();
            try b.push(.{ .LoadCapture = .{ .dst = this_r, .idx = this_idx } });
            try b.push(.{ .CallValueWithThis = .{
                .dst = dst,
                .callee = callee_r,
                .receiver = this_r,
                .args = args_start,
                .n_args = n_args,
                .arg_names = arg_names,
            } });
        } else {
            try b.push(.{ .CallValue = .{
                .dst = dst,
                .callee = callee_r,
                .args = args_start,
                .n_args = n_args,
                .arg_names = arg_names,
            } });
        }
    }
    return dst;
}

/// The bare name a call's callee reads, unwrapped through `!!`, when that
/// name's declared type is a RECEIVER function type — a local/param flag
/// or an own/enclosing-class property in the registry. Such an invocation
/// binds the implicit `this` as the lambda's receiver.
fn calleeRecvFnFlag(b: *FuncBuilder, callee: *const Expr) bool {
    var cur = callee;
    while (cur.* == .Postfix and cur.Postfix.op == .NotNull) cur = cur.Postfix.expr;
    const name = switch (cur.*) {
        .Path => |p| if (p.segments.len == 1) p.segments[0].name else return false,
        .Member => |m| blk: {
            if (m.receiver.* == .Path and m.receiver.Path.segments.len == 1 and
                std.mem.eql(u8, m.receiver.Path.segments[0].name, "this"))
            {
                break :blk m.name.name;
            }
            return false;
        },
        else => return false,
    };
    if (b.localDeclRecvFn(name)) return true;
    var owner = b.ownerClass() orelse build.currentOwnerClass();
    var hops: usize = 0;
    while (owner) |o| : (hops += 1) {
        if (hops > 32) break;
        if (b.module.registry.recv_fn_props.get(.{ .a = o, .b = name }) != null) return true;
        owner = b.module.registry.enclosing_class.get(o);
    }
    return false;
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

fn lowerSpreadParts(b: *FuncBuilder, args: []const Expr) Allocator.Error![]SpreadPart {
    const parts = try b.allocator.alloc(SpreadPart, args.len);
    for (args, parts) |*arg, *part| {
        if (arg.* == .Spread) {
            part.* = .{ .reg = try lowerExpr(b, arg.Spread.expr), .is_spread = true };
        } else {
            part.* = .{ .reg = try lowerExpr(b, arg), .is_spread = false };
        }
    }
    return parts;
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
    var spread_name: ?ConstId = null;
    var spread_candidates: ?[]const FuncId = null;
    const callee_reg = blk: {
        if (callee.* == .Member) {
            const m = callee.Member;
            if (b.resolve(m.name.name) == null and !b.knowsOuter(m.name.name) and !b.isLocalFn(m.name.name)) {
                member_id = try b.module.internConst(b.allocator, .{ .String = m.name.name });
                break :blk try lowerReceiver(b, m.receiver);
            }
        }
        // A bare callee naming an enclosing-class member fn
        // (`checkContents(context, *es)` inside another member) dispatches
        // through `this`, not as a first-class value read (a member fn is
        // not a field, so the value path dies on `get_field`). A name that
        // is also a known top-level fn (`maxOf(a, *rest)`) keeps the
        // global path — the member set over-approximates.
        if (callee.* == .Path and callee.Path.segments.len == 1) {
            const name = callee.Path.segments[0].name;
            if (b.resolve(name) == null and !b.isLocalFn(name) and b.hasEnclosingMember(name) and
                b.module.funcId(name) == null)
            {
                if (try resolveThisForBareCall(b)) |this_reg| {
                    member_id = try b.module.internConst(b.allocator, .{ .String = name });
                    break :blk this_reg;
                }
            }
            // A bare global with overloads: the spread can only bind a
            // `vararg` parameter, so pick among the vararg-bearing
            // candidates explicitly — the generic value read below is
            // arg-blind and can hand back a zero-arg overload, silently
            // dropping the spread's elements.
            if (b.resolve(name) == null and !b.knowsOuter(name) and !b.isLocalFn(name) and
                !b.hasOwnMember(name) and b.module.funcsBySimpleName(name).len > 1)
            {
                const nm = try b.module.internConst(b.allocator, .{ .String = name });
                if (try b.module.boundedSpreadCandidates(
                    b.allocator,
                    name,
                    b.self_package,
                    callee.Path.segments[0].span.file,
                )) |ids| {
                    spread_name = nm;
                    spread_candidates = ids;
                    if (ids.len != 0) {
                        const dst = b.allocReg();
                        try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = nm, .func = ids[0] } });
                        break :blk dst;
                    }
                }
                if (b.module.funcIdForSpreadCall(name, b.ownerClass())) |fid| {
                    const dst = b.allocReg();
                    try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = nm, .func = fid } });
                    break :blk dst;
                }
            }
        }
        break :blk try lowerExpr(b, callee);
    };
    const parts = try lowerSpreadParts(b, args);
    const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
    const dst = b.allocReg();
    try b.push(.{ .CallSpread = .{
        .dst = dst,
        .callee = callee_reg,
        .parts = parts,
        .arg_names = arg_names,
        .member = member_id,
        .name = spread_name,
        .candidates = spread_candidates,
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
    // A local binding of a function-typed value (a plain fn param like
    // `body: () -> T`, a local val) shadows every top-level namesake for a
    // bare call — the call invokes the value, never an inline splice of an
    // unrelated extension. A NON-function-typed local does not shadow a
    // call (the `flow`-param case), matching the bare-function path.
    if (b.resolve(nm) != null and !b.isNonFnParam(nm)) return null;
    // A constructible same-named class that shadows this call per the scope
    // rules (an own-scope constructor, or no applicable same-named factory)
    // is the Kotlin target: never splice an inline factory over it —
    // `MutableVector(arr, size)` inside the class body binds the internal
    // constructor, not the reified `MutableVector(size, init)` factory that
    // happens to fit the arity.
    if (try shadowedByClass(b, callee, args)) return null;
    const inline_call_shape = CallShape{
        .want = args.len,
        .last_is_lambda = lastArgIsLambdaOrAnon(args),
        .trailing_lambda_arity = trailingLambdaArity(args),
    };
    // A renamed import is indexed under its declaration's original leaf, not
    // the source alias. Resolve the exact imported overload first, then hand
    // its registered AST to the ordinary splice path. This keeps reified
    // vararg/iterable adapters static without widening the alias into a
    // simple-name lookup.
    if (try renamedImportDirectTarget(b, callee.Path.segments[0], args, ast_arg_names)) |fid| {
        if (b.module.funcById(fid)) |target_func| {
            if (target_func.is_inline) {
                if (inline_state.inlineAstById(fid.int())) |target_ast| {
                    if (bareInlineNeedsSplice(b, nm, target_ast, args)) {
                        const expected = b.peekExpected();
                        const exp_ptr: ?*const ast.TypeRef = if (expected) |*_e| _e else null;
                        if (try tryInlineCallWithTypeArgs(b, nm, target_ast, args, ast_arg_names, null, ast_type_args, exp_ptr)) |r| {
                            return r;
                        }
                    }
                }
            }
        }
    }
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
    const nlr_dbg = if (runtime.getenvSlice("KLIO_EF_TRACE")) |efw| std.mem.eql(u8, efw, nm) else false;
    if (try inlineTargetForBareCall(b, &callee.Path.segments[0], args, inline_call_shape)) |f| {
        if (nlr_dbg) {
            const last_stmts: usize = if (args.len > 0 and args[args.len - 1] == .Lambda) args[args.len - 1].Lambda.body.stmts.len else 999;
            std.debug.print("[tbie] synchronized file={d} in_fn={s} target-found needs={} nlr={} nstmts={d}\n", .{ callee.Path.segments[0].span.file.int(), build.currentRealFn() orelse "-", bareInlineNeedsSplice(b, nm, f, args), inline_call.argLambdaHasNonlocalReturn(args), last_stmts });
        }
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
            reifiedNeedsLambdaArity(b, f, inline_call_shape.trailing_lambda_arity.?) and
            !inline_call.reifiedBindableFromArgs(b, f, args, ast_arg_names);
        if (!reified_underfilled and bareInlineNeedsSplice(b, nm, f, args)) {
            const expected = b.peekExpected();
            const exp_ptr: ?*const ast.TypeRef = if (expected) |*_e| _e else null;
            if (try tryInlineCallWithTypeArgs(b, nm, f, args, ast_arg_names, null, ast_type_args, exp_ptr)) |r| {
                return r;
            }
            if (nlr_dbg) std.debug.print("[tbie] synchronized in_fn={s} SPLICE-DECLINED\n", .{build.currentRealFn() orelse "-"});
        }
    }
    if (nlr_dbg) std.debug.print("[tbie] synchronized file={d} NO-TARGET-OR-DECLINED\n", .{callee.Path.segments[0].span.file.int()});
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

    // `collector.block()` — an EXPLICIT receiver invoking the enclosing
    // class's RECEIVER-function-typed property (`SafeFlow.block: suspend
    // FlowCollector.() -> Unit`): Kotlin runs the stored callable with the
    // explicit value as its receiver. Without this arm the call dispatched
    // as a member of the receiver and missed (`invoke` on NopCollector).
    if (!is_infix and callee.* == .Member and !callee.Member.safe and
        callee.Member.receiver.* != .This)
    {
        const mname0 = callee.Member.name.name;
        const own_recv_fn = blk: {
            if (b.resolve("this") == null) break :blk false;
            var owner = b.ownerClass() orelse build.currentOwnerClass();
            var hops: usize = 0;
            while (owner) |o| : (hops += 1) {
                if (hops > 32) break;
                if (b.module.registry.recv_fn_props.get(.{ .a = o, .b = mname0 }) != null) break :blk true;
                owner = b.module.registry.enclosing_class.get(o);
            }
            break :blk false;
        };
        if (own_recv_fn) {
            const recv_r = try lowerExpr(b, callee.Member.receiver);
            const this_reg = b.resolve("this").?;
            const cal = b.allocReg();
            const fld = try b.module.internConst(b.allocator, .{ .String = mname0 });
            try b.push(.{ .GetField = .{ .dst = cal, .receiver = this_reg, .field = fld } });
            const run = try lowerArgRun(b, args);
            const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
            const dst = b.allocReg();
            try b.push(.{ .CallValueWithThis = .{
                .dst = dst,
                .callee = cal,
                .receiver = recv_r,
                .args = run[0],
                .n_args = run[1],
                .arg_names = arg_names,
            } });
            return dst;
        }
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
            // A DECLARED MEMBER of the spliced receiver's own hierarchy
            // (`fetchStreamingResponse()` inside a spliced member-inline
            // `HttpStatement.body`) binds the receiver the same way an
            // extension namesake does — the hierarchy shadow set answers
            // membership even when the member is internal.
            const member_of_recv = blk: {
                const chain = recv_chain orelse break :blk false;
                if (chain.len == 0) break :blk false;
                const hs = b.module.registry.hierarchy_shadow_names.get(chain[0]) orelse break :blk false;
                if (!hs.complete) break :blk false;
                break :blk hs.names.contains(nm);
            };
            const binds_this = !is_scoped_class and (b.hasOwnMember(nm) or member_of_recv or
                (recv_chain != null and nameHasReceiverCandidate(b, nm, recv_chain)));
            if (binds_this) {
                // Pinning the dispatch to the innermost bound `this` is only
                // sound when the receiver evidence proves that value serves
                // the member (`member_of_recv`, an extension on the proven
                // chain). The `hasOwnMember` leg names a member of the
                // lexically enclosing CLASS — inside a receiver lambda whose
                // receiver does not own the member (a `(Long) -> R` frame
                // callback created in a `CoroutineScope.()` block, calling a
                // Recomposer private), the bound `this` is the scope receiver
                // and the owner sits further out; a lazily lowered pack body
                // has no receiver-type context to tell the cases apart. Emit
                // the receiver-walking form for that leg: the walk tries the
                // bound receiver's members first (identical to the pin when
                // `this` IS the owner), then each enclosing receiver.
                if (b.resolve("this")) |bound_this| {
                    const run = try lowerArgRun(b, args);
                    const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
                    const dst = b.allocReg();
                    const nmc = try b.module.internConst(b.allocator, .{ .String = nm });
                    orEmitAudit(b, "inline_splice_recv_walk", "CallMemberOrGlobal", nm);
                    try b.push(.{ .CallMemberOrGlobal = .{
                        .dst = dst,
                        .this_idx = 0,
                        .name = nmc,
                        .trailing_lambda = b.callTrailingLambda(),
                        .args = run[0],
                        .n_args = run[1],
                        .arg_names = arg_names,
                        .recv = bound_this,
                        .candidates = try cmgCandidates(b, nm, callee.Path.segments[0].span.file, run[1]),
                        .static_recv = try cmgStaticRecv(b),
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
                        .trailing_lambda = b.callTrailingLambda(),
                        .args = run[0],
                        .n_args = run[1],
                        .arg_names = arg_names,
                        .recv = bound_this,
                        .candidates = try cmgCandidates(b, nm, callee.Path.segments[0].span.file, run[1]),
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
                        .trailing_lambda = b.callTrailingLambda(),
                        .args = run[0],
                        .n_args = run[1],
                        .arg_names = arg_names,
                        .candidates = try cmgCandidates(b, nm, callee.Path.segments[0].span.file, run[1]),
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
            .trailing_lambda = b.callTrailingLambda(),
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
                .trailing_lambda = b.callTrailingLambda(),
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
            const type_args = try helpers.internTypeArgsScoped(b, ast_type_args);
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
        // Same-named local-fn siblings are OVERLOADS: when the call's
        // static facts (arity, argument names, literal/declared type
        // heads) select exactly one, call through its mangled cell —
        // reachable both in the declaring scope and as a capture. Calls
        // no fact separates keep the plain last-decl binding below.
        const bare = callee.Path.segments[0].name;
        var local_fn_inapplicable = false;
        if (b.localFnOverloads(bare)) |ovs| {
            if (try selectLocalFnOverload(b, ovs, args, ast_arg_names)) |m| {
                if (try lowerSelectedLocalOverloadCall(b, bare, m, args, ast_arg_names)) |r| return r;
            }
        }
        // SELF-reference: a bare call to the enclosing local fn's own name
        // from inside its body — including generated nested lambdas (the
        // compose restart re-invoke) — binds the fn ITSELF through its
        // mangled cell. The plain name cannot serve it: a later same-named
        // sibling declaration rebinds the shared plain-name slot (last bind
        // wins), and Kotlin scopes this call to the declarations visible at
        // this point in the body — the enclosing fn, never the sibling.
        if (b.selfLocalFn()) |slf| {
            if (std.mem.eql(u8, slf.name, bare) and
                try selfLocalFnApplicable(b, slf.mangled, bare, args, ast_arg_names))
            {
                if (try lowerSelectedLocalOverloadCall(b, bare, slf.mangled, args, ast_arg_names)) |r| return r;
            }
        }
        if (b.localFnDecls(bare)) |decls| {
            local_fn_inapplicable = !(try anyLocalFnOverloadApplicable(
                b,
                decls,
                args,
                ast_arg_names,
            ));
            // A LONE local fn reached from a NESTED body (its own body, or
            // a local fn declared inside it): the mangled overload cell
            // binds BEFORE the body lowers exactly so nested calls can
            // capture it. Route the call through the cell (`fun traverse`
            // inside GapComposer's `movableContentReferenceFor` recursing
            // into its encloser). The PLAIN name cannot serve even when it
            // IS a visible outer binding: a later same-named sibling
            // declaration (a validator extension beside the composable)
            // rebinds the shared plain-name slot, so a by-name capture
            // runs the sibling. Multi-overload sets select above; an
            // inapplicable local keeps outward resolution.
            if (decls.len == 1 and !local_fn_inapplicable and
                b.resolve(bare) == null and
                (b.resolve(decls[0].mangled) != null or b.knowsOuter(decls[0].mangled)))
            {
                if (try lowerSelectedLocalOverloadCall(b, bare, decls[0].mangled, args, ast_arg_names)) |r| return r;
            }
        }
        // A local function shadows an outer one by NAME, but only among
        // candidates that can take the call. A local `fun validate()` does
        // not hide the top-level `validate(block: () -> Unit)` from
        // `validate { … }`; invoking the local as a value made it call
        // itself for ever. With no applicable local, resolution continues
        // outward to the top-level / member candidates below.
        if (!local_fn_inapplicable) {
            if (try lowerValueInvocation(b, callee, args, ast_arg_names)) |r| return r;
            // A LONE applicable local fn reached as a CAPTURE (declared in
            // an enclosing body, called from this closure): invoke the
            // captured closure value. Without this the call fell through to
            // the classifier arms, and a local `fun Test(a, b)` lost to an
            // imported `kotlin.test.Test` inside `r.go { Test(1, 2) }`.
            // Two or more siblings select through the mangled binding above.
            // Gated on an actual classifier collision: a captured local fn
            // with NO same-named class keeps its established route (its
            // value binding is not always capturable — a `fun emit` inside
            // a runtime-lowered lambda resolves through the scoped-global
            // layers, not a capture slot).
            if (b.localFnDecls(bare) != null and b.resolve(bare) == null and b.knowsOuter(bare) and
                b.module.classIdIndexed(bare, b.self_package, callee.Path.segments[0].span.file) != null)
            {
                const cap = try resolveCapture(b, bare);
                const callee_r = b.allocReg();
                try b.push(.{ .CellGet = .{ .dst = callee_r, .cell = cap } });
                const run = try lowerArgRun(b, args);
                const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
                const dst = b.allocReg();
                orEmitAudit(b, "captured_local_fn_call", "CallValue", bare);
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
    }

    const callee_class_id: ?ir.ClassId = if (callee.* == .Path and callee.Path.segments.len == 1)
        b.module.classIdIndexed(callee.Path.segments[0].name, b.self_package, callee.Path.segments[0].span.file) orelse
            b.module.classIdExactImport(callee.Path.segments[0].name, callee.Path.segments[0].span.file)
    else
        null;
    const callee_is_object = if (callee_class_id) |cid|
        cid.int() < b.module.classes.items.len and b.module.classes.items[cid.int()].is_object
    else
        false;

    // Whether a single-segment class-name call resolves to the constructor.
    const shadowed_by_class = if (callee_is_object) false else try shadowedByClass(b, callee, args);
    // A constructible same-named class competing with the function
    // candidates: a static commit to the function is only sound when the
    // pick is type-proven; otherwise the deferred class-carrying form
    // below lets the runtime decide ctor-vs-factory on the actual
    // argument types (`Box(s.length)` constructs `Box(Int)`, not the
    // `fun Box(s: String)` factory the arity-only view would pick).
    const class_competes = callee.* == .Path and callee.Path.segments.len == 1 and
        !shadowed_by_class and !callee_is_object and blk: {
        const cid = callee_class_id orelse break :blk false;
        if (cid.int() >= b.module.classes.items.len) break :blk false;
        const cls = &b.module.classes.items[cid.int()];
        // An abstract/interface/sealed class never constructs, so it
        // does not compete with the function candidates.
        if (cls.is_abstract) break :blk false;
        // The class competes when its primary constructor can take this
        // argument count, OR when the count exceeds the primary arity — a
        // secondary constructor (not visible in the IR class, which carries
        // only the primary) may accept it (`ByteString(bytes, 0, n)` binds
        // the `(ByteArray, Int, Int)` secondary, not `fun ByteString(vararg
        // Byte)`). Deferring an over-primary count to runtime is safe: when
        // no constructor actually matches, the runtime falls to the factory.
        var required: usize = 0;
        var has_vararg = false;
        for (cls.primary_params) |*p| {
            if (p.is_vararg) {
                has_vararg = true;
                continue;
            }
            if (!p.has_default) required += 1;
        }
        break :blk (args.len >= required and (has_vararg or args.len <= cls.primary_params.len)) or
            args.len > cls.primary_params.len;
    };

    // Path-callee with a registered top-level fn → Call{func}.
    if (callee.* == .Path and callee.Path.segments.len == 1) {
        if (try lowerPathCall(b, expr, shadowed_by_class, class_competes)) |r| return r;
    }

    // A named object is a singleton value, not a constructible class.
    // Once same-named function overloads have had their ordinary call tier,
    // invoke the exact object identity through its operator surface.
    if (callee_is_object) {
        return try emitObjectValueCall(b, args, ast_arg_names, ast_type_args, callee.Path.segments[0].name, callee_class_id.?);
    }

    // A LOCAL class declared in this function (or an enclosing one) shadows
    // any same-simple-name module class for a bare constructor call. Its
    // runtime `.Class` value is bound at the declaration; inside a nested
    // lambda it arrives through the capture set. Route the call through
    // that binding — the module-index class path below would construct an
    // unrelated class (a nested class of another owner) instead.
    if (callee.* == .Path and callee.Path.segments.len == 1) {
        const nm0 = callee.Path.segments[0].name;
        if (build.isLocalClassInScope(nm0) and b.resolve(nm0) == null and b.knowsOuter(nm0)) {
            const callee_r = try resolveCapture(b, nm0);
            const run = try lowerArgRun(b, args);
            const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
            const dst = b.allocReg();
            orEmitAudit(b, "local_class_capture_ctor", "CallValue", nm0);
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

    // Path-callee with a registered class name. The indexed lookup binds
    // the class visible from the caller's package and imports, so a
    // cross-package simple-name collision constructs the right class.
    if (callee.* == .Path and callee.Path.segments.len == 1) {
        if (b.module.classIdIndexed(callee.Path.segments[0].name, b.self_package, callee.Path.segments[0].span.file) orelse
            b.module.classIdExactImport(callee.Path.segments[0].name, callee.Path.segments[0].span.file)) |class_id|
        {
            const ctor_arity = try ctorArgFnArities(b, class_id, args, ast_arg_names);
            defer if (ctor_arity) |ca| b.allocator.free(ca);
            const run = try lowerArgRunFull(b, args, ctor_arity, null);
            const realigned = try ctorRealignedArgNames(b, class_id, args, ast_arg_names);
            defer if (realigned) |r| b.allocator.free(r);
            const arg_names = try internArgNames(b.allocator, b.module, realigned orelse ast_arg_names);
            const dst = b.allocReg();
            const cls = &b.module.classes.items[class_id.int()];
            const static_sam = cls.is_fun_interface and args.len == 1 and !anyNamedArg(ast_arg_names);
            if (shadowed_by_class or static_sam) {
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
                orEmitAudit(b, if (static_sam) "fun_interface_sam" else "bare_ctor_shadowed_by_class", "NewInstance", callee.Path.segments[0].name);
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
                    .candidates = try cmgCandidates(b, callee.Path.segments[0].name, callee.Path.segments[0].span.file, run[1]),
                    .static_recv = try cmgStaticRecv(b),
                } });
            }
            return dst;
        }
    }

    // Inside a method/extension body: unqualified `name(...)` that didn't
    // match a local / top-level fn / class is a method call on `this`.
    if (callee.* == .Path) {
        if (try lowerImplicitThisCall(
            b,
            callee,
            args,
            ast_arg_names,
            ast_type_args,
        )) |r| return r;
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
        // A collision-mangled class reached only through an explicit import
        // (`import a.Widget` with a same-named `b.Widget`) is registered under
        // its mangled name, so `classId` misses — but it is a real class ctor,
        // not an unresolved bare call.
        b.module.classIdExactImport(callee.Path.segments[0].name, callee.Path.segments[0].span.file) == null and
        (b.module.funcId(callee.Path.segments[0].name) == null or inReceiverContext(b)))
    {
        if (try lowerUnresolvedBareCall(b, callee, args, ast_arg_names, ast_type_args, null)) |r| return r;
    }

    // Built-in stdlib companion shortcuts: `Result.success(x)` etc.
    if (try lowerCompanionShortcut(b, callee, args, ast_arg_names)) |r| return r;

    // Package-qualified constructor call (`app.sub.Widget()`): the dotted
    // callee names a class, so construct it — before the function-FQN and
    // member-fallback paths, which would otherwise read the package head as a
    // field of the implicit receiver (`get_field app on this`).
    if (callee.* == .Member) {
        if (try lowerFqnCtorCall(b, expr)) |r| return r;
    }
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
            // A captured local fn is a candidate the runtime member walk
            // cannot see: emit the runtime-arbitrated form. Its value arm
            // falls to the enclosing member when the closure's declared
            // params refute the args (`testEncode(codec, bytes, symbols)`
            // binds the local on String args, the private member on
            // ByteArray).
            if (b.knowsOuter(nm0) and call.type_args.len == 0) {
                if (try resolveThisForBareCallNoBind(b)) |this_reg| {
                    const cv = try resolveCapture(b, nm0);
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
    const type_args = try helpers.internTypeArgsScoped(b, call.type_args);
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
/// Whether inline member fn `f` is declared on the enclosing class or one of
/// its transitive supertypes — i.e. reachable as `this.<f>` from a member body.
fn inlineOwnerInEnclosingHierarchy(b: *FuncBuilder, enclosing: []const u8, f: *const ast.Function) bool {
    const owner = inline_state.inlineMemberOwner(f) orelse return false;
    return classIsOrExtendsHosted(b, enclosing, owner);
}

/// Whether a member-inline candidate's owner class is on the qualified
/// call receiver's static type chain. An unknown receiver type keeps the
/// candidate (the shape-based pick's historical behavior); a KNOWN
/// receiver whose hierarchy does not include the owner rejects it —
/// `resp.body<User>()` on an `HttpResponse` must not splice the
/// unrelated `HttpStatement.body`.
fn memberOwnerOnReceiverChain(b: *FuncBuilder, receiver: *const Expr, cf: *const ast.Function) Allocator.Error!bool {
    const owner = inline_state.inlineMemberOwner(cf) orelse return true;
    const head = (try inline_call.inferReceiverType(b, receiver)) orelse return true;
    return classIsOrExtendsHosted(b, head, owner);
}

/// `classIsOrExtends` that also accepts `$Companion`-mangled names on
/// either side by reducing them to their host class: a bare call inside
/// `ContentType.Companion` is in scope of `HeaderValueWithParameters`'s
/// companion members exactly when `ContentType` extends it.
fn classIsOrExtendsHosted(b: *FuncBuilder, sub: []const u8, super: []const u8) bool {
    if (b.module.classIsOrExtends(sub, super)) return true;
    const sub_host = hostClassOfCompanion(sub) orelse sub;
    const super_host = hostClassOfCompanion(super) orelse super;
    if (sub_host.len == sub.len and super_host.len == super.len) return false;
    return b.module.classIsOrExtends(sub_host, super_host);
}

/// The symbol-index scope tier of an inline candidate at a reference
/// site (0 named-import … 5 invisible); unknown metadata ranks as the
/// default-import tier so it neither wins nor loses against real
/// records.
fn inlineCandTier(b: *const FuncBuilder, f: *const ast.Function, caller_file: span.FileId) u8 {
    const m = b.module;
    const decl_file = f.name.span.file;
    const decl_pkg = m.packageOfFile(decl_file) orelse return 3;
    const caller_pkg = m.packageOfFile(caller_file) orelse b.self_package;
    var buf: [256]u8 = undefined;
    const fqn = std.fmt.bufPrint(&buf, "{s}.{s}", .{ decl_pkg, f.name.name }) catch return 3;
    return m.scopeTier(fqn, decl_pkg, f.name.name, caller_pkg, caller_file);
}

/// Whether a plain top-level inline fn is visible at `caller_file` under
/// Kotlin scoping: same package, exact or wildcard import, or a
/// default-import package. Only the invisible tier (an unimported
/// foreign package) is rejected.
fn bareInlineVisibleFrom(b: *const FuncBuilder, f: *const ast.Function, caller_file: span.FileId) bool {
    return inlineCandTier(b, f, caller_file) <= 3;
}

/// Re-rank a shape-based plain-inline pick by call-site visibility: with
/// several same-name NON-extension inline candidates across packs (seven
/// `synchronized` actuals in the compose set), the registration-order
/// pick is bake-order-sensitive and can splice another pack's body.
/// Kotlin resolves by scope — prefer the lowest tier among candidates
/// that fit the call shape; ties keep the incumbent.
fn retierPlainInlinePick(
    b: *const FuncBuilder,
    pick: *const ast.Function,
    nm: []const u8,
    shape: CallShape,
    caller_file: span.FileId,
) *const ast.Function {
    if (pick.receiver_type != null or inline_state.inlineMemberOwner(pick) != null) return pick;
    const cands = inline_state.candidatesForName(nm) orelse return pick;
    if (cands.len < 2) return pick;
    var best = pick;
    var best_tier = inlineCandTier(b, pick, caller_file);
    for (cands) |cf| {
        if (cf == pick) continue;
        if (cf.receiver_type != null or inline_state.inlineMemberOwner(cf) != null) continue;
        if (shape.last_is_lambda) {
            if (cf.params.len == 0) continue;
            const lp = &cf.params[cf.params.len - 1];
            if (lp.ty.function == null) continue;
            if (cf.params.len != shape.want) continue;
        } else if (cf.params.len != shape.want) {
            continue;
        }
        const t = inlineCandTier(b, cf, caller_file);
        if (t < best_tier) {
            best_tier = t;
            best = cf;
        }
    }
    return best;
}

fn inlineTargetForBareCall(
    b: *FuncBuilder,
    seg: *const ast.Ident,
    args: []const Expr,
    shape: CallShape,
) Allocator.Error!?*const ast.Function {
    const nm = seg.name;
    // The active splice's declared receiver serves as evidence when the
    // caller context has none of its own (a bare reified call inside a
    // spliced extension body); it feeds only this pick, not binding.
    const evid_chain: ?[]const []const u8 = if (try narrowingRecvChain(b)) |c|
        c
    else if (b.spliceRecvTy()) |srt|
        try recvChainOf(b, srt)
    else
        null;
    // Host-backed default imports suppress the simple-name candidate table,
    // but not an exact FuncId resolved by the scope-aware index below. The
    // source declaration remains the semantic target of an inline call and
    // must be available when reification, non-local return, or suspension
    // requires a splice; ordinary calls still fall through to the host binding
    // because `bareInlineNeedsSplice` rejects them.
    const narrowed = inlineFnAstForRecv(nm, shape, evid_chain);
    const ires = b.module.resolveBareCallIndexed(
        nm,
        b.self_package,
        seg.span.file,
        args.len,
        shape.last_is_lambda,
    );
    var pick: ?*const ast.Function = switch (ires.outcome) {
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
                // Same reasoning for a companion member reached through
                // the enclosing class's hierarchy (`ContentType.Companion
                // .parse` calling the inherited `HeaderValueWithParameters
                // .Companion.parse`): companion scope is invisible to the
                // index, and Kotlin ranks it above a top-level namesake.
                if (nf.receiver_type == null and bareInlineNeedsSplice(b, nm, nf, args)) {
                    if (inline_state.inlineMemberOwner(nf)) |nowner| {
                        if (companionOwnerInEnclosingHierarchy(b, nowner)) break :blk nf;
                    }
                }
            }
            const idx_pick = inline_state.inlineAstById(fid.int());
            // A trailing-lambda call cannot bind a candidate whose last
            // parameter is not function-typed: the lambda would land on a
            // scalar parameter (`group(metadata: LongArray, offset: Int)`
            // absorbing `group(200) { … }`). When the index resolves such a
            // namesake for a trailing-lambda call, decline the inline splice so
            // the ordinary path resolves the lambda-hosting overload (the
            // receiver extension) instead.
            if (shape.last_is_lambda) {
                if (idx_pick) |ip| {
                    if (!astLastParamHostsLambda(ip)) break :blk null;
                }
            }
            break :blk idx_pick;
        },
        // The index declined; the shape-narrowed pick stands in — but a
        // plain (receiverless) inline fn is only a legal target when its
        // declaring package is in scope at the call site. Without the
        // filter, `max(permits, 0)` under `import kotlin.math.*` splices
        // an unrelated pack's `max(a: Dp, b: Dp)`. Extension picks stay:
        // receiver narrowing, not package scope, is their discriminator.
        .deferred => blk: {
            var nf = narrowed orelse break :blk null;
            // A plain pick re-ranks by call-site scope tier: with several
            // same-name plain inline candidates across packs (`synchronized`
            // actuals), the registration-order pick is bake-order-sensitive.
            nf = retierPlainInlinePick(b, nf, nm, shape, seg.span.file);
            // Member-inline fns are exempt: their discriminator is the
            // enclosing class hierarchy (checked below), not package
            // scope — `propertyFailsWith` on an implicit CompareContext
            // receiver must splice from any file.
            if (nf.receiver_type == null and
                inline_state.inlineMemberOwner(nf) == null and
                !bareInlineVisibleFrom(b, nf, seg.span.file))
            {
                break :blk null;
            }
            break :blk nf;
        },
    };
    // Same-simple-name inline MEMBER overloads declared in unrelated classes:
    // a bare call inside a member binds `this.<name>`, so the overload must be
    // one declared in the enclosing class's own hierarchy — never a namesake
    // member of an unrelated class. The index resolves the bare name without a
    // receiver, so it can pick either; correct it here. (`performingMeasure` is
    // a member of both `NodeCoordinator` and the unrelated `LookaheadDelegate`;
    // inside `InnerNodeCoordinator.measure` only the `NodeCoordinator` one is in
    // scope, and the two bodies differ.)
    if (pick) |pf| {
        if (b.ownerClass()) |enclosing| {
            // The pick is an inline member of a class the enclosing class does
            // NOT belong to. A bare call inside a member binds `this.<name>`, so
            // an unrelated class's namesake is never the target.
            if (pf.receiver_type == null) {
                if (inline_state.inlineMemberOwner(pf)) |powner| {
                    if (!classIsOrExtendsHosted(b, enclosing, powner)) {
                        // Prefer a same-name inline overload declared in the
                        // enclosing class's own hierarchy, if one exists.
                        var replaced = false;
                        if (inline_state.candidatesForName(nm)) |cands| {
                            if (cands.len >= 2) {
                                for (cands) |cf| {
                                    if (cf == pf or cf.receiver_type != null) continue;
                                    if (inlineOwnerInEnclosingHierarchy(b, enclosing, cf)) {
                                        pick = cf;
                                        replaced = true;
                                        break;
                                    }
                                }
                            }
                        }
                        // Otherwise, if the enclosing class declares its own
                        // member of this name, decline the splice so the normal
                        // member-call path binds it — a class's own `head`
                        // (even non-inline) wins over an unrelated class's
                        // inline `head`, whose body would run on the wrong `this`.
                        if (!replaced and b.hasEnclosingMember(nm)) return null;
                    }
                }
            }
        } else if (pf.receiver_type == null) {
            // No enclosing class at all (a top-level extension body): a
            // member-inline pick can only be in scope through an implicit
            // receiver, and the receiver chain is known here. When the
            // pick's owner is not on the chain, prefer the same-name
            // EXTENSION overload whose declared receiver IS — inside
            // `List<T>.fastFirstOrNull`, bare `fastForEach { }` must
            // splice `List.fastForEach`, never `SlotIdsSet`'s member
            // (whose body reads the wrong class's `set` field).
            if (inline_state.inlineMemberOwner(pf)) |powner| {
                const chain: ?[]const []const u8 = try narrowingRecvChain(b);
                if (chain) |ch| {
                    var owner_on_chain = false;
                    for (ch) |cn| {
                        if (std.mem.eql(u8, cn, powner)) {
                            owner_on_chain = true;
                            break;
                        }
                    }
                    if (!owner_on_chain) {
                        if (inline_state.candidatesForName(nm)) |cands| {
                            for (cands) |cf| {
                                if (cf == pf) continue;
                                const rt = cf.receiver_type orelse continue;
                                for (ch) |cn| {
                                    if (std.mem.eql(u8, cn, rt.name.name)) {
                                        pick = cf;
                                        break;
                                    }
                                }
                                if (pick != pf) break;
                            }
                        }
                    }
                }
            }
        }
    }
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
    // Argument type evidence corrects a shape-picked sibling: the splice
    // selectors above rank by NAME + arity + receiver only, so two inline
    // overloads that differ in a parameter's TYPE tie and the first
    // registered one wins — `visitAncestors(mask: Int, ...)` binding a
    // `NodeKind` argument whose real target is the `(type: NodeKind<T>, ...)`
    // sibling. When the declared/derived head of an argument DISPROVES the
    // pick's parameter (a user-class head against a primitive parameter, or
    // two distinct known classes), re-pick the sibling the evidence fits.
    if (pick) |pf| {
        if (inlineEvidenceRejects(b, pf, args)) {
            var better: ?*const ast.Function = null;
            if (inline_state.candidatesForName(nm)) |cands| {
                for (cands) |cf| {
                    if (cf == pf) continue;
                    if ((cf.receiver_type == null) != (pf.receiver_type == null)) continue;
                    if (!inlineShapeFits(cf, args, shape)) continue;
                    if (inlineEvidenceRejects(b, cf, args)) continue;
                    better = cf;
                    break;
                }
            }
            // No sibling fits either: decline the splice entirely so the
            // dynamic call path resolves on runtime values.
            pick = better;
        }
    }
    // The enclosing class's OWN applicable member outranks an inline
    // EXTENSION whose declared receiver is not evidenced by the receiver
    // chain: a bare `withCurrent { }` inside SnapshotStateMap (which
    // declares a private inline member `withCurrent`) must bind the
    // member, never splice the unrelated `T : StateRecord`.withCurrent
    // extension onto the map. An extension whose receiver IS on the
    // chain keeps the splice — the innermost receiver's extension is
    // Kotlin's pick there.
    if (pick) |pf| {
        if (runtime.getenvSlice("KLIO_INLINE_PICK")) |w| {
            if (std.mem.eql(u8, w, nm)) std.debug.print("[ipick-tail] {s} recv={s} hasOwn={} applicable={}\n", .{ nm, if (pf.receiver_type) |rt| rt.name.name else "-", b.hasOwnMember(nm), b.ownMemberApplicable(nm, args.len) });
        }
        if (pf.receiver_type != null and b.hasOwnMember(nm) and
            b.ownMemberApplicable(nm, args.len))
        {
            const rt_name = pf.receiver_type.?.name.name;
            var evidenced = false;
            if (try narrowingRecvChain(b)) |ch| {
                for (ch) |cn| {
                    if (std.mem.eql(u8, cn, rt_name)) {
                        evidenced = true;
                        break;
                    }
                }
            }
            if (!evidenced) return null;
        }
    }
    inlineResolveAudit(b, nm, seg.span.file, narrowed, pick, args, shape.last_is_lambda, ires);
    return pick;
}

/// Whether argument type evidence definitely excludes inline candidate `f`
/// for this call: a positional argument whose evidence head is a known user
/// class bound to a builtin-kind parameter (`NodeKind` -> `Int`), or two
/// distinct known class heads with no shared name. Conservative — unknown
/// evidence or parameter kinds never reject.
fn inlineEvidenceRejects(b: *FuncBuilder, f: *const ast.Function, args: []const Expr) bool {
    const positional_n = if (args.len > 0 and switch (args[args.len - 1]) {
        .Lambda, .AnonFun => true,
        else => false,
    }) args.len - 1 else args.len;
    for (args[0..positional_n], 0..) |*a, i| {
        if (i >= f.params.len) break;
        const ev = argDeclTypeRef(b, a) orelse continue;
        const ehead = std.mem.trimEnd(u8, ev.name, "?");
        const pname = f.params[i].ty.name.name;
        const phead = std.mem.trimEnd(u8, pname, "?");
        if (std.mem.eql(u8, ehead, phead)) continue;
        const e_builtin = paramLitKind(ehead);
        const p_builtin = paramLitKind(phead);
        // A known user class where a builtin kind is required (or vice
        // versa) is a definite mismatch.
        if (p_builtin != null and e_builtin == null and b.module.classId(ehead) != null) return true;
        if (p_builtin == null and e_builtin != null and b.module.classId(phead) != null and
            !classHasBoundedTypeParam(b, phead) and
            !typeNameIsParam(f, phead)) return true;
    }
    return false;
}

/// Whether the class named `phead` declares a type parameter with a real
/// (non-`Any`) upper bound. The registry records every class type param
/// (unbounded ones under an `Any` bound), so presence alone is not the
/// signal this evidence check keys on.
fn classHasBoundedTypeParam(b: *FuncBuilder, phead: []const u8) bool {
    const bounds = b.module.registry.class_type_param_bounds.get(phead) orelse return false;
    for (bounds) |bd| {
        if (!std.mem.eql(u8, bd.bound, "Any")) return true;
    }
    return false;
}

/// Whether `name` is one of `f`'s declared type parameters.
fn typeNameIsParam(f: *const ast.Function, name: []const u8) bool {
    for (f.type_params) |*tp| {
        if (std.mem.eql(u8, tp.name.name, name)) return true;
    }
    return false;
}

/// Shape fit for an evidence re-pick: every positional argument has a
/// parameter slot, a trailing lambda has a last parameter to bind, and every
/// unfilled parameter carries a default.
fn inlineShapeFits(f: *const ast.Function, args: []const Expr, shape: CallShape) bool {
    const has_trailing = shape.last_is_lambda;
    const positional_n = if (has_trailing and args.len > 0) args.len - 1 else args.len;
    if (f.params.len < args.len) return false;
    if (has_trailing and f.params.len == 0) return false;
    var i: usize = positional_n;
    const last = if (has_trailing) f.params.len - 1 else f.params.len;
    while (i < last) : (i += 1) {
        if (f.params[i].default == null) return false;
    }
    return true;
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
    // An inline member of a COMPANION object reached through the enclosing
    // class's hierarchy (`ContentType.Companion.parse` calling the inherited
    // `HeaderValueWithParameters.Companion.parse`): the splice is the only
    // route — member dispatch has no enclosing-supertype-companion walk on
    // the call side, and the bare-global fallback binds an unrelated
    // namesake (or nothing). Kotlin resolves this statically, so splice it.
    const companion_super_member = f.receiver_type == null and blk: {
        const owner = inline_state.inlineMemberOwner(f) orelse break :blk false;
        break :blk companionOwnerInEnclosingHierarchy(b, owner);
    };
    return !recv_mismatch and
        (f.is_suspend or argLambdaHasNonlocalReturn(args) or
            inline_call.argsForwardInlineLambda(b, args) or has_reified or shadowed_by_member or
            companion_super_member);
}

/// True when `owner` names a companion object (a `$Companion`-mangled
/// lifted class) whose HOST class is the enclosing class — or an
/// ancestor of it. Both sides reduce to their host class: a bare call
/// written inside `Sub.Companion` or inside `Sub`'s own body sees the
/// companion members of `Sub`'s superclasses (Kotlin's static scope).
fn companionOwnerInEnclosingHierarchy(b: *FuncBuilder, owner: []const u8) bool {
    const o_host = hostClassOfCompanion(owner) orelse return false;
    const e = b.ownerClass() orelse return false;
    const e_host = hostClassOfCompanion(e) orelse e;
    return b.module.classIsOrExtends(e_host, o_host);
}

/// The class a `$Companion` mangle belongs to (`Base$Companion` →
/// `Base`), or null when `name` is not a companion mangle.
fn hostClassOfCompanion(name: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, name, "$Companion") orelse return null;
    if (idx == 0) return null;
    return name[0..idx];
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
/// Whether `f`'s last parameter is function-typed, so it can host a trailing
/// lambda argument. A candidate that fails this cannot be the target of a
/// `name(args) { … }` call — the block would bind a scalar parameter.
fn astLastParamHostsLambda(f: *const ast.Function) bool {
    if (f.params.len == 0) return false;
    const last = f.params[f.params.len - 1];
    if (last.is_vararg) return false;
    return last.ty.function != null;
}

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

/// The definitely-known static type head of an argument expression, for
/// local-fn overload selection: literals, lambdas, and locals with a
/// declared type annotation. Null = unknown (never disproves).
fn staticArgHead(b: *const FuncBuilder, e: *const Expr) ?[]const u8 {
    return switch (e.*) {
        .BoolLit => "Boolean",
        .StringTemplate => "String",
        .CharLit => "Char",
        .IntLit => "Int",
        .FloatLit => "Double",
        .Lambda => "->",
        .Path => |p| blk: {
            if (p.segments.len != 1) break :blk null;
            break :blk b.localDeclType(p.segments[0].name);
        },
        else => null,
    };
}

fn allUppercase(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isUpper(c)) return false;
    }
    return s.len != 0;
}

const numeric_heads = [_][]const u8{
    "Int",  "Long",  "Short",  "Byte",  "Double", "Float",
    "UInt", "ULong", "UShort", "UByte", "Number",
};

fn headIsNumeric(h: []const u8) bool {
    for (numeric_heads) |n| {
        if (std.mem.eql(u8, h, n)) return true;
    }
    return false;
}

/// A builtin scalar head — the only heads that definitely disprove one
/// another (and that a lambda literal can never satisfy).
fn headIsScalar(h: []const u8) bool {
    if (headIsNumeric(h)) return true;
    const scalars = [_][]const u8{ "Boolean", "String", "Char" };
    for (scalars) |s| {
        if (std.mem.eql(u8, h, s)) return true;
    }
    return false;
}

/// Whether declared head `d` denotes a function type. A parsed function
/// type carries the synthetic tag `"<function>"` (see `ast.TypeRef`); a
/// spelled-out `(P) -> R` or an erased `FunctionN` name also count.
fn headIsFunctionType(d: []const u8) bool {
    return std.mem.eql(u8, d, "<function>") or
        std.mem.indexOf(u8, d, "->") != null or
        std.mem.startsWith(u8, d, "Function");
}

/// Can an argument with static head `h` bind a parameter declared `d`?
/// Disproof-only: `true` unless both sides are known and definitely
/// incompatible (numeric literals coerce across the numeric family).
///
/// `strict` tightens the lambda case for OVERLOAD SELECTION: a `{ … }`
/// argument matches only a function-typed parameter, so a `(…) -> R`
/// sibling wins over a same-arity non-function one. When `false` (the
/// applicability / shadow-or-fall-through decision) the lambda case is
/// disproof-only: reject only a definite non-function scalar, since an
/// unknown class name may be a function typealias.
fn headCompatible(h: []const u8, d_raw: []const u8, strict: bool) bool {
    const d = std.mem.trimEnd(u8, d_raw, "?");
    if (std.mem.eql(u8, d, "Any") or std.mem.eql(u8, d, "Unit")) return true;
    if (d.len > 0 and d.len <= 2 and allUppercase(d)) return true;
    const d_fn = headIsFunctionType(d);
    if (std.mem.eql(u8, h, "->")) {
        if (d_fn) return true;
        return if (strict) false else !headIsScalar(d);
    }
    if (d_fn) return false;
    if (std.mem.eql(u8, h, d)) return true;
    if (headIsNumeric(h) and headIsNumeric(d)) return true;
    // The head is a definite literal kind; a differently-named declared
    // class stays unknown (could be a supertype) — only the builtin
    // scalar heads disprove each other.
    return !(headIsScalar(h) and headIsScalar(d));
}

/// Statically select among same-named local-fn declarations: arity and
/// named-argument fit, then literal/declared-type disproof per bound
/// parameter. Returns the unique survivor's mangled binding, or null
/// when no signature fact separates the candidates (the caller keeps
/// the plain last-decl binding).
/// Can any same-named local-function declaration take this call at all
/// (arity, varargs, defaults, argument names)? When none can, the local
/// name does not shadow the outer candidates.
fn anyLocalFnOverloadApplicable(
    b: *const FuncBuilder,
    ovs: []const build.LocalFnOverload,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
) Allocator.Error!bool {
    outer: for (ovs) |*ov| {
        if (ov.is_ext) {
            const receiver = b.recvTypeRef() orelse return false;
            if (!try localOverloadReceiverCouldApply(b, ov, receiver)) continue;
        }
        if (args.len < ov.n_required and !ov.has_vararg) continue;
        if (args.len > ov.param_tys.len and !ov.has_vararg) continue;
        var bound = [_]bool{false} ** 64;
        if (ov.param_tys.len > bound.len) continue;
        var positional: usize = 0;
        for (args, 0..) |*a, i| {
            const supplied: ?[]const u8 = if (i < ast_arg_names.len) ast_arg_names[i] else null;
            var pi: ?usize = null;
            if (supplied) |nm| {
                var found = false;
                for (ov.param_names, 0..) |pn, k| {
                    if (std.mem.eql(u8, pn, nm)) {
                        if (bound[k]) continue :outer;
                        pi = k;
                        bound[k] = true;
                        found = true;
                        break;
                    }
                }
                if (!found) continue :outer;
            } else {
                if (positional < ov.param_tys.len) {
                    pi = positional;
                    bound[positional] = true;
                } else if (!ov.has_vararg) {
                    continue :outer;
                }
                positional += 1;
            }
            // Type-head disproof per bound parameter, mirroring
            // `selectLocalFnOverload`: a `validate { … }` (lambda arg) does not
            // fit `fun validate(state: Int)`. Without this the local name was
            // deemed applicable on arity alone and the call recursed into
            // itself instead of falling through to the outer extension.
            if (pi) |k| {
                const d = ov.param_tys[k] orelse continue;
                const h = staticArgHead(b, a) orelse continue;
                if (!headCompatible(h, d, false)) continue :outer;
            }
        }
        return true;
    }
    return false;
}

/// Whether the enclosing local fn's own overload record can take this call
/// (arity + argument names). Missing record (the table did not reach this
/// deferred body) keeps the route available — the runtime binder still
/// resolves the mangled cell's closure.
fn selfLocalFnApplicable(
    b: *const FuncBuilder,
    mangled: []const u8,
    bare: []const u8,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
) Allocator.Error!bool {
    const decls = b.localFnDecls(bare) orelse return true;
    for (decls) |*ov| {
        if (!std.mem.eql(u8, ov.mangled, mangled)) continue;
        return anyLocalFnOverloadApplicable(b, @as([*]const build.LocalFnOverload, @ptrCast(ov))[0..1], args, ast_arg_names);
    }
    return true;
}

fn selectLocalFnOverload(
    b: *const FuncBuilder,
    ovs: []const build.LocalFnOverload,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
) Allocator.Error!?[]const u8 {
    var survivor: ?*const build.LocalFnOverload = null;
    var n_survivors: usize = 0;
    var exact: ?*const build.LocalFnOverload = null;
    var n_exact: usize = 0;
    outer: for (ovs) |*ov| {
        // An EXTENSION sibling is only a candidate where a KNOWN
        // receiver type is in scope (the enclosing receiver-lambda's
        // declared receiver, carried across lambda boundaries):
        // `fun Checker.Composition()` beside a plain local
        // `fun Composition(...)` binds inside the validator's receiver
        // lambda and never from a receiver-less scope. A merely-captured
        // `this` is not enough — every lambda captures one.
        if (ov.is_ext) {
            const receiver = b.recvTypeRef() orelse continue;
            if (!try localOverloadReceiverCouldApply(b, ov, receiver)) continue;
        }
        if (args.len < ov.n_required and !ov.has_vararg) continue;
        if (args.len > ov.param_tys.len and !ov.has_vararg) continue;
        var bound = [_]bool{false} ** 64;
        if (ov.param_tys.len > bound.len) continue;
        var positional: usize = 0;
        for (args, 0..) |*a, i| {
            const supplied: ?[]const u8 = if (i < ast_arg_names.len) ast_arg_names[i] else null;
            var pi: ?usize = null;
            if (supplied) |nm| {
                for (ov.param_names, 0..) |pn, k| {
                    if (std.mem.eql(u8, pn, nm)) {
                        if (bound[k]) continue :outer;
                        pi = k;
                        bound[k] = true;
                        break;
                    }
                }
                if (pi == null) continue :outer;
            } else {
                if (positional < ov.param_tys.len) {
                    pi = positional;
                    bound[positional] = true;
                } else if (!ov.has_vararg) {
                    continue :outer;
                }
                positional += 1;
            }
            if (pi) |k| {
                const d = ov.param_tys[k] orelse continue;
                const h = staticArgHead(b, a) orelse continue;
                if (!headCompatible(h, d, true)) continue :outer;
            }
        }
        survivor = ov;
        n_survivors += 1;
        if (args.len == ov.param_tys.len) {
            exact = ov;
            n_exact += 1;
        }
    }
    if (n_survivors == 1) return survivor.?.mangled;
    if (n_exact == 1) return exact.?.mangled;
    return null;
}

/// Emit the call to a statically selected local-fn overload through its
/// mangled cell binding — resolvable in the declaring scope or as a
/// capture. Null when this scope cannot reach the cell (a forward sibling
/// reference from a lambda captured before the sibling declared); the
/// caller falls back to the plain-name binding.
fn lowerSelectedLocalOverloadCall(
    b: *FuncBuilder,
    bare: []const u8,
    mangled: []const u8,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
) Allocator.Error!?Reg {
    const cell: Reg = if (b.resolve(mangled)) |r|
        r
    else if (b.knowsOuter(mangled))
        try resolveCapture(b, mangled)
    else
        return null;
    const callee_reg = b.allocReg();
    try b.push(.{ .CellGet = .{ .dst = callee_reg, .cell = cell } });
    // A selected local *extension* overload takes the enclosing receiver
    // as its leading `this` param, like the plain-name ext arm.
    if (b.isLocalExtFn(mangled)) {
        // No reachable receiver: fall back to the plain-name route rather
        // than invoking the extension with its `this` slot missing.
        const this_reg = try resolveThisForBareCallNoBind(b);
        if (this_reg == null) return null;
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
    const lfp: ?[]const ?[]const u8 = if (allNull(ast_arg_names)) b.localFnParamTys(mangled) else null;
    const run = try lowerArgRunFull(b, args, null, lfp);
    const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
    const dst = b.allocReg();
    var member_declared = b.hasEnclosingMember(bare);
    if (!member_declared) {
        if (b.ownerClass()) |oc| {
            if (b.module.registry.hierarchy_methods.get(oc)) |s| {
                member_declared = s.contains(bare);
            }
        }
    }
    if (member_declared) {
        if (try resolveThisForBareCallNoBind(b)) |this_reg| {
            const name = try b.module.internConst(b.allocator, .{ .String = bare });
            try b.push(.{ .CallValueOrMember = .{
                .dst = dst,
                .callee = callee_reg,
                .this_recv = this_reg,
                .name = name,
                .args = run[0],
                .n_args = run[1],
                .arg_names = arg_names,
            } });
            return dst;
        }
    }
    try b.push(.{ .CallValue = .{
        .dst = dst,
        .callee = callee_reg,
        .args = run[0],
        .n_args = run[1],
        .arg_names = arg_names,
    } });
    return dst;
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

    // Member-function precedence over a same-named value/param. A local
    // fn with a same-named enclosing member also routes through the
    // arbitrated form: the value arm wins unless the closure's declared
    // params refute the args (Kotlin picks the member overload then), so
    // `testEncode(codec, byteArray, s)` reaches the private member past
    // the String-typed local.
    const redirect_to_member = blk: {
        var member_declared = b.hasEnclosingMember(name0);
        if (!member_declared) {
            if (b.ownerClass()) |oc| {
                if (b.module.registry.hierarchy_methods.get(oc)) |s| {
                    member_declared = s.contains(name0);
                }
            }
        }
        break :blk member_declared and b.resolve(name0) != null and !b.isLocalExtFn(name0);
    };
    if (redirect_to_member) {
        if (try resolveThisForBareCallNoBind(b)) |this_reg| {
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
        // Nor does a LOCAL whose initializer is a definite non-callable
        // literal: `var nodeIndex = 0` beside `fun nodeIndex(slots, group)`
        // resolves the call `nodeIndex(slots, startingGroup)` to the
        // function (an Int is not invokable) — the composer's
        // movable-content insert is the shape.
        if (b.module.funcId(name0) != null and !b.isLocalFn(name0)) {
            if (b.localInitExpr(name0)) |init_e| {
                if (argLitKind(init_e) != null) return null;
            }
        }
        // Nor does a function-typed param shadow one for a TRAILING-LAMBDA
        // call it cannot accept. The lambda binds the callee's last parameter,
        // so a param whose own last parameter is not a function type is not
        // this call's target: inside
        // `Flow<T>.map(crossinline transform: suspend (T) -> R)` the body's
        // `transform { value -> … }` is the `Flow.transform` OPERATOR, and only
        // the inner `transform(value)` is the parameter. Binding the parameter
        // there passed the operator's own lambda in as the emitted value, so
        // `map`'s caller saw a closure where its element belonged.
        if (b.isPlainFnParam(name0) and !b.fnParamTakesTrailingLambda(name0) and
            lastArgIsLambda(args) and b.module.funcId(name0) != null)
        {
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
        }) {
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

/// Whether an expression's STATIC type head is definitely a list-family
/// value: a call to a list factory, or a `listOf(...) + x` chain. Used to
/// route `list + (rhs as Any)` through `plusElement`.
fn staticListHead(e: *const Expr) bool {
    return switch (e.*) {
        .Call => |c| blk: {
            if (c.callee.* != .Path or c.callee.Path.segments.len != 1) break :blk false;
            const n = c.callee.Path.segments[0].name;
            break :blk std.mem.eql(u8, n, "listOf") or std.mem.eql(u8, n, "mutableListOf") or
                std.mem.eql(u8, n, "emptyList") or std.mem.eql(u8, n, "arrayListOf");
        },
        .Binary => |bi| bi.op == .Add and staticListHead(bi.lhs),
        else => false,
    };
}

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
        .Lambda => |l| blk: {
            if (l.implicit_it) break :blk @as(u8, 0);
            // The compose plugin threads every composable lambda BEFORE
            // lowering, appending `($composer, $changed)`. Those are not
            // source params: overload selection must rank the literal by
            // its DECLARED header, or the +2 shift binds `{ d -> }` to a
            // 3-param overload (`movableContentOf`'s P3 form).
            var n = l.params.len;
            if (n >= 2 and std.mem.eql(u8, l.params[n - 1].name, "$changed") and
                std.mem.eql(u8, l.params[n - 2].name, "$composer"))
            {
                n -= 2;
            }
            break :blk @intCast(n);
        },
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
    const ty = argDeclTypeRef(b, arg);
    const declared_fn_arity = if (ty) |t| fnTypeArityAlias(b, t) else null;
    const literal_callable = arg.* == .Lambda or arg.* == .AnonFun;
    return .{
        .named = name,
        .is_spread = arg.* == .Spread,
        .is_null = arg.* == .NullLit,
        .is_lambda = literal_callable or declared_fn_arity != null,
        .lambda_arity = astArgLambdaArity(arg) orelse if (declared_fn_arity) |n| @intCast(n) else null,
        .func_typed = declared_fn_arity != null,
        .lambda_is_literal = literal_callable,
        .literal_kind = if (argEvidenceLitKind(b, arg)) |k| switch (k) {
            .numeric => .numeric,
            .string => .string,
            .boolean => .boolean,
            .char => .char,
        } else null,
        .ty = ty,
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
/// An `if (x is T)` condition over a bare name smart-casts `x` to `T` for the
/// then-arm. Kotlin resolves extensions against the STATIC type, and lowering
/// hands the receiver's declared head to the extension filter, so without the
/// narrowing the declared head (`Any?`) refutes every `CharSequence` extension
/// and `x.isEmpty()` misses. A negated check narrows nothing here (its
/// information is on the else path).
pub fn narrowIsCheck(b: *FuncBuilder, cond: *const Expr) Allocator.Error!?build.FuncBuilder.NarrowedLocal {
    if (cond.* != .IsCheck) return null;
    const ck = cond.IsCheck;
    if (ck.negated) return null;
    const head = loweredCheckTypeName(b, &ck.ty);
    if (head.len == 0) return null;
    if (ck.expr.* == .Path and ck.expr.Path.segments.len == 1) {
        return try b.narrowLocal(ck.expr.Path.segments[0].name, head);
    }
    if (ck.expr.* == .This and ck.expr.This.qualifier == null) {
        return try b.narrowLocal("this", head);
    }
    return null;
}

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
                        sp.file.int(), sp.start,
                        la.name,       if (la.nullable) @as([]const u8, "?") else "",
                        th.name,       if (th.nullable) @as([]const u8, "?") else "",
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
    if (arg.* == .This and arg.This.qualifier == null) {
        if (b.localDeclTypeRef("this")) |narrowed| return narrowed;
        if (b.recvTypeRef()) |receiver| return receiver;
        if (b.enclosingRecvTy()) |head| {
            return .{ .name = head, .nullable = false, .args = &.{} };
        }
        return null;
    }
    switch (arg.*) {
        .IntLit => |lit| return .{
            .name = switch (lit.kind) {
                .Int => if (lit.value >= std.math.minInt(i32) and
                    lit.value <= std.math.maxInt(i32)) "Int" else "Long",
                .Long => "Long",
                .UInt => "UInt",
                .ULong => "ULong",
            },
            .nullable = false,
            .args = &.{},
        },
        .FloatLit => |lit| return .{
            .name = if (lit.kind == .Float) "Float" else "Double",
            .nullable = false,
            .args = &.{},
        },
        .BoolLit => return .{ .name = "Boolean", .nullable = false, .args = &.{} },
        .CharLit => return .{ .name = "Char", .nullable = false, .args = &.{} },
        .StringTemplate => return .{ .name = "String", .nullable = false, .args = &.{} },
        .NullLit => return .{ .name = "Nothing", .nullable = true, .args = &.{} },
        else => {},
    }
    // An unsafe cast fixes the argument's static type for overload
    // resolution — kotlinc sees exactly the cast target. That is the
    // documented way to force a sibling overload (ktor's deprecated
    // `P.install` delegates with `install(plugin as Plugin<P, B, F>,
    // configure)`; without the cast evidence the call binds itself and
    // recurses forever).
    if (arg.* == .As and !arg.As.safe) {
        return .{ .name = loweredTypeName(b, &arg.As.ty), .nullable = arg.As.ty.nullable, .args = &.{} };
    }
    if (arg.* == .Call and arg.Call.callee.* == .Path and arg.Call.callee.Path.segments.len == 1) {
        const seg = arg.Call.callee.Path.segments[0];
        if (b.localCallReturn(seg.name)) |ret| {
            return .{ .name = ret.name, .nullable = ret.nullable, .args = &.{} };
        }
        // A unique concrete classifier with no same-named plain function is
        // a constructor call, so its result head is statically authoritative.
        // The conservative function gate leaves factory/class collisions for
        // the ordinary call resolver instead of inventing a receiver type.
        if (b.resolve(seg.name) == null and !b.isLocalFn(seg.name) and
            !enclosingHasMemberNamed(b, seg.name))
        {
            var same_named_function = false;
            for (b.module.funcsBySimpleName(seg.name)) |fid| {
                const f = b.module.funcById(fid) orelse continue;
                if (f.kind == .plain and
                    (f.hasBody() or b.module.decl_ast_body.contains(fid.int())))
                {
                    same_named_function = true;
                    break;
                }
            }
            if (!same_named_function) {
                const pkg = b.module.packageOfFile(seg.span.file) orelse b.self_package;
                if (b.module.classIdIndexed(seg.name, pkg, seg.span.file)) |cid| {
                    if (cid.int() < b.module.classes.items.len) {
                        const class = &b.module.classes.items[cid.int()];
                        if (!class.is_object and !class.is_interface and !class.is_abstract) {
                            return .{ .name = class.fqn, .nullable = false, .args = &.{} };
                        }
                    }
                }
            }
        }
    }
    // A qualified object/class property read (`Nodes.Traversable`, parsed
    // as a Member access on a bare class-name receiver): the registered
    // per-class property type head is the argument's static type —
    // `visitAncestors(Nodes.Traversable) { }` must resolve against
    // `NodeKind`, not bind the sibling `(mask: Int, ...)` overload.
    if (arg.* == .Member and !arg.Member.safe) {
        const recv = arg.Member.receiver;
        if (recv.* == .Path and recv.Path.segments.len == 1) {
            const owner = recv.Path.segments[0].name;
            if (owner.len != 0 and std.ascii.isUpper(owner[0]) and
                b.resolve(owner) == null and b.module.classId(owner) != null)
            {
                if (b.module.registry.class_prop_type_heads.get(.{ .a = owner, .b = arg.Member.name.name })) |head| {
                    return .{ .name = head, .nullable = false, .args = &.{} };
                }
            }
        }
        return null;
    }
    if (arg.* != .Path) return null;
    const p = arg.Path;
    // Same qualified property-read evidence for the two-segment Path form.
    if (p.segments.len == 2) {
        const owner = p.segments[0].name;
        if (owner.len != 0 and std.ascii.isUpper(owner[0]) and
            b.resolve(owner) == null and b.module.classId(owner) != null)
        {
            if (b.module.registry.class_prop_type_heads.get(.{ .a = owner, .b = p.segments[1].name })) |head| {
                return .{ .name = head, .nullable = false, .args = &.{} };
            }
        }
        return null;
    }
    if (p.segments.len != 1) return null;
    if (b.localDeclTypeRef(p.segments[0].name)) |declared| {
        var result = declared;
        result.nullable = result.nullable or b.localDeclNullable(p.segments[0].name);
        return result;
    }
    if (b.localInitExpr(p.segments[0].name)) |init| {
        if (init != arg) {
            if (argDeclTypeRefLazy(b, init)) |inferred| return inferred;
        }
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

fn staticCallReturnTypeRef(
    b: *FuncBuilder,
    call_expr: *const Expr,
) Allocator.Error!?ir.TypeRef {
    if (call_expr.* == .Binary) {
        const bin = call_expr.Binary;
        const method: []const u8 = switch (bin.op) {
            .Add => "plus",
            .Sub => "minus",
            else => return null,
        };
        var inferred_receiver: ?ir.TypeRef = null;
        defer if (inferred_receiver) |*ty| ty.deinit(b.allocator);
        const receiver = argDeclTypeRefLazy(b, bin.lhs) orelse blk: {
            inferred_receiver = try staticCallReturnTypeRef(b, bin.lhs);
            break :blk inferred_receiver orelse return null;
        };
        if (isPrimitiveTypeName(typeHead(receiver.name))) return null;

        const args = bin.rhs[0..1];
        var shape_set = try buildStaticReturnArgShapes(b, args, &.{});
        defer shape_set.deinit(b.allocator);

        var target: ?FuncId = null;
        var identity = std.mem.trimEnd(u8, receiver.name, "?");
        if (std.mem.indexOfScalar(u8, identity, '<')) |lt| identity = identity[0..lt];
        const head = typeHead(identity);
        const owner_id = if (std.mem.indexOfScalar(u8, identity, '.') != null)
            b.module.classIdByFqn(identity)
        else
            b.module.uniqueClassIdBySimpleName(head);
        if (owner_id) |owner| {
            const lexical_owner: ?ir.ClassId = if (b.ownerClass()) |owner_name|
                (if (std.mem.indexOfScalar(u8, owner_name, '.') != null)
                    b.module.classIdByFqn(owner_name)
                else
                    (b.module.classIdIndexed(
                        owner_name,
                        b.self_package,
                        bin.span.file,
                    ) orelse b.module.classId(owner_name)))
            else
                null;
            const resolved = b.module.resolveMemberCall(
                owner,
                method,
                shape_set.shapes,
                .{ .lexical_owner = lexical_owner },
            );
            if (resolved.dispatch != .deferred) target = resolved.target;
        }
        if (target == null) {
            const implicit_owners = try b.collectImplicitReceiverTower(
                b.allocator,
                eagerLambdaRecvHead(b),
            );
            defer b.allocator.free(implicit_owners);
            const owned_bounds = try b.typeParamBoundsSlice();
            defer if (owned_bounds) |bounds| b.allocator.free(bounds);
            target = b.module.resolveExtensionCall(
                method,
                receiver,
                shape_set.shapes,
                .{
                    .caller_file = bin.span.file,
                    .caller_package = b.module.packageOfFile(bin.span.file) orelse b.self_package,
                    .implicit_dispatch_owners = implicit_owners,
                    .lexical_owner = b.ownerClass(),
                    .call_name = method,
                    .actual_type_param_bounds = owned_bounds orelse &.{},
                },
            ).target;
        }
        return try b.module.instantiatedCallReturnType(
            b.allocator,
            target orelse return null,
            receiver,
            shape_set.shapes,
            &.{},
        );
    }
    if (call_expr.* != .Call) return null;
    const call = call_expr.Call;
    var shape_set = try buildStaticReturnArgShapes(b, call.args, call.arg_names);
    defer shape_set.deinit(b.allocator);

    var receiver: ?ir.TypeRef = null;
    defer if (receiver) |*ty| ty.deinit(b.allocator);
    var target: FuncId = undefined;
    switch (call.callee.*) {
        .Path => |path| {
            if (path.segments.len != 1) return null;
            const name = path.segments[0];
            if (b.resolve(name.name) != null or b.isLocalFn(name.name) or
                b.knowsOuter(name.name) or enclosingHasMemberNamed(b, name.name))
            {
                return null;
            }
            const res = try b.module.resolveCall(
                b.allocator,
                name.name,
                b.self_package,
                name.span.file,
                shape_set.shapes,
                lastArgIsLambda(call.args),
                resolveCtxFor(b, name.name, call.type_args, null),
            );
            defer b.allocator.free(res.candidate_set);
            target = res.target orelse return null;
            // A plain lambda that captures its lexical class receiver makes
            // bare-call emission conservative, but an unknown receiver lambda
            // still cannot lend its target's return type to another proof.
            if (res.confidence != .exact and
                (b.recvTy() != null or b.isParamThunk())) return null;
        },
        .Member => |member| {
            receiver = if (argDeclTypeRefLazy(b, member.receiver)) |known|
                try known.clone(b.allocator)
            else
                try staticCallReturnTypeRef(b, member.receiver);
            const recv_ty = receiver orelse return null;
            var identity = std.mem.trimEnd(u8, recv_ty.name, "?");
            if (std.mem.indexOfScalar(u8, identity, '<')) |lt| identity = identity[0..lt];
            const head = typeHead(identity);
            const owner_id = if (std.mem.indexOfScalar(u8, identity, '.') != null)
                b.module.classIdByFqn(identity)
            else
                b.module.uniqueClassIdBySimpleName(head);

            var resolved_target: ?FuncId = null;
            if (owner_id) |owner| {
                const lexical_owner: ?ir.ClassId = if (b.ownerClass()) |owner_name|
                    (if (std.mem.indexOfScalar(u8, owner_name, '.') != null)
                        b.module.classIdByFqn(owner_name)
                    else
                        (b.module.classIdIndexed(
                            owner_name,
                            b.self_package,
                            member.name.span.file,
                        ) orelse b.module.classId(owner_name)))
                else
                    null;
                const resolved = b.module.resolveMemberCall(
                    owner,
                    member.name.name,
                    shape_set.shapes,
                    .{ .lexical_owner = lexical_owner },
                );
                if (resolved.dispatch != .deferred) resolved_target = resolved.target;
            }
            if (resolved_target == null) {
                const implicit_owners = try b.collectImplicitReceiverTower(
                    b.allocator,
                    eagerLambdaRecvHead(b),
                );
                defer b.allocator.free(implicit_owners);
                const owned_bounds = try b.typeParamBoundsSlice();
                defer if (owned_bounds) |bounds| b.allocator.free(bounds);
                resolved_target = b.module.resolveExtensionCall(
                    member.name.name,
                    recv_ty,
                    shape_set.shapes,
                    .{
                        .caller_file = member.name.span.file,
                        .caller_package = b.module.packageOfFile(member.name.span.file) orelse b.self_package,
                        .implicit_dispatch_owners = implicit_owners,
                        .lexical_owner = b.ownerClass(),
                        .call_name = member.name.name,
                        .actual_type_param_bounds = owned_bounds orelse &.{},
                    },
                ).target;
            }
            target = resolved_target orelse return null;
        },
        else => return null,
    }

    const explicit = try b.allocator.alloc(ir.TypeRef, call.type_args.len);
    defer {
        for (explicit) |*ty| ty.deinit(b.allocator);
        b.allocator.free(explicit);
    }
    for (call.type_args, explicit) |*ty, *out| {
        out.* = try decl_mod.loweredTypeRef(b.allocator, ty, true);
    }
    var inferred = try b.module.instantiatedCallReturnType(
        b.allocator,
        target,
        receiver,
        shape_set.shapes,
        explicit,
    );
    if (inferred != null and
        call.callee.* == .Member and call.callee.Member.safe)
    {
        inferred.?.nullable = true;
    }
    return inferred;
}

const StaticReturnArgShapes = struct {
    shapes: []applicability.ArgShape,
    inferred: []?ir.TypeRef,

    fn deinit(self: *@This(), allocator: Allocator) void {
        for (self.inferred) |*ty| {
            if (ty.*) |*owned| owned.deinit(allocator);
        }
        allocator.free(self.inferred);
        allocator.free(self.shapes);
    }
};

/// Static call shapes enriched by recursively resolved call return types.
/// Unlike the eager type-head channel, every inferred entry here comes from a
/// unique declaration identity and can therefore participate in exact
/// overload selection.
fn buildStaticReturnArgShapes(
    b: *FuncBuilder,
    args: []const Expr,
    arg_names: []const ?[]const u8,
) Allocator.Error!StaticReturnArgShapes {
    const shapes = try buildStaticArgShapes(b, args, arg_names);
    errdefer b.allocator.free(shapes);
    const inferred = try b.allocator.alloc(?ir.TypeRef, args.len);
    @memset(inferred, null);
    errdefer {
        for (inferred) |*ty| {
            if (ty.*) |*owned| owned.deinit(b.allocator);
        }
        b.allocator.free(inferred);
    }
    for (args, shapes, inferred) |*arg, *shape, *owned| {
        if (shape.ty != null) continue;
        owned.* = try staticCallReturnTypeRef(b, arg);
        if (owned.*) |ty| shape.ty = ty;
    }
    return .{ .shapes = shapes, .inferred = inferred };
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

/// Argument shapes admitted by an exact/static dispatch proof. The permissive
/// eager type-head fill remains useful for additive runtime ranking, but only
/// declared, cast, literal, and constructor evidence may reject a candidate.
fn buildStaticArgShapes(
    b: *FuncBuilder,
    args: []const Expr,
    arg_names: []const ?[]const u8,
) Allocator.Error![]applicability.ArgShape {
    const shapes = try buildArgShapes(b, args, arg_names);
    for (args, shapes) |*arg, *shape| {
        shape.ty = argDeclTypeRefLazy(b, arg);
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
    if (runtime.getenvSlice("KLIO_NU_TRACE") != null and std.mem.eql(u8, name, "Density")) {
        const abs = cid.int() < b.module.classes.items.len and b.module.classes.items[cid.int()].is_abstract;
        std.debug.print("[sbc] Density cid={d} abstract={} owner={s}\n", .{ cid.int(), abs, b.ownerClass() orelse "-" });
    }
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
    // Scope rule: a MEMBER of the enclosing class hierarchy is a nearer-scope
    // candidate than a same-named foreign classifier — a bare `Test(...)`
    // inside a class declaring `fun Test(...)` calls the member, never
    // constructs an imported `kotlin.test.Test`. A class NESTED in the
    // enclosing chain keeps constructor semantics: its bare name also sits in
    // the member set, but a capitalized call to it is a constructor. Deciding
    // `false` here routes the call through `CallMemberOrGlobal`, whose runtime
    // scoring still reaches the constructor when no member actually binds.
    if (runtime.getenvSlice("KLIO_SBC_TRACE") != null) {
        std.debug.print("[sbc] {s} owner={s} own={} encl={} nested={}\n", .{ name, b.ownerClass() orelse "-", b.hasOwnMember(name), b.hasEnclosingMember(name), classNestedInEnclosing(b, cid) });
    }
    if (enclosingHasMemberNamed(b, name) and !classNestedInEnclosing(b, cid)) return false;
    // Scope rule: a captured outer binding of the name (a local `fun Test`
    // declared in an enclosing body, reaching this closure as a capture) is
    // a nearer-scope candidate than an imported classifier — `Test(1, 2)`
    // inside `r.go { … }` calls the local function, never constructs
    // `kotlin.test.Test`. Deciding false routes through the deferred
    // class-carrying form, whose runtime shadow gate lets the captured
    // callable win and still reaches the constructor when nothing binds.
    if (b.resolve(name) == null and (b.knowsOuter(name) or isLowerAnonCapture(name))) return false;
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

/// Whether the enclosing class scope (own members, outer-class members, or
/// the supertype hierarchy) declares a member named `name`.
fn enclosingHasMemberNamed(b: *FuncBuilder, name: []const u8) bool {
    if (b.hasOwnMember(name) or b.hasEnclosingMember(name)) return true;
    const oc = b.ownerClass() orelse return false;
    const hs = b.module.registry.hierarchy_shadow_names.get(oc) orelse return false;
    return hs.names.contains(name);
}

/// Whether class `cid` is declared inside the enclosing class chain (a
/// nested/inner class of the class being lowered or of one of its outers).
fn classNestedInEnclosing(b: *FuncBuilder, cid: ir.ClassId) bool {
    if (cid.int() >= b.module.classes.items.len) return false;
    const cls_name = b.module.classes.items[cid.int()].name;
    const enc = b.module.registry.enclosing_class.get(cls_name) orelse return false;
    var owner = b.ownerClass();
    var hops: usize = 0;
    while (owner) |o| : (hops += 1) {
        if (hops > 32) break;
        if (std.mem.eql(u8, o, enc)) return true;
        owner = b.module.registry.enclosing_class.get(o);
    }
    return false;
}

fn anyFunctionParam(params: []const ir.Param) bool {
    for (params) |p| {
        if (std.mem.startsWith(u8, p.ty.name, "Function")) return true;
    }
    return false;
}

/// Path-callee bare-name → Call ladder. Returns null when no top-level fn /
/// the class path should handle it instead.
/// The read side of a `var x by D` local: dispatch `D.getValue(null, ::x)` when
/// the hidden delegate binding is reachable here — bound in this scope, or
/// captured from an enclosing one. Null when `x` is not a mutable delegated
/// local (a plain local, or a `val x by lazy`, whose eager-once value stands).
fn lowerDelegateRead(b: *FuncBuilder, name: []const u8) Allocator.Error!?Reg {
    var namebuf: [512]u8 = undefined;
    const dname_stack = std.fmt.bufPrint(&namebuf, "{s}$klio_delegate", .{name}) catch return null;
    const in_scope = b.resolve(dname_stack) != null;
    const outer = b.knowsOuter(dname_stack);
    if (!in_scope and !outer) return null;
    const dname = try b.allocator.dupe(u8, dname_stack);
    const delegate = if (in_scope) b.resolve(dname).? else try resolveCapture(b, dname);
    const null_arg = try b.emitConst(.Null);
    const prop_ref = b.allocReg();
    const pname = try b.module.internConst(b.allocator, .{ .String = name });
    try b.push(.{ .PropertyRef = .{ .dst = prop_ref, .name = pname } });
    const args_start = b.allocReg();
    try b.push(.{ .Move = .{ .dst = args_start, .src = null_arg } });
    _ = b.allocReg();
    try b.push(.{ .Move = .{ .dst = Reg.from(args_start.int() + 1), .src = prop_ref } });
    const dst = b.allocReg();
    const getter = try b.module.internConst(b.allocator, .{ .String = "getValue" });
    try b.push(.{ .CallMember = .{
        .dst = dst,
        .receiver = delegate,
        .name = getter,
        .args = args_start,
        .n_args = 2,
        .arg_names = &.{},
    } });
    return dst;
}

/// Among the same-named EXTENSION overloads of `name`, the one whose leading
/// `this` receiver type matches the enclosing extension's receiver type. Lets an
/// ambiguous bare call inside an extension body resolve its arity/receiver-lambda
/// shape. Null when no enclosing receiver type is known or no single overload
/// matches.
/// Whether any same-named EXTENSION whose declared receiver head matches the
/// enclosing receiver type accepts `n_args` value arguments. Kotlin checks
/// implicit-receiver candidates before no-receiver ones, so such an extension
/// shadows a same-named file-private top-level function.
fn extOnEnclosingReceiverApplies(b: *FuncBuilder, name: []const u8, n_args: usize) bool {
    const recv = b.enclosingRecvTy() orelse return false;
    const recv_simple = simpleTypeHead(recv);
    const ids = b.module.func_name_index.get(name) orelse return false;
    for (ids.items) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) continue;
        if (!std.mem.eql(u8, simpleTypeHead(f.params[0].ty.name), recv_simple)) continue;
        const user_params = f.params.len - 1;
        var required: usize = 0;
        for (f.params[1..]) |*pp| {
            if (!pp.has_default and !pp.is_vararg) required += 1;
        }
        if (n_args >= required and n_args <= user_params) return true;
    }
    return false;
}

fn disambiguateByReceiver(b: *FuncBuilder, name: []const u8) ?FuncId {
    const recv = b.enclosingRecvTy() orelse return null;
    const recv_simple = simpleTypeHead(recv);
    const ids = b.module.func_name_index.get(name) orelse return null;
    var match: ?FuncId = null;
    for (ids.items) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) continue;
        if (!std.mem.eql(u8, simpleTypeHead(f.params[0].ty.name), recv_simple)) continue;
        if (match != null) return null;
        match = fid;
    }
    return match;
}

fn simpleTypeHead(name: []const u8) []const u8 {
    var n = name;
    if (std.mem.indexOfScalar(u8, n, '<')) |lt| n = n[0..lt];
    if (std.mem.lastIndexOfScalar(u8, n, '.')) |dot| n = n[dot + 1 ..];
    return n;
}

/// Resolve a renamed import against the exact FQN the import denotes while
/// retaining the implicit receiver of a bare extension call.  Qualifying the
/// callee path is not equivalent: `import p.f as g; recv.g(x)` can be written
/// as bare `g(x)` inside an extension body, and `p.f(x)` would drop `recv`.
/// Null means the imported overload set is not statically unique from the
/// evidence available at lowering time.
fn renamedImportDirectTarget(
    b: *FuncBuilder,
    ident: ast.Ident,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
) Allocator.Error!?FuncId {
    const paths = b.module.importAliasPathsIn(ident.span.file, ident.name);
    if (paths.len != 1 or paths[0].segs.len < 2) return null;
    const target_leaf = paths[0].segs[paths[0].segs.len - 1];
    if (std.mem.eql(u8, target_leaf, ident.name)) return null;

    // A real member named by the alias remains in the implicit-receiver
    // candidate group ahead of the imported extension.
    if (inReceiverContext(b) and anyReceiverClassDeclares(b, ident.name)) return null;

    const shapes = try buildArgShapes(b, args, ast_arg_names);
    defer b.allocator.free(shapes);
    const recv = b.enclosingRecvTy() orelse b.recvTy() orelse b.ownerClass();
    const can_supply_this = b.resolve("this") != null or b.knowsOuter("this") or
        b.capturesThisSlot();

    var best: ?FuncId = null;
    var best_recv_rank: i16 = -1;
    var best_sig_rank: i32 = std.math.minInt(i32);
    var best_shape_rank: i16 = -1;
    var tied = false;
    const trace = if (runtime.getenvSlice("KLIO_BARE_TRACE")) |wanted|
        std.mem.eql(u8, wanted, ident.name)
    else
        false;
    for (b.module.funcsBySimpleName(target_leaf)) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        if (!std.mem.eql(u8, f.fqn, paths[0].fqn)) continue;
        if (f.low_priority) continue;
        if (!fqnCallArityFits(b, fid, args.len)) continue;
        const sig_score = b.module.declSigScore(fid, shapes) orelse continue;

        const is_ext = f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this");
        var recv_match = false;
        if (is_ext) {
            if (!can_supply_this) continue;
            if (recv) |r| {
                const actual = simpleTypeHead(r);
                const declared = simpleTypeHead(f.params[0].ty.name);
                recv_match = std.mem.eql(u8, actual, declared) or
                    b.module.classIsOrExtends(actual, declared);
                if (!recv_match) continue;
            }
        }

        const arity = b.module.decl_user_arity.get(fid.int()) orelse continue;
        const shape_rank: i16 = if (arity.has_vararg)
            1
        else if (arity.total == args.len)
            4
        else
            2;
        // Static argument compatibility selects the overload first. An
        // implicit receiver breaks a score tie, but cannot make
        // `Flow.combine(Flow, ...)` outrank `combine(Iterable<Flow>, ...)`
        // when the first supplied argument is statically a List.
        const recv_rank: i16 = if (recv_match) 1 else 0;
        if (trace) std.debug.print("[alias-pick] {s} fid={d} inline={} recv={d} score={d} shape={d}\n", .{
            f.fqn, fid.int(), f.is_inline, recv_rank, sig_score.points, shape_rank,
        });

        if (sig_score.points > best_sig_rank or
            (sig_score.points == best_sig_rank and recv_rank > best_recv_rank) or
            (sig_score.points == best_sig_rank and recv_rank == best_recv_rank and shape_rank > best_shape_rank))
        {
            best = fid;
            best_recv_rank = recv_rank;
            best_sig_rank = sig_score.points;
            best_shape_rank = shape_rank;
            tied = false;
        } else if (recv_rank == best_recv_rank and
            sig_score.points == best_sig_rank and shape_rank == best_shape_rank)
        {
            tied = true;
        }
    }
    return if (tied) null else best;
}

fn lowerPathCall(b: *FuncBuilder, expr: *const Expr, shadowed_by_class: bool, class_competes: bool) Allocator.Error!?Reg {
    const call = expr.Call;
    const callee = call.callee;
    const args = call.args;
    const ast_arg_names = call.arg_names;
    const ast_type_args = call.type_args;
    const segments = callee.Path.segments;
    const name0 = segments[0].name;

    // Secondary-ctor delegation / default-value thunk: a bare own-member call
    // with no `this` in scope is a companion access — the enclosing instance
    // does not exist yet, so `generateOetf(x)` inside `: this(generateOetf(x))`
    // binds the companion's `generateOetf`, never an instance method. Dispatch
    // it as a member call on the owner class value; the VM forwards a class
    // receiver to its companion singleton, walking the superclass chain so an
    // inherited companion member (declared on a superclass's companion) resolves
    // too — `Sub.mk()` lowers to exactly this `LoadGlobal + CallMember` pair.
    // Mirrors the value-read handling of the same case (a bare own-member read
    // in a param thunk); `own_members` already includes own + inherited
    // companion members, so a plain member name is filtered by `hasOwnMember`.
    if (b.isParamThunk() and b.resolve("this") == null and
        b.hasOwnMember(name0) and !classWithCompanion(b, name0))
    {
        if (b.ownerClass()) |owner| {
            const cls = b.allocReg();
            const on = try b.module.internConst(b.allocator, .{ .String = owner });
            try b.push(.{ .LoadGlobal = .{ .dst = cls, .name = on } });
            const run = try lowerArgRun(b, args);
            const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
            const dst = b.allocReg();
            const nmc = try b.module.internConst(b.allocator, .{ .String = name0 });
            try b.push(.{ .CallMember = .{
                .dst = dst,
                .receiver = cls,
                .name = nmc,
                .trailing_lambda = b.callTrailingLambda(),
                .args = run[0],
                .n_args = run[1],
                .arg_names = arg_names,
            } });
            return dst;
        }
    }

    // A captured outer that also names a top-level fn: route through value.
    // Unless the outer is a local FUNCTION that cannot take this call — a
    // local `fun validate()` does not shadow the top-level `validate(block)`
    // for `validate { … }`, and routing through the captured self-cell made
    // the local call itself.
    const local_fn_takes_call = if (b.localFnDecls(name0)) |decls|
        try anyLocalFnOverloadApplicable(b, decls, args, ast_arg_names)
    else
        true;
    const shadowed_by_local = b.knowsOuter(name0) and b.resolve(name0) == null and
        b.module.funcId(name0) != null and local_fn_takes_call and
        // A captured local with definite NON-callable evidence (`var key = 0`
        // beside the `key(...) {}` composable) never serves a CALL — the
        // function wins, as in Kotlin.
        !b.isNonFnLocal(name0);
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

    // A renamed import whose exact overload is an ordinary function binds
    // directly.  This preserves an implicit extension receiver and is also
    // immune to unrelated same-simple-name globals. Inline targets stay with
    // the splice path because reification, suspension, and non-local returns
    // may require the source body at this call site.
    if (!shadowed_by_class and segments.len == 1 and
        !b.callableMemberApplicable(name0, args.len))
    {
        if (try renamedImportDirectTarget(b, segments[0], args, ast_arg_names)) |target| {
            const f = b.module.funcById(target) orelse return null;
            if (!f.is_inline) return try emitCall(b, expr, target, true);
        }
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
    // The import may name a whole OVERLOAD SET (five `remember`s share one
    // FQN): `funcIdByFqn` returns the first by declaration order, which can
    // be arity-incompatible with this call — a 4-key `remember(a,b,c,d){..}`
    // blind-bound the zero-key overload. A multi-overload FQN skips BOTH
    // import-routing arms and falls to the full resolver, whose overload
    // scoring ranks every sibling (vararg included) — and whose implicit-
    // receiver dispatch keeps a bare `launch {}` on the scope extension
    // instead of the qualified rewrite's non-extension guidance stub.
    var imported_fqn_multi = false;
    if (imported_func_id != null) {
        const alias_paths = b.module.importAliasPathsIn(segments[0].span.file, name0);
        if (alias_paths.len == 1) {
            var fqn_overloads: usize = 0;
            for (b.module.funcsBySimpleName(name0)) |cid| {
                if (b.module.funcById(cid)) |cf| {
                    if (std.mem.eql(u8, cf.fqn, alias_paths[0].fqn)) fqn_overloads += 1;
                }
            }
            imported_fqn_multi = fqn_overloads > 1;
        }
    }
    if (imported_func_id != null and imported_fqn_multi) {
        // fall through to the generic resolution below (skip both arms)
    } else if (imported_func_id) |func_id| {
        // An applicable extension on an in-scope implicit receiver outranks the
        // imported plain namesake: inside `validate { contact(c) }`
        // (`MockViewValidator.() -> Unit`), the imported `contact` FQN resolves
        // to the `@Composable contact`, but the receiver's
        // `MockViewValidator.contact` extension must win (Kotlin resolves the
        // implicit-receiver candidate group first). Defer to the member/
        // extension dispatch below when such an extension applies.
        if (!shadowed_by_class and !extOnEnclosingReceiverApplies(b, name0, args.len)) {
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
                const type_args = try helpers.internTypeArgsScoped(b, ast_type_args);
                const dst = b.allocReg();
                try b.push(.{ .Call = .{
                    .dst = dst,
                    .func = bind_id,
                    .trailing_lambda = b.callTrailingLambda(),
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

    // FQN-precedence for a UNIQUE import whose leaf has MULTIPLE overloads (or is
    // an intrinsic), so `funcIdByFqn` above found no single FuncId to route to.
    // `import kotlin.math.max` names 4+ overloads: the import is a real in-scope
    // symbol, but a same-name unimported `other.max(Dp, Dp)` can still preempt it
    // in the applicability/fallback ladder (body-bearing, while the intrinsic
    // overloads are unrankable header stubs). Re-lower the call qualified to the
    // imported FQN so overload resolution reaches the imported symbol, bypassing
    // the invisible candidate. Order-independent (decided from this file's imports)
    // and gated on the import actually naming in-scope funcs, so it never invents
    // a target.
    // An applicable function in the enclosing class hierarchy shadows a
    // top-level import. A same-named non-callable property does not participate
    // in call resolution, so it must not block the imported function.
    if (imported_func_id == null and !shadowed_by_class and segments.len == 1 and
        !b.callableMemberApplicable(name0, args.len))
    {
        const alias_paths = b.module.importAliasPathsIn(segments[0].span.file, name0);
        if (alias_paths.len == 1 and alias_paths[0].segs.len >= 2) {
            // A RENAMING import (`import a.b.f as g`) binds `g` with no
            // function of that simple name in the module: the qualified
            // rewrite is the only route to the target, and candidates are
            // enumerated under the TARGET leaf.
            const target_leaf = alias_paths[0].segs[alias_paths[0].segs.len - 1];
            const renamed = !std.mem.eql(u8, target_leaf, name0);
            const cand_name = if (renamed) target_leaf else name0;
            if (renamed or b.module.funcsBySimpleName(name0).len >= 1) {
                // The import resolves to real funcs of that FQN (a multi-overload
                // symbol), OR to a stdlib intrinsic the func index does not enumerate
                // (`isAliasName`, e.g. kotlin.math.max). Either way the qualified call
                // reaches it.
                var import_resolves = ir.isAliasName(cand_name);
                // An imported EXTENSION function (`RoundedPolygon.Companion.circle`)
                // called with no explicit receiver has no `this` to carry: the
                // qualified FQN rewrite would load it as a receiverless global and
                // miss. Only a plain top-level function (the `kotlin.math.max`
                // shape this rewrite exists for) qualifies; an FQN with several
                // overloads stays eligible while any non-extension one exists.
                var any_nonext = false;
                var any_fqn_match = false;
                var any_inline = false;
                for (b.module.funcsBySimpleName(cand_name)) |cid| {
                    const cf = b.module.funcById(cid) orelse continue;
                    if (std.mem.eql(u8, cf.fqn, alias_paths[0].fqn)) {
                        import_resolves = true;
                        any_fqn_match = true;
                        if (cf.is_inline) any_inline = true;
                        if (cf.params.len == 0 or !std.mem.eql(u8, cf.params[0].name, "this")) {
                            any_nonext = true;
                        }
                    }
                }
                const imp_is_extension = any_fqn_match and !any_nonext;
                // An INLINE target stays with the splice machinery (which
                // resolves aliases itself): rewriting `flow { ... }`
                // (`unsafeFlow as flow` in every kotlinx flow operator) to a
                // qualified CALL skips the splice, and the crossinline
                // block's bare `collect` then lowers in a plain-lambda
                // context and binds the wrong receiver.
                if (import_resolves and !imp_is_extension and !any_inline) {
                    const new_segs = try b.allocator.alloc(ast.Ident, alias_paths[0].segs.len);
                    for (alias_paths[0].segs, 0..) |s, i| new_segs[i] = .{ .name = s, .span = segments[0].span };
                    const new_callee = try b.allocator.create(Expr);
                    new_callee.* = Expr{ .Path = .{ .segments = new_segs, .span = callee.Path.span } };
                    var new_call = call;
                    new_call.callee = new_callee;
                    const rewritten = Expr{ .Call = new_call };
                    return try lowerCall(b, &rewritten);
                }
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
    var ctx = resolveCtxFor(b, name0, ast_type_args, cast_pick);
    ctx.nonlocal_return_lambda = inline_call.argLambdaHasNonlocalReturn(args) or blk: {
        // A spliced forwarder passes the original lambda along as a
        // parameter Path (`synchronized(lock, block)` inside another
        // inline wrapper): follow the splice's lambda-argument map so a
        // non-local `return` in the ORIGINAL literal still pins the
        // static inline resolution.
        for (args) |*a| {
            if (a.* != .Path or a.Path.segments.len != 1) continue;
            const lam = b.inlineLambdaFor(a.Path.segments[0].name) orelse continue;
            if (lam.* != .Lambda) continue;
            var one = [_]Expr{lam.*};
            if (inline_call.argLambdaHasNonlocalReturn(&one)) break :blk true;
        }
        break :blk false;
    };
    if (runtime.getenvSlice("KLIO_EF_TRACE")) |efw| {
        if (std.mem.eql(u8, efw, name0)) std.debug.print("[efset] nlr={} nargs={d} last_lambda={} file={d}\n", .{ ctx.nonlocal_return_lambda, args.len, lastArgIsLambda(args), segments[0].span.file.int() });
    }
    const res = try resolveCallWithComposerAbi(
        b,
        name0,
        segments[0].span.file,
        shapes,
        last_arg_lambda,
        ctx,
    );
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

    // An exact explicit import remains a static call after overload
    // resolution, even inside a captured receiver context, when that receiver
    // has no applicable member or extension of the imported name. The earlier
    // import fast path intentionally defers an overloaded FQN so the shared
    // resolver can choose its sibling; once that choice is made there is no
    // runtime member-vs-global decision left to perform.
    if (res_final.target) |target| static_import: {
        if (res_final.emit_form != .CallMemberOrGlobal or shadowed_by_class or
            segments.len != 1 or b.callableMemberApplicable(name0, args.len) or
            extOnEnclosingReceiverApplies(b, name0, args.len)) break :static_import;
        const paths = b.module.importAliasPathsIn(segments[0].span.file, name0);
        if (paths.len != 1) break :static_import;
        const f = b.module.funcById(target) orelse break :static_import;
        if (!std.mem.eql(u8, f.fqn, paths[0].fqn)) break :static_import;
        if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) break :static_import;
        res_final.emit_form = .Call;
        res_final.ty_proven = true;
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

    // KLIO_BARE_TRACE=<name>: print the static resolution for a bare call —
    // which overload bound (or that none did), the emit form, and the
    // receiver context the decision saw. The static complement of
    // KLIO_MISS_TRACE.
    if (runtime.getenvSlice("KLIO_BARE_TRACE")) |w| {
        if (std.mem.eql(u8, w, name0) and res_final.target == null) {
            std.debug.print("[bare] {s} -> NONE recv_ty={s} encl_recv={s} pkg={s} shadowed={}\n", .{
                name0,
                b.recvTy() orelse "-",
                b.enclosingRecvTy() orelse "-",
                b.self_package,
                shadowed_by_class,
            });
        }
    }
    if (res_final.target) |target| {
        if (runtime.getenvSlice("KLIO_BARE_TRACE")) |w| {
            if (std.mem.eql(u8, w, name0)) {
                const tfn = b.module.funcById(target);
                const tf = if (tfn) |f| f.fqn else "?";
                const np: usize = if (tfn) |f| f.params.len else 0;
                const is_ext_t = if (tfn) |f| f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this") else false;
                std.debug.print("[bare] {s} -> {s}#{d} params={d} ext={} form={s} recv_ty={s} encl_recv={s} pkg={s} shadowed={} at=f{d}:{d}\n", .{
                    name0,
                    tf,
                    target.int(),
                    np,
                    is_ext_t,
                    @tagName(res_final.emit_form),
                    b.recvTy() orelse "-",
                    b.enclosingRecvTy() orelse "-",
                    b.self_package,
                    shadowed_by_class,
                    @intFromEnum(segments[0].span.file),
                    segments[0].span.start,
                });
            }
        }
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
        .recv_type = b.recvTypeRef(),
        .is_value_capture = b.knowsOuter(name0) and b.resolve(name0) == null,
        .in_tailrec_body = b.tailrecSelf() != null,
        .owner_class = b.ownerClass(),
    };
}

/// Resolve a source-shaped call first, then retry with the hidden Compose ABI
/// only when the current function has a real threaded composer and ordinary
/// Kotlin resolution found no target. The retry must itself select a
/// declaration whose lowered signature proves the synthetic pair; this keeps
/// same-name non-composable overloads on the ordinary path.
fn resolveCallWithComposerAbi(
    b: *FuncBuilder,
    name: []const u8,
    caller_file: ir.FileId,
    shapes: []const applicability.ArgShape,
    last_arg_lambda: bool,
    ctx: ir.Module.ResolveCtx,
) Allocator.Error!ir.Module.Resolution {
    const direct = try b.module.resolveCall(
        b.allocator,
        name,
        b.self_package,
        caller_file,
        shapes,
        last_arg_lambda,
        ctx,
    );
    if (direct.target != null or b.resolve("$composer") == null or
        argShapesHaveComposerPair(shapes))
    {
        return direct;
    }

    const augmented = try b.allocator.alloc(applicability.ArgShape, shapes.len + 2);
    defer b.allocator.free(augmented);
    @memcpy(augmented[0..shapes.len], shapes);
    augmented[shapes.len] = .{ .named = "$composer" };
    augmented[shapes.len + 1] = .{
        .ty = build.typeInt(),
        .named = "$changed",
        .literal_kind = .numeric,
    };

    const threaded = try b.module.resolveCall(
        b.allocator,
        name,
        b.self_package,
        caller_file,
        augmented,
        false,
        ctx,
    );
    if (threaded.target) |target| {
        if (b.module.funcById(target)) |f| {
            if (selectedCallHasComposerAbi(b.module, target, f)) {
                b.allocator.free(direct.candidate_set);
                return threaded;
            }
        }
    }
    b.allocator.free(threaded.candidate_set);
    return direct;
}

fn argShapesHaveComposerPair(shapes: []const applicability.ArgShape) bool {
    if (shapes.len < 2) return false;
    const composer_name = shapes[shapes.len - 2].named orelse return false;
    const changed_name = shapes[shapes.len - 1].named orelse return false;
    return std.mem.eql(u8, composer_name, "$composer") and
        std.mem.eql(u8, changed_name, "$changed");
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
    // The index ranked at least one candidate in a visible tier (a named
    // import, own package, wildcard, or default import): the call resolves
    // among those in-scope candidates at runtime — a type-dispatched overload
    // set the runtime picks by argument types. A heuristic fallback that
    // happened to land on an invisible same-name namesake (e.g. Brush.kt's
    // `lerp(Offset, Offset, Float)` when many packs contribute out-of-scope
    // `lerp` overloads) does NOT make it an out-of-scope reference. Only a set
    // whose every rankable candidate is out of scope is genuinely unresolved.
    if (index_res.tier < ir.Module.other_package_tier) return false;
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
                name,                 b.self_package,                file.int(),
                want,                 @intFromBool(last_arg_lambda), outcome,
                reason,               idx_fqn,                       index_res.tier,
                index_res.tier_count, heur_fqn,                      @tagName(rung),
                shape,                @intFromBool(divergent),       @intFromBool(explained),
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
        (b.recvTy() != null and !fnTypedRecvCannotShadow(b, name)))
    {
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
        (b.recvTy() != null and !fnTypedRecvCannotShadow(b, name0)))
    {
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

const SelectedCallArgs = struct {
    args: []const Expr,
    names: []const ?[]const u8,
    owned_args: ?[]Expr = null,
    owned_names: ?[]?[]const u8 = null,
    owned_composer_path: ?[]ast.Ident = null,

    fn deinit(self: *SelectedCallArgs, allocator: Allocator) void {
        if (self.owned_args) |items| allocator.free(items);
        if (self.owned_names) |items| allocator.free(items);
        if (self.owned_composer_path) |items| allocator.free(items);
        self.* = .{ .args = &.{}, .names = &.{} };
    }
};

fn hasThreadedComposerParams(f: *const Func) bool {
    if (f.params.len < 2) return false;
    return std.mem.eql(u8, f.params[f.params.len - 2].name, "$composer") and
        std.mem.eql(u8, f.params[f.params.len - 1].name, "$changed");
}

fn sameDeclSig(a: ir.Module.DeclSig, b: ir.Module.DeclSig) bool {
    if (a.kind != b.kind or
        a.arity.required != b.arity.required or
        a.arity.total != b.arity.total or
        a.arity.has_vararg != b.arity.has_vararg or
        a.sig.len != b.sig.len)
    {
        return false;
    }
    if ((a.enclosing_class == null) != (b.enclosing_class == null)) return false;
    if (a.enclosing_class) |ac| {
        if (ac.int() != b.enclosing_class.?.int()) return false;
    }
    if ((a.receiver_ty == null) != (b.receiver_ty == null)) return false;
    if (a.receiver_ty) |ar| {
        if (!ar.eql(b.receiver_ty.?)) return false;
    }
    for (a.sig, b.sig) |ap, bp| {
        if (!ap.eql(bp)) return false;
    }
    return true;
}

/// Whether the declaration selected during lowering has the transformed
/// Compose call ABI. A reserved declaration header retains the source
/// parameter list while its body-carrying sibling owns the synthetic tail, so
/// match that sibling by the canonical declaration signature rather than by
/// simple name.
fn selectedCallHasComposerAbi(module: *const Module, func_id: FuncId, f: *const Func) bool {
    if (hasThreadedComposerParams(f)) return true;
    for (f.annotation_names) |ann| {
        if (std.mem.eql(u8, ann, "Composable") or std.mem.endsWith(u8, ann, ".Composable")) return true;
    }
    const selected_sig = module.decl_sigs.get(func_id.int()) orelse return false;
    for (module.funcsBySimpleName(f.name)) |candidate_id| {
        if (candidate_id.int() == func_id.int()) continue;
        const candidate = module.funcById(candidate_id) orelse continue;
        if (!hasThreadedComposerParams(candidate)) continue;
        if (!std.mem.eql(u8, candidate.fqn, f.fqn)) continue;
        const candidate_sig = module.decl_sigs.get(candidate_id.int()) orelse continue;
        if (sameDeclSig(selected_sig, candidate_sig)) return true;
    }
    return false;
}

fn selectedCallArgs(module: *const Module, func_id: FuncId, args: []const Expr, names: []const ?[]const u8) SelectedCallArgs {
    if (args.len < 2 or names.len != args.len) return .{ .args = args, .names = names };
    const composer_name = names[names.len - 2] orelse return .{ .args = args, .names = names };
    const changed_name = names[names.len - 1] orelse return .{ .args = args, .names = names };
    if (!std.mem.eql(u8, composer_name, "$composer") or
        !std.mem.eql(u8, changed_name, "$changed"))
    {
        return .{ .args = args, .names = names };
    }
    const f = module.funcById(func_id) orelse return .{ .args = args, .names = names };
    if (selectedCallHasComposerAbi(module, func_id, f)) return .{ .args = args, .names = names };
    return .{
        .args = args[0 .. args.len - 2],
        .names = names[0 .. names.len - 2],
    };
}

fn hasComposerArgPair(names: []const ?[]const u8) bool {
    if (names.len < 2) return false;
    const composer_name = names[names.len - 2] orelse return false;
    const changed_name = names[names.len - 1] orelse return false;
    return std.mem.eql(u8, composer_name, "$composer") and
        std.mem.eql(u8, changed_name, "$changed");
}

/// Complete the exact selected Compose ABI from the current lowered scope.
/// The AST pass normally supplies this pair, but a cross-pack caller may have
/// been transformed before the callee joined its simple-name oracle. The
/// selected declaration and the synthesized `$composer` binding are direct
/// evidence, so emission can still produce the same static call.
fn selectedCallArgsForBuilder(
    b: *FuncBuilder,
    func_id: FuncId,
    args: []const Expr,
    names: []const ?[]const u8,
    call_span: ast.Span,
) Allocator.Error!SelectedCallArgs {
    var selected = selectedCallArgs(b.module, func_id, args, names);
    if (hasComposerArgPair(selected.names)) return selected;
    const f = b.module.funcById(func_id) orelse return selected;
    if (!selectedCallHasComposerAbi(b.module, func_id, f) or b.resolve("$composer") == null) return selected;

    const completed_args = try b.allocator.alloc(Expr, selected.args.len + 2);
    errdefer b.allocator.free(completed_args);
    @memcpy(completed_args[0..selected.args.len], selected.args);
    const composer_path = try b.allocator.alloc(ast.Ident, 1);
    errdefer b.allocator.free(composer_path);
    composer_path[0] = .{ .name = "$composer", .span = call_span };
    completed_args[selected.args.len] = .{ .Path = .{ .segments = composer_path, .span = call_span } };
    completed_args[selected.args.len + 1] = .{ .IntLit = .{ .value = 0, .kind = .Int, .span = call_span } };

    const completed_names = try b.allocator.alloc(?[]const u8, selected.names.len + 2);
    errdefer b.allocator.free(completed_names);
    @memcpy(completed_names[0..selected.names.len], selected.names);
    completed_names[selected.names.len] = "$composer";
    completed_names[selected.names.len + 1] = "$changed";

    selected.owned_args = completed_args;
    selected.owned_names = completed_names;
    selected.owned_composer_path = composer_path;
    selected.args = completed_args;
    selected.names = completed_names;
    return selected;
}

/// The `Call` emit form: a resolved bare-name static call. A committed
/// non-extension target lowers to a direct `Call` (or a `TailCallFunc` in a
/// tailrec body); an extension target routes through `emitExtBareCall`, which
/// prepends `this`. `resolveCall` has already decided this is a static call, so
/// the member-vs-global walk lives in `emitMemberOrGlobal`, not here.
fn emitCall(b: *FuncBuilder, expr: *const Expr, func_id: FuncId, was_cast: bool) Allocator.Error!Reg {
    const call = expr.Call;
    if (runtime.getenvSlice("KLIO_EMIT_TRACE") != null) {
        const c0 = call.callee;
        if (c0.* == .Path and c0.Path.segments.len == 1 and std.mem.eql(u8, c0.Path.segments[0].name, "remember") and @intFromEnum(c0.Path.segments[0].span.file) == 0) {
            std.debug.print("[emitCall] remember -> #{d} nargs={d}\n", .{ func_id.int(), call.args.len });
            runtime.trace.dumpCurrent(.{});
        }
    }
    const prev_trailing = b.setCallTrailingLambda(call.has_trailing_lambda);
    defer _ = b.setCallTrailingLambda(prev_trailing);
    var selected_args = try selectedCallArgsForBuilder(b, func_id, call.args, call.arg_names, exprSpan(call.callee));
    defer selected_args.deinit(b.allocator);
    const args = selected_args.args;
    const ast_arg_names = selected_args.names;
    const ast_type_args = call.type_args;

    // The committed target is overload-precise, so its receiver-function
    // parameter types are authoritative even when the source callee is an
    // alias with no same-named entry in the function index.
    if (b.module.funcById(func_id)) |f| {
        const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        try recordLambdaArgReceivers(b, f, args, ast_arg_names, ast_type_args, recv_off);
    }

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
    const lambda_param_types: ?[]?[]ir.TypeRef = blk: {
        const f = b.module.funcById(func_id) orelse break :blk null;
        const recv_off: usize = if (f.params.len != 0 and
            std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        break :blk try argLambdaParamTypes(
            b,
            f,
            args,
            ast_arg_names,
            ast_type_args,
            recv_off,
        );
    };
    defer if (lambda_param_types) |types|
        deinitArgLambdaParamTypes(b.allocator, types);
    b.pending_arg_lambda_param_types = lambda_param_types;
    const run = try lowerArgRunFull(b, args, arg_arity, param_ty_names);
    // A trailing lambda always binds the target's last (function-typed)
    // parameter. When a vararg parameter precedes it, positional binding
    // would otherwise pack the lambda into the vararg and leave the last
    // parameter unfilled (Kotlin forbids a positional argument after a
    // vararg, so the trailing lambda is the only filler). Name the lambda
    // to the last parameter so the runtime binds it correctly.
    const arg_names = try trailingLambdaArgNames(b, func_id, args, ast_arg_names);
    var type_args = try helpers.internTypeArgsScoped(b, ast_type_args);
    if (type_args.len == 0) {
        if (try spliceReifiedTypeArgs(b, func_id)) |stamped| type_args = stamped;
    }
    const dst = b.allocReg();
    try b.push(.{ .Call = .{
        .dst = dst,
        .func = func_id,
        .trailing_lambda = b.callTrailingLambda(),
        .args = run[0],
        .n_args = run[1],
        .arg_names = arg_names,
        .type_args = type_args,
        .exact = was_cast,
    } });
    return dst;
}

/// Sibling-arg reified inference: when an argument of a resolved call is
/// itself a bare 0-arg call to a single-type-param fn with no type args
/// (`enumEntries()`), and a SIBLING argument bound to the same declared
/// type variable statically names an enum (`EmptyEnum.entries`,
/// `EmptyEnum.values().toList()`), the enum solves the nested call's
/// reified argument. Records the solution keyed by the nested call's AST
/// node; `emitCall` consumes it when that node lowers with no type args
/// of its own.
/// `::name` in a slot whose DECLARED function type solves the referenced
/// fn's single reified type parameter (`val empty: () -> EnumEntries<E> =
/// ::enumEntries`): the reference lowers as a zero-arg closure over the
/// call with the solved type argument stamped — a plain function value
/// carries no type args, so invoking it later would lose the reification.
/// AST synthesized from the MODULE allocator (lambda bodies are
/// runtime-read).
fn reifiedRefClosure(b: *FuncBuilder, name: []const u8, sp: ast.Span) Allocator.Error!?Reg {
    const expected = b.peekExpected() orelse return null;
    const fnty = expected.function orelse return null;
    if (fnty.params.len != 0) return null;
    if (fnty.ret.type_args.len != 1) return null;
    const fid = b.module.funcId(name) orelse return null;
    const tps = b.module.registry.func_type_params.get(fid) orelse return null;
    if (tps.items.len != 1) return null;
    const ma = b.module.func_name_index.allocator;
    const segs = try ma.alloc(ast.Ident, 1);
    segs[0] = .{ .name = try ma.dupe(u8, name), .span = sp };
    const callee = try ma.create(ast.Expr);
    callee.* = .{ .Path = .{ .segments = segs, .span = sp } };
    const ta = try ma.alloc(ast.TypeRef, 1);
    ta[0] = fnty.ret.type_args[0].ty;
    const stmts = try ma.alloc(ast.Stmt, 1);
    stmts[0] = .{ .Expr = .{ .Call = .{
        .callee = callee,
        .args = &.{},
        .arg_names = &.{},
        .type_args = ta,
        .is_infix = false,
        .span = sp,
    } } };
    const lam: ast.Expr = .{ .Lambda = .{
        .params = &.{},
        .body = .{ .stmts = stmts, .span = sp },
        .span = sp,
        .implicit_it = false,
    } };
    const boxed = try ma.create(ast.Expr);
    boxed.* = lam;
    return try lowerExpr(b, boxed);
}

const SibSolved = struct { site: *const Expr, ty: ast.TypeRef };

fn solveSiblingExpected(b: *FuncBuilder, callee: *const Expr, args: []const Expr) ?SibSolved {
    if (callee.* != .Path or callee.Path.segments.len != 1) return null;
    if (args.len < 2) return null;
    const outer_name = callee.Path.segments[0].name;
    var outer: ?*const ir.Func = null;
    for (b.module.funcsBySimpleName(outer_name)) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        if (f.params.len == args.len or (f.params.len > args.len and f.params.len - args.len <= 1)) {
            outer = f;
            break;
        }
    }
    const f = outer orelse return null;
    const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
    for (args, 0..) |*arg, j| {
        if (arg.* != .Call) continue;
        const c = arg.Call;
        if (c.type_args.len != 0 or c.args.len != 0) continue;
        if (c.callee.* != .Path or c.callee.Path.segments.len != 1) continue;
        const nested_name = c.callee.Path.segments[0].name;
        const nested_fid = b.module.funcId(nested_name) orelse continue;
        const tps = b.module.registry.func_type_params.get(nested_fid) orelse continue;
        if (tps.items.len != 1) continue;
        const nested_f = b.module.funcById(nested_fid) orelse continue;
        // The lowered ir return type keeps only the head (`EnumEntries`);
        // the splice unifies against the AST declaration's full
        // `Head<T>`, so the head is all the expected type needs here.
        if (nested_f.return_ty.name.len == 0) continue;
        const pj = recv_off + j;
        if (pj >= f.params.len) continue;
        const tv = f.params[pj].ty.name;
        // The declared param type must be a bare type variable shared with
        // a sibling (`assertEquals(expected: T, actual: T)`).
        if (tv.len > 2 or !allUppercase(tv)) continue;
        for (args, 0..) |*sib, k| {
            if (k == j) continue;
            const pk = recv_off + k;
            if (pk >= f.params.len) continue;
            if (!std.mem.eql(u8, f.params[pk].ty.name, tv)) continue;
            const enum_name = staticEnumElem(b, sib) orelse continue;
            // Build `Head<Enum>` as the nested call's expected type; the
            // inline splice's return-type unification (the existing
            // reified oracle) solves T from it.
            var head = nested_f.return_ty.name;
            if (std.mem.lastIndexOfScalar(u8, head, '.')) |i| head = head[i + 1 ..];
            const sp = c.callee.Path.segments[0].span;
            const ta = b.allocator.alloc(ast.TypeArg, 1) catch return null;
            ta[0] = .{
                .variance = .Invariant,
                .is_star = false,
                .ty = .{ .name = .{ .name = enum_name, .span = sp }, .nullable = false, .span = sp, .type_args = &.{}, .function = null, .definitely_non_null = false, .annotations = &.{}, .qualified_path = null },
                .span = sp,
            };
            return .{ .site = arg, .ty = .{ .name = .{ .name = head, .span = sp }, .nullable = false, .span = sp, .type_args = ta, .function = null, .definitely_non_null = false, .annotations = &.{}, .qualified_path = null } };
        }
    }
    return null;
}

/// The enum class statically named by an expression's element type:
/// `E.entries` and `E.values().toList()` both yield `E` when `E` resolves
/// to a registered enum class.
fn staticEnumElem(b: *FuncBuilder, e: *const Expr) ?[]const u8 {
    switch (e.*) {
        .Member => |m| {
            if (std.mem.eql(u8, m.name.name, "entries")) return enumClassOfPath(b, m.receiver);
            return null;
        },
        .Call => |c| {
            if (c.callee.* != .Member) return null;
            const outer_m = c.callee.Member;
            if (!std.mem.eql(u8, outer_m.name.name, "toList")) return null;
            if (outer_m.receiver.* != .Call) return null;
            const inner = outer_m.receiver.Call;
            if (inner.callee.* != .Member) return null;
            const vm = inner.callee.Member;
            if (!std.mem.eql(u8, vm.name.name, "values")) return null;
            return enumClassOfPath(b, vm.receiver);
        },
        else => return null,
    }
}

fn enumClassOfPath(b: *FuncBuilder, e: *const Expr) ?[]const u8 {
    var name: []const u8 = undefined;
    var qual_cid: ?ir.ClassId = null;
    var owner_hint: ?[]const u8 = null;
    switch (e.*) {
        .Path => |p| {
            name = p.segments[p.segments.len - 1].name;
            // A qualified nested reference (`EnumEntriesListTest.EmptyEnum`)
            // must bind THAT nested class — the simple name may collide
            // with an unrelated top-level or sibling-nested enum.
            if (p.segments.len >= 2) {
                const owner_name = p.segments[p.segments.len - 2].name;
                owner_hint = owner_name;
                if (b.module.classId(owner_name)) |oid| {
                    qual_cid = b.module.classIdNestedIn(oid, name);
                }
            }
        },
        .Member => |m| {
            name = m.name.name;
            if (m.receiver.* == .Path and m.receiver.Path.segments.len >= 1) {
                const owner_name = m.receiver.Path.segments[m.receiver.Path.segments.len - 1].name;
                owner_hint = owner_name;
                if (b.module.classId(owner_name)) |oid| {
                    qual_cid = b.module.classIdNestedIn(oid, name);
                }
            } else if (m.receiver.* == .Member) {
                owner_hint = m.receiver.Member.name.name;
            }
        },
        else => return null,
    }
    if (qual_cid) |cid| {
        if (cid.int() < b.module.classes.items.len) {
            // The registered (lifted) name is what the runtime type-arg
            // lookup resolves — already unique, so no owner qualification
            // on top (a mangled `EnumEntriesListTest$EmptyEnum` must not
            // stamp as `EnumEntriesListTest.EnumEntriesListTest$EmptyEnum`).
            name = b.module.classes.items[cid.int()].name;
            if (std.mem.indexOfScalar(u8, name, '$') != null) owner_hint = null;
        }
    }
    // A nested-enum reference whose class lifted under a mangled name
    // resolves through the rename: a QUALIFIED reference through its
    // owner's alias table (`EnumEntriesListTest.EmptyEnum` ->
    // `EnumEntriesListTest$EmptyEnum`), a bare one through the lexical
    // scope-rename ladder (`EmptyEnum` -> `EnumEntriesFactoryTest$EmptyEnum`).
    if (b.module.classId(name) == null) {
        if (owner_hint) |o| {
            if (b.module.registry.nested_object_aliases.get(o)) |m| {
                if (m.get(name)) |rn| {
                    name = rn;
                    owner_hint = null;
                }
            }
        } else if (scopeTypeRename(b, name, e.span().file.int())) |rn| {
            name = rn;
        }
    }
    if (b.module.classId(name) == null) return null;
    // Enum-ness at lowering: the recorded supertype chain carries
    // `Enum` for every enum class (the implicit supertype is recorded at
    // class lowering).
    const chain = b.module.registry.class_super_names.get(name) orelse return null;
    for (chain) |sup| {
        var sn = sup;
        if (std.mem.lastIndexOfScalar(u8, sn, '.')) |i| sn = sn[i + 1 ..];
        if (std.mem.indexOfScalar(u8, sn, '<')) |lt| sn = sn[0..lt];
        if (!std.mem.eql(u8, sn, "Enum")) continue;
        // A qualified reference stamps the owner-qualified name: the
        // simple name may collide with an unrelated same-named enum, and
        // the runtime resolves the dotted form through the lifted
        // nested-class key.
        if (owner_hint) |o| {
            return std.fmt.allocPrint(b.module.func_name_index.allocator, "{s}.{s}", .{ o, name }) catch name;
        }
        return name;
    }
    return null;
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
    var selected_args = try selectedCallArgsForBuilder(b, func_id, call.args, call.arg_names, exprSpan(callee));
    defer selected_args.deinit(b.allocator);
    const args = selected_args.args;
    const ast_arg_names = selected_args.names;
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
    var type_args = try helpers.internTypeArgsScoped(b, ast_type_args);
    // The deferred form keeps the reified splice substitution too: a
    // spliced `enumEntriesIntrinsic()` lowered in a receiver context
    // (a lambda body) is otherwise blind at the runtime intrinsic.
    if (type_args.len == 0) {
        if (try spliceReifiedTypeArgs(b, func_id)) |stamped| type_args = stamped;
    }
    try b.push(.{ .CallMemberOrGlobal = .{
        .dst = dst,
        .this_idx = this_idx,
        .name = nm,
        .trailing_lambda = b.callTrailingLambda(),
        .args = run[0],
        .n_args = run[1],
        .arg_names = arg_names,
        .func = func_id,
        .candidates = try cmgCandidates(b, name0, callee.Path.segments[0].span.file, run[1]),
        .static_recv = cmg_static_recv,
        .type_args = type_args,
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
    if (nestedClassIdAtLexicalSite(b, name0)) |cid| return cid;
    if (b.module.classIdExactImport(name0, file)) |cid| return cid;
    // A receiver context whose owner chain is unknown here (a super-arg /
    // default-value thunk, a lambda) may still see a NESTED classifier the
    // flat index cannot rank; committing the package-scope pick would
    // override the runtime's scope walk with the wrong declaration
    // (CoroutineContext.Key shadowing a nested `object Key`). Decline —
    // the name-keyed runtime path owns the scoped resolution.
    if (inReceiverContext(b)) return null;
    return b.module.classIdIndexed(name0, b.self_package, file);
}

/// The class visible at a lexical source site without the receiver-context
/// decline used by an immediately-lowered read. Anonymous-object bodies use
/// this before moving into their registry-free side modules.
fn classIdAtLexicalSite(b: *FuncBuilder, name0: []const u8, file: anytype) ?ir.ClassId {
    if (nestedClassIdAtLexicalSite(b, name0)) |cid| return cid;
    if (b.module.classIdExactImport(name0, file)) |cid| return cid;
    return b.module.classIdIndexed(name0, b.self_package, file);
}

fn nestedClassIdAtLexicalSite(b: *FuncBuilder, name0: []const u8) ?ir.ClassId {
    if (b.ownerClass()) |oc| {
        // Resolve the OWNER to an id once (its lifted simple name is in the
        // class index), then answer through the nesting tree — the one
        // scoped classifier lookup, no string-mangled probing.
        if (b.module.classId(oc)) |owner_id| {
            if (b.module.classIdNestedIn(owner_id, name0)) |cid| return cid;
            // The nesting tree (`class_children`) is built at VM setup, AFTER
            // this lowering runs for a baked pack's bodies, so it can be empty
            // here. Derive the nesting directly from FQNs (which `classIdByFqn`
            // resolves without the tree): a bare `Nested` inside `a.b.Outer`
            // resolves to `a.b.Outer.Nested`, walking up the enclosing-class
            // FQNs so a reference to an outer-scope nested class still binds.
            if (b.module.classFqnById(owner_id)) |ofqn| {
                var pfqn: []const u8 = ofqn;
                var hops: usize = 0;
                while (hops < 16) : (hops += 1) {
                    const cand = std.fmt.allocPrint(b.allocator, "{s}.{s}", .{ pfqn, name0 }) catch break;
                    defer b.allocator.free(cand);
                    if (b.module.classIdByFqn(cand)) |cid| return cid;
                    const dot = std.mem.lastIndexOfScalar(u8, pfqn, '.') orelse break;
                    pfqn = pfqn[0..dot];
                    if (b.module.classIdByFqn(pfqn) == null) break; // left the class nest
                }
            }
        }
    }
    return null;
}

fn cmgStaticRecv(b: *FuncBuilder) Allocator.Error!?ConstId {
    const rt = b.recvTy() orelse return null;
    return try b.module.internConst(b.allocator, .{ .String = rt });
}

/// Package/import-scoped declarations carried by a deferred bare call. The
/// optional distinction is intentional: null means the remaining host-only or
/// incomplete-header boundary has no rankable declaration metadata; a non-null
/// (possibly empty) slice is authoritative and prevents the runtime from
/// widening back to the program-wide simple-name index.
fn cmgCandidates(b: *FuncBuilder, name: []const u8, file: ir.FileId, user_arg_count: usize) Allocator.Error!?[]const FuncId {
    return b.module.boundedCallCandidates(b.allocator, name, b.self_package, file, user_arg_count);
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
    const type_args = try helpers.internTypeArgsScoped(b, ast_type_args);
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

fn emitObjectValueCall(
    b: *FuncBuilder,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
    ast_type_args: []const ast.TypeRef,
    name0: []const u8,
    class_id: ir.ClassId,
) Allocator.Error!Reg {
    orEmitAudit(b, "object_operator_call", "LoadGlobal", name0);
    const callee_r = b.allocReg();
    const identity = b.module.classFqnById(class_id) orelse name0;
    const nm = try b.module.internConst(b.allocator, .{ .String = identity });
    try b.push(.{ .LoadGlobal = .{ .dst = callee_r, .name = nm, .class = class_id } });
    const run = try lowerArgRun(b, args);
    const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
    const type_args = try helpers.internTypeArgsScoped(b, ast_type_args);
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
    if (b.module.funcById(func_id)) |f| {
        if (threadedTrailingLambdaParam(f, args, ast_arg_names)) |hit| {
            const tagged = try internArgNames(b.allocator, b.module, ast_arg_names);
            tagged[hit.arg_index] = try b.module.internConst(b.allocator, .{ .String = hit.param_name });
            return tagged;
        }
    }
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

const ThreadedTrailingLambda = struct {
    arg_index: usize,
    param_name: []const u8,
};

/// The source trailing lambda immediately before the Compose synthetic pair
/// binds the selected declaration's last user parameter. The AST pass appends
/// the pair and clears `has_trailing_lambda`, so carrying this exact parameter
/// name into IR preserves Kotlin's across-default binding.
fn threadedTrailingLambdaParam(
    f: *const Func,
    args: []const Expr,
    names: []const ?[]const u8,
) ?ThreadedTrailingLambda {
    if (!hasThreadedComposerParams(f) or args.len < 3 or names.len != args.len) return null;
    const composer_name = names[names.len - 2] orelse return null;
    const changed_name = names[names.len - 1] orelse return null;
    if (!std.mem.eql(u8, composer_name, "$composer") or
        !std.mem.eql(u8, changed_name, "$changed"))
    {
        return null;
    }
    const arg_index = args.len - 3;
    if (args[arg_index] != .Lambda or names[arg_index] != null) return null;
    const user_param_end = f.params.len - 2;
    if (user_param_end == 0) return null;
    const param = &f.params[user_param_end - 1];
    if (!std.mem.startsWith(u8, param.ty.name, "Function")) return null;
    return .{ .arg_index = arg_index, .param_name = param.name };
}

/// The extension-fn bare-call path: prepend `this`, with trailing-lambda
/// arg-name synthesis and the member-precedence routing.
fn emitExtBareCall(b: *FuncBuilder, expr: *const Expr, func_id: FuncId, this_reg: Reg, was_cast: bool) Allocator.Error!Reg {
    const call = expr.Call;
    const callee = call.callee;
    var selected_args = try selectedCallArgsForBuilder(b, func_id, call.args, call.arg_names, exprSpan(callee));
    defer selected_args.deinit(b.allocator);
    const args = selected_args.args;
    const ast_arg_names = selected_args.names;
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
    const type_args = try helpers.internTypeArgsScoped(b, ast_type_args);

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
            .trailing_lambda = b.callTrailingLambda(),
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
        .trailing_lambda = b.callTrailingLambda(),
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

/// Resolve an own private method against the complete predeclared overload
/// set. Private members cannot be overridden, so a unique applicability winner
/// is a direct target even when its declaration appears after the caller.
fn resolvePrivateMemberCall(
    b: *FuncBuilder,
    name: []const u8,
    file: ir.FileId,
    args: []const Expr,
    arg_names: []const ?[]const u8,
) Allocator.Error!Module.MemberResolution {
    const owner_name = b.ownerClass() orelse return .{};
    const owner_id = b.module.classIdIndexed(owner_name, b.self_package, file) orelse
        b.module.classId(owner_name) orelse return .{};
    if (owner_id.int() >= b.module.classes.items.len) return .{};
    const shapes = try buildStaticArgShapes(b, args, arg_names);
    defer b.allocator.free(shapes);
    return b.module.resolveMemberCall(owner_id, name, shapes, .{
        .lexical_owner = owner_id,
        .private_only = true,
    });
}

/// Inside a method body: unqualified `name(...)` is a method call on `this`.
fn lowerImplicitThisCall(
    b: *FuncBuilder,
    callee: *const Expr,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
    ast_type_args: []const ast.TypeRef,
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

    const member_lambda_shape: ?ir.ModuleRegistry.MemberTrailingLambdaShape = if (allNull(ast_arg_names) and lastArgIsLambda(args))
        predeclaredMemberTrailingLambdaShape(b, name0, args.len)
    else
        null;
    const member_lambda_fid: ?FuncId = if (allNull(ast_arg_names) and lastArgIsLambda(args))
        memberHostingTrailingLambda(b, name0, args.len)
    else
        null;

    // Broad-collection mask: a trailing lambda bound to this member's
    // function-typed parameter whose declared type is `Iterable`/`Collection`
    // marks the lambda's matching params broad, so `it + x` over a runtime
    // `Set` yields a `List` (the declared, not runtime, receiver type).
    const itc_broad: ?[]u32 = blk: {
        const fid = member_lambda_fid orelse break :blk null;
        const f = b.module.funcById(fid) orelse break :blk null;
        const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        break :blk try argLambdaBroadMasks(b, f, args, ast_arg_names, recv_off);
    };
    defer if (itc_broad) |m| b.allocator.free(m);

    // Private own-class methods bind to their stable declaration identity.
    const private_resolution = try resolvePrivateMemberCall(
        b,
        name0,
        segments[0].span.file,
        args,
        ast_arg_names,
    );
    if (private_resolution.dispatch == .direct and ast_type_args.len == 0) {
        const fid = private_resolution.target.?;
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
        defer if (priv_arity) |arities| b.allocator.free(arities);
        const priv_fn_generic: ?[]bool = if (b.module.funcById(fid)) |pf|
            (try argFnGenericFlags(b, pf, args, ast_arg_names, if (pf.params.len != 0 and std.mem.eql(u8, pf.params[0].name, "this")) 1 else 0))
        else
            null;
        defer if (priv_fn_generic) |m| b.allocator.free(m);
        b.pending_arg_fn_generic = priv_fn_generic;
        const priv_lambda_param_types: ?[]?[]ir.TypeRef = if (b.module.funcById(fid)) |pf|
            (try argLambdaParamTypes(
                b,
                pf,
                args,
                ast_arg_names,
                ast_type_args,
                if (pf.params.len != 0 and
                    std.mem.eql(u8, pf.params[0].name, "this")) 1 else 0,
            ))
        else
            null;
        defer if (priv_lambda_param_types) |types|
            deinitArgLambdaParamTypes(b.allocator, types);
        b.pending_arg_lambda_param_types = priv_lambda_param_types;
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
            .trailing_lambda = b.callTrailingLambda(),
            .args = args_start,
            .n_args = run[1] + 1,
            .arg_names = arg_names,
            .type_args = &.{},
            .exact = true,
        } });
        return dst;
    }
    b.pending_arg_broad_masks = itc_broad;
    var member_arity: ?[]i16 = null;
    var member_fn_generic: ?[]bool = null;
    var member_lambda_param_types: ?[]?[]ir.TypeRef = null;
    const member_signature_fid = private_resolution.target orelse member_lambda_fid;
    if (member_signature_fid) |fid| {
        if (b.module.funcById(fid)) |f| {
            const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
            try recordLambdaArgReceivers(b, f, args, ast_arg_names, ast_type_args, recv_off);
            member_arity = try argFnArities(b, f, args, ast_arg_names, recv_off);
            member_fn_generic = try argFnGenericFlags(
                b,
                f,
                args,
                ast_arg_names,
                recv_off,
            );
            member_lambda_param_types = try argLambdaParamTypes(
                b,
                f,
                args,
                ast_arg_names,
                ast_type_args,
                recv_off,
            );
        }
    }
    if (member_lambda_shape) |shape| {
        if (member_arity == null) {
            const out = try b.allocator.alloc(i16, args.len);
            for (out) |*arity| arity.* = -1;
            member_arity = out;
        }
        member_arity.?[member_arity.?.len - 1] = shape.value_arity;
        const trailing = &args[args.len - 1];
        b.recordLambdaArgArity(trailing.span(), shape.value_arity);
        if (shape.receiver_head) |recv| {
            try b.recordLambdaArgRecvOwned(
                trailing.span(),
                try (ir.TypeRef{
                    .name = recv,
                    .nullable = false,
                    .args = &.{},
                }).clone(b.allocator),
            );
        }
    }
    defer if (member_arity) |arities| b.allocator.free(arities);
    defer if (member_fn_generic) |flags| b.allocator.free(flags);
    defer if (member_lambda_param_types) |types|
        deinitArgLambdaParamTypes(b.allocator, types);
    b.pending_arg_fn_generic = member_fn_generic;
    b.pending_arg_lambda_param_types = member_lambda_param_types;
    const run = try lowerArgRunWithArity(b, args, member_arity);
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
            .trailing_lambda = b.callTrailingLambda(),
            .args = run[0],
            .n_args = run[1],
            .arg_names = arg_names,
            .candidates = try cmgCandidates(b, name0, callee.Path.segments[0].span.file, run[1]),
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
        const type_args = try helpers.internTypeArgsScoped(b, ast_type_args);
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
        const type_args = try helpers.internTypeArgsScoped(b, ast_type_args);
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
        const type_args0 = try helpers.internTypeArgsScoped(b, ast_type_args);
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
            .trailing_lambda = b.callTrailingLambda(),
            .args = run[0],
            .n_args = run[1],
            .arg_names = arg_names,
            .recv = this_reg,
            .func = static_ext,
            .candidates = try cmgCandidates(b, name0, callee.Path.segments[0].span.file, run[1]),
            .static_recv = try cmgStaticRecv(b),
            .type_args = try helpers.internTypeArgsScoped(b, ast_type_args),
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
        .trailing_lambda = b.callTrailingLambda(),
        .args = run[0],
        .n_args = run[1],
        .arg_names = arg_names,
        .candidates = try cmgCandidates(b, name0, callee.Path.segments[0].span.file, run[1]),
        .static_recv = try cmgStaticRecv(b),
        .type_args = try helpers.internTypeArgsScoped(b, ast_type_args),
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

/// Package-qualified constructor call: the dotted callee (`app.sub.Widget()`)
/// names a class by its fully-qualified name. Rewrite it to a bare constructor
/// call on the class's simple name so the ordinary class-name path constructs
/// it — otherwise the member fallback reads the package head as a field of the
/// implicit receiver. Only fires when the head is genuinely a package (not a
/// local/captured/enclosing-member in scope) and the FQN names a class.
fn lowerFqnCtorCall(b: *FuncBuilder, expr: *const Expr) Allocator.Error!?Reg {
    const callee = expr.Call.callee;
    const fqn = (try collectDottedFqn(b.allocator, callee)) orelse return null;
    defer b.allocator.free(fqn);
    const tail = rsplitLast(fqn, '.');
    if (std.mem.eql(u8, tail, fqn)) return null; // not dotted
    const cid = b.module.classIdByFqn(fqn) orelse return null; // FQN is not a class
    const head = firstSegment(fqn);
    // The head must be a real package the reference qualifies through, not a
    // name that resolves in scope (which would be a member/local access).
    if (!headIsPackage(b, head)) return null;
    if (b.resolve(head) != null or b.knowsOuter(head) or b.hasEnclosingMember(head)) return null;
    if (b.module.classId(head) != null) return null; // head names a class: nested-class path handles it
    // Construct the EXACT class the FQN names. Rewriting to the bare simple
    // name and re-lowering would re-resolve it by simple name and pick the
    // first same-named class from another package (`gapbuffer.SlotTable` vs
    // `linkbuffer.SlotTable`) — the package qualifier must decide.
    const args = expr.Call.args;
    const ast_arg_names = expr.Call.arg_names;
    const ctor_arity = try ctorArgFnArities(b, cid, args, ast_arg_names);
    defer if (ctor_arity) |ca| b.allocator.free(ca);
    const run = try lowerArgRunFull(b, args, ctor_arity, null);
    const realigned = try ctorRealignedArgNames(b, cid, args, ast_arg_names);
    defer if (realigned) |r| b.allocator.free(r);
    const arg_names = try internArgNames(b.allocator, b.module, realigned orelse ast_arg_names);
    const dst = b.allocReg();
    try b.push(.{ .NewInstance = .{
        .dst = dst,
        .class = cid,
        .args = run[0],
        .n_args = run[1],
        .arg_names = arg_names,
    } });
    return dst;
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
            const type_args = try helpers.internTypeArgsScoped(b, ast_type_args);
            const dst = b.allocReg();
            try b.push(.{ .Call = .{
                .dst = dst,
                .func = func_id,
                .trailing_lambda = b.callTrailingLambda(),
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
                    .trailing_lambda = b.callTrailingLambda(),
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
        // An exact-FQN name can cover a whole OVERLOAD SET
        // (`kotlin.test.assertTrue` is (Boolean, String?) AND (String?,
        // () -> Boolean)); the runtime value load binds the first by
        // declaration order regardless of the call's arguments. With the
        // arguments in hand, bind the UNIQUE overload whose declared
        // signature the argument shapes fit; only an undecidable tie keeps
        // the value-call fallback.
        {
            const last = rsplitLast(fqn, '.');
            const shapes = try buildArgShapes(b, args, ast_arg_names);
            defer b.allocator.free(shapes);
            var only: ?FuncId = null;
            var fit_count: usize = 0;
            var fqn_overloads: usize = 0;
            for (b.module.funcsBySimpleName(last)) |fid| {
                const f = b.module.funcById(fid) orelse continue;
                if (!std.mem.eql(u8, f.fqn, fqn)) continue;
                if (!f.hasBody()) continue;
                if (f.low_priority) continue;
                fqn_overloads += 1;
                if (!fqnCallArityFits(b, fid, args.len)) continue;
                if (!b.module.declSigCompatible(fid, shapes)) continue;
                only = fid;
                fit_count += 1;
                if (fit_count > 1) break;
            }
            if (fqn_overloads > 1 and fit_count == 1) {
                const run = try lowerArgRun(b, args);
                const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
                const dst = b.allocReg();
                try b.push(.{ .Call = .{
                    .dst = dst,
                    .func = only.?,
                    .trailing_lambda = b.callTrailingLambda(),
                    .args = run[0],
                    .n_args = run[1],
                    .arg_names = arg_names,
                    .type_args = &.{},
                    .exact = false,
                } });
                return dst;
            }
        }
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

/// Whether `fid` can take `want` positional args: at least the required
/// (non-defaulted, non-vararg) count, at most the declared total unless a
/// vararg absorbs the excess.
fn fqnCallArityFits(b: *FuncBuilder, fid: FuncId, want: usize) bool {
    const arity = b.module.decl_user_arity.get(fid.int()) orelse return false;
    if (want < arity.required) return false;
    return arity.has_vararg or want <= arity.total;
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
/// Whether `lhs` of an `in` test is provably a RANGE value (a range
/// literal, or a binding declared with a range-family type), so the
/// element-compare inline for `x in lo..hi` must stand down in favor of a
/// `contains` dispatch.
fn lhsIsRangeShaped(b: *FuncBuilder, lhs: *const Expr) bool {
    if (lhs.* == .Binary and (lhs.Binary.op == .Range or lhs.Binary.op == .RangeUntil)) return true;
    const head = argStaticHead(b, lhs) orelse return false;
    for ([_][]const u8{
        "IntRange",        "LongRange",        "CharRange",       "UIntRange",
        "ULongRange",      "IntProgression",   "LongProgression", "CharProgression",
        "UIntProgression", "ULongProgression", "ClosedRange",     "OpenEndRange",
    }) |fam| {
        if (std.mem.eql(u8, head, fam)) return true;
    }
    return false;
}

fn argStaticHead(b: *FuncBuilder, a: *const Expr) ?[]const u8 {
    if (a.* != .Path) return null;
    const p = a.Path;
    if (p.segments.len != 1) return null;
    if (b.localDeclType(p.segments[0].name)) |t| return typeHead(t);
    return null;
}

/// The fallback member-call path: local-callable shadowing, super, cast-receiver
/// static dispatch, and plain CallMember.
/// Expected per-argument lambda arities for a member call whose RECEIVER is
/// a class name (`Snapshot.withMutableSnapshot { … }`, explicit `.Companion`
/// included): the lifted companion / class method registry resolves the
/// member's declared signature statically. Null when nothing is provable —
/// dynamic dispatch then proceeds exactly as before. The channel exists so
/// a `() -> R` block drops its parser-injected `it` and an `it` inside
/// captures the enclosing lambda's, instead of binding a null parameter.
fn classMemberArgArities(b: *FuncBuilder, receiver: *const Expr, mname: []const u8, args: []const Expr, ast_arg_names: []const ?[]const u8) Allocator.Error!?[]i16 {
    if (receiver.* != .Path) return null;
    const rsegs = receiver.Path.segments;
    if (rsegs.len == 0) return null;
    var rname = rsegs[rsegs.len - 1].name;
    if (std.mem.eql(u8, rname, "Companion") and rsegs.len >= 2) rname = rsegs[rsegs.len - 2].name;
    if (rname.len == 0 or !std.ascii.isUpper(rname[0])) return null;
    if (b.resolve(rname) != null or b.knowsOuter(rname)) return null;
    const a2 = b.allocator;
    var probe_arity: usize = args.len;
    while (probe_arity <= args.len + 3) : (probe_arity += 1) {
        const comp_key = std.fmt.allocPrint(a2, "{s}$Companion$Companion\x00{s}\x00{d}", .{ rname, mname, probe_arity }) catch return null;
        defer a2.free(comp_key);
        const cls_key = std.fmt.allocPrint(a2, "{s}\x00{s}\x00{d}", .{ rname, mname, probe_arity }) catch return null;
        defer a2.free(cls_key);
        const fid = b.module.registry.member_method_fids.get(comp_key) orelse
            b.module.registry.member_method_fids.get(cls_key) orelse continue;
        const f = b.module.funcById(fid) orelse continue;
        return try argFnArities(b, f, args, ast_arg_names, 1);
    }
    return null;
}

/// Expected lambda arities for an explicit-receiver call. Class/object
/// members are authoritative; otherwise a statically typed receiver can
/// select visible extension candidates by their declared receiver head. If
/// every best-scope candidate agrees, that common shape is safe to lower even
/// though runtime overload dispatch still chooses the callable.
fn memberCallArgArities(b: *FuncBuilder, receiver: *const Expr, mname: []const u8, args: []const Expr, ast_arg_names: []const ?[]const u8) Allocator.Error!?[]i16 {
    if (try classMemberArgArities(b, receiver, mname, args, ast_arg_names)) |arities| return arities;
    const recv_ty = argDeclTypeRef(b, receiver) orelse return null;
    const recv_head = typeHead(recv_ty.name);
    if (recv_head.len == 0) return null;

    const caller_file = exprSpan(receiver).file;
    const caller_pkg = b.module.packageOfFile(caller_file) orelse b.self_package;
    var best_tier: u8 = 255;
    var agreed: ?[]i16 = null;
    errdefer if (agreed) |a| b.allocator.free(a);

    for (b.module.funcsBySimpleName(mname)) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        if (f.kind == .instance_method or f.params.len == 0 or
            !std.mem.eql(u8, f.params[0].name, "this")) continue;
        if (f.kind == .member_extension) {
            const owner = b.module.registry.member_ext_owner_class.get(fid) orelse continue;
            const lexical_owner = b.ownerClass() orelse continue;
            if (!b.module.classIsOrExtends(lexical_owner, owner)) continue;
        }
        const candidate_head = typeHead(f.params[0].ty.name);
        if (!b.module.classIsOrExtends(recv_head, candidate_head)) continue;
        const tier = b.module.scopeTier(f.fqn, f.package, mname, caller_pkg, caller_file);
        if (tier > 3 or tier > best_tier) continue;
        const arities = (try argFnArities(b, f, args, ast_arg_names, 1)) orelse continue;
        if (tier < best_tier) {
            if (agreed) |old| b.allocator.free(old);
            agreed = arities;
            best_tier = tier;
            continue;
        }
        if (agreed) |old| {
            if (!std.mem.eql(i16, old, arities)) {
                b.allocator.free(arities);
                b.allocator.free(old);
                agreed = null;
                return null;
            }
            b.allocator.free(arities);
        } else {
            agreed = arities;
        }
    }
    return agreed;
}

/// Lower a member call once the shared resolver identifies its declaration.
/// Final/private declarations become `Call(FuncId)`; overridable class members
/// become `CallVirtual(MethodSlotId)`. Both forms leave no runtime name lookup.
fn lowerResolvedMemberCall(
    b: *FuncBuilder,
    receiver: *const Expr,
    name: ast.Ident,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
    ast_type_args: []const ast.TypeRef,
    declared_ty: ?TypeRef,
) Allocator.Error!?Reg {
    if (ast_type_args.len != 0 or receiver.* == .Super) return null;
    const ty = declared_ty orelse return null;
    var identity = std.mem.trimEnd(u8, ty.name, "?");
    if (std.mem.indexOfScalar(u8, identity, '<')) |lt| identity = identity[0..lt];
    const head = typeHead(identity);
    const owner_id = if (std.mem.indexOfScalar(u8, identity, '.') != null)
        b.module.classIdByFqn(identity)
    else
        b.module.uniqueClassIdBySimpleName(head);
    var static_owner = owner_id orelse return null;
    if (receiver.* == .Path and receiver.Path.segments.len != 0) {
        const receiver_name = receiver.Path.segments[receiver.Path.segments.len - 1].name;
        if (b.resolve(receiver_name) == null and !b.knowsOuter(receiver_name) and
            static_owner.int() < b.module.classes.items.len)
        {
            const classifier = &b.module.classes.items[static_owner.int()];
            if (!classifier.is_object) {
                static_owner = classifier.companion orelse return null;
            }
        }
    }

    var shape_set = try buildStaticReturnArgShapes(b, args, ast_arg_names);
    defer shape_set.deinit(b.allocator);
    const shapes = shape_set.shapes;
    const lexical_owner: ?ir.ClassId = if (b.ownerClass()) |owner_name|
        (if (std.mem.indexOfScalar(u8, owner_name, '.') != null)
            b.module.classIdByFqn(owner_name)
        else
            (b.module.classIdIndexed(owner_name, b.self_package, name.span.file) orelse b.module.classId(owner_name)))
    else
        null;
    const resolved = b.module.resolveMemberCall(static_owner, name.name, shapes, .{
        .lexical_owner = lexical_owner,
    });
    const func_id = resolved.target orelse return null;
    if (resolved.dispatch == .deferred) return null;
    const target = b.module.funcById(func_id) orelse return null;
    const has_spread = anySpread(args);
    if (resolved.dispatch == .direct and has_spread) return null;
    if (resolved.dispatch == .virtual) {
        const owner = &b.module.classes.items[static_owner.int()];
        // Numeric virtual slots operate on `Value.Instance`. Classifier ABI
        // metadata keeps mixed host-backed receivers on the host member path
        // while source-backed stdlib classes use the same static ABI as user
        // classes. Named, defaulted, and vararg interface calls bind against
        // the numeric declaration ABI.
        if (owner.is_value or owner.is_stub or ast_type_args.len != 0 or
            owner.receiver_abi != .instance) return null;
    }

    try recordLambdaArgReceivers(b, target, args, ast_arg_names, ast_type_args, 1);
    const broad_masks = try argLambdaBroadMasks(b, target, args, ast_arg_names, 1);
    defer if (broad_masks) |masks| b.allocator.free(masks);
    b.pending_arg_broad_masks = broad_masks;
    const arg_arity = try argFnArities(b, target, args, ast_arg_names, 1);
    defer if (arg_arity) |arities| b.allocator.free(arities);
    const arg_generic = try argFnGenericFlags(b, target, args, ast_arg_names, 1);
    defer if (arg_generic) |flags| b.allocator.free(flags);
    b.pending_arg_fn_generic = arg_generic;
    const lambda_param_types = try argLambdaParamTypes(
        b,
        target,
        args,
        ast_arg_names,
        ast_type_args,
        1,
    );
    defer if (lambda_param_types) |types|
        deinitArgLambdaParamTypes(b.allocator, types);
    b.pending_arg_lambda_param_types = lambda_param_types;

    const recv_reg = try lowerReceiver(b, receiver);
    if (resolved.dispatch == .virtual) {
        const arg_names = try trailingLambdaArgNames(b, func_id, args, ast_arg_names);
        var has_vararg = false;
        for (target.params[1..]) |param| if (param.is_vararg) {
            has_vararg = true;
            break;
        };
        const arg_params: ?[]u32 = if (anyNamedArg(ast_arg_names) or has_vararg) blk: {
            if (target.params.len == 0) return null;
            const mapped = (try mapArgsToParams(b, target.params[1..], args, ast_arg_names)) orelse return null;
            defer b.allocator.free(mapped);
            for (mapped) |param| if (param == null) return null;
            const indices = try b.allocator.alloc(u32, mapped.len);
            for (mapped, indices) |param, *out| out.* = @intCast(param.?);
            break :blk indices;
        } else null;
        const dst = b.allocReg();
        if (has_spread) {
            try b.push(.{ .CallSpread = .{
                .dst = dst,
                .callee = recv_reg,
                .parts = try lowerSpreadParts(b, args),
                .virtual_slot = ir.MethodSlotId.fromFunc(func_id),
                .arg_params = arg_params,
                .trailing_lambda = b.callTrailingLambda(),
            } });
            return dst;
        }
        const run = try lowerArgRunWithArity(b, args, arg_arity);
        try b.push(.{ .CallVirtual = .{
            .dst = dst,
            .receiver = recv_reg,
            .slot = ir.MethodSlotId.fromFunc(func_id),
            .args = run[0],
            .n_args = run[1],
            .arg_params = arg_params,
            .arg_names = if (arg_params == null) arg_names else &.{},
            .trailing_lambda = b.callTrailingLambda(),
        } });
        return dst;
    }

    const args_start = b.allocReg();
    const run = try lowerArgRunWithArity(b, args, arg_arity);
    try b.push(.{ .Move = .{ .dst = args_start, .src = recv_reg } });

    const user_names = try trailingLambdaArgNames(b, func_id, args, ast_arg_names);
    const arg_names: []?ConstId = if (user_names.len == 0)
        &.{}
    else blk: {
        const names = try b.allocator.alloc(?ConstId, user_names.len + 1);
        names[0] = null;
        @memcpy(names[1..], user_names);
        break :blk names;
    };
    const type_args = try helpers.internTypeArgsScoped(b, ast_type_args);
    const dst = b.allocReg();
    try b.push(.{ .Call = .{
        .dst = dst,
        .func = func_id,
        .trailing_lambda = b.callTrailingLambda(),
        .args = args_start,
        .n_args = run[1] + 1,
        .arg_names = arg_names,
        .type_args = type_args,
        .exact = true,
    } });
    return dst;
}

/// Bind an explicit-receiver top-level extension to its declaration identity.
/// Extensions are statically dispatched in Kotlin; the module resolver only
/// returns a target when receiver compatibility, visibility, and overload
/// ranking are all provable without a runtime value.
fn lowerResolvedExtensionCall(
    b: *FuncBuilder,
    receiver: *const Expr,
    name: ast.Ident,
    resolution_name: []const u8,
    target_fqn: ?[]const u8,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
    ast_type_args: []const ast.TypeRef,
    declared_ty: ?TypeRef,
) Allocator.Error!?Reg {
    // Explicit call-site type arguments constrain the eligible generic
    // declarations before ordinary overload ranking. The exact extension
    // path defers until it carries and proves that substitution.
    if (ast_type_args.len != 0) return null;
    const recv_ty = declared_ty orelse return null;
    var shape_set = try buildStaticReturnArgShapes(b, args, ast_arg_names);
    defer shape_set.deinit(b.allocator);
    const shapes = shape_set.shapes;
    const caller_file = name.span.file;
    const implicit_owners = try b.collectImplicitReceiverTower(b.allocator, eagerLambdaRecvHead(b));
    defer b.allocator.free(implicit_owners);
    const owned_type_param_bounds = try b.typeParamBoundsSlice();
    defer if (owned_type_param_bounds) |bounds| b.allocator.free(bounds);
    const resolution = b.module.resolveExtensionCall(resolution_name, recv_ty, shapes, .{
        .caller_file = caller_file,
        .caller_package = b.module.packageOfFile(caller_file) orelse b.self_package,
        .implicit_dispatch_owners = implicit_owners,
        .lexical_owner = b.ownerClass(),
        .target_fqn = target_fqn,
        .call_name = name.name,
        .actual_type_param_bounds = owned_type_param_bounds orelse &.{},
    });
    const func_id = resolution.target orelse return null;
    const target = b.module.funcById(func_id) orelse return null;
    // Inline declarations require their own resolved-target lowering strategy:
    // an ordinary exact call executes InlineOnly wrapper bodies, while a splice
    // can change lexical lookup for body-local helpers. Keep the declaration
    // identity on the compatibility path until that strategy consumes FuncId.
    if (target.is_inline) return null;

    try recordLambdaArgReceivers(b, target, args, ast_arg_names, ast_type_args, 1);
    const broad_masks = try argLambdaBroadMasks(b, target, args, ast_arg_names, 1);
    defer if (broad_masks) |masks| b.allocator.free(masks);
    b.pending_arg_broad_masks = broad_masks;
    const arg_arity = try argFnArities(b, target, args, ast_arg_names, 1);
    defer if (arg_arity) |arities| b.allocator.free(arities);
    const arg_generic = try argFnGenericFlags(b, target, args, ast_arg_names, 1);
    defer if (arg_generic) |flags| b.allocator.free(flags);
    b.pending_arg_fn_generic = arg_generic;
    const lambda_param_types = try argLambdaParamTypes(
        b,
        target,
        args,
        ast_arg_names,
        ast_type_args,
        1,
    );
    defer if (lambda_param_types) |types|
        deinitArgLambdaParamTypes(b.allocator, types);
    b.pending_arg_lambda_param_types = lambda_param_types;

    const recv_reg = try lowerReceiver(b, receiver);
    const args_start = b.allocReg();
    const run = try lowerArgRunWithArity(b, args, arg_arity);
    try b.push(.{ .Move = .{ .dst = args_start, .src = recv_reg } });

    const user_names = try trailingLambdaArgNames(b, func_id, args, ast_arg_names);
    const arg_names: []?ConstId = if (user_names.len == 0)
        &.{}
    else blk: {
        const names = try b.allocator.alloc(?ConstId, user_names.len + 1);
        names[0] = null;
        @memcpy(names[1..], user_names);
        break :blk names;
    };
    const type_args = try helpers.internTypeArgsScoped(b, ast_type_args);
    const dst = b.allocReg();
    try b.push(.{ .Call = .{
        .dst = dst,
        .func = func_id,
        .trailing_lambda = b.callTrailingLambda(),
        .args = args_start,
        .n_args = run[1] + 1,
        .arg_names = arg_names,
        .type_args = type_args,
        .exact = true,
    } });
    return dst;
}

fn staticReceiverHasNoCompetingCallable(
    b: *FuncBuilder,
    receiver_ty: ?TypeRef,
    name: []const u8,
) bool {
    const ty = receiver_ty orelse return false;
    const head = typeHead(ty.name);
    const hierarchy = b.module.registry.hierarchy_shadow_names.get(head) orelse return false;
    if (!hierarchy.complete or hierarchy.names.contains(name)) return false;
    return !b.module.extCouldApply(b.allocator, head, name);
}

fn localOverloadReceiverCouldApply(
    b: *const FuncBuilder,
    overload: *const build.LocalFnOverload,
    actual: TypeRef,
) Allocator.Error!bool {
    const declared = overload.receiver_ty orelse return true;
    const owned_bounds = try b.typeParamBoundsSlice();
    defer if (owned_bounds) |bounds| b.allocator.free(bounds);
    const actual_bounds: []const ir.ModuleRegistry.TypeParamBound =
        owned_bounds orelse &.{};
    if (overload.receiver_has_type_params) {
        return b.module.staticGenericReceiverApplicable(
            b.allocator,
            actual,
            declared,
            overload.type_params,
            actual_bounds,
        );
    }
    return b.module.staticTypeIsSubtypeWithBounds(
        b.allocator,
        actual,
        declared,
        actual_bounds,
    );
}

fn localExtensionReceiverCouldApply(
    b: *const FuncBuilder,
    name: []const u8,
    receiver_ty: ?TypeRef,
) Allocator.Error!bool {
    const actual = receiver_ty orelse return true;
    const overloads = b.localFnDecls(name) orelse return true;
    var saw_extension = false;
    for (overloads) |overload| {
        if (!overload.is_ext) continue;
        saw_extension = true;
        if (try localOverloadReceiverCouldApply(b, &overload, actual)) {
            return true;
        }
    }
    return !saw_extension;
}

fn lowerMemberCallFallback(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    const call = expr.Call;
    const callee = call.callee;
    const args = call.args;
    const ast_arg_names = call.arg_names;
    const ast_type_args = call.type_args;
    const receiver = callee.Member.receiver;
    const name = callee.Member.name;
    const lazy_declared_ty = argDeclTypeRefLazy(b, receiver);
    var inferred_declared_ty: ?ir.TypeRef = if (lazy_declared_ty == null)
        try staticCallReturnTypeRef(b, receiver)
    else
        null;
    defer if (inferred_declared_ty) |*ty| ty.deinit(b.allocator);
    const declared_ty = lazy_declared_ty orelse inferred_declared_ty;

    // Member declarations take precedence over local callables and extensions.
    // A unique static declaration commits here as either an exact function or
    // a virtual slot; only ambiguous/incomplete receiver shapes continue below.
    if (try lowerResolvedMemberCall(
        b,
        receiver,
        name,
        args,
        ast_arg_names,
        ast_type_args,
        declared_ty,
    )) |reg| return reg;

    // A bound local/param/captured-outer of this name shadows the member.
    // A plain bound local (`for (module in modules) { application.module() }`,
    // a `T.() -> R` value invoked with receiver syntax) is included too: the
    // member is still tried first at runtime, with the local as the fallback.
    const anon_cap = isLowerAnonCapture(name.name) and b.resolve(name.name) == null and
        !b.isLocalFn(name.name) and !b.isParam(name.name) and !b.knowsOuter(name.name);
    // A parameter whose declared type is a function type with NO receiver can
    // never serve an EXPLICIT-receiver call. Kotlin resolves `recv.name(args)` to
    // a member or extension of `recv`; a local competes only when its type is an
    // EXTENSION-function type (`Modifier.() -> Unit`, which is why `up.update()`
    // binds a `Up.() -> Unit` param). A plain `(FocusState) -> Unit` is not that —
    // and treating it as a candidate made `.onFocusChanged(onFocusChanged)` inside
    // `textFieldFocusModifier` INVOKE the callback with itself as its argument
    // instead of dispatching `Modifier.onFocusChanged`, recursing until the native
    // stack blew (every `BasicTextField`).
    const plain_fn_local = b.isPlainFnParam(name.name);
    const local_receiver_applicable = !b.isLocalExtFn(name.name) or
        try localExtensionReceiverCouldApply(b, name.name, declared_ty);
    const local_callable = !plain_fn_local and local_receiver_applicable and
        (b.isLocalFn(name.name) or b.isParam(name.name) or
            b.knowsOuter(name.name) or anon_cap or b.resolve(name.name) != null);
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
        // A receiver whose static type is an unbounded type parameter declares
        // no members, so the runtime class must not be consulted at all: the
        // in-scope callable is the only candidate Kotlin ever had.
        const recv_erased = receiver.* == .Path and
            receiver.Path.segments.len == 1 and
            b.isErasedRecvParam(receiver.Path.segments[0].name);
        const callable_takes_receiver = b.isReceiverLambdaParam(name.name) or
            b.isLocalExtFn(name.name) or b.localDeclRecvFn(name.name);
        const callable_shape_known = callable_takes_receiver or
            (b.isLocalFn(name.name) and !b.isLocalExtFn(name.name));
        if (callable_takes_receiver and
            (recv_erased or staticReceiverHasNoCompetingCallable(b, declared_ty, name.name)))
        {
            orEmitAudit(b, "member_or_local_exact_value", "CallValueWithThis", name.name);
            try b.push(.{ .CallValueWithThis = .{
                .dst = dst,
                .callee = local_reg,
                .receiver = recv,
                .args = run[0],
                .n_args = run[1],
                .arg_names = arg_names,
                .receiver_shape_exact = true,
            } });
            return dst;
        }
        orEmitAudit(b, "member_or_local_callable", "CallMemberOrValue", name.name);
        try b.push(.{ .CallMemberOrValue = .{
            .dst = dst,
            .receiver = recv,
            .name = nm,
            .fallback = local_reg,
            .args = run[0],
            .n_args = run[1],
            .arg_names = arg_names,
            .recv_erased = recv_erased,
            .fallback_takes_receiver = callable_takes_receiver,
            .fallback_receiver_shape_known = callable_shape_known,
        } });
        return dst;
    }

    // `super.method(...)`.
    if (receiver.* == .Super) {
        if (try resolveSuperThisReg(b)) |this_reg| {
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

    // A RENAMING import (`import a.b.f as g`) used with an explicit
    // receiver (`recv.g(args)`): no member or extension bears the alias
    // name, so bind the aliased extension overload directly by FQN. The
    // direct bind keeps a same-receiver namesake under the target's
    // ORIGINAL name (e.g. a wrapper `TestScope.runTest` delegating to the
    // aliased `kotlinx...runTest`) from capturing the call and recursing.
    {
        const alias_paths = b.module.importAliasPathsIn(name.span.file, name.name);
        if (alias_paths.len == 1 and alias_paths[0].segs.len >= 2) {
            const target_leaf = alias_paths[0].segs[alias_paths[0].segs.len - 1];
            if (!std.mem.eql(u8, target_leaf, name.name)) {
                if (try lowerResolvedExtensionCall(
                    b,
                    receiver,
                    name,
                    target_leaf,
                    alias_paths[0].fqn,
                    args,
                    ast_arg_names,
                    ast_type_args,
                    declared_ty,
                )) |reg| return reg;
            }
        }
    }

    if (try lowerResolvedExtensionCall(
        b,
        receiver,
        name,
        name.name,
        null,
        args,
        ast_arg_names,
        ast_type_args,
        declared_ty,
    )) |reg| return reg;

    const recv = try lowerReceiver(b, receiver);
    // A class-named receiver (`Snapshot.withMutableSnapshot { … }`, or an
    // explicit `.Companion`) resolves its member's declared signature
    // statically through the lifted companion / class method registry, so
    // each lambda argument learns its expected value arity — a `() -> R`
    // block then drops its parser-injected `it` and an `it` inside
    // captures the enclosing lambda's, instead of binding a spurious null
    // parameter.
    const uarg_arity: ?[]const i16 = try memberCallArgArities(b, receiver, name.name, args, ast_arg_names);
    const run = try lowerArgRunWithArity(b, args, uarg_arity);
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
        const t = declared_ty orelse break :blk null;
        const head = std.mem.trimEnd(u8, t.name, "?");
        if (head.len == 0) break :blk null;
        break :blk try b.module.internConst(b.allocator, .{ .String = head });
    };
    try b.push(.{ .CallMember = .{
        .dst = dst,
        .receiver = recv,
        .name = nm,
        .trailing_lambda = b.callTrailingLambda(),
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

/// Emit a dotted `pkg.Outer.Inner.member…` reference by binding the LONGEST
/// prefix that names a class to its EXACT id, then reading each remaining
/// segment as a field. Riding the class id keeps a same-simple-name class in
/// another package from swapping in at runtime (the `gapbuffer` vs
/// `linkbuffer` `Operation.Ins` collision), which a plain name-keyed global
/// load cannot do. Returns null when no prefix names a class — the caller
/// falls back to the name-keyed load.
fn emitFqnWithClassPrefix(b: *FuncBuilder, fqn: []const u8) Allocator.Error!?Reg {
    var end = fqn.len;
    while (true) {
        if (b.module.classIdByFqn(fqn[0..end])) |cid| {
            // Ride the exact id ONLY when the prefix's simple name is
            // genuinely ambiguous — collision-mangled out of the flat index
            // (null) or resolving to a DIFFERENT first-registered class.
            // When the simple name resolves to this very class the name-keyed
            // load is already correct AND preferable: an id load returns a
            // class's companion (or misses a same-named factory function),
            // so overriding an unambiguous `kotlinx.coroutines.Job` would
            // hand back `Job.Key` instead of the Job factory.
            const prefix = fqn[0..end];
            const simple = if (std.mem.lastIndexOfScalar(u8, prefix, '.')) |d| prefix[d + 1 ..] else prefix;
            const simple_cid = b.module.classId(simple);
            if (simple_cid != null and simple_cid.?.int() == cid.int()) return null;
            // The id table resolves an `object` prefix straight to its
            // singleton; a plain class prefix loads its class value, off which
            // each remaining segment reads its nested classifier / member.
            var cur = b.allocReg();
            const n = try b.module.internConst(b.allocator, .{ .String = fqn[0..end] });
            try b.push(.{ .LoadGlobal = .{ .dst = cur, .name = n, .class = cid } });
            var rest = fqn[end..];
            while (rest.len > 0) {
                rest = rest[1..]; // skip '.'
                const dot = std.mem.indexOfScalar(u8, rest, '.') orelse rest.len;
                const next = b.allocReg();
                const field = try b.module.internConst(b.allocator, .{ .String = rest[0..dot] });
                try b.push(.{ .GetField = .{ .dst = next, .receiver = cur, .field = field } });
                cur = next;
                rest = rest[dot..];
            }
            return cur;
        }
        const dot = std.mem.lastIndexOfScalar(u8, fqn[0..end], '.') orelse break;
        end = dot;
    }
    return null;
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

    const null_lit = Expr{ .NullLit = .{ .span = dummySpan() } };
    const null_shape = shapeOfAstArg(&b, &null_lit, null);
    try testing.expect(null_shape.is_null);

    try b.setLocalCallReturn("predicate", "Boolean", false);
    var predicate_segments = [_]ast.Ident{.{ .name = "predicate", .span = dummySpan() }};
    var predicate = Expr{ .Path = .{ .segments = &predicate_segments, .span = dummySpan() } };
    const predicate_call = Expr{ .Call = .{
        .callee = &predicate,
        .args = &.{},
        .arg_names = &.{},
        .type_args = &.{},
        .is_infix = false,
        .span = dummySpan(),
    } };
    const call_shape = shapeOfAstArg(&b, &predicate_call, null);
    try testing.expectEqualStrings("Boolean", call_shape.ty.?.name);
}

test "selected call args discard a composer pair from a non-composable overload" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    const plain_id = m.nextFuncId();
    try m.funcs.append(a, .{
        .id = plain_id,
        .name = "sameName",
        .fqn = "sample.sameName",
        .params = try a.dupe(ir.Param, &.{.{ .name = "value", .ty = build.typeInt(), .default = null }}),
        .return_ty = build.typeUnit(),
        .n_locals = 0,
        .blocks = &.{},
        .entry = ir.BlockId.from(0),
        .is_suspend = false,
    });
    const composable_id = m.nextFuncId();
    try m.funcs.append(a, .{
        .id = composable_id,
        .name = "sameName",
        .fqn = "sample.sameNameComposable",
        .params = &.{},
        .return_ty = build.typeUnit(),
        .n_locals = 0,
        .blocks = &.{},
        .entry = ir.BlockId.from(0),
        .is_suspend = false,
        .annotation_names = &.{"Composable"},
    });

    const args = [_]Expr{
        .{ .IntLit = .{ .value = 1, .kind = .Int, .span = dummySpan() } },
        .{ .NullLit = .{ .span = dummySpan() } },
        .{ .IntLit = .{ .value = 0, .kind = .Int, .span = dummySpan() } },
    };
    const names = [_]?[]const u8{ null, "$composer", "$changed" };
    const plain = selectedCallArgs(&m, plain_id, &args, &names);
    try testing.expectEqual(@as(usize, 1), plain.args.len);
    try testing.expectEqual(@as(usize, 1), plain.names.len);
    const composable = selectedCallArgs(&m, composable_id, &args, &names);
    try testing.expectEqual(@as(usize, 3), composable.args.len);
    try testing.expectEqual(@as(usize, 3), composable.names.len);

    const header_id = m.nextFuncId();
    try m.funcs.append(a, .{
        .id = header_id,
        .name = "reserved",
        .fqn = "sample.reserved",
        .params = try a.dupe(ir.Param, &.{.{ .name = "value", .ty = build.typeInt(), .default = null }}),
        .return_ty = build.typeUnit(),
        .n_locals = 0,
        .blocks = &.{},
        .entry = ir.BlockId.from(0),
        .is_suspend = false,
    });
    const body_id = m.nextFuncId();
    try m.funcs.append(a, .{
        .id = body_id,
        .name = "reserved",
        .fqn = "sample.reserved",
        .params = try a.dupe(ir.Param, &.{
            .{ .name = "value", .ty = build.typeInt(), .default = null },
            .{ .name = "$composer", .ty = build.typeUnit(), .default = null },
            .{ .name = "$changed", .ty = build.typeInt(), .default = null },
        }),
        .return_ty = build.typeUnit(),
        .n_locals = 0,
        .blocks = &.{},
        .entry = ir.BlockId.from(0),
        .is_suspend = false,
    });
    const reserved_sig: ir.Module.DeclSig = .{
        .arity = .{ .required = 1, .total = 1, .has_vararg = false },
        .sig = &.{build.typeInt()},
        .has_body = true,
    };
    try m.decl_sigs.put(header_id.int(), reserved_sig);
    try m.decl_sigs.put(body_id.int(), reserved_sig);
    try m.func_index.append(a, .{ .name = "reserved", .id = header_id });
    try m.func_index.append(a, .{ .name = "reserved", .id = body_id });
    try m.rebuildFuncNameIndex(a);
    const reserved = selectedCallArgs(&m, header_id, &args, &names);
    try testing.expectEqual(@as(usize, 3), reserved.args.len);
    try testing.expectEqual(@as(usize, 3), reserved.names.len);

    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();
    try b.bind("$composer", b.allocReg());
    const source_names = [_]?[]const u8{null};
    var completed = try selectedCallArgsForBuilder(
        &b,
        header_id,
        args[0..1],
        &source_names,
        dummySpan(),
    );
    defer completed.deinit(a);
    try testing.expectEqual(@as(usize, 3), completed.args.len);
    try testing.expectEqualStrings("$composer", completed.names[1].?);
    try testing.expectEqualStrings("$changed", completed.names[2].?);
    try testing.expect(completed.args[1] == .Path);
    try testing.expectEqualStrings("$composer", completed.args[1].Path.segments[0].name);
}

test "threaded trailing lambda binds before the composer pair" {
    var params = [_]ir.Param{
        .{ .name = "modifier$arg", .ty = .{ .name = "Modifier", .nullable = false, .args = &.{} }, .default = null },
        .{ .name = "measurePolicy", .ty = .{ .name = "Function1", .nullable = false, .args = &.{} }, .default = null },
        .{ .name = "$composer", .ty = .{ .name = "Composer", .nullable = false, .args = &.{} }, .default = null },
        .{ .name = "$changed", .ty = build.typeInt(), .default = null },
    };
    const f = Func{
        .id = FuncId.from(0),
        .name = "SubcomposeLayout",
        .fqn = "androidx.compose.ui.layout.SubcomposeLayout",
        .params = &params,
        .return_ty = build.typeUnit(),
        .n_locals = 0,
        .blocks = &.{},
        .entry = ir.BlockId.from(0),
        .is_suspend = false,
    };
    var lambda_params: [0]ast.Ident = .{};
    const args = [_]Expr{
        .{ .Lambda = .{
            .params = &lambda_params,
            .body = .{ .stmts = &.{}, .span = dummySpan() },
            .span = dummySpan(),
        } },
        .{ .NullLit = .{ .span = dummySpan() } },
        .{ .IntLit = .{ .value = 0, .kind = .Int, .span = dummySpan() } },
    };
    const names = [_]?[]const u8{ null, "$composer", "$changed" };
    const hit = threadedTrailingLambdaParam(&f, &args, &names).?;
    try testing.expectEqual(@as(usize, 0), hit.arg_index);
    try testing.expectEqualStrings("measurePolicy", hit.param_name);

    const explicitly_named = [_]?[]const u8{ "measurePolicy", "$composer", "$changed" };
    try testing.expect(threadedTrailingLambdaParam(&f, &args, &explicitly_named) == null);
}

test "lambda lowering records unknown, plain, and receiver callable shapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);
    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();
    const sp = dummySpan();
    const unit_ty = ast.TypeRef{
        .name = .{ .name = "Unit", .span = sp },
        .nullable = false,
        .span = sp,
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
    const string_ty = ast.TypeRef{
        .name = .{ .name = "String", .span = sp },
        .nullable = false,
        .span = sp,
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
    var plain_fn = ast.FunctionTypeRef{
        .receiver = null,
        .params = &.{},
        .ret = unit_ty,
        .is_suspend = false,
        .span = sp,
    };
    var receiver_fn = ast.FunctionTypeRef{
        .receiver = string_ty,
        .params = &.{},
        .ret = unit_ty,
        .is_suspend = false,
        .span = sp,
    };
    const plain_ty = ast.TypeRef{
        .name = .{ .name = "<function>", .span = sp },
        .nullable = false,
        .span = sp,
        .type_args = &.{},
        .function = &plain_fn,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
    const receiver_ty = ast.TypeRef{
        .name = .{ .name = "<function>", .span = sp },
        .nullable = false,
        .span = sp,
        .type_args = &.{},
        .function = &receiver_fn,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
    const lambda = Expr{ .Lambda = .{
        .params = &.{},
        .body = .{ .stmts = &.{}, .span = sp },
        .span = sp,
    } };

    _ = try lowerExpr(&b, &lambda);
    const unknown = &m.funcs.items[m.funcs.items.len - 1];
    try testing.expect(!unknown.lambda_receiver_shape_known);
    try testing.expect(!unknown.lambda_has_receiver);

    var prev = b.pushExpected(plain_ty);
    _ = try lowerExpr(&b, &lambda);
    b.restoreExpected(prev);
    const plain = &m.funcs.items[m.funcs.items.len - 1];
    try testing.expect(plain.lambda_receiver_shape_known);
    try testing.expect(!plain.lambda_has_receiver);

    prev = b.pushExpected(receiver_ty);
    _ = try lowerExpr(&b, &lambda);
    b.restoreExpected(prev);
    const receiver = &m.funcs.items[m.funcs.items.len - 1];
    try testing.expect(receiver.lambda_receiver_shape_known);
    try testing.expect(receiver.lambda_has_receiver);
}

test "receiver lambda substitutes a direct call type parameter" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer m.deinit(a);
    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();

    const fid = FuncId.from(42);
    var type_params: std.ArrayList([]const u8) = .empty;
    try type_params.append(a, "T");
    try m.registry.func_type_params.put(fid, type_params);

    var receiver_fn_args = [_]ir.TypeRef{
        .{ .name = "T", .nullable = false, .args = &.{} },
        build.typeUnit(),
    };
    var params = [_]ir.Param{
        .{ .name = "receiver", .ty = .{ .name = "T", .nullable = false, .args = &.{} }, .default = null },
        .{
            .name = "block",
            .ty = .{ .name = "Function0", .nullable = false, .args = &receiver_fn_args },
            .default = null,
        },
    };
    const func = Func{
        .id = fid,
        .name = "with",
        .fqn = "kotlin.with",
        .params = &params,
        .return_ty = build.typeUnit(),
        .n_locals = 0,
        .blocks = &.{},
        .entry = BlockId.from(0),
        .is_suspend = false,
        .low_priority = false,
    };

    const owner_reg = b.allocReg();
    try b.bind("owner", owner_reg);
    const sp = dummySpan();
    _ = try m.reserveClassFqn(a, "ShadowOwner", "sample.ShadowOwner", "sample", false);
    var ctor_path = [_]ast.Ident{.{ .name = "ShadowOwner", .span = sp }};
    var ctor_callee = Expr{ .Path = .{ .segments = &ctor_path, .span = sp } };
    const ctor_init = Expr{ .Call = .{
        .callee = &ctor_callee,
        .args = &.{},
        .arg_names = &.{},
        .type_args = &.{},
        .is_infix = false,
        .span = sp,
    } };
    try b.setLocalInitExpr("owner", &ctor_init);
    var owner_path = [_]ast.Ident{.{ .name = "owner", .span = sp }};
    const owner_arg = Expr{ .Path = .{ .segments = &owner_path, .span = sp } };
    const lambda = Expr{ .Lambda = .{
        .params = &.{},
        .body = .{ .stmts = &.{}, .span = sp },
        .span = sp,
    } };
    const args = [_]Expr{ owner_arg, lambda };

    try recordLambdaArgReceivers(&b, &func, &args, &.{}, &.{}, 0);
    try testing.expectEqualStrings("sample.ShadowOwner", b.lambdaArgRecv(sp).?.name);

    var unknown_path = [_]ast.Ident{.{ .name = "unknown", .span = sp }};
    const unknown_arg = Expr{ .Path = .{ .segments = &unknown_path, .span = sp } };
    const unproven_args = [_]Expr{ unknown_arg, lambda };
    try recordLambdaArgReceivers(&b, &func, &unproven_args, &.{}, &.{}, 0);
    try testing.expectEqualStrings("sample.ShadowOwner", b.lambdaArgRecv(sp).?.name);

    const explicit_any = ast.TypeRef{
        .name = .{ .name = "Any", .span = sp },
        .nullable = false,
        .span = sp,
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
    try recordLambdaArgReceivers(&b, &func, &args, &.{}, &.{explicit_any}, 0);
    try testing.expectEqualStrings("Any", b.lambdaArgRecv(sp).?.name);
}

test "local extension receiver applicability rejects nullable Nothing" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer m.deinit(a);
    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();

    try b.markLocalExtFn("contentEquals");
    try b.addLocalFnOverload("contentEquals", .{
        .mangled = "contentEquals$ovl0",
        .receiver_ty = try (ir.TypeRef{
            .name = "String",
            .nullable = false,
            .args = &.{},
        }).clone(a),
        .param_tys = try a.alloc(?[]const u8, 0),
        .param_names = try a.alloc([]const u8, 0),
        .n_required = 0,
        .has_vararg = false,
        .is_ext = true,
    });

    try testing.expect(!(try localExtensionReceiverCouldApply(&b, "contentEquals", .{
        .name = "Nothing",
        .nullable = true,
        .args = &.{},
    })));
    try testing.expect(try localExtensionReceiverCouldApply(&b, "contentEquals", .{
        .name = "String",
        .nullable = false,
        .args = &.{},
    }));
    try testing.expect(try localExtensionReceiverCouldApply(&b, "contentEquals", null));
}

test "argument maps repeat a vararg slot before a trailing lambda" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();

    const params = [_]ir.Param{
        .{ .name = "head", .ty = build.typeInt(), .default = null },
        .{ .name = "values", .ty = build.typeInt(), .default = null, .is_vararg = true },
        .{ .name = "block", .ty = .{ .name = "Function0", .nullable = false, .args = &.{} }, .default = null },
    };
    var lambda_params: [0]ast.Ident = .{};
    const args = [_]Expr{
        .{ .IntLit = .{ .value = 1, .kind = .Int, .span = dummySpan() } },
        .{ .IntLit = .{ .value = 2, .kind = .Int, .span = dummySpan() } },
        .{ .IntLit = .{ .value = 3, .kind = .Int, .span = dummySpan() } },
        .{ .Lambda = .{ .params = &lambda_params, .body = .{ .stmts = &.{}, .span = dummySpan() }, .span = dummySpan() } },
    };
    const mapped = (try mapArgsToParams(&b, &params, &args, &.{})).?;
    defer testing.allocator.free(mapped);
    try testing.expectEqualSlices(?usize, &.{ 0, 1, 1, 2 }, mapped);
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

test "calling an object loads its exact singleton for operator invoke" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer m.deinit(a);
    const cid = try m.reserveClassFqn(a, "Callable", "sample.Callable", "sample", false);
    m.classes.items[cid.int()].is_object = true;
    try m.registry.file_packages.put(dummySpan().file, "sample");

    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();
    var segments = [_]ast.Ident{.{ .name = "Callable", .span = dummySpan() }};
    var callee = Expr{ .Path = .{ .segments = &segments, .span = dummySpan() } };
    var args = [_]Expr{.{ .IntLit = .{ .value = 1, .kind = .Int, .span = dummySpan() } }};
    const call = Expr{ .Call = .{
        .callee = &callee,
        .args = &args,
        .arg_names = &.{},
        .type_args = &.{},
        .is_infix = false,
        .span = dummySpan(),
    } };
    const r = try lowerExpr(&b, &call);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "sample.f", build.typeInt());
    defer freeFunc(func);

    try testing.expect(func.blocks[0].insts[0] == .LoadGlobal);
    try testing.expectEqual(cid, func.blocks[0].insts[0].LoadGlobal.class.?);
    try testing.expect(func.blocks[0].insts[func.blocks[0].insts.len - 1] == .CallValue);
    for (func.blocks[0].insts) |inst| try testing.expect(inst != .NewInstance);
}

test "fun interface classifier lowers to a static SAM instance" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);
    const cid = try m.addClass(a, .{
        .id = ir.ClassId.from(0),
        .name = "Action",
        .fqn = "sample.Action",
        .package = "sample",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
        .is_abstract = true,
        .is_interface = true,
        .is_fun_interface = true,
    });
    try m.registry.file_packages.put(dummySpan().file, "sample");

    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();
    var segments = [_]ast.Ident{.{ .name = "Action", .span = dummySpan() }};
    var callee = Expr{ .Path = .{ .segments = &segments, .span = dummySpan() } };
    var args = [_]Expr{.{ .Lambda = .{
        .params = &.{},
        .body = .{ .stmts = &.{}, .span = dummySpan() },
        .span = dummySpan(),
    } }};
    const call = Expr{ .Call = .{
        .callee = &callee,
        .args = &args,
        .arg_names = &.{},
        .type_args = &.{},
        .is_infix = false,
        .span = dummySpan(),
    } };
    const r = try lowerExpr(&b, &call);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "sample.f", build.typeUnit());

    var saw_sam = false;
    for (func.blocks[0].insts) |inst| switch (inst) {
        .NewInstance => |ni| {
            try testing.expectEqual(cid, ni.class);
            saw_sam = true;
        },
        .CallMemberOrGlobal => return error.TestUnexpectedResult,
        else => {},
    };
    try testing.expect(saw_sam);
}

test "renamed overloaded import binds exact extension and plain identities" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);
    const sp = dummySpan();

    const Add = struct {
        fn func(
            module: *Module,
            alloc: Allocator,
            params: []ir.Param,
            kind: ir.FuncKind,
            is_inline: bool,
            arity: Module.DeclArity,
        ) !FuncId {
            const id = module.nextFuncId();
            try module.funcs.append(alloc, .{
                .id = id,
                .name = "combine",
                .fqn = "sample.combine",
                .package = "sample",
                .params = params,
                .return_ty = .{ .name = "Flow", .nullable = false, .args = &.{} },
                .n_locals = 0,
                .blocks = &.{},
                .entry = ir.BlockId.from(0),
                .is_suspend = false,
                .kind = kind,
                .has_receiver_param = kind == .top_level_extension,
                .is_inline = is_inline,
            });
            try module.func_index.append(alloc, .{ .name = "combine", .id = id });
            try module.decl_user_arity.put(id.int(), arity);
            const off: usize = if (kind == .top_level_extension) 1 else 0;
            const sig = try alloc.alloc(ir.TypeRef, params.len - off);
            for (params[off..], sig) |p, *ty| ty.* = p.ty;
            try module.decl_sigs.put(id.int(), .{
                .receiver_ty = if (off == 1) params[0].ty else null,
                .arity = arity,
                .sig = sig,
                .kind = kind,
                .is_inline = is_inline,
                .has_body = true,
            });
            return id;
        }
    };

    const ext_params = try a.alloc(ir.Param, 3);
    ext_params[0] = .{ .name = "this", .ty = .{ .name = "Flow", .nullable = false, .args = &.{} }, .default = null };
    ext_params[1] = .{ .name = "other", .ty = .{ .name = "Flow", .nullable = false, .args = &.{} }, .default = null };
    ext_params[2] = .{ .name = "transform", .ty = .{ .name = "Function2", .nullable = false, .args = &.{} }, .default = null };
    const ext_id = try Add.func(&m, a, ext_params, .top_level_extension, false, .{
        .required = 2,
        .total = 2,
        .has_vararg = false,
    });

    const plain_params = try a.alloc(ir.Param, 3);
    plain_params[0] = .{ .name = "flow", .ty = .{ .name = "Flow", .nullable = false, .args = &.{} }, .default = null };
    plain_params[1] = .{ .name = "other", .ty = .{ .name = "Flow", .nullable = false, .args = &.{} }, .default = null };
    plain_params[2] = .{ .name = "transform", .ty = .{ .name = "Function2", .nullable = false, .args = &.{} }, .default = null };
    const plain_id = try Add.func(&m, a, plain_params, .plain, false, .{
        .required = 3,
        .total = 3,
        .has_vararg = false,
    });

    const inline_params = try a.alloc(ir.Param, 2);
    inline_params[0] = .{ .name = "flows", .ty = .{ .name = "Flow", .nullable = false, .args = &.{} }, .default = null, .is_vararg = true };
    inline_params[1] = .{ .name = "transform", .ty = .{ .name = "Function1", .nullable = false, .args = &.{} }, .default = null };
    const inline_id = try Add.func(&m, a, inline_params, .plain, true, .{
        .required = 1,
        .total = 2,
        .has_vararg = true,
    });
    try m.rebuildFuncNameIndex(a);

    var paths: std.ArrayList(ir.ModuleRegistry.ImportPath) = .empty;
    const import_segs = try a.dupe([]const u8, &.{ "sample", "combine" });
    try paths.append(a, .{ .fqn = try a.dupe(u8, "sample.combine"), .segs = import_segs });
    var imports = std.StringHashMap(std.ArrayList(ir.ModuleRegistry.ImportPath)).init(a);
    try imports.put("combineOriginal", paths);
    try m.registry.import_aliases.put(sp.file, imports);

    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();
    b.setRecvTy("Flow");
    try b.bind("this", b.allocReg());
    try b.bind("first", b.allocReg());
    try b.bind("other", b.allocReg());
    try b.bind("transform", b.allocReg());
    try b.bind("arrayTransform", b.allocReg());
    try b.setLocalDeclType("first", "Flow");
    try b.setLocalDeclType("other", "Flow");
    try b.setLocalDeclType("transform", "Function2");
    try b.setLocalDeclType("arrayTransform", "Function1");

    var callee_segs = [_]ast.Ident{.{ .name = "combineOriginal", .span = sp }};
    var callee = Expr{ .Path = .{ .segments = &callee_segs, .span = sp } };
    var other_segs = [_]ast.Ident{.{ .name = "other", .span = sp }};
    var transform_segs = [_]ast.Ident{.{ .name = "transform", .span = sp }};
    var ext_args = [_]Expr{
        .{ .Path = .{ .segments = &other_segs, .span = sp } },
        .{ .Path = .{ .segments = &transform_segs, .span = sp } },
    };
    const ext_call = Expr{ .Call = .{
        .callee = &callee,
        .args = &ext_args,
        .arg_names = &.{},
        .type_args = &.{},
        .is_infix = false,
        .span = sp,
    } };
    _ = try lowerExpr(&b, &ext_call);
    const ext_insts = b.blocks.items[b.cur.int()].insts;
    const ext_inst = ext_insts[ext_insts.len - 1];
    try testing.expect(ext_inst == .Call);
    try testing.expectEqual(ext_id, ext_inst.Call.func);
    try testing.expect(ext_inst.Call.exact);

    var first_segs = [_]ast.Ident{.{ .name = "first", .span = sp }};
    var plain_args = [_]Expr{
        .{ .Path = .{ .segments = &first_segs, .span = sp } },
        .{ .Path = .{ .segments = &other_segs, .span = sp } },
        .{ .Path = .{ .segments = &transform_segs, .span = sp } },
    };
    const plain_call = Expr{ .Call = .{
        .callee = &callee,
        .args = &plain_args,
        .arg_names = &.{},
        .type_args = &.{},
        .is_infix = false,
        .span = sp,
    } };
    _ = try lowerExpr(&b, &plain_call);
    const plain_insts = b.blocks.items[b.cur.int()].insts;
    const plain_inst = plain_insts[plain_insts.len - 1];
    try testing.expect(plain_inst == .Call);
    try testing.expectEqual(plain_id, plain_inst.Call.func);
    try testing.expect(plain_inst.Call.exact);

    var array_transform_segs = [_]ast.Ident{.{ .name = "arrayTransform", .span = sp }};
    var inline_args = [_]Expr{
        .{ .Path = .{ .segments = &first_segs, .span = sp } },
        .{ .Path = .{ .segments = &other_segs, .span = sp } },
        .{ .Path = .{ .segments = &array_transform_segs, .span = sp } },
    };
    const inline_pick = try renamedImportDirectTarget(&b, callee_segs[0], &inline_args, &.{});
    try testing.expect(inline_pick != null);
    try testing.expectEqual(inline_id, inline_pick.?);
}

test "scope getter owner follows the class contributing an enclosing property" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);

    var inner_names = std.StringHashMap(void).init(testing.allocator);
    try inner_names.put("innerValue", {});
    try m.registry.hierarchy_shadow_names.put("Outer$Inner", .{
        .names = inner_names,
        .complete = true,
    });
    var outer_names = std.StringHashMap(void).init(testing.allocator);
    try outer_names.put("receiveException", {});
    try m.registry.hierarchy_shadow_names.put("Outer", .{
        .names = outer_names,
        .complete = true,
    });
    try m.registry.enclosing_class.put("Outer$Inner", "Outer");

    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    b.setOwnerClass("Outer$Inner");

    try testing.expectEqualStrings("Outer$Inner", sgetterOwner(&b, "innerValue").?);
    try testing.expectEqualStrings("Outer", sgetterOwner(&b, "receiveException").?);
}

test "bare enclosing property lowers with its outer getter owner" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var m = Module.default(a);
    defer m.deinit(a);
    var inner_names = std.StringHashMap(void).init(a);
    try inner_names.put("next", {});
    try m.registry.hierarchy_shadow_names.put("Outer$Inner", .{
        .names = inner_names,
        .complete = true,
    });
    var outer_names = std.StringHashMap(void).init(a);
    try outer_names.put("receiveException", {});
    try m.registry.hierarchy_shadow_names.put("Outer", .{
        .names = outer_names,
        .complete = true,
    });
    try m.registry.enclosing_class.put("Outer$Inner", "Outer");

    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();
    b.setOwnerClass("Outer$Inner");
    var enclosing = StringSet.init(a);
    try enclosing.put("receiveException", {});
    b.setEnclosingMembers(enclosing);
    try b.bind("this", b.allocReg());

    var seg = [_]ast.Ident{.{ .name = "receiveException", .span = dummySpan() }};
    const e = Expr{ .Path = .{ .segments = &seg, .span = dummySpan() } };
    const result = try lowerExpr(&b, &e);
    b.terminate(.{ .Return = result });
    const func = try b.finish("next", "Outer.Inner.next", build.typeString());

    try testing.expect(func.blocks[0].insts[0] == .LoadFromThisOrGlobal);
    const field = func.blocks[0].insts[0].LoadFromThisOrGlobal.name;
    try testing.expectEqualStrings(
        "$sgetter$Outer\u{1f}receiveException",
        m.consts.items[field.int()].String,
    );
}

test "super property in a lambda uses the enclosing this capture" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    b.setOwnerClass("Derived");
    b.setOuterNames(StringSet.init(testing.allocator));

    var receiver = Expr{ .Super = .{
        .qualifier = null,
        .label = null,
        .span = dummySpan(),
    } };
    const e = Expr{ .Member = .{
        .receiver = &receiver,
        .name = .{ .name = "label", .span = dummySpan() },
        .safe = false,
        .span = dummySpan(),
    } };
    const r = try lowerExpr(&b, &e);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "Derived.f", build.typeString());
    defer freeFunc(func);

    try testing.expectEqual(@as(usize, 2), func.blocks[0].insts.len);
    const capture = func.blocks[0].insts[0].LoadCapture;
    const call = func.blocks[0].insts[1].CallSuper;
    try testing.expectEqual(capture.dst, call.receiver);
    try testing.expectEqualStrings("this", func.capture_order[capture.idx]);
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

test "boxed capture interpolation reads the entry-hoisted cell value" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    var outer = StringSet.init(testing.allocator);
    try outer.put("count", {});
    b.setOuterNames(outer);
    var boxed = StringSet.init(testing.allocator);
    try boxed.put("count", {});
    b.setBoxedVars(boxed);

    var parts = [_]ast.StringPart{.{ .ShortInterp = .{ .name = "count", .span = dummySpan() } }};
    const e = Expr{ .StringTemplate = .{ .parts = &parts, .span = dummySpan() } };
    const r = try lowerExpr(&b, &e);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "f", build.typeString());
    defer freeFunc(func);

    var capture_reg: ?Reg = null;
    var value_reg: ?Reg = null;
    for (func.blocks[0].insts) |inst| switch (inst) {
        .LoadCapture => |lc| capture_reg = lc.dst,
        .CellGet => |cg| {
            try testing.expectEqual(capture_reg.?, cg.cell);
            value_reg = cg.dst;
        },
        else => {},
    };
    try testing.expect(capture_reg != null);
    try testing.expect(value_reg != null);
    const concat = func.blocks[0].insts[func.blocks[0].insts.len - 1].BinOp;
    try testing.expectEqual(value_reg.?, concat.rhs);
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

test "bare is-check type normalises to the file's exact-import class FQN" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer m.deinit(a);
    // Two packages declare a nested `Marker` under a same-named outer class:
    // both lift as `Operation$Marker`, so the bare simple name identifies
    // neither. The file's explicit import names exactly one; the check type
    // must carry that class's canonical FQN so the runtime compares identity.
    _ = try m.reserveClassFqn(a, "Operation$Marker", "com.ga.Operation.Marker", "com.ga", false);
    _ = try m.reserveClassFqn(a, "Operation$Marker", "com.gb.Operation.Marker", "com.gb", false);
    {
        var paths: std.ArrayList(ir.ModuleRegistry.ImportPath) = .empty;
        const segs = try a.alloc([]const u8, 4);
        segs[0] = "com";
        segs[1] = "ga";
        segs[2] = "Operation";
        segs[3] = "Marker";
        try paths.append(a, .{ .fqn = try a.dupe(u8, "com.ga.Operation.Marker"), .segs = segs });
        var inner_map = std.StringHashMap(std.ArrayList(ir.ModuleRegistry.ImportPath)).init(a);
        try inner_map.put("Marker", paths);
        try m.registry.import_aliases.put(span.FileId.from(0), inner_map);
    }
    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();
    const ty = ast.TypeRef{
        .name = .{ .name = "Marker", .span = dummySpan() },
        .nullable = false,
        .span = dummySpan(),
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
    try testing.expectEqualStrings("com.ga.Operation.Marker", loweredCheckTypeName(&b, &ty));
    // A file without the import keeps the bare simple name.
    const ty2 = ast.TypeRef{
        .name = .{ .name = "Marker", .span = span.Span.init(span.FileId.from(3), 0, 0) },
        .nullable = false,
        .span = span.Span.init(span.FileId.from(3), 0, 0),
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
    try testing.expectEqualStrings("Marker", loweredCheckTypeName(&b, &ty2));
}

test "anonymous object carries a lexical classifier identity" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);
    const sp = dummySpan();
    try m.registry.file_packages.put(sp.file, "sample");
    _ = try m.reserveClassFqn(a, "Marker", "sample.Marker", "sample", false);
    try m.registry.companion_singletons.put("Marker", "Marker$Companion");

    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();
    var segs = [_]ast.Ident{.{ .name = "Marker", .span = sp }};
    const expr = Expr{ .Path = .{ .segments = &segs, .span = sp } };
    const refs = try collectScopeClasses(&b, &expr);
    try testing.expectEqual(@as(usize, 1), refs.len);
    try testing.expectEqualStrings("Marker", refs[0].name);
    try testing.expectEqualStrings("sample.Marker", refs[0].fqn);
    try testing.expect(refs[0].has_companion);
}

test "trailing-lambda arity host accepts a signature-only candidate" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer m.deinit(a);
    // `launch(context, start, block)` as it looks to a file lowered BEFORE
    // the file that declares it: the signature (params, function-typed
    // tail) is lifted, but no body is attached yet. The arity host must
    // still pick it — skipping it left the trailing receiver lambda with a
    // spurious implicit `it` bound to the invocation's receiver argument.
    const params = try a.alloc(ir.Param, 4);
    params[0] = .{ .name = "this", .ty = .{ .name = "CoroutineScope", .nullable = false, .args = &.{} }, .default = null };
    params[1] = .{ .name = "context", .ty = .{ .name = "CoroutineContext", .nullable = false, .args = &.{} }, .default = null, .has_default = true };
    params[2] = .{ .name = "start", .ty = .{ .name = "CoroutineStart", .nullable = false, .args = &.{} }, .default = null, .has_default = true };
    params[3] = .{ .name = "block", .ty = .{ .name = "Function0", .nullable = false, .args = &.{} }, .default = null };
    const id = m.nextFuncId();
    try m.funcs.append(a, .{
        .id = id,
        .name = "launch",
        .fqn = "kotlinx.coroutines.launch",
        .package = "kotlinx.coroutines",
        .params = params,
        .return_ty = .{ .name = "Job", .nullable = false, .args = &.{} },
        .n_locals = 0,
        .blocks = &.{}, // signature only: hasBody() == false
        .entry = ir.BlockId.from(0),
        .is_suspend = false,
    });
    try m.func_index.append(a, .{ .name = "launch", .id = id });
    try m.rebuildFuncNameIndex(a);
    defer {
        a.free(m.funcs.items[id.int()].params);
        m.funcs.items[id.int()].params = &.{};
    }

    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();
    // `launch(Dispatchers.Default) { … }`: two user args, trailing lambda.
    const picked = overloadHostingTrailingLambda(&b, "launch", 2);
    try testing.expect(picked != null);
    try testing.expectEqual(id.int(), picked.?.int());
}

test "typed explicit extension receiver supplies trailing lambda arity" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer m.deinit(a);
    try m.registry.class_super_names.put("TestScope", try a.dupe([]const u8, &.{"CoroutineScope"}));

    const params = try a.alloc(ir.Param, 4);
    params[0] = .{ .name = "this", .ty = .{ .name = "CoroutineScope", .nullable = false, .args = &.{} }, .default = null };
    params[1] = .{ .name = "context", .ty = .{ .name = "CoroutineContext", .nullable = false, .args = &.{} }, .default = null, .has_default = true };
    params[2] = .{ .name = "start", .ty = .{ .name = "CoroutineStart", .nullable = false, .args = &.{} }, .default = null, .has_default = true };
    params[3] = .{ .name = "block", .ty = .{ .name = "Function0", .nullable = false, .args = &.{} }, .default = null };
    const id = m.nextFuncId();
    try m.funcs.append(a, .{
        .id = id,
        .name = "launch",
        .fqn = "launch",
        .package = "",
        .params = params,
        .return_ty = .{ .name = "Job", .nullable = false, .args = &.{} },
        .n_locals = 0,
        .blocks = &.{},
        .entry = ir.BlockId.from(0),
        .is_suspend = false,
        .kind = .top_level_extension,
    });
    try m.func_index.append(a, .{ .name = "launch", .id = id });
    try m.rebuildFuncNameIndex(a);
    defer {
        a.free(m.funcs.items[id.int()].params);
        m.funcs.items[id.int()].params = &.{};
    }

    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();
    const recv_reg = b.allocReg();
    try b.bind("outerScope", recv_reg);
    try b.setLocalDeclType("outerScope", "TestScope");
    var recv_segs = [_]ast.Ident{.{ .name = "outerScope", .span = dummySpan() }};
    const receiver = Expr{ .Path = .{ .segments = &recv_segs, .span = dummySpan() } };
    var implicit_it = [_]ast.Ident{.{ .name = "it", .span = dummySpan() }};
    const args = [_]Expr{.{ .Lambda = .{
        .params = &implicit_it,
        .body = .{ .stmts = &.{}, .span = dummySpan() },
        .span = dummySpan(),
        .implicit_it = true,
    } }};
    const arities = (try memberCallArgArities(&b, &receiver, "launch", &args, &.{})).?;
    defer a.free(arities);
    try testing.expectEqualSlices(i16, &.{0}, arities);
}

test "inherited member receiver lambda uses abstract defaults" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer m.deinit(a);
    try m.registry.class_super_names.put("ResumeTest", try a.dupe([]const u8, &.{"TestBase"}));

    var block_args = [_]ir.TypeRef{
        .{ .name = "CoroutineScope", .nullable = false, .args = &.{} },
        .{ .name = "Unit", .nullable = false, .args = &.{} },
    };
    const params = try a.alloc(ir.Param, 4);
    params[0] = .{ .name = "this", .ty = .{ .name = "TestBase", .nullable = false, .args = &.{} }, .default = null };
    params[1] = .{ .name = "expected", .ty = .{ .name = "Function1", .nullable = true, .args = &.{} }, .default = null };
    params[2] = .{ .name = "unhandled", .ty = .{ .name = "List", .nullable = false, .args = &.{} }, .default = null };
    params[3] = .{ .name = "block", .ty = .{ .name = "Function0", .nullable = false, .args = &block_args }, .default = null };
    const id = m.nextFuncId();
    try m.funcs.append(a, .{
        .id = id,
        .name = "runTest",
        .fqn = "TestBase.runTest",
        .package = "",
        .params = params,
        .return_ty = .{ .name = "Unit", .nullable = false, .args = &.{} },
        .n_locals = 0,
        .blocks = &.{},
        .entry = ir.BlockId.from(0),
        .is_suspend = false,
        .kind = .instance_method,
    });
    defer {
        a.free(m.funcs.items[id.int()].params);
        m.funcs.items[id.int()].params = &.{};
    }
    try m.registry.member_method_fids.put(try a.dupe(u8, "TestBase\x00runTest\x003"), id);
    var defaults: std.ArrayList(?FuncId) = .empty;
    try defaults.appendSlice(a, &.{ null, id, id, null });
    try m.registry.abstract_member_defaults.put(.{ .a = "TestBase", .b = "runTest" }, defaults);

    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();
    b.setOwnerClass("ResumeTest");
    const picked = memberHostingTrailingLambda(&b, "runTest", 1);
    try testing.expect(picked != null);
    try testing.expectEqual(id.int(), picked.?.int());
    try testing.expectEqualStrings("CoroutineScope", fnTypeReceiverHead(&b, params[3].ty).?);
}

test "headCompatible: literal heads disprove scalar params only" {
    // Literal Boolean disproves a String param — the local-fn overload
    // shape that recursed before selection existed.
    try std.testing.expect(!headCompatible("Boolean", "String", true));
    try std.testing.expect(headCompatible("Boolean", "Boolean", true));
    // Numeric literals coerce across the numeric family.
    try std.testing.expect(headCompatible("Int", "Long", true));
    try std.testing.expect(headCompatible("Int", "Double", true));
    try std.testing.expect(!headCompatible("Int", "String", true));
    // A lambda binds only function-shaped or generic params.
    try std.testing.expect(headCompatible("->", "() -> Unit", true));
    try std.testing.expect(headCompatible("->", "T", true));
    try std.testing.expect(!headCompatible("->", "String", true));
    try std.testing.expect(!headCompatible("String", "(Int) -> Int", true));
    // A parsed function type carries the synthetic `<function>` tag; a
    // lambda binds it under either strictness. `expect(…, predicate:
    // (Char) -> Boolean) { it == '-' }` regressed when the tag was not
    // recognized and the local fn was deemed inapplicable.
    try std.testing.expect(headCompatible("->", "<function>", true));
    try std.testing.expect(headCompatible("->", "<function>", false));
    // A user class head never disproves another named type (supertypes
    // are unknown here); generic/Any params accept anything.
    try std.testing.expect(headCompatible("MyThing", "Other", true));
    try std.testing.expect(headCompatible("String", "Any", true));
    try std.testing.expect(headCompatible("Int", "T", true));
    // Disproof-only lambda case (applicability decision): a lambda may
    // bind an unknown class name (a possible function typealias), so it
    // is not ruled inapplicable — but a definite scalar still disproves.
    try std.testing.expect(headCompatible("->", "MyPredicate", false));
    try std.testing.expect(!headCompatible("->", "MyPredicate", true));
    try std.testing.expect(!headCompatible("->", "String", false));
    try std.testing.expect(!headCompatible("->", "Int", false));
    // Nullable params adjudicate under the underlying head.
    try std.testing.expect(headCompatible("Boolean", "Boolean?", true));
    try std.testing.expect(!headCompatible("Boolean", "String?", true));
}

test "shared member resolution selects overloads and dispatch forms" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);
    const owner = try m.addClass(a, .{
        .id = ir.ClassId.from(0),
        .name = "Owner",
        .fqn = "sample.Owner",
        .package = "sample",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });

    const Add = struct {
        fn member(
            module: *Module,
            allocator: Allocator,
            owner_id: ir.ClassId,
            name: []const u8,
            ty: []const u8,
            is_private: bool,
            is_open: bool,
        ) !FuncId {
            const id = module.nextFuncId();
            const params = try allocator.alloc(ir.Param, 2);
            params[0] = .{ .name = "this", .ty = .{ .name = "Owner", .nullable = false, .args = &.{} }, .default = null };
            params[1] = .{ .name = "value", .ty = .{ .name = ty, .nullable = false, .args = &.{} }, .default = null };
            try module.funcs.append(allocator, .{
                .id = id,
                .name = name,
                .fqn = "sample.Owner.member",
                .package = "sample",
                .params = params,
                .return_ty = build.typeUnit(),
                .n_locals = 0,
                .blocks = &.{},
                .entry = ir.BlockId.from(0),
                .is_suspend = false,
                .kind = .instance_method,
                .has_receiver_param = true,
                .is_open = is_open,
            });
            const declared = try allocator.alloc(ir.TypeRef, 1);
            declared[0] = params[1].ty;
            try module.decl_sigs.put(id.int(), .{
                .enclosing_class = owner_id,
                .arity = .{ .required = 1, .total = 1, .has_vararg = false },
                .sig = declared,
                .kind = .instance_method,
                .visibility = if (is_private) .Private else .Public,
                .has_body = true,
            });
            try module.registerMemberDecl(allocator, "sample.Owner", name, id);
            return id;
        }
    };
    const int_pick = try Add.member(&m, a, owner, "pick", "Int", true, false);
    const bool_pick = try Add.member(&m, a, owner, "pick", "Boolean", true, false);
    m.classes.items[owner.int()].is_open = true;
    const final_pick = try Add.member(&m, a, owner, "finalPick", "Int", false, false);
    const virtual_pick = try Add.member(&m, a, owner, "virtualPick", "Int", false, true);

    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();
    b.setOwnerClass("Owner");
    var int_args = [_]Expr{.{ .IntLit = .{ .value = 1, .kind = .Int, .span = dummySpan() } }};
    var bool_args = [_]Expr{.{ .BoolLit = .{ .value = true, .span = dummySpan() } }};
    var unknown_name = [_]ast.Ident{.{ .name = "unknown", .span = dummySpan() }};
    var unknown_args = [_]Expr{.{ .Path = .{ .segments = &unknown_name, .span = dummySpan() } }};
    try testing.expectEqual(
        int_pick,
        (try resolvePrivateMemberCall(
            &b,
            "pick",
            dummySpan().file,
            &int_args,
            &.{},
        )).target.?,
    );
    try testing.expectEqual(
        bool_pick,
        (try resolvePrivateMemberCall(
            &b,
            "pick",
            dummySpan().file,
            &bool_args,
            &.{},
        )).target.?,
    );
    try testing.expect((try resolvePrivateMemberCall(
        &b,
        "pick",
        dummySpan().file,
        &unknown_args,
        &.{},
    )).target == null);

    const int_shapes = try buildArgShapes(&b, &int_args, &.{});
    defer a.free(int_shapes);
    const final_result = m.resolveMemberCall(owner, "finalPick", int_shapes, .{});
    try testing.expectEqual(ir.Module.MemberDispatch.direct, final_result.dispatch);
    try testing.expectEqual(final_pick, final_result.target.?);
    const virtual_result = m.resolveMemberCall(owner, "virtualPick", int_shapes, .{});
    try testing.expectEqual(ir.Module.MemberDispatch.virtual, virtual_result.dispatch);
    try testing.expectEqual(virtual_pick, virtual_result.target.?);
    const recv_reg = b.allocReg();
    try b.bind("target", recv_reg);
    try b.setLocalDeclType("target", "Owner");
    var recv_path = [_]ast.Ident{.{ .name = "target", .span = dummySpan() }};
    const recv_expr = Expr{ .Path = .{ .segments = &recv_path, .span = dummySpan() } };
    const lowered_virtual = try lowerResolvedMemberCall(
        &b,
        &recv_expr,
        .{ .name = "virtualPick", .span = dummySpan() },
        &int_args,
        &.{},
        &.{},
        .{ .name = "Owner", .nullable = false, .args = &.{} },
    );
    try testing.expect(lowered_virtual != null);
    const virtual_inst = b.blocks.items[b.cur.int()].insts[b.blocks.items[b.cur.int()].insts.len - 1];
    try testing.expect(virtual_inst == .CallVirtual);
    try testing.expectEqual(ir.MethodSlotId.fromFunc(virtual_pick), virtual_inst.CallVirtual.slot);
    m.classes.items[owner.int()].receiver_abi = .specialized;
    try testing.expect((try lowerResolvedMemberCall(
        &b,
        &recv_expr,
        .{ .name = "virtualPick", .span = dummySpan() },
        &int_args,
        &.{},
        &.{},
        .{ .name = "Owner", .nullable = false, .args = &.{} },
    )) == null);
    m.classes.items[owner.int()].receiver_abi = .instance;
    m.classes.items[owner.int()].is_open = false;
    m.classes.items[owner.int()].is_stub = true;
    const stub_result = m.resolveMemberCall(owner, "finalPick", int_shapes, .{});
    try testing.expectEqual(ir.Module.MemberDispatch.virtual, stub_result.dispatch);
    try testing.expectEqual(final_pick, stub_result.target.?);
    m.classes.items[owner.int()].is_stub = false;
    m.classes.items[owner.int()].is_value = true;
    const value_result = m.resolveMemberCall(owner, "finalPick", int_shapes, .{});
    try testing.expectEqual(ir.Module.MemberDispatch.virtual, value_result.dispatch);
    try testing.expectEqual(final_pick, value_result.target.?);
    m.classes.items[owner.int()].is_value = false;
    m.decl_sigs.getPtr(final_pick.int()).?.has_body = false;
    const bodyless_result = m.resolveMemberCall(owner, "finalPick", int_shapes, .{});
    try testing.expectEqual(ir.Module.MemberDispatch.virtual, bodyless_result.dispatch);
    try testing.expectEqual(final_pick, bodyless_result.target.?);
}

test "receiver callable emission respects members and lazy extensions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    var names = std.StringHashMap(void).init(a);
    try names.put("member", {});
    try m.registry.hierarchy_shadow_names.put("Target", .{
        .names = names,
        .complete = true,
    });

    const ext = m.nextFuncId();
    try m.funcs.append(a, .{
        .id = ext,
        .name = "extension",
        .fqn = "sample.extension",
        .package = "sample",
        .params = &.{},
        .return_ty = build.typeUnit(),
        .n_locals = 0,
        .blocks = &.{},
        .entry = ir.BlockId.from(0),
        .is_suspend = false,
    });
    try m.func_index.append(a, .{ .name = "extension", .id = ext });
    try m.decl_sigs.put(ext.int(), .{
        .receiver_ty = .{ .name = "Target", .nullable = false, .args = &.{} },
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .kind = .top_level_extension,
        .has_body = true,
    });

    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();
    const target_reg = b.allocReg();
    try b.bind("target", target_reg);
    try b.setLocalDeclType("target", "Target");
    for ([_][]const u8{ "value", "member", "extension" }) |name| {
        try b.bind(name, b.allocReg());
        try b.markParam(name);
        try b.markReceiverLambdaParam(name);
        try b.markReceiverLambdaArity(name, 0);
    }

    var receiver_segments = [_]ast.Ident{.{
        .name = "target",
        .span = dummySpan(),
    }};
    var receiver = Expr{ .Path = .{
        .segments = &receiver_segments,
        .span = dummySpan(),
    } };

    const Expect = struct {
        fn lower(
            builder: *FuncBuilder,
            recv: *Expr,
            name: []const u8,
            tag: std.meta.Tag(ir.Inst),
        ) !void {
            var callee = Expr{ .Member = .{
                .receiver = recv,
                .name = .{ .name = name, .span = dummySpan() },
                .safe = false,
                .span = dummySpan(),
            } };
            const call = Expr{ .Call = .{
                .callee = &callee,
                .args = &.{},
                .arg_names = &.{},
                .type_args = &.{},
                .is_infix = false,
                .span = dummySpan(),
            } };
            _ = try lowerExpr(builder, &call);
            const insts = builder.blocks.items[builder.cur.int()].insts;
            try testing.expectEqual(tag, std.meta.activeTag(insts[insts.len - 1]));
        }
    };

    try Expect.lower(&b, &receiver, "value", .CallValueWithThis);
    try Expect.lower(&b, &receiver, "member", .CallMemberOrValue);
    try Expect.lower(&b, &receiver, "extension", .CallMemberOrValue);
    const receiver_fallback = b.blocks.items[b.cur.int()].insts[
        b.blocks.items[b.cur.int()].insts.len - 1
    ].CallMemberOrValue;
    try testing.expect(receiver_fallback.fallback_takes_receiver);
    try testing.expect(receiver_fallback.fallback_receiver_shape_known);

    // A receiver-function-typed local is the same proven callable shape as a
    // parameter, even when its underlying value is an ordinary function
    // adapted at the assignment.
    try b.bind("typed", b.allocReg());
    try b.setLocalDeclRecvFn("typed");
    try Expect.lower(&b, &receiver, "typed", .CallValueWithThis);
    const typed_call = b.blocks.items[b.cur.int()].insts[
        b.blocks.items[b.cur.int()].insts.len - 1
    ].CallValueWithThis;
    try testing.expect(typed_call.receiver_shape_exact);

    // A plain local remains on the member-or-value compatibility form and
    // never receives the call receiver positionally.
    try b.bind("plain", b.allocReg());
    try b.markLocalFn("plain");
    try Expect.lower(&b, &receiver, "plain", .CallMemberOrValue);
    const plain_fallback = b.blocks.items[b.cur.int()].insts[
        b.blocks.items[b.cur.int()].insts.len - 1
    ].CallMemberOrValue;
    try testing.expect(!plain_fallback.fallback_takes_receiver);
    try testing.expect(plain_fallback.fallback_receiver_shape_known);

    // An erased receiver removes the member leg, but does not by itself prove
    // that a same-named local is callable. Exact value dispatch still requires
    // the local's declared receiver-function shape.
    try b.bind("unknown", b.allocReg());
    try b.markParam("unknown");
    try b.markErasedRecvParam("target");
    try Expect.lower(&b, &receiver, "value", .CallValueWithThis);
    try Expect.lower(&b, &receiver, "unknown", .CallMemberOrValue);
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

test "trailing lambda's implicit label survives a call-shaped receiver" {
    // `Stack().apply { … }`: lowering the receiver `Stack()` re-arms the
    // ambient pending label with "Stack"; the argument lambda must still
    // record "apply" so `return@apply` unwinds to the lambda, not into
    // the `apply` frame itself. Arena-backed: lambda lowering hangs side
    // tables off the module that outlive the builder.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);
    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();
    var recv_segs = [_]ast.Ident{.{ .name = "Stack", .span = dummySpan() }};
    var recv_callee = Expr{ .Path = .{ .segments = &recv_segs, .span = dummySpan() } };
    var recv_call = Expr{ .Call = .{
        .callee = &recv_callee,
        .args = &.{},
        .arg_names = &.{},
        .type_args = &.{},
        .is_infix = false,
        .span = dummySpan(),
    } };
    var callee = Expr{ .Member = .{
        .receiver = &recv_call,
        .name = .{ .name = "apply", .span = dummySpan() },
        .safe = false,
        .span = dummySpan(),
    } };
    var args = [_]Expr{.{ .Lambda = .{
        .params = &.{},
        .body = .{ .stmts = &.{}, .span = dummySpan() },
        .span = dummySpan(),
    } }};
    var arg_names = [_]?[]const u8{null};
    const e = Expr{ .Call = .{
        .callee = &callee,
        .args = &args,
        .arg_names = &arg_names,
        .type_args = &.{},
        .is_infix = false,
        .has_trailing_lambda = true,
        .span = dummySpan(),
    } };
    const r = try lowerExpr(&b, &e);
    b.terminate(.{ .Return = r });
    // Arena-owned: no freeFunc — the arena reclaims the whole build.
    _ = try b.finish("f", "f", build.typeUnit());
    var found = false;
    for (m.funcs.items) |*f| {
        if (f.is_lambda) {
            try testing.expectEqualStrings("apply", f.implicit_label orelse "");
            found = true;
        }
    }
    try testing.expect(found);
}
