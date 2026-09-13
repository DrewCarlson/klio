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

const argNamesAllNull = exec_call.argNamesAllNull;
const callerThisValue = exec_call.callerThisValue;
const constStr = exec_call.constStr;
const envVarSet = exec_call.envVarSet;
const execArmAstLambda = exec_call.execArmAstLambda;
const execArmBuildObject = exec_call.execArmBuildObject;
const execArmCall = exec_call.execArmCall;
const execArmCallMemberOrValue = exec_call.execArmCallMemberOrValue;
const execArmCallSpread = exec_call.execArmCallSpread;
const execArmCallSuper = exec_call.execArmCallSuper;
const execArmCallValue = exec_call.execArmCallValue;
const execArmCallValueOrMember = exec_call.execArmCallValueOrMember;
const execArmCallVirtual = exec_call.execArmCallVirtual;
const execArmCast = exec_call.execArmCast;
const execArmCtxCall = exec_call.execArmCtxCall;
const execArmCtxScope = exec_call.execArmCtxScope;
const execArmIndex = exec_call.execArmIndex;
const execArmIndexSet = exec_call.execArmIndexSet;
const execArmInstanceOf = exec_call.execArmInstanceOf;
const execArmLambda = exec_call.execArmLambda;
const execArmLoadFromThisOrGlobal = exec_call.execArmLoadFromThisOrGlobal;
const execArmMemberRef = exec_call.execArmMemberRef;
const execArmNewInstance = exec_call.execArmNewInstance;
const execArmNewList = exec_call.execArmNewList;
const execArmPropertyRef = exec_call.execArmPropertyRef;
const execArmQualifiedThis = exec_call.execArmQualifiedThis;
const execArmRegisterClass = exec_call.execArmRegisterClass;
const execArmStoreToThisOrGlobal = exec_call.execArmStoreToThisOrGlobal;
const execCallMemberOrGlobal = exec_call.execCallMemberOrGlobal;
const fastSubscript = exec_call.fastSubscript;
const freeArgNames = exec_call.freeArgNames;
const freeDispatchMissMsg = exec_call.freeDispatchMissMsg;
const nullSiteOk = exec_call.nullSiteOk;
const primitiveMemberFast = exec_call.primitiveMemberFast;
const rangeIterFast = exec_call.rangeIterFast;
const readArgRun = exec_call.readArgRun;
const resolveArgNames = exec_call.resolveArgNames;

const parent = @import("../eval.zig");
const ev_chain = @import("chain.zig");
const ev_diag = @import("diag.zig");
const ev_flow = @import("flow.zig");
const ev_frame = @import("frame.zig");
const ev_host = @import("host.zig");
const ev_leaf = @import("leaf.zig");
const ev_native = @import("native.zig");
const ev_state = @import("state.zig");
const ev_values = @import("values.zig");

const EvalResult = ev_flow.EvalResult;
const FlatCallReq = ev_flow.FlatCallReq;
const Frame = ev_frame.Frame;
const LeafOutcome = ev_native.LeafOutcome;
const MaybeValueResult = ev_host.MaybeValueResult;
const Step = ev_flow.Step;
const applyBinop = ev_values.applyBinop;
const applyUnop = ev_values.applyUnop;
const builtinFieldFast = ev_leaf.builtinFieldFast;
const cmTraceWant = ev_flow.cmTraceWant;
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
const gfStatsBump = ev_diag.gfStatsBump;
const gfTraceWant = ev_flow.gfTraceWant;
const isSetOrMap = ev_values.isSetOrMap;
const ladderStatsBump = ev_diag.ladderStatsBump;
const lateinitThrow = ev_flow.lateinitThrow;
const memberSiteEnabled = ev_flow.memberSiteEnabled;
const missTraceWant = ev_flow.missTraceWant;
const ok = ev_flow.ok;
const operatorMethod = ev_values.operatorMethod;
const popEnclosing = ev_chain.popEnclosing;
const pushEnclosingAccess = ev_chain.pushEnclosingAccess;
const pushEnclosingSubject = ev_chain.pushEnclosingSubject;
const raiseStep = ev_flow.raiseStep;
const serveOuterSlotRoute = ev_diag.serveOuterSlotRoute;
const stringify = ev_values.stringify;
const tryLeafValues = ev_native.tryLeafValues;
const valueToI64 = ev_values.valueToI64;
const vcallFlatEnabled = ev_flow.vcallFlatEnabled;

/// Every arm is OUTLINED and `execInst` itself stays `noinline`. Zig does not
/// reclaim block-scoped stack allocations (ziglang/zig#23475), so all the arms'
/// locals would otherwise live in one frame, summed, across the interpreter's
/// recursion. `noinline` is required: outlining the arms alone lets LLVM inline
/// `execInst` into its caller, which ADDS the arm frame instead of replacing it.
pub noinline fn execInst(comptime H: type, allocator: Allocator, frame: *Frame, inst: *const Inst, host: *H) Allocator.Error!Step {
    if (parent.frame_count_on) parent.inst_count += 1;
    if (runtime.prof.op_prof_active) runtime.prof.current_op = @intFromEnum(inst.*);
    switch (inst.*) {
        .SuspendResumePoint => {
            // No runtime effect on its own; the entry dispatch table reads `state`.
        },
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
        .EnclosingPush => |x| {
            const v = frame.read(x.src);
            pushEnclosingSubject(&v);
        },
        .EnclosingPop => popEnclosing(),
        .LoadParam => |lp| {
            const v = if (lp.idx < frame.params.items.len) frame.params.items[lp.idx] else Value.Unit;
            v.retain();
            try frame.write(lp.dst, v);
        },
        .NotNullAssert => |nn| {
            const v = frame.read(nn.src);
            if (v == .Null) {
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
                return raiseStep(frame, try lateinitThrow(allocator, constStr(frame.module, lc.name) orelse "?"));
            }
            v.retain();
            try frame.write(lc.dst, v);
        },
        .GetField => |*gf| {
            const gf_step = try execArmGetField(H, allocator, frame, gf, host);
            if (gfTraceWant()) |w0| {
                if (constStr(frame.module, gf.field)) |fname| {
                    if (std.mem.find(u8, fname, w0) != null and gf_step == .cont) {
                        const rv = frame.read(gf.dst);
                        const rn: []const u8 = if (rv == .Instance) blk: {
                            const g = rv.Instance.borrow();
                            const cg = g.get().class.borrow();
                            const n = cg.get().name;
                            cg.deinit();
                            g.deinit();
                            break :blk n;
                        } else @tagName(rv);
                        std.debug.print("[gfarm]   -> result={s}\n", .{rn});
                    }
                }
            }
            return gf_step;
        },
        .SetField => |sf| return execArmSetField(H, allocator, frame, sf, host),
        .CompoundField => |cf| return execArmCompoundField(H, allocator, frame, cf, host),
        .Call => |*call| return execArmCall(H, allocator, frame, call, host, true),
        .CallValue => |cv| return execArmCallValue(H, allocator, frame, cv, host),
        .CallValueWithThis => |cvt| {
            var callee_v = frame.read(cvt.callee);
            // A boxed capture holds the callable: a recursive local extension function reaches
            // its own closure through the shared self-cell, so classify the Cell's CONTENT.
            if (callee_v == .Cell) {
                const cg = callee_v.Cell.borrow();
                callee_v = cg.get().*;
                cg.deinit();
            }
            const recv = frame.read(cvt.receiver);
            const arg_values = try readArgRun(allocator, frame, cvt.args, cvt.n_args);
            defer allocator.free(arg_values);
            const names = try resolveArgNames(allocator, frame.module, cvt.arg_names);
            defer freeArgNames(allocator, names);
            if (cvTraceOn()) {
                std.debug.print("[cvt-instr] exact={} recv={s} n_args={d} caller={s}", .{
                    cvt.receiver_shape_exact, @tagName(std.meta.activeTag(recv)), arg_values.len, frame.func.name,
                });
                for (arg_values) |*av| std.debug.print(" {s}", .{@tagName(std.meta.activeTag(av.*))});
                std.debug.print("\n", .{});
            }
            // Flat receiver-lambda dispatch: only the plain bound shape (a `this`-capture closure
            // at exact arity) runs as a pushed activation; every other shape keeps the recursive path.
            if (comptime @hasDecl(H, "prepareClosureWithThisFlatCall")) {
                if (flatEnabled() and cvt.recv_head == null and callee_v == .IrClosure and argNamesAllNull(cvt.arg_names)) {
                    if (try host.prepareClosureWithThisFlatCall(allocator, &callee_v, &recv, arg_values)) |prep0| {
                        var prep = prep0;
                        prep.dst = cvt.dst;
                        frame.flat_call = prep;
                        return .flat_call;
                    }
                }
            }
            const result = if (cvt.recv_head != null and comptime @hasDecl(H, "callValueWithThisHead")) blk: {
                const head = constStr(frame.module, cvt.recv_head.?) orelse "";
                break :blk try host.callValueWithThisHead(allocator, &callee_v, &recv, arg_values, names, head);
            } else if (cvt.receiver_shape_exact)
                try host.callValueWithThisExact(allocator, &callee_v, &recv, arg_values, names)
            else
                try host.callValueWithThis(allocator, &callee_v, &recv, arg_values, names);
            switch (result) {
                .ok => |rv| try frame.write(cvt.dst, rv),
                .err => |e| return raiseStep(frame, e),
            }
        },
        .CallSpread => |cs| return execArmCallSpread(H, allocator, frame, cs, host),
        .CallSuper => |csup| return execArmCallSuper(H, allocator, frame, csup, host),
        .CallMemberOrGlobal => |*cmg| return execCallMemberOrGlobal(H, allocator, frame, cmg, host),
        .CallMember => |*cm| return execArmCallMember(H, allocator, frame, cm, host),
        .CallVirtual => |*cv| return execArmCallVirtual(H, allocator, frame, cv, host),
        .CallMemberOrValue => |cmv| return execArmCallMemberOrValue(H, allocator, frame, cmv, host),
        .CallValueOrMember => |cvm| return execArmCallValueOrMember(H, allocator, frame, cvm, host),
        .NewInstance => |ni| return execArmNewInstance(H, allocator, frame, ni, host),
        .InstanceOf => |io| return execArmInstanceOf(H, allocator, frame, io, host),
        .CtxLoad => |cl| {
            if (comptime !@hasDecl(H, "ctxResolve")) {
                try frame.write(cl.dst, .Null);
                return .cont;
            }
            const ty_name = constStr(frame.module, cl.ty) orelse "";
            const v = host.ctxResolve(ty_name, cl.erased) orelse Value.Null;
            v.retain();
            try frame.write(cl.dst, v);
        },
        .CtxScope => |cs| return execArmCtxScope(H, allocator, frame, cs, host),
        .CtxCall => |cc| return execArmCtxCall(H, allocator, frame, cc, host),
        .Cast => |cast| return execArmCast(H, allocator, frame, cast, host),
        .Lambda => |lam| return execArmLambda(H, allocator, frame, lam, host),
        .AstLambda => |al| return execArmAstLambda(H, allocator, frame, al, host),
        .RegisterClass => |rc| return execArmRegisterClass(H, allocator, frame, rc, host),
        .BuildObject => |bobj| return execArmBuildObject(H, allocator, frame, bobj, host),
        .StoreGlobal => |sg| {
            const name_str = constStr(frame.module, sg.name) orelse
                return raiseStep(frame, .{ .Type = "StoreGlobal: name not a string const" });
            const v = frame.read(sg.value);
            switch (try host.storeGlobal(allocator, name_str, v)) {
                .ok => {},
                .err => |e| return raiseStep(frame, e),
            }
        },
        .StoreToThisOrGlobal => |stg| return execArmStoreToThisOrGlobal(H, allocator, frame, stg, host),
        .LoadGlobal => |lg| {
            switch (try loadGlobalValue(H, allocator, frame.module, lg, host)) {
                .ok => |v| try frame.write(lg.dst, v),
                .err => |e| return raiseStep(frame, e),
            }
        },
        .LoadCapture => |lc| {
            const v = if (lc.idx < frame.captures.items.len) frame.captures.items[lc.idx] else Value.Unit;
            v.retain();
            try frame.write(lc.dst, v);
        },
        .LoadFromThisOrGlobal => |*lt| return execArmLoadFromThisOrGlobal(H, allocator, frame, lt, host),
        .Index => |ix| return execArmIndex(H, allocator, frame, ix, host),
        .IndexSet => |ixs| return execArmIndexSet(H, allocator, frame, ixs, host),
        .NewList => |nl| return execArmNewList(H, allocator, frame, nl, host),
        .QualifiedThis => |qt| return execArmQualifiedThis(H, allocator, frame, qt, host),
        .PropertyRef => |pr| return execArmPropertyRef(H, allocator, frame, pr, host),
        .MemberRef => |mr| return execArmMemberRef(H, allocator, frame, mr, host),
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
        .err => |e| return raiseStep(frame, e),
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

/// The stored slot's name against the site's name. Both come from the same module string
/// pool at nearly every site, so the pointer check settles this per-read guard.
inline fn sameFieldName(stored: []const u8, want: []const u8) bool {
    if (stored.ptr == want.ptr and stored.len == want.len) return true;
    if (std.mem.eql(u8, stored, want)) return true;
    // A scoped `$sgetter$<owner>\u{1f}<prop>` site stores its slot under the
    // bare property name; the separator-guarded suffix keeps it exact.
    return std.mem.startsWith(u8, want, "$sgetter$") and
        want.len > stored.len and
        std.mem.endsWith(u8, want, stored) and
        want[want.len - stored.len - 1] == '\u{1f}';
}

/// Dispatch-phase nanoseconds under `KLIO_FRAME_COUNT`. Only phases that RETURN before
/// the callee runs may be timed, or the callee's execution is billed to dispatch.
pub fn armNow() u64 {
    return gfNow();
}

pub fn armIsOn() bool {
    return parent.frame_count_on;
}

inline fn gfNow() u64 {
    if (!parent.frame_count_on) return 0;
    return @intCast(runtime.clockMonotonicNanos());
}

var gf_slow_census_state: u8 = 0;

var gf_slow_census_val: bool = false;

fn gfSlowCensusOn() bool {
    if (gf_slow_census_state == 0) {
        gf_slow_census_val = runtime.envOnce("KLIO_GF_SLOW_CENSUS") != null;
        gf_slow_census_state = 1;
    }
    return gf_slow_census_val;
}

const POLY_FIELD_SLOTS: usize = 1 << 14;

const PolyFieldEnt = struct { key: u64 = 0, route: u64 = 0 };

threadlocal var poly_field_cache: [POLY_FIELD_SLOTS]PolyFieldEnt = @splat(.{});

inline fn polyFieldKey(site: usize, cls: u64) u64 {
    const k = (@as(u64, site) *% 0x9E3779B97F4A7C15) ^ (cls *% 0xC2B2AE3D27D4EB4F);
    return k | 1;
}

fn polyFieldRoute(comptime H: type, host: *H, site: usize, cls: u64, recv: *const Value, name: []const u8) ?u64 {
    // The host's own (class, name) memo is generation-guarded; this cache
    // mirrors it, so the generation belongs in the key.
    const gen: u64 = if (comptime @hasDecl(H, "dispatchCacheGen")) H.dispatchCacheGen() else 0;
    const key = polyFieldKey(site, cls ^ (gen *% 0x51_7C_C1_B7_27_22_0A_95));
    const slot = &poly_field_cache[@as(usize, @intCast(key >> 17)) & (POLY_FIELD_SLOTS - 1)];
    if (slot.key == key) return if (slot.route == 0) null else slot.route;
    const r = host.fieldSiteRoute(recv, name);
    const route: u64 = if (r) |rr| (if (rr.cls == cls) rr.route else 0) else 0;
    slot.key = key;
    slot.route = route;
    return if (route == 0) null else route;
}

noinline fn execArmGetField(comptime H: type, allocator: Allocator, frame: *Frame, gf: anytype, host: *H) Allocator.Error!Step {
    if (parent.frame_count_on) parent.gf_slow += 1;
    const recv = frame.read(gf.receiver);
    if (gfTraceWant()) |w0| {
        if (constStr(frame.module, gf.field)) |fname| {
            if (std.mem.find(u8, fname, w0) != null) {
                const rn: []const u8 = if (recv == .Instance) blk: {
                    const g = recv.Instance.borrow();
                    const cg = g.get().class.borrow();
                    const n = cg.get().name;
                    cg.deinit();
                    g.deinit();
                    break :blk n;
                } else @tagName(recv);
                std.debug.print("[gfarm] field={s} recv={s} in={s}\n", .{ fname, rn, frame.func.name });
            }
        }
    }
    const name = constStr(frame.module, gf.field) orelse
        return raiseStep(frame, .{ .Type = "GetField: name not a string const" });
    if (try builtinFieldFast(H, host, allocator, &recv, name)) |bv| {
        try frame.write(gf.dst, bv);
        return .cont;
    }
    // `<class-companion-or-self>`: a bare class name in value position reads through the
    // per-class companion memo; a NON-class receiver of the sentinel is an identity read.
    if (std.mem.eql(u8, name, "<class-companion-or-self>")) {
        if (recv == .Class) {
            const g = recv.Class.borrow();
            defer g.deinit();
            switch (g.get().companion_read_state.load(.acquire)) {
                1 => {
                    recv.retain();
                    try frame.write(gf.dst, recv);
                    return .cont;
                },
                2 => {
                    const v = g.get().companion_read_value;
                    v.retain();
                    try frame.write(gf.dst, v);
                    return .cont;
                },
                else => {},
            }
        } else {
            recv.retain();
            try frame.write(gf.dst, recv);
            return .cont;
        }
    }
    // Keep the executing function's receiver reachable as the enclosing `this` while the
    // property resolves; in a lambda it rides the captured `this`, which `callerThisValue` finds.
    var pushed_enclosing = false;
    if (callerThisValue(frame)) |ct_v| {
        var ct = ct_v;
        const same = recv == .Instance and ct == .Instance and
            ObjRef(InstanceData).ptrEq(ct.Instance, recv.Instance);
        if (!same) {
            pushEnclosingAccess(&ct);
            pushed_enclosing = true;
        }
    }
    // Site memo: serve a stored slot or class getter directly when the receiver's class claimed
    // this site. The slot read re-verifies by name and declines lateinit and delegate shapes.
    if (comptime @hasDecl(H, "fieldSiteRoute")) {
        if (recv == .Instance) {
            const w0 = @atomicLoad(u64, @constCast(&gf.site_cls), .acquire);
            var site_mismatch = false;
            if (w0 > 1) fast: {
                var getter_fid: u64 = 0;
                {
                    const g = recv.Instance.borrow();
                    defer g.deinit();
                    const b = g.get();
                    if (w0 != @as(u64, @intCast(b.class.identity()))) {
                        site_mismatch = true;
                        break :fast;
                    }
                    const route = @atomicLoad(u64, @constCast(&gf.site_route), .acquire);
                    if (route == 0) break :fast;
                    if (route & 3 == 1) {
                        const idx: usize = @intCast(route >> 2);
                        if (idx >= b.fields.items.len) break :fast;
                        const f = &b.fields.items[idx];
                        // A recorded LAYOUT match proves the index names this property;
                        // the claim key stays the CLASS, as two classes can share a layout.
                        if (@atomicLoad(u64, @constCast(&gf.site_shape), .monotonic) != b.shapeOf() and
                            !sameFieldName(f.name, name)) break :fast;
                        const v = f.value;
                        if (v == .Delegate) break :fast;
                        if (parent.frame_count_on) parent.gf_mono += 1;
                        // A stored slot holding NULL is a plain null unless the
                        // property is an unset `lateinit`, whose read must throw.
                        if (v == .Null) {
                            if (comptime !@hasDecl(H, "storedNullServable")) break :fast;
                            if (!nullSiteOk(H, host, &recv, name, @constCast(&gf.null_ok))) break :fast;
                        }
                        v.retain();
                        if (pushed_enclosing) popEnclosing();
                        try frame.write(gf.dst, v);
                        return .cont;
                    }
                    if (route & 3 == 2) getter_fid = route >> 2;
                    if (route & 3 == 3) {
                        if (serveOuterSlotRoute(&recv, name, route)) |v| {
                            if (pushed_enclosing) popEnclosing();
                            try frame.write(gf.dst, v);
                            return .cont;
                        }
                        break :fast;
                    }
                }
                if (getter_fid != 0) {
                    if (parent.frame_count_on) parent.gf_getter += 1;
                    const t0 = gfNow();
                    defer parent.gf_getter_ns +%= gfNow() -% t0;
                    const got_g = host.runFieldGetter(allocator, @enumFromInt(getter_fid), recv);
                    if (pushed_enclosing) popEnclosing();
                    switch (try got_g) {
                        .ok => |v| {
                            v.retain();
                            try frame.write(gf.dst, v);
                            return .cont;
                        },
                        .err => |e| return raiseStep(frame, e),
                    }
                }
            }
            // A polymorphic site: the mono-class claim belongs to another receiver class. Serve this
            // class from its own (class, name) memo route, leaving the site's claim untouched.
            if (site_mismatch) poly: {
                const cls_now: u64 = @intCast(runtime.InstanceData.classIdentityUnlocked(recv.Instance));
                const r: struct { route: u64 } = .{
                    .route = polyFieldRoute(H, host, @intFromPtr(gf), cls_now, &recv, name) orelse break :poly,
                };
                if (r.route & 3 == 1) {
                    const idx: usize = @intCast(r.route >> 2);
                    const g = recv.Instance.borrow();
                    defer g.deinit();
                    const b = g.get();
                    if (idx >= b.fields.items.len) break :poly;
                    const f = &b.fields.items[idx];
                    if (!sameFieldName(f.name, name)) break :poly;
                    const v = f.value;
                    if (v == .Null or v == .Delegate) break :poly;
                    if (parent.frame_count_on) parent.gf_poly += 1;
                    v.retain();
                    if (pushed_enclosing) popEnclosing();
                    try frame.write(gf.dst, v);
                    return .cont;
                }
                if (r.route & 3 == 2) {
                    const got_g = host.runFieldGetter(allocator, @enumFromInt(r.route >> 2), recv);
                    if (pushed_enclosing) popEnclosing();
                    switch (try got_g) {
                        .ok => |v| {
                            v.retain();
                            try frame.write(gf.dst, v);
                            return .cont;
                        },
                        .err => |e| return raiseStep(frame, e),
                    }
                }
                if (r.route & 3 == 3) {
                    if (serveOuterSlotRoute(&recv, name, r.route)) |v| {
                        if (pushed_enclosing) popEnclosing();
                        try frame.write(gf.dst, v);
                        return .cont;
                    }
                }
            }
            if (gfSlowCensusOn()) {
                const cn: []const u8 = if (recv == .Instance) blk: {
                    const g = recv.Instance.borrow();
                    defer g.deinit();
                    const cg = g.get().class.borrow();
                    defer cg.deinit();
                    break :blk cg.get().name;
                } else @tagName(recv);
                std.debug.print("[gf-slow] {s}.{s}\n", .{ cn, name });
            }
        }
    }
    runtime.prof.opRoute(14);
    gfStatsBump(&recv, name);
    const t_slow = gfNow();
    const got = host.getField(allocator, &recv, name);
    parent.gf_slow_ns +%= gfNow() -% t_slow;
    if (pushed_enclosing) popEnclosing();
    switch (try got) {
        // host.getField returns a borrowed field value; the register owns its ref.
        .ok => |v| {
            v.retain();
            if (comptime @hasDecl(H, "fieldSiteRoute")) {
                if (recv == .Instance and @atomicLoad(u64, @constCast(&gf.site_cls), .monotonic) == 0) {
                    // Claim only once a route exists: the (class, name) memo fills lazily,
                    // so a no-route first read must leave the site free for a later retry.
                    if (host.fieldSiteRoute(&recv, name)) |r| {
                        // Bind (shape, index, name) under ONE borrow, so the recorded
                        // layout is the one the index was verified against.
                        const shp: u64 = blk: {
                            const g2 = recv.Instance.borrow();
                            defer g2.deinit();
                            const b2 = g2.get();
                            if (r.route & 3 != 1) break :blk 0;
                            const idx2: usize = @intCast(r.route >> 2);
                            if (idx2 >= b2.fields.items.len) break :blk 0;
                            if (!sameFieldName(b2.fields.items[idx2].name, name)) break :blk 0;
                            const sp = b2.shapeOf();
                            break :blk if (sp > 1) sp else 0;
                        };
                        if (@cmpxchgStrong(u64, @constCast(&gf.site_cls), 0, r.cls, .acq_rel, .monotonic) == null) {
                            if (shp != 0) @atomicStore(u64, @constCast(&gf.site_shape), shp, .monotonic);
                            if (r.route != 0) @atomicStore(u64, @constCast(&gf.site_route), r.route, .release);
                        }
                    }
                }
            }
            try frame.write(gf.dst, v);
        },
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

noinline fn execArmSetField(comptime H: type, allocator: Allocator, frame: *Frame, sf: anytype, host: *H) Allocator.Error!Step {
    const recv = frame.read(sf.receiver);
    const v = frame.read(sf.value);
    const name = constStr(frame.module, sf.field) orelse
        return raiseStep(frame, .{ .Type = "SetField: name not a string const" });
    const super_owner: ?[]const u8 = if (sf.super_owner) |c| constStr(frame.module, c) else null;
    switch (try host.setFieldFrom(allocator, &recv, name, v, super_owner)) {
        .ok => {},
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

fn modCountFrozenEval(mc: ?runtime.ObjRef(u64)) bool {
    const cell = mc orelse return false;
    const g = cell.borrow();
    defer g.deinit();
    return (g.get().* & runtime.FROZEN_MOD_BIT) != 0;
}

noinline fn execArmCompoundField(comptime H: type, allocator: Allocator, frame: *Frame, cf: anytype, host: *H) Allocator.Error!Step {
    const recv = frame.read(cf.receiver);
    const v = frame.read(cf.value);
    const name = constStr(frame.module, cf.field) orelse
        return raiseStep(frame, .{ .Type = "CompoundField: name not a string const" });
    const cur = switch (try host.getField(allocator, &recv, name)) {
        .ok => |fv| fv,
        .err => |e| return raiseStep(frame, e),
    };
    // A MUTABLE collection property compound-assigns in place: Kotlin dispatches `<op>Assign`
    // on the field value with NO write-back. A read-only value resolves to the binary `plus`
    // instead, and the property write-back below stores the fresh result.
    const is_collection = switch (cur) {
        .List => |l| l.mutable and !modCountFrozenEval(l.mod_count.get()),
        .Set => |st| st.mutable and !modCountFrozenEval(st.mod_count.get()),
        .Map => |m| m.mutable,
        else => false,
    };
    const assign = compoundAssignMethod(cf.op);
    if (is_collection and assign != null) {
        switch (try host.callMember(allocator, &cur, assign.?, &.{v})) {
            .ok => {},
            .err => |e| return raiseStep(frame, e),
        }
        return .cont;
    }
    // Prefer a user-declared `<op>Assign`: it mutates in place with no write-back.
    if (cur == .Instance and assign != null) {
        switch (try host.callMember(allocator, &cur, assign.?, &.{v})) {
            .ok => return .cont,
            .err => |e| switch (e) {
                .Unimplemented => |m| freeDispatchMissMsg(allocator, m),
                else => return raiseStep(frame, e),
            },
        }
    }
    // Read-modify-write: compute `cur.<op>(value)` and reassign the property.
    const combined: Value = blk: {
        if (cur == .Instance) {
            if (operatorMethod(cf.op)) |method| {
                switch (try host.callMember(allocator, &cur, method, &.{v})) {
                    .ok => |rv| break :blk rv,
                    .err => |e| return raiseStep(frame, e),
                }
            }
        }
        // A read-only collection combines through its binary operator intrinsic.
        switch (cur) {
            .List, .Set, .Map => {
                if (operatorMethod(cf.op)) |method| {
                    switch (try host.callMember(allocator, &cur, method, &.{v})) {
                        .ok => |rv| break :blk rv,
                        .err => |e| return raiseStep(frame, e),
                    }
                }
            },
            else => {},
        }
        switch (try applyBinop(allocator, cf.op, &cur, &v)) {
            .ok => |rv| break :blk rv,
            .err => |e| return raiseStep(frame, e),
        }
    };
    // `combined` is owned and `setField` retains its own copy, so drop ours to balance.
    const r = try host.setField(allocator, &recv, name, combined);
    combined.release(allocator);
    switch (r) {
        .ok => {},
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

/// Per-(site, class, argument signature) memo for a member site that sees more than one
/// receiver class; the dispatch generation is in the key, so a flush drops every entry.
const CALL_PIC_SLOTS: usize = 1 << 14;

const CallPicEnt = struct { key: u64 = 0, fid: u32 = 0 };

threadlocal var call_pic: [CALL_PIC_SLOTS]CallPicEnt = @splat(.{});

inline fn callPicKey(site: usize, cls: u64, sig: u64, gen: u64) u64 {
    var k = (@as(u64, site) *% 0x9E3779B97F4A7C15) ^ (cls *% 0xC2B2AE3D27D4EB4F);
    k ^= sig *% 0xD6E8FEB86659FD93;
    k ^= gen *% 0x517CC1B727220A95;
    return k | 1;
}

fn callPicGet(site: usize, cls: u64, sig: u64, gen: u64) ?u32 {
    const key = callPicKey(site, cls, sig, gen);
    const e = &call_pic[@as(usize, @intCast(key >> 17)) & (CALL_PIC_SLOTS - 1)];
    if (e.key != key) return null;
    return e.fid;
}

fn callPicPut(site: usize, cls: u64, sig: u64, gen: u64, fid: u32) void {
    const key = callPicKey(site, cls, sig, gen);
    const e = &call_pic[@as(usize, @intCast(key >> 17)) & (CALL_PIC_SLOTS - 1)];
    e.key = key;
    e.fid = fid;
}

fn tryLeafMember(comptime H: type, allocator: Allocator, frame: *Frame, recv: Value, fid: ir.FuncId, args: []const Value, host: *H) Allocator.Error!?LeafOutcome {
    if (recv == .Null) return null;
    const lf = frame.module.funcById(fid) orelse return null;
    if (args.len + 1 > 8) return null;
    var all: [8]Value = undefined;
    all[0] = recv;
    for (args, 0..) |a, i| all[i + 1] = a;
    return tryLeafValues(H, allocator, frame.module, lf, all[0 .. args.len + 1], host, null);
}

noinline fn execArmCallMember(comptime H: type, allocator: Allocator, frame: *Frame, cm: anytype, host: *H) Allocator.Error!Step {
    const cm_t0 = gfNow();
    defer if (parent.frame_count_on) {
        parent.cm_calls += 1;
    };
    const recv = frame.read(cm.receiver);
    if (cmTraceWant()) |w0| {
        const want = w0;
        if (constStr(frame.module, cm.name)) |nm| {
            if (std.mem.eql(u8, nm, want)) {
                const chain = ev_state.evtls.active_chain;
                const drecv_tn: []const u8 = if (cm.dispatch_receiver) |reg| blk: {
                    const dv = frame.read(reg);
                    if (dv == .Instance) {
                        const g = dv.Instance.borrow();
                        const cg = g.get().class.borrow();
                        const n = cg.get().name;
                        cg.deinit();
                        g.deinit();
                        break :blk n;
                    }
                    break :blk @tagName(dv);
                } else "-";
                std.debug.print("[cmarm] name={s} in={s} resolved={} dispatch={s} chain_len={d} chain_base={d}\n", .{
                    nm,
                    frame.func.name,
                    cm.resolved != null,
                    drecv_tn,
                    if (chain) |c| c.items.len else 0,
                    ev_state.evtls.active_chain_base,
                });
                if (chain) |c| {
                    for (c.items, 0..) |e, i| {
                        const tn: []const u8 = if (e.v == .Instance) blk: {
                            const g = e.v.Instance.borrow();
                            const cg = g.get().class.borrow();
                            const n = cg.get().name;
                            cg.deinit();
                            g.deinit();
                            break :blk n;
                        } else @tagName(e.v);
                        std.debug.print("[cmarm]   [{d}] kind={s} {s}\n", .{ i, @tagName(e.kind), tn });
                    }
                }
            }
        }
    }
    // Complete lowering evidence selected this declaration: execute that identity before any
    // representation fast path. An invalid one is a link error, never licence to re-resolve.
    if (cm.resolved) |fid| {
        dispatchBump(.call_member_resolved);
        if (comptime @hasDecl(H, "invokeResolvedMember")) {
            recv.retain();
            defer recv.release(allocator);
            var dispatch_recv: ?Value = if (cm.dispatch_receiver) |reg|
                frame.read(reg)
            else
                null;
            if (dispatch_recv) |value| value.retain();
            defer if (dispatch_recv) |value| value.release(allocator);
            const ra = try readArgRun(allocator, frame, cm.args, cm.n_args);
            defer allocator.free(ra);
            // Scalar-replay leaf: the receiver rides as param 0 (opaque genre when non-scalar);
            // a bail falls through to the ordinary invokers, which re-run the pure body exactly.
            if (argNamesAllNull(cm.arg_names) and ra.len + 1 <= 8 and
                cm.dispatch_receiver == null and recv != .Null) leaf: {
                const lf = frame.module.funcById(fid) orelse break :leaf;
                var all: [8]Value = undefined;
                all[0] = recv;
                for (ra, 0..) |a, i| all[i + 1] = a;
                if (try tryLeafValues(H, allocator, frame.module, lf, all[0 .. ra.len + 1], host, null)) |lo| switch (lo) {
                    .val => |v| {
                        try frame.write(cm.dst, v);
                        return .cont;
                    },
                    .raise => |e| return raiseStep(frame, e),
                };
            }
            // A resolved plain member at the fully-applied no-vararg shape runs as a pushed activation;
            // member extensions and every padded or vararg shape keep the recursive invoker.
            if (comptime @hasDecl(H, "prepareResolvedFlatCall")) {
                if (flatEnabled() and vcallFlatEnabled() and argNamesAllNull(cm.arg_names)) {
                    if (try host.prepareResolvedFlatCall(allocator, &recv, fid, ra)) |prep0| {
                        dispatchBump(.resolved_flat_prepare);
                        var prep = prep0;
                        prep.dst = cm.dst;
                        frame.flat_call = prep;
                        return .flat_call;
                    }
                }
            }
            const dispatch_ptr: ?*const Value = if (dispatch_recv) |*value|
                value
            else
                null;
            const names_resolved = try resolveArgNames(allocator, frame.module, cm.arg_names);
            defer allocator.free(names_resolved);
            switch (try host.invokeResolvedMember(
                allocator,
                dispatch_ptr,
                &recv,
                fid,
                ra,
                names_resolved,
            )) {
                .ok => |rv| {
                    try frame.write(cm.dst, rv);
                    return .cont;
                },
                .err => |e| return raiseStep(frame, e),
            }
        }
        return raiseStep(frame, .{ .Type = "resolved member calls are unsupported by this host" });
    }
    dispatchBump(.call_member_virtual);
    if (fastSubscript(allocator, frame, cm)) |rv| {
        dispatchBump(.member_fast_subscript);
        try frame.write(cm.dst, rv);
        return .cont;
    }
    if (primitiveMemberFast(frame, cm)) |rv| {
        dispatchBump(.member_prim_op);
        try frame.write(cm.dst, rv);
        return .cont;
    }
    if (recv == .RangeIter) {
        if (constStr(frame.module, cm.name)) |nm| {
            if (rangeIterFast(allocator, &recv, nm, cm.n_args)) |r| {
                dispatchBump(.member_range_iter);
                switch (r) {
                    .ok => |rv| {
                        try frame.write(cm.dst, rv);
                        return .cont;
                    },
                    .err => |e| return raiseStep(frame, e),
                }
            }
        }
    }
    // Pin the receiver across the dispatch: the register read is only a borrow, and the
    // callee may drop every other reference (a job completing inside `joinBlocking`).
    recv.retain();
    defer recv.release(allocator);
    const name_str = constStr(frame.module, cm.name) orelse
        return raiseStep(frame, .{ .Type = "CallMember: name not a string const" });
    runtime.prof.opRoute(0);
    const cm_args_t0 = gfNow();
    const arg_values = try readArgRun(allocator, frame, cm.args, cm.n_args);
    if (parent.frame_count_on) parent.cm_args_ns +%= gfNow() -% cm_args_t0;
    defer allocator.free(arg_values);
    const names = try resolveArgNames(allocator, frame.module, cm.arg_names);
    defer freeArgNames(allocator, names);
    // Keep the caller's instance `this` reachable while the dispatch resolves (the
    // member-extension visibility filter consults the chain); the entry is access-only.
    var pushed_enclosing = false;
    if (frame.params.items.len > 0 and frame.params.items[0] == .Instance) {
        const pi = frame.params.items[0].Instance;
        const same = recv == .Instance and ObjRef(InstanceData).ptrEq(pi, recv.Instance);
        if (!same) {
            pushEnclosingAccess(&frame.params.items[0]);
            pushed_enclosing = true;
        }
    }
    const static_recv: ?[]const u8 = if (cm.static_recv) |sid| constStr(frame.module, sid) else null;
    const declared_recv: ?[]const u8 = if (cm.declared_recv) |did| constStr(frame.module, did) else null;
    // Site memo replay: the claimed (class, arg-signature) pair serves its recorded target.
    // The signature is the same strict fold the method cache keys under, so no overload slips.
    if (parent.frame_count_on) parent.cm_pre_ns +%= gfNow() -% cm_t0;
    if (comptime @hasDecl(H, "memberSiteSig") and @hasDecl(H, "prepareMemberFlatFromFid")) {
        if (flatEnabled() and memberSiteEnabled() and recv == .Instance and argNamesAllNull(cm.arg_names)) {
            const w0 = @atomicLoad(u64, @constCast(&cm.site_cls), .acquire);
            if (w0 > 1) site: {
                const cls_now: u64 = @intCast(runtime.InstanceData.classIdentityUnlocked(recv.Instance));
                if (w0 != cls_now) {
                    const gen: u64 = if (comptime @hasDecl(H, "dispatchCacheGen")) H.dispatchCacheGen() else 0;
                    const sig_p = host.memberSiteSig(arg_values) orelse break :site;
                    const fid_p = callPicGet(@intFromPtr(cm), cls_now, sig_p, gen) orelse break :site;
                    if (try tryLeafMember(H, allocator, frame, recv, @enumFromInt(fid_p), arg_values, host)) |lo| switch (lo) {
                        .val => |v| {
                            if (pushed_enclosing) popEnclosing();
                            try frame.write(cm.dst, v);
                            return .cont;
                        },
                        .raise => |e| {
                            if (pushed_enclosing) popEnclosing();
                            return raiseStep(frame, e);
                        },
                    };
                    if (try host.prepareMemberFlatFromFid(allocator, &recv, name_str, arg_values, @enumFromInt(fid_p))) |prep0| {
                        dispatchBump(.member_site_flat);
                        var prep = prep0;
                        prep.dst = cm.dst;
                        prep.pop_enclosing_n = if (pushed_enclosing) 1 else 0;
                        frame.flat_call = prep;
                        return .flat_call;
                    }
                    break :site;
                }
                const route = @atomicLoad(u64, @constCast(&cm.site_route), .acquire);
                if (route == 0) break :site;
                const sig_now = host.memberSiteSig(arg_values) orelse break :site;
                if (sig_now != @atomicLoad(u64, @constCast(&cm.site_sig), .monotonic)) break :site;
                // Route bit0 = 1 carries a flat-call FuncId; bit0 = 0 carries a
                // host-serve kind that answers without any call machinery.
                if (route & 1 == 0) {
                    if (comptime @hasDecl(H, "hostMemberServeKind")) {
                        if (try host.hostMemberServeKind(allocator, @intCast(route >> 1), &recv, arg_values)) |served| {
                            dispatchBump(.member_site_flat);
                            if (pushed_enclosing) popEnclosing();
                            try frame.write(cm.dst, served);
                            return .cont;
                        }
                    }
                    break :site;
                }
                if (try tryLeafMember(H, allocator, frame, recv, @enumFromInt(@as(u32, @intCast(route >> 1))), arg_values, host)) |lo| switch (lo) {
                    .val => |v| {
                        if (pushed_enclosing) popEnclosing();
                        try frame.write(cm.dst, v);
                        return .cont;
                    },
                    .raise => |e| {
                        if (pushed_enclosing) popEnclosing();
                        return raiseStep(frame, e);
                    },
                };
                if (try host.prepareMemberFlatFromFid(allocator, &recv, name_str, arg_values, @enumFromInt(@as(u32, @intCast(route >> 1))))) |prep0| {
                    dispatchBump(.member_site_flat);
                    var prep = prep0;
                    prep.dst = cm.dst;
                    prep.pop_enclosing_n = if (pushed_enclosing) 1 else 0;
                    frame.flat_call = prep;
                    return .flat_call;
                }
            }
        }
    }
    // Flat member dispatch: a resolved method or cached top-level extension at the
    // fully-applied no-vararg shape runs as a pushed activation; the rest fall to the ladder.
    if (comptime @hasDecl(H, "prepareMemberFlatCall")) {
        if (flatEnabled()) {
            runtime.prof.opRoute(1);
            const cm_prep_t0 = gfNow();
            defer if (parent.frame_count_on) {
                parent.cm_prep_ns +%= gfNow() -% cm_prep_t0;
            };
            const prep_opt: ?FlatCallReq = if (argNamesAllNull(cm.arg_names))
                try host.prepareMemberFlatCall(allocator, &recv, name_str, arg_values, static_recv, declared_recv, true)
            else if (comptime @hasDecl(H, "prepareMemberFlatCallNamed"))
                // A NAMED call whose binding permutation is known replays into declaration order.
                try host.prepareMemberFlatCallNamed(allocator, &recv, name_str, arg_values, names, static_recv, declared_recv)
            else
                null;
            if (prep_opt) |prep0| {
                dispatchBump(.member_flat_prepare);
                var prep = prep0;
                prep.dst = cm.dst;
                prep.pop_enclosing_n = if (pushed_enclosing) 1 else 0;
                // Claim the site memo for the resolved target, keyed by receiver class and strict
                // argument signature, once resolution is stable and only for the positional form.
                if (comptime @hasDecl(H, "memberSiteSig")) {
                    if (memberSiteEnabled() and recv == .Instance and argNamesAllNull(cm.arg_names) and
                        dispatchCacheStable())
                    {
                        if (host.memberSiteSig(arg_values)) |sig| {
                            const cls: u64 = @intCast(runtime.InstanceData.classIdentityUnlocked(recv.Instance));
                            if (cls > 1 and @cmpxchgStrong(u64, @constCast(&cm.site_cls), 0, cls, .acq_rel, .monotonic) == null) {
                                @atomicStore(u64, @constCast(&cm.site_sig), sig, .monotonic);
                                @atomicStore(u64, @constCast(&cm.site_route), (@as(u64, prep.func.id.int()) << 1) | 1, .release);
                            } else if (cls > 1) {
                                // The site is claimed by another class; memo this one.
                                const gen: u64 = if (comptime @hasDecl(H, "dispatchCacheGen")) H.dispatchCacheGen() else 0;
                                callPicPut(@intFromPtr(cm), cls, sig, gen, prep.func.id.int());
                            }
                        }
                    }
                }
                frame.flat_call = prep;
                runtime.prof.opRoute(5);
                return .flat_call;
            }
        }
    }
    // Host member serves answer ahead of the ladder entry and claim the site with a
    // host-kind route, so later executions skip the flat-prepare decline walk.
    if (comptime @hasDecl(H, "hostMemberServeProbe")) {
        if (recv == .Instance and argNamesAllNull(cm.arg_names)) {
            if (try host.hostMemberServeProbe(allocator, &recv, name_str, arg_values)) |hit| {
                if (comptime @hasDecl(H, "memberSiteSig")) {
                    if (memberSiteEnabled() and dispatchCacheStable() and
                        @atomicLoad(u64, @constCast(&cm.site_cls), .monotonic) == 0)
                    {
                        if (host.memberSiteSig(arg_values)) |sig| {
                            const cls: u64 = blk: {
                                const g = recv.Instance.borrow();
                                defer g.deinit();
                                break :blk @intCast(g.get().class.identity());
                            };
                            if (cls > 1 and @cmpxchgStrong(u64, @constCast(&cm.site_cls), 0, cls, .acq_rel, .monotonic) == null) {
                                @atomicStore(u64, @constCast(&cm.site_sig), sig, .monotonic);
                                @atomicStore(u64, @constCast(&cm.site_route), @as(u64, hit.kind) << 1, .release);
                            }
                        }
                    }
                }
                if (pushed_enclosing) popEnclosing();
                try frame.write(cm.dst, hit.val);
                return .cont;
            }
        }
    }
    dispatchBump(.member_ladder);
    ladderStatsBump(&recv, name_str, frame.func.name);
    runtime.prof.opRoute(2);
    const prev_tl = if (cm.trailing_lambda and comptime @hasDecl(H, "setTrailingMemberCall"))
        H.setTrailingMemberCall(true)
    else
        false;
    const tl_touched = cm.trailing_lambda;
    const res = if (static_recv) |sname|
        host.callMemberNamedStatic(allocator, &recv, name_str, arg_values, names, sname)
    else if (declared_recv != null)
        host.callMemberNamedDeclared(allocator, &recv, name_str, arg_values, names, declared_recv)
    else
        host.callMemberNamed(allocator, &recv, name_str, arg_values, names);
    if (tl_touched) {
        if (comptime @hasDecl(H, "setTrailingMemberCall")) _ = H.setTrailingMemberCall(prev_tl);
    }
    if (pushed_enclosing) popEnclosing();
    switch (try res) {
        .ok => |rv| try frame.write(cm.dst, rv),
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

/// `LoadGlobal` semantics with no frame coupling: the framed arm and the fused tier both
/// call this. The result is RETAINED for the caller's register.
pub fn loadGlobalValue(comptime H: type, allocator: Allocator, module: *const Module, lg: anytype, host: *H) Allocator.Error!EvalResult {
    {
            const name_str = constStr(module, lg.name) orelse
                return errResult(.{ .Type = "LoadGlobal: name not a string const" });
            // A lowering-resolved identity binds that exact declaration; the name is the fallback.
            const by_id: ?Value = if (lg.func != null or lg.class != null)
                host.lookupGlobalById(allocator, lg.func, lg.class, lg.ctor_ref)
            else
                null;
            const lg_r: MaybeValueResult = if (by_id != null) .{ .ok = by_id } else try host.lookupGlobalThrowing(allocator, name_str);
            const found = switch (lg_r) {
                .ok => |maybe| maybe,
                .err => |e| return errResult(e),
            };
            // No receiver probe: `LoadGlobal` is emitted only where no implicit receiver can shadow
            // the name, and Kotlin rejects resolving it against a caller's receiver.
            var v: Value = undefined;
            if (found) |fv| {
                v = fv;
            } else if (comptime @hasDecl(H, "callFunc")) {
                // A top-level `val`/`var` with only a custom getter has no binding; re-run its getter.
                if (module.registry.top_level_prop_getters.get(name_str)) |getter_fid| {
                    switch (try host.callFunc(allocator, module, getter_fid, &.{})) {
                        .ok => |gv| {
                            return ok(gv);
                        },
                        .err => |e| return errResult(e),
                    }
                }
                // A qualified companion member the lowering flattened to one global name (`pkg.X.Y`) has
                // no global binding: split at the last dot and read the member off the owner class value.
                if (std.mem.findScalarLast(u8, name_str, '.')) |dot| {
                    if (dot != 0 and dot + 1 < name_str.len) {
                        const owner_v: ?Value = switch (try host.lookupGlobalThrowing(allocator, name_str[0..dot])) {
                            .ok => |maybe| maybe,
                            .err => null,
                        };
                        if (owner_v) |ov| {
                            if (ov == .Class or ov == .Instance) {
                                switch (try host.getField(allocator, &ov, name_str[dot + 1 ..])) {
                                    .ok => |fv| {
                                        fv.retain();
                                        return ok(fv);
                                    },
                                    .err => {},
                                }
                            }
                        }
                    }
                }
                // A `$lc<fn>`-mangled local class name (`Local$lcmain`) is how lowering names a local
                // class; the runtime registers it under the simple declared name.
                if (std.mem.find(u8, name_str, "$lc")) |lci| {
                    const simple = name_str[0..lci];
                    if (simple.len != 0) {
                        switch (try host.lookupGlobalThrowing(allocator, simple)) {
                            .ok => |maybe| if (maybe) |lv| return ok(lv),
                            .err => {},
                        }
                    }
                }
                if (envVarSet("KLIO_UNRESOLVED_TRACE")) {
                    std.debug.print("[unresolved] `{s}`\n", .{name_str});
                }
                const msg = try std.fmt.allocPrint(allocator, "unresolved global `{s}`", .{name_str});
                if (missTraceWant()) |w| {
                    if (std.mem.eql(u8, w, name_str)) std.debug.print("[lg-tail-a] name={s}\n", .{name_str});
                }
                dumpFrameChainForDiag();
                return errResult(.{ .Unbound = msg });
            } else {
                const msg = try std.fmt.allocPrint(allocator, "unresolved global `{s}`", .{name_str});
                if (missTraceWant()) |w| {
                    if (std.mem.eql(u8, w, name_str)) std.debug.print("[lg-tail-b] name={s} func={?} class={?}\n", .{ name_str, if (lg.func) |f| f.int() else null, if (lg.class) |c| c.int() else null });
                }
                dumpFrameChainForDiag();
                return errResult(.{ .Unbound = msg });
            }
            v.retain();
            return ok(v);
    }
}
