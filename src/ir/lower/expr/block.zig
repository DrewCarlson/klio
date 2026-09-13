//! Block lowering and the small path/segment utilities.

const std = @import("std");
const ast = @import("ast");
const ir = @import("../../ir.zig");
const build = @import("../../build.zig");
const literals = @import("../literals.zig");
const ast_scan = @import("../ast_scan.zig");
const stmt_mod = @import("../stmt.zig");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const AstBlock = ast.Block;
const Reg = ir.Reg;
const StringSet = std.StringHashMap(void);
const collectPathIdents = ast_scan.collectPathIdents;
const collectPathIdentsStmt = ast_scan.collectPathIdentsStmt;
const isPkgRoot = literals.isPkgRoot;
const lowerStmt = stmt_mod.lowerStmt;

const paths_mod = @import("paths.zig");
const loweredCheckTypeName = paths_mod.loweredCheckTypeName;

const arg_shape_mod = @import("arg_shape.zig");
const narrowNullCheckAll = arg_shape_mod.narrowNullCheckAll;

// -------------------------------------------------------------------------
// Block lowering.
// -------------------------------------------------------------------------

/// Lower a block expression, returning the register holding its tail value.
pub fn lowerBlock(b: *FuncBuilder, block: *const AstBlock) Allocator.Error!Reg {
    try b.pushScope();
    // Hoist the local-fn names an earlier-declared sibling references, so a
    // mutually-recursive forward reference resolves through a shared cell.
    try hoistMutualLocalFns(b, block);
    // An early-return guard narrows the REST of the block: after
    // `if (a == null) return`, `a` is not null for everything below it,
    // because the only path that reaches them is the one where the check
    // failed. Kotlin narrows there and the guard is the idiomatic shape.
    var guarded: std.ArrayList(build.FuncBuilder.NarrowedLocal) = .empty;
    defer guarded.deinit(b.allocator);
    var last: ?Reg = null;
    const block_tail = b.tail_pos;
    b.tail_pos = false;
    for (block.stmts, 0..) |*stmt, si| {
        // The last statement, or one followed only by a bare `return`, is
        // in tail position when the block is.
        const is_last = si + 1 == block.stmts.len;
        const before_bare_return = si + 2 == block.stmts.len and
            block.stmts[si + 1] == .Expr and block.stmts[si + 1].Expr == .Return and
            block.stmts[si + 1].Expr.Return.value == null;
        b.tail_pos = block_tail and stmt.* == .Expr and (is_last or before_bare_return);
        last = try lowerStmt(b, stmt);
        try narrowAfterExitGuard(b, stmt, &guarded);
    }
    const result = last orelse try b.emitConst(.Unit);
    var gi = guarded.items.len;
    while (gi > 0) : (gi -= 1) b.restoreLocal(guarded.items[gi - 1]);
    try b.popScope();
    return result;
}

/// Narrowings an already-lowered guard statement proves for the statements
/// that FOLLOW it. Only an `if` whose then-branch cannot fall through, and
/// only the non-null facts its condition's negation proves.
fn narrowAfterExitGuard(
    b: *FuncBuilder,
    stmt: *const ast.Stmt,
    out: *std.ArrayList(build.FuncBuilder.NarrowedLocal),
) Allocator.Error!void {
    if (stmt.* != .Expr or stmt.Expr != .If) return;
    const f = stmt.Expr.If;
    if (f.else_branch != null) return;
    if (!exprAlwaysExits(f.then_branch)) return;
    try narrowNullCheckAll(b, f.cond, false, out);
    try narrowNegatedIsCheckAll(b, f.cond, out);
}

/// Every `!is` fact a failed exit guard proves for the code below it. The
/// negation of `x !is T || y !is U` proves both `x is T` and `y is U`,
/// mirroring the null walk's `||` polarity. Kotlin narrows here and stdlib
/// leans on it: `ValueTimeMark.minus(ComparableTimeMark)` throws unless
/// `other is ValueTimeMark`, then calls `this.minus(other)` meaning the
/// ValueTimeMark overload — without the narrow the static bind resolved the
/// call back to the enclosing overload and recursed.
fn narrowNegatedIsCheckAll(
    b: *FuncBuilder,
    cond: *const Expr,
    out: *std.ArrayList(build.FuncBuilder.NarrowedLocal),
) Allocator.Error!void {
    if (cond.* == .Binary and cond.Binary.op == .Or) {
        try narrowNegatedIsCheckAll(b, cond.Binary.lhs, out);
        try narrowNegatedIsCheckAll(b, cond.Binary.rhs, out);
        return;
    }
    if (cond.* != .IsCheck) return;
    const ck = cond.IsCheck;
    if (!ck.negated) return;
    const head = loweredCheckTypeName(b, &ck.ty);
    if (head.len == 0) return;
    if (ck.expr.* == .Path and ck.expr.Path.segments.len == 1) {
        try out.append(b.allocator, try b.narrowLocal(ck.expr.Path.segments[0].name, head));
    } else if (ck.expr.* == .This and ck.expr.This.qualifier == null) {
        try out.append(b.allocator, try b.narrowLocal("this", head));
    }
}

/// Whether control cannot fall out of this expression: it returns, throws,
/// breaks or continues on every path.
fn exprAlwaysExits(e: *const Expr) bool {
    return switch (e.*) {
        .Return, .Throw, .Break, .Continue => true,
        .Block => |blk| blk.stmts.len != 0 and
            blk.stmts[blk.stmts.len - 1] == .Expr and
            exprAlwaysExits(&blk.stmts[blk.stmts.len - 1].Expr),
        .If => |inner| inner.else_branch != null and
            exprAlwaysExits(inner.then_branch) and
            exprAlwaysExits(inner.else_branch.?),
        else => false,
    };
}

pub fn hoistMutualLocalFns(b: *FuncBuilder, block: *const AstBlock) Allocator.Error!void {
    // Collect (stmt index, function) for each local-fn decl in this block.
    const LocalFn = struct { pos: usize, func: *const ast.Function };
    var local_fns: std.ArrayList(LocalFn) = .empty;
    defer local_fns.deinit(b.allocator);
    for (block.stmts, 0..) |*s, i| {
        if (s.* == .Decl and s.Decl == .Function) {
            local_fns.append(b.allocator, .{ .pos = i, .func = &s.Decl.Function }) catch return error.OutOfMemory;
        }
    }
    for (local_fns.items, 0..) |k, k_idx| {
        _ = k_idx;
        const k_pos = k.pos;
        const k_fn = k.func;
        var needs_hoist = false;
        for (local_fns.items) |i_entry| {
            if (i_entry.pos >= k_pos) break;
            const i_fn = i_entry.func;
            if (i_fn.body) |body| {
                var refs = StringSet.init(b.allocator);
                defer refs.deinit();
                switch (body) {
                    .Block => |blk| {
                        for (blk.stmts) |*s| try collectPathIdentsStmt(s, &refs);
                    },
                    .Expr => |*e| try collectPathIdents(e, &refs),
                }
                if (refs.contains(k_fn.name.name)) {
                    needs_hoist = true;
                    break;
                }
            }
        }
        if (needs_hoist and b.mutableHome(k_fn.name.name) == null) {
            const null_v = try b.emitConst(.Null);
            const home = b.allocReg();
            try b.push(.{ .MakeCell = .{ .dst = home, .src = null_v } });
            try b.setMutableHome(k_fn.name.name, home);
            try b.markMutable(k_fn.name.name);
            try b.markBoxed(k_fn.name.name);
            try b.bind(k_fn.name.name, home);
        }
    }
}

// -------------------------------------------------------------------------
// Small generic utilities.
// -------------------------------------------------------------------------

/// Index into a slice by a `u32` id, returning a const pointer or null.
pub fn idGet(comptime T: type, items: []const T, idx: u32) ?*const T {
    if (idx >= items.len) return null;
    return &items[idx];
}

/// Decide whether a dotted head `head` is a package-qualified global
/// (flatten the dotted path to a `LoadGlobal`-of-FQN) rather than a member
/// of an implicit receiver (walk `this`).
///
/// A head is a package head when it is a real package root (`kotlin`, `io`,
/// `org`, …) or names a package the program contributes a top-level symbol
/// to (`head.<rest>` is a declared FQN prefix). This is the one principled
/// predicate that replaces the former `isLambdaBody()` resolution axis: a
/// member/captured/local name shadows a package head (the caller filters
/// those with `resolve`/`knowsOuter`/`classId` guards at the use site), and
/// a name resolving to a package/imported/stdlib FQN resolves globally —
/// the same answer whether or not the reference is lexically inside a
/// lambda.
pub fn headIsPackage(b: *FuncBuilder, head: []const u8) bool {
    return isPkgRoot(head) or b.module.packageHeadDeclared(head);
}

/// The last segment after the final `sep`, or the whole string when absent.
pub fn rsplitLast(s: []const u8, sep: u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, s, sep)) |i| return s[i + 1 ..];
    return s;
}

/// The first segment before the first `.`, or the whole string when absent.
pub fn firstSegment(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '.')) |i| return s[0..i];
    return s;
}

/// Join `segments[*].name` with `.`. The caller owns the returned slice.
pub fn joinSegments(allocator: Allocator, segments: []const ast.Ident) Allocator.Error![]u8 {
    var total: usize = 0;
    for (segments, 0..) |s, i| {
        total += s.name.len;
        if (i != 0) total += 1;
    }
    var out = try allocator.alloc(u8, total);
    var off: usize = 0;
    for (segments, 0..) |s, i| {
        if (i != 0) {
            out[off] = '.';
            off += 1;
        }
        @memcpy(out[off .. off + s.name.len], s.name);
        off += s.name.len;
    }
    return out;
}

/// Snapshot a string set into an owned slice of its keys (borrowed slices).
pub fn setToSlice(allocator: Allocator, set: *const StringSet) Allocator.Error![][]const u8 {
    const out = try allocator.alloc([]const u8, set.count());
    var i: usize = 0;
    var it = set.keyIterator();
    while (it.next()) |k| : (i += 1) out[i] = k.*;
    return out;
}
