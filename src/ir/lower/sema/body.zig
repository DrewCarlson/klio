//! Bodies, statements and the expression switch. Every expression and
//! statement kind routes to the function of the package that lowers it.

const std = @import("std");
const span = @import("span");
const ast = @import("ast");
const sema = @import("sema");

const ir = @import("../../ir.zig");
const bridge = @import("../../core/bridge.zig");
const builder = @import("builder.zig");
const records = @import("records.zig");
const compose = @import("compose.zig");
const env = @import("env.zig");
const name = @import("name.zig");
const coerce = @import("coerce.zig");
const call = @import("call.zig");
const control = @import("control.zig");
const operator = @import("operator.zig");
const types = @import("types.zig");
const classes = @import("classes.zig");
const lambda = @import("lambda.zig");
const tailrec = @import("tailrec.zig");
const refs = @import("refs.zig");
const locals = @import("locals.zig");

const Builder = builder.Builder;
const Program = builder.Program;
const BodyKind = builder.BodyKind;
const Error = records.Error;
const FuncId = ir.FuncId;
const Reg = ir.Reg;
const Sym = sema.Sym;

/// Which builder a `FuncOrigin` lowers on: its body kind, the symbol whose
/// body it is, and the file whose records it reads.
const Plan = struct { kind: BodyKind, owner: Sym, file: u32 };

/// Lowers `f`'s body on its own builder. The body is entered first
/// (`env.enter`: its parameters, receivers and captures), then the package
/// that owns its kind writes it. A body that fails records its error in
/// `p.errors` and leaves `p.lowered` unset; only `OutOfMemory` propagates.
/// A declaration bound to a native, or with no body, has nothing to lower.
pub fn lowerBody(p: *Program, f: FuncId) Error!void {
    const br = p.br;
    if (f.int() >= br.origin.len) return;
    // A literal's body is lowered once a closure is made of it
    // (`lowerClosure`); one passed only to inline calls never runs.
    if (isLiteral(p.s, br.origin[f.int()]) and !(f.int() < p.closures.bit_length and p.closures.isSet(f.int()))) return;
    if (p.isNative(f)) return;
    const origin = br.origin[f.int()];
    const plan = planOf(p, origin) orelse return;
    // Once only: an instantiation may have lowered its callee already.
    if (!try p.markAttempted(f)) return;
    const errors_before = p.errors.items.len;
    const sa = try p.pushScratch();
    defer p.popScratch();
    var b = try Builder.init(p, sa, plan.file, plan.owner, f, plan.kind);
    b.site = try bodySite(p, origin, plan);
    lowerOrigin(&b, origin) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        // `fail` recorded its own error; a missing record and a construct
        // no package lowers yet are recorded here.
        for (p.errors.items[errors_before..]) |le| if (le.func == f) return;
        const e = if (err == error.Unrecorded) blk: {
            const m = b.miss orelse builder.Miss{ .node = .none, .what = "its" };
            break :blk b.fail(b.cur_span, "node {d} ({s}) has no {s} record", .{ m.node.int(), b.cur_kind, m.what });
        } else b.fail(b.cur_span, "this construct is not lowered", .{});
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return;
    };
    try b.finish();
}

/// Where a failure of the body is reported before any expression names
/// one: the declaration it belongs to, the file or enum class an init
/// unit initializes, or the reference an adapter serves.
fn bodySite(p: *Program, origin: bridge.FuncOrigin, plan: Plan) Error!span.Span {
    const s = p.s;
    return switch (origin) {
        .adapter => |i| try refs.referenceSite(p, i),
        .init_unit => |u| switch (p.br.units[u]) {
            .file, .eager_file => |file| if (file < s.files.items.len) (if (s.files.items[file].ast) |f| f.span else builder.zero_span) else builder.zero_span,
            .enum_class => |cls| declSite(s, cls),
        },
        else => declSite(s, plan.owner),
    };
}

fn declSite(s: *sema.Sema, sym: Sym) span.Span {
    if (sym == .none) return builder.zero_span;
    return switch (s.syms.get(sym).decl) {
        .none => builder.zero_span,
        .ident => if (s.syms.kind(sym) == .local) s.syms.localInfo(sym).span else builder.zero_span,
        inline else => |d| if (d) |x| x.span else builder.zero_span,
    };
}

/// Lowers the body of lambda literal `f`, which a closure is being made
/// of, unless it already is.
pub fn lowerClosure(p: *Program, f: FuncId) Error!void {
    if (f.int() >= p.closures.bit_length) try p.closures.resize(p.a, @max(f.int() + 1, p.m.funcs.items.len), false);
    p.closures.set(f.int());
    try lowerBody(p, f);
}

/// Whether an origin is a lambda literal or anonymous function.
fn isLiteral(s: *sema.Sema, origin: bridge.FuncOrigin) bool {
    return switch (origin) {
        .lambda => |sym| switch (s.syms.get(sym).decl) {
            .lambda, .anon_fun => true,
            else => false,
        },
        else => false,
    };
}

fn fileOf(s: *sema.Sema, sym: Sym) u32 {
    return if (sym == .none) sema.symbols.NO_FILE else s.syms.get(sym).file;
}

/// Whether `prop`'s getter (or setter) has nothing to lower: an `expect` or
/// `external` property declares no storage and, without a written
/// accessor, no body, so like a bodyless function its native runs.
pub fn bodylessAccessor(s: *sema.Sema, prop: Sym, setter: bool) bool {
    const fl = s.syms.flags(prop);
    if (!fl.expect and !fl.external) return false;
    if (s.syms.get(prop).decl != .property) return true;
    const written = s.syms.propertyInfo(prop).written;
    return !(if (setter) written.setter else written.getter);
}

fn planOf(p: *Program, origin: bridge.FuncOrigin) ?Plan {
    const s = p.s;
    return switch (origin) {
        .abstract => null,
        .decl => |sym| blk: {
            const flags = s.syms.flags(sym);
            const kind: BodyKind = switch (s.syms.kind(sym)) {
                .constructor => .ctor,
                .function => if (s.syms.functionInfo(sym).forwards != .none) .delegated else .function,
                else => .function,
            };
            // A function without a body runs its native, unless an
            // operation of the primitive table stands for it.
            if (kind == .function and !flags.has_body and !flags.synthetic and p.prims.get(sym) == null) break :blk null;
            break :blk .{ .kind = kind, .owner = sym, .file = fileOf(s, sym) };
        },
        .getter => |prop| if (bodylessAccessor(s, prop, false)) null else .{ .kind = .getter, .owner = prop, .file = fileOf(s, prop) },
        .setter => |prop| if (bodylessAccessor(s, prop, true)) null else .{ .kind = .setter, .owner = prop, .file = fileOf(s, prop) },
        .defaults => |t| .{ .kind = .defaults, .owner = t, .file = fileOf(s, t) },
        .init_unit => .{ .kind = .init_unit, .owner = .none, .file = sema.symbols.NO_FILE },
        .lambda => |sym| .{
            .kind = if (s.syms.get(sym).decl == .function) .local_fun else .lambda,
            .owner = sym,
            .file = fileOf(s, sym),
        },
        .sam_ctor => |sym| .{ .kind = .sam_ctor, .owner = sym, .file = fileOf(s, sym) },
        .sam_method => |sym| .{ .kind = .sam_method, .owner = sym, .file = fileOf(s, sym) },
        .sam_equals => |sym| .{ .kind = .sam_equals, .owner = sym, .file = fileOf(s, sym) },
        .sam_hash_code => |sym| .{ .kind = .sam_hash_code, .owner = sym, .file = fileOf(s, sym) },
        .adapter => .{ .kind = .adapter, .owner = .none, .file = sema.symbols.NO_FILE },
        .restart => |f| .{ .kind = .restart, .owner = f, .file = fileOf(s, f) },
    };
}

fn lowerOrigin(b: *Builder, origin: bridge.FuncOrigin) Error!void {
    const s = b.p.s;
    try env.enter(b);
    switch (origin) {
        .decl => |sym| {
            if (b.p.prims.get(sym) != null) return operator.lowerPrimBody(b, sym);
            switch (b.kind) {
                .ctor => return classes.lowerCtor(b, sym),
                .delegated => return classes.lowerSynthetic(b, sym),
                else => {},
            }
            if (s.syms.flags(sym).synthetic) return classes.lowerSynthetic(b, sym);
            // A body lowered in this build has its AST.
            const fd = switch (s.syms.get(sym).decl) {
                .function => |fd| fd.?,
                else => return classes.lowerSynthetic(b, sym),
            };
            if (fd.body) |*fb| {
                try classes.collectionGuard(b, sym);
                if (compose.composableFunction(s, sym)) return compose.lowerFunctionBody(b, sym, fb);
                return lowerFunctionBody(b, fb);
            }
            return b.fail(fd.span, "`{s}` has no body", .{fd.name.name});
        },
        .getter => |prop| try classes.lowerAccessor(b, prop, false),
        .setter => |prop| try classes.lowerAccessor(b, prop, true),
        .defaults => |t| try call.lowerDefaultsBridge(b, t),
        .init_unit => |u| try classes.lowerInitUnit(b, u),
        .lambda => |sym| try lambda.lowerClosureBody(b, sym),
        .sam_ctor, .sam_method, .sam_equals, .sam_hash_code => |sym| try classes.lowerSynthetic(b, sym),
        .adapter => |i| try refs.lowerAdapter(b, i),
        .restart => |f| try compose.lowerRestart(b, f),
        .abstract => {},
    }
}

/// Lowers `e`. While it lowers, it is the expression a failure names.
pub fn lowerExpr(b: *Builder, e: *const ast.Expr) Error!Reg {
    const saved = b.cur_span;
    const saved_kind = b.cur_kind;
    b.cur_span = e.span();
    b.cur_kind = @tagName(e.*);
    const r = try lowerExprInner(b, e);
    b.cur_span = saved;
    b.cur_kind = saved_kind;
    return r;
}

fn lowerExprInner(b: *Builder, e: *const ast.Expr) Error!Reg {
    return switch (e.*) {
        .IntLit, .FloatLit, .BoolLit, .NullLit, .CharLit => control.lowerLiteral(b, e),
        .StringTemplate => control.lowerTemplate(b, e),
        .Path, .Member => name.lowerName(b, e),
        .Call => call.lowerCall(b, e),
        .Index => operator.lowerIndex(b, e),
        .Binary => operator.lowerBinary(b, e),
        .Unary => |u| switch (u.op) {
            .PreInc, .PreDec => operator.lowerIncDec(b, e),
            .Neg, .Pos, .Not => operator.lowerUnary(b, e),
        },
        .Postfix => |pf| switch (pf.op) {
            .Inc, .Dec => operator.lowerIncDec(b, e),
            .NotNull => control.lowerNotNull(b, e),
        },
        .If => control.lowerIf(b, e),
        .While => control.lowerWhile(b, e),
        .DoWhile => control.lowerDoWhile(b, e),
        .For => control.lowerFor(b, e),
        .Return => control.lowerReturn(b, e),
        .Break => control.lowerBreak(b, e),
        .Continue => control.lowerContinue(b, e),
        .Labeled => control.lowerLabeled(b, e),
        .Block => |*blk| lowerBlock(b, blk),
        .Throw => control.lowerThrow(b, e),
        .Try => control.lowerTry(b, e),
        .Lambda => lambda.lowerLambda(b, e),
        .AnonFun => lambda.lowerAnonFun(b, e),
        .This => env.lowerThis(b, e),
        .Super => env.lowerSuper(b, e),
        .PropertyRef, .MemberRef => refs.lowerCallableRef(b, e),
        .When => control.lowerWhen(b, e),
        .IsCheck => types.lowerIsCheck(b, e),
        .As => types.lowerAs(b, e),
        // A spread operand's value is the array; the call copies its elements.
        .Spread => |sp| lowerExpr(b, sp.expr),
        .ObjectExpr => classes.lowerObjectExpr(b, e),
    };
}

pub fn lowerStmt(b: *Builder, st: *const ast.Stmt) Error!void {
    switch (st.*) {
        .Expr => |*e| try lowerDiscarding(b, e),
        .Decl => |d| switch (d.*) {
            .Property => |prop| try lowerLocalProperty(b, prop),
            .Function => try lambda.lowerLocalFun(b, d),
            .Class, .Object => try classes.lowerLocalClass(b, d),
            // A local type alias only names a type.
            .TypeAlias => {},
        },
        .Assign => |a| switch (a.op) {
            .Assign => try lowerAssign(b, a),
            .Add, .Sub, .Mul, .Div, .Rem => try operator.lowerCompound(b, a),
        },
        .DestructuringDecl => |d| try lowerDestructuring(b, d),
    }
}

/// Lowers `e` for its effects: an `if` or `when` moves no value into a
/// result, a block's statements are all statements, and an increment
/// writes its variable in place. Named by a failure as `lowerExpr` names
/// an expression.
pub fn lowerDiscarding(b: *Builder, e: *const ast.Expr) Error!void {
    const saved = b.cur_span;
    const saved_kind = b.cur_kind;
    b.cur_span = e.span();
    b.cur_kind = @tagName(e.*);
    switch (e.*) {
        .If => try control.lowerIfDiscarding(b, e),
        .When => try control.lowerWhenDiscarding(b, e),
        .Block => |*blk| try lowerStmtsDiscarding(b, blk.stmts),
        .Unary => |u| if (u.op == .PreInc or u.op == .PreDec) try operator.lowerIncDecStmt(b, e) else {
            _ = try lowerExprInner(b, e);
        },
        .Postfix => |pf| if (pf.op == .Inc or pf.op == .Dec) try operator.lowerIncDecStmt(b, e) else {
            _ = try lowerExprInner(b, e);
        },
        else => _ = try lowerExprInner(b, e),
    }
    b.cur_span = saved;
    b.cur_kind = saved_kind;
}

/// The block's statements in order; its value is the last statement's
/// when that is an expression, else `Unit`. Statements after a `return`,
/// `throw`, `break` or `continue` never run and are not lowered.
pub fn lowerBlock(b: *Builder, blk: *const ast.Block) Error!Reg {
    return (try lowerStmts(b, blk.stmts)) orelse b.unit();
}

/// `stmts` in order, as `lowerBlock` lowers them; the last one's value
/// when it is an expression, else null.
pub fn lowerStmts(b: *Builder, stmts: []const ast.Stmt) Error!?Reg {
    return statements(b, stmts, true);
}

/// `stmts` in order, for their effects: a loop's body, a `finally`.
pub fn lowerStmtsDiscarding(b: *Builder, stmts: []const ast.Stmt) Error!void {
    _ = try statements(b, stmts, false);
}

/// Each statement answers for the locals it writes while the values it
/// reads are in flight (`locals.Hazard`); the last one, when its value is
/// the block's, for the enclosing construct's too.
fn statements(b: *Builder, stmts: []const ast.Stmt, want_value: bool) Error!?Reg {
    const saved = b.hazard;
    defer b.hazard = saved;
    for (stmts, 0..) |*st, i| {
        if (b.terminated()) break;
        try traceStmt(b, st);
        if (want_value and i + 1 == stmts.len and st.* == .Expr) {
            var h: locals.Hazard = .{ .what = .{ .stmt = st }, .parent = saved };
            b.hazard = &h;
            return try lowerExpr(b, &st.Expr);
        }
        var h: locals.Hazard = .{ .what = .{ .stmt = st } };
        b.hazard = &h;
        try lowerStmt(b, st);
    }
    return null;
}

/// Lowers `e`, whose value is used as soon as it is computed (a branch's
/// condition, an expression body's result): it answers for its own writes
/// only.
pub fn lowerAlone(b: *Builder, e: *const ast.Expr) Error!Reg {
    const saved = b.hazard;
    defer b.hazard = saved;
    var h: locals.Hazard = .{ .what = .{ .expr = e } };
    b.hazard = &h;
    return lowerExpr(b, e);
}

/// Marks where the frame is in its source, the position a stack trace
/// captured in it reports.
fn traceStmt(b: *Builder, st: *const ast.Stmt) Error!void {
    const sp = switch (st.*) {
        .Expr => |*e| e.span(),
        .Assign => |a| a.span,
        .DestructuringDecl => |d| d.span,
        .Decl => |d| switch (d.*) {
            .Property => |p| p.span,
            else => return,
        },
    };
    try b.emit(.{ .Trace = .{ .span = sp } });
}

/// A function body, block or expression, ending in its return. A block
/// body that runs off its end returns `Unit`.
pub fn lowerFunctionBody(b: *Builder, fb: *const ast.FunctionBody) Error!void {
    try tailrec.begin(b);
    switch (fb.*) {
        .Block => |*blk| {
            try tailrec.markUnitBody(b, blk.stmts);
            try lowerStmtsDiscarding(b, blk.stmts);
            b.terminate(.{ .Return = null });
        },
        .Expr => |*e| {
            try tailrec.markExpr(b, e);
            try b.emit(.{ .Trace = .{ .span = e.span() } });
            const v = try lowerAlone(b, e);
            if (!b.terminated()) b.terminate(.{ .Return = try coerce.convert(b, v, try coerce.scalarOf(b, b.exprType(e.id())), try coerce.returnTo(b, b.owner)) });
        },
    }
}

/// The static type of `e`'s value: its own, or for a block, its last
/// statement's.
pub fn valueType(b: *Builder, e: *const ast.Expr) sema.TypeId {
    return switch (e.*) {
        .Block => |*blk| lastValueType(b, blk.stmts),
        else => b.exprType(e.id()),
    };
}

/// The static type of the value a block of statements ends in: its last
/// statement's, when that is an expression.
pub fn lastValueType(b: *Builder, stmts: []const ast.Stmt) sema.TypeId {
    if (stmts.len == 0) return .none;
    return switch (stmts[stmts.len - 1]) {
        .Expr => |*e| b.exprType(e.id()),
        else => .none,
    };
}

/// A local `val` or `var`. A delegated one keeps its delegate in its home
/// and reads and writes through it; one declared without a value holds
/// `null` until assigned.
pub fn lowerLocalProperty(b: *Builder, prop: *const ast.Property) Error!void {
    const sym = try b.decl(prop.id);
    if (prop.delegate) |d| {
        var delegate = try lowerExpr(b, d);
        const g = try b.delegate(prop.id);
        if (g.provide) |*pr| delegate = try env.delegateCall(b, pr, delegate, prop, null, .none);
        return env.bindLocal(b, sym, delegate);
    }
    const init = prop.init orelse return env.declareLocal(b, sym);
    const from = locals.mark(b);
    const v = try lowerExpr(b, init);
    try env.bindLocalFrom(b, sym, try coerce.coerce(b, v, b.exprType(init.id()), b.p.s.syms.localInfo(sym).ty), from);
}

/// `target = value`: a name's write, or an index target's `set` through
/// `operator.lowerIndexSet`. The target's records are on the assignment's
/// node, at the target's names. A receiver is evaluated before the value.
pub fn lowerAssign(b: *Builder, a: *const ast.AssignStmt) Error!void {
    switch (a.target) {
        .Index => return operator.lowerIndexSet(b, &a.target, &a.value, a.id),
        .Path => |p| {
            const segs = p.segments;
            const last = segs[segs.len - 1];
            const rec = b.nameAt(a.id, last.span.start) orelse return b.nameMissed(a.id);
            const prefix = if (segs.len > 1) try name.pathValue(b, a.id, segs[0 .. segs.len - 1]) else null;
            const prefix_ty: sema.TypeId = if (segs.len > 1) try name.pathType(b, a.id, segs[0 .. segs.len - 1]) else .none;
            const from = locals.mark(b);
            const v = try lowerExpr(b, &a.value);
            const v_ty = b.exprType(a.value.id());
            if (rec.kind == .local) return env.writeLocalFrom(b, rec.target, try coerce.coerce(b, v, v_ty, try name.heldType(b, &rec)), from);
            return name.write(b, &rec, prefix, prefix_ty, v, v_ty);
        },
        .Member => |m| {
            const rec = b.nameAt(a.id, m.name.span.start) orelse return b.nameMissed(a.id);
            const recv: ?Reg = if (name.takesExpr(&rec)) try name.memberReceiver(b, a.id, m.receiver) else null;
            const recv_ty = b.exprType(m.receiver.id());
            if (!m.safe or recv == null) {
                const v = try lowerExpr(b, &a.value);
                return name.write(b, &rec, recv, recv_ty, v, b.exprType(a.value.id()));
            }
            // `a?.x = v`: neither `v` nor the write happen when `a` is null.
            const split = try b.branchOnNull(recv.?);
            const join = try b.newBlock();
            b.switchTo(split.not_null);
            const v = try lowerExpr(b, &a.value);
            try name.write(b, &rec, recv, recv_ty, v, b.exprType(a.value.id()));
            b.terminate(.{ .Goto = join });
            b.switchTo(split.is_null);
            b.terminate(.{ .Goto = join });
            b.switchTo(join);
        },
        else => return b.fail(a.span, "not an assignable target", .{}),
    }
}

/// `val (a, b) = x`.
pub fn lowerDestructuring(b: *Builder, d: *const ast.DestructuringDeclStmt) Error!void {
    const v = try lowerExpr(b, &d.init);
    try destructure(b, d.id, d.names, d.sources, v);
}

/// Binds each name of a destructuring to its part of `value`, in order:
/// `componentN()` or, by name, the property. The records are on `node` at
/// each name, a renamed entry's read (`val n = x`) at its source; `_`
/// takes nothing. `for ((k, v) in m)` destructures through here too.
pub fn destructure(b: *Builder, node: ast.NodeId, idents: []const ast.Ident, sources: []const ast.Ident, value: Reg) Error!void {
    for (idents, 0..) |id, i| {
        if (id.isPlaceholder()) {
            // `_ = prop` still reads the property, for its effect.
            if (i < sources.len and sources[i].span.start != id.span.start) {
                if (try b.destructureEntry(node, sources[i].span.start)) |src| if (src.name) |*n| {
                    _ = try name.read(b, n, value);
                };
            }
            continue;
        }
        var entry = (try b.destructureEntry(node, id.span.start)) orelse return b.nameMissed(node);
        if (entry.call == null and entry.name == null and i < sources.len) {
            if (try b.destructureEntry(node, sources[i].span.start)) |src| {
                entry.call = src.call;
                entry.name = src.name;
            }
        }
        const part = if (entry.call) |*c|
            try call.emitCall(b, c, .{ .exprs = &.{}, .regs = &.{}, .receiver = value })
        else if (entry.name) |*n|
            try name.read(b, n, value)
        else
            return b.fail(id.span, "destructuring entry `{s}` has no component", .{id.name});
        if (entry.local == .none) return b.fail(id.span, "destructuring entry `{s}` declares no local", .{id.name});
        try env.bindLocal(b, entry.local, part);
    }
}
