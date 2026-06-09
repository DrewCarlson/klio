//! Expression lowering — the central recursive dispatch. Every sibling
//! lower file calls back into `lowerExpr`. Faithful port of the Rust
//! `lower/expr.rs`: literals, binary / unary primitive operations, paths,
//! member access, calls (including the overload-resolution ladder),
//! when / if / try as expressions, lambdas, and the remaining grammar.

const std = @import("std");
const ast = @import("ast");
const runtime = @import("runtime");
const ir = @import("../ir.zig");
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
const internArgNames = helpers.internArgNames;
const internTypeArgs = helpers.internTypeArgs;
const exprSpan = helpers.exprSpan;
const isAnyTypedPath = helpers.isAnyTypedPath;
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
    if (b.knowsOuter("this") or (in_lambda_body and b.isLambdaBody())) {
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
        // Skip the class-name shortcut when the enclosing class aliases this
        // name to a (mangled) nested object: a bare `Inner` inside `Outer`
        // must reach `Outer$Inner` even though a same-named top-level class
        // owns the bare `class_id`. Falling through to `lowerExpr` applies
        // the alias rewrite in the `Path` arm.
        var aliased = false;
        if (b.ownerClass()) |owner| {
            if (b.module.registry.nested_object_aliases.get(owner)) |m| {
                aliased = m.contains(n);
            }
        }
        if (!aliased and b.resolve(n) == null and !b.knowsOuter(n) and b.module.classId(n) != null) {
            const dst = b.allocReg();
            const nm = try b.module.internConst(b.allocator, .{ .String = n });
            try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = nm } });
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
        const f = idGet(Func, b.module.funcs.items, fid.int()) orelse continue;
        if (f.blocks.len == 0 or (f.params.len != 0 and f.params[f.params.len - 1].is_vararg)) continue;
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
            if (w.body) |body| _ = try lowerExpr(b, body);
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
                const r = try lowerWhen(b, w.subject, w.branches, exprSpan(expr));
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
                .ty = .{ .name = ck.ty.name.name, .nullable = ck.ty.nullable, .args = &.{} },
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
                .ty = .{ .name = cast.ty.name.name, .nullable = cast.ty.nullable, .args = &.{} },
                .safe = cast.safe,
            } });
            return dst;
        },
        .Postfix => return lowerPostfix(b, expr),
        .Labeled => return lowerLabeled(b, expr),
        .PropertyRef => |pr| {
            // `::greet` — a registered top-level fn loads the function value;
            // a tracked local / top-level prop keeps the unbound PropertyRef;
            // an untracked own-receiver member binds a MemberRef.
            const dst = b.allocReg();
            const nm = try b.module.internConst(b.allocator, .{ .String = pr.name.name });
            const is_tracked = b.resolve(pr.name.name) != null or isTopLevelProp(pr.name.name);
            if (b.module.funcId(pr.name.name) != null or b.module.classId(pr.name.name) != null) {
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
                .ast = ast_box,
                .captured_names = captured_names,
                .captures = captures,
            } });
            return dst;
        },
        .AnonFun => return lowerAnonFun(b, expr),
        .This => |t| {
            // `this` bare resolves to the implicit first param, or the
            // captured `this` slot inside a lambda body.
            const this_reg = b.resolve("this") orelse blk: {
                const idx = try b.recordCapture("this");
                const dst = b.allocReg();
                try b.push(.{ .LoadCapture = .{ .dst = dst, .idx = idx } });
                break :blk dst;
            };
            if (t.qualifier) |q| {
                const nm = try b.module.internConst(b.allocator, .{ .String = q.name });
                const dst = b.allocReg();
                try b.push(.{ .QualifiedThis = .{ .dst = dst, .receiver = this_reg, .qualifier = nm } });
                return dst;
            }
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

    // `==` on a boxed `Any` operand uses bitwise equality for Double/Float.
    if ((op == .Eq or op == .Neq) and
        (isBoxedToAnyForm(lhs) or isBoxedToAnyForm(rhs) or
            isAnyTypedPath(b, lhs) or isAnyTypedPath(b, rhs)))
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
    if ((op == .Lt or op == .Le or op == .Gt or op == .Ge) and
        (isGenericOperand(b, lhs) or isGenericOperand(b, rhs)))
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

    const l = try lowerExpr(b, lhs);
    const r = try lowerExpr(b, rhs);
    const dst = b.allocReg();
    try b.push(.{ .BinOp = .{ .dst = dst, .op = astBinop(op), .lhs = l, .rhs = r } });
    return dst;
}

fn isGenericOperand(b: *FuncBuilder, e: *const Expr) bool {
    return e.* == .Path and e.Path.segments.len == 1 and
        b.isGenericTypedParam(e.Path.segments[0].name);
}

/// Write `val` back to the lvalue `target` (shared by prefix ++/-- and the
/// postfix path's pre-snapshot path).
fn writeBackLvalue(b: *FuncBuilder, target: *const Expr, val: Reg) Allocator.Error!void {
    switch (target.*) {
        .Path => |p| {
            if (p.segments.len != 1) return;
            const name = p.segments[0].name;
            if (b.isBoxed(name)) {
                // Captured-and-written outer var: boxed at its binding site,
                // so the write is a `CellSet` on the shared cell (subsumes
                // the former captured-outer `StoreGlobal` fallback).
                const cell = try boxedCellReg(b, name);
                try b.push(.{ .CellSet = .{ .cell = cell, .value = val } });
            } else if (b.mutableHome(name)) |home| {
                try b.push(.{ .Move = .{ .dst = home, .src = val } });
            } else if (b.hasOwnMember(name) and b.resolve("this") != null) {
                const this_reg = b.resolve("this").?;
                const field = try b.module.internConst(b.allocator, .{ .String = name });
                try b.push(.{ .SetField = .{ .receiver = this_reg, .field = field, .value = val } });
            } else {
                try b.rebind(name, val);
            }
        },
        .Member => |m| {
            if (m.safe) return;
            const recv = try lowerReceiver(b, m.receiver);
            const field = try b.module.internConst(b.allocator, .{ .String = m.name.name });
            try b.push(.{ .SetField = .{ .receiver = recv, .field = field, .value = val } });
        },
        .Index => |ix| {
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
            try b.push(.{ .Move = .{ .dst = val_slot, .src = val } });
            const ret = b.allocReg();
            const nm = try b.module.internConst(b.allocator, .{ .String = "set" });
            try b.push(.{ .CallMember = .{
                .dst = ret,
                .receiver = recv,
                .name = nm,
                .args = key_start,
                .n_args = @as(u8, @intCast(n_keys)) + 1,
                .arg_names = &.{},
            } });
        },
        else => {},
    }
}

/// `Path` lowering — the full bare-name resolution ladder.
fn lowerPath(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    const segments = expr.Path.segments;
    const span0 = expr.Path.span;

    // `const val name = <literal>` inline.
    if (segments.len == 1 and b.ownerClass() != null and b.resolve(segments[0].name) == null) {
        const owner = b.ownerClass().?;
        if (b.module.registry.class_const_inits.get(.{ .a = owner, .b = segments[0].name })) |c| {
            return b.emitConst(c);
        }
    }
    // Nested-object alias rewrite.
    if (b.ownerClass()) |owner| {
        var renamed: ?[]const u8 = null;
        if (b.module.registry.nested_object_aliases.get(owner)) |m| {
            renamed = m.get(segments[0].name);
        }
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
        // this name.
        if (b.hasOwnMember(name0)) {
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
        // A bare name that is a known class is a class reference.
        if (b.module.classId(name0) != null) {
            const cls = b.allocReg();
            const n = try b.module.internConst(b.allocator, .{ .String = name0 });
            try b.push(.{ .LoadGlobal = .{ .dst = cls, .name = n } });
            const dst = b.allocReg();
            const sentinel = try b.module.internConst(b.allocator, .{ .String = "<class-companion-or-self>" });
            try b.push(.{ .GetField = .{ .dst = dst, .receiver = cls, .field = sentinel } });
            return dst;
        }
        // A bare builtin type name used as a qualifier.
        if (isBuiltinTypeName(name0)) {
            const this_idx = try b.recordCapture("this");
            const dst = b.allocReg();
            const name = try b.module.internConst(b.allocator, .{ .String = name0 });
            try b.push(.{ .LoadFromThisOrGlobal = .{ .dst = dst, .this_idx = this_idx, .name = name } });
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
        }
        // A bare reference to a known top-level property is a global read.
        if (isTopLevelProp(name0) and !b.hasOwnMember(name0) and !b.hasEnclosingMember(name0)) {
            const dst = b.allocReg();
            const nm = try b.module.internConst(b.allocator, .{ .String = name0 });
            try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = nm } });
            return dst;
        }
        if (b.resolve("this")) |this_reg| {
            // A bare name resolving to a known top-level fn is a
            // value-position function reference; skip the GetField shortcut.
            const is_known_global = b.module.funcId(name0) != null;
            if (!is_known_global) {
                const dst = b.allocReg();
                const nm = try b.module.internConst(b.allocator, .{ .String = name0 });
                try b.push(.{ .GetField = .{ .dst = dst, .receiver = this_reg, .field = nm } });
                return dst;
            }
        }
        const this_idx = try b.recordCapture("this");
        const dst = b.allocReg();
        const name = try sgetterName(b, name0);
        try b.push(.{ .LoadFromThisOrGlobal = .{ .dst = dst, .this_idx = this_idx, .name = name } });
        return dst;
    }

    // Multi-segment paths. Try the full FQN against the host first.
    if (segments.len >= 2 and
        isPackageHead(segments[0].name) and
        (isPkgRoot(segments[0].name) or !b.isLambdaBody()) and
        b.resolve(segments[0].name) == null and
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
    } else {
        // Unresolved head: route through `this` / the enclosing receiver.
        const this_idx = try b.recordCapture("this");
        const dst = b.allocReg();
        const n = try b.module.internConst(b.allocator, .{ .String = first.name });
        try b.push(.{ .LoadFromThisOrGlobal = .{ .dst = dst, .this_idx = this_idx, .name = n } });
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
            .Interp => |*e| try lowerExpr(b, e),
        };
        const dst = b.allocReg();
        try b.push(.{ .BinOp = .{ .dst = dst, .op = .StringConcat, .lhs = cur, .rhs = piece } });
        cur = dst;
    }
    return cur;
}

fn lowerShortInterp(b: *FuncBuilder, ident: ast.Ident) Allocator.Error!Reg {
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
    const this_idx = try b.recordCapture("this");
    const dst = b.allocReg();
    const n = try b.module.internConst(b.allocator, .{ .String = ident.name });
    try b.push(.{ .LoadFromThisOrGlobal = .{ .dst = dst, .this_idx = this_idx, .name = n } });
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
        if (isPackageHead(head) and
            (isPkgRoot(head) or !b.isLambdaBody()) and
            b.resolve(head) == null and
            !b.knowsOuter(head) and
            b.module.classId(head) == null and
            b.resolve("this") == null)
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
        if (b.currentInlineFn() != null) {
            b.terminate(.{ .LabeledReturn = .{ .label = lbl.name, .value = r } });
        } else {
            b.terminate(.{ .Return = r });
        }
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
        ch.* = .{ .type_name = h.c.ty.name.name, .handler = h.blk, .exception_reg = h.exc };
    }
    b.attachCatches(cur_id, catch_handlers, finally_entry);
    if (t.finally) |blk| try b.pushFinally(blk);
    const body_val = try lowerBlock(b, &t.body);
    try b.push(.{ .Move = .{ .dst = result, .src = body_val } });
    if (finally_entry) |fin| {
        b.terminate(.{ .Goto = fin });
    } else {
        b.terminate(.{ .Goto = exit });
    }

    // Each handler body.
    for (handlers) |h| {
        b.switchTo(h.blk);
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
        const finally_done = try b.allocBlock();
        b.switchTo(fin);
        if (t.finally) |blk| _ = try lowerBlock(b, &blk);
        b.terminate(.{ .Goto = finally_done });
        b.switchTo(finally_done);
        b.setFinallyDoneFor(cur_id, finally_done);
        b.terminate(.{ .Goto = exit });
    }

    b.switchTo(exit);
    return result;
}

fn lowerLambda(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    const lam = expr.Lambda;
    // `outer_names` / `inherited_rlp` ownership passes into the lambda lower.
    const outer_names = try b.visibleNames();
    const inherited_rlp = try b.receiverLambdaParamNames();
    var outer_boxed = try b.boxedVarsSnapshot();
    defer outer_boxed.deinit();
    const enclosing_owner = try enclosingOwnerFor(b);

    const lowered = try lowerLambdaBodyCapturing(
        b.module,
        lam.params,
        &lam.body,
        outer_names,
        &outer_boxed,
        inherited_rlp,
        enclosing_owner,
    );
    const body_func = lowered.func;
    const captured_names = lowered.captures;

    // Record the implicit label.
    if (b.pending_lambda_label) |label| {
        b.pending_lambda_label = null;
        if (idGetMut(Func, b.module.funcs.items, body_func.int())) |f| {
            f.implicit_label = label;
        }
    }
    const captures = try b.allocator.alloc(Reg, captured_names.len);
    for (captured_names, captures) |n, *c| c.* = try resolveCapture(b, n);

    const param_names = try lambdaParamNames(b.allocator, lam.params);
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
    for (af.params, param_names, param_idents) |p, *pn, *pi| {
        pn.* = p.name.name;
        pi.* = p.name;
    }
    // `outer_names` / `inherited_rlp` ownership passes into the lambda lower.
    const outer_names = try b.visibleNames();
    const inherited_rlp = try b.receiverLambdaParamNames();
    var outer_boxed = try b.boxedVarsSnapshot();
    defer outer_boxed.deinit();
    const enclosing_owner = try enclosingOwnerFor(b);

    const lowered = try lowerLambdaBodyCapturingKind(
        b.module,
        param_idents,
        &body_block,
        outer_names,
        false,
        &outer_boxed,
        null,
        inherited_rlp,
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
                    .n_args = @as(u8, @intCast(n_keys)) + 1,
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
            switch (inner.*) {
                .Path => |p| {
                    if (p.segments.len == 1) {
                        const nm = p.segments[0].name;
                        if (b.isBoxed(nm)) {
                            // Captured-and-written outer var: boxed at its
                            // binding site, so `++`/`--` is a `CellSet` on
                            // the shared cell (subsumes the former captured-
                            // outer `StoreGlobal` fallback).
                            const cell = try boxedCellReg(b, nm);
                            try b.push(.{ .CellSet = .{ .cell = cell, .value = new } });
                        } else if (b.mutableHome(nm)) |home| {
                            try b.push(.{ .Move = .{ .dst = home, .src = new } });
                        } else if (b.hasOwnMember(nm) and b.resolve("this") != null) {
                            const this_reg = b.resolve("this").?;
                            const field = try b.module.internConst(b.allocator, .{ .String = nm });
                            try b.push(.{ .SetField = .{ .receiver = this_reg, .field = field, .value = new } });
                        } else {
                            try b.rebind(nm, new);
                        }
                    }
                },
                .Member => |m| {
                    if (!m.safe) {
                        const recv = try lowerReceiver(b, m.receiver);
                        const field = try b.module.internConst(b.allocator, .{ .String = m.name.name });
                        try b.push(.{ .SetField = .{ .receiver = recv, .field = field, .value = new } });
                    }
                },
                .Index => |ix| {
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
                    try b.push(.{ .Move = .{ .dst = val_slot, .src = new } });
                    const dst = b.allocReg();
                    const nm = try b.module.internConst(b.allocator, .{ .String = "set" });
                    try b.push(.{ .CallMember = .{
                        .dst = dst,
                        .receiver = recv,
                        .name = nm,
                        .args = key_start,
                        .n_args = @as(u8, @intCast(n_keys)) + 1,
                        .arg_names = &.{},
                    } });
                },
                else => {},
            }
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
            if (w.body) |body| _ = try lowerExpr(b, body);
            b.popLoop();
            const c = try lowerExpr(b, w.cond);
            b.terminate(.{ .Branch = .{ .cond = c, .t = body_blk, .f = exit } });
            b.switchTo(exit);
            return b.emitConst(.Unit);
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

fn lastArgIsLambdaOrAnon(args: []const Expr) bool {
    if (args.len == 0) return false;
    const last = args[args.len - 1];
    return last == .Lambda or last == .AnonFun;
}

fn lowerCall(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    const call = expr.Call;
    const callee = call.callee;
    const args = call.args;
    const ast_arg_names = call.arg_names;
    const ast_type_args = call.type_args;
    const is_infix = call.is_infix;

    // A member call onto an inline `reified` extension (`xs.filterIsInstance<T>()`).
    if (!is_infix and callee.* == .Member and !callee.Member.safe and
        (ast_type_args.len != 0 or b.peekExpected() != null))
    {
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
            if (try tryInlineCallWithTypeArgs(b, mname, args, ast_arg_names, receiver, ast_type_args, exp_ptr)) |r| {
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
    if (callee.* == .Path and try anyLambdaWritesOuter(b, args)) {
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
    if (segments.len == 1) {
        var needs_this = false;
        if (b.module.funcId(segments[0].name)) |fid| {
            if (idGet(Func, b.module.funcs.items, fid.int())) |f| {
                needs_this = f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this");
            }
        }
        if (needs_this) {
            const this_reg = try resolveThisForBareCall(b);
            if (this_reg) |tr| try run_regs.append(b.allocator, tr);
        }
    }
    try run_regs.appendSlice(b.allocator, arg_regs);
    const n_args: u8 = @intCast(run_regs.items.len);
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
        if (b.module.funcId(segments[0].name)) |func_id| {
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
    const callee_reg = try lowerExpr(b, callee);
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
    } });
    return dst;
}

/// The general call path: inline expansion, infix, scope-fn markers, tailrec,
/// value invocation, class constructors, member dispatch, and the long
/// overload-selection ladder.
fn lowerCallGeneral(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    const call = expr.Call;
    const callee = call.callee;
    const args = call.args;
    const ast_arg_names = call.arg_names;
    const ast_type_args = call.type_args;
    const is_infix = call.is_infix;

    // Inline expansion (suspend-inline only).
    if (!is_infix and callee.* == .Path and callee.Path.segments.len == 1) {
        const nm = callee.Path.segments[0].name;
        if (b.inlineLambdaFor(nm)) |lam| {
            return spliceInlineLambda(b, lam, args);
        }
        const inline_call_shape = CallShape{
            .want = args.len,
            .last_is_lambda = lastArgIsLambdaOrAnon(args),
        };
        if (inlineFnAstForRecv(nm, inline_call_shape, b.recvTy())) |f| {
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
                    const positive = if (b.recvTy()) |cur|
                        (!std.mem.eql(u8, cur, rn) and !eqOptStr(b.ownerClass(), rn))
                    else
                        false;
                    const member_wins = b.hasEnclosingMember(nm) and
                        (if (b.ownerClass()) |oc| !std.mem.eql(u8, oc, rn) else false);
                    break :blk positive or member_wins;
                }
                break :blk false;
            };
            const needs_inline = !recv_mismatch and
                (f.is_suspend or argLambdaHasNonlocalReturn(args) or has_reified or shadowed_by_member);
            const expected = b.peekExpected();
            const exp_ptr: ?*const ast.TypeRef = if (expected) |*_e| _e else null;
            if (needs_inline) {
                if (try tryInlineCallWithTypeArgs(b, nm, args, ast_arg_names, null, ast_type_args, exp_ptr)) |r| {
                    return r;
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

    // `suspend { … }` builder.
    if (callee.* == .Path and callee.Path.segments.len == 1 and
        std.mem.eql(u8, callee.Path.segments[0].name, "suspend") and
        args.len == 1 and args[0] == .Lambda)
    {
        return lowerExpr(b, &args[0]);
    }
    // `contract { … }` — compile-time marker with no runtime effect.
    if (callee.* == .Path and callee.Path.segments.len == 1 and
        std.mem.eql(u8, callee.Path.segments[0].name, "contract") and
        args.len == 1 and args[0] == .Lambda)
    {
        return b.emitConst(.Unit);
    }
    // Self-call inside a tailrec fn → TailJump terminator.
    if (callee.* == .Path and callee.Path.segments.len == 1) {
        if (b.tailrecSelf()) |ts| {
            if (std.mem.eql(u8, ts, callee.Path.segments[0].name)) {
                const run = try lowerArgRun(b, args);
                b.terminate(.{ .TailJump = .{ .args = run[0], .n_args = run[1] } });
                const dead = try b.allocBlock();
                b.switchTo(dead);
                return b.emitConst(.Unit);
            }
        }
    }

    // A single-name callee resolving to a local binding / parameter is a
    // value invocation.
    if (callee.* == .Path and callee.Path.segments.len == 1) {
        if (try lowerValueInvocation(b, callee, args, ast_arg_names)) |r| return r;
    }

    // Whether a single-segment class-name call resolves to the constructor.
    const shadowed_by_class = try shadowedByClass(b, callee, args);

    // Path-callee with a registered top-level fn → Call{func}.
    if (callee.* == .Path and callee.Path.segments.len == 1) {
        if (try lowerPathCall(b, expr, shadowed_by_class)) |r| return r;
    }

    // Path-callee with a registered class name.
    if (callee.* == .Path and callee.Path.segments.len == 1) {
        if (b.module.classId(callee.Path.segments[0].name)) |class_id| {
            const run = try lowerArgRun(b, args);
            const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
            const dst = b.allocReg();
            if (shadowed_by_class) {
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
                try b.push(.{ .CallMemberOrGlobal = .{
                    .dst = dst,
                    .this_idx = this_idx,
                    .name = nmc,
                    .args = run[0],
                    .n_args = run[1],
                    .arg_names = arg_names,
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

    // Unresolved bare-name call.
    if (callee.* == .Path and callee.Path.segments.len == 1 and
        b.resolve(callee.Path.segments[0].name) == null and
        !b.knowsOuter(callee.Path.segments[0].name) and
        b.module.classId(callee.Path.segments[0].name) == null and
        b.module.funcId(callee.Path.segments[0].name) == null)
    {
        if (try lowerUnresolvedBareCall(b, callee, args, ast_arg_names)) |r| return r;
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
    const callee_r = try lowerExpr(b, callee);
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

/// True when a bodied same-name function already accepts this call's arity.
fn aFuncFits(b: *FuncBuilder, nm: []const u8, want: usize) bool {
    for (b.module.funcsBySimpleName(nm)) |fid| {
        const mf = idGet(Func, b.module.funcs.items, fid.int()) orelse continue;
        if (mf.blocks.len == 0) continue;
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

fn eqOptStr(a: ?[]const u8, b: []const u8) bool {
    if (a) |x| return std.mem.eql(u8, x, b);
    return false;
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
        const this_reg: ?Reg = if (b.knowsOuter("this") or b.isLambdaBody())
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
        var callee_reg = reg;
        if (b.isBoxed(name0)) {
            const c = b.allocReg();
            try b.push(.{ .CellGet = .{ .dst = c, .cell = reg } });
            callee_reg = c;
        }
        // A bare call to a receiver-typed function param.
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
        const run = try lowerArgRun(b, args);
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
fn shadowedByClass(b: *FuncBuilder, callee: *const Expr, args: []const Expr) Allocator.Error!bool {
    if (callee.* != .Path or callee.Path.segments.len != 1) return false;
    const name = callee.Path.segments[0].name;
    if (b.module.classId(name) == null) return false;
    const nargs = args.len;
    if (lastArgIsLambda(args)) {
        // A trailing lambda routes to a same-named factory with a
        // function-typed param to receive it; only when none fits is it a ctor.
        var factory_takes_lambda = false;
        for (b.module.func_index.items) |entry| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            const f = idGet(Func, b.module.funcs.items, entry.id.int()) orelse continue;
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
        if (idGet(Func, b.module.funcs.items, fid.int())) |f| {
            const last_vararg = f.params.len != 0 and f.params[f.params.len - 1].is_vararg;
            canonical_cant_take = !last_vararg and nargs > f.params.len;
        }
    }
    var any_factory_applicable = false;
    for (b.module.func_index.items) |entry| {
        if (!std.mem.eql(u8, entry.name, name)) continue;
        if (b.module.decl_user_arity.get(entry.id.int())) |arity| {
            const n: u32 = @intCast(nargs);
            if (n >= arity.required and (arity.trailing_vararg or n <= arity.total)) {
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
fn lowerPathCall(b: *FuncBuilder, expr: *const Expr, shadowed_by_class: bool) Allocator.Error!?Reg {
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
        const this_reg: ?Reg = if (b.knowsOuter("this") or b.isLambdaBody())
            try resolveCapture(b, "this")
        else
            b.resolve("this");
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

    // FQN-precedence: an explicit import routes a collision call.
    const collision = b.module.funcsBySimpleName(name0).len > 1;
    var imported_func_id: ?FuncId = null;
    if (collision) {
        if (b.module.importAliasIn(segments[0].span.file, name0)) |segs| {
            if (segs.len >= 2) {
                const fqn = try joinStrs(b.allocator, segs);
                defer b.allocator.free(fqn);
                imported_func_id = b.module.funcIdByFqn(fqn);
            }
        }
    }
    if (imported_func_id) |func_id| {
        if (!shadowed_by_class) {
            const needs_this = blk: {
                if (idGet(Func, b.module.funcs.items, func_id.int())) |f| {
                    break :blk f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this");
                }
                break :blk false;
            };
            if (!needs_this) {
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
    }

    // Arity-aware bare-call lookup.
    const want = args.len;
    const cands = b.module.funcsBySimpleName(name0);
    const last_arg_lambda = lastArgIsLambda(args);

    const name_is_alias = isAliasName(name0);
    const intrinsic_owns_all = std.mem.eql(u8, name0, "compareValues") or
        std.mem.eql(u8, name0, "compareValuesBy");

    const contract_with_msg = (std.mem.eql(u8, name0, "require") or
        std.mem.eql(u8, name0, "check") or std.mem.eql(u8, name0, "checkNotNull")) and
        lastArgIsLambda(args);
    const prefer_member = b.resolve("this") != null and b.hasOwnMember(name0) and
        b.resolve(name0) == null and !b.isLocalFn(name0) and !b.isLocalExtFn(name0) and
        !contract_with_msg;

    const cast_pick: ?FuncId = if (intrinsic_owns_all) null else try overloadPickByCast(b, cands, args, want);

    var bare_func_id: ?FuncId = null;
    if (!(intrinsic_owns_all or (prefer_member and cast_pick == null))) {
        bare_func_id = cast_pick;
        if (bare_func_id == null) bare_func_id = findCand(b, cands, want, .non_ext_arity);
        if (bare_func_id == null) bare_func_id = findCand(b, cands, want, .ext_arity);
        if (bare_func_id == null and last_arg_lambda) bare_func_id = findCand(b, cands, want, .ext_arity_tl);
        if (bare_func_id == null and last_arg_lambda) bare_func_id = findCand(b, cands, want, .non_ext_arity_tl);
        if (bare_func_id == null and !name_is_alias) {
            bare_func_id = try fallbackByDeclArity(b, cands, name0, want);
        }
    }

    // Prefer the same-name extension overload whose receiver matches the
    // enclosing extension's declared receiver.
    if (bare_func_id) |chosen| {
        if (b.recvTy()) |recv| {
            if (!matchesRecv(b, chosen, recv)) {
                var i: usize = 0;
                var found: ?FuncId = null;
                while (i < cands.len) : (i += 1) {
                    if (arityMatch(b, cands[i], want) and matchesRecv(b, cands[i], recv)) {
                        found = cands[i];
                        break;
                    }
                }
                if (found) |fnd| bare_func_id = fnd;
            }
        }
    }

    const was_cast = cast_pick != null and bare_func_id != null and bare_func_id.? == cast_pick.?;

    // Symbol-index resolution (the PRIMARY path): resolve the bare name as
    // a pure function of (caller package, caller imports, complete header
    // set). Where it resolves to a unique target the lowered call binds by
    // exact FQN; otherwise the order-based heuristic pick above is retained
    // as the fallback. The index is a faithful superset — it never selects
    // a different target than the heuristic for a name it resolves; the
    // KLIO_RESOLVE_AUDIT detector below proves zero divergence over the
    // green corpus.
    const index_pick = b.module.resolveBareCallIndexed(
        name0,
        b.self_package,
        segments[0].span.file,
        want,
        last_arg_lambda,
    );
    resolveAudit(b, name0, bare_func_id, index_pick);

    if (bare_func_id) |func_id| {
        if (!shadowed_by_class) {
            // Prefer the index's unique FQN-qualified target when it
            // resolves; it equals the heuristic pick on the green corpus,
            // so this routes the same call through the exact-FQN binding
            // instead of the order-sensitive path.
            const final_id = index_pick orelse func_id;
            return try emitBareFuncCall(b, expr, final_id, was_cast);
        }
    }
    return null;
}

/// Opt-in consistency detector for the symbol index (`KLIO_RESOLVE_AUDIT`).
/// For every bare call it compares the index's resolved FQN against the
/// order-based heuristic's pick and logs any divergence. A non-zero count
/// means the index is not yet a faithful superset of the heuristic on the
/// audited program — the index must equal the heuristic (or defer) for
/// every currently-green program.
fn resolveAudit(b: *FuncBuilder, name: []const u8, heuristic: ?FuncId, index: ?FuncId) void {
    if (!resolveAuditOn()) return;
    // The index only commits when it resolves a UNIQUE target; a `null`
    // index pick means "defer to the heuristic" and is never a divergence.
    const idx = index orelse return;
    const heur = heuristic orelse {
        resolveAuditLog(b, name, null, idx);
        return;
    };
    if (idx.int() != heur.int()) resolveAuditLog(b, name, heur, idx);
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

fn resolveAuditLog(b: *FuncBuilder, name: []const u8, heuristic: ?FuncId, index: FuncId) void {
    const heur_fqn = if (heuristic) |h| fqnOf(b, h) else "<none>";
    const idx_fqn = fqnOf(b, index);
    std.debug.print("[KLIO_RESOLVE_AUDIT] divergence: bare '{s}' heuristic={s} index={s}\n", .{ name, heur_fqn, idx_fqn });
}

fn fqnOf(b: *FuncBuilder, id: FuncId) []const u8 {
    if (idGet(Func, b.module.funcs.items, id.int())) |f| return f.fqn;
    return "<invalid>";
}

fn matchesRecv(b: *FuncBuilder, fid: FuncId, recv: []const u8) bool {
    const f = idGet(Func, b.module.funcs.items, fid.int()) orelse return false;
    if (f.blocks.len == 0) return false;
    if (f.params.len == 0) return false;
    return std.mem.eql(u8, f.params[0].name, "this") and std.mem.eql(u8, f.params[0].ty.name, recv);
}

const CandKind = enum { non_ext_arity, ext_arity, ext_arity_tl, non_ext_arity_tl };

fn findCand(b: *FuncBuilder, cands: []const FuncId, want: usize, kind: CandKind) ?FuncId {
    for (cands) |fid| {
        const non_ext = isNonExt(b, fid);
        const not_low = isNotLow(b, fid);
        switch (kind) {
            .non_ext_arity => if (non_ext and arityMatch(b, fid, want) and not_low) return fid,
            .ext_arity => if (!non_ext and arityMatch(b, fid, want) and not_low) return fid,
            .ext_arity_tl => if (!non_ext and arityMatchTl(b, fid, want) and not_low) return fid,
            .non_ext_arity_tl => if (non_ext and arityMatchTl(b, fid, want) and not_low) return fid,
        }
    }
    return null;
}

fn userParams(f: *const Func) usize {
    if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) {
        return f.params.len - 1;
    }
    return f.params.len;
}

fn arityMatch(b: *FuncBuilder, fid: FuncId, want: usize) bool {
    const f = idGet(Func, b.module.funcs.items, fid.int()) orelse return false;
    const last_not_vararg = f.params.len == 0 or !f.params[f.params.len - 1].is_vararg;
    return f.blocks.len != 0 and last_not_vararg and userParams(f) == want;
}

fn arityMatchTl(b: *FuncBuilder, fid: FuncId, want: usize) bool {
    const f = idGet(Func, b.module.funcs.items, fid.int()) orelse return false;
    const up = userParams(f);
    const last_is_fn = f.params.len != 0 and std.mem.startsWith(u8, f.params[f.params.len - 1].ty.name, "Function");
    if (f.blocks.len == 0 or !last_is_fn or up < want or want < 1) return false;
    const this_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
    const lead = want - 1;
    const last_user = up - 1;
    var i = lead;
    while (i < last_user) : (i += 1) {
        if (this_off + i >= f.params.len or !f.params[this_off + i].has_default) return false;
    }
    return true;
}

fn isNonExt(b: *FuncBuilder, fid: FuncId) bool {
    const f = idGet(Func, b.module.funcs.items, fid.int()) orelse return true;
    return f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this");
}

fn isNotLow(b: *FuncBuilder, fid: FuncId) bool {
    const f = idGet(Func, b.module.funcs.items, fid.int()) orelse return false;
    return !f.low_priority;
}

fn declArity(b: *FuncBuilder, fid: FuncId) ?u32 {
    return b.module.decl_user_params.get(fid.int());
}

fn fallbackByDeclArity(b: *FuncBuilder, cands: []const FuncId, name0: []const u8, want: usize) Allocator.Error!?FuncId {
    const fallback = b.module.funcId(name0);
    const want_u32: u32 = @intCast(want);
    const fallback_fits = blk: {
        if (fallback) |fid| {
            if (declArity(b, fid)) |n| break :blk n == want_u32;
        }
        break :blk true;
    };
    if (fallback_fits) return fallback;
    // Prefer a candidate whose declared arity fits.
    for (cands) |fid| {
        if (isNonExt(b, fid) and declArity(b, fid) == want_u32) return fid;
    }
    for (cands) |fid| {
        if (!isNonExt(b, fid) and declArity(b, fid) == want_u32) return fid;
    }
    return fallback;
}

fn isAliasName(name: []const u8) bool {
    const names = [_][]const u8{
        "maxOf",           "minOf",      "max",                 "min",
        "print",           "println",    "listOf",              "mutableListOf",
        "arrayListOf",     "setOf",      "mutableSetOf",        "hashSetOf",
        "linkedSetOf",     "mapOf",      "mutableMapOf",        "hashMapOf",
        "linkedMapOf",     "arrayOf",    "arrayOfNulls",        "emptyArray",
        "emptyList",       "emptySet",   "emptyMap",            "listOfNotNull",
        "setOfNotNull",    "buildList",  "buildSet",            "buildMap",
        "buildString",     "TODO",       "error",               "compareValues",
        "compareValuesBy", "compareBy",  "compareByDescending", "naturalOrder",
        "reverseOrder",    "sequenceOf", "emptySequence",       "generateSequence",
        "sequence",
    };
    for (names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

/// Emit a resolved bare-name `Call` (or the receiver-prepended forms).
fn emitBareFuncCall(b: *FuncBuilder, expr: *const Expr, func_id: FuncId, was_cast: bool) Allocator.Error!Reg {
    const call = expr.Call;
    const callee = call.callee;
    const args = call.args;
    const ast_arg_names = call.arg_names;
    const ast_type_args = call.type_args;

    const needs_this = blk: {
        if (idGet(Func, b.module.funcs.items, func_id.int())) |f| {
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
        if (idGet(Func, b.module.funcs.items, func_id.int())) |f| {
            if (f.is_tailrec) break :blk true;
        }
        for (b.module.tailrec_fn_names.items) |n| {
            if (std.mem.eql(u8, n, callee.Path.segments[0].name)) break :blk true;
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
        .exact = was_cast,
    } });
    return dst;
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
    const run = try lowerArgRun(b, all);

    // Target params for trailing-lambda arg-name synthesis.
    var target_params: [][]const u8 = &.{};
    if (idGet(Func, b.module.funcs.items, func_id.int())) |f| {
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
        const uargs = try lowerArgRun(b, args);
        const uarg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
        const nmc = try b.module.internConst(b.allocator, .{ .String = callee.Path.segments[0].name });
        const dst = b.allocReg();
        if (b.isLambdaBody()) {
            const this_idx = try b.recordCapture("this");
            try b.push(.{ .CallMemberOrGlobal = .{
                .dst = dst,
                .this_idx = this_idx,
                .name = nmc,
                .args = uargs[0],
                .n_args = uargs[1],
                .arg_names = uarg_names,
            } });
            return dst;
        }
        try b.push(.{ .CallMember = .{
            .dst = dst,
            .receiver = this_reg,
            .name = nmc,
            .args = uargs[0],
            .n_args = uargs[1],
            .arg_names = uarg_names,
        } });
        return dst;
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

fn allNull(names: []const ?[]const u8) bool {
    for (names) |n| {
        if (n != null) return false;
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
    const contract_with_msg = (std.mem.eql(u8, name0, "require") or
        std.mem.eql(u8, name0, "check") or std.mem.eql(u8, name0, "checkNotNull")) and
        lastArgIsLambda(args);
    if (contract_with_msg) return null;
    if (b.resolve(name0) != null or b.knowsOuter(name0) or !b.hasOwnMember(name0)) return null;
    const this_reg = b.resolve("this") orelse return null;

    // Private own-class methods bind statically.
    if (b.privateMethodFid(name0)) |fid| {
        const args_start = b.allocReg();
        try b.push(.{ .Move = .{ .dst = args_start, .src = this_reg } });
        for (args, 0..) |*a, i| {
            const r = try lowerExpr(b, a);
            try b.push(.{ .Move = .{
                .dst = Reg.from(args_start.int() + @as(u32, @intCast(i)) + 1),
                .src = r,
            } });
        }
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
            .n_args = @as(u8, @intCast(args.len)) + 1,
            .arg_names = arg_names,
            .type_args = &.{},
            .exact = false,
        } });
        return dst;
    }
    const run = try lowerArgRun(b, args);
    const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
    const dst = b.allocReg();
    const nm = try b.module.internConst(b.allocator, .{ .String = name0 });
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
    if (isPrimitiveConv(name0)) {
        if (b.resolve("this")) |this_reg| {
            const run = try lowerArgRun(b, args);
            const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
            const dst = b.allocReg();
            const nm = try b.module.internConst(b.allocator, .{ .String = name0 });
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
    }
    const this_idx = try b.recordCapture("this");
    const run = try lowerArgRun(b, args);
    const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
    const dst = b.allocReg();
    const nm = try b.module.internConst(b.allocator, .{ .String = name0 });
    try b.push(.{ .CallMemberOrGlobal = .{
        .dst = dst,
        .this_idx = this_idx,
        .name = nm,
        .args = run[0],
        .n_args = run[1],
        .arg_names = arg_names,
    } });
    return dst;
}

fn isPrimitiveConv(name: []const u8) bool {
    const names = [_][]const u8{
        "toInt",  "toLong",    "toByte", "toShort", "toDouble", "toFloat",
        "toChar", "toBoolean", "toUInt", "toULong", "toUByte",  "toUShort",
    };
    for (names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
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
        (head_is_real_pkg or !b.isLambdaBody()) and
        b.resolve(head) == null and
        !b.knowsOuter(head) and
        b.module.classId(head) == null and
        (head_is_real_pkg or !isTopLevelProp(head)) and
        (head_is_real_pkg or b.resolve("this") == null))
    {
        const want = args.len;
        const cands = b.module.funcsBySimpleName(tail);
        var pick: ?FuncId = null;
        for (cands) |fid| {
            const f = idGet(Func, b.module.funcs.items, fid.int()) orelse continue;
            if (std.mem.eql(u8, f.fqn, fqn) and f.params.len == want) {
                pick = fid;
                break;
            }
        }
        if (pick == null) {
            for (cands) |fid| {
                const f = idGet(Func, b.module.funcs.items, fid.int()) orelse continue;
                const first_is_this = f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this");
                if (!first_is_this and f.params.len == want) {
                    pick = fid;
                    break;
                }
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
    if (isPackageHead(head) and
        (head_is_real_pkg or !b.isLambdaBody()) and
        b.resolve(head) == null and
        !b.knowsOuter(head) and
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
    const anon_cap = isLowerAnonCapture(name.name) and b.resolve(name.name) == null and
        !b.isLocalFn(name.name) and !b.isParam(name.name) and !b.knowsOuter(name.name);
    const local_callable = b.isLocalFn(name.name) or b.isParam(name.name) or
        b.knowsOuter(name.name) or anon_cap;
    if (local_callable) {
        const local_reg = blk: {
            if (anon_cap) {
                const idx = try b.recordCapture(name.name);
                const r = b.allocReg();
                try b.push(.{ .LoadCapture = .{ .dst = r, .idx = idx } });
                break :blk r;
            }
            break :blk try resolveCapture(b, name.name);
        };
        const recv = try lowerReceiver(b, receiver);
        const run = try lowerArgRun(b, args);
        const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
        const nm = try b.module.internConst(b.allocator, .{ .String = name.name });
        const dst = b.allocReg();
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
    // first-param type is `T`.
    if (receiver.* == .As and !receiver.As.safe) {
        const cast_ty = receiver.As.ty;
        const want_user = args.len;
        var chosen: ?FuncId = null;
        for (b.module.funcsBySimpleName(name.name)) |fid| {
            const f = idGet(Func, b.module.funcs.items, fid.int()) orelse continue;
            if (f.blocks.len == 0) continue;
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
            if (arity_ok) {
                chosen = fid;
                break;
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
            try b.push(.{ .Call = .{
                .dst = dst,
                .func = func_id,
                .args = start,
                .n_args = @intCast(arg_regs.len),
                .arg_names = arg_names,
                .type_args = type_args,
                .exact = false,
            } });
            return dst;
        }
    }

    const recv = try lowerReceiver(b, receiver);
    const run = try lowerArgRun(b, args);
    const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
    const dst = b.allocReg();
    const nm = try b.module.internConst(b.allocator, .{ .String = name.name });
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

/// Join string slices with `.`. The caller owns the returned slice.
fn joinStrs(allocator: Allocator, strs: []const []const u8) Allocator.Error![]u8 {
    var total: usize = 0;
    for (strs, 0..) |s, i| {
        total += s.len;
        if (i != 0) total += 1;
    }
    var out = try allocator.alloc(u8, total);
    var off: usize = 0;
    for (strs, 0..) |s, i| {
        if (i != 0) {
            out[off] = '.';
            off += 1;
        }
        @memcpy(out[off .. off + s.len], s);
        off += s.len;
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

test "path falls back to load global when unbound" {
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
