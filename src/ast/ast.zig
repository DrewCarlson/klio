//! Kotlin AST.
const std = @import("std");
const span = @import("span");

pub const Span = span.Span;

pub const Ident = struct {
    name: []const u8,
    span: Span,
};

/// Source-declared visibility; an omitted modifier means `Public`.
pub const Visibility = enum {
    Public,
    Private,
    Protected,
    Internal,

    pub const default: Visibility = .Public;
};

/// Use-site target of an annotation (`@field:Foo`, `@get:Bar`). `None`
/// means the source wrote a plain `@Foo` with no explicit target.
pub const AnnotationUseSite = enum {
    Field,
    Property,
    Get,
    Set,
    Receiver,
    Param,
    SetParam,
    Delegate,
    File,
    /// `@all:Foo`: expands over every applicable anchor of a property (ctor
    /// parameter, property, backing field, getter, setter parameter). See
    /// `annotation_targets.expandAll`.
    All,
};

/// `@Target` derivation, `@all:` expansion, and the defaulting rule for
/// target-less property annotations.
pub const annotation_targets = @import("annotation_targets.zig");
pub const alias_expand = @import("alias_expand.zig");

/// A single `@Foo(args)` / `@use-site:Foo` annotation at a declaration site.
/// Argument values are parsed but stay opaque to downstream passes.
pub const Annotation = struct {
    use_site: ?AnnotationUseSite,
    path: []Ident,
    type_args: []TypeRef,
    args: []Expr,
    arg_names: []?[]const u8,
    span: Span,
};

/// Whether an accessor body reads or writes the backing `field`. A shape the
/// walk does not cover answers false, erring toward "no backing field".
pub fn accessorUsesField(a: *const Accessor) bool {
    return switch (a.body) {
        .Block => |b| blockUsesField(&b),
        .Expr => |e| exprUsesField(&e),
    };
}

pub fn blockUsesField(b: *const Block) bool {
    for (b.stmts) |s| {
        const hit = switch (s) {
            .Expr => |*e| exprUsesField(e),
            .Assign => |a| exprUsesField(&a.target) or exprUsesField(&a.value),
            .Decl => |d| switch (d) {
                .Property => |p| if (p.init) |*i| exprUsesField(i) else false,
                else => false,
            },
            else => false,
        };
        if (hit) return true;
    }
    return false;
}

pub fn exprUsesField(e: *const Expr) bool {
    return switch (e.*) {
        .Path => |p| p.segments.len == 1 and std.mem.eql(u8, p.segments[0].name, "field"),
        .Block => |b| blockUsesField(&b),
        .If => |i| exprUsesField(i.cond) or exprUsesField(i.then_branch) or
            (if (i.else_branch) |eb| exprUsesField(eb) else false),
        .When => |w| (if (w.subject) |s| exprUsesField(s) else false) or blk: {
            for (w.branches) |*b| {
                if (exprUsesField(&b.body)) break :blk true;
            }
            break :blk false;
        },
        .Call => |c| exprUsesField(c.callee) or blk: {
            for (c.args) |*a| if (exprUsesField(a)) break :blk true;
            break :blk false;
        },
        .Index => |x| blk: {
            if (exprUsesField(x.receiver)) break :blk true;
            for (x.args) |*a| if (exprUsesField(a)) break :blk true;
            break :blk false;
        },
        .Binary => |b| exprUsesField(b.lhs) or exprUsesField(b.rhs),
        .Return => |r| if (r.value) |v| exprUsesField(v) else false,
        .Member => |m| exprUsesField(m.receiver),
        .Unary => |x| exprUsesField(x.expr),
        .Postfix => |x| exprUsesField(x.expr),
        .As => |x| exprUsesField(x.expr),
        .IsCheck => |x| exprUsesField(x.expr),
        .Spread => |x| exprUsesField(x.expr),
        .Labeled => |x| exprUsesField(x.expr),
        else => false,
    };
}

pub const KotlinFile = struct {
    package: ?PackageHeader,
    imports: []ImportDecl,
    decls: []Decl,
    span: Span,
    /// `@file:` annotations in source order.
    file_annotations: []Annotation = &.{},
};

fn rewriteAliasedTypeName(ty: *TypeRef, aliases: *const std.StringHashMap([]const u8)) void {
    if (ty.function != null) return;
    if (aliases.get(ty.name.name)) |target| ty.name.name = target;
}

fn expandAliasesInDecls(decls: []Decl, aliases: *const std.StringHashMap([]const u8)) void {
    for (decls) |*d| {
        switch (d.*) {
            .Function => |*f| {
                for (f.params) |*p| rewriteAliasedTypeName(&p.ty, aliases);
                if (f.receiver_type) |*rt| rewriteAliasedTypeName(rt, aliases);
                if (f.return_type) |*rt| rewriteAliasedTypeName(rt, aliases);
            },
            .Class => |*c| {
                for (c.primary_params) |*p| rewriteAliasedTypeName(&p.ty, aliases);
                expandAliasesInDecls(c.members, aliases);
            },
            .Object => |*o| expandAliasesInDecls(o.members, aliases),
            else => {},
        }
    }
}

/// Replace this file's class typealiases with their underlying class in every
/// function signature (params, receiver, return) and constructor parameter.
/// A typealias is file-scoped in Kotlin, so it must be resolved here, where it
/// is unambiguously in scope; the flat global name table used at dispatch time
/// would otherwise let a same-simple-name class from another module capture the
/// parameter. Mutates `file.decls` in place; call right after parsing.
pub fn expandFileClassAliases(allocator: std.mem.Allocator, file: *KotlinFile) void {
    var aliases = std.StringHashMap([]const u8).init(allocator);
    defer aliases.deinit();
    for (file.decls) |*d| {
        if (d.* != .TypeAlias) continue;
        const ta = &d.TypeAlias;
        if (ta.target.function != null) continue;
        if (ta.target.name.name.len == 0) continue;
        if (std.mem.eql(u8, ta.target.name.name, ta.name.name)) continue;
        aliases.put(ta.name.name, ta.target.name.name) catch return;
    }
    if (aliases.count() == 0) return;
    expandAliasesInDecls(file.decls, &aliases);
}

pub const PackageHeader = struct {
    path: []Ident,
    span: Span,
};

pub const ImportDecl = struct {
    path: []Ident,
    alias: ?Ident,
    wildcard: bool,
    span: Span,
};

/// One entry of a `context(name: Type, ...)` clause. A `name` of `"_"` is
/// anonymous: it participates in context resolution but is not accessible by
/// name.
pub const ContextParam = struct {
    name: Ident,
    ty: TypeRef,
    span: Span,
};

pub const Decl = union(enum) {
    Function: Function,
    /// Boxed: `Property` is the largest variant (~1.7 KB), so the pointer keeps
    /// every other `Decl` slot small, and the heap-stable pointee keeps interior
    /// pointers (`ClassDef.body_properties` -> `&property.getter`) valid.
    Property: *Property,
    Class: Class,
    Object: ObjectDecl,
    /// `typealias Name[<Tp>] = Type`. Transparent at use sites: typeck unfolds
    /// it to the underlying type, type-args substituted, before any subtype or
    /// member-lookup work.
    TypeAlias: TypeAlias,
};

pub const TypeAlias = struct {
    name: Ident,
    type_params: []TypeParam,
    target: TypeRef,
    visibility: Visibility,
    annotations: []Annotation,
    span: Span,
};

pub const Function = struct {
    name: Ident,
    /// Receiver type of an extension function `fun T.foo(...)`; `None` for
    /// member and top-level functions. Bound as `this` inside the body.
    receiver_type: ?TypeRef,
    /// `context(a: A, b: B)` clause. Context parameters are in scope by name,
    /// never as implicit receivers, and are filled implicitly at call sites.
    context_params: []ContextParam = &.{},
    type_params: []TypeParam,
    where_bounds: []WhereBound,
    params: []Param,
    return_type: ?TypeRef,
    body: ?FunctionBody,
    is_open: bool,
    is_override: bool,
    /// Declared `final`. Meaningful on an `override` member, which is open by
    /// default: `final override fun` seals it against further overrides.
    /// Redundant but legal on a plain member.
    is_final: bool = false,
    /// Declared `abstract`: the function may have `body: None` and must live on
    /// an abstract class or an interface.
    is_abstract: bool,
    /// Declared `operator`. Required by Kotlin on functions that participate in
    /// operator dispatch, notably delegate `getValue` / `setValue`.
    is_operator: bool,
    is_inline: bool,
    /// Declared `infix`. Required for use at an infix call site `a foo b`.
    is_infix: bool,
    is_tailrec: bool,
    /// Declared `suspend`: the body is a suspension-allowed context, and every
    /// call site must itself sit in a suspending context.
    is_suspend: bool,
    /// `expect fun`: bodyless declaration awaiting an `actual` from a native
    /// binding or a platform source. IR lowering is skipped and dispatch goes
    /// through the installed `actual`.
    is_expect: bool,
    /// `actual fun`: platform counterpart of an `expect` of the same signature.
    is_actual: bool,
    visibility: Visibility,
    annotations: []Annotation,
    span: Span,
};

/// Variance of a type parameter (declaration site) or type argument (use site).
pub const Variance = enum {
    Invariant,
    /// `out T`: covariant, T may appear in output positions.
    Out,
    /// `in T`: contravariant, T may appear in input positions.
    In,

    pub const default: Variance = .Invariant;
};

pub const TypeParam = struct {
    name: Ident,
    variance: Variance,
    /// Inline bound from the `<T : Foo>` form; combined with `where`-clause
    /// bounds during type checking.
    upper_bound: ?TypeRef,
    /// `reified T`, only meaningful on an `inline fun` type parameter.
    is_reified: bool,
    annotations: []Annotation,
    span: Span,
};

pub const WhereBound = struct {
    name: Ident,
    bound: TypeRef,
    span: Span,
};

/// Type argument inside a `<...>` instantiation. Records the projection (`*`,
/// `out X`, `in X`) so typeck can enforce use-site variance.
pub const TypeArg = struct {
    variance: Variance,
    /// `*` star-projection; `ty` is unused when set.
    is_star: bool,
    ty: TypeRef,
    span: Span,
};

pub const FunctionBody = union(enum) {
    Block: Block,
    Expr: Expr,
};

pub const Param = struct {
    name: Ident,
    ty: TypeRef,
    /// Boxed so an absent default costs a pointer rather than an inline `Expr`.
    /// `Expr` is a watched codec type, so the shared-graph codec follows the
    /// pointer and materialises the default only when present.
    default: ?*Expr,
    /// `vararg x: T`, collected at the call site into a typed array.
    is_vararg: bool,
    /// `crossinline` lambda parameter: non-local returns are forbidden in the
    /// body of the supplied lambda.
    is_crossinline: bool,
    /// `noinline` lambda parameter: not inlined, so it may be stored or passed
    /// on like any other value.
    is_noinline: bool,
    annotations: []Annotation,
    span: Span,
};

pub const Property = struct {
    mutable: bool,
    name: Ident,
    /// `context(a: A)` clause, belonging to the property as a whole: both
    /// accessors see the parameters. A contextual property has no backing field.
    context_params: []ContextParam = &.{},
    /// Receiver type of an extension property `val T.foo: U get() = ...`;
    /// `None` for member and top-level ones. An extension property has no
    /// initializer, delegate, or backing field.
    receiver_type: ?TypeRef,
    ty: ?TypeRef,
    init: ?Expr,
    /// `val foo: T by expr`; `init` is `None` when set. Boxed, since it is
    /// present on almost no property.
    delegate: ?*Expr,
    /// `val foo: T get() = ...`. Reads of `foo` go through this accessor. Boxed;
    /// `Accessor` is a watched codec type, so the shared-graph decoder follows
    /// the pointer and `PropertyDef.getter` resolves to the same heap node.
    getter: ?*Accessor,
    /// `var foo: T set(value) { ... }`; the parameter is named `value` when the
    /// source omits a name. Boxed.
    setter: ?*Accessor,
    /// Declared `abstract`, valid only on a member of an abstract class or an
    /// interface: no `init` and no accessor bodies.
    is_abstract: bool,
    /// Declared `open`; required before a subclass may `override` the property.
    is_open: bool,
    is_override: bool,
    /// `lateinit var name: T`: non-null `var` with no initializer. A read before
    /// the first write throws `kotlin.UninitializedPropertyAccessException`.
    is_lateinit: bool,
    /// `const val NAME = EXPR`. Allowed only at top level or inside an object;
    /// the initializer must be compile-time evaluable over primitive and
    /// `String` operands.
    is_const: bool,
    /// `inline val/var foo`: both accessors are inline and the property may have
    /// no backing field (no initializer, no `field`-using accessor).
    is_inline: bool,
    /// `expect val/var`: no initializer or getter body, awaiting an `actual`.
    is_expect: bool,
    /// `actual val/var`: supplies the body for the matching `expect`.
    is_actual: bool,
    /// Visibility from a bodyless `private set` / `protected set` on a `var`.
    /// `None` means the setter inherits the property's visibility.
    setter_visibility: ?Visibility,
    /// Explicit backing-field clause in the initializer slot. The field is the
    /// property's storage: reads inside the declaring scope see the field type,
    /// reads outside see the property type. Boxed, since it is present on almost
    /// no property.
    explicit_field: ?*ExplicitField = null,
    visibility: Visibility,
    annotations: []Annotation,
    span: Span,
};

/// `field[: Type][= init]` clause of a property declaration. Member and
/// top-level `val` properties only; rejected on constructor and local ones.
pub const ExplicitField = struct {
    /// Declared field type; inferred from `init` when omitted, else the
    /// property's own type.
    ty: ?TypeRef,
    /// Field initializer. When absent the field must be definitely assigned on
    /// every construction path.
    init: ?Expr,
    /// Span of the `field` keyword token.
    span: Span,
};

pub const Accessor = struct {
    /// The single `set(value)` parameter; empty for a getter.
    params: []Ident,
    /// Explicit return-type annotation (`get(): Int`). Typeck requires it to
    /// match the property's declared type.
    return_type: ?TypeRef,
    body: FunctionBody,
    /// Per-accessor visibility, as in `var x; private set`.
    visibility: ?Visibility,
    /// `inline get()` / `inline set(v)`: this accessor alone is inlined, whatever
    /// the other does. Distinct from `Property.is_inline`, which marks the whole
    /// declaration and inlines both accessors.
    is_inline: bool,
    annotations: []Annotation,
    span: Span,
};

pub const Class = struct {
    name: Ident,
    type_params: []TypeParam,
    where_bounds: []WhereBound,
    /// Primary-constructor parameters; entries marked `val`/`var` also become
    /// member properties on the instance.
    primary_params: []ClassParam,
    /// Whether the header declares a primary constructor. A class with none
    /// (`class A { constructor(...) }`) gains no implicit zero-argument
    /// constructor once it declares a secondary.
    has_primary_ctor: bool = true,
    /// `init { ... }` blocks in declaration order, run during construction
    /// interleaved with body-property initializers per `init_block_positions`,
    /// matching Kotlin's source-order rule.
    init_blocks: []Block,
    /// Position of each `init_blocks` entry in declaration order, counted as the
    /// number of `members` already seen when the block was parsed: an entry with
    /// position `N` runs before `members[N]`'s initializer and after everything
    /// positioned earlier. Same length as `init_blocks`.
    init_block_positions: []usize,
    supertypes: []TypeRef,
    /// Per entry of `supertypes`, the declaration-site constructor arguments
    /// (`: Bar(a, b)`). `None` means no `(...)` was written, an interface-style
    /// reference; an empty list is the explicit `: Bar()` form.
    supertype_args: []?[]Expr,
    /// Parallel to each `supertype_args` list: the parameter label of each
    /// argument (`: Bar(objects = 2)` -> `"objects"`), `null` when positional.
    /// Empty means no labels were captured, so every argument binds by position.
    supertype_arg_names: []const ?[]const ?[]const u8 = &.{},
    /// Per entry of `supertypes`, the `: I by expr` delegate, evaluated once at
    /// construction. `None` for plain and constructor-call supertypes.
    supertype_delegates: []?Expr,
    is_data: bool,
    is_companion: bool,
    /// `enum class`: `enum_entries` holds the entries in source order and
    /// `members` the declarations following the `;` separator.
    is_enum: bool,
    /// `sealed class` / `sealed interface`, consulted by the runtime subtype
    /// checks and by `when` exhaustiveness.
    is_sealed: bool,
    /// `open class`. Without `open`, `abstract` or `sealed`, a class is final.
    is_open: bool,
    /// `abstract class`: may declare abstract members and cannot be constructed
    /// directly. Implies `open`.
    is_abstract: bool,
    /// `inner class`, capturing an outer-instance reference. A plain nested
    /// class captures none.
    is_inner: bool,
    /// Secondary constructors, each delegating explicitly to another constructor
    /// of this class (`: this(args)`) or to the superclass (`: super(args)`).
    secondary_ctors: []SecondaryCtor,
    /// `interface Foo { ... }`. Members may be abstract or carry a default body.
    /// An interface is never the leaf class of an instance; implementors pick up
    /// its default methods and its `is`-check membership.
    is_interface: bool,
    /// `fun interface`: single-abstract-method interface, eligible for SAM
    /// conversion from a lambda.
    is_fun_interface: bool,
    /// `value class`, and its deprecated `inline class` alias: a single-field
    /// wrapper. Typeck enforces the shape; interp keeps a boxed representation.
    is_value: bool,
    /// `annotation class Foo(...)`. Typeck enforces the body and parameter-type
    /// constraints.
    is_annotation: bool,
    /// `expect class Foo`, awaiting an `actual class Foo`; bodies may be empty.
    is_expect: bool,
    /// `actual class Foo`, matched to an `expect class` by simple name.
    is_actual: bool,
    enum_entries: []EnumEntry,
    members: []Decl,
    visibility: Visibility,
    /// Visibility from the explicit `class Foo private constructor(...)` form.
    /// `None` means the primary constructor inherits the class visibility.
    primary_ctor_visibility: ?Visibility,
    annotations: []Annotation,
    span: Span,
};

pub const EnumEntry = struct {
    name: Ident,
    /// Constructor arguments, present when the enum declares a primary ctor.
    args: []Expr,
    /// Per argument, the parameter a named argument binds (`A(b = 1, a = 0)`);
    /// `null` for a positional argument.
    arg_names: []const ?[]const u8 = &.{},
    /// Per-entry body declarations; empty for a bare entry.
    body_members: []Decl,
    annotations: []Annotation,
    span: Span,
};

pub const ClassParam = struct {
    /// `None` when the parameter is not a property, `Some(true)` for `var`,
    /// `Some(false)` for `val`.
    property: ?bool,
    name: Ident,
    ty: TypeRef,
    default: ?Expr,
    visibility: Visibility,
    /// `vararg` on a primary-constructor parameter; forbidden when the
    /// enclosing class is a `data class`.
    is_vararg: bool,
    annotations: []Annotation,
    span: Span,
};

pub const SecondaryCtor = struct {
    params: []Param,
    delegation: CtorDelegation,
    /// Per delegation argument, the parameter a named argument binds; `null`
    /// for a positional one. Empty when no argument is named.
    delegation_arg_names: []const ?[]const u8 = &.{},
    body: ?Block,
    visibility: Visibility,
    annotations: []Annotation,
    span: Span,
};

pub const CtorDelegation = union(enum) {
    /// `: this(args)`, delegating to another constructor of this class.
    This: []Expr,
    /// `: super(args)`, delegating to a parent-class constructor. Valid only
    /// when the class has no primary constructor.
    Super: []Expr,
    /// No delegation header: implicit `: this()` when a primary constructor
    /// exists, otherwise implicit `: super()`.
    None,
};

pub const ObjectDecl = struct {
    name: Ident,
    supertypes: []TypeRef,
    members: []Decl,
    /// `init { ... }` blocks in declaration order, run when the singleton is
    /// constructed; see `Class.init_blocks`.
    init_blocks: []Block,
    /// Position of each `init_blocks` entry relative to `members`, with the
    /// ordering contract of `Class.init_block_positions`.
    init_block_positions: []usize,
    /// Per supertype, the constructor arguments (`object O : Foo(a, b)`);
    /// `None` when no `(args)` was written.
    supertype_args: []?[]Expr,
    /// Parallel to `supertype_args`: argument labels, `null` per positional
    /// argument. Empty means every argument binds by position.
    supertype_arg_names: []const ?[]const ?[]const u8 = &.{},
    /// Parallel to `supertypes`: the `by` delegate expression, `null` for a
    /// plain supertype. Empty when the declaration used no `by` clause.
    supertype_delegates: []?Expr = &.{},
    annotations: []Annotation = &.{},
    /// `data object Foo`: generates a `toString` returning the simple class
    /// name. Unlike `data class` there is no `copy` and no `componentN`, and
    /// user-declared `equals`/`hashCode` overrides are rejected.
    is_data: bool,
    /// `expect object`, whose actual definition comes from a platform source set.
    is_expect: bool,
    /// `actual object`, superseding a matching `expect object`.
    is_actual: bool,
    visibility: Visibility,
    span: Span,
};

pub const TypeRef = struct {
    name: Ident,
    nullable: bool,
    span: Span,
    /// Generic type arguments; empty for non-generic references and for a bare
    /// type-parameter name like `T`.
    type_args: []TypeArg,
    /// When set, this `TypeRef` denotes a function type `(P1, P2, ...) -> R`,
    /// optionally with a receiver. `name.name` then carries the synthetic tag
    /// `"<function>"` so name-based consumers treat it as unresolved, and
    /// `nullable` reflects whether the function type itself is nullable
    /// (`((Int) -> Int)?`).
    function: ?*FunctionTypeRef,
    /// `T & Any`, the definitely-non-nullable projection of a type parameter,
    /// set when the parser sees a `&`-joined right-hand `Any` after a user type.
    /// Typeck rejects the shape on non-type-parameter receivers; interp treats
    /// it as the base `T`.
    definitely_non_null: bool,
    annotations: []Annotation,
    /// Full dotted source path when the reference was written qualified
    /// (`Outer.Inner`, `a.b.C`), `None` otherwise. `name` keeps only the last
    /// segment, so this preserves the qualifier that distinguishes a nested
    /// supertype from a same-named top-level class.
    qualified_path: ?[]const u8,
};

/// Function type written as a type annotation, e.g. `(Int, String) -> Boolean`
/// or `Receiver.(Int) -> Unit`.
pub const FunctionTypeRef = struct {
    receiver: ?TypeRef,
    params: []TypeRef,
    ret: TypeRef,
    is_suspend: bool,
    /// Leading `context(A, B)` block of a contextual function type. Types only;
    /// named entries are rejected by the parser. Equivalent to the flattened
    /// function type `(A, B, R, P) -> T`.
    context_params: []TypeRef = &.{},
    span: Span,
};

pub const Block = struct {
    stmts: []Stmt,
    span: Span,
};

pub const Stmt = union(enum) {
    Expr: Expr,
    Decl: Decl,
    Assign: struct {
        target: Expr,
        op: AssignOp,
        value: Expr,
        span: Span,
    },
    /// `val (a, b, ...) = expr`. Each name receives `expr.componentN()`
    /// (1-indexed); a name of `_` evaluates its component for effect without
    /// binding.
    DestructuringDecl: struct {
        mutable: bool,
        names: []Ident,
        /// Name-based form `(val a, val n = prop) = x`: each name reads the
        /// property of its own name unless renamed with `=`. Positional forms
        /// (`(a, b)`, `[a, b]`) read `componentN`.
        by_name: bool = false,
        sources: []Ident = &.{},
        init: Expr,
        span: Span,
    },
};

pub const AssignOp = enum {
    Assign,
    Add,
    Sub,
    Mul,
    Div,
    Rem,
};

/// Suffix-derived kind of an integer literal: `1` is `Int`, `1L` is `Long`,
/// `1u` is `UInt`, `1uL` is `ULong`. Drives both the runtime variant and the
/// literal's static type.
pub const IntLitKind = enum {
    Int,
    Long,
    UInt,
    ULong,

    pub const default: IntLitKind = .Int;
};

/// Suffix-derived kind of a float literal: `1.0` is `Double`, `1.0f` is `Float`.
pub const FloatLitKind = enum {
    Double,
    Float,

    pub const default: FloatLitKind = .Double;
};

pub const Expr = union(enum) {
    IntLit: struct {
        value: i64,
        kind: IntLitKind,
        span: Span,
    },
    FloatLit: struct {
        value: f64,
        kind: FloatLitKind,
        span: Span,
    },
    BoolLit: struct {
        value: bool,
        span: Span,
    },
    NullLit: struct {
        span: Span,
    },
    CharLit: struct {
        value: u16,
        span: Span,
    },
    StringTemplate: struct {
        parts: []StringPart,
        span: Span,
    },
    Path: struct {
        segments: []Ident,
        span: Span,
    },
    Member: struct {
        receiver: *Expr,
        name: Ident,
        safe: bool,
        span: Span,
    },
    /// `callee(args)`. `arg_names` is parallel to `args`: `Some(label)` where
    /// the source wrote `label = arg`, `None` where it is positional, and the
    /// interpreter reorders against the callee's parameter list. `type_args`
    /// carries explicit call-site type arguments (`foo<String>(...)`), consumed
    /// by reified type parameters.
    Call: struct {
        callee: *Expr,
        args: []Expr,
        arg_names: []?[]const u8,
        type_args: []TypeRef,
        /// Set when the source wrote `a name b` rather than `name(a, b)`;
        /// typeck then requires the callee to carry the `infix` modifier.
        is_infix: bool,
        /// Set when the final argument came as a trailing lambda (`f(x) { ... }`),
        /// which Kotlin binds to the LAST parameter. A parenthesized `f(x, { ... })`
        /// binds positionally and leaves this false.
        has_trailing_lambda: bool = false,
        /// Set when parentheses enclose the whole call expression, so a
        /// following lambda invokes the call's result.
        grouped: bool = false,
        span: Span,
    },
    Index: struct {
        receiver: *Expr,
        args: []Expr,
        span: Span,
    },
    Binary: struct {
        op: BinOp,
        lhs: *Expr,
        rhs: *Expr,
        span: Span,
    },
    Unary: struct {
        op: UnOp,
        expr: *Expr,
        span: Span,
    },
    Postfix: struct {
        op: PostfixOp,
        expr: *Expr,
        span: Span,
    },
    If: struct {
        cond: *Expr,
        then_branch: *Expr,
        else_branch: ?*Expr,
        span: Span,
    },
    While: struct {
        cond: *Expr,
        body: *Expr,
        span: Span,
    },
    /// `do body while (cond)`: the body always runs at least once. The body is
    /// optional to cover the `do; while (c)` form.
    DoWhile: struct {
        body: ?*Expr,
        cond: *Expr,
        span: Span,
    },
    /// `for (vars in iter) body`. `vars` holds one name normally and two or more
    /// for a destructuring `for ((k, v) in m)`, where each iteration element
    /// supplies the matching component (`Pair`, `Map.Entry`, or `componentN`).
    For: struct {
        vars: []Ident,
        /// `for ((val k, val v) in xs)`: name-based, see `DestructuringDecl`.
        by_name: bool = false,
        /// Set when the source wrote a `(...)`/`[...]` group, even a one-element
        /// one: `for ([b] in xs)` calls `component1()`, while `for (x in xs)`
        /// binds the element itself.
        destructured: bool = false,
        var_sources: []Ident = &.{},
        var_ty: ?TypeRef,
        iter: *Expr,
        body: *Expr,
        span: Span,
    },
    Return: struct {
        value: ?*Expr,
        label: ?Ident,
        span: Span,
    },
    Break: struct {
        label: ?Ident,
        span: Span,
    },
    Continue: struct {
        label: ?Ident,
        span: Span,
    },
    /// `label@ expr`, binding the jump target for `return@label`,
    /// `break@label` and `continue@label` within `expr`.
    Labeled: struct {
        label: Ident,
        expr: *Expr,
        span: Span,
    },
    Block: Block,
    Throw: struct {
        value: *Expr,
        span: Span,
    },
    Try: struct {
        body: Block,
        catches: []Catch,
        finally: ?Block,
        span: Span,
    },
    Lambda: struct {
        params: []Ident,
        /// Declared parameter type annotations (`{ s: String -> ... }`), aligned
        /// with `params`, `null` per unannotated slot. Empty when the literal
        /// declares no header. Runtime overload dispatch matches against these.
        param_tys: []?TypeRef = &.{},
        /// Annotations on the literal itself (`@Composable { ... }`). A runtime
        /// no-op, read by the compose pass to transform an annotated literal
        /// bound to an untyped val.
        annotations: []Annotation = &.{},
        body: Block,
        span: Span,
        /// Set when the parser injected the single `it` parameter for a
        /// zero-`->` lambda. The real arity then comes from the expected type:
        /// `{ x() }` is `() -> R` in a value position but `(T) -> R` where one
        /// parameter is expected.
        implicit_it: bool = false,
    },
    /// `this` or `this@Label`. The qualifier names an enclosing outer-class
    /// instance, as in `this@Outer` from inside an inner class.
    This: struct {
        qualifier: ?Ident,
        span: Span,
    },
    /// `super`, meaningful only as the receiver of `super.foo` /
    /// `super.foo(...)`, which resolves against the owning class's parent.
    /// `qualifier` carries `super<Base>.foo()`, required when several supertypes
    /// supply a matching member; `label` carries `super@Outer.foo()`, which
    /// dispatches through the outer class's parent rather than the inner
    /// class's. Both are `None` for a bare `super`.
    Super: struct {
        qualifier: ?TypeRef,
        label: ?Ident,
        span: Span,
    },
    /// `::foo`, a callable or property reference to a top-level or in-scope
    /// name. The runtime value exposes `.name` and `.get()`.
    PropertyRef: struct {
        name: Ident,
        span: Span,
    },
    /// `Receiver::name`. The receiver is a class (`Foo::method`, `Foo::class`)
    /// or an instance (`obj::method`); evaluation depends on which.
    MemberRef: struct {
        receiver: *Expr,
        name: Ident,
        span: Span,
    },
    /// `when` expression. `subject` is `Some` for the subject-bound form
    /// `when (x) { ... }` and `None` for `when { cond -> ... }`. Branches are
    /// tried in order and the first match supplies the result; with no match and
    /// no `else`, evaluation throws `kotlin.NoWhenBranchMatchedException`.
    When: struct {
        subject: ?*Expr,
        subject_binding: ?WhenBinding,
        branches: []WhenBranch,
        span: Span,
    },
    /// `expr is Type` / `expr !is Type`. `negated` is `true` for `!is`.
    IsCheck: struct {
        expr: *Expr,
        ty: TypeRef,
        negated: bool,
        span: Span,
    },
    /// `expr as Type` / `expr as? Type`. Under `safe` a failed runtime cast
    /// yields `null` instead of throwing `kotlin.ClassCastException`.
    As: struct {
        expr: *Expr,
        ty: TypeRef,
        safe: bool,
        span: Span,
    },
    /// Anonymous function expression `fun(x: Int): Int = x + 1`. A `return` in
    /// the body leaves this function, not the enclosing one.
    AnonFun: struct {
        receiver_ty: ?TypeRef,
        /// `context(x: A) fun (...)`: the body binds each context name from the
        /// context stack at entry, as a declared context function does.
        context_params: []ContextParam = &.{},
        params: []Param,
        return_ty: ?TypeRef,
        body: ?*FunctionBody,
        is_suspend: bool,
        span: Span,
    },
    /// `*expr`, spreading an array into a `vararg` parameter. Valid only as a
    /// top-level value argument, mixed with positional ones; typeck rejects it
    /// when the bound parameter is not `vararg`.
    Spread: struct {
        expr: *Expr,
        span: Span,
    },
    /// Anonymous object expression: `object { ... }`, `object : Foo { ... }`,
    /// `object : Parent(args), Iface { ... }`. Captures the enclosing scope for
    /// method bodies; each occurrence produces a fresh `ClassDef` and one
    /// instance.
    ObjectExpr: struct {
        supertypes: []TypeRef,
        supertype_args: []?[]Expr,
        supertype_arg_names: []const ?[]const ?[]const u8 = &.{},
        supertype_delegates: []?Expr,
        members: []Decl,
        /// `init { ... }` blocks in declaration order; see `Class.init_blocks`.
        init_blocks: []Block,
        /// Position of each `init_blocks` entry relative to `members`, with the
        /// ordering contract of `Class.init_block_positions`.
        init_block_positions: []usize,
        span: Span,
    },

    pub fn span(self: *const Expr) Span {
        return switch (self.*) {
            .IntLit => |e| e.span,
            .FloatLit => |e| e.span,
            .BoolLit => |e| e.span,
            .NullLit => |e| e.span,
            .CharLit => |e| e.span,
            .StringTemplate => |e| e.span,
            .Path => |e| e.span,
            .Member => |e| e.span,
            .Call => |e| e.span,
            .Index => |e| e.span,
            .Binary => |e| e.span,
            .Unary => |e| e.span,
            .Postfix => |e| e.span,
            .If => |e| e.span,
            .While => |e| e.span,
            .DoWhile => |e| e.span,
            .For => |e| e.span,
            .Return => |e| e.span,
            .Break => |e| e.span,
            .Continue => |e| e.span,
            .Labeled => |e| e.span,
            .Throw => |e| e.span,
            .Try => |e| e.span,
            .Lambda => |e| e.span,
            .This => |e| e.span,
            .Super => |e| e.span,
            .PropertyRef => |e| e.span,
            .MemberRef => |e| e.span,
            .When => |e| e.span,
            .IsCheck => |e| e.span,
            .As => |e| e.span,
            .AnonFun => |e| e.span,
            .Spread => |e| e.span,
            .ObjectExpr => |e| e.span,
            .Block => |b| b.span,
        };
    }
};

/// `when (val name: Ty = subject)`, binding `name` to the subject's value for
/// the branches. `ty` is `None` when the source omitted the annotation.
pub const WhenBinding = struct {
    name: Ident,
    ty: ?TypeRef,
    annotations: []Annotation,
    span: Span,
};

pub const WhenBranch = struct {
    /// Comma-separated patterns left of `->`; the branch fires when any of them
    /// matches. An `Else` pattern may only appear alone.
    patterns: []WhenPattern,
    body: Expr,
    span: Span,
};

pub const WhenPattern = struct {
    kind: WhenPatternKind,
    span: Span,
};

pub const WhenPatternKind = union(enum) {
    /// Equality match against the subject, or a Boolean condition in a
    /// subject-free `when`.
    Value: Expr,
    /// `in expr`: `subject in expr` membership.
    InRange: Expr,
    /// `!in expr`: `subject !in expr` membership.
    NotInRange: Expr,
    /// `is Type`. Implies a smart cast for the branch body when the subject is
    /// a single identifier.
    IsType: TypeRef,
    NotIsType: TypeRef,
    /// `else` fallthrough; valid only as the sole pattern of its branch.
    Else,
};

pub const Catch = struct {
    binding: Ident,
    ty: TypeRef,
    body: Block,
    span: Span,
};

pub const StringPart = union(enum) {
    Text: []const u8,
    ShortInterp: Ident,
    /// Boxed so a `StringPart` stays pointer-sized rather than `Expr`-sized;
    /// most parts are plain `Text`. `Expr` is a watched codec type.
    Interp: *Expr,
};

pub const BinOp = enum {
    Add,
    Sub,
    Mul,
    Div,
    Rem,
    Eq,
    Neq,
    IdentEq,
    IdentNeq,
    Lt,
    Le,
    Gt,
    Ge,
    In,
    NotIn,
    And,
    Or,
    Range,
    RangeUntil,
    Elvis,
    Assign,
};

pub const UnOp = enum {
    Neg,
    Pos,
    Not,
    PreInc,
    PreDec,
};

pub const PostfixOp = enum {
    Inc,
    Dec,
    NotNull,
};

test "expr span returns inline-variant span" {
    const f = span.FileId.from(0);
    const s = Span.init(f, 3, 7);
    const e = Expr{ .IntLit = .{ .value = 42, .kind = .Int, .span = s } };
    try std.testing.expect(e.span().eql(s));
}

test "expr span returns block span" {
    const f = span.FileId.from(0);
    const s = Span.init(f, 1, 9);
    const e = Expr{ .Block = .{ .stmts = &.{}, .span = s } };
    try std.testing.expect(e.span().eql(s));
}

test "enum defaults match kotlin source defaults" {
    try std.testing.expectEqual(Visibility.Public, Visibility.default);
    try std.testing.expectEqual(Variance.Invariant, Variance.default);
    try std.testing.expectEqual(IntLitKind.Int, IntLitKind.default);
    try std.testing.expectEqual(FloatLitKind.Double, FloatLitKind.default);
}

test "recursive expr nodes box through pointers" {
    const f = span.FileId.from(0);
    var lit = Expr{ .IntLit = .{ .value = 1, .kind = .Int, .span = Span.init(f, 0, 1) } };
    const u = Expr{ .Unary = .{ .op = .Neg, .expr = &lit, .span = Span.init(f, 0, 2) } };
    try std.testing.expectEqual(UnOp.Neg, u.Unary.op);
    try std.testing.expectEqual(@as(i64, 1), u.Unary.expr.IntLit.value);
}

test {
    _ = annotation_targets;
    _ = alias_expand;
}
