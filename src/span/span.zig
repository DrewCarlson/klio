//! Source positions and file tracking.
const std = @import("std");

/// Identifies a source file within a `SourceMap`.
pub const FileId = enum(u32) {
    _,
    pub fn from(v: u32) FileId {
        return @enumFromInt(v);
    }
    pub fn int(self: FileId) u32 {
        return @intFromEnum(self);
    }
};

/// Sentinel `FileId.int()` the stdlib-image baker stamps on a deferred
/// `inline`-function body marker: the empty block's `span.start` then holds the
/// body's byte offset in the image's deferred-body section. Far above any real
/// SourceMap id, so it can never collide with a genuine file.
pub const DEFERRED_BODY_FILE: u32 = 0xDEFE_4DED;

/// A half-open byte range within a single source file.
pub const Span = struct {
    file: FileId,
    start: u32,
    end: u32,

    pub fn init(file: FileId, start: u32, end: u32) Span {
        std.debug.assert(start <= end);
        return .{ .file = file, .start = start, .end = end };
    }

    pub fn len(self: Span) u32 {
        return self.end - self.start;
    }

    /// The source text covered by this span.
    pub fn text(self: Span, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }

    /// Smallest span covering both `self` and `other` (same file).
    pub fn join(self: Span, other: Span) Span {
        std.debug.assert(self.file == other.file);
        return .{
            .file = self.file,
            .start = @min(self.start, other.start),
            .end = @max(self.end, other.end),
        };
    }

    pub fn eql(self: Span, other: Span) bool {
        return self.file == other.file and self.start == other.start and self.end == other.end;
    }
};

pub const LineCol = struct { line: u32, col: u32 };

pub const SourceFile = struct {
    id: FileId,
    path: []const u8,
    source: []const u8,
    line_starts: []const u32,

    pub fn init(
        allocator: std.mem.Allocator,
        id: FileId,
        path: []const u8,
        source: []const u8,
    ) !SourceFile {
        var starts: std.ArrayList(u32) = .empty;
        errdefer starts.deinit(allocator);
        try starts.append(allocator, 0);
        for (source, 0..) |b, i| {
            if (b == '\n') try starts.append(allocator, @intCast(i + 1));
        }
        return .{
            .id = id,
            .path = path,
            .source = source,
            .line_starts = try starts.toOwnedSlice(allocator),
        };
    }

    /// 1-based line and column for a byte offset.
    pub fn lineCol(self: SourceFile, offset: u32) LineCol {
        var lo: usize = 0;
        var hi: usize = self.line_starts.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.line_starts[mid] <= offset) lo = mid + 1 else hi = mid;
        }
        const line = lo - 1;
        const col = offset - self.line_starts[line];
        return .{ .line = @intCast(line + 1), .col = col + 1 };
    }
};

pub const SourceMap = struct {
    arena: std.heap.ArenaAllocator,
    files: std.ArrayList(SourceFile),

    pub fn init(gpa: std.mem.Allocator) SourceMap {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa), .files = .empty };
    }

    pub fn deinit(self: *SourceMap) void {
        self.arena.deinit();
    }

    pub fn add(self: *SourceMap, path: []const u8, source: []const u8) !FileId {
        const a = self.arena.allocator();
        const id = FileId.from(@intCast(self.files.items.len));
        const path_owned = try a.dupe(u8, path);
        const source_owned = try a.dupe(u8, source);
        const sf = try SourceFile.init(a, id, path_owned, source_owned);
        try self.files.append(a, sf);
        return id;
    }

    pub fn get(self: *const SourceMap, id: FileId) *const SourceFile {
        return &self.files.items[id.int()];
    }
};

test "span join extends range" {
    const f = FileId.from(0);
    const a = Span.init(f, 0, 3);
    const b = Span.init(f, 5, 9);
    try std.testing.expect(a.join(b).eql(Span.init(f, 0, 9)));
}

test "line col resolves offsets" {
    var sm = SourceMap.init(std.testing.allocator);
    defer sm.deinit();
    const id = try sm.add("x.kt", "fun a()\nval b = 1\n");
    const sf = sm.get(id);
    try std.testing.expectEqual(LineCol{ .line = 1, .col = 1 }, sf.lineCol(0));
    try std.testing.expectEqual(LineCol{ .line = 2, .col = 1 }, sf.lineCol(8));
}
