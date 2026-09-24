//! Machine types at the boundaries of a body: each function's parameters
//! and result from its declaration in sema, a field's or a static's from
//! its seed. A function whose parameter layout is not one this derives
//! takes and returns every value boxed, which any caller can produce.

const std = @import("std");
const ir = @import("ir");
const sema = @import("sema");

const ctype = @import("ctype.zig");
const Ty = ctype.Ty;

const Allocator = std.mem.Allocator;
const FuncId = ir.FuncId;
const ClassId = ir.ClassId;
const NativeId = ir.NativeId;
const Sym = sema.Sym;
const TypeId = sema.TypeId;
const Bridge = ir.bridge.Bridge;

/// A compiled function's C signature.
pub const Sig = struct {
    params: []const Ty,
    ret: Ty,
    /// The static class of each parameter, where its type names one.
    param_cls: []const ?ClassId = &.{},
    /// The class the result is an instance of, where the type names one.
    ret_cls: ?ClassId = null,
};

pub const Sigs = struct {
    a: Allocator,
    br: *Bridge,
    s: *sema.Sema,
    m: *ir.Module,
    r: *const ir.Resolved,
    by_func: std.AutoHashMapUnmanaged(u32, Sig) = .empty,
    /// By NativeId: a function bound to it, whose declaration types its result.
    native_func: []FuncId = &.{},
    /// The first symbol the program's files declare. A base loaded from its
    /// image names symbols of the bake, which from here on are this run's.
    program_syms: u32 = std.math.maxInt(u32),

    pub fn init(a: Allocator, br: *Bridge) Allocator.Error!Sigs {
        const r = br.m.resolved.?;
        var self: Sigs = .{ .a = a, .br = br, .s = br.s, .m = br.m, .r = r };
        var i: u32 = 1;
        while (i < br.s.syms.count()) : (i += 1) {
            const file = br.s.syms.get(Sym.from(i)).file;
            const fc = br.s.fileOf(file) orelse continue;
            if (fc.origin == .program) {
                self.program_syms = i;
                break;
            }
        }
        self.native_func = try a.alloc(FuncId, r.natives.len);
        @memset(self.native_func, FuncId.from(ir.NO_FUNC));
        for (r.func_native, 0..) |n, f| {
            if (n == .none or n.int() >= r.natives.len) continue;
            if (self.native_func[n.int()].int() == ir.NO_FUNC) self.native_func[n.int()] = FuncId.from(@intCast(f));
        }
        return self;
    }

    /// Whether sema's symbol `sym` is one this analysis made: a base loaded
    /// from its image keeps the symbols of the bake, which past its prefix
    /// are this run's program symbols.
    pub fn symValid(self: *const Sigs, f: FuncId, sym: Sym) bool {
        if (sym == .none or sym.int() >= self.s.syms.count()) return false;
        const base_funcs: u32 = if (self.br.layer_ends.len != 0) self.br.layer_ends[0].funcs else 0;
        if (f.int() < base_funcs) return sym.int() < self.program_syms;
        return true;
    }

    /// The machine type a value of sema type `t` lives in.
    pub fn tyOfType(self: *const Sigs, t: TypeId) Ty {
        if (t == .none) return .object;
        const ty = self.s.types.get(t);
        const c = switch (ty) {
            .class => |c| c,
            else => return .object,
        };
        if (c.nullable) return .object;
        const bi = &self.s.builtins;
        const sym = c.sym;
        if (sym == .none) return .object;
        if (sym == bi.int) return .i32;
        if (sym == bi.long) return .i64;
        if (sym == bi.double) return .f64;
        if (sym == bi.float) return .f32;
        if (sym == bi.boolean) return .boolean;
        if (sym == bi.char) return .char;
        if (sym == bi.short) return .short;
        if (sym == bi.byte) return .byte;
        if (sym == bi.uint) return .u32;
        if (sym == bi.ulong) return .u64;
        if (sym == bi.ushort) return .u16;
        if (sym == bi.ubyte) return .u8;
        if (sym == bi.unit) return .unit;
        return .object;
    }

    /// The class sema type `t` names, when it names one the bridge made.
    pub fn classOfType(self: *const Sigs, t: TypeId) ?ClassId {
        if (t == .none) return null;
        const sym = self.s.types.classSym(t);
        if (sym == .none) return null;
        return self.br.classOfOpt(sym);
    }

    /// The signature of `f`, derived once.
    pub fn of(self: *Sigs, f: FuncId) Allocator.Error!Sig {
        if (self.by_func.get(f.int())) |sg| return sg;
        const sg = try self.derive(f);
        try self.by_func.put(self.a, f.int(), sg);
        return sg;
    }

    /// Every value boxed: what a body whose declaration this cannot read
    /// takes and returns.
    fn boxed(self: *Sigs, n: usize) Allocator.Error!Sig {
        const ps = try self.a.alloc(Ty, n);
        @memset(ps, .object);
        return .{ .params = ps, .ret = .object };
    }

    fn derive(self: *Sigs, f: FuncId) Allocator.Error!Sig {
        const func = self.m.funcById(f) orelse return self.boxed(0);
        const n = func.params.len;
        if (func.is_suspend) return self.boxed(n);
        if (f.int() >= self.br.origin.len) return self.boxed(n);
        var types: std.ArrayList(TypeId) = .empty;
        var ret: TypeId = .none;
        var ret_obj = false;
        const s = self.s;
        switch (self.br.origin[f.int()]) {
            .decl => |sym| {
                if (!self.symValid(f, sym)) return self.boxed(n);
                try sema.headers.functionHeader(s, sym);
                switch (s.syms.kind(sym)) {
                    .constructor => {
                        const cls = s.syms.owner(sym);
                        const ci = s.syms.classInfo(cls);
                        // An inner class's outer instance, an enum's name and
                        // ordinal and a local class's captures lead the values.
                        if (s.syms.flags(cls).inner or ci.kind == .enum_class or ci.kind == .enum_entry) return self.boxed(n);
                        if (self.br.classOfOpt(cls)) |c| {
                            if (c.int() < self.br.class_captures.len and self.br.class_captures[c.int()].len != 0) return self.boxed(n);
                        }
                        const info = s.syms.functionInfo(sym);
                        if (info.context_params.len != 0) return self.boxed(n);
                        try types.append(self.a, .none);
                        for (info.params) |p| try types.append(self.a, try self.valueParamType(p));
                        ret_obj = true;
                    },
                    .function => {
                        const info = s.syms.functionInfo(sym);
                        if (s.syms.flags(sym).composable) return self.boxed(n);
                        if (hasThis(s, sym)) try types.append(self.a, .none);
                        for (info.context_params) |cp| try types.append(self.a, try sema.headers.paramType(s, cp));
                        if (info.receiver != .none) try types.append(self.a, info.receiver);
                        for (info.params) |p| try types.append(self.a, try self.valueParamType(p));
                        for (info.type_params) |tp| {
                            if (s.syms.flags(tp).reified) try types.append(self.a, .none);
                        }
                        ret = try sema.headers.returnType(s, sym);
                    },
                    else => return self.boxed(n),
                }
            },
            .getter, .setter => |prop| {
                if (!self.symValid(f, prop)) return self.boxed(n);
                try sema.headers.propertyHeader(s, prop);
                if (s.syms.flags(prop).composable) return self.boxed(n);
                const info = s.syms.propertyInfo(prop);
                if (hasThis(s, prop)) try types.append(self.a, .none);
                for (info.context_params) |cp| try types.append(self.a, try sema.headers.paramType(s, cp));
                if (info.receiver != .none) try types.append(self.a, info.receiver);
                const pt = try sema.headers.propertyType(s, prop);
                if (self.br.origin[f.int()] == .setter) {
                    try types.append(self.a, pt);
                    ret = s.t.unit;
                } else ret = pt;
            },
            else => return self.boxed(n),
        }
        if (types.items.len != n) return self.boxed(n);
        const ps = try self.a.alloc(Ty, n);
        const pc = try self.a.alloc(?ClassId, n);
        for (types.items, ps, pc) |t, *p, *c| {
            p.* = self.tyOfType(t);
            c.* = self.classOfType(t);
        }
        // Parameter 0 of a member is the instance of its class.
        if (n != 0 and types.items[0] == .none) {
            ps[0] = .object;
            pc[0] = self.thisClass(f);
        }
        if (ret_obj) return .{ .params = ps, .ret = .object, .param_cls = pc, .ret_cls = self.thisClass(f) };
        return .{ .params = ps, .ret = self.tyOfType(ret), .param_cls = pc, .ret_cls = self.classOfType(ret) };
    }

    /// A value parameter's type as the body holds it: a vararg is its array.
    fn valueParamType(self: *Sigs, p: Sym) Allocator.Error!TypeId {
        if (self.s.syms.flags(p).vararg) return .none;
        return sema.headers.paramType(self.s, p);
    }

    /// The class whose member `f` is.
    fn thisClass(self: *Sigs, f: FuncId) ?ClassId {
        const sym: Sym = switch (self.br.origin[f.int()]) {
            .decl, .getter, .setter => |x| x,
            else => return null,
        };
        const owner = self.s.syms.owner(sym);
        if (owner == .none or self.s.syms.kind(owner) != .class) return null;
        return self.br.classOfOpt(owner);
    }

    /// The machine type a native answers in.
    pub fn nativeRet(self: *Sigs, n: NativeId) Allocator.Error!Ty {
        if (n.int() >= self.native_func.len) return .object;
        const f = self.native_func[n.int()];
        if (f.int() == ir.NO_FUNC) return .object;
        return (try self.of(f)).ret;
    }

    /// The machine type of field `slot` of instances of `c`.
    pub fn fieldTy(self: *const Sigs, c: ClassId, slot: u32) Ty {
        if (c.int() >= self.r.classes.len) return .object;
        const seeds = self.r.classes[c.int()].seeds;
        if (slot >= seeds.len) return .object;
        return seedTy(seeds[slot]);
    }

    pub fn staticTy(self: *const Sigs, st: ir.StaticId) Ty {
        if (st.int() >= self.r.statics.len) return .object;
        return seedTy(self.r.statics[st.int()].seed);
    }
};

/// A slot seeded with a primitive's zero holds that primitive.
pub fn seedTy(seed: ir.SlotSeed) Ty {
    return switch (seed) {
        .null_ref => .object,
        .int => .i32,
        .long => .i64,
        .short => .short,
        .byte => .byte,
        .float => .f32,
        .double => .f64,
        .boolean => .boolean,
        .char => .char,
    };
}

/// Whether `f` (a function, constructor or property) takes an instance as
/// parameter 0, as lowering lays it out.
fn hasThis(s: *sema.Sema, f: Sym) bool {
    if (s.syms.kind(f) == .constructor) return true;
    const owner = s.syms.owner(f);
    if (owner == .none or s.syms.kind(owner) != .class) return false;
    return !s.syms.flags(f).static;
}
