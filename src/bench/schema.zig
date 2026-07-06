//! Stable JSON schema for bench records + baseline diffing.

const std = @import("std");

pub const BenchRecord = struct {
    stage: []const u8,
    workload: []const u8,
    median_ns: u64,
    p99_ns: u64,
    iters: u64,
    allocs: ?u64 = null,
    alloc_bytes: ?u64 = null,
    ref_kotlinc_native_ns: ?u64 = null,
    ref_kotlinc_jvm_ns: ?u64 = null,

    /// Serialize one record as a JSON object; null optionals are omitted
    /// from the output.
    pub fn writeJson(self: *const BenchRecord, w: *std.Io.Writer, indent: usize) std.Io.Writer.Error!void {
        try writeIndent(w, indent);
        try w.writeAll("{\n");
        try writeStrField(w, indent + 1, "stage", self.stage, true);
        try writeStrField(w, indent + 1, "workload", self.workload, true);
        try writeU64Field(w, indent + 1, "median_ns", self.median_ns, true);
        try writeU64Field(w, indent + 1, "p99_ns", self.p99_ns, true);

        // The trailing optional fields are emitted only when present; the
        // last present field must not carry a comma. Iters is always last
        // of the mandatory group, so its comma depends on whether any
        // optional follows.
        const has_opt = self.allocs != null or self.alloc_bytes != null or
            self.ref_kotlinc_native_ns != null or self.ref_kotlinc_jvm_ns != null;
        try writeU64Field(w, indent + 1, "iters", self.iters, has_opt);

        var remaining: usize = 0;
        if (self.allocs != null) remaining += 1;
        if (self.alloc_bytes != null) remaining += 1;
        if (self.ref_kotlinc_native_ns != null) remaining += 1;
        if (self.ref_kotlinc_jvm_ns != null) remaining += 1;

        if (self.allocs) |v| {
            remaining -= 1;
            try writeU64Field(w, indent + 1, "allocs", v, remaining > 0);
        }
        if (self.alloc_bytes) |v| {
            remaining -= 1;
            try writeU64Field(w, indent + 1, "alloc_bytes", v, remaining > 0);
        }
        if (self.ref_kotlinc_native_ns) |v| {
            remaining -= 1;
            try writeU64Field(w, indent + 1, "ref_kotlinc_native_ns", v, remaining > 0);
        }
        if (self.ref_kotlinc_jvm_ns) |v| {
            remaining -= 1;
            try writeU64Field(w, indent + 1, "ref_kotlinc_jvm_ns", v, remaining > 0);
        }

        try writeIndent(w, indent);
        try w.writeAll("}");
    }
};

pub const BenchReport = struct {
    git_sha: []const u8,
    host: []const u8,
    records: []const BenchRecord,

    /// Emit `serde_json::to_string_pretty`-compatible JSON (2-space indent).
    pub fn writeJson(self: *const BenchReport, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("{\n");
        try writeStrField(w, 1, "git_sha", self.git_sha, true);
        try writeStrField(w, 1, "host", self.host, true);
        try writeIndent(w, 1);
        if (self.records.len == 0) {
            try w.writeAll("\"records\": []\n");
        } else {
            try w.writeAll("\"records\": [\n");
            for (self.records, 0..) |*rec, i| {
                try rec.writeJson(w, 2);
                if (i + 1 < self.records.len) try w.writeAll(",");
                try w.writeAll("\n");
            }
            try writeIndent(w, 1);
            try w.writeAll("]\n");
        }
        try w.writeAll("}");
    }
};

fn writeIndent(w: *std.Io.Writer, indent: usize) std.Io.Writer.Error!void {
    var i: usize = 0;
    while (i < indent) : (i += 1) try w.writeAll("  ");
}

fn writeStrField(w: *std.Io.Writer, indent: usize, name: []const u8, value: []const u8, comma: bool) std.Io.Writer.Error!void {
    try writeIndent(w, indent);
    try w.print("\"{s}\": ", .{name});
    try writeJsonString(w, value);
    if (comma) try w.writeAll(",");
    try w.writeAll("\n");
}

fn writeU64Field(w: *std.Io.Writer, indent: usize, name: []const u8, value: u64, comma: bool) std.Io.Writer.Error!void {
    try writeIndent(w, indent);
    try w.print("\"{s}\": {d}", .{ name, value });
    if (comma) try w.writeAll(",");
    try w.writeAll("\n");
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeAll("\"");
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeAll("\"");
}

pub const RegressionLevel = enum {
    Green,
    Yellow,
    Red,

    pub fn classify(ratio: f64) RegressionLevel {
        if (ratio >= 1.15) {
            return .Red;
        } else if (ratio >= 1.05) {
            return .Yellow;
        } else {
            return .Green;
        }
    }
};

pub const DiffRow = struct {
    stage: []const u8,
    workload: []const u8,
    base_ns: ?u64,
    cur_ns: u64,
    ratio: f64,
    level: RegressionLevel,
};

/// Diff the `median_ns` of `cur` vs. `base`. Returns one row per workload
/// present in `cur` (missing baselines emit ratio 1.0 + Green). The caller
/// owns the returned slice and frees it with the same allocator.
pub fn diff(allocator: std.mem.Allocator, base: *const BenchReport, cur: *const BenchReport) std.mem.Allocator.Error![]DiffRow {
    var rows: std.ArrayList(DiffRow) = .empty;
    errdefer rows.deinit(allocator);
    for (cur.records) |*r| {
        var base_ns: ?u64 = null;
        for (base.records) |*b| {
            if (std.mem.eql(u8, b.stage, r.stage) and std.mem.eql(u8, b.workload, r.workload)) {
                base_ns = b.median_ns;
                break;
            }
        }
        const ratio: f64 = blk: {
            if (base_ns) |b| {
                if (b > 0) {
                    break :blk @as(f64, @floatFromInt(r.median_ns)) / @as(f64, @floatFromInt(b));
                }
            }
            break :blk 1.0;
        };
        try rows.append(allocator, .{
            .stage = r.stage,
            .workload = r.workload,
            .base_ns = base_ns,
            .cur_ns = r.median_ns,
            .ratio = ratio,
            .level = RegressionLevel.classify(ratio),
        });
    }
    return rows.toOwnedSlice(allocator);
}

const testing = std.testing;

test "regression level classifies ratios" {
    try testing.expectEqual(RegressionLevel.Green, RegressionLevel.classify(1.0));
    try testing.expectEqual(RegressionLevel.Green, RegressionLevel.classify(1.04));
    try testing.expectEqual(RegressionLevel.Yellow, RegressionLevel.classify(1.05));
    try testing.expectEqual(RegressionLevel.Yellow, RegressionLevel.classify(1.14));
    try testing.expectEqual(RegressionLevel.Red, RegressionLevel.classify(1.15));
    try testing.expectEqual(RegressionLevel.Red, RegressionLevel.classify(2.0));
}

test "diff reports ratios against baseline" {
    const base_records = [_]BenchRecord{
        .{ .stage = "lex", .workload = "a", .median_ns = 100, .p99_ns = 100, .iters = 1 },
    };
    const cur_records = [_]BenchRecord{
        .{ .stage = "lex", .workload = "a", .median_ns = 200, .p99_ns = 200, .iters = 1 },
        .{ .stage = "lex", .workload = "b", .median_ns = 50, .p99_ns = 50, .iters = 1 },
    };
    const base = BenchReport{ .git_sha = "x", .host = "h", .records = &base_records };
    const cur = BenchReport{ .git_sha = "y", .host = "h", .records = &cur_records };

    const rows = try diff(testing.allocator, &base, &cur);
    defer testing.allocator.free(rows);

    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqual(@as(?u64, 100), rows[0].base_ns);
    try testing.expectEqual(@as(f64, 2.0), rows[0].ratio);
    try testing.expectEqual(RegressionLevel.Red, rows[0].level);
    // Missing baseline → ratio 1.0, Green.
    try testing.expectEqual(@as(?u64, null), rows[1].base_ns);
    try testing.expectEqual(@as(f64, 1.0), rows[1].ratio);
    try testing.expectEqual(RegressionLevel.Green, rows[1].level);
}

test "bench report serializes with skipped optionals" {
    const records = [_]BenchRecord{
        .{ .stage = "e2e", .workload = "g/x", .median_ns = 5, .p99_ns = 9, .iters = 3, .ref_kotlinc_jvm_ns = 42 },
    };
    const report = BenchReport{ .git_sha = "abc", .host = "linux-x86_64", .records = &records };

    var buf: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(testing.allocator, &buf);
    try report.writeJson(&aw.writer);
    buf = aw.toArrayList();
    defer buf.deinit(testing.allocator);

    // Present optionals appear; absent ones are skipped.
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"ref_kotlinc_jvm_ns\": 42") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "allocs") == null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "ref_kotlinc_native_ns") == null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"git_sha\": \"abc\"") != null);
}
