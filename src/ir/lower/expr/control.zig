//! Return, try, labeled and postfix expression lowering, with the try-frame
//! and finally replay helpers a jump needs.

const std = @import("std");
const ast = @import("ast");
const runtime = @import("runtime");
const ir = @import("../../ir.zig");
const build = @import("../../build.zig");
const decl_mod = @import("../decl.zig");
const for_loop = @import("../for_loop.zig");
const stmt_mod = @import("../stmt.zig");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const Reg = ir.Reg;
const UnOp = ir.UnOp;
const BlockId = ir.BlockId;
const CatchHandler = ir.CatchHandler;
const lowerForLabeled = for_loop.lowerForLabeled;
const lowerStmt = stmt_mod.lowerStmt;

const expr_mod = @import("../expr.zig");
const lowerExpr = expr_mod.lowerExpr;

const receiver_mod = @import("receiver.zig");
const lowerReceiver = receiver_mod.lowerReceiver;

const binary_mod = @import("binary.zig");
const writeBackLvalue = binary_mod.writeBackLvalue;

const paths_mod = @import("paths.zig");
const loweredTypeName = paths_mod.loweredTypeName;

const arg_shape_mod = @import("arg_shape.zig");
const narrowNullCheckAll = arg_shape_mod.narrowNullCheckAll;

const probe_mod = @import("probe.zig");
const userFunctionDeclared = probe_mod.userFunctionDeclared;

const block_mod = @import("block.zig");
const hoistMutualLocalFns = block_mod.hoistMutualLocalFns;
const lowerBlock = block_mod.lowerBlock;

/// Replay the `finally { … }` bodies pushed above `base` inline, innermost
/// first, ahead of a jump that leaves their try regions (an inline `return`
/// to its join, a `break`/`continue` crossing a `try`). While one finally
/// replays, only the finallys strictly outside it stay active, so a jump
/// within the finally body still unwinds correctly. The bypassed try
/// regions' runtime `TryFrame`s are popped when the current block exits —
/// the jump bypasses the finally sentinel that would pop them.
/// A `break`/`continue` leaves every try entered inside the loop: their
/// runtime frames are popped when the current block exits, and the finally
/// bodies replayed for the jump then run OUTSIDE them, so an exception one
/// of them throws is neither caught by a catch the jump already left nor
/// routed back into the finally itself.
pub fn leaveTryFramesForJump(b: *FuncBuilder, finally_base: usize, catch_base: usize) Allocator.Error!void {
    const fin = try b.finallyBodiesFrom(finally_base);
    defer b.allocator.free(fin);
    const cat = try b.catchBodiesFrom(catch_base);
    defer b.allocator.free(cat);
    if (fin.len == 0 and cat.len == 0) return;
    try b.appendPopOnExit(b.cur, fin);
    try b.appendPopOnExit(b.cur, cat);
    const next = try b.allocBlock();
    b.terminate(.{ .Goto = next });
    b.switchTo(next);
}

/// Among same-named LOCAL function overloads (`f`, `f$ovl0`, …) the
/// declaration whose parameter count matches the call; the plain name when
/// it fits or when nothing does.
pub fn localOverloadPick(b: *FuncBuilder, name: []const u8, argc: usize) []const u8 {
    if (!b.isLocalFn(name)) return name;
    var buf: [4][96]u8 = undefined;
    var any_sibling = false;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const m = std.fmt.bufPrint(&buf[i], "{s}$ovl{d}", .{ name, i }) catch break;
        if (b.isLocalFn(m)) any_sibling = true;
    }
    if (!any_sibling) return name;
    if (localFnArity(b, name) == argc) return name;
    i = 0;
    while (i < 4) : (i += 1) {
        const m = std.fmt.bufPrint(&buf[i], "{s}$ovl{d}", .{ name, i }) catch break;
        if (!b.isLocalFn(m)) continue;
        if (localFnArity(b, m) == argc) return b.module.func_name_index.allocator.dupe(u8, m) catch name;
    }
    return name;
}

fn localFnArity(b: *const FuncBuilder, name: []const u8) usize {
    if (b.localFnParamTys(name)) |tys| return tys.len;
    if (b.localExtFnArity(name)) |n| return @intCast(n);
    return 0;
}

pub fn replayFinallysForJump(b: *FuncBuilder, base_raw: usize) Allocator.Error!void {
    const base = @min(base_raw, b.finally_stack.items.len);
    const pop_bodies = try b.finallyBodiesFrom(base);
    if (b.finally_stack.items.len > base) {
        // Each finally body re-lowers under the splice-resolve context that
        // was active when its `try` was lowered, not the jump site's: a
        // spliced body's finally replayed inside a spliced lambda otherwise
        // resolves the body's own params against the lambda's caller region.
        const windows = try b.finallyWindowsSnapshot();
        defer b.allocator.free(windows);
        const prior = try b.swapFinallyStack(&.{});
        defer b.allocator.free(prior);
        var idx: usize = prior.len;
        while (idx > base) {
            idx -= 1;
            const blk = &prior[idx];
            const outer = try b.allocator.dupe(ast.Block, prior[0..idx]);
            const dropped = try b.swapFinallyStack(outer);
            b.allocator.free(dropped);
            const saved_window = b.lambda_splice_resolve;
            // The band list is restored by VALUE: a nested splice inside the
            // replayed body appends at the truncated length and would
            // otherwise overwrite the outer bands a bare length restore
            // re-exposes.
            const saved_bands = try b.allocator.dupe(
                @TypeOf(b.splice_hidden_bands.items[0]),
                b.splice_hidden_bands.items,
            );
            defer b.allocator.free(saved_bands);
            if (idx < windows.len) {
                b.lambda_splice_resolve = windows[idx].window;
                b.splice_hidden_bands.items.len = @min(b.splice_hidden_bands.items.len, windows[idx].bands_len);
            }
            _ = try lowerBlock(b, blk);
            b.lambda_splice_resolve = saved_window;
            b.splice_hidden_bands.clearRetainingCapacity();
            try b.splice_hidden_bands.appendSlice(b.allocator, saved_bands);
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

pub fn lowerReturn(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    const ret = expr.Return;
    const label = ret.label;
    var r: ?Reg = null;
    if (ret.value) |e| {
        // `return …` puts the declared return type in tail position; only a
        // bare `return` targets the enclosing fn.
        var prev: ?(?ast.TypeRef) = null;
        if (label == null) prev = b.pushExpected(b.declaredReturn());
        if (label == null) b.tail_pos = true;
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
            // Also pop the CATCH-ONLY try frames opened inside this inline body:
            // the jump to the join bypasses their `catch_done` exit, so without
            // this the catch stays armed over the code after the inlined call
            // (`parseString("double") { toDouble() }` then rejecting NaN).
            const catch_pops = try b.catchBodiesFrom(ar.catch_base);
            defer b.allocator.free(catch_pops);
            try b.appendPopOnExit(b.cur, catch_pops);
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
        // `return@<inlineFnName>` targeting an inline body currently being
        // SPLICED — reached from inside a lambda spliced by a nested inline
        // call (`accept { … }.otherwise { return@tryParseTime }`). The
        // target has no runtime frame, so the return resolves here to the
        // splice frame's join, replaying its own finallys first.
        if (if (runtime.envOnce("KLIO_NO_LR_STATIC") == null) b.inlineReturnFor(lbl.name) else null) |ar| {
            if (r) |rr| try b.push(.{ .Move = .{ .dst = ar.reg, .src = rr } });
            try replayFinallysForJump(b, ar.finally_base);
            b.terminate(.{ .Goto = ar.join });
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

pub fn lowerTry(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
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
    // A catch-only try (no finally) needs its body tracked so an inline
    // `return` inside it pops the runtime catch frame on the way to its join.
    const catch_only = finally_entry == null and t.catches.len != 0;
    if (catch_only) try b.pushCatchBody(cur_id);
    const body_val = try lowerBlock(b, &t.body);
    if (catch_only) b.popCatchBody();
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
        // A catch parameter's type is always written in the source, so it is
        // static evidence for every member call on it in the handler. Binding
        // the register without recording the type left those calls with no
        // receiver type — the largest single reason static member dispatch
        // declines is locals lowering has in scope but has no type for.
        try b.setLocalDeclTypeOwned(
            h.c.binding.name,
            try decl_mod.loweredTypeRef(b.allocator, &h.c.ty, true),
        );
        if (h.c.ty.nullable) try b.setLocalDeclNullable(h.c.binding.name);
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

/// `x++`/`--x` on a local declared NULLABLE (`var i: Int? = …`): the
/// builtin `inc`/`dec` members do not take a nullable receiver, so the
/// program's `T?.inc()`/`T?.dec()` extension is the target — lowered as the
/// call it is. Null when the operand is not such a local or no extension is
/// declared.
pub fn nullableIncDecCall(b: *FuncBuilder, operand: *const Expr, inc: bool) Allocator.Error!?Reg {
    if (operand.* != .Path or operand.Path.segments.len != 1) return null;
    const name = operand.Path.segments[0].name;
    if (!b.localDeclNullable(name)) return null;
    const op_name: []const u8 = if (inc) "inc" else "dec";
    if (!userFunctionDeclared(b, op_name) and !b.isLocalExtFn(op_name)) return null;
    const sp = operand.Path.span;
    const ma = b.module.func_name_index.allocator;
    const callee = try ma.create(ast.Expr);
    callee.* = .{ .Member = .{ .receiver = @constCast(operand), .name = .{ .name = op_name, .span = sp }, .safe = false, .span = sp } };
    const call = ast.Expr{ .Call = .{ .callee = callee, .args = &.{}, .arg_names = &.{}, .type_args = &.{}, .is_infix = false, .span = sp } };
    return try lowerExpr(b, &call);
}

/// A `recv.member` target whose receiver is an expression with possible
/// side effects (a call, an index, a nested member), so it must be
/// evaluated exactly once for a read-modify-write.
pub fn sideEffectingMemberTarget(e: *const Expr) bool {
    if (e.* != .Member or e.Member.safe) return false;
    const r = e.Member.receiver;
    return r.* != .Path and r.* != .This and r.* != .Super;
}

pub fn lowerPostfix(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
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
            if (stmt_mod.indexNeedsCaching(inner)) {
                try b.pushScope();
                defer b.popScope() catch {};
                const cached = try stmt_mod.cacheIndexTarget(b, &inner.Index);
                const old = try lowerExpr(b, &cached);
                const new = b.allocReg();
                try b.push(.{ .UnOp = .{ .dst = new, .op = uo, .operand = old } });
                try writeBackLvalue(b, &cached, new);
                return old;
            }
            if (sideEffectingMemberTarget(inner)) {
                // `getA().x++` evaluates `getA()` once.
                const m = &inner.Member;
                const recv = try lowerReceiver(b, m.receiver);
                const field = try b.module.internConst(b.allocator, .{ .String = m.name.name });
                const old = b.allocReg();
                try b.push(.{ .GetField = .{ .dst = old, .receiver = recv, .field = field } });
                const new = b.allocReg();
                try b.push(.{ .UnOp = .{ .dst = new, .op = uo, .operand = old } });
                try stmt_mod.storeMemberThroughReg(b, m, recv, new);
                return old;
            }
            if (inner.* == .Path and inner.Path.segments.len == 1 and
                b.localDeclNullable(inner.Path.segments[0].name) and
                (userFunctionDeclared(b, if (pf.op == .Inc) "inc" else "dec") or b.isLocalExtFn(if (pf.op == .Inc) "inc" else "dec")))
            {
                // Snapshot the OLD value into a fresh register: `inner` is
                // a mutable var whose register the write-back below
                // reassigns, so returning the live load would yield the NEW
                // value (post-increment must return the old one).
                const old_src = try lowerExpr(b, inner);
                const old = b.allocReg();
                try b.push(.{ .Move = .{ .dst = old, .src = old_src } });
                const call = (try nullableIncDecCall(b, inner, pf.op == .Inc)).?;
                try writeBackLvalue(b, inner, call);
                return old;
            }
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

pub fn lowerLabeled(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
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
            var lw_not_null: std.ArrayList(build.FuncBuilder.NarrowedLocal) = .empty;
            defer lw_not_null.deinit(b.allocator);
            try narrowNullCheckAll(b, w.cond, true, &lw_not_null);
            _ = try lowerExpr(b, w.body);
            var lwn = lw_not_null.items.len;
            while (lwn > 0) : (lwn -= 1) b.restoreLocal(lw_not_null.items[lwn - 1]);
            b.popLoop();
            b.terminate(.{ .Goto = header });
            b.switchTo(exit);
            return b.emitConst(.Unit);
        },
        .For => |f| return lowerForLabeled(b, f.vars, f.by_name, f.destructured, f.var_sources, f.iter, f.body, label.name),
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

/// Unwind the spliced-subject tower down to `base` before a jump that
/// leaves the regions (`break`/`continue` past a spliced `sync {}`):
/// every skipped region's `EnclosingPop` is emitted here, or the CAS
/// retry loop leaks one chain entry per iteration.
pub fn emitTowerPopsForJump(b: *FuncBuilder, base: u32) Allocator.Error!void {
    var d = b.encl_tower_depth;
    while (d > base) : (d -= 1) {
        try b.push(.{ .EnclosingPop = .{} });
    }
}
