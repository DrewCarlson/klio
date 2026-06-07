//! Compiler diagnostics.
//!
//! Models a Kotlin-compatible diagnostic: each emission can carry a
//! `DiagnosticFactory` (a stable ID + default severity + message
//! template mined from kotlinc's `FirErrors.kt`), zero or more secondary
//! labels, notes, and zero or more `FixIt`s. Severities align with
//! kotlinc's `CompilerMessageSeverity`.
//!
//! Diagnostics render via the `render` module — plain text matching
//! `kotlinc`'s `MessageRenderer.PLAIN`, NDJSON for tooling, and SARIF
//! 2.1.0 for static-analysis aggregators.

const std = @import("std");
const span = @import("span");
const Span = span.Span;

pub const generated = @import("generated/factories.zig");
pub const render = @import("render.zig");

/// Mirrors `org.jetbrains.kotlin.cli.common.messages.CompilerMessageSeverity`.
pub const Severity = enum {
    Error,
    StrongWarning,
    Warning,
    Info,
    Hint,

    pub fn asKotlincLabel(self: Severity) []const u8 {
        return switch (self) {
            .Error => "error",
            .StrongWarning, .Warning => "warning",
            .Info, .Hint => "info",
        };
    }
};

/// A stable diagnostic identifier paired with its default severity and
/// message template. Names mirror the upstream Kotlin compiler so existing
/// IDE infrastructure (IntelliJ inspections, quick-fix dispatchers, etc.)
/// recognizes them without translation.
pub const DiagnosticFactory = struct {
    name: []const u8,
    default_severity: Severity,
    message_template: []const u8,
};

pub const Label = struct {
    span: Span,
    message: []const u8,
};

pub const FixItKind = enum {
    QuickFix,
    Refactor,
    Suggestion,
};

pub const TextEdit = struct {
    span: Span,
    replacement: []const u8,
};

/// A suggested code change. `kind` lets IDEs filter quick-fixes from
/// refactors. `edits` are applied atomically.
pub const FixIt = struct {
    title: []const u8,
    kind: FixItKind,
    edits: []const TextEdit,
};

pub const Diagnostic = struct {
    severity: Severity,
    /// Factory (canonical Kotlin-style ID) when one applies. Falls back to
    /// `legacy_code` for diagnostics we haven't mapped to a kotlinc factory yet.
    factory: ?*const DiagnosticFactory,
    /// Older, kt-exp-internal code (e.g. `E0001`, `R0005`). Kept so the
    /// renderer can emit *something* even before every emit site is
    /// migrated to factories.
    legacy_code: ?[]const u8,
    message: []const u8,
    primary: Label,
    secondary: std.ArrayList(Label),
    notes: std.ArrayList([]const u8),
    fixits: std.ArrayList(FixIt),

    pub fn err(message: []const u8, sp: Span) Diagnostic {
        return .{
            .severity = .Error,
            .factory = null,
            .legacy_code = null,
            .message = message,
            .primary = .{ .span = sp, .message = "" },
            .secondary = .empty,
            .notes = .empty,
            .fixits = .empty,
        };
    }

    pub fn warning(message: []const u8, sp: Span) Diagnostic {
        var d = Diagnostic.err(message, sp);
        d.severity = .Warning;
        return d;
    }

    /// Build a diagnostic from a factory. Severity defaults to the factory's
    /// declared default; the message is the factory's template, which call
    /// sites may override with `withMessage`.
    pub fn fromFactory(factory: *const DiagnosticFactory, sp: Span) Diagnostic {
        return .{
            .severity = factory.default_severity,
            .factory = factory,
            .legacy_code = null,
            .message = factory.message_template,
            .primary = .{ .span = sp, .message = "" },
            .secondary = .empty,
            .notes = .empty,
            .fixits = .empty,
        };
    }

    pub fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void {
        self.secondary.deinit(allocator);
        self.notes.deinit(allocator);
        self.fixits.deinit(allocator);
    }

    pub fn withFactory(self: *Diagnostic, factory: *const DiagnosticFactory) *Diagnostic {
        self.factory = factory;
        return self;
    }

    pub fn withCode(self: *Diagnostic, legacy_code: []const u8) *Diagnostic {
        self.legacy_code = legacy_code;
        return self;
    }

    pub fn withSeverity(self: *Diagnostic, severity: Severity) *Diagnostic {
        self.severity = severity;
        return self;
    }

    pub fn withMessage(self: *Diagnostic, message: []const u8) *Diagnostic {
        self.message = message;
        return self;
    }

    pub fn withLabel(
        self: *Diagnostic,
        allocator: std.mem.Allocator,
        sp: Span,
        message: []const u8,
    ) !*Diagnostic {
        try self.secondary.append(allocator, .{ .span = sp, .message = message });
        return self;
    }

    pub fn withNote(
        self: *Diagnostic,
        allocator: std.mem.Allocator,
        note: []const u8,
    ) !*Diagnostic {
        try self.notes.append(allocator, note);
        return self;
    }

    pub fn withFixit(
        self: *Diagnostic,
        allocator: std.mem.Allocator,
        fixit: FixIt,
    ) !*Diagnostic {
        try self.fixits.append(allocator, fixit);
        return self;
    }

    /// The identifier we render in tool output. Factory name takes priority;
    /// falls back to the legacy code.
    pub fn code(self: *const Diagnostic) ?[]const u8 {
        if (self.factory) |f| return f.name;
        return self.legacy_code;
    }
};

pub const DiagnosticSink = struct {
    diagnostics: std.ArrayList(Diagnostic),

    pub fn init() DiagnosticSink {
        return .{ .diagnostics = .empty };
    }

    pub fn deinit(self: *DiagnosticSink, allocator: std.mem.Allocator) void {
        for (self.diagnostics.items) |*d| d.deinit(allocator);
        self.diagnostics.deinit(allocator);
    }

    pub fn emit(self: *DiagnosticSink, allocator: std.mem.Allocator, d: Diagnostic) !void {
        try self.diagnostics.append(allocator, d);
    }

    pub fn hasErrors(self: *const DiagnosticSink) bool {
        for (self.diagnostics.items) |d| {
            if (d.severity == .Error) return true;
        }
        return false;
    }

    pub fn diags(self: *const DiagnosticSink) []const Diagnostic {
        return self.diagnostics.items;
    }

    /// Convenience: render with the default plain-text renderer.
    pub fn render(
        self: *const DiagnosticSink,
        allocator: std.mem.Allocator,
        sources: *const span.SourceMap,
        out: *std.ArrayList(u8),
    ) !void {
        try render_mod.plain.render(allocator, self.diagnostics.items, sources, out);
    }
};

const render_mod = @import("render.zig");

test "severity kotlinc label" {
    try std.testing.expectEqualStrings("error", Severity.Error.asKotlincLabel());
    try std.testing.expectEqualStrings("warning", Severity.StrongWarning.asKotlincLabel());
    try std.testing.expectEqualStrings("warning", Severity.Warning.asKotlincLabel());
    try std.testing.expectEqualStrings("info", Severity.Info.asKotlincLabel());
    try std.testing.expectEqualStrings("info", Severity.Hint.asKotlincLabel());
}

test "error and warning constructors" {
    const f = span.FileId.from(0);
    const sp = Span.init(f, 0, 3);
    var e = Diagnostic.err("boom", sp);
    defer e.deinit(std.testing.allocator);
    try std.testing.expectEqual(Severity.Error, e.severity);
    try std.testing.expectEqualStrings("boom", e.message);
    try std.testing.expect(e.factory == null);
    try std.testing.expect(e.code() == null);

    var w = Diagnostic.warning("careful", sp);
    defer w.deinit(std.testing.allocator);
    try std.testing.expectEqual(Severity.Warning, w.severity);
    try std.testing.expectEqualStrings("careful", w.message);
}

test "from factory pulls template and severity" {
    const f = span.FileId.from(0);
    const sp = Span.init(f, 0, 3);
    var d = Diagnostic.fromFactory(&generated.ABSTRACT_DELEGATED_PROPERTY, sp);
    defer d.deinit(std.testing.allocator);
    try std.testing.expectEqual(Severity.Error, d.severity);
    try std.testing.expectEqualStrings("Delegated property cannot be abstract.", d.message);
    try std.testing.expectEqualStrings("ABSTRACT_DELEGATED_PROPERTY", d.code().?);
}

test "builders mutate and code priority" {
    const a = std.testing.allocator;
    const f = span.FileId.from(0);
    const sp = Span.init(f, 0, 3);
    var d = Diagnostic.err("boom", sp);
    defer d.deinit(a);
    _ = d.withCode("E0001");
    try std.testing.expectEqualStrings("E0001", d.code().?);
    _ = d.withFactory(&generated.ABSTRACT_DELEGATED_PROPERTY);
    // factory takes priority over legacy code
    try std.testing.expectEqualStrings("ABSTRACT_DELEGATED_PROPERTY", d.code().?);
    _ = try d.withLabel(a, sp, "here");
    _ = try d.withNote(a, "a note");
    try std.testing.expectEqual(@as(usize, 1), d.secondary.items.len);
    try std.testing.expectEqual(@as(usize, 1), d.notes.items.len);
    _ = d.withSeverity(.Warning).withMessage("changed");
    try std.testing.expectEqual(Severity.Warning, d.severity);
    try std.testing.expectEqualStrings("changed", d.message);
}

test "sink collects and reports errors" {
    const a = std.testing.allocator;
    const f = span.FileId.from(0);
    const sp = Span.init(f, 0, 3);
    var sink = DiagnosticSink.init();
    defer sink.deinit(a);
    try std.testing.expect(!sink.hasErrors());
    try sink.emit(a, Diagnostic.warning("w", sp));
    try std.testing.expect(!sink.hasErrors());
    try sink.emit(a, Diagnostic.err("e", sp));
    try std.testing.expect(sink.hasErrors());
    try std.testing.expectEqual(@as(usize, 2), sink.diags().len);
}

test "factories module wired" {
    try std.testing.expect(generated.FACTORIES.len > 0);
}

test {
    std.testing.refAllDecls(render);
    std.testing.refAllDecls(render.plain);
    std.testing.refAllDecls(render.json);
    std.testing.refAllDecls(render.sarif);
}
