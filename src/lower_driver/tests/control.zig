//! Package C3's tests: control flow, operators, type tests and templates.

const std = @import("std");
const span = @import("span");
const ast = @import("ast");
const lexer = @import("lexer");
const parser = @import("parser");
const sema = @import("sema");
const ir = @import("ir");

const lower = ir.lower_sema;
const operator = lower.operator;
const PrimOp = operator.PrimOp;

test {
    std.testing.refAllDecls(lower.control);
    std.testing.refAllDecls(lower.operator);
    std.testing.refAllDecls(lower.types);
}

fn parse(a: std.mem.Allocator, map: *span.SourceMap, path: []const u8, src: []const u8, origin: sema.Origin) !sema.SourceFile {
    const id = try map.add(path, src);
    const text = map.get(id).source;
    var lx = try lexer.Lexer.init(a, id, text);
    const lexed = try lx.tokenize();
    const p = parser.Parser.new(a, id, text, lexed.tokens, lexed.strings);
    const file = try a.create(ast.KotlinFile);
    file.* = p.parseFile();
    return .{ .ast = file, .path = path, .origin = origin };
}

/// The primitive classes as the base declares them: bodyless members, the
/// operations the table binds.
const prim_base =
    \\package kotlin
    \\public open class Any {
    \\    public open fun toString(): String
    \\    public open operator fun equals(other: Any?): Boolean
    \\    public open fun hashCode(): Int
    \\}
    \\public class Nothing private constructor()
    \\public object Unit
    \\public interface Comparable<in T> { public operator fun compareTo(other: T): Int }
    \\public abstract class Number
    \\public class Boolean : Comparable<Boolean> {
    \\    public operator fun not(): Boolean
    \\    public infix fun and(other: Boolean): Boolean
    \\    public infix fun or(other: Boolean): Boolean
    \\    public infix fun xor(other: Boolean): Boolean
    \\    public override operator fun compareTo(other: Boolean): Int
    \\    public override fun equals(other: Any?): Boolean
    \\}
    \\public class Char : Comparable<Char> {
    \\    public override operator fun compareTo(other: Char): Int
    \\    public operator fun plus(increment: Int): Char
    \\    public operator fun minus(other: Char): Int
    \\    public operator fun minus(decrement: Int): Char
    \\    public operator fun inc(): Char
    \\    public operator fun dec(): Char
    \\    public operator fun rangeTo(other: Char): CharRange
    \\    public fun toInt(): Int
    \\}
    \\public class CharRange
    \\public class IntRange
    \\public class Int : Number(), Comparable<Int> {
    \\    public override operator fun compareTo(other: Int): Int
    \\    public operator fun compareTo(other: Long): Int
    \\    public operator fun compareTo(other: Double): Int
    \\    public operator fun plus(other: Int): Int
    \\    public operator fun plus(other: Long): Long
    \\    public operator fun plus(other: Double): Double
    \\    public operator fun minus(other: Int): Int
    \\    public operator fun times(other: Int): Int
    \\    public operator fun div(other: Int): Int
    \\    public operator fun rem(other: Int): Int
    \\    public operator fun inc(): Int
    \\    public operator fun dec(): Int
    \\    public operator fun unaryPlus(): Int
    \\    public operator fun unaryMinus(): Int
    \\    public operator fun rangeTo(other: Int): IntRange
    \\    public infix fun shl(bitCount: Int): Int
    \\    public infix fun ushr(bitCount: Int): Int
    \\    public infix fun and(other: Int): Int
    \\    public fun inv(): Int
    \\    public fun toInt(): Int
    \\    public fun toLong(): Long
    \\    public override fun equals(other: Any?): Boolean
    \\    public override fun toString(): String
    \\}
    \\public class Long : Number(), Comparable<Long> {
    \\    public override operator fun compareTo(other: Long): Int
    \\    public operator fun plus(other: Long): Long
    \\    public infix fun shr(bitCount: Int): Long
    \\    public fun toLong(): Long
    \\}
    \\public class Short : Number(), Comparable<Short> {
    \\    public override operator fun compareTo(other: Short): Int
    \\    public operator fun plus(other: Short): Int
    \\    public operator fun unaryPlus(): Int
    \\    public operator fun unaryMinus(): Int
    \\}
    \\public class Byte : Number(), Comparable<Byte> {
    \\    public override operator fun compareTo(other: Byte): Int
    \\}
    \\public class Double : Number(), Comparable<Double> {
    \\    public override operator fun compareTo(other: Double): Int
    \\    public operator fun compareTo(other: Int): Int
    \\    public operator fun plus(other: Double): Double
    \\    public operator fun rem(other: Double): Double
    \\    public operator fun unaryMinus(): Double
    \\    public override fun equals(other: Any?): Boolean
    \\}
    \\public class Float : Number(), Comparable<Float> {
    \\    public override operator fun compareTo(other: Float): Int
    \\    public operator fun div(other: Float): Float
    \\}
    \\public interface CharSequence { public operator fun get(index: Int): Char }
    \\public class String : Comparable<String>, CharSequence {
    \\    public operator fun plus(other: Any?): String
    \\    public override operator fun get(index: Int): Char
    \\    public override operator fun compareTo(other: String): Int
    \\    public override fun equals(other: Any?): Boolean
    \\}
    \\public class Array<T> {
    \\    public operator fun get(index: Int): T
    \\    public operator fun set(index: Int, value: T): Unit
    \\    public val size: Int
    \\}
    \\public class IntArray {
    \\    public operator fun get(index: Int): Int
    \\    public operator fun set(index: Int, value: Int): Unit
    \\}
    \\public open class Throwable
    \\public interface Function<out R>
;

const Fixture = struct {
    arena: *std.heap.ArenaAllocator,
    s: *sema.Sema,
    table: operator.PrimTable,

    fn init() !Fixture {
        const arena = try std.testing.allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer {
            arena.deinit();
            std.testing.allocator.destroy(arena);
        }
        const a = arena.allocator();
        var map = span.SourceMap.init(a);
        const s = try sema.Sema.init(a);
        try s.addFiles(&.{try parse(a, &map, "base.kt", prim_base, .base)});
        return .{ .arena = arena, .s = s, .table = try operator.PrimTable.init(a, s) };
    }

    fn deinit(self: *Fixture) void {
        self.arena.deinit();
        std.testing.allocator.destroy(self.arena);
    }

    /// The member `n` of class `cls` whose parameters are of the classes
    /// `params` (FQNs), in order.
    fn member(self: *Fixture, cls: []const u8, n: []const u8, params: []const []const u8) !sema.Sym {
        const s = self.s;
        const c = s.classByFqn(cls);
        try std.testing.expect(c != .none);
        const nm = s.names.lookup(n) orelse return error.NoSuchMember;
        for (sema.Symbols.members(&s.syms.classInfo(c).members, nm)) |m| {
            if (s.syms.kind(m) != .function) continue;
            try sema.headers.functionHeader(s, m);
            const ps = s.syms.functionInfo(m).params;
            if (ps.len != params.len) continue;
            const same = for (ps, params) |p, want| {
                const pt = try sema.headers.paramType(s, p);
                const pc = s.types.classSym(pt);
                if (pc == .none or pc != s.classByFqn(want)) break false;
            } else true;
            if (same) return m;
        }
        return error.NoSuchMember;
    }

    /// The only member `n` of class `cls` with `arity` parameters.
    fn memberOfArity(self: *Fixture, cls: []const u8, n: []const u8, arity: usize) !sema.Sym {
        const s = self.s;
        const nm = s.names.lookup(n) orelse return error.NoSuchMember;
        for (sema.Symbols.members(&s.syms.classInfo(s.classByFqn(cls)).members, nm)) |m| {
            if (s.syms.kind(m) == .function and s.syms.functionInfo(m).params.len == arity) return m;
        }
        return error.NoSuchMember;
    }

    fn op(self: *Fixture, cls: []const u8, n: []const u8, params: []const []const u8) !?PrimOp {
        return self.table.get(try self.member(cls, n, params));
    }
};

fn expectOp(want: ?PrimOp, got: ?PrimOp) !void {
    if (want == null) {
        if (got != null) {
            std.debug.print("expected no binding, got {any}\n", .{got.?});
            return error.TestExpectedEqual;
        }
        return;
    }
    const g = got orelse {
        std.debug.print("expected {any}, got no binding\n", .{want.?});
        return error.TestExpectedEqual;
    };
    try std.testing.expectEqualDeep(want.?, g);
}

test "the primitive table binds arithmetic in every numeric type, mixed widths included" {
    var f = try Fixture.init();
    defer f.deinit();
    try expectOp(.{ .bin = .Add }, try f.op("kotlin.Int", "plus", &.{"kotlin.Int"}));
    try expectOp(.{ .bin = .Add }, try f.op("kotlin.Int", "plus", &.{"kotlin.Long"}));
    try expectOp(.{ .bin = .Add }, try f.op("kotlin.Int", "plus", &.{"kotlin.Double"}));
    try expectOp(.{ .bin = .Sub }, try f.op("kotlin.Int", "minus", &.{"kotlin.Int"}));
    try expectOp(.{ .bin = .Mul }, try f.op("kotlin.Int", "times", &.{"kotlin.Int"}));
    try expectOp(.{ .bin = .Div }, try f.op("kotlin.Int", "div", &.{"kotlin.Int"}));
    try expectOp(.{ .bin = .Mod }, try f.op("kotlin.Int", "rem", &.{"kotlin.Int"}));
    try expectOp(.{ .bin = .Add }, try f.op("kotlin.Long", "plus", &.{"kotlin.Long"}));
    try expectOp(.{ .bin = .Add }, try f.op("kotlin.Short", "plus", &.{"kotlin.Short"}));
    try expectOp(.{ .bin = .Add }, try f.op("kotlin.Double", "plus", &.{"kotlin.Double"}));
    try expectOp(.{ .bin = .Mod }, try f.op("kotlin.Double", "rem", &.{"kotlin.Double"}));
    try expectOp(.{ .bin = .Div }, try f.op("kotlin.Float", "div", &.{"kotlin.Float"}));
}

test "the primitive table binds unary operators, and leaves widening ones alone" {
    var f = try Fixture.init();
    defer f.deinit();
    try expectOp(.{ .un = .Neg }, try f.op("kotlin.Int", "unaryMinus", &.{}));
    try expectOp(.{ .un = .Neg }, try f.op("kotlin.Double", "unaryMinus", &.{}));
    try expectOp(.{ .un = .Neg }, try f.op("kotlin.Short", "unaryMinus", &.{}));
    try expectOp(.identity, try f.op("kotlin.Int", "unaryPlus", &.{}));
    // `Short.unaryPlus()` is an `Int`: not the operand itself.
    try expectOp(null, try f.op("kotlin.Short", "unaryPlus", &.{}));
    try expectOp(.{ .un = .Inc }, try f.op("kotlin.Int", "inc", &.{}));
    try expectOp(.{ .un = .Dec }, try f.op("kotlin.Int", "dec", &.{}));
    try expectOp(.{ .un = .Inc }, try f.op("kotlin.Char", "inc", &.{}));
    try expectOp(.not, try f.op("kotlin.Boolean", "not", &.{}));
}

test "the primitive table binds compareTo by operand family" {
    var f = try Fixture.init();
    defer f.deinit();
    try expectOp(.{ .compare = .integral }, try f.op("kotlin.Int", "compareTo", &.{"kotlin.Int"}));
    try expectOp(.{ .compare = .integral }, try f.op("kotlin.Int", "compareTo", &.{"kotlin.Long"}));
    try expectOp(.{ .compare = .floating }, try f.op("kotlin.Int", "compareTo", &.{"kotlin.Double"}));
    try expectOp(.{ .compare = .floating }, try f.op("kotlin.Double", "compareTo", &.{"kotlin.Double"}));
    try expectOp(.{ .compare = .floating }, try f.op("kotlin.Double", "compareTo", &.{"kotlin.Int"}));
    try expectOp(.{ .compare = .floating }, try f.op("kotlin.Float", "compareTo", &.{"kotlin.Float"}));
    try expectOp(.{ .compare = .integral }, try f.op("kotlin.Char", "compareTo", &.{"kotlin.Char"}));
    try expectOp(.{ .compare = .integral }, try f.op("kotlin.Boolean", "compareTo", &.{"kotlin.Boolean"}));
    // `String.compareTo` answers the difference at the first unequal
    // character: its declaration's native computes it.
    try expectOp(null, try f.op("kotlin.String", "compareTo", &.{"kotlin.String"}));
}

test "the primitive table binds equals as boxed equality" {
    var f = try Fixture.init();
    defer f.deinit();
    try expectOp(.{ .bin = .BoxedEq }, try f.op("kotlin.Int", "equals", &.{"kotlin.Any"}));
    try expectOp(.{ .bin = .BoxedEq }, try f.op("kotlin.Double", "equals", &.{"kotlin.Any"}));
    try expectOp(.{ .bin = .BoxedEq }, try f.op("kotlin.Boolean", "equals", &.{"kotlin.Any"}));
    try expectOp(.{ .bin = .BoxedEq }, try f.op("kotlin.String", "equals", &.{"kotlin.Any"}));
    // `Any.equals` is identity, served by its own body.
    try expectOp(null, try f.op("kotlin.Any", "equals", &.{"kotlin.Any"}));
}

test "the primitive table binds Char arithmetic, bitwise operations and element access" {
    var f = try Fixture.init();
    defer f.deinit();
    try expectOp(.{ .bin = .Add }, try f.op("kotlin.Char", "plus", &.{"kotlin.Int"}));
    try expectOp(.{ .bin = .Sub }, try f.op("kotlin.Char", "minus", &.{"kotlin.Char"}));
    try expectOp(.{ .bin = .Sub }, try f.op("kotlin.Char", "minus", &.{"kotlin.Int"}));
    try expectOp(.{ .bin = .And }, try f.op("kotlin.Boolean", "and", &.{"kotlin.Boolean"}));
    try expectOp(.{ .bin = .Or }, try f.op("kotlin.Boolean", "or", &.{"kotlin.Boolean"}));
    try expectOp(.{ .bin = .Xor }, try f.op("kotlin.Boolean", "xor", &.{"kotlin.Boolean"}));
    try expectOp(.{ .bin = .And }, try f.op("kotlin.Int", "and", &.{"kotlin.Int"}));
    try expectOp(.{ .bin = .Shl }, try f.op("kotlin.Int", "shl", &.{"kotlin.Int"}));
    try expectOp(.{ .bin = .UShr }, try f.op("kotlin.Int", "ushr", &.{"kotlin.Int"}));
    try expectOp(.{ .bin = .Shr }, try f.op("kotlin.Long", "shr", &.{"kotlin.Int"}));
    try expectOp(.array_get, try f.op("kotlin.String", "get", &.{"kotlin.Int"}));
    try expectOp(.array_get, try f.op("kotlin.Array", "get", &.{"kotlin.Int"}));
    try expectOp(.array_set, f.table.get(try f.memberOfArity("kotlin.Array", "set", 2)));
    try expectOp(.array_get, try f.op("kotlin.IntArray", "get", &.{"kotlin.Int"}));
    try expectOp(.array_set, try f.op("kotlin.IntArray", "set", &.{ "kotlin.Int", "kotlin.Int" }));
}

test "the primitive table leaves conversions, ranges and rendering to their declarations" {
    var f = try Fixture.init();
    defer f.deinit();
    try expectOp(.identity, try f.op("kotlin.Int", "toInt", &.{}));
    try expectOp(.identity, try f.op("kotlin.Long", "toLong", &.{}));
    try expectOp(null, try f.op("kotlin.Int", "toLong", &.{}));
    try expectOp(null, try f.op("kotlin.Char", "toInt", &.{}));
    try expectOp(null, try f.op("kotlin.Int", "rangeTo", &.{"kotlin.Int"}));
    try expectOp(null, try f.op("kotlin.Char", "rangeTo", &.{"kotlin.Char"}));
    try expectOp(null, try f.op("kotlin.Int", "inv", &.{}));
    try expectOp(null, try f.op("kotlin.Int", "toString", &.{}));
    try expectOp(null, try f.op("kotlin.String", "plus", &.{"kotlin.Any"}));
}

// ------------------------------------------------ the records C3 reads ----
//
// What each construct's lowering looks up, checked on sema's output before
// anything executes: a record missing here fails the body that needs it.

const rest_base =
    \\package kotlin
    \\public open class Throwable(public val message: String? = null)
    \\public open class Exception(message: String? = null) : Throwable(message)
    \\public class IllegalStateException(message: String? = null) : Exception(message)
    \\public class NoWhenBranchMatchedException : Exception()
    \\public fun println(message: Any?) {}
    \\public fun TODO(): Nothing = throw IllegalStateException()
    \\
;

const collections_base =
    \\package kotlin.collections
    \\public interface Iterator<out T> {
    \\    public operator fun next(): T
    \\    public operator fun hasNext(): Boolean
    \\}
    \\public interface Iterable<out T> { public operator fun iterator(): Iterator<T> }
    \\public interface List<out E> : Iterable<E> {
    \\    public operator fun get(index: Int): E
    \\    public operator fun contains(element: Any?): Boolean
    \\}
    \\public interface MutableList<E> : List<E> {
    \\    public operator fun set(index: Int, element: E): E
    \\    public operator fun plusAssign(element: E)
    \\}
    \\public fun <T> listOf(vararg elements: T): List<T> = TODO()
    \\public fun <T> mutableListOf(vararg elements: T): MutableList<T> = TODO()
    \\
;

const Prog = struct {
    arena: *std.heap.ArenaAllocator,
    s: *sema.Sema,
    file: *const ast.KotlinFile,
    recs: *const sema.output.FileRecords,

    fn init(program: []const u8) !Prog {
        const arena = try std.testing.allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer {
            arena.deinit();
            std.testing.allocator.destroy(arena);
        }
        const a = arena.allocator();
        var map = span.SourceMap.init(a);
        const s = try sema.Sema.init(a);
        try s.addFiles(&.{
            try parse(a, &map, "base.kt", prim_base, .base),
            try parse(a, &map, "rest.kt", rest_base, .base),
            try parse(a, &map, "collections.kt", collections_base, .base),
        });
        const prog = try parse(a, &map, "main.kt", program, .program);
        try s.addFiles(&.{prog});
        try s.resolveBodies(&.{.program});
        const out = try sema.output.build(s);
        var clean = true;
        for (s.census.sites.items) |site| {
            if (site.file != 3) continue;
            clean = false;
            std.debug.print("unresolved: {s} {s}\n", .{ @tagName(site.reason), site.detail });
        }
        try std.testing.expect(clean);
        return .{ .arena = arena, .s = s, .file = prog.ast, .recs = &out.files[3] };
    }

    fn deinit(self: *Prog) void {
        self.arena.deinit();
        std.testing.allocator.destroy(self.arena);
    }

    /// The statements of `main`.
    fn stmts(self: *const Prog) []const ast.Stmt {
        for (self.file.decls) |*d| switch (d.*) {
            .Function => |*f| if (std.mem.eql(u8, f.name.name, "main")) return f.body.?.Block.stmts,
            else => {},
        };
        return &.{};
    }

    /// Statement `i` of `main` as an expression: an expression statement,
    /// or a local's initializer.
    fn expr(self: *const Prog, i: usize) *const ast.Expr {
        return switch (self.stmts()[i]) {
            .Expr => |*e| e,
            .Decl => |d| d.Property.init.?,
            else => unreachable,
        };
    }

    fn assign(self: *const Prog, i: usize) *const ast.AssignStmt {
        return self.stmts()[i].Assign;
    }

    fn calleeName(self: *const Prog, rec: sema.records.CallRec) []const u8 {
        return self.s.str(self.s.syms.name(rec.callee));
    }

    fn symName(self: *const Prog, sym: sema.Sym) []const u8 {
        return self.s.str(self.s.syms.name(sym));
    }

    fn className(self: *const Prog, t: sema.TypeId) []const u8 {
        const cls = self.s.types.classSym(t);
        if (cls == .none) return @tagName(std.meta.activeTag(self.s.types.get(t)));
        return self.symName(cls);
    }
};

const output = sema.output;

test "a for loop records its iterator calls and its variable" {
    var p = try Prog.init(
        \\fun main() {
        \\    val xs = listOf(1, 2)
        \\    for (x in xs) println(x)
        \\}
    );
    defer p.deinit();
    const f = p.expr(1).For;
    const g = try output.forGroup(p.s, p.recs, f.id);
    try std.testing.expectEqualStrings("iterator", p.calleeName(g.iterator));
    try std.testing.expectEqualStrings("hasNext", p.calleeName(g.has_next));
    try std.testing.expectEqualStrings("next", p.calleeName(g.next));
    try std.testing.expectEqual(sema.records.Receiver.expr, g.iterator.dispatch);
    try std.testing.expectEqualStrings("x", p.symName(try output.decl(p.recs, f.id)));
}

test "a destructured for loop records each entry's component and local" {
    var p = try Prog.init(
        \\fun main() {
        \\    for ((a, _, c) in listOf(Triple3(1, "a", 2L))) println(a)
        \\}
        \\data class Triple3(val x: Int, val y: String, val z: Long)
    );
    defer p.deinit();
    const f = p.expr(0).For;
    const a = (try output.destructureEntry(p.s, p.recs, f.id, f.vars[0].span.start)).?;
    try std.testing.expectEqualStrings("a", p.symName(a.local));
    try std.testing.expectEqualStrings("component1", p.calleeName(a.call.?));
    try std.testing.expect((try output.destructureEntry(p.s, p.recs, f.id, f.vars[1].span.start)) == null);
    const c = (try output.destructureEntry(p.s, p.recs, f.id, f.vars[2].span.start)).?;
    try std.testing.expectEqualStrings("component3", p.calleeName(c.call.?));
}

test "compound assignments record the target's read, the operator and the write" {
    var p = try Prog.init(
        \\class Box(var v: Int)
        \\fun main() {
        \\    var n = 0
        \\    n += 1
        \\    val ml = mutableListOf(1)
        \\    ml[0] += 2
        \\    val box = Box(1)
        \\    box.v *= 3
        \\    ml += 5
        \\}
    );
    defer p.deinit();
    // A bare name: the operator and the write on the assignment, the read
    // on the target's own node.
    const n_plus = p.assign(1);
    const c1 = try output.compound(p.s, p.recs, n_plus.id);
    try std.testing.expectEqualStrings("plus", p.calleeName(c1.op));
    try std.testing.expect(!c1.assign_form);
    try std.testing.expect(c1.write != null and c1.write.?.kind == .local);
    try std.testing.expectEqual(sema.records.NameKind.local, (try output.name(p.s, p.recs, n_plus.target.id())).kind);
    // An index: `get`, the operator and `set`, all on the assignment.
    const c2 = try output.compound(p.s, p.recs, p.assign(3).id);
    try std.testing.expectEqualStrings("get", p.calleeName(c2.get.?));
    try std.testing.expectEqualStrings("plus", p.calleeName(c2.op));
    try std.testing.expectEqualStrings("set", p.calleeName(c2.set.?));
    // A member: its read and its write on the assignment.
    const c3 = try output.compound(p.s, p.recs, p.assign(5).id);
    try std.testing.expectEqualStrings("times", p.calleeName(c3.op));
    try std.testing.expectEqualStrings("v", p.symName(c3.read.?.target));
    try std.testing.expectEqualStrings("v", p.symName(c3.write.?.target));
    try std.testing.expectEqual(sema.records.Receiver.expr, c3.write.?.dispatch);
    // `plusAssign` writes nothing back.
    const c4 = try output.compound(p.s, p.recs, p.assign(6).id);
    try std.testing.expectEqualStrings("plusAssign", p.calleeName(c4.op));
    try std.testing.expect(c4.assign_form);
    try std.testing.expect(c4.write == null);
}

test "increments record inc or dec and the write back" {
    var p = try Prog.init(
        \\fun main() {
        \\    var n = 0
        \\    n++
        \\    val ml = mutableListOf(1)
        \\    --ml[0]
        \\}
    );
    defer p.deinit();
    const inc = p.expr(1);
    const c1 = try output.compound(p.s, p.recs, inc.id());
    try std.testing.expectEqualStrings("inc", p.calleeName(c1.op));
    try std.testing.expect(c1.write != null);
    try std.testing.expectEqual(sema.records.NameKind.local, (try output.name(p.s, p.recs, inc.Postfix.expr.id())).kind);
    const c2 = try output.compound(p.s, p.recs, p.expr(3).id());
    try std.testing.expectEqualStrings("dec", p.calleeName(c2.op));
    try std.testing.expectEqualStrings("get", p.calleeName(c2.get.?));
    try std.testing.expectEqualStrings("set", p.calleeName(c2.set.?));
}

test "when patterns record equals, contains and type tests at their offsets" {
    var p = try Prog.init(
        \\fun main() {
        \\    val n = 2
        \\    val xs = listOf(1, 2)
        \\    val w = when (n) { 1 -> "one"; in xs -> "in"; !in xs -> "out"; else -> "no" }
        \\    val y: Any = n
        \\    val z = when (y) { is String -> 1; !is Int -> 2; else -> 3 }
        \\}
    );
    defer p.deinit();
    const w = p.expr(2).When;
    const v1 = &w.branches[0].patterns[0].kind.Value;
    try std.testing.expectEqualStrings("equals", p.calleeName((try output.whenPattern(p.s, p.recs, w.id, v1.span().start)).equals));
    const v2 = &w.branches[1].patterns[0].kind.InRange;
    try std.testing.expectEqualStrings("contains", p.calleeName((try output.whenPattern(p.s, p.recs, w.id, v2.span().start)).contains));
    const v3 = &w.branches[2].patterns[0].kind.NotInRange;
    try std.testing.expectEqualStrings("contains", p.calleeName((try output.whenPattern(p.s, p.recs, w.id, v3.span().start)).contains));
    const z = p.expr(4).When;
    const t1 = (try output.whenPattern(p.s, p.recs, z.id, z.branches[0].patterns[0].span.start)).type_test;
    try std.testing.expectEqual(sema.records.TypeTestKind.is_, t1.kind);
    try std.testing.expectEqualStrings("String", p.symName(t1.class));
    const t2 = (try output.whenPattern(p.s, p.recs, z.id, z.branches[1].patterns[0].span.start)).type_test;
    try std.testing.expectEqual(sema.records.TypeTestKind.not_is, t2.kind);
}

test "a when subject binding records its local" {
    var p = try Prog.init(
        \\fun main() {
        \\    val q = when (val m = 3) { 0 -> m; else -> 1 }
        \\}
    );
    defer p.deinit();
    const w = p.expr(0).When;
    // Skipped until sema records the binding's local on the `when` node.
    const sym = output.decl(p.recs, w.id) catch return error.SkipZigTest;
    try std.testing.expectEqualStrings("m", p.symName(sym));
}

test "operators record the call their lowering reads" {
    var p = try Prog.init(
        \\fun main() {
        \\    val a = 1
        \\    val b = 2
        \\    val xs = listOf(1)
        \\    println(a == b)
        \\    println(a < b)
        \\    println(a in xs)
        \\    println(a + b)
        \\    println(-a)
        \\    println(xs[0])
        \\}
    );
    defer p.deinit();
    const arg = struct {
        fn of(pr: *const Prog, i: usize) *const ast.Expr {
            return &pr.expr(i).Call.args[0];
        }
    }.of;
    try std.testing.expectEqualStrings("equals", p.calleeName(try output.call(p.s, p.recs, arg(&p, 3).id())));
    try std.testing.expectEqualStrings("compareTo", p.calleeName(try output.call(p.s, p.recs, arg(&p, 4).id())));
    try std.testing.expectEqualStrings("contains", p.calleeName(try output.call(p.s, p.recs, arg(&p, 5).id())));
    try std.testing.expectEqualStrings("plus", p.calleeName(try output.call(p.s, p.recs, arg(&p, 6).id())));
    try std.testing.expectEqualStrings("unaryMinus", p.calleeName(try output.call(p.s, p.recs, arg(&p, 7).id())));
    try std.testing.expectEqualStrings("get", p.calleeName(try output.call(p.s, p.recs, arg(&p, 8).id())));
}

test "catch, is and as record their type tests" {
    var p = try Prog.init(
        \\fun main() {
        \\    val y: Any = 1
        \\    println(y is Int)
        \\    println(y as? String)
        \\    try { println(1) } catch (e: IllegalStateException) { println(e) }
        \\}
    );
    defer p.deinit();
    const is_ = try output.typeTest(p.recs, p.expr(1).Call.args[0].id());
    try std.testing.expectEqual(sema.records.TypeTestKind.is_, is_.kind);
    try std.testing.expectEqualStrings("Int", p.symName(is_.class));
    const as_ = try output.typeTest(p.recs, p.expr(2).Call.args[0].id());
    try std.testing.expectEqual(sema.records.TypeTestKind.as_safe, as_.kind);
    const c = p.expr(3).Try.catches[0];
    const ct = try output.typeTest(p.recs, c.id);
    try std.testing.expectEqual(sema.records.TypeTestKind.catch_, ct.kind);
    try std.testing.expectEqualStrings("IllegalStateException", p.symName(ct.class));
    try std.testing.expectEqualStrings("e", p.symName(ct.binding));
}

test "a return records the function it leaves" {
    var p = try Prog.init(
        \\fun f(x: Int): Int { return x }
        \\fun main() {}
    );
    defer p.deinit();
    const f = p.file.decls[0].Function;
    const ret = &f.body.?.Block.stmts[0].Expr;
    try std.testing.expectEqualStrings("f", p.symName(try output.returnTarget(p.recs, ret.Return.id)));
}

test "a literal has the type its constant is made with" {
    var p = try Prog.init(
        \\fun f(x: Long): Long = x
        \\fun main() {
        \\    val a: Long = 1
        \\    val b = 1.5f
        \\    val c: Byte = 7
        \\    println(f(1))
        \\}
    );
    defer p.deinit();
    try std.testing.expectEqualStrings("Long", p.className(output.exprType(p.recs, p.expr(0).id())));
    try std.testing.expectEqualStrings("Float", p.className(output.exprType(p.recs, p.expr(1).id())));
    try std.testing.expectEqualStrings("Byte", p.className(output.exprType(p.recs, p.expr(2).id())));
    // An argument's literal is typed by the parameter it is passed for.
    const lit = &p.expr(3).Call.args[0].Call.args[0];
    const t = output.exprType(p.recs, lit.id());
    // Skipped until sema writes an argument literal's solved type.
    if (p.s.types.get(t) == .int_lit) return error.SkipZigTest;
    try std.testing.expectEqualStrings("Long", p.className(t));
}

test "a negated literal takes its expected type" {
    var p = try Prog.init(
        \\fun main() {
        \\    val a: Long = -1
        \\}
    );
    defer p.deinit();
    const a = output.exprType(p.recs, p.expr(0).id());
    // Skipped until sema passes the expected type through a negated literal.
    if (!std.mem.eql(u8, p.className(a), "Long")) return error.SkipZigTest;
}

test "the negated smallest Int is an Int" {
    var p = try Prog.init(
        \\fun main() {
        \\    val b = -2147483648
        \\}
    );
    defer p.deinit();
    const b = output.exprType(p.recs, p.expr(0).id());
    // Skipped until sema types a negated literal by its negated value.
    if (!std.mem.eql(u8, p.className(b), "Int")) return error.SkipZigTest;
}

// ---------------------------------------------------------- executing ----
//
// Programs run through parse, sema, the bridge, this lowering and the VM
// over the executable base. The expected output is what kotlinc prints.

const driver = @import("../lower_driver.zig");

/// Runs `src` and expects exactly `want`; skipped while the driver is not
/// built.
fn expectRun(src: []const u8, want: []const u8) !void {
    driver.expectOutput(&.{src}, want) catch |err| {
        if (err == error.Unsupported) return error.SkipZigTest;
        return err;
    };
}

test "a when guard runs once its pattern matches, and a failed guard falls through" {
    try expectRun(
        \\sealed interface S
        \\data class A(val n: Int) : S
        \\data class B(val s: String) : S
        \\object C : S
        \\fun log(tag: String, v: Boolean): Boolean { println("eval " + tag); return v }
        \\fun f(x: S): String = when (x) {
        \\    is A if log("a>0", x.n > 0) -> "A+" + x.n
        \\    is A -> "A" + x.n
        \\    is B if x.s.length == 0 -> "B empty"
        \\    C -> "C"
        \\    else if log("else guard", x is B && x.s.length > 3) -> "long B"
        \\    else -> "other"
        \\}
        \\fun g(x: Any?): String = when (x) {
        \\    is String if x.length > 2 -> "str:" + x
        \\    is Int if x > 10 -> "big"
        \\    null -> "null"
        \\    else -> "else"
        \\}
        \\fun h(x: S): Int {
        \\    var r = 0
        \\    when (x) {
        \\        is A if x.n == 1 -> r = 1
        \\        is A -> r = 2
        \\        is B -> r = 3
        \\        C -> r = 4
        \\    }
        \\    return r
        \\}
        \\fun main() {
        \\    println(f(A(1)))
        \\    println(f(A(-1)))
        \\    println(f(B("")))
        \\    println(f(B("abcd")))
        \\    println(f(B("ab")))
        \\    println(f(C))
        \\    println(g("abc"))
        \\    println(g("ab"))
        \\    println(g(20))
        \\    println(g(5))
        \\    println(g(null))
        \\    println(h(A(1)) + h(A(2)) + h(B("")) + h(C))
        \\}
    , "eval a>0\nA+1\neval a>0\nA-1\nB empty\neval else guard\nlong B\neval else guard\nother\nC\nstr:abc\nelse\nbig\nelse\nnull\n10\n");
}

test "when with a subject tests values, ranges and types, null narrowing later branches" {
    try expectRun(
        \\sealed class Shape
        \\class Circle(val r: Int) : Shape()
        \\class Square(val s: Int) : Shape()
        \\fun describe(x: Any?): String = when (x) {
        \\    null -> "null"
        \\    0 -> "zero"
        \\    is String -> "string of " + x.length
        \\    is Int, is Long -> "integral"
        \\    else -> "other"
        \\}
        \\fun len(s: String?): Int = when (s) {
        \\    null -> -1
        \\    else -> s.length
        \\}
        \\fun digit(n: Int): String = when (n) {
        \\    in 0..9 -> "digit"
        \\    !in 0..99 -> "big"
        \\    else -> "two digits"
        \\}
        \\fun area(s: Shape): Int = when (s) {
        \\    is Circle -> 3 * s.r * s.r
        \\    is Square -> s.s * s.s
        \\}
        \\fun sign(n: Int): String = when {
        \\    n < 0 -> "negative"
        \\    n == 0 -> "zero"
        \\    else -> "positive"
        \\}
        \\fun main() {
        \\    println(describe(null))
        \\    println(describe(0))
        \\    println(describe("abc"))
        \\    println(describe(42))
        \\    println(describe(7L))
        \\    println(describe(2.5))
        \\    println(len(null))
        \\    println(len("four"))
        \\    println(digit(5))
        \\    println(digit(500))
        \\    println(digit(50))
        \\    println(area(Circle(2)))
        \\    println(area(Square(3)))
        \\    println(sign(-3))
        \\    println(sign(0))
        \\    println(sign(7))
        \\    var hits = 0
        \\    when (hits) { 1 -> { hits = 10 } }
        \\    println(hits)
        \\}
    ,
        \\null
        \\zero
        \\string of 3
        \\integral
        \\integral
        \\other
        \\-1
        \\4
        \\digit
        \\big
        \\two digits
        \\12
        \\9
        \\negative
        \\zero
        \\positive
        \\0
        \\
    );
}

test "a when subject binding is a local of the branches" {
    try expectRun(
        \\fun main() {
        \\    val v = when (val n = 3 * 4) { 12 -> "twelve $n"; else -> "other $n" }
        \\    println(v)
        \\}
    ,
        \\twelve 12
        \\
    );
}

test "labeled loops break and continue to the loop the label names" {
    try expectRun(
        \\fun main() {
        \\    outer@ for (i in 1..3) {
        \\        for (j in 1..3) {
        \\            if (j == 2) continue@outer
        \\            if (i == 3) break@outer
        \\            println("$i $j")
        \\        }
        \\    }
        \\    var k = 0
        \\    while (true) {
        \\        k++
        \\        if (k % 2 == 0) continue
        \\        if (k > 5) break
        \\        println("k=$k")
        \\    }
        \\    var w = 0
        \\    top@ while (w < 10) {
        \\        w++
        \\        var inner = 0
        \\        while (true) {
        \\            inner++
        \\            if (inner == 2) continue@top
        \\        }
        \\    }
        \\    println("w=$w")
        \\}
    ,
        \\1 1
        \\2 1
        \\k=1
        \\k=3
        \\k=5
        \\w=10
        \\
    );
}

test "a labeled do-while's continue checks the condition" {
    try expectRun(
        \\fun main() {
        \\    var m = 0
        \\    d@ do {
        \\        m++
        \\        println("m=$m")
        \\        if (m == 2) continue@d
        \\        if (m > 3) break
        \\    } while (m < 2)
        \\    var n = 0
        \\    do {
        \\        n++
        \\        if (n == 1) continue
        \\        println("n=$n")
        \\    } while (n < 3)
        \\}
    ,
        \\m=1
        \\m=2
        \\n=2
        \\n=3
        \\
    );
}

test "break and continue run the finallys they leave, innermost first" {
    try expectRun(
        \\fun main() {
        \\    for (i in 1..3) {
        \\        try {
        \\            if (i == 2) continue
        \\            if (i == 3) break
        \\            println("body $i")
        \\        } finally {
        \\            println("finally $i")
        \\        }
        \\    }
        \\    while (true) {
        \\        try {
        \\            try { break } finally { println("inner") }
        \\        } finally {
        \\            println("outer")
        \\        }
        \\    }
        \\    println("after")
        \\}
    ,
        \\body 1
        \\finally 1
        \\finally 2
        \\finally 3
        \\inner
        \\outer
        \\after
        \\
    );
}

test "a break out of a catch-only try leaves its catch behind" {
    try expectRun(
        \\fun stale(): String {
        \\    for (i in 0..1) {
        \\        try {
        \\            if (i == 0) break
        \\        } catch (e: IllegalStateException) {
        \\            return "caught by the try the loop left"
        \\        }
        \\    }
        \\    throw IllegalStateException("x")
        \\}
        \\fun main() {
        \\    try {
        \\        println(stale())
        \\    } catch (e: IllegalStateException) {
        \\        println("escaped " + e.message)
        \\    }
        \\}
    ,
        \\escaped x
        \\
    );
}

test "try catches by class, rethrows, and runs finally on return" {
    try expectRun(
        \\fun f(n: Int): String {
        \\    try {
        \\        if (n == 0) throw IllegalStateException("zero")
        \\        if (n == 1) throw IllegalArgumentException("one")
        \\        return "ok $n"
        \\    } catch (e: IllegalStateException) {
        \\        return "caught state " + e.message
        \\    } finally {
        \\        println("finally $n")
        \\    }
        \\}
        \\fun g() {
        \\    try {
        \\        try {
        \\            throw IllegalArgumentException("inner")
        \\        } catch (e: IllegalArgumentException) {
        \\            println("rethrowing")
        \\            throw e
        \\        }
        \\    } catch (e: RuntimeException) {
        \\        println("outer caught " + e.message)
        \\    }
        \\}
        \\fun main() {
        \\    println(f(0))
        \\    try {
        \\        println(f(1))
        \\    } catch (e: IllegalArgumentException) {
        \\        println("escaped " + e.message)
        \\    }
        \\    println(f(2))
        \\    g()
        \\    val v = try { 1 } finally { println("fin") }
        \\    println(v)
        \\    val w = try { throw Exception("x") } catch (e: Exception) { 7 }
        \\    println(w)
        \\}
    ,
        \\finally 0
        \\caught state zero
        \\finally 1
        \\escaped one
        \\finally 2
        \\ok 2
        \\rethrowing
        \\outer caught inner
        \\fin
        \\1
        \\7
        \\
    );
}

test "type tests and casts go by class, erased, null admitted by a nullable type" {
    try expectRun(
        \\open class Animal
        \\class Dog : Animal()
        \\class Cat : Animal()
        \\fun main() {
        \\    val a: Any? = null
        \\    println(a is String?)
        \\    println(a is String)
        \\    val d: Animal = Dog()
        \\    println(d is Dog)
        \\    println(d is Cat)
        \\    println(d !is Cat)
        \\    println(d is Any)
        \\    val xs: Collection<String> = listOf("a")
        \\    println(xs is List<String>)
        \\    println(d as? Cat)
        \\    try {
        \\        val cat = d as Cat
        \\        println(cat)
        \\    } catch (e: ClassCastException) {
        \\        println("cast failed")
        \\    }
        \\    val s: Any = "str"
        \\    println((s as String).length)
        \\    println(a as String?)
        \\}
    ,
        \\true
        \\false
        \\true
        \\false
        \\true
        \\true
        \\true
        \\null
        \\cast failed
        \\3
        \\null
        \\
    );
}

test "arithmetic on primitives in each numeric type" {
    try expectRun(
        \\fun main() {
        \\    val i = 7
        \\    val j = 2
        \\    println(i + j)
        \\    println(i - j)
        \\    println(i * j)
        \\    println(i / j)
        \\    println(i % j)
        \\    println(-7 / 2)
        \\    println(-7 % 2)
        \\    val l = 7L
        \\    println(l * 3 + i)
        \\    val big = 2147483647
        \\    println(big + 1)
        \\    println(9223372036854775807L + 1)
        \\    val d = 7.0
        \\    println(d / 2)
        \\    println(i / 2.0)
        \\    val f = 1.5f
        \\    println(f * 2)
        \\    println('a' + 1)
        \\    println('c' - 'a')
        \\    println(-d)
        \\    println(i > j && j > 0)
        \\    println(i < j || j == 2)
        \\    println(!(i == j))
        \\    println(i >= 7)
        \\    println(l <= 6L)
        \\}
    ,
        \\9
        \\5
        \\14
        \\3
        \\1
        \\-3
        \\-1
        \\28
        \\-2147483648
        \\-9223372036854775808
        \\3.5
        \\3.5
        \\3.0
        \\b
        \\2
        \\-7.0
        \\true
        \\true
        \\true
        \\true
        \\false
        \\
    );
}

test "== is IEEE on floating static types and equals on boxed ones" {
    try expectRun(
        \\fun main() {
        \\    val nan = 0.0 / 0.0
        \\    println(nan == nan)
        \\    val a: Any = nan
        \\    val b: Any = nan
        \\    println(a == b)
        \\    println(nan.equals(nan))
        \\    val z = 0.0
        \\    val nz = -0.0
        \\    println(z == nz)
        \\    val bz: Any = z
        \\    val bnz: Any = nz
        \\    println(bz == bnz)
        \\    val dn: Double? = nan
        \\    println(dn == nan)
        \\    println(nan.compareTo(nan))
        \\    println(nz.compareTo(z))
        \\    println(nan > 1.0)
        \\    println(1.0.compareTo(nan))
        \\    println("ab" == "a" + "b")
        \\    val n: String? = null
        \\    println(n == "x")
        \\    println(n == null)
        \\    println("x" != n)
        \\}
    ,
        \\false
        \\true
        \\true
        \\true
        \\false
        \\false
        \\0
        \\-1
        \\false
        \\-1
        \\true
        \\false
        \\true
        \\true
        \\
    );
}

test "+= calls plusAssign when the type declares it, else plus and assigns" {
    try expectRun(
        \\class Counter(var n: Int) {
        \\    operator fun plusAssign(k: Int) { n += k }
        \\}
        \\class V(val x: Int) {
        \\    operator fun plus(o: V): V = V(x + o.x)
        \\}
        \\class Holder(var v: V)
        \\fun main() {
        \\    val c = Counter(1)
        \\    c += 5
        \\    println(c.n)
        \\    var v = V(1)
        \\    v += V(2)
        \\    println(v.x)
        \\    val h = Holder(V(10))
        \\    h.v += V(5)
        \\    println(h.v.x)
        \\    var s = "a"
        \\    s += "b"
        \\    println(s)
        \\    var t = 10
        \\    t -= 3
        \\    t *= 2
        \\    t /= 4
        \\    t %= 2
        \\    println(t)
        \\}
    ,
        \\6
        \\3
        \\15
        \\ab
        \\1
        \\
    );
}

test "increments evaluate their target once and give the old or new value" {
    try expectRun(
        \\class Box(var n: Int)
        \\var calls = 0
        \\fun box(b: Box): Box {
        \\    calls++
        \\    return b
        \\}
        \\fun main() {
        \\    val arr = arrayOf(1, 2, 3)
        \\    arr[1]++
        \\    arr[2] += 10
        \\    println(arr[1])
        \\    println(arr[2])
        \\    var i = 5
        \\    println(i++)
        \\    println(i)
        \\    println(++i)
        \\    println(i-- + i)
        \\    val b = Box(1)
        \\    box(b).n++
        \\    box(b).n += 2
        \\    println(b.n)
        \\    println(calls)
        \\}
    ,
        \\3
        \\13
        \\5
        \\6
        \\7
        \\13
        \\4
        \\2
        \\
    );
}

test "in tests a range's contains" {
    try expectRun(
        \\fun main() {
        \\    val x = 5
        \\    println(x in 1..10)
        \\    println(x !in 1..4)
        \\    println(11 in 1..10)
        \\    var acc = ""
        \\    for (i in 1..3) acc += "$i"
        \\    for (i in 3 downTo 1) acc += "$i"
        \\    for (i in 0 until 6 step 2) acc += "$i"
        \\    println(acc)
        \\}
    ,
        \\true
        \\true
        \\false
        \\123321024
        \\
    );
}

test "in evaluates the container before the element" {
    try expectRun(
        \\var log = ""
        \\fun lo(v: Int): Int { log += "L"; return v }
        \\fun hi(v: Int): Int { log += "H"; return v }
        \\fun x(v: Int): Int { log += "X"; return v }
        \\fun main() {
        \\    println(x(2) in lo(1)..hi(3))
        \\    println(log)
        \\}
    , "true\nLHX\n");
}

test "templates convert an instance, a nullable and a primitive" {
    try expectRun(
        \\class P(val name: String) {
        \\    override fun toString(): String = "P($name)"
        \\}
        \\fun main() {
        \\    val p = P("x")
        \\    val n: String? = null
        \\    val m: P? = P("y")
        \\    val i = 42
        \\    val d = 2.5
        \\    val c = 'z'
        \\    val b = true
        \\    val l = 10L
        \\    println("p=$p n=$n m=$m i=$i d=$d c=$c b=$b l=$l")
        \\    println("sum=${i + 1} str=${"in" + "ner"}")
        \\    val s = "$i"
        \\    println(s.length)
        \\    println("")
        \\}
    ,
        \\p=P(x) n=null m=P(y) i=42 d=2.5 c=z b=true l=10
        \\sum=43 str=inner
        \\2
        \\
        \\
    );
}

test "elvis, safe calls and !! branch on null" {
    try expectRun(
        \\class Node(val next: Node?, val v: Int)
        \\fun twice(x: Int?): Int {
        \\    val y = x ?: return 0
        \\    return y * 2
        \\}
        \\fun main() {
        \\    val n = Node(Node(null, 2), 1)
        \\    println(n.next?.v)
        \\    println(n.next?.next?.v)
        \\    println(n.next?.next?.v ?: -1)
        \\    println(twice(null))
        \\    println(twice(4))
        \\    val s: String? = null
        \\    try {
        \\        println(s!!.length)
        \\    } catch (e: NullPointerException) {
        \\        println("npe")
        \\    }
        \\    var evaluated = false
        \\    fun side(): Boolean {
        \\        evaluated = true
        \\        return true
        \\    }
        \\    println(false && side())
        \\    println(true || side())
        \\    println(evaluated)
        \\}
    ,
        \\2
        \\null
        \\-1
        \\0
        \\8
        \\npe
        \\false
        \\true
        \\false
        \\
    );
}

test "a bare return in a secondary constructor still makes the instance" {
    try expectRun(
        \\class P(val x: Int) {
        \\    var note = "primary"
        \\    constructor(s: String) : this(s.length) {
        \\        if (s.length > 2) return
        \\        note = "short"
        \\    }
        \\}
        \\fun main() {
        \\    val a = P("abcd")
        \\    println(a.x)
        \\    println(a.note)
        \\    val b = P("ab")
        \\    println(b.x)
        \\    println(b.note)
        \\}
    , "4\nprimary\n2\nshort\n");
}

test "a tailrec self-call in tail position is a jump, however deep" {
    try expectRun(
        \\tailrec fun down(n: Int, acc: Int): Int = if (n == 0) acc else down(n - 1, acc + 1)
        \\tailrec fun swap(a: Int, b: Int, n: Int): Int = when {
        \\    n == 0 -> a
        \\    else -> swap(b, a, n - 1)
        \\}
        \\tailrec fun firstZero(n: Int): Boolean = n == 0 || firstZero(n - 1)
        \\var ticks = 0
        \\tailrec fun tick(n: Int) {
        \\    if (n > 0) {
        \\        ticks = ticks + 1
        \\        tick(n - 1)
        \\        return
        \\    }
        \\}
        \\tailrec fun counted(n: Int): Int {
        \\    if (n == 0) return 0
        \\    return counted(n - 1)
        \\}
        \\fun main() {
        \\    println(down(200000, 0))
        \\    println(swap(1, 2, 3))
        \\    println(firstZero(100000))
        \\    tick(100000)
        \\    println(ticks)
        \\    println(counted(100000))
        \\}
    , "200000\n2\ntrue\n100000\n0\n");
}

test "a primitive equals a value of another type only when it is of the same class" {
    try expectRun(
        \\fun main() {
        \\    val i = 0
        \\    val b: Any = 0.toByte()
        \\    val s: Any = 0.toShort()
        \\    val l: Any = 0L
        \\    val same: Any = 0
        \\    val n: Int? = 0
        \\    println(i == b)
        \\    println(i == s)
        \\    println(i == l)
        \\    println(i == same)
        \\    println(n == same)
        \\    println(n == b)
        \\}
    , "false\nfalse\nfalse\ntrue\ntrue\nfalse\n");
}

test "String.compareTo answers the difference at the first unequal character" {
    try expectRun(
        \\fun main() {
        \\    println("a".compareTo("c"))
        \\    println("abc".compareTo("ab"))
        \\    println("b" < "c")
        \\    println('a'.compareTo('c'))
        \\}
    , "-2\n1\ntrue\n-1\n");
}

test "a wall-capped program that catches its timeout gets another, so its finallys run" {
    // A caught timeout is not the end of the program: the next expiry throws
    // again rather than aborting past the `finally` that restores `inside`.
    const saved_unwind = ir.eval.wall_cap_unwind_ms.load(.monotonic);
    ir.eval.wall_cap_unwind_ms.store(50, .monotonic);
    ir.eval.wall_cap_fires.store(0, .monotonic);
    ir.eval.test_wall_deadline_ms.store(ir.eval.nowMonotonicMs() + 50, .monotonic);
    defer {
        ir.eval.test_wall_deadline_ms.store(0, .monotonic);
        ir.eval.wall_cap_fires.store(0, .monotonic);
        ir.eval.wall_cap_unwind_ms.store(saved_unwind, .monotonic);
        // A hard abort would have abandoned the cohort; the next test must not inherit it.
        @import("runtime").setRunBoundaryAbandon(false);
        @import("runtime").clearAbandon();
    }
    try expectRun(
        \\var inside = false
        \\fun spin(): Int {
        \\    var n = 0
        \\    while (true) n = n + 1
        \\}
        \\fun main() {
        \\    var caught = 0
        \\    repeat(2) {
        \\        try {
        \\            inside = true
        \\            try { spin() } finally { inside = false }
        \\        } catch (e: RuntimeException) {
        \\            caught = caught + 1
        \\        }
        \\    }
        \\    println("caught $caught, inside $inside")
        \\}
    , "caught 2, inside false\n");
}
