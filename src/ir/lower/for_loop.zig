//! `for (x in xs) body` loop lowering. Free functions over the shared
//! `FuncBuilder`; filled in alongside the expression dispatch.

const std = @import("std");
const ast = @import("ast");
const ir = @import("../ir.zig");
const build = @import("../build.zig");
const expr = @import("expr.zig");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const Reg = ir.Reg;
const Inst = ir.Inst;
const Const = ir.Const;
const Terminator = ir.Terminator;

const lowerExpr = expr.lowerExpr;

pub fn lowerFor(
    b: *FuncBuilder,
    vars: []const ast.Ident,
    by_name: bool,
    sources: []const ast.Ident,
    iter: *const Expr,
    body: *const Expr,
) Allocator.Error!Reg {
    return lowerForLabeled(b, vars, by_name, sources, iter, body, null);
}


fn countedEnabled() bool {
    return true;
}

pub fn lowerForLabeled(
    b: *FuncBuilder,
    vars: []const ast.Ident,
    by_name: bool,
    sources: []const ast.Ident,
    iter: *const Expr,
    body: *const Expr,
    label: ?[]const u8,
) Allocator.Error!Reg {
    // COUNTED-RANGE strength reduction: `for (i in a until b)` and
    // `for (i in a..b)` over same-typed Int/Long operands lower to a plain
    // register loop — no Range object, no iterator, no virtual protocol
    // calls per iteration. The iterator form dominated the interpreter's
    // loop profile (two CallVirtuals per iteration plus the range fields).
    // `KLIO_COUNTED=0` restores the iterator lowering for bisection.
    if (vars.len == 1 and !by_name and countedEnabled()) counted: {
        var lo_e: ?*const Expr = null;
        var hi_e: ?*const Expr = null;
        var inclusive = false;
        // `a downTo b`: start at `a`, step -1, inclusive `b` — the same
        // equality-exit loop with the compare and step reversed.
        var descending = false;
        // `… step k` with a positive INT-LITERAL k: the same equality-exit
        // register loop with the exit bound snapped to the progression's
        // real last element (`lo ± ((span / k) * k)`). A non-literal step
        // keeps the iterator lowering (the step-positive throw and the
        // dynamic last belong to the progression object).
        var step_lit: i64 = 1;
        var iter_shape = iter;
        if (iter.* == .Call) {
            const c = &iter.Call;
            if (c.is_infix and c.args.len == 2 and c.callee.* == .Path and
                c.callee.Path.segments.len == 1 and
                std.mem.eql(u8, c.callee.Path.segments[0].name, "step") and
                c.args[1] == .IntLit and c.args[1].IntLit.value > 0)
            {
                const inner = &c.args[0];
                const inner_counted = switch (inner.*) {
                    .Binary => |bin| bin.op == .Range,
                    .Call => |ic| ic.is_infix and ic.args.len == 2 and
                        ic.callee.* == .Path and ic.callee.Path.segments.len == 1 and
                        std.mem.eql(u8, ic.callee.Path.segments[0].name, "downTo"),
                    else => false,
                };
                // The floorMod shift below adds k to a |x| < k value; cap
                // the literal so that sum cannot wrap even in Int domain.
                if (inner_counted and c.args[1].IntLit.value <= (1 << 30)) {
                    step_lit = c.args[1].IntLit.value;
                    iter_shape = inner;
                }
            }
        }
        switch (iter_shape.*) {
            .Binary => |bin| switch (bin.op) {
                .Range => {
                    inclusive = true;
                    lo_e = bin.lhs;
                    hi_e = bin.rhs;
                },
                .RangeUntil => {
                    lo_e = bin.lhs;
                    hi_e = bin.rhs;
                },
                else => break :counted,
            },
            .Call => |c| blk: {
                if (c.is_infix and c.args.len == 2 and c.callee.* == .Path and
                    c.callee.Path.segments.len == 1)
                {
                    const nm = c.callee.Path.segments[0].name;
                    if (std.mem.eql(u8, nm, "until")) {
                        lo_e = &c.args[0];
                        hi_e = &c.args[1];
                        break :blk;
                    }
                    if (std.mem.eql(u8, nm, "downTo")) {
                        descending = true;
                        inclusive = true;
                        lo_e = &c.args[0];
                        hi_e = &c.args[1];
                        break :blk;
                    }
                }
                // A call whose STATIC type is a range still counts (below).
            },
            else => {},
        }
        if (step_lit != 1 and lo_e == null) break :counted;
        var is_int = false;
        var is_long = false;
        // Char ranges run the same register loop: Char comparisons order by
        // code and `Char +/- Int` yields Char, so the induction register
        // holds real Char values. The step-snap arithmetic is Int-only, so
        // a stepped char progression keeps the iterator lowering.
        var is_char = false;
        if (lo_e != null) {
            var lo_ty = (expr.staticExprTypeRef(b, lo_e.?) catch null) orelse break :counted;
            defer lo_ty.deinit(b.allocator);
            var hi_ty = (expr.staticExprTypeRef(b, hi_e.?) catch null) orelse break :counted;
            defer hi_ty.deinit(b.allocator);
            is_int = std.mem.eql(u8, lo_ty.name, "Int") and std.mem.eql(u8, hi_ty.name, "Int");
            is_long = std.mem.eql(u8, lo_ty.name, "Long") and std.mem.eql(u8, hi_ty.name, "Long");
            is_char = std.mem.eql(u8, lo_ty.name, "Char") and std.mem.eql(u8, hi_ty.name, "Char");
            if ((!is_int and !is_long and !is_char) or lo_ty.nullable or hi_ty.nullable) break :counted;
            if (is_char and step_lit != 1) break :counted;
        } else {
            // TYPE-DRIVEN prong: any iterable whose static type is a
            // non-nullable IntRange/LongRange (a hoisted `val`, a
            // range-returning call, `list.indices`) iterates
            // `[first, last]` step 1 by construction — read the two
            // bounds once and run the same register loop. Progressions
            // (`downTo`, `step`, `reversed`) type as IntProgression and
            // keep the iterator lowering.
            var ity = (expr.staticExprTypeRef(b, iter) catch null) orelse break :counted;
            defer ity.deinit(b.allocator);
            if (ity.nullable) break :counted;
            var head = ity.name;
            if (std.mem.lastIndexOfScalar(u8, head, '.')) |d| head = head[d + 1 ..];
            is_int = std.mem.eql(u8, head, "IntRange");
            is_long = std.mem.eql(u8, head, "LongRange");
            is_char = std.mem.eql(u8, head, "CharRange");
            if (!is_int and !is_long and !is_char) break :counted;
            inclusive = true;
        }

        // Bounds evaluate once, in source order, before the loop.
        var lo: Reg = undefined;
        var hi: Reg = undefined;
        if (lo_e) |le| {
            lo = try lowerExpr(b, le);
            const hi_raw = try lowerExpr(b, hi_e.?);
            hi = b.allocReg();
            try b.push(.{ .Move = .{ .dst = hi, .src = hi_raw } });
        } else {
            const rng = try lowerExpr(b, iter);
            const first_name = try b.module.internConst(b.allocator, .{ .String = "first" });
            const last_name = try b.module.internConst(b.allocator, .{ .String = "last" });
            lo = b.allocReg();
            try b.push(.{ .GetField = .{ .dst = lo, .receiver = rng, .field = first_name } });
            hi = b.allocReg();
            try b.push(.{ .GetField = .{ .dst = hi, .receiver = rng, .field = last_name } });
        }
        const i_reg = b.allocReg();
        try b.push(.{ .Move = .{ .dst = i_reg, .src = lo } });
        const one = if (is_long)
            try b.emitConst(.{ .Long = step_lit })
        else
            try b.emitConst(.{ .Int = @intCast(step_lit) });
        // With a step above 1, the equality exit must hit the
        // progression's real LAST element. kotlinc's overflow-free form
        // (getProgressionLastElement): the bounds only enter modulo-k
        // arithmetic, never a wide subtraction —
        //   asc:  last = hi - floorMod(hi % k - lo % k, k)
        //   desc: last = hi + floorMod(lo % k - hi % k, k)
        // floorMod(x, k) for |x| < k is ((x + k) % k); the step-literal
        // cap above keeps x + k in range. The header's emptiness check
        // keeps the ORIGINAL bound (the snapped last is meaningless when
        // the range is empty).
        var eq_bound = hi;
        if (step_lit != 1) {
            const hi_mod = b.allocReg();
            try b.push(.{ .BinOp = .{ .dst = hi_mod, .op = .Mod, .lhs = hi, .rhs = one } });
            const lo_mod = b.allocReg();
            try b.push(.{ .BinOp = .{ .dst = lo_mod, .op = .Mod, .lhs = i_reg, .rhs = one } });
            const diff = b.allocReg();
            try b.push(.{ .BinOp = .{
                .dst = diff,
                .op = .Sub,
                .lhs = if (descending) lo_mod else hi_mod,
                .rhs = if (descending) hi_mod else lo_mod,
            } });
            const shifted = b.allocReg();
            try b.push(.{ .BinOp = .{ .dst = shifted, .op = .Add, .lhs = diff, .rhs = one } });
            const fmod = b.allocReg();
            try b.push(.{ .BinOp = .{ .dst = fmod, .op = .Mod, .lhs = shifted, .rhs = one } });
            eq_bound = b.allocReg();
            try b.push(.{ .BinOp = .{
                .dst = eq_bound,
                .op = if (descending) .Add else .Sub,
                .lhs = hi,
                .rhs = fmod,
            } });
        }

        const header = try b.allocBlock();
        const body_blk = try b.allocBlock();
        const tail_blk = try b.allocBlock();
        const incr = try b.allocBlock();
        const exit = try b.allocBlock();
        b.terminate(.{ .Goto = header });

        // ENTRY check once. The INCLUSIVE form must terminate at
        // `hi == MAX_VALUE`, where increment-then-compare would wrap and
        // spin — so its per-iteration exit is an EQUALITY check before the
        // increment (`i == hi` → done, else `i < hi` so `i + 1` cannot
        // overflow). The exclusive form's `i < hi` compare is
        // overflow-free as is.
        b.switchTo(header);
        const cond = b.allocReg();
        try b.push(.{ .BinOp = .{
            .dst = cond,
            .op = if (descending) .GreaterEq else if (inclusive) .LessEq else .Less,
            .lhs = i_reg,
            .rhs = hi,
        } });
        b.terminate(.{ .Branch = .{ .cond = cond, .t = body_blk, .f = exit } });

        b.switchTo(body_blk);
        try b.pushScope();
        try b.bind(vars[0].name, i_reg);
        try b.setLocalDeclTypeOwned(vars[0].name, .{
            .name = try b.allocator.dupe(u8, if (is_long) "Long" else if (is_char) "Char" else "Int"),
            .nullable = false,
            .args = &.{},
        });
        // `continue` re-enters at the per-iteration EXIT CHECK, never the
        // body or the increment.
        try b.pushLoop(label, tail_blk, exit);
        _ = try lowerExpr(b, body);
        b.popLoop();
        try b.popScope();
        b.terminate(.{ .Goto = tail_blk });

        b.switchTo(tail_blk);
        if (inclusive) {
            const done = b.allocReg();
            try b.push(.{ .BinOp = .{ .dst = done, .op = .Eq, .lhs = i_reg, .rhs = eq_bound } });
            b.terminate(.{ .Branch = .{ .cond = done, .t = exit, .f = incr } });
        } else {
            b.terminate(.{ .Goto = incr });
        }

        b.switchTo(incr);
        try b.push(.{ .BinOp = .{
            .dst = i_reg,
            .op = if (descending) .Sub else .Add,
            .lhs = i_reg,
            .rhs = one,
        } });
        b.terminate(.{ .Goto = if (inclusive) body_blk else header });

        b.switchTo(exit);
        return b.emitConst(.Unit);
    }
    const recv = try lowerExpr(b, iter);
    const it_reg = b.allocReg();
    const zero = b.allocReg();
    try b.push(.{ .Move = .{ .dst = zero, .src = recv } });
    // Static protocol binding: when the iterable's `iterator()` return
    // resolves to the `Iterator` INTERFACE itself, `hasNext`/`next` emit
    // slot-bound against its roots — the runtime serves those by FuncId
    // (`iterator_protocol` for host iterators, the override slot for
    // interpreted implementors). A convention-based custom iterator (any
    // `operator hasNext/next` without the interface) keeps the by-name
    // form, exactly as before.
    var hn_root: ?ir.FuncId = null;
    var next_root: ?ir.FuncId = null;
    var iter_ext_fid: ?ir.FuncId = null;
    var iter_root: ?ir.FuncId = null;
    if (try expr.staticExprTypeRef(b, iter)) |ity0| {
        var ity = ity0;
        defer ity.deinit(b.allocator);
        const file = vars[0].span.file;
        // The receiver's own MEMBER `iterator()` binds through its virtual
        // slot (an IntRange for-loop no longer walks the name each entry).
        {
            var rhead = std.mem.trimEnd(u8, ity.name, "?");
            if (std.mem.indexOfScalar(u8, rhead, '<')) |lt| rhead = rhead[0..lt];
            const rcid = (if (std.mem.indexOfScalar(u8, rhead, '.') != null)
                b.module.classIdByFqn(rhead)
            else
                b.module.uniqueClassIdBySimpleName(rhead));
            if (rcid) |cid| {
                if (cid.int() < b.module.classes.items.len) {
                    const rfqn = b.module.classes.items[cid.int()].fqn;
                    const it_decls = b.module.memberDecls(rfqn, "iterator");
                    if (it_decls.len != 0) {
                        iter_root = it_decls[0];
                    } else {
                        // Inherited member (IntRange's iterator lives on
                        // IntProgression): the resolver chases supers.
                        const resolved = b.module.resolveMemberCall(cid, "iterator", &.{}, .{
                            .caller_file = file,
                            .lexical_owner = null,
                            .actual_type_param_bounds = &.{},
                            .receiver_type = ity,
                        });
                        iter_root = resolved.target;
                    }
                }
            }
        }
        // A member `iterator()` first; a receiver served only by the
        // UNIQUE top-level extension (`CharSequence.iterator():
        // CharIterator`) binds through its declared return the same way,
        // and the `iterator()` invocation itself binds to that extension.
        if ((try expr.nullaryMemberReturnTypeRef(b, ity, "iterator", file)) orelse
            (try expr.extensionNullaryReturnTypeRef(b, ity, "iterator", &iter_ext_fid))) |irt0|
        {
            var irt = irt0;
            defer irt.deinit(b.allocator);
            var head = std.mem.trimEnd(u8, irt.name, "?");
            if (std.mem.indexOfScalar(u8, head, '<')) |lt| head = head[0..lt];
            if (std.mem.lastIndexOfScalar(u8, head, '.')) |d| head = head[d + 1 ..];
            // The interface itself, or a primitive-iterator abstract class
            // (`ByteIterator`): `hasNext` roots on the interface; `next`
            // prefers the head class's own override (whose source body
            // delegates to the `nextByte()`-family the protocol handler
            // serves) and falls back to the interface root.
            const iterator_family = std.mem.eql(u8, head, "Iterator") or
                (std.mem.endsWith(u8, head, "Iterator") and blk_fam: {
                    // The kotlin.collections primitive-iterator family ONLY:
                    // a pack class that happens to end in `Iterator`
                    // (compose's path iterators) has its own dispatch story.
                    const cid = b.module.uniqueClassIdBySimpleName(head) orelse break :blk_fam false;
                    if (cid.int() >= b.module.classes.items.len) break :blk_fam false;
                    break :blk_fam std.mem.startsWith(u8, b.module.classes.items[cid.int()].fqn, "kotlin.collections.");
                });
            if (iterator_family) {
                if (b.module.uniqueClassIdBySimpleName("Iterator")) |icid| {
                    if (icid.int() < b.module.classes.items.len) {
                        const ifqn = b.module.classes.items[icid.int()].fqn;
                        const hn_decls = b.module.memberDecls(ifqn, "hasNext");
                        const nx_decls = b.module.memberDecls(ifqn, "next");
                        if (hn_decls.len != 0) hn_root = hn_decls[0];
                        if (nx_decls.len != 0) next_root = nx_decls[0];
                    }
                }
                if (!std.mem.eql(u8, head, "Iterator")) {
                    if (b.module.uniqueClassIdBySimpleName(head)) |hcid| {
                        if (hcid.int() < b.module.classes.items.len) {
                            const hfqn = b.module.classes.items[hcid.int()].fqn;
                            const own_next = b.module.memberDecls(hfqn, "next");
                            if (own_next.len != 0) next_root = own_next[0];
                            const own_hn = b.module.memberDecls(hfqn, "hasNext");
                            if (own_hn.len != 0) hn_root = own_hn[0];
                        }
                    }
                }
            }
        }
    }
    if (iter_root) |root| {
        const vargs = b.allocReg();
        try b.push(.{ .CallVirtual = .{
            .dst = it_reg,
            .receiver = zero,
            .slot = ir.MethodSlotId.fromFunc(root),
            .args = vargs,
            .n_args = 0,
        } });
    } else if (iter_ext_fid) |ext_fid| {
        try b.push(.{ .Call = .{
            .dst = it_reg,
            .func = ext_fid,
            .trailing_lambda = false,
            .args = zero,
            .n_args = 1,
            .arg_names = &.{},
            .type_args = &.{},
            .exact = true,
        } });
    } else {
        const name = try b.module.internConst(b.allocator, .{ .String = "iterator" });
        const args_start = b.allocReg();
        try b.push(.{ .CallMember = .{
            .dst = it_reg,
            .receiver = zero,
            .name = name,
            .args = args_start,
            .n_args = 0,
            .arg_names = &.{},
        } });
    }
    const header = try b.allocBlock();
    const body_blk = try b.allocBlock();
    const exit = try b.allocBlock();
    b.terminate(.{ .Goto = header });

    b.switchTo(header);
    const has_next = b.allocReg();
    const hn_name = try b.module.internConst(b.allocator, .{ .String = "hasNext" });
    const hn_args = b.allocReg();
    if (hn_root) |root| {
        try b.push(.{ .CallVirtual = .{
            .dst = has_next,
            .receiver = it_reg,
            .slot = ir.MethodSlotId.fromFunc(root),
            .args = hn_args,
            .n_args = 0,
        } });
    } else try b.push(.{ .CallMember = .{
        .dst = has_next,
        .receiver = it_reg,
        .name = hn_name,
        .args = hn_args,
        .n_args = 0,
        .arg_names = &.{},
    } });
    b.terminate(.{ .Branch = .{
        .cond = has_next,
        .t = body_blk,
        .f = exit,
    } });

    b.switchTo(body_blk);
    try b.pushScope();
    const next_reg = b.allocReg();
    const next_name = try b.module.internConst(b.allocator, .{ .String = "next" });
    const nargs = b.allocReg();
    if (next_root) |root| {
        try b.push(.{ .CallVirtual = .{
            .dst = next_reg,
            .receiver = it_reg,
            .slot = ir.MethodSlotId.fromFunc(root),
            .args = nargs,
            .n_args = 0,
        } });
    } else try b.push(.{ .CallMember = .{
        .dst = next_reg,
        .receiver = it_reg,
        .name = next_name,
        .args = nargs,
        .n_args = 0,
        .arg_names = &.{},
    } });
    if (vars.len == 1 and !by_name) {
        try b.bind(vars[0].name, next_reg);
        if (try expr.iterableElementTypeName(b, iter)) |elem| {
            try b.setLocalDeclTypeOwned(vars[0].name, .{
                .name = elem,
                .nullable = false,
                .args = &.{},
            });
        } else if (std.c.getenv("KLIO_FORVAR_TRACE") != null) {
            std.debug.print("[forvar] {s} elem=null iter_tag={s} fn={s} splice={s}\n", .{ vars[0].name, @tagName(std.meta.activeTag(iter.*)), build.currentRealFn() orelse "-", b.spliceRecvTy() orelse "-" });
        }
    } else if (by_name) {
        // `for ((val k, val v) in xs)`: each name reads its property off the
        // element.
        for (vars, 0..) |v, i| {
            const dst = b.allocReg();
            const field = try b.module.internConst(b.allocator, .{ .String = sources[i].name });
            try b.push(.{ .GetField = .{ .dst = dst, .receiver = next_reg, .field = field } });
            if (std.mem.eql(u8, v.name, "_")) continue;
            try b.bind(v.name, dst);
        }
    } else {
        // Each destructured name is bound to the element's `componentN()`, so
        // its type is that accessor's declared return type on the element.
        var elem_ty = try expr.iterableElementTypeRef(b, iter);
        defer if (elem_ty) |*t| t.deinit(b.allocator);
        for (vars, 0..) |v, i| {
            const comp = b.allocReg();
            const comp_name = try std.fmt.allocPrint(b.allocator, "component{d}", .{i + 1});
            const nm = try b.module.internConst(b.allocator, .{ .String = comp_name });
            const cargs = b.allocReg();
            try b.push(.{ .CallMember = .{
                .dst = comp,
                .receiver = next_reg,
                .name = nm,
                .args = cargs,
                .n_args = 0,
                .arg_names = &.{},
            } });
            try b.bind(v.name, comp);
            if (elem_ty) |ety| {
                if (try expr.nullaryMemberReturnTypeRef(b, ety, comp_name, iter.span().file)) |ct| {
                    try b.setLocalDeclTypeOwned(v.name, ct);
                }
            }
        }
    }
    try b.pushLoop(label, header, exit);
    _ = try lowerExpr(b, body);
    b.popLoop();
    try b.popScope();
    b.terminate(.{ .Goto = header });

    b.switchTo(exit);
    return b.emitConst(.Unit);
}

test {
    std.testing.refAllDecls(@This());
}
