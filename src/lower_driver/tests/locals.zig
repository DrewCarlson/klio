//! A `var`'s register read and written in place (`lower/sema/locals.zig`):
//! the instructions a statement over locals lowers to, and the programs
//! whose evaluation order a copy would otherwise have to keep. Every
//! expected output is what kotlinc 2.4.20 prints for the same program.

const std = @import("std");
const sema = @import("sema");
const ir = @import("ir");

const driver = @import("../lower_driver.zig");

const lower = ir.lower_sema;
const Sym = sema.Sym;
const FuncId = ir.FuncId;
const testing = std.testing;

/// A program analyzed and lowered over the miniature base.
const Fx = struct {
    arena: *std.heap.ArenaAllocator,
    an: driver.Analysis,
    prog: lower.Program,

    fn init(src: []const u8) !Fx {
        const arena = try testing.allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer {
            arena.deinit();
            testing.allocator.destroy(arena);
        }
        const al = arena.allocator();
        const an = try driver.analyze(al, &.{src});
        const census = try an.census(al, .program);
        if (census.len != 0) {
            std.debug.print("unresolved:\n{s}", .{census});
            return error.TestUnexpectedResult;
        }
        const prog = try lower.lowerProgram(al, an.s, an.br);
        if (prog.errors.items.len != 0) {
            for (prog.errors.items) |le| std.debug.print("{s}\n", .{le.msg});
            return error.TestUnexpectedResult;
        }
        return .{ .arena = arena, .an = an, .prog = prog };
    }

    fn deinit(self: *Fx) void {
        self.arena.deinit();
        testing.allocator.destroy(self.arena);
    }

    /// The body of the program's top-level function `name`.
    fn body(self: *const Fx, name: []const u8) !*const ir.Func {
        const s = self.an.s;
        var i: u32 = 1;
        while (i < s.syms.count()) : (i += 1) {
            const sym = Sym.from(i);
            if (s.syms.kind(sym) != .function) continue;
            const owner = s.syms.owner(sym);
            if (owner == .none or s.syms.kind(owner) != .package) continue;
            const f = s.syms.get(sym).file;
            if (f >= s.files.items.len or s.files.items[f].origin != .program) continue;
            if (!std.mem.eql(u8, s.str(s.syms.name(sym)), name)) continue;
            return &self.an.br.m.funcs.items[self.an.br.funcOf(sym).int()];
        }
        std.debug.print("no function {s}\n", .{name});
        return error.TestUnexpectedResult;
    }
};

/// The instructions of `f`'s blocks, a line each, without the position
/// markers: `BinOp r0 = r0 Add r1`.
fn listing(a: std.mem.Allocator, f: *const ir.Func) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (f.blocks, 0..) |blk, i| {
        try out.print(a, "b{d}:\n", .{i});
        for (blk.insts) |inst| {
            switch (inst) {
                .Trace => continue,
                .Move => |x| try out.print(a, "  Move r{d} = r{d}\n", .{ x.dst.int(), x.src.int() }),
                .Const => |x| try out.print(a, "  Const r{d}\n", .{x.dst.int()}),
                .LoadParam => |x| try out.print(a, "  LoadParam r{d} = {d}\n", .{ x.dst.int(), x.idx }),
                .BinOp => |x| try out.print(a, "  BinOp r{d} = r{d} {s} r{d}\n", .{ x.dst.int(), x.lhs.int(), @tagName(x.op), x.rhs.int() }),
                .UnOp => |x| try out.print(a, "  UnOp r{d} = {s} r{d}\n", .{ x.dst.int(), @tagName(x.op), x.operand.int() }),
                .GetFieldSlot => |x| try out.print(a, "  GetFieldSlot r{d} = r{d}.#{d}\n", .{ x.dst.int(), x.obj.int(), x.slot }),
                .CallStatic => |x| try out.print(a, "  CallStatic r{d} = (r{d}..{d})\n", .{ x.dst.int(), x.args.int(), x.n_args }),
                else => |x| try out.print(a, "  {s}\n", .{@tagName(x)}),
            }
        }
    }
    return out.items;
}

fn count(f: *const ir.Func, tag: std.meta.Tag(ir.Inst)) usize {
    var n: usize = 0;
    for (f.blocks) |blk| {
        for (blk.insts) |inst| {
            if (std.meta.activeTag(inst) == tag) n += 1;
        }
    }
    return n;
}

test "a = a + i over two vars is one BinOp into a" {
    var fx = try Fx.init(
        \\fun sum(n: Int): Int {
        \\    var a = 1
        \\    var i = 0
        \\    while (i < n) {
        \\        a = a + i
        \\        i++
        \\    }
        \\    return a
        \\}
    );
    defer fx.deinit();
    const f = try fx.body("sum");
    const text = try listing(fx.arena.allocator(), f);
    // The initializers' constants are the vars' registers, the condition
    // reads them in place, `a = a + i` is the one BinOp writing `a`, and
    // `i++` the one operation writing `i`.
    try testing.expectEqual(@as(usize, 0), count(f, .Move));
    try testing.expect(std.mem.find(u8, text, "BinOp r0 = r0 Add r1\n") != null);
    try testing.expect(std.mem.find(u8, text, "BinOp r3 = r1 Less r2\n") != null);
}

test "a statement over vars writes its result into the var it assigns" {
    var fx = try Fx.init(
        \\class Node(val v: Int, val next: Node?)
        \\fun g(x: Int): Int = x * 2
        \\fun walk(start: Node): Int {
        \\    var n: Node? = start
        \\    var t = 0
        \\    while (n != null) {
        \\        t = g(t) + n.v
        \\        t += n.v
        \\        n = n.next
        \\    }
        \\    return t
        \\}
    );
    defer fx.deinit();
    const f = try fx.body("walk");
    // `n` copies the parameter it starts from; in the loop the one move
    // is `t` into the call's argument, and each assignment computes into
    // its var's register: `g(t) + n.v` and `t += n.v` into `t` (r2),
    // `n.next` into `n` (r1).
    try testing.expectEqualStrings(
        \\b0:
        \\  LoadParam r0 = 0
        \\  Move r1 = r0
        \\  Const r2
        \\  Const r13
        \\b1:
        \\  Const r3
        \\  BinOp r4 = r1 IdentEq r3
        \\  Not
        \\b2:
        \\  CallStatic r7 = (r2..1)
        \\  GetFieldSlot r8 = r1.#0
        \\  BinOp r2 = r7 Add r8
        \\  GetFieldSlot r10 = r1.#0
        \\  BinOp r2 = r2 Add r10
        \\  GetFieldSlot r1 = r1.#1
        \\b3:
        \\b4:
        \\  Const r14
        \\
    , try listing(fx.arena.allocator(), f));
}

test "a var read before a write it must not see is copied, and only then" {
    var fx = try Fx.init(
        \\fun pair(x: Int, y: Int): Int = x * 10 + y
        \\fun early(): Int {
        \\    var a = 1
        \\    return pair(a, a++)
        \\}
        \\fun late(): Int {
        \\    var a = 1
        \\    return pair(a, a)
        \\}
    );
    defer fx.deinit();
    // `late` reads `a` in place twice and moves both into the call's
    // arguments. In `early` the increment writes `a` before the call, so
    // the first read is copied, straight into its argument slot, and the
    // old value the increment gives is copied into the next.
    try testing.expectEqualStrings(
        \\b0:
        \\  Const r0
        \\  Move r1 = r0
        \\  Move r2 = r0
        \\  CallStatic r3 = (r1..2)
        \\b1:
        \\  Const r4
        \\
    , try listing(fx.arena.allocator(), try fx.body("late")));
    try testing.expectEqualStrings(
        \\b0:
        \\  Const r0
        \\  Move r4 = r0
        \\  Move r5 = r0
        \\  UnOp r0 = Inc r0
        \\  CallStatic r6 = (r4..2)
        \\b1:
        \\  Const r7
        \\
    , try listing(fx.arena.allocator(), try fx.body("early")));
}

fn expectRun(src: []const u8, want: []const u8) !void {
    driver.expectOutput(&.{src}, want) catch |err| {
        if (err == error.Unsupported) return error.SkipZigTest;
        return err;
    };
}

test "a var read in place keeps the value it had when it was read" {
    try expectRun(
        \\class Box(var n: Int)
        \\fun pair(x: Int, y: Int): String = x.toString() + " " + y.toString()
        \\inline fun <T> heldBefore(x: T, f: () -> Unit): T {
        \\    f()
        \\    return x
        \\}
        \\inline fun <T> heldAfter(f: () -> Unit, x: T): T {
        \\    f()
        \\    return x
        \\}
        \\fun main() {
        \\    var a = 1
        \\    println(pair(a, run { a = 5; 0 }))
        \\    a = 1
        \\    println(a + a++)
        \\    println(a)
        \\    a = 1
        \\    println(a++ + a)
        \\    var i = 1
        \\    println(pair(++i, i++))
        \\    println(i)
        \\    a = 1
        \\    val b = a
        \\    a = 2
        \\    println(b)
        \\    a = 3
        \\    println(heldBefore(a) { a = 9 })
        \\    a = 3
        \\    println(heldAfter({ a = 9 }, a))
        \\    a = 4
        \\    println(a.let { a = 5; it })
        \\    a = 6
        \\    println(with(a) { a = 7; this })
        \\    a = 8
        \\    println("$a ${run { a = 3; a }}")
        \\    val arr = intArrayOf(0, 0, 0)
        \\    a = 2
        \\    arr[a] = run { a = 1; 10 }
        \\    println(arr[2])
        \\    var o = Box(1)
        \\    val first = o
        \\    o.n = run { o = Box(2); 5 }
        \\    println(pair(first.n, o.n))
        \\    a = 1
        \\    a += run { a = 10; 1 }
        \\    println(a)
        \\}
    ,
        \\1 0
        \\2
        \\2
        \\3
        \\2 2
        \\3
        \\1
        \\3
        \\3
        \\4
        \\6
        \\8 3
        \\10
        \\5 2
        \\2
        \\
    );
}

test "a when subject, a finally and a captured var see the value their order gives" {
    try expectRun(
        \\fun early(): Int {
        \\    var a = 1
        \\    try {
        \\        return a
        \\    } finally {
        \\        a = 2
        \\    }
        \\}
        \\fun main() {
        \\    println(early())
        \\    var a = 1
        \\    a = try { a + 1 } finally { println("finally " + a) }
        \\    println(a)
        \\    a = 1
        \\    when (a) {
        \\        run { a = 2; 1 } -> println("one " + a)
        \\        else -> println("else " + a)
        \\    }
        \\    a = 1
        \\    when (val v = a) {
        \\        else -> {
        \\            a = 5
        \\            println(v.toString() + " " + a)
        \\        }
        \\    }
        \\    var s: String? = null
        \\    s = s ?: run { s = "x"; "y" }
        \\    println(s)
        \\    var captured = 1
        \\    val bump = { captured += 10 }
        \\    println(captured + run { bump(); 0 })
        \\    println(captured)
        \\}
    ,
        \\1
        \\finally 1
        \\2
        \\one 2
        \\1 5
        \\y
        \\1
        \\11
        \\
    );
}

test "vars written in place across loops, break, continue and inline lambdas" {
    try expectRun(
        \\fun pair(x: Int, y: Int): String = x.toString() + " " + y.toString()
        \\fun main() {
        \\    var n = 0
        \\    var total = 0
        \\    while (true) {
        \\        n = n + 1
        \\        if (n % 2 == 0) continue
        \\        if (n > 7) break
        \\        total = total + n
        \\    }
        \\    println(pair(n, total))
        \\    var k = 0
        \\    do {
        \\        k++
        \\        if (k < 3) continue
        \\    } while (k < 5)
        \\    println(k)
        \\    var x = 10
        \\    x = x - x / 2
        \\    x = pair(x, x).length + x
        \\    println(x)
        \\    var c = 0
        \\    repeat(3) { c = c + it }
        \\    println(c)
        \\    var d = 5
        \\    d = d
        \\    val e = d++
        \\    println(pair(d, e))
        \\}
    ,
        \\9 16
        \\5
        \\8
        \\3
        \\6 5
        \\
    );
}

test "an argument lowered for a call alone is computed straight into its slot" {
    var fx = try Fx.init(
        \\fun f(x: Int): Int = x
        \\fun g(x: Int, y: Int): Int = x + y
        \\fun h(): Int = g(f(1), 2)
    );
    defer fx.deinit();
    // `1` is loaded into `f`'s argument, `f` returns into `g`'s first and
    // `2` is loaded into its second: nothing is moved.
    try testing.expectEqualStrings(
        \\b0:
        \\  Const r1
        \\  CallStatic r4 = (r1..1)
        \\  Const r5
        \\  CallStatic r6 = (r4..2)
        \\
    , try listing(fx.arena.allocator(), try fx.body("h")));
}

test "an inline function's copy reads its parameters from the caller's registers" {
    var fx = try Fx.init(
        \\inline fun <T> same(x: T): T {
        \\    val y = x
        \\    return y
        \\}
        \\fun g(n: Int): Int = same(n) + same(n)
    );
    defer fx.deinit();
    // Neither `x` nor its copy `y` is moved in: each copy's result reads
    // `n`'s register (r0). The blocks after each `return` are the copied
    // body's unreachable end.
    try testing.expectEqualStrings(
        \\b0:
        \\  LoadParam r0 = 0
        \\  Const r4
        \\b1:
        \\b2:
        \\  Move r3 = r0
        \\b3:
        \\  Const r2
        \\  Move r3 = r4
        \\b4:
        \\  BinOp r8 = r3 Add r7
        \\b5:
        \\  Move r7 = r0
        \\b6:
        \\  Const r6
        \\  Move r7 = r4
        \\
    , try listing(fx.arena.allocator(), try fx.body("g")));
}

test "a receiver and index read again by a second call keep their registers" {
    try expectRun(
        \\val a = intArrayOf(1, 2, 3)
        \\var calls = 0
        \\fun arr(): IntArray {
        \\    calls++
        \\    return a
        \\}
        \\fun idx(): Int {
        \\    calls += 10
        \\    return 1
        \\}
        \\fun main() {
        \\    arr()[idx()] += 5
        \\    arr()[idx()]++
        \\    println(a[1])
        \\    println(calls)
        \\}
    ,
        \\8
        \\22
        \\
    );
}
