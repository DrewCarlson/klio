//! Restart-epilogue injection at every exit of a restartable composable,
//! plus the shared lambda and function-signature helpers.

const std = @import("std");
const ast = @import("ast");
const root = @import("../compose_pass.zig");

const Ident = ast.Ident;
const Expr = ast.Expr;
const Function = ast.Function;
const FunctionBody = ast.FunctionBody;
const Param = ast.Param;
const Stmt = ast.Stmt;
const TypeRef = ast.TypeRef;

const composer_param = root.composer_param;
const changed_param = root.changed_param;

const builder = @import("builder.zig");
const B = builder.B;

const collect = @import("collect.zig");
const calleeInlinesLambda = collect.calleeInlinesLambda;

/// Injects the restart epilogue before every `return` that exits the restartable
/// composable, so an early or conditional return closes its open groups as
/// kotlinc's generated code does; otherwise the group stays open and the next
/// composition throws "Start/end imbalance". Each injected block closes the
/// enclosing wrapped replace-groups first, one `$composer.endReplaceGroup()` per
/// open bracket, then runs `$composer.endRestartGroup()?.updateScope(..)`.
/// Descends through control flow and into lambda arguments of INLINE callees,
/// where a bare `return` is a non-local exit of the composable; a non-inline
/// lambda, anonymous fn, local fn, or local class keeps its own returns.
pub const EpilogueInjector = struct {
    a: std.mem.Allocator,
    b: B,
    fn_name: []const u8,
    value_params: []const Param,
    /// Whether the body being injected owns a restart bracket. A content
    /// lambda's restart group belongs to `ComposableLambdaImpl`, so only
    /// replace-groups close there.
    has_restart: bool = true,
    /// Open wrapped replace-groups at the current descent position.
    replace_depth: usize = 0,
    /// Inline-lambda boundaries the descent entered: the callee's simple name,
    /// the implicit label of its lambda, and the replace-depth at entry, so
    /// `return@run` closes exactly the brackets opened inside.
    labels: [16]LabelEntry = undefined,
    n_labels: usize = 0,

    const LabelEntry = struct { name: []const u8, depth: usize };

    pub fn stmts(self: *EpilogueInjector, list: []Stmt) std.mem.Allocator.Error!void {
        for (list) |*s| try self.stmt(s);
    }

    fn stmt(self: *EpilogueInjector, s: *Stmt) std.mem.Allocator.Error!void {
        switch (s.*) {
            .Expr => |*e| try self.expr(e),
            .Assign => |*asg| {
                try self.expr(&asg.target);
                try self.expr(&asg.value);
            },
            .DestructuringDecl => |*dd| try self.expr(&dd.init),
            .Decl => |*d| switch (d.*) {
                .Property => |p| {
                    if (p.init) |*ini| try self.expr(ini);
                    if (p.delegate) |del| try self.expr(del);
                },
                // A local fn or class owns its returns.
                else => {},
            },
        }
    }

    fn block(self: *EpilogueInjector, blk: *ast.Block) std.mem.Allocator.Error!void {
        // A marker-close block the walker already emitted for a non-local return
        // (`{ …; $composer.endToMarker(m); return@label }`) closes every open
        // group down to the target scope, so per-bracket endReplaceGroup calls on
        // top would double-close.
        for (blk.stmts) |*st| {
            if (isComposerCallStmt(st, "endToMarker")) return;
        }
        // A branch block the walker wrapped opens a replace-group; a return
        // inside closes it too.
        const wrapped = blk.stmts.len != 0 and isComposerCallStmt(&blk.stmts[0], "startReplaceGroup");
        if (wrapped) self.replace_depth += 1;
        defer if (wrapped) {
            self.replace_depth -= 1;
        };
        try self.stmts(blk.stmts);
    }

    fn expr(self: *EpilogueInjector, e: *Expr) std.mem.Allocator.Error!void {
        switch (e.*) {
            .Return => |*r| {
                if (r.value) |v| try self.expr(v);
                const ret_span = r.span;
                // How many open replace-groups this return crosses, and whether
                // it exits the composable itself, which also runs the restart
                // epilogue.
                var n_end: usize = 0;
                var exits_composable = false;
                if (r.label == null or std.mem.eql(u8, r.label.?.name, self.fn_name)) {
                    n_end = self.replace_depth;
                    exits_composable = self.has_restart;
                    if (!self.has_restart and n_end == 0) return;
                } else {
                    // `return@run`: the exit crosses the brackets opened since
                    // the labeled inline lambda's entry.
                    var found = false;
                    var i: usize = self.n_labels;
                    while (i > 0) {
                        i -= 1;
                        if (std.mem.eql(u8, self.labels[i].name, r.label.?.name)) {
                            n_end = self.replace_depth - self.labels[i].depth;
                            found = true;
                            break;
                        }
                    }
                    if (!found or n_end == 0) return;
                }
                const inner = e.*;
                const extra: usize = if (exits_composable) 2 else 1;
                const list = try self.a.alloc(Stmt, n_end + extra);
                for (0..n_end) |k| {
                    list[k] = .{ .Expr = self.b.callMember(
                        self.b.pathExpr(composer_param),
                        "endReplaceGroup",
                        try self.a.alloc(Expr, 0),
                    ) };
                }
                if (exits_composable) {
                    list[n_end] = .{ .Expr = try endRestartGroupExpr(self.a, self.b, self.fn_name, self.value_params) };
                }
                list[n_end + extra - 1] = .{ .Expr = inner };
                e.* = .{ .Block = .{ .stmts = list, .span = ret_span } };
            },
            .Call => |*c| {
                try self.expr(c.callee);
                const callee_name: ?[]const u8 = if (c.callee.* == .Path and c.callee.Path.segments.len >= 1)
                    c.callee.Path.segments[c.callee.Path.segments.len - 1].name
                else if (c.callee.* == .Member)
                    c.callee.Member.name.name
                else
                    null;
                const inlines = callee_name != null and calleeInlinesLambda(callee_name.?);
                for (c.args) |*arg| {
                    switch (arg.*) {
                        .Lambda => |*lam| if (inlines) {
                            const pushed = self.n_labels < self.labels.len;
                            if (pushed) {
                                self.labels[self.n_labels] = .{ .name = callee_name.?, .depth = self.replace_depth };
                                self.n_labels += 1;
                            }
                            defer if (pushed) {
                                self.n_labels -= 1;
                            };
                            try self.block(&lam.body);
                        },
                        else => try self.expr(arg),
                    }
                }
            },
            .If => |*f| {
                try self.expr(f.cond);
                try self.expr(f.then_branch);
                if (f.else_branch) |eb| try self.expr(eb);
            },
            .When => |*wh| {
                if (wh.subject) |sub| try self.expr(sub);
                for (wh.branches) |*br| try self.expr(&br.body);
            },
            .Block => |*blk| try self.block(blk),
            .Try => |*t| {
                try self.block(&t.body);
                for (t.catches) |*ca| try self.block(&ca.body);
                if (t.finally) |*fin| try self.block(fin);
            },
            .While => |*wl| {
                try self.expr(wl.cond);
                try self.expr(wl.body);
            },
            .DoWhile => |*dw| {
                if (dw.body) |bd| try self.expr(bd);
                try self.expr(dw.cond);
            },
            .For => |*fr| {
                try self.expr(fr.iter);
                try self.expr(fr.body);
            },
            .Binary => |*bn| {
                try self.expr(bn.lhs);
                try self.expr(bn.rhs);
            },
            .Unary => |*u| try self.expr(u.expr),
            .Postfix => |*p| try self.expr(p.expr),
            .Member => |*m| try self.expr(m.receiver),
            .Index => |*ix| {
                try self.expr(ix.receiver);
                for (ix.args) |*arg| try self.expr(arg);
            },
            .Labeled => |*l| try self.expr(l.expr),
            .Throw => |*t| try self.expr(t.value),
            .IsCheck => |*ic| try self.expr(ic.expr),
            .As => |*as| try self.expr(as.expr),
            .StringTemplate => |*st| for (st.parts) |*part| switch (part.*) {
                .Interp => |ie| try self.expr(ie),
                else => {},
            },
            else => {},
        }
    }
};

/// Whether a headerless lambda body reads the implicit `it` anywhere.
fn blockUsesIt(blk: *const ast.Block) bool {
    for (blk.stmts) |*st| {
        if (stmtUsesIt(st)) return true;
    }
    return false;
}

fn stmtUsesIt(s: *const Stmt) bool {
    switch (s.*) {
        .Expr => |*e| return exprUsesIt(e),
        .Assign => |*asg| return exprUsesIt(&asg.target) or exprUsesIt(&asg.value),
        .DestructuringDecl => |*dd| return exprUsesIt(&dd.init),
        .Decl => |*d| switch (d.*) {
            .Property => |pr| {
                if (pr.init) |*ini| return exprUsesIt(ini);
                return false;
            },
            else => return false,
        },
    }
}

fn exprUsesIt(e: *const Expr) bool {
    switch (e.*) {
        .Path => |p| return p.segments.len == 1 and std.mem.eql(u8, p.segments[0].name, "it"),
        .Call => |*c| {
            if (exprUsesIt(c.callee)) return true;
            for (c.args) |*a| {
                switch (a.*) {
                    // A nested headerless lambda rebinds `it`.
                    .Lambda => {},
                    else => if (exprUsesIt(a)) return true,
                }
            }
            return false;
        },
        .If => |*f| {
            if (exprUsesIt(f.cond) or exprUsesIt(f.then_branch)) return true;
            if (f.else_branch) |eb| return exprUsesIt(eb);
            return false;
        },
        .When => |*wh| {
            if (wh.subject) |sub| if (exprUsesIt(sub)) return true;
            for (wh.branches) |*br| if (exprUsesIt(&br.body)) return true;
            return false;
        },
        .Block => |*blk| return blockUsesIt(blk),
        .Binary => |*bn| return exprUsesIt(bn.lhs) or exprUsesIt(bn.rhs),
        .Unary => |*u| return exprUsesIt(u.expr),
        .Postfix => |*p| return exprUsesIt(p.expr),
        .Member => |*m| return exprUsesIt(m.receiver),
        .Index => |*ix| {
            if (exprUsesIt(ix.receiver)) return true;
            for (ix.args) |*a| if (exprUsesIt(a)) return true;
            return false;
        },
        .StringTemplate => |*st| {
            for (st.parts) |*part| switch (part.*) {
                .Interp => |ie| if (exprUsesIt(ie)) return true,
                else => {},
            };
            return false;
        },
        .Labeled => |*l| return exprUsesIt(l.expr),
        .Throw => |*t| return exprUsesIt(t.value),
        .Return => |*r| {
            if (r.value) |v| return exprUsesIt(v);
            return false;
        },
        else => return false,
    }
}

/// Whether `s` is a bare `$composer.<name>()` call statement.
pub fn isComposerCallStmt(s: *const Stmt, name: []const u8) bool {
    if (s.* != .Expr) return false;
    const e = &s.Expr;
    if (e.* != .Call) return false;
    const callee = e.Call.callee;
    if (callee.* != .Member) return false;
    if (!std.mem.eql(u8, callee.Member.name.name, name)) return false;
    const recv = callee.Member.receiver;
    return recv.* == .Path and recv.Path.segments.len == 1 and
        std.mem.eql(u8, recv.Path.segments[0].name, composer_param);
}

pub fn endRestartGroupExpr(a: std.mem.Allocator, b: B, fn_name: []const u8, value_params: []const Param) std.mem.Allocator.Error!Expr {
    // `$composer.endRestartGroup()`
    const end_call = b.callMember(b.pathExpr(composer_param), "endRestartGroup", &.{});
    // `?.updateScope(<lambda>)`, a safe member call.
    const lambda = try recomposeLambda(a, b, fn_name, value_params);
    return .{ .Call = .{
        .callee = b.box(.{ .Member = .{
            .receiver = b.box(end_call),
            .name = b.ident("updateScope"),
            .safe = true,
            .span = b.gen_span,
        } }),
        .args = b.slice1(lambda),
        .arg_names = try oneNull(a),
        .type_args = &.{},
        .is_infix = false,
        .has_trailing_lambda = true,
        .span = b.gen_span,
    } };
}

/// `{ c, _f -> Self(origValueArgs, c, $changed or 1) }`: the recompose lambda
/// re-invoking the function with the same value arguments, the recompose
/// composer, and `$changed or 1`. `value_params` are the TRANSFORMED value
/// params, so a defaulted param is its renamed `p$arg`, the restart passes the
/// marker through, and the default re-evaluates in the new composition.
fn recomposeLambda(a: std.mem.Allocator, b: B, fn_name: []const u8, value_params: []const Param) std.mem.Allocator.Error!Expr {
    // Re-invoke the function: original value params by name, then the recompose
    // composer and `$changed or 1`.
    var call_args = try a.alloc(Expr, value_params.len + 2);
    for (value_params, 0..) |p, i| call_args[i] = b.pathExpr(p.name.name);
    call_args[value_params.len] = b.pathExpr("$rc"); // recompose composer lambda param
    // `updateChangedFlags($changed or 1)`, kotlinc's restart re-invoke. The wrap
    // folds every DYNAMIC "changed" triple down to "same": the restart re-runs
    // with the very values the scope captured, so a caller-recombined changed bit
    // frozen in `$changed` must not force the callee's downstream to re-execute
    // forever. Static triples, both bits set, survive the fold unchanged. `or` is
    // Kotlin's infix bitwise function; the AST `BinOp.Or` is logical `||`, whose
    // short-circuit on an Int kills the invocation.
    const forced = b.callMember(
        b.pathExpr(changed_param),
        "or",
        b.slice1(b.intLit(1)),
    );
    const ucf_args = try a.alloc(Expr, 1);
    ucf_args[0] = forced;
    call_args[value_params.len + 1] = b.call(
        b.pathExprSegs(&.{ "androidx", "compose", "runtime", "updateChangedFlags" }),
        ucf_args,
    );
    const reinvoke = b.call(b.pathExpr(fn_name), call_args);

    const lam_params = try a.alloc(Ident, 2);
    lam_params[0] = b.ident("$rc");
    lam_params[1] = b.ident("$rf");
    const lam_ptys = try a.alloc(?TypeRef, 2);
    lam_ptys[0] = null;
    lam_ptys[1] = null;
    const body_stmts = try a.alloc(Stmt, 1);
    body_stmts[0] = .{ .Expr = reinvoke };
    return .{ .Lambda = .{
        .params = lam_params,
        .param_tys = lam_ptys,
        .body = .{ .stmts = body_stmts, .span = b.gen_span },
        .implicit_it = false,
        .span = b.gen_span,
    } };
}

fn oneNull(a: std.mem.Allocator) std.mem.Allocator.Error![]?[]const u8 {
    const s = try a.alloc(?[]const u8, 1);
    s[0] = null;
    return s;
}

/// The simple (last-segment) name a call's callee denotes, or null when the
/// callee is neither a plain name nor a member; only those shapes are threaded.
pub fn calleeSimpleName(callee: *const Expr) ?[]const u8 {
    return switch (callee.*) {
        .Path => |p| if (p.segments.len >= 1) p.segments[p.segments.len - 1].name else null,
        .Member => |m| m.name.name,
        else => null,
    };
}

/// The lambda inside a memo wrap the pass emitted around a sink argument
/// (`rememberComposableLambda(key, tracked, block, $composer, 0)` or
/// `composableLambdaInstance(key, tracked, block)`), for the lowering-side shape
/// repair: the wrap runs before resolution selects the parameter.
pub fn memoWrappedLambda(e: *Expr) ?*@FieldType(Expr, "Lambda") {
    if (e.* != .Call) return null;
    const c = &e.Call;
    const nm = calleeSimpleName(c.callee) orelse return null;
    if (!std.mem.eql(u8, nm, "rememberComposableLambda") and
        !std.mem.eql(u8, nm, "composableLambdaInstance")) return null;
    if (c.args.len < 3) return null;
    return trailingLambda(&c.args[2]);
}

/// A lambda literal argument, or a lambda wrapped in a `Labeled` node from an
/// explicit `lbl@{ … }` trailing lambda. Returns the lambda payload pointer so
/// the labeled form threads exactly like the bare one; null for a non-lambda arg.
pub fn trailingLambda(e: *Expr) ?*@FieldType(Expr, "Lambda") {
    return switch (e.*) {
        .Lambda => &e.Lambda,
        .Labeled => |*l| if (l.expr.* == .Lambda) &l.expr.Lambda else null,
        else => null,
    };
}

pub fn signatureOnly(f: *const Function, params: []Param) Function {
    var out = f.*;
    out.params = params;
    return out;
}

/// A copy of `f` with new params and body, every other field preserved. The
/// `@Composable` annotation stays so downstream passes still recognise the
/// function.
pub fn withBody(f: *const Function, params: []Param, body: FunctionBody) Function {
    var out = f.*;
    out.params = params;
    out.body = body;
    return out;
}
