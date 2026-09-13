//! The eligibility pass: whether a function lowers to the scalar core, and the
//! machine type of every register its body defines.
const std = @import("std");
const stdlib = @import("stdlib");
const member_dispatch = @import("interp_ir").member_dispatch;
const ir = @import("ir");
const Func = ir.Func;
const Module = ir.Module;
const cgen = @import("../cgen.zig");

const ARRAY_CLS = cgen.ARRAY_CLS;
const BareResolution = cgen.BareResolution;
const CELL_CLS = cgen.CELL_CLS;
const CapInfo = cgen.CapInfo;
const Compiled = cgen.Compiled;
const Error = cgen.Error;
const FUNC_MAX_ARITY = cgen.FUNC_MAX_ARITY;
const Global = cgen.Global;
const ITER_CLS = cgen.ITER_CLS;
const LIST_CLS = cgen.LIST_CLS;
const LambdaInfo = cgen.LambdaInfo;
const Program = cgen.Program;
const RANGE_CLS = cgen.RANGE_CLS;
const STRING_CLS = cgen.STRING_CLS;
const THROWABLE_CLS = cgen.THROWABLE_CLS;
const Ty = cgen.Ty;
const accessOwner = cgen.accessOwner;
const accessPlan = cgen.accessPlan;
const ambiguousOverload = cgen.ambiguousOverload;
const arrayElemOf = cgen.arrayElemOf;
const arrayOfIntrinsic = cgen.arrayOfIntrinsic;
const bareCallTarget = cgen.bareCallTarget;
const bindCallArgs = cgen.bindCallArgs;
const blockOrder = cgen.blockOrder;
const bodySuspends = cgen.bodySuspends;
const builtinConst = cgen.builtinConst;
const builtinQualifier = cgen.builtinQualifier;
const cOp = cgen.cOp;
const callResultCls = cgen.callResultCls;
const classFields = cgen.classFields;
const classIndexOfName = cgen.classIndexOfName;
const classQualifierNamed = cgen.classQualifierNamed;
const commonCls = cgen.commonCls;
const companionObjectNamed = cgen.companionObjectNamed;
const companionReceiver = cgen.companionReceiver;
const constTy = cgen.constTy;
const ctorDefault = cgen.ctorDefault;
const ctorFits = cgen.ctorFits;
const emit = cgen.emit;
const enumClassNamed = cgen.enumClassNamed;
const enumEntries = cgen.enumEntries;
const enumEntryIndex = cgen.enumEntryIndex;
const expectedFnType = cgen.expectedFnType;
const fieldIndex = cgen.fieldIndex;
const funcCls = cgen.funcCls;
const funcClsArity = cgen.funcClsArity;
const funcRetTy2 = cgen.funcRetTy2;
const functionResultTy = cgen.functionResultTy;
const globalIndex = cgen.globalIndex;
const globalTy = cgen.globalTy;
const hostMemberOp = cgen.hostMemberOp;
const instRefuse = cgen.instRefuse;
const instRefuseNamed = cgen.instRefuseNamed;
const isArrayOfNulls = cgen.isArrayOfNulls;
const isArrayTypeName = cgen.isArrayTypeName;
const isBitwise = cgen.isBitwise;
const isBuiltinCls = cgen.isBuiltinCls;
const isCmp = cgen.isCmp;
const isDelay = cgen.isDelay;
const isLaunch = cgen.isLaunch;
const isNumericTy = cgen.isNumericTy;
const isPrintln = cgen.isPrintln;
const isRunBlocking = cgen.isRunBlocking;
const isStringReg = cgen.isStringReg;
const isThrowableClass = cgen.isThrowableClass;
const isToStringCall = cgen.isToStringCall;
const lambdaEscapes = cgen.lambdaEscapes;
const lambdaParams = cgen.lambdaParams;
const listIntrinsic = cgen.listIntrinsic;
const listMemberName = cgen.listMemberName;
const memberRoot = cgen.memberRoot;
const nestedClassNamed = cgen.nestedClassNamed;
const no = cgen.no;
const noCallee = cgen.noCallee;
const noName = cgen.noName;
const numCls = cgen.numCls;
const numClsTy = cgen.numClsTy;
const numConv = cgen.numConv;
const numConvVirtual = cgen.numConvVirtual;
const objectClassNamed = cgen.objectClassNamed;
const plainFieldName = cgen.plainFieldName;
const primArrayElem = cgen.primArrayElem;
const primArrayKind = cgen.primArrayKind;
const promote = cgen.promote;
const qualifierOwnerFqn = cgen.qualifierOwnerFqn;
const receiverClass = cgen.receiverClass;
const refElemCls = cgen.refElemCls;
const refElemOf = cgen.refElemOf;
const rendersToString = cgen.rendersToString;
const resolveBare = cgen.resolveBare;
const sameWidthKind = cgen.sameWidthKind;
const scalarIntrinsic = cgen.scalarIntrinsic;
const simpleName = cgen.simpleName;
const staticClassOf = cgen.staticClassOf;
const stdlibEntry = cgen.stdlibEntry;
const topLevelFuncNamed = cgen.topLevelFuncNamed;
const traceOn = cgen.traceOn;
const tyOf = cgen.tyOf;
const typeReaches = cgen.typeReaches;
const unsignedTypeOf = cgen.unsignedTypeOf;
const virtualProp = cgen.virtualProp;

pub fn eligible(gpa: std.mem.Allocator, m: *const Module, prog: Program, f: *const Func, globals: []const Global, synth: ?[]const ir.Param, caps: []const CapInfo) Error!?Compiled {
    // A synthesized thunk declares no parameters and reads its caller's
    // positionally, so it is compiled against the signature it will be handed.
    const params: []const ir.Param = synth orelse f.params;
    // A `suspend` body compiles to a state machine over a heap frame; the
    // result is boxed, because it answers either the value or SUSPENDED. A
    // lambda the lowering did not MARK suspending still needs that shape when
    // it calls something that suspends — a `runBlocking` block is written
    // without the keyword.
    const suspends = bodySuspends(m, f);
    // A method is an ordinary function whose first parameter is the receiver;
    // the call sites already move it into arg 0.
    if (f.has_receiver_param and receiverClass(m, f) == null) return no(f, "receiver class");
    // A body the image left deferred is decoded on first touch. The emitter
    // reaches only what the program can call, so this materialises exactly the
    // bodies it compiles.
    if (f.blocks.len == 0) _ = m.ensureFuncBody(@constCast(f));
    if (!f.hasBody() or f.blocks.len == 0) return no(f, "no body");
    if (f.n_locals == 0) return no(f, "no locals");

    // The declared return type is a starting point only. An unannotated
    // declaration (`var counter = 0` lowers to a thunk) carries a placeholder,
    // so the authority is the register the body actually returns; the declared
    // type settles the Unit case, where there is no register to ask.
    var ret = funcRetTy2(m, f) orelse Ty.unit;
    for (params) |p| {
        // A default is the CALLER's business: the callee takes the parameter
        // like any other, and a call that omits it runs the thunk.
        // A parameter whose type names nothing the module declares is an
        // erased reference, not a refusal: it can be passed, returned and
        // stored, and any use that needs its layout refuses where it is used.
        _ = p;
    }

    const types = try gpa.alloc(Ty, f.n_locals);
    errdefer gpa.free(types);
    @memset(types, .unit);
    const cls = try gpa.alloc(?u32, f.n_locals);
    errdefer gpa.free(cls);
    @memset(cls, null);
    const elem = try gpa.alloc(Ty, f.n_locals);
    errdefer gpa.free(elem);
    @memset(elem, .unit);
    const elem_cls = try gpa.alloc(?u32, f.n_locals);
    errdefer gpa.free(elem_cls);
    @memset(elem_cls, null);
    // The integer constant a register was JUST given. Any other instruction
    // clears the whole table, because which register it wrote is not modelled
    // here: a value still known to be constant is one nothing has touched.
    const const_at = try gpa.alloc(?i64, f.n_locals);
    defer gpa.free(const_at);
    @memset(const_at, null);
    var pending_const: ?struct { reg: u32, val: i64 } = null;
    const lam = try gpa.alloc(?LambdaInfo, f.n_locals);
    errdefer gpa.free(lam);
    @memset(lam, null);
    const slot = try gpa.alloc(i32, f.n_locals);
    errdefer gpa.free(slot);
    @memset(slot, -1);
    const known = try gpa.alloc(bool, f.n_locals);
    defer gpa.free(known);
    @memset(known, false);

    // Blocks in reverse postorder, so a register's definition is typed before
    // every use of it except across a back edge, where the lowering already
    // puts the definition ahead of the edge. Source order does not have that
    // property: a `when` writes its result in the arm blocks, which sit after
    // the block that returns it.
    // Where each bare name inside an inlined receiver body resolved. Owned by
    // the Compiled this returns; freed on refusal.
    var bare: std.AutoHashMapUnmanaged(*const ir.Inst, BareResolution) = .empty;
    errdefer bare.deinit(gpa);
    // The implicit receivers in scope, innermost last. `with(x) { … }` and
    // `apply` splice their bodies inline and push the subject here.
    var encl: std.ArrayList(u32) = .empty;
    defer encl.deinit(gpa);

    const order = try blockOrder(gpa, f);
    defer gpa.free(order);
    for (order) |bi| {
        const blk = &f.blocks[bi];
        // A `finally` has to run on every exit from its region, including a
        // throw passing through; that is a separate shape from a handler.
        if (blk.finally != null) return no(f, "finally");
        for (blk.catches) |h| {
            if (h.exception_reg.int() >= f.n_locals) return no(f, "catch register");
            // The handler tests an interval, so the caught type has to be one
            // the program's throwable hierarchy places.
            if (prog.throws.find(h.type_name) == null) return no(f, "catch type");
            types[h.exception_reg.int()] = .object;
            cls[h.exception_reg.int()] = THROWABLE_CLS;
            known[h.exception_reg.int()] = true;
        }
        for (blk.insts) |*inst| {
            // What the PREVIOUS instruction made constant, which is all this
            // pass claims to know: anything else may have written any register.
            @memset(const_at, null);
            if (pending_const) |pc| const_at[pc.reg] = pc.val;
            pending_const = null;
            if (inst.* == .Const) {
                const cv0 = inst.Const;
                if (cv0.value.int() < m.consts.items.len and cv0.dst.int() < f.n_locals) {
                    const kv0: ?i64 = switch (m.consts.items[cv0.value.int()]) {
                        .Int => |x| @as(i64, x),
                        .Long => |x| x,
                        .Short => |x| @as(i64, x),
                        .Byte => |x| @as(i64, x),
                        else => null,
                    };
                    if (kv0) |v0| pending_const = .{ .reg = cv0.dst.int(), .val = v0 };
                }
            }
            switch (inst.*) {
                .Trace => {},
                // The enclosing-subject chain exists for the interpreter's
                // dynamic resolution: a bare name or a member the lowering
                // could not bind consults it while a inlined body runs.
                // Compiled code resolves every one of those statically or
                // refuses, so there is nothing for the chain to answer.
                .EnclosingPush => |ep| {
                    if (ep.src.int() >= f.n_locals) return no(f, "enclosing src");
                    try encl.append(gpa, ep.src.int());
                },
                .EnclosingPop => {
                    if (encl.items.len != 0) _ = encl.pop();
                },
                // A bare name inside such a body: the interpreter searches the
                // implicit receivers innermost first and falls back to the
                // global. The emitter does that search once, here.
                .LoadFromThisOrGlobal => |lt| {
                    if (lt.name.int() >= m.consts.items.len) return no(f, "bare name");
                    const bn = m.consts.items[lt.name.int()];
                    if (bn != .String) return no(f, "bare name kind");
                    if (lt.dst.int() >= f.n_locals) return no(f, "bare dst");
                    if (resolveBare(m, prog, types, cls, known, encl.items, null, bn.String, false)) |res| {
                        try bare.put(gpa, inst, res);
                        switch (res) {
                            // A bare NAME never resolves to a construction;
                            // only a bare call can.
                            .construct => return no(f, "bare name"),
                            .field => |fl| {
                                const fds = prog.of(cls[fl.recv].?).?;
                                types[lt.dst.int()] = fds[fl.idx].ty;
                                cls[lt.dst.int()] = fds[fl.idx].cls;
                            },
                            .accessor => |ac| {
                                const gfn = m.funcById(ac.func) orelse return no(f, "bare getter");
                                const gt = funcRetTy2(m, gfn) orelse return no(f, "bare getter type");
                                types[lt.dst.int()] = gt;
                                if (gt == .object) cls[lt.dst.int()] = classIndexOfName(m, gfn.return_ty);
 if (refElemOf(cls[lt.dst.int()], gfn.return_ty)) |re_| elem[lt.dst.int()] = re_;
                    elem_cls[lt.dst.int()] = refElemCls(m, cls[lt.dst.int()], gfn.return_ty);
                            },
                            .global, .member, .call => unreachable,
                        }
                        known[lt.dst.int()] = true;
                        continue;
                    }
                    const gi5 = globalIndex(globals, bn.String) orelse return noName(f, "bare name", bn.String);
                    try bare.put(gpa, inst, .global);
                    const gt5 = (try globalTy(gpa, m, prog, globals, gi5)) orelse return no(f, "global type");
                    types[lt.dst.int()] = gt5;
                    if (gt5 == .object) {
                        const gf5 = m.funcById(globals[gi5].func).?;
                        cls[lt.dst.int()] = classIndexOfName(m, gf5.return_ty);
                        if (refElemOf(cls[lt.dst.int()], gf5.return_ty)) |re_| elem[lt.dst.int()] = re_;
                    elem_cls[lt.dst.int()] = refElemCls(m, cls[lt.dst.int()], gf5.return_ty);
                    }
                    known[lt.dst.int()] = true;
                },
                .StoreToThisOrGlobal => |st| {
                    if (st.name.int() >= m.consts.items.len) return no(f, "bare name");
                    const bn2 = m.consts.items[st.name.int()];
                    if (bn2 != .String) return no(f, "bare name kind");
                    if (st.value.int() >= f.n_locals or !known[st.value.int()]) return no(f, "bare value");
                    const pref: ?u32 = if (st.recv) |rv| rv.int() else null;
                    if (resolveBare(m, prog, types, cls, known, encl.items, pref, bn2.String, true)) |res| {
                        try bare.put(gpa, inst, res);
                        switch (res) {
                            .construct => return no(f, "bare name"),
                            .field => |fl| {
                                const fds = prog.of(cls[fl.recv].?).?;
                                if (types[st.value.int()] != fds[fl.idx].ty) return no(f, "bare value type");
                            },
                            .accessor => |ac| {
                                const sfn = m.funcById(ac.func) orelse return no(f, "bare setter");
                                const want6: Ty = if (sfn.params.len >= 2) (tyOf(sfn.params[1].ty) orelse .object) else return no(f, "bare setter arity");
                                if (want6 != .object and types[st.value.int()] != want6) return no(f, "bare value type");
                            },
                            .global, .member, .call => unreachable,
                        }
                        continue;
                    }
                    const gi6 = globalIndex(globals, bn2.String) orelse return noName(f, "bare name", bn2.String);
                    _ = gi6;
                    try bare.put(gpa, inst, .global);
                },
                // A bare call whose name may be a member of an implicit
                // receiver or a top-level declaration. The interpreter decides
                // at run time by searching the receivers; the emitter searches
                // the same ones once, here.
                .CallMemberOrGlobal => |cg2| {

                    if (cg2.name.int() >= m.consts.items.len) return no(f, "bare call name");
                    const cn2 = m.consts.items[cg2.name.int()];
                    if (cn2 != .String) return no(f, "bare call name kind");
                    var ka9: u32 = 0;
                    while (ka9 < cg2.n_args) : (ka9 += 1) {
                        const a9 = cg2.args.int() + ka9;
                        if (a9 >= f.n_locals or !known[a9]) return no(f, "bare call arg");
                    }
                    if (cg2.dst.int() >= f.n_locals) return no(f, "bare call dst");
                    // A bare call to a stdlib entry the backend performs
                    // directly is that operation, not a call to a body that
                    // does not exist.
                    if (cg2.func) |gfid0| {
                        if (m.funcById(gfid0)) |gfn0| {
                            if (isPrintln(gfn0) or scalarIntrinsic(gfn0) == .print) {
                                if (cg2.n_args != 1) return no(f, "println arity");
                                if (types[cg2.args.int()] == .unit) return no(f, "println of Unit");
                                try bare.put(gpa, inst, .{ .call = gfid0 });
                                types[cg2.dst.int()] = .unit;
                                known[cg2.dst.int()] = true;
                                continue;
                            }
                        }
                    }
                    // The innermost implicit receiver that declares the name
                    // wins, which is what shadows a same-named global.
                    var mi: usize = encl.items.len;
                    while (mi > 0) {
                        mi -= 1;
                        const r9 = encl.items[mi];
                        if (r9 >= f.n_locals or !known[r9] or types[r9] != .object) continue;
                        const rc9 = cls[r9] orelse continue;
                        if (isBuiltinCls(rc9)) continue;
                        // A FUNCTION-TYPED property of the receiver answers
                        // through the invoke convention, which outranks a
                        // global of the same name.
                        if (fieldIndex(prog, rc9, cn2.String) != null) return noName(f, "bare call names a property", cn2.String);
                        const root9b = memberRoot(m, prog, rc9, cn2.String, cg2.n_args) orelse continue;
                        const rt9 = funcRetTy2(m, root9b) orelse return no(f, "bare call return type");
                        try bare.put(gpa, inst, .{ .member = .{ .recv = r9, .slot = root9b.id.int() } });
                        types[cg2.dst.int()] = rt9;
                        if (rt9 == .object) {
                            cls[cg2.dst.int()] = classIndexOfName(m, root9b.return_ty);
                            if (refElemOf(cls[cg2.dst.int()], root9b.return_ty)) |re9| elem[cg2.dst.int()] = re9;
                    elem_cls[cg2.dst.int()] = refElemCls(m, cls[cg2.dst.int()], root9b.return_ty);
                        }
                        known[cg2.dst.int()] = true;
                        break;
                    } else {
                        // Which declaration a bare call names is a question of
                        // scope: an overload set the arguments do not separate,
                        // a class of the same name (constructor versus
                        // factory), or a property holding a function all answer
                        // it at run time in the interpreter. The emitter has to
                        // answer it once, so it answers only when the
                        // declaration is unambiguous.
                        const picked = bareCallTarget(m, prog, cn2.String, types, cg2.args.int(), cg2.n_args, cg2.arg_names);
                        // No function owns the name: a class of it is a
                        // construction, which is what the lowering leaves open
                        // when there is nothing else the name could mean.
                        if (picked == null and globalIndex(globals, cn2.String) == null) {
                            if (classQualifierNamed(m, cn2.String)) |bcid| {
                                const bfields = prog.of(bcid) orelse return no(f, "class layout");
                                const bdef = &m.classes.items[bcid];
                                if (bdef.primary_params.len < cg2.n_args) return no(f, "ctor arity");
                                const bb10 = bindCallArgs(m, bdef.primary_params, cg2.args.int(), cg2.n_args, cg2.arg_names) orelse
                                    return no(f, "ctor argument binding");
                                var bi10: u32 = 0;
                                while (bi10 < bdef.primary_params.len) : (bi10 += 1) {
                                    if (bb10.regs[bi10] != null) continue;
                                    const bdf = ctorDefault(prog.layouts, bdef, bi10) orelse return no(f, "ctor arity");
                                    const bdfn = m.funcById(bdf) orelse return no(f, "ctor default thunk");
                                    if (funcRetTy2(m, bdfn) == null) return no(f, "ctor default thunk type");
                                }
                                for (bfields) |bfd| {
                                    const bai = bfd.arg orelse continue;
                                    const bar = bb10.regs[bai] orelse continue;
                                    if (bar >= f.n_locals or !known[bar]) return no(f, "ctor arg");
                                    const bwiden = isNumericTy(bfd.ty) and isNumericTy(types[bar]) and
                                        !bfd.ty.isFloat() and !types[bar].isFloat() and
                                        (if (const_at[bar]) |kv3| kv3 >= 0 else false);
                                    if (types[bar] != bfd.ty and bfd.ty != .object and
                                        !sameWidthKind(types[bar], bfd.ty) and !bwiden) return no(f, "ctor arg type");
                                    if (bfd.ty == .object) {
                                        if (bfd.cls) |bwc| {
                                            const bgc = cls[bar] orelse return no(f, "ctor arg class");
                                            if (bgc != bwc and !typeReaches(m, bgc, bwc)) return no(f, "ctor arg class");
                                        }
                                    }
                                }
                                if (cg2.dst.int() >= f.n_locals) return no(f, "ctor dst");
                                try bare.put(gpa, inst, .{ .construct = bcid });
                                types[cg2.dst.int()] = .object;
                                cls[cg2.dst.int()] = bcid;
                                known[cg2.dst.int()] = true;
                                break;
                            }
                        }
                        if (picked == null) {
                            // Which declarations the name could mean, and what
                            // the arguments are: that is the backlog entry.
                            if (traceOn()) {
                                for (m.funcs.items) |*cnd| {
                                    if (!std.mem.eql(u8, cnd.name, cn2.String)) continue;
                                    std.debug.print("[cgen]   candidate {s} params={d}", .{ cnd.fqn, cnd.params.len });
                                    for (cnd.params) |cp| std.debug.print(" [{s}:{s}]", .{ cp.name, cp.ty.name });
                                    std.debug.print("\n", .{});
                                }
                                var kq: u32 = 0;
                                while (kq < cg2.n_args) : (kq += 1) {
                                    std.debug.print("[cgen]   argument {d} is {s}\n", .{ kq, @tagName(types[cg2.args.int() + kq]) });
                                }
                            }
                            return noName(f, "bare call", cn2.String);
                        }
                        if (ctorFits(m, cn2.String, types, cg2.args.int(), cg2.n_args, cg2.arg_names))
                            return noName(f, "bare call", cn2.String);
                        if (globalIndex(globals, cn2.String) != null) return noName(f, "bare call", cn2.String);
                        const gfid = picked.?.id;
                        const gfn9 = m.funcById(gfid) orelse return no(f, "bare call target");
                        if (!gfn9.hasBody()) return noCallee(f, gfn9, "no body for");
                        if (gfn9.params.len < cg2.n_args) return noCallee(f, gfn9, "arity of");
                        // Arguments reach the callee in ITS order, and a
                        // parameter nothing binds runs the thunk for it.
                        const bb9 = bindCallArgs(m, gfn9.params, cg2.args.int(), cg2.n_args, cg2.arg_names) orelse
                            return noCallee(f, gfn9, "argument binding of");
                        var db9: u32 = 0;
                        while (db9 < bb9.n) : (db9 += 1) {
                            if (bb9.regs[db9] != null) continue;
                            const dfid9 = prog.defaultThunk(gfn9.id, db9) orelse return noCallee(f, gfn9, "arity of");
                            const dfn9b = m.funcById(dfid9) orelse return no(f, "default thunk");
                            if (funcRetTy2(m, dfn9b) == null) return no(f, "default thunk type");
                        }
                        const rt10 = funcRetTy2(m, gfn9) orelse return no(f, "bare call return type");
                        try bare.put(gpa, inst, .{ .call = gfid });
                        types[cg2.dst.int()] = rt10;
                        if (rt10 == .object) {
                            cls[cg2.dst.int()] = callResultCls(m, gfn9);
                            if (refElemOf(cls[cg2.dst.int()], gfn9.return_ty)) |re10| elem[cg2.dst.int()] = re10;
                    elem_cls[cg2.dst.int()] = refElemCls(m, cls[cg2.dst.int()], gfn9.return_ty);
                        }
                        known[cg2.dst.int()] = true;
                    }
                },
                .Const => |c| {
                    if (c.dst.int() >= f.n_locals) return no(f, "const dst");
                    if (c.value.int() >= m.consts.items.len) return no(f, "const id");
                    const t = constTy(m.consts.items[c.value.int()]) orelse return no(f, "const kind");
                    types[c.dst.int()] = t;
                    // A null literal has no class of its own; whatever it is
                    // compared against or assigned to supplies that.
                    if (t == .object and m.consts.items[c.value.int()] == .String) cls[c.dst.int()] = STRING_CLS;
                    known[c.dst.int()] = true;
                },
                .MakeCell => |mk| {
                    if (mk.dst.int() >= f.n_locals or mk.src.int() >= f.n_locals) return no(f, "cell reg");
                    if (!known[mk.src.int()]) return no(f, "cell source");
                    types[mk.dst.int()] = .object;
                    cls[mk.dst.int()] = CELL_CLS;
                    // A cell holds one machine type for its whole life, so it
                    // is the one every write agrees on. The lowering seeds a
                    // `var` with a Unit placeholder where the declaration has
                    // no initializer, which says nothing; writes that disagree
                    // leave the cell holding boxed values.
                    var cet = types[mk.src.int()];
                    for (f.blocks) |*b2| {
                        for (b2.insts) |*ci| {
                            if (ci.* != .CellSet) continue;
                            if (ci.CellSet.cell.int() != mk.dst.int()) continue;
                            const vr = ci.CellSet.value.int();
                            if (vr >= f.n_locals or !known[vr]) continue;
                            if (types[vr] == .unit) continue;
                            if (cet == .unit) {
                                cet = types[vr];
                            } else if (cet != types[vr]) {
                                cet = .object;
                            }
                        }
                    }
                    elem[mk.dst.int()] = cet;
                    known[mk.dst.int()] = true;
                },
                .CellGet => |cg| {
                    if (cg.cell.int() >= f.n_locals or !known[cg.cell.int()]) return no(f, "cell read");
                    if (cls[cg.cell.int()] == null or cls[cg.cell.int()].? != CELL_CLS) return no(f, "cell read of a non-cell");
                    if (cg.dst.int() >= f.n_locals) return no(f, "cell dst");
                    types[cg.dst.int()] = elem[cg.cell.int()];
                    known[cg.dst.int()] = true;
                },
                .CellSet => |cs| {
                    if (cs.cell.int() >= f.n_locals or !known[cs.cell.int()]) return no(f, "cell write");
                    if (cls[cs.cell.int()] == null or cls[cs.cell.int()].? != CELL_CLS) return no(f, "cell write to a non-cell");
                    if (cs.value.int() >= f.n_locals or !known[cs.value.int()]) return no(f, "cell value");
                    // A cell of boxed values takes anything; one of a machine
                    // type takes that type.
                    if (elem[cs.cell.int()] != .object and types[cs.value.int()] != elem[cs.cell.int()]) {
                        return no(f, "cell value type");
                    }
                },
                .LoadCapture => |lc| {
                    if (lc.dst.int() >= f.n_locals or lc.idx >= caps.len) return no(f, "load capture");
                    types[lc.dst.int()] = caps[lc.idx].ty;
                    cls[lc.dst.int()] = caps[lc.idx].cls;
                    elem[lc.dst.int()] = caps[lc.idx].elem;
                    known[lc.dst.int()] = true;
                },
                // `x as T`. The value passes through unchanged when the test
                // holds; otherwise a `ClassCastException`, or null for `as?`.
                // The named type is what the result register carries, which is
                // the point of writing the cast.
                .Cast => |ca| {
                    if (ca.src.int() >= f.n_locals or !known[ca.src.int()]) return no(f, "cast operand");
                    if (ca.dst.int() >= f.n_locals) return no(f, "cast dst");
                    // `as?` and `as T?` admit null, so the result is a
                    // reference whatever the named type is.
                    const scalar = if (ca.safe or ca.ty.nullable) null else tyOf(ca.ty);
                    if (scalar) |t| {
                        types[ca.dst.int()] = t;
                    } else {
                        types[ca.dst.int()] = .object;
                        cls[ca.dst.int()] = classIndexOfName(m, ca.ty);
                        if (refElemOf(cls[ca.dst.int()], ca.ty)) |re13| elem[ca.dst.int()] = re13;
                    elem_cls[ca.dst.int()] = refElemCls(m, cls[ca.dst.int()], ca.ty);
                    }
                    known[ca.dst.int()] = true;
                },
                // `x is T`. Which classes answer it is decided at emit time
                // from the hierarchy the program compiled; a value that is not
                // a compiled instance answers from its own representation.
                .InstanceOf => |io| {
                    if (io.src.int() >= f.n_locals or !known[io.src.int()]) return no(f, "is operand");
                    if (io.dst.int() >= f.n_locals) return no(f, "is dst");
                    types[io.dst.int()] = .boolean;
                    known[io.dst.int()] = true;
                },
                .LoadParam => |lp| {
                    if (lp.dst.int() >= f.n_locals or lp.idx >= params.len) return no(f, "load param");
                    const pt = params[lp.idx].ty;
                    if (params[lp.idx].is_vararg) {
                        // The parameter holds the array the call site built.
                        types[lp.dst.int()] = .object;
                        cls[lp.dst.int()] = ARRAY_CLS;
                        elem[lp.dst.int()] = tyOf(pt) orelse .unit;
                        known[lp.dst.int()] = true;
                        continue;
                    }
                    if (tyOf(pt)) |t| {
                        types[lp.dst.int()] = t;
                    } else {
                        types[lp.dst.int()] = .object;
                        cls[lp.dst.int()] = classIndexOfName(m, pt);
                        if (refElemOf(cls[lp.dst.int()], pt)) |re_| elem[lp.dst.int()] = re_;
                    elem_cls[lp.dst.int()] = refElemCls(m, cls[lp.dst.int()], pt);
                        // `List<Int>` says what its elements are; a list whose
                        // element type is written down needs no inference. An
                        // array says so in its own name.
                        if (cls[lp.dst.int()]) |rc| {
                            if (rc == LIST_CLS and pt.args.len == 1) {
                                if (tyOf(pt.args[0])) |et| elem[lp.dst.int()] = et;
                            }
                            if (rc == ARRAY_CLS) elem[lp.dst.int()] = arrayElemOf(pt);
                            // A function type's last argument is its result.
                            if (funcClsArity(rc) != null) elem[lp.dst.int()] = functionResultTy(pt);
                        }
                    }
                    known[lp.dst.int()] = true;
                },
                .Move => |mv| {
                    if (mv.dst.int() >= f.n_locals or mv.src.int() >= f.n_locals) return no(f, "move reg");
                    if (!known[mv.src.int()]) return no(f, "move source");
                    types[mv.dst.int()] = types[mv.src.int()];
                    cls[mv.dst.int()] = cls[mv.src.int()];
                    elem[mv.dst.int()] = elem[mv.src.int()];
                    elem_cls[mv.dst.int()] = elem_cls[mv.src.int()];
                    lam[mv.dst.int()] = lam[mv.src.int()];
                    known[mv.dst.int()] = true;
                },
                .BinOp => |b| {
                    if (b.dst.int() >= f.n_locals or b.lhs.int() >= f.n_locals or b.rhs.int() >= f.n_locals) return null;
                    if (!known[b.lhs.int()] or !known[b.rhs.int()]) return null;
                    const lt = types[b.lhs.int()];
                    const rt = types[b.rhs.int()];
                    // `==`/`!=` where either side is a reference is Kotlin's
                    // structural equality, which a null operand reduces to a
                    // null test. Either way the runtime decides it.
                    if ((b.op == .Eq or b.op == .NotEq) and (lt == .object or rt == .object)) {
                        if (b.dst.int() >= f.n_locals) return no(f, "compare dst");
                        types[b.dst.int()] = .boolean;
                        known[b.dst.int()] = true;
                        continue;
                    }
                    // `===` is referential identity, which never dispatches a
                    // user `equals`.
                    if (b.op == .IdentEq or b.op == .IdentNeq) {
                        if (b.dst.int() >= f.n_locals) return no(f, "compare dst");
                        types[b.dst.int()] = .boolean;
                        known[b.dst.int()] = true;
                        continue;
                    }
                    // Concatenation, either spelled as itself or as `+` with a
                    // string on one side. Kotlin renders the other operand
                    // through its own `toString`, so anything may be joined.
                    const str_join = b.op == .StringConcat or
                        (b.op == .Add and (isStringReg(types, cls, b.lhs.int()) or isStringReg(types, cls, b.rhs.int())));
                    if (str_join) {
                        if (b.dst.int() >= f.n_locals) return no(f, "concat dst");
                        types[b.dst.int()] = .object;
                        cls[b.dst.int()] = STRING_CLS;
                        known[b.dst.int()] = true;
                        continue;
                    }
                    // `a..b` and `a..<b` build a progression: a runtime value
                    // with its own bound and step resolution, which the
                    // interpreter performs and compiled code reuses.
                    if (b.op == .RangeTo or b.op == .RangeUntil) {
                        if (!isNumericTy(lt) or !isNumericTy(rt)) return no(f, "range operand types");
                        if (b.dst.int() >= f.n_locals) return no(f, "range dst");
                        types[b.dst.int()] = .object;
                        cls[b.dst.int()] = RANGE_CLS;
                        // A progression counts values of the operands' own
                        // type: `'a'..'e'` yields Chars, where the ARITHMETIC
                        // promotion of two Chars would be Int.
                        elem[b.dst.int()] = if (lt == rt) lt else (promote(lt, rt) orelse lt);
                        known[b.dst.int()] = true;
                        continue;
                    }
                    // `ushr` has no C spelling of its own — it is a cast to
                    // unsigned around `>>` — so it is admitted here and written
                    // out below rather than looked up.
                    if (b.op != .UShr and cOp(b.op) == null) {
                        if (traceOn()) std.debug.print("[cgen] refuse {s}: binop kind `{s}`\n", .{ f.fqn, @tagName(b.op) });
                        return null;
                    }
                    if (isCmp(b.op)) {
                        if (lt == .unit or rt == .unit) return null;
                        types[b.dst.int()] = .boolean;
                    } else if (isBitwise(b.op)) {
                        // Kotlin's shifts and bitwise ops are integer-only and
                        // take the LEFT operand's width.
                        if (lt.isFloat() or rt.isFloat() or lt == .unit or rt == .unit) return null;
                        if ((lt == .boolean) != (rt == .boolean)) return null;
                        types[b.dst.int()] = lt;
                    } else if (lt == .char and (b.op == .Add or b.op == .Sub) and
                        rt != .char and isNumericTy(rt) and !rt.isFloat())
                    {
                        // Kotlin's `Char + Int` and `Char - Int` answer a Char;
                        // `Char - Char` answers the distance, which promotes.
                        types[b.dst.int()] = .char;
                    } else {
                        types[b.dst.int()] = promote(lt, rt) orelse return no(f, "binop operand types");
                    }
                    known[b.dst.int()] = true;
                },
                .UnOp => |u| {
                    if (u.dst.int() >= f.n_locals or u.operand.int() >= f.n_locals) return no(f, "unop reg");
                    if (!known[u.operand.int()]) return no(f, "unop operand");
                    const ot = types[u.operand.int()];
                    if (!isNumericTy(ot)) return no(f, "unop operand type");
                    types[u.dst.int()] = switch (u.op) {
                        // Kotlin's unary minus and plus on a Byte or a Short
                        // answer an Int; every other width answers itself.
                        .Neg, .Plus => if (ot == .byte or ot == .short) Ty.i32 else ot,
                        // `inc()`/`dec()` keep the receiver's type, and wrap
                        // like the rest of Kotlin's integer arithmetic.
                        .Inc, .Dec => ot,
                    };
                    known[u.dst.int()] = true;
                },
                .Not => |n| {
                    if (n.dst.int() >= f.n_locals or n.src.int() >= f.n_locals) return no(f, "not reg");
                    if (!known[n.src.int()] or types[n.src.int()] != .boolean) return no(f, "not operand");
                    types[n.dst.int()] = .boolean;
                    known[n.dst.int()] = true;
                },
                .CallMember => |cm| {
                    // `toString()` on a value that declares no override of its
                    // own: the runtime renders it as it renders it for
                    // printing. A class that DOES override still dispatches.
                    if (cm.name.int() < m.consts.items.len) {
                        const tsn = m.consts.items[cm.name.int()];
                        if (tsn == .String and isToStringCall(tsn.String, cm.n_args) and
                            cm.receiver.int() < f.n_locals and known[cm.receiver.int()])
                        {
                            if (rendersToString(m, prog, cls, cm.receiver.int())) {
                                if (cm.dst.int() >= f.n_locals) return no(f, "member dst");
                                types[cm.dst.int()] = .object;
                                cls[cm.dst.int()] = STRING_CLS;
                                known[cm.dst.int()] = true;
                                continue;
                            }
                        }
                    }
                    // The iteration protocol on a builtin receiver, written
                    // by name rather than bound to a slot. Which members those
                    // are, and what each answers, is the interpreter's — the
                    // same classification the slot-bound route reads.
                    if (cm.arg_names.len == 0 and cm.name.int() < m.consts.items.len and
                        cm.receiver.int() < f.n_locals and known[cm.receiver.int()] and
                        types[cm.receiver.int()] == .object and cls[cm.receiver.int()] != null and
                        isBuiltinCls(cls[cm.receiver.int()].?))
                    {
                        const bmn = m.consts.items[cm.name.int()];
                        if (bmn == .String) {
                            if (member_dispatch.hostFreeMemberAnswer(plainFieldName(bmn.String))) |ans| {
                                var kkb: u32 = 0;
                                while (kkb < cm.n_args) : (kkb += 1) {
                                    const ab = cm.args.int() + kkb;
                                    if (ab >= f.n_locals or !known[ab]) return no(f, "host member arg");
                                }
                                if (cm.dst.int() >= f.n_locals) return no(f, "host member dst");
                                const et2 = elem[cm.receiver.int()];
                                switch (ans) {
                                    .iterator => {
                                        types[cm.dst.int()] = .object;
                                        cls[cm.dst.int()] = ITER_CLS;
                                        elem[cm.dst.int()] = et2;
                                        elem_cls[cm.dst.int()] = elem_cls[cm.receiver.int()];
                                    },
                                    .boolean => types[cm.dst.int()] = .boolean,
                                    .index => types[cm.dst.int()] = .i32,
                                    .unit => types[cm.dst.int()] = .unit,
                                    .element => {
                                        types[cm.dst.int()] = if (et2 == .unit) .object else et2;
                                        if (types[cm.dst.int()] == .object) cls[cm.dst.int()] = elem_cls[cm.receiver.int()];
                                    },
                                }
                                known[cm.dst.int()] = true;
                                continue;
                            }
                        }
                    }
                    if (cm.receiver.int() < f.n_locals and known[cm.receiver.int()] and
                        types[cm.receiver.int()] == .object and cls[cm.receiver.int()] != null and
                        cls[cm.receiver.int()].? == ARRAY_CLS)
                    {
                        if (cm.name.int() >= m.consts.items.len) return no(f, "member name");
                        const an = m.consts.items[cm.name.int()];
                        if (an != .String) return no(f, "member name kind");
                        const aa = cm.args.int();
                        var ka: u32 = 0;
                        while (ka < cm.n_args) : (ka += 1) {
                            if (aa + ka >= f.n_locals or !known[aa + ka]) return no(f, "array arg");
                        }
                        if (cm.dst.int() >= f.n_locals) return no(f, "array dst");
                        const aet = elem[cm.receiver.int()];
                        if (std.mem.eql(u8, an.String, "get") and cm.n_args == 1) {
                            if (types[aa] != .i32) return no(f, "array index type");
                            types[cm.dst.int()] = if (aet == .unit) .object else aet;
                            cls[cm.dst.int()] = null;
                        } else if (std.mem.eql(u8, an.String, "set") and cm.n_args == 2) {
                            if (types[aa] != .i32) return no(f, "array index type");
                            if (aet != .unit and types[aa + 1] != aet) return no(f, "array element type");
                            types[cm.dst.int()] = .unit;
                        } else return noName(f, "array member", an.String);
                        known[cm.dst.int()] = true;
                        continue;
                    }
                    if (cm.receiver.int() < f.n_locals and known[cm.receiver.int()] and
                        types[cm.receiver.int()] == .object and cls[cm.receiver.int()] != null and
                        cls[cm.receiver.int()].? == LIST_CLS)
                    {
                        if (cm.name.int() >= m.consts.items.len) return no(f, "member name");
                        const mn = m.consts.items[cm.name.int()];
                        if (mn != .String) return no(f, "member name kind");
                        const a0 = cm.args.int();
                        var kk: u32 = 0;
                        while (kk < cm.n_args) : (kk += 1) {
                            if (a0 + kk >= f.n_locals or !known[a0 + kk]) return no(f, "list arg");
                        }
                        if (cm.dst.int() >= f.n_locals) return no(f, "list dst");
                        if (std.mem.eql(u8, mn.String, "get") and cm.n_args == 1) {
                            if (types[a0] != .i32) return no(f, "list index type");
                            const et = elem[cm.receiver.int()];
                            types[cm.dst.int()] = if (et == .unit) .object else et;
                            cls[cm.dst.int()] = if (et == .unit) elem_cls[cm.receiver.int()] else null;
                            known[cm.dst.int()] = true;
                            continue;
                        }
                        if (std.mem.eql(u8, mn.String, "add") and cm.n_args == 1) {
                            types[cm.dst.int()] = .boolean;
                            known[cm.dst.int()] = true;
                            continue;
                        }
                        if (std.mem.eql(u8, mn.String, "set") and cm.n_args == 2) {
                            if (types[a0] != .i32) return no(f, "list index type");
                            types[cm.dst.int()] = .object;
                            cls[cm.dst.int()] = null;
                            known[cm.dst.int()] = true;
                            continue;
                        }
                        return no(f, "list member");
                    }
                    // A member CALLED on a class name runs on that class's
                    // companion: `Config.of(3)` is a call on the companion
                    // object, with the companion as the receiver.
                    if (numConv(m, cm) == null and cm.arg_names.len == 0 and cm.name.int() < m.consts.items.len) {
                        if (companionReceiver(m, prog, types, cls, cm.receiver.int())) |cc6| {
                            const mn6 = m.consts.items[cm.name.int()];
                            if (mn6 != .String) return no(f, "member name kind");
                            const root6 = memberRoot(m, prog, cc6, plainFieldName(mn6.String), cm.n_args) orelse
                                return noName(f, "companion member", mn6.String);
                            const mrt6 = funcRetTy2(m, root6) orelse return no(f, "member return type");
                            var kk6: u32 = 0;
                            while (kk6 < cm.n_args) : (kk6 += 1) {
                                const ar6b = cm.args.int() + kk6;
                                if (ar6b >= f.n_locals or !known[ar6b]) return no(f, "member arg");
                            }
                            if (cm.dst.int() >= f.n_locals) return no(f, "member dst");
                            types[cm.dst.int()] = mrt6;
                            if (mrt6 == .object) {
                                cls[cm.dst.int()] = classIndexOfName(m, root6.return_ty);
                                if (refElemOf(cls[cm.dst.int()], root6.return_ty)) |re6| elem[cm.dst.int()] = re6;
                    elem_cls[cm.dst.int()] = refElemCls(m, cls[cm.dst.int()], root6.return_ty);
                            }
                            known[cm.dst.int()] = true;
                            continue;
                        }
                    }
                    // A member call on a user class the lowering left by
                    // name. The declaration it binds to is decided here, and
                    // dispatch then runs exactly as it does for a slot the
                    // lowering resolved.
                    if (numConv(m, cm) == null and cm.arg_names.len == 0 and
                        cm.receiver.int() < f.n_locals and known[cm.receiver.int()] and
                        types[cm.receiver.int()] == .object)
                    {
                        if (cls[cm.receiver.int()]) |rc5| {
                            if (!isBuiltinCls(rc5) and cm.name.int() < m.consts.items.len) {
                                const mnm = m.consts.items[cm.name.int()];
                                if (mnm != .String) return no(f, "member name kind");
                                // A property holding a function, called by its
                                // name: read the property, then invoke what it
                                // holds.
                                if (fieldIndex(prog, rc5, mnm.String)) |fidx| {
                                    const fds5 = prog.of(rc5).?;
                                    const far = funcClsArity(fds5[fidx].cls orelse 0) orelse return noName(f, "member", mnm.String);
                                    if (far != cm.n_args) return no(f, "invoke arity");
                                    var kk7: u32 = 0;
                                    while (kk7 < cm.n_args) : (kk7 += 1) {
                                        const a7 = cm.args.int() + kk7;
                                        if (a7 >= f.n_locals or !known[a7]) return no(f, "invoke arg");
                                    }
                                    if (cm.dst.int() >= f.n_locals) return no(f, "invoke dst");
                                    types[cm.dst.int()] = fds5[fidx].elem;
                                    known[cm.dst.int()] = true;
                                    continue;
                                }
                                const root5 = memberRoot(m, prog, rc5, plainFieldName(mnm.String), cm.n_args) orelse {
                                    // A value with no `toString` of its own
                                    // renders the way the runtime renders it
                                    // for printing: one renderer, two callers.
                                    if (cm.n_args == 0 and std.mem.eql(u8, plainFieldName(mnm.String), "toString")) {
                                        if (cm.dst.int() >= f.n_locals) return no(f, "member dst");
                                        types[cm.dst.int()] = .object;
                                        cls[cm.dst.int()] = STRING_CLS;
                                        known[cm.dst.int()] = true;
                                        continue;
                                    }
                                    return noName(f, "member", mnm.String);
                                };
                                const mrt = funcRetTy2(m, root5) orelse return no(f, "member return type");
                                var kk5: u32 = 0;
                                while (kk5 < cm.n_args) : (kk5 += 1) {
                                    const ar5 = cm.args.int() + kk5;
                                    if (ar5 >= f.n_locals or !known[ar5]) return no(f, "member arg");
                                }
                                if (cm.dst.int() >= f.n_locals) return no(f, "member dst");
                                types[cm.dst.int()] = mrt;
                                if (mrt == .object) cls[cm.dst.int()] = classIndexOfName(m, root5.return_ty);
 if (refElemOf(cls[cm.dst.int()], root5.return_ty)) |re_| elem[cm.dst.int()] = re_;
                    elem_cls[cm.dst.int()] = refElemCls(m, cls[cm.dst.int()], root5.return_ty);
                                known[cm.dst.int()] = true;
                                continue;
                            }
                        }
                    }
                    const to = numConv(m, cm) orelse return instRefuseNamed(m, f, inst, cm.name);
                    if (cm.receiver.int() >= f.n_locals or !known[cm.receiver.int()]) return no(f, "conv receiver");
                    const rt2 = types[cm.receiver.int()];
                    if (!isNumericTy(rt2)) return no(f, "conv receiver type");
                    if (cm.dst.int() >= f.n_locals) return no(f, "conv dst");
                    // Kotlin saturates a floating value to Int.MIN/MAX and maps
                    // NaN to 0; a C cast leaves all three undefined.
                    if (rt2.isFloat() and (to == .i32 or to == .i64)) return no(f, "float to int");
                    types[cm.dst.int()] = to;
                    known[cm.dst.int()] = true;
                },
                .CallVirtual => |cv| {
                    // `toString()` on a value that declares no override of its
                    // own renders through the runtime; a class that DOES
                    // override still dispatches.
                    if (m.funcById(ir.FuncId.from(cv.slot.int()))) |tsd| {
                        if (isToStringCall(tsd.name, cv.n_args) and
                            cv.receiver.int() < f.n_locals and known[cv.receiver.int()])
                        {
                            if (rendersToString(m, prog, cls, cv.receiver.int())) {
                                if (cv.dst.int() >= f.n_locals) return no(f, "virtual dst");
                                types[cv.dst.int()] = .object;
                                cls[cv.dst.int()] = STRING_CLS;
                                known[cv.dst.int()] = true;
                                continue;
                            }
                        }
                    }
                    // A member the runtime serves from the receiver's own
                    // representation. The receiver has to be a runtime value
                    // rather than a compiled class: a user class that
                    // implements the same interface dispatches to its body.
                    if (cv.receiver.int() < f.n_locals and known[cv.receiver.int()] and
                        types[cv.receiver.int()] == .object and cls[cv.receiver.int()] != null and
                        isBuiltinCls(cls[cv.receiver.int()].?))
                    {
                        if (m.funcById(ir.FuncId.from(cv.slot.int()))) |decl| host: {
                            const op = hostMemberOp(decl) orelse break :host;
                            var kh: u32 = 0;
                            while (kh < cv.n_args) : (kh += 1) {
                                const ah = cv.args.int() + kh;
                                if (ah >= f.n_locals or !known[ah]) return no(f, "host member arg");
                            }
                            if (cv.dst.int() >= f.n_locals) return no(f, "host member dst");
                            if (op == .collection_iterator) {
                                types[cv.dst.int()] = .object;
                                cls[cv.dst.int()] = ITER_CLS;
                                elem[cv.dst.int()] = elem[cv.receiver.int()];
                                elem_cls[cv.dst.int()] = elem_cls[cv.receiver.int()];
                                known[cv.dst.int()] = true;
                                continue;
                            }
                            // The declaration says what the step answers. A
                            // return type that names neither a machine type
                            // nor a compiled class is the container's own
                            // element type, which the receiver carries.
                            const hrt = tyOf(decl.return_ty) orelse blk: {
                                if (classIndexOfName(m, decl.return_ty) == null and
                                    elem[cv.receiver.int()] != .unit) break :blk elem[cv.receiver.int()];
                                break :blk Ty.object;
                            };
                            types[cv.dst.int()] = hrt;
                            if (hrt == .object) {
                                cls[cv.dst.int()] = classIndexOfName(m, decl.return_ty) orelse
                                    elem_cls[cv.receiver.int()];
                            }
                            known[cv.dst.int()] = true;
                            continue;
                        }
                    }
                    if (cv.receiver.int() < f.n_locals and known[cv.receiver.int()] and
                        cls[cv.receiver.int()] != null and cls[cv.receiver.int()].? == LIST_CLS)
                    {
                        const mn = listMemberName(m, cv.slot) orelse return no(f, "list virtual member");
                        const a0 = cv.args.int();
                        var kk: u32 = 0;
                        while (kk < cv.n_args) : (kk += 1) {
                            if (a0 + kk >= f.n_locals or !known[a0 + kk]) return no(f, "list arg");
                        }
                        if (cv.dst.int() >= f.n_locals) return no(f, "list dst");
                        if (std.mem.eql(u8, mn, "get") and cv.n_args == 1) {
                            if (types[a0] != .i32) return no(f, "list index type");
                            const et = elem[cv.receiver.int()];
                            types[cv.dst.int()] = if (et == .unit) .object else et;
                            cls[cv.dst.int()] = if (et == .unit) elem_cls[cv.receiver.int()] else null;
                        } else if (std.mem.eql(u8, mn, "add") and cv.n_args == 1) {
                            types[cv.dst.int()] = .boolean;
                        } else if (std.mem.eql(u8, mn, "set") and cv.n_args == 2) {
                            if (types[a0] != .i32) return no(f, "list index type");
                            types[cv.dst.int()] = .object;
                            cls[cv.dst.int()] = null;
                        } else {
                            // Any other member of a builtin receiver is an
                            // operation the interpreter already implements.
                            const decl = m.funcById(ir.FuncId.from(cv.slot.int())) orelse return no(f, "list virtual member");
                            const sym = stdlibEntry(decl) orelse return noName(f, "list virtual member", decl.fqn);
                            _ = sym;
                            const vrt = tyOf(decl.return_ty) orelse Ty.object;
                            types[cv.dst.int()] = vrt;
                            if (vrt == .object) {
                                cls[cv.dst.int()] = classIndexOfName(m, decl.return_ty);
                                if (refElemOf(cls[cv.dst.int()], decl.return_ty)) |re12| elem[cv.dst.int()] = re12;
                    elem_cls[cv.dst.int()] = refElemCls(m, cls[cv.dst.int()], decl.return_ty);
                            }
                            known[cv.dst.int()] = true;
                            continue;
                        }
                        known[cv.dst.int()] = true;
                        continue;
                    }
                    if (cv.arg_names.len == 0 and cv.receiver.int() < f.n_locals and
                        known[cv.receiver.int()] and types[cv.receiver.int()] == .object)
                    {
                        if (m.funcById(ir.FuncId.from(cv.slot.int()))) |root| {
                            if (root.hasBody() or root.params.len != 0) {
                                // The slot's root declaration gives the result
                                // type and the argument shape; which body runs
                                // is decided at run time by the receiver.
                                const rt4 = funcRetTy2(m, root) orelse return no(f, "virtual return type");
                                // The dispatcher forwards what the site passes
                                // straight into the body it picks, so the site
                                // has to supply the declaration's parameters
                                // positionally. A site that omits one — a
                                // default, or a named argument the lowering
                                // reordered — needs the missing value computed
                                // HERE, before the receiver is known.
                                if (cv.n_args + 1 != root.params.len) return noCallee(f, root, "virtual call arity");
                                var kk2: u32 = 0;
                                while (kk2 < cv.n_args) : (kk2 += 1) {
                                    const ar2 = cv.args.int() + kk2;
                                    if (ar2 >= f.n_locals or !known[ar2]) return no(f, "virtual arg");
                                }
                                if (cv.dst.int() >= f.n_locals) return no(f, "virtual dst");
                                types[cv.dst.int()] = rt4;
                                if (rt4 == .object) cls[cv.dst.int()] = classIndexOfName(m, root.return_ty);
 if (refElemOf(cls[cv.dst.int()], root.return_ty)) |re_| elem[cv.dst.int()] = re_;
                    elem_cls[cv.dst.int()] = refElemCls(m, cls[cv.dst.int()], root.return_ty);
                                known[cv.dst.int()] = true;
                                continue;
                            }
                        }
                    }
                    const to = numConvVirtual(m, cv) orelse return instRefuse(f, inst);
                    if (cv.receiver.int() >= f.n_locals or !known[cv.receiver.int()]) return no(f, "conv receiver");
                    const rt3 = types[cv.receiver.int()];
                    if (!isNumericTy(rt3)) return no(f, "conv receiver type");
                    if (cv.dst.int() >= f.n_locals) return no(f, "conv dst");
                    if (rt3.isFloat() and (to == .i32 or to == .i64)) return no(f, "float to int");
                    types[cv.dst.int()] = to;
                    known[cv.dst.int()] = true;
                },
                .NewInstance => |ni| {
                    // An unsigned integer is a value class: constructing one
                    // reinterprets the same bits.
                    if (ni.class.int() < m.classes.items.len) {
                        if (unsignedTypeOf(m.classes.items[ni.class.int()].name)) |ut| {
                            if (ni.n_args != 1) return no(f, "unsigned ctor arity");
                            const ur = ni.args.int();
                            if (ur >= f.n_locals or !known[ur]) return no(f, "unsigned value");
                            if (!isNumericTy(types[ur])) return no(f, "unsigned value type");
                            if (ni.dst.int() >= f.n_locals) return no(f, "unsigned dst");
                            types[ni.dst.int()] = ut;
                            known[ni.dst.int()] = true;
                            continue;
                        }
                    }
                    if (ni.class.int() < m.classes.items.len and
                        isArrayTypeName(m.classes.items[ni.class.int()].name))
                    {
                        // `IntArray(n)` is a sized array, not an instance with
                        // fields. `IntArray(n) { i -> … }` runs a body per
                        // element, which is a loop rather than an allocation.
                        if (ni.n_args != 1 and ni.n_args != 2) return no(f, "array ctor arity");
                        const nr = ni.args.int();
                        if (nr >= f.n_locals or !known[nr]) return no(f, "array size");
                        if (types[nr] != .i32) return no(f, "array size type");
                        if (ni.n_args == 2) {
                            const lr = ni.args.int() + 1;
                            if (lr >= f.n_locals or !known[lr]) return no(f, "array initializer");
                            if (lam[lr] == null and funcClsArity(cls[lr] orelse 0) != @as(u32, 1)) {
                                return no(f, "array initializer shape");
                            }
                        }
                        if (ni.dst.int() >= f.n_locals) return no(f, "array dst");
                        types[ni.dst.int()] = .object;
                        cls[ni.dst.int()] = ARRAY_CLS;
                        elem[ni.dst.int()] = if (primArrayKind(m.classes.items[ni.class.int()].name)) |k|
                            primArrayElem(k)
                        else
                            .unit;
                        known[ni.dst.int()] = true;
                        continue;
                    }
                    if (isThrowableClass(m, ni.class.int())) {
                        if (ni.n_args > 1) return no(f, "throwable ctor arity");
                        if (ni.n_args == 1) {
                            const ar4 = ni.args.int();
                            if (ar4 >= f.n_locals or !known[ar4]) return no(f, "throwable message");
                        }
                        if (ni.dst.int() >= f.n_locals) return no(f, "throwable dst");
                        types[ni.dst.int()] = .object;
                        cls[ni.dst.int()] = THROWABLE_CLS;
                        known[ni.dst.int()] = true;
                        continue;
                    }
                    const fields = prog.of(ni.class.int()) orelse {
                        if (traceOn() and ni.class.int() < m.classes.items.len) {
                            if (cgen.layout_diag_busy) return no(f, "class layout");
                            cgen.layout_diag_busy = true;
                            cgen.layout_quiet = false;
                            if (try classFields(gpa, m, prog.layouts, ni.class, &prog, globals, true)) |junk| gpa.free(junk.fields);
                            cgen.layout_quiet = true;
                            cgen.layout_diag_busy = false;
                        }
                        return no(f, "class layout");
                    };
                    const cdef3 = &m.classes.items[ni.class.int()];
                    if (cdef3.primary_params.len < ni.n_args) return no(f, "ctor arity");
                    // A constructor takes its arguments in ITS order, whatever
                    // order the call writes them in.
                    const cb3 = bindCallArgs(m, cdef3.primary_params, ni.args.int(), ni.n_args, ni.arg_names) orelse
                        return no(f, "ctor argument binding");
                    // A parameter nothing binds runs the thunk the declaration
                    // lowered for its default.
                    var ci3: u32 = 0;
                    while (ci3 < cdef3.primary_params.len) : (ci3 += 1) {
                        if (cb3.regs[ci3] != null) continue;
                        const cdf = ctorDefault(prog.layouts, cdef3, ci3) orelse return no(f, "ctor arity");
                        const cdfn = m.funcById(cdf) orelse return no(f, "ctor default thunk");
                        if (funcRetTy2(m, cdfn) == null) return no(f, "ctor default thunk type");
                    }
                    for (fields) |fd| {
                        const ai = fd.arg orelse continue;
                        const ar = cb3.regs[ai] orelse continue;
                        if (ar >= f.n_locals or !known[ar]) return no(f, "ctor arg");
                        // A field that holds a REFERENCE takes any value: the
                        // call site boxes a machine type for it, which is what
                        // an erased type parameter needs.
                        // A narrower integer CONSTANT reaching a wider field
                        // is the same value, which is what an overload the
                        // lowering resolved to the constructor leaves behind.
                        // A negative one is not: widening it would sign-extend
                        // where the interpreter keeps the number it computed.
                        const widen_ok = isNumericTy(fd.ty) and isNumericTy(types[ar]) and
                            !fd.ty.isFloat() and !types[ar].isFloat() and
                            (if (const_at[ar]) |kv2| kv2 >= 0 else false);
                        if (types[ar] != fd.ty and fd.ty != .object and
                            !sameWidthKind(types[ar], fd.ty) and !widen_ok)
                        {
                            if (traceOn()) std.debug.print("[cgen]   field `{s}` is {s}, argument r{d} is {s}\n", .{ fd.name, @tagName(fd.ty), ar, @tagName(types[ar]) });
                            return no(f, "ctor arg type");
                        }
                        // An argument whose class is not the field's is a call
                        // to a SECONDARY constructor, which runs a body the
                        // emitter does not have. Matching arity alone made it
                        // look like the primary and stored the argument as it
                        // came.
                        if (fd.ty == .object) {
                            if (fd.cls) |want_c| {
                                const got_c = cls[ar] orelse return no(f, "ctor arg class");
                                if (got_c != want_c and !typeReaches(m, got_c, want_c)) {
                                    return no(f, "ctor arg class");
                                }
                            }
                        }
                    }
                    if (ni.dst.int() >= f.n_locals) return no(f, "ctor dst");
                    types[ni.dst.int()] = .object;
                    cls[ni.dst.int()] = ni.class.int();
                    known[ni.dst.int()] = true;
                },
                .GetField => |gf| {
                    if (gf.receiver.int() >= f.n_locals or !known[gf.receiver.int()]) return no(f, "field receiver");
                    // The lowering's sentinel for a bare name in value
                    // position: a CLASS resolves to its companion, and
                    // anything else is itself.
                    if (gf.field.int() < m.consts.items.len) {
                        const sen = m.consts.items[gf.field.int()];
                        if (sen == .String and std.mem.eql(u8, sen.String, "<class-companion-or-self>")) {
                            if (gf.dst.int() >= f.n_locals) return no(f, "field dst");
                            if (staticClassOf(types, cls, gf.receiver.int())) |scq| {
                                if (companionObjectNamed(m, prog, if (scq < m.classes.items.len) m.classes.items[scq].fqn else "")) |ccq| {
                                    types[gf.dst.int()] = .object;
                                    cls[gf.dst.int()] = ccq;
                                } else {
                                    types[gf.dst.int()] = .unit;
                                    cls[gf.dst.int()] = scq;
                                }
                            } else {
                                types[gf.dst.int()] = types[gf.receiver.int()];
                                cls[gf.dst.int()] = cls[gf.receiver.int()];
                                elem[gf.dst.int()] = elem[gf.receiver.int()];
                            }
                            known[gf.dst.int()] = true;
                            continue;
                        }
                    }
                    // A read off a class NAME whose member belongs to that
                    // class's companion: the companion answers it, so the
                    // access runs against the companion singleton.
                    var qual_recv: ?u32 = null;
                    if (staticClassOf(types, cls, gf.receiver.int())) |sc| {
                        if (gf.field.int() >= m.consts.items.len) return no(f, "field name");
                        const enm = m.consts.items[gf.field.int()];
                        if (enm != .String) return no(f, "field name kind");
                        if (numClsTy(sc)) |bt2| {
                            const bc3 = builtinConst(bt2, plainFieldName(enm.String)) orelse
                                return noName(f, "builtin constant", enm.String);
                            if (gf.dst.int() >= f.n_locals) return no(f, "constant dst");
                            types[gf.dst.int()] = bc3.ty;
                            known[gf.dst.int()] = true;
                            continue;
                        }
                        if (sc < m.classes.items.len) {
                            if (nestedClassNamed(m, qualifierOwnerFqn(m.classes.items[sc].fqn), plainFieldName(enm.String))) |nc| {
                                if (gf.dst.int() >= f.n_locals) return no(f, "qualifier dst");
                                types[gf.dst.int()] = .unit;
                                cls[gf.dst.int()] = nc;
                                known[gf.dst.int()] = true;
                                continue;
                            }
                        }
                        // `E.entries` is every entry of an enum, in
                        // declaration order, as a list.
                        if (std.mem.eql(u8, plainFieldName(enm.String), "entries") and
                            enumEntries(m, prog, sc).len != 0)
                        {
                            if (gf.dst.int() >= f.n_locals) return no(f, "entries dst");
                            types[gf.dst.int()] = .object;
                            cls[gf.dst.int()] = LIST_CLS;
                            elem_cls[gf.dst.int()] = sc;
                            known[gf.dst.int()] = true;
                            continue;
                        }
                        if (enumEntryIndex(m, prog, sc, plainFieldName(enm.String))) |_| {
                            if (gf.dst.int() >= f.n_locals) return no(f, "entry dst");
                            types[gf.dst.int()] = .object;
                            cls[gf.dst.int()] = sc;
                            known[gf.dst.int()] = true;
                            continue;
                        }
                        qual_recv = companionObjectNamed(m, prog, if (sc < m.classes.items.len) m.classes.items[sc].fqn else "") orelse {
                            if (traceOn()) {
                                std.debug.print("[cgen] refuse {s}: member `{s}` of the class `{s}`, which has no companion the program laid out\n", .{
                                    f.fqn, enm.String, if (sc < m.classes.items.len) m.classes.items[sc].fqn else "?",
                                });
                                // Say WHY the companion has no layout, which is
                                // the thing to fix.
                                var ci9: u32 = 0;
                                while (ci9 < m.classes.items.len) : (ci9 += 1) {
                                    if (!m.classes.items[ci9].is_object) continue;
                                    if (!std.mem.endsWith(u8, m.classes.items[ci9].fqn, ".Companion")) continue;
                                    const own9 = qualifierOwnerFqn(m.classes.items[ci9].fqn);
                                    if (sc >= m.classes.items.len) break;
                                    if (!std.mem.eql(u8, own9, m.classes.items[sc].fqn) and
                                        !std.mem.eql(u8, simpleName(own9), simpleName(m.classes.items[sc].fqn))) continue;
                                    if (cgen.layout_diag_busy) return no(f, "class layout");
                            cgen.layout_diag_busy = true;
                            cgen.layout_quiet = false;
                                    if (try classFields(gpa, m, prog.layouts, @enumFromInt(ci9), &prog, globals, true)) |j9| gpa.free(j9.fields);
                                    cgen.layout_quiet = true;
                                    cgen.layout_diag_busy = false;
                                }
                            }
                            return null;
                        };
                    }
                    if (qual_recv == null and types[gf.receiver.int()] != .object) return no(f, "field on non-object");
                    var rc = qual_recv orelse (cls[gf.receiver.int()] orelse return no(f, "field receiver class"));
                    if (rc == STRING_CLS or rc == LIST_CLS or rc == ARRAY_CLS) {
                        const snm = m.consts.items[gf.field.int()];
                        if (snm != .String) return no(f, "builtin member name");
                        const want: []const u8 = if (rc == STRING_CLS) "length" else "size";
                        if (!std.mem.eql(u8, plainFieldName(snm.String), want)) return noName(f, "builtin member", snm.String);
                        if (gf.dst.int() >= f.n_locals) return no(f, "field dst");
                        types[gf.dst.int()] = .i32;
                        known[gf.dst.int()] = true;
                        continue;
                    }
                    // A progression answers its bounds and its step from its
                    // own record; the counted loop the lowering writes for
                    // `for (x in r)` reads exactly those three.
                    if (rc == RANGE_CLS) {
                        const pnm = m.consts.items[gf.field.int()];
                        if (pnm != .String) return no(f, "builtin member name");
                        const pn = plainFieldName(pnm.String);
                        const et = elem[gf.receiver.int()];
                        const pt: Ty = if (std.mem.eql(u8, pn, "step"))
                            (if (et == .i64 or et == .u64) Ty.i64 else Ty.i32)
                        else if (std.mem.eql(u8, pn, "first") or std.mem.eql(u8, pn, "last"))
                            (if (et == .unit) Ty.i32 else et)
                        else
                            return noName(f, "builtin member", pnm.String);
                        if (gf.dst.int() >= f.n_locals) return no(f, "field dst");
                        types[gf.dst.int()] = pt;
                        known[gf.dst.int()] = true;
                        continue;
                    }
                    if (gf.field.int() >= m.consts.items.len) return no(f, "field name");
                    const nm = m.consts.items[gf.field.int()];
                    if (nm != .String) return no(f, "field name kind");
                    // A nested class read off its outer names a type, not a
                    // value: the register is a qualifier and holds nothing.
                    if (rc < m.classes.items.len) {
                        if (nestedClassNamed(m, qualifierOwnerFqn(m.classes.items[rc].fqn), plainFieldName(nm.String))) |nc| {
                            if (gf.dst.int() >= f.n_locals) return no(f, "qualifier dst");
                            types[gf.dst.int()] = .unit;
                            cls[gf.dst.int()] = nc;
                            known[gf.dst.int()] = true;
                            continue;
                        }
                    }
                    if (qual_recv == null) {
                        if (accessOwner(m, prog, rc, nm.String, false)) |cc| {
                            rc = cc;
                            qual_recv = cc;
                        }
                    }
                    switch (accessPlan(m, prog, rc, nm.String, false)) {
                        .none => {
                            // Name why the class has no layout, when that is
                            // the reason the field is not there.
                            if (traceOn() and prog.of(rc) == null and rc < m.classes.items.len) {
                                if (cgen.layout_diag_busy) return no(f, "class layout");
                            cgen.layout_diag_busy = true;
                            cgen.layout_quiet = false;
                                if (try classFields(gpa, m, prog.layouts, @enumFromInt(rc), &prog, globals, true)) |junk2| {
                                    gpa.free(junk2.fields);
                                }
                                cgen.layout_quiet = true;
                                cgen.layout_diag_busy = false;
                            }
                            return noName(f, "field not laid out", nm.String);
                        },
                        .virtual => {
                            const vp = virtualProp(m, prog, rc, plainFieldName(nm.String)).?;
                            if (gf.dst.int() >= f.n_locals) return no(f, "field dst");
                            types[gf.dst.int()] = vp.ret;
                            cls[gf.dst.int()] = vp.cls;
                            elem[gf.dst.int()] = vp.elem;
                            known[gf.dst.int()] = true;
                            continue;
                        },
                        .accessor => |g| {
                            const gfn = m.funcById(g) orelse return no(f, "getter body");
                            const gt = funcRetTy2(m, gfn) orelse return no(f, "getter return type");
                            if (gf.dst.int() >= f.n_locals) return no(f, "field dst");
                            types[gf.dst.int()] = gt;
                            if (gt == .object) {
                                cls[gf.dst.int()] = classIndexOfName(m, gfn.return_ty);
                                if (refElemOf(cls[gf.dst.int()], gfn.return_ty)) |re_| elem[gf.dst.int()] = re_;
                    elem_cls[gf.dst.int()] = refElemCls(m, cls[gf.dst.int()], gfn.return_ty);
                            }
                            known[gf.dst.int()] = true;
                            continue;
                        },
                        .field => |idx| {
                            const fields = prog.of(rc).?;
                            if (gf.dst.int() >= f.n_locals) return no(f, "field dst");
                            types[gf.dst.int()] = fields[idx].ty;
                            cls[gf.dst.int()] = fields[idx].cls;
                            elem[gf.dst.int()] = fields[idx].elem;
                            known[gf.dst.int()] = true;
                        },
                    }
                },
                .SetField => |sf| {
                    if (sf.receiver.int() >= f.n_locals or !known[sf.receiver.int()]) return no(f, "field receiver");
                    if (types[sf.receiver.int()] != .object) return no(f, "field on non-object");
                    const rc = cls[sf.receiver.int()] orelse return no(f, "field receiver class");
                    if (sf.field.int() >= m.consts.items.len) return no(f, "field name");
                    const nm = m.consts.items[sf.field.int()];
                    if (nm != .String) return no(f, "field name kind");
                    switch (accessPlan(m, prog, rc, nm.String, true)) {
                        .none, .virtual => return noName(f, "field not laid out", nm.String),
                        .accessor => |st| {
                            const sfn = m.funcById(st) orelse return no(f, "setter body");
                            if (sf.value.int() >= f.n_locals or !known[sf.value.int()]) return no(f, "field value");
                            // The setter's own parameter decides what it takes.
                            const want: Ty = if (sfn.params.len >= 2)
                                (tyOf(sfn.params[1].ty) orelse .object)
                            else
                                return no(f, "setter arity");
                            if (want != .object and types[sf.value.int()] != want) return no(f, "setter value type");
                        },
                        .field => |idx| {
                            const fields = prog.of(rc).?;
                            if (sf.value.int() >= f.n_locals or !known[sf.value.int()]) return no(f, "field value");
                            if (types[sf.value.int()] != fields[idx].ty) return no(f, "field value type");
                        },
                    }
                },
                .LoadGlobal => |lg| {
                    if (lg.name.int() >= m.consts.items.len) return no(f, "global name");
                    const gn = m.consts.items[lg.name.int()];
                    if (gn != .String) return no(f, "global name kind");
                    if (objectClassNamed(m, prog, gn.String) orelse
                        companionObjectNamed(m, prog, gn.String)) |oc|
                    {
                        if (lg.dst.int() >= f.n_locals) return no(f, "singleton dst");
                        types[lg.dst.int()] = .object;
                        cls[lg.dst.int()] = oc;
                        known[lg.dst.int()] = true;
                        continue;
                    }
                    // A builtin type's name is a qualifier too: `Int` in
                    // `Int.MAX_VALUE` names the type, and the constant read
                    // off it is the language's own number.
                    if (builtinQualifier(gn.String)) |bt| {
                        if (globalIndex(globals, gn.String) == null) {
                            if (lg.dst.int() >= f.n_locals) return no(f, "qualifier dst");
                            types[lg.dst.int()] = .unit;
                            cls[lg.dst.int()] = numCls(bt);
                            known[lg.dst.int()] = true;
                            continue;
                        }
                    }
                    // An enum's own name is a qualifier: it carries no value,
                    // and the member read off it resolves at emit time.
                    if (enumClassNamed(m, prog, gn.String)) |ec| {
                        if (lg.dst.int() >= f.n_locals) return no(f, "qualifier dst");
                        types[lg.dst.int()] = .unit;
                        cls[lg.dst.int()] = ec;
                        known[lg.dst.int()] = true;
                        continue;
                    }
                    // Any other class name is a qualifier too: `Outer` in
                    // `Outer.Section` names the type the nested name is read
                    // off. A global of the same name is a value and wins.
                    if (globalIndex(globals, gn.String) == null) {
                        if (classQualifierNamed(m, gn.String)) |qc| {
                            if (lg.dst.int() >= f.n_locals) return no(f, "qualifier dst");
                            types[lg.dst.int()] = .unit;
                            cls[lg.dst.int()] = qc;
                            known[lg.dst.int()] = true;
                            continue;
                        }
                    }
                    if (globalIndex(globals, gn.String) == null) {
                        // A function's NAME in value position is the function
                        // itself: a callable with no captures, which is the
                        // same shape a lambda that captures nothing takes.
                        if (topLevelFuncNamed(m, gn.String)) |rf| {
                            if (rf.params.len <= FUNC_MAX_ARITY) {
                                if (lg.dst.int() >= f.n_locals) return no(f, "callable dst");
                                types[lg.dst.int()] = .object;
                                cls[lg.dst.int()] = funcCls(@intCast(rf.params.len));
                                elem[lg.dst.int()] = funcRetTy2(m, rf) orelse .object;
                                lam[lg.dst.int()] = .{ .body = rf.id, .captures = &.{} };
                                known[lg.dst.int()] = true;
                                continue;
                            }
                        }
                    }
                    const gi = globalIndex(globals, gn.String) orelse return noName(f, "global not declared", gn.String);
                    if (lg.dst.int() >= f.n_locals) return no(f, "global dst");
                    const gt = (try globalTy(gpa, m, prog, globals, gi)) orelse return no(f, "global type");
                    types[lg.dst.int()] = gt;
                    if (gt == .object) {
                        const gf = m.funcById(globals[gi].func).?;
                        cls[lg.dst.int()] = classIndexOfName(m, gf.return_ty);
                        if (refElemOf(cls[lg.dst.int()], gf.return_ty)) |re_| elem[lg.dst.int()] = re_;
                    elem_cls[lg.dst.int()] = refElemCls(m, cls[lg.dst.int()], gf.return_ty);
                    }
                    known[lg.dst.int()] = true;
                },
                .StoreGlobal => |sg| {
                    if (sg.name.int() >= m.consts.items.len) return no(f, "global name");
                    const gn = m.consts.items[sg.name.int()];
                    if (gn != .String) return no(f, "global name kind");
                    const gi = globalIndex(globals, gn.String) orelse return noName(f, "global not declared", gn.String);
                    if (sg.value.int() >= f.n_locals or !known[sg.value.int()]) return no(f, "global value");
                    const gt = (try globalTy(gpa, m, prog, globals, gi)) orelse return no(f, "global type");
                    if (types[sg.value.int()] != gt) {
                        if (traceOn()) std.debug.print("[cgen]   global `{s}` is {s}, stored value is {s}\n", .{ gn.String, @tagName(gt), @tagName(types[sg.value.int()]) });
                        return no(f, "global value type");
                    }
                },
                .AstLambda => |al| {
                    const body = al.body_func orelse return no(f, "lambda without a lowered body");
                    if (al.dst.int() >= f.n_locals) return no(f, "lambda dst");
                    for (al.captures) |cr| {
                        if (cr.int() >= f.n_locals or !known[cr.int()]) return no(f, "lambda capture");
                    }
                    lam[al.dst.int()] = .{ .body = body, .captures = al.captures };
                    known[al.dst.int()] = true;
                    if (!lambdaEscapes(m, f, al.dst)) {
                        // Never materialised: every use is a direct call, so
                        // the call site passes the captures itself.
                        types[al.dst.int()] = .unit;
                        continue;
                    }
                    // The value has to exist. It becomes an instance of a
                    // class the emitter synthesizes for this body, one field
                    // per capture, which is what lets the collector trace it
                    // and a call through it find the body again.
                    const bfn = m.funcById(body) orelse return no(f, "lambda body missing");
                    const arity = bfn.params.len;
                    if (arity > FUNC_MAX_ARITY) return no(f, "lambda arity");
                    const ct5 = try gpa.alloc(CapInfo, al.captures.len);
                    defer gpa.free(ct5);
                    for (al.captures, 0..) |cr5, ci6| ct5[ci6] = .{ .ty = types[cr5.int()], .cls = cls[cr5.int()], .elem = elem[cr5.int()] };
                    const fnty = expectedFnType(m, f, al.dst);
                    const lsynth = if (fnty) |t5| try lambdaParams(gpa, bfn, t5) else null;
                    defer if (lsynth) |ls5| gpa.free(ls5);
                    var lc = (try eligible(gpa, m, prog, bfn, globals, lsynth, ct5)) orelse return no(f, "lambda body");
                    const lret = lc.ret;
                    lc.deinit(gpa);
                    types[al.dst.int()] = .object;
                    cls[al.dst.int()] = funcCls(@intCast(arity));
                    elem[al.dst.int()] = lret;
                },
                // A bare call whose name is both a callable in scope and
                // possibly a member of the receiver. When the local is a
                // function value the local wins, which is what the interpreter
                // decides at run time by finding it first.
                .CallValueOrMember => |cvm| {
                    if (cvm.arg_names.len != 0) return no(f, "value call names");
                    if (cvm.callee.int() >= f.n_locals or !known[cvm.callee.int()]) return no(f, "value callee");
                    if (types[cvm.callee.int()] != .object) return instRefuse(f, inst);
                    const fc2 = cls[cvm.callee.int()] orelse return instRefuse(f, inst);
                    const ar7 = funcClsArity(fc2) orelse return instRefuse(f, inst);
                    if (cvm.n_args != ar7) return no(f, "value call arity");
                    var kk8: u32 = 0;
                    while (kk8 < cvm.n_args) : (kk8 += 1) {
                        const a8 = cvm.args.int() + kk8;
                        if (a8 >= f.n_locals or !known[a8]) return no(f, "value call arg");
                    }
                    if (cvm.dst.int() >= f.n_locals) return no(f, "value call dst");
                    types[cvm.dst.int()] = elem[cvm.callee.int()];
                    known[cvm.dst.int()] = true;
                },
                .CallValue => |cv2| {
                    if (cv2.arg_names.len != 0 or cv2.type_args.len != 0) return no(f, "value call names/type args");
                    if (cv2.callee.int() >= f.n_locals) return no(f, "value callee");
                    if (types[cv2.callee.int()] == .object) {
                        // A call through a function VALUE: the body is decided
                        // at run time by which closure the value is, so the
                        // arguments and the result pass boxed.
                        const fc = cls[cv2.callee.int()] orelse return no(f, "value callee class");
                        const ar6 = funcClsArity(fc) orelse return no(f, "value callee is not callable");
                        if (cv2.n_args != ar6) return no(f, "value call arity");
                        var kk6: u32 = 0;
                        while (kk6 < cv2.n_args) : (kk6 += 1) {
                            const a6 = cv2.args.int() + kk6;
                            if (a6 >= f.n_locals or !known[a6]) return no(f, "value call arg");
                        }
                        if (cv2.dst.int() >= f.n_locals) return no(f, "value call dst");
                        types[cv2.dst.int()] = elem[cv2.callee.int()];
                        known[cv2.dst.int()] = true;
                        continue;
                    }
                    const li = lam[cv2.callee.int()] orelse return no(f, "value call to an unknown callee");
                    const bf = m.funcById(li.body) orelse return no(f, "lambda body missing");
                    // The lowering always gives a lambda an `it` slot, so a
                    // zero-argument call leaves one parameter unsupplied. It is
                    // unreachable in a lambda that declares none, and gets the
                    // type's zero.
                    if (cv2.n_args > bf.params.len) return no(f, "lambda arity");
                    var kk3: u32 = 0;
                    while (kk3 < cv2.n_args) : (kk3 += 1) {
                        const ar3 = cv2.args.int() + kk3;
                        if (ar3 >= f.n_locals or !known[ar3]) return no(f, "lambda arg");
                    }
                    if (cv2.dst.int() >= f.n_locals) return no(f, "lambda dst");
                    // A lambda declares no return type, so the answer is what
                    // its body compiles to — with the captures it was made
                    // with, since those are part of its signature here.
                    const ct2 = try gpa.alloc(CapInfo, li.captures.len);
                    defer gpa.free(ct2);
                    for (li.captures, 0..) |cr2, ci5| ct2[ci5] = .{ .ty = types[cr2.int()], .cls = cls[cr2.int()], .elem = elem[cr2.int()] };
                    var bc = (try eligible(gpa, m, prog, bf, globals, null, ct2)) orelse return no(f, "lambda body");
                    const rt7 = bc.ret;
                    bc.deinit(gpa);
                    types[cv2.dst.int()] = rt7;
                    if (rt7 == .object) cls[cv2.dst.int()] = classIndexOfName(m, bf.return_ty);
 if (refElemOf(cls[cv2.dst.int()], bf.return_ty)) |re_| elem[cv2.dst.int()] = re_;
                    elem_cls[cv2.dst.int()] = refElemCls(m, cls[cv2.dst.int()], bf.return_ty);
                    known[cv2.dst.int()] = true;
                },
                .Call => |c| {
                    // Type arguments say nothing about which body runs for a
                    // call the lowering already resolved.
                    if (c.dst.int() >= f.n_locals) return null;
                    const callee = m.funcById(c.func) orelse return no(f, "call target missing");
                    if (isLaunch(callee)) {
                        if (c.n_args < 1) return no(f, "launch arity");
                        const lr5 = c.args.int() + c.n_args - 1;
                        if (lr5 >= f.n_locals or !known[lr5]) return no(f, "launch block");
                        if (types[lr5] != .object) return no(f, "launch block is not a value");
                        if (c.dst.int() >= f.n_locals) return no(f, "launch dst");
                        types[c.dst.int()] = .object;
                        known[c.dst.int()] = true;
                        continue;
                    }
                    if (isRunBlocking(callee)) {
                        // The block is the root coroutine. It has to be a
                        // lambda whose body this program compiled: the driver
                        // resumes it by calling it.
                        if (c.n_args < 1) return no(f, "runBlocking arity");
                        const br = c.args.int() + c.n_args - 1;
                        if (br >= f.n_locals or !known[br]) return no(f, "runBlocking block");
                        const li3 = lam[br] orelse return no(f, "runBlocking block is not a lambda");
                        const bfn3 = m.funcById(li3.body) orelse return no(f, "runBlocking block body");
                        if (!bodySuspends(m, bfn3)) return no(f, "runBlocking block is not suspending");
                        if (c.dst.int() >= f.n_locals) return no(f, "runBlocking dst");
                        types[c.dst.int()] = .object;
                        known[c.dst.int()] = true;
                        continue;
                    }
                    if (isArrayOfNulls(callee)) {
                        const nr3 = c.args.int();
                        if (c.n_args != 1 or nr3 >= f.n_locals or !known[nr3]) return no(f, "array size");
                        if (types[nr3] != .i32) return no(f, "array size type");
                        if (c.dst.int() >= f.n_locals) return no(f, "array dst");
                        types[c.dst.int()] = .object;
                        cls[c.dst.int()] = ARRAY_CLS;
                        known[c.dst.int()] = true;
                        continue;
                    }
                    if (arrayOfIntrinsic(callee)) |maybe_kind| {
                        const aa2 = c.args.int();
                        var ka2: u32 = 0;
                        while (ka2 < c.n_args) : (ka2 += 1) {
                            if (aa2 + ka2 >= f.n_locals or !known[aa2 + ka2]) return no(f, "array arg");
                        }
                        if (c.dst.int() >= f.n_locals) return no(f, "array dst");
                        types[c.dst.int()] = .object;
                        cls[c.dst.int()] = ARRAY_CLS;
                        if (maybe_kind) |k2| {
                            const et2 = primArrayElem(k2);
                            var ka3: u32 = 0;
                            while (ka3 < c.n_args) : (ka3 += 1) {
                                if (types[aa2 + ka3] != et2) return no(f, "array element type");
                            }
                            elem[c.dst.int()] = et2;
                        }
                        known[c.dst.int()] = true;
                        continue;
                    }
                    if (listIntrinsic(callee)) |_| {
                        var et: ?Ty = null;
                        var k: u32 = 0;
                        while (k < c.n_args) : (k += 1) {
                            const ar = c.args.int() + k;
                            if (ar >= f.n_locals or !known[ar]) return no(f, "list element");
                            if (k == 0) et = types[ar] else if (et.? != types[ar]) et = null;
                            if (et == null) break;
                        }
                        if (c.dst.int() >= f.n_locals) return no(f, "list dst");
                        types[c.dst.int()] = .object;
                        cls[c.dst.int()] = LIST_CLS;
                        elem[c.dst.int()] = if (et) |t| (if (t == .object) .unit else t) else .unit;
                        if (elem[c.dst.int()] == .unit) {
                            elem_cls[c.dst.int()] = commonCls(m, cls, c.args.int(), c.n_args);
                        }
                        known[c.dst.int()] = true;
                        continue;
                    }
                    if (scalarIntrinsic(callee)) |si| {
                        const sa = c.args.int();
                        var ks: u32 = 0;
                        while (ks < c.n_args) : (ks += 1) {
                            if (sa + ks >= f.n_locals or !known[sa + ks]) return no(f, "intrinsic arg");
                        }
                        if (c.dst.int() >= f.n_locals) return no(f, "intrinsic dst");
                        switch (si) {
                            .print => {
                                if (c.n_args != 1) return no(f, "print arity");
                                if (types[sa] == .unit) return no(f, "print of Unit");
                                types[c.dst.int()] = .unit;
                            },
                            // The floating forms differ from C's: Kotlin's
                            // `max` propagates NaN and orders -0.0 below 0.0,
                            // where `fmax` does neither.
                            .max, .min => {
                                if (c.n_args != 2) return no(f, "intrinsic arity");
                                if (types[sa] != types[sa + 1]) return no(f, "intrinsic operand types");
                                if (types[sa] != .i32 and types[sa] != .i64) return no(f, "intrinsic operand type");
                                types[c.dst.int()] = types[sa];
                            },
                            .abs => {
                                if (c.n_args != 1) return no(f, "intrinsic arity");
                                if (types[sa] != .i32 and types[sa] != .i64) return no(f, "intrinsic operand type");
                                types[c.dst.int()] = types[sa];
                            },
                        }
                        known[c.dst.int()] = true;
                        continue;
                    }
                    if (isPrintln(callee)) {
                        if (c.n_args != 1) return no(f, "println arity");
                        const a0 = c.args.int();
                        if (a0 >= f.n_locals or !known[a0]) return no(f, "println arg");
                        if (types[a0] == .unit) return no(f, "println of Unit");
                        types[c.dst.int()] = .unit;
                        known[c.dst.int()] = true;
                    } else if (isDelay(callee)) {
                        if (c.n_args < 1) return no(f, "delay arity");
                        const mr = c.args.int();
                        if (mr >= f.n_locals or !known[mr]) return no(f, "delay argument");
                        if (types[mr] != .i32 and types[mr] != .i64) return no(f, "delay argument type");
                        if (c.dst.int() >= f.n_locals) return no(f, "delay dst");
                        types[c.dst.int()] = .unit;
                        known[c.dst.int()] = true;
                    } else {
                        if (!callee.hasBody()) {
                            // No Kotlin body, but the interpreter implements
                            // it: compiled code runs the same entry.
                            if (stdlibEntry(callee) != null) {
                                var ks9: u32 = 0;
                                while (ks9 < c.n_args) : (ks9 += 1) {
                                    const a9 = c.args.int() + ks9;
                                    if (a9 >= f.n_locals or !known[a9]) return no(f, "stdlib arg");
                                }
                                if (c.dst.int() >= f.n_locals) return no(f, "stdlib dst");
                                // The table answers a value; the DECLARATION
                                // says what kind, so a result that is a machine
                                // type comes back as one rather than staying
                                // boxed and refusing the next `+`.
                                const srt = tyOf(callee.return_ty) orelse Ty.object;
                                types[c.dst.int()] = srt;
                                if (srt == .object) {
                                    cls[c.dst.int()] = classIndexOfName(m, callee.return_ty);
                                    if (refElemOf(cls[c.dst.int()], callee.return_ty)) |re11| elem[c.dst.int()] = re11;
                    elem_cls[c.dst.int()] = refElemCls(m, cls[c.dst.int()], callee.return_ty);
                                }
                                known[c.dst.int()] = true;
                                continue;
                            }
                            return noCallee(f, callee, "no body for");
                        }
                        // A name several declarations answer, which these
                        // arguments do not separate, is decided from the
                        // VALUES at run time; the lowering's pick is one
                        // candidate, not the answer.
                        if (!callee.has_receiver_param and
                            ambiguousOverload(m, prog, callee.name, types, c.args.int(), c.n_args, c.arg_names))
                        {
                            return noCallee(f, callee, "overload of");
                        }
                        const has_vararg = for (callee.params) |p| {
                            if (p.is_vararg) break true;
                        } else false;
                        if (callee.params.len < c.n_args and !has_vararg) return noCallee(f, callee, "arity of");
                        const bnd = bindCallArgs(m, callee.params, c.args.int(), c.n_args, c.arg_names) orelse
                            return noCallee(f, callee, "argument binding of");
                        // A parameter nothing binds is filled by the thunk the
                        // declaration lowered for it, run with the arguments
                        // ahead of it.
                        // A parameter declared as a class the emitter lays
                        // out cannot take a RUNTIME value: a body that reads
                        // its fields would address a list, a range or a string
                        // as though it were an instance.
                        var ai9: u32 = 0;
                        while (ai9 < bnd.n) : (ai9 += 1) {
                            const areg9 = bnd.regs[ai9] orelse continue;
                            if (types[areg9] != .object) continue;
                            const got9 = cls[areg9] orelse continue;
                            if (!isBuiltinCls(got9)) continue;
                            const want9 = classIndexOfName(m, callee.params[ai9].ty) orelse continue;
                            if (isBuiltinCls(want9)) continue;
                            const wf9 = prog.of(want9) orelse continue;
                            // A supertype with no storage — `Any`, an
                            // interface — is satisfied by a runtime value; one
                            // with fields is not, and a body reading them would
                            // address a list or a range as an instance.
                            if (wf9.len == 0) continue;
                            return noCallee(f, callee, "a runtime value where an instance is declared by");
                        }
                        var di: u32 = 0;
                        while (di < bnd.n) : (di += 1) {
                            if (bnd.regs[di] != null) continue;
                            // A `vararg` nothing filled is the empty array, not
                            // a missing argument.
                            if (bnd.vararg_param != null and bnd.vararg_param.? == di) continue;
                            const dfid = prog.defaultThunk(callee.id, di) orelse return noCallee(f, callee, "arity of");
                            const dfn = m.funcById(dfid) orelse return no(f, "default thunk");
                            if (funcRetTy2(m, dfn) == null) return no(f, "default thunk type");
                        }
                        const rt = funcRetTy2(m, callee) orelse return no(f, "callee return type");
                        types[c.dst.int()] = rt;
                        if (rt == .object) cls[c.dst.int()] = callResultCls(m, callee);
 if (refElemOf(cls[c.dst.int()], callee.return_ty)) |re_| elem[c.dst.int()] = re_;
                    elem_cls[c.dst.int()] = refElemCls(m, cls[c.dst.int()], callee.return_ty);
                        known[c.dst.int()] = true;
                    }
                    var k: u32 = 0;
                    while (k < c.n_args) : (k += 1) {
                        const ar = c.args.int() + k;
                        if (ar >= f.n_locals or !known[ar]) return null;
                    }
                },
                else => return instRefuse(f, inst),
            }
        }
        switch (blk.terminator) {
            .Goto => {},
            .Branch => |br| {
                if (br.cond.int() >= f.n_locals or !known[br.cond.int()]) return null;
            },
            .Return => |r| {
                if (r) |rr| {
                    if (rr.int() >= f.n_locals or !known[rr.int()]) return no(f, "return value");
                }
            },
            // A block carrying a catch handler is refused above, so a program
            // that compiles has no handler anywhere and a throw always leaves
            // it. That is what makes an uncaught throw the whole story here.
            .Throw => |t| {
                if (t.int() >= f.n_locals or !known[t.int()]) return no(f, "throw value");
            },
            else => return no(f, "terminator"),
        }
    }
    // Resolve the result from the returned registers, which the body pass has
    // now typed. Disagreeing returns mean the emitter cannot name one C type.
    var saw_ret = false;
    var ret_cls: ?u32 = null;
    var ret_elem: Ty = .unit;
    // Only the blocks the body can reach: an unreachable one was never typed,
    // and its terminator names a register nothing defined.
    const live_ret = try gpa.alloc(bool, f.blocks.len);
    defer gpa.free(live_ret);
    @memset(live_ret, false);
    for (order) |bi| live_ret[bi] = true;
    for (f.blocks, 0..) |*blk, bi2| {
        if (!live_ret[bi2]) continue;
        if (blk.terminator != .Return) continue;
        const rr = blk.terminator.Return orelse continue;
        if (rr.int() >= f.n_locals or !known[rr.int()]) return no(f, "return register");
        if (!saw_ret) {
            ret = types[rr.int()];
            ret_cls = cls[rr.int()];
            ret_elem = elem[rr.int()];
            saw_ret = true;
        } else if (ret != types[rr.int()]) return no(f, "returns differ");
    }
    if (!saw_ret) ret = .unit;

    var n_slots: u32 = 0;
    var r: u32 = 0;
    while (r < f.n_locals) : (r += 1) {
        if (types[r] != .object) continue;
        slot[r] = @intCast(n_slots);
        n_slots += 1;
    }
    return .{ .f = f, .caps = caps, .params = params, .types = types, .cls = cls, .elem = elem, .elem_cls = elem_cls, .lam = lam, .slot = slot, .n_slots = n_slots, .ret = ret, .ret_cls = ret_cls, .ret_elem = ret_elem, .suspends = suspends, .bare = bare };
}
