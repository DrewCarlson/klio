//! Kotlin AST.
const std = @import("std");
const span = @import("span");

pub const Span = span.Span;

pub const Ident = struct {
    name: []const u8,
    span: Span,
};

/// Source-declared visibility modifier for a declaration. Defaults to
/// `Public` when the source omits a modifier, matching Kotlin's default.
pub const Visibility = enum {
    Public,
    Private,
    Protected,
    Internal,

    pub const default: Visibility = .Public;
};

/// Use-site target for a declaration-site annotation, e.g. `@field:Foo`,
/// `@get:Bar`. `None` on an `Annotation` means the source wrote a plain
/// `@Foo` with no explicit target.
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
    /// `@all:Foo` — the property meta-target: expands over every
    /// applicable anchor of a member/top-level property (constructor
    /// parameter, the property, its backing field, getter, and setter
    /// parameter). See `annotation_targets.expandAll`.
    All,
};

/// Use-site targeting machinery: U(A) derivation from `@Target`, `@all:`
/// expansion, and the defaulting rule for target-less property annotations.
pub const annotation_targets = @import("annotation_targets.zig");

/// A single `@Foo(args)` / `@use-site:Foo` annotation at a declaration
/// site. Values inside are parsed best-effort; downstream passes treat
/// them as opaque for now.
pub const Annotation = struct {
    use_site: ?AnnotationUseSite,
    path: []Ident,
    type_args: []TypeRef,
    args: []Expr,
    arg_names: []?[]const u8,
    span: Span,
};

/// Whether an accessor body reads or writes the backing `field`. The walk
/// covers the statement/expression shapes accessor bodies actually use; an
/// exotic shape answers false, which errs toward "no backing field".
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
    /// `@file:` annotations (`@file:UseSerializers(...)`,
    /// `@file:UseContextualSerialization(...)`), in source order.
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

/// Expand this file's class typealiases in every function signature the file
/// declares (params, receiver, return) and in constructor parameters. A
/// `private typealias Node = LockFreeLinkedListNode` is file-scoped in Kotlin,
/// so resolving it here — where the alias is unambiguously in scope — replaces
/// the bare simple name with the concrete class. Otherwise a same-simple-name
/// real class in another module (compose's `Modifier.Node` vs kotlinx's
/// `typealias Node`) can capture the param through the flat global name table
/// at dispatch time. Mutates `file.decls` in place; call right after parsing a
/// file that will be lowered.
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

/// One entry of a `context(name: Type, ...)` modifier clause on a
/// function or property declaration. A `name` of `"_"` declares an
/// anonymous context parameter: it participates in context resolution
/// but is not accessible by name.
pub const ContextParam = struct {
    name: Ident,
    ty: TypeRef,
    span: Span,
};

pub const Decl = union(enum) {
    Function: Function,
    /// Boxed: `Property` is the largest variant (its inline `init`/`delegate`/
    /// `getter`/`setter` make it ~1.7 KB), so storing it behind a pointer keeps
    /// every other `Decl` slot small. The pointee is heap-stable, so interior
    /// pointers into it (e.g. `ClassDef.body_properties` -> `&property.getter`)
    /// stay valid.
    Property: *Property,
    Class: Class,
    /// Standalone `object Foo { … }` singleton.
    Object: ObjectDecl,
    /// `typealias Name[<Tp>] = Type`. Aliases are transparent at use sites:
    /// the type checker unfolds them to the underlying type with type-args
    /// substituted before any subtype / member-lookup work.
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
    /// Receiver type for an extension function declared as
    /// `fun T.foo(...)`. `None` for regular and member functions. The
    /// interpreter binds the call-site receiver as `this` inside the
    /// body; the type checker walks the receiver's class chain to find
    /// matching extensions at member-call sites.
    receiver_type: ?TypeRef,
    /// `context(a: A, b: B)` modifier clause. Context parameters are in
    /// scope by name in the body (never as implicit receivers) and are
    /// filled implicitly at call sites from the enclosing scope tower.
    context_params: []ContextParam = &.{},
    /// Generic type parameters declared on this function: `fun <T> id(x: T): T`.
    type_params: []TypeParam,
    /// `where` clause bounds: `fun <T> foo() where T : Foo, T : Bar`.
    where_bounds: []WhereBound,
    params: []Param,
    return_type: ?TypeRef,
    body: ?FunctionBody,
    /// Declared with the `open` modifier.
    is_open: bool,
    /// Declared with the `override` modifier.
    is_override: bool,
    /// Declared with the `final` modifier. Meaningful on an `override` member
    /// (`final override fun`), where it seals the method against any further
    /// override — otherwise an `override` is open by default. Redundant but
    /// legal on a plain member. Defaults to false so the many synthesized
    /// `Function` nodes need not spell it.
    is_final: bool = false,
    /// Declared with the `abstract` modifier. When set the function may have
    /// `body: None` and must live on an `abstract class` / `interface`.
    is_abstract: bool,
    /// Declared with the `operator` modifier. Required by Kotlin on functions
    /// that participate in operator/convention dispatch — notably
    /// `getValue` / `setValue` for property delegates.
    is_operator: bool,
    /// Declared with the `inline` modifier.
    is_inline: bool,
    /// Declared with the `infix` modifier. Required for use at an infix call
    /// site `a foo b`; the type checker enforces this.
    is_infix: bool,
    /// Declared with the `tailrec` modifier.
    is_tailrec: bool,
    /// Declared with the `suspend` modifier. The function colours every
    /// call inside its body as a suspension-allowed context, and every
    /// call site to this function is required to be inside a suspending
    /// context.
    is_suspend: bool,
    /// `expect fun foo(): R` — declaration without a body, awaiting
    /// an `actual` impl supplied by the host (native binding) or a
    /// platform-specific Kotlin source. Bodies are forbidden; the
    /// IR build skips lowering and the dispatch fast path relies on
    /// the installed `actual` binding.
    is_expect: bool,
    /// `actual fun foo(): R = …` — the platform-side counterpart
    /// to an `expect` declaration with the same signature.
    is_actual: bool,
    visibility: Visibility,
    annotations: []Annotation,
    span: Span,
};

/// Variance of a type parameter (declaration site) or type argument (use site).
pub const Variance = enum {
    Invariant,
    /// `out T` — covariant; T may appear in output positions.
    Out,
    /// `in T` — contravariant; T may appear in input positions.
    In,

    pub const default: Variance = .Invariant;
};

/// Generic type parameter declaration, e.g. `<out T : Comparable<T>>`.
pub const TypeParam = struct {
    name: Ident,
    variance: Variance,
    /// Inline upper bound from the `<T : Foo>` form; combined with
    /// `where`-clause bounds during type checking.
    upper_bound: ?TypeRef,
    /// `reified T` — only meaningful on `inline fun` type parameters.
    is_reified: bool,
    annotations: []Annotation,
    span: Span,
};

/// Single `where` clause bound: `where T : Foo`.
pub const WhereBound = struct {
    name: Ident,
    bound: TypeRef,
    span: Span,
};

/// Type argument inside a `<...>` instantiation. Tracks projection (`*`,
/// `out X`, `in X`) so the type checker can enforce variance on use sites.
pub const TypeArg = struct {
    variance: Variance,
    /// `*` star-projection; when true `ty` is unused.
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
    /// Boxed so an absent default (the common case) costs a pointer, not a
    /// full inline `Expr`. `Expr` is a watched codec type, so the shared-graph
    /// encoder/decoder follows the pointer and materialises the default only
    /// when present.
    default: ?*Expr,
    /// `vararg x: T` — variadic parameter; runtime-collected into a typed
    /// array.
    is_vararg: bool,
    /// `crossinline` lambda parameter on an `inline fun` — non-local returns
    /// are forbidden in the body of the supplied lambda.
    is_crossinline: bool,
    /// `noinline` lambda parameter on an `inline fun` — the lambda is *not*
    /// inlined and may be stored / passed on like a regular value.
    is_noinline: bool,
    annotations: []Annotation,
    span: Span,
};

pub const Property = struct {
    mutable: bool,
    name: Ident,
    /// `context(a: A)` modifier clause. The clause belongs to the
    /// property as a whole: both accessors see the parameters. A
    /// contextual property has no backing field.
    context_params: []ContextParam = &.{},
    /// Receiver type for an extension property declared as
    /// `val T.foo: U get() = ...`. `None` for member/top-level properties.
    /// Extension properties may not have an initializer, delegate, or
    /// backing field; the accessor body is invoked with the receiver
    /// bound as `this`.
    receiver_type: ?TypeRef,
    ty: ?TypeRef,
    init: ?Expr,
    /// `val foo: T by expr` — the delegate expression that produces an
    /// object with `getValue` (and `setValue` for `var`). When set, `init`
    /// is `None`. Boxed — present on almost no property, so an inline `Expr`
    /// would tax every `Property` node for nothing.
    delegate: ?*Expr,
    /// `val foo: T get() = …` or `get() { … }`. When set, reads of `foo`
    /// invoke this accessor instead of (or in addition to) the backing
    /// field. Boxed (rarely present); `Accessor` is a watched codec type, so
    /// the shared-graph decoder follows the pointer and `PropertyDef.getter`
    /// resolves to the same heap node.
    getter: ?*Accessor,
    /// `var foo: T set(value) { … }`. Receives the assigned value via the
    /// first parameter (named `value` if the source omits a name). Boxed.
    setter: ?*Accessor,
    /// Declared with the `abstract` modifier — only valid on a member of an
    /// `abstract class` / `interface`. Abstract properties carry no `init`
    /// and no body for their accessors.
    is_abstract: bool,
    /// Declared with the `open` modifier (`open val foo: Int = 1`). Required
    /// for a subclass to `override` the property.
    is_open: bool,
    /// Declared with the `override` modifier (`override val foo: T = ...`).
    is_override: bool,
    /// `lateinit var name: T` — non-null `var` without initializer. Reads
    /// before first write throw `kotlin.UninitializedPropertyAccessException`.
    is_lateinit: bool,
    /// `const val NAME = EXPR` — compile-time constant. Only allowed at top
    /// level or inside an `object` (including a `companion object`). The
    /// initializer must be a compile-time-evaluable expression over
    /// primitive / `String` operands.
    is_const: bool,
    /// `inline val/var foo` — both accessors are inline; the property is not
    /// allowed to have a backing field (no initializer, no `field`-using
    /// accessor).
    is_inline: bool,
    /// `expect val/var foo: T` — declaration without an
    /// initializer or getter body; awaits an `actual` impl.
    is_expect: bool,
    /// `actual val/var foo: T = …` — supplies the body for an
    /// `expect` declaration with the same name + signature.
    is_actual: bool,
    /// Per-setter visibility recorded when the source uses bodyless
    /// `private set` / `protected set` etc. on a `var`. None means the
    /// setter inherits the property visibility.
    setter_visibility: ?Visibility,
    /// Explicit backing field clause in the initializer slot:
    /// `val items: List<String>` + `field = mutableListOf()`. The field is
    /// the property's storage; reads inside the declaring scope see the
    /// field type, reads outside see the property type. Boxed — present on
    /// almost no property, so an inline struct would tax every `Property`
    /// node for nothing.
    explicit_field: ?*ExplicitField = null,
    visibility: Visibility,
    annotations: []Annotation,
    span: Span,
};

/// `field[: Type][= init]` clause of a property declaration (member and
/// top-level `val` properties only; rejected by the parser on constructor
/// and local properties).
pub const ExplicitField = struct {
    /// Declared field type. When omitted it is inferred from `init`, or
    /// defaults to the property's own type.
    ty: ?TypeRef,
    /// Field initializer. When absent the field must be definitely
    /// assigned in every construction path (init blocks).
    init: ?Expr,
    /// Span of the `field` keyword token.
    span: Span,
};

pub const Accessor = struct {
    /// For a setter the single parameter (`set(value)`); empty for a
    /// getter.
    params: []Ident,
    /// Optional explicit return-type annotation on the accessor, e.g.
    /// `get(): Int { … }`. The type checker enforces that this matches
    /// the property's declared type.
    return_type: ?TypeRef,
    body: FunctionBody,
    /// Per-accessor visibility — typically used as `var x; private set` to
    /// keep the getter public while restricting writes.
    visibility: ?Visibility,
    /// `inline get()` / `inline set(v)` — the individual accessor body
    /// is inlined at every read/write site, independent of any other
    /// accessor on the same property. Distinct from the whole-property
    /// `inline val/var foo` form which marks the property declaration
    /// (`Property.is_inline`) and implicitly inlines both accessors.
    is_inline: bool,
    annotations: []Annotation,
    span: Span,
};

pub const Class = struct {
    name: Ident,
    /// Generic type parameters: `class Box<out T>`.
    type_params: []TypeParam,
    /// `where`-clause bounds.
    where_bounds: []WhereBound,
    /// Primary-constructor parameters. Entries marked `val`/`var` also
    /// become member properties on the instance.
    primary_params: []ClassParam,
    /// Whether the header declares a primary constructor (`class A()` /
    /// `class A(x: Int)`), as opposed to a class with none (`class A {
    /// constructor(...) }`), which has no implicit zero-argument constructor
    /// once it declares a secondary.
    has_primary_ctor: bool = true,
    /// `init { … }` blocks in declaration order. Executed during
    /// construction interleaved with body-property initializers per
    /// `init_block_positions`, matching Kotlin's source-order rule.
    init_blocks: []Block,
    /// Position of each entry in `init_blocks` in the original
    /// declaration order, measured as "the number of `members` already
    /// seen at the point the init block was parsed". So an init block
    /// with position `N` runs **before** `members[N]`'s property
    /// initializer (and after any earlier-positioned members and init
    /// blocks). Same length as `init_blocks`.
    init_block_positions: []usize,
    /// Parsed but otherwise unused: supertype names from `class Foo : Bar()`.
    supertypes: []TypeRef,
    /// For each entry in `supertypes`, the constructor argument list at the
    /// declaration site (`: Bar(a, b)`). `None` means no `(...)` was written
    /// (interface-style supertype reference); `Some(vec)` means it was a
    /// super-constructor call, including the empty-arg form `: Bar()`.
    supertype_args: []?[]Expr,
    /// Parallel to each `supertype_args` list: the argument label for each
    /// super-constructor argument (`: Bar(objects = 2)` -> `"objects"`),
    /// or `null` for a positional argument. Empty (the default) means no
    /// labels were captured, so every argument binds positionally. Used to
    /// bind a named super-constructor argument to the base parameter of
    /// that name rather than by position.
    supertype_arg_names: []const ?[]const ?[]const u8 = &.{},
    /// For each entry in `supertypes`, the delegate expression from
    /// `: I by expr`. `None` for plain supertype references and for
    /// constructor-call supertypes (`: Bar(...)`); `Some(expr)` records
    /// the delegate expression to evaluate once at construction time.
    supertype_delegates: []?Expr,
    /// `data class`.
    is_data: bool,
    /// `companion object` (named or anonymous).
    is_companion: bool,
    /// `enum class`. When set, `enum_entries` holds the declared entries in
    /// source order and `members` holds the shared methods/properties that
    /// follow the `;` separator in the class body.
    is_enum: bool,
    /// `sealed class` / `sealed interface`. Records the modifier so the
    /// runtime subtype checks and `when` exhaustiveness logic can see it.
    /// Today the runtime only consults `supertypes` by simple name; sealed
    /// is otherwise just a flag.
    is_sealed: bool,
    /// `open class` — subclassable. Without `open` (or `abstract`/`sealed`)
    /// a class is final.
    is_open: bool,
    /// `abstract class` — may declare abstract members and cannot be
    /// constructed directly. Implies `open`.
    is_abstract: bool,
    /// `inner class` — nested class that captures an outer-instance
    /// reference. Plain (non-`inner`) nested classes do not capture one.
    is_inner: bool,
    /// Secondary constructors declared in the class body. Each carries an
    /// explicit delegation to either another constructor of the same class
    /// (`: this(args)`) or the superclass (`: super(args)`).
    secondary_ctors: []SecondaryCtor,
    /// `interface Foo { … }`. Methods and properties on an interface may have
    /// no body (abstract) or carry a default body. Constructed instances are
    /// never `Value::Class` for an interface; they're never the leaf class of
    /// any `Value::Instance`. Implementing classes pick up default methods
    /// and inherit `is`-check membership.
    is_interface: bool,
    /// `fun interface Foo { fun apply(...): ... }` — a single-abstract-method
    /// interface eligible for SAM conversion from a lambda.
    is_fun_interface: bool,
    /// `value class` (and the deprecated alias `inline class`) — single-field
    /// wrapper class. Typeck enforces the shape; the interp keeps a boxed
    /// representation so existing equality / printing machinery applies.
    is_value: bool,
    /// `annotation class Foo(...)` — declaration of an annotation type.
    /// Typeck enforces shape constraints on the class body and parameter
    /// types.
    is_annotation: bool,
    /// `expect class Foo` — declaration awaiting an `actual class Foo`
    /// counterpart. Bodies / constructor bodies may be empty.
    is_expect: bool,
    /// `actual class Foo` — concrete impl matched to an `expect class`
    /// by simple name.
    is_actual: bool,
    enum_entries: []EnumEntry,
    members: []Decl,
    visibility: Visibility,
    /// Visibility on the primary constructor when the source uses the
    /// explicit `class Foo private constructor(...)` form. `None` means the
    /// primary constructor inherits the class visibility.
    primary_ctor_visibility: ?Visibility,
    annotations: []Annotation,
    span: Span,
};

pub const EnumEntry = struct {
    name: Ident,
    /// Constructor arguments — present when the enum declares a primary ctor.
    args: []Expr,
    /// Per argument, the parameter a named argument binds (`A(b = 1, a = 0)`);
    /// null for a positional argument.
    arg_names: []const ?[]const u8 = &.{},
    /// Per-entry body declarations (overrides like `override fun apply(...)`).
    /// Empty for bare entries.
    body_members: []Decl,
    annotations: []Annotation,
    span: Span,
};

pub const ClassParam = struct {
    /// `None` when the param isn't a property; `Some(true)` for `var`,
    /// `Some(false)` for `val`.
    property: ?bool,
    name: Ident,
    ty: TypeRef,
    default: ?Expr,
    visibility: Visibility,
    /// `vararg` modifier on a primary-constructor parameter. Forbidden when
    /// the enclosing class is a `data class`.
    is_vararg: bool,
    annotations: []Annotation,
    span: Span,
};

pub const SecondaryCtor = struct {
    params: []Param,
    delegation: CtorDelegation,
    /// Per delegation argument, the name a named argument (`this(message =
    /// …)`) binds; null for a positional one. Empty when no argument is
    /// named.
    delegation_arg_names: []const ?[]const u8 = &.{},
    body: ?Block,
    visibility: Visibility,
    annotations: []Annotation,
    span: Span,
};

pub const CtorDelegation = union(enum) {
    /// `: this(args)` — delegate to another constructor on this class.
    This: []Expr,
    /// `: super(args)` — delegate directly to a parent-class constructor.
    /// Only valid when the class has no primary constructor.
    Super: []Expr,
    /// No explicit delegation header. Treated as implicit `: this()` when a
    /// primary constructor exists, otherwise implicit `: super()`.
    None,
};

pub const ObjectDecl = struct {
    name: Ident,
    supertypes: []TypeRef,
    members: []Decl,
    /// `init { … }` blocks in declaration order, run when the singleton is
    /// constructed — same semantics as `Class.init_blocks`.
    init_blocks: []Block,
    /// Position of each entry in `init_blocks` relative to `members`, with
    /// the same before/after ordering contract as
    /// `Class.init_block_positions`.
    init_block_positions: []usize,
    /// Constructor arguments for each declared supertype (`object O :
    /// Foo(arg1, arg2)`). Slot per supertype; `None` when no `(args)` was
    /// written (interface or default-ctor base).
    supertype_args: []?[]Expr,
    /// Parallel to `supertype_args`: argument labels for a named
    /// super-constructor call (`object O : Foo(objects = 2)`), `null` per
    /// positional argument. Empty default = all positional. See the
    /// matching field on the class declaration.
    supertype_arg_names: []const ?[]const ?[]const u8 = &.{},
    /// Parallel to `supertypes`: the delegate expression of an inheritance
    /// delegation (`object O : Iface by impl`), `null` for a plain supertype.
    /// Empty when the declaration used no `by` clause.
    supertype_delegates: []?Expr = &.{},
    /// Annotations written on the declaration (`@Serializable object O`).
    annotations: []Annotation = &.{},
    /// `data object Foo { … }` — auto-generates `toString` returning the
    /// simple class name. Distinct from `data class`: no `copy` / no
    /// `componentN`, and user-declared `equals`/`hashCode` overrides are
    /// rejected.
    is_data: bool,
    /// `expect object` — a platform-supplied singleton whose actual
    /// definition appears in a platform source set.
    is_expect: bool,
    /// `actual object` — the platform definition that supersedes a
    /// matching `expect object`.
    is_actual: bool,
    visibility: Visibility,
    span: Span,
};

pub const TypeRef = struct {
    name: Ident,
    nullable: bool,
    span: Span,
    /// Generic type arguments: `List<Int>` carries `[TypeArg(Int)]`. Empty
    /// for non-generic references and for parameter-name references like a
    /// bare `T`.
    type_args: []TypeArg,
    /// When present, this `TypeRef` denotes a function type
    /// `(P1, P2, ...) -> R` (optionally with a receiver). The
    /// `name`/`nullable` fields remain valid: `name.name` carries the
    /// synthetic tag `"<function>"` so existing name-based consumers
    /// (resolver, type lowering) treat it as unresolved without panicking,
    /// and `nullable` reflects whether the function type itself is nullable
    /// (e.g. `((Int) -> Int)?`).
    function: ?*FunctionTypeRef,
    /// `T & Any` — definitely non-nullable projection of a type parameter.
    /// The parser sets this when it sees a `&`-joined right-hand `Any`
    /// after a user-type. Typeck rejects the shape on non-type-parameter
    /// receivers; interp treats it as the base T at runtime.
    definitely_non_null: bool,
    annotations: []Annotation,
    /// The full dotted source path when this reference was written
    /// qualified (`Outer.Inner`, `a.b.C`). `name` keeps only the last
    /// segment (klio resolves types by simple name), so this preserves
    /// the qualifier for the cases that need it — chiefly disambiguating
    /// a nested supertype (`Outer.Inner`) from a same-named top-level
    /// class. `None` for an unqualified reference.
    qualified_path: ?[]const u8,
};

/// Function type written as a type annotation, e.g.
/// `(Int, String) -> Boolean` or `Receiver.(Int) -> Unit`.
pub const FunctionTypeRef = struct {
    receiver: ?TypeRef,
    params: []TypeRef,
    ret: TypeRef,
    is_suspend: bool,
    /// Leading `context(A, B)` block of a contextual function type
    /// `context(A, B) R.(P) -> T`. Types only — named entries are
    /// rejected by the parser. The type is equivalent to the flattened
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
    /// `val (a, b, ...) = expr` / `var (a, b, ...) = expr`. Each name
    /// receives `expr.componentN()` (1-indexed). A name of `_` is a
    /// discard — its component is evaluated for side effects but no
    /// binding is created.
    DestructuringDecl: struct {
        mutable: bool,
        names: []Ident,
        /// Name-based form `(val a, val n = prop) = x`: each name reads the
        /// property in `sources` (its own name unless renamed with `=`).
        /// Positional forms (`(a, b)`, `[a, b]`) read `componentN`.
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

/// Suffix-derived kind of an integer literal. `1` is `Int`, `1L` is
/// `Long`, `1u` is `UInt`, `1uL` is `ULong`. Drives both the runtime
/// variant chosen by the interpreter and the literal's static type
/// in the type checker.
pub const IntLitKind = enum {
    Int,
    Long,
    UInt,
    ULong,

    pub const default: IntLitKind = .Int;
};

/// Suffix-derived kind of a floating-point literal. `1.0` is `Double`;
/// `1.0f` / `1.0F` is `Float`.
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
    /// `callee(args)`. `arg_names` is parallel to `args`: a `Some(label)`
    /// entry means the source wrote `label = arg`, a `None` entry is
    /// positional. The interpreter uses these labels to reorder against a
    /// callable's parameter list. `type_args` carries explicit call-site
    /// generic type arguments like `foo<String>(...)`; empty when none were
    /// written. Consumed primarily by reified type-parameter handling.
    Call: struct {
        callee: *Expr,
        args: []Expr,
        arg_names: []?[]const u8,
        type_args: []TypeRef,
        /// True when the source wrote this as an infix call `a name b`
        /// rather than `name(a, b)`. The type checker requires the resolved
        /// callee to carry the `infix` modifier in that case.
        is_infix: bool,
        /// True when the source supplied the final argument as a TRAILING
        /// lambda (`f(x) { … }`), which Kotlin binds to the LAST parameter.
        /// A parenthesized lambda (`f(x, { … })`) binds positionally and
        /// leaves this false.
        has_trailing_lambda: bool = false,
        /// True when parentheses enclosed this complete call expression.
        /// A following lambda then invokes the call's result.
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
    /// `do body while (cond)` — post-tested loop. Body is always evaluated at
    /// least once. Optional body covers the form `do; while(c)`.
    DoWhile: struct {
        body: ?*Expr,
        cond: *Expr,
        span: Span,
    },
    /// `for (vars in iter) body`. `vars` has length 1 for the normal case
    /// `for (x in xs)`; length 2+ when the source used destructuring like
    /// `for ((k, v) in m)`. The interpreter pulls the matching component
    /// from each iteration element (`Pair`/`Map.Entry`/general `componentN`).
    For: struct {
        vars: []Ident,
        /// `for ((val k, val v) in xs)`: name-based, see `DestructuringDecl`.
        by_name: bool = false,
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
    /// `label@ expr` — binds an explicit label name to `expr`. The label is
    /// the jump target for `return@label` / `break@label` / `continue@label`
    /// within `expr`. Used on loop expressions and lambda / call expressions.
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
        /// Declared parameter type annotations (`{ s: String -> … }`),
        /// aligned with `params`; `null` per unannotated slot. Empty when
        /// the literal declares no header (the injected `it` carries no
        /// annotation). Runtime overload dispatch reads these to match a
        /// lambda against a declared function-type parameter.
        param_tys: []?TypeRef = &.{},
        /// Annotations written on the literal itself (`@Composable { … }`).
        /// The expression form is a runtime no-op, but the compose pass
        /// reads it to transform an annotated literal bound to an
        /// untyped val.
        annotations: []Annotation = &.{},
        body: Block,
        span: Span,
        /// True when the single `it` parameter was injected by the parser
        /// for a zero-`->` lambda. The literal's real arity then comes
        /// from the expected type: `{ x() }` is `() -> R` in a value
        /// position but `(T) -> R` when passed where one parameter is
        /// expected.
        implicit_it: bool = false,
    },
    /// `this` or `this@Label`. `qualifier` is `Some(name)` for the labeled
    /// form, used inside an inner class to refer to the enclosing
    /// outer-class instance (`this@Outer`).
    This: struct {
        qualifier: ?Ident,
        span: Span,
    },
    /// `super` — only meaningful as the receiver of `super.foo` /
    /// `super.foo(...)`. Evaluation resolves the member against the
    /// owning class's parent class. `qualifier` carries the `<Klazz>`
    /// type argument (`super<Base>.foo()`) — required when the receiver
    /// has multiple supertypes that supply a matching member. `label`
    /// carries the `@Outer` selector (`super@Outer.foo()`) — used from
    /// inside an inner class to dispatch through the outer class's
    /// parent rather than the inner class's. Both are `None` for a
    /// bare `super`.
    Super: struct {
        qualifier: ?TypeRef,
        label: ?Ident,
        span: Span,
    },
    /// `::foo` — callable/property reference to a top-level or in-scope
    /// name. Today the runtime treats it as a lightweight property
    /// metadata value with `.name` and `.get()` — enough for delegates.
    PropertyRef: struct {
        name: Ident,
        span: Span,
    },
    /// `Receiver::name` — qualified callable / property reference. The
    /// receiver is a class (`Foo::method`, `Foo::class`) or an instance
    /// (`obj::method`). Evaluation depends on the resolved receiver kind.
    MemberRef: struct {
        receiver: *Expr,
        name: Ident,
        span: Span,
    },
    /// `when` expression. `subject` is `Some` for the subject-bound form
    /// `when (x) { … }` and `None` for the subject-free form
    /// `when { cond -> … }`. Branches are tried in order; the first matching
    /// branch's body is the result. When no branch matches and no `else`
    /// branch is present, evaluation throws
    /// `kotlin.NoWhenBranchMatchedException`.
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
    /// `expr as Type` / `expr as? Type`. `safe` is `true` for `as?`, in which
    /// case a failed runtime cast yields `null` instead of throwing
    /// `kotlin.ClassCastException`.
    As: struct {
        expr: *Expr,
        ty: TypeRef,
        safe: bool,
        span: Span,
    },
    /// Anonymous function expression: `fun(x: Int): Int = x + 1` /
    /// `fun T.foo(): T { ... }`. `return` inside the body is a local return
    /// out of this function rather than the enclosing one.
    AnonFun: struct {
        receiver_ty: ?TypeRef,
        /// `context(x: A) fun (…)`: the body binds each context name from
        /// the context stack at entry, as a declared context function does.
        context_params: []ContextParam = &.{},
        params: []Param,
        return_ty: ?TypeRef,
        body: ?*FunctionBody,
        is_suspend: bool,
        span: Span,
    },
    /// `*expr` — spread of an array into a `vararg` parameter at a call
    /// site. Only valid as a top-level value argument: `foo(*arr)`, mixed
    /// with positional args. The interpreter flattens it into the vararg
    /// array; the type checker rejects it when the bound parameter is not
    /// `vararg`.
    Spread: struct {
        expr: *Expr,
        span: Span,
    },
    /// Anonymous object expression: `object { ... }`, `object : Foo { ... }`,
    /// `object : Parent(args), Iface { ... }`. Captures the enclosing scope
    /// for method bodies (closure-like). Each occurrence produces a fresh
    /// `ClassDef` and a single instance.
    ObjectExpr: struct {
        supertypes: []TypeRef,
        supertype_args: []?[]Expr,
        supertype_arg_names: []const ?[]const ?[]const u8 = &.{},
        supertype_delegates: []?Expr,
        members: []Decl,
        /// `init { … }` blocks in declaration order, run at construction
        /// interleaved with the property initializers — same semantics as
        /// `Class.init_blocks`.
        init_blocks: []Block,
        /// Position of each entry in `init_blocks` relative to `members`,
        /// with the same before/after ordering contract as
        /// `Class.init_block_positions`.
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

/// `when (val name: Ty = subject)` — binds `name` to the subject's value
/// for the duration of the when's branches. `ty` is `None` when the
/// source omitted the type annotation.
pub const WhenBinding = struct {
    name: Ident,
    ty: ?TypeRef,
    annotations: []Annotation,
    span: Span,
};

pub const WhenBranch = struct {
    /// Comma-separated patterns on the left of `->`. A branch fires when any
    /// pattern matches. An `Else` pattern can only appear by itself.
    patterns: []WhenPattern,
    body: Expr,
    span: Span,
};

pub const WhenPattern = struct {
    kind: WhenPatternKind,
    span: Span,
};

pub const WhenPatternKind = union(enum) {
    /// `value` — equality match against the subject (subject-bound `when`),
    /// or Boolean condition (subject-free `when`).
    Value: Expr,
    /// `in expr` — `subject in expr` membership.
    InRange: Expr,
    /// `!in expr` — `subject !in expr` membership.
    NotInRange: Expr,
    /// `is Type` — runtime type check on the subject. Implies a smart cast
    /// for the branch body when the subject is a single identifier.
    IsType: TypeRef,
    /// `!is Type`.
    NotIsType: TypeRef,
    /// `else` — fallthrough. Only valid as the sole pattern in its branch.
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
    /// Boxed so a `StringPart` is pointer-sized, not Expr-sized: a string
    /// template's parts slice held a full inline `Expr` per `${…}` even though
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
    /// `lhs in rhs` — membership. Implemented by `value_in` in the interp.
    In,
    /// `lhs !in rhs`.
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
}
