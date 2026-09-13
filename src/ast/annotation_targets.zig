//! Annotation use-site targeting (Kotlin 2.4), shared by typeck for diagnostics
//! and by lowering for per-anchor records. `useSiteSet` derives the allowed
//! target set U(A) from `@Target`; `expandAll` implements the `@all:`
//! meta-target; `defaultPlacement` the rule for a target-less annotation.

const std = @import("std");

/// The use-site targets an annotation class admits. `AnnotationTarget` entries
/// map as FIELD -> {field, delegate}, PROPERTY -> {property}, PROPERTY_GETTER ->
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

    /// No `@Target` on the class: every use-site target but `file` is admitted.
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

/// `null` target names means no `@Target`, or an unresolvable class, which
/// admits everything but `file`.
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

pub const PropertyShape = struct {
    is_ctor_property: bool = false,
    is_var: bool = false,
    /// An initializer, an explicit `field` clause, or a defaulted accessor. A
    /// property with only custom accessor bodies has none.
    has_backing_field: bool = false,
    is_delegated: bool = false,
    /// Suppresses the defaulted `field` placement on constructor properties.
    in_annotation_class: bool = false,
};

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

/// `@all:A` expansion on a member or top-level property: a copy on the
/// constructor parameter, the property, the backing field when one exists, the
/// getter, and the setter parameter of a `var`, each only when its target is in
/// U(A). An empty result means no anchor applies, which is an error at the site.
pub fn expandAll(u: UseSiteSet, shape: PropertyShape) Placement {
    var p = Placement{};
    if (shape.is_ctor_property and u.param) p.param = true;
    if (u.property) p.property = true;
    if (shape.has_backing_field and u.field) p.field = true;
    if (u.get) p.get = true;
    if (shape.is_var and u.setparam) p.setparam = true;
    return p;
}

/// Defaulting for `@A` with no use-site target on a property. An empty result
/// means no defaulting anchor applies: the annotation stays on the property
/// declaration and plain target checking decides.
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

// Tests

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
    {
        const p = expandAll(wide, .{ .is_ctor_property = true, .has_backing_field = true });
        try testing.expect(p.param and p.property and p.field and p.get);
        try testing.expect(!p.setparam and !p.set and !p.delegate);
    }
    {
        const p = expandAll(wide, .{ .is_ctor_property = true, .is_var = true, .has_backing_field = true });
        try testing.expect(p.param and p.property and p.field and p.get and p.setparam);
    }
    {
        const p = expandAll(wide, .{ .has_backing_field = true });
        try testing.expect(!p.param and p.property and p.field and p.get);
    }
    {
        const p = expandAll(set(&.{"PROPERTY_GETTER"}), .{});
        try testing.expect(p.get and !p.field and !p.property);
    }
    {
        const p = expandAll(set(&.{"FUNCTION"}), .{ .is_ctor_property = true, .has_backing_field = true });
        try testing.expect(p.isEmpty());
    }
    {
        const p = expandAll(set(&.{"VALUE_PARAMETER"}), .{ .is_ctor_property = true, .has_backing_field = true });
        try testing.expect(p.param and !p.property and !p.field and !p.get and !p.setparam);
    }
}

test "defaultPlacement implements the param + property/field rule" {
    const ctor: PropertyShape = .{ .is_ctor_property = true, .has_backing_field = true };
    {
        const p = defaultPlacement(set(&.{ "VALUE_PARAMETER", "PROPERTY", "FIELD" }), ctor);
        try testing.expect(p.param and p.property and !p.field);
    }
    {
        const p = defaultPlacement(set(&.{ "VALUE_PARAMETER", "FIELD" }), ctor);
        try testing.expect(p.param and p.field and !p.property);
    }
    {
        const p = defaultPlacement(set(&.{"VALUE_PARAMETER"}), ctor);
        try testing.expect(p.param and !p.property and !p.field);
    }
    {
        const p = defaultPlacement(set(&.{ "PROPERTY", "FIELD" }), ctor);
        try testing.expect(!p.param and p.property and !p.field);
    }
    {
        const p = defaultPlacement(set(&.{ "VALUE_PARAMETER", "PROPERTY", "FIELD" }), .{ .has_backing_field = true });
        try testing.expect(!p.param and p.property and !p.field);
    }
    {
        const p = defaultPlacement(set(&.{"FIELD"}), .{ .has_backing_field = true });
        try testing.expect(p.field and !p.property);
    }
    {
        const p = defaultPlacement(set(&.{"FIELD"}), .{});
        try testing.expect(p.isEmpty());
    }
    {
        const p = defaultPlacement(set(&.{"PROPERTY_GETTER"}), .{ .has_backing_field = true });
        try testing.expect(p.isEmpty());
    }
    {
        const p = defaultPlacement(set(&.{ "PROPERTY", "FIELD" }), .{ .is_delegated = true });
        try testing.expect(p.property and !p.delegate and !p.field);
    }
    {
        const p = defaultPlacement(set(&.{"FIELD"}), .{ .is_delegated = true });
        try testing.expect(p.delegate and !p.field);
    }
    {
        const p = defaultPlacement(set(&.{ "VALUE_PARAMETER", "FIELD" }), .{
            .is_ctor_property = true,
            .has_backing_field = true,
            .in_annotation_class = true,
        });
        try testing.expect(p.param and !p.field and !p.property);
    }
}
