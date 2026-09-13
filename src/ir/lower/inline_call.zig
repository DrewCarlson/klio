//! Inline-call lowering: expanding an `inline fun` body and splicing its lambda
//! arguments at the call site. Free functions over the shared `FuncBuilder`.

const std = @import("std");
const ast = @import("ast");
const ir = @import("../ir.zig");
const build = @import("../build.zig");
const expr_lower = @import("expr.zig");
const static_call_type = @import("static_call_type.zig");
const inline_state = @import("inline_state.zig");
const ast_scan = @import("ast_scan.zig");
const helpers = @import("helpers.zig");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const TypeRef = ast.TypeRef;
const Function = ast.Function;
const Reg = ir.Reg;
const Const = ir.Const;
const Inst = ir.Inst;
const Terminator = ir.Terminator;
const InlineReturn = build.InlineReturn;
const CallShape = inline_state.CallShape;

const lowerExpr = expr_lower.lowerExpr;
const lowerBlock = expr_lower.lowerBlock;

/// Best-effort static type of a member call's receiver, used only to disambiguate
/// same-name reified inline extensions on different receiver types.
threadlocal var infer_recv_depth: u16 = 0;

pub fn inferReceiverType(b: *const FuncBuilder, this_arg: ?*const Expr) Allocator.Error!?[]const u8 {
    // A local's recorded initializer can reference the local itself, so the
    // init-expr recursion needs a depth bound; real chains are a few hops.
    if (infer_recv_depth >= 16) return null;
    infer_recv_depth += 1;
    defer infer_recv_depth -= 1;
    const arg = this_arg orelse return b.thisNarrow() orelse b.recvTy();
    switch (arg.*) {
    // A smart-cast `this` resolves against the narrowed type; `super` keeps the
    // declared one.
        .This => return b.thisNarrow() orelse b.recvTy(),
        .Super => return b.recvTy(),
        .Call => |call| {
            const name = switch (call.callee.*) {
                .Member => |m| m.name.name,
                .Path => |p| if (p.segments.len == 1) p.segments[0].name else return null,
                else => return null,
            };
            // Tally concrete return types across the same-name overloads and pick
            // the most common; `Unit`, a bare type parameter, and a tie answer none.
            var tally = std.StringHashMap(usize).init(b.allocator);
            defer tally.deinit();
            for (b.module.funcsBySimpleName(name)) |fid| {
                const f = b.module.funcById(fid) orelse continue;
                const rt = f.return_ty.name;
                const is_type_param = rt.len <= 2 and allAsciiUppercase(rt);
                if (rt.len == 0 or std.mem.eql(u8, rt, "Unit") or is_type_param) {
                    continue;
                }
                const gop = try tally.getOrPut(rt);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            }
            var best: ?[]const u8 = null;
            var best_n: usize = 0;
            var tie = false;
            var it = tally.iterator();
            while (it.next()) |entry| {
                const ty = entry.key_ptr.*;
                const n = entry.value_ptr.*;
                if (best == null) {
                    best = ty;
                    best_n = n;
                } else if (n > best_n) {
                    best = ty;
                    best_n = n;
                    tie = false;
                } else if (n == best_n) {
                    tie = true;
                }
            }
            if (tie) return null;
            return best;
        },
        .Path => |p| {
            if (p.segments.len != 1) return null;
            const name = p.segments[0].name;
            if (b.localDeclType(name)) |t| return t;
            if (b.localInitExpr(name)) |e| return inferReceiverType(b, e);
            if (b.module.eagerTypeOf(arg.span())) |t| return t.name;
            // A bare name that is not a local is a member of the enclosing class,
            // whose declared type is receiver evidence just as a local's is.
            if (ownerMemberDeclType(b, name)) |t| return t;
            // A bare name that is neither a local nor a member names a type, the only
            // evidence separating an extension set spread over several receivers.
            if (b.resolve(name) == null and !b.knowsOuter(name) and
                b.module.classId(name) != null) return name;
            return null;
        },
        else => return null,
    }
}

/// Receiver-head inference for the qualified member-inline splice gate, extending
/// `inferReceiverType` with a constructor-call initializer, a member property read,
/// and a splice-receiver member.
pub fn gateReceiverHead(b: *const FuncBuilder, receiver: *const Expr) Allocator.Error!?[]const u8 {
    if (try inferReceiverType(b, receiver)) |h| return h;
    switch (receiver.*) {
        .Path => |p| {
            if (p.segments.len != 1) return null;
            const name = p.segments[0].name;
            if (b.localInitExpr(name)) |e| {
                if (ctorClassName(b, e)) |cn| return cn;
            }
            if (b.lambda_splice_resolve == null) {
                if (b.spliceRecvTy()) |srt| {
                    if (classMemberDeclType(b, srt, name)) |t| return t;
                }
            }
            const sb = expr_lower.staticBareReceiverType(b, name);
            if (inline_state.runtime.envOnce("KLIO_EXT_TRACE")) |w| {
                if (std.mem.eql(u8, w, name)) std.debug.print("[gate] {s}: local={} outer={} sbrt={?s}\n", .{ name, b.resolve(name) != null, b.knowsOuter(name), sb });
            }
            if (sb) |h| return h;
            return null;
        },
        .Member => |m| {
            if (m.safe) return null;
            const base = (try gateReceiverHead(b, m.receiver)) orelse return null;
            return classMemberDeclType(b, base, m.name.name);
        },
        .Call => |call| return ctorClassName(b, receiver) orelse blk: {
            _ = call;
            break :blk null;
        },
    // An unsafe cast fixes the receiver's static type: kotlinc resolves through it.
        .As => |a| {
            if (a.safe) return null;
            const nm2 = std.mem.trimEnd(u8, a.ty.name.name, "?");
            if (nm2.len == 0) return null;
            return nm2;
        },
    // `x!!` fixes the receiver's static type to the non-null projection of `x`'s.
        .Postfix => |pf| if (pf.op == .NotNull)
            return (try gateReceiverHead(b, pf.expr))
        else
            return null,
        else => return null,
    }
}

fn ctorClassName(b: *const FuncBuilder, e: *const Expr) ?[]const u8 {
    if (e.* != .Call) return null;
    const callee = e.Call.callee;
    if (callee.* != .Path or callee.Path.segments.len != 1) return null;
    const name = callee.Path.segments[0].name;
    if (b.module.classId(name) != null) return name;
    return null;
}

/// The declared type head of member `name` on the enclosing class or a transitive
/// supertype: a primary-constructor `val` or a body property.
fn ownerMemberDeclType(b: *const FuncBuilder, name: []const u8) ?[]const u8 {
    const owner = b.ownerClass() orelse return null;
    return classMemberDeclType(b, owner, name);
}

/// As `ownerMemberDeclType`, from an explicit starting class.
fn classMemberDeclType(b: *const FuncBuilder, owner: []const u8, name: []const u8) ?[]const u8 {
    var seen: [16][]const u8 = undefined;
    var n_seen: usize = 0;
    var queue: [16][]const u8 = undefined;
    var head: usize = 0;
    var tail: usize = 0;
    queue[tail] = owner;
    tail += 1;
    while (head < tail) {
        const cur = queue[head];
        head += 1;
        var dup = false;
        for (seen[0..n_seen]) |s| {
            if (std.mem.eql(u8, s, cur)) dup = true;
        }
        if (dup) continue;
        if (n_seen < seen.len) {
            seen[n_seen] = cur;
            n_seen += 1;
        }
        if (b.module.classId(cur)) |cid| {
            if (@intFromEnum(cid) < b.module.classes.items.len) {
                const c = &b.module.classes.items[@intFromEnum(cid)];
                for (c.primary_params) |*pp| {
                    if (std.mem.eql(u8, pp.name, name) and pp.ty.name.len != 0) return pp.ty.name;
                }
            }
        }
        if (inline_state.memberPropAst(cur, name)) |prop| {
            if (prop.ty) |*t| {
                if (t.name.name.len != 0) return t.name.name;
            }
        }
        if (b.module.registry.class_super_names.get(cur)) |sups| {
            for (sups) |s| {
                if (tail < queue.len) {
                    queue[tail] = s;
                    tail += 1;
                }
            }
        }
    }
    return null;
}

fn allAsciiUppercase(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isUpper(c)) return false;
    }
    return true;
}

/// Whether any lambda-literal argument contains a non-local `return` in its own
/// body, not descending into nested lambdas or local functions.
pub fn argLambdaHasNonlocalReturn(args: []const Expr) bool {
    for (args) |*a| {
        if (a.* == .Lambda) {
            if (scanStmts(a.Lambda.body.stmts)) return true;
        }
    }
    return false;
}

/// Whether any argument lambda contains a call that can suspend. An inline fn's
/// inline lambda inherits the caller's suspend capability, so such a call must
/// splice: the host-served intrinsic route loses a real suspension.
pub fn argLambdaMaySuspend(b: *const FuncBuilder, f: *const ast.Function, args: []const Expr) bool {
    var heads_buf: [6][]const u8 = undefined;
    var n_heads: usize = 0;
    for (f.params) |*p| {
        if (p.ty.function) |pf| {
            if (pf.receiver) |r| {
                if (n_heads < heads_buf.len) {
                    heads_buf[n_heads] = r.name.name;
                    n_heads += 1;
                }
            }
        }
    }
    if (b.recvTy()) |rt| {
        if (n_heads < heads_buf.len) {
            heads_buf[n_heads] = rt;
            n_heads += 1;
        }
    }
    if (b.spliceRecvTy()) |rt| {
        if (n_heads < heads_buf.len) {
            heads_buf[n_heads] = rt;
            n_heads += 1;
        }
    }
    const heads = heads_buf[0..n_heads];
    for (args) |*a| {
        switch (a.*) {
            .Lambda => |l| if (suspendScanStmts(b, heads, l.body.stmts)) return true,
            .AnonFun => |af| {
                const body = af.body orelse continue;
                switch (body.*) {
                    .Block => |blk| if (suspendScanStmts(b, heads, blk.stmts)) return true,
                    .Expr => |*ex| if (suspendScan(b, heads, ex)) return true,
                }
            },
            else => continue,
        }
    }
    return false;
}

fn callNameMaySuspend(b: *const FuncBuilder, heads: []const []const u8, name: []const u8) bool {
    // A suspend candidate counts only when a receiver visible to the lambda body
    // could bind it: receiverless, or accepting one of the visible heads.
    for (b.module.funcsBySimpleName(name)) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        if (!f.is_suspend) continue;
        const is_ext = f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this");
        if (!is_ext) return true;
        const want = typeHeadOf(f.params[0].ty.name);
        for (heads) |h| {
            if (std.mem.eql(u8, h, want) or b.module.classIsOrExtends(h, want)) return true;
        }
    }
    return false;
}

fn typeHeadOf(n: []const u8) []const u8 {
    var h = std.mem.trimEnd(u8, n, "?");
    if (std.mem.findScalar(u8, h, '<')) |lt| h = h[0..lt];
    return h;
}

fn suspendScanStmts(b: *const FuncBuilder, heads: []const []const u8, stmts: []const Stmt) bool {
    for (stmts) |*s| {
        const hit = switch (s.*) {
            .Expr => |*e| suspendScan(b, heads, e),
            .Assign => |asg| suspendScan(b, heads, &asg.target) or suspendScan(b, heads, &asg.value),
            .DestructuringDecl => |d| suspendScan(b, heads, &d.init),
            .Decl => |decl| switch (decl) {
                .Property => |p| if (p.init) |*init| suspendScan(b, heads, init) else false,
                else => false,
            },
        };
        if (hit) return true;
    }
    return false;
}

fn suspendScan(b: *const FuncBuilder, heads: []const []const u8, e: *const Expr) bool {
    return switch (e.*) {
        .Call => |c| blk: {
            const cname: ?[]const u8 = switch (c.callee.*) {
                .Path => |pth| if (pth.segments.len != 0) pth.segments[pth.segments.len - 1].name else null,
                .Member => |m| m.name.name,
                else => null,
            };
            if (cname) |n| {
                if (callNameMaySuspend(b, heads, n)) break :blk true;
            }
            break :blk suspendScan(b, heads, c.callee) or suspendScanArgs(b, heads, c.args);
        },
        .Lambda => |l| suspendScanStmts(b, heads, l.body.stmts),
        .AnonFun => |af| blk3: {
            const body = af.body orelse break :blk3 false;
            break :blk3 switch (body.*) {
                .Block => |blkb| suspendScanStmts(b, heads, blkb.stmts),
                .Expr => |*ex| suspendScan(b, heads, ex),
            };
        },
        .Member => |m| suspendScan(b, heads, m.receiver),
        .Unary => |u| suspendScan(b, heads, u.expr),
        .Postfix => |pf| suspendScan(b, heads, pf.expr),
        .Spread => |sp| suspendScan(b, heads, sp.expr),
        .Throw => |t| suspendScan(b, heads, t.value),
        .Labeled => |l| suspendScan(b, heads, l.expr),
        .As => |a| suspendScan(b, heads, a.expr),
        .IsCheck => |c| suspendScan(b, heads, c.expr),
        .MemberRef => |r| suspendScan(b, heads, r.receiver),
        .Index => |i| suspendScan(b, heads, i.receiver) or suspendScanArgs(b, heads, i.args),
        .Binary => |bin| suspendScan(b, heads, bin.lhs) or suspendScan(b, heads, bin.rhs),
        .If => |i| suspendScan(b, heads, i.cond) or suspendScan(b, heads, i.then_branch) or
            (if (i.else_branch) |eb| suspendScan(b, heads, eb) else false),
        .While => |w| suspendScan(b, heads, w.cond) or suspendScan(b, heads, w.body),
        .DoWhile => |dw| (if (dw.body) |body| suspendScan(b, heads, body) else false) or suspendScan(b, heads, dw.cond),
        .For => |f| suspendScan(b, heads, f.iter) or suspendScan(b, heads, f.body),
        .Block => |blk2| suspendScanStmts(b, heads, blk2.stmts),
        else => false,
    };
}

fn suspendScanArgs(b: *const FuncBuilder, heads: []const []const u8, args: []const Expr) bool {
    for (args) |*a| {
        if (suspendScan(b, heads, a)) return true;
    }
    return false;
}

/// Recover the original literal when an inline body forwards one of its lambda
/// parameters onward; Kotlin keeps it inline through the whole chain.
pub fn forwardedInlineLambda(b: *const FuncBuilder, arg: *const Expr) ?*const Expr {
    if (arg.* != .Path or arg.Path.segments.len != 1) return null;
    return b.inlineLambdaFor(arg.Path.segments[0].name);
}

pub fn argsForwardInlineLambda(b: *const FuncBuilder, args: []const Expr) bool {
    for (args) |*arg| {
        if (forwardedInlineLambda(b, arg) != null) return true;
    }
    return false;
}

/// Whether any argument lambda literal contains a `return@LABEL` naming `label`,
/// which keeps a widened splice off the call so the label stays on a real frame.
pub fn argLambdaTargetsLabel(args: []const Expr, label: []const u8) bool {
    for (args) |*a| {
        if (a.* != .Lambda) continue;
        if (labelScanStmtsG(true, a.Lambda.body.stmts, label)) return true;
    }
    return false;
}

/// Whether any argument lambda contains a `return@LABEL` naming an inline splice
/// currently open here, a frameless scope the dynamic unwind cannot find, so the
/// call must splice.
pub fn argLambdaTargetsSplicedLabel(b: *const FuncBuilder, args: []const Expr) bool {
    if (b.inline_lambda_ret.items.len == 0) return false;
    for (args) |*a| {
        const lam: *const Expr = if (a.* == .Lambda) a else forwardedInlineLambda(b, a) orelse continue;
        if (lam.* != .Lambda) continue;
        for (b.inline_lambda_ret.items) |ret| {
            if (labelScanStmts(lam.Lambda.body.stmts, ret.label)) return true;
        }
    }
    return false;
}

fn labelScanStmts(stmts: []const Stmt, label: []const u8) bool {
    return labelScanStmtsG(false, stmts, label);
}

fn labelScan(e: *const Expr, label: []const u8) bool {
    return labelScanG(false, e, label);
}

fn labelScanStmtsG(comptime deep: bool, stmts: []const Stmt, label: []const u8) bool {
    for (stmts) |*st| {
        const hit = switch (st.*) {
            .Expr => |*e| labelScanG(deep, e, label),
            .Assign => |asg| labelScanG(deep, &asg.target, label) or labelScanG(deep, &asg.value, label),
            .DestructuringDecl => |d| labelScanG(deep, &d.init, label),
            .Decl => |decl| switch (decl) {
                .Property => |pr| if (pr.init) |*init| labelScanG(deep, init, label) else false,
                else => false,
            },
        };
        if (hit) return true;
    }
    return false;
}

fn labelScanArgs(comptime deep: bool, args: []const Expr, label: []const u8) bool {
    for (args) |*a| {
        if (labelScanG(deep, a, label)) return true;
    }
    return false;
}

fn labelScanG(comptime deep: bool, e: *const Expr, label: []const u8) bool {
    return switch (e.*) {
        .Return => |r| if (r.label) |l| std.mem.eql(u8, l.name, label) else false,
        .Lambda => |lam| deep and labelScanStmtsG(deep, lam.body.stmts, label),
        .AnonFun => |af| blk: {
            if (!deep) break :blk false;
            const body = af.body orelse break :blk false;
            break :blk switch (body.*) {
                .Block => |bb| labelScanStmtsG(deep, bb.stmts, label),
                .Expr => |*ex| labelScanG(deep, ex, label),
            };
        },
        .ObjectExpr => false,
        .Member => |m| labelScanG(deep, m.receiver, label),
        .Unary => |u| labelScanG(deep, u.expr, label),
        .Postfix => |po| labelScanG(deep, po.expr, label),
        .Spread => |sp| labelScanG(deep, sp.expr, label),
        .Throw => |t| labelScanG(deep, t.value, label),
        .Labeled => |l| labelScanG(deep, l.expr, label),
        .As => |a| labelScanG(deep, a.expr, label),
        .IsCheck => |c| labelScanG(deep, c.expr, label),
        .MemberRef => |r| labelScanG(deep, r.receiver, label),
        .Call => |c| labelScanG(deep, c.callee, label) or labelScanArgs(deep, c.args, label),
        .Index => |i| labelScanG(deep, i.receiver, label) or labelScanArgs(deep, i.args, label),
        .Binary => |bin| labelScanG(deep, bin.lhs, label) or labelScanG(deep, bin.rhs, label),
        .If => |i| labelScanG(deep, i.cond, label) or labelScanG(deep, i.then_branch, label) or
            (if (i.else_branch) |eb| labelScanG(deep, eb, label) else false),
        .While => |w| labelScanG(deep, w.cond, label) or labelScanG(deep, w.body, label),
        .DoWhile => |dw| (if (dw.body) |body| labelScanG(deep, body, label) else false) or labelScanG(deep, dw.cond, label),
        .For => |f| labelScanG(deep, f.iter, label) or labelScanG(deep, f.body, label),
        .Block => |blk| labelScanStmtsG(deep, blk.stmts, label),
        .When => |w| (if (w.subject) |sub| labelScanG(deep, sub, label) else false) or blk: {
            for (w.branches) |*br| {
                if (labelScanG(deep, &br.body, label)) break :blk true;
            }
            break :blk false;
        },
        .Try => |t| labelScanStmtsG(deep, t.body.stmts, label) or blk: {
            for (t.catches) |*c| {
                if (labelScanStmtsG(deep, c.body.stmts, label)) break :blk true;
            }
            break :blk (if (t.finally) |fb| labelScanStmtsG(deep, fb.stmts, label) else false);
        },
        else => false,
    };
}


/// True when every reference to `name` in the callee body is a call's callee head,
/// so the splice's call-position expansion consumes every use. Conservative: an
/// unrecognised construct or a bare value occurrence is false.
fn paramOnlyCalled(f: *const ast.Function, name: []const u8) bool {
    const body = if (f.body) |*bd| bd else return false;
    return switch (body.*) {
        .Block => |blk| !pocStmts(true, blk.stmts, name),
        .Expr => |*ex| !pocUses(true, ex, name),
    };
}

fn pocStmts(comptime exempt_call_head: bool, stmts: []const Stmt, name: []const u8) bool {
    for (stmts) |*st| {
        const hit = switch (st.*) {
            .Expr => |*e| pocUses(exempt_call_head, e, name),
            .Assign => |asg| pocUses(exempt_call_head, &asg.target, name) or pocUses(exempt_call_head, &asg.value, name),
            .DestructuringDecl => |d| pocUses(exempt_call_head, &d.init, name),
            .Decl => |decl| switch (decl) {
                .Property => |pr| blk: {
                    // A same-named local re-declaration shadows below; keep the arg.
                    if (std.mem.eql(u8, pr.name.name, name)) break :blk true;
                    break :blk if (pr.init) |*init| pocUses(exempt_call_head, init, name) else false;
                },
                else => true,
            },
        };
        if (hit) return true;
    }
    return false;
}

/// Whether `name` occurs as a value, in any position that is not the callee head
/// of a call, under `e`. Unknown constructs count as a use.
fn pocUses(comptime exempt_call_head: bool, e: *const Expr, name: []const u8) bool {
    return switch (e.*) {
        .IntLit, .FloatLit, .BoolLit, .NullLit, .CharLit, .This, .Super, .Break, .Continue => false,
        .Path => |pth| pth.segments.len == 1 and std.mem.eql(u8, pth.segments[0].name, name),
        .StringTemplate => |st| blk: {
            for (st.parts) |*part| switch (part.*) {
                .Text => {},
                .ShortInterp => |id| if (std.mem.eql(u8, id.name, name)) break :blk true,
                .Interp => |ie| if (pocUses(exempt_call_head, ie, name)) break :blk true,
            };
            break :blk false;
        },
        // A receiver-lambda param invoked with an explicit receiver reaches the param
        // through the member name, which needs the materialized value.
        .Member => |m| std.mem.eql(u8, m.name.name, name) or
            pocUses(exempt_call_head, m.receiver, name),
        .Call => |c| blk: {
        // `contract { … }` lowers to Unit, so a param inside it is never a value use.
            if (c.callee.* == .Path and c.callee.Path.segments.len == 1 and
                std.mem.eql(u8, c.callee.Path.segments[0].name, "contract") and
                c.args.len == 1 and c.args[0] == .Lambda)
            {
                break :blk false;
            }
            const head_is_param = exempt_call_head and c.callee.* == .Path and
                c.callee.Path.segments.len == 1 and
                std.mem.eql(u8, c.callee.Path.segments[0].name, name);
            if (!head_is_param and pocUses(exempt_call_head, c.callee, name)) break :blk true;
            for (c.args) |*a2| {
                if (pocUses(exempt_call_head, a2, name)) break :blk true;
            }
            break :blk false;
        },
        .Index => |ix| blk: {
            if (pocUses(exempt_call_head, ix.receiver, name)) break :blk true;
            for (ix.args) |*a2| {
                if (pocUses(exempt_call_head, a2, name)) break :blk true;
            }
            break :blk false;
        },
        .Binary => |bin| pocUses(exempt_call_head, bin.lhs, name) or pocUses(exempt_call_head, bin.rhs, name),
        .Unary => |u| pocUses(exempt_call_head, u.expr, name),
        .Postfix => |po| pocUses(exempt_call_head, po.expr, name),
        .If => |i| pocUses(exempt_call_head, i.cond, name) or pocUses(exempt_call_head, i.then_branch, name) or
            (if (i.else_branch) |eb| pocUses(exempt_call_head, eb, name) else false),
        .While => |w| pocUses(exempt_call_head, w.cond, name) or pocUses(exempt_call_head, w.body, name),
        .DoWhile => |dw| (if (dw.body) |bd| pocUses(exempt_call_head, bd, name) else false) or pocUses(exempt_call_head, dw.cond, name),
        .For => |fo| pocUses(exempt_call_head, fo.iter, name) or pocUses(exempt_call_head, fo.body, name),
        .Return => |r| if (r.value) |v| pocUses(exempt_call_head, v, name) else false,
        .Labeled => |l| pocUses(exempt_call_head, l.expr, name),
        .Block => |blk2| pocStmts(exempt_call_head, blk2.stmts, name),
        .Throw => |t| pocUses(exempt_call_head, t.value, name),
        .Try => |t| blk: {
            if (pocStmts(exempt_call_head, t.body.stmts, name)) break :blk true;
            for (t.catches) |*c2| {
                if (pocStmts(exempt_call_head, c2.body.stmts, name)) break :blk true;
            }
            break :blk (if (t.finally) |fb| pocStmts(exempt_call_head, fb.stmts, name) else false);
        },
        // A nested lambda in the callee body may itself splice, materialize or defer,
        // so the param's reachability through it is not decidable here.
        .Lambda => true,
        .When => |w| blk: {
            if (w.subject) |sub| {
                if (pocUses(exempt_call_head, sub, name)) break :blk true;
            }
            for (w.branches) |*br| {
                if (pocUses(exempt_call_head, &br.body, name)) break :blk true;
                for (br.patterns) |*pat| switch (pat.kind) {
                    .Value, .InRange, .NotInRange => |*pe| if (pocUses(exempt_call_head, pe, name)) break :blk true,
                    else => {},
                };
            }
            break :blk false;
        },
        .IsCheck => |c| pocUses(exempt_call_head, c.expr, name),
        .As => |a2| pocUses(exempt_call_head, a2.expr, name),
        .Spread => |sp| pocUses(exempt_call_head, sp.expr, name),
        else => true,
    };
}

fn scanStmts(stmts: []const Stmt) bool {
    for (stmts) |*s| {
        const hit = switch (s.*) {
            .Expr => |*e| scan(e),
            .Assign => |asg| scan(&asg.target) or scan(&asg.value),
            .DestructuringDecl => |d| scan(&d.init),
            .Decl => |decl| switch (decl) {
                .Property => |p| if (p.init) |*init| scan(init) else false,
                else => false,
            },
        };
        if (hit) return true;
    }
    return false;
}

// A non-local return inside a nested scope is its own and must not count here.
fn scan(e: *const Expr) bool {
    return switch (e.*) {
        .Return => true,
        .Lambda, .AnonFun, .ObjectExpr => false,
        .Member => |m| scan(m.receiver),
        .Unary => |u| scan(u.expr),
        .Postfix => |p| scan(p.expr),
        .Spread => |s| scan(s.expr),
        .Throw => |t| scan(t.value),
        .Labeled => |l| scan(l.expr),
        .As => |a| scan(a.expr),
        .IsCheck => |c| scan(c.expr),
        .MemberRef => |r| scan(r.receiver),
        .Call => |c| scan(c.callee) or scanArgs(c.args),
        .Index => |i| scan(i.receiver) or scanArgs(i.args),
        .Binary => |bin| scan(bin.lhs) or scan(bin.rhs),
        .If => |i| scan(i.cond) or scan(i.then_branch) or
            (if (i.else_branch) |eb| scan(eb) else false),
        .While => |w| scan(w.cond) or scan(w.body),
        .DoWhile => |dw| (if (dw.body) |body| scan(body) else false) or scan(dw.cond),
        .For => |f| scan(f.iter) or scan(f.body),
        .Block => |blk| scanStmts(blk.stmts),
        .When => |w| (if (w.subject) |sub| scan(sub) else false) or scanWhenBranches(w.branches),
        .Try => |t| scanStmts(t.body.stmts) or scanCatches(t.catches) or
            (if (t.finally) |fb| scanStmts(fb.stmts) else false),
        else => false,
    };
}

fn scanArgs(args: []const Expr) bool {
    for (args) |*a| {
        if (scan(a)) return true;
    }
    return false;
}

fn scanWhenBranches(branches: []const ast.WhenBranch) bool {
    for (branches) |*br| {
        if (scan(&br.body)) return true;
    }
    return false;
}

fn scanCatches(catches: []const ast.Catch) bool {
    for (catches) |*c| {
        if (scanStmts(c.body.stmts)) return true;
    }
    return false;
}

/// Splice an `inline fun` argument lambda where the inlined body invokes the
/// corresponding lambda parameter. Receiver-formed splicing is unconditional.
pub fn rfsEnabled() bool {
    return true;
}

pub fn spliceInlineLambda(
    b: *FuncBuilder,
    lambda_name: []const u8,
    lam: *const Expr,
    arg_exprs: []const Expr,
) Allocator.Error!Reg {
    return spliceInlineLambdaOn(b, lambda_name, lam, arg_exprs, null, null);
}

/// A caller record a lambda-splice parameter binding shadows, restored when the
/// splice ends.
const ShadowSave = struct { name: []const u8, ty: ?ir.TypeRef, init: ?*const ast.Expr };

/// A caller binding hidden for the duration of a spliced lambda body.
const HiddenBind = struct { name: []const u8, h: build.HiddenBinding };

/// Where a spliced lambda literal takes its subject from: the caller's supplied
/// receiver, the first positional argument when a receiver-formed literal is
/// invoked through a param-form function type, or nothing at all.
const LambdaSeat = struct { receiver: ?Reg, arg_supplies_recv: bool };

fn lambdaSpliceSeat(
    b: *FuncBuilder,
    lambda_name: []const u8,
    lam: *const Expr,
    arg_exprs: []const Expr,
    explicit_receiver: ?Reg,
) LambdaSeat {
    const params = lam.Lambda.params;
    // A receiver-formed literal invoked with one more positional argument than it
    // declares gets its receiver from that argument, Kotlin's function types
    // interconverting. The mark-route fallback is the lexically enclosing subject,
    // wrong exactly when the caller computed a fresh receiver.
    const lam_receiver_formed = b.isReceiverLambdaParam(lambda_name) or
        b.lambdaArgRecv(lam.Lambda.span) != null;
    // The literal's value-parameter count under its declared function type: a
    // headerless block's speculative `it` is vacuous under `T.()` but is the value
    // parameter under `T.(A)`. Recorded span-keyed when the literal materializes.
    const decl_params: usize = blk: {
        if (b.lambdaArgArity(lam.Lambda.span)) |n| break :blk @intCast(@max(n, 0));
        break :blk params.len;
    };
    const arg_supplies_recv = explicit_receiver == null and lam_receiver_formed and
        !(lam.Lambda.implicit_it and b.lambdaArgArity(lam.Lambda.span) == null) and
        arg_exprs.len == decl_params + 1;
    const receiver = if (arg_supplies_recv)
        null
    else explicit_receiver orelse if (b.isReceiverLambdaParam(lambda_name))
        b.resolve("this")
    else
        null;
    return .{ .receiver = receiver, .arg_supplies_recv = arg_supplies_recv };
}

/// `KLIO_SPLICE_TRACE=<param>`: how a lambda argument seated its receiver.
fn traceLambdaSpliceEntry(
    b: *FuncBuilder,
    lambda_name: []const u8,
    lam: *const Expr,
    arg_exprs: []const Expr,
    explicit_receiver: ?Reg,
    seat: LambdaSeat,
) void {
    const params = lam.Lambda.params;
    const receiver = seat.receiver;
    const arg_supplies_recv = seat.arg_supplies_recv;
    if (inline_state.runtime.envOnce("KLIO_SPLICE_TRACE")) |w| {
        if (std.mem.eql(u8, w, lambda_name)) std.debug.print("[splice-lam] {s} owner={s} rlp={} explicit={} recv={} seat={} nargs={d} nparams={d} it={} lar={} span={}:{}\n", .{ lambda_name, b.ownerClass() orelse "?", b.isReceiverLambdaParam(lambda_name), explicit_receiver != null, receiver != null, arg_supplies_recv, arg_exprs.len, params.len, lam.Lambda.implicit_it, b.lambdaArgRecv(lam.Lambda.span) != null, lam.Lambda.span.file, lam.Lambda.span.start });
    }
}

/// The enclosing inline fn's param names, collected before this splice pushes its
/// own frame: exactly the marks to suspend while the caller's body lowers.
fn collectEnclosingSubstKeys(b: *FuncBuilder, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    if (b.innermostInlineLambdaSubst()) |subst0| {
        var kit0 = subst0.keyIterator();
        while (kit0.next()) |k0| try out.append(b.allocator, k0.*);
    }
}

/// The lambda's subject binds as its `this`, and as `this@<fn>` inside a receiver
/// lambda passed to inline `f`, shadowing the fn splice's same-labeled binding.
fn bindLambdaSubject(
    b: *FuncBuilder,
    lambda_name: []const u8,
    receiver: ?Reg,
    recv_seat: bool,
    arg_regs: []const Reg,
    lambda_own_base: usize,
) Allocator.Error!void {
    if (receiver) |reg| try b.bind("this", reg) else if (recv_seat) try b.bind("this", arg_regs[0]);
    // Inside a receiver lambda passed to inline `f`, `this@f` names the lambda's own
    // receiver and shadows the fn splice's same-labeled binding, under which a
    // closure in the body captures it.
    if (receiver orelse (if (recv_seat) arg_regs[0] else null)) |subject| {
        if (b.currentInlineFn()) |fname| {
            const label = try std.fmt.allocPrint(b.allocator, "this@{s}", .{fname});
            try b.bind(label, subject);
        }
    }
    if (inline_state.runtime.envOnce("KLIO_THIS_TRACE") != null) {
        std.debug.print("[lam-splice-bind] {s} recv={?d} own_base={d} depth={d}\n", .{ lambda_name, if (receiver) |r| r.int() else null, lambda_own_base, b.scopeDepth() });
    }
}

/// The splice's parameter bindings inherit the argument expressions' static types,
/// what kotlinc gives the lambda parameter. The splice runs in the caller's
/// builder, so each binding shadows a same-named outer record, saved for the
/// caller to restore on exit.
fn bindSplicedLambdaParams(
    b: *FuncBuilder,
    lam: *const Expr,
    eff_arg_regs: []const Reg,
    eff_arg_exprs: []const Expr,
    shadow_saves: *std.ArrayList(ShadowSave),
) Allocator.Error!void {
    const params = lam.Lambda.params;
    const bind_n: usize = if (params.len == 0)
        @min(@as(usize, 1), eff_arg_regs.len)
    else
        @min(params.len, eff_arg_regs.len);
    // Every argument's type is read before any parameter binds: the argument
    // expressions belong to the callee's body scope, and a lambda parameter sharing
    // a name would have its own source erased by the binding.
    const arg_tys = try b.allocator.alloc(?ir.TypeRef, bind_n);
    defer {
        for (arg_tys) |*t| if (t.*) |*ty| ty.deinit(b.allocator);
        b.allocator.free(arg_tys);
    }
    for (arg_tys, 0..) |*slot, ai| {
        if (expr_lower.argDeclTypeRefLazy(b, &eff_arg_exprs[ai])) |ty| {
            slot.* = try ty.clone(b.allocator);
            continue;
        }
        const ae = &eff_arg_exprs[ai];
        if (ae.* == .Index and ae.Index.args.len == 1) {
            slot.* = try expr_lower.iterableElementTypeRef(b, ae.Index.receiver);
        } else {
            slot.* = try expr_lower.staticExprTypeRef(b, ae);
        }
    }
    var bi: usize = 0;
    while (bi < bind_n) : (bi += 1) {
        const pname = if (params.len == 0) "it" else params[bi].name;
        try shadow_saves.append(b.allocator, .{
            .name = pname,
            .ty = if (b.localDeclTypeRef(pname)) |t| try t.clone(b.allocator) else null,
            .init = b.localInitExpr(pname),
        });
        try b.bind(pname, eff_arg_regs[bi]);
        b.clearLocalDeclType(pname);
            // The literal's own annotation is the parameter's type and outranks the
            // callee's argument expression, as kotlinc types an annotated param.
        if (params.len != 0 and bi < lam.Lambda.param_tys.len) {
            if (lam.Lambda.param_tys[bi]) |*annotated| {
                try b.setLocalDeclTypeOwned(
                    pname,
                    try expr_lower.loweredOwnedLocalTypeRef(b, annotated),
                );
                continue;
            }
        }
        const arg_ty: ?ir.TypeRef = arg_tys[bi];
        if (arg_ty) |ty| {
            // A bare type-parameter head names nothing in the receiving scope.
            var h = std.mem.trimEnd(u8, ty.name, "?");
            if (std.mem.findScalar(u8, h, '<')) |lt| h = h[0..lt];
            const bare_tp = (h.len > 0 and h.len <= 2 and
                std.ascii.isUpper(h[0])) or b.isTypeParam(h) or
                ir.parseClassTypeParamIdentity(h) != null;
            if (!bare_tp) {
                try b.setLocalDeclTypeOwned(pname, try ty.clone(b.allocator));
            }
        }
    }
}

/// The owner splice's localize target, captured before the new frame is pushed
/// and duplicated so restoring does not alias the frame's own snapshot. The target
/// for an unlabeled `return` belongs to the frame the lambda was defined under.
fn ownerLambdaReturnSnapshot(b: *FuncBuilder, defining_frame: ?usize) Allocator.Error!?[]InlineReturn {
    if (defining_frame) |di| return try b.allocator.dupe(InlineReturn, b.inlineLambdaFrameOwnerReturn(di));
    if (b.inlineLambdaOwnerReturn()) |o| return try b.allocator.dupe(InlineReturn, o);
    return null;
}

/// The lambda body is caller code, so the inline lambda parameters it can invoke
/// come from the frame the lambda was defined under; the inline function's own
/// frame is skipped, and a name it binds itself shadows.
fn inheritedLambdaSubst(
    b: *FuncBuilder,
    lam: *const Expr,
    defining_frame: ?usize,
) Allocator.Error!std.StringHashMap(*const ast.Expr) {
    const params = lam.Lambda.params;
    var inherited_subst = std.StringHashMap(*const ast.Expr).init(b.allocator);
    if (defining_frame) |di| {
        if (di > 0) {
            var dit = b.inline_lambda_subst.items[di - 1].subst.iterator();
            inherit: while (dit.next()) |e| {
                const key = e.key_ptr.*;
                for (params) |p| {
                    if (std.mem.eql(u8, p.name, key)) continue :inherit;
                }
                if (params.len == 0 and std.mem.eql(u8, key, "it")) continue;
                // Only a name the skipped frames re-bind needs carrying.
                var shadowed = false;
                for (b.inline_lambda_subst.items[di..]) |*fr2| {
                    if (fr2.subst.contains(key)) {
                        shadowed = true;
                        break;
                    }
                }
                if (!shadowed) continue;
                try inherited_subst.put(key, e.value_ptr.*);
            }
        }
    }
    return inherited_subst;
}

/// Resolve the lambda body's free names against the caller scopes plus the
/// lambda's own, skipping the inline fn's parameter scopes in between. Returns
/// whether a hidden band was pushed for that skipped region.
fn openSpliceResolveWindow(
    b: *FuncBuilder,
    splice_caller_depth: ?usize,
    lambda_own_base: usize,
) Allocator.Error!bool {
    var pushed_band = false;
    if (splice_caller_depth) |d| {
        b.lambda_splice_resolve = .{ .caller_depth = d, .own_base = lambda_own_base };
        // Record this window's hidden region, the inline fn's scopes between the
        // caller depth and the lambda's own, so a nested window keeps it hidden.
        if (lambda_own_base > d) {
            try b.splice_hidden_bands.append(b.allocator, .{ .lo = d, .hi = lambda_own_base - 1 });
            pushed_band = true;
        }
    }
    return pushed_band;
}

/// The spliced body's receiver-lambda-param marks are scoped to the inline fn's
/// own names, and a leaked mark emits CallValueWithThis with the scope subject as
/// receiver, so suspend exactly those while the caller body lowers.
fn suspendEnclosingRlpMarks(
    b: *FuncBuilder,
    keys: []const []const u8,
    out: *std.ArrayList([]const u8),
) Allocator.Error!void {
    for (keys) |k| {
        // Only a mark this splice added for the inline fn's own parameter is suspended;
        // a caller's same-named receiver-lambda parameter keeps its own. The mark bit is
        // name-keyed with no provenance, so keep it whenever an outer frame carries it.
        if (b.isReceiverLambdaParam(k) and b.isSpliceRlpMark(k) and
            !b.isSharedRlpMark(k))
        {
            b.unmarkReceiverLambdaParam(k);
            try out.append(b.allocator, k);
        }
    }
}

/// The inline fn's own parameter bindings are hidden for the caller body too, or
/// they shadow a caller class's same-named member.
fn hideEnclosingParamBindings(
    b: *FuncBuilder,
    keys: []const []const u8,
    out: *std.ArrayList(HiddenBind),
) Allocator.Error!void {
    for (keys) |k| {
        if (b.hideBinding(k)) |h| {
            try out.append(b.allocator, .{ .name = k, .h = h });
        }
    }
}

/// The spliced receiver lambda has no runtime closure, its subject being only the
/// window's bound register, so bare member reads need the subject's static head to
/// win the member-versus-global arbitration.
fn splicedSubjectHead(
    b: *FuncBuilder,
    lambda_name: []const u8,
    lam: *const Expr,
    arg_exprs: []const Expr,
    receiver_expr: ?*const Expr,
    explicit_receiver: ?Reg,
    receiver: ?Reg,
    recv_seat: bool,
    subject_reg: ?Reg,
) Allocator.Error!?[]const u8 {
    var recv_head: ?[]const u8 = null;
    if (subject_reg != null) {
        recv_head = b.receiverLambdaRecvHead(lambda_name);
        if (recv_head == null) {
            if (b.lambdaArgRecv(lam.Lambda.span)) |rt| {
                const h0 = expr_lower.typeHead(std.mem.trimEnd(u8, rt.name, "?"));
                const bare_tp0 = (h0.len > 0 and h0.len <= 2 and std.ascii.isUpper(h0[0])) or
                    b.isTypeParam(h0) or ir.parseClassTypeParamIdentity(h0) != null;
                if (!bare_tp0 and h0.len != 0) recv_head = h0;
            }
        }
        const subj_expr: ?*const Expr = receiver_expr orelse
            (if (recv_seat and arg_exprs.len != 0) &arg_exprs[0] else null);
        if (recv_head == null and rfsEnabled()) if (subj_expr) |rex| {
            var derived: ?[]const u8 = null;
            if (expr_lower.argDeclTypeRefLazy(b, rex)) |known| {
                derived = expr_lower.typeHead(std.mem.trimEnd(u8, known.name, "?"));
            } else if (try expr_lower.staticExprTypeRef(b, rex)) |owned_ty| {
                var owned = owned_ty;
                defer owned.deinit(b.allocator);
                derived = try b.allocator.dupe(u8, expr_lower.typeHead(std.mem.trimEnd(u8, owned.name, "?")));
            }
            if (derived) |h| {
                const bare_tp = (h.len > 0 and h.len <= 2 and std.ascii.isUpper(h[0])) or
                    b.isTypeParam(h) or ir.parseClassTypeParamIdentity(h) != null;
                if (!bare_tp and h.len != 0) recv_head = h;
            }
        };
    // A bare invocation of a generic receiver-formed param has no receiver expression
    // to type and binds the callee's own substituted subject, so inherit the
    // enclosing window's head. An explicit `receiver.block()` binds an expression
    // unrelated to that head.
        if (recv_head == null and rfsEnabled() and explicit_receiver == null and
            receiver != null)
        {
            recv_head = b.spliceRecvTy();
        }
    }
    return recv_head;
}

/// Body-declared `var`s a nested closure writes must box, the scan
/// `tryInlineCallWithTypeArgs` runs for an inline fn body.
fn markLambdaBodyBoxedVars(
    b: *FuncBuilder,
    body: *const ast.Block,
    out: *std.ArrayList([]const u8),
) Allocator.Error!void {
    var body_boxed = try ast_scan.computeBoxedVars(b.allocator, body.stmts);
    defer body_boxed.deinit();
    var bit = body_boxed.keyIterator();
    while (bit.next()) |k| {
        if (!b.isBoxed(k.*)) {
            try b.markBoxed(k.*);
            try out.append(b.allocator, k.*);
        }
    }
}

/// The localize target and join point a spliced lambda body returns through: the
/// caller's own inline-return stack is taken aside for the duration, the owner
/// frame's target reinstated over it, and a labeled `return@<fn>` funnels to `end`.
const SplicedLambdaReturn = struct {
    saved: []InlineReturn,
    result: Reg,
    end: ir.BlockId,
    label: ?[]const u8,
};

fn openSplicedLambdaReturn(
    b: *FuncBuilder,
    inherited_subst: std.StringHashMap(*const ast.Expr),
    owner_ret: ?[]InlineReturn,
) Allocator.Error!SplicedLambdaReturn {
    try b.pushInlineLambdaFrame(inherited_subst, b.scopeDepth());
    const saved = try b.takeInlineReturn();
    if (owner_ret) |o| {
        try b.restoreInlineReturn(o);
    }
    const result = b.allocReg();
    const unit0 = try b.emitConst(Const.Unit);
    try b.push(.{ .Move = .{ .dst = result, .src = unit0 } });
    const end = try b.allocBlock();
    const label = b.currentInlineFn();
    if (label) |lbl| {
        try b.pushInlineLambdaRet(lbl, result, end);
    }
    return .{ .saved = saved, .result = result, .end = end, .label = label };
}

/// In a receiver lambda the innermost implicit receiver is the lambda's subject,
/// so bare calls hint its head, not the enclosing fn's receiver; without a subject
/// the hint is the one active at the call site. Returns the parked `this` narrow.
fn installSplicedLambdaHint(
    b: *FuncBuilder,
    subject_reg: ?Reg,
    recv_head: ?[]const u8,
    site_hint: ?FuncBuilder.CallerHint,
) ?[]const u8 {
    if (subject_reg != null) {
        b.setSpliceHint(true, recv_head);
        if (rfsEnabled()) {
            b.setSpliceRecvTy(recv_head);
            b.splice_recv_from_window = recv_head != null;
        }
    } else if (site_hint) |sh| b.setSpliceHint(sh.active, sh.recv);
    return b.setThisNarrow(if (subject_reg != null) null else if (site_hint) |sh| sh.this_narrow else b.thisNarrow());
}

/// The caller-code region a spliced lambda body lowers in: the caller's member
/// scope swapped back in, the subject joined to the runtime enclosing-receiver
/// chain, the enclosing in-progress marks hidden so a same-fn call inside is not
/// self-recursive, and the inline-fn-body flag suspended so the callee's loops
/// cannot capture the lambda's `break`/`continue`.
const SplicedBodyRegion = struct {
    caller_scope: ?FuncBuilder.CallerScopeRestore,
    encl_pushed: bool,
    prev_tower_top: ?Reg,
    prev_decl_base: usize,
    prev_inline_fn_body: u32,
};

fn enterSplicedLambdaBody(b: *FuncBuilder, subject_reg: ?Reg) Allocator.Error!SplicedBodyRegion {
    const caller_scope = try b.enterCallerMemberScope();
    const encl_pushed = subject_reg != null and rfsEnabled();
    const prev_tower_top = b.encl_tower_top;
    if (encl_pushed) {
        try b.push(.{ .EnclosingPush = .{ .src = subject_reg.? } });
        b.encl_tower_depth += 1;
        b.encl_tower_top = subject_reg.?;
    }
    const prev_decl_base = b.inline_stack_visible_base;
    if (!std.mem.eql(u8, inline_state.runtime.envOnce("KLIO_NRG") orelse "1", "0")) {
        b.inline_stack_visible_base = b.inline_stack.items.len;
    }
    // A tail-position call hands its tail position to the lambda's last statement.
    b.tail_pos = b.tail_call_ok;
    const prev_inline_fn_body = b.lowering_inline_fn_body;
    b.lowering_inline_fn_body = 0;
    b.in_spliced_lambda_body += 1;
    return .{
        .caller_scope = caller_scope,
        .encl_pushed = encl_pushed,
        .prev_tower_top = prev_tower_top,
        .prev_decl_base = prev_decl_base,
        .prev_inline_fn_body = prev_inline_fn_body,
    };
}

fn exitSplicedLambdaBody(b: *FuncBuilder, region: SplicedBodyRegion) void {
    b.in_spliced_lambda_body -= 1;
    b.lowering_inline_fn_body = region.prev_inline_fn_body;
    b.inline_stack_visible_base = region.prev_decl_base;
    if (region.encl_pushed) {
        b.encl_tower_depth -= 1;
        b.encl_tower_top = region.prev_tower_top;
    }
    if (region.caller_scope) |cs| b.exitCallerMemberScope(cs);
}

/// Hand every mark, binding and hint this splice parked back to the caller, in the
/// reverse of the order they were taken.
fn restoreSplicedLambdaContext(
    b: *FuncBuilder,
    lam_boxed_here: []const []const u8,
    hidden_binds: []const HiddenBind,
    suspended_rlp: []const []const u8,
    lam_prev_narrow: ?[]const u8,
    lam_prev_active: bool,
    lam_prev_recv: ?[]const u8,
    subject_reg: ?Reg,
    lam_prev_splice_recv: ?[]const u8,
    lam_prev_recv_from_window: bool,
    pushed_band: bool,
    prev_splice: ?build.SpliceWindow,
) Allocator.Error!void {
    for (lam_boxed_here) |n| b.unmarkBoxed(n);
    for (hidden_binds) |hb| b.restoreHiddenBinding(hb.name, hb.h);
    for (suspended_rlp) |k| try b.markReceiverLambdaParam(k);
    _ = b.setThisNarrow(lam_prev_narrow);
    b.setSpliceHint(lam_prev_active, lam_prev_recv);
    if (subject_reg != null and rfsEnabled()) {
        b.setSpliceRecvTy(lam_prev_splice_recv);
        b.splice_recv_from_window = lam_prev_recv_from_window;
    }
    if (pushed_band) _ = b.splice_hidden_bands.pop();
    b.lambda_splice_resolve = prev_splice;
}

/// As `spliceInlineLambda`, with the receiver supplied by the call rather than
/// inferred from the parameter's name-keyed mark, which an enclosing splice of a
/// same-named parameter can suspend.
pub fn spliceInlineLambdaOn(
    b: *FuncBuilder,
    lambda_name: []const u8,
    lam: *const Expr,
    arg_exprs: []const Expr,
    explicit_receiver: ?Reg,
    receiver_expr: ?*const Expr,
) Allocator.Error!Reg {
    if (lam.* != .Lambda) {
        return lowerExpr(b, lam);
    }
    const body = lam.Lambda.body;
    const seat = lambdaSpliceSeat(b, lambda_name, lam, arg_exprs, explicit_receiver);
    const receiver = seat.receiver;
    traceLambdaSpliceEntry(b, lambda_name, lam, arg_exprs, explicit_receiver, seat);

    const arg_regs = try b.allocator.alloc(Reg, arg_exprs.len);
    defer b.allocator.free(arg_regs);
    for (arg_exprs, 0..) |*a, i| {
        arg_regs[i] = try lowerExpr(b, a);
    }
    // A receiver-formed literal invoked through a param-form function type supplies
    // its receiver as the first argument; without the seat it falls into `it`.
    const recv_seat = seat.arg_supplies_recv;
    const arg_shift: usize = if (recv_seat) 1 else 0;
    const eff_arg_regs = arg_regs[arg_shift..];
    const eff_arg_exprs = arg_exprs[arg_shift..];
    // The lambda being spliced was defined in the caller's scope, so its free names
    // resolve there, not against the inline fn's parameter scope. The caller depth is
    // on the frame that substitutes this lambda, not the innermost one: a lambda
    // spliced from inside another belongs to the scope it was written in.
    const defining_frame = b.definingInlineLambdaFrame(lambda_name, lam);
    const splice_caller_depth = if (defining_frame) |di|
        b.inlineLambdaFrameCallerDepth(di)
    else
        b.inlineLambdaCallerDepth();
    const site_hint = if (defining_frame) |di|
        b.inlineLambdaFrameHint(di)
    else
        b.inlineLambdaCallerHint();
    // The enclosing inline fn's param names, collected before this splice pushes its
    // own frame, are the marks to suspend while the caller's body lowers.
    var enclosing_subst_keys: std.ArrayList([]const u8) = .empty;
    defer enclosing_subst_keys.deinit(b.allocator);
    try collectEnclosingSubstKeys(b, &enclosing_subst_keys);
    const counted = inline_state.inlineExpandEnter();
    const subject_prior_this = b.resolve("this");
    try b.pushScope();
    const lambda_own_base = b.scopeDepth() - 1;
    try bindLambdaSubject(b, lambda_name, receiver, recv_seat, arg_regs, lambda_own_base);
    // The splice's parameter bindings inherit the argument expressions' static types,
    // what kotlinc gives the lambda parameter. The splice runs in the caller's
    // builder, so the binding shadows a same-named outer record and restores on exit.
    var shadow_saves: std.ArrayList(ShadowSave) = .empty;
    defer {
        for (shadow_saves.items) |*sv| {
            b.clearLocalDeclType(sv.name);
            if (sv.ty) |t| b.setLocalDeclTypeOwned(sv.name, t) catch {};
            if (sv.init) |e| b.setLocalInitExpr(sv.name, e) catch {};
        }
        shadow_saves.deinit(b.allocator);
    }
    try bindSplicedLambdaParams(b, lam, eff_arg_regs, eff_arg_exprs, &shadow_saves);
    const owner_ret = try ownerLambdaReturnSnapshot(b, defining_frame);
    const inherited_subst = try inheritedLambdaSubst(b, lam, defining_frame);
    const ret = try openSplicedLambdaReturn(b, inherited_subst, owner_ret);
    const result = ret.result;
    // Resolve the lambda body's free names against the caller scopes plus the
    // lambda's own, skipping the inline fn's parameter scopes in between.
    const prev_splice = b.lambda_splice_resolve;
    const pushed_band = try openSpliceResolveWindow(b, splice_caller_depth, lambda_own_base);
    var suspended_rlp: std.ArrayList([]const u8) = .empty;
    defer suspended_rlp.deinit(b.allocator);
    try suspendEnclosingRlpMarks(b, enclosing_subst_keys.items, &suspended_rlp);
    var hidden_binds: std.ArrayList(HiddenBind) = .empty;
    defer hidden_binds.deinit(b.allocator);
    try hideEnclosingParamBindings(b, enclosing_subst_keys.items, &hidden_binds);
    const lam_prev_active = b.spliceHintActive();
    const lam_prev_recv = b.spliceHintRecv();
    // A seated subject, invoked with value-arity plus one positional args, is a
    // subject exactly like a supplied receiver.
    const subject_reg: ?Reg = receiver orelse if (recv_seat) arg_regs[0] else null;
    const recv_head = try splicedSubjectHead(
        b,
        lambda_name,
        lam,
        arg_exprs,
        receiver_expr,
        explicit_receiver,
        receiver,
        recv_seat,
        subject_reg,
    );
    const lam_prev_splice_recv = b.spliceRecvTy();
    const lam_prev_recv_from_window = b.splice_recv_from_window;
    const subject_bind_pushed = subject_reg != null;
    if (subject_bind_pushed) {
        try b.subject_binds.append(b.allocator, .{
            .reg = subject_reg.?,
            .head = recv_head,
            .prior_this = subject_prior_this,
        });
    }
    defer if (subject_bind_pushed) {
        _ = b.subject_binds.pop();
    };
    const lam_prev_narrow = installSplicedLambdaHint(b, subject_reg, recv_head, site_hint);
    // Body-declared `var`s a nested closure writes must box, the scan
    // `tryInlineCallWithTypeArgs` runs for an inline fn body.
    var lam_boxed_here: std.ArrayList([]const u8) = .empty;
    defer lam_boxed_here.deinit(b.allocator);
    try markLambdaBodyBoxedVars(b, &body, &lam_boxed_here);
    const region = try enterSplicedLambdaBody(b, subject_reg);
    const v = try lowerBlock(b, &body);
    exitSplicedLambdaBody(b, region);
    try restoreSplicedLambdaContext(
        b,
        lam_boxed_here.items,
        hidden_binds.items,
        suspended_rlp.items,
        lam_prev_narrow,
        lam_prev_active,
        lam_prev_recv,
        subject_reg,
        lam_prev_splice_recv,
        lam_prev_recv_from_window,
        pushed_band,
        prev_splice,
    );
    try b.push(.{ .Move = .{ .dst = result, .src = v } });
    b.terminate(.{ .Goto = ret.end });
    b.switchTo(ret.end);
    if (region.encl_pushed) try b.push(.{ .EnclosingPop = .{} });
    if (ret.label != null) {
        b.popInlineLambdaRet();
    }
    try b.restoreInlineReturn(ret.saved);
    b.popInlineLambdaFrame();
    try b.popScope();
    if (counted) {
        inline_state.inlineExpandLeave();
    }
    return result;
}

/// Build the effective per-type-parameter argument list for an inline call: explicit
/// `<…>` arguments are kept, and an unspecified reified parameter is inferred by
/// unifying the declared return against the call's expected type.
fn inferReifiedTypeArgs(
    allocator: Allocator,
    f: *const Function,
    explicit: []const TypeRef,
    expected: ?*const TypeRef,
    ordered: []const ?*const Expr,
    bb: ?*const FuncBuilder,
) Allocator.Error![]?TypeRef {
    return inferReifiedTypeArgsRecv(allocator, f, explicit, expected, ordered, bb, null);
}

/// `inferReifiedTypeArgs` with the receiver expression: a reified parameter appearing
/// only in receiver position binds from the receiver's static type, or from the
/// enclosing declaration's receiver for an implicit one.
fn inferReifiedTypeArgsRecv(
    allocator: Allocator,
    f: *const Function,
    explicit: []const TypeRef,
    expected: ?*const TypeRef,
    ordered: []const ?*const Expr,
    bb: ?*const FuncBuilder,
    recv_arg: ?*const Expr,
) Allocator.Error![]?TypeRef {
    var out = try allocator.alloc(?TypeRef, f.type_params.len);
    for (f.type_params, 0..) |_, i| {
        out[i] = if (i < explicit.len) explicit[i] else null;
    }
    var needs_infer = false;
    for (f.type_params, 0..) |tp, i| {
        if (tp.is_reified and out[i] == null) {
            needs_infer = true;
            break;
        }
    }
    if (!needs_infer) return out;

    var tp_names = std.StringHashMap(void).init(allocator);
    defer tp_names.deinit();
    for (f.type_params) |tp| {
        try tp_names.put(tp.name.name, {});
    }
    var subst = std.StringHashMap(TypeRef).init(allocator);
    defer subst.deinit();

    // Unify each declared value-parameter type against its actual argument, so a
    // reified `T` appearing only in a parameter position is inferred first.
    for (f.params, 0..) |*p, i| {
        if (i >= ordered.len) break;
        const arg = ordered[i] orelse continue;
        if (std.c.getenv("KLIO_UNIFY_TRACE") != null)
            std.debug.print("[unify-fn] {s} p{d}={s}:{s}<{d}> arg={s}\n", .{ f.name.name, i, p.name.name, p.ty.name.name, p.ty.type_args.len, @tagName(std.meta.activeTag(arg.*)) });
        try unifyParamAgainstArg(allocator, &p.ty, arg, &tp_names, &subst, bb);
    }

    // Receiver position: unify the declared receiver against the receiver expression.
    if (f.receiver_type) |*rt| {
        if (recv_arg) |ra| {
            try unifyParamAgainstArg(allocator, rt, ra, &tp_names, &subst, bb);
        } else if (bb) |b| {
            if (try inferReceiverType(b, null)) |head| {
                const hd = std.mem.trimEnd(u8, head, "?");
                const synth = TypeRef{
                    .name = .{ .name = hd, .span = rt.span },
                    .nullable = false,
                    .span = rt.span,
                    .type_args = &.{},
                    .function = null,
                    .definitely_non_null = false,
                    .annotations = &.{},
                    .qualified_path = null,
                };
                try unifyTypeParam(rt, &synth, &tp_names, &subst);
            }
        }
    }
    // Fallback: unify the declared return against the call's expected type.
    if (expected) |exp| {
        if (f.return_type) |*ret| {
            if (std.c.getenv("KLIO_UNIFY_TRACE") != null) {
                std.debug.print("[unify-exp] {s} ret={s}<{d}> exp={s}<{d}>", .{ f.name.name, ret.name.name, ret.type_args.len, exp.name.name, exp.type_args.len });
                for (exp.type_args) |*ta| std.debug.print(" [{s}{s}]", .{ if (ta.is_star) "*" else "", ta.ty.name.name });
                std.debug.print("\n", .{});
            }
            try unifyTypeParam(ret, exp, &tp_names, &subst);
        }
    }

    for (f.type_params, 0..) |tp, i| {
        if (out[i] == null) {
            if (subst.get(tp.name.name)) |t| {
                out[i] = t;
            }
        }
        if (std.c.getenv("KLIO_UNIFY_TRACE") != null) {
            std.debug.print("[unify-out] {s} {s} subst={s} enclosing={s}\n", .{ f.name.name, tp.name.name, if (subst.get(tp.name.name)) |t| t.name.name else "-", if (bb) |b| (b.resolveReifiedTypeName(tp.name.name) orelse "-") else "-" });
        }
    }
    // An enclosing splice that already bound a reified parameter of the same name
    // resolves it lexically; solving it through the callee's own bound is inference
    // this does not do.
    if (bb) |b| {
        for (f.type_params, 0..) |tp, i| {
            if (!tp.is_reified) continue;
            // An explicit `<T>` naming an enclosing splice's reified binding is that
            // binding; left bare it reaches the runtime unbound.
            const lookup_name: []const u8 = if (out[i]) |o| blk: {
                if (o.type_args.len != 0 or o.function != null) continue;
                break :blk o.name.name;
            } else tp.name.name;
            const bound = b.resolveReifiedTypeName(lookup_name) orelse continue;
            const nullable = std.mem.endsWith(u8, bound, "?");
            const head = if (nullable) bound[0 .. bound.len - 1] else bound;
            // A generic binding keeps its full spelling: head-reading consumers strip
            // at `<`, and `typeOf<T>()` parses the arguments back out.
            out[i] = .{
                .name = .{ .name = head, .span = tp.name.span },
                .nullable = nullable,
                .span = tp.name.span,
                .type_args = &.{},
                .function = null,
                .definitely_non_null = false,
                .annotations = &.{},
                .qualified_path = null,
            };
        }
    }
    return out;
}

/// Whether a member call to inline extension `name` with these value arguments can
/// bind every reified type parameter by inference alone. Gates splicing a reified
/// inline extension in statement position, where `is T` must check the real class.
pub fn argsBindAllReified(allocator: Allocator, name: []const u8, args: []const Expr, bb: ?*const FuncBuilder) bool {
    const last_is_lambda = args.len > 0 and switch (args[args.len - 1]) {
        .Lambda, .AnonFun => true,
        else => false,
    };
    const trailing_arity: ?usize = if (args.len == 0) null else switch (args[args.len - 1]) {
        .Lambda => |l| if (l.implicit_it) 0 else l.params.len,
        .AnonFun => |af| af.params.len,
        else => null,
    };
    const shape = CallShape{ .want = args.len, .last_is_lambda = last_is_lambda, .trailing_lambda_arity = trailing_arity };
    // Scan the full candidate set: the stub-index pick is blind to member-inline
    // overloads. A candidate qualifies when it takes a receiver, declares a reified
    // parameter, and the value arguments bind every one of them.
    var single_buf: [1]*const ast.Function = undefined;
    // The enclosing extension's declared receiver is evidence for the
    // extensions-only decline in `inlineFnAstForRecvExt`, without which a bare
    // reified call inside an extension loses its argument to the runtime walk.
    var chain_buf: [1][]const u8 = undefined;
    const recv_chain: ?[]const []const u8 = blk: {
        const b2 = bb orelse break :blk null;
        const rt = b2.recvTy() orelse b2.spliceRecvTy() orelse break :blk null;
        chain_buf[0] = rt;
        break :blk chain_buf[0..1];
    };
    const cands: []const *const ast.Function = inline_state.candidatesForName(name) orelse blk: {
        const f = inline_state.inlineFnAstForRecvExt(name, shape, recv_chain, true) orelse return false;
        single_buf[0] = f;
        break :blk single_buf[0..1];
    };
    for (cands) |f| {
        if (f.receiver_type == null and inline_state.inlineMemberOwner(f) == null) continue;
        var any_reified = false;
        for (f.type_params) |tp| {
            if (tp.is_reified) any_reified = true;
        }
        if (!any_reified) continue;
        const ordered = allocator.alloc(?*const Expr, f.params.len) catch return false;
        defer allocator.free(ordered);
        for (ordered, 0..) |*slot, i| slot.* = if (i < args.len) &args[i] else null;
        const probe = inferReifiedTypeArgs(allocator, f, &.{}, null, ordered, bb) catch return false;
        defer allocator.free(probe);
        var all_bound = true;
        for (f.type_params, 0..) |tp, i| {
            if (tp.is_reified and probe[i] == null) all_bound = false;
        }
        if (all_bound) return true;
    }
    return false;
}

/// An argument naming an enclosing splice's parameter carries that parameter's
/// declared type, already reified-substituted.
fn unifySplicedParamArg(
    param_ty: *const TypeRef,
    arg: *const Expr,
    tp_names: *const std.StringHashMap(void),
    subst: *std.StringHashMap(TypeRef),
    bb: ?*const FuncBuilder,
) Allocator.Error!bool {
    if (arg.* == .Path and arg.Path.segments.len == 1) {
        if (bb) |b| {
            // Inside a spliced lambda-argument body the free names are the caller's,
            // so the enclosing splice's same-named parameter is a different binding
            // and would mis-bind the nested reified parameter.
            const in_lambda_window = b.lambda_splice_resolve != null;
            if (!in_lambda_window) if (b.spliceParamTy(arg.Path.segments[0].name)) |aty| {
                if (param_ty.function) |pft| {
                    if (aty.function) |aft| {
                        const n = @min(pft.params.len, aft.params.len);
                        var i: usize = 0;
                        while (i < n) : (i += 1) {
                            try unifyTypeParam(&pft.params[i], &aft.params[i], tp_names, subst);
                        }
                        if (pft.receiver != null and aft.receiver != null) {
                            try unifyTypeParam(&pft.receiver.?, &aft.receiver.?, tp_names, subst);
                        }
                        try unifyTypeParam(&pft.ret, &aft.ret, tp_names, subst);
                    }
                } else {
                    try unifyTypeParam(param_ty, &aty, tp_names, subst);
                }
                return true;
            };
            // A caller local with a declared type binds the parameter to that static
            // type, as kotlinc infers, never to the value's runtime class.
            if (!in_lambda_window and param_ty.function == null) {
                const local_name = arg.Path.segments[0].name;
                if (b.localDeclTypeRef(local_name)) |decl_ref| {
                    // The declared-type record dies with the builder while the
                    // binding outlives it, so copy the type into the module's own
                    // memory with its arguments intact. A type spelled with the
                    // enclosing function's own type parameter has no binding here.
                    if (expr_lower.astTypeRefFromIr(@constCast(b), decl_ref, arg.Path.segments[0].span)) |converted| if (!mentionsBareTypeParam(&converted)) {
                        var decl = try cloneAstTypeRef(b.module.registry.allocator, converted);
                        decl.nullable = decl.nullable or b.localDeclNullable(local_name);
                        try unifyTypeParam(param_ty, &decl, tp_names, subst);
                        return true;
                    };
                }
            }
        }
    }
        return false;
}

/// A function-typed parameter unifies each declared parameter type against the
/// lambda literal's corresponding annotation.
fn unifyFunctionTypedParam(
    param_ty: *const TypeRef,
    arg: *const Expr,
    tp_names: *const std.StringHashMap(void),
    subst: *std.StringHashMap(TypeRef),
) Allocator.Error!bool {
    if (param_ty.function) |ft| {
        if (arg.* == .Lambda) {
            const lam = &arg.Lambda;
            const n = @min(ft.params.len, lam.param_tys.len);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if (lam.param_tys[i]) |*pt| {
                    try unifyTypeParam(&ft.params[i], pt, tp_names, subst);
                }
            }
        }
        // A constructor reference against `(...) -> T` solves `T` as the constructed
        // class; the bound alone would answer `is T` for every subtype.
        if (ft.ret.type_args.len == 0 and ft.ret.function == null and
            tp_names.contains(ft.ret.name.name) and !subst.contains(ft.ret.name.name))
        {
            if (typeConstructorRefName(arg)) |cls| {
                try subst.put(ft.ret.name.name, .{
                    .name = .{ .name = cls, .span = arg.span() },
                    .nullable = false,
                    .span = arg.span(),
                    .type_args = &.{},
                    .function = null,
                    .definitely_non_null = false,
                    .annotations = &.{},
                    .qualified_path = null,
                });
            }
        }
        return true;
    }
        return false;
}

/// The parameter is a type parameter (`cause: T`), and its argument's own type
/// solves it whenever statically evident, a constructor call being the shape that
/// matters, then any argument whose static type lowering already knows. Positive
/// proof only.
fn unifyBareTypeParam(
    allocator: Allocator,
    param_ty: *const TypeRef,
    arg: *const Expr,
    tp_names: *const std.StringHashMap(void),
    subst: *std.StringHashMap(TypeRef),
    bb: ?*const FuncBuilder,
) Allocator.Error!bool {
    // The parameter is a type parameter (`cause: T`), and its argument's own type
    // solves it whenever statically evident, a constructor call being the shape
    // that matters. Positive proof only.
    if (param_ty.type_args.len == 0 and param_ty.function == null and
        tp_names.contains(param_ty.name.name) and !subst.contains(param_ty.name.name))
    {
        if (ctorArgTypeRef(allocator, arg, bb)) |aty| {
            try subst.put(param_ty.name.name, aty.*);
            return true;
        }
        if (std.c.getenv("KLIO_UNIFY_TRACE") != null) {
            const st = staticArgTypeRef(allocator, arg, bb);
            std.debug.print("[unify-tp] {s} arg={s} static={s}<{d}>\n", .{ param_ty.name.name, @tagName(std.meta.activeTag(arg.*)), if (st) |t| t.name.name else "-", if (st) |t| t.type_args.len else 0 });
        }
    // Any argument whose static type lowering already knows solves it too: a
    // literal, a typed local, a declared parameter. Without this an un-spliced
    // body reads a process-global `T`.
        if (staticArgTypeRef(allocator, arg, bb)) |aty| {
            try subst.put(param_ty.name.name, aty.*);
            return true;
        }
    }
        return false;
}

/// A generic-class parameter against an argument the call derivation can type
/// unifies the type arguments positionally.
fn unifyGenericClassParam(
    allocator: Allocator,
    param_ty: *const TypeRef,
    arg: *const Expr,
    tp_names: *const std.StringHashMap(void),
    subst: *std.StringHashMap(TypeRef),
    bb: ?*const FuncBuilder,
) Allocator.Error!bool {
    // A generic-class parameter against an argument the call derivation can type
    // unifies the type arguments positionally.
    if (param_ty.type_args.len != 0 and param_ty.function == null and
        !tp_names.contains(param_ty.name.name) and arg.* == .Call)
    {
        if (staticArgTypeRef(allocator, arg, bb)) |aty| {
            const ph = std.mem.trimEnd(u8, param_ty.name.name, "?");
            const ah = std.mem.trimEnd(u8, aty.name.name, "?");
            const ph_s = if (std.mem.findScalarLast(u8, ph, '.')) |d| ph[d + 1 ..] else ph;
            const ah_s = if (std.mem.findScalarLast(u8, ah, '.')) |d| ah[d + 1 ..] else ah;
            if (std.mem.eql(u8, ph_s, ah_s) and aty.type_args.len == param_ty.type_args.len) {
                for (param_ty.type_args, aty.type_args) |*pa, *aa| {
                    if (pa.is_star or aa.is_star) continue;
                    try unifyTypeParam(&pa.ty, &aa.ty, tp_names, subst);
                }
            }
        }
    }
        return false;
}

/// A companion serializer-factory argument against a `KSerializer<T>` parameter
/// solves `T` from the receiver, the generated factory returning the declaration's
/// own serializer. A prior arm may have bound the parameter from the factory's
/// declared return type, which keeps only a simple head, so the written receiver
/// path overrides an unqualified binding.
fn unifySerializerFactoryParam(
    allocator: Allocator,
    param_ty: *const TypeRef,
    arg: *const Expr,
    tp_names: *const std.StringHashMap(void),
    subst: *std.StringHashMap(TypeRef),
) Allocator.Error!bool {
    // A companion serializer-factory argument against a `KSerializer<T>` parameter
    // solves `T` from the receiver, the generated factory returning the
    // declaration's own serializer. A prior arm may have bound the parameter from
    // the factory's declared return type, which keeps only a simple head, so the
    // written receiver path overrides an unqualified binding.
    const kser_tv: ?[]const u8 = if (param_ty.type_args.len == 1 and !param_ty.type_args[0].is_star and
        std.mem.eql(u8, std.mem.trimEnd(u8, param_ty.name.name, "?"), "KSerializer") and
        tp_names.contains(param_ty.type_args[0].ty.name.name)) param_ty.type_args[0].ty.name.name else null;
    const kser_open = if (kser_tv) |tv| blk: {
        const prior = subst.get(tv) orelse break :blk true;
        break :blk prior.qualified_path == null and std.mem.findScalar(u8, prior.name.name, '.') == null;
    } else false;
    if (kser_open) kser: {
        if (arg.* == .Call and arg.Call.callee.* == .Member and
            std.mem.eql(u8, arg.Call.callee.Member.name.name, "serializer"))
        {
            // The receiver names the class: a bare name, or a dotted member chain
            // whose spelling the splice resolves as written.
            if (classPathSpelling(allocator, arg.Call.callee.Member.receiver)) |cls_path| {
                // The bound name is the last segment; a dotted spelling rides as the
                // qualified path the splice resolves to the lifted class.
                const last = if (std.mem.findScalarLast(u8, cls_path, '.')) |d| cls_path[d + 1 ..] else cls_path;
                if (last.len != 0 and std.ascii.isUpper(last[0])) {
                    const qualified: ?[]const u8 = if (last.len == cls_path.len) null else cls_path;
                    if (subst.get(kser_tv.?)) |prior| {
                        if (std.mem.eql(u8, prior.name.name, last)) {
                            if (qualified == null) break :kser;
                            var merged = prior;
                            merged.qualified_path = qualified;
                            try subst.put(kser_tv.?, merged);
                            return true;
                        }
                    }
                    try subst.put(param_ty.type_args[0].ty.name.name, .{
                        .name = .{ .name = last, .span = arg.span() },
                        .nullable = false,
                        .span = arg.span(),
                        .type_args = &.{},
                        .function = null,
                        .definitely_non_null = false,
                        .annotations = &.{},
                        .qualified_path = qualified,
                    });
                    return true;
                }
            }
        }
    }
        return false;
}

/// A class-literal argument against a `KClass<T>` parameter solves `T = C`.
fn unifyClassLiteralParam(
    param_ty: *const TypeRef,
    arg: *const Expr,
    tp_names: *const std.StringHashMap(void),
    subst: *std.StringHashMap(TypeRef),
) Allocator.Error!bool {
    // A class-literal argument against a `KClass<T>` parameter solves `T = C`.
    if (param_ty.type_args.len == 1 and !param_ty.type_args[0].is_star and
        std.mem.eql(u8, std.mem.trimEnd(u8, param_ty.name.name, "?"), "KClass") and
        tp_names.contains(param_ty.type_args[0].ty.name.name) and
        !subst.contains(param_ty.type_args[0].ty.name.name))
    {
        if (arg.* == .MemberRef and std.mem.eql(u8, arg.MemberRef.name.name, "class") and
            arg.MemberRef.receiver.* == .Path and arg.MemberRef.receiver.Path.segments.len >= 1)
        {
            const segs = arg.MemberRef.receiver.Path.segments;
            const cls_name = segs[segs.len - 1].name;
            if (cls_name.len != 0 and std.ascii.isUpper(cls_name[0])) {
                try subst.put(param_ty.type_args[0].ty.name.name, .{
                    .name = .{ .name = cls_name, .span = arg.span() },
                    .nullable = false,
                    .span = arg.span(),
                    .type_args = &.{},
                    .function = null,
                    .definitely_non_null = false,
                    .annotations = &.{},
                    .qualified_path = null,
                });
                return true;
            }
        }
    }
        return false;
}

/// The parameter's own type arguments mention a type parameter, so the argument's
/// generic type, its declaration's supertype list, a local object literal's
/// supertype, the local's declared class, and finally its lowered record are
/// tried in that order.
fn unifyTypeArgumentsAgainstArg(
    allocator: Allocator,
    param_ty: *const TypeRef,
    arg: *const Expr,
    tp_names: *const std.StringHashMap(void),
    subst: *std.StringHashMap(TypeRef),
    bb: ?*const FuncBuilder,
) Allocator.Error!bool {
    if (param_ty.type_args.len != 0) {
        var mentions_tp = false;
        for (param_ty.type_args) |*ta| {
            if (!ta.is_star and tp_names.contains(ta.ty.name.name)) {
                mentions_tp = true;
                break;
            }
        }
        if (!mentions_tp) return true;
        if (try argGenericTypeRef(allocator, arg, 0)) |aty| {
            try unifyTypeParam(param_ty, aty, tp_names, subst);
            return true;
        }
        // The argument names a declaration, so the parameter's type argument comes
        // from that declaration's supertype list.
        if (argDeclSupertypeMatching(arg, param_ty.name.name, bb)) |sup| {
            try unifyTypeParam(param_ty, sup, tp_names, subst);
            return true;
        }
    // A local initialized by an object literal carries its supertype the same way,
    // the only place its type arguments are written.
        if (localObjectSupertypeMatching(arg, param_ty.name.name, bb)) |sup| {
            try unifyTypeParam(param_ty, sup, tp_names, subst);
            return true;
        }
    // A local whose declared type names a class solves through that class's supertype
    // list, binding `T` to the head, all a reified consumer can read.
        try declTypeSupertypeBind(param_ty, arg, tp_names, subst, bb);
    // Last: the argument's statically recorded type, head-matched.
        try unifyLoweredTypeParam(param_ty, arg, tp_names, subst, bb);
    }
        return false;
}

/// Unify one declared value-parameter type against its actual argument expression,
/// recording reified type-parameter solutions in `subst`. A function-typed parameter
/// unifies each declared parameter type against the lambda literal's corresponding
/// annotation; a generic-class parameter unifies against the argument's statically
/// evident generic type, from explicit type args or a property's declared type.
fn unifyParamAgainstArg(
    allocator: Allocator,
    param_ty: *const TypeRef,
    arg: *const Expr,
    tp_names: *const std.StringHashMap(void),
    subst: *std.StringHashMap(TypeRef),
    bb: ?*const FuncBuilder,
) Allocator.Error!void {
    // An argument naming an enclosing splice's parameter carries that parameter's
    // declared type, already reified-substituted.
    if (try unifySplicedParamArg(param_ty, arg, tp_names, subst, bb)) return;
    if (try unifyFunctionTypedParam(param_ty, arg, tp_names, subst)) return;
    if (try unifyBareTypeParam(allocator, param_ty, arg, tp_names, subst, bb)) return;
    if (try unifyGenericClassParam(allocator, param_ty, arg, tp_names, subst, bb)) return;
    if (try unifySerializerFactoryParam(allocator, param_ty, arg, tp_names, subst)) return;
    if (try unifyClassLiteralParam(param_ty, arg, tp_names, subst)) return;
    if (try unifyTypeArgumentsAgainstArg(allocator, param_ty, arg, tp_names, subst, bb)) return;
}

/// The class an argument constructs, as a `TypeRef`: the one argument shape whose
/// type is evident without a type checker.
/// `callerOwnerClass` is the caller's lexical owner while a splice infers its
/// reified bindings after the callee frame is pushed.
var splice_lexical_owner: ?[]const u8 = null;

/// The caller's lexical owner while a splice binds its arguments, for derivations
/// that rename nested classes through the scope the argument was written in.
pub fn spliceLexicalOwner() ?[]const u8 {
    return splice_lexical_owner;
}

/// The dotted class spelling an expression names when every segment is capitalised.
pub fn classPathSpelling(allocator: Allocator, e: *const Expr) ?[]const u8 {
    var chain: std.ArrayList([]const u8) = .empty;
    defer chain.deinit(allocator);
    var cur: *const Expr = e;
    while (true) {
        switch (cur.*) {
            .Member => |*mm| {
                chain.append(allocator, mm.name.name) catch return null;
                cur = mm.receiver;
            },
            .Path => |*pp| {
                var i = pp.segments.len;
                while (i > 0) : (i -= 1) chain.append(allocator, pp.segments[i - 1].name) catch return null;
                break;
            },
            else => return null,
        }
    }
    if (chain.items.len == 0) return null;
    var buf: std.ArrayList(u8) = .empty;
    var i = chain.items.len;
    while (i > 0) : (i -= 1) {
        const seg = chain.items[i - 1];
        if (seg.len == 0 or !std.ascii.isUpper(seg[0])) return null;
        if (i != chain.items.len) buf.append(allocator, '.') catch return null;
        buf.appendSlice(allocator, seg) catch return null;
    }
    return buf.toOwnedSlice(allocator) catch null;
}

pub fn ctorArgTypeRef(allocator: Allocator, arg: *const Expr, bb: ?*const FuncBuilder) ?*const TypeRef {
    const call = switch (arg.*) {
        .Call => |*c| c,
        else => return null,
    };
    // The callee is a bare name, a dotted path, or a member chain over class names.
    var segs: std.ArrayList(ast.Ident) = .empty;
    defer segs.deinit(allocator);
    switch (call.callee.*) {
        .Path => |*p| segs.appendSlice(allocator, p.segments) catch return null,
        .Member => |*m| {
            var cur: *const Expr = call.callee;
            var chain: std.ArrayList(ast.Ident) = .empty;
            defer chain.deinit(allocator);
            while (true) {
                switch (cur.*) {
                    .Member => |*mm| {
                        chain.append(allocator, mm.name) catch return null;
                        cur = mm.receiver;
                    },
                    .Path => |*pp| {
                        var i = pp.segments.len;
                        while (i > 0) : (i -= 1) chain.append(allocator, pp.segments[i - 1]) catch return null;
                        break;
                    },
                    else => return null,
                }
            }
            _ = m;
            var i = chain.items.len;
            while (i > 0) : (i -= 1) {
                const id = chain.items[i - 1];
                if (id.name.len == 0 or !std.ascii.isUpper(id.name[0])) return null;
                segs.append(allocator, id) catch return null;
            }
        },
        else => return null,
    }
    if (segs.items.len == 0) return null;
    const head = segs.items[segs.items.len - 1];
    if (head.name.len == 0 or !std.ascii.isUpper(head.name[0])) return null;
    const b = bb orelse return null;
    // A dotted constructor path names the nested class through its outer, and the
    // bound name keeps the spelling the splice resolves.
    var written_name: []const u8 = head.name;
    var cid: ?ir.ClassId = null;
    if (segs.items.len >= 2) {
        var buf: std.ArrayList(u8) = .empty;
        for (segs.items, 0..) |seg, si| {
            if (si > 0) buf.append(allocator, '.') catch return null;
            buf.appendSlice(allocator, seg.name) catch return null;
        }
        const dotted = buf.toOwnedSlice(allocator) catch return null;
        // The nesting tree is built at VM setup; at lowering the dotted spelling
        // resolves as a `.`-aligned suffix of a registered fqn.
        if (b.module.classIdByQualifiedSuffix(dotted)) |nid| {
            cid = nid;
            written_name = dotted;
        } else {
            // The lifted class table keys a nested class `Outer$D`.
            const mangled = std.mem.replaceOwned(u8, allocator, dotted, ".", "$") catch return null;
            if (b.module.classId(mangled)) |nid| {
                cid = nid;
                written_name = dotted;
            }
        }
        if (std.c.getenv("KLIO_CTORARG_TRACE") != null)
            std.debug.print("[ctorarg] dotted={s} cid={?d}\n", .{ dotted, if (cid) |c| c.int() else null });
    }
    // A nested class referenced bare inside its declaring subtree lives in the class
    // table under its lifted name, and the enclosing scope's own classifier wins
    // over the package-level index.
    if (cid == null) cid = blk: {
        const owner = splice_lexical_owner orelse b.ownerClass();
        const renamed = expr_lower.scopeTypeRenameFrom(@constCast(b), owner, head.name, head.span.file.int()) orelse break :blk null;
        break :blk b.module.classId(renamed);
    };
    if (cid == null) cid = b.module.classIdIndexed(head.name, b.self_package, head.span.file) orelse
        b.module.classId(head.name);
    if (cid == null) return null;
    // A lifted class is referenced by its lifted identity, which the flat name table
    // cannot confuse.
    if (cid.?.int() < b.module.classes.items.len) {
        const lifted = b.module.classes.items[cid.?.int()].name;
        if (!std.mem.eql(u8, lifted, written_name) and std.mem.findScalar(u8, lifted, '$') != null and
            std.mem.findScalar(u8, written_name, '.') == null)
        {
            written_name = lifted;
        }
    }
    var targs = allocator.alloc(ast.TypeArg, call.type_args.len) catch return null;
    for (call.type_args, 0..) |ta, i| {
        targs[i] = .{ .variance = .Invariant, .is_star = false, .ty = ta, .span = ta.span };
    }
    // A generic class constructed without explicit type arguments infers them from
    // the constructor arguments, each class type parameter binding through the first
    // primary parameter declared as that bare variable.
    if (call.type_args.len == 0) infer: {
        const cls = if (cid.?.int() < b.module.classes.items.len) &b.module.classes.items[cid.?.int()] else break :infer;
        if (cls.type_params.len == 0) break :infer;
        const inferred = allocator.alloc(ast.TypeArg, cls.type_params.len) catch break :infer;
        var all = true;
        for (cls.type_params, 0..) |tp, ti| {
            var solved: ?*const TypeRef = null;
            for (cls.primary_params, 0..) |*pp, pi| {
                if (pi >= call.args.len) break;
                // `value: T?` binds `T` from its argument as `value: T` does.
                if (!std.mem.eql(u8, std.mem.trimEnd(u8, pp.ty.name, "?"), tp)) continue;
                solved = staticArgTypeRef(allocator, &call.args[pi], bb) orelse ctorArgTypeRef(allocator, &call.args[pi], bb);
                if (solved != null) break;
            }
            const st = solved orelse {
                all = false;
                break;
            };
            inferred[ti] = .{ .variance = .Invariant, .is_star = false, .ty = st.*, .span = st.span };
        }
        if (all) targs = inferred;
    }
    // Still head-only for a generic class: the static constructor derivation knows
    // shapes this position-by-parameter inference does not.
    if (targs.len == 0 and call.type_args.len == 0) fallback: {
        const cls = if (cid.?.int() < b.module.classes.items.len) &b.module.classes.items[cid.?.int()] else break :fallback;
        if (cls.type_params.len == 0) break :fallback;
        const derived = (expr_lower.ctorInitTypeRef(@constCast(b), arg) catch null) orelse break :fallback;
        if (derived.args.len == 0) break :fallback;
        const as_ast = expr_lower.astTypeRefFromIr(@constCast(b), derived, head.span) orelse break :fallback;
        targs = as_ast.type_args;
    }
    // The class resolved in scope is the binding's identity, so a bare name shared
    // with another class carries the resolved class's qualified name.
    const qualified: ?[]const u8 = blk: {
        const cls = if (cid.?.int() < b.module.classes.items.len) &b.module.classes.items[cid.?.int()] else break :blk null;
        if (std.mem.eql(u8, cls.fqn, written_name)) break :blk null;
        if (std.mem.findScalar(u8, cls.fqn, '.') == null) break :blk null;
        if (b.module.uniqueClassIdBySimpleName(head.name) != null) break :blk null;
        break :blk cls.fqn;
    };
    const out = allocator.create(TypeRef) catch return null;
    out.* = .{
        .name = .{ .name = written_name, .span = head.span },
        .nullable = false,
        .span = head.span,
        .type_args = targs,
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = qualified,
    };
    return out;
}

/// The argument's statically known type, for solving a parameter that is a type
/// parameter. Head only, since a reified `T` is read as `T::class` or `is T`, both
/// erasing type arguments. A head that is itself a type parameter answers nothing.
pub fn staticArgTypeRef(allocator: Allocator, arg: *const Expr, bb: ?*const FuncBuilder) ?*const TypeRef {
    const b = bb orelse return null;
    // A call argument types through the static call derivation when the lazy typer
    // has no memo for it.
    var explicit_needed = false;
    const ty = expr_lower.argDeclTypeRefLazy(@constCast(b), arg) orelse blk: {
        // A bare `object` reference types as the object's class. Argument typing
        // only: the general lazy typer must not type the name, or receiver lowering
        // reads it as a field of the enclosing `this`.
        if (expr_lower.objectRefTypeRef(@constCast(b), arg)) |t| break :blk t;
        if (arg.* != .Call) return null;
        const derived_opt = static_call_type.staticCallReturnTypeRef(@constCast(b), arg) catch null;
        if (std.c.getenv("KLIO_UNIFY_TRACE") != null) std.debug.print("[satr] call callee={s} derived={?s} nta={d} dargs={d} darg0={s}\n", .{ @tagName(std.meta.activeTag(arg.Call.callee.*)), if (derived_opt) |d| d.name else null, arg.Call.type_args.len, if (derived_opt) |d| d.args.len else 0, if (derived_opt) |d| (if (d.args.len != 0) d.args[0].name else "-") else "-" });
        const derived = derived_opt orelse return null;
        // A derived return whose arguments are still the callee's own type
        // parameters says nothing the head does not. An explicit type-argument list
        // instantiates them instead.
        for (derived.args) |a| {
            var ah = std.mem.trimEnd(u8, a.name, "?");
            if (std.mem.findScalar(u8, ah, '<')) |lt| ah = ah[0..lt];
            const dangling = ah.len == 0 or (ah.len <= 2 and isAllUpper(ah)) or b.isTypeParam(ah) or ir.parseClassTypeParamIdentity(ah) != null;
            if (dangling or (std.mem.eql(u8, ah, "*") and arg.Call.type_args.len != 0)) {
                if (arg.Call.type_args.len != 0) {
                    explicit_needed = true;
                    break;
                }
                return null;
            }
        }
        break :blk derived;
    };
    const head = std.mem.trimEnd(u8, ty.name, "?");
    if (head.len == 0) return null;
    if (std.mem.findAny(u8, head, "<>-(") != null) return null;
    if (head.len <= 2 and isAllUpper(head)) return null;
    // A recorded type spelled nullable is nullable whether or not the flag rode along.
    const spelled_nullable = head.len != ty.name.len;
    const out = allocator.create(TypeRef) catch return null;
    if (explicit_needed) {
        if (explicitCallInstantiation(b, arg, head)) |full| {
            out.* = full;
            return out;
        }
        return null;
    }
    // The recorded type keeps its arguments, which a reified consumer needs to
    // materialise the KType's arguments.
    if (ty.args.len != 0) {
        if (expr_lower.astTypeRefFromIr(@constCast(b), ty, arg.span())) |full| {
            out.* = full;
            return out;
        }
    }
    // An explicit type-argument list on the call instantiates the callee's generic
    // return directly.
    if (ty.args.len == 0 and arg.* == .Call and arg.Call.type_args.len != 0) {
        if (explicitCallInstantiation(b, arg, head)) |full| {
            out.* = full;
            return out;
        }
    }
    out.* = .{
        .name = .{ .name = head, .span = arg.span() },
        .nullable = ty.nullable or spelled_nullable,
        .span = arg.span(),
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
    return out;
}

/// The callee's declared generic return instantiated by the call's explicit type
/// arguments, when every same-named candidate of that arity and return head agrees.
fn explicitCallInstantiation(b: *const FuncBuilder, arg: *const Expr, head: []const u8) ?TypeRef {
    const call = arg.Call;
    const cname: []const u8 = switch (call.callee.*) {
        .Member => |m| m.name.name,
        .Path => |p| p.segments[p.segments.len - 1].name,
        else => return null,
    };
    const head_s = if (std.mem.findScalarLast(u8, head, '.')) |d| head[d + 1 ..] else head;
    var found: ?TypeRef = null;
    const tr = std.c.getenv("KLIO_UNIFY_TRACE") != null;
    if (tr) std.debug.print("[eci] {s} head={s} cands={d} nta={d}\n", .{ cname, head, b.module.funcsBySimpleName(cname).len, call.type_args.len });
    for (b.module.funcsBySimpleName(cname)) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        const tp_opt = b.module.registry.func_type_params.get(fid);
        if (tr) std.debug.print("[eci]   {s} tps={d} ret={s}<{d}>\n", .{ f.fqn, if (tp_opt) |l| l.items.len else 0, f.return_ty.name, f.return_ty.args.len });
        const tp = tp_opt orelse continue;
        if (tp.items.len != call.type_args.len) continue;
        var rh = std.mem.trimEnd(u8, f.return_ty.name, "?");
        if (std.mem.findScalar(u8, rh, '<')) |lt| rh = rh[0..lt];
        const rh_s = if (std.mem.findScalarLast(u8, rh, '.')) |d| rh[d + 1 ..] else rh;
        if (!std.mem.eql(u8, rh_s, head_s)) continue;
        if (f.return_ty.args.len == 0) continue;
        const targs = b.allocator.alloc(ast.TypeArg, f.return_ty.args.len) catch return null;
        var ok = true;
        for (f.return_ty.args, targs) |*ra, *ta| {
            var rah = std.mem.trimEnd(u8, ra.name, "?");
            if (std.mem.findScalar(u8, rah, '<')) |lt| rah = rah[0..lt];
            var pick: ?usize = null;
            for (tp.items, 0..) |pn, pi| {
                if (std.mem.eql(u8, pn, rah)) pick = pi;
            }
            const pi = pick orelse {
                ok = false;
                break;
            };
            const src = &call.type_args[pi];
            if (src.name.name.len == 0 or b.isTypeParam(src.name.name)) {
                ok = false;
                break;
            }
            var t = src.*;
            if (ra.nullable) t.nullable = true;
            ta.* = .{ .variance = .Invariant, .is_star = false, .ty = t, .span = src.span };
        }
        if (!ok) {
            b.allocator.free(targs);
            continue;
        }
        const cand = TypeRef{
            .name = .{ .name = head, .span = arg.span() },
            .nullable = f.return_ty.nullable,
            .span = arg.span(),
            .type_args = targs,
            .function = null,
            .definitely_non_null = false,
            .annotations = &.{},
            .qualified_path = null,
        };
        if (found) |prev| {
            // Same-shaped candidates agree; a different shape is ambiguous.
            if (prev.type_args.len != cand.type_args.len) return null;
            for (prev.type_args, cand.type_args) |*pa, *ca| {
                if (!std.mem.eql(u8, pa.ty.name.name, ca.ty.name.name) or pa.ty.nullable != ca.ty.nullable) return null;
            }
            b.allocator.free(targs);
            continue;
        }
        found = cand;
    }
    return found;
}

fn isAllUpper(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isUpper(c) and !std.ascii.isDigit(c)) return false;
    }
    return true;
}


/// The supertype whose head equals `want` of the class or object an argument path
/// names. Null when the argument is not a plain declaration reference or declares
/// no matching supertype.
fn argDeclSupertypeMatching(arg: *const Expr, want: []const u8, bb: ?*const FuncBuilder) ?*const TypeRef {
    const name: []const u8 = switch (arg.*) {
        .Path => |*p| blk: {
            if (p.segments.len == 0) break :blk "";
            break :blk p.segments[p.segments.len - 1].name;
        },
        .Member => |*m| m.name.name,
        else => "",
    };
    if (name.len == 0) return null;
    // A nested declaration named like a library class lifts under a mangled name,
    // and the scope alias resolves the bare spelling to it ahead of the index.
    const scoped: ?[]const ast.TypeRef = blk: {
        const b = bb orelse break :blk null;
        if (arg.* != .Path or arg.Path.segments.len != 1) break :blk null;
        const renamed = expr_lower.scopeTypeRename(b, name, arg.Path.segments[0].span.file.int()) orelse break :blk null;
        break :blk inline_state.classSupertypeRefs(renamed);
    };
    const sups = scoped orelse inline_state.classSupertypeRefs(name) orelse return null;
    for (sups) |*sup| {
        if (sup.type_args.len == 0) continue;
        const sup_head = if (std.mem.findScalarLast(u8, sup.name.name, '.')) |d| sup.name.name[d + 1 ..] else sup.name.name;
        if (std.mem.eql(u8, sup_head, want)) return sup;
    }
    return null;
}

/// Solve `param_ty`'s type-parameter arguments from the argument's recorded static
/// type, a lowered `ir.TypeRef`: match the head and bind each parameter position to
/// the corresponding argument's own head, enough for a reified parameter.
fn unifyLoweredTypeParam(
    param_ty: *const TypeRef,
    arg: *const Expr,
    tp_names: *const std.StringHashMap(void),
    subst: *std.StringHashMap(TypeRef),
    bb: ?*const FuncBuilder,
) Allocator.Error!void {
    const b = bb orelse return;
    const ty = expr_lower.argDeclTypeRefLazy(@constCast(b), arg) orelse return;
    var head = std.mem.trimEnd(u8, ty.name, "?");
    if (std.mem.findScalar(u8, head, '<')) |lt| head = head[0..lt];
    if (!std.mem.eql(u8, head, param_ty.name.name)) return;
    const n = @min(param_ty.type_args.len, ty.args.len);
    for (param_ty.type_args[0..n], ty.args[0..n]) |*pa, *aa| {
        if (pa.is_star) continue;
        if (!tp_names.contains(pa.ty.name.name)) continue;
        if (subst.contains(pa.ty.name.name)) continue;
        const ah = std.mem.trimEnd(u8, aa.name, "?");
        if (ah.len == 0) continue;
        if (std.mem.findAny(u8, ah, "<>-(") != null) continue;
        if (ah.len <= 2 and isAllUpper(ah)) continue;
        try subst.put(pa.ty.name.name, .{
            .name = .{ .name = ah, .span = arg.span() },
            .nullable = aa.nullable,
            .span = arg.span(),
            .type_args = &.{},
            .function = null,
            .definitely_non_null = false,
            .annotations = &.{},
            .qualified_path = null,
        });
    }
}

/// Bind `param_ty`'s type-parameter arguments from the class supertype of the
/// argument's recorded declared type, heads only.
fn declTypeSupertypeBind(
    param_ty: *const TypeRef,
    arg: *const Expr,
    tp_names: *const std.StringHashMap(void),
    subst: *std.StringHashMap(TypeRef),
    bb: ?*const FuncBuilder,
) Allocator.Error!void {
    const b = bb orelse return;
    if (arg.* != .Path or arg.Path.segments.len != 1) return;
    const nm = arg.Path.segments[0].name;
    // A bare name that is an enclosing class's member property reads its registered
    // head; a local reads its recorded declared type.
    const decl_name: []const u8 = if (b.localDeclTypeRef(nm)) |d| d.name else blk: {
        if (b.resolve(nm) != null) return;
        const owner = b.ownerClass() orelse return;
        const heads = b.module.registry.class_prop_type_heads;
        if (heads.get(.{ .a = owner, .b = nm })) |h| break :blk h;
        const chain: []const []const u8 = b.module.registry.class_super_names.get(owner) orelse return;
        for (chain) |cls| {
            if (heads.get(.{ .a = cls, .b = nm })) |h| break :blk h;
        }
        return;
    };
    var head = std.mem.trimEnd(u8, decl_name, "?");
    if (std.mem.findScalar(u8, head, '<')) |lt| head = head[0..lt];
    if (head.len == 0) return;
    const sups = inline_state.classSupertypeRefs(head) orelse return;
    for (sups) |*sup| {
        if (sup.type_args.len == 0) continue;
        if (!std.mem.eql(u8, sup.name.name, param_ty.name.name)) continue;
        const n = @min(param_ty.type_args.len, sup.type_args.len);
        for (param_ty.type_args[0..n], sup.type_args[0..n]) |*pa, *sa| {
            if (pa.is_star or sa.is_star) continue;
            if (!tp_names.contains(pa.ty.name.name)) continue;
            if (subst.contains(pa.ty.name.name)) continue;
            const ah = sa.ty.name.name;
            if (ah.len == 0) continue;
            if (ah.len <= 2 and isAllUpper(ah)) continue;
            try subst.put(pa.ty.name.name, .{
                .name = .{ .name = ah, .span = arg.span() },
                .nullable = sa.ty.nullable,
                .span = arg.span(),
                .type_args = &.{},
                .function = null,
                .definitely_non_null = false,
                .annotations = &.{},
                .qualified_path = null,
            });
        }
        return;
    }
}

/// The supertype matching `want` of the object literal a local was initialized
/// with. `argDeclSupertypeMatching` reads a named declaration's supertypes; this
/// reads an anonymous one through the local that holds it.
fn localObjectSupertypeMatching(arg: *const Expr, want: []const u8, bb: ?*const FuncBuilder) ?*const TypeRef {
    if (arg.* != .Path or arg.Path.segments.len != 1) return null;
    const b = bb orelse return null;
    const init = b.localInitExpr(arg.Path.segments[0].name) orelse return null;
    if (init.* != .ObjectExpr) return null;
    for (init.ObjectExpr.supertypes) |*sup| {
        if (sup.type_args.len == 0) continue;
        if (std.mem.eql(u8, sup.name.name, want)) return sup;
    }
    return null;
}

/// The argument expression's generic type when statically evident: a constructor or
/// factory call with explicit `<…>` type args, or a property access resolvable
/// through the member-property AST registry. Inference stays positive-proof only.
fn argGenericTypeRef(allocator: Allocator, arg: *const Expr, depth: usize) Allocator.Error!?*const TypeRef {
    if (depth > 4) return null;
    switch (arg.*) {
        .Call => |*c| {
            if (c.type_args.len == 0) return null;
            if (c.callee.* != .Path) return null;
            const segs = c.callee.Path.segments;
            if (segs.len == 0) return null;
            const head = segs[segs.len - 1];
            if (head.name.len == 0 or !std.ascii.isUpper(head.name[0])) return null;
            const targs = try allocator.alloc(ast.TypeArg, c.type_args.len);
            for (c.type_args, 0..) |ta, i| {
                targs[i] = .{ .variance = .Invariant, .is_star = false, .ty = ta, .span = ta.span };
            }
            const out = try allocator.create(TypeRef);
            out.* = .{
                .name = head,
                .nullable = false,
                .span = head.span,
                .type_args = targs,
                .function = null,
                .definitely_non_null = false,
                .annotations = &.{},
                .qualified_path = null,
            };
            return out;
        },
        .Path => |*p| {
            if (p.segments.len < 2) return null;
            const owner = p.segments[p.segments.len - 2].name;
            const name = p.segments[p.segments.len - 1].name;
            return propGenericTypeRef(allocator, owner, name, depth);
        },
        .Member => |*m| {
            if (m.receiver.* != .Path) return null;
            const rs = m.receiver.Path.segments;
            if (rs.len == 0) return null;
            return propGenericTypeRef(allocator, rs[rs.len - 1].name, m.name.name, depth);
        },
        else => return null,
    }
}

/// Resolve property `owner.name`'s generic type through the registered property
/// AST: the declared type, the getter's return annotation, or an expression body.
fn propGenericTypeRef(allocator: Allocator, owner: []const u8, name: []const u8, depth: usize) Allocator.Error!?*const TypeRef {
    const p = inline_state.memberPropAst(owner, name) orelse return null;
    if (p.ty) |*t| {
        if (t.type_args.len != 0) return t;
    }
    if (p.getter) |g| {
        if (g.return_type) |*rt| {
            if (rt.type_args.len != 0) return rt;
        }
        if (g.body == .Expr) return argGenericTypeRef(allocator, &g.body.Expr, depth + 1);
    }
    if (p.init) |*init| return argGenericTypeRef(allocator, init, depth + 1);
    return null;
}

/// Unify a declared type, which may mention type parameters, against a concrete
/// actual type, recording each solution. A declared bare type parameter binds to
/// the whole actual type; matching heads recurse positionally through arguments.
fn mentionsBareTypeParam(t: *const ast.TypeRef) bool {
    if (expr_lower.bareTypeParamHead(t.name.name)) return true;
    for (t.type_args) |a| {
        if (!a.is_star and mentionsBareTypeParam(&a.ty)) return true;
    }
    return false;
}

/// Deep-copies a type reference (name and type arguments) into `alloc`.
fn cloneAstTypeRef(alloc: std.mem.Allocator, t: ast.TypeRef) std.mem.Allocator.Error!ast.TypeRef {
    var out = t;
    out.name.name = try alloc.dupe(u8, t.name.name);
    const args = try alloc.alloc(ast.TypeArg, t.type_args.len);
    for (t.type_args, args) |a, *o| {
        o.* = a;
        o.ty = try cloneAstTypeRef(alloc, a.ty);
    }
    out.type_args = args;
    return out;
}

fn unifyTypeParam(
    decl: *const TypeRef,
    actual: *const TypeRef,
    tp_names: *const std.StringHashMap(void),
    subst: *std.StringHashMap(TypeRef),
) Allocator.Error!void {
    if (decl.type_args.len == 0 and tp_names.contains(decl.name.name)) {
        // A star projection binds nothing.
        if (std.mem.eql(u8, actual.name.name, "*")) return;
        if (!subst.contains(decl.name.name)) {
            // A use-site projection binds the projected type, never the projection
            // marker: `T = String`.
            var bound = actual.*;
            if (std.mem.startsWith(u8, bound.name.name, "out#")) {
                bound.name.name = bound.name.name["out#".len..];
            } else if (std.mem.startsWith(u8, bound.name.name, "in#")) {
                bound.name.name = bound.name.name["in#".len..];
            }
            try subst.put(decl.name.name, bound);
        }
        return;
    }
    const n = @min(decl.type_args.len, actual.type_args.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const d = &decl.type_args[i];
        const a = &actual.type_args[i];
        if (!d.is_star and !a.is_star) {
            try unifyTypeParam(&d.ty, &a.ty, tp_names, subst);
        }
    }
}

/// Add `ty`'s head name (and its generic arguments', recursively) to `out`.
fn putTypeRefNames(ty: *const TypeRef, out: *ast_scan.StringSet) Allocator.Error!void {
    try out.put(ty.name.name, {});
    for (ty.type_args) |*targ| {
        if (!targ.is_star) try putTypeRefNames(&targ.ty, out);
    }
    if (ty.function) |ft| {
        if (ft.receiver) |*r| try putTypeRefNames(r, out);
        for (ft.params) |*p| try putTypeRefNames(p, out);
        try putTypeRefNames(&ft.ret, out);
    }
}

/// Collect the type names a body resolves at runtime: `as T` and `is T` targets,
/// call-site type arguments, and `when` is-patterns. With `collectPathIdents` this
/// decides whether a reified inline extension's body ever reads a reified parameter.
fn collectRuntimeTypeNames(e: *const Expr, out: *ast_scan.StringSet) Allocator.Error!void {
    switch (e.*) {
        .As => |u| {
            try putTypeRefNames(&u.ty, out);
            try collectRuntimeTypeNames(u.expr, out);
        },
        .IsCheck => |u| {
            try putTypeRefNames(&u.ty, out);
            try collectRuntimeTypeNames(u.expr, out);
        },
        .Call => |c| {
            for (c.type_args) |*ta| try putTypeRefNames(ta, out);
            try collectRuntimeTypeNames(c.callee, out);
            for (c.args) |*a| try collectRuntimeTypeNames(a, out);
        },
        .When => |w| {
            if (w.subject) |s| try collectRuntimeTypeNames(s, out);
            for (w.branches) |*br| {
                for (br.patterns) |*p| switch (p.kind) {
                    .IsType, .NotIsType => |ty| try putTypeRefNames(&ty, out),
                    .Value, .InRange, .NotInRange => |*ve| try collectRuntimeTypeNames(ve, out),
                    .Else => {},
                };
                try collectRuntimeTypeNames(&br.body, out);
            }
        },
        .Member => |m| try collectRuntimeTypeNames(m.receiver, out),
        .MemberRef => |m| try collectRuntimeTypeNames(m.receiver, out),
        .Index => |idx| {
            try collectRuntimeTypeNames(idx.receiver, out);
            for (idx.args) |*a| try collectRuntimeTypeNames(a, out);
        },
        .Binary => |bin| {
            try collectRuntimeTypeNames(bin.lhs, out);
            try collectRuntimeTypeNames(bin.rhs, out);
        },
        .Unary => |u| try collectRuntimeTypeNames(u.expr, out),
        .Postfix => |u| try collectRuntimeTypeNames(u.expr, out),
        .Spread => |u| try collectRuntimeTypeNames(u.expr, out),
        .Throw => |u| try collectRuntimeTypeNames(u.value, out),
        .Labeled => |u| try collectRuntimeTypeNames(u.expr, out),
        .If => |f| {
            try collectRuntimeTypeNames(f.cond, out);
            try collectRuntimeTypeNames(f.then_branch, out);
            if (f.else_branch) |els| try collectRuntimeTypeNames(els, out);
        },
        .While => |w| {
            try collectRuntimeTypeNames(w.cond, out);
            try collectRuntimeTypeNames(w.body, out);
        },
        .DoWhile => |w| {
            if (w.body) |b| try collectRuntimeTypeNames(b, out);
            try collectRuntimeTypeNames(w.cond, out);
        },
        .For => |f| {
            try collectRuntimeTypeNames(f.iter, out);
            try collectRuntimeTypeNames(f.body, out);
        },
        .Return => |r| {
            if (r.value) |v| try collectRuntimeTypeNames(v, out);
        },
        .Block => |b| {
            for (b.stmts) |*s| try collectRuntimeTypeNamesStmt(s, out);
        },
        .Lambda => |l| {
            for (l.body.stmts) |*s| try collectRuntimeTypeNamesStmt(s, out);
        },
        .AnonFun => |af| {
            if (af.body) |fb| switch (fb.*) {
                .Block => |b| {
                    for (b.stmts) |*s| try collectRuntimeTypeNamesStmt(s, out);
                },
                .Expr => |*ex| try collectRuntimeTypeNames(ex, out),
            };
        },
        .Try => |t| {
            for (t.body.stmts) |*s| try collectRuntimeTypeNamesStmt(s, out);
            for (t.catches) |*c| {
                try putTypeRefNames(&c.ty, out);
                for (c.body.stmts) |*s| try collectRuntimeTypeNamesStmt(s, out);
            }
            if (t.finally) |fb| {
                for (fb.stmts) |*s| try collectRuntimeTypeNamesStmt(s, out);
            }
        },
        .StringTemplate => |st| {
            for (st.parts) |*p| switch (p.*) {
                .Interp => |ex| try collectRuntimeTypeNames(ex, out),
                else => {},
            };
        },
        else => {},
    }
}

fn collectRuntimeTypeNamesStmt(s: *const Stmt, out: *ast_scan.StringSet) Allocator.Error!void {
    switch (s.*) {
        .Expr => |*e| try collectRuntimeTypeNames(e, out),
        .Assign => |a| {
            try collectRuntimeTypeNames(&a.target, out);
            try collectRuntimeTypeNames(&a.value, out);
        },
        .DestructuringDecl => |d| try collectRuntimeTypeNames(&d.init, out),
        .Decl => |d| switch (d) {
            .Property => |p| {
                if (p.init) |*e| try collectRuntimeTypeNames(e, out);
                if (p.delegate) |e| try collectRuntimeTypeNames(e, out);
            },
            .Function => |f| {
                if (f.body) |fb| switch (fb) {
                    .Block => |b| {
                        for (b.stmts) |*st2| try collectRuntimeTypeNamesStmt(st2, out);
                    },
                    .Expr => |*ex| try collectRuntimeTypeNames(ex, out),
                };
            },
            else => {},
        },
    }
}

/// Whether `f`'s body never references any of its reified type parameters, as a
/// bare name or in a runtime type position. Such a body splices with no binding for
/// the parameter, which a call with no type arguments and no expected type needs.
pub fn reifiedParamsUnusedInBody(allocator: Allocator, f: *const Function) Allocator.Error!bool {
    var any_reified = false;
    for (f.type_params) |tp| {
        if (tp.is_reified) any_reified = true;
    }
    if (!any_reified) return true;
    const body = if (f.body) |*fb| fb else return false;
    var used = ast_scan.StringSet.init(allocator);
    defer used.deinit();
    switch (body.*) {
        .Expr => |*e| {
            try ast_scan.collectPathIdents(e, &used);
            try collectRuntimeTypeNames(e, &used);
        },
        .Block => |*blk| {
            for (blk.stmts) |*s| {
                try ast_scan.collectPathIdentsStmt(s, &used);
                try collectRuntimeTypeNamesStmt(s, &used);
            }
        },
    }
    for (f.type_params) |tp| {
        if (tp.is_reified and used.contains(tp.name.name)) return false;
    }
    return true;
}

/// Render a reified type argument's full spelling: the substituted head plus its
/// generic arguments, recursively. A `Function`/`FunctionN` head has no class value
/// to bind, Kotlin erasing function types under reification.
fn functionTypeHead(head: []const u8) bool {
    if (!std.mem.startsWith(u8, head, "Function")) return false;
    for (head["Function".len..]) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

fn renderReifiedTypeName(b: *FuncBuilder, head: []const u8, a: *const ast.TypeRef) Allocator.Error![]const u8 {
    if (a.type_args.len == 0) {
        if (!a.nullable) return head;
        return std.fmt.allocPrint(b.allocator, "{s}?", .{head});
    }
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(b.allocator, head);
    try out.append(b.allocator, '<');
    for (a.type_args, 0..) |*ta, i| {
        if (i != 0) try out.appendSlice(b.allocator, ", ");
        if (ta.is_star) {
            try out.append(b.allocator, '*');
            continue;
        }
        // The caller's lexical owner renames a nested argument head; the callee
        // frame is pushed by the time the bindings render.
        const inner_head = b.resolveReifiedTypeName(ta.ty.name.name) orelse
            (expr_lower.scopeTypeRenameFrom(b, splice_lexical_owner orelse b.ownerClass(), ta.ty.name.name, ta.ty.name.span.file.int()) orelse ta.ty.name.name);
        const rendered = try renderReifiedTypeName(b, inner_head, &ta.ty);
        try out.appendSlice(b.allocator, rendered);
    }
    try out.append(b.allocator, '>');
    if (a.nullable) try out.append(b.allocator, '?');
    return out.toOwnedSlice(b.allocator);
}

fn inlineVarargFactory(elem: []const u8) []const u8 {
    const eq = std.mem.eql;
    if (eq(u8, elem, "Byte")) return "byteArrayOf";
    if (eq(u8, elem, "Short")) return "shortArrayOf";
    if (eq(u8, elem, "Int")) return "intArrayOf";
    if (eq(u8, elem, "Long")) return "longArrayOf";
    if (eq(u8, elem, "Char")) return "charArrayOf";
    if (eq(u8, elem, "Boolean")) return "booleanArrayOf";
    if (eq(u8, elem, "Float")) return "floatArrayOf";
    if (eq(u8, elem, "Double")) return "doubleArrayOf";
    if (eq(u8, elem, "UByte")) return "ubyteArrayOf";
    if (eq(u8, elem, "UShort")) return "ushortArrayOf";
    if (eq(u8, elem, "UInt")) return "uintArrayOf";
    if (eq(u8, elem, "ULong")) return "ulongArrayOf";
    return "arrayOf";
}

/// Materialize the array value a vararg parameter denotes inside an inline body.
/// Keeping it an ordinary factory call reuses the call spread path, so
/// `inlineFn(*values)` flattens the supplied array exactly once.
fn inlineVarargArrayExpr(
    b: *FuncBuilder,
    param: *const ast.Param,
    elems: []const Expr,
) Allocator.Error!*const Expr {
    const factory = inlineVarargFactory(param.ty.name.name);
    const segs = try b.allocator.alloc(ast.Ident, 1);
    segs[0] = .{ .name = factory, .span = param.span };
    const callee = try b.allocator.create(Expr);
    callee.* = .{ .Path = .{ .segments = segs, .span = param.span } };
    const copied = try b.allocator.dupe(Expr, elems);
    const out = try b.allocator.create(Expr);
    out.* = .{ .Call = .{
        .callee = callee,
        .args = copied,
        .arg_names = &.{},
        .type_args = &.{},
        .is_infix = false,
        .span = param.span,
    } };
    return out;
}

/// Expand a call to a `suspend inline fun` by splicing its body into the caller.
/// `type_args` carries the call-site `<T = SomeType>` so each reified parameter
/// binds before the body lowers, and `expected` carries the call's tail-position
/// type so an unspecified reified parameter can be inferred from context.
/// `callSiteFile` is the file an expression was written in, against which a
/// file-private inline candidate's visibility is judged.
fn callSiteFileOf(e: *const Expr) ?span.FileId {
    return switch (e.*) {
        .Path => |p| if (p.segments.len != 0) p.segments[0].span.file else null,
        .Member => |m| m.name.span.file,
        .Call => |c| callSiteFileOf(c.callee),
        .Lambda => |l| l.span.file,
        .This => |t| t.span.file,
        else => null,
    };
}

/// `KLIO_SPLICE_TRACE=<fn>`: why a splice that was entered declined, otherwise
/// indistinguishable from never being considered.
fn spliceBail(fname: []const u8, why: []const u8) void {
    if (inline_state.runtime.envOnce("KLIO_SPLICE_TRACE")) |w| {
        if (std.mem.eql(u8, w, fname)) std.debug.print("[splice-why] {s}: {s}\n", .{ fname, why });
    }
}

/// Whether an AST type reference mentions any of `f`'s declared type parameters.
/// Such a type is not a concrete fact about the spliced parameter, its meaning
/// depending on the call's inference.
fn astTypeMentionsFnTypeParam(ty: *const ast.TypeRef, f: *const ast.Function) bool {
    for (f.type_params) |*tp| {
        if (std.mem.eql(u8, tp.name.name, ty.name.name)) return true;
    }
    for (ty.type_args) |*ta| {
        if (ta.is_star) continue;
        if (astTypeMentionsFnTypeParam(&ta.ty, f)) return true;
    }
    if (ty.function) |fnty| {
        if (fnty.receiver) |*r| {
            if (astTypeMentionsFnTypeParam(r, f)) return true;
        }
        for (fnty.params) |*pp| {
            if (astTypeMentionsFnTypeParam(pp, f)) return true;
        }
        if (astTypeMentionsFnTypeParam(&fnty.ret, f)) return true;
    }
    return false;
}

pub var splice_route_tag: []const u8 = "?";

/// The declaration a call splices. A bare call arrives with its `target` already
/// resolved, so the splice expands the declaration the call binds. A member call
/// resolves here by receiver and shape narrowing: the target must be a receiver
/// extension.
fn spliceTargetFor(
    b: *FuncBuilder,
    fname: []const u8,
    target: ?*const ast.Function,
    args: []const Expr,
    this_arg: ?*const Expr,
) Allocator.Error!?*const ast.Function {
    if (target) |t| return t;
    const last_is_lambda = args.len > 0 and switch (args[args.len - 1]) {
        .Lambda, .AnonFun => true,
        else => false,
    };
    const trailing_arity: ?usize = if (args.len == 0) null else switch (args[args.len - 1]) {
        .Lambda => |l| if (l.implicit_it) 0 else l.params.len,
        .AnonFun => |af| af.params.len,
        else => null,
    };
    const call_shape = CallShape{
        .want = args.len,
        .last_is_lambda = last_is_lambda,
        .trailing_lambda_arity = trailing_arity,
        .call_file = if (this_arg) |ta| callSiteFileOf(ta) else null,
        .arg0_class_literal = args.len != 0 and args[0] == .MemberRef and
            std.mem.eql(u8, args[0].MemberRef.name.name, "class"),
    };
    var recv_ty = try inferReceiverType(b, this_arg);
    // A bare call inside an extension body has the enclosing extension's
    // declared receiver as its implicit receiver, without which the
    // extensions-only decline below loses the reified type argument.
    if (recv_ty == null and this_arg == null) recv_ty = b.recvTy();
    const recv_chain: ?[]const []const u8 = if (recv_ty) |r|
        try expr_lower.recvChainOf(b, r)
    else
        null;
    return inline_state.inlineFnAstForRecvExt(
        fname,
        call_shape,
        recv_chain,
        this_arg != null,
    );
}

/// A member extension narrowed by receiver and shape is visible only inside its
/// declaring class hierarchy.
fn memberExtVisibleAtCall(
    b: *FuncBuilder,
    fname: []const u8,
    target: ?*const ast.Function,
    f: *const ast.Function,
) bool {
    if (!(target == null and f.receiver_type != null)) return true;
    const owner = inline_state.inlineMemberOwner(f) orelse return true;
    const enc = b.ownerClass() orelse {
        spliceBail(fname, "member-ext-owner-invisible (no enclosing class)");
        return false;
    };
    if (!expr_lower.classIsOrExtendsHosted(b, enc, owner)) {
        if (inline_state.runtime.envOnce("KLIO_SPLICE_TRACE")) |w| {
            if (std.mem.eql(u8, w, fname)) std.debug.print("[splice-why] {s}: member-ext-owner-invisible enc={s} owner={s}\n", .{ fname, enc, owner });
        }
        return false;
    }
    return true;
}

/// `Result` is natively represented, and its inline members' source bodies read
/// internal slots the native value never carries, so never splice them; the
/// runtime serves them from intrinsics.
fn resultReceiverIsNative(f: *const ast.Function) bool {
    const rt = f.receiver_type orelse return false;
    return std.mem.eql(u8, rt.name.name, "Result");
}

/// `kotlin.reflect.typeOf<T>()` is a reified intrinsic whose source body is a
/// placeholder throw, served at runtime from the reified type argument.
fn typeOfIsReifiedIntrinsic(fname: []const u8, f: *const ast.Function) bool {
    if (!(std.mem.eql(u8, fname, "typeOf") and f.params.len == 0 and
        f.type_params.len == 1 and f.type_params[0].is_reified)) return false;
    const rt = f.return_type orelse return false;
    return std.mem.endsWith(u8, rt.name.name, "KType");
}

/// `KLIO_SPLICE_TRACE=<fn>`: whether a named inline function reaches the splice
/// path at all, and which parameter types the splice binds.
fn traceSpliceEntry(
    fname: []const u8,
    f: *const ast.Function,
    this_arg: ?*const Expr,
    type_args: []const TypeRef,
) void {
    if (inline_state.runtime.envOnce("KLIO_SPLICE_TRACE")) |w| {
        if (std.mem.eql(u8, w, fname)) {
            const site: ?u32 = if (this_arg) |r| helpers.exprSpan(r).start else null;
            std.debug.print("[splice] {s} entered, params={d} decl={}:{} site={?} nta={d} route={s}\n", .{ fname, f.params.len, f.name.span.file, f.name.span.start, site, type_args.len, splice_route_tag });
        }
    }
}

/// Seat every supplied argument in its declared parameter slot, materializing a
/// vararg group into the array the inline body sees. False declines the splice.
fn orderInlineArgs(
    b: *FuncBuilder,
    fname: []const u8,
    f: *const ast.Function,
    args: []const Expr,
    arg_names: []const ?[]const u8,
    ordered: []?*const Expr,
    vararg_value: *?*const Expr,
) Allocator.Error!bool {
    // A trailing lambda fills the last parameter even when earlier defaulted
    // parameters are omitted; mapping 1:1 from the front would leave the last,
    // function-typed one unfilled.
    const last_is_trailing_lambda = args.len > 0 and
        (args.len > arg_names.len or arg_names[args.len - 1] == null) and
        switch (args[args.len - 1]) {
            .Lambda, .AnonFun => true,
            else => false,
        };
    const lambda_to_last = last_is_trailing_lambda and f.params.len > 0 and
        !f.params[f.params.len - 1].is_vararg;
    if (lambda_to_last) {
        ordered[f.params.len - 1] = &args[args.len - 1];
    }
    const positional_n = if (lambda_to_last) args.len - 1 else args.len;
    const vararg_idx: ?usize = blk: {
        for (f.params, 0..) |p, i| {
            if (p.is_vararg) break :blk i;
        }
        break :blk null;
    };
    if (vararg_idx) |vi| {
    // Parameters after a vararg can only be supplied by name, apart from a trailing
    // lambda, so remaining positional arguments are vararg elements, materialized
    // into the array the inline body sees.
        var elem_start: usize = 0;
        while (elem_start < positional_n and elem_start < vi) : (elem_start += 1) {
            const nm: ?[]const u8 = if (elem_start < arg_names.len) arg_names[elem_start] else null;
            if (nm != null) break;
            ordered[elem_start] = &args[elem_start];
        }
        var elem_end = positional_n;
        for (args[elem_start..positional_n], elem_start..) |*a, ai| {
            const nm: ?[]const u8 = if (ai < arg_names.len) arg_names[ai] else null;
            if (nm) |name| {
                const idx = paramIndex(f, name) orelse return false;
                if (idx == vi) return false;
                if (ordered[idx] != null) {
                    spliceBail(fname, "named-collision");
                    return false;
                }
                ordered[idx] = a;
                elem_end = @min(elem_end, ai);
            }
        }
        const elems = args[elem_start..elem_end];
        if (elems.len != 0) ordered[vi] = &elems[0];
        vararg_value.* = try inlineVarargArrayExpr(b, &f.params[vi], elems);
    } else {
        var next_pos: usize = 0;
        for (args[0..positional_n], 0..) |*a, i| {
            const nm: ?[]const u8 = if (i < arg_names.len) arg_names[i] else null;
            if (nm) |name| {
                const idx = paramIndex(f, name) orelse {
                    spliceBail(fname, "named-param-miss");
                    return false;
                };
                // A name for a slot a positional argument already took is Kotlin's
                // "argument passed twice" error, and the sign of a wrong overload.
                if (ordered[idx] != null) {
                    spliceBail(fname, "named-collision");
                    return false;
                }
                ordered[idx] = a;
            } else {
                while (next_pos < ordered.len and ordered[next_pos] != null) {
                    next_pos += 1;
                }
                if (next_pos >= ordered.len) {
                    spliceBail(fname, "positional-overflow");
                    return false;
                }
                ordered[next_pos] = a;
                next_pos += 1;
            }
        }
    }
    return true;
}

/// Every slot a supplied argument did not take is filled from the declaration's
/// own default, which is callee code. A slot with neither is not this overload.
fn fillInlineDefaultSlots(
    fname: []const u8,
    f: *const ast.Function,
    ordered: []?*const Expr,
    slot_is_default: []bool,
) bool {
    for (slot_is_default) |*x| x.* = false;
    for (ordered, 0..) |*slot, i| {
        if (slot.* == null) {
            if (f.params[i].is_vararg) {
                continue;
            } else if (f.params[i].default) |d| {
                slot.* = d;
                slot_is_default[i] = true;
            } else {
                spliceBail(fname, "unfilled-param");
                return false;
            }
        }
    }
    return true;
}

/// A reified parameter still unbound after explicit-argument, expected-type and
/// callable-reference inference must not be one the body reads, or splicing
/// leaves `T::class` dangling; decline and let member dispatch bind it.
fn declinesOnUnboundReified(
    b: *FuncBuilder,
    fname: []const u8,
    f: *const ast.Function,
    probe: []const ?TypeRef,
    ordered: []const ?*const Expr,
) Allocator.Error!bool {
    var unbound_reified = false;
    for (f.type_params, 0..) |tp, i| {
        if (!(tp.is_reified and probe[i] == null)) continue;
        if (callableRefParamFor(f, ordered, tp.name.name) != null) continue;
        unbound_reified = true;
    }
    if (inline_state.runtime.envOnce("KLIO_SPLICE_TRACE")) |w| {
        if (std.mem.eql(u8, w, fname)) {
            for (f.type_params, 0..) |tp, i| {
                if (!tp.is_reified) continue;
                const bound: []const u8 = if (probe[i]) |t| t.name.name else "<unbound>";
                std.debug.print("[splice] {s} reified {s} probe={s}\n", .{ fname, tp.name.name, bound });
            }
        }
    }
    if (unbound_reified and !(try reifiedParamsUnusedInBody(b.allocator, f))) {
        spliceBail(fname, "unbound-reified");
        return true;
    }
    return false;
}

/// A caller window bound ref a splice shadows with the call site's own solved
/// binding, restored when the splice ends.
const S4Restore = struct { name: []const u8, prev: ?ir.TypeRef };

/// A caller local-decl type record an inline parameter binding shadows.
const PTySave = struct { name: []const u8, ty: ?ir.TypeRef };

/// Expansion-depth admission for one splice. A reified callee gets the wider
/// budget, its body's type reads having no dynamic fallback.
fn enterInlineExpansion(fname: []const u8, f: *const ast.Function) bool {
    const has_reified_tp = blk: {
        for (f.type_params) |tp| {
            if (tp.is_reified) break :blk true;
        }
        break :blk false;
    };
    if (!(if (has_reified_tp) inline_state.inlineExpandEnterReified() else inline_state.inlineExpandEnter())) {
        spliceBail(fname, "expand-depth");
        return false;
    }
    return true;
}

/// An extension or member-inline splice through an explicit receiver lowers that
/// receiver here. The receiver is a nested expression, so the caller's per-arg
/// lambda typing stash, consumed by this splice's own arg loop, must not leak
/// into it.
fn lowerSpliceReceiver(
    b: *FuncBuilder,
    f: *const ast.Function,
    this_arg: ?*const Expr,
    member_splice: bool,
) Allocator.Error!?Reg {
    if (!((f.receiver_type != null or member_splice) and this_arg != null)) return null;
    const sh_bm = b.pending_arg_broad_masks;
    const sh_fg = b.pending_arg_fn_generic;
    const sh_lp = b.pending_arg_lambda_param_types;
    const sh_lu = b.pending_arg_lambda_unit;
    b.pending_arg_broad_masks = null;
    b.pending_arg_fn_generic = null;
    b.pending_arg_lambda_param_types = null;
    b.pending_arg_lambda_unit = null;
    defer {
        b.pending_arg_broad_masks = sh_bm;
        b.pending_arg_fn_generic = sh_fg;
        b.pending_arg_lambda_param_types = sh_lp;
        if (b.pending_arg_lambda_unit) |m| b.allocator.free(m);
        b.pending_arg_lambda_unit = sh_lu;
    }
    return try lowerExpr(b, this_arg.?);
}

/// The spliced extension's declared receiver is evidence for the body's own
/// inline gates, on the dedicated splice channel rather than `recv_ty` so
/// nested-lambda bare calls keep resolving through the runtime receiver walk.
fn installSpliceRecvWindow(
    b: *FuncBuilder,
    f: *const ast.Function,
    this_arg: ?*const Expr,
    member_splice: bool,
) Allocator.Error!void {
    if (f.receiver_type) |rt| {
    // A generic inline receiver names no classifier while the call site's static
    // receiver type does, so substitute it and let the body's bare calls see the
    // real receiver class.
        var recv_head: []const u8 = rt.name.name;
        var declares_param = false;
        for (f.type_params) |*tp| {
            if (std.mem.eql(u8, tp.name.name, rt.name.name)) declares_param = true;
        }
        if (declares_param) if (this_arg) |ra| {
            if (expr_lower.argDeclTypeRefLazy(b, ra)) |known| {
                recv_head = try b.allocator.dupe(u8, expr_lower.typeHead(std.mem.trimEnd(u8, known.name, "?")));
            } else if (try expr_lower.staticExprTypeRef(b, ra)) |owned_ty| {
                var owned = owned_ty;
                defer owned.deinit(b.allocator);
                recv_head = try b.allocator.dupe(u8, expr_lower.typeHead(std.mem.trimEnd(u8, owned.name, "?")));
            }
        } else if (b.recvTy() orelse b.spliceRecvTy()) |eh| {
            // A bare call to the generic receiver splice has no receiver expression,
            // so the window head is the enclosing receiver's, not the literal `T`.
            recv_head = try b.allocator.dupe(u8, expr_lower.typeHead(std.mem.trimEnd(u8, eh, "?")));
        };
        b.setSpliceRecvTy(recv_head);
    } else if (member_splice) {
        // A member-inline splice's bare names resolve against the owner class
        // exactly as an extension's resolve against its receiver.
        if (inline_state.inlineMemberOwner(f)) |ow| b.setSpliceRecvTy(ow);
    } else if (this_arg == null) {
        // A bare inline-member call through the implicit receiver splices with the
        // owner window too, or the body's own property reads lower ownerless.
        if (inline_state.inlineMemberOwner(f)) |ow| {
            b.setSpliceRecvTy(ow);
        } else if (build.FuncBuilder.spliceRefDebug()) {
            std.debug.print("[splice-ref] fn={s} bare-member-owner=NULL\n", .{f.name.name});
        }
    }
}

/// The actual receiver's full static type enters the window when the call site
/// derives one, since iterating `this` inside the body types its elements from
/// the receiver's arguments. A bare type-parameter head resolves through the
/// caller's full bound ref.
fn spliceReceiverTypeRefOwned(
    b: *FuncBuilder,
    f: *const ast.Function,
    this_arg: ?*const Expr,
) Allocator.Error!?ir.TypeRef {
    var recv_ref_owned: ?ir.TypeRef = null;
    // An inline extension called bare on the implicit receiver has no receiver
    // expression to read a type from, but the window it splices into already holds
    // the caller's own receiver, whose element type every derived lambda param needs.
    if (f.receiver_type != null and this_arg == null) fwd: {
        const cur = b.spliceRecvTyRef() orelse break :fwd;
        if (cur.args.len == 0) break :fwd;
        const declared_head = expr_lower.typeHead(std.mem.trimEnd(u8, f.receiver_type.?.name.name, "?"));
        const cur_head = expr_lower.typeHead(std.mem.trimEnd(u8, cur.name, "?"));
    // Only when the callee's declared receiver is the same classifier or a supertype
    // of the one in hand; a delegation to an unrelated extension must not inherit
    // this receiver's arguments.
        if (!std.mem.eql(u8, declared_head, cur_head) and
            !b.module.classIsOrExtends(cur_head, declared_head)) break :fwd;
        recv_ref_owned = cur.clone(b.allocator) catch break :fwd;
    }
    if (f.receiver_type != null) if (this_arg) |ra| blk: {
        var inferred: ?ir.TypeRef = null;
        defer if (inferred) |*t| t.deinit(b.allocator);
        var got = expr_lower.argDeclTypeRefLazy(b, ra) orelse got_blk: {
            // A lazily-typed local answers only through its initializer, the same
            // chain the member path consults before resolving.
            inferred = try expr_lower.staticExprTypeRef(b, ra);
            break :got_blk inferred orelse break :blk;
        };
        if (got.args.len == 0) {
            var h = std.mem.trimEnd(u8, got.name, "?");
            if (std.mem.findScalar(u8, h, '<')) |lt| h = h[0..lt];
            if (b.typeParamBoundRef(expr_lower.typeHead(h))) |bref| got = bref.*;
        }
        if (got.args.len == 0) break :blk;
        recv_ref_owned = got.clone(b.allocator) catch break :blk;
    };
    if (build.FuncBuilder.spliceRefDebug()) {
        std.debug.print("[splice-ref] fn={s} this_arg={s} ref={?s}<{d}>\n", .{
            f.name.name,
            if (this_arg) |ra| (if (ra.* == .Path and ra.Path.segments.len != 0) ra.Path.segments[ra.Path.segments.len - 1].name else @tagName(std.meta.activeTag(ra.*))) else "-",
            if (recv_ref_owned) |r| r.name else null,
            if (recv_ref_owned) |r| r.args.len else 0,
        });
    }
    return recv_ref_owned;
}

/// The caller's solved bindings become window bound refs, so every consumer sees
/// the call-site instantiation for each fn type parameter.
fn installSolvedTypeParamBounds(
    b: *FuncBuilder,
    s4_restores: *std.ArrayList(S4Restore),
) void {
    if (b.module.pending_splice_solved) |solved| {
        b.module.pending_splice_solved = null;
        defer b.allocator.free(solved);
        for (solved) |sb| {
            const prev: ?ir.TypeRef = if (b.typeParamBoundRef(sb.name)) |p|
                p.clone(b.allocator) catch null
            else
                null;
            s4_restores.append(b.allocator, .{ .name = sb.name, .prev = prev }) catch {
                var t = sb.ty;
                t.deinit(b.allocator);
                continue;
            };
            b.addTypeParamBoundRef(sb.name, sb.ty) catch {};
        }
    }
}

/// The inline body lowers into the caller's builder, so its own `var` decls and
/// any inline parameter a nested closure writes must be boxed into a shared
/// `Value.Cell` there, exactly as a captured `var` is at a lambda boundary.
/// Otherwise the write takes the `StoreGlobal`-for-capture fallback, which only
/// round-trips on the stdlib-HOF scoped env.
fn computeSpliceBoxedNames(
    b: *FuncBuilder,
    f: *const ast.Function,
    body: *const ast.FunctionBody,
    splice_boxed: *ast_scan.StringSet,
) Allocator.Error!void {
    if (body.* == .Block) {
        // Body-declared `var`s captured-and-written by a nested closure.
        var body_boxed = try ast_scan.computeBoxedVars(b.allocator, body.Block.stmts);
        defer body_boxed.deinit();
        var bit = body_boxed.keyIterator();
        while (bit.next()) |k| try splice_boxed.put(k.*, {});
        // Inline parameters written by a nested closure in the body. A parameter is
        // not a body `var` decl, so `computeBoxedVars` does not see it.
        var assigned = ast_scan.StringSet.init(b.allocator);
        defer assigned.deinit();
        try ast_scan.namesAssignedInLambdasRebindsOnly(body.Block.stmts, &assigned);
        for (f.params) |*p| {
            if (assigned.contains(p.name.name)) try splice_boxed.put(p.name.name, {});
        }
    }
}

/// The state one inline parameter binding reads and writes: the call's ordered
/// arguments and default marks on the way in, and the bound registers, splice
/// substitution map and shadow records on the way out.
const InlineArgBind = struct {
    b: *FuncBuilder,
    fname: []const u8,
    f: *const ast.Function,
    args: []const Expr,
    ordered: []const ?*const Expr,
    slot_is_default: []const bool,
    vararg_value: ?*const Expr,
    arg_lambda_param_types: ?[]const ?[]const ir.TypeRef,
    explicit_receiver: ?Reg,
    splice_boxed: *const ast_scan.StringSet,
    arg_regs: []Reg,
    lambda_map: *std.StringHashMap(*const ast.Expr),
    param_ty_saves: *std.ArrayList(PTySave),
    bound_param_names: *std.ArrayList([]const u8),
    boxed_here: *std.ArrayList([]const u8),
    any_forwarded_lambda: bool = false,
    any_literal_lambda: bool = false,
};

/// A lambda or callable-reference argument bound to a declared function-typed
/// param takes its arity from the declaration, and the caller's per-slot
/// instantiated param types, which this binding otherwise bypasses.
fn prepareInlineLambdaArg(ctx: *InlineArgBind, p: *const ast.Param, a: *const Expr) void {
    const b = ctx.b;
    const args = ctx.args;
    const arg_lambda_param_types = ctx.arg_lambda_param_types;
// A callable-reference argument needs the declared arity too: the MemberRef
// lowering binds the target fid only when it knows the expected function
// shape, and a name-carrying reference cannot reach a file-scoped extension.
if (a.* == .MemberRef and p.ty.function != null) {
    b.pending_lambda_arity = @intCast(p.ty.function.?.params.len);
}
// A lambda argument bound to a declared function-typed param takes its arity
// from the declaration; a zero-`->` lambda for a `() -> R` param must not
// keep the parser's implicit `it`.
if ((a.* == .Lambda or a.* == .AnonFun) and p.ty.function != null) {
    b.pending_lambda_arity = @intCast(p.ty.function.?.params.len);
    if (arg_lambda_param_types) |slots| {
        // `ordered[i]` points into the caller's arg slice; recover the
        // argument index the per-slot types are keyed by. The synthetic
        // vararg expression lies outside the slice.
        const base = @intFromPtr(args.ptr);
        const off = @intFromPtr(a) -% base;
        const idx = off / @sizeOf(Expr);
        if (@intFromPtr(a) >= base and idx < args.len and
            idx < slots.len)
        {
            b.pending_ref_lambda_param_types = slots[idx];
        }
    }
}
}

/// A lambda argument every call position of the body expands is consumed by the
/// splice, so materializing it builds a dead closure per call. The substitution
/// map serves the call positions and the use scan proved no value position
/// exists. The literal's own body referencing the param's name still needs the
/// binding as the shadow the window hides.
fn spliceConsumesLambdaArg(
    fname: []const u8,
    f: *const ast.Function,
    p: *const ast.Param,
    a: *const Expr,
    is_default: bool,
) bool {
    return a.* == .Lambda and !is_default and
        p.ty.function != null and paramOnlyCalled(f, p.name.name) and
        !pocStmts(false, a.Lambda.body.stmts, p.name.name) and
        !std.mem.eql(u8, inline_state.runtime.envOnce("KLIO_ARG_SKIP") orelse "1", "0") and
        blk_only: {
            const only = inline_state.runtime.envOnce("KLIO_ARG_SKIP_ONLY") orelse break :blk_only true;
            var it = std.mem.splitScalar(u8, only, ',');
            while (it.next()) |w| {
                if (std.mem.eql(u8, w, fname)) break :blk_only true;
            }
            break :blk_only false;
        };
}

/// Lower one argument into the caller's builder. A default-filled slot is callee
/// code: Kotlin evaluates a default in the declaration's scope, where the
/// extension receiver and earlier params are visible, while a caller-supplied
/// argument keeps the call site's scope and must not see the params already
/// bound by earlier iterations.
fn lowerInlineArgValue(
    ctx: *InlineArgBind,
    p: *const ast.Param,
    a: *const Expr,
    i: usize,
    coerced: ?Reg,
) Allocator.Error!Reg {
    _ = p;
    const b = ctx.b;
    const f = ctx.f;
    const slot_is_default = ctx.slot_is_default;
    const explicit_receiver = ctx.explicit_receiver;
    return if (slot_is_default[i] and explicit_receiver != null) blk: {
        // The default is callee code, so the receiver is its innermost implicit
        // receiver typed by the declaration, even when the call site could not
        // type the receiver expression.
        const prior_this = b.resolveIgnoringFloor("this");
        try b.pushScope();
        try b.bind("this", explicit_receiver.?);
        const prev_default_recv = b.spliceRecvTy();
        const recv_head: ?[]const u8 = if (f.receiver_type) |rt|
            expr_lower.typeHead(std.mem.trimEnd(u8, rt.name.name, "?"))
        else
            null;
        if (recv_head) |h| b.setSpliceRecvTy(h);
        try b.subject_binds.append(b.allocator, .{
            .reg = explicit_receiver.?,
            .head = recv_head,
            .prior_this = prior_this,
        });
        const rr = coerced orelse try lowerExpr(b, a);
        _ = b.subject_binds.pop();
        b.setSpliceRecvTy(prev_default_recv);
        try b.popScope();
        break :blk rr;
    } else if (slot_is_default[i]) coerced orelse try lowerExpr(b, a) else blk: {
        var hidden_params: std.ArrayList(struct { name: []const u8, h: build.HiddenBinding }) = .empty;
        defer hidden_params.deinit(b.allocator);
        for (ctx.bound_param_names.items) |nm| {
            if (b.hideBinding(nm)) |h| {
                hidden_params.append(b.allocator, .{ .name = nm, .h = h }) catch break;
            }
        }
        const rr = coerced orelse try lowerExpr(b, a);
        var hi = hidden_params.items.len;
        while (hi > 0) {
            hi -= 1;
            b.restoreHiddenBinding(hidden_params.items[hi].name, hidden_params.items[hi].h);
        }
        break :blk rr;
    };
}

/// A parameter declared by one of the callee's own type parameters types nothing
/// inside the body, so the argument's static type is the instantiation. Recorded
/// under the local-decl channel, which `spliceParamTy` falls through to for tp
/// heads, shadow-saving any same-named caller record. A bare tp head is refused;
/// loose tp args ride, the head still binding.
fn recordInlineParamDeclType(
    ctx: *InlineArgBind,
    p: *const ast.Param,
    a: *const Expr,
) Allocator.Error!void {
    const b = ctx.b;
    const f = ctx.f;
    if (!(p.ty.function == null and !p.is_vararg)) return;
    tp_arg: {
        const dh = p.ty.name.name;
        const tp_declared = (dh.len > 0 and dh.len <= 2 and
            std.ascii.isUpper(dh[0])) or
            blk_tp: {
                for (f.type_params) |*tp| {
                    if (std.mem.eql(u8, tp.name.name, dh)) break :blk_tp true;
                }
                break :blk_tp false;
            };
        if (!tp_declared) {
            // A concrete declared head is the parameter's static type inside the
            // spliced body just as in the framed activation, letting the
            // explicit-receiver derivations see through the binding.
            if (dh.len == 0) break :tp_arg;
            // A concrete head can still carry the fn's type params in its
            // arguments, and the declared spelling verbatim would feed a raw `T`
            // to the reified derivations, so those keep the derived channel.
            if (astTypeMentionsFnTypeParam(&p.ty, f)) break :tp_arg;
            try ctx.param_ty_saves.append(b.allocator, .{
                .name = p.name.name,
                .ty = if (b.localDeclTypeRef(p.name.name)) |t| try t.clone(b.allocator) else null,
            });
            b.clearLocalDeclType(p.name.name);
            try b.setLocalDeclTypeOwned(p.name.name, try expr_lower.loweredOwnedLocalTypeRef(b, &p.ty));
            break :tp_arg;
        }
        var derived_owned: ?ir.TypeRef = null;
        defer if (derived_owned) |*t| t.deinit(b.allocator);
        const derived: ?ir.TypeRef = expr_lower.argDeclTypeRefLazy(b, a) orelse dblk: {
            derived_owned = try expr_lower.staticExprTypeRef(b, a);
            break :dblk derived_owned;
        };
        // Clone before clearing: `derived` may borrow the very record the clear
        // frees, a same-named caller local's.
        var derived_clone: ?ir.TypeRef = null;
        if (derived) |dv| {
            var h = std.mem.trimEnd(u8, dv.name, "?");
            if (std.mem.findScalar(u8, h, '<')) |lt| h = h[0..lt];
            const bare = (h.len > 0 and h.len <= 2 and std.ascii.isUpper(h[0])) or
                b.isTypeParam(h) or ir.parseClassTypeParamIdentity(h) != null;
            if (!bare) derived_clone = try dv.clone(b.allocator);
        }
        // Always shadow the caller's same-named record for a tp-declared param:
        // with nothing derivable the body must see no record at all.
        try ctx.param_ty_saves.append(b.allocator, .{
            .name = p.name.name,
            .ty = if (b.localDeclTypeRef(p.name.name)) |t| try t.clone(b.allocator) else null,
        });
        b.clearLocalDeclType(p.name.name);
        if (derived_clone) |dc| {
            try b.setLocalDeclTypeOwned(p.name.name, dc);
        } else if (b.typeParamBound(dh) != null) {
            // Nothing derivable from the argument, but the callee declared this
            // parameter by one of its own bounded type parameters, and the
            // receiver walk resolves a type parameter through its bound.
            try b.setLocalDeclTypeOwned(p.name.name, .{
                .name = try b.allocator.dupe(u8, dh),
                .nullable = p.ty.nullable,
                .args = &.{},
            });
        }
    }
}

/// Bind one inline parameter: lower its argument in the right scope, seat the
/// register, box it where a nested closure writes it, record its static type and
/// enter it in the splice substitution map unless it is `noinline`.
fn bindInlineArg(ctx: *InlineArgBind, p: *const ast.Param, i: usize) Allocator.Error!void {
    const b = ctx.b;
    const f = ctx.f;
    const fname = ctx.fname;
    const ordered = ctx.ordered;
    const slot_is_default = ctx.slot_is_default;
    const vararg_value = ctx.vararg_value;
    const arg_regs = ctx.arg_regs;
    const a = if (p.is_vararg) vararg_value.? else ordered[i].?;
    const forwarded_lambda = forwardedInlineLambda(b, a);
// A numeric literal argument re-types to its declared primitive parameter, per
// kotlinc literal typing. The regular call path coerces in `lowerArgRunFull`,
// but the splice binds the lowered arg directly.
    const coerced: ?Reg = if (p.ty.function == null and !p.ty.nullable)
        try helpers.coerceNumericLiteralArg(b, a, p.ty.name.name)
    else
        null;
    prepareInlineLambdaArg(ctx, p, a);
    // A default-filled slot is callee code: Kotlin evaluates a default in the
    // declaration's scope, where the extension receiver and earlier params are
    // visible, while caller-supplied arguments keep the call site's scope. The
    // splice bypasses `lowerArgRun`, so the sibling-solved expected type applies
    // here too.
    const sib_push = if (b.sib_expected_site) |site|
        site == @as(*const anyopaque, @ptrCast(a))
    else
        false;
    const sib_prev = if (sib_push) b.pushExpected(b.sib_expected_ty) else null;
    // A literal lambda that materializes, the body forwarding the param as a
    // value rather than only calling it, must lower under the param's declared
    // function type exactly as `lowerArgRun` would, the expected type being where
    // `lowerLambda` reads the receiver head. Otherwise a receiver-formed literal
    // lowers as a plain block whose `this` comes from the enclosing splice's
    // subject, and every later invocation runs against that stale receiver.
    const lam_ty_push = (a.* == .Lambda or a.* == .AnonFun) and p.ty.function != null;
    const lam_ty_prev = if (lam_ty_push) b.pushExpected(p.ty) else null;
    // Span-keyed receiver record for the literal: a later call-position splice
    // must know it is receiver-formed, so the supplied argument seats as `this`.
    if (lam_ty_push and a.* == .Lambda) {
        if (p.ty.function.?.receiver) |*rty| {
            const lowered_recv = try expr_lower.loweredOwnedLocalTypeRef(b, rty);
            try b.recordLambdaArgRecvOwned(a.Lambda.span, lowered_recv);
            b.recordLambdaArgArity(a.Lambda.span, @intCast(p.ty.function.?.params.len));
        }
    }
    if (lam_ty_push and inline_state.runtime.envOnce("KLIO_ARG_SKIP_TRACE") != null) {
        std.debug.print("[arg-mat] fn={s} param={s} recv_ty={s}\n", .{ fname, p.name.name, if (p.ty.function.?.receiver) |r| r.name.name else "-" });
    }
    const splice_consumed_lambda = spliceConsumesLambdaArg(fname, f, p, a, slot_is_default[i]);
    if (splice_consumed_lambda) {
        if (inline_state.runtime.envOnce("KLIO_ARG_SKIP_TRACE") != null) {
            std.debug.print("[arg-skip] fn={s} param={s}\n", .{ fname, p.name.name });
        }
        if (lam_ty_push) b.restoreExpected(lam_ty_prev);
        if (sib_push) b.restoreExpected(sib_prev);
        b.pending_lambda_arity = -1;
        b.pending_ref_lambda_param_types = null;
        arg_regs[i] = try b.emitConst(Const.Unit);
        try ctx.bound_param_names.append(b.allocator, p.name.name);
        try ctx.lambda_map.put(p.name.name, a);
        ctx.any_literal_lambda = true;
        return;
    }
    const r = try lowerInlineArgValue(ctx, p, a, i, coerced);
    if (lam_ty_push) b.restoreExpected(lam_ty_prev);
    if (sib_push) b.restoreExpected(sib_prev);
    b.pending_lambda_arity = -1;
    b.pending_ref_lambda_param_types = null;
    arg_regs[i] = r;
    // A fn-typed literal that materialized because the body forwards it is a
    // dead-construction candidate: when every forward lands in a nested
    // call-position splice, nothing reads the closure register.
    if (a.* == .Lambda and p.ty.function != null and !slot_is_default[i]) {
        b.noteForwardedLambda(r, a.Lambda.span);
    }
    // A lambda argument is spliced inline, so it is never a closure value to
    // box, even if a deeper nested lambda mentions the param name.
    const box_param = ctx.splice_boxed.contains(p.name.name) and a.* != .Lambda;
    if (box_param and !b.isBoxed(p.name.name)) {
        // Box the parameter into a shared cell. The scope-local `bind` suffices
        // for `boxedCellReg`, so the mark and binding live only inside the
        // spliced scope and leak no `mutable_homes` entry onto a caller local.
        const home = b.allocReg();
        try b.push(.{ .MakeCell = .{ .dst = home, .src = r } });
        try b.markBoxed(p.name.name);
        try b.bind(p.name.name, home);
        try ctx.boxed_here.append(b.allocator, p.name.name);
    } else {
        try b.bind(p.name.name, r);
    }
    try ctx.bound_param_names.append(b.allocator, p.name.name);
    try recordInlineParamDeclType(ctx, p, a);
    // `noinline` parameters opt out of inline-lambda splicing: their argument
    // value still flows through the binding above, but a call to the parameter
    // inside the inlined body lowers as a normal CallValue, so the lambda can be
    // passed on or stored. `crossinline` keeps the inline-lambda path, but a
    // bare `return` in the lambda body is illegal there, since the inlined
    // body's return targets the enclosing inline fn's caller. No parser-level
    // diagnostic is emitted; the runtime semantics match.
    if (!p.is_noinline) {
        if (forwarded_lambda) |lam| {
            try ctx.lambda_map.put(p.name.name, lam);
            ctx.any_forwarded_lambda = true;
        } else if (a.* == .Lambda) {
            try ctx.lambda_map.put(p.name.name, a);
            ctx.any_literal_lambda = true;
        }
    }
}

/// A caller splice-param type record this splice shadows.
const SpRestore = struct { name: []const u8, prev: ?ast.TypeRef };

/// Mark params whose declared type is one of this inline fn's own generic type
/// parameters, so a comparison operator on such an operand lowers to `compareTo`,
/// the total order for Double and Float. The names added are removed once the
/// body lowers, so the mark never leaks onto a same-named caller local.
fn markInlineGenericTypedParams(
    b: *FuncBuilder,
    f: *const ast.Function,
    marked_generic: *std.ArrayList([]const u8),
) Allocator.Error!void {
    if (f.type_params.len != 0) {
        var tp_names = std.StringHashMap(void).init(b.allocator);
        defer tp_names.deinit();
        for (f.type_params) |tp| {
            try tp_names.put(tp.name.name, {});
        }
        for (f.params) |*p| {
            if (p.ty.function == null and
                !p.ty.nullable and
                tp_names.contains(p.ty.name.name) and
                !b.isGenericTypedParam(p.name.name))
            {
                try b.markGenericTypedParam(p.name.name);
                try marked_generic.append(b.allocator, p.name.name);
            }
        }
    }
}

/// Mark params whose declared type is a receiver-typed function so a bare
/// `block(...)` dispatches `this.block()`. Same record-and-remove discipline as
/// the generic marks.
fn markInlineReceiverLambdaParams(
    b: *FuncBuilder,
    f: *const ast.Function,
    marked_rlp: *std.ArrayList([]const u8),
    shared_rlp_here: *std.ArrayList([]const u8),
) Allocator.Error!void {
    for (f.params) |*p| {
        const has_recv = if (p.ty.function) |ft| ft.receiver != null else false;
        if (has_recv and b.isReceiverLambdaParam(p.name.name)) {
            // Already marked by an enclosing splice: ownership is shared, and the
            // caller-body suspension must keep it.
            try b.noteSharedRlpMark(p.name.name);
            try shared_rlp_here.append(b.allocator, p.name.name);
        }
        if (has_recv and !b.isReceiverLambdaParam(p.name.name)) {
            try b.markReceiverLambdaParam(p.name.name);
            // Record the declared receiver head so a spliced lambda body's bare calls
            // hint the lambda's receiver, not the enclosing fn's; a type-parameter
            // head records no hint.
            const rhead = p.ty.function.?.receiver.?.name.name;
            var head_is_tp = false;
            for (f.type_params) |tp| {
                if (std.mem.eql(u8, tp.name.name, rhead)) head_is_tp = true;
            }
            try b.setReceiverLambdaRecvHead(p.name.name, if (head_is_tp) null else rhead);
            try b.noteSpliceRlpMark(p.name.name);
            try marked_rlp.append(b.allocator, p.name.name);
        }
    }
}

/// The member body's bare sibling calls must lower as member-shadowable dispatch
/// on the bound `this`, so activate the owner class and its hierarchy's
/// member-name set over the caller's parked ones.
fn installMemberSpliceScope(
    b: *FuncBuilder,
    f: *const ast.Function,
    member_scope_prev_owner: *?[]const u8,
    member_scope_prev_members: *?build.StringSet,
) void {
    const owner = inline_state.inlineMemberOwner(f).?;
    member_scope_prev_owner.* = b.owner_class;
    b.owner_class = owner;
    var merged = build.StringSet.init(b.allocator);
    var ok = true;
    {
        var it = b.enclosing_members.keyIterator();
        while (it.next()) |k| merged.put(k.*, {}) catch {
            ok = false;
            break;
        };
    }
    if (ok) {
        if (b.module.registry.hierarchy_methods.get(owner)) |methods| {
            var mit = methods.keyIterator();
            while (mit.next()) |k| merged.put(k.*, {}) catch {};
        }
        var prev = merged;
        std.mem.swap(build.StringSet, &prev, &b.enclosing_members);
        member_scope_prev_members.* = prev;
    } else {
        merged.deinit();
    }
}

/// The bound receiver shadows `this` for the body, so join the subject-bind stack
/// and let a nested member-inline splice find its owner's receiver. `this@<fn>`
/// inside the spliced body, anon-object members included, must reach the splice
/// receiver, which a real call binds at function entry.
fn bindSpliceReceiverSubject(
    b: *FuncBuilder,
    fname: []const u8,
    explicit_receiver: ?Reg,
) Allocator.Error!void {
    if (explicit_receiver) |receiver| {
        // The bound receiver shadows `this` for the body, so join the subject-bind
        // stack and let a nested member-inline splice find its owner's receiver.
        try b.subject_binds.append(b.allocator, .{
            .reg = receiver,
            .head = b.spliceRecvTy(),
            // The body floor hides the caller's `this`; the subject record keeps it
            // for reads a nested window must bind beneath the subjects.
            .prior_this = b.resolveIgnoringFloor("this"),
        });
        try b.bind("this", receiver);
        if (inline_state.runtime.envOnce("KLIO_THIS_TRACE") != null) {
            std.debug.print("[splice-bind] {s} this=r{d} scope={d}\n", .{ fname, receiver.int(), b.scopes.items.len - 1 });
        }
        // `this@<fn>` inside the spliced body, anon-object members included, must
        // reach the splice receiver, which a real call binds at function entry.
        const label = try std.fmt.allocPrint(b.allocator, "this@{s}", .{fname});
        try b.bind(label, receiver);
    }
}

/// A bare member-inline call inside spliced-subject regions dispatches on the
/// innermost receiver whose class reaches the owner; when no subject can receive
/// the member the body's `this` is the owning receiver further out.
fn bindOwnerImplicitThis(
    b: *FuncBuilder,
    f: *const ast.Function,
    this_arg: ?*const Expr,
) Allocator.Error!void {
    if (!(this_arg == null and inline_state.inlineMemberOwner(f) != null and
        b.subject_binds.items.len != 0)) return;
    owner_this: {
        const owner = inline_state.inlineMemberOwner(f).?;
        const owner_base = if (std.mem.find(u8, owner, "$f")) |oi| owner[0..oi] else owner;
        var si = b.subject_binds.items.len;
        while (si > 0) {
            si -= 1;
            const sb = b.subject_binds.items[si];
            // An unknown subject head cannot be disproven a receiver, so keep the
            // ambient binding.
            const h = sb.head orelse break :owner_this;
            if (b.module.classIsOrExtends(h, owner) or
                b.module.classIsOrExtends(h, owner_base))
            {
                // This subject receives the call. Innermost is already the ambient
                // `this`; an outer one rebinds to its reg.
                if (si != b.subject_binds.items.len - 1) {
                    try b.bind("this", sb.reg);
                }
                break :owner_this;
            }
        }
        const outer = b.subject_binds.items[0].prior_this orelse break :owner_this;
        try b.bind("this", outer);
    }
}

/// Record each parameter's declared type with this splice's reified substitutions
/// applied, so a nested reified inline call passing them along solves its own type
/// parameters lexically.
fn bindSpliceParamTypes(
    b: *FuncBuilder,
    fname: []const u8,
    f: *const ast.Function,
    splice_ty_restores: *std.ArrayList(SpRestore),
) Allocator.Error!void {
    for (f.params) |*p| {
        const sub = try substReifiedInTypeRef(b, &p.ty);
        const sprev = try b.bindSpliceParamTy(p.name.name, sub);
        try splice_ty_restores.append(b.allocator, .{ .name = p.name.name, .prev = sprev });
        if (inline_state.runtime.envOnce("KLIO_SPLICE_TRACE")) |w| {
            if (std.mem.eql(u8, w, fname)) std.debug.print("[splice] {s} bound {s}: {s}\n", .{ fname, p.name.name, sub.name.name });
        }
    }
}

/// The callee's non-reified type-parameter bounds ride along with its param types,
/// without which the head names nothing and every member call on such a parameter
/// stays dynamic. Marked incomplete: the record supports the receiver-owner lookup,
/// never a negative proof.
fn bindSpliceTypeParamBounds(
    b: *FuncBuilder,
    f: *const ast.Function,
    splice_bound_restores: *std.ArrayList(build.FuncBuilder.SpliceBoundRestore),
) Allocator.Error!void {
    for (f.type_params) |*tp| {
        if (tp.is_reified) continue;
        const bound_ty: ?*const ast.TypeRef = blk: {
            if (tp.upper_bound) |*ub| break :blk ub;
            for (f.where_bounds) |*wb| {
                if (std.mem.eql(u8, wb.name.name, tp.name.name)) break :blk &wb.bound;
            }
            break :blk null;
        };
        const ub = bound_ty orelse continue;
        if (ub.function != null or ub.qualified_path != null or ub.name.name.len == 0) continue;
        const r = try b.bindSpliceTypeParamBound(tp.name.name, .{
            .param = tp.name.name,
            .bound = ub.name.name,
            .complete = false,
            .head_only = !ub.nullable,
        });
        try splice_bound_restores.append(b.allocator, r);
    }
}

/// Mark body-declared `var`s a nested closure writes as boxed, so their decl emits
/// `MakeCell`. Params were boxed at bind time; newly-boxed names are recorded so
/// the mark is removed after the splice.
fn markSpliceBodyBoxedVars(
    b: *FuncBuilder,
    f: *const ast.Function,
    splice_boxed: *const ast_scan.StringSet,
    boxed_here: *std.ArrayList([]const u8),
) Allocator.Error!void {
    var sit = splice_boxed.keyIterator();
    while (sit.next()) |k| {
        if (paramIndex(f, k.*) != null) continue; // params handled at bind time
        if (!b.isBoxed(k.*)) {
            try b.markBoxed(k.*);
            try boxed_here.append(b.allocator, k.*);
        }
    }
}

/// A caller reified-type binding this splice shadows.
const ReifiedRestore = struct { name: []const u8, prev: ?Reg };

/// A caller reified type-name substitution this splice shadows.
const NameRestore = struct { name: []const u8, prev: ?[]const u8 };

/// A forwarded inline lambda is caller-of-caller code: its free names, bare-call
/// hints and receiver context belong to the frame it was forwarded from, so when
/// every substituted lambda is forwarded, inherit that frame's provenance.
fn pushSpliceLambdaFrame(
    b: *FuncBuilder,
    lambda_map: std.StringHashMap(*const ast.Expr),
    caller_scope_depth: *usize,
    prev_hint_active: bool,
    prev_hint_recv: ?[]const u8,
    prev_this_narrow: ?[]const u8,
    any_forwarded_lambda: bool,
    any_literal_lambda: bool,
) Allocator.Error!void {
    var frame_hint_active = prev_hint_active;
    var frame_hint_recv = prev_hint_recv;
    var frame_this_narrow = prev_this_narrow;
    if (any_forwarded_lambda and !any_literal_lambda) {
        if (b.inlineLambdaCallerDepth()) |d| caller_scope_depth.* = d;
        if (b.inlineLambdaCallerHint()) |h| {
            frame_hint_active = h.active;
            frame_hint_recv = h.recv;
            frame_this_narrow = h.this_narrow;
        }
    }
    try b.pushInlineLambdaFrameHinted(lambda_map, caller_scope_depth.*, frame_hint_active, frame_hint_recv, frame_this_narrow);
}

/// Explicit `<…>` type arguments win; an unspecified reified parameter is
/// inferred by unifying the declared return against the call's expected type,
/// falling back to the caller-frame probe. The callee frame is pushed by now, so
/// argument-derived bindings rename nested classes through the caller's lexical
/// owner.
fn effectiveReifiedTypeArgs(
    b: *FuncBuilder,
    fname: []const u8,
    f: *const ast.Function,
    type_args: []const TypeRef,
    expected: ?*const TypeRef,
    ordered: []?*const Expr,
    this_arg: ?*const Expr,
    caller_probe: ?[]?TypeRef,
) Allocator.Error![]?TypeRef {
    const effective_type_args = try inferReifiedTypeArgsRecv(b.allocator, f, type_args, expected, ordered, b, this_arg);
    stripReifiedProjections(effective_type_args);
    if (caller_probe) |cp| {
        for (effective_type_args, 0..) |*eff, i| {
            if (eff.* == null and i < cp.len) eff.* = cp[i];
        }
    }
    if (inline_state.runtime.envOnce("KLIO_SPLICE_TRACE")) |w| {
        if (std.mem.eql(u8, w, fname)) {
            for (f.type_params, 0..) |tp, i| {
                if (!tp.is_reified) continue;
                const bound: []const u8 = if (effective_type_args[i]) |t| t.name.name else "<unbound>";
                std.debug.print("[splice] {s} reified {s} effective={s}\n", .{ fname, tp.name.name, bound });
            }
        }
    }
    return effective_type_args;
}

/// Bind each reified type parameter to the resolved class value at the call site,
/// in two places: locally, so the body's `T::class` read lowers as a bare `T` Path
/// plus MemberRef `.class`; and as a global named "T", which
/// `Inst::InstanceOf { ty: TypeRef "T" }` checks against, mirroring how
/// `call_func_typed` binds runtime type-args. Without the global, `x is T` tests a
/// non-existent class and falls through to `true`. The global is not saved or
/// restored, the same shape non-inline type-arg binding uses: a nested splice
/// overwrites it, and the restore happens implicitly when the enclosing call
/// returns.
fn bindReifiedTypeArgs(
    b: *FuncBuilder,
    fname: []const u8,
    f: *const ast.Function,
    effective_type_args: []const ?TypeRef,
    ordered: []?*const Expr,
    arg_regs: []const Reg,
    lexical_owner: ?[]const u8,
    reified_restores: *std.ArrayList(ReifiedRestore),
    reified_name_restores: *std.ArrayList(NameRestore),
) Allocator.Error!void {
    for (f.type_params, 0..) |tp, tp_idx| {
        if (!tp.is_reified) continue;
        const arg = if (tp_idx < effective_type_args.len) effective_type_args[tp_idx] else null;
        var cls_reg_opt: ?Reg = null;
        if (arg) |a| {
            // The stamped name resolves through the scope rename too, so a mangled
            // nested class reaches the runtime as its lifted name, and a
            // function-local class by its `$lc<fn>` alias.
            const local_alias: ?[]const u8 = blk: {
                var lc_buf: [160]u8 = undefined;
                const key = std.fmt.bufPrint(&lc_buf, "{s}$lc{s}", .{ a.name.name, build.currentRealFn() orelse "" }) catch break :blk null;
                if (b.module.registry.class_super_names.get(key) == null) break :blk null;
                break :blk b.allocator.dupe(u8, key) catch null;
            };
            // An arrow-form argument binds the arity-indexed `FunctionN` its `is`
            // and `as` checks compare against.
            const head_sub = if (a.function) |ft|
                try std.fmt.allocPrint(b.allocator, "Function{d}", .{ft.params.len + ft.context_params.len + @as(usize, @intFromBool(ft.receiver != null))})
            else
                local_alias orelse b.resolveReifiedTypeName(a.name.name) orelse
                    reifiedQualifiedName(b, a) orelse
                    (expr_lower.scopeTypeRenameFrom(b, lexical_owner, a.name.name, a.name.span.file.int()) orelse a.name.name);
            // Carry the full generic spelling, not just the head: a nested reified
            // consumer reads the stamped name and needs the arguments for the KType.
            const substituted = try renderReifiedTypeName(b, head_sub, &a);
            if (inline_state.runtime.envOnce("KLIO_SPLICE_TRACE")) |w| {
                if (std.mem.eql(u8, w, fname)) std.debug.print("[splice] {s} bind-name {s} := {s} (head_sub={s}, written={s}, owner={?s})\n", .{ fname, tp.name.name, substituted, head_sub, a.name.name, b.ownerClass() });
            }
            const nprev = try b.bindReifiedTypeName(tp.name.name, substituted);
            try reified_name_restores.append(b.allocator, .{ .name = tp.name.name, .prev = nprev });
        }
        if (arg) |a| {
            // A type argument naming an enclosing splice's reified parameter chains
            // lexically, reusing the class value the outer splice resolved.
            if (b.resolveReifiedType(a.name.name)) |reg| {
                cls_reg_opt = reg;
            } else {
                const cls_reg = b.allocReg();
                // A private or file-local nested class is lifted under a mangled
                // name, so resolve the type-arg name through the scope rename, the
                // same path a `Nested(args)` construction takes. A function-type
                // argument has the synthetic name `<function>`, which is not a
                // global, and Kotlin erases function types under reification anyway,
                // so bind it to `Any`. The bound class is the head.
                const bare_head = if (std.mem.findScalar(u8, a.name.name, '<')) |lt| a.name.name[0..lt] else a.name.name;
                const resolved_name = if (a.function != null or (functionTypeHead(bare_head) and b.module.classId(bare_head) == null))
                    "Any"
                else
                    reifiedQualifiedName(b, a) orelse
                        (expr_lower.scopeTypeRenameFrom(b, lexical_owner, bare_head, a.name.span.file.int()) orelse bare_head);
                const arg_name = try b.module.internConst(b.allocator, .{ .String = resolved_name });
                // Carry the resolved class identity so a builtin type whose bare name
                // resolves to a constructor intrinsic binds the `.Class` value
                // instead, matching how a concrete `Type::class` receiver lowers.
                const idx_pick = b.module.classIdIndexed(resolved_name, b.self_package, a.name.span.file);
                const flat_pick = b.module.classId(resolved_name);
                const cls_pick: ?ir.ClassId = idx_pick orelse flat_pick;
                // Constructor-ref semantics: a reified type argument binds the class
                // value, so a type with a `companion object` yields the class.
                try b.push(.{ .LoadGlobal = .{ .dst = cls_reg, .name = arg_name, .class = cls_pick, .ctor_ref = true } });
                cls_reg_opt = cls_reg;
            }
        } else if (callableRefParamFor(f, ordered, tp.name.name)) |pi| {
            // Inferred from a constructor-reference argument: the lowered reference
            // is the class value, so bind it directly.
            cls_reg_opt = arg_regs[pi];
        }
        const cls_reg = cls_reg_opt orelse continue;
        try b.bind(tp.name.name, cls_reg);
        const tp_global = try b.module.internConst(b.allocator, .{ .String = tp.name.name });
        try b.push(.{ .StoreGlobal = .{ .name = tp_global, .value = cls_reg } });
        const prev = try b.bindReifiedType(tp.name.name, cls_reg);
        try reified_restores.append(b.allocator, .{ .name = tp.name.name, .prev = prev });
    }
}

/// A body mentioning `return@<this fn>` may put that return inside a closure that
/// crosses a real frame, unwinding as a `LabeledReturn` toward a frame this splice
/// never creates, so a runtime absorption region is armed over the spliced body.
fn bodyNeedsLabeledReturnAbsorb(f: *const ast.Function, body: *const ast.FunctionBody) bool {
    switch (body.*) {
        .Block => |bb| {
            for (bb.stmts) |*st| if (ast_scan.containsLabeledReturnStmt(st, f.name.name)) return true;
        },
        .Expr => |*ex| if (ast_scan.containsLabeledReturn(ex, f.name.name)) return true,
    }
    return false;
}

/// Lowering the callee's own body: its loops are lexical for its own
/// `break`/`continue`, so suspend any enclosing spliced-lambda context, which a
/// lambda the body splices re-enters through `spliceInlineLambdaOn`.
fn lowerSplicedBody(
    b: *FuncBuilder,
    f: *const ast.Function,
    body: *const ast.FunctionBody,
) Allocator.Error!Reg {
    const prev_in_spliced = b.in_spliced_lambda_body;
    b.in_spliced_lambda_body = 0;
    b.lowering_inline_fn_body += 1;
    const body_val = switch (body.*) {
        // Lower an expression body with the inline function's own declared return
        // type as the expected tail-position type, so a tail-position reified call
        // infers from this function's return rather than the splice site's expected.
        .Expr => |*e| blk: {
            const prev = b.pushExpected(f.return_type);
            defer b.restoreExpected(prev);
            break :blk try lowerExpr(b, e);
        },
        .Block => |*blk| try lowerBlock(b, blk),
    };
    b.lowering_inline_fn_body -= 1;
    b.in_spliced_lambda_body = prev_in_spliced;
    return body_val;
}

/// Remove the marks, boxing flags and reified bindings this splice added, so a
/// same-named caller local keeps its own; the reified bindings unwind in reverse
/// order so nested same-named params restore correctly.
fn restoreSpliceMarks(
    b: *FuncBuilder,
    marked_rlp: []const []const u8,
    shared_rlp_here: []const []const u8,
    boxed_here: []const []const u8,
    reified_restores: []const ReifiedRestore,
) void {
    for (marked_rlp) |n| {
        b.unmarkReceiverLambdaParam(n);
        b.clearSpliceRlpMark(n);
    }
    for (shared_rlp_here) |n| b.clearSharedRlpMark(n);
    // Remove the boxing marks added for this splice so a same-named caller local
    // keeps its own boxed status.
    for (boxed_here) |n| b.unmarkBoxed(n);
    // Restore enclosing reified-type bindings shadowed by this splice, in reverse
    // order so nested same-named params unwind correctly.
    {
        var ri: usize = reified_restores.len;
        while (ri > 0) {
            ri -= 1;
            const rr = reified_restores[ri];
            b.restoreReifiedType(rr.name, rr.prev);
        }
    }
}

pub fn tryInlineCallWithTypeArgs(
    b: *FuncBuilder,
    fname: []const u8,
    target: ?*const ast.Function,
    args: []const Expr,
    arg_names: []const ?[]const u8,
    this_arg: ?*const Expr,
    type_args: []const TypeRef,
    expected: ?*const TypeRef,
) Allocator.Error!?Reg {
    const f = (try spliceTargetFor(b, fname, target, args, this_arg)) orelse return null;
    if (!memberExtVisibleAtCall(b, fname, target, f)) return null;
    if (b.inlineDeclInProgress(f)) return null;
    if (resultReceiverIsNative(f)) return null;
    if (typeOfIsReifiedIntrinsic(fname, f)) return null;
    traceSpliceEntry(fname, f, this_arg, type_args);
    // Materialise the body if it is a deferred image marker before reading it.
    inline_state.ensureInlineBody(f);
    const body = if (f.body) |*body_ref| body_ref else {
        spliceBail(fname, "no-body");
        return null;
    };

    const ordered = try b.allocator.alloc(?*const Expr, f.params.len);
    defer b.allocator.free(ordered);
    for (ordered) |*slot| slot.* = null;
    var vararg_value: ?*const Expr = null;
    if (!try orderInlineArgs(b, fname, f, args, arg_names, ordered, &vararg_value)) return null;
    const slot_is_default = try b.allocator.alloc(bool, ordered.len);
    defer b.allocator.free(slot_is_default);
    if (!fillInlineDefaultSlots(fname, f, ordered, slot_is_default)) return null;

    // This is the caller-frame inference: arguments are the caller's expressions, so
    // their typing belongs here, and the callee-frame pass may lose a derivation
    // that needs the caller's scope.
    var caller_probe: ?[]?TypeRef = null;
    defer if (caller_probe) |cp| b.allocator.free(cp);
    {
        const probe = try inferReifiedTypeArgsRecv(b.allocator, f, type_args, expected, ordered, b, this_arg);
        stripReifiedProjections(probe);
        caller_probe = probe;
        if (try declinesOnUnboundReified(b, fname, f, probe, ordered)) return null;
    }

    if (!enterInlineExpansion(fname, f)) return null;
    errdefer inline_state.inlineExpandLeave();
    const member_splice = f.receiver_type == null and this_arg != null and
        inline_state.inlineMemberOwner(f) != null;
    const explicit_receiver = try lowerSpliceReceiver(b, f, this_arg, member_splice);
    // The caller's lexical owner, for scope-true renames of the reified type
    // arguments bound below; the callee frame pushed next has none.
    const lexical_owner = b.ownerClass();
    try b.pushInlineDecl(fname, f);
    const prev_splice_recv = b.spliceRecvTy();
    try installSpliceRecvWindow(b, f, this_arg, member_splice);
    defer b.setSpliceRecvTy(prev_splice_recv);
    const recv_ref_owned = try spliceReceiverTypeRefOwned(b, f, this_arg);
    const prev_recv_ref = b.setSpliceRecvTyRef(recv_ref_owned);
    defer if (b.setSpliceRecvTyRef(prev_recv_ref)) |owned| {
        var t = owned;
        t.deinit(b.allocator);
    };
    var s4_restores: std.ArrayList(S4Restore) = .empty;
    defer s4_restores.deinit(b.allocator);
    defer for (s4_restores.items) |*sr| {
        if (sr.prev) |p| {
            b.addTypeParamBoundRef(sr.name, p) catch {};
        } else if (b.type_param_bound_refs.fetchRemove(sr.name)) |kv| {
            var v = kv.value;
            v.deinit(b.allocator);
        }
    };
    installSolvedTypeParamBounds(b, &s4_restores);
    // Bare-call hygiene for the spliced body: its bare calls resolve against the
    // inline fn's own receiver, never the caller's class. The pre-splice hint is
    // recorded on the inline-lambda frame so a spliced caller lambda restores it.
    const prev_hint_active = b.spliceHintActive();
    const prev_hint_recv = b.spliceHintRecv();
    b.setSpliceHint(true, if (f.receiver_type) |rt| rt.name.name else if (member_splice) inline_state.inlineMemberOwner(f) else null);
    defer b.setSpliceHint(prev_hint_active, prev_hint_recv);
    const prev_hint_recv_ref = b.setSpliceHintRecvRef(f.receiver_type);
    defer _ = b.setSpliceHintRecvRef(prev_hint_recv_ref);
    // The spliced body has its own receiver context, so the caller's smart-cast
    // narrow of `this` must not leak into it.
    const prev_this_narrow = b.setThisNarrow(null);
    defer _ = b.setThisNarrow(prev_this_narrow);
    // Scope depth before the inline fn binds its parameters: a lambda argument
    // spliced from this call resolves its free names in these caller scopes.
    var caller_scope_depth = b.scopeDepth();
    try b.pushScope();
    // The inline body lowers into the caller's builder, so its own `var` decls and
    // any inline parameter a nested closure writes must be boxed into a shared
    // `Value.Cell` here, exactly as a captured `var` is at a lambda boundary.
    // Otherwise the write takes the `StoreGlobal`-for-capture fallback, which only
    // round-trips on the stdlib-HOF scoped env. Newly boxed names are unboxed after
    // the splice so the mark never leaks onto a same-named caller local.
    var boxed_here: std.ArrayList([]const u8) = .empty;
    defer boxed_here.deinit(b.allocator);
    var splice_boxed = ast_scan.StringSet.init(b.allocator);
    defer splice_boxed.deinit();
    try computeSpliceBoxedNames(b, f, body, &splice_boxed);
    var lambda_map = std.StringHashMap(*const ast.Expr).init(b.allocator);
    const arg_regs = try b.allocator.alloc(Reg, f.params.len);
    defer b.allocator.free(arg_regs);
    // The caller's emitter computed instantiated expected param types per argument
    // slot, which this loop bypasses, so consume them here.
    const arg_lambda_param_types = b.pending_arg_lambda_param_types;
    b.pending_arg_lambda_param_types = null;
    var param_ty_saves: std.ArrayList(PTySave) = .empty;
    defer param_ty_saves.deinit(b.allocator);
    defer for (param_ty_saves.items) |*sv| {
        b.clearLocalDeclType(sv.name);
        if (sv.ty) |t| b.setLocalDeclTypeOwned(sv.name, t) catch {};
    };
    // Params already bound by earlier iterations must not capture a later
    // caller-supplied argument using the same name: Kotlin evaluates supplied
    // arguments in the caller's scope, and only a default-filled slot is callee code.
    var bound_param_names: std.ArrayList([]const u8) = .empty;
    defer bound_param_names.deinit(b.allocator);
    var arg_bind = InlineArgBind{
        .b = b,
        .fname = fname,
        .f = f,
        .args = args,
        .ordered = ordered,
        .slot_is_default = slot_is_default,
        .vararg_value = vararg_value,
        .arg_lambda_param_types = arg_lambda_param_types,
        .explicit_receiver = explicit_receiver,
        .splice_boxed = &splice_boxed,
        .arg_regs = arg_regs,
        .lambda_map = &lambda_map,
        .param_ty_saves = &param_ty_saves,
        .bound_param_names = &bound_param_names,
        .boxed_here = &boxed_here,
    };
    for (f.params, 0..) |*p, i| try bindInlineArg(&arg_bind, p, i);
    const any_forwarded_lambda = arg_bind.any_forwarded_lambda;
    const any_literal_lambda = arg_bind.any_literal_lambda;
    var marked_generic: std.ArrayList([]const u8) = .empty;
    defer marked_generic.deinit(b.allocator);
    try markInlineGenericTypedParams(b, f, &marked_generic);
    // Mark params whose declared type is a receiver-typed function so a bare
    // `block(...)` dispatches `this.block()`. Same record-and-remove discipline.
    var marked_rlp: std.ArrayList([]const u8) = .empty;
    defer marked_rlp.deinit(b.allocator);
    var shared_rlp_here: std.ArrayList([]const u8) = .empty;
    defer shared_rlp_here.deinit(b.allocator);
    try markInlineReceiverLambdaParams(b, f, &marked_rlp, &shared_rlp_here);
    // A forwarded inline lambda is caller-of-caller code: its free names, bare-call
    // hints and receiver context belong to the frame it was forwarded from, so when
    // every substituted lambda is forwarded, inherit that frame's provenance.
    try pushSpliceLambdaFrame(b, lambda_map, &caller_scope_depth, prev_hint_active, prev_hint_recv, prev_this_narrow, any_forwarded_lambda, any_literal_lambda);
    // An inline extension splice's body resolves names against the inline function's
    // own parameter and receiver scopes, not the caller lambda's free names, but a
    // nesting `lambda_splice_resolve` window skips the very scopes this splice binds
    // into. Suspend it after lowering the receiver expression, itself a caller free
    // name, and restore it after the body.
    // A member-inline fn spliced through an explicit receiver binds that receiver as
    // the body's `this` exactly like a receiver extension.
    const ext_splice = (f.receiver_type != null or member_splice) and this_arg != null;
    // The member body's bare sibling calls must lower as member-shadowable dispatch
    // on the bound `this`, so activate the owner class and its hierarchy's
    // member-name set. A spliced body resolves in its declaration scope, so park the
    // caller's member sets and lexical owner; member splices park too, their owner
    // swap installing the owner scope on top, and the call-site lambda swaps the
    // parked caller scope back in for its own nested-class ctors.
    // `KLIO_SPLICE_HYG=0` disables.
    var hyg_snap: build.FuncBuilder.MemberScopeSnapshot = undefined;
    const hyg_active = (ext_splice or member_splice) and
        !std.mem.eql(u8, inline_state.runtime.envOnce("KLIO_SPLICE_HYG") orelse "1", "0");
    if (hyg_active) b.beginSpliceDeclScope(&hyg_snap);
    defer if (hyg_active) b.endSpliceDeclScope(&hyg_snap);
    var member_scope_prev_owner: ?[]const u8 = null;
    var member_scope_prev_members: ?build.StringSet = null;
    // The body's lexical scope is the owner class, not the call site, so bare names
    // in a spliced member body never bind a caller local. The floor covers the whole
    // splice; the caller-lambda window overrides it while an arg lambda lowers.
    var prev_body_floor: ?usize = null;
    var body_floor_set = false;
    // A spliced body resolves bare names in the callee's scope, the caller's locals
    // sitting below the floor for member and extension splices alike. The splice's
    // own parameters bind above the floor.
    if (hyg_active) {
        prev_body_floor = b.splice_body_floor;
        b.splice_body_floor = caller_scope_depth;
        body_floor_set = true;
    }
    defer if (body_floor_set) {
        b.splice_body_floor = prev_body_floor;
    };
    if (member_splice) installMemberSpliceScope(b, f, &member_scope_prev_owner, &member_scope_prev_members);
    defer if (member_splice) {
        b.owner_class = member_scope_prev_owner;
        if (member_scope_prev_members) |pm| {
            b.enclosing_members.deinit();
            b.enclosing_members = pm;
        }
    };
    var prev_splice_window: @TypeOf(b.lambda_splice_resolve) = null;
    if (inline_state.runtime.envOnce("KLIO_SPLICE_TRACE")) |w| {
        if (std.mem.eql(u8, w, fname)) std.debug.print("[splice] {s} recv={} ext={} member={} this_arg={}\n", .{ fname, explicit_receiver != null, f.receiver_type != null, member_splice, this_arg != null });
    }
    // An extension splice's bound receiver is an implicit receiver inner to any
    // spliced lambda subject already on the tower, so push it too. Only while a
    // tower region is active: outside one, emissions pin the bound register.
    const encl_ext_pushed = explicit_receiver != null and rfsEnabled() and b.encl_tower_depth > 0;
    const prev_ext_tower_top = b.encl_tower_top;
    if (encl_ext_pushed) {
        try b.push(.{ .EnclosingPush = .{ .src = explicit_receiver.? } });
        b.encl_tower_depth += 1;
        b.encl_tower_top = explicit_receiver.?;
    }
    const ext_subject_pushed = explicit_receiver != null;
    try bindSpliceReceiverSubject(b, fname, explicit_receiver);
    defer if (ext_subject_pushed) {
        _ = b.subject_binds.pop();
    };
    try bindOwnerImplicitThis(b, f, this_arg);
    if (ext_splice) {
        prev_splice_window = b.lambda_splice_resolve;
        b.lambda_splice_resolve = null;
    }
    // Bind each reified type parameter to the resolved class value at the call site,
    // in two places: locally, so the body's `T::class` read lowers as a bare `T`
    // Path plus MemberRef `.class`; and as a global named "T", which
    // `Inst::InstanceOf { ty: TypeRef "T" }` checks against, mirroring how
    // `call_func_typed` binds runtime type-args. Without the global, `x is T` tests
    // a non-existent class and falls through to `true`.
    //
    // The global is not saved or restored, the same shape non-inline type-arg
    // binding uses: a nested splice overwrites it, and the restore happens
    // implicitly when the enclosing call returns.
    // Explicit `<…>` type arguments win; an unspecified reified parameter is
    // inferred by unifying the declared return against the call's expected type. The
    // callee frame is pushed by now, so argument-derived bindings rename nested
    // classes through the caller's lexical owner.
    const prev_splice_owner = splice_lexical_owner;
    splice_lexical_owner = lexical_owner;
    defer splice_lexical_owner = prev_splice_owner;
    const effective_type_args = try effectiveReifiedTypeArgs(b, fname, f, type_args, expected, ordered, this_arg, caller_probe);
    defer b.allocator.free(effective_type_args);
    var reified_restores: std.ArrayList(ReifiedRestore) = .empty;
    defer reified_restores.deinit(b.allocator);
    // Name substitutions for the splice's reified params, consumed by `emitCall` and
    // `emitExtBareCall` to stamp static type args onto nested calls in the body.
    var reified_name_restores: std.ArrayList(NameRestore) = .empty;
    defer reified_name_restores.deinit(b.allocator);
    defer for (reified_name_restores.items) |nr| b.restoreReifiedTypeName(nr.name, nr.prev);
    try bindReifiedTypeArgs(b, fname, f, effective_type_args, ordered, arg_regs, lexical_owner, &reified_restores, &reified_name_restores);
    // Record each parameter's declared type with this splice's reified substitutions
    // applied, so a nested reified inline call passing them along solves its own
    // type parameters lexically.
    var splice_ty_restores: std.ArrayList(SpRestore) = .empty;
    defer splice_ty_restores.deinit(b.allocator);
    defer for (splice_ty_restores.items) |sr| b.restoreSpliceParamTy(sr.name, sr.prev);
    try bindSpliceParamTypes(b, fname, f, &splice_ty_restores);
    // The callee's non-reified type-parameter bounds ride along with its param
    // types, without which the head names nothing and every member call on such a
    // parameter stays dynamic. Marked incomplete: the record supports the
    // receiver-owner lookup, never a negative proof.
    var splice_bound_restores: std.ArrayList(build.FuncBuilder.SpliceBoundRestore) = .empty;
    defer splice_bound_restores.deinit(b.allocator);
    defer for (splice_bound_restores.items) |sb| b.restoreSpliceTypeParamBound(sb);
    try bindSpliceTypeParamBounds(b, f, &splice_bound_restores);
    try markSpliceBodyBoxedVars(b, f, &splice_boxed, &boxed_here);
    const result = b.allocReg();
    const unit0 = try b.emitConst(Const.Unit);
    try b.push(.{ .Move = .{ .dst = result, .src = unit0 } });
    const join = try b.allocBlock();
    try b.pushInlineReturn(result, join, f.name.name);
    // A body mentioning `return@<this fn>` may put that return inside a closure that
    // crosses a real frame, unwinding as a `LabeledReturn` toward a frame this splice
    // never creates, so arm a runtime absorption region over the spliced body.
    const needs_lr_absorb = bodyNeedsLabeledReturnAbsorb(f, body);
    if (needs_lr_absorb and inline_state.runtime.envOnce("KLIO_NO_LR_ABSORB") == null) {
        const region = try b.allocBlock();
        b.terminate(.{ .Goto = region });
        b.switchTo(region);
        b.setLrAbsorb(region, f.name.name, join, result);
    }
    // Lowering the callee's own body: its loops are lexical for its own
    // `break`/`continue`, so suspend any enclosing spliced-lambda context, which a
    // lambda the body splices re-enters through `spliceInlineLambdaOn`.
    const body_val = try lowerSplicedBody(b, f, body);
    try b.push(.{ .Move = .{ .dst = result, .src = body_val } });
    if (ext_splice) b.lambda_splice_resolve = prev_splice_window;
    b.terminate(.{ .Goto = join });
    b.switchTo(join);
    if (encl_ext_pushed) {
        try b.push(.{ .EnclosingPop = .{} });
        b.encl_tower_depth -= 1;
        b.encl_tower_top = prev_ext_tower_top;
    }
    restoreSpliceMarks(b, marked_rlp.items, shared_rlp_here.items, boxed_here.items, reified_restores.items);
    b.popInlineReturn();
    b.popInlineLambdaFrame();
    try b.popScope();
    b.popInlineDecl();
    inline_state.inlineExpandLeave();
    return result;
}

/// The runtime-resolvable class name for a reified type argument: a qualified
/// nested reference resolves to its lifted `$`-mangled class, trying deeper nesting
/// when two segments miss; an unqualified name uses the scope-rename ladder.
fn reifiedQualifiedName(b: *FuncBuilder, a: ast.TypeRef) ?[]const u8 {
    // An inferred nested type argument carries its dotted spelling in `name`, not
    // `qualified_path`, so resolve either; the dotted head names a `.`-aligned
    // suffix of the nested class's lifted fqn.
    const qp = a.qualified_path orelse
        (if (std.mem.findScalar(u8, a.name.name, '.') != null and a.name.name[0] != '.')
            a.name.name
        else
            return null);
    // The dotted spelling is a `.`-aligned suffix of the class's fqn, whose
    // registered name is the lifted one the class table holds. That name can be a
    // bare simple name the index resolves to an unrelated classifier, so only a
    // spelling resolving back to this class may stand for it.
    const suffix_hit: ?ir.ClassId = b.module.classIdByQualifiedSuffix(qp);
    if (suffix_hit) |cid| {
        if (cid.int() < b.module.classes.items.len) {
            const nm = b.module.classes.items[cid.int()].name;
            const back = b.module.classIdIndexed(nm, b.self_package, a.name.span.file) orelse b.module.classId(nm);
            if (back != null and back.?.int() == cid.int()) return nm;
        }
    }
    var segs: [8][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, qp, '.');
    while (it.next()) |seg| {
        if (n == segs.len) return null;
        segs[n] = seg;
        n += 1;
    }
    if (n < 2) return null;
    var k: usize = 2;
    while (k <= n) : (k += 1) {
        var buf: std.ArrayList(u8) = .empty;
        for (segs[n - k .. n], 0..) |seg, i| {
            if (i != 0) buf.append(b.allocator, '$') catch return null;
            buf.appendSlice(b.allocator, seg) catch return null;
        }
        const cand = buf.toOwnedSlice(b.allocator) catch return null;
        const ccid_opt = b.module.classIdIndexed(cand, b.self_package, a.name.span.file);
        if (ccid_opt) |ccid| {
            if (suffix_hit == null or ccid.int() == suffix_hit.?.int()) return cand;
        }
    }
    return null;
}

fn paramIndex(f: *const Function, name: []const u8) ?usize {
    for (f.params, 0..) |p, i| {
        if (std.mem.eql(u8, p.name.name, name)) return i;
    }
    return null;
}

/// Clone `ty` with the builder's active reified name substitutions applied,
/// recursing through generic arguments and function-type positions.
fn substReifiedInTypeRef(b: *FuncBuilder, ty: *const TypeRef) Allocator.Error!TypeRef {
    var out = ty.*;
    if (b.resolveReifiedTypeName(ty.name.name)) |actual| {
        out.name = .{ .name = actual, .span = ty.name.span };
    }
    if (ty.type_args.len != 0) {
        const targs = try b.allocator.alloc(ast.TypeArg, ty.type_args.len);
        for (ty.type_args, 0..) |ta, i| {
            targs[i] = ta;
            if (!ta.is_star) targs[i].ty = try substReifiedInTypeRef(b, &ta.ty);
        }
        out.type_args = targs;
    }
    if (ty.function) |ft| {
        const nf = try b.allocator.create(ast.FunctionTypeRef);
        nf.* = ft.*;
        if (ft.receiver) |*r| nf.receiver = try substReifiedInTypeRef(b, r);
        const nparams = try b.allocator.alloc(TypeRef, ft.params.len);
        for (ft.params, 0..) |*p, i| nparams[i] = try substReifiedInTypeRef(b, p);
        nf.params = nparams;
        nf.ret = try substReifiedInTypeRef(b, &ft.ret);
        out.function = nf;
    }
    return out;
}

/// Whether every reified type parameter of `f` is solvable from the call's
/// non-lambda arguments, which keeps a splice whose trailing lambda under-declares
/// the function-typed parameter's arity.
/// `reifiedArgNamesFromArgs` resolves the reified type-argument names a call binds
/// by inference, mapped through the active splice substitutions and scope renames,
/// ready to stamp on a typed dispatch instruction.
pub fn inferReifiedNamesForCall(
    b: *FuncBuilder,
    f: *const Function,
    args: []const Expr,
    arg_names: []const ?[]const u8,
    file: u32,
) ?[]const []const u8 {
    const ordered = b.allocator.alloc(?*const Expr, f.params.len) catch return null;
    defer b.allocator.free(ordered);
    for (ordered) |*slot| slot.* = null;
    const last_is_lambda = args.len > 0 and switch (args[args.len - 1]) {
        .Lambda, .AnonFun => true,
        else => false,
    };
    const lambda_to_last = last_is_lambda and args.len <= f.params.len and f.params.len > 0;
    if (lambda_to_last) ordered[f.params.len - 1] = &args[args.len - 1];
    const positional_n = if (lambda_to_last) args.len - 1 else args.len;
    var next_pos: usize = 0;
    for (args[0..positional_n], 0..) |*a, i| {
        const nm: ?[]const u8 = if (i < arg_names.len) arg_names[i] else null;
        if (nm) |name| {
            const idx = paramIndex(f, name) orelse return null;
            ordered[idx] = a;
        } else {
            while (next_pos < ordered.len and ordered[next_pos] != null) next_pos += 1;
            if (next_pos >= ordered.len) {
                if (inline_state.runtime.envOnce("KLIO_SAM_TRACE") != null) std.debug.print("[irnfc] {s}: positional-overflow args={d} params={d}\n", .{ f.name.name, args.len, f.params.len });
                return null;
            }
            ordered[next_pos] = a;
            next_pos += 1;
        }
    }
    const probe = inferReifiedTypeArgs(b.allocator, f, &.{}, null, ordered, b) catch return null;
    defer b.allocator.free(probe);
    var out: std.ArrayList([]const u8) = .empty;
    for (f.type_params, 0..) |tp, i| {
        if (!tp.is_reified) continue;
        const t = probe[i] orelse {
            if (inline_state.runtime.envOnce("KLIO_SAM_TRACE") != null) std.debug.print("[irnfc] {s}: {s} unbound (args={d} params={d})\n", .{ f.name.name, tp.name.name, args.len, f.params.len });
            out.deinit(b.allocator);
            return null;
        };
        const head = b.resolveReifiedTypeName(t.name.name) orelse
            (expr_lower.scopeTypeRename(b, t.name.name, file) orelse t.name.name);
        // The full generic spelling: a typed member call binds its reified parameter
        // by name at runtime, and `typeOf<T>()` there needs the arguments.
        const substituted = renderReifiedTypeName(b, head, &t) catch {
            if (inline_state.runtime.envOnce("KLIO_SAM_TRACE") != null) std.debug.print("[irnfc] {s}: {s} render-fail head={s}\n", .{ f.name.name, tp.name.name, head });
            out.deinit(b.allocator);
            return null;
        };
        if (inline_state.runtime.envOnce("KLIO_SAM_TRACE") != null) std.debug.print("[irnfc] {s}: {s} := {s} (probe={s})\n", .{ f.name.name, tp.name.name, substituted, t.name.name });
        out.append(b.allocator, substituted) catch {
            out.deinit(b.allocator);
            return null;
        };
    }
    if (out.items.len == 0) {
        out.deinit(b.allocator);
        return null;
    }
    return out.toOwnedSlice(b.allocator) catch null;
}

pub fn reifiedBindableFromArgs(
    b: *const FuncBuilder,
    f: *const Function,
    args: []const Expr,
    arg_names: []const ?[]const u8,
) bool {
    const ordered = b.allocator.alloc(?*const Expr, f.params.len) catch return false;
    defer b.allocator.free(ordered);
    for (ordered) |*slot| slot.* = null;
    const last_is_lambda = args.len > 0 and switch (args[args.len - 1]) {
        .Lambda, .AnonFun => true,
        else => false,
    };
    const lambda_to_last = last_is_lambda and args.len <= f.params.len and f.params.len > 0;
    if (lambda_to_last) ordered[f.params.len - 1] = &args[args.len - 1];
    const positional_n = if (lambda_to_last) args.len - 1 else args.len;
    var next_pos: usize = 0;
    for (args[0..positional_n], 0..) |*a, i| {
        const nm: ?[]const u8 = if (i < arg_names.len) arg_names[i] else null;
        if (nm) |name| {
            const idx = paramIndex(f, name) orelse return false;
            ordered[idx] = a;
        } else {
            while (next_pos < ordered.len and ordered[next_pos] != null) next_pos += 1;
            if (next_pos >= ordered.len) return false;
            ordered[next_pos] = a;
            next_pos += 1;
        }
    }
    const probe = inferReifiedTypeArgs(b.allocator, f, &.{}, null, ordered, b) catch return false;
    defer b.allocator.free(probe);
    for (f.type_params, 0..) |tp, i| {
        if (tp.is_reified and probe[i] == null) return false;
    }
    return true;
}

/// Index of a parameter that solves type parameter `tp_name` from a
/// constructor-reference argument: its declared type is a function type returning
/// the bare parameter, and the argument is a `Type::Nested` constructor reference,
/// whose lowered value is the referenced class.
fn callableRefParamFor(f: *const Function, ordered: []const ?*const Expr, tp_name: []const u8) ?usize {
    for (f.params, 0..) |*p, i| {
        const ft = p.ty.function orelse continue;
        if (ft.ret.function != null or ft.ret.type_args.len != 0) continue;
        if (!std.mem.eql(u8, ft.ret.name.name, tp_name)) continue;
        const a = (if (i < ordered.len) ordered[i] else null) orelse continue;
        if (isTypeConstructorRef(a)) return i;
    }
    return null;
}

/// Whether an expression is a `Type::Nested` constructor reference: a `MemberRef`
/// whose receiver is a type-name path and whose member names a type. A lowercase
/// member is a bound callable, not a class.
fn isTypeConstructorRef(e: *const Expr) bool {
    return switch (e.*) {
        .MemberRef => |mr| nameLooksLikeType(mr.name.name) and isTypeNamePath(mr.receiver),
        // `::Name`: a bare constructor reference.
        .PropertyRef => |pr| nameLooksLikeType(pr.name.name),
        else => false,
    };
}

/// The class a constructor reference names (`::Sub`, `Outer::Sub`),
/// null for anything else.
fn typeConstructorRefName(e: *const Expr) ?[]const u8 {
    return switch (e.*) {
        .MemberRef => |mr| if (nameLooksLikeType(mr.name.name) and isTypeNamePath(mr.receiver)) mr.name.name else null,
        .PropertyRef => |pr| if (nameLooksLikeType(pr.name.name)) pr.name.name else null,
        else => null,
    };
}

fn isTypeNamePath(e: *const Expr) bool {
    return switch (e.*) {
        .Path => |p| blk: {
            if (p.segments.len == 0) break :blk false;
            for (p.segments) |s| {
                if (!nameLooksLikeType(s.name)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

fn nameLooksLikeType(n: []const u8) bool {
    return n.len > 0 and n[0] >= 'A' and n[0] <= 'Z';
}


const testing = std.testing;
const span = @import("span");

test {
    testing.refAllDecls(@This());
}

fn dummySpan() span.Span {
    return span.Span.init(span.FileId.from(0), 0, 0);
}

fn ident(name: []const u8) ast.Ident {
    return .{ .name = name, .span = dummySpan() };
}

test "arg_lambda_has_nonlocal_return detects bare return" {
    var ret = Expr{ .Return = .{ .value = null, .label = null, .span = dummySpan() } };
    var stmts = [_]Stmt{.{ .Expr = ret }};
    const lam = Expr{ .Lambda = .{
        .params = &.{},
        .body = .{ .stmts = &stmts, .span = dummySpan() },
        .span = dummySpan(),
    } };
    const args = [_]Expr{lam};
    try testing.expect(argLambdaHasNonlocalReturn(&args));
    _ = &ret;
}

test "arg_lambda_has_nonlocal_return ignores nested lambda return" {
    // A `return` inside a nested lambda is local to that lambda.
    var inner_ret = Expr{ .Return = .{ .value = null, .label = null, .span = dummySpan() } };
    var inner_stmts = [_]Stmt{.{ .Expr = inner_ret }};
    const inner_lam = Expr{ .Lambda = .{
        .params = &.{},
        .body = .{ .stmts = &inner_stmts, .span = dummySpan() },
        .span = dummySpan(),
    } };
    var outer_stmts = [_]Stmt{.{ .Expr = inner_lam }};
    const outer_lam = Expr{ .Lambda = .{
        .params = &.{},
        .body = .{ .stmts = &outer_stmts, .span = dummySpan() },
        .span = dummySpan(),
    } };
    const args = [_]Expr{outer_lam};
    try testing.expect(!argLambdaHasNonlocalReturn(&args));
    _ = &inner_ret;
}

test "arg_lambda_has_nonlocal_return scans nested control flow" {
    // `if (cond) return` inside a lambda body counts.
    var cond = Expr{ .BoolLit = .{ .value = true, .span = dummySpan() } };
    var ret = Expr{ .Return = .{ .value = null, .label = null, .span = dummySpan() } };
    const if_expr = Expr{ .If = .{
        .cond = &cond,
        .then_branch = &ret,
        .else_branch = null,
        .span = dummySpan(),
    } };
    var stmts = [_]Stmt{.{ .Expr = if_expr }};
    const lam = Expr{ .Lambda = .{
        .params = &.{},
        .body = .{ .stmts = &stmts, .span = dummySpan() },
        .span = dummySpan(),
    } };
    const args = [_]Expr{lam};
    try testing.expect(argLambdaHasNonlocalReturn(&args));
}

test "arg_lambda_has_nonlocal_return false for plain body" {
    var lit = Expr{ .IntLit = .{ .value = 1, .kind = .Int, .span = dummySpan() } };
    var stmts = [_]Stmt{.{ .Expr = lit }};
    const lam = Expr{ .Lambda = .{
        .params = &.{},
        .body = .{ .stmts = &stmts, .span = dummySpan() },
        .span = dummySpan(),
    } };
    const args = [_]Expr{lam};
    try testing.expect(!argLambdaHasNonlocalReturn(&args));
    _ = &lit;
}

test "arg_lambda_has_nonlocal_return false for non-lambda arg" {
    const lit = Expr{ .IntLit = .{ .value = 1, .kind = .Int, .span = dummySpan() } };
    const args = [_]Expr{lit};
    try testing.expect(!argLambdaHasNonlocalReturn(&args));
}

test "inline lambda forwarding preserves the original literal" {
    var module = ir.Module.default(testing.allocator);
    defer module.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &module);
    defer b.deinit();

    var lambda = Expr{ .Lambda = .{
        .params = &.{},
        .body = .{ .stmts = &.{}, .span = dummySpan() },
        .span = dummySpan(),
    } };
    var substitutions = std.StringHashMap(*const ast.Expr).init(testing.allocator);
    try substitutions.put("block", &lambda);
    try b.pushInlineLambdaFrame(substitutions, b.scopeDepth());
    defer b.popInlineLambdaFrame();

    var segments = [_]ast.Ident{ident("block")};
    const forwarded = Expr{ .Path = .{ .segments = &segments, .span = dummySpan() } };
    const args = [_]Expr{forwarded};
    try testing.expectEqual(&lambda, forwardedInlineLambda(&b, &forwarded).?);
    try testing.expect(argsForwardInlineLambda(&b, &args));
}

fn typeRef(name: []const u8) TypeRef {
    return .{
        .name = ident(name),
        .nullable = false,
        .span = dummySpan(),
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
}

test "unify_type_param binds a bare type parameter" {
    var tp_names = std.StringHashMap(void).init(testing.allocator);
    defer tp_names.deinit();
    try tp_names.put("T", {});
    var subst = std.StringHashMap(TypeRef).init(testing.allocator);
    defer subst.deinit();
    const decl = typeRef("T");
    const actual = typeRef("User");
    try unifyTypeParam(&decl, &actual, &tp_names, &subst);
    const got = subst.get("T") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("User", got.name.name);
}

test "unify_type_param recurses through generic args" {
    var tp_names = std.StringHashMap(void).init(testing.allocator);
    defer tp_names.deinit();
    try tp_names.put("T", {});
    var subst = std.StringHashMap(TypeRef).init(testing.allocator);
    defer subst.deinit();
    // decl: Box<T> ; actual: Box<Int> ; solves T = Int.
    var decl_args = [_]ast.TypeArg{.{
        .variance = .Invariant,
        .is_star = false,
        .ty = typeRef("T"),
        .span = dummySpan(),
    }};
    var actual_args = [_]ast.TypeArg{.{
        .variance = .Invariant,
        .is_star = false,
        .ty = typeRef("Int"),
        .span = dummySpan(),
    }};
    var decl = typeRef("Box");
    decl.type_args = &decl_args;
    var actual = typeRef("Box");
    actual.type_args = &actual_args;
    try unifyTypeParam(&decl, &actual, &tp_names, &subst);
    const got = subst.get("T") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Int", got.name.name);
}

/// A reified parameter inferred from a use-site projection binds the projected
/// type, never the projection marker, so `emptyArray<T>()` names a class.
fn stripReifiedProjections(args: []?TypeRef) void {
    for (args) |*slot| {
        if (slot.*) |*t| {
            if (std.mem.startsWith(u8, t.name.name, "out#")) {
                t.name.name = t.name.name["out#".len..];
            } else if (std.mem.startsWith(u8, t.name.name, "in#")) {
                t.name.name = t.name.name["in#".len..];
            }
        }
    }
}
