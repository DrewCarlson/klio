//! Calls: a `CallRec` and its operands become an argument run in the
//! callee's declared order (receiver, contexts, extension receiver, value
//! parameters with defaults masks and varargs, reified type values), with
//! conversions applied, then the instruction `dispatch.choose` names.
//!
//! Operands are evaluated in source order after the receiver, then placed
//! in the order the calling convention gives the callee's frame (`Layout`).
//! An omitted argument sends the call through the callee's defaults bridge,
//! which takes the callee's parameters and one mask word per 32 value
//! parameters, evaluates each omitted default in the declaring scope, and
//! calls the callee with its own dispatch. A composable that fills its own
//! defaults takes the omitted arguments' bits in `$default` instead.

const std = @import("std");
const span = @import("span");
const sema = @import("sema");
const operator = @import("operator.zig");
const ast = @import("ast");

const ir = @import("../../ir.zig");
const bridge = @import("../../core/bridge.zig");
const builder = @import("builder.zig");
const records = @import("records.zig");
const dispatch = @import("dispatch.zig");
const env = @import("env.zig");
const body = @import("body.zig");
const name_mod = @import("name.zig");
const control = @import("control.zig");
const types_mod = @import("types.zig");
const lambda_mod = @import("lambda.zig");
const inline_mod = @import("inline.zig");
const tailrec = @import("tailrec.zig");
const compose = @import("compose.zig");
const locals = @import("locals.zig");
const coerce = @import("coerce.zig");
const classes = @import("classes.zig");

const Allocator = std.mem.Allocator;
const Builder = builder.Builder;
const Program = builder.Program;
const Error = records.Error;
const CallRec = records.CallRec;
const NameRec = records.NameRec;
const ArgSource = sema.records.ArgSource;
const VarargPart = sema.records.VarargPart;
const Conv = sema.records.Conv;
const How = dispatch.How;
const FuncId = ir.FuncId;
const ClassId = ir.ClassId;
const Reg = ir.Reg;
const Sym = sema.Sym;
const TypeId = sema.TypeId;
const NodeId = ast.NodeId;

pub const Operands = struct {
    /// The source operand expressions (the design's 1.4), in order; null for
    /// an operand the caller already lowered into `regs`.
    exprs: []const ?*const ast.Expr,
    regs: []const ?Reg,
    /// The `.expr` receiver, already lowered. For a `value_invoke`, the
    /// value invoked.
    receiver: ?Reg,
    /// A `value_invoke` of an extension function type written `recv.f()`:
    /// `recv`, which fills the `.receiver` parameter.
    invoke_receiver: ?Reg = null,
    /// Where the construct is written, for a lowering error.
    sp: span.Span = no_span,
    /// A self-call of a `tailrec` function in tail position.
    tail: bool = false,
    /// The call as written, when there is one: a composable call reads
    /// its receiver and invoked value from it.
    call: ?*const ast.Expr = null,
    /// Where lowering stood before the caller lowered operands the call
    /// alone consumes (a written call's receiver), which its argument run
    /// may then compute in place (`locals.runFrom`).
    from: ?locals.Mark = null,
    /// The static type of each operand in `regs`, where the caller knows
    /// it; an operand from `exprs` has its expression's.
    types: []const TypeId = &.{},
    /// The `.expr` receiver's static type.
    receiver_ty: TypeId = .none,
    /// The call's own static type, which its result is converted to.
    result_ty: TypeId = .none,

    pub fn count(ops: Operands) usize {
        return @max(ops.exprs.len, ops.regs.len);
    }
};

const no_span: span.Span = .{ .file = span.FileId.from(0), .start = 0, .end = 0 };

// ---------------------------------------------------------------- layout --

/// Where each part of a frame's parameters sits, in the order of the
/// calling convention (docs/design/LOWER-SEMA-PACKAGES.md 2.2).
pub const Layout = struct {
    /// A member's dispatch receiver, or a constructor's instance, at 0.
    this: bool = false,
    /// A constructor's outer instance, enum `name` and `ordinal`, and
    /// captured values; a local function's captured values.
    hidden: u16 = 0,
    contexts: u16 = 0,
    ext: bool = false,
    values: u16 = 0,
    /// A composable function's `$composer`, then its `changed` ints and
    /// the `defaults` ints of one that fills its own defaults.
    composer: bool = false,
    changed: u16 = 0,
    defaults: u16 = 0,
    reified: u16 = 0,
    /// A defaults bridge's mask words.
    masks: u16 = 0,

    pub fn hiddenStart(l: Layout) u16 {
        return @intFromBool(l.this);
    }
    pub fn contextStart(l: Layout) u16 {
        return l.hiddenStart() + l.hidden;
    }
    pub fn extIndex(l: Layout) u16 {
        return l.contextStart() + l.contexts;
    }
    pub fn valueStart(l: Layout) u16 {
        return l.extIndex() + @intFromBool(l.ext);
    }
    pub fn composerStart(l: Layout) u16 {
        return l.valueStart() + l.values;
    }
    pub fn reifiedStart(l: Layout) u16 {
        return l.composerStart() + @as(u16, if (l.composer) 1 + l.changed + l.defaults else 0);
    }
    pub fn maskStart(l: Layout) u16 {
        return l.reifiedStart() + l.reified;
    }
    pub fn len(l: Layout) u16 {
        return l.maskStart() + l.masks;
    }
};

/// The frame of function or constructor `callee`; `masks` is left 0 (a
/// defaults bridge adds `maskWords(values)`).
pub fn layoutOf(p: *const Program, callee: Sym) Layout {
    const s = p.s;
    const info = s.syms.functionInfo(callee);
    if (s.syms.kind(callee) == .constructor) {
        return .{
            .this = true,
            .hidden = ctorHidden(p, s.syms.owner(callee)),
            .contexts = @intCast(info.context_params.len),
            .values = @intCast(info.params.len),
        };
    }
    const captured = localCaptures(p, callee);
    const this = captured == null and dispatch.isMember(s, callee);
    const composer = compose.composableFunction(s, callee);
    return .{
        .this = this,
        .hidden = if (captured) |c| @intCast(c.len) else 0,
        .contexts = @intCast(info.context_params.len),
        .ext = info.receiver != .none,
        .values = @intCast(info.params.len),
        .composer = composer,
        .changed = if (composer) bridge.declChangedInts(s, callee, this) else 0,
        .defaults = if (bridge.composableDefaults(s, callee)) bridge.defaultInts(info.params.len) else 0,
        .reified = reifiedCount(s, callee),
    };
}

/// The mask words a defaults bridge over `values` parameters takes.
pub fn maskWords(values: usize) u16 {
    return @intCast((values + 31) / 32);
}

/// The values a constructor of `cls` takes after the instance: the outer
/// instance of an inner class, the `name` and `ordinal` of an enum class
/// (and of an entry's own class, which passes them on), and the captured
/// values of a local class or object expression.
fn ctorHidden(p: *const Program, cls: Sym) u16 {
    const s = p.s;
    var n: u16 = @intFromBool(isInner(s, cls));
    switch (s.syms.classInfo(cls).kind) {
        .enum_class, .enum_entry => n += 2,
        else => {},
    }
    return n + @as(u16, @intCast(classCaptures(p, cls).len));
}

/// An inner class declared in a class: it holds its outer instance.
fn isInner(s: *sema.Sema, cls: Sym) bool {
    const outer = s.syms.owner(cls);
    return s.syms.flags(cls).inner and outer != .none and s.syms.kind(outer) == .class;
}

fn classCaptures(p: *const Program, cls: Sym) []const bridge.CaptureKey {
    const c = dispatch.classIdOf(p.br, cls) orelse return &.{};
    return if (c.int() < p.br.class_captures.len) p.br.class_captures[c.int()] else &.{};
}

/// A local function's captures, which lead its parameters; null for any
/// other function.
fn localCaptures(p: *const Program, f: Sym) ?[]const bridge.CaptureKey {
    const id = dispatch.funcIdOf(p.br, f) orelse return null;
    if (!dispatch.isLocal(p.br, id)) return null;
    return if (id.int() < p.br.captures_of.len) p.br.captures_of[id.int()] else &.{};
}

fn reifiedCount(s: *sema.Sema, f: Sym) u16 {
    var n: u16 = 0;
    for (s.syms.functionInfo(f).type_params) |tp| {
        if (s.syms.flags(tp).reified) n += 1;
    }
    return n;
}

// ------------------------------------------------------ argument mapping --

/// The mask words for a call's `args`: bit `i % 32` of word `i / 32` is set
/// where value parameter `i` is omitted. `has_default` is per parameter: a
/// vararg parameter given no element is omitted when it declares a default.
/// Empty when nothing is omitted.
pub fn defaultMasks(a: Allocator, args: []const ArgSource, has_default: []const bool) Allocator.Error![]u32 {
    var any = false;
    for (args, 0..) |src, i| {
        if (omitted(src, i < has_default.len and has_default[i])) any = true;
    }
    if (!any) return &.{};
    const words = try a.alloc(u32, maskWords(args.len));
    @memset(words, 0);
    for (args, 0..) |src, i| {
        if (!omitted(src, i < has_default.len and has_default[i])) continue;
        words[i / 32] |= @as(u32, 1) << @intCast(i % 32);
    }
    return words;
}

fn omitted(src: ArgSource, has_default: bool) bool {
    return switch (src) {
        .default => true,
        .vararg => |parts| parts.len == 0 and has_default,
        .arg, .receiver => false,
    };
}

/// Per value parameter, the operand it takes (null for a default, a vararg
/// or the call's receiver), after checking that the record uses every one
/// of `n_operands` operands exactly once.
pub fn permutation(a: Allocator, args: []const ArgSource, n_operands: usize) Error![]?u16 {
    const used = try a.alloc(bool, n_operands);
    @memset(used, false);
    const out = try a.alloc(?u16, args.len);
    for (args, out) |src, *o| {
        o.* = null;
        switch (src) {
            .arg => |k| {
                try useOperand(used, k);
                o.* = k;
            },
            .vararg => |parts| for (parts) |pt| try useOperand(used, pt.arg),
            .default, .receiver => {},
        }
    }
    for (used) |u| if (!u) return error.Unsupported;
    return out;
}

fn useOperand(used: []bool, k: u16) Error!void {
    if (k >= used.len or used[k]) return error.Unsupported;
    used[k] = true;
}

/// The parameters a record's `args` map to: the callee's value parameters
/// after the leading contexts a contextual `invoke` takes from the scope.
fn valueParams(s: *sema.Sema, rec: *const CallRec) []const Sym {
    const all = s.syms.functionInfo(rec.callee).params;
    return if (all.len >= rec.args.len) all[all.len - rec.args.len ..] else all;
}

fn hasDefaults(a: Allocator, s: *sema.Sema, params: []const Sym) Allocator.Error![]bool {
    const out = try a.alloc(bool, params.len);
    for (params, out) |p, *o| o.* = s.syms.flags(p).has_default;
    return out;
}

// ----------------------------------------------------------------- calls --

/// An `Expr.Call`.
pub fn lowerCall(b: *Builder, e: *const ast.Expr) Error!Reg {
    // An operator member on integer constants (`1 shl 2`) folds as `1 + 2` does.
    if (sema.body.intConstValue(e) != null) return operator.foldedArithmetic(b, e);
    const c = &e.Call;
    const rec = b.call(c.id) catch |err| return missing(b, err, c.span, "call");
    const written: []const ast.Expr = if (c.is_infix and c.args.len != 0) c.args[1..] else c.args;
    var ops = try operandsOf(b, written);
    ops.sp = c.span;
    // The receiver is this call's alone.
    ops.from = locals.mark(b);
    var recv: ?Reg = null;
    var safe = false;
    ops.result_ty = b.exprType(c.id);
    if (c.is_infix and c.args.len != 0) {
        recv = try body.lowerExpr(b, &c.args[0]);
        ops.receiver_ty = b.exprType(c.args[0].id());
    } else switch (c.callee.*) {
        .Path => |path| {
            // `a.b.f()`: the prefix's records are the call's, one per
            // segment that yields a value.
            const segs = path.segments;
            if (segs.len > 1) recv = try name_mod.pathValue(b, c.id, segs[0 .. segs.len - 1]);
        },
        .Member => |m| {
            safe = m.safe;
            if (m.receiver.* != .Super) {
                if (isQualifier(b, m.receiver)) {
                    recv = try qualifierValue(b, c.id, m.receiver);
                } else {
                    recv = try body.lowerExpr(b, m.receiver);
                    ops.receiver_ty = b.exprType(m.receiver.id());
                }
            }
        },
        else => {},
    }
    ops.tail = !safe and tailrec.isTailCall(b, e, rec.callee);
    ops.call = e;
    const site: CallSite = .{ .e = e, .rec = &rec, .ops = ops, .safe = safe };
    if (safe) {
        const r = recv orelse return b.fail(c.span, "a safe call without a receiver", .{});
        return control.lowerSafe(b, r, site);
    }
    return site.lower(b, recv);
}

/// A call typed `Nothing` to a function that may return, its result a `T`
/// the call fixed as `Nothing`, throws `KotlinNothingValueException` when it
/// does, as kotlinc's JVM backend has it.
fn nothingValue(b: *Builder, rec: *const CallRec, ty: TypeId) Error!void {
    const s = b.p.s;
    if (ty == .none or b.terminated() or ty != s.t.nothing) return;
    if (rec.callee == .none or s.syms.kind(rec.callee) != .function) return;
    if (try sema.headers.returnType(s, rec.callee) == s.t.nothing) return;
    // A base without the class (a test's miniature one) lets the value through.
    if (s.classByFqn("kotlin.KotlinNothingValueException") == .none) return;
    const exc = try classes.newThrowable(b, "kotlin.KotlinNothingValueException", try b.nullValue());
    b.terminate(.{ .Throw = exc });
}

/// A written call once its receiver is evaluated; `lower` is what `?.`
/// runs on a receiver that is not null.
const CallSite = struct {
    e: *const ast.Expr,
    rec: *const CallRec,
    ops: Operands,
    /// `a?.f()`: the call's own type is the expression's without its `?`.
    safe: bool = false,

    pub fn lower(self: CallSite, b: *Builder, recv: ?Reg) Error!Reg {
        var ops = self.ops;
        if (self.rec.form == .value_invoke) {
            ops.receiver = try invokedValue(b, self.e, recv);
            ops.invoke_receiver = recv;
        } else {
            ops.receiver = recv;
        }
        const result = try emitCall(b, self.rec, ops);
        const own_ty = if (self.safe and ops.result_ty != .none) try b.p.s.types.makeNotNull(ops.result_ty) else ops.result_ty;
        try nothingValue(b, self.rec, own_ty);
        return result;
    }
};

/// The value a `value_invoke` invokes. A named callee (`f(x)`, `a.f(x)`,
/// `Obj.f(x)`) is read through the record the call's node holds at the
/// name; any other callee is an expression of its own.
fn invokedValue(b: *Builder, e: *const ast.Expr, recv: ?Reg) Error!Reg {
    const c = &e.Call;
    const at: u32 = switch (c.callee.*) {
        .Path => |path| path.segments[path.segments.len - 1].span.start,
        .Member => |m| m.name.span.start,
        else => return body.lowerExpr(b, c.callee),
    };
    const nr = b.nameAt(c.id, at) orelse return b.fail(c.span, "the value this call invokes has no record", .{});
    return name_mod.read(b, &nr, if (name_mod.takesExpr(&nr)) recv else null);
}

/// Whether a call's receiver is a package or classifier qualifier, which
/// sema resolved as no expression.
fn isQualifier(b: *Builder, e: *const ast.Expr) bool {
    return switch (e.*) {
        .Path, .Member => b.exprType(e.id()) == .none,
        else => false,
    };
}

/// A qualifier receiver's value: the object or companion a call through
/// `Cls.f()` reaches, which the call's node records at the qualifier's
/// last name; none for a package or a static call.
fn qualifierValue(b: *Builder, node: NodeId, q: *const ast.Expr) Error!?Reg {
    const at = switch (q.*) {
        .Path => |path| path.segments[path.segments.len - 1].span.start,
        .Member => |m| m.name.span.start,
        else => return null,
    };
    const nr = b.nameAt(node, at) orelse return null;
    return try name_mod.read(b, &nr, null);
}

/// `ops`, naming the construct being lowered when the caller gave no span.
fn withSpan(b: *Builder, ops: Operands) Operands {
    var out = ops;
    if (out.sp.start == 0 and out.sp.end == 0) out.sp = b.cur_span;
    return out;
}

fn operandsOf(b: *Builder, written: []const ast.Expr) Error!Operands {
    const a = b.p.a;
    const exprs = try a.alloc(?*const ast.Expr, written.len);
    for (written, exprs) |*x, *o| o.* = x;
    const regs = try a.alloc(?Reg, written.len);
    @memset(regs, null);
    return .{ .exprs = exprs, .regs = regs, .receiver = null };
}

/// Every call, the desugared ones included.
pub fn emitCall(b: *Builder, rec: *const CallRec, ops_in: Operands) Error!Reg {
    const ops = withSpan(b, ops_in);
    switch (rec.form) {
        .this_delegation, .super_delegation => {
            _ = try lowerDelegation(b, rec, ops);
            return b.emitConst(.Unit);
        },
        .plain, .super_, .value_invoke, .ctor, .sam_ctor => {},
    }
    const s = b.p.s;
    const a = b.p.a;
    // `remember` is lowered as the Compose compiler has it.
    if (b.env.composer != null and compose.isRemember(s, rec.callee)) {
        if (try compose.lowerRemember(b, rec, ops)) |r| return r;
    }
    // `Iface { ... }` in a scope that remembers is remembered whole.
    if (rec.form == .sam_ctor and ops.exprs.len == 1) if (ops.exprs[0]) |arg| if (literal(arg)) |lit| {
        if (try compose.memoizes(b, lit, (try b.lambda(lit.id())).func)) return compose.memoizedSamCtor(b, rec, ops, lit);
    };
    var how = dispatch.choose(b.p, rec) catch |err| return noHow(b, rec, ops.sp, err);
    const params = valueParams(s, rec);
    _ = permutation(a, rec.args, ops.count()) catch
        return b.fail(ops.sp, "the call record of `{s}` does not use each argument once", .{calleeName(s, rec.callee)});
    const has_default = try hasDefaults(a, s, params);
    // A composable filling its own defaults takes the omitted arguments'
    // bits after its change bits, 31 to an int.
    const own_defaults = how != .value and how != .ctor and bridge.composableDefaults(s, rec.callee);
    const masks: []const u32 = if (own_defaults) &.{} else try defaultMasks(a, rec.args, has_default);
    // A `tailrec` self-call leaving arguments out evaluates their defaults
    // itself, as the defaults bridge would, and jumps. A default an
    // override inherits is its supertype's to evaluate: that call is no
    // tail call, as kotlinc has it.
    const tail_defaults = ops.tail and masks.len != 0 and (how == .static or how == .virtual) and ownDefaults(s, rec.args, params, has_default);
    // The function whose receiver the call passes: the callee's, or through
    // a defaults bridge an override inherits, the declaration the bridge
    // belongs to (a value class's override of `I.f` passes `I.f$default`
    // the instance).
    var receiver_of = rec.callee;
    if (masks.len != 0 and !tail_defaults) {
        if (rec.form == .super_) {
            return b.fail(ops.sp, "super calls with default arguments are prohibited; pass every argument of `{s}`", .{calleeName(s, rec.callee)});
        }
        how = try throughDefaults(b, rec, how, ops.sp);
        receiver_of = defaultsTarget(b, rec.callee);
    }
    const in_place = if (how == .inline_) try inPlaceLambdas(b, rec, ops, params) else &.{};
    const groups = if (how == .inline_) try inlineGroups(b, rec, ops, in_place, params) else compose.InlineGroups{};
    // The values lowered from here on are the run's own.
    const from = ops.from orelse locals.mark(b);
    const vals = try evalOperands(b, ops, in_place, try unmemoizedOperands(b, rec, ops, params));

    var run: Run = .{};
    switch (how) {
        // A SAM class takes the function value alone.
        .ctor => if (rec.form != .sam_ctor) try pushCtorHidden(b, &run, rec, ops, .new),
        // The function value is `invoke`'s dispatch receiver.
        .value => try run.push(a, try receiverFor(b, rec.dispatch, ops.receiver, ops.sp)),
        // A constructor an instruction stands for (an unsigned type's) takes
        // its value alone.
        else => if (rec.form != .ctor) {
            const lay = layoutOf(b.p, rec.callee);
            if (lay.this) {
                const r = try receiverFor(b, rec.dispatch, ops.receiver, ops.sp);
                try run.push(a, try coerce.convert(b, r, try receiverScalar(b, rec.dispatch, ops), try coerce.dispatchHeld(b, receiver_of)));
            }
            if (localCaptures(b.p, rec.callee)) |keys| {
                for (try env.materializeCaptures(b, keys)) |r| try run.push(a, r);
            }
        },
    }
    for (rec.contexts) |cx| try run.push(a, try receiverFor(b, cx, null, ops.sp));
    const lay_ext = how != .ctor and how != .value and layoutOf(b.p, rec.callee).ext;
    if (lay_ext) {
        const r = try receiverFor(b, rec.extension, ops.receiver, ops.sp);
        try run.push(a, try coerce.convert(b, r, try receiverScalar(b, rec.extension, ops), try coerce.receiverHeld(b, rec.callee)));
    }
    const value_start = run.regs.items.len;
    try pushValues(b, &run, rec, ops, vals, params);
    if (composableCall(b.p.s, rec, how)) {
        try run.push(a, try compose.composer(b));
        for (try compose.callChanged(b, rec, how == .value, ops)) |r| try run.push(a, r);
        if (own_defaults) {
            const words = try a.alloc(i32, bridge.defaultInts(rec.args.len));
            @memset(words, 0);
            for (rec.args, 0..) |src, i| {
                if (omitted(src, i < has_default.len and has_default[i])) words[i / 31] |= @as(i32, 1) << @intCast(i % 31);
            }
            for (words) |w| try run.push(a, try b.emitConst(.{ .Int = w }));
        }
    }
    if (how != .value and how != .ctor) try pushReified(b, &run, rec, ops.sp);
    if (tail_defaults) {
        try tailDefaults(b, rec, params, run.regs.items[value_start..][0..params.len], has_default, ops.sp);
        return tailrec.jump(b, run.regs.items);
    }
    for (masks) |w| try run.push(a, try b.emitConst(.{ .Int = @bitCast(w) }));
    // A `tailrec` function's self-call in tail position jumps back to the
    // top of its body.
    if (ops.tail and masks.len == 0) switch (how) {
        .static, .virtual => return tailrec.jump(b, run.regs.items),
        else => {},
    };
    // `key(k...) { ... }` composes its block in a movable group keyed by
    // its keys, so the block's state follows them.
    if (compose.isKeyCall(s, rec.callee)) {
        try compose.startMovableGroup(b, ops.sp, try keyValues(b, rec, vals));
        const result = try finish(b, rec, how, &run, from);
        try compose.endMovableGroup(b);
        return result;
    }
    const result = try finish(b, rec, how, &run, from);
    try groups.end(b);
    return resultAs(b, rec, how, result, ops.result_ty);
}

/// A call's result as a value of the call's own type: the callee's result
/// is held boxed where the callee is dispatched or the type is generic.
fn resultAs(b: *Builder, rec: *const CallRec, how: How, result: Reg, ty: TypeId) Error!Reg {
    if (ty == .none) return result;
    const held: ?coerce.Scalar = switch (how) {
        .prim, .array_get, .array_set, .value => null,
        else => try coerce.returnHeld(b, rec.callee),
    };
    return coerce.convert(b, result, held, try coerce.scalarOf(b, ty));
}

/// The scalar class a call's receiver is a value of: the receiver
/// expression's type, or the implicit receiver's.
fn receiverScalar(b: *Builder, r: sema.records.Receiver, ops: Operands) Error!?coerce.Scalar {
    return switch (r) {
        .expr => coerce.scalarOf(b, ops.receiver_ty),
        else => coerce.implicitScalar(b, r),
    };
}

/// The static type of operand `k`: its expression's, or the one the caller
/// gave for a register; `.none` when neither is known.
fn operandType(b: *Builder, ops: Operands, k: usize) TypeId {
    if (k < ops.exprs.len) if (ops.exprs[k]) |e| return b.exprType(e.id());
    if (k < ops.types.len) return ops.types[k];
    return .none;
}

/// The groups of an inline call whose literals compose.
fn inlineGroups(b: *Builder, rec: *const CallRec, ops: Operands, in_place: []const bool, params: []const Sym) Error!compose.InlineGroups {
    if (b.env.composer == null) return .{};
    const s = b.p.s;
    const literals = try b.p.a.alloc(?*const ast.Expr, in_place.len);
    for (literals, in_place, 0..) |*l, ip, k| l.* = if (ip and k < ops.exprs.len) (if (ops.exprs[k]) |e| literal(e) else null) else null;
    var inline_params: usize = 0;
    for (params) |p| {
        if (inlinable(s, p)) inline_params += 1;
    }
    return compose.InlineGroups.begin(b, rec, ops.call, literals, inline_params);
}

/// The values a `key` call's vararg keys evaluated to, in order.
fn keyValues(b: *Builder, rec: *const CallRec, vals: []const ?Reg) Error![]const Reg {
    var out: std.ArrayList(Reg) = .empty;
    for (rec.args) |src| switch (src) {
        .vararg => |parts| for (parts) |part| {
            if (part.arg < vals.len) if (vals[part.arg]) |r| try out.append(b.p.a, r);
        },
        else => {},
    };
    return out.items;
}

/// Whether a call passes the composer pair: it calls a `@Composable`
/// function, or invokes a value of a `@Composable` function type.
fn composableCall(s: *sema.Sema, rec: *const CallRec, how: How) bool {
    return switch (how) {
        .ctor => false,
        .value => rec.composable,
        else => compose.composableFunction(s, rec.callee) or rec.composable,
    };
}

/// The argument run as it is built, with the lambda literal an inline
/// callee takes in place at each position (null elsewhere).
const Run = struct {
    regs: std.ArrayList(Reg) = .empty,
    lambdas: std.ArrayList(?*const ast.Expr) = .empty,

    fn push(self: *Run, a: Allocator, r: Reg) Allocator.Error!void {
        try self.regs.append(a, r);
        try self.lambdas.append(a, null);
    }
};

fn finish(b: *Builder, rec: *const CallRec, how: How, run: *const Run, from: locals.Mark) Error!Reg {
    switch (how) {
        .inline_ => |f| {
            if (try enumIntrinsic(b, rec, f, run)) |r| return r;
            if (isTypeOf(b.p.s, rec.callee) and rec.type_args.len == 1) return types_mod.typeValue(b, rec.type_args[0]);
            return inline_mod.instantiate(b, rec, f, run.regs.items, run.lambdas.items);
        },
        // A function with an empty body does nothing once its receiver and
        // arguments are evaluated (a platform's no-op actual).
        .static => |f| if (b.p.br.funcOfOpt(rec.callee) == f and emptyBody(b.p.s, rec.callee)) return b.unit(),
        // A scalar class's constructor answers its number over a `this` it
        // does not read: nothing is allocated.
        .ctor => |c| if (try coerce.scalarClass(b, b.p.s.syms.owner(rec.callee)) != null) {
            // One that only answers its value is the value, once the
            // companion its construction initializes is.
            if (run.regs.items.len == 1) if (try trivialCtor(b, c.ctor)) |t| {
                if (t.companion) |comp| try b.emit(.{ .LoadObject = .{ .dst = b.newReg(), .class = comp } });
                return run.regs.items[0];
            };
            const regs = try b.p.a.alloc(Reg, run.regs.items.len + 1);
            regs[0] = try b.unit();
            @memcpy(regs[1..], run.regs.items);
            const first = try locals.runFrom(b, from, regs);
            const dst = b.newReg();
            try b.emit(.{ .CallStatic = .{ .dst = dst, .func = c.ctor, .args = first, .n_args = @intCast(regs.len) } });
            return dst;
        },
        else => {},
    }
    const first = try locals.runFrom(b, from, run.regs.items);
    const dst = b.newReg();
    try dispatch.emitHow(b, how, dst, first, @intCast(run.regs.items.len));
    return dst;
}

/// A scalar class constructor that only answers its one value, after
/// initializing the companion `companion` when there is one.
const Trivial = struct { companion: ?ir.ClassId = null };

/// Whether scalar class constructor `f` only answers its one value: a single
/// block returning what it loads as its parameter after `this`, which runs
/// no init block, and at most initializes a companion.
fn trivialCtor(b: *Builder, f: FuncId) Error!?Trivial {
    const p = b.p;
    if (f.int() >= p.m.funcs.items.len) return null;
    if (!p.isLowered(f)) {
        try body.lowerBody(p, f);
        if (!p.isLowered(f)) return null;
    }
    const func = &p.m.funcs.items[f.int()];
    _ = p.m.ensureFuncBody(func);
    if (func.blocks.len != 1 or func.entry.int() != 0) return null;
    const blk = &func.blocks[0];
    const ret = switch (blk.terminator) {
        .Return => |r| r orelse return null,
        else => return null,
    };
    var value: ?ir.Reg = null;
    var out: Trivial = .{};
    for (blk.insts) |inst| switch (inst) {
        .Trace => {},
        .LoadParam => |lp| if (lp.idx == 1) {
            value = lp.dst;
        },
        .LoadObject => |lo| {
            if (out.companion != null or lo.dst == ret) return null;
            out.companion = lo.class;
        },
        else => return null,
    };
    if (value == null or value.? != ret) return null;
    return out;
}

/// Whether `f` is a written function of the base (the standard library, a
/// pack: a platform's no-op actual) whose body is an empty block: not
/// inline, suspending, tail-recursive, external or composable (a composable
/// one still opens its groups). A program's own functions keep their calls,
/// which klio's tools name them by (fault injection, frame watches).
fn emptyBody(s: *sema.Sema, f: Sym) bool {
    if (s.syms.kind(f) != .function) return false;
    const file = s.syms.get(f).file;
    if (file >= s.files.items.len or s.files.items[file].origin == .program) return false;
    if (s.syms.get(f).decl != .function) return false;
    const fl = s.syms.flags(f);
    if (fl.inline_ or fl.suspend_ or fl.tailrec or fl.external or fl.expect) return false;
    return s.syms.functionInfo(f).empty_body and !compose.composableFunction(s, f);
}

/// `kotlin.reflect.typeOf<T>()`: the run-time type of its type argument,
/// which the compiler makes.
pub fn isTypeOf(s: *sema.Sema, f: Sym) bool {
    if (s.syms.kind(f) != .function) return false;
    const owner = s.syms.owner(f);
    if (owner == .none or s.syms.kind(owner) != .package) return false;
    return std.mem.eql(u8, s.str(s.syms.packageInfo(owner).fqn), "kotlin.reflect") and
        std.mem.eql(u8, s.str(s.syms.name(f)), "typeOf");
}

pub const EnumIntrinsic = enum { value_of, values, entries, entries_intrinsic };

/// Which of the enum intrinsics `f` is: `kotlin.enumValueOf`,
/// `kotlin.enumValues`, `kotlin.enums.enumEntries<E>()`, or the
/// `enumEntriesIntrinsic` the last one's body calls.
pub fn enumIntrinsicOf(s: *sema.Sema, f: Sym) ?EnumIntrinsic {
    if (s.syms.kind(f) != .function) return null;
    const owner = s.syms.owner(f);
    if (owner == .none or s.syms.kind(owner) != .package) return null;
    const pkg = s.str(s.syms.packageInfo(owner).fqn);
    const name = s.str(s.syms.name(f));
    const eql = std.mem.eql;
    if (eql(u8, pkg, "kotlin")) {
        if (eql(u8, name, "enumValueOf")) return .value_of;
        if (eql(u8, name, "enumValues")) return .values;
    } else if (eql(u8, pkg, "kotlin.enums")) {
        if (eql(u8, name, "enumEntries") and s.syms.functionInfo(f).params.len == 0) return .entries;
        if (eql(u8, name, "enumEntriesIntrinsic")) return .entries_intrinsic;
    }
    return null;
}

/// `enumValueOf<E>(name)`, `enumValues<E>()` and `enumEntries<E>()` for an
/// enum class `E` are the compiler's: they call `E`'s own `valueOf`,
/// `values` and `entries`. Of a reified type parameter, a call of `f` over
/// the run, which the inline copy that knows `E` replaces
/// (`inline.enumIntrinsic`). Null for any other call.
fn enumIntrinsic(b: *Builder, rec: *const CallRec, f: FuncId, run: *const Run) Error!?Reg {
    const s = b.p.s;
    const which = enumIntrinsicOf(s, rec.callee) orelse return null;
    if (which == .entries_intrinsic or rec.type_args.len != 1) return null;
    const cls = s.types.classSym(rec.type_args[0]);
    if (cls != .none) return try enumIntrinsicCall(b, which, cls, run.regs.items);
    if (!types_mod.isReified(s, rec.type_args[0]))
        return b.fail(b.cur_span, "`{s}` of a type that is not an enum class", .{calleeName(s, rec.callee)});
    const dst = b.newReg();
    try b.emit(.{ .CallStatic = .{ .dst = dst, .func = f, .args = try b.run(run.regs.items), .n_args = @intCast(run.regs.items.len) } });
    return dst;
}

/// Enum class `cls`'s own `valueOf(args[0])`, `values()` or `entries`, for
/// `enumValueOf`, `enumValues` or `enumEntries` of it.
pub fn enumIntrinsicCall(b: *Builder, which: EnumIntrinsic, cls: Sym, args_in: []const Reg) Error!Reg {
    const s = b.p.s;
    const members = &s.syms.classInfo(cls).members;
    const member_name = switch (which) {
        .value_of => sema.wk.valueOf,
        .values => sema.wk.values,
        .entries, .entries_intrinsic => sema.wk.entries,
    };
    for (sema.symbols.Symbols.members(members, member_name)) |m| {
        if (!s.syms.flags(m).static) continue;
        const target: FuncId = switch (which) {
            .entries, .entries_intrinsic => if (s.syms.kind(m) == .property) b.p.br.getterOf(m) else continue,
            else => dispatch.funcIdOf(b.p.br, m) orelse continue,
        };
        const args = if (which == .value_of) args_in[0..1] else args_in[0..0];
        const dst = b.newReg();
        try b.emit(.{ .CallStatic = .{ .dst = dst, .func = target, .args = try b.run(args), .n_args = @intCast(args.len) } });
        return dst;
    }
    return b.fail(b.cur_span, "`{s}` has no `{s}`", .{ s.str(s.syms.classInfo(cls).fqn), s.str(member_name) });
}

/// The call through the callee's defaults bridge, which calls the callee
/// with `how` once the defaults are in.
/// Whether every argument `args` leaves out has a default written on its
/// own parameter.
fn ownDefaults(s: *sema.Sema, args: []const ArgSource, params: []const Sym, has_default: []const bool) bool {
    for (args, 0..) |src, i| {
        if (i >= params.len) break;
        if (omitted(src, i < has_default.len and has_default[i]) and paramDefault(s, params[i]) == null) return false;
    }
    return true;
}

/// A `tailrec` self-call's omitted arguments in `values`: each default in
/// parameter order, after every written argument, seeing the new values of
/// the parameters before it, as the defaults bridge evaluates them.
fn tailDefaults(b: *Builder, rec: *const CallRec, params: []const Sym, values: []Reg, has_default: []const bool, sp: span.Span) Error!void {
    const a = b.p.a;
    const saved = try a.alloc(?builder.Home, params.len);
    for (params, saved) |p, *h| h.* = b.locals.get(p);
    for (rec.args, 0..) |src, i| {
        if (i >= params.len) break;
        if (omitted(src, i < has_default.len and has_default[i])) values[i] = try defaultValue(b, rec.callee, params[i], null, sp);
        try b.locals.put(a, params[i], .{ .reg = values[i] });
    }
    for (params, saved) |p, h| {
        if (h) |home| try b.locals.put(a, p, home) else _ = b.locals.remove(p);
    }
}

/// The declaration whose defaults `callee`'s defaults bridge evaluates: the
/// callee's own, or the one it inherits them from.
fn defaultsTarget(b: *Builder, callee: Sym) Sym {
    const br = b.p.br;
    const d = br.defaultsOf(callee) orelse return callee;
    if (d.int() >= br.origin.len) return callee;
    return switch (br.origin[d.int()]) {
        .defaults => |t| t,
        else => callee,
    };
}

fn throughDefaults(b: *Builder, rec: *const CallRec, how: How, sp: span.Span) Error!How {
    const d = b.p.br.defaultsOf(rec.callee) orelse
        return b.fail(sp, "`{s}` has no defaults bridge", .{calleeName(b.p.s, rec.callee)});
    return switch (how) {
        .ctor => |c| .{ .ctor = .{ .class = c.class, .ctor = d } },
        .inline_ => .{ .inline_ = d },
        .static, .virtual, .interface, .native, .super_native => .{ .static = d },
        .prim, .array_get, .array_set, .value => b.fail(sp, "an omitted argument of an operation", .{}),
    };
}

fn noHow(b: *Builder, rec: *const CallRec, sp: span.Span, err: Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => b.fail(sp, "`{s}` has no identity to call", .{calleeName(b.p.s, rec.callee)}),
    };
}

fn missing(b: *Builder, err: Error, sp: span.Span, what: []const u8) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Unrecorded => b.fail(sp, "no {s} record", .{what}),
        error.Unsupported => error.Unsupported,
    };
}

fn calleeName(s: *sema.Sema, f: Sym) []const u8 {
    if (f == .none) return "?";
    return s.str(s.syms.name(f));
}

/// `receiver`'s register: `expr` for `.expr`, else the implicit receiver.
fn receiverFor(b: *Builder, r: sema.records.Receiver, expr: ?Reg, sp: span.Span) Error!Reg {
    return (try env.receiverOf(b, r, expr)) orelse b.fail(sp, "a call without the receiver its callee takes", .{});
}

/// Each operand's register, in source order; null for a lambda literal an
/// inline callee lowers in place.
/// Per operand, a literal a scope that remembers does not remember on its
/// own: one an inline callee takes inline, and one a fun interface wraps,
/// whose wrapper is remembered instead.
fn unmemoizedOperands(b: *Builder, rec: *const CallRec, ops: Operands, params: []const Sym) Error![]const bool {
    if (!b.compose_remember) return &.{};
    const s = b.p.s;
    const out = try b.p.a.alloc(bool, ops.count());
    @memset(out, false);
    const inline_callee = rec.callee != .none and s.syms.kind(rec.callee) == .function and s.syms.flags(rec.callee).inline_;
    for (rec.args, 0..) |src, i| {
        const k = switch (src) {
            .arg => |k| k,
            else => continue,
        };
        if (k >= out.len or k >= ops.exprs.len) continue;
        const ex = ops.exprs[k] orelse continue;
        if (literal(ex) == null) continue;
        const conv: Conv = if (i < rec.conv.len) rec.conv[i] else .none;
        if (conv == .sam or (inline_callee and i < params.len and inlinable(s, params[i]))) out[k] = true;
    }
    return out;
}

fn evalOperands(b: *Builder, ops: Operands, in_place: []const bool, unmemoized: []const bool) Error![]?Reg {
    const out = try b.p.a.alloc(?Reg, ops.count());
    for (out, 0..) |*o, k| {
        if (k < ops.regs.len) {
            if (ops.regs[k]) |r| {
                o.* = r;
                continue;
            }
        }
        if (k < in_place.len and in_place[k]) {
            o.* = null;
            continue;
        }
        const ex = (if (k < ops.exprs.len) ops.exprs[k] else null) orelse
            return b.fail(ops.sp, "operand {d} is neither lowered nor written", .{k});
        const saved = b.unmemoized;
        defer b.unmemoized = saved;
        if (k < unmemoized.len and unmemoized[k]) b.unmemoized = literal(ex);
        o.* = try body.lowerExpr(b, ex);
    }
    return out;
}

/// Per operand, whether it is a lambda literal an inline callee lowers in
/// place: bound to a functional parameter that is not `noinline`, not
/// nullable and not converted.
fn inPlaceLambdas(b: *Builder, rec: *const CallRec, ops: Operands, params: []const Sym) Error![]bool {
    const s = b.p.s;
    const out = try b.p.a.alloc(bool, ops.count());
    @memset(out, false);
    for (rec.args, 0..) |src, i| {
        const k = switch (src) {
            .arg => |k| k,
            else => continue,
        };
        if (k >= ops.exprs.len) continue;
        if (k < ops.regs.len and ops.regs[k] != null) continue;
        const ex = ops.exprs[k] orelse continue;
        if (literal(ex) == null) continue;
        if (i >= params.len or !inlinable(s, params[i])) continue;
        if (i < rec.conv.len and rec.conv[i] != .none) continue;
        out[k] = true;
    }
    return out;
}

/// A lambda or anonymous function literal, through its label.
fn literal(e: *const ast.Expr) ?*const ast.Expr {
    var x = e;
    while (x.* == .Labeled) x = x.Labeled.expr;
    return switch (x.*) {
        .Lambda, .AnonFun => x,
        else => null,
    };
}

/// A parameter an inline function's instantiation takes a literal for.
fn inlinable(s: *sema.Sema, p: Sym) bool {
    if (s.syms.flags(p).no_inline) return false;
    const t = s.syms.paramInfo(p).ty;
    if (t == .none or s.types.isErr(t) or s.types.isNullable(t)) return false;
    const args = s.types.argsOf(t);
    if (args.len == 0) return false;
    return dispatch.isFunctionClass(s, s.types.classSym(t), @intCast(args.len - 1));
}

fn pushValues(b: *Builder, run: *Run, rec: *const CallRec, ops: Operands, vals: []const ?Reg, params: []const Sym) Error!void {
    const s = b.p.s;
    const a = b.p.a;
    for (rec.args, 0..) |src, i| {
        const conv: Conv = if (i < rec.conv.len) rec.conv[i] else .none;
        switch (src) {
            .arg => |k| {
                if (vals[k]) |r| {
                    const held: ?coerce.Scalar = if (i < params.len) try coerce.paramHeld(b, rec.callee, params[i]) else null;
                    const v = try coerce.convert(b, r, try coerce.scalarOf(b, operandType(b, ops, k)), held);
                    try run.push(a, try convertArg(b, v, conv, if (k < ops.exprs.len) ops.exprs[k] else null));
                } else {
                    // The literal is lowered where the instantiation calls it.
                    const lit = literal(ops.exprs[k].?);
                    try run.regs.append(a, try b.emitConst(.Unit));
                    try run.lambdas.append(a, lit);
                    if (i < params.len and try compose.disallowsComposableCalls(s, params[i])) {
                        if (lit) |l| try b.compose_disallowed.put(a, l, {});
                    }
                }
            },
            .default => try run.push(a, try b.emitConst(.Unit)),
            .vararg => |parts| {
                if (i >= params.len) return b.fail(ops.sp, "a vararg argument past the parameters", .{});
                if (parts.len == 0 and s.syms.flags(params[i]).has_default) {
                    try run.push(a, try b.emitConst(.Unit));
                } else {
                    try run.push(a, try packVararg(b, params[i], parts, vals, ops, ops.sp));
                }
            },
            // A function value's parameters are generic: a scalar class's
            // value goes in boxed.
            .receiver => {
                const r = try receiverFor(b, rec.extension, ops.invoke_receiver, ops.sp);
                try run.push(a, try coerce.convert(b, r, try receiverScalar(b, rec.extension, ops), null));
            },
        }
    }
}

/// An argument converted for its parameter; a literal a fun interface
/// wraps is remembered wrapped in a scope that remembers.
fn convertArg(b: *Builder, r: Reg, conv: Conv, ex: ?*const ast.Expr) Error!Reg {
    if (conv == .sam) if (ex) |e| if (literal(e)) |lit| {
        const f = (try b.lambda(lit.id())).func;
        const saved = b.unmemoized;
        b.unmemoized = null;
        defer b.unmemoized = saved;
        if (try compose.memoizes(b, lit, f)) return compose.memoizedSam(b, r, conv.sam, f);
    };
    return convert(b, r, conv);
}

fn convert(b: *Builder, r: Reg, conv: Conv) Error!Reg {
    return switch (conv) {
        .none => r,
        .sam => |iface| lambda_mod.samWrap(b, r, iface),
        // A suspend function value is called like any other: the VM
        // suspends by snapshotting frames, not through a continuation.
        .suspend_ => r,
    };
}

/// The array a vararg parameter receives: its elements in source order, a
/// spread's copied, so the callee never shares the caller's array.
fn packVararg(b: *Builder, param: Sym, parts: []const VarargPart, vals: []const ?Reg, ops: Operands, sp: span.Span) Error!Reg {
    const s = b.p.s;
    const a = b.p.a;
    // An array holds a scalar class's values boxed.
    const boxed = try a.alloc(Reg, parts.len);
    for (parts, boxed) |pt, *r| r.* = if (pt.spread) vals[pt.arg].? else try coerce.convert(b, vals[pt.arg].?, try coerce.scalarOf(b, operandType(b, ops, pt.arg)), null);
    const arr_t = try s.varargArrayType(s.syms.paramInfo(param).ty);
    const cls = dispatch.classIdOf(b.p.br, s.types.classSym(arr_t)) orelse
        return b.fail(sp, "the array a vararg parameter takes has no class", .{});
    var spreads = false;
    for (parts) |pt| spreads = spreads or pt.spread;
    var elems: std.ArrayList(Reg) = .empty;
    if (!spreads) {
        for (parts, boxed) |pt, r| try elems.append(a, try convert(b, r, pt.conv));
        return newArray(b, cls, elems.items);
    }
    // Runs of single elements become arrays of their own; the helper joins
    // them and the spread arrays into a new one.
    var segs: std.ArrayList(Reg) = .empty;
    for (parts, boxed) |pt, r| {
        if (!pt.spread) {
            try elems.append(a, try convert(b, r, pt.conv));
            continue;
        }
        if (elems.items.len != 0) {
            try segs.append(a, try newArray(b, cls, elems.items));
            elems.clearRetainingCapacity();
        }
        try segs.append(a, r);
    }
    if (elems.items.len != 0) try segs.append(a, try newArray(b, cls, elems.items));
    const any_array = dispatch.classIdOf(b.p.br, s.builtins.array) orelse
        return b.fail(sp, "the base declares no `kotlin.Array`", .{});
    const joined = try newArray(b, any_array, segs.items);
    const concat = try spreadHelper(b, sp);
    const dst = b.newReg();
    try b.emit(.{ .CallStatic = .{ .dst = dst, .func = concat, .args = try b.run(&.{joined}), .n_args = 1 } });
    return dst;
}

fn newArray(b: *Builder, cls: ClassId, elems: []const Reg) Error!Reg {
    const first = try b.run(elems);
    const dst = b.newReg();
    try b.emit(.{ .NewArray = .{ .dst = dst, .class = cls, .args = first, .n_args = @intCast(elems.len) } });
    return dst;
}

/// The base's array join, `kotlin.__klio_arrayConcat(parts: Array<out Any>)`:
/// a new array of the parts' kind holding every part's elements in order.
pub const spread_helper = "__klio_arrayConcat";

fn spreadHelper(b: *Builder, sp: span.Span) Error!FuncId {
    const s = b.p.s;
    const fail_msg = "the base declares no `kotlin." ++ spread_helper ++ "` to spread an array into a vararg";
    const pkg_name = s.names.lookup("kotlin") orelse return b.fail(sp, fail_msg, .{});
    const pkg = s.syms.package_by_fqn.get(pkg_name) orelse return b.fail(sp, fail_msg, .{});
    const n = s.names.lookup(spread_helper) orelse return b.fail(sp, fail_msg, .{});
    for (sema.scope.membersOf(s, pkg, n)) |m| {
        if (s.syms.kind(m) != .function) continue;
        if (dispatch.funcIdOf(b.p.br, m)) |f| return f;
    }
    return b.fail(sp, fail_msg, .{});
}

/// A reified type parameter's run-time type value, per the callee's
/// reified type parameters in order.
fn pushReified(b: *Builder, run: *Run, rec: *const CallRec, sp: span.Span) Error!void {
    const s = b.p.s;
    if (s.syms.kind(rec.callee) != .function) return;
    for (s.syms.functionInfo(rec.callee).type_params, 0..) |tp, i| {
        if (!s.syms.flags(tp).reified) continue;
        if (i >= rec.type_args.len or s.types.isErr(rec.type_args[i])) {
            return b.fail(sp, "reified `{s}` of `{s}` has no type argument", .{ s.str(s.syms.name(tp)), calleeName(s, rec.callee) });
        }
        try run.push(b.p.a, try types_mod.typeValue(b, rec.type_args[i]));
    }
}

// ---------------------------------------------------------- constructors --

const CtorMode = enum { new, this_delegation, super_delegation };

/// A constructor's hidden values after the instance. A new instance takes
/// its outer instance from the call's dispatch receiver and its captures
/// from this body; `this(...)` passes on this constructor's own; `super(...)`
/// takes the superclass's outer instance, passes on an enum entry's `name`
/// and `ordinal`, and captures what a local superclass captures.
fn pushCtorHidden(b: *Builder, run: *Run, rec: *const CallRec, ops: Operands, mode: CtorMode) Error!void {
    const s = b.p.s;
    const a = b.p.a;
    const cls = s.syms.owner(rec.callee);
    if (mode == .this_delegation) {
        var i: u16 = 0;
        while (i < ctorHidden(b.p, cls)) : (i += 1) try run.push(a, try loadParam(b, 1 + i));
        return;
    }
    if (isInner(s, cls)) try run.push(a, try receiverFor(b, rec.dispatch, ops.receiver, ops.sp));
    switch (s.syms.classInfo(cls).kind) {
        .enum_class, .enum_entry => {
            if (mode == .new) return b.fail(ops.sp, "an enum class is constructed only for its entries", .{});
            const cur = currentClass(b) orelse return b.fail(ops.sp, "an enum constructor delegation outside a constructor", .{});
            const at: u16 = 1 + @as(u16, @intFromBool(isInner(s, cur)));
            try run.push(a, try loadParam(b, at));
            try run.push(a, try loadParam(b, at + 1));
        },
        else => {},
    }
    const keys = classCaptures(b.p, cls);
    if (keys.len != 0) {
        for (try env.materializeCaptures(b, keys)) |r| try run.push(a, r);
    }
}

/// The class whose constructor this body is.
fn currentClass(b: *Builder) ?Sym {
    const s = b.p.s;
    if (b.owner == .none or s.syms.kind(b.owner) != .constructor) return null;
    return s.syms.owner(b.owner);
}

fn loadParam(b: *Builder, idx: u16) Error!Reg {
    const dst = b.newReg();
    try b.emit(.{ .LoadParam = .{ .dst = dst, .idx = idx } });
    return dst;
}

/// A constructor delegation or supertype initializer, on the instance being
/// built: `this` (the constructor's parameter 0), the hidden values, then the
/// arguments, called statically.
/// Answers the delegated-to constructor's result: the number, for a scalar
/// class's.
pub fn lowerDelegation(b: *Builder, rec: *const CallRec, ops_in: Operands) Error!Reg {
    const ops = withSpan(b, ops_in);
    const s = b.p.s;
    const a = b.p.a;
    const mode: CtorMode = switch (rec.form) {
        .this_delegation => .this_delegation,
        .super_delegation => .super_delegation,
        else => return b.fail(ops.sp, "a delegation record of another form", .{}),
    };
    var ctor = dispatch.funcIdOf(b.p.br, rec.callee) orelse
        return b.fail(ops.sp, "constructor `{s}` has no identity", .{calleeName(s, rec.callee)});
    const params = valueParams(s, rec);
    _ = permutation(a, rec.args, ops.count()) catch
        return b.fail(ops.sp, "the delegation record does not use each argument once", .{});
    const masks = try defaultMasks(a, rec.args, try hasDefaults(a, s, params));
    if (masks.len != 0) ctor = b.p.br.defaultsOf(rec.callee) orelse
        return b.fail(ops.sp, "constructor `{s}` has no defaults bridge", .{calleeName(s, rec.callee)});
    const vals = try evalOperands(b, ops, &.{}, &.{});
    // A superclass the host constructs makes its host value, which this
    // instance holds for the host's members to act on.
    if (mode == .super_delegation and b.p.isNative(ctor)) {
        try hostSuper(b, rec, ops, vals, params, masks, ctor);
        return b.unit();
    }
    var run: Run = .{};
    try run.push(a, try loadParam(b, 0));
    try pushCtorHidden(b, &run, rec, ops, mode);
    for (rec.contexts) |cx| try run.push(a, try receiverFor(b, cx, null, ops.sp));
    try pushValues(b, &run, rec, ops, vals, params);
    for (masks) |w| try run.push(a, try b.emitConst(.{ .Int = @bitCast(w) }));
    const first = try b.run(run.regs.items);
    const dst = b.newReg();
    try b.emit(.{ .CallStatic = .{ .dst = dst, .func = ctor, .args = first, .n_args = @intCast(run.regs.items.len) } });
    return dst;
}

fn hostSuper(b: *Builder, rec: *const CallRec, ops: Operands, vals: []const ?Reg, params: []const Sym, masks: []const u32, ctor: FuncId) Error!void {
    const s = b.p.s;
    const a = b.p.a;
    const br = b.p.br;
    const sup = br.classOfOpt(s.syms.owner(rec.callee)) orelse
        return b.fail(ops.sp, "the superclass of `{s}` has no class id", .{calleeName(s, rec.callee)});
    const own = br.classOfOpt(b.env.this_class) orelse
        return b.fail(ops.sp, "a superclass constructor call outside a class", .{});
    const r = b.p.m.resolved orelse return b.fail(ops.sp, "the module has no run-time tables", .{});
    const slot = r.classes[own.int()].host_slot;
    if (slot == bridge.NONE) return b.fail(ops.sp, "`{s}` holds no host value for its superclass", .{s.str(s.syms.name(b.env.this_class))});
    var run: Run = .{};
    for (rec.contexts) |cx| try run.push(a, try receiverFor(b, cx, null, ops.sp));
    try pushValues(b, &run, rec, ops, vals, params);
    for (masks) |w| try run.push(a, try b.emitConst(.{ .Int = @bitCast(w) }));
    const v = b.newReg();
    try b.emit(.{ .RNewInstance = .{ .dst = v, .class = sup, .ctor = ctor, .args = try b.run(run.regs.items), .n_args = @intCast(run.regs.items.len) } });
    try b.emit(.{ .SetFieldSlot = .{ .obj = try loadParam(b, 0), .slot = slot, .value = v } });
}

/// A constructor call's arguments after the instance: `head` (the hidden
/// values the caller computed, such as an enum entry's `name` and
/// `ordinal`), then contexts, values and masks. `func` is the constructor,
/// or its defaults bridge when an argument is omitted.
pub const CtorArgs = struct { func: FuncId, run: Reg, n: u32 };

pub fn ctorArgs(b: *Builder, rec: *const CallRec, ops_in: Operands, head: []const Reg) Error!CtorArgs {
    const ops = withSpan(b, ops_in);
    const s = b.p.s;
    const a = b.p.a;
    var func = dispatch.funcIdOf(b.p.br, rec.callee) orelse
        return b.fail(ops.sp, "constructor `{s}` has no identity", .{calleeName(s, rec.callee)});
    const params = valueParams(s, rec);
    _ = permutation(a, rec.args, ops.count()) catch
        return b.fail(ops.sp, "the constructor record does not use each argument once", .{});
    const masks = try defaultMasks(a, rec.args, try hasDefaults(a, s, params));
    if (masks.len != 0) func = b.p.br.defaultsOf(rec.callee) orelse
        return b.fail(ops.sp, "constructor `{s}` has no defaults bridge", .{calleeName(s, rec.callee)});
    const from = locals.mark(b);
    const vals = try evalOperands(b, ops, &.{}, &.{});
    var run: Run = .{};
    for (head) |r| try run.push(a, r);
    for (rec.contexts) |cx| try run.push(a, try receiverFor(b, cx, null, ops.sp));
    try pushValues(b, &run, rec, ops, vals, params);
    for (masks) |w| try run.push(a, try b.emitConst(.{ .Int = @bitCast(w) }));
    return .{ .func = func, .run = try locals.runFrom(b, from, run.regs.items), .n = @intCast(run.regs.items.len) };
}

// -------------------------------------------------------- defaults bridge --

/// The body of `target`'s defaults bridge. Its parameters are `target`'s
/// followed by the mask words. Each parameter whose bit is set takes its
/// default, evaluated in the declaring scope where the parameters before
/// it are visible with their final values; then `target` runs with its own
/// dispatch (virtually for an open member, on the same instance for a
/// constructor).
pub fn lowerDefaultsBridge(b: *Builder, target: Sym) Error!void {
    const s = b.p.s;
    const a = b.p.a;
    const sp = declSpan(s, target);
    // A frame of the bridge stands at the declaration, as kotlinc's
    // `$default` method's line table puts it.
    if (sp.end != 0) try b.emit(.{ .Trace = .{ .span = sp } });
    var lay = layoutOf(b.p, target);
    lay.masks = maskWords(lay.values);
    const params = s.syms.functionInfo(target).params;
    const this_reg: ?Reg = if (lay.this) try loadParam(b, 0) else null;
    // An argument the bridge fills with a static default is static to the
    // composable: the change bits it passes on mark each one, in the int
    // holding its slot (after the contexts and extension receiver).
    const static_bits: []Reg = try a.alloc(Reg, lay.changed);
    for (static_bits) |*r| {
        r.* = b.newReg();
        try b.emit(.{ .Move = .{ .dst = r.*, .src = try b.emitConst(.{ .Int = 0 }) } });
    }
    // An actual's defaults are its expect's expressions, which name the
    // expect's parameters and, in an expect class, its `this`, and an
    // extension's its receiver.
    const expect = expectOf(s, target);
    const expect_params: []const Sym = if (expect != .none) s.syms.functionInfo(expect).params else &.{};
    if (expect != .none) {
        const ecls = s.syms.owner(expect);
        if (this_reg) |t| if (s.syms.kind(ecls) == .class) try env.bindReceiver(b, env.thisKind(s, ecls), ecls, t);
        if (s.syms.functionInfo(expect).receiver != .none and s.syms.functionInfo(target).receiver != .none) {
            try env.bindReceiver(b, .extension, expect, try env.receiver(b, .extension, target));
        }
    }
    for (params, 0..) |p, i| {
        const given = try loadParam(b, lay.valueStart() + @as(u16, @intCast(i)));
        if (!s.syms.flags(p).has_default) {
            try env.bindLocal(b, p, given);
            if (i < expect_params.len) try env.bindLocal(b, expect_params[i], given);
            continue;
        }
        const home = b.newReg();
        try b.emit(.{ .Move = .{ .dst = home, .src = given } });
        const mask = try loadParam(b, lay.maskStart() + @as(u16, @intCast(i / 32)));
        const bit = try b.emitConst(.{ .Int = @bitCast(@as(u32, 1) << @intCast(i % 32)) });
        const masked = b.newReg();
        try b.emit(.{ .BinOp = .{ .dst = masked, .op = .And, .lhs = mask, .rhs = bit } });
        const zero = try b.emitConst(.{ .Int = 0 });
        const set = b.newReg();
        try b.emit(.{ .BinOp = .{ .dst = set, .op = .NotEq, .lhs = masked, .rhs = zero } });
        const dflt = try b.newBlock();
        const join = try b.newBlock();
        b.terminate(.{ .Branch = .{ .cond = set, .t = dflt, .f = join } });
        b.switchTo(dflt);
        if (lay.composer and try compose.defaultIsStatic(b, target, p)) {
            const slot = lay.contexts + @intFromBool(lay.ext) + i;
            const r = static_bits[slot / 10];
            const bits = try b.emitConst(.{ .Int = compose.slotBits(compose.static_bits, slot) });
            try b.emit(.{ .BinOp = .{ .dst = r, .op = .Or, .lhs = r, .rhs = bits } });
        }
        // A default holds its value as the parameter does.
        const v = try coerce.convert(b, try defaultValue(b, target, p, this_reg, sp), try coerce.scalarOf(b, try defaultType(b, p)), try coerce.paramHeld(b, target, p));
        if (!b.terminated()) {
            try b.emit(.{ .Move = .{ .dst = home, .src = v } });
            b.terminate(.{ .Goto = join });
        }
        b.switchTo(join);
        try env.bindLocal(b, p, home);
        if (i < expect_params.len) try env.bindLocal(b, expect_params[i], home);
    }
    const from = locals.mark(b);
    var run: Run = .{};
    var i: u16 = 0;
    while (i < lay.valueStart()) : (i += 1) {
        try run.push(a, if (i == 0 and this_reg != null) this_reg.? else try loadParam(b, i));
    }
    for (params) |p| try run.push(a, try env.readLocal(b, p));
    if (lay.composer) {
        try run.push(a, try loadParam(b, lay.composerStart()));
        for (static_bits, 0..) |bits, k| {
            const given = try loadParam(b, lay.composerStart() + 1 + @as(u16, @intCast(k)));
            const changed = b.newReg();
            try b.emit(.{ .BinOp = .{ .dst = changed, .op = .Or, .lhs = given, .rhs = bits } });
            try run.push(a, changed);
        }
    }
    i = 0;
    while (i < lay.reified) : (i += 1) try run.push(a, try loadParam(b, lay.reifiedStart() + i));
    const rec: CallRec = .{ .callee = target, .form = .plain };
    const how: How = if (s.syms.kind(target) == .constructor)
        .{ .static = dispatch.funcIdOf(b.p.br, target) orelse return b.fail(sp, "constructor `{s}` has no identity", .{calleeName(s, target)}) }
    else
        dispatch.choose(b.p, &rec) catch |err| return noHow(b, &rec, sp, err);
    const result = try finish(b, &rec, how, &run, from);
    if (!b.terminated()) b.terminate(.{ .Return = result });
}

/// The static type of parameter `p`'s default: its expression's, or for a
/// data class's `copy`, the property's.
fn defaultType(b: *Builder, p: Sym) Error!TypeId {
    const s = b.p.s;
    if (paramDefault(s, p)) |ex| return b.exprType(ex.id());
    const prop = s.syms.paramInfo(p).default_prop;
    if (prop != .none) return sema.headers.propertyType(s, prop);
    return sema.headers.paramType(s, p);
}

/// The value parameter `p` (the `i`th of `target`) takes when omitted: its
/// default expression, or for a data class's `copy` the receiver's
/// property of the same position.
pub fn defaultValue(b: *Builder, target: Sym, p: Sym, this_reg: ?Reg, sp: span.Span) Error!Reg {
    const s = b.p.s;
    if (paramDefault(s, p)) |ex| return body.lowerExpr(b, ex);
    // An actual parameter takes its expect's default, whose records are
    // in the expect's file.
    const from = s.syms.paramInfo(p).default_from;
    if (from != .none) {
        if (paramDefault(s, from)) |ex| {
            const file = b.file;
            b.setFile(s.syms.get(from).file);
            const v = try body.lowerExpr(b, ex);
            b.setFile(file);
            return v;
        }
    }
    // A data class `copy` parameter defaults to its property's value.
    const prop = s.syms.paramInfo(p).default_prop;
    if (prop != .none) {
        const nr: NameRec = .{ .kind = .property, .target = prop, .dispatch = .expr };
        return name_mod.read(b, &nr, this_reg);
    }
    return b.fail(sp, "the default of parameter `{s}` of `{s}` has no expression", .{ s.str(s.syms.name(p)), calleeName(s, target) });
}

/// The expect function or constructor whose defaults actual `f` takes, or
/// `.none`.
pub fn expectOf(s: *sema.Sema, f: Sym) Sym {
    for (s.syms.functionInfo(f).params) |p| {
        const from = s.syms.paramInfo(p).default_from;
        if (from != .none) return s.syms.owner(from);
    }
    return .none;
}

/// A parameter's written default expression.
pub fn paramDefault(s: *sema.Sema, p: Sym) ?*const ast.Expr {
    // Read where the function's own body lowers, which has its AST.
    return switch (s.syms.get(p).decl) {
        .param => |pd| pd.?.default,
        .class_param => |cp| if (cp.?.default) |*d| d else null,
        else => null,
    };
}

fn declSpan(s: *sema.Sema, f: Sym) span.Span {
    return switch (s.syms.get(f).decl) {
        .function => |fd| if (fd) |x| x.span else no_span,
        .secondary_ctor => |sc| if (sc) |x| x.span else no_span,
        .class => |c| if (c) |x| x.span else no_span,
        else => no_span,
    };
}
