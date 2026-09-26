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
    /// A value whose type does not fit the type its place declares: a
    /// delegate's `getValue` returning what its property cannot hold.
    type_mismatch,
    /// A `when` whose value is used, or whose subject is an enum, a sealed
    /// type or a `Boolean`, that a subject's value can fall through.
    non_exhaustive_when,
    /// A `when` guard where none may stand: in a `when` without a subject,
    /// or after several conditions.
    when_guard,
    /// A member function or property declared without `override` that has
    /// the signature of a supertype's member.
    member_hidden,
    /// A declaration kotlinc refuses for its shape: its modifiers, its
    /// kind's rules, its supertypes. The site names kotlinc's diagnostic.
    declaration,
    /// A call through a convention (`a + b`, `a[i]`, `a f b`) of a function
    /// declared without the `operator` or `infix` it needs.
    modifier_required,
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

/// How a diagnostic weighs, as kotlinc ranks its factories: an error fails
/// the compilation, a warning does not.
pub const Severity = enum(u1) { err, warning };

/// kotlinc's diagnostics the analysis reports, by their factory names
/// (klio's own are `KLIO_*`). `none` leaves a site to its reason's.
pub const Factory = enum {
    none,
    ABSTRACT_CLASS_MEMBER_NOT_IMPLEMENTED,
    ABSTRACT_MEMBER_NOT_IMPLEMENTED,
    ABSTRACT_MEMBER_NOT_IMPLEMENTED_BY_ENUM_ENTRY,
    ACTUAL_MISSING,
    AMBIGUOUS_ANONYMOUS_TYPE_INFERRED,
    BACKING_FIELD_FOR_DELEGATED_PROPERTY,
    CANNOT_CHANGE_ACCESS_PRIVILEGE,
    CANNOT_INFER_PARAMETER_TYPE,
    CANNOT_WEAKEN_ACCESS_PRIVILEGE,
    CLASSIFIER_REDECLARATION,
    COMMA_IN_WHEN_CONDITION_WITH_WHEN_GUARD,
    COMPONENT_FUNCTION_MISSING,
    CONFLICTING_OVERLOADS,
    CONST_VAL_NOT_TOP_LEVEL_OR_OBJECT,
    CYCLIC_CONSTRUCTOR_DELEGATION_CALL,
    CONST_VAL_WITHOUT_INITIALIZER,
    CONST_VAL_WITH_DELEGATE,
    CONST_VAL_WITH_GETTER,
    CONST_VAL_WITH_NON_CONST_INITIALIZER,
    DATA_CLASS_NOT_PROPERTY_PARAMETER,
    DATA_CLASS_VARARG_PARAMETER,
    DATA_CLASS_WITHOUT_PARAMETERS,
    DATA_OBJECT_CUSTOM_EQUALS_OR_HASH_CODE,
    DELEGATE_SPECIAL_FUNCTION_MISSING,
    DELEGATE_SPECIAL_FUNCTION_NONE_APPLICABLE,
    DELEGATE_SPECIAL_FUNCTION_RETURN_TYPE_MISMATCH,
    DELEGATION_NOT_TO_INTERFACE,
    EXPECT_ACTUAL_INCOMPATIBLE_FUNCTION_MODIFIERS_DIFFERENT,
    EXPECT_ACTUAL_INCOMPATIBLE_FUNCTION_MODIFIERS_NOT_SUBSET,
    EXPLICIT_BACKING_FIELD_IN_INTERFACE,
    EXPLICIT_FIELD_MUST_BE_INITIALIZED,
    EXPLICIT_FIELD_VISIBILITY_MUST_BE_LESS_PERMISSIVE,
    EXTENSION_PROPERTY_MUST_HAVE_ACCESSORS_OR_BE_ABSTRACT,
    EXTENSION_PROPERTY_WITH_BACKING_FIELD,
    FINAL_SUPERTYPE,
    GENERIC_THROWABLE_SUBCLASS,
    HAS_NEXT_MISSING,
    ILLEGAL_INLINE_PARAMETER_MODIFIER,
    INAPPLICABLE_INFIX_MODIFIER,
    INAPPLICABLE_LATEINIT_MODIFIER,
    INAPPLICABLE_OPERATOR_MODIFIER,
    INCOMPATIBLE_MODIFIERS,
    INCONSISTENT_BACKING_FIELD_TYPE,
    INLINE_PROPERTY_WITH_BACKING_FIELD,
    INFIX_MODIFIER_REQUIRED,
    INVISIBLE_REFERENCE,
    MANY_IMPL_MEMBER_NOT_IMPLEMENTED,
    MANY_INTERFACES_MEMBER_NOT_IMPLEMENTED,
    ITERATOR_MISSING,
    KLIO_MISSING_BUILTIN,
    KLIO_UNRECORDED,
    KLIO_UNSUPPORTED,
    MULTIPLE_VARARG_PARAMETERS,
    NEXT_MISSING,
    NONE_APPLICABLE,
    NON_SUSPEND_OVERRIDDEN_BY_SUSPEND,
    NON_FINAL_PROPERTY_WITH_EXPLICIT_BACKING_FIELD,
    NOTHING_TO_INLINE,
    NOTHING_TO_OVERRIDE,
    OPERATOR_MODIFIER_REQUIRED,
    PARAMETER_NAME_CHANGED_ON_OVERRIDE,
    NO_ACTUAL_FOR_EXPECT,
    NO_ELSE_IN_WHEN,
    NO_GET_METHOD,
    NO_SET_METHOD,
    NO_THIS,
    OVERLOAD_RESOLUTION_AMBIGUITY,
    OVERRIDING_FINAL_MEMBER,
    PROPERTY_INITIALIZER_NO_BACKING_FIELD,
    PROPERTY_WITH_EXPLICIT_FIELD_AND_ACCESSORS,
    PROPERTY_TYPE_MISMATCH_ON_OVERRIDE,
    REDECLARATION,
    REDUNDANT_EXPLICIT_BACKING_FIELD,
    REIFIED_TYPE_PARAMETER_NO_INLINE,
    RETURN_TYPE_MISMATCH_ON_OVERRIDE,
    SEALED_SUPERTYPE_IN_LOCAL_CLASS,
    SINGLETON_IN_SUPERTYPE,
    SUPERTYPE_NOT_INITIALIZED,
    SUPER_NOT_AVAILABLE,
    SUSPEND_OVERRIDDEN_BY_NON_SUSPEND,
    TYPE_CANT_BE_USED_FOR_CONST_VAL,
    TYPE_MISMATCH,
    TYPE_PARAMETER_AS_REIFIED,
    UNCHECKED_CAST,
    UNRESOLVED_IMPORT,
    UNRESOLVED_LABEL,
    UNRESOLVED_REFERENCE,
    UNSUPPORTED_FEATURE,
    VALUE_CLASS_CANNOT_EXTEND_CLASSES,
    VALUE_CLASS_CONSTRUCTOR_NOT_FINAL_READ_ONLY_PARAMETER,
    VALUE_CLASS_EMPTY_CONSTRUCTOR,
    VALUE_CLASS_NOT_FINAL,
    VAR_OVERRIDDEN_BY_VAL,
    VAR_PROPERTY_WITH_EXPLICIT_BACKING_FIELD,
    VAR_TYPE_MISMATCH_ON_OVERRIDE,
    VIRTUAL_MEMBER_HIDDEN,
    WHEN_GUARD_WITHOUT_SUBJECT,
    WRONG_MODIFIER_TARGET,
};

/// A place a diagnostic points to besides its own: the other declaration of
/// a clash, the declaration an override hides.
pub const Related = struct {
    file: u32,
    sp: span.Span,
    message: []const u8,
};

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
    /// kotlinc's name for the diagnostic, where it is not the reason's
    /// (`factoryOf`).
    factory: Factory = .none,
    severity: Severity = .err,
    related: []const Related = &.{},
    notes: []const []const u8 = &.{},
};

/// The facts of a site a diagnostic draws on; see `Site`.
pub const Facts = struct {
    name: []const u8 = "",
    on: []const u8 = "",
    arg_types: []const TypeId = &.{},
    syms: []const Sym = &.{},
    message: []const u8 = "",
    factory: Factory = .none,
    severity: Severity = .err,
    related: []const Related = &.{},
    notes: []const []const u8 = &.{},
};

/// The name kotlinc gives the diagnostic of `site`: the site's own, else
/// its reason's. A reason kotlinc has no diagnostic for (what klio does not
/// model, its own internal failures) is named `KLIO_*`.
pub fn factoryOf(site: Site) []const u8 {
    return @tagName(factoryEnum(site));
}

fn factoryEnum(site: Site) Factory {
    if (site.factory != .none) return site.factory;
    return switch (site.reason) {
        .unresolved_type, .unresolved_name, .unresolved_call, .unresolved_member, .receiver_unresolved => .UNRESOLVED_REFERENCE,
        .no_applicable => .NONE_APPLICABLE,
        .ambiguous => .OVERLOAD_RESOLUTION_AMBIGUITY,
        .unresolved_receiver => .UNRESOLVED_LABEL,
        .unresolved_operator => operatorFactory(site.name),
        .uninferred => .CANNOT_INFER_PARAMETER_TYPE,
        .unresolved_import => .UNRESOLVED_IMPORT,
        .unsupported => .KLIO_UNSUPPORTED,
        .missing_builtin => .KLIO_MISSING_BUILTIN,
        .unrecorded => .KLIO_UNRECORDED,
        .expect_actual_mismatch => .ACTUAL_MISSING,
        .conflicting_overloads => .CONFLICTING_OVERLOADS,
        .expect_no_actual => .NO_ACTUAL_FOR_EXPECT,
        .invisible => .INVISIBLE_REFERENCE,
        .reified_param => .TYPE_PARAMETER_AS_REIFIED,
        .type_mismatch => .TYPE_MISMATCH,
        .non_exhaustive_when => .NO_ELSE_IN_WHEN,
        .when_guard => .WHEN_GUARD_WITHOUT_SUBJECT,
        .member_hidden => .VIRTUAL_MEMBER_HIDDEN,
        // Always named by the site.
        .declaration => .KLIO_UNSUPPORTED,
        .modifier_required => .OPERATOR_MODIFIER_REQUIRED,
    };
}

/// kotlinc's diagnostic for an operator convention no function answers.
fn operatorFactory(name: []const u8) Factory {
    const eql = std.mem.eql;
    if (eql(u8, name, "get")) return .NO_GET_METHOD;
    if (eql(u8, name, "set")) return .NO_SET_METHOD;
    if (eql(u8, name, "iterator")) return .ITERATOR_MISSING;
    if (eql(u8, name, "next")) return .NEXT_MISSING;
    if (eql(u8, name, "hasNext")) return .HAS_NEXT_MISSING;
    if (std.mem.startsWith(u8, name, "component")) return .COMPONENT_FUNCTION_MISSING;
    if (eql(u8, name, "getValue") or eql(u8, name, "setValue") or eql(u8, name, "provideDelegate")) return .DELEGATE_SPECIAL_FUNCTION_MISSING;
    return .UNRESOLVED_REFERENCE;
}

pub const Census = struct {
    arena: Allocator,
    counts: [std.meta.fields(Reason).len]u64 = @splat(0),
    /// Every error site, in the order reported. The dump and the per-file
    /// totals read this; the counts above are its histogram.
    sites: std.ArrayList(Site) = .empty,
    /// The warning sites, in the order reported: diagnostics only, never
    /// counted.
    warnings: std.ArrayList(Site) = .empty,
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
        if (site.severity == .warning) return self.warnings.append(self.arena, site);
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
        return self.reportSite(.{
            .reason = reason,
            .file = file,
            .sp = sp,
            .detail = detail,
            .name = facts.name,
            .on = facts.on,
            .arg_types = facts.arg_types,
            .syms = facts.syms,
            .message = facts.message,
            .factory = facts.factory,
            .severity = facts.severity,
            .related = facts.related,
            .notes = facts.notes,
        });
    }

    /// How many sites of each severity are reported so far, for `truncate`.
    pub const Mark = struct { sites: usize, warnings: usize };

    pub fn mark(self: *const Census) Mark {
        return .{ .sites = self.sites.items.len, .warnings = self.warnings.items.len };
    }

    /// Drops every site reported after `m`.
    pub fn truncate(self: *Census, m: Mark) void {
        for (self.sites.items[m.sites..]) |site| self.counts[@intFromEnum(site.reason)] -= 1;
        self.sites.shrinkRetainingCapacity(m.sites);
        self.warnings.shrinkRetainingCapacity(m.warnings);
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

test "a warning is kept apart from the counted sites" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c = Census.init(arena.allocator());
    const sp = span.Span.init(span.FileId.from(0), 1, 2);
    const m = c.mark();
    try c.reportFacts(.type_mismatch, 0, sp, .{ .factory = .UNCHECKED_CAST, .severity = .warning }, "cast", .{});
    try c.report(.unresolved_name, 0, sp, "x");
    try std.testing.expectEqual(@as(u64, 1), c.total());
    try std.testing.expectEqual(@as(usize, 1), c.warnings.items.len);
    try std.testing.expectEqualStrings("UNCHECKED_CAST", factoryOf(c.warnings.items[0]));
    c.truncate(m);
    try std.testing.expectEqual(@as(u64, 0), c.total());
    try std.testing.expectEqual(@as(usize, 0), c.warnings.items.len);
}

test "a site is named by its reason unless it names itself" {
    const sp = span.Span.init(span.FileId.from(0), 1, 2);
    try std.testing.expectEqualStrings("UNRESOLVED_REFERENCE", factoryOf(.{ .reason = .unresolved_type, .file = 0, .sp = sp, .detail = "" }));
    try std.testing.expectEqualStrings("NO_GET_METHOD", factoryOf(.{ .reason = .unresolved_operator, .file = 0, .sp = sp, .detail = "", .name = "get" }));
    try std.testing.expectEqualStrings("COMPONENT_FUNCTION_MISSING", factoryOf(.{ .reason = .unresolved_operator, .file = 0, .sp = sp, .detail = "", .name = "component2" }));
    try std.testing.expectEqualStrings("UNRESOLVED_REFERENCE", factoryOf(.{ .reason = .unresolved_operator, .file = 0, .sp = sp, .detail = "", .name = "plus" }));
    try std.testing.expectEqualStrings("NO_THIS", factoryOf(.{ .reason = .unresolved_receiver, .file = 0, .sp = sp, .detail = "", .factory = .NO_THIS }));
}
