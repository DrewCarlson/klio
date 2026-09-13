//! Output assembly: the includes, the statics, the declarations and the
//! definitions, written in the order a C compiler accepts them.
const std = @import("std");
const stdlib = @import("stdlib");
const ir = @import("ir");
const Func = ir.Func;
const Module = ir.Module;
const cgen = @import("../cgen.zig");

const CapInfo = cgen.CapInfo;
const ClassLayout = cgen.ClassLayout;
const Compiled = cgen.Compiled;
const Error = cgen.Error;
const FUNC_MAX_ARITY = cgen.FUNC_MAX_ARITY;
const FieldInfo = cgen.FieldInfo;
const FuncDefaults = cgen.FuncDefaults;
const Global = cgen.Global;
const LIST_CLS = cgen.LIST_CLS;
const LambdaUse = cgen.LambdaUse;
const Parent = cgen.Parent;
const Program = cgen.Program;
const PropUse = cgen.PropUse;
const SingletonUse = cgen.SingletonUse;
const SlotUse = cgen.SlotUse;
const Ty = cgen.Ty;
const acceptedRet = cgen.acceptedRet;
const accessOwner = cgen.accessOwner;
const accessPlan = cgen.accessPlan;
const arrayOfIntrinsic = cgen.arrayOfIntrinsic;
const bindCallArgs = cgen.bindCallArgs;
const boxExpr = cgen.boxExpr;
const buildThrowTable = cgen.buildThrowTable;
const classFields = cgen.classFields;
const companionObjectNamed = cgen.companionObjectNamed;
const companionReceiver = cgen.companionReceiver;
const ctorDefault = cgen.ctorDefault;
const ctorParamTy = cgen.ctorParamTy;
const eligible = cgen.eligible;
const enumEntries = cgen.enumEntries;
const enumEntryIndex = cgen.enumEntryIndex;
const expectedFnType = cgen.expectedFnType;
const fieldIndex = cgen.fieldIndex;
const funcClsArity = cgen.funcClsArity;
const funcRetTy2 = cgen.funcRetTy2;
const globalIndex = cgen.globalIndex;
const isArrayOfNulls = cgen.isArrayOfNulls;
const isArrayTypeName = cgen.isArrayTypeName;
const isBuiltinCls = cgen.isBuiltinCls;
const isDelay = cgen.isDelay;
const isLaunch = cgen.isLaunch;
const isPrintln = cgen.isPrintln;
const isRunBlocking = cgen.isRunBlocking;
const isThrowableClass = cgen.isThrowableClass;
const isToStringCall = cgen.isToStringCall;
const lambdaParams = cgen.lambdaParams;
const layoutFor = cgen.layoutFor;
const listIntrinsic = cgen.listIntrinsic;
const mangleName = cgen.mangleName;
const memberRoot = cgen.memberRoot;
const no = cgen.no;
const numConv = cgen.numConv;
const numConvVirtual = cgen.numConvVirtual;
const objectClassNamed = cgen.objectClassNamed;
const ownLayout = cgen.ownLayout;
const plainFieldName = cgen.plainFieldName;
const rendersToString = cgen.rendersToString;
const scalarIntrinsic = cgen.scalarIntrinsic;
const slotImpl = cgen.slotImpl;
const staticClassOf = cgen.staticClassOf;
const stdlibEntry = cgen.stdlibEntry;
const toStringOf = cgen.toStringOf;
const traceOn = cgen.traceOn;
const tyOf = cgen.tyOf;
const typeHasSlot = cgen.typeHasSlot;
const typeReaches = cgen.typeReaches;
const unboxExpr = cgen.unboxExpr;
const unsignedTypeOf = cgen.unsignedTypeOf;
const virtualProp = cgen.virtualProp;
const writeBody = cgen.writeBody;
const writeCtorBody = cgen.writeCtorBody;
const writeCtorProto = cgen.writeCtorProto;
const writeProto = cgen.writeProto;
const writeSymbol = cgen.writeSymbol;
const zeroKindOf = cgen.zeroKindOf;

/// Emit the whole program. Returns false when `main` itself is outside the
/// subset, which is the caller's signal to fall back.
pub fn emit(
    gpa: std.mem.Allocator,
    m: *const Module,
    entry: *const Func,
    globals: []const Global,
    layouts: []const ClassLayout,
    defaults: []const FuncDefaults,
    w: *std.Io.Writer,
    src_path: []const u8,
) Error!bool {
    var throws = try buildThrowTable(gpa, m);
    defer throws.deinit(gpa);

    // Resolve every class's layout: the emitter asks about the same classes
    // repeatedly, and resolving walks the class table each time. A property
    // the source left unannotated takes the type its initializer computes, and
    // asking the initializer needs the layouts resolved so far — so the table
    // is built to a fixed point rather than in one pass. The passes only ever
    // ADD fields, so it settles in as many rounds as an initializer chain is
    // deep.
    const table = try gpa.alloc(?[]const FieldInfo, m.classes.items.len);
    defer {
        for (table) |maybe| {
            if (maybe) |fs| gpa.free(fs);
        }
        gpa.free(table);
    }
    const parent_table = try gpa.alloc(?Parent, m.classes.items.len);
    defer gpa.free(parent_table);
    @memset(table, null);
    @memset(parent_table, null);
    var prog: Program = .{ .fields = table, .parents = parent_table, .layouts = layouts, .throws = throws, .defaults = defaults };
    const complete_table = try gpa.alloc(bool, m.classes.items.len);
    defer gpa.free(complete_table);
    @memset(complete_table, false);
    {
        const MAX_PASSES: u32 = 8;
        var pass: u32 = 0;
        while (pass < MAX_PASSES) : (pass += 1) {
            var grew_layout = false;
            const last = pass + 1 == MAX_PASSES;
            for (table, 0..) |*slot_p, i| {
                if (complete_table[i]) continue;
                const prev: ?*const Program = if (pass == 0) null else &prog;
                const laid = (try classFields(gpa, m, layouts, @enumFromInt(i), prev, globals, last)) orelse continue;
                const before: usize = if (slot_p.*) |old_fs| old_fs.len else std.math.maxInt(usize);
                complete_table[i] = laid.complete;
                if (before == laid.fields.len and !laid.complete) {
                    gpa.free(laid.fields);
                    continue;
                }
                if (slot_p.*) |old_fs| gpa.free(old_fs);
                slot_p.* = laid.fields;
                parent_table[i] = laid.parent;
                grew_layout = true;
            }
            if (!grew_layout) break;
        }
        // A class still missing a property has no usable layout: handing out a
        // partial one would address the wrong field.
        for (table, 0..) |*slot_p, i| {
            if (complete_table[i]) continue;
            if (slot_p.*) |old_fs| gpa.free(old_fs);
            slot_p.* = null;
            parent_table[i] = null;
        }
    }
    var accepted: std.ArrayList(Compiled) = .empty;
    defer {
        for (accepted.items) |*c| c.deinit(gpa);
        accepted.deinit(gpa);
    }
    var seen = std.AutoHashMap(u32, void).init(gpa);
    defer seen.deinit();
    const Pending = struct { f: *const Func, synth: ?[]const ir.Param, caps: []const CapInfo = &.{} };
    // Capture signatures outlive the queue entry that carried them.
    var synth_owned: std.ArrayList([]ir.Param) = .empty;
    defer {
        for (synth_owned.items) |sp| gpa.free(sp);
        synth_owned.deinit(gpa);
    }
    var cap_owned: std.ArrayList([]CapInfo) = .empty;
    defer {
        for (cap_owned.items) |ct| gpa.free(ct);
        cap_owned.deinit(gpa);
    }
    var queue: std.ArrayList(Pending) = .empty;
    defer queue.deinit(gpa);

    // Reachable closure from the entry: only what the program can call is
    // emitted, which is what keeps a whole-stdlib lowering from becoming tens
    // of thousands of C functions.
    try queue.append(gpa, .{ .f = entry, .synth = null });
    try seen.put(entry.id.int(), {});
    // Only a class the program CONSTRUCTS can answer a virtual call, so the
    // two sets grow together: draining the queue discovers constructions and
    // call sites, and pairing them can queue more bodies, which can construct
    // more classes. The walk runs until neither set grows.
    var constructed: std.ArrayList(u32) = .empty;
    defer constructed.deinit(gpa);
    var vsites: std.ArrayList(ir.MethodSlotId) = .empty;
    defer vsites.deinit(gpa);
    // A single refusal anywhere in the reachable set fails the whole emission:
    // a compiled program has no interpreter to fall back INTO, so a body it
    // cannot call is not a slow path, it is a missing one.
    while (true) {
    while (queue.pop()) |pending| {
        const f = pending.f;
        const c = (try eligible(gpa, m, prog, f, globals, pending.synth, pending.caps)) orelse return false;
        try accepted.append(gpa, c);
        for (f.blocks) |*blk| {
            for (blk.insts) |*inst| {
                // A function's NAME in value position: the body it refers to
                // is reachable through the reference alone.
                if (inst.* == .LoadGlobal) {
                    if (c.lam[inst.LoadGlobal.dst.int()]) |li11| {
                        const rfn = m.funcById(li11.body) orelse return false;
                        if (!seen.contains(rfn.id.int())) {
                            try seen.put(rfn.id.int(), {});
                            try queue.append(gpa, .{ .f = rfn, .synth = null });
                        }
                    }
                }
                // The one instance an `object` declaration has, named either
                // by its own name or through the class whose companion it is.
                const singleton_cid: ?u32 = switch (inst.*) {
                    .LoadGlobal => |lg4| blk4: {
                        if (lg4.name.int() >= m.consts.items.len) break :blk4 null;
                        const gn4 = m.consts.items[lg4.name.int()];
                        if (gn4 != .String) break :blk4 null;
                        break :blk4 objectClassNamed(m, prog, gn4.String) orelse
                            companionObjectNamed(m, prog, gn4.String);
                    },
                    .CallMember => |cm4| blk6: {
                        break :blk6 companionReceiver(m, prog, c.types, c.cls, cm4.receiver.int());
                    },
                    .GetField => |gf4| blk5: {
                        if (gf4.field.int() >= m.consts.items.len) break :blk5 null;
                        const fn4 = m.consts.items[gf4.field.int()];
                        if (fn4 != .String) break :blk5 null;
                        if (staticClassOf(c.types, c.cls, gf4.receiver.int())) |sc4| {
                            if (sc4 >= m.classes.items.len) break :blk5 null;
                            break :blk5 companionObjectNamed(m, prog, m.classes.items[sc4].fqn);
                        }
                        const rc4 = c.cls[gf4.receiver.int()] orelse break :blk5 null;
                        break :blk5 accessOwner(m, prog, rc4, fn4.String, false);
                    },
                    else => null,
                };
                if (singleton_cid) |oc| {
                    var have_o = false;
                    for (constructed.items) |uo| {
                        if (uo == oc) have_o = true;
                    }
                    if (!have_o) try constructed.append(gpa, oc);
                    for (prog.of(oc).?) |fd| {
                        const ifid = fd.init orelse continue;
                        const ifn = m.funcById(ifid) orelse return false;
                        if (seen.contains(ifn.id.int())) continue;
                        try seen.put(ifn.id.int(), {});
                        try queue.append(gpa, .{ .f = ifn, .synth = null });
                    }
                }
                // A referenced global drags in the thunk that initializes it.
                // Only referenced ones: the list carries every top-level
                // property in the program AND its libraries, and pulling them
                // all in would compile the whole stdlib to run `main`.
                const gname: ?ir.ConstId = switch (inst.*) {
                    .LoadGlobal => |lg| lg.name,
                    .StoreGlobal => |sg| sg.name,
                    else => null,
                };
                if (gname) |cid| {
                    if (cid.int() < m.consts.items.len) {
                        const gn = m.consts.items[cid.int()];
                        if (gn == .String) {
                            if (globalIndex(globals, gn.String)) |gi| {
                                const gf = m.funcById(globals[gi].func) orelse return false;
                                if (!seen.contains(gf.id.int())) {
                                    try seen.put(gf.id.int(), {});
                                    try queue.append(gpa, .{ .f = gf, .synth = null });
                                }
                            }
                        }
                    }
                    continue;
                }
                // Constructing a class runs the thunks that initialize its body
                // properties, so those are reachable too.
                if (inst.* == .AstLambda) {
                    const al2 = inst.AstLambda;
                    const bfid = al2.body_func orelse return false;
                    const bfn = m.funcById(bfid) orelse return false;
                    if (!seen.contains(bfn.id.int())) {
                        // The body is compiled against what this site captured:
                        // those values arrive as leading arguments. Its own
                        // parameters carry no declared types, so they come from
                        // the function type the value is expected to have —
                        // the same signature `eligible` typed it against.
                        const ct = try gpa.alloc(CapInfo, al2.captures.len);
                        for (al2.captures, 0..) |cr, ci4| ct[ci4] = .{ .ty = c.types[cr.int()], .cls = c.cls[cr.int()], .elem = c.elem[cr.int()] };
                        try cap_owned.append(gpa, ct);
                        var lsyn: ?[]ir.Param = null;
                        if (expectedFnType(m, c.f, al2.dst)) |t6| {
                            lsyn = try lambdaParams(gpa, bfn, t6);
                        }
                        if (lsyn) |ls6| try synth_owned.append(gpa, ls6);
                        try seen.put(bfn.id.int(), {});
                        try queue.append(gpa, .{ .f = bfn, .synth = lsyn, .caps = ct });
                    }
                    continue;
                }
                if (inst.* == .CallMember) {
                    const cm3 = inst.CallMember;
                    if (numConv(m, cm3) == null) if (c.cls[cm3.receiver.int()]) |rc8| {
                        if (!isBuiltinCls(rc8) and cm3.name.int() < m.consts.items.len) {
                            const nmc = m.consts.items[cm3.name.int()];
                            if (nmc == .String and fieldIndex(prog, rc8, nmc.String) == null) {
                                if (memberRoot(m, prog, rc8, plainFieldName(nmc.String), cm3.n_args)) |root8| {
                                    var have8 = false;
                                    for (vsites.items) |sv2| {
                                        if (sv2.int() == root8.id.int()) have8 = true;
                                    }
                                    if (!have8) try vsites.append(gpa, ir.MethodSlotId.from(root8.id.int()));
                                }
                            }
                        }
                    };
                    continue;
                }
                // Rendering a value calls its `toString`, so that slot is a
                // call site like any other.
                {
                    const rendered: ?u32 = switch (inst.*) {
                        .BinOp => |b3| if (b3.op == .StringConcat or c.types[b3.dst.int()] == .object) b3.lhs.int() else null,
                        else => null,
                    };
                    if (rendered) |rr4| {
                        for ([_]u32{ rr4, inst.BinOp.rhs.int() }) |reg4| {
                            if (c.types[reg4] != .object) continue;
                            const rc4b = c.cls[reg4] orelse continue;
                            const ts4 = toStringOf(m, prog, rc4b) orelse continue;
                            var have4b = false;
                            for (vsites.items) |sv4| {
                                if (sv4.int() == ts4.id.int()) have4b = true;
                            }
                            if (!have4b) try vsites.append(gpa, ir.MethodSlotId.from(ts4.id.int()));
                        }
                    }
                }
                if (inst.* == .Call) {
                    const pc4 = m.funcById(inst.Call.func);
                    if (pc4) |pf4| {
                        if ((isPrintln(pf4) or scalarIntrinsic(pf4) == .print) and inst.Call.n_args == 1) {
                            const a4 = inst.Call.args.int();
                            if (c.types[a4] == .object) {
                                if (c.cls[a4]) |rc4c| {
                                    if (toStringOf(m, prog, rc4c)) |ts4b| {
                                        var have4c = false;
                                        for (vsites.items) |sv5| {
                                            if (sv5.int() == ts4b.id.int()) have4c = true;
                                        }
                                        if (!have4c) try vsites.append(gpa, ir.MethodSlotId.from(ts4b.id.int()));
                                    }
                                }
                            }
                        }
                    }
                }
                if (inst.* == .CallVirtual) {
                    const cv2 = inst.CallVirtual;
                    if (numConvVirtual(m, cv2) == null) {
                        var have_site = false;
                        for (vsites.items) |sv| {
                            if (sv == cv2.slot) have_site = true;
                        }
                        if (!have_site) try vsites.append(gpa, cv2.slot);
                    }
                }
                // Reading an entry off its enum's name builds that entry:
                // the thunks its declaration writes for the constructor run,
                // and so do the enum's own body-property initializers.
                if (inst.* == .GetField) {
                    const gq = inst.GetField;
                    if (staticClassOf(c.types, c.cls, gq.receiver.int())) |sq| {
                        const eqn = m.consts.items[gq.field.int()];
                        if (eqn == .String) {
                            const all_entries = std.mem.eql(u8, plainFieldName(eqn.String), "entries") and
                                enumEntries(m, prog, sq).len != 0;
                            if (all_entries) {
                                var have_q5 = false;
                                for (constructed.items) |uq| {
                                    if (uq == sq) have_q5 = true;
                                }
                                if (!have_q5) try constructed.append(gpa, sq);
                                const ents6 = enumEntries(m, prog, sq);
                                for (ents6) |e6| {
                                    for (e6.args) |afid6| {
                                        const afn6 = m.funcById(afid6) orelse return false;
                                        if (seen.contains(afn6.id.int())) continue;
                                        try seen.put(afn6.id.int(), {});
                                        try queue.append(gpa, .{ .f = afn6, .synth = null });
                                    }
                                }
                                for (prog.of(sq).?) |fd6| {
                                    if (fd6.from_parent or fd6.preset) continue;
                                    const ifid6 = fd6.init orelse continue;
                                    const ifn6 = m.funcById(ifid6) orelse return false;
                                    if (seen.contains(ifn6.id.int())) continue;
                                    try seen.put(ifn6.id.int(), {});
                                    try queue.append(gpa, .{ .f = ifn6, .synth = null });
                                }
                                continue;
                            }
                            if (enumEntryIndex(m, prog, sq, plainFieldName(eqn.String))) |eqi| {
                                var have_q = false;
                                for (constructed.items) |uq| {
                                    if (uq == sq) have_q = true;
                                }
                                if (!have_q) try constructed.append(gpa, sq);
                                const ents3 = enumEntries(m, prog, sq);
                                for (ents3[eqi].args) |afid| {
                                    const afn2 = m.funcById(afid) orelse return false;
                                    if (seen.contains(afn2.id.int())) continue;
                                    try seen.put(afn2.id.int(), {});
                                    try queue.append(gpa, .{ .f = afn2, .synth = null });
                                }
                                for (prog.of(sq).?) |fd2| {
                                    if (fd2.from_parent or fd2.preset) continue;
                                    const ifid2 = fd2.init orelse continue;
                                    const ifn2 = m.funcById(ifid2) orelse return false;
                                    if (seen.contains(ifn2.id.int())) continue;
                                    try seen.put(ifn2.id.int(), {});
                                    try queue.append(gpa, .{ .f = ifn2, .synth = null });
                                }
                                continue;
                            }
                        }
                    }
                }
                // A bare name inside an inlined receiver body resolved to a
                // computed property or to a top-level one; either way what it
                // resolved to has to be compiled.
                if (c.bare.get(inst)) |res| {
                    blkbare: switch (res) {
                        .field => {},
                        .construct => |bcid2| {
                            // Constructing runs the class's own initializers,
                            // which the construction walk below queues.
                            var have_bc = false;
                            for (constructed.items) |uc2| {
                                if (uc2 == bcid2) have_bc = true;
                            }
                            if (!have_bc) try constructed.append(gpa, bcid2);
                            const bfd2 = prog.of(bcid2) orelse return false;
                            for (bfd2) |fdx| {
                                if (fdx.from_parent) continue;
                                const ifx = fdx.init orelse continue;
                                const ifnx = m.funcById(ifx) orelse return false;
                                if (seen.contains(ifnx.id.int())) continue;
                                try seen.put(ifnx.id.int(), {});
                                try queue.append(gpa, .{ .f = ifnx, .synth = null });
                            }
                            const bdef2 = &m.classes.items[bcid2];
                            var dpx: usize = 0;
                            while (dpx < bdef2.primary_params.len) : (dpx += 1) {
                                const dfx = ctorDefault(prog.layouts, bdef2, dpx) orelse continue;
                                const dfnx = m.funcById(dfx) orelse return false;
                                if (seen.contains(dfnx.id.int())) continue;
                                try seen.put(dfnx.id.int(), {});
                                const csynx = try gpa.alloc(ir.Param, 1 + bdef2.primary_params.len);
                                try synth_owned.append(gpa, csynx);
                                csynx[0] = .{
                                    .name = "$ctor_default_recv",
                                    .ty = .{ .name = "", .nullable = true, .args = &.{} },
                                    .default = null,
                                };
                                @memcpy(csynx[1..], bdef2.primary_params);
                                try queue.append(gpa, .{ .f = dfnx, .synth = csynx });
                            }
                            if (prog.parentOf(bcid2) != null) return false;
                        },
                        .accessor => |ac| {
                            const afn3 = m.funcById(ac.func) orelse return false;
                            if (!seen.contains(afn3.id.int())) {
                                try seen.put(afn3.id.int(), {});
                                try queue.append(gpa, .{ .f = afn3, .synth = null });
                            }
                        },
                        .global => {
                            const bname: ?[]const u8 = switch (inst.*) {
                                .LoadFromThisOrGlobal => |l3| m.consts.items[l3.name.int()].String,
                                .StoreToThisOrGlobal => |s3| m.consts.items[s3.name.int()].String,
                                else => null,
                            };
                            if (bname) |bn3| {
                                if (globalIndex(globals, bn3)) |gi3| {
                                    const gfn3 = m.funcById(globals[gi3].func) orelse return false;
                                    if (!seen.contains(gfn3.id.int())) {
                                        try seen.put(gfn3.id.int(), {});
                                        try queue.append(gpa, .{ .f = gfn3, .synth = null });
                                    }
                                }
                            }
                        },
                        .member => |mb| {
                            // Every class beneath the receiver's type may
                            // answer, which the virtual pairing then queues.
                            var have_m = false;
                            for (vsites.items) |sv6| {
                                if (sv6.int() == mb.slot) have_m = true;
                            }
                            if (!have_m) try vsites.append(gpa, ir.MethodSlotId.from(mb.slot));
                        },
                        .call => |cf| {
                            const cfn = m.funcById(cf) orelse return false;
                            if (isPrintln(cfn) or scalarIntrinsic(cfn) != null or
                                listIntrinsic(cfn) != null or arrayOfIntrinsic(cfn) != null or
                                isArrayOfNulls(cfn)) break :blkbare;
                            if (!seen.contains(cfn.id.int())) {
                                try seen.put(cfn.id.int(), {});
                                try queue.append(gpa, .{ .f = cfn, .synth = null });
                            }
                            // A parameter the call leaves unbound runs the
                            // thunk the declaration lowered for it.
                            if (inst.* == .CallMemberOrGlobal) {
                                const cgq = inst.CallMemberOrGlobal;
                                if (bindCallArgs(m, cfn.params, cgq.args.int(), cgq.n_args, cgq.arg_names)) |bq| {
                                    var dq2: u32 = 0;
                                    while (dq2 < bq.n) : (dq2 += 1) {
                                        if (bq.regs[dq2] != null) continue;
                                        const dfq = prog.defaultThunk(cfn.id, dq2) orelse break;
                                        const dfnq = m.funcById(dfq) orelse return false;
                                        if (seen.contains(dfnq.id.int())) continue;
                                        try seen.put(dfnq.id.int(), {});
                                        try queue.append(gpa, .{ .f = dfnq, .synth = null });
                                    }
                                }
                            }
                        },
                    }
                    continue;
                }
                // A computed property reads and writes through its accessors,
                // so those are reachable wherever the property is touched.
                const acc: ?struct { rc: u32, name: ir.ConstId, set: bool } = switch (inst.*) {
                    .GetField => |gf2| blk3: {
                        const rcx = c.cls[gf2.receiver.int()] orelse break :blk3 null;
                        break :blk3 .{ .rc = rcx, .name = gf2.field, .set = false };
                    },
                    .SetField => |sf2| blk4: {
                        const rcx = c.cls[sf2.receiver.int()] orelse break :blk4 null;
                        break :blk4 .{ .rc = rcx, .name = sf2.field, .set = true };
                    },
                    else => null,
                };
                if (acc) |a2| {
                    if (!isBuiltinCls(a2.rc) and a2.name.int() < m.consts.items.len) {
                        const anm = m.consts.items[a2.name.int()];
                        if (anm == .String) {
                            switch (accessPlan(m, prog, a2.rc, anm.String, a2.set)) {
                                .accessor => |fid3| {
                                    const afn = m.funcById(fid3) orelse return false;
                                    if (!seen.contains(afn.id.int())) {
                                        try seen.put(afn.id.int(), {});
                                        try queue.append(gpa, .{ .f = afn, .synth = null });
                                    }
                                },
                                .virtual => {
                                    // Every class beneath the receiver's type
                                    // may answer, so every getter is reachable.
                                    const pn = plainFieldName(anm.String);
                                    var pc: u32 = 0;
                                    while (pc < m.classes.items.len) : (pc += 1) {
                                        if (prog.of(pc) == null) continue;
                                        if (!typeReaches(m, pc, a2.rc)) continue;
                                        const pg = prog.accessor(m, pc, pn, .get) orelse continue;
                                        const pfn = m.funcById(pg) orelse return false;
                                        if (seen.contains(pfn.id.int())) continue;
                                        try seen.put(pfn.id.int(), {});
                                        try queue.append(gpa, .{ .f = pfn, .synth = null });
                                    }
                                },
                                .field, .none => {},
                            }
                        }
                    }
                    continue;
                }
                if (inst.* == .NewInstance) {
                    if (inst.NewInstance.class.int() < m.classes.items.len and
                        (isArrayTypeName(m.classes.items[inst.NewInstance.class.int()].name) or
                            unsignedTypeOf(m.classes.items[inst.NewInstance.class.int()].name) != null)) continue;
                    {
                        const nc2 = inst.NewInstance.class.int();
                        var have_c = false;
                        for (constructed.items) |uc| {
                            if (uc == nc2) have_c = true;
                        }
                        if (!have_c) try constructed.append(gpa, nc2);
                    }
                    // Constructing a class runs every initializer in its chain:
                    // each class's body-property thunks, and the thunks it
                    // passes to its superclass's constructor.
                    var walk: ?u32 = inst.NewInstance.class.int();
                    var steps: u32 = 0;
                    while (walk) |wc| : (steps += 1) {
                        if (steps > 32) break;
                        const fds = prog.of(wc) orelse break;
                        const wdef = &m.classes.items[wc];
                        // Constructing a class runs its init blocks too.
                        if (ownLayout(prog, wdef.name)) |ol| {
                            for (ol.init_blocks) |ibf2| {
                                const ibn2 = m.funcById(ibf2) orelse return false;
                                if (seen.contains(ibn2.id.int())) continue;
                                try seen.put(ibn2.id.int(), {});
                                try queue.append(gpa, .{ .f = ibn2, .synth = null });
                            }
                        }
                        // And the thunk behind every constructor parameter the
                        // construction may omit.
                        if (wc == inst.NewInstance.class.int()) {
                            var dpi: usize = 0;
                            while (dpi < wdef.primary_params.len) : (dpi += 1) {
                                const dfd = ctorDefault(prog.layouts, wdef, dpi) orelse continue;
                                const dfn5 = m.funcById(dfd) orelse return false;
                                if (seen.contains(dfn5.id.int())) continue;
                                try seen.put(dfn5.id.int(), {});
                                // Like a superclass-argument thunk, it
                                // declares no parameters and reads its
                                // caller's positionally: a synthesized
                                // receiver slot first, then the constructor
                                // arguments AHEAD of the one it fills.
                                const csyn = try gpa.alloc(ir.Param, 1 + wdef.primary_params.len);
                                try synth_owned.append(gpa, csyn);
                                csyn[0] = .{
                                    .name = "$ctor_default_recv",
                                    .ty = .{ .name = "", .nullable = true, .args = &.{} },
                                    .default = null,
                                };
                                @memcpy(csyn[1..], wdef.primary_params);
                                try queue.append(gpa, .{ .f = dfn5, .synth = csyn });
                            }
                        }
                        for (fds) |fd| {
                            if (fd.from_parent) continue;
                            const ifid = fd.init orelse continue;
                            const ifn = m.funcById(ifid) orelse return false;
                            if (seen.contains(ifn.id.int())) continue;
                            try seen.put(ifn.id.int(), {});
                            try queue.append(gpa, .{ .f = ifn, .synth = null });
                        }
                        const pp = prog.parentOf(wc) orelse break;
                        for (pp.args) |tf| {
                            const ifn = m.funcById(tf) orelse return false;
                            if (seen.contains(ifn.id.int())) continue;
                            try seen.put(ifn.id.int(), {});
                            // A superclass-argument thunk declares no
                            // parameters and reads its class's constructor
                            // arguments positionally, so it compiles against
                            // them.
                            try queue.append(gpa, .{ .f = ifn, .synth = wdef.primary_params });
                        }
                        walk = pp.cid;
                    }
                    continue;
                }
                if (inst.* != .Call) continue;
                const callee = m.funcById(inst.Call.func) orelse return false;
                if (isPrintln(callee) or listIntrinsic(callee) != null or scalarIntrinsic(callee) != null or
                    arrayOfIntrinsic(callee) != null or isArrayOfNulls(callee) or isRunBlocking(callee) or
                    isDelay(callee) or isLaunch(callee)) continue;
                // A declaration the interpreter implements has no body to
                // compile: the call reaches the same entry the interpreter
                // reaches.
                if (!callee.hasBody() and stdlibEntry(callee) != null) continue;
                // A call that leaves a parameter unbound runs the thunk for it.
                const bnd3 = bindCallArgs(m, callee.params, inst.Call.args.int(), inst.Call.n_args, inst.Call.arg_names) orelse
                    return false;
                var dq: u32 = 0;
                while (dq < bnd3.n) : (dq += 1) {
                    if (bnd3.regs[dq] != null) continue;
                    const dfid2 = prog.defaultThunk(callee.id, dq) orelse break;
                    const dfn2 = m.funcById(dfid2) orelse return false;
                    if (seen.contains(dfn2.id.int())) continue;
                    try seen.put(dfn2.id.int(), {});
                    // The thunk reads the parameters ahead of its own
                    // positionally, so it compiles against the callee's
                    // signature up to that point.
                    try queue.append(gpa, .{ .f = dfn2, .synth = callee.params[0..dq] });
                }
                if (seen.contains(callee.id.int())) continue;
                try seen.put(callee.id.int(), {});
                try queue.append(gpa, .{ .f = callee, .synth = null });
            }
        }
    }
        // Every construction the walk found, against every virtual call site
        // it found. A class the program never builds answers nothing, which is
        // what keeps an abstract library base out of the compile.
        var grew_reach = false;
        for (vsites.items) |slot| {
            for (constructed.items) |cid| {
                const impl = slotImpl(m, prog, cid, slot) orelse {
                    // The class has the member in its type but no body for it:
                    // it satisfies the interface by DELEGATION, which forwards
                    // to another object at run time. Refusing keeps that a
                    // refusal rather than an AbstractMethodError in a compiled
                    // program.
                    const root9 = m.funcById(ir.FuncId.from(slot.int())) orelse continue;
                    if (typeHasSlot(m, cid, root9)) {
                        if (traceOn()) {
                            std.debug.print("[cgen] refuse {s}: `{s}` is satisfied by delegation\n", .{
                                m.classes.items[cid].name, root9.name,
                            });
                        }
                        return false;
                    }
                    continue;
                };
                // An override declaring more parameters than the site supplies
                // fills them from its own default thunks, so those are
                // reachable wherever the dispatcher is.
                const vroot = m.funcById(ir.FuncId.from(slot.int()));
                var vk: u32 = 1;
                while (vk < impl.params.len) : (vk += 1) {
                    const vfid = prog.defaultThunk(impl.id, vk) orelse
                        (if (vroot) |vr| prog.defaultThunk(vr.id, vk) else null) orelse continue;
                    const vfn = m.funcById(vfid) orelse return false;
                    if (seen.contains(vfn.id.int())) continue;
                    try seen.put(vfn.id.int(), {});
                    try queue.append(gpa, .{ .f = vfn, .synth = impl.params[0..vk] });
                    grew_reach = true;
                }
                if (seen.contains(impl.id.int())) continue;
                try seen.put(impl.id.int(), {});
                try queue.append(gpa, .{ .f = impl, .synth = null });
                grew_reach = true;
            }
        }
        if (!grew_reach) break;
    }

    // Printing a floating value is the one place where C's formatting and
    // Kotlin's disagree, so the helper rides along only when it is used.
    // A program with any handler carries the try machinery, and its throws go
    // through it rather than straight out.
    var uses_try = false;
    for (accepted.items) |*c| {
        for (c.f.blocks) |*blk| {
            if (blk.catches.len != 0) uses_try = true;
        }
    }

    // Virtual call sites: each distinct slot gets one dispatcher, switching on
    // the receiver's class.
    var used_slots: std.ArrayList(SlotUse) = .empty;
    defer used_slots.deinit(gpa);
    for (accepted.items) |*c| {
        for (c.f.blocks) |*blk| {
            for (blk.insts) |*inst| {
                if (inst.* == .CallMember) {
                    const cm2 = inst.CallMember;
                    if (numConv(m, cm2) != null) continue;
                    if (companionReceiver(m, prog, c.types, c.cls, cm2.receiver.int())) |cc8| {
                        const root8 = memberRoot(m, prog, cc8, plainFieldName(m.consts.items[cm2.name.int()].String), cm2.n_args) orelse continue;
                        var have8 = false;
                        for (used_slots.items) |u| {
                            if (u.slot == root8.id.int()) have8 = true;
                        }
                        if (!have8) try used_slots.append(gpa, .{ .slot = root8.id.int(), .n_args = cm2.n_args });
                        continue;
                    }
                    const rc7 = c.cls[cm2.receiver.int()] orelse continue;
                    if (isBuiltinCls(rc7)) continue;
                    if (fieldIndex(prog, rc7, m.consts.items[cm2.name.int()].String) != null) continue;
                    const root7 = memberRoot(m, prog, rc7, plainFieldName(m.consts.items[cm2.name.int()].String), cm2.n_args) orelse continue;
                    var have7 = false;
                    for (used_slots.items) |u| {
                        if (u.slot == root7.id.int()) have7 = true;
                    }
                    if (!have7) try used_slots.append(gpa, .{ .slot = root7.id.int(), .n_args = cm2.n_args });
                    continue;
                }
                {
                    var regs4: [2]?u32 = .{ null, null };
                    switch (inst.*) {
                        .BinOp => |b5| {
                            if (c.types[b5.dst.int()] == .object) {
                                regs4[0] = b5.lhs.int();
                                regs4[1] = b5.rhs.int();
                            }
                        },
                        .Call => |cl5| {
                            const pf5 = m.funcById(cl5.func);
                            if (pf5) |p5| {
                                if ((isPrintln(p5) or scalarIntrinsic(p5) == .print) and cl5.n_args == 1) {
                                    regs4[0] = cl5.args.int();
                                }
                            }
                        },
                        else => {},
                    }
                    for (regs4) |maybe_r| {
                        const r5 = maybe_r orelse continue;
                        if (c.types[r5] != .object) continue;
                        const rc5b = c.cls[r5] orelse continue;
                        const ts5 = toStringOf(m, prog, rc5b) orelse continue;
                        var have5 = false;
                        for (used_slots.items) |us5| {
                            if (us5.slot == ts5.id.int()) have5 = true;
                        }
                        if (!have5) try used_slots.append(gpa, .{ .slot = ts5.id.int(), .n_args = 0 });
                    }
                }
                if (c.bare.get(inst)) |res2| {
                    if (res2 == .member) {
                        var have_s = false;
                        for (used_slots.items) |us6| {
                            if (us6.slot == res2.member.slot) have_s = true;
                        }
                        if (!have_s) {
                            const nargs6: u32 = switch (inst.*) {
                                .CallMemberOrGlobal => |cg6| cg6.n_args,
                                else => 0,
                            };
                            try used_slots.append(gpa, .{ .slot = res2.member.slot, .n_args = nargs6 });
                        }
                    }
                }
                if (inst.* != .CallVirtual) continue;
                const cv = inst.CallVirtual;
                if (c.cls[cv.receiver.int()]) |rc| {
                    if (rc == LIST_CLS) continue;
                }
                if (m.funcById(ir.FuncId.from(cv.slot.int()))) |tsd3| {
                    if (isToStringCall(tsd3.name, cv.n_args) and
                        rendersToString(m, prog, c.cls, cv.receiver.int())) continue;
                }
                if (numConvVirtual(m, cv) != null) continue;
                var have3 = false;
                for (used_slots.items) |u| {
                    if (u.slot == cv.slot.int()) have3 = true;
                }
                if (!have3) try used_slots.append(gpa, .{ .slot = cv.slot.int(), .n_args = cv.n_args });
            }
        }
    }

    // `object` declarations the program names. Each has ONE instance, created
    // before the program runs and rooted for its whole life.
    var used_singletons: std.ArrayList(SingletonUse) = .empty;
    defer used_singletons.deinit(gpa);
    for (accepted.items) |*c| {
        for (c.f.blocks) |*blk| {
            for (blk.insts) |*inst| {
                // An enum entry read off the enum's name is an instance built
                // once, exactly like an `object` declaration's.
                if (inst.* == .CallMember) {
                    if (companionReceiver(m, prog, c.types, c.cls, inst.CallMember.receiver.int())) |cc9| {
                        var have_c9 = false;
                        for (used_singletons.items) |u| {
                            if (u.cid == cc9 and u.entry == null) have_c9 = true;
                        }
                        if (!have_c9) try used_singletons.append(gpa, .{ .cid = cc9 });
                    }
                    continue;
                }
                if (inst.* == .GetField) {
                    const gf3 = inst.GetField;
                    // A property the receiver's own class does not carry is its
                    // companion's, and that singleton has to exist.
                    if (staticClassOf(c.types, c.cls, gf3.receiver.int()) == null) {
                        if (gf3.field.int() < m.consts.items.len) {
                            const fnm3 = m.consts.items[gf3.field.int()];
                            if (fnm3 == .String) {
                                if (c.cls[gf3.receiver.int()]) |rc3| {
                                    if (accessOwner(m, prog, rc3, fnm3.String, false)) |cc3| {
                                        var have_c3 = false;
                                        for (used_singletons.items) |u| {
                                            if (u.cid == cc3 and u.entry == null) have_c3 = true;
                                        }
                                        if (!have_c3) try used_singletons.append(gpa, .{ .cid = cc3 });
                                    }
                                }
                            }
                        }
                    }
                    if (staticClassOf(c.types, c.cls, gf3.receiver.int())) |sc2| {
                        const enm2 = m.consts.items[gf3.field.int()];
                        if (enm2 == .String) {
                            if (std.mem.eql(u8, plainFieldName(enm2.String), "entries")) {
                                const ents5 = enumEntries(m, prog, sc2);
                                for (ents5, 0..) |_, ei5| {
                                    var have_e5 = false;
                                    for (used_singletons.items) |u| {
                                        if (u.cid == sc2 and u.entry != null and u.entry.? == ei5) have_e5 = true;
                                    }
                                    if (!have_e5) try used_singletons.append(gpa, .{ .cid = sc2, .entry = @intCast(ei5) });
                                }
                            }
                            if (enumEntryIndex(m, prog, sc2, plainFieldName(enm2.String))) |ei3| {
                                var have_e = false;
                                for (used_singletons.items) |u| {
                                    if (u.cid == sc2 and u.entry != null and u.entry.? == ei3) have_e = true;
                                }
                                if (!have_e) try used_singletons.append(gpa, .{ .cid = sc2, .entry = ei3 });
                            } else if (sc2 < m.classes.items.len) {
                                // A member read off a class name answers from
                                // that class's companion, which is a singleton
                                // the program has to build.
                                if (companionObjectNamed(m, prog, m.classes.items[sc2].fqn)) |cc2| {
                                    var have_c = false;
                                    for (used_singletons.items) |u| {
                                        if (u.cid == cc2 and u.entry == null) have_c = true;
                                    }
                                    if (!have_c) try used_singletons.append(gpa, .{ .cid = cc2 });
                                }
                            }
                        }
                    }
                    continue;
                }
                if (inst.* != .LoadGlobal) continue;
                const cid2 = inst.LoadGlobal.name;
                if (cid2.int() >= m.consts.items.len) continue;
                const gn2 = m.consts.items[cid2.int()];
                if (gn2 != .String) continue;
                const oc = objectClassNamed(m, prog, gn2.String) orelse
                    companionObjectNamed(m, prog, gn2.String) orelse continue;
                var have2 = false;
                for (used_singletons.items) |u| {
                    if (u.cid == oc and u.entry == null) have2 = true;
                }
                if (!have2) try used_singletons.append(gpa, .{ .cid = oc });
            }
        }
    }

    // Properties read through a type that declares them without storage. One
    // dispatcher per (receiver type, name): which getter runs is the
    // receiver's class, exactly as for a method.
    var used_props: std.ArrayList(PropUse) = .empty;
    defer used_props.deinit(gpa);
    for (accepted.items) |*c| {
        for (c.f.blocks) |*blk| {
            for (blk.insts) |*inst| {
                if (inst.* != .GetField) continue;
                const gf4 = inst.GetField;
                const rc4 = c.cls[gf4.receiver.int()] orelse continue;
                if (isBuiltinCls(rc4)) continue;
                if (staticClassOf(c.types, c.cls, gf4.receiver.int()) != null) continue;
                const nm4 = m.consts.items[gf4.field.int()];
                if (nm4 != .String) continue;
                if (accessPlan(m, prog, rc4, nm4.String, false) != .virtual) continue;
                const pname = plainFieldName(nm4.String);
                const vp4 = virtualProp(m, prog, rc4, pname) orelse continue;
                var have_p = false;
                for (used_props.items) |u| {
                    if (u.cid == rc4 and std.mem.eql(u8, u.name, pname)) have_p = true;
                }
                if (!have_p) try used_props.append(gpa, .{ .name = pname, .cid = rc4, .ret = vp4.ret });
            }
        }
    }

    // Lambdas whose value has to exist. Each becomes a class the emitter
    // synthesizes for that body, one field per capture: the collector traces
    // it like any instance, and a call through the value finds the body again
    // by its class handle.
    var used_lambdas: std.ArrayList(LambdaUse) = .empty;
    defer used_lambdas.deinit(gpa);
    for (accepted.items) |*c| {
        for (c.f.blocks) |*blk| {
            for (blk.insts) |*inst| {
                if (inst.* == .LoadGlobal) {
                    const lr9 = inst.LoadGlobal.dst.int();
                    if (c.lam[lr9]) |li9| {
                        var have_r = false;
                        for (used_lambdas.items) |u| {
                            if (u.body == li9.body) have_r = true;
                        }
                        if (!have_r) {
                            try used_lambdas.append(gpa, .{
                                .body = li9.body,
                                .n_caps = 0,
                                .arity = funcClsArity(c.cls[lr9].?).?,
                                .ret = c.elem[lr9],
                            });
                        }
                    }
                    continue;
                }
                if (inst.* != .AstLambda) continue;
                const al2 = inst.AstLambda;
                if (c.types[al2.dst.int()] != .object) continue;
                const bfid = al2.body_func orelse continue;
                var have_l = false;
                for (used_lambdas.items) |u| {
                    if (u.body == bfid) have_l = true;
                }
                if (have_l) continue;
                try used_lambdas.append(gpa, .{
                    .body = bfid,
                    .n_caps = @intCast(al2.captures.len),
                    .arity = funcClsArity(c.cls[al2.dst.int()].?).?,
                    .ret = c.elem[al2.dst.int()],
                });
            }
        }
    }

    // Classes the program constructs or reads through. Emitted as descriptors
    // and registered before main: a compiled program carries its own layout
    // because there is no module to ask.
    var used_classes: std.ArrayList(u32) = .empty;
    defer used_classes.deinit(gpa);
    for (used_singletons.items) |su2| {
        var seen_o = false;
        for (used_classes.items) |u| {
            if (u == su2.cid) seen_o = true;
        }
        if (!seen_o) try used_classes.append(gpa, su2.cid);
    }
    for (accepted.items) |*c| {
        for (c.cls) |maybe| {
            const cid = maybe orelse continue;
            if (isBuiltinCls(cid)) continue;
            // A class the program never laid out has no descriptor to
            // register: an interface, or a library type a value merely passes
            // through. Nothing constructs one, and every read that would need
            // its fields is refused before it reaches here.
            if (prog.of(cid) == null) continue;
            var seen_cls = false;
            for (used_classes.items) |u| {
                if (u == cid) seen_cls = true;
            }
            if (!seen_cls) try used_classes.append(gpa, cid);
        }
    }
    // Classes the program actually constructs, and every superclass in their
    // chains: each gets an initializer, and a subclass's calls its parent's.
    var ctor_classes: std.ArrayList(u32) = .empty;
    defer ctor_classes.deinit(gpa);
    {
        var want: std.ArrayList(u32) = .empty;
        defer want.deinit(gpa);
        for (used_singletons.items) |su3| try want.append(gpa, su3.cid);
        for (accepted.items) |*cc| {
            for (cc.f.blocks) |*blk| {
                for (blk.insts) |*inst| {
                    if (inst.* != .NewInstance) continue;
                    const nc = inst.NewInstance.class.int();
                    if (isThrowableClass(m, nc)) continue;
                    // An array is a runtime value, not an instance the emitter
                    // lays out or initializes.
                    if (nc < m.classes.items.len and
                        (isArrayTypeName(m.classes.items[nc].name) or unsignedTypeOf(m.classes.items[nc].name) != null)) continue;
                    try want.append(gpa, nc);
                }
            }
        }
        var wi: usize = 0;
        while (wi < want.items.len) : (wi += 1) {
            const cid = want.items[wi];
            if (prog.of(cid) == null) continue;
            var have = false;
            for (ctor_classes.items) |u| {
                if (u == cid) have = true;
            }
            if (have) continue;
            try ctor_classes.append(gpa, cid);
            if (prog.parentOf(cid)) |pp| try want.append(gpa, pp.cid);
        }
    }

    // A string is a reference too: a program that only concatenates still needs
    // the runtime for its collector and renderer.
    var uses_objects_hint = false;
    var uses_objects = used_classes.items.len != 0;
    for (accepted.items) |*c| {
        for (c.types) |t| {
            // A `Char` prints as a character, a `Short`/`Byte` as itself, and
            // an unsigned value as unsigned, so a program holding one needs the
            // runtime's renderer even if it never touches the heap.
            switch (t) {
                .object, .char, .short, .byte, .u32, .u64, .u16, .u8 => uses_objects = true,
                else => {},
            }
        }
    }

    // Only the globals the program actually touches get storage.
    var used_globals: std.ArrayList(Global) = .empty;
    defer used_globals.deinit(gpa);
    for (accepted.items) |*c| {
        for (c.f.blocks) |*blk| {
            for (blk.insts) |*inst| {
                const nm: ?ir.ConstId = switch (inst.*) {
                    .LoadGlobal => |lg| lg.name,
                    .StoreGlobal => |sg| sg.name,
                    // A bare name that resolved to no implicit receiver is the
                    // top-level property it falls back to.
                    .LoadFromThisOrGlobal => |lt2| if (c.bare.get(inst)) |r2|
                        (if (r2 == .global) lt2.name else null)
                    else
                        null,
                    .StoreToThisOrGlobal => |st2| if (c.bare.get(inst)) |r3|
                        (if (r3 == .global) st2.name else null)
                    else
                        null,
                    else => null,
                };
                const cid = nm orelse continue;
                const gn = m.consts.items[cid.int()];
                if (gn != .String) continue;
                const gi = globalIndex(globals, gn.String) orelse continue;
                var have = false;
                for (used_globals.items) |u| {
                    if (std.mem.eql(u8, u.name, globals[gi].name)) have = true;
                }
                if (!have) try used_globals.append(gpa, globals[gi]);
            }
        }
    }
    if (used_globals.items.len != 0 or used_singletons.items.len != 0 or used_slots.items.len != 0 or uses_try) uses_objects_hint = true;

    var needs_div = false;
    var needs_cast = false;
    for (accepted.items) |*c| {
        for (c.f.blocks) |*blk| {
            for (blk.insts) |*inst| {
                switch (inst.*) {
                    .Cast => |ca| {
                        if (!ca.safe) needs_cast = true;
                        uses_objects_hint = true;
                    },
                    .InstanceOf => uses_objects_hint = true,
                    .BinOp => |b| {
                        if ((b.op == .Div or b.op == .Mod) and !c.types[b.dst.int()].isFloat()) needs_div = true;
                    },
                    // Printing goes through the runtime's renderer, so a
                    // program that prints anything links it.
                    .Call => |call| {
                        const callee = m.funcById(call.func) orelse continue;
                        if (isPrintln(callee) or scalarIntrinsic(callee) == .print) uses_objects_hint = true;
                    },
                    else => {},
                }
            }
        }
    }

    try w.print(
        \\/* Generated by `klio transpile --native {s}`. Do not edit.
        \\ * The program, not a launcher for it: no image is loaded and no
        \\ * interpreter runs. Build: zig cc -O2 <this file> -o prog */
        \\#include <stdio.h>
        \\#include <stdint.h>
        \\#include <stdlib.h>
        \\#include <math.h>
        \\#include <inttypes.h>
        \\#include <setjmp.h>
        \\
    , .{src_path});
    // Every hint is in: a program that prints, throws, holds a global or
    // dispatches needs the runtime, and the header has to say so before the
    // first declaration that uses it.
    if (uses_objects_hint) uses_objects = true;
    if (uses_objects) {
        try w.writeAll(
            \\#include <klio_rt.h>
            \\
            \\
        );
        for (used_classes.items) |cid| try w.print("static uint32_t KCLS_{d};\n", .{cid});
        for (used_lambdas.items) |lu| try w.print("static uint32_t KLAM_{d};\n", .{lu.body.int()});
        // The starter a lambda that suspends is registered under, declared
        // before the registration that names it.
        for (used_lambdas.items) |lu| {
            for (accepted.items) |*cc| {
                if (cc.f.id != lu.body or !cc.suspends) continue;
                try w.print("static klio_value kcs_{d}(klio_value self);\n", .{lu.body.int()});
            }
        }
        try w.writeAll("\nstatic void klio_register_classes(void) {\n");
        for (used_classes.items) |cid| {
            const cdef = &m.classes.items[cid];
            const fields = prog.of(cid).?;
            try w.print("  {{ static const char *const fn[] = {{", .{});
            for (fields, 0..) |fld, i| {
                if (i != 0) try w.writeAll(", ");
                try w.writeByte('"');
                try w.writeAll(fld.name);
                try w.writeByte('"');
            }
            if (fields.len == 0) try w.writeAll("0");
            // The primary constructor's properties are the fields this class
            // contributes from its own arguments: the parent's come first and
            // belong to the parent.
            var plo: u32 = 0;
            var phi: u32 = 0;
            for (fields, 0..) |fld2, fi2| {
                if (fld2.from_parent or fld2.arg == null) continue;
                if (phi == 0) plo = @intCast(fi2);
                phi = @intCast(fi2 + 1);
            }
            var flags: u32 = 0;
            if (layoutFor(prog.layouts, cdef)) |l2| {
                if (l2.is_data) flags |= 1;
            }
            if (cdef.is_enum) flags |= 2;
            if (cdef.is_object) flags |= 4;
            try w.writeAll("};\n    static const unsigned char fz[] = {");
            for (fields, 0..) |fld3, fz_i| {
                if (fz_i != 0) try w.writeAll(", ");
                try w.print("{d}", .{zeroKindOf(fld3.ty)});
            }
            if (fields.len == 0) try w.writeAll("0");
            try w.writeAll("};\n");
            try w.print("    KCLS_{d} = klio_nat_class(\"{s}\", {d}, fn, {d}, {d}, {d}, fz); }}\n", .{
                cid, cdef.name, fields.len, plo, phi, flags,
            });
        }
        for (used_lambdas.items) |lu| {
            try w.print("  {{ static const char *const fn[] = {{", .{});
            var ci7: u32 = 0;
            while (ci7 < lu.n_caps) : (ci7 += 1) {
                if (ci7 != 0) try w.writeAll(", ");
                try w.print("\"k{d}\"", .{ci7});
            }
            if (lu.n_caps == 0) try w.writeAll("0");
            try w.print("}}; KLAM_{d} = klio_nat_class(\"Function{d}\", {d}, fn, 0, 0, 0, 0); }}\n", .{ lu.body.int(), lu.arity, lu.n_caps });
            for (accepted.items) |*cc| {
                if (cc.f.id != lu.body) continue;
                if (!cc.suspends) continue;
                try w.print("  klio_nat_coro_starter(KLAM_{d}, kcs_{d});\n", .{ lu.body.int(), lu.body.int() });
            }
        }
        try w.writeAll("}\n\n");
    }
    if (uses_try) try w.writeAll(
        \\/* A try region. The handler stack and the in-flight value live here rather
        \\ * than in the runtime: `setjmp` has to be called in the frame that catches,
        \\ * so it cannot hide behind a function. Single-threaded, like the programs
        \\ * this backend accepts so far. */
        \\typedef struct klio_try { struct klio_try *prev; jmp_buf jb; } klio_try;
        \\static klio_try *klio_try_top = 0;
        \\static klio_value klio_in_flight;
        \\static klio_nat_frame klio_in_flight_frame;
        \\static void klio_try_arm(klio_try *t) { t->prev = klio_try_top; klio_try_top = t; }
        \\static void klio_try_disarm(void) { if (klio_try_top) klio_try_top = klio_try_top->prev; }
        \\KLIO_NORETURN static void klio_do_throw(klio_value e) {
        \\  if (klio_try_top) { klio_in_flight = e; longjmp(klio_try_top->jb, 1); }
        \\  klio_nat_throw(e);
        \\}
        \\
        \\
    );
    if (needs_cast) {
        // A failed `as` is a ClassCastException, a real throwable a handler in
        // the same program can catch.
        const cce = prog.throws.find("ClassCastException");
        try w.print(
            \\KLIO_NORETURN static void klio_cast_fail(const char *ty, size_t n) {{
            \\  {s}(klio_nat_exception("kotlin.ClassCastException",
            \\      klio_nat_string(ty, n), {d}));
            \\}}
            \\
            \\
        , .{ if (uses_try) "klio_do_throw" else "klio_nat_throw", if (cce) |t| t.lo else 0 });
    }
    if (needs_div) {
        // Kotlin THROWS on integer division by zero; C leaves it undefined.
        // It is a real throwable, so a `catch` in compiled code sees it and
        // an uncaught one is reported by the runtime, in the one place that
        // knows how a throwable reads.
        const az = prog.throws.find("ArithmeticException");
        try w.print(
            \\KLIO_NORETURN static void klio_arith_zero(void) {{
            \\  {s}(klio_nat_exception("kotlin.ArithmeticException",
            \\      klio_nat_string("/ by zero", 9), {d}));
            \\}}
            \\
            \\
        , .{ if (uses_try) "klio_do_throw" else "klio_nat_throw", if (az) |t| t.lo else 0 });
    }


    if (used_singletons.items.len != 0) {
        try w.print("\n/* `object` declarations: one instance each, built before the program\n" ++
            " * runs and rooted for its whole life. */\n", .{});
        try w.print("static klio_value KO[{d}];\n", .{used_singletons.items.len});
        try w.print("static klio_nat_frame KOF;\n", .{});
    }
    {
        var n_ls: usize = 0;
        for (used_lambdas.items) |lu| {
            if (lu.n_caps == 0) n_ls += 1;
        }
        if (n_ls != 0) {
            try w.print("\n/* A lambda literal that captures nothing is a SINGLETON in Kotlin:\n" ++
                " * every evaluation of the same literal yields the same instance, so\n" ++
                " * `===` holds across evaluations. One instance each, rooted for the\n" ++
                " * life of the program. */\n", .{});
            try w.print("static klio_value KL[{d}];\n", .{n_ls});
            try w.print("static klio_nat_frame KLF;\n", .{});
        }
    }
    if (used_globals.items.len != 0) {
        try w.print("\n/* Top-level properties. Published to the collector for the life of the\n" ++
            " * program: a global is a root, not a frame slot. */\n", .{});
        try w.print("static klio_value KG[{d}];\n", .{used_globals.items.len});
        try w.print("static klio_nat_frame KGF;\n", .{});
    }

    // Prototypes first: the call graph has cycles (recursion, mutual calls),
    // and a dispatcher is defined after the bodies it selects between.
    for (accepted.items) |*c| {
        try writeProto(w, c);
        try w.writeAll(";\n");
        // The continuation a suspend body is re-entered through.
        if (c.suspends) {
            try w.print("static klio_value kco_{d}(void *fp, klio_value resumed);\n", .{c.f.id.int()});
            try w.print("static void *kcf_{d}(", .{c.f.id.int()});
            if (c.params.len == 0 and c.caps.len == 0) {
                try w.writeAll("void");
            } else {
                for (c.caps, 0..) |ct, i| {
                    if (i != 0) try w.writeAll(", ");
                    try w.print("{s}", .{ct.ty.cName()});
                }
                for (c.params, 0..) |p, i| {
                    if (i != 0 or c.caps.len != 0) try w.writeAll(", ");
                    try w.print("{s}", .{(tyOf(p.ty) orelse Ty.object).cName()});
                }
            }
            try w.writeAll(");\n");
        }
    }
    for (used_slots.items) |su| {
        const root = m.funcById(ir.FuncId.from(su.slot)).?;
        const rt6 = funcRetTy2(m, root) orelse .unit;
        try w.print("static {s} kvirt_{d}(klio_value recv", .{ rt6.cName(), su.slot });
        var ai3: u32 = 0;
        while (ai3 < su.n_args) : (ai3 += 1) {
            const pt3: Ty = if (ai3 + 1 < root.params.len) (tyOf(root.params[ai3 + 1].ty) orelse .object) else .object;
            try w.print(", {s} a{d}", .{ pt3.cName(), ai3 });
        }
        try w.writeAll(");\n");
    }
    for (ctor_classes.items) |cid| {
        try writeCtorProto(w, m, cid);
        try w.writeAll(";\n");
    }
    for (used_props.items) |pu| {
        var mb: [96]u8 = undefined;
        try w.print("static {s} kprop_{d}_{s}(klio_value recv);\n", .{
            pu.ret.cName(), pu.cid, mangleName(pu.name, &mb),
        });
    }

    // One adapter per materialised lambda, and one dispatcher per arity called
    // through a value. A function value's arguments and result pass boxed,
    // because which body runs is a run-time answer and two bodies of the same
    // arity need not agree on machine types.
    for (used_lambdas.items) |lu| {
        try w.print("static klio_value klam_{d}(klio_value self", .{lu.body.int()});
        var ai7: u32 = 0;
        while (ai7 < lu.arity) : (ai7 += 1) try w.print(", klio_value a{d}", .{ai7});
        try w.writeAll(");\n");
    }
    {
        var seen_ar: [FUNC_MAX_ARITY + 1]bool = @splat(false);
        for (used_lambdas.items) |lu| {
            if (seen_ar[lu.arity]) continue;
            seen_ar[lu.arity] = true;
            try w.print("static klio_value klam_call_{d}(klio_value f", .{lu.arity});
            var ai8: u32 = 0;
            while (ai8 < lu.arity) : (ai8 += 1) try w.print(", klio_value a{d}", .{ai8});
            try w.writeAll(");\n");
        }
    }
    try w.writeAll("\n");
    for (accepted.items) |*c| try writeBody(gpa, w, m, prog, c, uses_objects, used_globals.items, used_singletons.items, used_slots.items, uses_try, accepted.items, used_classes.items, used_lambdas.items);

    for (used_slots.items) |su| {
        const root = m.funcById(ir.FuncId.from(su.slot)).?;
        const rt5 = funcRetTy2(m, root) orelse .unit;
        try w.print("\n/* Virtual dispatch for `{s}`. Which body runs is the receiver's\n" ++
            " * class, compared here against the handles registered at startup —\n" ++
            " * they are runtime values, so this is a chain and not a switch. */\n", .{root.name});
        try w.print("static {s} kvirt_{d}(klio_value recv", .{ rt5.cName(), su.slot });
        var ai: u32 = 0;
        while (ai < su.n_args) : (ai += 1) {
            const pt2: Ty = if (ai + 1 < root.params.len) (tyOf(root.params[ai + 1].ty) orelse .object) else .object;
            try w.print(", {s} a{d}", .{ pt2.cName(), ai });
        }
        // A slot no constructed class answers still needs a body: the call
        // site is reachable, and reaching it means no receiver implements the
        // method.
        try w.writeAll(") {\n  uint32_t k = klio_nat_class_of(recv);\n  (void)k;\n");
        for (used_classes.items) |cid| {
            const impl = slotImpl(m, prog, cid, ir.MethodSlotId.from(su.slot)) orelse continue;
            var in_set = false;
            for (accepted.items) |*cc| {
                if (cc.f == impl) in_set = true;
            }
            if (!in_set) continue;
            // The implementation may declare more parameters than the call
            // site supplies: an override can carry defaults the site omits.
            // Those run their thunks here, handed what came before them.
            try w.print("  if (k == KCLS_{d}) {{\n", .{cid});
            var dk9: u32 = su.n_args + 1;
            while (dk9 < impl.params.len) : (dk9 += 1) {
                // The default may be declared where the method is DECLARED
                // rather than where its body is: an interface can carry the
                // default for a method a superclass implements.
                const dfid9 = prog.defaultThunk(impl.id, dk9) orelse
                    prog.defaultThunk(root.id, dk9) orelse break;
                const dfn9 = m.funcById(dfid9) orelse break;
                const dt9 = acceptedRet(accepted.items, dfn9) orelse funcRetTy2(m, dfn9) orelse .unit;
                var dsym9: std.Io.Writer.Allocating = .init(gpa);
                defer dsym9.deinit();
                try writeSymbol(&dsym9.writer, dfn9);
                try w.print("    {s} vd{d} = {s}(recv", .{ dt9.cName(), dk9, dsym9.written() });
                var pk9: u32 = 1;
                while (pk9 < dk9) : (pk9 += 1) {
                    if (pk9 <= su.n_args) {
                        try w.print(", a{d}", .{pk9 - 1});
                    } else {
                        try w.print(", vd{d}", .{pk9});
                    }
                }
                try w.writeAll(");\n");
            }
            if (dk9 != impl.params.len) {
                // A parameter with no default and no argument: nothing can
                // fill it, so this receiver cannot answer at all. Leaving the
                // arm empty would let the call fall through to the
                // no-implementation tail at run time, which is a wrong answer
                // rather than a refusal.
                if (traceOn()) std.debug.print("[cgen] refuse {s}: dispatcher arm cannot fill a parameter of `{s}`\n", .{ root.name, impl.fqn });
                return false;
            }
            try w.writeAll("    return ");
            try writeSymbol(w, impl);
            try w.writeAll("(recv");
            var aj: u32 = 1;
            while (aj < impl.params.len) : (aj += 1) {
                if (aj <= su.n_args) {
                    try w.print(", a{d}", .{aj - 1});
                } else {
                    try w.print(", vd{d}", .{aj});
                }
            }
            try w.writeAll(");\n  }\n");
        }
        try w.print("  klio_nat_no_method(\"{s}\");\n", .{root.name});
        // `klio_nat_no_method` does not return, but C does not know that from
        // the declaration alone, so give the function a value to fall off with.
        if (rt5 == .object) {
            try w.writeAll("  return klio_nat_box_unit();\n");
        } else {
            try w.writeAll("  return 0;\n");
        }
        try w.writeAll("}\n");
    }
    if (ctor_classes.items.len != 0) try w.writeAll("\n");
    for (ctor_classes.items) |cid| try writeCtorBody(gpa, w, m, prog, cid);
    if (ctor_classes.items.len != 0) try w.writeAll("\n");
    // A lambda that suspends and can be handed to `launch` needs a starter:
    // the driver is given the closure VALUE and has to find the code.
    for (used_lambdas.items) |lu| {
        const sc9 = blk10: {
            for (accepted.items) |*cc| {
                if (cc.f.id == lu.body) break :blk10 cc;
            }
            return false;
        };
        if (!sc9.suspends) continue;
        try w.print("static klio_value kcs_{d}(klio_value self) {{\n  return kco_{d}(kcf_{d}(", .{
            lu.body.int(), lu.body.int(), lu.body.int(),
        });
        for (sc9.caps, 0..) |ct9, ci9| {
            if (ci9 != 0) try w.writeAll(", ");
            var gb10: [96]u8 = undefined;
            const g10 = try std.fmt.bufPrint(&gb10, "klio_nat_get(self, {d})", .{ci9});
            var ob12: [200]u8 = undefined;
            try w.print("{s}", .{unboxExpr(ct9.ty, g10, &ob12)});
        }
        for (sc9.params, 0..) |p10, pi10| {
            if (pi10 != 0 or sc9.caps.len != 0) try w.writeAll(", ");
            const pt10: Ty = tyOf(p10.ty) orelse .object;
            var zb10: [64]u8 = undefined;
            try w.print("{s}", .{if (pt10 == .object) "klio_nat_box_unit()" else boxExpr(.unit, "0", &zb10)});
        }
        try w.writeAll("), klio_nat_box_unit());\n}\n");
    }
    for (used_lambdas.items) |lu| {
        const bc2 = blk9: {
            for (accepted.items) |*cc| {
                if (cc.f.id == lu.body) break :blk9 cc;
            }
            return false;
        };
        try w.print("static klio_value klam_{d}(klio_value self", .{lu.body.int()});
        var ai9: u32 = 0;
        while (ai9 < lu.arity) : (ai9 += 1) try w.print(", klio_value a{d}", .{ai9});
        try w.writeAll(") {\n");
        if (lu.n_caps == 0) try w.writeAll("  (void)self;\n");
        // The lowering always gives a lambda an `it` slot, so a body can
        // declare fewer parameters than its type takes.
        var av9: u32 = 0;
        while (av9 < lu.arity) : (av9 += 1) try w.print("  (void)a{d};\n", .{av9});
        var call9: std.Io.Writer.Allocating = .init(gpa);
        defer call9.deinit();
        try writeSymbol(&call9.writer, bc2.f);
        try call9.writer.writeByte('(');
        for (bc2.caps, 0..) |ct9, ci9| {
            if (ci9 != 0) try call9.writer.writeAll(", ");
            var gb9: [96]u8 = undefined;
            const g9 = try std.fmt.bufPrint(&gb9, "klio_nat_get(self, {d})", .{ci9});
            var ob10: [200]u8 = undefined;
            try call9.writer.print("{s}", .{unboxExpr(ct9.ty, g9, &ob10)});
        }
        for (bc2.params, 0..) |p9, pi9| {
            if (pi9 != 0 or bc2.caps.len != 0) try call9.writer.writeAll(", ");
            const pt9: Ty = tyOf(p9.ty) orelse .object;
            var ab10: [16]u8 = undefined;
            // The lowering always gives a lambda an `it` slot, so a body may
            // declare a parameter the call never supplies; it gets the type's
            // zero, which is unreachable in a lambda that declares none.
            const src10 = if (pi9 < lu.arity)
                try std.fmt.bufPrint(&ab10, "a{d}", .{pi9})
            else
                "klio_nat_box_unit()";
            var ob11: [200]u8 = undefined;
            try call9.writer.print("{s}", .{unboxExpr(pt9, src10, &ob11)});
        }
        try call9.writer.writeByte(')');
        var bb15: [400]u8 = undefined;
        try w.print("  return {s};\n}}\n", .{boxExpr(bc2.ret, call9.written(), &bb15)});
    }
    {
        var seen_ar2: [FUNC_MAX_ARITY + 1]bool = @splat(false);
        for (used_lambdas.items) |lu| {
            if (seen_ar2[lu.arity]) continue;
            seen_ar2[lu.arity] = true;
            try w.print("static klio_value klam_call_{d}(klio_value f", .{lu.arity});
            var ai10: u32 = 0;
            while (ai10 < lu.arity) : (ai10 += 1) try w.print(", klio_value a{d}", .{ai10});
            try w.writeAll(") {\n  uint32_t k = klio_nat_class_of(f);\n  (void)k;\n");
            for (used_lambdas.items) |lu2| {
                if (lu2.arity != lu.arity) continue;
                try w.print("  if (k == KLAM_{d}) return klam_{d}(f", .{ lu2.body.int(), lu2.body.int() });
                var aj10: u32 = 0;
                while (aj10 < lu.arity) : (aj10 += 1) try w.print(", a{d}", .{aj10});
                try w.writeAll(");\n");
            }
            try w.writeAll("  klio_nat_no_method(\"invoke\");\n  return klio_nat_box_unit();\n}\n");
            // The same dispatcher in the uniform shape a stdlib entry calls
            // back through: `forEach` and its kind hand the runtime a closure
            // VALUE and an argument array.
            try w.print("static klio_value klam_inv_{d}(klio_value f, const klio_value *a) {{\n  (void)a;\n  return klam_call_{d}(f", .{ lu.arity, lu.arity });
            var ai11: u32 = 0;
            while (ai11 < lu.arity) : (ai11 += 1) try w.print(", a[{d}]", .{ai11});
            try w.writeAll(");\n}\n");
        }
    }
    for (used_props.items) |pu| {
        var mb2: [96]u8 = undefined;
        try w.print("static {s} kprop_{d}_{s}(klio_value recv) {{\n  uint32_t k = klio_nat_class_of(recv);\n  (void)k;\n", .{
            pu.ret.cName(), pu.cid, mangleName(pu.name, &mb2),
        });
        for (used_classes.items) |cid2| {
            if (!typeReaches(m, cid2, pu.cid)) continue;
            if (prog.accessor(m, cid2, pu.name, .get)) |g2| {
                const gfn2 = m.funcById(g2) orelse continue;
                var in_set2 = false;
                for (accepted.items) |*cc2| {
                    if (cc2.f == gfn2) in_set2 = true;
                }
                if (!in_set2) continue;
                try w.print("  if (k == KCLS_{d}) return ", .{cid2});
                try writeSymbol(w, gfn2);
                try w.writeAll("(recv);\n");
                continue;
            }
            const fi6 = fieldIndex(prog, cid2, pu.name) orelse continue;
            var gb6: [96]u8 = undefined;
            const g6 = try std.fmt.bufPrint(&gb6, "klio_nat_get(recv, {d})", .{fi6});
            var ob6: [160]u8 = undefined;
            try w.print("  if (k == KCLS_{d}) return {s};\n", .{ cid2, unboxExpr(pu.ret, g6, &ob6) });
        }
        try w.print("  klio_nat_no_method(\"{s}\");\n", .{pu.name});
        if (pu.ret == .object) {
            try w.writeAll("  return klio_nat_box_unit();\n}\n");
        } else {
            try w.writeAll("  return 0;\n}\n");
        }
    }
    if (used_lambdas.items.len != 0) try w.writeAll("\n");
    if (used_singletons.items.len != 0) {
        try w.writeAll("static void klio_init_singletons(void) {\n");
        try w.print("  for (unsigned i = 0; i < {d}; i++) KO[i] = klio_nat_box_unit();\n", .{used_singletons.items.len});
        try w.print("  KOF.n = {d}; KOF.slots = KO; klio_nat_enter(&KOF);\n", .{used_singletons.items.len});
        for (used_singletons.items, 0..) |su4, oi| {
            try w.print("  KO[{d}] = klio_nat_alloc_instance(KCLS_{d});\n", .{ oi, su4.cid });
            const ei = su4.entry orelse {
                try w.print("  kinit_{d}(KO[{d}]);\n", .{ su4.cid, oi });
                continue;
            };
            // An enum entry carries its own name and position, then runs the
            // enum's constructor with the arguments its declaration writes.
            const ents2 = enumEntries(m, prog, su4.cid);
            try w.print("  klio_nat_set(KO[{d}], 0, klio_nat_string(\"{s}\", {d}));\n", .{ oi, ents2[ei].name, ents2[ei].name.len });
            try w.print("  klio_nat_set(KO[{d}], 1, klio_nat_box_int({d}));\n", .{ oi, ei });
            const edef = &m.classes.items[su4.cid];
            try w.print("  kinit_{d}(KO[{d}]", .{ su4.cid, oi });
            for (edef.primary_params, 0..) |_, pi| {
                try w.writeAll(", ");
                const want = ctorParamTy(edef, pi);
                if (pi >= ents2[ei].args.len) {
                    try w.print("{s}", .{if (want == .object) "klio_nat_null()" else "0"});
                    continue;
                }
                const afn = m.funcById(ents2[ei].args[pi]).?;
                var sym4: std.Io.Writer.Allocating = .init(gpa);
                defer sym4.deinit();
                try writeSymbol(&sym4.writer, afn);
                var cb5: [220]u8 = undefined;
                const call5 = if (afn.has_receiver_param)
                    try std.fmt.bufPrint(&cb5, "{s}(KO[{d}])", .{ sym4.written(), oi })
                else
                    try std.fmt.bufPrint(&cb5, "{s}()", .{sym4.written()});
                const have5 = funcRetTy2(m, afn) orelse want;
                var bx5: [300]u8 = undefined;
                if (want == .object and have5 != .object) {
                    try w.print("{s}", .{boxExpr(have5, call5, &bx5)});
                } else {
                    try w.print("{s}", .{call5});
                }
            }
            try w.writeAll(");\n");
        }
        try w.writeAll("}\n\n");
    }
    if (used_globals.items.len != 0) {
        try w.writeAll("static void klio_init_globals(void) {\n");
        try w.print("  for (unsigned i = 0; i < {d}; i++) KG[i] = klio_nat_box_unit();\n", .{used_globals.items.len});
        try w.print("  KGF.n = {d}; KGF.slots = KG; klio_nat_enter(&KGF);\n", .{used_globals.items.len});
        for (used_globals.items, 0..) |g, i| {
            const gf = m.funcById(g.func).?;
            var acc_i: ?usize = null;
            for (accepted.items, 0..) |*cc, ci| {
                if (cc.f == gf) acc_i = ci;
            }
            const gt = accepted.items[acc_i.?].ret;
            var bb: [96]u8 = undefined;
            var call_buf: [160]u8 = undefined;
            var sym: std.Io.Writer.Allocating = .init(gpa);
            defer sym.deinit();
            try writeSymbol(&sym.writer, gf);
            const call = try std.fmt.bufPrint(&call_buf, "{s}()", .{sym.written()});
            try w.print("  KG[{d}] = {s};\n", .{ i, boxExpr(gt, call, &bb) });
        }
        try w.writeAll("}\n\n");
    }

    try w.writeAll("int main(void) {\n");
    if (uses_objects) try w.writeAll("  klio_nat_init(0);\n  klio_register_classes();\n");
    if (uses_try) try w.writeAll(
        "  klio_in_flight = klio_nat_box_unit();\n" ++
        "  klio_in_flight_frame.n = 1; klio_in_flight_frame.slots = &klio_in_flight;\n" ++
        "  klio_nat_enter(&klio_in_flight_frame);\n",
    );
    {
        // Every arity a closure can be called through, registered so a stdlib
        // entry that takes a lambda can reach compiled code.
        var seen_ar3: [FUNC_MAX_ARITY + 1]bool = @splat(false);
        for (used_lambdas.items) |lu| {
            if (seen_ar3[lu.arity]) continue;
            seen_ar3[lu.arity] = true;
            try w.print("  klio_nat_lambda_invoker({d}, klam_inv_{d});\n", .{ lu.arity, lu.arity });
        }
    }
    {
        var n_ls3: usize = 0;
        for (used_lambdas.items) |lu| {
            if (lu.n_caps == 0) n_ls3 += 1;
        }
        if (n_ls3 != 0) {
            // A lambda literal that captures nothing has ONE instance for the
            // life of the program, built here and rooted.
            try w.print("  for (unsigned i = 0; i < {d}; i++) KL[i] = klio_nat_box_unit();\n", .{n_ls3});
            try w.print("  KLF.n = {d}; KLF.slots = KL; klio_nat_enter(&KLF);\n", .{n_ls3});
            var li3: usize = 0;
            for (used_lambdas.items) |lu| {
                if (lu.n_caps != 0) continue;
                try w.print("  KL[{d}] = klio_nat_alloc_instance(KLAM_{d});\n", .{ li3, lu.body.int() });
                li3 += 1;
            }
        }
    }
    if (used_singletons.items.len != 0) try w.writeAll("  klio_init_singletons();\n");
    if (used_globals.items.len != 0) {
        // Top-level properties run their initializers in declaration order,
        // which is the order the interpreter runs them in, and BEFORE the
        // permanent phase ends: a global outlives every collection.
        try w.writeAll("  klio_init_globals();\n");
    }
    if (uses_objects) try w.writeAll("  klio_nat_begin();\n");
    try w.writeAll("  ");
    try writeSymbol(w, entry);
    try w.writeAll("();\n  return 0;\n}\n");
    return true;
}
