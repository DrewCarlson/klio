//! The lowering census: runs the bridge and lowering from sema over every
//! body of an analysis, without executing anything, and sorts what failed
//! by kind. `klio sema --lower` prints it; driving it to zero over the base
//! and the packs is what makes real programs runnable on the new pipeline.

const std = @import("std");
const span = @import("span");
const sema = @import("sema");
const ir = @import("ir");
const runtime = @import("runtime");

const Allocator = std.mem.Allocator;
const bridge = ir.bridge;
const lower = ir.lower_sema;
const Sym = sema.Sym;

pub const Kind = enum {
    /// A node without the record its construct needs (sema's gap).
    unrecorded,
    /// A construct no lowering package handles yet.
    unsupported,
    /// A declaration the bridge gave no identity, slot or storage.
    bridge,
    /// Any other lowering error.
    lowering,
    /// A bodyless declaration no native binds.
    unbound_native,
};

pub const n_kinds = std.meta.fields(Kind).len;

pub const Entry = struct {
    kind: Kind,
    /// The failing function's display FQN.
    func: []const u8,
    /// `path:line:col`, or empty.
    where: []const u8,
    msg: []const u8,
    /// The source file of the failure, for a per-library breakdown; none
    /// when unknown.
    file: ?u32 = null,
};

pub const Result = struct {
    /// Bodies the program tried to lower, and those it did.
    bodies: u32 = 0,
    lowered: u32 = 0,
    counts: [n_kinds]u32 = @splat(0),
    entries: []const Entry = &.{},
};

/// Bridges and lowers `s`'s bodies in `files` (all when empty), binding
/// bodyless declarations through `natives`, and returns what failed. `map`
/// locates spans; `records` is `sema.output.build(s).files`.
pub fn run(a: Allocator, s: *sema.Sema, map: *const span.SourceMap, records: []const sema.output.FileRecords, layers: []const bridge.Layer, files: []const u32, binding: @import("pipeline.zig").Binding) !Result {
    const saved_perm = runtime.gc.alloc_perm;
    runtime.gc.alloc_perm = true;
    defer runtime.gc.alloc_perm = saved_perm;
    const br = try bridge.build(a, s, .{ .natives = binding.natives, .host_symbol = binding.host_symbol, .host_members = binding.host_members, .spread_varargs = binding.spread_varargs, .constructors = binding.constructors, .host_fns = binding.host_fns, .host_tries = binding.host_tries, .records = records, .layers = layers, .files = files });
    const prog = try lower.lowerProgram(a, s, br);

    var out: Result = .{};
    var entries: std.ArrayList(Entry) = .empty;
    const n = br.origin.len;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const f = ir.FuncId.from(i);
        if (i < prog.attempted.bit_length and prog.attempted.isSet(i)) {
            out.bodies += 1;
            if (prog.isLowered(f)) out.lowered += 1;
        }
        if (try unbound(s, br, &prog, f)) |sym| {
            const e: Entry = .{ .kind = .unbound_native, .func = br.m.funcs.items[i].fqn, .where = try declWhere(a, s, map, sym), .msg = "no native binds this bodyless declaration", .file = if (s.fileOf(s.syms.get(sym).file)) |fc| fc.ast.span.file.int() else null };
            try entries.append(a, e);
            out.counts[@intFromEnum(Kind.unbound_native)] += 1;
        }
    }
    for (prog.errors.items) |le| {
        const k = classify(le.msg);
        out.counts[@intFromEnum(k)] += 1;
        try entries.append(a, .{
            .kind = k,
            .func = br.m.funcs.items[le.func.int()].fqn,
            .where = try spanWhere(a, map, le.span),
            .msg = le.msg,
            .file = le.span.file.int(),
        });
    }
    out.entries = entries.items;
    return out;
}

/// What kind of failure a lowering error's message reports.
pub fn classify(msg: []const u8) Kind {
    if (std.mem.startsWith(u8, msg, "node ") and std.mem.endsWith(u8, msg, " record")) return .unrecorded;
    if (std.mem.eql(u8, msg, "this construct is not lowered")) return .unsupported;
    const bridge_marks = [_][]const u8{ "has no identity", "has no id", "has no class id", "no method slot", "has no storage", "has no getter", "has no setter", "has no field", "has no SAM", "has no defaults bridge", "no class in the tables", "has no capture slots", "has no outer slot" };
    for (bridge_marks) |mark| if (std.mem.indexOf(u8, msg, mark) != null) return .bridge;
    return .lowering;
}

/// The declaration a `FuncId` runs when it is bodyless, abstract-free, and
/// neither a native nor an operation of the primitive table binds it: a
/// function, or the accessor of an `expect` or `external` property, which
/// reports the property.
fn unbound(s: *sema.Sema, br: *const bridge.Bridge, prog: *const lower.Program, f: ir.FuncId) !?Sym {
    const i = f.int();
    if (br.m.resolved) |r| if (i < r.func_native.len and r.func_native[i] != .none) return null;
    const sym = switch (br.origin[i]) {
        .decl => |d| d,
        .getter, .setter => |prop| {
            if (!lower.body.bodylessAccessor(s, prop, br.origin[i] == .setter)) return null;
            return if (try noActualByDesign(s, prop)) null else prop;
        },
        else => return null,
    };
    if (s.syms.kind(sym) != .function) return null;
    const fl = s.syms.flags(sym);
    if (fl.has_body or fl.synthetic or fl.modality == .abstract) return null;
    if (prog.prims.get(sym) != null) return null;
    // The lowering makes these at each call.
    if (lower.call.enumIntrinsicOf(s, sym) != null) return null;
    if (try noActualByDesign(s, sym)) return null;
    return sym;
}

/// Whether `sym` is an `expect` its declaration marks as having no actual,
/// `@Suppress("NO_ACTUAL_FOR_EXPECT")`: kotlinc's own marker for an expect
/// that every use resolves past. The compose runtime's
/// `AbstractMutableList<*>.modCount` is one. On the JVM each use inside a
/// subclass resolves to `java.util.AbstractList`'s protected `modCount`
/// field, and in klio to `kotlin.collections.AbstractMutableList`'s
/// protected `modCount`, a member, which wins over the extension; so the
/// expect is never reached and no platform supplies an actual for it.
fn noActualByDesign(s: *sema.Sema, sym: Sym) !bool {
    if (!s.syms.flags(sym).expect) return false;
    const anns = switch (s.syms.get(sym).decl) {
        .property => |pd| pd.annotations,
        .function => |fd| fd.annotations,
        else => return false,
    };
    const suppress = s.classByFqn("kotlin.Suppress");
    if (suppress == .none) return false;
    const ctx: sema.headers.TypeCtx = .{ .decl = sym, .file = s.syms.get(sym).file };
    for (anns) |*ann| {
        if (try sema.headers.annotationClass(s, ctx, ann) != suppress) continue;
        for (ann.args) |*arg| {
            const t = switch (arg.*) {
                .StringTemplate => |t| t,
                else => continue,
            };
            if (t.parts.len == 1 and t.parts[0] == .Text and std.mem.eql(u8, t.parts[0].Text, "NO_ACTUAL_FOR_EXPECT")) return true;
        }
    }
    return false;
}

fn declWhere(a: Allocator, s: *sema.Sema, map: *const span.SourceMap, sym: Sym) ![]const u8 {
    const sp: span.Span = switch (s.syms.get(sym).decl) {
        .function => |fd| fd.span,
        .property => |pd| pd.span,
        else => return "",
    };
    return spanWhere(a, map, sp);
}

fn spanWhere(a: Allocator, map: *const span.SourceMap, sp: span.Span) ![]const u8 {
    const src = map.getChecked(sp.file) orelse return "";
    const lc = src.lineCol(sp.start);
    return std.fmt.allocPrint(a, "{s}:{d}:{d}", .{ src.path, lc.line, lc.col });
}

/// Prints the census: totals, counts by kind, and for each kind the most
/// frequent messages (node ids folded) with an example each, then the
/// first `sites` entries of each kind.
pub fn print(a: Allocator, w: *std.ArrayList(u8), r: Result, sites: usize) !void {
    try w.print(a, "[lower] bodies {d}, lowered {d}, failed {d}\n", .{ r.bodies, r.lowered, r.bodies - r.lowered });
    for (0..n_kinds) |k| try w.print(a, "[lower] {s}: {d}\n", .{ @tagName(@as(Kind, @enumFromInt(k))), r.counts[k] });
    for (0..n_kinds) |k| {
        const kind: Kind = @enumFromInt(k);
        if (r.counts[k] == 0) continue;
        var groups: std.StringArrayHashMapUnmanaged(struct { n: u32, first: Entry }) = .empty;
        for (r.entries) |e| {
            if (e.kind != kind) continue;
            const key = try fold(a, if (kind == .unbound_native) e.func else e.msg);
            const gop = try groups.getOrPut(a, key);
            if (!gop.found_existing) gop.value_ptr.* = .{ .n = 0, .first = e };
            gop.value_ptr.n += 1;
        }
        const Item = struct { key: []const u8, n: u32, first: Entry };
        var items: std.ArrayList(Item) = .empty;
        var it = groups.iterator();
        while (it.next()) |g| try items.append(a, .{ .key = g.key_ptr.*, .n = g.value_ptr.n, .first = g.value_ptr.first });
        std.mem.sort(Item, items.items, {}, struct {
            fn lt(_: void, x: Item, y: Item) bool {
                if (x.n != y.n) return x.n > y.n;
                return std.mem.lessThan(u8, x.key, y.key);
            }
        }.lt);
        try w.print(a, "\n[lower] {s}, by message:\n", .{@tagName(kind)});
        for (items.items, 0..) |item, j| {
            if (j >= sites) break;
            try w.print(a, "  {d:>5}  {s}\n         e.g. {s} in {s}\n", .{ item.n, item.key, item.first.where, item.first.func });
        }
    }
    // Then each failure as a site, `lower_<kind> path:line:col: what`, the
    // first `sites` of each kind: the lines a census gate lists.
    var shown: [n_kinds]usize = @splat(0);
    for (r.entries) |e| {
        if (e.where.len == 0) continue;
        const k = @intFromEnum(e.kind);
        if (shown[k] >= sites) continue;
        shown[k] += 1;
        try w.print(a, "  lower_{s} {s}: {s}\n", .{ @tagName(e.kind), e.where, if (e.kind == .unbound_native) e.func else e.msg });
    }
}

/// A message with its node ids and numbers folded, so one gap groups.
pub fn fold(a: Allocator, msg: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < msg.len) {
        if (std.ascii.isDigit(msg[i])) {
            try out.append(a, 'N');
            while (i < msg.len and std.ascii.isDigit(msg[i])) i += 1;
            continue;
        }
        try out.append(a, msg[i]);
        i += 1;
    }
    return out.items;
}

test "the census lists each failure as a site a gate can match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Result = .{ .bodies = 3, .lowered = 2 };
    r.counts[@intFromEnum(Kind.bridge)] = 1;
    r.counts[@intFromEnum(Kind.unbound_native)] = 1;
    r.entries = &.{
        .{ .kind = .bridge, .func = "p.stop$default", .where = "src/E.kt:48:35", .msg = "`engineConfig` has no getter" },
        .{ .kind = .unbound_native, .func = "p.Digest", .where = "src/D.kt:7:1", .msg = "no native binds this bodyless declaration" },
    };
    var out: std.ArrayList(u8) = .empty;
    try print(a, &out, r, 100);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "  lower_bridge src/E.kt:48:35: `engineConfig` has no getter\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "  lower_unbound_native src/D.kt:7:1: p.Digest\n") != null);
}

test "an expect property without an actual is a bodyless declaration no native binds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const driver = @import("lower_driver.zig");
    const an = try driver.analyze(a, &.{
        \\package demo
        \\expect val unbound: Int
        \\expect var String.tally: Int
        \\@Suppress("NO_ACTUAL_FOR_EXPECT")
        \\expect var String.designed: Int
        \\fun main() {}
    });
    const files = [_]u32{an.baseFiles()};
    const r = try run(a, an.s, &an.map, an.out.files, &an.layers, &files, .{ .natives = driver.natives.resolve });
    var got: std.ArrayList(u8) = .empty;
    for (r.entries) |e| try got.print(a, "{s} {s} {s}\n", .{ @tagName(e.kind), e.where, e.func });
    // No accessor lowers over storage the expect never had; each of the
    // expect's accessors is bodyless, and the one kotlinc's marker says has
    // no actual by design is not reported.
    try std.testing.expectEqualStrings(
        "unbound_native test0.kt:2:8 demo.unbound.<get>\n" ++
            "unbound_native test0.kt:3:8 demo.tally.<get>\n" ++
            "unbound_native test0.kt:3:8 demo.tally.<set>\n",
        got.items,
    );
}

test "a lowering error's message says its kind" {
    try std.testing.expectEqual(Kind.unrecorded, classify("node 12 (Call) has no call record"));
    try std.testing.expectEqual(Kind.unsupported, classify("this construct is not lowered"));
    try std.testing.expectEqual(Kind.bridge, classify("`f` has no identity to call"));
    try std.testing.expectEqual(Kind.lowering, classify("`super` is not a value"));
}
