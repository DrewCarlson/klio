//! Bodies that belong to a class: constructors, init units, accessors,
//! synthesized members (data, enum and value-class members, SAM classes,
//! `by` forwarders), object expressions and local classes.
//!
//! A constructor receives the instance `RNewInstance` allocated with every
//! slot at its seed, stores the hidden values it was passed (an inner
//! class's outer instance, a local class's captured values), runs the
//! supertype initializer on the same instance, stores its `by` delegates
//! and constructor properties, then runs property initializers and `init`
//! blocks in source order, and returns the instance.

const std = @import("std");
const ast = @import("ast");
const sema = @import("sema");

const ir = @import("../../ir.zig");
const bridge = @import("../../core/bridge.zig");
const builder = @import("builder.zig");
const records = @import("records.zig");
const env = @import("env.zig");
const body = @import("body.zig");
const call = @import("call.zig");
const name_mod = @import("name.zig");
const dispatch = @import("dispatch.zig");

const Builder = builder.Builder;
const Error = records.Error;
const CallRec = records.CallRec;
const NameRec = records.NameRec;
const ClassId = ir.ClassId;
const FuncId = ir.FuncId;
const Reg = ir.Reg;
const Sym = sema.Sym;

// ---------------------------------------------------------- constructors --

/// A constructor's body: primary (written or implicit, of a class, object
/// or object expression) or secondary.
pub fn lowerCtor(b: *Builder, ctor: Sym) Error!void {
    const s = b.p.s;
    const cls = s.syms.owner(ctor);
    const this = try env.thisOf(b, cls);
    // An enum class's companion initializes as part of the enum class,
    // after its entries.
    if (s.syms.classInfo(cls).kind == .companion) {
        const outer = s.syms.owner(cls);
        if (outer != .none and s.syms.kind(outer) == .class and s.syms.classInfo(outer).kind == .enum_class) try ensureEnumInit(b, outer);
    }
    // A class initializes at its first instantiation, before the instance's
    // own initialization, and its superclass before it, as the JVM runs
    // their static initializers: the nearest companion up the chain, whose
    // own constructor starts with the next one up.
    if (s.syms.classInfo(cls).kind == .class) if (nearestCompanion(s, cls)) |comp| if (b.p.br.classOfOpt(comp)) |c| {
        try b.emit(.{ .LoadObject = .{ .dst = b.newReg(), .class = c } });
    };
    // A companion is its class's static initialization: the superclass's
    // runs first.
    if (s.syms.classInfo(cls).kind == .companion) {
        const outer = s.syms.owner(cls);
        if (outer != .none and s.syms.kind(outer) == .class and s.syms.classInfo(outer).kind == .class) {
            if (superclassOf(s, outer)) |sup| if (nearestCompanion(s, sup)) |comp| if (b.p.br.classOfOpt(comp)) |c| {
                try b.emit(.{ .LoadObject = .{ .dst = b.newReg(), .class = c } });
            };
        }
    }
    switch (s.syms.get(ctor).decl) {
        .secondary_ctor => |sc| try secondaryCtor(b, cls, sc, this),
        else => try primaryCtor(b, cls, this),
    }
    if (!b.terminated()) b.terminate(.{ .Return = this });
}

/// The superclass of class `cls`, an interface never; null for none.
fn superclassOf(s: *sema.Sema, cls: Sym) ?Sym {
    const sts = sema.headers.supertypes(s, cls) catch return null;
    for (sts) |st| {
        const sc = s.types.classSym(st);
        if (sc == .none or s.syms.kind(sc) != .class) continue;
        if (s.syms.classInfo(sc).kind == .class) return sc;
    }
    return null;
}

/// The companion of `cls` or, lacking one, of its nearest superclass that
/// has one.
fn nearestCompanion(s: *sema.Sema, cls: Sym) ?Sym {
    var c = cls;
    var hops: u8 = 0;
    while (hops < 64) : (hops += 1) {
        const comp = s.syms.classInfo(c).companion;
        if (comp != .none) return comp;
        c = superclassOf(s, c) orelse return null;
    }
    return null;
}

/// What a class's declaration holds that its construction runs.
const ClassDecl = struct {
    node: ast.NodeId,
    supertypes: []const ast.TypeRef,
    supertype_args: []const ?[]ast.Expr,
    delegates: []const ?ast.Expr,
    members: []const ast.Decl,
    init_blocks: []const ast.Block,
    init_positions: []const usize,
    primary_params: []const ast.ClassParam = &.{},
};

fn classDecl(s: *sema.Sema, cls: Sym) ?ClassDecl {
    return switch (s.syms.get(cls).decl) {
        .class => |c| .{
            .node = c.id,
            .supertypes = c.supertypes,
            .supertype_args = c.supertype_args,
            .delegates = c.supertype_delegates,
            .members = c.members,
            .init_blocks = c.x().init_blocks,
            .init_positions = c.x().init_block_positions,
            .primary_params = c.primary_params,
        },
        .object => |o| .{
            .node = o.id,
            .supertypes = o.supertypes,
            .supertype_args = o.supertype_args,
            .delegates = o.supertype_delegates,
            .members = o.members,
            .init_blocks = o.init_blocks,
            .init_positions = o.init_block_positions,
        },
        .object_literal => |o| .{
            .node = o.id,
            .supertypes = o.supertypes,
            .supertype_args = o.supertype_args,
            .delegates = o.supertype_delegates,
            .members = o.members,
            .init_blocks = o.init_blocks,
            .init_positions = o.init_block_positions,
        },
        else => null,
    };
}

fn primaryCtor(b: *Builder, cls: Sym, this: Reg) Error!void {
    const s = b.p.s;
    const cd = classDecl(s, cls) orelse return b.fail(b.cur_span, "`{s}` has no declaration to construct", .{s.str(s.syms.name(cls))});
    try storeHidden(b, cls, this);
    // A value class's properties are its value: they are set before its
    // supertype's initialization, which may read them through `this`.
    const value = s.syms.flags(cls).value;
    if (value) try storeCtorProperties(b, cls, cd, this);
    try superInit(b, cls, cd);
    try storeDelegates(b, cls, cd, this);
    if (!value) try storeCtorProperties(b, cls, cd, this);
    try initializers(b, cls, cd, this);
}

/// A secondary constructor delegates first: to `this(...)`, which runs the
/// class's initialization, or to `super(...)` (written or implicit), after
/// which it runs the initialization itself. Then its own body.
fn secondaryCtor(b: *Builder, cls: Sym, sc: *const ast.SecondaryCtor, this: Reg) Error!void {
    const s = b.p.s;
    const cd = classDecl(s, cls) orelse return b.fail(sc.span, "`{s}` has no declaration to construct", .{s.str(s.syms.name(cls))});
    try storeHidden(b, cls, this);
    switch (sc.delegation) {
        .This, .Super => |args| {
            const rec = try b.call(sc.id);
            try call.lowerDelegation(b, &rec, .{ .exprs = try exprList(b, args), .regs = &.{}, .receiver = null, .sp = sc.span });
        },
        .None => try implicitSuper(b, cls, this, sc.span),
    }
    if (sc.delegation != .This) {
        try storeDelegates(b, cls, cd, this);
        try initializers(b, cls, cd, this);
    }
    if (sc.body) |*blk| _ = try body.lowerStmts(b, blk.stmts);
}

fn exprList(b: *Builder, args: []const ast.Expr) Error![]const ?*const ast.Expr {
    const out = try b.p.a.alloc(?*const ast.Expr, args.len);
    for (args, out) |*x, *o| o.* = x;
    return out;
}

/// Stores the values a constructor receives before its parameters: the
/// outer instance of an inner class and a local class's captured values,
/// each into its slot.
fn storeHidden(b: *Builder, cls: Sym, this: Reg) Error!void {
    const s = b.p.s;
    const br = b.p.br;
    const c = br.classOfOpt(cls) orelse return;
    if (env.outerOf(s, cls)) |outer| {
        const slot = br.outerSlot(c) orelse return b.fail(b.cur_span, "inner class `{s}` has no outer slot", .{s.str(s.syms.name(cls))});
        const v = try env.receiver(b, env.thisKind(s, outer), outer);
        try b.emit(.{ .SetFieldSlot = .{ .obj = this, .slot = slot, .value = v } });
    }
    const keys = br.class_captures[c.int()];
    if (keys.len == 0) return;
    const base = br.capture_base[c.int()];
    for (try env.materializeCaptures(b, keys), 0..) |v, i| {
        try b.emit(.{ .SetFieldSlot = .{ .obj = this, .slot = base + @as(u32, @intCast(i)), .value = v } });
    }
}

/// The supertype initializer on this instance: the written `: Base(...)`
/// call, an enum class's `Enum(name, ordinal)`, or an enum entry body's
/// call of its enum class's constructor with the entry's arguments.
fn superInit(b: *Builder, cls: Sym, cd: ClassDecl) Error!void {
    const s = b.p.s;
    const this = try env.thisOf(b, cls);
    switch (s.syms.classInfo(cls).kind) {
        .enum_class => return enumSuper(b, this),
        .enum_entry => {
            const entry = entryOfBody(s, cls) orelse return b.fail(b.cur_span, "an enum entry class without its entry", .{});
            const rec = try b.call(entry.id);
            return call.lowerDelegation(b, &rec, .{ .exprs = try exprList(b, entry.args), .regs = &.{}, .receiver = null, .sp = entry.span });
        },
        else => {},
    }
    const recs = try b.supers(cd.node);
    var written: std.ArrayList(usize) = .empty;
    for (cd.supertype_args, 0..) |args, i| if (args != null) try written.append(b.p.a, i);
    if (recs.len != written.items.len) {
        return b.fail(b.cur_span, "`{s}` has {d} supertype calls and {d} records", .{ s.str(s.syms.name(cls)), written.items.len, recs.len });
    }
    for (recs, written.items) |*rec, i| {
        const sp = if (i < cd.supertypes.len) cd.supertypes[i].span else b.cur_span;
        try call.lowerDelegation(b, rec, .{ .exprs = try exprList(b, cd.supertype_args[i].?), .regs = &.{}, .receiver = null, .sp = sp });
    }
}

/// `Enum(name, ordinal)` on the instance an enum class's constructor
/// builds, from the constructor's own `name` and `ordinal`.
fn enumSuper(b: *Builder, this: Reg) Error!void {
    const s = b.p.s;
    const at = b.env.enum_name orelse return b.fail(b.cur_span, "an enum constructor without its name", .{});
    const enum_cls = s.builtins.enum_;
    if (enum_cls == .none) return b.fail(b.cur_span, "the base declares no `kotlin.Enum`", .{});
    const ctor = s.syms.classInfo(enum_cls).primary_ctor;
    const f = b.p.br.funcOfOpt(ctor) orelse return b.fail(b.cur_span, "`kotlin.Enum` has no constructor id", .{});
    const n = try loadParam(b, at);
    const o = try loadParam(b, at + 1);
    const run = try b.run(&.{ this, n, o });
    try b.emit(.{ .CallStatic = .{ .dst = b.newReg(), .func = f, .args = run, .n_args = 3 } });
}

/// A secondary constructor written without a delegation, in a class with
/// no primary constructor, calls its superclass's constructor that takes
/// no arguments.
fn implicitSuper(b: *Builder, cls: Sym, this: Reg, sp: @import("span").Span) Error!void {
    const s = b.p.s;
    if (s.syms.classInfo(cls).kind == .enum_class) return enumSuper(b, this);
    const sup = superClass(s, cls) orelse return;
    if (sup == s.builtins.any) return;
    const primary = s.syms.classInfo(sup).primary_ctor;
    if (env.outerOf(s, sup) != null or (primary != .none and call.layoutOf(b.p, primary).hidden != 0)) {
        return b.fail(sp, "the implicit `super()` to `{s}`, which takes hidden values, has no record", .{s.str(s.syms.name(sup))});
    }
    // The superclass's constructor that takes no arguments, primary or
    // secondary; else one whose parameters all have defaults, through its
    // defaults bridge.
    var defaulted: ?Sym = null;
    for (sema.symbols.Symbols.members(&s.syms.classInfo(sup).members, sema.wk.init)) |ctor| {
        if (s.syms.kind(ctor) != .constructor) continue;
        const params = s.syms.functionInfo(ctor).params;
        if (params.len == 0) {
            const f = b.p.br.funcOfOpt(ctor) orelse return b.fail(sp, "`{s}` has no constructor id", .{s.str(s.syms.name(sup))});
            try b.emit(.{ .CallStatic = .{ .dst = b.newReg(), .func = f, .args = try b.run(&.{this}), .n_args = 1 } });
            return;
        }
        const all = for (params) |p| {
            if (!s.syms.flags(p).has_default) break false;
        } else true;
        if (all and defaulted == null) defaulted = ctor;
    }
    const ctor = defaulted orelse
        return b.fail(sp, "`{s}` has no constructor that takes no arguments", .{s.str(s.syms.name(sup))});
    const bridge_f = b.p.br.defaultsOf(ctor) orelse return b.fail(sp, "`{s}` has no defaults bridge", .{s.str(s.syms.name(sup))});
    const n = s.syms.functionInfo(ctor).params.len;
    var regs: std.ArrayList(Reg) = .empty;
    try regs.append(b.p.a, this);
    for (0..n) |_| try regs.append(b.p.a, try b.emitConst(.Unit));
    // Every parameter takes its default.
    var left = n;
    while (left > 0) {
        const bits = @min(left, 32);
        const word: u32 = if (bits == 32) std.math.maxInt(u32) else (@as(u32, 1) << @intCast(bits)) - 1;
        try regs.append(b.p.a, try b.emitConst(.{ .Int = @bitCast(word) }));
        left -= bits;
    }
    try b.emit(.{ .CallStatic = .{ .dst = b.newReg(), .func = bridge_f, .args = try b.run(regs.items), .n_args = @intCast(regs.items.len) } });
}

fn superClass(s: *sema.Sema, cls: Sym) ?Sym {
    for (s.syms.classInfo(cls).supertypes) |st| {
        const c = s.types.classSym(st);
        if (c == .none or s.syms.kind(c) != .class) continue;
        if (s.syms.classInfo(c).kind != .interface) return c;
    }
    return null;
}

/// The entry whose body class is `cls`.
fn entryOfBody(s: *sema.Sema, cls: Sym) ?*const ast.EnumEntry {
    const enum_cls = s.syms.owner(cls);
    if (enum_cls == .none or s.syms.kind(enum_cls) != .class) return null;
    for (s.syms.classInfo(enum_cls).enum_entries) |e| {
        if (s.syms.entryInfo(e).body_class == cls) return s.syms.get(e).decl.enum_entry;
    }
    return null;
}

/// `: I by d`: each delegate into its slot.
fn storeDelegates(b: *Builder, cls: Sym, cd: ClassDecl, this: Reg) Error!void {
    for (cd.delegates, 0..) |*d, i| {
        const ex: *const ast.Expr = if (d.*) |*x| x else continue;
        const slot = b.p.br.delegateSlot(cls, @intCast(i)) orelse return b.fail(ex.span(), "a `by` delegate without a slot", .{});
        const v = try body.lowerExpr(b, ex);
        try b.emit(.{ .SetFieldSlot = .{ .obj = this, .slot = slot, .value = v } });
    }
}

/// The primary constructor's `val`/`var` parameters, each into its field.
fn storeCtorProperties(b: *Builder, cls: Sym, cd: ClassDecl, this: Reg) Error!void {
    const s = b.p.s;
    if (cd.primary_params.len == 0) return;
    const ctor = s.syms.classInfo(cls).primary_ctor;
    const params = s.syms.functionInfo(ctor).params;
    for (cd.primary_params, 0..) |*cp, i| {
        if (cp.property == null or i >= params.len) continue;
        const prop = ctorProperty(s, cls, cp) orelse continue;
        const slot = b.p.br.fieldOf(prop) orelse continue;
        const v = try env.readLocal(b, params[i]);
        try b.emit(.{ .SetFieldSlot = .{ .obj = this, .slot = slot, .value = v } });
    }
}

/// The property a primary constructor parameter declares.
fn ctorProperty(s: *sema.Sema, cls: Sym, cp: *const ast.ClassParam) ?Sym {
    const n = s.names.lookup(cp.name.name) orelse return null;
    for (sema.symbols.Symbols.members(&s.syms.classInfo(cls).members, n)) |m| {
        if (s.syms.kind(m) != .property) continue;
        switch (s.syms.get(m).decl) {
            .class_param => |x| if (x == cp) return m,
            else => {},
        }
    }
    return null;
}

/// The property a body declaration declares.
fn memberProperty(s: *sema.Sema, cls: Sym, pd: *const ast.Property) ?Sym {
    const n = s.names.lookup(pd.name.name) orelse return null;
    for (sema.symbols.Symbols.members(&s.syms.classInfo(cls).members, n)) |m| {
        if (s.syms.kind(m) != .property) continue;
        switch (s.syms.get(m).decl) {
            .property => |x| if (x == pd) return m,
            else => {},
        }
    }
    return null;
}

/// Property initializers and `init` blocks in source order: the blocks at
/// position `i` run before member `i`'s initializer.
fn initializers(b: *Builder, cls: Sym, cd: ClassDecl, this: Reg) Error!void {
    var next_block: usize = 0;
    for (cd.members, 0..) |*m, i| {
        next_block = try blocksAt(b, cd, next_block, i);
        switch (m.*) {
            .Property => |pd| try initProperty(b, cls, pd, this),
            else => {},
        }
    }
    _ = try blocksAt(b, cd, next_block, std.math.maxInt(usize));
}

fn blocksAt(b: *Builder, cd: ClassDecl, from: usize, pos: usize) Error!usize {
    var k = from;
    while (k < cd.init_blocks.len) : (k += 1) {
        const at = if (k < cd.init_positions.len) cd.init_positions[k] else std.math.maxInt(usize);
        if (at > pos) break;
        if (b.terminated()) return k + 1;
        _ = try body.lowerStmts(b, cd.init_blocks[k].stmts);
    }
    return k;
}

fn initProperty(b: *Builder, cls: Sym, pd: *const ast.Property, this: Reg) Error!void {
    const s = b.p.s;
    const br = b.p.br;
    const prop = memberProperty(s, cls, pd) orelse return b.fail(pd.span, "property `{s}` has no symbol", .{pd.name.name});
    if (pd.delegate) |d| {
        try b.emit(.{ .Trace = .{ .span = d.span() } });
        var v = try body.lowerExpr(b, d);
        const g = try b.delegate(pd.id);
        if (g.provide) |*pr| v = try delegateOp(b, pr, v, prop, this, null, null);
        const slot = br.delegateFieldOf(prop) orelse return b.fail(pd.span, "delegated `{s}` has no delegate slot", .{pd.name.name});
        try b.emit(.{ .SetFieldSlot = .{ .obj = this, .slot = slot, .value = v } });
        return;
    }
    const init: ?*const ast.Expr = if (pd.init) |x| x else if (pd.explicit_field) |ef| ef.init else null;
    const ex = init orelse return;
    if (defaultInitializer(s, s.syms.propertyInfo(prop).ty, ex)) return;
    try b.emit(.{ .Trace = .{ .span = ex.span() } });
    const v = try body.lowerExpr(b, ex);
    const slot = br.fieldOf(prop) orelse return b.fail(pd.span, "initialized `{s}` has no field", .{pd.name.name});
    try b.emit(.{ .SetFieldSlot = .{ .obj = this, .slot = slot, .value = v } });
}

/// The `KProperty` a property's delegate receives: its accessors, bound to
/// the instance for a member.
fn propertyRef(b: *Builder, prop: Sym, this: ?Reg) Error!Reg {
    const s = b.p.s;
    const br = b.p.br;
    const dst = b.newReg();
    const n = try b.p.m.internConst(b.p.a, .{ .String = s.str(s.syms.name(prop)) });
    const setter: u32 = if (br.setterOf(prop)) |f| f.int() else ir.NO_FUNC;
    try b.emit(.{ .RPropertyRef = .{ .dst = dst, .getter = br.getterOf(prop), .setter = setter, .bound = this, .name = n } });
    return dst;
}

/// One of a delegated property's operators on `delegate`: `thisRef` (an
/// extension property's receiver, the instance, or `null` at the top
/// level), the property, then the new value for `setValue`.
fn delegateOp(b: *Builder, rec: *const CallRec, delegate: Reg, prop: Sym, this: ?Reg, this_ref_in: ?Reg, value: ?Reg) Error!Reg {
    const this_ref = this_ref_in orelse this orelse try b.nullValue();
    const regs: [3]?Reg = .{ this_ref, try propertyRef(b, prop, this), value };
    const exprs: [3]?*const ast.Expr = .{ null, null, null };
    const n: usize = if (value != null) 3 else 2;
    return call.emitCall(b, rec, .{ .exprs = exprs[0..n], .regs = regs[0..n], .receiver = delegate });
}

/// How many parameters the body being written takes.
fn paramCount(b: *const Builder) u16 {
    return @intCast(b.p.m.funcs.items[b.func.int()].params.len);
}

fn loadParam(b: *Builder, idx: u16) Error!Reg {
    const dst = b.newReg();
    try b.emit(.{ .LoadParam = .{ .dst = dst, .idx = idx } });
    return dst;
}

// ------------------------------------------------------------ init units --

/// A file's statics in source order, or an enum class's entries in order.
pub fn lowerInitUnit(b: *Builder, unit: u32) Error!void {
    const br = b.p.br;
    switch (br.units[unit]) {
        .file => |f| try fileStatics(b, f),
        .enum_class => |e| try enumEntries(b, e),
    }
    if (!b.terminated()) b.terminate(.{ .Return = null });
}

fn fileStatics(b: *Builder, file: u32) Error!void {
    const s = b.p.s;
    const br = b.p.br;
    b.setFile(file);
    var i: u32 = 1;
    while (i < br.static_of.len) : (i += 1) {
        const st = br.static_of[i];
        if (st.int() == bridge.NONE) continue;
        const p = Sym.from(i);
        if (s.syms.kind(p) != .property or s.syms.get(p).file != file) continue;
        const pd = switch (s.syms.get(p).decl) {
            .property => |pd| pd,
            else => continue,
        };
        b.cur_span = pd.span;
        if (pd.delegate) |d| {
            try b.emit(.{ .Trace = .{ .span = d.span() } });
            var v = try body.lowerExpr(b, d);
            const g = try b.delegate(pd.id);
            if (g.provide) |*pr| v = try delegateOp(b, pr, v, p, null, null, null);
            try b.emit(.{ .StoreStatic = .{ .static = st, .value = v } });
            continue;
        }
        const ex = pd.init orelse if (pd.explicit_field) |ef| ef.init orelse continue else continue;
        if (defaultInitializer(s, s.syms.propertyInfo(p).ty, ex)) continue;
        // A frame of the file's initialization stands at the initializer
        // it runs, as the JVM's `<clinit>` line table puts it.
        try b.emit(.{ .Trace = .{ .span = ex.span() } });
        const v = try body.lowerExpr(b, ex);
        try b.emit(.{ .StoreStatic = .{ .static = st, .value = v } });
    }
}

/// Whether `init`, the initializer of a property of type `ty`, is a
/// constant equal to the field's JVM default: zero, `false`, '\u0000' or
/// positive 0.0 for a non-null primitive, `null` for any type. kotlinc's
/// JVM backend drops such an initializer, so a value stored into the field
/// before it would run (by a supertype's or an earlier initializer) stays.
fn defaultInitializer(s: *sema.Sema, ty: sema.TypeId, init: *const ast.Expr) bool {
    if (init.* == .NullLit) return true;
    if (ty == .none or s.types.isNullable(ty)) return false;
    // The primitives whose slots the bridge seeds with their zero.
    const t = s.t;
    const primitives = [_]sema.TypeId{ t.boolean, t.char, t.byte, t.short, t.int, t.long, t.float, t.double };
    if (std.mem.indexOfScalar(sema.TypeId, &primitives, ty) == null) return false;
    return zeroConstant(init);
}

/// A literal zero, `false` or '\u0000', integer arithmetic folding to
/// zero, or a conversion (`0.toByte()`) of one.
fn zeroConstant(e: *const ast.Expr) bool {
    return switch (e.*) {
        .BoolLit => |x| !x.value,
        .CharLit => |x| x.value == 0,
        .FloatLit => |x| x.value == 0 and !std.math.signbit(x.value),
        .IntLit => |x| x.value == 0,
        .Unary, .Binary => (sema.body.intConstValue(e) orelse return false) == 0,
        .Call => |c| c.args.len == 0 and switch (c.callee.*) {
            .Member => |m| isConversion(m.name.name) and zeroConstant(m.receiver),
            else => false,
        },
        else => false,
    };
}

fn isConversion(n: []const u8) bool {
    const names = [_][]const u8{ "toByte", "toShort", "toInt", "toLong", "toChar", "toFloat", "toDouble" };
    for (names) |x| if (std.mem.eql(u8, n, x)) return true;
    return false;
}

/// Each entry, in order: a new instance of its body class or of the enum
/// class, given its name and ordinal, stored in its static.
fn enumEntries(b: *Builder, cls: Sym) Error!void {
    const s = b.p.s;
    const br = b.p.br;
    b.setFile(s.syms.get(cls).file);
    for (s.syms.classInfo(cls).enum_entries, 0..) |e, ordinal| {
        const entry = s.syms.get(e).decl.enum_entry;
        b.cur_span = entry.span;
        try b.emit(.{ .Trace = .{ .span = entry.span } });
        const st = br.staticOf(e) orelse return b.fail(entry.span, "entry `{s}` has no static", .{entry.name.name});
        const n = try b.emitConst(.{ .String = entry.name.name });
        const o = try b.emitConst(.{ .Int = @intCast(ordinal) });
        const dst = b.newReg();
        const body_cls = s.syms.entryInfo(e).body_class;
        if (body_cls != .none) {
            const c = br.classOfOpt(body_cls) orelse return b.fail(entry.span, "entry `{s}`'s class has no id", .{entry.name.name});
            const ctor = br.funcOfOpt(s.syms.classInfo(body_cls).primary_ctor) orelse return b.fail(entry.span, "entry `{s}`'s class has no constructor", .{entry.name.name});
            try b.emit(.{ .RNewInstance = .{ .dst = dst, .class = c, .ctor = ctor, .args = try b.run(&.{ n, o }), .n_args = 2 } });
        } else {
            const rec = try b.call(entry.id);
            const args = try call.ctorArgs(b, &rec, .{ .exprs = try exprList(b, entry.args), .regs = &.{}, .receiver = null, .sp = entry.span }, &.{ n, o });
            const c = br.classOfOpt(cls) orelse return b.fail(entry.span, "enum class has no id", .{});
            try b.emit(.{ .RNewInstance = .{ .dst = dst, .class = c, .ctor = args.func, .args = args.run, .n_args = args.n } });
        }
        try b.emit(.{ .StoreStatic = .{ .static = st, .value = dst } });
    }
    try enumEntriesList(b, cls);
    // The companion initializes as part of the enum class, after the entries.
    const comp = s.syms.classInfo(cls).companion;
    if (comp != .none) if (br.classOfOpt(comp)) |c| {
        try b.emit(.{ .LoadObject = .{ .dst = b.newReg(), .class = c } });
    };
}

/// The enum class's initialization, run once on first use: a read of its
/// first entry's static.
fn ensureEnumInit(b: *Builder, cls: Sym) Error!void {
    const s = b.p.s;
    const entries = s.syms.classInfo(cls).enum_entries;
    if (entries.len == 0) return;
    const st = b.p.br.staticOf(entries[0]) orelse return;
    try b.emit(.{ .LoadStatic = .{ .dst = b.newReg(), .static = st } });
}

/// `entries`: the base's `kotlin.enums.enumEntries(entries: Array<E>)`
/// over the entries in order.
fn enumEntriesList(b: *Builder, cls: Sym) Error!void {
    const s = b.p.s;
    const br = b.p.br;
    const prop = for (sema.symbols.Symbols.members(&s.syms.classInfo(cls).members, sema.wk.entries)) |m| {
        if (s.syms.kind(m) == .property and s.syms.flags(m).static) break m;
    } else return;
    const st = br.staticOf(prop) orelse return;
    const make = (try enumEntriesOverArray(b)) orelse return b.fail(b.cur_span, "the base declares no `kotlin.enums.enumEntries(Array)`", .{});
    const arr = try entriesArray(b, cls);
    const list = try callStatic(b, make, &.{arr});
    try b.emit(.{ .StoreStatic = .{ .static = st, .value = list } });
}

fn enumEntriesOverArray(b: *Builder) Error!?FuncId {
    const s = b.p.s;
    const pkg_name = s.names.lookup("kotlin.enums") orelse return null;
    const pkg = s.syms.package_by_fqn.get(pkg_name) orelse return null;
    const n = s.names.lookup("enumEntries") orelse return null;
    for (sema.scope.membersOf(s, pkg, n)) |m| {
        if (s.syms.kind(m) != .function) continue;
        const params = s.syms.functionInfo(m).params;
        if (params.len != 1) continue;
        // Over a loaded base, nothing has resolved its header yet.
        const t = try sema.headers.paramType(s, params[0]);
        if (s.types.classSym(t) != s.builtins.array) continue;
        return b.p.br.funcOfOpt(m);
    }
    return null;
}

// ------------------------------------------------------------- accessors --

/// A property's getter or setter: its written accessor, the default one
/// over its field or static, a delegated property's `getValue`/`setValue`,
/// or a `by` forwarder.
pub fn lowerAccessor(b: *Builder, prop: Sym, setter: bool) Error!void {
    const s = b.p.s;
    const info = s.syms.propertyInfo(prop);
    if (info.forwards != .none) return forwardAccessor(b, prop, setter);
    const this: ?Reg = if (env.hasThis(s, prop)) try env.thisOf(b, s.syms.owner(prop)) else null;
    // An extension property's delegate takes its receiver as `thisRef`.
    const ext: ?Reg = if (info.receiver != .none) try env.receiver(b, .extension, prop) else null;
    const pd: ?*const ast.Property = switch (s.syms.get(prop).decl) {
        .property => |x| x,
        else => null,
    };
    if (setter) {
        const value = try loadParam(b, b.env.setter_value orelse return b.fail(b.cur_span, "a setter without its value", .{}));
        if (pd) |x| if (x.setter) |acc| {
            try bindSetterValue(b, prop, acc, value);
            try accessorBody(b, acc, true);
            return;
        };
        if (pd) |x| if (x.delegate != null) {
            const g = try b.delegate(x.id);
            const set = g.set orelse return b.fail(x.span, "delegated `{s}` has no setValue", .{x.name.name});
            _ = try delegateOp(b, &set, try delegateOf(b, prop, this), prop, this, ext, value);
            b.terminate(.{ .Return = try b.unit() });
            return;
        };
        try storeField(b, prop, this, value);
        b.terminate(.{ .Return = try b.unit() });
        return;
    }
    if (pd) |x| if (x.getter) |acc| return accessorBody(b, acc, false);
    // A `const val`'s getter is its constant, as a read of it is.
    if (pd) |x| if (s.syms.flags(prop).const_) if (x.init) |init| {
        const v = try body.lowerExpr(b, init);
        if (!b.terminated()) b.terminate(.{ .Return = v });
        return;
    };
    if (pd) |x| if (x.delegate != null) {
        const g = try b.delegate(x.id);
        const v = try delegateOp(b, &g.get, try delegateOf(b, prop, this), prop, this, ext, null);
        b.terminate(.{ .Return = v });
        return;
    };
    b.terminate(.{ .Return = try loadField(b, prop, this) });
}

/// A written accessor's body: an expression getter returns its value, an
/// expression setter runs for its effect.
fn accessorBody(b: *Builder, acc: *const ast.Accessor, setter: bool) Error!void {
    switch (acc.body) {
        .Block => |*blk| {
            _ = try body.lowerStmts(b, blk.stmts);
            if (!b.terminated()) b.terminate(.{ .Return = if (setter) try b.unit() else null });
        },
        .Expr => |*e| {
            try b.emit(.{ .Trace = .{ .span = e.span() } });
            const v = try body.lowerExpr(b, e);
            if (!b.terminated()) b.terminate(.{ .Return = if (setter) try b.unit() else v });
        },
    }
}

/// Binds the local a written setter declares for its new value, which the
/// setter's `decl` record names.
fn bindSetterValue(b: *Builder, prop: Sym, acc: *const ast.Accessor, value: Reg) Error!void {
    _ = prop;
    try env.bindLocal(b, try b.decl(acc.id), value);
}

fn loadField(b: *Builder, prop: Sym, this: ?Reg) Error!Reg {
    const s = b.p.s;
    const br = b.p.br;
    const dst = b.newReg();
    if (this) |t| {
        const slot = br.fieldOf(prop) orelse return b.fail(b.cur_span, "`{s}` has no field", .{s.str(s.syms.name(prop))});
        try b.emit(.{ .GetFieldSlot = .{ .dst = dst, .obj = t, .slot = slot } });
    } else {
        const st = br.staticOf(prop) orelse return b.fail(b.cur_span, "`{s}` has no storage", .{s.str(s.syms.name(prop))});
        try b.emit(.{ .LoadStatic = .{ .dst = dst, .static = st } });
    }
    if (!s.syms.flags(prop).lateinit) return dst;
    const checked = b.newReg();
    const n = try b.p.m.internConst(b.p.a, .{ .String = s.str(s.syms.name(prop)) });
    try b.emit(.{ .LateinitCheck = .{ .dst = checked, .src = dst, .name = n } });
    return checked;
}

fn storeField(b: *Builder, prop: Sym, this: ?Reg, value: Reg) Error!void {
    const s = b.p.s;
    const br = b.p.br;
    if (this) |t| {
        const slot = br.fieldOf(prop) orelse return b.fail(b.cur_span, "`{s}` has no field", .{s.str(s.syms.name(prop))});
        try b.emit(.{ .SetFieldSlot = .{ .obj = t, .slot = slot, .value = value } });
    } else {
        const st = br.staticOf(prop) orelse return b.fail(b.cur_span, "`{s}` has no storage", .{s.str(s.syms.name(prop))});
        try b.emit(.{ .StoreStatic = .{ .static = st, .value = value } });
    }
}

/// A delegated property's delegate: its slot on the instance, or its
/// static at the top level.
fn delegateOf(b: *Builder, prop: Sym, this: ?Reg) Error!Reg {
    const s = b.p.s;
    const br = b.p.br;
    const dst = b.newReg();
    if (this) |t| {
        const slot = br.delegateFieldOf(prop) orelse return b.fail(b.cur_span, "`{s}` has no delegate slot", .{s.str(s.syms.name(prop))});
        try b.emit(.{ .GetFieldSlot = .{ .dst = dst, .obj = t, .slot = slot } });
    } else {
        const st = br.staticOf(prop) orelse return b.fail(b.cur_span, "`{s}` has no delegate static", .{s.str(s.syms.name(prop))});
        try b.emit(.{ .LoadStatic = .{ .dst = dst, .static = st } });
    }
    return dst;
}

/// An accessor a class gets from `: I by d`: the interface's accessor on
/// the delegate in the class's slot.
fn forwardAccessor(b: *Builder, prop: Sym, setter: bool) Error!void {
    const s = b.p.s;
    const br = b.p.br;
    const info = s.syms.propertyInfo(prop);
    const cls = s.syms.owner(prop);
    const this = try env.thisOf(b, cls);
    const delegate = try byDelegate(b, cls, info.delegation, this);
    const q = info.forwards;
    const target = if (setter) br.setterOf(q) orelse return b.fail(b.cur_span, "a forwarded setter of a `val`", .{}) else br.getterOf(q);
    var args: std.ArrayList(Reg) = .empty;
    try args.append(b.p.a, delegate);
    var idx: u16 = 1;
    while (idx < paramCount(b)) : (idx += 1) try args.append(b.p.a, try loadParam(b, idx));
    const v = try forwardCall(b, s.syms.owner(q), target, args.items);
    b.terminate(.{ .Return = if (setter) try b.unit() else v });
}

fn byDelegate(b: *Builder, cls: Sym, supertype: u16, this: Reg) Error!Reg {
    const slot = b.p.br.delegateSlot(cls, supertype) orelse return b.fail(b.cur_span, "a `by` member without its delegate slot", .{});
    const dst = b.newReg();
    try b.emit(.{ .GetFieldSlot = .{ .dst = dst, .obj = this, .slot = slot } });
    return dst;
}

/// Calls member `f` of `owner` on `args` (its receiver first) through its
/// slot: through the interface when `owner` is one.
fn forwardCall(b: *Builder, owner: Sym, f: FuncId, args: []const Reg) Error!Reg {
    const s = b.p.s;
    const br = b.p.br;
    const slot = br.slotOf(f) orelse return b.fail(b.cur_span, "a forwarded member without a slot", .{});
    const run = try b.run(args);
    const n: u32 = @intCast(args.len);
    const dst = b.newReg();
    if (s.syms.classInfo(owner).kind == .interface) {
        try b.emit(.{ .CallInterface = .{ .dst = dst, .iface = br.classOf(owner), .slot = slot, .args = run, .n_args = n } });
    } else {
        try b.emit(.{ .RCallVirtual = .{ .dst = dst, .slot = slot, .args = run, .n_args = n } });
    }
    return dst;
}

// ----------------------------------------------------- synthetic members --

/// A member the language declares: data and value-class members, enum
/// `values` and `valueOf`, a `by` forwarder, a SAM class's constructor and
/// method.
pub fn lowerSynthetic(b: *Builder, f: Sym) Error!void {
    const s = b.p.s;
    switch (b.kind) {
        .sam_ctor => return samCtor(b),
        .sam_method => return samMethod(b, f),
        .sam_equals => return samEquals(b, f),
        .sam_hash_code => return samHashCode(b),
        else => {},
    }
    if (s.syms.kind(f) != .function) return b.fail(b.cur_span, "a synthetic declaration that is not a function", .{});
    const info = s.syms.functionInfo(f);
    if (info.forwards != .none) return forwardFunction(b, f);
    const cls = s.syms.owner(f);
    if (cls == .none or s.syms.kind(cls) != .class) return b.fail(b.cur_span, "a synthetic function outside a class", .{});
    const n = s.str(s.syms.name(f));
    switch (info.synth) {
        .enum_values => return enumValues(b, cls),
        .enum_value_of => return enumValueOf(b, cls),
        .data_equals => return dataEquals(b, cls),
        .data_hash_code => return dataHashCode(b, cls),
        .data_to_string => return dataToString(b, cls),
        .data_copy => return dataCopy(b, cls, f),
        .data_component => return dataComponent(b, cls, info.component),
        .annotation_equals => return annotationEquals(b, cls),
        .annotation_hash_code => return annotationHashCode(b, cls),
        // An annotation instance names its class by its qualified name, as
        // kotlinc's generated `toString` does: `@test.One()`.
        .annotation_to_string => return propertiesToString(b, cls, try std.fmt.allocPrint(b.p.a, "@{s}", .{s.str(s.syms.classInfo(cls).fqn)})),
        .none => {},
    }
    return b.fail(b.cur_span, "synthetic `{s}` has no lowering", .{n});
}

/// A `by` member: the interface member on the delegate in its slot, with
/// this member's parameters.
fn forwardFunction(b: *Builder, f: Sym) Error!void {
    const s = b.p.s;
    const br = b.p.br;
    const info = s.syms.functionInfo(f);
    const cls = s.syms.owner(f);
    const this = try env.thisOf(b, cls);
    const delegate = try byDelegate(b, cls, info.delegation, this);
    const q = info.forwards;
    const target = br.funcOfOpt(q) orelse return b.fail(b.cur_span, "a forwarded member without an id", .{});
    var args: std.ArrayList(Reg) = .empty;
    try args.append(b.p.a, delegate);
    var idx: u16 = 1;
    while (idx < paramCount(b)) : (idx += 1) try args.append(b.p.a, try loadParam(b, idx));
    b.terminate(.{ .Return = try forwardCall(b, s.syms.owner(q), target, args.items) });
}

/// The SAM class's constructor: the function value into slot 0.
fn samCtor(b: *Builder) Error!void {
    const this = try loadParam(b, 0);
    const value = try loadParam(b, 1);
    try b.emit(.{ .SetFieldSlot = .{ .obj = this, .slot = 0, .value = value } });
    b.terminate(.{ .Return = this });
}

/// The SAM class's method: its function value invoked with the method's
/// parameters.
fn samMethod(b: *Builder, iface: Sym) Error!void {
    _ = iface;
    const this = try loadParam(b, 0);
    const fv = b.newReg();
    try b.emit(.{ .GetFieldSlot = .{ .dst = fv, .obj = this, .slot = 0 } });
    var regs: std.ArrayList(Reg) = .empty;
    try regs.append(b.p.a, fv);
    var idx: u16 = 1;
    while (idx < paramCount(b)) : (idx += 1) try regs.append(b.p.a, try loadParam(b, idx));
    const run = try b.run(regs.items);
    const dst = b.newReg();
    try b.emit(.{ .RCallValue = .{ .dst = dst, .callee = run, .args = Reg.from(run.int() + 1), .n_args = @intCast(regs.items.len - 1) } });
    b.terminate(.{ .Return = dst });
}

/// The SAM class's `equals`: the same wrapper, or a wrapper of the
/// interface over an equal function, as the JVM's wrapper over a callable
/// reference or a function value compares.
fn samEquals(b: *Builder, iface: Sym) Error!void {
    const cls = b.p.br.samClassOf(iface) orelse return b.fail(b.cur_span, "a fun interface without a SAM class", .{});
    const this = try loadParam(b, 0);
    const other = try loadParam(b, 1);
    const yes = try b.newBlock();
    const no = try b.newBlock();
    const same = b.newReg();
    try b.emit(.{ .BinOp = .{ .dst = same, .op = .IdentEq, .lhs = this, .rhs = other } });
    const check = try b.newBlock();
    b.terminate(.{ .Branch = .{ .cond = same, .t = yes, .f = check } });
    b.switchTo(check);
    const is = b.newReg();
    try b.emit(.{ .RInstanceOf = .{ .dst = is, .src = other, .class = cls, .nullable = false } });
    const compare = try b.newBlock();
    b.terminate(.{ .Branch = .{ .cond = is, .t = compare, .f = no } });
    b.switchTo(compare);
    const x = b.newReg();
    try b.emit(.{ .GetFieldSlot = .{ .dst = x, .obj = this, .slot = 0 } });
    const y = b.newReg();
    try b.emit(.{ .GetFieldSlot = .{ .dst = y, .obj = other, .slot = 0 } });
    const eq = try valuesEqual(b, try anyEquals(b), x, y);
    b.terminate(.{ .Branch = .{ .cond = eq, .t = yes, .f = no } });
    b.switchTo(yes);
    b.terminate(.{ .Return = try b.emitConst(.{ .Bool = true }) });
    b.switchTo(no);
    b.terminate(.{ .Return = try b.emitConst(.{ .Bool = false }) });
}

/// The SAM class's `hashCode`: its function's.
fn samHashCode(b: *Builder) Error!void {
    const this = try loadParam(b, 0);
    const fv = b.newReg();
    try b.emit(.{ .GetFieldSlot = .{ .dst = fv, .obj = this, .slot = 0 } });
    b.terminate(.{ .Return = try callStatic(b, try baseExtension(b, "hashCode"), &.{fv}) });
}

/// A data or value class's constructor properties, in parameter order.
fn dataProperties(b: *Builder, cls: Sym) Error![]const Sym {
    const s = b.p.s;
    var out: std.ArrayList(Sym) = .empty;
    const c = switch (s.syms.get(cls).decl) {
        .class => |c| c,
        else => return out.items,
    };
    for (c.primary_params) |*cp| {
        if (cp.property == null) continue;
        if (ctorProperty(s, cls, cp)) |p| try out.append(b.p.a, p);
    }
    return out.items;
}

/// `recv.p` for property `p` of the class.
fn readProp(b: *Builder, p: Sym, recv: Reg) Error!Reg {
    const nr: NameRec = .{ .kind = .property, .target = p, .dispatch = .expr };
    return name_mod.read(b, &nr, recv);
}

fn dataComponent(b: *Builder, cls: Sym, k: usize) Error!void {
    const props = try dataProperties(b, cls);
    if (k == 0 or k > props.len) return b.fail(b.cur_span, "component{d} past the properties", .{k});
    const this = try env.thisOf(b, cls);
    b.terminate(.{ .Return = try readProp(b, props[k - 1], this) });
}

/// `copy(...)`: a new instance of the class from the parameters, with the
/// hidden values this instance was made with.
fn dataCopy(b: *Builder, cls: Sym, f: Sym) Error!void {
    const s = b.p.s;
    const br = b.p.br;
    const c = br.classOfOpt(cls) orelse return b.fail(b.cur_span, "a data class without an id", .{});
    const ctor = br.funcOfOpt(s.syms.classInfo(cls).primary_ctor) orelse return b.fail(b.cur_span, "a data class without a constructor", .{});
    var args: std.ArrayList(Reg) = .empty;
    if (env.outerOf(s, cls)) |outer| try args.append(b.p.a, try env.receiver(b, env.thisKind(s, outer), outer));
    try args.appendSlice(b.p.a, try env.materializeCaptures(b, br.class_captures[c.int()]));
    for (s.syms.functionInfo(f).params) |p| try args.append(b.p.a, try env.readLocal(b, p));
    const dst = b.newReg();
    try b.emit(.{ .RNewInstance = .{ .dst = dst, .class = c, .ctor = ctor, .args = try b.run(args.items), .n_args = @intCast(args.items.len) } });
    b.terminate(.{ .Return = dst });
}

/// `Name(a=1, b=2)`.
fn dataToString(b: *Builder, cls: Sym) Error!void {
    const s = b.p.s;
    // A data object renders as its name.
    if (s.syms.classInfo(cls).kind == .object) {
        b.terminate(.{ .Return = try b.emitConst(.{ .String = s.str(s.syms.name(cls)) }) });
        return;
    }
    return propertiesToString(b, cls, s.str(s.syms.name(cls)));
}

/// `<head>(a=1, b=2)` over the constructor properties: `Name` for a data
/// class, `@pkg.Name` for an annotation instance.
fn propertiesToString(b: *Builder, cls: Sym, head: []const u8) Error!void {
    const s = b.p.s;
    const this = try env.thisOf(b, cls);
    const to_string = try baseExtension(b, "toString");
    const props = try dataProperties(b, cls);
    var acc = try b.emitConst(.{ .String = try std.fmt.allocPrint(b.p.a, "{s}(", .{head}) });
    for (props, 0..) |p, i| {
        const label = try std.fmt.allocPrint(b.p.a, "{s}{s}=", .{ if (i == 0) "" else ", ", s.str(s.syms.name(p)) });
        acc = try concat(b, acc, try b.emitConst(.{ .String = label }));
        const v = try readProp(b, p, this);
        // An array renders by its elements, as the JVM's `Arrays.toString`
        // does: `[1, 2]`.
        const f = (try arrayContent(b, p, "contentToString", 0)) orelse to_string;
        acc = try concat(b, acc, try callStatic(b, f, &.{v}));
    }
    acc = try concat(b, acc, try b.emitConst(.{ .String = ")" }));
    b.terminate(.{ .Return = acc });
}

/// `31 * h + p.hashCode()` over the properties, `null` hashing to 0.
fn dataHashCode(b: *Builder, cls: Sym) Error!void {
    const s = b.p.s;
    // A data object's hash is its qualified name's, as kotlinc's JVM
    // backend generates it.
    const kind = s.syms.classInfo(cls).kind;
    if (kind == .object or kind == .companion) {
        b.terminate(.{ .Return = try b.emitConst(.{ .Int = stringHash(s.str(s.syms.classInfo(cls).fqn)) }) });
        return;
    }
    const this = try env.thisOf(b, cls);
    const hash = try baseExtension(b, "hashCode");
    const props = try dataProperties(b, cls);
    var acc: ?Reg = null;
    const k31 = try b.emitConst(.{ .Int = 31 });
    for (props) |p| {
        const h = try callStatic(b, hash, &.{try readProp(b, p, this)});
        if (acc) |x| {
            const m = b.newReg();
            try b.emit(.{ .BinOp = .{ .dst = m, .op = .Mul, .lhs = x, .rhs = k31 } });
            const sum = b.newReg();
            try b.emit(.{ .BinOp = .{ .dst = sum, .op = .Add, .lhs = m, .rhs = h } });
            acc = sum;
        } else acc = h;
    }
    b.terminate(.{ .Return = acc orelse try b.emitConst(.{ .Int = 0 }) });
}

/// An annotation instance's hash, as `java.lang.annotation.Annotation`
/// defines it: the sum over its members of `(127 * name.hashCode()) xor
/// value.hashCode()`.
fn annotationHashCode(b: *Builder, cls: Sym) Error!void {
    const s = b.p.s;
    const this = try env.thisOf(b, cls);
    const hash = try baseExtension(b, "hashCode");
    const props = try dataProperties(b, cls);
    var acc = try b.emitConst(.{ .Int = 0 });
    for (props) |p| {
        const key = try b.emitConst(.{ .Int = 127 *% stringHash(s.str(s.syms.name(p))) });
        const v = try readProp(b, p, this);
        // An array member hashes by content.
        const h = if (try arrayContent(b, p, "contentHashCode", 0)) |f| try callStatic(b, f, &.{v}) else try callStatic(b, hash, &.{v});
        const x = b.newReg();
        try b.emit(.{ .BinOp = .{ .dst = x, .op = .Xor, .lhs = key, .rhs = h } });
        const sum = b.newReg();
        try b.emit(.{ .BinOp = .{ .dst = sum, .op = .Add, .lhs = acc, .rhs = x } });
        acc = sum;
    }
    b.terminate(.{ .Return = acc });
}

/// An annotation instance equals another of its class whose members are
/// each equal, array members by content.
fn annotationEquals(b: *Builder, cls: Sym) Error!void {
    const br = b.p.br;
    const this = try env.thisOf(b, cls);
    const other = try loadParam(b, 1);
    const yes = try b.newBlock();
    const no = try b.newBlock();
    const same = b.newReg();
    try b.emit(.{ .BinOp = .{ .dst = same, .op = .IdentEq, .lhs = this, .rhs = other } });
    const check = try b.newBlock();
    b.terminate(.{ .Branch = .{ .cond = same, .t = yes, .f = check } });
    b.switchTo(check);
    const is = b.newReg();
    try b.emit(.{ .RInstanceOf = .{ .dst = is, .src = other, .class = br.classOf(cls), .nullable = false } });
    var next = try b.newBlock();
    b.terminate(.{ .Branch = .{ .cond = is, .t = next, .f = no } });
    const any_equals = try anyEquals(b);
    for (try dataProperties(b, cls)) |p| {
        b.switchTo(next);
        const x = try readProp(b, p, this);
        const y = try readProp(b, p, other);
        const eq = if (try arrayContent(b, p, "contentEquals", 1)) |f| try callStatic(b, f, &.{ x, y }) else try valuesEqual(b, any_equals, x, y);
        next = try b.newBlock();
        b.terminate(.{ .Branch = .{ .cond = eq, .t = next, .f = no } });
    }
    b.switchTo(next);
    b.terminate(.{ .Goto = yes });
    b.switchTo(yes);
    b.terminate(.{ .Return = try b.emitConst(.{ .Bool = true }) });
    b.switchTo(no);
    b.terminate(.{ .Return = try b.emitConst(.{ .Bool = false }) });
}

/// For a property of an array type, the `kotlin.collections` extension
/// `name` taking `n` parameters whose receiver is that array class
/// (`contentEquals`, `contentHashCode`); null for any other type.
fn arrayContent(b: *Builder, p: Sym, comptime name: []const u8, n: usize) Error!?FuncId {
    const s = b.p.s;
    const cls = s.types.classSym(try s.types.makeNotNull(try sema.headers.propertyType(s, p)));
    if (cls == .none) return null;
    const pkg_name = s.names.lookup("kotlin.collections") orelse return null;
    const pkg = s.syms.package_by_fqn.get(pkg_name) orelse return null;
    const fname = s.names.lookup(name) orelse return null;
    for (sema.scope.membersOf(s, pkg, fname)) |m| {
        if (s.syms.kind(m) != .function) continue;
        try sema.headers.functionHeader(s, m);
        const info = s.syms.functionInfo(m);
        if (info.params.len != n or info.receiver == .none) continue;
        if (s.types.classSym(try s.types.makeNotNull(info.receiver)) != cls) continue;
        if (b.p.br.funcOfOpt(m)) |f| return f;
    }
    return null;
}

/// `String.hashCode` of a name: `31 * h + c` over its UTF-16 units.
fn stringHash(name: []const u8) i32 {
    var h: i32 = 0;
    var it = std.unicode.Utf8View.initUnchecked(name).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp >= 0x10000) {
            const v = cp - 0x10000;
            h = 31 *% h +% @as(i32, @intCast(0xD800 + (v >> 10)));
            h = 31 *% h +% @as(i32, @intCast(0xDC00 + (v & 0x3FF)));
        } else h = 31 *% h +% @as(i32, @intCast(cp));
    }
    return h;
}

/// The same instance, or an instance of the class whose properties are
/// each equal.
fn dataEquals(b: *Builder, cls: Sym) Error!void {
    const s = b.p.s;
    const br = b.p.br;
    const this = try env.thisOf(b, cls);
    const other = try loadParam(b, 1);
    const yes = try b.newBlock();
    const no = try b.newBlock();
    const same = b.newReg();
    try b.emit(.{ .BinOp = .{ .dst = same, .op = .IdentEq, .lhs = this, .rhs = other } });
    const check = try b.newBlock();
    b.terminate(.{ .Branch = .{ .cond = same, .t = yes, .f = check } });
    b.switchTo(check);
    const is = b.newReg();
    try b.emit(.{ .RInstanceOf = .{ .dst = is, .src = other, .class = br.classOf(cls), .nullable = false } });
    var next = try b.newBlock();
    b.terminate(.{ .Branch = .{ .cond = is, .t = next, .f = no } });
    const any_equals = try anyEquals(b);
    for (try dataProperties(b, cls)) |p| {
        b.switchTo(next);
        const x = try readProp(b, p, this);
        const y = try readProp(b, p, other);
        const eq = try valuesEqual(b, any_equals, x, y);
        next = try b.newBlock();
        b.terminate(.{ .Branch = .{ .cond = eq, .t = next, .f = no } });
    }
    b.switchTo(next);
    b.terminate(.{ .Goto = yes });
    b.switchTo(yes);
    b.terminate(.{ .Return = try b.emitConst(.{ .Bool = true }) });
    b.switchTo(no);
    b.terminate(.{ .Return = try b.emitConst(.{ .Bool = false }) });
    _ = s;
}

/// `x == y`: both null, or `x.equals(y)` through `Any.equals`'s slot.
fn valuesEqual(b: *Builder, any_equals: FuncId, x: Reg, y: Reg) Error!Reg {
    const result = b.newReg();
    const split = try b.branchOnNull(x);
    const join = try b.newBlock();
    b.switchTo(split.is_null);
    try b.emit(.{ .BinOp = .{ .dst = result, .op = .IdentEq, .lhs = y, .rhs = try b.nullValue() } });
    b.terminate(.{ .Goto = join });
    b.switchTo(split.not_null);
    const slot = b.p.br.slotOf(any_equals) orelse return b.fail(b.cur_span, "`Any.equals` has no slot", .{});
    try b.emit(.{ .RCallVirtual = .{ .dst = result, .slot = slot, .args = try b.run(&.{ x, y }), .n_args = 2 } });
    b.terminate(.{ .Goto = join });
    b.switchTo(join);
    return result;
}

fn anyEquals(b: *Builder) Error!FuncId {
    const s = b.p.s;
    const any = s.builtins.any;
    if (any != .none) {
        for (sema.symbols.Symbols.members(&s.syms.classInfo(any).members, sema.wk.equals)) |m| {
            if (b.p.br.funcOfOpt(m)) |f| return f;
        }
    }
    return b.fail(b.cur_span, "the base declares no `Any.equals`", .{});
}

/// `values()`: a new array of the entries in order.
fn enumValues(b: *Builder, cls: Sym) Error!void {
    b.terminate(.{ .Return = try entriesArray(b, cls) });
}

fn entriesArray(b: *Builder, cls: Sym) Error!Reg {
    const s = b.p.s;
    const br = b.p.br;
    var regs: std.ArrayList(Reg) = .empty;
    for (s.syms.classInfo(cls).enum_entries) |e| {
        const st = br.staticOf(e) orelse return b.fail(b.cur_span, "an entry without a static", .{});
        const r = b.newReg();
        try b.emit(.{ .LoadStatic = .{ .dst = r, .static = st } });
        try regs.append(b.p.a, r);
    }
    const arr = dispatch.classIdOf(br, s.builtins.array) orelse return b.fail(b.cur_span, "the base declares no `kotlin.Array`", .{});
    const dst = b.newReg();
    try b.emit(.{ .NewArray = .{ .dst = dst, .class = arr, .args = try b.run(regs.items), .n_args = @intCast(regs.items.len) } });
    return dst;
}

/// `valueOf(value)`: the entry of that name, else
/// `IllegalArgumentException("No enum constant E.value")`.
fn enumValueOf(b: *Builder, cls: Sym) Error!void {
    const s = b.p.s;
    const br = b.p.br;
    const value = try loadParam(b, b.env.values_at);
    // `valueOf` initializes the class, a name no entry has included.
    try ensureEnumInit(b, cls);
    for (s.syms.classInfo(cls).enum_entries) |e| {
        const st = br.staticOf(e) orelse return b.fail(b.cur_span, "an entry without a static", .{});
        const n = try b.emitConst(.{ .String = s.str(s.syms.name(e)) });
        const eq = b.newReg();
        try b.emit(.{ .BinOp = .{ .dst = eq, .op = .Eq, .lhs = value, .rhs = n } });
        const hit = try b.newBlock();
        const miss = try b.newBlock();
        b.terminate(.{ .Branch = .{ .cond = eq, .t = hit, .f = miss } });
        b.switchTo(hit);
        const r = b.newReg();
        try b.emit(.{ .LoadStatic = .{ .dst = r, .static = st } });
        b.terminate(.{ .Return = r });
        b.switchTo(miss);
    }
    const prefix = try std.fmt.allocPrint(b.p.a, "No enum constant {s}.", .{s.str(s.syms.classInfo(cls).fqn)});
    const msg = try concat(b, try b.emitConst(.{ .String = prefix }), value);
    b.terminate(.{ .Throw = try newThrowable(b, "kotlin.IllegalArgumentException", msg) });
}

/// A new instance of the base's throwable class `fqn` with `message`.
fn newThrowable(b: *Builder, fqn: []const u8, message: Reg) Error!Reg {
    const s = b.p.s;
    const br = b.p.br;
    const cls = s.classByFqn(fqn);
    if (cls == .none) return b.fail(b.cur_span, "the base declares no `{s}`", .{fqn});
    for (sema.symbols.Symbols.members(&s.syms.classInfo(cls).members, sema.wk.init)) |ctor| {
        if (s.syms.kind(ctor) != .constructor or s.syms.functionInfo(ctor).params.len != 1) continue;
        const f = br.funcOfOpt(ctor) orelse continue;
        const dst = b.newReg();
        try b.emit(.{ .RNewInstance = .{ .dst = dst, .class = br.classOf(cls), .ctor = f, .args = try b.run(&.{message}), .n_args = 1 } });
        return dst;
    }
    return b.fail(b.cur_span, "`{s}` has no constructor taking a message", .{fqn});
}

fn concat(b: *Builder, x: Reg, y: Reg) Error!Reg {
    const dst = b.newReg();
    try b.emit(.{ .BinOp = .{ .dst = dst, .op = .StringConcat, .lhs = x, .rhs = y } });
    return dst;
}

fn callStatic(b: *Builder, f: FuncId, args: []const Reg) Error!Reg {
    const dst = b.newReg();
    try b.emit(.{ .CallStatic = .{ .dst = dst, .func = f, .args = try b.run(args), .n_args = @intCast(args.len) } });
    return dst;
}

/// The base's `Any?.name()` extension in package `kotlin`: `toString` and
/// `hashCode` of a value that may be null.
fn baseExtension(b: *Builder, name: []const u8) Error!FuncId {
    const s = b.p.s;
    const fail_msg = "the base declares no `Any?.{s}()` in package kotlin";
    const pkg_name = s.names.lookup("kotlin") orelse return b.fail(b.cur_span, fail_msg, .{name});
    const pkg = s.syms.package_by_fqn.get(pkg_name) orelse return b.fail(b.cur_span, fail_msg, .{name});
    const n = s.names.lookup(name) orelse return b.fail(b.cur_span, fail_msg, .{name});
    for (sema.scope.membersOf(s, pkg, n)) |m| {
        if (s.syms.kind(m) != .function) continue;
        try sema.headers.functionHeader(s, m);
        const info = s.syms.functionInfo(m);
        if (info.receiver != s.t.any_q or info.params.len != 0) continue;
        if (b.p.br.funcOfOpt(m)) |f| return f;
    }
    return b.fail(b.cur_span, fail_msg, .{name});
}

// ------------------------------------------- object expressions, locals --

/// `object : ... { }`: a new instance of its class, given the values the
/// class captures.
pub fn lowerObjectExpr(b: *Builder, e: *const ast.Expr) Error!Reg {
    const s = b.p.s;
    const br = b.p.br;
    const o = e.ObjectExpr;
    const cls = try b.decl(o.id);
    const c = br.classOfOpt(cls) orelse return b.fail(o.span, "an object expression without a class id", .{});
    const ctor = br.funcOfOpt(s.syms.classInfo(cls).primary_ctor) orelse return b.fail(o.span, "an object expression without a constructor", .{});
    const caps = try env.materializeCaptures(b, br.class_captures[c.int()]);
    const dst = b.newReg();
    try b.emit(.{ .RNewInstance = .{ .dst = dst, .class = c, .ctor = ctor, .args = try b.run(caps), .n_args = @intCast(caps.len) } });
    return dst;
}

/// A local class or object declaration emits nothing: its members lower
/// like any member, and each construction passes its captures.
pub fn lowerLocalClass(b: *Builder, d: *const ast.Decl) Error!void {
    _ = .{ b, d };
}

// --------------------------------------------------- collection guards --

/// The members of the collection interfaces whose argument a caller may
/// pass as any value, and what an override answers for one of another
/// type: kotlinc's type-checked bridges.
const guarded = [_]struct { fqn: []const u8, name: []const u8, answer: enum { false_, minus_one, null_ } }{
    .{ .fqn = "kotlin.collections.Collection", .name = "contains", .answer = .false_ },
    .{ .fqn = "kotlin.collections.List", .name = "indexOf", .answer = .minus_one },
    .{ .fqn = "kotlin.collections.List", .name = "lastIndexOf", .answer = .minus_one },
    .{ .fqn = "kotlin.collections.MutableCollection", .name = "remove", .answer = .false_ },
    .{ .fqn = "kotlin.collections.Map", .name = "containsKey", .answer = .false_ },
    .{ .fqn = "kotlin.collections.Map", .name = "containsValue", .answer = .false_ },
    .{ .fqn = "kotlin.collections.Map", .name = "get", .answer = .null_ },
    .{ .fqn = "kotlin.collections.MutableMap", .name = "remove", .answer = .null_ },
};

/// An override of one of those members whose parameter erases to a class
/// narrower than `Any`, or does not admit null, first checks its argument,
/// as the bridge kotlinc generates for it does: `if (element !is E) return
/// <answer>`, which a null fails for a non-null `E`.
pub fn collectionGuard(b: *Builder, f: Sym) Error!void {
    const s = b.p.s;
    const info = s.syms.functionInfo(f);
    if (info.params.len != 1 or info.receiver != .none or !env.hasThis(s, f)) return;
    const name = s.str(s.syms.name(f));
    const answer = for (guarded) |g| {
        if (!std.mem.eql(u8, name, g.name)) continue;
        const cls = s.classByFqn(g.fqn);
        if (cls == .none) continue;
        if (try overridesMemberOf(s, f, cls, 0)) break g.answer;
    } else return;
    const p = info.params[0];
    const t = try sema.headers.paramType(s, p);
    const erased = try erasedClass(s, t, 0);
    const nullable = try admitsNull(s, t, 0);
    if (erased == .none or (erased == s.builtins.any and nullable)) return;
    const c = b.p.br.classOfOpt(erased) orelse return;
    const v = (try env.homeOf(b, p)) orelse return;
    const value = switch (v) {
        .reg, .cell => |r| r,
    };
    const ok = b.newReg();
    try b.emit(.{ .RInstanceOf = .{ .dst = ok, .src = value, .class = c, .nullable = nullable } });
    const body_blk = try b.newBlock();
    const reject = try b.newBlock();
    b.terminate(.{ .Branch = .{ .cond = ok, .t = body_blk, .f = reject } });
    b.switchTo(reject);
    const out = switch (answer) {
        .false_ => try b.emitConst(.{ .Bool = false }),
        .minus_one => try b.emitConst(.{ .Int = -1 }),
        .null_ => try b.nullValue(),
    };
    b.terminate(.{ .Return = out });
    b.switchTo(body_blk);
}

/// Whether `f` overrides, at any depth, a member declared in `cls`.
fn overridesMemberOf(s: *sema.Sema, f: Sym, cls: Sym, depth: u8) Error!bool {
    if (depth > 16) return false;
    for (try sema.members.overridden(s, f)) |o| {
        if (s.syms.owner(o) == cls) return true;
        if (try overridesMemberOf(s, o, cls, depth + 1)) return true;
    }
    return false;
}

/// Whether `t` admits null: a nullable type, or a type parameter whose
/// first bound does (none is `Any?`).
fn admitsNull(s: *sema.Sema, t: sema.TypeId, depth: u8) Error!bool {
    if (s.types.isNullable(t)) return true;
    if (depth > 8) return true;
    return switch (s.types.get(t)) {
        .param => |tp| blk: {
            const bounds = s.syms.typeParamInfo(tp.sym).bounds;
            if (bounds.len == 0) break :blk true;
            break :blk admitsNull(s, bounds[0], depth + 1);
        },
        else => false,
    };
}

/// The class a type erases to: its own, or a type parameter's first bound's.
fn erasedClass(s: *sema.Sema, t: sema.TypeId, depth: u8) Error!Sym {
    if (t == .none or depth > 8) return .none;
    return switch (s.types.get(t)) {
        .class => |c| c.sym,
        .param => |tp| blk: {
            const bounds = s.syms.typeParamInfo(tp.sym).bounds;
            if (bounds.len == 0) break :blk s.builtins.any;
            break :blk erasedClass(s, bounds[0], depth + 1);
        },
        else => .none,
    };
}
