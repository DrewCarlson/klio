//! The per-instruction body emitter: every block a label, every register a
//! typed C local.
const std = @import("std");
const member_dispatch = @import("interp_ir").member_dispatch;
const ir = @import("ir");
const Module = ir.Module;
const cgen = @import("../cgen.zig");

const ARRAY_CLS = cgen.ARRAY_CLS;
const ArgBinding = cgen.ArgBinding;
const Compiled = cgen.Compiled;
const Global = cgen.Global;
const LIST_CLS = cgen.LIST_CLS;
const LambdaUse = cgen.LambdaUse;
const ListIntrinsic = cgen.ListIntrinsic;
const Program = cgen.Program;
const RANGE_CLS = cgen.RANGE_CLS;
const STRING_CLS = cgen.STRING_CLS;
const ScalarIntrinsic = cgen.ScalarIntrinsic;
const SingletonUse = cgen.SingletonUse;
const SlotUse = cgen.SlotUse;
const Ty = cgen.Ty;
const acceptedParamTy = cgen.acceptedParamTy;
const acceptedRet = cgen.acceptedRet;
const accessOwner = cgen.accessOwner;
const accessPlan = cgen.accessPlan;
const arrayOfIntrinsic = cgen.arrayOfIntrinsic;
const bindCallArgs = cgen.bindCallArgs;
const boxExpr = cgen.boxExpr;
const builtinConst = cgen.builtinConst;
const cOp = cgen.cOp;
const classIndexOfName = cgen.classIndexOfName;
const companionObjectNamed = cgen.companionObjectNamed;
const companionReceiver = cgen.companionReceiver;
const constTy = cgen.constTy;
const convExpr = cgen.convExpr;
const ctorDefault = cgen.ctorDefault;
const ctorParamTy = cgen.ctorParamTy;
const emit = cgen.emit;
const emitCLiteral = cgen.emitCLiteral;
const enumEntries = cgen.enumEntries;
const enumEntryIndex = cgen.enumEntryIndex;
const fieldIndex = cgen.fieldIndex;
const funcClsArity = cgen.funcClsArity;
const funcRetTy2 = cgen.funcRetTy2;
const globalIndex = cgen.globalIndex;
const hostMemberOp = cgen.hostMemberOp;
const isArrayOfNulls = cgen.isArrayOfNulls;
const isArrayTypeName = cgen.isArrayTypeName;
const isBuiltinCls = cgen.isBuiltinCls;
const isCmp = cgen.isCmp;
const isDelay = cgen.isDelay;
const isDispatched = cgen.isDispatched;
const isLaunch = cgen.isLaunch;
const isPrintln = cgen.isPrintln;
const isRunBlocking = cgen.isRunBlocking;
const isThrowableClass = cgen.isThrowableClass;
const isToStringCall = cgen.isToStringCall;
const lambdaSingletonSlot = cgen.lambdaSingletonSlot;
const listIntrinsic = cgen.listIntrinsic;
const listMemberName = cgen.listMemberName;
const mangleName = cgen.mangleName;
const memberRoot = cgen.memberRoot;
const no = cgen.no;
const numClsTy = cgen.numClsTy;
const numConv = cgen.numConv;
const paramTy = cgen.paramTy;
const plainFieldName = cgen.plainFieldName;
const primArrayKind = cgen.primArrayKind;
const primKindOfTy = cgen.primKindOfTy;
const promote = cgen.promote;
const reachableBlocks = cgen.reachableBlocks;
const regName = cgen.regName;
const renderExpr = cgen.renderExpr;
const rendersToString = cgen.rendersToString;
const scalarIntrinsic = cgen.scalarIntrinsic;
const simpleName = cgen.simpleName;
const singletonSlot = cgen.singletonSlot;
const staticClassOf = cgen.staticClassOf;
const stdlibEntry = cgen.stdlibEntry;
const suspendIndex = cgen.suspendIndex;
const suspendPoints = cgen.suspendPoints;
const tyOf = cgen.tyOf;
const typeReaches = cgen.typeReaches;
const unboxExpr = cgen.unboxExpr;
const unsignedTypeOf = cgen.unsignedTypeOf;
const wrapTy = cgen.wrapTy;
const writeConst = cgen.writeConst;
const writeProto = cgen.writeProto;
const writeSymbol = cgen.writeSymbol;

/// What every step of one body reads: the writer, the module, the program, the analysis.
const Body = struct {
    gpa: std.mem.Allocator,
    w: *std.Io.Writer,
    m: *const Module,
    prog: Program,
    c: *const Compiled,
    f: *const ir.Func,
    uses_objects: bool,
    globals: []const Global,
    singletons: []const SingletonUse,
    slots: []const SlotUse,
    uses_try: bool,
    accepted: []const Compiled,
    registered: []const u32,
    lambdas: []const LambdaUse,
    points: []const *const ir.Inst,
};

pub fn writeBody(gpa: std.mem.Allocator, w: *std.Io.Writer, m: *const Module, prog: Program, c: *const Compiled, uses_objects: bool, globals: []const Global, singletons: []const SingletonUse, slots: []const SlotUse, uses_try: bool, accepted: []const Compiled, registered: []const u32, lambdas: []const LambdaUse) !void {
    const f = c.f;
    const live = try reachableBlocks(gpa, f);
    defer gpa.free(live);
    const points = try suspendPoints(gpa, m, f, live);
    defer gpa.free(points);
    var has_catch = false;
    for (f.blocks) |*blk| {
        if (blk.catches.len != 0) has_catch = true;
    }
    const ctx: Body = .{
        .gpa = gpa,
        .w = w,
        .m = m,
        .prog = prog,
        .c = c,
        .f = f,
        .uses_objects = uses_objects,
        .globals = globals,
        .singletons = singletons,
        .slots = slots,
        .uses_try = uses_try,
        .accepted = accepted,
        .registered = registered,
        .lambdas = lambdas,
        .points = points,
    };
    try writeFunctionOpening(&ctx);
    try writeRegisterLocals(&ctx, has_catch);
    if (c.n_slots != 0 and !c.suspends) try writeGcSlotFrame(&ctx);
    if (has_catch) {
        // The handler stack as found: a `return` out of an armed region never reaches its disarm,
        // so every return puts the stack back where it was.
        try w.writeAll("  klio_try *KTE = klio_try_top;\n");
    }
    if (!c.suspends) try w.writeAll("  goto B0;\n");
    for (f.blocks, 0..) |*blk, bi| {
        if (!live[bi]) continue;
        try w.print("B{d}:;\n", .{bi});
        if (blk.catch_done_for != null) try w.writeAll("  klio_try_disarm();\n");
        if (blk.catches.len != 0) try writeCatchLandingPad(&ctx, blk, bi);
        for (blk.insts) |*inst| try writeInst(&ctx, inst);
        try writeTerminator(&ctx, blk, bi, has_catch);
    }
    try w.writeAll("}\n\n");
}

/// The C a body opens with: a prototype, or a suspending body's frame, entry and header.
fn writeFunctionOpening(ctx: *const Body) !void {
    const w = ctx.w;
    const c = ctx.c;
    if (c.suspends) {
        try writeCoroutineFrameType(ctx);
        try writeCoroutineFrameBuilder(ctx);
        try writeSuspendingEntry(ctx);
        try writeContinuationPreamble(ctx);
    } else {
        try writeProto(w, c);
        try w.writeAll(" {\n");
    }
}

/// The frame a suspension leaves behind: registers, resume label and object slots, on the
/// heap because the body returns in the middle of itself.
fn writeCoroutineFrameType(ctx: *const Body) !void {
    const w = ctx.w;
    const c = ctx.c;
    const f = ctx.f;
    try w.print("typedef struct {{\n  uint32_t st;\n  klio_nat_frame gcf;\n  klio_value ks[{d}];\n", .{@max(c.n_slots, 1)});
    var sr: u32 = 0;
    while (sr < f.n_locals) : (sr += 1) {
        if (c.types[sr] == .object) continue;
        try w.print("  {s} r{d};\n", .{ c.types[sr].cName(), sr });
    }
    for (c.caps, 0..) |ct, ci| try w.print("  {s} k{d};\n", .{ ct.ty.cName(), ci });
    for (c.params, 0..) |p, pi| {
        const pt: Ty = tyOf(p.ty) orelse .object;
        try w.print("  {s} p{d};\n", .{ pt.cName(), pi });
    }
    try w.print("}} kfr_{d};\n", .{f.id.int()});
}

/// Building the frame is separate from running it: a DRIVER-started coroutine is handed one.
fn writeCoroutineFrameBuilder(ctx: *const Body) !void {
    const w = ctx.w;
    const c = ctx.c;
    const f = ctx.f;
    try w.print("static void *kcf_{d}(", .{f.id.int()});
    if (c.params.len == 0 and c.caps.len == 0) {
        try w.writeAll("void");
    } else {
        for (c.caps, 0..) |ct, i| {
            if (i != 0) try w.writeAll(", ");
            try w.print("{s} k{d}", .{ ct.ty.cName(), i });
        }
        for (c.params, 0..) |p, i| {
            if (i != 0 or c.caps.len != 0) try w.writeAll(", ");
            const pt: Ty = tyOf(p.ty) orelse .object;
            try w.print("{s} p{d}", .{ pt.cName(), i });
        }
    }
    try w.writeAll(") {\n");
    try w.print("  kfr_{d} *fr = (kfr_{d} *)klio_nat_coro_frame(sizeof(kfr_{d}), offsetof(kfr_{d}, gcf), offsetof(kfr_{d}, ks), {d});\n", .{
        f.id.int(), f.id.int(), f.id.int(), f.id.int(), f.id.int(), c.n_slots,
    });
    for (c.caps, 0..) |_, ci| try w.print("  fr->k{d} = k{d};\n", .{ ci, ci });
    for (c.params, 0..) |_, pi| try w.print("  fr->p{d} = p{d};\n", .{ pi, pi });
    try w.writeAll("  return fr;\n}\n");
}

fn writeSuspendingEntry(ctx: *const Body) !void {
    const w = ctx.w;
    const c = ctx.c;
    const f = ctx.f;
    try writeProto(w, c);
    try w.writeAll(" {\n");
    try w.print("  return kco_{d}(kcf_{d}(", .{ f.id.int(), f.id.int() });
    for (c.caps, 0..) |_, ci| {
        if (ci != 0) try w.writeAll(", ");
        try w.print("k{d}", .{ci});
    }
    for (c.params, 0..) |_, pi| {
        if (pi != 0 or c.caps.len != 0) try w.writeAll(", ");
        try w.print("p{d}", .{pi});
    }
    try w.writeAll("), klio_nat_box_unit());\n}\n");
}

/// The continuation: entered fresh, and again at each resume.
fn writeContinuationPreamble(ctx: *const Body) !void {
    const w = ctx.w;
    const f = ctx.f;
    const points = ctx.points;
    try w.print("static klio_value kco_{d}(void *fp, klio_value resumed) {{\n", .{f.id.int()});
    try w.print("  kfr_{d} *fr = (kfr_{d} *)fp;\n  (void)resumed;\n", .{ f.id.int(), f.id.int() });
    if (points.len != 0) {
        try w.writeAll("  switch (fr->st) {\n");
        var pi2: u32 = 0;
        while (pi2 < points.len) : (pi2 += 1) try w.print("    case {d}: goto RS{d};\n", .{ pi2 + 1, pi2 });
        try w.writeAll("    default: break;\n  }\n");
    }
    try w.writeAll("  goto B0;\n");
}

fn writeRegisterLocals(ctx: *const Body, has_catch: bool) !void {
    const w = ctx.w;
    const c = ctx.c;
    const f = ctx.f;
    var r: u32 = 0;
    if (c.suspends) r = f.n_locals;
    while (r < f.n_locals) : (r += 1) {
        if (c.types[r] == .object) continue;
        // A local written after `setjmp` and read after the jump back must be volatile.
        try w.print("  {s}{s} r{d} = 0;\n", .{ if (has_catch) "volatile " else "", c.types[r].cName(), r });
    }
    // Registers the body never reads: the emitted file should be warning-clean.
    r = if (c.suspends) f.n_locals else 0;
    while (r < f.n_locals) : (r += 1) {
        if (c.types[r] == .object) continue;
        try w.print("  (void)r{d};", .{r});
    }
    try w.writeAll("\n");
}

/// References published to the collector for the call, cleared first so a collection before
/// the first assignment does not follow whatever the stack held.
fn writeGcSlotFrame(ctx: *const Body) !void {
    const w = ctx.w;
    const c = ctx.c;
    try w.print("  klio_value KS[{d}];\n", .{c.n_slots});
    try w.print("  for (unsigned i = 0; i < {d}; i++) KS[i] = klio_nat_box_unit();\n", .{c.n_slots});
    try w.print("  klio_nat_frame KF; KF.n = {d}; KF.slots = KS; klio_nat_enter(&KF);\n", .{c.n_slots});
}

/// Arm before the region's body: a throw lands back here and each handler is tried in order.
fn writeCatchLandingPad(ctx: *const Body, blk: *const ir.Block, bi: usize) !void {
    const w = ctx.w;
    const prog = ctx.prog;
    const c = ctx.c;
    try w.print("  klio_try KT{d};\n", .{bi});
    // A throw reaching here skipped every frame's `leave`, so the chain is put back first.
    try w.print("  klio_nat_frame *KM{d} = klio_nat_frame_mark();\n", .{bi});
    try w.print("  klio_try_arm(&KT{d});\n", .{bi});
    try w.print("  if (setjmp(KT{d}.jb) != 0) {{\n", .{bi});
    try w.print("    klio_nat_frame_restore(KM{d});\n", .{bi});
    try w.writeAll("    klio_try_disarm();\n");
    for (blk.catches) |h| {
        var eb: [32]u8 = undefined;
        const ht = prog.throws.find(h.type_name).?;
        try w.print("    if (klio_nat_catches(klio_in_flight, {d}, {d})) {{ {s} = klio_in_flight; goto B{d}; }} /* {s} */\n", .{
            ht.lo, ht.hi, regName(c, h.exception_reg.int(), &eb), h.handler.int(), h.type_name,
        });
    }
    try w.writeAll("    klio_do_throw(klio_in_flight);\n  }\n");
}

fn writeInst(ctx: *const Body, inst: *const ir.Inst) !void {
    const w = ctx.w;
    const m = ctx.m;
    const c = ctx.c;
    const globals = ctx.globals;
    switch (inst.*) {
        .Trace => {},
        .EnclosingPush, .EnclosingPop => {},
        .CallMemberOrGlobal => try writeBareCall(ctx, inst),
        .LoadFromThisOrGlobal => try writeBareLoad(ctx, inst),
        .StoreToThisOrGlobal => try writeBareStore(ctx, inst),
        .Const => try writeConstLoad(ctx, inst),
        // A suspend body reads its parameters and captures from the frame: the C arguments are gone.
        .LoadParam => |lp| {
            var nb: [32]u8 = undefined;
            try w.print("  {s} = {s}p{d};\n", .{ regName(c, lp.dst.int(), &nb), if (c.suspends) "fr->" else "", lp.idx });
        },
        .LoadCapture => |lc| {
            var nb: [32]u8 = undefined;
            try w.print("  {s} = {s}k{d};\n", .{ regName(c, lc.dst.int(), &nb), if (c.suspends) "fr->" else "", lc.idx });
        },
        .MakeCell => |mk| {
            var nb: [32]u8 = undefined;
            var sb2: [32]u8 = undefined;
            var bb4: [96]u8 = undefined;
            try w.print("  {s} = klio_nat_cell({s});\n", .{
                regName(c, mk.dst.int(), &nb),
                boxExpr(c.types[mk.src.int()], regName(c, mk.src.int(), &sb2), &bb4),
            });
        },
        .CellGet => |cg| {
            var nb: [32]u8 = undefined;
            var cb4: [32]u8 = undefined;
            var gb2: [96]u8 = undefined;
            const g2 = try std.fmt.bufPrint(&gb2, "klio_nat_cell_get({s})", .{regName(c, cg.cell.int(), &cb4)});
            var ob2: [160]u8 = undefined;
            try w.print("  {s} = {s};\n", .{
                regName(c, cg.dst.int(), &nb), unboxExpr(c.types[cg.dst.int()], g2, &ob2),
            });
        },
        .CellSet => |cs| {
            var cb5: [32]u8 = undefined;
            var vb2: [32]u8 = undefined;
            var bb5: [96]u8 = undefined;
            try w.print("  klio_nat_cell_set({s}, {s});\n", .{
                regName(c, cs.cell.int(), &cb5),
                boxExpr(c.types[cs.value.int()], regName(c, cs.value.int(), &vb2), &bb5),
            });
        },
        .Move => |mv| {
            var nb: [32]u8 = undefined;
            var sb: [32]u8 = undefined;
            const dt2 = c.types[mv.dst.int()];
            const st2 = c.types[mv.src.int()];
            const src2 = regName(c, mv.src.int(), &sb);
            var bb14: [96]u8 = undefined;
            const val2 = if (dt2 == .object and st2 != .object)
                boxExpr(st2, src2, &bb14)
            else if (dt2 != .object and st2 == .object)
                unboxExpr(dt2, src2, &bb14)
            else
                src2;
            try w.print("  {s} = {s};\n", .{ regName(c, mv.dst.int(), &nb), val2 });
        },
        .NewInstance => try writeNewInstance(ctx, inst),
        .GetField => try writeGetField(ctx, inst),
        .SetField => try writeSetField(ctx, inst),
        .BinOp => try writeBinOp(ctx, inst),
        .UnOp => try writeUnOp(ctx, inst),
        .Not => |n| try w.print("  r{d} = !r{d};\n", .{ n.dst.int(), n.src.int() }),
        .Cast => try writeCast(ctx, inst),
        .InstanceOf => try writeInstanceOf(ctx, inst),
        .CallMember => try writeCallMember(ctx, inst),
        .CallVirtual => try writeCallVirtual(ctx, inst),
        .LoadGlobal => try writeLoadGlobal(ctx, inst),
        .StoreGlobal => |sg| {
            const gn = m.consts.items[sg.name.int()].String;
            const gi = globalIndex(globals, gn).?;
            var vb: [32]u8 = undefined;
            var bb: [96]u8 = undefined;
            try w.print("  KG[{d}] = {s};\n", .{
                gi, boxExpr(c.types[sg.value.int()], regName(c, sg.value.int(), &vb), &bb),
            });
        },
        .AstLambda => try writeAstLambda(ctx, inst),
        .CallValueOrMember => try writeValueDispatchCall(ctx, inst),
        .CallValue => try writeCallValue(ctx, inst),
        .Call => try writeCall(ctx, inst),
        else => unreachable,
    }
}

/// A call the lowering left open between a member and a global, as the bare table resolved it.
fn writeBareCall(ctx: *const Body, inst: *const ir.Inst) !void {
    const w = ctx.w;
    const c = ctx.c;
    const cg3 = inst.CallMemberOrGlobal;
    var nb18: [32]u8 = undefined;
    const cdst = regName(c, cg3.dst.int(), &nb18);
    switch (c.bare.get(inst).?) {
        // A bare call that names a class constructs one.
        .construct => |bcid3| try writeBareConstruction(ctx, inst, cdst, bcid3),
        .member => |mb2| {
            var rb18: [32]u8 = undefined;
            try w.print("  {s} = kvirt_{d}({s}", .{ cdst, mb2.slot, regName(c, mb2.recv, &rb18) });
            var aj18: u32 = 0;
            while (aj18 < cg3.n_args) : (aj18 += 1) {
                var ab18: [32]u8 = undefined;
                try w.print(", {s}", .{regName(c, cg3.args.int() + aj18, &ab18)});
            }
            try w.writeAll(");\n");
        },
        .call => |cf2| try writeBareStaticCall(ctx, inst, cdst, cf2),
        else => unreachable,
    }
}

/// The instance a bare constructor call builds: defaults into locals, allocation, initializer.
fn writeBareConstruction(ctx: *const Body, inst: *const ir.Inst, cdst: []const u8, bcid3: u32) !void {
    const gpa = ctx.gpa;
    const w = ctx.w;
    const m = ctx.m;
    const prog = ctx.prog;
    const c = ctx.c;
    const accepted = ctx.accepted;
    const cg3 = inst.CallMemberOrGlobal;
    const bdef3 = &m.classes.items[bcid3];
    const bb11 = bindCallArgs(m, bdef3.primary_params, cg3.args.int(), cg3.n_args, cg3.arg_names).?;
    var dq3: u32 = 0;
    while (dq3 < bb11.n) : (dq3 += 1) {
        if (bb11.regs[dq3] != null) continue;
        const dfn3 = m.funcById(ctorDefault(prog.layouts, bdef3, dq3).?).?;
        const dt3 = acceptedRet(accepted, dfn3) orelse funcRetTy2(m, dfn3).?;
        var ds3: std.Io.Writer.Allocating = .init(gpa);
        defer ds3.deinit();
        try writeSymbol(&ds3.writer, dfn3);
        try w.print("  {s} kbc{d}_{d} = {s}(klio_nat_null()", .{ dt3.cName(), cg3.dst.int(), dq3, ds3.written() });
        var dk3: u32 = 0;
        while (dk3 < bb11.n) : (dk3 += 1) {
            try w.writeAll(", ");
            const wt3 = ctorParamTy(bdef3, dk3);
            if (dk3 >= dq3) {
                if (wt3 == .object) try w.writeAll("klio_nat_null()") else try w.writeAll("0");
                continue;
            }
            var bx7: [96]u8 = undefined;
            if (bb11.regs[dk3]) |br7| {
                var ab7: [32]u8 = undefined;
                try w.print("{s}", .{convExpr(c.types[br7], wt3, regName(c, br7, &ab7), &bx7)});
            } else {
                var tb7: [48]u8 = undefined;
                const tn7 = try std.fmt.bufPrint(&tb7, "kbc{d}_{d}", .{ cg3.dst.int(), dk3 });
                try w.print("{s}", .{tn7});
            }
        }
        try w.writeAll(");\n");
    }
    try w.print("  {s} = klio_nat_alloc_instance(KCLS_{d});\n", .{ cdst, bcid3 });
    try w.print("  kinit_{d}({s}", .{ bcid3, cdst });
    var pi7: u32 = 0;
    while (pi7 < bb11.n) : (pi7 += 1) {
        try w.writeAll(", ");
        const wt7 = ctorParamTy(bdef3, pi7);
        var ab8: [32]u8 = undefined;
        var bx8: [96]u8 = undefined;
        if (bb11.regs[pi7]) |ar8| {
            try w.print("{s}", .{convExpr(c.types[ar8], wt7, regName(c, ar8, &ab8), &bx8)});
            continue;
        }
        const dfn8 = m.funcById(ctorDefault(prog.layouts, bdef3, pi7).?).?;
        const hv8 = acceptedRet(accepted, dfn8) orelse funcRetTy2(m, dfn8).?;
        var tb8: [48]u8 = undefined;
        const tn8 = try std.fmt.bufPrint(&tb8, "kbc{d}_{d}", .{ cg3.dst.int(), pi7 });
        try w.print("{s}", .{convExpr(hv8, wt7, tn8, &bx8)});
    }
    try w.writeAll(");\n");
}

fn writeBareStaticCall(ctx: *const Body, inst: *const ir.Inst, cdst: []const u8, cf2: ir.FuncId) !void {
    const gpa = ctx.gpa;
    const w = ctx.w;
    const m = ctx.m;
    const prog = ctx.prog;
    const c = ctx.c;
    const accepted = ctx.accepted;
    const cg3 = inst.CallMemberOrGlobal;
    const cfn2 = m.funcById(cf2).?;
    if (isPrintln(cfn2) or scalarIntrinsic(cfn2) == .print) {
        var rex3: std.Io.Writer.Allocating = .init(gpa);
        defer rex3.deinit();
        try renderExpr(gpa, m, prog, c, cg3.args.int(), &rex3);
        try w.print("  {s}({s});\n", .{
            if (isPrintln(cfn2)) "klio_nat_println" else "klio_nat_print",
            rex3.written(),
        });
        return;
    }
    const bn19 = bindCallArgs(m, cfn2.params, cg3.args.int(), cg3.n_args, cg3.arg_names).?;
    var dj19: u32 = 0;
    while (dj19 < bn19.n) : (dj19 += 1) {
        if (bn19.regs[dj19] != null) continue;
        const dfn19 = m.funcById(prog.defaultThunk(cfn2.id, dj19).?).?;
        const dt19 = acceptedRet(accepted, dfn19) orelse funcRetTy2(m, dfn19).?;
        var ds19: std.Io.Writer.Allocating = .init(gpa);
        defer ds19.deinit();
        try writeSymbol(&ds19.writer, dfn19);
        try w.print("  {s} kb{d}_{d} = {s}(", .{ dt19.cName(), cg3.dst.int(), dj19, ds19.written() });
        var dk19: u32 = 0;
        while (dk19 < dj19) : (dk19 += 1) {
            if (dk19 != 0) try w.writeAll(", ");
            if (bn19.regs[dk19]) |br19| {
                var ab20: [32]u8 = undefined;
                try w.print("{s}", .{regName(c, br19, &ab20)});
            } else {
                try w.print("kb{d}_{d}", .{ cg3.dst.int(), dk19 });
            }
        }
        try w.writeAll(");\n");
    }
    try w.print("  {s} = ", .{cdst});
    try writeSymbol(w, cfn2);
    try w.writeByte('(');
    var aj19: u32 = 0;
    while (aj19 < bn19.n) : (aj19 += 1) {
        if (aj19 != 0) try w.writeAll(", ");
        var ab19: [32]u8 = undefined;
        var cb19: [96]u8 = undefined;
        const pw19 = acceptedParamTy(accepted, cfn2, aj19) orelse paramTy(cfn2.params[aj19]);
        if (bn19.regs[aj19]) |ar19| {
            try w.print("{s}", .{convExpr(c.types[ar19], pw19, regName(c, ar19, &ab19), &cb19)});
            continue;
        }
        const dfn20 = m.funcById(prog.defaultThunk(cfn2.id, aj19).?).?;
        const hv20 = acceptedRet(accepted, dfn20) orelse funcRetTy2(m, dfn20).?;
        var tb20: [48]u8 = undefined;
        const tn20 = try std.fmt.bufPrint(&tb20, "kb{d}_{d}", .{ cg3.dst.int(), aj19 });
        try w.print("{s}", .{convExpr(hv20, pw19, tn20, &cb19)});
    }
    try w.writeAll(");\n");
}

/// A bare name read: a field of the receiver, its getter, or a global.
fn writeBareLoad(ctx: *const Body, inst: *const ir.Inst) !void {
    const gpa = ctx.gpa;
    const w = ctx.w;
    const m = ctx.m;
    const c = ctx.c;
    const globals = ctx.globals;
    const lt = inst.LoadFromThisOrGlobal;
    var nb8: [32]u8 = undefined;
    const dst8 = regName(c, lt.dst.int(), &nb8);
    switch (c.bare.get(inst).?) {
        .construct => unreachable,
        .field => |fl| {
            var rb8: [32]u8 = undefined;
            var gb8: [128]u8 = undefined;
            const g8 = try std.fmt.bufPrint(&gb8, "klio_nat_get({s}, {d})", .{ regName(c, fl.recv, &rb8), fl.idx });
            var ob8: [200]u8 = undefined;
            try w.print("  {s} = {s};\n", .{ dst8, unboxExpr(c.types[lt.dst.int()], g8, &ob8) });
        },
        .accessor => |ac| {
            var rb9: [32]u8 = undefined;
            var sym8: std.Io.Writer.Allocating = .init(gpa);
            defer sym8.deinit();
            try writeSymbol(&sym8.writer, m.funcById(ac.func).?);
            try w.print("  {s} = {s}({s});\n", .{ dst8, sym8.written(), regName(c, ac.recv, &rb9) });
        },
        .global => {
            const gi8 = globalIndex(globals, m.consts.items[lt.name.int()].String).?;
            var ob9: [96]u8 = undefined;
            var src9: [32]u8 = undefined;
            const from9 = try std.fmt.bufPrint(&src9, "KG[{d}]", .{gi8});
            try w.print("  {s} = {s};\n", .{ dst8, unboxExpr(c.types[lt.dst.int()], from9, &ob9) });
        },
        .member, .call => unreachable,
    }
}

fn writeBareStore(ctx: *const Body, inst: *const ir.Inst) !void {
    const gpa = ctx.gpa;
    const w = ctx.w;
    const m = ctx.m;
    const c = ctx.c;
    const globals = ctx.globals;
    const st = inst.StoreToThisOrGlobal;
    switch (c.bare.get(inst).?) {
        .construct => unreachable,
        .field => |fl| {
            var rb10: [32]u8 = undefined;
            var vb10: [32]u8 = undefined;
            var bb10: [96]u8 = undefined;
            try w.print("  klio_nat_set({s}, {d}, {s});\n", .{
                regName(c, fl.recv, &rb10), fl.idx,
                boxExpr(c.types[st.value.int()], regName(c, st.value.int(), &vb10), &bb10),
            });
        },
        .accessor => |ac| {
            var rb11: [32]u8 = undefined;
            var vb11: [32]u8 = undefined;
            var bb11: [96]u8 = undefined;
            const sfn = m.funcById(ac.func).?;
            var sym9: std.Io.Writer.Allocating = .init(gpa);
            defer sym9.deinit();
            try writeSymbol(&sym9.writer, sfn);
            const want9: Ty = if (sfn.params.len >= 2) (tyOf(sfn.params[1].ty) orelse .object) else .object;
            const arg9 = if (want9 == .object and c.types[st.value.int()] != .object)
                boxExpr(c.types[st.value.int()], regName(c, st.value.int(), &vb11), &bb11)
            else
                regName(c, st.value.int(), &vb11);
            try w.print("  {s}({s}, {s});\n", .{ sym9.written(), regName(c, ac.recv, &rb11), arg9 });
        },
        .global => {
            const gi9 = globalIndex(globals, m.consts.items[st.name.int()].String).?;
            var vb12: [32]u8 = undefined;
            var bb12: [96]u8 = undefined;
            try w.print("  KG[{d}] = {s};\n", .{
                gi9, boxExpr(c.types[st.value.int()], regName(c, st.value.int(), &vb12), &bb12),
            });
        },
        .member, .call => unreachable,
    }
}

fn writeConstLoad(ctx: *const Body, inst: *const ir.Inst) !void {
    const w = ctx.w;
    const m = ctx.m;
    const c = ctx.c;
    const k = inst.Const;
    const kv = m.consts.items[k.value.int()];
    var nb: [32]u8 = undefined;
    if (kv == .Null) {
        try w.print("  {s} = klio_nat_null();\n", .{regName(c, k.dst.int(), &nb)});
        return;
    }
    if (kv == .String) {
        try w.print("  {s} = klio_nat_string(", .{regName(c, k.dst.int(), &nb)});
        try emitCLiteral(w, kv.String);
        try w.print(", {d});\n", .{kv.String.len});
        return;
    }
    // The lowering writes Unit into a result register first, so a reference register can also
    // be assigned a scalar constant.
    if (c.types[k.dst.int()] == .object) {
        var kb: [48]u8 = undefined;
        var kw: std.Io.Writer = .fixed(&kb);
        try writeConst(&kw, kv);
        var bb13: [96]u8 = undefined;
        try w.print("  {s} = {s};\n", .{
            regName(c, k.dst.int(), &nb),
            boxExpr(constTy(kv) orelse .unit, kw.buffered(), &bb13),
        });
        return;
    }
    try w.print("  {s} = ", .{regName(c, k.dst.int(), &nb)});
    try writeConst(w, kv);
    try w.writeAll(";\n");
}

/// A constructor call: a runtime throwable, an unsigned wrapper, an array, or an instance.
fn writeNewInstance(ctx: *const Body, inst: *const ir.Inst) !void {
    const w = ctx.w;
    const m = ctx.m;
    const prog = ctx.prog;
    const c = ctx.c;
    const ni = inst.NewInstance;
    var nb: [32]u8 = undefined;
    const dst = regName(c, ni.dst.int(), &nb);
    if (isThrowableClass(m, ni.class.int())) {
        const cn = m.classes.items[ni.class.int()];
        const tid = prog.throws.find(cn.name) orelse prog.throws.find(cn.fqn);
        try w.print("  {s} = klio_nat_exception(\"{s}\", ", .{ dst, cn.fqn });
        if (ni.n_args == 1) {
            var ab6: [32]u8 = undefined;
            var bb7: [96]u8 = undefined;
            const ar5 = ni.args.int();
            try w.print("{s}", .{boxExpr(c.types[ar5], regName(c, ar5, &ab6), &bb7)});
        } else {
            try w.writeAll("klio_nat_box_unit()");
        }
        try w.print(", {d});\n", .{if (tid) |t| t.lo else 0});
        return;
    }
    if (unsignedTypeOf(m.classes.items[ni.class.int()].name)) |ut2| {
        var ub9: [32]u8 = undefined;
        try w.print("  {s} = ({s}){s};\n", .{
            dst, ut2.cName(), regName(c, ni.args.int(), &ub9),
        });
        return;
    }
    if (isArrayTypeName(m.classes.items[ni.class.int()].name)) {
        try writeNewArray(ctx, inst, dst);
        return;
    }
    try writeNewObject(ctx, inst, dst);
}

fn writeNewArray(ctx: *const Body, inst: *const ir.Inst, dst: []const u8) !void {
    const gpa = ctx.gpa;
    const w = ctx.w;
    const m = ctx.m;
    const c = ctx.c;
    const accepted = ctx.accepted;
    const ni = inst.NewInstance;
    var sb7: [32]u8 = undefined;
    const nsz = regName(c, ni.args.int(), &sb7);
    if (primArrayKind(m.classes.items[ni.class.int()].name)) |k7| {
        try w.print("  {s} = klio_nat_prim_array({d}, {s});\n", .{ dst, k7, nsz });
    } else {
        try w.print("  {s} = klio_nat_ref_array_sized({s});\n", .{ dst, nsz });
    }
    if (ni.n_args == 2) {
        // Each element is what the initializer returns for its index, a loop rather than dispatch.
        const lr2 = ni.args.int() + 1;
        var elem_call: std.Io.Writer.Allocating = .init(gpa);
        defer elem_call.deinit();
        var ety: Ty = .object;
        if (c.lam[lr2]) |li2| {
            const bf2 = m.funcById(li2.body).?;
            ety = acceptedRet(accepted, bf2) orelse .object;
            try writeSymbol(&elem_call.writer, bf2);
            try elem_call.writer.writeByte('(');
            for (li2.captures, 0..) |cr13, ci13| {
                if (ci13 != 0) try elem_call.writer.writeAll(", ");
                var cb13: [32]u8 = undefined;
                try elem_call.writer.print("{s}", .{regName(c, cr13.int(), &cb13)});
            }
            var pj: u32 = 0;
            while (pj < bf2.params.len) : (pj += 1) {
                if (pj != 0 or li2.captures.len != 0) try elem_call.writer.writeAll(", ");
                if (pj == 0) {
                    try elem_call.writer.print("ki{d}", .{ni.dst.int()});
                } else {
                    try elem_call.writer.writeAll("0");
                }
            }
            try elem_call.writer.writeByte(')');
        } else {
            var fb16: [32]u8 = undefined;
            ety = c.elem[lr2];
            try elem_call.writer.print("klam_call_1({s}, klio_nat_box_int(ki{d}))", .{
                regName(c, lr2, &fb16), ni.dst.int(),
            });
            // The dispatcher already answers a boxed value.
            ety = .object;
        }
        var bb20: [420]u8 = undefined;
        try w.print(
            "  for (int32_t ki{d} = 0; ki{d} < {s}; ki{d}++) klio_nat_array_set({s}, ki{d}, {s});\n",
            .{ ni.dst.int(), ni.dst.int(), nsz, ni.dst.int(), dst, ni.dst.int(), boxExpr(ety, elem_call.written(), &bb20) },
        );
    }
}

fn writeNewObject(ctx: *const Body, inst: *const ir.Inst, dst: []const u8) !void {
    const gpa = ctx.gpa;
    const w = ctx.w;
    const m = ctx.m;
    const prog = ctx.prog;
    const c = ctx.c;
    const accepted = ctx.accepted;
    const ni = inst.NewInstance;
    const cdef2 = &m.classes.items[ni.class.int()];
    const cb4 = bindCallArgs(m, cdef2.primary_params, ni.args.int(), ni.n_args, ni.arg_names).?;
    // A parameter nothing binds runs its default thunk into a local: a later default may read it.
    var dp3: u32 = 0;
    while (dp3 < cb4.n) : (dp3 += 1) {
        if (cb4.regs[dp3] != null) continue;
        const cdfn2 = m.funcById(ctorDefault(prog.layouts, cdef2, dp3).?).?;
        const cdt = acceptedRet(accepted, cdfn2) orelse funcRetTy2(m, cdfn2).?;
        var csym: std.Io.Writer.Allocating = .init(gpa);
        defer csym.deinit();
        try writeSymbol(&csym.writer, cdfn2);
        try w.print("  {s} kcd{d}_{d} = {s}(klio_nat_null()", .{ cdt.cName(), ni.dst.int(), dp3, csym.written() });
        // Kotlin forbids a default from reading a parameter declared after it, so the thunk takes
        // the whole signature and the rest go in as their C zero.
        var ck3: u32 = 0;
        while (ck3 < cb4.n) : (ck3 += 1) {
            try w.writeAll(", ");
            const cwant = ctorParamTy(cdef2, ck3);
            if (ck3 >= dp3) {
                if (cwant == .object) try w.writeAll("klio_nat_null()") else try w.writeAll("0");
                continue;
            }
            var bx6: [96]u8 = undefined;
            if (cb4.regs[ck3]) |br5| {
                var ab6: [32]u8 = undefined;
                try w.print("{s}", .{convExpr(c.types[br5], cwant, regName(c, br5, &ab6), &bx6)});
            } else {
                const pdfn = m.funcById(ctorDefault(prog.layouts, cdef2, ck3).?).?;
                const phave = acceptedRet(accepted, pdfn) orelse funcRetTy2(m, pdfn).?;
                var tb6: [48]u8 = undefined;
                const tn6 = try std.fmt.bufPrint(&tb6, "kcd{d}_{d}", .{ ni.dst.int(), ck3 });
                try w.print("{s}", .{convExpr(phave, cwant, tn6, &bx6)});
            }
        }
        try w.writeAll(");\n");
    }
    try w.print("  {s} = klio_nat_alloc_instance(KCLS_{d});\n", .{ dst, ni.class.int() });
    // The class's own initializer fills it, which lets a subclass hand the same instance up.
    try w.print("  kinit_{d}({s}", .{ ni.class.int(), dst });
    var pi3: u32 = 0;
    while (pi3 < cb4.n) : (pi3 += 1) {
        try w.writeAll(", ");
        const want3: Ty = ctorParamTy(cdef2, pi3);
        var ab5: [32]u8 = undefined;
        var bx3: [96]u8 = undefined;
        if (cb4.regs[pi3]) |areg3| {
            try w.print("{s}", .{convExpr(c.types[areg3], want3, regName(c, areg3, &ab5), &bx3)});
            continue;
        }
        const cdfn3 = m.funcById(ctorDefault(prog.layouts, cdef2, pi3).?).?;
        const chave = acceptedRet(accepted, cdfn3) orelse funcRetTy2(m, cdfn3).?;
        var tb5: [48]u8 = undefined;
        const tn5 = try std.fmt.bufPrint(&tb5, "kcd{d}_{d}", .{ ni.dst.int(), pi3 });
        try w.print("{s}", .{convExpr(chave, want3, tn5, &bx3)});
    }
    try w.writeAll(");\n");
}

/// A property read, resolved to a builtin, enum entry, companion, dispatcher, accessor or slot.
fn writeGetField(ctx: *const Body, inst: *const ir.Inst) !void {
    const w = ctx.w;
    const m = ctx.m;
    const prog = ctx.prog;
    const c = ctx.c;
    const singletons = ctx.singletons;
    const gf = inst.GetField;
    // A read whose result NAMES a class resolves at emit time and leaves nothing behind.
    if (staticClassOf(c.types, c.cls, gf.dst.int()) != null) return;
    {
        const sen2 = m.consts.items[gf.field.int()];
        if (sen2 == .String and std.mem.eql(u8, sen2.String, "<class-companion-or-self>")) {
            var nb21: [32]u8 = undefined;
            var rb21: [32]u8 = undefined;
            if (staticClassOf(c.types, c.cls, gf.receiver.int())) |scq2| {
                const ccq2 = companionObjectNamed(m, prog, m.classes.items[scq2].fqn).?;
                try w.print("  {s} = KO[{d}];\n", .{
                    regName(c, gf.dst.int(), &nb21), singletonSlot(singletons, ccq2, null).?,
                });
            } else {
                try w.print("  {s} = {s};\n", .{
                    regName(c, gf.dst.int(), &nb21), regName(c, gf.receiver.int(), &rb21),
                });
            }
            return;
        }
    }
    var rc = c.cls[gf.receiver.int()].?;
    // Read FROM the receiver register, or the companion singleton when the receiver is a class name.
    var qrb: [32]u8 = undefined;
    var recv_txt: []const u8 = regName(c, gf.receiver.int(), &qrb);
    if (staticClassOf(c.types, c.cls, gf.receiver.int())) |sc| {
        if (try writeStaticClassRead(ctx, inst, sc)) return;
        rc = companionObjectNamed(m, prog, m.classes.items[sc].fqn).?;
        recv_txt = try std.fmt.bufPrint(&qrb, "KO[{d}]", .{singletonSlot(singletons, rc, null).?});
    } else if (accessOwner(m, prog, rc, m.consts.items[gf.field.int()].String, false)) |cc| {
        // The name is the companion's, not the receiver's.
        rc = cc;
        recv_txt = try std.fmt.bufPrint(&qrb, "KO[{d}]", .{singletonSlot(singletons, cc, null).?});
    }
    if (rc == STRING_CLS or rc == LIST_CLS or rc == ARRAY_CLS) {
        var nb: [32]u8 = undefined;
        var rb: [32]u8 = undefined;
        try w.print("  {s} = {s}({s});\n", .{
            regName(c, gf.dst.int(), &nb),
            switch (rc) {
                STRING_CLS => "klio_nat_str_length",
                ARRAY_CLS => "klio_nat_array_size",
                else => "klio_nat_list_size",
            },
            regName(c, gf.receiver.int(), &rb),
        });
        return;
    }
    if (rc == RANGE_CLS) {
        var nb18: [32]u8 = undefined;
        var rb18: [32]u8 = undefined;
        var pb18: [160]u8 = undefined;
        var ob18: [220]u8 = undefined;
        const call18 = try std.fmt.bufPrint(&pb18, "klio_nat_builtin_prop(\"{s}\", {s})", .{
            plainFieldName(m.consts.items[gf.field.int()].String),
            regName(c, gf.receiver.int(), &rb18),
        });
        try w.print("  {s} = {s};\n", .{
            regName(c, gf.dst.int(), &nb18),
            unboxExpr(c.types[gf.dst.int()], call18, &ob18),
        });
        return;
    }
    try writeFieldAccess(ctx, inst, rc, recv_txt);
}

/// A read on a class NAME with no receiver: a builtin constant, an enum's entries, or one entry.
fn writeStaticClassRead(ctx: *const Body, inst: *const ir.Inst, sc: u32) !bool {
    const w = ctx.w;
    const m = ctx.m;
    const prog = ctx.prog;
    const c = ctx.c;
    const singletons = ctx.singletons;
    const gf = inst.GetField;
    const enm = m.consts.items[gf.field.int()].String;
    if (numClsTy(sc)) |bt3| {
        var nb15: [32]u8 = undefined;
        try w.print("  {s} = {s};\n", .{
            regName(c, gf.dst.int(), &nb15),
            builtinConst(bt3, plainFieldName(enm)).?.text,
        });
        return true;
    }
    if (std.mem.eql(u8, plainFieldName(enm), "entries") and
        enumEntries(m, prog, sc).len != 0)
    {
        const ents4 = enumEntries(m, prog, sc);
        var nb22: [32]u8 = undefined;
        try w.print("  {{ klio_value ee[{d}];\n", .{ents4.len});
        for (ents4, 0..) |_, ei4| {
            try w.print("    ee[{d}] = KO[{d}];\n", .{
                ei4, singletonSlot(singletons, sc, @intCast(ei4)).?,
            });
        }
        try w.print("    {s} = klio_nat_list(ee, {d}); }}\n", .{
            regName(c, gf.dst.int(), &nb22), ents4.len,
        });
        return true;
    }
    if (enumEntryIndex(m, prog, sc, plainFieldName(enm))) |ei2| {
        var nb3: [32]u8 = undefined;
        try w.print("  {s} = KO[{d}];\n", .{
            regName(c, gf.dst.int(), &nb3), singletonSlot(singletons, sc, ei2).?,
        });
        return true;
    }
    return false;
}

fn writeFieldAccess(ctx: *const Body, inst: *const ir.Inst, rc: u32, recv_txt: []const u8) !void {
    const gpa = ctx.gpa;
    const w = ctx.w;
    const m = ctx.m;
    const prog = ctx.prog;
    const c = ctx.c;
    const gf = inst.GetField;
    const nm = m.consts.items[gf.field.int()].String;
    switch (accessPlan(m, prog, rc, nm, false)) {
        .none => unreachable,
        .virtual => {
            var nb17: [32]u8 = undefined;
            var mangled: [96]u8 = undefined;
            try w.print("  {s} = kprop_{d}_{s}({s});\n", .{
                regName(c, gf.dst.int(), &nb17), rc,
                mangleName(plainFieldName(nm), &mangled), recv_txt,
            });
        },
        .accessor => |gacc| {
            const gfn = m.funcById(gacc).?;
            var nb2: [32]u8 = undefined;
            var sym2: std.Io.Writer.Allocating = .init(gpa);
            defer sym2.deinit();
            try writeSymbol(&sym2.writer, gfn);
            try w.print("  {s} = {s}({s});\n", .{
                regName(c, gf.dst.int(), &nb2), sym2.written(), recv_txt,
            });
        },
        .field => |idx| {
            var nb: [32]u8 = undefined;
            var ub: [128]u8 = undefined;
            const get = try std.fmt.bufPrint(&ub, "klio_nat_get({s}, {d})", .{ recv_txt, idx });
            var ob: [160]u8 = undefined;
            try w.print("  {s} = {s};\n", .{
                regName(c, gf.dst.int(), &nb), unboxExpr(c.types[gf.dst.int()], get, &ob),
            });
        },
    }
}

fn writeSetField(ctx: *const Body, inst: *const ir.Inst) !void {
    const gpa = ctx.gpa;
    const w = ctx.w;
    const m = ctx.m;
    const prog = ctx.prog;
    const c = ctx.c;
    const sf = inst.SetField;
    const rc = c.cls[sf.receiver.int()].?;
    const nm = m.consts.items[sf.field.int()].String;
    switch (accessPlan(m, prog, rc, nm, true)) {
        .none, .virtual => unreachable,
        .accessor => |sacc| {
            const sfn = m.funcById(sacc).?;
            var rb3: [32]u8 = undefined;
            var vb3: [32]u8 = undefined;
            var bx3: [96]u8 = undefined;
            var sym3: std.Io.Writer.Allocating = .init(gpa);
            defer sym3.deinit();
            try writeSymbol(&sym3.writer, sfn);
            const want3: Ty = if (sfn.params.len >= 2) (tyOf(sfn.params[1].ty) orelse .object) else .object;
            const arg3 = convExpr(c.types[sf.value.int()], want3, regName(c, sf.value.int(), &vb3), &bx3);
            try w.print("  {s}({s}, {s});\n", .{ sym3.written(), regName(c, sf.receiver.int(), &rb3), arg3 });
        },
        .field => |idx| {
            var rb: [32]u8 = undefined;
            var vb: [32]u8 = undefined;
            var bb: [96]u8 = undefined;
            try w.print("  klio_nat_set({s}, {d}, {s});\n", .{
                regName(c, sf.receiver.int(), &rb), idx,
                boxExpr(c.types[sf.value.int()], regName(c, sf.value.int(), &vb), &bb),
            });
        },
    }
}

/// A binary operator whose result is a VALUE: identity, reference equality, range, concatenation.
fn writeBinOp(ctx: *const Body, inst: *const ir.Inst) !void {
    const gpa = ctx.gpa;
    const w = ctx.w;
    const m = ctx.m;
    const prog = ctx.prog;
    const c = ctx.c;
    const b = inst.BinOp;
    const dt = c.types[b.dst.int()];
    if (b.op == .IdentEq or b.op == .IdentNeq) {
        var db4: [32]u8 = undefined;
        var lb4: [32]u8 = undefined;
        var rb4: [32]u8 = undefined;
        var l4: [96]u8 = undefined;
        var r4: [96]u8 = undefined;
        try w.print("  {s} = {s}klio_nat_value_ident({s}, {s});\n", .{
            regName(c, b.dst.int(), &db4),
            if (b.op == .IdentNeq) "!" else "",
            boxExpr(c.types[b.lhs.int()], regName(c, b.lhs.int(), &lb4), &l4),
            boxExpr(c.types[b.rhs.int()], regName(c, b.rhs.int(), &rb4), &r4),
        });
        return;
    }
    if ((b.op == .Eq or b.op == .NotEq) and
        (c.types[b.lhs.int()] == .object or c.types[b.rhs.int()] == .object))
    {
        var db2: [32]u8 = undefined;
        var lb2: [32]u8 = undefined;
        var rb2: [32]u8 = undefined;
        var l2: [96]u8 = undefined;
        var r2: [96]u8 = undefined;
        try w.print("  {s} = {s}klio_nat_value_eq({s}, {s});\n", .{
            regName(c, b.dst.int(), &db2),
            if (b.op == .NotEq) "!" else "",
            boxExpr(c.types[b.lhs.int()], regName(c, b.lhs.int(), &lb2), &l2),
            boxExpr(c.types[b.rhs.int()], regName(c, b.rhs.int(), &rb2), &r2),
        });
        return;
    }
    if (dt == .object and (b.op == .RangeTo or b.op == .RangeUntil)) {
        var db3: [32]u8 = undefined;
        var lb3: [32]u8 = undefined;
        var rb3: [32]u8 = undefined;
        var l3: [96]u8 = undefined;
        var r3: [96]u8 = undefined;
        try w.print("  {s} = klio_nat_range({d}, {s}, {s});\n", .{
            regName(c, b.dst.int(), &db3),
            @as(u32, if (b.op == .RangeTo) 0 else 1),
            boxExpr(c.types[b.lhs.int()], regName(c, b.lhs.int(), &lb3), &l3),
            boxExpr(c.types[b.rhs.int()], regName(c, b.rhs.int(), &rb3), &r3),
        });
        return;
    }
    if (dt == .object) {
        // Concatenation: either operand may be any value, rendered as Kotlin would render it.
        var db: [32]u8 = undefined;
        var lex: std.Io.Writer.Allocating = .init(gpa);
        defer lex.deinit();
        var rex2: std.Io.Writer.Allocating = .init(gpa);
        defer rex2.deinit();
        try renderExpr(gpa, m, prog, c, b.lhs.int(), &lex);
        try renderExpr(gpa, m, prog, c, b.rhs.int(), &rex2);
        try w.print("  {s} = klio_nat_concat({s}, {s});\n", .{
            regName(c, b.dst.int(), &db), lex.written(), rex2.written(),
        });
        return;
    }
    try writeArithBinOp(ctx, inst, dt);
}

/// A binary operator on machine types, keeping Kotlin's wrapping and shift masking.
fn writeArithBinOp(ctx: *const Body, inst: *const ir.Inst, dt: Ty) !void {
    const w = ctx.w;
    const c = ctx.c;
    const b = inst.BinOp;
    var lnb: [32]u8 = undefined;
    var rnb: [32]u8 = undefined;
    var dnb: [32]u8 = undefined;
    const ln = regName(c, b.lhs.int(), &lnb);
    const rn = regName(c, b.rhs.int(), &rnb);
    const dn = regName(c, b.dst.int(), &dnb);
    if (b.op == .UShr) {
        // C has no unsigned right shift of a signed value, so it runs in the unsigned type of the
        // same width; Kotlin masks the shift count where C leaves an over-wide shift undefined.
        const lt5 = c.types[b.lhs.int()];
        const ut5: []const u8 = if (lt5 == .i64) "uint64_t" else "uint32_t";
        try w.print("  {s} = ({s})(({s}){s} >> ({s} & {d}));\n", .{
            dn, dt.cName(), ut5, ln, rn,
            @as(u32, if (lt5 == .i64) 63 else 31),
        });
        return;
    }
    const op = cOp(b.op).?;
    if ((b.op == .Div or b.op == .Mod) and !dt.isFloat() and !isCmp(b.op)) {
        try w.print("  if ({s} == 0) klio_arith_zero();\n", .{rn});
        // The most negative value divided by -1 overflows: Kotlin wraps it, C leaves it undefined.
        if (wrapTy(dt)) |ut4| {
            if (b.op == .Div) {
                try w.print("  if ({s} == -1) {{ {s} = ({s})(0 - ({s}){s}); }} else\n", .{
                    rn, dn, dt.cName(), ut4, ln,
                });
            } else {
                try w.print("  if ({s} == -1) {{ {s} = 0; }} else\n", .{ rn, dn });
            }
        }
    }
    if (b.op == .Shl or b.op == .Shr) {
        // Kotlin masks the shift count; C leaves an over-wide shift undefined.
        const lt = c.types[b.lhs.int()];
        try w.print("  {s} = ({s})({s} {s} ({s} & {d}));\n", .{
            dn, dt.cName(), ln, op, rn,
            @as(u32, if (lt == .i64) 63 else 31),
        });
    } else if ((b.op == .Add or b.op == .Sub or b.op == .Mul) and wrapTy(dt) != null) {
        // Kotlin's integer arithmetic WRAPS where C leaves signed overflow undefined, so it runs in
        // the unsigned type of the same width. Only these three overflow that way.
        const ut2 = wrapTy(dt).?;
        try w.print("  {s} = ({s})(({s}){s} {s} ({s}){s});\n", .{
            dn, dt.cName(), ut2, ln, op, ut2, rn,
        });
    } else {
        const pt10: []const u8 = if (isCmp(b.op))
            promote(c.types[b.lhs.int()], c.types[b.rhs.int()]).?.cName()
        else
            dt.cName();
        try w.print("  {s} = ({s})(({s}){s} {s} ({s}){s});\n", .{
            dn, dt.cName(), pt10, ln, op, pt10, rn,
        });
    }
}

/// A unary operator, wrapping where Kotlin wraps.
fn writeUnOp(ctx: *const Body, inst: *const ir.Inst) !void {
    const w = ctx.w;
    const c = ctx.c;
    const u = inst.UnOp;
    const t = c.types[u.dst.int()];
    switch (u.op) {
        // Negating the most negative value overflows, which Kotlin wraps and C leaves undefined.
        .Neg => if (wrapTy(t)) |ut3| {
            try w.print("  r{d} = ({s})(0u - ({s})r{d});\n", .{
                u.dst.int(), t.cName(), ut3, u.operand.int(),
            });
        } else {
            try w.print("  r{d} = ({s})(-r{d});\n", .{ u.dst.int(), t.cName(), u.operand.int() });
        },
        .Plus => try w.print("  r{d} = ({s})r{d};\n", .{ u.dst.int(), t.cName(), u.operand.int() }),
        // Kotlin's `inc`/`dec` wrap; C leaves signed overflow undefined, so the step runs unsigned.
        .Inc, .Dec => {
            const step: []const u8 = if (u.op == .Inc) "+" else "-";
            if (wrapTy(t)) |ut6| {
                try w.print("  r{d} = ({s})(({s})r{d} {s} 1);\n", .{
                    u.dst.int(), t.cName(), ut6, u.operand.int(), step,
                });
            } else {
                try w.print("  r{d} = ({s})(r{d} {s} 1);\n", .{
                    u.dst.int(), t.cName(), u.operand.int(), step,
                });
            }
        },
    }
}

/// A cast: an exact test against every registered class the target reaches, then the runtime's.
fn writeCast(ctx: *const Body, inst: *const ir.Inst) !void {
    const w = ctx.w;
    const m = ctx.m;
    const c = ctx.c;
    const registered = ctx.registered;
    const ca = inst.Cast;
    var nb20: [32]u8 = undefined;
    var rb20: [32]u8 = undefined;
    var bx20: [96]u8 = undefined;
    const sn = regName(c, ca.src.int(), &rb20);
    const sv = boxExpr(c.types[ca.src.int()], sn, &bx20);
    const dn20 = regName(c, ca.dst.int(), &nb20);
    const tname = simpleName(ca.ty.name);
    try w.print("  {{ klio_value kc = {s};\n    uint32_t kt = klio_nat_class_of(kc);\n    (void)kt;\n    int32_t kok = ", .{sv});
    if (classIndexOfName(m, ca.ty)) |tc2| {
        if (!isBuiltinCls(tc2)) {
            for (registered) |cid| {
                if (!typeReaches(m, cid, tc2)) continue;
                try w.print("(kt == KCLS_{d}) || ", .{cid});
            }
        }
    }
    try w.print("klio_nat_is_type(kc, \"{s}\", 1);\n", .{tname});
    var ob20: [220]u8 = undefined;
    const dv = convExpr(.object, c.types[ca.dst.int()], "kc", &ob20);
    if (ca.safe) {
        try w.print("    {s} = kok ? {s} : klio_nat_null(); }}\n", .{ dn20, dv });
    } else {
        try w.print("    if (!kok) klio_cast_fail(\"{s}\", {d});\n    {s} = {s}; }}\n", .{
            tname, tname.len, dn20, dv,
        });
    }
}

fn writeInstanceOf(ctx: *const Body, inst: *const ir.Inst) !void {
    const w = ctx.w;
    const m = ctx.m;
    const c = ctx.c;
    const registered = ctx.registered;
    const io = inst.InstanceOf;
    // Registered classes whose type includes the one asked about get an exact test; anything
    // else answers from its representation.
    var nb19: [32]u8 = undefined;
    var rb19: [32]u8 = undefined;
    var bx19: [96]u8 = undefined;
    const target = classIndexOfName(m, io.ty);
    const iv = boxExpr(c.types[io.src.int()], regName(c, io.src.int(), &rb19), &bx19);
    try w.print("  {{ klio_value kc = {s};\n    uint32_t kt = klio_nat_class_of(kc);\n    (void)kt;\n    {s} = ", .{
        iv, regName(c, io.dst.int(), &nb19),
    });
    if (target) |tc| {
        if (!isBuiltinCls(tc)) {
            for (registered) |cid| {
                if (!typeReaches(m, cid, tc)) continue;
                try w.print("(kt == KCLS_{d}) || ", .{cid});
            }
        }
    }
    try w.print("klio_nat_is_type(kc, \"{s}\", {d}); }}\n", .{
        simpleName(io.ty.name),
        @as(u32, if (io.ty.nullable) 1 else 0),
    });
}

fn writeCallMember(ctx: *const Body, inst: *const ir.Inst) !void {
    const w = ctx.w;
    const m = ctx.m;
    const prog = ctx.prog;
    const c = ctx.c;
    const singletons = ctx.singletons;
    const cm = inst.CallMember;
    var nb: [32]u8 = undefined;
    var rb: [32]u8 = undefined;
    const recv = regName(c, cm.receiver.int(), &rb);
    // `toString()` on a value with no override of its own.
    if (isToStringCall(m.consts.items[cm.name.int()].String, cm.n_args) and
        rendersToString(m, prog, c.cls, cm.receiver.int()))
    {
        var bx10: [96]u8 = undefined;
        try w.print("  {s} = klio_nat_to_string({s});\n", .{
            regName(c, cm.dst.int(), &nb),
            boxExpr(c.types[cm.receiver.int()], recv, &bx10),
        });
        return;
    }
    // The iteration protocol on a builtin receiver, by name: the runtime picks the same handler.
    if (c.cls[cm.receiver.int()]) |brc| {
        if (isBuiltinCls(brc) and member_dispatch.hostFreeMemberAnswer(plainFieldName(m.consts.items[cm.name.int()].String)) != null) {
            try writeHostMemberCall(ctx, inst, recv);
            return;
        }
    }
    if (c.cls[cm.receiver.int()]) |rc| {
        if (rc == ARRAY_CLS) {
            try writeArrayMemberCall(ctx, inst, recv);
            return;
        }
        if (rc == LIST_CLS) {
            try writeListMemberCall(ctx, inst, recv);
            return;
        }
    }
    // A call written on a class NAME runs on that class's companion, the singleton receiver.
    if (companionReceiver(m, prog, c.types, c.cls, cm.receiver.int())) |cc7| {
        const mn7 = m.consts.items[cm.name.int()].String;
        const root7b = memberRoot(m, prog, cc7, plainFieldName(mn7), cm.n_args).?;
        try w.print("  {s} = kvirt_{d}(KO[{d}]", .{
            regName(c, cm.dst.int(), &nb), root7b.id.int(), singletonSlot(singletons, cc7, null).?,
        });
        var aj7: u32 = 0;
        while (aj7 < cm.n_args) : (aj7 += 1) {
            var ab7b: [32]u8 = undefined;
            try w.print(", {s}", .{regName(c, cm.args.int() + aj7, &ab7b)});
        }
        try w.writeAll(");\n");
        return;
    }
    if (numConv(m, cm) == null and c.cls[cm.receiver.int()] != null and
        !isBuiltinCls(c.cls[cm.receiver.int()].?))
    {
        try writeDeclaredMemberCall(ctx, inst, recv);
        return;
    }
    try w.print("  {s} = ({s}){s};\n", .{
        regName(c, cm.dst.int(), &nb), c.types[cm.dst.int()].cName(), recv,
    });
}

/// A member the runtime answers by name, with the receiver as its first argument.
fn writeHostMemberCall(ctx: *const Body, inst: *const ir.Inst, recv: []const u8) !void {
    const w = ctx.w;
    const m = ctx.m;
    const c = ctx.c;
    const cm = inst.CallMember;
    var nb: [32]u8 = undefined;
    try w.print("  {{ klio_value ma[{d}];\n    ma[0] = {s};\n", .{ cm.n_args + 1, recv });
    var khb: u32 = 0;
    while (khb < cm.n_args) : (khb += 1) {
        const ahb = cm.args.int() + khb;
        var abb: [32]u8 = undefined;
        var bbb: [96]u8 = undefined;
        try w.print("    ma[{d}] = {s};\n", .{
            khb + 1, boxExpr(c.types[ahb], regName(c, ahb, &abb), &bbb),
        });
    }
    var hbb: [320]u8 = undefined;
    var hob: [400]u8 = undefined;
    const hcall2 = try std.fmt.bufPrint(&hbb, "klio_nat_member(\"{s}\", ma, {d})", .{
        plainFieldName(m.consts.items[cm.name.int()].String), cm.n_args + 1,
    });
    try w.print("    {s} = {s}; }}\n", .{
        regName(c, cm.dst.int(), &nb),
        unboxExpr(c.types[cm.dst.int()], hcall2, &hob),
    });
}

fn writeArrayMemberCall(ctx: *const Body, inst: *const ir.Inst, recv: []const u8) !void {
    const w = ctx.w;
    const m = ctx.m;
    const c = ctx.c;
    const cm = inst.CallMember;
    var nb: [32]u8 = undefined;
    const an2 = m.consts.items[cm.name.int()].String;
    const aa4 = cm.args.int();
    var ab7: [32]u8 = undefined;
    if (std.mem.eql(u8, an2, "get")) {
        var gb7: [160]u8 = undefined;
        const g7 = try std.fmt.bufPrint(&gb7, "klio_nat_array_get({s}, {s})", .{ recv, regName(c, aa4, &ab7) });
        var ob7: [220]u8 = undefined;
        try w.print("  {s} = {s};\n", .{
            regName(c, cm.dst.int(), &nb), unboxExpr(c.types[cm.dst.int()], g7, &ob7),
        });
    } else {
        std.debug.assert(std.mem.eql(u8, an2, "set") and cm.n_args == 2);
        var vb7: [32]u8 = undefined;
        var bb7: [96]u8 = undefined;
        try w.print("  klio_nat_array_set({s}, {s}, {s});\n", .{
            recv, regName(c, aa4, &ab7),
            boxExpr(c.types[aa4 + 1], regName(c, aa4 + 1, &vb7), &bb7),
        });
    }
}

fn writeListMemberCall(ctx: *const Body, inst: *const ir.Inst, recv: []const u8) !void {
    const w = ctx.w;
    const m = ctx.m;
    const c = ctx.c;
    const cm = inst.CallMember;
    var nb: [32]u8 = undefined;
    const mn = m.consts.items[cm.name.int()].String;
    const a0 = cm.args.int();
    var ab: [32]u8 = undefined;
    var bb: [96]u8 = undefined;
    if (std.mem.eql(u8, mn, "get")) {
        var gb: [160]u8 = undefined;
        const g = try std.fmt.bufPrint(&gb, "klio_nat_list_get({s}, {s})", .{ recv, regName(c, a0, &ab) });
        var ob: [220]u8 = undefined;
        try w.print("  {s} = {s};\n", .{
            regName(c, cm.dst.int(), &nb), unboxExpr(c.types[cm.dst.int()], g, &ob),
        });
    } else if (std.mem.eql(u8, mn, "add")) {
        try w.print("  klio_nat_list_add({s}, {s});\n", .{
            recv, boxExpr(c.types[a0], regName(c, a0, &ab), &bb),
        });
        try w.print("  {s} = 1;\n", .{regName(c, cm.dst.int(), &nb)});
    } else {
        var vb: [32]u8 = undefined;
        try w.print("  klio_nat_list_set({s}, {s}, {s});\n", .{
            recv, regName(c, a0, &ab),
            boxExpr(c.types[a0 + 1], regName(c, a0 + 1, &vb), &bb),
        });
        try w.print("  {s} = klio_nat_box_unit();\n", .{regName(c, cm.dst.int(), &nb)});
    }
}

/// A member of a compiled class: a property holding a lambda, or a dispatch through its slot.
fn writeDeclaredMemberCall(ctx: *const Body, inst: *const ir.Inst, recv: []const u8) !void {
    const gpa = ctx.gpa;
    const w = ctx.w;
    const m = ctx.m;
    const prog = ctx.prog;
    const c = ctx.c;
    const cm = inst.CallMember;
    var nb: [32]u8 = undefined;
    const rc9 = c.cls[cm.receiver.int()].?;
    const mn9 = m.consts.items[cm.name.int()].String;
    if (fieldIndex(prog, rc9, mn9)) |fidx9| {
        const fds9 = prog.of(rc9).?;
        var call14: std.Io.Writer.Allocating = .init(gpa);
        defer call14.deinit();
        try call14.writer.print("klam_call_{d}(klio_nat_get({s}, {d})", .{
            funcClsArity(fds9[fidx9].cls.?).?, recv, fidx9,
        });
        var aj14: u32 = 0;
        while (aj14 < cm.n_args) : (aj14 += 1) {
            const ar14 = cm.args.int() + aj14;
            var ab14: [32]u8 = undefined;
            var bb18: [96]u8 = undefined;
            try call14.writer.print(", {s}", .{
                boxExpr(c.types[ar14], regName(c, ar14, &ab14), &bb18),
            });
        }
        try call14.writer.writeByte(')');
        var ob14: [400]u8 = undefined;
        try w.print("  {s} = {s};\n", .{
            regName(c, cm.dst.int(), &nb),
            unboxExpr(c.types[cm.dst.int()], call14.written(), &ob14),
        });
        return;
    }
    const root6 = memberRoot(m, prog, rc9, plainFieldName(mn9), cm.n_args) orelse {
        var bx9: [96]u8 = undefined;
        try w.print("  {s} = klio_nat_to_string({s});\n", .{
            regName(c, cm.dst.int(), &nb),
            boxExpr(c.types[cm.receiver.int()], recv, &bx9),
        });
        return;
    };
    try w.print("  {s} = kvirt_{d}({s}", .{
        regName(c, cm.dst.int(), &nb), root6.id.int(), recv,
    });
    var aj5: u32 = 0;
    while (aj5 < cm.n_args) : (aj5 += 1) {
        var ab5: [32]u8 = undefined;
        try w.print(", {s}", .{regName(c, cm.args.int() + aj5, &ab5)});
    }
    try w.writeAll(");\n");
}

fn writeCallVirtual(ctx: *const Body, inst: *const ir.Inst) !void {
    const w = ctx.w;
    const m = ctx.m;
    const prog = ctx.prog;
    const c = ctx.c;
    const slots = ctx.slots;
    const cv = inst.CallVirtual;
    var nb: [32]u8 = undefined;
    var rb: [32]u8 = undefined;
    const recv = regName(c, cv.receiver.int(), &rb);
    if (m.funcById(ir.FuncId.from(cv.slot.int()))) |tsd2| {
        if (isToStringCall(tsd2.name, cv.n_args) and
            rendersToString(m, prog, c.cls, cv.receiver.int()))
        {
            var bx11: [96]u8 = undefined;
            try w.print("  {s} = klio_nat_to_string({s});\n", .{
                regName(c, cv.dst.int(), &nb),
                boxExpr(c.types[cv.receiver.int()], recv, &bx11),
            });
            return;
        }
    }
    if (try writeHostVirtualCall(ctx, inst, recv)) return;
    if (isDispatched(slots, cv.slot.int())) {
        try w.print("  {s} = kvirt_{d}({s}", .{
            regName(c, cv.dst.int(), &nb), cv.slot.int(), recv,
        });
        var aj2: u32 = 0;
        while (aj2 < cv.n_args) : (aj2 += 1) {
            var ab3: [32]u8 = undefined;
            try w.print(", {s}", .{regName(c, cv.args.int() + aj2, &ab3)});
        }
        try w.writeAll(");\n");
        return;
    }
    if (c.cls[cv.receiver.int()]) |rc| {
        if (rc == LIST_CLS) {
            try writeListVirtualCall(ctx, inst, recv);
            return;
        }
    }
    try w.print("  {s} = ({s}){s};\n", .{
        regName(c, cv.dst.int(), &nb), c.types[cv.dst.int()].cName(), recv,
    });
}

/// A builtin receiver's member, answered by the declaration's own name. True when it wrote it.
fn writeHostVirtualCall(ctx: *const Body, inst: *const ir.Inst, recv: []const u8) !bool {
    const w = ctx.w;
    const m = ctx.m;
    const c = ctx.c;
    const cv = inst.CallVirtual;
    var nb: [32]u8 = undefined;
    if (c.cls[cv.receiver.int()]) |rc0| {
        if (isBuiltinCls(rc0)) host: {
            const decl0 = m.funcById(ir.FuncId.from(cv.slot.int())) orelse break :host;
            if (hostMemberOp(decl0) == null) break :host;
            // The runtime reads the declaration's name to pick the operation, receiver first.
            try w.print("  {{ klio_value ma[{d}];\n    ma[0] = {s};\n", .{ cv.n_args + 1, recv });
            var kh: u32 = 0;
            while (kh < cv.n_args) : (kh += 1) {
                const ah = cv.args.int() + kh;
                var ahb: [32]u8 = undefined;
                var bhb: [96]u8 = undefined;
                try w.print("    ma[{d}] = {s};\n", .{
                    kh + 1, boxExpr(c.types[ah], regName(c, ah, &ahb), &bhb),
                });
            }
            var hb: [320]u8 = undefined;
            var hob: [400]u8 = undefined;
            const hcall = try std.fmt.bufPrint(&hb, "klio_nat_member(\"{s}\", ma, {d})", .{ decl0.fqn, cv.n_args + 1 });
            try w.print("    {s} = {s}; }}\n", .{
                regName(c, cv.dst.int(), &nb),
                unboxExpr(c.types[cv.dst.int()], hcall, &hob),
            });
            return true;
        }
    }
    return false;
}

/// A list member through a slot: the runtime's calls where one exists, the interpreter's entry.
fn writeListVirtualCall(ctx: *const Body, inst: *const ir.Inst, recv: []const u8) !void {
    const w = ctx.w;
    const m = ctx.m;
    const c = ctx.c;
    const cv = inst.CallVirtual;
    var nb: [32]u8 = undefined;
    const mn = listMemberName(m, cv.slot).?;
    const a0 = cv.args.int();
    var ab: [32]u8 = undefined;
    var bb: [96]u8 = undefined;
    if (std.mem.eql(u8, mn, "get")) {
        var gb: [160]u8 = undefined;
        const g = try std.fmt.bufPrint(&gb, "klio_nat_list_get({s}, {s})", .{ recv, regName(c, a0, &ab) });
        var ob: [220]u8 = undefined;
        try w.print("  {s} = {s};\n", .{
            regName(c, cv.dst.int(), &nb), unboxExpr(c.types[cv.dst.int()], g, &ob),
        });
    } else if (std.mem.eql(u8, mn, "add") and cv.n_args == 1) {
        try w.print("  klio_nat_list_add({s}, {s});\n", .{
            recv, boxExpr(c.types[a0], regName(c, a0, &ab), &bb),
        });
        try w.print("  {s} = 1;\n", .{regName(c, cv.dst.int(), &nb)});
    } else if (std.mem.eql(u8, mn, "set") and cv.n_args == 2) {
        var vb: [32]u8 = undefined;
        try w.print("  klio_nat_list_set({s}, {s}, {s});\n", .{
            recv, regName(c, a0, &ab),
            boxExpr(c.types[a0 + 1], regName(c, a0 + 1, &vb), &bb),
        });
        try w.print("  {s} = klio_nat_box_unit();\n", .{regName(c, cv.dst.int(), &nb)});
    } else {
        // The interpreter's own entry, receiver first.
        const decl2 = m.funcById(ir.FuncId.from(cv.slot.int())).?;
        const sym2 = stdlibEntry(decl2).?;
        try w.print("  {{ klio_value sa[{d}];\n    sa[0] = {s};\n", .{ cv.n_args + 1, recv });
        var kv2: u32 = 0;
        while (kv2 < cv.n_args) : (kv2 += 1) {
            const ar12 = cv.args.int() + kv2;
            var ab12: [32]u8 = undefined;
            var bb12: [96]u8 = undefined;
            try w.print("    sa[{d}] = {s};\n", .{
                kv2 + 1, boxExpr(c.types[ar12], regName(c, ar12, &ab12), &bb12),
            });
        }
        var ob15: [300]u8 = undefined;
        var sb15: [260]u8 = undefined;
        const sc15 = try std.fmt.bufPrint(&sb15, "klio_nat_stdlib(\"{s}\", sa, {d})", .{ sym2, cv.n_args + 1 });
        try w.print("    {s} = {s}; }}\n", .{
            regName(c, cv.dst.int(), &nb),
            unboxExpr(c.types[cv.dst.int()], sc15, &ob15),
        });
    }
}

fn writeLoadGlobal(ctx: *const Body, inst: *const ir.Inst) !void {
    const w = ctx.w;
    const m = ctx.m;
    const c = ctx.c;
    const globals = ctx.globals;
    const singletons = ctx.singletons;
    const lambdas = ctx.lambdas;
    const lg = inst.LoadGlobal;
    const gn = m.consts.items[lg.name.int()].String;
    if (staticClassOf(c.types, c.cls, lg.dst.int()) != null) return;
    if (c.lam[lg.dst.int()]) |li10| {
        var nb23: [32]u8 = undefined;
        try w.print("  {s} = KL[{d}];\n", .{
            regName(c, lg.dst.int(), &nb23), lambdaSingletonSlot(lambdas, li10.body).?,
        });
        return;
    }
    if (c.cls[lg.dst.int()]) |rc| {
        if (!isBuiltinCls(rc) and singletonSlot(singletons, rc, null) != null) {
            var nb2: [32]u8 = undefined;
            try w.print("  {s} = KO[{d}];\n", .{
                regName(c, lg.dst.int(), &nb2), singletonSlot(singletons, rc, null).?,
            });
            return;
        }
    }
    const gi = globalIndex(globals, gn).?;
    var nb: [32]u8 = undefined;
    var ob: [96]u8 = undefined;
    var src: [32]u8 = undefined;
    const from = try std.fmt.bufPrint(&src, "KG[{d}]", .{gi});
    try w.print("  {s} = {s};\n", .{
        regName(c, lg.dst.int(), &nb), unboxExpr(c.types[lg.dst.int()], from, &ob),
    });
}

/// A lambda literal: its one instance, or a fresh closure holding the captures.
fn writeAstLambda(ctx: *const Body, inst: *const ir.Inst) !void {
    const w = ctx.w;
    const c = ctx.c;
    const lambdas = ctx.lambdas;
    const al3 = inst.AstLambda;
    if (c.types[al3.dst.int()] != .object) {
        // Nothing to materialise: every use is a direct call passing the captures itself.
        return;
    }
    var nb12: [32]u8 = undefined;
    const ldst = regName(c, al3.dst.int(), &nb12);
    if (al3.captures.len == 0) {
        // The literal's one instance, built before the program runs: two evaluations are one object.
        try w.print("  {s} = KL[{d}];\n", .{
            ldst, lambdaSingletonSlot(lambdas, al3.body_func.?).?,
        });
        return;
    }
    try w.print("  {s} = klio_nat_alloc_instance(KLAM_{d});\n", .{ ldst, al3.body_func.?.int() });
    for (al3.captures, 0..) |cr12, ci12| {
        var cb12: [32]u8 = undefined;
        var bb16: [96]u8 = undefined;
        try w.print("  klio_nat_set({s}, {d}, {s});\n", .{
            ldst, ci12,
            boxExpr(c.types[cr12.int()], regName(c, cr12.int(), &cb12), &bb16),
        });
    }
}

/// A call on a value the emitter could not resolve, through the lambda class's dispatcher.
fn writeValueDispatchCall(ctx: *const Body, inst: *const ir.Inst) !void {
    const gpa = ctx.gpa;
    const w = ctx.w;
    const c = ctx.c;
    const cvm = inst.CallValueOrMember;
    var nb14: [32]u8 = undefined;
    var fb14: [32]u8 = undefined;
    var call15: std.Io.Writer.Allocating = .init(gpa);
    defer call15.deinit();
    try call15.writer.print("klam_call_{d}({s}", .{
        funcClsArity(c.cls[cvm.callee.int()].?).?,
        regName(c, cvm.callee.int(), &fb14),
    });
    var aj15: u32 = 0;
    while (aj15 < cvm.n_args) : (aj15 += 1) {
        const ar15 = cvm.args.int() + aj15;
        var ab15: [32]u8 = undefined;
        var bb19: [96]u8 = undefined;
        try call15.writer.print(", {s}", .{
            boxExpr(c.types[ar15], regName(c, ar15, &ab15), &bb19),
        });
    }
    try call15.writer.writeByte(')');
    var ob15: [400]u8 = undefined;
    try w.print("  {s} = {s};\n", .{
        regName(c, cvm.dst.int(), &nb14),
        unboxExpr(c.types[cvm.dst.int()], call15.written(), &ob15),
    });
}

/// A call on a callable register: the dispatcher, or the body the emitter knows it holds.
fn writeCallValue(ctx: *const Body, inst: *const ir.Inst) !void {
    const gpa = ctx.gpa;
    const w = ctx.w;
    const m = ctx.m;
    const c = ctx.c;
    const cv2 = inst.CallValue;
    if (c.types[cv2.callee.int()] == .object) {
        var nb13: [32]u8 = undefined;
        var fb13: [32]u8 = undefined;
        var call13: std.Io.Writer.Allocating = .init(gpa);
        defer call13.deinit();
        try call13.writer.print("klam_call_{d}({s}", .{
            funcClsArity(c.cls[cv2.callee.int()].?).?,
            regName(c, cv2.callee.int(), &fb13),
        });
        var aj13: u32 = 0;
        while (aj13 < cv2.n_args) : (aj13 += 1) {
            const ar13 = cv2.args.int() + aj13;
            var ab13: [32]u8 = undefined;
            var bb17: [96]u8 = undefined;
            try call13.writer.print(", {s}", .{
                boxExpr(c.types[ar13], regName(c, ar13, &ab13), &bb17),
            });
        }
        try call13.writer.writeByte(')');
        var ob13: [400]u8 = undefined;
        try w.print("  {s} = {s};\n", .{
            regName(c, cv2.dst.int(), &nb13),
            unboxExpr(c.types[cv2.dst.int()], call13.written(), &ob13),
        });
        return;
    }
    const li = c.lam[cv2.callee.int()].?;
    const bf = m.funcById(li.body).?;
    var nb3: [32]u8 = undefined;
    try w.print("  {s} = ", .{regName(c, cv2.dst.int(), &nb3)});
    try writeSymbol(w, bf);
    try w.writeByte('(');
    for (li.captures, 0..) |cr, ci3| {
        if (ci3 != 0) try w.writeAll(", ");
        var cb3: [32]u8 = undefined;
        try w.print("{s}", .{regName(c, cr.int(), &cb3)});
    }
    var aj3: u32 = 0;
    while (aj3 < cv2.n_args) : (aj3 += 1) {
        if (li.captures.len != 0 or aj3 != 0) try w.writeAll(", ");
        var ab5: [32]u8 = undefined;
        try w.print("{s}", .{regName(c, cv2.args.int() + aj3, &ab5)});
    }
    var aj4: usize = cv2.n_args;
    while (aj4 < bf.params.len) : (aj4 += 1) {
        if (li.captures.len != 0 or aj4 != 0) try w.writeAll(", ");
        const pt4: Ty = tyOf(bf.params[aj4].ty) orelse .object;
        if (pt4 == .object) {
            try w.writeAll("klio_nat_box_unit()");
        } else {
            try w.writeAll("0");
        }
    }
    try w.writeAll(");\n");
}

/// A static call: an intrinsic the emitter writes itself, or the callee by symbol.
fn writeCall(ctx: *const Body, inst: *const ir.Inst) !void {
    const gpa = ctx.gpa;
    const w = ctx.w;
    const m = ctx.m;
    const prog = ctx.prog;
    const c = ctx.c;
    const call = inst.Call;
    const callee = m.funcById(call.func).?;
    if (scalarIntrinsic(callee)) |si| {
        try writeScalarIntrinsicCall(ctx, inst, si);
        return;
    }
    if (isLaunch(callee)) {
        const lr6 = call.args.int() + call.n_args - 1;
        var db7: [32]u8 = undefined;
        var lb7: [32]u8 = undefined;
        try w.print("  {s} = klio_nat_coro_launch({s});\n", .{
            regName(c, call.dst.int(), &db7), regName(c, lr6, &lb7),
        });
        return;
    }
    if (isRunBlocking(callee)) {
        try writeRunBlockingCall(ctx, inst);
        return;
    }
    if (isArrayOfNulls(callee)) {
        var db4: [32]u8 = undefined;
        var nb16: [32]u8 = undefined;
        try w.print("  {s} = klio_nat_ref_array_sized({s});\n", .{
            regName(c, call.dst.int(), &db4), regName(c, call.args.int(), &nb16),
        });
        return;
    }
    if (arrayOfIntrinsic(callee)) |maybe_kind| {
        try writeArrayOfCall(ctx, inst, maybe_kind);
        return;
    }
    if (listIntrinsic(callee)) |kind| {
        try writeListOfCall(ctx, inst, kind);
        return;
    }
    if (isPrintln(callee)) {
        const a0 = call.args.int();
        // Everything prints through the runtime's renderer: how Kotlin renders a value is
        // the interpreter's own code, and printf's buffered stream interleaves wrongly.
        var rex: std.Io.Writer.Allocating = .init(gpa);
        defer rex.deinit();
        try renderExpr(gpa, m, prog, c, a0, &rex);
        try w.print("  klio_nat_println({s});\n", .{rex.written()});
    } else if (!callee.hasBody()) {
        try writeStdlibCall(ctx, inst, callee);
    } else {
        try writeDeclaredCall(ctx, inst, callee);
    }
}

fn writeScalarIntrinsicCall(ctx: *const Body, inst: *const ir.Inst, si: ScalarIntrinsic) !void {
    const w = ctx.w;
    const c = ctx.c;
    const call = inst.Call;
    var db2: [32]u8 = undefined;
    var a1b: [32]u8 = undefined;
    var a2b: [32]u8 = undefined;
    const sa = call.args.int();
    const sdst = regName(c, call.dst.int(), &db2);
    const x1 = regName(c, sa, &a1b);
    switch (si) {
        .print => {
            var bx6: [96]u8 = undefined;
            try w.print("  klio_nat_print({s});\n", .{boxExpr(c.types[sa], x1, &bx6)});
        },
        .max, .min => {
            const x2 = regName(c, sa + 1, &a2b);
            try w.print("  {s} = ({s} {s} {s}) ? {s} : {s};\n", .{
                sdst, x1, if (si == .max) ">" else "<", x2, x1, x2,
            });
        },
        // Kotlin's `abs` on the most negative value returns it unchanged, so the negation runs unsigned.
        .abs => try w.print("  {s} = ({s} < 0) ? ({s})(0u{s} - ({s}){s}) : {s};\n", .{
            sdst, x1, c.types[sa].cName(),
            if (c.types[sa] == .i64) "ll" else "",
            if (c.types[sa] == .i64) "uint64_t" else "uint32_t",
            x1, x1,
        }),
    }
}

/// `runBlocking`: the block's frame, handed to the driver that pumps it.
fn writeRunBlockingCall(ctx: *const Body, inst: *const ir.Inst) !void {
    const w = ctx.w;
    const m = ctx.m;
    const c = ctx.c;
    const call = inst.Call;
    const br2 = call.args.int() + call.n_args - 1;
    const li4 = c.lam[br2].?;
    const bfn4 = m.funcById(li4.body).?;
    var db6: [32]u8 = undefined;
    try w.print("  {s} = klio_nat_run_blocking(kco_{d}, kcf_{d}(", .{
        regName(c, call.dst.int(), &db6), bfn4.id.int(), bfn4.id.int(),
    });
    for (li4.captures, 0..) |cr6, ci6| {
        if (ci6 != 0) try w.writeAll(", ");
        var cb6: [32]u8 = undefined;
        try w.print("{s}", .{regName(c, cr6.int(), &cb6)});
    }
    // The block's own parameters, a receiver slot the lowering always gives it, start unset.
    var pk6: usize = 0;
    while (pk6 < bfn4.params.len) : (pk6 += 1) {
        if (pk6 != 0 or li4.captures.len != 0) try w.writeAll(", ");
        const pt6: Ty = tyOf(bfn4.params[pk6].ty) orelse .object;
        var zb6: [64]u8 = undefined;
        try w.print("{s}", .{if (pt6 == .object) "klio_nat_box_unit()" else boxExpr(.unit, "0", &zb6)});
    }
    try w.writeAll("));\n");
}

fn writeArrayOfCall(ctx: *const Body, inst: *const ir.Inst, maybe_kind: ?u32) !void {
    const w = ctx.w;
    const c = ctx.c;
    const call = inst.Call;
    var db3: [32]u8 = undefined;
    const adst = regName(c, call.dst.int(), &db3);
    if (call.n_args == 0) {
        if (maybe_kind) |k3| {
            try w.print("  {s} = klio_nat_prim_array({d}, 0);\n", .{ adst, k3 });
        } else {
            try w.print("  {s} = klio_nat_ref_array(0, 0);\n", .{adst});
        }
        return;
    }
    try w.print("  {{ klio_value av[{d}];\n", .{call.n_args});
    var ka4: u32 = 0;
    while (ka4 < call.n_args) : (ka4 += 1) {
        const ar4 = call.args.int() + ka4;
        var ab8: [32]u8 = undefined;
        var bb8: [96]u8 = undefined;
        try w.print("    av[{d}] = {s};\n", .{
            ka4, boxExpr(c.types[ar4], regName(c, ar4, &ab8), &bb8),
        });
    }
    if (maybe_kind) |k4| {
        try w.print("    {s} = klio_nat_prim_array_of({d}, av, {d}); }}\n", .{ adst, k4, call.n_args });
    } else {
        try w.print("    {s} = klio_nat_ref_array(av, {d}); }}\n", .{ adst, call.n_args });
    }
}

fn writeListOfCall(ctx: *const Body, inst: *const ir.Inst, kind: ListIntrinsic) !void {
    const w = ctx.w;
    const c = ctx.c;
    const call = inst.Call;
    var db: [32]u8 = undefined;
    const dst = regName(c, call.dst.int(), &db);
    if (call.n_args == 0) {
        try w.print("  {s} = {s}(0, 0);\n", .{
            dst, if (kind == .list_of) "klio_nat_list" else "klio_nat_mutable_list",
        });
        return;
    }
    try w.print("  {{ klio_value ev[{d}];\n", .{call.n_args});
    var k: u32 = 0;
    while (k < call.n_args) : (k += 1) {
        const ar = call.args.int() + k;
        var ab: [32]u8 = undefined;
        var bb: [96]u8 = undefined;
        try w.print("    ev[{d}] = {s};\n", .{
            k, boxExpr(c.types[ar], regName(c, ar, &ab), &bb),
        });
    }
    try w.print("    {s} = {s}(ev, {d}); }}\n", .{
        dst, if (kind == .list_of) "klio_nat_list" else "klio_nat_mutable_list", call.n_args,
    });
}

/// The interpreter's own entry, called by name with the arguments boxed.
fn writeStdlibCall(ctx: *const Body, inst: *const ir.Inst, callee: *const ir.Func) !void {
    const w = ctx.w;
    const c = ctx.c;
    const call = inst.Call;
    const sym = stdlibEntry(callee).?;
    var db11: [32]u8 = undefined;
    if (call.n_args == 0) {
        var ob13: [200]u8 = undefined;
        var sb13: [220]u8 = undefined;
        const sc13 = try std.fmt.bufPrint(&sb13, "klio_nat_stdlib(\"{s}\", 0, 0)", .{sym});
        try w.print("  {s} = {s};\n", .{
            regName(c, call.dst.int(), &db11),
            unboxExpr(c.types[call.dst.int()], sc13, &ob13),
        });
        return;
    }
    try w.print("  {{ klio_value sa[{d}];\n", .{call.n_args});
    var ks11: u32 = 0;
    while (ks11 < call.n_args) : (ks11 += 1) {
        const ar11 = call.args.int() + ks11;
        var ab11: [32]u8 = undefined;
        var bb11: [96]u8 = undefined;
        try w.print("    sa[{d}] = {s};\n", .{
            ks11, boxExpr(c.types[ar11], regName(c, ar11, &ab11), &bb11),
        });
    }
    var ob14: [300]u8 = undefined;
    var sb14: [260]u8 = undefined;
    const sc14 = try std.fmt.bufPrint(&sb14, "klio_nat_stdlib(\"{s}\", sa, {d})", .{ sym, call.n_args });
    try w.print("    {s} = {s}; }}\n", .{
        regName(c, call.dst.int(), &db11),
        unboxExpr(c.types[call.dst.int()], sc14, &ob14),
    });
}

fn writeDeclaredCall(ctx: *const Body, inst: *const ir.Inst, callee: *const ir.Func) !void {
    const gpa = ctx.gpa;
    const w = ctx.w;
    const m = ctx.m;
    const prog = ctx.prog;
    const c = ctx.c;
    const accepted = ctx.accepted;
    const points = ctx.points;
    const call = inst.Call;
    // Arguments go to the callee in ITS order; an unbound parameter runs its thunk into a local.
    const bnd2 = bindCallArgs(m, callee.params, call.args.int(), call.n_args, call.arg_names).?;
    try writeDefaultThunks(ctx, inst, callee, &bnd2);
    // A SUSPENDING call may not come back. The state is saved before it runs; if the callee
    // suspends, this frame records its own continuation and answers SUSPENDED in turn.
    if (suspendIndex(points, inst)) |sp| {
        try writeSuspendingCall(ctx, inst, callee, &bnd2, sp);
        return;
    }
    // The result register may hold a reference where the callee returns a machine type.
    const cret = acceptedRet(accepted, callee) orelse funcRetTy2(m, callee) orelse .unit;
    const dwant = c.types[call.dst.int()];
    // A `vararg` parameter takes ONE array holding the trailing arguments.
    if (bnd2.vararg_param) |vp2| {
        try writeVarargArray(ctx, inst, callee, &bnd2, vp2);
    }
    var db: [32]u8 = undefined;
    // The call is built whole, then converted: a Unit-answering callee still has to RUN.
    var callx: std.Io.Writer.Allocating = .init(gpa);
    defer callx.deinit();
    const cw = &callx.writer;
    try writeSymbol(cw, callee);
    try cw.writeByte('(');
    var k: u32 = 0;
    while (k < bnd2.n) : (k += 1) {
        if (k != 0) try cw.writeAll(", ");
        if (bnd2.vararg_param != null and bnd2.vararg_param.? == k) {
            try cw.print("kva{d}", .{call.dst.int()});
            continue;
        }
        if (bnd2.regs[k]) |br2| {
            var ab: [32]u8 = undefined;
            var cb14: [96]u8 = undefined;
            const pwant = acceptedParamTy(accepted, callee, k) orelse paramTy(callee.params[k]);
            try cw.print("{s}", .{
                convExpr(c.types[br2], pwant, regName(c, br2, &ab), &cb14),
            });
            continue;
        }
        // The parameter's own type decides: a thunk's scalar arrives boxed at a reference parameter.
        const want4: Ty = paramTy(callee.params[k]);
        const dfn4 = m.funcById(prog.defaultThunk(callee.id, k).?).?;
        const have4 = acceptedRet(accepted, dfn4) orelse funcRetTy2(m, dfn4).?;
        var tb4: [48]u8 = undefined;
        const tn4 = try std.fmt.bufPrint(&tb4, "kd{d}_{d}", .{ call.dst.int(), k });
        var bx4: [96]u8 = undefined;
        if (want4 == .object and have4 != .object) {
            try cw.print("{s}", .{boxExpr(have4, tn4, &bx4)});
        } else {
            try cw.print("{s}", .{tn4});
        }
    }
    try cw.writeAll(")");
    var cx: [420]u8 = undefined;
    try w.print("  {s} = {s};\n", .{
        regName(c, call.dst.int(), &db),
        convExpr(cret, dwant, callx.written(), &cx),
    });
}

fn writeDefaultThunks(ctx: *const Body, inst: *const ir.Inst, callee: *const ir.Func, bnd2: *const ArgBinding) !void {
    const gpa = ctx.gpa;
    const w = ctx.w;
    const m = ctx.m;
    const prog = ctx.prog;
    const c = ctx.c;
    const accepted = ctx.accepted;
    const call = inst.Call;
    var di2: u32 = 0;
    while (di2 < bnd2.n) : (di2 += 1) {
        if (bnd2.regs[di2] != null) continue;
        // A `vararg` takes the array built below, not a default thunk.
        if (bnd2.vararg_param != null and bnd2.vararg_param.? == di2) continue;
        const dfn = m.funcById(prog.defaultThunk(callee.id, di2).?).?;
        const dt2 = acceptedRet(accepted, dfn) orelse funcRetTy2(m, dfn).?;
        var dsym: std.Io.Writer.Allocating = .init(gpa);
        defer dsym.deinit();
        try writeSymbol(&dsym.writer, dfn);
        try w.print("  {s} kd{d}_{d} = {s}(", .{ dt2.cName(), call.dst.int(), di2, dsym.written() });
        var dk: u32 = 0;
        while (dk < di2) : (dk += 1) {
            if (dk != 0) try w.writeAll(", ");
            if (bnd2.regs[dk]) |br| {
                var ab3: [32]u8 = undefined;
                try w.print("{s}", .{regName(c, br, &ab3)});
            } else {
                try w.print("kd{d}_{d}", .{ call.dst.int(), dk });
            }
        }
        try w.writeAll(");\n");
    }
}

/// A call that may not come back: state saved, the park answering SUSPENDED, the resume label.
fn writeSuspendingCall(ctx: *const Body, inst: *const ir.Inst, callee: *const ir.Func, bnd2: *const ArgBinding, sp: u32) !void {
    const w = ctx.w;
    const c = ctx.c;
    const f = ctx.f;
    const accepted = ctx.accepted;
    const call = inst.Call;
    var db9: [32]u8 = undefined;
    if (isDelay(callee)) {
        // The wait IS the suspension: it records the continuation and answers SUSPENDED.
        var mb9: [32]u8 = undefined;
        var cb10: [96]u8 = undefined;
        const mr9 = call.args.int();
        try w.print("  fr->st = {d};\n  return klio_nat_coro_delay({s}, kco_{d}, fr);\n", .{
            sp + 1,
            convExpr(c.types[mr9], .i64, regName(c, mr9, &mb9), &cb10),
            f.id.int(),
        });
        var ob11: [200]u8 = undefined;
        try w.print("RS{d}:;\n  {s} = {s};\n", .{
            sp,
            regName(c, call.dst.int(), &db9),
            unboxExpr(c.types[call.dst.int()], "resumed", &ob11),
        });
        return;
    }
    try w.print("  fr->st = {d};\n  {{ klio_value sv = ", .{sp + 1});
    try writeSymbol(w, callee);
    try w.writeByte('(');
    var sk: u32 = 0;
    while (sk < bnd2.n) : (sk += 1) {
        if (sk != 0) try w.writeAll(", ");
        if (bnd2.regs[sk]) |br9| {
            var ab9: [32]u8 = undefined;
            var cb9: [96]u8 = undefined;
            const pw9 = acceptedParamTy(accepted, callee, sk) orelse
                (tyOf(callee.params[sk].ty) orelse .object);
            try w.print("{s}", .{convExpr(c.types[br9], pw9, regName(c, br9, &ab9), &cb9)});
        } else {
            try w.writeAll("klio_nat_box_unit()");
        }
    }
    try w.writeAll(");\n");
    try w.print("    if (klio_nat_is_suspended(sv)) return klio_nat_coro_park(kco_{d}, fr);\n", .{f.id.int()});
    var ob9: [200]u8 = undefined;
    try w.print("    {s} = {s}; }}\n", .{
        regName(c, call.dst.int(), &db9),
        unboxExpr(c.types[call.dst.int()], "sv", &ob9),
    });
    try w.print("  goto RD{d};\n", .{sp});
    // The resume lands here with the value the suspension produced, both arms on one register.
    try w.print("RS{d}:;\n", .{sp});
    var ob10: [200]u8 = undefined;
    try w.print("  {s} = {s};\n", .{
        regName(c, call.dst.int(), &db9),
        unboxExpr(c.types[call.dst.int()], "resumed", &ob10),
    });
    try w.print("RD{d}:;\n", .{sp});
    return;
}

fn writeVarargArray(ctx: *const Body, inst: *const ir.Inst, callee: *const ir.Func, bnd2: *const ArgBinding, vp2: u32) !void {
    const w = ctx.w;
    const c = ctx.c;
    const call = inst.Call;
    const vt = tyOf(callee.params[vp2].ty) orelse Ty.object;
    const vkind = primKindOfTy(vt);
    try w.print("  klio_value kva{d};\n  {{ klio_value ve[{d}];\n", .{
        call.dst.int(), if (bnd2.vararg_n == 0) @as(u32, 1) else bnd2.vararg_n,
    });
    var vi: u32 = 0;
    while (vi < bnd2.vararg_n) : (vi += 1) {
        const vr = bnd2.vararg_base + vi;
        var vab: [32]u8 = undefined;
        var vbb: [96]u8 = undefined;
        try w.print("    ve[{d}] = {s};\n", .{
            vi, boxExpr(c.types[vr], regName(c, vr, &vab), &vbb),
        });
    }
    if (vkind) |kk9| {
        try w.print("    kva{d} = klio_nat_prim_array_of({d}, ve, {d}); }}\n", .{
            call.dst.int(), kk9, bnd2.vararg_n,
        });
    } else {
        try w.print("    kva{d} = klio_nat_ref_array(ve, {d}); }}\n", .{
            call.dst.int(), bnd2.vararg_n,
        });
    }
}

/// How the block leaves: a jump, a branch, a throw, or the return that gives back the frame.
fn writeTerminator(ctx: *const Body, blk: *const ir.Block, bi: usize, has_catch: bool) !void {
    const w = ctx.w;
    const c = ctx.c;
    const uses_objects = ctx.uses_objects;
    const uses_try = ctx.uses_try;
    switch (blk.terminator) {
        .Goto => |g| {
            // A jump to a block at or before this one closes a loop, where an allocating body would
            // otherwise run to the end of the heap before anything could collect.
            if (uses_objects and g.int() <= bi) try w.writeAll("  klio_nat_safepoint();\n");
            try w.print("  goto B{d};\n", .{g.int()});
        },
        .Branch => |br| {
            var cb: [32]u8 = undefined;
            var ub7: [96]u8 = undefined;
            // A condition is a Boolean in Kotlin even when boxed, so it unboxes rather than tests as a ref.
            const cond = convExpr(c.types[br.cond.int()], .boolean, regName(c, br.cond.int(), &cb), &ub7);
            try w.print("  if ({s}) goto B{d}; else goto B{d};\n", .{ cond, br.t.int(), br.f.int() });
        },
        .Throw => |t| {
            var tb: [32]u8 = undefined;
            var bb6: [96]u8 = undefined;
            try w.print("  {s}({s});\n", .{
                if (uses_try) "klio_do_throw" else "klio_nat_throw",
                boxExpr(c.types[t.int()], regName(c, t.int(), &tb), &bb6),
            });
        },
        .Return => |ret| {
            if (c.suspends) {
                // The frame dies with the last return out of the body.
                var rb9: [32]u8 = undefined;
                var bb9: [96]u8 = undefined;
                const val9 = if (ret) |rr9|
                    boxExpr(c.types[rr9.int()], regName(c, rr9.int(), &rb9), &bb9)
                else
                    "klio_nat_box_unit()";
                try w.print("  {{ klio_value rv = {s};\n    klio_nat_coro_free(fr);\n    return rv; }}\n", .{val9});
                return;
            }
            if (has_catch) try w.writeAll("  klio_try_top = KTE;\n");
            if (c.n_slots != 0) try w.writeAll("  klio_nat_leave(&KF);\n");
            if (ret) |rr| {
                var rb: [32]u8 = undefined;
                try w.print("  return {s};\n", .{regName(c, rr.int(), &rb)});
            } else if (c.ret == .object) {
                try w.writeAll("  return klio_nat_box_unit();\n");
            } else {
                try w.writeAll("  return 0;\n");
            }
        },
        else => unreachable,
    }
}
