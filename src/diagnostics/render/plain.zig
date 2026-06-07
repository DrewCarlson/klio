//! Plain-text renderer matching `kotlinc`'s `MessageRenderer.PLAIN`:
//!
//! ```text
//! file.kt:10:5: error: Unresolved reference: foo
//!         foo()
//!         ^^^
//! ```
//!
//! Includes the source line and an underline-caret if the span fits on a
//! single line. Multi-line spans only mark the start.

const std = @import("std");
const span = @import("span");
const SourceFile = span.SourceFile;
const SourceMap = span.SourceMap;
const Span = span.Span;

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
        try renderOne(allocator, d, sources, out);
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

fn renderOne(
    allocator: std.mem.Allocator,
    d: *const Diagnostic,
    sources: *const SourceMap,
    out: *std.ArrayList(u8),
) !void {
    const file = sources.get(d.primary.span.file);
    const lc = file.lineCol(d.primary.span.start);
    const sev_label = severityWord(d.severity);
    if (d.code()) |c| {
        try printLine(allocator, out, "{s}:{d}:{d}: {s}: {s} [{s}]", .{
            file.path, lc.line, lc.col, sev_label, d.message, c,
        });
    } else {
        try printLine(allocator, out, "{s}:{d}:{d}: {s}: {s}", .{
            file.path, lc.line, lc.col, sev_label, d.message,
        });
    }
    if (sourceLine(file, d.primary.span)) |snippet| {
        try out.appendSlice(allocator, snippet);
        try out.append(allocator, '\n');
        const underline = try caretUnderline(allocator, file, d.primary.span);
        defer allocator.free(underline);
        try out.appendSlice(allocator, underline);
        try out.append(allocator, '\n');
    }
    for (d.secondary.items) |sec| {
        const slc = file.lineCol(sec.span.start);
        try printLine(allocator, out, "    {s}:{d}:{d}: {s}", .{
            file.path, slc.line, slc.col, sec.message,
        });
    }
    for (d.notes.items) |note| {
        try printLine(allocator, out, "    note: {s}", .{note});
    }
    for (d.fixits.items) |fixit| {
        try printLine(allocator, out, "    help: {s}", .{fixit.title});
    }
}

fn printLine(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const s = try std.fmt.allocPrint(allocator, fmt ++ "\n", args);
    defer allocator.free(s);
    try out.appendSlice(allocator, s);
}

fn severityWord(sev: Severity) []const u8 {
    return sev.asKotlincLabel();
}

fn sourceLine(file: *const SourceFile, sp: Span) ?[]const u8 {
    const lc = file.lineCol(sp.start);
    const target = lc.line - 1;
    var idx: u32 = 0;
    var it = std.mem.splitScalar(u8, file.source, '\n');
    while (it.next()) |segment| {
        if (idx == target) return segment;
        idx += 1;
    }
    return null;
}

fn caretUnderline(allocator: std.mem.Allocator, file: *const SourceFile, sp: Span) ![]u8 {
    const start = file.lineCol(sp.start);
    const end = file.lineCol(sp.end);
    const width: u32 = if (start.line == end.line)
        @max(end.col -| start.col, 1)
    else
        1;
    var s: std.ArrayList(u8) = .empty;
    errdefer s.deinit(allocator);
    var i: u32 = 1;
    while (i < start.col) : (i += 1) {
        try s.append(allocator, ' ');
    }
    var j: u32 = 0;
    while (j < width) : (j += 1) {
        try s.append(allocator, '^');
    }
    return s.toOwnedSlice(allocator);
}

test "plain render matches kotlinc layout" {
    const a = std.testing.allocator;
    var sm = SourceMap.init(a);
    defer sm.deinit();
    const id = try sm.add("file.kt", "fun main() {\n    foo()\n}\n");
    // span over "foo" on line 2 (offset 17..20)
    const sp = Span.init(id, 17, 20);
    var d = Diagnostic.err("Unresolved reference: foo", sp);
    defer d.deinit(a);
    const s = try toString(a, &.{d}, &sm);
    defer a.free(s);
    const expected = "file.kt:2:5: error: Unresolved reference: foo\n    foo()\n    ^^^\n";
    try std.testing.expectEqualStrings(expected, s);
}

test "plain render with code suffix and notes" {
    const a = std.testing.allocator;
    var sm = SourceMap.init(a);
    defer sm.deinit();
    const id = try sm.add("x.kt", "val a = 1\n");
    const sp = Span.init(id, 4, 5);
    var d = Diagnostic.err("oops", sp);
    defer d.deinit(a);
    _ = d.withCode("E0001");
    _ = try d.withNote(a, "consider this");
    const s = try toString(a, &.{d}, &sm);
    defer a.free(s);
    const expected = "x.kt:1:5: error: oops [E0001]\nval a = 1\n    ^\n    note: consider this\n";
    try std.testing.expectEqualStrings(expected, s);
}

test "plain render warning level" {
    const a = std.testing.allocator;
    var sm = SourceMap.init(a);
    defer sm.deinit();
    const id = try sm.add("x.kt", "val a = 1\n");
    const sp = Span.init(id, 0, 3);
    var d = Diagnostic.warning("careful", sp);
    defer d.deinit(a);
    const s = try toString(a, &.{d}, &sm);
    defer a.free(s);
    const expected = "x.kt:1:1: warning: careful\nval a = 1\n^^^\n";
    try std.testing.expectEqualStrings(expected, s);
}
