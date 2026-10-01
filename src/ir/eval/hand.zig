//! Hand-built modules of code lowered from sema, for tests of the resolved
//! instructions without a bridge: functions, classes with slot seeds and
//! dispatch entries, statics with init units, natives and the exceptions
//! the VM throws. Everything allocates from the allocator `init` takes,
//! an arena, and nothing is freed on its own.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");

const Allocator = std.mem.Allocator;
const BlockId = ir.BlockId;
const ClassId = ir.ClassId;
const ConstId = ir.ConstId;
const FuncId = ir.FuncId;
const Inst = ir.Inst;
const MethodSlotId = ir.MethodSlotId;
const NativeId = ir.NativeId;
const Reg = ir.Reg;
const StaticId = ir.StaticId;
const resolved = ir.resolved;

pub const Block = struct {
    insts: []const Inst = &.{},
    term: ir.Terminator,
    catches: []const ir.CatchHandler = &.{},
};

pub const ClassOpts = struct {
    seeds: []const ir.SlotSeed = &.{},
    /// Display names of the slots, the def's `layout_slots`.
    slot_names: []const []const u8 = &.{},
    /// Direct supertypes; the ancestor closure is computed by `finish`.
    supers: []const ClassId = &.{},
};

pub const Hand = struct {
    a: Allocator,
    m: *ir.Module,
    r: *ir.Resolved,
    classes: std.ArrayList(resolved.ClassRt) = .empty,
    supers: std.ArrayList([]const ClassId) = .empty,
    statics: std.ArrayList(resolved.StaticRt) = .empty,
    units: std.ArrayList(resolved.InitUnitRt) = .empty,
    natives: std.ArrayList(resolved.NativeRt) = .empty,
    func_native: std.ArrayList(NativeId) = .empty,

    pub fn init(a: Allocator) Allocator.Error!Hand {
        const m = try a.create(ir.Module);
        m.* = ir.Module.init(a);
        const tables = try a.create(ir.Resolved);
        tables.* = .{};
        m.resolved = tables;
        return .{ .a = a, .m = m, .r = tables };
    }

    /// A function taking `n_params` parameters, with no body until `body`.
    pub fn func(self: *Hand, name: []const u8, n_params: usize) Allocator.Error!FuncId {
        const id = FuncId.from(@intCast(self.m.funcs.items.len));
        const params = try self.a.alloc(ir.Param, n_params);
        for (params) |*p| p.* = .{ .name = "p", .ty = .{ .name = "", .nullable = true, .args = &.{} }, .default = null };
        const f: ir.Func = .{
            .id = id,
            .name = name,
            .fqn = name,
            .params = params,
            .return_ty = .{ .name = "", .nullable = true, .args = &.{} },
            .n_locals = 0,
            .blocks = &.{},
            .entry = BlockId.from(0),
            .is_suspend = false,
        };
        try self.m.funcs.append(self.a, f);
        try self.func_native.append(self.a, .none);
        return id;
    }

    /// Gives `f` its blocks, numbered in order; block 0 is the entry.
    pub fn body(self: *Hand, f: FuncId, blocks: []const Block) Allocator.Error!void {
        const out = try self.a.alloc(ir.Block, blocks.len);
        var max_reg: u32 = 0;
        const Scan = struct {
            max: *u32,
            fn visit(s: @This(), x: Reg, is_def: bool) void {
                _ = is_def;
                if (x.int() + 1 > s.max.*) s.max.* = x.int() + 1;
            }
        };
        const scan: Scan = .{ .max = &max_reg };
        for (blocks, out, 0..) |b, *o, i| {
            const insts = try self.a.dupe(Inst, b.insts);
            for (insts) |*inst| ir.visitInstRegs(inst, scan, Scan.visit);
            ir.visitTerminatorRegs(&b.term, scan, Scan.visit);
            o.* = .{ .id = BlockId.from(@intCast(i)), .insts = insts, .terminator = b.term };
            if (b.catches.len != 0) {
                const hs = try o.handlersMut(self.a);
                hs.catches = try self.a.dupe(ir.CatchHandler, b.catches);
                for (b.catches) |c| scan.visit(c.exception_reg, true);
            }
        }
        const fm = self.m.funcByIdMut(f).?;
        fm.blocks = out;
        fm.n_locals = max_reg;
    }

    pub fn class(self: *Hand, name: []const u8, opts: ClassOpts) Allocator.Error!ClassId {
        const id = ClassId.from(@intCast(self.classes.items.len));
        const def = try runtime.ClassDef.minimal(self.a, name, name, id.int());
        const layout = try self.a.alloc(runtime.LayoutSlot, opts.slot_names.len);
        for (layout, opts.slot_names) |*l, n| l.* = .{ .name = n };
        def.asPtr().layout_slots = layout;
        // The options' slices may be the caller's temporaries (`.supers =
        // &.{k}` over a runtime `k`), which die with its statement: `finish`
        // reads copies.
        try self.classes.append(self.a, .{ .def = def, .seeds = try self.a.dupe(ir.SlotSeed, opts.seeds) });
        const supers = try self.a.dupe(ClassId, opts.supers);
        try self.supers.append(self.a, supers);
        try self.m.classes.append(self.a, .{
            .id = id,
            .name = name,
            .fqn = name,
            .primary_params = &.{},
            .methods = &.{},
            .init_block = null,
            .companion = null,
            .supertypes = supers,
        });
        return id;
    }

    /// Makes `class` an object whose constructor is `ctor`.
    pub fn object(self: *Hand, class_id: ClassId, ctor: FuncId) void {
        self.classes.items[class_id.int()].object_ctor = ctor.int();
    }

    /// `class` answers the slot rooted at `root` with `target`.
    pub fn dispatch(self: *Hand, class_id: ClassId, root: FuncId, target: FuncId) Allocator.Error!void {
        try self.m.method_dispatch.put(ir.Module.methodDispatchKey(class_id, MethodSlotId.fromFunc(root)), target);
    }

    pub fn initUnit(self: *Hand, f: FuncId) Allocator.Error!u32 {
        try self.units.append(self.a, .{ .func = f });
        return @intCast(self.units.items.len - 1);
    }

    pub fn static(self: *Hand, name: []const u8, seed: ir.SlotSeed, unit: ?u32) Allocator.Error!StaticId {
        try self.statics.append(self.a, .{ .unit = unit orelse resolved.NONE, .seed = seed, .name = name });
        return StaticId.from(@intCast(self.statics.items.len - 1));
    }

    pub fn native(self: *Hand, name: []const u8, f: runtime.StdlibFn) Allocator.Error!NativeId {
        try self.natives.append(self.a, .{ .func = f, .name = name });
        return NativeId.from(@intCast(self.natives.items.len - 1));
    }

    /// Binds the bodyless `f` to `n`, so a static call of `f` runs the native.
    pub fn bindNative(self: *Hand, f: FuncId, n: NativeId) void {
        self.func_native.items[f.int()] = n;
    }

    pub fn constant(self: *Hand, c: ir.Const) Allocator.Error!ConstId {
        try self.m.consts.append(self.a, c);
        return ConstId.from(@intCast(self.m.consts.items.len - 1));
    }

    pub fn regs(self: *Hand, rs: []const Reg) Allocator.Error![]const Reg {
        return self.a.dupe(Reg, rs);
    }

    /// Installs the tables and each class's ancestor closure. Every root
    /// is a slot of its own, at its `FuncId`, so each class's vtable holds
    /// what `dispatch` gave it there.
    pub fn finish(self: *Hand) Allocator.Error!void {
        const nf = self.m.funcs.items.len;
        const index = try self.a.alloc(u32, nf);
        for (index, 0..) |*x, i| x.* = @intCast(i);
        const iface = try self.a.alloc(u32, nf);
        @memset(iface, resolved.NONE);
        self.r.slot_index = index;
        self.r.slot_iface = iface;
        for (self.classes.items, 0..) |*rt, c| {
            const vt = try self.a.alloc(resolved.VSlot, nf);
            @memset(vt, .{});
            var it = self.m.method_dispatch.iterator();
            while (it.next()) |e| {
                if (e.key_ptr.* >> 32 != c) continue;
                const slot: u32 = @truncate(e.key_ptr.*);
                if (slot < nf) vt[slot] = .{ .root = slot, .func = e.value_ptr.*.int() };
            }
            rt.vtable = vt;
        }
        self.r.classes = self.classes.items;
        self.r.statics = self.statics.items;
        self.r.init_units = self.units.items;
        self.r.natives = self.natives.items;
        self.r.func_native = self.func_native.items;
        self.m.class_ancestors.clearRetainingCapacity();
        for (0..self.classes.items.len) |i| {
            var acc: std.ArrayList(ClassId) = .empty;
            var stack: std.ArrayList(ClassId) = .empty;
            try stack.append(self.a, ClassId.from(@intCast(i)));
            while (stack.pop()) |c| {
                if (std.mem.indexOfScalar(ClassId, acc.items, c) != null) continue;
                try acc.append(self.a, c);
                try stack.appendSlice(self.a, self.supers.items[c.int()]);
            }
            std.mem.sort(ClassId, acc.items, {}, struct {
                fn lt(_: void, x: ClassId, y: ClassId) bool {
                    return x.int() < y.int();
                }
            }.lt);
            try self.m.class_ancestors.append(self.a, acc.items);
        }
    }

    pub fn funcPtr(self: *Hand, f: FuncId) *const ir.Func {
        return self.m.funcById(f).?;
    }
};

/// A register by number.
pub fn reg(n: u32) Reg {
    return Reg.from(n);
}

/// Memory for one test's run: an arena that owns every value and buffer
/// the run makes, with reference counting off, so the evaluator's
/// per-thread pools never keep a buffer past the arena. `deinit` restores
/// the counting mode it found.
pub const TestMemory = struct {
    arena: std.heap.ArenaAllocator,
    prev_reclaim: bool,

    pub fn init() TestMemory {
        const prev = runtime.reclaimEnabled();
        runtime.setReclaim(false);
        return .{ .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator), .prev_reclaim = prev };
    }

    pub fn allocator(self: *TestMemory) Allocator {
        return self.arena.allocator();
    }

    /// Frees the test's memory, and the streams built for its functions: they are cached by
    /// the functions' addresses, which the next test's functions may take.
    pub fn deinit(self: *TestMemory) void {
        ir.bc.resetCacheForTest();
        self.arena.deinit();
        runtime.setReclaim(self.prev_reclaim);
    }
};

// ---------------------------------------------------------------------------
// Instructions by shape, for writing bodies compactly.

pub fn konst(dst: u32, c: ConstId) Inst {
    return .{ .Const = .{ .dst = reg(dst), .value = c } };
}
pub fn param(dst: u32, idx: u16) Inst {
    return .{ .LoadParam = .{ .dst = reg(dst), .idx = idx } };
}
pub fn capture(dst: u32, idx: u16) Inst {
    return .{ .LoadCapture = .{ .dst = reg(dst), .idx = idx } };
}
pub fn bin(dst: u32, op: ir.BinOp, lhs: u32, rhs: u32) Inst {
    return .{ .BinOp = .{ .dst = reg(dst), .op = op, .lhs = reg(lhs), .rhs = reg(rhs) } };
}
pub fn not(dst: u32, src: u32) Inst {
    return .{ .Not = .{ .dst = reg(dst), .src = reg(src) } };
}
pub fn callStatic(dst: u32, f: FuncId, args: u32, n: u32) Inst {
    return .{ .CallStatic = .{ .dst = reg(dst), .func = f, .args = reg(args), .n_args = n } };
}
pub fn callVirtual(dst: u32, root: FuncId, args: u32, n: u32) Inst {
    return .{ .RCallVirtual = .{ .dst = reg(dst), .slot = MethodSlotId.fromFunc(root), .args = reg(args), .n_args = n } };
}
pub fn callInterface(dst: u32, iface: ClassId, root: FuncId, args: u32, n: u32) Inst {
    return .{ .CallInterface = .{ .dst = reg(dst), .iface = iface, .slot = MethodSlotId.fromFunc(root), .args = reg(args), .n_args = n } };
}
pub fn newInstance(dst: u32, c: ClassId, ctor: FuncId, args: u32, n: u32) Inst {
    return .{ .RNewInstance = .{ .dst = reg(dst), .class = c, .ctor = ctor, .args = reg(args), .n_args = n } };
}
pub fn getField(dst: u32, obj: u32, slot: u32) Inst {
    return .{ .GetFieldSlot = .{ .dst = reg(dst), .obj = reg(obj), .slot = slot } };
}
pub fn setField(obj: u32, slot: u32, value: u32) Inst {
    return .{ .SetFieldSlot = .{ .obj = reg(obj), .slot = slot, .value = reg(value) } };
}
pub fn loadStatic(dst: u32, s: StaticId) Inst {
    return .{ .LoadStatic = .{ .dst = reg(dst), .static = s } };
}
pub fn storeStatic(s: StaticId, value: u32) Inst {
    return .{ .StoreStatic = .{ .static = s, .value = reg(value) } };
}
pub fn loadObject(dst: u32, c: ClassId) Inst {
    return .{ .LoadObject = .{ .dst = reg(dst), .class = c } };
}
pub fn instanceOf(dst: u32, src: u32, c: ClassId, nullable: bool) Inst {
    return .{ .RInstanceOf = .{ .dst = reg(dst), .src = reg(src), .class = c, .nullable = nullable } };
}
pub fn cast(dst: u32, src: u32, c: ClassId, nullable: bool, safe: bool) Inst {
    return .{ .RCast = .{ .dst = reg(dst), .src = reg(src), .class = c, .nullable = nullable, .safe = safe } };
}
pub fn ret(v: u32) ir.Terminator {
    return .{ .Return = reg(v) };
}
pub fn jump(b: u32) ir.Terminator {
    return .{ .Goto = BlockId.from(b) };
}
pub fn catchClass(c: ClassId, handler: u32, exception_reg: u32) ir.CatchHandler {
    return .{ .class = c, .handler = BlockId.from(handler), .exception_reg = reg(exception_reg) };
}

/// `this`, returned: the constructor of a class with nothing to initialize.
pub fn ctorReturningThis(h: *Hand) Allocator.Error!FuncId {
    const f = try h.func("<init>", 1);
    try h.body(f, &.{.{ .insts = &.{param(0, 0)}, .term = ret(0) }});
    return f;
}

/// `(this, message)`: stores the message in slot 0, the shape of the
/// exception constructors the VM runs.
pub fn ctorStoringMessage(h: *Hand) Allocator.Error!FuncId {
    const f = try h.func("<init>(message)", 2);
    try h.body(f, &.{.{ .insts = &.{ param(0, 0), param(1, 1), setField(0, 0, 1) }, .term = ret(0) }});
    return f;
}

/// A throwable class with its message in slot 0.
pub fn throwableClass(h: *Hand, name: []const u8, supers: []const ClassId) Allocator.Error!ClassId {
    return h.class(name, .{ .seeds = &.{.null_ref}, .slot_names = &.{"message"}, .supers = supers });
}

// ---------------------------------------------------------------------------
// Programs: each builds its functions and tables into a fresh `Hand`,
// finishes it and returns `main`. The doc comment says what `main` returns.

/// `twice(40)` over two static calls of `add1`: 42.
pub fn staticChain(h: *Hand) Allocator.Error!FuncId {
    const one = try h.constant(.{ .Int = 1 });
    const forty = try h.constant(.{ .Int = 40 });
    const add1 = try h.func("add1", 1);
    const twice = try h.func("twice", 1);
    const main = try h.func("main", 0);
    try h.body(add1, &.{.{ .insts = &.{ param(0, 0), konst(1, one), bin(2, .Add, 0, 1) }, .term = ret(2) }});
    try h.body(twice, &.{.{ .insts = &.{ param(0, 0), callStatic(1, add1, 0, 1), callStatic(2, add1, 1, 1) }, .term = ret(2) }});
    try h.body(main, &.{.{ .insts = &.{ konst(0, forty), callStatic(1, twice, 0, 1) }, .term = ret(1) }});
    try h.finish();
    return main;
}

fn constReturning(h: *Hand, name: []const u8, v: i32) Allocator.Error!FuncId {
    const c = try h.constant(.{ .Int = v });
    const f = try h.func(name, 1);
    try h.body(f, &.{.{ .insts = &.{konst(1, c)}, .term = ret(1) }});
    return f;
}

/// Virtual dispatch through two overrides (`Base.name` 1, `Mid` 2, `Leaf`
/// 3), a diamond (`D : B, C` with `B` overriding `A.v`: 20) and a member
/// implementing two interface roots (`R.w` for `P.w` and `Q.w`: 7), packed
/// into one number: 790123.
pub fn dispatch(h: *Hand) Allocator.Error!FuncId {
    const ctor = try ctorReturningThis(h);
    const base_name = try constReturning(h, "Base.name", 1);
    const mid_name = try constReturning(h, "Mid.name", 2);
    const leaf_name = try constReturning(h, "Leaf.name", 3);
    const base = try h.class("Base", .{});
    const mid = try h.class("Mid", .{ .supers = &.{base} });
    const leaf = try h.class("Leaf", .{ .supers = &.{mid} });
    try h.dispatch(base, base_name, base_name);
    try h.dispatch(mid, base_name, mid_name);
    try h.dispatch(leaf, base_name, leaf_name);

    const a_v = try constReturning(h, "A.v", 10);
    const b_v = try constReturning(h, "B.v", 20);
    const ia = try h.class("A", .{});
    const ib = try h.class("B", .{ .supers = &.{ia} });
    const ic = try h.class("C", .{ .supers = &.{ia} });
    const d = try h.class("D", .{ .supers = &.{ ib, ic } });
    try h.dispatch(ia, a_v, a_v);
    try h.dispatch(ib, a_v, b_v);
    try h.dispatch(ic, a_v, a_v);
    try h.dispatch(d, a_v, b_v);

    const p_w = try h.func("P.w", 1);
    const q_w = try h.func("Q.w", 1);
    const r_w = try constReturning(h, "R.w", 7);
    const ip = try h.class("P", .{});
    const iq = try h.class("Q", .{});
    const rc = try h.class("R", .{ .supers = &.{ ip, iq } });
    try h.dispatch(rc, p_w, r_w);
    try h.dispatch(rc, q_w, r_w);

    const c10 = try h.constant(.{ .Int = 10 });
    const c100 = try h.constant(.{ .Int = 100 });
    const c1000 = try h.constant(.{ .Int = 1000 });
    const c10000 = try h.constant(.{ .Int = 10000 });
    const c100000 = try h.constant(.{ .Int = 100000 });
    const main = try h.func("main", 0);
    try h.body(main, &.{.{ .insts = &.{
        newInstance(0, base, ctor, 0, 0),
        newInstance(1, mid, ctor, 0, 0),
        newInstance(2, leaf, ctor, 0, 0),
        newInstance(3, d, ctor, 0, 0),
        newInstance(4, rc, ctor, 0, 0),
        callVirtual(5, base_name, 0, 1),
        callVirtual(6, base_name, 1, 1),
        callVirtual(7, base_name, 2, 1),
        callInterface(8, ic, a_v, 3, 1),
        callInterface(9, ip, p_w, 4, 1),
        callInterface(10, iq, q_w, 4, 1),
        konst(11, c100),
        bin(12, .Mul, 5, 11),
        konst(13, c10),
        bin(14, .Mul, 6, 13),
        bin(15, .Add, 12, 14),
        bin(16, .Add, 15, 7),
        konst(17, c1000),
        bin(18, .Mul, 8, 17),
        bin(19, .Add, 16, 18),
        konst(20, c10000),
        bin(21, .Mul, 9, 20),
        bin(22, .Add, 19, 21),
        konst(23, c100000),
        bin(24, .Mul, 10, 23),
        bin(25, .Add, 22, 24),
    }, .term = ret(25) }});
    try h.finish();
    return main;
}

/// A constructor reads its slots before it writes them and sees the seeds:
/// `P(5)` stores `5 + 0` and whether slot 1 still held null. True.
pub fn seeds(h: *Hand) Allocator.Error!FuncId {
    const p = try h.class("P", .{ .seeds = &.{ .int, .null_ref }, .slot_names = &.{ "x", "s" } });
    const null_c = try h.constant(.Null);
    const five = try h.constant(.{ .Int = 5 });
    const ctor = try h.func("P.<init>", 2);
    try h.body(ctor, &.{.{ .insts = &.{
        param(0, 0),
        param(1, 1),
        getField(2, 0, 0),
        getField(3, 0, 1),
        konst(4, null_c),
        bin(5, .IdentEq, 3, 4),
        bin(6, .Add, 1, 2),
        setField(0, 0, 6),
        setField(0, 1, 5),
    }, .term = ret(0) }});
    const main = try h.func("main", 0);
    try h.body(main, &.{.{ .insts = &.{
        konst(0, five),
        newInstance(1, p, ctor, 0, 1),
        getField(2, 1, 0),
        getField(3, 1, 1),
        konst(4, five),
        bin(5, .Eq, 2, 4),
        bin(6, .And, 5, 3),
    }, .term = ret(6) }});
    try h.finish();
    return main;
}

/// Three statics one init unit writes. The unit reads `s1` before writing
/// it (the seed, 0), so `s0` is 7 and `s1` 14, and it runs once, so `s2`
/// is 1: 1471.
pub fn statics(h: *Hand) Allocator.Error!FuncId {
    const unit_fn = try h.func("<file init>", 0);
    const unit = try h.initUnit(unit_fn);
    const s0 = try h.static("s0", .int, unit);
    const s1 = try h.static("s1", .int, unit);
    const s2 = try h.static("s2", .int, unit);
    const c1 = try h.constant(.{ .Int = 1 });
    const c2 = try h.constant(.{ .Int = 2 });
    const c7 = try h.constant(.{ .Int = 7 });
    const c10 = try h.constant(.{ .Int = 10 });
    const c100 = try h.constant(.{ .Int = 100 });
    try h.body(unit_fn, &.{.{ .insts = &.{
        loadStatic(0, s1),
        konst(1, c7),
        bin(2, .Add, 0, 1),
        storeStatic(s0, 2),
        loadStatic(3, s0),
        konst(4, c2),
        bin(5, .Mul, 3, 4),
        storeStatic(s1, 5),
        loadStatic(6, s2),
        konst(7, c1),
        bin(8, .Add, 6, 7),
        storeStatic(s2, 8),
    }, .term = .{ .Return = null } }});
    const main = try h.func("main", 0);
    try h.body(main, &.{.{ .insts = &.{
        loadStatic(0, s1),
        loadStatic(1, s0),
        loadStatic(2, s2),
        konst(3, c100),
        bin(4, .Mul, 0, 3),
        konst(5, c10),
        bin(6, .Mul, 1, 5),
        bin(7, .Add, 4, 6),
        bin(8, .Add, 7, 2),
    }, .term = ret(8) }});
    try h.finish();
    return main;
}

/// An object whose constructor reads the object itself (the instance being
/// built) and counts its runs: two reads give one instance, built once.
/// True.
pub fn singleton(h: *Hand) Allocator.Error!FuncId {
    const o = try h.class("O", .{ .seeds = &.{ .boolean, .int }, .slot_names = &.{ "selfSeen", "n" } });
    const c1 = try h.constant(.{ .Int = 1 });
    const ctor = try h.func("O.<init>", 1);
    try h.body(ctor, &.{.{ .insts = &.{
        param(0, 0),
        loadObject(1, o),
        bin(2, .IdentEq, 1, 0),
        setField(0, 0, 2),
        getField(3, 0, 1),
        konst(4, c1),
        bin(5, .Add, 3, 4),
        setField(0, 1, 5),
    }, .term = ret(0) }});
    h.object(o, ctor);
    const main = try h.func("main", 0);
    try h.body(main, &.{.{ .insts = &.{
        loadObject(0, o),
        loadObject(1, o),
        bin(2, .IdentEq, 0, 1),
        getField(3, 0, 0),
        getField(4, 0, 1),
        konst(5, c1),
        bin(6, .Eq, 4, 5),
        bin(7, .And, 2, 3),
        bin(8, .And, 7, 6),
    }, .term = ret(8) }});
    try h.finish();
    return main;
}

/// A number boxed as a scalar value class, boxed again (the same instance),
/// tested, and unboxed twice (the second time the number itself); the sum
/// of the two unboxed numbers, 14, when the instance tests as the class and
/// the second box is the first.
pub fn boxing(h: *Hand) Allocator.Error!FuncId {
    const meters = try h.class("Meters", .{ .slot_names = &.{"value"}, .seeds = &.{.int} });
    const seven = try h.constant(.{ .Int = 7 });
    const minus = try h.constant(.{ .Int = -1 });
    const main = try h.func("main", 0);
    try h.body(main, &.{
        .{ .insts = &.{
            konst(0, seven),
            .{ .BoxValue = .{ .dst = reg(1), .src = reg(0), .class = meters, .slot = 0 } },
            .{ .BoxValue = .{ .dst = reg(2), .src = reg(1), .class = meters, .slot = 0 } },
            bin(3, .IdentEq, 1, 2),
            instanceOf(4, 1, meters, false),
            .{ .UnboxValue = .{ .dst = reg(5), .src = reg(2), .class = meters, .slot = 0 } },
            .{ .UnboxValue = .{ .dst = reg(6), .src = reg(5), .class = meters, .slot = 0 } },
            bin(7, .Add, 5, 6),
            bin(8, .And, 3, 4),
        }, .term = .{ .Branch = .{ .cond = reg(8), .t = BlockId.from(1), .f = BlockId.from(2) } } },
        .{ .insts = &.{}, .term = ret(7) },
        .{ .insts = &.{konst(9, minus)}, .term = ret(9) },
    });
    try h.finish();
    return main;
}

/// Type tests and casts on an instance, on null with and without
/// `nullable`, on a host `Int`, and against type values. True.
pub fn typeTests(h: *Hand) Allocator.Error!FuncId {
    const ctor = try ctorReturningThis(h);
    const animal = try h.class("Animal", .{});
    const dog = try h.class("Dog", .{ .supers = &.{animal} });
    const cat = try h.class("Cat", .{ .supers = &.{animal} });
    const int_c = try h.class("Int", .{});
    h.r.host_class.int = int_c;
    const null_c = try h.constant(.Null);
    const five = try h.constant(.{ .Int = 5 });
    const main = try h.func("main", 0);
    try h.body(main, &.{.{ .insts = &.{
        newInstance(0, dog, ctor, 0, 0),
        instanceOf(1, 0, animal, false),
        instanceOf(2, 0, cat, false),
        not(3, 2),
        konst(4, null_c),
        instanceOf(5, 4, animal, true),
        instanceOf(6, 4, animal, false),
        not(7, 6),
        cast(8, 0, animal, false, false),
        bin(9, .IdentEq, 8, 0),
        cast(10, 0, cat, false, true),
        bin(11, .IdentEq, 10, 4),
        cast(12, 4, animal, true, false),
        bin(13, .IdentEq, 12, 4),
        konst(14, five),
        instanceOf(15, 14, int_c, false),
        .{ .ClassLiteral = .{ .dst = reg(16), .class = animal } },
        .{ .InstanceOfDyn = .{ .dst = reg(17), .src = reg(0), .ty = reg(16), .nullable = false } },
        .{ .CastDyn = .{ .dst = reg(18), .src = reg(0), .ty = reg(16), .nullable = false, .safe = false } },
        bin(19, .IdentEq, 18, 0),
        .{ .ClassOf = .{ .dst = reg(20), .src = reg(0) } },
        .{ .InstanceOfDyn = .{ .dst = reg(21), .src = reg(0), .ty = reg(20), .nullable = false } },
        .{ .ClassLiteral = .{ .dst = reg(22), .class = cat } },
        .{ .InstanceOfDyn = .{ .dst = reg(23), .src = reg(0), .ty = reg(22), .nullable = false } },
        not(24, 23),
        bin(25, .And, 1, 3),
        bin(26, .And, 25, 5),
        bin(27, .And, 26, 7),
        bin(28, .And, 27, 9),
        bin(29, .And, 28, 11),
        bin(30, .And, 29, 13),
        bin(31, .And, 30, 15),
        bin(32, .And, 31, 17),
        bin(33, .And, 32, 19),
        bin(34, .And, 33, 21),
        bin(35, .And, 34, 24),
    }, .term = ret(35) }});
    try h.finish();
    return main;
}

/// A callee throws an `IllegalStateException`; the caller's handlers are
/// `Other` and then `Exception`, and the second takes it by class: 2.
pub fn catchByClass(h: *Hand) Allocator.Error!FuncId {
    const ctor = try ctorStoringMessage(h);
    const throwable = try throwableClass(h, "Throwable", &.{});
    const exception = try throwableClass(h, "Exception", &.{throwable});
    const illegal_state = try throwableClass(h, "IllegalStateException", &.{exception});
    const other = try throwableClass(h, "Other", &.{throwable});
    const bad = try h.constant(.{ .String = "bad" });
    const c0 = try h.constant(.{ .Int = 0 });
    const c1 = try h.constant(.{ .Int = 1 });
    const c2 = try h.constant(.{ .Int = 2 });
    const boom = try h.func("boom", 0);
    try h.body(boom, &.{.{ .insts = &.{ konst(0, bad), newInstance(1, illegal_state, ctor, 0, 1) }, .term = .{ .Throw = reg(1) } }});
    const main = try h.func("main", 0);
    try h.body(main, &.{
        .{ .insts = &.{callStatic(0, boom, 0, 0)}, .term = jump(3), .catches = &.{ catchClass(other, 1, 5), catchClass(exception, 2, 5) } },
        .{ .insts = &.{konst(6, c1)}, .term = ret(6) },
        .{ .insts = &.{ getField(7, 5, 0), konst(8, c2) }, .term = ret(8) },
        .{ .insts = &.{konst(9, c0)}, .term = ret(9) },
    });
    try h.finish();
    return main;
}

/// `Array` and `IntArray` construction, element reads and a write, a
/// `String` read, and an index past the end caught as
/// `IndexOutOfBoundsException`: 129 when every check holds, else -1.
pub fn arrays(h: *Hand) Allocator.Error!FuncId {
    const ctor = try ctorStoringMessage(h);
    const throwable = try throwableClass(h, "Throwable", &.{});
    const ioobe = try throwableClass(h, "IndexOutOfBoundsException", &.{throwable});
    h.r.exceptions.index_out_of_bounds = .{ .class = ioobe, .ctor = ctor };
    const array_c = try h.class("Array", .{});
    const int_array_c = try h.class("IntArray", .{});
    h.r.host_class.array = array_c;
    h.r.host_class.prim_array[@intFromEnum(runtime.PrimitiveArrayKind.Int)] = int_array_c;
    const c1 = try h.constant(.{ .Int = 1 });
    const c2 = try h.constant(.{ .Int = 2 });
    const c3 = try h.constant(.{ .Int = 3 });
    const c9 = try h.constant(.{ .Int = 9 });
    const c10 = try h.constant(.{ .Int = 10 });
    const c100 = try h.constant(.{ .Int = 100 });
    const cm1 = try h.constant(.{ .Int = -1 });
    const abc = try h.constant(.{ .String = "abc" });
    const b_char = try h.constant(.{ .Char = 'b' });
    const main = try h.func("main", 0);
    try h.body(main, &.{
        .{ .insts = &.{
            konst(0, c1),
            konst(1, c2),
            konst(2, c3),
            .{ .NewArray = .{ .dst = reg(3), .class = array_c, .args = reg(0), .n_args = 3 } },
            konst(4, c1),
            .{ .ArrayGet = .{ .dst = reg(5), .array = reg(3), .index = reg(4) } },
            konst(6, c2),
            konst(7, c9),
            .{ .ArraySet = .{ .array = reg(3), .index = reg(6), .value = reg(7) } },
            .{ .ArrayGet = .{ .dst = reg(8), .array = reg(3), .index = reg(6) } },
            konst(9, abc),
            .{ .ArrayGet = .{ .dst = reg(10), .array = reg(9), .index = reg(4) } },
            konst(11, b_char),
            bin(12, .Eq, 10, 11),
            .{ .NewArray = .{ .dst = reg(22), .class = int_array_c, .args = reg(0), .n_args = 3 } },
            .{ .ArrayGet = .{ .dst = reg(23), .array = reg(22), .index = reg(4) } },
            bin(24, .Eq, 23, 1),
            bin(25, .And, 12, 24),
        }, .term = jump(1) },
        .{ .insts = &.{ konst(13, c3), .{ .ArrayGet = .{ .dst = reg(14), .array = reg(3), .index = reg(13) } } }, .term = jump(3), .catches = &.{catchClass(ioobe, 2, 20)} },
        .{ .insts = &.{
            konst(15, c10),
            bin(16, .Mul, 5, 15),
            bin(17, .Add, 16, 8),
            konst(18, c100),
            bin(19, .Add, 17, 18),
        }, .term = .{ .Branch = .{ .cond = reg(25), .t = BlockId.from(4), .f = BlockId.from(3) } } },
        .{ .insts = &.{konst(21, cm1)}, .term = ret(21) },
        .{ .term = ret(19) },
    });
    try h.finish();
    return main;
}

/// The reused instructions' throws in a module lowered from sema, caught by
/// the tables' classes: `!!` on null, integer division by zero and a
/// `lateinit` read before its write, with kotlinc's messages. True.
pub fn reusedThrows(h: *Hand) Allocator.Error!FuncId {
    const ctor = try ctorStoringMessage(h);
    const throwable = try throwableClass(h, "Throwable", &.{});
    const npe = try throwableClass(h, "NullPointerException", &.{throwable});
    const arith = try throwableClass(h, "ArithmeticException", &.{throwable});
    const upae = try throwableClass(h, "UninitializedPropertyAccessException", &.{throwable});
    h.r.exceptions.null_pointer = .{ .class = npe, .ctor = ctor };
    h.r.exceptions.arithmetic = .{ .class = arith, .ctor = ctor };
    h.r.exceptions.uninitialized_property = .{ .class = upae, .ctor = ctor };
    const null_c = try h.constant(.Null);
    const false_c = try h.constant(.{ .Bool = false });
    const c0 = try h.constant(.{ .Int = 0 });
    const c1 = try h.constant(.{ .Int = 1 });
    const x_name = try h.constant(.{ .String = "x" });
    const div_msg = try h.constant(.{ .String = "/ by zero" });
    const late_msg = try h.constant(.{ .String = "lateinit property x has not been initialized" });
    const main = try h.func("main", 0);
    try h.body(main, &.{
        .{ .insts = &.{ konst(0, null_c), .{ .NotNullAssert = .{ .dst = reg(1), .src = reg(0) } } }, .term = jump(6), .catches = &.{catchClass(npe, 1, 3)} },
        .{ .term = jump(2) },
        .{ .insts = &.{ konst(4, c1), konst(5, c0), bin(7, .Div, 4, 5) }, .term = jump(6), .catches = &.{catchClass(arith, 3, 6)} },
        .{ .insts = &.{getField(8, 6, 0)}, .term = jump(4) },
        .{ .insts = &.{.{ .LateinitCheck = .{ .dst = reg(9), .src = reg(0), .name = x_name } }}, .term = jump(6), .catches = &.{catchClass(upae, 5, 10)} },
        .{ .insts = &.{
            getField(11, 10, 0),
            konst(12, late_msg),
            bin(13, .Eq, 11, 12),
            konst(14, div_msg),
            bin(15, .Eq, 8, 14),
            bin(16, .And, 13, 15),
        }, .term = ret(16) },
        .{ .insts = &.{konst(17, false_c)}, .term = ret(17) },
    });
    try h.finish();
    return main;
}

/// The VM's own throws caught by class: a virtual call on null and
/// `null as Animal` raise `NullPointerException`, `Dog as Cat` raises
/// `ClassCastException`: 7 when all three are caught, else 0.
pub fn vmThrows(h: *Hand) Allocator.Error!FuncId {
    const ctor = try ctorStoringMessage(h);
    const this_ctor = try ctorReturningThis(h);
    const throwable = try throwableClass(h, "Throwable", &.{});
    const npe = try throwableClass(h, "NullPointerException", &.{throwable});
    const cce = try throwableClass(h, "ClassCastException", &.{throwable});
    h.r.exceptions.null_pointer = .{ .class = npe, .ctor = ctor };
    h.r.exceptions.class_cast = .{ .class = cce, .ctor = ctor };
    const animal = try h.class("Animal", .{});
    const dog = try h.class("Dog", .{ .supers = &.{animal} });
    const cat = try h.class("Cat", .{ .supers = &.{animal} });
    const m_root = try h.func("Animal.m", 1);
    const null_c = try h.constant(.Null);
    const c0 = try h.constant(.{ .Int = 0 });
    const c7 = try h.constant(.{ .Int = 7 });
    const main = try h.func("main", 0);
    try h.body(main, &.{
        .{ .insts = &.{ konst(0, null_c), callVirtual(1, m_root, 0, 1) }, .term = jump(6), .catches = &.{catchClass(npe, 1, 2)} },
        .{ .term = jump(2) },
        .{ .insts = &.{ newInstance(3, dog, this_ctor, 0, 0), cast(4, 3, cat, false, false) }, .term = jump(6), .catches = &.{catchClass(cce, 3, 5)} },
        .{ .term = jump(4) },
        .{ .insts = &.{cast(6, 0, animal, false, false)}, .term = jump(6), .catches = &.{catchClass(npe, 5, 7)} },
        .{ .insts = &.{konst(8, c7)}, .term = ret(8) },
        .{ .insts = &.{konst(9, c0)}, .term = ret(9) },
    });
    try h.finish();
    return main;
}
