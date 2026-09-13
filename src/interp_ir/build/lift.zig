//! AST lifting for the module builder: companion, nested and inner classes lift to
//! top level, bare `field` references in accessor bodies rewrite to the synthetic
//! backing slot, and an `object` declaration gains a `Class` shell so the regular
//! class-lowering pipeline applies.

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

/// How a bare `field` reference maps onto storage: an instance accessor uses
/// `this.__klio_field__<prop>`, a top-level one the `__klio_topfield__<prop>` global.
/// `this_member` carries the owning class, so a `field` read inside an anonymous
/// object reaches the OWNER's slot, not the object's `this`.
pub const FieldSubst = union(enum) { this_member: ?[]const u8, object_member: []const u8, global };

/// Returns a freshly-allocated rewritten expression owned by `allocator`.
pub fn substituteFieldWithThis(allocator: Allocator, prop_name: []const u8, expr: *const Expr, owner: ?[]const u8) Allocator.Error!*Expr {
    const out = try allocator.create(Expr);
    out.* = expr.*;
    try walkField(allocator, out, prop_name, .{ .this_member = owner });
    return out;
}

/// The binding is registered under the raw key, so this bypasses accessor dispatch.
pub fn substituteFieldWithGlobal(allocator: Allocator, prop_name: []const u8, expr: *const Expr) Allocator.Error!*Expr {
    const out = try allocator.create(Expr);
    out.* = expr.*;
    try walkField(allocator, out, prop_name, .global);
    return out;
}

/// The Vm's get_field/set_field detect the `__klio_field__` prefix and skip custom
/// getter/setter dispatch; `__klio_topfield__` is the top-level storage key itself.
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
                .object_member => |owner| {
                    const backing = try std.fmt.allocPrint(allocator, "__klio_field__{s}", .{prop});
                    const recv = try allocator.create(Expr);
                    recv.* = .{ .This = .{ .qualifier = .{ .name = owner, .span = dummySpan }, .span = dummySpan } };
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
        // `field` is an ordinary binding inside the accessor, so a nested scope captures it:
        // without this walk a `field` inside a lambda, loop, when or try reads an unresolved global.
        .Lambda => |*l| {
            for (l.body.stmts) |*s| try walkFieldStmt(allocator, s, prop, mode);
        },
        .AnonFun => |af| {
            if (af.body) |body| switch (body.*) {
                .Block => |*blk| for (blk.stmts) |*st| try walkFieldStmt(allocator, st, prop, mode),
                .Expr => |*ex| try walkField(allocator, @constCast(ex), prop, mode),
            };
        },
        .While => |w| {
            try walkField(allocator, w.cond, prop, mode);
            try walkField(allocator, w.body, prop, mode);
        },
        .DoWhile => |dw| {
            if (dw.body) |body| try walkField(allocator, body, prop, mode);
            try walkField(allocator, dw.cond, prop, mode);
        },
        .For => |f| {
            try walkField(allocator, f.iter, prop, mode);
            try walkField(allocator, f.body, prop, mode);
        },
        .Labeled => |l| try walkField(allocator, l.expr, prop, mode),
        .ObjectExpr => |*o| {
            const inner: FieldSubst = switch (mode) {
                .this_member => |owner| if (owner) |own| .{ .object_member = own } else mode,
                else => mode,
            };
            // The object's members are rewritten in place inside an AST that can outlive this
            // lowering, so the replacement nodes must outlive it too.
            const keep = std.heap.page_allocator;
            for (o.members) |*m| try walkFieldDecl(keep, m, prop, inner);
            for (o.init_blocks) |*blk| {
                for (blk.stmts) |*st| try walkFieldStmt(keep, st, prop, inner);
            }
        },
        .Try => |*t| {
            for (t.body.stmts) |*s| try walkFieldStmt(allocator, s, prop, mode);
            for (t.catches) |*c| {
                for (c.body.stmts) |*s| try walkFieldStmt(allocator, s, prop, mode);
            }
            if (t.finally) |*fin| {
                for (fin.stmts) |*s| try walkFieldStmt(allocator, s, prop, mode);
            }
        },
        .When => |*w| {
            if (w.subject) |subj| try walkField(allocator, subj, prop, mode);
            for (w.branches) |*br| {
                for (br.patterns) |*pat| switch (pat.kind) {
                    .Value => |*pe| try walkField(allocator, @constCast(pe), prop, mode),
                    .InRange => |*pe| try walkField(allocator, @constCast(pe), prop, mode),
                    .NotInRange => |*pe| try walkField(allocator, @constCast(pe), prop, mode),
                    else => {},
                };
                try walkField(allocator, &br.body, prop, mode);
            }
        },
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
        // A local `val`/`var` carries its initializer in a `Decl.Property` whose `field`
        // reference must be rewritten; a local cannot have accessors, so only its initializer walks.
        .Decl => |*d| try walkFieldDecl(allocator, d, prop, mode),
        .DestructuringDecl => |*dd| try walkField(allocator, &dd.init, prop, mode),
    }
}

fn walkFieldDecl(allocator: Allocator, d: *Decl, prop: []const u8, mode: FieldSubst) Allocator.Error!void {
    switch (d.*) {
        .Property => |p| {
            if (p.init) |*init| try walkField(allocator, init, prop, mode);
            if (p.delegate) |del| try walkField(allocator, del, prop, mode);
        },
        .Function => |*f| {
            if (f.body) |*body| switch (body.*) {
                .Block => |*blk| for (blk.stmts) |*st| try walkFieldStmt(allocator, st, prop, mode),
                .Expr => |*ex| try walkField(allocator, ex, prop, mode),
            };
        },
        else => {},
    }
}

/// Returns a freshly-allocated block with each bare `field` replaced.
pub fn rewriteBlockField(allocator: Allocator, block: *const Block, prop: []const u8, owner: ?[]const u8) Allocator.Error!Block {
    const stmts = try allocator.dupe(Stmt, block.stmts);
    for (stmts) |*s| try walkFieldStmt(allocator, s, prop, .{ .this_member = owner });
    return .{ .stmts = stmts, .span = block.span };
}

/// Qualified supertype paths across all declarations, reduced to their last two
/// segments. A nested class mangles on a collision only when extended this way.
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

/// Null below two segments. The result references `path`'s storage; `allocator` is unused.
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

/// Member names visible from `c` to siblings and nested classes, an enum's synthetic
/// statics and entry names included.
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

pub const LiftCtx = struct {
    allocator: Allocator,
    out_decls: *std.ArrayList(Decl),
    object_names: *std.ArrayList([]const u8),
    /// Spans appended in lockstep with `object_names`. `buildClassDef` matches a class's
    /// span against these, never the simple name, which another package can share.
    object_spans: *std.ArrayList(Span),
    companion_singletons: *std.StringHashMap([]const u8),
    nested_outer_members: *OuterMembers,
    enclosing_class: *EnclosingMap,
    nested_object_aliases: *AliasMap,
    top_level_type_names: *const StringSet,
    mangled_nested: *MangledMap,
    used_qualified_supertypes: *const StringSet,
    /// Nested simple names declared MORE THAN ONCE. The flat lifted namespace holds one,
    /// so every duplicate lifts mangled.
    dup_nested_names: *const StringSet,
};

/// `BytesHexFormat.Builder` and `NumberHexFormat.Builder` cannot share flat `Builder`.
pub fn collectDupNestedNames(a: Allocator, decls: []const ast.Decl, out: *StringSet) Allocator.Error!void {
    var counts = std.StringHashMap(u32).init(a);
    defer counts.deinit();
    for (decls) |*d| {
        switch (d.*) {
            .Class => |*c| try countNestedNames(&counts, c.members),
            .Object => |*o| try countNestedNames(&counts, o.members),
            else => {},
        }
    }
    var it = counts.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* > 1) try out.put(e.key_ptr.*, {});
    }
}

fn countNestedNames(counts: *std.StringHashMap(u32), members: []const ast.Decl) Allocator.Error!void {
    for (members) |*m| {
        switch (m.*) {
            .Class => |*nc| {
                if (!nc.is_companion) {
                    const gop = try counts.getOrPut(nc.name.name);
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* += 1;
                }
                try countNestedNames(counts, nc.members);
            },
            .Object => |*no| {
                const gop = try counts.getOrPut(no.name.name);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
                try countNestedNames(counts, no.members);
            },
            else => {},
        }
    }
}

/// Companion singletons register in `companion_singletons`, tagged with the outer's
/// visible-member set in `nested_outer_members`.
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
            const collides = ctx.top_level_type_names.contains(co.name.name) or
                ctx.dup_nested_names.contains(co.name.name);
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
            // A type nested inside this object is itself a classifier and must lift to top level.
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
                // Also under the enclosing-chain-qualified name: two nested `C`s in different outers
                // otherwise share the bare key and the last registration wins for both.
                if (enclosing_chain.len != 0) {
                    var qual: std.ArrayList(u8) = .empty;
                    for (enclosing_chain) |ec| {
                        try qual.appendSlice(a, ec.name.name);
                        try qual.append(a, '.');
                    }
                    // The class's SOURCE simple name: a mangled nested class prefixes its outer with `$`.
                    const own = if (std.mem.findScalarLast(u8, c.name.name, '$')) |d| c.name.name[d + 1 ..] else c.name.name;
                    try qual.appendSlice(a, own);
                    try ctx.companion_singletons.put(try qual.toOwnedSlice(a), comp_name);
                }
            } else {
                var extras = StringSet.init(a);
                // The enclosing class's own members and its companion's are visible under bare names
                // inside a nested class, so a companion `Default` read from a nested `Builder` binds
                // the enclosing companion.
                try collectEnclosingMemberNames(c, &extras);
                var ci = enclosing_chain.len;
                while (ci > 0) {
                    ci -= 1;
                    try collectEnclosingMemberNames(enclosing_chain[ci], &extras);
                }
                const qualified = try std.fmt.allocPrint(a, "{s}.{s}", .{ c.name.name, nested.name.name });
                // Kotlin scopes a `private` nested class to its declaring class, but the lifted namespace
                // is flat: it lifts under a scope-keyed mangled name, and bare references in the declaring
                // subtree rewrite through `nested_object_aliases`.
                const is_private = nested.visibility == .Private;
                // A nested class with its OWN companion, referenced by bare name for a companion member,
                // mangles unconditionally: a cross-module collision is invisible at this module's bake.
                // The class keeps its nested fqn, so qualified references still resolve.
                const nested_has_companion = blk: {
                    for (nested.members) |*nm| {
                        if (nm.* == .Class and nm.Class.is_companion) break :blk true;
                    }
                    break :blk false;
                };
                // A nested simple name matching ANY top-level type in the image mangles too: the image
                // build combines every pack, so a flat lift would clobber the top-level entry.
                const collides = nested_has_companion or
                    ctx.dup_nested_names.contains(nested.name.name) or
                    ctx.top_level_type_names.contains(nested.name.name);
                var lifted = nested.*;
                if (is_private or collides) {
                    const mangled = try std.fmt.allocPrint(a, "{s}${s}", .{ c.name.name, nested.name.name });
                    try ctx.mangled_nested.put(qualified, mangled);
                    lifted.name = .{ .name = mangled, .span = nested.name.span };
                    // The alias is registered whenever the class is mangled, so `scopeTypeRename` rewrites
                    // references inside the declaring subtree.
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

/// The synthesised class runs the regular class-lowering pipeline; `object_names` then
/// allocates one instance per name, published as a global.
pub fn synthesizeClassFromObject(allocator: Allocator, o: *const ObjectDecl) Allocator.Error!Class {
    // Delegation carries over: the slot array is padded to the supertype count so a
    // declaration delegating only some supertypes lines up.
    const delegates = try allocator.alloc(?Expr, o.supertypes.len);
    for (delegates, 0..) |*d, i| d.* = if (i < o.supertype_delegates.len) o.supertype_delegates[i] else null;
    return .{
        .name = o.name,
        .type_params = &.{},
        .where_bounds = &.{},
        .primary_params = &.{},
        .init_blocks = o.init_blocks,
        .init_block_positions = o.init_block_positions,
        .supertypes = o.supertypes,
        .supertype_args = o.supertype_args,
        .supertype_arg_names = o.supertype_arg_names,
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
        .annotations = o.annotations,
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
    const out = try substituteFieldWithThis(a, "x", &e, null);
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
