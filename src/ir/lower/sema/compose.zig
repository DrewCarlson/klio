//! Compose as lowering: `@Composable` functions, getters and lambdas take
//! the Compose compiler's `$composer: Composer` and `$changed` ints after
//! their value parameters, and every call of one passes the composer of
//! the composable scope it is written in and what it knows of each
//! argument.
//!
//! Composability is sema's: the declaration flag, and the attribute of a
//! function type a lambda literal or an invoked value has.

const std = @import("std");
const ast = @import("ast");
const sema = @import("sema");
const span = @import("span");

const ir = @import("../../ir.zig");
const bridge = @import("../../core/bridge.zig");
const builder = @import("builder.zig");
const records = @import("records.zig");
const body = @import("body.zig");
const call = @import("call.zig");
const env = @import("env.zig");
const lambda = @import("lambda.zig");

const Builder = builder.Builder;
const Error = records.Error;
const Reg = ir.Reg;
const Sym = sema.Sym;

pub const composableFunction = bridge.composableFunction;
pub const composableGetter = bridge.composableGetter;
pub const composableType = bridge.composableType;

/// The composer of the composable scope being lowered: the function,
/// getter or lambda whose composer is in scope.
pub fn composer(b: *Builder) Error!Reg {
    return b.env.composer orelse b.fail(b.cur_span, "a composable call outside a composable function or lambda", .{});
}

// -------------------------------------------------------- change bits --

/// A `$changed` slot's three bits: uncertain 0b000, same 0b001, different
/// 0b010, static 0b011; 0b100 marks a value of an unstable type.
pub const same_bits: u3 = 0b001;
pub const different_bits: u3 = 0b010;
pub const static_bits: u3 = 0b011;
const unstable_bit: u3 = 0b100;
const mask_bits: u3 = 0b111;

/// `state` at `slot` of the int holding it: each int holds ten slots of
/// three bits above the forced bit.
pub fn slotBits(state: u3, slot: usize) i32 {
    return @as(i32, state) << @intCast(1 + 3 * (slot % 10));
}

/// One parameter a composable scope's change bits track. Slots follow the
/// Compose compiler's order: contexts, extension receiver, value
/// parameters, dispatch receiver; a composable lambda's last slot is the
/// lambda itself.
pub const Tracked = struct {
    /// The env keys a read of it loads (`env.symKey`, `env.recvKey`).
    key: u64 = 0,
    alt: u64 = 0,
    /// Its parameter index.
    idx: u16 = 0,
    ty: sema.TypeId = .none,
    /// A dispatch receiver's class.
    cls: Sym = .none,
    /// A value parameter's symbol and index among the values, and whether
    /// its body fills it with a default that is not static.
    param: Sym = .none,
    value: ?u16 = null,
    nonstatic_default: bool = false,
    vararg: bool = false,
    self: bool = false,
};

/// What a call knows of one argument, for its callee's slot.
const Meta = struct {
    state: enum { uncertain, static, forwarded } = .uncertain,
    /// The caller's slot a forwarded argument's bits come from.
    from: usize = 0,
    unstable: bool = false,
};

/// The `$changed` ints a call passes: per argument, in the callee's slot
/// order, what the caller knows of it. A static value is static; a
/// parameter of the caller passed on carries the caller's bits for it;
/// anything else is uncertain, and the callee compares it. `value`: an
/// `invoke` of a composable function value, whose last slot is the value.
pub fn callChanged(b: *Builder, rec: *const records.CallRec, value: bool, ops: call.Operands) Error![]const Reg {
    const s = b.p.s;
    const a = b.p.a;
    var metas: std.ArrayList(Meta) = .empty;
    const written: ?*const ast.Expr = if (ops.call) |e| (if (e.* == .Call) e else null) else null;
    const recv_expr: ?*const ast.Expr = if (written) |e| switch (e.Call.callee.*) {
        .Member => |m| m.receiver,
        else => null,
    } else null;
    for (rec.contexts) |c| try metas.append(a, try receiverMeta(b, c, null));
    if (value) {
        for (rec.args, 0..) |src, i| try metas.append(a, try argMeta(b, src, convOf(rec, i), ops, recv_expr));
        try metas.append(a, if (written) |e| invokedMeta(b, e) else .{});
    } else {
        const f = rec.callee;
        if (s.syms.functionInfo(f).receiver != .none) try metas.append(a, try receiverMeta(b, rec.extension, recv_expr));
        for (rec.args, 0..) |src, i| try metas.append(a, try argMeta(b, src, convOf(rec, i), ops, recv_expr));
        if (call.layoutOf(b.p, f).this) try metas.append(a, try receiverMeta(b, rec.dispatch, recv_expr));
    }
    return changedInts(b, metas.items);
}

fn convOf(rec: *const records.CallRec, i: usize) sema.records.Conv {
    return if (i < rec.conv.len) rec.conv[i] else .none;
}

/// The `$changed` a composable getter call passes: its receivers' bits.
pub fn getterChanged(b: *Builder, rec: *const records.NameRec, p: Sym) Error![]const Reg {
    const s = b.p.s;
    const a = b.p.a;
    var metas: std.ArrayList(Meta) = .empty;
    for (rec.contexts) |c| try metas.append(a, try receiverMeta(b, c, null));
    if (s.syms.propertyInfo(p).receiver != .none) try metas.append(a, try receiverMeta(b, rec.extension, null));
    if (env.hasThis(s, p)) try metas.append(a, try receiverMeta(b, rec.dispatch, null));
    return changedInts(b, metas.items);
}

fn argMeta(b: *Builder, src: sema.records.ArgSource, conv: sema.records.Conv, ops: call.Operands, recv_expr: ?*const ast.Expr) Error!Meta {
    // A fun interface's wrapper is of an interface type, which is not stable.
    if (conv == .sam) return .{};
    return switch (src) {
        .arg => |k| if ((if (k < ops.exprs.len) ops.exprs[k] else null)) |e| try exprMeta(b, e) else .{},
        .receiver => if (recv_expr) |e| try exprMeta(b, e) else .{},
        // An omitted argument is not provided; a vararg is a fresh array.
        .default, .vararg => .{},
    };
}

fn exprMeta(b: *Builder, e: *const ast.Expr) Error!Meta {
    if (try isStaticExpr(b, e)) return .{ .state = .static };
    var m: Meta = .{};
    if (forwardedSlot(b, e)) |slot| m = .{ .state = .forwarded, .from = slot };
    m.unstable = try typeStability(b, b.exprType(e.id()), 0) == .unstable;
    return m;
}

/// The value a composable `invoke` calls: a parameter of this scope named
/// as the callee passes its bits on. The call's node holds the name's
/// record.
fn invokedMeta(b: *Builder, e: *const ast.Expr) Meta {
    const c = &e.Call;
    const at = switch (c.callee.*) {
        .Path => |p| if (p.segments.len == 1) p.segments[0].span.start else return .{},
        else => return .{},
    };
    const nr = b.nameAt(c.id, at) orelse return .{};
    if (nr.kind != .param) return .{};
    const slot = trackedSlot(b, env.symKey(nr.target)) orelse return .{};
    return .{ .state = .forwarded, .from = slot };
}

fn receiverMeta(b: *Builder, r: sema.records.Receiver, expr: ?*const ast.Expr) Error!Meta {
    return switch (r) {
        .none => .{},
        .expr => if (expr) |e| try exprMeta(b, e) else .{},
        .implicit => |im| blk: {
            // An object is the same every composition.
            if (im.kind == .object) break :blk .{ .state = .static };
            var m: Meta = .{};
            if (trackedSlot(b, env.recvKey(im.kind, im.owner))) |slot| m = .{ .state = .forwarded, .from = slot };
            if (im.kind == .class_this) m.unstable = try classStability(b, im.owner, &.{}, 0) == .unstable;
            break :blk m;
        },
    };
}

/// The slot of this scope's tracked parameter `e` reads, when it reads one.
fn forwardedSlot(b: *Builder, e: *const ast.Expr) ?usize {
    switch (e.*) {
        .Path => |p| {
            if (p.segments.len != 1) return null;
            const nr = b.nameAt(p.id, p.segments[0].span.start) orelse return null;
            if (nr.kind != .param) return null;
            return trackedSlot(b, env.symKey(nr.target));
        },
        .This => |t| {
            const r = b.recv(t.id) catch return null;
            return trackedSlot(b, env.recvKey(r.kind, r.owner));
        },
        else => return null,
    }
}

fn trackedSlot(b: *Builder, key: u64) ?usize {
    for (b.compose_tracked, 0..) |t, i| {
        if (t.key != 0 and (t.key == key or t.alt == key)) return i;
    }
    return null;
}

/// The ints over `metas`, ten slots each: the static and unstable bits a
/// constant, each forwarded slot's bits moved from the caller's.
fn changedInts(b: *Builder, metas: []const Meta) Error![]const Reg {
    const out = try b.p.a.alloc(Reg, bridge.changedInts(metas.len));
    for (out, 0..) |*r, k| {
        const start = k * 10;
        const end = @min(start + 10, metas.len);
        var constant: i32 = 0;
        var dynamic: ?Reg = null;
        for (metas[@min(start, end)..end], start..) |m, slot| {
            if (m.unstable) constant |= slotBits(unstable_bit, slot);
            switch (m.state) {
                .uncertain => {},
                .static => constant |= slotBits(static_bits, slot),
                .forwarded => if (try movedBits(b, m.from, slot)) |bits| {
                    dynamic = if (dynamic) |d| try orRegs(b, d, bits) else bits;
                },
            }
        }
        const c = try b.emitConst(.{ .Int = constant });
        r.* = if (dynamic) |d| (if (constant == 0) d else try orRegs(b, d, c)) else c;
    }
    return out;
}

/// `(0b111 at to) and <the caller's bits at from, moved to to>`.
fn movedBits(b: *Builder, from: usize, to: usize) Error!?Reg {
    if (from / 10 >= b.compose_dirty.len) return null;
    const src = b.compose_dirty[from / 10];
    const delta = @as(i32, @intCast(to % 10)) - @as(i32, @intCast(from % 10));
    var moved = src;
    if (delta != 0) {
        moved = b.newReg();
        const by = try b.emitConst(.{ .Int = 3 * @as(i32, @intCast(@abs(delta))) });
        try b.emit(.{ .BinOp = .{ .dst = moved, .op = if (delta > 0) .Shl else .Shr, .lhs = src, .rhs = by } });
    }
    return try bitAnd(b, moved, slotBits(mask_bits, to));
}

fn orRegs(b: *Builder, x: Reg, y: Reg) Error!Reg {
    const dst = b.newReg();
    try b.emit(.{ .BinOp = .{ .dst = dst, .op = .Or, .lhs = x, .rhs = y } });
    return dst;
}

/// A value every composition passes the same, as the Compose compiler
/// judges it: a literal, an enum entry, an object, a `const val`, a
/// read-only property of a stable type on a static receiver that is
/// `@Stable` or declared with its default getter in this file, arithmetic
/// on static operands, a `@Stable` function's or `@Immutable` class's
/// call over static arguments, and `remember` without keys of a stable
/// type.
fn isStaticExpr(b: *Builder, e: *const ast.Expr) Error!bool {
    return switch (e.*) {
        .IntLit, .FloatLit, .BoolLit, .CharLit, .NullLit => true,
        .StringTemplate => |t| for (t.parts) |part| {
            if (part != .Text) break false;
        } else true,
        .Path => |p| blk: {
            // Every segment that is a value: the first read on its implicit
            // receivers, each later one a static read on the one before.
            var any = false;
            for (p.segments) |seg| {
                const nr = b.nameAt(p.id, seg.span.start) orelse continue;
                if (!try staticRead(b, &nr, any or implicitStatic(&nr))) break :blk false;
                any = true;
            }
            break :blk any;
        },
        .Member => |m| blk: {
            if (m.safe) break :blk false;
            const nr = b.nameAt(m.id, m.name.span.start) orelse break :blk false;
            // A package or class qualifier is no value; any other receiver
            // is static when it is.
            const qualifier = switch (m.receiver.*) {
                .Path, .Member => b.exprType(m.receiver.id()) == .none,
                else => false,
            };
            const recv_static = (qualifier and implicitStatic(&nr)) or try isStaticExpr(b, m.receiver);
            break :blk try staticRead(b, &nr, recv_static);
        },
        .Unary => |u| u.op == .Neg and try isStaticExpr(b, u.expr),
        .Binary => |x| switch (x.op) {
            .Add, .Sub, .Mul, .Div, .And, .Or, .Eq, .IdentEq, .Lt, .Le, .Gt, .Ge => try isStaticExpr(b, x.lhs) and
                try isStaticExpr(b, x.rhs) and
                try typeStability(b, b.exprType(x.id), 0) == .stable,
            else => false,
        },
        .Call => |c| try staticCall(b, e, &c),
        .Lambda, .AnonFun => try staticLiteral(b, e),
        .Labeled => |l| try isStaticExpr(b, l.expr),
        else => false,
    };
}

/// A literal is static when it is the same every composition: a composable
/// one, which the runtime's composable lambda holds, or one remembered
/// over no captures.
fn staticLiteral(b: *Builder, e: *const ast.Expr) Error!bool {
    const rec = b.lambda(e.id()) catch return false;
    if (b.env.composer == null) return false;
    if (composableType(b.p.s, rec.fn_type)) return true;
    if (!try memoizes(b, e, rec.func)) return false;
    const id = b.p.br.funcOfOpt(rec.func) orelse return false;
    return b.p.br.capturesOf(id).len == 0;
}

fn staticCall(b: *Builder, e: *const ast.Expr, c: *const @FieldType(ast.Expr, "Call")) Error!bool {
    const s = b.p.s;
    const rec = b.call(c.id) catch return false;
    const f = rec.callee;
    if (f == .none) return false;
    const result_stable = try typeStability(b, b.exprType(e.id()), 0) == .stable;
    if (s.syms.kind(f) == .constructor) {
        if (!try annotatedClass(s, s.syms.owner(f), "Immutable")) return false;
    } else if (s.syms.kind(f) == .function) {
        if (isRuntimeFunction(s, f, "androidx.compose.runtime", "remember")) {
            // `remember { ... }` without keys: the value it first computed.
            return rec.args.len == 1 and result_stable;
        }
        if (!stableFunction(s, f)) {
            if (!try annotated(s, f, "Stable") or !result_stable) return false;
        }
    } else return false;
    switch (c.callee.*) {
        .Member => |m| if (rec.dispatch == .expr or rec.extension == .expr) {
            if (!try isStaticExpr(b, m.receiver)) return false;
        },
        else => {},
    }
    for (c.args) |*arg| {
        if (!try isStaticExpr(b, arg)) return false;
    }
    return true;
}

/// The standard library's collection builders the Compose compiler treats
/// as stable functions.
fn stableFunction(s: *sema.Sema, f: Sym) bool {
    const names = .{ "emptyList", "listOf", "listOfNotNull", "mapOf", "emptyMap", "setOf", "emptySet" };
    inline for (names) |n| if (isRuntimeFunction(s, f, "kotlin.collections", n)) return true;
    return isRuntimeFunction(s, f, "kotlin", "to");
}

/// Whether a read's implicit receivers are the same every composition: it
/// has none but objects. A class's `this` or an extension receiver is a
/// value of this scope.
fn implicitStatic(nr: *const records.NameRec) bool {
    if (nr.contexts.len != 0) return false;
    inline for (.{ nr.dispatch, nr.extension }) |r| switch (r) {
        .none, .expr => {},
        .implicit => |im| if (im.kind != .object) return false,
    };
    return true;
}

/// Whether a name read is static, its receiver (if any) being so when
/// `recv_static`.
fn staticRead(b: *Builder, nr: *const records.NameRec, recv_static: bool) Error!bool {
    const s = b.p.s;
    switch (nr.kind) {
        .enum_entry, .object => return true,
        .property => {
            if (s.syms.flags(nr.target).const_) return true;
            if (!recv_static) return false;
            if (try typeStability(b, try sema.headers.propertyType(s, nr.target), 0) != .stable) return false;
            if (try propertyMarkedStable(s, nr.target)) return true;
            // A `val` of this file with its default getter.
            if (s.syms.get(nr.target).decl != .property) return false;
            const info = s.syms.propertyInfo(nr.target);
            return s.syms.get(nr.target).file == b.file and !s.syms.flags(nr.target).mutable and !info.written.getter and !info.has_delegate;
        },
        else => return false,
    }
}

/// A property annotated `@Stable`, whose value the composition treats as
/// unchanging for an unchanging receiver.
fn propertyMarkedStable(s: *sema.Sema, p: Sym) Error!bool {
    if (s.syms.get(p).decl != .property) return false;
    const cls = s.classByFqn("androidx.compose.runtime.Stable");
    return try sema.headers.hasAnnotation(s, p, .decl, cls) or try sema.headers.hasAnnotation(s, p, .getter, cls);
}

/// `androidx.compose.runtime.currentComposer`, the compiler intrinsic that
/// reads the scope's composer.
pub fn isCurrentComposer(s: *sema.Sema, p: Sym) bool {
    if (s.syms.kind(p) != .property) return false;
    const owner = s.syms.owner(p);
    if (owner == .none or s.syms.kind(owner) != .package) return false;
    return std.mem.eql(u8, s.str(s.syms.name(p)), "currentComposer") and
        std.mem.eql(u8, s.str(s.syms.packageInfo(owner).fqn), "androidx.compose.runtime");
}

// ------------------------------------------------------------- bodies --

/// Where a composable body's own `return`s go: its exit, which closes the
/// groups the body opened, and the register its value is moved into.
pub const Exit = struct {
    block: ir.BlockId,
    result: ?Reg,
};

/// A composable function's body. A restartable one runs in a restart
/// group whose scope re-invokes it, and skips when its arguments are what
/// they were. Any other (inline, value-returning, marked non-restartable)
/// is its plain body in its caller's group, as the Compose compiler emits
/// it, its composable calls passing its composer on.
pub fn lowerFunctionBody(b: *Builder, f: Sym, fb: *const ast.FunctionBody) Error!void {
    const s = b.p.s;
    // A function that manages its own groups gets none added.
    b.compose_explicit = try annotated(s, f, "ExplicitGroupsComposable");
    if (try bridge.restartable(s, f)) return restartableBody(b, f, fb);
    return plainBody(b, f, fb);
}

/// A non-restartable body: its returns still close the replace groups
/// they leave.
fn plainBody(b: *Builder, f: Sym, fb: *const ast.FunctionBody) Error!void {
    const s = b.p.s;
    b.compose_remember = true;
    b.compose_tracked = try functionTracked(b, f);
    b.compose_dirty = b.env.changed;
    b.compose_dirty_var = false;
    // An overridable body, or one that returns early, is its caller's
    // group's only as a group of its own, unless it is read-only or keeps
    // its own groups.
    const fl = s.syms.flags(f);
    const overridable = env.hasThis(s, f) and (fl.override or fl.modality != .final or
        s.syms.classInfo(s.syms.owner(f)).kind == .interface);
    const outer = !b.compose_explicit and !try annotated(s, f, "ReadOnlyComposable") and
        (overridable or returnsEarly(b, f, fb));
    if (outer) {
        _ = try composerCall(b, "startReplaceGroup", &.{try b.emitConst(.{ .Int = positionalKey(declSpan(s, f)) })});
    }
    if (try Defaults.enter(b, f)) |*d| try d.fill(b, f, null, b.compose_tracked);
    const exit = try b.newBlock();
    const result = b.newReg();
    try groupedBody(b, fb, .{ .block = exit, .result = result }, !outer);
    b.switchTo(exit);
    if (outer) try endReplaceGroupCall(b);
    b.terminate(.{ .Return = result });
}

/// Whether `f` returns anywhere but at the end of its body: a `return` to
/// it that is not the body's last statement.
fn returnsEarly(b: *Builder, f: Sym, fb: *const ast.FunctionBody) bool {
    const root = declNode(b.p.s, f) orelse return false;
    const tail: ?u32 = switch (fb.*) {
        .Block => |*blk| if (blk.stmts.len != 0) switch (blk.stmts[blk.stmts.len - 1]) {
            .Expr => |*e| if (e.* == .Return) e.span().start else null,
            else => null,
        } else null,
        .Expr => null,
    };
    const recs = b.recs;
    const id = root.id.int();
    if (id == 0 or id >= recs.node_count) return false;
    var i = recs.start[id];
    while (i < recs.refs.len) : (i += 1) {
        const r = recs.refs[i];
        if (r.anchor.start >= root.sp.end and r.anchor.end > root.sp.end) break;
        if (r.kind != .return_ or r.target != f) continue;
        if (tail) |t| if (r.anchor.start == t) continue;
        return true;
    }
    return false;
}

/// A restartable body: `startRestartGroup`, the skip gate, the body or
/// `skipToGroupEnd`, then `endRestartGroup` with its recompose lambda. The
/// body is lowered before the gate is written, so the gate compares only
/// the parameters the body reads, as the Compose compiler does.
fn restartableBody(b: *Builder, f: Sym, fb: *const ast.FunctionBody) Error!void {
    const s = b.p.s;
    const changed = b.env.changed;
    if (changed.len == 0) return b.fail(b.cur_span, "a composable function without its `$changed`", .{});
    _ = try composerCall(b, "startRestartGroup", &.{try b.emitConst(.{ .Int = positionalKey(declSpan(s, f)) })});
    b.compose_remember = true;
    const tracked = try functionTracked(b, f);
    const defaults = try Defaults.enter(b, f);
    const skippable = !try annotated(s, f, "NonSkippableComposable");
    const gate: Gate = if (skippable) try Gate.open(b, tracked) else .{ .dirty = changed };
    b.compose_tracked = tracked;
    b.compose_dirty = gate.dirty;
    b.compose_dirty_var = skippable;
    if (defaults) |*d| try d.fill(b, f, if (skippable) gate.dirty else null, tracked);
    const exit = try b.newBlock();
    try groupedBody(b, fb, .{ .block = exit, .result = null }, false);
    if (skippable) try gate.close(b, tracked, exit, if (defaults) |*d| d else null);
    b.switchTo(exit);
    try endRestartGroup(b, f, changed, if (defaults) |*d| d else null);
    b.terminate(.{ .Return = try b.unit() });
}

/// A composable's defaults, which its body fills as the Compose compiler
/// has it: a call passes a placeholder for an omitted argument and sets
/// its bit in `$default`.
const Defaults = struct {
    /// By value parameter: the register a defaulted one is filled into.
    homes: []?Reg,
    /// By value parameter: whether its default expression is static.
    static: []bool,
    masks: []Reg,

    /// Loads `$default`, and gives each defaulted parameter a register
    /// holding what the call passed; null for a composable without them.
    fn enter(b: *Builder, f: Sym) Error!?Defaults {
        const at = b.env.defaults_at orelse return null;
        const s = b.p.s;
        const a = b.p.a;
        const params = s.syms.functionInfo(f).params;
        const lay = call.layoutOf(b.p, f);
        const d: Defaults = .{
            .homes = try a.alloc(?Reg, params.len),
            .static = try a.alloc(bool, params.len),
            .masks = try a.alloc(Reg, bridge.defaultInts(params.len)),
        };
        for (d.masks, 0..) |*r, k| {
            r.* = b.newReg();
            try b.emitEntry(.{ .LoadParam = .{ .dst = r.*, .idx = at + @as(u16, @intCast(k)) } });
        }
        for (params, d.homes, d.static, 0..) |p, *h, *st, i| {
            h.* = null;
            st.* = true;
            if (!s.syms.flags(p).has_default) continue;
            const raw = b.newReg();
            try b.emitEntry(.{ .LoadParam = .{ .dst = raw, .idx = lay.valueStart() + @as(u16, @intCast(i)) } });
            const home = b.newReg();
            try b.emitEntry(.{ .Move = .{ .dst = home, .src = raw } });
            h.* = home;
            st.* = try defaultIsStatic(b, f, p);
        }
        return d;
    }

    /// Whether value parameter `i` was omitted: its bit in `$default`.
    fn omitted(d: *const Defaults, b: *Builder, i: usize) Error!Reg {
        const bit = try bitAnd(b, d.masks[i / 31], @as(i32, 1) << @intCast(i % 31));
        return cmp(b, .NotEq, bit, 0);
    }

    /// Fills the omitted parameters. A skippable body whose defaults are
    /// not all static computes them in a defaults group, only when it runs
    /// fresh or the composer says they are invalid, and a parameter given
    /// a default that is not static is uncertain to the calls it reaches.
    fn fill(d: *const Defaults, b: *Builder, f: Sym, dirty: ?[]const Reg, tracked: []const Tracked) Error!void {
        const all_static = for (d.homes, d.static) |h, st| {
            if (h != null and !st) break false;
        } else true;
        if (dirty == null or all_static) return d.set(b, f, null, tracked);
        _ = try composerCall(b, "startDefaults", &.{});
        const fresh = try cmp(b, .Eq, try bitAnd(b, b.env.changed[0], 1), 0);
        const cond = try orRegs(b, fresh, try composerGetter(b, "defaultsInvalid"));
        const set_blk = try b.newBlock();
        const keep_blk = try b.newBlock();
        const join = try b.newBlock();
        b.terminate(.{ .Branch = .{ .cond = cond, .t = set_blk, .f = keep_blk } });
        b.switchTo(set_blk);
        try d.set(b, f, dirty, tracked);
        b.terminate(.{ .Goto = join });
        b.switchTo(keep_blk);
        _ = try composerCall(b, "skipToGroupEnd", &.{});
        for (d.homes, d.static, 0..) |h, st, i| {
            if (h == null or st) continue;
            const yes = try b.newBlock();
            const next = try b.newBlock();
            b.terminate(.{ .Branch = .{ .cond = try d.omitted(b, i), .t = yes, .f = next } });
            b.switchTo(yes);
            try setUncertain(b, dirty.?, valueSlot(b, f, tracked, i));
            b.terminate(.{ .Goto = next });
            b.switchTo(next);
        }
        b.terminate(.{ .Goto = join });
        b.switchTo(join);
        _ = try composerCall(b, "endDefaults", &.{});
    }

    /// `if (<omitted>) p = <default>` for each defaulted parameter in
    /// order, each later default reading the earlier ones.
    fn set(d: *const Defaults, b: *Builder, f: Sym, dirty: ?[]const Reg, tracked: []const Tracked) Error!void {
        const s = b.p.s;
        const params = s.syms.functionInfo(f).params;
        const expect = call.expectOf(s, f);
        const expect_params: []const Sym = if (expect != .none) s.syms.functionInfo(expect).params else &.{};
        for (params, d.homes, d.static, 0..) |p, h, st, i| {
            const home = h orelse continue;
            const yes = try b.newBlock();
            const next = try b.newBlock();
            b.terminate(.{ .Branch = .{ .cond = try d.omitted(b, i), .t = yes, .f = next } });
            b.switchTo(yes);
            const v = try call.defaultValue(b, f, p, null, declSpan(s, f));
            if (!b.terminated()) {
                try b.emit(.{ .Move = .{ .dst = home, .src = v } });
                if (dirty) |dt| if (!st) try setUncertain(b, dt, valueSlot(b, f, tracked, i));
                b.terminate(.{ .Goto = next });
            }
            b.switchTo(next);
            try env.rebindParam(b, p, home);
            if (i < expect_params.len) try env.rebindParam(b, expect_params[i], home);
        }
    }
};

/// The slot of `f`'s value parameter `i` among `tracked`.
fn valueSlot(b: *Builder, f: Sym, tracked: []const Tracked, i: usize) usize {
    const p = b.p.s.syms.functionInfo(f).params[i];
    for (tracked, 0..) |t, slot| if (t.param == p) return slot;
    return 0;
}

/// `$dirty = $dirty and (0b111 at slot).inv()`: the slot uncertain.
fn setUncertain(b: *Builder, dirty: []const Reg, slot: usize) Error!void {
    const r = dirty[slot / 10];
    try b.emit(.{ .BinOp = .{ .dst = r, .op = .And, .lhs = r, .rhs = try b.emitConst(.{ .Int = ~slotBits(mask_bits, slot) }) } });
}

/// Whether parameter `p`'s default is static, judged over the records of
/// the file it is written in.
pub fn defaultIsStatic(b: *Builder, f: Sym, p: Sym) Error!bool {
    const s = b.p.s;
    _ = f;
    if (call.paramDefault(s, p)) |ex| return isStaticExpr(b, ex);
    const from = s.syms.paramInfo(p).default_from;
    const ex = (if (from != .none) call.paramDefault(s, from) else null) orelse return false;
    const file = b.file;
    b.setFile(s.syms.get(from).file);
    defer b.setFile(file);
    return isStaticExpr(b, ex);
}

/// A skip gate while its body is lowered: the block the gate is written
/// into once the body has shown which parameters it reads, and the body's
/// first block.
const Gate = struct {
    dirty: []const Reg,
    block: ir.BlockId = undefined,
    run: ir.BlockId = undefined,

    /// Leaves the current block for the gate's, and starts the body.
    fn open(b: *Builder, tracked: []const Tracked) Error!Gate {
        _ = tracked;
        const dirty = try b.p.a.alloc(Reg, b.env.changed.len);
        for (dirty) |*r| r.* = b.newReg();
        const g: Gate = .{ .dirty = dirty, .block = try b.newBlock(), .run = try b.newBlock() };
        b.terminate(.{ .Goto = g.block });
        b.switchTo(g.run);
        return g;
    }

    /// Writes the gate: `$dirty` from `$changed`, each read parameter the
    /// caller left uncertain compared, then `shouldExecute(<differs>,
    /// $dirty and 1)` choosing the body or `skipToGroupEnd` and `skip`.
    fn close(g: Gate, b: *Builder, tracked: []const Tracked, skip: ir.BlockId, defaults: ?*const Defaults) Error!void {
        const changed = b.env.changed;
        b.switchTo(g.block);
        for (g.dirty, changed) |d, c| try b.emit(.{ .Move = .{ .dst = d, .src = c } });
        const used = try b.p.a.alloc(bool, tracked.len);
        for (tracked, used) |t, *u| u.* = isUsed(b, t);
        for (tracked, used, 0..) |t, u, slot| {
            if (t.self or t.vararg or !u) continue;
            const v = try loadParam(b, t.idx);
            const i = t.value orelse {
                try probe(b, g.dirty, changed, slot, v, t, null);
                continue;
            };
            const d = defaults orelse {
                try probe(b, g.dirty, changed, slot, v, t, null);
                continue;
            };
            if (d.homes[i] == null) {
                try probe(b, g.dirty, changed, slot, v, t, null);
            } else if (d.static[i]) {
                // A static default is static: `if (<omitted>) static else <probe>`.
                const yes = try b.newBlock();
                const no = try b.newBlock();
                const join = try b.newBlock();
                b.terminate(.{ .Branch = .{ .cond = try d.omitted(b, i), .t = yes, .f = no } });
                b.switchTo(yes);
                try orInto(b, g.dirty[slot / 10], slotBits(static_bits, slot));
                b.terminate(.{ .Goto = join });
                b.switchTo(no);
                try probe(b, g.dirty, changed, slot, v, t, null);
                b.terminate(.{ .Goto = join });
                b.switchTo(join);
            } else {
                // Only a provided argument is compared.
                const provided = try cmp(b, .Eq, try bitAnd(b, d.masks[i / 31], @as(i32, 1) << @intCast(i % 31)), 0);
                try probe(b, g.dirty, changed, slot, v, t, provided);
            }
        }
        for (tracked, 0..) |t, slot| {
            if (!t.vararg) continue;
            const v = try loadParam(b, t.idx);
            const i = t.value orelse continue;
            if (defaults) |d| if (d.homes[i] != null) {
                const yes = try b.newBlock();
                const join = try b.newBlock();
                const provided = try cmp(b, .Eq, try bitAnd(b, d.masks[i / 31], @as(i32, 1) << @intCast(i % 31)), 0);
                b.terminate(.{ .Branch = .{ .cond = provided, .t = yes, .f = join } });
                b.switchTo(yes);
                try varargProbe(b, g.dirty, changed, slot, v, t);
                b.terminate(.{ .Goto = join });
                b.switchTo(join);
                continue;
            };
            try varargProbe(b, g.dirty, changed, slot, v, t);
        }
        const differs = try hasDifferences(b, g.dirty, used);
        const exec = try composerCall(b, "shouldExecute", &.{ differs, try bitAnd(b, g.dirty[0], 1) });
        const skip_blk = try b.newBlock();
        b.terminate(.{ .Branch = .{ .cond = exec, .t = g.run, .f = skip_blk } });
        b.switchTo(skip_blk);
        _ = try composerCall(b, "skipToGroupEnd", &.{});
        b.terminate(.{ .Goto = skip });
    }
};

/// Whether the body read tracked parameter `t`; the lambda's own slot
/// always counts.
fn isUsed(b: *Builder, t: Tracked) bool {
    if (t.self) return true;
    if (t.key != 0 and b.env.reads.contains(t.key)) return true;
    return t.alt != 0 and b.env.reads.contains(t.alt);
}

/// A composable function's tracked parameters.
fn functionTracked(b: *Builder, f: Sym) Error![]const Tracked {
    const s = b.p.s;
    const a = b.p.a;
    const info = s.syms.functionInfo(f);
    const lay = call.layoutOf(b.p, f);
    const own_defaults = bridge.composableDefaults(s, f);
    var out: std.ArrayList(Tracked) = .empty;
    for (info.context_params, 0..) |c, i| try out.append(a, .{
        .key = env.symKey(c),
        .alt = env.recvKey(.context, c),
        .idx = lay.contextStart() + @as(u16, @intCast(i)),
        .ty = try sema.headers.paramType(s, c),
    });
    if (info.receiver != .none) try out.append(a, .{ .key = env.recvKey(.extension, f), .idx = lay.extIndex(), .ty = info.receiver });
    for (info.params, 0..) |p, i| try out.append(a, .{
        .key = env.symKey(p),
        .idx = lay.valueStart() + @as(u16, @intCast(i)),
        .ty = try sema.headers.paramType(s, p),
        .param = p,
        .value = @intCast(i),
        .nonstatic_default = own_defaults and s.syms.flags(p).has_default and !try defaultIsStatic(b, f, p),
        .vararg = s.syms.flags(p).vararg,
    });
    if (lay.this) {
        const cls = s.syms.owner(f);
        try out.append(a, .{ .key = env.recvKey(env.thisKind(s, cls), cls), .idx = 0, .cls = cls });
    }
    return out.items;
}

/// A composable lambda's tracked parameters: its contexts, receiver and
/// values, then the lambda itself.
fn lambdaTracked(b: *Builder, f: Sym, rec: *const records.LambdaRec) Error![]const Tracked {
    const s = b.p.s;
    const a = b.p.a;
    const args = s.types.argsOf(rec.fn_type);
    var out: std.ArrayList(Tracked) = .empty;
    var idx: u16 = 0;
    for (rec.contexts) |c| {
        try out.append(a, .{ .key = env.symKey(c), .alt = env.recvKey(.context, c), .idx = idx, .ty = argType(args, idx) });
        idx += 1;
    }
    if (rec.has_receiver) {
        try out.append(a, .{ .key = env.recvKey(.lambda, f), .alt = env.recvKey(.extension, f), .idx = idx, .ty = argType(args, idx) });
        idx += 1;
    }
    if (rec.it != .none) {
        try out.append(a, .{ .key = env.symKey(rec.it), .idx = idx, .ty = argType(args, idx) });
        idx += 1;
    } else for (rec.params) |p| {
        try out.append(a, .{ .key = if (p != .none) env.symKey(p) else 0, .idx = idx, .ty = argType(args, idx) });
        idx += 1;
    }
    try out.append(a, .{ .self = true });
    return out.items;
}

fn argType(args: []const sema.types.Arg, i: usize) sema.TypeId {
    return if (i + 1 < args.len) args[i].ty else .none;
}

/// Whether any read parameter differs or the body is forced: per int,
/// `$dirty and (<same at each read slot> or 1) != <same at each read slot>`;
/// with no slots, `$dirty != 0`.
fn hasDifferences(b: *Builder, dirty: []const Reg, used: []const bool) Error!Reg {
    if (used.len == 0) return cmp(b, .NotEq, dirty[0], 0);
    var any: ?Reg = null;
    for (dirty, 0..) |d, k| {
        const start = k * 10;
        const end = @min(start + 10, used.len);
        var same: i32 = 0;
        for (used[@min(start, end)..end], start..) |u, slot| {
            if (u) same |= slotBits(same_bits, slot);
        }
        const one = if (same == 0)
            try cmp(b, .NotEq, try bitAnd(b, d, 1), 0)
        else
            try cmp(b, .NotEq, try bitAnd(b, d, same | 1), same);
        any = if (any) |x| try orRegs(b, x, one) else one;
    }
    return any.?;
}

fn cmp(b: *Builder, op: ir.BinOp, x: Reg, k: i32) Error!Reg {
    const dst = b.newReg();
    try b.emit(.{ .BinOp = .{ .dst = dst, .op = op, .lhs = x, .rhs = try b.emitConst(.{ .Int = k }) } });
    return dst;
}

/// `if ($changed and <static at slot> == 0) $dirty = $dirty or (if (<changed>(v)) <different> else <same>)`.
fn probe(b: *Builder, dirty: []const Reg, changed: []const Reg, slot: usize, v: Reg, t: Tracked, provided: ?Reg) Error!void {
    const k = slot / 10;
    const certain = try bitAnd(b, changed[k], slotBits(static_bits, slot));
    const unknown = try cmp(b, .Eq, certain, 0);
    const check = try b.newBlock();
    const join = try b.newBlock();
    b.terminate(.{ .Branch = .{ .cond = unknown, .t = check, .f = join } });
    b.switchTo(check);
    // `<provided> && <changed>`: an omitted argument is the same.
    const differs = if (provided) |pv| blk: {
        const r = b.newReg();
        const ask = try b.newBlock();
        const no = try b.newBlock();
        const done = try b.newBlock();
        b.terminate(.{ .Branch = .{ .cond = pv, .t = ask, .f = no } });
        b.switchTo(ask);
        try b.emit(.{ .Move = .{ .dst = r, .src = try probeChanged(b, changed[k], slot, v, t) } });
        b.terminate(.{ .Goto = done });
        b.switchTo(no);
        try b.emit(.{ .Move = .{ .dst = r, .src = try b.emitConst(.{ .Bool = false }) } });
        b.terminate(.{ .Goto = done });
        b.switchTo(done);
        break :blk r;
    } else try probeChanged(b, changed[k], slot, v, t);
    const diff_blk = try b.newBlock();
    const same_blk = try b.newBlock();
    b.terminate(.{ .Branch = .{ .cond = differs, .t = diff_blk, .f = same_blk } });
    b.switchTo(diff_blk);
    try orInto(b, dirty[k], slotBits(different_bits, slot));
    b.terminate(.{ .Goto = join });
    b.switchTo(same_blk);
    try orInto(b, dirty[k], slotBits(same_bits, slot));
    b.terminate(.{ .Goto = join });
    b.switchTo(join);
}

/// The comparison a probe makes of parameter `t`'s value: a function value
/// by identity, a value of uncertain stability by what the caller's
/// unstable bit says.
fn probeChanged(b: *Builder, changed: Reg, slot: usize, v: Reg, t: Tracked) Error!Reg {
    const st = if (t.cls != .none) try classStability(b, t.cls, &.{}, 0) else try typeStability(b, t.ty, 0);
    if (st != .uncertain) return changedCall(b, v, t.ty, st, true);
    // `if ($changed and <unstable at slot> == 0) changed(v) else changedInstance(v)`.
    const marked = try bitAnd(b, changed, slotBits(unstable_bit, slot));
    const stable_arg = try cmp(b, .Eq, marked, 0);
    const result = b.newReg();
    const yes = try b.newBlock();
    const no = try b.newBlock();
    const join = try b.newBlock();
    b.terminate(.{ .Branch = .{ .cond = stable_arg, .t = yes, .f = no } });
    b.switchTo(yes);
    try b.emit(.{ .Move = .{ .dst = result, .src = try changedCall(b, v, t.ty, .stable, true) } });
    b.terminate(.{ .Goto = join });
    b.switchTo(no);
    try b.emit(.{ .Move = .{ .dst = result, .src = try changedCall(b, v, t.ty, .unstable, true) } });
    b.terminate(.{ .Goto = join });
    b.switchTo(join);
    return result;
}

/// A vararg is a fresh array every call, so its elements are compared, in
/// a movable group keyed by the parameter and its size: its size changing
/// or any element differing marks it different; otherwise, once no bits
/// are set, the same.
fn varargProbe(b: *Builder, dirty: []const Reg, changed: []const Reg, slot: usize, arr: Reg, t: Tracked) Error!void {
    const s = b.p.s;
    const k = slot / 10;
    const arr_t = try s.varargArrayType(t.ty);
    const size_getter = arraySize(b, arr_t) orelse return b.fail(b.cur_span, "a vararg array without its size", .{});
    const size = b.newReg();
    try b.emit(.{ .CallStatic = .{ .dst = size, .func = size_getter, .args = try b.run(&.{arr}), .n_args = 1 } });
    _ = try composerCall(b, "startMovableGroup", &.{ try b.emitConst(.{ .Int = positionalKey(paramSpan(s, t.param)) }), size });
    const size_changed = try changedCall(b, size, s.types.class(s.builtins.int, &.{}, false) catch .none, .stable, true);
    try orIf(b, dirty[k], size_changed, slotBits(different_bits, slot));
    const i = b.newReg();
    try b.emit(.{ .Move = .{ .dst = i, .src = try b.emitConst(.{ .Int = 0 }) } });
    const head = try b.newBlock();
    const each = try b.newBlock();
    const done = try b.newBlock();
    b.terminate(.{ .Goto = head });
    b.switchTo(head);
    const more = b.newReg();
    try b.emit(.{ .BinOp = .{ .dst = more, .op = .Less, .lhs = i, .rhs = size } });
    b.terminate(.{ .Branch = .{ .cond = more, .t = each, .f = done } });
    b.switchTo(each);
    const elem = b.newReg();
    try b.emit(.{ .ArrayGet = .{ .dst = elem, .array = arr, .index = i } });
    const elem_t: Tracked = .{ .ty = t.ty };
    try orIf(b, dirty[k], try probeChanged(b, changed[k], slot, elem, elem_t), slotBits(different_bits, slot));
    try b.emit(.{ .BinOp = .{ .dst = i, .op = .Add, .lhs = i, .rhs = try b.emitConst(.{ .Int = 1 }) } });
    b.terminate(.{ .Goto = head });
    b.switchTo(done);
    _ = try composerCall(b, "endMovableGroup", &.{});
    // No bits at the slot: the same.
    const bits = try bitAnd(b, dirty[k], slotBits(mask_bits, slot));
    try orIf(b, dirty[k], try cmp(b, .Eq, bits, 0), slotBits(same_bits, slot));
}

/// `if (cond) dst = dst or bits`.
fn orIf(b: *Builder, dst: Reg, cond: Reg, bits: i32) Error!void {
    const yes = try b.newBlock();
    const join = try b.newBlock();
    b.terminate(.{ .Branch = .{ .cond = cond, .t = yes, .f = join } });
    b.switchTo(yes);
    try orInto(b, dst, bits);
    b.terminate(.{ .Goto = join });
    b.switchTo(join);
}

fn paramSpan(s: *sema.Sema, p: Sym) span.Span {
    return switch (s.syms.get(p).decl) {
        .param => |pd| pd.?.span,
        else => .{ .file = span.FileId.from(0), .start = 0, .end = 0 },
    };
}

/// The body's statements, then its exit: running off the end or returning
/// goes there with the value.
fn groupedBody(b: *Builder, fb: *const ast.FunctionBody, exit: Exit, realize_all: bool) Error!void {
    const saved = b.compose_exit;
    const saved_open = b.compose_open;
    const saved_marker = b.compose_marker;
    const saved_block = b.compose_block;
    b.compose_exit = exit;
    b.compose_open = 0;
    b.compose_marker = try markerFor(b, declNode(b.p.s, b.owner), b.owner);
    b.compose_block = .{
        .end = switch (fb.*) {
            .Block => |*blk| blk.span.end,
            .Expr => |*e| e.span().end,
        },
        .loop_body = realize_all,
    };
    defer {
        b.compose_exit = saved;
        b.compose_open = saved_open;
        b.compose_marker = saved_marker;
        b.compose_block = saved_block;
    }
    const v: ?Reg = switch (fb.*) {
        .Block => |*blk| blk: {
            _ = try body.lowerStmts(b, blk.stmts);
            break :blk null;
        },
        .Expr => |*e| blk: {
            try b.emit(.{ .Trace = .{ .span = e.span() } });
            break :blk try body.lowerExpr(b, e);
        },
    };
    if (b.terminated()) return;
    if (exit.result) |r| try b.emit(.{ .Move = .{ .dst = r, .src = v orelse try b.unit() } });
    b.terminate(.{ .Goto = exit.block });
}

/// For `lowerReturn`: a return from the composable body being lowered
/// goes to its exit. Null when the body has none.
pub fn returnExit(b: *Builder, target: Sym, v: ?Reg) Error!?ir.BlockId {
    if (target != b.owner) return null;
    const exit = b.compose_exit orelse return null;
    if (exit.result) |r| try b.emit(.{ .Move = .{ .dst = r, .src = v orelse try b.unit() } });
    // From inside inline code, the groups its callees opened close too.
    if (b.regions.items.len != 0 and b.compose_marker != null) {
        try endToMarker(b, b.compose_marker.?);
    } else try closeGroups(b, 0);
    return exit.block;
}

/// `$composer.endToMarker(marker)`: ends every group opened since the
/// marker was read.
pub fn endToMarker(b: *Builder, marker: Reg) Error!void {
    _ = try composerCall(b, "endToMarker", &.{marker});
}

/// The composer's `currentMarker` where a scope starts, when a lambda
/// literal inside `root` returns to `target`: that return may leave groups
/// an inline callee opened, which it ends back to the marker.
pub fn markerFor(b: *Builder, root: ?Root, target: Sym) Error!?Reg {
    if (b.env.composer == null) return null;
    const r = root orelse return null;
    if (!nonLocalReturnTo(b, r, target)) return null;
    return try composerGetter(b, "currentMarker");
}

/// A node and its source range: a subtree whose records follow the node's.
pub const Root = struct { id: ast.NodeId, sp: span.Span };

fn declNode(s: *sema.Sema, f: Sym) ?Root {
    return switch (s.syms.get(f).decl) {
        .function => |fd| if (fd) |x| .{ .id = x.id, .sp = x.span } else null,
        .lambda => |l| if (l) |x| .{ .id = x.id, .sp = x.span } else null,
        else => null,
    };
}

/// Whether a `return` to `target` is written inside a lambda literal in
/// `root`'s subtree. Node ids number a subtree from its root in source
/// order, so each literal's record precedes its body's.
fn nonLocalReturnTo(b: *Builder, root: Root, target: Sym) bool {
    const recs = b.recs;
    const id = root.id.int();
    if (id == 0 or id >= recs.node_count) return false;
    var lambdas: [32]span.Span = undefined;
    var n: usize = 0;
    var i = recs.start[id];
    while (i < recs.refs.len) : (i += 1) {
        const r = recs.refs[i];
        if (r.anchor.start >= root.sp.end and r.anchor.end > root.sp.end) break;
        switch (r.detail) {
            .lambda => |l| if (l.func != target and n < lambdas.len) {
                lambdas[n] = r.anchor;
                n += 1;
            },
            else => {},
        }
        if (r.kind != .return_ or r.target != target) continue;
        for (lambdas[0..n]) |ls| {
            if (ls.start <= r.anchor.start and r.anchor.end <= ls.end) return true;
        }
    }
    return false;
}

/// `endReplaceGroup()` for each replace group open above `depth`, for a
/// jump that leaves them.
pub fn closeGroups(b: *Builder, depth: u32) Error!void {
    var n = b.compose_open -| depth;
    while (n > 0) : (n -= 1) try endReplaceGroupCall(b);
}

/// `endRestartGroup()?.updateScope { c, _ -> f(<the same values>, c, <$changed forced>) }`.
fn endRestartGroup(b: *Builder, f: Sym, changed: []const Reg, defaults: ?*const Defaults) Error!void {
    const s = b.p.s;
    const br = b.p.br;
    const scope = try composerCall(b, "endRestartGroup", &.{});
    const split = try b.branchOnNull(scope);
    const done = try b.newBlock();
    b.switchTo(split.is_null);
    b.terminate(.{ .Goto = done });
    b.switchTo(split.not_null);
    const restart = br.restartOf(f) orelse return b.fail(b.cur_span, "`{s}` has no recompose lambda", .{s.str(s.syms.name(f))});
    const lay = call.layoutOf(b.p, f);
    const n = lay.valueStart() + lay.values;
    const masks: []const Reg = if (defaults) |d| d.masks else &.{};
    const caps = try b.p.a.alloc(Reg, n + changed.len + masks.len);
    for (caps[0..n], 0..) |*r, i| {
        // A defaulted parameter recomposes with the value it was filled with.
        const home: ?Reg = if (defaults) |d| (if (i >= lay.valueStart()) d.homes[i - lay.valueStart()] else null) else null;
        r.* = home orelse try loadParam(b, @intCast(i));
    }
    @memcpy(caps[n .. n + changed.len], changed);
    @memcpy(caps[n + changed.len ..], masks);
    const closure = b.newReg();
    try b.emit(.{ .MakeClosure = .{ .dst = closure, .func = restart, .captures = caps } });
    _ = try interfaceCall(b, "androidx.compose.runtime.ScopeUpdateScope", "updateScope", scope, &.{closure});
    b.terminate(.{ .Goto = done });
    b.switchTo(done);
}

/// A recompose lambda's body: the function again, over the values it was
/// called with, its change bits through `updateChangedFlags`, the first
/// int forced.
pub fn lowerRestart(b: *Builder, f: Sym) Error!void {
    const s = b.p.s;
    const br = b.p.br;
    const lay = call.layoutOf(b.p, f);
    const n = lay.valueStart() + lay.values;
    var run: std.ArrayList(Reg) = .empty;
    var i: u16 = 0;
    while (i < n) : (i += 1) {
        const r = b.newReg();
        try b.emit(.{ .LoadCapture = .{ .dst = r, .idx = i } });
        try run.append(b.p.a, r);
    }
    try run.append(b.p.a, try loadParam(b, 0));
    const update = runtimeFunction(b, "androidx.compose.runtime", "updateChangedFlags") orelse
        return b.fail(b.cur_span, "the compose runtime declares no `updateChangedFlags`", .{});
    var k: u16 = 0;
    while (k < lay.changed) : (k += 1) {
        var changed = b.newReg();
        try b.emit(.{ .LoadCapture = .{ .dst = changed, .idx = n + k } });
        if (k == 0) changed = try orRegs(b, changed, try b.emitConst(.{ .Int = 1 }));
        const flags = b.newReg();
        try b.emit(.{ .CallStatic = .{ .dst = flags, .func = update, .args = try b.run(&.{changed}), .n_args = 1 } });
        try run.append(b.p.a, flags);
    }
    k = 0;
    while (k < lay.defaults) : (k += 1) {
        const mask = b.newReg();
        try b.emit(.{ .LoadCapture = .{ .dst = mask, .idx = n + lay.changed + k } });
        try run.append(b.p.a, mask);
    }
    const target = br.funcOfOpt(f) orelse return b.fail(b.cur_span, "`{s}` has no id", .{s.str(s.syms.name(f))});
    try b.emit(.{ .CallStatic = .{ .dst = b.newReg(), .func = target, .args = try b.run(run.items), .n_args = @intCast(run.items.len) } });
    b.terminate(.{ .Return = try b.unit() });
}

// ------------------------------------------------------ skip calculus --

/// The getter of an array class's `size`.
fn arraySize(b: *Builder, arr_t: sema.TypeId) ?ir.FuncId {
    const s = b.p.s;
    const cls = s.types.classSym(arr_t);
    if (cls == .none) return null;
    const n = s.names.lookup("size") orelse return null;
    for (sema.symbols.Symbols.members(&s.syms.classInfo(cls).members, n)) |p| {
        if (s.syms.kind(p) != .property) continue;
        const g = b.p.br.getter_of[p.int()];
        if (g.int() != bridge.NONE) return g;
    }
    return null;
}

fn orInto(b: *Builder, dst: Reg, bits: i32) Error!void {
    try b.emit(.{ .BinOp = .{ .dst = dst, .op = .Or, .lhs = dst, .rhs = try b.emitConst(.{ .Int = bits }) } });
}

fn bitAnd(b: *Builder, v: Reg, bits: i32) Error!Reg {
    const dst = b.newReg();
    try b.emit(.{ .BinOp = .{ .dst = dst, .op = .And, .lhs = v, .rhs = try b.emitConst(.{ .Int = bits }) } });
    return dst;
}

/// `$composer.changed(v)` through the overload for `ty`'s primitive, or
/// `changedInstance` for a value compared by identity: one of unstable
/// type, or, when `instance_fns`, a function value.
fn changedCall(b: *Builder, v: Reg, ty: sema.TypeId, st: Stability, instance_fns: bool) Error!Reg {
    const s = b.p.s;
    if (ty != .none and !s.types.isNullable(ty)) {
        const cls = s.types.classSym(ty);
        const composer_cls = s.classByFqn("androidx.compose.runtime.Composer");
        if (cls != .none and isPrimitive(s, cls) and composer_cls != .none and
            try memberFunction(s, composer_cls, "changed", 1, cls) != null)
        {
            return composerCallTyped(b, "changed", &.{v}, cls);
        }
    }
    const by_identity = st != .stable or (instance_fns and ty != .none and isFunctionClass(s, s.types.classSym(ty)));
    return composerCall(b, if (by_identity) "changedInstance" else "changed", &.{v});
}

fn isPrimitive(s: *sema.Sema, cls: Sym) bool {
    const bi = s.builtins;
    inline for (.{ "boolean", "char", "byte", "short", "int", "long", "float", "double" }) |f| {
        if (@field(bi, f) == cls) return true;
    }
    return false;
}

/// How the Compose compiler judges a type's values: stable ones compare
/// by `equals`, unstable ones by identity, and for uncertain ones (an
/// interface, a type parameter, an open class) the caller says which.
pub const Stability = enum {
    stable,
    unstable,
    uncertain,

    fn plus(x: Stability, y: Stability) Stability {
        if (x == .unstable or y == .unstable) return .unstable;
        if (x == .uncertain or y == .uncertain) return .uncertain;
        return .stable;
    }
};

/// A type's stability: primitives, `String`, `Unit` and function types
/// are stable, a type parameter uncertain, a class as `classStability`.
pub fn typeStability(b: *Builder, ty: sema.TypeId, depth: u8) Error!Stability {
    const s = b.p.s;
    if (ty == .none) return .uncertain;
    return switch (s.types.get(ty)) {
        .class => |c| blk: {
            if (isPrimitive(s, c.sym) or c.sym == s.builtins.string or c.sym == s.builtins.unit) break :blk .stable;
            if (isFunctionClass(s, c.sym)) break :blk .stable;
            break :blk try classStability(b, c.sym, c.args, depth);
        },
        .param => .uncertain,
        else => .unstable,
    };
}

/// A class's stability over the type arguments `args`: stable when it or
/// a supertype is marked stable, an enum, an object, or a known stable
/// construct; uncertain for an interface; otherwise its `val`s' types
/// together (a `var` makes it unstable), starting uncertain for a class
/// that is not final, and its superclass's unless that is uncertain.
pub fn classStability(b: *Builder, cls: Sym, args: []const sema.types.Arg, depth: u8) Error!Stability {
    const s = b.p.s;
    if (depth > 8) return .unstable;
    if (s.syms.kind(cls) != .class) return .unstable;
    if (try stableMarkedDescendant(s, cls, 0)) return .stable;
    const info = s.syms.classInfo(cls);
    switch (info.kind) {
        .enum_class, .enum_entry, .object, .companion => return .stable,
        else => {},
    }
    if (knownStableMask(s, cls)) |mask| {
        var st: Stability = .stable;
        for (args, 0..) |a, i| {
            if (i < 32 and mask & (@as(u32, 1) << @intCast(i)) != 0) st = st.plus(if (a.ty == .none) .unstable else try typeStability(b, a.ty, depth + 1));
        }
        return st;
    }
    if (info.kind == .interface or info.kind == .annotation) return .uncertain;
    var st: Stability = if (s.syms.flags(cls).modality == .final) .stable else .uncertain;
    var it = info.members.iterator();
    while (it.next()) |e| for (e.value_ptr.items) |m| {
        if (s.syms.kind(m) != .property or s.syms.owner(m) != cls) continue;
        if (!hasBackingField(b, m)) continue;
        const delegated = s.syms.propertyInfo(m).has_delegate;
        if (s.syms.flags(m).mutable and !delegated) return .unstable;
        const t = if (delegated) try delegateType(b, m) else try sema.headers.propertyType(s, m);
        st = st.plus(try memberStability(b, info.type_params, args, t, depth + 1));
    };
    for (try sema.headers.supertypes(s, cls)) |sup| {
        const sc = s.types.classSym(sup);
        if (sc == .none or sc == s.builtins.any or s.syms.kind(sc) != .class) continue;
        if (s.syms.classInfo(sc).kind == .interface) continue;
        const sst = try classStability(b, sc, s.types.argsOf(sup), depth + 1);
        if (sst != .uncertain) st = st.plus(sst);
    }
    return st;
}

/// A member's type stability, the class's own type parameters read as the
/// arguments it was given.
fn memberStability(b: *Builder, params: []const Sym, args: []const sema.types.Arg, t: sema.TypeId, depth: u8) Error!Stability {
    const s = b.p.s;
    if (t != .none) switch (s.types.get(t)) {
        .param => |p| for (params, 0..) |tp, i| {
            if (tp != p.sym) continue;
            if (i < args.len and args[i].ty != .none) return typeStability(b, args[i].ty, depth);
            return .uncertain;
        },
        else => {},
    };
    return typeStability(b, t, depth);
}

/// Whether a property stores a value: it has a field or a delegate.
fn hasBackingField(b: *Builder, p: Sym) bool {
    return b.p.s.syms.propertyInfo(p).has_delegate or b.p.br.fieldOf(p) != null;
}

/// The type of a delegated property's delegate, from its file's records.
fn delegateType(b: *Builder, p: Sym) Error!sema.TypeId {
    const s = b.p.s;
    // A delegate's type is in the records of the build that lowers it.
    const pd = switch (s.syms.get(p).decl) {
        .property => |pd| pd.?,
        else => return .none,
    };
    const d = pd.delegate orelse return .none;
    const file = s.syms.get(p).file;
    if (file >= b.p.br.records.len) return .none;
    return sema.output.exprType(&b.p.br.records[file], d.id());
}

fn stableMarkedDescendant(s: *sema.Sema, cls: Sym, depth: u8) Error!bool {
    if (depth > 16) return false;
    if (try stableMarked(s, cls)) return true;
    for (try sema.headers.supertypes(s, cls)) |sup| {
        const sc = s.types.classSym(sup);
        if (sc == .none or sc == s.builtins.any or s.syms.kind(sc) != .class) continue;
        if (try stableMarkedDescendant(s, sc, depth + 1)) return true;
    }
    return false;
}

/// The type-argument mask of a construct the Compose compiler knows to be
/// stable (`Pair`, `Result`, ...): the arguments whose stability counts.
fn knownStableMask(s: *sema.Sema, cls: Sym) ?u32 {
    const fqn = s.str(s.syms.classInfo(cls).fqn);
    const known = .{
        .{ "kotlin.Pair", 0b11 },                           .{ "kotlin.Triple", 0b111 },
        .{ "kotlin.Comparator", 0b1 },                      .{ "kotlin.Result", 0b1 },
        .{ "kotlin.ranges.ClosedRange", 0b1 },              .{ "kotlin.ranges.ClosedFloatingPointRange", 0b1 },
        .{ "kotlinx.collections.immutable.ImmutableCollection", 0b1 }, .{ "kotlinx.collections.immutable.ImmutableList", 0b1 },
        .{ "kotlinx.collections.immutable.ImmutableSet", 0b1 }, .{ "kotlinx.collections.immutable.ImmutableMap", 0b11 },
        .{ "kotlinx.collections.immutable.PersistentCollection", 0b1 }, .{ "kotlinx.collections.immutable.PersistentList", 0b1 },
        .{ "kotlinx.collections.immutable.PersistentSet", 0b1 }, .{ "kotlinx.collections.immutable.PersistentMap", 0b11 },
        .{ "kotlin.coroutines.EmptyCoroutineContext", 0 },
    };
    inline for (known) |k| if (std.mem.eql(u8, fqn, k[0])) return k[1];
    return null;
}

fn isFunctionClass(s: *sema.Sema, cls: Sym) bool {
    var it = s.function_classes.valueIterator();
    while (it.next()) |c| if (c.* == cls) return true;
    var sit = s.suspend_function_classes.valueIterator();
    while (sit.next()) |c| if (c.* == cls) return true;
    return false;
}

/// Marked `@Stable`, `@Immutable`, or with an annotation itself marked
/// `@StableMarker`.
fn stableMarked(s: *sema.Sema, cls: Sym) Error!bool {
    switch (s.syms.get(cls).decl) {
        .class, .object => {},
        else => return false,
    }
    const marker = s.classByFqn("androidx.compose.runtime.StableMarker");
    for (try sema.headers.annotationClasses(s, cls, .decl)) |ac| {
        if (ac == .none) continue;
        if (ac == marker) return true;
        if (s.syms.get(ac).decl != .class) continue;
        if (try sema.headers.hasAnnotation(s, ac, .decl, marker)) return true;
    }
    return false;
}

/// Whether class `cls` carries `androidx.compose.runtime.<name>`.
fn annotatedClass(s: *sema.Sema, cls: Sym, comptime name: []const u8) Error!bool {
    if (s.syms.get(cls).decl != .class) return false;
    return sema.headers.hasAnnotation(s, cls, .decl, s.classByFqn("androidx.compose.runtime." ++ name));
}

// ------------------------------------------------------------ lambdas --

/// A composable literal's closure as the runtime's composable lambda. One
/// capturing nothing is a singleton, as the Compose compiler keeps it:
/// `composableLambdaInstance(key, false, closure)` made once. Otherwise, in
/// a composable scope `rememberComposableLambda(key, true, closure)`,
/// remembered in the caller's group so unchanged content stays the same
/// instance; elsewhere `composableLambdaInstance(key, true, closure)`. The
/// closure itself where the runtime declares neither.
pub fn wrapLambda(b: *Builder, closure: Reg, sp: span.Span, f: Sym) Error!Reg {
    const br = b.p.br;
    // A public inline function's body is its callers', which keep no
    // singleton of it.
    const s = b.p.s;
    const public_inline = s.syms.kind(b.owner) == .function and s.syms.flags(b.owner).inline_ and
        (s.syms.flags(b.owner).visibility == .public or s.syms.flags(b.owner).visibility == .protected);
    if (!public_inline) if (br.singletonOf(f)) |st| if (br.funcOfOpt(f)) |id| if (br.capturesOf(id).len == 0) {
        if (runtimeFunction(b, "androidx.compose.runtime.internal", "composableLambdaInstance")) |make| {
            return singleton(b, st, make, closure, sp);
        }
    };
    const in_scope = b.env.composer != null;
    const factory = (if (in_scope)
        runtimeFunction(b, "androidx.compose.runtime.internal", "rememberComposableLambda")
    else
        runtimeFunction(b, "androidx.compose.runtime.internal", "composableLambdaInstance")) orelse return closure;
    var args: std.ArrayList(Reg) = .empty;
    try args.append(b.p.a, try b.emitConst(.{ .Int = positionalKey(sp) }));
    try args.append(b.p.a, try b.emitConst(.{ .Bool = true }));
    try args.append(b.p.a, closure);
    if (in_scope) {
        // The key and `tracked` are constants: static to it.
        try args.append(b.p.a, try composer(b));
        try args.appendSlice(b.p.a, try changedInts(b, &.{ .{ .state = .static }, .{ .state = .static }, .{} }));
    }
    const dst = b.newReg();
    try b.emit(.{ .CallStatic = .{ .dst = dst, .func = factory, .args = try b.run(args.items), .n_args = @intCast(args.items.len) } });
    return dst;
}

/// `<static> ?: composableLambdaInstance(key, false, closure)`, kept.
fn singleton(b: *Builder, st: ir.StaticId, make: ir.FuncId, closure: Reg, sp: span.Span) Error!Reg {
    const result = b.newReg();
    try b.emit(.{ .LoadStatic = .{ .dst = result, .static = st } });
    const split = try b.branchOnNull(result);
    const join = try b.newBlock();
    b.switchTo(split.is_null);
    const args = [_]Reg{ try b.emitConst(.{ .Int = positionalKey(sp) }), try b.emitConst(.{ .Bool = false }), closure };
    const v = b.newReg();
    try b.emit(.{ .CallStatic = .{ .dst = v, .func = make, .args = try b.run(&args), .n_args = 3 } });
    try b.emit(.{ .StoreStatic = .{ .static = st, .value = v } });
    try b.emit(.{ .Move = .{ .dst = result, .src = v } });
    b.terminate(.{ .Goto = join });
    b.switchTo(split.not_null);
    b.terminate(.{ .Goto = join });
    b.switchTo(join);
    return result;
}

/// A composable literal's body, which the runtime's composable lambda runs
/// in its own group. Returning `Unit` with no parameter of unstable type,
/// it skips like a restartable function when nothing it reads changed and
/// the lambda is the same. Its returns close the replace groups they
/// leave.
pub fn lowerLambdaBody(b: *Builder, f: Sym, rec: *const records.LambdaRec, stmts: []const ast.Stmt, unit_result: bool) Error!void {
    const exit = try b.newBlock();
    const result = b.newReg();
    const saved = b.compose_exit;
    const saved_open = b.compose_open;
    const saved_marker = b.compose_marker;
    const saved_block = b.compose_block;
    b.compose_exit = .{ .block = exit, .result = result };
    b.compose_open = 0;
    b.compose_marker = try markerFor(b, declNode(b.p.s, b.owner), b.owner);
    b.compose_block = .{ .end = if (declNode(b.p.s, b.owner)) |r| r.sp.end else 0 };
    defer {
        b.compose_exit = saved;
        b.compose_open = saved_open;
        b.compose_marker = saved_marker;
        b.compose_block = saved_block;
    }
    if (b.env.changed.len == 0) return b.fail(b.cur_span, "a composable lambda without its `$changed`", .{});
    const tracked = try lambdaTracked(b, f, rec);
    var skippable = unit_result;
    for (tracked) |t| {
        if (!t.self and try typeStability(b, t.ty, 0) == .unstable) skippable = false;
    }
    const gate: Gate = if (skippable) try Gate.open(b, tracked) else .{ .dirty = b.env.changed };
    b.compose_tracked = tracked;
    b.compose_dirty = gate.dirty;
    b.compose_dirty_var = skippable;
    b.compose_remember = true;
    const v = try body.lowerStmts(b, stmts);
    if (!b.terminated()) {
        try b.emit(.{ .Move = .{ .dst = result, .src = if (unit_result) try b.unit() else v orelse try b.unit() } });
        b.terminate(.{ .Goto = exit });
    }
    if (skippable) {
        const skipped = try b.newBlock();
        try gate.close(b, tracked, skipped, null);
        b.switchTo(skipped);
        try b.emit(.{ .Move = .{ .dst = result, .src = try b.unit() } });
        b.terminate(.{ .Goto = exit });
    }
    b.switchTo(exit);
    b.terminate(.{ .Return = result });
}

// --------------------------------------------------------------- loops --

/// The block scope a coalescable group answers to: a composable call after
/// the group and before `end` realizes it, and a loop body realizes every
/// group directly in it.
pub const BlockScope = struct { end: u32 = 0, loop_body: bool = false };

/// A loop's groups, as the Compose compiler places them when the loop
/// composes: one around the whole loop when a composable call follows it
/// in its block or the block is a loop body, and with a `continue` of its
/// own, one around its condition and one around each iteration.
pub const LoopGroups = struct {
    outer: bool = false,
    per_iteration: bool = false,

    pub fn begin(b: *Builder, e: *const ast.Expr, body_expr: ?*const ast.Expr, label: ?[]const u8) Error!LoopGroups {
        if (!composes(b, e)) return .{};
        const g: LoopGroups = .{
            .outer = b.compose_block.loop_body or composesAfter(b, e),
            .per_iteration = if (body_expr) |x| continuesLoop(x, label, true) else false,
        };
        if (g.outer) try startReplaceGroup(b, e.span());
        return g;
    }

    pub fn end(g: LoopGroups, b: *Builder) Error!void {
        if (!g.outer or b.terminated()) return;
        try endReplaceGroupCall(b);
        b.compose_open -= 1;
    }
};

/// A call of an inline function that does not compose itself but whose
/// literals do, as the Compose compiler groups it: like a loop, one group
/// around the whole call when a composable call follows it in its block or
/// that block realizes all its groups, every group inside its literals
/// realized, and each literal's body in a group of its own when the
/// function takes more than one literal inline.
pub const InlineGroups = struct {
    outer: bool = false,
    saved_force: bool = false,
    active: bool = false,

    pub fn begin(b: *Builder, rec: *const records.CallRec, e: ?*const ast.Expr, literals: []const ?*const ast.Expr, inline_params: usize) Error!InlineGroups {
        if (b.env.composer == null or b.compose_explicit or composableFunction(b.p.s, rec.callee)) return .{};
        const composing = for (literals) |lit| {
            if (lit) |l| if (composes(b, l)) break true;
        } else false;
        if (!composing) return .{};
        const call_expr = e orelse return .{};
        const g: InlineGroups = .{
            .outer = b.compose_block.loop_body or composesAfter(b, call_expr),
            .saved_force = b.compose_lambda_groups,
            .active = true,
        };
        if (g.outer) try startReplaceGroup(b, call_expr.span());
        b.compose_lambda_groups = inline_params > 1;
        return g;
    }

    pub fn end(g: InlineGroups, b: *Builder) Error!void {
        if (!g.active) return;
        b.compose_lambda_groups = g.saved_force;
        if (!g.outer) return;
        b.compose_open -= 1;
        if (!b.terminated()) try endReplaceGroupCall(b);
    }
};

/// Whether a composable call or read is written after `e` and before the
/// end of the block scope it is in.
fn composesAfter(b: *Builder, e: *const ast.Expr) bool {
    const s = b.p.s;
    const recs = b.recs;
    const id = e.id().int();
    if (id == 0 or id >= recs.node_count) return false;
    const from = e.span().end;
    const to = b.compose_block.end;
    var i = recs.start[id];
    while (i < recs.refs.len) : (i += 1) {
        const r = recs.refs[i];
        if (r.anchor.start < from) continue;
        if (r.anchor.start >= to) break;
        switch (r.detail) {
            .call => |c| if (c.composable) return true,
            else => {},
        }
        if (r.kind == .read and r.target != .none and composableGetter(s, r.target) and !isCurrentComposer(s, r.target)) return true;
    }
    return false;
}

/// Whether `e` holds a `continue` of the loop whose body it is: one naming
/// `label`, or an unlabeled one outside any nested loop (`own`).
fn continuesLoop(e: *const ast.Expr, label: ?[]const u8, own: bool) bool {
    return switch (e.*) {
        .Continue => |c| if (c.label) |l| (label != null and std.mem.eql(u8, l.name, label.?)) else own,
        .Block => |*blk| stmtsContinue(blk.stmts, label, own),
        .If => |x| continuesLoop(x.cond, label, own) or continuesLoop(x.then_branch, label, own) or
            (if (x.else_branch) |eb| continuesLoop(eb, label, own) else false),
        .When => |w| blk: {
            if (w.subject) |sj| if (continuesLoop(sj, label, own)) break :blk true;
            for (w.branches) |*br| if (continuesLoop(&br.body, label, own)) break :blk true;
            break :blk false;
        },
        .While => |w| continuesLoop(w.cond, label, own) or continuesLoop(w.body, label, false),
        .DoWhile => |w| (if (w.body) |bd| continuesLoop(bd, label, false) else false) or continuesLoop(w.cond, label, own),
        .For => |f| continuesLoop(f.iter, label, own) or continuesLoop(f.body, label, false),
        .Labeled => |x| continuesLoop(x.expr, label, own),
        .Call => |c| blk: {
            if (continuesLoop(c.callee, label, own)) break :blk true;
            for (c.args) |*a| if (continuesLoop(a, label, own)) break :blk true;
            break :blk false;
        },
        .Index => |x| blk: {
            if (continuesLoop(x.receiver, label, own)) break :blk true;
            for (x.args) |*a| if (continuesLoop(a, label, own)) break :blk true;
            break :blk false;
        },
        .Binary => |x| continuesLoop(x.lhs, label, own) or continuesLoop(x.rhs, label, own),
        .Unary => |x| continuesLoop(x.expr, label, own),
        .Postfix => |x| continuesLoop(x.expr, label, own),
        .As => |x| continuesLoop(x.expr, label, own),
        .IsCheck => |x| continuesLoop(x.expr, label, own),
        .Spread => |x| continuesLoop(x.expr, label, own),
        .Member => |m| continuesLoop(m.receiver, label, own),
        .Return => |r| if (r.value) |v| continuesLoop(v, label, own) else false,
        .Throw => |t| continuesLoop(t.value, label, own),
        .Try => |t| blk: {
            if (stmtsContinue(t.body.stmts, label, own)) break :blk true;
            for (t.catches) |*c| if (stmtsContinue(c.body.stmts, label, own)) break :blk true;
            if (t.finally) |*f| if (stmtsContinue(f.stmts, label, own)) break :blk true;
            break :blk false;
        },
        // An inline lambda's body can continue the loop it is written in.
        .Lambda => |l| stmtsContinue(l.body.stmts, label, own),
        .StringTemplate => |t| for (t.parts) |part| switch (part) {
            .Interp => |x| if (continuesLoop(x, label, own)) break true,
            else => {},
        } else false,
        else => false,
    };
}

fn stmtsContinue(stmts: []const ast.Stmt, label: ?[]const u8, own: bool) bool {
    for (stmts) |*st| {
        const hit = switch (st.*) {
            .Expr => |*x| continuesLoop(x, label, own),
            .Assign => |a| continuesLoop(&a.target, label, own) or continuesLoop(&a.value, label, own),
            .Decl => |d| switch (d.*) {
                .Property => |p| if (p.init) |x| continuesLoop(x, label, own) else false,
                else => false,
            },
            .DestructuringDecl => |dd| continuesLoop(&dd.init, label, own),
        };
        if (hit) return true;
    }
    return false;
}

// ----------------------------------------------------------- remembering --

/// Whether literal `lit`, over function `f`, is remembered where it is
/// lowered, as the Compose compiler memoizes lambdas: in a scope that can
/// remember (a composable body, or an inline lambda in one, outside any
/// `try`), not as an inline argument, not `@DontMemoize`, and capturing
/// no `var` and no inline lambda parameter.
pub fn memoizes(b: *Builder, lit: *const ast.Expr, f: Sym) Error!bool {
    if (!b.compose_remember or b.env.composer == null or b.unmemoized == lit) return false;
    if (runtimeGetter(b, "androidx.compose.runtime.Composer", "Empty") == null) return false;
    const s = b.p.s;
    const br = b.p.br;
    const dont = s.classByFqn("androidx.compose.runtime.DontMemoize");
    if (dont != .none) {
        if (lit.* == .Lambda and try sema.headers.annotatedWith(s, .{ .decl = f, .file = b.file }, lit.Lambda.annotations, dont)) return false;
        if (try annotated(s, b.owner, "DontMemoize")) return false;
    }
    const id = br.funcOfOpt(f) orelse return false;
    for (br.capturesOf(id)) |k| switch (k) {
        .local => |l| if (br.isCell(l) or try inlineLambdaParam(s, l)) return false,
        .receiver => {},
    };
    return true;
}

/// A parameter of an inline function that takes a lambda inline.
fn inlineLambdaParam(s: *sema.Sema, l: Sym) Error!bool {
    if (s.syms.kind(l) != .value_param) return false;
    const owner = s.syms.owner(l);
    if (owner == .none or !s.syms.flags(owner).inline_ or s.syms.flags(l).no_inline) return false;
    const t = try sema.headers.paramType(s, l);
    return t != .none and isFunctionClass(s, s.types.classSym(t));
}

/// A remember key: its value, what the scope knows of it, and its type.
const Key = struct { value: Reg, meta: Meta = .{}, ty: sema.TypeId = .none };

/// The closure over literal `f`, remembered over its captures.
pub fn memoizedClosure(b: *Builder, f: Sym) Error!Reg {
    return remembered(b, try captureKeys(b, f), true, .{ .closure = f });
}

/// A fun interface's wrapper of `value`, the closure over literal `f`,
/// remembered over the literal's captures.
pub fn memoizedSam(b: *Builder, value: Reg, iface: Sym, f: Sym) Error!Reg {
    return remembered(b, try captureKeys(b, f), true, .{ .sam = .{ .value = value, .iface = iface } });
}

/// `Iface { ... }` remembered over the literal's captures.
pub fn memoizedSamCtor(b: *Builder, rec: *const records.CallRec, ops: call.Operands, lit: *const ast.Expr) Error!Reg {
    const f = (try b.lambda(lit.id())).func;
    return remembered(b, try captureKeys(b, f), true, .{ .sam_ctor = .{ .rec = rec, .ops = ops, .lit = lit } });
}

fn captureKeys(b: *Builder, f: Sym) Error![]const Key {
    const s = b.p.s;
    const br = b.p.br;
    const id = br.funcOfOpt(f) orelse return b.fail(b.cur_span, "a literal without an id", .{});
    const caps = br.capturesOf(id);
    const vals = try env.materializeCaptures(b, caps);
    const keys = try b.p.a.alloc(Key, caps.len);
    for (caps, vals, keys) |c, v, *k| k.* = switch (c) {
        .local => |l| .{
            .value = v,
            .meta = if (trackedSlot(b, env.symKey(l))) |slot| .{ .state = .forwarded, .from = slot } else .{},
            .ty = switch (s.syms.kind(l)) {
                .value_param => try sema.headers.paramType(s, l),
                .local => s.syms.localInfo(l).ty,
                else => .none,
            },
        },
        .receiver => |r| .{
            .value = v,
            .meta = try receiverMeta(b, .{ .implicit = .{ .kind = r.kind, .owner = r.owner } }, null),
            .ty = switch (r.kind) {
                .class_this, .object => s.syms.classInfo(r.owner).self_type,
                .extension => if (s.syms.kind(r.owner) == .property) s.syms.propertyInfo(r.owner).receiver else s.syms.functionInfo(r.owner).receiver,
                else => .none,
            },
        },
    };
    return keys;
}

/// `androidx.compose.runtime.remember`, which the Compose compiler lowers
/// itself.
pub fn isRemember(s: *sema.Sema, f: Sym) bool {
    return s.syms.kind(f) == .function and s.syms.flags(f).inline_ and isRuntimeFunction(s, f, "androidx.compose.runtime", "remember");
}

/// `remember(keys...) { calculation }` as the Compose compiler has it: the
/// keys, then the value remembered over them. Null when a key is spread or
/// the calculation is no literal, which the runtime's own `remember` does.
pub fn lowerRemember(b: *Builder, rec: *const records.CallRec, ops: call.Operands) Error!?Reg {
    const s = b.p.s;
    const a = b.p.a;
    const params = s.syms.functionInfo(rec.callee).params;
    var calc: ?*const ast.Expr = null;
    var exprs: std.ArrayList(*const ast.Expr) = .empty;
    for (rec.args, 0..) |src, i| {
        const is_calc = i < params.len and std.mem.eql(u8, s.str(s.syms.name(params[i])), "calculation");
        switch (src) {
            .arg => |k| {
                const e = (if (k < ops.exprs.len) ops.exprs[k] else null) orelse return null;
                if (is_calc) calc = e else try exprs.append(a, e);
            },
            .vararg => |parts| for (parts) |part| {
                if (part.spread) return null;
                try exprs.append(a, (if (part.arg < ops.exprs.len) ops.exprs[part.arg] else null) orelse return null);
            },
            .default, .receiver => return null,
        }
    }
    const c = calc orelse return null;
    if (lambdaLiteral(c) == null) return null;
    const keys = try a.alloc(Key, exprs.items.len);
    for (exprs.items, keys) |e, *k| k.* = .{ .value = try body.lowerExpr(b, e), .meta = try exprMeta(b, e), .ty = b.exprType(e.id()) };
    return try remembered(b, keys, false, .{ .calc = c });
}

fn lambdaLiteral(e: *const ast.Expr) ?*const ast.Expr {
    var x = e;
    while (x.* == .Labeled) x = x.Labeled.expr;
    return switch (x.*) {
        .Lambda, .AnonFun => x,
        else => null,
    };
}

const Make = union(enum) {
    closure: Sym,
    sam: struct { value: Reg, iface: Sym },
    sam_ctor: struct { rec: *const records.CallRec, ops: call.Operands, lit: *const ast.Expr },
    calc: *const ast.Expr,
};

/// `$composer.cache(<a key changed>) { <make> }`: the remembered value,
/// or a new one when a key changed or nothing is remembered yet.
fn remembered(b: *Builder, keys: []const Key, memoized: bool, make: Make) Error!Reg {
    const invalid = try rememberInvalid(b, keys, memoized);
    const stored = try composerCall(b, "rememberedValue", &.{});
    const empty = try composerEmpty(b);
    const unset = b.newReg();
    try b.emit(.{ .BinOp = .{ .dst = unset, .op = .IdentEq, .lhs = stored, .rhs = empty } });
    const again = try orRegs(b, invalid, unset);
    const result = b.newReg();
    const make_blk = try b.newBlock();
    const keep_blk = try b.newBlock();
    const join = try b.newBlock();
    b.terminate(.{ .Branch = .{ .cond = again, .t = make_blk, .f = keep_blk } });
    b.switchTo(make_blk);
    const v = switch (make) {
        .closure => |f| try lambda.closureOf(b, f),
        .sam => |x| try lambda.samWrap(b, x.value, x.iface),
        .sam_ctor => |x| blk: {
            const saved = b.unmemoized;
            b.unmemoized = x.lit;
            defer b.unmemoized = saved;
            break :blk try call.emitCall(b, x.rec, x.ops);
        },
        // The calculation may not compose, so nothing in it remembers.
        .calc => |c| blk: {
            const saved = b.compose_remember;
            b.compose_remember = false;
            defer b.compose_remember = saved;
            break :blk try lambda.lowerInPlace(b, c, &.{});
        },
    };
    if (!b.terminated()) {
        _ = try composerCall(b, "updateRememberedValue", &.{v});
        try b.emit(.{ .Move = .{ .dst = result, .src = v } });
        b.terminate(.{ .Goto = join });
    }
    b.switchTo(keep_blk);
    try b.emit(.{ .Move = .{ .dst = result, .src = stored } });
    b.terminate(.{ .Goto = join });
    b.switchTo(join);
    return result;
}

/// Whether any key changed, as the Compose compiler's intrinsic remember
/// asks: a static key never does; a parameter passed on whose bits the
/// skip gate settled is different by its bits, compared only when its
/// value may be unstable; one with uncertain bits is compared when they
/// are uncertain or unstable; anything else is compared.
fn rememberInvalid(b: *Builder, keys: []const Key, memoized: bool) Error!Reg {
    var invalid: ?Reg = null;
    for (keys) |k| {
        const one = (try keyChanged(b, k, memoized)) orelse continue;
        invalid = if (invalid) |x| try orRegs(b, x, one) else one;
    }
    return invalid orelse b.emitConst(.{ .Bool = false });
}

fn keyChanged(b: *Builder, k: Key, memoized: bool) Error!?Reg {
    if (k.meta.state == .static) return null;
    const st = try typeStability(b, k.ty, 0);
    if (k.meta.state != .forwarded or st == .unstable or k.meta.from / 10 >= b.compose_dirty.len) return try keyCompare(b, k, st, memoized);
    const slot = k.meta.from;
    const d = b.compose_dirty[slot / 10];
    const nonstatic_default = slot < b.compose_tracked.len and b.compose_tracked[slot].nonstatic_default;
    if (b.compose_dirty_var and !nonstatic_default) {
        // `$dirty and 0b111 == different`, or compared when marked unstable.
        const different = try cmp(b, .Eq, try bitAnd(b, d, slotBits(mask_bits, slot)), slotBits(different_bits, slot));
        if (st == .stable) return different;
        const marked = try cmp(b, .NotEq, try bitAnd(b, d, slotBits(unstable_bit, slot)), 0);
        return try orRegs(b, different, try keyCompareIf(b, marked, k, st, memoized));
    }
    // `($changed and 0b111 xor 0b011) > 0b010`: uncertain or unstable.
    const x = b.newReg();
    try b.emit(.{ .BinOp = .{ .dst = x, .op = .Xor, .lhs = try bitAnd(b, d, slotBits(mask_bits, slot)), .rhs = try b.emitConst(.{ .Int = slotBits(static_bits, slot) }) } });
    const unsettled = try cmp(b, .Greater, x, slotBits(different_bits, slot));
    const different = try cmp(b, .Eq, try bitAnd(b, d, slotBits(static_bits, slot)), slotBits(different_bits, slot));
    return try orRegs(b, try keyCompareIf(b, unsettled, k, st, memoized), different);
}

/// `<cond> && <compare>`, comparing only when `cond` holds.
fn keyCompareIf(b: *Builder, cond: Reg, k: Key, st: Stability, memoized: bool) Error!Reg {
    const r = b.newReg();
    const yes = try b.newBlock();
    const no = try b.newBlock();
    const join = try b.newBlock();
    b.terminate(.{ .Branch = .{ .cond = cond, .t = yes, .f = no } });
    b.switchTo(yes);
    try b.emit(.{ .Move = .{ .dst = r, .src = try keyCompare(b, k, st, memoized) } });
    b.terminate(.{ .Goto = join });
    b.switchTo(no);
    try b.emit(.{ .Move = .{ .dst = r, .src = try b.emitConst(.{ .Bool = false }) } });
    b.terminate(.{ .Goto = join });
    b.switchTo(join);
    return r;
}

/// A key compared: a remembered lambda's unstable capture by identity,
/// anything else by `equals`.
fn keyCompare(b: *Builder, k: Key, st: Stability, memoized: bool) Error!Reg {
    return changedCall(b, k.value, k.ty, if (memoized) st else .stable, false);
}

/// `Composer.Empty`, what `rememberedValue` answers when nothing is
/// remembered yet.
fn composerEmpty(b: *Builder) Error!Reg {
    const g = runtimeGetter(b, "androidx.compose.runtime.Composer", "Empty") orelse
        return b.fail(b.cur_span, "the compose runtime declares no `Composer.Empty`", .{});
    const obj = try env.loadObject(b, g.owner);
    const dst = b.newReg();
    try b.emit(.{ .CallStatic = .{ .dst = dst, .func = g.func, .args = try b.run(&.{obj}), .n_args = 1 } });
    return dst;
}

/// The getter of property `name` of class `cls_fqn`'s companion, and the
/// companion.
const Getter = struct { func: ir.FuncId, owner: Sym };

fn runtimeGetter(b: *Builder, comptime cls_fqn: []const u8, comptime name: []const u8) ?Getter {
    const s = b.p.s;
    const cls = s.classByFqn(cls_fqn);
    if (cls == .none) return null;
    const comp = s.syms.classInfo(cls).companion;
    if (comp == .none) return null;
    const n = s.names.lookup(name) orelse return null;
    for (sema.symbols.Symbols.members(&s.syms.classInfo(comp).members, n)) |p| {
        if (s.syms.kind(p) != .property) continue;
        if (p.int() >= b.p.br.getter_of.len) continue;
        const g = b.p.br.getter_of[p.int()];
        if (g.int() == bridge.NONE) continue;
        return .{ .func = g, .owner = comp };
    }
    return null;
}

/// Whether parameter `p` takes a lambda that may not compose.
pub fn disallowsComposableCalls(s: *sema.Sema, p: Sym) Error!bool {
    if (s.syms.get(p).decl != .param) return false;
    return sema.headers.hasAnnotation(s, p, .written_type, s.classByFqn("androidx.compose.runtime.DisallowComposableCalls"));
}

// ------------------------------------------------------------- groups --

/// Whether `e` composes in a composable scope: a composable call or
/// composable getter read anywhere in it. Node ids number a subtree in
/// source order from its root, so its records follow the root's and end
/// where the source passes its end.
pub fn composes(b: *Builder, e: *const ast.Expr) bool {
    if (b.env.composer == null or b.compose_explicit) return false;
    const s = b.p.s;
    const recs = b.recs;
    const id = e.id().int();
    if (id == 0 or id >= recs.node_count) return false;
    const sp = e.span();
    var i = recs.start[id];
    while (i < recs.refs.len) : (i += 1) {
        const r = recs.refs[i];
        if (r.anchor.start >= sp.end and r.anchor.end > sp.end) break;
        switch (r.detail) {
            .call => |c| if (c.composable) return true,
            else => {},
        }
        // `currentComposer` is the compiler's, not a composable read.
        if (r.kind == .read and r.target != .none and composableGetter(s, r.target) and !isCurrentComposer(s, r.target)) return true;
    }
    return false;
}

/// `$composer.startReplaceGroup(<site>)`, counted open.
pub fn startReplaceGroup(b: *Builder, site: span.Span) Error!void {
    _ = try composerCall(b, "startReplaceGroup", &.{try b.emitConst(.{ .Int = positionalKey(site) })});
    b.compose_open += 1;
}

pub fn endReplaceGroupCall(b: *Builder) Error!void {
    _ = try composerCall(b, "endReplaceGroup", &.{});
}

/// The empty replace group a branch that composes nothing still takes.
pub fn emptyGroup(b: *Builder, site: span.Span) Error!void {
    _ = try composerCall(b, "startReplaceGroup", &.{try b.emitConst(.{ .Int = positionalKey(site) })});
    try endReplaceGroupCall(b);
}

/// `androidx.compose.runtime.key`, whose block composes in a movable group
/// its keys identify.
pub fn isKeyCall(s: *sema.Sema, f: Sym) bool {
    return composableFunction(s, f) and isRuntimeFunction(s, f, "androidx.compose.runtime", "key");
}

/// `$composer.startMovableGroup(<site>, <keys joined>)`.
pub fn startMovableGroup(b: *Builder, site: span.Span, keys: []const Reg) Error!void {
    var data: Reg = if (keys.len == 0) try b.nullValue() else keys[0];
    for (keys[@min(keys.len, 1)..]) |k| data = try composerCall(b, "joinKey", &.{ data, k });
    _ = try composerCall(b, "startMovableGroup", &.{ try b.emitConst(.{ .Int = positionalKey(site) }), data });
}

pub fn endMovableGroup(b: *Builder) Error!void {
    _ = try composerCall(b, "endMovableGroup", &.{});
}

// ------------------------------------------------------------ runtime --

/// Whether `f` carries `androidx.compose.runtime.<name>`.
fn annotated(s: *sema.Sema, f: Sym, comptime name: []const u8) Error!bool {
    if (s.syms.get(f).decl != .function) return false;
    return sema.headers.hasAnnotation(s, f, .decl, s.classByFqn("androidx.compose.runtime." ++ name));
}

fn isRuntimeFunction(s: *sema.Sema, f: Sym, comptime pkg: []const u8, comptime name: []const u8) bool {
    const owner = s.syms.owner(f);
    if (owner == .none or s.syms.kind(owner) != .package) return false;
    return std.mem.eql(u8, s.str(s.syms.name(f)), name) and std.mem.eql(u8, s.str(s.syms.packageInfo(owner).fqn), pkg);
}

/// The compose runtime's top-level function `pkg.name`, by its id.
fn runtimeFunction(b: *Builder, comptime pkg: []const u8, comptime name: []const u8) ?ir.FuncId {
    const s = b.p.s;
    const pkg_name = s.names.lookup(pkg) orelse return null;
    const p = s.syms.package_by_fqn.get(pkg_name) orelse return null;
    const n = s.names.lookup(name) orelse return null;
    for (sema.scope.membersOf(s, p, n)) |m| {
        if (s.syms.kind(m) != .function) continue;
        if (b.p.br.funcOfOpt(m)) |f| return f;
    }
    return null;
}

/// The member function `name` of class `fqn` taking `n` parameters, the
/// first of class `first` when given.
fn memberFunction(s: *sema.Sema, cls: Sym, name: []const u8, n: usize, first: ?Sym) Error!?Sym {
    const nm = s.names.lookup(name) orelse return null;
    var found: ?Sym = null;
    var overloads: u32 = 0;
    for (sema.symbols.Symbols.members(&s.syms.classInfo(cls).members, nm)) |m| {
        if (s.syms.kind(m) != .function or s.syms.owner(m) != cls) continue;
        const params = s.syms.functionInfo(m).params;
        if (params.len != n) continue;
        if (first) |want| {
            if (s.types.classSym(try sema.headers.paramType(s, params[0])) == want) return m;
            continue;
        }
        overloads += 1;
        if (found == null) found = m;
        // Among overloads, the one over `Any?`, which a value of any type takes.
        if (n != 0) {
            const t = try sema.headers.paramType(s, params[0]);
            if (s.types.classSym(t) == s.builtins.any and s.types.isNullable(t)) found = m;
        }
    }
    return found;
}

/// `$composer.<name>(args)` through the `Composer` interface.
fn composerCall(b: *Builder, name: []const u8, args: []const Reg) Error!Reg {
    return interfaceCall(b, "androidx.compose.runtime.Composer", name, try composer(b), args);
}

fn composerCallTyped(b: *Builder, name: []const u8, args: []const Reg, first: Sym) Error!Reg {
    return interfaceCallOf(b, "androidx.compose.runtime.Composer", name, try composer(b), args, first);
}

fn interfaceCall(b: *Builder, comptime iface_fqn: []const u8, name: []const u8, recv: Reg, args: []const Reg) Error!Reg {
    return interfaceCallOf(b, iface_fqn, name, recv, args, null);
}

fn interfaceCallOf(b: *Builder, comptime iface_fqn: []const u8, name: []const u8, recv: Reg, args: []const Reg, first: ?Sym) Error!Reg {
    const s = b.p.s;
    const br = b.p.br;
    const cls = s.classByFqn(iface_fqn);
    if (cls == .none) return b.fail(b.cur_span, "the compose runtime declares no `{s}`", .{iface_fqn});
    const m = (try memberFunction(s, cls, name, args.len, first)) orelse
        return b.fail(b.cur_span, "`{s}` has no `{s}` taking {d} arguments", .{ iface_fqn, name, args.len });
    const f = br.funcOfOpt(m) orelse return b.fail(b.cur_span, "`{s}.{s}` has no id", .{ iface_fqn, name });
    const slot = br.slotOf(f) orelse return b.fail(b.cur_span, "`{s}.{s}` has no slot", .{ iface_fqn, name });
    var run: std.ArrayList(Reg) = .empty;
    try run.append(b.p.a, recv);
    try run.appendSlice(b.p.a, args);
    const dst = b.newReg();
    try b.emit(.{ .CallInterface = .{ .dst = dst, .iface = br.classOf(cls), .slot = slot, .args = try b.run(run.items), .n_args = @intCast(run.items.len) } });
    return dst;
}

/// `$composer.<name>`, a property of the `Composer` interface.
fn composerGetter(b: *Builder, name: []const u8) Error!Reg {
    const s = b.p.s;
    const br = b.p.br;
    const cls = s.classByFqn("androidx.compose.runtime.Composer");
    if (cls == .none) return b.fail(b.cur_span, "the compose runtime declares no `Composer`", .{});
    const nm = s.names.lookup(name) orelse return b.fail(b.cur_span, "`Composer` has no `{s}`", .{name});
    for (sema.symbols.Symbols.members(&s.syms.classInfo(cls).members, nm)) |p| {
        if (s.syms.kind(p) != .property) continue;
        const g = br.getter_of[p.int()];
        const slot = br.slotOf(g) orelse continue;
        const dst = b.newReg();
        try b.emit(.{ .CallInterface = .{ .dst = dst, .iface = br.classOf(cls), .slot = slot, .args = try b.run(&.{try composer(b)}), .n_args = 1 } });
        return dst;
    }
    return b.fail(b.cur_span, "`Composer` has no `{s}`", .{name});
}

fn loadParam(b: *Builder, idx: u16) Error!Reg {
    const r = b.newReg();
    try b.emit(.{ .LoadParam = .{ .dst = r, .idx = idx } });
    return r;
}

fn declSpan(s: *sema.Sema, f: Sym) span.Span {
    return switch (s.syms.get(f).decl) {
        .function => |fd| fd.?.span,
        else => .{ .file = span.FileId.from(0), .start = 0, .end = 0 },
    };
}

/// A group key: stable across compositions, distinct per source range.
pub fn positionalKey(sp: span.Span) i32 {
    var h: u64 = 0xcbf29ce484222325;
    inline for (.{ @as(u64, sp.file.int()), @as(u64, sp.start), @as(u64, sp.end) }) |v| {
        h ^= v;
        h *%= 0x100000001b3;
    }
    return @truncate(@as(i64, @bitCast(h)));
}

test "a group key is the pass's hash of the source range" {
    const sp: span.Span = .{ .file = span.FileId.from(3), .start = 10, .end = 42 };
    const again: span.Span = .{ .file = span.FileId.from(3), .start = 10, .end = 42 };
    const other: span.Span = .{ .file = span.FileId.from(3), .start = 10, .end = 43 };
    try std.testing.expectEqual(positionalKey(sp), positionalKey(again));
    try std.testing.expect(positionalKey(sp) != positionalKey(other));
}
