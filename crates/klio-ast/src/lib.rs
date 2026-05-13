//! Kotlin AST.

use klio_span::Span;

#[derive(Debug, Clone)]
pub struct Ident {
    pub name: String,
    pub span: Span,
}

/// Source-declared visibility modifier for a declaration. Defaults to
/// `Public` when the source omits a modifier, matching Kotlin's default.
/// Phase E will enforce cross-visibility access; the parser models the
/// modifier today so downstream passes can read it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Visibility {
    #[default]
    Public,
    Private,
    Protected,
    Internal,
}

/// Use-site target for a declaration-site annotation, e.g. `@field:Foo`,
/// `@get:Bar`. `None` on an `Annotation` means the source wrote a plain
/// `@Foo` with no explicit target.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AnnotationUseSite {
    Field,
    Property,
    Get,
    Set,
    Receiver,
    Param,
    SetParam,
    Delegate,
    File,
}

/// A single `@Foo(args)` / `@use-site:Foo` annotation at a declaration
/// site. Values inside are parsed best-effort; downstream passes treat
/// them as opaque for now.
#[derive(Debug, Clone)]
pub struct Annotation {
    pub use_site: Option<AnnotationUseSite>,
    pub path: Vec<Ident>,
    pub type_args: Vec<TypeRef>,
    pub args: Vec<Expr>,
    pub arg_names: Vec<Option<String>>,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct KotlinFile {
    pub package: Option<PackageHeader>,
    pub imports: Vec<ImportDecl>,
    pub decls: Vec<Decl>,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct PackageHeader {
    pub path: Vec<Ident>,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct ImportDecl {
    pub path: Vec<Ident>,
    pub alias: Option<Ident>,
    pub wildcard: bool,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub enum Decl {
    Function(Function),
    Property(Property),
    Class(Class),
    /// Standalone `object Foo { … }` singleton.
    Object(ObjectDecl),
    /// `typealias Name[<Tp>] = Type`. Aliases are transparent at use sites:
    /// the type checker unfolds them to the underlying type with type-args
    /// substituted before any subtype / member-lookup work.
    TypeAlias(TypeAlias),
}

#[derive(Debug, Clone)]
pub struct TypeAlias {
    pub name: Ident,
    pub type_params: Vec<TypeParam>,
    pub target: TypeRef,
    pub visibility: Visibility,
    pub annotations: Vec<Annotation>,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct Function {
    pub name: Ident,
    /// Receiver type for an extension function declared as
    /// `fun T.foo(...)`. `None` for regular and member functions. The
    /// interpreter binds the call-site receiver as `this` inside the
    /// body; the type checker walks the receiver's class chain to find
    /// matching extensions at member-call sites.
    pub receiver_type: Option<TypeRef>,
    /// Generic type parameters declared on this function: `fun <T> id(x: T): T`.
    pub type_params: Vec<TypeParam>,
    /// `where` clause bounds: `fun <T> foo() where T : Foo, T : Bar`.
    pub where_bounds: Vec<WhereBound>,
    pub params: Vec<Param>,
    pub return_type: Option<TypeRef>,
    pub body: Option<FunctionBody>,
    /// Declared with the `open` modifier.
    pub is_open: bool,
    /// Declared with the `override` modifier.
    pub is_override: bool,
    /// Declared with the `abstract` modifier. When set the function may have
    /// `body: None` and must live on an `abstract class` / `interface`.
    pub is_abstract: bool,
    /// Declared with the `operator` modifier. Required by Kotlin on functions
    /// that participate in operator/convention dispatch — notably
    /// `getValue` / `setValue` for property delegates.
    pub is_operator: bool,
    /// Declared with the `inline` modifier.
    pub is_inline: bool,
    /// Declared with the `infix` modifier. Required for use at an infix call
    /// site `a foo b`; the type checker enforces this.
    pub is_infix: bool,
    /// Declared with the `tailrec` modifier. Phase K will add tail-call
    /// detection and rewrite; for now the flag is round-tripped through the
    /// AST without enforcement.
    pub is_tailrec: bool,
    /// Declared with the `suspend` modifier. The function colours every
    /// call inside its body as a suspension-allowed context, and every
    /// call site to this function is required to be inside a suspending
    /// context.
    pub is_suspend: bool,
    pub visibility: Visibility,
    pub annotations: Vec<Annotation>,
    pub span: Span,
}

/// Variance of a type parameter (declaration site) or type argument (use site).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Variance {
    #[default]
    Invariant,
    /// `out T` — covariant; T may appear in output positions.
    Out,
    /// `in T` — contravariant; T may appear in input positions.
    In,
}

/// Generic type parameter declaration, e.g. `<out T : Comparable<T>>`.
#[derive(Debug, Clone)]
pub struct TypeParam {
    pub name: Ident,
    pub variance: Variance,
    /// Inline upper bound from the `<T : Foo>` form; combined with
    /// `where`-clause bounds during type checking.
    pub upper_bound: Option<TypeRef>,
    /// `reified T` — only meaningful on `inline fun` type parameters.
    pub is_reified: bool,
    pub annotations: Vec<Annotation>,
    pub span: Span,
}

/// Single `where` clause bound: `where T : Foo`.
#[derive(Debug, Clone)]
pub struct WhereBound {
    pub name: Ident,
    pub bound: TypeRef,
    pub span: Span,
}

/// Type argument inside a `<...>` instantiation. Tracks projection (`*`,
/// `out X`, `in X`) so the type checker can enforce variance on use sites.
#[derive(Debug, Clone)]
pub struct TypeArg {
    pub variance: Variance,
    /// `*` star-projection; when true `ty` is unused.
    pub is_star: bool,
    pub ty: TypeRef,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub enum FunctionBody {
    Block(Block),
    Expr(Expr),
}

#[derive(Debug, Clone)]
pub struct Param {
    pub name: Ident,
    pub ty: TypeRef,
    pub default: Option<Expr>,
    /// `vararg x: T` — variadic parameter; runtime-collected into a typed
    /// array.
    pub is_vararg: bool,
    /// `crossinline` lambda parameter on an `inline fun` — non-local returns
    /// are forbidden in the body of the supplied lambda.
    pub is_crossinline: bool,
    /// `noinline` lambda parameter on an `inline fun` — the lambda is *not*
    /// inlined and may be stored / passed on like a regular value.
    pub is_noinline: bool,
    pub annotations: Vec<Annotation>,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct Property {
    pub mutable: bool,
    pub name: Ident,
    /// Receiver type for an extension property declared as
    /// `val T.foo: U get() = ...`. `None` for member/top-level properties.
    /// Extension properties may not have an initializer, delegate, or
    /// backing field; the accessor body is invoked with the receiver
    /// bound as `this`.
    pub receiver_type: Option<TypeRef>,
    pub ty: Option<TypeRef>,
    pub init: Option<Expr>,
    /// `val foo: T by expr` — the delegate expression that produces an
    /// object with `getValue` (and `setValue` for `var`). When set, `init`
    /// is `None`.
    pub delegate: Option<Expr>,
    /// `val foo: T get() = …` or `get() { … }`. When set, reads of `foo`
    /// invoke this accessor instead of (or in addition to) the backing
    /// field.
    pub getter: Option<Accessor>,
    /// `var foo: T set(value) { … }`. Receives the assigned value via the
    /// first parameter (named `value` if the source omits a name).
    pub setter: Option<Accessor>,
    /// Declared with the `abstract` modifier — only valid on a member of an
    /// `abstract class` / `interface`. Abstract properties carry no `init`
    /// and no body for their accessors.
    pub is_abstract: bool,
    /// Declared with the `open` modifier (`open val foo: Int = 1`). Required
    /// for a subclass to `override` the property (spec §5.4).
    pub is_open: bool,
    /// Declared with the `override` modifier (`override val foo: T = ...`).
    pub is_override: bool,
    /// `lateinit var name: T` — non-null `var` without initializer. Reads
    /// before first write throw `kotlin.UninitializedPropertyAccessException`.
    pub is_lateinit: bool,
    /// `const val NAME = EXPR` — compile-time constant. Only allowed at top
    /// level or inside an `object` (including a `companion object`). The
    /// initializer must be a compile-time-evaluable expression over
    /// primitive / `String` operands.
    pub is_const: bool,
    /// `inline val/var foo` — both accessors are inline; the property is not
    /// allowed to have a backing field (no initializer, no `field`-using
    /// accessor). Spec §4.3.4.
    pub is_inline: bool,
    /// Per-setter visibility recorded when the source uses bodyless
    /// `private set` / `protected set` etc. on a `var`. None means the
    /// setter inherits the property visibility. Spec §4.6.
    pub setter_visibility: Option<Visibility>,
    pub visibility: Visibility,
    pub annotations: Vec<Annotation>,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct Accessor {
    /// For a setter the single parameter (`set(value)`); empty for a
    /// getter.
    pub params: Vec<Ident>,
    /// Optional explicit return-type annotation on the accessor, e.g.
    /// `get(): Int { … }`. The type checker enforces that this matches
    /// the property's declared type.
    pub return_type: Option<TypeRef>,
    pub body: FunctionBody,
    /// Per-accessor visibility — typically used as `var x; private set` to
    /// keep the getter public while restricting writes. Spec §4.6 / §4.3.4.
    pub visibility: Option<Visibility>,
    pub annotations: Vec<Annotation>,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct Class {
    pub name: Ident,
    /// Generic type parameters: `class Box<out T>`.
    pub type_params: Vec<TypeParam>,
    /// `where`-clause bounds.
    pub where_bounds: Vec<WhereBound>,
    /// Primary-constructor parameters. Entries marked `val`/`var` also
    /// become member properties on the instance.
    pub primary_params: Vec<ClassParam>,
    /// `init { … }` blocks in declaration order. Executed during
    /// construction after primary params bind but before body property
    /// initializers in source order is enforced by `members` ordering.
    pub init_blocks: Vec<Block>,
    /// Parsed but otherwise unused: supertype names from `class Foo : Bar()`.
    pub supertypes: Vec<TypeRef>,
    /// For each entry in `supertypes`, the constructor argument list at the
    /// declaration site (`: Bar(a, b)`). `None` means no `(...)` was written
    /// (interface-style supertype reference); `Some(vec)` means it was a
    /// super-constructor call, including the empty-arg form `: Bar()`.
    pub supertype_args: Vec<Option<Vec<Expr>>>,
    /// For each entry in `supertypes`, the delegate expression from
    /// `: I by expr`. `None` for plain supertype references and for
    /// constructor-call supertypes (`: Bar(...)`); `Some(expr)` records
    /// the delegate expression to evaluate once at construction time.
    pub supertype_delegates: Vec<Option<Expr>>,
    /// `data class`.
    pub is_data: bool,
    /// `companion object` (named or anonymous).
    pub is_companion: bool,
    /// `enum class`. When set, `enum_entries` holds the declared entries in
    /// source order and `members` holds the shared methods/properties that
    /// follow the `;` separator in the class body.
    pub is_enum: bool,
    /// `sealed class` / `sealed interface`. Records the modifier so the
    /// runtime subtype checks and `when` exhaustiveness logic can see it.
    /// Today the runtime only consults `supertypes` by simple name; sealed
    /// is otherwise just a flag.
    pub is_sealed: bool,
    /// `open class` — subclassable. Without `open` (or `abstract`/`sealed`)
    /// a class is final.
    pub is_open: bool,
    /// `abstract class` — may declare abstract members and cannot be
    /// constructed directly. Implies `open`.
    pub is_abstract: bool,
    /// `inner class` — nested class that captures an outer-instance
    /// reference. Plain (non-`inner`) nested classes do not capture one.
    pub is_inner: bool,
    /// Secondary constructors declared in the class body. Each carries an
    /// explicit delegation to either another constructor of the same class
    /// (`: this(args)`) or the superclass (`: super(args)`).
    pub secondary_ctors: Vec<SecondaryCtor>,
    /// `interface Foo { … }`. Methods and properties on an interface may have
    /// no body (abstract) or carry a default body. Constructed instances are
    /// never `Value::Class` for an interface; they're never the leaf class of
    /// any `Value::Instance`. Implementing classes pick up default methods
    /// and inherit `is`-check membership.
    pub is_interface: bool,
    /// `fun interface Foo { fun apply(...): ... }` — a single-abstract-method
    /// interface eligible for SAM conversion from a lambda.
    pub is_fun_interface: bool,
    /// `value class` (and the deprecated alias `inline class`) — single-field
    /// wrapper class. Typeck enforces the shape; the interp keeps a boxed
    /// representation so existing equality / printing machinery applies.
    pub is_value: bool,
    /// `annotation class Foo(...)` — declaration of an annotation type.
    /// Typeck enforces shape constraints on the class body and parameter
    /// types.
    pub is_annotation: bool,
    pub enum_entries: Vec<EnumEntry>,
    pub members: Vec<Decl>,
    pub visibility: Visibility,
    /// Visibility on the primary constructor when the source uses the
    /// explicit `class Foo private constructor(...)` form. `None` means the
    /// primary constructor inherits the class visibility. Spec §4.6.
    pub primary_ctor_visibility: Option<Visibility>,
    pub annotations: Vec<Annotation>,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct EnumEntry {
    pub name: Ident,
    /// Constructor arguments — present when the enum declares a primary ctor.
    pub args: Vec<Expr>,
    /// Per-entry body declarations (overrides like `override fun apply(...)`).
    /// Empty for bare entries.
    pub body_members: Vec<Decl>,
    pub annotations: Vec<Annotation>,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct ClassParam {
    /// `None` when the param isn't a property; `Some(true)` for `var`,
    /// `Some(false)` for `val`.
    pub property: Option<bool>,
    pub name: Ident,
    pub ty: TypeRef,
    pub default: Option<Expr>,
    pub visibility: Visibility,
    /// `vararg` modifier on a primary-constructor parameter. Forbidden when
    /// the enclosing class is a `data class` (spec §4.1.2).
    pub is_vararg: bool,
    pub annotations: Vec<Annotation>,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct SecondaryCtor {
    pub params: Vec<Param>,
    pub delegation: CtorDelegation,
    pub body: Option<Block>,
    pub visibility: Visibility,
    pub annotations: Vec<Annotation>,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub enum CtorDelegation {
    /// `: this(args)` — delegate to another constructor on this class.
    This(Vec<Expr>),
    /// `: super(args)` — delegate directly to a parent-class constructor.
    /// Only valid when the class has no primary constructor.
    Super(Vec<Expr>),
    /// No explicit delegation header. Treated as implicit `: this()` when a
    /// primary constructor exists, otherwise implicit `: super()`.
    None,
}

#[derive(Debug, Clone)]
pub struct ObjectDecl {
    pub name: Ident,
    pub supertypes: Vec<TypeRef>,
    pub members: Vec<Decl>,
    /// Constructor arguments for each declared supertype (`object O :
    /// Foo(arg1, arg2)`). Slot per supertype; `None` when no `(args)` was
    /// written (interface or default-ctor base).
    pub supertype_args: Vec<Option<Vec<Expr>>>,
    /// `data object Foo { … }` — auto-generates `toString` returning the
    /// simple class name. Distinct from `data class`: no `copy` / no
    /// `componentN`, and user-declared `equals`/`hashCode` overrides are
    /// rejected.
    pub is_data: bool,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct TypeRef {
    pub name: Ident,
    pub nullable: bool,
    pub span: Span,
    /// Generic type arguments: `List<Int>` carries `[TypeArg(Int)]`. Empty
    /// for non-generic references and for parameter-name references like a
    /// bare `T`.
    pub type_args: Vec<TypeArg>,
    /// When present, this `TypeRef` denotes a function type
    /// `(P1, P2, ...) -> R` (optionally with a receiver). The
    /// `name`/`nullable` fields remain valid: `name.name` carries the
    /// synthetic tag `"<function>"` so existing name-based consumers
    /// (resolver, type lowering) treat it as unresolved without panicking,
    /// and `nullable` reflects whether the function type itself is nullable
    /// (e.g. `((Int) -> Int)?`).
    pub function: Option<Box<FunctionTypeRef>>,
    /// `T & Any` — definitely non-nullable projection of a type parameter.
    /// The parser sets this when it sees a `&`-joined right-hand `Any`
    /// after a user-type. Typeck rejects the shape on non-type-parameter
    /// receivers; interp treats it as the base T at runtime.
    pub definitely_non_null: bool,
    pub annotations: Vec<Annotation>,
}

/// Function type written as a type annotation, e.g.
/// `(Int, String) -> Boolean` or `Receiver.(Int) -> Unit`.
#[derive(Debug, Clone)]
pub struct FunctionTypeRef {
    pub receiver: Option<TypeRef>,
    pub params: Vec<TypeRef>,
    pub ret: TypeRef,
    pub is_suspend: bool,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct Block {
    pub stmts: Vec<Stmt>,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub enum Stmt {
    Expr(Expr),
    Decl(Decl),
    Assign {
        target: Expr,
        op: AssignOp,
        value: Expr,
        span: Span,
    },
    /// `val (a, b, ...) = expr` / `var (a, b, ...) = expr`. Each name
    /// receives `expr.componentN()` (1-indexed). A name of `_` is a
    /// discard — its component is evaluated for side effects but no
    /// binding is created.
    DestructuringDecl {
        mutable: bool,
        names: Vec<Ident>,
        init: Expr,
        span: Span,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AssignOp {
    Assign,
    Add,
    Sub,
    Mul,
    Div,
    Rem,
}

/// Suffix-derived kind of an integer literal. `1` is `Int`, `1L` is
/// `Long`, `1u` is `UInt`, `1uL` is `ULong`. Drives both the runtime
/// variant chosen by the interpreter and the literal's static type
/// in the type checker.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum IntLitKind {
    #[default]
    Int,
    Long,
    UInt,
    ULong,
}

/// Suffix-derived kind of a floating-point literal. `1.0` is `Double`;
/// `1.0f` / `1.0F` is `Float`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum FloatLitKind {
    #[default]
    Double,
    Float,
}

#[derive(Debug, Clone)]
pub enum Expr {
    IntLit { value: i64, kind: IntLitKind, span: Span },
    FloatLit { value: f64, kind: FloatLitKind, span: Span },
    BoolLit { value: bool, span: Span },
    NullLit { span: Span },
    CharLit { value: char, span: Span },
    StringTemplate { parts: Vec<StringPart>, span: Span },
    Path { segments: Vec<Ident>, span: Span },
    Member { receiver: Box<Expr>, name: Ident, safe: bool, span: Span },
    /// `callee(args)`. `arg_names` is parallel to `args`: a `Some(label)`
    /// entry means the source wrote `label = arg`, a `None` entry is
    /// positional. The interpreter uses these labels to reorder against a
    /// callable's parameter list. `type_args` carries explicit call-site
    /// generic type arguments like `foo<String>(...)`; empty when none were
    /// written. Consumed primarily by reified type-parameter handling.
    Call {
        callee: Box<Expr>,
        args: Vec<Expr>,
        arg_names: Vec<Option<String>>,
        type_args: Vec<TypeRef>,
        /// True when the source wrote this as an infix call `a name b`
        /// rather than `name(a, b)`. The type checker requires the resolved
        /// callee to carry the `infix` modifier in that case.
        is_infix: bool,
        span: Span,
    },
    Index { receiver: Box<Expr>, args: Vec<Expr>, span: Span },
    Binary { op: BinOp, lhs: Box<Expr>, rhs: Box<Expr>, span: Span },
    Unary { op: UnOp, expr: Box<Expr>, span: Span },
    Postfix { op: PostfixOp, expr: Box<Expr>, span: Span },
    If { cond: Box<Expr>, then_branch: Box<Expr>, else_branch: Option<Box<Expr>>, span: Span },
    While { cond: Box<Expr>, body: Box<Expr>, span: Span },
    /// `do body while (cond)` — post-tested loop. Body is always evaluated at
    /// least once (§7.2.2). Optional body covers the spec form `do; while(c)`.
    DoWhile { body: Option<Box<Expr>>, cond: Box<Expr>, span: Span },
    /// `for (vars in iter) body`. `vars` has length 1 for the normal case
    /// `for (x in xs)`; length 2+ when the source used destructuring like
    /// `for ((k, v) in m)`. The interpreter pulls the matching component
    /// from each iteration element (`Pair`/`Map.Entry`/general `componentN`).
    For { vars: Vec<Ident>, var_ty: Option<TypeRef>, iter: Box<Expr>, body: Box<Expr>, span: Span },
    Return { value: Option<Box<Expr>>, label: Option<Ident>, span: Span },
    Break { label: Option<Ident>, span: Span },
    Continue { label: Option<Ident>, span: Span },
    /// `label@ expr` — binds an explicit label name to `expr`. The label is
    /// the jump target for `return@label` / `break@label` / `continue@label`
    /// within `expr`. Used on loop expressions and lambda / call expressions.
    Labeled { label: Ident, expr: Box<Expr>, span: Span },
    Block(Block),
    Throw { value: Box<Expr>, span: Span },
    Try { body: Block, catches: Vec<Catch>, finally: Option<Block>, span: Span },
    Lambda { params: Vec<Ident>, body: Block, span: Span },
    /// `this` or `this@Label`. `qualifier` is `Some(name)` for the labeled
    /// form, used inside an inner class to refer to the enclosing
    /// outer-class instance (`this@Outer`).
    This { qualifier: Option<Ident>, span: Span },
    /// `super` — only meaningful as the receiver of `super.foo` /
    /// `super.foo(...)`. Evaluation resolves the member against the
    /// owning class's parent class. `qualifier` carries the `<Klazz>`
    /// type argument (`super<Base>.foo()`) — required when the receiver
    /// has multiple supertypes that supply a matching member. `label`
    /// carries the `@Outer` selector (`super@Outer.foo()`) — used from
    /// inside an inner class to dispatch through the outer class's
    /// parent rather than the inner class's. Both are `None` for a
    /// bare `super`.
    Super { qualifier: Option<TypeRef>, label: Option<Ident>, span: Span },
    /// `::foo` — callable/property reference to a top-level or in-scope
    /// name. Today the runtime treats it as a lightweight property
    /// metadata value with `.name` and `.get()` — enough for delegates.
    PropertyRef { name: Ident, span: Span },
    /// `Receiver::name` — qualified callable / property reference. The
    /// receiver is a class (`Foo::method`, `Foo::class`) or an instance
    /// (`obj::method`). Evaluation depends on the resolved receiver kind.
    MemberRef { receiver: Box<Expr>, name: Ident, span: Span },
    /// `when` expression. `subject` is `Some` for the subject-bound form
    /// `when (x) { … }` and `None` for the subject-free form
    /// `when { cond -> … }`. Branches are tried in order; the first matching
    /// branch's body is the result. When no branch matches and no `else`
    /// branch is present, evaluation throws
    /// `kotlin.NoWhenBranchMatchedException`.
    When {
        subject: Option<Box<Expr>>,
        subject_binding: Option<WhenBinding>,
        branches: Vec<WhenBranch>,
        span: Span,
    },
    /// `expr is Type` / `expr !is Type`. `negated` is `true` for `!is`.
    IsCheck { expr: Box<Expr>, ty: TypeRef, negated: bool, span: Span },
    /// `expr as Type` / `expr as? Type`. `safe` is `true` for `as?`, in which
    /// case a failed runtime cast yields `null` instead of throwing
    /// `kotlin.ClassCastException`.
    As { expr: Box<Expr>, ty: TypeRef, safe: bool, span: Span },
    /// Anonymous function expression: `fun(x: Int): Int = x + 1` /
    /// `fun T.foo(): T { ... }`. `return` inside the body is a local return
    /// out of this function rather than the enclosing one.
    AnonFun {
        receiver_ty: Option<TypeRef>,
        params: Vec<Param>,
        return_ty: Option<TypeRef>,
        body: Option<Box<FunctionBody>>,
        is_suspend: bool,
        span: Span,
    },
    /// `*expr` — spread of an array into a `vararg` parameter at a call
    /// site. Only valid as a top-level value argument: `foo(*arr)`, mixed
    /// with positional args. The interpreter flattens it into the vararg
    /// array; the type checker rejects it when the bound parameter is not
    /// `vararg`.
    Spread { expr: Box<Expr>, span: Span },
    /// Anonymous object expression: `object { ... }`, `object : Foo { ... }`,
    /// `object : Parent(args), Iface { ... }`. Captures the enclosing scope
    /// for method bodies (closure-like). Each occurrence produces a fresh
    /// `ClassDef` and a single instance.
    ObjectExpr {
        supertypes: Vec<TypeRef>,
        supertype_args: Vec<Option<Vec<Expr>>>,
        supertype_delegates: Vec<Option<Expr>>,
        members: Vec<Decl>,
        span: Span,
    },
}

/// `when (val name: Ty = subject)` — binds `name` to the subject's value
/// for the duration of the when's branches. `ty` is `None` when the
/// source omitted the type annotation.
#[derive(Debug, Clone)]
pub struct WhenBinding {
    pub name: Ident,
    pub ty: Option<TypeRef>,
    pub annotations: Vec<Annotation>,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct WhenBranch {
    /// Comma-separated patterns on the left of `->`. A branch fires when any
    /// pattern matches. An `Else` pattern can only appear by itself.
    pub patterns: Vec<WhenPattern>,
    pub body: Expr,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct WhenPattern {
    pub kind: WhenPatternKind,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub enum WhenPatternKind {
    /// `value` — equality match against the subject (subject-bound `when`),
    /// or Boolean condition (subject-free `when`).
    Value(Expr),
    /// `in expr` — `subject in expr` membership.
    InRange(Expr),
    /// `!in expr` — `subject !in expr` membership.
    NotInRange(Expr),
    /// `is Type` — runtime type check on the subject. Implies a smart cast
    /// for the branch body when the subject is a single identifier.
    IsType(TypeRef),
    /// `!is Type`.
    NotIsType(TypeRef),
    /// `else` — fallthrough. Only valid as the sole pattern in its branch.
    Else,
}

#[derive(Debug, Clone)]
pub struct Catch {
    pub binding: Ident,
    pub ty: TypeRef,
    pub body: Block,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub enum StringPart {
    Text(String),
    ShortInterp(Ident),
    Interp(Expr),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BinOp {
    Add, Sub, Mul, Div, Rem,
    Eq, Neq, IdentEq, IdentNeq,
    Lt, Le, Gt, Ge,
    /// `lhs in rhs` — membership. Implemented by `value_in` in the interp.
    In,
    /// `lhs !in rhs`.
    NotIn,
    And, Or,
    Range, RangeUntil,
    Elvis,
    Assign,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UnOp {
    Neg,
    Pos,
    Not,
    PreInc,
    PreDec,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PostfixOp {
    Inc,
    Dec,
    NotNull,
}

impl Expr {
    #[must_use]
    pub fn span(&self) -> Span {
        match self {
            Self::IntLit { span, .. }
            | Self::FloatLit { span, .. }
            | Self::BoolLit { span, .. }
            | Self::NullLit { span }
            | Self::CharLit { span, .. }
            | Self::StringTemplate { span, .. }
            | Self::Path { span, .. }
            | Self::Member { span, .. }
            | Self::Call { span, .. }
            | Self::Index { span, .. }
            | Self::Binary { span, .. }
            | Self::Unary { span, .. }
            | Self::Postfix { span, .. }
            | Self::If { span, .. }
            | Self::While { span, .. }
            | Self::DoWhile { span, .. }
            | Self::For { span, .. }
            | Self::Return { span, .. }
            | Self::Break { span, .. }
            | Self::Continue { span, .. }
            | Self::Labeled { span, .. }
            | Self::Throw { span, .. }
            | Self::Try { span, .. }
            | Self::Lambda { span, .. }
            | Self::This { span, .. }
            | Self::Super { span, .. }
            | Self::PropertyRef { span, .. }
            | Self::MemberRef { span, .. }
            | Self::When { span, .. }
            | Self::IsCheck { span, .. }
            | Self::As { span, .. }
            | Self::AnonFun { span, .. }
            | Self::Spread { span, .. }
            | Self::ObjectExpr { span, .. } => *span,
            Self::Block(b) => b.span,
        }
    }
}
