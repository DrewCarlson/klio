//! Host slot operations: the by-name slot fallbacks, the free-member answers the
//! builtin surface serves, and the type-safe dispatch barriers.

const std = @import("std");
const ir = @import("ir");
const runtime = @import("runtime");
const vmhost = @import("../vmhost.zig");
const VmHost = vmhost.VmHost;
const builtin_members = @import("../builtin_members.zig");
const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const Module = ir.Module;
const FuncId = ir.FuncId;
const MethodSlotId = ir.MethodSlotId;
const EvalResult = ir.eval.EvalResult;
const builtinIterator = builtin_members.builtinIterator;
const comparatorMember = builtin_members.comparatorMember;
const iteratorMember = builtin_members.iteratorMember;
const rangeIterMember = builtin_members.rangeIterMember;
const seqIterMember = builtin_members.seqIterMember;
const sequenceMember = builtin_members.sequenceMember;

const hcm = @import("../host_call_member.zig");
const boolVal = hcm.boolVal;
const cacheGen = hcm.cacheGen;
const simpleName = hcm.simpleName;
const throwExc = hcm.throwExc;

const receiver_probe = @import("receiver_probe.zig");
const receiverImplementsType = receiver_probe.receiverImplementsType;

const reflect_anon = @import("reflect_anon.zig");
const isIteratorNext = reflect_anon.isIteratorNext;

/// `KLIO_NOINST_TRACE=1`: report each virtual slot resolved against the runtime
/// class of a host-backed (non-`Instance`) receiver. Resolved once — this sits
/// on the member-dispatch path, where the env cache's mutex would show up.
/// Counts every time a STATICALLY BOUND virtual slot call degrades to a
/// by-name member walk. `execArmCallVirtual` documents that arm as having no
/// name-based fallback — "a missing slot is a link error in the program
/// image" — and this host has one. Both cannot be true, and a bytecode VM or
/// a C backend needs the unlinked slot to be a build error rather than a
/// walk. Counting it is the prerequisite for making that so.
pub var slot_by_name_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

pub fn slotByNameFallbacks() u64 {
    return slot_by_name_count.load(.monotonic);
}

/// A builtin member whose implementation is a host function reached by
/// RECEIVER VARIANT rather than by FQN, so `linkBodyless` finds no native for
/// it and a statically bound slot call declines to a member-name walk
/// (`KLIO_NOINST_WHY` reports `target-not-executable`). Binding the target
/// `FuncId` to the handler settles the call by id instead.
///
/// The FQN comparison happens ONCE per `FuncId` per thread; every later call
/// on that slot is an integer probe. The handlers are the existing ones — a
/// second implementation here is exactly the duplication this avoids.
pub const HostSlotOp = enum {
    iterator_protocol,
    collection_iterator,
    kclass_is_instance,
    comparator_member,
    array_get,
    sequence_iterator,
};

pub threadlocal var host_slot_ops: ?std.AutoHashMapUnmanaged(u32, ?HostSlotOp) = null;
pub threadlocal var host_slot_ops_gen: u32 = 0;

pub fn hostSlotOpFor(module: *const Module, target: FuncId) ?HostSlotOp {
    if (host_slot_ops == null) host_slot_ops = .{};
    // Keyed by a bare function id, which the next program mints again for a
    // different function: drop the whole map when the generation moves.
    if (host_slot_ops_gen != cacheGen()) {
        host_slot_ops.?.clearRetainingCapacity();
        host_slot_ops_gen = cacheGen();
    }
    const map = &host_slot_ops.?;
    if (map.get(target.int())) |cached| return cached;
    const fqn = if (module.funcById(target)) |f| f.fqn else return null;
    const op: ?HostSlotOp = hostSlotOpOfFqn(fqn);
    map.put(std.heap.page_allocator, target.int(), op) catch return op;
    return op;
}

/// The same classification off the declaration's name alone, so a consumer
/// that holds the declaration rather than a live module (the native backend,
/// deciding at compile time which member calls the runtime serves) reads the
/// one table instead of keeping a second.
pub fn hostSlotOpOfFqn(fqn: []const u8) ?HostSlotOp {
    return blk: {
        const owner = fqn[0 .. std.mem.lastIndexOfScalar(u8, fqn, '.') orelse break :blk null];
        const name = fqn[owner.len + 1 ..];
        const iter_owner = std.mem.eql(u8, owner, "kotlin.collections.Iterator") or
            std.mem.eql(u8, owner, "kotlin.collections.MutableIterator") or
            std.mem.eql(u8, owner, "kotlin.collections.ListIterator") or
            std.mem.eql(u8, owner, "kotlin.collections.MutableListIterator") or
            // The primitive-iterator abstract classes: their `next()` source
            // body delegates to `nextInt()`-family members the host serves
            // through the same protocol handler.
            (std.mem.startsWith(u8, owner, "kotlin.collections.") and
                std.mem.endsWith(u8, owner, "Iterator"));
        if (iter_owner and (isIteratorProtocol(name) or isIteratorNext(name)))
            break :blk .iterator_protocol;
        // `iterator()` on a collection: the host builds the iterator from the
        // receiver's own representation, and no native is registered under
        // the interface's FQN either.
        if (std.mem.eql(u8, name, "iterator") and
            (std.mem.eql(u8, owner, "kotlin.collections.Iterable") or
                std.mem.eql(u8, owner, "kotlin.collections.MutableIterable") or
                std.mem.eql(u8, owner, "kotlin.collections.Collection") or
                std.mem.eql(u8, owner, "kotlin.collections.MutableCollection") or
                std.mem.eql(u8, owner, "kotlin.collections.List") or
                std.mem.eql(u8, owner, "kotlin.collections.MutableList") or
                std.mem.eql(u8, owner, "kotlin.collections.Set") or
                std.mem.eql(u8, owner, "kotlin.collections.MutableSet") or
                std.mem.eql(u8, owner, "kotlin.collections.ArrayList") or
                std.mem.eql(u8, owner, "kotlin.collections.HashSet") or
                std.mem.eql(u8, owner, "kotlin.collections.LinkedHashSet")))
            break :blk .collection_iterator;
        // The remaining interface members the host serves from the value's
        // own representation, measured off the noinst-why decline tally:
        // KClass.isInstance, Comparator.compare, indexed array get, and a
        // Sequence's lazy iterator.
        if (std.mem.eql(u8, owner, "kotlin.reflect.KClass") and
            std.mem.eql(u8, name, "isInstance")) break :blk .kclass_is_instance;
        if (std.mem.eql(u8, owner, "kotlin.Comparator") and
            std.mem.eql(u8, name, "compare")) break :blk .comparator_member;
        if (std.mem.eql(u8, name, "get") and
            std.mem.startsWith(u8, owner, "kotlin.") and
            std.mem.endsWith(u8, owner, "Array") and
            std.mem.indexOfScalar(u8, owner["kotlin.".len..], '.') == null)
            break :blk .array_get;
        // An array iterates from its own storage, exactly as a collection
        // does, and no native is registered under the array type either.
        if (std.mem.eql(u8, name, "iterator") and
            std.mem.startsWith(u8, owner, "kotlin.") and
            std.mem.endsWith(u8, owner, "Array") and
            std.mem.indexOfScalar(u8, owner["kotlin.".len..], '.') == null)
            break :blk .collection_iterator;
        if (std.mem.eql(u8, owner, "kotlin.sequences.Sequence") and
            std.mem.eql(u8, name, "iterator")) break :blk .sequence_iterator;
        break :blk null;
    };
}

/// The builtin members a caller with no module can serve, selected by the
/// receiver's own representation and the member's NAME: the iteration protocol
/// and the collection `iterator()`. `callMemberInner` reaches the same handlers
/// on the same receivers, so there is one implementation of each.
pub fn hostFreeMemberByName(allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    if (std.mem.eql(u8, name, "iterator") and args.len == 0) {
        // The self-iterator convention first, then the builtin collection or
        // range iterator.
        switch (receiver.*) {
            .Iterator, .RangeIter, .SeqIter => return .{ .ok = receiver.* },
            else => {},
        }
        if (try builtinIterator(allocator, receiver)) |r| return r;
    }
    if (receiver.* == .Iterator) {
        if (try iteratorMember(allocator, receiver, name, args)) |r| return r;
    }
    if (receiver.* == .RangeIter) {
        if (try rangeIterMember(allocator, receiver, name, args)) |r| return r;
    }
    return null;
}

/// What such a member answers, as a KIND rather than a runtime type: a caller
/// that has to choose a machine type for the result reads the protocol from
/// where it is implemented instead of keeping a second copy of it.
pub const HostFreeAnswer = enum {
    /// An iterator over the receiver.
    iterator,
    /// Whether the iteration can step again.
    boolean,
    /// One element of what is being iterated.
    element,
    /// A position within the iteration.
    index,
    /// Nothing: the member is performed for its effect.
    unit,
};

pub fn hostFreeMemberAnswer(name: []const u8) ?HostFreeAnswer {
    if (std.mem.eql(u8, name, "iterator")) return .iterator;
    if (std.mem.eql(u8, name, "hasNext") or std.mem.eql(u8, name, "hasPrevious")) return .boolean;
    if (std.mem.eql(u8, name, "nextIndex") or std.mem.eql(u8, name, "previousIndex")) return .index;
    if (std.mem.eql(u8, name, "remove")) return .unit;
    if (isIteratorNext(name) or std.mem.eql(u8, name, "previous")) return .element;
    return null;
}

/// The host slot ops whose handlers read only the receiver's own
/// representation, so they answer with no interpreter host behind them. A
/// compiled program has no module to dispatch through and serves its builtin
/// member calls from here; the interpreter reaches the same bodies through
/// `runHostSlotOp`, so there is one implementation rather than two.
pub fn runHostFreeSlotOp(allocator: Allocator, op: HostSlotOp, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    switch (op) {
        .iterator_protocol, .collection_iterator => return hostFreeMemberByName(allocator, receiver, name, args),
        .array_get => {
            if (receiver.* != .Array or args.len != 1) return null;
            const idx = args[0].asI64() orelse return null;
            const arr = receiver.Array;
            const n = arr.len();
            if (idx >= 0 and @as(usize, @intCast(idx)) < n) {
                const elem = arr.get(@intCast(idx));
                elem.retain();
                return .{ .ok = elem };
            }
            const msg = try std.fmt.allocPrint(allocator, "Index {d} out of bounds for length {d}", .{ idx, n });
            defer if (runtime.freeScratch()) allocator.free(msg);
            return .{ .err = try throwExc(allocator, "kotlin.ArrayIndexOutOfBoundsException", msg) };
        },
        else => return null,
    }
}

pub fn runHostSlotOp(self: *VmHost, allocator: Allocator, op: HostSlotOp, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    if (try runHostFreeSlotOp(allocator, op, receiver, name, args)) |r| return r;
    switch (op) {
        .iterator_protocol => switch (receiver.*) {
            .SeqIter => return seqIterMember(self, allocator, receiver, name, args),
            else => return null,
        },
        .kclass_is_instance => {
            if (receiver.* != .Class or args.len != 1) return null;
            const cg = receiver.Class.borrow();
            const cname = cg.get().name;
            var hit = args[0].isRuntimeType(cname);
            if (!hit and args[0] == .Instance) hit = receiverImplementsType(self, &args[0], cname);
            const r = boolVal(hit);
            cg.deinit();
            return .{ .ok = r };
        },
        .comparator_member => switch (receiver.*) {
            .Comparator => return comparatorMember(self, allocator, receiver, name, args),
            else => return null,
        },
        .sequence_iterator => switch (receiver.*) {
            .Sequence => return sequenceMember(self, allocator, receiver, name, args),
            else => return null,
        },
        .collection_iterator, .array_get => return null,
    }
}

/// Names the builtin iterator variants own outright.
pub fn isIteratorProtocol(name: []const u8) bool {
    return std.mem.eql(u8, name, "hasNext") or std.mem.eql(u8, name, "next") or
        std.mem.eql(u8, name, "hasPrevious") or std.mem.eql(u8, name, "previous") or
        std.mem.eql(u8, name, "nextIndex") or std.mem.eql(u8, name, "previousIndex");
}

pub fn noteSlotByName2(self: *VmHost, slot: MethodSlotId, name: []const u8, receiver: *const Value) void {
    _ = slot_by_name_count.fetchAdd(1, .monotonic);
    if (!runtime.envSetOnce("KLIO_SLOT_BYNAME")) return;
    if (runtime.envOnce("KLIO_SLOT_RECV") != null) {
        std.debug.print("[slot-recv] {s} recv_ty={s}\n", .{ name, receiver.typeFqn() });
        return;
    }
    const mg = self.module.borrow();
    defer mg.deinit();
    const root = FuncId.from(slot.int());
    std.debug.print("[slot-byname] {s} root={s}\n", .{
        name,
        if (mg.get().funcById(root)) |f| f.fqn else "?",
    });
}

/// A value that IS its own representation — no host wrapper for the by-name
/// walk to unpack on the way in.
pub fn isScalarValue(v: *const Value) bool {
    return switch (v.*) {
        .Int, .Long, .Short, .Byte, .UInt, .ULong, .UShort, .UByte, .Double, .Float, .Bool, .Char => true,
        else => false,
    };
}


pub fn noinstTraceOn() bool {
    const S = struct {
        var known: ?bool = null;
    };
    if (S.known) |k| return k;
    const k = runtime.envSetOnce("KLIO_NOINST_TRACE");
    S.known = k;
    return k;
}

/// Invoke a statically resolved virtual family by numeric slot. The runtime
/// receiver contributes its exact class identity; named and runtime-defined
/// classes both resolve to an O(1) `(class, slot)` target.
/// kotlinc's type-safe collection bridges, by member name. A generic
/// collection member called through an erased signature (`indexOf(Object)`)
/// checks the argument against the class type parameter's bound and answers
/// a fixed default for a foreign value instead of running the body against a
/// representation the value does not have. The member set and defaults are
/// kotlinc's BuiltinSpecialBridges.
pub const BarrierKind = enum { bool_false, int_neg1, null_or_false, second_arg };

pub fn barrierSpec(name: []const u8) ?BarrierKind {
    const eql = std.mem.eql;
    if (eql(u8, name, "contains") or eql(u8, name, "containsKey") or
        eql(u8, name, "containsValue")) return .bool_false;
    if (eql(u8, name, "indexOf") or eql(u8, name, "lastIndexOf")) return .int_neg1;
    if (eql(u8, name, "get") or eql(u8, name, "remove")) return .null_or_false;
    if (eql(u8, name, "getOrDefault")) return .second_arg;
    return null;
}

/// The bridge's answer when the first argument fails the class type
/// parameter's erased-bound check, or null when the bridge admits the call
/// (no tp-typed param, no bound, or the value passes `is Bound`).
pub fn typeSafeBarrierAnswer(
    self: *VmHost,
    module: *const ir.Module,
    target: FuncId,
    kind: BarrierKind,
    args: []const Value,
) ?Value {
    const btr = runtime.envOnce("KLIO_BARRIER_TRACE") != null;
    if (args.len == 0) return null;
    const f = module.funcById(target) orelse return null;
    const sig = module.decl_sigs.get(target.int()) orelse return null;
    if (!sig.has_body) return null;
    const owner = sig.enclosing_class orelse {
        if (btr) std.debug.print("[barrier] {s}: no owner\n", .{f.name});
        return null;
    };
    if (owner.int() >= module.classes.items.len) return null;
    const cls = &module.classes.items[owner.int()];
    const has_this = f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this");
    const pi: usize = @intFromBool(has_this);
    if (pi >= f.params.len) return null;
    const pty_name = f.params[pi].ty.name;
    var tp_name: []const u8 = undefined;
    if (ir.parseClassTypeParamIdentity(pty_name)) |identity| {
        if (identity.owner.int() != owner.int()) {
            if (btr) std.debug.print("[barrier] {s}: mangle owner {d} != {d}\n", .{ f.name, identity.owner.int(), owner.int() });
            return null;
        }
        tp_name = identity.param;
    } else {
        var declared = false;
        for (cls.type_params) |tp| {
            if (std.mem.eql(u8, tp, pty_name)) {
                declared = true;
                break;
            }
        }
        if (!declared) {
            if (btr) std.debug.print("[barrier] {s}: param ty {s} not a tp of {s} (n={d})\n", .{ f.name, pty_name, cls.name, cls.type_params.len });
            return null;
        }
        tp_name = pty_name;
    }
    const bounds = module.registry.class_type_param_bounds.get(cls.fqn) orelse {
        if (btr) std.debug.print("[barrier] {s}: no bounds for {s}\n", .{ f.name, cls.fqn });
        return null;
    };
    var bound_head: ?[]const u8 = null;
    for (bounds) |bd| {
        if (std.mem.eql(u8, bd.param, tp_name)) {
            var h = std.mem.trimEnd(u8, bd.bound, "?");
            if (std.mem.indexOfScalar(u8, h, '<')) |lt| h = h[0..lt];
            bound_head = h;
            break;
        }
    }
    // Bounds may be recorded fqn-qualified; the instance check and the
    // Any-universal test both speak simple heads.
    const bh_raw = bound_head orelse return null;
    const bh = simpleName(bh_raw);
    if (bh.len == 0 or std.mem.eql(u8, bh, "Any")) return null;
    // A bound that is itself a type parameter proves nothing about values.
    if (bh.len <= 2 or ir.parseClassTypeParamIdentity(bh) != null) return null;
    if (self.instanceOf(&args[0], .{ .name = bh, .nullable = false, .args = &.{} })) return null;
    if (btr) std.debug.print("[barrier] TRIP {s} on {s}: arg={s} !is {s}\n", .{ f.name, cls.fqn, args[0].typeFqn(), bh });
    return switch (kind) {
        .bool_false => .{ .Bool = false },
        .int_neg1 => .{ .Int = -1 },
        .null_or_false => if (std.mem.eql(u8, f.return_ty.name, "Boolean"))
            .{ .Bool = false }
        else
            .Null,
        .second_arg => if (args.len > 1) args[1] else .Null,
    };
}

/// Claim and fill a CallVirtual host-receiver site memo (single-fill; the
/// tagged `site_native` release store is the validity gate, so a concurrent
/// replayer either sees the whole memo or takes the slow path). `name` must
/// be module-owned so its pointer outlives every replay. Verdict encoding:
/// low bits 00 = a direct StdlibFn pointer, tag 3 = (op << 2) with 0xFF
/// meaning "no host op, member-name walk only".
pub fn stampVirtSite(site: ?ir.VirtNativeSite, receiver: *const Value, encoded: u64, name: []const u8) void {
    const st = site orelse return;
    if (encoded == 0 or (encoded & 3 != 0 and encoded & 3 != 3)) return;
    const key: u64 = @intFromPtr(receiver.typeFqn().ptr);
    if (key == 0) return;
    if (@cmpxchgStrong(u64, st.cls, 0, key, .acq_rel, .monotonic) != null) return;
    st.name_ptr.* = @intFromPtr(name.ptr);
    st.name_len.* = @intCast(name.len);
    @atomicStore(u64, st.native, encoded, .release);
}


/// The simple name of the class or interface declaring a virtual slot's
/// method (`ClosedRange` for `kotlin.ranges.ClosedRange.contains`).
pub fn slotOwnerSimpleName(self: *VmHost, slot: MethodSlotId) ?[]const u8 {
    const mg = self.module.borrow();
    defer mg.deinit();
    const f = mg.get().funcById(FuncId.from(slot.int())) orelse return null;
    const fqn = f.fqn;
    const last_dot = std.mem.lastIndexOfScalar(u8, fqn, '.') orelse return null;
    const owner = fqn[0..last_dot];
    const owner_dot = std.mem.lastIndexOfScalar(u8, owner, '.');
    const simple = if (owner_dot) |d| owner[d + 1 ..] else owner;
    return if (simple.len == 0) null else simple;
}

/// The element type name of a host Range value's kind.
pub fn rangeElemTypeName(kind: runtime.RangeKind) []const u8 {
    return switch (kind) {
        .Int => "Int",
        .Long => "Long",
        .Char => "Char",
        .UInt => "UInt",
        .ULong => "ULong",
    };
}

pub fn slotNameOrNull(self: *VmHost, slot: MethodSlotId) ?[]const u8 {
    const mg = self.module.borrow();
    defer mg.deinit();
    const f = mg.get().funcById(FuncId.from(slot.int())) orelse return null;
    return f.name;
}
