//! Values of function types: lambdas, anonymous functions, local functions
//! (lifted, their captures leading their parameters), lambdas lowered in
//! place for an inline call, and SAM wrapping.
//!
//! A literal is a `MakeClosure` over its function's id, holding the values
//! the bridge found it captures; a captured cell stays a cell, so the
//! closure and its creator share it. A local function is lowered on its
//! own, like any declaration, and every call passes its captures.

const std = @import("std");
const ast = @import("ast");
const sema = @import("sema");

const ir = @import("../../ir.zig");
const bridge = @import("../../core/bridge.zig");
const builder = @import("builder.zig");
const records = @import("records.zig");
const env = @import("env.zig");
const body = @import("body.zig");
const compose = @import("compose.zig");

const Builder = builder.Builder;
const Error = records.Error;
const LambdaRec = records.LambdaRec;
const Reg = ir.Reg;
const Sym = sema.Sym;

/// `MakeClosure` at the literal. A literal passed where a fun interface is
/// expected is wrapped by the call that converts it (`Conv.sam`), not
/// here.
pub fn lowerLambda(b: *Builder, e: *const ast.Expr) Error!Reg {
    return literalValue(b, e, try b.lambda(e.Lambda.id));
}

pub fn lowerAnonFun(b: *Builder, e: *const ast.Expr) Error!Reg {
    return literalValue(b, e, try b.lambda(e.AnonFun.id));
}

fn literalValue(b: *Builder, e: *const ast.Expr, rec: records.LambdaRec) Error!Reg {
    const s = b.p.s;
    const composable = bridge.composableType(s, rec.fn_type);
    // A composable literal returning `Unit` is remembered as the runtime's
    // composable lambda, which gives its content a recompose scope of its
    // own; any other literal in a composable scope is remembered over its
    // captures.
    if (composable and returnsUnit(s, rec.fn_type)) return compose.wrapLambda(b, try closureOf(b, rec.func), e.span(), rec.func);
    if (!composable and try compose.memoizes(b, e, rec.func)) return compose.memoizedClosure(b, rec.func);
    return closureOf(b, rec.func);
}

/// A closure over function `f` with the captures the bridge computed.
pub fn closureOf(b: *Builder, f: Sym) Error!Reg {
    const br = b.p.br;
    const s = b.p.s;
    const id = br.funcOfOpt(f) orelse return b.fail(b.cur_span, "`{s}` has no id", .{s.str(s.syms.name(f))});
    // A literal's body is lowered once a closure is made of it.
    try body.lowerClosure(b.p, id);
    const caps = try env.materializeCaptures(b, br.capturesOf(id));
    const dst = b.newReg();
    try b.emit(.{ .MakeClosure = .{ .dst = dst, .func = id, .captures = caps } });
    return dst;
}

/// A local function declaration emits nothing: the program lowers its body
/// on its own, and each call passes its captures.
pub fn lowerLocalFun(b: *Builder, d: *const ast.Decl) Error!void {
    _ = .{ b, d };
}

/// A lambda's, anonymous function's or local function's body, entered by
/// `env.enter`. A lambda's value is its last expression's, or `Unit` when
/// its function type returns `Unit`.
pub fn lowerClosureBody(b: *Builder, f: Sym) Error!void {
    const s = b.p.s;
    switch (s.syms.get(f).decl) {
        .lambda => |l| {
            const rec = try b.lambda(l.id);
            try checkParams(b, l);
            const unit_result = returnsUnit(s, rec.fn_type);
            if (bridge.composableType(s, rec.fn_type)) return compose.lowerLambdaBody(b, f, &rec, l.body.stmts, unit_result);
            const v = try body.lowerStmts(b, l.body.stmts);
            if (b.terminated()) return;
            b.terminate(.{ .Return = if (unit_result) try b.unit() else v orelse try b.unit() });
        },
        .anon_fun => |af| {
            const fb = af.body orelse {
                b.terminate(.{ .Return = try b.unit() });
                return;
            };
            try body.lowerFunctionBody(b, fb);
        },
        .function => |fd| {
            const fb = if (fd.body) |*x| x else return b.fail(fd.span, "local function `{s}` has no body", .{fd.name.name});
            if (compose.composableFunction(s, f)) return compose.lowerFunctionBody(b, f, fb);
            try body.lowerFunctionBody(b, fb);
        },
        else => return b.fail(b.cur_span, "a closure body whose symbol is no function literal", .{}),
    }
}

/// A destructured parameter `(a, b) ->` has no records to bind it by.
fn checkParams(b: *Builder, l: *const ast.LambdaExpr) Error!void {
    for (l.params) |p| {
        if (std.mem.startsWith(u8, p.name, "(")) return b.fail(p.span, "a destructured lambda parameter has no records", .{});
    }
}

/// Whether a function type's result is `Unit`.
fn returnsUnit(s: *sema.Sema, fn_type: sema.TypeId) bool {
    if (fn_type == .none) return false;
    const args = s.types.argsOf(fn_type);
    if (args.len == 0) return false;
    return args[args.len - 1].ty == s.t.unit;
}

/// Lowers a lambda literal's body into `b` at the current block (D), its
/// parameters bound to `args` in the function type's order (contexts,
/// receiver, parameters). A `return@label` inside leaves through the
/// region's end; the returned register holds the literal's value.
pub fn lowerInPlace(b: *Builder, literal: *const ast.Expr, args: []const Reg) Error!Reg {
    const s = b.p.s;
    const a = b.p.a;
    const lit = strip(literal);
    const id = lit.id();
    const rec = try b.lambda(id);
    var i: usize = 0;
    const need = rec.contexts.len + @intFromBool(rec.has_receiver) + (if (rec.it != .none) 1 else rec.params.len);
    if (args.len < need) return b.fail(lit.span(), "a literal lowered in place with {d} arguments for {d} parameters", .{ args.len, need });
    for (rec.contexts) |c| {
        try env.bindLocal(b, c, args[i]);
        try env.bindReceiver(b, .context, c, args[i]);
        i += 1;
    }
    if (rec.has_receiver) {
        try env.bindReceiver(b, if (lit.* == .Lambda) .lambda else .extension, rec.func, args[i]);
        i += 1;
    }
    if (rec.it != .none) {
        try env.bindLocal(b, rec.it, args[i]);
        i += 1;
    } else for (rec.params) |p| {
        if (p != .none) try env.bindLocal(b, p, args[i]);
        i += 1;
    }
    // A composable literal composes into the composer it was called with.
    const saved_composer = b.env.composer;
    const saved_changed = b.env.changed;
    const saved_block = b.compose_block;
    const saved_remember = b.compose_remember;
    const saved_lambda_groups = b.compose_lambda_groups;
    defer {
        b.env.composer = saved_composer;
        b.env.changed = saved_changed;
        b.compose_block = saved_block;
        b.compose_remember = saved_remember;
        b.compose_lambda_groups = saved_lambda_groups;
    }
    // A literal that may not compose remembers nothing.
    if (b.compose_disallowed.contains(lit)) b.compose_remember = false;
    // A literal an inline call takes groups whatever composes in it; when
    // the call takes several, the literal's body is a group of its own.
    const own_group = b.compose_lambda_groups and b.env.composer != null and compose.composes(b, lit);
    b.compose_lambda_groups = false;
    if (b.env.composer != null) b.compose_block = .{ .end = lit.span().end, .loop_body = true };
    if (bridge.composableType(s, rec.fn_type)) {
        const ints = bridge.lambdaChangedInts(i);
        if (args.len < i + 1 + ints) return b.fail(lit.span(), "a composable literal lowered in place without the composer", .{});
        b.env.composer = args[i];
        b.env.changed = args[i + 1 .. i + 1 + ints];
    }
    const result = b.newReg();
    const end = try b.newBlock();
    // The literal's own group is open to its returns, which end at its end.
    if (own_group) try compose.startReplaceGroup(b, lit.span());
    defer if (own_group) {
        b.compose_open -= 1;
    };
    const marker = try compose.markerFor(b, .{ .id = lit.id(), .sp = lit.span() }, rec.func);
    try b.regions.append(a, .{ .lambda = .{ .func = rec.func, .result = result, .end = end, .finally_depth = b.finallys.items.len, .compose_open = b.compose_open, .marker = marker } });
    defer _ = b.regions.pop();
    switch (lit.*) {
        .Lambda => |l| {
            try checkParams(b, l);
            const v = try body.lowerStmts(b, l.body.stmts);
            if (!b.terminated()) {
                const out = if (returnsUnit(s, rec.fn_type)) try b.unit() else v orelse try b.unit();
                try b.emit(.{ .Move = .{ .dst = result, .src = out } });
                b.terminate(.{ .Goto = end });
            }
        },
        .AnonFun => |af| {
            if (af.body) |fb| switch (fb.*) {
                .Block => |*blk| {
                    _ = try body.lowerStmts(b, blk.stmts);
                    if (!b.terminated()) {
                        try b.emit(.{ .Move = .{ .dst = result, .src = try b.unit() } });
                        b.terminate(.{ .Goto = end });
                    }
                },
                .Expr => |*ex| {
                    const v = try body.lowerExpr(b, ex);
                    if (!b.terminated()) {
                        try b.emit(.{ .Move = .{ .dst = result, .src = v } });
                        b.terminate(.{ .Goto = end });
                    }
                },
            } else {
                try b.emit(.{ .Move = .{ .dst = result, .src = try b.unit() } });
                b.terminate(.{ .Goto = end });
            }
        },
        else => return b.fail(lit.span(), "lowered in place but not a function literal", .{}),
    }
    b.switchTo(end);
    if (own_group) try compose.endReplaceGroupCall(b);
    return result;
}

fn strip(e: *const ast.Expr) *const ast.Expr {
    var x = e;
    while (x.* == .Labeled) x = x.Labeled.expr;
    return x;
}

/// Wraps the function value in `value` in fun interface `iface`'s SAM
/// class: a new instance holding it. A null function value, passed for a
/// nullable interface, stays null.
pub fn samWrap(b: *Builder, value: Reg, iface: Sym) Error!Reg {
    const s = b.p.s;
    const br = b.p.br;
    const cls = br.samClassOf(iface) orelse return b.fail(b.cur_span, "`{s}` has no SAM class", .{s.str(s.syms.name(iface))});
    const ctor = br.samCtorOf(iface) orelse return b.fail(b.cur_span, "`{s}` has no SAM constructor", .{s.str(s.syms.name(iface))});
    const dst = b.newReg();
    const split = try b.branchOnNull(value);
    const join = try b.newBlock();
    b.switchTo(split.not_null);
    try b.emit(.{ .RNewInstance = .{ .dst = dst, .class = cls, .ctor = ctor, .args = try b.run(&.{value}), .n_args = 1 } });
    b.terminate(.{ .Goto = join });
    b.switchTo(split.is_null);
    try b.emit(.{ .Move = .{ .dst = dst, .src = try b.nullValue() } });
    b.terminate(.{ .Goto = join });
    b.switchTo(join);
    return dst;
}
