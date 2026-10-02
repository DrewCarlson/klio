//! Instruction handlers: the outlined `execInst` arms, the binary-operator
//! semantics, the field routes, and member-call dispatch.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");
const span = @import("span");

const Allocator = std.mem.Allocator;

const Value = runtime.Value;

const BinOp = ir.BinOp;
const Const = ir.Const;
const Inst = ir.Inst;
const UnOp = ir.UnOp;


const constStr = ev_values.constStr;

const parent = @import("../eval.zig");
const ev_diag = @import("diag.zig");
const ev_flow = @import("flow.zig");
const ev_frame = @import("frame.zig");
const ev_resolved = @import("resolved.zig");
const ev_values = @import("values.zig");

const EvalResult = ev_flow.EvalResult;
const Frame = ev_frame.Frame;
const Step = ev_flow.Step;
const applyBinop = ev_values.applyBinop;
const applyUnop = ev_values.applyUnop;
const constToValue = ev_values.constToValue;
const dumpCurrentFrameParamsForDiag = ev_diag.dumpCurrentFrameParamsForDiag;
const dumpFrameChainForDiagAlways = ev_diag.dumpFrameChainForDiagAlways;
const errResult = ev_flow.errResult;
const lateinitThrow = ev_flow.lateinitThrow;
const ok = ev_flow.ok;
const raiseStep = ev_flow.raiseStep;
const renderValue = ev_values.renderValue;

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
            // Sema lowers a declared `operator fun not()` as a call: the operand is a Boolean.
            const v = frame.read(n.src);
            const b = switch (v) {
                .Bool => |bv| !bv,
                else => {
                    if (runtime.envOnce("KLIO_ERR_TRACE") != null) {
                        std.debug.print("[not-miss] in={s} kind={s} span={?any}\n", .{
                            frame.func.name, @tagName(std.meta.activeTag(v)), frame.span(),
                        });
                        dumpCurrentFrameParamsForDiag();
                        dumpFrameChainForDiagAlways();
                    }
                    return raiseStep(frame, .{ .Type = "Not on non-bool" });
                },
            };
            try frame.write(n.dst, .{ .Bool = b });
        },
        .UnOp => |u| return execArmUnOp(allocator, frame, u),
        .BinOp => |bo| return execArmBinOp(H, allocator, frame, bo, host),
        // A stream runs no Trace: `Frame.span` reads the block's Traces before the instruction.
        .Trace => {},
        .LoadParam => |lp| {
            const v = if (lp.idx < frame.params.len) frame.params[lp.idx] else Value.Unit;
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
        .IterOpen => |x| return ev_resolved.execIterOpen(frame, x),
        .IterHas => |x| return ev_resolved.execIterHas(allocator, frame, x),
        .IterGet => |x| return ev_resolved.execIterGet(H, allocator, frame, x, host),
        .NewArray => |x| return ev_resolved.execNewArray(H, allocator, frame, x, host),
        .BoxValue => |x| return ev_resolved.execBoxValue(allocator, frame, x),
        .UnboxValue => |x| return ev_resolved.execUnboxValue(H, allocator, frame, x),
        .LoadCapture => |lc| {
            const v = if (lc.idx < frame.captures.len) frame.captures[lc.idx] else Value.Unit;
            v.retain();
            try frame.write(lc.dst, v);
        },
    }
    return .cont;
}

pub noinline fn execArmCellSet(comptime H: type, allocator: Allocator, frame: *Frame, cs: anytype, host: *H) Allocator.Error!Step {
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

/// A unary operator on a primitive. Sema lowers an operator a class or an
/// extension declares as a call, so the operand here is always a number or a
/// char.
noinline fn execArmUnOp(allocator: Allocator, frame: *Frame, u: anytype) Allocator.Error!Step {
    const v = frame.read(u.operand);
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

/// Binary-operator semantics with no frame coupling: the framed arm and the
/// tier and the host's operator natives share it. Sema emits a `BinOp` over
/// primitives and strings, `===` over anything, and a primitive's `equals`
/// against any value; an operator a class or an extension declares is a call.
/// Equality where either side is neither a primitive nor a string asks the
/// host, which dispatches the value's own `equals`.
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
    switch (bo.op) {
        .StringConcat => {
            if (try ev_values.concatInPlace(allocator, &l, &r)) |s| return ok(.{ .String = s });
            const ls = try renderValue(allocator, &l);
            const rs = try renderValue(allocator, &r);
            const combined = try std.mem.concat(allocator, u8, &.{ ls, rs });
            // `ls`/`rs` are owned renderings; `combined` is adopted by the StringRef cell.
            if (runtime.freeScratch()) {
                allocator.free(ls);
                allocator.free(rs);
            }
            return ok(.{ .String = try runtime.strInitOwned(allocator, combined) });
        },
        // `===`/`!==` is pointer identity, never a user `equals` dispatch.
        .IdentEq, .IdentNeq => {
            const same = Value.referenceEq(&l, &r);
            return ok(.{ .Bool = if (bo.op == .IdentNeq) !same else same });
        },
        .Eq, .NotEq, .BoxedEq, .BoxedNotEq => {
            const neg = bo.op == .NotEq or bo.op == .BoxedNotEq;
            // `x == null` compares against the null literal by identity.
            if (l == .Null or r == .Null) return ok(.{ .Bool = (l == .Null and r == .Null) != neg });
            if (!plainEqualityOperand(&l) or !plainEqualityOperand(&r)) {
                if (comptime @hasDecl(H, "deepValueEquals")) {
                    return ok(.{ .Bool = (try host.deepValueEquals(allocator, &l, &r)) != neg });
                }
            }
        },
        else => {},
    }
    switch (try applyBinop(allocator, bo.op, &l, &r)) {
        .ok => |out| return ok(out),
        .err => |e| return errResult(e),
    }
}

/// A value whose equality needs no dispatch: a number, a character, a
/// boolean, a string or the suspension marker.
fn plainEqualityOperand(v: *const Value) bool {
    return switch (v.*) {
        .Int, .Long, .Short, .Byte, .UInt, .ULong, .UShort, .UByte, .Double, .Float, .Char, .Bool, .String, .CoroutineSuspended, .Unit => true,
        else => false,
    };
}
