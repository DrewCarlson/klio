//! Sema's census sites in the program's files as diagnostics: kotlinc's
//! factory and severity, the message in plain words, the places a site
//! relates, less what `@Suppress` silences.

const std = @import("std");
const span = @import("span");
const sema = @import("sema");
const diagnostics = @import("diagnostics");

const Allocator = std.mem.Allocator;
const Diagnostic = diagnostics.Diagnostic;
const Site = sema.census.Site;

pub const Options = struct {
    /// What an error site is shown as. An import that names nothing is an
    /// error whatever this says: it fails the file whatever runs it.
    error_severity: diagnostics.Severity = .Error,
    /// The warning sites too, when there is no error.
    warnings: bool = true,
};

pub const Collected = struct {
    /// The error sites' diagnostics in the order reported, then the
    /// warnings'.
    list: []Diagnostic,
    /// The error sites `@Suppress` does not silence, those `list` leaves
    /// out included.
    sites: []const Site,
    /// How many of them are not the member of a receiver that did not
    /// resolve.
    primary: usize,
};

/// The diagnostics of the program's files. A member of a receiver that did
/// not resolve is left out when anything else is shown: the receiver's own
/// diagnostic says it.
pub fn collect(arena: Allocator, s: *sema.Sema, opts: Options) Allocator.Error!Collected {
    var sup = sema.suppress.Suppressions.init(arena);
    var kept: std.ArrayList(Site) = .empty;
    var primary: usize = 0;
    for (s.census.sites.items) |site| {
        if (!inProgram(s, site) or try sup.suppressed(s, site)) continue;
        try kept.append(arena, site);
        if (site.reason != .receiver_unresolved) primary += 1;
    }
    var out: std.ArrayList(Diagnostic) = .empty;
    for (kept.items) |site| {
        if (site.reason == .receiver_unresolved and primary != 0) continue;
        const severity: diagnostics.Severity = if (site.reason == .unresolved_import) .Error else opts.error_severity;
        try out.append(arena, try fromSite(arena, s, site, severity));
    }
    // kotlinc prints no warning of a compilation that has an error.
    if (opts.warnings and kept.items.len == 0) {
        for (s.census.warnings.items) |site| {
            if (!inProgram(s, site) or try sup.suppressed(s, site)) continue;
            try out.append(arena, try fromSite(arena, s, site, .Warning));
        }
    }
    return .{ .list = out.items, .sites = kept.items, .primary = primary };
}

fn inProgram(s: *sema.Sema, site: Site) bool {
    const fc = s.fileOf(site.file) orelse return false;
    return fc.origin == .program;
}

/// The diagnostic of `site`, shown with `severity`.
pub fn fromSite(arena: Allocator, s: *sema.Sema, site: Site, severity: diagnostics.Severity) Allocator.Error!Diagnostic {
    var d = Diagnostic.err(try sema.diagnose.message(s, arena, site), site.sp);
    d.severity = severity;
    d.factory = try factory(arena, sema.census.factoryOf(site), severity);
    for (site.related) |r| try d.secondary.append(arena, .{ .span = r.sp, .message = r.message });
    for (site.notes) |n| try d.notes.append(arena, n);
    return d;
}

/// The factory named `name`; one of that name alone when neither kotlinc
/// nor klio declares it.
fn factory(arena: Allocator, name: []const u8, severity: diagnostics.Severity) Allocator.Error!*const diagnostics.DiagnosticFactory {
    if (diagnostics.factoryByName(name)) |f| return f;
    const f = try arena.create(diagnostics.DiagnosticFactory);
    f.* = .{ .name = name, .default_severity = severity, .message_template = "" };
    return f;
}

/// Orders `list` by file, then by where each diagnostic starts.
pub fn sortByPlace(list: []Diagnostic) void {
    std.sort.insertion(Diagnostic, list, {}, struct {
        fn lt(_: void, a: Diagnostic, b: Diagnostic) bool {
            const fa = a.primary.span.file.int();
            const fb = b.primary.span.file.int();
            if (fa != fb) return fa < fb;
            return a.primary.span.start < b.primary.span.start;
        }
    }.lt);
}

test "every diagnostic sema names is a factory kotlinc or klio declares" {
    inline for (std.meta.fields(sema.census.Factory)) |f| {
        if (comptime std.mem.eql(u8, f.name, "none")) continue;
        if (diagnostics.factoryByName(f.name) == null) {
            std.debug.print("no factory {s}\n", .{f.name});
            return error.TestUnexpectedResult;
        }
    }
    const sp = span.Span.init(span.FileId.from(0), 0, 0);
    inline for (std.meta.fields(sema.census.Reason)) |f| {
        const site: Site = .{ .reason = @enumFromInt(f.value), .file = 0, .sp = sp, .detail = "" };
        try std.testing.expect(diagnostics.factoryByName(sema.census.factoryOf(site)) != null);
    }
}
