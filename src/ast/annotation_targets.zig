//! Annotation use-site targeting (Kotlin 2.4 semantics).
//!
//! Shared by the type checker (diagnostics) and lowering (per-anchor
//! runtime annotation records). Three pieces:
//!
//! - `useSiteSet` derives an annotation class's allowed use-site target
//!   set U(A) from its `@Target` entry names.
//! - `expandAll` implements the `@all:` property meta-target: a copy of
//!   the annotation lands on every applicable anchor, skipping silently
//!   any anchor outside U(A).
//! - `defaultPlacement` implements the LV 2.4 defaulting rule for a
//!   target-less annotation on a property: `param` when applicable, plus
//!   the first of `property`/`field`; otherwise the first applicable of
//!   `property`, `field`, delegate storage.

const std = @import("std");

/// The use-site targets an annotation class admits, derived from its
/// `@Target` meta-annotation. `AnnotationTarget` entries map as:
/// FIELD -> {field, delegate}, PROPERTY -> {property}, PROPERTY_GETTER ->
/// {get}, PROPERTY_SETTER -> {set}, VALUE_PARAMETER -> {param, receiver,
/// setparam}, FILE -> {file}; every other entry contributes nothing.
pub const UseSiteSet = struct {
    param: bool = false,
    receiver: bool = false,
    setparam: bool = false,
    field: bool = false,
    delegate: bool = false,
    property: bool = false,
    get: bool = false,
    set: bool = false,
    file: bool = false,

    /// No `@Target` on the annotation class: every use-site target except
    /// `file` is admitted.
    pub const no_target: UseSiteSet = .{
        .param = true,
        .receiver = true,
        .setparam = true,
        .field = true,
        .delegate = true,
        .property = true,
        .get = true,
        .set = true,
        .file = false,
    };
};

/// Derive U(A) from the annotation class's `@Target` entry names
/// (`"FIELD"`, `"PROPERTY"`, ...). `null` means the class declares no
/// `@Target` (or is not resolvable), which admits everything but `file`.
pub fn useSiteSet(target_names: ?[]const []const u8) UseSiteSet {
    const names = target_names orelse return UseSiteSet.no_target;
    var u = UseSiteSet{};
    for (names) |n| {
        if (std.mem.eql(u8, n, "FIELD")) {
            u.field = true;
            u.delegate = true;
        } else if (std.mem.eql(u8, n, "PROPERTY")) {
            u.property = true;
        } else if (std.mem.eql(u8, n, "PROPERTY_GETTER")) {
            u.get = true;
        } else if (std.mem.eql(u8, n, "PROPERTY_SETTER")) {
            u.set = true;
        } else if (std.mem.eql(u8, n, "VALUE_PARAMETER")) {
            u.param = true;
            u.receiver = true;
            u.setparam = true;
        } else if (std.mem.eql(u8, n, "FILE")) {
            u.file = true;
        }
    }
    return u;
}

/// The shape of the property declaration an annotation entry anchors to,
/// as target assignment needs it.
pub const PropertyShape = struct {
    /// A `val`/`var` declared in a primary constructor.
    is_ctor_property: bool = false,
    /// Declared `var` (a setter parameter anchor exists).
    is_var: bool = false,
    /// The property has a backing field: an initializer, an explicit
    /// `field` clause, or a defaulted accessor. A property with only
    /// custom accessor bodies (and no initializer) has none.
    has_backing_field: bool = false,
    /// Declared `by <delegate>`.
    is_delegated: bool = false,
    /// The containing class is an `annotation class` (suppresses the
    /// defaulted `field` placement on constructor properties).
    in_annotation_class: bool = false,
};

/// The final anchors one annotation entry lands on.
pub const Placement = struct {
    param: bool = false,
    property: bool = false,
    field: bool = false,
    get: bool = false,
    set: bool = false,
    setparam: bool = false,
    delegate: bool = false,
    receiver: bool = false,

    pub fn isEmpty(self: Placement) bool {
        return !(self.param or self.property or self.field or self.get or
            self.set or self.setparam or self.delegate or self.receiver);
    }
};

/// `@all:A` expansion on a member/top-level property (KEEP-0402): a copy
/// on the constructor parameter (constructor properties), the property,
/// the backing field (when one exists), the getter, and the setter
/// parameter (`var` only) — each iff its use-site target is in U(A).
/// An empty result means no anchor is applicable (an error at the site).
pub fn expandAll(u: UseSiteSet, shape: PropertyShape) Placement {
    var p = Placement{};
    if (shape.is_ctor_property and u.param) p.param = true;
    if (u.property) p.property = true;
    if (shape.has_backing_field and u.field) p.field = true;
    if (u.get) p.get = true;
    if (shape.is_var and u.setparam) p.setparam = true;
    return p;
}

/// LV 2.4 defaulting for `@A` written with no use-site target on a
/// property declaration. An empty result means none of the defaulting
/// anchors is applicable: the annotation stays on the property
/// declaration and plain target checking decides (an annotation that
/// cannot target a property at all is an error).
pub fn defaultPlacement(u: UseSiteSet, shape: PropertyShape) Placement {
    var p = Placement{};
    if (shape.is_ctor_property and u.param) {
        p.param = true;
        if (u.property) {
            p.property = true;
        } else if (shape.has_backing_field and u.field and !shape.in_annotation_class) {
            p.field = true;
        }
        return p;
    }
    if (u.property) {
        p.property = true;
        return p;
    }
    if (shape.has_backing_field and u.field) {
        p.field = true;
        return p;
    }
    if (shape.is_delegated and u.delegate) {
        p.delegate = true;
        return p;
    }
    return p;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

fn set(names: []const []const u8) UseSiteSet {
    return useSiteSet(names);
}

test "useSiteSet maps @Target entries per the KEEP table" {
    const u = set(&.{ "FIELD", "PROPERTY_SETTER" });
    try testing.expect(u.field and u.delegate and u.set);
    try testing.expect(!u.property and !u.get and !u.param and !u.receiver and !u.setparam and !u.file);

    const v = set(&.{"VALUE_PARAMETER"});
    try testing.expect(v.param and v.receiver and v.setparam);
    try testing.expect(!v.field);

    // CLASS/FUNCTION-style entries contribute nothing.
    const w = set(&.{ "CLASS", "FUNCTION" });
    try testing.expect(std.meta.eql(w, UseSiteSet{}));

    // No @Target admits everything except file.
    const d = useSiteSet(null);
    try testing.expect(d.param and d.property and d.field and d.get and d.set and d.setparam and d.delegate and d.receiver);
    try testing.expect(!d.file);
}

test "expandAll places on every applicable anchor" {
    const wide = set(&.{ "VALUE_PARAMETER", "PROPERTY", "FIELD", "PROPERTY_GETTER" });
    // A1: ctor val — param, property, field, get; no setparam.
    {
        const p = expandAll(wide, .{ .is_ctor_property = true, .has_backing_field = true });
        try testing.expect(p.param and p.property and p.field and p.get);
        try testing.expect(!p.setparam and !p.set and !p.delegate);
    }
    // A2: ctor var — also setparam (VALUE_PARAMETER covers it).
    {
        const p = expandAll(wide, .{ .is_ctor_property = true, .is_var = true, .has_backing_field = true });
        try testing.expect(p.param and p.property and p.field and p.get and p.setparam);
    }
    // A3/A12: member/top-level val — property, field, get; no param.
    {
        const p = expandAll(wide, .{ .has_backing_field = true });
        try testing.expect(!p.param and p.property and p.field and p.get);
    }
    // A4: getter-only annotation on a property with no backing field —
    // get only, field skipped silently.
    {
        const p = expandAll(set(&.{"PROPERTY_GETTER"}), .{});
        try testing.expect(p.get and !p.field and !p.property);
    }
    // A5: nothing applicable.
    {
        const p = expandAll(set(&.{"FUNCTION"}), .{ .is_ctor_property = true, .has_backing_field = true });
        try testing.expect(p.isEmpty());
    }
    // A9: param-only annotation — param only, rest skipped silently.
    {
        const p = expandAll(set(&.{"VALUE_PARAMETER"}), .{ .is_ctor_property = true, .has_backing_field = true });
        try testing.expect(p.param and !p.property and !p.field and !p.get and !p.setparam);
    }
}

test "defaultPlacement implements the param + property/field rule" {
    const ctor: PropertyShape = .{ .is_ctor_property = true, .has_backing_field = true };
    // B1: param, property, field admitted -> param + property.
    {
        const p = defaultPlacement(set(&.{ "VALUE_PARAMETER", "PROPERTY", "FIELD" }), ctor);
        try testing.expect(p.param and p.property and !p.field);
    }
    // B2/B11: param, field (no property) -> param + field.
    {
        const p = defaultPlacement(set(&.{ "VALUE_PARAMETER", "FIELD" }), ctor);
        try testing.expect(p.param and p.field and !p.property);
    }
    // B3: param only.
    {
        const p = defaultPlacement(set(&.{"VALUE_PARAMETER"}), ctor);
        try testing.expect(p.param and !p.property and !p.field);
    }
    // B4: property+field without param -> property only.
    {
        const p = defaultPlacement(set(&.{ "PROPERTY", "FIELD" }), ctor);
        try testing.expect(!p.param and p.property and !p.field);
    }
    // B5: member property, property preferred.
    {
        const p = defaultPlacement(set(&.{ "VALUE_PARAMETER", "PROPERTY", "FIELD" }), .{ .has_backing_field = true });
        try testing.expect(!p.param and p.property and !p.field);
    }
    // B6: field-only member property.
    {
        const p = defaultPlacement(set(&.{"FIELD"}), .{ .has_backing_field = true });
        try testing.expect(p.field and !p.property);
    }
    // B7: field-only on a property without a backing field -> empty.
    {
        const p = defaultPlacement(set(&.{"FIELD"}), .{});
        try testing.expect(p.isEmpty());
    }
    // B8: getter-only never defaults.
    {
        const p = defaultPlacement(set(&.{"PROPERTY_GETTER"}), .{ .has_backing_field = true });
        try testing.expect(p.isEmpty());
    }
    // B9: delegated property, property applicable.
    {
        const p = defaultPlacement(set(&.{ "PROPERTY", "FIELD" }), .{ .is_delegated = true });
        try testing.expect(p.property and !p.delegate and !p.field);
    }
    // Delegated property, field-only annotation -> delegate storage field.
    {
        const p = defaultPlacement(set(&.{"FIELD"}), .{ .is_delegated = true });
        try testing.expect(p.delegate and !p.field);
    }
    // B10: annotation-class ctor property suppresses the field placement.
    {
        const p = defaultPlacement(set(&.{ "VALUE_PARAMETER", "FIELD" }), .{
            .is_ctor_property = true,
            .has_backing_field = true,
            .in_annotation_class = true,
        });
        try testing.expect(p.param and !p.field and !p.property);
    }
}
