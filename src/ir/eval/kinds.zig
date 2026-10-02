//! Register kinds for the baseline JIT (`plans/jit.md`, `jit/types`): for
//! each op of a function's streams, the tag each register holds whenever the
//! op runs, where every path to it through the function's ops agrees. A
//! path counts whether its ops run compiled or in their handlers, since both
//! write what the op's semantics make. Compiled code entered at an op from
//! outside (a handler's dispatch, the frame loop) checks the kinds the op's
//! code relies on before it runs; so a kind only has to hold on the paths
//! compiled code takes to the op, and a write this pass does not see (a
//! catch's exception, a resume) meets a check.

const std = @import("std");
const runtime = @import("runtime");

const ir = @import("../ir.zig");
const bc = ir.bc;

const Op = bc.Op;
const Value = runtime.Value;
pub const Tag = std.meta.Tag(Value);

/// A register's kind at an op: a value tag, or one of these.
pub const Kind = u8;
/// Paths to the op disagree, or a write's tag is not known.
pub const unknown: Kind = 0xff;
/// No path this pass follows reaches the op.
pub const unreached: Kind = 0xfe;
/// Some path to the op has not written the register since the function's
/// frame opened.
pub const unwritten: Kind = 0xfd;

pub fn of(t: Tag) Kind {
    return @intFromEnum(t);
}

/// An instance known more of than its tag: that it has at least a number of
/// slots, up to `max_fact_slots`, and whether its slots are plain
/// (`runtime.PLAIN_SLOTS`), both fixed when it is made. What a field
/// access's checks leave known of its receiver, and a `new` from a template
/// of what it makes.
const inst_fact: Kind = 0x80;
const fact_plain: Kind = 0x20;
pub const max_fact_slots: u32 = 0x1f;

comptime {
    std.debug.assert(@typeInfo(Tag).@"enum".fields.len < inst_fact);
}

/// The kind of an instance with at least `slots` slots and, when `plain`, plain ones.
pub fn instFact(slots: usize, plain: bool) Kind {
    const s: Kind = @intCast(@min(slots, max_fact_slots));
    if (s == 0 and !plain) return of(.Instance);
    return inst_fact | (if (plain) fact_plain else 0) | s;
}

pub fn isInstFact(k: Kind) bool {
    return k >= inst_fact and k < inst_fact + 2 * fact_plain;
}

/// The slots an instance of kind `k` is known to have.
pub fn factSlots(k: Kind) u32 {
    return if (isInstFact(k)) k & max_fact_slots else 0;
}

/// Whether an instance of kind `k` is known to have plain slots.
pub fn factPlain(k: Kind) bool {
    return isInstFact(k) and k & fact_plain != 0;
}

/// The tag kind `k` is, if it is one.
pub fn tagOf(k: Kind) ?Tag {
    if (k >= unwritten) return null;
    if (isInstFact(k)) return .Instance;
    return @enumFromInt(k);
}

fn meet(a: Kind, b: Kind) Kind {
    if (a == unreached) return b;
    if (b == unreached) return a;
    if (a == unwritten or b == unwritten) return unwritten;
    if (a == b) return a;
    // Two instances: what both are known to be.
    if (tagOf(a) == .Instance and tagOf(b) == .Instance) return instFact(@min(factSlots(a), factSlots(b)), factPlain(a) and factPlain(b));
    return unknown;
}

/// Register kind `k` once an access to slot `slot` of the instance it holds has passed
/// its checks: an instance with more than `slot` slots.
fn accessed(k: Kind, slot: u32) Kind {
    if (k == unwritten or k == unreached) return k;
    return instFact(@max(factSlots(k), slot + 1), factPlain(k));
}

/// The kinds of a function's registers at each of its ops.
pub const Kinds = struct {
    n: u32,
    /// The module the function runs in, whose tables say what a `new` makes.
    module: ?*const ir.Module = null,
    /// Per code word: the index into `rows` of the op starting there, or
    /// `no_row`.
    row_of: []u32,
    /// `n` kinds per op.
    rows: []Kind,

    pub const no_row = std.math.maxInt(u32);

    /// The kinds at the op at `pc`, or null for a pc that starts no op.
    pub fn at(self: *const Kinds, pc: usize) ?[]const Kind {
        if (pc >= self.row_of.len or self.row_of[pc] == no_row) return null;
        const r = self.row_of[pc];
        return self.rows[r * self.n ..][0..self.n];
    }

    /// Register `reg`'s kind at the op at `pc`.
    pub fn kindAt(self: *const Kinds, pc: usize, reg: u32) Kind {
        const row = self.at(pc) orelse return unknown;
        if (reg >= row.len) return unknown;
        const k = row[reg];
        return if (k >= unwritten) unknown else k;
    }

    /// The kinds after the op at `pc`, in block `bi`, runs: its row with its writes, into
    /// `buf` (`n` long). Null for a pc that starts no op.
    pub fn after(self: *const Kinds, fs: *const bc.FuncStreams, bi: u32, pc: usize, buf: []Kind) ?[]Kind {
        const row = self.at(pc) orelse return null;
        @memcpy(buf, row);
        var succ: [2]u32 = undefined;
        _ = step(fs, .{ .module = self.module }, bi, fs.opAt(pc), pc, buf, &succ);
        return buf;
    }

    /// Whether every path to the op at `pc` has written register `reg`.
    pub fn written(self: *const Kinds, pc: usize, reg: u32) bool {
        const row = self.at(pc) orelse return false;
        if (reg >= row.len) return false;
        return row[reg] < unwritten;
    }
};

/// The kinds of `fs`'s registers at each of its ops, allocated in `a`.
pub fn analyze(a: std.mem.Allocator, fs: *const bc.FuncStreams, module: ?*const ir.Module) std.mem.Allocator.Error!Kinds {
    return analyzeWith(a, fs, null, module);
}

/// `analyze` for a callee compiled in place of its call: parameter `i` loads
/// `params[i]`, the kind its call's argument register has there, and `unknown`
/// past them, as the callee's parameter load copies the argument unchecked.
pub fn analyzeWith(a: std.mem.Allocator, fs: *const bc.FuncStreams, params: ?[]const Kind, module: ?*const ir.Module) std.mem.Allocator.Error!Kinds {
    const n = fs.func.n_locals;
    const code = fs.code;
    const row_of = try a.alloc(u32, code.len);
    @memset(row_of, Kinds.no_row);
    var n_ops: u32 = 0;
    for (fs.blocks) |b| {
        var pc: usize = b.enter;
        while (pc <= b.end) {
            const op = fs.opAt(pc);
            row_of[pc] = n_ops;
            n_ops += 1;
            pc += bc.opLen(op, code, pc);
        }
    }
    const rows = try a.alloc(Kind, @as(usize, n_ops) * n);
    @memset(rows, unreached);
    const out: Kinds = .{ .n = n, .module = module, .row_of = row_of, .rows = rows };
    const nb = fs.blocks.len;
    // Per block: its entry's kinds, and whether it waits to be walked.
    const entry = try a.alloc(Kind, nb * n);
    defer a.free(entry);
    @memset(entry, unreached);
    const queued = try a.alloc(bool, nb);
    defer a.free(queued);
    @memset(queued, false);
    var work: std.ArrayList(u32) = .empty;
    defer work.deinit(a);
    // Nothing is known of a register before the function writes it; a catch's or a
    // finally's block is entered from wherever its region threw or left, so nothing is
    // known there either.
    const start = fs.func.entry.int();
    const entries = try a.alloc(bool, nb);
    defer a.free(entries);
    @memset(entries, false);
    if (start < nb) entries[start] = true;
    for (fs.func.blocks) |*blk| {
        const hs = blk.h();
        for (hs.catches) |ch| if (ch.handler.int() < nb) {
            entries[ch.handler.int()] = true;
        };
        if (hs.finally) |f| if (f.int() < nb) {
            entries[f.int()] = true;
        };
        if (hs.finally_done) |f| if (f.int() < nb) {
            entries[f.int()] = true;
        };
    }
    for (entries, 0..) |e, bi| if (e) {
        @memset(entry[bi * n ..][0..n], unwritten);
        try work.append(a, @intCast(bi));
        queued[bi] = true;
    };
    const state = try a.alloc(Kind, n);
    defer a.free(state);
    while (work.pop()) |bi| {
        queued[bi] = false;
        @memcpy(state, entry[bi * n ..][0..n]);
        const b = fs.blocks[bi];
        var pc: usize = b.enter;
        while (pc <= b.end) {
            const op = fs.opAt(pc);
            const row = out.rows[row_of[pc] * n ..][0..n];
            for (row, state) |*r, s| r.* = meet(r.*, s);
            @memcpy(state, row);
            var succ: [2]u32 = undefined;
            const targets = step(fs, .{ .params = params, .module = module }, bi, op, pc, state, &succ);
            for (targets) |t| {
                if (t >= nb) continue;
                const e = entry[t * n ..][0..n];
                var changed = false;
                for (e, state) |*x, s| {
                    const m = meet(x.*, s);
                    if (m != x.*) {
                        x.* = m;
                        changed = true;
                    }
                }
                if (changed and !queued[t]) {
                    queued[t] = true;
                    try work.append(a, t);
                }
            }
            if (endsBlock(op)) break;
            // A `bin_k` prefix's fronted op runs only from the prefix's handler, which
            // `step` took with the prefix.
            pc += bc.opLen(op, code, pc) + (if (bc.kOperator(op) != null and !isCmpBrK(op)) bc.opLen(fs.opAt(pc + 6), code, pc + 6) else 0);
        }
    }
    return out;
}

fn isCmpBrK(op: Op) bool {
    return @intFromEnum(op) >= @intFromEnum(Op.cmp_br_k_less) and @intFromEnum(op) <= @intFromEnum(Op.cmp_br_k_ident_neq);
}

/// Whether the block's ops stop at `op`: control goes on only to its targets.
fn endsBlock(op: Op) bool {
    return switch (op) {
        .jump, .goto_try, .br, .cmp_br, .ret, .ret_try, .term_exit, .end => true,
        .cmp_br_k_less, .cmp_br_k_less_eq, .cmp_br_k_greater, .cmp_br_k_greater_eq, .cmp_br_k_eq, .cmp_br_k_not_eq, .cmp_br_k_boxed_eq, .cmp_br_k_boxed_not_eq, .cmp_br_k_ident_eq, .cmp_br_k_ident_neq => true,
        else => false,
    };
}

/// Applies `op` at `pc` of block `bi` to `state`, the kinds before it, and
/// returns the blocks it goes to when it ends its block.
/// What `step` knows besides the function: its parameters' kinds, for a callee compiled in
/// place, and the module it runs in.
const StepCtx = struct {
    params: ?[]const Kind = null,
    module: ?*const ir.Module = null,
};

fn step(fs: *const bc.FuncStreams, sx: StepCtx, bi: u32, op: Op, pc: usize, state: []Kind, out: *[2]u32) []const u32 {
    const c = fs.code;
    const params = sx.params;
    const put = struct {
        fn f(s: []Kind, r: u32, k: Kind) void {
            if (r < s.len) s[r] = k;
        }
    }.f;
    const get = struct {
        fn f(s: []const Kind, r: u32) Kind {
            return if (r < s.len) s[r] else unknown;
        }
    }.f;
    switch (op) {
        .const_int => put(state, c[pc + 1], of(.Int)),
        .const_val => put(state, c[pc + 1], of(std.meta.activeTag(fs.values[c[pc + 2]]))),
        .const_str => put(state, c[pc + 1], of(.String)),
        .const_load, .cell_get, .load_capture => put(state, c[pc + 1], unknown),
        .load_param => put(state, c[pc + 1], loadedParam(fs, params, c[pc + 2])),
        .make_cell => put(state, c[pc + 1], of(.Cell)),
        .move => put(state, c[pc + 1], get(state, c[pc + 2])),
        .load_params => for (0..c[pc + 1]) |k| put(state, c[pc + 2 + 2 * k], loadedParam(fs, params, c[pc + 3 + 2 * k])),
        .bin, .add, .sub, .cmp, .bin_mul, .bin_div, .bin_mod, .bin_and, .bin_or, .bin_xor, .bin_shl, .bin_shr, .bin_ushr, .bin_ident_eq, .bin_ident_neq => {
            const bop: ir.BinOp = @enumFromInt(c[pc + 2] & 0xff);
            put(state, c[pc + 3], binKind(bop, get(state, c[pc + 4]), get(state, c[pc + 5])));
        },
        .cmp_br => {
            put(state, c[pc + 3], of(.Bool));
            out.* = .{ c[pc + 6], c[pc + 8] };
            return out[0..2];
        },
        .bin_k_add, .bin_k_sub, .bin_k_mul, .bin_k_div, .bin_k_mod, .bin_k_less, .bin_k_less_eq, .bin_k_greater, .bin_k_greater_eq, .bin_k_eq, .bin_k_not_eq, .bin_k_boxed_eq, .bin_k_boxed_not_eq, .bin_k_and, .bin_k_or, .bin_k_xor, .bin_k_shl, .bin_k_shr, .bin_k_ushr, .bin_k_ident_eq, .bin_k_ident_neq => {
            // The prefix and the op it fronts as one (`analyze` goes on past both): the
            // constant's register holds its constant only where the fronted op ran.
            const kt = kTypeKind(@enumFromInt((c[pc + 1] >> 8) & 0xff));
            const bop = bc.kOperator(op).?;
            put(state, c[pc + 9], binKind(bop, get(state, c[pc + 2]), kt));
            put(state, c[pc + 3], unknown);
        },
        .cmp_br_k_less, .cmp_br_k_less_eq, .cmp_br_k_greater, .cmp_br_k_greater_eq, .cmp_br_k_eq, .cmp_br_k_not_eq, .cmp_br_k_boxed_eq, .cmp_br_k_boxed_not_eq, .cmp_br_k_ident_eq, .cmp_br_k_ident_neq => {
            put(state, c[pc + 9], of(.Bool));
            put(state, c[pc + 3], unknown);
            out.* = .{ c[pc + 12], c[pc + 14] };
            return out[0..2];
        },
        .un_inc, .un_dec => {
            // `inc` and `dec` keep every numeric type.
            const src = get(state, c[pc + 4]);
            put(state, c[pc + 3], if (numeric(src)) src else unknown);
        },
        .un_neg => {
            // A negated Byte or Short is an Int.
            const src = get(state, c[pc + 4]);
            put(state, c[pc + 3], if (src == of(.Int) or src == of(.Long) or src == of(.Double) or src == of(.Float)) src else unknown);
        },
        .fn_inv => {
            const src = get(state, c[pc + 4]);
            put(state, c[pc + 3], if (src == of(.Int) or src == of(.Long)) src else unknown);
        },
        .un => put(state, c[pc + 3], unknown),
        .conv_byte => put(state, c[pc + 3], of(.Byte)),
        .conv_short => put(state, c[pc + 3], of(.Short)),
        .conv_int => put(state, c[pc + 3], of(.Int)),
        .conv_long => put(state, c[pc + 3], of(.Long)),
        .conv_float => put(state, c[pc + 3], of(.Float)),
        .conv_double => put(state, c[pc + 3], of(.Double)),
        .conv_char => put(state, c[pc + 3], of(.Char)),
        .fn_float_from_bits => put(state, c[pc + 3], of(.Float)),
        .fn_double_from_bits => put(state, c[pc + 3], of(.Double)),
        .fn_count_trailing_zero_bits => put(state, c[pc + 3], of(.Int)),
        .fn_to_ulong => put(state, c[pc + 3], of(.ULong)),
        .fn_to_uint => put(state, c[pc + 3], of(.UInt)),
        .fn_to_ushort => put(state, c[pc + 3], of(.UShort)),
        .fn_to_ubyte => put(state, c[pc + 3], of(.UByte)),
        .fn_to_raw_bits, .fn_to_bits, .fn_uint_to_float, .fn_uint_to_double, .fn_ulong_to_float, .fn_ulong_to_double, .fn_sin, .fn_cos, .fn_sqrt, .fn_unsigned_bits => put(state, c[pc + 3], unknown),
        .not, .is => put(state, c[pc + 2], of(.Bool)),
        .not_null => {
            const src = get(state, c[pc + 3]);
            put(state, c[pc + 2], if (src == of(.Null)) unknown else src);
        },
        .get_field => {
            // On from its code, the op's receiver passed its checks; the field's value is
            // written after.
            put(state, c[pc + 3], accessed(get(state, c[pc + 3]), c[pc + 4]));
            put(state, c[pc + 2], unknown);
        },
        .set_field => put(state, c[pc + 2], accessed(get(state, c[pc + 2]), c[pc + 3])),
        .array_get, .load_object, .load_static, .cast, .box_value, .unbox_value, .iter_open, .iter_get => put(state, c[pc + 2], unknown),
        .iter_has => put(state, c[pc + 2], of(.Bool)),
        .call, .vcall, .callv, .native => put(state, c[pc + 5], unknown),
        .new => put(state, c[pc + 6], newKind(fs, sx.module, pc)),
        .cell_set => put(state, c[pc + 2], unknown),
        .escape, .make_closure, .new_array => {
            const insts = fs.func.blocks[bi].insts;
            const i = c[pc + 1];
            if (i < insts.len) if (instDst(&insts[i])) |d| put(state, d, unknown);
        },
        .array_set, .store_static, .block_entry => {},
        .jump, .goto_try => {
            out[0] = c[pc + 1];
            return out[0..1];
        },
        .br => {
            out.* = .{ c[pc + 2], c[pc + 4] };
            return out[0..2];
        },
        .ret, .ret_try => return out[0..0],
        .term_exit, .end => {
            // The block's terminator runs in the frame loop.
            return switch (fs.func.blocks[bi].terminator) {
                .Goto => |t| blk: {
                    out[0] = t.int();
                    break :blk out[0..1];
                },
                .Branch => |br| blk: {
                    out.* = .{ br.t.int(), br.f.int() };
                    break :blk out[0..2];
                },
                else => out[0..0],
            };
        },
        .jit => unreachable,
    }
    return out[0..0];
}

/// What a load of parameter `idx` gives: its call's argument's kind where the
/// callee is compiled in place (`params`), else its declared kind.
/// What `new` at `pc` makes of a class a Kotlin constructor makes: an instance with the
/// class's slots, plain where its class's are (`InstanceData.seqOf`). A throwable, and a
/// class the host makes, are other values.
fn newKind(fs: *const bc.FuncStreams, module: ?*const ir.Module, pc: usize) Kind {
    const c = fs.code;
    const mod = module orelse return unknown;
    const r = mod.resolved orelse return unknown;
    const class = c[pc + 2];
    const ctor = c[pc + 3];
    if (class >= r.classes.len) return unknown;
    const rt = &r.classes[class];
    if (rt.throwable) return unknown;
    if (ctor < r.func_native.len and r.func_native[ctor] != .none) return unknown;
    return instFact(rt.seeds.len, runtime.InstanceData.seqOf(rt.def) & runtime.PLAIN_SLOTS != 0);
}

fn loadedParam(fs: *const bc.FuncStreams, params: ?[]const Kind, idx: u32) Kind {
    const ps = params orelse return paramKind(fs.func, idx);
    return if (idx < ps.len) ps[idx] else unknown;
}

/// The kind of `func`'s parameter `idx`, when it is declared a non-null
/// primitive (`bridge.primitiveType`): the compiled load of it checks it.
pub fn paramKind(func: *const ir.Func, idx: u32) Kind {
    if (idx >= func.params.len) return unknown;
    const ty = func.params[idx].ty;
    if (ty.nullable) return unknown;
    const names = [_]struct { []const u8, Tag }{
        .{ "kotlin.Int", .Int },       .{ "kotlin.Long", .Long },     .{ "kotlin.Short", .Short },
        .{ "kotlin.Byte", .Byte },     .{ "kotlin.Float", .Float },   .{ "kotlin.Double", .Double },
        .{ "kotlin.Boolean", .Bool }, .{ "kotlin.Char", .Char },
    };
    for (names) |n| if (std.mem.eql(u8, ty.name, n[0])) return of(n[1]);
    return unknown;
}

/// The register an instruction the stream leaves to its arm writes.
fn instDst(inst: *const ir.Inst) ?u32 {
    return switch (inst.*) {
        inline else => |x| if (@TypeOf(x) != void and @hasField(@TypeOf(x), "dst")) x.dst.int() else null,
    };
}

fn numeric(k: Kind) bool {
    const t = tagOf(k) orelse return false;
    return switch (t) {
        .Int, .Long, .Double, .Float, .Short, .Byte, .UInt, .ULong, .UShort, .UByte => true,
        else => false,
    };
}

fn kTypeKind(k: bc.KType) Kind {
    return switch (k) {
        .int => of(.Int),
        .long => of(.Long),
        .float => of(.Float),
        .double => of(.Double),
        .ulong => of(.ULong),
        .uint => of(.UInt),
        .null => of(.Null),
    };
}

/// What `op` makes of operands of kinds `l` and `r`: a compare a Bool
/// whatever it compares, arithmetic its operands' kind where both have it.
fn binKind(op: ir.BinOp, l: Kind, r: Kind) Kind {
    switch (op) {
        .Eq, .NotEq, .Less, .LessEq, .Greater, .GreaterEq, .BoxedEq, .BoxedNotEq, .IdentEq, .IdentNeq => return of(.Bool),
        .Add, .Sub, .Mul, .Div, .Mod => {
            if (l != r) return unknown;
            const t = tagOf(l) orelse return unknown;
            return switch (t) {
                .Int, .Long, .Double, .Float => l,
                else => unknown,
            };
        },
        .And, .Or, .Xor => {
            if (l != r) return unknown;
            const t = tagOf(l) orelse return unknown;
            return switch (t) {
                .Int, .Long, .Bool => l,
                else => unknown,
            };
        },
        .Shl, .Shr, .UShr => {
            if (r != of(.Int)) return unknown;
            const t = tagOf(l) orelse return unknown;
            return switch (t) {
                .Int, .Long => l,
                else => unknown,
            };
        },
        else => return unknown,
    }
}

const testing = std.testing;
const hand = @import("hand.zig");

fn branchOn(cond: u32, t: u32, f: u32) ir.Terminator {
    return .{ .Branch = .{ .cond = hand.reg(cond), .t = .from(t), .f = .from(f) } };
}

fn kindsOf(a: std.mem.Allocator, h: *hand.Hand, f: ir.FuncId) !struct { *const bc.FuncStreams, Kinds } {
    const fs = bc.funcStreams(h.funcPtr(f), h.m.consts.items) orelse return error.TestUnexpectedResult;
    return .{ fs, try analyze(a, fs, null) };
}

test "a loop's counter and accumulator keep their kinds around the back edge" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try hand.Hand.init(a);
    const zero = try h.constant(.{ .Int = 0 });
    const one = try h.constant(.{ .Int = 1 });
    const zero_l = try h.constant(.{ .Long = 0 });
    // var i = 0; var acc = 0L; while (i < n) { acc = acc + i.toLong(); i = i + 1 }; return acc
    const f = try h.func("sum", 1);
    try h.body(f, &.{
        .{ .insts = &.{ hand.param(0, 0), hand.konst(1, zero), hand.konst(2, zero_l) }, .term = hand.jump(1) },
        .{ .insts = &.{hand.bin(3, .Less, 1, 0)}, .term = branchOn(3, 2, 3) },
        .{ .insts = &.{
            .{ .UnOp = .{ .dst = hand.reg(4), .op = .ToLong, .operand = hand.reg(1) } },
            hand.bin(2, .Add, 2, 4),
            hand.konst(5, one),
            hand.bin(1, .Add, 1, 5),
        }, .term = hand.jump(1) },
        .{ .insts = &.{}, .term = hand.ret(2) },
    });
    try h.finish();
    const fs, const k = try kindsOf(a, &h, f);
    const head = fs.blocks[1].enter;
    try testing.expectEqual(of(.Int), k.kindAt(head, 1));
    try testing.expectEqual(of(.Long), k.kindAt(head, 2));
    // A parameter declared no primitive type is not known.
    try testing.expectEqual(unknown, k.kindAt(head, 0));
    const exit = fs.blocks[3].enter;
    try testing.expectEqual(of(.Long), k.kindAt(exit, 2));
    try testing.expectEqual(of(.Bool), k.kindAt(exit, 3));
}

test "a register written with two kinds on two paths is unknown where they join" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try hand.Hand.init(a);
    const one = try h.constant(.{ .Int = 1 });
    const one_l = try h.constant(.{ .Long = 1 });
    const two = try h.constant(.{ .Int = 2 });
    // if (p) { x = 1; y = 2 } else { x = 1L; y = 2 }; return x
    const f = try h.func("join", 1);
    try h.body(f, &.{
        .{ .insts = &.{hand.param(0, 0)}, .term = branchOn(0, 1, 2) },
        .{ .insts = &.{ hand.konst(1, one), hand.konst(2, two) }, .term = hand.jump(3) },
        .{ .insts = &.{ hand.konst(1, one_l), hand.konst(2, two) }, .term = hand.jump(3) },
        .{ .insts = &.{hand.bin(3, .Add, 1, 2)}, .term = hand.ret(3) },
    });
    try h.finish();
    const fs, const k = try kindsOf(a, &h, f);
    const join = fs.blocks[3].enter;
    try testing.expectEqual(unknown, k.kindAt(join, 1));
    try testing.expectEqual(of(.Int), k.kindAt(join, 2));
    // Before the branch nothing has been written.
    try testing.expectEqual(unknown, k.kindAt(fs.blocks[0].enter, 1));
}

test "compares make Bools, arithmetic keeps its operands' kind, and a mixed pair is unknown" {
    try testing.expectEqual(of(.Bool), binKind(.Less, unknown, unknown));
    try testing.expectEqual(of(.Bool), binKind(.IdentEq, of(.Instance), of(.Null)));
    try testing.expectEqual(of(.Int), binKind(.Mul, of(.Int), of(.Int)));
    try testing.expectEqual(of(.Double), binKind(.Div, of(.Double), of(.Double)));
    try testing.expectEqual(unknown, binKind(.Add, of(.Int), of(.Long)));
    try testing.expectEqual(unknown, binKind(.Add, of(.Byte), of(.Byte)));
    try testing.expectEqual(of(.Long), binKind(.Shl, of(.Long), of(.Int)));
    try testing.expectEqual(of(.Bool), binKind(.And, of(.Bool), of(.Bool)));
    try testing.expectEqual(unknown, binKind(.StringConcat, of(.String), of(.String)));
}

test "a parameter declared a non-null primitive has its type's kind" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try hand.Hand.init(a);
    const f = try h.func("typed", 3);
    try h.body(f, &.{.{ .insts = &.{ hand.param(0, 0), hand.param(1, 1), hand.param(2, 2), hand.bin(3, .Add, 0, 1) }, .term = hand.ret(3) }});
    const params = h.m.funcByIdMut(f).?.params;
    params[0].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
    params[1].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
    params[2].ty = .{ .name = "kotlin.Int", .nullable = true, .args = &.{} };
    try h.finish();
    const fs, const k = try kindsOf(a, &h, f);
    const b = fs.blocks[0];
    const last = b.idx_pc[b.idx_pc.len - 1];
    try testing.expectEqual(of(.Int), k.kindAt(last, 0));
    try testing.expectEqual(unknown, k.kindAt(last, 2));
    // Two Int parameters add to an Int.
    const ret_pc = last + bc.opLen(fs.opAt(last), fs.code, last);
    try testing.expectEqual(of(.Int), k.kindAt(ret_pc, 3));
}

test "a register is written where every path to an op wrote it, and nowhere past a catch's entry" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try hand.Hand.init(a);
    const one = try h.constant(.{ .Int = 1 });
    const exc = try h.class("E", .{});
    // b0: x = 1; if (p) goto b1 else goto b2 (y = 1 on b1 only); b3 joins; b4 catches b0's throws.
    const f = try h.func("paths", 1);
    try h.body(f, &.{
        .{ .insts = &.{ hand.param(0, 0), hand.konst(1, one) }, .term = branchOn(0, 1, 2), .catches = &.{hand.catchClass(exc, 4, 5)} },
        .{ .insts = &.{hand.konst(2, one)}, .term = hand.jump(3) },
        .{ .insts = &.{}, .term = hand.jump(3) },
        .{ .insts = &.{}, .term = hand.ret(1) },
        .{ .insts = &.{}, .term = hand.ret(1) },
    });
    try h.finish();
    const fs, const k = try kindsOf(a, &h, f);
    const join = fs.blocks[3].enter;
    try testing.expect(k.written(join, 1));
    try testing.expect(!k.written(join, 2));
    try testing.expect(!k.written(fs.blocks[0].enter, 1));
    // A throw in b0 may come before its writes.
    try testing.expect(!k.written(fs.blocks[4].enter, 1));
    try testing.expectEqual(unknown, k.kindAt(fs.blocks[4].enter, 1));
}

test "a new of a class leaves its instance's slots known, and a field access what it reached" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try hand.Hand.init(a);
    const point = try h.class("Point", .{ .seeds = &.{ .int, .int } });
    const ctor = try hand.ctorReturningThis(&h);
    // p = Point(); x = p.1; q.0 = x; y = q.2; return y
    const f = try h.func("fields", 1);
    try h.body(f, &.{.{ .insts = &.{
        hand.param(0, 0),
        hand.newInstance(1, point, ctor, 2, 0),
        hand.getField(3, 1, 1),
        hand.setField(0, 0, 3),
        hand.getField(4, 0, 2),
    }, .term = hand.ret(4) }});
    try h.finish();
    const fs = bc.funcStreams(h.funcPtr(f), h.m.consts.items) orelse return error.TestUnexpectedResult;
    const k = try analyze(a, fs, h.m);
    const b = fs.blocks[0];
    // A class ordered by default: its slots are not plain.
    try testing.expectEqual(instFact(2, false), k.kindAt(b.idx_pc[2], 1));
    // A class with no volatile property has plain slots where the processor copies a slot whole.
    h.classes.items[point.int()].def.asPtr().ordered_slots = false;
    const k2 = try analyze(a, fs, h.m);
    try testing.expectEqual(instFact(2, runtime.plainSlotsOn()), k2.kindAt(b.idx_pc[2], 1));
    const plain = false;
    // After the `new`: the class's two slots.
    try testing.expectEqual(instFact(2, plain), k.kindAt(b.idx_pc[2], 1));
    try testing.expectEqual(Tag.Instance, tagOf(k.kindAt(b.idx_pc[2], 1)).?);
    // Before any access the parameter is not known; a store to slot 0 leaves one slot known.
    try testing.expectEqual(unknown, k.kindAt(b.idx_pc[3], 0));
    try testing.expectEqual(instFact(1, false), k.kindAt(b.idx_pc[4], 0));
    // A read of slot 2 leaves three; its own result is the field's.
    const ret_pc = b.idx_pc[4] + bc.opLen(fs.opAt(b.idx_pc[4]), fs.code, b.idx_pc[4]);
    try testing.expectEqual(instFact(3, false), k.kindAt(ret_pc, 0));
    try testing.expectEqual(unknown, k.kindAt(ret_pc, 4));
    // Where paths join, what both know.
    try testing.expectEqual(instFact(1, false), meet(instFact(3, true), instFact(1, false)));
    try testing.expectEqual(instFact(2, true), meet(instFact(3, true), instFact(2, true)));
    try testing.expectEqual(of(.Instance), meet(instFact(3, true), of(.Instance)));
    try testing.expectEqual(unknown, meet(instFact(3, true), of(.Int)));
    try testing.expectEqual(of(.Instance), instFact(0, false));
    // Without the module's tables a `new` is not known.
    const bare = try analyze(a, fs, null);
    try testing.expectEqual(unknown, bare.kindAt(b.idx_pc[2], 1));
}
