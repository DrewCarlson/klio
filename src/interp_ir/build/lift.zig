//! AST lifting helpers used by the IR module builder.
//!
//! These transform anonymous-object / nested-class / accessor-body
//! AST shapes before lowering: lifting companion / nested / inner classes
//! to top level, rewriting bare `field` references in accessor bodies to
//! the synthetic backing slot, and synthesising a `Class` shell from an
//! `object` declaration so the regular class-lowering pipeline applies.

const std = @import("std");
const ast = @import("ast");
const span = @import("span");

const Allocator = std.mem.Allocator;
const Expr = ast.Expr;
const Block = ast.Block;
const Stmt = ast.Stmt;
const Ident = ast.Ident;
const Class = ast.Class;
const ObjectDecl = ast.ObjectDecl;
const Decl = ast.Decl;
const Span = span.Span;
const FileId = span.FileId;

const StringSet = std.StringHashMap(void);
/// Enclosing class name -> set of nested-object simple-name aliases.
pub const AliasMap = std.StringHashMap(std.StringHashMap([]const u8));
/// Lifted nested class name -> outer-scope visible member names.
pub const OuterMembers = std.StringHashMap(StringSet);
/// Inner class -> outer class name.
pub const EnclosingMap = std.StringHashMap([]const u8);
/// Qualified nested name (`Outer.Inner`) -> mangled top-level name.
pub const MangledMap = std.StringHashMap([]const u8);

const dummySpan = Span.init(FileId.from(0), 0, 0);

/// How a bare `field` reference in an accessor body maps onto storage:
/// instance accessors read/write `this.__klio_field__<prop>`; top-level
/// accessors read/write the `__klio_topfield__<prop>` global binding.
pub const FieldSubst = enum { this_member, global };

/// Replace every bare `field` identifier in `expr` with
/// `this.__klio_field__<prop_name>`. Used by accessor-body lowering so
/// the IR thunk reads / writes the backing field on the receiver.
///
/// Returns a freshly-allocated rewritten expression owned by `allocator`.
pub fn substituteFieldWithThis(allocator: Allocator, prop_name: []const u8, expr: *const Expr) Allocator.Error!*Expr {
    const out = try allocator.create(Expr);
    out.* = expr.*;
    try walkField(allocator, out, prop_name, .this_member);
    return out;
}

/// Replace every bare `field` identifier in `expr` with the raw global
/// storage name `__klio_topfield__<prop_name>`. Used by top-level
/// accessor-body lowering; the storage binding itself is registered
/// under that raw key, so the read/write bypasses accessor dispatch.
pub fn substituteFieldWithGlobal(allocator: Allocator, prop_name: []const u8, expr: *const Expr) Allocator.Error!*Expr {
    const out = try allocator.create(Expr);
    out.* = expr.*;
    try walkField(allocator, out, prop_name, .global);
    return out;
}

/// Rewrite a bare `field` reference per `mode` (see `FieldSubst`). The Vm's
/// get_field / set_field detect the `__klio_field__` prefix and skip the
/// custom-getter/setter dispatch; `__klio_topfield__` is the storage key
/// itself for top-level properties.
pub fn walkField(allocator: Allocator, e: *Expr, prop: []const u8, mode: FieldSubst) Allocator.Error!void {
    if (e.* == .Path) {
        const p = e.Path;
        if (p.segments.len == 1 and std.mem.eql(u8, p.segments[0].name, "field")) {
            switch (mode) {
                .this_member => {
                    const backing = try std.fmt.allocPrint(allocator, "__klio_field__{s}", .{prop});
                    const this_segs = try allocator.alloc(Ident, 1);
                    this_segs[0] = .{ .name = "this", .span = dummySpan };
                    const recv = try allocator.create(Expr);
                    recv.* = .{ .Path = .{ .segments = this_segs, .span = dummySpan } };
                    e.* = .{ .Member = .{
                        .receiver = recv,
                        .name = .{ .name = backing, .span = dummySpan },
                        .safe = false,
                        .span = dummySpan,
                    } };
                },
                .global => {
                    const backing = try std.fmt.allocPrint(allocator, "__klio_topfield__{s}", .{prop});
                    const segs = try allocator.alloc(Ident, 1);
                    segs[0] = .{ .name = backing, .span = dummySpan };
                    e.* = .{ .Path = .{ .segments = segs, .span = dummySpan } };
                },
            }
            return;
        }
    }
    switch (e.*) {
        .Call => |c| {
            try walkField(allocator, c.callee, prop, mode);
            for (c.args) |*a| try walkField(allocator, a, prop, mode);
        },
        .Member => |m| try walkField(allocator, m.receiver, prop, mode),
        .Binary => |b| {
            try walkField(allocator, b.lhs, prop, mode);
            try walkField(allocator, b.rhs, prop, mode);
        },
        .Unary => |u| try walkField(allocator, u.expr, prop, mode),
        .Postfix => |u| try walkField(allocator, u.expr, prop, mode),
        .IsCheck => |u| try walkField(allocator, u.expr, prop, mode),
        .As => |u| try walkField(allocator, u.expr, prop, mode),
        .Spread => |u| try walkField(allocator, u.expr, prop, mode),
        .If => |iff| {
            try walkField(allocator, iff.cond, prop, mode);
            try walkField(allocator, iff.then_branch, prop, mode);
            if (iff.else_branch) |eb| try walkField(allocator, eb, prop, mode);
        },
        .Index => |ix| {
            try walkField(allocator, ix.receiver, prop, mode);
            for (ix.args) |*a| try walkField(allocator, a, prop, mode);
        },
        .Block => |*b| {
            for (b.stmts) |*s| try walkFieldStmt(allocator, s, prop, mode);
        },
        .StringTemplate => |st| {
            for (st.parts) |*part| {
                if (part.* == .Interp) try walkField(allocator, part.Interp, prop, mode);
            }
        },
        .Return => |r| {
            if (r.value) |v| try walkField(allocator, v, prop, mode);
        },
        .Throw => |t| try walkField(allocator, t.value, prop, mode),
        else => {},
    }
}

fn walkFieldStmt(allocator: Allocator, s: *Stmt, prop: []const u8, mode: FieldSubst) Allocator.Error!void {
    switch (s.*) {
        .Expr => |*e| try walkField(allocator, e, prop, mode),
        .Assign => |*a| {
            try walkField(allocator, &a.target, prop, mode);
            try walkField(allocator, &a.value, prop, mode);
        },
        else => {},
    }
}

/// Rewrite a `field` backing reference inside an accessor block. Returns
/// a freshly-allocated block whose statements have had each bare `field`
/// reference replaced with the synthetic backing-slot access.
pub fn rewriteBlockField(allocator: Allocator, block: *const Block, prop: []const u8) Allocator.Error!Block {
    const stmts = try allocator.dupe(Stmt, block.stmts);
    for (stmts) |*s| try walkFieldStmt(allocator, s, prop, .this_member);
    return .{ .stmts = stmts, .span = block.span };
}

/// Collect the qualified supertype paths used across all declarations
/// (recursing into nested classes), reduced to their last two segments
/// (`Outer.Name`). A nested class is mangled on a name collision only when
/// it is actually extended this way — see the call site.
pub fn collectUsedQualifiedSupertypes(allocator: Allocator, decls: []const Decl, out: *StringSet) Allocator.Error!void {
    for (decls) |*d| {
        if (d.* == .Class) try walkQualifiedSupertypes(allocator, &d.Class, out);
    }
}

fn walkQualifiedSupertypes(allocator: Allocator, c: *const Class, out: *StringSet) Allocator.Error!void {
    for (c.supertypes) |*t| {
        if (t.qualified_path) |qp| {
            if (lastTwo(allocator, qp)) |key| {
                try out.put(try out.allocator.dupe(u8, key), {});
            }
        }
    }
    for (c.members) |*m| {
        if (m.* == .Class) try walkQualifiedSupertypes(allocator, &m.Class, out);
    }
}

/// Reduce a dotted path to its last two segments (`a.b.C` -> `b.C`).
/// Returns `null` when the path has fewer than two segments. The returned
/// slice references `path`'s storage (no allocation); `allocator` is
/// accepted for signature symmetry and unused.
fn lastTwo(allocator: Allocator, path: []const u8) ?[]const u8 {
    _ = allocator;
    var last: ?usize = null;
    var prev: ?usize = null;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] == '.') {
            prev = last;
            last = i;
        }
    }
    if (last == null) return null;
    const start = if (prev) |p| p + 1 else 0;
    return path[start..];
}

/// Collect the member names visible from `c` to siblings / nested classes:
/// primary-ctor params, body properties + functions, companion members,
/// and (for an enum) the synthetic statics + entry names. Inserts into
/// `out`, allocating each key in `out`'s allocator.
pub fn collectEnclosingMemberNames(c: *const Class, out: *StringSet) Allocator.Error!void {
    const a = out.allocator;
    for (c.primary_params) |*p| {
        try out.put(try a.dupe(u8, p.name.name), {});
    }
    for (c.members) |*m| {
        switch (m.*) {
            .Property => |p| try out.put(try a.dupe(u8, p.name.name), {}),
            .Function => |*f| try out.put(try a.dupe(u8, f.name.name), {}),
            .Class => |*nested| {
                if (nested.is_companion) {
                    for (nested.members) |*m2| {
                        switch (m2.*) {
                            .Property => |p| try out.put(try a.dupe(u8, p.name.name), {}),
                            .Function => |*f| try out.put(try a.dupe(u8, f.name.name), {}),
                            else => {},
                        }
                    }
                }
            },
            else => {},
        }
    }
    if (c.is_enum) {
        try out.put(try a.dupe(u8, "entries"), {});
        try out.put(try a.dupe(u8, "values"), {});
        try out.put(try a.dupe(u8, "valueOf"), {});
        for (c.enum_entries) |*e| {
            try out.put(try a.dupe(u8, e.name.name), {});
        }
    }
}

/// Accumulators threaded through the recursive lift.
pub const LiftCtx = struct {
    allocator: Allocator,
    out_decls: *std.ArrayList(Decl),
    object_names: *std.ArrayList([]const u8),
    /// Declaration spans appended in lockstep with `object_names`: the
    /// identity of each lifted `object` decl. `buildClassDef` matches a
    /// class's span against these — never the simple name, which a
    /// same-named class from another package can collide with.
    object_spans: *std.ArrayList(Span),
    companion_singletons: *std.StringHashMap([]const u8),
    nested_outer_members: *OuterMembers,
    enclosing_class: *EnclosingMap,
    nested_object_aliases: *AliasMap,
    top_level_type_names: *const StringSet,
    mangled_nested: *MangledMap,
    used_qualified_supertypes: *const StringSet,
};

/// Recursively walk a class's members and lift companion objects, plain
/// nested classes, and inner classes to top-level entries in `out_decls`.
/// Companion singletons are registered in `companion_singletons` and
/// tagged with the outer's visible-member set in `nested_outer_members`.
pub fn liftClassRecursive(
    ctx: *LiftCtx,
    c: *const Class,
    enclosing_chain: []const *const Class,
) Allocator.Error!void {
    const a = ctx.allocator;
    for (c.members) |*m| {
        if (m.* == .Object) {
            const co = &m.Object;
            const is_private0 = co.visibility == .Private;
            const collides = ctx.top_level_type_names.contains(co.name.name);
            var lifted_name: []const u8 = co.name.name;
            var alias_simple: ?[]const u8 = null;
            if (is_private0 or collides) {
                lifted_name = try std.fmt.allocPrint(a, "{s}${s}", .{ c.name.name, co.name.name });
                alias_simple = co.name.name;
            }
            const is_private = is_private0 or collides;
            try ctx.object_names.append(a, lifted_name);
            try ctx.object_spans.append(a, co.span);
            try ctx.enclosing_class.put(lifted_name, c.name.name);
            var extras = StringSet.init(a);
            try collectEnclosingMemberNames(c, &extras);
            var ci = enclosing_chain.len;
            while (ci > 0) {
                ci -= 1;
                try collectEnclosingMemberNames(enclosing_chain[ci], &extras);
            }
            try ctx.nested_outer_members.put(lifted_name, extras);
            if (alias_simple) |simple| {
                try putAlias(ctx, c.name.name, simple, lifted_name);
            }
            var synth = try synthesizeClassFromObject(a, co);
            if (is_private) {
                synth.name = .{ .name = lifted_name, .span = co.name.span };
            }
            // A type nested inside this object (e.g. an inline `value class`
            // declared in `object Monotonic`) is itself a classifier that
            // must lift to a top-level class and register its simple name.
            const next_chain = try appendChain(a, enclosing_chain, c);
            defer a.free(next_chain);
            try liftClassRecursive(ctx, &synth, next_chain);
            try ctx.out_decls.append(a, .{ .Class = synth });
        } else if (m.* == .Class) {
            const nested = &m.Class;
            if (nested.is_companion) {
                const comp_name = try std.fmt.allocPrint(a, "{s}$Companion${s}", .{ c.name.name, nested.name.name });
                var renamed = nested.*;
                renamed.name = .{ .name = comp_name, .span = nested.name.span };
                renamed.is_companion = false;
                var extras = StringSet.init(a);
                for (c.primary_params) |*p| try extras.put(try a.dupe(u8, p.name.name), {});
                for (c.members) |*m2| {
                    switch (m2.*) {
                        .Property => |p| try extras.put(try a.dupe(u8, p.name.name), {}),
                        .Function => |*f| try extras.put(try a.dupe(u8, f.name.name), {}),
                        else => {},
                    }
                }
                if (c.is_enum) {
                    try extras.put(try a.dupe(u8, "entries"), {});
                    try extras.put(try a.dupe(u8, "values"), {});
                    try extras.put(try a.dupe(u8, "valueOf"), {});
                    for (c.enum_entries) |*e| try extras.put(try a.dupe(u8, e.name.name), {});
                }
                var ci = enclosing_chain.len;
                while (ci > 0) {
                    ci -= 1;
                    try collectEnclosingMemberNames(enclosing_chain[ci], &extras);
                }
                try ctx.nested_outer_members.put(comp_name, extras);
                try ctx.object_names.append(a, comp_name);
                try ctx.object_spans.append(a, nested.span);
                try ctx.enclosing_class.put(comp_name, c.name.name);
                const next_chain = try appendChain(a, enclosing_chain, c);
                defer a.free(next_chain);
                try liftClassRecursive(ctx, &renamed, next_chain);
                try ctx.out_decls.append(a, .{ .Class = renamed });
                try ctx.companion_singletons.put(c.name.name, comp_name);
            } else {
                var extras = StringSet.init(a);
                // The enclosing class's own members AND its companion's members
                // are visible under bare names inside this nested class — a
                // companion `Default` referenced from a nested `Builder` must
                // bind the enclosing companion, not an unrelated global class of
                // the same simple name.
                try collectEnclosingMemberNames(c, &extras);
                var ci = enclosing_chain.len;
                while (ci > 0) {
                    ci -= 1;
                    try collectEnclosingMemberNames(enclosing_chain[ci], &extras);
                }
                const qualified = try std.fmt.allocPrint(a, "{s}.{s}", .{ c.name.name, nested.name.name });
                // Kotlin scopes a `private` nested class to its declaring
                // class; the lifted top-level namespace is flat, so a
                // private nested class always lifts under a scope-keyed
                // mangled name (the same identity a private nested object
                // gets) and bare references inside the declaring class's
                // subtree rewrite through `nested_object_aliases`. A
                // non-private nested class is mangled only when its bare
                // name would collide with a top-level type that is also
                // extended through the qualified form.
                const is_private = nested.visibility == .Private;
                // A nested class with its OWN companion, referenced by bare name
                // for a companion member (`Alignment.Proportional` inside
                // `LineHeightStyle`, where `Alignment` is a nested value class),
                // must mangle+alias UNCONDITIONALLY: a cross-module collision
                // (its simple name vs another pack's top-level type, e.g.
                // ui.Alignment loaded only once material3 pulls ui-core in beside
                // ui-text) is NOT visible at this module's bake, so gating on a
                // bake-visible collision misses it and the bare name resolves to
                // the wrong same-named type at runtime. Mangling is safe: the
                // class keeps its NESTED fqn (from the pre-lift span override),
                // so external qualified refs still resolve, while bare refs in
                // the declaring subtree rewrite through the alias. The
                // qualified-supertype form is the older, narrower trigger.
                const nested_has_companion = blk: {
                    for (nested.members) |*nm| {
                        if (nm.* == .Class and nm.Class.is_companion) break :blk true;
                    }
                    break :blk false;
                };
                const collides = nested_has_companion or
                    (ctx.top_level_type_names.contains(nested.name.name) and
                        ctx.used_qualified_supertypes.contains(qualified));
                var lifted = nested.*;
                if (is_private or collides) {
                    const mangled = try std.fmt.allocPrint(a, "{s}${s}", .{ c.name.name, nested.name.name });
                    try ctx.mangled_nested.put(qualified, mangled);
                    lifted.name = .{ .name = mangled, .span = nested.name.span };
                    // Register the bare-name alias whenever the class is mangled,
                    // not only for a private one: a mangled nested class
                    // referenced by bare name inside its declaring subtree (a
                    // colliding value class read for a companion member) needs
                    // the alias so `scopeTypeRename` rewrites the reference to
                    // the mangled name.
                    try putAlias(ctx, c.name.name, nested.name.name, mangled);
                } else {
                    a.free(qualified);
                }
                try ctx.nested_outer_members.put(lifted.name.name, extras);
                try ctx.enclosing_class.put(lifted.name.name, c.name.name);
                const next_chain = try appendChain(a, enclosing_chain, c);
                defer a.free(next_chain);
                try liftClassRecursive(ctx, &lifted, next_chain);
                try ctx.out_decls.append(a, .{ .Class = lifted });
            }
        }
    }
}

fn appendChain(allocator: Allocator, chain: []const *const Class, c: *const Class) Allocator.Error![]const *const Class {
    const out = try allocator.alloc(*const Class, chain.len + 1);
    @memcpy(out[0..chain.len], chain);
    out[chain.len] = c;
    return out;
}

fn putAlias(ctx: *LiftCtx, cls: []const u8, simple: []const u8, mangled: []const u8) Allocator.Error!void {
    const gop = try ctx.nested_object_aliases.getOrPut(cls);
    if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap([]const u8).init(ctx.allocator);
    try gop.value_ptr.put(simple, mangled);
}

/// Synthesise a `Class` AST node that mirrors an `ObjectDecl`. The
/// resulting class participates in the regular class-lowering pipeline
/// (members, supertype delegation, init blocks); a separate
/// `object_names` map then allocates one instance per name and the Vm
/// publishes it as a global at startup.
pub fn synthesizeClassFromObject(allocator: Allocator, o: *const ObjectDecl) Allocator.Error!Class {
    const delegates = try allocator.alloc(?Expr, o.supertypes.len);
    for (delegates) |*d| d.* = null;
    return .{
        .name = o.name,
        .type_params = &.{},
        .where_bounds = &.{},
        .primary_params = &.{},
        .init_blocks = o.init_blocks,
        .init_block_positions = o.init_block_positions,
        .supertypes = o.supertypes,
        .supertype_args = o.supertype_args,
        .supertype_delegates = delegates,
        .is_data = o.is_data,
        .is_companion = false,
        .is_enum = false,
        .is_sealed = false,
        .is_expect = o.is_expect,
        .is_actual = o.is_actual,
        .is_open = false,
        .is_abstract = false,
        .is_inner = false,
        .secondary_ctors = &.{},
        .is_interface = false,
        .is_fun_interface = false,
        .is_value = false,
        .is_annotation = false,
        .enum_entries = &.{},
        .members = o.members,
        .visibility = .Public,
        .primary_ctor_visibility = null,
        .annotations = &.{},
        .span = o.span,
    };
}

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "substituteFieldWithThis rewrites a bare field reference" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var segs = [_]Ident{.{ .name = "field", .span = dummySpan }};
    const e = Expr{ .Path = .{ .segments = &segs, .span = dummySpan } };
    const out = try substituteFieldWithThis(a, "x", &e);
    try testing.expect(out.* == .Member);
    try testing.expectEqualStrings("__klio_field__x", out.Member.name.name);
    try testing.expect(out.Member.receiver.* == .Path);
    try testing.expectEqualStrings("this", out.Member.receiver.Path.segments[0].name);
}

test "synthesizeClassFromObject mirrors object shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const o = ObjectDecl{
        .name = .{ .name = "Foo", .span = dummySpan },
        .supertypes = &.{},
        .members = &.{},
        .init_blocks = &.{},
        .init_block_positions = &.{},
        .supertype_args = &.{},
        .is_data = false,
        .is_expect = false,
        .is_actual = false,
        .visibility = .Public,
        .span = dummySpan,
    };
    const c = try synthesizeClassFromObject(a, &o);
    try testing.expectEqualStrings("Foo", c.name.name);
    try testing.expect(!c.is_companion);
}
