//! Definite assignment and reachability, as kotlinc's control-flow analysis
//! reports them in a program: a local read where some path reaches it
//! unassigned (`UNINITIALIZED_VARIABLE`), a `val` assigned where it may be
//! assigned already (`VAL_REASSIGNMENT`), and a function with a block body
//! and a result whose end is reachable (`NO_RETURN_IN_FUNCTION_WITH_BLOCK_BODY`).
//!
//! A structured pass over each body's syntax. What a name is, what a call
//! calls and what an expression's type is come from sema's records; a call
//! whose type is `Nothing` ends its path, and a lambda passed for a
//! parameter its callee's contract `callsInPlace` runs where the call is.

const std = @import("std");
const ast = @import("ast");
const span = @import("span");

const sema_mod = @import("sema.zig");
const Sema = sema_mod.Sema;
const symbols = @import("symbols.zig");
const records = @import("records.zig");
const types = @import("types.zig");
const body = @import("body.zig");
const declcheck = @import("declcheck.zig");
const annocheck = @import("annocheck.zig");

const Allocator = std.mem.Allocator;
const Sym = symbols.Sym;
const TypeId = types.TypeId;
const Span = span.Span;
const Expr = ast.Expr;
const Bits = std.DynamicBitSetUnmanaged;

pub fn checkProgram(s: *Sema) Allocator.Error!void {
    var i: u32 = 0;
    while (i < s.files.items.len) : (i += 1) {
        const fc = s.files.items[i];
        // A program's bodies are all resolved; a pack's or the base's only
        // where the program reaches them, which leaves the rest without
        // the records this reads.
        if (fc.origin != .program or !declcheck.checked(&fc)) continue;
        const file = fc.ast orelse continue;
        var idx = try FileIndex.build(s, i);
        // Each declaration's symbol, for its resolved types.
        var j: u32 = 1;
        while (j < s.syms.count()) : (j += 1) {
            const sym = Sym.from(j);
            const info = s.syms.get(sym);
            if (info.file != i) continue;
            switch (info.decl) {
                .function => |d| if (d) |fd| try idx.functions.put(s.arena, fd, sym),
                .property => |d| if (d) |pd| try idx.properties.put(s.arena, pd, sym),
                else => {},
            }
        }
        var w = Walker{ .s = s, .file = i, .idx = &idx };
        try w.container(file.decls, &.{}, &.{});
        // The classes declared in bodies, each initialized on its own.
        while (w.later.pop()) |l| try w.initialization(l.members, l.init_blocks, l.positions);
    }
}

/// A file's records the pass reads, by where they are.
const FileIndex = struct {
    /// Names read, written or declared, by the start of the name.
    reads: std.AutoHashMapUnmanaged(u32, Sym) = .empty,
    writes: std.AutoHashMapUnmanaged(u32, Sym) = .empty,
    decls: std.AutoHashMapUnmanaged(u32, Sym) = .empty,
    /// A call's record, by the call's node.
    calls: std.AutoHashMapUnmanaged(u32, *const records.CallRec) = .empty,
    /// The function or lambda a `return` leaves, by the return's node.
    returns: std.AutoHashMapUnmanaged(u32, Sym) = .empty,
    /// The lambda a lambda literal is, by its node.
    lambdas: std.AutoHashMapUnmanaged(u32, Sym) = .empty,
    /// Expression types, by node.
    types: std.AutoHashMapUnmanaged(u32, TypeId) = .empty,
    /// The symbols of the file's functions and properties, by declaration.
    functions: std.AutoHashMapUnmanaged(*const ast.Function, Sym) = .empty,
    properties: std.AutoHashMapUnmanaged(*const ast.Property, Sym) = .empty,

    fn build(s: *Sema, file: u32) Allocator.Error!FileIndex {
        const a = s.arena;
        var x: FileIndex = .{};
        for (s.refs.items) |r| {
            if (r.file != file or r.target == .none) continue;
            switch (r.kind) {
                .read => try x.reads.put(a, r.anchor.start, r.target),
                .write => try x.writes.put(a, r.anchor.start, r.target),
                .decl => {
                    try x.decls.put(a, r.anchor.start, r.target);
                    if (r.node != .none) try x.lambdas.put(a, r.node.int(), r.target);
                },
                .call, .ctor => if (r.detail == .call and r.node != .none) {
                    const gop = try x.calls.getOrPut(a, r.node.int());
                    if (!gop.found_existing) gop.value_ptr.* = r.detail.call;
                },
                .return_ => if (r.node != .none) try x.returns.put(a, r.node.int(), r.target),
                else => {},
            }
        }
        for (s.expr_types.items) |et| {
            if (et.file != file or et.node == .none) continue;
            try x.types.put(a, et.node.int(), et.ty);
        }
        return x;
    }
};

/// What each tracked local is on one path: definitely assigned, maybe
/// assigned; `dead` when the path cannot get here.
const State = struct {
    da: Bits,
    ma: Bits,
    dead: bool = false,

    fn clone(self: *const State, a: Allocator) Allocator.Error!State {
        return .{ .da = try self.da.clone(a), .ma = try self.ma.clone(a), .dead = self.dead };
    }

    /// Where two paths meet: assigned on both, maybe on either. A dead path
    /// says nothing.
    fn merge(self: *State, other: *const State) void {
        if (other.dead) return;
        if (self.dead) {
            self.da.setRangeValue(.{ .start = 0, .end = self.da.bit_length }, false);
            self.da.setUnion(other.da);
            self.ma.setUnion(other.ma);
            self.dead = false;
            return;
        }
        self.da.setIntersection(other.da);
        self.ma.setUnion(other.ma);
    }
};

/// A loop, for its `break`s and `continue`s.
const Loop = struct {
    label: ?[]const u8,
    breaks: std.ArrayList(State) = .empty,
    continues: std.ArrayList(State) = .empty,
};

/// A body that may run again (a loop's, a lambda's its callee may run more
/// than once): the `val`s declared before it, and the writes in it to `val`s.
/// One whose local may already be assigned when the body runs again is a
/// reassignment.
const Repeat = struct {
    declared_before: Bits,
    writes: std.ArrayList(Write) = .empty,
};

const Write = struct { slot: u32, at: Span };

/// An in-place lambda walked where its call is: a `return` to it ends its
/// path, and where it ends the call goes on.
const Inline = struct {
    sym: Sym,
    exits: std.ArrayList(State) = .empty,
};

/// A loop around the walk, or a boundary a jump cannot cross.
const Enclosing = struct { label: ?[]const u8 = null, boundary: bool = false };

/// A class body: its declarations, `init` blocks and where they stand.
const ClassBody = struct {
    members: []const ast.Decl,
    init_blocks: []const ast.Block,
    positions: []const usize,
};

const Walker = struct {
    s: *Sema,
    file: u32,
    idx: *const FileIndex,
    /// The tracked locals of the body being walked, by symbol.
    vars: std.AutoHashMapUnmanaged(Sym, u32) = .empty,
    /// Per tracked local: a `val`; declared outside the nested body being
    /// walked (a lambda or local function that does not run in place).
    is_val: std.ArrayList(bool) = .empty,
    outer: Bits = .{},
    /// Per tracked local: its declaration has been walked.
    declared: Bits = .{},
    /// Locals a nested body assigns: whether they are assigned is not known
    /// past it, and a read of one is not reported.
    unknown: Bits = .{},
    state: State = .{ .da = .{}, .ma = .{} },
    loops: std.ArrayList(Loop) = .empty,
    inlines: std.ArrayList(Inline) = .empty,
    repeats: std.ArrayList(Repeat) = .empty,
    /// Where something was reported, so a body walked twice (a loop's
    /// second iteration) reports it once.
    reported: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// In an inline function: its parameters it inlines (a function type,
    /// not `noinline`), each `crossinline` or not.
    inline_params: std.AutoHashMapUnmanaged(Sym, bool) = .empty,
    /// How many bodies that do not run in place enclose the walk.
    plain_depth: u32 = 0,
    /// Classes and object expressions declared in a body, whose own
    /// initialization is walked once the file's walks are done.
    later: std.ArrayList(ClassBody) = .empty,
    /// The loops around the walk, innermost last, and between them the
    /// bodies that do not run in place (a function, a class, a lambda not
    /// inlined), which a `break` cannot cross.
    loop_labels: std.ArrayList(Enclosing) = .empty,

    fn a(self: *const Walker) Allocator {
        return self.s.arena;
    }

    // ------------------------------------------------------ declarations --

    fn decl(self: *Walker, d: *const ast.Decl) Allocator.Error!void {
        switch (d.*) {
            .Function => |*f| try self.function(f),
            .Property => |p| try self.property(p),
            .Class => |*c| {
                const x = c.x();
                try self.container(c.members, x.init_blocks, x.init_block_positions);
                for (x.secondary_ctors) |*sc| if (sc.body) |*b| try self.topBody(.{ .block = b }, null);
                for (c.primary_params) |*cp| if (cp.default) |*dv| try self.topBody(.{ .expr = dv }, null);
            },
            .Object => |*o| try self.container(o.members, o.init_blocks, o.init_block_positions),
            .TypeAlias => {},
        }
    }

    /// A file's or a class body's declarations, then its initialization.
    fn container(self: *Walker, members: []const ast.Decl, init_blocks: []const ast.Block, positions: []const usize) Allocator.Error!void {
        for (members) |*m| try self.decl(m);
        try self.initialization(members, init_blocks, positions);
    }

    /// The property initializers and `init` blocks of a file or a class
    /// body, walked as one path in the order they run. Each property with a
    /// backing field is tracked: assigned where its initializer or delegate
    /// runs or an `init` block assigns it, and a read before that, there or
    /// in a lambda run in place, is of an uninitialized variable.
    fn initialization(self: *Walker, members: []const ast.Decl, init_blocks: []const ast.Block, positions: []const usize) Allocator.Error!void {
        const Step = union(enum) { property: *const ast.Property, block: *const ast.Block };
        var steps: std.ArrayList(Step) = .empty;
        var next_block: usize = 0;
        const ordered = positions.len == init_blocks.len;
        for (members, 0..) |*m, mi| {
            while (ordered and next_block < init_blocks.len and positions[next_block] <= mi) : (next_block += 1) {
                try steps.append(self.a(), .{ .block = &init_blocks[next_block] });
            }
            if (m.* == .Property) try steps.append(self.a(), .{ .property = m.Property });
        }
        for (init_blocks[next_block..]) |*b| try steps.append(self.a(), .{ .block = b });
        if (steps.items.len == 0) return;

        self.vars = .empty;
        self.is_val = .empty;
        self.loops = .empty;
        self.loop_labels = .empty;
        self.inlines = .empty;
        self.repeats = .empty;
        self.inline_params = .empty;
        for (steps.items) |st| switch (st) {
            .property => |p| if (self.idx.properties.get(p)) |sym| if (initialized(p)) try self.track(sym, !p.mutable),
            .block => {},
        };
        for (steps.items) |st| switch (st) {
            .property => |p| {
                if (p.init) |e| try self.prescan(e);
                if (p.delegate) |e| try self.prescan(e);
            },
            .block => |b| try self.prescanBlock(b),
        };
        const n = self.is_val.items.len;
        self.outer = try Bits.initEmpty(self.a(), n);
        self.declared = try Bits.initEmpty(self.a(), n);
        self.unknown = try Bits.initEmpty(self.a(), n);
        self.state = .{ .da = try Bits.initEmpty(self.a(), n), .ma = try Bits.initEmpty(self.a(), n) };
        for (steps.items) |st| switch (st) {
            .property => |p| {
                if (p.init) |e| try self.expr(e);
                if (p.delegate) |e| try self.expr(e);
                if (p.init == null and p.delegate == null) continue;
                const sym = self.idx.properties.get(p) orelse continue;
                if (self.vars.get(sym)) |slot| self.assign(slot);
            },
            .block => |b| try self.block(b),
        };
    }

    /// Whether a property's value is stored where its owner initializes:
    /// it has a backing field and is neither `const` nor `lateinit`.
    fn initialized(p: *const ast.Property) bool {
        if (p.is_const or p.is_lateinit or p.is_abstract or p.receiver_type != null) return false;
        return declcheck.hasBackingField(p);
    }

    fn function(self: *Walker, f: *const ast.Function) Allocator.Error!void {
        for (f.params) |*p| if (p.default) |dv| try self.topBody(.{ .expr = dv }, null);
        const b = f.body orelse return;
        const fsym = self.idx.functions.get(f);
        const wants_result = f.return_type != null and self.resultOf(if (fsym) |sym| self.s.syms.functionInfo(sym).ret else .none);
        self.inline_params = .empty;
        defer self.inline_params = .empty;
        if (f.is_inline) if (fsym) |sym| {
            const ps = self.s.syms.functionInfo(sym).params;
            if (ps.len == f.params.len) for (f.params, ps) |p, psym| {
                if (p.is_noinline) continue;
                const t = self.s.syms.paramInfo(psym).ty;
                if (t == .none or self.s.types.isNullable(t) or @import("calls.zig").functionShape(self.s, t) == null) continue;
                try self.inline_params.put(self.a(), psym, p.is_crossinline);
            };
        };
        switch (b) {
            .Block => |*blk| try self.topBody(.{ .block = blk }, if (wants_result) blk.span else null),
            .Expr => |*e| try self.topBody(.{ .expr = e }, null),
        }
    }

    /// A property's accessors; its initializer and delegate run with its
    /// owner's `initialization`.
    fn property(self: *Walker, p: *const ast.Property) Allocator.Error!void {
        const wants_result = p.ty != null and self.resultOf(if (self.idx.properties.get(p)) |sym| self.s.syms.propertyInfo(sym).ty else .none);
        if (p.getter) |g| switch (g.body) {
            .Block => |*blk| try self.topBody(.{ .block = blk }, if (wants_result) blk.span else null),
            .Expr => |*e| try self.topBody(.{ .expr = e }, null),
        };
        if (p.setter) |st| switch (st.body) {
            .Block => |*blk| try self.topBody(.{ .block = blk }, null),
            .Expr => |*e| try self.topBody(.{ .expr = e }, null),
        };
    }

    const Body = union(enum) { block: *const ast.Block, expr: *const Expr };

    /// Whether a body declared to give `t` must end in a `return`: a type
    /// known, and not `Unit` (written so or through an alias).
    fn resultOf(self: *const Walker, t: TypeId) bool {
        const s = self.s;
        return t != .none and !s.types.isErr(t) and t != s.t.unit;
    }

    /// Walks one body from a fresh state; `result_at` is the span of a block
    /// body whose end must not be reachable.
    fn topBody(self: *Walker, b: Body, result_at: ?Span) Allocator.Error!void {
        self.loop_labels = .empty;
        self.vars = .empty;
        self.is_val = .empty;
        self.loops = .empty;
        self.inlines = .empty;
        self.repeats = .empty;
        switch (b) {
            .block => |blk| try self.prescanBlock(blk),
            .expr => |e| try self.prescan(e),
        }
        const n = self.is_val.items.len;
        self.outer = try Bits.initEmpty(self.a(), n);
        self.declared = try Bits.initEmpty(self.a(), n);
        self.unknown = try Bits.initEmpty(self.a(), n);
        self.state = .{ .da = try Bits.initEmpty(self.a(), n), .ma = try Bits.initEmpty(self.a(), n) };
        switch (b) {
            .block => |blk| try self.block(blk),
            .expr => |e| try self.expr(e),
        }
        if (result_at) |sp| if (!self.state.dead) {
            const at = Span.init(sp.file, sp.end -| 1, sp.end);
            try self.report(at, .NO_RETURN_IN_FUNCTION_WITH_BLOCK_BODY, "Missing return statement.");
        };
    }

    // ----------------------------------------------------------- prescan --

    /// Gives every local a body declares, at any depth, its slot.
    fn prescanBlock(self: *Walker, b: *const ast.Block) Allocator.Error!void {
        for (b.stmts) |*st| try self.prescanStmt(st);
    }

    fn prescanStmt(self: *Walker, st: *const ast.Stmt) Allocator.Error!void {
        switch (st.*) {
            .Expr => |*e| try self.prescan(e),
            .Decl => |d| switch (d.*) {
                .Property => |p| {
                    // A `lateinit` local is checked when it is read.
                    if (!p.is_lateinit) if (self.idx.decls.get(p.name.span.start)) |sym| try self.track(sym, !p.mutable);
                    if (p.init) |e| try self.prescan(e);
                },
                .Function => |*f| if (f.body) |b| switch (b) {
                    .Block => |*blk| try self.prescanBlock(blk),
                    .Expr => |*e| try self.prescan(e),
                },
                else => {},
            },
            .Assign => |asg| {
                try self.prescan(&asg.target);
                try self.prescan(&asg.value);
            },
            .DestructuringDecl => |dd| try self.prescan(&dd.init),
        }
    }

    fn prescan(self: *Walker, e: *const Expr) Allocator.Error!void {
        switch (e.*) {
            .Block => |*b| try self.prescanBlock(b),
            .Lambda => |l| try self.prescanBlock(&l.body),
            .If => |x| {
                try self.prescan(x.cond);
                try self.prescan(x.then_branch);
                if (x.else_branch) |el| try self.prescan(el);
            },
            .While => |x| {
                try self.prescan(x.cond);
                try self.prescan(x.body);
            },
            .DoWhile => |x| {
                if (x.body) |bd| try self.prescan(bd);
                try self.prescan(x.cond);
            },
            .For => |x| {
                try self.prescan(x.iter);
                try self.prescan(x.body);
            },
            .Try => |x| {
                try self.prescanBlock(&x.body);
                for (x.catches) |*c| try self.prescanBlock(&c.body);
                if (x.finally) |*f| try self.prescanBlock(f);
            },
            .When => |x| {
                if (x.subject) |sub| try self.prescan(sub);
                for (x.branches) |*br| try self.prescan(&br.body);
            },
            .Labeled => |x| try self.prescan(x.expr),
            .Call => |c| {
                try self.prescan(c.callee);
                for (c.args) |*arg| try self.prescan(arg);
            },
            .Binary => |x| {
                try self.prescan(x.lhs);
                try self.prescan(x.rhs);
            },
            .Return => |x| if (x.value) |v| try self.prescan(v),
            .Throw => |x| try self.prescan(x.value),
            .AnonFun => |x| if (x.body) |b| switch (b.*) {
                .Block => |*blk| try self.prescanBlock(blk),
                .Expr => |*ex| try self.prescan(ex),
            },
            else => {},
        }
    }

    fn track(self: *Walker, sym: Sym, is_val: bool) Allocator.Error!void {
        const gop = try self.vars.getOrPut(self.a(), sym);
        if (gop.found_existing) return;
        gop.value_ptr.* = @intCast(self.is_val.items.len);
        try self.is_val.append(self.a(), is_val);
    }

    // -------------------------------------------------------- statements --

    fn block(self: *Walker, b: *const ast.Block) Allocator.Error!void {
        for (b.stmts) |*st| try self.stmt(st);
    }

    fn stmt(self: *Walker, st: *const ast.Stmt) Allocator.Error!void {
        switch (st.*) {
            .Expr => |*e| try self.expr(e),
            .Decl => |d| switch (d.*) {
                .Property => |p| {
                    try self.annotations(p.annotations, .{ .admits = &.{.LOCAL_VARIABLE}, .name = "local variable" });
                    if (p.init) |e| try self.expr(e);
                    if (p.delegate) |e| try self.expr(e);
                    const sym = self.idx.decls.get(p.name.span.start) orelse return;
                    const slot = self.vars.get(sym) orelse return;
                    self.declared.set(slot);
                    // Declared again on each pass of a loop: a new local.
                    self.state.da.unset(slot);
                    self.state.ma.unset(slot);
                    if (p.init != null or p.delegate != null) self.assign(slot);
                },
                .Function => |*f| if (f.body) |b| switch (b) {
                    .Block => |*blk| try self.nested(.{ .block = blk }),
                    .Expr => |*e| try self.nested(.{ .expr = e }),
                },
                .Class => |*c| try self.localClass(c),
                .Object => |*o| try self.localObject(o),
                .TypeAlias => {},
            },
            .Assign => |asg| try self.assignment(asg),
            .DestructuringDecl => |dd| try self.expr(&dd.init),
        }
    }

    fn assignment(self: *Walker, asg: *const ast.AssignStmt) Allocator.Error!void {
        const name: ?ast.Ident = switch (asg.target) {
            .Path => |p| if (p.segments.len == 1) p.segments[0] else null,
            else => null,
        };
        if (name == null) {
            // `this.x = v` in an initializer assigns the property `x`.
            if (asg.target == .Member and asg.target.Member.receiver.* == .This) {
                const m = asg.target.Member;
                if (self.idx.writes.get(m.name.span.start)) |sym| if (self.vars.contains(sym)) {
                    if (asg.op != .Assign) try self.readSym(sym, m.name.name, asg.target.span());
                    try self.expr(&asg.value);
                    try self.writeName(m.name);
                    return;
                };
            }
            try self.expr(&asg.target);
            try self.expr(&asg.value);
            if (asg.target == .Member) try self.propertyWrite(asg.target.Member.name);
            return;
        }
        const id = name.?;
        // `x += 1` reads `x` first.
        if (asg.op != .Assign) try self.readName(id);
        try self.expr(&asg.value);
        try self.writeName(id);
    }

    // ------------------------------------------------------- expressions --

    fn expr(self: *Walker, e: *const Expr) Allocator.Error!void {
        try self.exprInner(e);
        // An expression of type `Nothing` (`null!!`, a call that throws)
        // does not complete.
        if (!self.state.dead and self.isNothing(e)) self.state.dead = true;
    }

    fn exprInner(self: *Walker, e: *const Expr) Allocator.Error!void {
        switch (e.*) {
            .IntLit, .FloatLit, .BoolLit, .NullLit, .CharLit, .This, .Super, .PropertyRef => {},
            .StringTemplate => |t| for (t.parts) |part| switch (part) {
                .Text => {},
                .ShortInterp => |id| try self.readName(id),
                .Interp => |inner| try self.expr(inner),
            },
            .Path => |p| try self.readName(p.segments[0]),
            .Member => |m| if (self.thisMember(e)) |sym| {
                if (!self.state.dead) try self.readSym(sym, m.name.name, e.span());
            } else try self.expr(m.receiver),
            .MemberRef => |r| try self.expr(r.receiver),
            .Call => try self.call(e),
            .Index => |x| {
                try self.expr(x.receiver);
                for (x.args) |*arg| try self.expr(arg);
            },
            .Binary => |x| switch (x.op) {
                .And, .Or, .Elvis => {
                    try self.expr(x.lhs);
                    var skip = try self.state.clone(self.a());
                    try self.expr(x.rhs);
                    skip.merge(&self.state);
                    self.state = skip;
                },
                else => {
                    try self.expr(x.lhs);
                    try self.expr(x.rhs);
                },
            },
            .Unary => |x| {
                try self.expr(x.expr);
                if (x.op == .PreInc or x.op == .PreDec) if (single(x.expr)) |id| try self.writeName(id);
            },
            .Postfix => |x| {
                try self.expr(x.expr);
                if (x.op == .Inc or x.op == .Dec) if (single(x.expr)) |id| try self.writeName(id);
            },
            .If => |x| {
                try self.expr(x.cond);
                const after_cond = try self.state.clone(self.a());
                try self.expr(x.then_branch);
                const then_end = self.state;
                self.state = after_cond;
                if (x.else_branch) |el| try self.expr(el);
                self.state.merge(&then_end);
            },
            .When => |x| try self.when(e, x),
            .While => |x| try self.loop(null, .{ .cond = x.cond, .body = x.body, .first = .cond }),
            .DoWhile => |x| try self.loop(null, .{ .cond = x.cond, .body = x.body, .first = .body }),
            .For => |x| {
                try self.expr(x.iter);
                try self.loop(null, .{ .cond = null, .body = x.body, .first = .cond });
            },
            .Labeled => |x| switch (x.expr.*) {
                .While => |w| try self.loop(x.label.name, .{ .cond = w.cond, .body = w.body, .first = .cond }),
                .DoWhile => |w| try self.loop(x.label.name, .{ .cond = w.cond, .body = w.body, .first = .body }),
                .For => |w| {
                    try self.expr(w.iter);
                    try self.loop(x.label.name, .{ .cond = null, .body = w.body, .first = .cond });
                },
                else => try self.expr(x.expr),
            },
            .Return => |x| {
                if (x.value) |v| try self.expr(v);
                try self.returnTo(e.id());
            },
            .Throw => |x| {
                try self.expr(x.value);
                self.state.dead = true;
            },
            .Break => |x| try self.jump(if (x.label) |l| l.name else null, true, e.span()),
            .Continue => |x| try self.jump(if (x.label) |l| l.name else null, false, e.span()),
            .Block => |*b| try self.block(b),
            .Try => |x| try self.tryExpr(x),
            .Lambda => |l| {
                try self.lambdaAnnotations(l);
                try self.nested(.{ .block = &l.body });
            },
            .AnonFun => |x| if (x.body) |b| switch (b.*) {
                .Block => |*blk| try self.nested(.{ .block = blk }),
                .Expr => |*ex| try self.nested(.{ .expr = ex }),
            },
            .ObjectExpr => |o| try self.objectExpr(o),
            .IsCheck => |x| try self.expr(x.expr),
            .As => |x| try self.expr(x.expr),
            .Spread => |x| try self.expr(x.expr),
        }
    }

    fn call(self: *Walker, e: *const Expr) Allocator.Error!void {
        const c = e.Call;
        // `contract { ... }` describes the function; nothing in it runs.
        if (c.callee.* == .Path and c.callee.Path.segments.len == 1 and std.mem.eql(u8, c.callee.Path.segments[0].name, "contract")) return;
        switch (c.callee.*) {
            .Path => |p| if (p.segments.len > 1) {
                try self.readName(p.segments[0]);
            } else try self.invokesInlineParam(p.segments[0]),
            .Member => |m| {
                // `block.invoke()` is a call of the parameter too.
                const id: ?ast.Ident = if (std.mem.eql(u8, m.name.name, "invoke")) single(m.receiver) else null;
                if (id != null and self.inlineParam(id.?) != null) try self.invokesInlineParam(id.?) else try self.expr(m.receiver);
            },
            else => try self.expr(c.callee),
        }
        const rec = self.idx.calls.get(e.id().int());
        for (c.args, 0..) |*arg, i| {
            const lam = lambdaOf(arg);
            if (lam) |l| if (rec) |r| if (try self.inPlace(r, i)) |kind| {
                try self.inlineLambda(arg, l, kind);
                continue;
            };
            // An inline parameter passed on for an inline function's
            // parameter it inlines too.
            if (single(arg)) |id| if (self.inlineParam(id) != null) if (rec) |r| if (self.passesInline(r, i, false)) continue;
            // A lambda an inline function inlines: its body is the caller's,
            // though when it runs is not known.
            if (lam) |l| if (rec) |r| if (self.passesInline(r, i, true)) {
                try self.lambdaAnnotations(l);
                try self.nestedAs(.{ .block = &l.body }, false);
                continue;
            };
            if (anonFunOf(arg)) |f| if (f.body) |fb| if (rec) |r| if (self.passesInline(r, i, true) or try self.inPlace(r, i) != null) {
                switch (fb.*) {
                    .Block => |*blk| try self.nestedAs(.{ .block = blk }, false),
                    .Expr => |*ex| try self.nestedAs(.{ .expr = ex }, false),
                }
                continue;
            };
            try self.expr(arg);
        }
    }

    /// The inline parameter `id` names, with whether it is `crossinline`.
    fn inlineParam(self: *const Walker, id: ast.Ident) ?struct { Sym, bool } {
        const sym = self.idx.reads.get(id.span.start) orelse return null;
        const cross = self.inline_params.get(sym) orelse return null;
        return .{ sym, cross };
    }

    /// `block()` for an inline parameter `block`: where a body that does not
    /// run in place encloses it, a non-local return in the lambda passed for
    /// it could not leave, unless the parameter is `crossinline`.
    fn invokesInlineParam(self: *Walker, id: ast.Ident) Allocator.Error!void {
        const ip = self.inlineParam(id) orelse return;
        if (self.plain_depth == 0 or ip[1]) return;
        const d = try self.paramText(ip[0], false);
        const msg = try std.fmt.allocPrint(self.a(), "Cannot inline '{s}' here: it might contain non-local returns. Add 'crossinline' modifier to parameter declaration '{s}'.", .{ d, d });
        try self.reportMsg(id.span, .NON_LOCAL_RETURN_NOT_ALLOWED, msg);
    }

    /// Whether the call passes its operand `i` for a parameter of an inline
    /// function (or constructor) that inlines it; `local` asks too that the
    /// parameter is not `crossinline`, so a non-local return in it leaves the
    /// caller.
    fn passesInline(self: *const Walker, rec: *const records.CallRec, i: usize, local: bool) bool {
        const s = self.s;
        const k = s.syms.kind(rec.callee);
        if ((k != .function and k != .constructor) or !s.syms.flags(rec.callee).inline_) return false;
        const params = s.syms.functionInfo(rec.callee).params;
        for (rec.args, 0..) |src, pi| {
            if (src == .arg and src.arg == i) {
                if (pi >= params.len) return false;
                const fl = s.syms.flags(params[pi]);
                return !fl.no_inline and !(local and fl.crossinline);
            }
        }
        return false;
    }

    /// `name: Type` (with `crossinline` before it when `with_mod` and it is)
    /// as kotlinc writes a parameter.
    fn paramText(self: *Walker, p: Sym, with_mod: bool) Allocator.Error![]const u8 {
        const s = self.s;
        const cross = with_mod and s.syms.flags(p).crossinline;
        return std.fmt.allocPrint(self.a(), "{s}{s}: {s}", .{ if (cross) "crossinline " else "", s.str(s.syms.name(p)), try sema_mod.diagnose.typeText(s, self.a(), s.syms.paramInfo(p).ty) });
    }

    /// How the callee runs the lambda passed as its operand `i`, when its
    /// contract says it runs in place.
    fn inPlace(self: *Walker, rec: *const records.CallRec, i: usize) Allocator.Error!?body.EffectKind {
        const s = self.s;
        if (s.syms.kind(rec.callee) != .function) return null;
        const param: u16 = for (rec.args, 0..) |src, pi| {
            if (src == .arg and src.arg == i) break @intCast(pi);
        } else return null;
        for (try body.contractOf(s, rec.callee)) |eff| {
            switch (eff.kind) {
                .in_place_exactly_once, .in_place_at_least_once, .in_place_at_most_once, .in_place_unknown => {},
                else => continue,
            }
            if (eff.cond.* == .operand and eff.cond.operand == .param and eff.cond.operand.param == param) return eff.kind;
        }
        return null;
    }

    /// A lambda its callee runs where the call is: once, at least once, at
    /// most once, or any number of times.
    fn inlineLambda(self: *Walker, arg: *const Expr, l: *const ast.LambdaExpr, kind: body.EffectKind) Allocator.Error!void {
        try self.lambdaAnnotations(l);
        const sym = self.idx.lambdas.get(arg.id().int()) orelse self.idx.lambdas.get(l.id.int()) orelse Sym.none;
        try self.inlines.append(self.a(), .{ .sym = sym });
        const before = try self.state.clone(self.a());
        switch (kind) {
            .in_place_exactly_once, .in_place_at_most_once => try self.block(&l.body),
            else => {
                // It may run again: what it assigned may be assigned already.
                try self.repeats.append(self.a(), .{ .declared_before = try self.declared.clone(self.a()) });
                try self.block(&l.body);
                try self.endRepeat(if (self.state.dead) null else &self.state.ma, &.{});
            },
        }
        var frame = self.inlines.pop().?;
        for (frame.exits.items) |*x| self.state.merge(x);
        // At most once, or any number of times: it may not run.
        if (kind == .in_place_at_most_once or kind == .in_place_unknown) self.state.merge(&before);
        frame.exits.deinit(self.a());
    }

    fn when(self: *Walker, e: *const Expr, x: *const ast.WhenExpr) Allocator.Error!void {
        if (x.subject) |sub| try self.expr(sub);
        var merged = try self.state.clone(self.a());
        merged.dead = true;
        var has_else = false;
        for (x.branches) |*br| {
            for (br.patterns) |*pat| switch (pat.kind) {
                .Value, .InRange, .NotInRange => |*v| try self.expr(v),
                .Else => has_else = true,
                else => {},
            };
            const cond_state = try self.state.clone(self.a());
            if (br.guard) |g| try self.expr(&g.expr);
            try self.expr(&br.body);
            merged.merge(&self.state);
            self.state = cond_state;
        }
        const exhaustive = has_else or self.s.exhaustive_whens.contains(whenKey(self.file, e.id()));
        if (!exhaustive) merged.merge(&self.state);
        if (merged.dead) {
            merged.da.setRangeValue(.{ .start = 0, .end = merged.da.bit_length }, false);
            merged.da.setUnion(self.state.da);
            merged.ma.setUnion(self.state.ma);
        }
        self.state = merged;
    }

    const LoopShape = struct { cond: ?*const Expr, body: ?*const Expr, first: enum { cond, body } };

    fn loop(self: *Walker, label: ?[]const u8, shape: LoopShape) Allocator.Error!void {
        // `while (true)` and `do ... while (true)` leave only by a jump.
        const forever = if (shape.cond) |c| c.* == .BoolLit and c.BoolLit.value else false;
        try self.loop_labels.append(self.a(), .{ .label = label });
        defer _ = self.loop_labels.pop();
        try self.loops.append(self.a(), .{ .label = label });
        try self.repeats.append(self.a(), .{ .declared_before = try self.declared.clone(self.a()) });
        if (shape.first == .cond) if (shape.cond) |c| try self.expr(c);
        const entry = try self.state.clone(self.a());
        if (shape.body) |b| try self.expr(b);
        if (shape.first == .body) if (shape.cond) |c| try self.expr(c);
        // Where the body goes round again, what it assigned may be
        // assigned already.
        const top = &self.loops.items[self.loops.items.len - 1];
        try self.endRepeat(if (self.state.dead) null else &self.state.ma, top.continues.items);
        var lp = self.loops.pop().?;
        // The loop ends when its condition is false (never, for a constant
        // `true`), or by a `break`.
        var exit: State = if (forever) blk: {
            var x = try self.state.clone(self.a());
            x.dead = true;
            break :blk x;
        } else switch (shape.first) {
            // A `while` or `for` may not run its body at all.
            .cond => blk: {
                var x = try entry.clone(self.a());
                x.ma.setUnion(self.state.ma);
                break :blk x;
            },
            .body => self.state,
        };
        for (lp.breaks.items) |*bs| exit.merge(bs);
        if (exit.dead) {
            exit.da.setRangeValue(.{ .start = 0, .end = exit.da.bit_length }, false);
            exit.da.setUnion(self.state.da);
            exit.ma.setUnion(self.state.ma);
        }
        self.state = exit;
        lp.breaks.deinit(self.a());
        lp.continues.deinit(self.a());
    }

    /// Closes the innermost repeat: a write to a `val` declared before the
    /// body, maybe assigned where the body goes round again (`back`, the
    /// end of the body, null where it does not complete; `continues`), is a
    /// reassignment.
    fn endRepeat(self: *Walker, back: ?*const Bits, continues: []const State) Allocator.Error!void {
        var r = self.repeats.pop().?;
        var again = try Bits.initEmpty(self.a(), self.is_val.items.len);
        if (back) |b| again.setUnion(b.*);
        for (continues) |*c| again.setUnion(c.ma);
        for (r.writes.items) |w| {
            if (r.declared_before.isSet(w.slot) and again.isSet(w.slot)) try self.report(w.at, .VAL_REASSIGNMENT, "'val' cannot be reassigned.");
        }
        r.writes.deinit(self.a());
    }

    fn jump(self: *Walker, label: ?[]const u8, is_break: bool, at: Span) Allocator.Error!void {
        // The loop the jump leaves, looked for through every boundary.
        var crossed = false;
        const found = blk: {
            var i = self.loop_labels.items.len;
            while (i > 0) {
                i -= 1;
                const x = self.loop_labels.items[i];
                if (x.boundary) {
                    crossed = true;
                    continue;
                }
                if (label) |l| if (x.label == null or !std.mem.eql(u8, x.label.?, l)) continue;
                break :blk true;
            }
            break :blk false;
        };
        if (label != null and !found) {
            try self.report(at, .NOT_A_LOOP_LABEL, "Label does not denote a reachable loop.");
            self.state.dead = true;
            return;
        }
        if (found and crossed) {
            try self.report(at, .BREAK_OR_CONTINUE_JUMPS_ACROSS_FUNCTION_BOUNDARY, "'break' or 'continue' crosses a function or class boundary.");
            self.state.dead = true;
            return;
        }
        if (self.state.dead) return;
        var i = self.loops.items.len;
        while (i > 0) {
            i -= 1;
            const lp = &self.loops.items[i];
            if (label) |l| if (lp.label == null or !std.mem.eql(u8, lp.label.?, l)) continue;
            if (is_break) try lp.breaks.append(self.a(), try self.state.clone(self.a())) else try lp.continues.append(self.a(), try self.state.clone(self.a()));
            break;
        }
        self.state.dead = true;
    }

    fn returnTo(self: *Walker, node: ast.NodeId) Allocator.Error!void {
        if (self.idx.returns.get(node.int())) |target| {
            var i = self.inlines.items.len;
            while (i > 0) {
                i -= 1;
                const f = &self.inlines.items[i];
                if (f.sym == target and !self.state.dead) {
                    try f.exits.append(self.a(), try self.state.clone(self.a()));
                    break;
                }
            }
        }
        self.state.dead = true;
    }

    fn tryExpr(self: *Walker, x: *const ast.TryExpr) Allocator.Error!void {
        const before = try self.state.clone(self.a());
        // The jumps out of the body and the catches, which a `finally` that
        // never completes takes over.
        const marks = try self.a().alloc([2]usize, self.loops.items.len);
        for (self.loops.items, marks) |*lp, *m| m.* = .{ lp.breaks.items.len, lp.continues.items.len };
        const inline_marks = try self.a().alloc(usize, self.inlines.items.len);
        for (self.inlines.items, inline_marks) |*f, *m| m.* = f.exits.items.len;
        try self.block(&x.body);
        var merged = self.state;
        for (x.catches) |*c| {
            // A catch may be entered before anything the try assigns.
            var entry = try before.clone(self.a());
            entry.ma.setUnion(merged.ma);
            entry.dead = false;
            self.state = entry;
            try self.block(&c.body);
            merged.merge(&self.state);
        }
        self.state = merged;
        if (x.finally) |*f| {
            const dead = self.state.dead;
            self.state.dead = false;
            try self.block(f);
            if (self.state.dead) {
                for (self.loops.items[0..marks.len], marks) |*lp, m| {
                    lp.breaks.shrinkRetainingCapacity(m[0]);
                    lp.continues.shrinkRetainingCapacity(m[1]);
                }
                for (self.inlines.items[0..inline_marks.len], inline_marks) |*fr, m| fr.exits.shrinkRetainingCapacity(m);
            }
            if (dead) self.state.dead = true;
        }
    }

    // ----------------------------------------------- nested bodies (not run here) --

    /// A body that does not run where it is written (a lambda, a local
    /// function or class): it sees the locals as they are here, and what it
    /// assigns is assigned at no known point.
    fn nested(self: *Walker, b: Body) Allocator.Error!void {
        return self.nestedAs(b, true);
    }

    /// `nested`; `plain` when the body is not inlined where it is written.
    fn nestedAs(self: *Walker, b: Body, plain: bool) Allocator.Error!void {
        if (plain) try self.loop_labels.append(self.a(), .{ .boundary = true });
        defer if (plain) {
            _ = self.loop_labels.pop();
        };
        const saved_state = try self.state.clone(self.a());
        const saved_outer = try self.outer.clone(self.a());
        const saved_loops = self.loops;
        const saved_inlines = self.inlines;
        const saved_repeats = self.repeats;
        self.loops = .empty;
        self.inlines = .empty;
        self.repeats = .empty;
        if (plain) self.plain_depth += 1;
        defer if (plain) {
            self.plain_depth -= 1;
        };
        // Every local declared so far is outside the nested body.
        self.outer.setUnion(self.declared);
        const before_ma = try self.state.ma.clone(self.a());
        self.state.dead = false;
        switch (b) {
            .block => |blk| try self.block(blk),
            .expr => |e| try self.expr(e),
        }
        // Outer locals it assigned are of unknown state from here.
        var assigned = try self.state.ma.clone(self.a());
        var it = before_ma.iterator(.{});
        while (it.next()) |i| assigned.unset(i);
        self.unknown.setUnion(assigned);
        self.state = saved_state;
        self.state.ma.setUnion(assigned);
        self.outer = saved_outer;
        self.loops = saved_loops;
        self.inlines = saved_inlines;
        self.repeats = saved_repeats;
    }

    /// An object expression: its property initializers and `init` blocks
    /// run where it is written; its functions and accessors later.
    fn objectExpr(self: *Walker, o: *const ast.ObjectLiteral) Allocator.Error!void {
        try self.loop_labels.append(self.a(), .{ .boundary = true });
        defer _ = self.loop_labels.pop();
        for (o.members) |*d| if (d.* == .Property) {
            const p = d.Property;
            if (p.init) |e| try self.nestedAs(.{ .expr = e }, false);
            if (p.delegate) |e| try self.nestedAs(.{ .expr = e }, false);
        };
        for (o.init_blocks) |*b| try self.nestedAs(.{ .block = b }, false);
        try self.nestedDecls(o.members, false);
        try self.later.append(self.a(), .{ .members = o.members, .init_blocks = o.init_blocks, .positions = o.init_block_positions });
    }

    /// Declarations in a body; their property initializers too when
    /// `inits`.
    fn nestedDecls(self: *Walker, decls: []const ast.Decl, inits: bool) Allocator.Error!void {
        for (decls) |*d| switch (d.*) {
            .Function => |*f| if (f.body) |b| switch (b) {
                .Block => |*blk| try self.nested(.{ .block = blk }),
                .Expr => |*e| try self.nested(.{ .expr = e }),
            },
            .Property => |p| {
                if (inits) if (p.init) |e| try self.nested(.{ .expr = e });
                if (p.getter) |g| switch (g.body) {
                    .Block => |*blk| try self.nested(.{ .block = blk }),
                    .Expr => |*e| try self.nested(.{ .expr = e }),
                };
            },
            .Class => |*c| try self.localClass(c),
            .Object => |*o| try self.localObject(o),
            .TypeAlias => {},
        };
    }

    fn localClass(self: *Walker, c: *const ast.Class) Allocator.Error!void {
        const x = c.x();
        try self.later.append(self.a(), .{ .members = c.members, .init_blocks = x.init_blocks, .positions = x.init_block_positions });
        try self.nestedDecls(c.members, true);
    }

    fn localObject(self: *Walker, o: *const ast.ObjectDecl) Allocator.Error!void {
        try self.later.append(self.a(), .{ .members = o.members, .init_blocks = o.init_blocks, .positions = o.init_block_positions });
        try self.nestedDecls(o.members, true);
    }

    // ------------------------------------------------------------- names --

    /// The annotations written in a body, against the place they stand:
    /// resolved in the file, as no annotation class is local.
    fn annotations(self: *Walker, anns: []const ast.Annotation, site: annocheck.Site) Allocator.Error!void {
        try annocheck.checkPlace(self.s, .{ .decl = .none, .file = self.file }, anns, site);
    }

    fn lambdaAnnotations(self: *Walker, l: *const ast.LambdaExpr) Allocator.Error!void {
        try self.annotations(l.annotations, .{ .admits = &.{ .FUNCTION, .EXPRESSION }, .name = "anonymous function" });
    }

    fn readName(self: *Walker, id: ast.Ident) Allocator.Error!void {
        if (self.state.dead) return;
        const sym = self.idx.reads.get(id.span.start) orelse return;
        // An inline parameter is called or passed on to be inlined, nothing
        // else: as a value it has no object to be.
        if (self.inline_params.contains(sym)) {
            const msg = try std.fmt.allocPrint(self.a(), "Illegal usage of inline parameter '{s}'. Add 'noinline' modifier to the parameter declaration.", .{try self.paramText(sym, true)});
            try self.reportMsg(id.span, .USAGE_IS_NOT_INLINABLE, msg);
            return;
        }
        try self.readSym(sym, id.name, id.span);
    }

    fn readSym(self: *Walker, sym: Sym, name: []const u8, at: Span) Allocator.Error!void {
        const slot = self.vars.get(sym) orelse return;
        if (self.state.da.isSet(slot) or self.unknown.isSet(slot)) return;
        // A property read where it may run later: a lambda, a function.
        if (self.s.syms.kind(sym) == .property and self.plain_depth != 0) return;
        const msg = try std.fmt.allocPrint(self.a(), "Variable '{s}' must be initialized.", .{name});
        try self.reportMsg(at, .UNINITIALIZED_VARIABLE, msg);
    }

    /// `this.x`: a property of the class being initialized read through
    /// its receiver.
    fn thisMember(self: *const Walker, e: *const Expr) ?Sym {
        const m = e.Member;
        if (m.receiver.* != .This or m.safe) return null;
        return self.idx.reads.get(m.name.span.start);
    }

    fn writeName(self: *Walker, id: ast.Ident) Allocator.Error!void {
        const s = self.s;
        const sym = self.idx.writes.get(id.span.start) orelse return;
        if (self.vars.get(sym)) |slot| {
            if (self.is_val.items[slot] and !self.state.dead) {
                if (self.state.ma.isSet(slot) or self.outer.isSet(slot)) {
                    try self.report(id.span, .VAL_REASSIGNMENT, "'val' cannot be reassigned.");
                } else for (self.repeats.items) |*r| try r.writes.append(self.a(), .{ .slot = slot, .at = id.span });
            }
            self.assign(slot);
            return;
        }
        switch (s.syms.kind(sym)) {
            // A parameter, a loop variable, a catch parameter, a destructured
            // entry: assigned where it is declared.
            .value_param => try self.report(id.span, .VAL_REASSIGNMENT, "'val' cannot be reassigned."),
            .local => if (!s.syms.flags(sym).mutable and !s.syms.flags(sym).synthetic) try self.report(id.span, .VAL_REASSIGNMENT, "'val' cannot be reassigned."),
            .property => try self.propertyWrite(id),
            else => {},
        }
    }

    /// A write to a read-only property that has an initializer or a
    /// delegate. One without may be assigned where its class initializes.
    fn propertyWrite(self: *Walker, id: ast.Ident) Allocator.Error!void {
        const s = self.s;
        const sym = self.idx.writes.get(id.span.start) orelse return;
        if (s.syms.kind(sym) != .property or s.syms.flags(sym).mutable) return;
        const pd = switch (s.syms.get(sym).decl) {
            .property => |d| d orelse return,
            else => return,
        };
        if (pd.init == null and pd.delegate == null) return;
        try self.report(id.span, .VAL_REASSIGNMENT, "'val' cannot be reassigned.");
    }

    fn assign(self: *Walker, slot: u32) void {
        if (self.state.dead) return;
        self.state.da.set(slot);
        self.state.ma.set(slot);
    }

    /// Whether `e`'s type is `Nothing`: its recorded type, else what the
    /// function it calls returns (a type parameter by the call's argument
    /// for it), or the property it reads is.
    fn isNothing(self: *const Walker, e: *const Expr) bool {
        const s = self.s;
        const nothing = s.t.nothing;
        if (self.idx.types.get(e.id().int())) |t| return t == nothing;
        switch (e.*) {
            .Call => {
                const rec = self.idx.calls.get(e.id().int()) orelse return false;
                if (s.syms.kind(rec.callee) != .function) return false;
                const ret = s.syms.functionInfo(rec.callee).ret;
                if (ret == nothing) return true;
                switch (s.types.get(ret)) {
                    .param => |p| {
                        if (p.nullable) return false;
                        const tps = s.syms.functionInfo(rec.callee).type_params;
                        for (tps, 0..) |tp, i| if (tp == p.sym and i < rec.type_args.len) return rec.type_args[i] == nothing;
                        return false;
                    },
                    else => return false,
                }
            },
            .Path => |p| {
                const sym = self.idx.reads.get(p.segments[p.segments.len - 1].span.start) orelse return false;
                return s.syms.kind(sym) == .property and s.syms.propertyInfo(sym).ty == nothing;
            },
            .Member => |m| {
                const sym = self.idx.reads.get(m.name.span.start) orelse return false;
                return s.syms.kind(sym) == .property and s.syms.propertyInfo(sym).ty == nothing;
            },
            else => return false,
        }
    }

    fn report(self: *Walker, at: Span, factory: @import("census.zig").Factory, msg: []const u8) Allocator.Error!void {
        try self.reportMsg(at, factory, msg);
    }

    fn reportMsg(self: *Walker, at: Span, factory: @import("census.zig").Factory, msg: []const u8) Allocator.Error!void {
        if ((try self.reported.getOrPut(self.a(), at.start)).found_existing) return;
        try self.s.census.reportFacts(.declaration, self.file, at, .{ .message = msg, .factory = factory }, "{s}", .{msg});
    }
};

/// The key `Sema.exhaustive_whens` holds a `when` under.
pub fn whenKey(file: u32, node: ast.NodeId) u64 {
    return (@as(u64, file) << 32) | node.int();
}

fn single(e: *const Expr) ?ast.Ident {
    return switch (e.*) {
        .Path => |p| if (p.segments.len == 1) p.segments[0] else null,
        else => null,
    };
}

/// The anonymous function `e` is, through a label.
fn anonFunOf(e: *const Expr) ?*const ast.AnonFunExpr {
    return switch (e.*) {
        .AnonFun => |f| f,
        .Labeled => |x| anonFunOf(x.expr),
        else => null,
    };
}

fn lambdaOf(e: *const Expr) ?*const ast.LambdaExpr {
    return switch (e.*) {
        .Lambda => |l| l,
        .Labeled => |x| if (x.expr.* == .Lambda) x.expr.Lambda else null,
        else => null,
    };
}
