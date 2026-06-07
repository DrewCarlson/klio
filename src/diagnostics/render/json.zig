//! NDJSON renderer — one diagnostic per line, suitable for streaming into
//! external tooling that wants to consume our diagnostics directly.

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
    for (diagnostics) |*d| {
        const file = sources.get(d.primary.span.file);
        const start = file.lineCol(d.primary.span.start);
        const end = file.lineCol(d.primary.span.end);
        var s: std.ArrayList(u8) = .empty;
        defer s.deinit(allocator);
        try s.append(allocator, '{');
        try pushField(allocator, &s, "factory", try jsonString(allocator, if (d.factory) |f| f.name else ""));
        try pushField(allocator, &s, "legacy_code", try jsonString(allocator, d.legacy_code orelse ""));
        try pushField(allocator, &s, "severity", try jsonString(allocator, severityStr(d.severity)));
        try pushField(allocator, &s, "file", try jsonString(allocator, file.path));
        try pushField(allocator, &s, "message", try jsonString(allocator, d.message));
        try s.appendSlice(allocator, ",\"range\":{\"start\":{");
        try appendFmt(allocator, &s, "\"line\":{d},\"col\":{d}", .{ start.line, start.col });
        try s.appendSlice(allocator, "},\"end\":{");
        try appendFmt(allocator, &s, "\"line\":{d},\"col\":{d}", .{ end.line, end.col });
        try s.appendSlice(allocator, "}}");
        if (d.notes.items.len != 0) {
            try s.appendSlice(allocator, ",\"notes\":[");
            for (d.notes.items, 0..) |n, i| {
                if (i > 0) try s.append(allocator, ',');
                const js = try jsonString(allocator, n);
                defer allocator.free(js);
                try s.appendSlice(allocator, js);
            }
            try s.append(allocator, ']');
        }
        if (d.fixits.items.len != 0) {
            try s.appendSlice(allocator, ",\"fixits\":[");
            for (d.fixits.items, 0..) |fx, i| {
                if (i > 0) try s.append(allocator, ',');
                const js = try jsonString(allocator, fx.title);
                defer allocator.free(js);
                try appendFmt(allocator, &s, "{{\"title\":{s}}}", .{js});
            }
            try s.append(allocator, ']');
        }
        try s.append(allocator, '}');
        try out.appendSlice(allocator, s.items);
        try out.append(allocator, '\n');
    }
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

/// Appends `"key":value`, prefixing a comma unless the buffer ends with `{`.
/// Takes ownership of `value` (an already-quoted JSON fragment) and frees it.
fn pushField(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), key: []const u8, value: []const u8) !void {
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

fn severityStr(sev: Severity) []const u8 {
    return switch (sev) {
        .Error => "error",
        .StrongWarning => "strong_warning",
        .Warning => "warning",
        .Info => "info",
        .Hint => "hint",
    };
}

test "json render single diagnostic" {
    const a = std.testing.allocator;
    var sm = SourceMap.init(a);
    defer sm.deinit();
    const id = try sm.add("x.kt", "val a = 1\n");
    const sp = span.Span.init(id, 4, 5);
    var d = Diagnostic.err("oops", sp);
    defer d.deinit(a);
    const s = try toString(a, &.{d}, &sm);
    defer a.free(s);
    const expected =
        "{\"factory\":\"\",\"legacy_code\":\"\",\"severity\":\"error\",\"file\":\"x.kt\",\"message\":\"oops\",\"range\":{\"start\":{\"line\":1,\"col\":5},\"end\":{\"line\":1,\"col\":6}}}\n";
    try std.testing.expectEqualStrings(expected, s);
}

test "json render with factory notes and fixit" {
    const a = std.testing.allocator;
    var sm = SourceMap.init(a);
    defer sm.deinit();
    const id = try sm.add("x.kt", "val a = 1\n");
    const sp = span.Span.init(id, 0, 3);
    var d = Diagnostic.fromFactory(&diag.generated.ABSTRACT_DELEGATED_PROPERTY, sp);
    defer d.deinit(a);
    _ = try d.withNote(a, "note one");
    _ = try d.withFixit(a, .{ .title = "fix it", .kind = .QuickFix, .edits = &.{} });
    const s = try toString(a, &.{d}, &sm);
    defer a.free(s);
    const expected =
        "{\"factory\":\"ABSTRACT_DELEGATED_PROPERTY\",\"legacy_code\":\"\",\"severity\":\"error\",\"file\":\"x.kt\",\"message\":\"Delegated property cannot be abstract.\",\"range\":{\"start\":{\"line\":1,\"col\":1},\"end\":{\"line\":1,\"col\":4}},\"notes\":[\"note one\"],\"fixits\":[{\"title\":\"fix it\"}]}\n";
    try std.testing.expectEqualStrings(expected, s);
}

test "json string escapes control chars" {
    const a = std.testing.allocator;
    const s = try jsonString(a, "a\"b\\c\nd\te\x01f");
    defer a.free(s);
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\te\\u0001f\"", s);
}
