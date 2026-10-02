//! Human-readable IR dump (`klio dump-ir`) over a frozen `Module`, running
//! nothing. Every call site is classified DIRECT (an exact `FuncId`/`ClassId`
//! target), VIRTUAL (a numeric method slot), or DYNAMIC (resolved by name at
//! runtime); a dynamic call carrying a unique lowered target is BOUND, one
//! carrying none is UNBOUND.

const std = @import("std");
const ir = @import("ir.zig");

const Module = ir.Module;
const Func = ir.Func;
const Inst = ir.Inst;
const Const = ir.Const;

pub const Options = struct {
    /// Substring filter on `name`/`fqn`; null dumps the default set.
    func_filter: ?[]const u8 = null,
    /// Dump every appended function, not just `module.top_level`.
    all: bool = false,
    /// A module lowered from sema numbers the program's functions after the
    /// base's: the default set is then every function from this id on.
    program_from: ?u32 = null,
};

const Kind = enum { direct, virtual, dyn_bound, dyn_unbound };

const Tally = struct {
    direct: usize = 0,
    virtual: usize = 0,
    dyn_bound: usize = 0,
    dyn_unbound: usize = 0,

    fn add(self: *Tally, k: Kind) void {
        switch (k) {
            .direct => self.direct += 1,
            .virtual => self.virtual += 1,
            .dyn_bound => self.dyn_bound += 1,
            .dyn_unbound => self.dyn_unbound += 1,
        }
    }
    fn total(self: Tally) usize {
        return self.direct + self.virtual + self.dyn_bound + self.dyn_unbound;
    }
};

/// Null when the instruction is not a call site.
fn classify(inst: *const Inst) ?Kind {
    return switch (inst.*) {
        .CallStatic, .RNewInstance, .CallNative => .direct,
        .RCallVirtual, .CallInterface => .virtual,
        else => null,
    };
}

fn reg(r: ir.Reg) u32 {
    return r.int();
}

/// A `<...>` placeholder where the id is out of range or not a string.
fn constStr(m: *const Module, id: ir.ConstId) []const u8 {
    const i = id.int();
    if (i >= m.consts.items.len) return "<oob>";
    return switch (m.consts.items[i]) {
        .String => |s| s,
        else => "<non-str>",
    };
}

fn funcName(m: *const Module, id: ir.FuncId) []const u8 {
    return if (m.funcById(id)) |f| f.name else "<unknown>";
}

fn className(m: *const Module, id: ir.ClassId) []const u8 {
    for (m.classes.items) |*c| {
        if (c.id.int() == id.int()) return c.name;
    }
    return "<class?>";
}

fn slotName(m: *const Module, slot: ir.MethodSlotId) []const u8 {
    return funcName(m, ir.FuncId.from(slot.int()));
}

fn staticName(m: *const Module, id: ir.StaticId) []const u8 {
    const r = m.resolved orelse return "<static?>";
    return if (id.int() < r.statics.len) r.statics[id.int()].name else "<static?>";
}

fn nativeName(m: *const Module, id: ir.NativeId) []const u8 {
    const r = m.resolved orelse return "<native?>";
    return if (id.int() < r.natives.len) r.natives[id.int()].name else "<native?>";
}

fn regList(w: *std.Io.Writer, regs: []const ir.Reg) !void {
    try w.writeByte('[');
    for (regs, 0..) |r, i| {
        if (i != 0) try w.writeAll(", ");
        try w.print("r{d}", .{reg(r)});
    }
    try w.writeByte(']');
}

fn nullMark(nullable: bool) []const u8 {
    return if (nullable) "?" else "";
}

/// The instructions lowered from sema: every operand is an id, printed with
/// the display name beside it.
fn dumpResolved(w: *std.Io.Writer, m: *const Module, inst: *const Inst) !bool {
    switch (inst.*) {
        .CallStatic => |c| {
            try w.print("r{d} <- CallStatic {s}#{d} ", .{ reg(c.dst), funcName(m, c.func), c.func.int() });
            try argRun(w, c.args, c.n_args);
            try w.writeAll("        [DIRECT]");
        },
        .RCallVirtual => |c| {
            try w.print("r{d} <- CallVirtual slot {s}#{d} ", .{ reg(c.dst), slotName(m, c.slot), c.slot.int() });
            try argRun(w, c.args, c.n_args);
            try w.writeAll("        [VIRTUAL]");
        },
        .CallInterface => |c| {
            try w.print("r{d} <- CallInterface {s}#{d} slot {s}#{d} ", .{ reg(c.dst), className(m, c.iface), c.iface.int(), slotName(m, c.slot), c.slot.int() });
            try argRun(w, c.args, c.n_args);
            try w.writeAll("        [VIRTUAL]");
        },
        .CallNative => |c| {
            try w.print("r{d} <- CallNative {s}#{d} ", .{ reg(c.dst), nativeName(m, c.native), c.native.int() });
            try argRun(w, c.args, c.n_args);
            try w.writeAll("        [DIRECT]");
        },
        .RCallValue => |c| {
            try w.print("r{d} <- CallValue r{d} ", .{ reg(c.dst), reg(c.callee) });
            try argRun(w, c.args, c.n_args);
        },
        .RNewInstance => |c| {
            try w.print("r{d} <- NewInstance {s}#{d} ctor {s}#{d} ", .{ reg(c.dst), className(m, c.class), c.class.int(), funcName(m, c.ctor), c.ctor.int() });
            try argRun(w, c.args, c.n_args);
            try w.writeAll("        [DIRECT]");
        },
        .GetFieldSlot => |c| try w.print("r{d} <- GetFieldSlot r{d}.#{d}", .{ reg(c.dst), reg(c.obj), c.slot }),
        .SetFieldSlot => |c| try w.print("SetFieldSlot r{d}.#{d} <- r{d}", .{ reg(c.obj), c.slot, reg(c.value) }),
        .LoadStatic => |c| try w.print("r{d} <- LoadStatic {s}#{d}", .{ reg(c.dst), staticName(m, c.static), c.static.int() }),
        .StoreStatic => |c| try w.print("StoreStatic {s}#{d} <- r{d}", .{ staticName(m, c.static), c.static.int(), reg(c.value) }),
        .LoadObject => |c| try w.print("r{d} <- LoadObject {s}#{d}", .{ reg(c.dst), className(m, c.class), c.class.int() }),
        .MakeClosure => |c| {
            try w.print("r{d} <- MakeClosure {s}#{d} captures=", .{ reg(c.dst), funcName(m, c.func), c.func.int() });
            try regList(w, c.captures);
        },
        .FunctionRef => |c| {
            try w.print("r{d} <- FunctionRef {s}#{d} adapter {s}#{d}", .{ reg(c.dst), funcName(m, c.target), c.target.int(), funcName(m, c.adapter), c.adapter.int() });
            if (c.bound) |b| try w.print(" bound=r{d}", .{reg(b)});
        },
        .RPropertyRef => |c| {
            try w.print("r{d} <- PropertyRef '{s}' get {s}#{d}", .{ reg(c.dst), constStr(m, c.name), funcName(m, c.getter), c.getter.int() });
            if (c.setter != ir.NO_FUNC) try w.print(" set {s}#{d}", .{ funcName(m, ir.FuncId.from(c.setter)), c.setter });
            if (c.bound) |b| try w.print(" bound=r{d}", .{reg(b)});
        },
        .ClassLiteral => |c| try w.print("r{d} <- ClassLiteral {s}#{d}", .{ reg(c.dst), className(m, c.class), c.class.int() }),
        .ClassOf => |c| try w.print("r{d} <- ClassOf r{d}", .{ reg(c.dst), reg(c.src) }),
        .RInstanceOf => |c| try w.print("r{d} <- InstanceOf r{d} is {s}#{d}{s}", .{ reg(c.dst), reg(c.src), className(m, c.class), c.class.int(), nullMark(c.nullable) }),
        .RCast => |c| try w.print("r{d} <- Cast r{d} as{s} {s}#{d}{s}", .{ reg(c.dst), reg(c.src), nullMark(c.safe), className(m, c.class), c.class.int(), nullMark(c.nullable) }),
        .InstanceOfDyn => |c| try w.print("r{d} <- InstanceOfDyn r{d} is r{d}{s}", .{ reg(c.dst), reg(c.src), reg(c.ty), nullMark(c.nullable) }),
        .CastDyn => |c| try w.print("r{d} <- CastDyn r{d} as{s} r{d}{s}", .{ reg(c.dst), reg(c.src), nullMark(c.safe), reg(c.ty), nullMark(c.nullable) }),
        .ArrayGet => |c| try w.print("r{d} <- ArrayGet r{d}[r{d}]", .{ reg(c.dst), reg(c.array), reg(c.index) }),
        .ArraySet => |c| try w.print("ArraySet r{d}[r{d}] <- r{d}", .{ reg(c.array), reg(c.index), reg(c.value) }),
        .IterOpen => |c| try w.print("r{d} <- IterOpen r{d}", .{ reg(c.dst), reg(c.src) }),
        .IterHas => |c| try w.print("r{d} <- IterHas r{d}[r{d}] stamp r{d}", .{ reg(c.dst), reg(c.src), reg(c.idx), reg(c.stamp) }),
        .IterGet => |c| try w.print("r{d} <- IterGet r{d}[r{d}] stamp r{d}", .{ reg(c.dst), reg(c.src), reg(c.idx), reg(c.stamp) }),
        .BoxValue => |c| try w.print("r{d} <- BoxValue r{d} as {s}#{d} slot {d}", .{ reg(c.dst), reg(c.src), className(m, c.class), c.class.int(), c.slot }),
        .UnboxValue => |c| try w.print("r{d} <- UnboxValue r{d} from {s}#{d} slot {d}", .{ reg(c.dst), reg(c.src), className(m, c.class), c.class.int(), c.slot }),
        .NewArray => |c| {
            try w.print("r{d} <- NewArray {s}#{d} ", .{ reg(c.dst), className(m, c.class), c.class.int() });
            try argRun(w, c.args, c.n_args);
        },
        else => return false,
    }
    return true;
}

fn argRun(w: *std.Io.Writer, args: ir.Reg, n: u32) !void {
    if (n == 0) {
        try w.writeAll("()");
        return;
    }
    try w.print("(r{d}..+{d})", .{ reg(args), n });
}

fn dumpInst(w: *std.Io.Writer, m: *const Module, inst: *const Inst, tally: *Tally) !void {
    if (classify(inst)) |k| tally.add(k);
    if (try dumpResolved(w, m, inst)) {
        try w.writeAll("\n");
        return;
    }
    switch (inst.*) {
        .Const => |c| {
            try w.print("r{d} <- Const c{d} ({s}", .{ reg(c.dst), c.value.int(), constLabel(m, c.value) });
            if (c.value.int() < m.consts.items.len) {
                switch (m.consts.items[c.value.int()]) {
                    .Int => |v| try w.print(" {d}", .{v}),
                    .Long => |v| try w.print(" {d}", .{v}),
                    .Bool => |v| try w.print(" {}", .{v}),
                    .Double => |v| try w.print(" {d}", .{v}),
                    else => {},
                }
            }
            try w.writeAll(")");
        },
        .LoadParam => |c| try w.print("r{d} <- LoadParam #{d}", .{ reg(c.dst), c.idx }),
        .LoadCapture => |c| try w.print("r{d} <- LoadCapture #{d}", .{ reg(c.dst), c.idx }),
        .Move => |c| try w.print("r{d} <- Move r{d}", .{ reg(c.dst), reg(c.src) }),
        .MakeCell => |c| try w.print("r{d} <- MakeCell r{d}", .{ reg(c.dst), reg(c.src) }),
        .CellGet => |c| try w.print("r{d} <- CellGet r{d}", .{ reg(c.dst), reg(c.cell) }),
        .CellSet => |c| try w.print("CellSet r{d} <- r{d}", .{ reg(c.cell), reg(c.value) }),
        .BinOp => |c| try w.print("r{d} <- BinOp {s} r{d}, r{d}", .{ reg(c.dst), @tagName(c.op), reg(c.lhs), reg(c.rhs) }),
        .UnOp => |c| try w.print("r{d} <- UnOp {s} r{d}", .{ reg(c.dst), @tagName(c.op), reg(c.operand) }),
        .Not => |c| try w.print("r{d} <- Not r{d}", .{ reg(c.dst), reg(c.src) }),
        .NotNullAssert => |c| try w.print("r{d} <- NotNullAssert r{d}", .{ reg(c.dst), reg(c.src) }),
        .LateinitCheck => |c| try w.print("r{d} <- LateinitCheck r{d} '{s}'", .{ reg(c.dst), reg(c.src), constStr(m, c.name) }),
        else => try w.print("{s}", .{@tagName(inst.*)}),
    }
    try w.writeAll("\n");
}

fn constLabel(m: *const Module, id: ir.ConstId) []const u8 {
    const i = id.int();
    if (i >= m.consts.items.len) return "oob";
    return @tagName(m.consts.items[i]);
}

fn dumpTerminator(w: *std.Io.Writer, t: *const ir.Terminator) !void {
    switch (t.*) {
        .Goto => |b| try w.print("    goto b{d}\n", .{b.int()}),
        .Branch => |br| try w.print("    branch r{d} ? b{d} : b{d}\n", .{ reg(br.cond), br.t.int(), br.f.int() }),
        .Return => |r| if (r) |rr| try w.print("    return r{d}\n", .{reg(rr)}) else try w.writeAll("    return unit\n"),
        .Throw => |r| try w.print("    throw r{d}\n", .{reg(r)}),
        .Unreachable => try w.writeAll("    unreachable\n"),
    }
}

fn dumpFunc(w: *std.Io.Writer, m: *const Module, f: *const Func, mod_tally: *Tally) !void {
    try w.print("func #{d}  {s}(", .{ f.id.int(), f.name });
    for (f.params, 0..) |p, i| {
        if (i != 0) try w.writeAll(", ");
        try w.print("{s}", .{p.name});
    }
    try w.print(")   [kind={s}{s}{s} ret={s}{s}]\n", .{
        @tagName(f.kind),
        if (f.is_suspend) " suspend" else "",
        if (f.is_inline) " inline" else "",
        if (f.return_ty.name.len != 0) f.return_ty.name else "-",
        if (f.return_ty.nullable) "?" else "",
    });

    if (!f.hasBody()) {
        try w.writeAll("  <no body (native / abstract / deferred)>\n\n");
        return;
    }
    if (f.blocks.len == 0) {
        try w.writeAll("  <body deferred; not decoded>\n\n");
        return;
    }

    var tally: Tally = .{};
    for (f.blocks) |*b| {
        try w.print("  b{d}:\n", .{b.id.int()});
        for (b.insts) |*inst| {
            try w.writeAll("    ");
            try dumpInst(w, m, inst, &tally);
        }
        try dumpTerminator(w, &b.terminator);
    }
    try w.print("  calls: {d} direct, {d} virtual, {d} dynamic ({d} bound, {d} unbound)\n\n", .{
        tally.direct, tally.virtual, tally.dyn_bound + tally.dyn_unbound, tally.dyn_bound, tally.dyn_unbound,
    });
    mod_tally.direct += tally.direct;
    mod_tally.virtual += tally.virtual;
    mod_tally.dyn_bound += tally.dyn_bound;
    mod_tally.dyn_unbound += tally.dyn_unbound;
}

fn matches(f: *const Func, filter: []const u8) bool {
    return std.mem.find(u8, f.name, filter) != null or std.mem.find(u8, f.fqn, filter) != null;
}

pub fn dumpModule(w: *std.Io.Writer, m: *const Module, opts: Options) !void {
    var mod_tally: Tally = .{};
    var dumped: usize = 0;

    if (opts.func_filter) |filter| {
        for (m.funcs.items) |*f| {
            if (matches(f, filter)) {
                try dumpFunc(w, m, f, &mod_tally);
                dumped += 1;
            }
        }
    } else if (opts.all) {
        for (m.funcs.items) |*f| {
            try dumpFunc(w, m, f, &mod_tally);
            dumped += 1;
        }
    } else if (opts.program_from) |from| {
        for (m.funcs.items[@min(from, m.funcs.items.len)..]) |*f| {
            try dumpFunc(w, m, f, &mod_tally);
            dumped += 1;
        }
    } else {
        // `buildModuleFiles` links the whole stdlib and any gated packs into one
        // module, so the default set is the user script: no package header, no
        // receiver, no synthesized thunk. Reach a packaged function by `--func`.
        for (m.funcs.items) |*f| {
            if (f.package.len != 0 or f.has_receiver_param or f.kind != .plain or
                f.is_lambda or std.mem.startsWith(u8, f.name, "__")) continue;
            try dumpFunc(w, m, f, &mod_tally);
            dumped += 1;
        }
        if (dumped == 0) {
            try w.writeAll("(no top-level package-less user functions; this file declares a package — use --func NAME or --all)\n");
        }
    }

    try w.print("module rollup: {d} functions, {d} direct, {d} virtual, {d} dynamic ({d} bound, {d} unbound)\n", .{
        dumped, mod_tally.direct, mod_tally.virtual, mod_tally.dyn_bound + mod_tally.dyn_unbound, mod_tally.dyn_bound, mod_tally.dyn_unbound,
    });
}

test "a program's functions are the default set when they follow a base" {
    const hand = ir.eval.hand;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try hand.Hand.init(a);
    _ = try hand.dispatch(&h);
    const n = h.m.funcs.items.len;
    try std.testing.expect(n > 2);
    var aw: std.Io.Writer.Allocating = .init(a);
    try dumpModule(&aw.writer, h.m, .{ .program_from = @intCast(n - 2) });
    const out = aw.written();
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "func #"));
    const first = try std.fmt.allocPrint(a, "func #{d} ", .{n - 2});
    try std.testing.expect(std.mem.startsWith(u8, out, first));
    try std.testing.expect(std.mem.find(u8, out, "module rollup: 2 functions") != null);
}

test "the instructions lowered from sema print their ids beside display names" {
    const hand = ir.eval.hand;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try hand.Hand.init(a);
    _ = try hand.dispatch(&h);
    var aw: std.Io.Writer.Allocating = .init(a);
    try dumpModule(&aw.writer, h.m, .{ .func_filter = "main" });
    const out = aw.written();
    try std.testing.expect(std.mem.find(u8, out, "r0 <- NewInstance Base#0 ctor <init>#0 ()        [DIRECT]") != null);
    try std.testing.expect(std.mem.find(u8, out, "r5 <- CallVirtual slot Base.name#1 (r0..+1)        [VIRTUAL]") != null);
    try std.testing.expect(std.mem.find(u8, out, "r8 <- CallInterface C#5 slot A.v#4 (r3..+1)        [VIRTUAL]") != null);
}
