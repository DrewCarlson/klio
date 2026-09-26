//! `@Suppress`: where a file asks for diagnostics of given names not to be
//! reported. kotlinc honors the names on a file (`@file:Suppress`), on any
//! declaration and on an annotated lambda, over everything the annotated
//! element spans; `"warnings"` names every warning. Names compare without
//! regard to case, as kotlinc compares them.

const std = @import("std");
const ast = @import("ast");
const span = @import("span");

const Sema = @import("sema.zig").Sema;
const census = @import("census.zig");

const Allocator = std.mem.Allocator;

/// The offsets `names` are suppressed over, in one file.
pub const Region = struct {
    start: u32,
    end: u32,
    names: []const []const u8,
};

/// The regions of each file, collected on first use.
pub const Suppressions = struct {
    arena: Allocator,
    by_file: std.AutoHashMapUnmanaged(u32, []const Region) = .empty,

    pub fn init(arena: Allocator) Suppressions {
        return .{ .arena = arena };
    }

    /// Whether `site` lies in a region that names its diagnostic, or names
    /// `warnings` and it is one.
    pub fn suppressed(self: *Suppressions, s: *Sema, site: census.Site) Allocator.Error!bool {
        const regions = try self.regionsOf(s, site.file);
        const name = census.factoryOf(site);
        for (regions) |r| {
            if (site.sp.start < r.start or site.sp.end > r.end) continue;
            for (r.names) |n| {
                if (std.ascii.eqlIgnoreCase(n, name)) return true;
                if (site.severity == .warning and std.ascii.eqlIgnoreCase(n, "warnings")) return true;
            }
        }
        return false;
    }

    fn regionsOf(self: *Suppressions, s: *Sema, file: u32) Allocator.Error![]const Region {
        if (self.by_file.get(file)) |r| return r;
        const fc = s.fileOf(file) orelse return &.{};
        const regions = try collect(self.arena, fc.ast);
        try self.by_file.put(self.arena, file, regions);
        return regions;
    }
};

/// Every `@Suppress` region of `file`.
pub fn collect(a: Allocator, file: *const ast.KotlinFile) Allocator.Error![]const Region {
    var c = Collector{ .a = a };
    try c.push(file.file_annotations, 0, std.math.maxInt(u32));
    for (file.decls) |*d| try c.walk(ast.Decl, d);
    return c.out.items;
}

/// Walks the syntax tree by reflection: a node with `annotations` and a
/// `span` is an annotated element.
const Collector = struct {
    a: Allocator,
    out: std.ArrayList(Region) = .empty,

    fn push(self: *Collector, anns: []const ast.Annotation, start: u32, end: u32) Allocator.Error!void {
        for (anns) |*an| {
            if (an.path.len == 0 or !std.mem.eql(u8, an.path[an.path.len - 1].name, "Suppress")) continue;
            var names: std.ArrayList([]const u8) = .empty;
            for (an.args) |*arg| try stringsOf(self.a, arg, &names);
            if (names.items.len != 0) try self.out.append(self.a, .{ .start = start, .end = end, .names = names.items });
        }
    }

    fn walk(self: *Collector, comptime T: type, v: *const T) Allocator.Error!void {
        if (comptime skipped(T)) return;
        switch (@typeInfo(T)) {
            .@"struct" => |st| {
                if (@hasField(T, "annotations") and @hasField(T, "span") and @FieldType(T, "span") == span.Span) {
                    try self.push(v.annotations, v.span.start, v.span.end);
                }
                inline for (st.fields) |f| {
                    if (comptime !std.mem.eql(u8, f.name, "annotations")) try self.walk(f.type, &@field(v.*, f.name));
                }
            },
            .@"union" => switch (v.*) {
                inline else => |*payload| try self.walk(@TypeOf(payload.*), payload),
            },
            .optional => |o| if (v.*) |*x| try self.walk(o.child, x),
            .pointer => |p| switch (p.size) {
                .one => try self.walk(p.child, v.*),
                .slice => for (v.*) |*x| try self.walk(p.child, x),
                else => @compileError("unexpected pointer in an AST node: " ++ @typeName(T)),
            },
            else => {},
        }
    }
};

/// A type that holds no annotated element.
fn skipped(comptime T: type) bool {
    if (T == span.Span or T == ast.Ident or T == ast.NodeId or T == ast.Annotation) return true;
    return switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum", .void => true,
        .optional => |o| skipped(o.child),
        .pointer => |p| p.size == .slice and skipped(p.child),
        else => false,
    };
}

/// The string literals of a `@Suppress` argument: one string, or the
/// elements of a spread `arrayOf`.
fn stringsOf(a: Allocator, e: *const ast.Expr, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    switch (e.*) {
        .StringTemplate => |t| {
            var buf: std.ArrayList(u8) = .empty;
            for (t.parts) |part| switch (part) {
                .Text => |text| try buf.appendSlice(a, text),
                else => return,
            };
            try out.append(a, buf.items);
        },
        .Spread => |x| try stringsOf(a, x.expr, out),
        .Call => |c| for (c.args) |*arg| try stringsOf(a, arg, out),
        else => {},
    }
}
