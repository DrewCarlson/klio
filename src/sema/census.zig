//! What the analysis could not resolve, by reason. Zero is the exit of the
//! frontend work; every non-zero row is a construct the analysis does not
//! model yet or a declaration it cannot see, named with where it happened.

const std = @import("std");
const span = @import("span");

const Allocator = std.mem.Allocator;
const Sym = @import("symbols.zig").Sym;
const TypeId = @import("types.zig").TypeId;

pub const Reason = enum(u8) {
    /// A type reference names no classifier in scope.
    unresolved_type,
    /// A bare name is no local, parameter, property, object or class.
    unresolved_name,
    /// A call names no function, constructor or invocable value.
    unresolved_call,
    /// `recv.name` finds no member or extension on the receiver's type.
    unresolved_member,
    /// Candidates exist, none applies to the arguments.
    no_applicable,
    /// Several candidates apply and none is most specific.
    ambiguous,
    /// The receiver's type is itself unresolved, so a member cannot be found.
    receiver_unresolved,
    /// A `this@L`/`super` names no receiver in scope.
    unresolved_receiver,
    /// An operator convention (`get`, `plus`, `iterator`, ...) finds no
    /// `operator` function.
    unresolved_operator,
    /// A type argument could not be inferred.
    uninferred,
    /// An import names nothing.
    unresolved_import,
    /// The analysis does not model this construct yet; `detail` names it.
    unsupported,
    /// A class the language refers to is not declared by the base set.
    missing_builtin,
    /// A node lowering needs a record for was resolved without one.
    unrecorded,
    /// An `actual` whose modifiers differ from its `expect`'s, or a
    /// declaration matching an `expect` without being marked `actual`.
    expect_actual_mismatch,
    /// Two declarations of one scope with the same name and signature.
    conflicting_overloads,
    /// An `expect` of the program that no `actual` implements.
    expect_no_actual,
    /// A call names a member it cannot see: private to another class, or
    /// protected outside its class's subclasses.
    invisible,
    /// A type parameter that is not reified passed for a reified one.
    reified_param,
};

/// What one tentative resolution recorded. `refs` holds the analysis's
/// reference records; the census knows them only as opaque items.
pub fn BufferOf(comptime Ref: type, comptime ExprType: type) type {
    return struct {
        sites: std.ArrayList(Site) = .empty,
        refs: std.ArrayList(Ref) = .empty,
        types: std.ArrayList(ExprType) = .empty,
        resolved: u64 = 0,
        parent: ?*@This() = null,
    };
}

pub const Buffer = BufferOf(@import("records.zig").Ref, @import("records.zig").ExprType);

pub const Site = struct {
    reason: Reason,
    file: u32,
    sp: span.Span,
    /// What the census prints: the site in the analysis's own terms.
    detail: []const u8,
    /// What a diagnostic of the site names: the unresolved name, the
    /// called function, the type or import written.
    name: []const u8 = "",
    /// The type a member or operator was looked up on, as written.
    on: []const u8 = "",
    /// The argument types of a call no candidate accepts; `.none` for a
    /// lambda or reference not typed yet.
    arg_types: []const TypeId = &.{},
    /// The declarations a diagnostic of the site lists: a call's
    /// candidates, the type parameter left uninferred, the declaration
    /// that conflicts and the ones it conflicts with.
    syms: []const Sym = &.{},
    /// The diagnostic's message, where the site composes its own.
    message: []const u8 = "",
};

/// The facts of a site a diagnostic draws on; see `Site`.
pub const Facts = struct {
    name: []const u8 = "",
    on: []const u8 = "",
    arg_types: []const TypeId = &.{},
    syms: []const Sym = &.{},
    message: []const u8 = "",
};

pub const Census = struct {
    arena: Allocator,
    counts: [std.meta.fields(Reason).len]u64 = @splat(0),
    /// Every site, in the order reported. The dump and the per-file totals
    /// read this; the counts above are its histogram.
    sites: std.ArrayList(Site) = .empty,
    /// Sites resolved, for the ratio the census prints.
    resolved: u64 = 0,
    /// Non-zero while an expression is analyzed only to learn its type:
    /// nothing it finds is reported.
    muted: u32 = 0,
    /// While set, sites (and the references `Ctx.addRef` records) go here
    /// instead, to be committed or dropped as one.
    buffer: ?*Buffer = null,

    pub fn init(arena: Allocator) Census {
        return .{ .arena = arena };
    }

    pub fn report(self: *Census, reason: Reason, file: u32, sp: span.Span, detail: []const u8) Allocator.Error!void {
        return self.reportSite(.{ .reason = reason, .file = file, .sp = sp, .detail = detail });
    }

    pub fn reportSite(self: *Census, site: Site) Allocator.Error!void {
        if (self.muted != 0) return;
        if (self.buffer) |b| {
            try b.sites.append(self.arena, site);
            return;
        }
        self.counts[@intFromEnum(site.reason)] += 1;
        try self.sites.append(self.arena, site);
    }

    pub fn reportFmt(self: *Census, reason: Reason, file: u32, sp: span.Span, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const detail = try std.fmt.allocPrint(self.arena, fmt, args);
        return self.report(reason, file, sp, detail);
    }

    /// A site with the facts its diagnostic draws on.
    pub fn reportFacts(self: *Census, reason: Reason, file: u32, sp: span.Span, facts: Facts, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        if (self.muted != 0) return;
        const detail = try std.fmt.allocPrint(self.arena, fmt, args);
        return self.reportSite(.{ .reason = reason, .file = file, .sp = sp, .detail = detail, .name = facts.name, .on = facts.on, .arg_types = facts.arg_types, .syms = facts.syms, .message = facts.message });
    }

    /// Drops every site reported after the first `n`.
    pub fn truncate(self: *Census, n: usize) void {
        for (self.sites.items[n..]) |site| self.counts[@intFromEnum(site.reason)] -= 1;
        self.sites.shrinkRetainingCapacity(n);
    }

    pub fn missingBuiltin(self: *Census, fqn: []const u8) Allocator.Error!void {
        return self.report(.missing_builtin, std.math.maxInt(u32), span.Span.init(span.FileId.from(0), 0, 0), fqn);
    }

    pub fn total(self: *const Census) u64 {
        var n: u64 = 0;
        for (self.counts) |c| n += c;
        return n;
    }

    pub fn count(self: *const Census, reason: Reason) u64 {
        return self.counts[@intFromEnum(reason)];
    }
};

test "the census counts by reason" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c = Census.init(arena.allocator());
    const sp = span.Span.init(span.FileId.from(0), 1, 2);
    try c.report(.unresolved_name, 0, sp, "x");
    try c.reportFmt(.unsupported, 0, sp, "construct {s}", .{"when"});
    try std.testing.expectEqual(@as(u64, 2), c.total());
    try std.testing.expectEqual(@as(u64, 1), c.count(.unsupported));
    try std.testing.expectEqualStrings("construct when", c.sites.items[1].detail);
}
