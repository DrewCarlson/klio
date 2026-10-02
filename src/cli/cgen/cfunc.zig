//! One compiled body as a C function: every block a label, every scalar
//! register a typed C local, every reference register a slot of the frame
//! the body publishes to the collector.

const std = @import("std");
const ir = @import("ir");

const ctype = @import("ctype.zig");
const typing = @import("typing.zig");
const program = @import("program.zig");

const Ty = ctype.Ty;
const Program = program.Program;
const Body = program.Body;
const Writer = std.Io.Writer;
const Reg = ir.Reg;
const FuncId = ir.FuncId;
const ClassId = ir.ClassId;

pub const Error = error{ OutOfMemory, WriteFailed };

/// The exceptions the runtime raises, as `klio_r_raise` numbers them.
pub const Raise = @import("rt_abi.zig").Raise;

const Fn = struct {
    p: *Program,
    b: *const Body,
    w: *Writer,
    /// By block: its position in reverse postorder, for back edges.
    order: []u32,
    /// Scratch for one expression.
    ex: std.Io.Writer.Allocating,

    fn ty(self: *const Fn, r: Reg) Ty {
        if (r.int() >= self.b.t.tys.len) return .object;
        return self.b.t.tys[r.int()];
    }

    fn cls(self: *const Fn, r: Reg) ?ClassId {
        if (r.int() >= self.b.t.cls.len) return null;
        return self.b.t.cls[r.int()];
    }

    fn reg(self: *Fn, r: Reg) Error![]const u8 {
        if (self.ty(r) == .object) return std.fmt.allocPrint(self.p.a, "KS[{d}]", .{self.b.slot[r.int()]});
        return std.fmt.allocPrint(self.p.a, "r{d}", .{r.int()});
    }

    /// `r` converted to kind `want`.
    fn as(self: *Fn, r: Reg, want: Ty) Error![]const u8 {
        const name = try self.reg(r);
        var aw: std.Io.Writer.Allocating = .init(self.p.a);
        try ctype.writeConv(&aw.writer, self.ty(r), want, name);
        return aw.written();
    }

    fn boxed(self: *Fn, r: Reg) Error![]const u8 {
        return self.as(r, .object);
    }

    /// Writes `dst = expr`, where `expr` is of kind `have`.
    fn assign(self: *Fn, dst: Reg, expr: []const u8, have: Ty) Error!void {
        const name = try self.reg(dst);
        try self.w.print("  {s} = ", .{name});
        try ctype.writeConv(self.w, have, self.ty(dst), expr);
        try self.w.writeAll(";\n");
    }

    fn fmt(self: *Fn, comptime f: []const u8, args: anytype) Error![]const u8 {
        return std.fmt.allocPrint(self.p.a, f, args);
    }

    /// The argument array `ka` for a call of `n` values from `args`, boxed.
    fn argArray(self: *Fn, args: Reg, n: u32, skip: u32) Error![]const u8 {
        if (n <= skip) return "0";
        try self.w.print("  {{ klio_value ka[{d}] = {{", .{n - skip});
        var i: u32 = skip;
        while (i < n) : (i += 1) {
            if (i != skip) try self.w.writeAll(", ");
            try self.w.writeAll(try self.boxed(Reg.from(args.int() + i)));
        }
        try self.w.writeAll("};\n");
        return "ka";
    }
};

/// A C function's symbol.
pub fn symbol(a: std.mem.Allocator, f: FuncId) ![]const u8 {
    return std.fmt.allocPrint(a, "kf_{d}", .{f.int()});
}

/// The prototype of body `b`.
pub fn writeProto(w: *Writer, b: *const Body) !void {
    try w.print("static {s} kf_{d}(", .{ b.sig.ret.cName(), b.id.int() });
    var any = false;
    if (b.closure) {
        try w.writeAll("klio_value kself");
        any = true;
    }
    for (b.sig.params, 0..) |t, i| {
        if (any) try w.writeAll(", ");
        try w.print("{s} p{d}", .{ t.cName(), i });
        any = true;
    }
    if (!any) try w.writeAll("void");
    try w.writeByte(')');
}

/// The blocks in reverse postorder over normal and handler edges.
fn blockOrder(p: *Program, f: *const ir.Func) Error![]u32 {
    const n = f.blocks.len;
    const order = try p.a.alloc(u32, n);
    @memset(order, std.math.maxInt(u32));
    if (n == 0) return order;
    const seen = try p.a.alloc(bool, n);
    @memset(seen, false);
    var post: std.ArrayList(u32) = .empty;
    const Frame = struct { bi: u32, next: u32 };
    var stack: std.ArrayList(Frame) = .empty;
    const entry = f.entry.int();
    seen[entry] = true;
    try stack.append(p.a, .{ .bi = entry, .next = 0 });
    while (stack.items.len != 0) {
        const top = &stack.items[stack.items.len - 1];
        const blk = &f.blocks[top.bi];
        if (succ(blk, top.next)) |s| {
            top.next += 1;
            if (s < n and !seen[s]) {
                seen[s] = true;
                try stack.append(p.a, .{ .bi = s, .next = 0 });
            }
            continue;
        }
        try post.append(p.a, top.bi);
        _ = stack.pop();
    }
    const total = post.items.len;
    for (post.items, 0..) |bi, i| order[bi] = @intCast(total - 1 - i);
    return order;
}

fn succ(blk: *const ir.Block, i: u32) ?u32 {
    const catches = blk.h().catches;
    if (i < catches.len) return catches[i].handler.int();
    const k = i - @as(u32, @intCast(catches.len));
    return switch (blk.terminator) {
        .Goto => |g| if (k == 0) g.int() else null,
        .Branch => |br| switch (k) {
            0 => br.t.int(),
            1 => br.f.int(),
            else => null,
        },
        else => null,
    };
}

pub fn writeBody(p: *Program, w: *Writer, b: *const Body) Error!void {
    var fx: Fn = .{ .p = p, .b = b, .w = w, .order = try blockOrder(p, b.f), .ex = .init(p.a) };
    const f = b.f;
    try w.print("/* {s} */\n", .{f.fqn});
    try writeProto(w, b);
    try w.writeAll(" {\n");
    // A local written after `setjmp` and read after the jump back must be volatile.
    const vol: []const u8 = if (b.has_try) "volatile " else "";
    var r: u32 = 0;
    while (r < f.n_locals) : (r += 1) {
        const t = b.t.tys[r];
        if (t == .object) continue;
        try w.print("  {s}{s} r{d} = 0; (void)r{d};\n", .{ vol, t.cName(), r, r });
    }
    for (b.sig.params, 0..) |_, i| try w.print("  (void)p{d};\n", .{i});
    if (b.closure) try w.writeAll("  (void)kself;\n");
    if (b.n_slots != 0) {
        try w.print("  klio_value KS[{d}];\n  for (unsigned i = 0; i < {d}; i++) KS[i] = klio_nat_box_unit();\n", .{ b.n_slots, b.n_slots });
        try w.print("  klio_nat_frame KF; KF.n = {d}; KF.slots = KS; klio_nat_enter(&KF);\n", .{b.n_slots});
    }
    if (b.has_try) {
        try w.writeAll("  klio_try *KTE = klio_try_top;\n");
        for (f.blocks, 0..) |*blk, bi| {
            if (blk.h().catches.len == 0) continue;
            try w.print("  klio_try KT{d}; klio_nat_frame *KM{d};\n", .{ bi, bi });
        }
    }
    try w.writeAll("  klio_nat_safepoint();\n");
    try w.print("  goto B{d};\n", .{f.entry.int()});
    for (f.blocks, 0..) |*blk, bi| {
        if (fx.order[bi] == std.math.maxInt(u32)) continue;
        try w.print("B{d}:;\n", .{bi});
        try writeBlockEntry(&fx, blk, bi);
        for (blk.insts) |*inst| try writeInst(&fx, inst);
        try writeTerminator(&fx, blk, bi);
    }
    try w.writeAll("}\n\n");
}

/// A try region's frame is armed on every fresh entry of its body's
/// block and popped where normal flow leaves it, as the VM keeps its try
/// stack. A throw lands back here and tries each handler in order.
fn writeBlockEntry(fx: *Fn, blk: *const ir.Block, bi: usize) Error!void {
    const w = fx.w;
    const h = blk.h();
    if (h.catch_done_for) |body| try w.print("  klio_try_pop(&KT{d});\n", .{body.int()});
    if (h.catches.len == 0) return;
    try w.print("  KM{d} = klio_nat_frame_mark();\n  klio_try_arm(&KT{d});\n", .{ bi, bi });
    try w.print("  if (setjmp(KT{d}.jb) != 0) {{\n", .{bi});
    try w.print("    klio_nat_frame_restore(KM{d});\n    klio_try_top = KT{d}.prev;\n", .{ bi, bi });
    for (h.catches) |c| {
        const target = try fx.reg(c.exception_reg);
        try w.print("    if (klio_r_is_a(klio_in_flight, {d}u, 0)) {{ {s} = klio_in_flight; goto B{d}; }} /* {s} */\n", .{ c.class.int(), target, c.handler.int(), fx.p.className(c.class.int()) });
    }
    try w.writeAll("    kthrow(klio_in_flight);\n  }\n");
}

fn isBackEdge(fx: *const Fn, from: usize, to: ir.BlockId) bool {
    const t = to.int();
    if (t >= fx.order.len) return false;
    return fx.order[t] <= fx.order[from];
}

fn writeJump(fx: *Fn, from: usize, to: ir.BlockId) Error!void {
    if (isBackEdge(fx, from, to)) try fx.w.writeAll("klio_nat_safepoint(); ");
    try fx.w.print("goto B{d};", .{to.int()});
}

fn writeReturnValue(fx: *Fn, expr: []const u8, have: Ty) Error!void {
    const w = fx.w;
    const ret = fx.b.sig.ret;
    try w.print("  {{ {s} kret = ", .{ret.cName()});
    try ctype.writeConv(w, have, ret, expr);
    try w.writeAll(";");
    if (fx.b.has_try) try w.writeAll(" klio_try_top = KTE;");
    if (fx.b.n_slots != 0) try w.writeAll(" klio_nat_leave(&KF);");
    try w.writeAll(" return kret; }\n");
}

fn writeTerminator(fx: *Fn, blk: *const ir.Block, bi: usize) Error!void {
    const w = fx.w;
    // A jump out of a try region pops its frame.
    if (blk.terminator == .Goto) {
        for (blk.h().pop_on_exit) |body| try w.print("  klio_try_pop(&KT{d});\n", .{body.int()});
    }
    switch (blk.terminator) {
        .Goto => |g| {
            try w.writeAll("  ");
            try writeJump(fx, bi, g);
            try w.writeAll("\n");
        },
        .Branch => |br| {
            try w.print("  if ({s}) {{ ", .{try fx.as(br.cond, .boolean)});
            try writeJump(fx, bi, br.t);
            try w.writeAll(" } else { ");
            try writeJump(fx, bi, br.f);
            try w.writeAll(" }\n");
        },
        .Return => |r| {
            if (r) |x| {
                try writeReturnValue(fx, try fx.reg(x), fx.ty(x));
            } else try writeReturnValue(fx, "klio_nat_box_unit()", .object);
        },
        .Throw => |r| try w.print("  kthrow({s});\n", .{try fx.boxed(r)}),
        .Unreachable => try w.writeAll("  klio_r_unreachable();\n"),
    }
}

/// A constant as a boxed value expression.
fn writeConstValue(fx: *Fn, c: ir.Const) Error!void {
    const w = fx.w;
    switch (c) {
        .String => |s| {
            try w.writeAll("klio_nat_string(");
            try ctype.writeCString(w, s);
            try w.print(", {d})", .{s.len});
        },
        .Null => try w.writeAll("klio_nat_null()"),
        else => {
            var aw: std.Io.Writer.Allocating = .init(fx.p.a);
            try ctype.writeScalar(&aw.writer, c);
            try ctype.writeBox(w, ctype.constTy(c), aw.written());
        },
    }
}

fn writeInst(fx: *Fn, inst: *const ir.Inst) Error!void {
    const p = fx.p;
    const w = fx.w;
    switch (inst.*) {
        .Trace => {},
        .Const => |x| {
            const c = p.m.consts.items[x.value.int()];
            var aw: std.Io.Writer.Allocating = .init(p.a);
            switch (c) {
                .String, .Null => {
                    const saved = fx.w;
                    fx.w = &aw.writer;
                    try writeConstValue(fx, c);
                    fx.w = saved;
                    try fx.assign(x.dst, aw.written(), .object);
                },
                else => {
                    try ctype.writeScalar(&aw.writer, c);
                    try fx.assign(x.dst, aw.written(), ctype.constTy(c));
                },
            }
        },
        .LoadParam => |x| {
            if (x.idx >= fx.b.sig.params.len) {
                p.refuse("`{s}` reads parameter {d} of {d}", .{ fx.b.f.fqn, x.idx, fx.b.sig.params.len });
                return;
            }
            try fx.assign(x.dst, try fx.fmt("p{d}", .{x.idx}), fx.b.sig.params[x.idx]);
        },
        .LoadCapture => |x| {
            if (!fx.b.closure) {
                p.refuse("`{s}` reads a capture but is not a closure body", .{fx.b.f.fqn});
                return;
            }
            try fx.assign(x.dst, try fx.fmt("klio_r_get(kself, {d})", .{x.idx}), .object);
        },
        .Move => |x| try fx.assign(x.dst, try fx.reg(x.src), fx.ty(x.src)),
        .MakeCell => |x| try fx.assign(x.dst, try fx.fmt("klio_nat_cell({s})", .{try fx.boxed(x.src)}), .object),
        .CellGet => |x| try fx.assign(x.dst, try fx.fmt("klio_nat_cell_get({s})", .{try fx.boxed(x.cell)}), .object),
        .CellSet => |x| try w.print("  klio_nat_cell_set({s}, {s});\n", .{ try fx.boxed(x.cell), try fx.boxed(x.value) }),
        .GetFieldSlot => |x| try fx.assign(x.dst, try fx.fmt("klio_r_get({s}, {d})", .{ try fx.boxed(x.obj), x.slot }), .object),
        .SetFieldSlot => |x| try w.print("  klio_r_set({s}, {d}, {s});\n", .{ try fx.boxed(x.obj), x.slot, try fx.boxed(x.value) }),
        .LoadStatic => |x| {
            try writeUnitTouch(fx, x.static);
            try fx.assign(x.dst, try fx.fmt("KG[{d}]", .{p.staticIndex(x.static)}), .object);
        },
        .StoreStatic => |x| {
            try writeUnitTouch(fx, x.static);
            try w.print("  KG[{d}] = {s};\n", .{ p.staticIndex(x.static), try fx.boxed(x.value) });
        },
        .LoadObject => |x| {
            if (p.r.host_class.unit) |u| if (u == x.class) return fx.assign(x.dst, "klio_nat_box_unit()", .object);
            try fx.assign(x.dst, try fx.fmt("ko_{d}()", .{x.class.int()}), .object);
        },
        .RNewInstance => |x| {
            // A host-backed class's constructor is a native that makes the
            // host value itself.
            if (p.nativeOf(x.ctor)) |n| return writeNativeCall(fx, n, x.dst, x.args, x.n_args);
            const cb = p.body(x.ctor) orelse {
                p.refuse("the constructor `{s}` is not compiled", .{p.funcName(x.ctor)});
                return;
            };
            // The instance is in `dst` while its constructor runs.
            try fx.assign(x.dst, try fx.fmt("klio_r_new({d}u)", .{x.class.int()}), .object);
            if (cb.sig.params.len == 0) {
                p.refuse("the constructor `{s}` takes no instance", .{p.funcName(x.ctor)});
                return;
            }
            var call: std.Io.Writer.Allocating = .init(p.a);
            try call.writer.print("kf_{d}({s}", .{ x.ctor.int(), try fx.reg(x.dst) });
            const rest = try callExpr(fx, "", cb.sig.params[1..], x.args, x.n_args);
            // `rest` is `(args...)`; the instance leads them.
            if (rest.len > 2) try call.writer.writeAll(", ");
            try call.writer.writeAll(rest[1..]);
            try fx.assign(x.dst, call.written(), cb.sig.ret);
        },
        .CallStatic => |x| {
            try writeUnitRun(fx, x.init);
            if (p.nativeOf(x.func)) |n| return writeNativeCall(fx, n, x.dst, x.args, x.n_args);
            const cb = p.body(x.func) orelse {
                p.refuse("`{s}` is not compiled", .{p.funcName(x.func)});
                return;
            };
            if (cb.closure) {
                p.refuse("`{s}` is called directly and made a closure of", .{p.funcName(x.func)});
                return;
            }
            try fx.assign(x.dst, try callExpr(fx, try fx.fmt("kf_{d}", .{x.func.int()}), cb.sig.params, x.args, x.n_args), cb.sig.ret);
        },
        .CallNative => |x| try writeNativeCall(fx, x.native, x.dst, x.args, x.n_args),
        .RCallVirtual => |x| try writeVirtualCall(fx, x.slot, x.dst, x.args, x.n_args),
        .CallInterface => |x| try writeVirtualCall(fx, x.slot, x.dst, x.args, x.n_args),
        .RCallValue => |x| {
            const arr = try fx.argArray(x.args, x.n_args, 0);
            try fx.assign(x.dst, try fx.fmt("kcall({s}, {s}, {d})", .{ try fx.boxed(x.callee), arr, x.n_args }), .object);
            if (x.n_args != 0) try w.writeAll("  }\n");
        },
        .MakeClosure => |x| {
            const cc = p.closureOf(x.func) orelse {
                p.refuse("a closure of `{s}` has no class", .{p.funcName(x.func)});
                return;
            };
            if (x.captures.len == 0) return fx.assign(x.dst, try fx.fmt("klam_{d}()", .{cc.id}), .object);
            try fx.assign(x.dst, try fx.fmt("klio_r_new({d}u)", .{cc.id}), .object);
            const d = try fx.reg(x.dst);
            for (x.captures, 0..) |c, i| try w.print("  klio_r_set({s}, {d}, {s});\n", .{ d, i, try fx.boxed(c) });
        },
        .FunctionRef => |x| {
            const cc = p.closureOf(x.adapter) orelse {
                p.refuse("a reference over `{s}` has no class", .{p.funcName(x.adapter)});
                return;
            };
            try fx.assign(x.dst, try fx.fmt("klio_r_new({d}u)", .{cc.id}), .object);
            if (x.bound) |bnd| try w.print("  klio_r_set({s}, 0, {s});\n", .{ try fx.reg(x.dst), try fx.boxed(bnd) });
        },
        .ClassLiteral => |x| try fx.assign(x.dst, try fx.fmt("klio_r_kclass({d}u)", .{x.class.int()}), .object),
        .ClassOf => |x| try fx.assign(x.dst, try fx.fmt("klio_r_class_value({s})", .{try fx.boxed(x.src)}), .object),
        .RInstanceOf => |x| {
            const st = fx.ty(x.src);
            if (st != .object) {
                // A scalar's class is its kind's: the answer is known here.
                const is = if (scalarClass(p, st)) |sc| ir.resolved.isA(p.m, sc, x.class) else false;
                return fx.assign(x.dst, if (is) "1" else "0", .boolean);
            }
            try fx.assign(x.dst, try fx.fmt("klio_r_is_a({s}, {d}u, {d})", .{ try fx.reg(x.src), x.class.int(), @intFromBool(x.nullable) }), .boolean);
        },
        .RCast => |x| {
            const expr = try fx.fmt("klio_r_cast({s}, {d}u, {d}, {d})", .{ try fx.boxed(x.src), x.class.int(), @intFromBool(x.nullable), @intFromBool(x.safe) });
            try fx.assign(x.dst, expr, .object);
        },
        .BoxValue => |x| try fx.assign(x.dst, try fx.fmt("klio_r_box_value({s}, {d}u, {d}u)", .{ try fx.boxed(x.src), x.class.int(), x.slot }), .object),
        .UnboxValue => |x| try fx.assign(x.dst, try fx.fmt("klio_r_unbox_value({s}, {d}u, {d}u)", .{ try fx.boxed(x.src), x.class.int(), x.slot }), .object),
        .ArrayGet => |x| try fx.assign(x.dst, try fx.fmt("klio_r_array_get({s}, {s})", .{ try fx.boxed(x.array), try fx.as(x.index, .i32) }), .object),
        .ArraySet => |x| try w.print("  klio_r_array_set({s}, {s}, {s});\n", .{ try fx.boxed(x.array), try fx.as(x.index, .i32), try fx.boxed(x.value) }),
        .IterOpen => |x| try fx.assign(x.dst, try fx.fmt("klio_r_iter_open({s})", .{try fx.boxed(x.src)}), .object),
        .IterHas => |x| try fx.assign(x.dst, try fx.fmt("klio_r_iter_has({s}, {s}, {s})", .{ try fx.boxed(x.src), try fx.as(x.idx, .i32), try fx.boxed(x.stamp) }), .boolean),
        .IterGet => |x| try fx.assign(x.dst, try fx.fmt("klio_r_iter_get({s}, {s}, {s})", .{ try fx.boxed(x.src), try fx.as(x.idx, .i32), try fx.boxed(x.stamp) }), .object),
        .NewArray => |x| {
            const arr = try fx.argArray(x.args, x.n_args, 0);
            try fx.assign(x.dst, try fx.fmt("klio_r_new_array({d}u, {s}, {d})", .{ x.class.int(), arr, x.n_args }), .object);
            if (x.n_args != 0) try w.writeAll("  }\n");
        },
        .NotNullAssert => |x| {
            if (fx.ty(x.src) == .object) try w.print("  if (klio_nat_is_null({s})) kraise({d}u, klio_nat_null());\n", .{ try fx.reg(x.src), @intFromEnum(Raise.npe) });
            try fx.assign(x.dst, try fx.reg(x.src), fx.ty(x.src));
        },
        .LateinitCheck => |x| {
            if (fx.ty(x.src) == .object) {
                const name = switch (p.m.consts.items[x.name.int()]) {
                    .String => |s| s,
                    else => "?",
                };
                const msg = try fx.fmt("lateinit property {s} has not been initialized", .{name});
                try w.print("  if (klio_nat_is_null({s})) kraise({d}u, klio_nat_string(", .{ try fx.reg(x.src), @intFromEnum(Raise.uninitialized) });
                try ctype.writeCString(w, msg);
                try w.print(", {d}));\n", .{msg.len});
            }
            try fx.assign(x.dst, try fx.reg(x.src), fx.ty(x.src));
        },
        .BinOp => |x| try writeBinOp(fx, x),
        .UnOp => |x| try writeUnOp(fx, x),
        .Not => |x| try fx.assign(x.dst, try fx.fmt("!{s}", .{try fx.as(x.src, .boolean)}), .boolean),
        else => p.refuse("`{s}`: the instruction {s}", .{ fx.b.f.fqn, @tagName(inst.*) }),
    }
}

/// The class a scalar kind's values are.
fn scalarClass(p: *const Program, t: Ty) ?ClassId {
    const h = &p.r.host_class;
    return switch (t) {
        .i32 => h.int,
        .i64 => h.long,
        .f64 => h.double,
        .f32 => h.float,
        .boolean => h.boolean,
        .char => h.char,
        .short => h.short,
        .byte => h.byte,
        .u32 => h.uint,
        .u64 => h.ulong,
        .u16 => h.ushort,
        .u8 => h.ubyte,
        .unit => h.unit,
        .object => null,
    };
}

/// Ensures the init unit behind `st` ran.
fn writeUnitTouch(fx: *Fn, st: ir.StaticId) Error!void {
    try writeUnitRun(fx, fx.p.r.statics[st.int()].unit);
}

/// Ensures init unit `unit` ran (`NONE`: none).
fn writeUnitRun(fx: *Fn, unit: u32) Error!void {
    if (unit == ir.resolved.NONE) return;
    const ui = fx.p.unitIndex(unit) orelse return;
    try fx.w.print("  if (KU[{d}] != 2) ku_{d}();\n", .{ ui, ui });
}

/// `name(args...)`, each argument converted to its parameter's kind.
fn callExpr(fx: *Fn, name: []const u8, params: []const Ty, args: Reg, n: u32) Error![]const u8 {
    var call: std.Io.Writer.Allocating = .init(fx.p.a);
    try call.writer.print("{s}(", .{name});
    var i: u32 = 0;
    // An argument past the callee's parameters is one no parameter reads.
    while (i < n and i < params.len) : (i += 1) {
        if (i != 0) try call.writer.writeAll(", ");
        try call.writer.writeAll(try fx.as(Reg.from(args.int() + i), params[i]));
    }
    // A parameter the call passes no argument for reads as `Unit`, as a
    // frame's missing parameter does in the VM.
    while (i < params.len) : (i += 1) {
        if (i != 0) try call.writer.writeAll(", ");
        try call.writer.writeAll(if (params[i] == .object) "klio_nat_box_unit()" else "0");
    }
    try call.writer.writeAll(")");
    return call.written();
}

fn writeNativeCall(fx: *Fn, n: ir.NativeId, dst: Reg, args: Reg, n_args: u32) Error!void {
    const arr = try fx.argArray(args, n_args, 0);
    try fx.assign(dst, try fx.fmt("klio_r_native_call({d}u, {s}, {d}) /* {s} */", .{ fx.p.nativeIndex(n), arr, n_args, fx.p.r.natives[n.int()].name }), .object);
    if (n_args != 0) try fx.w.writeAll("  }\n");
}

fn writeVirtualCall(fx: *Fn, slot: ir.MethodSlotId, dst: Reg, args: Reg, n: u32) Error!void {
    const root = try fx.p.sigs.of(FuncId.from(slot.int()));
    try fx.assign(dst, try callExpr(fx, try fx.fmt("kv_{d}", .{slot.int()}), root.params, args, n), root.ret);
}

fn writeBinOp(fx: *Fn, x: anytype) Error!void {
    const l = fx.ty(x.lhs);
    const r = fx.ty(x.rhs);
    const op: ir.BinOp = x.op;
    const res = typing.binResult(op, l, r);
    if (try scalarBinOp(fx, op, x.dst, x.lhs, x.rhs, l, r, res)) return;
    // Everything else is the runtime's: its operators are the VM's.
    try fx.assign(x.dst, try fx.fmt("klio_r_binop({d}u, {s}, {s})", .{ @intFromEnum(op), try fx.boxed(x.lhs), try fx.boxed(x.rhs) }), .object);
}

/// A signed C type's unsigned twin, for arithmetic that wraps.
fn unsignedOf(t: Ty) []const u8 {
    return switch (t) {
        .i32, .u32, .char, .short, .byte, .u16, .u8, .boolean, .unit => "uint32_t",
        .i64, .u64 => "uint64_t",
        else => "",
    };
}

/// The scalar forms. False leaves the operator to the runtime.
fn scalarBinOp(fx: *Fn, op: ir.BinOp, dst: Reg, lr: Reg, rr: Reg, l: Ty, r: Ty, res: ?Ty) Error!bool {
    if (l == .object or r == .object) return false;
    const w = fx.w;
    switch (op) {
        .Add, .Sub, .Mul => {
            const t = res orelse return false;
            const cop: []const u8 = switch (op) {
                .Add => "+",
                .Sub => "-",
                else => "*",
            };
            const lv = try fx.reg(lr);
            const rv = try fx.reg(rr);
            if (t.isFloat()) {
                try fx.assign(dst, try fx.fmt("(({s}){s} {s} ({s}){s})", .{ t.cName(), lv, cop, t.cName(), rv }), t);
                return true;
            }
            if (t == .char) {
                // Char plus or minus an integer wraps to 16 bits.
                try fx.assign(dst, try fx.fmt("((uint16_t)((uint32_t)(int64_t){s} {s} (uint32_t)(int64_t){s}))", .{ lv, cop, rv }), .char);
                return true;
            }
            if (l == .char and r == .char) {
                try fx.assign(dst, try fx.fmt("((int32_t){s} - (int32_t){s})", .{ lv, rv }), .i32);
                return true;
            }
            const u = unsignedOf(t);
            try fx.assign(dst, try fx.fmt("(({s})(({s})({s}){s} {s} ({s})({s}){s}))", .{ t.cName(), u, t.cName(), lv, cop, u, t.cName(), rv }), t);
            return true;
        },
        .Div, .Mod => {
            const t = res orelse return false;
            const lv = try fx.as(lr, t);
            const rv = try fx.as(rr, t);
            if (t.isFloat()) {
                if (op == .Div) {
                    try fx.assign(dst, try fx.fmt("({s} / {s})", .{ lv, rv }), t);
                } else {
                    try fx.assign(dst, try fx.fmt("{s}({s}, {s})", .{ if (t == .f32) "fmodf" else "fmod", lv, rv }), t);
                }
                return true;
            }
            if (t == .char) return false;
            try w.print("  if ({s} == 0) kraise({d}u, klio_nat_string(\"/ by zero\", 9));\n", .{ rv, @intFromEnum(Raise.arithmetic) });
            if (t.isUnsigned()) {
                try fx.assign(dst, try fx.fmt("({s} {s} {s})", .{ lv, if (op == .Div) "/" else "%", rv }), t);
                return true;
            }
            // The one overflowing quotient wraps, and its remainder is 0.
            const min = if (t == .i64) "INT64_MIN" else "INT32_MIN";
            if (op == .Div) {
                try fx.assign(dst, try fx.fmt("(({s} == -1 && {s} == {s}) ? {s} : {s} / {s})", .{ rv, lv, min, min, lv, rv }), t);
            } else {
                try fx.assign(dst, try fx.fmt("({s} == -1 ? ({s})0 : {s} % {s})", .{ rv, t.cName(), lv, rv }), t);
            }
            return true;
        },
        .Less, .LessEq, .Greater, .GreaterEq => {
            const common = compareKind(l, r) orelse return false;
            // A value against itself: C calls the comparison tautological,
            // and only a floating NaN is not ordered with itself.
            if (lr == rr) {
                const strict = op == .Less or op == .Greater;
                const expr = if (strict) "0" else if (common.isFloat()) try fx.fmt("(!isnan({s}))", .{try fx.reg(lr)}) else "1";
                try fx.assign(dst, expr, .boolean);
                return true;
            }
            const cop: []const u8 = switch (op) {
                .Less => "<",
                .LessEq => "<=",
                .Greater => ">",
                else => ">=",
            };
            try fx.assign(dst, try fx.fmt("({s} {s} {s})", .{ try castTo(fx, lr, common), cop, try castTo(fx, rr, common) }), .boolean);
            return true;
        },
        .Eq, .NotEq => {
            // Floating equality follows the VM's rule; the runtime has it.
            if (l.isFloat() or r.isFloat()) return false;
            const common = compareKind(l, r) orelse return false;
            if (lr == rr) {
                try fx.assign(dst, if (op == .Eq) "1" else "0", .boolean);
                return true;
            }
            try fx.assign(dst, try fx.fmt("({s} {s} {s})", .{ try castTo(fx, lr, common), if (op == .Eq) "==" else "!=", try castTo(fx, rr, common) }), .boolean);
            return true;
        },
        .BoxedEq, .BoxedNotEq => {
            if (l != r or l.isFloat()) return false;
            if (lr == rr) {
                try fx.assign(dst, if (op == .BoxedEq) "1" else "0", .boolean);
                return true;
            }
            try fx.assign(dst, try fx.fmt("({s} {s} {s})", .{ try fx.reg(lr), if (op == .BoxedEq) "==" else "!=", try fx.reg(rr) }), .boolean);
            return true;
        },
        .And, .Or, .Xor => {
            const t = res orelse return false;
            const cop: []const u8 = switch (op) {
                .And => "&",
                .Or => "|",
                else => "^",
            };
            try fx.assign(dst, try fx.fmt("(({s})({s} {s} {s}))", .{ t.cName(), try fx.as(lr, t), cop, try fx.as(rr, t) }), t);
            return true;
        },
        .Shl, .Shr, .UShr => {
            const t = res orelse return false;
            const wide = t == .i64 or t == .u64;
            const mask: u32 = if (wide) 63 else 31;
            const u = unsignedOf(t);
            const lv = try fx.reg(lr);
            const sh = try fx.fmt("((uint32_t){s} & {d}u)", .{ try fx.as(rr, .i32), mask });
            const expr = switch (op) {
                .Shl => try fx.fmt("(({s})(({s}){s} << {s}))", .{ t.cName(), u, lv, sh }),
                .UShr => try fx.fmt("(({s})(({s}){s} >> {s}))", .{ t.cName(), u, lv, sh }),
                else => if (t.isUnsigned())
                    try fx.fmt("(({s})({s} >> {s}))", .{ t.cName(), lv, sh })
                else
                    // Arithmetic shift without relying on the implementation's.
                    try fx.fmt("(({s})({s} < 0 ? ~(~({s}){s} >> {s}) : ({s}){s} >> {s}))", .{ t.cName(), lv, u, lv, sh, u, lv, sh }),
            };
            try fx.assign(dst, expr, t);
            return true;
        },
        .StringConcat => {
            try fx.assign(dst, try fx.fmt("klio_r_concat({s}, {s})", .{ try fx.boxed(lr), try fx.boxed(rr) }), .object);
            return true;
        },
        else => return false,
    }
}

/// The kind two scalars compare in, or null when C cannot compare them
/// as Kotlin does.
fn compareKind(l: Ty, r: Ty) ?Ty {
    if (l == r) return if (l == .unit) null else l;
    if (l.isFloat() or r.isFloat()) {
        if (!l.isNumeric() or !r.isNumeric()) return null;
        return .f64;
    }
    if (l.isUnsigned() or r.isUnsigned()) {
        if (!l.isUnsigned() or !r.isUnsigned()) return null;
        return .u64;
    }
    const signed = [_]Ty{ .i32, .i64, .short, .byte };
    const li = for (signed) |s| {
        if (s == l) break true;
    } else false;
    const ri = for (signed) |s| {
        if (s == r) break true;
    } else false;
    if (li and ri) return .i64;
    return null;
}

fn castTo(fx: *Fn, r: Reg, t: Ty) Error![]const u8 {
    if (fx.ty(r) == t) return fx.reg(r);
    return fx.fmt("(({s}){s})", .{ t.cName(), try fx.reg(r) });
}

fn writeUnOp(fx: *Fn, x: anytype) Error!void {
    const t = fx.ty(x.operand);
    const res = typing.unResult(x.op, t) orelse {
        try fx.assign(x.dst, try fx.fmt("klio_r_unop({d}u, {s})", .{ @intFromEnum(x.op), try fx.boxed(x.operand) }), .object);
        return;
    };
    const v = try fx.reg(x.operand);
    const expr = switch (x.op) {
        .Plus => try fx.fmt("(({s}){s})", .{ res.cName(), v }),
        .Neg => if (res.isFloat())
            try fx.fmt("(-{s})", .{v})
        else
            try fx.fmt("(({s})(0u - ({s})({s}){s}))", .{ res.cName(), unsignedOf(res), res.cName(), v }),
        .Inc, .Dec => if (res.isFloat())
            try fx.fmt("({s} {s} 1)", .{ v, if (x.op == .Inc) "+" else "-" })
        else
            try fx.fmt("(({s})(({s}){s} {s} 1u))", .{ res.cName(), unsignedOf(res), v, if (x.op == .Inc) "+" else "-" }),
        // An integer keeps its low bits, through the unsigned type of the
        // result's width.
        .ToByte, .ToShort, .ToInt, .ToLong, .ToChar => try fx.fmt("(({s})({s}){s})", .{ res.cName(), unsignedOf(res), v }),
        .ToFloat, .ToDouble => try fx.fmt("(({s}){s})", .{ res.cName(), v }),
        .Inv => try fx.fmt("(({s})(~{s}))", .{ res.cName(), v }),
        // `typing.unResult` leaves these to the runtime.
        .ToRawBits, .ToBits, .FloatFromBits, .DoubleFromBits, .CountTrailingZeroBits, .UIntToFloat, .UIntToDouble, .ULongToFloat, .ULongToDouble, .Sin, .Cos, .Sqrt, .ToULong, .ToUInt, .ToUShort, .ToUByte, .UnsignedBits => unreachable,
    };
    try fx.assign(x.dst, expr, res);
}
