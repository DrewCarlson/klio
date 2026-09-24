//! Instruction handlers: the outlined `execInst` arms, the binary-operator
//! semantics, the field routes, and member-call dispatch.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");
const span = @import("span");

const Allocator = std.mem.Allocator;

const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const InstanceData = runtime.InstanceData;

const BinOp = ir.BinOp;
const Const = ir.Const;
const FuncId = ir.FuncId;
const Inst = ir.Inst;
const Module = ir.Module;
const UnOp = ir.UnOp;

const exec_call = @import("../exec_call.zig");

const callerThisValue = exec_call.callerThisValue;
const constStr = exec_call.constStr;
const envVarSet = exec_call.envVarSet;
const freeDispatchMissMsg = exec_call.freeDispatchMissMsg;
const readArgRun = exec_call.readArgRun;

const parent = @import("../eval.zig");
const ev_chain = @import("chain.zig");
const ev_diag = @import("diag.zig");
const ev_flow = @import("flow.zig");
const ev_frame = @import("frame.zig");
const ev_host = @import("host.zig");
const ev_leaf = @import("leaf.zig");
const ev_resolved = @import("resolved.zig");
const ev_state = @import("state.zig");
const ev_values = @import("values.zig");

const EvalResult = ev_flow.EvalResult;
const FlatCallReq = ev_flow.FlatCallReq;
const Frame = ev_frame.Frame;
const MaybeValueResult = ev_host.MaybeValueResult;
const Step = ev_flow.Step;
const applyBinop = ev_values.applyBinop;
const applyUnop = ev_values.applyUnop;
const compoundAssignMethod = ev_values.compoundAssignMethod;
const constToValue = ev_values.constToValue;
const cvTraceOn = ev_flow.cvTraceOn;
const dispatchBump = ev_diag.dispatchBump;
const dispatchCacheStable = ev_diag.dispatchCacheStable;
const dumpCurrentFrameParamsForDiag = ev_diag.dumpCurrentFrameParamsForDiag;
const dumpFrameChainForDiag = ev_diag.dumpFrameChainForDiag;
const dumpFrameChainForDiagAlways = ev_diag.dumpFrameChainForDiagAlways;
const errResult = ev_flow.errResult;
const flatEnabled = ev_flow.flatEnabled;
const isSetOrMap = ev_values.isSetOrMap;
const lateinitThrow = ev_flow.lateinitThrow;
const missTraceWant = ev_flow.missTraceWant;
const ok = ev_flow.ok;
const operatorMethod = ev_values.operatorMethod;
const popEnclosing = ev_chain.popEnclosing;
const pushEnclosingAccess = ev_chain.pushEnclosingAccess;
const pushEnclosingSubject = ev_chain.pushEnclosingSubject;
const raiseStep = ev_flow.raiseStep;
const stringify = ev_values.stringify;
const valueToI64 = ev_values.valueToI64;

/// Every arm is OUTLINED and `execInst` itself stays `noinline`. Zig does not
/// reclaim block-scoped stack allocations (ziglang/zig#23475), so all the arms'
/// locals would otherwise live in one frame, summed, across the interpreter's
/// recursion. `noinline` is required: outlining the arms alone lets LLVM inline
/// `execInst` into its caller, which ADDS the arm frame instead of replacing it.
pub noinline fn execInst(comptime H: type, allocator: Allocator, frame: *Frame, inst: *const Inst, host: *H) Allocator.Error!Step {
    if (parent.frame_count_on) parent.inst_count += 1;
    if (runtime.prof.op_prof_active) runtime.prof.current_op = @intFromEnum(inst.*);
    switch (inst.*) {
        .Const => |c| {
            const v = try constToValue(allocator, &frame.module.consts.items[c.value.int()]);
            try frame.write(c.dst, v);
        },
        .Move => |mv| {
            const v = frame.read(mv.src);
            v.retain();
            try frame.write(mv.dst, v);
        },
        .MakeCell => |mc| {
            const v = frame.read(mc.src);
            v.retain();
            try frame.write(mc.dst, try Value.newCell(allocator, v));
        },
        .CellGet => |cg| {
            const v = switch (frame.read(cg.cell)) {
                .Cell => |c| blk: {
                    const g = c.borrow();
                    defer g.deinit();
                    break :blk g.get().*;
                },
                else => |other| other,
            };
            v.retain();
            try frame.write(cg.dst, v);
        },
        .CellSet => |cs| return execArmCellSet(H, allocator, frame, cs, host),
        .Not => |n| {
            const v = frame.read(n.src);
            // A user-defined `operator fun not()` overrides the builtin Bool inversion.
            if (v == .Instance) {
                const result = host.callMember(allocator, &v, "not", &.{});
                switch (try result) {
                    .ok => |rv| {
                        try frame.write(n.dst, rv);
                        return .cont;
                    },
                    .err => |e| return raiseStep(frame, e),
                }
            }
            const b = switch (v) {
                .Bool => |bv| !bv,
                else => {
                    if (runtime.envOnce("KLIO_ERR_TRACE") != null) {
                        std.debug.print("[not-miss] in={s} kind={s} span={?any}\n", .{
                            frame.func.name, @tagName(std.meta.activeTag(v)), frame.cur_span,
                        });
                        dumpCurrentFrameParamsForDiag();
                        dumpFrameChainForDiagAlways();
                    }
                    return raiseStep(frame, .{ .Type = "Not on non-bool" });
                },
            };
            try frame.write(n.dst, .{ .Bool = b });
        },
        .UnOp => |u| return execArmUnOp(H, allocator, frame, u, host),
        .BinOp => |bo| return execArmBinOp(H, allocator, frame, bo, host),
        .Trace => |t| frame.cur_span = t.span,
        .LoadParam => |lp| {
            const v = if (lp.idx < frame.params.items.len) frame.params.items[lp.idx] else Value.Unit;
            v.retain();
            try frame.write(lp.dst, v);
        },
        .NotNullAssert => |nn| {
            const v = frame.read(nn.src);
            if (v == .Null) {
                // Code lowered from sema catches the base's class, not a host exception.
                if (frame.module.resolved) |r| return ev_resolved.throwNotNull(H, allocator, frame, host, r);
                const exc = try Value.newException(allocator, .{
                    .fqn = try runtime.strInit(allocator, "kotlin.NullPointerException"),
                    .message = .{},
                    .cause = null,
                });
                return raiseStep(frame, .{ .Throw = exc });
            }
            v.retain();
            try frame.write(nn.dst, v);
        },
        .LateinitCheck => |lc| {
            const v = frame.read(lc.src);
            if (v == .Null) {
                if (frame.module.resolved) |r| return ev_resolved.throwUninitialized(H, allocator, frame, host, r, constStr(frame.module, lc.name) orelse "?");
                return raiseStep(frame, try lateinitThrow(allocator, constStr(frame.module, lc.name) orelse "?"));
            }
            v.retain();
            try frame.write(lc.dst, v);
        },
        .CallStatic => |x| return ev_resolved.execCallStatic(H, allocator, frame, x, host),
        .RCallVirtual => |x| return ev_resolved.execRCallVirtual(H, allocator, frame, x, host),
        .CallInterface => |x| return ev_resolved.execCallInterface(H, allocator, frame, x, host),
        .CallNative => |x| return ev_resolved.execCallNative(H, allocator, frame, x, host),
        .RCallValue => |x| return ev_resolved.execRCallValue(H, allocator, frame, x, host),
        .RNewInstance => |x| return ev_resolved.execRNewInstance(H, allocator, frame, x, host),
        .GetFieldSlot => |x| return ev_resolved.execGetFieldSlot(H, allocator, frame, x, host),
        .SetFieldSlot => |x| return ev_resolved.execSetFieldSlot(H, allocator, frame, x, host),
        .LoadStatic => |x| return ev_resolved.execLoadStatic(H, allocator, frame, x, host),
        .StoreStatic => |x| return ev_resolved.execStoreStatic(H, allocator, frame, x, host),
        .LoadObject => |x| return ev_resolved.execLoadObject(H, allocator, frame, x, host),
        .MakeClosure => |x| return ev_resolved.execMakeClosure(H, allocator, frame, x, host),
        .FunctionRef => |x| return ev_resolved.execFunctionRef(H, allocator, frame, x, host),
        .RPropertyRef => |x| return ev_resolved.execRPropertyRef(H, allocator, frame, x, host),
        .ClassLiteral => |x| return ev_resolved.execClassLiteral(H, allocator, frame, x, host),
        .ClassOf => |x| return ev_resolved.execClassOf(H, allocator, frame, x, host),
        .RInstanceOf => |x| return ev_resolved.execRInstanceOf(H, allocator, frame, x, host),
        .RCast => |x| return ev_resolved.execRCast(H, allocator, frame, x, host),
        .InstanceOfDyn => |x| return ev_resolved.execInstanceOfDyn(H, allocator, frame, x, host),
        .CastDyn => |x| return ev_resolved.execCastDyn(H, allocator, frame, x, host),
        .ArrayGet => |x| return ev_resolved.execArrayGet(H, allocator, frame, x, host),
        .ArraySet => |x| return ev_resolved.execArraySet(H, allocator, frame, x, host),
        .NewArray => |x| return ev_resolved.execNewArray(H, allocator, frame, x, host),
        .LoadCapture => |lc| {
            const v = if (lc.idx < frame.captures.items.len) frame.captures.items[lc.idx] else Value.Unit;
            v.retain();
            try frame.write(lc.dst, v);
        },
    }
    return .cont;
}

noinline fn execArmCellSet(comptime H: type, allocator: Allocator, frame: *Frame, cs: anytype, host: *H) Allocator.Error!Step {
    _ = host;
    const v = frame.read(cs.value);
    v.retain();
    switch (frame.read(cs.cell)) {
        .Cell => |c| {
            const g = c.borrowMut();
            defer g.deinit();
            const old = g.get().*;
            g.get().* = v;
            if (runtime.reclaimEnabled()) old.release(allocator);
        },
        else => {
            try frame.write(cs.cell, v);
        },
    }
    return .cont;
}

noinline fn execArmUnOp(comptime H: type, allocator: Allocator, frame: *Frame, u: anytype, host: *H) Allocator.Error!Step {
    const v = frame.read(u.operand);
    // Outside any class scope a scalar's unary operators are its builtin members that no
    // extension can shadow; an enclosing instance may bring a member-extension operator.
    const enclosing_possible = frame.enclosing_this.items.len != 0 or
        (frame.params.items.len > 0 and frame.params.items[0] == .Instance);
    if (!enclosing_possible) {
        switch (v) {
            .Int, .Long, .Double, .Float, .Short, .Byte, .Char, .UInt, .ULong, .UShort, .UByte => {
                switch (try applyUnop(allocator, u.op, &v)) {
                    .ok => |out| {
                        try frame.write(u.dst, out);
                        return .cont;
                    },
                    .err => {},
                }
            },
            else => {},
        }
    }
    const method = switch (u.op) {
        .Neg => "unaryMinus",
        .Plus => "unaryPlus",
        .Inc => "inc",
        .Dec => "dec",
    };
    if (v == .Instance) {
        switch (try host.callMember(allocator, &v, method, &.{})) {
            .ok => |rv| {
                try frame.write(u.dst, rv);
                return .cont;
            },
            .err => |e| return raiseStep(frame, e),
        }
    }
    // Member-extension operator on a primitive receiver: surface the calling frame's `this`
    // as enclosing-this so the extension-fallback visibility filter accepts the owner.
    var pushed_enclosing = false;
    if (frame.params.items.len > 0 and frame.params.items[0] == .Instance) {
        pushEnclosingAccess(&frame.params.items[0]);
        pushed_enclosing = true;
    }
    const extension_result = try host.callMember(allocator, &v, method, &.{});
    if (pushed_enclosing) popEnclosing();
    switch (extension_result) {
        .ok => |rv| {
            try frame.write(u.dst, rv);
            return .cont;
        },
        .err => |e| switch (e) {
            .Unimplemented => |m| freeDispatchMissMsg(allocator, m),
            else => return raiseStep(frame, e),
        },
    }
    switch (try applyUnop(allocator, u.op, &v)) {
        .ok => |out| try frame.write(u.dst, out),
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

pub noinline fn execArmBinOp(comptime H: type, allocator: Allocator, frame: *Frame, bo: anytype, host: *H) Allocator.Error!Step {
    const l = frame.read(bo.lhs);
    const r = frame.read(bo.rhs);
    switch (try binopValue(H, allocator, l, r, @TypeOf(bo), bo, host)) {
        .ok => |v| try frame.write(bo.dst, v),
        .err => |e| {
            // Code lowered from sema catches the base's ArithmeticException, not a host exception.
            if (frame.module.resolved) |res| {
                if (ev_resolved.integralDivByZero(bo.op, l, r)) return ev_resolved.throwArithmetic(H, allocator, frame, host, res);
            }
            return raiseStep(frame, e);
        },
    }
    return .cont;
}

/// Binary-operator semantics with no frame coupling: the framed arm and the fused tier
/// both call this, so the slow equality, concatenation and compareTo tails exist once.
pub fn binopValue(comptime H: type, allocator: Allocator, l_in: Value, r_in: Value, comptime OpT: type, bo: OpT, host: *H) Allocator.Error!EvalResult {
    var l = l_in;
    var r = r_in;
    // A boxed capture is transparent to every operator: compare the cell's CONTENT.
    while (l == .Cell) {
        const cg = l.Cell.borrow();
        l = cg.get().*;
        cg.deinit();
    }
    while (r == .Cell) {
        const cg = r.Cell.borrow();
        r = cg.get().*;
        cg.deinit();
    }
    // `Add` with a String or null LEFT operand is `String.plus(Any?)`: both sides render
    // through the host so a user `toString` fires. LEFT only, since `collection + element`
    // is the collection's own `plus`; `String?.plus(Any?)` is what `null + x` resolves to.
    const string_add = bo.op == .Add and (l == .String or l == .Null);
    if (bo.op == .StringConcat or string_add) {
        const ls = switch (try stringify(H, allocator, host, &l)) {
            .ok => |s| s,
            .err => |e| return errResult(e),
        };
        const rs = switch (try stringify(H, allocator, host, &r)) {
            .ok => |s| s,
            .err => |e| return errResult(e),
        };
        const combined = try std.mem.concat(allocator, u8, &.{ ls, rs });
        // `ls`/`rs` are owned renderings; `combined` is adopted by the StringRef cell.
        if (runtime.freeScratch()) {
            allocator.free(ls);
            allocator.free(rs);
        }
        return ok(.{ .String = try runtime.strInitOwned(allocator, combined) });
    }
    if ((bo.op == .Add or bo.op == .Sub) and switch (l) {
        .Map, .List, .Set, .Sequence, .Range => true,
        else => false,
    }) {
        // `xs += y` on a MUTABLE collection dispatches the in-place `plusAssign`/`minusAssign`
        // Kotlin prefers; a read-only receiver or a plain `xs + y` takes `plus`/`minus` below.
        if (bo.compound) {
            const mutable = switch (l) {
                .List => |c| c.mutable,
                .Set => |c| c.mutable,
                .Map => |c| c.mutable,
                else => false,
            };
            if (mutable) {
                const assign = if (bo.op == .Add) "plusAssign" else "minusAssign";
                switch (try host.callMember(allocator, &l, assign, &.{r})) {
                    .ok => {
                        l.retain();
                        return ok(l);
                    },
                    .err => |e| return errResult(e),
                }
            }
        }
        const method = if (bo.op == .Add) "plus" else "minus";
        switch (try host.callMember(allocator, &l, method, &.{r})) {
            .ok => |rv| {
                return ok(rv);
            },
            .err => |e| return errResult(e),
        }
    }
    // Arrays define `+` (`plus`) but no `-`.
    if (bo.op == .Add and l == .Array) {
        switch (try host.callMember(allocator, &l, "plus", &.{r})) {
            .ok => |rv| {
                return ok(rv);
            },
            .err => |e| return errResult(e),
        }
    }
    // `===`/`!==` is pointer identity, never a user `equals` dispatch.
    if (bo.op == .IdentEq or bo.op == .IdentNeq) {
        const same = Value.referenceEq(&l, &r);
        const b = if (bo.op == .IdentNeq) !same else same;
        return ok(.{ .Bool = b });
    }
    // A `Result` has no user `equals` surface of its own; its payload still follows Kotlin `==`.
    if ((bo.op == .Eq or bo.op == .NotEq or bo.op == .BoxedEq or bo.op == .BoxedNotEq) and
        (l == .Result or r == .Result))
    {
        const eq = if (l == .Result and r == .Result and l.Result.ok == r.Result.ok)
            if (comptime @hasDecl(H, "deepValueEquals"))
                try host.deepValueEquals(allocator, l.Result.payload.asPtr(), r.Result.payload.asPtr())
            else
                Value.structuralEq(l.Result.payload.asPtr(), r.Result.payload.asPtr())
        else
            false;
        const b = if (bo.op == .NotEq or bo.op == .BoxedNotEq) !eq else eq;
        return ok(.{ .Bool = b });
    }
    // The suspension marker has identity-only equality and no member surface.
    if ((bo.op == .Eq or bo.op == .NotEq or bo.op == .BoxedEq or bo.op == .BoxedNotEq) and
        (l == .CoroutineSuspended or r == .CoroutineSuspended))
    {
        const eq = Value.structuralEq(&l, &r);
        const b = if (bo.op == .NotEq or bo.op == .BoxedNotEq) !eq else eq;
        return ok(.{ .Bool = b });
    }
    // `x == null` compares against the null literal by identity, never a user `equals`.
    if ((bo.op == .Eq or bo.op == .NotEq or bo.op == .BoxedEq or bo.op == .BoxedNotEq) and
        (l == .Null or r == .Null))
    {
        const both_null = l == .Null and r == .Null;
        const b = if (bo.op == .NotEq or bo.op == .BoxedNotEq) !both_null else both_null;
        return ok(.{ .Bool = b });
    }
    // Set/Map (and Pair/Triple) `==` compares entry-wise so an element's user `equals` fires;
    // bare structural equality would treat a non-data Instance by identity. A native LEFT
    // operand against an Instance routes here too, since Kotlin dispatches on the left.
    if ((bo.op == .Eq or bo.op == .NotEq or bo.op == .BoxedEq or bo.op == .BoxedNotEq) and
        ((isSetOrMap(&l) and isSetOrMap(&r)) or
            ((isSetOrMap(&l) or l == .List) and r == .Instance) or
            (l == .Pair and r == .Pair) or (l == .Triple and r == .Triple)))
    {
        if (comptime @hasDecl(H, "deepValueEquals")) {
            const eq = try host.deepValueEquals(allocator, &l, &r);
            const neg = bo.op == .NotEq or bo.op == .BoxedNotEq;
            return ok(.{ .Bool = if (neg) !eq else eq });
        }
    }
    // Callable references compare by target, bound receiver and adaptation, never by
    // closure identity alone.
    if ((bo.op == .Eq or bo.op == .NotEq or bo.op == .BoxedEq or bo.op == .BoxedNotEq) and
        (l == .IrClosure or r == .IrClosure or l == .PropertyRef or r == .PropertyRef) and
        comptime @hasDecl(H, "deepValueEquals"))
    {
        // A callable never equals a non-callable value; an Instance keeps its own `equals`.
        const eq = if (l != .Instance and r != .Instance)
            try host.deepValueEquals(allocator, &l, &r)
        else
            false;
        const neg = bo.op == .NotEq or bo.op == .BoxedNotEq;
        if (l != .Instance and r != .Instance) return ok(.{ .Bool = if (neg) !eq else eq });
    }
    if (operatorMethod(bo.op)) |method| {
        // A Char compared with another scalar has no builtin order: only a `compareTo`
        // extension the program declares can serve it.
        const is_compare = bo.op == .Less or bo.op == .LessEq or bo.op == .Greater or bo.op == .GreaterEq;
        const char_mixed_compare = is_compare and
            ((std.meta.activeTag(l) != std.meta.activeTag(r) and (l == .Char or r == .Char)) or
                l == .Null or r == .Null or l == .Array or r == .Array);
        if (l == .Instance or r == .Instance or char_mixed_compare) {
            // A `fun interface` SAM wrapper has no equality of its own: compare through the
            // wrapper, so a memoized lambda equals its converted form.
            if ((bo.op == .Eq or bo.op == .BoxedEq or bo.op == .NotEq or bo.op == .BoxedNotEq) and
                (Value.samTargetOf(&l) != null or Value.samTargetOf(&r) != null))
            {
                const eqv = Value.structuralEq(&l, &r);
                const bv = if (bo.op == .NotEq or bo.op == .BoxedNotEq) !eqv else eqv;
                return ok(.{ .Bool = bv });
            }
            // `a == b` dispatches on the LEFT, but a builtin collection carries only structural
            // equality; swap so a user Instance's own `equals` runs. Equality is symmetric.
            const swap = (bo.op == .Eq or bo.op == .BoxedEq or bo.op == .NotEq or bo.op == .BoxedNotEq) and l != .Instance and r == .Instance;
            const recv_ptr = if (swap) &r else &l;
            const arg_val = if (swap) l else r;
            // Strict extension dispatch: an operator extension whose declared receiver rejects `l`
            // is no candidate, so `Unimplemented` surfaces and the `<op>Assign` fallback can fire.
            var result: Value = undefined;
            const ext_only: ?EvalResult = if (char_mixed_compare and comptime @hasDecl(H, "extensionFnFallback"))
                try host.extensionFnFallback(allocator, recv_ptr, method, &.{arg_val}, false, null, null)
            else
                null;
            switch (ext_only orelse try host.callMemberStrictExt(allocator, recv_ptr, method, &.{arg_val}, &.{null}, null)) {
                .ok => |v| result = v,
                .err => |e| switch (e) {
                    // The type may declare only the in-place `<op>Assign` form.
                    .Unimplemented => {
                        if (l == .Instance and compoundAssignMethod(bo.op) != null) {
                            const assign = compoundAssignMethod(bo.op).?;
                            switch (try host.callMember(allocator, &l, assign, &.{r})) {
                                .ok => {},
                                .err => |e2| return errResult(e2),
                            }
                            result = l;
                        } else if (bo.op == .Eq or bo.op == .BoxedEq or bo.op == .NotEq or bo.op == .BoxedNotEq) {
                            // Kotlin's default equality is structural.
                            const boxed = bo.op == .BoxedEq or bo.op == .BoxedNotEq;
                            result = .{ .Bool = if (boxed)
                                Value.structuralEqBoxed(&l, &r)
                            else
                                Value.structuralEq(&l, &r) };
                        } else {
                            return errResult(e);
                        }
                    },
                    else => return errResult(e),
                },
            }
            const final_val: Value = switch (bo.op) {
                .Less => .{ .Bool = if (valueToI64(&result)) |i| i < 0 else false },
                .LessEq => .{ .Bool = if (valueToI64(&result)) |i| i <= 0 else false },
                .Greater => .{ .Bool = if (valueToI64(&result)) |i| i > 0 else false },
                .GreaterEq => .{ .Bool = if (valueToI64(&result)) |i| i >= 0 else false },
                .NotEq, .BoxedNotEq => if (result == .Bool) Value{ .Bool = !result.Bool } else result,
                else => result,
            };
            return ok(final_val);
        }
    }
    // `..`/`..<` over operands the i64-backed `Range` cannot represent (floating point,
    // String, any other `Comparable`) routes to the stdlib `rangeTo`/`rangeUntil`.
    if ((bo.op == .RangeTo or bo.op == .RangeUntil) and
        (l == .Double or l == .Float or r == .Double or r == .Float or
            l == .String or r == .String or l == .Instance or r == .Instance))
    {
        const method = if (bo.op == .RangeUntil) "rangeUntil" else "rangeTo";
        switch (try host.callMember(allocator, &l, method, &.{r})) {
            .ok => |rv| {
                return ok(rv);
            },
            .err => |e| return errResult(e),
        }
    }
    // A builtin List whose ELEMENTS are user instances needs an element-wise compare to
    // dispatch their `equals`; structural comparison alone cannot.
    if ((bo.op == .Eq or bo.op == .NotEq or bo.op == .BoxedEq or bo.op == .BoxedNotEq) and
        (l == .List or r == .List))
    {
        if (host.collectionsEqualHostAware(allocator, &l, &r)) |eq| {
            const b = if (bo.op == .NotEq or bo.op == .BoxedNotEq) !eq else eq;
            return ok(.{ .Bool = b });
        }
    }
    switch (try applyBinop(allocator, bo.op, &l, &r)) {
        .ok => |out| return ok(out),
        .err => |e| return errResult(e),
    }
}
