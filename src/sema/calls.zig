//! Call resolution: collect candidates level by level from the scope tower,
//! keep those applicable to the arguments (mapping positional, named,
//! vararg and trailing-lambda arguments, inferring type arguments), choose
//! the most specific, then analyze lambda arguments against the chosen
//! candidate's parameter types.
//!
//! Levels follow the language's priority: for a call without an explicit
//! receiver, each lexical scope's local functions, then that scope's
//! implicit receivers' members and the extensions that apply to them, and
//! finally top-level functions and constructors by import precedence. For
//! `recv.f()`, the receiver type's members, then extensions. A level with
//! an applicable candidate ends the search.

const std = @import("std");
const ast = @import("ast");
const span = @import("span");

const sema_mod = @import("sema.zig");
const symbols = @import("symbols.zig");
const types = @import("types.zig");
const names_mod = @import("names.zig");
const headers = @import("headers.zig");
const scope_mod = @import("scope.zig");
const subtyping = @import("subtyping.zig");
const members = @import("members.zig");
const records = @import("records.zig");
const infer = @import("infer.zig");
const body = @import("body.zig");

const Allocator = std.mem.Allocator;
const Sema = sema_mod.Sema;
const Sym = symbols.Sym;
const TypeId = types.TypeId;
const Name = names_mod.Name;
const wk = names_mod.wk;
const Expr = ast.Expr;
const Span = span.Span;
const Ctx = body.Ctx;
const Receiver = records.Receiver;
const RefKind = records.RefKind;

pub const Arg = struct {
    expr: *const Expr,
    name: ?Name = null,
    /// The argument's type, `.none` for a postponed argument.
    ty: TypeId = .none,
    spread: bool = false,
    /// A lambda, anonymous function or callable reference: analyzed after
    /// a candidate is chosen, against its parameter type.
    postponed: bool = false,
    /// A call whose own lambdas need a type only the chosen candidate
    /// gives (`sortedWith(compareBy(c) { it.first })`): resolved again,
    /// after the choice, against the parameter type.
    deferred: bool = false,
    /// A collection literal: the parameter type chooses the function it
    /// calls, so it is resolved once a candidate is chosen.
    literal: bool = false,
};

/// Whether a branching expression's result can be a lambda, anonymous
/// function or callable reference written in one of its branches.
fn branchesGiveLambda(e: *const Expr) bool {
    return switch (e.*) {
        .If => |i| i.else_branch != null and (givesLambda(i.then_branch) or givesLambda(i.else_branch.?)),
        .When => |w| blk: {
            for (w.branches) |*br| if (givesLambda(&br.body)) break :blk true;
            break :blk false;
        },
        .Binary => |b| b.op == .Elvis and (givesLambda(b.lhs) or givesLambda(b.rhs)),
        else => false,
    };
}

fn givesLambda(e: *const Expr) bool {
    return switch (e.*) {
        .Lambda, .AnonFun, .PropertyRef, .MemberRef => true,
        .Labeled => |l| givesLambda(l.expr),
        .Block => |b| b.stmts.len != 0 and switch (b.stmts[b.stmts.len - 1]) {
            .Expr => |*last| givesLambda(last),
            else => false,
        },
        else => branchesGiveLambda(e),
    };
}

/// Whether a call (or a branch of an elvis or `if` that is one) passes a
/// lambda whose own result is a lambda.
fn lambdaGivesLambda(e: *const Expr) bool {
    switch (e.*) {
        .Binary => |b| return b.op == .Elvis and (lambdaGivesLambda(b.lhs) or lambdaGivesLambda(b.rhs)),
        .If => |i| return i.else_branch != null and (lambdaGivesLambda(i.then_branch) or lambdaGivesLambda(i.else_branch.?)),
        .Call => |c| {
            for (c.args) |*a| {
                var inner = a;
                if (inner.* == .Labeled) inner = inner.Labeled.expr;
                if (inner.* != .Lambda) continue;
                const stmts = inner.Lambda.body.stmts;
                if (stmts.len == 0) continue;
                switch (stmts[stmts.len - 1]) {
                    .Expr => |*last| if (givesLambda(last)) return true,
                    else => {},
                }
            }
            return false;
        },
        else => return false,
    }
}

/// Whether a call expression passes a lambda anywhere in its arguments,
/// directly or to a call among them (`nullsLast(compareBy { it.x })`,
/// whose lambda's input only the call `nullsLast` is passed to gives), or
/// a branch of an elvis or `if` is such a call.
fn callHasLambda(e: *const Expr) bool {
    switch (e.*) {
        .Binary => |b| return b.op == .Elvis and (callHasLambda(b.lhs) or callHasLambda(b.rhs)),
        .If => |i| return i.else_branch != null and (callHasLambda(i.then_branch) or callHasLambda(i.else_branch.?)),
        else => {},
    }
    if (e.* != .Call) return false;
    for (e.Call.args) |*a| {
        var inner = a;
        if (inner.* == .Labeled) inner = inner.Labeled.expr;
        if (inner.* == .Spread) inner = inner.Spread.expr;
        switch (inner.*) {
            .Lambda, .AnonFun => return true,
            .Call => if (callHasLambda(inner)) return true,
            else => {},
        }
    }
    return false;
}

pub const Cand = struct {
    /// The function or constructor called; for `invoke` on a value, the
    /// `invoke` function.
    sym: Sym,
    /// The declaring class's type parameters as seen through the receiver.
    subst: *const types.Subst,
    dispatch: Receiver = .none,
    extension: Receiver = .none,
    /// The type of the value bound to the extension receiver.
    ext_ty: TypeId = .none,
    /// For `invoke` on a local or property: the value's symbol.
    via: Sym = .none,
    via_dispatch: Receiver = .none,
    /// For `invoke` on an extension property: where its extension
    /// receiver comes from.
    via_extension: Receiver = .none,
    /// A constructor of a class reached through a type alias carries the
    /// alias's expansion as its result.
    ctor_result: TypeId = .none,
    /// The type alias a constructor is called through: its type
    /// parameters are the ones inferred.
    alias: Sym = .none,
    /// `invoke` on a value of extension-function type whose receiver is
    /// supplied by the call's receiver (`recv.block()`) or an implicit
    /// receiver (`block()` inside it): that receiver is the first argument.
    recv_arg_ty: TypeId = .none,
    recv_arg_src: Receiver = .none,
    /// `invoke` on a value of contextual function type whose first this
    /// many parameters, the contexts, are taken from the scope.
    ctx_scope: u8 = 0,
    /// `invoke` on a value: a local, a property, an object, or any
    /// expression's result (`f(1)(2)`), recorded as an invoke.
    on_value: bool = false,
    /// `invoke` on a value of a composable function type.
    composable_value: bool = false,
    /// How the call runs, where the candidate's kind alone does not say:
    /// through `super`, a constructor delegation, a SAM constructor.
    form: records.CallForm = .plain,
    /// Another supertype's function this one stands for, whose default
    /// values a call takes (`members.Member.defaults`).
    defaults: Sym = .none,
    /// An inner class's constructor reached through a type alias on an
    /// outer instance: the instance's type, and the outer type the alias
    /// writes, whose parameters the instance fixes (`foo.InnerAlias("OK")`
    /// for `typealias InnerAlias<K> = Foo<K>.Inner` and a `Foo<String>`).
    outer_arg: TypeId = .none,
    outer_want: TypeId = .none,
};

const Slot = struct {
    param: u16,
    /// A positional argument absorbed by a vararg parameter.
    vararg_elem: bool = false,
    /// A named argument for a vararg parameter: the array it passes whole
    /// (`foo(x = arrayOf("a", "b"))`).
    named_array: bool = false,
};

const Applied = struct {
    cand: Cand,
    sys: infer.System,
    /// The arguments as the candidate sees them: the call's, with the
    /// receiver first for an extension-function-type `invoke`.
    args: []Arg,
    slots: []Slot,
    uses_default: u16,
    uses_vararg: bool,
    generic: bool,
    /// Where each context argument comes from.
    contexts: []const Receiver = &.{},
    /// Per operand (`args`), a conversion the argument goes through.
    conv: []records.Conv = &.{},
};

pub var empty_subst: types.Subst = .empty;

// -------------------------------------------------------------- entry ----

pub fn call(ctx: *Ctx, e: *const Expr, expected: TypeId) Allocator.Error!TypeId {
    const s = ctx.s;
    const c = e.Call;
    if (c.collection_literal) return collectionLiteral(ctx, e, expected);
    // `a f b` is `a.f(b)`: the left operand is the receiver.
    if (c.is_infix and c.args.len == 2 and c.callee.* == .Path and c.callee.Path.segments.len == 1) {
        const lt = try body.receiverExpr(ctx, &c.args[0]);
        const rhs = try prepareArgs(ctx, c.args[1..2], &.{});
        const recv_t = try literalReceiver(s, lt);
        return infixCall(ctx, recv_t, c.callee.Path.segments[0], rhs, expected);
    }
    // `r?.f(args)`: the arguments are evaluated only when `r` is not null,
    // so they see it (and its safe chain) smart cast.
    if (c.callee.* == .Member and c.callee.Member.safe and c.callee.Member.receiver.* != .Super) {
        const m = c.callee.Member;
        const rt = try body.receiverExpr(ctx, m.receiver);
        const facts = try body.nonNullFacts(ctx, m.receiver);
        const sc = try ctx.push(.block, .none);
        defer ctx.pop(sc);
        try body.applyFacts(ctx, facts);
        const args = try prepareArgs(ctx, c.args, c.argNames());
        const type_args = try explicitTypeArgs(ctx, c.typeArgs());
        const t = try memberCall(ctx, rt, .expr, m.name, args, c.has_trailing_lambda, type_args, expected, true);
        return s.types.makeNullable(t);
    }
    const args = try prepareArgs(ctx, c.args, c.argNames());
    const type_args = try explicitTypeArgs(ctx, c.typeArgs());
    switch (c.callee.*) {
        .Path => |p| {
            if (p.segments.len == 1) {
                return bareCall(ctx, p.segments[0], args, c.has_trailing_lambda, type_args, expected);
            }
            const prefix = p.segments[0 .. p.segments.len - 1];
            const last = p.segments[p.segments.len - 1];
            const head = try body.pathHead(ctx, prefix);
            if (head.kind == .none) {
                try ctx.report(.unresolved_name, prefix[0].span, "{s}", .{try scope_mod.pathStr(s, prefix)});
                return s.types.errType();
            }
            if (head.used == prefix.len) {
                switch (head.kind) {
                    .package => return packageCall(ctx, head.pkg, last, args, c.has_trailing_lambda, type_args, expected),
                    .classifier => return staticCall(ctx, head.cls, prefix[prefix.len - 1].span, last, args, c.has_trailing_lambda, type_args, expected),
                    .value => return memberCall(ctx, head.ty, .expr, last, args, c.has_trailing_lambda, type_args, expected, false),
                    .none => unreachable,
                }
            }
            // A value or classifier prefix followed by more members.
            const recv_t = try body.qualifiedAccessPrefix(ctx, prefix, head);
            return memberCall(ctx, recv_t, .expr, last, args, c.has_trailing_lambda, type_args, expected, false);
        },
        .Member => |m| {
            if (m.receiver.* == .Super) return superCall(ctx, m.receiver.Super, m.name, args, c.has_trailing_lambda, type_args, expected);
            if (try body.asQualifier(ctx, m.receiver)) |q| {
                switch (q.kind) {
                    .package => return packageCall(ctx, q.pkg, m.name, args, c.has_trailing_lambda, type_args, expected),
                    .classifier => return staticCall(ctx, q.cls, body.lastNameSpan(m.receiver), m.name, args, c.has_trailing_lambda, type_args, expected),
                    else => {},
                }
            }
            const rt = try body.receiverExpr(ctx, m.receiver);
            const t = try memberCall(ctx, rt, .expr, m.name, args, c.has_trailing_lambda, type_args, expected, m.safe);
            return if (m.safe) s.types.makeNullable(t) else t;
        },
        else => {
            // `(expr)(args)`: `invoke` on the value.
            const vt = try body.receiverExpr(ctx, c.callee);
            return invokeValue(ctx, vt, c.callee.span(), .none, .none, .expr, args, c.has_trailing_lambda, expected);
        },
    }
}

/// Types a call's arguments before its candidates are checked. A lambda,
/// a callable reference or a collection literal waits for the chosen
/// candidate's parameter type; so does a call whose own lambda needs it.
fn prepareArgs(ctx: *Ctx, exprs: []const Expr, arg_names: []const ?[]const u8) Allocator.Error![]Arg {
    const s = ctx.s;
    const out = try s.arena.alloc(Arg, exprs.len);
    const saved = ctx.in_arg;
    defer ctx.in_arg = saved;
    for (exprs, out, 0..) |*a, *o, i| {
        o.* = .{ .expr = a };
        if (i < arg_names.len) {
            if (arg_names[i]) |n| o.name = try ctx.intern(n);
        }
        var inner = a;
        if (a.* == .Spread) {
            o.spread = true;
            inner = a.Spread.expr;
        }
        switch (inner.*) {
            // A class literal's type is known now: `Base::class` is a
            // `KClass<Base>`, which may rule a candidate out or fix what a
            // lambda argument takes.
            .MemberRef => |r| if (isClassLiteral(r)) {
                ctx.in_arg = .arg;
                o.ty = try body.expr(ctx, inner, .none);
                continue;
            } else {
                o.postponed = true;
                continue;
            },
            .Lambda, .AnonFun, .PropertyRef => {
                o.postponed = true;
                continue;
            },
            .Labeled => |l| if (l.expr.* == .Lambda) {
                o.postponed = true;
                continue;
            },
            .Call => |c| if (c.collection_literal) {
                o.postponed = true;
                o.literal = true;
                continue;
            },
            else => {},
        }
        // `if (c) { { x -> ... } } else null`: a lambda a branch gives is
        // typed by the parameter, so the whole argument waits for it.
        if (branchesGiveLambda(inner)) {
            o.postponed = true;
            o.deferred = true;
            continue;
        }
        // `key?.let { { key } }`: a lambda whose result is a lambda needs
        // the parameter's function type, which only the chosen candidate
        // gives.
        if (lambdaGivesLambda(inner)) {
            o.postponed = true;
            o.deferred = true;
            continue;
        }
        ctx.in_arg = .arg;
        if (callHasLambda(inner)) {
            // Resolved tentatively: kept when its type is complete, else
            // resolved again once the enclosing call knows what it expects.
            // A lambda typed by builder inference is a guess the expected
            // type replaces: `cmp(Comparator { a, b -> a.compareTo(b) })`
            // takes `Comparator<Int>` from `cmp`'s parameter, not what the
            // lambda's body would make it, and
            // `listOf<Op<MutableList<String>>>(Op("add") { add("e") })`
            // the element type's receiver, not the one `add` would.
            const b = try ctx.beginBuffer();
            const saved_builder = ctx.builder_typed;
            const saved_shape = ctx.lambda_shape_guessed;
            ctx.builder_typed = false;
            ctx.lambda_shape_guessed = false;
            const t = body.expr(ctx, inner, .none) catch |e| {
                ctx.builder_typed = saved_builder;
                ctx.lambda_shape_guessed = saved_shape;
                return e;
            };
            const guessed = ctx.builder_typed or ctx.lambda_shape_guessed;
            ctx.builder_typed = saved_builder;
            ctx.lambda_shape_guessed = saved_shape;
            const z = try infer.zonk(s, t);
            if (b.sites.items.len == 0 and !guessed and !infer.hasUnboundedVar(s, z) and !s.types.isErr(z)) {
                try ctx.commit(b);
                o.ty = t;
            } else {
                ctx.drop(b);
                o.postponed = true;
                o.deferred = true;
            }
            continue;
        }
        o.ty = try body.expr(ctx, inner, .none);
    }
    return out;
}

/// `T::class` or `value::class`: a class literal, not a callable reference.
fn isClassLiteral(r: anytype) bool {
    return std.mem.eql(u8, r.name.name, "class");
}

/// The written type arguments; `.none` for one written `_`, which the call
/// infers (`foo<Int, _> { it.toFloat() }`).
fn explicitTypeArgs(ctx: *Ctx, trs: []const ast.TypeRef) Allocator.Error![]const TypeId {
    if (trs.len == 0) return &.{};
    const out = try ctx.arena().alloc(TypeId, trs.len);
    for (trs, out) |*tr, *o| o.* = if (isUnderscore(tr)) .none else try body.resolveTypeInBody(ctx, tr);
    return out;
}

fn isUnderscore(tr: *const ast.TypeRef) bool {
    return std.mem.eql(u8, tr.name.name, "_") and !tr.nullable and tr.type_args.len == 0 and tr.function == null;
}

// --------------------------------------------------------- candidates ----

const Level = std.ArrayList(Cand);

fn newLevel() Level {
    return .empty;
}

/// A call without an explicit receiver: `f(args)`.
fn bareCall(ctx: *Ctx, id: ast.Ident, args: []Arg, trailing: bool, type_args: []const TypeId, expected: TypeId) Allocator.Error!TypeId {
    const s = ctx.s;
    const n = try ctx.intern(id.name);
    var levels: std.ArrayList(Level) = .empty;
    // Local callables of every enclosing local scope rank above any
    // implicit receiver's members: a parameter `make` of the function an
    // object expression is in wins over the object's own `make()`.
    var sc: ?*body.Scope = ctx.scope;
    var hide = false;
    while (sc) |c| : (sc = c.parent) {
        if (!body.localsVisible(c, &hide)) continue;
        // The scope's local functions and callable locals.
        var local_level = newLevel();
        var i = c.locals.items.len;
        while (i > 0) {
            i -= 1;
            const l = c.locals.items[i];
            if (l.name != n) continue;
            switch (s.syms.kind(l.sym)) {
                .function => if (s.syms.functionInfo(l.sym).receiver == .none) {
                    try local_level.append(s.arena, .{ .sym = l.sym, .subst = &empty_subst });
                },
                .local, .value_param => {
                    const vt = try body.narrowedType(ctx, l.sym, try body.symbolType(ctx, l.sym));
                    try appendInvokes(ctx, &local_level, vt, l.sym, .none);
                },
                .class => try appendCallableCtors(ctx, &local_level, l.sym, .none),
                else => {},
            }
        }
        if (local_level.items.len != 0) try levels.append(s.arena, local_level);
        // A local of extension-function type invoked bare takes an implicit
        // receiver as its receiver, innermost first.
        var j = c.locals.items.len;
        while (j > 0) {
            j -= 1;
            const l = c.locals.items[j];
            if (l.name != n) continue;
            const k = s.syms.kind(l.sym);
            if (k != .local and k != .value_param) continue;
            const vt = try body.narrowedType(ctx, l.sym, try body.symbolType(ctx, l.sym));
            for (try body.implicitReceivers(ctx)) |r| {
                var rl = newLevel();
                try appendReceiverInvokes(ctx, &rl, vt, l.sym, .none, try body.narrowedReceiver(ctx, r), .{ .implicit = .{ .kind = r.kind, .owner = r.owner } });
                if (rl.items.len != 0) try levels.append(s.arena, rl);
            }
            break;
        }
    }
    sc = ctx.scope;
    while (sc) |c| : (sc = c.parent) {
        // Each implicit receiver: members, then extensions that take it.
        for (c.receivers.items) |r| {
            const rt = try body.narrowedReceiver(ctx, r);
            const recv: Receiver = .{ .implicit = .{ .kind = r.kind, .owner = r.owner } };
            var member_level = newLevel();
            var ext_props: std.ArrayList(TypeId) = .empty;
            var ext_syms: std.ArrayList(Sym) = .empty;
            // A receiver that may be null has no members to call bare; the
            // extensions on its nullable type apply (`toString()` in
            // `fun K?.foo()` is `Any?.toString()`).
            const members_apply = !try subtyping.admitsNull(s, rt);
            if (members_apply) for (try members.lookup(s, rt, n, .callable)) |m| {
                switch (s.syms.kind(m.sym)) {
                    .function => {
                        try headers.functionHeader(s, m.sym);
                        if (s.syms.functionInfo(m.sym).receiver != .none) continue;
                        try member_level.append(s.arena, .{ .sym = m.sym, .subst = m.subst, .dispatch = recv, .defaults = m.defaults });
                    },
                    .property => {
                        const pt = try members.memberType(s, m);
                        try appendInvokes(ctx, &member_level, pt, m.sym, recv);
                        try ext_props.append(s.arena, pt);
                        try ext_syms.append(s.arena, m.sym);
                    },
                    else => {},
                }
            };
            // An inner class of the receiver's class, built on it
            // (`Inner(args)` in an extension of the outer class).
            if (member_level.items.len == 0 and s.types.classSym(rt) != .none and r.kind != .class_this) {
                const nested = try scope_mod.nestedClassifier(s, s.types.classSym(rt), n);
                if (nested != .none and s.syms.kind(nested) == .class and s.syms.flags(nested).inner) {
                    try appendCtorsVia(ctx, &member_level, nested, .{ .dispatch = recv }, rt);
                }
            }
            if (member_level.items.len != 0) try levels.append(s.arena, member_level);
            // A property of extension-function type invoked bare takes an
            // implicit receiver as its receiver, innermost first.
            for (ext_props.items, ext_syms.items) |pt, ps| {
                for (try body.implicitReceivers(ctx)) |r2| {
                    var rl = newLevel();
                    try appendReceiverInvokes(ctx, &rl, pt, ps, recv, try body.narrowedReceiver(ctx, r2), .{ .implicit = .{ .kind = r2.kind, .owner = r2.owner } });
                    if (rl.items.len != 0) try levels.append(s.arena, rl);
                }
            }
            try appendExtensionLevels(ctx, &levels, n, recv, rt, false);
        }
        // A class's nested classifiers (its own, its companion's, its
        // supertypes') rank with the class, above anything top-level, and
        // so do its static functions: an enum's `values()` and `valueOf()`
        // called in its companion.
        if (c.kind == .class and c.owner != .none) {
            var statics = newLevel();
            for (scope_mod.membersOf(s, c.owner, n)) |m| {
                if (s.syms.kind(m) != .function or !s.syms.flags(m).static) continue;
                try statics.append(s.arena, .{ .sym = m, .subst = &empty_subst });
            }
            if (statics.items.len != 0) try levels.append(s.arena, statics);
            const nested = try scope_mod.nestedClassifier(s, c.owner, n);
            if (nested != .none) {
                var level = newLevel();
                switch (s.syms.kind(nested)) {
                    .class => try appendCallableCtors(ctx, &level, nested, .none),
                    .type_alias => try appendAliasCtors(ctx, &level, nested),
                    else => {},
                }
                if (level.items.len != 0) try levels.append(s.arena, level);
            }
        }
    }
    // Top-level functions, constructors and invocable properties, by import
    // precedence.
    // Enum entries and objects in an enclosing class's static scope, called
    // through `invoke`.
    if (try body.staticScopeValueSym(ctx, n)) |v| {
        var level = newLevel();
        try appendValueInvokes(ctx, &level, v);
        if (level.items.len != 0) try levels.append(s.arena, level);
    }
    for (try topLevelTiers(ctx, n)) |tier| {
        var level = newLevel();
        // A classifier's value (its companion, the object itself) called
        // through `invoke`: tried after the constructors of the same tier.
        var value_level = newLevel();
        for (tier) |m| {
            switch (s.syms.kind(m)) {
                .function => {
                    try headers.functionHeader(s, m);
                    if (s.syms.functionInfo(m).receiver != .none) continue;
                    try level.append(s.arena, .{ .sym = m, .subst = importedSubst(ctx, m), .dispatch = importedOwner(ctx, m) });
                },
                .property => {
                    try headers.propertyHeader(s, m);
                    if (s.syms.propertyInfo(m).receiver != .none) continue;
                    try appendInvokes(ctx, &level, try s.types.substitute(try headers.propertyType(s, m), importedSubst(ctx, m)), m, importedOwner(ctx, m));
                },
                .class => {
                    try appendCallableCtors(ctx, &level, m, .none);
                    try appendValueInvokes(ctx, &value_level, m);
                },
                .type_alias => try appendAliasCtors(ctx, &level, m),
                .enum_entry => try appendValueInvokes(ctx, &value_level, m),
                else => {},
            }
        }
        if (level.items.len != 0) try levels.append(s.arena, level);
        if (value_level.items.len != 0) try levels.append(s.arena, value_level);
    }
    // Classifiers in the enclosing declarations' scope (nested classes and
    // type aliases).
    const cls = try body.classifierInScope(ctx, n);
    if (cls != .none and s.syms.kind(cls) == .type_alias) {
        var level = newLevel();
        try appendAliasCtors(ctx, &level, cls);
        if (level.items.len != 0) try levels.append(s.arena, level);
    }
    if (cls != .none and s.syms.kind(cls) == .class) {
        var level = newLevel();
        try appendCallableCtors(ctx, &level, cls, .none);
        if (level.items.len != 0) try levels.append(s.arena, level);
        var value_level = newLevel();
        try appendValueInvokes(ctx, &value_level, cls);
        if (value_level.items.len != 0) try levels.append(s.arena, value_level);
    }
    return resolveLevels(ctx, levels.items, id, args, trailing, type_args, expected);
}

/// `a f b`: `a.f(b)` for an `infix` function `f` only, so an infix
/// extension is chosen over a member that is not infix
/// (`infix fun Int.rem(other: Int)` for `5 rem 2`).
fn infixCall(ctx: *Ctx, rt: TypeId, id: ast.Ident, args: []Arg, expected: TypeId) Allocator.Error!TypeId {
    return memberCallAs(ctx, rt, .expr, id, args, false, &.{}, expected, false, true);
}

/// `recv.f(args)` on a value of type `rt`.
pub fn memberCall(ctx: *Ctx, rt_lit: TypeId, recv_src: Receiver, id: ast.Ident, args: []Arg, trailing: bool, type_args: []const TypeId, expected: TypeId, safe: bool) Allocator.Error!TypeId {
    return memberCallAs(ctx, rt_lit, recv_src, id, args, trailing, type_args, expected, safe, false);
}

fn memberCallAs(ctx: *Ctx, rt_lit: TypeId, recv_src: Receiver, id: ast.Ident, args: []Arg, trailing: bool, type_args: []const TypeId, expected: TypeId, safe: bool, infix_only: bool) Allocator.Error!TypeId {
    const s = ctx.s;
    const rt_in = try literalReceiver(s, rt_lit);
    // A safe call sees the receiver not null: `T & Any` for a type
    // parameter, so its members apply.
    const rt = if (safe) try s.types.definitelyNotNull(rt_in) else rt_in;
    if (s.types.isErr(rt)) {
        try finishArgsBlind(ctx, args);
        try ctx.report(.receiver_unresolved, id.span, "{s}", .{id.name});
        return s.types.errType();
    }
    const n = try ctx.intern(id.name);
    var levels: std.ArrayList(Level) = .empty;
    var member_level = newLevel();
    // A receiver that may be null (`String?`, an unbounded `T`) has no
    // members without a safe call; the extensions that take a nullable
    // receiver apply (`Any?.toString()`).
    const members_apply = !try subtyping.admitsNull(s, rt);
    // `content.invoke()` on a composable function value.
    const comp_invoke = n == wk.invoke and try composableFunctionType(s, rt);
    if (members_apply) for (try members.lookup(s, rt, n, .callable)) |m| {
        switch (s.syms.kind(m.sym)) {
            .function => {
                try headers.functionHeader(s, m.sym);
                if (s.syms.functionInfo(m.sym).receiver != .none) continue;
                try member_level.append(s.arena, .{ .sym = m.sym, .subst = m.subst, .dispatch = recv_src, .composable_value = comp_invoke, .defaults = m.defaults });
            },
            .property => try appendInvokes(ctx, &member_level, try members.memberType(s, m), m.sym, recv_src),
            else => {},
        }
    };
    // An inner class's constructor on an outer instance: `outer.Inner()`,
    // or through a type alias of it: `outer.InnerAlias()`.
    if (s.types.classSym(rt) != .none) {
        const nested = try scope_mod.nestedClassifier(s, s.types.classSym(rt), n);
        if (nested != .none and s.syms.kind(nested) == .class and s.syms.flags(nested).inner) {
            try appendCtorsVia(ctx, &member_level, nested, .{ .dispatch = recv_src }, rt);
        }
        // An alias of an inner class nested in the receiver's class.
        if (nested != .none and s.syms.kind(nested) == .type_alias) {
            const target = s.types.classSym(try headers.aliasTarget(s, nested));
            if (target != .none and s.syms.flags(target).inner) try appendAliasCtorsOn(ctx, &member_level, nested, recv_src, rt);
        }
        if (member_level.items.len == 0) {
            for (try topLevelTiers(ctx, n)) |tier| {
                for (tier) |m| {
                    if (s.syms.kind(m) != .type_alias) continue;
                    const target = s.types.classSym(try headers.aliasTarget(s, m));
                    if (target == .none or !s.syms.flags(target).inner) continue;
                    if (try subtyping.supertypeWithClass(s, rt, s.syms.owner(target)) == null) continue;
                    try appendAliasCtorsOn(ctx, &member_level, m, recv_src, rt);
                }
                if (member_level.items.len != 0) break;
            }
        }
    }
    if (member_level.items.len != 0) try levels.append(s.arena, member_level);
    // A value of extension-function type named `n`, with the receiver as
    // its receiver: `recv.block()`.
    const rinv = try receiverInvokeLevel(ctx, n, rt, recv_src);
    if (rinv.items.len != 0) try levels.append(s.arena, rinv);
    try appendExtensionLevels(ctx, &levels, n, recv_src, rt, false);
    try appendExtPropInvokeLevel(ctx, &levels, n, rt, recv_src);
    if (infix_only) {
        for (levels.items) |*level| {
            var kept: usize = 0;
            for (level.items) |c| {
                if (c.via != .none or c.on_value or s.syms.kind(c.sym) != .function) continue;
                if (!try members.isInfix(s, c.sym)) continue;
                level.items[kept] = c;
                kept += 1;
            }
            level.shrinkRetainingCapacity(kept);
        }
    }
    // No candidate at all: the diagnostic names the type looked on.
    const none = for (levels.items) |level| {
        if (level.items.len != 0) break false;
    } else true;
    if (none) {
        try finishArgsBlind(ctx, args);
        try ctx.reportFacts(.unresolved_call, id.span, .{ .name = id.name, .on = try sema_mod.diagnose.typeText(s, s.arena, rt) }, "{s}", .{id.name});
        return s.types.errType();
    }
    return resolveLevels(ctx, levels.items, id, args, trailing, type_args, expected);
}

/// `Cls.f(args)`: a member of the class's companion or of the object, a
/// nested class's constructor, an enum class's `valueOf`/`values`.
/// `Cls.f(args)` and `Obj.f(args)`. `qual` is the qualifier's last name:
/// when the call goes to an object's or a companion's member, that object
/// is read there, as its receiver.
fn staticCall(ctx: *Ctx, cls: Sym, qual: Span, id: ast.Ident, args: []Arg, trailing: bool, type_args: []const TypeId, expected: TypeId) Allocator.Error!TypeId {
    const s = ctx.s;
    const n = try ctx.intern(id.name);
    var levels: std.ArrayList(Level) = .empty;
    var level = newLevel();
    var value_level = newLevel();
    for (scope_mod.membersOf(s, cls, n)) |m| {
        if (!scope_mod.visible(s, m)) continue;
        switch (s.syms.kind(m)) {
            .class => {
                try appendCallableCtors(ctx, &level, m, .none);
                try appendValueInvokes(ctx, &value_level, m);
            },
            .function => if (s.syms.flags(m).static) {
                try level.append(s.arena, .{ .sym = m, .subst = &empty_subst });
            },
            // `Op.ADD(2, 3)`: the entry's `invoke`.
            .enum_entry => try appendValueInvokes(ctx, &value_level, m),
            else => {},
        }
    }
    if (level.items.len != 0) try levels.append(s.arena, level);
    if (value_level.items.len != 0) try levels.append(s.arena, value_level);
    const info = s.syms.classInfo(cls);
    const holder: Sym = if (info.kind == .object or info.kind == .companion) cls else info.companion;
    // Nested constructors, static functions and entry invokes first; when
    // none applies, the holder object's members, with the holder read.
    if (levels.items.len != 0 and holder != .none) {
        const b = try ctx.beginBuffer();
        const t = try resolveLevels(ctx, levels.items, id, args, trailing, type_args, expected);
        if (b.sites.items.len == 0) {
            try ctx.commit(b);
            return t;
        }
        ctx.drop(b);
        levels.clearRetainingCapacity();
    }
    if (holder != .none) {
        try ctx.addRef(.{ .file = ctx.file, .anchor = qual, .kind = .object, .target = holder });
        const ht = try headers.selfType(s, holder);
        var member_level = newLevel();
        for (try members.lookup(s, ht, n, .callable)) |m| {
            switch (s.syms.kind(m.sym)) {
                .function => {
                    try headers.functionHeader(s, m.sym);
                    if (s.syms.functionInfo(m.sym).receiver != .none) continue;
                    try member_level.append(s.arena, .{ .sym = m.sym, .subst = m.subst, .dispatch = .expr });
                },
                .property => try appendInvokes(ctx, &member_level, try members.memberType(s, m), m.sym, .expr),
                else => {},
            }
        }
        if (member_level.items.len != 0) try levels.append(s.arena, member_level);
        try appendExtensionLevels(ctx, &levels, n, .expr, ht, false);
        // `Obj.content()` for a value `content: Obj.() -> Unit` in scope.
        const rl = try receiverInvokeLevel(ctx, n, ht, .expr);
        if (rl.items.len != 0) try levels.append(s.arena, rl);
        try appendExtPropInvokeLevel(ctx, &levels, n, ht, .expr);
    }
    return resolveLevels(ctx, levels.items, id, args, trailing, type_args, expected);
}

/// `pkg.f(args)`: a top-level function or constructor of the package.
fn packageCall(ctx: *Ctx, pkg: Sym, id: ast.Ident, args: []Arg, trailing: bool, type_args: []const TypeId, expected: TypeId) Allocator.Error!TypeId {
    const s = ctx.s;
    const n = try ctx.intern(id.name);
    var level = newLevel();
    for (scope_mod.membersOf(s, pkg, n)) |m| {
        if (!scope_mod.visible(s, m)) continue;
        switch (s.syms.kind(m)) {
            .function => {
                try headers.functionHeader(s, m);
                if (s.syms.functionInfo(m).receiver != .none) continue;
                try level.append(s.arena, .{ .sym = m, .subst = &empty_subst });
            },
            .class => try appendCallableCtors(ctx, &level, m, .none),
            .type_alias => try appendAliasCtors(ctx, &level, m),
            else => {},
        }
    }
    var levels = [_]Level{level};
    return resolveLevels(ctx, if (level.items.len != 0) levels[0..] else levels[0..0], id, args, trailing, type_args, expected);
}

/// What a collection literal calls, chosen by the type expected of it.
const LiteralTarget = union(enum) {
    none,
    /// The `operator fun of` of the expected class's companion.
    of: Sym,
    /// A library function: `listOf`, `setOf`, `intArrayOf`, ...
    function: struct { pkg: []const u8, name: []const u8 },
};

/// The library function a collection literal calls for an expected class
/// the compiler knows, by its fully qualified name.
const literal_functions = [_]struct { class: []const u8, pkg: []const u8, name: []const u8 }{
    .{ .class = "kotlin.collections.List", .pkg = "kotlin.collections", .name = "listOf" },
    .{ .class = "kotlin.collections.MutableList", .pkg = "kotlin.collections", .name = "mutableListOf" },
    .{ .class = "kotlin.collections.Set", .pkg = "kotlin.collections", .name = "setOf" },
    .{ .class = "kotlin.collections.MutableSet", .pkg = "kotlin.collections", .name = "mutableSetOf" },
    .{ .class = "kotlin.sequences.Sequence", .pkg = "kotlin.sequences", .name = "sequenceOf" },
    .{ .class = "kotlin.Array", .pkg = "kotlin", .name = "arrayOf" },
    .{ .class = "kotlin.IntArray", .pkg = "kotlin", .name = "intArrayOf" },
    .{ .class = "kotlin.LongArray", .pkg = "kotlin", .name = "longArrayOf" },
    .{ .class = "kotlin.ShortArray", .pkg = "kotlin", .name = "shortArrayOf" },
    .{ .class = "kotlin.ByteArray", .pkg = "kotlin", .name = "byteArrayOf" },
    .{ .class = "kotlin.CharArray", .pkg = "kotlin", .name = "charArrayOf" },
    .{ .class = "kotlin.BooleanArray", .pkg = "kotlin", .name = "booleanArrayOf" },
    .{ .class = "kotlin.FloatArray", .pkg = "kotlin", .name = "floatArrayOf" },
    .{ .class = "kotlin.DoubleArray", .pkg = "kotlin", .name = "doubleArrayOf" },
    .{ .class = "kotlin.UIntArray", .pkg = "kotlin", .name = "uintArrayOf" },
    .{ .class = "kotlin.ULongArray", .pkg = "kotlin", .name = "ulongArrayOf" },
    .{ .class = "kotlin.UShortArray", .pkg = "kotlin", .name = "ushortArrayOf" },
    .{ .class = "kotlin.UByteArray", .pkg = "kotlin", .name = "ubyteArrayOf" },
};

const list_of: LiteralTarget = .{ .function = .{ .pkg = "kotlin.collections", .name = "listOf" } };

/// The function a collection literal expected to be `expected` calls: the
/// `operator fun of` of the expected class's companion; for the library's
/// lists, sets, sequences and arrays, their `...Of` function; else `listOf`
/// where a `List` is what is expected (a `Collection`, an `Iterable`, `Any`)
/// or nothing usable is. `.none` for any other expected class.
fn literalTarget(ctx: *Ctx, expected: TypeId) Allocator.Error!LiteralTarget {
    const s = ctx.s;
    if (expected == .none) return list_of;
    const t = try s.types.makeNotNull(try infer.zonk(s, expected));
    const c = switch (s.types.get(t)) {
        .class => |c| c,
        else => return list_of,
    };
    const comp = s.syms.classInfo(c.sym).companion;
    if (comp != .none and try definesOf(ctx, comp)) return .{ .of = comp };
    const fqn = s.str(s.syms.classInfo(c.sym).fqn);
    for (literal_functions) |f| {
        if (std.mem.eql(u8, fqn, f.class)) return .{ .function = .{ .pkg = f.pkg, .name = f.name } };
    }
    if (s.builtins.list != .none and (try subtyping.supertypeWithClass(s, try headers.selfType(s, s.builtins.list), c.sym)) != null) return list_of;
    return .none;
}

/// Whether a companion declares or is extended by an `operator fun of`.
fn definesOf(ctx: *Ctx, comp: Sym) Allocator.Error!bool {
    const s = ctx.s;
    const n = try ctx.intern("of");
    const ct = try headers.selfType(s, comp);
    for (try members.lookup(s, ct, n, .function)) |m| {
        if (try members.isOperator(s, m.sym)) return true;
    }
    for (try extensionFunctions(ctx, n)) |x| {
        if (!try members.isOperator(s, x.sym)) continue;
        if (try extensionTakes(s, x.sym, x.subst, ct)) return true;
    }
    return false;
}

/// `[a, b]`: the function the expected type chooses, called with the
/// elements as its arguments.
fn collectionLiteral(ctx: *Ctx, e: *const Expr, expected: TypeId) Allocator.Error!TypeId {
    const s = ctx.s;
    const c = e.Call;
    const at = c.callee.span();
    const args = try prepareArgs(ctx, c.args, c.argNames());
    switch (try literalTarget(ctx, expected)) {
        .none => {
            try finishArgsBlind(ctx, args);
            try ctx.reportFacts(.unresolved_call, at, .{
                .message = try std.fmt.allocPrint(s.arena, "a collection literal cannot make a `{s}`: its companion declares no `operator fun of`", .{try sema_mod.diagnose.typeText(s, s.arena, expected)}),
            }, "collection literal of {s}", .{try sema_mod.render.typeStr(s, s.arena, expected)});
            return s.types.errType();
        },
        .function => |f| {
            const id = ast.Ident{ .name = f.name, .span = at };
            const pn = s.names.lookup(f.pkg) orelse return missingLiteralFunction(ctx, args, id);
            const pkg = s.syms.package_by_fqn.get(pn) orelse return missingLiteralFunction(ctx, args, id);
            return packageCall(ctx, pkg, id, args, false, &.{}, expected);
        },
        .of => |comp| {
            const id = ast.Ident{ .name = "of", .span = at };
            const n = try ctx.intern("of");
            const ct = try headers.selfType(s, comp);
            const recv: Receiver = .{ .implicit = .{ .kind = .object, .owner = comp } };
            var levels: std.ArrayList(Level) = .empty;
            var member_level = newLevel();
            for (try members.lookup(s, ct, n, .function)) |m| {
                if (!try members.isOperator(s, m.sym)) continue;
                try headers.functionHeader(s, m.sym);
                if (s.syms.functionInfo(m.sym).receiver != .none) continue;
                try member_level.append(s.arena, .{ .sym = m.sym, .subst = m.subst, .dispatch = recv });
            }
            if (member_level.items.len != 0) try levels.append(s.arena, member_level);
            try appendExtensionLevels(ctx, &levels, n, recv, ct, true);
            return resolveLevels(ctx, levels.items, id, args, false, &.{}, expected);
        },
    }
}

fn missingLiteralFunction(ctx: *Ctx, args: []const Arg, id: ast.Ident) Allocator.Error!TypeId {
    try finishArgsBlind(ctx, args);
    try ctx.report(.unresolved_call, id.span, "{s}", .{id.name});
    return ctx.s.types.errType();
}

/// How a class's constructors are reached: the outer instance of an inner
/// class, the substitution its type arguments give, and a type alias.
const CtorVia = struct {
    dispatch: Receiver = .none,
    subst: *const types.Subst = &empty_subst,
    result: TypeId = .none,
    alias: Sym = .none,
};

/// The constructors of `cls`. An inner class's, called without an outer
/// instance (`dispatch` none), take the innermost implicit receiver of its
/// outer class; one on an explicit instance takes `outer_ty`'s arguments.
fn appendCtors(ctx: *Ctx, level: *Level, cls: Sym, dispatch: Receiver) Allocator.Error!void {
    return appendCtorsVia(ctx, level, cls, .{ .dispatch = dispatch }, .none);
}

/// The constructors of `cls` a call here can name: a private or protected
/// one only inside the class (a protected one also in a subclass). A
/// sealed class's constructors are not callable outside it, so `Period()`
/// is the function named like it.
fn appendCallableCtors(ctx: *Ctx, level: *Level, cls: Sym, dispatch: Receiver) Allocator.Error!void {
    const start = level.items.len;
    try appendCtors(ctx, level, cls, dispatch);
    var kept = start;
    for (level.items[start..]) |c| {
        if (!try ctorVisible(ctx, c.sym)) continue;
        level.items[kept] = c;
        kept += 1;
    }
    level.shrinkRetainingCapacity(kept);
}

fn ctorVisible(ctx: *Ctx, ctor: Sym) Allocator.Error!bool {
    const s = ctx.s;
    if (s.syms.kind(ctor) != .constructor) return true;
    const vis = s.syms.flags(ctor).visibility;
    if (vis != .private and vis != .protected) return true;
    const cls = s.syms.owner(ctor);
    var sc: ?*body.Scope = ctx.scope;
    while (sc) |c| : (sc = c.parent) {
        if (c.kind != .class or c.owner == .none) continue;
        if (c.owner == cls) return true;
        if (vis == .protected and (try subtyping.supertypeWithClass(s, try headers.selfType(s, c.owner), cls)) != null) return true;
    }
    return false;
}

fn appendCtorsVia(ctx: *Ctx, level: *Level, cls: Sym, via_in: CtorVia, outer_ty: TypeId) Allocator.Error!void {
    const s = ctx.s;
    const info = s.syms.classInfo(cls);
    // A fun interface's name called with a lambda is its SAM constructor;
    // through a type alias, the alias's parameters are what it infers.
    if (info.kind == .interface and s.syms.flags(cls).fun_iface) {
        const ctor = try samConstructor(ctx, cls);
        if (ctor != .none) try level.append(s.arena, .{ .sym = ctor, .subst = via_in.subst, .form = .sam_ctor, .ctor_result = via_in.result, .alias = via_in.alias });
        return;
    }
    if (info.kind == .interface or info.kind == .object or info.kind == .companion) return;
    var via = via_in;
    var outer_arg: TypeId = .none;
    var outer_want: TypeId = .none;
    if (s.syms.flags(cls).inner) {
        const outer = s.syms.owner(cls);
        var ot = outer_ty;
        if (via.dispatch == .none) {
            for (try body.implicitReceivers(ctx)) |r| {
                const rt = try body.narrowedReceiver(ctx, r);
                if (try subtyping.supertypeWithClass(s, rt, outer) == null) continue;
                via.dispatch = .{ .implicit = .{ .kind = r.kind, .owner = r.owner } };
                ot = rt;
                break;
            }
        }
        if (ot != .none) {
            if (try subtyping.supertypeWithClass(s, ot, outer)) |st| {
                if (via.alias != .none) {
                    outer_arg = st;
                    outer_want = try s.types.substitute(try headers.selfType(s, outer), via.subst);
                }
                const sub = try s.arena.create(types.Subst);
                sub.* = try subtyping.classSubst(s, st);
                var it = via.subst.iterator();
                while (it.next()) |e| try sub.put(s.arena, e.key_ptr.*, e.value_ptr.*);
                via.subst = sub;
            }
        }
    }
    for (symbols.Symbols.members(&info.members, wk.init)) |ctor| {
        if (s.syms.kind(ctor) != .constructor) continue;
        try level.append(s.arena, .{ .sym = ctor, .subst = via.subst, .dispatch = via.dispatch, .ctor_result = via.result, .alias = via.alias, .outer_arg = outer_arg, .outer_want = outer_want });
    }
}

/// The constructors of the class a type alias expands to. The alias's
/// type parameters are the ones a call infers; the class's take the
/// expansion's arguments.
fn appendAliasCtors(ctx: *Ctx, level: *Level, alias: Sym) Allocator.Error!void {
    return appendAliasCtorsOn(ctx, level, alias, .none, .none);
}

fn appendAliasCtorsOn(ctx: *Ctx, level: *Level, alias: Sym, dispatch: Receiver, outer_ty: TypeId) Allocator.Error!void {
    const s = ctx.s;
    const target = try s.types.makeNotNull(try headers.aliasTarget(s, alias));
    const cls = s.types.classSym(target);
    if (cls == .none or s.syms.kind(cls) != .class) return;
    const sub = try s.arena.create(types.Subst);
    sub.* = try subtyping.classSubst(s, target);
    try appendCtorsVia(ctx, level, cls, .{ .dispatch = dispatch, .subst = sub, .result = target, .alias = alias }, outer_ty);
}

/// `invoke` on the value a classifier or enum entry denotes: an object, a
/// class's companion, an enum entry.
fn appendValueInvokes(ctx: *Ctx, level: *Level, sym: Sym) Allocator.Error!void {
    const s = ctx.s;
    const holder: Sym, const vt: TypeId = switch (s.syms.kind(sym)) {
        .enum_entry => .{ sym, try headers.selfType(s, s.syms.entryInfo(sym).enum_class) },
        .class => blk: {
            const info = s.syms.classInfo(sym);
            if (info.kind == .object or info.kind == .companion) break :blk .{ sym, try headers.selfType(s, sym) };
            if (info.companion == .none) return;
            break :blk .{ info.companion, try headers.selfType(s, info.companion) };
        },
        else => return,
    };
    try appendInvokes(ctx, level, vt, holder, .none);
}

/// `invoke` candidates for a value of type `vt` held by `via`.
fn appendInvokes(ctx: *Ctx, level: *Level, vt: TypeId, via: Sym, via_dispatch: Receiver) Allocator.Error!void {
    return appendInvokesVia(ctx, level, vt, via, via_dispatch, .none);
}

fn appendInvokesVia(ctx: *Ctx, level: *Level, vt: TypeId, via: Sym, via_dispatch: Receiver, via_extension: Receiver) Allocator.Error!void {
    const s = ctx.s;
    if (s.types.isErr(vt)) return;
    const k = contextCount(s, vt);
    const comp = try composableFunctionType(s, vt);
    for (try members.lookup(s, vt, wk.invoke, .function)) |m| {
        if (!try members.isOperator(s, m.sym)) continue;
        try level.append(s.arena, .{ .sym = m.sym, .subst = m.subst, .dispatch = .expr, .via = via, .via_dispatch = via_dispatch, .via_extension = via_extension, .on_value = true, .composable_value = comp });
        // A contextual function value is also invoked with its contexts
        // taken from the scope.
        if (k != 0) try level.append(s.arena, .{ .sym = m.sym, .subst = m.subst, .dispatch = .expr, .via = via, .via_dispatch = via_dispatch, .via_extension = via_extension, .ctx_scope = k, .on_value = true, .composable_value = comp });
    }
    for (try extensionFunctions(ctx, wk.invoke)) |x| {
        if (!try members.isOperator(s, x.sym)) continue;
        try level.append(s.arena, .{ .sym = x.sym, .subst = x.subst, .dispatch = x.dispatch, .extension = .expr, .ext_ty = vt, .via = via, .via_dispatch = via_dispatch, .via_extension = via_extension, .on_value = true });
    }
}

/// `recv.p(args)` for an extension property `p` of `recv`'s type whose
/// value is invoked: `Color.VectorConverter(colorSpace)`.
fn appendExtPropInvokeLevel(ctx: *Ctx, levels: *std.ArrayList(Level), n: Name, rt: TypeId, recv_src: Receiver) Allocator.Error!void {
    const s = ctx.s;
    const ep = (try extensionProperty(ctx, rt, n)) orelse return;
    var level = newLevel();
    try appendInvokesVia(ctx, &level, ep.ty, ep.sym, ep.dispatch, recv_src);
    if (level.items.len != 0) try levels.append(s.arena, level);
}

/// `invoke` on a value of extension-function type `R.(A) -> B` with the
/// receiver supplied by `recv_ty` (the call's receiver, or an implicit one)
/// as the first argument.
fn appendReceiverInvokes(ctx: *Ctx, level: *Level, vt: TypeId, via: Sym, via_dispatch: Receiver, recv_ty: TypeId, recv_src: Receiver) Allocator.Error!void {
    const s = ctx.s;
    if (s.types.isErr(vt)) return;
    const nn = try s.types.makeNotNull(vt);
    const shape = functionShape(s, nn) orelse return;
    if (!shape.has_receiver) return;
    const comp = try composableFunctionType(s, nn);
    for (try members.lookup(s, nn, wk.invoke, .function)) |m| {
        try level.append(s.arena, .{ .sym = m.sym, .subst = m.subst, .dispatch = .expr, .via = via, .via_dispatch = via_dispatch, .recv_arg_ty = recv_ty, .recv_arg_src = recv_src, .ctx_scope = @intCast(shape.contexts), .on_value = true, .composable_value = comp });
    }
}

/// Values named `n` in scope that could be invoked with a receiver: locals,
/// then implicit receivers' properties, then top-level properties.
fn receiverInvokeLevel(ctx: *Ctx, n: Name, recv_ty: TypeId, recv_src: Receiver) Allocator.Error!Level {
    const s = ctx.s;
    var level = newLevel();
    if (body.lookupLocal(ctx, n)) |loc| {
        const k = s.syms.kind(loc);
        if (k == .local or k == .value_param) {
            const vt = try body.narrowedType(ctx, loc, try body.symbolType(ctx, loc));
            try appendReceiverInvokes(ctx, &level, vt, loc, .none, recv_ty, recv_src);
        }
    }
    if (level.items.len != 0) return level;
    for (try body.implicitReceivers(ctx)) |r| {
        for (try members.lookup(s, try body.narrowedReceiver(ctx, r), n, .property)) |m| {
            if (s.syms.kind(m.sym) != .property) continue;
            try appendReceiverInvokes(ctx, &level, try members.memberType(s, m), m.sym, .{ .implicit = .{ .kind = r.kind, .owner = r.owner } }, recv_ty, recv_src);
        }
        if (level.items.len != 0) return level;
    }
    if (try topLevelProperty(ctx, n)) |p| {
        try appendReceiverInvokes(ctx, &level, try headers.propertyType(s, p), p, .none, recv_ty, recv_src);
    }
    return level;
}

/// `value(args)` on an expression's value.
fn invokeValue(ctx: *Ctx, vt: TypeId, anchor: Span, via: Sym, via_dispatch: Receiver, _: Receiver, args: []Arg, trailing: bool, expected: TypeId) Allocator.Error!TypeId {
    const s = ctx.s;
    var levels: std.ArrayList(Level) = .empty;
    var level = newLevel();
    try appendInvokes(ctx, &level, vt, via, via_dispatch);
    if (level.items.len != 0) try levels.append(s.arena, level);
    // A value of extension-function type takes an implicit receiver as its
    // receiver, innermost first: `block!!()` inside `scope.apply { }`.
    for (try body.implicitReceivers(ctx)) |r| {
        var rl = newLevel();
        try appendReceiverInvokes(ctx, &rl, vt, via, via_dispatch, try body.narrowedReceiver(ctx, r), .{ .implicit = .{ .kind = r.kind, .owner = r.owner } });
        if (rl.items.len != 0) try levels.append(s.arena, rl);
    }
    const id = ast.Ident{ .name = "invoke", .span = anchor };
    if (levels.items.len == 0) {
        try finishArgsBlind(ctx, args);
        try ctx.reportFacts(.unresolved_call, anchor, .{
            .message = try std.fmt.allocPrint(s.arena, "a value of type `{s}` cannot be called: it has no `operator fun invoke` that accepts these arguments", .{try sema_mod.diagnose.typeText(s, s.arena, vt)}),
        }, "invoke on {s}", .{try sema_mod.render.typeStr(s, s.arena, vt)});
        return s.types.errType();
    }
    return resolveLevels(ctx, levels.items, id, args, trailing, &.{}, expected);
}

const ExtCand = struct {
    sym: Sym,
    subst: *const types.Subst,
    dispatch: Receiver,
    /// Precedence: a lower tier is tried first, and candidates of one
    /// tier compete with each other only.
    tier: u16,
};

/// Every extension function named `n` in scope, in precedence order: local
/// extensions by scope, member extensions of each implicit receiver
/// (innermost first), then top-level extensions by import precedence.
fn extensionFunctions(ctx: *Ctx, n: Name) Allocator.Error![]const ExtCand {
    const s = ctx.s;
    var out: std.ArrayList(ExtCand) = .empty;
    var tier: u16 = 0;
    var sc: ?*body.Scope = ctx.scope;
    var hide = false;
    while (sc) |c| : (sc = c.parent) {
        var any = false;
        var i: usize = if (body.localsVisible(c, &hide)) c.locals.items.len else 0;
        while (i > 0) {
            i -= 1;
            const l = c.locals.items[i];
            if (l.name != n or s.syms.kind(l.sym) != .function) continue;
            try headers.functionHeader(s, l.sym);
            if (s.syms.functionInfo(l.sym).receiver == .none) continue;
            try out.append(s.arena, .{ .sym = l.sym, .subst = &empty_subst, .dispatch = .none, .tier = tier });
            any = true;
        }
        if (any) tier += 1;
    }
    // A smart cast receiver offers the member extensions of what it was
    // cast to (`is Bob -> bar()` for a `fun Bob.bar()` Bob declares).
    for (try body.implicitReceivers(ctx)) |r| {
        var any = false;
        for (try members.lookup(s, try body.narrowedReceiver(ctx, r), n, .function)) |m| {
            try headers.functionHeader(s, m.sym);
            if (s.syms.functionInfo(m.sym).receiver == .none) continue;
            try out.append(s.arena, .{ .sym = m.sym, .subst = m.subst, .dispatch = .{ .implicit = .{ .kind = r.kind, .owner = r.owner } }, .tier = tier });
            any = true;
        }
        if (any) tier += 1;
    }
    // A package can be both the file's own and a default import; each
    // declaration is a candidate once, at its first tier.
    var seen: std.AutoHashMapUnmanaged(Sym, void) = .empty;
    for (out.items) |x| try seen.put(s.arena, x.sym, {});
    for (try topLevelTiers(ctx, n)) |top| {
        var any = false;
        for (top) |m| {
            if (s.syms.kind(m) != .function) continue;
            if ((try seen.getOrPut(s.arena, m)).found_existing) continue;
            try headers.functionHeader(s, m);
            if (s.syms.functionInfo(m).receiver == .none) continue;
            try out.append(s.arena, .{ .sym = m, .subst = importedSubst(ctx, m), .dispatch = importedOwner(ctx, m), .tier = tier });
            any = true;
        }
        if (any) tier += 1;
    }
    return out.items;
}

/// Extension candidates for a receiver of type `rt`, one level per tier.
fn appendExtensionLevels(ctx: *Ctx, levels: *std.ArrayList(Level), n: Name, recv_src: Receiver, rt: TypeId, operator_only: bool) Allocator.Error!void {
    const s = ctx.s;
    var cur: Level = newLevel();
    var cur_tier: u16 = 0;
    for (try extensionFunctions(ctx, n)) |x| {
        if (operator_only and !try members.isOperator(s, x.sym)) continue;
        if (x.tier != cur_tier and cur.items.len != 0) {
            try levels.append(s.arena, cur);
            cur = newLevel();
        }
        cur_tier = x.tier;
        try cur.append(s.arena, .{ .sym = x.sym, .subst = x.subst, .dispatch = x.dispatch, .extension = recv_src, .ext_ty = rt });
    }
    if (cur.items.len != 0) try levels.append(s.arena, cur);
}

/// Top-level declarations named `n`, one slice per precedence tier:
/// explicit imports, the file's package, star imports, default imports.
/// A member imported by name from an object (`import Obj.f`) is called or
/// read on that object, which may inherit it; a top-level declaration has
/// no dispatch receiver.
pub fn importedOwner(ctx: *Ctx, m: Sym) Receiver {
    const s = ctx.s;
    if (objectImport(ctx, m)) |oi| return .{ .implicit = .{ .kind = .object, .owner = oi.object } };
    const owner = s.syms.owner(m);
    if (owner == .none or s.syms.kind(owner) != .class) return .none;
    return .{ .implicit = .{ .kind = .object, .owner = owner } };
}

/// The type arguments a member imported from an object takes from the
/// object's supertypes (`genericFromSuper(g: G)` of an `object C :
/// I<String>` takes a `String`).
pub fn importedSubst(ctx: *Ctx, m: Sym) *const types.Subst {
    if (objectImport(ctx, m)) |oi| return oi.subst;
    return &empty_subst;
}

fn objectImport(ctx: *Ctx, m: Sym) ?scope_mod.ObjectImport {
    const fc = ctx.s.fileOf(ctx.file) orelse return null;
    const fi = fc.imports orelse return null;
    return fi.object_members.get(m);
}

pub fn topLevelTiers(ctx: *Ctx, n: Name) Allocator.Error![]const []const Sym {
    const s = ctx.s;
    var tiers: std.ArrayList([]const Sym) = .empty;
    const fi = try scope_mod.fileImports(s, ctx.file);
    if (fi.explicit.getPtr(n)) |targets| {
        var list: std.ArrayList(Sym) = .empty;
        for (targets.items) |*t| {
            const on_object = try scope_mod.objectMembers(s, fi, t);
            if (on_object) |ms| try list.appendSlice(s.arena, ms);
            for (scope_mod.membersOf(s, t.container, t.member)) |m| {
                if (!scope_mod.visible(s, m)) continue;
                // An object's functions and properties came from the lookup.
                if (on_object != null and (s.syms.kind(m) == .function or s.syms.kind(m) == .property)) continue;
                try list.append(s.arena, m);
            }
        }
        try tiers.append(s.arena, list.items);
    }
    const fc = s.files.items[ctx.file];
    try tiers.append(s.arena, try visibleMembers(ctx, fc.package, n));
    {
        var list: std.ArrayList(Sym) = .empty;
        for (fi.star.items) |c| try list.appendSlice(s.arena, try visibleMembers(ctx, c, n));
        try tiers.append(s.arena, list.items);
    }
    for (try scope_mod.defaultPackages(s)) |level| {
        var list: std.ArrayList(Sym) = .empty;
        for (level) |p| try list.appendSlice(s.arena, try visibleMembers(ctx, p, n));
        try tiers.append(s.arena, list.items);
    }
    return tiers.items;
}

/// Members of a package visible from the current file: a `private`
/// top-level declaration is visible only in its own file.
fn visibleMembers(ctx: *Ctx, container: Sym, n: Name) Allocator.Error![]const Sym {
    const s = ctx.s;
    var out: std.ArrayList(Sym) = .empty;
    for (scope_mod.membersOf(s, container, n)) |m| {
        if (!scope_mod.visible(s, m)) continue;
        const sym = s.syms.get(m);
        if (sym.flags.visibility == .private and s.syms.kind(container) == .package and sym.file != ctx.file) continue;
        try out.append(s.arena, m);
    }
    return out.items;
}

// ----------------------------------------------------------- selection ----

/// `KLIO_SEMA_TRACE=<name>` prints every candidate a call named `<name>`
/// considers and why each is rejected.
fn traceName() ?[]const u8 {
    const v = std.c.getenv("KLIO_SEMA_TRACE") orelse return null;
    return std.mem.span(v);
}

var trace_active: bool = false;

fn traceReject(ctx: *Ctx, cand: Cand, comptime why: []const u8, args: anytype) void {
    if (!trace_active) return;
    const s = ctx.s;
    const id = sema_mod.render.callableId(s, s.arena, cand.sym) catch "?";
    std.debug.print("[sema-trace]   reject {s}: " ++ why ++ "\n", .{id} ++ args);
}

fn resolveLevels(ctx: *Ctx, levels: []const Level, id: ast.Ident, args: []Arg, trailing: bool, type_args: []const TypeId, expected_in: TypeId) Allocator.Error!TypeId {
    const s = ctx.s;
    const expected = try infer.usableExpected(s, expected_in);
    // What the candidates' results are constrained by: an expected type
    // still naming an enclosing call's open variables (a lambda's result
    // `ReadOnlyProperty<Owner, V>` while `V` waits for it) constrains the
    // positions that do not.
    const soft_expected = if (expected != .none or expected_in == .none) expected else try infer.zonk(s, expected_in);
    var any_candidate = false;
    const saved_trace = trace_active;
    defer trace_active = saved_trace;
    trace_active = if (traceName()) |t| std.mem.eql(u8, t, id.name) else false;
    if (trace_active) {
        const loc = ctx.s.files.items[ctx.file].path;
        std.debug.print("[sema-trace] {s} at {s}+{d} args=({s}) expected={s}\n", .{ id.name, loc, id.span.start, try argTypesText(ctx, args), if (expected != .none) try sema_mod.render.typeStr(s, s.arena, expected) else "-" });
    }
    // The first level whose applicable candidates are all low priority:
    // taken only when no later level has a candidate that is not.
    var low_level: ?[]Applied = null;
    // The first level whose applicable candidates the call cannot see.
    var hidden_level: ?[]Applied = null;
    for (levels, 0..) |level, li| {
        var applicable: std.ArrayList(Applied) = .empty;
        for (level.items) |cand| {
            any_candidate = true;
            if (trace_active) {
                const cid = try sema_mod.render.callableId(s, s.arena, cand.sym);
                const rt = if (cand.ext_ty != .none) try sema_mod.render.typeStr(s, s.arena, cand.ext_ty) else "-";
                std.debug.print("[sema-trace]  level {d} cand {s} ext_recv={s}\n", .{ li, cid, rt });
            }
            if (try check(ctx, cand, args, trailing, type_args, soft_expected)) |ap| try applicable.append(s.arena, ap);
        }
        if (applicable.items.len == 0) continue;
        // Candidates the call cannot see yield to a later level's: a
        // superclass's private member extension does not shadow the
        // library's extension of that name.
        if (try dropInvisible(ctx, &applicable)) {
            if (hidden_level == null) hidden_level = applicable.items;
            continue;
        }
        try dropLowPriority(ctx, &applicable);
        if (try onlyLowPriority(ctx, applicable.items)) {
            if (low_level == null) low_level = applicable.items;
            continue;
        }
        return chooseAndComplete(ctx, applicable.items, args, trailing, id, expected);
    }
    if (low_level) |apps| return chooseAndComplete(ctx, apps, args, trailing, id, expected);
    // Only candidates the call cannot see apply: it names one of them, and
    // cannot access it.
    if (hidden_level) |apps| {
        const m = apps[0].cand.sym;
        try ctx.reportFacts(.invisible, id.span, .{ .name = id.name, .syms = try ctx.arena().dupe(Sym, &.{m}) }, "{s}", .{id.name});
        return chooseAndComplete(ctx, apps, args, trailing, id, expected);
    }
    try finishArgsBlind(ctx, args);
    if (any_candidate) {
        try ctx.reportFacts(.no_applicable, id.span, .{ .name = id.name, .arg_types = try argTypes(ctx, args), .syms = try levelSyms(ctx, levels) }, "{s}({s})", .{ id.name, try argTypesText(ctx, args) });
    } else {
        try ctx.report(.unresolved_call, id.span, "{s}", .{id.name});
    }
    return s.types.errType();
}

/// The most specific of a level's applicable candidates, completed.
fn chooseAndComplete(ctx: *Ctx, applicable: []Applied, args: []Arg, trailing: bool, id: ast.Ident, expected: TypeId) Allocator.Error!TypeId {
    if (applicable.len > 1) {
        if (try byLambdaReturn(ctx, applicable)) |idx| {
            return complete(ctx, applicable[idx], args, trailing, id, expected);
        }
    }
    const chosen = try mostSpecific(ctx, applicable, args);
    if (chosen.ambiguous) {
        const cands = try ctx.arena().alloc(Sym, applicable.len);
        for (applicable, cands) |ap, *c| c.* = ap.cand.sym;
        try ctx.reportFacts(.ambiguous, id.span, .{ .name = id.name, .syms = cands }, "{s}: {d} candidates", .{ id.name, applicable.len });
    }
    return complete(ctx, applicable[chosen.index], args, trailing, id, expected);
}

fn argTypesText(ctx: *Ctx, args: []const Arg) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (args, 0..) |a, i| {
        if (i != 0) try buf.appendSlice(ctx.arena(), ", ");
        if (a.postponed) {
            try buf.appendSlice(ctx.arena(), "{...}");
        } else {
            try buf.appendSlice(ctx.arena(), try sema_mod.render.typeStr(ctx.s, ctx.arena(), a.ty));
        }
    }
    return buf.items;
}

/// The arguments' types for a diagnostic: `.none` for one postponed.
fn argTypes(ctx: *Ctx, args: []const Arg) Allocator.Error![]const TypeId {
    const out = try ctx.arena().alloc(TypeId, args.len);
    for (args, out) |a, *o| o.* = if (a.postponed) .none else try infer.zonk(ctx.s, a.ty);
    return out;
}

/// Every candidate of `levels`, once each, for a diagnostic.
fn levelSyms(ctx: *Ctx, levels: []const Level) Allocator.Error![]const Sym {
    var out: std.ArrayList(Sym) = .empty;
    for (levels) |level| for (level.items) |c| {
        if (std.mem.indexOfScalar(Sym, out.items, c.sym) == null) try out.append(ctx.arena(), c.sym);
    };
    return out.items;
}

/// Resolves postponed arguments with no expected type, so a call that
/// resolves to nothing still resolves what is inside its lambdas.
fn finishArgsBlind(ctx: *Ctx, args: []const Arg) Allocator.Error!void {
    for (args) |a| {
        if (!a.postponed) continue;
        var inner = a.expr;
        if (inner.* == .Spread) inner = inner.Spread.expr;
        _ = try body.expr(ctx, inner, .none);
    }
}

/// The parameters a candidate's arguments map to: a function's value
/// parameters, less the contexts an `invoke` takes from the scope.
fn candParams(s: *Sema, cand: Cand) []const Sym {
    return s.syms.functionInfo(cand.sym).params[cand.ctx_scope..];
}

/// Type parameters inferred at a call: the function's own, plus the class's
/// for a constructor.
fn candTypeParams(s: *Sema, cand: Cand) Allocator.Error![]const Sym {
    if (cand.alias != .none) return s.syms.aliasInfo(cand.alias).type_params;
    const sym = cand.sym;
    const own = s.syms.functionInfo(sym).type_params;
    if (s.syms.kind(sym) != .constructor) return own;
    const cls_tps = s.syms.classInfo(s.syms.owner(sym)).type_params;
    if (own.len == 0) return cls_tps;
    const out = try s.arena.alloc(Sym, cls_tps.len + own.len);
    @memcpy(out[0..cls_tps.len], cls_tps);
    @memcpy(out[cls_tps.len..], own);
    return out;
}

/// Maps arguments to parameters and checks each against its parameter type
/// with inference. Null when the candidate does not apply.
fn check(ctx: *Ctx, cand: Cand, call_args: []const Arg, trailing: bool, type_args: []const TypeId, expected: TypeId) Allocator.Error!?Applied {
    const s = ctx.s;
    if (s.syms.flags(cand.sym).hidden) {
        traceReject(ctx, cand, "hidden by @Deprecated(level = HIDDEN)", .{});
        return null;
    }
    try headers.functionHeader(s, cand.sym);
    const params = candParams(s, cand);
    const args: []Arg = if (cand.recv_arg_ty != .none) blk: {
        const out = try s.arena.alloc(Arg, call_args.len + 1);
        const placeholder = try s.arena.create(Expr);
        placeholder.* = .{ .NullLit = .{ .span = if (call_args.len != 0) call_args[0].expr.span() else span.Span.init(span.FileId.from(0), 0, 0) } };
        out[0] = .{ .expr = placeholder, .ty = cand.recv_arg_ty };
        @memcpy(out[1..], call_args);
        break :blk out;
    } else try s.arena.dupe(Arg, call_args);
    const slots = (try mapArgs(ctx, cand.sym, cand.defaults, params, args, trailing)) orelse {
        traceReject(ctx, cand, "arguments do not map to {d} parameters", .{params.len});
        return null;
    };
    var sys = infer.System.init(s);
    const tps = try candTypeParams(s, cand);
    try sys.addTypeParams(tps);
    if (!try sys.addDeclaredBounds(tps, cand.subst)) {
        traceReject(ctx, cand, "declared bounds conflict", .{});
        return null;
    }
    // The type arguments written, which a lambda is checked against as
    // they are: `DIContext<C>(t) { ... }` does not pass the lambda for a
    // parameter of type `C`.
    var written: types.Subst = .empty;
    if (type_args.len != 0) {
        const own = s.syms.functionInfo(cand.sym).type_params;
        const pinned = if (s.syms.kind(cand.sym) == .constructor) tps else own;
        if (type_args.len != pinned.len) {
            traceReject(ctx, cand, "{d} type arguments for {d} parameters", .{ type_args.len, pinned.len });
            return null;
        }
        for (pinned, type_args) |tp, ta| {
            if (ta == .none) continue;
            try written.put(s.arena, tp, ta);
            const v = try sys.open(try s.types.param(tp, false));
            if (!try sys.constrain(ta, v) or !try sys.constrain(v, ta)) {
                traceReject(ctx, cand, "type argument conflicts", .{});
                return null;
            }
        }
    }
    // The extension receiver.
    const info = s.syms.functionInfo(cand.sym);
    if (cand.extension != .none) {
        if (info.receiver == .none) return null;
        const want = try sys.open(try s.types.substitute(info.receiver, cand.subst));
        if (!try sys.constrain(cand.ext_ty, want)) {
            if (trace_active) traceReject(ctx, cand, "receiver {s} does not fit {s}", .{ try sema_mod.render.typeStr(s, s.arena, cand.ext_ty), try sema_mod.render.typeStr(s, s.arena, want) });
            return null;
        }
    }
    if (cand.outer_want != .none) {
        if (!try sys.constrain(cand.outer_arg, try sys.open(cand.outer_want))) {
            traceReject(ctx, cand, "the outer instance does not fit", .{});
            return null;
        }
    }
    var uses_vararg = false;
    const conv = try s.arena.alloc(records.Conv, args.len);
    @memset(conv, .none);
    for (args, slots, 0..) |a, slot, ai| {
        const p = params[slot.param];
        var pt = try s.types.substitute(try headers.paramType(s, p), cand.subst);
        if (s.syms.flags(p).vararg) {
            if (slot.vararg_elem) {
                uses_vararg = true;
            } else if (a.spread or slot.named_array) {
                pt = try varargArrayType(ctx, pt);
            }
        }
        const opened = try sys.open(pt);
        if (a.postponed) {
            const shaped = if (written.count() != 0) try sys.open(try s.types.substitute(pt, &written)) else opened;
            if (!try postponedFits(ctx, a, shaped)) {
                if (trace_active) traceReject(ctx, cand, "lambda does not fit {s}", .{try sema_mod.render.typeStr(s, s.arena, opened)});
                return null;
            }
            // A deferred call is at most what the functions it names
            // return: `compareBy { ... }` is a `Comparator`, which the
            // `Comparable` parameters of `maxOf(a, b, c)` do not take.
            if (a.deferred) if (try deferredResultClass(ctx, a.expr)) |at| {
                if (!try classCanFit(ctx, &sys, at, opened)) {
                    if (trace_active) traceReject(ctx, cand, "a {s} does not fit {s}", .{ try sema_mod.render.typeStr(s, s.arena, at), try sema_mod.render.typeStr(s, s.arena, opened) });
                    return null;
                }
            };
            continue;
        }
        var trial_arg = try sys.clone();
        if (try trial_arg.constrain(a.ty, opened)) {
            _ = try sys.constrain(a.ty, opened);
            continue;
        }
        if (try convertedArg(ctx, &sys, a.ty, opened)) |cv| {
            conv[ai] = cv;
            continue;
        }
        if (trace_active) traceReject(ctx, cand, "argument {s} does not fit {s}", .{ try sema_mod.render.typeStr(s, s.arena, a.ty), try sema_mod.render.typeStr(s, s.arena, opened) });
        return null;
    }
    var uses_default: u16 = 0;
    for (params, 0..) |p, pi| {
        var mapped = false;
        var spread = false;
        for (slots, args) |sl, a| if (sl.param == pi) {
            mapped = true;
            if (a.spread) spread = true;
        };
        if (!mapped and !s.syms.flags(p).vararg) uses_default += 1;
        // A vararg call, even with no elements, is less specific than a
        // candidate without one.
        if (s.syms.flags(p).vararg and !spread) uses_vararg = true;
    }
    // Context arguments come from the scope: the contexts of a contextual
    // `invoke`, and the callee's own context parameters.
    var contexts: std.ArrayList(Receiver) = .empty;
    const scope_ctx = s.syms.functionInfo(cand.sym).params[0..cand.ctx_scope];
    for ([_][]const Sym{ scope_ctx, info.context_params }) |ps| for (ps) |p| {
        const want = try sys.open(try s.types.substitute(try headers.paramType(s, p), cand.subst));
        const r = (try contextArgument(ctx, &sys, want)) orelse {
            if (trace_active) traceReject(ctx, cand, "no context argument for {s}", .{try sema_mod.render.typeStr(s, s.arena, want)});
            return null;
        };
        try contexts.append(s.arena, r);
    };
    // The expected type constrains the result softly: a candidate that
    // cannot meet it is still applicable, as the result may be converted.
    const known_expected: TypeId = if (expected != .none and !s.types.isErr(expected)) try sys.knownPart(expected) else .none;
    // One it would leave no type arguments for, as `Unit` expected of
    // `assertFailsWith`'s `T : Throwable`, is dropped.
    if (known_expected != .none) {
        const ret = try candReturn(ctx, cand, &sys);
        var trial = try sys.clone();
        if (try trial.constrain(ret, known_expected) and try trial.solve(true)) {
            _ = try sys.constrain(ret, known_expected);
        }
    }
    // A variable nothing constrains is left open here: whether it can be
    // fixed is the enclosing call's or the expected type's question.
    var trial = try sys.clone();
    if (!try trial.solve(true)) {
        traceReject(ctx, cand, "no type arguments satisfy the bounds", .{});
        return null;
    }
    return .{ .cand = cand, .sys = sys, .args = args, .slots = slots, .uses_default = uses_default, .uses_vararg = uses_vararg, .generic = tps.len != 0, .contexts = contexts.items, .conv = conv };
}

/// The implicit value a context parameter of type `want` takes: in the
/// innermost scope that has one, the receiver or context value whose type
/// fits. Two that fit in one scope are ambiguous, and the call does not
/// apply.
fn contextArgument(ctx: *Ctx, sys: *infer.System, want: TypeId) Allocator.Error!?Receiver {
    const s = ctx.s;
    var sc: ?*body.Scope = ctx.scope;
    while (sc) |c| : (sc = c.parent) {
        var found: ?Receiver = null;
        var found_ty: TypeId = .none;
        var n: usize = 0;
        for (c.contexts.items) |cv| {
            // A named context parameter smart cast by a check on it passes
            // as its narrowed type (`if (ctx is String) bar()` for a
            // `context(s: String) fun bar()`).
            const ct = try body.narrowedType(ctx, cv.sym, cv.ty);
            var trial = try sys.clone();
            if (!try trial.constrain(ct, want)) continue;
            n += 1;
            found = .{ .implicit = .{ .kind = .context, .owner = cv.sym } };
            found_ty = ct;
        }
        for (c.receivers.items) |r| {
            const rt = try body.narrowedReceiver(ctx, r);
            var trial = try sys.clone();
            if (!try trial.constrain(rt, want)) continue;
            n += 1;
            found = .{ .implicit = .{ .kind = r.kind, .owner = r.owner } };
            found_ty = rt;
        }
        if (n > 1) return null;
        if (found) |f| {
            _ = try sys.constrain(found_ty, want);
            return f;
        }
    }
    _ = s;
    return null;
}

fn candReturn(ctx: *Ctx, cand: Cand, sys: *infer.System) Allocator.Error!TypeId {
    const s = ctx.s;
    if (cand.ctor_result != .none) return sys.open(cand.ctor_result);
    const ret = if (s.syms.kind(cand.sym) == .constructor)
        try headers.selfType(s, s.syms.owner(cand.sym))
    else
        try headers.returnType(s, cand.sym);
    return sys.open(try s.types.substitute(ret, cand.subst));
}

/// Positional arguments in order, named ones by name, extra positional
/// arguments into a vararg, a trailing lambda to the last parameter. Every
/// parameter left over needs a default or is a vararg.
/// `defaults`: the function whose default values `fsym` takes where it
/// declares none (`Cand.defaults`).
fn mapArgs(ctx: *Ctx, fsym: Sym, defaults: Sym, params: []const Sym, args: []const Arg, trailing: bool) Allocator.Error!?[]Slot {
    const s = ctx.s;
    const slots = try s.arena.alloc(Slot, args.len);
    const filled = try s.arena.alloc(bool, params.len);
    @memset(filled, false);
    var pos: usize = 0;
    for (args, 0..) |a, i| {
        if (trailing and i + 1 == args.len and a.name == null) {
            if (params.len == 0) return null;
            const last: u16 = @intCast(params.len - 1);
            if (filled[last] and !s.syms.flags(params[last]).vararg) return null;
            slots[i] = .{ .param = last };
            filled[last] = true;
            continue;
        }
        if (a.name) |n| {
            var found: ?usize = null;
            for (params, 0..) |p, pi| if (s.syms.name(p) == n) {
                found = pi;
            };
            const pi = found orelse return null;
            if (filled[pi] and !s.syms.flags(params[pi]).vararg) return null;
            // A spread argument only passes a vararg's elements.
            if (a.spread and !s.syms.flags(params[pi]).vararg) return null;
            filled[pi] = true;
            slots[i] = .{ .param = @intCast(pi), .named_array = s.syms.flags(params[pi]).vararg and !a.spread };
            // A named argument before the vararg ends positional filling
            // at that parameter.
            if (pi >= pos) pos = pi + 1;
            continue;
        }
        if (pos >= params.len) return null;
        if (s.syms.flags(params[pos]).vararg) {
            slots[i] = .{ .param = @intCast(pos), .vararg_elem = !a.spread };
            filled[pos] = true;
            continue;
        }
        if (a.spread) return null;
        slots[i] = .{ .param = @intCast(pos) };
        filled[pos] = true;
        pos += 1;
    }
    for (params, filled) |p, f| {
        if (f) continue;
        if (s.syms.flags(p).vararg) continue;
        if (try paramHasDefault(ctx, fsym, p)) continue;
        if (try defaultIn(ctx, defaults, s.syms.paramInfo(p).index)) continue;
        return null;
    }
    return slots;
}

/// Whether parameter `idx` of function `f` has a default; false with no `f`.
fn defaultIn(ctx: *Ctx, f: Sym, idx: usize) Allocator.Error!bool {
    if (f == .none) return false;
    const ps = ctx.s.syms.functionInfo(f).params;
    return idx < ps.len and try paramHasDefault(ctx, f, ps[idx]);
}

/// A parameter's default, written on it or on the declaration it overrides.
fn paramHasDefault(ctx: *Ctx, fsym: Sym, p: Sym) Allocator.Error!bool {
    const s = ctx.s;
    if (s.syms.flags(p).has_default) return true;
    if (!s.syms.flags(fsym).override) return false;
    const cls = s.syms.owner(fsym);
    if (cls == .none or s.syms.kind(cls) != .class) return false;
    const idx = s.syms.paramInfo(p).index;
    for (try headers.supertypes(s, cls)) |st| {
        const self_subst = try s.arena.create(types.Subst);
        self_subst.* = .empty;
        for (try members.lookup(s, st, s.syms.name(fsym), .function)) |m| {
            if (!try members.sameSignature(s, fsym, self_subst, m.sym, m.subst)) continue;
            const bp = s.syms.functionInfo(m.sym).params;
            if (idx < bp.len and try paramHasDefault(ctx, m.sym, bp[idx])) return true;
        }
    }
    return false;
}

/// Whether a lambda, anonymous function or callable reference can be
/// passed where `pt` is expected, by shape alone.
fn postponedFits(ctx: *Ctx, a: Arg, pt: TypeId) Allocator.Error!bool {
    const s = ctx.s;
    if (a.deferred) return true;
    if (a.literal) return (try literalTarget(ctx, pt)) != .none;
    // A callable reference can be a function type or a `KProperty`; its
    // candidates are chosen against the parameter type after the call's.
    {
        var inner = a.expr;
        if (inner.* == .Spread) inner = inner.Spread.expr;
        if (inner.* == .PropertyRef or inner.* == .MemberRef) return refApplies(ctx, inner, pt);
    }
    const t = try s.types.makeNotNull(pt);
    switch (s.types.get(t)) {
        .variable, .err => return true,
        // An enclosing declaration's type parameter is rigid here: a
        // lambda is not known to be a `T`.
        .param => return false,
        .class => |c| {
            var fn_t = t;
            const shape = functionShape(s, t) orelse blk: {
                // A fun interface takes a lambda by SAM conversion, shaped
                // as its method.
                if (s.syms.flags(c.sym).fun_iface) {
                    const sam = (try samType(ctx, t)) orelse return true;
                    fn_t = sam.fn_type;
                    break :blk functionShape(s, sam.fn_type) orelse return true;
                }
                // `Any`, `Function<R>` and their like take any lambda.
                return s.builtins.any == c.sym or s.builtins.function == c.sym;
            };
            var inner = a.expr;
            if (inner.* == .Spread) inner = inner.Spread.expr;
            if (inner.* == .Labeled) inner = inner.Labeled.expr;
            switch (inner.*) {
                .Lambda => |l| {
                    if (l.implicit_it or l.params.len == 0) return shape.params <= 1 or l.params.len == 0 and shape.params == 0;
                    if (l.params.len != shape.params) return false;
                    return lambdaParamTypesFit(ctx, l, fn_t, shape);
                },
                .AnonFun => |f| {
                    // Without its own contexts it may take them as its
                    // leading parameters.
                    if (f.context_params.len == 0 and !shape.has_receiver and f.params.len == shape.params + shape.contexts) return true;
                    return f.params.len == shape.params;
                },
                else => return true,
            }
        },
        else => return true,
    }
}

/// Whether a lambda's written parameter types accept what the function
/// type passes: `{ i: Int, e: Long -> }` does not fit `(Int, Char) -> Unit`.
/// A parameter type still open is decided with the call.
fn lambdaParamTypesFit(ctx: *Ctx, l: *const ast.LambdaExpr, fn_t: TypeId, shape: FnShape) Allocator.Error!bool {
    const s = ctx.s;
    const args = s.types.argsOf(fn_t);
    const first = shape.contexts + @intFromBool(shape.has_receiver);
    for (l.param_tys, 0..) |maybe_tr, i| {
        const tr = maybe_tr orelse continue;
        if (first + i >= args.len) break;
        const given = try infer.zonk(s, args[first + i].ty);
        if (given == .none or infer.hasOpenVar(s, given) or s.types.isErr(given)) continue;
        const written = try body.resolveTypeInBodyQuiet(ctx, &tr);
        if (s.types.isErr(written)) continue;
        if (!try subtyping.isSubtype(s, given, written)) return false;
    }
    return true;
}

/// Whether a callable reference could have type `pt`: a function type, a
/// reflection type (`KProperty1`, `KFunction2`, ...), `Function`, a fun
/// interface, `Any`, or a type still to be inferred.
fn refFits(s: *Sema, pt: TypeId) bool {
    const t = s.types.makeNotNull(pt) catch return true;
    switch (s.types.get(t)) {
        .class => |c| {
            if (functionShape(s, t) != null) return true;
            if (c.sym == s.builtins.any or c.sym == s.builtins.function) return true;
            if (s.syms.flags(c.sym).fun_iface) return true;
            const fqn = s.str(s.syms.classInfo(c.sym).fqn);
            return std.mem.startsWith(u8, fqn, "kotlin.reflect.");
        },
        else => return true,
    }
}

/// A function type's layout: `contexts` leading context types, then the
/// receiver when there is one, then `params` parameters.
pub const FnShape = struct { params: usize, has_receiver: bool, is_suspend: bool, contexts: usize = 0 };

/// How many contexts a function type takes; 0 for any other type.
fn contextCount(s: *Sema, t: TypeId) u8 {
    return switch (s.types.get(t)) {
        .class => |c| c.attrs.context_count,
        else => 0,
    };
}

/// The shape of a `FunctionN`/`SuspendFunctionN` type: value parameters
/// (receiver excluded) and whether it takes a receiver.
/// `t` as the suspend function type of the same shape, when it is a plain
/// function type (`(A) -> R` becomes `suspend (A) -> R`).
fn suspendConverted(s: *Sema, t_in: TypeId) Allocator.Error!?TypeId {
    const t = try s.types.makeNotNull(try infer.zonk(s, t_in));
    const c = switch (s.types.get(t)) {
        .class => |c| c,
        else => return null,
    };
    var it = s.function_classes.iterator();
    while (it.next()) |e| if (e.value_ptr.* == c.sym) {
        const sus = s.suspend_function_classes.get(e.key_ptr.*) orelse return null;
        return try s.types.classAttrs(sus, c.args, c.nullable, c.attrs);
    };
    return null;
}

/// The conversion that lets a value of type `at` be passed for `pt`, which
/// it does not fit as it is, constraining `sys` with it: a value of a plain
/// function type, or of a type that extends one (`object Ok : () -> Unit`),
/// passed for a suspend function type is suspend converted; passed for a
/// fun interface, SAM converted, the method's function type taking the
/// parameter's nullability. Null when neither applies.
fn convertedArg(ctx: *Ctx, sys: *infer.System, at: TypeId, pt: TypeId) Allocator.Error!?records.Conv {
    const s = ctx.s;
    const fvs = try functionValueTypes(s, at);
    if (fvs.len == 0) return null;
    const nullable = s.types.isNullable(try infer.zonk(s, at));
    for (fvs) |ft_nn| {
        const ft = if (nullable) try s.types.makeNullable(ft_nn) else ft_nn;
        if (try suspendConverted(s, ft)) |st| {
            var trial = try sys.clone();
            if (try trial.constrain(st, pt)) {
                _ = try sys.constrain(st, pt);
                return .suspend_;
            }
        }
    }
    const pt_nn = try s.types.makeNotNull(pt);
    const sam = (try samType(ctx, pt_nn)) orelse return null;
    const want = if (s.types.isNullable(pt)) try s.types.makeNullable(sam.fn_type) else sam.fn_type;
    for (fvs) |ft_nn| {
        const ft = if (nullable) try s.types.makeNullable(ft_nn) else ft_nn;
        // A suspend method takes a plain function value too.
        const forms = [_]?TypeId{ ft, try suspendConverted(s, ft) };
        for (forms) |form| {
            const f = form orelse continue;
            var trial = try sys.clone();
            if (!try trial.constrain(f, want)) continue;
            _ = try sys.constrain(f, want);
            return .{ .sam = s.types.classSym(pt_nn) };
        }
    }
    return null;
}

/// The function types a value of type `t` can be invoked as: `t` itself
/// when it is one, else the function-type supertypes of its class, of a
/// type parameter's bounds or of an intersection's parts.
fn functionValueTypes(s: *Sema, t_in: TypeId) Allocator.Error![]const TypeId {
    var out: std.ArrayList(TypeId) = .empty;
    try collectFunctionTypes(s, try s.types.makeNotNull(try infer.zonk(s, t_in)), &out);
    return out.items;
}

fn collectFunctionTypes(s: *Sema, t: TypeId, out: *std.ArrayList(TypeId)) Allocator.Error!void {
    switch (s.types.get(t)) {
        .class => {
            if (functionShape(s, t) != null) return out.append(s.arena, t);
            var seen: std.AutoHashMapUnmanaged(Sym, void) = .empty;
            var queue: std.ArrayList(TypeId) = .empty;
            try queue.append(s.arena, t);
            var qi: usize = 0;
            while (qi < queue.items.len) : (qi += 1) {
                const cur = queue.items[qi];
                const c = s.types.get(cur).class;
                if ((try seen.getOrPut(s.arena, c.sym)).found_existing) continue;
                if (qi != 0 and functionShape(s, cur) != null) {
                    try out.append(s.arena, cur);
                    continue;
                }
                const subst = try subtyping.classSubst(s, cur);
                for (try headers.supertypes(s, c.sym)) |st| {
                    const inst = try s.types.substitute(st, &subst);
                    if (s.types.get(inst) == .class) try queue.append(s.arena, inst);
                }
            }
        },
        .param => |p| for (try headers.typeParamBounds(s, p.sym)) |b| try collectFunctionTypes(s, try s.types.makeNotNull(b), out),
        .intersection => |parts| for (parts) |part| try collectFunctionTypes(s, try s.types.makeNotNull(part), out),
        else => {},
    }
}

pub fn functionShape(s: *Sema, t: TypeId) ?FnShape {
    const c = switch (s.types.get(t)) {
        .class => |c| c,
        else => return null,
    };
    var it = s.function_classes.iterator();
    while (it.next()) |e| if (e.value_ptr.* == c.sym) {
        const n = e.key_ptr.*;
        const recv: usize = @intFromBool(c.attrs.ext_fn);
        return .{ .params = n - recv - c.attrs.context_count, .has_receiver = c.attrs.ext_fn, .is_suspend = false, .contexts = c.attrs.context_count };
    };
    var sit = s.suspend_function_classes.iterator();
    while (sit.next()) |e| if (e.value_ptr.* == c.sym) {
        const n = e.key_ptr.*;
        const recv: usize = @intFromBool(c.attrs.ext_fn);
        return .{ .params = n - recv - c.attrs.context_count, .has_receiver = c.attrs.ext_fn, .is_suspend = true, .contexts = c.attrs.context_count };
    };
    // A function reference's `KFunctionN` has the shape of its `FunctionN`,
    // with the extension receiver of an extension function's first.
    const krecv: u32 = @intFromBool(c.attrs.ext_fn);
    var kit = s.kfunction_classes.iterator();
    while (kit.next()) |e| if (e.value_ptr.* == c.sym) return .{ .params = e.key_ptr.* - krecv, .has_receiver = c.attrs.ext_fn, .is_suspend = false };
    var ksit = s.ksuspend_function_classes.iterator();
    while (ksit.next()) |e| if (e.value_ptr.* == c.sym) return .{ .params = e.key_ptr.* - krecv, .has_receiver = c.attrs.ext_fn, .is_suspend = true };
    return null;
}

/// Whether every candidate is `@LowPriorityInOverloadResolution`: such a
/// level does not end the search, a later level's candidate wins over it.
fn onlyLowPriority(ctx: *Ctx, apps: []const Applied) Allocator.Error!bool {
    const s = ctx.s;
    const low = s.builtins.low_priority;
    if (low == .none) return false;
    for (apps) |a| {
        if (!try hasAnnotation(s, a.cand.sym, low)) return false;
    }
    return true;
}

/// `@LowPriorityInOverloadResolution` candidates apply only when no other
/// candidate of the level does.
/// Drops the candidates the call cannot see when some it can see apply;
/// true, with the list left whole, when none it can see does.
fn dropInvisible(ctx: *Ctx, apps: *std.ArrayList(Applied)) Allocator.Error!bool {
    var visible_n: usize = 0;
    for (apps.items) |a| {
        if (try memberVisible(ctx, a.cand.sym)) visible_n += 1;
    }
    if (visible_n == apps.items.len) return false;
    if (visible_n == 0) return true;
    var i: usize = 0;
    while (i < apps.items.len) {
        if (!try memberVisible(ctx, apps.items[i].cand.sym)) {
            _ = apps.orderedRemove(i);
        } else i += 1;
    }
    return false;
}

/// Whether the code being resolved can see class member `sym`: a private
/// member only inside its class, what the class nests and, for a
/// companion's, the class the companion belongs to; a protected one inside
/// its class's subclasses too, and inside a class whose companion is one
/// (`class B { companion object : A() }` calls A's protected members).
/// Constructors are checked with their class.
pub fn memberVisible(ctx: *Ctx, sym: Sym) Allocator.Error!bool {
    const s = ctx.s;
    const vis = s.syms.flags(sym).visibility;
    if (vis != .private and vis != .protected) return true;
    if (s.syms.kind(sym) == .constructor) return true;
    var cls = s.syms.owner(sym);
    if (cls == .none or s.syms.kind(cls) != .class) return true;
    if (s.syms.classInfo(cls).kind == .companion) {
        const outer = s.syms.owner(cls);
        if (outer != .none and s.syms.kind(outer) == .class) cls = outer;
    }
    var sc: ?*body.Scope = ctx.scope;
    while (sc) |c| : (sc = c.parent) {
        if (c.kind != .class or c.owner == .none) continue;
        if (c.owner == cls) return true;
        if (vis != .protected) continue;
        if ((try subtyping.supertypeWithClass(s, try headers.selfType(s, c.owner), cls)) != null) return true;
        if (s.syms.kind(c.owner) != .class) continue;
        const comp = s.syms.classInfo(c.owner).companion;
        if (comp != .none and (try subtyping.supertypeWithClass(s, try headers.selfType(s, comp), cls)) != null) return true;
    }
    return false;
}

fn dropLowPriority(ctx: *Ctx, apps: *std.ArrayList(Applied)) Allocator.Error!void {
    const s = ctx.s;
    const low = s.builtins.low_priority;
    if (low == .none or apps.items.len < 2) return;
    var kept: usize = 0;
    for (apps.items) |a| {
        if (!try hasAnnotation(s, a.cand.sym, low)) kept += 1;
    }
    if (kept == 0 or kept == apps.items.len) return;
    var i: usize = 0;
    while (i < apps.items.len) {
        if (try hasAnnotation(s, apps.items[i].cand.sym, low)) {
            _ = apps.orderedRemove(i);
        } else i += 1;
    }
}

/// Whether a function is annotated with the annotation class `cls`.
fn hasAnnotation(s: *Sema, sym: Sym, cls: Sym) Allocator.Error!bool {
    const anns: []const ast.Annotation = switch (s.syms.get(sym).decl) {
        .function => |f| f.annotations,
        else => return false,
    };
    return headers.annotatedWith(s, .{ .decl = sym, .file = s.syms.get(sym).file }, anns, cls);
}

/// `@OverloadResolutionByLambdaReturnType` overloads (`sumOf`) differ only
/// in the result type of their lambda parameter: the lambda is analyzed
/// once, without recording anything, to learn its result, and the
/// candidate whose lambda result it fits is chosen.
fn byLambdaReturn(ctx: *Ctx, apps: []Applied) Allocator.Error!?usize {
    const s = ctx.s;
    // One annotated candidate is enough: the rule applies to the set.
    var annotated = false;
    for (apps) |*a| {
        if (try hasAnnotation(s, a.cand.sym, s.builtins.overload_by_lambda)) annotated = true;
    }
    if (!annotated) return null;
    // The single postponed argument they all map.
    const first = &apps[0];
    var li: ?usize = null;
    for (first.args, 0..) |a, i| if (a.postponed) {
        if (li != null) return null;
        li = i;
    };
    const arg_index = li orelse return null;
    const params = candParams(s, first.cand);
    const pt = try first.sys.open(try s.types.substitute(try headers.paramType(s, params[first.slots[arg_index].param]), first.cand.subst));
    var trial = try first.sys.clone();
    _ = try trial.solve(true);
    const hint = try lambdaExpectation(ctx, &trial, &first.sys, pt);
    // Only the parameter types matter; the result is what is learned.
    const nn = try s.types.makeNotNull(hint);
    const hc = switch (s.types.get(nn)) {
        .class => |c| c,
        else => return null,
    };
    const loose_args = try s.arena.dupe(types.Arg, hc.args);
    if (loose_args.len != 0) loose_args[loose_args.len - 1] = .{ .variance = .inv, .ty = s.t.any_q };
    const probe = try s.types.classAttrs(hc.sym, loose_args, false, hc.attrs);
    s.census.muted += 1;
    if (first.args[arg_index].expr.* == .Lambda) ctx.lambda_label = s.syms.name(first.cand.sym);
    const lt = body.expr(ctx, first.args[arg_index].expr, probe) catch |e| {
        s.census.muted -= 1;
        return e;
    };
    s.census.muted -= 1;
    const lret = switch (s.types.get(try s.types.makeNotNull(lt))) {
        .class => |c| if (c.args.len != 0) c.args[c.args.len - 1].ty else return null,
        else => return null,
    };
    var hit: ?usize = null;
    for (apps, 0..) |*a, i| {
        const ap = candParams(s, a.cand);
        const apt = try s.types.substitute(try headers.paramType(s, ap[a.slots[arg_index].param]), a.cand.subst);
        const ac = switch (s.types.get(try s.types.makeNotNull(apt))) {
            .class => |c| c,
            else => continue,
        };
        if (ac.args.len == 0) continue;
        const want = ac.args[ac.args.len - 1].ty;
        var sys = try a.sys.clone();
        if (!try sys.constrain(lret, try a.sys.open(want))) continue;
        // An exact result wins over one it merely fits.
        if (try subtyping.equivalent(s, lret, want)) return i;
        if (hit == null) hit = i;
    }
    if (hit != null) return hit;
    // What the lambda gives against `Any?` fits no candidate: a nested
    // call it returns was fixed without the result's expectation
    // (`return@flatMapTo emptySequence()`). The first candidate whose own
    // function type the lambda analyzes against without a site is chosen.
    for (apps, 0..) |*a, i| {
        const ap = candParams(s, a.cand);
        const apt = try a.sys.open(try s.types.substitute(try headers.paramType(s, ap[a.slots[arg_index].param]), a.cand.subst));
        var a_trial = try a.sys.clone();
        _ = try a_trial.solve(true);
        var a_sys = try a.sys.clone();
        const want = try lambdaExpectation(ctx, &a_trial, &a_sys, apt);
        const b = try ctx.beginBuffer();
        if (a.args[arg_index].expr.* == .Lambda) ctx.lambda_label = s.syms.name(a.cand.sym);
        const t = body.expr(ctx, a.args[arg_index].expr, want) catch |e| {
            ctx.drop(b);
            return e;
        };
        const clean = b.sites.items.len == 0 and !s.types.isErr(t);
        ctx.drop(b);
        if (clean) return i;
    }
    return null;
}

const Choice = struct { index: usize, ambiguous: bool };

/// The candidate every other is less specific than. Ties break toward no
/// vararg, then fewer defaults used, then non-generic; candidates left
/// ambiguous prefer those that SAM convert no argument, then those that
/// suspend convert none (`take(g)` for a `g: () -> String` is
/// `take(() -> String)`, not `take(suspend () -> String)`).
fn mostSpecific(ctx: *Ctx, apps: []Applied, args: []const Arg) Allocator.Error!Choice {
    const c = try mostSpecificByTypes(ctx, apps, args);
    if (!c.ambiguous) return c;
    if (try withoutConversion(ctx, apps, args, .sam)) |r| return r;
    if (try withoutConversion(ctx, apps, args, .suspend_)) |r| return r;
    return c;
}

/// The most specific of the candidates that pass no argument through a
/// conversion of kind `kind`, when some but not all of them do; null
/// otherwise.
fn withoutConversion(ctx: *Ctx, apps: []Applied, args: []const Arg, kind: std.meta.Tag(records.Conv)) Allocator.Error!?Choice {
    const s = ctx.s;
    var plain: std.ArrayList(usize) = .empty;
    for (apps, 0..) |*a, i| {
        const uses = switch (kind) {
            .sam => try usesSam(ctx, a),
            else => usesConv(a, kind),
        };
        if (!uses) try plain.append(s.arena, i);
    }
    const n = plain.items.len;
    if (n == 0 or n == apps.len) return null;
    if (n == 1) return .{ .index = plain.items[0], .ambiguous = false };
    const sub = try s.arena.alloc(Applied, n);
    for (plain.items, sub) |i, *dst| dst.* = apps[i];
    const r = try mostSpecific(ctx, sub, args);
    return .{ .index = plain.items[r.index], .ambiguous = r.ambiguous };
}

fn usesConv(app: *const Applied, kind: std.meta.Tag(records.Conv)) bool {
    for (app.conv) |cv| if (cv == kind) return true;
    return false;
}

/// Whether a candidate passes some argument through a SAM conversion: a
/// function value converted to a fun interface, or a lambda literal whose
/// parameter is a fun interface.
fn usesSam(ctx: *Ctx, app: *const Applied) Allocator.Error!bool {
    const s = ctx.s;
    for (app.conv) |cv| if (cv == .sam) return true;
    const params = candParams(s, app.cand);
    for (app.args, app.slots) |a, slot| {
        if (!a.postponed) continue;
        var inner = a.expr;
        if (inner.* == .Labeled) inner = inner.Labeled.expr;
        if (inner.* != .Lambda and inner.* != .AnonFun) continue;
        const pt = try s.types.makeNotNull(try s.types.substitute(try headers.paramType(s, params[slot.param]), app.cand.subst));
        if (functionShape(s, pt) != null) continue;
        const cls = s.types.classSym(pt);
        if (cls != .none and s.syms.flags(cls).fun_iface) return true;
    }
    return false;
}

fn mostSpecificByTypes(ctx: *Ctx, apps: []Applied, args: []const Arg) Allocator.Error!Choice {
    if (apps.len == 1) return .{ .index = 0, .ambiguous = false };
    var best: ?usize = null;
    var ambiguous = false;
    outer: for (apps, 0..) |*a, i| {
        for (apps, 0..) |*b, j| {
            if (i == j) continue;
            if (!try atLeastAsSpecific(ctx, a, b, args)) continue :outer;
            if (try atLeastAsSpecific(ctx, b, a, args)) {
                // Equally specific by parameter types: break the tie.
                if (tieBreak(a, b) != .lt) continue :outer;
            }
        }
        if (best == null) best = i else ambiguous = true;
    }
    if (best) |b| return .{ .index = b, .ambiguous = ambiguous };
    // None is most specific by parameter types: a non-generic candidate
    // beats every generic one, and the non-generic ones compare among
    // themselves (`UByteArray.sumBy((UByte) -> UInt)` over
    // `Iterable<T>.sumBy((T) -> Int)`).
    var plain: std.ArrayList(usize) = .empty;
    for (apps, 0..) |*a, i| if (!a.generic) try plain.append(ctx.s.arena, i);
    if (plain.items.len != 0 and plain.items.len != apps.len) {
        const sub = try ctx.s.arena.alloc(Applied, plain.items.len);
        for (plain.items, sub) |i, *dst| dst.* = apps[i];
        const c = try mostSpecificByTypes(ctx, sub, args);
        if (!c.ambiguous) return .{ .index = plain.items[c.index], .ambiguous = false };
    }
    // No single most specific: take the first tie-break winner.
    var idx: usize = 0;
    for (apps, 0..) |*a, i| {
        if (tieBreak(a, &apps[idx]) == .lt) idx = i;
    }
    return .{ .index = idx, .ambiguous = true };
}

fn tieBreak(a: *const Applied, b: *const Applied) std.math.Order {
    if (a.uses_vararg != b.uses_vararg) return if (!a.uses_vararg) .lt else .gt;
    if (a.uses_default != b.uses_default) return std.math.order(a.uses_default, b.uses_default);
    if (a.generic != b.generic) return if (!a.generic) .lt else .gt;
    if (a.cand.via != .none and b.cand.via == .none) return .gt;
    if (a.cand.via == .none and b.cand.via != .none) return .lt;
    return .eq;
}

/// Whether `a`'s parameter types, at every argument, fit `b`'s.
fn atLeastAsSpecific(ctx: *Ctx, a: *const Applied, b: *const Applied, args: []const Arg) Allocator.Error!bool {
    const s = ctx.s;
    const ap = candParams(s, a.cand);
    const bp = candParams(s, b.cand);
    var sys = infer.System.init(s);
    const b_tps = try candTypeParams(s, b.cand);
    try sys.addTypeParams(b_tps);
    // `b`'s type parameters keep their bounds: `<S : C>` is more specific
    // than `<S : A>` for `C : A`, not the other way round.
    if (!try sys.addDeclaredBounds(b_tps, b.cand.subst)) return false;
    // A candidate with a receiver-as-first-argument sees the call's
    // arguments one position later.
    const a_off: usize = @intFromBool(a.cand.recv_arg_ty != .none);
    const b_off: usize = @intFromBool(b.cand.recv_arg_ty != .none);
    for (args, 0..) |_, i| {
        const at = try specificityType(ctx, a, ap, i + a_off);
        const bt_raw = try specificityType(ctx, b, bp, i + b_off);
        if (try numericNotLessSpecific(s, at, bt_raw)) continue;
        const bt = try sys.open(bt_raw);
        if (!try sys.constrain(at, bt)) return false;
    }
    // An extension receiver counts as a parameter.
    const ai = s.syms.functionInfo(a.cand.sym);
    const bi = s.syms.functionInfo(b.cand.sym);
    if (ai.receiver != .none and bi.receiver != .none) {
        const at = try s.types.substitute(ai.receiver, a.cand.subst);
        const bt_raw = try s.types.substitute(bi.receiver, b.cand.subst);
        if (!try numericNotLessSpecific(s, at, bt_raw)) {
            if (!try sys.constrain(at, try sys.open(bt_raw))) return false;
        }
    }
    var trial = try sys.clone();
    return trial.solve(true);
}

/// Among the built-in numeric types, which are not subtypes of one another,
/// a parameter of the first is as specific as one of the second: `Int`
/// over `Long`, `Short` and `Byte`, `Short` over `Byte`, `Double` over
/// `Float`, and the same for the unsigned types. Nullability aside:
/// `f(Int?)` is chosen over `f(Long)` for `f(1)`, and `f(Int)` over
/// `f(Long)` for an argument that fits both (`f(throw e)`).
fn numericNotLessSpecific(s: *Sema, a_in: TypeId, b_in: TypeId) Allocator.Error!bool {
    const a = try s.types.makeNotNull(a_in);
    const b = try s.types.makeNotNull(b_in);
    const t = s.t;
    if (a == .none or b == .none or a == b) return false;
    if (a == t.int) return b == t.long or b == t.short or b == t.byte;
    if (a == t.short) return b == t.byte;
    if (a == t.double) return b == t.float;
    if (a == t.uint) return b == t.ulong or b == t.ushort or b == t.ubyte;
    if (a == t.ushort) return b == t.ubyte;
    return false;
}

fn specificityType(ctx: *Ctx, app: *const Applied, params: []const Sym, arg_index: usize) Allocator.Error!TypeId {
    const s = ctx.s;
    const slot = app.slots[arg_index];
    const p = params[slot.param];
    return s.types.substitute(try headers.paramType(s, p), app.cand.subst);
}

/// Analyzes postponed arguments against the chosen candidate, fixes its
/// type arguments and records the reference.
fn complete(ctx: *Ctx, app_in: Applied, call_args: []Arg, trailing: bool, id: ast.Ident, expected: TypeId) Allocator.Error!TypeId {
    _ = trailing;
    _ = call_args;
    const s = ctx.s;
    var app = app_in;
    const cand = app.cand;
    if (ctx.delegate_expect) |de| if (de.anchor.start == id.span.start and de.anchor.end == id.span.end) {
        ctx.delegate_expect = null;
        try expectDelegateValue(ctx, &app.sys, try candReturn(ctx, cand, &app.sys), de);
    };
    try postponedInOrder(ctx, &app, try ctx.intern(id.name));
    // In argument position the variables the result mentions are the
    // enclosing call's to fix, with what it expects of the argument.
    const leave_open = ctx.in_arg != .none and expected == .none;
    if (leave_open) app.sys.result = try candReturn(ctx, cand, &app.sys);
    if (leave_open and ctx.in_arg == .arg) app.sys.keep = app.sys.result;
    _ = try app.sys.solve(leave_open);
    try app.sys.forwardForeign();
    if (!leave_open) if (app.sys.firstUninferred()) |tp| {
        try ctx.reportFacts(.uninferred, id.span, .{ .name = id.name, .syms = try ctx.arena().dupe(Sym, &.{tp}) }, "{s}", .{id.name});
    };
    const ret = try app.sys.close(try candReturn(ctx, cand, &app.sys));
    // `invoke` on a value records the value's read first.
    if (cand.via != .none) {
        const vk = s.syms.kind(cand.via);
        if (vk == .property or vk == .local or vk == .value_param) {
            try ctx.addRef(.{ .file = ctx.file, .anchor = id.span, .kind = .read, .target = cand.via, .dispatch = cand.via_dispatch, .extension = cand.via_extension });
        } else if (vk == .class or vk == .enum_entry) {
            try ctx.addRef(.{ .file = ctx.file, .anchor = id.span, .kind = .object, .target = cand.via });
        }
    }
    const kind: RefKind = if (s.syms.kind(cand.sym) == .constructor) .ctor else if (cand.via != .none or cand.on_value) .invoke else .call;
    // An extension-function-type `invoke` records where its receiver came
    // from as the extension receiver.
    const ext: Receiver = if (cand.recv_arg_ty != .none) cand.recv_arg_src else cand.extension;
    const form: records.CallForm = if (cand.form != .plain) cand.form else if (kind == .ctor) .ctor else if (kind == .invoke) .value_invoke else .plain;
    try checkReifiedArgs(ctx, &app, id);
    // A default only the function the candidate stands for declares: the
    // call is that function's, whose default bridge makes the value and
    // whose dispatch reaches the implementation the class inherits.
    if (try takesForeignDefault(ctx, &app)) app.cand.sym = cand.defaults;
    try ctx.addRef(.{ .file = ctx.file, .anchor = id.span, .kind = kind, .target = app.cand.sym, .dispatch = cand.dispatch, .extension = ext, .contexts = app.contexts, .detail = .{ .call = try callDetail(ctx, &app, form, ext) } });
    return ret;
}

/// Constrains a delegate's call so what its `getValue` returns is the
/// property's written type, when the call's system allows it: a delegate
/// that does not fit is reported where the property checks it.
fn expectDelegateValue(ctx: *Ctx, sys: *infer.System, ret: TypeId, de: *const body.DelegateExpect) Allocator.Error!void {
    var trial = try sys.clone();
    const v = (try delegateValueType(ctx, &trial, ret, de.this_ref)) orelse return;
    var fit = try trial.clone();
    if (!try fit.constrain(v, de.declared)) return;
    if (de.mutable and !try fit.constrain(de.declared, v)) return;
    _ = try trial.constrain(v, de.declared);
    if (de.mutable) _ = try trial.constrain(de.declared, v);
    sys.* = trial;
}

/// Whether the call leaves a parameter to a default that only
/// `app.cand.defaults` declares.
fn takesForeignDefault(ctx: *Ctx, app: *const Applied) Allocator.Error!bool {
    const s = ctx.s;
    const d = app.cand.defaults;
    if (d == .none) return false;
    const params = s.syms.functionInfo(app.cand.sym).params;
    for (params, 0..) |p, pi| {
        if (s.syms.flags(p).vararg) continue;
        const given = for (app.slots) |sl| {
            if (sl.param == pi) break true;
        } else false;
        if (given) continue;
        if (try paramHasDefault(ctx, app.cand.sym, p)) continue;
        if (try defaultIn(ctx, d, pi)) return true;
    }
    return false;
}

/// A reified type parameter's argument must be a type known when the call
/// runs: kotlinc rejects a type parameter that is not reified there
/// (`arrayOf(a, b)` in `fun <T> choose(a: T, b: T)` has no class to make
/// the array of). The program's calls only: the libraries' sources
/// suppress the error where the value is never read as that type.
fn checkReifiedArgs(ctx: *Ctx, app: *Applied, id: ast.Ident) Allocator.Error!void {
    const s = ctx.s;
    const fc = s.fileOf(ctx.file) orelse return;
    if (fc.origin != .program) return;
    if (s.syms.kind(app.cand.sym) != .function) return;
    for (try candTypeParams(s, app.cand)) |tp| {
        if (!s.syms.flags(tp).reified) continue;
        const t = app.sys.fixedFor(tp);
        if (t == .none) continue;
        const z = try s.types.makeNotNull(try infer.zonk(s, t));
        switch (s.types.get(z)) {
            .param => |p| if (!s.syms.flags(p.sym).reified) {
                try ctx.reportFacts(.reified_param, id.span, .{ .name = id.name, .syms = try ctx.arena().dupe(Sym, &.{p.sym}) }, "{s}: {s}", .{ id.name, s.str(s.syms.name(p.sym)) });
                return;
            },
            // An intersection has no class to reify; kotlinc refuses one
            // inferred (`show("a", 1)` makes `T` a `Comparable<*> &
            // Serializable`).
            .intersection => {
                const text = try sema_mod.diagnose.typeText(s, s.arena, z);
                try ctx.reportFacts(.reified_param, id.span, .{
                    .name = id.name,
                    .message = try std.fmt.allocPrint(s.arena, "the reified type argument `{s}` of `{s}` was inferred as the intersection `{s}`; write the type argument explicitly", .{ s.str(s.syms.name(tp)), id.name, text }),
                }, "{s}: {s}", .{ id.name, text });
                return;
            },
            else => {},
        }
    }
}

/// Analyzes the postponed arguments in an order where each one's inputs
/// are known: an argument waits while another postponed lambda's result
/// still gives a variable its expected type mentions
/// (`minOfWith(compareBy { it.length }) { it }` types the selector first,
/// whose result is `compareBy`'s `T`). When every one waits, the first
/// goes.
fn postponedInOrder(ctx: *Ctx, app: *Applied, label: Name) Allocator.Error!void {
    const s = ctx.s;
    var remaining: std.ArrayList(usize) = .empty;
    for (app.args, 0..) |a, i| if (a.postponed) try remaining.append(s.arena, i);
    while (remaining.items.len != 0) {
        var pick: usize = 0;
        for (remaining.items, 0..) |i, ri| {
            if (!try waitsOnLambdaResult(ctx, app, i, remaining.items)) {
                pick = ri;
                break;
            }
        }
        const i = remaining.orderedRemove(pick);
        try postponedArg(ctx, app, &app.args[i], app.slots[i], label);
    }
}

/// Whether postponed argument `i`'s expected type mentions a variable that
/// another of `remaining`, a lambda, gives through its result.
fn waitsOnLambdaResult(ctx: *Ctx, app: *Applied, i: usize, remaining: []const usize) Allocator.Error!bool {
    const s = ctx.s;
    if (remaining.len < 2) return false;
    const mine = try app.sys.open(try paramTypeOf(ctx, app, i));
    // A lambda's own inputs are what it needs; any other argument needs its
    // whole expected type.
    const needs: TypeId = if (isLambdaArg(app.args[i].expr)) blk: {
        const nn = try s.types.makeNotNull(try infer.zonk(s, mine));
        const args = s.types.argsOf(nn);
        if (functionShape(s, nn) == null or args.len == 0) break :blk .none;
        const inputs = try s.arena.alloc(types.Arg, args.len - 1);
        @memcpy(inputs, args[0 .. args.len - 1]);
        break :blk try s.types.class(s.builtins.any, inputs, false);
    } else mine;
    if (needs == .none) return false;
    for (remaining) |j| {
        if (j == i or !isLambdaArg(app.args[j].expr)) continue;
        const theirs = try s.types.makeNotNull(try infer.zonk(s, try app.sys.open(try paramTypeOf(ctx, app, j))));
        if (functionShape(s, theirs) == null) continue;
        const targs = s.types.argsOf(theirs);
        if (targs.len == 0) continue;
        if (try sharesOpenVar(s, &app.sys, needs, targs[targs.len - 1].ty)) return true;
    }
    return false;
}

fn paramTypeOf(ctx: *Ctx, app: *const Applied, i: usize) Allocator.Error!TypeId {
    const s = ctx.s;
    const p = candParams(s, app.cand)[app.slots[i].param];
    var pt = try s.types.substitute(try headers.paramType(s, p), app.cand.subst);
    if (s.syms.flags(p).vararg and app.args[i].spread) pt = try varargArrayType(ctx, pt);
    return pt;
}

fn isLambdaArg(e: *const ast.Expr) bool {
    var inner = e;
    if (inner.* == .Spread) inner = inner.Spread.expr;
    if (inner.* == .Labeled) inner = inner.Labeled.expr;
    return inner.* == .Lambda or inner.* == .AnonFun;
}

/// Whether `a` and `b` mention a common variable `sys` has not fixed.
fn sharesOpenVar(s: *Sema, sys: *infer.System, a: TypeId, b: TypeId) Allocator.Error!bool {
    var in_a: std.ArrayList(u32) = .empty;
    try collectOpenVars(s, try infer.zonk(s, a), &in_a);
    if (in_a.items.len == 0) return false;
    var in_b: std.ArrayList(u32) = .empty;
    try collectOpenVars(s, try infer.zonk(s, b), &in_b);
    _ = sys;
    for (in_a.items) |x| {
        if (std.mem.indexOfScalar(u32, in_b.items, x) != null) return true;
    }
    return false;
}

fn collectOpenVars(s: *Sema, t: TypeId, out: *std.ArrayList(u32)) Allocator.Error!void {
    switch (s.types.get(t)) {
        .variable => |v| if (!s.var_solution.contains(v.id)) try out.append(s.arena, v.id),
        .class => |c| for (c.args) |a| {
            if (a.variance != .star) try collectOpenVars(s, a.ty, out);
        },
        .intersection => |parts| for (parts) |p| try collectOpenVars(s, p, out),
        else => {},
    }
}

/// A lambda, anonymous function or callable reference argument, analyzed
/// once against the chosen candidate's parameter: its parameter types come
/// from what the system knows so far, and its result feeds the system.
fn postponedArg(ctx: *Ctx, app: *Applied, a: *Arg, slot: Slot, label: Name) Allocator.Error!void {
    const s = ctx.s;
    const cand = app.cand;
    const p = candParams(s, cand)[slot.param];
    var pt = try s.types.substitute(try headers.paramType(s, p), cand.subst);
    if (s.syms.flags(p).vararg and a.spread) pt = try varargArrayType(ctx, pt);
    const opened = try app.sys.open(pt);
    if (a.literal) {
        // Resolved against the parameter type as it stands, its own
        // variables left open for this call to fix with the rest
        // (`makeString([1, 2])` for `MyList<U>` makes `U` an `Int`).
        var inner = a.expr;
        if (inner.* == .Spread) inner = inner.Spread.expr;
        const saved = ctx.in_arg;
        ctx.in_arg = .arg;
        defer ctx.in_arg = saved;
        a.ty = try body.expr(ctx, inner, opened);
        _ = try app.sys.constrain(a.ty, opened);
        return;
    }
    try writtenInputs(ctx, &app.sys, a.expr, opened);
    // What the lambda's parameter types mention is fixed first.
    try app.sys.fixInputs(opened);
    var trial = try app.sys.clone();
    _ = try trial.solve(false);
    // A parameter or receiver type nothing constrains yet stays a variable
    // in the lambda, and the calls in its body infer it for this system
    // (builder inference: `channelFlow { send(1) }`).
    var inner_call = a.expr;
    if (inner_call.* == .Spread) inner_call = inner_call.Spread.expr;
    if (a.deferred and inner_call.* == .Call) {
        // A call deferred to this parameter is resolved against what the
        // system knows of it; a variable nothing constrains yet stays open,
        // for the call's own lambdas to type (`infiniteRepeatable(keyframes
        // { 0f at 0 })` takes `Float` from `keyframes`' body, not the `Any?`
        // `T` would default to), and the call's result fixes it here.
        const saved = ctx.in_arg;
        ctx.in_arg = .arg;
        defer ctx.in_arg = saved;
        a.ty = try body.expr(ctx, inner_call, try trial.closeKnown(opened));
        _ = try app.sys.constrain(a.ty, opened);
        return;
    }
    const builders = try app.sys.builderVars(&trial, opened);
    if (builders.len != 0) ctx.builder_typed = true;
    for (builders) |bv| {
        trial.unfix(bv);
        try s.builder_owners.put(s.arena, bv, &app.sys);
    }
    defer for (builders) |bv| {
        _ = s.builder_owners.remove(bv);
    };
    const hint = try lambdaExpectation(ctx, &trial, &app.sys, opened);
    var inner = a.expr;
    if (inner.* == .Spread) inner = inner.Spread.expr;
    // A lambda passed to `f` is labeled `f` unless it names itself.
    if (inner.* == .Lambda) ctx.lambda_label = label;
    const at = try body.expr(ctx, inner, hint);
    ctx.lambda_label = .empty;
    a.ty = at;
    _ = try app.sys.constrain(at, opened);
    try noteSamLiteral(ctx, app, a, opened);
}

/// A lambda's written parameter types bound its expected inputs before it
/// is analyzed: `{ thisRef: Owner, property -> ... }` passed for
/// `(T, KProperty<*>) -> R` makes `T` at most an `Owner`.
fn writtenInputs(ctx: *Ctx, sys: *infer.System, e: *const Expr, pt: TypeId) Allocator.Error!void {
    const s = ctx.s;
    var inner = e;
    if (inner.* == .Spread) inner = inner.Spread.expr;
    if (inner.* == .Labeled) inner = inner.Labeled.expr;
    if (inner.* != .Lambda) return;
    const l = inner.Lambda;
    if (l.param_tys.len == 0) return;
    var ft = try s.types.makeNotNull(try infer.zonk(s, pt));
    if (functionShape(s, ft) == null) {
        const sam = (try samType(ctx, ft)) orelse return;
        ft = sam.fn_type;
    }
    const sh = functionShape(s, ft) orelse return;
    const args = s.types.argsOf(ft);
    const first = sh.contexts + @intFromBool(sh.has_receiver);
    s.census.muted += 1;
    defer s.census.muted -= 1;
    const b = try ctx.beginBuffer();
    defer ctx.drop(b);
    for (l.param_tys, 0..) |*tr_opt, i| {
        const tr = if (tr_opt.*) |*t| t else continue;
        if (first + i + 1 >= args.len) break;
        const want = args[first + i].ty;
        const written = try body.resolveTypeInBody(ctx, tr);
        if (s.types.isErr(written)) continue;
        var trial = try sys.clone();
        if (try trial.constrain(want, written)) _ = try sys.constrain(want, written);
    }
}

/// A lambda, anonymous function or callable reference passed for a fun
/// interface parameter is wrapped in the interface.
fn noteSamLiteral(ctx: *Ctx, app: *Applied, a: *const Arg, pt: TypeId) Allocator.Error!void {
    const s = ctx.s;
    var inner = a.expr;
    if (inner.* == .Spread) inner = inner.Spread.expr;
    if (inner.* == .Labeled) inner = inner.Labeled.expr;
    // `run(::intRef)` for an `IntConsumer` parameter wraps the reference.
    switch (inner.*) {
        .Lambda, .AnonFun, .PropertyRef, .MemberRef => {},
        else => return,
    }
    const t = try s.types.makeNotNull(try infer.zonk(s, try app.sys.close(pt)));
    const cls = s.types.classSym(t);
    if (cls == .none or !s.syms.flags(cls).fun_iface) return;
    for (app.args, 0..) |*x, i| if (x == a) {
        app.conv[i] = .{ .sam = cls };
    };
}

/// The call record lowering reads: each parameter's operand, the
/// contexts, the solved type arguments and the conversions.
/// An integer literal argument has the integral type its parameter
/// solved to: `f(1)` for `f(x: Long)` passes a `Long`, recorded on the
/// literal's node (and a negated literal's) so lowering makes that
/// constant.
fn adoptLiteralArgs(ctx: *Ctx, app: *Applied, params: []const Sym) Allocator.Error!void {
    const s = ctx.s;
    for (app.args, app.slots) |a, slot| {
        if (a.postponed or a.ty == .none) continue;
        if (s.types.get(try infer.zonk(s, a.ty)) != .int_lit) continue;
        const pt_raw = try s.types.substitute(try headers.paramType(s, params[slot.param]), app.cand.subst);
        const pt = try s.types.makeNotNull(try infer.zonk(s, try app.sys.close(try app.sys.open(pt_raw))));
        // A parameter left a variable for an enclosing call to fix
        // (`"a" to 1` under `Map<String, Long>`): the literal takes what it
        // is fixed to, when that is integral.
        const pending = s.types.get(pt) == .variable;
        if (!pending and !infer.isIntegral(s, pt)) continue;
        var e = a.expr;
        if (e.* == .Spread) continue;
        try ctx.addTypeEntry(.{ .file = ctx.file, .node = e.id(), .sp = e.span(), .ty = pt, .if_integral = pending });
        if (e.* == .Unary) {
            e = e.Unary.expr;
            try ctx.addTypeEntry(.{ .file = ctx.file, .node = e.id(), .sp = e.span(), .ty = pt, .if_integral = pending });
        }
        // `f(if (c) 1 else 2)` for `f(x: Long)`: each literal branch.
        if (!pending) try body.adoptLiteralBranch(ctx, e, pt);
    }
}

fn callDetail(ctx: *Ctx, app: *Applied, form: records.CallForm, ext: Receiver) Allocator.Error!*const records.CallRec {
    const s = ctx.s;
    const cand = app.cand;
    const params = candParams(s, cand);
    try adoptLiteralArgs(ctx, app, params);
    // An extension-function-type invoke's receiver is the placeholder
    // operand at 0; the written arguments follow it.
    const recv_off: usize = @intFromBool(cand.recv_arg_ty != .none);
    const srcs = try s.arena.alloc(records.ArgSource, params.len);
    const convs = try s.arena.alloc(records.Conv, params.len);
    for (params, srcs, convs, 0..) |p, *src, *cv, pi| {
        cv.* = .none;
        if (s.syms.flags(p).vararg) {
            var parts: std.ArrayList(records.VarargPart) = .empty;
            for (app.slots, app.args, 0..) |sl, a, ai| {
                if (sl.param != pi) continue;
                try parts.append(s.arena, .{ .arg = @intCast(ai - recv_off), .spread = a.spread or sl.named_array, .conv = if (app.conv.len > ai) app.conv[ai] else .none });
                if (app.conv.len > ai) cv.* = app.conv[ai];
            }
            src.* = .{ .vararg = parts.items };
            continue;
        }
        src.* = .default;
        for (app.slots, 0..) |sl, ai| {
            if (sl.param != pi) continue;
            src.* = if (ai < recv_off) .receiver else .{ .arg = @intCast(ai - recv_off) };
            if (app.conv.len > ai) cv.* = app.conv[ai];
            break;
        }
    }
    // Solved type arguments: the class's for a constructor (through an
    // alias, the expansion's), a function's own.
    var targs: std.ArrayList(TypeId) = .empty;
    if (cand.alias != .none) {
        const res = try app.sys.close(try candReturn(ctx, cand, &app.sys));
        for (s.types.argsOf(res)) |a| try targs.append(s.arena, a.ty);
    } else {
        for (try candTypeParams(s, cand)) |tp| {
            // A variable left open for the enclosing call is recorded as
            // itself; the output reads it solved.
            const t = app.sys.fixedFor(tp);
            try targs.append(s.arena, if (t != .none) t else app.sys.open_subst.get(tp) orelse s.types.errType());
        }
    }
    const rec = try s.arena.create(records.CallRec);
    rec.* = .{
        .callee = cand.sym,
        .form = form,
        .dispatch = cand.dispatch,
        .extension = ext,
        .args = srcs,
        .contexts = app.contexts,
        .type_args = targs.items,
        .conv = convs,
        .composable = s.syms.flags(cand.sym).composable or cand.composable_value,
    };
    return rec;
}

/// Whether `t` is a function type marked `@Composable`.
fn composableFunctionType(s: *Sema, t: TypeId) Allocator.Error!bool {
    return switch (s.types.get(try s.types.makeNotNull(try infer.zonk(s, t)))) {
        .class => |c| c.attrs.composable and functionShape(s, try s.types.makeNotNull(try infer.zonk(s, t))) != null,
        else => false,
    };
}

/// `t`, a function type, marked `@Composable`.
fn withComposable(s: *Sema, t: TypeId) Allocator.Error!TypeId {
    const c = switch (s.types.get(t)) {
        .class => |c| c,
        else => return t,
    };
    var attrs = c.attrs;
    attrs.composable = true;
    return s.types.classAttrs(c.sym, c.args, c.nullable, attrs);
}

/// The function type a lambda is analyzed against: parameter types as the
/// trial solution fixes them, the result left to the real system.
fn lambdaExpectation(ctx: *Ctx, trial: *infer.System, sys: *infer.System, pt: TypeId) Allocator.Error!TypeId {
    const s = ctx.s;
    const closed = try trial.close(pt);
    _ = functionShape(s, try s.types.makeNotNull(closed)) orelse return closed;
    const c = s.types.get(try s.types.makeNotNull(closed)).class;
    const orig = switch (s.types.get(try s.types.makeNotNull(pt))) {
        .class => |oc| oc,
        else => return closed,
    };
    // Keep the result position open so the lambda's own type flows into
    // it, unless what is known already fixes it: then the body's last
    // expression is analyzed against it (`{ arrayOfNulls(n) }` expected to
    // give `Array<T?>`).
    const out = try s.arena.alloc(types.Arg, c.args.len);
    @memcpy(out, c.args);
    if (out.len != 0 and orig.args.len == out.len) {
        const orig_ret = orig.args[orig.args.len - 1].ty;
        out[out.len - 1] = orig.args[orig.args.len - 1];
        // Fixed only by constraints, not by a default: a variable nothing
        // constrains yet is left open by this solve. A result below known
        // upper bounds is analyzed against them: a lower bound is only what
        // the lambda's own result joins (`builder.ifEmpty { emptyMap() }`
        // gives a `Map`, not the receiver's `MutableMap`).
        var fixed = try sys.clone();
        _ = try fixed.solve(true);
        const ret = (try fixed.upperMeet(orig_ret)) orelse try fixed.close(orig_ret);
        // Else the inputs it names are what the lambda is analyzed with
        // (`ReadOnlyProperty<T, V>` with `T` from `{ thisRef: Owner, ... }`).
        out[out.len - 1].ty = if (!infer.hasOpenVar(s, ret)) ret else try sys.closeInputs(trial, orig_ret);
    }
    return s.types.classAttrs(c.sym, out, c.nullable, c.attrs);
}

// ------------------------------------------------------------- lambdas ----

/// A lambda literal against its expected type: the parameters take the
/// expected parameter types (or `it`), a receiver lambda gets its receiver
/// as an implicit receiver, and the result is the last expression's type
/// joined with every `return@label`.
pub fn lambda(ctx: *Ctx, l: *const ast.LambdaExpr, expected_in: TypeId) Allocator.Error!TypeId {
    const s = ctx.s;
    var expected = if (expected_in != .none) try infer.zonk(s, expected_in) else .none;
    var shape: ?FnShape = null;
    var exp_args: []const types.Arg = &.{};
    var sam_ret: TypeId = .none;
    if (expected != .none) {
        const nn = try s.types.makeNotNull(expected);
        shape = functionShape(s, nn);
        if (shape != null) {
            exp_args = s.types.get(nn).class.args;
        } else if (try samType(ctx, nn)) |sam| {
            expected = sam.fn_type;
            shape = functionShape(s, sam.fn_type);
            exp_args = s.types.get(sam.fn_type).class.args;
            sam_ret = nn;
        }
    }
    if (shape == null and (expected == .none or s.types.get(try s.types.makeNotNull(expected)) == .variable or s.types.classSym(try s.types.makeNotNull(expected)) == s.builtins.any)) {
        ctx.lambda_shape_guessed = true;
    }
    const fsym = try s.syms.addFunction(.{
        .kind = .function,
        .name = wk.anonymous,
        .owner = ctx.localOwner(),
        .file = ctx.file,
        .flags = .{ .has_body = true },
        .decl = .{ .lambda = l },
        .detail = 0,
    }, .{ .state = .done });
    const sc = try ctx.push(.lambda, fsym);
    defer ctx.pop(sc);
    sc.label = try lambdaLabel(ctx, l);
    var returns: std.ArrayList(TypeId) = .empty;
    sc.lambda_returns = &returns;
    var recv: TypeId = .none;
    var param_types: std.ArrayList(TypeId) = .empty;
    var ret_expected: TypeId = .none;
    // A contextual function type's contexts are values in the literal's
    // scope that calls take context arguments from.
    var ctx_types: std.ArrayList(TypeId) = .empty;
    var ctx_syms: std.ArrayList(Sym) = .empty;
    if (shape) |sh| {
        var i: usize = sh.contexts;
        for (exp_args[0..sh.contexts]) |ca| {
            const t = try infer.zonk(s, ca.ty);
            const csym = try body.newLocal(ctx, wk.anonymous, .{ .name = "<context>", .span = l.span }, t, false);
            try sc.contexts.append(s.arena, .{ .ty = t, .sym = csym });
            try ctx_types.append(s.arena, ca.ty);
            try ctx_syms.append(s.arena, csym);
        }
        if (sh.has_receiver) {
            recv = exp_args[i].ty;
            i += 1;
        }
        while (i + 1 < exp_args.len) : (i += 1) try param_types.append(s.arena, exp_args[i].ty);
        ret_expected = exp_args[exp_args.len - 1].ty;
    }
    if (recv != .none) {
        try sc.receivers.append(s.arena, .{ .ty = try infer.zonk(s, recv), .kind = .lambda, .owner = fsym, .label = sc.label });
    }
    // Parameters: declared, destructured, `it`, or none.
    var declared_types: std.ArrayList(TypeId) = .empty;
    var param_syms: std.ArrayList(Sym) = .empty;
    var it_sym: Sym = .none;
    if (l.implicit_it) {
        // `it` exists only where one parameter is expected; with no
        // expected type or none expected, the literal takes none.
        if (param_types.items.len == 1) {
            const t = param_types.items[0];
            it_sym = try body.newLocal(ctx, wk.it, .{ .name = "it", .span = l.span }, try infer.zonk(s, t), false);
            try ctx.declareLocal(wk.it, it_sym);
            try declared_types.append(s.arena, t);
        }
    } else {
        for (l.params, 0..) |p, i| {
            var t: TypeId = if (i < param_types.items.len) param_types.items[i] else s.types.errType();
            if (i < l.param_tys.len) {
                if (l.param_tys[i]) |*tr| t = try body.resolveTypeInBody(ctx, tr);
            }
            try declared_types.append(s.arena, t);
            if (p.isPlaceholder() or std.mem.startsWith(u8, p.name, "(")) {
                try param_syms.append(s.arena, .none);
                continue;
            }
            const psym = try body.newLocal(ctx, try ctx.intern(p.name), p, try infer.zonk(s, t), false);
            try ctx.declareLocal(s.syms.name(psym), psym);
            try param_syms.append(s.arena, psym);
        }
    }
    sc.ret = ret_expected;
    const last = try lambdaBody(ctx, sc, &l.body, ret_expected);
    try returns.append(s.arena, last);
    const want_unit = sc.unit_return or (ret_expected != .none and (try infer.zonk(s, ret_expected)) == s.t.unit);
    const result = if (want_unit) s.t.unit else try body.join(ctx, returns.items, .none);
    const is_suspend = if (shape) |sh| sh.is_suspend else false;
    var ft = try s.contextFunctionType(ctx_types.items, recv, declared_types.items, result, is_suspend, false);
    // Composable when the function type it is expected as is, or when
    // written `@Composable { ... }`.
    const composable = (expected != .none and try composableFunctionType(s, expected)) or
        (s.builtins.composable != .none and l.annotations.len != 0 and try headers.annotatedWith(s, body.typeCtx(ctx), l.annotations, s.builtins.composable));
    if (composable) ft = try withComposable(s, ft);
    const rec = try s.arena.create(records.LambdaRec);
    rec.* = .{
        .func = fsym,
        .fn_type = ft,
        .sam = if (sam_ret != .none) s.types.classSym(try s.types.makeNotNull(sam_ret)) else .none,
        .params = param_syms.items,
        .it = it_sym,
        .contexts = ctx_syms.items,
        .has_receiver = recv != .none,
        .suspend_ = is_suspend,
    };
    try ctx.addRef(.{ .file = ctx.file, .anchor = l.span, .kind = .decl, .target = fsym, .detail = .{ .lambda = rec } });
    if (sam_ret != .none) return sam_ret;
    return ft;
}

fn lambdaBody(ctx: *Ctx, sc: *const body.Scope, b: *const ast.Block, ret_expected: TypeId) Allocator.Error!TypeId {
    const s = ctx.s;
    if (b.stmts.len == 0) return s.t.unit;
    return body.lambdaStatements(ctx, sc, b.stmts, ret_expected);
}

/// `label@ { ... }` names the lambda; otherwise the function it is passed
/// to does. Either was left on the context by whoever resolves the
/// literal, and is taken once.
fn lambdaLabel(ctx: *Ctx, l: *const ast.LambdaExpr) Allocator.Error!Name {
    _ = l;
    const n = ctx.lambda_label;
    ctx.lambda_label = .empty;
    return n;
}

/// The synthetic `fun Iface(function: (A) -> B): Iface` a fun interface
/// declares for SAM construction, named like the interface and declared
/// beside it.
pub fn samConstructor(ctx: *Ctx, iface: Sym) Allocator.Error!Sym {
    const s = ctx.s;
    if (s.sam_ctors.get(iface)) |f| return f;
    const self_t = try headers.selfType(s, iface);
    const sam = (try samType(ctx, self_t)) orelse {
        try s.sam_ctors.put(s.arena, iface, .none);
        return .none;
    };
    const tps = s.syms.classInfo(iface).type_params;
    const f = try s.syms.addFunction(.{
        .kind = .function,
        .name = s.syms.name(iface),
        .owner = s.syms.owner(iface),
        .file = s.syms.get(iface).file,
        .flags = .{ .synthetic = true, .has_body = true },
        .decl = .none,
        .detail = 0,
    }, .{ .type_params = tps, .ret = self_t, .state = .done, .body_done = true });
    const p = try s.syms.addParam(.{
        .kind = .value_param,
        .name = try s.names.intern("function"),
        .owner = f,
        .file = s.syms.get(iface).file,
        .flags = .{ .synthetic = true },
        .decl = .none,
        .detail = 0,
    }, .{ .ty = sam.fn_type, .state = .done });
    s.syms.functionInfo(f).params = try s.arena.dupe(Sym, &.{p});
    try s.sam_ctors.put(s.arena, iface, f);
    return f;
}

const Sam = struct { fn_type: TypeId, method: Sym };

/// A fun interface's single abstract method as a function type.
pub fn samType(ctx: *Ctx, t: TypeId) Allocator.Error!?Sam {
    const s = ctx.s;
    const c = switch (s.types.get(t)) {
        .class => |c| c,
        else => return null,
    };
    if (!s.syms.flags(c.sym).fun_iface) return null;
    return samMethod(ctx, t);
}

/// The abstract method of interface type `t`, declared on it or inherited
/// (`fun interface Style : CustomStyle<StyleScope>` takes
/// `StyleScope.applyStyle()`), as a function type seen through `t`.
fn samMethod(ctx: *Ctx, t: TypeId) Allocator.Error!?Sam {
    const s = ctx.s;
    const c = switch (s.types.get(t)) {
        .class => |c| c,
        else => return null,
    };
    const subst = try subtyping.classSubst(s, t);
    var it = s.syms.classInfo(c.sym).members.iterator();
    while (it.next()) |e| {
        for (e.value_ptr.items) |m| {
            if (s.syms.kind(m) != .function) continue;
            if (s.syms.flags(m).modality != .abstract) continue;
            try headers.functionHeader(s, m);
            const info = s.syms.functionInfo(m);
            var ps: std.ArrayList(TypeId) = .empty;
            for (info.params) |p| {
                // A vararg is the array it collects, as the lambda sees it.
                var pt = try s.types.substitute(try headers.paramType(s, p), &subst);
                if (s.syms.flags(p).vararg) pt = try varargArrayType(ctx, pt);
                try ps.append(s.arena, pt);
            }
            const recv = if (info.receiver != .none) try s.types.substitute(info.receiver, &subst) else .none;
            const ret = try s.types.substitute(try headers.returnType(s, m), &subst);
            // A method's context parameters are the function type's
            // contexts: `context(a: A) fun accept(s: String): Int` is
            // `context(A) (String) -> Int`.
            var cs: std.ArrayList(TypeId) = .empty;
            for (info.context_params) |p| try cs.append(s.arena, try s.types.substitute(try headers.paramType(s, p), &subst));
            // A `@Composable` method takes a composable lambda
            // (`TextFieldDecorator { it() }`).
            var ft = try s.contextFunctionType(cs.items, recv, ps.items, ret, s.syms.flags(m).suspend_, false);
            if (s.syms.flags(m).composable) ft = try withComposable(s, ft);
            return .{ .fn_type = ft, .method = m };
        }
    }
    for (try headers.supertypes(s, c.sym)) |st| {
        const sc = s.types.classSym(st);
        if (sc == .none or s.syms.classInfo(sc).kind != .interface) continue;
        if (try samMethod(ctx, try s.types.substitute(st, &subst))) |sam| return sam;
    }
    return null;
}

pub fn anonymousFunction(ctx: *Ctx, f: *const ast.AnonFunExpr, expected: TypeId) Allocator.Error!TypeId {
    const s = ctx.s;
    const fsym = try s.syms.addFunction(.{
        .kind = .function,
        .name = wk.anonymous,
        .owner = ctx.localOwner(),
        .file = ctx.file,
        .flags = .{ .has_body = true, .suspend_ = f.is_suspend },
        .decl = .{ .anon_fun = f },
        .detail = 0,
    }, .{ .state = .done });
    const sc = try ctx.push(.function, fsym);
    defer ctx.pop(sc);
    // `l@ fun T.() { this@l }`: a label names the function and its receiver.
    sc.label = ctx.lambda_label;
    ctx.lambda_label = .empty;
    var exp_params: []const types.Arg = &.{};
    var exp_contexts: []const types.Arg = &.{};
    var exp_recv: TypeId = .none;
    if (expected != .none) {
        const nn = try s.types.makeNotNull(try infer.zonk(s, expected));
        if (functionShape(s, nn)) |sh| {
            const a = s.types.get(nn).class.args;
            exp_contexts = a[0..sh.contexts];
            const first = sh.contexts + @intFromBool(sh.has_receiver);
            if (sh.has_receiver) exp_recv = a[sh.contexts].ty;
            exp_params = a[first .. a.len - 1];
        }
    }
    // `context(x: C) fun (...)` declares its contexts; a plain anonymous
    // function where a contextual type is expected takes them as its
    // leading parameters.
    var ctx_types: std.ArrayList(TypeId) = .empty;
    var ctx_syms: std.ArrayList(Sym) = .empty;
    for (f.context_params) |*cp| {
        const t = try body.resolveTypeInBody(ctx, &cp.ty);
        const csym = try body.newLocal(ctx, try ctx.intern(cp.name.name), cp.name, t, false);
        if (!std.mem.eql(u8, cp.name.name, "_")) try ctx.declareLocal(s.syms.name(csym), csym);
        try sc.contexts.append(s.arena, .{ .ty = t, .sym = csym });
        try ctx_types.append(s.arena, t);
        try ctx_syms.append(s.arena, csym);
    }
    if (f.context_params.len == 0 and exp_contexts.len != 0 and exp_recv == .none and f.params.len == exp_contexts.len + exp_params.len) {
        exp_params = exp_contexts.ptr[0 .. exp_contexts.len + exp_params.len];
    }
    var recv: TypeId = if (f.receiver_ty) |*tr| try body.resolveTypeInBody(ctx, tr) else exp_recv;
    recv = try infer.zonk(s, recv);
    if (recv != .none) try sc.receivers.append(s.arena, .{ .ty = recv, .kind = .extension, .owner = fsym, .label = sc.label });
    var pts: std.ArrayList(TypeId) = .empty;
    var param_syms: std.ArrayList(Sym) = .empty;
    for (f.params, 0..) |*p, i| {
        const t = if (p.ty.name.name.len != 0 or p.ty.function != null)
            try body.resolveTypeInBody(ctx, &p.ty)
        else if (i < exp_params.len) exp_params[i].ty else s.types.errType();
        try pts.append(s.arena, t);
        const psym = try body.newLocal(ctx, try ctx.intern(p.name.name), p.name, t, false);
        try ctx.declareLocal(s.syms.name(psym), psym);
        try param_syms.append(s.arena, psym);
    }
    var ret: TypeId = if (f.return_ty) |*tr| try body.resolveTypeInBody(ctx, tr) else .none;
    sc.ret = ret;
    if (f.body) |b| {
        switch (b.*) {
            .Block => |*blk| {
                _ = try body.block(ctx, blk, .none);
                if (ret == .none) ret = s.t.unit;
            },
            .Expr => |*e| {
                const t = try body.expr(ctx, e, ret);
                if (ret == .none) ret = t else try infer.noteExpected(s, t, ret);
            },
        }
    }
    const ft = try s.contextFunctionType(ctx_types.items, recv, pts.items, ret, f.is_suspend, false);
    const rec = try s.arena.create(records.LambdaRec);
    rec.* = .{
        .func = fsym,
        .fn_type = ft,
        .params = param_syms.items,
        .contexts = ctx_syms.items,
        .has_receiver = recv != .none,
        .suspend_ = f.is_suspend,
    };
    try ctx.addRef(.{ .file = ctx.file, .anchor = f.span, .kind = .decl, .target = fsym, .detail = .{ .lambda = rec } });
    return ft;
}

// --------------------------------------------------------- properties ----

pub const ExtProp = struct {
    sym: Sym,
    ty: TypeId,
    dispatch: Receiver,
    /// The declaring class's type parameters through the implicit
    /// receiver, and the property's own that its receiver fixed.
    subst: *const types.Subst = &empty_subst,
    /// The system that matched the receiver, when it constrained a
    /// variable a call infers from the enclosing lambda's body: the caller
    /// that takes the property forwards what it learned.
    sys: ?*infer.System = null,
    /// The context arguments its accessors take.
    contexts: []const Receiver = &.{},

    /// Takes the property: what matching its receiver said of a builder
    /// variable reaches the call inferring it
    /// (`this.value` on a `Buildee<T>` for `val Buildee<User>.value`).
    pub fn take(self: ExtProp) Allocator.Error!void {
        if (self.sys) |x| try x.forwardForeign();
    }
};

/// The extension property named `n` that takes a receiver of type `rt`, and
/// its type as seen through it.
pub fn extensionProperty(ctx: *Ctx, rt: TypeId, n: Name) Allocator.Error!?ExtProp {
    const s = ctx.s;
    // A member extension is seen through the implicit receiver declaring
    // it: its class's type parameters are that receiver's arguments
    // (`val T.foo` of a `Test<String>` extends a `String`).
    const Candidate = struct { sym: Sym, subst: *const types.Subst, dispatch: Receiver, tier: u16 };
    var candidates: std.ArrayList(Candidate) = .empty;
    var tier: u16 = 0;
    for (try body.implicitReceivers(ctx)) |r| {
        for (try members.lookup(s, try body.narrowedReceiver(ctx, r), n, .property)) |m| {
            if (s.syms.kind(m.sym) != .property) continue;
            try headers.propertyHeader(s, m.sym);
            if (s.syms.propertyInfo(m.sym).receiver == .none) continue;
            try candidates.append(s.arena, .{ .sym = m.sym, .subst = m.subst, .dispatch = .{ .implicit = .{ .kind = r.kind, .owner = r.owner } }, .tier = tier });
        }
        tier += 1;
    }
    for (try topLevelTiers(ctx, n)) |top| {
        for (top) |m| {
            if (s.syms.kind(m) != .property) continue;
            try headers.propertyHeader(s, m);
            if (s.syms.propertyInfo(m).receiver == .none) continue;
            // `import Duration.Companion.seconds`: read on the companion.
            try candidates.append(s.arena, .{ .sym = m, .subst = importedSubst(ctx, m), .dispatch = importedOwner(ctx, m), .tier = tier });
        }
        tier += 1;
    }
    // The first tier with a property that takes the receiver; of several
    // there, the one whose receiver is most specific (`D.attr` over
    // `C.attr` on a `D` that extends `C`).
    var best: ?ExtProp = null;
    var best_recv: TypeId = .none;
    var best_tier: u16 = 0;
    for (candidates.items) |c| {
        if (best != null and c.tier != best_tier) break;
        const info = s.syms.propertyInfo(c.sym);
        const sys = try s.arena.create(infer.System);
        sys.* = infer.System.init(s);
        try sys.addTypeParams(info.type_params);
        const recv = try sys.open(try s.types.substitute(info.receiver, c.subst));
        if (!try sys.constrain(rt, recv)) continue;
        if (!try sys.solve(false)) continue;
        const cx = (try propertyContexts(ctx, c.sym, c.subst)) orelse continue;
        const closed_recv = try sys.close(recv);
        if (best != null and !(try subtyping.isSubtype(s, closed_recv, best_recv) and !try subtyping.isSubtype(s, best_recv, closed_recv))) continue;
        const t = try sys.close(try sys.open(try s.types.substitute(try headers.propertyType(s, c.sym), c.subst)));
        best = .{ .sym = c.sym, .ty = t, .dispatch = c.dispatch, .subst = try withFixed(s, sys, info.type_params, c.subst), .sys = if (sys.hasForeign()) sys else null, .contexts = cx };
        best_recv = closed_recv;
        best_tier = c.tier;
    }
    return best;
}

/// A non-extension top-level property named `n` by import precedence.
/// A property whose context parameters have no value in scope is not
/// one the access can name: `b` is the plain `val b`, not the
/// `context(a: A) val b`, where no `A` is in scope.
pub fn topLevelProperty(ctx: *Ctx, n: Name) Allocator.Error!?Sym {
    const s = ctx.s;
    for (try topLevelTiers(ctx, n)) |tier| {
        for (tier) |m| {
            if (s.syms.kind(m) != .property) continue;
            try headers.propertyHeader(s, m);
            if (s.syms.propertyInfo(m).receiver != .none) continue;
            if ((try propertyContexts(ctx, m, &empty_subst)) == null) continue;
            return m;
        }
    }
    return null;
}

pub fn packageProperty(ctx: *Ctx, pkg: Sym, n: Name) Allocator.Error!?Sym {
    const s = ctx.s;
    for (scope_mod.membersOf(s, pkg, n)) |m| {
        if (s.syms.kind(m) != .property or !scope_mod.visible(s, m)) continue;
        try headers.propertyHeader(s, m);
        if (s.syms.propertyInfo(m).receiver != .none) continue;
        if ((try propertyContexts(ctx, m, &empty_subst)) == null) continue;
        return m;
    }
    return null;
}

/// The context arguments an access of property `p` passes its getter or
/// setter, one per context parameter, each the implicit value in scope that
/// a call's would be; null when one has none. `subst` is what the
/// declaring class's type parameters are through the receiver.
pub fn propertyContexts(ctx: *Ctx, p: Sym, subst: *const types.Subst) Allocator.Error!?[]const Receiver {
    const s = ctx.s;
    if (s.syms.kind(p) != .property) return &.{};
    try headers.propertyHeader(s, p);
    const info = s.syms.propertyInfo(p);
    if (info.context_params.len == 0) return &.{};
    var sys = infer.System.init(s);
    try sys.addTypeParams(info.type_params);
    const out = try s.arena.alloc(Receiver, info.context_params.len);
    for (info.context_params, out) |cp, *o| {
        const want = try sys.open(try s.types.substitute(try headers.paramType(s, cp), subst));
        o.* = (try contextArgument(ctx, &sys, want)) orelse return null;
    }
    return out;
}

/// `recv.name` on a value of type `t`: a member property, then an
/// extension property. Records the reference.
pub fn propertyAccess(ctx: *Ctx, t_in: TypeId, n: Name, sp: Span, access: body.Access, recv: Receiver) Allocator.Error!TypeId {
    const s = ctx.s;
    const lit = try literalReceiver(s, t_in);
    const t = try s.types.makeNotNull(lit);
    const kind: RefKind = if (access == .write) .write else .read;
    if (s.types.isErr(t)) {
        try ctx.report(.receiver_unresolved, sp, "{s}", .{s.str(n)});
        return s.types.errType();
    }
    // A receiver that may be null reaches a member only through `?.`, so an
    // extension on the nullable type is the one it reads (`Data?.weight`
    // beside the member `weight`). The caller passes a `?.` receiver's
    // type as not null.
    if (try subtyping.admitsNull(s, lit)) if (try extensionProperty(ctx, lit, n)) |ext| {
        try ext.take();
        try ctx.addRef(.{ .file = ctx.file, .anchor = sp, .kind = kind, .target = ext.sym, .extension = recv, .dispatch = ext.dispatch, .contexts = ext.contexts });
        return ext.ty;
    };
    const ms = try members.withoutExtensionProperties(s, try members.lookup(s, t, n, .property));
    if (ms.len != 0) {
        const m = ms[0];
        const cx = (try propertyContexts(ctx, m.sym, m.subst)) orelse &.{};
        try ctx.addRef(.{ .file = ctx.file, .anchor = sp, .kind = if (s.syms.kind(m.sym) == .enum_entry) .object else kind, .target = m.sym, .dispatch = recv, .contexts = cx });
        return members.memberType(s, m);
    }
    if (try extensionProperty(ctx, t, n)) |ext| {
        try ext.take();
        try ctx.addRef(.{ .file = ctx.file, .anchor = sp, .kind = kind, .target = ext.sym, .extension = recv, .dispatch = ext.dispatch, .contexts = ext.contexts });
        return ext.ty;
    }
    try ctx.reportFacts(.unresolved_member, sp, .{ .name = s.str(n), .on = try sema_mod.diagnose.typeText(s, s.arena, t) }, "{s}.{s}", .{ try sema_mod.render.typeStr(s, s.arena, t), s.str(n) });
    return s.types.errType();
}

/// A member or extension property `n` on `t` read by a destructuring by
/// name.
pub fn propertyOn(ctx: *Ctx, t: TypeId, n: Name, sp: Span) Allocator.Error!TypeId {
    return propertyAccess(ctx, t, n, sp, .read, .expr);
}

// ----------------------------------------------------------- operators ----

/// An integer literal used as a receiver takes its default type.
pub fn literalReceiver(s: *Sema, t: TypeId) Allocator.Error!TypeId {
    return switch (s.types.get(t)) {
        .int_lit => |l| infer.intLitDefault(s, l),
        else => t,
    };
}

/// An operator convention on a receiver of type `rt`: the `operator`
/// members named `n`, then `operator` extensions. Records the reference at
/// `anchor` with `kind`.
pub fn operatorCall(ctx: *Ctx, anchor: Span, rt_in: TypeId, n: Name, pre_args: []const Arg, kind: RefKind) Allocator.Error!TypeId {
    return operatorCallExpecting(ctx, anchor, rt_in, n, pre_args, kind, .none);
}

/// `operatorCall` whose result is expected to be `expected`, which
/// constrains the candidate's type parameters as a call's expected type
/// does: a delegate's `getValue` takes the property's type (`val n: Int by
/// map` makes `Map.getValue`'s `V1` an `Int`).
pub fn operatorCallExpecting(ctx: *Ctx, anchor: Span, rt_in: TypeId, n: Name, pre_args: []const Arg, kind: RefKind, expected: TypeId) Allocator.Error!TypeId {
    const s = ctx.s;
    const rt = try literalReceiver(s, rt_in);
    if (s.types.isErr(rt)) {
        try ctx.failNode(anchor);
        return s.types.errType();
    }
    const args = try s.arena.dupe(Arg, pre_args);
    var levels: std.ArrayList(Level) = .empty;
    var member_level = newLevel();
    // As for a call: a receiver that may be null reaches only extensions
    // (`String?.plus`).
    const members_apply = !try subtyping.admitsNull(s, rt);
    if (members_apply) for (try members.lookup(s, rt, n, .function)) |m| {
        if (!try members.isOperator(s, m.sym)) continue;
        try headers.functionHeader(s, m.sym);
        if (s.syms.functionInfo(m.sym).receiver != .none) continue;
        try member_level.append(s.arena, .{ .sym = m.sym, .subst = m.subst, .dispatch = .expr });
    };
    if (member_level.items.len != 0) try levels.append(s.arena, member_level);
    try appendExtensionLevels(ctx, &levels, n, .expr, rt, true);
    var low_level: ?[]Applied = null;
    for (levels.items, 0..) |level, li| {
        var applicable: std.ArrayList(Applied) = .empty;
        for (level.items) |cand| {
            // An indexed assignment's value binds to `set`'s last
            // parameter, as a trailing lambda does, whatever the
            // parameters before it default or absorb.
            if (try check(ctx, cand, args, kind == .set, &.{}, expected)) |ap| try applicable.append(s.arena, ap);
        }
        if (applicable.items.len != 0) {
            try dropLowPriority(ctx, &applicable);
            if (try onlyLowPriority(ctx, applicable.items)) {
                if (low_level == null) low_level = applicable.items;
                applicable.clearRetainingCapacity();
            }
        }
        const last = li + 1 == levels.items.len;
        if (applicable.items.len == 0 and last) if (low_level) |l| {
            applicable = .fromOwnedSlice(l);
        };
        if (applicable.items.len == 0) continue;
        const chosen = try mostSpecific(ctx, applicable.items, args);
        var app = applicable.items[chosen.index];
        for (app.args, app.slots) |*a, slot| {
            if (!a.postponed) continue;
            try postponedArg(ctx, &app, a, slot, n);
        }
        _ = try app.sys.solve(false);
        try app.sys.forwardForeign();
        const ret = try app.sys.close(try candReturn(ctx, app.cand, &app.sys));
        try ctx.addRef(.{ .file = ctx.file, .anchor = anchor, .kind = kind, .op = n, .target = app.cand.sym, .dispatch = app.cand.dispatch, .extension = app.cand.extension, .contexts = app.contexts, .detail = .{ .call = try callDetail(ctx, &app, .plain, app.cand.extension) } });
        return ret;
    }
    for (args) |a| if (a.postponed) {
        _ = try body.expr(ctx, a.expr, .none);
    };
    try ctx.reportFacts(.unresolved_operator, anchor, .{ .name = s.str(n), .on = try sema_mod.diagnose.typeText(s, s.arena, rt), .arg_types = try argTypes(ctx, args) }, "{s}.{s}({s})", .{ try sema_mod.render.typeStr(s, s.arena, rt), s.str(n), try argTypesText(ctx, args) });
    return s.types.errType();
}

/// A binary operator's right operand as its argument when it is a call
/// with a lambda, prepared like a call's argument so it can wait for the
/// operator's parameter (`ops + ops.map { Op(...) { ... } }`); null for
/// any other operand.
pub fn lambdaCallOperand(ctx: *Ctx, rhs: *const Expr) Allocator.Error!?[]Arg {
    if (!callHasLambda(rhs)) return null;
    return try prepareArgs(ctx, @as([*]const Expr, @ptrCast(rhs))[0..1], &.{});
}

pub fn indexGet(ctx: *Ctx, e: *const Expr, recv: *const Expr, idx: []const Expr) Allocator.Error!TypeId {
    const rt = try body.receiverExpr(ctx, recv);
    const args = try prepareArgs(ctx, idx, &.{});
    return operatorCall(ctx, e.span(), rt, wk.get, args, .get);
}

pub fn indexSet(ctx: *Ctx, target: *const Expr, recv: *const Expr, idx: []const Expr, value: *const Expr) Allocator.Error!TypeId {
    const s = ctx.s;
    const rt = try body.receiverExpr(ctx, recv);
    const iargs = try prepareArgs(ctx, idx, &.{});
    // The value is `set`'s last argument, prepared like any other: a lambda
    // is analyzed once, against the chosen `set`'s parameter.
    const vargs = try prepareArgs(ctx, @as([*]const Expr, @ptrCast(value))[0..1], &.{});
    const args = try s.arena.alloc(Arg, iargs.len + 1);
    @memcpy(args[0..iargs.len], iargs);
    args[iargs.len] = vargs[0];
    return operatorCall(ctx, target.span(), rt, wk.set, args, .set);
}

/// `a op= b`: `opAssign` when the target's type declares it, else
/// `a = a op b`.
pub fn compoundAssign(ctx: *Ctx, a: *const ast.AssignStmt) Allocator.Error!void {
    const s = ctx.s;
    const op_name: Name = switch (a.op) {
        .Add => wk.plus,
        .Sub => wk.minus,
        .Mul => wk.times,
        .Div => wk.div,
        .Rem => wk.rem,
        .Assign => unreachable,
    };
    const assign_name: Name = switch (a.op) {
        .Add => wk.plusAssign,
        .Sub => wk.minusAssign,
        .Mul => wk.timesAssign,
        .Div => wk.divAssign,
        .Rem => wk.remAssign,
        .Assign => unreachable,
    };
    const target = try readTarget(ctx, &a.target);
    // A lambda (`handlers += { x -> ... }`) waits for the operator's
    // parameter type, as a lambda argument does.
    const args: []const Arg = switch (a.value) {
        .Lambda, .AnonFun, .PropertyRef, .MemberRef => try prepareArgs(ctx, @as([*]const Expr, @ptrCast(&a.value))[0..1], &.{}),
        else => blk: {
            const saved = ctx.in_arg;
            ctx.in_arg = .branch;
            const vt = try body.expr(ctx, &a.value, .none);
            ctx.in_arg = saved;
            const one = try ctx.arena().alloc(Arg, 1);
            one[0] = .{ .expr = &a.value, .ty = vt };
            break :blk one;
        },
    };
    // `plusAssign` wins when it exists.
    if (try hasOperator(ctx, target.ty, assign_name)) {
        _ = try operatorCall(ctx, a.span, target.ty, assign_name, args, .op_assign);
        return;
    }
    const result = try operatorCall(ctx, a.span, target.ty, op_name, args, .op);
    try writeTarget(ctx, &a.target, target, &a.value, result);
    _ = s;
}

/// An assignment target resolved once: its receiver, its index arguments,
/// and the type its read gives.
const Target = struct {
    ty: TypeId,
    recv_t: TypeId = .none,
    index_args: []Arg = &.{},
};

/// Reads a compound target (`x`, `a.x`, `a[i]`), resolving its receiver
/// and index arguments once.
fn readTarget(ctx: *Ctx, target: *const Expr) Allocator.Error!Target {
    switch (target.*) {
        .Index => |ix| {
            const rt = try body.receiverExpr(ctx, ix.receiver);
            const iargs = try prepareArgs(ctx, ix.args, &.{});
            const t = try operatorCall(ctx, target.span(), rt, wk.get, iargs, .get);
            return .{ .ty = t, .recv_t = rt, .index_args = iargs };
        },
        .Member => |m| {
            if (try body.asQualifier(ctx, m.receiver) == null and m.receiver.* != .Super) {
                const recv_t = try body.receiverExpr(ctx, m.receiver);
                const rt = if (m.safe) try ctx.s.types.makeNotNull(recv_t) else recv_t;
                const n = try ctx.intern(m.name.name);
                const t = try propertyAccess(ctx, rt, n, m.name.span, .read, .expr);
                return .{ .ty = t, .recv_t = rt };
            }
            return .{ .ty = try body.expr(ctx, target, .none) };
        },
        else => return .{ .ty = try body.expr(ctx, target, .none) },
    }
}

/// Writes a compound target read by `readTarget`, reusing its receiver.
fn writeTarget(ctx: *Ctx, target: *const Expr, read: Target, value: *const Expr, value_t: TypeId) Allocator.Error!void {
    const s = ctx.s;
    switch (target.*) {
        .Index => {
            var sargs = try s.arena.alloc(Arg, read.index_args.len + 1);
            @memcpy(sargs[0..read.index_args.len], read.index_args);
            sargs[read.index_args.len] = .{ .expr = value, .ty = value_t };
            _ = try operatorCall(ctx, target.span(), read.recv_t, wk.set, sargs, .set);
        },
        .Member => |m| {
            if (read.recv_t != .none) {
                _ = try propertyAccess(ctx, read.recv_t, try ctx.intern(m.name.name), m.name.span, .write, .expr);
            } else {
                _ = try body.assignTarget(ctx, target);
            }
        },
        else => _ = try body.assignTarget(ctx, target),
    }
}

fn hasOperator(ctx: *Ctx, t: TypeId, n: Name) Allocator.Error!bool {
    const s = ctx.s;
    if (s.types.isErr(t)) return false;
    for (try members.lookup(s, t, n, .function)) |m| {
        if (try members.isOperator(s, m.sym)) return true;
    }
    for (try extensionFunctions(ctx, n)) |x| {
        if (!try members.isOperator(s, x.sym)) continue;
        const info = s.syms.functionInfo(x.sym);
        var sys = infer.System.init(s);
        try sys.addTypeParams(info.type_params);
        // Its type parameters' bounds too: `P.provideDelegate` for a
        // `P : MyClass` is no operator of a `String`.
        if (!try sys.addDeclaredBounds(info.type_params, x.subst)) continue;
        if (try sys.constrain(t, try sys.open(try s.types.substitute(info.receiver, x.subst)))) return true;
    }
    return false;
}

pub fn unary(ctx: *Ctx, e: *const Expr, op: ast.UnOp, operand: *const Expr, expected: TypeId) Allocator.Error!TypeId {
    switch (op) {
        .PreInc => return incDec(ctx, e, operand, true, false),
        .PreDec => return incDec(ctx, e, operand, false, false),
        else => {},
    }
    // `-1` and `+1` are literals, not calls: typed by their signed value
    // (`-2147483648` is an `Int`) and what is expected of them.
    if ((op == .Neg or op == .Pos) and operand.* == .IntLit and operand.IntLit.kind != .Long) {
        return body.signedLiteral(ctx, operand, op == .Neg, expected);
    }
    const t = try body.receiverExpr(ctx, operand);
    const n: Name = switch (op) {
        .Neg => wk.unaryMinus,
        .Pos => wk.unaryPlus,
        .Not => wk.not,
        else => unreachable,
    };
    return operatorCall(ctx, e.span(), t, n, &.{}, .op);
}

/// `!x` in a condition, `x` of type `operand_t`: its `not`.
pub fn notRef(ctx: *Ctx, e: *const Expr, operand_t: TypeId) Allocator.Error!TypeId {
    return operatorCall(ctx, e.span(), operand_t, wk.not, &.{}, .op);
}

/// `x++`, `x--`, `++x`, `--x`: `inc`/`dec` on the operand, written back.
pub fn incDec(ctx: *Ctx, e: *const Expr, operand: *const Expr, inc: bool, postfix: bool) Allocator.Error!TypeId {
    _ = postfix;
    const target = try readTarget(ctx, operand);
    const r = try operatorCall(ctx, e.span(), target.ty, if (inc) wk.inc else wk.dec, &.{}, if (inc) .inc else .dec);
    try writeTarget(ctx, operand, target, operand, r);
    return target.ty;
}

/// `x in c`: `c.contains(x)`.
pub fn containsCall(ctx: *Ctx, anchor: Span, container_t: TypeId, elem_t: TypeId) Allocator.Error!TypeId {
    const dummy = try ctx.arena().create(Expr);
    dummy.* = .{ .NullLit = .{ .span = anchor } };
    return operatorCall(ctx, anchor, container_t, wk.contains, &.{.{ .expr = dummy, .ty = elem_t }}, .contains);
}

/// `elem in c` with `elem` written as an expression: `c.contains(elem)`,
/// `elem` the argument, so a literal takes its parameter's type.
pub fn containsArgCall(ctx: *Ctx, anchor: Span, container_t: TypeId, elem: *const Expr, elem_t: TypeId) Allocator.Error!TypeId {
    return operatorCall(ctx, anchor, container_t, wk.contains, &.{.{ .expr = elem, .ty = elem_t }}, .contains);
}

/// `a == b` resolves to `equals` on `a`'s type.
pub fn equalsRef(ctx: *Ctx, anchor: Span, lhs_t: TypeId) Allocator.Error!void {
    const s = ctx.s;
    if (s.types.isErr(lhs_t)) return ctx.failNode(anchor);
    const t = try s.types.makeNotNull(try literalReceiver(s, lhs_t));
    const ms = try members.lookup(s, if (s.types.get(t) == .class or s.types.get(t) == .param) t else s.t.any, wk.equals, .function);
    for (ms) |m| {
        const ps = s.syms.functionInfo(m.sym).params;
        if (ps.len != 1) continue;
        // The other side (the right operand, or the `when` subject's
        // pattern value) is operand 0.
        const rec = try s.arena.create(records.CallRec);
        rec.* = .{ .callee = m.sym, .form = .plain, .dispatch = .expr, .args = try s.arena.dupe(records.ArgSource, &.{.{ .arg = 0 }}), .conv = try s.arena.dupe(records.Conv, &.{.none}) };
        try ctx.addRef(.{ .file = ctx.file, .anchor = anchor, .kind = .equals, .target = m.sym, .dispatch = .expr, .detail = .{ .call = rec } });
        return;
    }
}

/// `for (x in c)`: `c.iterator()`, then `hasNext()` and `next()` on the
/// iterator. Returns the element type.
pub fn iteration(ctx: *Ctx, anchor: Span, t: TypeId) Allocator.Error!TypeId {
    const s = ctx.s;
    const it_t = try operatorCall(ctx, anchor, t, wk.iterator, &.{}, .iterator);
    if (s.types.isErr(it_t)) return it_t;
    _ = try operatorCall(ctx, anchor, it_t, wk.hasNext, &.{}, .has_next);
    return operatorCall(ctx, anchor, it_t, wk.next, &.{}, .next);
}

/// `componentN()` on a destructured value.
pub fn componentCall(ctx: *Ctx, t: TypeId, n: usize, entry_span: Span, anchor: Span) Allocator.Error!TypeId {
    _ = anchor;
    const name = try ctx.s.names.component(n);
    return operatorCall(ctx, entry_span, t, name, &.{}, .component);
}

/// A delegated property: `provideDelegate` when the delegate declares it,
/// then `getValue` (and `setValue` for a `var`). Returns the value type.
/// `host` is `provideDelegate`'s `thisRef`: the instance declaring the
/// property, which makes the delegate before any extension receiver
/// exists (`val Long.x by d()` in `object O` provides with `O`, gets with
/// the `Long`).
pub fn delegateAccess(ctx: *Ctx, del: *const Expr, del_t_in: TypeId, prop: Sym, mutable: bool, host: TypeId) Allocator.Error!TypeId {
    const s = ctx.s;
    var del_t = del_t_in;
    const anchor = del.span();
    const dummy = try ctx.arena().create(Expr);
    dummy.* = .{ .NullLit = .{ .span = anchor } };
    const this_ref = try thisRefType(ctx);
    const kprop = if (s.builtins.kproperty0 != .none) try s.types.class(s.builtins.kproperty0, &.{.{ .variance = .star, .ty = .none }}, false) else s.types.errType();
    const pd_args = [_]Arg{ .{ .expr = dummy, .ty = this_ref }, .{ .expr = dummy, .ty = kprop } };
    const provide_args = [_]Arg{ .{ .expr = dummy, .ty = host }, .{ .expr = dummy, .ty = kprop } };
    if (try hasOperator(ctx, del_t, wk.provideDelegate)) {
        del_t = try operatorCall(ctx, anchor, del_t, wk.provideDelegate, &provide_args, .provide_delegate);
    }
    const declared: TypeId = switch (s.syms.kind(prop)) {
        .property => s.syms.propertyInfo(prop).ty,
        .local => s.syms.localInfo(prop).ty,
        else => .none,
    };
    const vt = try operatorCallExpecting(ctx, anchor, del_t, wk.getValue, &pd_args, .get_value, declared);
    if (mutable) {
        const value_t = if (s.syms.kind(prop) == .property) s.syms.propertyInfo(prop).ty else vt;
        const set_args = [_]Arg{ .{ .expr = dummy, .ty = this_ref }, .{ .expr = dummy, .ty = kprop }, .{ .expr = dummy, .ty = if (value_t != .none) value_t else vt } };
        _ = try operatorCall(ctx, anchor, del_t, wk.setValue, &set_args, .set_value);
    }
    return vt;
}

/// The type `getValue` gives on a delegate of type `del_t` whose type
/// arguments may still be open in `sys`, which takes in the chosen
/// candidate's own variables and what the property's owner, `this_ref`,
/// passed as its `thisRef` says of them (`ReadOnlyProperty { ... }` is a
/// `ReadOnlyProperty` of the class declaring the property). A delegate
/// with a `provideDelegate` is first what that returns: `val v: String by
/// delegate()` for a `delegate<V>()` whose `provideDelegate` returns a
/// `Lazy<V>` makes `V` a `String`. Null when no candidate takes the
/// delegate.
pub fn delegateValueType(ctx: *Ctx, sys: *infer.System, del_t: TypeId, this_ref: TypeId) Allocator.Error!?TypeId {
    const provided = (try operatorResultIn(ctx, sys, del_t, wk.provideDelegate, this_ref)) orelse del_t;
    return operatorResultIn(ctx, sys, provided, wk.getValue, this_ref);
}

/// What the operator `n` (`getValue`, `provideDelegate`) returns on a
/// receiver of type `recv_t` in `sys`, its first parameter taking
/// `this_ref` when it can. Null when no operator of that name takes the
/// receiver.
fn operatorResultIn(ctx: *Ctx, sys: *infer.System, recv_t: TypeId, n: Name, this_ref: TypeId) Allocator.Error!?TypeId {
    const s = ctx.s;
    for (try members.lookup(s, recv_t, n, .function)) |m| {
        if (!try members.isOperator(s, m.sym)) continue;
        try headers.functionHeader(s, m.sym);
        const fi = s.syms.functionInfo(m.sym);
        var trial = try sys.clone();
        trial.trial = false;
        try trial.addTypeParams(fi.type_params);
        if (fi.params.len != 0) {
            const pt = try trial.open(try s.types.substitute(try headers.paramType(s, fi.params[0]), m.subst));
            var probe = try trial.clone();
            if (try probe.constrain(this_ref, pt)) _ = try trial.constrain(this_ref, pt);
        }
        const ret = try trial.open(try s.types.substitute(fi.ret, m.subst));
        sys.* = trial;
        return ret;
    }
    for (try extensionFunctions(ctx, n)) |x| {
        if (!try members.isOperator(s, x.sym)) continue;
        try headers.functionHeader(s, x.sym);
        const fi = s.syms.functionInfo(x.sym);
        if (fi.receiver == .none) continue;
        // `State<T>.getValue` on a `MutableState<?1>`: the extension's own
        // type parameters written as the receiver's arguments are the
        // delegate's arguments, so the result speaks of `?1` itself.
        if (try receiverBinding(s, fi, x.subst, recv_t)) |sub| {
            return try s.types.substitute(try s.types.substitute(fi.ret, x.subst), sub);
        }
        var trial = try sys.clone();
        trial.trial = false;
        try trial.addTypeParams(fi.type_params);
        if (!try trial.constrain(recv_t, try trial.open(try s.types.substitute(fi.receiver, x.subst)))) continue;
        if (fi.params.len != 0) {
            const pt = try trial.open(try s.types.substitute(try headers.paramType(s, fi.params[0]), x.subst));
            var probe = try trial.clone();
            if (try probe.constrain(this_ref, pt)) _ = try trial.constrain(this_ref, pt);
        }
        const ret = try trial.open(try s.types.substitute(fi.ret, x.subst));
        sys.* = trial;
        return ret;
    }
    return null;
}

/// The extension's type parameters bound by matching its receiver
/// `C<T, ...>` against `t`'s supertype of class `C`, when every one the
/// result mentions is a bare argument there.
fn receiverBinding(s: *Sema, fi: *const symbols.FunctionInfo, subst: *const types.Subst, t: TypeId) Allocator.Error!?*const types.Subst {
    const recv = try s.types.substitute(fi.receiver, subst);
    const rc = switch (s.types.get(try s.types.makeNotNull(recv))) {
        .class => |c| c,
        else => return null,
    };
    const sup = (try subtyping.supertypeWithClass(s, try s.types.makeNotNull(t), rc.sym)) orelse return null;
    const sc = switch (s.types.get(sup)) {
        .class => |c| c,
        else => return null,
    };
    if (sc.args.len != rc.args.len) return null;
    const out = try s.arena.create(types.Subst);
    out.* = .empty;
    for (rc.args, sc.args) |ra, sa| {
        if (ra.variance == .star or sa.variance == .star) continue;
        switch (s.types.get(ra.ty)) {
            .param => |p| {
                for (fi.type_params) |tp| if (tp == p.sym) try out.put(s.arena, tp, sa.ty);
            },
            else => {},
        }
    }
    for (fi.type_params) |tp| if (!out.contains(tp)) return null;
    return out;
}

pub fn thisRefType(ctx: *Ctx) Allocator.Error!TypeId {
    const r = (try body.thisReceiver(ctx, null)) orelse return ctx.s.t.nothing_q;
    return r.ty;
}

// ----------------------------------------------------- constructors ----

/// `: Base(args)` in a class header, or an enum entry's arguments.
pub fn superTypeCall(ctx: *Ctx, st: TypeId, anchor: Span, arg_exprs: []const Expr, arg_names: []const ?[]const u8) Allocator.Error!TypeId {
    const s = ctx.s;
    const cls = s.types.classSym(st);
    if (cls == .none) return s.types.errType();
    const args = try prepareArgs(ctx, arg_exprs, arg_names);
    var level = newLevel();
    try appendCtors(ctx, &level, cls, .none);
    // The written supertype fixes the class's type arguments; the
    // constructor runs on the instance being made.
    for (level.items) |*c| {
        c.ctor_result = st;
        c.form = .super_delegation;
    }
    var levels = [_]Level{level};
    const id = ast.Ident{ .name = s.str(s.syms.name(cls)), .span = anchor };
    return resolveLevels(ctx, if (level.items.len != 0) levels[0..] else levels[0..0], id, args, false, try writtenTypeArgs(ctx, st), st);
}

/// The type arguments a written class type gives its constructor call:
/// `: Base<E>()` pins `Base`'s parameters. A star projection pins nothing.
fn writtenTypeArgs(ctx: *Ctx, t: TypeId) Allocator.Error![]const TypeId {
    const s = ctx.s;
    const c = switch (s.types.get(t)) {
        .class => |c| c,
        else => return &.{},
    };
    // An inner class's type also carries its outer class's arguments,
    // which the outer instance supplies, not the call.
    const own = @min(c.args.len, s.syms.classInfo(c.sym).type_params.len);
    if (own == 0) return &.{};
    const out = try s.arena.alloc(TypeId, own);
    for (c.args[0..own], out) |a, *o| {
        if (a.variance == .star) return &.{};
        o.* = a.ty;
    }
    return out;
}

/// `this(args)` or `super(args)` from a secondary constructor.
pub fn delegationCall(ctx: *Ctx, cls: Sym, anchor: Span, arg_exprs: []const Expr, arg_names: []const ?[]const u8, is_super: bool) Allocator.Error!TypeId {
    const s = ctx.s;
    const args = try prepareArgs(ctx, arg_exprs, arg_names);
    var level = newLevel();
    try appendCtors(ctx, &level, cls, .none);
    for (level.items) |*c| c.form = if (is_super) .super_delegation else .this_delegation;
    var levels = [_]Level{level};
    const id = ast.Ident{ .name = s.str(s.syms.name(cls)), .span = anchor };
    // `this(...)` keeps the class's own type parameters; `super(...)` takes
    // the arguments the class header wrote for its superclass.
    const target_t: TypeId = if (is_super) blk: {
        const owner = ctx.scope.owner;
        const own_cls = if (owner != .none and s.syms.kind(owner) == .constructor) s.syms.owner(owner) else .none;
        if (own_cls == .none) break :blk .none;
        for (try headers.supertypes(s, own_cls)) |st| {
            if (s.types.classSym(st) == cls) break :blk st;
        }
        break :blk .none;
    } else try headers.selfType(s, cls);
    const pinned = if (target_t != .none) try writtenTypeArgs(ctx, target_t) else &.{};
    return resolveLevels(ctx, if (level.items.len != 0) levels[0..] else levels[0..0], id, args, false, pinned, .none);
}

// ------------------------------------------------------------- super ----

/// Whether class scope `c` is its class's header, resolved without the
/// instance: its own `this` is taken out while the header resolves.
fn inHeader(c: *const body.Scope) bool {
    if (c.static_only) return false;
    for (c.receivers.items) |r| {
        if (r.owner == c.owner and (r.kind == .class_this or r.kind == .object)) return false;
    }
    return true;
}

fn superTarget(ctx: *Ctx, sp: *const ast.SuperExpr) Allocator.Error!?struct { ty: TypeId, owner: Sym } {
    const s = ctx.s;
    // `super@Outer`: the named class's supertypes; else the innermost
    // class's.
    var cls: Sym = .none;
    var sc: ?*body.Scope = ctx.scope;
    while (sc) |c| : (sc = c.parent) {
        if (c.kind != .class) continue;
        if (sp.label) |l| {
            if (!std.mem.eql(u8, s.str(s.syms.name(c.owner)), l.name)) continue;
        } else if (inHeader(c)) {
            // A class's header runs before its instance exists: `super`
            // there is the enclosing class's (`object : A by
            // super.createA()`).
            continue;
        }
        cls = c.owner;
        break;
    }
    if (cls == .none) return null;
    const sts = try headers.supertypes(s, cls);
    if (sp.qualifier) |*q| {
        const qt = try body.resolveTypeInBody(ctx, q);
        const qc = s.types.classSym(qt);
        for (sts) |st| if (s.types.classSym(st) == qc) return .{ .ty = st, .owner = cls };
        return .{ .ty = qt, .owner = cls };
    }
    // The class supertype when there is one, else the only interface.
    for (sts) |st| {
        const c = s.types.classSym(st);
        if (c != .none and s.syms.classInfo(c).kind != .interface) return .{ .ty = st, .owner = cls };
    }
    if (sts.len != 0) return .{ .ty = sts[0], .owner = cls };
    return null;
}

pub fn superMember(ctx: *Ctx, sp: *const ast.SuperExpr, name: ast.Ident, access: body.Access) Allocator.Error!TypeId {
    const s = ctx.s;
    const tgt = (try superTarget(ctx, sp)) orelse {
        try ctx.report(.unresolved_receiver, sp.span, "super", .{});
        return s.types.errType();
    };
    const n = try ctx.intern(name.name);
    // Unqualified, the supertype that implements the property: the
    // superclass, or the one interface that does when the superclass
    // does not (`super.p` for an interface's `val p get() = ...`).
    var ty = tgt.ty;
    if (sp.qualifier == null) {
        var found: TypeId = .none;
        var count: usize = 0;
        for (try headers.supertypes(s, tgt.owner)) |st| {
            for (try members.lookup(s, st, n, .property)) |m| {
                if (s.syms.flags(m.sym).modality == .abstract) continue;
                count += 1;
                found = st;
                break;
            }
        }
        if (count == 1) ty = found;
    }
    return propertyAccess(ctx, ty, n, name.span, access, .{ .implicit = .{ .kind = .super_, .owner = tgt.owner } });
}

fn superCall(ctx: *Ctx, sp: *const ast.SuperExpr, name: ast.Ident, args: []Arg, trailing: bool, type_args: []const TypeId, expected: TypeId) Allocator.Error!TypeId {
    const s = ctx.s;
    const tgt = (try superTarget(ctx, sp)) orelse {
        try finishArgsBlind(ctx, args);
        try ctx.report(.unresolved_receiver, sp.span, "super", .{});
        return s.types.errType();
    };
    // Every supertype when unqualified: an interface may be the declarer.
    var levels: std.ArrayList(Level) = .empty;
    const n = try ctx.intern(name.name);
    const recv: Receiver = .{ .implicit = .{ .kind = .super_, .owner = tgt.owner } };
    var level = newLevel();
    const sts: []const TypeId = if (sp.qualifier != null) &.{tgt.ty} else try headers.supertypes(s, tgt.owner);
    for (sts) |st| {
        for (try members.lookup(s, st, n, .function)) |m| {
            try headers.functionHeader(s, m.sym);
            if (s.syms.functionInfo(m.sym).receiver != .none) continue;
            if (!s.syms.flags(m.sym).has_body and s.syms.flags(m.sym).modality == .abstract) continue;
            try level.append(s.arena, .{ .sym = m.sym, .subst = m.subst, .dispatch = recv, .form = .super_ });
        }
        // `super.Inner(args)`: an inner class of the supertype, built on
        // this instance.
        const sc = s.types.classSym(st);
        if (sc != .none) {
            const nested = try scope_mod.nestedClassifier(s, sc, n);
            if (nested != .none and s.syms.kind(nested) == .class and s.syms.flags(nested).inner) {
                try appendCtorsVia(ctx, &level, nested, .{ .dispatch = recv }, st);
            }
        }
    }
    // `Any.toString` reached through an interface is the one a superclass
    // overrides: only the most derived implementation is a candidate.
    if (sp.qualifier == null) {
        var i: usize = 0;
        while (i < level.items.len) {
            const m = level.items[i].sym;
            var shadowed = false;
            for (level.items, 0..) |o, j| {
                if (j == i) continue;
                if (o.sym == m and j < i) shadowed = true;
                if (o.sym != m and s.syms.kind(o.sym) == .function and try members.overridesTransitively(s, o.sym, m)) shadowed = true;
                if (shadowed) break;
            }
            if (shadowed) _ = level.orderedRemove(i) else i += 1;
        }
    }
    if (level.items.len != 0) try levels.append(s.arena, level);
    return resolveLevels(ctx, levels.items, name, args, trailing, type_args, expected);
}

// ------------------------------------------------- callable references ----

/// A declaration a callable reference could name, and where its receivers
/// come from.
const RefCand = struct {
    sym: Sym = .none,
    /// The declaring class's type parameters as seen through the receiver.
    subst: *const types.Subst = &empty_subst,
    dispatch: Receiver = .none,
    extension: Receiver = .none,
    /// The type of the value bound to the extension receiver.
    ext_ty: TypeId = .none,
    /// The receiver an unbound reference takes as its first parameter.
    lead: TypeId = .none,
    /// A constructor reached through this type alias: its expansion is the
    /// result.
    alias: Sym = .none,
};

const RefLevel = std.ArrayList(RefCand);

/// `::f`, `Recv::f`, `::Cls` against the expected type. Candidates are
/// collected level by level as a call's are, bound to the left side's
/// value, to an implicit receiver, or unbound on a type; the first level
/// with a candidate whose reference type fits the expected type answers.
pub fn callableRef(ctx: *Ctx, e: *const Expr, recv: ?*const Expr, name: ast.Ident, expected_in: TypeId) Allocator.Error!TypeId {
    const s = ctx.s;
    if (recv != null and std.mem.eql(u8, name.name, "class")) return classLiteral(ctx, recv.?, e.span());
    const n = try ctx.intern(name.name);
    const nullable_lhs = e.* == .MemberRef and e.MemberRef.nullable_receiver;
    const set = (try refLevels(ctx, recv, qualifierTypeArgs(e), nullable_lhs, n)) orelse {
        try ctx.report(.receiver_unresolved, name.span, "{s}", .{name.name});
        return s.types.errType();
    };
    const expected: TypeId = if (expected_in != .none) try infer.zonk(s, expected_in) else .none;
    const chosen = (try chooseRef(ctx, set.levels, expected)) orelse {
        try ctx.reportFacts(.unresolved_name, name.span, .{ .name = name.name }, "::{s}", .{name.name});
        return s.types.errType();
    };
    const c = chosen.c;
    // A class named on the left whose companion the reference is bound to
    // names that companion.
    if (set.companion != .none and (isObjectSource(c.dispatch, set.companion) or isObjectSource(c.extension, set.companion))) {
        try ctx.addRef(.{ .file = ctx.file, .anchor = body.lastNameSpan(recv.?), .kind = .object, .target = set.companion });
    }
    // The function type the reference adapts to: the expected one, or a
    // fun interface's method.
    var fn_expected = expected;
    if (expected != .none and !s.types.isErr(expected) and functionShape(s, try s.types.makeNotNull(expected)) == null) {
        if (try samType(ctx, try s.types.makeNotNull(expected))) |sam| fn_expected = sam.fn_type;
    }
    const shape: ?FnShape = if (fn_expected != .none and !s.types.isErr(fn_expected)) functionShape(s, try s.types.makeNotNull(fn_expected)) else null;
    // A reference on a value (`x::f`, `x::ext`) is bound to it; a bare one
    // is bound to the implicit receiver it goes through.
    const on_value = c.dispatch == .expr or c.extension == .expr;
    const rec = try s.arena.create(records.RefRec);
    rec.* = .{
        .target = c.sym,
        .bound = if (on_value) .expr else c.dispatch,
        .extension = if (on_value) .none else c.extension,
        // The function value the reference makes; a SAM conversion wraps it.
        .ty = if (chosen.fn_ty != .none) chosen.fn_ty else chosen.ty,
        .type_args = chosen.targs,
        .adapt = try refAdapt(ctx, c.sym, shape, fn_expected, c.lead != .none),
    };
    try ctx.addRef(.{ .file = ctx.file, .anchor = name.span, .kind = .ref, .target = c.sym, .dispatch = c.dispatch, .extension = c.extension, .detail = .{ .ref = rec } });
    return chosen.ty;
}

/// The candidate levels of `recv::n`; null when the left side's type is
/// unresolved.
/// `Outer<String>::f`: the type arguments written on the qualifier.
fn qualifierTypeArgs(e: *const Expr) []const ast.TypeRef {
    return if (e.* == .MemberRef) e.MemberRef.qualifier_type_args else &.{};
}

/// A reference's candidate levels, and the companion of a class named on
/// the left whose levels follow the class's own.
const RefSet = struct {
    levels: []const RefLevel,
    companion: Sym = .none,
};

fn isObjectSource(r: Receiver, obj: Sym) bool {
    return r == .implicit and r.implicit.kind == .object and r.implicit.owner == obj;
}

/// `nullable_lhs`: the qualifier was written `A?`.
fn refLevels(ctx: *Ctx, recv: ?*const Expr, q_args: []const ast.TypeRef, nullable_lhs: bool, n: Name) Allocator.Error!?RefSet {
    const s = ctx.s;
    var levels: std.ArrayList(RefLevel) = .empty;
    const r = recv orelse {
        try scopeRefLevels(ctx, &levels, n);
        return .{ .levels = levels.items };
    };
    var static_cls: Sym = .none;
    if (try body.asQualifier(ctx, r)) |q| {
        if (q.kind == .classifier) static_cls = q.cls;
    }
    // An object named on the left is a value: the reference is bound to
    // it, unless it names one of the object's nested classes, or type
    // arguments make the left side a type (`OnObject<Any>::foo` for
    // `typealias OnObject<T> = Obj` takes the object as its argument). The
    // object is reached as an implicit receiver is, not by evaluating the
    // qualifier.
    if (static_cls != .none and q_args.len == 0 and isObjectClass(s, static_cls) and try scope_mod.nestedClassifier(s, static_cls, n) == .none) {
        try ctx.addRef(.{ .file = ctx.file, .anchor = body.lastNameSpan(r), .kind = .object, .target = static_cls });
        try boundRefLevels(ctx, &levels, try headers.selfType(s, static_cls), .{ .implicit = .{ .kind = .object, .owner = static_cls } }, n);
    } else if (static_cls != .none) {
        // `A?::foo` takes an `A?` first: the extensions on the nullable
        // type are its candidates.
        const qt = try qualifierType(ctx, r, static_cls, q_args);
        try unboundRefLevels(ctx, &levels, static_cls, if (nullable_lhs) try s.types.makeNullable(qt) else qt, n);
        // `C::x` is also the companion's `x`, bound to the companion, below
        // what the type `C` offers: `call(A::instance)` for a `call(f: () ->
        // Boolean)` binds `instance` to a companion that extends `A`, where
        // `A::instance` with nothing expected takes an `A`.
        const comp = s.syms.classInfo(static_cls).companion;
        if (comp != .none) {
            try boundRefLevels(ctx, &levels, try headers.selfType(s, comp), .{ .implicit = .{ .kind = .object, .owner = comp } }, n);
            return .{ .levels = levels.items, .companion = comp };
        }
    } else {
        const rt = try literalReceiver(s, try body.receiverExpr(ctx, r));
        if (s.types.isErr(rt)) return null;
        try boundRefLevels(ctx, &levels, rt, .expr, n);
    }
    return .{ .levels = levels.items };
}

/// Whether a value of class `at` (its arguments unknown) can be passed
/// for `pt`: `pt`'s class is among its supertypes, or for a variable of
/// `sys`, each class its declared bounds name is.
fn classCanFit(ctx: *Ctx, sys: *infer.System, at: TypeId, pt: TypeId) Allocator.Error!bool {
    const s = ctx.s;
    const t = try s.types.makeNotNull(try infer.zonk(s, pt));
    switch (s.types.get(t)) {
        .class => |c| return (try subtyping.supertypeWithClass(s, at, c.sym)) != null or c.sym == s.builtins.any,
        .variable => {
            for (try sys.declaredBoundsOf(t)) |b| {
                const bc = s.types.classSym(try s.types.makeNotNull(try infer.zonk(s, b)));
                if (bc == .none or bc == s.builtins.any) continue;
                if ((try subtyping.supertypeWithClass(s, at, bc)) == null) return false;
            }
            return true;
        },
        else => return true,
    }
}

/// The class every function a deferred call can name returns, star
/// projected: what the argument's type is at most before it resolves.
/// For a bare call, the top-level functions of that name; for a call on a
/// receiver, the members and the extensions whose receiver its class
/// reaches. Null for any other argument, or when the functions return
/// different classes, or a local of that name may be the one called.
fn deferredResultClass(ctx: *Ctx, e: *const Expr) Allocator.Error!?TypeId {
    const s = ctx.s;
    var inner = e;
    if (inner.* == .Spread) inner = inner.Spread.expr;
    const c_expr = switch (inner.*) {
        .Call => |c| c,
        else => return null,
    };
    switch (c_expr.callee.*) {
        .Path => |p| {
            if (p.segments.len == 1) return bareResultClass(ctx, p.segments[0]);
            const prefix = p.segments[0 .. p.segments.len - 1];
            const rt = (try silentType(ctx, .{ .path = prefix })) orelse return null;
            return receiverResultClass(ctx, rt, p.segments[p.segments.len - 1]);
        },
        .Member => |m| {
            if (m.receiver.* == .Super) return null;
            const rt = (try silentType(ctx, .{ .expr = m.receiver })) orelse return null;
            return receiverResultClass(ctx, if (m.safe) try s.types.makeNotNull(rt) else rt, m.name);
        },
        else => return null,
    }
}

fn bareResultClass(ctx: *Ctx, seg: ast.Ident) Allocator.Error!?TypeId {
    const s = ctx.s;
    const n = try ctx.intern(seg.name);
    if (body.lookupLocal(ctx, n) != null) return null;
    var cls: Sym = .none;
    for (try topLevelTiers(ctx, n)) |tier| for (tier) |m| {
        if (s.syms.kind(m) != .function) return null;
        try headers.functionHeader(s, m);
        const c = s.types.classSym(try s.types.makeNotNull(try headers.returnType(s, m)));
        if (c == .none) return null;
        if (cls == .none) cls = c else if (cls != c) return null;
    };
    if (cls == .none) return null;
    return try starred(ctx, cls);
}

/// The type of a call's receiver, a value path's prefix or an expression,
/// found without recording anything; null when it is not a value.
fn silentType(ctx: *Ctx, recv: union(enum) { path: []const ast.Ident, expr: *const Expr }) Allocator.Error!?TypeId {
    const s = ctx.s;
    s.census.muted += 1;
    defer s.census.muted -= 1;
    const b = try ctx.beginBuffer();
    defer ctx.drop(b);
    const t = switch (recv) {
        .path => |prefix| blk: {
            const head = try body.pathHead(ctx, prefix);
            if (head.kind != .value) return null;
            if (head.used == prefix.len) break :blk head.ty;
            break :blk try body.qualifiedAccessPrefix(ctx, prefix, head);
        },
        .expr => |r| blk: {
            if (try body.asQualifier(ctx, r)) |q| if (q.kind != .value) return null;
            break :blk try body.receiverExpr(ctx, r);
        },
    };
    if (s.types.isErr(t)) return null;
    return try infer.zonk(s, t);
}

fn receiverResultClass(ctx: *Ctx, rt: TypeId, id: ast.Ident) Allocator.Error!?TypeId {
    const s = ctx.s;
    const n = try ctx.intern(id.name);
    const rt_nn = try s.types.makeNotNull(rt);
    if (s.types.get(rt_nn) != .class) return null;
    var cls: Sym = .none;
    if (!try subtyping.admitsNull(s, rt)) for (try members.lookup(s, rt, n, .callable)) |m| {
        if (s.syms.kind(m.sym) != .function) return null;
        try headers.functionHeader(s, m.sym);
        if (s.syms.functionInfo(m.sym).receiver != .none) continue;
        if (!try agreeOn(s, &cls, m.sym)) return null;
    };
    if ((try receiverInvokeLevel(ctx, n, rt, .expr)).items.len != 0) return null;
    var levels: std.ArrayList(Level) = .empty;
    try appendExtensionLevels(ctx, &levels, n, .expr, rt, false);
    for (levels.items) |level| for (level.items) |cand| {
        if (s.syms.kind(cand.sym) != .function) return null;
        try headers.functionHeader(s, cand.sym);
        const r = s.syms.functionInfo(cand.sym).receiver;
        if (r == .none or !try receiverClassFits(s, rt_nn, r)) continue;
        if (!try agreeOn(s, &cls, cand.sym)) return null;
    };
    if (cls == .none) return null;
    return try starred(ctx, cls);
}

/// Folds `f`'s result class into `cls`; false when it has none or another.
fn agreeOn(s: *Sema, cls: *Sym, f: Sym) Allocator.Error!bool {
    const c = s.types.classSym(try s.types.makeNotNull(try headers.returnType(s, f)));
    if (c == .none) return false;
    if (cls.* == .none) cls.* = c else if (cls.* != c) return false;
    return true;
}

/// Whether a receiver of class type `rt` can be an extension's declared
/// receiver `r`, by class: `r`'s class, or each class a type parameter's
/// bounds name, is among `rt`'s supertypes.
fn receiverClassFits(s: *Sema, rt: TypeId, r: TypeId) Allocator.Error!bool {
    const nn = try s.types.makeNotNull(r);
    switch (s.types.get(nn)) {
        .class => |c| return c.sym == s.builtins.any or (try subtyping.supertypeWithClass(s, rt, c.sym)) != null,
        .param => |p| {
            for (try headers.typeParamBounds(s, p.sym)) |b| {
                const bc = s.types.classSym(try s.types.makeNotNull(b));
                if (bc == .none or bc == s.builtins.any) continue;
                if ((try subtyping.supertypeWithClass(s, rt, bc)) == null) return false;
            }
            return true;
        },
        else => return true,
    }
}

/// Whether a callable reference argument can be passed where `pt` is
/// expected: one of its candidates fits the function type `pt` is, or
/// the one a fun interface's method gives, exactly or by the arity an
/// adapted reference has. Resolved silently; the chosen call resolves it
/// again for real.
fn refApplies(ctx: *Ctx, e: *const Expr, pt: TypeId) Allocator.Error!bool {
    const s = ctx.s;
    const nn = try s.types.makeNotNull(try infer.zonk(s, pt));
    const c = switch (s.types.get(nn)) {
        .class => |c| c,
        else => return true,
    };
    if (c.sym == s.builtins.any or c.sym == s.builtins.function) return true;
    const target: TypeId = if (functionShape(s, nn) != null) nn else if (try samType(ctx, nn)) |sam| sam.fn_type else return refFits(s, nn);
    const recv: ?*const Expr, const name: ast.Ident = switch (e.*) {
        .PropertyRef => |r| .{ null, r.name },
        .MemberRef => |r| .{ r.receiver, r.name },
        else => return true,
    };
    if (recv != null and std.mem.eql(u8, name.name, "class")) return refFits(s, nn);
    s.census.muted += 1;
    defer s.census.muted -= 1;
    const nullable_lhs = e.* == .MemberRef and e.MemberRef.nullable_receiver;
    const levels = ((try refLevels(ctx, recv, qualifierTypeArgs(e), nullable_lhs, try ctx.intern(name.name))) orelse return true).levels;
    for (levels) |level| for (level.items) |cand| {
        if (try refFit(ctx, cand, target) != null) return true;
    };
    const sh = functionShape(s, target).?;
    for (levels) |level| for (level.items) |cand| {
        const k = s.syms.kind(cand.sym);
        if (k != .function and k != .constructor) continue;
        try headers.functionHeader(s, cand.sym);
        const ps = s.syms.functionInfo(cand.sym).params.len + @intFromBool(cand.lead != .none);
        if (ps == sh.params + @intFromBool(sh.has_receiver) or ps == sh.params) return true;
    };
    return false;
}

fn isObjectClass(s: *Sema, cls: Sym) bool {
    const k = s.syms.classInfo(cls).kind;
    return k == .object or k == .companion;
}

/// Candidates on a value of type `rt` supplied by `src`: its members, an
/// inner class's constructors, then the extensions that take it.
fn boundRefLevels(ctx: *Ctx, levels: *std.ArrayList(RefLevel), rt: TypeId, src: Receiver, n: Name) Allocator.Error!void {
    const s = ctx.s;
    var level: RefLevel = .empty;
    // A value that may be null has no members to reference; the extensions
    // on its nullable type apply (`t::toString` for a `t: T` is
    // `Any?.toString`).
    const members_apply = !try subtyping.admitsNull(s, rt);
    if (members_apply) for (try members.lookup(s, rt, n, .callable)) |m| {
        if (s.syms.kind(m.sym) == .function) {
            try headers.functionHeader(s, m.sym);
            if (s.syms.functionInfo(m.sym).receiver != .none) continue;
        }
        try level.append(s.arena, .{ .sym = m.sym, .subst = m.subst, .dispatch = src });
    };
    // `outer::Inner` binds an inner class's constructor to `outer`.
    if (level.items.len == 0 and s.types.classSym(rt) != .none) {
        const nested = try scope_mod.nestedClassifier(s, s.types.classSym(rt), n);
        if (nested != .none and s.syms.kind(nested) == .class and s.syms.flags(nested).inner) {
            try ctorRefCands(ctx, &level, nested, .{ .dispatch = src, .subst = try innerSubst(ctx, nested, rt) });
        }
        if (level.items.len == 0) try innerAliasRefCands(ctx, &level, rt, src, n);
    }
    if (level.items.len != 0) try levels.append(s.arena, level);
    var ext: RefLevel = .empty;
    for (try extensionFunctions(ctx, n)) |x| {
        const xs = (try extensionRefSubst(s, x.sym, x.subst, rt)) orelse continue;
        try ext.append(s.arena, .{ .sym = x.sym, .subst = xs, .dispatch = x.dispatch, .extension = src, .ext_ty = rt });
    }
    if (try extensionProperty(ctx, rt, n)) |ep| {
        try ext.append(s.arena, .{ .sym = ep.sym, .subst = ep.subst, .dispatch = ep.dispatch, .extension = src, .ext_ty = rt });
    }
    if (ext.items.len != 0) try levels.append(s.arena, ext);
}

/// Candidates on a type named on the left (`Cls::f`): members and
/// extensions take an instance as their first parameter; a nested class
/// names its constructors, an inner one taking its outer instance first.
/// The type a class qualifier of a reference names: with written type
/// arguments (`Outer<String>`), that application, else the class over its
/// own type parameters.
fn qualifierType(ctx: *Ctx, q: *const Expr, cls: Sym, q_args: []const ast.TypeRef) Allocator.Error!TypeId {
    const s = ctx.s;
    // A type alias written with arguments is its expansion with them.
    if (q_args.len != 0 and q.* == .Path and q.Path.segments.len == 1) alias: {
        const n = try ctx.intern(q.Path.segments[0].name);
        const alias = try scope_mod.classifierInContext(s, body.typeCtx(ctx).decl, ctx.file, n);
        if (alias == .none or s.syms.kind(alias) != .type_alias) break :alias;
        const atps = s.syms.aliasInfo(alias).type_params;
        if (atps.len != q_args.len) break :alias;
        for (q_args) |*tr| if (std.mem.eql(u8, tr.name.name, "*")) break :alias;
        var subst: types.Subst = .empty;
        for (atps, q_args) |tp, *tr| try subst.put(s.arena, tp, try body.resolveTypeInBody(ctx, tr));
        return s.types.makeNotNull(try s.types.substitute(try headers.aliasTarget(s, alias), &subst));
    }
    const tps = try headers.classTypeParams(s, cls);
    if (q_args.len == 0 or q_args.len != tps.len) return headers.selfType(s, cls);
    const args = try s.arena.alloc(types.Arg, q_args.len);
    for (q_args, args) |*tr, *a| {
        // `BufferedChannel<*>::f`: a star is written as a type named `*`.
        if (std.mem.eql(u8, tr.name.name, "*")) {
            a.* = .{ .variance = .star, .ty = .none };
            continue;
        }
        a.* = .{ .variance = .inv, .ty = try body.resolveTypeInBody(ctx, tr) };
    }
    return s.types.class(cls, args, false);
}

fn unboundRefLevels(ctx: *Ctx, levels: *std.ArrayList(RefLevel), cls: Sym, self_t: TypeId, n: Name) Allocator.Error!void {
    const s = ctx.s;
    var level: RefLevel = .empty;
    // A nullable type has no members to reference.
    const members_apply = !try subtyping.admitsNull(s, self_t);
    if (members_apply) for (try members.lookup(s, self_t, n, .callable)) |m| {
        if (s.syms.kind(m.sym) == .function) {
            try headers.functionHeader(s, m.sym);
            if (s.syms.functionInfo(m.sym).receiver != .none) continue;
        }
        // A static member (`Color::valueOf`) takes no instance.
        const lead: TypeId = if (s.syms.flags(m.sym).static) .none else self_t;
        try level.append(s.arena, .{ .sym = m.sym, .subst = m.subst, .lead = lead });
    };
    const nested = try scope_mod.nestedClassifier(s, cls, n);
    if (members_apply and nested != .none and s.syms.kind(nested) == .class) {
        const inner = s.syms.flags(nested).inner;
        try ctorRefCands(ctx, &level, nested, .{ .lead = if (inner) self_t else .none, .subst = if (inner) try innerSubst(ctx, nested, self_t) else &empty_subst });
    }
    if (level.items.len == 0) {
        var aliased: RefLevel = .empty;
        try innerAliasRefCands(ctx, &aliased, self_t, .none, n);
        for (aliased.items) |*c| {
            c.dispatch = .none;
            c.lead = self_t;
        }
        try level.appendSlice(s.arena, aliased.items);
    }
    if (level.items.len != 0) try levels.append(s.arena, level);
    var ext: RefLevel = .empty;
    for (try extensionFunctions(ctx, n)) |x| {
        const xs = (try extensionRefSubst(s, x.sym, x.subst, self_t)) orelse continue;
        try ext.append(s.arena, .{ .sym = x.sym, .subst = xs, .dispatch = x.dispatch, .lead = self_t });
    }
    if (try extensionProperty(ctx, self_t, n)) |ep| {
        try ext.append(s.arena, .{ .sym = ep.sym, .subst = ep.subst, .dispatch = ep.dispatch, .lead = self_t });
    }
    if (ext.items.len != 0) try levels.append(s.arena, ext);
}

/// Candidates for `::f` without a left side: local declarations, then each
/// implicit receiver's members and extensions (bound to it), then
/// top-level declarations and classifiers in scope.
fn scopeRefLevels(ctx: *Ctx, levels: *std.ArrayList(RefLevel), n: Name) Allocator.Error!void {
    const s = ctx.s;
    // The local functions and classes of each block, innermost first, the
    // overloads of one block together. A local variable is not referenced
    // with `::`: `::f` beside `val f` names the function `f`, however far
    // out it is declared.
    var sc: ?*body.Scope = ctx.scope;
    var hide = false;
    while (sc) |c| : (sc = c.parent) {
        var level: RefLevel = .empty;
        var i: usize = if (body.localsVisible(c, &hide)) c.locals.items.len else 0;
        while (i > 0) {
            i -= 1;
            const loc = c.locals.items[i].sym;
            if (c.locals.items[i].name != n) continue;
            switch (s.syms.kind(loc)) {
                // A local class names its constructors.
                .class => try ctorRefCands(ctx, &level, loc, .{}),
                .function => {
                    try headers.functionHeader(s, loc);
                    // A local extension function binds the innermost
                    // implicit receiver it takes; with none, `::f` does not
                    // name it.
                    const recv = s.syms.functionInfo(loc).receiver;
                    if (recv != .none) {
                        for (try body.implicitReceivers(ctx)) |r| {
                            const rt = try body.narrowedReceiver(ctx, r);
                            const xs = (try extensionRefSubst(s, loc, &empty_subst, rt)) orelse continue;
                            try level.append(s.arena, .{ .sym = loc, .subst = xs, .extension = .{ .implicit = .{ .kind = r.kind, .owner = r.owner } }, .ext_ty = rt });
                            break;
                        }
                    } else try level.append(s.arena, .{ .sym = loc });
                },
                else => {},
            }
        }
        if (level.items.len != 0) try levels.append(s.arena, level);
    }
    for (try body.implicitReceivers(ctx)) |r| {
        const rt = try body.narrowedReceiver(ctx, r);
        try boundRefLevels(ctx, levels, rt, .{ .implicit = .{ .kind = r.kind, .owner = r.owner } }, n);
    }
    // A top-level extension is named by `::f` only through an implicit
    // receiver it takes, which the receivers' levels above offer: with no
    // receiver written it is not a candidate (`::deco` beside
    // `fun String.deco()` is the plain `deco`).
    for (try topLevelTiers(ctx, n)) |tier| {
        var level: RefLevel = .empty;
        for (tier) |m| {
            switch (s.syms.kind(m)) {
                .function => {
                    try headers.functionHeader(s, m);
                    if (s.syms.functionInfo(m).receiver != .none) continue;
                    try level.append(s.arena, .{ .sym = m, .dispatch = importedOwner(ctx, m) });
                },
                .property => {
                    try headers.propertyHeader(s, m);
                    if (s.syms.propertyInfo(m).receiver != .none) continue;
                    try level.append(s.arena, .{ .sym = m, .dispatch = importedOwner(ctx, m) });
                },
                .class => try ctorRefCands(ctx, &level, m, .{}),
                .type_alias => {
                    const target = s.types.classSym(try s.types.makeNotNull(try headers.aliasTarget(s, m)));
                    if (target != .none and s.syms.kind(target) == .class) try ctorRefCands(ctx, &level, target, .{ .alias = m });
                },
                else => {},
            }
        }
        if (level.items.len != 0) try levels.append(s.arena, level);
    }
    const cls = try body.classifierInScope(ctx, n);
    if (cls != .none and s.syms.kind(cls) == .class) {
        var level: RefLevel = .empty;
        try ctorRefCands(ctx, &level, cls, .{});
        if (level.items.len != 0) try levels.append(s.arena, level);
    }
}

/// The constructors of `cls` as reference candidates. An inner class's,
/// with neither an outer instance nor an unbound one named, take the
/// innermost implicit receiver of its outer class, as a call would.
fn ctorRefCands(ctx: *Ctx, level: *RefLevel, cls: Sym, via: RefCand) Allocator.Error!void {
    const s = ctx.s;
    const kind = s.syms.classInfo(cls).kind;
    // A fun interface names its SAM constructor: `::Supplier` is
    // `(() -> T) -> Supplier<T>`.
    if (kind == .interface and s.syms.flags(cls).fun_iface and via.alias == .none and via.lead == .none and via.dispatch == .none) {
        const f = try samConstructor(ctx, cls);
        if (f != .none) try level.append(s.arena, .{ .sym = f });
        return;
    }
    if (kind == .interface or kind == .object or kind == .companion) return;
    var base = via;
    if (s.syms.flags(cls).inner and base.dispatch == .none and base.lead == .none) {
        const outer = s.syms.owner(cls);
        for (try body.implicitReceivers(ctx)) |r| {
            const rt = try body.narrowedReceiver(ctx, r);
            if (try subtyping.supertypeWithClass(s, rt, outer) == null) continue;
            base.dispatch = .{ .implicit = .{ .kind = r.kind, .owner = r.owner } };
            base.subst = try innerSubst(ctx, cls, rt);
            break;
        }
    }
    for (symbols.Symbols.members(&s.syms.classInfo(cls).members, wk.init)) |ctor| {
        if (s.syms.kind(ctor) != .constructor) continue;
        var c = base;
        c.sym = ctor;
        try level.append(s.arena, c);
    }
}

/// The substitution an inner class's outer type parameters take from an
/// outer instance of type `outer_t`.
fn innerSubst(ctx: *Ctx, inner: Sym, outer_t: TypeId) Allocator.Error!*const types.Subst {
    const s = ctx.s;
    const st = (try subtyping.supertypeWithClass(s, outer_t, s.syms.owner(inner))) orelse return &empty_subst;
    const sub = try s.arena.create(types.Subst);
    sub.* = try subtyping.classSubst(s, st);
    return sub;
}

/// The constructors of an inner class of `outer_t`'s class reached
/// through a type alias in scope named `n`.
fn innerAliasRefCands(ctx: *Ctx, level: *RefLevel, outer_t: TypeId, src: Receiver, n: Name) Allocator.Error!void {
    const s = ctx.s;
    // An alias nested in the outer class (`typealias A = Outer<X>.Inner`
    // inside `Outer`), then top-level ones.
    const oc = s.types.classSym(outer_t);
    if (oc != .none) {
        const nested = try scope_mod.nestedClassifier(s, oc, n);
        if (nested != .none and s.syms.kind(nested) == .type_alias) {
            const target = s.types.classSym(try headers.aliasTarget(s, nested));
            if (target != .none and s.syms.flags(target).inner) {
                try ctorRefCands(ctx, level, target, .{ .dispatch = src, .subst = try innerSubst(ctx, target, outer_t), .alias = nested });
                return;
            }
        }
    }
    for (try topLevelTiers(ctx, n)) |tier| {
        for (tier) |m| {
            if (s.syms.kind(m) != .type_alias) continue;
            const target = s.types.classSym(try headers.aliasTarget(s, m));
            if (target == .none or !s.syms.flags(target).inner) continue;
            if (try subtyping.supertypeWithClass(s, outer_t, s.syms.owner(target)) == null) continue;
            try ctorRefCands(ctx, level, target, .{ .dispatch = src, .subst = try innerSubst(ctx, target, outer_t), .alias = m });
            return;
        }
    }
}

/// Whether an extension's declared receiver accepts a value of type `rt`.
fn extensionTakes(s: *Sema, f: Sym, subst: *const types.Subst, rt: TypeId) Allocator.Error!bool {
    return (try extensionRefSubst(s, f, subst, rt)) != null;
}

/// The substitution extension function `f` takes on a receiver of type
/// `rt`: `subst` with the type parameters of `f` the receiver fixes
/// (`Int::self` for `fun <T> T.self(): T` returns an `Int`); null when `f`
/// does not take `rt`.
fn extensionRefSubst(s: *Sema, f: Sym, subst: *const types.Subst, rt: TypeId) Allocator.Error!?*const types.Subst {
    try headers.functionHeader(s, f);
    const info = s.syms.functionInfo(f);
    if (info.receiver == .none) return null;
    var sys = infer.System.init(s);
    sys.trial = true;
    try sys.addTypeParams(info.type_params);
    if (!try sys.constrain(rt, try sys.open(try s.types.substitute(info.receiver, subst)))) return null;
    if (!try sys.solve(true)) return null;
    return withFixed(s, &sys, info.type_params, subst);
}

/// `subst` and the type parameters among `tps` that `sys` fixed to a type
/// naming none of its variables.
fn withFixed(s: *Sema, sys: *infer.System, tps: []const Sym, subst: *const types.Subst) Allocator.Error!*const types.Subst {
    if (tps.len == 0) return subst;
    const out = try s.arena.create(types.Subst);
    out.* = .empty;
    var it = subst.iterator();
    while (it.next()) |e| try out.put(s.arena, e.key_ptr.*, e.value_ptr.*);
    for (tps) |tp| {
        const fixed = sys.fixedFor(tp);
        if (fixed == .none) continue;
        const t = try sys.close(fixed);
        if (infer.hasOpenVar(s, t)) continue;
        try out.put(s.arena, tp, t);
    }
    return out;
}

const RefChoice = struct {
    c: RefCand,
    ty: TypeId,
    /// For a reference SAM converted to a fun interface (`ty`): the
    /// function type it fits, the value the conversion wraps.
    fn_ty: TypeId = .none,
    /// The target's own type arguments the fit inferred, in declaration
    /// order; empty when no expected type inferred them.
    targs: []const TypeId = &.{},
};

/// A reference type that fits, and the target's type arguments it fixed.
const RefFit = struct { ty: TypeId, targs: []const TypeId };

/// The candidate a reference names. With an expected type, the first level
/// holding a candidate whose type fits it, the most specific of those,
/// its type parameters inferred from the fit. Otherwise, or when none fits
/// exactly (a reference adapted to defaults, varargs or a `Unit` result),
/// the first level's candidate whose arity the expected function type
/// takes, else its first.
fn chooseRef(ctx: *Ctx, levels: []const RefLevel, expected: TypeId) Allocator.Error!?RefChoice {
    const s = ctx.s;
    if (levels.len == 0) return null;
    const usable = expected != .none and !s.types.isErr(expected) and s.types.get(expected) != .variable;
    // A fun interface expected takes the reference by SAM conversion: its
    // method's function type is what the reference must fit, and the
    // interface is the reference's type.
    var target = expected;
    var sam_iface: TypeId = .none;
    if (usable) {
        const nn = try s.types.makeNotNull(expected);
        if (functionShape(s, nn) == null) {
            if (try samType(ctx, nn)) |sam| {
                target = sam.fn_type;
                sam_iface = expected;
            }
        }
        for (levels) |level| {
            var fits: std.ArrayList(RefChoice) = .empty;
            for (level.items) |c| {
                if (try refFit(ctx, c, target)) |f| try fits.append(s.arena, .{ .c = c, .ty = if (sam_iface != .none) sam_iface else f.ty, .fn_ty = if (sam_iface != .none) f.ty else .none, .targs = f.targs });
            }
            if (fits.items.len == 0) continue;
            return try mostSpecificRef(ctx, fits.items);
        }
    }
    const first = levels[0].items;
    var chosen = first[0];
    const shape: ?FnShape = if (usable) functionShape(s, try s.types.makeNotNull(target)) else null;
    if (shape) |sh| {
        for (first) |c| {
            const k = s.syms.kind(c.sym);
            if (k != .function and k != .constructor) continue;
            try headers.functionHeader(s, c.sym);
            const ps = s.syms.functionInfo(c.sym).params.len + @intFromBool(c.lead != .none);
            if (ps == sh.params + @intFromBool(sh.has_receiver) or ps == sh.params) {
                chosen = c;
                break;
            }
        }
    }
    return .{ .c = chosen, .ty = try refType(ctx, chosen) };
}

/// The reference type of `c` when it fits `expected`, with the type
/// parameters the fit infers; null when it does not fit. A function
/// reference that does not fit as declared may fit adapted.
fn refFit(ctx: *Ctx, c: RefCand, expected: TypeId) Allocator.Error!?RefFit {
    const s = ctx.s;
    const t = try refType(ctx, c);
    if (s.types.isErr(t)) return null;
    if (try fitRefType(ctx, c, t, expected)) |r| return r;
    const adapted = (try adaptedRefType(ctx, c, t, expected)) orelse return null;
    return fitRefType(ctx, c, adapted, expected);
}

/// `t`, a type of the reference `c`, with `c`'s type parameters inferred
/// from `t <: expected`; null when it does not fit.
fn fitRefType(ctx: *Ctx, c: RefCand, t: TypeId, expected: TypeId) Allocator.Error!?RefFit {
    const s = ctx.s;
    var sys = infer.System.init(s);
    sys.trial = true;
    const k = s.syms.kind(c.sym);
    if (k == .function or k == .constructor) {
        var tps: std.ArrayList(Sym) = .empty;
        try tps.appendSlice(s.arena, s.syms.functionInfo(c.sym).type_params);
        if (k == .constructor) try tps.appendSlice(s.arena, s.syms.classInfo(s.syms.owner(c.sym)).type_params);
        if (c.alias != .none) try tps.appendSlice(s.arena, s.syms.aliasInfo(c.alias).type_params);
        try sys.addTypeParams(tps.items);
    } else if (k == .property) {
        try sys.addTypeParams(s.syms.propertyInfo(c.sym).type_params);
    }
    // A bound extension's receiver fixes its type parameters too.
    if (c.ext_ty != .none) {
        const recv: TypeId = switch (k) {
            .function => s.syms.functionInfo(c.sym).receiver,
            .property => s.syms.propertyInfo(c.sym).receiver,
            else => .none,
        };
        if (recv != .none and !try sys.constrain(c.ext_ty, try sys.open(try s.types.substitute(recv, c.subst)))) return null;
    }
    const opened = try sys.open(t);
    if (!try sys.constrain(opened, expected)) return null;
    if (!try sys.solve(false)) return null;
    // A function's own type arguments, for a reified parameter's run-time
    // type (`useArray(::arrayOf)` passes `String`).
    var targs: []const TypeId = &.{};
    if (k == .function) {
        const own = s.syms.functionInfo(c.sym).type_params;
        const out = try s.arena.alloc(TypeId, own.len);
        for (own, out) |tp, *o| {
            const f = sys.fixedFor(tp);
            o.* = if (f == .none) s.types.errType() else try sys.close(f);
        }
        targs = out;
    }
    return .{ .ty = try sys.close(opened), .targs = targs };
}

/// A function reference adapted to the function type expected: as many
/// parameters as it takes, a vararg taking the rest one element at a time,
/// every parameter left over defaulted or an empty vararg, and a `Unit`
/// result discarding the function's. Null when it cannot adapt.
fn adaptedRefType(ctx: *Ctx, c: RefCand, declared: TypeId, expected: TypeId) Allocator.Error!?TypeId {
    const s = ctx.s;
    const k = s.syms.kind(c.sym);
    if (k != .function and k != .constructor) return null;
    const nn = try s.types.makeNotNull(expected);
    const shape = functionShape(s, nn) orelse return null;
    const want = s.types.argsOf(nn);
    var remaining: usize = want.len - 1;
    const info = s.syms.functionInfo(c.sym);
    var ps: std.ArrayList(TypeId) = .empty;
    if (c.lead != .none) {
        if (remaining == 0) return null;
        try ps.append(s.arena, try s.types.substitute(c.lead, c.subst));
        remaining -= 1;
    }
    var i: usize = 0;
    while (remaining > 0) : (i += 1) {
        if (i >= info.params.len) return null;
        const p = info.params[i];
        const pt = try s.types.substitute(try headers.paramType(s, p), c.subst);
        if (s.syms.flags(p).vararg) {
            // An array where the vararg stands passes it whole, and the
            // parameters after it follow; anything else is its elements,
            // and the parameters after them take their defaults.
            const arr = try varargArrayType(ctx, pt);
            const at = want[want.len - 1 - remaining].ty;
            if (s.types.classSym(try s.types.makeNotNull(try infer.zonk(s, at))) == s.types.classSym(arr)) {
                try ps.append(s.arena, arr);
                remaining -= 1;
                continue;
            }
            while (remaining > 0) : (remaining -= 1) try ps.append(s.arena, pt);
            i += 1;
            break;
        }
        try ps.append(s.arena, pt);
        remaining -= 1;
    }
    for (info.params[@min(i, info.params.len)..]) |p| {
        if (s.syms.flags(p).vararg) continue;
        if (!try paramHasDefault(ctx, c.sym, p)) return null;
    }
    const declared_args = s.types.argsOf(declared);
    var ret = declared_args[declared_args.len - 1].ty;
    if (try infer.zonk(s, want[want.len - 1].ty) == s.t.unit) ret = s.t.unit;
    return try s.functionType(.none, ps.items, ret, shape.is_suspend or s.syms.flags(c.sym).suspend_, false);
}

fn mostSpecificRef(ctx: *Ctx, fits: []const RefChoice) Allocator.Error!RefChoice {
    const s = ctx.s;
    if (fits.len == 1) return fits[0];
    outer: for (fits, 0..) |a, i| {
        const ap = s.types.argsOf(if (a.fn_ty != .none) a.fn_ty else a.ty);
        for (fits, 0..) |b, j| {
            if (i == j) continue;
            const bp = s.types.argsOf(if (b.fn_ty != .none) b.fn_ty else b.ty);
            if (ap.len != bp.len) continue :outer;
            // Every parameter type of `a` fits `b`'s.
            for (ap[0 .. ap.len -| 1], bp[0 .. bp.len -| 1]) |x, y| {
                if (!try subtyping.isSubtype(s, x.ty, y.ty)) continue :outer;
            }
        }
        return a;
    }
    return fits[0];
}

/// The type a reference to `c` has: a `KFunctionN` over its parameters
/// (an unbound receiver first), or a property type.
fn refType(ctx: *Ctx, c: RefCand) Allocator.Error!TypeId {
    const s = ctx.s;
    switch (s.syms.kind(c.sym)) {
        .function, .constructor => {
            try headers.functionHeader(s, c.sym);
            const info = s.syms.functionInfo(c.sym);
            var ps: std.ArrayList(TypeId) = .empty;
            if (c.lead != .none) try ps.append(s.arena, try s.types.substitute(c.lead, c.subst));
            for (info.params) |p| {
                var pt = try s.types.substitute(try headers.paramType(s, p), c.subst);
                if (s.syms.flags(p).vararg) pt = try varargArrayType(ctx, pt);
                try ps.append(s.arena, pt);
            }
            const ret = if (s.syms.kind(c.sym) == .constructor) blk: {
                if (c.alias != .none) break :blk try s.types.makeNotNull(try headers.aliasTarget(s, c.alias));
                break :blk try s.types.substitute(try headers.selfType(s, s.syms.owner(c.sym)), c.subst);
            } else try s.types.substitute(try headers.returnType(s, c.sym), c.subst);
            // `Int::plusOne` for `fun Int.plusOne(x: Int)` keeps the
            // extension receiver as one: `3.p(4)` calls it.
            const ext = s.syms.kind(c.sym) == .function and info.receiver != .none and c.lead != .none;
            const kf = try s.kfunctionClass(@intCast(ps.items.len), s.syms.flags(c.sym).suspend_);
            if (kf != .none) {
                var args: std.ArrayList(types.Arg) = .empty;
                for (ps.items) |p| try args.append(s.arena, .{ .variance = .inv, .ty = p });
                try args.append(s.arena, .{ .variance = .inv, .ty = ret });
                return s.types.classAttrs(kf, args.items, false, .{ .ext_fn = ext });
            }
            if (ext) return s.functionType(ps.items[0], ps.items[1..], ret, s.syms.flags(c.sym).suspend_, false);
            return s.functionType(.none, ps.items, ret, s.syms.flags(c.sym).suspend_, false);
        },
        .property => {
            try headers.propertyHeader(s, c.sym);
            const pt = try s.types.substitute(try headers.propertyType(s, c.sym), c.subst);
            const mutable = s.syms.flags(c.sym).mutable;
            const b = s.builtins;
            const unbound = c.lead != .none;
            const k = if (unbound)
                (if (mutable) b.kmutable_property1 else b.kproperty1)
            else
                (if (mutable) b.kmutable_property0 else b.kproperty0);
            if (k == .none) return s.types.errType();
            if (unbound) return s.types.class(k, &.{ .{ .variance = .inv, .ty = c.lead }, .{ .variance = .inv, .ty = pt } }, false);
            return s.types.class(k, &.{.{ .variance = .inv, .ty = pt }}, false);
        },
        else => return s.types.errType(),
    }
}

/// How a function reference adapts to the function type expected of it:
/// trailing parameters left to their defaults, a result dropped for `Unit`.
/// `lead`: an unbound reference, whose first function-type parameter is
/// the receiver, not one of the target's parameters.
fn refAdapt(ctx: *Ctx, target: Sym, shape: ?FnShape, expected: TypeId, lead: bool) Allocator.Error!records.RefAdapt {
    const s = ctx.s;
    var a: records.RefAdapt = .{};
    const sh = shape orelse return a;
    const k = s.syms.kind(target);
    if (k != .function and k != .constructor) return a;
    try headers.functionHeader(s, target);
    const ps = s.syms.functionInfo(target).params;
    // The target's parameters the function type's supply.
    const given = (sh.params + @intFromBool(sh.has_receiver)) -| @intFromBool(lead);
    const et = try s.types.makeNotNull(try infer.zonk(s, expected));
    const args = s.types.argsOf(et);
    const vi: ?usize = for (ps, 0..) |p, i| {
        if (s.syms.flags(p).vararg) break i;
    } else null;
    if (vi != null and given > vi.?) {
        // The function type reaches the vararg: its arguments from there
        // are the vararg's elements, and every parameter after it takes
        // its default; or the one there is the array itself, and the
        // parameters after it take the arguments after that, the rest
        // their defaults.
        const at = vi.? + @intFromBool(lead);
        const array_form = at + 1 < args.len and isArrayType(s, try s.types.makeNotNull(try infer.zonk(s, args[at].ty)));
        a.vararg_elems = !array_form;
        const after_given: usize = if (array_form) given - (vi.? + 1) else 0;
        var n: u16 = 0;
        for (ps[vi.? + 1 ..], 0..) |p, pos| {
            if (pos < after_given) continue;
            if (try paramHasDefault(ctx, target, p)) n += 1;
        }
        a.defaults = n;
    } else if (ps.len > given) {
        var n: u16 = 0;
        for (ps[given..]) |p| {
            if (try paramHasDefault(ctx, target, p)) n += 1;
            if (s.syms.flags(p).vararg) a.vararg_elems = true;
        }
        a.defaults = n;
    }
    if (args.len != 0 and k == .function) {
        const want_ret = args[args.len - 1].ty;
        const ret = try headers.returnType(s, target);
        if (want_ret == s.t.unit and ret != s.t.unit) a.drop_result = true;
    }
    return a;
}

/// Whether `t` is `Array<...>` or a primitive array.
fn isArrayType(s: *Sema, t: TypeId) bool {
    const cls = s.types.classSym(t);
    if (cls == .none) return false;
    if (cls == s.builtins.array) return true;
    const fqn = s.str(s.syms.classInfo(cls).fqn);
    return std.mem.startsWith(u8, fqn, "kotlin.") and std.mem.endsWith(u8, fqn, "Array") and std.mem.indexOfScalar(u8, fqn["kotlin.".len..], '.') == null;
}

/// `C::class` names a classifier: `KClass<C>`. `x::class` is the class of
/// a value at run time: `KClass<out T>` for `x: T`.
fn classLiteral(ctx: *Ctx, recv: *const Expr, sp: Span) Allocator.Error!TypeId {
    const s = ctx.s;
    var t: TypeId = .none;
    var bound = false;
    // A type parameter (reified, in an inline function) or a classifier.
    if (recv.* == .Path and recv.Path.segments.len == 1) {
        const n = try ctx.intern(recv.Path.segments[0].name);
        if (body.lookupLocal(ctx, n) == null) {
            const tc = body.typeCtx(ctx);
            const c = try scope_mod.classifierInContext(s, tc.decl, ctx.file, n);
            if (c != .none and s.syms.kind(c) == .type_param) t = try s.types.param(c, false);
        }
    }
    if (t == .none) {
        if (try body.asQualifier(ctx, recv)) |q| {
            if (q.kind == .classifier) t = try starred(ctx, q.cls);
        }
    }
    if (t == .none) {
        t = try s.types.makeNotNull(try body.receiverExpr(ctx, recv));
        bound = true;
    }
    if (s.types.isErr(t) or s.builtins.kclass == .none) return s.types.errType();
    const test_rec = try s.arena.create(records.TypeTestRec);
    test_rec.* = .{ .kind = if (bound) .class_of else .class_literal, .ty = t, .class = s.types.classSym(t), .nullable = false };
    try ctx.addRef(.{ .file = ctx.file, .anchor = sp, .kind = .class_literal, .target = switch (s.types.get(t)) {
        .class => |c| c.sym,
        .param => |p| p.sym,
        else => .none,
    }, .dispatch = if (bound) .expr else .none, .detail = .{ .type_test = test_rec } });
    return s.types.class(s.builtins.kclass, &.{.{ .variance = if (bound) .out else .inv, .ty = t }}, false);
}

/// A class used bare, as a class literal names it: its type parameters
/// star-projected.
fn starred(ctx: *Ctx, cls: Sym) Allocator.Error!TypeId {
    const s = ctx.s;
    const tps = try headers.classTypeParams(s, cls);
    const args = try s.arena.alloc(types.Arg, tps.len);
    for (args) |*a| a.* = .{ .variance = .star, .ty = .none };
    return s.types.class(cls, args, false);
}

// --------------------------------------------------------------- misc ----

/// The array type a vararg parameter of element type `elem` has: a
/// primitive array for a primitive element, else `Array<out T>`.
pub fn varargArrayType(ctx: *Ctx, elem: TypeId) Allocator.Error!TypeId {
    return ctx.s.varargArrayType(elem);
}
