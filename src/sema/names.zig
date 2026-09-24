//! Interned identifiers. Every name sema compares is a `Name`, so a lookup
//! is an integer compare and a symbol table keys on a `u32`.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Name = enum(u32) {
    empty = 0,
    _,

    pub fn int(self: Name) u32 {
        return @intFromEnum(self);
    }
};

/// Names the resolver asks for by construction: operator conventions,
/// synthesized members and the default package roots. Interned first, in
/// this order, so `wk.get` is a constant.
const well_known = [_][]const u8{
    "",
    "invoke",
    "get",
    "set",
    "iterator",
    "hasNext",
    "next",
    "getValue",
    "setValue",
    "provideDelegate",
    "plus",
    "minus",
    "times",
    "div",
    "rem",
    "mod",
    "rangeTo",
    "rangeUntil",
    "contains",
    "compareTo",
    "equals",
    "hashCode",
    "toString",
    "unaryMinus",
    "unaryPlus",
    "not",
    "inc",
    "dec",
    "plusAssign",
    "minusAssign",
    "timesAssign",
    "divAssign",
    "remAssign",
    "Companion",
    "value",
    "field",
    "it",
    "values",
    "valueOf",
    "entries",
    "name",
    "ordinal",
    "copy",
    "<init>",
    "<anonymous>",
    "<root>",
    "kotlin",
    "Any",
    "Nothing",
    "Unit",
    "Int",
    "Long",
    "Short",
    "Byte",
    "Double",
    "Float",
    "Char",
    "Boolean",
    "String",
    "Array",
    "Enum",
    "size",
    "length",
    "and",
    "or",
    "xor",
    "_",
};

pub const wk = struct {
    pub const empty: Name = .empty;
    pub const invoke = at("invoke");
    pub const get = at("get");
    pub const set = at("set");
    pub const iterator = at("iterator");
    pub const hasNext = at("hasNext");
    pub const next = at("next");
    pub const getValue = at("getValue");
    pub const setValue = at("setValue");
    pub const provideDelegate = at("provideDelegate");
    pub const plus = at("plus");
    pub const minus = at("minus");
    pub const times = at("times");
    pub const div = at("div");
    pub const rem = at("rem");
    pub const mod = at("mod");
    pub const rangeTo = at("rangeTo");
    pub const rangeUntil = at("rangeUntil");
    pub const contains = at("contains");
    pub const compareTo = at("compareTo");
    pub const equals = at("equals");
    pub const hashCode = at("hashCode");
    pub const toString = at("toString");
    pub const unaryMinus = at("unaryMinus");
    pub const unaryPlus = at("unaryPlus");
    pub const not = at("not");
    pub const inc = at("inc");
    pub const dec = at("dec");
    pub const plusAssign = at("plusAssign");
    pub const minusAssign = at("minusAssign");
    pub const timesAssign = at("timesAssign");
    pub const divAssign = at("divAssign");
    pub const remAssign = at("remAssign");
    pub const Companion = at("Companion");
    pub const value = at("value");
    pub const field = at("field");
    pub const it = at("it");
    pub const values = at("values");
    pub const valueOf = at("valueOf");
    pub const entries = at("entries");
    pub const name = at("name");
    pub const ordinal = at("ordinal");
    pub const copy = at("copy");
    pub const init = at("<init>");
    pub const anonymous = at("<anonymous>");
    pub const root = at("<root>");
    pub const kotlin = at("kotlin");
    pub const Any = at("Any");
    pub const Nothing = at("Nothing");
    pub const Unit = at("Unit");
    pub const Int = at("Int");
    pub const Long = at("Long");
    pub const Short = at("Short");
    pub const Byte = at("Byte");
    pub const Double = at("Double");
    pub const Float = at("Float");
    pub const Char = at("Char");
    pub const Boolean = at("Boolean");
    pub const String = at("String");
    pub const Array = at("Array");
    pub const Enum = at("Enum");
    pub const size = at("size");
    pub const length = at("length");
    pub const and_ = at("and");
    pub const or_ = at("or");
    pub const xor = at("xor");
    pub const underscore = at("_");

    fn at(comptime s: []const u8) Name {
        inline for (well_known, 0..) |w, i| {
            if (comptime std.mem.eql(u8, w, s)) return @enumFromInt(i);
        }
        @compileError("not a well-known name: " ++ s);
    }
};

pub const Names = struct {
    arena: Allocator,
    map: std.StringHashMapUnmanaged(Name) = .empty,
    strs: std.ArrayList([]const u8) = .empty,

    /// `arena` owns every interned string and the tables; nothing is freed
    /// before the whole analysis is dropped.
    pub fn init(arena: Allocator) Allocator.Error!Names {
        var n = Names{ .arena = arena };
        for (well_known) |w| _ = try n.intern(w);
        return n;
    }

    pub fn intern(self: *Names, s: []const u8) Allocator.Error!Name {
        if (self.map.get(s)) |n| return n;
        const owned = try self.arena.dupe(u8, s);
        const n: Name = @enumFromInt(@as(u32, @intCast(self.strs.items.len)));
        try self.strs.append(self.arena, owned);
        try self.map.put(self.arena, owned, n);
        return n;
    }

    pub fn lookup(self: *const Names, s: []const u8) ?Name {
        return self.map.get(s);
    }

    pub fn str(self: *const Names, n: Name) []const u8 {
        return self.strs.items[n.int()];
    }

    /// `componentN` for a destructuring position counted from 1.
    pub fn component(self: *Names, n: usize) Allocator.Error!Name {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "component{d}", .{n}) catch unreachable;
        return self.intern(s);
    }
};

test "well-known names intern to their constants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var names = try Names.init(arena.allocator());
    try std.testing.expectEqual(wk.get, try names.intern("get"));
    try std.testing.expectEqual(wk.underscore, try names.intern("_"));
    try std.testing.expectEqualStrings("iterator", names.str(wk.iterator));
    const a = try names.intern("frobnicate");
    try std.testing.expectEqual(a, try names.intern("frobnicate"));
    try std.testing.expect(a != wk.get);
    try std.testing.expectEqual(try names.intern("component3"), try names.component(3));
}
