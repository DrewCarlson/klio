//! Names, prototypes, literals and expression rendering: what a declaration
//! looks like in the emitted C, and how a value is written into it.
const std = @import("std");
const ir = @import("ir");
const Func = ir.Func;
const Module = ir.Module;
const cgen = @import("../cgen.zig");

const ClassLayout = cgen.ClassLayout;
const Compiled = cgen.Compiled;
const Error = cgen.Error;
const Program = cgen.Program;
const Ty = cgen.Ty;
const funcRetTy2 = cgen.funcRetTy2;
const no = cgen.no;
const paramTy = cgen.paramTy;
const toStringOf = cgen.toStringOf;
const tyOf = cgen.tyOf;

/// A C identifier for the function. Derived from the fqn, never from the id:
/// ids are not stable across bakes, and a name that moves between builds would
/// silently link the wrong body.
/// A name as a C identifier fragment: the same escaping `writeSymbol` uses,
/// so two names that differ anywhere differ here too.
pub fn mangleName(name: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    for (name) |ch| {
        if (std.ascii.isAlphanumeric(ch)) {
            if (n + 1 > buf.len) break;
            buf[n] = ch;
            n += 1;
        } else {
            if (n + 3 > buf.len) break;
            _ = std.fmt.bufPrint(buf[n..], "_{x:0>2}", .{ch}) catch break;
            n += 3;
        }
    }
    return buf[0..n];
}

pub fn writeSymbol(w: *std.Io.Writer, f: *const Func) !void {
    try w.writeAll("kc_");
    for (f.fqn) |ch| {
        if (std.ascii.isAlphanumeric(ch)) {
            try w.writeByte(ch);
        } else {
            try w.print("_{x:0>2}", .{ch});
        }
    }
    // The fqn alone is not unique: every lambda is named `<lambda>`. The id
    // distinguishes them, and only has to hold within this one file.
    try w.print("_{d}", .{f.id.int()});
}

/// A scalar as a `klio_value`, for the moment it crosses into the object world.
/// A class's own constructor parameter types, as the emitted initializer
/// declares them.
pub fn ctorParamTy(c: *const ir.Class, i: usize) Ty {
    return tyOf(c.primary_params[i].ty) orelse .object;
}

/// The thunk that fills a primary-constructor parameter a construction omits.
pub fn ctorDefault(layouts: []const ClassLayout, c: *const ir.Class, idx: usize) ?ir.FuncId {
    const l = layoutFor(layouts, c) orelse return null;
    if (idx >= l.ctor_defaults.len) return null;
    return l.ctor_defaults[idx];
}

/// The declarations a class contributes itself: its body properties in source
/// order and the init blocks between them. The table is keyed by whatever name
/// the built module used — the FQN for a class in a package, the simple name
/// for one without — so a lookup has to accept either.
pub fn ownLayout(prog: Program, name: []const u8) ?*const ClassLayout {
    for (prog.layouts) |*l| {
        if (std.mem.eql(u8, l.name, name)) return l;
    }
    return null;
}

pub fn layoutFor(layouts: []const ClassLayout, c: *const ir.Class) ?*const ClassLayout {
    for (layouts) |*l| {
        if (std.mem.eql(u8, l.name, c.name) or std.mem.eql(u8, l.name, c.fqn)) return l;
    }
    return null;
}

/// The prototype of a class's initializer. It fills an instance the caller has
/// already allocated, which is what lets a subclass hand its own instance to
/// the superclass's initializer rather than building a second one.
pub fn writeCtorProto(w: *std.Io.Writer, m: *const Module, cid: u32) !void {
    const c = &m.classes.items[cid];
    try w.print("static void kinit_{d}(klio_value self", .{cid});
    for (c.primary_params, 0..) |_, i| {
        try w.print(", {s} p{d}", .{ ctorParamTy(c, i).cName(), i });
    }
    try w.writeAll(")");
}

/// One call to a thunk the class table carries: a superclass-argument thunk
/// reads the constructor's parameters, a body-property thunk reads the
/// instance and then the parameters.
pub fn writeThunkCall(
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    c: *const ir.Class,
    ifn: *const Func,
) !void {
    var sym: std.Io.Writer.Allocating = .init(gpa);
    defer sym.deinit();
    try writeSymbol(&sym.writer, ifn);
    try out.print("{s}(", .{sym.written()});
    var first = true;
    if (ifn.has_receiver_param) {
        try out.writeAll("self");
        first = false;
    }
    for (c.primary_params, 0..) |_, i| {
        if (!first) try out.writeAll(", ");
        first = false;
        const have = ctorParamTy(c, i);
        const pidx = i + @as(usize, if (ifn.has_receiver_param) 1 else 0);
        // The thunk's own signature decides: a parameter it declares as a
        // reference arrives boxed, whatever the constructor holds.
        const want: Ty = if (pidx < ifn.params.len) (tyOf(ifn.params[pidx].ty) orelse .object) else have;
        var nb: [16]u8 = undefined;
        const arg = std.fmt.bufPrint(&nb, "p{d}", .{i}) catch unreachable;
        var bx: [64]u8 = undefined;
        if (want == .object and have != .object) {
            try out.print("{s}", .{boxExpr(have, arg, &bx)});
        } else {
            try out.print("{s}", .{arg});
        }
    }
    try out.writeAll(")");
}

/// A class's initializer: the superclass's fields first, through its own
/// initializer, then the fields this class declares.
pub fn writeCtorBody(
    gpa: std.mem.Allocator,
    w: *std.Io.Writer,
    m: *const Module,
    prog: Program,
    cid: u32,
) !void {
    const c = &m.classes.items[cid];
    const fields = prog.of(cid).?;
    try writeCtorProto(w, m, cid);
    try w.writeAll(" {\n");
    // A class whose fields are all filled elsewhere (an enum, whose entries
    // carry their own name and position) uses none of its arguments.
    try w.writeAll("  (void)self;");
    for (c.primary_params, 0..) |_, vi| try w.print("  (void)p{d};", .{vi});
    try w.writeAll("\n");
    if (prog.parentOf(cid)) |pp| {
        const sup = &m.classes.items[pp.cid];
        try w.print("  kinit_{d}(self", .{pp.cid});
        for (pp.args, 0..) |tf, i| {
            try w.writeAll(", ");
            const ifn = m.funcById(tf).?;
            var call: std.Io.Writer.Allocating = .init(gpa);
            defer call.deinit();
            try writeThunkCall(gpa, &call.writer, c, ifn);
            const want = ctorParamTy(sup, i);
            const have = funcRetTy2(m, ifn) orelse want;
            var bx: [320]u8 = undefined;
            if (want == .object and have != .object) {
                try w.print("{s}", .{boxExpr(have, call.written(), &bx)});
            } else {
                try w.print("{s}", .{call.written()});
            }
        }
        try w.writeAll(");\n");
    }
    // The class's own declarations run in SOURCE order: an init block sits
    // between the body properties it was written between, and Kotlin's rule is
    // that each one sees the properties declared above it and the zeros of
    // those below.
    const own = ownLayout(prog, c.name);
    const n_props: usize = if (own) |o| o.props.len else 0;
    var prop_i: usize = 0;
    var field_i: usize = 0;
    // The constructor's own properties are filled before any of it runs.
    for (fields, 0..) |fd, fi| {
        if (fd.from_parent or fd.preset) continue;
        const ai = fd.arg orelse continue;
        var bb0: [400]u8 = undefined;
        var nb0: [16]u8 = undefined;
        const arg0 = std.fmt.bufPrint(&nb0, "p{d}", .{ai}) catch unreachable;
        try w.print("  klio_nat_set(self, {d}, {s});\n", .{ fi, boxExpr(fd.ty, arg0, &bb0) });
        field_i = fi + 1;
    }
    while (prop_i <= n_props) : (prop_i += 1) {
        if (own) |o| {
            for (o.init_blocks, 0..) |ibf, ib_i| {
                const at: usize = if (ib_i < o.init_block_positions.len) o.init_block_positions[ib_i] else n_props;
                if (at != prop_i) continue;
                const ibn = m.funcById(ibf) orelse continue;
                var icall: std.Io.Writer.Allocating = .init(gpa);
                defer icall.deinit();
                try writeThunkCall(gpa, &icall.writer, c, ibn);
                try w.print("  {s};\n", .{icall.written()});
            }
        }
        if (prop_i == n_props) break;
        // The field this declaration contributes, when it has one.
        const want_name = if (own) |o| o.props[prop_i].name else "";
        var fi2: ?usize = null;
        for (fields, 0..) |fd2, k| {
            if (fd2.from_parent or fd2.preset or fd2.arg != null) continue;
            if (!std.mem.eql(u8, fd2.name, want_name)) continue;
            fi2 = k;
        }
        const fi3 = fi2 orelse continue;
        const fd = fields[fi3];
        var bb: [400]u8 = undefined;
        const ifid = fd.init orelse {
            // A declared non-nullable primitive with no initializer starts at
            // its type's zero, which is what the interpreter stores.
            const z = if (fd.ty == .object) "klio_nat_null()" else boxExpr(fd.ty, "0", &bb);
            try w.print("  klio_nat_set(self, {d}, {s});\n", .{ fi3, z });
            continue;
        };
        const ifn = m.funcById(ifid).?;
        var call: std.Io.Writer.Allocating = .init(gpa);
        defer call.deinit();
        try writeThunkCall(gpa, &call.writer, c, ifn);
        try w.print("  klio_nat_set(self, {d}, {s});\n", .{ fi3, boxExpr(fd.ty, call.written(), &bb) });
    }
    try w.writeAll("}\n");
}

/// A register as a `klio_value` ready to be rendered: a value whose class
/// declares `toString` renders as what that returns, which is what Kotlin
/// means by printing it.
pub fn renderExpr(
    gpa: std.mem.Allocator,
    m: *const Module,
    prog: Program,
    c: *const Compiled,
    reg: u32,
    out: *std.Io.Writer.Allocating,
) !void {
    var rb: [32]u8 = undefined;
    const name = regName(c, reg, &rb);
    if (c.types[reg] == .object) {
        if (c.cls[reg]) |rc| {
            if (toStringOf(m, prog, rc)) |ts| {
                try out.writer.print("kvirt_{d}({s})", .{ ts.id.int(), name });
                return;
            }
        }
    }
    var bb: [96]u8 = undefined;
    try out.writer.print("{s}", .{boxExpr(c.types[reg], name, &bb)});
    _ = gpa;
}

/// The runtime entry that boxes a machine type, or an empty name when the
/// value is already a reference.
/// A field's declared type as the runtime's zero-kind byte.
pub fn zeroKindOf(t: Ty) u8 {
    return switch (t) {
        .object, .unit => 0,
        .i32 => 1,
        .i64 => 2,
        .f64 => 3,
        .f32 => 4,
        .boolean => 5,
        .char => 6,
        .short => 7,
        .byte => 8,
        .u32 => 9,
        .u64 => 10,
        .u16 => 11,
        .u8 => 12,
    };
}

pub fn boxFnName(t: Ty) []const u8 {
    return switch (t) {
        .i32 => "klio_nat_box_int",
        .i64 => "klio_nat_box_long",
        .f64 => "klio_nat_box_double",
        .f32 => "klio_nat_box_float",
        .boolean => "klio_nat_box_bool",
        .char => "klio_nat_box_char",
        .short => "klio_nat_box_short",
        .byte => "klio_nat_box_byte",
        .u32 => "klio_nat_box_uint",
        .u64 => "klio_nat_box_ulong",
        .u16 => "klio_nat_box_ushort",
        .u8 => "klio_nat_box_ubyte",
        .unit, .object => "",
    };
}

/// The compiled parameter type of an accepted body, which is what its C
/// signature declares. A synthesized thunk and a lambda compile against a
/// signature the emitter chose, so the declaration is not the authority.
pub fn acceptedParamTy(accepted: []const Compiled, f: *const Func, idx: usize) ?Ty {
    for (accepted) |*cc| {
        if (cc.f != f) continue;
        if (idx >= cc.params.len) return null;
        return paramTy(cc.params[idx]);
    }
    return null;
}

/// An expression of type `have` as the C type `want` needs it: a machine type
/// boxed into a reference, a reference unboxed into a machine type. The
/// lowering reuses one register for values of both shapes, and the register's
/// own type is what its C local declares, so the conversion belongs at the
/// point of use.
pub fn convExpr(have: Ty, want: Ty, expr: []const u8, buf: []u8) []const u8 {
    if (have == want) return expr;
    if (want == .object) return boxExpr(have, expr, buf);
    if (have == .object) return unboxExpr(want, expr, buf);
    return expr;
}

pub fn boxExpr(t: Ty, expr: []const u8, buf: []u8) []const u8 {
    const fname = switch (t) {
        .i32 => "klio_nat_box_int",
        .i64 => "klio_nat_box_long",
        .f64 => "klio_nat_box_double",
        .f32 => "klio_nat_box_float",
        .boolean => "klio_nat_box_bool",
        .char => "klio_nat_box_char",
        .short => "klio_nat_box_short",
        .byte => "klio_nat_box_byte",
        .u32 => "klio_nat_box_uint",
        .u64 => "klio_nat_box_ulong",
        .u16 => "klio_nat_box_ushort",
        .u8 => "klio_nat_box_ubyte",
        // Boxing a Unit result must still run what produced it: the comma
        // keeps the expression and yields the Unit value. Returning a bare
        // `klio_nat_box_unit()` dropped the call.
        .unit => return std.fmt.bufPrint(buf, "((void)({s}), klio_nat_box_unit())", .{expr}) catch unreachable,
        .object => return std.fmt.bufPrint(buf, "{s}", .{expr}) catch unreachable,
    };
    return std.fmt.bufPrint(buf, "{s}({s})", .{ fname, expr }) catch unreachable;
}

/// The reverse: a `klio_value` known to hold `t`, back in a C local.
pub fn unboxExpr(t: Ty, expr: []const u8, buf: []u8) []const u8 {
    const fname = switch (t) {
        .i32 => "klio_nat_int",
        .i64 => "klio_nat_long",
        .f64 => "klio_nat_double",
        .f32 => "klio_nat_float",
        .boolean => "klio_nat_bool",
        .char => "klio_nat_char",
        .short => "klio_nat_short",
        .byte => "klio_nat_byte",
        .u32 => "klio_nat_uint",
        .u64 => "klio_nat_ulong",
        .u16 => "klio_nat_ushort",
        .u8 => "klio_nat_ubyte",
        // A Unit result is still a result: the expression that produced it
        // has to run. The comma keeps the call and yields the Unit register's
        // zero, where returning a bare `0` dropped the call entirely.
        .unit => return std.fmt.bufPrint(buf, "((void)({s}), 0)", .{expr}) catch unreachable,
        .object => return std.fmt.bufPrint(buf, "{s}", .{expr}) catch unreachable,
    };
    return std.fmt.bufPrint(buf, "{s}({s})", .{ fname, expr }) catch unreachable;
}

/// Where a register lives: a C local for a scalar, a published frame slot for
/// a reference.
pub fn regName(c: *const Compiled, r: u32, buf: []u8) []const u8 {
    // A suspend function's registers live in a HEAP frame: the body can return
    // in the middle and be re-entered later, so nothing may sit in a C local
    // that the return would discard.
    if (c.suspends) {
        if (c.types[r] == .object) {
            return std.fmt.bufPrint(buf, "fr->ks[{d}]", .{c.slot[r]}) catch unreachable;
        }
        return std.fmt.bufPrint(buf, "fr->r{d}", .{r}) catch unreachable;
    }
    if (c.types[r] == .object) {
        return std.fmt.bufPrint(buf, "KS[{d}]", .{c.slot[r]}) catch unreachable;
    }
    return std.fmt.bufPrint(buf, "r{d}", .{r}) catch unreachable;
}

pub fn writeProto(w: *std.Io.Writer, c: *const Compiled) !void {
    // A suspend body answers either its result or the SUSPENDED marker, so its
    // C result is a value rather than the declared machine type.
    try w.print("static {s} ", .{if (c.suspends) "klio_value" else c.ret.cName()});
    try writeSymbol(w, c.f);
    try w.writeByte('(');
    if (c.params.len == 0 and c.caps.len == 0) {
        try w.writeAll("void");
    } else {
        for (c.caps, 0..) |ct, i| {
            if (i != 0) try w.writeAll(", ");
            try w.print("{s} k{d}", .{ ct.ty.cName(), i });
        }
        for (c.params, 0..) |p, i| {
            if (i != 0 or c.caps.len != 0) try w.writeAll(", ");
            try w.print("{s} p{d}", .{ paramTy(p).cName(), i });
        }
    }
    try w.writeByte(')');
}

pub fn writeConst(w: *std.Io.Writer, c: ir.Const) !void {
    switch (c) {
        .Int => |v| try w.print("INT32_C({d})", .{v}),
        .Long => |v| try w.print("INT64_C({d})", .{v}),
        .Bool => |v| try w.print("{d}", .{@intFromBool(v)}),
        .Char => |v| try w.print("{d}u", .{v}),
        .Short => |v| try w.print("{d}", .{v}),
        .Byte => |v| try w.print("{d}", .{v}),
        .UInt => |v| try w.print("UINT32_C({d})", .{v}),
        .ULong => |v| try w.print("UINT64_C({d})", .{v}),
        .UShort => |v| try w.print("((uint16_t){d}u)", .{v}),
        .UByte => |v| try w.print("((uint8_t){d}u)", .{v}),
        .Unit => try w.writeAll("0"),
        .Double => |v| try writeFloatLit(w, v, false),
        .Float => |v| try writeFloatLit(w, v, true),
        else => unreachable,
    }
}

/// A C string literal for arbitrary bytes. The source may hold anything,
/// including embedded NULs and invalid UTF-8, so every byte outside the plain
/// printable range is escaped numerically rather than passed through.
pub fn emitCLiteral(w: *std.Io.Writer, bytes: []const u8) !void {
    try w.writeByte('"');
    for (bytes) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            0x20...0x21, 0x23...0x5B, 0x5D...0x7E => try w.writeByte(ch),
            else => try w.print("\\{o:0>3}", .{ch}),
        }
    }
    try w.writeByte('"');
}

/// A C floating literal for `v`. The shortest round-trip decimal is exact, but
/// it can come out with no decimal point at all (1e20 formats as
/// "100000000000000000000"), which C reads as an integer literal too large for
/// any integer type. A literal that carries neither a point nor an exponent
/// gets ".0" so it stays a double.
pub fn writeFloatLit(w: *std.Io.Writer, v: f64, is_f32: bool) !void {
    if (std.math.isNan(v)) {
        try w.print("(({s})NAN)", .{if (is_f32) "float" else "double"});
        return;
    }
    if (std.math.isInf(v)) {
        try w.print("(({s}{s})INFINITY)", .{ if (v < 0) "-" else "", if (is_f32) "float" else "double" });
        return;
    }
    // Scientific form, because plain decimal is neither always short (a
    // denormal expands to three hundred digits) nor always a float literal
    // (1e20 comes out as "100000000000000000000", which C reads as an integer
    // too large for any type). The shortest form that round-trips is exact.
    var buf: [64]u8 = undefined;
    const txt = std.fmt.bufPrint(&buf, "{e}", .{v}) catch return error.WriteFailed;
    try w.writeAll(txt);
    if (std.mem.indexOfAny(u8, txt, ".eE") == null) try w.writeAll(".0");
    if (is_f32) try w.writeByte('f');
}

/// Integer division and remainder by zero throw in Kotlin; C makes them
/// undefined. The emitted body traps explicitly so a compiled program reports
/// the same failure rather than executing nonsense.
pub fn writeDivGuard(w: *std.Io.Writer, rhs: u32) !void {
    try w.print("  if (r{d} == 0) klio_arith_zero();\n", .{rhs});
}

/// Blocks some terminator can actually reach. Every emitted block ends in an
/// explicit `goto`/`return`, so nothing falls through and a block no edge names
/// is dead: emitting it would only leave the C compiler warning about a label
/// nothing jumps to.
/// The `i`th block control can reach from this one: its handlers first, then
/// wherever its terminator goes. Null once they are exhausted.
pub fn succOf(f: *const Func, blk: *const ir.Block, i: u32) ?u32 {
    _ = f;
    if (i < blk.catches.len) return blk.catches[i].handler.int();
    const k = i - @as(u32, @intCast(blk.catches.len));
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

/// The reachable blocks in reverse postorder from the entry. Catch handlers
/// are reached by a throw rather than a terminator, so they are edges too.
pub fn blockOrder(gpa: std.mem.Allocator, f: *const Func) Error![]u32 {
    const n = f.blocks.len;
    var post: std.ArrayList(u32) = .empty;
    errdefer post.deinit(gpa);
    const seen = try gpa.alloc(bool, n);
    defer gpa.free(seen);
    @memset(seen, false);
    // An explicit stack: a deeply nested function would otherwise recurse as
    // deep as it has blocks.
    const Frame = struct { bi: u32, next: u32 };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(gpa);
    if (n == 0) return try post.toOwnedSlice(gpa);
    seen[0] = true;
    try stack.append(gpa, .{ .bi = 0, .next = 0 });
    while (stack.items.len != 0) {
        const top = &stack.items[stack.items.len - 1];
        const blk = &f.blocks[top.bi];
        if (succOf(f, blk, top.next)) |s2| {
            top.next += 1;
            if (s2 < n and !seen[s2]) {
                seen[s2] = true;
                try stack.append(gpa, .{ .bi = s2, .next = 0 });
            }
            continue;
        }
        try post.append(gpa, top.bi);
        _ = stack.pop();
    }
    const out = try post.toOwnedSlice(gpa);
    std.mem.reverse(u32, out);
    return out;
}

pub fn reachableBlocks(gpa: std.mem.Allocator, f: *const Func) Error![]bool {
    const hit = try gpa.alloc(bool, f.blocks.len);
    @memset(hit, false);
    if (f.blocks.len != 0) hit[0] = true;
    var grew = true;
    while (grew) {
        grew = false;
        for (f.blocks, 0..) |*blk, bi| {
            if (!hit[bi]) continue;
            // A handler is reached by a throw, not by any terminator: without
            // this edge the block it jumps to looks dead and is dropped.
            for (blk.catches) |h| {
                if (h.handler.int() < hit.len and !hit[h.handler.int()]) {
                    hit[h.handler.int()] = true;
                    grew = true;
                }
            }
            switch (blk.terminator) {
                .Goto => |g| {
                    if (g.int() < hit.len and !hit[g.int()]) {
                        hit[g.int()] = true;
                        grew = true;
                    }
                },
                .Branch => |br| {
                    for ([_]u32{ br.t.int(), br.f.int() }) |t| {
                        if (t < hit.len and !hit[t]) {
                            hit[t] = true;
                            grew = true;
                        }
                    }
                },
                else => {},
            }
        }
    }
    return hit;
}

/// The type a body the emitter accepted actually returns, which is what its C
/// signature says. The DECLARED return type is not the authority: a thunk the
/// lowering synthesized carries a placeholder.
pub fn acceptedRet(accepted: []const Compiled, f: *const Func) ?Ty {
    for (accepted) |*cc| {
        if (cc.f == f) return cc.ret;
    }
    return null;
}

/// The suspending calls in a body, in emission order. Each is a point the
/// function can return from and be re-entered at, so each gets a state number
/// and a resume label.
pub fn suspendPoints(gpa: std.mem.Allocator, m: *const Module, f: *const Func, live: []const bool) Error![]const *const ir.Inst {
    var out: std.ArrayList(*const ir.Inst) = .empty;
    errdefer out.deinit(gpa);
    for (f.blocks, 0..) |*blk, bi| {
        if (!live[bi]) continue;
        for (blk.insts) |*inst| {
            if (!isSuspendingCall(m, inst)) continue;
            try out.append(gpa, inst);
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Whether a body has to compile as a state machine: it is declared
/// `suspend`, or it calls something that is.
pub fn bodySuspends(m: *const Module, f: *const Func) bool {
    if (f.is_suspend) return true;
    for (f.blocks) |*blk| {
        for (blk.insts) |*inst| {
            if (isSuspendingCall(m, inst)) return true;
        }
    }
    return false;
}

pub fn isSuspendingCall(m: *const Module, inst: *const ir.Inst) bool {
    return switch (inst.*) {
        .Call => |cl| blk: {
            const callee = m.funcById(cl.func) orelse break :blk false;
            break :blk callee.is_suspend;
        },
        else => false,
    };
}

pub fn suspendIndex(points: []const *const ir.Inst, inst: *const ir.Inst) ?u32 {
    for (points, 0..) |p, i| {
        if (p == inst) return @intCast(i);
    }
    return null;
}
