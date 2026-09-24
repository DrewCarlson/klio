//! Where a body finds its receivers, locals and captures: the current
//! class's `this`, an outer instance, an extension, lambda or context
//! receiver, an object, and each local's home or cell.
//!
//! A body's parameters, captures and receivers are registered when the
//! body is entered (`enter`), from the calling convention of its kind, and
//! loaded on first use into the entry block, which dominates every use.
//! A value the body neither declares nor receives is read from the
//! captured slots of the local class it is a member of, or from an outer
//! instance along the inner classes' outer slots. Nothing is looked up by
//! name.

const std = @import("std");
const ast = @import("ast");
const sema = @import("sema");

const ir = @import("../../ir.zig");
const bridge = @import("../../core/bridge.zig");
const builder = @import("builder.zig");
const records = @import("records.zig");
const call = @import("call.zig");

const Builder = builder.Builder;
const Error = records.Error;
const Reg = ir.Reg;
const Sym = sema.Sym;
const ImplicitKind = sema.records.ImplicitKind;
const Receiver = sema.records.Receiver;
const CaptureKey = bridge.CaptureKey;

/// Where a value the body did not compute is read from.
pub const Slot = union(enum) {
    /// `LoadParam idx`.
    param: u16,
    /// `LoadCapture idx`: a closure's captured value.
    capture: u16,
};

pub const Env = struct {
    /// Parameters, captures and receivers by key (`symKey`, `recvKey`):
    /// where each is read from.
    slots: std.AutoHashMapUnmanaged(u64, Slot) = .empty,
    /// Registers already holding a key's value: a slot loaded in the entry
    /// block, an outer instance, or a receiver bound where a lambda is
    /// lowered in place.
    loaded: std.AutoHashMapUnmanaged(u64, Reg) = .empty,
    /// The class whose instance is parameter 0, or `.none`.
    this_class: Sym = .none,
    /// The first value parameter.
    values_at: u16 = 0,
    /// The first reified type value, after the value parameters.
    reified_at: u16 = 0,
    /// A setter's new value.
    setter_value: ?u16 = null,
    /// An enum class constructor's `name`; `ordinal` follows it.
    enum_name: ?u16 = null,
    /// The composable scope's `$composer` and `$changed` ints: a
    /// composable function's, getter's or lambda's, or those a composable
    /// literal lowered in place was called with.
    composer: ?Reg = null,
    changed: []const Reg = &.{},
    /// A composable filling its own defaults: its first `$default` int.
    defaults_at: ?u16 = null,
    /// In a composable body, the parameters and receivers it read, by key.
    reads: std.AutoHashMapUnmanaged(u64, void) = .empty,
};

pub fn symKey(s: Sym) u64 {
    return s.int();
}

pub fn recvKey(kind: ImplicitKind, owner: Sym) u64 {
    return (@as(u64, 1) << 63) | (@as(u64, @intFromEnum(kind)) << 32) | owner.int();
}

pub fn captureKey(k: CaptureKey) u64 {
    return switch (k) {
        .local => |s| symKey(s),
        .receiver => |r| recvKey(r.kind, r.owner),
    };
}

// ------------------------------------------------------------ body entry --

/// Registers the parameters, receivers and captures the calling convention
/// gives a body of `b.kind` whose symbol is `b.owner`:
///
/// - function: `this` (member), contexts, extension receiver, value
///   parameters, reified type values; a local function takes its captured
///   values first and has no `this`.
/// - constructor: `this`, the outer instance (inner class), `name` and
///   `ordinal` (enum class and enum entry class), captured values (local
///   class, object expression), value parameters.
/// - getter, setter: `this` (member), contexts, extension receiver, the
///   setter's new value.
/// - lambda, anonymous function: contexts, receiver, value parameters (or
///   `it`), and captures through `LoadCapture`.
/// - defaults bridge: its target's parameters.
///
/// Init units, SAM classes and adapters register nothing.
pub fn enter(b: *Builder) Error!void {
    switch (b.kind) {
        .function, .delegated => try enterFunction(b, b.owner, null),
        .local_fun => try enterFunction(b, b.owner, b.captures),
        .defaults => {
            const s = b.p.s;
            if (s.syms.kind(b.owner) == .constructor) return enterCtor(b, b.owner);
            try enterFunction(b, b.owner, localCaptures(b, b.owner));
        },
        .ctor => try enterCtor(b, b.owner),
        .getter, .setter => try enterAccessor(b),
        .lambda => try enterClosure(b),
        .init_unit, .sam_ctor, .sam_method, .sam_equals, .sam_hash_code, .adapter, .restart => {},
    }
}

fn setSlot(b: *Builder, key: u64, slot: Slot) Error!void {
    try b.env.slots.put(b.p.a, key, slot);
}

/// Whether `f` (a function, constructor or property) is called with an
/// instance as parameter 0.
pub fn hasThis(s: *sema.Sema, f: Sym) bool {
    if (s.syms.kind(f) == .constructor) return true;
    const owner = s.syms.owner(f);
    if (owner == .none or s.syms.kind(owner) != .class) return false;
    return !s.syms.flags(f).static;
}

/// The implicit-receiver kind a class's own `this` has: objects and
/// companions are `object`, everything else `class_this`.
pub fn thisKind(s: *sema.Sema, cls: Sym) ImplicitKind {
    return switch (s.syms.classInfo(cls).kind) {
        .object, .companion => .object,
        else => .class_this,
    };
}

/// The class whose instance an inner class holds, or null.
pub fn outerOf(s: *sema.Sema, cls: Sym) ?Sym {
    if (!s.syms.flags(cls).inner) return null;
    const outer = s.syms.owner(cls);
    return if (outer != .none and s.syms.kind(outer) == .class) outer else null;
}

fn enterThis(b: *Builder, cls: Sym) Error!void {
    b.env.this_class = cls;
    try setSlot(b, recvKey(thisKind(b.p.s, cls), cls), .{ .param = 0 });
}

/// A local function's captures, which lead its parameters; null for any
/// other function.
fn localCaptures(b: *Builder, f: Sym) ?[]const CaptureKey {
    const br = b.p.br;
    if (f.int() >= br.func_of.len) return null;
    const id = br.func_of[f.int()].int();
    if (id == bridge.NONE or id >= br.origin.len or br.origin[id] != .lambda) return null;
    return if (id < br.captures_of.len) br.captures_of[id] else &.{};
}

/// A function's frame; `captured` leads it for a local function, which
/// has no `this`.
fn enterFunction(b: *Builder, f: Sym, captured: ?[]const CaptureKey) Error!void {
    const s = b.p.s;
    try sema.headers.functionHeader(s, f);
    var idx: u16 = 0;
    if (captured) |keys| {
        for (keys) |k| {
            try setSlot(b, captureKey(k), .{ .param = idx });
            idx += 1;
        }
    } else if (hasThis(s, f)) {
        try enterThis(b, s.syms.owner(f));
        idx = 1;
    }
    const info = s.syms.functionInfo(f);
    for (info.context_params) |c| {
        try setSlot(b, symKey(c), .{ .param = idx });
        try setSlot(b, recvKey(.context, c), .{ .param = idx });
        idx += 1;
    }
    if (info.receiver != .none) {
        try setSlot(b, recvKey(.extension, f), .{ .param = idx });
        idx += 1;
    }
    b.env.values_at = idx;
    for (info.params) |p| {
        try setSlot(b, symKey(p), .{ .param = idx });
        idx += 1;
    }
    if (bridge.composableFunction(s, f)) {
        const ints = bridge.declChangedInts(s, f, captured == null and hasThis(s, f));
        try enterComposer(b, idx, ints);
        idx += 1 + ints;
        // `$default`, which the body reads where it fills its defaults.
        if (bridge.composableDefaults(s, f)) {
            b.env.defaults_at = idx;
            idx += bridge.defaultInts(info.params.len);
        }
    }
    b.env.reified_at = idx;
    // A reified type parameter's run-time type value is a local of the
    // body, loaded at entry, which `types.typeValue` reads and inline
    // instantiation replaces with the call site's value.
    for (info.type_params) |tp| {
        if (!s.syms.flags(tp).reified) continue;
        const r = b.newReg();
        try b.emitEntry(.{ .LoadParam = .{ .dst = r, .idx = idx } });
        try b.locals.put(b.p.a, tp, .{ .reg = r });
        idx += 1;
    }
}

/// A constructor's frame, which its defaults bridge shares.
fn enterCtor(b: *Builder, ctor: Sym) Error!void {
    const s = b.p.s;
    try sema.headers.functionHeader(s, ctor);
    const cls = s.syms.owner(ctor);
    try enterThis(b, cls);
    var idx: u16 = 1;
    if (outerOf(s, cls)) |outer| {
        try setSlot(b, recvKey(thisKind(s, outer), outer), .{ .param = idx });
        idx += 1;
    }
    switch (s.syms.classInfo(cls).kind) {
        .enum_class, .enum_entry => {
            b.env.enum_name = idx;
            idx += 2;
        },
        else => {},
    }
    for (classCaptures(b, cls)) |k| {
        try setSlot(b, captureKey(k), .{ .param = idx });
        idx += 1;
    }
    for (s.syms.functionInfo(ctor).context_params) |c| {
        try setSlot(b, symKey(c), .{ .param = idx });
        try setSlot(b, recvKey(.context, c), .{ .param = idx });
        idx += 1;
    }
    b.env.values_at = idx;
    for (s.syms.functionInfo(ctor).params) |p| {
        try setSlot(b, symKey(p), .{ .param = idx });
        idx += 1;
    }
    b.env.reified_at = idx;
}

fn enterAccessor(b: *Builder) Error!void {
    const s = b.p.s;
    const prop = b.owner;
    try sema.headers.propertyHeader(s, prop);
    var idx: u16 = 0;
    if (hasThis(s, prop)) {
        try enterThis(b, s.syms.owner(prop));
        idx = 1;
    }
    const info = s.syms.propertyInfo(prop);
    for (info.context_params) |c| {
        try setSlot(b, symKey(c), .{ .param = idx });
        try setSlot(b, recvKey(.context, c), .{ .param = idx });
        idx += 1;
    }
    if (info.receiver != .none) {
        try setSlot(b, recvKey(.extension, prop), .{ .param = idx });
        idx += 1;
    }
    b.env.values_at = idx;
    if (b.kind == .setter) b.env.setter_value = idx;
    if (b.kind == .getter and bridge.composableGetter(s, prop)) try enterComposer(b, idx, bridge.getterChangedInts(s, prop));
}

/// Loads the composer at parameter `idx` and the `ints` change-bit ints
/// after it.
fn enterComposer(b: *Builder, idx: u16, ints: u16) Error!void {
    const c = b.newReg();
    try b.emitEntry(.{ .LoadParam = .{ .dst = c, .idx = idx } });
    const changed = try b.p.a.alloc(Reg, ints);
    for (changed, 0..) |*r, k| {
        r.* = b.newReg();
        try b.emitEntry(.{ .LoadParam = .{ .dst = r.*, .idx = idx + 1 + @as(u16, @intCast(k)) } });
    }
    b.env.composer = c;
    b.env.changed = changed;
}

fn enterClosure(b: *Builder) Error!void {
    const s = b.p.s;
    const f = b.owner;
    const node: ast.NodeId, const is_lambda = switch (s.syms.get(f).decl) {
        .lambda => |l| .{ l.id, true },
        .anon_fun => |af| .{ af.id, false },
        else => return b.fail(b.cur_span, "a closure body whose symbol is not a lambda or anonymous function", .{}),
    };
    const rec = try b.lambda(node);
    var idx: u16 = 0;
    for (rec.contexts) |c| {
        try setSlot(b, symKey(c), .{ .param = idx });
        try setSlot(b, recvKey(.context, c), .{ .param = idx });
        idx += 1;
    }
    if (rec.has_receiver) {
        // A lambda's receiver is a `lambda` receiver; an anonymous
        // function's is its extension receiver.
        try setSlot(b, recvKey(if (is_lambda) .lambda else .extension, f), .{ .param = idx });
        idx += 1;
    }
    b.env.values_at = idx;
    if (rec.it != .none) {
        try setSlot(b, symKey(rec.it), .{ .param = idx });
        idx += 1;
    }
    for (rec.params) |p| {
        if (p != .none) try setSlot(b, symKey(p), .{ .param = idx });
        idx += 1;
    }
    if (bridge.composableType(s, rec.fn_type)) try enterComposer(b, idx, bridge.lambdaChangedInts(idx));
    for (b.captures, 0..) |k, i| try setSlot(b, captureKey(k), .{ .capture = @intCast(i) });
}

/// The captured values a local class or object expression stores, in slot
/// order from `Bridge.capture_base`.
fn classCaptures(b: *Builder, cls: Sym) []const CaptureKey {
    const br = b.p.br;
    const c = classIdOf(br, cls) orelse return &.{};
    return if (c < br.class_captures.len) br.class_captures[c] else &.{};
}

fn classIdOf(br: *const bridge.Bridge, cls: Sym) ?u32 {
    if (cls.int() >= br.class_of.len) return null;
    const c = br.class_of[cls.int()].int();
    return if (c == bridge.NONE) null else c;
}

// ------------------------------------------------------------- receivers --

/// The register holding the implicit receiver `{kind, owner}`.
pub fn receiver(b: *Builder, kind: ImplicitKind, owner: Sym) Error!Reg {
    const s = b.p.s;
    // `super` is the enclosing instance, dispatched non-virtually.
    if (kind == .super_) return thisOf(b, owner);
    const key = recvKey(kind, owner);
    if (try known(b, key)) |r| return r;
    if (try fromClass(b, key)) |r| return r;
    switch (kind) {
        // An object reached from outside its own body is its singleton.
        .object => return loadObject(b, owner),
        // A context parameter is a value: a parameter of this body or one
        // it captured.
        .context => if (try homeOf(b, owner)) |h| return switch (h) {
            .reg => |r| r,
            .cell => |c| cellGet(b, c),
        },
        else => {},
    }
    return b.fail(b.cur_span, "the {s} receiver of `{s}` is not available in this body", .{ @tagName(kind), s.str(s.syms.name(owner)) });
}

/// The instance of class `cls` as a receiver: its `this`, or the object.
pub fn thisOf(b: *Builder, cls: Sym) Error!Reg {
    return receiver(b, thisKind(b.p.s, cls), cls);
}

/// The register a record's receiver is in: `expr_reg` for `.expr`, the
/// implicit receiver's, or null for `.none`.
pub fn receiverOf(b: *Builder, r: Receiver, expr_reg: ?Reg) Error!?Reg {
    return switch (r) {
        .none => null,
        .expr => expr_reg orelse b.fail(b.cur_span, "the record names a receiver expression this site does not have", .{}),
        .implicit => |im| try receiver(b, im.kind, im.owner),
    };
}

/// Makes `reg` parameter `p`'s value from here on, without reading it: a
/// composable filling its own defaults gives a defaulted parameter the
/// register it fills.
pub fn rebindParam(b: *Builder, p: Sym, reg: Reg) Error!void {
    try b.env.loaded.put(b.p.a, symKey(p), reg);
}

/// Makes `reg` the receiver `{kind, owner}` from here on: a lambda
/// lowered in place binds its receiver to the argument's register.
pub fn bindReceiver(b: *Builder, kind: ImplicitKind, owner: Sym, reg: Reg) Error!void {
    try b.env.loaded.put(b.p.a, recvKey(kind, owner), reg);
}

/// The singleton of object or companion `cls`, loaded where it is used:
/// the first use constructs it.
pub fn loadObject(b: *Builder, cls: Sym) Error!Reg {
    const c = classIdOf(b.p.br, cls) orelse return b.fail(b.cur_span, "`{s}` has no class id", .{b.p.s.str(b.p.s.syms.name(cls))});
    const dst = b.newReg();
    try b.emit(.{ .LoadObject = .{ .dst = dst, .class = ir.ClassId.from(c) } });
    return dst;
}

/// A key's register when it is loaded, bound, or a slot of this body.
/// Every parameter of the body loaded in the entry block; by parameter
/// index, the register holding it.
pub fn paramRegs(b: *Builder) Error![]?Reg {
    var it = b.env.slots.iterator();
    while (it.next()) |e| switch (e.value_ptr.*) {
        .param => _ = try known(b, e.key_ptr.*),
        .capture => {},
    };
    const n = b.p.m.funcs.items[b.func.int()].params.len;
    const out = try b.p.a.alloc(?Reg, n);
    @memset(out, null);
    for (b.blocks.items[0].insts.items) |inst| switch (inst) {
        .LoadParam => |x| if (x.idx < n) {
            out[x.idx] = x.dst;
        },
        else => {},
    };
    return out;
}

fn known(b: *Builder, key: u64) Error!?Reg {
    // A composable's skip gate compares only what its body reads.
    if (b.env.composer != null) try b.env.reads.put(b.p.a, key, {});
    if (b.env.loaded.get(key)) |r| return r;
    const slot = b.env.slots.get(key) orelse return null;
    const dst = b.newReg();
    try b.emitEntry(switch (slot) {
        .param => |i| .{ .LoadParam = .{ .dst = dst, .idx = i } },
        .capture => |i| .{ .LoadCapture = .{ .dst = dst, .idx = i } },
    });
    try b.env.loaded.put(b.p.a, key, dst);
    return dst;
}

/// A key a member of this body's class reaches through the class: the
/// class's captured slots (a local class or object expression), then each
/// outer instance of an inner class, outward.
fn fromClass(b: *Builder, key: u64) Error!?Reg {
    const s = b.p.s;
    const br = b.p.br;
    var cls = b.env.this_class;
    if (cls == .none) return null;
    var reg = (try known(b, recvKey(thisKind(s, cls), cls))) orelse return null;
    while (true) {
        if (classIdOf(br, cls)) |c| {
            const keys = if (c < br.class_captures.len) br.class_captures[c] else &.{};
            for (keys, 0..) |k, i| {
                if (captureKey(k) != key) continue;
                const base = if (c < br.capture_base.len) br.capture_base[c] else bridge.NONE;
                if (base == bridge.NONE) return b.fail(b.cur_span, "a class with captures has no capture slots", .{});
                const dst = b.newReg();
                try b.emitEntry(.{ .GetFieldSlot = .{ .dst = dst, .obj = reg, .slot = base + @as(u32, @intCast(i)) } });
                try b.env.loaded.put(b.p.a, key, dst);
                return dst;
            }
        }
        const outer = outerOf(s, cls) orelse return null;
        const okey = recvKey(thisKind(s, outer), outer);
        reg = (try known(b, okey)) orelse blk: {
            const c = classIdOf(br, cls) orelse return null;
            const slot = if (c < br.outer_slot.len) br.outer_slot[c] else bridge.NONE;
            if (slot == bridge.NONE) return b.fail(b.cur_span, "an inner class has no outer slot", .{});
            const dst = b.newReg();
            try b.emitEntry(.{ .GetFieldSlot = .{ .dst = dst, .obj = reg, .slot = slot } });
            try b.env.loaded.put(b.p.a, okey, dst);
            break :blk dst;
        };
        if (okey == key) return reg;
        cls = outer;
    }
}

/// `this` / `this@L`, from its record.
pub fn lowerThis(b: *Builder, e: *const ast.Expr) Error!Reg {
    const r = try b.recv(e.This.id);
    return receiver(b, r.kind, r.owner);
}

/// `super` is only a call's or a member access's receiver, whose record
/// names the instance; as a value of its own it has no meaning.
pub fn lowerSuper(b: *Builder, e: *const ast.Expr) Error!Reg {
    return b.fail(e.span(), "`super` is not a value", .{});
}

// ---------------------------------------------------------------- locals --

/// Where a local or parameter lives in this body: its own home, a
/// parameter or capture, or a captured slot of its class. A captured cell
/// stays a cell. Null when the body cannot reach it.
pub fn homeOf(b: *Builder, s: Sym) Error!?builder.Home {
    if (b.locals.get(s)) |h| return h;
    const key = symKey(s);
    const r = (try known(b, key)) orelse (try fromClass(b, key)) orelse return null;
    return if (b.p.br.isCell(s)) .{ .cell = r } else .{ .reg = r };
}

/// Gives local `s` its home, holding `value`: a cell when a nested body
/// shares it, a register of its own when it is a `var`, and `value`'s
/// register itself for a `val`, which nothing writes again.
pub fn bindLocal(b: *Builder, s: Sym, value: Reg) Error!void {
    const home: builder.Home = if (b.p.br.isCell(s)) blk: {
        const dst = b.newReg();
        try b.emit(.{ .MakeCell = .{ .dst = dst, .src = value } });
        break :blk .{ .cell = dst };
    } else if (b.p.s.syms.flags(s).mutable) blk: {
        const dst = b.newReg();
        try b.emit(.{ .Move = .{ .dst = dst, .src = value } });
        break :blk .{ .reg = dst };
    } else .{ .reg = value };
    try b.locals.put(b.p.a, s, home);
}

/// Gives local `s` a home of its own before its first assignment
/// (`val x: Int` then `x = ...`, a `lateinit var`): it holds `null` until
/// written.
pub fn declareLocal(b: *Builder, s: Sym) Error!void {
    const nul = try b.nullValue();
    const dst = b.newReg();
    if (b.p.br.isCell(s)) {
        try b.emit(.{ .MakeCell = .{ .dst = dst, .src = nul } });
        try b.locals.put(b.p.a, s, .{ .cell = dst });
    } else {
        try b.emit(.{ .Move = .{ .dst = dst, .src = nul } });
        try b.locals.put(b.p.a, s, .{ .reg = dst });
    }
}

/// The value of local or parameter `s`. A `var` in a register is copied,
/// so a later write cannot change a value already read; a delegated local
/// asks its delegate; a `lateinit` local is checked.
pub fn readLocal(b: *Builder, s: Sym) Error!Reg {
    if (delegatedLocal(b, s)) |prop| return readDelegated(b, s, prop);
    const home = (try homeOf(b, s)) orelse return unreachable_(b, s);
    const v = switch (home) {
        .cell => |c| try cellGet(b, c),
        .reg => |r| if (b.locals.contains(s) and b.p.s.syms.flags(s).mutable) blk: {
            const dst = b.newReg();
            try b.emit(.{ .Move = .{ .dst = dst, .src = r } });
            break :blk dst;
        } else r,
    };
    if (lateinitLocal(b.p.s, s)) |prop| {
        const dst = b.newReg();
        const n = try b.p.m.internConst(b.p.a, .{ .String = prop.name.name });
        try b.emit(.{ .LateinitCheck = .{ .dst = dst, .src = v, .name = n } });
        return dst;
    }
    return v;
}

/// Stores `value` into local `s`: its register or its cell, or through
/// its delegate.
pub fn writeLocal(b: *Builder, s: Sym, value: Reg) Error!void {
    if (delegatedLocal(b, s)) |prop| return writeDelegated(b, s, prop, value);
    const home = (try homeOf(b, s)) orelse return unreachable_(b, s);
    switch (home) {
        .cell => |c| try b.emit(.{ .CellSet = .{ .cell = c, .value = value } }),
        .reg => |r| {
            if (!b.locals.contains(s)) {
                const st = b.p.s;
                return b.fail(b.cur_span, "`{s}` is written by a body that captured it by value", .{st.str(st.syms.name(s))});
            }
            try b.emit(.{ .Move = .{ .dst = r, .src = value } });
        },
    }
}

fn cellGet(b: *Builder, c: Reg) Error!Reg {
    const dst = b.newReg();
    try b.emit(.{ .CellGet = .{ .dst = dst, .cell = c } });
    return dst;
}

fn unreachable_(b: *Builder, s: Sym) Error {
    const st = b.p.s;
    return b.fail(b.cur_span, "`{s}` is not available in this body", .{st.str(st.syms.name(s))});
}

fn lateinitLocal(s: *sema.Sema, sym: Sym) ?*const ast.Property {
    return switch (s.syms.get(sym).decl) {
        .local_prop => |p| if (p.is_lateinit) p else null,
        else => null,
    };
}

/// The registers holding `keys` in this body, in order: a home, a receiver,
/// or this body's own capture (a cell stays a cell).
pub fn materializeCaptures(b: *Builder, keys: []const CaptureKey) Error![]Reg {
    const out = try b.p.a.alloc(Reg, keys.len);
    for (keys, out) |k, *o| o.* = switch (k) {
        .local => |s| switch ((try homeOf(b, s)) orelse return unreachable_(b, s)) {
            .reg, .cell => |r| r,
        },
        .receiver => |r| try receiver(b, r.kind, r.owner),
    };
    return out;
}

// ------------------------------------------------------- delegated locals --

/// A delegated local's declaration: its home holds the delegate, and each
/// read and write calls `getValue` and `setValue` on it.
pub fn delegatedLocal(b: *Builder, s: Sym) ?*const ast.Property {
    return switch (b.p.s.syms.get(s).decl) {
        .local_prop => |p| if (p.delegate != null) p else null,
        else => null,
    };
}

/// The `KProperty` a local's delegate receives: its name, with no accessor
/// behind it.
pub fn localPropertyRef(b: *Builder, prop: *const ast.Property) Error!Reg {
    const dst = b.newReg();
    const n = try b.p.m.internConst(b.p.a, .{ .String = prop.name.name });
    try b.emit(.{ .RPropertyRef = .{ .dst = dst, .getter = ir.FuncId.from(ir.NO_FUNC), .setter = ir.NO_FUNC, .bound = null, .name = n } });
    return dst;
}

/// Calls one of a local delegate's operators (`provideDelegate`,
/// `getValue`, `setValue`) on `delegate`: `thisRef` is `null`, then the
/// property, then the new value for `setValue`.
pub fn delegateCall(b: *Builder, rec: *const records.CallRec, delegate: Reg, prop: *const ast.Property, value: ?Reg) Error!Reg {
    const regs: [3]?Reg = .{ try b.nullValue(), try localPropertyRef(b, prop), value };
    const exprs: [3]?*const ast.Expr = .{ null, null, null };
    const n: usize = if (value != null) 3 else 2;
    return call.emitCall(b, rec, .{ .exprs = exprs[0..n], .regs = regs[0..n], .receiver = delegate });
}

fn delegateOf(b: *Builder, s: Sym) Error!Reg {
    return switch ((try homeOf(b, s)) orelse return unreachable_(b, s)) {
        .reg => |r| r,
        .cell => |c| cellGet(b, c),
    };
}

fn readDelegated(b: *Builder, s: Sym, prop: *const ast.Property) Error!Reg {
    const g = try b.delegate(prop.id);
    return delegateCall(b, &g.get, try delegateOf(b, s), prop, null);
}

fn writeDelegated(b: *Builder, s: Sym, prop: *const ast.Property, value: Reg) Error!void {
    const g = try b.delegate(prop.id);
    const set = g.set orelse return b.fail(prop.span, "delegated `val {s}` is written", .{prop.name.name});
    _ = try delegateCall(b, &set, try delegateOf(b, s), prop, value);
}
