//! AST → CFG lowering. Walks an `ast.Block` (function / accessor /
//! init body) and produces a `Cfg`.
//!
//! Lowering carries a "current block" that subsequent nodes append
//! to. Control-flow forms (`if`, `when`, `while`, `try`, `&&`, `||`,
//! `?:`, `?.`, `!!`, `as`, `return`/`throw`/`break`/`continue`) split
//! the current block and rewire it through the new blocks they
//! create. Terminator-emitting forms leave the current block set to
//! a fresh "dead" block with no predecessors so later statements
//! still lower cleanly into the IR (the reachability analysis will
//! prune them later).
//!
//! The lowering does not consult type information; every `Eval`
//! node is emitted with `Type.Unresolved`. A later integration step
//! routes typed expression results from the typechecker into the
//! lowering so analyses (smart-cast, reachability) can read them.

const std = @import("std");
const ast = @import("ast");
const span = @import("span");
const types = @import("types");
const builder = @import("builder.zig");
const ir = @import("ir.zig");
const contracts = @import("analyses/contracts.zig");

const Allocator = std.mem.Allocator;
const Block = ast.Block;
const Catch = ast.Catch;
const Decl = ast.Decl;
const Expr = ast.Expr;
const Ident = ast.Ident;
const BinOp = ast.BinOp;
const UnOp = ast.UnOp;
const PostfixOp = ast.PostfixOp;
const StringPart = ast.StringPart;
const WhenBranch = ast.WhenBranch;
const WhenPatternKind = ast.WhenPatternKind;
const Span = span.Span;
const Type = types.Type;

const CfgBuilder = builder.CfgBuilder;
const BlockId = ir.BlockId;
const Cfg = ir.Cfg;
const EdgeKind = ir.EdgeKind;
const ExprRef = ir.ExprRef;
const FieldId = ir.FieldId;
const LoopId = ir.LoopId;
const Node = ir.Node;
const Pattern = ir.Pattern;
const Place = ir.Place;
const Reg = ir.Reg;
const SwitchArm = ir.SwitchArm;
const Symbol = ir.Symbol;
const Terminator = ir.Terminator;

/// A `(start, end)` span key for the side-table maps. Mirrors Rust's
/// `(u32, u32)` tuple key (file-relative offsets).
pub const SpanKey = struct { start: u32, end: u32 };

/// Position of a node within the CFG: the block plus the node index.
pub const NodePos = struct { block: BlockId, node_idx: usize };

const SpanKeyContext = struct {
    pub fn hash(_: SpanKeyContext, k: SpanKey) u64 {
        return (@as(u64, k.start) << 32) | @as(u64, k.end);
    }
    pub fn eql(_: SpanKeyContext, a: SpanKey, b: SpanKey) bool {
        return a.start == b.start and a.end == b.end;
    }
};

const RegContext = struct {
    pub fn hash(_: RegContext, r: Reg) u64 {
        return r.int();
    }
    pub fn eql(_: RegContext, a: Reg, b: Reg) bool {
        return a == b;
    }
};

const SymbolContext = struct {
    pub fn hash(_: SymbolContext, s: Symbol) u64 {
        return std.hash.Wyhash.hash(0, s.name);
    }
    pub fn eql(_: SymbolContext, a: Symbol, b: Symbol) bool {
        return a.eql(b);
    }
};

pub const SpanKeyMap = std.HashMap(SpanKey, Reg, SpanKeyContext, std.hash_map.default_max_load_percentage);
pub const SpanPosMap = std.HashMap(SpanKey, NodePos, SpanKeyContext, std.hash_map.default_max_load_percentage);
pub const RegPlaceMap = std.HashMap(Reg, Place, RegContext, std.hash_map.default_max_load_percentage);
pub const AliasMap = std.HashMap(Symbol, Place, SymbolContext, std.hash_map.default_max_load_percentage);
const RefinementMap = std.HashMap(Reg, Refinement, RegContext, std.hash_map.default_max_load_percentage);

/// Lowered output: the CFG plus side tables.
///
/// * `reg_for_span` maps an expression's source span to the register
///   that holds its computed value (last write wins).
/// * `reg_to_place` maps a register to the `Place` it reads, so an
///   `AssumeIs(reg, T)` on a path can refine the original place.
/// * `span_to_pos` maps a span to the `(block, node_idx)` where its
///   `Eval` lands.
/// * `aliases` records `val b = a` style bindings so smart-cast
///   lookups can follow the chain.
pub const Lowered = struct {
    cfg: Cfg,
    reg_for_span: SpanKeyMap,
    reg_to_place: RegPlaceMap,
    span_to_pos: SpanPosMap,
    aliases: AliasMap,
};

const LoopFrame = struct {
    id: LoopId,
    /// Block that `continue` jumps to (typically the loop head).
    cont_target: BlockId,
    /// Block that `break` jumps to (typically the loop exit).
    break_target: BlockId,
    label: ?[]const u8,
};

const LabelFrame = struct {
    name: []const u8,
    /// Block that `return@name` / `break@name` jumps to.
    target: BlockId,
    /// Register for the lambda/block's value, if any. Populated when
    /// `return@name expr` is encountered.
    result: ?Reg,
};

const TryFrame = struct {
    /// Each entry is (exception-type, handler-entry-block). Order
    /// matches source order; the first matching handler wins.
    handlers: []Handler,
    /// Block to flow into for the normal-exit copy of the finally,
    /// when one is present.
    finally_entry: ?BlockId,
};

const Handler = struct { ty: ?Type, block: BlockId };

/// Refinement implied by the truthiness of a boolean-typed register.
/// Carried in `pending_refinements` so `lowerIf` / `lowerWhen` /
/// `lowerShortCircuit` can emit the matching `AssumeIs` or
/// `AssumeNull` on the correct branch arm.
const Refinement = union(enum) {
    Is: struct {
        reg: Reg,
        ty: Type,
        class_name: ?[]const u8,
        polarity: bool,
        span: Span,
    },
    NullEq: struct {
        reg: Reg,
        span: Span,
        eq_null: bool,
    },
    /// Reference-equality of two registers, both of which hold a
    /// `Place`. Used to narrow each place to the intersection of
    /// the two on the truthy branch.
    RefEq: struct {
        reg_a: Reg,
        reg_b: Reg,
        span: Span,
    },
    /// `!cond` flips polarity of every contained refinement.
    Not: *Refinement,
    /// `&&` of multiple refinements — all hold on the true branch.
    And: []Refinement,
    /// `||` of multiple refinements — only the intersection holds on
    /// the true branch, and the union on the false branch. For now we
    /// only emit the symmetric facts; broader handling lives in the
    /// constraint-system milestone.
    Or: []Refinement,

    fn clone(self: Refinement, allocator: Allocator) Allocator.Error!Refinement {
        return switch (self) {
            .Is => |r| .{ .Is = .{
                .reg = r.reg,
                .ty = try r.ty.clone(allocator),
                .class_name = if (r.class_name) |cn| try allocator.dupe(u8, cn) else null,
                .polarity = r.polarity,
                .span = r.span,
            } },
            .NullEq => |r| .{ .NullEq = r },
            .RefEq => |r| .{ .RefEq = r },
            .Not => |inner| blk: {
                const p = try allocator.create(Refinement);
                p.* = try inner.clone(allocator);
                break :blk .{ .Not = p };
            },
            .And => |parts| blk: {
                const out = try allocator.alloc(Refinement, parts.len);
                for (parts, out) |src, *dst| dst.* = try src.clone(allocator);
                break :blk .{ .And = out };
            },
            .Or => |parts| blk: {
                const out = try allocator.alloc(Refinement, parts.len);
                for (parts, out) |src, *dst| dst.* = try src.clone(allocator);
                break :blk .{ .Or = out };
            },
        };
    }
};

pub const Lowering = struct {
    allocator: Allocator,
    b: CfgBuilder,
    loop_stack: std.ArrayList(LoopFrame),
    label_stack: std.ArrayList(LabelFrame),
    try_stack: std.ArrayList(TryFrame),
    reg_for_span: SpanKeyMap,
    reg_to_place: RegPlaceMap,
    pending_refinements: RefinementMap,
    span_to_pos: SpanPosMap,
    aliases: AliasMap,

    pub fn init(allocator: Allocator) Lowering {
        return .{
            .allocator = allocator,
            .b = CfgBuilder.init(),
            .loop_stack = .empty,
            .label_stack = .empty,
            .try_stack = .empty,
            .reg_for_span = SpanKeyMap.init(allocator),
            .reg_to_place = RegPlaceMap.init(allocator),
            .pending_refinements = RefinementMap.init(allocator),
            .span_to_pos = SpanPosMap.init(allocator),
            .aliases = AliasMap.init(allocator),
        };
    }

    /// Lower a function body. The CFG has one entry block and one
    /// synthetic exit block; every `return` jumps to the exit. The
    /// implicit fall-off-the-end of a `Unit`-typed body is wired to
    /// the exit by an explicit `Goto`.
    pub fn lowerFunction(self: *Lowering, body: *const Block, source: Span) Allocator.Error!Lowered {
        const a = self.allocator;
        const entry = try self.b.newBlock(a);
        const exit = try self.b.newBlock(a);
        var cur = entry;
        // Establish a synthetic "function" label so `return` (no label)
        // can jump to `exit` without a separate codepath.
        try self.label_stack.append(a, .{
            .name = "<fn>",
            .target = exit,
            .result = null,
        });
        _ = try self.lowerBlock(body, &cur);
        try self.b.setTerminator(a, cur, .{ .Goto = exit });
        try self.b.setTerminator(a, exit, .{ .Return = null });
        var exits: std.ArrayList(BlockId) = .empty;
        try exits.append(a, exit);
        const cfg = self.b.finish(a, entry, exits, source);

        self.loop_stack.deinit(a);
        self.label_stack.deinit(a);
        self.try_stack.deinit(a);
        self.pending_refinements.deinit();

        return .{
            .cfg = cfg,
            .reg_for_span = self.reg_for_span,
            .reg_to_place = self.reg_to_place,
            .span_to_pos = self.span_to_pos,
            .aliases = self.aliases,
        };
    }

    /// Emit the `AssumeIs` / `AssumeNull` nodes implied by a
    /// refinement onto `blk`. `truth` is the polarity to interpret
    /// the refinement under: `true` for the then-arm, `false` for
    /// the else-arm.
    fn emitRefinement(self: *Lowering, blk: BlockId, refinement: *const Refinement, truth: bool) Allocator.Error!void {
        const a = self.allocator;
        switch (refinement.*) {
            .Is => |r| {
                const effective = r.polarity == truth;
                try self.b.push(a, blk, .{ .AssumeIs = .{
                    .reg = r.reg,
                    .ty = try r.ty.clone(a),
                    .class_name = if (r.class_name) |cn| try a.dupe(u8, cn) else null,
                    .polarity = effective,
                    .span = r.span,
                } });
            },
            .NullEq => |r| {
                // `x == null` true on then; the refinement is "x == null".
                // Truth=true keeps eq_null; truth=false flips it.
                const effective = r.eq_null == truth;
                try self.b.push(a, blk, .{ .AssumeNull = .{
                    .reg = r.reg,
                    .eq_null = effective,
                    .span = r.span,
                } });
            },
            .RefEq => |r| {
                try self.b.push(a, blk, .{ .AssumeRefEq = .{
                    .reg_a = r.reg_a,
                    .reg_b = r.reg_b,
                    .polarity = truth,
                    .span = r.span,
                } });
            },
            .Not => |inner| try self.emitRefinement(blk, inner, !truth),
            .And => |parts| {
                if (truth) {
                    for (parts) |*p| {
                        try self.emitRefinement(blk, p, true);
                    }
                }
                // On the false arm of `a && b`, neither part is
                // individually known — we drop refinements.
            },
            .Or => |parts| {
                if (!truth) {
                    for (parts) |*p| {
                        try self.emitRefinement(blk, p, false);
                    }
                }
                // On the true arm of `a || b`, neither part is
                // individually known — we drop refinements.
            },
        }
    }

    fn lowerBlock(self: *Lowering, block: *const Block, cur: *BlockId) Allocator.Error!?Reg {
        var last: ?Reg = null;
        for (block.stmts) |*stmt| {
            last = try self.lowerStmt(stmt, cur);
        }
        return last;
    }

    fn lowerStmt(self: *Lowering, stmt: *const ast.Stmt, cur: *BlockId) Allocator.Error!?Reg {
        const a = self.allocator;
        switch (stmt.*) {
            .Expr => |*e| return try self.lowerExpr(e, cur),
            .Decl => |d| switch (d) {
                .Property => |p| {
                    const sp = p.name.span;
                    try self.b.push(a, cur.*, .{ .DeclLocal = .{
                        .place = .{ .name = try a.dupe(u8, p.name.name) },
                        .declared_ty = .Unresolved,
                        .span = sp,
                    } });
                    if (p.init) |init_expr| {
                        const r = try self.lowerExpr(&init_expr, cur);
                        // Bound smart casts: when an immutable local
                        // binds to a place expression (another local or
                        // a member chain) we record the aliasing so
                        // smart-cast lookups for the new name can follow
                        // the chain.
                        if (!p.mutable) {
                            if (try exprToPlace(a, &init_expr)) |src| {
                                try self.aliases.put(
                                    .{ .name = try a.dupe(u8, p.name.name) },
                                    src,
                                );
                            }
                        }
                        try self.b.push(a, cur.*, .{ .Assign = .{
                            .lhs = .{ .Local = .{ .name = try a.dupe(u8, p.name.name) } },
                            .rhs = r,
                            .span = sp,
                        } });
                    }
                    return null;
                },
                else => return null,
            },
            .Assign => |asn| {
                const rhs = try self.lowerExpr(&asn.value, cur);
                const lhs_place = try exprToPlace(a, &asn.target);
                const place = lhs_place orelse Place{ .Local = .{ .name = try a.dupe(u8, "<expr>") } };
                // Record both the assignment span and the LHS target's
                // span as pointing at the position right before the
                // Assign node executes. The typechecker queries this for
                // the val-first-write check.
                const pos = self.b.currentNodeCount(cur.*) orelse 0;
                try self.span_to_pos.put(.{ .start = asn.span.start, .end = asn.span.end }, .{ .block = cur.*, .node_idx = pos });
                const lhs_span = asn.target.span();
                try self.span_to_pos.put(.{ .start = lhs_span.start, .end = lhs_span.end }, .{ .block = cur.*, .node_idx = pos });
                try self.b.push(a, cur.*, .{ .Assign = .{
                    .lhs = place,
                    .rhs = rhs,
                    .span = asn.span,
                } });
                return null;
            },
            .DestructuringDecl => |dd| {
                const r = try self.lowerExpr(&dd.init, cur);
                for (dd.names) |n| {
                    if (std.mem.eql(u8, n.name, "_")) {
                        continue;
                    }
                    try self.b.push(a, cur.*, .{ .DeclLocal = .{
                        .place = .{ .name = try a.dupe(u8, n.name) },
                        .declared_ty = .Unresolved,
                        .span = dd.span,
                    } });
                    try self.b.push(a, cur.*, .{ .Assign = .{
                        .lhs = .{ .Local = .{ .name = try a.dupe(u8, n.name) } },
                        .rhs = r,
                        .span = dd.span,
                    } });
                }
                return null;
            },
        }
    }

    fn freshDeadBlock(self: *Lowering) Allocator.Error!BlockId {
        // Default terminator is Unreachable; that's exactly what we want.
        return try self.b.newBlock(self.allocator);
    }

    fn recordReg(self: *Lowering, sp: Span, reg: Reg) Allocator.Error!Reg {
        try self.reg_for_span.put(.{ .start = sp.start, .end = sp.end }, reg);
        return reg;
    }

    fn emitEval(self: *Lowering, cur: BlockId, sp: Span) Allocator.Error!Reg {
        const a = self.allocator;
        const reg = self.b.newReg();
        // Capture the position the eval lands at *before* pushing it so
        // smart-cast queries can read the in-state just before the
        // expression evaluates — that's the semantic the checker
        // historically needed.
        const pos = self.b.currentNodeCount(cur).?;
        try self.span_to_pos.put(.{ .start = sp.start, .end = sp.end }, .{ .block = cur, .node_idx = pos });
        try self.b.push(a, cur, .{ .Eval = .{
            .reg = reg,
            .expr = .{ .span = sp, .ty = .Unresolved },
        } });
        return try self.recordReg(sp, reg);
    }

    // single dispatch over every Expr variant; arms are grouped by lowering category
    fn lowerExpr(self: *Lowering, expr: *const Expr, cur: *BlockId) Allocator.Error!Reg {
        const a = self.allocator;
        switch (expr.*) {
            .IntLit => |e| return try self.emitEval(cur.*, e.span),
            .FloatLit => |e| return try self.emitEval(cur.*, e.span),
            .BoolLit => |e| return try self.emitEval(cur.*, e.span),
            .NullLit => |e| return try self.emitEval(cur.*, e.span),
            .CharLit => |e| return try self.emitEval(cur.*, e.span),

            .StringTemplate => |e| {
                for (e.parts) |*p| {
                    if (p.* == .Interp) {
                        _ = try self.lowerExpr(&p.Interp, cur);
                    }
                }
                return try self.emitEval(cur.*, e.span);
            },

            .Path => |e| {
                const reg = try self.emitEval(cur.*, e.span);
                if (try exprToPlace(a, expr)) |place| {
                    try self.reg_to_place.put(reg, place);
                }
                return reg;
            },
            .This => |e| {
                const reg = try self.emitEval(cur.*, e.span);
                if (try exprToPlace(a, expr)) |place| {
                    try self.reg_to_place.put(reg, place);
                }
                return reg;
            },
            .Super => |e| {
                const reg = try self.emitEval(cur.*, e.span);
                if (try exprToPlace(a, expr)) |place| {
                    try self.reg_to_place.put(reg, place);
                }
                return reg;
            },
            .PropertyRef => |e| {
                const reg = try self.emitEval(cur.*, e.span);
                if (try exprToPlace(a, expr)) |place| {
                    try self.reg_to_place.put(reg, place);
                }
                return reg;
            },

            .Member => |e| {
                _ = try self.lowerExpr(e.receiver, cur);
                const reg = try self.emitEval(cur.*, e.span);
                if (try exprToPlace(a, expr)) |place| {
                    try self.reg_to_place.put(reg, place);
                }
                return reg;
            },
            .MemberRef => |e| {
                _ = try self.lowerExpr(e.receiver, cur);
                return try self.emitEval(cur.*, e.span);
            },

            .Call => |e| {
                // callsInPlace(EXACTLY_ONCE): if the callee is one of
                // the stdlib scope functions and the last argument is a
                // lambda literal, inline the lambda body into the current
                // block before any contract effects so subsequent
                // statements see the body's assignments and narrowings.
                const exactly_once = lambdaCallsInPlace(e.callee, e.args);
                var arg_regs: std.ArrayList(Reg) = .empty;
                defer arg_regs.deinit(a);
                _ = try self.lowerExpr(e.callee, cur);
                if (exactly_once) {
                    // Lower all non-lambda args normally; the trailing
                    // lambda body is inlined directly into `cur`.
                    const lambda_idx = e.args.len - 1;
                    for (e.args, 0..) |*arg, i| {
                        if (i == lambda_idx) break;
                        try arg_regs.append(a, try self.lowerExpr(arg, cur));
                    }
                    if (e.args[lambda_idx] == .Lambda) {
                        _ = try self.lowerBlock(&e.args[lambda_idx].Lambda.body, cur);
                    }
                    const result = try self.emitEval(cur.*, e.span);
                    try self.applyContractEffects(e.callee, arg_regs.items, e.args, cur.*, e.span);
                    return result;
                } else {
                    for (e.args) |*arg| {
                        try arg_regs.append(a, try self.lowerExpr(arg, cur));
                    }
                    const result = try self.emitEval(cur.*, e.span);
                    try self.applyContractEffects(e.callee, arg_regs.items, e.args, cur.*, e.span);
                    return result;
                }
            },
            .Index => |e| {
                _ = try self.lowerExpr(e.receiver, cur);
                for (e.args) |*arg| {
                    _ = try self.lowerExpr(arg, cur);
                }
                return try self.emitEval(cur.*, e.span);
            },
            .Spread => |e| {
                _ = try self.lowerExpr(e.expr, cur);
                return try self.emitEval(cur.*, e.span);
            },

            .Binary => |e| return try self.lowerBinary(e.op, e.lhs, e.rhs, e.span, cur),

            .Unary => |e| {
                const inner = try self.lowerExpr(e.expr, cur);
                if ((e.op == .PreInc or e.op == .PreDec)) {
                    if (try exprToPlace(a, e.expr)) |place| {
                        try self.b.push(a, cur.*, .{ .Assign = .{
                            .lhs = place,
                            .rhs = inner,
                            .span = e.span,
                        } });
                    }
                }
                const result = try self.emitEval(cur.*, e.span);
                if (e.op == .Not) {
                    if (self.pending_refinements.get(inner)) |r| {
                        const cloned = try r.clone(a);
                        const boxed = try a.create(Refinement);
                        boxed.* = cloned;
                        try self.pending_refinements.put(result, .{ .Not = boxed });
                    }
                }
                return result;
            },

            .Postfix => |e| switch (e.op) {
                .Inc, .Dec => {
                    const r = try self.lowerExpr(e.expr, cur);
                    if (try exprToPlace(a, e.expr)) |place| {
                        try self.b.push(a, cur.*, .{ .Assign = .{
                            .lhs = place,
                            .rhs = r,
                            .span = e.span,
                        } });
                    }
                    return try self.emitEval(cur.*, e.span);
                },
                .NotNull => {
                    const r = try self.lowerExpr(e.expr, cur);
                    try self.b.push(a, cur.*, .{ .AssumeNull = .{
                        .reg = r,
                        .eq_null = false,
                        .span = e.span,
                    } });
                    try self.b.push(a, cur.*, .{ .Assert = .{
                        .reg = r,
                        .span = e.span,
                    } });
                    return r;
                },
            },

            .If => |e| return try self.lowerIf(e.cond, e.then_branch, e.else_branch, e.span, cur),

            .When => |e| return try self.lowerWhen(e.subject, e.branches, e.span, cur),

            .While => |e| return try self.lowerWhile(e.cond, e.body, e.span, cur),
            .DoWhile => |e| return try self.lowerDoWhile(e.body, e.cond, e.span, cur),
            .For => |e| return try self.lowerFor(e.iter, e.body, e.span, cur),

            .Return => |e| {
                const r: ?Reg = if (e.value) |v| try self.lowerExpr(v, cur) else null;
                const target = self.returnTarget(if (e.label) |*l| l else null);
                if (r) |reg| {
                    self.labelSetResult(if (e.label) |*l| l else null, reg);
                }
                try self.b.setTerminator(a, cur.*, .{ .Goto = target });
                cur.* = try self.freshDeadBlock();
                return try self.emitEval(cur.*, e.span);
            },
            .Break => |e| {
                const target = self.breakTarget(if (e.label) |*l| l else null);
                try self.b.setTerminator(a, cur.*, .{ .Goto = target });
                cur.* = try self.freshDeadBlock();
                return try self.emitEval(cur.*, e.span);
            },
            .Continue => |e| {
                const target = self.continueTarget(if (e.label) |*l| l else null);
                try self.b.setTerminator(a, cur.*, .{ .Goto = target });
                cur.* = try self.freshDeadBlock();
                return try self.emitEval(cur.*, e.span);
            },
            .Throw => |e| {
                const r = try self.lowerExpr(e.value, cur);
                try self.routeThrow(cur.*, r);
                cur.* = try self.freshDeadBlock();
                return try self.emitEval(cur.*, e.span);
            },

            .Labeled => |e| {
                const target = try self.b.newBlock(a);
                const label_id = self.b.newLabel();
                try self.b.push(a, target, .{ .LabelMark = .{ .label = label_id } });
                try self.label_stack.append(a, .{
                    .name = e.label.name,
                    .target = target,
                    .result = null,
                });
                const r = try self.lowerExpr(e.expr, cur);
                try self.b.setTerminator(a, cur.*, .{ .Goto = target });
                const frame = self.label_stack.pop().?;
                cur.* = target;
                return frame.result orelse r;
            },

            .Block => |bk| {
                if (try self.lowerBlock(&bk, cur)) |r| {
                    return r;
                }
                return try self.emitEval(cur.*, bk.span);
            },

            .Try => |e| return try self.lowerTry(&e.body, e.catches, if (e.finally) |*f| f else null, e.span, cur),

            .Lambda => |e| return try self.emitEval(cur.*, e.span),
            .AnonFun => |e| return try self.emitEval(cur.*, e.span),
            .ObjectExpr => |e| return try self.emitEval(cur.*, e.span),

            .IsCheck => |e| {
                const r = try self.lowerExpr(e.expr, cur);
                const result = self.b.newReg();
                try self.b.push(a, cur.*, .{ .Eval = .{
                    .reg = result,
                    .expr = .{ .span = e.span, .ty = .Boolean },
                } });
                const ty_t = try types.convertTypeRefLossy(a, &e.ty);
                const class_name: ?[]const u8 = if (types.builtinByName(e.ty.name.name) == null)
                    try a.dupe(u8, e.ty.name.name)
                else
                    null;
                try self.pending_refinements.put(result, .{ .Is = .{
                    .reg = r,
                    .ty = ty_t,
                    .class_name = class_name,
                    .polarity = !e.negated,
                    .span = e.span,
                } });
                return try self.recordReg(e.span, result);
            },
            .As => |e| {
                const r = try self.lowerExpr(e.expr, cur);
                const ty_t = try types.convertTypeRefLossy(a, &e.ty);
                const class_name: ?[]const u8 = if (types.builtinByName(e.ty.name.name) == null)
                    try a.dupe(u8, e.ty.name.name)
                else
                    null;
                if (!e.safe) {
                    try self.b.push(a, cur.*, .{ .AssumeIs = .{
                        .reg = r,
                        .ty = ty_t,
                        .class_name = class_name,
                        .polarity = true,
                        .span = e.span,
                    } });
                    try self.b.push(a, cur.*, .{ .Assert = .{
                        .reg = r,
                        .span = e.span,
                    } });
                }
                return try self.emitEval(cur.*, e.span);
            },
        }
    }

    fn lowerBinary(
        self: *Lowering,
        op: BinOp,
        lhs: *const Expr,
        rhs: *const Expr,
        sp: Span,
        cur: *BlockId,
    ) Allocator.Error!Reg {
        switch (op) {
            .And => return try self.lowerShortCircuit(lhs, rhs, sp, cur, true),
            .Or => return try self.lowerShortCircuit(lhs, rhs, sp, cur, false),
            .Elvis => return try self.lowerElvis(lhs, rhs, sp, cur),
            .Eq, .Neq, .IdentEq, .IdentNeq => {
                const a = self.allocator;
                const l = try self.lowerExpr(lhs, cur);
                const r = try self.lowerExpr(rhs, cur);
                const result = try self.emitEval(cur.*, sp);
                const eq_op = (op == .Eq or op == .IdentEq);
                if (isNullLit(rhs)) {
                    try self.pending_refinements.put(result, .{ .NullEq = .{
                        .reg = l,
                        .span = sp,
                        .eq_null = eq_op,
                    } });
                } else if (isNullLit(lhs)) {
                    try self.pending_refinements.put(result, .{ .NullEq = .{
                        .reg = r,
                        .span = sp,
                        .eq_null = eq_op,
                    } });
                } else if (self.reg_to_place.contains(l) and self.reg_to_place.contains(r)) {
                    // Cross-variable reference equality on two place
                    // expressions. Negation flips at branch emission time
                    // via `emitRefinement(truth=...)`.
                    const refinement: Refinement = .{ .RefEq = .{
                        .reg_a = l,
                        .reg_b = r,
                        .span = sp,
                    } };
                    const wrapped: Refinement = if (eq_op) refinement else blk: {
                        const p = try a.create(Refinement);
                        p.* = refinement;
                        break :blk .{ .Not = p };
                    };
                    try self.pending_refinements.put(result, wrapped);
                }
                return result;
            },
            else => {
                _ = try self.lowerExpr(lhs, cur);
                _ = try self.lowerExpr(rhs, cur);
                return try self.emitEval(cur.*, sp);
            },
        }
    }

    /// `a && b` => evaluate `a`; if true, evaluate `b`; result is the
    /// boolean of the joined block. `a || b` is symmetric.
    fn lowerShortCircuit(
        self: *Lowering,
        lhs: *const Expr,
        rhs: *const Expr,
        sp: Span,
        cur: *BlockId,
        short_on_false: bool,
    ) Allocator.Error!Reg {
        const a = self.allocator;
        const l = try self.lowerExpr(lhs, cur);
        const lhs_refinement: ?Refinement = if (self.pending_refinements.get(l)) |r| try r.clone(a) else null;
        const rhs_blk = try self.b.newBlock(a);
        const join = try self.b.newBlock(a);
        const then_blk: BlockId = if (short_on_false) rhs_blk else join;
        const else_blk: BlockId = if (short_on_false) join else rhs_blk;
        try self.b.setTerminator(a, cur.*, .{ .Branch = .{
            .cond = l,
            .then_blk = then_blk,
            .else_blk = else_blk,
        } });
        try self.b.push(a, rhs_blk, .{ .Assume = .{
            .reg = l,
            .polarity = short_on_false,
        } });
        if (lhs_refinement) |*r| {
            // On the rhs-eval block, lhs's truth-polarity matches
            // `short_on_false` (for `&&` we evaluate rhs when lhs is
            // true; for `||` when lhs is false).
            try self.emitRefinement(rhs_blk, r, short_on_false);
        }
        var rhs_cur = rhs_blk;
        const r_reg = try self.lowerExpr(rhs, &rhs_cur);
        const rhs_refinement: ?Refinement = if (self.pending_refinements.get(r_reg)) |r| try r.clone(a) else null;
        try self.b.setTerminator(a, rhs_cur, .{ .Goto = join });
        try self.b.push(a, join, .{ .Assume = .{
            .reg = l,
            .polarity = !short_on_false,
        } });
        const combined: ?Refinement = blk: {
            if (lhs_refinement) |la| {
                if (rhs_refinement) |rb| {
                    const parts = try a.alloc(Refinement, 2);
                    parts[0] = la;
                    parts[1] = rb;
                    break :blk if (short_on_false)
                        Refinement{ .And = parts }
                    else
                        Refinement{ .Or = parts };
                }
                break :blk la;
            }
            if (rhs_refinement) |rb| break :blk rb;
            break :blk null;
        };
        cur.* = join;
        const result = try self.emitEval(cur.*, sp);
        if (combined) |r| {
            try self.pending_refinements.put(result, r);
        }
        return result;
    }

    /// `a ?: b` => evaluate `a`; if non-null, that's the result; if
    /// null, evaluate `b`. Lowered as a null-check branch.
    fn lowerElvis(self: *Lowering, lhs: *const Expr, rhs: *const Expr, sp: Span, cur: *BlockId) Allocator.Error!Reg {
        const a = self.allocator;
        const l = try self.lowerExpr(lhs, cur);
        const null_blk = try self.b.newBlock(a);
        const nonnull_blk = try self.b.newBlock(a);
        const join = try self.b.newBlock(a);
        try self.b.setTerminator(a, cur.*, .{ .Branch = .{
            .cond = l,
            .then_blk = nonnull_blk,
            .else_blk = null_blk,
        } });
        try self.b.push(a, null_blk, .{ .AssumeNull = .{
            .reg = l,
            .eq_null = true,
            .span = sp,
        } });
        var null_cur = null_blk;
        _ = try self.lowerExpr(rhs, &null_cur);
        try self.b.setTerminator(a, null_cur, .{ .Goto = join });
        try self.b.push(a, nonnull_blk, .{ .AssumeNull = .{
            .reg = l,
            .eq_null = false,
            .span = sp,
        } });
        try self.b.setTerminator(a, nonnull_blk, .{ .Goto = join });
        cur.* = join;
        return try self.emitEval(cur.*, sp);
    }

    fn lowerIf(
        self: *Lowering,
        cond: *const Expr,
        then_branch: *const Expr,
        else_branch: ?*const Expr,
        sp: Span,
        cur: *BlockId,
    ) Allocator.Error!Reg {
        const a = self.allocator;
        const c = try self.lowerExpr(cond, cur);
        const refinement: ?Refinement = if (self.pending_refinements.get(c)) |r| try r.clone(a) else null;
        const then_blk = try self.b.newBlock(a);
        const else_blk = try self.b.newBlock(a);
        const join = try self.b.newBlock(a);
        try self.b.setTerminator(a, cur.*, .{ .Branch = .{
            .cond = c,
            .then_blk = then_blk,
            .else_blk = else_blk,
        } });

        try self.b.push(a, then_blk, .{ .Assume = .{
            .reg = c,
            .polarity = true,
        } });
        if (refinement) |*r| {
            try self.emitRefinement(then_blk, r, true);
        }
        var then_cur = then_blk;
        _ = try self.lowerExpr(then_branch, &then_cur);
        try self.b.setTerminator(a, then_cur, .{ .Goto = join });

        try self.b.push(a, else_blk, .{ .Assume = .{
            .reg = c,
            .polarity = false,
        } });
        if (refinement) |*r| {
            try self.emitRefinement(else_blk, r, false);
        }
        var else_cur = else_blk;
        if (else_branch) |e| {
            _ = try self.lowerExpr(e, &else_cur);
        }
        try self.b.setTerminator(a, else_cur, .{ .Goto = join });

        cur.* = join;
        return try self.emitEval(cur.*, sp);
    }

    fn lowerWhen(
        self: *Lowering,
        subject: ?*const Expr,
        branches: []const WhenBranch,
        sp: Span,
        cur: *BlockId,
    ) Allocator.Error!Reg {
        const a = self.allocator;
        const subj_reg: ?Reg = if (subject) |s| try self.lowerExpr(s, cur) else null;
        const join = try self.b.newBlock(a);

        var next = try self.b.newBlock(a);
        try self.b.setTerminator(a, cur.*, .{ .Goto = next });

        for (branches) |*branch| {
            const arm_body = try self.b.newBlock(a);
            const fall = try self.b.newBlock(a);
            for (branch.patterns, 0..) |*pat, i| {
                const last = i + 1 == branch.patterns.len;
                const try_next: BlockId = if (last) fall else try self.b.newBlock(a);
                try self.lowerWhenPattern(&pat.kind, subj_reg, next, arm_body, try_next);
                next = try_next;
            }
            var arm_cur = arm_body;
            _ = try self.lowerExpr(&branch.body, &arm_cur);
            try self.b.setTerminator(a, arm_cur, .{ .Goto = join });
            next = fall;
        }
        // No-arm-matched fallthrough flows to the join; a subject-bound
        // `when` without `else` throws at runtime — that detail is
        // handled by the typechecker/interpreter, not CFG.
        try self.b.setTerminator(a, next, .{ .Goto = join });
        cur.* = join;
        return try self.emitEval(cur.*, sp);
    }

    /// Lower a single `when` pattern: evaluate it against `subj` if
    /// `subj` is set else as a boolean condition; on match branch to
    /// `match_blk`, on miss branch to `miss_blk`.
    fn lowerWhenPattern(
        self: *Lowering,
        kind: *const WhenPatternKind,
        subj: ?Reg,
        before: BlockId,
        match_blk: BlockId,
        miss_blk: BlockId,
    ) Allocator.Error!void {
        const a = self.allocator;
        var cur = before;
        switch (kind.*) {
            .Value => |e| {
                const v = try self.lowerExpr(&e, &cur);
                if (subj) |s| {
                    const cmp = self.b.newReg();
                    try self.b.push(a, cur, .{ .Eval = .{
                        .reg = cmp,
                        .expr = .{ .span = e.span(), .ty = .Boolean },
                    } });
                    _ = s;
                    try self.b.setTerminator(a, cur, .{ .Branch = .{
                        .cond = cmp,
                        .then_blk = match_blk,
                        .else_blk = miss_blk,
                    } });
                } else {
                    try self.b.setTerminator(a, cur, .{ .Branch = .{
                        .cond = v,
                        .then_blk = match_blk,
                        .else_blk = miss_blk,
                    } });
                }
            },
            .InRange, .NotInRange => {
                const e = switch (kind.*) {
                    .InRange => |x| x,
                    .NotInRange => |x| x,
                    else => unreachable,
                };
                _ = try self.lowerExpr(&e, &cur);
                const cmp = self.b.newReg();
                try self.b.push(a, cur, .{ .Eval = .{
                    .reg = cmp,
                    .expr = .{ .span = e.span(), .ty = .Boolean },
                } });
                try self.b.setTerminator(a, cur, .{ .Branch = .{
                    .cond = cmp,
                    .then_blk = match_blk,
                    .else_blk = miss_blk,
                } });
            },
            .IsType, .NotIsType => {
                const negated = (kind.* == .NotIsType);
                const polarity = !negated;
                const ty = switch (kind.*) {
                    .IsType => |x| x,
                    .NotIsType => |x| x,
                    else => unreachable,
                };
                const cmp = self.b.newReg();
                const ty_t = try types.convertTypeRefLossy(a, &ty);
                const class_name: ?[]const u8 = if (types.builtinByName(ty.name.name) == null)
                    try a.dupe(u8, ty.name.name)
                else
                    null;
                if (subj) |s| {
                    try self.b.push(a, cur, .{ .AssumeIs = .{
                        .reg = s,
                        .ty = try ty_t.clone(a),
                        .class_name = class_name,
                        .polarity = polarity,
                        .span = ty.span,
                    } });
                    try self.b.push(a, cur, .{ .Eval = .{
                        .reg = cmp,
                        .expr = .{ .span = ty.span, .ty = .Boolean },
                    } });
                    const arms = try a.alloc(SwitchArm, 1);
                    arms[0] = .{
                        .pattern = .{ .Is = .{ .ty = ty_t, .polarity = polarity } },
                        .target = match_blk,
                    };
                    try self.b.setTerminator(a, cur, .{ .Switch = .{
                        .reg = s,
                        .arms = arms,
                        .default = miss_blk,
                    } });
                } else {
                    try self.b.setTerminator(a, cur, .{ .Branch = .{
                        .cond = cmp,
                        .then_blk = match_blk,
                        .else_blk = miss_blk,
                    } });
                }
            },
            .Else => {
                try self.b.setTerminator(a, cur, .{ .Goto = match_blk });
            },
        }
    }

    fn lowerWhile(self: *Lowering, cond: *const Expr, body: *const Expr, sp: Span, cur: *BlockId) Allocator.Error!Reg {
        const a = self.allocator;
        const head = try self.b.newBlock(a);
        const body_blk = try self.b.newBlock(a);
        const exit = try self.b.newBlock(a);
        const lid = self.b.newLoop();

        try self.b.setTerminator(a, cur.*, .{ .Goto = head });

        const c = blk: {
            var head_cur = head;
            const r = try self.lowerExpr(cond, &head_cur);
            try self.b.setTerminator(a, head_cur, .{ .Branch = .{
                .cond = r,
                .then_blk = body_blk,
                .else_blk = exit,
            } });
            break :blk r;
        };

        try self.b.push(a, body_blk, .{ .Assume = .{
            .reg = c,
            .polarity = true,
        } });
        try self.loop_stack.append(a, .{
            .id = lid,
            .cont_target = head,
            .break_target = exit,
            .label = null,
        });
        var body_cur = body_blk;
        _ = try self.lowerExpr(body, &body_cur);
        try self.b.push(a, body_cur, .{ .Backedge = .{ .loop_id = lid } });
        try self.b.setTerminator(a, body_cur, .{ .Goto = head });
        _ = self.loop_stack.pop();

        try self.b.push(a, exit, .{ .Assume = .{
            .reg = c,
            .polarity = false,
        } });
        cur.* = exit;
        return try self.emitEval(cur.*, sp);
    }

    fn lowerDoWhile(
        self: *Lowering,
        body: ?*const Expr,
        cond: *const Expr,
        sp: Span,
        cur: *BlockId,
    ) Allocator.Error!Reg {
        const a = self.allocator;
        const head = try self.b.newBlock(a);
        const cond_blk = try self.b.newBlock(a);
        const exit = try self.b.newBlock(a);
        const lid = self.b.newLoop();

        try self.b.setTerminator(a, cur.*, .{ .Goto = head });
        try self.loop_stack.append(a, .{
            .id = lid,
            .cont_target = cond_blk,
            .break_target = exit,
            .label = null,
        });
        var head_cur = head;
        if (body) |bd| {
            _ = try self.lowerExpr(bd, &head_cur);
        }
        try self.b.setTerminator(a, head_cur, .{ .Goto = cond_blk });
        _ = self.loop_stack.pop();

        var cond_cur = cond_blk;
        const r = try self.lowerExpr(cond, &cond_cur);
        try self.b.push(a, cond_cur, .{ .Backedge = .{ .loop_id = lid } });
        try self.b.setTerminator(a, cond_cur, .{ .Branch = .{
            .cond = r,
            .then_blk = head,
            .else_blk = exit,
        } });

        try self.b.push(a, exit, .{ .Assume = .{
            .reg = r,
            .polarity = false,
        } });
        cur.* = exit;
        return try self.emitEval(cur.*, sp);
    }

    fn lowerFor(self: *Lowering, iter: *const Expr, body: *const Expr, sp: Span, cur: *BlockId) Allocator.Error!Reg {
        // `for (x in xs) body` desugars to an iterator while loop. The
        // lowering here is conservative — we evaluate `xs`, then loop
        // body up to an indeterminate count. Reachability and
        // killDataFlow only need a backedge and the standard loop shape.
        const a = self.allocator;
        _ = try self.lowerExpr(iter, cur);
        const head = try self.b.newBlock(a);
        const body_blk = try self.b.newBlock(a);
        const exit = try self.b.newBlock(a);
        const lid = self.b.newLoop();
        try self.b.setTerminator(a, cur.*, .{ .Goto = head });
        const cond = self.b.newReg();
        try self.b.push(a, head, .{ .Eval = .{
            .reg = cond,
            .expr = .{ .span = sp, .ty = .Boolean },
        } });
        try self.b.setTerminator(a, head, .{ .Branch = .{
            .cond = cond,
            .then_blk = body_blk,
            .else_blk = exit,
        } });
        try self.loop_stack.append(a, .{
            .id = lid,
            .cont_target = head,
            .break_target = exit,
            .label = null,
        });
        var body_cur = body_blk;
        _ = try self.lowerExpr(body, &body_cur);
        try self.b.push(a, body_cur, .{ .Backedge = .{ .loop_id = lid } });
        try self.b.setTerminator(a, body_cur, .{ .Goto = head });
        _ = self.loop_stack.pop();
        cur.* = exit;
        return try self.emitEval(cur.*, sp);
    }

    fn lowerTry(
        self: *Lowering,
        body: *const Block,
        catches: []const Catch,
        finally: ?*const Block,
        sp: Span,
        cur: *BlockId,
    ) Allocator.Error!Reg {
        const a = self.allocator;
        const handlers_entry = try a.alloc(Handler, catches.len);
        for (catches, handlers_entry) |*c, *h| {
            const blk = try self.b.newBlock(a);
            h.* = .{ .ty = try types.convertTypeRefLossy(a, &c.ty), .block = blk };
        }

        const join = try self.b.newBlock(a);
        const finally_entry_blk: ?BlockId = if (finally != null) try self.b.newBlock(a) else null;
        const normal_finally_blk: ?BlockId = if (finally != null) try self.b.newBlock(a) else null;

        try self.try_stack.append(a, .{
            .handlers = handlers_entry,
            .finally_entry = finally_entry_blk,
        });

        // Body
        const body_blk = try self.b.newBlock(a);
        try self.b.setTerminator(a, cur.*, .{ .Goto = body_blk });
        var body_cur = body_blk;
        _ = try self.lowerBlock(body, &body_cur);
        const body_exit_to = normal_finally_blk orelse join;
        try self.b.setTerminator(a, body_cur, .{ .Goto = body_exit_to });
        // Exception edges from the body to each handler.
        for (handlers_entry) |h| {
            try self.b.addEdge(a, body_blk, h.block, .{ .Exception = .{ .ty = if (h.ty) |t| try t.clone(a) else null } });
        }

        // Handlers: each catch body lowers like a block; its normal exit
        // flows into the finally (if any) and then to the join.
        for (catches, handlers_entry) |*c, h| {
            var h_cur = h.block;
            _ = try self.lowerBlock(&c.body, &h_cur);
            const h_exit_to = normal_finally_blk orelse join;
            try self.b.setTerminator(a, h_cur, .{ .Goto = h_exit_to });
        }

        _ = self.try_stack.pop();

        // Finally has two copies: one for the normal exit and one
        // (currently shared) for each exception path. The normal-exit
        // copy is emitted explicitly; the exception-path copy lives at
        // `finally_entry_blk` and is reached from any uncaught throw via
        // the try-stack walk.
        if (finally != null and normal_finally_blk != null and finally_entry_blk != null) {
            const fin = finally.?;
            var nf_cur = normal_finally_blk.?;
            _ = try self.lowerBlock(fin, &nf_cur);
            try self.b.setTerminator(a, nf_cur, .{ .Goto = join });
            try self.b.addEdge(a, nf_cur, join, .FinallyExit);

            var tf_cur = finally_entry_blk.?;
            _ = try self.lowerBlock(fin, &tf_cur);
            // Exception-path finally re-throws into the enclosing try
            // (or, if none, leaves the function). For now we wire it to
            // `join` and let reachability prune it later when we have
            // type info.
            try self.b.setTerminator(a, tf_cur, .{ .Goto = join });
            try self.b.addEdge(a, tf_cur, join, .FinallyExit);
        }

        cur.* = join;
        return try self.emitEval(cur.*, sp);
    }

    fn routeThrow(self: *Lowering, from: BlockId, reg: Reg) Allocator.Error!void {
        // Wire the throw terminator on `from`; the topmost try frame's
        // handlers get exception edges.
        const a = self.allocator;
        try self.b.setTerminator(a, from, .{ .Throw = reg });
        if (self.try_stack.items.len != 0) {
            const frame = self.try_stack.items[self.try_stack.items.len - 1];
            for (frame.handlers) |h| {
                try self.b.addEdge(a, from, h.block, .{ .Exception = .{ .ty = if (h.ty) |t| try t.clone(a) else null } });
            }
            if (frame.finally_entry) |fe| {
                try self.b.addEdge(a, from, fe, .FinallyEntry);
            }
        }
    }

    fn returnTarget(self: *const Lowering, label: ?*const Ident) BlockId {
        if (label) |name| {
            var i = self.label_stack.items.len;
            while (i > 0) {
                i -= 1;
                const f = self.label_stack.items[i];
                if (std.mem.eql(u8, f.name, name.name)) return f.target;
            }
            return self.fnTarget();
        }
        return self.fnTarget();
    }

    fn fnTarget(self: *const Lowering) BlockId {
        // The function frame is always the bottom-most label frame.
        return self.label_stack.items[0].target;
    }

    fn breakTarget(self: *const Lowering, label: ?*const Ident) BlockId {
        if (label) |name| {
            var i = self.loop_stack.items.len;
            while (i > 0) {
                i -= 1;
                const f = self.loop_stack.items[i];
                if (f.label) |l| {
                    if (std.mem.eql(u8, l, name.name)) return f.break_target;
                }
            }
            return self.loop_stack.items[self.loop_stack.items.len - 1].break_target;
        }
        return self.loop_stack.items[self.loop_stack.items.len - 1].break_target;
    }

    fn continueTarget(self: *const Lowering, label: ?*const Ident) BlockId {
        if (label) |name| {
            var i = self.loop_stack.items.len;
            while (i > 0) {
                i -= 1;
                const f = self.loop_stack.items[i];
                if (f.label) |l| {
                    if (std.mem.eql(u8, l, name.name)) return f.cont_target;
                }
            }
            return self.loop_stack.items[self.loop_stack.items.len - 1].cont_target;
        }
        return self.loop_stack.items[self.loop_stack.items.len - 1].cont_target;
    }

    fn labelSetResult(self: *Lowering, label: ?*const Ident, reg: Reg) void {
        if (label) |name| {
            var i = self.label_stack.items.len;
            while (i > 0) {
                i -= 1;
                if (std.mem.eql(u8, self.label_stack.items[i].name, name.name)) {
                    self.label_stack.items[i].result = reg;
                    return;
                }
            }
        }
    }

    /// Apply contract effects to the post-call block. The effect
    /// catalogue lives in `contracts.stdlibContract`; the lowering just
    /// translates each `ContractEffect` into the corresponding `Assume*`
    /// node and replays any pending refinement on the predicate
    /// register.
    fn applyContractEffects(
        self: *Lowering,
        callee: *const Expr,
        arg_regs: []const Reg,
        args: []const Expr,
        cur: BlockId,
        sp: Span,
    ) Allocator.Error!void {
        const a = self.allocator;
        const name = simpleName(callee) orelse return;
        for (contracts.stdlibContract(name)) |effect| {
            switch (effect) {
                .AssumeNonNull => |e| {
                    if (e.arg_idx < arg_regs.len and e.arg_idx < args.len) {
                        try self.b.push(a, cur, .{ .AssumeNull = .{
                            .reg = arg_regs[e.arg_idx],
                            .eq_null = false,
                            .span = sp,
                        } });
                    }
                },
                .AssumePredicate => |e| {
                    if (e.arg_idx < arg_regs.len and e.arg_idx < args.len) {
                        const r = arg_regs[e.arg_idx];
                        try self.b.push(a, cur, .{ .Assume = .{
                            .reg = r,
                            .polarity = true,
                        } });
                        if (self.pending_refinements.get(r)) |refinement| {
                            const cloned = try refinement.clone(a);
                            try self.emitRefinement(cur, &cloned, true);
                        }
                    }
                },
            }
        }
    }
};

fn exprToPlace(allocator: Allocator, e: *const Expr) Allocator.Error!?Place {
    switch (e.*) {
        .Path => |p| {
            if (p.segments.len == 1) {
                return Place{ .Local = .{ .name = try allocator.dupe(u8, p.segments[0].name) } };
            }
            return null;
        },
        .Member => |m| {
            if (m.safe) return null;
            const inner = (try exprToPlace(allocator, m.receiver)) orelse return null;
            const recv = try allocator.create(Place);
            recv.* = inner;
            return Place{ .Field = .{
                .receiver = recv,
                .field = .{ .name = try allocator.dupe(u8, m.name.name) },
            } };
        },
        .This => return Place.This,
        else => return null,
    }
}

fn isNullLit(e: *const Expr) bool {
    return e.* == .NullLit;
}

fn simpleName(callee: *const Expr) ?[]const u8 {
    switch (callee.*) {
        .Path => |p| {
            if (p.segments.len == 1) return p.segments[0].name;
            return null;
        },
        else => return null,
    }
}

/// True when `callee` is a stdlib scope function whose contract invokes
/// the trailing lambda argument exactly once on the normal path. The
/// body's effects (assignments, narrowings, declarations) propagate to
/// the caller scope and the CFG should inline them so VIA and smart-cast
/// see them without crossing a lambda boundary.
fn lambdaCallsInPlace(callee: *const Expr, args: []const Expr) bool {
    if (args.len == 0) return false;
    const last = &args[args.len - 1];
    if (last.* != .Lambda) return false;
    switch (callee.*) {
        // `recv.let/run/apply/also { ... }` — member-form. `with` is
        // top-level but takes a receiver as a positional argument.
        .Member => |m| {
            if (m.safe) return false;
            const n = m.name.name;
            return std.mem.eql(u8, n, "let") or std.mem.eql(u8, n, "run") or
                std.mem.eql(u8, n, "apply") or std.mem.eql(u8, n, "also");
        },
        .Path => |p| {
            if (p.segments.len != 1) return false;
            const name = p.segments[0].name;
            // `run { ... }` / `with(x) { ... }` — top-level scope fns.
            if (std.mem.eql(u8, name, "run") or std.mem.eql(u8, name, "with")) {
                return true;
            }
            // User-declared `contract { callsInPlace(block,
            // EXACTLY_ONCE) }`: if the registry records the trailing-arg
            // position as exactly-once, treat the call like a scope
            // function so the lambda body's assignments / smart-casts
            // flow to the caller scope.
            const user_params = contracts.userExactlyOnceParams(name);
            return user_params.len != 0;
        },
        else => return false,
    }
}

/// Convenience entry point: lower a function body into a CFG.
pub fn lowerFunction(allocator: Allocator, body: *const Block, source: Span) Allocator.Error!Lowered {
    var lowering = Lowering.init(allocator);
    return lowering.lowerFunction(body, source);
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const Lexer = @import("lexer").Lexer;
const Parser = @import("parser").Parser;
const print = @import("print.zig");

/// Parse the first function in `src`, lower its body, and render the
/// CFG to text. Everything is allocated from `arena`.
fn lowerFirstFun(arena: Allocator, src: []const u8) ![]u8 {
    const file = span.FileId.from(0);
    var lexer = try Lexer.init(arena, file, src);
    const lexed = try lexer.tokenize();
    try std.testing.expect(!lexed.diagnostics.hasErrors());
    const parser = Parser.new(arena, file, src, lexed.tokens);
    const parsed = parser.parseFile();
    try std.testing.expect(!parser.diagnostics.hasErrors());

    var func: ?*const ast.Function = null;
    for (parsed.decls) |*d| {
        if (d.* == .Function) {
            func = &d.Function;
            break;
        }
    }
    const f = func orelse return error.NoFunction;
    const fbody = f.body orelse return error.NoBody;
    var body: Block = switch (fbody) {
        .Block => |bk| bk,
        .Expr => |e| blk: {
            const stmts = try arena.alloc(ast.Stmt, 1);
            stmts[0] = .{ .Expr = e };
            break :blk Block{ .stmts = stmts, .span = e.span() };
        },
    };

    var lowered = try lowerFunction(arena, &body, f.span);
    return try print.printCfg(arena, &lowered.cfg);
}

const expectContains = struct {
    fn f(haystack: []const u8, needle: []const u8) !void {
        if (std.mem.indexOf(u8, haystack, needle) == null) {
            std.debug.print("expected to find:\n  {s}\nin:\n{s}\n", .{ needle, haystack });
            return error.NotFound;
        }
    }
}.f;

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, i, needle)) |pos| {
        count += 1;
        i = pos + needle.len;
    }
    return count;
}

test "empty body lowers to entry goto exit, exit returns" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const s = try lowerFirstFun(a, "fun main() { }");
    try expectContains(s, "cfg: entry=b0");
    try expectContains(s, "goto b1");
    try expectContains(s, "term: return");
}

test "straight-line assignment emits decl and assign nodes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const s = try lowerFirstFun(a,
        \\fun main() {
        \\    val x = 1
        \\    val y = x + 2
        \\}
    );
    try expectContains(s, "decl x : Unresolved");
    try expectContains(s, "decl y : Unresolved");
    try expectContains(s, "assign x = r");
    try expectContains(s, "assign y = r");
}

test "if-else lowers to a branch with a join" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const s = try lowerFirstFun(a,
        \\fun main() {
        \\    val c = true
        \\    val x = if (c) 1 else 2
        \\}
    );
    try expectContains(s, "branch r");
    // the then-arm assumes the condition true, the else-arm false.
    try expectContains(s, "assume r");
    try expectContains(s, "assume !r");
}

test "short-circuit && lowers to a branch and assume nodes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const s = try lowerFirstFun(a,
        \\fun main() {
        \\    val a = true
        \\    val b = false
        \\    val c = a && b
        \\}
    );
    try expectContains(s, "branch r");
    try expectContains(s, "assume r");
}

test "elvis lowers to a null-check branch" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const s = try lowerFirstFun(a,
        \\fun main() {
        \\    val x: Int? = null
        \\    val y = x ?: 0
        \\}
    );
    try expectContains(s, "branch r");
    try expectContains(s, "== null");
    try expectContains(s, "!= null");
}

test "while loop emits a backedge and loop-shape blocks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const s = try lowerFirstFun(a,
        \\fun main() {
        \\    var i = 0
        \\    while (i < 10) {
        \\        i = i + 1
        \\    }
        \\}
    );
    try expectContains(s, "backedge l0");
    try expectContains(s, "branch r");
}

test "try-catch-finally emits exception and finally edges" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const s = try lowerFirstFun(a,
        \\fun main() {
        \\    try {
        \\        val x = 1
        \\    } catch (e: RuntimeException) {
        \\        val y = 2
        \\    } finally {
        \\        val z = 3
        \\    }
        \\}
    );
    try expectContains(s, "(throw");
    try expectContains(s, "finally-exit");
    try expectContains(s, "decl z : Unresolved");
}

test "subject-bound when with is emits a switch" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const s = try lowerFirstFun(a,
        \\fun main() {
        \\    val x: Any = 1
        \\    val r = when (x) {
        \\        is String -> 1
        \\        is Int -> 2
        \\        else -> 3
        \\    }
        \\}
    );
    try expectContains(s, "switch r");
    try expectContains(s, "is String");
}

test "return terminates the block via goto to exit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const s = try lowerFirstFun(a,
        \\fun main() {
        \\    val x = 1
        \\    return
        \\    val y = 2
        \\}
    );
    // exit block is b1; the return short-circuits to it.
    try expectContains(s, "goto b1");
    try expectContains(s, "term: return");
}

test "not-null assertion emits assume-non-null and assert" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const s = try lowerFirstFun(a,
        \\fun main() {
        \\    val x: Int? = 1
        \\    val y = x!! + 1
        \\}
    );
    try expectContains(s, "!= null");
    try expectContains(s, "assert r");
}

test "bound smart-cast records an alias for an immutable place binding" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const file = span.FileId.from(0);
    const src =
        \\fun main() {
        \\    val a = 1
        \\    val b = a
        \\}
    ;
    var lexer = try Lexer.init(a, file, src);
    const lexed = try lexer.tokenize();
    const parser = Parser.new(a, file, src, lexed.tokens);
    const parsed = parser.parseFile();
    var func: ?*const ast.Function = null;
    for (parsed.decls) |*d| {
        if (d.* == .Function) {
            func = &d.Function;
            break;
        }
    }
    const f = func.?;
    var body = f.body.?.Block;
    var lowered = try lowerFunction(a, &body, f.span);
    // `val b = a` aliases `b` to local `a`.
    const alias = lowered.aliases.get(.{ .name = "b" });
    try std.testing.expect(alias != null);
    try std.testing.expect(alias.? == .Local);
    try std.testing.expectEqualStrings("a", alias.?.Local.name);
}
