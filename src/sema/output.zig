//! Sema's decisions by node: for each file, the records each node holds
//! and the type each expression has, variables solved. This is what
//! lowering reads, and what `klio sema --dump` prints.

const std = @import("std");
const ast = @import("ast");

const sema_mod = @import("sema.zig");
const records = @import("records.zig");
const types = @import("types.zig");
const infer = @import("infer.zig");

const Allocator = std.mem.Allocator;
const Sema = sema_mod.Sema;
const Ref = records.Ref;
const TypeId = types.TypeId;
const Sym = @import("symbols.zig").Sym;
const NodeId = ast.NodeId;

pub const FileRecords = struct {
    /// The file's `node_count`: every id is below it.
    node_count: u32 = 0,
    /// The file's records ordered by node, and within a node in the order
    /// they were made.
    refs: []const Ref = &.{},
    /// `refs[start[n]..start[n + 1]]` are node `n`'s.
    start: []const u32 = &.{},
    /// Each resolved expression's type; `.none` for a node that is not one.
    types: []const TypeId = &.{},

    /// The records node `n` holds.
    pub fn at(self: *const FileRecords, n: NodeId) []const Ref {
        const i = n.int();
        if (i == 0 or i >= self.node_count) return &.{};
        return self.refs[self.start[i]..self.start[i + 1]];
    }

    /// The record of `kind` node `n` holds; several of one kind (a path's
    /// segments) are told apart by their anchors.
    pub fn one(self: *const FileRecords, n: NodeId, kind: records.RefKind) ?Ref {
        for (self.at(n)) |r| if (r.kind == kind) return r;
        return null;
    }

    pub fn typeOf(self: *const FileRecords, n: NodeId) TypeId {
        const i = n.int();
        if (i == 0 or i >= self.node_count) return .none;
        return self.types[i];
    }
};

pub const Output = struct {
    /// Indexed like `Sema.files`.
    files: []FileRecords,
    /// Records made where no node was current; each is a gap in the node
    /// plumbing, and the index cannot address it.
    orphans: u32,
};

/// Indexes the committed records and expression types by file and node,
/// and reports every expression lowering needs a record for that has none
/// (`unrecorded`). Call once bodies are resolved.
pub fn build(s: *Sema) Allocator.Error!Output {
    const a = s.arena;
    const nfiles = s.files.items.len;
    const out = try a.alloc(FileRecords, nfiles);
    @memset(out, .{});
    // Count per node, then place: a counting sort that keeps each node's
    // records in the order they were made.
    const counts = try a.alloc([]u32, nfiles);
    for (s.files.items, out, counts) |fc, *fr, *cnt| {
        fr.node_count = if (fc.ast) |f| @max(f.node_count, 1) else 1;
        cnt.* = try a.alloc(u32, fr.node_count + 1);
        @memset(cnt.*, 0);
    }
    var orphans: u32 = 0;
    for (s.refs.items) |r| {
        const i = r.node.int();
        if (i == 0 or r.file >= nfiles or i >= out[r.file].node_count) {
            orphans += 1;
            continue;
        }
        counts[r.file][i + 1] += 1;
    }
    for (out, counts) |*fr, cnt| {
        var acc: u32 = 0;
        for (cnt) |*c| {
            acc += c.*;
            c.* = acc;
        }
        fr.start = try a.dupe(u32, cnt);
        fr.refs = try a.alloc(Ref, acc);
    }
    for (s.refs.items) |r| {
        const i = r.node.int();
        if (i == 0 or r.file >= nfiles or i >= out[r.file].node_count) continue;
        // A reference's and a lambda's type take their solved variables,
        // as call type arguments do when read.
        switch (r.detail) {
            .ref => |x| {
                @constCast(x).ty = try infer.zonk(s, x.ty);
                const targs = try s.arena.alloc(TypeId, x.type_args.len);
                for (x.type_args, targs) |t, *o| o.* = try infer.zonk(s, t);
                @constCast(x).type_args = targs;
            },
            .lambda => |x| @constCast(x).fn_type = try infer.zonk(s, x.fn_type),
            else => {},
        }
        const slot = &counts[r.file][i];
        @constCast(out[r.file].refs)[slot.*] = r;
        slot.* += 1;
    }
    // Where the census already has a site, per file, sorted: a node that
    // holds one failed to resolve, which the census counts already.
    const site_starts = try a.alloc(std.ArrayList(u32), nfiles);
    @memset(site_starts, .empty);
    for (s.census.sites.items) |site| {
        if (site.file < nfiles) try site_starts[site.file].append(a, site.sp.start);
    }
    for (site_starts) |*l| std.mem.sort(u32, l.items, {}, std.sort.asc(u32));
    // Types, solved, and the nodes that needed a record and got none.
    const tys = try a.alloc([]TypeId, nfiles);
    for (out, tys) |fr, *t| {
        t.* = try a.alloc(TypeId, fr.node_count);
        @memset(t.*, .none);
    }
    // A node marked failed (an operand's resolution failed first) keeps
    // its type but is not checked.
    const failed = try a.alloc(std.DynamicBitSetUnmanaged, nfiles);
    for (out, failed) |fr, *f| f.* = try std.DynamicBitSetUnmanaged.initEmpty(a, fr.node_count);
    for (s.expr_types.items) |et| {
        const i = et.node.int();
        if (et.file >= nfiles or i == 0 or i >= out[et.file].node_count) continue;
        if (s.types.isErr(et.ty)) failed[et.file].set(i);
    }
    for (s.expr_types.items) |et| {
        const i = et.node.int();
        if (et.file >= nfiles or i == 0 or i >= out[et.file].node_count) continue;
        const z = try infer.zonk(s, et.ty);
        if (et.if_integral and !infer.isIntegral(s, try s.types.makeNotNull(z))) continue;
        if (tys[et.file][i] == .none or !s.types.isErr(z)) tys[et.file][i] = z;
        if (!et.needs_record or s.types.isErr(z) or failed[et.file].isSet(i)) continue;
        if (out[et.file].at(et.node).len != 0) continue;
        if (holdsSite(site_starts[et.file].items, et.sp)) continue;
        try s.census.reportFmt(.unrecorded, et.file, et.sp, "node {d}", .{i});
    }
    for (out, tys) |*fr, t| fr.types = t;
    return .{ .files = out, .orphans = orphans };
}

/// Frees the logs `build` indexed (`Sema.refs`, `Sema.expr_types`), for a
/// caller that reads only the index from then on, as lowering does.
pub fn releaseLogs(s: *Sema) void {
    s.refs.clearAndFree(s.arena);
    s.expr_types.clearAndFree(s.arena);
}

/// Whether a sorted list of site offsets has one inside `sp`.
fn holdsSite(starts: []const u32, sp: @import("span").Span) bool {
    const i = std.sort.lowerBound(u32, starts, sp.start, struct {
        fn order(key: u32, item: u32) std.math.Order {
            return std.math.order(key, item);
        }
    }.order);
    return i < starts.len and starts[i] < sp.end;
}

// ------------------------------------------------------------- lookups ----
//
// What lowering reads for a node, typed. A node without the record its kind
// needs is `error.Unrecorded`: lowering fails that body and names the node.

pub const Error = error{ OutOfMemory, Unrecorded };

/// Whether a record's kind is one of a group's parts rather than the
/// node's own call.
fn groupPart(k: records.RefKind) bool {
    return switch (k) {
        .iterator, .has_next, .next, .component, .get_value, .set_value, .provide_delegate => true,
        else => false,
    };
}

/// The node's call: a call, constructor, invoke, index access, or an
/// operator convention. Type arguments come back solved.
pub fn call(s: *Sema, fr: *const FileRecords, id: NodeId) Error!records.CallRec {
    for (fr.at(id)) |r| {
        if (groupPart(r.kind)) continue;
        switch (r.detail) {
            .call => |c| return solved(s, c.*),
            else => {},
        }
    }
    return error.Unrecorded;
}

/// The call record of `kind` at node `id` (a group's part: `iterator`,
/// `get_value`, a compound assignment's `get`, ...).
pub fn callOf(s: *Sema, fr: *const FileRecords, id: NodeId, kind: records.RefKind) Error!records.CallRec {
    for (fr.at(id)) |r| {
        if (r.kind != kind) continue;
        switch (r.detail) {
            .call => |c| return solved(s, c.*),
            else => {},
        }
    }
    return error.Unrecorded;
}

fn solved(s: *Sema, c: records.CallRec) Error!records.CallRec {
    var out = c;
    const targs = try s.arena.alloc(TypeId, c.type_args.len);
    for (c.type_args, targs) |t, *o| o.* = try infer.zonk(s, t);
    out.type_args = targs;
    return out;
}

/// The node's name: a read or write of a local, parameter or property, or
/// an object or enum entry used as a value.
pub fn name(s: *Sema, fr: *const FileRecords, id: NodeId) Error!records.NameRec {
    for (fr.at(id)) |r| {
        if (nameOf(s, r)) |n| return n;
    }
    return error.Unrecorded;
}

/// Every name record of a node in the order they were made: a dotted
/// path's segments that yield a value.
pub fn names(s: *Sema, fr: *const FileRecords, id: NodeId) Error![]const records.NameRec {
    var out: std.ArrayList(records.NameRec) = .empty;
    for (fr.at(id)) |r| {
        if (nameOf(s, r)) |n| try out.append(s.arena, n);
    }
    return out.items;
}

fn nameOf(s: *Sema, r: Ref) ?records.NameRec {
    const write = switch (r.kind) {
        .read => false,
        .write => true,
        .object => false,
        else => return null,
    };
    const kind: records.NameKind = switch (s.syms.kind(r.target)) {
        // An accessor's `field`, a local, stands for its property's storage.
        .local => if (s.backing_fields.get(r.target)) |prop| return .{ .kind = .backing_field, .write = write, .target = prop } else .local,
        .value_param => .param,
        .property => .property,
        .enum_entry => .enum_entry,
        .class => .object,
        else => return null,
    };
    return .{ .kind = kind, .write = write, .target = r.target, .dispatch = r.dispatch, .extension = r.extension, .contexts = r.contexts };
}

/// The type of expression `id`, variables solved; `.none` for a node that
/// is not a resolved expression.
pub fn exprType(fr: *const FileRecords, id: NodeId) TypeId {
    return fr.typeOf(id);
}

/// The node's `this` / `this@L`: which implicit receiver.
pub fn recv(fr: *const FileRecords, id: NodeId) Error!records.RecvRec {
    for (fr.at(id)) |r| {
        if (r.kind != .this_) continue;
        return switch (r.dispatch) {
            .implicit => |im| .{ .kind = im.kind, .owner = im.owner },
            else => error.Unrecorded,
        };
    }
    return error.Unrecorded;
}

/// The node's type test: `is`, `as`, a catch parameter, a class literal.
pub fn typeTest(fr: *const FileRecords, id: NodeId) Error!records.TypeTestRec {
    for (fr.at(id)) |r| switch (r.detail) {
        .type_test => |t| return t.*,
        else => {},
    };
    return error.Unrecorded;
}

/// Every type test of a node in order: a `when`'s `is` patterns.
pub fn typeTests(s: *Sema, fr: *const FileRecords, id: NodeId) Error![]const records.TypeTestRec {
    var out: std.ArrayList(records.TypeTestRec) = .empty;
    for (fr.at(id)) |r| switch (r.detail) {
        .type_test => |t| try out.append(s.arena, t.*),
        else => {},
    };
    return out.items;
}

/// The node's callable reference.
pub fn ref(fr: *const FileRecords, id: NodeId) Error!records.RefRec {
    for (fr.at(id)) |r| switch (r.detail) {
        .ref => |x| return x.*,
        else => {},
    };
    return error.Unrecorded;
}

/// The node's lambda or anonymous function.
pub fn lambda(fr: *const FileRecords, id: NodeId) Error!records.LambdaRec {
    for (fr.at(id)) |r| switch (r.detail) {
        .lambda => |l| return l.*,
        else => {},
    };
    return error.Unrecorded;
}

/// The function or lambda a `return` node leaves.
pub fn returnTarget(fr: *const FileRecords, id: NodeId) Error!Sym {
    for (fr.at(id)) |r| if (r.kind == .return_) return r.target;
    return error.Unrecorded;
}

/// The symbol a declaration node declares: a local property, function,
/// class or object, or an object expression's anonymous class.
pub fn decl(fr: *const FileRecords, id: NodeId) Error!Sym {
    for (fr.at(id)) |r| if (r.kind == .decl) return r.target;
    return error.Unrecorded;
}

pub const ForGroup = struct {
    iterator: records.CallRec,
    has_next: records.CallRec,
    next: records.CallRec,
};

/// `for (x in c)`: `c.iterator()`, `hasNext()` and `next()`.
pub fn forGroup(s: *Sema, fr: *const FileRecords, id: NodeId) Error!ForGroup {
    return .{
        .iterator = try callOf(s, fr, id, .iterator),
        .has_next = try callOf(s, fr, id, .has_next),
        .next = try callOf(s, fr, id, .next),
    };
}

/// `a op= b`, `++a`, `a--`: the target's receiver and index arguments are
/// evaluated once.
pub const Compound = struct {
    /// An index target's `get`.
    get: ?records.CallRec = null,
    /// A name or member target's read.
    read: ?records.NameRec = null,
    /// `plusAssign` (nothing is written back), `plus`, `inc` or `dec`.
    op: records.CallRec,
    assign_form: bool = false,
    /// An index target's `set`.
    set: ?records.CallRec = null,
    /// The name or member written.
    write: ?records.NameRec = null,
};

/// A compound assignment's or increment's records.
pub fn compound(s: *Sema, fr: *const FileRecords, id: NodeId) Error!Compound {
    var out: Compound = .{ .op = undefined };
    var have_op = false;
    for (fr.at(id)) |r| {
        switch (r.kind) {
            .get => out.get = try solvedDetail(s, r),
            .set => out.set = try solvedDetail(s, r),
            .op_assign => {
                out.op = (try solvedDetail(s, r)) orelse return error.Unrecorded;
                out.assign_form = true;
                have_op = true;
            },
            .op, .inc, .dec => {
                out.op = (try solvedDetail(s, r)) orelse return error.Unrecorded;
                have_op = true;
            },
            .read => out.read = nameOf(s, r),
            .write => out.write = nameOf(s, r),
            else => {},
        }
    }
    if (!have_op) return error.Unrecorded;
    return out;
}

fn solvedDetail(s: *Sema, r: Ref) Error!?records.CallRec {
    return switch (r.detail) {
        .call => |c| try solved(s, c.*),
        else => null,
    };
}

pub const DestructEntry = struct {
    /// The entry's local.
    local: Sym = .none,
    /// `componentN`, or for name-based destructuring the property read.
    call: ?records.CallRec = null,
    name: ?records.NameRec = null,
};

/// `val (a, b) = x`, `for ((k, v) in m)`, `{ (a, b) -> }`: the entry
/// written at `entry` (its name's offset); null for `_`, which takes
/// nothing.
pub fn destructureEntry(s: *Sema, fr: *const FileRecords, id: NodeId, entry: u32) Error!?DestructEntry {
    var out: DestructEntry = .{};
    var any = false;
    for (fr.at(id)) |r| {
        if (r.anchor.start != entry) continue;
        switch (r.kind) {
            .component => out.call = try solvedDetail(s, r),
            .read => out.name = nameOf(s, r),
            .decl => out.local = r.target,
            else => continue,
        }
        any = true;
    }
    return if (any) out else null;
}

/// The records of `kind` node `id` made at `anchor`, for constructs whose
/// parts have no node of their own: a `when`'s patterns (at each pattern's
/// offset), a destructuring's entries, a path's segments.
pub fn atAnchor(fr: *const FileRecords, id: NodeId, kind: records.RefKind, anchor: u32) ?Ref {
    for (fr.at(id)) |r| {
        if (r.kind == kind and r.anchor.start == anchor) return r;
    }
    return null;
}

/// What a `when` pattern tests with.
pub const WhenPattern = union(enum) {
    equals: records.CallRec,
    contains: records.CallRec,
    type_test: records.TypeTestRec,
};

/// A `when` pattern's test: its `equals`, `contains` or type test, at the
/// pattern's offset.
pub fn whenPattern(s: *Sema, fr: *const FileRecords, when_id: NodeId, pattern: u32) Error!WhenPattern {
    for (fr.at(when_id)) |r| {
        if (r.anchor.start != pattern) continue;
        switch (r.kind) {
            .equals => if (try solvedDetail(s, r)) |c| return .{ .equals = c },
            .contains => if (try solvedDetail(s, r)) |c| return .{ .contains = c },
            .type_test => switch (r.detail) {
                .type_test => |t| return .{ .type_test = t.* },
                else => {},
            },
            else => {},
        }
    }
    return error.Unrecorded;
}

pub const Delegate = struct {
    provide: ?records.CallRec = null,
    get: records.CallRec,
    set: ?records.CallRec = null,
};

/// A delegated property's `provideDelegate`, `getValue` and `setValue`.
pub fn delegate(s: *Sema, fr: *const FileRecords, id: NodeId) Error!Delegate {
    return .{
        .provide = callOf(s, fr, id, .provide_delegate) catch null,
        .get = try callOf(s, fr, id, .get_value),
        .set = callOf(s, fr, id, .set_value) catch null,
    };
}

/// A class's supertype initializers (`: Base(args)`), in the order written;
/// an interface supertype has none.
pub fn supers(s: *Sema, fr: *const FileRecords, id: NodeId) Error![]const records.CallRec {
    var out: std.ArrayList(records.CallRec) = .empty;
    for (fr.at(id)) |r| switch (r.detail) {
        .call => |c| if (c.form == .super_delegation) try out.append(s.arena, try solved(s, c.*)),
        else => {},
    };
    return out.items;
}

/// The name record of a dotted path's segment at `anchor` (the segment's
/// offset); null for a segment that is a package or classifier qualifier.
pub fn nameAt(s: *Sema, fr: *const FileRecords, id: NodeId, anchor: u32) ?records.NameRec {
    for (fr.at(id)) |r| {
        if (r.anchor.start != anchor) continue;
        if (nameOf(s, r)) |n| return n;
    }
    return null;
}
