//! Stage-3 JIT: compile a hot natural loop to native x86-64 machine code.
//!
//! Additive tier over the IR interpreter (see docs/design/JIT-DESIGN.md). The loop's
//! IR registers live as i64 slots in a scratch file; the emitted code uses
//! rax/rcx/rdx/rsi scratch per op (no register allocator) and runs the loop
//! natively, eliminating Value boxing, member dispatch, and per-instruction
//! interpreter overhead. Packed primitive arrays are indexed directly out of
//! their scalar buffer (the F5 representation), with a bounds-check that deopts
//! to the interpreter at the faulting instruction on out-of-range access.
//!
//! Gated behind `KLIO_JIT` and entered only when the live-in registers' runtime
//! types (and indexed-array kinds) match the compiled specialization; otherwise
//! the interpreter runs the loop unchanged. So the build stays correct with the
//! JIT off (default) or on.

const std = @import("std");
const ir = @import("ir.zig");

const Module = ir.Module;
const Inst = ir.Inst;
const Reg = ir.Reg;
const FuncId = ir.FuncId;

const common = @import("jit_loop/common.zig");
const shapes = @import("jit_loop/shapes.zig");
const inline_analysis = @import("jit_loop/inline_analysis.zig");
const type_infer = @import("jit_loop/types.zig");
const loop_shape = @import("jit_loop/loop_shape.zig");
const compiler = @import("jit_loop/compiler.zig");
const compile_loop = @import("jit_loop/compile_loop.zig");
const run_mod = @import("jit_loop/run.zig");
const code_cache = @import("jit_loop/cache.zig");
const compile_func = @import("jit_loop/compile_func.zig");

pub const RegType = common.RegType;
pub const encodeResumePub = common.encodeResumePub;
pub const THROW_INST = common.THROW_INST;
pub const throwCode = common.throwCode;
pub const DEOPT_INST = common.DEOPT_INST;
pub const deoptCode = common.deoptCode;
pub const RETURN_INST = common.RETURN_INST;
pub const returnCode = common.returnCode;
pub const TrampCtx = common.TrampCtx;
pub const TrampFn = common.TrampFn;
pub const CallSite = common.CallSite;
pub const ArrayUnbox = common.ArrayUnbox;
pub const CellUnbox = common.CellUnbox;
pub const NullableUnbox = common.NullableUnbox;
pub const ObjParamLoad = common.ObjParamLoad;
pub const MethodFieldCheck = common.MethodFieldCheck;
pub const MemberIC = common.MemberIC;
pub const memberICKey = common.memberICKey;
pub const FieldBase = common.FieldBase;
pub const CompiledLoop = common.CompiledLoop;
pub const DirectSite = common.DirectSite;

pub const MemberResolver = shapes.MemberResolver;
pub const VirtResolver = shapes.VirtResolver;
pub const FieldResolver = shapes.FieldResolver;
const trampolinableGlobalOf = shapes.trampolinableGlobalOf;
const trampolinableMemberOf = shapes.trampolinableMemberOf;

pub const liveElementAt = type_infer.liveElementAt;
pub const instanceClassIdentity = type_infer.instanceClassIdentity;

pub const tryCompile = compile_loop.tryCompile;

pub const Resume = run_mod.Resume;
pub const RunResult = run_mod.RunResult;
pub const reseedArrays = run_mod.reseedArrays;
pub const runLoop = run_mod.runLoop;
pub const cellSlotIn = run_mod.cellSlotIn;
pub const valueFromSlot = run_mod.valueFromSlot;
pub const INT_TAG = run_mod.INT_TAG;
pub const valueFromSlotTagged = run_mod.valueFromSlotTagged;
pub const FuncOutcome = run_mod.FuncOutcome;
pub const runFunc = run_mod.runFunc;

pub const FUSED_YIELD_BACK_EDGES = code_cache.FUSED_YIELD_BACK_EDGES;
pub const FuncJit = code_cache.FuncJit;
pub const setEnabledForTest = code_cache.setEnabledForTest;
pub const enabled = code_cache.enabled;
pub const debugEnabled = code_cache.debugEnabled;
pub const funcEnabled = code_cache.funcEnabled;
pub const setFuncEnabledForTest = code_cache.setFuncEnabledForTest;
pub const evictIfOverBudget = code_cache.evictIfOverBudget;
pub const compiledFunc = code_cache.compiledFunc;
pub const resetForTest = code_cache.resetForTest;
pub const forFunc = code_cache.forFunc;
pub const SeamProbe = code_cache.SeamProbe;
pub const methodSeamPeek = code_cache.methodSeamPeek;
pub const methodSeamProbe = code_cache.methodSeamProbe;
pub const methodSeamCompile = code_cache.methodSeamCompile;
pub const fusedShouldYieldToFuncTier = code_cache.fusedShouldYieldToFuncTier;
pub const compileCalleeForCall = code_cache.compileCalleeForCall;
pub const maybeRunHotFunc = code_cache.maybeRunHotFunc;
pub const loopDeclined = code_cache.loopDeclined;
pub const compileHotLoopFor = code_cache.compileHotLoopFor;
pub const streamBackEdge = code_cache.streamBackEdge;
pub const maybeRunHot = code_cache.maybeRunHot;
pub const maybeRunHotPre = code_cache.maybeRunHotPre;
const metadata_allocator = code_cache.metadata_allocator;

pub const tryCompileFunc = compile_func.tryCompileFunc;

test "JIT metadata uses packed storage and resets pointer-keyed caches" {
    const testing = std.testing;
    try testing.expect(metadata_allocator.vtable != std.heap.page_allocator.vtable);
    try type_infer.ret_type_cache.put(metadata_allocator, 1, .i32);
    resetForTest();
    try testing.expectEqual(@as(usize, 0), type_infer.ret_type_cache.count());
}

test "loop JIT recognizes a boxed global read trampoline" {
    const testing = std.testing;
    var module = Module.init(testing.allocator);
    defer module.deinit(testing.allocator);
    const name = try module.internConst(testing.allocator, .{ .String = "pkg.SINGLETON" });
    const inst = Inst{ .LoadGlobal = .{ .dst = Reg.from(3), .name = name } };
    const global = trampolinableGlobalOf(&module, &inst).?;
    try testing.expectEqual(@as(u32, 3), global.dst.int());
    try testing.expectEqualStrings("pkg.SINGLETON", global.name);
}

test "loop JIT preserves exact member-extension operands" {
    const testing = std.testing;
    var module = Module.init(testing.allocator);
    defer module.deinit(testing.allocator);
    const name = try module.internConst(testing.allocator, .{ .String = "pick" });
    const inst = Inst{ .CallMember = .{
        .dst = Reg.from(8),
        .receiver = Reg.from(3),
        .name = name,
        .args = Reg.from(4),
        .n_args = 1,
        .resolved = FuncId.from(17),
        .dispatch_receiver = Reg.from(2),
    } };
    const member = trampolinableMemberOf(&module, &inst).?;
    try testing.expectEqual(FuncId.from(17), member.resolved.?);
    try testing.expectEqual(Reg.from(2), member.dispatch_recv.?);
    try testing.expectEqual(Reg.from(3), member.recv);
    try testing.expectEqual(@as(u32, 4), member.args_reg);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(@import("jit_loop/cache.zig"));
    std.testing.refAllDecls(@import("jit_loop/common.zig"));
    std.testing.refAllDecls(@import("jit_loop/compile_func.zig"));
    std.testing.refAllDecls(@import("jit_loop/compile_loop.zig"));
    std.testing.refAllDecls(@import("jit_loop/compiler.zig"));
    std.testing.refAllDecls(@import("jit_loop/inline_analysis.zig"));
    std.testing.refAllDecls(@import("jit_loop/loop_shape.zig"));
    std.testing.refAllDecls(@import("jit_loop/run.zig"));
    std.testing.refAllDecls(@import("jit_loop/shapes.zig"));
    std.testing.refAllDecls(@import("jit_loop/types.zig"));
}
