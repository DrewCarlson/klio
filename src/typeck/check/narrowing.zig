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

/// Phase hook for narrowing the value path `e` to `ty` along the current
/// branch. Narrowing itself comes from the CFG `Assume` nodes consumed in
/// `cfgNarrowedAt`; this exists so the root binds a uniform entry point.
pub fn narrow(self: *Checker, e: *const Expr, ty: Type) Allocator.Error!void {
    _ = self;
    _ = e;
    _ = ty;
}

/// Per-query analysis scratch. A fixpoint solve runs once per narrowing or
/// reachability query and its working set must be genuinely reclaimed
/// afterwards, which the driver's phase arena cannot do. The checker owns one
/// retained arena: each query resets it keeping capacity, so the steady state
/// allocates no new pages, and uses it for that query's dynamic extent only.
/// Queries never nest, and anything escaping one (types, class names,
/// substitutions) is cloned onto `self.allocator` before the next reset.
pub fn queryScratch(self: *const Checker) Allocator {
    _ = self.query_scratch.reset(.retain_capacity);
    return self.query_scratch.allocator();
}

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

/// Narrowed type at `query_span`. Every refinement kind (`is`, null,
/// cross-reference equality, `&&`/`||`, `as`, `!!`, bound aliases, stdlib
/// contracts) reaches here as an Assume node the lowering emitted.
pub fn lookupNarrowedAt(self: *const Checker, name: []const u8, query_span: Span) Allocator.Error!?Type {
    return cfgNarrowedAt(self, name, query_span);
}

/// CFG-derived narrowed type for `name` at `query_span`, following the
/// bound-smart-cast alias chain when the place itself has no fact. Null when
/// the CFG offers nothing more specific than the declared type.
pub fn cfgNarrowedAt(self: *const Checker, name: []const u8, query_span: Span) Allocator.Error!?Type {
    const scratch = queryScratch(self);
    const at = (try solvedSmartStateAt(self, scratch, query_span)) orelse return null;
    return stateNarrowedType(self, at.lowered, at.state, name);
}

/// A solved smart-cast state at one program point, alive on the query-scratch
/// arena until the next query resets it.
const SmartStateAt = struct {
    lowered: *const cfa.lower.Lowered,
    state: *const smartcast.SmartCastLattice,
};

/// Locate `query_span` in the enclosing function's CFG and solve the
/// smart-cast analysis up to that point. One solve serves every fact
/// extraction there. All working memory lives on `scratch`.
fn solvedSmartStateAt(self: *const Checker, scratch: Allocator, query_span: Span) Allocator.Error!?SmartStateAt {
    const fn_span = lastSpan(self.cfg_fn_stack.items) orelse return null;
    const lowered = self.lowerings.get(fn_span) orelse return null;
    const pos_entry = lowered.span_to_pos.get(.{ .start = query_span.start, .end = query_span.end }) orelse return null;
    const bid = pos_entry.block;
    const pos = pos_entry.node_idx;

    const declared = try cfgDeclaredTypes(self, scratch);
    const entry = (try solveBlockEntry(scratch, lowered, bid, declared.map())) orelse return null;
    const states = try smartcast.statesWithinBlockWithDeclared(
        scratch,
        &lowered.cfg,
        bid,
        entry,
        &lowered.reg_to_place,
        declared.map(),
    );
    if (pos >= states.items.len) return null;
    return .{ .lowered = lowered, .state = &states.items[pos] };
}

/// Narrowed type for `name` from a solved state, following the
/// bound-smart-cast alias chain. Cloned onto `self.allocator`.
fn stateNarrowedType(
    self: *const Checker,
    lowered: *const cfa.lower.Lowered,
    state: *const smartcast.SmartCastLattice,
    name: []const u8,
) Allocator.Error!?Type {
    var place = Place{ .Local = .{ .name = name } };
    var step: usize = 0;
    while (step < 8) : (step += 1) {
        if (smartFact(state, place)) |fact| {
            if (fact.narrowed) |t| {
                // A user-class narrowing carries `Unresolved` as its type,
                // which the checker treats permissively and pairs with the
                // class recovered by `cfgNarrowedClassAt`.
                if (fact.null == .NonNull and t != .Unresolved) {
                    return try t.nonNull().clone(self.allocator);
                }
                return try t.clone(self.allocator);
            }
            // No type narrowing, but the place is known non-null: project the
            // declared type's non-null form so the caller gets a usable Type.
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

/// Narrowed user-class name for `name` from a solved state, duped onto
/// `self.allocator`.
fn stateNarrowedClass(
    self: *const Checker,
    lowered: *const cfa.lower.Lowered,
    state: *const smartcast.SmartCastLattice,
    name: []const u8,
) Allocator.Error!?[]const u8 {
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

/// Every smart-cast fact the expression checker wants at one program point,
/// from a single dataflow solve. `narrowed` and `narrowed_class` are owned by
/// `self.allocator`; the caller owns `gadt`, keys and values alike.
pub const SmartFacts = struct {
    narrowed: ?Type = null,
    narrowed_class: ?[]const u8 = null,
    gadt: std.StringHashMap(Type),
};

/// Narrowed type, narrowed class and, under `want_gadt`, the GADT
/// substitution, all from one solve. `checkExpr` calls this once per name
/// read rather than solving the same CFG three times.
pub fn cfgSmartFactsAt(
    self: *const Checker,
    name: []const u8,
    query_span: Span,
    want_gadt: bool,
) Allocator.Error!SmartFacts {
    var out = SmartFacts{ .gadt = std.StringHashMap(Type).init(self.allocator) };
    const scratch = queryScratch(self);
    const at = (try solvedSmartStateAt(self, scratch, query_span)) orelse return out;
    out.narrowed_class = try stateNarrowedClass(self, at.lowered, at.state, name);
    out.narrowed = try stateNarrowedType(self, at.lowered, at.state, name);
    if (want_gadt) try stateGadtSubst(self, scratch, at.state, &out.gadt);
    return out;
}

/// GADT refinement: when a narrowing at `query_span` refines a place from
/// `Super<T>` to a subclass whose typed-supertype chain instantiates
/// `Super<f(...)>`, derive the substitution unifying `T` with the
/// corresponding position in `f(...)`. Accumulated over every in-scope place;
/// empty when there are no class narrowings or no type parameters in play.
pub fn cfgGadtSubstAt(self: *const Checker, query_span: Span) Allocator.Error!std.StringHashMap(Type) {
    var subst = std.StringHashMap(Type).init(self.allocator);
    errdefer deinitSubst(self.allocator, &subst);
    const scratch = queryScratch(self);
    const at = (try solvedSmartStateAt(self, scratch, query_span)) orelse return subst;
    try stateGadtSubst(self, scratch, at.state, &subst);
    return subst;
}

/// Accumulate into `subst` the GADT substitution implied by every
/// class-narrowed place in a solved state. Keys and values on
/// `self.allocator`.
fn stateGadtSubst(
    self: *const Checker,
    scratch: Allocator,
    state: *const smartcast.SmartCastLattice,
    subst: *std.StringHashMap(Type),
) Allocator.Error!void {
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
        const supertype_args = (try walkSupertypeArgs(self, scratch, narrowed_class, declared_head)) orelse continue;
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
}

/// A synthetic `Block` for the primary-constructor init flow: every declared
/// property becomes a `Stmt.Decl` in source order, and every init block
/// contributes its statements where it appears in `c.members`. Lowering it
/// gives a CFG whose exit VIA says which uninitialized properties are
/// definitely assigned along every primary-constructor path.
pub fn synthesizeClassInitBody(self: *const Checker, c: *const Class) Allocator.Error!Block {
    var stmts: std.ArrayList(Stmt) = .empty;
    errdefer stmts.deinit(self.allocator);
    // A primary-parameter property is pre-assigned by its matching argument,
    // so a degenerate `val name = name` seeds it as assigned at the synthetic
    // entry.
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
            const sp = try self.allocator.create(Property);
            sp.* = shadow;
            try stmts.append(self.allocator, .{ .Decl = .{ .Property = sp } });
        }
    }
    // Source order, so property initializers interleave with init blocks
    // correctly.
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

/// VIA classification of `name` at the exit of the CFG owned by `cfg_span`.
/// The class post-init walker asks this of the synthetic class-init CFG to
/// learn whether every primary-constructor path assigned a property.
pub fn cfgViaUnassignedAtExit(self: *const Checker, cfg_span: Span, name: []const u8) Allocator.Error!?bool {
    const lowered = self.lowerings.get(cfg_span) orelse return null;
    const scratch = queryScratch(self);
    const states = try via.solveVia(scratch, &lowered.cfg);
    if (lowered.cfg.exits.items.len == 0) return null;
    const exit = lowered.cfg.exits.items[0];
    if (exit.int() >= states.items.len) return null;
    const state = &states.items[exit.int()];
    const place = Place{ .Local = .{ .name = name } };
    return viaVerdict(state, place);
}

/// True when the CFG's VIA analysis classifies `name` as possibly unassigned
/// at `query_span`. Drives the definite-assignment check.
pub fn cfgViaUnassignedAt(self: *const Checker, name: []const u8, query_span: Span) Allocator.Error!?bool {
    const fn_span = lastSpan(self.cfg_fn_stack.items) orelse return null;
    const lowered = self.lowerings.get(fn_span) orelse return null;
    const pos_entry = lowered.span_to_pos.get(.{ .start = query_span.start, .end = query_span.end }) orelse return null;
    const bid = pos_entry.block;
    const pos = pos_entry.node_idx;

    const scratch = queryScratch(self);

    const solved = try via.solveVia(scratch, &lowered.cfg);
    if (bid.int() >= solved.items.len) return null;
    const entry = try solved.items[bid.int()].clone(scratch);

    const states = try via.statesWithinBlock(scratch, &lowered.cfg, bid, entry);
    if (pos >= states.len) return null;
    const state = &states[pos];
    const place = Place{ .Local = .{ .name = name } };
    // `Flat.Bottom` means the place has no VIA fact here: typically a
    // parameter, assigned at entry and never `DeclLocal`-ed, or a name tracked
    // outside the CFG. Answering null lets callers fall back to other signals,
    // so a verdict is returned only for a place the CFG genuinely tracks.
    return viaVerdict(state, place);
}

/// True when the CFG's reachability analysis classifies `query_span`'s block
/// as unreachable. The checker's `Nothing`-typed spans are threaded through,
/// so a `Nothing`-returning call such as `error(...)` prunes its block's
/// successors exactly as an explicit `return` or `throw` would.
pub fn cfgIsUnreachableAt(self: *Checker, query_span: Span) Allocator.Error!?bool {
    const fn_span = lastSpan(self.cfg_fn_stack.items) orelse return null;
    const lowered = self.lowerings.get(fn_span) orelse return null;
    const pos_entry = lowered.span_to_pos.get(.{ .start = query_span.start, .end = query_span.end }) orelse return null;
    const bid = pos_entry.block;

    // Reachability depends only on the CFG, immutable per function span, and
    // the set of `Nothing`-typed spans, so the solve is memoized per function
    // until that set changes. The query fires once per statement and without
    // the memo dominates whole-module checks.
    const gop = try self.reach_cache.getOrPut(fn_span);
    if (!gop.found_existing or gop.value_ptr.epoch != self.nothing_epoch) {
        const scratch = queryScratch(self);
        // The analysis only asks whether an expression in this CFG diverges,
        // so feed it this function's `Nothing` spans, filtered for current
        // membership, rather than the module-wide set.
        var type_map = reachable.TypeMap.init(scratch);
        if (self.nothing_by_fn.getPtr(fn_span)) |bucket| {
            var it = bucket.keyIterator();
            while (it.next()) |sp| {
                if (!self.nothing_spans.contains(sp.*)) continue;
                try type_map.put(.{ .start = sp.start, .end = sp.end }, .Nothing);
            }
        }
        const r = try reachable.analyseWithTypes(scratch, &lowered.cfg, &type_map);
        const kept = try self.allocator.dupe(bool, r.reachable);
        if (gop.found_existing) self.allocator.free(gop.value_ptr.reachable);
        gop.value_ptr.* = .{ .epoch = self.nothing_epoch, .reachable = kept };
    }
    const r = reachable.Reachability{ .reachable = gop.value_ptr.reachable };
    if (!r.isReachable(bid)) return true;
    // A statement is also unreachable when an earlier node in its own block
    // diverges: an `Unreachable` marker, or an `Eval` of a `Nothing`-typed
    // expression such as a call to a `Nothing`-returning function.
    const block = lowered.cfg.block(bid);
    const upto = @min(pos_entry.node_idx, block.nodes.items.len);
    for (block.nodes.items[0..upto]) |n| {
        switch (n) {
            .Unreachable => return true,
            .Eval => |e| {
                const sp = Span{ .file = fn_span.file, .start = e.expr.span.start, .end = e.expr.span.end };
                if (self.nothing_spans.contains(sp)) return true;
            },
            else => {},
        }
    }
    return false;
}

/// Per-place declared types drawn from every binding visible in the active
/// frames. The smart-cast pass reads it so `AssumeRefEq` can narrow each side
/// to the other's declared type when no prior fact applies.
pub fn cfgDeclaredTypes(self: *const Checker, allocator: Allocator) Allocator.Error!DeclaredTypes {
    var out = DeclaredTypes{ .entries = .empty };
    errdefer out.deinit(allocator);
    for (self.frames.items) |*frame| {
        var it = frame.bindings.iterator();
        while (it.next()) |e| {
            try out.entries.append(allocator, .{
                .key = Place{ .Local = .{ .name = try allocator.dupe(u8, e.key_ptr.*) } },
                .value = try e.value_ptr.ty.clone(allocator),
            });
        }
    }
    return out;
}

/// Owned `Place` to `Type` table. `map()` yields a borrowed `PlaceTypeMap`
/// over these entries for the smart-cast pass.
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

/// The user-class counterpart of `cfgNarrowedAt`: an owned class name when
/// `name` is class-narrowed at `query_span`.
pub fn cfgNarrowedClassAt(self: *const Checker, name: []const u8, query_span: Span) Allocator.Error!?[]const u8 {
    const scratch = queryScratch(self);
    const at = (try solvedSmartStateAt(self, scratch, query_span)) orelse return null;
    return stateNarrowedClass(self, at.lowered, at.state, name);
}

pub fn resolution(self: *const Checker) *const root.Resolution {
    return self.resolution;
}

/// True when `candidate` is `target` itself or a transitive subclass of it in
/// the local class table.
pub fn isClassOrSubclass(self: *const Checker, candidate: []const u8, target: []const u8) bool {
    if (std.mem.eql(u8, candidate, target)) {
        return true;
    }
    return isSubtypeOf(self, candidate, target);
}

/// The concrete classes, neither abstract nor interface nor sealed, whose
/// transitive supertype chain contains `root_name`: the leaf set a `when` must
/// cover. The result and its elements are owned by the caller.
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
        // A sealed or abstract intermediate is not a leaf; its concrete
        // descendants are listed separately.
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
    const root_info = root.classNamed(self, subject_class) orelse return;
    if (!root_info.is_sealed) {
        return;
    }
    // An `else` branch covers everything.
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

/// Walk a class's supertype chain for `sup`. False when `sub == sup`: an
/// identity is not a strict subtype here.
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
        const info = root.classNamed(self, name) orelse continue;
        for (info.supertypes.items) |s| {
            if (std.mem.eql(u8, s, sup)) {
                return true;
            }
            frontier.append(self.allocator, s) catch return false;
        }
    }
    return false;
}

/// `target`'s type-argument list as instantiated from `subclass`. The result
/// and its elements are owned by the caller.
fn walkSupertypeArgs(self: *const Checker, allocator: Allocator, subclass: []const u8, target: []const u8) Allocator.Error!?[]Type {
    const info = root.classNamed(self, subclass) orelse return null;
    if (std.mem.eql(u8, subclass, target)) {
        const out = try allocator.alloc(Type, info.type_param_names.items.len);
        errdefer allocator.free(out);
        for (info.type_param_names.items, out) |n, *dst| {
            dst.* = .{ .TypeParam = try allocator.dupe(u8, n) };
        }
        return out;
    }
    for (info.typed_supertypes.items) |s| {
        if (std.mem.eql(u8, s.name, target)) {
            const out = try allocator.alloc(Type, s.args.len);
            errdefer allocator.free(out);
            for (s.args, out) |*a, *dst| dst.* = try a.clone(allocator);
            return out;
        }
        if (try walkSupertypeArgs(self, allocator, s.name, target)) |deeper| {
            // Substitute the subclass's arguments into the deeper result: for
            // `subclass : Mid<X>` and `Mid<X> : Target<f(X)>`, replacing `X`
            // with `s_args` gives `Target<f(arg)>`.
            const mid_info = root.classNamed(self, s.name) orelse return null;
            var subst = std.StringHashMap(Type).init(allocator);
            var i: usize = 0;
            while (i < mid_info.type_param_names.items.len and i < s.args.len) : (i += 1) {
                const name = try allocator.dupe(u8, mid_info.type_param_names.items[i]);
                try subst.put(name, try s.args[i].clone(allocator));
            }
            const substituted = try allocator.alloc(Type, deeper.len);
            errdefer allocator.free(substituted);
            for (deeper, substituted) |*t, *dst| {
                dst.* = try helpers.substituteTypeParams(allocator, t, &subst);
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

/// Solve the smart-cast analysis to fixpoint and clone the entry state of
/// block `bid`, ready for `statesWithinBlock`. Null when `bid` is out of
/// range. The caller owns the returned lattice.
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

/// Join with ", "; the caller owns the result.
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
