//! `for (x in xs) body` loop lowering, over the shared `FuncBuilder`.

const std = @import("std");
const ast = @import("ast");
const ir = @import("../ir.zig");
const build = @import("../build.zig");
const expr = @import("expr.zig");
const stmt_mod = @import("stmt.zig");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const Reg = ir.Reg;
const Inst = ir.Inst;
const Const = ir.Const;
const Terminator = ir.Terminator;

const lowerExpr = expr.lowerExpr;

pub fn lowerFor(
    b: *FuncBuilder,
    vars: []const ast.Ident,
    by_name: bool,
    destructured: bool,
    sources: []const ast.Ident,
    iter: *const Expr,
    body: *const Expr,
) Allocator.Error!Reg {
    return lowerForLabeled(b, vars, by_name, destructured, sources, iter, body, null);
}


fn countedEnabled() bool {
    return true;
}

pub fn lowerForLabeled(
    b: *FuncBuilder,
    vars: []const ast.Ident,
    by_name: bool,
    destructured: bool,
    sources: []const ast.Ident,
    iter: *const Expr,
    body: *const Expr,
    label: ?[]const u8,
) Allocator.Error!Reg {
    if (try lowerCountedRange(b, vars, by_name, destructured, iter, body, label)) |r| return r;
    return lowerIteratorLoop(b, vars, by_name, destructured, sources, iter, body, label);
}

// -------------------------------------------------------------------------
// The counted-range register loop.
// -------------------------------------------------------------------------

/// The register-loop shape a counted `for` runs.
const CountedShape = struct {
    /// `null` when the bounds come from a range-typed iterable's `first`/`last`
    /// rather than from two written-out operands.
    lo_e: ?*const Expr = null,
    hi_e: ?*const Expr = null,
    inclusive: bool = false,
    /// `a downTo b` starts at `a` with step -1 and inclusive `b`: the same
    /// equality-exit loop with the compare and step reversed.
    descending: bool = false,
    /// `… step k` with a positive Int-literal k is the same loop with the exit
    /// bound snapped to the progression's real last element. A non-literal step
    /// keeps the iterator lowering, its step-positive throw and dynamic last
    /// belonging to the progression object.
    step_lit: i64 = 1,
    is_int: bool = false,
    is_long: bool = false,
    /// Char ranges run the same register loop: Char comparisons order by code and
    /// `Char +/- Int` yields Char. The step-snap arithmetic is Int-only, so a
    /// stepped char progression keeps the iterator lowering.
    is_char: bool = false,
};

/// The bound registers a counted loop compares and steps between.
const CountedBounds = struct { lo: Reg, hi: Reg };

/// Everything the counted loop's blocks emit against, once the bounds and the
/// step have been evaluated.
const CountedLoop = struct {
    shape: CountedShape,
    i_reg: Reg,
    hi: Reg,
    one: Reg,
    eq_bound: Reg,
};

/// Counted-range strength reduction: `for (i in a until b)` and `for (i in a..b)`
/// over same-typed Int/Long operands lower to a plain register loop, with no Range
/// object, iterator, or virtual protocol call per iteration. `KLIO_COUNTED=0`
/// restores the iterator lowering.
///
/// `null` means the iterable keeps the iterator lowering, with nothing emitted.
fn lowerCountedRange(
    b: *FuncBuilder,
    vars: []const ast.Ident,
    by_name: bool,
    destructured: bool,
    iter: *const Expr,
    body: *const Expr,
    label: ?[]const u8,
) Allocator.Error!?Reg {
    if (vars.len != 1 or by_name or destructured or !countedEnabled()) return null;
    const shape = countedShape(b, iter) orelse return null;

    const bounds = try emitCountedBounds(b, iter, shape);
    const i_reg = b.allocReg();
    try b.push(.{ .Move = .{ .dst = i_reg, .src = bounds.lo } });
    const one = if (shape.is_long)
        try b.emitConst(.{ .Long = shape.step_lit })
    else
        try b.emitConst(.{ .Int = @intCast(shape.step_lit) });
    const eq_bound = if (shape.step_lit != 1)
        try emitSteppedEqBound(b, shape, bounds.hi, i_reg, one)
    else
        bounds.hi;

    return try emitCountedLoop(b, .{
        .shape = shape,
        .i_reg = i_reg,
        .hi = bounds.hi,
        .one = one,
        .eq_bound = eq_bound,
    }, vars, body, label);
}

/// The `… step k` call peeled off an iterable, with the range it applies to.
const StepPeel = struct {
    /// The range the step applies to, or the iterable itself when no literal
    /// step was peeled.
    shape: *const Expr,
    step: i64,
};

/// `… step k` with a positive Int-literal k is the same loop with the exit
/// bound snapped to the progression's real last element. A non-literal step
/// keeps the iterator lowering, its step-positive throw and dynamic last
/// belonging to the progression object.
fn peelStepCall(iter: *const Expr) StepPeel {
    var step_lit: i64 = 1;
    var iter_shape = iter;
    if (iter.* == .Call) {
        const c = &iter.Call;
        if (c.is_infix and c.args.len == 2 and c.callee.* == .Path and
            c.callee.Path.segments.len == 1 and
            std.mem.eql(u8, c.callee.Path.segments[0].name, "step") and
            c.args[1] == .IntLit and c.args[1].IntLit.value > 0)
        {
            const inner = &c.args[0];
            const inner_counted = switch (inner.*) {
                .Binary => |bin| bin.op == .Range,
                .Call => |ic| ic.is_infix and ic.args.len == 2 and
                    ic.callee.* == .Path and ic.callee.Path.segments.len == 1 and
                    std.mem.eql(u8, ic.callee.Path.segments[0].name, "downTo"),
                else => false,
            };
            // The floorMod shift below adds k to a |x| < k value, so cap the
            // literal to keep that sum from wrapping.
            if (inner_counted and c.args[1].IntLit.value <= (1 << 30)) {
                step_lit = c.args[1].IntLit.value;
                iter_shape = inner;
            }
        }
    }
    return .{ .shape = iter_shape, .step = step_lit };
}

/// The two written-out ends of a range shape, with the direction they run in.
/// Both ends stay `null` for an iterable whose range-ness is only in its static
/// type; `null` means the shape is not a range at all.
const RangeEnds = struct {
    lo_e: ?*const Expr = null,
    hi_e: ?*const Expr = null,
    inclusive: bool = false,
    descending: bool = false,
};

fn rangeEnds(iter_shape: *const Expr) ?RangeEnds {
    var out: RangeEnds = .{};
    switch (iter_shape.*) {
        .Binary => |bin| switch (bin.op) {
            .Range => {
                out.inclusive = true;
                out.lo_e = bin.lhs;
                out.hi_e = bin.rhs;
            },
            .RangeUntil => {
                out.lo_e = bin.lhs;
                out.hi_e = bin.rhs;
            },
            else => return null,
        },
        .Call => |c| blk: {
            if (c.is_infix and c.args.len == 2 and c.callee.* == .Path and
                c.callee.Path.segments.len == 1)
            {
                const nm = c.callee.Path.segments[0].name;
                if (std.mem.eql(u8, nm, "until")) {
                    out.lo_e = &c.args[0];
                    out.hi_e = &c.args[1];
                    break :blk;
                }
                if (std.mem.eql(u8, nm, "downTo")) {
                    out.descending = true;
                    out.inclusive = true;
                    out.lo_e = &c.args[0];
                    out.hi_e = &c.args[1];
                    break :blk;
                }
            }
            // A call whose static type is a range still counts, below.
        },
        else => {},
    }
    return out;
}

/// Settle the register-loop shape of `iter`, or `null` to keep the iterator
/// lowering.
fn countedShape(b: *FuncBuilder, iter: *const Expr) ?CountedShape {
    const peeled = peelStepCall(iter);
    const ends = rangeEnds(peeled.shape) orelse return null;
    var out = CountedShape{
        .lo_e = ends.lo_e,
        .hi_e = ends.hi_e,
        .inclusive = ends.inclusive,
        .descending = ends.descending,
        .step_lit = peeled.step,
    };
    if (out.step_lit != 1 and out.lo_e == null) return null;
    if (out.lo_e) |le| {
        var lo_ty = (expr.staticExprTypeRef(b, le) catch null) orelse return null;
        defer lo_ty.deinit(b.allocator);
        var hi_ty = (expr.staticExprTypeRef(b, out.hi_e.?) catch null) orelse return null;
        defer hi_ty.deinit(b.allocator);
        out.is_int = std.mem.eql(u8, lo_ty.name, "Int") and std.mem.eql(u8, hi_ty.name, "Int");
        out.is_long = std.mem.eql(u8, lo_ty.name, "Long") and std.mem.eql(u8, hi_ty.name, "Long");
        out.is_char = std.mem.eql(u8, lo_ty.name, "Char") and std.mem.eql(u8, hi_ty.name, "Char");
        if ((!out.is_int and !out.is_long and !out.is_char) or lo_ty.nullable or hi_ty.nullable) return null;
        if (out.is_char and out.step_lit != 1) return null;
    } else {
        // Type-driven prong: an iterable whose static type is a non-nullable
        // IntRange or LongRange iterates `[first, last]` step 1 by construction.
        // Progressions type as IntProgression and keep the iterator lowering.
        var ity = (expr.staticExprTypeRef(b, iter) catch null) orelse return null;
        defer ity.deinit(b.allocator);
        if (ity.nullable) return null;
        var head = ity.name;
        if (std.mem.findScalarLast(u8, head, '.')) |d| head = head[d + 1 ..];
        out.is_int = std.mem.eql(u8, head, "IntRange");
        out.is_long = std.mem.eql(u8, head, "LongRange");
        out.is_char = std.mem.eql(u8, head, "CharRange");
        if (!out.is_int and !out.is_long and !out.is_char) return null;
        out.inclusive = true;
    }
    return out;
}

/// Bounds evaluate once, in source order, before the loop.
fn emitCountedBounds(b: *FuncBuilder, iter: *const Expr, shape: CountedShape) Allocator.Error!CountedBounds {
    if (shape.lo_e) |le| {
        const lo = try lowerExpr(b, le);
        const hi_raw = try lowerExpr(b, shape.hi_e.?);
        const hi = b.allocReg();
        try b.push(.{ .Move = .{ .dst = hi, .src = hi_raw } });
        return .{ .lo = lo, .hi = hi };
    }
    const rng = try lowerExpr(b, iter);
    const first_name = try b.module.internConst(b.allocator, .{ .String = "first" });
    const last_name = try b.module.internConst(b.allocator, .{ .String = "last" });
    const lo = b.allocReg();
    try b.push(.{ .GetField = .{ .dst = lo, .receiver = rng, .field = first_name } });
    const hi = b.allocReg();
    try b.push(.{ .GetField = .{ .dst = hi, .receiver = rng, .field = last_name } });
    return .{ .lo = lo, .hi = hi };
}

/// With a step above 1 the equality exit must hit the progression's real last
/// element. kotlinc's overflow-free `getProgressionLastElement` keeps the
/// bounds in modulo-k arithmetic rather than a wide subtraction:
///   asc:  last = hi - floorMod(hi % k - lo % k, k)
///   desc: last = hi + floorMod(lo % k - hi % k, k)
/// `floorMod(x, k)` for |x| < k is `((x + k) % k)`, and the step cap keeps
/// `x + k` in range. The header's emptiness check keeps the original bound.
fn emitSteppedEqBound(
    b: *FuncBuilder,
    shape: CountedShape,
    hi: Reg,
    i_reg: Reg,
    one: Reg,
) Allocator.Error!Reg {
    const descending = shape.descending;
    const hi_mod = b.allocReg();
    try b.push(.{ .BinOp = .{ .dst = hi_mod, .op = .Mod, .lhs = hi, .rhs = one } });
    const lo_mod = b.allocReg();
    try b.push(.{ .BinOp = .{ .dst = lo_mod, .op = .Mod, .lhs = i_reg, .rhs = one } });
    const diff = b.allocReg();
    try b.push(.{ .BinOp = .{
        .dst = diff,
        .op = .Sub,
        .lhs = if (descending) lo_mod else hi_mod,
        .rhs = if (descending) hi_mod else lo_mod,
    } });
    const shifted = b.allocReg();
    try b.push(.{ .BinOp = .{ .dst = shifted, .op = .Add, .lhs = diff, .rhs = one } });
    const fmod = b.allocReg();
    try b.push(.{ .BinOp = .{ .dst = fmod, .op = .Mod, .lhs = shifted, .rhs = one } });
    const eq_bound = b.allocReg();
    try b.push(.{ .BinOp = .{
        .dst = eq_bound,
        .op = if (descending) .Add else .Sub,
        .lhs = hi,
        .rhs = fmod,
    } });
    return eq_bound;
}

/// Lay out the header/body/tail/increment/exit blocks and fill each one.
fn emitCountedLoop(
    b: *FuncBuilder,
    cl: CountedLoop,
    vars: []const ast.Ident,
    body: *const Expr,
    label: ?[]const u8,
) Allocator.Error!Reg {
    const header = try b.allocBlock();
    const body_blk = try b.allocBlock();
    const tail_blk = try b.allocBlock();
    const incr = try b.allocBlock();
    const exit = try b.allocBlock();
    b.terminate(.{ .Goto = header });

    b.switchTo(header);
    try emitCountedEntryCheck(b, cl, body_blk, exit);

    b.switchTo(body_blk);
    try emitCountedBody(b, cl, vars, body, label, tail_blk, exit);

    b.switchTo(tail_blk);
    try emitCountedTailCheck(b, cl, incr, exit);

    b.switchTo(incr);
    try emitCountedIncrement(b, cl, body_blk, header);

    b.switchTo(exit);
    return b.emitConst(.Unit);
}

/// The entry check runs once. The inclusive form must terminate at
/// `hi == MAX_VALUE`, where increment-then-compare would wrap, so its exit is
/// an equality check before the increment: `i == hi` is done, else `i < hi`
/// and `i + 1` cannot overflow. The exclusive form's compare is safe as is.
fn emitCountedEntryCheck(
    b: *FuncBuilder,
    cl: CountedLoop,
    body_blk: ir.BlockId,
    exit: ir.BlockId,
) Allocator.Error!void {
    const cond = b.allocReg();
    try b.push(.{ .BinOp = .{
        .dst = cond,
        .op = if (cl.shape.descending) .GreaterEq else if (cl.shape.inclusive) .LessEq else .Less,
        .lhs = cl.i_reg,
        .rhs = cl.hi,
    } });
    b.terminate(.{ .Branch = .{ .cond = cond, .t = body_blk, .f = exit } });
}

fn emitCountedBody(
    b: *FuncBuilder,
    cl: CountedLoop,
    vars: []const ast.Ident,
    body: *const Expr,
    label: ?[]const u8,
    tail_blk: ir.BlockId,
    exit: ir.BlockId,
) Allocator.Error!void {
    try b.pushScope();
    try bindCountedVar(b, vars[0], cl);
    // `continue` re-enters at the per-iteration exit check, never the body or
    // the increment.
    try b.pushLoop(label, tail_blk, exit);
    _ = try lowerExpr(b, body);
    b.popLoop();
    try b.popScope();
    b.terminate(.{ .Goto = tail_blk });
}

/// The single loop variable aliases the induction register outright, and takes
/// the element type the bounds settled on.
fn bindCountedVar(b: *FuncBuilder, v: ast.Ident, cl: CountedLoop) Allocator.Error!void {
    try b.bind(v.name, cl.i_reg);
    try b.setLocalDeclTypeOwned(v.name, .{
        .name = try b.allocator.dupe(u8, if (cl.shape.is_long) "Long" else if (cl.shape.is_char) "Char" else "Int"),
        .nullable = false,
        .args = &.{},
    });
}

fn emitCountedTailCheck(
    b: *FuncBuilder,
    cl: CountedLoop,
    incr: ir.BlockId,
    exit: ir.BlockId,
) Allocator.Error!void {
    if (cl.shape.inclusive) {
        const done = b.allocReg();
        try b.push(.{ .BinOp = .{ .dst = done, .op = .Eq, .lhs = cl.i_reg, .rhs = cl.eq_bound } });
        b.terminate(.{ .Branch = .{ .cond = done, .t = exit, .f = incr } });
    } else {
        b.terminate(.{ .Goto = incr });
    }
}

fn emitCountedIncrement(
    b: *FuncBuilder,
    cl: CountedLoop,
    body_blk: ir.BlockId,
    header: ir.BlockId,
) Allocator.Error!void {
    try b.push(.{ .BinOp = .{
        .dst = cl.i_reg,
        .op = if (cl.shape.descending) .Sub else .Add,
        .lhs = cl.i_reg,
        .rhs = cl.one,
    } });
    b.terminate(.{ .Goto = if (cl.shape.inclusive) body_blk else header });
}

// -------------------------------------------------------------------------
// The iterator-protocol loop.
// -------------------------------------------------------------------------

/// Static protocol binding: when the iterable's `iterator()` return resolves to
/// the `Iterator` interface itself, `hasNext` and `next` emit slot-bound against
/// its roots, which the runtime serves by FuncId. A convention-based iterator
/// with no interface keeps the by-name form.
const IterBinding = struct {
    iter_root: ?ir.FuncId = null,
    iter_ext_fid: ?ir.FuncId = null,
    hn_root: ?ir.FuncId = null,
    next_root: ?ir.FuncId = null,
};

fn lowerIteratorLoop(
    b: *FuncBuilder,
    vars: []const ast.Ident,
    by_name: bool,
    destructured: bool,
    sources: []const ast.Ident,
    iter: *const Expr,
    body: *const Expr,
    label: ?[]const u8,
) Allocator.Error!Reg {
    const recv = try lowerExpr(b, iter);
    const it_reg = b.allocReg();
    const zero = b.allocReg();
    try b.push(.{ .Move = .{ .dst = zero, .src = recv } });
    const binding = try staticIteratorBinding(b, vars, iter);
    try emitIteratorCall(b, binding, it_reg, zero);

    const header = try b.allocBlock();
    const body_blk = try b.allocBlock();
    const exit = try b.allocBlock();
    b.terminate(.{ .Goto = header });

    b.switchTo(header);
    try emitHasNextCheck(b, binding, it_reg, body_blk, exit);

    b.switchTo(body_blk);
    try b.pushScope();
    const next_reg = try emitNextCall(b, binding, it_reg);
    try bindLoopVars(b, vars, by_name, destructured, sources, iter, next_reg);
    try b.pushLoop(label, header, exit);
    _ = try lowerExpr(b, body);
    b.popLoop();
    try b.popScope();
    b.terminate(.{ .Goto = header });

    b.switchTo(exit);
    return b.emitConst(.Unit);
}

/// Settle which of the three protocol calls can bind statically.
fn staticIteratorBinding(
    b: *FuncBuilder,
    vars: []const ast.Ident,
    iter: *const Expr,
) Allocator.Error!IterBinding {
    var out: IterBinding = .{};
    var ity = (try expr.staticExprTypeRef(b, iter)) orelse return out;
    defer ity.deinit(b.allocator);
    const file = vars[0].span.file;
    out.iter_root = receiverIteratorRoot(b, ity, file);
    // A member `iterator()` first; a receiver served only by the unique top-level
    // extension binds through its declared return the same way.
    if ((try expr.nullaryMemberReturnTypeRef(b, ity, "iterator", file)) orelse
        (try expr.extensionNullaryReturnTypeRef(b, ity, "iterator", &out.iter_ext_fid))) |irt0|
    {
        var irt = irt0;
        defer irt.deinit(b.allocator);
        var head = std.mem.trimEnd(u8, irt.name, "?");
        if (std.mem.findScalar(u8, head, '<')) |lt| head = head[0..lt];
        if (std.mem.findScalarLast(u8, head, '.')) |d| head = head[d + 1 ..];
        if (iteratorFamily(b, head)) bindIteratorFamilyRoots(b, head, &out);
    }
    return out;
}

/// The receiver's own member `iterator()` binds through its virtual slot, so a
/// range for-loop no longer walks the name on each entry.
fn receiverIteratorRoot(b: *FuncBuilder, ity: ir.TypeRef, file: ir.FileId) ?ir.FuncId {
    var rhead = std.mem.trimEnd(u8, ity.name, "?");
    if (std.mem.findScalar(u8, rhead, '<')) |lt| rhead = rhead[0..lt];
    const rcid = (if (std.mem.findScalar(u8, rhead, '.') != null)
        b.module.classIdByFqn(rhead)
    else
        b.module.uniqueClassIdBySimpleName(rhead));
    const cid = rcid orelse return null;
    if (cid.int() >= b.module.classes.items.len) return null;
    const rfqn = b.module.classes.items[cid.int()].fqn;
    const it_decls = b.module.memberDecls(rfqn, "iterator");
    if (it_decls.len != 0) return it_decls[0];
    // An inherited member: the resolver chases supers.
    const resolved = b.module.resolveMemberCall(cid, "iterator", &.{}, .{
        .caller_file = file,
        .lexical_owner = null,
        .actual_type_param_bounds = &.{},
        .receiver_type = ity,
    });
    return resolved.target;
}

/// The interface itself, or a primitive-iterator abstract class: `hasNext`
/// roots on the interface, while `next` prefers the head class's own
/// override, which delegates to the `nextByte()`-family.
fn iteratorFamily(b: *FuncBuilder, head: []const u8) bool {
    if (std.mem.eql(u8, head, "Iterator")) return true;
    if (!std.mem.endsWith(u8, head, "Iterator")) return false;
    // The kotlin.collections primitive-iterator family only; a pack
    // class ending in `Iterator` has its own dispatch story.
    const cid = b.module.uniqueClassIdBySimpleName(head) orelse return false;
    if (cid.int() >= b.module.classes.items.len) return false;
    return std.mem.startsWith(u8, b.module.classes.items[cid.int()].fqn, "kotlin.collections.");
}

fn bindIteratorFamilyRoots(b: *FuncBuilder, head: []const u8, out: *IterBinding) void {
    if (b.module.uniqueClassIdBySimpleName("Iterator")) |icid| {
        if (icid.int() < b.module.classes.items.len) {
            const ifqn = b.module.classes.items[icid.int()].fqn;
            const hn_decls = b.module.memberDecls(ifqn, "hasNext");
            const nx_decls = b.module.memberDecls(ifqn, "next");
            if (hn_decls.len != 0) out.hn_root = hn_decls[0];
            if (nx_decls.len != 0) out.next_root = nx_decls[0];
        }
    }
    if (!std.mem.eql(u8, head, "Iterator")) {
        if (b.module.uniqueClassIdBySimpleName(head)) |hcid| {
            if (hcid.int() < b.module.classes.items.len) {
                const hfqn = b.module.classes.items[hcid.int()].fqn;
                const own_next = b.module.memberDecls(hfqn, "next");
                if (own_next.len != 0) out.next_root = own_next[0];
                const own_hn = b.module.memberDecls(hfqn, "hasNext");
                if (own_hn.len != 0) out.hn_root = own_hn[0];
            }
        }
    }
}

fn emitIteratorCall(b: *FuncBuilder, binding: IterBinding, it_reg: Reg, zero: Reg) Allocator.Error!void {
    if (binding.iter_root) |root| {
        const vargs = b.allocReg();
        try b.push(.{ .CallVirtual = .{
            .dst = it_reg,
            .receiver = zero,
            .slot = ir.MethodSlotId.fromFunc(root),
            .args = vargs,
            .n_args = 0,
        } });
    } else if (binding.iter_ext_fid) |ext_fid| {
        try b.push(.{ .Call = .{
            .dst = it_reg,
            .func = ext_fid,
            .trailing_lambda = false,
            .args = zero,
            .n_args = 1,
            .arg_names = &.{},
            .type_args = &.{},
            .exact = true,
        } });
    } else {
        const name = try b.module.internConst(b.allocator, .{ .String = "iterator" });
        const args_start = b.allocReg();
        try b.push(.{ .CallMember = .{
            .dst = it_reg,
            .receiver = zero,
            .name = name,
            .args = args_start,
            .n_args = 0,
            .arg_names = &.{},
        } });
    }
}

fn emitHasNextCheck(
    b: *FuncBuilder,
    binding: IterBinding,
    it_reg: Reg,
    body_blk: ir.BlockId,
    exit: ir.BlockId,
) Allocator.Error!void {
    const has_next = b.allocReg();
    const hn_name = try b.module.internConst(b.allocator, .{ .String = "hasNext" });
    const hn_args = b.allocReg();
    if (binding.hn_root) |root| {
        try b.push(.{ .CallVirtual = .{
            .dst = has_next,
            .receiver = it_reg,
            .slot = ir.MethodSlotId.fromFunc(root),
            .args = hn_args,
            .n_args = 0,
        } });
    } else try b.push(.{ .CallMember = .{
        .dst = has_next,
        .receiver = it_reg,
        .name = hn_name,
        .args = hn_args,
        .n_args = 0,
        .arg_names = &.{},
    } });
    b.terminate(.{ .Branch = .{
        .cond = has_next,
        .t = body_blk,
        .f = exit,
    } });
}

fn emitNextCall(b: *FuncBuilder, binding: IterBinding, it_reg: Reg) Allocator.Error!Reg {
    const next_reg = b.allocReg();
    const next_name = try b.module.internConst(b.allocator, .{ .String = "next" });
    const nargs = b.allocReg();
    if (binding.next_root) |root| {
        try b.push(.{ .CallVirtual = .{
            .dst = next_reg,
            .receiver = it_reg,
            .slot = ir.MethodSlotId.fromFunc(root),
            .args = nargs,
            .n_args = 0,
        } });
    } else try b.push(.{ .CallMember = .{
        .dst = next_reg,
        .receiver = it_reg,
        .name = next_name,
        .args = nargs,
        .n_args = 0,
        .arg_names = &.{},
    } });
    return next_reg;
}

/// Bind the loop's names to the element the iterator just produced.
fn bindLoopVars(
    b: *FuncBuilder,
    vars: []const ast.Ident,
    by_name: bool,
    destructured: bool,
    sources: []const ast.Ident,
    iter: *const Expr,
    next_reg: Reg,
) Allocator.Error!void {
    if (vars.len == 1 and !by_name and !destructured) {
        try bindSingleLoopVar(b, vars[0], iter, next_reg);
    } else if (by_name) {
        try bindNamedLoopVars(b, vars, sources, next_reg);
    } else {
        try bindDestructuredLoopVars(b, vars, iter, next_reg);
    }
}

fn bindSingleLoopVar(b: *FuncBuilder, v: ast.Ident, iter: *const Expr, next_reg: Reg) Allocator.Error!void {
    try b.bind(v.name, next_reg);
    if (try expr.iterableElementTypeName(b, iter)) |elem| {
        try b.setLocalDeclTypeOwned(v.name, .{
            .name = elem,
            .nullable = false,
            .args = &.{},
        });
    } else if (std.c.getenv("KLIO_FORVAR_TRACE") != null) {
        std.debug.print("[forvar] {s} elem=null iter_tag={s} fn={s} splice={s}\n", .{ v.name, @tagName(std.meta.activeTag(iter.*)), build.currentRealFn() orelse "-", b.spliceRecvTy() orelse "-" });
    }
}

/// `for ((val k, val v) in xs)`: each name reads its property off the element.
fn bindNamedLoopVars(
    b: *FuncBuilder,
    vars: []const ast.Ident,
    sources: []const ast.Ident,
    next_reg: Reg,
) Allocator.Error!void {
    for (vars, 0..) |v, i| {
        const dst = b.allocReg();
        const field = try b.module.internConst(b.allocator, .{ .String = sources[i].name });
        try b.push(.{ .GetField = .{ .dst = dst, .receiver = next_reg, .field = field } });
        if (stmt_mod.isUnderscorePlaceholder(v)) continue;
        try b.bind(v.name, dst);
    }
}

/// Each destructured name binds to the element's `componentN()`, so its type
/// is that accessor's declared return on the element.
fn bindDestructuredLoopVars(
    b: *FuncBuilder,
    vars: []const ast.Ident,
    iter: *const Expr,
    next_reg: Reg,
) Allocator.Error!void {
    var elem_ty = try expr.iterableElementTypeRef(b, iter);
    defer if (elem_ty) |*t| t.deinit(b.allocator);
    for (vars, 0..) |v, i| {
        // A bare positional `_` skips its `componentN()` call, as kotlinc never
        // invokes the accessor for a discarded slot.
        if (stmt_mod.isUnderscorePlaceholder(v)) continue;
        const comp = b.allocReg();
        const comp_name = try std.fmt.allocPrint(b.allocator, "component{d}", .{i + 1});
        const nm = try b.module.internConst(b.allocator, .{ .String = comp_name });
        const cargs = b.allocReg();
        try b.push(.{ .CallMember = .{
            .dst = comp,
            .receiver = next_reg,
            .name = nm,
            .args = cargs,
            .n_args = 0,
            .arg_names = &.{},
        } });
        try b.bind(v.name, comp);
        if (elem_ty) |ety| {
            if (try expr.nullaryMemberReturnTypeRef(b, ety, comp_name, iter.span().file)) |ct| {
                try b.setLocalDeclTypeOwned(v.name, ct);
            }
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
