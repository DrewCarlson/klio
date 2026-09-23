//! Property slots: a per-class table answering "what runs when this property
//! is read on an instance of this class".
//!
//! A property read on an interface or an abstract class cannot name a getter,
//! because the accessor is per-implementation — the same reason a method call
//! on one cannot name a `FuncId`. Methods answer that with a slot, and a
//! property wants the same shape. It cannot share the method table: a slot
//! there is rooted at the base declaration's `FuncId` and `overridesSlot`
//! requires the two functions to carry the SAME NAME, while accessors are
//! named `__get_<Class>_<prop>` and so never match across a chain.
//!
//! So the family is keyed by the property name along the chain, which is
//! Kotlin's own rule — properties do not overload. The slot is rooted at the
//! topmost ancestor whose body declares the name, and each class in the family
//! contributes one entry saying how IT answers: an accessor to run, or a field
//! index to read.

const std = @import("std");

const runtime = @import("runtime");

const core_class = @import("class.zig");
const core_ids = @import("ids.zig");
const m_fields = @import("module_fields.zig");
const m_regclass = @import("module_regclass.zig");
const m_static = @import("module_static.zig");
const core_consts = @import("consts.zig");
const core_inst = @import("inst.zig");

const Class = core_class.Class;
const ClassId = core_ids.ClassId;
const FuncId = core_ids.FuncId;
const PropSlotId = core_ids.PropSlotId;
const Allocator = std.mem.Allocator;

const Module = @import("../ir.zig").Module;

/// How one class answers a read of one property.
pub const PropTarget = union(enum) {
    /// Run this accessor with the receiver as its only argument.
    getter: FuncId,
    /// Read this index of the receiver's field layout.
    field: u32,
};

/// One `(class, slot) -> answer` row, flattened for the image: the codec
/// carries plain fields, and a tagged union is not one.
pub const PropDispatchEntry = struct {
    runtime_class: ClassId,
    slot: u32,
    is_getter: bool,
    value: u32,
};

/// One `(root class FQN, property name) -> slot` row. Carried in the image
/// because the numbering is assignment order: a baked site's slot means a
/// different property in a table linked from scratch.
pub const PropSlotEntry = struct {
    root_fqn: []const u8,
    name: []const u8,
    slot: u32,
};

pub fn propDispatchEntries(self: *const Module, allocator: Allocator) Allocator.Error![]PropDispatchEntry {
    const out = try allocator.alloc(PropDispatchEntry, self.prop_dispatch.count());
    var i: usize = 0;
    var it = self.prop_dispatch.iterator();
    while (it.next()) |e| : (i += 1) {
        const key = e.key_ptr.*;
        out[i] = .{
            .runtime_class = ClassId.from(@intCast(key >> 32)),
            .slot = @truncate(key),
            .is_getter = e.value_ptr.* == .getter,
            .value = switch (e.value_ptr.*) {
                .getter => |f| f.int(),
                .field => |idx| idx,
            },
        };
    }
    return out;
}

pub fn propSlotEntries(self: *const Module, allocator: Allocator) Allocator.Error![]PropSlotEntry {
    const out = try allocator.alloc(PropSlotEntry, self.prop_slot_ids.count());
    var i: usize = 0;
    var it = self.prop_slot_ids.iterator();
    while (it.next()) |e| : (i += 1) {
        out[i] = .{ .root_fqn = e.key_ptr.a, .name = e.key_ptr.b, .slot = e.value_ptr.* };
    }
    return out;
}

pub fn registerPropSlotTarget(self: *Module, entry: PropDispatchEntry) Allocator.Error!void {
    const target: PropTarget = if (entry.is_getter)
        .{ .getter = FuncId.from(entry.value) }
    else
        .{ .field = entry.value };
    try self.prop_dispatch.put(propDispatchKey(entry.runtime_class, PropSlotId.from(entry.slot)), target);
}

pub fn registerPropSlotId(self: *Module, entry: PropSlotEntry) Allocator.Error!void {
    try self.prop_slot_ids.put(.{ .a = entry.root_fqn, .b = entry.name }, entry.slot);
}

pub fn propDispatchKey(class: ClassId, slot: PropSlotId) u64 {
    return (@as(u64, class.int()) << 32) | slot.int();
}

/// How `runtime_class` answers `slot`, or null when the table has no entry and
/// the read must fall back to the by-name walk.
pub fn propSlotTarget(self: *const Module, runtime_class: ClassId, slot: PropSlotId) ?PropTarget {
    return self.prop_dispatch.get(propDispatchKey(runtime_class, slot));
}

/// The slot the property `name` occupies on `cid`, or null when no class in
/// the chain declares it.
pub fn propSlotOf(self: *const Module, cid: ClassId, name: []const u8) ?PropSlotId {
    const root = propSlotRoot(self, cid, name) orelse return null;
    const raw = self.prop_slot_ids.get(.{ .a = self.classes.items[root.int()].fqn, .b = name }) orelse return null;
    return PropSlotId.from(raw);
}

/// The topmost ancestor of `cid` (itself included) whose body declares `name`.
///
/// Breadth-first over the full supertype closure, taking the FARTHEST
/// declaration rather than the nearest: the root is what every implementation
/// in the family agrees on, so an interface's declaration outranks the class's
/// override of it.
fn propSlotRoot(self: *const Module, cid: ClassId, name: []const u8) ?ClassId {
    var best: ?ClassId = null;
    var best_depth: u32 = 0;
    var queue: [64]ClassId = undefined;
    var depths: [64]u32 = undefined;
    var head: usize = 0;
    var tail: usize = 0;
    queue[tail] = cid;
    depths[tail] = 0;
    tail += 1;
    while (head < tail) : (head += 1) {
        const cur = queue[head];
        const depth = depths[head];
        if (cur.int() >= self.classes.items.len) continue;
        const c = &self.classes.items[cur.int()];
        if (declaresProp(c, name) != null and (best == null or depth > best_depth)) {
            best = cur;
            best_depth = depth;
        }
        for (c.supertypes) |sup| {
            if (tail == queue.len) break;
            queue[tail] = sup;
            depths[tail] = depth + 1;
            tail += 1;
        }
    }
    return best;
}

fn declaresProp(c: *const Class, name: []const u8) ?*const core_class.DeclaredProp {
    for (c.declared_props) |*p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

/// Build every `(class, property slot) -> answer` entry once, after the class
/// bodies have lowered — the accessor a class answers with is a function those
/// bodies create.
pub fn linkPropertySlots(self: *Module) Allocator.Error!void {
    var buf: [256]u8 = undefined;
    // The ids a loaded base brought are final: a baked site carries the number
    // that base assigned, so renumbering would point it at another property.
    // New families continue past the highest one in hand.
    var next_slot: u32 = 0;
    {
        var it = self.prop_slot_ids.valueIterator();
        while (it.next()) |v| next_slot = @max(next_slot, v.* + 1);
    }

    // Pass one: every (root class, property) pair becomes a slot id. A root is
    // a class whose declaration no supertype of it repeats.
    for (self.classes.items) |*c| {
        if (c.name.len == 0) continue;
        for (c.declared_props) |p| {
            const root = propSlotRoot(self, c.id, p.name) orelse continue;
            const root_fqn = self.classes.items[root.int()].fqn;
            if (root_fqn.len == 0) continue;
            const gop = try self.prop_slot_ids.getOrPut(.{ .a = root_fqn, .b = p.name });
            if (!gop.found_existing) {
                gop.value_ptr.* = next_slot;
                next_slot += 1;
            }
        }
    }

    // Pass two: every class in a family says how it answers.
    for (self.classes.items) |*c| {
        if (c.name.len == 0) continue;
        // A value class's accessor takes the underlying value as its receiver,
        // not the instance a slot read holds.
        if (c.is_value) continue;
        // Where the state is not in the layout, no index into it is the
        // answer: a host-backed collection keeps its elements in the host
        // object, and a `by`-delegating class forwards the member to another
        // object entirely. `Log : ArrayList<String>()` read `size` as the
        // seed 0 for exactly this reason.
        if (stateLivesElsewhere(self, c.id)) continue;
        var seen: [128][]const u8 = undefined;
        var n_seen: usize = 0;
        var cur: ?ClassId = c.id;
        var hops: usize = 0;
        while (cur) |cid| : (hops += 1) {
            if (hops > 32 or cid.int() >= self.classes.items.len) break;
            const owner = &self.classes.items[cid.int()];
            for (owner.declared_props) |p| {
                // Nearest declaration wins, so a name already answered by a
                // class lower in the chain is settled.
                var dup = false;
                for (seen[0..n_seen]) |s| {
                    if (std.mem.eql(u8, s, p.name)) dup = true;
                }
                if (dup) continue;
                if (n_seen < seen.len) {
                    seen[n_seen] = p.name;
                    n_seen += 1;
                }
                if (p.is_abstract) continue;
                const root = propSlotRoot(self, c.id, p.name) orelse continue;
                const root_fqn = self.classes.items[root.int()].fqn;
                const slot = self.prop_slot_ids.get(.{ .a = root_fqn, .b = p.name }) orelse continue;
                const target = answerFor(self, c.id, owner, p, &buf) orelse continue;
                try self.prop_dispatch.put(
                    propDispatchKey(c.id, PropSlotId.from(slot)),
                    target,
                );
            }
            cur = if (owner.supertypes.len != 0) owner.supertypes[0] else null;
        }
    }
    if (runtime.envOnce("KLIO_PROP_SLOT_PROBE") != null) {
        std.debug.print("[prop-slot] slots={d} entries={d}\n", .{ next_slot, self.prop_dispatch.count() });
    }
}

/// Whether an instance of `cid` holds some of its state outside its own field
/// layout, so a layout index cannot be the answer to a property read.
fn stateLivesElsewhere(self: *const Module, cid: ClassId) bool {
    var cur: ?ClassId = cid;
    var hops: usize = 0;
    while (cur) |c| : (hops += 1) {
        if (hops > 32 or c.int() >= self.classes.items.len) return true;
        const cls = &self.classes.items[c.int()];
        if (cls.is_intrinsic_backed) return true;
        if (m_fields.classFieldLayout(self, c)) |entry| {
            for (entry.slots) |sl| {
                if (std.mem.startsWith(u8, sl.name, "__delegate__")) return true;
            }
        }
        cur = if (cls.supertypes.len != 0) cls.supertypes[0] else null;
    }
    return false;
}

/// What a read on an instance of `recv` runs, given that `owner` is the
/// nearest class declaring the property.
fn answerFor(
    self: *const Module,
    recv: ClassId,
    owner: *const Class,
    p: core_class.DeclaredProp,
    buf: []u8,
) ?PropTarget {
    if (p.has_getter) {
        const key = std.fmt.bufPrint(buf, "__get_{s}_{s}", .{ owner.name, p.name }) catch return null;
        const fid = uniqueFuncNamed(self, key) orelse return null;
        return .{ .getter = fid };
    }
    // A stored property answers from the receiver's own composed layout, whose
    // index already accounts for every base in the chain.
    const idx = storedSlotIndex(self, recv, p.name) orelse return null;
    return .{ .field = idx };
}

/// The composed-layout index of the plain cell for `name` on `cid`.
fn storedSlotIndex(self: *const Module, cid: ClassId, name: []const u8) ?u32 {
    const entry = m_fields.classFieldLayout(self, cid) orelse return null;
    var found: ?u32 = null;
    for (entry.slots, 0..) |slot, i| {
        if (!slot.plain) continue;
        if (!std.mem.eql(u8, m_fields.propNameOfSlotKey(slot.name), name)) continue;
        // Two cells for one name is a shadow, and which one a read means is
        // not a question this table can answer.
        if (found != null) return null;
        found = @intCast(i);
    }
    return found;
}

/// A function the table carries under exactly this name. `Func.id`, never the
/// table position: the two are unrelated, and reading the position named an
/// unrelated function.
fn uniqueFuncNamed(self: *const Module, key: []const u8) ?FuncId {
    var found: ?FuncId = null;
    for (self.funcs.items) |*f| {
        if (!std.mem.eql(u8, f.name, key)) continue;
        if (!f.hasBody()) continue;
        if (found != null) return null;
        found = f.id;
    }
    return found;
}

/// Which constructor a construction of `cid` with `n_args` arguments reaches,
/// when the argument COUNT alone settles it. Null when none accepts the count
/// or more than one does — then the runtime's value scoring decides.
///
/// 0 is the primary; 1 + i the i'th secondary.
pub fn soleCtorForArity(self: *const Module, cid: ClassId, n_args: u16) ?u16 {
    if (cid.int() >= self.classes.items.len) return null;
    const c = &self.classes.items[cid.int()];
    var pick: ?u16 = null;
    if (c.primaryArity()) |pa| {
        if (pa.accepts(n_args)) pick = 0;
    }
    for (c.secondary_ctor_arities, 0..) |sa, i| {
        if (!sa.accepts(n_args)) continue;
        if (pick != null) return null;
        pick = @intCast(i + 1);
    }
    return pick;
}

/// Which constructor of `cid` a construction with this shape reaches, as the
/// index `soleCtorForArity` uses: 0 the primary, 1 + i the i'th secondary.
///
/// Two things can settle it. The argument COUNT settles it when exactly one
/// constructor accepts the count. Where several do, the call's static argument
/// heads settle it when exactly one candidate's declared heads match them
/// position for position — the same comparison the runtime's scoring makes
/// first, and the only one of its tests that reads no value.
///
/// Null is "lowering cannot say", never "no constructor": a missing static
/// head, a named argument, or two candidates the heads do not separate all
/// leave the choice to the runtime.
pub fn staticCtorPick(
    self: *const Module,
    cid: ClassId,
    n_args: u16,
    arg_names: []const ?[]const u8,
    arg_heads: []const ?[]const u8,
) ?u16 {
    if (cid.int() >= self.classes.items.len) return null;
    const c = &self.classes.items[cid.int()];
    if (runtime.envOnce("KLIO_CTOR_PICK_WHY")) |want| {
        if (std.mem.eql(u8, want, "*") or std.mem.eql(u8, want, c.name)) {
            std.debug.print("[ctor-why] {s} fqn={s} nargs={d} stub={} prim={} sig={} secs={d} args=", .{
                c.name, c.fqn, n_args, c.is_stub, c.has_primary_ctor, c.primary_ctor_sig != null, c.secondary_ctor_arities.len,
            });
            for (arg_heads) |h| std.debug.print("{s},", .{h orelse "?"});
            std.debug.print("\n", .{});
            var si: u16 = 0;
            while (si < c.ctorSlotCount()) : (si += 1) {
                const sg = c.ctorSig(si) orelse {
                    std.debug.print("[ctor-why]   slot {d}: absent\n", .{si});
                    continue;
                };
                std.debug.print("[ctor-why]   slot {d}: req={d} total={d} vararg={} low={} accepts={} heads=", .{ si, sg.required, sg.total, sg.vararg, sg.low_priority, sg.accepts(n_args) });
                for (sg.param_heads) |ph| std.debug.print("{s},", .{ph});
                std.debug.print("\n", .{});
            }
        }
    }
    // A reserved placeholder answers with the shape of a class that declares
    // nothing, which is a different class from the one the site names.
    if (c.is_stub) return null;
    if (c.has_primary_ctor and c.primary_ctor_sig == null) return null;
    // A class with no parameter list in its header records no primary
    // signature; its implicit constructor takes no arguments and needs none.
    // A named argument binds by name rather than position, so the head
    // comparison below would line up the wrong parameters.
    for (arg_names) |n| if (n != null) return null;

    var accepted: [64]u16 = undefined;
    var n_accepted: usize = 0;
    var any_ordinary = false;
    var slot: u16 = 0;
    const slots = c.ctorSlotCount();
    while (slot < slots) : (slot += 1) {
        const sig = c.ctorSig(slot) orelse continue;
        if (!sig.accepts(n_args)) continue;
        if (n_accepted == accepted.len) return null;
        accepted[n_accepted] = slot;
        n_accepted += 1;
        if (!sig.low_priority) any_ordinary = true;
    }
    // A constructor source cannot name is reached only when nothing else takes
    // the call, which is the order the runtime's two passes impose.
    if (any_ordinary) {
        var w: usize = 0;
        for (accepted[0..n_accepted]) |sl| {
            if (c.ctorSig(sl).?.low_priority) continue;
            accepted[w] = sl;
            w += 1;
        }
        n_accepted = w;
    }
    if (n_accepted == 0) return null;
    if (n_accepted == 1) return accepted[0];

    // Beyond the count, only a complete set of static heads can decide.
    if (arg_heads.len < n_args) return null;
    for (arg_heads[0..n_args]) |h| if (h == null) return null;

    var winner: ?u16 = null;
    for (accepted[0..n_accepted]) |sl| {
        const sig = c.ctorSig(sl).?;
        // A vararg or a defaulted tail binds a different number of parameters
        // than the call passes, so the positions no longer line up.
        if (sig.vararg or sig.total != n_args) return null;
        if (sig.param_heads.len != n_args) return null;
        var all = true;
        for (arg_heads[0..n_args], sig.param_heads) |h, declared| {
            if (!std.mem.eql(u8, h.?, declared)) {
                all = false;
                break;
            }
        }
        if (!all) continue;
        if (winner != null) return null;
        winner = sl;
    }
    return winner;
}

/// Name the constructor every construction site reaches, once every class has
/// lowered.
///
/// This runs as a link pass rather than at emission for the reason the getter
/// route does: a `NewInstance` can be emitted before the class it names is
/// lowered, and a reserved stub answers the question with the wrong shape.
///
/// `KLIO_CTOR_PICK=0` withdraws the binding, leaving every site on the
/// runtime's value scoring.
pub fn linkCtorPicks(self: *Module) void {
    if (std.mem.eql(u8, runtime.envOnce("KLIO_CTOR_PICK") orelse "1", "0")) return;
    var bound: usize = 0;
    var open: usize = 0;
    var sole: usize = 0;
    for (self.funcs.items) |*f| {
        for (f.blocks) |*b| {
            for (b.insts) |*inst| {
                if (inst.* != .NewInstance) continue;
                const ni = &inst.NewInstance;
                if (ni.class.int() < self.classes.items.len and
                    self.classes.items[ni.class.int()].hasSoleCtor())
                {
                    sole += 1;
                    continue;
                }
                if (ni.n_args > 64) {
                    open += 1;
                    continue;
                }
                var names_buf: [64]?[]const u8 = @splat(null);
                var heads_buf: [64]?[]const u8 = @splat(null);
                const n: usize = @intCast(ni.n_args);
                const cs = self.consts.items;
                for (0..n) |i| {
                    if (i < ni.arg_names.len) {
                        if (ni.arg_names[i]) |cid| {
                            if (cid.int() < cs.len and cs[cid.int()] == .String) names_buf[i] = cs[cid.int()].String;
                        }
                    }
                    if (i < ni.arg_static_heads.len) {
                        if (ni.arg_static_heads[i]) |cid| {
                            if (cid.int() < cs.len and cs[cid.int()] == .String) heads_buf[i] = cs[cid.int()].String;
                        }
                    }
                }
                if (staticCtorPick(self, ni.class, @intCast(n), names_buf[0..n], heads_buf[0..n])) |pick| {
                    ni.ctor_pick = pick;
                    bound += 1;
                } else {
                    open += 1;
                }
            }
        }
    }
    if (runtime.envOnce("KLIO_CTOR_PICK_PROBE") != null)
        std.debug.print("[ctor-pick-link] sole={d} bound={d} open={d}\n", .{ sole, bound, open });
}

/// `KLIO_CTOR_PROBE=1`: how many construction sites the argument count alone
/// settles, split by whether the class offers a choice at all.
pub fn probeCtorArity(self: *const Module) void {
    if (runtime.envOnce("KLIO_CTOR_PROBE") == null) return;
    var sole: usize = 0;
    var multi_decided: usize = 0;
    var multi_open: usize = 0;
    for (self.funcs.items) |*f| {
        for (f.blocks) |*b| {
            for (b.insts) |*inst| {
                if (inst.* != .NewInstance) continue;
                const ni = &inst.NewInstance;
                if (ni.class.int() >= self.classes.items.len) continue;
                const c = &self.classes.items[ni.class.int()];
                if (c.hasSoleCtor()) {
                    sole += 1;
                    continue;
                }
                if (soleCtorForArity(self, ni.class, @intCast(ni.n_args)) != null)
                    multi_decided += 1
                else
                    multi_open += 1;
            }
        }
    }
    std.debug.print("[ctor-probe] sole={d} multi_decided_by_arity={d} multi_open={d}\n", .{ sole, multi_decided, multi_open });
}

/// Whether the supertype-name walk from `cid` reaches the simple name `want`.
fn classNameReaches(self: *const Module, cid: ClassId, want: []const u8) bool {
    if (cid.int() >= self.classes.items.len) return false;
    const names = self.registry.class_super_names.get(self.classes.items[cid.int()].name) orelse return false;
    for (names) |nm| {
        if (std.mem.eql(u8, nm, want)) return true;
    }
    return false;
}

/// Every class `cid` IS, itself included: its transitive supertype closure,
/// sorted so a subtype test is a binary search rather than a walk.
///
/// Recomputed at link time rather than carried in the image, because it is a
/// pure function of `classes[].supertypes` which the image already holds, and
/// because `ClassId` is the image's own identifier — unlike a numbering this
/// pass invents, it cannot mean a different class in a later build.
pub fn linkClassAncestors(self: *Module, allocator: Allocator) Allocator.Error!void {
    const n = self.classes.items.len;
    self.class_ancestors.clearRetainingCapacity();
    try self.class_ancestors.ensureTotalCapacity(allocator, n);
    while (self.class_ancestors.items.len < n) self.class_ancestors.appendAssumeCapacity(&.{});

    var stack: std.ArrayList(ClassId) = .empty;
    defer stack.deinit(allocator);
    var acc: std.ArrayList(ClassId) = .empty;
    defer acc.deinit(allocator);

    // `Any` is every class's supertype and no class declares it, so the walk
    // over declared supertypes never reaches it: `Target as Any` threw a
    // ClassCastException until the closure carried it.
    const any_cid = self.classIdByFqn("kotlin.Any") orelse self.uniqueClassIdBySimpleName("Any");

    for (0..n) |i| {
        acc.clearRetainingCapacity();
        stack.clearRetainingCapacity();
        try stack.append(allocator, ClassId.from(@intCast(i)));
        var steps: usize = 0;
        while (stack.pop()) |cur| {
            steps += 1;
            if (steps > 4096) break;
            if (cur.int() >= n) continue;
            var seen = false;
            for (acc.items) |a| {
                if (a == cur) seen = true;
            }
            if (seen) continue;
            try acc.append(allocator, cur);
            const cc = &self.classes.items[cur.int()];
            for (cc.supertypes) |sup| try stack.append(allocator, sup);
            // `populateClassSupertypes` DROPS a supertype it cannot resolve as
            // the class is registered — a forward reference leaves no slot and
            // no ref — and nothing retries, so 111 classes on a compose program
            // record no supertype at all while the runtime knows their parent.
            // The names survive in the registry, recorded from the AST, and the
            // closure is the right place to read them: it is this pass's own
            // structure, with none of the parallel-to-`supertype_refs` or
            // `supertypes[0]`-is-the-superclass meaning that repairing the
            // class graph in place would break.
            if (cc.name.len != 0) {
                if (self.registry.class_super_names.get(cc.name)) |names| {
                    for (names) |nm| {
                        const sup = self.uniqueClassIdBySimpleName(nm) orelse continue;
                        if (sup.int() == cur.int()) continue;
                        try stack.append(allocator, sup);
                    }
                }
            }
        }
        if (any_cid) |any| {
            var has_any = false;
            for (acc.items) |e| {
                if (e == any) has_any = true;
            }
            if (!has_any) try acc.append(allocator, any);
        }
        std.mem.sort(ClassId, acc.items, {}, struct {
            fn lt(_: void, x: ClassId, y: ClassId) bool {
                return x.int() < y.int();
            }
        }.lt);
        self.class_ancestors.items[i] = try allocator.dupe(ClassId, acc.items);
    }
}

/// Whether an instance of `sub` is also a `sup`, by identity, or null when
/// this module has no closure for `sub` and cannot answer.
///
/// The distinction is the whole safety of the type test. A module that never
/// ran `linkClassAncestors` — a bundle loads its image and runs, skipping the
/// link path the build takes — has an EMPTY table, and a plain `false` there
/// says "not a subtype" about every class in the program. Returning null
/// sends the read back to the by-name walk instead.
pub fn classIsAKnown(self: *const Module, sub: ClassId, sup: ClassId) ?bool {
    if (sub.int() >= self.class_ancestors.items.len) return null;
    if (self.class_ancestors.items[sub.int()].len == 0) return null;
    return classIsA(self, sub, sup);
}

/// Whether an instance of `sub` is also a `sup`, by identity. Callers that
/// must not mistake "no closure" for "not a subtype" use `classIsAKnown`.
pub fn classIsA(self: *const Module, sub: ClassId, sup: ClassId) bool {
    if (sub.int() >= self.class_ancestors.items.len) return false;
    const list = self.class_ancestors.items[sub.int()];
    var lo: usize = 0;
    var hi: usize = list.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const v = list[mid].int();
        if (v == sup.int()) return true;
        if (v < sup.int()) lo = mid + 1 else hi = mid;
    }
    return false;
}

/// Bind every `is T` whose head names one declared class.
pub fn linkInstanceOfTargets(self: *Module) void {
    var n: usize = 0;
    var n_cast: usize = 0;
    for (self.funcs.items) |*f| {
        for (f.blocks) |*b| {
            for (b.insts) |*inst| {
                // `as T` asks the same question `is T` does, and answers it
                // from the same table.
                const ty = switch (inst.*) {
                    .InstanceOf => |io| io.ty,
                    .Cast => |ca| ca.ty,
                    else => continue,
                };
                // `is T?` admits null and `is List<String>` erases its
                // argument; neither is the plain identity question.
                if (ty.nullable or ty.args.len != 0) continue;
                // A written-out `is androidx...RememberObserverHolder` names
                // its class exactly; the simple-name index never matches one.
                const cid = (if (std.mem.findScalar(u8, ty.name, '.') != null)
                    self.classIdByFqn(ty.name)
                else
                    self.uniqueClassIdBySimpleName(ty.name)) orelse continue;
                switch (inst.*) {
                    .InstanceOf => |*io| {
                        io.cls = cid;
                        n += 1;
                    },
                    .Cast => |*ca| {
                        ca.cls_raw = cid.int();
                        n_cast += 1;
                    },
                    else => unreachable,
                }
            }
        }
    }
    if (runtime.envOnce("KLIO_ISCHECK_PROBE") != null)
        std.debug.print("[ischeck-link] bound={d} cast={d}\n", .{ n, n_cast });
}

/// `KLIO_THIS_PROBE=1`: how much of the implicit-receiver walk is a walk over
/// one thing. A `LoadFromThisOrGlobal` in a function that pushes no enclosing
/// receiver has exactly one implicit receiver — the function's own `this`,
/// which `this_idx` already names — so the search at runtime is over a chain
/// that lowering fixed. Split by whether the site already carries a resolved
/// identity, because those are a different repair.
pub fn probeThisOrGlobal(self: *const Module) void {
    if (runtime.envOnce("KLIO_THIS_PROBE") == null) return;
    var sites: usize = 0;
    var no_push_fn: usize = 0;
    var no_push_named: usize = 0;
    var with_push_fn: usize = 0;
    var pushes: usize = 0;
    var writes: usize = 0;
    var writes_no_push: usize = 0;
    var no_push_owner_declares: usize = 0;
    var no_push_owner_silent: usize = 0;
    var no_push_no_owner: usize = 0;
    for (self.funcs.items) |*f| {
        // The receiver a bare read would search, by either route lowering has:
        // the declaration's enclosing class, else the class of the frame's own
        // `this` parameter — a lambda body carries the second and not the first.
        const owner: ?ClassId = blk: {
            if (self.decl_sigs.get(f.id.int())) |ds| {
                if (ds.enclosing_class) |oc| {
                    if (oc.int() < self.classes.items.len) break :blk oc;
                }
            }
            if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) {
                const h = f.params[0].ty.name;
                const head = std.mem.trimEnd(u8, h, "?");
                if (self.classIdByFqn(head)) |c| break :blk c;
                if (self.uniqueClassIdBySimpleName(head)) |c| break :blk c;
            }
            break :blk null;
        };
        var fn_pushes: usize = 0;
        for (f.blocks) |*b| {
            for (b.insts) |*inst| {
                if (inst.* == .EnclosingPush) fn_pushes += 1;
            }
        }
        pushes += fn_pushes;
        for (f.blocks) |*b| {
            for (b.insts) |*inst| {
                switch (inst.*) {
                    .LoadFromThisOrGlobal => |lt| {
                        sites += 1;
                        if (fn_pushes != 0) {
                            with_push_fn += 1;
                        } else {
                            no_push_fn += 1;
                            if (lt.func != null or lt.class != null) {
                                no_push_named += 1;
                            } else if (owner) |oc| {
                                const nm = self.consts.items[lt.name.int()].String;
                                if (propSlotRoot(self, oc, nm) != null)
                                    no_push_owner_declares += 1
                                else
                                    no_push_owner_silent += 1;
                            } else no_push_no_owner += 1;
                        }
                    },
                    .StoreToThisOrGlobal => {
                        writes += 1;
                        if (fn_pushes == 0) writes_no_push += 1;
                    },
                    else => {},
                }
            }
        }
    }
    std.debug.print("[this-probe] reads={d} in_pushless_fn={d} of_those_named={d} in_pushing_fn={d} writes={d} writes_pushless={d} pushes={d}\n", .{
        sites, no_push_fn, no_push_named, with_push_fn, writes, writes_no_push, pushes,
    });
    std.debug.print("[this-probe] pushless_unnamed: owner_declares={d} owner_silent={d} no_owner={d}\n", .{
        no_push_owner_declares, no_push_owner_silent, no_push_no_owner,
    });
}

/// Mark every member-call site whose operation and receiver KIND are both
/// fixed at lowering. The runtime serves these from the site's operation and
/// the receiver's value tag; neither reads a name.
///
/// `KLIO_BUILTIN_PROVEN=0` leaves the bit clear, so a census claim can be
/// told from a serve.
pub fn linkBuiltinMembers(self: *Module) void {
    if (std.mem.eql(u8, runtime.envOnce("KLIO_BUILTIN_PROVEN") orelse "1", "0")) return;
    const open = hostOnlyHeads(self);
    var n: usize = 0;
    for (self.funcs.items) |*f| {
        for (f.blocks) |*b| {
            for (b.insts) |*inst| {
                if (inst.* != .CallMember) continue;
                const cm = &inst.CallMember;
                if (cm.builtin == .none) continue;
                // Either channel names the receiver's static head: an
                // explicit receiver records `declared_recv`, the
                // extension-body implicit one `static_recv`. The question
                // here is what the value IS, which both answer.
                const sr = cm.x().static_recv orelse cm.x().declared_recv orelse continue;
                const head = switch (self.consts.items[sr.int()]) {
                    .String => |str| str,
                    else => continue,
                };
                if (!builtinValueHead(head, cm.builtin, open)) continue;
                cm.builtin_proven = true;
                n += 1;
            }
        }
    }
    if (runtime.envOnce("KLIO_BUILTIN_PROBE") != null)
        std.debug.print("[builtin-link] proven={d} charseq_host_only={}\n", .{ n, open.char_sequence });
}

/// Bind the class a bare global read names, once every declaration exists.
///
/// A `LoadGlobal` carries an exact identity when the emitter had one, and
/// nineteen emitters build one. The ones that do not leave the read on the
/// host's name ladder — an env hash, then an object-name probe, then an FQN
/// probe — for a name the module's own tables answer. This pass asks the
/// question once per site instead of once per execution.
///
/// Only a name that uniquely names an `object` is bound. A top-level property
/// or function of the same name answers the read instead, and a class that is
/// not an object has no singleton to read in value position.
///
/// `KLIO_GLOBAL_ID=0` withdraws it.
pub fn linkGlobalIdentities(self: *Module) void {
    if (std.mem.eql(u8, runtime.envOnce("KLIO_GLOBAL_ID") orelse "1", "0")) return;
    var bound: usize = 0;
    var open: usize = 0;
    // synthesized, top-level property, no class, stub, not an object, name also a function
    var why: [6]usize = @splat(0);
    for (self.funcs.items) |*f| {
        for (f.blocks) |*b| {
            for (b.insts) |*inst| {
                if (inst.* != .LoadGlobal) continue;
                const lg = &inst.LoadGlobal;
                if (lg.func != null or lg.class != null) continue;
                if (lg.ctor_ref or lg.type_qualifier) continue;
                if (lg.name.int() >= self.consts.items.len) continue;
                const nm = switch (self.consts.items[lg.name.int()]) {
                    .String => |str| str,
                    else => continue,
                };
                open += 1;
                // A synthesized storage key names no declaration.
                if (nm.len == 0 or nm[0] == '$' or std.mem.startsWith(u8, nm, "__klio")) {
                    why[0] += 1;
                    continue;
                }
                // A top-level property answers the read from its own binding.
                if (self.registry.top_level_prop_getters.contains(nm) or
                    self.registry.top_level_prop_setters.contains(nm))
                {
                    why[1] += 1;
                    continue;
                }
                const cid_opt = self.classIdByFqn(nm) orelse self.uniqueClassIdBySimpleName(nm);
                const cid = cid_opt orelse {
                    why[2] += 1;
                    continue;
                };
                if (cid.int() >= self.classes.items.len) continue;
                const c = &self.classes.items[cid.int()];
                if (c.is_stub) {
                    why[3] += 1;
                    continue;
                }
                if (!c.is_object) {
                    why[4] += 1;
                    continue;
                }
                // A same-named top-level function shares the name's value
                // position, and a callee register is a `LoadGlobal` too.
                if (self.funcsBySimpleName(nm).len != 0) {
                    why[5] += 1;
                    continue;
                }
                lg.class = cid;
                bound += 1;
                open -= 1;
            }
        }
    }
    if (runtime.envOnce("KLIO_GLOBAL_ID_PROBE") != null)
        std.debug.print("[global-id-link] bound={d} open={d} synth={d} top_prop={d} no_class={d} stub={d} not_object={d} also_fn={d}\n", .{
            bound, open, why[0], why[1], why[2], why[3], why[4], why[5],
        });
}

/// Replace a bare read of a `const val` with the constant itself.
///
/// Kotlin's `const val` takes a compile-time constant initializer and cannot
/// be overridden or reassigned, so the read has one answer for the life of
/// the program. The scanner has recorded those values since it was written —
/// "so references inline it" — and nothing read the table: every such site
/// still hashed the name through the host's global ladder.
///
/// `KLIO_CONST_GLOBAL=0` withdraws it.
pub fn linkConstGlobals(self: *Module, allocator: Allocator) void {
    if (std.mem.eql(u8, runtime.envOnce("KLIO_CONST_GLOBAL") orelse "1", "0")) return;
    if (self.registry.top_level_const_vals.count() == 0) return;
    var inlined: usize = 0;
    for (self.funcs.items) |*f| {
        for (f.blocks) |*b| {
            for (b.insts) |*inst| {
                if (inst.* != .LoadGlobal) continue;
                const lg = inst.LoadGlobal;
                if (lg.func != null or lg.class != null) continue;
                if (lg.ctor_ref or lg.type_qualifier) continue;
                if (lg.name.int() >= self.consts.items.len) continue;
                const nm = switch (self.consts.items[lg.name.int()]) {
                    .String => |str| str,
                    else => continue,
                };
                const cv = constValFor(self, nm) orelse continue;
                const cid = self.internConst(allocator, cv) catch continue;
                inst.* = .{ .Const = .{ .dst = lg.dst, .value = cid } };
                inlined += 1;
            }
        }
    }
    if (runtime.envOnce("KLIO_CONST_GLOBAL_PROBE") != null)
        std.debug.print("[const-global] inlined={d}\n", .{inlined});
}

/// The recorded value of a `const val` the name reaches. The table is keyed by
/// FQN; a bare read spells the simple name, and a simple name that several
/// packages declare is no single constant.
fn constValFor(self: *const Module, name: []const u8) ?core_consts.Const {
    if (self.registry.top_level_const_vals.get(name)) |cv| return cv;
    if (std.mem.findScalar(u8, name, '.') != null) return null;
    var found: ?core_consts.Const = null;
    var it = self.registry.top_level_const_vals.iterator();
    while (it.next()) |e| {
        const fqn = e.key_ptr.*;
        const dot = std.mem.findScalarLast(u8, fqn, '.') orelse continue;
        if (!std.mem.eql(u8, fqn[dot + 1 ..], name)) continue;
        if (found != null) return null;
        found = e.value_ptr.*;
    }
    return found;
}

/// Mark every member-or-global site whose member leg cannot win: the function
/// pushes no enclosing receiver, so the only implicit receiver is its own
/// `this`; that class's hierarchy declares no such name; no extension of the
/// name exists at all; and a global target is already resolved.
///
/// The bit is a CLAIM, not a commit — `KLIO_XORY_AUDIT` checks it against the
/// arm that actually wins before anything is rewritten.
pub fn linkMemberOrGlobal(self: *Module) void {
    var n: usize = 0;
    var n_splice: usize = 0;
    var n_overloaded: usize = 0;
    var n_undeclared: usize = 0;
    var n_extension: usize = 0;
    for (self.funcs.items) |*f| {
        var pushes: usize = 0;
        for (f.blocks) |*b| {
            for (b.insts) |*inst| {
                if (inst.* == .EnclosingPush) pushes += 1;
            }
        }
        if (pushes != 0) continue;
        const owner: ?ClassId = blk: {
            if (self.decl_sigs.get(f.id.int())) |ds| {
                if (ds.enclosing_class) |oc| {
                    if (oc.int() < self.classes.items.len) break :blk oc;
                }
            }
            if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) {
                const head = std.mem.trimEnd(u8, f.params[0].ty.name, "?");
                if (self.classIdByFqn(head)) |c| break :blk c;
                if (self.uniqueClassIdBySimpleName(head)) |c| break :blk c;
            }
            // A lambda body's own signature spells no receiver; lowering
            // recorded the class its bare names resolve against.
            if (f.x().lexical_owner) |lo| {
                if (lo.len != 0) {
                    if (self.classIdByFqn(lo)) |c| break :blk c;
                    if (self.uniqueClassIdBySimpleName(lo)) |c| break :blk c;
                }
            }
            break :blk null;
        };
        // `runCatching { error("F") }` inside a class whose body declares
        // `error` reaches that member. A body that recorded its lexical owner
        // can be asked; one that recorded nothing cannot, and is refused.
        const is_declared = self.decl_sigs.get(f.id.int()) != null or f.x().lexical_owner != null;
        for (f.blocks) |*b| {
            for (b.insts) |*inst| {
                if (inst.* != .CallMemberOrGlobal) continue;
                const cg = inst.CallMemberOrGlobal;
                if (cg.func == null and cg.class == null) continue;
                if (owner == null and !is_declared) {
                    n_undeclared += 1;
                    continue;
                }
                const nm = switch (self.consts.items[cg.name.int()]) {
                    .String => |str| str,
                    else => continue,
                };
                // A synthesized name (`__klioMonitorEnter`, `$sgetter$...`)
                // has routes of its own that no class declaration describes,
                // and the audit found the member arm winning at every one.
                if (nm.len != 0 and (nm[0] == '$' or std.mem.startsWith(u8, nm, "__klio"))) continue;
                // Kotlin ranks an extension on an implicit receiver above a
                // top-level function, and `extensionCouldServe` is name-only,
                // so it is asked of the SITE and not of one receiver: a site
                // with no owner reached the owner branch's copy of this test
                // never, and claimed past a same-named extension.
                if (extensionCouldServe(self, owner, nm)) {
                    n_extension += 1;
                    continue;
                }
                // An inline splice binds its receiver as an ordinary register
                // of the CALLER's frame, so the site has an implicit receiver
                // that is neither a `this` parameter nor an `EnclosingPush`.
                // Naming that register's class and asking it the owner's
                // questions was tried and is NOT enough: `sortedDescending`
                // calls `reverseOrder()` inside `Iterable<T>.sortedWith`, and
                // the claim there changes what runs. Refused.
                if (cg.recv != null or cg.static_recv != null) {
                    n_splice += 1;
                    continue;
                }
                // The claim says the GLOBAL LEG wins, not which declaration
                // it runs: the leg re-ranks a name with several declarations
                // by the argument values, and the site's `func` is one guess
                // among them. A name with exactly one declaration has nothing
                // to re-rank.
                // The site's own candidate set is authoritative where lowering
                // recorded one, and a set of one has nothing to re-rank; the
                // module-wide name count is the fallback question.
                const sole_target = if (cg.candidates) |cands|
                    cands.len == 1
                else
                    self.funcsBySimpleName(nm).len == 1;
                if (!sole_target and !cg.func_final) {
                    n_overloaded += 1;
                    continue;
                }
                if (owner) |oc| {
                    // Answering "no supertype declares this" from a closure
                    // this module never built is the bundle's `is` bug again:
                    // an absent table reads as a confident no.
                    if (oc.int() >= self.class_ancestors.items.len) continue;
                    if (self.class_ancestors.items[oc.int()].len == 0) continue;
                    if (hierarchyDeclaresName(self, oc, nm)) continue;
                    if (anyAncestorDeclaresName(self, oc, nm)) continue;
                    if (hierarchyDeclaresMethod(self, oc, nm)) continue;
                }
                if (runtime.envOnce("KLIO_XORY_WHY")) |want| {
                    if (std.mem.eql(u8, want, "*") or std.mem.eql(u8, want, nm)) {
                        std.debug.print("[xory-why] claim {s} in={s} owner={s} methods={d}\n", .{
                            nm,
                            f.fqn,
                            if (owner) |oc| self.classes.items[oc.int()].fqn else "<none>",
                            if (owner) |oc| self.classes.items[oc.int()].methods.len else 0,
                        });
                    }
                }
                inst.CallMemberOrGlobal.global_only = true;
                n += 1;
            }
        }
    }
    if (runtime.envOnce("KLIO_XORY_PROBE") != null)
        std.debug.print("[xory-link] global_only={d} splice_receiver={d} overloaded={d} undeclared_frame={d} extension={d}\n", .{ n, n_splice, n_overloaded, n_undeclared, n_extension });
}

/// `KLIO_XORY_PROBE=1`: how much of the member-or-global hedge is decidable.
///
/// The instruction exists because lowering could not prove the name is NOT a
/// member of some implicit receiver. Whole-program, that is a question with
/// an answer: if no receiver in scope at the site declares the name, the call
/// is the global leg and the hedge is dead. The receivers in scope are the
/// function's own `this` and anything an `EnclosingPush` put there — and a
/// function that pushes none has at most one.
pub fn probeMemberOrGlobal(self: *const Module) void {
    if (runtime.envOnce("KLIO_XORY_PROBE") == null) return;
    var sites: usize = 0;
    var pushless: usize = 0;
    var pushless_named_global: usize = 0;
    var decidable_global: usize = 0;
    var owner_declares: usize = 0;
    var no_owner_at_all: usize = 0;
    var ext_could_serve: usize = 0;
    for (self.funcs.items) |*f| {
        var pushes: usize = 0;
        for (f.blocks) |*b| {
            for (b.insts) |*inst| {
                if (inst.* == .EnclosingPush) pushes += 1;
            }
        }
        const owner: ?ClassId = blk: {
            if (self.decl_sigs.get(f.id.int())) |ds| {
                if (ds.enclosing_class) |oc| {
                    if (oc.int() < self.classes.items.len) break :blk oc;
                }
            }
            if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) {
                const head = std.mem.trimEnd(u8, f.params[0].ty.name, "?");
                if (self.classIdByFqn(head)) |c| break :blk c;
                if (self.uniqueClassIdBySimpleName(head)) |c| break :blk c;
            }
            break :blk null;
        };
        for (f.blocks) |*b| {
            for (b.insts) |*inst| {
                if (inst.* != .CallMemberOrGlobal) continue;
                const cg = inst.CallMemberOrGlobal;
                sites += 1;
                if (pushes != 0) continue;
                pushless += 1;
                const has_global_target = cg.func != null or cg.class != null;
                if (has_global_target) pushless_named_global += 1;
                const nm = switch (self.consts.items[cg.name.int()]) {
                    .String => |str| str,
                    else => continue,
                };
                if (owner) |oc| {
                    if (hierarchyDeclaresName(self, oc, nm)) {
                        owner_declares += 1;
                    } else if (extensionCouldServe(self, oc, nm)) {
                        ext_could_serve += 1;
                    } else if (has_global_target) {
                        decidable_global += 1;
                    }
                } else {
                    no_owner_at_all += 1;
                    if (has_global_target) decidable_global += 1;
                }
            }
        }
    }
    std.debug.print("[xory-probe] sites={d} pushless={d} with_global_target={d} owner_declares={d} ext_could_serve={d} no_owner={d} decidable_global={d}\n", .{
        sites, pushless, pushless_named_global, owner_declares, ext_could_serve, no_owner_at_all, decidable_global,
    });
}

/// Whether `cid` or anything in its ancestor closure declares a METHOD called
/// `name`.
///
/// `hierarchyDeclaresName` and `anyAncestorDeclaresName` read declared
/// PROPERTIES and the shadow-name registry, and a member function is in
/// neither. A test class declaring `fun error(message: String): Nothing`
/// shadows `kotlin.error` for every bare call in its own body, and the
/// member-or-global claim could not see it.
pub fn hierarchyDeclaresMethod(self: *const Module, cid: ClassId, name: []const u8) bool {
    if (cid.int() >= self.classes.items.len) return false;
    if (classDeclaresMethod(self, cid, name)) return true;
    if (cid.int() >= self.class_ancestors.items.len) return true;
    for (self.class_ancestors.items[cid.int()]) |anc| {
        if (classDeclaresMethod(self, anc, name)) return true;
    }
    // The name-keyed supertype chain reaches edges the closure can miss.
    const c = &self.classes.items[cid.int()];
    const chain: []const []const u8 = self.registry.class_super_names.get(c.name) orelse &.{};
    for (chain) |sup| {
        const sid = self.classIdByFqn(sup) orelse self.classId(sup) orelse continue;
        if (classDeclaresMethod(self, sid, name)) return true;
    }
    return false;
}

fn classDeclaresMethod(self: *const Module, cid: ClassId, name: []const u8) bool {
    if (cid.int() >= self.classes.items.len) return false;
    for (self.classes.items[cid.int()].methods) |fid| {
        const f = self.funcById(fid) orelse continue;
        if (std.mem.eql(u8, f.name, name)) return true;
    }
    return false;
}

/// Whether any class in `cid`'s ancestor closure declares `name`. The
/// name-keyed hierarchy tables miss an edge the closure has, and a bare call
/// resolves against every supertype, so both are asked.
pub fn anyAncestorDeclaresName(self: *const Module, cid: ClassId, name: []const u8) bool {
    if (cid.int() >= self.class_ancestors.items.len) return true;
    for (self.class_ancestors.items[cid.int()]) |anc| {
        if (anc.int() >= self.classes.items.len) continue;
        const c = &self.classes.items[anc.int()];
        for (c.declared_props) |pr| {
            if (std.mem.eql(u8, pr.name, name)) return true;
        }
        if (self.registry.hierarchy_shadow_names.get(c.name)) |hs| {
            if (hs.names.contains(name)) return true;
        }
        var buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}\u{1f}{s}", .{ c.name, name }) catch return true;
        if (self.registry.subclass_declares_prop.contains(key)) return true;
    }
    return false;
}

/// Whether any extension named `name` could serve a bare call on an implicit
/// receiver of class `cid`. Kotlin ranks an extension on the implicit
/// receiver above a top-level function, so committing the global leg without
/// asking this would skip it.
///
/// Deliberately generous: any declaration of the name with a receiver type at
/// all counts, without checking that the receiver relates or the shape fits.
/// The direction that over-reports is the one that refuses to commit.
pub fn extensionCouldServe(self: *const Module, cid: ?ClassId, name: []const u8) bool {
    for (self.funcsBySimpleName(name)) |fid| {
        const sig = self.decl_sigs.get(fid.int()) orelse continue;
        const rt = sig.receiver_ty orelse continue;
        // No receiver to compare against: any extension of the name could be
        // the one that serves.
        const sub = cid orelse return true;
        const head = m_static.staticTypeHead(std.mem.trimEnd(u8, rt.name, "?"));
        if (head.len == 0) return true;
        // An unbounded type-parameter receiver applies to every type.
        if (head.len <= 2 and isAllUpperName(head)) return true;
        const rcid = self.classIdByFqn(head) orelse self.uniqueClassIdBySimpleName(head) orelse return true;
        if (rcid.int() == sub.int()) return true;
        // An absent ancestor closure reads as "cannot say", never as "no".
        if (self.classIsAKnown(sub, rcid) orelse return true) return true;
    }
    return false;
}

fn isAllUpperName(s: []const u8) bool {
    for (s) |c| {
        if (c < 'A' or c > 'Z') return false;
    }
    return s.len != 0;
}

/// Whether `cid` or any of its supertypes declares a member called `name`,
/// by either route the registry records.
pub fn hierarchyDeclaresName(self: *const Module, cid: ClassId, name: []const u8) bool {
    if (cid.int() >= self.classes.items.len) return false;
    const c = &self.classes.items[cid.int()];
    for (c.declared_props) |pr| {
        if (std.mem.eql(u8, pr.name, name)) return true;
    }
    if (self.registry.hierarchy_shadow_names.get(c.name)) |hs| {
        if (hs.names.contains(name)) return true;
    }
    const chain: []const []const u8 = self.registry.class_super_names.get(c.name) orelse &.{};
    for (chain) |sup| {
        if (self.registry.hierarchy_shadow_names.get(sup)) |hs| {
            if (hs.names.contains(name)) return true;
        }
    }
    return false;
}

/// `KLIO_BUILTIN_PROBE=1`: how many member-call sites name a builtin
/// operation, and how many of those also carry a static receiver head that
/// no interpreted instance can wear. The second number is the one that can
/// be called resolved: the site names the operation AND the receiver kind,
/// so the runtime's tag test is an assertion rather than a derivation.
pub fn probeBuiltinMembers(self: *const Module) void {
    if (runtime.envOnce("KLIO_BUILTIN_PROBE") == null) return;
    var sites: usize = 0;
    var named_op: usize = 0;
    var op_with_head: usize = 0;
    var op_head_nonclass: usize = 0;
    for (self.funcs.items) |*f| {
        for (f.blocks) |*b| {
            for (b.insts) |*inst| {
                if (inst.* != .CallMember) continue;
                const cm = &inst.CallMember;
                sites += 1;
                if (cm.builtin == .none) continue;
                named_op += 1;
                const sr = cm.x().static_recv orelse continue;
                op_with_head += 1;
                const head = switch (self.consts.items[sr.int()]) {
                    .String => |str| str,
                    else => continue,
                };
                if (builtinValueHead(head, cm.builtin, hostOnlyHeads(self))) op_head_nonclass += 1;
            }
        }
    }
    var set_sites: usize = 0;
    var set_with_head: usize = 0;
    var get_sites: usize = 0;
    var get_with_head: usize = 0;
    for (self.funcs.items) |*f| {
        for (f.blocks) |*b| {
            for (b.insts) |*inst| {
                if (inst.* != .CallMember) continue;
                const cm = &inst.CallMember;
                const has_head = cm.x().static_recv != null;
                if (cm.builtin == .set) {
                    set_sites += 1;
                    if (has_head) set_with_head += 1;
                } else if (cm.builtin == .get) {
                    get_sites += 1;
                    if (has_head) get_with_head += 1;
                }
            }
        }
    }
    std.debug.print("[builtin-probe] member_sites={d} named_op={d} with_static_recv={d} head_is_builtin_value={d}\n", .{
        sites, named_op, op_with_head, op_head_nonclass,
    });
    std.debug.print("[builtin-probe] get={d} get_with_head={d} set={d} set_with_head={d}\n", .{
        get_sites, get_with_head, set_sites, set_with_head,
    });
}

/// Whether a site's receiver head and operation together name a path that
/// always serves, so the site cannot fall back to the by-name walk.
///
/// A head alone does not settle it. A scalar's operations decline on a
/// mismatched argument and a string has no `set` at all; either would send
/// the site back to the walk, and the audit said so the first time this
/// answered on the head alone.
/// Which INTERFACE heads this module can only ever satisfy with a host-backed
/// value. An interpreted class implementing one arrives at the serve as an
/// `Instance`, which no host path answers, so a claim over that head would be
/// false the moment such a class exists. Computed once per link, since the
/// answer is a property of the class graph and not of a site.
pub const HostOnlyHeads = struct {
    char_sequence: bool = false,
};

pub fn hostOnlyHeads(self: *const Module) HostOnlyHeads {
    return .{ .char_sequence = !anyInterpretedImplementor(self, "CharSequence") };
}

/// A head with no class row answers TRUE: a class naming it as a supertype
/// left no ancestor edge to find, and an unprovable claim is the wrong way to
/// be wrong.
fn anyInterpretedImplementor(self: *const Module, head: []const u8) bool {
    const want = self.classIdByFqn(head) orelse self.uniqueClassIdBySimpleName(head) orelse return true;
    for (self.classes.items, 0..) |*c, i| {
        if (c.name.len == 0 or c.is_stub or c.is_intrinsic_backed) continue;
        // A class's ancestor list names the class itself, which is the head
        // and not an implementor of it.
        if (i == want.int()) continue;
        if (i >= self.class_ancestors.items.len) continue;
        for (self.class_ancestors.items[i]) |anc| {
            if (anc.int() == want.int()) {
                if (runtime.envOnce("KLIO_BUILTIN_PROBE") != null)
                    std.debug.print("[host-only] {s} implements {s}\n", .{ c.fqn, head });
                return true;
            }
        }
    }
    return false;
}

pub fn builtinValueHead(head: []const u8, op: core_inst.BuiltinMember, open: HostOnlyHeads) bool {
    const array_names = [_][]const u8{
        "IntArray",  "LongArray",    "FloatArray", "DoubleArray",
        "ShortArray", "ByteArray",   "CharArray",  "BooleanArray",
        "UIntArray", "ULongArray",   "UShortArray", "UByteArray",
        "Array",
    };
    const simple = if (std.mem.findScalarLast(u8, head, '.')) |i| head[i + 1 ..] else head;
    switch (op) {
        .get, .set => {
            for (array_names) |n| {
                if (std.mem.eql(u8, simple, n)) return true;
            }
            // A string is immutable, so only the read is a path at all. It
            // serves an ASCII index directly, a non-ASCII one through the
            // cursor-resumed UTF-16 walk, and raises the out-of-bounds the
            // native would have raised.
            if (op != .get) return false;
            // A string is immutable, so only the read is a path at all. It
            // serves an ASCII index directly, a non-ASCII one through the
            // cursor-resumed walk, and raises the out-of-bounds the native
            // would have raised; a builder, which is final, does the same
            // against the reader memo.
            if (std.mem.eql(u8, simple, "String") or std.mem.eql(u8, simple, "StringBuilder")) return true;
            // `CharSequence` is neither, so it is a claim about the class
            // graph: with no interpreted implementor, every value under that
            // head is one of the two above.
            // `List` is NOT here, measured: `AbstractList.subList` returns an
            // interpreted `SubList`, so a list-headed site can receive an
            // instance no host serve answers, and the graph question refuses
            // the head in every module the stdlib is part of.
            return open.char_sequence and std.mem.eql(u8, simple, "CharSequence");
        },
        // `toString` on the two host-backed text shapes: a string is its own,
        // a builder's is its buffer decoded, and `CharSequence` answers under
        // the same graph question the subscript asks.
        .to_string => {
            if (std.mem.eql(u8, simple, "String") or std.mem.eql(u8, simple, "StringBuilder")) return true;
            return open.char_sequence and std.mem.eql(u8, simple, "CharSequence");
        },
        // The bit and width operations of `Int` and `Long`. Each is declared
        // to take the receiver's own width, or an `Int` count for a shift, so
        // the pair the serve requires is the only pair the call can present.
        .inv, .to_int, .to_long, .shl, .shr, .ushr, .bit_and, .bit_or, .bit_xor => {
            return std.mem.eql(u8, simple, "Int") or std.mem.eql(u8, simple, "Long");
        },
        // `compareTo` is NOT here: `Int.compareTo` is declared over every
        // other numeric width too, and the serve takes only a same-kind pair.
        else => return false,
    }
}

/// `KLIO_GRAPH_PROBE=1`: how complete the class graph is. A class whose
/// closure is only itself and `Any` has no supertype edge at all; split by
/// whether the registry remembers a name the resolution could have used,
/// because that tells a dropped forward reference from a genuine root.
pub fn probeClassGraph(self: *const Module) void {
    if (runtime.envOnce("KLIO_GRAPH_PROBE") == null) return;
    var total: usize = 0;
    var rootish: usize = 0;
    var rootish_with_names: usize = 0;
    var declared_edges: usize = 0;
    var registry_names: usize = 0;
    for (self.classes.items, 0..) |*c, i| {
        if (c.name.len == 0) continue;
        total += 1;
        declared_edges += c.supertypes.len;
        const names: usize = if (self.registry.class_super_names.get(c.name)) |ns| ns.len else 0;
        registry_names += names;
        const anc: usize = if (i < self.class_ancestors.items.len) self.class_ancestors.items[i].len else 0;
        if (anc <= 2) {
            rootish += 1;
            if (names != 0) rootish_with_names += 1;
        }
    }
    std.debug.print("[graph] classes={d} rootish={d} rootish_with_names={d} declared_edges={d} registry_names={d}\n", .{
        total, rootish, rootish_with_names, declared_edges, registry_names,
    });
}

/// `KLIO_ISCHECK_PROBE=1`: how many `is T` sites name something the module
/// could test by identity — a unique declared class — against those whose
/// head is a builtin, a type parameter, or ambiguous.
pub fn probeInstanceOf(self: *const Module) void {
    if (runtime.envOnce("KLIO_ISCHECK_PROBE") == null) return;
    var unique_class: usize = 0;
    var generic_args: usize = 0;
    var nullable: usize = 0;
    var no_class: usize = 0;
    for (self.funcs.items) |*f| {
        for (f.blocks) |*b| {
            for (b.insts) |*inst| {
                if (inst.* != .InstanceOf) continue;
                const ty = inst.InstanceOf.ty;
                if (ty.nullable) {
                    nullable += 1;
                    continue;
                }
                if (ty.args.len != 0) {
                    generic_args += 1;
                    continue;
                }
                const resolved = if (std.mem.findScalar(u8, ty.name, '.') != null)
                    self.classIdByFqn(ty.name)
                else
                    self.uniqueClassIdBySimpleName(ty.name);
                if (resolved != null) unique_class += 1 else no_class += 1;
            }
        }
    }
    std.debug.print("[ischeck] unique_class={d} generic_args={d} nullable={d} no_class={d}\n", .{
        unique_class, generic_args, nullable, no_class,
    });
}

const testing = std.testing;

/// A class carrying nothing but its constructor signatures, which is all a
/// pick reads.
fn ctorTestClass(m: *Module, a: Allocator, name: []const u8, primary: ?core_class.CtorArity, secondaries: []const core_class.CtorArity) Allocator.Error!ClassId {
    const id = ClassId.from(@intCast(m.classes.items.len));
    try m.classes.append(a, .{
        .id = id,
        .name = name,
        .fqn = name,
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
        .has_primary_ctor = primary != null,
        .primary_ctor_sig = primary,
        .secondary_ctor_arities = secondaries,
        .secondary_ctor_count = @intCast(secondaries.len),
    });
    return id;
}

test "a class with no parameter list still has one constructor" {
    const a = testing.allocator;
    var m = Module.init(a);
    defer m.deinit(a);
    const bare = try ctorTestClass(&m, a, "Bare", null, &.{});
    try testing.expect(m.classes.items[bare.int()].hasSoleCtor());
    // Its implicit constructor takes no arguments, and the pick names it.
    try testing.expectEqual(@as(?u16, 0), m.staticCtorPick(bare, 0, &.{}, &.{}));

    // One secondary and no primary header is still one constructor, but it is
    // the secondary: the implicit no-argument one is gone.
    const one_sec = try ctorTestClass(&m, a, "OneSec", null, &.{.{ .required = 1, .total = 1 }});
    try testing.expect(m.classes.items[one_sec.int()].hasSoleCtor());
    try testing.expectEqual(@as(?core_class.CtorArity, null), m.classes.items[one_sec.int()].primaryArity());
}

test "the argument count names a constructor when only one accepts it" {
    const a = testing.allocator;
    var m = Module.init(a);
    defer m.deinit(a);
    const c = try ctorTestClass(
        &m,
        a,
        "Two",
        .{ .required = 2, .total = 2, .param_heads = &.{ "Int", "Int" }, .param_names = &.{ "a", "b" } },
        &.{.{ .required = 1, .total = 1, .param_heads = &.{"String"}, .param_names = &.{"s"} }},
    );
    try testing.expectEqual(@as(?u16, 1), m.staticCtorPick(c, 1, &.{null}, &.{null}));
    try testing.expectEqual(@as(?u16, 0), m.staticCtorPick(c, 2, &.{ null, null }, &.{ null, null }));
    // No constructor takes three.
    try testing.expectEqual(@as(?u16, null), m.staticCtorPick(c, 3, &.{ null, null, null }, &.{ null, null, null }));
}

test "the static heads separate two constructors the count cannot" {
    const a = testing.allocator;
    var m = Module.init(a);
    defer m.deinit(a);
    const c = try ctorTestClass(
        &m,
        a,
        "Same",
        .{ .required = 1, .total = 1, .param_heads = &.{"Int"}, .param_names = &.{"n"} },
        &.{.{ .required = 1, .total = 1, .param_heads = &.{"String"}, .param_names = &.{"s"} }},
    );
    try testing.expectEqual(@as(?u16, 1), m.staticCtorPick(c, 1, &.{null}, &.{"String"}));
    try testing.expectEqual(@as(?u16, 0), m.staticCtorPick(c, 1, &.{null}, &.{"Int"}));
    // A head lowering does not know leaves the choice to the runtime, and so
    // does a head neither constructor declares.
    try testing.expectEqual(@as(?u16, null), m.staticCtorPick(c, 1, &.{null}, &.{null}));
    try testing.expectEqual(@as(?u16, null), m.staticCtorPick(c, 1, &.{null}, &.{"Double"}));
    // A named argument binds by name, so the positional comparison is refused.
    try testing.expectEqual(@as(?u16, null), m.staticCtorPick(c, 1, &.{"s"}, &.{"String"}));
}

test "a constructor source cannot name loses to one it can" {
    const a = testing.allocator;
    var m = Module.init(a);
    defer m.deinit(a);
    const c = try ctorTestClass(
        &m,
        a,
        "Hidden",
        .{ .required = 2, .total = 4, .param_heads = &.{ "T", "C", "T", "String" }, .param_names = &.{ "a", "b", "c", "d" } },
        &.{.{ .required = 2, .total = 3, .low_priority = true, .param_heads = &.{ "T", "C", "T" }, .param_names = &.{ "a", "b", "c" } }},
    );
    // Both accept three arguments; the hidden one is not a candidate.
    try testing.expectEqual(@as(?u16, 0), m.staticCtorPick(c, 3, &.{ null, null, null }, &.{ null, null, null }));
}
