//! The whole program a native build compiles: every function, class,
//! static and native reachable from `main` over the resolved instructions,
//! walked to a fixed point. A virtual call reaches the implementations of
//! its slot in every class the program constructs and in the class of
//! every host value kind, so those sets grow together.

const std = @import("std");
const ir = @import("ir");

const Allocator = std.mem.Allocator;
const FuncId = ir.FuncId;
const ClassId = ir.ClassId;
const MethodSlotId = ir.MethodSlotId;
const NativeId = ir.NativeId;
const StaticId = ir.StaticId;
const Module = ir.Module;
const Resolved = ir.Resolved;
const Bridge = ir.bridge.Bridge;

/// One closure the program makes, and over which body.
pub const ClosureSite = struct {
    body: FuncId,
    kind: enum { lambda, function_ref },
    bound: bool = false,
    n_caps: u32 = 0,
    target: FuncId = FuncId.from(ir.NO_FUNC),
};

/// A host exception name and the Kotlin class that stands for it.
pub const HostRaised = struct { key: []const u8, raised: ir.resolved.Raised };

pub const Reach = struct {
    gpa: Allocator,
    br: *Bridge,
    m: *Module,
    r: *const Resolved,
    /// Functions with a body the program runs, in discovery order.
    funcs: std.ArrayList(FuncId) = .empty,
    func_seen: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Bodyless functions the program calls: each runs its native.
    natives: std.ArrayList(NativeId) = .empty,
    native_seen: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Classes the program makes instances of: constructed, an object, or
    /// an exception the runtime raises into a `catch`.
    constructed: std.ArrayList(ClassId) = .empty,
    constructed_seen: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Slots called virtually.
    slots: std.ArrayList(MethodSlotId) = .empty,
    slot_seen: std.AutoHashMapUnmanaged(u32, void) = .empty,
    statics: std.ArrayList(StaticId) = .empty,
    static_seen: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// The init units a static or a call into a file's facade runs.
    units: std.ArrayList(u32) = .empty,
    unit_seen: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Objects and companions read by `LoadObject`.
    objects: std.ArrayList(ClassId) = .empty,
    object_seen: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Every closure the program makes.
    closure_sites: std.ArrayList(ClosureSite) = .empty,
    /// Functions a call reached that have neither a body nor a native.
    missing: std.ArrayList(FuncId) = .empty,
    /// The classes of host values: they answer a dispatch through their
    /// class's implementation like any instance.
    hosts: std.ArrayList(ClassId) = .empty,
    /// Classes a type test, cast, catch, literal or array names.
    tested: std.ArrayList(ClassId) = .empty,
    tested_seen: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Classes a `catch` names.
    caught: std.ArrayList(ClassId) = .empty,
    /// The exceptions the runtime raises that a `catch` of the program can
    /// see: the program builds them when they are raised.
    raisable: std.ArrayList(ir.resolved.Raised) = .empty,
    raisable_seen: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// The host exception names those stand for, as natives throw them.
    raisable_hosts: std.ArrayList(HostRaised) = .empty,

    pending: std.ArrayList(FuncId) = .empty,

    pub fn func(self: *const Reach, id: FuncId) ?*const ir.Func {
        return self.m.funcById(id);
    }

    /// The native `id` runs instead of a body, or null.
    pub fn nativeOf(self: *const Reach, id: FuncId) ?NativeId {
        if (id.int() >= self.r.func_native.len) return null;
        const n = self.r.func_native[id.int()];
        return if (n == .none) null else n;
    }

    /// Whether the program constructs `c` or an object of it.
    pub fn isConstructed(self: *const Reach, c: ClassId) bool {
        return self.constructed_seen.contains(c.int());
    }

    /// The implementation of `slot` in class `c`.
    pub fn target(self: *const Reach, c: ClassId, slot: MethodSlotId) ?FuncId {
        return self.m.methodSlotTarget(c, slot);
    }

    pub fn addFunc(self: *Reach, id: FuncId) Allocator.Error!void {
        if (id.int() == ir.NO_FUNC) return;
        if (self.nativeOf(id)) |n| return self.addNative(n);
        const gop = try self.func_seen.getOrPut(self.gpa, id.int());
        if (gop.found_existing) return;
        const f = self.m.funcById(id) orelse {
            try self.missing.append(self.gpa, id);
            return;
        };
        if (!f.hasBody() or !self.m.ensureFuncBody(@constCast(f))) {
            try self.missing.append(self.gpa, id);
            return;
        }
        try self.funcs.append(self.gpa, id);
        try self.pending.append(self.gpa, id);
    }

    fn addNative(self: *Reach, n: NativeId) Allocator.Error!void {
        const gop = try self.native_seen.getOrPut(self.gpa, n.int());
        if (!gop.found_existing) try self.natives.append(self.gpa, n);
    }

    fn addSlot(self: *Reach, slot: MethodSlotId) Allocator.Error!void {
        const gop = try self.slot_seen.getOrPut(self.gpa, slot.int());
        if (gop.found_existing) return;
        try self.slots.append(self.gpa, slot);
        // What a host value whose class leaves the slot open answers with.
        if (slot.int() < self.r.host_slot.len and self.r.host_slot[slot.int()] != .none) try self.addNative(self.r.host_slot[slot.int()]);
        for (self.constructed.items) |c| {
            if (self.target(c, slot)) |t| try self.addFunc(t);
        }
        for (self.hosts.items) |c| {
            if (self.target(c, slot)) |t| try self.addFunc(t);
        }
    }

    /// A host value kind's class: every dispatched slot's implementation in
    /// it is reachable.
    pub fn addHostClass(self: *Reach, c: ClassId) Allocator.Error!void {
        for (self.hosts.items) |h| if (h == c) return;
        try self.hosts.append(self.gpa, c);
        for (self.slots.items) |slot| {
            if (self.target(c, slot)) |t| try self.addFunc(t);
        }
    }

    pub fn addConstructed(self: *Reach, c: ClassId) Allocator.Error!void {
        const gop = try self.constructed_seen.getOrPut(self.gpa, c.int());
        if (gop.found_existing) return;
        try self.constructed.append(self.gpa, c);
        for (self.slots.items) |slot| {
            if (self.target(c, slot)) |t| try self.addFunc(t);
        }
        // The runtime renders, compares and hashes an instance through its
        // class's own members.
        for (self.r.well_known.values) |wk| {
            const slot = wk orelse continue;
            if (self.target(c, slot)) |t| try self.addFunc(t);
        }
    }

    /// Whether a native bound to the declaration `fqn` is reached.
    pub fn reachesNative(self: *const Reach, fqn: []const u8) bool {
        for (self.natives.items) |n| {
            if (std.mem.eql(u8, self.r.natives[n.int()].name, fqn)) return true;
        }
        return false;
    }

    fn addObject(self: *Reach, c: ClassId) Allocator.Error!void {
        const gop = try self.object_seen.getOrPut(self.gpa, c.int());
        if (gop.found_existing) return;
        try self.objects.append(self.gpa, c);
        try self.addConstructed(c);
        if (c.int() < self.r.classes.len) {
            const ctor = self.r.classes[c.int()].object_ctor;
            if (ctor != ir.NO_FUNC) try self.addFunc(FuncId.from(ctor));
        }
    }

    fn addStatic(self: *Reach, s: StaticId) Allocator.Error!void {
        const gop = try self.static_seen.getOrPut(self.gpa, s.int());
        if (gop.found_existing) return;
        try self.statics.append(self.gpa, s);
        if (s.int() >= self.r.statics.len) return;
        try self.addUnit(self.r.statics[s.int()].unit);
    }

    /// Init unit `unit`, `NONE` for none.
    pub fn addUnit(self: *Reach, unit: u32) Allocator.Error!void {
        if (unit == ir.resolved.NONE or unit >= self.r.init_units.len) return;
        const gop = try self.unit_seen.getOrPut(self.gpa, unit);
        if (gop.found_existing) return;
        try self.units.append(self.gpa, unit);
        try self.addFunc(self.r.init_units[unit].func);
    }

    fn addTested(self: *Reach, c: ClassId) Allocator.Error!void {
        const gop = try self.tested_seen.getOrPut(self.gpa, c.int());
        if (!gop.found_existing) try self.tested.append(self.gpa, c);
    }

    /// The runtime's exceptions a `catch` of the program can see, built by
    /// the program's own constructors when raised.
    pub fn addExceptions(self: *Reach) Allocator.Error!void {
        if (self.caught.items.len == 0) return;
        const e = &self.r.exceptions;
        const fixed = [_]?ir.resolved.Raised{ e.null_pointer, e.class_cast, e.arithmetic, e.uninitialized_property, e.index_out_of_bounds, e.array_index_out_of_bounds, e.string_index_out_of_bounds, self.r.base.init_failed, self.r.base.no_class_def };
        for (fixed) |x| if (x) |raised| {
            _ = try self.addRaisable(raised);
        };
        var it = e.by_fqn.iterator();
        while (it.next()) |entry| {
            if (!try self.addRaisable(entry.value_ptr.*)) continue;
            for (self.raisable_hosts.items) |h| {
                if (std.mem.eql(u8, h.key, entry.key_ptr.*)) break;
            } else try self.raisable_hosts.append(self.gpa, .{ .key = entry.key_ptr.*, .raised = entry.value_ptr.* });
        }
    }

    /// Whether a `catch` of the program can see `raised`; it is then built
    /// by the program.
    fn addRaisable(self: *Reach, raised: ir.resolved.Raised) Allocator.Error!bool {
        const is_caught = for (self.caught.items) |c| {
            if (ir.resolved.isA(self.m, raised.class, c)) break true;
        } else false;
        if (!is_caught) return false;
        const gop = try self.raisable_seen.getOrPut(self.gpa, raised.class.int());
        if (gop.found_existing) return true;
        try self.raisable.append(self.gpa, raised);
        try self.addConstructed(raised.class);
        try self.addFunc(raised.ctor);
        return true;
    }

    fn visit(self: *Reach, id: FuncId) Allocator.Error!void {
        const f = self.m.funcById(id) orelse return;
        for (f.blocks) |*b| {
            for (b.h().catches) |h| {
                if (h.class_raw == ir.NO_CLASS) continue;
                const c = ClassId.from(h.class_raw);
                try self.addTested(c);
                for (self.caught.items) |x| {
                    if (x == c) break;
                } else try self.caught.append(self.gpa, c);
            }
            for (b.insts) |*inst| switch (inst.*) {
                .CallStatic => |x| {
                    try self.addUnit(x.init);
                    try self.addFunc(x.func);
                },
                .CallNative => |x| try self.addNative(x.native),
                .RCallVirtual => |x| try self.addSlot(x.slot),
                .CallInterface => |x| try self.addSlot(x.slot),
                .RNewInstance => |x| {
                    try self.addConstructed(x.class);
                    try self.addFunc(x.ctor);
                },
                .LoadObject => |x| try self.addObject(x.class),
                .LoadStatic => |x| try self.addStatic(x.static),
                .StoreStatic => |x| try self.addStatic(x.static),
                .MakeClosure => |x| {
                    try self.closure_sites.append(self.gpa, .{ .body = x.func, .kind = .lambda, .n_caps = @intCast(x.captures.len) });
                    try self.addFunc(x.func);
                },
                .FunctionRef => |x| {
                    try self.closure_sites.append(self.gpa, .{ .body = x.adapter, .kind = .function_ref, .bound = x.bound != null, .target = x.target });
                    try self.addFunc(x.adapter);
                },
                .RPropertyRef => |x| {
                    try self.addFunc(x.getter);
                    if (x.setter != ir.NO_FUNC) try self.addFunc(FuncId.from(x.setter));
                },
                .RInstanceOf => |x| try self.addTested(x.class),
                .RCast => |x| try self.addTested(x.class),
                .ClassLiteral => |x| try self.addTested(x.class),
                .NewArray => |x| try self.addTested(x.class),
                else => {},
            };
        }
    }

    /// Walks from `entry` until nothing new is reached.
    pub fn walk(self: *Reach, entry: FuncId) Allocator.Error!void {
        try self.addFunc(entry);
        try self.drain();
    }

    /// Visits what was reached since the last drain.
    pub fn drain(self: *Reach) Allocator.Error!void {
        while (self.pending.pop()) |id| try self.visit(id);
    }
};

pub fn init(gpa: Allocator, br: *Bridge) ?Reach {
    const r = br.m.resolved orelse return null;
    return .{ .gpa = gpa, .br = br, .m = br.m, .r = r };
}
