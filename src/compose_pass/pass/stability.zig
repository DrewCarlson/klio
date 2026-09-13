//! Per-class stability inference, the input to the skip calculus.

const std = @import("std");
const ast = @import("ast");
const root = @import("../compose_pass.zig");

const Decl = ast.Decl;
const Expr = ast.Expr;
const Function = ast.Function;
const TypeRef = ast.TypeRef;

const epilogue = @import("epilogue.zig");
const calleeSimpleName = epilogue.calleeSimpleName;

/// Per-class stability classification. A composable whose value parameters and
/// receiver are all STABLE gets the skip calculus; one with any unstable
/// parameter is restartable but not skippable: it keeps its restart scope,
/// emits no `changed()` probes, and never skips, so an invalidation of an
/// enclosing scope re-runs it even when the parameter instance is unchanged.
/// `stable_annotated` (`@Stable`/`@Immutable`) is unconditionally stable;
/// inferred `stable` still requires stable type arguments at the use site.
pub const Stability = enum { unstable, stable, stable_annotated };

/// Delegate factories whose backing field is a stable snapshot-state object:
/// `var x by mutableStateOf(…)` keeps the declaring class stable, since the
/// field is a `MutableState`, itself `@Stable`.
const stable_delegate_factories = [_][]const u8{
    "mutableStateOf",
    "mutableIntStateOf",
    "mutableLongStateOf",
    "mutableFloatStateOf",
    "mutableDoubleStateOf",
};

const stable_builtin_types = [_][]const u8{
    "Int",   "Long",   "Short",  "Byte", "Char",    "Boolean",
    "Float", "Double", "String", "Unit", "Nothing", "UInt",
    "ULong", "UShort", "UByte",
};

fn isStableBuiltinType(name: []const u8) bool {
    for (stable_builtin_types) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn hasStableAnnotation(annotations: []const ast.Annotation) bool {
    for (annotations) |ann| {
        if (ann.path.len == 0) continue;
        const nm = ann.path[ann.path.len - 1].name;
        if (std.mem.eql(u8, nm, "Stable")) return true;
        if (std.mem.eql(u8, nm, "Immutable")) return true;
        if (std.mem.eql(u8, nm, "StableMarker")) return true;
    }
    return false;
}

fn isTypeParamName(name: []const u8, tps: []const ast.TypeParam) bool {
    for (tps) |*tp| if (std.mem.eql(u8, tp.name.name, name)) return true;
    return false;
}

/// Build the class-stability registry over every class, object, and typealias
/// in `module_decls` and `base_decls`, nested declarations included. Caller owns
/// the returned map. Same-simple-name collisions keep the weaker verdict.
pub fn collectClassStability(
    a: std.mem.Allocator,
    module_decls: []const Decl,
    base_decls: []const Decl,
) std.mem.Allocator.Error!std.StringHashMap(Stability) {
    var cls = StabilityClassifier{
        .classes = std.StringHashMap(*const ast.Class).init(a),
        .objects = std.StringHashMap(*const ast.ObjectDecl).init(a),
        .aliases = std.StringHashMap(*const ast.TypeAlias).init(a),
        .memo = std.StringHashMap(Stability).init(a),
        .in_progress = std.StringHashMap(void).init(a),
    };
    defer cls.classes.deinit();
    defer cls.objects.deinit();
    defer cls.aliases.deinit();
    defer cls.in_progress.deinit();
    try cls.index(module_decls);
    try cls.index(base_decls);
    var it = cls.classes.keyIterator();
    while (it.next()) |k| _ = try cls.classifyName(k.*);
    var oit = cls.objects.keyIterator();
    while (oit.next()) |k| _ = try cls.classifyName(k.*);
    var ait = cls.aliases.keyIterator();
    while (ait.next()) |k| _ = try cls.classifyName(k.*);
    return cls.memo;
}

const StabilityClassifier = struct {
    classes: std.StringHashMap(*const ast.Class),
    objects: std.StringHashMap(*const ast.ObjectDecl),
    aliases: std.StringHashMap(*const ast.TypeAlias),
    memo: std.StringHashMap(Stability),
    in_progress: std.StringHashMap(void),

    fn index(self: *StabilityClassifier, decls: []const Decl) std.mem.Allocator.Error!void {
        for (decls) |*d| switch (d.*) {
            .Class => |*c| {
                const gop = try self.classes.getOrPut(c.name.name);
                if (!gop.found_existing) gop.value_ptr.* = c;
                try self.index(c.members);
            },
            .Object => |*o| {
                const gop = try self.objects.getOrPut(o.name.name);
                if (!gop.found_existing) gop.value_ptr.* = o;
                try self.index(o.members);
            },
            .TypeAlias => |*t| {
                const gop = try self.aliases.getOrPut(t.name.name);
                if (!gop.found_existing) gop.value_ptr.* = t;
            },
            else => {},
        };
    }

    fn classifyName(self: *StabilityClassifier, name: []const u8) std.mem.Allocator.Error!Stability {
        if (self.memo.get(name)) |s| return s;
        if (self.in_progress.contains(name)) return .stable; // recursive back-edge
        try self.in_progress.put(name, {});
        defer _ = self.in_progress.remove(name);
        const result: Stability = blk: {
            if (self.classes.get(name)) |c| break :blk try self.classifyClass(c);
            if (self.objects.get(name)) |o| break :blk try self.classifyObject(o);
            if (self.aliases.get(name)) |t| {
                break :blk if (try self.typeStable(&t.target, t.type_params)) .stable else .unstable;
            }
            break :blk .unstable;
        };
        try self.memo.put(name, result);
        return result;
    }

    fn typeStable(self: *StabilityClassifier, t: *const TypeRef, tps: []const ast.TypeParam) std.mem.Allocator.Error!bool {
        if (t.function != null) return true; // function types are stable
        const n = t.name.name;
        if (isTypeParamName(n, tps)) return false;
        if (isStableBuiltinType(n)) return true;
        switch (try self.classifyName(n)) {
            .stable_annotated => return true,
            .unstable => return false,
            .stable => {
                for (t.type_args) |*ta| {
                    if (ta.is_star) return false;
                    if (!try self.typeStable(&ta.ty, tps)) return false;
                }
                return true;
            },
        }
    }

    fn classifyClass(self: *StabilityClassifier, c: *const ast.Class) std.mem.Allocator.Error!Stability {
        if (hasStableAnnotation(c.annotations)) return .stable_annotated;
        if (c.is_enum) return .stable;
        if (c.is_interface or c.is_fun_interface or c.is_annotation) return .unstable;
        if (c.is_open or c.is_abstract or c.is_sealed) return .unstable;
        // A class supertype (ctor-call form) folds its own stability in;
        // interface supertypes carry no state and are ignored.
        for (c.supertypes, c.supertype_args) |*st, sa| {
            if (sa == null) continue;
            switch (try self.classifyName(st.name.name)) {
                .unstable => return .unstable,
                else => {},
            }
        }
        for (c.primary_params) |*p| {
            const is_prop = p.property orelse continue;
            if (is_prop) return .unstable; // `var` constructor property
            if (!try self.typeStable(&p.ty, c.type_params)) return .unstable;
        }
        if (!try self.membersStable(c.members, c.type_params)) return .unstable;
        return .stable;
    }

    fn classifyObject(self: *StabilityClassifier, o: *const ast.ObjectDecl) std.mem.Allocator.Error!Stability {
        if (!try self.membersStable(o.members, &.{})) return .unstable;
        return .stable;
    }

    fn membersStable(self: *StabilityClassifier, members: []const Decl, tps: []const ast.TypeParam) std.mem.Allocator.Error!bool {
        for (members) |*m| {
            if (m.* != .Property) continue;
            const p = m.Property;
            if (p.receiver_type != null) continue; // extension member: no backing field
            if (p.delegate) |del| {
                if (delegateFactoryStable(del)) continue;
                return false;
            }
            // Computed property (getter, no backing field) carries no state.
            if (p.getter != null and p.init == null and p.explicit_field == null) continue;
            if (p.mutable) return false;
            if (p.ty) |*ty| {
                if (!try self.typeStable(ty, tps)) return false;
            } else if (p.init) |*ini| {
                if (!literalStable(ini)) return false;
            }
        }
        return true;
    }
};

fn delegateFactoryStable(e: *const Expr) bool {
    if (e.* != .Call) return false;
    const nm = calleeSimpleName(e.Call.callee) orelse return false;
    for (stable_delegate_factories) |f| if (std.mem.eql(u8, f, nm)) return true;
    return false;
}

fn literalStable(e: *const Expr) bool {
    return switch (e.*) {
        .IntLit, .FloatLit, .BoolLit, .CharLit => true,
        .StringTemplate => |st| blk: {
            for (st.parts) |part| if (part == .Interp) break :blk false;
            break :blk true;
        },
        else => false,
    };
}

/// Registry-only stability check for a parameter type at transform time:
/// `active_stability` is the finished map, with no recursion into declarations.
fn typeStableFromMap(map: *const std.StringHashMap(Stability), t: *const TypeRef, tps: []const ast.TypeParam) bool {
    if (t.function != null) return true;
    const n = t.name.name;
    if (isTypeParamName(n, tps)) return false;
    if (isStableBuiltinType(n)) return true;
    switch (map.get(n) orelse .unstable) {
        .stable_annotated => return true,
        .unstable => return false,
        .stable => {
            for (t.type_args) |*ta| {
                if (ta.is_star) return false;
                if (!typeStableFromMap(map, &ta.ty, tps)) return false;
            }
            return true;
        },
    }
}

/// Whether `f` gets the skip calculus: every value parameter, the extension
/// receiver, and the enclosing class of a member must be stable. A null
/// `active_stability` treats every type as stable.
pub fn fnIsSkippable(f: *const Function, in_class: bool, enclosing_class: ?[]const u8) bool {
    _ = in_class;
    _ = enclosing_class;
    // Strong skipping: every restartable composable is skippable regardless of
    // parameter stability. Unstable parameters and receivers compare by instance
    // (`changedInstance`) while stable ones keep the structural `changed`. Only
    // an explicit `@NonSkippableComposable` opts a function out.
    for (f.annotations) |ann| {
        if (ann.path.len == 0) continue;
        if (std.mem.eql(u8, ann.path[ann.path.len - 1].name, "NonSkippableComposable")) return false;
    }
    return true;
}

/// The probe method for a parameter under strong skipping: structural `changed`
/// for a stable type, identity `changedInstance` for an unstable one, so a
/// mutated model object with the same identity still skips.
pub fn probeMethodFor(ty: *const ast.TypeRef, tps: []const ast.TypeParam) []const u8 {
    const map = root.active_stability orelse return "changed";
    return if (typeStableFromMap(map, ty, tps)) "changed" else "changedInstance";
}
