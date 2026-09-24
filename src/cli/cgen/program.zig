//! The program a native build emits: what it reaches from `main`, the
//! machine type of every function's registers, and the ids its C refers to
//! (statics, singletons, closure classes, natives). Built once, then read
//! by the writers.

const std = @import("std");
const ir = @import("ir");
const sema = @import("sema");

const reach_mod = @import("reach.zig");
const sig_mod = @import("sig.zig");
const typing = @import("typing.zig");
const ctype = @import("ctype.zig");

const Allocator = std.mem.Allocator;
const FuncId = ir.FuncId;
const ClassId = ir.ClassId;
const MethodSlotId = ir.MethodSlotId;
const NativeId = ir.NativeId;
const StaticId = ir.StaticId;
const Ty = ctype.Ty;
const Sig = sig_mod.Sig;

/// A body that becomes one C function.
pub const Body = struct {
    id: FuncId,
    f: *const ir.Func,
    sig: Sig,
    t: typing.Typing,
    /// Its frame slot, for each register that holds a reference.
    slot: []u32,
    n_slots: u32,
    /// A closure's body: its captures are read from the closure, passed
    /// first.
    closure: bool,
    has_try: bool,
};

/// A class a closure is an instance of: one per closure body.
pub const ClosureClass = struct {
    id: u32,
    body: FuncId,
    arity: u32,
    n_caps: u32,
    kind: enum { lambda, function_ref },
    /// For a function reference: what it refers to, for its equality.
    target: FuncId = FuncId.from(ir.NO_FUNC),
};

pub const Program = struct {
    gpa: Allocator,
    /// Owns everything the emission derives.
    a: Allocator,
    br: *ir.bridge.Bridge,
    m: *ir.Module,
    r: *const ir.Resolved,
    s: *sema.Sema,
    sigs: sig_mod.Sigs,
    rc: reach_mod.Reach,
    main: FuncId,
    bodies: std.ArrayList(Body) = .empty,
    body_index: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    closures: std.ArrayList(ClosureClass) = .empty,
    closure_of: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// Statics the program reads or writes, in `KG` order.
    statics: std.ArrayList(StaticId) = .empty,
    static_index: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// Init units behind those statics, in `KU` order.
    units: std.ArrayList(u32) = .empty,
    unit_index: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// Singletons, in `KO` order.
    objects: std.ArrayList(ClassId) = .empty,
    object_index: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// Every class the program registers with the runtime.
    classes: std.ArrayList(u32) = .empty,
    class_seen: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Why the program is outside what the backend compiles.
    refusal: ?[]const u8 = null,
    /// The base's `KlioMatchGroups`, when a native the program calls builds
    /// one over a host match (`MatchResult.groups`).
    match_groups: ?ir.resolved.ClassCtor = null,

    pub fn refuse(self: *Program, comptime fmt: []const u8, args: anytype) void {
        if (self.refusal != null) return;
        self.refusal = std.fmt.allocPrint(self.a, fmt, args) catch "out of memory";
    }

    pub fn body(self: *const Program, f: FuncId) ?*const Body {
        const i = self.body_index.get(f.int()) orelse return null;
        return &self.bodies.items[i];
    }

    pub fn closureOf(self: *const Program, f: FuncId) ?*const ClosureClass {
        const i = self.closure_of.get(f.int()) orelse return null;
        return &self.closures.items[i];
    }

    pub fn staticIndex(self: *const Program, st: StaticId) u32 {
        return self.static_index.get(st.int()).?;
    }

    pub fn unitIndex(self: *const Program, u: u32) ?u32 {
        return self.unit_index.get(u);
    }

    /// The init unit of the file declaring `main`, `NONE` for none.
    pub fn mainUnit(self: *const Program) u32 {
        const units = self.r.facade_unit;
        return if (self.main.int() < units.len) units[self.main.int()] else ir.resolved.NONE;
    }

    pub fn objectIndex(self: *const Program, c: ClassId) u32 {
        return self.object_index.get(c.int()).?;
    }

    pub fn funcName(self: *const Program, f: FuncId) []const u8 {
        return if (self.m.funcById(f)) |func| func.fqn else "?";
    }

    pub fn className(self: *const Program, c: u32) []const u8 {
        if (c < self.m.classes.items.len) return self.m.classes.items[c].fqn;
        return "<closure>";
    }

    /// The native `f` runs instead of a body.
    pub fn nativeOf(self: *const Program, f: FuncId) ?NativeId {
        return self.rc.nativeOf(f);
    }

    /// Where native `n` sits in the table the program registers.
    pub fn nativeIndex(self: *const Program, n: NativeId) u32 {
        for (self.rc.natives.items, 0..) |x, i| {
            if (x == n) return @intCast(i);
        }
        unreachable;
    }

    pub fn addClass(self: *Program, c: u32) Allocator.Error!void {
        if (c == ir.resolved.NONE) return;
        const gop = try self.class_seen.getOrPut(self.a, c);
        if (gop.found_existing) return;
        try self.classes.append(self.a, c);
        // Every ancestor, so type tests against it and `KClass` reads of it
        // answer from the registry.
        if (c < self.m.class_ancestors.items.len) {
            for (self.m.class_ancestors.items[c]) |anc| try self.addClass(anc.int());
        }
    }

    /// The classes of the host's value kinds, which a type test or a
    /// dispatch may meet.
    pub fn hostClasses(self: *const Program, out: *std.ArrayList(u32)) Allocator.Error!void {
        const h = &self.r.host_class;
        const singles = [_]?ClassId{ h.unit, h.boolean, h.char, h.byte, h.short, h.int, h.long, h.float, h.double, h.ubyte, h.ushort, h.uint, h.ulong, h.string, h.array };
        for (singles) |c| if (c) |id| try out.append(self.a, id.int());
        for (h.prim_array) |c| if (c) |id| try out.append(self.a, id.int());
        for (h.by_tag) |c| if (c) |id| try out.append(self.a, id.int());
        for (h.range) |c| if (c) |id| try out.append(self.a, id.int());
        for (h.progression) |c| if (c) |id| try out.append(self.a, id.int());
        for (h.function) |c| try out.append(self.a, c.int());
        for (h.suspend_function) |c| if (c.int() != ir.resolved.NONE) try out.append(self.a, c.int());
    }
};

/// Builds the program reached from `main`: every body typed, every id the
/// C names allocated. `refusal` is set when something is outside the
/// backend.
pub fn build(gpa: Allocator, a: Allocator, br: *ir.bridge.Bridge, main: FuncId) Allocator.Error!Program {
    var p: Program = .{
        .gpa = gpa,
        .a = a,
        .br = br,
        .m = br.m,
        .r = br.m.resolved.?,
        .s = br.s,
        .sigs = try sig_mod.Sigs.init(a, br),
        .rc = reach_mod.init(a, br).?,
        .main = main,
    };
    // A host value reaching a dispatch runs its class's implementation.
    var hc: std.ArrayList(u32) = .empty;
    try p.hostClasses(&hc);
    for (hc.items) |c| try p.rc.addHostClass(ClassId.from(c));
    // The file declaring `main` initializes before it runs.
    try p.rc.addUnit(p.mainUnit());
    try p.rc.walk(main);
    // The host builds a match's groups with the base's constructor.
    if (p.r.base.match_groups) |mg| if (p.rc.reachesNative("kotlin.text.MatchResult.groups")) {
        try p.rc.addConstructed(mg.class);
        try p.rc.addFunc(mg.ctor);
        try p.rc.drain();
        p.match_groups = mg;
    };
    // An exception's constructor can reach another `catch`.
    while (true) {
        try p.rc.addExceptions();
        if (p.rc.pending.items.len == 0) break;
        try p.rc.drain();
    }
    if (p.rc.missing.items.len != 0) {
        const f = p.rc.missing.items[0];
        p.refuse("`{s}` has neither a body nor a native", .{p.funcName(f)});
    }

    // Closure classes, numbered past the module's classes.
    var next_class: u32 = @intCast(p.m.classes.items.len);
    for (p.rc.closure_sites.items) |cs| {
        const gop = try p.closure_of.getOrPut(a, cs.body.int());
        if (gop.found_existing) continue;
        const func = p.m.funcById(cs.body) orelse continue;
        gop.value_ptr.* = @intCast(p.closures.items.len);
        const bound: u32 = if (cs.kind == .function_ref and cs.bound) 1 else 0;
        const caps: u32 = if (cs.body.int() < br.captures_of.len) @intCast(br.captures_of[cs.body.int()].len) else 0;
        try p.closures.append(a, .{
            .id = next_class,
            .body = cs.body,
            .arity = @intCast(func.params.len),
            .n_caps = if (cs.kind == .function_ref) bound + caps else cs.n_caps,
            .kind = if (cs.kind == .function_ref) .function_ref else .lambda,
            .target = cs.target,
        });
        next_class += 1;
    }

    for (p.rc.statics.items) |st| {
        try p.static_index.put(a, st.int(), @intCast(p.statics.items.len));
        try p.statics.append(a, st);
    }
    for (p.rc.units.items) |unit| {
        try p.unit_index.put(a, unit, @intCast(p.units.items.len));
        try p.units.append(a, unit);
    }
    for (p.rc.objects.items) |c| {
        try p.object_index.put(a, c.int(), @intCast(p.objects.items.len));
        try p.objects.append(a, c);
    }

    for (p.rc.constructed.items) |c| try p.addClass(c.int());
    for (hc.items) |c| try p.addClass(c);
    for (p.rc.tested.items) |c| try p.addClass(c.int());

    for (p.rc.funcs.items) |id| {
        const func = p.m.funcById(id).?;
        if (func.is_suspend) {
            p.refuse("`{s}` suspends", .{func.fqn});
            continue;
        }
        const sg = try p.sigs.of(id);
        const closure = p.closure_of.contains(id.int());
        const t = try typing.solve(a, .{ .sigs = &p.sigs, .f = func, .sig = sg });
        const slot = try a.alloc(u32, func.n_locals);
        var n_slots: u32 = 0;
        for (t.tys, slot) |ty, *s| {
            if (ty == .object) {
                s.* = n_slots;
                n_slots += 1;
            } else s.* = std.math.maxInt(u32);
        }
        var has_try = false;
        for (func.blocks) |*blk| {
            const h = blk.h();
            if (h.catches.len != 0 or h.pop_on_exit.len != 0 or h.catch_done_for != null) has_try = true;
            if (h.finally != null or h.finally_done != null or h.lr_absorb != null) p.refuse("`{s}` has a `finally`", .{func.fqn});
        }
        try p.body_index.put(a, id.int(), @intCast(p.bodies.items.len));
        try p.bodies.append(a, .{ .id = id, .f = func, .sig = sg, .t = t, .slot = slot, .n_slots = n_slots, .closure = closure, .has_try = has_try });
    }
    return p;
}
