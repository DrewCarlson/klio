//! Declarations with identity. Every package, class, function, constructor,
//! property, parameter, local, type parameter, type alias and enum entry the
//! analysis sees is one `Sym`, and every reference it resolves names one.

const std = @import("std");
const ast = @import("ast");
const span = @import("span");

const names_mod = @import("names.zig");
const types_mod = @import("types.zig");

const Allocator = std.mem.Allocator;
const Name = names_mod.Name;
const TypeId = types_mod.TypeId;

pub const Sym = enum(u32) {
    none = 0,
    _,

    pub fn int(self: Sym) u32 {
        return @intFromEnum(self);
    }
    pub fn from(i: u32) Sym {
        return @enumFromInt(i);
    }
};

pub const Kind = enum(u8) {
    package,
    /// Class, interface, object, companion, enum class, annotation class,
    /// enum entry with a body, object expression.
    class,
    type_param,
    /// Named function (top-level, member, local), accessor, anonymous
    /// function and lambda literal.
    function,
    constructor,
    property,
    value_param,
    /// Local `val`/`var`, `for` variable, catch parameter, destructuring
    /// entry, `when` subject binding.
    local,
    type_alias,
    enum_entry,
};

pub const Visibility = enum(u2) { public, internal, protected, private };
pub const Modality = enum(u2) { final, open, abstract, sealed };

pub const Flags = packed struct(u32) {
    visibility: Visibility = .public,
    modality: Modality = .final,
    expect: bool = false,
    actual: bool = false,
    inline_: bool = false,
    suspend_: bool = false,
    operator: bool = false,
    infix: bool = false,
    override: bool = false,
    data: bool = false,
    inner: bool = false,
    value: bool = false,
    fun_iface: bool = false,
    const_: bool = false,
    lateinit: bool = false,
    mutable: bool = false,
    vararg: bool = false,
    reified: bool = false,
    crossinline: bool = false,
    no_inline: bool = false,
    tailrec: bool = false,
    external: bool = false,
    /// Declared by the analysis, not by source: `FunctionN`, data-class
    /// `componentN`/`copy`, enum `values`/`valueOf`/`entries`, an implicit
    /// constructor, a fake override.
    synthetic: bool = false,
    has_body: bool = false,
    has_default: bool = false,
    /// An `expect` whose `actual` is in the analysis: every lookup sees the
    /// actual instead.
    superseded: bool = false,
    /// Called on the class itself, not an instance: an enum class's
    /// `values()`/`valueOf()`/`entries`.
    static: bool = false,
    /// Annotated `@Composable` (a function, or a property whose getter is).
    composable: bool = false,
    /// `@Deprecated(level = HIDDEN)`: declared, but never a candidate for
    /// a reference in source.
    hidden: bool = false,
    _pad: u1 = 0,
};

/// Where a symbol is declared. The pointers borrow the AST, which outlives
/// the analysis.
pub const Decl = union(enum) {
    none,
    file: *const ast.KotlinFile,
    class: *const ast.Class,
    object: *const ast.ObjectDecl,
    object_literal: *const ast.ObjectLiteral,
    enum_entry: *const ast.EnumEntry,
    function: *const ast.Function,
    anon_fun: *const ast.AnonFunExpr,
    lambda: *const ast.LambdaExpr,
    accessor: *const ast.Accessor,
    property: *const ast.Property,
    class_param: *const ast.ClassParam,
    param: *const ast.Param,
    context_param: *const ast.ContextParam,
    secondary_ctor: *const ast.SecondaryCtor,
    type_param: *const ast.TypeParam,
    type_alias: *const ast.TypeAlias,
    /// A local introduced by an identifier alone: a `for` variable, a
    /// lambda parameter, a catch binding, a destructuring entry.
    ident: ast.Ident,
    local_prop: *const ast.Property,
};

pub const NO_FILE: u32 = std.math.maxInt(u32);

pub const Symbol = struct {
    kind: Kind,
    name: Name,
    /// The package of a top-level declaration, the class of a member, the
    /// function of a parameter, local or type parameter.
    owner: Sym,
    /// The declaring file, for visibility and import scope; `NO_FILE` for a
    /// synthetic or package symbol.
    file: u32,
    flags: Flags,
    decl: Decl,
    /// Index into the per-kind table below.
    detail: u32,
};

pub const HeaderState = enum(u8) { pending, resolving, done };

/// A declared-member index: name to every symbol declared under it.
pub const NameIndex = std.AutoHashMapUnmanaged(Name, std.ArrayList(Sym));

pub const ClassKind = enum(u8) {
    class,
    interface,
    object,
    companion,
    enum_class,
    enum_entry,
    annotation,
    anonymous,
};

pub const ClassInfo = struct {
    kind: ClassKind,
    /// Fully qualified name, dotted, nested classes joined by `.`.
    fqn: Name,
    type_params: []const Sym = &.{},
    /// `type_params` followed by the outer classes' for an inner class,
    /// the arguments its type carries; set on first use.
    all_type_params: ?[]const Sym = null,
    /// Direct supertypes, resolved by the header pass. An empty list after
    /// `done` means `Any` alone, which the header pass writes explicitly.
    supertypes: []const TypeId = &.{},
    supertypes_state: HeaderState = .pending,
    /// Declared members, constructors under `<init>`, nested classifiers
    /// under their own name.
    members: NameIndex = .empty,
    companion: Sym = .none,
    primary_ctor: Sym = .none,
    enum_entries: []const Sym = &.{},
    /// The type `this` has inside the class: the class applied to its own
    /// type parameters.
    self_type: TypeId = .none,
};

pub const FunctionInfo = struct {
    type_params: []const Sym = &.{},
    params: []const Sym = &.{},
    context_params: []const Sym = &.{},
    /// Extension receiver type, `.none` for a non-extension.
    receiver: TypeId = .none,
    ret: TypeId = .none,
    state: HeaderState = .pending,
    /// For an accessor: the property it belongs to.
    property: Sym = .none,
    is_getter: bool = false,
    is_setter: bool = false,
    /// The body has been resolved (possibly early, to infer the return
    /// type), so the body pass does not resolve it again.
    body_done: bool = false,
    /// The members of the class's supertypes this member overrides
    /// directly; null until `members.overridden` computes it.
    overrides: ?[]const Sym = null,
    /// A member a class gets from `: I by d`: the interface member it
    /// forwards to, and which of the class's supertypes carries the `by`.
    forwards: Sym = .none,
    delegation: u16 = 0,
    /// What the language synthesizes this member as, for a member with no
    /// declaration; `component` carries its index.
    synth: Synth = .none,
    component: u16 = 0,
};

/// The members the language declares for a class.
pub const Synth = enum(u8) {
    none,
    enum_values,
    enum_value_of,
    data_equals,
    data_hash_code,
    data_to_string,
    data_copy,
    data_component,
    /// An annotation class's `equals`, `hashCode` and `toString`: by its
    /// constructor properties, `toString` rendered `@Tag(name=alpha)`.
    annotation_equals,
    annotation_hash_code,
    annotation_to_string,
};

pub const PropertyInfo = struct {
    type_params: []const Sym = &.{},
    context_params: []const Sym = &.{},
    receiver: TypeId = .none,
    ty: TypeId = .none,
    state: HeaderState = .pending,
    getter: Sym = .none,
    setter: Sym = .none,
    has_delegate: bool = false,
    /// Declared in a primary constructor.
    from_ctor: bool = false,
    body_done: bool = false,
    /// Resolved for its type before its class's body reached it, with the
    /// setter left for that pass: a setter never changes the type, and
    /// resolving it early could need this property's own type.
    setter_pending: bool = false,
    /// The type of an explicit backing field (`field = ...`), set when
    /// the property's body resolves.
    field_ty: TypeId = .none,
    /// As `FunctionInfo.overrides`.
    overrides: ?[]const Sym = null,
    /// As `FunctionInfo.forwards` and `delegation`.
    forwards: Sym = .none,
    delegation: u16 = 0,
};

pub const ParamInfo = struct {
    ty: TypeId = .none,
    index: u16 = 0,
    state: HeaderState = .pending,
    /// An `actual`'s parameter that takes its `expect`'s default: that
    /// `expect` parameter, whose default expression (resolved in the
    /// `expect`'s scope) is the one evaluated.
    default_from: Sym = .none,
    /// A data class `copy` parameter: the property whose current value is
    /// its default.
    default_prop: Sym = .none,
};

pub const LocalInfo = struct {
    ty: TypeId = .none,
};

pub const TypeParamInfo = struct {
    bounds: []const TypeId = &.{},
    state: HeaderState = .pending,
    index: u16 = 0,
    variance: types_mod.Variance = .inv,
};

pub const TypeAliasInfo = struct {
    type_params: []const Sym = &.{},
    target: TypeId = .none,
    state: HeaderState = .pending,
};

pub const EnumEntryInfo = struct {
    /// The enum class.
    enum_class: Sym,
    ordinal: u32,
    /// The anonymous subclass an entry with a body declares.
    body_class: Sym = .none,
};

pub const PackageInfo = struct {
    fqn: Name,
    /// Top-level declarations of every file in the package.
    members: NameIndex = .empty,
    subpackages: std.AutoHashMapUnmanaged(Name, Sym) = .empty,
};

pub const Symbols = struct {
    arena: Allocator,
    syms: std.ArrayList(Symbol) = .empty,
    classes: std.ArrayList(ClassInfo) = .empty,
    functions: std.ArrayList(FunctionInfo) = .empty,
    properties: std.ArrayList(PropertyInfo) = .empty,
    params: std.ArrayList(ParamInfo) = .empty,
    locals: std.ArrayList(LocalInfo) = .empty,
    type_params: std.ArrayList(TypeParamInfo) = .empty,
    aliases: std.ArrayList(TypeAliasInfo) = .empty,
    entries: std.ArrayList(EnumEntryInfo) = .empty,
    packages: std.ArrayList(PackageInfo) = .empty,
    /// Every classifier by fully qualified name.
    by_fqn: std.AutoHashMapUnmanaged(Name, Sym) = .empty,
    /// Every package by fully qualified name.
    package_by_fqn: std.AutoHashMapUnmanaged(Name, Sym) = .empty,
    root_package: Sym = .none,

    pub fn init(arena: Allocator) Allocator.Error!Symbols {
        var s = Symbols{ .arena = arena };
        // Index 0 is `Sym.none`.
        try s.syms.append(arena, .{ .kind = .package, .name = .empty, .owner = .none, .file = NO_FILE, .flags = .{}, .decl = .none, .detail = 0 });
        return s;
    }

    pub fn get(self: *const Symbols, s: Sym) *const Symbol {
        return &self.syms.items[s.int()];
    }

    pub fn getMut(self: *Symbols, s: Sym) *Symbol {
        return &self.syms.items[s.int()];
    }

    pub fn kind(self: *const Symbols, s: Sym) Kind {
        return self.syms.items[s.int()].kind;
    }

    pub fn name(self: *const Symbols, s: Sym) Name {
        return self.syms.items[s.int()].name;
    }

    pub fn owner(self: *const Symbols, s: Sym) Sym {
        return self.syms.items[s.int()].owner;
    }

    pub fn flags(self: *const Symbols, s: Sym) Flags {
        return self.syms.items[s.int()].flags;
    }

    pub fn count(self: *const Symbols) usize {
        return self.syms.items.len;
    }

    fn push(self: *Symbols, sym: Symbol) Allocator.Error!Sym {
        const id = Sym.from(@intCast(self.syms.items.len));
        try self.syms.append(self.arena, sym);
        return id;
    }

    pub fn addPackage(self: *Symbols, simple: Name, fqn: Name, parent: Sym) Allocator.Error!Sym {
        const detail: u32 = @intCast(self.packages.items.len);
        try self.packages.append(self.arena, .{ .fqn = fqn });
        const id = try self.push(.{ .kind = .package, .name = simple, .owner = parent, .file = NO_FILE, .flags = .{}, .decl = .none, .detail = detail });
        try self.package_by_fqn.put(self.arena, fqn, id);
        if (parent != .none) try self.packageInfo(parent).subpackages.put(self.arena, simple, id);
        return id;
    }

    pub fn addClass(self: *Symbols, sym: Symbol, info: ClassInfo) Allocator.Error!Sym {
        var s = sym;
        s.kind = .class;
        s.detail = @intCast(self.classes.items.len);
        try self.classes.append(self.arena, info);
        const id = try self.push(s);
        return id;
    }

    pub fn addFunction(self: *Symbols, sym: Symbol, info: FunctionInfo) Allocator.Error!Sym {
        var s = sym;
        std.debug.assert(s.kind == .function or s.kind == .constructor);
        s.detail = @intCast(self.functions.items.len);
        try self.functions.append(self.arena, info);
        return self.push(s);
    }

    pub fn addProperty(self: *Symbols, sym: Symbol, info: PropertyInfo) Allocator.Error!Sym {
        var s = sym;
        s.kind = .property;
        s.detail = @intCast(self.properties.items.len);
        try self.properties.append(self.arena, info);
        return self.push(s);
    }

    pub fn addParam(self: *Symbols, sym: Symbol, info: ParamInfo) Allocator.Error!Sym {
        var s = sym;
        s.kind = .value_param;
        s.detail = @intCast(self.params.items.len);
        try self.params.append(self.arena, info);
        return self.push(s);
    }

    pub fn addLocal(self: *Symbols, sym: Symbol, info: LocalInfo) Allocator.Error!Sym {
        var s = sym;
        s.kind = .local;
        s.detail = @intCast(self.locals.items.len);
        try self.locals.append(self.arena, info);
        return self.push(s);
    }

    pub fn addTypeParam(self: *Symbols, sym: Symbol, info: TypeParamInfo) Allocator.Error!Sym {
        var s = sym;
        s.kind = .type_param;
        s.detail = @intCast(self.type_params.items.len);
        try self.type_params.append(self.arena, info);
        return self.push(s);
    }

    pub fn addAlias(self: *Symbols, sym: Symbol, info: TypeAliasInfo) Allocator.Error!Sym {
        var s = sym;
        s.kind = .type_alias;
        s.detail = @intCast(self.aliases.items.len);
        try self.aliases.append(self.arena, info);
        return self.push(s);
    }

    pub fn addEntry(self: *Symbols, sym: Symbol, info: EnumEntryInfo) Allocator.Error!Sym {
        var s = sym;
        s.kind = .enum_entry;
        s.detail = @intCast(self.entries.items.len);
        try self.entries.append(self.arena, info);
        return self.push(s);
    }

    pub fn classInfo(self: *Symbols, s: Sym) *ClassInfo {
        const sym = self.get(s);
        std.debug.assert(sym.kind == .class);
        return &self.classes.items[sym.detail];
    }

    pub fn functionInfo(self: *Symbols, s: Sym) *FunctionInfo {
        const sym = self.get(s);
        std.debug.assert(sym.kind == .function or sym.kind == .constructor);
        return &self.functions.items[sym.detail];
    }

    pub fn propertyInfo(self: *Symbols, s: Sym) *PropertyInfo {
        const sym = self.get(s);
        std.debug.assert(sym.kind == .property);
        return &self.properties.items[sym.detail];
    }

    pub fn paramInfo(self: *Symbols, s: Sym) *ParamInfo {
        const sym = self.get(s);
        std.debug.assert(sym.kind == .value_param);
        return &self.params.items[sym.detail];
    }

    pub fn localInfo(self: *Symbols, s: Sym) *LocalInfo {
        const sym = self.get(s);
        std.debug.assert(sym.kind == .local);
        return &self.locals.items[sym.detail];
    }

    pub fn typeParamInfo(self: *Symbols, s: Sym) *TypeParamInfo {
        const sym = self.get(s);
        std.debug.assert(sym.kind == .type_param);
        return &self.type_params.items[sym.detail];
    }

    pub fn aliasInfo(self: *Symbols, s: Sym) *TypeAliasInfo {
        const sym = self.get(s);
        std.debug.assert(sym.kind == .type_alias);
        return &self.aliases.items[sym.detail];
    }

    pub fn entryInfo(self: *Symbols, s: Sym) *EnumEntryInfo {
        const sym = self.get(s);
        std.debug.assert(sym.kind == .enum_entry);
        return &self.entries.items[sym.detail];
    }

    pub fn packageInfo(self: *Symbols, s: Sym) *PackageInfo {
        const sym = self.get(s);
        std.debug.assert(sym.kind == .package);
        return &self.packages.items[sym.detail];
    }

    /// Records `member` under `n` in `index`.
    pub fn indexMember(self: *Symbols, index: *NameIndex, n: Name, member: Sym) Allocator.Error!void {
        const gop = try index.getOrPut(self.arena, n);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.arena, member);
    }

    /// The members `index` declares under `n`.
    pub fn members(index: *const NameIndex, n: Name) []const Sym {
        if (index.getPtr(n)) |list| return list.items;
        return &.{};
    }

    /// The class `s` is declared in, walking out through functions and
    /// properties; `.none` at the top level.
    pub fn enclosingClass(self: *const Symbols, s: Sym) Sym {
        var cur = self.owner(s);
        while (cur != .none) {
            const k = self.kind(cur);
            if (k == .class) return cur;
            if (k == .package) return .none;
            cur = self.owner(cur);
        }
        return .none;
    }

    /// The package `s` is declared in.
    pub fn packageOf(self: *const Symbols, s: Sym) Sym {
        var cur = s;
        while (cur != .none and self.kind(cur) != .package) cur = self.owner(cur);
        return cur;
    }
};

test "symbols get dense ids and per-kind details" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var names = try names_mod.Names.init(arena.allocator());
    var syms = try Symbols.init(arena.allocator());
    const kotlin = try syms.addPackage(names_mod.wk.kotlin, names_mod.wk.kotlin, .none);
    const any_fqn = try names.intern("kotlin.Any");
    const any = try syms.addClass(.{ .kind = .class, .name = names_mod.wk.Any, .owner = kotlin, .file = NO_FILE, .flags = .{ .modality = .open }, .decl = .none, .detail = 0 }, .{ .kind = .class, .fqn = any_fqn });
    try std.testing.expect(any != .none);
    try std.testing.expectEqual(Kind.class, syms.kind(any));
    try std.testing.expectEqual(any_fqn, syms.classInfo(any).fqn);
    try std.testing.expectEqual(kotlin, syms.packageOf(any));
    try syms.indexMember(&syms.packageInfo(kotlin).members, names_mod.wk.Any, any);
    try std.testing.expectEqualSlices(Sym, &.{any}, Symbols.members(&syms.packageInfo(kotlin).members, names_mod.wk.Any));
}
