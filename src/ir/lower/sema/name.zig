//! Reads and writes of names: a local's home, a parameter, a property
//! through its slot or accessor, a top-level property's static, an object
//! or an enum entry.
//!
//! A property is read from its field when it has one, its getter is the
//! default one, and no override can answer instead (the property is final,
//! private, or reached through `super`); otherwise its getter is called:
//! statically when final or top-level, through its slot otherwise. Writes
//! mirror reads with the setter; a `val` is only written while its own
//! class initializes it, into its field.

const std = @import("std");
const ast = @import("ast");
const sema = @import("sema");

const ir = @import("../../ir.zig");
const bridge = @import("../../core/bridge.zig");
const builder = @import("builder.zig");
const records = @import("records.zig");
const env = @import("env.zig");
const body = @import("body.zig");
const inline_mod = @import("inline.zig");
const compose = @import("compose.zig");
const locals = @import("locals.zig");

const Builder = builder.Builder;
const Error = records.Error;
const NameRec = records.NameRec;
const Reg = ir.Reg;
const Sym = sema.Sym;
const FuncId = ir.FuncId;

/// A `Path` or `Member` read.
pub fn lowerName(b: *Builder, e: *const ast.Expr) Error!Reg {
    switch (e.*) {
        .Path => |p| {
            if (p.segments.len == 1) {
                const rec = try b.name(p.id);
                return read(b, &rec, null);
            }
            return (try pathValue(b, p.id, p.segments)) orelse b.nameMissed(p.id);
        },
        .Member => |m| {
            const rec = b.nameAt(m.id, m.name.span.start) orelse return b.nameMissed(m.id);
            if (isInitializedOf(b.p.s, rec.target)) if (try lateinitInitialized(b, m.receiver)) |r| return r;
            if (!takesExpr(&rec)) return read(b, &rec, null);
            // A constant read through an object qualifier initializes
            // nothing; one read on an expression still evaluates it.
            if (isConstRead(b.p.s, &rec) and objectQualifier(b, m.id, m.receiver)) return read(b, &rec, null);
            // The receiver is this read's alone.
            const from = locals.mark(b);
            const recv = try memberReceiver(b, m.id, m.receiver);
            if (!m.safe) return readFrom(b, &rec, recv, from);
            // `a?.x`: null when `a` is.
            const split = try b.branchOnNull(recv);
            const result = b.newReg();
            const join = try b.newBlock();
            b.switchTo(split.not_null);
            const v = try read(b, &rec, recv);
            try b.emit(.{ .Move = .{ .dst = result, .src = v } });
            b.terminate(.{ .Goto = join });
            b.switchTo(split.is_null);
            try b.emit(.{ .Move = .{ .dst = result, .src = try b.nullValue() } });
            b.terminate(.{ .Goto = join });
            b.switchTo(join);
            return result;
        },
        else => return b.fail(e.span(), "not a name", .{}),
    }
}

/// `kotlin.isInitialized`, the compiler intrinsic `::p.isInitialized`.
fn isInitializedOf(s: *sema.Sema, p: Sym) bool {
    if (s.syms.kind(p) != .property) return false;
    const owner = s.syms.owner(p);
    if (owner == .none or s.syms.kind(owner) != .package) return false;
    return std.mem.eql(u8, s.str(s.syms.packageInfo(owner).fqn), "kotlin") and
        std.mem.eql(u8, s.str(s.syms.name(p)), "isInitialized");
}

/// `::p.isInitialized` of a `lateinit` property `p`: whether its storage,
/// read without the check, holds a value. Null when `ref` is no reference
/// to a stored property.
fn lateinitInitialized(b: *Builder, ref: *const ast.Expr) Error!?Reg {
    const s = b.p.s;
    const br = b.p.br;
    const rr = sema.output.ref(b.recs, ref.id()) catch return null;
    const p = rr.target;
    if (s.syms.kind(p) != .property) return null;
    const raw = b.newReg();
    if (isMember(s, p)) {
        const slot = br.fieldOf(p) orelse return null;
        const this: Reg = switch (rr.bound) {
            .expr => switch (ref.*) {
                .MemberRef => |mr| try body.lowerExpr(b, mr.receiver),
                else => return null,
            },
            .implicit => |im| try env.receiver(b, im.kind, im.owner),
            else => return null,
        };
        try b.emit(.{ .GetFieldSlot = .{ .dst = raw, .obj = this, .slot = slot } });
    } else {
        const st = br.staticOf(p) orelse return null;
        try b.emit(.{ .LoadStatic = .{ .dst = raw, .static = st } });
    }
    const dst = b.newReg();
    try b.emit(.{ .BinOp = .{ .dst = dst, .op = .IdentNeq, .lhs = raw, .rhs = try b.nullValue() } });
    return dst;
}

/// Whether a record reads or writes on its site's receiver expression.
pub fn takesExpr(rec: *const NameRec) bool {
    return rec.dispatch == .expr or rec.extension == .expr;
}

/// The value of a dotted path's segments, from the name records node `id`
/// holds at each segment: a segment without one is a package or
/// classifier qualifier, and each segment with one reads on the value
/// before it. Null when every segment is a qualifier.
pub fn pathValue(b: *Builder, id: ast.NodeId, segs: []const ast.Ident) Error!?Reg {
    var cur: ?Reg = null;
    // Where lowering stood before `cur` was read, which the next read alone
    // consumes.
    var from: ?locals.Mark = null;
    for (segs, 0..) |seg, i| {
        const rec = b.nameAt(id, seg.span.start) orelse {
            // A qualifier cannot follow a value.
            if (cur != null) return b.nameMissed(id);
            continue;
        };
        // An object qualifier of a constant is not read: the constant
        // initializes nothing.
        if (rec.kind == .object and i + 1 < segs.len) {
            if (b.nameAt(id, segs[i + 1].span.start)) |next| if (isConstRead(b.p.s, &next)) continue;
        }
        const here = locals.mark(b);
        cur = try readFrom(b, &rec, cur, from);
        from = here;
    }
    return cur;
}

/// Whether `rec` reads a `const val`, which is its constant.
fn isConstRead(s: *sema.Sema, rec: *const NameRec) bool {
    if (rec.kind != .property or !s.syms.flags(rec.target).const_) return false;
    const pd = propDecl(s, rec.target) orelse return false;
    return pd.init != null;
}

/// The value a member access `recv.name` reads on: the object or
/// companion a classifier qualifier stands for (its record is on the
/// member's node, at the qualifier's last name), else the receiver
/// expression's value.
pub fn memberReceiver(b: *Builder, node: ast.NodeId, recv: *const ast.Expr) Error!Reg {
    if (b.nameAt(node, lastNameStart(recv))) |h| {
        if (h.kind == .object) return read(b, &h, null);
    }
    return body.lowerExpr(b, recv);
}

/// Whether member access `recv.name` names its receiver by an object or
/// companion qualifier rather than an expression.
fn objectQualifier(b: *Builder, node: ast.NodeId, recv: *const ast.Expr) bool {
    const h = b.nameAt(node, lastNameStart(recv)) orelse return false;
    return h.kind == .object;
}

fn lastNameStart(e: *const ast.Expr) u32 {
    return switch (e.*) {
        .Path => |p| p.segments[p.segments.len - 1].span.start,
        .Member => |m| m.name.span.start,
        else => e.span().start,
    };
}

/// A `$name` template part, whose record is on `ident.id`: `$this` is a
/// receiver, anything else a name.
pub fn lowerTemplateName(b: *Builder, ident: *const ast.Ident) Error!Reg {
    if (std.mem.eql(u8, ident.name, "this")) {
        const r = try b.recv(ident.id);
        return env.receiver(b, r.kind, r.owner);
    }
    const rec = try b.name(ident.id);
    return read(b, &rec, null);
}

/// The value `rec` names, on `recv` for a record whose receiver is the
/// site's expression.
pub fn read(b: *Builder, rec: *const NameRec, recv: ?Reg) Error!Reg {
    return readFrom(b, rec, recv, null);
}

/// `read` on a receiver lowered since `from` that the read alone consumes:
/// an accessor call computes it in place in its argument run.
pub fn readFrom(b: *Builder, rec: *const NameRec, recv: ?Reg, from: ?locals.Mark) Error!Reg {
    return switch (rec.kind) {
        .local, .param => env.readLocal(b, rec.target),
        .object => env.loadObject(b, rec.target),
        .enum_entry => entryValue(b, rec.target),
        .backing_field => readField(b, rec.target),
        .property => readProperty(b, rec, recv, from),
    };
}

/// An enum entry: its static; inside the entry's own body class, and the
/// inner classes within it, the instance under construction, which the
/// static holds only once the entry is built.
fn entryValue(b: *Builder, entry: Sym) Error!Reg {
    const s = b.p.s;
    const body_cls = s.syms.entryInfo(entry).body_class;
    if (body_cls != .none) {
        var cls = b.env.this_class;
        var hops: u8 = 0;
        while (cls != .none and hops < 16) : (hops += 1) {
            if (cls == body_cls) return env.receiver(b, .class_this, body_cls);
            if (!s.syms.flags(cls).inner) break;
            cls = s.syms.owner(cls);
        }
    }
    return loadStatic(b, entry);
}

/// Stores `value` into what `rec` names.
pub fn write(b: *Builder, rec: *const NameRec, recv: ?Reg, value: Reg) Error!void {
    const s = b.p.s;
    return switch (rec.kind) {
        .local => env.writeLocal(b, rec.target, value),
        .backing_field => writeField(b, rec.target, value),
        .property => writeProperty(b, rec, recv, value),
        .param, .object, .enum_entry => b.fail(b.cur_span, "`{s}` is not assignable", .{s.str(s.syms.name(rec.target))}),
    };
}

// ------------------------------------------------------------ properties --

/// Whether `p` is read with an instance: a member that is not static.
fn isMember(s: *sema.Sema, p: Sym) bool {
    return env.hasThis(s, p);
}

/// Whether no override can answer for member `p`: it is final or private,
/// or an open member of a class nothing extends (an enum class's entries
/// may override its open members).
pub fn finalMember(s: *sema.Sema, p: Sym) bool {
    const f = s.syms.flags(p);
    const cls = s.syms.owner(p);
    const ck = s.syms.classInfo(cls).kind;
    // A private member is never overridden, an interface's included.
    if (f.visibility == .private) return true;
    if (ck == .interface) return false;
    if (f.modality == .final) return true;
    return s.syms.flags(cls).modality == .final and ck != .enum_class;
}

fn propDecl(s: *sema.Sema, p: Sym) ?*const ast.Property {
    return switch (s.syms.get(p).decl) {
        .property => |pd| pd,
        else => null,
    };
}

/// Whether `p`'s getter is the one that returns its field.
fn defaultGetter(s: *sema.Sema, p: Sym) bool {
    const pd = propDecl(s, p) orelse return s.syms.get(p).decl == .class_param;
    return pd.getter == null and pd.delegate == null;
}

/// Whether `p`'s setter is the one that stores its field.
fn defaultSetter(s: *sema.Sema, p: Sym) bool {
    const pd = propDecl(s, p) orelse return s.syms.get(p).decl == .class_param;
    return pd.setter == null and pd.delegate == null;
}

/// The receiver a property record dispatches on.
fn dispatchReg(b: *Builder, rec: *const NameRec, recv: ?Reg) Error!?Reg {
    return env.receiverOf(b, rec.dispatch, recv);
}

fn isSuper(r: sema.records.Receiver) bool {
    return switch (r) {
        .implicit => |im| im.kind == .super_,
        else => false,
    };
}

fn readProperty(b: *Builder, rec: *const NameRec, recv: ?Reg, from: ?locals.Mark) Error!Reg {
    const s = b.p.s;
    const br = b.p.br;
    const p = rec.target;
    // The scope's composer, which the compiler reads for this intrinsic.
    if (compose.isCurrentComposer(s, p)) return compose.composer(b);
    // A `const val` is its constant, wherever it is read: reading it
    // initializes nothing.
    if (s.syms.flags(p).const_) if (propDecl(s, p)) |pd| if (pd.init) |init| {
        const decl_file = s.syms.get(p).file;
        // A file this run does not lower (a loaded base's) has no records
        // to lower the initializer from; the getter returns it, and reads
        // nothing of its receiver.
        if (!br.lowersFile(decl_file)) {
            const g = getterOf(br, p) orelse return noAccessor(b, p, "getter");
            const recv_arg: []const Reg = if (isMember(s, p)) &.{try b.nullValue()} else &.{};
            const dst = b.newReg();
            try b.emit(.{ .CallStatic = .{ .dst = dst, .func = g, .args = try b.run(recv_arg), .n_args = @intCast(recv_arg.len) } });
            return dst;
        }
        const file = b.file;
        b.setFile(decl_file);
        defer b.setFile(file);
        return body.lowerExpr(b, init);
    };
    const member = isMember(s, p);
    const disp: ?Reg = if (member) (try dispatchReg(b, rec, recv)) orelse
        return b.fail(b.cur_span, "member property `{s}` read without a receiver", .{s.str(s.syms.name(p))}) else null;
    const ext = try env.receiverOf(b, rec.extension, recv);
    const via_super = isSuper(rec.dispatch);
    if (ext == null and rec.contexts.len == 0 and defaultGetter(s, p)) {
        if (member) {
            const direct = via_super or finalMember(s, p);
            if (br.fieldOf(p)) |slot| {
                if (direct) {
                    const dst = b.newReg();
                    try b.emit(.{ .GetFieldSlot = .{ .dst = dst, .obj = disp.?, .slot = slot } });
                    return lateinitChecked(b, p, dst);
                }
            }
        } else if (br.staticOf(p)) |st| {
            const dst = b.newReg();
            try b.emit(.{ .LoadStatic = .{ .dst = dst, .static = st } });
            return lateinitChecked(b, p, dst);
        }
    }
    var args: std.ArrayList(Reg) = .empty;
    if (disp) |d| try args.append(b.p.a, d);
    for (rec.contexts) |c| try args.append(b.p.a, try contextArg(b, c));
    if (ext) |x| try args.append(b.p.a, x);
    // A composable getter takes the composer and its change bits.
    if (compose.composableGetter(s, p)) {
        try args.append(b.p.a, try compose.composer(b));
        try args.appendSlice(b.p.a, try compose.getterChanged(b, rec, p));
    }
    return accessorCall(b, p, getterOf(br, p) orelse return noAccessor(b, p, "getter"), false, args.items, member and !via_super, via_super, from);
}

fn writeProperty(b: *Builder, rec: *const NameRec, recv: ?Reg, value: Reg) Error!void {
    const s = b.p.s;
    const br = b.p.br;
    const p = rec.target;
    const member = isMember(s, p);
    const disp: ?Reg = if (member) (try dispatchReg(b, rec, recv)) orelse
        return b.fail(b.cur_span, "member property `{s}` written without a receiver", .{s.str(s.syms.name(p))}) else null;
    const ext = try env.receiverOf(b, rec.extension, recv);
    const via_super = isSuper(rec.dispatch);
    const mutable = s.syms.flags(p).mutable;
    if (ext == null and rec.contexts.len == 0 and (!mutable or defaultSetter(s, p))) {
        if (member) {
            // A `val` is written only by its own class's initialization.
            const direct = !mutable or via_super or finalMember(s, p);
            if (br.fieldOf(p)) |slot| {
                if (direct) {
                    try b.emit(.{ .SetFieldSlot = .{ .obj = disp.?, .slot = slot, .value = value } });
                    return;
                }
            }
        } else if (br.staticOf(p)) |st| {
            try b.emit(.{ .StoreStatic = .{ .static = st, .value = value } });
            return;
        }
    }
    var args: std.ArrayList(Reg) = .empty;
    if (disp) |d| try args.append(b.p.a, d);
    for (rec.contexts) |c| try args.append(b.p.a, try contextArg(b, c));
    if (ext) |x| try args.append(b.p.a, x);
    try args.append(b.p.a, value);
    const setter = br.setterOf(p) orelse return noAccessor(b, p, "setter");
    _ = try accessorCall(b, p, setter, true, args.items, member and !via_super, via_super, null);
}

/// `field` in an accessor: the property's own storage.
fn readField(b: *Builder, p: Sym) Error!Reg {
    const s = b.p.s;
    const br = b.p.br;
    const dst = b.newReg();
    if (isMember(s, p)) {
        const slot = br.fieldOf(p) orelse return noStorage(b, p);
        try b.emit(.{ .GetFieldSlot = .{ .dst = dst, .obj = try env.thisOf(b, s.syms.owner(p)), .slot = slot } });
    } else {
        const st = br.staticOf(p) orelse return noStorage(b, p);
        try b.emit(.{ .LoadStatic = .{ .dst = dst, .static = st } });
    }
    return dst;
}

fn writeField(b: *Builder, p: Sym, value: Reg) Error!void {
    const s = b.p.s;
    const br = b.p.br;
    if (isMember(s, p)) {
        const slot = br.fieldOf(p) orelse return noStorage(b, p);
        try b.emit(.{ .SetFieldSlot = .{ .obj = try env.thisOf(b, s.syms.owner(p)), .slot = slot, .value = value } });
    } else {
        const st = br.staticOf(p) orelse return noStorage(b, p);
        try b.emit(.{ .StoreStatic = .{ .static = st, .value = value } });
    }
}

fn lateinitChecked(b: *Builder, p: Sym, v: Reg) Error!Reg {
    const s = b.p.s;
    if (!s.syms.flags(p).lateinit) return v;
    const dst = b.newReg();
    const n = try b.p.m.internConst(b.p.a, .{ .String = s.str(s.syms.name(p)) });
    try b.emit(.{ .LateinitCheck = .{ .dst = dst, .src = v, .name = n } });
    return dst;
}

/// A context argument, which the scope always supplies.
fn contextArg(b: *Builder, c: sema.records.Receiver) Error!Reg {
    return (try env.receiverOf(b, c, null)) orelse b.fail(b.cur_span, "a context argument with no receiver", .{});
}

fn getterOf(br: *const bridge.Bridge, p: Sym) ?FuncId {
    if (p.int() >= br.getter_of.len) return null;
    const f = br.getter_of[p.int()];
    return if (f.int() == bridge.NONE) null else f;
}

/// Calls accessor `f` of property `p` over `args`: through its slot when
/// `virtual` and an override may answer, else directly. `via_super` runs a
/// native accessor as it is, which no receiver's override redirects.
fn accessorCall(b: *Builder, p: Sym, f: FuncId, setter: bool, args: []const Reg, virtual: bool, via_super: bool, from: ?locals.Mark) Error!Reg {
    const s = b.p.s;
    const br = b.p.br;
    // An inline accessor is instantiated like an inline function, unless a
    // native implements it.
    if (inlineAccessor(s, p, setter) and !b.p.isNative(f)) {
        const rec: records.CallRec = .{ .callee = p, .form = .plain };
        const lambdas = try b.p.a.alloc(?*const ast.Expr, args.len);
        @memset(lambdas, null);
        return inline_mod.instantiate(b, &rec, f, args, lambdas);
    }
    const run = if (from) |m| try locals.runFrom(b, m, args) else try b.run(args);
    const n: u32 = @intCast(args.len);
    const dst = b.newReg();
    if (!virtual or finalMember(s, p)) {
        if (via_super) if (b.p.m.resolved) |r| if (f.int() < r.func_native.len and r.func_native[f.int()] != .none) {
            try b.emit(.{ .CallNative = .{ .dst = dst, .native = r.func_native[f.int()], .args = run, .n_args = n, .direct = true } });
            return dst;
        };
        try b.emit(.{ .CallStatic = .{ .dst = dst, .func = f, .args = run, .n_args = n } });
        return dst;
    }
    if (f.int() >= br.slot_of.len) return b.fail(b.cur_span, "accessor of `{s}` has no method slot", .{s.str(s.syms.name(p))});
    const slot = br.slot_of[f.int()];
    const owner = s.syms.owner(p);
    if (s.syms.classInfo(owner).kind == .interface) {
        try b.emit(.{ .CallInterface = .{ .dst = dst, .iface = br.classOf(owner), .slot = slot, .args = run, .n_args = n } });
    } else {
        try b.emit(.{ .RCallVirtual = .{ .dst = dst, .slot = slot, .args = run, .n_args = n } });
    }
    return dst;
}

/// Whether `p`'s getter (or setter) is inline: the property is, or the
/// accessor alone.
fn inlineAccessor(s: *sema.Sema, p: Sym, setter: bool) bool {
    if (s.syms.flags(p).inline_) return true;
    const pd = propDecl(s, p) orelse return false;
    const acc = (if (setter) pd.setter else pd.getter) orelse return false;
    return acc.is_inline;
}

fn loadStatic(b: *Builder, s_: Sym) Error!Reg {
    const st = b.p.br.staticOf(s_) orelse return noStorage(b, s_);
    const dst = b.newReg();
    try b.emit(.{ .LoadStatic = .{ .dst = dst, .static = st } });
    return dst;
}

fn noAccessor(b: *Builder, p: Sym, what: []const u8) Error {
    const s = b.p.s;
    return b.fail(b.cur_span, "`{s}` has no {s}", .{ s.str(s.syms.name(p)), what });
}

fn noStorage(b: *Builder, p: Sym) Error {
    const s = b.p.s;
    return b.fail(b.cur_span, "`{s}` has no storage", .{s.str(s.syms.name(p))});
}
