//! Mines `FirErrors.kt` + `FirErrorsDefaultMessages.kt` from the upstream
//! Kotlin compiler for canonical diagnostic factory IDs, default
//! severities, and message templates. Emits Zig constants into
//! `src/diagnostics/generated/factories.zig`.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const main = @import("main.zig");
pub const run = main.run;

pub const Severity = enum {
    Error,
    Warning,

    /// Render the severity as it appears in the generated Zig factories table
    /// (the enum-literal form of `diagnostics.Severity`).
    pub fn asZig(self: Severity) []const u8 {
        return switch (self) {
            .Error => ".Error",
            .Warning => ".Warning",
        };
    }
};

pub const Factory = struct {
    name: []const u8,
    severity: Severity,
    message: []const u8,

    pub fn deinit(self: *Factory, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.message);
    }
};

/// `name → severity` entry parsed from a `FirErrors.kt`-shaped file.
pub const SeverityEntry = struct {
    name: []const u8,
    severity: Severity,
};

/// `name → template` entry parsed from the default-messages map.
pub const MessageEntry = struct {
    name: []const u8,
    template: []const u8,
};

fn lessBySeverityName(_: void, a: SeverityEntry, b: SeverityEntry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn lessByMessageName(_: void, a: MessageEntry, b: MessageEntry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn lessByFactoryName(_: void, a: Factory, b: Factory) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Parse a `FirErrors.kt`-shaped file. Returns `(name → severity)` for every
/// `val NAME: KtDiagnosticFactoryN<…> = KtDiagnosticFactoryN("NAME", SEVERITY, …)`
/// declaration we recognize, sorted by name with later duplicates winning.
///
/// The returned slice and every `name` it borrows are owned by the caller and
/// must be freed (see `freeSeverityEntries`).
pub fn parseFactories(allocator: Allocator, src: []const u8) Allocator.Error![]SeverityEntry {
    var map = std.StringHashMap(Severity).init(allocator);
    defer map.deinit();
    errdefer {
        var it = map.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
    }

    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw_line| {
        const line = trim(raw_line);
        if (!std.mem.startsWith(u8, line, "val ")) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const rhs = trim(line[eq + 1 ..]);
        // Look for KtDiagnosticFactory{0,1,2,3,4}( ... or
        // KtDiagnosticFactoryForDeprecationN(…
        if (!std.mem.startsWith(u8, rhs, "KtDiagnosticFactory")) continue;
        const open = std.mem.indexOfScalar(u8, rhs, '(') orelse continue;
        const args = rhs[open + 1 ..];
        // First arg is "NAME", second is SEVERITY (ERROR/WARNING).
        const quote_start = std.mem.indexOfScalar(u8, args, '"') orelse continue;
        const after_quote = args[quote_start + 1 ..];
        const quote_end = std.mem.indexOfScalar(u8, after_quote, '"') orelse continue;
        const name = after_quote[0..quote_end];
        const rest = after_quote[quote_end + 1 ..];
        const comma = std.mem.indexOfScalar(u8, rest, ',') orelse continue;
        const sev_token = trimStart(rest[comma + 1 ..]);
        const severity: Severity = if (std.mem.startsWith(u8, sev_token, "ERROR"))
            .Error
        else if (std.mem.startsWith(u8, sev_token, "WARNING"))
            .Warning
        else
            continue;

        const gop = try map.getOrPut(name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try allocator.dupe(u8, name);
        }
        gop.value_ptr.* = severity;
    }

    var out = try allocator.alloc(SeverityEntry, map.count());
    errdefer allocator.free(out);
    var it = map.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) {
        out[i] = .{ .name = e.key_ptr.*, .severity = e.value_ptr.* };
    }
    std.mem.sort(SeverityEntry, out, {}, lessBySeverityName);
    return out;
}

pub fn freeSeverityEntries(allocator: Allocator, entries: []SeverityEntry) void {
    for (entries) |e| allocator.free(e.name);
    allocator.free(entries);
}

/// Parse the default-messages map. Returns `(name → template)` from every
/// `map.put(NAME, "template", …)` line, sorted by name with later duplicates
/// winning.
///
/// The returned slice and every `name`/`template` it borrows are owned by the
/// caller and must be freed (see `freeMessageEntries`).
pub fn parseMessages(allocator: Allocator, src: []const u8) Allocator.Error![]MessageEntry {
    var map = std.StringHashMap([]const u8).init(allocator);
    defer map.deinit();
    errdefer {
        var it = map.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
    }

    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw_line| {
        const line = trim(raw_line);
        if (!std.mem.startsWith(u8, line, "map.put(")) continue;
        const after_open = line["map.put(".len..];
        const comma = std.mem.indexOfScalar(u8, after_open, ',') orelse continue;
        const name = trim(after_open[0..comma]);
        const rest = trimStart(after_open[comma + 1 ..]);
        if (rest.len == 0 or rest[0] != '"') continue;
        const body = rest[1..];
        // Find the matching close quote, respecting `\"` escapes.
        var end: ?usize = null;
        var prev: u8 = 0;
        for (body, 0..) |c, idx| {
            if (c == '"' and prev != '\\') {
                end = idx;
                break;
            }
            prev = c;
        }
        const e = end orelse continue;
        const template = body[0..e];

        const gop = try map.getOrPut(name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try allocator.dupe(u8, name);
        } else {
            allocator.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = try allocator.dupe(u8, template);
    }

    var out = try allocator.alloc(MessageEntry, map.count());
    errdefer allocator.free(out);
    var it = map.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) {
        out[i] = .{ .name = e.key_ptr.*, .template = e.value_ptr.* };
    }
    std.mem.sort(MessageEntry, out, {}, lessByMessageName);
    return out;
}

pub fn freeMessageEntries(allocator: Allocator, entries: []MessageEntry) void {
    for (entries) |e| {
        allocator.free(e.name);
        allocator.free(e.template);
    }
    allocator.free(entries);
}

fn lookupMessage(messages: []const MessageEntry, name: []const u8) ?[]const u8 {
    for (messages) |m| {
        if (std.mem.eql(u8, m.name, name)) return m.template;
    }
    return null;
}

/// Read and parse the upstream `FirErrors.kt` / `FirErrorsDefaultMessages.kt`
/// under `stdlib_root`, producing the sorted factory table. Missing or
/// unreadable files are treated as empty.
///
/// The returned factories and the strings they own must be freed with
/// `freeFactories`.
pub fn mine(allocator: Allocator, io: Io, stdlib_root: []const u8) Allocator.Error![]Factory {
    const fir_errors = try std.fs.path.join(allocator, &.{
        stdlib_root,
        "compiler/fir/checkers/gen/org/jetbrains/kotlin/fir/analysis/diagnostics/FirErrors.kt",
    });
    defer allocator.free(fir_errors);
    const fir_messages = try std.fs.path.join(allocator, &.{
        stdlib_root,
        "compiler/fir/checkers/src/org/jetbrains/kotlin/fir/analysis/diagnostics/FirErrorsDefaultMessages.kt",
    });
    defer allocator.free(fir_messages);

    const errors_src = readFile(allocator, io, fir_errors);
    defer if (errors_src) |s| allocator.free(s);
    const messages_src = readFile(allocator, io, fir_messages);
    defer if (messages_src) |s| allocator.free(s);

    const factories = try parseFactories(allocator, errors_src orelse "");
    defer freeSeverityEntries(allocator, factories);
    const messages = try parseMessages(allocator, messages_src orelse "");
    defer freeMessageEntries(allocator, messages);

    var out = try allocator.alloc(Factory, factories.len);
    errdefer allocator.free(out);
    var built: usize = 0;
    errdefer for (out[0..built]) |*f| f.deinit(allocator);
    for (factories) |fac| {
        const name = try allocator.dupe(u8, fac.name);
        errdefer allocator.free(name);
        const message = if (lookupMessage(messages, fac.name)) |m|
            try allocator.dupe(u8, m)
        else
            try allocator.dupe(u8, fac.name);
        out[built] = .{ .name = name, .severity = fac.severity, .message = message };
        built += 1;
    }
    std.mem.sort(Factory, out, {}, lessByFactoryName);
    return out;
}

pub fn freeFactories(allocator: Allocator, factories: []Factory) void {
    for (factories) |*f| f.deinit(allocator);
    allocator.free(factories);
}

/// Append a Zig string literal for `s` to `out`, escaping (`\` → `\\`,
/// `"` → `\"`, control chars as escapes). The escapes produced are all
/// valid Zig string escapes.
fn writeEscaped(out: *std.ArrayList(u8), allocator: Allocator, s: []const u8) Allocator.Error!void {
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
                    var buf: [4]u8 = undefined;
                    const hex = std.fmt.bufPrint(&buf, "\\x{x:0>2}", .{c}) catch unreachable;
                    try out.appendSlice(allocator, hex);
                } else {
                    try out.append(allocator, c);
                }
            },
        }
    }
    try out.append(allocator, '"');
}

/// Render the generated Zig module. Returns an owned, NUL-free byte slice.
pub fn render(allocator: Allocator, factories: []const Factory) Allocator.Error![]u8 {
    var s: std.ArrayList(u8) = .empty;
    errdefer s.deinit(allocator);

    try s.appendSlice(allocator,
        \\//! Auto-generated diagnostic factories mined from the upstream Kotlin compiler.
        \\//! Do not edit by hand.
        \\
        \\const diag = @import("../diagnostics.zig");
        \\const DiagnosticFactory = diag.DiagnosticFactory;
        \\const Severity = diag.Severity;
        \\
        \\
    );

    for (factories) |f| {
        try s.appendSlice(allocator, "pub const ");
        try s.appendSlice(allocator, f.name);
        try s.appendSlice(allocator, " = DiagnosticFactory{\n");
        try s.appendSlice(allocator, "    .name = ");
        try writeEscaped(&s, allocator, f.name);
        try s.appendSlice(allocator, ",\n");
        try s.appendSlice(allocator, "    .default_severity = ");
        try s.appendSlice(allocator, f.severity.asZig());
        try s.appendSlice(allocator, ",\n");
        try s.appendSlice(allocator, "    .message_template = ");
        try writeEscaped(&s, allocator, f.message);
        try s.appendSlice(allocator, ",\n");
        try s.appendSlice(allocator, "};\n");
    }

    try s.appendSlice(allocator, "\npub const FACTORIES = [_]*const DiagnosticFactory{\n");
    for (factories) |f| {
        try s.appendSlice(allocator, "    &");
        try s.appendSlice(allocator, f.name);
        try s.appendSlice(allocator, ",\n");
    }
    try s.appendSlice(allocator, "};\n");

    return s.toOwnedSlice(allocator);
}

fn readFile(allocator: Allocator, io: Io, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch null;
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn trimStart(s: []const u8) []const u8 {
    return std.mem.trimStart(u8, s, " \t\r\n");
}

const testing = std.testing;

test "parses typical factory line" {
    const src =
        \\
        \\            val UNSUPPORTED: KtDiagnosticFactory1<String> = KtDiagnosticFactory1("UNSUPPORTED", ERROR, SourceElementPositioningStrategies.DEFAULT, PsiElement::class, getRendererFactory())
        \\            val SHADOWED: KtDiagnosticFactory0 = KtDiagnosticFactory0("SHADOWED", WARNING, SourceElementPositioningStrategies.DEFAULT, PsiElement::class, getRendererFactory())
        \\
    ;
    const m = try parseFactories(testing.allocator, src);
    defer freeSeverityEntries(testing.allocator, m);

    var unsupported: ?Severity = null;
    var shadowed: ?Severity = null;
    for (m) |e| {
        if (std.mem.eql(u8, e.name, "UNSUPPORTED")) unsupported = e.severity;
        if (std.mem.eql(u8, e.name, "SHADOWED")) shadowed = e.severity;
    }
    try testing.expectEqual(Severity.Error, unsupported.?);
    try testing.expectEqual(Severity.Warning, shadowed.?);
}

test "parses typical message line" {
    const src =
        \\
        \\            map.put(UNSUPPORTED, "{0}", TO_STRING)
        \\            map.put(OTHER_ERROR, "Unknown error.")
        \\            map.put(NEW_INFERENCE_ERROR, "New inference error [{0}].", STRING)
        \\
    ;
    const m = try parseMessages(testing.allocator, src);
    defer freeMessageEntries(testing.allocator, m);

    try testing.expectEqualStrings("{0}", lookupMessage(m, "UNSUPPORTED").?);
    try testing.expectEqualStrings("Unknown error.", lookupMessage(m, "OTHER_ERROR").?);
    try testing.expectEqualStrings("New inference error [{0}].", lookupMessage(m, "NEW_INFERENCE_ERROR").?);
}

test "render emits factory consts and table" {
    const factories = [_]Factory{
        .{ .name = "A_FACTORY", .severity = .Error, .message = "the {0} message" },
        .{ .name = "B_FACTORY", .severity = .Warning, .message = "another" },
    };
    const out = try render(testing.allocator, &factories);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "pub const A_FACTORY = DiagnosticFactory{") != null);
    try testing.expect(std.mem.indexOf(u8, out, ".default_severity = .Error,") != null);
    try testing.expect(std.mem.indexOf(u8, out, ".default_severity = .Warning,") != null);
    try testing.expect(std.mem.indexOf(u8, out, ".message_template = \"the {0} message\",") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub const FACTORIES = [_]*const DiagnosticFactory{") != null);
    try testing.expect(std.mem.indexOf(u8, out, "    &A_FACTORY,") != null);
    try testing.expect(std.mem.indexOf(u8, out, "    &B_FACTORY,") != null);
}

test "render escapes backslashes like rust debug" {
    const factories = [_]Factory{
        .{ .name = "X", .severity = .Error, .message = "line\\nbreak" },
    };
    const out = try render(testing.allocator, &factories);
    defer testing.allocator.free(out);
    // The message contains a literal backslash-n which must render as `\\n`.
    try testing.expect(std.mem.indexOf(u8, out, ".message_template = \"line\\\\nbreak\",") != null);
}

test {
    std.testing.refAllDecls(@This());
    _ = main;
}
