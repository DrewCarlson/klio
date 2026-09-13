//! IR evaluator tests.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");

const Allocator = std.mem.Allocator;

const Value = runtime.Value;

const BinOp = ir.BinOp;
const Const = ir.Const;
const Func = ir.Func;
const Inst = ir.Inst;
const Module = ir.Module;
const Reg = ir.Reg;
const testing = std.testing;

const ev_activation = @import("activation.zig");
const ev_chain = @import("chain.zig");
const ev_enter = @import("enter.zig");
const ev_flow = @import("flow.zig");
const ev_host = @import("host.zig");
const ev_snapshot = @import("snapshot.zig");
const ev_state = @import("state.zig");

const EnclosingEntry = ev_state.EnclosingEntry;
const NullHost = ev_host.NullHost;
const SuspendState = ev_snapshot.SuspendState;
const TryFrame = ev_snapshot.TryFrame;
const chainAllocator = ev_chain.chainAllocator;
const enclosingEntriesAlloc = ev_chain.enclosingEntriesAlloc;
const enclosingThisChainAlloc = ev_chain.enclosingThisChainAlloc;
const enclosingThisLast = ev_chain.enclosingThisLast;
const eval = ev_enter.eval;
const nullHost = ev_host.nullHost;
const ok = ev_flow.ok;
const popEnclosing = ev_chain.popEnclosing;
const pushEnclosing = ev_chain.pushEnclosing;
const pushEnclosingSubject = ev_chain.pushEnclosingSubject;
const resetSuspendLivenessCache = ev_snapshot.resetSuspendLivenessCache;
const resumeContinuation = ev_activation.resumeContinuation;
const suspendLiveRegs = ev_snapshot.suspendLiveRegs;

const FuncBuilder = ir.build.FuncBuilder;

fn freeFunc(func: Func) void {
    for (func.blocks) |b| {
        if (b.insts.len != 0) testing.allocator.free(b.insts);
        if (b.catches.len != 0) testing.allocator.free(b.catches);
    }
    testing.allocator.free(func.blocks);
    if (func.capture_order.len != 0) testing.allocator.free(func.capture_order);
}

fn lit(b: *FuncBuilder, v: i32) Allocator.Error!Reg {
    return b.emitConst(.{ .Int = v });
}

test "eval_int_const" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const r = try lit(&b, 7);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "test.f", ir.build.typeInt());
    defer freeFunc(func);
    const res = try eval(testing.allocator, &m, &func, .empty);
    try testing.expect(res == .ok);
    try testing.expect(res.ok == .Int and res.ok.Int == 7);
}

test "eval reports a bodyless function instead of indexing empty blocks" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const r = try lit(&b, 7);
    b.terminate(.{ .Return = r });
    var func = try b.finish("missing", "test.missing", ir.build.typeInt());
    const blocks = func.blocks;
    defer {
        func.blocks = blocks;
        freeFunc(func);
    }
    func.blocks = &.{};

    const result = try eval(testing.allocator, &m, &func, .empty);
    try testing.expect(result == .err);
    try testing.expect(result.err == .CalleeFailed);
    try testing.expectEqualStrings("virtual method target is not executable", result.err.CalleeFailed);
}

test "eval_int_add" {
    var module = Module.default(testing.allocator);
    defer module.deinit(testing.allocator);
    var builder = try FuncBuilder.init(testing.allocator, &module);
    defer builder.deinit();
    const lhs = try lit(&builder, 2);
    const rhs = try lit(&builder, 40);
    const dst = builder.allocReg();
    try builder.push(.{ .BinOp = .{ .dst = dst, .op = .Add, .lhs = lhs, .rhs = rhs } });
    builder.terminate(.{ .Return = dst });
    const func = try builder.finish("f", "test.f", ir.build.typeInt());
    defer freeFunc(func);
    const result = try eval(testing.allocator, &module, &func, .empty);
    try testing.expect(result == .ok);
    try testing.expect(result.ok == .Int and result.ok.Int == 42);
}

test "eval_load_param" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const p = b.allocReg();
    try b.push(.{ .LoadParam = .{ .dst = p, .idx = 0 } });
    b.terminate(.{ .Return = p });
    const func = try b.finish("f", "test.f", ir.build.typeInt());
    defer freeFunc(func);
    var args: std.ArrayList(Value) = .empty;
    try args.append(testing.allocator, .{ .Int = 99 });
    const v = try eval(testing.allocator, &m, &func, args);
    try testing.expect(v == .ok);
    try testing.expect(v.ok == .Int and v.ok.Int == 99);
}

test "eval_branch" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const cond = try b.emitConst(.{ .Bool = true });
    const t_blk = try b.allocBlock();
    const f_blk = try b.allocBlock();
    b.terminate(.{ .Branch = .{ .cond = cond, .t = t_blk, .f = f_blk } });

    b.switchTo(t_blk);
    const t_val = try lit(&b, 1);
    b.terminate(.{ .Return = t_val });

    b.switchTo(f_blk);
    const f_val = try lit(&b, 0);
    b.terminate(.{ .Return = f_val });

    const func = try b.finish("f", "test.f", ir.build.typeInt());
    defer freeFunc(func);
    const v = try eval(testing.allocator, &m, &func, .empty);
    try testing.expect(v == .ok);
    try testing.expect(v.ok == .Int and v.ok.Int == 1);
}

test "suspend liveness keeps only values read on reachable resume paths" {
    resetSuspendLivenessCache();
    defer resetSuspendLivenessCache();

    const entry_insts = [_]Inst{
        .{ .Const = .{ .dst = .from(0), .value = .from(0) } },
        .{ .Const = .{ .dst = .from(1), .value = .from(1) } },
        .{ .Move = .{ .dst = .from(2), .src = .from(0) } },
        .{ .Const = .{ .dst = .from(3), .value = .from(2) } },
    };
    const blocks = [_]ir.Block{
        .{
            .id = .from(0),
            .insts = @constCast(&entry_insts),
            .terminator = .{ .Branch = .{ .cond = .from(2), .t = .from(1), .f = .from(2) } },
        },
        .{ .id = .from(1), .insts = &.{}, .terminator = .{ .Return = .from(0) } },
        .{ .id = .from(2), .insts = &.{}, .terminator = .{ .Return = .from(1) } },
    };
    const func: Func = .{
        .id = .from(0),
        .name = "resumePaths",
        .fqn = "test.resumePaths",
        .params = &.{},
        .return_ty = .{ .name = "Int", .nullable = false, .args = &.{} },
        .n_locals = 4,
        .blocks = @constCast(&blocks),
        .entry = .from(0),
        .is_suspend = true,
    };

    // Before the move both branch results are live; the move's destination and the dead fourth register are not.
    const before_move = try suspendLiveRegs(&func, .from(0), 2);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, before_move);
    const before_term = try suspendLiveRegs(&func, .from(0), entry_insts.len);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, before_term);
}

test "resumed labeled return reaches its snapshotted target frame" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);

    const inner_blocks = [_]ir.Block{.{
        .id = .from(0),
        .insts = &.{},
        .terminator = .{ .LabeledReturn = .{
            .label = "hasNext",
            .value = .from(0),
        } },
    }};
    const outer_blocks = [_]ir.Block{.{
        .id = .from(0),
        .insts = &.{},
        .terminator = .{ .Return = .from(0) },
    }};
    try m.funcs.append(testing.allocator, .{
        .id = .from(0),
        .name = "<lambda>",
        .fqn = "test.hasNext.<lambda>",
        .params = &.{},
        .return_ty = ir.build.typeBool(),
        .n_locals = 1,
        .blocks = @constCast(&inner_blocks),
        .entry = .from(0),
        .is_suspend = false,
        .is_lambda = true,
    });
    try m.funcs.append(testing.allocator, .{
        .id = .from(1),
        .name = "hasNext",
        .fqn = "test.hasNext",
        .params = &.{},
        .return_ty = ir.build.typeBool(),
        .n_locals = 1,
        .blocks = @constCast(&outer_blocks),
        .entry = .from(0),
        .is_suspend = true,
    });

    var state = SuspendState{ .token = 1 };
    const inner_regs = try testing.allocator.dupe(Value, &.{.{ .Bool = true }});
    const outer_regs = try testing.allocator.dupe(Value, &.{Value.Unit});
    const inner_params = try testing.allocator.alloc(Value, 0);
    const inner_captures = try testing.allocator.alloc(Value, 0);
    const inner_enclosing = try testing.allocator.alloc(EnclosingEntry, 0);
    const inner_try = try testing.allocator.alloc(TryFrame, 0);
    const outer_params = try testing.allocator.alloc(Value, 0);
    const outer_captures = try testing.allocator.alloc(Value, 0);
    const outer_enclosing = try testing.allocator.alloc(EnclosingEntry, 0);
    const outer_try = try testing.allocator.alloc(TryFrame, 0);
    try state.frames.append(testing.allocator, .{
        .func = .from(0),
        .module = null,
        .block = .from(0),
        .inst_idx = 0,
        .regs = .{ .dense = inner_regs },
        .params = inner_params,
        .captures = inner_captures,
        .enclosing_this = inner_enclosing,
        .try_stack = inner_try,
        .is_lambda = true,
        .resume_reg = null,
    });
    try state.frames.append(testing.allocator, .{
        .func = .from(1),
        .module = null,
        .block = .from(0),
        .inst_idx = 0,
        .regs = .{ .dense = outer_regs },
        .params = outer_params,
        .captures = outer_captures,
        .enclosing_this = outer_enclosing,
        .try_stack = outer_try,
        .is_lambda = false,
        .resume_reg = .from(0),
    });

    var host = nullHost();
    const result = try resumeContinuation(
        NullHost,
        testing.allocator,
        &m,
        &state,
        Value.Unit,
        &host,
    );
    // `resumeContinuation` consumes the frame list; clear the moved handle.
    state.frames = .empty;
    try testing.expect(result == .ok);
    try testing.expect(result.ok == .Bool and result.ok.Bool);
}

test "enclosing chain tags subjects and projects innermost-first" {
    var chain: std.ArrayList(EnclosingEntry) = .empty;
    defer chain.deinit(chainAllocator());
    const prev = ev_state.evtls.active_chain;
    ev_state.evtls.active_chain = &chain;
    defer ev_state.evtls.active_chain = prev;

    const receiver = Value{ .Int = 1 };
    const subject = Value{ .Int = 2 };
    pushEnclosing(&receiver);
    pushEnclosingSubject(&subject);

    const vals = try enclosingThisChainAlloc(testing.allocator);
    defer testing.allocator.free(vals);
    try testing.expectEqual(@as(usize, 2), vals.len);
    try testing.expect(vals[0] == .Int and vals[0].Int == 2);
    try testing.expect(vals[1] == .Int and vals[1].Int == 1);
    try testing.expect(enclosingThisLast().? == .Int and enclosingThisLast().?.Int == 2);

    const entries = try enclosingEntriesAlloc(testing.allocator);
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expect(entries[0].isSubject() and entries[0].v.Int == 2);
    try testing.expect(!entries[1].isSubject() and entries[1].v.Int == 1);

    popEnclosing();
    const rest = try enclosingEntriesAlloc(testing.allocator);
    defer testing.allocator.free(rest);
    try testing.expectEqual(@as(usize, 1), rest.len);
    try testing.expect(!rest[0].isSubject() and rest[0].v.Int == 1);
    popEnclosing();
    try testing.expectEqual(@as(usize, 0), chain.items.len);
}

test "enclosing chain pushes are dropped with no active frame" {
    const prev = ev_state.evtls.active_chain;
    ev_state.evtls.active_chain = null;
    defer ev_state.evtls.active_chain = prev;

    const v = Value{ .Int = 7 };
    pushEnclosing(&v);
    pushEnclosingSubject(&v);
    popEnclosing();
    try testing.expect(enclosingThisLast() == null);
    const entries = try enclosingEntriesAlloc(testing.allocator);
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}
