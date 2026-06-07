//! Emit the encoded symbol index consumed by `stdlib`.

const std = @import("std");

const pack = @import("pack");
const schema = pack.schema;
const PackError = pack.PackError;

const parse = @import("parse.zig");
const Decl = parse.Decl;
const DeclKind = parse.DeclKind;
const walk = @import("walk.zig");
const FileDecls = walk.FileDecls;

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const EmitError = error{Encode} || Allocator.Error;

/// Build the symbol index from `files`, encode it, and write
/// `out_dir/symbols.postcard`. Returns the number of unique symbols written.
pub fn emitGenerated(allocator: Allocator, io: Io, out_dir: []const u8, files: []const FileDecls) EmitError!usize {
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, out_dir) catch return error.Encode;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var seen = std.StringHashMap(void).init(arena);
    var entries: std.ArrayList(schema.SymbolRecord) = .empty;
    for (files) |f| {
        for (f.decls) |*d| {
            const key = try std.fmt.allocPrint(arena, "{s}|{s}|{s}|{s}", .{
                d.fqn,
                d.signature,
                @tagName(d.kind),
                f.rel_path,
            });
            const gop = try seen.getOrPut(key);
            if (gop.found_existing) {
                continue;
            }
            try entries.append(arena, declToRecord(d, f.rel_path));
        }
    }
    const count = entries.items.len;
    std.mem.sort(schema.SymbolRecord, entries.items, {}, lessByFqn);

    const index = schema.SymbolIndex{ .entries = entries.items };
    var err: PackError = undefined;
    var bytes = (try schema.encode(schema.SymbolIndex, arena, &index, &err)) orelse return error.Encode;
    defer bytes.deinit(arena);

    const out_path = try std.fs.path.join(arena, &.{ out_dir, "symbols.postcard" });
    cwd.writeFile(io, .{ .sub_path = out_path, .data = bytes.items }) catch return error.Encode;
    return count;
}

fn declToRecord(d: *const Decl, rel: []const u8) schema.SymbolRecord {
    const kind: schema.SymbolKind = switch (d.kind) {
        .Function => .Function,
        .Property => .Property,
        .Class => .Class,
        .Interface => .Interface,
        .Object => .Object,
        .TypeAlias => .TypeAlias,
    };
    const package = rsplitPackage(d.fqn);
    return .{
        .fqn = d.fqn,
        .package = package,
        .name = d.name,
        .kind = kind,
        .receiver = d.receiver,
        .signature = d.signature,
        .param_names = d.param_names,
        .modifiers = schema.ModifierBits.fromBits(d.modifiers),
        .source = .{
            .path = rel,
            .line = d.line,
            .column = d.column,
        },
    };
}

/// Everything before the last `.` of `fqn`, or empty when there is no `.`.
/// Returns a slice into `fqn`.
fn rsplitPackage(fqn: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, fqn, '.')) |idx| {
        return fqn[0..idx];
    }
    return "";
}

fn lessByFqn(_: void, a: schema.SymbolRecord, b: schema.SymbolRecord) bool {
    return std.mem.order(u8, a.fqn, b.fqn) == .lt;
}

const testing = std.testing;

test "rsplitPackage splits off the trailing name" {
    try testing.expectEqualStrings("kotlin.collections", rsplitPackage("kotlin.collections.listOf"));
    try testing.expectEqualStrings("", rsplitPackage("println"));
}

test "declToRecord maps kind and modifiers" {
    var params = [_][]const u8{"x"};
    const d = Decl{
        .kind = .Function,
        .name = "foo",
        .fqn = "kotlin.foo",
        .parent = null,
        .receiver = null,
        .modifiers = parse.modflag.PUBLIC | parse.modflag.INLINE,
        .signature = "fun foo",
        .param_names = params[0..],
        .line = 3,
        .column = 1,
    };
    const r = declToRecord(&d, "src/kotlin/Foo.kt");
    try testing.expectEqual(schema.SymbolKind.Function, r.kind);
    try testing.expectEqualStrings("kotlin", r.package);
    try testing.expect(r.modifiers.PUBLIC);
    try testing.expect(r.modifiers.INLINE);
    try testing.expect(r.source != null);
    try testing.expectEqual(@as(u32, 3), r.source.?.line);
}

test "emitGenerated writes a decodable symbols index" {
    const a = testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(out_dir);

    var params0 = [_][]const u8{"message"};
    var decls = [_]Decl{.{
        .kind = .Function,
        .name = "println",
        .fqn = "kotlin.io.println",
        .parent = null,
        .receiver = null,
        .modifiers = parse.modflag.PUBLIC,
        .signature = "fun println",
        .param_names = params0[0..],
        .line = 1,
        .column = 1,
    }};
    const files = [_]FileDecls{.{
        .rel_path = "src/kotlin/io/Console.kt",
        .package = "kotlin.io",
        .decls = decls[0..],
    }};

    const n = try emitGenerated(a, io, out_dir, files[0..]);
    try testing.expectEqual(@as(usize, 1), n);

    const out_path = try std.fs.path.join(a, &.{ out_dir, "symbols.postcard" });
    defer a.free(out_path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, out_path, a, .unlimited);
    defer a.free(bytes);

    var err: PackError = undefined;
    var decoded = (try schema.decode(schema.SymbolIndex, a, bytes, &err)).?;
    defer decoded.deinit(a);
    try testing.expectEqual(@as(usize, 1), decoded.entries.len);
    try testing.expectEqualStrings("kotlin.io.println", decoded.entries[0].fqn);
    try testing.expectEqualStrings("kotlin.io", decoded.entries[0].package);
}

test "emitGenerated dedups identical decls" {
    const a = testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(out_dir);

    var decls = [_]Decl{
        .{
            .kind = .Function,
            .name = "foo",
            .fqn = "kotlin.foo",
            .parent = null,
            .receiver = null,
            .modifiers = 0,
            .signature = "fun foo",
            .param_names = &.{},
            .line = 1,
            .column = 1,
        },
        .{
            .kind = .Function,
            .name = "foo",
            .fqn = "kotlin.foo",
            .parent = null,
            .receiver = null,
            .modifiers = 0,
            .signature = "fun foo",
            .param_names = &.{},
            .line = 1,
            .column = 1,
        },
    };
    const files = [_]FileDecls{.{
        .rel_path = "src/kotlin/Foo.kt",
        .package = "kotlin",
        .decls = decls[0..],
    }};

    const n = try emitGenerated(a, io, out_dir, files[0..]);
    try testing.expectEqual(@as(usize, 1), n);
}
