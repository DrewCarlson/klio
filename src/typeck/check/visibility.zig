//! Visibility / access checks (T0031, T0032, T0068, …). Free functions
//! over `*Checker`.

const std = @import("std");

const span = @import("span");
const ast = @import("ast");
const types = @import("types");

const root = @import("../check.zig");
const helpers = @import("helpers.zig");

const Allocator = std.mem.Allocator;
const Span = span.Span;
const FileId = span.FileId;
const Checker = root.Checker;
const ClassInfo = root.ClassInfo;
const Diagnostic = root.Diagnostic;
const codes = root.codes;

const Expr = ast.Expr;
const TypeRef = ast.TypeRef;
const Visibility = ast.Visibility;
const AssignOp = ast.AssignOp;
const Annotation = ast.Annotation;
const Type = types.Type;

/// A conflicting-overload pair: the two declaration spans and the shared
/// function name.
const OverloadPair = struct {
    a: Span,
    b: Span,
    name: []const u8,
};

/// Walk a class's supertype chain in `classes` looking for `sup`. Returns
/// false when `sub == sup` (an identity is not a strict subtype here).
fn isSubtypeOf(self: *const Checker, sub: []const u8, sup: []const u8) bool {
    if (std.mem.eql(u8, sub, sup)) {
        return false;
    }
    var frontier: std.ArrayList([]const u8) = .empty;
    defer frontier.deinit(self.allocator);
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(self.allocator);
    frontier.append(self.allocator, sub) catch return false;
    var steps: usize = 0;
    while (frontier.pop()) |name| {
        if (steps > 64) {
            return false;
        }
        steps += 1;
        if (sliceContains(seen.items, name)) {
            continue;
        }
        seen.append(self.allocator, name) catch return false;
        const info = self.classes.get(name) orelse continue;
        for (info.supertypes.items) |s| {
            if (std.mem.eql(u8, s, sup)) {
                return true;
            }
            frontier.append(self.allocator, s) catch return false;
        }
    }
    return false;
}

/// Look up the most recent binding for `name` across the frame stack.
fn lookup(self: *const Checker, name: []const u8) ?*const root.Binding {
    var i: usize = self.frames.items.len;
    while (i > 0) {
        i -= 1;
        if (self.frames.items[i].bindings.getPtr(name)) |b| {
            return b;
        }
    }
    return null;
}

fn sliceContains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| {
        if (std.mem.eql(u8, h, needle)) return true;
    }
    return false;
}

/// Check a member / reference access at `e` against the declaring scope's
/// visibility. No-op placeholder retained so the phase driver keeps a
/// uniform entry point; the per-site checks below are invoked directly by
/// the expression / declaration phases.
pub fn checkVisibility(self: *Checker, e: *const Expr) Allocator.Error!void {
    _ = self;
    _ = e;
}

/// Look up the effective visibility a class declares for a member.
/// Walks the supertype chain so inherited members are seen with the
/// declaring class's annotation. Returns `(visibility, declaring_class)`.
pub fn lookupMemberVisibility(
    self: *const Checker,
    class: []const u8,
    name: []const u8,
) Allocator.Error!?struct { Visibility, []const u8 } {
    var seen = std.StringHashMap(void).init(self.allocator);
    defer seen.deinit();
    var frontier: std.ArrayList([]const u8) = .empty;
    defer frontier.deinit(self.allocator);
    try frontier.append(self.allocator, class);
    var steps: usize = 0;
    while (frontier.pop()) |c| {
        if (steps > 64) {
            break;
        }
        steps += 1;
        if ((try seen.getOrPut(c)).found_existing) {
            continue;
        }
        const info = self.classes.get(c) orelse continue;
        if (info.member_visibility.get(name)) |v| {
            return .{ v, c };
        }
        if (info.members.contains(name)) {
            return .{ Visibility.Public, c };
        }
        for (info.supertypes.items) |s| {
            try frontier.append(self.allocator, s);
        }
    }
    return null;
}

/// `protected` access through a receiver is allowed only when (a) the
/// current enclosing class is the declaring class or a subclass, AND
/// (b) the receiver's static class is the current enclosing class or
/// a subclass of it. Matches kotlinc's qualified-access rule.
pub fn protectedAccessAllowed(
    self: *const Checker,
    declaring_class: []const u8,
    recv_class: ?[]const u8,
) bool {
    if (self.class_stack.items.len == 0) {
        return false;
    }
    const enclosing = self.class_stack.items[self.class_stack.items.len - 1];
    const in_subclass =
        std.mem.eql(u8, enclosing, declaring_class) or isSubtypeOf(self, enclosing, declaring_class);
    if (!in_subclass) {
        return false;
    }
    const rc = recv_class orelse return true;
    return std.mem.eql(u8, rc, enclosing) or
        isSubtypeOf(self, rc, enclosing) or
        std.mem.eql(u8, rc, declaring_class) or
        isSubtypeOf(self, rc, declaring_class);
}

/// Emit T0031 when access at `member_span` to `name` on `declaring_class`
/// is forbidden by visibility. `recv_class` is the receiver's static
/// user-class when known, used for the `protected` qualified-access rule.
pub fn checkMemberVisibility(
    self: *Checker,
    declaring_class: []const u8,
    name: []const u8,
    recv_class: ?[]const u8,
    member_span: Span,
) Allocator.Error!void {
    const lookup_res = try lookupMemberVisibility(self, declaring_class, name) orelse return;
    const v = lookup_res[0];
    const decl_class = lookup_res[1];
    const allowed = switch (v) {
        .Public, .Internal => true,
        .Private => blk: {
            if (self.class_stack.items.len == 0) break :blk false;
            break :blk std.mem.eql(u8, self.class_stack.items[self.class_stack.items.len - 1], decl_class);
        },
        .Protected => protectedAccessAllowed(self, decl_class, recv_class),
    };
    if (allowed) {
        return;
    }
    const kind: []const u8 = switch (v) {
        .Private => "private",
        .Protected => "protected",
        else => "invisible",
    };
    const msg = try std.fmt.allocPrint(
        self.allocator,
        "Cannot access `{s}`: it is {s} in `{s}`",
        .{ name, kind, decl_class },
    );
    var d = Diagnostic.err(msg, member_span);
    _ = d.withCode(codes.TYPE_INVISIBLE_MEMBER);
    try self.diagnostics.emit(self.allocator, d);
}

/// Constructor / class-as-reference visibility. `private` top-level
/// class is reachable only from inside its file; `protected` at the
/// top level is illegal in Kotlin and we conservatively treat it the
/// same as `private`.
pub fn checkClassUseVisibility(
    self: *Checker,
    name: []const u8,
    info: *const ClassInfo,
    use_span: Span,
) Allocator.Error!void {
    // A per-primary-ctor visibility (`class Foo private constructor(...)`)
    // gates constructor invocations independently of the class visibility
    // itself.
    const same_file = info.decl_file == null or info.decl_file.? == use_span.file;
    if (info.primary_ctor_visibility) |pcv| {
        if (pcv == .Private and !same_file) {
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "Cannot access `{s}`: primary constructor is private",
                .{name},
            );
            var d = Diagnostic.err(msg, use_span);
            _ = d.withCode(codes.TYPE_INVISIBLE_MEMBER);
            try self.diagnostics.emit(self.allocator, d);
            return;
        }
    }
    switch (info.decl_visibility) {
        .Public, .Internal => return,
        else => {},
    }
    switch (info.decl_visibility) {
        .Private => if (same_file) return,
        .Protected => if (protectedAccessAllowed(self, name, null)) return,
        else => {},
    }
    const kind: []const u8 = switch (info.decl_visibility) {
        .Private => "private",
        .Protected => "protected",
        else => "invisible",
    };
    const msg = try std.fmt.allocPrint(
        self.allocator,
        "Cannot access `{s}`: class is {s}",
        .{ name, kind },
    );
    var d = Diagnostic.err(msg, use_span);
    _ = d.withCode(codes.TYPE_INVISIBLE_MEMBER);
    try self.diagnostics.emit(self.allocator, d);
}

/// When inside the body of a `public inline` function, references to an
/// `internal` top-level declaration require `@PublishedApi`.
pub fn checkPublishedApiUse(
    self: *Checker,
    name: []const u8,
    visibility: Visibility,
    target_anns: []const Annotation,
    use_span: Span,
) Allocator.Error!void {
    if (visibility != .Internal) {
        return;
    }
    const in_public_inline = self.public_inline_stack.items.len != 0 and
        self.public_inline_stack.items[self.public_inline_stack.items.len - 1];
    if (!in_public_inline) {
        return;
    }
    if (helpers.hasPublishedApi(target_anns)) {
        return;
    }
    const msg = try std.fmt.allocPrint(
        self.allocator,
        "Cannot access `{s}` from a public inline function: it is `internal` and not annotated `@PublishedApi`",
        .{name},
    );
    var d = Diagnostic.err(msg, use_span);
    _ = d.withCode(codes.TYPE_INVISIBLE_MEMBER);
    try self.diagnostics.emit(self.allocator, d);
}

/// Emit T0031/T0032 when a bare-name reference resolves to a `private`
/// top-level fn / property declared in another file. `decl_file` is the
/// file of the declaration; `use_span` carries the access site's file.
pub fn checkTopLevelVisibility(
    self: *Checker,
    name: []const u8,
    visibility: Visibility,
    decl_file: FileId,
    use_span: Span,
) Allocator.Error!void {
    switch (visibility) {
        .Public, .Internal => return,
        else => {},
    }
    // Top-level `protected` is illegal in Kotlin; until we surface a
    // dedicated diagnostic, treat it as `private` and gate by file.
    if (use_span.file == decl_file) {
        return;
    }
    const msg = try std.fmt.allocPrint(
        self.allocator,
        "Cannot access `{s}`: it is private in its declaring file",
        .{name},
    );
    var d = Diagnostic.err(msg, use_span);
    _ = d.withCode(codes.TYPE_INVISIBLE_REFERENCE);
    try self.diagnostics.emit(self.allocator, d);
}

/// Walk a class's supertype chain looking for a member by simple name.
/// Returns the declared `Type` plus the user-class name when the
/// declared type names a user class (drives `expr_class` propagation
/// through chains like `foo.bar.baz`). The returned `Type` is cloned and
/// owned by `allocator`.
pub fn lookupMemberThroughChain(
    self: *const Checker,
    allocator: Allocator,
    class: []const u8,
    name: []const u8,
) Allocator.Error!?struct { Type, ?[]const u8 } {
    var seen = std.StringHashMap(void).init(self.allocator);
    defer seen.deinit();
    var frontier: std.ArrayList([]const u8) = .empty;
    defer frontier.deinit(self.allocator);
    try frontier.append(self.allocator, class);
    var steps: usize = 0;
    while (frontier.pop()) |c| {
        if (steps > 64) {
            break;
        }
        steps += 1;
        if ((try seen.getOrPut(c)).found_existing) {
            continue;
        }
        const info = self.classes.get(c) orelse continue;
        if (info.members.get(name)) |ty| {
            const cn = info.member_class.get(name);
            return .{ try ty.clone(allocator), cn };
        }
        for (info.supertypes.items) |s| {
            try frontier.append(self.allocator, s);
        }
    }
    return null;
}

/// Probe whether a member named `name` is reachable through `class`'s
/// supertype chain, without cloning the member type. Mirrors the
/// `lookup_member_through_chain(..).is_some()` uses in the DSL / super
/// checks below.
fn memberReachable(self: *const Checker, class: []const u8, name: []const u8) Allocator.Error!bool {
    var seen = std.StringHashMap(void).init(self.allocator);
    defer seen.deinit();
    var frontier: std.ArrayList([]const u8) = .empty;
    defer frontier.deinit(self.allocator);
    try frontier.append(self.allocator, class);
    var steps: usize = 0;
    while (frontier.pop()) |c| {
        if (steps > 64) {
            break;
        }
        steps += 1;
        if ((try seen.getOrPut(c)).found_existing) {
            continue;
        }
        const info = self.classes.get(c) orelse continue;
        if (info.members.contains(name)) {
            return true;
        }
        for (info.supertypes.items) |s| {
            try frontier.append(self.allocator, s);
        }
    }
    return false;
}

/// A bare member reference inside nested DSL lambdas must resolve against
/// the innermost implicit receiver whenever any closer receiver shares a
/// dsl marker with the receiver that actually owns the member. Emits
/// T0113 at `member_span` otherwise.
pub fn enforceDslScopeForMember(self: *Checker, name: []const u8, member_span: Span) Allocator.Error!void {
    const stack = self.dsl_receiver_stack.items;
    if (stack.len < 2) {
        return;
    }
    const last_idx = stack.len - 1;
    var resolved: ?usize = null;
    for (stack, 0..) |r, i| {
        if (try memberReachable(self, r.name, name)) {
            resolved = i;
        }
    }
    const idx = resolved orelse return;
    if (idx == last_idx) {
        return;
    }
    const resolved_cls = stack[idx].name;
    const resolved_markers = &stack[idx].markers;
    if (resolved_markers.count() == 0) {
        return;
    }
    var inner_cls: ?[]const u8 = null;
    for (stack[idx + 1 ..]) |r| {
        if (markersIntersect(&r.markers, resolved_markers)) {
            inner_cls = r.name;
            break;
        }
    }
    const inner = inner_cls orelse return;
    const msg = try std.fmt.allocPrint(
        self.allocator,
        "member `{s}` of `{s}` is shadowed by a closer DSL receiver of type `{s}`",
        .{ name, resolved_cls, inner },
    );
    var d = Diagnostic.err(msg, member_span);
    _ = d.withCode(codes.TYPE_DSL_SCOPE_VIOLATION);
    try self.diagnostics.emit(self.allocator, d);
}

/// `this@Outer.b` is rejected when a closer implicit receiver shares a
/// marker with `Outer` and also exposes `b`.
pub fn enforceDslScopeForQualifiedThis(
    self: *Checker,
    qualifier: []const u8,
    member_name: []const u8,
    member_span: Span,
) Allocator.Error!void {
    const stack = self.dsl_receiver_stack.items;
    if (stack.len < 2) {
        return;
    }
    var idx_opt: ?usize = null;
    for (stack, 0..) |r, i| {
        if (std.mem.eql(u8, r.name, qualifier)) {
            idx_opt = i;
            break;
        }
    }
    const idx = idx_opt orelse return;
    if (idx == stack.len - 1) {
        return;
    }
    const resolved_cls = stack[idx].name;
    const resolved_markers = &stack[idx].markers;
    if (resolved_markers.count() == 0) {
        return;
    }
    if (!try memberReachable(self, resolved_cls, member_name)) {
        return;
    }
    var inner_cls: ?[]const u8 = null;
    for (stack[idx + 1 ..]) |r| {
        if (markersIntersect(&r.markers, resolved_markers)) {
            inner_cls = r.name;
            break;
        }
    }
    const inner = inner_cls orelse return;
    const msg = try std.fmt.allocPrint(
        self.allocator,
        "member `{s}` of `{s}` is shadowed by a closer DSL receiver of type `{s}`",
        .{ member_name, resolved_cls, inner },
    );
    var d = Diagnostic.err(msg, member_span);
    _ = d.withCode(codes.TYPE_DSL_SCOPE_VIOLATION);
    try self.diagnostics.emit(self.allocator, d);
}

/// True when `markers` contains any key that also appears in `against`.
fn markersIntersect(markers: *const std.StringHashMap(void), against: *const std.StringHashMap(void)) bool {
    var it = markers.keyIterator();
    while (it.next()) |k| {
        if (against.contains(k.*)) return true;
    }
    return false;
}

/// `a name b` (`is_infix == true`) must resolve to a function declared
/// with the `infix` modifier. Walks top-level fns, the lhs's class
/// members, and extension functions visible on the lhs's class chain;
/// emits T0029 when no candidate has the modifier set.
pub fn checkInfixModifier(self: *Checker, callee: *const Expr, args: []const Expr, call_span: Span) Allocator.Error!void {
    const segments = switch (callee.*) {
        .Path => |p| p.segments,
        else => return,
    };
    if (segments.len != 1) {
        return;
    }
    const name = segments[0].name;
    var found = false;
    var any = false;
    if (self.fns.get(name)) |sigs| {
        for (sigs.items) |s| {
            any = true;
            if (s.is_infix) {
                found = true;
            }
        }
    }
    if (!found and args.len > 0) {
        const lhs = &args[0];
        const lhs_class = self.expr_class.get(lhs.span());
        if (lhs_class) |cn| {
            var seen = std.StringHashMap(void).init(self.allocator);
            defer seen.deinit();
            var frontier: std.ArrayList([]const u8) = .empty;
            defer frontier.deinit(self.allocator);
            try frontier.append(self.allocator, cn);
            var steps: usize = 0;
            while (frontier.pop()) |c| {
                if (steps > 64) {
                    break;
                }
                steps += 1;
                if ((try seen.getOrPut(c)).found_existing) {
                    continue;
                }
                if (self.classes.get(c)) |info| {
                    if (info.member_flags.get(name)) |flags| {
                        any = true;
                        if (flags.is_infix) {
                            found = true;
                            break;
                        }
                    }
                    for (info.supertypes.items) |s| {
                        try frontier.append(self.allocator, s);
                    }
                }
            }
            if (!found) {
                var keys: std.ArrayList([]const u8) = .empty;
                defer keys.deinit(self.allocator);
                try keys.append(self.allocator, cn);
                var seen2 = std.StringHashMap(void).init(self.allocator);
                defer seen2.deinit();
                try seen2.put(cn, {});
                var f2: std.ArrayList([]const u8) = .empty;
                defer f2.deinit(self.allocator);
                try f2.append(self.allocator, cn);
                var steps2: usize = 0;
                while (f2.pop()) |c| {
                    if (steps2 > 64) {
                        break;
                    }
                    steps2 += 1;
                    if (self.classes.get(c)) |info| {
                        for (info.supertypes.items) |s| {
                            if (!(try seen2.getOrPut(s)).found_existing) {
                                try keys.append(self.allocator, s);
                                try f2.append(self.allocator, s);
                            }
                        }
                    }
                }
                try keys.append(self.allocator, "Any");
                for (keys.items) |key| {
                    if (self.extensions.get(key)) |list| {
                        for (list.items) |ext| {
                            if (std.mem.eql(u8, ext.name, name)) {
                                any = true;
                                if (ext.sig.is_infix) {
                                    found = true;
                                    break;
                                }
                            }
                        }
                    }
                    if (found) {
                        break;
                    }
                }
            }
        }
    }
    if (any and !found) {
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "`{s}` is not declared with the `infix` modifier",
            .{name},
        );
        var d = Diagnostic.err(msg, call_span);
        _ = d.withCode(codes.TYPE_INFIX_MODIFIER_REQUIRED);
        try self.diagnostics.emit(self.allocator, d);
    }
}

/// Walk every (f, g) declared in the same scope at the same c-level
/// partition. The phantom call site is fully-specified (every parameter
/// supplied, no defaults used), so we only consider pairs of equal arity.
/// If neither dominates the other on the pairwise MSC test and the case-3
/// tiebreakers also fail to pick a winner, the pair is a compile-time
/// conflict.
pub fn checkConflictingOverloads(self: *Checker) Allocator.Error!void {
    var pairs: std.ArrayList(OverloadPair) = .empty;
    defer pairs.deinit(self.allocator);
    var fn_it = self.fns.iterator();
    while (fn_it.next()) |entry| {
        const name = entry.key_ptr.*;
        const sigs = entry.value_ptr.items;
        if (sigs.len < 2) {
            continue;
        }
        var i: usize = 0;
        while (i < sigs.len) : (i += 1) {
            var j: usize = i + 1;
            while (j < sigs.len) : (j += 1) {
                const a = &sigs[i];
                const b = &sigs[j];
                if (a.params.len != b.params.len) {
                    continue;
                }
                // Two packages may each declare the same signature —
                // kotlinc's conflicting-overloads domain is one package.
                if (!sameDeclPackage(self, a.decl_span, b.decl_span)) {
                    continue;
                }
                const n = a.params.len;
                const a_ge_b = try helpers.atLeastAsApplicable(self.allocator, a, b, n, &self.classes);
                const b_ge_a = try helpers.atLeastAsApplicable(self.allocator, b, a, n, &self.classes);
                if (!(a_ge_b and b_ge_a)) {
                    continue;
                }
                // Case 3 tiebreakers: non-parameterized, fewer defaults,
                // no-vararg.
                if ((a.type_param_count == 0) != (b.type_param_count == 0)) {
                    continue;
                }
                const a_defaults = countTrue(a.has_default);
                const b_defaults = countTrue(b.has_default);
                if (a_defaults != b_defaults) {
                    continue;
                }
                const a_va = anyTrue(a.is_vararg);
                const b_va = anyTrue(b.is_vararg);
                if (a_va != b_va) {
                    continue;
                }
                if (a.decl_span) |sa| {
                    if (b.decl_span) |sb| {
                        try pairs.append(self.allocator, .{ .a = sa, .b = sb, .name = name });
                    }
                }
            }
        }
    }
    for (pairs.items) |pair| {
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "Conflicting overloads for `{s}`",
            .{pair.name},
        );
        var d = Diagnostic.err(msg, pair.a);
        _ = d.withCode(codes.TYPE_CONFLICTING_OVERLOADS);
        try self.diagnostics.emit(self.allocator, d);
    }
}

/// Whether two declaration sites live in the same package, judged by
/// their files' package headers (the multi-file entry point records one
/// package per FileId; a missing entry is the root package).
fn sameDeclPackage(self: *Checker, a: ?Span, b: ?Span) bool {
    const sa = a orelse return true;
    const sb = b orelse return true;
    const pa = self.file_packages.get(sa.file.int()) orelse "";
    const pb = self.file_packages.get(sb.file.int()) orelse "";
    return std.mem.eql(u8, pa, pb);
}

fn countTrue(flags: []const bool) usize {
    var count: usize = 0;
    for (flags) |h| {
        if (h) count += 1;
    }
    return count;
}

fn anyTrue(flags: []const bool) bool {
    for (flags) |v| {
        if (v) return true;
    }
    return false;
}

/// A compound assignment `A op= B` is ambiguous when the LHS receiver's
/// class declares *both* the `op` binary operator (`plus` / `minus` /
/// `times` / `div` / `rem`) and the matching `opAssign` form
/// (`plusAssign` / …). Emits T0079.
pub fn checkCompoundAssignAmbiguity(
    self: *Checker,
    target: *const Expr,
    op: AssignOp,
    sp: Span,
) Allocator.Error!void {
    const op_name: []const u8, const assign_name: []const u8 = switch (op) {
        .Add => .{ "plus", "plusAssign" },
        .Sub => .{ "minus", "minusAssign" },
        .Mul => .{ "times", "timesAssign" },
        .Div => .{ "div", "divAssign" },
        .Rem => .{ "rem", "remAssign" },
        .Assign => return,
    };
    const class_name: ?[]const u8 = switch (target.*) {
        .Path => |p| if (p.segments.len == 1)
            (if (lookup(self, p.segments[0].name)) |b| b.class_name else null)
        else
            self.expr_class.get(target.span()),
        .Member => |m| self.expr_class.get(m.receiver.span()),
        .Index => |x| self.expr_class.get(x.receiver.span()),
        else => self.expr_class.get(target.span()),
    };
    const cn = class_name orelse return;
    const info = self.classes.get(cn) orelse return;
    const has_op = info.members.contains(op_name);
    const has_assign = info.members.contains(assign_name);
    if (has_op and has_assign) {
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "Compound assignment `{s}=` is ambiguous: `{s}` declares both `{s}` and `{s}`",
            .{ op_name, cn, op_name, assign_name },
        );
        var d = Diagnostic.err(msg, sp);
        _ = d.withCode(codes.TYPE_ASSIGN_OPERATOR_AMBIGUITY);
        try self.diagnostics.emit(self.allocator, d);
    }
}

/// `super<Q>.f(...)` requires `Q` to be an immediate supertype of the
/// enclosing class. Emits T0073 otherwise.
pub fn checkSuperQualifier(self: *Checker, qualifier: *const TypeRef, super_span: Span) Allocator.Error!void {
    if (self.class_stack.items.len == 0) {
        return;
    }
    const enclosing = self.class_stack.items[self.class_stack.items.len - 1];
    const info = self.classes.get(enclosing) orelse return;
    const q_name = qualifier.name.name;
    var is_super = false;
    for (info.supertypes.items) |s| {
        if (std.mem.eql(u8, s, q_name)) {
            is_super = true;
            break;
        }
    }
    if (!is_super) {
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "`super<{s}>` is not allowed: `{s}` is not an immediate supertype of `{s}`",
            .{ q_name, q_name, enclosing },
        );
        var d = Diagnostic.err(msg, super_span);
        _ = d.withCode(codes.TYPE_SUPER_QUALIFIER_NOT_SUPERTYPE);
        try self.diagnostics.emit(self.allocator, d);
    }
}

/// Basic super-form: walk the enclosing class's direct supertypes and emit
/// T0093 when two or more contribute a member named `name`. The diagnostic
/// encourages disambiguation via `super<TypeName>.name(...)`.
pub fn checkAmbiguousSuper(self: *Checker, name: []const u8, super_span: Span) Allocator.Error!void {
    if (self.class_stack.items.len == 0) {
        return;
    }
    const enclosing = self.class_stack.items[self.class_stack.items.len - 1];
    const info = self.classes.get(enclosing) orelse return;
    var contributors: std.ArrayList([]const u8) = .empty;
    defer contributors.deinit(self.allocator);
    for (info.supertypes.items) |s| {
        if (try memberReachable(self, s, name)) {
            try contributors.append(self.allocator, s);
        }
    }
    if (contributors.items.len >= 2) {
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(self.allocator);
        for (contributors.items, 0..) |c, i| {
            if (i > 0) try joined.appendSlice(self.allocator, " and ");
            try joined.appendSlice(self.allocator, c);
        }
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "`super.{s}` is ambiguous: members named `{s}` exist in {s}. Use `super<TypeName>.{s}(...)` to disambiguate.",
            .{ name, name, joined.items, name },
        );
        var d = Diagnostic.err(msg, super_span);
        _ = d.withCode(codes.TYPE_AMBIGUOUS_SUPER);
        try self.diagnostics.emit(self.allocator, d);
    }
}

test {
    std.testing.refAllDecls(@This());
}
