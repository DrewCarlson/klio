//! Body resolution: every expression typed, every name and call resolved to
//! a declaration, against the lexical scope tower.
//!
//! A scope holds the locals it declares, the implicit receivers it brings
//! into scope (a class's `this` and companion, an extension function's
//! receiver, a receiver lambda's receiver) and the smart casts in force in
//! it. Name lookup walks the scopes innermost first: locals, then each
//! implicit receiver's members and extensions, then the file's static
//! scope.

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
const calls = @import("calls.zig");
const census_mod = @import("census.zig");

const Allocator = std.mem.Allocator;
const Sema = sema_mod.Sema;
const Sym = symbols.Sym;
const TypeId = types.TypeId;
const Name = names_mod.Name;
const wk = names_mod.wk;
const Expr = ast.Expr;
const Span = span.Span;
const Receiver = records.Receiver;
const ImplicitKind = records.ImplicitKind;

pub const Local = struct { name: Name, sym: Sym };

pub const Recv = struct {
    ty: TypeId,
    kind: ImplicitKind,
    owner: Sym,
    /// `this@label` names it.
    label: Name,
};

pub const Narrow = struct { sym: Sym, ty: TypeId };

/// A value a call's context parameter can take from the scope: a context
/// parameter of the enclosing function or accessor, or a context of a
/// lambda or anonymous function of contextual function type.
pub const ContextValue = struct { ty: TypeId, sym: Sym };

pub const ScopeKind = enum { file, class, function, lambda, block };

pub const Scope = struct {
    parent: ?*Scope,
    kind: ScopeKind,
    /// The class, function or lambda symbol that opened the scope.
    owner: Sym = .none,
    /// The label `return@l` and `this@l` use: a function's or lambda's name.
    label: Name = .empty,
    locals: std.ArrayList(Local) = .empty,
    receivers: std.ArrayList(Recv) = .empty,
    contexts: std.ArrayList(ContextValue) = .empty,
    narrow: std.ArrayList(Narrow) = .empty,
    /// A class scope whose `this` is not in scope: a nested class sees its
    /// outer class's static scope only.
    static_only: bool = false,
    /// The primary constructor's plain parameters, visible to initializers.
    ctor_params: bool = false,
    /// A member function's or accessor's body, where the primary
    /// constructor's plain parameters are not in scope.
    member_body: bool = false,
    /// For a lambda: the types its `return@label` and last expression give.
    lambda_returns: ?*std.ArrayList(TypeId) = null,
    /// For a lambda: a `return@label` without a value was seen, which makes
    /// the lambda's result Unit.
    unit_return: bool = false,
    /// For a function: its declared return type, for `return`.
    ret: TypeId = .none,
};

/// What a delegated property with a written type expects of the call its
/// delegate expression makes: that its `getValue`, through its
/// `provideDelegate` when it has one, returns the property's type (and,
/// for a `var`, that its `setValue` takes it).
pub const DelegateExpect = struct {
    /// The called name of the delegate expression's call.
    anchor: Span,
    declared: TypeId,
    mutable: bool,
    this_ref: TypeId,
};

/// What a generic call may leave open for the expression that uses its
/// result.
pub const ArgMode = enum {
    /// Nothing: the call fixes every variable.
    none,
    /// A branch of an `if`, `when` or `?:`, or an operand, whose type
    /// joins others': variables nothing constrains stay open.
    branch,
    /// A call's argument: every variable the result mentions stays open,
    /// with its bounds, for the enclosing call to fix against its
    /// parameter.
    arg,
};

pub const Ctx = struct {
    s: *Sema,
    file: u32,
    scope: *Scope,
    /// Whether a generic call being resolved may leave variables open for
    /// what uses its result.
    in_arg: ArgMode = .none,
    /// Resolving a declaration only for its type (`inferPropertyType`):
    /// a property's setter waits for the ordinary pass.
    typing_only: bool = false,
    /// The node being resolved: the innermost expression, or the
    /// statement or declaration that holds it. Records made meanwhile
    /// belong to it.
    node: ast.NodeId = .none,
    /// The label the next lambda literal takes: written (`lit@{ ... }`) or
    /// the name of the function it is passed to. Taken by `calls.lambda`.
    lambda_label: Name = .empty,
    /// Set when a lambda's parameter or receiver type was left to builder
    /// inference: its body gave it its type.
    builder_typed: bool = false,
    /// Set when a lambda was analyzed with no function type expected of it
    /// (against a type variable or `Any`): its shape is its own header's, a
    /// guess the expected type may replace (`{ _ -> }` in `listOf` passed
    /// for a `List<String.(S) -> Unit>` takes a receiver).
    lambda_shape_guessed: bool = false,
    /// The innermost `try` being resolved: what its body and catches
    /// assign, for the smart casts its catches and finally see.
    try_log: ?*TryLog = null,
    /// A delegated property's written type, for the call its delegate
    /// expression makes: taken by that call before its lambdas and
    /// references are analyzed.
    delegate_expect: ?*const DelegateExpect = null,

    pub fn arena(self: *const Ctx) Allocator {
        return self.s.arena;
    }

    pub fn report(self: *Ctx, reason: census_mod.Reason, sp: Span, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try self.s.census.reportFmt(reason, self.file, sp, fmt, args);
    }

    /// `report`, with the facts the site's diagnostic draws on.
    pub fn reportFacts(self: *Ctx, reason: census_mod.Reason, sp: Span, facts: census_mod.Facts, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try self.s.census.reportFacts(reason, self.file, sp, facts, fmt, args);
    }

    /// How many records the current list holds, to find one added later.
    pub fn refCount(self: *const Ctx) usize {
        if (self.s.census.buffer) |b| return b.refs.items.len;
        return self.s.refs.items.len;
    }

    /// The call record written for `node` since the list held `since`.
    pub fn callRecordSince(self: *const Ctx, node: ast.NodeId, since: usize) ?*const records.CallRec {
        const list = if (self.s.census.buffer) |b| b.refs.items else self.s.refs.items;
        if (since > list.len) return null;
        var i = list.len;
        while (i > since) {
            i -= 1;
            const r = &list[i];
            if (r.node != node or r.file != self.file) continue;
            if (r.detail == .call) return r.detail.call;
        }
        return null;
    }

    pub fn addRef(self: *Ctx, r: records.Ref) Allocator.Error!void {
        if (self.s.census.muted != 0) return;
        var ref = r;
        ref.file = self.file;
        if (ref.node == .none) ref.node = self.node;
        if (self.s.census.buffer) |b| {
            try b.refs.append(self.s.arena, ref);
            b.resolved += 1;
            return;
        }
        try self.s.refs.append(self.s.arena, ref);
        self.s.census.resolved += 1;
    }

    /// Keeps an expression's type, under the rules `addRef` follows.
    /// `needs_record`: the expression's kind is one lowering reads a
    /// record for.
    pub fn addType(self: *Ctx, node: ast.NodeId, sp: Span, ty: TypeId, needs_record: bool) Allocator.Error!void {
        return self.addTypeEntry(.{ .file = self.file, .node = node, .sp = sp, .ty = ty, .needs_record = needs_record });
    }

    pub fn addTypeEntry(self: *Ctx, et: records.ExprType) Allocator.Error!void {
        if (self.s.census.muted != 0 or et.node == .none) return;
        if (self.s.census.buffer) |b| {
            try b.types.append(self.s.arena, et);
            return;
        }
        try self.s.expr_types.append(self.s.arena, et);
    }

    /// The current node could not be resolved because an operand already
    /// failed: its census site is elsewhere, and its missing record is not
    /// a gap of its own.
    pub fn failNode(self: *Ctx, sp: Span) Allocator.Error!void {
        return self.addType(self.node, sp, self.s.types.errType(), false);
    }

    /// Makes `n` the node records belong to until the returned value is
    /// passed to `leaveNode`.
    pub fn enterNode(self: *Ctx, n: ast.NodeId) ast.NodeId {
        const saved = self.node;
        if (n != .none) self.node = n;
        return saved;
    }

    pub fn leaveNode(self: *Ctx, saved: ast.NodeId) void {
        self.node = saved;
    }

    /// Starts recording into a fresh buffer; `commit` or `drop` ends it.
    pub fn beginBuffer(self: *Ctx) Allocator.Error!*census_mod.Buffer {
        const b = try self.s.arena.create(census_mod.Buffer);
        b.* = .{ .parent = self.s.census.buffer };
        self.s.census.buffer = b;
        return b;
    }

    /// Keeps what the buffer recorded, in the enclosing buffer or the
    /// analysis.
    pub fn commit(self: *Ctx, b: *census_mod.Buffer) Allocator.Error!void {
        const s = self.s;
        s.census.buffer = b.parent;
        for (b.sites.items) |site| try s.census.reportSite(site);
        if (b.parent) |p| {
            try p.refs.appendSlice(s.arena, b.refs.items);
            try p.types.appendSlice(s.arena, b.types.items);
            p.resolved += b.resolved;
        } else {
            try s.refs.appendSlice(s.arena, b.refs.items);
            try s.expr_types.appendSlice(s.arena, b.types.items);
            s.census.resolved += b.resolved;
        }
    }

    pub fn drop(self: *Ctx, b: *census_mod.Buffer) void {
        self.s.census.buffer = b.parent;
    }

    pub fn push(self: *Ctx, kind: ScopeKind, owner: Sym) Allocator.Error!*Scope {
        const sc = try self.s.arena.create(Scope);
        sc.* = .{ .parent = self.scope, .kind = kind, .owner = owner };
        self.scope = sc;
        return sc;
    }

    pub fn pop(self: *Ctx, sc: *Scope) void {
        self.scope = sc.parent.?;
    }

    pub fn declareLocal(self: *Ctx, n: Name, sym: Sym) Allocator.Error!void {
        try self.scope.locals.append(self.s.arena, .{ .name = n, .sym = sym });
    }

    pub fn intern(self: *Ctx, str: []const u8) Allocator.Error!Name {
        return self.s.names.intern(str);
    }

    /// The innermost function or lambda symbol, owner of a new local.
    pub fn localOwner(self: *const Ctx) Sym {
        var sc: ?*Scope = self.scope;
        while (sc) |c| : (sc = c.parent) {
            if (c.kind == .function or c.kind == .lambda or c.kind == .class) return c.owner;
        }
        return .none;
    }
};

// ---------------------------------------------------------------- driver --

pub fn resolveAll(s: *Sema, origins: []const sema_mod.Origin) Allocator.Error!void {
    var i: u32 = 0;
    while (i < s.files.items.len) : (i += 1) {
        const fc = s.files.items[i];
        var wanted = false;
        for (origins) |o| if (o == fc.origin) {
            wanted = true;
        };
        if (!wanted) continue;
        try resolveFile(s, i);
    }
}

/// The SAM constructor of every fun interface declared from `first` on,
/// made when its layer is added so its symbol has a fixed place.
pub fn samConstructorsFrom(s: *Sema, first: Sym) Allocator.Error!void {
    const n = s.syms.count();
    var i: u32 = @max(first.int(), 1);
    while (i < n) : (i += 1) {
        const sym = Sym.from(i);
        if (s.syms.kind(sym) != .class or !s.syms.flags(sym).fun_iface) continue;
        if (s.syms.classInfo(sym).kind != .interface) continue;
        var ctx = Ctx{ .s = s, .file = s.syms.get(sym).file, .scope = try fileScope(s) };
        _ = try calls.samConstructor(&ctx, sym);
    }
}

fn fileScope(s: *Sema) Allocator.Error!*Scope {
    const sc = try s.arena.create(Scope);
    sc.* = .{ .parent = null, .kind = .file };
    return sc;
}

pub fn resolveFile(s: *Sema, file: u32) Allocator.Error!void {
    const fc = s.files.items[file];
    try scope_mod.checkInheritedImports(s, file);
    var ctx = Ctx{ .s = s, .file = file, .scope = try fileScope(s) };
    for (fc.ast.decls) |*d| {
        const sym = declSym(s, fc.package, d) orelse continue;
        try resolveMemberDecl(&ctx, sym);
    }
}

/// The symbol collected for a declaration of `container`.
fn declSym(s: *Sema, container: Sym, d: *const ast.Decl) ?Sym {
    const name_str: []const u8 = switch (d.*) {
        .Function => |f| f.name.name,
        .Property => |p| p.name.name,
        .Class => |c| c.name.name,
        .Object => |o| o.name.name,
        .TypeAlias => |t| t.name.name,
    };
    const n = s.names.lookup(name_str) orelse return null;
    for (scope_mod.membersOf(s, container, n)) |m| {
        const sym = s.syms.get(m);
        const same = switch (d.*) {
            .Function => |*f| sym.decl == .function and sym.decl.function == f,
            .Property => |p| sym.decl == .property and sym.decl.property == p,
            .Class => |*c| sym.decl == .class and sym.decl.class == c,
            .Object => |*o| sym.decl == .object and sym.decl.object == o,
            .TypeAlias => |*t| sym.decl == .type_alias and sym.decl.type_alias == t,
        };
        if (same) return m;
    }
    return null;
}

/// Opens the class scopes a member of `cls` resolves in: the outer
/// classes' first, then `cls`'s own.
fn pushClassScopes(ctx: *Ctx, cls: Sym) Allocator.Error!void {
    var chain: std.ArrayList(Sym) = .empty;
    var cur = cls;
    while (cur != .none and ctx.s.syms.kind(cur) == .class) {
        // A class declared in a body keeps the scope that body opened for
        // it, where the enclosing locals and receivers are: the classes it
        // nests open on top of that (an inner class of an object
        // expression sees the class declaring the expression).
        if (ctx.s.local_class_scopes.get(cur)) |sc| {
            ctx.scope = sc;
            break;
        }
        try chain.append(ctx.arena(), cur);
        const owner = ctx.s.syms.owner(cur);
        if (owner == .none or ctx.s.syms.kind(owner) != .class) break;
        cur = owner;
    }
    // Outermost first. A class's `this` is visible from a nested class only
    // through `inner` classes.
    var this_visible = true;
    var i = chain.items.len;
    var visible_flags = try ctx.arena().alloc(bool, chain.items.len);
    {
        var j: usize = 0;
        while (j < chain.items.len) : (j += 1) {
            visible_flags[j] = this_visible;
            const c = chain.items[j];
            const info = ctx.s.syms.classInfo(c);
            if (!ctx.s.syms.flags(c).inner and info.kind != .anonymous) this_visible = false;
        }
    }
    while (i > 0) {
        i -= 1;
        try pushClassScope(ctx, chain.items[i], !visible_flags[i]);
    }
}

/// The innermost scope opened for class `cls`.
fn ownClassScope(ctx: *Ctx, cls: Sym) ?*Scope {
    var sc: ?*Scope = ctx.scope;
    while (sc) |c| : (sc = c.parent) {
        if (c.kind == .class and c.owner == cls) return c;
    }
    return null;
}

pub fn pushClassScope(ctx: *Ctx, cls: Sym, static_only: bool) Allocator.Error!void {
    const s = ctx.s;
    const sc = try ctx.push(.class, cls);
    sc.static_only = static_only;
    const info = s.syms.classInfo(cls);
    // An enum entry's body is `this@X` for its entry `X`.
    const name = s.str(s.syms.name(cls));
    const label = if (info.kind == .enum_entry and name.len > 1 and name[0] == '$') try s.names.intern(name[1..]) else s.syms.name(cls);
    sc.label = label;
    if (!static_only or info.kind == .object or info.kind == .companion) {
        const kind: ImplicitKind = if (info.kind == .object or info.kind == .companion) .object else .class_this;
        try sc.receivers.append(s.arena, .{ .ty = try headers.selfType(s, cls), .kind = kind, .owner = cls, .label = label });
    }
    // Companion objects of the class and its superclasses are implicit
    // receivers after `this`.
    var seen: std.AutoHashMapUnmanaged(Sym, void) = .empty;
    try pushCompanions(ctx, sc, cls, &seen);
}

fn pushCompanions(ctx: *Ctx, sc: *Scope, cls: Sym, seen: *std.AutoHashMapUnmanaged(Sym, void)) Allocator.Error!void {
    const s = ctx.s;
    if ((try seen.getOrPut(s.arena, cls)).found_existing) return;
    const comp = s.syms.classInfo(cls).companion;
    if (comp != .none and comp != cls) {
        try sc.receivers.append(s.arena, .{ .ty = try headers.selfType(s, comp), .kind = .object, .owner = comp, .label = s.syms.name(comp) });
    }
    for (try headers.supertypes(s, cls)) |st| {
        const sup = s.types.classSym(st);
        if (sup == .none or s.syms.classInfo(sup).kind == .interface) continue;
        try pushCompanions(ctx, sc, sup, seen);
    }
}

/// Resolves the bodies a member or top-level declaration owns.
fn resolveMemberDecl(ctx: *Ctx, sym: Sym) Allocator.Error!void {
    const s = ctx.s;
    const saved = ctx.scope;
    defer ctx.scope = saved;
    switch (s.syms.kind(sym)) {
        .function => try resolveFunction(ctx, sym),
        .property => try resolveProperty(ctx, sym),
        .class => try resolveClass(ctx, sym),
        else => {},
    }
}

/// A declaration's context parameters: the named ones are locals, and
/// each is a value calls can take a context argument from.
pub fn pushContextParams(ctx: *Ctx, sc: *Scope, cps: []const Sym) Allocator.Error!void {
    const s = ctx.s;
    for (cps) |p| {
        const n = s.syms.name(p);
        if (!std.mem.eql(u8, s.str(n), "_")) try ctx.declareLocal(n, p);
        try sc.contexts.append(s.arena, .{ .ty = try headers.paramType(s, p), .sym = p });
    }
}

/// Opens a function's scope: its type parameters are in the symbol, its
/// value parameters become locals, its extension receiver an implicit
/// receiver.
fn pushFunctionScope(ctx: *Ctx, f: Sym) Allocator.Error!*Scope {
    const s = ctx.s;
    try headers.functionHeader(s, f);
    const sc = try ctx.push(.function, f);
    sc.label = s.syms.name(f);
    const owner = s.syms.owner(f);
    sc.member_body = owner != .none and s.syms.kind(owner) == .class;
    const info = s.syms.functionInfo(f);
    for (info.params) |p| try ctx.declareLocal(s.syms.name(p), p);
    try pushContextParams(ctx, sc, info.context_params);
    if (info.receiver != .none) {
        try sc.receivers.append(s.arena, .{ .ty = info.receiver, .kind = .extension, .owner = f, .label = s.syms.name(f) });
    }
    sc.ret = info.ret;
    return sc;
}

fn resolveFunction(ctx: *Ctx, f: Sym) Allocator.Error!void {
    const s = ctx.s;
    const sym = s.syms.get(f);
    const fd = switch (sym.decl) {
        .function => |fd| fd,
        else => return,
    };
    // A superseded `expect` has no body that runs, but its defaults are
    // the ones its `actual` evaluates.
    const superseded = s.syms.flags(f).superseded;
    if (superseded and !hasDefaults(s, f)) return;
    const owner = sym.owner;
    if (owner != .none and s.syms.kind(owner) == .class) try pushClassScopes(ctx, owner);
    if (s.syms.functionInfo(f).body_done) return;
    s.syms.functionInfo(f).body_done = true;
    const sc = try pushFunctionScope(ctx, f);
    try resolveParamDefaults(ctx, s.syms.functionInfo(f).params);
    if (superseded) {
        ctx.pop(sc);
        return;
    }
    if (fd.body) |*b| {
        const ret = s.syms.functionInfo(f).ret;
        switch (b.*) {
            .Block => |*blk| _ = try block(ctx, blk, .none),
            .Expr => |*e| {
                const t = try expr(ctx, e, ret);
                if (s.syms.functionInfo(f).ret == .none) s.syms.functionInfo(f).ret = try escapingType(s, f, t);
            },
        }
    }
    ctx.pop(sc);
}

fn hasDefaults(s: *Sema, f: Sym) bool {
    for (s.syms.functionInfo(f).params) |p| {
        if (s.syms.flags(p).has_default) return true;
    }
    return false;
}

/// The parameter defaults of a superseded `expect` class's constructors
/// and member functions, nested classes included: its `actual` class's
/// members evaluate them.
fn resolveExpectClassDefaults(ctx: *Ctx, cls: Sym) Allocator.Error!void {
    const s = ctx.s;
    const saved = ctx.scope;
    defer ctx.scope = saved;
    // The defaults run on an instance of the actual class: its members are
    // what they name (`stop(gracePeriodMillis: Long =
    // engineConfig.shutdownGracePeriod)` reads the actual's
    // `engineConfig`, not the expect's, which has no getter).
    const actual = s.syms.by_fqn.get(s.syms.classInfo(cls).fqn) orelse cls;
    try pushClassScopes(ctx, if (actual != cls and s.syms.kind(actual) == .class) actual else cls);
    const class_scope = ctx.scope;
    var it = s.syms.classInfo(cls).members.iterator();
    while (it.next()) |e| {
        for (e.value_ptr.items) |m| {
            if (s.syms.owner(m) != cls) continue;
            ctx.scope = class_scope;
            switch (s.syms.kind(m)) {
                // An expect member has no body: only its defaults resolve.
                .function => if (hasDefaults(s, m)) try resolveFunctionInClass(ctx, m),
                .constructor => if (hasDefaults(s, m)) {
                    try headers.functionHeader(s, m);
                    const sc = try ctx.push(.function, m);
                    for (s.syms.functionInfo(m).params) |p| try ctx.declareLocal(s.syms.name(p), p);
                    try resolveParamDefaults(ctx, s.syms.functionInfo(m).params);
                    ctx.pop(sc);
                },
                .class => {
                    ctx.scope = saved;
                    try resolveExpectClassDefaults(ctx, m);
                },
                else => {},
            }
        }
    }
}

fn resolveParamDefaults(ctx: *Ctx, params: []const Sym) Allocator.Error!void {
    const s = ctx.s;
    for (params) |p| {
        const sym = s.syms.get(p);
        const default: ?*const Expr = switch (sym.decl) {
            .param => |pd| pd.default,
            .class_param => |cp| if (cp.default) |*d| d else null,
            else => null,
        };
        // A `vararg` parameter's default is the whole array (`vararg val
        // arg: String = []`).
        if (default) |d| try typedValue(ctx, d, try symbolType(ctx, p));
    }
}

/// A value whose declaration writes its type: a default argument, an
/// expression body, an initializer. Its type is a subtype of the declared
/// one, which a call inferring a variable from the enclosing lambda's body
/// learns (`fun source(): Buildee<Target> = this` in a builder lambda).
fn typedValue(ctx: *Ctx, e: *const Expr, declared: TypeId) Allocator.Error!void {
    const t = try expr(ctx, e, declared);
    try infer.noteExpected(ctx.s, t, declared);
}

/// A delegated property whose type is written takes what its delegate's
/// `getValue` returns only when that fits it: kotlinc refuses `val q: P
/// by lazy { enc(raw) }` for an `enc` returning a `B`.
fn checkDelegateValue(ctx: *Ctx, d: *const Expr, got: TypeId, declared: TypeId) Allocator.Error!void {
    const s = ctx.s;
    if (got == .none or declared == .none or s.types.isErr(got) or s.types.isErr(declared)) return;
    const g = try infer.zonk(s, got);
    if (infer.hasOpenVar(s, g) or try subtyping.isSubtype(s, g, declared)) return;
    const msg = try std.fmt.allocPrint(s.arena, "the delegate's `getValue` returns `{s}`, but the property is a `{s}`", .{ try sema_mod.diagnose.typeText(s, s.arena, g), try sema_mod.diagnose.typeText(s, s.arena, declared) });
    try ctx.reportFacts(.type_mismatch, d.span(), .{ .message = msg }, "{s}", .{msg});
}

/// The type an expression body gives a function that does not write one.
pub fn inferReturnType(s: *Sema, f: Sym) Allocator.Error!TypeId {
    const info = s.syms.functionInfo(f);
    if (info.body_done) return if (info.ret != .none) info.ret else s.types.errType();
    // Another declaration's body resolves for real even when the caller is
    // only speculating.
    const muted = s.census.muted;
    const buffer = s.census.buffer;
    s.census.muted = 0;
    s.census.buffer = null;
    defer {
        s.census.muted = muted;
        s.census.buffer = buffer;
    }
    const sym = s.syms.get(f);
    if (sym.decl != .function) return s.types.errType();
    const file = sym.file;
    if (file == symbols.NO_FILE) return s.types.errType();
    var ctx = Ctx{ .s = s, .file = file, .scope = try fileScope(s) };
    // A member of a class declared in a body resolves in the scope that
    // body opened, where the enclosing locals are.
    if (s.local_class_scopes.get(sym.owner)) |sc| {
        ctx.scope = sc;
        try resolveFunctionInClass(&ctx, f);
    } else {
        try resolveFunction(&ctx, f);
    }
    const r = s.syms.functionInfo(f).ret;
    return if (r != .none) r else s.types.errType();
}

fn resolveProperty(ctx: *Ctx, p: Sym) Allocator.Error!void {
    const s = ctx.s;
    const owner = s.syms.owner(p);
    if (owner != .none and s.syms.kind(owner) == .class) try pushClassScopes(ctx, owner);
    try resolvePropertyIn(ctx, p);
}

/// A property's initializer, delegate, backing field and accessors, in the
/// scope already open: its class's for a member, with the primary
/// constructor's parameters its initializer sees.
fn resolvePropertyIn(ctx: *Ctx, p: Sym) Allocator.Error!void {
    const s = ctx.s;
    const sym = s.syms.get(p);
    if (sym.flags.superseded) return;
    const pd = switch (sym.decl) {
        .property => |pd| pd,
        // A constructor property's value is its parameter's.
        else => return,
    };
    const saved_node = ctx.enterNode(pd.id);
    defer ctx.leaveNode(saved_node);
    const info = s.syms.propertyInfo(p);
    if (info.body_done) {
        // Typed early: the setter comes now.
        if (info.setter_pending and !ctx.typing_only) {
            info.setter_pending = false;
            const sc = try pushPropertyScope(ctx, p);
            defer ctx.pop(sc);
            if (pd.setter) |st| try resolveSetter(ctx, p, st);
        }
        return;
    }
    info.body_done = true;
    try headers.propertyHeader(s, p);
    // The delegate is made where the property is declared, once per
    // instance of its class, before any extension receiver exists: `this`
    // in it is the class's (`val A.x by ::prop` binds the `prop` of the
    // instance declaring `x`, not of the receiver `x` is read on). Its
    // `getValue` takes the extension receiver as `thisRef`.
    var delegate_t: TypeId = .none;
    var host: TypeId = .none;
    if (pd.delegate) |d| {
        const dsc = try ctx.push(.function, p);
        dsc.label = sym.name;
        defer ctx.pop(dsc);
        // `getValue`'s `thisRef` is the extension receiver of an extension
        // property, though the delegate cannot see it.
        host = try calls.thisRefType(ctx);
        const recv = s.syms.propertyInfo(p).receiver;
        const this_ref = if (recv != .none) recv else host;
        delegate_t = try delegateExpr(ctx, d, s.syms.propertyInfo(p).ty, pd.mutable, this_ref);
    }
    const sc = try pushPropertyScope(ctx, p);
    defer ctx.pop(sc);
    const declared = s.syms.propertyInfo(p).ty;
    if (pd.delegate) |d| {
        const t = try calls.delegateAccess(ctx, d, delegate_t, p, pd.mutable, host);
        if (s.syms.propertyInfo(p).ty == .none) s.syms.propertyInfo(p).ty = t else try checkDelegateValue(ctx, d, t, declared);
    }
    if (pd.init) |i| {
        const t = try expr(ctx, i, declared);
        if (s.syms.propertyInfo(p).ty == .none) s.syms.propertyInfo(p).ty = try escapingType(s, p, try widenForDecl(s, t)) else try infer.noteExpected(s, t, declared);
    }
    if (pd.explicit_field) |ef| {
        var ft: TypeId = if (ef.ty) |tr| try headers.resolveTypeRef(s, typeCtx(ctx), tr) else .none;
        if (ef.init) |i| {
            const it = try expr(ctx, i, ft);
            if (ft == .none) ft = try widenForDecl(s, it);
        }
        s.syms.propertyInfo(p).field_ty = ft;
    }
    if (pd.getter) |g| {
        const gsc = try ctx.push(.function, p);
        gsc.member_body = true;
        gsc.label = sym.name;
        const field_t = s.syms.propertyInfo(p).ty;
        const t = try accessorBody(ctx, g, field_t);
        if (s.syms.propertyInfo(p).ty == .none) {
            s.syms.propertyInfo(p).ty = t;
        } else if (g.body == .Expr) try infer.noteExpected(s, t, field_t);
        ctx.pop(gsc);
    }
    if (pd.setter) |st| {
        if (ctx.typing_only) {
            s.syms.propertyInfo(p).setter_pending = true;
        } else try resolveSetter(ctx, p, st);
    }
}

/// The scope a property's initializer and accessors resolve in: its
/// extension receiver and context parameters.
fn pushPropertyScope(ctx: *Ctx, p: Sym) Allocator.Error!*Scope {
    const s = ctx.s;
    const sc = try ctx.push(.function, p);
    sc.label = s.syms.name(p);
    const recv = s.syms.propertyInfo(p).receiver;
    if (recv != .none) try sc.receivers.append(s.arena, .{ .ty = recv, .kind = .extension, .owner = p, .label = s.syms.name(p) });
    try pushContextParams(ctx, sc, s.syms.propertyInfo(p).context_params);
    return sc;
}

fn resolveSetter(ctx: *Ctx, p: Sym, st: *const ast.Accessor) Allocator.Error!void {
    const s = ctx.s;
    const ssc = try ctx.push(.function, p);
    defer ctx.pop(ssc);
    ssc.member_body = true;
    ssc.label = s.syms.name(p);
    const vt = s.syms.propertyInfo(p).ty;
    const param_name = if (st.params.len != 0) st.params[0].name else "value";
    const vsym = try newLocal(ctx, try ctx.intern(param_name), if (st.params.len != 0) st.params[0] else .{ .name = "value", .span = st.span }, vt, false);
    try ctx.declareLocal(s.syms.name(vsym), vsym);
    // The setter's value parameter, found by the accessor's node.
    try ctx.addRef(.{ .file = ctx.file, .node = st.id, .anchor = if (st.params.len != 0) st.params[0].span else st.span, .kind = .decl, .target = vsym });
    ssc.ret = s.t.unit;
    _ = try accessorBody(ctx, st, vt);
}

fn accessorBody(ctx: *Ctx, acc: *const ast.Accessor, field_t: TypeId) Allocator.Error!TypeId {
    const s = ctx.s;
    // `field` is the backing field inside an accessor.
    const fsym = try newLocal(ctx, wk.field, .{ .name = "field", .span = acc.span }, field_t, true);
    try ctx.declareLocal(wk.field, fsym);
    if (ctx.scope.owner != .none and s.syms.kind(ctx.scope.owner) == .property) {
        try s.backing_fields.put(s.arena, fsym, ctx.scope.owner);
    }
    ctx.scope.ret = field_t;
    return switch (acc.body) {
        .Block => |*b| blk: {
            _ = try block(ctx, b, .none);
            break :blk if (field_t != .none) field_t else s.types.errType();
        },
        .Expr => |*e| try expr(ctx, e, field_t),
    };
}

/// `e!!` where `e`'s type is a variable a call left open with only lower
/// bounds (`with(x) { restore(y) }!!`): the variable is the common
/// supertype of what flows into it, fixed here, so `!!` takes its
/// non-null part.
fn fixAtNotNull(s: *Sema, t: TypeId) Allocator.Error!TypeId {
    const z = try infer.zonk(s, t);
    const v = switch (s.types.get(z)) {
        .variable => |v| v,
        else => return t,
    };
    const b = s.open_var_bounds.get(v.id) orelse return t;
    if (b.lower.len == 0 or b.upper.len != 0) return t;
    var lowers: std.ArrayList(TypeId) = .empty;
    for (b.lower) |lb| {
        const lz = try infer.zonk(s, lb);
        if (infer.hasOpenVar(s, lz)) return t;
        try lowers.append(s.arena, lz);
    }
    const fixed = try subtyping.commonSupertype(s, lowers.items);
    try s.var_solution.put(s.arena, v.id, fixed);
    return infer.zonk(s, t);
}

/// The type a declaration infers from `t` as seen outside it: an anonymous
/// object's type does not leave a declaration that is not private or
/// local, which exposes the object's single supertype (else `Any`).
fn escapingType(s: *Sema, decl: Sym, t: TypeId) Allocator.Error!TypeId {
    if (t == .none or s.types.isErr(t)) return t;
    const nn = try s.types.makeNotNull(t);
    const c = s.types.classSym(nn);
    if (c == .none or s.syms.kind(c) != .class or s.syms.classInfo(c).kind != .anonymous) return t;
    if (s.syms.flags(decl).visibility == .private) return t;
    const owner = s.syms.owner(decl);
    // A local declaration (owned by a function or lambda) keeps it, and so
    // does a member of a local class or object expression, which nothing
    // outside can name (`object { val b = object { val a = 1 } }.b.a`).
    if (owner != .none and s.syms.kind(owner) != .class and s.syms.kind(owner) != .package) return t;
    if (owner != .none and s.syms.kind(owner) == .class and sema_mod.render.isLocalClass(s, owner)) return t;
    const sts = try headers.supertypes(s, c);
    const approx = if (sts.len == 1) sts[0] else s.t.any;
    return if (s.types.isNullable(t)) s.types.makeNullable(approx) else approx;
}

/// The declared type a value gets from its initializer: an integer literal
/// becomes `Int` (or `Long`).
fn widenForDecl(s: *Sema, t: TypeId) Allocator.Error!TypeId {
    return switch (s.types.get(t)) {
        .int_lit => |l| infer.intLitDefault(s, l),
        else => infer.zonk(s, t),
    };
}

/// A delegate expression, inferred with its `getValue`: the property's
/// owner is its `thisRef`, and with a declared type, `var x: T? by
/// holder(null)` makes `getValue` give (and, for a `var`, `setValue`
/// take) a `T?`, which fixes `holder`'s type argument.
fn delegateExpr(ctx: *Ctx, d: *const Expr, declared_in: TypeId, mutable: bool, this_ref: TypeId) Allocator.Error!TypeId {
    const s = ctx.s;
    const declared: TypeId = if (declared_in == .none or s.types.isErr(declared_in)) .none else declared_in;
    const saved = ctx.in_arg;
    const saved_expect = ctx.delegate_expect;
    ctx.in_arg = .arg;
    // The written type reaches the delegate's call as kotlinc's delegate
    // inference has it, before the call's lambdas and references are
    // analyzed: `val v: IC<String> by lazy(::IC)` makes `::IC` an
    // `() -> IC<String>`.
    const expect: DelegateExpect = .{ .anchor = if (d.* == .Call) lastNameSpan(d.Call.callee) else d.span(), .declared = declared, .mutable = mutable, .this_ref = this_ref };
    if (declared != .none and d.* == .Call) ctx.delegate_expect = &expect;
    const dt = expr(ctx, d, .none) catch |e| {
        ctx.in_arg = saved;
        ctx.delegate_expect = saved_expect;
        return e;
    };
    ctx.in_arg = saved;
    ctx.delegate_expect = saved_expect;
    const z = try infer.zonk(s, dt);
    if (!infer.hasOpenVar(s, z)) return z;
    var sys = infer.System.init(s);
    try sys.adopt(z);
    const ret = try calls.delegateValueType(ctx, &sys, z, this_ref);
    if (ret != null and declared != .none) {
        var trial = try sys.clone();
        const fits = try trial.constrain(ret.?, declared) and (!mutable or try trial.constrain(declared, ret.?));
        if (fits) {
            _ = try sys.constrain(ret.?, declared);
            if (mutable) _ = try sys.constrain(declared, ret.?);
        }
    }
    _ = try sys.solve(false);
    return infer.zonk(s, z);
}

/// The type an initializer, delegate or getter gives a property that does
/// not write one.
pub fn inferPropertyType(s: *Sema, p: Sym) Allocator.Error!TypeId {
    const sym = s.syms.get(p);
    if (sym.file == symbols.NO_FILE) return s.types.errType();
    if (s.syms.propertyInfo(p).body_done) {
        const t = s.syms.propertyInfo(p).ty;
        return if (t != .none) t else s.types.errType();
    }
    const muted = s.census.muted;
    const buffer = s.census.buffer;
    s.census.muted = 0;
    s.census.buffer = null;
    defer {
        s.census.muted = muted;
        s.census.buffer = buffer;
    }
    var ctx = Ctx{ .s = s, .file = sym.file, .scope = try fileScope(s), .typing_only = true };
    try openMemberScope(&ctx, sym.owner);
    try resolvePropertyIn(&ctx, p);
    const t = s.syms.propertyInfo(p).ty;
    return if (t != .none) t else s.types.errType();
}

/// Opens the scope a member of `owner` resolves in when its type is asked
/// for before its class's body reaches it: the class scopes (a class
/// declared in a body keeps the scope that body opened, where the
/// enclosing locals are) and the primary constructor's parameters.
fn openMemberScope(ctx: *Ctx, owner: Sym) Allocator.Error!void {
    const s = ctx.s;
    if (owner == .none or s.syms.kind(owner) != .class) return;
    if (s.local_class_scopes.get(owner)) |sc| ctx.scope = sc else try pushClassScopes(ctx, owner);
    const primary = s.syms.classInfo(owner).primary_ctor;
    if (primary != .none) _ = try pushPlainCtorParams(ctx, primary);
}

/// A scope with the primary constructor's parameters that are not
/// properties: in initializers, a `val`/`var` parameter is the property.
fn pushPlainCtorParams(ctx: *Ctx, primary: Sym) Allocator.Error!*Scope {
    const s = ctx.s;
    try headers.functionHeader(s, primary);
    const sc = try ctx.push(.function, primary);
    sc.ctor_params = true;
    for (s.syms.functionInfo(primary).params) |p| {
        const decl = s.syms.get(p).decl;
        if (decl == .class_param and decl.class_param.property != null) continue;
        try ctx.declareLocal(s.syms.name(p), p);
    }
    return sc;
}

/// Whether scope `c`'s locals are visible from where the walk started: a
/// constructor's plain parameters are not, once the walk has left a
/// member's body. `hide` carries that across the walk.
pub fn localsVisible(c: *const Scope, hide: *bool) bool {
    const visible = !(c.ctor_params and hide.*);
    if (c.member_body) hide.* = true;
    return visible;
}

fn resolveClass(ctx: *Ctx, cls: Sym) Allocator.Error!void {
    const s = ctx.s;
    const sym = s.syms.get(cls);
    if (sym.flags.superseded) return resolveExpectClassDefaults(ctx, cls);
    const saved = ctx.scope;
    defer ctx.scope = saved;
    // The header's constructor arguments and delegates resolve in the
    // primary constructor's scope, where its parameters are locals.
    try pushClassScopes(ctx, cls);
    const ctor_scope = try classInit(ctx, cls);
    // Property initializers and init blocks see the constructor's
    // parameters; member functions do not.
    var it = s.syms.classInfo(cls).members.iterator();
    var member_list: std.ArrayList(Sym) = .empty;
    while (it.next()) |e| try member_list.appendSlice(s.arena, e.value_ptr.items);
    std.mem.sort(Sym, member_list.items, {}, struct {
        fn lt(_: void, a: Sym, b: Sym) bool {
            return a.int() < b.int();
        }
    }.lt);
    for (member_list.items) |m| {
        if (s.syms.owner(m) != cls) continue;
        switch (s.syms.kind(m)) {
            .property => {
                const inner_saved = ctx.scope;
                try resolveProperty(ctx, m);
                ctx.scope = inner_saved;
            },
            else => {},
        }
    }
    if (ctor_scope) |sc| ctx.pop(sc);
    for (member_list.items) |m| {
        if (s.syms.owner(m) != cls) continue;
        switch (s.syms.kind(m)) {
            .function => {
                const inner_saved = ctx.scope;
                try resolveFunctionInClass(ctx, m);
                ctx.scope = inner_saved;
            },
            .constructor => {
                if (s.syms.get(m).decl != .secondary_ctor) continue;
                const inner_saved = ctx.scope;
                try secondaryCtor(ctx, cls, m);
                ctx.scope = inner_saved;
            },
            .class => {
                const inner_saved = ctx.scope;
                ctx.scope = saved;
                try resolveClass(ctx, m);
                ctx.scope = inner_saved;
            },
            else => {},
        }
    }
}

/// Resolves what a class's construction runs, with its class scope open:
/// parameter defaults and supertype arguments see every constructor
/// parameter; init blocks and property initializers (in the scope this
/// returns, which the caller pops after them) see the plain parameters,
/// since a `val`/`var` parameter there is the property.
fn classInit(ctx: *Ctx, cls: Sym) Allocator.Error!?*Scope {
    const s = ctx.s;
    const primary = s.syms.classInfo(cls).primary_ctor;
    const params: []const Sym = if (primary != .none) blk: {
        try headers.functionHeader(s, primary);
        break :blk s.syms.functionInfo(primary).params;
    } else &.{};
    {
        const sc = try ctx.push(.function, if (primary != .none) primary else cls);
        for (params) |p| try ctx.declareLocal(s.syms.name(p), p);
        try resolveParamDefaults(ctx, params);
        // The header runs before the instance exists: its `this` is not in
        // scope there, its static scope is (an object expression's `this`
        // in its supertype's arguments is the supertype's companion, else
        // the enclosing receiver).
        const own = ownClassScope(ctx, cls);
        const all_receivers = if (own) |o| o.receivers else std.ArrayList(Recv).empty;
        if (own) |o| {
            var header: std.ArrayList(Recv) = .empty;
            for (o.receivers.items) |r| {
                if (r.kind == .class_this and r.owner == cls) continue;
                try header.append(s.arena, r);
            }
            o.receivers = header;
        }
        defer if (own) |o| {
            o.receivers = all_receivers;
        };
        switch (s.syms.get(cls).decl) {
            .class => |c| {
                // An enum entry's body class takes the entry's arguments,
                // which `enumEntry` resolves on the enum class.
                const saved_node = ctx.enterNode(c.id);
                defer ctx.leaveNode(saved_node);
                if (s.syms.classInfo(cls).kind != .enum_entry) try superCalls(ctx, cls, c.supertypes, c.supertype_args, c.x().supertype_arg_names, c.supertype_delegates);
            },
            .object => |o| {
                const saved_node = ctx.enterNode(o.id);
                defer ctx.leaveNode(saved_node);
                try superCalls(ctx, cls, o.supertypes, o.supertype_args, o.supertype_arg_names, o.supertype_delegates);
            },
            .object_literal => |o| try superCalls(ctx, cls, o.supertypes, o.supertype_args, o.supertype_arg_names, o.supertype_delegates),
            else => {},
        }
        ctx.pop(sc);
        // An enum's entries are made by its static initializer: the
        // class's static scope is in scope there, its `this` and its
        // constructor's parameters are not (`Alpha(run { ... })` is the
        // top-level `run`, not `this@Foo.run`).
        switch (s.syms.get(cls).decl) {
            .class => |c| for (c.x().enum_entries) |*e| try enumEntry(ctx, cls, e),
            else => {},
        }
    }
    if (primary == .none) {
        switch (s.syms.get(cls).decl) {
            .class => |c| {
                for (c.x().init_blocks) |*b| _ = try block(ctx, b, .none);
            },
            .object => |o| for (o.init_blocks) |*b| {
                _ = try block(ctx, b, .none);
            },
            .object_literal => |o| for (o.init_blocks) |*b| {
                _ = try block(ctx, b, .none);
            },
            else => {},
        }
        return null;
    }
    const sc = try pushPlainCtorParams(ctx, primary);
    switch (s.syms.get(cls).decl) {
        .class => |c| {
            for (c.x().init_blocks) |*b| _ = try block(ctx, b, .none);
        },
        .object => |o| for (o.init_blocks) |*b| {
            _ = try block(ctx, b, .none);
        },
        .object_literal => |o| for (o.init_blocks) |*b| {
            _ = try block(ctx, b, .none);
        },
        else => {},
    }
    return sc;
}

/// A member function whose class scopes are already open.
fn resolveFunctionInClass(ctx: *Ctx, f: Sym) Allocator.Error!void {
    const s = ctx.s;
    const sym = s.syms.get(f);
    const fd = switch (sym.decl) {
        .function => |fd| fd,
        else => return,
    };
    if (sym.flags.superseded) return;
    if (s.syms.functionInfo(f).body_done) return;
    s.syms.functionInfo(f).body_done = true;
    const sc = try pushFunctionScope(ctx, f);
    try resolveParamDefaults(ctx, s.syms.functionInfo(f).params);
    if (fd.body) |*b| {
        const ret = s.syms.functionInfo(f).ret;
        switch (b.*) {
            .Block => |*blk| _ = try block(ctx, blk, .none),
            .Expr => |*e| {
                const t = try expr(ctx, e, ret);
                if (s.syms.functionInfo(f).ret == .none) s.syms.functionInfo(f).ret = try escapingType(s, f, try widenForDecl(s, t)) else try infer.noteExpected(s, t, ret);
            },
        }
    }
    ctx.pop(sc);
}

fn secondaryCtor(ctx: *Ctx, cls: Sym, ctor: Sym) Allocator.Error!void {
    const s = ctx.s;
    const sc_decl = s.syms.get(ctor).decl.secondary_ctor;
    const saved_node = ctx.enterNode(sc_decl.id);
    defer ctx.leaveNode(saved_node);
    try headers.functionHeader(s, ctor);
    const sc = try ctx.push(.function, ctor);
    for (s.syms.functionInfo(ctor).params) |p| try ctx.declareLocal(s.syms.name(p), p);
    try resolveParamDefaults(ctx, s.syms.functionInfo(ctor).params);
    switch (sc_decl.delegation) {
        .This => |args| _ = try calls.delegationCall(ctx, cls, sc_decl.span, args, sc_decl.delegation_arg_names, false),
        .Super => |args| {
            const sup = superClassType(s, cls);
            if (sup != .none) _ = try calls.delegationCall(ctx, s.types.classSym(sup), sc_decl.span, args, sc_decl.delegation_arg_names, true);
        },
        .None => {},
    }
    if (sc_decl.body) |*b| _ = try block(ctx, b, .none);
    ctx.pop(sc);
}

fn superClassType(s: *Sema, cls: Sym) TypeId {
    const sts = headers.supertypes(s, cls) catch return .none;
    for (sts) |st| {
        const c = s.types.classSym(st);
        if (c == .none) continue;
        if (s.syms.classInfo(c).kind != .interface) return st;
    }
    return .none;
}

/// `: Base(args)` constructor calls and `: Iface by delegate` expressions.
fn superCalls(ctx: *Ctx, cls: Sym, supertypes: []const ast.TypeRef, args: []const ?[]Expr, arg_names: []const ?[]const ?[]const u8, delegates: []const ?Expr) Allocator.Error!void {
    const s = ctx.s;
    // The supertypes as the header resolves them: without the class's own
    // nested classifiers (a superclass's private nested `OtherClass<T>`
    // does not shadow the `OtherClass` the header names).
    const tctx = headers.TypeCtx{ .decl = cls, .file = ctx.file, .header = true };
    for (supertypes, 0..) |*tr, i| {
        if (i < args.len) {
            if (args[i]) |a| {
                const st = try headers.resolveTypeRef(s, tctx, tr);
                const target = s.types.classSym(st);
                if (target != .none) {
                    const names: []const ?[]const u8 = if (i < arg_names.len) (arg_names[i] orelse &.{}) else &.{};
                    _ = try calls.superTypeCall(ctx, st, tr.span, a, names);
                }
            }
        }
        if (i < delegates.len) {
            // `: I<V> by Impl(x)`: the delegate is expected to be the
            // interface it implements.
            if (delegates[i]) |*d| try typedValue(ctx, d, try headers.resolveTypeRef(s, tctx, tr));
        }
    }
}

fn enumEntry(ctx: *Ctx, cls: Sym, e: *const ast.EnumEntry) Allocator.Error!void {
    const s = ctx.s;
    const saved = ctx.enterNode(e.id);
    defer ctx.leaveNode(saved);
    // Every entry constructs, with or without arguments: `A` in an enum
    // whose constructors are all secondary calls the one taking none.
    const self_t = try headers.selfType(s, cls);
    _ = try calls.superTypeCall(ctx, self_t, e.name.span, e.args, e.arg_names);
}

// ------------------------------------------------------------ statements --

pub fn block(ctx: *Ctx, b: *const ast.Block, expected: TypeId) Allocator.Error!TypeId {
    const sc = try ctx.push(.block, .none);
    defer ctx.pop(sc);
    const t = try blockIn(ctx, b.stmts, expected);
    try flowOut(ctx, sc);
    return t;
}

/// A lambda's statements in its scope `sc`. The last statement's value is
/// the lambda's result, unless a `return@label` without a value came before
/// it: the result is then Unit and the last statement is coerced to it
/// (`run { if (b) return@run; 42 }` is Unit, and
/// `{ if (b) return@let; materialize() }` calls `materialize<Unit>()`).
pub fn lambdaStatements(ctx: *Ctx, sc: *const Scope, stmts: []const ast.Stmt, expected: TypeId) Allocator.Error!TypeId {
    const s = ctx.s;
    var last: TypeId = s.t.unit;
    const saved_arg = ctx.in_arg;
    defer ctx.in_arg = saved_arg;
    for (stmts, 0..) |*st, i| {
        const is_last = i + 1 == stmts.len;
        const coerced = is_last and sc.unit_return;
        ctx.in_arg = if (is_last and !coerced) saved_arg else .none;
        const exp: TypeId = if (!is_last) .none else if (coerced) s.t.unit else expected;
        last = try stmt(ctx, st, exp);
        if (coerced) last = s.t.unit;
    }
    return last;
}

/// The statements of a block in the current scope; the type is the last
/// statement's when it is an expression.
pub fn blockIn(ctx: *Ctx, stmts: []const ast.Stmt, expected: TypeId) Allocator.Error!TypeId {
    const s = ctx.s;
    var last: TypeId = s.t.unit;
    const saved_arg = ctx.in_arg;
    defer ctx.in_arg = saved_arg;
    for (stmts, 0..) |*st, i| {
        const is_last = i + 1 == stmts.len;
        // Only the block's result can leave inference open for its user.
        ctx.in_arg = if (is_last) saved_arg else .none;
        last = try stmt(ctx, st, if (is_last) expected else .none);
    }
    return last;
}

fn stmt(ctx: *Ctx, st: *const ast.Stmt, expected: TypeId) Allocator.Error!TypeId {
    const s = ctx.s;
    if (st.* != .Expr) ctx.in_arg = .none;
    switch (st.*) {
        .Expr => |*e| return expr(ctx, e, expected),
        .Decl => |d| {
            try localDecl(ctx, d);
            return s.t.unit;
        },
        .Assign => |a| {
            const saved = ctx.enterNode(a.id);
            defer ctx.leaveNode(saved);
            try assignment(ctx, a);
            return s.t.unit;
        },
        .DestructuringDecl => |d| {
            const saved = ctx.enterNode(d.id);
            defer ctx.leaveNode(saved);
            const t = try expr(ctx, &d.init, .none);
            try destructure(ctx, d.names, d.by_name, d.sources, t, d.init.span(), d.mutable);
            return s.t.unit;
        },
    }
}

/// `val (a, b) = x`: `componentN` on `x` for each name.
pub fn destructure(ctx: *Ctx, idents: []const ast.Ident, by_name: bool, sources: []const ast.Ident, t: TypeId, anchor: Span, mutable: bool) Allocator.Error!void {
    const s = ctx.s;
    for (idents, 0..) |id, i| {
        // `_` takes nothing: its `componentN` is not called. By name,
        // `_ = prop` still reads the property.
        if (id.isPlaceholder()) {
            if (by_name and i < sources.len and !sources[i].isPlaceholder()) {
                _ = try calls.propertyOn(ctx, t, try ctx.intern(sources[i].name), sources[i].span);
            }
            continue;
        }
        var et: TypeId = s.types.errType();
        if (by_name and i < sources.len) {
            et = try calls.propertyOn(ctx, t, try ctx.intern(sources[i].name), sources[i].span);
        } else {
            et = try calls.componentCall(ctx, t, i + 1, id.span, anchor);
        }
        const sym = try newLocal(ctx, try ctx.intern(id.name), id, et, mutable);
        try ctx.declareLocal(s.syms.name(sym), sym);
        try ctx.addRef(.{ .file = ctx.file, .anchor = id.span, .kind = .decl, .target = sym });
    }
}

pub fn newLocal(ctx: *Ctx, n: Name, id: ast.Ident, ty: TypeId, mutable: bool) Allocator.Error!Sym {
    return ctx.s.syms.addLocal(.{
        .kind = .local,
        .name = n,
        .owner = ctx.localOwner(),
        .file = ctx.file,
        .flags = .{ .mutable = mutable },
        .decl = .{ .ident = id },
        .detail = 0,
    }, .{ .ty = ty });
}

fn localDecl(ctx: *Ctx, d: *const ast.Decl) Allocator.Error!void {
    const s = ctx.s;
    switch (d.*) {
        .Property => |p| {
            const saved_node = ctx.enterNode(p.id);
            defer ctx.leaveNode(saved_node);
            var declared: TypeId = .none;
            if (p.ty) |tr| declared = try headers.resolveTypeRef(s, typeCtx(ctx), tr);
            var t = declared;
            if (p.init) |i| {
                const it = try expr(ctx, i, declared);
                if (declared == .none) t = try widenForDecl(s, it) else try infer.noteExpected(s, it, declared);
            }
            if (p.delegate) |del| {
                const dt = try delegateExpr(ctx, del, declared, p.mutable, try calls.thisRefType(ctx));
                const sym = try newLocal(ctx, try ctx.intern(p.name.name), p.name, t, p.mutable);
                // The property, so a nested body finds its delegate's calls.
                s.syms.getMut(sym).decl = .{ .local_prop = p };
                try ctx.addRef(.{ .file = ctx.file, .anchor = p.name.span, .kind = .decl, .target = sym });
                const vt = try calls.delegateAccess(ctx, del, dt, sym, p.mutable, try calls.thisRefType(ctx));
                if (t == .none) s.syms.localInfo(sym).ty = vt else try checkDelegateValue(ctx, del, vt, t);
                try ctx.declareLocal(s.syms.name(sym), sym);
                return;
            }
            if (t == .none) t = s.types.errType();
            const sym = try newLocal(ctx, try ctx.intern(p.name.name), p.name, t, p.mutable);
            s.syms.getMut(sym).decl = .{ .local_prop = p };
            try ctx.addRef(.{ .file = ctx.file, .anchor = p.name.span, .kind = .decl, .target = sym });
            try ctx.declareLocal(s.syms.name(sym), sym);
            if (!p.mutable) if (p.init) |i| {
                // Only values that cannot change after the declaration.
                var implied: std.ArrayList(Narrow) = .empty;
                for (try nonNullFacts(ctx, i)) |f| {
                    if (s.syms.kind(f.sym) == .local and s.syms.flags(f.sym).mutable) continue;
                    try implied.append(s.arena, f);
                }
                if (implied.items.len != 0) try s.nonnull_implies.put(s.arena, sym, implied.items);
            };
        },
        .Function => |*f| {
            const saved_node = ctx.enterNode(f.id);
            defer ctx.leaveNode(saved_node);
            _ = try localFunction(ctx, f);
        },
        .Class, .Object => try localClass(ctx, d),
        .TypeAlias => {},
    }
}

/// A local function is declared in the enclosing scope (before its body
/// resolves, so it can recurse) and resolved against it.
pub fn localFunction(ctx: *Ctx, f: *const ast.Function) Allocator.Error!Sym {
    const s = ctx.s;
    const sym = try declareLocalFunction(ctx, f);
    try ctx.declareLocal(s.syms.name(sym), sym);
    try ctx.addRef(.{ .file = ctx.file, .node = f.id, .anchor = f.name.span, .kind = .decl, .target = sym });
    try resolveLocalFunctionBody(ctx, sym);
    return sym;
}

pub fn declareLocalFunction(ctx: *Ctx, f: *const ast.Function) Allocator.Error!Sym {
    const s = ctx.s;
    const sym = try s.syms.addFunction(.{
        .kind = .function,
        .name = try ctx.intern(f.name.name),
        .owner = ctx.localOwner(),
        .file = ctx.file,
        .flags = .{ .inline_ = f.is_inline, .suspend_ = f.is_suspend, .operator = f.is_operator, .infix = f.is_infix, .tailrec = f.is_tailrec, .has_body = f.body != null },
        .decl = .{ .function = f },
        .detail = 0,
    }, .{});
    const tps = try localTypeParams(ctx, f.type_params, sym);
    const params = try localParams(ctx, f.params, sym);
    const cps = try localContextParams(ctx, f.context_params, sym);
    const info = s.syms.functionInfo(sym);
    info.type_params = tps;
    info.params = params;
    info.context_params = cps;
    return sym;
}

/// A local function's `context(a: A)` parameters: its callers pass them,
/// and its body takes context arguments from them first.
fn localContextParams(ctx: *Ctx, cps: []const ast.ContextParam, owner: Sym) Allocator.Error![]const Sym {
    const s = ctx.s;
    if (cps.len == 0) return &.{};
    const out = try s.arena.alloc(Sym, cps.len);
    for (cps, out, 0..) |*cp, *o, i| {
        o.* = try s.syms.addParam(.{
            .kind = .value_param,
            .name = try ctx.intern(cp.name.name),
            .owner = owner,
            .file = ctx.file,
            .flags = .{},
            .decl = .{ .context_param = cp },
            .detail = 0,
        }, .{ .index = @intCast(i) });
    }
    return out;
}

pub fn resolveLocalFunctionBody(ctx: *Ctx, sym: Sym) Allocator.Error!void {
    const s = ctx.s;
    const f = s.syms.get(sym).decl.function;
    s.syms.functionInfo(sym).body_done = true;
    const sc = try pushFunctionScope(ctx, sym);
    defer ctx.pop(sc);
    try resolveParamDefaults(ctx, s.syms.functionInfo(sym).params);
    if (f.body) |*b| {
        switch (b.*) {
            .Block => |*blk| _ = try block(ctx, blk, .none),
            .Expr => |*e| {
                const ret = s.syms.functionInfo(sym).ret;
                const t = try expr(ctx, e, ret);
                if (ret == .none) s.syms.functionInfo(sym).ret = try widenForDecl(s, t) else try infer.noteExpected(s, t, ret);
            },
        }
    }
}

fn localTypeParams(ctx: *Ctx, tps: []const ast.TypeParam, owner: Sym) Allocator.Error![]const Sym {
    const s = ctx.s;
    if (tps.len == 0) return &.{};
    const out = try s.arena.alloc(Sym, tps.len);
    for (tps, out, 0..) |*tp, *o, i| {
        o.* = try s.syms.addTypeParam(.{
            .kind = .type_param,
            .name = try ctx.intern(tp.name.name),
            .owner = owner,
            .file = ctx.file,
            .flags = .{ .reified = tp.is_reified },
            .decl = .{ .type_param = tp },
            .detail = 0,
        }, .{ .index = @intCast(i) });
    }
    return out;
}

fn localParams(ctx: *Ctx, ps: []const ast.Param, owner: Sym) Allocator.Error![]const Sym {
    const s = ctx.s;
    if (ps.len == 0) return &.{};
    const out = try s.arena.alloc(Sym, ps.len);
    for (ps, out, 0..) |*p, *o, i| {
        o.* = try s.syms.addParam(.{
            .kind = .value_param,
            .name = try ctx.intern(p.name.name),
            .owner = owner,
            .file = ctx.file,
            .flags = .{ .vararg = p.is_vararg, .has_default = p.default != null },
            .decl = .{ .param = p },
            .detail = 0,
        }, .{ .index = @intCast(i) });
    }
    return out;
}

/// A class declared in a body. Its members resolve with the enclosing
/// scope visible, so they can read the function's locals.
fn localClass(ctx: *Ctx, d: *const ast.Decl) Allocator.Error!void {
    const s = ctx.s;
    const owner = ctx.localOwner();
    const cls = try sema_mod.decls.collectLocalClass(s, ctx.file, d, owner);
    try ctx.declareLocal(s.syms.name(cls), cls);
    const node: ast.NodeId, const sp: Span = switch (d.*) {
        .Class => |c| .{ c.id, c.name.span },
        .Object => |o| .{ o.id, o.name.span },
        else => .{ .none, .{ .file = span.FileId.from(0), .start = 0, .end = 0 } },
    };
    try ctx.addRef(.{ .file = ctx.file, .node = node, .anchor = sp, .kind = .decl, .target = cls });
    const gop = try s.local_classifiers.getOrPut(s.arena, owner);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try s.syms.indexMember(gop.value_ptr, s.syms.name(cls), cls);
    try resolveLocalClassBody(ctx, cls);
}

pub fn resolveLocalClassBody(ctx: *Ctx, cls: Sym) Allocator.Error!void {
    const saved = ctx.scope;
    defer ctx.scope = saved;
    // The class scope opens on top of the enclosing body's scope.
    try pushClassScope(ctx, cls, false);
    const inner = ctx.scope;
    ctx.scope = saved;
    try resolveClassWithin(ctx, cls, inner);
}

/// `resolveClass` for a class whose scope is `class_scope`, already open.
fn resolveClassWithin(ctx: *Ctx, cls: Sym, class_scope: *Scope) Allocator.Error!void {
    const s = ctx.s;
    try s.local_class_scopes.put(s.arena, cls, class_scope);
    ctx.scope = class_scope;
    const ctor_scope = try classInit(ctx, cls);
    var member_list: std.ArrayList(Sym) = .empty;
    var it = s.syms.classInfo(cls).members.iterator();
    while (it.next()) |e| try member_list.appendSlice(s.arena, e.value_ptr.items);
    std.mem.sort(Sym, member_list.items, {}, struct {
        fn lt(_: void, a: Sym, b: Sym) bool {
            return a.int() < b.int();
        }
    }.lt);
    for (member_list.items) |m| {
        if (s.syms.owner(m) != cls or s.syms.kind(m) != .property) continue;
        const inner_saved = ctx.scope;
        try resolvePropertyIn(ctx, m);
        ctx.scope = inner_saved;
    }
    if (ctor_scope) |sc| ctx.pop(sc);
    for (member_list.items) |m| {
        if (s.syms.owner(m) != cls) continue;
        const inner_saved = ctx.scope;
        switch (s.syms.kind(m)) {
            .function => try resolveFunctionInClass(ctx, m),
            .constructor => if (s.syms.get(m).decl == .secondary_ctor) try secondaryCtor(ctx, cls, m),
            .class => {
                const nested_scope = try nestedScope(ctx, m);
                try resolveClassWithin(ctx, m, nested_scope);
            },
            else => {},
        }
        ctx.scope = inner_saved;
    }
}

/// The scope a class nested in the open class scope resolves in. A class
/// that is not `inner` sees the outer class's statics and companions but
/// not its `this`.
fn nestedScope(ctx: *Ctx, cls: Sym) Allocator.Error!*Scope {
    const saved = ctx.scope;
    defer ctx.scope = saved;
    if (!ctx.s.syms.flags(cls).inner and saved.kind == .class and !saved.static_only) {
        ctx.scope = saved.parent.?;
        try pushClassScope(ctx, saved.owner, true);
    }
    try pushClassScope(ctx, cls, false);
    return ctx.scope;
}

pub fn typeCtx(ctx: *const Ctx) headers.TypeCtx {
    // The innermost declaration whose type parameters are in scope.
    var sc: ?*Scope = ctx.scope;
    while (sc) |c| : (sc = c.parent) {
        if (c.owner != .none) return .{ .decl = c.owner, .file = ctx.file };
    }
    const fc = ctx.s.files.items[ctx.file];
    return .{ .decl = fc.package, .file = ctx.file };
}

/// A local classifier in scope, for a type written in a body.
pub fn resolveTypeInBody(ctx: *Ctx, tr: *const ast.TypeRef) Allocator.Error!TypeId {
    const s = ctx.s;
    if (tr.function == null and tr.x().qualified_path == null) {
        if (s.names.lookup(tr.name.name)) |n| {
            if (lookupLocal(ctx, n)) |loc| {
                if (s.syms.kind(loc) == .class) {
                    return s.types.classAttrs(loc, try typeArgsIn(ctx, tr.type_args), tr.nullable, .{});
                }
            }
        }
    }
    return headers.resolveTypeRef(s, typeCtx(ctx), tr);
}

fn typeArgsIn(ctx: *Ctx, targs: []const ast.TypeArg) Allocator.Error![]const types.Arg {
    const out = try ctx.arena().alloc(types.Arg, targs.len);
    for (targs, out) |*ta, *o| {
        if (ta.is_star) {
            o.* = .{ .variance = .star, .ty = .none };
            continue;
        }
        o.* = .{ .variance = switch (ta.variance) {
            .Invariant => .inv,
            .Out => .out,
            .In => .in,
        }, .ty = try resolveTypeInBody(ctx, &ta.ty) };
    }
    return out;
}

fn assignment(ctx: *Ctx, a: *const ast.AssignStmt) Allocator.Error!void {
    const s = ctx.s;
    if (a.op == .Assign) {
        switch (a.target) {
            .Index => |ix| {
                _ = try calls.indexSet(ctx, &a.target, ix.receiver, ix.args, &a.value);
                return;
            },
            else => {},
        }
        const target_t = try assignTarget(ctx, &a.target);
        const vt = try expr(ctx, &a.value, target_t);
        try infer.noteExpected(s, vt, target_t);
        try narrowAfterAssign(ctx, &a.target, vt);
        return;
    }
    try calls.compoundAssign(ctx, a);
}

/// What a `try`'s body and catches assign: a catch may start, and the
/// finally runs, after any of it.
pub const TryLog = struct {
    assigned: std.ArrayList(Narrow) = .empty,
    parent: ?*TryLog = null,
};

/// `try { } catch { } finally { }`. The body can throw before or after any
/// of its assignments, so a catch sees each variable the body assigns as
/// the common supertype of its type before the `try` and every type
/// assigned to it; the finally sees the same over the catches too (`x`
/// assigned `42` after a `throw` is not an `Int` in the finally). Past the
/// `try`, the smart casts are those the body and the catches that complete
/// agree on, then what the finally assigns.
fn tryExpr(ctx: *Ctx, t: *const ast.TryExpr, expected: TypeId) Allocator.Error!TypeId {
    const s = ctx.s;
    var branch_types: std.ArrayList(TypeId) = .empty;
    var outs: std.ArrayList(BranchOut) = .empty;
    var log: TryLog = .{ .parent = ctx.try_log };
    // The body and catch results stay open for `join` when nothing is
    // expected, as an `if`'s branches do.
    const saved_branch = ctx.in_arg;
    if (try openExpected(s, expected) and ctx.in_arg == .none) ctx.in_arg = .branch;
    ctx.try_log = &log;
    {
        const sc = try ctx.push(.block, .none);
        const bt = try block(ctx, &t.body, expected);
        try branch_types.append(s.arena, bt);
        try outs.append(s.arena, if (isNothingType(s, try s.types.makeNotNull(bt))) null else try ctx.arena().dupe(Narrow, sc.narrow.items));
        ctx.pop(sc);
    }
    const entry = try thrownState(ctx, log.assigned.items);
    for (t.catches) |*c| {
        const sc = try ctx.push(.block, .none);
        try applyFacts(ctx, entry);
        const ct = try resolveTypeInBody(ctx, &c.ty);
        const sym = try newLocal(ctx, try ctx.intern(c.binding.name), c.binding, ct, false);
        try ctx.declareLocal(s.syms.name(sym), sym);
        {
            const saved_node = ctx.enterNode(c.id);
            defer ctx.leaveNode(saved_node);
            try typeTestRef(ctx, .catch_, ct, c.ty.span, sym);
        }
        const ctt = try blockIn(ctx, c.body.stmts, expected);
        try branch_types.append(s.arena, ctt);
        const completes = !isNothingType(s, try s.types.makeNotNull(ctt)) and !(c.body.stmts.len != 0 and switch (c.body.stmts[c.body.stmts.len - 1]) {
            .Expr => |*last| jumps(last),
            else => false,
        });
        try outs.append(s.arena, if (completes) try ctx.arena().dupe(Narrow, sc.narrow.items) else null);
        ctx.pop(sc);
    }
    ctx.try_log = log.parent;
    ctx.in_arg = saved_branch;
    const r = try join(ctx, branch_types.items, expected);
    // Both taken over the state before the `try`: the finally sees none of
    // what the body and catches leave when they complete.
    const finally_entry = try thrownState(ctx, log.assigned.items);
    const merged = try mergeBranches(ctx, outs.items, null);
    var own: []const Narrow = &.{};
    if (t.finally) |*f| {
        const saved_arg = ctx.in_arg;
        ctx.in_arg = .none;
        defer ctx.in_arg = saved_arg;
        const sc = try ctx.push(.block, .none);
        try applyFacts(ctx, finally_entry);
        const facts_end = sc.narrow.items.len;
        _ = try block(ctx, f, .none);
        // Only what the finally itself establishes holds after it.
        own = try ctx.arena().dupe(Narrow, sc.narrow.items[facts_end..]);
        ctx.pop(sc);
    }
    try applyFacts(ctx, merged);
    try applyFacts(ctx, own);
    return r;
}

/// The smart casts where a `try` may have thrown: each variable in
/// `assigned` as the common supertype of its type now and every type
/// assigned to it.
fn thrownState(ctx: *Ctx, assigned: []const Narrow) Allocator.Error![]const Narrow {
    const s = ctx.s;
    var out: std.ArrayList(Narrow) = .empty;
    var seen: std.AutoHashMapUnmanaged(Sym, void) = .empty;
    for (assigned) |a| {
        if ((try seen.getOrPut(s.arena, a.sym)).found_existing) continue;
        const before = try narrowedType(ctx, a.sym, try subjectBaseType(ctx, a.sym));
        var tys: std.ArrayList(TypeId) = .empty;
        try tys.append(s.arena, before);
        for (assigned) |b| if (b.sym == a.sym) try tys.append(s.arena, b.ty);
        const t = try subtyping.commonSupertype(s, tys.items);
        if (t == before or s.types.isErr(t)) continue;
        try out.append(s.arena, .{ .sym = a.sym, .ty = t });
    }
    return out.items;
}

/// After `x = v`, a local is what `v` is, when that fits its declared
/// type; any earlier smart cast on it ends.
fn narrowAfterAssign(ctx: *Ctx, target: *const Expr, vt_in: TypeId) Allocator.Error!void {
    const s = ctx.s;
    if (target.* != .Path or target.Path.segments.len != 1) return;
    const n = s.names.lookup(target.Path.segments[0].name) orelse return;
    const loc = lookupLocalValue(ctx, n) orelse return;
    // A `var`, or a `val` declared without an initializer and assigned
    // once later.
    if (s.syms.kind(loc) != .local) return;
    const declared = s.syms.localInfo(loc).ty;
    var t = declared;
    if (vt_in != .none and !s.types.isErr(vt_in)) {
        const vt = try widenForDecl(s, try infer.zonk(s, vt_in));
        if (!infer.hasOpenVar(s, vt) and !isNothingType(s, try s.types.makeNotNull(vt)) and try subtyping.isSubtype(s, vt, declared)) t = vt;
    }
    try ctx.scope.narrow.append(s.arena, .{ .sym = loc, .ty = t });
    var log = ctx.try_log;
    while (log) |l| : (log = l.parent) try l.assigned.append(s.arena, .{ .sym = loc, .ty = t });
}

/// Resolves an assignment's left side as a write and returns its type.
pub fn assignTarget(ctx: *Ctx, target: *const Expr) Allocator.Error!TypeId {
    return switch (target.*) {
        .Path => |p| if (p.segments.len == 1) nameAccess(ctx, p.segments[0], .write) else qualifiedAccess(ctx, target, .write),
        .Member => |m| memberAccess(ctx, target, m.receiver, m.name, m.safe, .write),
        else => expr(ctx, target, .none),
    };
}

// ----------------------------------------------------------- expressions --

pub fn expr(ctx: *Ctx, e: *const Expr, expected: TypeId) Allocator.Error!TypeId {
    const id = e.id();
    const saved = ctx.enterNode(id);
    defer ctx.leaveNode(saved);
    // Only the forms whose type is a call's keep an argument's partial
    // inference; every other form's parts complete on their own.
    const saved_arg = ctx.in_arg;
    defer ctx.in_arg = saved_arg;
    if (ctx.in_arg != .none and !passesOpen(e)) ctx.in_arg = .none;
    const refs_before = ctx.refCount();
    const t = try exprInner(ctx, e, expected);
    try ctx.addType(id, e.span(), t, needsRecord(e));
    // `require(x is T)`: past a call whose contract says what its normal
    // return implies, that holds.
    if (e.* == .Call) try applyFacts(ctx, (try contractFacts(ctx, e, refs_before, .returns)).when_true);
    return t;
}

/// Whether lowering reads a record for an expression of this kind: a
/// name, member, call, index, callable reference, `for`, `this`, a type
/// test, a lambda, an object expression, a `return`, or an operator that
/// is a convention call. `&&`, `||`, `?:`, `===`, `!!`, a comparison
/// with `null` and a negated literal are not.
pub fn needsRecord(e: *const Expr) bool {
    // Arithmetic over integer literals is folded, not called.
    if (intConstValue(e) != null) return false;
    return switch (e.*) {
        .Path, .Member, .Call, .Index, .For, .PropertyRef, .MemberRef => true,
        .This, .IsCheck, .As, .Lambda, .AnonFun, .ObjectExpr, .Return => true,
        .Binary => |b| switch (b.op) {
            .IdentEq, .IdentNeq, .And, .Or, .Elvis, .Assign => false,
            .Eq, .Neq => b.lhs.* != .NullLit and b.rhs.* != .NullLit,
            else => true,
        },
        .Unary => |u| switch (u.op) {
            .Neg, .Pos => u.expr.* != .IntLit and u.expr.* != .FloatLit,
            else => true,
        },
        .Postfix => |p| p.op != .NotNull,
        else => false,
    };
}

/// Whether nothing usable is expected: no type, or one still an open
/// variable (a lambda's result being inferred), so branches join.
/// What a branch of an `if` or `when` is expected to be: nothing, where the
/// whole is expected to be only `Any` or `Any?`, so a generic call in one
/// branch stays open for the join with the others.
fn branchExpected(s: *Sema, expected: TypeId) Allocator.Error!TypeId {
    if (expected == .none) return expected;
    const z = try infer.zonk(s, expected);
    if (s.types.classSym(try s.types.makeNotNull(z)) == s.builtins.any) return .none;
    return expected;
}

fn openExpected(s: *Sema, expected: TypeId) Allocator.Error!bool {
    const u = try infer.usableExpected(s, expected);
    if (u == .none) return true;
    // `Any` and `Any?` say nothing the branches could share.
    return s.types.classSym(try s.types.makeNotNull(u)) == s.builtins.any;
}

/// Whether an argument's partial inference reaches into `e`: a call, and
/// the forms whose type is a call's inside it (branches, blocks, `!!`,
/// labels, lambdas) or a literal still to be typed.
fn passesOpen(e: *const Expr) bool {
    if (intConstValue(e) != null) return true;
    return switch (e.*) {
        .Call, .Index, .If, .When, .Try, .Labeled, .Block, .Lambda, .AnonFun, .IntLit, .Return, .PropertyRef, .MemberRef, .Spread => true,
        .Binary => |b| b.op == .Elvis,
        .Postfix => |p| p.op == .NotNull,
        .Unary => |u| (u.op == .Neg or u.op == .Pos) and u.expr.* == .IntLit,
        else => false,
    };
}

/// `e` resolved and completed on its own: an enclosing argument's
/// inference does not reach into it.
pub fn independent(ctx: *Ctx, e: *const Expr, expected: TypeId) Allocator.Error!TypeId {
    const saved = ctx.in_arg;
    ctx.in_arg = .none;
    defer ctx.in_arg = saved;
    return expr(ctx, e, expected);
}

/// An explicit receiver: the call on it needs its type first, so a
/// variable a lambda's body is inferring is fixed there.
pub fn receiverExpr(ctx: *Ctx, e: *const Expr) Allocator.Error!TypeId {
    return infer.fixReceiver(ctx.s, try independent(ctx, e, .none));
}

fn exprInner(ctx: *Ctx, e: *const Expr, expected: TypeId) Allocator.Error!TypeId {
    const s = ctx.s;
    switch (e.*) {
        .IntLit => |lit| return intLiteral(ctx, lit.value, lit.kind, expected),
        .FloatLit => |lit| return if (lit.kind == .Float) s.simpleType(classOrNone(s, "kotlin.Float")) else s.t.double,
        .BoolLit => return s.t.boolean,
        .NullLit => return s.t.nothing_q,
        .CharLit => return s.t.char,
        .StringTemplate => |st| {
            for (st.parts) |part| switch (part) {
                .Text => {},
                .ShortInterp => |id| {
                    // `$name` is a node of its own.
                    const saved = ctx.enterNode(id.id);
                    defer ctx.leaveNode(saved);
                    if (std.mem.eql(u8, id.name, "this")) {
                        _ = try thisExpr(ctx, null, id.span);
                    } else {
                        const t = try nameAccess(ctx, id, .read);
                        try ctx.addType(id.id, id.span, t, true);
                    }
                },
                .Interp => |ie| _ = try expr(ctx, ie, .none),
            };
            return s.t.string;
        },
        .Path => |p| {
            if (p.segments.len == 1) return nameAccess(ctx, p.segments[0], .read);
            return qualifiedAccess(ctx, e, .read);
        },
        .Member => |m| return memberAccess(ctx, e, m.receiver, m.name, m.safe, .read),
        .Call => return calls.call(ctx, e, expected),
        .Index => |ix| return calls.indexGet(ctx, e, ix.receiver, ix.args),
        .Binary => |b| return binary(ctx, e, b.op, b.lhs, b.rhs, expected),
        .Unary => |u| {
            if (u.expr.* != .IntLit) if (intConstValue(e)) |v| return constArithmetic(ctx, &.{u.expr}, v, expected);
            return calls.unary(ctx, e, u.op, u.expr, expected);
        },
        .Postfix => |p| {
            if (p.op == .NotNull) {
                // `e!!` is `checkNotNull<K>(e: K?): K`: an expected `T` makes `e` expect `T?`.
                const inner_expected = if (expected != .none) try s.types.makeNullable(expected) else .none;
                const t = try fixAtNotNull(s, try expr(ctx, p.expr, inner_expected));
                try narrowAfterNotNull(ctx, p.expr);
                return s.types.definitelyNotNull(t);
            }
            return calls.incDec(ctx, e, p.expr, p.op == .Inc, true);
        },
        .If => |i| return ifExpr(ctx, i.cond, i.then_branch, i.else_branch, expected),
        .While => |w| {
            const facts = try condition(ctx, w.cond);
            const sc = try ctx.push(.block, .none);
            try applyFacts(ctx, facts.when_true);
            _ = try expr(ctx, w.body, .none);
            ctx.pop(sc);
            return s.t.unit;
        },
        .DoWhile => |w| {
            const sc = try ctx.push(.block, .none);
            if (w.body) |b| {
                switch (b.*) {
                    // Locals of a do-while body are visible in its condition.
                    .Block => |*blk| _ = try blockIn(ctx, blk.stmts, .none),
                    else => _ = try expr(ctx, b, .none),
                }
            }
            _ = try condition(ctx, w.cond);
            ctx.pop(sc);
            return s.t.unit;
        },
        .For => |f| return forLoop(ctx, f),
        .Return => |r| {
            if (returnTarget(ctx, r.label)) |sc| {
                if (sc.owner != .none) try ctx.addRef(.{ .file = ctx.file, .anchor = r.span, .kind = .return_, .target = sc.owner });
            }
            if (r.value) |v| {
                const target = returnTarget(ctx, r.label);
                const t = try expr(ctx, v, if (target) |sc| sc.ret else .none);
                if (target) |sc| try infer.noteExpected(s, t, sc.ret);
                if (target) |sc| if (sc.lambda_returns) |lr| try lr.append(s.arena, t);
            } else if (returnTarget(ctx, r.label)) |sc| {
                if (sc.lambda_returns) |lr| try lr.append(s.arena, s.t.unit);
                sc.unit_return = true;
            }
            return s.t.nothing;
        },
        .Break, .Continue => return s.t.nothing,
        .Labeled => |l| {
            // `lit@{ ... }` and `lit@fun() { ... }` name the literal.
            if (l.expr.* == .Lambda or l.expr.* == .AnonFun) ctx.lambda_label = try ctx.intern(l.label.name);
            return expr(ctx, l.expr, expected);
        },
        .Block => |*b| return block(ctx, b, expected),
        .Throw => |t| {
            _ = try expr(ctx, t.value, s.t.throwable);
            return s.t.nothing;
        },
        .Try => |t| return tryExpr(ctx, t, expected),
        .Lambda => |l| return calls.lambda(ctx, l, expected),
        .AnonFun => |f| return calls.anonymousFunction(ctx, f, expected),
        .This => |t| return thisExpr(ctx, t.qualifier, t.span),
        .Super => |sp| {
            try ctx.reportFacts(.unsupported, sp.span, .{ .message = "`super` can only be used to access a member of a supertype" }, "`super` outside a member access", .{});
            return s.types.errType();
        },
        .PropertyRef => |r| return calls.callableRef(ctx, e, null, r.name, expected),
        .MemberRef => |r| return calls.callableRef(ctx, e, r.receiver, r.name, expected),
        .When => |w| return whenExpr(ctx, w, expected),
        .IsCheck => |c| {
            _ = try expr(ctx, c.expr, .none);
            const t = try resolveTypeInBody(ctx, &c.ty);
            try typeTestRef(ctx, if (c.negated) .not_is else .is_, t, c.ty.span, .none);
            return s.t.boolean;
        },
        .As => |a| {
            const ot = try expr(ctx, a.expr, .none);
            // `h as Box` on a `Holder<T>` is a `Box<T>`: a generic class
            // written bare takes its arguments from the operand.
            var t = try resolveTypeInBody(ctx, &a.ty);
            if (!s.types.isErr(ot) and !s.types.isErr(t)) t = try refineBareType(ctx, try s.types.makeNotNull(ot), t);
            try typeTestRef(ctx, if (a.safe) .as_safe else .as_, t, a.ty.span, .none);
            // Once `x as T` has run, `x` is a `T` for the rest of the block.
            if (!a.safe) try narrowAfterCast(ctx, a.expr, t);
            return if (a.safe) s.types.makeNullable(t) else t;
        },
        .Spread => |sp| return expr(ctx, sp.expr, .none),
        .ObjectExpr => |o| return objectExpr(ctx, o),
    }
}

fn classOrNone(s: *Sema, fqn: []const u8) Sym {
    return s.classByFqn(fqn);
}

/// `-n` and `+n` for an integer literal `n`: the literal node takes the
/// type of the signed value.
pub fn signedLiteral(ctx: *Ctx, lit: *const Expr, negate: bool, expected: TypeId) Allocator.Error!TypeId {
    const saved = ctx.enterNode(lit.id());
    defer ctx.leaveNode(saved);
    const v = lit.IntLit.value;
    const t = try intLiteral(ctx, if (negate) -%v else v, lit.IntLit.kind, expected);
    try ctx.addType(lit.id(), lit.span(), t, false);
    return t;
}

fn intLiteral(ctx: *Ctx, value: i64, kind: ast.IntLitKind, expected: TypeId) Allocator.Error!TypeId {
    const s = ctx.s;
    switch (kind) {
        .Long => return s.t.long,
        .UInt, .ULong => {
            if (kind == .ULong) return s.t.ulong;
            const exp_nn = if (expected != .none) try s.types.makeNotNull(expected) else .none;
            if (exp_nn != .none and (exp_nn == s.t.ulong or exp_nn == s.t.ushort or exp_nn == s.t.ubyte)) return exp_nn;
            // An unsigned literal takes the unsigned type an enclosing call
            // expects (`ubyteArrayOf(1u, 2u)`), else `UInt`.
            if (ctx.in_arg != .none) {
                const uv: u64 = @bitCast(value);
                return s.types.intern(.{ .int_lit = .{ .uint = uv <= std.math.maxInt(u32), .ulong = true, .ushort = uv <= std.math.maxInt(u16), .ubyte = uv <= std.math.maxInt(u8) } });
            }
            return s.t.uint;
        },
        .Int => {},
    }
    // An integer literal takes the integral type expected of it.
    if (expected != .none) {
        const exp_nn = try s.types.makeNotNull(try infer.zonk(s, expected));
        const fits_int = value >= std.math.minInt(i32) and value <= std.math.maxInt(i32);
        if (exp_nn == s.t.long) return s.t.long;
        if (exp_nn == s.t.int and fits_int) return s.t.int;
        if (exp_nn == s.t.short and value >= std.math.minInt(i16) and value <= std.math.maxInt(i16)) return s.t.short;
        if (exp_nn == s.t.byte and value >= std.math.minInt(i8) and value <= std.math.maxInt(i8)) return s.t.byte;
        // Against a variable it stays a literal of every type it fits, so
        // a `Byte` flowing in beside it makes both a `Byte`.
        if (s.types.get(exp_nn) == .variable or s.types.get(exp_nn) == .param) return signedLit(s, value);
    }
    if (value >= std.math.minInt(i32) and value <= std.math.maxInt(i32)) {
        if (ctx.in_arg != .none) return signedLit(s, value);
        return s.t.int;
    }
    return s.t.long;
}

/// Arithmetic over integer literals, of value `v`: its operands are
/// visited as the operands they are, and it is the literal of `v`.
fn constArithmetic(ctx: *Ctx, operands: []const *const Expr, v: i64, expected: TypeId) Allocator.Error!TypeId {
    const saved = ctx.in_arg;
    ctx.in_arg = .none;
    for (operands) |o| _ = expr(ctx, o, .none) catch |err| {
        ctx.in_arg = saved;
        return err;
    };
    ctx.in_arg = saved;
    const s = ctx.s;
    // An `Int` while every literal in it is one, wrapping as `Int`
    // arithmetic does (`2147483647 + 1` is `-2147483648`); a `Short` or a
    // `Byte` only where its value fits.
    const lit: types.IntLit = .{
        .int = operandsFitInt(operands),
        .long = true,
        .short = v >= std.math.minInt(i16) and v <= std.math.maxInt(i16),
        .byte = v >= std.math.minInt(i8) and v <= std.math.maxInt(i8),
    };
    if (expected != .none) {
        const exp_nn = try s.types.makeNotNull(try infer.zonk(s, expected));
        if (exp_nn == s.t.long) return s.t.long;
        if (exp_nn == s.t.int and lit.int) return s.t.int;
        if (exp_nn == s.t.short and lit.short) return s.t.short;
        if (exp_nn == s.t.byte and lit.byte) return s.t.byte;
        if (s.types.get(exp_nn) == .variable or s.types.get(exp_nn) == .param) return s.types.intern(.{ .int_lit = lit });
    }
    if (ctx.in_arg != .none) return s.types.intern(.{ .int_lit = lit });
    return if (lit.int) s.t.int else s.t.long;
}

fn operandsFitInt(operands: []const *const Expr) bool {
    for (operands) |o| if (!literalsFitInt(o)) return false;
    return true;
}

/// Whether every integer literal in the constant expression `e` is an `Int`.
fn literalsFitInt(e: *const Expr) bool {
    return switch (e.*) {
        .IntLit => |l| l.value >= std.math.minInt(i32) and l.value <= std.math.maxInt(i32),
        .Unary => |u| literalsFitInt(u.expr),
        .Binary => |x| literalsFitInt(x.lhs) and literalsFitInt(x.rhs),
        else => false,
    };
}

/// The value of an arithmetic expression over integer literals, which
/// kotlinc types as an integer literal itself: `+`, `-`, `*`, `/` and `%`
/// over `Int` literals and their negations. Null for any other expression
/// and for a division by zero.
pub fn intConstValue(e: *const Expr) ?i64 {
    switch (e.*) {
        .IntLit => |l| return if (l.kind == .Int) l.value else null,
        .Unary => |u| {
            const v = intConstValue(u.expr) orelse return null;
            return switch (u.op) {
                .Neg => -%v,
                .Pos => v,
                else => null,
            };
        },
        .Binary => |x| {
            switch (x.op) {
                .Add, .Sub, .Mul, .Div, .Rem => {},
                else => return null,
            }
            const a = intConstValue(x.lhs) orelse return null;
            const b = intConstValue(x.rhs) orelse return null;
            return switch (x.op) {
                .Add => a +% b,
                .Sub => a -% b,
                .Mul => a *% b,
                .Div => if (b == 0) null else if (b == -1) -%a else @divTrunc(a, b),
                .Rem => if (b == 0) null else if (b == -1) 0 else @rem(a, b),
                else => unreachable,
            };
        },
        else => return null,
    }
}

/// `intConstValue` computed in a `bits`-wide signed type, wrapping at every
/// step as that type's arithmetic does.
pub fn intConstValueIn(e: *const Expr, bits: u8) ?i64 {
    const v: i64 = switch (e.*) {
        .IntLit => |l| if (l.kind == .Int) l.value else return null,
        .Unary => |u| blk: {
            const x = intConstValueIn(u.expr, bits) orelse return null;
            break :blk switch (u.op) {
                .Neg => -%x,
                .Pos => x,
                else => return null,
            };
        },
        .Binary => |x| blk: {
            switch (x.op) {
                .Add, .Sub, .Mul, .Div, .Rem => {},
                else => return null,
            }
            const a = intConstValueIn(x.lhs, bits) orelse return null;
            const b = intConstValueIn(x.rhs, bits) orelse return null;
            break :blk switch (x.op) {
                .Add => a +% b,
                .Sub => a -% b,
                .Mul => a *% b,
                .Div => if (b == 0) return null else if (b == -1) -%a else @divTrunc(a, b),
                .Rem => if (b == 0) return null else if (b == -1) 0 else @rem(a, b),
                else => unreachable,
            };
        },
        else => return null,
    };
    return switch (bits) {
        8 => @as(i8, @truncate(v)),
        16 => @as(i16, @truncate(v)),
        32 => @as(i32, @truncate(v)),
        else => v,
    };
}

fn signedLit(s: *Sema, value: i64) Allocator.Error!TypeId {
    return s.types.intern(.{ .int_lit = .{
        .int = value >= std.math.minInt(i32) and value <= std.math.maxInt(i32),
        .long = true,
        .short = value >= std.math.minInt(i16) and value <= std.math.maxInt(i16),
        .byte = value >= std.math.minInt(i8) and value <= std.math.maxInt(i8),
    } });
}

pub fn join(ctx: *Ctx, list_in: []const TypeId, expected: TypeId) Allocator.Error!TypeId {
    const s = ctx.s;
    var list = list_in;
    // A branch whose type still has open variables (`emptyList()`) takes
    // them from the other branches: each other branch flows into it. A
    // single type has none to take them from, and keeps them open for
    // what uses it (a lambda's `X("OK")` passed on to `X<String?>`).
    var open = false;
    if (list.len > 1) for (list) |t| if (infer.hasOpenVar(s, try infer.zonk(s, t))) {
        open = true;
    };
    if (open) {
        var sys = infer.System.init(s);
        for (list) |t| try sys.adopt(try infer.zonk(s, t));
        // The open branch every other one fits below, when there is one.
        var top: ?usize = null;
        for (list, 0..) |ti, i| {
            if (!infer.hasOpenVar(s, try infer.zonk(s, ti))) continue;
            var all_below = true;
            for (list, 0..) |tj, j| {
                if (i == j or isNothingType(s, tj)) continue;
                var trial = try sys.clone();
                if (!try trial.constrain(tj, ti)) {
                    all_below = false;
                    // `FiniteAnimationSpec<IntOffset>` and `snap()`'s
                    // `SnapSpec<T>`: the open branch fits below the other,
                    // whose arguments its supertype then shares.
                    var below = try sys.clone();
                    if (try below.constrain(ti, tj)) {
                        _ = try sys.constrain(ti, tj);
                        continue;
                    }
                }
                _ = try sys.constrain(tj, ti);
            }
            if (all_below and top == null) top = i;
        }
        _ = try sys.solve(ctx.in_arg != .none);
        const out = try s.arena.alloc(TypeId, list.len);
        for (list, out) |t, *o| o.* = try infer.zonk(s, t);
        list = out;
        // In an argument, a branch left open that the others fit below is
        // the join, its variables the call's to fix: `if (c) emptyList()
        // else mutableListOf()` passed as a `List<String>?` is a
        // `List<String>`, not a `List<Any>`.
        if (ctx.in_arg != .none) if (top) |i| if (infer.hasOpenVar(s, list[i])) {
            for (list) |t| if (s.types.isNullable(t)) return s.types.makeNullable(list[i]);
            return list[i];
        };
    }
    // Integer literals join the integral type the other branches have when
    // they fit it (`if (c) 1L else 0` is a `Long`).
    var others: std.ArrayList(TypeId) = .empty;
    var lits: ?TypeId = null;
    for (list) |t| {
        if (s.types.get(t) == .int_lit) {
            lits = if (lits) |l| try infer.joinLits(s, l, t) else t;
        } else try others.append(s.arena, try widenForDecl(s, t));
    }
    if (lits) |l| {
        if (others.items.len != 0) {
            const lub = try subtyping.commonSupertype(s, others.items);
            const nn = try s.types.makeNotNull(lub);
            if (infer.isIntegral(s, nn) and try subtyping.isSubtype(s, l, nn)) return lub;
        } else if (expected != .none and !s.types.isErr(expected)) {
            // Only literals: the integral type expected of them, when they
            // fit it (`val x: Long = if (c) 1 else 2`).
            const nn = try s.types.makeNotNull(expected);
            if (infer.isIntegral(s, nn) and try subtyping.isSubtype(s, l, nn)) return nn;
        } else if (ctx.in_arg != .none) {
            // Only literals, in a branch or an argument: still a literal,
            // for the enclosing branches or call to type (`if (c) 5L else
            // if (d) 1 else -2` is a `Long`).
            return l;
        }
    }
    var widened: std.ArrayList(TypeId) = .empty;
    for (list) |t| try widened.append(s.arena, try widenForDecl(s, t));
    return subtyping.commonSupertype(s, widened.items);
}

fn returnTarget(ctx: *Ctx, label: ?ast.Ident) ?*Scope {
    var sc: ?*Scope = ctx.scope;
    if (label) |l| {
        const n = ctx.s.names.lookup(l.name) orelse return null;
        while (sc) |c| : (sc = c.parent) {
            if ((c.kind == .lambda or c.kind == .function) and c.label == n) return c;
        }
        return null;
    }
    // A bare `return` leaves the innermost named function, crossing lambdas.
    while (sc) |c| : (sc = c.parent) {
        if (c.kind == .function) return c;
    }
    return null;
}

/// A branch whose value is an integer literal has the integral type the
/// branches joined to: `if (c) 1L.shl(n) else 0` makes the `0` a `Long`,
/// as a nested `if`'s or `when`'s literal branches and a block's last
/// literal are. Recorded on the literal's node so lowering makes that
/// constant.
pub fn adoptLiteralBranch(ctx: *Ctx, e: *const Expr, joined: TypeId) Allocator.Error!void {
    const s = ctx.s;
    if (joined == .none or s.types.isErr(joined)) return;
    const t = try s.types.makeNotNull(joined);
    if (!infer.isIntegral(s, t)) return;
    switch (e.*) {
        .IntLit => try ctx.addType(e.id(), e.span(), t, false),
        .Unary => |u| if ((u.op == .Neg or u.op == .Pos) and u.expr.* == .IntLit) {
            try ctx.addType(e.id(), e.span(), t, false);
            try ctx.addType(u.expr.id(), u.expr.span(), t, false);
        },
        .Block => |b| if (b.stmts.len != 0) switch (b.stmts[b.stmts.len - 1]) {
            .Expr => |*last| try adoptLiteralBranch(ctx, last, joined),
            else => {},
        },
        .If => |i| if (i.else_branch) |eb| {
            try ctx.addType(e.id(), e.span(), t, false);
            try adoptLiteralBranch(ctx, i.then_branch, joined);
            try adoptLiteralBranch(ctx, eb, joined);
        },
        .When => |w| {
            try ctx.addType(e.id(), e.span(), t, false);
            for (w.branches) |*br| try adoptLiteralBranch(ctx, &br.body, joined);
        },
        else => {},
    }
}

fn ifExpr(ctx: *Ctx, cond: *const Expr, then_b: *const Expr, else_b: ?*const Expr, expected_in: TypeId) Allocator.Error!TypeId {
    const s = ctx.s;
    const expected = try branchExpected(s, expected_in);
    const facts = try condition(ctx, cond);
    var list: std.ArrayList(TypeId) = .empty;
    // Branch results stay open for `join` when nothing is expected.
    const saved_arg = ctx.in_arg;
    defer ctx.in_arg = saved_arg;
    if (try openExpected(s, expected) and ctx.in_arg == .none) ctx.in_arg = .branch;
    var outs: [2]BranchOut = undefined;
    {
        const sc = try ctx.push(.block, .none);
        try applyFacts(ctx, facts.when_true);
        const t = try expr(ctx, then_b, expected);
        try list.append(s.arena, t);
        outs[0] = try branchOut(ctx, sc, then_b, t);
        ctx.pop(sc);
    }
    if (else_b) |eb| {
        const sc = try ctx.push(.block, .none);
        try applyFacts(ctx, facts.when_false);
        const t = try expr(ctx, eb, expected);
        try list.append(s.arena, t);
        outs[1] = try branchOut(ctx, sc, eb, t);
        ctx.pop(sc);
        ctx.in_arg = saved_arg;
        const r = try join(ctx, list.items, expected);
        try adoptLiteralBranch(ctx, then_b, r);
        try adoptLiteralBranch(ctx, eb, r);
        try applyFacts(ctx, try mergeBranches(ctx, &outs, null));
        return r;
    }
    outs[1] = facts.when_false;
    ctx.in_arg = saved_arg;
    _ = try join(ctx, list.items, expected);
    try applyFacts(ctx, try mergeBranches(ctx, &outs, null));
    return s.t.unit;
}

fn whenExpr(ctx: *Ctx, w: *const ast.WhenExpr, expected_in: TypeId) Allocator.Error!TypeId {
    const s = ctx.s;
    const expected = try branchExpected(s, expected_in);
    // Popped by hand once the branches' facts are merged.
    const outer = try ctx.push(.block, .none);
    errdefer ctx.pop(outer);
    var subject_t: TypeId = .none;
    var subject_sym: Sym = .none;
    if (w.subject) |subj| {
        subject_t = try independent(ctx, subj, .none);
        if (w.subject_binding) |bind| {
            const t = if (bind.ty) |*tr| try resolveTypeInBody(ctx, tr) else try widenForDecl(s, subject_t);
            const sym = try newLocal(ctx, try ctx.intern(bind.name.name), bind.name, t, false);
            try ctx.declareLocal(s.syms.name(sym), sym);
            try ctx.addRef(.{ .file = ctx.file, .anchor = bind.name.span, .kind = .decl, .target = sym });
            subject_sym = sym;
            subject_t = t;
        } else {
            subject_sym = stableSubject(ctx, subj);
        }
    }
    var list: std.ArrayList(TypeId) = .empty;
    var outs: std.ArrayList(BranchOut) = .empty;
    var has_else = false;
    // Without a subject, a branch is reached only when every earlier
    // condition was false.
    var prior_false: std.ArrayList(Narrow) = .empty;
    for (w.branches) |*br| {
        const sc = try ctx.push(.block, .none);
        try applyFacts(ctx, prior_false.items);
        var narrowed: TypeId = .none;
        for (br.patterns) |*pat| {
            switch (pat.kind) {
                .Value => |*v| {
                    if (w.subject != null) {
                        _ = try expr(ctx, v, subject_t);
                        // `null ->` is an identity test, not a call.
                        if (v.* != .NullLit) try calls.equalsRef(ctx, v.span(), subject_t);
                        // `null -> ...` (alone or among other patterns):
                        // every later branch sees the subject not null.
                        if (v.* == .NullLit and subject_sym != .none) {
                            try prior_false.append(s.arena, .{ .sym = subject_sym, .ty = try s.types.definitelyNotNull(try narrowedType(ctx, subject_sym, subject_t)) });
                        }
                    } else {
                        const facts = try condition(ctx, v);
                        // Every condition of an earlier branch was false
                        // when a later one runs; one alone was true here.
                        if (br.patterns.len == 1) try applyFacts(ctx, facts.when_true);
                        try prior_false.appendSlice(s.arena, facts.when_false);
                    }
                },
                .InRange, .NotInRange => |*v| {
                    const rt = try expr(ctx, v, .none);
                    _ = try calls.containsCall(ctx, v.span(), rt, subject_t);
                },
                .IsType => |*tr| {
                    const t = try isCheckType(ctx, tr, false);
                    try typeTestRef(ctx, .is_, t, pat.span, .none);
                    if (br.patterns.len == 1) narrowed = t;
                },
                .NotIsType => |*tr| try typeTestRef(ctx, .not_is, try resolveTypeInBody(ctx, tr), pat.span, .none),
                .Else => has_else = true,
            }
        }
        if (narrowed != .none and subject_sym != .none) {
            try ctx.scope.narrow.append(s.arena, .{ .sym = subject_sym, .ty = try intersectNarrow(ctx, subject_t, narrowed) });
        }
        const saved_arg = ctx.in_arg;
        if (try openExpected(s, expected) and ctx.in_arg == .none) ctx.in_arg = .branch;
        const bt = try expr(ctx, &br.body, expected);
        try list.append(s.arena, bt);
        ctx.in_arg = saved_arg;
        try outs.append(s.arena, try branchOut(ctx, sc, &br.body, bt));
        ctx.pop(sc);
    }
    // A `when` without `else` may match nothing and fall through.
    if (!has_else) try outs.append(s.arena, prior_false.items);
    const r = try join(ctx, list.items, expected);
    for (w.branches) |*br| try adoptLiteralBranch(ctx, &br.body, r);
    const merged = try mergeBranches(ctx, outs.items, outer);
    ctx.pop(outer);
    try applyFacts(ctx, merged);
    return r;
}

fn forLoop(ctx: *Ctx, f: *const ast.ForExpr) Allocator.Error!TypeId {
    const s = ctx.s;
    const it_t = try receiverExpr(ctx, f.iter);
    const elem = try calls.iteration(ctx, f.iter.span(), it_t);
    const sc = try ctx.push(.block, .none);
    defer ctx.pop(sc);
    if (f.vars.len == 1 and !f.destructured) {
        const vt = if (f.var_ty) |*tr| try resolveTypeInBody(ctx, tr) else elem;
        const sym = try newLocal(ctx, try ctx.intern(f.vars[0].name), f.vars[0], vt, false);
        try ctx.declareLocal(s.syms.name(sym), sym);
        try ctx.addRef(.{ .file = ctx.file, .anchor = f.vars[0].span, .kind = .decl, .target = sym });
    } else {
        try destructure(ctx, f.vars, f.by_name, f.var_sources, elem, f.iter.span(), false);
    }
    _ = try expr(ctx, f.body, .none);
    return s.t.unit;
}

fn objectExpr(ctx: *Ctx, o: *const ast.ObjectLiteral) Allocator.Error!TypeId {
    const s = ctx.s;
    const cls = try sema_mod.decls.collectObjectLiteral(s, ctx.file, o, ctx.localOwner());
    try ctx.addRef(.{ .file = ctx.file, .anchor = o.span, .kind = .decl, .target = cls });
    try resolveLocalClassBody(ctx, cls);
    return headers.selfType(s, cls);
}

fn thisExpr(ctx: *Ctx, qualifier: ?ast.Ident, sp: Span) Allocator.Error!TypeId {
    const s = ctx.s;
    const r = (try thisReceiver(ctx, qualifier)) orelse {
        try ctx.report(.unresolved_receiver, sp, "this{s}{s}", .{ if (qualifier != null) "@" else "", if (qualifier) |q| q.name else "" });
        return s.types.errType();
    };
    try ctx.addRef(.{ .file = ctx.file, .anchor = sp, .kind = .this_, .target = r.owner, .dispatch = .{ .implicit = .{ .kind = r.kind, .owner = r.owner } } });
    return narrowedReceiver(ctx, r);
}

/// Records a type test: `is`, `as`, a catch parameter, a class literal.
/// The class is the erased class of `t`, none for a type parameter.
pub fn typeTestRef(ctx: *Ctx, kind: records.TypeTestKind, t: TypeId, sp: Span, binding: Sym) Allocator.Error!void {
    const s = ctx.s;
    if (s.types.isErr(t)) return;
    const rec = try s.arena.create(records.TypeTestRec);
    rec.* = .{
        .kind = kind,
        .ty = t,
        .class = s.types.classSym(try s.types.makeNotNull(t)),
        .nullable = s.types.isNullable(t),
        .binding = binding,
    };
    try ctx.addRef(.{ .file = ctx.file, .anchor = sp, .kind = .type_test, .target = rec.class, .detail = .{ .type_test = rec } });
}

/// The receiver `this` or `this@label` names.
pub fn thisReceiver(ctx: *Ctx, qualifier: ?ast.Ident) Allocator.Error!?Recv {
    const s = ctx.s;
    const want: ?Name = if (qualifier) |q| (s.names.lookup(q.name) orelse return null) else null;
    var sc: ?*Scope = ctx.scope;
    while (sc) |c| : (sc = c.parent) {
        for (c.receivers.items) |r| {
            if (want) |n| {
                if (r.label != n) continue;
                return r;
            }
            // The innermost implicit receiver. In a class's body its own
            // `this` comes before its companions; in a header, which runs
            // before the instance exists, a supertype's companion is `this`
            // (`object : W(this)` passes `W.Companion`).
            return r;
        }
    }
    return null;
}

/// A receiver's type with the smart casts on `this` applied.
pub fn narrowedReceiver(ctx: *Ctx, r: Recv) Allocator.Error!TypeId {
    return narrowedType(ctx, r.owner, r.ty);
}

// ------------------------------------------------------------ smart casts --

pub const Facts = struct {
    when_true: []const Narrow = &.{},
    when_false: []const Narrow = &.{},
};

/// Resolves a condition and returns the smart casts it establishes on
/// each outcome.
pub fn condition(ctx: *Ctx, cond: *const Expr) Allocator.Error!Facts {
    return (try conditionTyped(ctx, cond)).facts;
}

const TypedFacts = struct { facts: Facts, ty: TypeId };

fn conditionTyped(ctx: *Ctx, cond: *const Expr) Allocator.Error!TypedFacts {
    // The condition is a node of its own, as when it is resolved as an
    // expression.
    const saved = ctx.enterNode(cond.id());
    defer ctx.leaveNode(saved);
    const r = try conditionInner(ctx, cond);
    try ctx.addType(cond.id(), cond.span(), r.ty, needsRecord(cond));
    return r;
}

fn conditionInner(ctx: *Ctx, cond: *const Expr) Allocator.Error!TypedFacts {
    const s = ctx.s;
    const saved_arg = ctx.in_arg;
    ctx.in_arg = .none;
    defer ctx.in_arg = saved_arg;
    const b_t = s.t.boolean;
    switch (cond.*) {
        .IsCheck => |c| {
            _ = try expr(ctx, c.expr, .none);
            const t = try isCheckType(ctx, &c.ty, false);
            try typeTestRef(ctx, if (c.negated) .not_is else .is_, t, c.ty.span, .none);
            return .{ .facts = try isFacts(ctx, c.expr, t, c.negated), .ty = b_t };
        },
        .Binary => |b| switch (b.op) {
            .Eq, .Neq, .IdentEq, .IdentNeq => {
                const lt = try expr(ctx, b.lhs, .none);
                _ = try expr(ctx, b.rhs, .none);
                // `x == null` is an identity test, not a call.
                if ((b.op == .Eq or b.op == .Neq) and b.lhs.* != .NullLit and b.rhs.* != .NullLit) try calls.equalsRef(ctx, cond.span(), lt);
                return .{ .facts = try nullFacts(ctx, b.op, b.lhs, b.rhs), .ty = b_t };
            },
            .And => {
                const l = try condition(ctx, b.lhs);
                const sc = try ctx.push(.block, .none);
                try applyFacts(ctx, l.when_true);
                const r = try condition(ctx, b.rhs);
                ctx.pop(sc);
                return .{ .facts = .{ .when_true = try concat(ctx, l.when_true, r.when_true) }, .ty = b_t };
            },
            .Or => {
                const l = try condition(ctx, b.lhs);
                const sc = try ctx.push(.block, .none);
                try applyFacts(ctx, l.when_false);
                const r = try condition(ctx, b.rhs);
                ctx.pop(sc);
                return .{ .facts = .{ .when_false = try concat(ctx, l.when_false, r.when_false) }, .ty = b_t };
            },
            else => {},
        },
        // `!x` is `x.not()` on whatever `x` is: `Boolean.not`, or an
        // `operator fun B.not()`.
        .Unary => |u| if (u.op == .Not) {
            const inner = try conditionTyped(ctx, u.expr);
            const t = try calls.notRef(ctx, cond, inner.ty);
            return .{ .facts = .{ .when_true = inner.facts.when_false, .when_false = inner.facts.when_true }, .ty = t };
        },
        else => {},
    }
    const refs_before = ctx.refCount();
    const t = try expr(ctx, cond, b_t);
    // `x.isNullOrEmpty()`: a contract's `returns(true)` and `returns(false)`
    // say what each outcome implies.
    if (cond.* == .Call) return .{ .facts = try contractFacts(ctx, cond, refs_before, .outcome), .ty = t };
    return .{ .facts = .{}, .ty = t };
}

// -------------------------------------------------------------- contracts --

pub const EffectKind = enum { returns, returns_true, returns_false, returns_not_null };

/// `returns(...) implies (cond)` in a function's `contract { }`: `cond` is
/// written over the function's parameters and `this`.
pub const Effect = struct { kind: EffectKind, cond: *const Expr };

/// The effects a function's contract declares, read from the first
/// statement of its body.
fn contractOf(s: *Sema, f: Sym) Allocator.Error![]const Effect {
    if (s.contracts.get(f)) |c| return c;
    var out: std.ArrayList(Effect) = .empty;
    const fd = switch (s.syms.get(f).decl) {
        .function => |fd| fd,
        else => null,
    };
    if (fd) |d| if (d.body) |*b| if (b.* == .Block and b.Block.stmts.len != 0) {
        const first = &b.Block.stmts[0];
        if (first.* == .Expr and first.Expr == .Call) {
            const c = first.Expr.Call;
            if (c.callee.* == .Path and c.callee.Path.segments.len == 1 and std.mem.eql(u8, c.callee.Path.segments[0].name, "contract") and c.args.len == 1 and c.args[0] == .Lambda) {
                for (c.args[0].Lambda.body.stmts) |*st| {
                    if (st.* != .Expr or st.Expr != .Call) continue;
                    const imp = st.Expr.Call;
                    if (!imp.is_infix or imp.args.len != 2) continue;
                    if (imp.callee.* != .Path or !std.mem.eql(u8, imp.callee.Path.segments[0].name, "implies")) continue;
                    const r = &imp.args[0];
                    if (r.* != .Call or r.Call.callee.* != .Path) continue;
                    const rn = r.Call.callee.Path.segments[0].name;
                    const kind: EffectKind = if (std.mem.eql(u8, rn, "returnsNotNull"))
                        .returns_not_null
                    else if (!std.mem.eql(u8, rn, "returns"))
                        continue
                    else if (r.Call.args.len == 0)
                        .returns
                    else switch (r.Call.args[0]) {
                        .BoolLit => |bl| if (bl.value) .returns_true else .returns_false,
                        else => continue,
                    };
                    try out.append(s.arena, .{ .kind = kind, .cond = &imp.args[1] });
                }
            }
        }
    };
    try s.contracts.put(s.arena, f, out.items);
    return out.items;
}

const ContractUse = enum { returns, outcome };

/// The smart casts a call's contract gives: past its normal return
/// (`use == .returns`, in `when_true`), or on each Boolean outcome.
fn contractFacts(ctx: *Ctx, e: *const Expr, refs_before: usize, use: ContractUse) Allocator.Error!Facts {
    const s = ctx.s;
    const rec = ctx.callRecordSince(e.id(), refs_before) orelse return .{};
    if (s.syms.kind(rec.callee) != .function) return .{};
    const effects = try contractOf(s, rec.callee);
    if (effects.len == 0) return .{};
    const c = &e.Call;
    const params = s.syms.functionInfo(rec.callee).params;
    const recv: ?*const Expr = if (c.callee.* == .Member) c.callee.Member.receiver else null;
    const binding: ContractBinding = .{ .call = c, .params = params, .args = rec.args, .receiver = recv, .callee = rec.callee };
    var out: Facts = .{};
    for (effects) |eff| {
        switch (use) {
            .returns => if (eff.kind == .returns) {
                const f = try impliedFacts(ctx, eff.cond, &binding);
                out.when_true = try concat(ctx, out.when_true, f.when_true);
            },
            .outcome => switch (eff.kind) {
                .returns_true => out.when_true = try concat(ctx, out.when_true, (try impliedFacts(ctx, eff.cond, &binding)).when_true),
                .returns_false => out.when_false = try concat(ctx, out.when_false, (try impliedFacts(ctx, eff.cond, &binding)).when_true),
                else => {},
            },
        }
    }
    return out;
}

const ContractBinding = struct {
    call: *const @FieldType(Expr, "Call"),
    params: []const Sym,
    args: []const records.ArgSource,
    receiver: ?*const Expr,
    /// The function declaring the contract: its types are written there.
    callee: Sym,
};

/// The argument expression a contract's name stands for: a parameter's
/// operand, or the receiver for `this`.
fn contractOperand(ctx: *Ctx, e: *const Expr, b: *const ContractBinding) ?*const Expr {
    switch (e.*) {
        .This => return b.receiver,
        .Path => |p| {
            if (p.segments.len != 1) return null;
            for (b.params, 0..) |prm, i| {
                if (!std.mem.eql(u8, ctx.s.str(ctx.s.syms.name(prm)), p.segments[0].name)) continue;
                if (i >= b.args.len) return null;
                return switch (b.args[i]) {
                    .arg => |ai| if (ai < b.call.args.len) &b.call.args[ai] else null,
                    .receiver => b.receiver,
                    else => null,
                };
            }
            return null;
        },
        else => return null,
    }
}

/// What a contract condition says about the call's operands when it holds
/// (`when_true`) and when it does not (`when_false`).
fn impliedFacts(ctx: *Ctx, cond: *const Expr, b: *const ContractBinding) Allocator.Error!Facts {
    switch (cond.*) {
        .Path, .This => {
            // A Boolean parameter: the argument's own condition holds.
            const arg = contractOperand(ctx, cond, b) orelse return .{};
            return conditionFactsOnly(ctx, arg);
        },
        .Binary => |bin| switch (bin.op) {
            .Eq, .Neq, .IdentEq, .IdentNeq => {
                const side = if (bin.rhs.* == .NullLit) bin.lhs else if (bin.lhs.* == .NullLit) bin.rhs else return .{};
                const arg = contractOperand(ctx, side, b) orelse return .{};
                const f = try nonNullFacts(ctx, arg);
                return if (bin.op == .Neq or bin.op == .IdentNeq) .{ .when_true = f } else .{ .when_false = f };
            },
            .And => {
                const l = try impliedFacts(ctx, bin.lhs, b);
                const r = try impliedFacts(ctx, bin.rhs, b);
                return .{ .when_true = try concat(ctx, l.when_true, r.when_true) };
            },
            else => return .{},
        },
        .Unary => |u| if (u.op == .Not) {
            const inner = try impliedFacts(ctx, u.expr, b);
            return .{ .when_true = inner.when_false, .when_false = inner.when_true };
        } else return .{},
        // `implies (this@isError is NetRequestStatus.Error)`: the operand is
        // the type, as written where the contract is declared.
        .IsCheck => |c| {
            const arg = contractOperand(ctx, c.expr, b) orelse return .{};
            ctx.s.census.muted += 1;
            const t = headers.resolveTypeRef(ctx.s, headers.ctxOf(ctx.s, b.callee), &c.ty);
            ctx.s.census.muted -= 1;
            const ty = try t;
            if (ctx.s.types.isErr(ty)) return .{};
            return isFacts(ctx, arg, ty, c.negated);
        },
        else => return .{},
    }
}

/// `e is t`: `e` is a `t` on the outcome that says so. A safe chain
/// `r?.m is T` with a non-null `T` also says `r` is not null, and narrows
/// `r.m` when that is a stable path.
fn isFacts(ctx: *Ctx, e: *const Expr, t: TypeId, negated: bool) Allocator.Error!Facts {
    const s = ctx.s;
    var out: std.ArrayList(Narrow) = .empty;
    const non_null = !s.types.isErr(t) and !s.types.isNullable(t);
    if (non_null) try out.appendSlice(s.arena, try nonNullFacts(ctx, e));
    const subj = (try subjectOf(ctx, e)) orelse try safeSubject(ctx, e);
    if (subj) |sj| try out.append(s.arena, .{ .sym = sj.sym, .ty = try intersectNarrow(ctx, sj.ty, t) });
    return if (negated) .{ .when_false = out.items } else .{ .when_true = out.items };
}

/// `r?.m` for a stable `r` and a stable property `m`: the path `r.m`.
fn safeSubject(ctx: *Ctx, e: *const Expr) Allocator.Error!?Subject {
    if (e.* != .Member or !e.Member.safe) return null;
    const base = stableSubject(ctx, e.Member.receiver);
    if (base == .none) return null;
    const path = try pathSubject(ctx, base, e.Member.name.name);
    if (path == .none) return null;
    return .{ .sym = path, .ty = try narrowedType(ctx, path, try subjectBaseType(ctx, path)) };
}

fn concat(ctx: *Ctx, a: []const Narrow, b: []const Narrow) Allocator.Error![]const Narrow {
    const out = try ctx.arena().alloc(Narrow, a.len + b.len);
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len..], b);
    return out;
}

fn oneFact(ctx: *Ctx, sym: Sym, t: TypeId) Allocator.Error![]const Narrow {
    const out = try ctx.arena().alloc(Narrow, 1);
    out[0] = .{ .sym = sym, .ty = t };
    return out;
}

pub fn applyFacts(ctx: *Ctx, facts: []const Narrow) Allocator.Error!void {
    for (facts) |f| try ctx.scope.narrow.append(ctx.arena(), f);
}

/// A stable value a smart cast can attach to: a local, a parameter, a
/// read-only property of `this`, or `this` itself (by its receiver owner).
pub fn stableSubject(ctx: *Ctx, e: *const Expr) Sym {
    const s = ctx.s;
    switch (e.*) {
        .Path => |p| {
            var base = stableName(ctx, p.segments[0]);
            for (p.segments[1..]) |seg| {
                if (base == .none) return .none;
                base = pathSubject(ctx, base, seg.name) catch .none;
            }
            return base;
        },
        // `a.b` where `a` is stable and `b` a stable property.
        .Member => |m| {
            if (m.safe) return .none;
            const base = stableSubject(ctx, m.receiver);
            if (base == .none) return .none;
            return pathSubject(ctx, base, m.name.name) catch .none;
        },
        .This => |t| {
            const r = (thisReceiver(ctx, t.qualifier) catch null) orelse return .none;
            return r.owner;
        },
        .Labeled => |l| return stableSubject(ctx, l.expr),
        else => {
            _ = s;
            return .none;
        },
    }
}

/// A bare name that is a stable value: a local, a parameter, or a
/// read-only property of an implicit receiver.
fn stableName(ctx: *Ctx, id: ast.Ident) Sym {
    const s = ctx.s;
    const n = s.names.lookup(id.name) orelse return .none;
    if (lookupLocalValue(ctx, n)) |loc| {
        const k = s.syms.kind(loc);
        if (k == .local or k == .value_param) return loc;
        return .none;
    }
    const r = findImplicitProperty(ctx, n) catch return .none;
    if (r) |sym| {
        if (stableProperty(s, sym)) return sym;
        return .none;
    }
    // A top-level `val` of the reading code's own module: nothing else
    // can change it between two reads (`val minus: Any = -0.0` smart
    // casts after `minus is Double`).
    const top = calls.topLevelProperty(ctx, n) catch return .none;
    if (top) |sym| {
        if (stableProperty(s, sym) and sameModule(s, sym, ctx.file)) return sym;
    }
    return .none;
}

/// Whether `sym` is declared among the files `file` is compiled with: the
/// program's, or the libraries'.
fn sameModule(s: *Sema, sym: Sym, file: u32) bool {
    const a = s.fileOf(s.syms.get(sym).file) orelse return false;
    const b = s.fileOf(file) orelse return false;
    return a.origin == b.origin;
}

/// A property whose value cannot change between two reads, so a smart
/// cast on it holds: a `val`, final, without a custom getter or delegate.
fn stableProperty(s: *Sema, p: Sym) bool {
    if (s.syms.kind(p) != .property) return false;
    const f = s.syms.flags(p);
    if (f.mutable or f.modality != .final) return false;
    return switch (s.syms.get(p).decl) {
        .property => |pd| pd.getter == null and pd.delegate == null,
        .class_param => true,
        else => false,
    };
}

/// The subject standing for `base.name` when `name` is a stable property
/// of `base`'s type, one per pair, typed with the property's type as seen
/// through `base`.
fn pathSubject(ctx: *Ctx, base: Sym, name_str: []const u8) Allocator.Error!Sym {
    const s = ctx.s;
    const n = s.names.lookup(name_str) orelse return .none;
    const base_t = try narrowedType(ctx, base, try subjectBaseType(ctx, base));
    if (s.types.isErr(base_t)) return .none;
    const ms = try members.lookup(s, base_t, n, .property);
    if (ms.len == 0 or !stableProperty(s, ms[0].sym)) return .none;
    const key: u64 = (@as(u64, base.int()) << 32) | ms[0].sym.int();
    if (s.path_subjects.get(key)) |sym| return sym;
    const sym = try s.syms.addLocal(.{
        .kind = .local,
        .name = n,
        .owner = .none,
        .file = ctx.file,
        .flags = .{ .synthetic = true },
        .decl = .none,
        .detail = 0,
    }, .{ .ty = try members.memberType(s, ms[0]) });
    try s.path_subjects.put(s.arena, key, sym);
    return sym;
}

/// The declared type of a subject: a local's or parameter's, a property's,
/// the receiver's for `this` (keyed by the receiver's owner).
fn subjectBaseType(ctx: *Ctx, sym: Sym) Allocator.Error!TypeId {
    const s = ctx.s;
    return switch (s.syms.kind(sym)) {
        .local, .value_param, .property => symbolType(ctx, sym),
        else => blk: {
            var sc: ?*Scope = ctx.scope;
            while (sc) |c| : (sc = c.parent) {
                for (c.receivers.items) |r| if (r.owner == sym) break :blk r.ty;
            }
            break :blk s.types.errType();
        },
    };
}

/// A read of `e` narrowed by the smart casts on it, when it is a stable
/// member path.
fn narrowRead(ctx: *Ctx, e: *const Expr, t: TypeId) Allocator.Error!TypeId {
    const subj = stableSubject(ctx, e);
    if (subj == .none) return t;
    return narrowedType(ctx, subj, t);
}

fn findImplicitProperty(ctx: *Ctx, n: Name) Allocator.Error!?Sym {
    var sc: ?*Scope = ctx.scope;
    while (sc) |c| : (sc = c.parent) {
        for (c.receivers.items) |r| {
            const ms = try members.lookup(ctx.s, try narrowedReceiver(ctx, r), n, .property);
            if (ms.len != 0) return ms[0].sym;
        }
    }
    return null;
}

pub const Subject = struct { sym: Sym, ty: TypeId };

/// A stable value a smart cast attaches to, with its type as the smart
/// casts in scope already see it.
pub fn subjectOf(ctx: *Ctx, e: *const Expr) Allocator.Error!?Subject {
    const sym = stableSubject(ctx, e);
    if (sym == .none) return null;
    if (e.* == .This) {
        const r = (try thisReceiver(ctx, e.This.qualifier)) orelse return null;
        return .{ .sym = sym, .ty = try narrowedReceiver(ctx, r) };
    }
    if (e.* == .Labeled) return subjectOf(ctx, e.Labeled.expr);
    return .{ .sym = sym, .ty = try narrowedType(ctx, sym, try symbolType(ctx, sym)) };
}

/// `x == null`, `x != null`, `x === null`, `x !== null`: the subject is
/// not null on the outcome that rules null out.
fn nullFacts(ctx: *Ctx, op: ast.BinOp, lhs: *const Expr, rhs: *const Expr) Allocator.Error!Facts {
    const eq = op == .Eq or op == .IdentEq;
    if (rhs.* == .NullLit or lhs.* == .NullLit) {
        const subj_expr = if (rhs.* == .NullLit) lhs else rhs;
        const fact = try nonNullFacts(ctx, subj_expr);
        const null_fact = try nullOnlyFacts(ctx, subj_expr);
        return if (eq) .{ .when_true = null_fact, .when_false = fact } else .{ .when_true = fact, .when_false = null_fact };
    }
    // `x?.isActive == true`, `descriptor === polyDescriptor`: equal to a
    // value that is not null, the side is not null either.
    const subj_expr = if (try knownNonNull(ctx, rhs)) lhs else if (try knownNonNull(ctx, lhs)) rhs else return .{};
    const fact = try nonNullFacts(ctx, subj_expr);
    return if (eq) .{ .when_true = fact } else .{ .when_false = fact };
}

/// What knowing a stable `e` is null says: it is a `Nothing?` as well as
/// its type (`i == null` makes `i.foo()` call a `String?.foo()` for an
/// `Int?`, and `i`'s members are still its type's).
fn nullOnlyFacts(ctx: *Ctx, e: *const Expr) Allocator.Error![]const Narrow {
    const s = ctx.s;
    const subj = (try subjectOf(ctx, e)) orelse return &.{};
    if (!try subtyping.admitsNull(s, subj.ty) or s.types.isErr(subj.ty)) return &.{};
    if (s.types.get(subj.ty) == .intersection) return &.{};
    const nn = try s.types.makeNotNull(subj.ty);
    if (nn == s.t.nothing) return &.{};
    const out = try s.arena.alloc(Narrow, 1);
    out[0] = .{ .sym = subj.sym, .ty = try s.types.intern(.{ .intersection = &.{ subj.ty, s.t.nothing_q } }) };
    return out;
}

/// A literal, or a stable value whose type is not nullable.
fn knownNonNull(ctx: *Ctx, e: *const Expr) Allocator.Error!bool {
    if (nonNullLiteral(e)) return true;
    const subj = (try subjectOf(ctx, e)) orelse return false;
    return !try subtyping.admitsNull(ctx.s, subj.ty);
}

fn nonNullLiteral(e: *const Expr) bool {
    return switch (e.*) {
        .BoolLit, .IntLit, .FloatLit, .CharLit, .StringTemplate => true,
        else => false,
    };
}

/// What knowing `e` is not null says: a stable `e` is not null, and for a
/// safe access `r?.m` or safe call `r?.f()`, neither is `r` (nor `r.m`
/// when that is a stable path).
pub fn nonNullFacts(ctx: *Ctx, e: *const Expr) Allocator.Error![]const Narrow {
    const s = ctx.s;
    var out: std.ArrayList(Narrow) = .empty;
    var cur = e;
    while (true) {
        if (try subjectOf(ctx, cur)) |subj| {
            try out.append(s.arena, .{ .sym = subj.sym, .ty = try s.types.definitelyNotNull(subj.ty) });
            // A `val` initialized from a safe chain carries the chain's facts.
            if (s.nonnull_implies.get(subj.sym)) |implied| try out.appendSlice(s.arena, implied);
        }
        // `x as? T` is not null exactly when `x` is a `T`.
        if (cur.* == .As and cur.As.safe) {
            if (try subjectOf(ctx, cur.As.expr)) |subj| {
                const t = try resolveTypeInBodyQuiet(ctx, &cur.As.ty);
                if (!s.types.isErr(t)) try out.append(s.arena, .{ .sym = subj.sym, .ty = try intersectNarrow(ctx, subj.ty, try s.types.makeNotNull(t)) });
            }
            break;
        }
        const recv: *const Expr = switch (cur.*) {
            .Member => |m| blk: {
                if (!m.safe) break;
                // `r?.m` is `r.m` once `r` is known not null.
                const base = stableSubject(ctx, m.receiver);
                if (base != .none) {
                    const path = try pathSubject(ctx, base, m.name.name);
                    if (path != .none) try out.append(s.arena, .{ .sym = path, .ty = try s.types.definitelyNotNull(try narrowedType(ctx, path, try subjectBaseType(ctx, path))) });
                }
                break :blk m.receiver;
            },
            .Call => |c| blk: {
                if (c.callee.* != .Member or !c.callee.Member.safe) break;
                break :blk c.callee.Member.receiver;
            },
            else => break,
        };
        cur = recv;
    }
    return out.items;
}

/// A subject of type `current` narrowed by `is t`: the tested type when it
/// is a subtype of what the subject already is, else the intersection of
/// both, so members of each stay reachable. A subtype of a class that
/// declares private members is intersected with the class too: the
/// subtype does not inherit them, and `is Derived -> baz()` in `Base`
/// still calls `Base`'s private `baz`. A bare generic type (`is List` on an
/// `Iterable<T>`) takes its arguments from the subject.
fn intersectNarrow(ctx: *Ctx, current: TypeId, t_in: TypeId) Allocator.Error!TypeId {
    const s = ctx.s;
    if (s.types.isErr(current) or s.types.isErr(t_in)) return t_in;
    const cur_nn = try s.types.makeNotNull(current);
    const t = try refineBareType(ctx, cur_nn, t_in);
    // `is T?` keeps the value nullable when it was: `b: Any?` after
    // `b is Double?` is a `Double?`, not a `Double`.
    const keep_null = s.types.isNullable(t) and try subtyping.admitsNull(s, current);
    const t_nn = try s.types.makeNotNull(t);
    if (try subtyping.isSubtype(s, t_nn, cur_nn)) {
        if (keep_null) return s.types.makeNullable(t_nn);
        const cur_cls = s.types.classSym(cur_nn);
        if (cur_cls != .none and cur_cls != s.types.classSym(t_nn) and declaresPrivate(s, cur_cls)) {
            return s.types.intern(.{ .intersection = &.{ cur_nn, t_nn } });
        }
        return t_nn;
    }
    if (try subtyping.isSubtype(s, cur_nn, t_nn)) return if (keep_null) s.types.makeNullable(cur_nn) else cur_nn;
    return s.types.intern(.{ .intersection = &.{ cur_nn, t_nn } });
}

/// Whether class `cls` declares a private function or property.
fn declaresPrivate(s: *Sema, cls: Sym) bool {
    var it = s.syms.classInfo(cls).members.iterator();
    while (it.next()) |e| for (e.value_ptr.items) |m| {
        const k = s.syms.kind(m);
        if ((k == .function or k == .property) and s.syms.flags(m).visibility == .private) return true;
    };
    return false;
}

/// `is C` written without type arguments for a generic `C`: the arguments
/// that make `C<...>` a subtype of the subject, else star projections.
fn refineBareType(ctx: *Ctx, subject: TypeId, t: TypeId) Allocator.Error!TypeId {
    const s = ctx.s;
    const c = switch (s.types.get(t)) {
        .class => |c| c,
        else => return t,
    };
    const tps = s.syms.classInfo(c.sym).type_params;
    if (tps.len == 0 or c.args.len != 0) return t;
    var sys = infer.System.init(s);
    try sys.addTypeParams(tps);
    const opened = try sys.open(try headers.selfType(s, c.sym));
    // Only the parts of the subject `C` extends say anything about its
    // arguments; `is List` on an `Iterable<T> & RandomAccess` learns from
    // the `Iterable<T>`.
    const parts: []const TypeId = switch (s.types.get(subject)) {
        .intersection => |p| p,
        else => &.{subject},
    };
    for (parts) |part| {
        const pc = s.types.classSym(part);
        if (pc == .none) continue;
        const view = (try subtyping.supertypeWithClass(s, opened, pc)) orelse continue;
        // Argument by argument: one the subject cannot answer (`Plugin<P,
        // B, F>`'s rigid `P` against `CallPipeline`) leaves the others
        // inferred (`plugin is ScopedPlugin` is a `ScopedPlugin<B, F>`).
        const pc_tps = try headers.classTypeParams(s, pc);
        const pargs = s.types.argsOf(try s.types.makeNotNull(part));
        for (s.types.argsOf(view), 0..) |va, i| {
            if (i >= pargs.len) break;
            const pa = pargs[i];
            if (va.variance == .star or pa.variance == .star) continue;
            const decl: types.Variance = if (i < pc_tps.len) s.syms.typeParamInfo(pc_tps[i]).variance else .inv;
            const v: types.Variance = if (pa.variance != .inv) pa.variance else decl;
            var trial = try sys.clone();
            const fits = switch (v) {
                .out => try trial.constrain(va.ty, pa.ty),
                .in => try trial.constrain(pa.ty, va.ty),
                else => try trial.constrain(va.ty, pa.ty) and try trial.constrain(pa.ty, va.ty),
            };
            if (!fits) continue;
            switch (v) {
                .out => _ = try sys.constrain(va.ty, pa.ty),
                .in => _ = try sys.constrain(pa.ty, va.ty),
                else => {
                    _ = try sys.constrain(va.ty, pa.ty);
                    _ = try sys.constrain(pa.ty, va.ty);
                },
            }
        }
    }
    const args = try s.arena.alloc(types.Arg, tps.len);
    if (try sys.solve(true)) {
        for (tps, args) |tp, *a| {
            const f = sys.fixedFor(tp);
            a.* = if (f != .none and !infer.hasOpenVar(s, f)) .{ .variance = .inv, .ty = f } else .{ .variance = .star, .ty = .none };
        }
    } else {
        for (args) |*a| a.* = .{ .variance = .star, .ty = .none };
    }
    return s.types.classAttrs(c.sym, args, c.nullable, c.attrs);
}

/// The type of `sym` as the smart casts in scope see it, `declared` when
/// none applies.
pub fn narrowedType(ctx: *Ctx, sym: Sym, declared: TypeId) Allocator.Error!TypeId {
    var sc: ?*Scope = ctx.scope;
    while (sc) |c| : (sc = c.parent) {
        var i = c.narrow.items.len;
        while (i > 0) {
            i -= 1;
            const n = c.narrow.items[i];
            if (n.sym == sym) return n.ty;
        }
    }
    return (try fieldCast(ctx, sym)) orelse declared;
}

/// A property with an explicit backing field reads as the field's type
/// inside the class that declares it, where the field is visible.
fn fieldCast(ctx: *Ctx, sym: Sym) Allocator.Error!?TypeId {
    const s = ctx.s;
    if (s.syms.kind(sym) != .property) return null;
    const pd = switch (s.syms.get(sym).decl) {
        .property => |pd| pd,
        else => return null,
    };
    if (pd.explicit_field == null or pd.getter != null) return null;
    // A class member's field is visible in the class; a top-level
    // property's in its file.
    const owner = s.syms.owner(sym);
    var inside = s.syms.kind(owner) != .class and s.syms.get(sym).file == ctx.file;
    var sc: ?*Scope = ctx.scope;
    while (sc) |c| : (sc = c.parent) {
        if (c.kind == .class and c.owner == owner) inside = true;
    }
    if (!inside) return null;
    if (s.syms.propertyInfo(sym).field_ty == .none) _ = try inferPropertyType(s, sym);
    const ft = s.syms.propertyInfo(sym).field_ty;
    return if (ft == .none or s.types.isErr(ft)) null else ft;
}

/// After `x as T`, `x` is a `T` for the rest of the block.
fn narrowAfterCast(ctx: *Ctx, e: *const Expr, t: TypeId) Allocator.Error!void {
    if (ctx.s.types.isErr(t)) return;
    const subj = (try subjectOf(ctx, e)) orelse return;
    try ctx.scope.narrow.append(ctx.arena(), .{ .sym = subj.sym, .ty = try intersectNarrow(ctx, subj.ty, t) });
}

/// After `x!!`, `x` is not null for the rest of the block.
fn narrowAfterNotNull(ctx: *Ctx, e: *const Expr) Allocator.Error!void {
    const subj = (try subjectOf(ctx, e)) orelse return;
    try ctx.scope.narrow.append(ctx.arena(), .{ .sym = subj.sym, .ty = try ctx.s.types.definitelyNotNull(subj.ty) });
}

/// The smart casts in effect where a branch ends, or null when it never
/// completes normally.
const BranchOut = ?[]const Narrow;

fn branchOut(ctx: *Ctx, sc: *const Scope, e: *const Expr, t: TypeId) Allocator.Error!BranchOut {
    if (jumps(e) or (t != .none and isNothingType(ctx.s, t))) return null;
    return try ctx.arena().dupe(Narrow, sc.narrow.items);
}

/// The smart casts that hold where branches meet: a symbol narrowed on
/// some path takes the common supertype of its type on every path that
/// completes, a path that leaves it alone contributing its type before the
/// branches. Symbols declared in `inner` (a `when` subject binding) end
/// with it.
fn mergeBranches(ctx: *Ctx, outs: []const BranchOut, inner: ?*const Scope) Allocator.Error![]const Narrow {
    const s = ctx.s;
    var live: std.ArrayList([]const Narrow) = .empty;
    for (outs) |o| if (o) |x| try live.append(s.arena, x);
    var merged: std.ArrayList(Narrow) = .empty;
    if (live.items.len == 0) return merged.items;
    var seen: std.AutoHashMapUnmanaged(Sym, void) = .empty;
    for (live.items) |out| for (out) |n| {
        if ((try seen.getOrPut(s.arena, n.sym)).found_existing) continue;
        if (inner) |sc| if (declaresLocal(sc, n.sym)) continue;
        const before = try narrowedType(ctx, n.sym, try subjectBaseType(ctx, n.sym));
        const tys = try s.arena.alloc(TypeId, live.items.len);
        var same = true;
        for (live.items, tys) |o, *t| {
            t.* = lastNarrow(o, n.sym) orelse before;
            if (t.* != tys[0]) same = false;
        }
        const t = if (same) tys[0] else try subtyping.commonSupertype(s, tys);
        if (t == before or s.types.isErr(t)) continue;
        try merged.append(s.arena, .{ .sym = n.sym, .ty = t });
    };
    return merged.items;
}

fn lastNarrow(out: []const Narrow, sym: Sym) ?TypeId {
    var i = out.len;
    while (i > 0) {
        i -= 1;
        if (out[i].sym == sym) return out[i].ty;
    }
    return null;
}

fn declaresLocal(sc: *const Scope, sym: Sym) bool {
    for (sc.locals.items) |l| if (l.sym == sym) return true;
    return false;
}

/// A block that completes leaves its smart casts on the values declared
/// outside it to the code after it.
fn flowOut(ctx: *Ctx, sc: *Scope) Allocator.Error!void {
    const parent = sc.parent orelse return;
    for (sc.narrow.items) |n| {
        if (declaresLocal(sc, n.sym)) continue;
        try parent.narrow.append(ctx.arena(), n);
    }
}

/// The facts of a condition that is already resolved.
fn conditionFactsOnly(ctx: *Ctx, cond: *const Expr) Allocator.Error!Facts {
    switch (cond.*) {
        .IsCheck => |c| return isFacts(ctx, c.expr, try isCheckType(ctx, &c.ty, true), c.negated),
        .Binary => |b| switch (b.op) {
            .Eq, .Neq, .IdentEq, .IdentNeq => return nullFacts(ctx, b.op, b.lhs, b.rhs),
            .Or => {
                const l = try conditionFactsOnly(ctx, b.lhs);
                const r = try conditionFactsOnly(ctx, b.rhs);
                return .{ .when_false = try concat(ctx, l.when_false, r.when_false) };
            },
            .And => {
                const l = try conditionFactsOnly(ctx, b.lhs);
                const r = try conditionFactsOnly(ctx, b.rhs);
                return .{ .when_true = try concat(ctx, l.when_true, r.when_true) };
            },
            else => return .{},
        },
        .Unary => |u| if (u.op == .Not) {
            const inner = try conditionFactsOnly(ctx, u.expr);
            return .{ .when_true = inner.when_false, .when_false = inner.when_true };
        } else return .{},
        else => return .{},
    }
}

/// The type an `is` check tests: a generic type alias written bare is its
/// class written bare (`is Z` for `typealias Z<U> = B<U>`), whose type
/// arguments the smart cast infers from the subject.
fn isCheckType(ctx: *Ctx, tr: *const ast.TypeRef, quiet: bool) Allocator.Error!TypeId {
    const s = ctx.s;
    const t = if (quiet) try resolveTypeInBodyQuiet(ctx, tr) else try resolveTypeInBody(ctx, tr);
    if (tr.type_args.len != 0 or tr.function != null or s.types.isErr(t)) return t;
    const n = s.names.lookup(tr.name.name) orelse return t;
    const found = try scope_mod.classifierInContext(s, typeCtx(ctx).decl, ctx.file, n);
    if (found == .none or s.syms.kind(found) != .type_alias) return t;
    if (s.syms.aliasInfo(found).type_params.len == 0) return t;
    const cls = s.types.classSym(try s.types.makeNotNull(t));
    if (cls == .none) return t;
    return s.types.class(cls, &.{}, s.types.isNullable(t));
}

pub fn resolveTypeInBodyQuiet(ctx: *Ctx, tr: *const ast.TypeRef) Allocator.Error!TypeId {
    // Already reported when the condition resolved.
    const before = ctx.s.census.sites.items.len;
    const t = try resolveTypeInBody(ctx, tr);
    ctx.s.census.truncate(before);
    return t;
}

/// Whether an expression always leaves the enclosing block.
pub fn jumps(e: *const Expr) bool {
    return switch (e.*) {
        .Return, .Throw, .Break, .Continue => true,
        .Block => |b| b.stmts.len != 0 and switch (b.stmts[b.stmts.len - 1]) {
            .Expr => |*last| jumps(last),
            else => false,
        },
        else => false,
    };
}

pub fn symbolType(ctx: *Ctx, sym: Sym) Allocator.Error!TypeId {
    const s = ctx.s;
    return switch (s.syms.kind(sym)) {
        .local => s.syms.localInfo(sym).ty,
        .value_param => blk: {
            const t = try headers.paramType(s, sym);
            if (s.syms.flags(sym).vararg) break :blk try calls.varargArrayType(ctx, t);
            break :blk t;
        },
        .property => headers.propertyType(s, sym),
        .class => headers.selfType(s, sym),
        else => s.types.errType(),
    };
}

// ------------------------------------------------------------------ names --

pub const Access = enum { read, write };

/// A local, parameter or local declaration named `n` in scope.
pub fn lookupLocal(ctx: *const Ctx, n: Name) ?Sym {
    var sc: ?*Scope = ctx.scope;
    var hide = false;
    while (sc) |c| : (sc = c.parent) {
        if (!localsVisible(c, &hide)) continue;
        var i = c.locals.items.len;
        while (i > 0) {
            i -= 1;
            if (c.locals.items[i].name == n) return c.locals.items[i].sym;
        }
    }
    return null;
}

/// The innermost local named `n` that is a value: a local function is a
/// value only through `::`, so it does not hide an outer `val` of its name.
pub fn lookupLocalValue(ctx: *const Ctx, n: Name) ?Sym {
    var sc: ?*Scope = ctx.scope;
    var hide = false;
    while (sc) |c| : (sc = c.parent) {
        if (!localsVisible(c, &hide)) continue;
        var i = c.locals.items.len;
        while (i > 0) {
            i -= 1;
            const l = c.locals.items[i];
            if (l.name != n or ctx.s.syms.kind(l.sym) == .function) continue;
            return l.sym;
        }
    }
    return null;
}

/// Every implicit receiver in scope, innermost first.
pub fn implicitReceivers(ctx: *Ctx) Allocator.Error![]const Recv {
    var out: std.ArrayList(Recv) = .empty;
    var sc: ?*Scope = ctx.scope;
    while (sc) |c| : (sc = c.parent) {
        for (c.receivers.items) |r| try out.append(ctx.arena(), r);
    }
    return out.items;
}

/// A bare name as a value: a local, a property of an implicit receiver (a
/// member or an extension), a top-level property, an object, a companion.
pub fn nameAccess(ctx: *Ctx, id: ast.Ident, access: Access) Allocator.Error!TypeId {
    const s = ctx.s;
    const n = try ctx.intern(id.name);
    const kind: records.RefKind = if (access == .write) .write else .read;
    if (lookupLocalValue(ctx, n)) |loc| {
        switch (s.syms.kind(loc)) {
            .local, .value_param => {
                try ctx.addRef(.{ .file = ctx.file, .anchor = id.span, .kind = kind, .target = loc });
                const declared = try symbolType(ctx, loc);
                return if (access == .read) narrowedType(ctx, loc, declared) else declared;
            },
            .class => {
                // A local class used as a value is its companion.
                return classifierAsValue(ctx, loc, id.span);
            },
            else => {},
        }
    }
    const recvs = try implicitReceivers(ctx);
    for (recvs) |r| {
        const rt = try narrowedReceiver(ctx, r);
        // A receiver that may be null has no members to read bare; the
        // extensions on its nullable type apply.
        const ms: []const members.Member = if (try subtyping.admitsNull(s, rt)) &.{} else try members.withoutExtensionProperties(s, try members.lookup(s, rt, n, .property));
        if (ms.len != 0) {
            const m = ms[0];
            const is_entry = s.syms.kind(m.sym) == .enum_entry;
            // An enum entry is a static value: no receiver dispatches to it.
            const recv: Receiver = if (is_entry or s.syms.flags(m.sym).static) .none else .{ .implicit = .{ .kind = r.kind, .owner = r.owner } };
            const cx = (try calls.propertyContexts(ctx, m.sym, m.subst)) orelse &.{};
            try ctx.addRef(.{ .file = ctx.file, .anchor = id.span, .kind = if (is_entry) .object else kind, .target = m.sym, .dispatch = recv, .contexts = cx });
            const t = try members.memberType(s, m);
            return if (access == .read and s.syms.kind(m.sym) == .property) narrowedType(ctx, m.sym, t) else t;
        }
        if (try calls.extensionProperty(ctx, rt, n)) |ext| {
            try ext.take();
            try ctx.addRef(.{ .file = ctx.file, .anchor = id.span, .kind = kind, .target = ext.sym, .extension = .{ .implicit = .{ .kind = r.kind, .owner = r.owner } }, .dispatch = ext.dispatch, .contexts = ext.contexts });
            return ext.ty;
        }
    }
    // Enum entries and nested objects in the enclosing classes' static scope.
    if (try staticScopeValue(ctx, n)) |hit| {
        try ctx.addRef(.{ .file = ctx.file, .anchor = id.span, .kind = if (hit.is_property) kind else .object, .target = hit.sym });
        return hit.ty;
    }
    // An enum entry imported by name (`import Color.RED`).
    for (try calls.topLevelTiers(ctx, n)) |tier| {
        for (tier) |m| {
            if (s.syms.kind(m) != .enum_entry) continue;
            try ctx.addRef(.{ .file = ctx.file, .anchor = id.span, .kind = .object, .target = m });
            return headers.selfType(s, s.syms.entryInfo(m).enum_class);
        }
    }
    if (try calls.topLevelProperty(ctx, n)) |p| {
        // A property imported from an object is read on the object.
        const subst = calls.importedSubst(ctx, p);
        const cx = (try calls.propertyContexts(ctx, p, subst)) orelse &.{};
        try ctx.addRef(.{ .file = ctx.file, .anchor = id.span, .kind = kind, .target = p, .dispatch = calls.importedOwner(ctx, p), .contexts = cx });
        const t = try s.types.substitute(try headers.propertyType(s, p), subst);
        return if (access == .read) narrowedType(ctx, p, t) else t;
    }
    var cls = try classifierInScope(ctx, n);
    // A class that is not a value (no object, no companion) does not end
    // the search: an object of its name a star import brings is the value.
    if (cls != .none and s.syms.kind(cls) == .class and !isValueClass(s, cls)) {
        const v = try scope_mod.classifierInFileWhere(s, ctx.file, n, &isValueClassifier);
        if (v != .none) cls = if (s.syms.kind(v) == .type_alias) s.types.classSym(try s.types.makeNotNull(try headers.aliasTarget(s, v))) else v;
    }
    if (cls != .none and s.syms.kind(cls) == .class) return classifierAsValue(ctx, cls, id.span);
    try ctx.report(.unresolved_name, id.span, "{s}", .{id.name});
    return s.types.errType();
}

/// An object, or a class with a companion: a class that is a value.
fn isValueClass(s: *Sema, cls: Sym) bool {
    const info = s.syms.classInfo(cls);
    return info.kind == .object or info.kind == .companion or info.companion != .none;
}

fn isValueClassifier(s: *Sema, sym: Sym) Allocator.Error!bool {
    return switch (s.syms.kind(sym)) {
        .class => isValueClass(s, sym),
        .type_alias => blk: {
            const cls = s.types.classSym(try s.types.makeNotNull(try headers.aliasTarget(s, sym)));
            break :blk cls != .none and s.syms.kind(cls) == .class and isValueClass(s, cls);
        },
        else => false,
    };
}

/// A classifier named `n` from inside the body: local classes, then the
/// enclosing declarations' classifiers and the file's.
pub fn classifierInScope(ctx: *Ctx, n: Name) Allocator.Error!Sym {
    if (lookupLocal(ctx, n)) |loc| {
        if (ctx.s.syms.kind(loc) == .class) return loc;
    }
    const tc = typeCtx(ctx);
    const c = try scope_mod.classifierInContext(ctx.s, tc.decl, ctx.file, n);
    if (c != .none and ctx.s.syms.kind(c) == .type_alias) {
        const target = try headers.aliasTarget(ctx.s, c);
        const ts = ctx.s.types.classSym(target);
        return ts;
    }
    return c;
}

/// An object, or a class's companion, used as a value.
pub fn classifierAsValue(ctx: *Ctx, cls: Sym, sp: Span) Allocator.Error!TypeId {
    const s = ctx.s;
    const info = s.syms.classInfo(cls);
    if (info.kind == .object or info.kind == .companion) {
        try ctx.addRef(.{ .file = ctx.file, .anchor = sp, .kind = .object, .target = cls });
        return headers.selfType(s, cls);
    }
    if (info.companion != .none) {
        try ctx.addRef(.{ .file = ctx.file, .anchor = sp, .kind = .object, .target = info.companion });
        return headers.selfType(s, info.companion);
    }
    try ctx.reportFacts(.unresolved_name, sp, .{
        .message = try std.fmt.allocPrint(s.arena, "`{s}` has no companion object", .{s.str(s.syms.name(cls))}),
    }, "{s} has no companion object", .{s.str(s.syms.name(cls))});
    return s.types.errType();
}

const StaticHit = struct { sym: Sym, ty: TypeId, is_property: bool = false };

/// An enum entry or object named `n` in an enclosing class's static scope,
/// as a value a call can `invoke`.
pub fn staticScopeValueSym(ctx: *Ctx, n: Name) Allocator.Error!?Sym {
    const s = ctx.s;
    var sc: ?*Scope = ctx.scope;
    while (sc) |c| : (sc = c.parent) {
        if (c.kind != .class) continue;
        for (scope_mod.membersOf(s, c.owner, n)) |m| {
            switch (s.syms.kind(m)) {
                .enum_entry => return m,
                .class => {
                    const k = s.syms.classInfo(m).kind;
                    if (k == .object or k == .companion) return m;
                },
                else => {},
            }
        }
    }
    return null;
}

/// An enum entry or nested object declared by an enclosing class.
fn staticScopeValue(ctx: *Ctx, n: Name) Allocator.Error!?StaticHit {
    const s = ctx.s;
    var sc: ?*Scope = ctx.scope;
    while (sc) |c| : (sc = c.parent) {
        if (c.kind != .class) continue;
        for (scope_mod.membersOf(s, c.owner, n)) |m| {
            switch (s.syms.kind(m)) {
                .enum_entry => return .{ .sym = m, .ty = try headers.selfType(s, s.syms.entryInfo(m).enum_class) },
                .property => if (s.syms.flags(m).static) return .{ .sym = m, .ty = try headers.propertyType(s, m), .is_property = true },
                else => {},
            }
        }
    }
    return null;
}

/// A qualified path as a value: `a.b.c` where a prefix is a package, a
/// class or a value.
pub fn qualifiedAccess(ctx: *Ctx, e: *const Expr, access: Access) Allocator.Error!TypeId {
    const s = ctx.s;
    const segs = e.Path.segments;
    // The longest prefix that names a value or a classifier, then members.
    const head = try pathHead(ctx, segs);
    var t: TypeId = head.ty;
    var i = head.used;
    if (head.kind == .none) {
        try ctx.report(.unresolved_name, segs[0].span, "{s}", .{try scope_mod.pathStr(s, segs)});
        return s.types.errType();
    }
    // The stable path read so far, for the smart casts on it.
    var subj: Sym = if (head.kind == .value) stableName(ctx, segs[0]) else .none;
    while (i < segs.len) : (i += 1) {
        const last = i + 1 == segs.len;
        const acc: Access = if (last) access else .read;
        t = try memberOnType(ctx, t, segs[i], acc, head.kind == .classifier and i == head.used, head.cls, segs[i - 1].span);
        if (s.types.isErr(t)) return t;
        if (subj != .none) subj = try pathSubject(ctx, subj, segs[i].name);
        if (subj != .none and acc == .read) t = try narrowedType(ctx, subj, t);
    }
    return t;
}

/// The type of `segs` read as a value, given what its head denotes: the
/// members after the head, read one at a time.
pub fn qualifiedAccessPrefix(ctx: *Ctx, segs: []const ast.Ident, head: Head) Allocator.Error!TypeId {
    var t = head.ty;
    var i = head.used;
    while (i < segs.len) : (i += 1) {
        t = try memberOnType(ctx, t, segs[i], .read, head.kind == .classifier and i == head.used, head.cls, segs[i - 1].span);
        if (ctx.s.types.isErr(t)) return t;
    }
    return t;
}

pub const Head = struct {
    kind: enum { none, value, classifier, package },
    ty: TypeId = .none,
    used: usize = 0,
    cls: Sym = .none,
    pkg: Sym = .none,
};

/// What the first segments of a dotted path denote: a value (a local or a
/// property in scope), a classifier (with its companion's type when used
/// as a value), or a package.
pub fn pathHead(ctx: *Ctx, segs: []const ast.Ident) Allocator.Error!Head {
    const n0 = try ctx.intern(segs[0].name);
    // A value named by the first segment wins over a classifier.
    if (try valueNamed(ctx, n0)) {
        const t = try nameAccess(ctx, segs[0], .read);
        return .{ .kind = .value, .ty = t, .used = 1 };
    }
    return qualifierHead(ctx, segs);
}

/// What a dotted path's leading segments name when its first segment is
/// not a value: a classifier (and the nested classifiers after it) or a
/// package. Records nothing, so a caller can ask before resolving.
fn qualifierHead(ctx: *Ctx, segs: []const ast.Ident) Allocator.Error!Head {
    const s = ctx.s;
    const n0 = try ctx.intern(segs[0].name);
    var cls = try classifierInScope(ctx, n0);
    var used: usize = 1;
    if (cls == .none) {
        // A package prefix, then classifiers nested in it.
        const r = try scope_mod.resolvePathContainer(s, segs);
        if (r.used == 0) return .{ .kind = .none };
        if (s.syms.kind(r.container) == .package) {
            return .{ .kind = .package, .pkg = r.container, .used = r.used };
        }
        cls = r.container;
        used = r.used;
    }
    if (s.syms.kind(cls) != .class) return .{ .kind = .none };
    // Nested classifiers along the path.
    while (used < segs.len) {
        const n = try ctx.intern(segs[used].name);
        const nested = try scope_mod.nestedClassifier(s, cls, n);
        if (nested == .none or s.syms.kind(nested) != .class) break;
        cls = nested;
        used += 1;
    }
    return .{ .kind = .classifier, .cls = cls, .used = used, .ty = .none };
}

/// Whether a bare name resolves to a value (so it shadows a classifier of
/// the same name in a qualified path).
fn valueNamed(ctx: *Ctx, n: Name) Allocator.Error!bool {
    const s = ctx.s;
    if (lookupLocal(ctx, n)) |loc| {
        const k = s.syms.kind(loc);
        return k == .local or k == .value_param;
    }
    const recvs = try implicitReceivers(ctx);
    for (recvs) |r| {
        const ms = try members.lookup(s, r.ty, n, .property);
        for (ms) |m| if (s.syms.kind(m.sym) == .property) return true;
    }
    if (try calls.topLevelProperty(ctx, n)) |_| return true;
    return false;
}

/// `segment` read on a value of type `t`, or on a classifier `cls` used as
/// a qualifier (its companion's members, its enum entries, its nested
/// objects).
fn memberOnType(ctx: *Ctx, t: TypeId, seg: ast.Ident, access: Access, on_classifier: bool, cls: Sym, qual: Span) Allocator.Error!TypeId {
    const n = try ctx.intern(seg.name);
    if (on_classifier) return staticMember(ctx, cls, qual, .none, seg, n, access);
    return calls.propertyAccess(ctx, t, n, seg.span, access, .expr);
}

/// `Cls.name`: an enum entry, a nested object, a companion member, or a
/// member of an object.
/// `qual_node`: the qualifier as an expression of its own (`Obj` in
/// `Obj.x`). A write records the object it stands for there, as the value
/// of that expression: the receiver the write back (`Obj.x += 1`,
/// `Obj.x++`) evaluates.
pub fn staticMember(ctx: *Ctx, cls: Sym, qual: Span, qual_node: ast.NodeId, seg: ast.Ident, n: Name, access: Access) Allocator.Error!TypeId {
    const s = ctx.s;
    const info = s.syms.classInfo(cls);
    for (scope_mod.membersOf(s, cls, n)) |m| {
        switch (s.syms.kind(m)) {
            .enum_entry => {
                try ctx.addRef(.{ .file = ctx.file, .anchor = seg.span, .kind = .object, .target = m });
                return headers.selfType(s, cls);
            },
            .class => {
                const mk = s.syms.classInfo(m).kind;
                if (mk == .object or mk == .companion) {
                    try ctx.addRef(.{ .file = ctx.file, .anchor = seg.span, .kind = .object, .target = m });
                    return headers.selfType(s, m);
                }
            },
            .property => if (s.syms.flags(m).static) {
                try ctx.addRef(.{ .file = ctx.file, .anchor = seg.span, .kind = if (access == .write) .write else .read, .target = m });
                return headers.propertyType(s, m);
            },
            else => {},
        }
    }
    // An object's own members, or the companion's.
    const holder: Sym = if (info.kind == .object or info.kind == .companion) cls else info.companion;
    if (holder != .none) {
        const ht = try headers.selfType(s, holder);
        const node: ast.NodeId = if (access == .write) qual_node else .none;
        try ctx.addRef(.{ .file = ctx.file, .node = node, .anchor = qual, .kind = .object, .target = holder });
        return calls.propertyAccess(ctx, ht, n, seg.span, access, .expr);
    }
    try ctx.reportFacts(.unresolved_member, seg.span, .{ .name = seg.name, .on = s.str(s.syms.name(cls)) }, "{s}.{s}", .{ s.str(s.syms.name(cls)), seg.name });
    return s.types.errType();
}

/// `recv.name` (or `recv?.name`) as a value or an assignment target.
pub fn memberAccess(ctx: *Ctx, e: *const Expr, recv: *const Expr, name: ast.Ident, safe: bool, access: Access) Allocator.Error!TypeId {
    const s = ctx.s;
    const n = try ctx.intern(name.name);
    // `Cls.name` and `pkg.Cls.name`: the receiver is a qualifier.
    if (try asQualifier(ctx, recv)) |q| {
        switch (q.kind) {
            .classifier => return staticMember(ctx, q.cls, lastNameSpan(recv), recv.id(), name, n, access),
            .package => {
                if (try calls.packageProperty(ctx, q.pkg, n)) |p| {
                    try ctx.addRef(.{ .file = ctx.file, .anchor = name.span, .kind = if (access == .write) .write else .read, .target = p });
                    return headers.propertyType(s, p);
                }
                const c = scope_mod.classifierIn(s, q.pkg, n);
                if (c != .none and s.syms.kind(c) == .class) return classifierAsValue(ctx, c, name.span);
                try ctx.report(.unresolved_name, name.span, "{s}", .{name.name});
                return s.types.errType();
            },
            else => {},
        }
    }
    if (recv.* == .Super) return calls.superMember(ctx, recv.Super, name, access);
    const recv_t = try receiverExpr(ctx, recv);
    const rt = if (safe) try s.types.makeNotNull(recv_t) else recv_t;
    var t = try calls.propertyAccess(ctx, rt, n, name.span, access, .expr);
    if (access == .read and !safe) t = try narrowRead(ctx, e, t);
    return if (safe) s.types.makeNullable(t) else t;
}

/// The expression as a qualifier (a package or classifier), when it is
/// not a value.
pub fn asQualifier(ctx: *Ctx, e: *const Expr) Allocator.Error!?Head {
    var segs: std.ArrayList(ast.Ident) = .empty;
    switch (e.*) {
        .Path => |p| try segs.appendSlice(ctx.arena(), p.segments),
        // `a.b.C` parsed as members: flatten.
        .Member => if (!try flattenPath(ctx, e, &segs)) return null,
        else => return null,
    }
    if (segs.items.len == 0) return null;
    // A value is not a qualifier; asked before anything is resolved, so
    // the caller resolving the value records it once.
    if (try valueNamed(ctx, try ctx.intern(segs.items[0].name))) return null;
    const h = try qualifierHead(ctx, segs.items);
    if (h.kind == .none or h.kind == .value) return null;
    if (h.used != segs.items.len) return null;
    return h;
}

/// The span of the last name a qualifier expression spells: `b` in `a.b`.
pub fn lastNameSpan(e: *const Expr) Span {
    return switch (e.*) {
        .Path => |p| p.segments[p.segments.len - 1].span,
        .Member => |m| m.name.span,
        else => e.span(),
    };
}

fn flattenPath(ctx: *Ctx, e: *const Expr, out: *std.ArrayList(ast.Ident)) Allocator.Error!bool {
    switch (e.*) {
        .Path => |p| {
            try out.appendSlice(ctx.arena(), p.segments);
            return true;
        },
        .Member => |m| {
            if (m.safe) return false;
            if (!try flattenPath(ctx, m.receiver, out)) return false;
            try out.append(ctx.arena(), m.name);
            return true;
        },
        else => return false,
    }
}

// ------------------------------------------------------------- operators --

fn binary(ctx: *Ctx, e: *const Expr, op: ast.BinOp, lhs: *const Expr, rhs: *const Expr, expected: TypeId) Allocator.Error!TypeId {
    const s = ctx.s;
    switch (op) {
        .And, .Or => {
            _ = try condition(ctx, e);
            return s.t.boolean;
        },
        .Eq, .Neq => {
            _ = try condition(ctx, e);
            return s.t.boolean;
        },
        .IdentEq, .IdentNeq => {
            _ = try expr(ctx, lhs, .none);
            _ = try expr(ctx, rhs, .none);
            return s.t.boolean;
        },
        .Elvis => {
            // Both sides join like branches: `x ?: ArrayList()` gives the
            // right side's element type from the left.
            const saved_arg = ctx.in_arg;
            // The left side's non-null part is taken, which a variable
            // left open cannot say: it joins as a branch at most.
            ctx.in_arg = if (try openExpected(s, expected) or saved_arg != .none) .branch else .none;
            // The left side may be null: `findChildByType(42) ?: this` for
            // a `PsiElement` infers `T? <: PsiElement?`.
            const l_expected = if (expected == .none or s.types.isErr(expected)) expected else try s.types.makeNullable(expected);
            const lt = try expr(ctx, lhs, l_expected);
            if (try openExpected(s, expected) and saved_arg == .none) ctx.in_arg = .branch else ctx.in_arg = saved_arg;
            const rt = try expr(ctx, rhs, expected);
            ctx.in_arg = saved_arg;
            const lnn = try s.types.definitelyNotNull(lt);
            if (isNothingType(s, rt)) {
                // `x ?: return`: past it, `x` is not null.
                try applyFacts(ctx, try nonNullFacts(ctx, lhs));
                return lnn;
            }
            const joined = try join(ctx, &.{ lnn, rt }, expected);
            try adoptLiteralBranch(ctx, rhs, joined);
            return joined;
        },
        .Assign => {
            const tt = try assignTarget(ctx, lhs);
            const vt = try expr(ctx, rhs, tt);
            try narrowAfterAssign(ctx, lhs, vt);
            return s.t.unit;
        },
        .In, .NotIn => {
            // The left operand is `contains`' argument: an integer literal
            // takes the type the parameter gives it (`5 in r` for a
            // `contains(l: Long)`).
            const saved_arg = ctx.in_arg;
            ctx.in_arg = .arg;
            const lt = expr(ctx, lhs, .none) catch |err| {
                ctx.in_arg = saved_arg;
                return err;
            };
            ctx.in_arg = saved_arg;
            const rt = try receiverExpr(ctx, rhs);
            _ = try calls.containsArgCall(ctx, e.span(), rt, lhs, lt);
            return s.t.boolean;
        },
        .Lt, .Le, .Gt, .Ge => {
            const lt = try receiverExpr(ctx, lhs);
            const saved_arg = ctx.in_arg;
            ctx.in_arg = .branch;
            const rt = try expr(ctx, rhs, .none);
            ctx.in_arg = saved_arg;
            _ = try calls.operatorCall(ctx, e.span(), lt, wk.compareTo, &.{.{ .expr = rhs, .ty = rt }}, .compare_to);
            return s.t.boolean;
        },
        else => {
            const n: Name = switch (op) {
                .Add => wk.plus,
                .Sub => wk.minus,
                .Mul => wk.times,
                .Div => wk.div,
                .Rem => wk.rem,
                .Range => wk.rangeTo,
                .RangeUntil => wk.rangeUntil,
                else => unreachable,
            };
            const kind: records.RefKind = switch (op) {
                .Range => .range_to,
                .RangeUntil => .range_until,
                else => .op,
            };
            // Arithmetic over integer literals is an integer literal of
            // its value, typed as one where it is used (`8192 * 2` passed
            // for a `Long`); lowering folds it.
            if (intConstValue(e)) |v| return constArithmetic(ctx, &.{ lhs, rhs }, v, expected);
            const lt = try receiverExpr(ctx, lhs);
            if (try calls.lambdaCallOperand(ctx, rhs)) |args| return calls.operatorCall(ctx, e.span(), lt, n, args, kind);
            const saved_arg = ctx.in_arg;
            ctx.in_arg = .branch;
            const rt = try expr(ctx, rhs, .none);
            ctx.in_arg = saved_arg;
            return calls.operatorCall(ctx, e.span(), lt, n, &.{.{ .expr = rhs, .ty = rt }}, kind);
        },
    }
}

pub fn isNothingType(s: *Sema, t: TypeId) bool {
    return s.builtins.nothing != .none and s.types.classSym(t) == s.builtins.nothing and !s.types.isNullable(t);
}

test {
    _ = calls;
}
