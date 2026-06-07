//! Smart-cast narrowing: consumes the CFG smart-cast / VIA / reachability
//! results to answer flow-sensitive queries (narrowed type, narrowed class,
//! GADT substitution, definite assignment, reachability) plus the env-frame
//! helpers and sealed-`when` exhaustiveness check. Free functions over
//! `*Checker`.

const std = @import("std");

const span = @import("span");
const ast = @import("ast");
const types = @import("types");
const cfa = @import("cfa");

const root = @import("../check.zig");
const helpers = @import("helpers.zig");

const Allocator = std.mem.Allocator;
const Span = span.Span;
const Checker = root.Checker;
const Binding = root.Binding;
const Frame = root.Frame;
const Class = ast.Class;
const Block = ast.Block;
const Stmt = ast.Stmt;
const Property = ast.Property;
const Expr = ast.Expr;
const WhenBranch = ast.WhenBranch;
const Type = types.Type;
const Diagnostic = root.Diagnostic;
const codes = root.codes;

const smartcast = cfa.analyses.smartcast;
const via = cfa.analyses.via;
const reachable = cfa.analyses.reachable;
const Place = cfa.Place;

/// Narrow the static type of the value path referenced by `e` to `ty`
/// along the current branch. Smart-cast narrowing is driven by the CFG
/// `Assume` nodes consumed in `cfgNarrowedAt`; this phase hook is retained
/// so the root binds a uniform entry point.
pub fn narrow(self: *Checker, e: *const Expr, ty: Type) Allocator.Error!void {
    _ = self;
    _ = e;
    _ = ty;
}

// ---- env helpers ----------------------------------------------------

pub fn pushFrame(self: *Checker) Allocator.Error!void {
    try self.frames.append(self.allocator, Frame.init(self.allocator));
}

pub fn popFrame(self: *Checker) void {
    if (self.frames.pop()) |f| {
        var frame = f;
        frame.deinit();
    }
}

pub fn currentFrame(self: *Checker) *Frame {
    std.debug.assert(self.frames.items.len > 0);
    return &self.frames.items[self.frames.items.len - 1];
}

pub fn lookup(self: *const Checker, name: []const u8) ?*const Binding {
    var i: usize = self.frames.items.len;
    while (i > 0) {
        i -= 1;
        if (self.frames.items[i].bindings.getPtr(name)) |b| {
            return b;
        }
    }
    return null;
}

/// Narrowed type at the expression located at `query_span`.
/// Routes through the CFG smart-cast analysis: every refinement
/// kind the typechecker historically tracked on Frame.narrowings
/// (is / null / cross-ref-eq / && / || / as / !! / bound aliases /
/// stdlib contracts) is now emitted as an Assume node by the
/// lowering and consumed here.
pub fn lookupNarrowedAt(self: *const Checker, name: []const u8, query_span: Span) Allocator.Error!?Type {
    return cfgNarrowedAt(self, name, query_span);
}

/// CFG-derived narrowed type for `name` at `query_span`. Walks
/// the bound-smart-cast alias chain when the place itself has
/// no recorded fact. Returns `null` if the CFG offers nothing
/// more specific than the declared type.
pub fn cfgNarrowedAt(self: *const Checker, name: []const u8, query_span: Span) Allocator.Error!?Type {
    const fn_span = lastSpan(self.cfg_fn_stack.items) orelse return null;
    const lowered = self.lowerings.get(fn_span) orelse return null;
    const pos_entry = lowered.span_to_pos.get(.{ .start = query_span.start, .end = query_span.end }) orelse return null;
    const bid = pos_entry.block;
    const pos = pos_entry.node_idx;

    var declared = try cfgDeclaredTypes(self);
    defer declared.deinit(self.allocator);

    const entry = (try solveBlockEntry(self.allocator, lowered, bid, declared.map())) orelse return null;
    var states = try smartcast.statesWithinBlockWithDeclared(
        self.allocator,
        &lowered.cfg,
        bid,
        entry,
        &lowered.reg_to_place,
        declared.map(),
    );
    defer deinitSmartStates(self.allocator, &states);
    if (pos >= states.items.len) return null;
    const state = &states.items[pos];

    var place = Place{ .Local = .{ .name = name } };
    var step: usize = 0;
    while (step < 8) : (step += 1) {
        if (smartFact(state, place)) |fact| {
            if (fact.narrowed) |t| {
                // For a user-class narrowing the underlying Type
                // is `Unresolved`; the typechecker treats that as
                // "permissive" and recovers the class via
                // `cfgNarrowedClassAt`. Return it so callers get
                // the same shape as the legacy frame path.
                if (fact.null == .NonNull and t != .Unresolved) {
                    return try t.nonNull().clone(self.allocator);
                }
                return try t.clone(self.allocator);
            }
            // No type-narrowing but the place is known non-null
            // (or definitely null). Project the declared type's
            // non-null form so the caller sees a usable Type.
            if (fact.null == .NonNull) {
                const bound: ?Type = switch (place) {
                    .Local => |sym| if (lookup(self, sym.name)) |b| b.ty else null,
                    else => null,
                };
                if (bound) |declared_ty| {
                    if (declared_ty.isNullable()) {
                        return try declared_ty.nonNull().clone(self.allocator);
                    }
                }
            }
        }
        switch (place) {
            .Local => |sym| {
                if (lowered.aliases.get(.{ .name = sym.name })) |next| {
                    place = next;
                    continue;
                }
            },
            else => {},
        }
        break;
    }
    return null;
}

/// GADT-style refinement: when a smart-cast narrowing at
/// `query_span` has refined a place from `Super<T>` to a
/// subclass whose typed-supertype chain instantiates
/// `Super<f(...)>`, derive the substitution that unifies `T`
/// with the corresponding position in `f(...)`. Returns the
/// per-type-parameter substitution accumulated over every
/// in-scope place at this program point; empty when the CFG
/// has no class narrowings or the declared types don't carry
/// type parameters.
pub fn cfgGadtSubstAt(self: *const Checker, query_span: Span) Allocator.Error!std.StringHashMap(Type) {
    var subst = std.StringHashMap(Type).init(self.allocator);
    errdefer deinitSubst(self.allocator, &subst);

    const fn_span = lastSpan(self.cfg_fn_stack.items) orelse return subst;
    const lowered = self.lowerings.get(fn_span) orelse return subst;
    const pos_entry = lowered.span_to_pos.get(.{ .start = query_span.start, .end = query_span.end }) orelse return subst;
    const bid = pos_entry.block;
    const pos = pos_entry.node_idx;

    var declared = try cfgDeclaredTypes(self);
    defer declared.deinit(self.allocator);

    const entry = (try solveBlockEntry(self.allocator, lowered, bid, declared.map())) orelse return subst;
    var states = try smartcast.statesWithinBlockWithDeclared(
        self.allocator,
        &lowered.cfg,
        bid,
        entry,
        &lowered.reg_to_place,
        declared.map(),
    );
    defer deinitSmartStates(self.allocator, &states);
    if (pos >= states.items.len) return subst;
    const state = &states.items[pos];

    for (state.entries.items) |*ent| {
        const fact = ent.value;
        const narrowed_class = fact.narrowed_class orelse continue;
        const sym = switch (ent.key) {
            .Local => |s| s,
            else => continue,
        };
        const binding = lookup(self, sym.name) orelse continue;
        const non_null = binding.ty.nonNull();
        const gen = switch (non_null.*) {
            .Generic => |g| g,
            else => continue,
        };
        const declared_head = gen.name;
        const declared_args = gen.args;
        const supertype_args = (try walkSupertypeArgs(self, narrowed_class, declared_head)) orelse continue;
        defer {
            for (supertype_args) |*t| t.deinit(self.allocator);
            self.allocator.free(supertype_args);
        }
        var i: usize = 0;
        while (i < declared_args.len and i < supertype_args.len) : (i += 1) {
            const declared_arg = declared_args[i];
            if (declared_arg.is_star) continue;
            const tp_name = switch (declared_arg.ty) {
                .TypeParam => |n| n,
                else => continue,
            };
            const super_arg = supertype_args[i];
            switch (super_arg) {
                .TypeParam, .Unresolved => continue,
                else => {},
            }
            const gop = try subst.getOrPut(tp_name);
            if (!gop.found_existing) {
                gop.key_ptr.* = try self.allocator.dupe(u8, tp_name);
                gop.value_ptr.* = try super_arg.clone(self.allocator);
            }
        }
    }
    return subst;
}

/// Build a synthetic `Block` representing the primary-
/// constructor init flow: every declared property becomes a
/// `Stmt.Decl(Decl.Property(_))` in source order, and every
/// init block contributes its statements at the position it
/// appears in `c.members`. Lowering this block produces a CFG
/// whose exit state's VIA tells us which uninitialized
/// properties were definitely assigned along every primary-
/// ctor path.
pub fn synthesizeClassInitBody(self: *const Checker, c: *const Class) Allocator.Error!Block {
    var stmts: std.ArrayList(Stmt) = .empty;
    errdefer stmts.deinit(self.allocator);
    // Primary-param properties are pre-assigned by their
    // matching ctor argument; emit a declared-and-assigned
    // shadow as a degenerate `val name = name` so VIA seeds
    // them as Assigned at the synthetic entry.
    for (c.primary_params) |*p| {
        if (p.property != null) {
            const segments = try self.allocator.alloc(ast.Ident, 1);
            segments[0] = p.name;
            const shadow = Property{
                .mutable = p.property == true,
                .name = p.name,
                .receiver_type = null,
                .ty = p.ty,
                .init = Expr{ .Path = .{ .segments = segments, .span = p.name.span } },
                .delegate = null,
                .getter = null,
                .setter = null,
                .is_abstract = false,
                .is_open = false,
                .is_override = false,
                .is_lateinit = false,
                .is_const = false,
                .is_inline = false,
                .is_expect = false,
                .is_actual = false,
                .setter_visibility = null,
                .span = p.name.span,
                .visibility = p.visibility,
                .annotations = &.{},
            };
            try stmts.append(self.allocator, .{ .Decl = .{ .Property = shadow } });
        }
    }
    // Walk members in source order so property initializers
    // interleave with init blocks correctly.
    for (c.members) |*m| {
        if (m.* == .Property) {
            const p = m.Property;
            if (p.getter != null or p.delegate != null) {
                continue;
            }
            try stmts.append(self.allocator, .{ .Decl = .{ .Property = p } });
        }
    }
    for (c.init_blocks) |*ib| {
        for (ib.stmts) |s| {
            try stmts.append(self.allocator, s);
        }
    }
    return Block{
        .stmts = try stmts.toOwnedSlice(self.allocator),
        .span = c.name.span,
    };
}

/// VIA classification of `name` at the *exit* of the CFG whose
/// owning span matches `cfg_span`. Used by the class
/// post-init walker to ask "did every primary-ctor path
/// assign this property?" against the synthetic class-init
/// CFG built by `check_class`.
pub fn cfgViaUnassignedAtExit(self: *const Checker, cfg_span: Span, name: []const u8) Allocator.Error!?bool {
    const lowered = self.lowerings.get(cfg_span) orelse return null;
    var states = try via.solveVia(self.allocator, &lowered.cfg);
    defer deinitViaStates(self.allocator, &states);
    if (lowered.cfg.exits.items.len == 0) return null;
    const exit = lowered.cfg.exits.items[0];
    if (exit.int() >= states.items.len) return null;
    const state = &states.items[exit.int()];
    const place = Place{ .Local = .{ .name = name } };
    return viaVerdict(state, place);
}

/// Returns true when the CFG's VIA analysis classifies `name`
/// as "may not be assigned" at the program point of
/// `query_span`. Drives the T0020 definite-assignment check
/// alongside the legacy `assigned` set; once the CFG matches
/// the legacy behaviour everywhere, the set drops out.
pub fn cfgViaUnassignedAt(self: *const Checker, name: []const u8, query_span: Span) Allocator.Error!?bool {
    const fn_span = lastSpan(self.cfg_fn_stack.items) orelse return null;
    const lowered = self.lowerings.get(fn_span) orelse return null;
    const pos_entry = lowered.span_to_pos.get(.{ .start = query_span.start, .end = query_span.end }) orelse return null;
    const bid = pos_entry.block;
    const pos = pos_entry.node_idx;

    var solved = try via.solveVia(self.allocator, &lowered.cfg);
    defer deinitViaStates(self.allocator, &solved);
    if (bid.int() >= solved.items.len) return null;
    const entry = try solved.items[bid.int()].clone(self.allocator);

    const states = try via.statesWithinBlock(self.allocator, &lowered.cfg, bid, entry);
    defer {
        for (states) |*s| s.deinit(self.allocator);
        self.allocator.free(states);
    }
    if (pos >= states.len) return null;
    const state = &states[pos];
    const place = Place{ .Local = .{ .name = name } };
    // `Flat.Bottom` means the place has no VIA fact at this
    // program point — typically a parameter (assigned at
    // function entry, never `DeclLocal`-ed) or a name the
    // typechecker tracks outside the CFG. Return `null` so
    // callers fall back to other signals; only return a
    // verdict when the CFG genuinely tracks the place.
    return viaVerdict(state, place);
}

/// Returns true when the CFG's reachability analysis classifies
/// the block containing `query_span` as unreachable. Drives the
/// W0002 unreachable-code warning. The typechecker's `types` map
/// is threaded through so `Nothing`-returning expressions
/// (`error(...)`, `TODO()`) prune their block's successors the
/// same way an explicit `return` / `throw` would.
pub fn cfgIsUnreachableAt(self: *const Checker, query_span: Span) Allocator.Error!?bool {
    const fn_span = lastSpan(self.cfg_fn_stack.items) orelse return null;
    const lowered = self.lowerings.get(fn_span) orelse return null;
    const pos_entry = lowered.span_to_pos.get(.{ .start = query_span.start, .end = query_span.end }) orelse return null;
    const bid = pos_entry.block;

    var type_map = reachable.TypeMap.init(self.allocator);
    defer {
        var it = type_map.valueIterator();
        while (it.next()) |t| t.deinit(self.allocator);
        type_map.deinit();
    }
    var it = self.types.iterator();
    while (it.next()) |e| {
        try type_map.put(
            .{ .start = e.key_ptr.start, .end = e.key_ptr.end },
            try e.value_ptr.clone(self.allocator),
        );
    }
    var r = try reachable.analyseWithTypes(self.allocator, &lowered.cfg, &type_map);
    defer r.deinit(self.allocator);
    return !r.isReachable(bid);
}

/// Per-place declared-type map drawn from every binding visible
/// in the active frames. Fed into the smart-cast pass so
/// `AssumeRefEq` can narrow each side to the other's declared
/// type when no prior fact applies.
pub fn cfgDeclaredTypes(self: *const Checker) Allocator.Error!DeclaredTypes {
    var out = DeclaredTypes{ .entries = .empty };
    errdefer out.deinit(self.allocator);
    for (self.frames.items) |*frame| {
        var it = frame.bindings.iterator();
        while (it.next()) |e| {
            try out.entries.append(self.allocator, .{
                .key = Place{ .Local = .{ .name = try self.allocator.dupe(u8, e.key_ptr.*) } },
                .value = try e.value_ptr.ty.clone(self.allocator),
            });
        }
    }
    return out;
}

/// Owned per-place declared-type table mirroring Rust's
/// `HashMap<Place, Type>`. Bridged to the smart-cast pass via
/// `map()`, which yields a borrowed `PlaceTypeMap` over the
/// owned entries.
pub const DeclaredTypes = struct {
    entries: std.ArrayList(smartcast.PlaceTypeMap.Entry),

    pub fn map(self: *const DeclaredTypes) smartcast.PlaceTypeMap {
        return .{ .entries = self.entries.items };
    }

    pub fn deinit(self: *DeclaredTypes, allocator: Allocator) void {
        for (self.entries.items) |*e| {
            e.key.deinit(allocator);
            e.value.deinit(allocator);
        }
        self.entries.deinit(allocator);
    }
};

/// CFG-derived class-name narrowing for `name` at `query_span`.
/// Parallels `cfgNarrowedAt` for the user-class branch. Returns
/// an owned class-name string when narrowed.
pub fn cfgNarrowedClassAt(self: *const Checker, name: []const u8, query_span: Span) Allocator.Error!?[]const u8 {
    const fn_span = lastSpan(self.cfg_fn_stack.items) orelse return null;
    const lowered = self.lowerings.get(fn_span) orelse return null;
    const pos_entry = lowered.span_to_pos.get(.{ .start = query_span.start, .end = query_span.end }) orelse return null;
    const bid = pos_entry.block;
    const pos = pos_entry.node_idx;

    var declared = try cfgDeclaredTypes(self);
    defer declared.deinit(self.allocator);

    const entry = (try solveBlockEntry(self.allocator, lowered, bid, declared.map())) orelse return null;
    var states = try smartcast.statesWithinBlockWithDeclared(
        self.allocator,
        &lowered.cfg,
        bid,
        entry,
        &lowered.reg_to_place,
        declared.map(),
    );
    defer deinitSmartStates(self.allocator, &states);
    if (pos >= states.items.len) return null;
    const state = &states.items[pos];

    var place = Place{ .Local = .{ .name = name } };
    var step: usize = 0;
    while (step < 8) : (step += 1) {
        if (smartFact(state, place)) |fact| {
            if (fact.narrowed_class) |cn| {
                return try self.allocator.dupe(u8, cn);
            }
        }
        switch (place) {
            .Local => |sym| {
                if (lowered.aliases.get(.{ .name = sym.name })) |next| {
                    place = next;
                    continue;
                }
            },
            else => {},
        }
        break;
    }
    return null;
}

pub fn resolution(self: *const Checker) *const root.Resolution {
    return self.resolution;
}

// ---- sealed-`when` exhaustiveness ----------------------------------

/// True iff `candidate` is the same class as `target` or a transitive
/// subclass through the local class table.
pub fn isClassOrSubclass(self: *const Checker, candidate: []const u8, target: []const u8) bool {
    if (std.mem.eql(u8, candidate, target)) {
        return true;
    }
    return isSubtypeOf(self, candidate, target);
}

/// All concrete (non-abstract, non-interface, non-sealed) classes whose
/// transitive supertype chain contains `root_name`. Used as the leaf set
/// the branches must cover. Result and its elements are owned by the
/// caller.
pub fn sealedLeafSubclasses(self: *const Checker, root_name: []const u8) Allocator.Error![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| self.allocator.free(s);
        out.deinit(self.allocator);
    }
    var it = self.classes.iterator();
    while (it.next()) |e| {
        const name = e.key_ptr.*;
        const info = e.value_ptr;
        if (std.mem.eql(u8, name, root_name)) {
            continue;
        }
        if (info.is_interface) {
            continue;
        }
        if (!isSubtypeOf(self, name, root_name)) {
            continue;
        }
        // Treat sealed/abstract intermediates as non-leaves — their
        // concrete descendants are listed separately.
        if (info.is_sealed or info.is_abstract) {
            continue;
        }
        try out.append(self.allocator, try self.allocator.dupe(u8, name));
    }
    std.mem.sort([]const u8, out.items, {}, lessThanStr);
    return out.toOwnedSlice(self.allocator);
}

pub fn checkWhenExhaustive(
    self: *Checker,
    subject_class: []const u8,
    branches: []const WhenBranch,
    when_span: Span,
) Allocator.Error!void {
    const root_info = self.classes.get(subject_class) orelse return;
    if (!root_info.is_sealed) {
        return;
    }
    // Else branch trivially covers everything.
    for (branches) |*b| {
        for (b.patterns) |*p| {
            if (p.kind == .Else) {
                return;
            }
        }
    }
    const leaves = try sealedLeafSubclasses(self, subject_class);
    defer {
        for (leaves) |s| self.allocator.free(s);
        self.allocator.free(leaves);
    }
    if (leaves.len == 0) {
        return;
    }
    var missing: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(self.allocator);
    for (leaves) |leaf| {
        var covered = false;
        outer: for (branches) |*br| {
            for (br.patterns) |*p| {
                switch (p.kind) {
                    .IsType => |t| {
                        if (isClassOrSubclass(self, leaf, t.name.name)) {
                            covered = true;
                            break :outer;
                        }
                    },
                    else => {},
                }
            }
        }
        if (!covered) {
            try missing.append(self.allocator, leaf);
        }
    }
    if (missing.items.len != 0) {
        const list = try joinComma(self.allocator, missing.items);
        defer self.allocator.free(list);
        const inserted = if (missing.items.len == 1) missing.items[0] else list;
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "'when' expression must be exhaustive, add necessary 'is {s}' branches or 'else' branch.",
            .{inserted},
        );
        var d = Diagnostic.err(msg, when_span);
        _ = d.withCode(codes.TYPE_WHEN_NOT_EXHAUSTIVE);
        try self.diagnostics.emit(self.allocator, d);
    }
}

// ---- file-local helpers --------------------------------------------

/// Walk a class's supertype chain in `classes` looking for `sup`. Returns
/// false when `sub == sup` (an identity is not a strict subtype here).
/// Mirrors `Checker::is_subtype_of` from the declaration phase, kept local
/// until that phase lands.
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
        if (sliceContainsStr(seen.items, name)) {
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

/// Instantiate `target`'s type-arg list as seen from `subclass`. Mirrors
/// `Checker::walk_supertype_args` from the declaration phase, kept local
/// until that phase lands. Result and its elements are owned by the caller.
fn walkSupertypeArgs(self: *const Checker, subclass: []const u8, target: []const u8) Allocator.Error!?[]Type {
    const info = self.classes.get(subclass) orelse return null;
    if (std.mem.eql(u8, subclass, target)) {
        const out = try self.allocator.alloc(Type, info.type_param_names.items.len);
        errdefer self.allocator.free(out);
        for (info.type_param_names.items, out) |n, *dst| {
            dst.* = .{ .TypeParam = try self.allocator.dupe(u8, n) };
        }
        return out;
    }
    for (info.typed_supertypes.items) |s| {
        if (std.mem.eql(u8, s.name, target)) {
            const out = try self.allocator.alloc(Type, s.args.len);
            errdefer self.allocator.free(out);
            for (s.args, out) |*a, *dst| dst.* = try a.clone(self.allocator);
            return out;
        }
        if (try walkSupertypeArgs(self, s.name, target)) |deeper| {
            defer {
                for (deeper) |*t| t.deinit(self.allocator);
                self.allocator.free(deeper);
            }
            // Substitute the subclass's args into the deeper
            // result: if `subclass : Mid<X>` and
            // `Mid<X> : Target<f(X)>`, derive `Target<f(arg)>`
            // by replacing `X` in `deeper` with `s_args`.
            const mid_info = self.classes.get(s.name) orelse return null;
            var subst = std.StringHashMap(Type).init(self.allocator);
            defer deinitSubst(self.allocator, &subst);
            var i: usize = 0;
            while (i < mid_info.type_param_names.items.len and i < s.args.len) : (i += 1) {
                const name = try self.allocator.dupe(u8, mid_info.type_param_names.items[i]);
                try subst.put(name, try s.args[i].clone(self.allocator));
            }
            const substituted = try self.allocator.alloc(Type, deeper.len);
            errdefer self.allocator.free(substituted);
            for (deeper, substituted) |*t, *dst| {
                dst.* = try helpers.substituteTypeParams(self.allocator, t, &subst);
            }
            return substituted;
        }
    }
    return null;
}

fn lastSpan(items: []const Span) ?Span {
    if (items.len == 0) return null;
    return items[items.len - 1];
}

/// Solve the smart-cast analysis to fixpoint and return a freshly-cloned
/// entry-state for block `bid`, ready to feed `statesWithinBlock`. Returns
/// `null` when `bid` is out of range. Caller owns the returned lattice.
fn solveBlockEntry(
    allocator: Allocator,
    lowered: *const cfa.lower.Lowered,
    bid: cfa.BlockId,
    declared: smartcast.PlaceTypeMap,
) Allocator.Error!?smartcast.SmartCastLattice {
    var solved = try smartcast.solveWithDeclared(allocator, &lowered.cfg, &lowered.reg_to_place, declared);
    defer deinitSmartStates(allocator, &solved);
    if (bid.int() >= solved.items.len) return null;
    return try solved.items[bid.int()].clone(allocator);
}

fn smartFact(state: *const smartcast.SmartCastLattice, place: Place) ?*const smartcast.SmartCastFact {
    for (state.entries.items) |*e| {
        if (e.key.eql(place)) return &e.value;
    }
    return null;
}

fn viaVerdict(state: anytype, place: Place) ?bool {
    for (state.entries.items) |*e| {
        if (!e.key.eql(place)) continue;
        return switch (e.value) {
            .Bottom => null,
            .Value => |v| v == .Unassigned,
            .Top => true,
        };
    }
    return null;
}

fn deinitSmartStates(allocator: Allocator, states: *smartcast.SmartCastBlockStates) void {
    for (states.items) |*s| s.deinit(allocator);
    states.deinit(allocator);
}

fn deinitViaStates(allocator: Allocator, states: *via.ViaBlockStates) void {
    for (states.items) |*s| s.deinit(allocator);
    states.deinit(allocator);
}

fn deinitSubst(allocator: Allocator, subst: *std.StringHashMap(Type)) void {
    var it = subst.iterator();
    while (it.next()) |e| {
        allocator.free(e.key_ptr.*);
        e.value_ptr.deinit(allocator);
    }
    subst.deinit();
}

fn sliceContainsStr(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| {
        if (std.mem.eql(u8, h, needle)) return true;
    }
    return false;
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Join with ", " — caller owns the result.
fn joinComma(allocator: Allocator, items: []const []const u8) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    for (items, 0..) |s, i| {
        if (i > 0) aw.writer.writeAll(", ") catch return error.OutOfMemory;
        aw.writer.writeAll(s) catch return error.OutOfMemory;
    }
    return aw.toOwnedSlice();
}

test {
    std.testing.refAllDecls(@This());
}
