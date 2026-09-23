//! The per-class field layout, composed from what each class publishes.
//!
//! A class's own slots and its superclass link are properties of the
//! declaration (`ir.Class.field_layout`); this flattens a chain of them into the
//! layout an instance of that class actually holds, so a field read can name a
//! slot by index instead of by name. `interp_ir/class_layout.zig` computes the
//! same answer by walking the runtime `ClassDef` graph and is the oracle the
//! two are checked against.

const std = @import("std");
const runtime = @import("runtime");
const Allocator = std.mem.Allocator;
const root_ir = @import("../ir.zig");
const core_class = @import("class.zig");
const m_props = @import("module_props.zig");
const core_ids = @import("ids.zig");
const inst_mod = @import("inst.zig");

const ClassId = core_ids.ClassId;
const FuncId = core_ids.FuncId;
const FieldLayoutState = core_class.FieldLayoutState;
const FieldSlot = core_class.FieldSlot;
const Module = root_ir.Module;

/// Chains deeper than this are a cycle; matches the runtime walk's cap, so a
/// chain one accepts the other never refuses.
const max_depth: usize = 64;

/// One class's complete field layout, base classes first.
pub const ClassFieldLayout = struct {
    /// Every slot an instance holds, in order: the chain's declared slots, then
    /// the plain constructor parameters its member bodies capture.
    slots: []const FieldSlot = &.{},
    /// How many leading `slots` are declared; the rest are captures.
    declared: u32 = 0,
    /// How many leading `slots` come from the superclass.
    base: u32 = 0,
    state: FieldLayoutState = .unpublished,
};

/// The layout of `cid`, or null when the class has none to read: an interface, an
/// object expression, a function-local class, or one no build described.
pub fn classFieldLayout(self: *const Module, cid: ClassId) ?*const ClassFieldLayout {
    if (cid.int() >= self.field_layout.items.len) return null;
    const entry = &self.field_layout.items[cid.int()];
    return if (entry.state == .ok) entry else null;
}

/// Why `cid` has no layout, for a caller that must tell "no storage" from "not
/// described". Null when the class has one, or is off the end of the table.
pub fn classFieldLayoutState(self: *const Module, cid: ClassId) ?FieldLayoutState {
    if (cid.int() >= self.field_layout.items.len) return null;
    return self.field_layout.items[cid.int()].state;
}

/// The slot `name` occupies in `cid`'s layout. A declared slot's index holds for
/// every subclass of `cid`; a capture's does not (see `ir.FieldLayout`).
pub fn fieldSlotIndex(self: *const Module, cid: ClassId, name: []const u8) ?u32 {
    const entry = classFieldLayout(self, cid) orelse return null;
    for (entry.slots, 0..) |slot, i| {
        if (std.mem.eql(u8, slot.name, name)) return @intCast(i);
    }
    return null;
}

/// Bind every field read whose answer is a property ACCESSOR to that getter.
///
/// Runs after every class body has lowered, which is the only time it can: the
/// getter is a function the body lowering creates, so a read lowered earlier
/// cannot name it. Lowering records the receiver's static class on the read
/// regardless, and this pass turns that into a target. 20% of field reads on a
/// compose program are this shape — the layout holds no slot because an
/// accessor answers, and the runtime finds it by name on every read.
/// Property names some STRICT subclass of a class declares, keyed by the
/// class's simple name. Built at link time because that is the only point both
/// sources are complete: a subclass's own layout slots, and the accessors the
/// class bodies created — an override that replaces a stored property with a
/// getter contributes NO slot, so a scan over layouts alone cannot see it, and
/// that blind spot is what made an earlier attempt at this unsound.
pub fn linkGetterRoutes(self: *Module) void {
    var buf: [256]u8 = undefined;
    var n_none: usize = 0;
    var n_cls: usize = 0;
    var n_bound: usize = 0;
    var n_open: usize = 0;
    var n_comp: usize = 0;
    var n_prop: usize = 0;
    var n_sget: usize = 0;
    const probe = runtime.envOnce("KLIO_GETTER_PROBE") != null;
    // Both halves of "does any subclass redeclare this" are complete here and
    // nowhere earlier, which is why the open-class claim is made in this pass
    // rather than at the read.

    for (self.funcs.items) |*f| {
        // An accessor reading its own property reads the backing store: the
        // scoped name it carries must not resolve to the accessor itself.
        const own_accessor_prop: ?[]const u8 = if (std.mem.startsWith(u8, f.name, "__get_"))
            f.name["__get_".len..]
        else if (std.mem.startsWith(u8, f.name, "__set_"))
            f.name["__set_".len..]
        else
            null;
        for (f.blocks) |*b| {
            for (b.insts) |*inst| {
                if (inst.* != .GetField) continue;
                const gf = &inst.GetField;
                if (gf.own_kind != .none) continue;
                n_none += 1;
                const raw = switch (self.consts.items[gf.field.int()]) {
                    .String => |str| str,
                    else => continue,
                };
                // A bare read inside a method is spelled
                // `$sgetter$<owner>\u{1f}<prop>`, and the runtime decodes it on
                // every execution to dispatch virtually: an `open val` a
                // subclass overrides answers from the subclass even in a base
                // method. That IS the property table's rule, and the name
                // carries the owner the site's `own_cls` does not, so these
                // resolve without a receiver type.
                if (sgetterOwnerClass(self, raw)) |sg| {
                    if (own_accessor_prop) |oap| {
                        // `__get_<Owner>_<prop>` reading `$sgetter$<Owner>\u{1f}<prop>`.
                        if (std.mem.endsWith(u8, oap, sg.prop) and oap.len > sg.prop.len and oap[oap.len - sg.prop.len - 1] == '_') {
                            const owner_part = oap[0 .. oap.len - sg.prop.len - 1];
                            if (sg.cid.int() < self.classes.items.len and std.mem.eql(u8, owner_part, self.classes.items[sg.cid.int()].name)) continue;
                        }
                    }
                    // A private accessor is the declaring class's own and no
                    // subclass redeclares it: the language names it outright,
                    // ahead of the family slot a runtime class would pick.
                    if (privateGetterOn(self, sg.cid, sg.prop, &buf)) |fid| {
                        gf.own_cls = sg.cid;
                        gf.own_slot = fid.int();
                        gf.own_kind = .getter;
                        n_bound += 1;
                        continue;
                    }
                }
                if (sgetterSlot(self, raw)) |slot| {
                    gf.own_slot = slot.int();
                    gf.own_kind = .prop_slot;
                    n_sget += 1;
                    continue;
                }
                const cid = gf.own_cls orelse continue;
                n_cls += 1;
                const name = raw;
                // `Color.Unspecified` names the CLASSIFIER and reads a plain
                // stored field of its companion SINGLETON, whose class is the
                // companion's. The read's recorded class is the outer one, so
                // the claim has to hop.
                if (companionSlotOwner(self, cid, name)) |comp| {
                    if (soleCtorSlot(self, comp.cid, name, &buf)) |idx| {
                        gf.own_cls = comp.cid;
                        gf.own_slot = idx;
                        gf.own_kind = .slot;
                        n_comp += 1;
                        continue;
                    }
                }
                if (openSlotLinkEnabled()) {
                    if (openClassSlot(self, cid, name, &buf)) |idx| {
                        gf.own_slot = idx;
                        gf.own_kind = .slot;
                        n_open += 1;
                        continue;
                    }
                }
                if (getterFor(self, cid, name, &buf)) |fid| {
                    gf.own_slot = fid.int();
                    gf.own_kind = .getter;
                    n_bound += 1;
                    continue;
                }
                // What no contract on a named class can answer: the property
                // is declared where no implementation lives, so the read
                // carries the family's slot and the receiver's class picks.
                const slot = m_props.propSlotOf(self, cid, name) orelse continue;
                gf.own_slot = slot.int();
                gf.own_kind = .prop_slot;
                n_prop += 1;
            }
        }
    }
    if (probe)
        std.debug.print("[getter-link] unresolved={d} with_class={d} getter={d} prop_slot={d} open_slot={d} companion={d} sgetter={d}\n", .{ n_none, n_cls, n_bound, n_prop, n_open, n_comp, n_sget });
}

/// The property slot a scope-qualified read names, or null when the spelling
/// is not one or the owner declares no family for the property.
///
/// `KLIO_SGETTER_SLOT=0` leaves these on the runtime decode.
/// The owner class and property a `$sgetter$<owner>\u{1f}<prop>` field names.
fn sgetterOwnerClass(self: *const Module, raw: []const u8) ?struct { cid: ClassId, prop: []const u8 } {
    if (!std.mem.startsWith(u8, raw, "$sgetter$")) return null;
    const rest = raw["$sgetter$".len..];
    const sep = std.mem.findScalar(u8, rest, '\u{1f}') orelse return null;
    const owner = rest[0..sep];
    const cid = self.classIdByFqn(owner) orelse self.uniqueClassIdBySimpleName(owner) orelse return null;
    return .{ .cid = cid, .prop = rest[sep + 1 ..] };
}

/// The private getter `cid` itself declares for `prop`, with a body.
fn privateGetterOn(self: *const Module, cid: ClassId, prop: []const u8, buf: []u8) ?FuncId {
    if (cid.int() >= self.classes.items.len) return null;
    const c = &self.classes.items[cid.int()];
    if (c.name.len == 0) return null;
    const fid = uniqueFuncNamed(self, buf, "__get_{s}_{s}", c.name, prop) orelse return null;
    const sig = self.decl_sigs.get(fid.int()) orelse return null;
    return if (sig.visibility == .Private) fid else null;
}

fn sgetterSlot(self: *const Module, raw: []const u8) ?core_ids.PropSlotId {
    if (!std.mem.startsWith(u8, raw, "$sgetter$")) return null;
    if (std.mem.eql(u8, runtime.envOnce("KLIO_SGETTER_SLOT") orelse "1", "0")) return null;
    const rest = raw["$sgetter$".len..];
    const sep = std.mem.findScalar(u8, rest, '\u{1f}') orelse return null;
    const owner = rest[0..sep];
    const prop = rest[sep + 1 ..];
    const cid = self.classIdByFqn(owner) orelse self.uniqueClassIdBySimpleName(owner) orelse return null;
    return m_props.propSlotOf(self, cid, prop);
}

/// The companion class of `cid` when the property is the companion's rather
/// than the class's own.
fn companionSlotOwner(self: *const Module, cid: ClassId, name: []const u8) ?struct { cid: ClassId } {
    if (cid.int() >= self.classes.items.len) return null;
    const c = &self.classes.items[cid.int()];
    if (c.name.len == 0) return null;
    if (fieldSlotIndex(self, cid, name) != null) return null;
    const mangled = self.registry.companion_singletons.get(c.name) orelse
        self.registry.companion_singletons.get(c.fqn) orelse return null;
    const ccid = self.classIdByFqn(mangled) orelse self.classId(mangled) orelse return null;
    return .{ .cid = ccid };
}

/// A plain stored constructor-or-body slot of a class nothing can subclass:
/// the conditions `fieldSlotClaim` applies at a read, minus the ones about a
/// receiver, since a companion singleton is the only instance of its class.
fn soleCtorSlot(self: *const Module, cid: ClassId, name: []const u8, buf: []u8) ?u32 {
    _ = buf;
    if (cid.int() >= self.classes.items.len) return null;
    const c = &self.classes.items[cid.int()];
    if (c.is_open or c.is_abstract or c.is_interface) return null;
    const entry = classFieldLayout(self, cid) orelse return null;
    const idx = fieldSlotIndex(self, cid, name) orelse return null;
    if (idx >= entry.declared) return null;
    const slot = entry.slots[idx];
    if (!slot.plain) return null;
    for (entry.slots) |sl| {
        if (std.mem.startsWith(u8, sl.name, "__delegate__")) return null;
    }
    var cells: usize = 0;
    for (entry.slots[0..entry.declared]) |sl| {
        if (std.mem.eql(u8, propNameOfSlotKey(sl.name), name)) cells += 1;
    }
    return if (cells == 1) idx else null;
}

/// A slot's registry key is owner-mangled where a class shadows a supertype's
/// same-named property; the property name is the part after the separator.
pub fn propNameOfSlotKey(key: []const u8) []const u8 {
    if (std.mem.findScalar(u8, key, '\u{1f}')) |sep| return key[sep + 1 ..];
    return key;
}

/// `KLIO_OPEN_SLOT=0` keeps an open class's constructor properties on the
/// by-name read.
fn openSlotLinkEnabled() bool {
    return !std.mem.eql(u8, runtime.envOnce("KLIO_OPEN_SLOT") orelse "1", "0");
}

/// A declared slot of an OPEN class, which lowering refuses because a subclass
/// might answer the property differently. A declared slot's index is the same
/// in every subclass, so what a subclass can change is whether the slot is the
/// answer — and that is exactly "does any subclass redeclare the property",
/// which only link time can ask. Constructor properties only: a body property
/// of an open base is written by that base's initializer, partway through a
/// subclass's construction, so a read through a subclass can land on the seed.
fn openClassSlot(
    self: *const Module,
    cid: ClassId,
    name: []const u8,
    buf: []u8,
) ?u32 {
    if (cid.int() >= self.classes.items.len) return null;
    const c = &self.classes.items[cid.int()];
    if (!c.is_open and !c.is_abstract and !c.is_interface) return null;
    if (c.name.len == 0) return null;
    const entry = classFieldLayout(self, cid) orelse return null;
    const idx = fieldSlotIndex(self, cid, name) orelse return null;
    if (idx >= entry.declared) return null;
    const slot = entry.slots[idx];
    if (!slot.plain or !slot.ctor) return null;
    for (entry.slots) |sl| {
        if (std.mem.startsWith(u8, sl.name, "__delegate__")) return null;
    }
    var cells: usize = 0;
    for (entry.slots[0..entry.declared]) |sl| {
        if (std.mem.eql(u8, propNameOfSlotKey(sl.name), name)) cells += 1;
    }
    if (cells != 1) return null;
    const key = std.fmt.bufPrint(buf, "{s}\u{1f}{s}", .{ c.name, name }) catch return null;
    if (self.registry.subclass_declares_prop.contains(key)) return null;
    return idx;
}

/// Whether any subclass of `owner` declares a member called `name`.
///
/// Whole-program knowledge: the build records one entry per (ancestor simple
/// name, member name) pair a subclass declares, so a name no subclass touches
/// is answered by the owner's own cell whatever the runtime class turns out
/// to be. Over-reports rather than under — a method of the same name counts —
/// which is the direction that refuses rather than claims.
pub fn subclassDeclaresProp(self: *const Module, owner: []const u8, name: []const u8) bool {
    var buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{s}\u{1f}{s}", .{ owner, name }) catch return true;
    return self.registry.subclass_declares_prop.contains(key);
}

/// The accessor that answers `name` on `cid` or one of its supertypes.
///
/// Two contracts, both written by the class builder: `__get_<Class>_<prop>`
/// for a body property's getter, and `__ext_get_<Head>_<prop>` for an
/// extension property's — and the second is the common one here, because a
/// read the layout cannot answer is far more often `Int.dp` than a class's own
/// accessor. Only a name exactly one function carries: a same-simple-name
/// class elsewhere would otherwise lend its getter.
/// Why `getterFor` found no accessor. `accessor_or_method` is the largest
/// remaining reason a field read cannot claim a slot, and the getter route
/// is what should answer those, so which of its guards turns them away is
/// the next thing to know.
pub const GetterReject = enum(u8) { value_class, plainly_stores, subclass_declares, chain_end, hops };
pub var getter_rejects: [@typeInfo(GetterReject).@"enum".fields.len]usize = @splat(0);

fn getterReject(r: GetterReject) ?FuncId {
    getter_rejects[@intFromEnum(r)] += 1;
    return null;
}

pub fn getterRejectDump() void {
    if (runtime.envOnce("KLIO_GETTER_WHY") == null) return;
    inline for (@typeInfo(GetterReject).@"enum".fields) |f| {
        if (getter_rejects[f.value] != 0)
            std.debug.print("[getter-why] {d:>8}  {s}\n", .{ getter_rejects[f.value], f.name });
    }
}

fn getterFor(self: *const Module, cid: ClassId, name: []const u8, buf: []u8) ?FuncId {
    // The claim proves only that the receiver is SOMEWHERE on `cid`'s chain.
    // When `cid` is final that is the whole answer — no class can sit below it
    // to redeclare the property — and the walk's nearest-first order is
    // Kotlin's own.
    const recv_final = blk: {
        if (cid.int() >= self.classes.items.len) break :blk false;
        const rc = &self.classes.items[cid.int()];
        break :blk !rc.is_open and !rc.is_abstract and !rc.is_interface;
    };
    var cur = cid;
    var hops: usize = 0;
    while (hops < 32) : (hops += 1) {
        if (cur.int() >= self.classes.items.len) return null;
        const c = &self.classes.items[cur.int()];
        // A value class's accessor takes the UNDERLYING value as its receiver,
        // not the box the read holds, so naming it hands the getter a
        // receiver of the wrong shape and it decodes garbage.
        if (c.is_value) return getterReject(.value_class);
        // The runtime's rule, and the reason naming an ancestor's accessor is
        // not enough: the nearest declaration answers, so a class that STORES
        // the property plainly ends the walk with a cell rather than a call.
        if (plainlyStores(c, name)) return getterReject(.plainly_stores);
        if (c.name.len != 0) {
            // A private accessor is the language's answer for a read the
            // declaring class's own body makes: no subclass can redeclare a
            // private property, and a same-named private one below is a
            // different declaration.
            if (hops == 0) {
                if (uniqueFuncNamed(self, buf, "__get_{s}_{s}", c.name, name)) |fid| {
                    if (self.decl_sigs.get(fid.int())) |sig| {
                        if (sig.visibility == .Private) return fid;
                    }
                }
            }
            // A strict subclass redeclaring the property can answer it its own
            // way, and the read's proven receiver is only known to be SOMEWHERE
            // on this chain: `Rgb` stores `isSrgb` where its base declares
            // `get() = false`, and the base's accessor served that false.
            if (!recv_final) {
                const sub_key = std.fmt.bufPrint(buf, "{s}\u{1f}{s}", .{ c.name, name }) catch return null;
                if (self.registry.subclass_declares_prop.contains(sub_key)) return getterReject(.subclass_declares);
            }
            if (uniqueFuncNamed(self, buf, "__get_{s}_{s}", c.name, name)) |fid| return fid;
            if (uniqueFuncNamed(self, buf, "__ext_get_{s}_{s}", c.name, name)) |fid| return fid;
        }
        if (c.supertypes.len == 0) return getterReject(.chain_end);
        cur = c.supertypes[0];
    }
    return null;
}

/// Whether `c` itself holds a plain cell for the property `name`.
///
/// Its OWN slots, because the walk asks the question one class at a time and a
/// base's cell is the base's answer, not this class's. By the slot's PROPERTY
/// name rather than its key: a class that shadows or override-cells a
/// supertype's same-named property stores under an owner-mangled key, and
/// matching the key alone reported no storage for exactly the overrides that
/// make the accessor walk wrong.
fn plainlyStores(c: *const core_class.Class, name: []const u8) bool {
    if (c.field_layout.state != .ok) return false;
    for (c.field_layout.own) |slot| {
        if (!slot.plain) continue;
        if (std.mem.eql(u8, propNameOfSlotKey(slot.name), name)) return true;
    }
    return false;
}

/// Accessors are NOT in `func_name_index`: a compose program's module carries
/// 2 440 `__get_` functions and the index holds none of them, so a lookup
/// through it sees only the few that arrive by another route. The pass scans
/// the function table once instead.
fn uniqueFuncNamed(self: *const Module, buf: []u8, comptime fmt: []const u8, owner: []const u8, name: []const u8) ?FuncId {
    const key = std.fmt.bufPrint(buf, fmt, .{ owner, name }) catch return null;
    var found: ?FuncId = null;
    // Through the name index: the link runs this once per read, and a scan
    // of the function table per read is the bake's whole time.
    for (self.funcsBySimpleName(key)) |fid| {
        const f = self.funcById(fid) orelse continue;
        // A bodyless header identifies the accessor and cannot run it.
        if (!f.hasBody()) continue;
        // A header reserved and then placed is indexed twice under one id.
        if (found) |seen| {
            if (seen.int() == fid.int()) continue;
            return null;
        }
        found = fid;
    }
    return found;
}

/// What a `super.<prop>` access reaches: the accessor a class on the chain
/// declares, or the cell it declares when no accessor answers there.
pub const SuperAnswer = union(enum) {
    accessor: FuncId,
    cell: struct { cid: ClassId, idx: u32 },
};

pub const SuperAccess = enum { read, write };

/// The nearest class on the chain from `cid`, level order over class and
/// interfaces, that declares `name`; what it declares decides.
///
/// NOT `getterFor`: that walk refuses a non-final class whose subclass
/// redeclares the property, because a virtual read only knows its receiver
/// is somewhere on the chain. `super` is the opposite. The language pins the
/// base's declaration and an override is exactly what it must not reach, so
/// the override that makes `getterFor` decline is the reason this exists.
fn nearestSuperMember(self: *const Module, cid: ClassId, name: []const u8, access: SuperAccess, buf: []u8) ?SuperAnswer {
    var level: [32]ClassId = undefined;
    var next: [32]ClassId = undefined;
    var n: usize = 1;
    level[0] = cid;
    var depth: usize = 0;
    while (depth < 16 and n != 0) : (depth += 1) {
        var n_next: usize = 0;
        for (level[0..n]) |c_id| {
            if (c_id.int() >= self.classes.items.len) continue;
            const c = &self.classes.items[c_id.int()];
            const acc = switch (access) {
                .read => declaredGetterOn(self, c_id, name, buf),
                .write => declaredSetterOn(self, c_id, name, buf),
            };
            if (acc) |fid| {
                // A declaration without a body names the property without
                // answering it, and Kotlin allows no `super` access to that.
                const f = self.funcById(fid) orelse return null;
                return if (f.hasBody()) .{ .accessor = fid } else null;
            }
            if (declaredCellOn(self, c_id, name, access)) |idx| return .{ .cell = .{ .cid = c_id, .idx = idx } };
            for (c.supertypes) |sup| {
                if (n_next == next.len) return null;
                next[n_next] = sup;
                n_next += 1;
            }
        }
        for (next[0..n_next], 0..) |v, i| level[i] = v;
        n = n_next;
    }
    return null;
}

/// The stored cell `cid` itself declares for `name`: a slot in its own
/// declared range, under the plain or owner-mangled key, that a read or a
/// write serves whole. A declared slot's index holds in every subclass.
fn declaredCellOn(self: *const Module, cid: ClassId, name: []const u8, access: SuperAccess) ?u32 {
    const entry = classFieldLayout(self, cid) orelse return null;
    var i: usize = entry.base;
    while (i < entry.declared) : (i += 1) {
        const slot = entry.slots[i];
        if (!std.mem.eql(u8, propNameOfSlotKey(slot.name), name)) continue;
        const whole = switch (access) {
            .read => slot.plain,
            .write => slot.plain_write,
        };
        return if (whole) @intCast(i) else null;
    }
    return null;
}

/// The declaration a `super` access reaches among `candidates`: the one
/// class a qualified reference names, or the supertypes an unqualified one
/// means, the superclass before interfaces as Kotlin ranks them. Several
/// interfaces answering is not something the plain form is allowed to mean.
pub fn superMemberAmong(self: *const Module, candidates: []const ClassId, name: []const u8, access: SuperAccess, buf: []u8) ?SuperAnswer {
    var iface_hit: ?SuperAnswer = null;
    var iface_n: usize = 0;
    for (candidates) |sid| {
        if (sid.int() >= self.classes.items.len) continue;
        const a = nearestSuperMember(self, sid, name, access, buf) orelse continue;
        if (!self.classes.items[sid.int()].is_interface) return a;
        iface_hit = a;
        iface_n += 1;
    }
    return if (iface_n == 1) iface_hit else null;
}

/// The declaration a `super` access reaches from `start`: the class itself
/// when the reference named it (`super<K>`), else its supertypes.
fn superMemberAnswer(self: *const Module, start: ClassId, qualified: bool, name: []const u8, access: SuperAccess, buf: []u8) ?SuperAnswer {
    if (start.int() >= self.classes.items.len) return null;
    if (qualified) return superMemberAmong(self, &.{start}, name, access, buf);
    return superMemberAmong(self, self.classes.items[start.int()].supertypes, name, access, buf);
}

/// Settle every `super.<prop>` read and write lowering left open, now that
/// every body has lowered and every accessor exists.
///
/// The access cannot be settled where it is emitted: the accessor is created
/// when the DECLARING class's body lowers and bodies lower from a pool, so an
/// emitter would bind or not by pool order. An accessor becomes a direct call
/// on the register run the emitter reserved for it, a stored property the
/// base's cell. What stays open is left in its pending form, which fails
/// where it is reached: no by-name answer to a super access is right.
pub fn linkSuperMembers(self: *Module) void {
    var buf: [256]u8 = undefined;
    var calls: usize = 0;
    var cells: usize = 0;
    var open: usize = 0;
    const why = runtime.envOnce("KLIO_SUPER_WHY") != null;
    for (self.funcs.items) |*f| {
        for (f.blocks) |*b| {
            for (b.insts) |*inst| {
                switch (inst.*) {
                    .GetField => |gf| {
                        if (gf.own_kind != .super_target) continue;
                        const name = switch (self.consts.items[gf.field.int()]) {
                            .String => |str| str,
                            else => continue,
                        };
                        const start = gf.own_cls orelse continue;
                        const ans = superMemberAnswer(self, start, gf.own_slot == 1, name, .read, &buf) orelse {
                            open += 1;
                            if (why) std.debug.print("[super-open] read {s}.{s} qualified={} in {s}\n", .{ self.classes.items[start.int()].name, name, gf.own_slot == 1, f.name });
                            continue;
                        };
                        switch (ans) {
                            .accessor => |fid| {
                                inst.* = .{ .Call = .{
                                    .dst = gf.dst,
                                    .func = fid,
                                    .args = gf.receiver,
                                    .n_args = 1,
                                    .exact = true,
                                } };
                                calls += 1;
                            },
                            .cell => |c| {
                                inst.GetField.own_cls = c.cid;
                                inst.GetField.own_slot = c.idx;
                                inst.GetField.own_kind = .super_slot;
                                cells += 1;
                            },
                        }
                    },
                    .SetField => |sf| {
                        if (sf.own_kind != .super_target) continue;
                        const name = switch (self.consts.items[sf.field.int()]) {
                            .String => |str| str,
                            else => continue,
                        };
                        const start = sf.own_cls orelse continue;
                        const qualified = sf.own_slot & inst_mod.SUPER_WRITE_QUALIFIED != 0;
                        const ans = superMemberAnswer(self, start, qualified, name, .write, &buf) orelse {
                            open += 1;
                            if (why) std.debug.print("[super-open] write {s}.{s} qualified={} in {s}\n", .{ self.classes.items[start.int()].name, name, qualified, f.name });
                            continue;
                        };
                        switch (ans) {
                            .accessor => |fid| {
                                // The emitter placed the value right after
                                // the receiver, which is the run a call reads.
                                if (sf.value.int() != sf.receiver.int() + 1) {
                                    open += 1;
                                    continue;
                                }
                                inst.* = .{ .Call = .{
                                    .dst = core_ids.Reg.from(sf.own_slot & ~inst_mod.SUPER_WRITE_QUALIFIED),
                                    .func = fid,
                                    .args = sf.receiver,
                                    .n_args = 2,
                                    .exact = true,
                                } };
                                calls += 1;
                            },
                            .cell => |c| {
                                inst.SetField.own_cls = c.cid;
                                inst.SetField.own_slot = c.idx;
                                inst.SetField.own_kind = .super_slot;
                                cells += 1;
                            },
                        }
                    },
                    else => {},
                }
            }
        }
    }
    if (why or runtime.envOnce("KLIO_GETTER_PROBE") != null)
        std.debug.print("[super-link] calls={d} cells={d} open={d}\n", .{ calls, cells, open });
}

/// The accessor `cid` itself declares for `name`, member or extension form.
/// No chain walk: the caller has already chosen the class, which is what
/// `super.<prop>` does by naming the supertype.
pub fn declaredGetterOn(self: *const Module, cid: ClassId, name: []const u8, buf: []u8) ?FuncId {
    if (cid.int() >= self.classes.items.len) return null;
    const c = &self.classes.items[cid.int()];
    if (c.name.len == 0 or c.is_value) return null;
    if (uniqueFuncNamed(self, buf, "__get_{s}_{s}", c.name, name)) |fid| return fid;
    return uniqueFuncNamed(self, buf, "__ext_get_{s}_{s}", c.name, name);
}

/// The setter `cid` itself declares for `name`, member or extension form.
pub fn declaredSetterOn(self: *const Module, cid: ClassId, name: []const u8, buf: []u8) ?FuncId {
    if (cid.int() >= self.classes.items.len) return null;
    const c = &self.classes.items[cid.int()];
    if (c.name.len == 0 or c.is_value) return null;
    if (uniqueFuncNamed(self, buf, "__set_{s}_{s}", c.name, name)) |fid| return fid;
    return uniqueFuncNamed(self, buf, "__ext_set_{s}_{s}", c.name, name);
}

/// Compose every class's layout from scratch.
pub fn linkFieldSlots(self: *Module, allocator: Allocator) Allocator.Error!void {
    self.field_layout.clearRetainingCapacity();
    return linkFieldSlotsFrom(self, allocator, 0);
}

/// Composes the classes from `first_class` on, leaving the entries already in
/// `field_layout` alone.
///
/// A program extending a baked base inherits that base's layout table with the
/// image, and its own declarations only ever ADD classes: the layout of a class
/// is a function of its own declaration and its superclass chain, and nothing a
/// program declares reaches into a base class's chain. Re-composing every base
/// class to append a few user ones walked the whole class table.
///
/// The one way a program does touch a base class is `addClass` claiming an
/// existing slot when the FQN matches exactly, which overwrites the `ir.Class`
/// and resets its layout to `unpublished`. Composing a subclass onto the stale
/// table entry that class left behind would be silent corruption, so the caller
/// checks for that and relinks from zero instead.
pub fn linkFieldSlotsFrom(self: *Module, allocator: Allocator, first_class: usize) Allocator.Error!void {
    const n = self.classes.items.len;
    while (self.field_layout.items.len < n) try self.field_layout.append(allocator, .{});
    if (first_class >= n) return;
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const state = try scratch.allocator().alloc(u8, n);
    @memset(state, 0);
    // Entries the base image brought are final; a super below the mark is read,
    // never recomposed.
    @memset(state[0..@min(first_class, n)], 2);
    var i = first_class;
    while (i < n) : (i += 1) try linkFieldClass(self, allocator, state, ClassId.from(@intCast(i)));
}

/// Whether any class below `first_class` lost its published layout, which means
/// a declaration in this build claimed a base class's slot.
pub fn baseFieldLayoutsStale(self: *const Module, first_class: usize) bool {
    const upto = @min(first_class, self.classes.items.len);
    for (self.classes.items[0..upto]) |*c| {
        if (c.field_layout.state == .unpublished) return true;
    }
    return false;
}

fn linkFieldClass(self: *Module, a: Allocator, state: []u8, cid: ClassId) Allocator.Error!void {
    const i = cid.int();
    if (i >= state.len) return;
    // 1 marks a class the walk is inside, which a supertype edge back to it must
    // not follow; 2 marks one already composed.
    if (state[i] != 0) return;
    state[i] = 1;
    defer state[i] = 2;

    const out = &self.field_layout.items[i];
    const own_layout = self.classes.items[i].field_layout;
    switch (own_layout.state) {
        .unpublished, .unavailable => {
            out.* = .{ .state = .unavailable };
            return;
        },
        .interface, .anonymous, .local_runtime => {
            out.* = .{ .state = own_layout.state };
            return;
        },
        .ok => {},
    }

    // The chain leaf-first, which also bounds the depth before anything is built.
    var chain: [max_depth]ClassId = undefined;
    var depth: usize = 0;
    var cur: ?ClassId = cid;
    while (cur) |c| {
        if (c.int() >= self.classes.items.len or depth == max_depth) {
            out.* = .{ .state = .unavailable };
            return;
        }
        chain[depth] = c;
        depth += 1;
        cur = self.classes.items[c.int()].field_layout.super;
    }

    var base_slots: []const FieldSlot = &.{};
    if (own_layout.super) |sid| {
        if (state[sid.int()] == 1) {
            out.* = .{ .state = .unavailable };
            return;
        }
        try linkFieldClass(self, a, state, sid);
        const super_entry = self.field_layout.items[sid.int()];
        switch (super_entry.state) {
            .ok => base_slots = super_entry.slots[0..super_entry.declared],
            .interface, .anonymous, .local_runtime => {
                out.* = .{ .state = super_entry.state };
                return;
            },
            .unpublished, .unavailable => {
                out.* = .{ .state = .unavailable };
                return;
            },
        }
    }

    var slots: std.ArrayList(FieldSlot) = .empty;
    errdefer slots.deinit(a);
    try slots.ensureTotalCapacity(a, base_slots.len + own_layout.own.len);
    slots.appendSliceAssumeCapacity(base_slots);
    slots.appendSliceAssumeCapacity(own_layout.own);
    const declared: u32 = @intCast(slots.items.len);

    // Captures land after every declared slot in the chain, base classes first,
    // and only where no class in the chain claimed the name.
    var level = depth;
    while (level > 0) {
        level -= 1;
        const candidates = self.classes.items[chain[level].int()].field_layout.captures;
        next: for (candidates) |name| {
            for (slots.items) |slot| {
                if (std.mem.eql(u8, slot.name, name)) continue :next;
            }
            try slots.append(a, .{ .name = name });
        }
    }

    self.classes.items[i].field_layout.base = @intCast(base_slots.len);
    out.* = .{
        .slots = try slots.toOwnedSlice(a),
        .declared = declared,
        .base = @intCast(base_slots.len),
        .state = .ok,
    };
}

const testing = std.testing;

/// `Module.deinit` leaves class-owned slices to whatever arena the build used;
/// a test on the testing allocator returns the composed ones itself.
fn freeLinked(m: *Module, a: Allocator) void {
    for (m.field_layout.items) |entry| {
        if (entry.slots.len != 0) a.free(entry.slots);
    }
}

fn testClass(m: *Module, a: Allocator, name: []const u8, layout: core_class.FieldLayout) Allocator.Error!ClassId {
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
        .field_layout = layout,
    });
    return id;
}

test "a subclass layout starts with its superclass's declared slots" {
    const a = testing.allocator;
    var m = Module.init(a);
    defer m.deinit(a);
    defer freeLinked(&m, a);
    const base = try testClass(&m, a, "Base", .{
        .own = &.{ .{ .name = "a", .seed = .int }, .{ .name = "fromBase" } },
        .state = .ok,
    });
    const derived = try testClass(&m, a, "Derived", .{
        .own = &.{ .{ .name = "b", .seed = .int }, .{ .name = "own" } },
        .super = base,
        .state = .ok,
    });
    try linkFieldSlots(&m, a);

    const bl = classFieldLayout(&m, base).?;
    try testing.expectEqual(@as(usize, 2), bl.slots.len);
    try testing.expectEqual(@as(u32, 0), bl.base);
    const dl = classFieldLayout(&m, derived).?;
    try testing.expectEqual(@as(usize, 4), dl.slots.len);
    try testing.expectEqual(@as(u32, 2), dl.base);
    try testing.expectEqual(@as(u32, 4), dl.declared);
    // A declared slot keeps its index through the subclass.
    try testing.expectEqual(@as(u32, 0), fieldSlotIndex(&m, base, "a").?);
    try testing.expectEqual(@as(u32, 0), fieldSlotIndex(&m, derived, "a").?);
    try testing.expectEqual(core_class.SlotSeed.int, dl.slots[0].seed);
    try testing.expectEqual(@as(u32, 2), m.classes.items[derived.int()].field_layout.base);
}

test "a capture follows every declared slot and drops when the chain claims its name" {
    const a = testing.allocator;
    var m = Module.init(a);
    defer m.deinit(a);
    defer freeLinked(&m, a);
    const base = try testClass(&m, a, "Base", .{
        .own = &.{.{ .name = "kept" }},
        .captures = &.{ "hidden", "seen" },
        .state = .ok,
    });
    const derived = try testClass(&m, a, "Derived", .{
        .own = &.{.{ .name = "hidden" }},
        .super = base,
        .state = .ok,
    });
    try linkFieldSlots(&m, a);

    // The base alone keeps both captures, after its declared slot.
    const bl = classFieldLayout(&m, base).?;
    try testing.expectEqual(@as(u32, 1), bl.declared);
    try testing.expectEqualStrings("hidden", bl.slots[1].name);
    try testing.expectEqualStrings("seen", bl.slots[2].name);
    // The subclass declares `hidden`, so the base's parameter keeps no field.
    const dl = classFieldLayout(&m, derived).?;
    try testing.expectEqual(@as(u32, 2), dl.declared);
    try testing.expectEqual(@as(usize, 3), dl.slots.len);
    try testing.expectEqualStrings("seen", dl.slots[2].name);
}

test "a class with no layout passes its reason down the chain" {
    const a = testing.allocator;
    var m = Module.init(a);
    defer m.deinit(a);
    defer freeLinked(&m, a);
    const local = try testClass(&m, a, "Local", .{ .state = .local_runtime });
    const sub = try testClass(&m, a, "Sub", .{
        .own = &.{.{ .name = "x" }},
        .super = local,
        .state = .ok,
    });
    const undescribed = try testClass(&m, a, "Undescribed", .{ .state = .unavailable });
    try linkFieldSlots(&m, a);

    try testing.expect(classFieldLayout(&m, local) == null);
    try testing.expect(classFieldLayout(&m, sub) == null);
    try testing.expectEqual(FieldLayoutState.local_runtime, classFieldLayoutState(&m, sub).?);
    try testing.expectEqual(FieldLayoutState.unavailable, classFieldLayoutState(&m, undescribed).?);
}

test "a class table slot a later build claims reads as stale" {
    const a = testing.allocator;
    var m = Module.init(a);
    defer m.deinit(a);
    defer freeLinked(&m, a);
    _ = try testClass(&m, a, "Base", .{ .own = &.{.{ .name = "a" }}, .state = .ok });
    try linkFieldSlots(&m, a);
    try testing.expect(!baseFieldLayoutsStale(&m, 1));
    // `addClass` overwriting the slot resets the class's layout.
    m.classes.items[0].field_layout = .{};
    try testing.expect(baseFieldLayoutsStale(&m, 1));
}
