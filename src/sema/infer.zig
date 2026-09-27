//! Type-argument inference: a constraint system over fresh variables, one
//! per type parameter of the candidate being checked. Constraints come
//! from `argument <: parameter` and `return <: expected`; each variable is
//! fixed to the common supertype of its lower bounds, or to its upper
//! bound when nothing flows into it.
//!
//! A nested call whose variables nothing constrains (`f(emptyList())`)
//! returns its type with those variables still open; the enclosing call's
//! system adopts them and fixes them with its own. Every fixed variable is
//! recorded in `Sema.var_solution`, so a type recorded while a variable
//! was open can be completed afterwards with `zonk`.

const std = @import("std");

const sema_mod = @import("sema.zig");
const symbols = @import("symbols.zig");
const types = @import("types.zig");
const headers = @import("headers.zig");
const subtyping = @import("subtyping.zig");

const Allocator = std.mem.Allocator;
const Sema = sema_mod.Sema;
const Sym = symbols.Sym;
const TypeId = types.TypeId;

pub const Var = struct {
    /// The type parameter the variable stands for; `.none` for a variable
    /// adopted from a nested call.
    tp: Sym,
    id: u32,
    ty: TypeId,
    lower: std.ArrayList(TypeId) = .empty,
    upper: std.ArrayList(TypeId) = .empty,
    /// The type parameter's declared bounds, opened. Upper bounds too, but
    /// a variable with nothing else is still unconstrained.
    declared: std.ArrayList(TypeId) = .empty,
    fixed: TypeId = .none,
    /// Nothing constrained it.
    uninferred: bool = false,
    /// A variable an enclosing call is inferring from the body of a
    /// lambda passed to it (builder inference): this system constrains it
    /// but never fixes it, and hands what it learned to that call's.
    foreign: bool = false,
    /// Its declared bounds were constrained with the type it was fixed to.
    bounds_applied: bool = false,
    /// A lambda of the call was analyzed with it open, its body inferring
    /// it (builder inference): the call's other lambdas are too, whatever
    /// that body said of it.
    postponed: bool = false,
    /// It stands for a reified type parameter, here or in the call that
    /// left it open.
    reified: bool = false,
};

pub const System = struct {
    s: *Sema,
    vars: std.ArrayList(Var) = .empty,
    index: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// Type parameter to its variable type.
    open_subst: types.Subst = .empty,
    /// A copy solved to see what the variables would become; its fixed
    /// types never reach `Sema.var_solution`.
    trial: bool = false,
    depth: u32 = 0,
    /// The result type of a call in argument position: a variable it
    /// mentions stays open for the enclosing call to fix, unless a lambda
    /// took it as an input.
    keep: TypeId = .none,
    /// The call's result type when its variables may be left open. Only
    /// what an enclosing call adopts from it, the variables it mentions and
    /// those their bounds mention, can be fixed later; the rest are fixed
    /// here.
    result: TypeId = .none,
    /// Variables a lambda's parameter or receiver type mentions: fixed
    /// before the lambda is analyzed, so never left open.
    must_fix: std.AutoHashMapUnmanaged(u32, void) = .empty,

    pub fn init(s: *Sema) System {
        return .{ .s = s };
    }

    /// An independent copy, for a trial solve that must not fix the real
    /// system's variables. A trial never records its solutions.
    pub fn clone(self: *const System) Allocator.Error!System {
        const a = self.s.arena;
        var out = System{ .s = self.s, .trial = true, .keep = self.keep, .result = self.result };
        var mf = self.must_fix.iterator();
        while (mf.next()) |e| try out.must_fix.put(a, e.key_ptr.*, {});
        for (self.vars.items) |v| {
            var nv = v;
            nv.lower = .empty;
            nv.upper = .empty;
            nv.declared = .empty;
            try nv.lower.appendSlice(a, v.lower.items);
            try nv.upper.appendSlice(a, v.upper.items);
            try nv.declared.appendSlice(a, v.declared.items);
            try out.vars.append(a, nv);
        }
        var it = self.index.iterator();
        while (it.next()) |e| try out.index.put(a, e.key_ptr.*, e.value_ptr.*);
        var st = self.open_subst.iterator();
        while (st.next()) |e| try out.open_subst.put(a, e.key_ptr.*, e.value_ptr.*);
        return out;
    }

    /// Frees what the system holds, for a trial copy nothing reads again;
    /// the types it interned stay.
    pub fn deinit(self: *System) void {
        const a = self.s.arena;
        for (self.vars.items) |*v| {
            v.lower.deinit(a);
            v.upper.deinit(a);
            v.declared.deinit(a);
        }
        self.vars.deinit(a);
        self.index.deinit(a);
        self.open_subst.deinit(a);
        self.must_fix.deinit(a);
        self.* = undefined;
    }

    pub fn freshVar(s: *Sema) Allocator.Error!struct { id: u32, ty: TypeId } {
        const id = s.next_type_var;
        s.next_type_var += 1;
        return .{ .id = id, .ty = try s.types.intern(.{ .variable = .{ .id = id } }) };
    }

    /// One fresh variable per type parameter.
    pub fn addTypeParams(self: *System, tps: []const Sym) Allocator.Error!void {
        const s = self.s;
        for (tps) |tp| {
            const v = try freshVar(s);
            try self.index.put(s.arena, v.id, @intCast(self.vars.items.len));
            const reified = s.syms.flags(tp).reified;
            if (reified) try s.reified_vars.put(s.arena, v.id, {});
            try self.vars.append(s.arena, .{ .tp = tp, .id = v.id, .ty = v.ty, .reified = reified });
            try self.open_subst.put(s.arena, tp, v.ty);
        }
    }

    /// Takes in every still-open variable `t` mentions from a nested call.
    pub fn adopt(self: *System, t: TypeId) Allocator.Error!void {
        const s = self.s;
        switch (s.types.get(t)) {
            .variable => |v| {
                if (self.index.contains(v.id)) return;
                if (s.var_solution.contains(v.id)) return;
                try self.index.put(s.arena, v.id, @intCast(self.vars.items.len));
                var nv: Var = .{ .tp = .none, .id = v.id, .ty = try s.types.intern(.{ .variable = .{ .id = v.id } }), .foreign = s.builder_owners.contains(v.id), .reified = s.reified_vars.contains(v.id) };
                // What the call that left it open knew about it, and the
                // open variables that knowledge mentions.
                const bounds = s.open_var_bounds.get(v.id);
                if (bounds) |b| {
                    try nv.lower.appendSlice(s.arena, b.lower);
                    try nv.upper.appendSlice(s.arena, b.upper);
                    try nv.declared.appendSlice(s.arena, b.declared);
                }
                // A builder variable: what the statements of the lambda so
                // far said of it, so a candidate that contradicts them does
                // not apply (`add(Target())` then `consume(get(0))` rules
                // out `consume(Different)`).
                if (nv.foreign) if (s.builder_owners.get(v.id)) |owner| {
                    if (owner.index.get(v.id)) |oi| {
                        const ov = &owner.vars.items[oi];
                        for (ov.lower.items) |lb| if (!owner.mentionsOwnVar(lb)) try nv.lower.append(s.arena, lb);
                        for (ov.upper.items) |ub| if (!owner.mentionsOwnVar(ub)) try nv.upper.append(s.arena, ub);
                    }
                };
                try self.vars.append(s.arena, nv);
                const added = self.vars.items[self.vars.items.len - 1];
                for (added.lower.items) |lb| try self.adopt(lb);
                for (added.upper.items) |ub| try self.adopt(ub);
                for (added.declared.items) |db| try self.adopt(db);
            },
            .class => |c| for (c.args) |a| {
                if (a.variance != .star) try self.adopt(a.ty);
            },
            .intersection => |parts| for (parts) |p| try self.adopt(p),
            else => {},
        }
    }

    /// The variables the input positions of `fn_type` mention that this
    /// system cannot type yet: nothing constrains them (`trial`, solved,
    /// says so). A lambda passed there is analyzed with them as they are.
    pub fn builderVars(self: *System, trial: *const System, fn_type: TypeId) Allocator.Error![]const u32 {
        const s = self.s;
        var out: std.ArrayList(u32) = .empty;
        const nn = try s.types.makeNotNull(fn_type);
        const args = s.types.argsOf(nn);
        if (args.len == 0) return out.items;
        var found: std.ArrayList(u32) = .empty;
        for (args[0 .. args.len - 1]) |arg| {
            if (arg.variance != .star) try collectVarIds(s, arg.ty, &found);
        }
        for (found.items) |id| {
            const i = trial.index.get(id) orelse continue;
            const v = trial.vars.items[i];
            if (v.foreign) continue;
            // `parallelBuild({ base(it) }, { derived(it) })`: the second
            // lambda's `it` is still the variable the first left open, not
            // the `TargetTypeBase` the first said it is at most.
            if (!v.uninferred and !v.postponed) continue;
            if (std.mem.indexOfScalar(u32, out.items, id) == null) try out.append(s.arena, id);
        }
        for (out.items) |id| if (self.index.get(id)) |i| {
            self.vars.items[i].postponed = true;
        };
        return out.items;
    }

    /// The declared bounds of variable `t` of this system, opened.
    pub fn declaredBoundsOf(self: *const System, t: TypeId) Allocator.Error![]const TypeId {
        const i = self.varIndex(t) orelse return &.{};
        return self.vars.items[i].declared.items;
    }

    /// Fixes variable `id`, one a lambda's body is inferring, to what the
    /// statements analyzed so far say of it: the common supertype of its
    /// lower bounds, else the most specific of its upper bounds. A value of
    /// that type used as a receiver needs it now (`add(1)` then
    /// `get(0).equals(1)` fixes the element type to `Int`). Null when
    /// nothing is known of it yet.
    pub fn fixEarly(self: *System, id: u32) Allocator.Error!?TypeId {
        const s = self.s;
        const i = self.index.get(id) orelse return null;
        if (self.vars.items[i].fixed != .none) return self.vars.items[i].fixed;
        var lowers: std.ArrayList(TypeId) = .empty;
        var lits: types.IntLit = .{};
        var any_lit = false;
        for (self.vars.items[i].lower.items) |lb| {
            const z = try zonk(s, lb);
            if (self.hasUnfixed(z)) continue;
            switch (s.types.get(z)) {
                .int_lit => |l| {
                    lits = mergeLits(lits, l);
                    any_lit = true;
                },
                else => try lowers.append(s.arena, z),
            }
        }
        var result: TypeId = .none;
        if (any_lit) {
            const lit = try s.types.intern(.{ .int_lit = lits });
            const joins = lowers.items.len != 0 and try subtyping.isSubtype(s, lit, try subtyping.commonSupertype(s, lowers.items));
            if (!joins) try lowers.append(s.arena, try intLitDefault(s, lits));
        }
        if (lowers.items.len != 0) {
            result = try subtyping.commonSupertype(s, lowers.items);
        } else {
            for (self.vars.items[i].upper.items) |ub| {
                const z = try zonk(s, ub);
                if (self.hasUnfixed(z)) continue;
                result = try self.meetUpper(result, z);
            }
        }
        if (result == .none) return null;
        self.vars.items[i].fixed = result;
        if (!self.trial) try s.var_solution.put(s.arena, id, result);
        return result;
    }

    /// Leaves a variable a trial fixed unfixed again.
    pub fn unfix(self: *System, id: u32) void {
        const i = self.index.get(id) orelse return;
        self.vars.items[i].fixed = .none;
    }

    /// Hands what this system learned about the variables enclosing calls
    /// are inferring from a lambda's body to those calls' systems.
    pub fn forwardForeign(self: *System) Allocator.Error!void {
        const s = self.s;
        var i: usize = 0;
        while (i < self.vars.items.len) : (i += 1) {
            const v = self.vars.items[i];
            if (!v.foreign) continue;
            const owner = s.builder_owners.get(v.id) orelse continue;
            for (v.lower.items) |lb| {
                const t = try self.close(lb);
                if (!self.hasUnfixed(t) or self.mentionsOnlyForeign(t)) _ = try owner.constrain(t, v.ty);
            }
            for (v.upper.items) |ub| {
                const t = try self.close(ub);
                if (!self.hasUnfixed(t) or self.mentionsOnlyForeign(t)) _ = try owner.constrain(v.ty, t);
            }
        }
    }

    /// Whether this system constrains a variable an enclosing call infers
    /// from a lambda's body.
    pub fn hasForeign(self: *const System) bool {
        for (self.vars.items) |v| if (v.foreign) return true;
        return false;
    }

    /// Whether `t` mentions a variable of this system that is still open
    /// and is not one a lambda's body is inferring: a bound only this
    /// system can read.
    fn mentionsOwnVar(self: *const System, t: TypeId) bool {
        const ts = &self.s.types;
        switch (ts.get(t)) {
            .variable => |v| {
                const i = self.index.get(v.id) orelse return false;
                if (self.vars.items[i].fixed != .none) return false;
                return !self.s.builder_owners.contains(v.id);
            },
            .class => |c| {
                for (c.args) |a| if (a.variance != .star and self.mentionsOwnVar(a.ty)) return true;
                return false;
            },
            .intersection => |parts| {
                for (parts) |p| if (self.mentionsOwnVar(p)) return true;
                return false;
            },
            else => return false,
        }
    }

    /// Whether every variable of this system `t` mentions is foreign.
    fn mentionsOnlyForeign(self: *const System, t: TypeId) bool {
        const ts = &self.s.types;
        switch (ts.get(t)) {
            .variable => {
                const i = self.anyVarIndex(t) orelse return true;
                return self.vars.items[i].foreign;
            },
            .class => |c| {
                for (c.args) |a| if (a.variance != .star and !self.mentionsOnlyForeign(a.ty)) return false;
                return true;
            },
            .intersection => |parts| {
                for (parts) |p| if (!self.mentionsOnlyForeign(p)) return false;
                return true;
            },
            else => return true,
        }
    }

    /// Marks the variables the input positions of a function type mention
    /// (its receiver and parameters) as ones to fix.
    pub fn fixInputs(self: *System, fn_type: TypeId) Allocator.Error!void {
        const s = self.s;
        const nn = try s.types.makeNotNull(fn_type);
        const args = s.types.argsOf(nn);
        if (args.len == 0) return;
        for (args[0 .. args.len - 1]) |arg| {
            if (arg.variance != .star) try self.markVars(arg.ty);
        }
    }

    fn markVars(self: *System, t: TypeId) Allocator.Error!void {
        const s = self.s;
        switch (s.types.get(t)) {
            .variable => |v| try self.must_fix.put(s.arena, v.id, {}),
            .class => |c| for (c.args) |arg| {
                if (arg.variance != .star) try self.markVars(arg.ty);
            },
            .intersection => |parts| for (parts) |p| try self.markVars(p),
            else => {},
        }
    }

    /// `t` with each variable marked as a lambda's input replaced by what
    /// `fixed`, this system solved, fixed it to; the others stay.
    pub fn closeInputs(self: *const System, fixed: *const System, t: TypeId) Allocator.Error!TypeId {
        const ts = &self.s.types;
        switch (ts.get(t)) {
            .variable => |v| {
                if (!self.must_fix.contains(v.id)) return t;
                const i = fixed.index.get(v.id) orelse return t;
                const f = fixed.vars.items[i].fixed;
                if (f == .none) return t;
                return withVarNullability(ts, v, f);
            },
            .class => |c| {
                const out = try self.s.arena.alloc(types.Arg, c.args.len);
                for (c.args, out) |a, *o| {
                    o.* = a;
                    if (a.variance != .star) o.ty = try self.closeInputs(fixed, a.ty);
                }
                return ts.classAttrs(c.sym, out, c.nullable, c.attrs);
            },
            else => return t,
        }
    }

    /// `t` as far as this system can use it as an expectation: a position
    /// naming another call's open variable says nothing yet, so it becomes
    /// a star projection, and `t` itself such a variable is `.none`.
    pub fn knownPart(self: *const System, t_in: TypeId) Allocator.Error!TypeId {
        const s = self.s;
        const t = try zonk(s, t_in);
        switch (s.types.get(t)) {
            .variable => |v| return if (self.index.contains(v.id)) t else .none,
            .class => |c| {
                if (c.args.len == 0) return t;
                const out = try s.arena.alloc(types.Arg, c.args.len);
                for (c.args, out) |a, *o| {
                    o.* = a;
                    if (a.variance == .star) continue;
                    const k = try self.knownPart(a.ty);
                    if (k == .none) o.* = .{ .variance = .star, .ty = .none } else o.ty = k;
                }
                return s.types.classAttrs(c.sym, out, c.nullable, c.attrs);
            },
            .intersection => |parts| {
                for (parts) |p| if ((try self.knownPart(p)) != p) return .none;
                return t;
            },
            else => return t,
        }
    }

    /// A variable the kept result reaches, directly or through the bounds
    /// of the variables it names, that the enclosing call fixes: the
    /// `HashMap()` passed to `toMap(destination: M): M` keeps its key and
    /// value open for the call `toMap` is passed to.
    fn keptOpen(self: *const System, v: *const Var, keep_reach: ?std.AutoHashMapUnmanaged(u32, void)) bool {
        if (self.must_fix.contains(v.id)) return false;
        const r = keep_reach orelse return false;
        return r.contains(v.id);
    }

    /// The index of a (non-null) variable of this system. `V?` is not `V`:
    /// the constraint rules take the `?` off first.
    fn varIndex(self: *const System, t: TypeId) ?usize {
        return switch (self.s.types.get(t)) {
            .variable => |v| if (v.nullable or v.dnn) null else if (self.index.get(v.id)) |i| i else null,
            else => null,
        };
    }

    fn anyVarIndex(self: *const System, t: TypeId) ?usize {
        return switch (self.s.types.get(t)) {
            .variable => |v| if (self.index.get(v.id)) |i| i else null,
            else => null,
        };
    }

    /// `t` with the candidate's type parameters replaced by variables.
    pub fn open(self: *System, t: TypeId) Allocator.Error!TypeId {
        return self.s.types.substitute(t, &self.open_subst);
    }

    /// Whether `t` names one of this system's variables other than `id`
    /// (`U` in `T : U`, not `T` in `T : Comparable<T>`).
    fn mentionsOtherVar(self: *const System, t: TypeId, id: u32) bool {
        const ts = &self.s.types;
        switch (ts.get(t)) {
            .variable => |v| return v.id != id and self.anyVarIndex(t) != null,
            .class => |c| {
                for (c.args) |a| if (a.variance != .star and self.mentionsOtherVar(a.ty, id)) return true;
                return false;
            },
            .intersection => |parts| {
                for (parts) |p| if (self.mentionsOtherVar(p, id)) return true;
                return false;
            },
            else => return false,
        }
    }

    pub fn mentionsVar(self: *const System, t: TypeId) bool {
        const ts = &self.s.types;
        switch (ts.get(t)) {
            .variable => return self.anyVarIndex(t) != null,
            .class => |c| {
                for (c.args) |a| if (a.variance != .star and self.mentionsVar(a.ty)) return true;
                return false;
            },
            .intersection => |parts| {
                for (parts) |p| if (self.mentionsVar(p)) return true;
                return false;
            },
            else => return false,
        }
    }

    /// Adds `sub <: sup`. False when the constraint cannot hold whatever
    /// the variables become.
    pub fn constrain(self: *System, sub_in: TypeId, sup_in: TypeId) Allocator.Error!bool {
        const s = self.s;
        const ts = &s.types;
        // Incorporation can revisit a pair through a cycle of variables;
        // past this depth a constraint is taken as holding.
        if (self.depth > 24) return true;
        self.depth += 1;
        defer self.depth -= 1;
        try self.adopt(sub_in);
        try self.adopt(sup_in);
        const sub = try zonk(s, sub_in);
        const sup = try zonk(s, sup_in);
        if (sub == sup) return true;
        if (ts.isErr(sub) or ts.isErr(sup)) return true;
        if (self.varIndex(sup)) |i| return self.addLower(i, try self.normalizeLower(sub));
        if (self.varIndex(sub)) |i| return self.addUpper(i, sup);
        // `X <: V?`: the non-null part of X flows into V; for a type
        // parameter whose bound admits null that is `X & Any`.
        if (ts.isNullable(sup)) {
            if (self.varIndex(try ts.makeNotNull(sup))) |i| {
                const sub_nn = try ts.makeNotNull(sub);
                // A type parameter whose bound admits null, and a variable
                // that may be fixed to a nullable type, flow in as their
                // non-null part: `W? <: V?` is `W & Any <: V`.
                const part = switch (ts.get(sub_nn)) {
                    .param => if (try subtyping.admitsNull(s, sub_nn)) try ts.definitelyNotNull(sub_nn) else sub_nn,
                    .variable => try ts.definitelyNotNull(sub_nn),
                    else => sub_nn,
                };
                return self.addLower(i, try self.normalizeLower(part));
            }
        }
        // `V? <: X`: X must admit null, and V fits it.
        if (ts.isNullable(sub)) {
            if (self.varIndex(try ts.makeNotNull(sub))) |i| {
                if (!self.mentionsVar(sup) and !try subtyping.admitsNull(s, sup)) return false;
                return self.addUpper(i, sup);
            }
        }
        // `X <: W & Any`: X is not null and fits `W`; `W & Any <: X`: `W`
        // fits `X?`.
        if (dnnVar(ts, sup)) |w| {
            if (ts.isNullable(sub)) return false;
            return self.constrain(sub, w);
        }
        if (dnnVar(ts, sub)) |w| return self.constrain(w, try ts.makeNullable(sup));
        // `X <: A & B` holds when it holds for each part.
        if (ts.get(sup) == .intersection) {
            for (ts.get(sup).intersection) |part| {
                if (!try self.constrain(sub, part)) return false;
            }
            return true;
        }
        if (!self.mentionsVar(sub) and !self.mentionsVar(sup)) return subtyping.isSubtype(s, sub, sup);
        const sub_t = ts.get(sub);
        switch (sub_t) {
            .intersection => |parts| {
                for (parts) |p| {
                    if (try subtyping.isSubtype(s, p, try self.approx(sup))) return self.constrain(p, sup);
                }
                // The part that has the class the supertype names, when
                // the constraint holds through it (a smart cast's
                // `DeserializationStrategy<T> & AbstractPolymorphicSerializer<*>`
                // as an `AbstractPolymorphicSerializer<V>`).
                const sup_sym = ts.classSym(try ts.makeNotNull(sup));
                if (sup_sym != .none) for (parts) |p| {
                    if ((try subtyping.supertypeWithClass(s, try ts.makeNotNull(p), sup_sym)) == null) continue;
                    var trial = try self.clone();
                    defer trial.deinit();
                    if (try trial.constrain(p, sup)) return self.constrain(p, sup);
                };
                return self.constrain(parts[0], sup);
            },
            // A literal against a type still open (a declared bound
            // `Comparable<T>`) is typed once the variable is fixed: taking
            // its default here would make `T` at most an `Int` before a
            // `Long` flows in. It fits when one of its types has the class.
            .int_lit => |l| {
                if (!self.mentionsVar(sup)) return self.constrain(try intLitDefault(s, l), sup);
                const target = ts.classSym(try ts.makeNotNull(sup));
                if (target == .none) return false;
                for (litTypes(s, l)) |t| {
                    if (t != .none and (try subtyping.supertypeWithClass(s, t, target)) != null) return true;
                }
                return false;
            },
            else => {},
        }
        if (isNothing(s, sub)) return !ts.isNullable(sub) or try subtyping.admitsNull(s, try self.approx(sup));
        const sub_nn = try ts.makeNotNull(sub);
        const sup_nn = try ts.makeNotNull(sup);
        if (ts.isNullable(sub) and !ts.isNullable(sup) and ts.get(sup) == .class) return false;
        switch (ts.get(sub_nn)) {
            .class => {},
            .param => |p| {
                if (ts.get(sup_nn) == .param and ts.get(sup_nn).param.sym == p.sym) return true;
                for (try headers.typeParamBounds(s, p.sym)) |b| {
                    if (try self.constrain(b, sup_nn)) return true;
                }
                return false;
            },
            else => return true,
        }
        const sup_c = switch (ts.get(sup_nn)) {
            .class => |c| c,
            else => return true,
        };
        const up = (try subtyping.supertypeWithClass(s, sub_nn, sup_c.sym)) orelse return false;
        const have = ts.argsOf(up);
        const tps = try headers.classTypeParams(s, sup_c.sym);
        for (sup_c.args, 0..) |w, i| {
            if (w.variance == .star or i >= have.len) continue;
            const h = have[i];
            if (h.variance == .star) {
                // A star projection captures an unknown type within the
                // parameter's bound; the bound is what flows into a
                // variable.
                if (self.varIndex(w.ty)) |vi| {
                    const bound: TypeId = if (i < tps.len) blk: {
                        const bs = try headers.typeParamBounds(s, tps[i]);
                        break :blk if (bs.len != 0) bs[0] else s.t.any_q;
                    } else s.t.any_q;
                    try self.vars.items[vi].lower.append(s.arena, bound);
                }
                continue;
            }
            const decl_var: types.Variance = if (i < tps.len) s.syms.typeParamInfo(tps[i]).variance else .inv;
            // `Array<in Number> <: Array<W>` for an invariant parameter: `W`
            // is the captured type, of which `Number` is a lower bound
            // (`sourceArr.copyInto(dest)` for a `dest: Array<in Number>`
            // gives an `Array<Number>`, not the receiver's `Array<Int>`).
            if (decl_var == .inv and w.variance == .inv and h.variance == .in) {
                if (!try self.constrain(h.ty, w.ty)) return false;
                continue;
            }
            const v: types.Variance = if (w.variance != .inv) w.variance else if (h.variance != .inv) h.variance else decl_var;
            switch (v) {
                .out => if (!try self.constrain(h.ty, w.ty)) return false,
                .in => if (!try self.constrain(w.ty, h.ty)) return false,
                .inv, .star => {
                    if (!try self.constrain(h.ty, w.ty)) return false;
                    if (!try self.constrain(w.ty, h.ty)) return false;
                },
            }
        }
        return true;
    }

    /// A new lower bound must fit every upper bound already known, and the
    /// constraint that says so is added too.
    fn addLower(self: *System, i: usize, lb: TypeId) Allocator.Error!bool {
        const s = self.s;
        // A bound already known was incorporated when it was added.
        if (std.mem.indexOfScalar(TypeId, self.vars.items[i].lower.items, lb) != null) return true;
        try self.vars.items[i].lower.append(s.arena, lb);
        const uppers = try s.arena.dupe(TypeId, self.vars.items[i].upper.items);
        for (uppers) |ub| {
            if (!try self.constrain(lb, ub)) return false;
        }
        const declared = try s.arena.dupe(TypeId, self.vars.items[i].declared.items);
        for (declared) |ub| {
            if (!try self.constrain(lb, ub)) return false;
        }
        return true;
    }

    fn addUpper(self: *System, i: usize, ub: TypeId) Allocator.Error!bool {
        const s = self.s;
        if (std.mem.indexOfScalar(TypeId, self.vars.items[i].upper.items, ub) != null) return true;
        try self.vars.items[i].upper.append(s.arena, ub);
        const lowers = try s.arena.dupe(TypeId, self.vars.items[i].lower.items);
        for (lowers) |lb| {
            if (!try self.constrain(lb, ub)) return false;
        }
        return true;
    }

    /// Each type parameter's declared bounds are upper bounds of its
    /// variable: `C : MutableCollection<in R>` is how `R` is learned from a
    /// collection argument.
    /// The declared bounds of `tps` as constraints on their variables. A
    /// bound naming the declaring class's own parameters (`fun <R : T>`
    /// in a class of `T`) sees them through `class_subst`, the receiver's
    /// arguments.
    pub fn addDeclaredBounds(self: *System, tps: []const Sym, class_subst: *const types.Subst) Allocator.Error!bool {
        const s = self.s;
        for (tps) |tp| {
            const v = self.open_subst.get(tp) orelse continue;
            const i = self.varIndex(v) orelse continue;
            for (try headers.typeParamBounds(s, tp)) |b| {
                if (s.types.classSym(b) == s.builtins.any and s.types.isNullable(b)) continue;
                try self.vars.items[i].declared.append(s.arena, try self.open(try s.types.substitute(b, class_subst)));
            }
        }
        return true;
    }

    /// Lower bounds keep integer literals as literals: `solve` gives a
    /// variable only literals flow into the integral type an upper bound
    /// asks for (`arrayOf(1, 2)` passed as `Array<Long>`), else `Int`.
    fn normalizeLower(self: *System, t: TypeId) Allocator.Error!TypeId {
        _ = self;
        return t;
    }

    fn approx(self: *System, t: TypeId) Allocator.Error!TypeId {
        return self.replaceVars(t, true);
    }

    fn replaceVars(self: *System, t: TypeId, unfixed_as_top: bool) Allocator.Error!TypeId {
        const ts = &self.s.types;
        switch (ts.get(t)) {
            .variable => |v| {
                const i = self.anyVarIndex(t) orelse return t;
                const f = self.vars.items[i].fixed;
                if (f != .none) return withVarNullability(ts, v, f);
                return if (unfixed_as_top) self.s.t.any_q else t;
            },
            .class => |c| {
                if (!self.mentionsVar(t)) return t;
                const out = try self.s.arena.alloc(types.Arg, c.args.len);
                for (c.args, out) |a, *o| {
                    o.* = a;
                    if (a.variance != .star) o.ty = try self.replaceVars(a.ty, unfixed_as_top);
                }
                return ts.classAttrs(c.sym, out, c.nullable, c.attrs);
            },
            .intersection => |parts| {
                const out = try self.s.arena.alloc(TypeId, parts.len);
                for (parts, out) |p, *o| o.* = try self.replaceVars(p, unfixed_as_top);
                return ts.intern(.{ .intersection = out });
            },
            else => return t,
        }
    }

    /// The more specific of two upper bounds: the one below the other, or
    /// a nullable one's non-null form when that is below the other
    /// (`ColorFilter?` and `Any` meet at `ColorFilter`); else the first.
    fn meetUpper(self: *const System, a: TypeId, b: TypeId) Allocator.Error!TypeId {
        const s = self.s;
        if (a == .none) return b;
        if (try subtyping.isSubtype(s, b, a)) return b;
        if (try subtyping.isSubtype(s, a, b)) return a;
        // Below `T` and `Any`: `T & Any`.
        const an = try s.types.definitelyNotNull(a);
        const bn = try s.types.definitelyNotNull(b);
        if (an != a and try subtyping.isSubtype(s, an, b)) return an;
        if (bn != b and try subtyping.isSubtype(s, bn, a)) return bn;
        // Neither is below the other: below both is their intersection
        // (`E <: Int` and `E <: String` make `E` an `Int & String`).
        var parts: std.ArrayList(TypeId) = .empty;
        for ([_]TypeId{ a, b }) |t| switch (s.types.get(t)) {
            .intersection => |ps| try parts.appendSlice(s.arena, ps),
            else => try parts.append(s.arena, t),
        };
        return s.types.intern(.{ .intersection = parts.items });
    }

    /// For a variable of this system, the most specific type under its
    /// upper bounds that mention no unfixed variable; null without one.
    pub fn upperMeet(self: *System, t: TypeId) Allocator.Error!?TypeId {
        const i = self.varIndex(try zonk(self.s, t)) orelse return null;
        var best: TypeId = .none;
        for (self.vars.items[i].upper.items) |ub| {
            const z = try zonk(self.s, ub);
            if (self.hasUnfixed(z)) continue;
            best = try self.meetUpper(best, try self.close(z));
        }
        return if (best == .none) null else best;
    }

    /// The meet of `v`'s upper bounds, when every one names no variable
    /// still open; null otherwise.
    fn closedUpperMeet(self: *System, v: *const Var) Allocator.Error!?TypeId {
        if (v.upper.items.len == 0) return null;
        var best: TypeId = .none;
        for (v.upper.items) |ub| {
            const z = try zonk(self.s, ub);
            if (self.hasUnfixed(z)) return null;
            best = try self.meetUpper(best, try self.close(z));
        }
        return best;
    }

    /// The meet of the fixed variables `v` is a lower bound of, and of the
    /// variables a lambda's body is inferring it is below: `yieldAll(listOf())`
    /// in a `sequence { }` makes `listOf`'s element the builder's `T`, for
    /// the builder to fix.
    fn impliedUpper(self: *System, v: *const Var) Allocator.Error!TypeId {
        const s = self.s;
        var best: TypeId = .none;
        for (self.vars.items) |*w| {
            if (w.id == v.id) continue;
            if (w.fixed == .none and !w.foreign) continue;
            for (w.lower.items) |lb| {
                const z = try zonk(s, lb);
                const is_v = switch (s.types.get(z)) {
                    .variable => |x| x.id == v.id and !x.nullable and !x.dnn,
                    else => false,
                };
                if (is_v) best = try self.meetUpper(best, if (w.foreign) w.ty else w.fixed);
            }
        }
        return best;
    }

    /// Fixes every variable. `leave_open` keeps a variable nothing
    /// constrained open, for a call in argument position whose enclosing
    /// call will fix it. Returns false when a fixed type violates an upper
    /// bound.
    pub fn solve(self: *System, leave_open: bool) Allocator.Error!bool {
        const s = self.s;
        const reach: ?std.AutoHashMapUnmanaged(u32, void) = if (leave_open and self.result != .none) try self.reachable(self.result) else null;
        const keep_reach: ?std.AutoHashMapUnmanaged(u32, void) = if (leave_open and self.keep != .none) try self.reachable(self.keep) else null;
        var progress = true;
        // Each round fixes a variable or ends the loop, and a variable waits
        // for those it names: `arrayOf(arrayOf(...))` fixes one level a
        // round, from the innermost out.
        while (progress) {
            progress = false;
            // A variable fixed to a type puts that type below its declared
            // bounds, which may name variables still open: `TEvent` fixed
            // to `SomeEvent` below `Event<TService>` makes `TService` at
            // least `SomeService`.
            var vi: usize = 0;
            while (vi < self.vars.items.len) : (vi += 1) {
                const v = &self.vars.items[vi];
                if (v.fixed == .none or v.bounds_applied) continue;
                v.bounds_applied = true;
                const fixed = v.fixed;
                for (try s.arena.dupe(TypeId, v.declared.items)) |db| {
                    const z = try zonk(s, db);
                    if (!self.mentionsOtherUnfixed(z, self.vars.items[vi].id)) continue;
                    var trial = try self.clone();
                    defer trial.deinit();
                    if (try trial.constrain(fixed, z)) {
                        _ = try self.constrain(fixed, z);
                        progress = true;
                    }
                }
            }
            for (self.vars.items) |*v| {
                if (v.fixed != .none or v.foreign) continue;
                if (leave_open and self.keptOpen(v, keep_reach)) continue;
                // Equal to a variable a lambda's body is inferring (`set`'s
                // `K` on a builder's `MutableMap<K, V>`): it is that
                // variable, and what else flows into it flows into that one.
                if (try self.equalForeign(v)) |f| {
                    v.fixed = f;
                    progress = true;
                    continue;
                }
                var lowers: std.ArrayList(TypeId) = .empty;
                var lits: types.IntLit = .{};
                var any_lit = false;
                var pending = false;
                // Below it a nullable type still open (`T2?` of
                // `same("text", lookup())`): whatever that becomes, `v`
                // holds its null.
                var pending_null = false;
                var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
                try seen.put(s.arena, v.id, {});
                for (v.lower.items) |lb| {
                    const z = try zonk(s, lb);
                    if (self.waitsOnOwn(z)) {
                        pending = true;
                        if (s.types.isNullable(z)) pending_null = true;
                        // `v :> w` for an open `w`: what is below `w` is
                        // below `v` too.
                        try self.lowersThrough(z, &lowers, &seen);
                        continue;
                    }
                    switch (s.types.get(z)) {
                        .int_lit => |l| {
                            lits = mergeLits(lits, l);
                            any_lit = true;
                        },
                        else => try lowers.append(s.arena, try self.close(z)),
                    }
                }
                if (any_lit and lowers.items.len == 0 and !pending) {
                    // Only literals: the integral type an upper bound
                    // names, or an enclosing call's to decide.
                    if (try self.literalTarget(v, lits)) |t| {
                        v.fixed = t;
                        progress = true;
                        continue;
                    }
                    if (leave_open and v.upper.items.len == 0 and reaches(reach, v.id)) continue;
                    v.fixed = try intLitDefault(s, lits);
                    progress = true;
                    continue;
                }
                if (any_lit and lowers.items.len != 0) {
                    // Literals join a type they fit as that type (`Byte`
                    // for `1` and a `Byte`), else as their default.
                    const lub = try subtyping.commonSupertype(s, lowers.items);
                    const lit = try s.types.intern(.{ .int_lit = lits });
                    if (!try subtyping.isSubtype(s, lit, lub)) try lowers.append(s.arena, try intLitDefault(s, lits));
                } else if (any_lit) {
                    // Beside a variable still open, the integral type an
                    // upper bound names, else the default: `Holder(4)` for a
                    // `Holder<T>` with `T : Long` holds a `Long`.
                    try lowers.append(s.arena, (try self.literalTarget(v, lits)) orelse try intLitDefault(s, lits));
                }
                if (lowers.items.len != 0) {
                    v.fixed = try subtyping.commonSupertype(s, lowers.items);
                    if (pending_null) v.fixed = try s.types.makeNullable(v.fixed);
                    // A reified variable is not fixed at `Nothing` while an
                    // upper bound gives it a type, as kotlinc has it: `val p:
                    // String? by saved { error("none") }` makes `saved`'s
                    // reified `T` a `String?`, which it serializes.
                    if (isNothing(s, v.fixed) and v.reified) {
                        if (try self.closedUpperMeet(v)) |meet| {
                            if (!isNothing(s, meet) and try subtyping.isSubtype(s, v.fixed, meet)) v.fixed = meet;
                        }
                    }
                    // The join can be coarser than an upper bound every
                    // lower bound fits: `In<Int>` and `In<String>` join to
                    // `In<*>`, which is not below `In<Int & String>`; the
                    // bound is then the type.
                    if (try self.closedUpperMeet(v)) |meet| {
                        if (!try subtyping.isSubtype(s, v.fixed, meet)) {
                            const all_fit = for (lowers.items) |lb| {
                                if (!try subtyping.isSubtype(s, lb, meet)) break false;
                            } else true;
                            if (all_fit) v.fixed = meet;
                        }
                    }
                    // A lower bound that still names open variables fits
                    // below the type fixed: `EnumEntries<E>` beside an
                    // `EnumEntries<NonEmptyEnum>` makes `E` a `NonEmptyEnum`,
                    // and a variable below it is at most that type.
                    if (pending) {
                        const fixed = v.fixed;
                        for (try s.arena.dupe(TypeId, v.lower.items)) |lb| {
                            const z = try zonk(s, lb);
                            if (!self.waitsOnOwn(z)) continue;
                            var trial = try self.clone();
                            defer trial.deinit();
                            if (try trial.constrain(z, fixed)) _ = try self.constrain(z, fixed);
                        }
                    }
                    progress = true;
                    continue;
                }
                if (pending) {
                    // Below it only variables that know of nothing below
                    // them, as two variables equal to each other (`T2` and
                    // `T3` of `passThrough(none())`) do: an upper bound
                    // every one of them names is the type, unless an
                    // enclosing call decides it.
                    // Those variables must know of nothing below them either:
                    // one with a literal or a type below it is fixed first,
                    // and says what `v` is (`Holder(123)` for a `Holder<T>`
                    // with `T : Any` is a `Holder<Int>`, not a `Holder<Any>`).
                    var nothing_seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
                    try nothing_seen.put(s.arena, v.id, {});
                    const only_vars = for (v.lower.items) |lb| {
                        const z = try zonk(s, lb);
                        if (self.varIndex(z) == null) break false;
                        if (!try self.knowsNothingBelow(z, &nothing_seen)) break false;
                    } else true;
                    if (only_vars and (!leave_open or !reaches(reach, v.id))) if (try self.closedUpperMeet(v)) |meet| {
                        v.fixed = meet;
                        progress = true;
                    };
                    continue;
                }
                // Only upper bounds: the most specific type under all of
                // them, the declared bounds included (`T : Any` below an
                // expected `ColorFilter?` is a `ColorFilter`).
                var best: TypeId = .none;
                for (v.upper.items) |ub| {
                    const z = try zonk(s, ub);
                    if (self.waitsOnOwn(z)) continue;
                    best = try self.meetUpper(best, try self.close(z));
                }
                // `V <: W` between two variables is kept on `W` alone, as
                // its lower bound: a fixed `W` is `V`'s upper bound too
                // (`decode<T'>()` passed as `same(Level.LOW, _)`'s `T`).
                if (best == .none and v.lower.items.len == 0) best = try self.impliedUpper(v);
                if (best != .none) {
                    for (v.declared.items) |db| {
                        const z = try zonk(s, db);
                        if (self.waitsOnOwn(z)) continue;
                        best = try self.meetUpper(best, try self.close(z));
                    }
                    v.fixed = best;
                    progress = true;
                }
            }
        }
        for (self.vars.items) |*v| {
            if (v.fixed != .none or v.foreign) continue;
            // A declared bound written over another of the call's type
            // parameters (`T : U`) constrains it once that one is known.
            var bound_by_var = false;
            for (v.declared.items) |db| {
                if (self.mentionsOtherVar(try zonk(s, db), v.id)) bound_by_var = true;
            }
            if (v.lower.items.len == 0 and v.upper.items.len == 0 and !bound_by_var) v.uninferred = true;
            if (leave_open and v.uninferred) continue;
            // Bounded only by its declared bounds over variables still open
            // (`TService : Service<TService, TEvent>` before a lambda gives
            // `TEvent`): nothing is known of it yet.
            if (leave_open and bound_by_var and v.lower.items.len == 0 and v.upper.items.len == 0 and try self.declaredWaitsOnOpen(v)) continue;
            // Only below variables still open (`R <: T` for an open `T :
            // Comparable<T>`): nothing is known of it yet either.
            if (leave_open and v.lower.items.len == 0 and try self.onlyBelowOpen(v) and reaches(reach, v.id)) continue;
            if (leave_open and v.upper.items.len == 0 and self.literalOnly(v) and reaches(reach, v.id)) continue;
            // What flows into it waits on a variable left open: the
            // enclosing call fixes both.
            if (leave_open and try self.waitsOnOpen(v)) continue;
            if (leave_open and self.keptOpen(v, keep_reach)) continue;
            // The declared bound, when it no longer mentions a variable.
            var fixed: TypeId = s.t.any_q;
            for (v.declared.items) |db| {
                const closed = try self.close(try zonk(s, db));
                if (self.hasUnfixed(closed)) continue;
                fixed = closed;
                break;
            }
            v.fixed = fixed;
        }
        var ok = true;
        for (self.vars.items) |v| {
            if (v.foreign) continue;
            if (v.fixed == .none) {
                // Left open: whoever adopts it inherits what is known.
                if (!self.trial and (v.lower.items.len != 0 or v.upper.items.len != 0 or v.declared.items.len != 0)) {
                    try s.open_var_bounds.put(s.arena, v.id, .{ .lower = v.lower.items, .upper = v.upper.items, .declared = v.declared.items });
                }
                continue;
            }
            if (!self.trial) try s.var_solution.put(s.arena, v.id, v.fixed);
            for (v.upper.items) |ub| {
                const closed = try self.close(try zonk(s, ub));
                if (self.hasUnfixed(closed)) continue;
                if (!try self.fits(v.fixed, closed)) ok = false;
            }
            for (v.declared.items) |db| {
                const closed = try self.close(try zonk(s, db));
                if (self.hasUnfixed(closed)) continue;
                if (!try self.fits(v.fixed, closed)) ok = false;
            }
        }
        return ok;
    }

    /// A foreign variable both below and above `v`, which `v` equals. That
    /// it is above is kept on either side: as `v`'s upper bound, or as a
    /// lower bound of the foreign variable naming `v`.
    fn equalForeign(self: *const System, v: *const Var) Allocator.Error!?TypeId {
        for (v.lower.items) |lb| {
            const z = try zonk(self.s, lb);
            const i = self.varIndex(z) orelse continue;
            const f = &self.vars.items[i];
            if (!f.foreign) continue;
            for (v.upper.items) |ub| {
                if ((try zonk(self.s, ub)) == z) return z;
            }
            for (f.lower.items) |flb| {
                if ((try zonk(self.s, flb)) == v.ty) return z;
            }
        }
        return null;
    }

    /// Whether a fixed type satisfies a bound. A variable a lambda's body
    /// is inferring stands for a type still to come: the bound is a
    /// constraint on it (`materialize()` fixed to a builder's `T` and
    /// passed for a `Target` makes `T` at most a `Target`).
    fn fits(self: *System, fixed: TypeId, bound: TypeId) Allocator.Error!bool {
        if (self.mentionsForeign(fixed) or self.mentionsForeign(bound)) return self.constrain(fixed, bound);
        if (try subtyping.isSubtype(self.s, fixed, bound)) return true;
        return capturedFits(self.s, fixed, bound);
    }

    /// Whether `fixed` fits `bound` once its star projections are captured.
    /// A star passed where a type argument is inferred captures an unknown
    /// type, which `constrain` takes at the parameter's bound: `Ser<*>` for
    /// a `Ser<T>` puts `Any?` below `T`. A `Ser<*>` reaching the bound
    /// through a variable (`FlowSer(xs.first())` for `xs: List<Ser<*>>`)
    /// fits the `Ser<T>` that capture fixed.
    fn capturedFits(s: *Sema, fixed: TypeId, bound: TypeId) Allocator.Error!bool {
        const ts = &s.types;
        if (ts.isNullable(fixed) and !try subtyping.admitsNull(s, bound)) return false;
        const bound_nn = try ts.makeNotNull(bound);
        const bc = switch (ts.get(bound_nn)) {
            .class => |c| c,
            else => return false,
        };
        const up = (try subtyping.supertypeWithClass(s, try ts.makeNotNull(fixed), bc.sym)) orelse return false;
        const have = ts.argsOf(up);
        if (have.len != bc.args.len) return false;
        const tps = try headers.classTypeParams(s, bc.sym);
        const args = try s.arena.dupe(types.Arg, have);
        var captured = false;
        for (args, bc.args, 0..) |*h, w, i| {
            if (h.variance != .star or w.variance == .star) continue;
            const cap: TypeId = if (i < tps.len) blk: {
                const bs = try headers.typeParamBounds(s, tps[i]);
                break :blk if (bs.len != 0) bs[0] else s.t.any_q;
            } else s.t.any_q;
            if (!try subtyping.isSubtype(s, cap, w.ty)) return false;
            h.* = w;
            captured = true;
        }
        if (!captured) return false;
        return subtyping.isSubtype(s, try ts.class(bc.sym, args, false), bound_nn);
    }

    fn mentionsForeign(self: *const System, t: TypeId) bool {
        const ts = &self.s.types;
        switch (ts.get(t)) {
            .variable => {
                const i = self.anyVarIndex(t) orelse return false;
                return self.vars.items[i].foreign;
            },
            .class => |c| {
                for (c.args) |a| if (a.variance != .star and self.mentionsForeign(a.ty)) return true;
                return false;
            },
            .intersection => |parts| {
                for (parts) |p| if (self.mentionsForeign(p)) return true;
                return false;
            },
            else => return false,
        }
    }

    /// The variables of this system an enclosing call adopts from `t`: the
    /// ones it mentions and, transitively, the ones their bounds mention.
    fn reachable(self: *const System, t: TypeId) Allocator.Error!std.AutoHashMapUnmanaged(u32, void) {
        const s = self.s;
        var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
        var work: std.ArrayList(TypeId) = .empty;
        try work.append(s.arena, try zonk(s, t));
        while (work.pop()) |cur| {
            switch (s.types.get(cur)) {
                .variable => |v| {
                    if (seen.contains(v.id)) continue;
                    try seen.put(s.arena, v.id, {});
                    const i = self.index.get(v.id) orelse continue;
                    const sv = &self.vars.items[i];
                    for (sv.lower.items) |b| try work.append(s.arena, try zonk(s, b));
                    for (sv.upper.items) |b| try work.append(s.arena, try zonk(s, b));
                },
                .class => |c| for (c.args) |a| {
                    if (a.variance != .star) try work.append(s.arena, a.ty);
                },
                .intersection => |parts| try work.appendSlice(s.arena, parts),
                else => {},
            }
        }
        return seen;
    }

    fn declaredWaitsOnOpen(self: *const System, v: *const Var) Allocator.Error!bool {
        for (v.declared.items) |db| {
            if (self.mentionsOtherUnfixed(try zonk(self.s, db), v.id)) return true;
        }
        return false;
    }

    fn mentionsOtherUnfixed(self: *const System, t: TypeId, id: u32) bool {
        const ts = &self.s.types;
        switch (ts.get(t)) {
            .variable => |v| {
                if (v.id == id) return false;
                const i = self.anyVarIndex(t) orelse return false;
                return self.vars.items[i].fixed == .none;
            },
            .class => |c| {
                for (c.args) |a| if (a.variance != .star and self.mentionsOtherUnfixed(a.ty, id)) return true;
                return false;
            },
            .intersection => |parts| {
                for (parts) |p| if (self.mentionsOtherUnfixed(p, id)) return true;
                return false;
            },
            else => return false,
        }
    }

    fn onlyBelowOpen(self: *const System, v: *const Var) Allocator.Error!bool {
        if (v.upper.items.len == 0) return false;
        for (v.upper.items) |ub| {
            if (!self.hasUnfixed(try zonk(self.s, ub))) return false;
        }
        return true;
    }

    fn waitsOnOpen(self: *const System, v: *const Var) Allocator.Error!bool {
        for (v.lower.items) |lb| {
            if (self.hasUnfixed(try zonk(self.s, lb))) return true;
        }
        return false;
    }

    fn literalOnly(self: *const System, v: *const Var) bool {
        if (v.lower.items.len == 0) return false;
        for (v.lower.items) |lb| {
            if (self.s.types.get(lb) != .int_lit) return false;
        }
        return true;
    }

    /// The integral type an upper bound of `v` asks for that every literal
    /// flowing into it fits.
    fn literalTarget(self: *System, v: *const Var, lits: types.IntLit) Allocator.Error!?TypeId {
        const s = self.s;
        // An upper bound, or the type parameter's declared bound
        // (`Box(4)` for `class Box<T : Long>` is a `Box<Long>`).
        for ([_][]const TypeId{ v.upper.items, v.declared.items }) |bounds| for (bounds) |ub| {
            const z = try self.close(try zonk(s, ub));
            if (self.hasUnfixed(z)) continue;
            const nn = try s.types.makeNotNull(z);
            const lit = try s.types.intern(.{ .int_lit = lits });
            if (try subtyping.isSubtype(s, lit, nn) and isIntegral(s, nn)) return nn;
        };
        return null;
    }

    fn hasUnfixed(self: *const System, t: TypeId) bool {
        const ts = &self.s.types;
        switch (ts.get(t)) {
            .variable => {
                const i = self.anyVarIndex(t) orelse return false;
                return self.vars.items[i].fixed == .none;
            },
            .class => |c| {
                for (c.args) |a| if (a.variance != .star and self.hasUnfixed(a.ty)) return true;
                return false;
            },
            .intersection => |parts| {
                for (parts) |p| if (self.hasUnfixed(p)) return true;
                return false;
            },
            else => return false,
        }
    }

    /// The lower bounds of `t`, an open variable of this system, that name
    /// none, and through the open variables among them theirs: `v :> t`
    /// makes them `v`'s too. A literal is typed by its own variable, whose
    /// upper bounds may ask for another integral type, so it is not taken.
    fn lowersThrough(self: *System, t: TypeId, lowers: *std.ArrayList(TypeId), seen: *std.AutoHashMapUnmanaged(u32, void)) Allocator.Error!void {
        const s = self.s;
        const v = switch (s.types.get(t)) {
            .variable => |v| v,
            else => return,
        };
        const i = self.index.get(v.id) orelse return;
        if ((try seen.getOrPut(s.arena, v.id)).found_existing) return;
        for (self.vars.items[i].lower.items) |lb| {
            const z = try zonk(s, lb);
            if (self.waitsOnOwn(z)) {
                try self.lowersThrough(z, lowers, seen);
                continue;
            }
            if (s.types.get(z) == .int_lit) continue;
            const c = try self.close(z);
            try lowers.append(s.arena, try withVarNullability(&s.types, v, c));
        }
    }

    /// Whether `t`, a variable of this system, has nothing below it but
    /// open variables that have nothing below them.
    fn knowsNothingBelow(self: *System, t: TypeId, seen: *std.AutoHashMapUnmanaged(u32, void)) Allocator.Error!bool {
        const s = self.s;
        const v = switch (s.types.get(t)) {
            .variable => |v| v,
            else => return false,
        };
        const i = self.index.get(v.id) orelse return true;
        if ((try seen.getOrPut(s.arena, v.id)).found_existing) return true;
        for (self.vars.items[i].lower.items) |lb| {
            const z = try zonk(s, lb);
            if (self.varIndex(z) == null or !self.waitsOnOwn(z)) return false;
            if (!try self.knowsNothingBelow(z, seen)) return false;
        }
        return true;
    }

    /// Whether `t` mentions a variable of this system still to be fixed.
    /// A foreign variable, one an enclosing call infers from a lambda's
    /// body, stands as a type of its own here: a bound naming it is known.
    fn waitsOnOwn(self: *const System, t: TypeId) bool {
        const ts = &self.s.types;
        switch (ts.get(t)) {
            .variable => {
                const i = self.anyVarIndex(t) orelse return false;
                const v = self.vars.items[i];
                return v.fixed == .none and !v.foreign;
            },
            .class => |c| {
                for (c.args) |a| if (a.variance != .star and self.waitsOnOwn(a.ty)) return true;
                return false;
            },
            .intersection => |parts| {
                for (parts) |p| if (self.waitsOnOwn(p)) return true;
                return false;
            },
            else => return false,
        }
    }

    /// `t` with each variable this solved system fixed from constraints
    /// replaced by its type; one nothing constrained, fixed only by its
    /// default, stays a variable.
    pub fn closeKnown(self: *const System, t: TypeId) Allocator.Error!TypeId {
        const ts = &self.s.types;
        switch (ts.get(t)) {
            .variable => |v| {
                const i = self.anyVarIndex(t) orelse return t;
                const x = self.vars.items[i];
                if (x.fixed == .none or x.uninferred) return t;
                return withVarNullability(ts, v, x.fixed);
            },
            .class => |c| {
                if (!self.mentionsVar(t)) return t;
                const out = try self.s.arena.alloc(types.Arg, c.args.len);
                for (c.args, out) |a, *o| {
                    o.* = a;
                    if (a.variance != .star) o.ty = try self.closeKnown(a.ty);
                }
                return ts.classAttrs(c.sym, out, c.nullable, c.attrs);
            },
            else => return t,
        }
    }

    /// `t` with every fixed variable replaced by its type.
    pub fn close(self: *System, t: TypeId) Allocator.Error!TypeId {
        if (!self.mentionsVar(t)) return t;
        return self.replaceVars(t, false);
    }

    /// The fixed type of the variable for `tp`, or `.none`.
    pub fn fixedFor(self: *const System, tp: Sym) TypeId {
        for (self.vars.items) |v| if (v.tp == tp) return v.fixed;
        return .none;
    }

    pub fn anyUninferred(self: *const System) bool {
        return self.firstUninferred() != null;
    }

    /// The type parameter of the first variable nothing constrained.
    pub fn firstUninferred(self: *const System) ?Sym {
        for (self.vars.items) |v| if (v.uninferred and v.tp != .none) return v.tp;
        return null;
    }
};

/// Whether an enclosing call can reach variable `id`; with no reach
/// computed, every variable counts.
fn reaches(reach: ?std.AutoHashMapUnmanaged(u32, void), id: u32) bool {
    const r = reach orelse return true;
    return r.contains(id);
}

/// The plain variable `W` of `W & Any`, null for any other type.
fn dnnVar(ts: *types.TypeStore, t: TypeId) ?TypeId {
    return switch (ts.get(t)) {
        .variable => |v| if (v.dnn) ts.intern(.{ .variable = .{ .id = v.id } }) catch null else null,
        else => null,
    };
}

fn mergeLits(a: types.IntLit, b: types.IntLit) types.IntLit {
    // A variable several literals flow into can be what all of them fit.
    const any_a = @as(u8, @bitCast(a)) != 0;
    if (!any_a) return b;
    return @bitCast(@as(u8, @bitCast(a)) & @as(u8, @bitCast(b)));
}

/// Two integer literal types as one: what both fit.
pub fn joinLits(s: *Sema, a: TypeId, b: TypeId) Allocator.Error!TypeId {
    return s.types.intern(.{ .int_lit = mergeLits(s.types.get(a).int_lit, s.types.get(b).int_lit) });
}

pub fn isIntegral(s: *Sema, t: TypeId) bool {
    const c = s.t;
    return t == c.int or t == c.long or t == c.short or t == c.byte or
        t == c.uint or t == c.ulong or t == c.ushort or t == c.ubyte;
}

fn isNothing(s: *Sema, t: TypeId) bool {
    return s.builtins.nothing != .none and s.types.classSym(t) == s.builtins.nothing;
}

/// The types an integer literal can take; `.none` for the ones it cannot.
fn litTypes(s: *Sema, l: types.IntLit) [8]TypeId {
    const c = s.t;
    return .{
        if (l.int) c.int else .none,       if (l.long) c.long else .none,
        if (l.short) c.short else .none,   if (l.byte) c.byte else .none,
        if (l.uint) c.uint else .none,     if (l.ulong) c.ulong else .none,
        if (l.ushort) c.ushort else .none, if (l.ubyte) c.ubyte else .none,
    };
}

/// The type an integer literal takes when nothing expects another: `Int`
/// when it fits, else `Long`.
pub fn intLitDefault(s: *Sema, l: types.IntLit) Allocator.Error!TypeId {
    if (l.int) return s.t.int;
    if (l.long) return s.t.long;
    if (l.uint) return s.t.uint;
    if (l.ulong) return s.t.ulong;
    return s.t.int;
}

/// A value of type `actual` used where `expected` is declared (an
/// assignment, a typed initializer, a return): when either mentions a
/// variable a call is inferring from a lambda's body, the use constrains
/// it in that call's system.
pub fn noteExpected(s: *Sema, actual: TypeId, expected: TypeId) Allocator.Error!void {
    if (actual == .none or expected == .none or s.builder_owners.count() == 0) return;
    var ids: std.ArrayList(u32) = .empty;
    try collectVarIds(s, try zonk(s, actual), &ids);
    try collectVarIds(s, try zonk(s, expected), &ids);
    for (ids.items) |id| {
        const owner = s.builder_owners.get(id) orelse continue;
        _ = try owner.constrain(actual, expected);
        return;
    }
}

/// A receiver whose type is a variable a call is inferring from the lambda
/// being analyzed has no members of its own: the variable is fixed first,
/// to what the lambda's statements so far say of it.
pub fn fixReceiver(s: *Sema, t: TypeId) Allocator.Error!TypeId {
    if (t == .none or s.builder_owners.count() == 0) return t;
    const z = try zonk(s, t);
    const v = switch (s.types.get(z)) {
        .variable => |v| v,
        else => return t,
    };
    const owner = s.builder_owners.get(v.id) orelse return t;
    _ = (try owner.fixEarly(v.id)) orelse return t;
    return zonk(s, z);
}

fn collectVarIds(s: *Sema, t: TypeId, out: *std.ArrayList(u32)) Allocator.Error!void {
    switch (s.types.get(t)) {
        .variable => |v| try out.append(s.arena, v.id),
        .class => |c| for (c.args) |a| {
            if (a.variance != .star) try collectVarIds(s, a.ty, out);
        },
        .intersection => |parts| for (parts) |p| try collectVarIds(s, p, out),
        else => {},
    }
}

fn mentionsId(s: *Sema, t: TypeId, id: u32) bool {
    switch (s.types.get(t)) {
        .variable => |v| return v.id == id,
        .class => |c| {
            for (c.args) |a| if (a.variance != .star and mentionsId(s, a.ty, id)) return true;
            return false;
        },
        .intersection => |parts| {
            for (parts) |p| if (mentionsId(s, p, id)) return true;
            return false;
        },
        else => return false,
    }
}

/// Whether `t` mentions an open variable nothing constrained: a type only
/// the enclosing call can give.
pub fn hasUnboundedVar(s: *Sema, t: TypeId) bool {
    switch (s.types.get(t)) {
        .variable => |v| {
            if (s.var_solution.contains(v.id)) return false;
            const b = s.open_var_bounds.get(v.id) orelse return true;
            return b.lower.len == 0 and b.upper.len == 0;
        },
        .class => |c| {
            for (c.args) |a| if (a.variance != .star and hasUnboundedVar(s, a.ty)) return true;
            return false;
        },
        .intersection => |parts| {
            for (parts) |p| if (hasUnboundedVar(s, p)) return true;
            return false;
        },
        else => return false,
    }
}

/// Whether `t` mentions a variable no system has fixed yet.
pub fn hasOpenVar(s: *Sema, t: TypeId) bool {
    switch (s.types.get(t)) {
        .variable => |v| return !s.var_solution.contains(v.id),
        .class => |c| {
            for (c.args) |a| if (a.variance != .star and hasOpenVar(s, a.ty)) return true;
            return false;
        },
        .intersection => |parts| {
            for (parts) |p| if (hasOpenVar(s, p)) return true;
            return false;
        },
        else => return false,
    }
}

/// An expected type an inner call may use: solved, or `.none`. A variable
/// of the enclosing call's system stays that system's to fix.
pub fn usableExpected(s: *Sema, t: TypeId) Allocator.Error!TypeId {
    if (t == .none) return t;
    const z = try zonk(s, t);
    return if (hasOpenVar(s, z)) .none else z;
}

/// `t`, what variable `v` stands for, with `v`'s nullability: `t?` for
/// `V?`, `t & Any` for `V & Any`.
fn withVarNullability(ts: *types.TypeStore, v: types.Var, t: TypeId) Allocator.Error!TypeId {
    if (v.nullable) return ts.makeNullable(t);
    if (v.dnn) return ts.definitelyNotNull(t);
    return t;
}

/// `t` with every variable some system has fixed replaced by its solution.
pub fn zonk(s: *Sema, t: TypeId) Allocator.Error!TypeId {
    const ts = &s.types;
    switch (ts.get(t)) {
        .variable => |v| {
            const sol = s.var_solution.get(v.id) orelse return t;
            const z = try zonk(s, sol);
            return withVarNullability(ts, v, z);
        },
        .class => |c| {
            if (c.args.len == 0) return t;
            var changed = false;
            const out = try s.arena.alloc(types.Arg, c.args.len);
            for (c.args, out) |a, *o| {
                o.* = a;
                if (a.variance == .star) continue;
                o.ty = try zonk(s, a.ty);
                if (o.ty != a.ty) changed = true;
            }
            if (!changed) return t;
            return ts.classAttrs(c.sym, out, c.nullable, c.attrs);
        },
        .intersection => |parts| {
            var changed = false;
            const out = try s.arena.alloc(TypeId, parts.len);
            for (parts, out) |p, *o| {
                o.* = try zonk(s, p);
                if (o.* != p) changed = true;
            }
            if (!changed) return t;
            return ts.intern(.{ .intersection = out });
        },
        else => return t,
    }
}
