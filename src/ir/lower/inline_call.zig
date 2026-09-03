//! Inline-call lowering: expanding an `inline fun` body (and splicing its
//! lambda arguments) at the call site. Free functions over the shared
//! `FuncBuilder`; filled in alongside the expression dispatch.

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

/// Best-effort static type of a member call's receiver, used only to
/// disambiguate same-name reified inline extensions declared on different
/// receiver types. Handles the cases the ktor client surface needs:
/// an implicit/explicit `this` (the enclosing extension's receiver type),
/// and a chained call `recv.foo().bar()` (the inner call's declared return
/// type, looked up from a same-named non-extension function). Returns
/// `null` when the type can't be inferred cheaply — the caller then falls
/// back to shape-based overload resolution.
threadlocal var infer_recv_depth: u16 = 0;

pub fn inferReceiverType(b: *const FuncBuilder, this_arg: ?*const Expr) Allocator.Error!?[]const u8 {
    // A local's recorded initializer can reference the local itself
    // (`val x = x.rotateLeft(1)` shadowing an outer `x`), and the
    // init-expr recursion below then never terminates. Bound the depth;
    // real inference chains are a handful of hops.
    if (infer_recv_depth >= 16) return null;
    infer_recv_depth += 1;
    defer infer_recv_depth -= 1;
    const arg = this_arg orelse return b.thisNarrow() orelse b.recvTy();
    switch (arg.*) {
        // A smart-cast `this` (`when (this) { is List -> this.single() }`)
        // resolves against the narrowed type; `super` keeps the declared one.
        .This => return b.thisNarrow() orelse b.recvTy(),
        .Super => return b.recvTy(),
        .Call => |call| {
            // `recv.method(...)` — use the called function's declared return
            // type. Resolve by simple name against the lowered module's
            // functions, preferring a unique return type among candidates.
            const name = switch (call.callee.*) {
                .Member => |m| m.name.name,
                .Path => |p| if (p.segments.len == 1) p.segments[0].name else return null,
                else => return null,
            };
            // Tally concrete return types across the same-name overloads
            // and pick the most common one. A bare generic type parameter
            // (`V`/`T`), `Unit`, and the untyped case carry no information
            // and are ignored, so an operator `kotlin.collections.get(key):
            // V` neither vetoes nor competes with the ktor `get(...):
            // HttpResponse` extensions. The dominant concrete return wins;
            // an exact tie between two different concrete types is left
            // unresolved (`null`) so the caller keeps shape-based fallback.
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
        // A plain local: its declared annotation, or the inferred type of
        // its recorded initializer (`val resp = client.get(url)` makes
        // `resp.body<T>()` narrow to the `HttpResponse` overload).
        .Path => |p| {
            if (p.segments.len != 1) return null;
            const name = p.segments[0].name;
            if (b.localDeclType(name)) |t| return t;
            if (b.localInitExpr(name)) |e| return inferReceiverType(b, e);
            // Typeck fills the receiver head only when lexical declaration and
            // initializer evidence could not carry it into the nested body.
            if (b.module.eagerTypeOf(arg.span())) |t| return t.name;
            // A bare name that is not a local is a member of the enclosing
            // class, whose declared type is receiver evidence just as a
            // local's is. Without it a reified inline extension called on a
            // property receiver had NO receiver type, so its declaration was
            // never found and the splice bailed to a plain member dispatch —
            // where the reified `T` has nothing to bind to
            // (`modifierNode.dispatchForKind(Nodes.PointerInput) { … }` inside
            // `HitPathTracker.Node`).
            if (ownerMemberDeclType(b, name)) |t| return t;
            // A bare name that is neither a local nor a member names a TYPE:
            // an `object`, or a class reached through its companion
            // (`Json.decodeFromString<User>(s)` — the receiver is
            // `Json.Default`, a `Json`). The name IS the receiver's type head,
            // and it is the only evidence that can separate an extension
            // overload set spread over several receivers
            // (`Json.decodeFromString` next to `StringFormat.decodeFromString`).
            // Without it the splice declined and the reified `T` reached the
            // runtime unbound, where `T::class` reads an unresolved global.
            if (b.resolve(name) == null and !b.knowsOuter(name) and
                b.module.classId(name) != null) return name;
            return null;
        },
        else => return null,
    }
}

/// Receiver-head inference for the qualified member-inline splice gate:
/// `inferReceiverType` extended with the shapes that gate needs — a
/// constructor-call initializer (`val w = Walker()`), a member property
/// read (`slots.table`), and a splice-receiver member — WITHOUT changing
/// the shared inference every other inline pick consults.
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
            // An enclosing class's member property (`jsonNoAltNames.
            // decodeFromString(...)` inside the test class) types the
            // receiver through the owner's property heads.
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
        // An unsafe cast fixes the receiver's static type for resolution:
        // kotlinc resolves the member/extension through the cast's target
        // (`(firstStateRecord as StateMapStateRecord).withCurrent(block)`).
        .As => |a| {
            if (a.safe) return null;
            const nm2 = std.mem.trimEnd(u8, a.ty.name.name, "?");
            if (nm2.len == 0) return null;
            return nm2;
        },
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

/// The declared type head of member `name` on the enclosing class, searching
/// the class and then its transitive supertypes: a primary-constructor `val`
/// (`class Node(val modifierNode: Modifier.Node)`) or a body property. Null
/// when no enclosing class declares the name.
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

/// Does any argument that is a lambda literal contain a non-local
/// `return` in its own body (not descending into nested lambdas /
/// local functions, whose returns are their own)?
pub fn argLambdaHasNonlocalReturn(args: []const Expr) bool {
    for (args) |*a| {
        if (a.* == .Lambda) {
            if (scanStmts(a.Lambda.body.stmts)) return true;
        }
    }
    return false;
}

/// Does any argument lambda contain a call that can SUSPEND (any same-name
/// declaration is a suspend fn)? An inline fn's inline lambda inherits the
/// caller's suspend capability, so such a call site must SPLICE — the
/// host-served intrinsic route runs the lambda across a non-suspending
/// native boundary and a real suspension is lost (`toList()` =
/// `buildList { consumeEach { add(it) } }` dropped the consume).
/// Descends into nested lambdas: their suspension crosses this frame too.
pub fn argLambdaMaySuspend(b: *const FuncBuilder, f: *const ast.Function, args: []const Expr) bool {
    // The receiver heads a bare call inside the argument lambda can bind
    // against: each fn-typed parameter's declared lambda receiver, plus the
    // ENCLOSING function's own receiver (the receiver tower a spliced lambda
    // body still sees — `consumeEach` inside `toList()`'s builder binds
    // this@toList, a ReceiveChannel).
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
    // A suspend candidate counts only when the receivers visible to the
    // lambda body could actually bind it: it is receiverless, or its
    // declared receiver accepts one of the visible receiver heads. Without
    // the filter, ByteWriteChannel's suspend `writeInt` forced a splice of
    // ktor's `buildPacket { writeInt(1) }` — whose call binds the plain
    // Sink member — and the forced splice broke the receiver binding.
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
    if (std.mem.indexOfScalar(u8, h, '<')) |lt| h = h[0..lt];
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

/// Recover the original literal when an inline body forwards one of its
/// lambda parameters to another inline call. The forwarding expression is a
/// plain path in the callee body, but Kotlin keeps the original lambda inline
/// through the entire chain.
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

/// Whether any argument lambda literal contains a `return@LABEL` naming
/// `label` — used to keep a widened splice off calls whose own label the
/// lambda targets, so the label stays on a real frame.
pub fn argLambdaTargetsLabel(args: []const Expr, label: []const u8) bool {
    for (args) |*a| {
        if (a.* != .Lambda) continue;
        if (labelScanStmtsG(true, a.Lambda.body.stmts, label)) return true;
    }
    return false;
}

/// Whether any argument lambda contains a `return@LABEL` whose label is an
/// inline splice currently open in this builder — a FRAMELESS scope the
/// dynamic unwind can never find. Such a call must splice (kotlinc inlines
/// it); a labeled return targeting a real frame unwinds fine dynamically.
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


/// True when every reference to `name` in the callee body is the CALLEE
/// head of a call — i.e. the splice's call-position expansion consumes
/// every use and no value position remains. Conservative: any construct
/// this walk does not understand, a shadowing risk, or a bare value
/// occurrence returns false.
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
                    // A same-named local re-declaration shadows below; too
                    // rare to model — treat as a value use (keep the arg).
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

/// Whether `name` occurs as a VALUE (any position that is not the callee
/// head of a call) under `e`. Unknown constructs count as a use.
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
        // A receiver-lambda param invoked with an explicit receiver
        // (`expected.getter()`) reaches the param through the MEMBER name;
        // that route needs the materialized value.
        .Member => |m| std.mem.eql(u8, m.name.name, name) or
            pocUses(exempt_call_head, m.receiver, name),
        .Call => |c| blk: {
            // `contract { … }` lowers to Unit (a compile-time marker): a
            // param mentioned inside its literal (`callsInPlace(action)`)
            // is dead code, never a value use.
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
        // A nested lambda in the callee body may itself splice, materialize,
        // or defer — the param's reachability through that layer is not
        // decidable here, so any nested literal keeps the materialization
        // (observe's `observeDerivedStateRecalculations(...) { ...block... }`
        // lost the binding through exactly this interplay).
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

// A non-local return inside a nested scope (lambda / anon fun / object
// expression) is its own and must not count here; those arms return
// false, kept distinct from the catch-all default.
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

/// Splice an `inline fun` argument lambda where the inlined body
/// invokes the corresponding lambda parameter.
/// Receiver-formed lambda splicing is unconditional: the runtime subject
/// tower and its resolution rules are the semantics, not a mode. The
/// name survives as a seam marker for the (now always-true) call sites.
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

/// As `spliceInlineLambda`, with the lambda's receiver supplied by the call
/// rather than inferred from the parameter's mark. A `this.f(x)` call names
/// the receiver explicitly, and the mark is name-keyed — an enclosing splice
/// of a same-named parameter suspends it, leaving the body without a `this`.
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
    const params = lam.Lambda.params;
    const body = lam.Lambda.body;
    // A receiver-formed literal invoked with ONE MORE positional argument
    // than it declares gets its receiver from that argument (`T.() -> R`
    // passed through a `(T) -> R` param and invoked `block(current(this))`
    // — Kotlin's function types interconvert and the receiver rides
    // positionally). The mark-route fallback (`resolve("this")`) is the
    // lexically-enclosing subject, which is the WRONG object exactly when
    // the caller computed a fresh receiver to pass — the snapshot map read
    // the stale first record forever once record reuse split the two.
    const lam_receiver_formed = b.isReceiverLambdaParam(lambda_name) or
        b.lambdaArgRecv(lam.Lambda.span) != null;
    // The literal's value-parameter count under its DECLARED function type:
    // a headerless block's speculative implicit `it` is vacuous under a
    // zero-param `T.()` shape (kotlinc gives such a lambda no `it`), but it
    // IS the value parameter under `T.(A)` (`{ this.onError(it) }` for
    // `String.(Int) -> Nothing`). The declared arity is recorded span-keyed
    // when the literal materializes through a receiver-formed param; without
    // a record the literal's own header stands.
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
    if (inline_state.runtime.envOnce("KLIO_SPLICE_TRACE")) |w| {
        if (std.mem.eql(u8, w, lambda_name)) std.debug.print("[splice-lam] {s} owner={s} rlp={} explicit={} recv={} seat={} nargs={d} nparams={d} it={} lar={} span={}:{}\n", .{ lambda_name, b.ownerClass() orelse "?", b.isReceiverLambdaParam(lambda_name), explicit_receiver != null, receiver != null, arg_supplies_recv, arg_exprs.len, params.len, lam.Lambda.implicit_it, b.lambdaArgRecv(lam.Lambda.span) != null, lam.Lambda.span.file, lam.Lambda.span.start });
    }

    const arg_regs = try b.allocator.alloc(Reg, arg_exprs.len);
    defer b.allocator.free(arg_regs);
    for (arg_exprs, 0..) |*a, i| {
        arg_regs[i] = try lowerExpr(b, a);
    }
    // A RECEIVER-formed literal invoked through a param-form function type
    // (`T.() -> R` passed where `(T) -> R` is declared — Kotlin's function
    // types interconvert) supplies its receiver as the FIRST argument:
    // `block(current(this))` binds `current(this)` as the literal's `this`.
    // Without the seat the argument fell into `it` and the body's bare
    // `this` leaked to the enclosing splice's subject — the snapshot map
    // read the stale first record forever once record reuse split the two.
    const recv_seat = arg_supplies_recv;
    const arg_shift: usize = if (recv_seat) 1 else 0;
    const eff_arg_regs = arg_regs[arg_shift..];
    const eff_arg_exprs = arg_exprs[arg_shift..];
    // The lambda being spliced was defined in the inline call's caller
    // scope, so its free names must resolve there — not against the
    // inline fn's parameter scope, whose names would shadow a same-named
    // caller variable the lambda body references. The caller depth was
    // recorded on the current inline-lambda frame at the call site.
    // Located on the frame that SUBSTITUTES this lambda, not the innermost
    // one: a lambda spliced from inside another spliced lambda body belongs
    // to the scope it was written in, several inline levels out. Reading the
    // innermost frame made the window admit the callee's parameter scopes,
    // so a same-named caller binding (`onError` at two inline levels)
    // resolved to the wrong closure.
    const defining_frame = b.definingInlineLambdaFrame(lambda_name, lam);
    const splice_caller_depth = if (defining_frame) |di|
        b.inlineLambdaFrameCallerDepth(di)
    else
        b.inlineLambdaCallerDepth();
    const site_hint = if (defining_frame) |di|
        b.inlineLambdaFrameHint(di)
    else
        b.inlineLambdaCallerHint();
    // Collect the enclosing inline fn's param names BEFORE this splice
    // pushes its own (empty-subst) frame — these are the marks to suspend
    // while the caller's body lowers.
    var enclosing_subst_keys: std.ArrayList([]const u8) = .empty;
    defer enclosing_subst_keys.deinit(b.allocator);
    if (b.innermostInlineLambdaSubst()) |subst0| {
        var kit0 = subst0.keyIterator();
        while (kit0.next()) |k0| try enclosing_subst_keys.append(b.allocator, k0.*);
    }
    const counted = inline_state.inlineExpandEnter();
    const subject_prior_this = b.resolve("this");
    try b.pushScope();
    const lambda_own_base = b.scopeDepth() - 1;
    if (receiver) |reg| try b.bind("this", reg) else if (recv_seat) try b.bind("this", arg_regs[0]);
    // Inside a receiver lambda passed to inline `f`, `this@f` names the
    // lambda's OWN receiver — the spliced subject — and shadows the fn
    // splice's same-labeled binding (f's extension receiver). A closure
    // created in the body captures its `this` under exactly this label, so
    // without the shadow a nested `forEachIndexed { block(i, e) }` inside
    // `encodeCollection`'s `composite.block()` captured the enclosing
    // Encoder and ran the caller's element block against it.
    if (receiver orelse (if (recv_seat) arg_regs[0] else null)) |subject| {
        if (b.currentInlineFn()) |fname| {
            const label = try std.fmt.allocPrint(b.allocator, "this@{s}", .{fname});
            try b.bind(label, subject);
        }
    }
    if (inline_state.runtime.envOnce("KLIO_THIS_TRACE") != null) {
        std.debug.print("[lam-splice-bind] {s} recv={?d} own_base={d} depth={d}\n", .{ lambda_name, if (receiver) |r| r.int() else null, lambda_own_base, b.scopeDepth() });
    }
    // The splice's parameter bindings inherit the ARGUMENT expressions'
    // static types: `predicate(element)` inside a spliced `all` body binds
    // the caller lambda's `it` to `element`, and the loop variable's derived
    // type (Char over a CharSequence receiver) is exactly the type kotlinc
    // gives the lambda parameter. The splice runs in the CALLER's builder,
    // whose flat decl-type map may already record a SAME-NAMED outer local
    // (`let { it.sortedBy { ... } }` records the outer `it`): the binding
    // shadows that record for the body and restores it on exit — the derived
    // types are argument-position facts, not enclosing-scope facts.
    const ShadowSave = struct { name: []const u8, ty: ?ir.TypeRef, init: ?*const ast.Expr };
    var shadow_saves: std.ArrayList(ShadowSave) = .empty;
    defer {
        for (shadow_saves.items) |*sv| {
            b.clearLocalDeclType(sv.name);
            if (sv.ty) |t| b.setLocalDeclTypeOwned(sv.name, t) catch {};
            if (sv.init) |e| b.setLocalInitExpr(sv.name, e) catch {};
        }
        shadow_saves.deinit(b.allocator);
    }
    const bind_n: usize = if (params.len == 0)
        @min(@as(usize, 1), eff_arg_regs.len)
    else
        @min(params.len, eff_arg_regs.len);
    // Every argument's type is read BEFORE any parameter binds. The
    // argument expressions belong to the callee's body scope, and a lambda
    // parameter that shares a name with something that scope declares
    // (`forEachIndexed`'s own `index` counter and the user's `index`
    // parameter) would otherwise have its own source erased by the binding
    // that consumes it.
    const arg_tys = try b.allocator.alloc(?ir.TypeRef, bind_n);
    defer {
        for (arg_tys) |*t| if (t.*) |*ty| ty.deinit(b.allocator);
        b.allocator.free(arg_tys);
    }
    for (arg_tys, 0..) |*slot, ai| {
        // An INDEXED argument carries the same element fact the loop
        // variable does, and half the generated array family invokes its
        // lambda that way: `ShortArray.indexOfFirst` splices its predicate
        // at `predicate(this[index])` while `ShortArray.any` splices at
        // `predicate(element)`. Only the second one bound a type, so every
        // member call on `it` inside the user's lambda resolved by name for
        // the indexed half of the family.
        if (expr_lower.argDeclTypeRefLazy(b, &eff_arg_exprs[ai])) |ty| {
            slot.* = try ty.clone(b.allocator);
            continue;
        }
        const ae = &eff_arg_exprs[ai];
        if (ae.* == .Index and ae.Index.args.len == 1) {
            slot.* = try expr_lower.iterableElementTypeRef(b, ae.Index.receiver);
        } else {
            // A CALL argument (`selector(iterator.next())`) carries the same
            // element fact the loop-variable and indexed forms do — the
            // static deriver answers it, exactly as the value-param path
            // above does for tp-declared params.
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
        // The literal's OWN annotation is the parameter's type
        // (`{ index, acc: Number, e -> ... }`): it outranks whatever the
        // callee's argument expression derives, exactly as kotlinc types an
        // annotated lambda parameter.
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
            // A head that is still a bare TYPE PARAMETER names nothing in
            // the receiving scope; committing it only feeds the
            // no_class_id bucket and disproves candidates a null leaves
            // open.
            var h = std.mem.trimEnd(u8, ty.name, "?");
            if (std.mem.indexOfScalar(u8, h, '<')) |lt| h = h[0..lt];
            // A class-param IDENTITY mangle names nothing lowering can
            // resolve either — committing `$class$ N i:E` heads only fed
            // the no_class_id bucket.
            const bare_tp = (h.len > 0 and h.len <= 2 and
                std.ascii.isUpper(h[0])) or b.isTypeParam(h) or
                ir.parseClassTypeParamIdentity(h) != null;
            if (!bare_tp) {
                try b.setLocalDeclTypeOwned(pname, try ty.clone(b.allocator));
            }
        }
    }
    // Capture the owner splice's localize target *before* pushing the new
    // frame, then duplicate it so restoring does not alias the frame's
    // own snapshot (which the frame frees on pop).
    // The localize target for an unlabeled `return` in this lambda belongs to
    // the frame the lambda was DEFINED under, for the same reason its free
    // names do: a `{ _, _, _ -> return null }` spliced several inline levels
    // in returns from the function that wrote it.
    const owner_ret: ?[]InlineReturn = if (defining_frame) |di|
        try b.allocator.dupe(InlineReturn, b.inlineLambdaFrameOwnerReturn(di))
    else if (b.inlineLambdaOwnerReturn()) |o|
        try b.allocator.dupe(InlineReturn, o)
    else
        null;
    // The lambda body is CALLER code, so the inline lambda parameters it can
    // invoke are the CALLER's, inherited from the frame the lambda was
    // defined under. The inline function's own frame — the one being spliced
    // into — is skipped, and a name this lambda binds itself shadows the
    // inherited entry. An empty frame here left a body's call to its own
    // enclosing inline parameter with no splice, dispatching it by name.
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
                // Only a name the skipped frames RE-BIND needs carrying: that
                // is the collision the empty frame lost. Every other caller
                // name already resolves through the register window, and
                // exposing it here would hand an unrelated call to a splice.
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
    // Resolve the lambda body's free names against the caller scopes
    // plus the lambda's own scopes, skipping the inline fn's parameter
    // scopes in between.
    const prev_splice = b.lambda_splice_resolve;
    var pushed_band = false;
    if (splice_caller_depth) |d| {
        b.lambda_splice_resolve = .{ .caller_depth = d, .own_base = lambda_own_base };
        // Record this window's hidden region (the inline fn's scopes
        // between the caller depth and the lambda's own scope) so a
        // NESTED window whose caller region reaches above it keeps the
        // region hidden — its `this`/locals belong to the inline fn, not
        // the nested lambda's defining scope.
        if (lambda_own_base > d) {
            try b.splice_hidden_bands.append(b.allocator, .{ .lo = d, .hi = lambda_own_base - 1 });
            pushed_band = true;
        }
    }
    // The lambda body is CALLER code: its bare calls resolve under the
    // hint that was active at the inline call site, not the spliced
    // body's own receiver hint.
    // The spliced body's receiver-lambda-param MARKS are scoped to the
    // inline fn's own names; inside the CALLER's lambda body the same
    // simple name refers to a caller binding (`apply`'s `block: T.() -> Unit`
    // param vs the test's captured composable `block`), and a leaked mark
    // emits CallValueWithThis with the scope subject as receiver — the
    // subject then rides the composable pair. Suspend exactly the enclosing
    // inline fn's own param marks (the frame's substitution keys) for the
    // caller body; every other mark stays (a `buildMap { put(...) }` body
    // still resolves through its own receiver machinery).
    var suspended_rlp: std.ArrayList([]const u8) = .empty;
    defer suspended_rlp.deinit(b.allocator);
    for (enclosing_subst_keys.items) |k| {
        // Only a mark THIS splice added for the inline fn's own parameter is
        // suspended. When the caller declares a same-named receiver-lambda
        // parameter (`fun mk(block: C.() -> Unit) = C().apply { block() }`),
        // the mark is the caller's and suspending it drops the receiver from
        // the bare call.
        //
        // The splice-mark bit is NAME-keyed with no provenance: when an
        // OUTER inline frame binds the same name (`kotlin.with`'s own
        // `block` param spliced inside `SlotTable.edit`, whose
        // receiver-formed param is ALSO `block`), suspending drops the
        // OUTER callee's mark too and the caller-body `block()` splices
        // with NO receiver — the editor lambda ran on the table. Keep the
        // mark whenever any outer frame's substitution also carries it.
        if (b.isReceiverLambdaParam(k) and b.isSpliceRlpMark(k) and
            !b.isSharedRlpMark(k))
        {
            b.unmarkReceiverLambdaParam(k);
            try suspended_rlp.append(b.allocator, k);
        }
    }
    // The inline fn's own parameter BINDINGS are hidden for the caller
    // body too, not just their marks: `apply`'s `block: T.() -> Unit`
    // param otherwise shadows a caller class's same-named member inside
    // the spliced lambda (and a nested closure then captures the
    // out-of-scope binding — collapsed to Unit once the splice frame is
    // gone).
    var hidden_binds: std.ArrayList(struct { name: []const u8, h: build.HiddenBinding }) = .empty;
    defer hidden_binds.deinit(b.allocator);
    for (enclosing_subst_keys.items) |k| {
        if (b.hideBinding(k)) |h| {
            try hidden_binds.append(b.allocator, .{ .name = k, .h = h });
        }
    }
    const lam_prev_active = b.spliceHintActive();
    const lam_prev_recv = b.spliceHintRecv();
    // The spliced receiver lambda has no runtime closure — its subject is
    // only the window's bound register — so the body's bare member reads
    // need the subject's STATIC head to win the member-vs-global
    // arbitration (`objectArgs` inside `with(stack) { ... }` is the
    // stack's member, never a global). The declared head decides when
    // concrete; a generic head (`with`'s `T.()`) substitutes the
    // receiver EXPRESSION's static type, exactly as the inline-fn splice
    // substitutes a generic `T.apply` receiver.
    var recv_head: ?[]const u8 = null;
    // A SEATED subject (a receiver-formed literal invoked with value-arity+1
    // positional args — `block(current(this))`) is a subject exactly like a
    // supplied receiver: the body's bare member reads/calls resolve against
    // it, so it gets the same window head and runtime tower push.
    const subject_reg: ?Reg = receiver orelse if (recv_seat) arg_regs[0] else null;
    if (subject_reg != null) {
        recv_head = b.receiverLambdaRecvHead(lambda_name);
        // The seat case's declared receiver head was recorded span-keyed
        // when the literal lowered through its receiver-formed param.
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
        // A BARE invocation of a generic receiver-formed param
        // (`apply`'s `block()` — no receiver expression to type) binds
        // the CALLEE's own substituted subject: inherit the enclosing
        // splice window's head rather than clobbering it with null
        // (`scope.apply { result = ... }` must keep Scope so the write
        // arbitration knows the subject hides no `result`). ONLY the
        // bare form: an EXPLICIT `receiver.block()` (`with`'s body)
        // binds the receiver expression, which need not relate to the
        // enclosing head at all — a member-inline splice's owner head
        // (SlotTable) fed `with(openEditor())`'s editor subject and
        // every bare editor read pinned to the table.
        if (recv_head == null and rfsEnabled() and explicit_receiver == null and
            receiver != null)
        {
            recv_head = b.spliceRecvTy();
        }
    }
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
    if (subject_reg != null) {
        // Receiver lambda (`apply { minusAssign(key) }`): the innermost
        // implicit receiver inside the body is the lambda's SUBJECT, so
        // bare calls hint its head — never the enclosing fn's receiver,
        // which would refute candidates the subject satisfies.
        b.setSpliceHint(true, recv_head);
        if (rfsEnabled()) {
            b.setSpliceRecvTy(recv_head);
            b.splice_recv_from_window = recv_head != null;
        }
    } else if (site_hint) |sh| b.setSpliceHint(sh.active, sh.recv);
    const lam_prev_narrow = b.setThisNarrow(if (subject_reg != null) null else if (site_hint) |sh| sh.this_narrow else b.thisNarrow());
    // Body-declared `var`s a nested closure WRITES must box (`var expected
    // = 0` in a spliced lambda whose `repeat { expected += 2 }` closure
    // mutates it) — the same scan `tryInlineCallWithTypeArgs` runs for an
    // inline FN body. Without the mark the decl emits a plain slot and the
    // closure's compound assign mis-routes to `plusAssign` on the value.
    var lam_boxed_here: std.ArrayList([]const u8) = .empty;
    defer lam_boxed_here.deinit(b.allocator);
    {
        var body_boxed = try ast_scan.computeBoxedVars(b.allocator, body.stmts);
        defer body_boxed.deinit();
        var bit = body_boxed.keyIterator();
        while (bit.next()) |k| {
            if (!b.isBoxed(k.*)) {
                try b.markBoxed(k.*);
                try lam_boxed_here.append(b.allocator, k.*);
            }
        }
    }
    // The lambda body is CALLER code in the caller's MEMBER scope too: an
    // active extension splice parked the caller's own/enclosing member sets
    // for its body; the lambda content swaps them back in so a bare member
    // call resolves against the caller's class exactly as it would outside
    // the splice.
    const caller_scope = try b.enterCallerMemberScope();
    // The spliced subject joins the RUNTIME enclosing-receiver chain for
    // the body's region: qualified member-extension calls, operators, and
    // companion-chain reads inside the body dispatch against it exactly
    // as the framed route's closure receiver would. Label returns funnel
    // through `end`, whose first instruction pops; a non-local owner
    // return skips the pop and frame teardown heals it.
    const encl_pushed = subject_reg != null and rfsEnabled();
    const prev_tower_top = b.encl_tower_top;
    if (encl_pushed) {
        try b.push(.{ .EnclosingPush = .{ .src = subject_reg.? } });
        b.encl_tower_depth += 1;
        b.encl_tower_top = subject_reg.?;
    }
    // The literal's content is CALLER code: enclosing splices' in-progress
    // marks don't make a same-fn call inside it self-recursive
    // (`repeat { … forEach { repeat { … } } }` must splice all the way).
    const prev_decl_base = b.inline_stack_visible_base;
    if (!std.mem.eql(u8, inline_state.runtime.envOnce("KLIO_NRG") orelse "1", "0")) {
        b.inline_stack_visible_base = b.inline_stack.items.len;
    }
    const v = try lowerBlock(b, &body);
    b.inline_stack_visible_base = prev_decl_base;
    if (encl_pushed) {
        b.encl_tower_depth -= 1;
        b.encl_tower_top = prev_tower_top;
    }
    if (caller_scope) |cs| b.exitCallerMemberScope(cs);
    for (lam_boxed_here.items) |n| b.unmarkBoxed(n);
    for (hidden_binds.items) |hb| b.restoreHiddenBinding(hb.name, hb.h);
    for (suspended_rlp.items) |k| try b.markReceiverLambdaParam(k);
    _ = b.setThisNarrow(lam_prev_narrow);
    b.setSpliceHint(lam_prev_active, lam_prev_recv);
    if (subject_reg != null and rfsEnabled()) {
        b.setSpliceRecvTy(lam_prev_splice_recv);
        b.splice_recv_from_window = lam_prev_recv_from_window;
    }
    if (pushed_band) _ = b.splice_hidden_bands.pop();
    b.lambda_splice_resolve = prev_splice;
    try b.push(.{ .Move = .{ .dst = result, .src = v } });
    b.terminate(.{ .Goto = end });
    b.switchTo(end);
    if (encl_pushed) try b.push(.{ .EnclosingPop = .{} });
    if (label != null) {
        b.popInlineLambdaRet();
    }
    try b.restoreInlineReturn(saved);
    b.popInlineLambdaFrame();
    try b.popScope();
    if (counted) {
        inline_state.inlineExpandLeave();
    }
    return result;
}

/// Build the effective per-type-parameter argument list for an inline
/// call: each explicit `<…>` argument is kept; any reified parameter
/// left unspecified is inferred by unifying the function's declared
/// return type with the call's expected (tail-position) type. Non-reified
/// parameters and parameters that cannot be inferred stay `null`.
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

/// `inferReifiedTypeArgs` with the RECEIVER expression: a reified
/// parameter that only appears in receiver position (`SD.equalsImpl(...)`
/// declared `<reified SD : SerialDescriptor> SD.equalsImpl`) binds from
/// the receiver's static type, or — for an implicit receiver — from the
/// enclosing declaration's receiver type. Left unbound it spliced `is SD`
/// against nothing and every descriptor `equals` answered false.
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

    // Unify each declared value-parameter type against its actual argument.
    // A reified `T` that appears only in a parameter position — including
    // inside a function-typed parameter `block: (T) -> R`, solved from the
    // lambda literal's parameter annotations (`{ s: String -> … }`) — is
    // inferred here, before the return-type fallback below.
    for (f.params, 0..) |*p, i| {
        if (i >= ordered.len) break;
        const arg = ordered[i] orelse continue;
        if (std.c.getenv("KLIO_UNIFY_TRACE") != null)
            std.debug.print("[unify-fn] {s} p{d}={s}:{s}<{d}> arg={s}\n", .{ f.name.name, i, p.name.name, p.ty.name.name, p.ty.type_args.len, @tagName(std.meta.activeTag(arg.*)) });
        try unifyParamAgainstArg(allocator, &p.ty, arg, &tp_names, &subst, bb);
    }

    // Receiver position: unify the declared receiver type against the
    // receiver expression, or the enclosing declaration's receiver type
    // for an implicit `this`.
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
    // Fallback: unify the declared return type against the call's expected
    // (tail-position) type, so `val u: User = resp.body()` binds `T = User`
    // with no explicit `<User>`.
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
    // An enclosing splice that already bound a reified parameter of the SAME
    // NAME resolves it lexically: the body text `filterIsInstanceTo(
    // ArrayList<R>())` inside a spliced `filterIsInstance<reified R>` means
    // that R, and solving it through the callee's `C : MutableCollection<in
    // R>` bound is inference this does not do. Without it the nested call
    // declined its splice and reached the runtime with no type argument at
    // all, so `is R` read a process-global (`filterIsInstance<Int?>` kept
    // only the non-null elements).
    if (bb) |b| {
        for (f.type_params, 0..) |tp, i| {
            if (!tp.is_reified) continue;
            // An EXPLICIT `<T>` that names an enclosing splice's reified
            // binding is that binding too: `serializer<T>()` written inside
            // `encodeToString<reified T>` means the caller's T, and left as
            // the bare name it reached the runtime as an unbound `T` —
            // `typeOf<T>()` then asked for a class named `T`.
            const lookup_name: []const u8 = if (out[i]) |o| blk: {
                if (o.type_args.len != 0 or o.function != null) continue;
                break :blk o.name.name;
            } else tp.name.name;
            const bound = b.resolveReifiedTypeName(lookup_name) orelse continue;
            const nullable = std.mem.endsWith(u8, bound, "?");
            const head = if (nullable) bound[0 .. bound.len - 1] else bound;
            // A generic binding (`List<Color>`) keeps its full spelling as
            // the name: head-reading consumers (`T::class`, `is T`) strip at
            // `<`, and `typeOf<T>()` parses the arguments back out.
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

/// Whether a member call to inline extension `name` with these value
/// arguments can bind EVERY reified type parameter by inference alone (no
/// explicit `<…>`, no expected type) — the gate for splicing a reified
/// inline extension in statement position, where `drawNode.dispatchForKind(
/// Nodes.Draw) { … }` must splice so `is T` checks the argument's real
/// generic type instead of dispatching at runtime with `T` unbound.
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
    // Scan the full candidate set: the stub-index pick is blind to
    // MEMBER-inline overloads (`NodeCoordinator.visitNodes(type, block)`
    // next to its `(mask, block)` sibling), and the receiver-blind shape
    // pick cannot separate them — a candidate qualifies when it takes a
    // receiver (extension or member), declares a reified parameter, and
    // the value arguments bind every one of them.
    var single_buf: [1]*const ast.Function = undefined;
    // The enclosing extension's declared receiver is receiver evidence for
    // the extensions-only decline in `inlineFnAstForRecvExt` (a bare
    // `filterIsInstance<T>()` inside `List<*>.countOf()` must stay
    // spliceable, or the reified argument is lost to the runtime walk).
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

/// Unify one declared value-parameter type against its actual argument
/// expression, recording any reified type-parameter solutions in `subst`.
/// A function-typed parameter `(P…) -> R` unifies each declared parameter
/// type against the lambda literal's corresponding annotation, so a reified
/// `T` carried only by a lambda parameter is solved from `{ s: String -> … }`.
/// A generic-class parameter (`kind: NodeKind<T>`) unifies against the
/// argument's statically evident generic type — a constructor call with
/// explicit call-site type args, or a property access whose declared type /
/// accessor return type / expression body carries them (`Nodes.Draw` ->
/// `NodeKind<DrawModifierNode>`), solving `T` so `is T` in the spliced body
/// checks the real class.
fn unifyParamAgainstArg(
    allocator: Allocator,
    param_ty: *const TypeRef,
    arg: *const Expr,
    tp_names: *const std.StringHashMap(void),
    subst: *std.StringHashMap(TypeRef),
    bb: ?*const FuncBuilder,
) Allocator.Error!void {
    // An argument naming an enclosing splice's parameter carries that
    // parameter's declared type (with the enclosing reified substitution
    // already applied): `it.dispatchForKind(type, block)` inside a
    // spliced `visitNodes(type: NodeKind<T>, block: (T) -> Unit)` body
    // solves the nested call's `T` from `type`'s recorded type.
    if (arg.* == .Path and arg.Path.segments.len == 1) {
        if (bb) |b| {
            // Inside a spliced LAMBDA-ARGUMENT body the free names are the
            // CALLER's (`lambda_splice_resolve` window): the enclosing
            // splice's same-named parameter is a different binding, and
            // unifying against its declared type mis-binds the nested
            // reified parameter (the mask-overload's `block: (NodeB) ->
            // Unit` captured `T := NodeB` for the outer lambda's
            // `it.disp(type, block)`).
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
                return;
            };
        }
    }
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
        // A CONSTRUCTOR reference against `(...) -> T` solves `T` as the
        // constructed class (`composerAs(::ComposerForUnsignedNumbers)`
        // binds the reified composer type; the bound alone would answer
        // `is T` for every composer).
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
        return;
    }
    // The parameter IS a type parameter (`cause: T`). Its argument's own type
    // solves it whenever that type is statically evident — a constructor call
    // is the shape that matters (`testUpstreamError(TimeoutCancellationException(""))`
    // binds `T = TimeoutCancellationException`). Positive proof only: a call
    // that is not a constructor says nothing about `T` here.
    if (param_ty.type_args.len == 0 and param_ty.function == null and
        tp_names.contains(param_ty.name.name) and !subst.contains(param_ty.name.name))
    {
        if (ctorArgTypeRef(allocator, arg, bb)) |aty| {
            try subst.put(param_ty.name.name, aty.*);
            return;
        }
        if (std.c.getenv("KLIO_UNIFY_TRACE") != null) {
            const st = staticArgTypeRef(allocator, arg, bb);
            std.debug.print("[unify-tp] {s} arg={s} static={s}<{d}>\n", .{ param_ty.name.name, @tagName(std.meta.activeTag(arg.*)), if (st) |t| t.name.name else "-", if (st) |t| t.type_args.len else 0 });
        }
        // Any argument whose static type lowering already knows solves it
        // too: a literal, a typed local, a declared parameter. Without this
        // a reified `T` bound only by `f(42)` stayed unsolved, the splice
        // declined, and the un-spliced body read a PROCESS-GLOBAL `T` — so
        // `T::class` was either unresolved or the previous call's answer.
        if (staticArgTypeRef(allocator, arg, bb)) |aty| {
            try subst.put(param_ty.name.name, aty.*);
            return;
        }
    }
    // A generic-class parameter (`serializer: KSerializer<T>`) against an
    // argument whose static type the call derivation knows
    // (`CustomIntSerializer(true).cast<IntBox>()` -> `KSerializer<IntBox>`)
    // unifies the type arguments positionally.
    if (param_ty.type_args.len != 0 and param_ty.function == null and
        !tp_names.contains(param_ty.name.name) and arg.* == .Call)
    {
        if (staticArgTypeRef(allocator, arg, bb)) |aty| {
            const ph = std.mem.trimEnd(u8, param_ty.name.name, "?");
            const ah = std.mem.trimEnd(u8, aty.name.name, "?");
            const ph_s = if (std.mem.lastIndexOfScalar(u8, ph, '.')) |d| ph[d + 1 ..] else ph;
            const ah_s = if (std.mem.lastIndexOfScalar(u8, ah, '.')) |d| ah[d + 1 ..] else ah;
            if (std.mem.eql(u8, ph_s, ah_s) and aty.type_args.len == param_ty.type_args.len) {
                for (param_ty.type_args, aty.type_args) |*pa, *aa| {
                    if (pa.is_star or aa.is_star) continue;
                    try unifyTypeParam(&pa.ty, &aa.ty, tp_names, subst);
                }
            }
        }
    }
    // A companion serializer-factory argument (`subclass(PolyDerived
    // .serializer())`) against a `KSerializer<T>` parameter solves
    // `T = PolyDerived`: the plugin's generated factory returns the
    // declaration's own serializer, so the receiver names the type.
    // A prior arm may have bound the parameter from the factory's declared
    // return type, which keeps only a SIMPLE head (`Error` for
    // `ApiResponse.Error.serializer()`): that spelling resolves to an
    // unrelated classifier of the same name (`kotlin.Error`). The written
    // receiver path is the authority for a nested class, so it overrides an
    // unqualified binding.
    const kser_tv: ?[]const u8 = if (param_ty.type_args.len == 1 and !param_ty.type_args[0].is_star and
        std.mem.eql(u8, std.mem.trimEnd(u8, param_ty.name.name, "?"), "KSerializer") and
        tp_names.contains(param_ty.type_args[0].ty.name.name)) param_ty.type_args[0].ty.name.name else null;
    const kser_open = if (kser_tv) |tv| blk: {
        const prior = subst.get(tv) orelse break :blk true;
        break :blk prior.qualified_path == null and std.mem.indexOfScalar(u8, prior.name.name, '.') == null;
    } else false;
    if (kser_open) kser: {
        if (arg.* == .Call and arg.Call.callee.* == .Member and
            std.mem.eql(u8, arg.Call.callee.Member.name.name, "serializer"))
        {
            // The receiver names the class: a bare name, or a dotted path
            // (`Proto.Message.IntMessage.serializer()`, parsed as a member
            // chain) whose spelling the splice resolves as written.
            if (classPathSpelling(allocator, arg.Call.callee.Member.receiver)) |cls_path| {
                // The bound name is the LAST segment; a dotted spelling rides
                // as the qualified path, which the splice resolves to the
                // lifted class the table holds.
                const last = if (std.mem.lastIndexOfScalar(u8, cls_path, '.')) |d| cls_path[d + 1 ..] else cls_path;
                if (last.len != 0 and std.ascii.isUpper(last[0])) {
                    const qualified: ?[]const u8 = if (last.len == cls_path.len) null else cls_path;
                    // A prior binding of the same simple name
                    // (`ParametrizedData<Data>` solved from `value: T`) keeps
                    // its type arguments; the receiver spelling contributes
                    // only the qualified path.
                    if (subst.get(kser_tv.?)) |prior| {
                        if (std.mem.eql(u8, prior.name.name, last)) {
                            if (qualified == null) break :kser;
                            var merged = prior;
                            merged.qualified_path = qualified;
                            try subst.put(kser_tv.?, merged);
                            return;
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
                    return;
                }
            }
        }
    }
    // A class-literal argument (`subclass(C::class)`) against a
    // `KClass<T>` parameter solves `T = C` — the literal names its class
    // statically.
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
                return;
            }
        }
    }
    if (param_ty.type_args.len != 0) {
        var mentions_tp = false;
        for (param_ty.type_args) |*ta| {
            if (!ta.is_star and tp_names.contains(ta.ty.name.name)) {
                mentions_tp = true;
                break;
            }
        }
        if (!mentions_tp) return;
        if (try argGenericTypeRef(allocator, arg, 0)) |aty| {
            try unifyTypeParam(param_ty, aty, tp_names, subst);
            return;
        }
        // The argument names a DECLARATION (`serializersModuleOf(BSerializer)`
        // where `object BSerializer : KSerializer<B>`): the parameter's type
        // argument is solved from the declaration's own supertype list.
        if (argDeclSupertypeMatching(arg, param_ty.name.name)) |sup| {
            try unifyTypeParam(param_ty, sup, tp_names, subst);
            return;
        }
        // A local initialized by an OBJECT LITERAL carries its supertype the
        // same way, and that is the only place its type arguments are
        // written: `val s = object : KSerializer<Int> by … {}` handed to
        // `subclass(serializer: KSerializer<T>)` solves `T = Int`. The
        // local's recorded declared type is head-only, so this is the one
        // channel that reaches the argument.
        if (localObjectSupertypeMatching(arg, param_ty.name.name, bb)) |sup| {
            try unifyTypeParam(param_ty, sup, tp_names, subst);
            return;
        }
        // A local whose DECLARED type names a class solves through that
        // class's supertype list: `boxWithItemSerializer` is a
        // `ThirdPartyBoxSerializer`, which is a
        // `KSerializer<ThirdPartyBox<S>>`, so a `KSerializer<T>` parameter
        // binds `T` to the HEAD `ThirdPartyBox` — the head is all a reified
        // consumer (`T::class`, `is T`) can read, and the inner `S` is the
        // class's own parameter with no binding at this site.
        try declTypeSupertypeBind(param_ty, arg, tp_names, subst, bb);
        // Last: the argument's statically recorded type, which carries its
        // type arguments even when the argument is a plain local
        // (`val s = object : KSerializer<Int> by …` handed to
        // `subclass(serializer: KSerializer<T>)` solves `T = Int`). Head-
        // matched, because that recorded type is the local's denotable one.
        try unifyLoweredTypeParam(param_ty, arg, tp_names, subst, bb);
    }
}

/// The class an argument CONSTRUCTS, as a `TypeRef` — the one argument shape
/// whose type is evident without a type checker. `Foo(...)` names `Foo` when
/// `Foo` resolves to a class; anything else (a factory function, a variable,
/// a member call) stays unproven and returns null.
/// The caller's lexical owner while a splice infers its reified bindings
/// after the callee frame is pushed (`b.ownerClass()` is the callee's then).
var splice_lexical_owner: ?[]const u8 = null;

/// The caller's lexical owner while a splice binds its arguments (the
/// callee frame is pushed by then), for derivations that rename nested
/// classes through the scope the argument was written in.
pub fn spliceLexicalOwner() ?[]const u8 {
    return splice_lexical_owner;
}

/// The dotted class spelling an expression names when every segment is a
/// capitalised identifier: `Outer.Inner` written as a path or parsed as a
/// member chain. Null for anything else.
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
    // The callee is a bare name (`D(...)`), a dotted path (`Outer.D(...)`),
    // or a member chain over class names (`Outer.D` parsed as a member
    // access); every spelling collapses to its segments.
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
    // A dotted constructor path (`Outer.D(...)`) names the nested class
    // through its outer; the bound name keeps the dotted spelling so the
    // splice resolves it the way a written `<Outer.D>` would.
    var written_name: []const u8 = head.name;
    var cid: ?ir.ClassId = null;
    if (segs.items.len >= 2) {
        var buf: std.ArrayList(u8) = .empty;
        for (segs.items, 0..) |seg, si| {
            if (si > 0) buf.append(allocator, '.') catch return null;
            buf.appendSlice(allocator, seg.name) catch return null;
        }
        const dotted = buf.toOwnedSlice(allocator) catch return null;
        // The nesting tree is built at VM setup; at lowering the dotted
        // spelling resolves as a `.`-aligned suffix of a registered fqn.
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
    // A nested class referenced by bare name inside its declaring subtree
    // lives in the class table under its lifted (mangled) name.
    if (cid == null) cid = b.module.classIdIndexed(head.name, b.self_package, head.span.file) orelse
        b.module.classId(head.name) orelse blk: {
        const owner = splice_lexical_owner orelse b.ownerClass();
        const renamed = expr_lower.scopeTypeRenameFrom(@constCast(b), owner, head.name, head.span.file.int()) orelse break :blk null;
        break :blk b.module.classId(renamed);
    };
    if (cid == null) return null;
    var targs = allocator.alloc(ast.TypeArg, call.type_args.len) catch return null;
    for (call.type_args, 0..) |ta, i| {
        targs[i] = .{ .variance = .Invariant, .is_star = false, .ty = ta, .span = ta.span };
    }
    // A GENERIC class constructed without explicit type arguments infers
    // them from the constructor arguments, as kotlinc does: `Box(1)` is a
    // `Box<Int>` (each class type parameter binds through the first
    // primary-constructor parameter declared as that bare variable whose
    // argument has a statically known type).
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
    // Still head-only for a generic class: the static constructor
    // derivation knows shapes this position-by-parameter inference does
    // not (`Array(1) { Box("foo") }` types by the initializer's tail).
    if (targs.len == 0 and call.type_args.len == 0) fallback: {
        const cls = if (cid.?.int() < b.module.classes.items.len) &b.module.classes.items[cid.?.int()] else break :fallback;
        if (cls.type_params.len == 0) break :fallback;
        const derived = (expr_lower.ctorInitTypeRef(@constCast(b), arg) catch null) orelse break :fallback;
        if (derived.args.len == 0) break :fallback;
        const as_ast = expr_lower.astTypeRefFromIr(@constCast(b), derived, head.span) orelse break :fallback;
        targs = as_ast.type_args;
    }
    const out = allocator.create(TypeRef) catch return null;
    out.* = .{
        .name = .{ .name = written_name, .span = head.span },
        .nullable = false,
        .span = head.span,
        .type_args = targs,
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
    return out;
}

/// The argument's statically-known type, for solving a parameter that IS a
/// type parameter (`v: T`). Head only: a reified `T` is read as `T::class` or
/// `is T`, and both erase type arguments. A head that is itself a type
/// parameter answers nothing — substituting it leaves the body's `T` as
/// unresolved as before.
pub fn staticArgTypeRef(allocator: Allocator, arg: *const Expr, bb: ?*const FuncBuilder) ?*const TypeRef {
    const b = bb orelse return null;
    // A call argument (`listOf(42)`) types through the static call
    // derivation when the lazy typer has no memo for it here: the reified
    // consumer needs `List<Int>`, not an unbound `T`.
    var explicit_needed = false;
    const ty = expr_lower.argDeclTypeRefLazy(@constCast(b), arg) orelse blk: {
        // A bare `object` reference as an argument types as the object's
        // class (a sibling `assertEquals(Object, decode(...))` solves the
        // reified parameter). Argument typing only: the general lazy typer
        // must not type the name, or receiver lowering reads it as a field
        // of the enclosing `this`.
        if (expr_lower.objectRefTypeRef(@constCast(b), arg)) |t| break :blk t;
        if (arg.* != .Call) return null;
        const derived_opt = static_call_type.staticCallReturnTypeRef(@constCast(b), arg) catch null;
        if (std.c.getenv("KLIO_UNIFY_TRACE") != null) std.debug.print("[satr] call callee={s} derived={?s} nta={d} dargs={d} darg0={s}\n", .{ @tagName(std.meta.activeTag(arg.Call.callee.*)), if (derived_opt) |d| d.name else null, arg.Call.type_args.len, if (derived_opt) |d| d.args.len else 0, if (derived_opt) |d| (if (d.args.len != 0) d.args[0].name else "-") else "-" });
        const derived = derived_opt orelse return null;
        // A derived return whose arguments are still the callee's own
        // type parameters (`List<T>` for an un-inferred `listOf(...)`)
        // says nothing the head does not; the reified consumer must not
        // carry a dangling `T`. An EXPLICIT type-argument list on the call
        // instantiates them instead (`x.cast<IntBox>()` declared
        // `KSerializer<T>` IS `KSerializer<IntBox>`).
        for (derived.args) |a| {
            var ah = std.mem.trimEnd(u8, a.name, "?");
            if (std.mem.indexOfScalar(u8, ah, '<')) |lt| ah = ah[0..lt];
            const dangling = ah.len == 0 or (ah.len <= 2 and isAllUpper(ah)) or b.isTypeParam(ah) or ir.parseClassTypeParamIdentity(ah) != null;
            // A star in the derived return (`KSerializer<*>` from a
            // `KSerializer<*>.cast<X>()` receiver) is likewise only
            // instantiated by the explicit list.
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
    if (std.mem.indexOfAny(u8, head, "<>-(") != null) return null;
    if (head.len <= 2 and isAllUpper(head)) return null;
    // A recorded type spelled nullable (`T1$A?` from a splice binding)
    // is nullable whether or not the flag rode along.
    const spelled_nullable = head.len != ty.name.len;
    const out = allocator.create(TypeRef) catch return null;
    if (explicit_needed) {
        if (explicitCallInstantiation(b, arg, head)) |full| {
            out.* = full;
            return out;
        }
        return null;
    }
    // The recorded type keeps its arguments (`Collection<String>`): a
    // reified consumer (`typeOf<T>()` behind `serializer<T>()`) needs
    // them to materialise the KType's arguments.
    if (ty.args.len != 0) {
        if (expr_lower.astTypeRefFromIr(@constCast(b), ty, arg.span())) |full| {
            out.* = full;
            return out;
        }
    }
    // An explicit type-argument list on the call instantiates the callee's
    // generic return directly: `x.cast<IntBox>()` declared as
    // `KSerializer<T>` IS `KSerializer<IntBox>`.
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

/// The callee's declared generic return instantiated by the call's
/// explicit type arguments, when every same-named candidate that takes
/// this many type arguments and returns `head` agrees on the shape.
fn explicitCallInstantiation(b: *const FuncBuilder, arg: *const Expr, head: []const u8) ?TypeRef {
    const call = arg.Call;
    const cname: []const u8 = switch (call.callee.*) {
        .Member => |m| m.name.name,
        .Path => |p| p.segments[p.segments.len - 1].name,
        else => return null,
    };
    const head_s = if (std.mem.lastIndexOfScalar(u8, head, '.')) |d| head[d + 1 ..] else head;
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
        if (std.mem.indexOfScalar(u8, rh, '<')) |lt| rh = rh[0..lt];
        const rh_s = if (std.mem.lastIndexOfScalar(u8, rh, '.')) |d| rh[d + 1 ..] else rh;
        if (!std.mem.eql(u8, rh_s, head_s)) continue;
        if (f.return_ty.args.len == 0) continue;
        const targs = b.allocator.alloc(ast.TypeArg, f.return_ty.args.len) catch return null;
        var ok = true;
        for (f.return_ty.args, targs) |*ra, *ta| {
            var rah = std.mem.trimEnd(u8, ra.name, "?");
            if (std.mem.indexOfScalar(u8, rah, '<')) |lt| rah = rah[0..lt];
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
            // Same-shaped candidates (the pack's and a test's own
            // `KSerializer<*>.cast()`) agree; a different shape is ambiguous.
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


/// The supertype of the class/object an argument path names whose head equals
/// `want` — the declared instantiation (`KSerializer<B>`) an argument of that
/// declaration's type satisfies. Null when the argument is not a plain
/// declaration reference or declares no matching supertype.
fn argDeclSupertypeMatching(arg: *const Expr, want: []const u8) ?*const TypeRef {
    const name: []const u8 = switch (arg.*) {
        .Path => |*p| blk: {
            if (p.segments.len == 0) break :blk "";
            break :blk p.segments[p.segments.len - 1].name;
        },
        .Member => |*m| m.name.name,
        else => "",
    };
    if (name.len == 0) return null;
    const sups = inline_state.classSupertypeRefs(name) orelse return null;
    for (sups) |*sup| {
        if (sup.type_args.len == 0) continue;
        const sup_head = if (std.mem.lastIndexOfScalar(u8, sup.name.name, '.')) |d| sup.name.name[d + 1 ..] else sup.name.name;
        if (std.mem.eql(u8, sup_head, want)) return sup;
    }
    return null;
}

/// Solve `param_ty`'s type-parameter arguments from the argument's recorded
/// static type. The recorded type is a lowered `ir.TypeRef`, so this matches
/// the head and binds each parameter position to the corresponding argument's
/// own head — enough for a reified parameter, which erases its arguments.
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
    if (std.mem.indexOfScalar(u8, head, '<')) |lt| head = head[0..lt];
    if (!std.mem.eql(u8, head, param_ty.name.name)) return;
    const n = @min(param_ty.type_args.len, ty.args.len);
    for (param_ty.type_args[0..n], ty.args[0..n]) |*pa, *aa| {
        if (pa.is_star) continue;
        if (!tp_names.contains(pa.ty.name.name)) continue;
        if (subst.contains(pa.ty.name.name)) continue;
        const ah = std.mem.trimEnd(u8, aa.name, "?");
        if (ah.len == 0) continue;
        if (std.mem.indexOfAny(u8, ah, "<>-(") != null) continue;
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
/// argument's recorded declared type, heads only (see the call site).
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
    // A bare name that is an enclosing class's MEMBER property reads its
    // registered head; a local reads its recorded declared type.
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
    if (std.mem.indexOfScalar(u8, head, '<')) |lt| head = head[0..lt];
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

/// The supertype matching `want` of the object literal a LOCAL was
/// initialized with. `argDeclSupertypeMatching` reads a named declaration's
/// supertypes; this reads an anonymous one through the local that holds it.
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

/// The argument expression's generic type, when statically evident:
/// a constructor/factory call with explicit `<…>` type args, or a
/// property access resolvable through the member-property AST registry.
/// Returns null when the type cannot be proven — inference stays
/// positive-proof only.
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

/// Resolve property `owner.name`'s generic type through the registered
/// property AST: the declared type, the getter's return annotation, or —
/// for an expression-body accessor / initializer — the expression itself.
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

/// Unify a declared type (which may mention type parameters) against a
/// concrete actual type, recording each type parameter's solution. When
/// the declared type *is* a bare type parameter, it binds to the whole
/// actual type; otherwise matching heads recurse positionally through
/// generic arguments (`Box<T>` vs `Box<Int>` solves `T = Int`).
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
            try subst.put(decl.name.name, actual.*);
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

/// Collect the type names a body resolves at runtime — `as T` / `is T`
/// targets, call-site type arguments, and `when` is-patterns — recursing
/// the same expression shapes `collectPathIdents` walks. Together the two
/// scans decide whether a reified inline extension's body ever reads a
/// reified parameter.
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

/// Whether `f`'s body never references any of its reified type
/// parameters — neither as a bare name (`T::class` reads through the
/// `Path` head) nor in a runtime type position (`as T`, `is T`, a
/// call-site type argument, a `when` is-pattern, a catch type). Such a
/// body can splice with no binding for the reified parameter, which is
/// what a call with no explicit type arguments and no expected type
/// needs (`Json.encodeToString(value)` in a hook lambda).
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

/// Render a reified type argument's full spelling: the (already substituted)
/// head plus its generic arguments, recursively — `List<Int>`, `Map<String,
/// List<Int>>`, `*` for a star projection. A plain head renders as itself.
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
        // The CALLER's lexical owner renames a nested argument head
        // (`ThirdPartyBox<Item>` inside the class declaring `Item`): the
        // callee frame is pushed by the time the bindings render.
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

/// Materialize the array value a vararg parameter denotes inside an inline
/// body. Keeping this as an ordinary factory call reuses the call spread path,
/// so `inlineFn(*values)` flattens the supplied array exactly once.
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

/// Expand a call to a `suspend inline fun` by splicing its body into
/// the caller. `type_args` carries the call-site `<T = SomeType>` for
/// reified type parameters so the splice can bind each reified
/// parameter's name to the resolved class value before lowering the
/// body — `T::class` and `is T` reads inside the spliced body then
/// resolve to the call site's type. `expected` carries the call's
/// tail-position type so a reified parameter with no explicit `<…>`
/// argument can be inferred from context.
/// The source file a call-site expression was written in, from its span:
/// visibility of a file-private inline candidate is judged against this.
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

/// `KLIO_SPLICE_TRACE=<fn>` — why a splice that was entered declined, which
/// is otherwise indistinguishable from "never considered".
fn spliceBail(fname: []const u8, why: []const u8) void {
    if (inline_state.runtime.envOnce("KLIO_SPLICE_TRACE")) |w| {
        if (std.mem.eql(u8, w, fname)) std.debug.print("[splice-why] {s}: {s}\n", .{ fname, why });
    }
}

/// Whether an AST type reference mentions any of `f`'s declared type
/// parameters anywhere in its tree (head, generic arguments, or function
/// shape). Such a declared type is not a concrete fact about the spliced
/// parameter — its meaning depends on the call's inference.
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
    // A bare call arrives with its `target` already resolved (the
    // symbol index's pick, or the narrowing fallback for the shapes the
    // index defers on) so the splice expands exactly the declaration
    // the call binds. A member call (`recv.f(...)`, `this_arg` set)
    // resolves here by receiver/shape narrowing: the inline target must
    // be a receiver extension, never a same-named top-level overload.
    var f: *const ast.Function = undefined;
    if (target) |t| {
        f = t;
    } else {
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
        // A BARE call inside an extension body has the enclosing
        // extension's declared receiver as its implicit receiver — that
        // is real evidence (`filterIsInstance<T>()` inside
        // `List<*>.countOf()` narrows on List), and without it the
        // extensions-only decline below would push a reified splice to
        // the runtime walk, losing the type argument.
        if (recv_ty == null and this_arg == null) recv_ty = b.recvTy();
        const recv_chain: ?[]const []const u8 = if (recv_ty) |r|
            try expr_lower.recvChainOf(b, r)
        else
            null;
        f = inline_state.inlineFnAstForRecvExt(
            fname,
            call_shape,
            recv_chain,
            this_arg != null,
        ) orelse return null;
    }
    // A MEMBER extension narrowed by receiver and shape is visible only
    // inside its declaring class hierarchy: JsonTestBase's
    // `Json.encodeToString(value, mode)` never takes a call from a class
    // that does not extend JsonTestBase.
    if (target == null and f.receiver_type != null) {
        if (inline_state.inlineMemberOwner(f)) |owner| {
            const enc = b.ownerClass() orelse {
                spliceBail(fname, "member-ext-owner-invisible (no enclosing class)");
                return null;
            };
            if (!expr_lower.classIsOrExtendsHosted(b, enc, owner)) {
                if (inline_state.runtime.envOnce("KLIO_SPLICE_TRACE")) |w| {
                    if (std.mem.eql(u8, w, fname)) std.debug.print("[splice-why] {s}: member-ext-owner-invisible enc={s} owner={s}\n", .{ fname, enc, owner });
                }
                return null;
            }
        }
    }
    if (b.inlineDeclInProgress(f)) {
        return null;
    }
    // `Result` is natively represented (a value class the interpreter models
    // directly): its inline members' SOURCE bodies read the internal `value`
    // slot and the `Failure` wrapper, which the native value never carries.
    // Never splice them — the runtime dispatch serves them from the native
    // intrinsics (`Result.map`, `getOrThrow`, ...).
    if (f.receiver_type) |rt| {
        if (std.mem.eql(u8, rt.name.name, "Result")) return null;
    }
    // `kotlin.reflect.typeOf<T>()` is a reified intrinsic: its source body
    // is a placeholder throw, and the runtime serves the call from the
    // reified type argument — never splice it.
    if (std.mem.eql(u8, fname, "typeOf") and f.params.len == 0 and
        f.type_params.len == 1 and f.type_params[0].is_reified)
    {
        if (f.return_type) |rt| {
            if (std.mem.endsWith(u8, rt.name.name, "KType")) return null;
        }
    }
    // `KLIO_SPLICE_TRACE=<fn>` — whether a named inline function reaches the
    // splice path at all, and which parameter types the splice binds. The
    // pair answers "did it inline" and "does its body see declared types",
    // which is otherwise invisible from the outside.
    if (inline_state.runtime.envOnce("KLIO_SPLICE_TRACE")) |w| {
        if (std.mem.eql(u8, w, fname)) {
            const site: ?u32 = if (this_arg) |r| helpers.exprSpan(r).start else null;
            std.debug.print("[splice] {s} entered, params={d} decl={}:{} site={?} nta={d} route={s}\n", .{ fname, f.params.len, f.name.span.file, f.name.span.start, site, type_args.len, splice_route_tag });
        }
    }
    // Materialise the body if it is a deferred image marker before reading it.
    inline_state.ensureInlineBody(f);
    const body = if (f.body) |*body_ref| body_ref else {
        spliceBail(fname, "no-body");
        return null;
    };

    var ordered = try b.allocator.alloc(?*const Expr, f.params.len);
    defer b.allocator.free(ordered);
    for (ordered) |*slot| slot.* = null;
    var vararg_value: ?*const Expr = null;
    // A trailing lambda fills the last parameter even when earlier
    // defaulted parameters are omitted (`assertFailsWith<T> { … }` skips
    // the defaulted `message` and binds the lambda to `block`). Mapping it
    // 1:1 from the front would land it on the first param and leave the
    // last (function-typed, no default) one unfilled, declining the splice.
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
        // Parameters after a vararg can only be supplied by name, apart from
        // a trailing lambda. All remaining positional arguments are vararg
        // elements and are materialized into the array the inline body sees.
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
                const idx = paramIndex(f, name) orelse return null;
                if (idx == vi) return null;
                ordered[idx] = a;
                elem_end = @min(elem_end, ai);
            }
        }
        const elems = args[elem_start..elem_end];
        if (elems.len != 0) ordered[vi] = &elems[0];
        vararg_value = try inlineVarargArrayExpr(b, &f.params[vi], elems);
    } else {
        var next_pos: usize = 0;
        for (args[0..positional_n], 0..) |*a, i| {
            const nm: ?[]const u8 = if (i < arg_names.len) arg_names[i] else null;
            if (nm) |name| {
                const idx = paramIndex(f, name) orelse {
                    spliceBail(fname, "named-param-miss");
                    return null;
                };
                ordered[idx] = a;
            } else {
                while (next_pos < ordered.len and ordered[next_pos] != null) {
                    next_pos += 1;
                }
                if (next_pos >= ordered.len) {
                    spliceBail(fname, "positional-overflow");
                    return null;
                }
                ordered[next_pos] = a;
                next_pos += 1;
            }
        }
    }
    var slot_is_default = try b.allocator.alloc(bool, ordered.len);
    defer b.allocator.free(slot_is_default);
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
                return null;
            }
        }
    }

    // A reified parameter that stays unbound after explicit-argument,
    // expected-type, and callable-reference-argument inference must not
    // be one the body actually reads — splicing would leave `T::class` /
    // `is T` dangling. Decline the splice instead; the member-dispatch
    // fallback binds runtime type arguments. A body that never reads its
    // reified parameters (the `Json.encodeToString(value)` shape) splices
    // fine without a binding.
    // The caller-frame inference: arguments are the CALLER's expressions,
    // so their typing belongs here; the callee-frame pass below may lose
    // a derivation that needs the caller's scope (`listOf(B(1))` where
    // `B` nests in the caller's class), and then this answer stands.
    var caller_probe: ?[]?TypeRef = null;
    defer if (caller_probe) |cp| b.allocator.free(cp);
    {
        const probe = try inferReifiedTypeArgsRecv(b.allocator, f, type_args, expected, ordered, b, this_arg);
        caller_probe = probe;
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
            return null;
        }
    }

    if (!inline_state.inlineExpandEnter()) {
        spliceBail(fname, "expand-depth");
        return null;
    }
    errdefer inline_state.inlineExpandLeave();
    const member_splice = f.receiver_type == null and this_arg != null and
        inline_state.inlineMemberOwner(f) != null;
    const explicit_receiver = if ((f.receiver_type != null or member_splice) and
        this_arg != null) recv_blk: {
        // The receiver is a NESTED expression: the caller's per-arg lambda
        // typing stash (consumed by this splice's own arg loop below) must
        // not leak into the receiver's lambdas — `ByteArray(2) { it }
        // .scan("") { op }` typed the factory's `it` from scan's operation.
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
        break :recv_blk try lowerExpr(b, this_arg.?);
    } else null;
    // The caller's lexical owner, for scope-true renames of the reified
    // type arguments bound below (the callee frame pushed next has none).
    const lexical_owner = b.ownerClass();
    try b.pushInlineDecl(fname, f);
    // The spliced extension's declared receiver is receiver EVIDENCE for
    // the body's own inline gates (`filterIsInstance<T>()` inside
    // `List<*>.countOf()` must stay spliceable) — via the dedicated
    // splice channel, NOT `recv_ty`, so nested-lambda bare calls
    // (`collect { }` inside a flow operator body) keep resolving through
    // the runtime receiver walk instead of pinning to the innermost this.
    const prev_splice_recv = b.spliceRecvTy();
    if (f.receiver_type) |rt| {
        // A generic inline receiver (`T.apply`) names no classifier; the
        // CALL SITE's static receiver type does. Substitute it so the
        // spliced body's bare calls see the real receiver class and its
        // members can shadow same-named top-level functions.
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
            // A BARE call to the generic receiver splice (`apply { ... }`
            // inside `M.onEachIndexed`) has no receiver expression; the
            // window head is the ENCLOSING receiver's, not the callee's
            // own literal `T`.
            recv_head = try b.allocator.dupe(u8, expr_lower.typeHead(std.mem.trimEnd(u8, eh, "?")));
        };
        b.setSpliceRecvTy(recv_head);
    } else if (member_splice) {
        // A member-inline splice's bare names resolve against the OWNER
        // class exactly as an extension's resolve against its receiver
        // (`inner.walkInner(...)` inside a spliced `Walker.walk` reads
        // Walker's `inner` property).
        if (inline_state.inlineMemberOwner(f)) |ow| b.setSpliceRecvTy(ow);
    } else if (this_arg == null) {
        // A BARE inline-member call through the implicit receiver
        // (`propertyFailsWith { ... }` inside an extension declared ON the
        // owner) splices with the owner window too — without it the body's
        // own property reads (`expected.getter()`) lower ownerless.
        if (inline_state.inlineMemberOwner(f)) |ow| {
            b.setSpliceRecvTy(ow);
        } else if (build.FuncBuilder.spliceRefDebug()) {
            std.debug.print("[splice-ref] fn={s} bare-member-owner=NULL\n", .{f.name.name});
        }
    }
    defer b.setSpliceRecvTy(prev_splice_recv);
    // The ACTUAL receiver's full static type enters the window when the
    // call site derives one: iterating `this` inside the spliced body
    // types its elements from the receiver's ARGUMENTS (`data.count { }`
    // on `data: T` with `T : Iterable<String>` binds String elements),
    // which the head-only channel above cannot carry. A bare
    // type-parameter head resolves through the caller's full bound ref.
    var recv_ref_owned: ?ir.TypeRef = null;
    // An inline extension called as a BARE call on the implicit receiver —
    // `map`'s body is `return mapTo(ArrayList(…), transform)` — has no
    // receiver EXPRESSION to read a type from, but the window it is being
    // spliced into already holds the caller's own receiver. Carrying it
    // forward is what keeps `lookup.values.map { it.tag() }` typed: without
    // it the delegation drops `Collection<Named>` and every lambda parameter
    // derived from the element goes untyped one level in.
    if (f.receiver_type != null and this_arg == null) fwd: {
        const cur = b.spliceRecvTyRef() orelse break :fwd;
        if (cur.args.len == 0) break :fwd;
        const declared_head = expr_lower.typeHead(std.mem.trimEnd(u8, f.receiver_type.?.name.name, "?"));
        const cur_head = expr_lower.typeHead(std.mem.trimEnd(u8, cur.name, "?"));
        // Only when the callee's declared receiver is the same classifier or
        // a supertype of the one in hand: a delegation to an unrelated
        // extension must not inherit this receiver's arguments.
        if (!std.mem.eql(u8, declared_head, cur_head) and
            !b.module.classIsOrExtends(cur_head, declared_head)) break :fwd;
        recv_ref_owned = cur.clone(b.allocator) catch break :fwd;
    }
    if (f.receiver_type != null) if (this_arg) |ra| blk: {
        var inferred: ?ir.TypeRef = null;
        defer if (inferred) |*t| t.deinit(b.allocator);
        var got = expr_lower.argDeclTypeRefLazy(b, ra) orelse got_blk: {
            // A lazily-typed local (`val data = listOf(...)`) answers only
            // through its initializer — the same chain the member path
            // consults before resolving.
            inferred = try expr_lower.staticExprTypeRef(b, ra);
            break :got_blk inferred orelse break :blk;
        };
        if (got.args.len == 0) {
            var h = std.mem.trimEnd(u8, got.name, "?");
            if (std.mem.indexOfScalar(u8, h, '<')) |lt| h = h[0..lt];
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
    const prev_recv_ref = b.setSpliceRecvTyRef(recv_ref_owned);
    defer if (b.setSpliceRecvTyRef(prev_recv_ref)) |owned| {
        var t = owned;
        t.deinit(b.allocator);
    };
    // Engine step four: the caller's SOLVED bindings become window bound
    // refs, so every consumer sees the call-site instantiation for each
    // fn type parameter — argument-bound ones (joinTo's A := the buffer)
    // included, not just the receiver-bound.
    const S4Restore = struct { name: []const u8, prev: ?ir.TypeRef };
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
    // Bare-call hygiene for the spliced body: its bare calls resolve
    // against the inline fn's own receiver (none for a receiver-less
    // inline fn), never the caller's class. The pre-splice hint is
    // recorded on the inline-lambda frame below so a spliced caller
    // lambda restores it.
    const prev_hint_active = b.spliceHintActive();
    const prev_hint_recv = b.spliceHintRecv();
    b.setSpliceHint(true, if (f.receiver_type) |rt| rt.name.name else if (member_splice) inline_state.inlineMemberOwner(f) else null);
    defer b.setSpliceHint(prev_hint_active, prev_hint_recv);
    const prev_hint_recv_ref = b.setSpliceHintRecvRef(f.receiver_type);
    defer _ = b.setSpliceHintRecvRef(prev_hint_recv_ref);
    // The spliced body has its own receiver context: the caller's
    // smart-cast narrow of `this` must not leak into it.
    const prev_this_narrow = b.setThisNarrow(null);
    defer _ = b.setThisNarrow(prev_this_narrow);
    // Scope depth before the inline fn binds its parameters: a lambda
    // argument spliced from this call resolves its free names in these
    // caller scopes, not against the inline fn's parameter scope.
    var caller_scope_depth = b.scopeDepth();
    try b.pushScope();
    // Precise captured-`var` carrier across the inline splice. The inline
    // body is lowered into THIS (the caller's) builder, so its own `var`
    // decls — and any inline parameter — that a nested closure inside the
    // body *writes* must be boxed into a shared `Value.Cell` here, exactly
    // as a captured `var` is at an ordinary lambda boundary. Without this
    // the body lowers the write through the `StoreGlobal`-for-capture
    // fallback, which only round-trips on the stdlib-HOF scoped env. Box
    // them so the write lowers to `CellSet` on the shared cell and is
    // visible on every closure-execution path. Names newly boxed here are
    // recorded and unboxed after the splice so the mark never leaks onto a
    // same-named caller local.
    var boxed_here: std.ArrayList([]const u8) = .empty;
    defer boxed_here.deinit(b.allocator);
    var splice_boxed = ast_scan.StringSet.init(b.allocator);
    defer splice_boxed.deinit();
    if (body.* == .Block) {
        // Body-declared `var`s captured-and-written by a nested closure.
        var body_boxed = try ast_scan.computeBoxedVars(b.allocator, body.Block.stmts);
        defer body_boxed.deinit();
        var bit = body_boxed.keyIterator();
        while (bit.next()) |k| try splice_boxed.put(k.*, {});
        // Inline parameters written by a nested closure in the body. A
        // parameter is not a body `var` decl, so `computeBoxedVars` does
        // not see it; collect mutation targets inside nested lambdas and
        // box any that name a parameter.
        var assigned = ast_scan.StringSet.init(b.allocator);
        defer assigned.deinit();
        try ast_scan.namesAssignedInLambdasRebindsOnly(body.Block.stmts, &assigned);
        for (f.params) |*p| {
            if (assigned.contains(p.name.name)) try splice_boxed.put(p.name.name, {});
        }
    }
    var lambda_map = std.StringHashMap(*const ast.Expr).init(b.allocator);
    const arg_regs = try b.allocator.alloc(Reg, f.params.len);
    defer b.allocator.free(arg_regs);
    // The caller's emitter computed instantiated expected param types per
    // ARGUMENT slot (`lowerArgRun`'s transfer, which this loop bypasses):
    // consume them here so each lambda's eagerly-lowered closure body
    // types its params.
    const arg_lambda_param_types = b.pending_arg_lambda_param_types;
    b.pending_arg_lambda_param_types = null;
    const PTySave = struct { name: []const u8, ty: ?ir.TypeRef };
    var param_ty_saves: std.ArrayList(PTySave) = .empty;
    defer param_ty_saves.deinit(b.allocator);
    defer for (param_ty_saves.items) |*sv| {
        b.clearLocalDeclType(sv.name);
        if (sv.ty) |t| b.setLocalDeclTypeOwned(sv.name, t) catch {};
    };
    var any_forwarded_lambda = false;
    var any_literal_lambda = false;
    // Params already bound by earlier iterations of this loop must not
    // capture a LATER caller-supplied argument expression that happens to
    // use the same name: `space.groupNext(0, address)` with a caller local
    // `address` read 0 (the just-bound param) instead of the local. Kotlin
    // evaluates supplied arguments in the CALLER's scope; only a
    // default-filled slot is callee code that sees the earlier params.
    var bound_param_names: std.ArrayList([]const u8) = .empty;
    defer bound_param_names.deinit(b.allocator);
    for (f.params, 0..) |*p, i| {
        const a = if (p.is_vararg) vararg_value.? else ordered[i].?;
        const forwarded_lambda = forwardedInlineLambda(b, a);
        // A numeric literal argument re-types to its declared primitive
        // parameter (kotlinc literal typing): `f(1)` for `f(x: Long)`
        // binds a `Long`, not an `Int`. The regular call path coerces in
        // `lowerArgRunFull`; the inline splice binds the lowered arg
        // directly, so apply the same coercion here. Without it the bound
        // value stays `Int` and any later `==`/`equals` against a `Long`
        // is a cross-type comparison that is always false.
        const coerced: ?Reg = if (p.ty.function == null and !p.ty.nullable)
            try helpers.coerceNumericLiteralArg(b, a, p.ty.name.name)
        else
            null;
        // A callable-REFERENCE argument (`map(String::indentWidth)`) needs
        // the declared arity too: the MemberRef lowering binds the target
        // fid only when it knows the expected function shape, and a
        // name-carrying reference invoked later cannot reach a private or
        // file-scoped extension the LOWERING site resolves legally.
        if (a.* == .MemberRef and p.ty.function != null) {
            b.pending_lambda_arity = @intCast(p.ty.function.?.params.len);
        }
        // A lambda argument bound to a declared function-typed param
        // takes its arity from the declaration — a zero-`->` lambda for
        // a `() -> R` param must NOT keep the parser's implicit `it`
        // (which would swallow the first invocation slot as Null).
        if ((a.* == .Lambda or a.* == .AnonFun) and p.ty.function != null) {
            b.pending_lambda_arity = @intCast(p.ty.function.?.params.len);
            if (arg_lambda_param_types) |slots| {
                // `ordered[i]` points into the caller's arg slice; recover
                // the ARGUMENT index the per-slot types are keyed by. The
                // synthetic vararg expression lies outside the slice.
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
        // A default-filled slot is CALLEE code: Kotlin evaluates a default
        // expression in the declaration's scope, where the extension
        // receiver (and the already-bound earlier params) are visible —
        // `endIndex: Int = length` on `CharSequence.substring` reads the
        // receiver's `length`. Caller-supplied arguments keep the call
        // site's scope (no callee `this`).
        // The splice bypasses `lowerArgRun`'s transfer, so the sibling-solved
        // expected type for exactly this argument node applies here too.
        const sib_push = if (b.sib_expected_site) |site|
            site == @as(*const anyopaque, @ptrCast(a))
        else
            false;
        const sib_prev = if (sib_push) b.pushExpected(b.sib_expected_ty) else null;
        // A literal lambda that MATERIALIZES (the body forwards the param
        // as a value rather than only calling it) must lower under the
        // param's declared FUNCTION TYPE, exactly as `lowerArgRun` would
        // have: the expected type is where `lowerLambda` reads the
        // receiver head. Without it a `StateMapStateRecord.() -> R`
        // literal lowers as a PLAIN block — `lambda_has_receiver` false,
        // `this` captured from the enclosing splice's subject binding —
        // and every later invocation runs the body against the stale
        // creation-time subject instead of the supplied receiver (the
        // snapshot map's CAS loop livelocked on exactly that once record
        // reuse split the two).
        const lam_ty_push = (a.* == .Lambda or a.* == .AnonFun) and p.ty.function != null;
        const lam_ty_prev = if (lam_ty_push) b.pushExpected(p.ty) else null;
        // Span-keyed receiver record for the literal: a later CALL-POSITION
        // splice of this same literal (the body forwards the param into
        // another inline whose body invokes it — `withCurrent(block)` into
        // `block(current(this))`) must know the literal is receiver-formed
        // so the supplied argument seats as `this`, not as `it`.
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
        // by the splice's call-position expansion; materializing it here
        // builds a dead closure (plus captures) per call. Skip the value
        // entirely — the substitution map serves the call positions, and
        // the use scan proved no value position exists.
        // The literal's own body referencing the PARAM'S NAME (a caller
        // binding `block` passed into a callee whose param is also
        // `block`) needs the binding as the shadow the window hides —
        // observe's literal into observeDerivedStateRecalculations lost
        // its outer `block` exactly this way.
        const splice_consumed_lambda = a.* == .Lambda and !slot_is_default[i] and
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
        if (splice_consumed_lambda) {
            if (inline_state.runtime.envOnce("KLIO_ARG_SKIP_TRACE") != null) {
                std.debug.print("[arg-skip] fn={s} param={s}\n", .{ fname, p.name.name });
            }
            if (lam_ty_push) b.restoreExpected(lam_ty_prev);
            if (sib_push) b.restoreExpected(sib_prev);
            b.pending_lambda_arity = -1;
            b.pending_ref_lambda_param_types = null;
            arg_regs[i] = try b.emitConst(Const.Unit);
            try bound_param_names.append(b.allocator, p.name.name);
            try lambda_map.put(p.name.name, a);
            any_literal_lambda = true;
            continue;
        }
        const r = if (slot_is_default[i] and explicit_receiver != null) blk: {
            try b.pushScope();
            try b.bind("this", explicit_receiver.?);
            const rr = coerced orelse try lowerExpr(b, a);
            try b.popScope();
            break :blk rr;
        } else if (slot_is_default[i]) coerced orelse try lowerExpr(b, a) else blk: {
            var hidden_params: std.ArrayList(struct { name: []const u8, h: build.HiddenBinding }) = .empty;
            defer hidden_params.deinit(b.allocator);
            for (bound_param_names.items) |nm| {
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
        if (lam_ty_push) b.restoreExpected(lam_ty_prev);
        if (sib_push) b.restoreExpected(sib_prev);
        b.pending_lambda_arity = -1;
        b.pending_ref_lambda_param_types = null;
        arg_regs[i] = r;
        // A fn-typed literal that MATERIALIZED because the body forwards
        // it (not only-calls it) is a dead-construction candidate: when
        // every forward lands in a nested call-position splice, nothing
        // ever reads the closure register and `finish` nops the build.
        if (a.* == .Lambda and p.ty.function != null and !slot_is_default[i]) {
            b.noteForwardedLambda(r, a.Lambda.span);
        }
        // A lambda argument is spliced inline (its body is expanded at the
        // call site), so it is never a closure value to box — skip boxing
        // it even if a deeper nested lambda mentions the param name.
        const box_param = splice_boxed.contains(p.name.name) and a.* != .Lambda;
        if (box_param and !b.isBoxed(p.name.name)) {
            // Box the parameter into a shared cell. The scope-local `bind`
            // is enough for `boxedCellReg` to recover the cell (it falls to
            // `resolve` when no `mutable_home` is set), so the boxing mark
            // and binding live only inside the spliced scope and are torn
            // down with it — no flat `mutable_homes`/`mutables` entry leaks
            // onto a same-named caller local.
            const home = b.allocReg();
            try b.push(.{ .MakeCell = .{ .dst = home, .src = r } });
            try b.markBoxed(p.name.name);
            try b.bind(p.name.name, home);
            try boxed_here.append(b.allocator, p.name.name);
        } else {
            try b.bind(p.name.name, r);
        }
        try bound_param_names.append(b.allocator, p.name.name);
        // A parameter DECLARED by one of the callee's own type parameters
        // (`destination: M`) types nothing inside the body; the ARGUMENT's
        // static type is the instantiation (`LinkedHashMap<K,
        // MutableList<T>>` answers `getOrPut`'s V where `M` cannot).
        // Record it under the local-decl channel — the spliceParamTy read
        // falls through to it for tp heads — shadow-saving any same-named
        // caller record. A bare tp HEAD in the derived answer is refused
        // as everywhere; loose tp ARGS ride, the head still binds.
        if (p.ty.function == null and !p.is_vararg) tp_arg: {
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
                // A CONCRETE declared head (`value: Int`) is the
                // parameter's static type inside the spliced body just
                // as it is in the framed activation. Recording it lets
                // the explicit-receiver derivations (the scalar
                // extension splice's receiver head, member proofs) see
                // through the binding — the SlotTable `countOneBits`
                // wrapper's inner `value.countOneBits()` otherwise
                // stayed framed pack-wide for want of a head. Same
                // shadow-save discipline as the tp arm.
                if (dh.len == 0) break :tp_arg;
                // A concrete HEAD can still carry the fn's type params in
                // its ARGUMENTS (`serializer: KSerializer<T>`): recording
                // the declared spelling verbatim feeds a raw `T` to the
                // reified derivations, which then lower `T::class` as a
                // global read. Those params keep the argument-derived
                // channel (record nothing here).
                if (astTypeMentionsFnTypeParam(&p.ty, f)) break :tp_arg;
                try param_ty_saves.append(b.allocator, .{
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
            // Clone BEFORE clearing: `derived` may borrow the very record
            // the clear frees (a same-named caller local's).
            var derived_clone: ?ir.TypeRef = null;
            if (derived) |dv| {
                var h = std.mem.trimEnd(u8, dv.name, "?");
                if (std.mem.indexOfScalar(u8, h, '<')) |lt| h = h[0..lt];
                const bare = (h.len > 0 and h.len <= 2 and std.ascii.isUpper(h[0])) or
                    b.isTypeParam(h) or ir.parseClassTypeParamIdentity(h) != null;
                if (!bare) derived_clone = try dv.clone(b.allocator);
            }
            // ALWAYS shadow the caller's same-named record for a
            // tp-declared param — with nothing derivable the body must
            // see NO record, never an unrelated caller local's.
            try param_ty_saves.append(b.allocator, .{
                .name = p.name.name,
                .ty = if (b.localDeclTypeRef(p.name.name)) |t| try t.clone(b.allocator) else null,
            });
            b.clearLocalDeclType(p.name.name);
            if (derived_clone) |dc| {
                try b.setLocalDeclTypeOwned(p.name.name, dc);
            } else if (b.typeParamBound(dh) != null) {
                // Nothing derivable from the argument, but the callee DECLARED
                // this parameter by one of its own bounded type parameters
                // (`destination: C where C : MutableCollection<in T>`). Record
                // that head: the receiver walk resolves a type parameter
                // through its bound, which is how Kotlin resolves a member on
                // such a value — leaving it blank made every member call in
                // the spliced body dynamic.
                try b.setLocalDeclTypeOwned(p.name.name, .{
                    .name = try b.allocator.dupe(u8, dh),
                    .nullable = p.ty.nullable,
                    .args = &.{},
                });
            }
        }
        // `noinline` parameters opt out of the inline-lambda splicing
        // path. Their argument value still flows through the binding
        // above, but a call to that parameter inside the inlined body
        // lowers as a normal CallValue against the reg instead of
        // inlining the lambda literal. Without this gate, every inline
        // call would splice every lambda argument's body — defeating
        // `noinline`'s point of letting the lambda be passed on or
        // stored.
        //
        // `crossinline` keeps the inline-lambda path, but a bare
        // `return` in the lambda body is illegal: the inlined body's
        // return targets the enclosing inline fn's caller, and
        // `crossinline` promises that the lambda will not perform such a
        // non-local return. Klio doesn't currently emit a parser-level
        // diagnostic for the violation; the runtime semantics still
        // match Kotlin.
        if (!p.is_noinline) {
            if (forwarded_lambda) |lam| {
                try lambda_map.put(p.name.name, lam);
                any_forwarded_lambda = true;
            } else if (a.* == .Lambda) {
                try lambda_map.put(p.name.name, a);
                any_literal_lambda = true;
            }
        }
    }
    // Mark params whose declared type is one of this inline fn's own
    // generic type-parameters, so a comparison operator on such an
    // operand inside the spliced body lowers to `compareTo` (total order
    // for Double/Float) — matching the reference compiler. The splice
    // binds the body in the caller's builder, so record which names we
    // add and remove them once the body is lowered to avoid leaking the
    // mark onto a same-named caller local.
    var marked_generic: std.ArrayList([]const u8) = .empty;
    defer marked_generic.deinit(b.allocator);
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
    // Mark params whose declared type is a receiver-typed function
    // (`block: T.() -> R`) so a bare `block(...)` in the spliced body
    // dispatches `this.block()`. Same record-and-remove discipline as
    // the generic marks above.
    var marked_rlp: std.ArrayList([]const u8) = .empty;
    defer marked_rlp.deinit(b.allocator);
    var shared_rlp_here: std.ArrayList([]const u8) = .empty;
    defer shared_rlp_here.deinit(b.allocator);
    for (f.params) |*p| {
        const has_recv = if (p.ty.function) |ft| ft.receiver != null else false;
        if (has_recv and b.isReceiverLambdaParam(p.name.name)) {
            // Already marked by an ENCLOSING splice: ownership is shared;
            // the caller-body suspension must keep it.
            try b.noteSharedRlpMark(p.name.name);
            try shared_rlp_here.append(b.allocator, p.name.name);
        }
        if (has_recv and !b.isReceiverLambdaParam(p.name.name)) {
            try b.markReceiverLambdaParam(p.name.name);
            // Record the declared receiver head so a spliced lambda body's
            // bare calls hint the LAMBDA's receiver (the innermost implicit
            // receiver), not the enclosing fn's; a type-parameter head is
            // statically unresolvable and records no hint.
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
    // A FORWARDED inline lambda is caller-of-caller code: its free names,
    // bare-call hints, and receiver context belong to the frame it was
    // forwarded FROM, not this call site. When every substituted lambda is
    // forwarded, inherit the outer frame's provenance wholesale.
    var frame_hint_active = prev_hint_active;
    var frame_hint_recv = prev_hint_recv;
    var frame_this_narrow = prev_this_narrow;
    if (any_forwarded_lambda and !any_literal_lambda) {
        if (b.inlineLambdaCallerDepth()) |d| caller_scope_depth = d;
        if (b.inlineLambdaCallerHint()) |h| {
            frame_hint_active = h.active;
            frame_hint_recv = h.recv;
            frame_this_narrow = h.this_narrow;
        }
    }
    try b.pushInlineLambdaFrameHinted(lambda_map, caller_scope_depth, frame_hint_active, frame_hint_recv, frame_this_narrow);
    // An inline extension splice's body resolves names against the inline
    // function's own parameter/receiver scopes, not the caller lambda's free
    // names. When this splice is itself nested inside a spliced
    // inline-argument lambda, that outer `lambda_splice_resolve` window skips
    // the very scopes this splice binds its `this`/params into — so a bare
    // member call in the body (`receiveNullable(...)` inside a spliced
    // `ApplicationCall.receive`) cannot see the bound receiver. After lowering
    // the receiver expression (which IS a caller free name and needs the
    // window), suspend the window so the extension body's own bindings resolve
    // normally; it is restored after the body.
    // A member-inline fn spliced through an EXPLICIT receiver
    // (`CC(e, a).pfw<E> { … }`, `coordinator.visitNodes(type) { … }`)
    // binds that receiver as the body's `this` exactly like a
    // receiver extension: the body's own member reads (`e.g()`) and its
    // nested reified calls resolve against it. Without the binding the
    // call fell to runtime member dispatch with the reified parameter
    // dead (`E::class` reading the `kotlin.math.E` global).
    const ext_splice = (f.receiver_type != null or member_splice) and this_arg != null;
    // The member body's bare sibling calls (`visitNodes(mask, include)`
    // inside `visitNodes(type, block)`, `headToTail(...)`) must lower as
    // member-shadowable dispatch on the bound `this`, exactly as the
    // declaration lowering scopes them: activate the owner class and its
    // hierarchy's member-name set for the splice.
    // A spliced body resolves in its DECLARATION scope: park the caller's
    // member sets and lexical owner so a bare `indices` inside a spliced
    // `UByteArray.getOrElse` is the receiver's extension property, not a
    // same-named METHOD of the calling class. MEMBER splices park too —
    // their owner swap below installs the owner scope on top of the parked
    // (cleared) sets, and the call-site LAMBDA swaps the parked caller
    // scope back in (`enterCallerMemberScope` in spliceInlineLambda): a
    // bare nested-class ctor in the lambda (`throw TestException()` inside
    // `UnsafeBufferOperations.readFromHead(buffer) { ... }`) must see the
    // CALLER class's nesteds, which the owner scope hid.
    // `KLIO_SPLICE_HYG=0` disables.
    var hyg_snap: build.FuncBuilder.MemberScopeSnapshot = undefined;
    const hyg_active = (ext_splice or member_splice) and
        !std.mem.eql(u8, inline_state.runtime.envOnce("KLIO_SPLICE_HYG") orelse "1", "0");
    if (hyg_active) b.beginSpliceDeclScope(&hyg_snap);
    defer if (hyg_active) b.endSpliceDeclScope(&hyg_snap);
    var member_scope_prev_owner: ?[]const u8 = null;
    var member_scope_prev_members: ?build.StringSet = null;
    // The body's lexical scope is the owner class, not the call site: bare
    // names in a spliced MEMBER body must never bind a caller local (the
    // caller's `slots` parameter captured the body's `slots`-field read).
    // The floor covers the whole splice; the caller-lambda window overrides
    // it while an arg lambda lowers, and body finallies replayed inside
    // that window still resolve above the floor.
    var prev_body_floor: ?usize = null;
    var body_floor_set = false;
    // A spliced body resolves bare names in the CALLEE's scope: the
    // caller's locals sit below the floor for member AND extension
    // splices alike (`serializer(typeOf<T>())` inside the pack's
    // `SerializersModule.serializer<T>()` must never bind a caller's
    // `serializer` parameter). The splice's own parameters are bound
    // above the floor; an argument lambda's body keeps the caller
    // window.
    if (hyg_active) {
        prev_body_floor = b.splice_body_floor;
        b.splice_body_floor = caller_scope_depth;
        body_floor_set = true;
    }
    defer if (body_floor_set) {
        b.splice_body_floor = prev_body_floor;
    };
    if (member_splice) {
        const owner = inline_state.inlineMemberOwner(f).?;
        member_scope_prev_owner = b.owner_class;
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
            member_scope_prev_members = prev;
        } else {
            merged.deinit();
        }
    }
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
    // An EXT-splice's bound receiver is an implicit receiver inner to
    // any spliced lambda subject already on the tower: push it too so
    // the runtime chain stays complete (`resumeWith` inside a spliced
    // `Continuation.resume`, itself inside a spliced atomic `loop { }`,
    // dispatches on the continuation, which no other walk entry holds).
    // Only while a tower region is active — outside one, emissions pin
    // the bound register directly, exactly as before.
    const encl_ext_pushed = explicit_receiver != null and rfsEnabled() and b.encl_tower_depth > 0;
    const prev_ext_tower_top = b.encl_tower_top;
    if (encl_ext_pushed) {
        try b.push(.{ .EnclosingPush = .{ .src = explicit_receiver.? } });
        b.encl_tower_depth += 1;
        b.encl_tower_top = explicit_receiver.?;
    }
    const ext_subject_pushed = explicit_receiver != null;
    if (explicit_receiver) |receiver| {
        // The bound receiver shadows `this` for the body: join the
        // subject-bind stack so a nested bare member-inline splice can
        // find the receiver its owner actually dispatches on.
        try b.subject_binds.append(b.allocator, .{
            .reg = receiver,
            .head = b.spliceRecvTy(),
            // The body floor hides the caller's `this` from the spliced
            // body; the subject record keeps it for reads a nested
            // window must bind beneath the subjects.
            .prior_this = b.resolveIgnoringFloor("this"),
        });
        try b.bind("this", receiver);
        if (inline_state.runtime.envOnce("KLIO_THIS_TRACE") != null) {
            std.debug.print("[splice-bind] {s} this=r{d} scope={d}\n", .{ fname, receiver.int(), b.scopes.items.len - 1 });
        }
        // `this@<fn>` inside the spliced body (including an anon object's
        // members, which capture it by this name) must reach the splice
        // receiver — a real call binds the label at function entry; the
        // splice provides the same binding in its scope.
        const label = try std.fmt.allocPrint(b.allocator, "this@{s}", .{fname});
        try b.bind(label, receiver);
    }
    defer if (ext_subject_pushed) {
        _ = b.subject_binds.pop();
    };
    // A BARE member-inline call inside spliced-subject regions
    // (`with(rec) { bump2(...) }` where `bump2` is the enclosing class's
    // member): the call dispatches on the innermost receiver whose class
    // reaches the OWNER. The ambient scope `this` is the innermost
    // subject; when that subject (or any inner one) cannot receive the
    // member, the body's `this` is the owning receiver further out —
    // without the rebind every owner member access pins to the subject.
    if (this_arg == null and inline_state.inlineMemberOwner(f) != null and
        b.subject_binds.items.len != 0) owner_this: {
        const owner = inline_state.inlineMemberOwner(f).?;
        const owner_base = if (std.mem.indexOf(u8, owner, "$f")) |oi| owner[0..oi] else owner;
        var si = b.subject_binds.items.len;
        while (si > 0) {
            si -= 1;
            const sb = b.subject_binds.items[si];
            // An unknown subject head cannot be disproven a receiver:
            // keep the ambient binding.
            const h = sb.head orelse break :owner_this;
            if (b.module.classIsOrExtends(h, owner) or
                b.module.classIsOrExtends(h, owner_base))
            {
                // This subject receives the call. Innermost is already
                // the ambient `this`; an outer one rebinds to its reg.
                if (si != b.subject_binds.items.len - 1) {
                    try b.bind("this", sb.reg);
                }
                break :owner_this;
            }
        }
        const outer = b.subject_binds.items[0].prior_this orelse break :owner_this;
        try b.bind("this", outer);
    }
    if (ext_splice) {
        prev_splice_window = b.lambda_splice_resolve;
        b.lambda_splice_resolve = null;
    }
    // Bind each reified type parameter to the resolved class value at the
    // call site. Two bindings are needed:
    //
    //   * Local: `T` resolves as a value (the spliced body's `T::class`
    //     read lowers as a bare `T` Path → MemberRef `.class`, the Path
    //     resolves through the local bind).
    //   * Global: `Inst::InstanceOf { ty: TypeRef "T" }` checks the value
    //     against the global named "T" (mirroring how `call_func_typed`
    //     binds runtime type-args). Without the global, `x is T` would
    //     test against a non-existent class `T` and silently fall through
    //     to `true`.
    //
    // The global isn't saved/restored — same shape klio uses for type-arg
    // binding in non-inline calls. A nested splice overwrites it; a later
    // restore happens implicitly when the enclosing call returns.
    // Explicit `<…>` type arguments win; any reified parameter left
    // unspecified is inferred by unifying the function's declared return
    // type against the call's expected (tail-position) type, so
    // `val u: User = resp.body()` binds `T = User` with no `<User>`.
    // The callee frame is pushed by now: argument-derived bindings rename
    // nested classes through the CALLER's lexical owner.
    const prev_splice_owner = splice_lexical_owner;
    splice_lexical_owner = lexical_owner;
    defer splice_lexical_owner = prev_splice_owner;
    const effective_type_args = try inferReifiedTypeArgsRecv(b.allocator, f, type_args, expected, ordered, b, this_arg);
    defer b.allocator.free(effective_type_args);
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
    const ReifiedRestore = struct { name: []const u8, prev: ?Reg };
    var reified_restores: std.ArrayList(ReifiedRestore) = .empty;
    defer reified_restores.deinit(b.allocator);
    // NAME substitutions for the splice's reified params (`T` -> `E`),
    // consumed by `emitCall`/`emitExtBareCall` to stamp static type args
    // onto nested calls in the spliced body — the body's
    // `enumEntriesIntrinsic()` otherwise reaches the runtime with no type
    // information at all.
    const NameRestore = struct { name: []const u8, prev: ?[]const u8 };
    var reified_name_restores: std.ArrayList(NameRestore) = .empty;
    defer reified_name_restores.deinit(b.allocator);
    defer for (reified_name_restores.items) |nr| b.restoreReifiedTypeName(nr.name, nr.prev);
    for (f.type_params, 0..) |tp, tp_idx| {
        if (!tp.is_reified) continue;
        const arg = if (tp_idx < effective_type_args.len) effective_type_args[tp_idx] else null;
        var cls_reg_opt: ?Reg = null;
        if (arg) |a| {
            // The stamped name resolves through the scope rename too: a
            // mangled nested class (`enumEntries<Item>()` where `Item`
            // lifted as `A$Item`) must reach the runtime as the lifted
            // name the class table actually holds.
            const head_sub = b.resolveReifiedTypeName(a.name.name) orelse
                reifiedQualifiedName(b, a) orelse
                (expr_lower.scopeTypeRenameFrom(b, lexical_owner, a.name.name, a.name.span.file.int()) orelse a.name.name);
            // Carry the FULL generic spelling, not just the head: a nested
            // reified consumer (`typeOf<T>()` inside a spliced
            // `typeInfo<List<Int>>()`) reads the stamped name at runtime and
            // must see `List<Int>` to materialise the KType's arguments.
            const substituted = try renderReifiedTypeName(b, head_sub, &a);
            if (inline_state.runtime.envOnce("KLIO_SPLICE_TRACE")) |w| {
                if (std.mem.eql(u8, w, fname)) std.debug.print("[splice] {s} bind-name {s} := {s} (head_sub={s}, written={s}, owner={?s})\n", .{ fname, tp.name.name, substituted, head_sub, a.name.name, b.ownerClass() });
            }
            const nprev = try b.bindReifiedTypeName(tp.name.name, substituted);
            try reified_name_restores.append(b.allocator, .{ .name = tp.name.name, .prev = nprev });
        }
        if (arg) |a| {
            // A type argument naming an *enclosing splice's* reified
            // parameter chains lexically: `trySuspend<TaskType>(...)`
            // inside a spliced `sleepWhile<reified TaskType>` body reuses
            // the class value the outer splice already resolved.
            if (b.resolveReifiedType(a.name.name)) |reg| {
                cls_reg_opt = reg;
            } else {
                const cls_reg = b.allocReg();
                // A private / file-local nested class is lifted under a mangled
                // name; resolve the type-arg name through the scope rename (the
                // same path `Nested(args)` construction takes) so a reified
                // `<PrivateNested>` binds its class instead of an unresolved
                // global of the source name.
                //
                // A FUNCTION-TYPE argument (`mutableVectorOf<() -> Unit>()`) has
                // the synthetic name `<function>`, which is not a global — and
                // Kotlin erases function types under reification anyway (a
                // reified `() -> Unit` reifies as `Function0`, not a distinct
                // class). Bind it to `Any` so the reified use (array creation,
                // membership) resolves rather than loading an unresolved global.
                // The bound CLASS is the head: a generic spelling carried in
                // the name (`Box<Int>`, from an enclosing binding or ctor-arg
                // inference) loads `Box`.
                const bare_head = if (std.mem.indexOfScalar(u8, a.name.name, '<')) |lt| a.name.name[0..lt] else a.name.name;
                const resolved_name = if (a.function != null)
                    "Any"
                else
                    reifiedQualifiedName(b, a) orelse
                        (expr_lower.scopeTypeRenameFrom(b, lexical_owner, bare_head, a.name.span.file.int()) orelse bare_head);
                const arg_name = try b.module.internConst(b.allocator, .{ .String = resolved_name });
                // Carry the resolved class identity so a builtin/stdlib type
                // whose bare name otherwise resolves to a constructor
                // intrinsic (an exception class) binds the `.Class` value
                // instead, matching how a concrete `Type::class` receiver
                // lowers. Without it `T::class` for such a type yields the
                // intrinsic and member dispatch (`isInstance`) misses.
                const idx_pick = b.module.classIdIndexed(resolved_name, b.self_package, a.name.span.file);
                const flat_pick = b.module.classId(resolved_name);
                const cls_pick: ?ir.ClassId = idx_pick orelse flat_pick;
                // Constructor-ref semantics: a reified type argument binds the
                // CLASS value, so a type that declares a `companion object`
                // yields the class (its `T::class`), not the published
                // companion singleton (which would degrade to
                // `T$Companion$Companion` after the companion is built).
                try b.push(.{ .LoadGlobal = .{ .dst = cls_reg, .name = arg_name, .class = cls_pick, .ctor_ref = true } });
                cls_reg_opt = cls_reg;
            }
        } else if (callableRefParamFor(f, ordered, tp.name.name)) |pi| {
            // Inferred from a constructor-reference argument
            // (`sleepWhile(Slot::Read)` solves `TaskType = Slot.Read`
            // from `createTask: (Continuation<Unit>) -> TaskType`): the
            // lowered reference IS the class value, so bind it directly.
            cls_reg_opt = arg_regs[pi];
        }
        const cls_reg = cls_reg_opt orelse continue;
        try b.bind(tp.name.name, cls_reg);
        const tp_global = try b.module.internConst(b.allocator, .{ .String = tp.name.name });
        try b.push(.{ .StoreGlobal = .{ .name = tp_global, .value = cls_reg } });
        const prev = try b.bindReifiedType(tp.name.name, cls_reg);
        try reified_restores.append(b.allocator, .{ .name = tp.name.name, .prev = prev });
    }
    // Record each parameter's declared type (with this splice's reified
    // substitutions applied) so a nested reified inline call in the body
    // that passes these parameters along can solve its own type
    // parameters lexically.
    const SpRestore = struct { name: []const u8, prev: ?ast.TypeRef };
    var splice_ty_restores: std.ArrayList(SpRestore) = .empty;
    defer splice_ty_restores.deinit(b.allocator);
    defer for (splice_ty_restores.items) |sr| b.restoreSpliceParamTy(sr.name, sr.prev);
    for (f.params) |*p| {
        const sub = try substReifiedInTypeRef(b, &p.ty);
        const sprev = try b.bindSpliceParamTy(p.name.name, sub);
        try splice_ty_restores.append(b.allocator, .{ .name = p.name.name, .prev = sprev });
        if (inline_state.runtime.envOnce("KLIO_SPLICE_TRACE")) |w| {
            if (std.mem.eql(u8, w, fname)) std.debug.print("[splice] {s} bound {s}: {s}\n", .{ fname, p.name.name, sub.name.name });
        }
    }
    // The callee's non-reified type-parameter BOUNDS ride along with its
    // param types: `destination: M` reaches the caller's builder through the
    // splice-ty channel, and without `M : MutableMap<...>` the head names
    // nothing and every member call on `destination` stays dynamic. Marked
    // incomplete — the record supports the receiver-owner lookup, never a
    // negative proof.
    var splice_bound_restores: std.ArrayList(build.FuncBuilder.SpliceBoundRestore) = .empty;
    defer splice_bound_restores.deinit(b.allocator);
    defer for (splice_bound_restores.items) |sb| b.restoreSpliceTypeParamBound(sb);
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
    // Mark body-declared `var`s that a nested closure writes as boxed so
    // their decl emits `MakeCell` and the closure's write lands on the
    // shared cell. (Params were boxed at bind time above; this covers
    // `var`s declared inside the spliced body.) Record newly-boxed names so
    // the mark is removed after the splice and cannot reach a same-named
    // caller local.
    {
        var sit = splice_boxed.keyIterator();
        while (sit.next()) |k| {
            if (paramIndex(f, k.*) != null) continue; // params handled at bind time
            if (!b.isBoxed(k.*)) {
                try b.markBoxed(k.*);
                try boxed_here.append(b.allocator, k.*);
            }
        }
    }
    const result = b.allocReg();
    const unit0 = try b.emitConst(Const.Unit);
    try b.push(.{ .Move = .{ .dst = result, .src = unit0 } });
    const join = try b.allocBlock();
    try b.pushInlineReturn(result, join, f.name.name);
    // A body that mentions `return@<this fn>` may put that return inside a
    // closure that crosses a real frame (a lambda handed to a nested inline
    // call that runs unspliced), where it unwinds at runtime as a
    // `LabeledReturn` toward a frame this splice never creates. Arm a
    // runtime absorption region over the spliced body so such an unwind
    // resolves to this splice's join.
    const needs_lr_absorb = blk: {
        switch (body.*) {
            .Block => |bb| {
                for (bb.stmts) |*st| if (ast_scan.containsLabeledReturnStmt(st, f.name.name)) break :blk true;
            },
            .Expr => |*ex| if (ast_scan.containsLabeledReturn(ex, f.name.name)) break :blk true,
        }
        break :blk false;
    };
    if (needs_lr_absorb and inline_state.runtime.envOnce("KLIO_NO_LR_ABSORB") == null) {
        const region = try b.allocBlock();
        b.terminate(.{ .Goto = region });
        b.switchTo(region);
        b.setLrAbsorb(region, f.name.name, join, result);
    }
    const body_val = switch (body.*) {
        // Lower an expression body with the inline function's own declared
        // return type as the expected (tail-position) type — exactly as a
        // normal function body lowers. A tail-position reified call then
        // infers its type argument from this function's return type rather
        // than the splice site's surrounding expected, so a chain like
        // `receiveChannel(): ByteReadChannel = receive()` binds the inner
        // `receive`'s `T` to `ByteReadChannel`.
        .Expr => |*e| blk: {
            const prev = b.pushExpected(f.return_type);
            defer b.restoreExpected(prev);
            break :blk try lowerExpr(b, e);
        },
        .Block => |*blk| try lowerBlock(b, blk),
    };
    try b.push(.{ .Move = .{ .dst = result, .src = body_val } });
    if (ext_splice) b.lambda_splice_resolve = prev_splice_window;
    b.terminate(.{ .Goto = join });
    b.switchTo(join);
    if (encl_ext_pushed) {
        try b.push(.{ .EnclosingPop = .{} });
        b.encl_tower_depth -= 1;
        b.encl_tower_top = prev_ext_tower_top;
    }
    for (marked_rlp.items) |n| {
        b.unmarkReceiverLambdaParam(n);
        b.clearSpliceRlpMark(n);
    }
    for (shared_rlp_here.items) |n| b.clearSharedRlpMark(n);
    // Remove the boxing marks added for this splice so a same-named caller
    // local keeps its own (un)boxed status.
    for (boxed_here.items) |n| b.unmarkBoxed(n);
    // Restore enclosing reified-type bindings shadowed by this splice
    // (reverse order so nested same-named params unwind correctly).
    {
        var ri: usize = reified_restores.items.len;
        while (ri > 0) {
            ri -= 1;
            const rr = reified_restores.items[ri];
            b.restoreReifiedType(rr.name, rr.prev);
        }
    }
    b.popInlineReturn();
    b.popInlineLambdaFrame();
    try b.popScope();
    b.popInlineDecl();
    inline_state.inlineExpandLeave();
    return result;
}

/// The runtime-resolvable class name for a reified type argument: a
/// QUALIFIED nested reference (`IntervalList.Interval`) resolves to its
/// lifted `$`-mangled class (`IntervalList$Interval`, trying deeper
/// nesting when two segments miss); an unqualified name falls back to
/// the lexical scope-rename ladder unchanged.
fn reifiedQualifiedName(b: *FuncBuilder, a: ast.TypeRef) ?[]const u8 {
    // An INFERRED nested type argument (`T` = `Foo.Bar` derived from a
    // `Foo.Bar(1)` argument) carries its dotted spelling in `name`, not
    // `qualified_path`, so resolve either: the dotted head names a
    // `.`-aligned suffix of the nested class's lifted fqn, and without it
    // the reified bind loads a bare `Foo.Bar` global that does not exist.
    const qp = a.qualified_path orelse
        (if (std.mem.indexOfScalar(u8, a.name.name, '.') != null and a.name.name[0] != '.')
            a.name.name
        else
            return null);
    // The dotted spelling is a `.`-aligned suffix of the class's fqn
    // (`Proto.Message.IntMessage` inside `Holder`): the registered name is
    // the lifted one the class table holds.
    // The dot-suffix hit's registered `name` can be the bare simple name
    // (`Error` for `Tests.ApiResponse.Error`), which the bare index resolves
    // to an unrelated classifier of that name (`kotlin.Error`): only a
    // spelling that resolves BACK to this class may stand for it — else the
    // lifted `Outer$Nested` candidates below, which the index keys, do.
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

/// Clone `ty` with the builder's active reified NAME substitutions
/// applied (`NodeKind<T>` -> `NodeKind<LayoutAwareModifierNode>`),
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

/// Whether every reified type parameter of `f` is solvable from the
/// call's non-lambda arguments (explicit generic-typed values, splice
/// parameters carrying recorded types). Used to keep a splice whose
/// trailing lambda under-declares the function-typed parameter's arity:
/// arity only matters when the lambda is the sole evidence for `T`.
/// Resolve the reified type-argument NAMES a call binds by inference
/// (the same evidence `reifiedBindableFromArgs` proves), mapped through
/// the active splice substitutions and scope renames — ready to stamp on
/// a typed dispatch instruction. Null when any reified parameter stays
/// unbound.
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
        // The FULL generic spelling: a typed member call binds its reified
        // parameter by name at runtime, and `typeOf<T>()` there needs the
        // arguments (`ParametrizedData<Data>` asks the companion for the
        // argument serializer).
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
/// constructor-reference argument: the parameter's declared type is a
/// function type whose return is the bare type parameter, and the
/// argument is a `Type::Nested` constructor reference — whose lowered
/// value is the referenced class, so the splice can bind the reified
/// parameter to it directly (`sleepWhile(Slot::Read)` solves
/// `TaskType = Slot.Read`).
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

/// Whether an expression is a `Type::Nested` constructor reference —
/// a `MemberRef` whose receiver is a type-name path and whose member
/// itself names a type (`Slot::Read`). A lowercase member (`obj::method`,
/// `String::length`) is a bound callable, not a class, so it never
/// solves a reified parameter here.
fn isTypeConstructorRef(e: *const Expr) bool {
    return switch (e.*) {
        .MemberRef => |mr| nameLooksLikeType(mr.name.name) and isTypeNamePath(mr.receiver),
        // `::Name` — a bare constructor reference.
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

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

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
