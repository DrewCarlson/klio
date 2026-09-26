//! Declaration collection: one symbol per declaration in every file, indexed
//! by its package or class. Nothing here resolves a type; the header pass
//! does that on demand.

const std = @import("std");
const ast = @import("ast");

const sema_mod = @import("sema.zig");
const symbols = @import("symbols.zig");
const types = @import("types.zig");
const names_mod = @import("names.zig");
const census_mod = @import("census.zig");

const Allocator = std.mem.Allocator;
const Sema = sema_mod.Sema;
const Sym = symbols.Sym;
const Symbol = symbols.Symbol;
const Flags = symbols.Flags;
const Name = names_mod.Name;
const wk = names_mod.wk;

pub fn visibility(v: ast.Visibility) symbols.Visibility {
    return switch (v) {
        .Public => .public,
        .Internal => .internal,
        .Protected => .protected,
        .Private => .private,
    };
}

/// The package symbol for a dotted path, creating each segment's package.
pub fn packageFor(s: *Sema, path: []const ast.Ident) Allocator.Error!Sym {
    if (s.syms.root_package == .none) {
        s.syms.root_package = try s.syms.addPackage(.empty, .empty, .none);
    }
    var cur = s.syms.root_package;
    var fqn: std.ArrayList(u8) = .empty;
    for (path) |seg| {
        if (fqn.items.len != 0) try fqn.append(s.arena, '.');
        try fqn.appendSlice(s.arena, seg.name);
        const simple = try s.names.intern(seg.name);
        const pinfo = s.syms.packageInfo(cur);
        if (pinfo.subpackages.get(simple)) |next| {
            cur = next;
            continue;
        }
        cur = try s.syms.addPackage(simple, try s.names.intern(fqn.items), cur);
    }
    return cur;
}

pub fn packageFqnStr(s: *Sema, pkg: Sym) []const u8 {
    return s.str(s.syms.packageInfo(pkg).fqn);
}

const Ctx = struct {
    s: *Sema,
    file: u32,
    /// Dotted FQN prefix of the enclosing class, or the package's.
    prefix: []const u8,
    /// Declared in a body: not reachable by qualified name.
    local: bool = false,
};

fn join(s: *Sema, prefix: []const u8, simple: []const u8) Allocator.Error![]const u8 {
    if (prefix.len == 0) return s.arena.dupe(u8, simple);
    return std.fmt.allocPrint(s.arena, "{s}.{s}", .{ prefix, simple });
}

pub fn collectFile(s: *Sema, f: sema_mod.SourceFile) Allocator.Error!void {
    const pkg_path: []const ast.Ident = if (f.ast.package) |p| p.path else &.{};
    const pkg = try packageFor(s, pkg_path);
    const file_index: u32 = @intCast(s.files.items.len);
    try s.files.append(s.arena, .{ .ast = f.ast, .path = f.path, .origin = f.origin, .generated = f.generated, .package = pkg });
    const ctx = Ctx{ .s = s, .file = file_index, .prefix = packageFqnStr(s, pkg) };
    for (f.ast.decls) |*d| try collectDecl(ctx, d, pkg, .top_level);
    // An import alias binds a name the way a declaration does; interned
    // now, a lookup of it by name succeeds before the imports resolve.
    for (f.ast.imports) |imp| {
        if (imp.alias) |a| _ = try s.names.intern(a.name);
    }
}

const Place = enum { top_level, member, interface_member };

/// The package or class a declaration is indexed under. Looked up at
/// insertion time: collecting a nested class grows the class table, so a
/// pointer taken before it would dangle.
const Container = struct {
    sym: Sym,

    fn index(self: Container, s: *Sema) *symbols.NameIndex {
        return switch (s.syms.kind(self.sym)) {
            .package => &s.syms.packageInfo(self.sym).members,
            .class => &s.syms.classInfo(self.sym).members,
            else => unreachable,
        };
    }
};

fn collectDecl(ctx: Ctx, d: *const ast.Decl, owner: Sym, place: Place) Allocator.Error!void {
    const sym = switch (d.*) {
        .Function => |*f| try collectFunction(ctx, f, owner, place),
        .Property => |p| try collectProperty(ctx, p, owner, place),
        .Class => |*c| try collectClass(ctx, c, owner),
        .Object => |*o| try collectObject(ctx, o, owner),
        .TypeAlias => |*ta| try collectTypeAlias(ctx, ta, owner),
    };
    const c = Container{ .sym = owner };
    try ctx.s.syms.indexMember(c.index(ctx.s), ctx.s.syms.name(sym), sym);
}

fn typeParams(ctx: Ctx, tps: []const ast.TypeParam, owner: Sym) Allocator.Error![]const Sym {
    if (tps.len == 0) return &.{};
    const out = try ctx.s.arena.alloc(Sym, tps.len);
    for (tps, out, 0..) |*tp, *o, i| {
        o.* = try ctx.s.syms.addTypeParam(.{
            .kind = .type_param,
            .name = try ctx.s.names.intern(tp.name.name),
            .owner = owner,
            .file = ctx.file,
            .flags = .{ .reified = tp.is_reified },
            .decl = .{ .type_param = tp },
            .detail = 0,
        }, .{
            .index = @intCast(i),
            .variance = switch (tp.variance) {
                .Invariant => .inv,
                .Out => .out,
                .In => .in,
            },
        });
    }
    return out;
}

fn valueParams(ctx: Ctx, ps: []const ast.Param, owner: Sym) Allocator.Error![]const Sym {
    if (ps.len == 0) return &.{};
    const out = try ctx.s.arena.alloc(Sym, ps.len);
    for (ps, out, 0..) |*p, *o, i| {
        o.* = try ctx.s.syms.addParam(.{
            .kind = .value_param,
            .name = try ctx.s.names.intern(p.name.name),
            .owner = owner,
            .file = ctx.file,
            .flags = .{ .vararg = p.is_vararg, .crossinline = p.is_crossinline, .no_inline = p.is_noinline, .has_default = p.default != null },
            .decl = .{ .param = p },
            .detail = 0,
        }, .{ .index = @intCast(i) });
    }
    return out;
}

fn contextParams(ctx: Ctx, cps: []const ast.ContextParam, owner: Sym) Allocator.Error![]const Sym {
    if (cps.len == 0) return &.{};
    const out = try ctx.s.arena.alloc(Sym, cps.len);
    for (cps, out, 0..) |*cp, *o, i| {
        o.* = try ctx.s.syms.addParam(.{
            .kind = .value_param,
            .name = try ctx.s.names.intern(cp.name.name),
            .owner = owner,
            .file = ctx.file,
            .flags = .{},
            .decl = .{ .context_param = cp },
            .detail = 0,
        }, .{ .index = @intCast(i) });
    }
    return out;
}

fn memberModality(place: Place, is_abstract: bool, is_open: bool, is_override: bool, is_final: bool, has_body: bool) symbols.Modality {
    if (is_abstract) return .abstract;
    if (place == .interface_member) return if (has_body) .open else .abstract;
    if (is_final) return .final;
    if (is_open) return .open;
    if (is_override) return .open;
    return .final;
}

fn collectFunction(ctx: Ctx, f: *const ast.Function, owner: Sym, place: Place) Allocator.Error!Sym {
    const s = ctx.s;
    const sym = try s.syms.addFunction(.{
        .kind = .function,
        .name = try s.names.intern(f.name.name),
        .owner = owner,
        .file = ctx.file,
        .flags = .{
            .visibility = visibility(f.visibility),
            .modality = if (place == .top_level) .final else memberModality(place, f.is_abstract, f.is_open, f.is_override, f.is_final, f.body != null),
            .expect = f.is_expect,
            .actual = f.is_actual,
            .inline_ = f.is_inline,
            .suspend_ = f.is_suspend,
            .operator = f.is_operator,
            .infix = f.is_infix,
            .override = f.is_override,
            .tailrec = f.is_tailrec,
            .has_body = f.body != null,
            .external = f.is_external or hasModifierAnnotation(f.annotations, "external"),
        },
        .decl = .{ .function = f },
        .detail = 0,
    }, .{});
    const tps = try typeParams(ctx, f.type_params, sym);
    const params = try valueParams(ctx, f.params, sym);
    const cps = try contextParams(ctx, f.context_params, sym);
    const info = s.syms.functionInfo(sym);
    info.type_params = tps;
    info.params = params;
    info.context_params = cps;
    return sym;
}

fn hasModifierAnnotation(anns: []const ast.Annotation, simple: []const u8) bool {
    for (anns) |a| {
        if (a.path.len != 0 and std.mem.eql(u8, a.path[a.path.len - 1].name, simple)) return true;
    }
    return false;
}

fn collectProperty(ctx: Ctx, p: *const ast.Property, owner: Sym, place: Place) Allocator.Error!Sym {
    const s = ctx.s;
    const has_body = p.getter != null or p.init != null or p.delegate != null;
    const sym = try s.syms.addProperty(.{
        .kind = .property,
        .name = try s.names.intern(p.name.name),
        .owner = owner,
        .file = ctx.file,
        .flags = .{
            .visibility = visibility(p.visibility),
            .modality = if (place == .top_level) .final else memberModality(place, p.is_abstract, p.is_open, p.is_override, p.is_final, has_body),
            .expect = p.is_expect,
            .actual = p.is_actual,
            .inline_ = p.is_inline,
            .override = p.is_override,
            .const_ = p.is_const,
            .lateinit = p.is_lateinit,
            .mutable = p.mutable,
            .has_body = has_body,
        },
        .decl = .{ .property = p },
        .detail = 0,
    }, .{ .has_delegate = p.delegate != null });
    const tps = try typeParams(ctx, p.type_params, sym);
    const cps = try contextParams(ctx, p.context_params, sym);
    const info = s.syms.propertyInfo(sym);
    info.type_params = tps;
    info.context_params = cps;
    return sym;
}

fn classKind(c: *const ast.Class) symbols.ClassKind {
    if (c.is_companion) return .companion;
    if (c.is_interface) return .interface;
    if (c.is_annotation) return .annotation;
    if (c.is_enum and c.name.name.len > 0 and c.name.name[0] == '$') return .enum_entry;
    if (c.is_enum) return .enum_class;
    return .class;
}

fn classModality(c: *const ast.Class) symbols.Modality {
    if (c.is_interface) return .abstract;
    if (c.is_sealed) return .sealed;
    if (c.is_abstract) return .abstract;
    if (c.is_open) return .open;
    return .final;
}

fn collectClass(ctx: Ctx, c: *const ast.Class, owner: Sym) Allocator.Error!Sym {
    const s = ctx.s;
    const fqn_str = try join(s, ctx.prefix, c.name.name);
    const fqn = try s.names.intern(fqn_str);
    const kind = classKind(c);
    const sym = try s.syms.addClass(.{
        .kind = .class,
        .name = try s.names.intern(c.name.name),
        .owner = owner,
        .file = ctx.file,
        .flags = .{
            .visibility = visibility(c.visibility),
            .modality = classModality(c),
            .expect = c.is_expect,
            .actual = c.is_actual,
            .external = c.is_external,
            .data = c.is_data,
            .inner = c.is_inner,
            .value = c.is_value,
            .fun_iface = c.is_fun_interface,
        },
        .decl = .{ .class = c },
        .detail = 0,
    }, .{ .kind = kind, .fqn = fqn });
    if (!ctx.local) try registerFqn(s, fqn, sym);
    const inner = Ctx{ .s = s, .file = ctx.file, .prefix = fqn_str, .local = ctx.local };
    const tps = try typeParams(ctx, c.type_params, sym);
    s.syms.classInfo(sym).type_params = tps;

    const place: Place = if (c.is_interface) .interface_member else .member;
    // Constructors: the primary (explicit, or implicit when the class
    // declares no constructor at all), then each secondary.
    const x = c.x();
    const wants_primary = c.has_primary_ctor or (x.secondary_ctors.len == 0 and kind != .interface);
    if (wants_primary and kind != .interface) {
        const ctor = try s.syms.addFunction(.{
            .kind = .constructor,
            .name = wk.init,
            .owner = sym,
            .file = ctx.file,
            .flags = .{
                .visibility = if (c.primary_ctor_visibility) |v| visibility(v) else if (kind == .enum_class or c.is_sealed) .private else .public,
                .synthetic = !c.has_primary_ctor,
                .has_body = true,
            },
            .decl = .{ .class = c },
            .detail = 0,
        }, .{});
        try indexClassMember(s, sym, wk.init, ctor);
        s.syms.classInfo(sym).primary_ctor = ctor;
        if (c.primary_params.len != 0) {
            const params = try s.arena.alloc(Sym, c.primary_params.len);
            for (c.primary_params, params, 0..) |*cp, *o, i| {
                o.* = try s.syms.addParam(.{
                    .kind = .value_param,
                    .name = try s.names.intern(cp.name.name),
                    .owner = ctor,
                    .file = ctx.file,
                    .flags = .{ .vararg = cp.is_vararg, .has_default = cp.default != null },
                    .decl = .{ .class_param = cp },
                    .detail = 0,
                }, .{ .index = @intCast(i) });
                if (cp.property) |mutable| {
                    const prop = try s.syms.addProperty(.{
                        .kind = .property,
                        .name = try s.names.intern(cp.name.name),
                        .owner = sym,
                        .file = ctx.file,
                        .flags = .{
                            .visibility = visibility(cp.visibility),
                            .modality = if (cp.is_final) .final else if (cp.is_open or cp.is_override) .open else .final,
                            .mutable = mutable,
                            .override = cp.is_override,
                            .has_body = true,
                        },
                        .decl = .{ .class_param = cp },
                        .detail = 0,
                    }, .{ .from_ctor = true });
                    try indexClassMember(s, sym, s.syms.name(prop), prop);
                }
            }
            s.syms.functionInfo(ctor).params = params;
        }
    }
    for (x.secondary_ctors) |*sc| {
        const ctor = try s.syms.addFunction(.{
            .kind = .constructor,
            .name = wk.init,
            .owner = sym,
            .file = ctx.file,
            .flags = .{ .visibility = visibility(sc.visibility), .has_body = true },
            .decl = .{ .secondary_ctor = sc },
            .detail = 0,
        }, .{});
        const params = try valueParams(ctx, sc.params, ctor);
        s.syms.functionInfo(ctor).params = params;
        try indexClassMember(s, sym, wk.init, ctor);
    }

    for (c.members) |*m| {
        try collectDecl(inner, m, sym, place);
        if (m.* == .Class and m.Class.is_companion) {
            const members_list = symbols.Symbols.members(&s.syms.classInfo(sym).members, try s.names.intern(m.Class.name.name));
            if (members_list.len != 0) s.syms.classInfo(sym).companion = members_list[members_list.len - 1];
        }
    }

    if (x.enum_entries.len != 0) {
        const entries = try s.arena.alloc(Sym, x.enum_entries.len);
        for (x.enum_entries, entries, 0..) |*e, *o, i| {
            o.* = try s.syms.addEntry(.{
                .kind = .enum_entry,
                .name = try s.names.intern(e.name.name),
                .owner = sym,
                .file = ctx.file,
                .flags = .{},
                .decl = .{ .enum_entry = e },
                .detail = 0,
            }, .{ .enum_class = sym, .ordinal = @intCast(i) });
            try indexClassMember(s, sym, s.syms.name(o.*), o.*);
            if (e.body_members.len != 0) {
                const body_name = try std.fmt.allocPrint(s.arena, "${s}", .{e.name.name});
                const nested = symbols.Symbols.members(&s.syms.classInfo(sym).members, try s.names.intern(body_name));
                if (nested.len != 0) s.syms.entryInfo(o.*).body_class = nested[0];
            }
        }
        s.syms.classInfo(sym).enum_entries = entries;
    }
    return sym;
}

fn indexClassMember(s: *Sema, class: Sym, n: Name, member: Sym) Allocator.Error!void {
    try s.syms.indexMember(&s.syms.classInfo(class).members, n, member);
}

fn collectObject(ctx: Ctx, o: *const ast.ObjectDecl, owner: Sym) Allocator.Error!Sym {
    const s = ctx.s;
    const fqn_str = try join(s, ctx.prefix, o.name.name);
    const fqn = try s.names.intern(fqn_str);
    const sym = try s.syms.addClass(.{
        .kind = .class,
        .name = try s.names.intern(o.name.name),
        .owner = owner,
        .file = ctx.file,
        .flags = .{
            .visibility = visibility(o.visibility),
            .expect = o.is_expect,
            .actual = o.is_actual,
            .data = o.is_data,
        },
        .decl = .{ .object = o },
        .detail = 0,
    }, .{ .kind = .object, .fqn = fqn });
    if (!ctx.local) try registerFqn(s, fqn, sym);
    const ctor = try s.syms.addFunction(.{
        .kind = .constructor,
        .name = wk.init,
        .owner = sym,
        .file = ctx.file,
        .flags = .{ .visibility = .private, .synthetic = true, .has_body = true },
        .decl = .{ .object = o },
        .detail = 0,
    }, .{});
    try indexClassMember(s, sym, wk.init, ctor);
    s.syms.classInfo(sym).primary_ctor = ctor;
    const inner = Ctx{ .s = s, .file = ctx.file, .prefix = fqn_str, .local = ctx.local };
    for (o.members) |*m| try collectDecl(inner, m, sym, .member);
    return sym;
}

/// A class or object declared in a body: owned by the enclosing function,
/// reachable only through the body's scope.
pub fn collectLocalClass(s: *Sema, file: u32, d: *const ast.Decl, owner: Sym) Allocator.Error!Sym {
    const ctx = Ctx{ .s = s, .file = file, .prefix = "<local>", .local = true };
    const sym = switch (d.*) {
        .Class => |*c| try collectClass(ctx, c, owner),
        .Object => |*o| try collectObject(ctx, o, owner),
        else => unreachable,
    };
    try synthesizeMembers(s, sym);
    return sym;
}

/// An object expression's anonymous class.
pub fn collectObjectLiteral(s: *Sema, file: u32, o: *const ast.ObjectLiteral, owner: Sym) Allocator.Error!Sym {
    const sym = try s.syms.addClass(.{
        .kind = .class,
        .name = wk.anonymous,
        .owner = owner,
        .file = file,
        .flags = .{},
        .decl = .{ .object_literal = o },
        .detail = 0,
    }, .{ .kind = .anonymous, .fqn = wk.anonymous });
    const ctor = try s.syms.addFunction(.{
        .kind = .constructor,
        .name = wk.init,
        .owner = sym,
        .file = file,
        .flags = .{ .visibility = .private, .synthetic = true, .has_body = true },
        .decl = .{ .object_literal = o },
        .detail = 0,
    }, .{});
    try indexClassMember(s, sym, wk.init, ctor);
    s.syms.classInfo(sym).primary_ctor = ctor;
    const inner = Ctx{ .s = s, .file = file, .prefix = "<anonymous>", .local = true };
    for (o.members) |*m| try collectDecl(inner, m, sym, .member);
    try synthesizeDelegation(s, sym);
    return sym;
}

/// Members the language declares for a class: an enum class's static
/// `values()`, `valueOf(String)` and `entries`; a data class's
/// `componentN()` per constructor property and `copy(...)`.
pub fn synthesizeMembers(s: *Sema, cls: Sym) Allocator.Error!void {
    const info = s.syms.classInfo(cls);
    const file = s.syms.get(cls).file;
    if (info.kind == .enum_class) {
        const self_t = try headersSelf(s, cls);
        if (s.builtins.array != .none) {
            const arr = try s.types.class(s.builtins.array, &.{.{ .variance = .inv, .ty = self_t }}, false);
            const v = try synthFunction(s, cls, file, wk.values, &.{}, arr, .{ .static = true });
            s.syms.functionInfo(v).synth = .enum_values;
        }
        const vo = try synthFunction(s, cls, file, wk.valueOf, &.{.{ .name = wk.value, .ty = s.t.string }}, self_t, .{ .static = true });
        s.syms.functionInfo(vo).synth = .enum_value_of;
        const entries_cls = s.classByFqn("kotlin.enums.EnumEntries");
        if (entries_cls != .none) {
            const et = try s.types.class(entries_cls, &.{.{ .variance = .inv, .ty = self_t }}, false);
            const p = try s.syms.addProperty(.{
                .kind = .property,
                .name = wk.entries,
                .owner = cls,
                .file = file,
                .flags = .{ .synthetic = true, .static = true },
                .decl = .none,
                .detail = 0,
            }, .{ .ty = et, .state = .done, .body_done = true });
            try indexClassMember(s, cls, wk.entries, p);
        }
    }
    // A data class, data object or value class gets `equals`, `hashCode`
    // and `toString` of its own unless it declares them or a superclass
    // makes them final.
    if (s.syms.flags(cls).data or s.syms.flags(cls).value) {
        const any_q = s.t.any_q;
        if (symbols.Symbols.members(&s.syms.classInfo(cls).members, wk.equals).len == 0 and !try inheritsFinal(s, cls, wk.equals, 1)) {
            const f = try synthFunction(s, cls, file, wk.equals, &.{.{ .name = try s.names.intern("other"), .ty = any_q }}, s.t.boolean, .{ .override = true, .operator = true, .modality = .open });
            s.syms.functionInfo(f).synth = .data_equals;
        }
        if (symbols.Symbols.members(&s.syms.classInfo(cls).members, wk.hashCode).len == 0 and !try inheritsFinal(s, cls, wk.hashCode, 0)) {
            const f = try synthFunction(s, cls, file, wk.hashCode, &.{}, s.t.int, .{ .override = true, .modality = .open });
            s.syms.functionInfo(f).synth = .data_hash_code;
        }
        if (symbols.Symbols.members(&s.syms.classInfo(cls).members, wk.toString).len == 0 and !try inheritsFinal(s, cls, wk.toString, 0)) {
            const f = try synthFunction(s, cls, file, wk.toString, &.{}, s.t.string, .{ .override = true, .modality = .open });
            s.syms.functionInfo(f).synth = .data_to_string;
        }
    }
    // An annotation instance compares, hashes and renders by its
    // properties.
    if (info.kind == .annotation) {
        const f_eq = try synthFunction(s, cls, file, wk.equals, &.{.{ .name = try s.names.intern("other"), .ty = s.t.any_q }}, s.t.boolean, .{ .override = true, .operator = true, .modality = .open });
        s.syms.functionInfo(f_eq).synth = .annotation_equals;
        const f_hash = try synthFunction(s, cls, file, wk.hashCode, &.{}, s.t.int, .{ .override = true, .modality = .open });
        s.syms.functionInfo(f_hash).synth = .annotation_hash_code;
        const f_str = try synthFunction(s, cls, file, wk.toString, &.{}, s.t.string, .{ .override = true, .modality = .open });
        s.syms.functionInfo(f_str).synth = .annotation_to_string;
    }
    try synthesizeDelegation(s, cls);
    // A data object has no `copy` and no `componentN`: `data object A {
    // fun copy() = "O" }` declares the only `copy`.
    if (s.syms.flags(cls).data and info.kind != .object and info.primary_ctor != .none) {
        const self_t = try headersSelf(s, cls);
        const ctor_params = s.syms.functionInfo(info.primary_ctor).params;
        var copy_params: std.ArrayList(SynthParam) = .empty;
        var n: usize = 0;
        for (ctor_params) |p| {
            const decl = s.syms.get(p).decl;
            if (decl != .class_param) continue;
            const t = try headersParam(s, p);
            try copy_params.append(s.arena, .{ .name = s.syms.name(p), .ty = t, .has_default = true, .default_prop = ctorProperty(s, cls, p) });
            if (decl.class_param.property == null) continue;
            n += 1;
            const comp = try synthFunction(s, cls, file, try s.names.component(n), &.{}, t, .{ .operator = true });
            s.syms.functionInfo(comp).synth = .data_component;
            s.syms.functionInfo(comp).component = @intCast(n);
        }
        const copy = try synthFunction(s, cls, file, wk.copy, copy_params.items, self_t, .{});
        s.syms.functionInfo(copy).synth = .data_copy;
    }
}

/// The members a class gets from `: I by d`: each member of `I` (not of
/// `Any`) the class does not declare itself, as a synthetic override whose
/// signature is `I`'s as the class sees it, forwarding to the delegate.
/// Whether a superclass of `cls` makes its `Any` member `n` (taking
/// `arity` parameters) final: a data class then inherits it rather than
/// generating its own (`data class D(val x: String) : Base()` for a
/// `Base` with `final override fun toString()` prints what `Base` does).
fn inheritsFinal(s: *Sema, cls: Sym, n: Name, arity: usize) Allocator.Error!bool {
    const headers = @import("headers.zig");
    const members = @import("members.zig");
    for (try headers.supertypes(s, cls)) |st| {
        for (try members.lookup(s, st, n, .function)) |m| {
            if (s.syms.owner(m.sym) == s.builtins.any) continue;
            if (s.syms.flags(m.sym).modality != .final) continue;
            try headers.functionHeader(s, m.sym);
            const info = s.syms.functionInfo(m.sym);
            if (info.receiver != .none or info.params.len != arity) continue;
            return true;
        }
    }
    return false;
}

fn synthesizeDelegation(s: *Sema, cls: Sym) Allocator.Error!void {
    const headers = @import("headers.zig");
    const members = @import("members.zig");
    // A class, an object and an object expression can each delegate.
    const supertypes: []const ast.TypeRef, const delegates: []const ?ast.Expr = switch (s.syms.get(cls).decl) {
        .class => |c| .{ c.supertypes, c.supertype_delegates },
        .object => |o| .{ o.supertypes, o.supertype_delegates },
        .object_literal => |o| .{ o.supertypes, o.supertype_delegates },
        else => return,
    };
    const file = s.syms.get(cls).file;
    for (delegates, 0..) |d, di| {
        if (d == null or di >= supertypes.len) continue;
        const st = try headers.resolveTypeRef(s, .{ .decl = cls, .file = file }, &supertypes[di]);
        const iface = s.types.classSym(st);
        if (iface == .none) continue;
        var names: std.ArrayList(names_mod.Name) = .empty;
        try memberNames(s, iface, &names);
        const own_subst = try s.arena.create(types.Subst);
        own_subst.* = .empty;
        for (names.items) |n| {
            for (try members.lookup(s, st, n, .callable)) |m| {
                const owner = s.syms.owner(m.sym);
                if (owner == s.builtins.any or s.syms.flags(m.sym).static) continue;
                if (try declaresSame(s, cls, m, own_subst)) continue;
                _ = try synthDelegated(s, cls, file, m, @intCast(di));
            }
        }
    }
}

/// Every member name declared in `cls` and its supertypes.
fn memberNames(s: *Sema, cls: Sym, out: *std.ArrayList(names_mod.Name)) Allocator.Error!void {
    const headers = @import("headers.zig");
    var it = s.syms.classInfo(cls).members.iterator();
    while (it.next()) |e| {
        for (e.value_ptr.items) |m| {
            const k = s.syms.kind(m);
            if (k != .function and k != .property) continue;
            if (std.mem.indexOfScalar(names_mod.Name, out.items, e.key_ptr.*) == null) try out.append(s.arena, e.key_ptr.*);
            break;
        }
    }
    for (try headers.supertypes(s, cls)) |st| {
        const sc = s.types.classSym(st);
        if (sc != .none and sc != s.builtins.any) try memberNames(s, sc, out);
    }
}

/// Whether `cls` declares a member `m` would be delegated as.
fn declaresSame(s: *Sema, cls: Sym, m: @import("members.zig").Member, own_subst: *const types.Subst) Allocator.Error!bool {
    const members = @import("members.zig");
    for (symbols.Symbols.members(&s.syms.classInfo(cls).members, s.syms.name(m.sym))) |own| {
        if (s.syms.kind(own) != s.syms.kind(m.sym)) continue;
        if (s.syms.kind(own) == .property) return true;
        if (try members.sameSignature(s, own, own_subst, m.sym, m.subst)) return true;
    }
    return false;
}

fn synthDelegated(s: *Sema, cls: Sym, file: u32, m: @import("members.zig").Member, di: u16) Allocator.Error!Sym {
    const headers = @import("headers.zig");
    // A copy: adding symbols below can move the table `get` points into.
    const src = s.syms.get(m.sym).*;
    var flags: Flags = .{ .synthetic = true, .has_body = true, .override = true };
    flags.suspend_ = src.flags.suspend_;
    flags.operator = src.flags.operator;
    flags.infix = src.flags.infix;
    flags.mutable = src.flags.mutable;
    if (src.kind == .property) {
        const p = try s.syms.addProperty(.{
            .kind = .property,
            .name = src.name,
            .owner = cls,
            .file = file,
            .flags = flags,
            .decl = .none,
            .detail = 0,
        }, .{
            .ty = try s.types.substitute(try headers.propertyType(s, m.sym), m.subst),
            .receiver = if (s.syms.propertyInfo(m.sym).receiver != .none) try s.types.substitute(s.syms.propertyInfo(m.sym).receiver, m.subst) else .none,
            .type_params = s.syms.propertyInfo(m.sym).type_params,
            .state = .done,
            .body_done = true,
            .forwards = m.sym,
            .delegation = di,
        });
        try indexClassMember(s, cls, src.name, p);
        return p;
    }
    try headers.functionHeader(s, m.sym);
    // Read before adding symbols: `addFunction` (and a return type inferred
    // from a body) can grow the table `functionInfo` points into.
    const ret = try s.types.substitute(try headers.returnType(s, m.sym), m.subst);
    const src_info = s.syms.functionInfo(m.sym).*;
    const fi = &src_info;
    const f = try s.syms.addFunction(.{
        .kind = .function,
        .name = src.name,
        .owner = cls,
        .file = file,
        .flags = flags,
        .decl = .none,
        .detail = 0,
    }, .{
        .type_params = fi.type_params,
        .receiver = if (fi.receiver != .none) try s.types.substitute(fi.receiver, m.subst) else .none,
        .ret = ret,
        .state = .done,
        .body_done = true,
        .forwards = m.sym,
        .delegation = di,
    });
    const ps = try s.arena.alloc(Sym, fi.params.len);
    for (fi.params, ps, 0..) |p, *o, i| {
        o.* = try s.syms.addParam(.{
            .kind = .value_param,
            .name = s.syms.name(p),
            .owner = f,
            .file = file,
            .flags = .{ .synthetic = true, .vararg = s.syms.flags(p).vararg },
            .decl = .none,
            .detail = 0,
        }, .{ .index = @intCast(i), .ty = try s.types.substitute(try headers.paramType(s, p), m.subst), .state = .done });
    }
    s.syms.functionInfo(f).params = ps;
    try indexClassMember(s, cls, src.name, f);
    return f;
}

const SynthParam = struct { name: names_mod.Name, ty: types.TypeId, has_default: bool = false, default_prop: Sym = .none };

/// The property a constructor parameter declares (`val x`), `.none` for a
/// plain parameter.
fn ctorProperty(s: *Sema, cls: Sym, p: Sym) Sym {
    for (symbols.Symbols.members(&s.syms.classInfo(cls).members, s.syms.name(p))) |m| {
        if (s.syms.kind(m) == .property and s.syms.propertyInfo(m).from_ctor) return m;
    }
    return .none;
}

fn synthFunction(s: *Sema, cls: Sym, file: u32, n: names_mod.Name, params: []const SynthParam, ret: types.TypeId, extra: Flags) Allocator.Error!Sym {
    var flags = extra;
    flags.synthetic = true;
    flags.has_body = true;
    const f = try s.syms.addFunction(.{
        .kind = .function,
        .name = n,
        .owner = cls,
        .file = file,
        .flags = flags,
        .decl = .none,
        .detail = 0,
    }, .{ .ret = ret, .state = .done, .body_done = true });
    const ps = try s.arena.alloc(Sym, params.len);
    for (params, ps, 0..) |p, *o, i| {
        o.* = try s.syms.addParam(.{
            .kind = .value_param,
            .name = p.name,
            .owner = f,
            .file = file,
            .flags = .{ .synthetic = true, .has_default = p.has_default },
            .decl = .none,
            .detail = 0,
        }, .{ .index = @intCast(i), .ty = p.ty, .state = .done, .default_prop = p.default_prop });
    }
    s.syms.functionInfo(f).params = ps;
    try indexClassMember(s, cls, n, f);
    return f;
}

fn headersSelf(s: *Sema, cls: Sym) Allocator.Error!types.TypeId {
    return @import("headers.zig").selfType(s, cls);
}

fn headersParam(s: *Sema, p: Sym) Allocator.Error!types.TypeId {
    return @import("headers.zig").paramType(s, p);
}

/// Synthesizes the language-declared members of every class collected so
/// far; runs once the builtins are bound.
pub fn synthesizeAll(s: *Sema) Allocator.Error!void {
    return synthesizeFrom(s, Sym.from(1));
}

/// Synthesized members of the classes declared from `first` on.
/// Marks the functions, constructors and properties declared from `first`
/// on that `@kotlin.Deprecated(level = DeprecationLevel.HIDDEN)` hides from
/// source: they stay declared but are never a candidate.
pub fn markHidden(s: *Sema, first: Sym) Allocator.Error!void {
    const headers = @import("headers.zig");
    const deprecated = s.builtins.deprecated;
    if (deprecated == .none) return;
    var i: u32 = @max(first.int(), 1);
    const n = s.syms.count();
    while (i < n) : (i += 1) {
        const sym = Sym.from(i);
        const anns: []const ast.Annotation = switch (s.syms.get(sym).decl) {
            .function => |f| f.annotations,
            .property => |p| p.annotations,
            .secondary_ctor => |c| c.annotations,
            else => continue,
        };
        if (!hiddenLevel(anns)) continue;
        if (!try headers.annotatedWith(s, .{ .decl = sym, .file = s.syms.get(sym).file }, anns, deprecated)) continue;
        s.syms.getMut(sym).flags.hidden = true;
    }
}

/// Whether an annotation named `Deprecated` passes `DeprecationLevel.HIDDEN`
/// as its level, named or third.
fn hiddenLevel(anns: []const ast.Annotation) bool {
    for (anns) |a| {
        if (a.path.len == 0 or !std.mem.eql(u8, a.path[a.path.len - 1].name, "Deprecated")) continue;
        for (a.args, 0..) |*arg, i| {
            const named: ?[]const u8 = if (i < a.arg_names.len) a.arg_names[i] else null;
            if (named) |nm| {
                if (!std.mem.eql(u8, nm, "level")) continue;
            } else if (i != 2) continue;
            const last: []const u8 = switch (arg.*) {
                .Path => |p| p.segments[p.segments.len - 1].name,
                .Member => |m| m.name.name,
                else => continue,
            };
            if (std.mem.eql(u8, last, "HIDDEN")) return true;
        }
    }
    return false;
}

pub fn synthesizeFrom(s: *Sema, first: Sym) Allocator.Error!void {
    var i: u32 = @max(first.int(), 1);
    const n = s.syms.count();
    while (i < n) : (i += 1) {
        const sym = Sym.from(i);
        if (s.syms.kind(sym) != .class) continue;
        try synthesizeMembers(s, sym);
    }
}

fn collectTypeAlias(ctx: Ctx, ta: *const ast.TypeAlias, owner: Sym) Allocator.Error!Sym {
    const s = ctx.s;
    const fqn = try s.names.intern(try join(s, ctx.prefix, ta.name.name));
    const sym = try s.syms.addAlias(.{
        .kind = .type_alias,
        .name = try s.names.intern(ta.name.name),
        .owner = owner,
        .file = ctx.file,
        .flags = .{ .visibility = visibility(ta.visibility) },
        .decl = .{ .type_alias = ta },
        .detail = 0,
    }, .{});
    const tps = try typeParams(ctx, ta.type_params, sym);
    s.syms.aliasInfo(sym).type_params = tps;
    try registerFqn(s, fqn, sym);
    return sym;
}

/// Records `sym` as the classifier named `fqn`. An `actual` replaces an
/// `expect` of the same name, and a declaration never replaces an `actual`.
fn registerFqn(s: *Sema, fqn: Name, sym: Sym) Allocator.Error!void {
    const gop = try s.syms.by_fqn.getOrPut(s.arena, fqn);
    if (!gop.found_existing) {
        gop.value_ptr.* = sym;
        return;
    }
    const prev = gop.value_ptr.*;
    const pf = s.syms.flags(prev);
    const nf = s.syms.flags(sym);
    if (pf.expect and !nf.expect) {
        s.syms.getMut(prev).flags.superseded = true;
        gop.value_ptr.* = sym;
    } else if (nf.expect and !pf.expect) {
        s.syms.getMut(sym).flags.superseded = true;
    }
}

/// Marks every `expect` function or property that an `actual` of the same
/// name and arity in the same package supersedes, so lookups see only the
/// actual. Classes are settled as they register; their members' defaults
/// are linked here. Links actuals to expects where either was declared
/// from `first` on, so a later layer does not link (or report) an earlier
/// one's pairs again.
pub fn linkExpectActual(s: *Sema, first: Sym) Allocator.Error!void {
    var p: usize = 0;
    while (p < s.syms.packages.items.len) : (p += 1) {
        var it = s.syms.packages.items[p].members.iterator();
        while (it.next()) |entry| {
            const list = entry.value_ptr.items;
            for (list) |e| {
                if (!s.syms.flags(e).expect) continue;
                switch (s.syms.kind(e)) {
                    .function, .property => {},
                    .class => {
                        const actual = s.syms.by_fqn.get(s.syms.classInfo(e).fqn) orelse continue;
                        if (e.int() < first.int() and actual.int() < first.int()) continue;
                        if (actual != e and s.syms.kind(actual) == .class) try linkClassDefaults(s, e, actual);
                        continue;
                    },
                    else => continue,
                }
                if (list.len < 2) continue;
                const ek = s.syms.kind(e);
                for (list) |a| {
                    if (a == e or s.syms.flags(a).expect) continue;
                    if (s.syms.kind(a) != ek) continue;
                    if (e.int() < first.int() and a.int() < first.int()) continue;
                    if (!try sameErasedSignature(s, e, a)) continue;
                    s.syms.getMut(e).flags.superseded = true;
                    try checkActualModifiers(s, e, a);
                    if (ek == .function) inheritDefaults(s, e, a);
                    // An expect hidden from source hides its actual.
                    if (s.syms.flags(e).hidden) s.syms.getMut(a).flags.hidden = true;
                    break;
                }
            }
        }
    }
}

/// An `actual` declares no defaults: its parameters take the ones its
/// `expect` declares.
fn inheritDefaults(s: *Sema, e: Sym, a: Sym) void {
    const ep = s.syms.functionInfo(e).params;
    const ap = s.syms.functionInfo(a).params;
    if (ep.len != ap.len) return;
    for (ep, ap) |x, y| {
        if (!s.syms.flags(x).has_default or s.syms.flags(y).has_default) continue;
        s.syms.getMut(y).flags.has_default = true;
        s.syms.paramInfo(y).default_from = x;
    }
}

/// The defaults an `expect` class's constructors and member functions
/// declare, given to the `actual` class's matching ones, nested classes
/// included.
fn linkClassDefaults(s: *Sema, e: Sym, a: Sym) Allocator.Error!void {
    var it = s.syms.classInfo(e).members.iterator();
    while (it.next()) |entry| {
        const actuals = symbols.Symbols.members(&s.syms.classInfo(a).members, entry.key_ptr.*);
        for (entry.value_ptr.items) |em| {
            const k = s.syms.kind(em);
            for (actuals) |am| {
                if (s.syms.kind(am) != k) continue;
                switch (k) {
                    .function, .constructor => {
                        if (!try sameErasedSignature(s, em, am)) continue;
                        inheritDefaults(s, em, am);
                    },
                    .class => try linkClassDefaults(s, em, am),
                    else => {},
                }
                break;
            }
        }
    }
}

/// Whether two top-level declarations have the same erased signature:
/// receiver and parameter classes (or type-parameter positions), and the
/// same number of type parameters.
fn sameErasedSignature(s: *Sema, a: Sym, b: Sym) Allocator.Error!bool {
    const headers = @import("headers.zig");
    if (s.syms.kind(a) == .property) {
        try headers.propertyHeader(s, a);
        try headers.propertyHeader(s, b);
        return sameErasure(s, s.syms.propertyInfo(a).receiver, s.syms.propertyInfo(b).receiver);
    }
    try headers.functionHeader(s, a);
    try headers.functionHeader(s, b);
    const ai = s.syms.functionInfo(a);
    const bi = s.syms.functionInfo(b);
    if (ai.params.len != bi.params.len or ai.type_params.len != bi.type_params.len) return false;
    if (!sameErasure(s, ai.receiver, bi.receiver)) return false;
    for (ai.params, bi.params) |ap, bp| {
        if (s.syms.flags(ap).vararg != s.syms.flags(bp).vararg) return false;
        if (!sameErasure(s, try headers.paramType(s, ap), try headers.paramType(s, bp))) return false;
    }
    return true;
}

/// An `expect` class and its `actual` are one class: a parameter of the
/// expect's nested `Factory` is the actual's `Factory` parameter. They
/// share their fully qualified name.
fn sameErasure(s: *Sema, a: types.TypeId, b: types.TypeId) bool {
    if (a == b) return true;
    if (a == .none or b == .none) return false;
    const ta = s.types.get(a);
    const tb = s.types.get(b);
    if (ta == .class and tb == .class) {
        const x = ta.class.sym;
        const y = tb.class.sym;
        if (x == y) return true;
        if (s.syms.kind(x) != .class or s.syms.kind(y) != .class) return false;
        return s.syms.classInfo(x).fqn == s.syms.classInfo(y).fqn;
    }
    if (ta == .param and tb == .param) {
        return s.syms.typeParamInfo(ta.param.sym).index == s.syms.typeParamInfo(tb.param.sym).index;
    }
    return ta == .err or tb == .err;
}

/// An `actual` must repeat its `expect`'s modifiers. A difference is a
/// defect in the base sources, reported to the census; the header facts
/// callers resolve against (`operator`, `infix`) are the expect's.
fn checkActualModifiers(s: *Sema, e: Sym, a: Sym) Allocator.Error!void {
    const ef = s.syms.flags(e);
    const af = s.syms.flags(a);
    const file = s.syms.get(a).file;
    const sp = declSpan(s, a);
    const name = s.str(s.syms.name(a));
    if (!af.actual) try mismatch(s, file, sp, name, .ACTUAL_MISSING, "matches an expect but is not marked actual", "`{s}` implements an `expect` and must be marked `actual`");
    // The actual carries every `inline`, `operator` and `infix` its expect
    // has, and may add `inline`; `suspend` matches.
    const not_subset: census_mod.Factory = .EXPECT_ACTUAL_INCOMPATIBLE_FUNCTION_MODIFIERS_NOT_SUBSET;
    if (ef.inline_ and !af.inline_) try mismatch(s, file, sp, name, not_subset, "its expect is inline", "`{s}` must be `inline`, as its `expect` is");
    if (ef.suspend_ != af.suspend_) try mismatch(s, file, sp, name, .EXPECT_ACTUAL_INCOMPATIBLE_FUNCTION_MODIFIERS_DIFFERENT, "suspend differs from its expect", "`{s}` must be `suspend` exactly when its `expect` is");
    if (ef.operator and !af.operator) try mismatch(s, file, sp, name, not_subset, "its expect is an operator", "`{s}` must be an `operator`, as its `expect` is");
    if (ef.infix and !af.infix) try mismatch(s, file, sp, name, not_subset, "its expect is infix", "`{s}` must be `infix`, as its `expect` is");
    const m = s.syms.getMut(a);
    m.flags.operator = m.flags.operator or ef.operator;
    m.flags.infix = m.flags.infix or ef.infix;
}

fn mismatch(s: *Sema, file: u32, sp: @import("span").Span, name: []const u8, factory: census_mod.Factory, comptime detail: []const u8, comptime msg: []const u8) Allocator.Error!void {
    try s.census.reportFacts(.expect_actual_mismatch, file, sp, .{ .message = try std.fmt.allocPrint(s.arena, msg, .{name}), .factory = factory }, "{s}: " ++ detail, .{name});
}

/// The span of a declaration's name.
pub fn declSpan(s: *Sema, sym: Sym) @import("span").Span {
    return switch (s.syms.get(sym).decl) {
        .function => |f| f.name.span,
        .property => |p| p.name.span,
        .class => |c| c.name.span,
        .object => |o| o.name.span,
        .type_alias => |ta| ta.name.span,
        .class_param => |cp| cp.name.span,
        // A data class's `componentN` and `copy` are declared by the class.
        .none => if (dataMember(s, sym)) declSpan(s, s.syms.owner(sym)) else @import("span").Span.init(@import("span").FileId.from(0), 0, 0),
        else => @import("span").Span.init(@import("span").FileId.from(0), 0, 0),
    };
}

/// A `componentN` or `copy` the language declares for a data class.
fn dataMember(s: *Sema, sym: Sym) bool {
    if (s.syms.kind(sym) != .function or !s.syms.flags(sym).synthetic) return false;
    return switch (s.syms.functionInfo(sym).synth) {
        .data_component, .data_copy => true,
        else => false,
    };
}

/// Reports what is wrong with the program's declarations from `first` on,
/// before any body is resolved: two declarations of one scope that clash
/// (functions of one signature, properties or classifiers of one name), a
/// member with a supertype member's signature and no `override`, and an
/// `expect` no `actual` implements. The base's declarations are the
/// libraries', not the program's to answer for.
pub fn checkDeclarations(s: *Sema, first: Sym) Allocator.Error!void {
    var i: u32 = first.int();
    const n: u32 = @intCast(s.syms.count());
    while (i < n) : (i += 1) {
        const sym = Sym.from(i);
        const file = s.syms.get(sym).file;
        const fc = s.fileOf(file) orelse continue;
        if (fc.origin != .program) continue;
        switch (s.syms.kind(sym)) {
            .function, .property, .class, .type_alias => {},
            else => continue,
        }
        if (s.syms.flags(sym).synthetic) continue;
        const owner = s.syms.owner(sym);
        if (owner == .none) continue;
        switch (s.syms.kind(owner)) {
            .package, .class => {},
            else => continue,
        }
        try checkConflicts(s, sym, owner);
        if (!fc.generated) try checkHidesMember(s, sym);
        try checkExpectHasActual(s, sym);
    }
}

/// A member declared without `override` that has the signature of a
/// supertype's member: kotlinc requires the modifier.
fn checkHidesMember(s: *Sema, sym: Sym) Allocator.Error!void {
    const fl = s.syms.flags(sym);
    if (fl.override or fl.static) return;
    const hidden = try @import("members.zig").hiddenSupertypeMember(s, sym);
    if (hidden == .none) return;
    const msg = try std.fmt.allocPrint(s.arena, "`{s}` hides member of supertype `{s}` and needs an `override` modifier", .{
        s.str(s.syms.name(sym)),
        s.str(s.syms.name(s.syms.owner(hidden))),
    });
    try s.census.reportFacts(.member_hidden, s.syms.get(sym).file, declSpan(s, sym), .{ .message = msg }, "{s}", .{msg});
}

fn checkConflicts(s: *Sema, sym: Sym, owner: Sym) Allocator.Error!void {
    const scope_mod = @import("scope.zig");
    var clashes: std.ArrayList(Sym) = .empty;
    for (scope_mod.membersOf(s, owner, s.syms.name(sym))) |other| {
        if (other == sym) continue;
        if (!try clash(s, sym, other)) continue;
        if (clashes.items.len == 0) try clashes.append(s.arena, sym);
        try clashes.append(s.arena, other);
    }
    if (clashes.items.len == 0) return;
    const name = s.str(s.syms.name(sym));
    var related: std.ArrayList(census_mod.Related) = .empty;
    for (clashes.items[1..]) |other| try related.append(s.arena, .{ .file = s.syms.get(other).file, .sp = declSpan(s, other), .message = "also declared here" });
    // kotlinc names a clash of functions an overload conflict and one of
    // properties or classifiers a redeclaration.
    const factory: census_mod.Factory = switch (s.syms.kind(sym)) {
        .function => .CONFLICTING_OVERLOADS,
        .property => .REDECLARATION,
        else => .CLASSIFIER_REDECLARATION,
    };
    try s.census.reportFacts(.conflicting_overloads, s.syms.get(sym).file, declSpan(s, sym), .{ .name = name, .syms = clashes.items, .factory = factory, .related = related.items }, "{s}: {d} declarations", .{ name, clashes.items.len });
    // A `componentN` or `copy` the class declares clashes with the one the
    // language declares for it too, which kotlinc reports at the class.
    for (clashes.items[1..]) |other| {
        if (!dataMember(s, other)) continue;
        const pair = try s.arena.dupe(Sym, &.{ other, sym });
        const back = try s.arena.dupe(census_mod.Related, &.{.{ .file = s.syms.get(sym).file, .sp = declSpan(s, sym), .message = "also declared here" }});
        try s.census.reportFacts(.conflicting_overloads, s.syms.get(other).file, declSpan(s, other), .{ .name = name, .syms = pair, .factory = factory, .related = back }, "{s}: {d} declarations", .{ name, 2 });
    }
}

/// Whether two declarations of one scope under one name clash: two
/// functions of the same signature, two properties, or two classifiers. An
/// `expect` and the `actual` implementing it do not, nor do two private
/// top-level declarations of different files.
fn clash(s: *Sema, a: Sym, b: Sym) Allocator.Error!bool {
    const ka = s.syms.kind(a);
    const kb = s.syms.kind(b);
    const classifier = struct {
        fn is(k: symbols.Kind) bool {
            return k == .class or k == .type_alias;
        }
    }.is;
    if (!(ka == kb or (classifier(ka) and classifier(kb)))) return false;
    switch (ka) {
        .function, .property, .class, .type_alias => {},
        else => return false,
    }
    const fa = s.syms.flags(a);
    const fb = s.syms.flags(b);
    if (fb.synthetic and !dataMember(s, b)) return false;
    if (fa.expect != fb.expect) return false;
    if (fa.visibility == .private and fb.visibility == .private and s.syms.get(a).file != s.syms.get(b).file) return false;
    return switch (ka) {
        .function => sameSignature(s, a, b),
        .property => samePropertySignature(s, a, b),
        else => true,
    };
}

/// Whether two properties have one signature: their receiver and context
/// parameter types. `val x` and `val X.x` are different properties.
fn samePropertySignature(s: *Sema, a: Sym, b: Sym) Allocator.Error!bool {
    const headers = @import("headers.zig");
    try headers.propertyHeader(s, a);
    try headers.propertyHeader(s, b);
    const ai = s.syms.propertyInfo(a);
    const bi = s.syms.propertyInfo(b);
    if (ai.type_params.len != bi.type_params.len) return false;
    if (!try sameTypeParams(s, ai.type_params, bi.type_params)) return false;
    if ((ai.receiver == .none) != (bi.receiver == .none)) return false;
    if (ai.receiver != .none and !sameType(s, ai.receiver, bi.receiver)) return false;
    if (ai.context_params.len != bi.context_params.len) return false;
    for (ai.context_params, bi.context_params) |x, y| {
        if (!sameType(s, try headers.paramType(s, x), try headers.paramType(s, y))) return false;
    }
    return true;
}

/// Whether two lists of type parameters have the same bounds, position by
/// position: `fun <T : A> f(t: T)` and `fun <T : B> f(t: T)` overload.
fn sameTypeParams(s: *Sema, a: []const Sym, b: []const Sym) Allocator.Error!bool {
    const headers = @import("headers.zig");
    for (a, b) |x, y| {
        const xb = try headers.typeParamBounds(s, x);
        const yb = try headers.typeParamBounds(s, y);
        if (xb.len != yb.len) return false;
        for (xb, yb) |p, q| {
            if (!sameType(s, p, q)) return false;
        }
    }
    return true;
}

/// Whether two functions have one signature: receiver, context and value
/// parameter types, varargs and type parameter count; the names of the
/// parameters and the return type are not part of it.
fn sameSignature(s: *Sema, a: Sym, b: Sym) Allocator.Error!bool {
    const headers = @import("headers.zig");
    try headers.functionHeader(s, a);
    try headers.functionHeader(s, b);
    const ai = s.syms.functionInfo(a);
    const bi = s.syms.functionInfo(b);
    if (ai.params.len != bi.params.len or ai.type_params.len != bi.type_params.len) return false;
    if (!try sameTypeParams(s, ai.type_params, bi.type_params)) return false;
    if (ai.context_params.len != bi.context_params.len) return false;
    if ((ai.receiver == .none) != (bi.receiver == .none)) return false;
    if (ai.receiver != .none and !sameType(s, ai.receiver, bi.receiver)) return false;
    for (ai.context_params, bi.context_params) |x, y| {
        if (!sameType(s, try headers.paramType(s, x), try headers.paramType(s, y))) return false;
    }
    for (ai.params, bi.params) |x, y| {
        if (s.syms.flags(x).vararg != s.syms.flags(y).vararg) return false;
        if (!sameType(s, try headers.paramType(s, x), try headers.paramType(s, y))) return false;
    }
    return true;
}

/// Type equality with type parameters compared by position.
fn sameType(s: *Sema, a: types.TypeId, b: types.TypeId) bool {
    if (a == b) return true;
    const ta = s.types.get(a);
    const tb = s.types.get(b);
    switch (ta) {
        .param => |p| {
            if (tb != .param) return false;
            const q = tb.param;
            return p.nullable == q.nullable and p.dnn == q.dnn and
                s.syms.typeParamInfo(p.sym).index == s.syms.typeParamInfo(q.sym).index;
        },
        .class => |c| {
            if (tb != .class) return false;
            const d = tb.class;
            if (c.sym != d.sym or c.nullable != d.nullable or c.args.len != d.args.len) return false;
            for (c.args, d.args) |x, y| {
                if (x.variance != y.variance) return false;
                if (x.variance == .star) continue;
                if (!sameType(s, x.ty, y.ty)) return false;
            }
            return true;
        },
        else => return false,
    }
}

/// An `expect` of the program is implemented by an `actual` of the program
/// in its package: one no `actual` supersedes is reported at its name.
fn checkExpectHasActual(s: *Sema, sym: Sym) Allocator.Error!void {
    const f = s.syms.flags(sym);
    if (!f.expect or f.superseded) return;
    // A member is implemented with its class.
    if (s.syms.kind(s.syms.owner(sym)) != .package) return;
    if (s.syms.kind(sym) == .class) {
        const actual = s.syms.by_fqn.get(s.syms.classInfo(sym).fqn) orelse sym;
        if (actual != sym) return;
        // An `@OptionalExpectation` annotation class needs no actual: where
        // it has none, its uses are dropped.
        switch (s.syms.get(sym).decl) {
            .class => |c| {
                const headers = @import("headers.zig");
                const opt = s.classByFqn("kotlin.OptionalExpectation");
                if (try headers.annotatedWith(s, headers.ctxOf(s, sym), c.annotations, opt)) return;
            },
            else => {},
        }
    }
    const pkg = s.str(s.syms.packageInfo(s.syms.owner(sym)).fqn);
    const simple = s.str(s.syms.name(sym));
    const fqn = if (pkg.len == 0) simple else try std.fmt.allocPrint(s.arena, "{s}.{s}", .{ pkg, simple });
    try s.census.reportFacts(.expect_no_actual, s.syms.get(sym).file, declSpan(s, sym), .{ .name = fqn }, "{s}", .{fqn});
}

/// `kotlin.reflect.KFunctionN<P1.., R>` (or `KSuspendFunctionN`), the type
/// of a function reference: a `FunctionN` of the same arity that is also a
/// `KFunction<R>`.
pub fn synthesizeKFunctionClass(s: *Sema, arity: u32, is_suspend: bool) Allocator.Error!Sym {
    const simple = try std.fmt.allocPrint(s.arena, "{s}{d}", .{ if (is_suspend) "KSuspendFunction" else "KFunction", arity });
    const fqn = try s.names.intern(try std.fmt.allocPrint(s.arena, "kotlin.reflect.{s}", .{simple}));
    const pkg = try packageFor(s, &.{ .{ .name = "kotlin", .span = undefined }, .{ .name = "reflect", .span = undefined } });
    const cls = try s.syms.addClass(.{
        .kind = .class,
        .name = try s.names.intern(simple),
        .owner = pkg,
        .file = symbols.NO_FILE,
        .flags = .{ .modality = .abstract, .synthetic = true },
        .decl = .none,
        .detail = 0,
    }, .{ .kind = .interface, .fqn = fqn });
    try s.syms.by_fqn.put(s.arena, fqn, cls);
    try s.syms.indexMember(&s.syms.packageInfo(pkg).members, s.syms.name(cls), cls);
    const tps = try s.arena.alloc(Sym, arity + 1);
    for (tps, 0..) |*tp, i| {
        const is_ret = i == arity;
        const tp_name = if (is_ret) "R" else try std.fmt.allocPrint(s.arena, "P{d}", .{i + 1});
        tp.* = try s.syms.addTypeParam(.{
            .kind = .type_param,
            .name = try s.names.intern(tp_name),
            .owner = cls,
            .file = symbols.NO_FILE,
            .flags = .{ .synthetic = true },
            .decl = .none,
            .detail = 0,
        }, .{ .index = @intCast(i), .variance = if (is_ret) .out else .in, .state = .done, .bounds = &.{} });
    }
    const info = s.syms.classInfo(cls);
    info.type_params = tps;
    const self_args = try s.arena.alloc(types.Arg, tps.len);
    for (tps, self_args) |tp, *a| a.* = .{ .variance = .inv, .ty = try s.types.param(tp, false) };
    info.self_type = try s.types.class(cls, self_args, false);
    var sts: std.ArrayList(types.TypeId) = .empty;
    try sts.append(s.arena, try s.types.class(try s.functionClass(arity, is_suspend), self_args, false));
    if (s.builtins.kfunction != .none) {
        try sts.append(s.arena, try s.types.class(s.builtins.kfunction, &.{.{ .variance = .inv, .ty = self_args[arity].ty }}, false));
    }
    s.syms.classInfo(cls).supertypes = sts.items;
    s.syms.classInfo(cls).supertypes_state = .done;
    return cls;
}

/// Declares `kotlin.FunctionN<in P1, ..., in PN, out R> : Function<R>` with
/// `abstract operator fun invoke(p1: P1, ...): R`, or the suspend family in
/// `kotlin.coroutines`.
pub fn synthesizeFunctionClass(s: *Sema, arity: u32, is_suspend: bool) Allocator.Error!Sym {
    const pkg_name = if (is_suspend) "kotlin.coroutines" else "kotlin";
    const simple = try std.fmt.allocPrint(s.arena, "{s}{d}", .{ if (is_suspend) "SuspendFunction" else "Function", arity });
    const fqn = try s.names.intern(try std.fmt.allocPrint(s.arena, "{s}.{s}", .{ pkg_name, simple }));
    var path: std.ArrayList(ast.Ident) = .empty;
    var it = std.mem.splitScalar(u8, pkg_name, '.');
    while (it.next()) |seg| try path.append(s.arena, .{ .name = seg, .span = undefined });
    const pkg = try packageFor(s, path.items);
    const cls = try s.syms.addClass(.{
        .kind = .class,
        .name = try s.names.intern(simple),
        .owner = pkg,
        .file = symbols.NO_FILE,
        .flags = .{ .modality = .abstract, .synthetic = true },
        .decl = .none,
        .detail = 0,
    }, .{ .kind = .interface, .fqn = fqn });
    try s.syms.by_fqn.put(s.arena, fqn, cls);
    try s.syms.indexMember(&s.syms.packageInfo(pkg).members, s.syms.name(cls), cls);

    const tps = try s.arena.alloc(Sym, arity + 1);
    for (tps, 0..) |*tp, i| {
        const is_ret = i == arity;
        const tp_name = if (is_ret) "R" else try std.fmt.allocPrint(s.arena, "P{d}", .{i + 1});
        tp.* = try s.syms.addTypeParam(.{
            .kind = .type_param,
            .name = try s.names.intern(tp_name),
            .owner = cls,
            .file = symbols.NO_FILE,
            .flags = .{ .synthetic = true },
            .decl = .none,
            .detail = 0,
        }, .{ .index = @intCast(i), .variance = if (is_ret) .out else .in, .state = .done, .bounds = &.{} });
    }
    const info = s.syms.classInfo(cls);
    info.type_params = tps;
    const ret_t = try s.types.param(tps[arity], false);
    if (s.builtins.function != .none) {
        info.supertypes = try s.arena.dupe(types.TypeId, &.{try s.types.class(s.builtins.function, &.{.{ .variance = .inv, .ty = ret_t }}, false)});
    } else if (s.builtins.any != .none) {
        info.supertypes = try s.arena.dupe(types.TypeId, &.{s.t.any});
    }
    info.supertypes_state = .done;
    var self_args = try s.arena.alloc(types.Arg, tps.len);
    for (tps, 0..) |tp, i| self_args[i] = .{ .variance = .inv, .ty = try s.types.param(tp, false) };
    info.self_type = try s.types.class(cls, self_args, false);

    const invoke = try s.syms.addFunction(.{
        .kind = .function,
        .name = wk.invoke,
        .owner = cls,
        .file = symbols.NO_FILE,
        .flags = .{ .modality = .abstract, .operator = true, .synthetic = true, .suspend_ = is_suspend },
        .decl = .none,
        .detail = 0,
    }, .{ .ret = ret_t, .state = .done });
    const params = try s.arena.alloc(Sym, arity);
    for (params, 0..) |*p, i| {
        p.* = try s.syms.addParam(.{
            .kind = .value_param,
            .name = try s.names.intern(try std.fmt.allocPrint(s.arena, "p{d}", .{i + 1})),
            .owner = invoke,
            .file = symbols.NO_FILE,
            .flags = .{ .synthetic = true },
            .decl = .none,
            .detail = 0,
        }, .{ .index = @intCast(i), .ty = try s.types.param(tps[i], false), .state = .done });
    }
    s.syms.functionInfo(invoke).params = params;
    try s.syms.indexMember(&s.syms.classInfo(cls).members, wk.invoke, invoke);
    return cls;
}
