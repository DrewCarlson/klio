//! Minimal SARIF 2.1.0 renderer. Produces a single SARIF run with one
//! result per diagnostic, suitable for GitHub Code Scanning and CodeQL-
//! style aggregators. Schema reference:
//! <https://docs.oasis-open.org/sarif/sarif/v2.1.0/sarif-v2.1.0.html>.

const std = @import("std");
const span = @import("span");
const SourceMap = span.SourceMap;

const diag = @import("../diagnostics.zig");
const Diagnostic = diag.Diagnostic;
const Severity = diag.Severity;

pub fn render(
    allocator: std.mem.Allocator,
    diagnostics: []const Diagnostic,
    sources: *const SourceMap,
    out: *std.ArrayList(u8),
) !void {
    var s: std.ArrayList(u8) = .empty;
    defer s.deinit(allocator);
    try s.appendSlice(allocator, "{\"version\":\"2.1.0\",\"$schema\":\"https://json.schemastore.org/sarif-2.1.0.json\",\"runs\":[{\"tool\":{\"driver\":{");
    try push(allocator, &s, "name", try jsonString(allocator, "klio"));
    try push(allocator, &s, "informationUri", try jsonString(allocator, "https://github.com/DrewCarlson/kt-exp"));
    try push(allocator, &s, "rules", try rulesArray(allocator, diagnostics));
    try s.appendSlice(allocator, "}},\"results\":[");
    for (diagnostics, 0..) |*d, i| {
        if (i > 0) try s.append(allocator, ',');
        const obj = try resultObject(allocator, d, sources);
        defer allocator.free(obj);
        try s.appendSlice(allocator, obj);
    }
    try s.appendSlice(allocator, "]}]}");
    try out.appendSlice(allocator, s.items);
    try out.append(allocator, '\n');
}

pub fn toString(
    allocator: std.mem.Allocator,
    diagnostics: []const Diagnostic,
    sources: *const SourceMap,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try render(allocator, diagnostics, sources, &buf);
    return buf.toOwnedSlice(allocator);
}

fn rulesArray(allocator: std.mem.Allocator, diagnostics: []const Diagnostic) ![]u8 {
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(allocator);
    for (diagnostics) |*d| {
        if (d.code()) |c| {
            if (!contains(seen.items, c)) {
                try seen.append(allocator, c);
            }
        }
    }
    var s: std.ArrayList(u8) = .empty;
    errdefer s.deinit(allocator);
    try s.append(allocator, '[');
    for (seen.items, 0..) |c, i| {
        if (i > 0) try s.append(allocator, ',');
        const id = try jsonString(allocator, c);
        defer allocator.free(id);
        try appendFmt(allocator, &s, "{{\"id\":{s},\"name\":{s}}}", .{ id, id });
    }
    try s.append(allocator, ']');
    return s.toOwnedSlice(allocator);
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| {
        if (std.mem.eql(u8, h, needle)) return true;
    }
    return false;
}

fn resultObject(allocator: std.mem.Allocator, d: *const Diagnostic, sources: *const SourceMap) ![]u8 {
    const file = sources.get(d.primary.span.file);
    const start = file.lineCol(d.primary.span.start);
    const end = file.lineCol(d.primary.span.end);
    const level: []const u8 = switch (d.severity) {
        .Error => "error",
        .StrongWarning, .Warning => "warning",
        .Info, .Hint => "note",
    };
    const rule_id = d.code() orelse "klio.diagnostic";
    var s: std.ArrayList(u8) = .empty;
    errdefer s.deinit(allocator);
    try s.append(allocator, '{');
    try push(allocator, &s, "ruleId", try jsonString(allocator, rule_id));
    try push(allocator, &s, "level", try jsonString(allocator, level));
    {
        const msg = try jsonString(allocator, d.message);
        defer allocator.free(msg);
        const obj = try std.fmt.allocPrint(allocator, "{{\"text\":{s}}}", .{msg});
        try push(allocator, &s, "message", obj);
    }
    {
        const uri = try jsonString(allocator, file.path);
        defer allocator.free(uri);
        const loc = try std.fmt.allocPrint(
            allocator,
            "[{{\"physicalLocation\":{{\"artifactLocation\":{{\"uri\":{s}}},\"region\":{{\"startLine\":{d},\"startColumn\":{d},\"endLine\":{d},\"endColumn\":{d}}}}}}}]",
            .{ uri, start.line, start.col, end.line, end.col },
        );
        try push(allocator, &s, "locations", loc);
    }
    try s.append(allocator, '}');
    return s.toOwnedSlice(allocator);
}

/// Appends `"key":value`, prefixing a comma unless the buffer ends with `{`.
/// Takes ownership of `value` and frees it.
fn push(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), key: []const u8, value: []const u8) !void {
    defer allocator.free(value);
    if (buf.items.len == 0 or buf.items[buf.items.len - 1] != '{') {
        try buf.append(allocator, ',');
    }
    try appendFmt(allocator, buf, "\"{s}\":{s}", .{ key, value });
}

fn appendFmt(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(s);
    try buf.appendSlice(allocator, s);
}

fn jsonString(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    try appendFmt(allocator, &out, "\\u{x:0>4}", .{c});
                } else {
                    try out.append(allocator, c);
                }
            },
        }
    }
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

test "sarif render single diagnostic with factory" {
    const a = std.testing.allocator;
    var sm = SourceMap.init(a);
    defer sm.deinit();
    const id = try sm.add("x.kt", "val a = 1\n");
    const sp = span.Span.init(id, 0, 3);
    var d = Diagnostic.fromFactory(&diag.generated.ABSTRACT_DELEGATED_PROPERTY, sp);
    defer d.deinit(a);
    const s = try toString(a, &.{d}, &sm);
    defer a.free(s);
    const expected =
        "{\"version\":\"2.1.0\",\"$schema\":\"https://json.schemastore.org/sarif-2.1.0.json\",\"runs\":[{\"tool\":{\"driver\":{\"name\":\"klio\",\"informationUri\":\"https://github.com/DrewCarlson/kt-exp\",\"rules\":[{\"id\":\"ABSTRACT_DELEGATED_PROPERTY\",\"name\":\"ABSTRACT_DELEGATED_PROPERTY\"}]}},\"results\":[{\"ruleId\":\"ABSTRACT_DELEGATED_PROPERTY\",\"level\":\"error\",\"message\":{\"text\":\"Delegated property cannot be abstract.\"},\"locations\":[{\"physicalLocation\":{\"artifactLocation\":{\"uri\":\"x.kt\"},\"region\":{\"startLine\":1,\"startColumn\":1,\"endLine\":1,\"endColumn\":4}}}]}]}]}\n";
    try std.testing.expectEqualStrings(expected, s);
}

test "sarif render without code uses default rule id and empty rules" {
    const a = std.testing.allocator;
    var sm = SourceMap.init(a);
    defer sm.deinit();
    const id = try sm.add("x.kt", "val a = 1\n");
    const sp = span.Span.init(id, 4, 5);
    var d = Diagnostic.warning("careful", sp);
    defer d.deinit(a);
    const s = try toString(a, &.{d}, &sm);
    defer a.free(s);
    const expected =
        "{\"version\":\"2.1.0\",\"$schema\":\"https://json.schemastore.org/sarif-2.1.0.json\",\"runs\":[{\"tool\":{\"driver\":{\"name\":\"klio\",\"informationUri\":\"https://github.com/DrewCarlson/kt-exp\",\"rules\":[]}},\"results\":[{\"ruleId\":\"klio.diagnostic\",\"level\":\"warning\",\"message\":{\"text\":\"careful\"},\"locations\":[{\"physicalLocation\":{\"artifactLocation\":{\"uri\":\"x.kt\"},\"region\":{\"startLine\":1,\"startColumn\":5,\"endLine\":1,\"endColumn\":6}}}]}]}]}\n";
    try std.testing.expectEqualStrings(expected, s);
}
