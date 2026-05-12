//! Tolerant static type checker.

use std::collections::{HashMap, HashSet};

use klio_ast::{
    Accessor, AssignOp, BinOp, Block, Class, CtorDelegation, Decl, EnumEntry, Expr,
    Function, FunctionBody, KotlinFile, ObjectDecl, Param, PostfixOp, Property,
    SecondaryCtor, Stmt, StringPart, TypeRef, UnOp, Visibility, WhenBranch, WhenPatternKind,
};
use klio_diagnostics::{Diagnostic, DiagnosticSink};
use klio_resolver::Resolution;
use klio_span::Span;
use klio_types::{builtin_by_name, convert_type_ref_lossy, Type};

/// Output of the type-checking pass.
#[derive(Debug)]
pub struct TypeCheck {
    /// Type assigned to each expression by its span. Statements have no
    /// entry. Spans not in this map were either skipped or assigned
    /// `Type::Unresolved`.
    pub types: HashMap<Span, Type>,
    pub diagnostics: DiagnosticSink,
}

impl TypeCheck {
    /// Look up the type assigned to an expression by span.
    #[must_use]
    pub fn type_of(&self, span: Span) -> Option<&Type> {
        self.types.get(&span)
    }
}

/// Public entry point. `resolution` is the resolver's output for the same
/// file; the checker reads it but does not mutate it.
#[must_use]
pub fn typecheck(file: &KotlinFile, resolution: &Resolution) -> TypeCheck {
    let mut tc = Checker::new(resolution);
    tc.run(file);
    TypeCheck {
        types: tc.types,
        diagnostics: tc.diagnostics,
    }
}

/// Diagnostic codes emitted by the type checker.
pub mod codes {
    pub const TYPE_MISMATCH: &str = "T0001";
    pub const TYPE_UNRESOLVED_REFERENCE: &str = "T0002";
    pub const TYPE_NULL_SAFETY: &str = "T0003";
    pub const TYPE_ARGUMENT_COUNT: &str = "T0004";
    pub const TYPE_MISSING_RETURN: &str = "T0005";
    pub const TYPE_VAL_REASSIGN: &str = "T0006";
    pub const TYPE_ABSTRACT_MEMBER_NOT_IMPLEMENTED: &str = "T0007";
    pub const TYPE_WRONG_RECEIVER: &str = "T0008";
    /// Subclass declares a member with the same simple name as a parent's
    /// `open` member without `override`.
    pub const TYPE_OVERRIDE_NEEDED: &str = "T0009";
    /// Override marker on a member whose parent declaration is not `open`.
    pub const TYPE_OVERRIDE_BUT_PARENT_NOT_OPEN: &str = "T0010";
    /// Override marker on a member that has no matching parent declaration.
    pub const TYPE_OVERRIDE_BUT_NO_BASE: &str = "T0011";
    /// A class used as a property delegate (`val x by D()`) declares
    /// `getValue` / `setValue` without the `operator` modifier. Kotlin
    /// requires the modifier on delegate-convention functions; emitted as
    /// a warning so existing user code remains runnable until the parity
    /// pipeline gates on it.
    pub const TYPE_DELEGATE_OPERATOR_REQUIRED: &str = "T0012";
    /// A concrete class inherits two or more interface/superclass defaults
    /// for the same simple-name member but does not declare its own
    /// `override`. Kotlin requires an explicit override to disambiguate.
    pub const TYPE_DIAMOND_CONFLICT: &str = "T0013";
    /// `lateinit val` — Kotlin only permits `lateinit var`.
    pub const TYPE_LATEINIT_VAL: &str = "T0014";
    /// `lateinit` on a primitive-typed property (`Int`, `Long`, `Short`,
    /// `Byte`, `Float`, `Double`, `Boolean`, `Char`). Not allowed.
    pub const TYPE_LATEINIT_PRIMITIVE: &str = "T0015";
    /// `lateinit` with an initializer expression. Mutually exclusive.
    pub const TYPE_LATEINIT_WITH_INITIALIZER: &str = "T0016";
    /// `lateinit` on a nullable type. Kotlin forbids it — lateinit
    /// guarantees a non-null value after initialization.
    pub const TYPE_LATEINIT_NULLABLE: &str = "T0017";
    /// Accessor declared an explicit return-type annotation that does
    /// not match the property's declared type.
    pub const TYPE_ACCESSOR_RETURN_TYPE_MISMATCH: &str = "T0018";
    /// `when` over a sealed-class subject is non-exhaustive: some subclasses
    /// are not covered and no `else` branch is present.
    pub const TYPE_WHEN_NOT_EXHAUSTIVE: &str = "T0019";
    /// Read of a `var` declared without an initializer before any write on
    /// the path reaching the read site.
    pub const TYPE_VAR_NOT_DEFINITELY_ASSIGNED: &str = "T0020";
    /// Use-site variance violation: a generic instantiation supplies a type
    /// argument that conflicts with declared / projected variance.
    pub const TYPE_VARIANCE_VIOLATION: &str = "T0021";
    /// Type argument supplied to a generic does not satisfy its declared
    /// upper bound.
    pub const TYPE_BOUND_NOT_SATISFIED: &str = "T0022";
    /// `reified` type parameter on a function that is not declared `inline`.
    pub const TYPE_REIFIED_REQUIRES_INLINE: &str = "T0023";
    /// Declaration-site variance violation: an `out` type parameter appears
    /// in an input position, or an `in` type parameter appears in an output
    /// position.
    pub const TYPE_DECLARATION_VARIANCE_VIOLATION: &str = "T0024";
    /// `vararg` parameter must be unique and trailing (followed only by
    /// parameters with default values).
    pub const TYPE_VARARG_MISUSE: &str = "T0025";
    /// `crossinline` / `noinline` parameter modifier on a function that is
    /// not declared `inline`.
    pub const TYPE_INLINE_MODIFIER_OUTSIDE_INLINE: &str = "T0026";
    /// `T & Any` definitely-non-nullable type used where `T` is not a type
    /// parameter — the form is only meaningful for type-parameter
    /// receivers per Kotlin spec.
    pub const TYPE_DEFINITELY_NON_NULL_NOT_TYPE_PARAM: &str = "T0027";
    /// `expr as List<String>` / `expr as Map<K, V>` — runtime cast against
    /// erased generic type arguments. Warning only, matching kotlinc-native.
    pub const TYPE_UNCHECKED_CAST: &str = "T0028";
    /// `a foo b` where `foo` resolves to a function declared without the
    /// `infix` modifier.
    pub const TYPE_INFIX_MODIFIER_REQUIRED: &str = "T0029";
    /// `return@label` / `break@label` / `continue@label` where the label
    /// name is not lexically bound by an enclosing loop or labeled lambda.
    pub const TYPE_UNRESOLVED_LABEL: &str = "T0030";
    /// Access to a `private` / `protected` class member from outside the
    /// declaring class (and outside subclasses, for `protected`).
    pub const TYPE_INVISIBLE_MEMBER: &str = "T0031";
    /// Reference to a `private` top-level declaration from outside its
    /// declaring file. With the current single-file analysis pipeline
    /// cross-file references already surface as `UNRESOLVED_REFERENCE`;
    /// the code is reserved for once multi-file resolution lands.
    pub const TYPE_INVISIBLE_REFERENCE: &str = "T0032";
    /// `const val` declared outside top-level / `object` scope.
    pub const TYPE_CONST_VAL_NOT_TOPLEVEL: &str = "T0033";
    /// `const val` whose initializer is missing, non-constant, or whose
    /// declared type is not a permitted compile-time-constant type, or
    /// which declares `get` / `set` / `by` accessors.
    pub const TYPE_CONST_VAL_NON_CONST_INIT: &str = "T0034";
    /// `value class` / `inline class` declaration whose shape violates the
    /// Kotlin rules (open / abstract / sealed, secondary body, init blocks,
    /// non-Any supertype, bad primary-ctor shape, `equals` / `hashCode`
    /// override, etc.).
    pub const TYPE_VALUE_CLASS_SHAPE: &str = "T0035";
    /// `annotation class` declaration whose shape violates the Kotlin rules
    /// (non-empty body, secondary constructors, open / abstract / data /
    /// enum / inner / value, non-Any supertype).
    pub const TYPE_ANNOTATION_CLASS_SHAPE: &str = "T0036";
    /// `annotation class` primary-ctor property whose type is not one of
    /// the permitted annotation-parameter types.
    pub const TYPE_ANNOTATION_PARAM_TYPE: &str = "T0037";
    /// `typealias Foo = Foo` — alias references itself directly or
    /// transitively through another alias.
    pub const TYPE_RECURSIVE_TYPEALIAS: &str = "T0038";
    /// `typealias` declared inside a class body, function body, or other
    /// non-top-level scope. Kotlin allows aliases only at top level.
    pub const TYPE_TYPEALIAS_NOT_TOPLEVEL: &str = "T0039";
    /// Extension property declared with an initializer (`val T.foo = ...`).
    pub const TYPE_EXTENSION_PROPERTY_HAS_INITIALIZER: &str = "T0040";
    /// Extension property declared with a `by` delegate.
    pub const TYPE_EXTENSION_PROPERTY_HAS_DELEGATE: &str = "T0041";
    /// Extension property without a custom getter (and a setter when `var`).
    pub const TYPE_EXTENSION_PROPERTY_NEEDS_ACCESSOR: &str = "T0042";
    /// Supertype delegation target is not an interface. Kotlin only permits
    /// `class C : I by d` when `I` is an interface.
    pub const TYPE_DELEGATION_TARGET_NOT_INTERFACE: &str = "T0043";
    /// Supertype delegation expression's static type is not a subtype of the
    /// named interface.
    pub const TYPE_DELEGATION_TYPE_MISMATCH: &str = "T0044";
    /// `data object Foo` declares `equals` / `hashCode`. The spec
    /// auto-generates identity-based versions and forbids overrides.
    pub const TYPE_DATA_OBJECT_FORBIDS_EQUALS_HASHCODE: &str = "T0045";
    /// Bare `field` identifier referenced outside a property accessor body,
    /// or inside an accessor body for a property that has no backing field
    /// (extension property, computed property without `field`).
    pub const TYPE_BACKING_FIELD_OUTSIDE_ACCESSOR: &str = "T0046";
    /// `*expr` spread argument supplied to a parameter that is not declared
    /// `vararg`.
    pub const TYPE_SPREAD_REQUIRES_VARARG: &str = "T0047";
    /// A self-recursive call inside a `tailrec` function appears in a
    /// non-tail position. The compiler still generates the function, but
    /// emits this warning so the user knows the call won't be optimized
    /// into a loop. Matches kotlinc-native's `NON_TAIL_RECURSIVE_CALL`.
    pub const TYPE_NON_TAIL_RECURSIVE_CALL: &str = "T0048";
    /// A function declared `tailrec` contains no tail-position self-calls,
    /// so the modifier has no effect. Matches kotlinc-native's
    /// `NO_TAIL_CALLS_FOUND`.
    pub const TYPE_NO_TAIL_CALLS_FOUND: &str = "T0049";
    /// A class declared as an enum overrides one of the `final` members of
    /// `kotlin.Enum<T>` (`equals`, `hashCode`, or `compareTo`). Spec §3.9.
    pub const TYPE_ENUM_FORBIDS_FINAL_OVERRIDE: &str = "T0050";
    /// A subtype of `kotlin.Throwable` declares type parameters. Spec §3.12
    /// makes this a compile-time error.
    pub const TYPE_THROWABLE_TYPE_PARAMS: &str = "T0051";
    /// A function is declared `tailrec` together with `open` or `override`.
    /// Virtual dispatch defeats the trampoline rewrite, so kotlinc emits a
    /// warning. Matches `TAILREC_ON_VIRTUAL_MEMBER`.
    pub const TYPE_TAILREC_ON_OPEN: &str = "T0057";
    /// A `data class` body declares a `componentN` function whose signature
    /// matches one of the auto-generated component accessors. Spec §4.1.2
    /// states `componentN` cannot be explicified.
    pub const TYPE_DATA_CLASS_FORBIDS_COMPONENT_OVERRIDE: &str = "T0058";
    /// A `data class` body declares a `copy` function. Spec §4.1.2 states
    /// `copy` cannot be explicified.
    pub const TYPE_DATA_CLASS_FORBIDS_COPY_OVERRIDE: &str = "T0059";
    /// Two or more secondary constructors form a delegation cycle through
    /// `this(...)` calls. Spec §4.1.1 forbids this.
    pub const TYPE_CONSTRUCTOR_DELEGATION_CYCLE: &str = "T0060";
    /// A `data class` declares no `val`/`var` primary-constructor property.
    /// Spec §4.1.2 requires at least one data property.
    pub const TYPE_DATA_CLASS_NO_PROPERTIES: &str = "T0061";
    /// A `data class` primary-constructor property is `vararg`. Spec §4.1.2
    /// forbids this.
    pub const TYPE_DATA_CLASS_VARARG_PROPERTY: &str = "T0062";
    /// An `inline val/var` property has a backing field. Spec §4.3.4 forbids
    /// this — inline properties must have explicit accessors with no `field`.
    pub const TYPE_INLINE_PROPERTY_HAS_BACKING_FIELD: &str = "T0053";
    /// A property without a backing field (custom accessors that don't use
    /// `field`) declares an initializer. Spec §4.3.4: properties without
    /// backing fields are not allowed to have initializer expressions.
    pub const TYPE_PROPERTY_NO_BACKING_FIELD_HAS_INITIALIZER: &str = "T0054";
    /// An `inline` parameter (lambda) is used in a way that lets it escape
    /// the function: stored in a variable, returned, or passed to a
    /// non-inline callee. Spec §4.2.5.
    pub const TYPE_INLINE_PARAM_LEAK: &str = "T0055";
    /// A `crossinline` parameter is stored in a variable or returned.
    /// Capturing into other lambdas is allowed; this catches the disallowed
    /// store/return forms. Spec §4.2.5.
    pub const TYPE_CROSSINLINE_PARAM_LEAK: &str = "T0056";
    /// A class declares a non-open/abstract/sealed superclass. Spec §5.1:
    /// a class is final by default and cannot be inherited from.
    pub const TYPE_INHERIT_FROM_FINAL_CLASS: &str = "T0063";
    /// A class declares an object type as a superclass. Spec §5.1: object
    /// types cannot be inherited from.
    pub const TYPE_INHERIT_FROM_OBJECT: &str = "T0064";
    /// An overriding function's return type is not a subtype of the
    /// overridden function's return type. Spec §5.4.
    pub const TYPE_OVERRIDE_RETURN_TYPE_MISMATCH: &str = "T0065";
    /// An overriding property's mutability is stronger than the base
    /// (e.g. `var` base, `val` override). Spec §5.4.
    pub const TYPE_OVERRIDE_PROPERTY_MUTABILITY: &str = "T0066";
    /// An overriding property's type is not a subtype of the base, or two
    /// `var`s have non-equivalent types. Spec §5.4.
    pub const TYPE_OVERRIDE_PROPERTY_TYPE: &str = "T0067";
    /// An overriding declaration's explicit visibility is stronger than the
    /// overridden declaration's visibility. Spec §5.4.
    pub const TYPE_OVERRIDE_VISIBILITY_STRONGER: &str = "T0068";
    /// A declaration is `private` and also `open` / `abstract` / `override`.
    /// Spec §5.4 forbids the combination.
    pub const TYPE_PRIVATE_AND_OPEN_OR_ABSTRACT_OR_OVERRIDE: &str = "T0070";
    /// A local or anonymous type is declared as an inheritor of a `sealed`
    /// type. Spec §5.1.2: sealed inheritors must have a fully-qualified
    /// name in the same package and module.
    pub const TYPE_SEALED_INHERITOR_NOT_QUALIFIED: &str = "T0071";
    /// A `data` or `enum` class declaration carries `open` / `abstract`
    /// modifiers. Spec §5.1: data, enum, and annotation classes are
    /// always closed.
    pub const TYPE_DATA_OR_ENUM_CLASS_OPEN_OR_ABSTRACT: &str = "T0072";
    /// A label was attached to an expression that is not labelable per
    /// spec §6.3 (only lambda literals, loops, and calls that pass a
    /// trailing lambda may carry a label).
    pub const TYPE_LABEL_TARGET_NOT_LABELABLE: &str = "T0078";
    /// A top-level property's initializer participates in a read cycle
    /// with other top-level properties. Spec §6 note: initialization
    /// cycles in declaration scopes have unspecified behavior.
    pub const TYPE_PROPERTY_INITIALIZER_CYCLE: &str = "T0076";
    /// A primary-constructor parameter that is not marked `val` / `var`
    /// (i.e. not a property) is read from a member function or accessor
    /// body. Spec §6.1: such params are only DLD to the classifier
    /// initialization scope, so methods cannot see them.
    pub const TYPE_NON_PROPERTY_CTOR_PARAM_OUT_OF_SCOPE: &str = "T0075";
    /// `A === B` or `A !== B` where the static types of `A` and `B` are
    /// definitely-distinct and unrelated by subtyping. Spec §8.9.1: such
    /// reference-equality expressions are invalid.
    pub const TYPE_REFERENCE_EQUALITY_DISTINCT_TYPES: &str = "T0081";
    /// `A == B` or `A != B` where the static types of `A` and `B` are
    /// definitely-distinct and unrelated by subtyping. Spec §8.9.2.
    pub const TYPE_VALUE_EQUALITY_DISTINCT_TYPES: &str = "T0082";
    /// `e as? T` where `T` is a type parameter not declared `reified`. Spec
    /// §8.16: when `T` is not runtime-available the check is not performed,
    /// so the runtime can return a value of an unrelated type. Warning.
    pub const TYPE_CAST_TO_NON_REIFIED_TYPE_PARAMETER: &str = "T0083";
    /// Bare type syntax in `is` / `as` whose type-argument inference would
    /// produce a star-projection slot. Spec §8.11.1.
    pub const TYPE_BARE_TYPE_INFERENCE_FAILED: &str = "T0084";
    /// A non-private function or property returns / exposes an object
    /// literal value whose anonymous type has more than one declared
    /// supertype without an explicit return-type ascription. Spec §8.23.
    pub const TYPE_ANONYMOUS_OBJECT_ESCAPES_PUBLIC: &str = "T0085";
    /// `*expr` spread argument whose element type is not a subtype of the
    /// declared vararg parameter's element type. Spec §8.21.5.
    pub const TYPE_SPREAD_TYPE_MISMATCH: &str = "T0086";
}

/// A scope frame mapping local names to their declared/inferred types
/// and mutability. Frames stack lexically.
#[derive(Debug, Default, Clone)]
struct Frame {
    /// `name -> (declared type, mutable?)`. `mutable=false` lets us flag
    /// `val` reassignment.
    bindings: HashMap<String, Binding>,
    /// Smart-cast narrowings active in this frame. Keyed by dot-path —
    /// either a bare local name (`"x"`) or a member chain
    /// (`"box.shape"`, `"o.inner.value"`). Stored separately from
    /// declarations so we can pop them without disturbing bindings.
    narrowings: HashMap<String, Type>,
    /// Companion class-name narrowings parallel to `narrowings`, used to
    /// keep `expr_class` propagation alive through chains involving a
    /// smart-cast prefix (e.g. after `if (n.shape is Circle)`, access
    /// `n.shape.radius` resolves through the `Circle` member table).
    narrowing_class: HashMap<String, String>,
}

#[derive(Debug, Clone)]
struct Binding {
    ty: Type,
    mutable: bool,
    /// Span of the declaration site for nicer diagnostics.
    #[allow(dead_code)]
    decl_span: Option<Span>,
    /// User-class name when the binding's declared/inferred type refers to a
    /// user class (not a builtin / function type). Used by sealed-`when`
    /// exhaustiveness, member-access lookup, and smart-cast widening of
    /// `val` properties.
    class_name: Option<String>,
    /// True for `var` declarations that lack both an initializer and the
    /// `lateinit` modifier. Reads through such a binding must be preceded
    /// by an unconditional write on every control-flow path; otherwise the
    /// definite-assignment check (T0020) fires.
    needs_init: bool,
}


/// One extension declaration on a given receiver type.
#[derive(Debug, Clone)]
struct ExtensionSig {
    name: String,
    sig: FnSig,
    /// User-class name of the declared return type, when applicable.
    /// Drives `expr_class` propagation for `recv.ext()` chains the same
    /// way `ClassInfo.member_class` does for regular members.
    return_class: Option<String>,
}

/// One extension-property declaration on a given receiver type.
#[derive(Debug, Clone)]
struct ExtensionPropSig {
    name: String,
    ty: Type,
    #[allow(dead_code)]
    mutable: bool,
    return_class: Option<String>,
}

/// Description of a user-declared function, used to check call sites
/// when the callee resolves to a top-level function or a member.
#[derive(Debug, Clone)]
struct FnSig {
    /// Parameter declared types in source order.
    params: Vec<Type>,
    /// True for each parameter that has a default value.
    has_default: Vec<bool>,
    /// True for each parameter whose name we know (for named-arg calls).
    param_names: Vec<String>,
    /// True for each parameter declared `vararg`.
    is_vararg: Vec<bool>,
    return_ty: Type,
    /// True when the source declared the function with the `infix` modifier.
    /// Required to be `true` for the call to appear in `a name b` form.
    is_infix: bool,
}

/// Description of a user-declared class.
#[derive(Debug, Clone, Default)]
struct ClassInfo {
    /// Has any secondary constructor — we then relax primary-ctor arity
    /// checks to avoid false positives, since the resolver / interp pick
    /// the matching overload at runtime.
    has_secondary_ctors: bool,
    /// Member name -> type. Covers primary-param properties, body
    /// properties, and methods (as `Type::Function`).
    members: HashMap<String, Type>,
    /// Member name -> mutable? (only for properties).
    member_mutable: HashMap<String, bool>,
    /// Constructor parameter list (primary). Used to type-check `Box(...)`.
    ctor: Option<FnSig>,
    /// Names of declared abstract members on this class.
    abstract_members: Vec<String>,
    /// Names of declared concrete members on this class.
    concrete_members: Vec<String>,
    /// Per-member modifier flags: `is_open`, `is_override`. Used to drive
    /// the override-diagnostic codes T0009/T0010/T0011.
    member_flags: HashMap<String, MemberFlags>,
    /// Per-member detailed signature used by T0065 / T0066 / T0067 / T0068.
    member_sigs: HashMap<String, MemberSig>,
    /// Member name -> user-class name when the member's declared type
    /// names a user class. Populated alongside `members` so member access
    /// can propagate `expr_class` through chains like `foo.bar.baz`.
    member_class: HashMap<String, String>,
    /// Names of supertypes (raw — interfaces or classes).
    supertypes: Vec<String>,
    is_abstract: bool,
    is_interface: bool,
    is_sealed: bool,
    #[allow(dead_code)]
    is_open: bool,
    /// `object` singleton — registered in `classes` so member lookup works
    /// but never inheritable and never instantiable.
    is_object: bool,
    /// Declared inside a function body (local class) or via `object { … }`
    /// (anonymous object). Used to enforce the sealed-inheritor §5.1.2
    /// rule that disallows local / anonymous inheritors.
    is_local_or_anonymous: bool,
    /// Member name -> effective visibility for access checks. Captures
    /// primary-param properties, body properties, methods, and secondary
    /// constructor bodies. Defaults to `Public`.
    member_visibility: HashMap<String, Visibility>,
    /// Visibility of the class itself. Drives constructor-call access
    /// checks: invoking `Foo(...)` outside the declaring file when the
    /// class is `private`, or invoking it from an unrelated scope when
    /// the class is `protected`, is rejected.
    decl_visibility: Visibility,
    /// File the class is declared in. Used by `private`-class enforcement.
    decl_file: Option<klio_span::FileId>,
    /// Visibility of the primary constructor when it diverges from the
    /// class itself (`class Foo private constructor(...)`). `None` means
    /// the constructor inherits the class visibility.
    primary_ctor_visibility: Option<Visibility>,
}

/// Detailed per-member signature used by override-rule diagnostics
/// (T0065 / T0066 / T0067 / T0068). Stored separately from `MemberFlags`
/// so existing name-keyed override walks keep their semantics.
#[derive(Debug, Clone)]
enum MemberSig {
    Function {
        #[allow(dead_code)]
        param_types: Vec<Type>,
        return_ty: Type,
        visibility: Visibility,
    },
    Property {
        ty: Type,
        mutable: bool,
        visibility: Visibility,
    },
}

#[derive(Debug, Clone, Copy, Default)]
struct MemberFlags {
    is_open: bool,
    is_override: bool,
    is_abstract: bool,
    /// True when a `fun` member carried the `operator` modifier. Used to
    /// drive the T0012 delegate-operator check.
    is_operator: bool,
    /// True when a `fun` member carried the `infix` modifier.
    is_infix: bool,
    /// True when a `fun` member declares an actual body (default
    /// implementation). Used by the diamond-conflict check to identify
    /// methods that two supertypes supply concretely.
    has_default_body: bool,
}

struct Checker<'a> {
    resolution: &'a Resolution,
    types: HashMap<Span, Type>,
    /// User-class name attached to an expression by span — populated for
    /// path / `this` / constructor-call sites whose static type is a
    /// user-declared class. The plain `Type` enum collapses user classes
    /// to `Unresolved`, so this side map carries the identity that
    /// sealed-`when`, member access, and smart casts need.
    expr_class: HashMap<Span, String>,
    /// Names of locals that are definitely assigned at the current
    /// program point. Drives the T0020 definite-assignment check.
    assigned: HashSet<String>,
    /// Inferred element type for an expression whose runtime value is a
    /// `List<T>`. The plain `Type` enum has no generic `List` variant, so
    /// chains like `listOf(1).map { it * 2 }.fold(0) { a, b -> a + b }`
    /// use this side channel to flow `T` from the seed through `map` /
    /// `filter` / `fold` lambda parameters and into the chain's result.
    list_elem: HashMap<Span, Type>,
    diagnostics: DiagnosticSink,
    frames: Vec<Frame>,
    /// File-level user functions.
    /// Top-level user functions keyed by simple name. A name maps to a
    /// list of signatures so positional overloads can be picked at call
    /// sites by first-fit on argument types.
    fns: HashMap<String, Vec<FnSig>>,
    /// User-declared extension functions keyed by the receiver type's
    /// simple name. Member-call typing (`recv.foo(args)`) consults this
    /// after instance-member lookup falls through, walks the receiver's
    /// class chain, and uses the same first-fit overload resolution as
    /// regular function calls.
    extensions: HashMap<String, Vec<ExtensionSig>>,
    /// Extension properties keyed by simple receiver-type name. Consulted
    /// at `recv.prop` sites after class-member lookup falls through.
    extension_properties: HashMap<String, Vec<ExtensionPropSig>>,
    /// File-level user classes.
    classes: HashMap<String, ClassInfo>,
    /// Name of the enclosing class while we type-check a class body, so
    /// `this` can be typed. Stack to support nested classes.
    class_stack: Vec<String>,
    /// Enclosing function's declared/inferred return type for `return`.
    fn_return_stack: Vec<Type>,
    /// Lexically active jump labels bound by enclosing loops or `Labeled`
    /// expressions. Used to validate `return@l` / `break@l` / `continue@l`
    /// against bound names (T0030).
    label_stack: Vec<String>,
    /// Visibility + declaring file for each top-level function name. A
    /// name maps to one entry per declared overload. Drives the T0032
    /// invisible-reference check at call / reference sites.
    fn_visibility: HashMap<String, Vec<(Visibility, klio_span::FileId)>>,
    /// Visibility + declaring file for each top-level property.
    prop_visibility: HashMap<String, (Visibility, klio_span::FileId)>,
    /// Per-setter visibility for top-level `var` properties whose setter is
    /// more restrictive than the property itself (`var x; private set`).
    /// Spec §4.6: gates writes from outside the declaring scope.
    setter_visibility: HashMap<String, (Visibility, klio_span::FileId)>,
    /// Top-level type aliases keyed by simple name. Phase G unfolds these at
    /// every type-reference site through `unfold_typeref` so the downstream
    /// type machinery never sees an alias name.
    aliases: HashMap<String, TypeAliasInfo>,
    /// Stack of "is the enclosing function `public inline`?" flags. Used by
    /// the J6 @PublishedApi visibility check: inside a public-inline body,
    /// references to `internal` declarations are forbidden unless the
    /// target carries `@PublishedApi`.
    public_inline_stack: Vec<bool>,
    /// Stack of reified type-parameter name sets for each enclosing
    /// function. Used at `as?` / `as` sites to decide whether the target
    /// type is runtime-available.
    reified_type_params: Vec<std::collections::HashSet<String>>,
    /// Stack of all type-parameter names in scope (reified + non-reified)
    /// for each enclosing function / class. Parallel to
    /// `reified_type_params`.
    type_params_in_scope: Vec<std::collections::HashSet<String>>,
    /// Annotations of each top-level function overload, parallel to
    /// `fns`. Used by J6 to look up `@PublishedApi`.
    fn_annotations: HashMap<String, Vec<Vec<klio_ast::Annotation>>>,
    /// Annotations of each top-level property by simple name.
    prop_annotations: HashMap<String, Vec<klio_ast::Annotation>>,
}

/// Description of a user-declared `typealias`.
#[derive(Debug, Clone)]
struct TypeAliasInfo {
    /// Declared type-parameter names in source order. Reserved for the
    /// generic-substitution path (alias use sites with explicit type args).
    #[allow(dead_code)]
    type_params: Vec<String>,
    /// Right-hand-side `TypeRef` — the alias target.
    target: TypeRef,
    /// Span of the alias's name for cycle-diagnostic labeling.
    name_span: Span,
}

impl<'a> Checker<'a> {
    fn new(resolution: &'a Resolution) -> Self {
        Self {
            resolution,
            types: HashMap::new(),
            expr_class: HashMap::new(),
            assigned: HashSet::new(),
            list_elem: HashMap::new(),
            diagnostics: DiagnosticSink::new(),
            frames: vec![Frame::default()],
            fns: HashMap::new(),
            extensions: HashMap::new(),
            extension_properties: HashMap::new(),
            classes: HashMap::new(),
            class_stack: Vec::new(),
            fn_return_stack: Vec::new(),
            label_stack: Vec::new(),
            fn_visibility: HashMap::new(),
            prop_visibility: HashMap::new(),
            setter_visibility: HashMap::new(),
            aliases: HashMap::new(),
            public_inline_stack: Vec::new(),
            reified_type_params: Vec::new(),
            type_params_in_scope: Vec::new(),
            fn_annotations: HashMap::new(),
            prop_annotations: HashMap::new(),
        }
    }

    fn run(&mut self, file: &KotlinFile) {
        // First pass: seed signatures of top-level functions, classes and
        // top-level property types so forward references in bodies typecheck.
        for d in &file.decls {
            self.declare_top_level(d);
        }
        // Second pass: typecheck bodies.
        for d in &file.decls {
            self.check_decl(d);
        }
        // M28: generics-related diagnostics (reified/inline, vararg, declaration-site variance).
        for d in &file.decls {
            self.check_m28_decl(d);
        }
        // T0027: definitely-non-nullable (`T & Any`) used outside a type parameter.
        let mut tp_scope: Vec<HashSet<String>> = vec![HashSet::new()];
        for d in &file.decls {
            self.check_definitely_non_null_decl(d, &mut tp_scope);
        }
        // Phase F: `const val`, `value class`, `annotation class` shape checks.
        for d in &file.decls {
            self.check_phase_f_decl(d, PhaseFScope::TopLevel);
        }
        // Phase G: typealias scope + cycle checks.
        for d in &file.decls {
            self.check_phase_g_decl(d, /*at_top_level=*/ true);
        }
        self.check_typealias_cycles();
        // Phase H: extension property shape checks.
        for d in &file.decls {
            self.check_phase_h_decl(d);
        }
        // Phase J: data object, backing-field, spread, @PublishedApi.
        for d in &file.decls {
            self.check_phase_j_decl(d, /*in_accessor=*/ false);
        }
        // Phase K: `tailrec` tail-call analysis.
        for d in &file.decls {
            self.check_phase_k_decl(d);
        }
        // T0076: top-level property initializer cycles (spec §6).
        self.check_property_initializer_cycles(file);
        // T0075: non-property primary-ctor param read from method body.
        for d in &file.decls {
            self.check_ctor_param_scope_decl(d);
        }
    }

    fn check_ctor_param_scope_decl(&mut self, d: &Decl) {
        match d {
            Decl::Class(c) => {
                // Names visible as members of this class — own members and
                // transitively inherited supertype members / properties — are
                // shadowed by their member binding rather than the ctor
                // param. Skip those names when computing the non-property set.
                let member_names = self.collect_member_name_set(c);
                let non_prop: std::collections::HashMap<String, Span> = c
                    .primary_params
                    .iter()
                    .filter(|p| p.property.is_none() && !member_names.contains(&p.name.name))
                    .map(|p| (p.name.name.clone(), p.name.span))
                    .collect();
                if !non_prop.is_empty() {
                    for m in &c.members {
                        match m {
                            Decl::Function(f) => {
                                if let Some(body) = &f.body {
                                    let mut local: std::collections::HashSet<String> = f
                                        .params
                                        .iter()
                                        .map(|p| p.name.name.clone())
                                        .collect();
                                    self.check_ctor_param_in_body(body, &non_prop, &mut local);
                                }
                            }
                            Decl::Property(p) => {
                                // Property initializers run during instance
                                // init — non-property ctor params are visible
                                // there. Accessor bodies, however, are
                                // invoked post-construction and must not see
                                // them.
                                if let Some(getter) = &p.getter {
                                    let mut local = std::collections::HashSet::new();
                                    self.check_ctor_param_in_body(&getter.body, &non_prop, &mut local);
                                }
                                if let Some(setter) = &p.setter {
                                    let mut local: std::collections::HashSet<String> =
                                        setter.params.iter().map(|i| i.name.clone()).collect();
                                    self.check_ctor_param_in_body(&setter.body, &non_prop, &mut local);
                                }
                            }
                            _ => {}
                        }
                    }
                }
                for m in &c.members {
                    self.check_ctor_param_scope_decl(m);
                }
            }
            Decl::Object(o) => {
                for m in &o.members {
                    self.check_ctor_param_scope_decl(m);
                }
            }
            _ => {}
        }
    }

    /// Names that resolve as class members at any point in the class's
    /// inheritance chain — own properties / functions / property-form ctor
    /// params, plus transitively inherited equivalents via `self.classes`.
    fn collect_member_name_set(&self, c: &Class) -> std::collections::HashSet<String> {
        let mut out = std::collections::HashSet::new();
        for p in &c.primary_params {
            if p.property.is_some() {
                out.insert(p.name.name.clone());
            }
        }
        for m in &c.members {
            match m {
                Decl::Function(f) => {
                    out.insert(f.name.name.clone());
                }
                Decl::Property(p) => {
                    out.insert(p.name.name.clone());
                }
                _ => {}
            }
        }
        for s in &c.supertypes {
            if let Some(info) = self.classes.get(&s.name.name) {
                for k in info.members.keys() {
                    out.insert(k.clone());
                }
            }
        }
        out
    }

    fn check_ctor_param_in_body(
        &mut self,
        body: &FunctionBody,
        non_prop: &std::collections::HashMap<String, Span>,
        local: &mut std::collections::HashSet<String>,
    ) {
        match body {
            FunctionBody::Block(b) => self.check_ctor_param_in_block(b, non_prop, local),
            FunctionBody::Expr(e) => self.check_ctor_param_in_expr(e, non_prop, local),
        }
    }

    fn check_ctor_param_in_block(
        &mut self,
        b: &Block,
        non_prop: &std::collections::HashMap<String, Span>,
        local: &mut std::collections::HashSet<String>,
    ) {
        for s in &b.stmts {
            match s {
                Stmt::Expr(e) => self.check_ctor_param_in_expr(e, non_prop, local),
                Stmt::Assign { target, value, .. } => {
                    self.check_ctor_param_in_expr(target, non_prop, local);
                    self.check_ctor_param_in_expr(value, non_prop, local);
                }
                Stmt::Decl(Decl::Property(p)) => {
                    if let Some(init) = &p.init {
                        self.check_ctor_param_in_expr(init, non_prop, local);
                    }
                    local.insert(p.name.name.clone());
                }
                Stmt::Decl(Decl::Function(f)) => {
                    local.insert(f.name.name.clone());
                }
                Stmt::DestructuringDecl { names, init, .. } => {
                    self.check_ctor_param_in_expr(init, non_prop, local);
                    for n in names {
                        if n.name != "_" {
                            local.insert(n.name.clone());
                        }
                    }
                }
                _ => {}
            }
        }
    }

    fn check_ctor_param_in_expr(
        &mut self,
        e: &Expr,
        non_prop: &std::collections::HashMap<String, Span>,
        local: &mut std::collections::HashSet<String>,
    ) {
        match e {
            Expr::Path { segments, .. } => {
                if let Some(first) = segments.first() {
                    if segments.len() == 1 && !local.contains(&first.name) {
                        if non_prop.contains_key(&first.name) {
                            self.diagnostics.emit(
                                Diagnostic::error(
                                    format!(
                                        "`{}` is a primary-constructor parameter (not a `val`/`var`) and is not in scope here; declare it as `val {0}` to promote it to a property",
                                        first.name
                                    ),
                                    first.span,
                                )
                                .with_code(codes::TYPE_NON_PROPERTY_CTOR_PARAM_OUT_OF_SCOPE),
                            );
                        }
                    }
                }
            }
            Expr::Member { receiver, .. } => self.check_ctor_param_in_expr(receiver, non_prop, local),
            Expr::Call { callee, args, .. } => {
                self.check_ctor_param_in_expr(callee, non_prop, local);
                for a in args {
                    self.check_ctor_param_in_expr(a, non_prop, local);
                }
            }
            Expr::Index { receiver, args, .. } => {
                self.check_ctor_param_in_expr(receiver, non_prop, local);
                for a in args {
                    self.check_ctor_param_in_expr(a, non_prop, local);
                }
            }
            Expr::Binary { lhs, rhs, .. } => {
                self.check_ctor_param_in_expr(lhs, non_prop, local);
                self.check_ctor_param_in_expr(rhs, non_prop, local);
            }
            Expr::Unary { expr, .. } | Expr::Postfix { expr, .. } => {
                self.check_ctor_param_in_expr(expr, non_prop, local);
            }
            Expr::If { cond, then_branch, else_branch, .. } => {
                self.check_ctor_param_in_expr(cond, non_prop, local);
                self.check_ctor_param_in_expr(then_branch, non_prop, local);
                if let Some(eb) = else_branch {
                    self.check_ctor_param_in_expr(eb, non_prop, local);
                }
            }
            Expr::While { cond, body, .. } => {
                self.check_ctor_param_in_expr(cond, non_prop, local);
                self.check_ctor_param_in_expr(body, non_prop, local);
            }
            Expr::DoWhile { body, cond, .. } => {
                if let Some(b) = body {
                    self.check_ctor_param_in_expr(b, non_prop, local);
                }
                self.check_ctor_param_in_expr(cond, non_prop, local);
            }
            Expr::For { iter, body, vars, .. } => {
                self.check_ctor_param_in_expr(iter, non_prop, local);
                let mut inner = local.clone();
                for v in vars {
                    inner.insert(v.name.clone());
                }
                self.check_ctor_param_in_expr(body, non_prop, &mut inner);
            }
            Expr::Block(b) => self.check_ctor_param_in_block(b, non_prop, local),
            Expr::Return { value: Some(v), .. } | Expr::Throw { value: v, .. } => {
                self.check_ctor_param_in_expr(v, non_prop, local);
            }
            Expr::Labeled { expr, .. } => self.check_ctor_param_in_expr(expr, non_prop, local),
            Expr::StringTemplate { parts, .. } => {
                for part in parts {
                    match part {
                        klio_ast::StringPart::ShortInterp(id) => {
                            if !local.contains(&id.name) && non_prop.contains_key(&id.name) {
                                self.diagnostics.emit(
                                    Diagnostic::error(
                                        format!(
                                            "`{}` is a primary-constructor parameter (not a `val`/`var`) and is not in scope here; declare it as `val {0}` to promote it to a property",
                                            id.name
                                        ),
                                        id.span,
                                    )
                                    .with_code(codes::TYPE_NON_PROPERTY_CTOR_PARAM_OUT_OF_SCOPE),
                                );
                            }
                        }
                        klio_ast::StringPart::Interp(e) => {
                            self.check_ctor_param_in_expr(e, non_prop, local)
                        }
                        klio_ast::StringPart::Text(_) => {}
                    }
                }
            }
            Expr::IsCheck { expr, .. } | Expr::As { expr, .. } | Expr::Spread { expr, .. } => {
                self.check_ctor_param_in_expr(expr, non_prop, local);
            }
            Expr::Lambda { params, body, .. } => {
                let mut inner = local.clone();
                for p in params {
                    inner.insert(p.name.clone());
                }
                self.check_ctor_param_in_block(body, non_prop, &mut inner);
            }
            Expr::When { subject, branches, .. } => {
                if let Some(s) = subject {
                    self.check_ctor_param_in_expr(s, non_prop, local);
                }
                for b in branches {
                    for p in &b.patterns {
                        match &p.kind {
                            klio_ast::WhenPatternKind::Value(e)
                            | klio_ast::WhenPatternKind::InRange(e)
                            | klio_ast::WhenPatternKind::NotInRange(e) => {
                                self.check_ctor_param_in_expr(e, non_prop, local);
                            }
                            _ => {}
                        }
                    }
                    self.check_ctor_param_in_expr(&b.body, non_prop, local);
                }
            }
            Expr::Try { body, catches, finally, .. } => {
                self.check_ctor_param_in_block(body, non_prop, local);
                for c in catches {
                    let mut inner = local.clone();
                    inner.insert(c.binding.name.clone());
                    self.check_ctor_param_in_block(&c.body, non_prop, &mut inner);
                }
                if let Some(fb) = finally {
                    self.check_ctor_param_in_block(fb, non_prop, local);
                }
            }
            _ => {}
        }
    }

    /// Detect cycles among top-level property initializer reads. A property
    /// whose initializer reads another property — directly or transitively
    /// back to itself — forms a cycle whose evaluation order is unspecified.
    fn check_property_initializer_cycles(&mut self, file: &KotlinFile) {
        use std::collections::{HashMap, HashSet};

        let mut props: Vec<(&Property, usize)> = Vec::new();
        let mut by_name: HashMap<String, usize> = HashMap::new();
        for d in &file.decls {
            if let Decl::Property(p) = d {
                if p.init.is_some() {
                    let idx = props.len();
                    by_name.insert(p.name.name.clone(), idx);
                    props.push((p, idx));
                }
            }
        }
        if props.is_empty() {
            return;
        }

        let mut edges: Vec<Vec<usize>> = vec![Vec::new(); props.len()];
        for (p, idx) in &props {
            let init = p.init.as_ref().unwrap();
            let mut reads: HashSet<usize> = HashSet::new();
            collect_property_reads(init, &by_name, &mut reads);
            edges[*idx] = reads.into_iter().collect();
        }

        // Tarjan SCC over `edges`.
        let n = edges.len();
        let mut index = 0usize;
        let mut idx_of: Vec<Option<usize>> = vec![None; n];
        let mut lowlink: Vec<usize> = vec![0; n];
        let mut on_stack: Vec<bool> = vec![false; n];
        let mut stack: Vec<usize> = Vec::new();
        let mut sccs: Vec<Vec<usize>> = Vec::new();

        fn strongconnect(
            v: usize,
            edges: &[Vec<usize>],
            index: &mut usize,
            idx_of: &mut [Option<usize>],
            lowlink: &mut [usize],
            on_stack: &mut [bool],
            stack: &mut Vec<usize>,
            sccs: &mut Vec<Vec<usize>>,
        ) {
            idx_of[v] = Some(*index);
            lowlink[v] = *index;
            *index += 1;
            stack.push(v);
            on_stack[v] = true;
            for &w in &edges[v] {
                if idx_of[w].is_none() {
                    strongconnect(w, edges, index, idx_of, lowlink, on_stack, stack, sccs);
                    lowlink[v] = lowlink[v].min(lowlink[w]);
                } else if on_stack[w] {
                    lowlink[v] = lowlink[v].min(idx_of[w].unwrap());
                }
            }
            if lowlink[v] == idx_of[v].unwrap() {
                let mut comp = Vec::new();
                loop {
                    let w = stack.pop().unwrap();
                    on_stack[w] = false;
                    comp.push(w);
                    if w == v {
                        break;
                    }
                }
                sccs.push(comp);
            }
        }

        for v in 0..n {
            if idx_of[v].is_none() {
                strongconnect(
                    v,
                    &edges,
                    &mut index,
                    &mut idx_of,
                    &mut lowlink,
                    &mut on_stack,
                    &mut stack,
                    &mut sccs,
                );
            }
        }

        for comp in &sccs {
            let is_cycle = comp.len() > 1 || edges[comp[0]].contains(&comp[0]);
            if !is_cycle {
                continue;
            }
            let names: Vec<String> = comp
                .iter()
                .map(|&i| props[i].0.name.name.clone())
                .collect();
            let chain = names.join(" -> ");
            for &i in comp {
                let p = props[i].0;
                self.diagnostics.emit(
                    Diagnostic::warning(
                        format!(
                            "Property `{}` participates in an initializer cycle: {}",
                            p.name.name, chain
                        ),
                        p.init.as_ref().unwrap().span(),
                    )
                    .with_code(codes::TYPE_PROPERTY_INITIALIZER_CYCLE),
                );
            }
        }
    }

    fn check_phase_k_decl(&mut self, d: &Decl) {
        match d {
            Decl::Function(f) => self.check_tailrec_function(f),
            Decl::Class(c) => {
                for m in &c.members {
                    self.check_phase_k_decl(m);
                }
            }
            Decl::Object(o) => {
                for m in &o.members {
                    self.check_phase_k_decl(m);
                }
            }
            Decl::Property(_) | Decl::TypeAlias(_) => {}
        }
    }

    fn check_tailrec_function(&mut self, f: &Function) {
        if !f.is_tailrec {
            return;
        }
        if f.is_open || f.is_override {
            self.diagnostics.emit(
                Diagnostic::warning(
                    "tailrec is redundant on an open or override function — virtual dispatch defeats the rewrite"
                        .to_string(),
                    f.name.span,
                )
                .with_code(codes::TYPE_TAILREC_ON_OPEN),
            );
        }
        let Some(body) = &f.body else {
            return;
        };
        let mut tail_sites = std::collections::HashSet::new();
        let mut all_sites: Vec<Span> = Vec::new();
        match body {
            FunctionBody::Block(b) => {
                tailrec_walk_block(b, true, &f.name.name, &mut tail_sites);
                tailrec_collect_all_block(b, &f.name.name, &mut all_sites);
            }
            FunctionBody::Expr(e) => {
                tailrec_walk_expr(e, true, &f.name.name, &mut tail_sites);
                tailrec_collect_all_expr(e, &f.name.name, &mut all_sites);
            }
        }
        if tail_sites.is_empty() {
            self.diagnostics.emit(
                Diagnostic::warning(
                    format!(
                        "a function is marked `tailrec` but no tail calls are found"
                    ),
                    f.name.span,
                )
                .with_code(codes::TYPE_NO_TAIL_CALLS_FOUND),
            );
        }
        for sp in &all_sites {
            if !tail_sites.contains(sp) {
                self.diagnostics.emit(
                    Diagnostic::warning(
                        format!(
                            "recursive call to `{}` is not a tail call",
                            f.name.name
                        ),
                        *sp,
                    )
                    .with_code(codes::TYPE_NON_TAIL_RECURSIVE_CALL),
                );
            }
        }
    }

    fn check_phase_f_decl(&mut self, d: &Decl, scope: PhaseFScope) {
        match d {
            Decl::Property(p) => {
                if p.is_const {
                    self.check_const_val(p, scope);
                }
                if p.is_inline {
                    self.check_inline_property(p);
                }
                // Spec §4.3.4: a property without a backing field cannot
                // declare an initializer. Skip extension properties (T0040
                // already covers that case) and abstract properties.
                if p.init.is_some()
                    && !p.is_abstract
                    && p.receiver_type.is_none()
                    && !Self::property_has_backing_field(p)
                {
                    self.diagnostics.emit(
                        Diagnostic::error(
                            format!(
                                "property `{}` has custom accessors that don't use `field`, so it \
                                 has no backing field — initializer is not allowed",
                                p.name.name
                            ),
                            p.name.span,
                        )
                        .with_code(codes::TYPE_PROPERTY_NO_BACKING_FIELD_HAS_INITIALIZER),
                    );
                }
            }
            Decl::Class(c) => {
                if c.is_value {
                    self.check_value_class(c);
                }
                if c.is_annotation {
                    self.check_annotation_class(c);
                }
                let member_scope = if c.is_companion || matches!(scope, PhaseFScope::Object) {
                    PhaseFScope::Object
                } else {
                    PhaseFScope::Class
                };
                for m in &c.members {
                    self.check_phase_f_decl(m, member_scope);
                }
            }
            Decl::Object(o) => {
                for m in &o.members {
                    self.check_phase_f_decl(m, PhaseFScope::Object);
                }
            }
            Decl::Function(_) => {}
            Decl::TypeAlias(_) => {}
        }
    }

    fn check_phase_h_decl(&mut self, d: &Decl) {
        match d {
            Decl::Property(p) => {
                if p.receiver_type.is_none() {
                    return;
                }
                if p.init.is_some() {
                    self.diagnostics.emit(
                        Diagnostic::error(
                            format!(
                                "extension property `{}` cannot have an initializer; no backing field is allowed",
                                p.name.name
                            ),
                            p.name.span,
                        )
                        .with_code(codes::TYPE_EXTENSION_PROPERTY_HAS_INITIALIZER),
                    );
                }
                if p.delegate.is_some() {
                    self.diagnostics.emit(
                        Diagnostic::error(
                            format!(
                                "extension property `{}` cannot be declared with a `by` delegate",
                                p.name.name
                            ),
                            p.name.span,
                        )
                        .with_code(codes::TYPE_EXTENSION_PROPERTY_HAS_DELEGATE),
                    );
                }
                let need_setter = p.mutable;
                let missing_getter = p.getter.is_none();
                let missing_setter = need_setter && p.setter.is_none();
                if (missing_getter || missing_setter) && p.init.is_none() && p.delegate.is_none() {
                    let what = if missing_getter && missing_setter {
                        "explicit getter and setter"
                    } else if missing_getter {
                        "explicit getter"
                    } else {
                        "explicit setter"
                    };
                    self.diagnostics.emit(
                        Diagnostic::error(
                            format!(
                                "extension property `{}` requires {what}",
                                p.name.name
                            ),
                            p.name.span,
                        )
                        .with_code(codes::TYPE_EXTENSION_PROPERTY_NEEDS_ACCESSOR),
                    );
                }
                if p.is_lateinit {
                    self.diagnostics.emit(
                        Diagnostic::error(
                            format!(
                                "extension property `{}` cannot be `lateinit`",
                                p.name.name
                            ),
                            p.name.span,
                        )
                        .with_code(codes::TYPE_EXTENSION_PROPERTY_HAS_INITIALIZER),
                    );
                }
            }
            Decl::Class(c) => {
                for m in &c.members {
                    self.check_phase_h_decl(m);
                }
            }
            Decl::Object(o) => {
                for m in &o.members {
                    self.check_phase_h_decl(m);
                }
            }
            _ => {}
        }
    }

    fn check_phase_j_decl(&mut self, d: &Decl, in_accessor: bool) {
        match d {
            Decl::Object(o) => {
                if o.is_data {
                    for m in &o.members {
                        if let Decl::Function(f) = m {
                            if f.name.name == "equals" || f.name.name == "hashCode" {
                                self.diagnostics.emit(
                                    Diagnostic::error(
                                        format!(
                                            "`data object {}` cannot override `{}`",
                                            o.name.name, f.name.name
                                        ),
                                        f.name.span,
                                    )
                                    .with_code(codes::TYPE_DATA_OBJECT_FORBIDS_EQUALS_HASHCODE),
                                );
                            }
                        }
                    }
                }
                for m in &o.members {
                    self.check_phase_j_decl(m, false);
                }
            }
            Decl::Class(c) => {
                for m in &c.members {
                    self.check_phase_j_decl(m, false);
                }
            }
            Decl::Property(p) => {
                // Extension properties never have a backing field — any
                // `field` reference inside their accessors is invalid.
                let has_backing_field = p.receiver_type.is_none();
                if let Some(g) = &p.getter {
                    self.walk_accessor_for_phase_j(g, has_backing_field, &p.name.name);
                }
                if let Some(s) = &p.setter {
                    self.walk_accessor_for_phase_j(s, has_backing_field, &p.name.name);
                }
                if let Some(init) = &p.init {
                    self.walk_expr_for_phase_j(init, in_accessor, true, &p.name.name);
                }
            }
            Decl::Function(f) => {
                if let Some(body) = &f.body {
                    match body {
                        FunctionBody::Block(b) => self.walk_block_for_phase_j(b, in_accessor, false, ""),
                        FunctionBody::Expr(e) => self.walk_expr_for_phase_j(e, in_accessor, false, ""),
                    }
                }
            }
            Decl::TypeAlias(_) => {}
        }
    }

    fn walk_accessor_for_phase_j(&mut self, a: &Accessor, has_backing_field: bool, prop_name: &str) {
        match &a.body {
            FunctionBody::Block(b) => self.walk_block_for_phase_j(b, true, has_backing_field, prop_name),
            FunctionBody::Expr(e) => self.walk_expr_for_phase_j(e, true, has_backing_field, prop_name),
        }
    }

    fn walk_block_for_phase_j(
        &mut self,
        b: &Block,
        in_accessor: bool,
        has_backing_field: bool,
        prop_name: &str,
    ) {
        for s in &b.stmts {
            match s {
                Stmt::Decl(d) => self.check_phase_j_decl(d, in_accessor),
                Stmt::Expr(e) => self.walk_expr_for_phase_j(e, in_accessor, has_backing_field, prop_name),
                Stmt::Assign { target, value, .. } => {
                    self.walk_expr_for_phase_j(target, in_accessor, has_backing_field, prop_name);
                    self.walk_expr_for_phase_j(value, in_accessor, has_backing_field, prop_name);
                }
                Stmt::DestructuringDecl { init, .. } => {
                    self.walk_expr_for_phase_j(init, in_accessor, has_backing_field, prop_name);
                }
            }
        }
    }

    fn walk_expr_for_phase_j(
        &mut self,
        e: &Expr,
        in_accessor: bool,
        has_backing_field: bool,
        prop_name: &str,
    ) {
        if let Expr::Path { segments, .. } = e {
            if segments.len() == 1 && segments[0].name == "field" {
                if !in_accessor {
                    self.diagnostics.emit(
                        Diagnostic::error(
                            "`field` can only be referenced inside a property accessor body",
                            segments[0].span,
                        )
                        .with_code(codes::TYPE_BACKING_FIELD_OUTSIDE_ACCESSOR),
                    );
                } else if !has_backing_field {
                    let detail = if prop_name.is_empty() {
                        "property has no backing field".to_string()
                    } else {
                        format!("property `{prop_name}` has no backing field")
                    };
                    self.diagnostics.emit(
                        Diagnostic::error(
                            format!("`field` is not available here: {detail}"),
                            segments[0].span,
                        )
                        .with_code(codes::TYPE_BACKING_FIELD_OUTSIDE_ACCESSOR),
                    );
                }
            }
        }
        // Recurse through children that may contain `field` references.
        match e {
            Expr::Block(b) => self.walk_block_for_phase_j(b, in_accessor, has_backing_field, prop_name),
            Expr::If { cond, then_branch, else_branch, .. } => {
                self.walk_expr_for_phase_j(cond, in_accessor, has_backing_field, prop_name);
                self.walk_expr_for_phase_j(then_branch, in_accessor, has_backing_field, prop_name);
                if let Some(eb) = else_branch {
                    self.walk_expr_for_phase_j(eb, in_accessor, has_backing_field, prop_name);
                }
            }
            Expr::While { cond, body, .. } => {
                self.walk_expr_for_phase_j(cond, in_accessor, has_backing_field, prop_name);
                self.walk_expr_for_phase_j(body, in_accessor, has_backing_field, prop_name);
            }
            Expr::DoWhile { body, cond, .. } => {
                if let Some(b) = body {
                    self.walk_expr_for_phase_j(b, in_accessor, has_backing_field, prop_name);
                }
                self.walk_expr_for_phase_j(cond, in_accessor, has_backing_field, prop_name);
            }
            Expr::For { iter, body, .. } => {
                self.walk_expr_for_phase_j(iter, in_accessor, has_backing_field, prop_name);
                self.walk_expr_for_phase_j(body, in_accessor, has_backing_field, prop_name);
            }
            Expr::Binary { lhs, rhs, .. } => {
                self.walk_expr_for_phase_j(lhs, in_accessor, has_backing_field, prop_name);
                self.walk_expr_for_phase_j(rhs, in_accessor, has_backing_field, prop_name);
            }
            Expr::Unary { expr, .. } | Expr::Postfix { expr, .. } => {
                self.walk_expr_for_phase_j(expr, in_accessor, has_backing_field, prop_name);
            }
            Expr::Member { receiver, .. } => {
                self.walk_expr_for_phase_j(receiver, in_accessor, has_backing_field, prop_name);
            }
            Expr::Call { callee, args, .. } => {
                self.walk_expr_for_phase_j(callee, in_accessor, has_backing_field, prop_name);
                for a in args {
                    self.walk_expr_for_phase_j(a, in_accessor, has_backing_field, prop_name);
                }
            }
            Expr::Index { receiver, args, .. } => {
                self.walk_expr_for_phase_j(receiver, in_accessor, has_backing_field, prop_name);
                for a in args {
                    self.walk_expr_for_phase_j(a, in_accessor, has_backing_field, prop_name);
                }
            }
            Expr::Return { value, .. } => {
                if let Some(v) = value {
                    self.walk_expr_for_phase_j(v, in_accessor, has_backing_field, prop_name);
                }
            }
            Expr::Labeled { expr, .. } => {
                self.walk_expr_for_phase_j(expr, in_accessor, has_backing_field, prop_name);
            }
            Expr::Throw { value, .. } => {
                self.walk_expr_for_phase_j(value, in_accessor, has_backing_field, prop_name);
            }
            Expr::Try { body, catches, finally, .. } => {
                self.walk_block_for_phase_j(body, in_accessor, has_backing_field, prop_name);
                for c in catches {
                    self.walk_block_for_phase_j(&c.body, in_accessor, has_backing_field, prop_name);
                }
                if let Some(fb) = finally {
                    self.walk_block_for_phase_j(fb, in_accessor, has_backing_field, prop_name);
                }
            }
            Expr::Lambda { body, .. } => {
                // Lambdas inside accessor bodies still see `field`.
                self.walk_block_for_phase_j(body, in_accessor, has_backing_field, prop_name);
            }
            Expr::When { subject, branches, .. } => {
                if let Some(s) = subject {
                    self.walk_expr_for_phase_j(s, in_accessor, has_backing_field, prop_name);
                }
                for b in branches {
                    for p in &b.patterns {
                        match &p.kind {
                            WhenPatternKind::Value(e)
                            | WhenPatternKind::InRange(e)
                            | WhenPatternKind::NotInRange(e) => {
                                self.walk_expr_for_phase_j(e, in_accessor, has_backing_field, prop_name);
                            }
                            _ => {}
                        }
                    }
                    self.walk_expr_for_phase_j(&b.body, in_accessor, has_backing_field, prop_name);
                }
            }
            Expr::IsCheck { expr, .. } | Expr::As { expr, .. } => {
                self.walk_expr_for_phase_j(expr, in_accessor, has_backing_field, prop_name);
            }
            Expr::AnonFun { body, .. } => {
                if let Some(b) = body {
                    match b.as_ref() {
                        FunctionBody::Block(blk) => self.walk_block_for_phase_j(blk, in_accessor, has_backing_field, prop_name),
                        FunctionBody::Expr(ex) => self.walk_expr_for_phase_j(ex, in_accessor, has_backing_field, prop_name),
                    }
                }
            }
            Expr::Spread { expr, .. } => {
                self.walk_expr_for_phase_j(expr, in_accessor, has_backing_field, prop_name);
            }
            Expr::ObjectExpr { members, .. } => {
                for m in members {
                    self.check_phase_j_decl(m, false);
                }
            }
            _ => {}
        }
    }

    fn check_phase_g_decl(&mut self, d: &Decl, at_top_level: bool) {
        match d {
            Decl::TypeAlias(a) => {
                if !at_top_level {
                    self.diagnostics.emit(
                        Diagnostic::error(
                            format!(
                                "`typealias {}` is only allowed at top level",
                                a.name.name
                            ),
                            a.name.span,
                        )
                        .with_code(codes::TYPE_TYPEALIAS_NOT_TOPLEVEL),
                    );
                }
            }
            Decl::Class(c) => {
                for m in &c.members {
                    self.check_phase_g_decl(m, /*at_top_level=*/ false);
                }
            }
            Decl::Object(o) => {
                for m in &o.members {
                    self.check_phase_g_decl(m, /*at_top_level=*/ false);
                }
            }
            Decl::Function(f) => {
                if let Some(body) = &f.body {
                    match body {
                        FunctionBody::Block(b) => self.walk_block_for_phase_g(b),
                        FunctionBody::Expr(e) => self.walk_expr_for_phase_g(e),
                    }
                }
            }
            Decl::Property(_) => {}
        }
    }

    fn walk_block_for_phase_g(&mut self, b: &Block) {
        for s in &b.stmts {
            match s {
                Stmt::Decl(d) => self.check_phase_g_decl(d, /*at_top_level=*/ false),
                Stmt::Expr(e) => self.walk_expr_for_phase_g(e),
                Stmt::Assign { value, .. } => self.walk_expr_for_phase_g(value),
                Stmt::DestructuringDecl { init, .. } => self.walk_expr_for_phase_g(init),
            }
        }
    }

    fn walk_expr_for_phase_g(&mut self, e: &Expr) {
        match e {
            Expr::Block(b) => self.walk_block_for_phase_g(b),
            Expr::If { cond, then_branch, else_branch, .. } => {
                self.walk_expr_for_phase_g(cond);
                self.walk_expr_for_phase_g(then_branch);
                if let Some(eb) = else_branch {
                    self.walk_expr_for_phase_g(eb);
                }
            }
            Expr::While { cond, body, .. } => {
                self.walk_expr_for_phase_g(cond);
                self.walk_expr_for_phase_g(body);
            }
            Expr::DoWhile { body, cond, .. } => {
                if let Some(b) = body {
                    self.walk_expr_for_phase_g(b);
                }
                self.walk_expr_for_phase_g(cond);
            }
            Expr::For { iter, body, .. } => {
                self.walk_expr_for_phase_g(iter);
                self.walk_expr_for_phase_g(body);
            }
            Expr::Lambda { body, .. } => self.walk_block_for_phase_g(body),
            Expr::AnonFun { body, .. } => {
                if let Some(b) = body.as_deref() {
                    match b {
                        FunctionBody::Block(blk) => self.walk_block_for_phase_g(blk),
                        FunctionBody::Expr(ex) => self.walk_expr_for_phase_g(ex),
                    }
                }
            }
            Expr::ObjectExpr { members, .. } => {
                for m in members {
                    self.check_phase_g_decl(m, /*at_top_level=*/ false);
                }
            }
            Expr::When { subject, branches, .. } => {
                if let Some(s) = subject {
                    self.walk_expr_for_phase_g(s);
                }
                for br in branches {
                    self.walk_expr_for_phase_g(&br.body);
                }
            }
            Expr::Labeled { expr, .. } => self.walk_expr_for_phase_g(expr),
            Expr::Try { body, finally, .. } => {
                self.walk_block_for_phase_g(body);
                if let Some(f) = finally {
                    self.walk_block_for_phase_g(f);
                }
            }
            _ => {}
        }
    }

    /// Detect direct / transitive `typealias` cycles. Emits T0038 once per
    /// alias on a cycle.
    fn check_typealias_cycles(&mut self) {
        let names: Vec<String> = self.aliases.keys().cloned().collect();
        for n in names {
            let mut seen: HashSet<String> = HashSet::new();
            if self.alias_reaches_self(&n, &n, &mut seen) {
                let span = self.aliases[&n].name_span;
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!("recursive typealias `{}` expands to itself", n),
                        span,
                    )
                    .with_code(codes::TYPE_RECURSIVE_TYPEALIAS),
                );
            }
        }
    }

    fn alias_reaches_self(
        &self,
        start: &str,
        current: &str,
        seen: &mut HashSet<String>,
    ) -> bool {
        let Some(info) = self.aliases.get(current) else {
            return false;
        };
        if !seen.insert(current.to_string()) {
            return false;
        }
        // Walk every aliased name appearing anywhere in the target TypeRef.
        let mut targets: Vec<String> = Vec::new();
        collect_aliased_names(&info.target, &mut targets);
        for t in targets {
            if t == start {
                return true;
            }
            if self.alias_reaches_self(start, &t, seen) {
                return true;
            }
        }
        false
    }

    /// Spec §4.3.4 backing-field rule. A property has a backing field iff:
    ///   * no custom accessors (default get/set);
    ///   * any custom accessor body references `field`;
    ///   * mutable property with exactly one of get/set custom (the other
    ///     defaults and needs storage).
    /// Extension properties never have a backing field.
    fn property_has_backing_field(p: &Property) -> bool {
        if p.receiver_type.is_some() {
            return false;
        }
        let g = p.getter.as_ref();
        let s = p.setter.as_ref();
        match (g, s) {
            (None, None) => true,
            (Some(a), None) | (None, Some(a)) => {
                if p.mutable {
                    true
                } else {
                    accessor_uses_field(a)
                }
            }
            (Some(a), Some(b)) => accessor_uses_field(a) || accessor_uses_field(b),
        }
    }

    /// Spec §4.2.5: inline-param escape detection. Walk the body and at
    /// every bare-name use of an inline / crossinline parameter outside a
    /// `Call.callee` slot, emit T0055/T0056. Conservative: a Path read in
    /// a non-call context counts as an escape. Re-passing the parameter as
    /// a call argument also counts (we cannot tell whether the callee is
    /// itself inline).
    /// Spec §8.23: a non-private function that returns an anonymous
    /// object with multiple declared supertypes (and no explicit return
    /// type annotation) leaks an unnameable type out of its scope.
    /// Single-supertype anonymous objects are implicitly downcast to
    /// their supertype, so they are allowed.
    fn check_anonymous_object_escape(&mut self, f: &Function) {
        if matches!(f.visibility, Visibility::Private) {
            return;
        }
        if f.return_type.is_some() {
            return;
        }
        let Some(body) = &f.body else { return };
        let tail = match body {
            FunctionBody::Expr(e) => e,
            FunctionBody::Block(b) => {
                let Some(last) = b.stmts.last() else { return };
                match last {
                    klio_ast::Stmt::Expr(e) => e,
                    _ => return,
                }
            }
        };
        let Expr::ObjectExpr { supertypes, span, .. } = tail else { return };
        if supertypes.len() < 2 {
            return;
        }
        self.diagnostics.emit(
            Diagnostic::error(
                format!(
                    "anonymous object with multiple supertypes escapes from non-private function `{}` — declare an explicit return type",
                    f.name.name
                ),
                *span,
            )
            .with_code(codes::TYPE_ANONYMOUS_OBJECT_ESCAPES_PUBLIC),
        );
    }

    fn check_inline_param_escape(&mut self, f: &Function) {
        if !f.is_inline {
            return;
        }
        // Only function-typed parameters are inlined (or crossinline /
        // noinline). Plain values (`x: Int`) on an inline fun are not
        // affected by §4.2.5.
        let is_fn_typed = |p: &Param| p.ty.function.is_some();
        let inline_params: Vec<String> = f
            .params
            .iter()
            .filter(|p| !p.is_noinline && !p.is_crossinline && is_fn_typed(p))
            .map(|p| p.name.name.clone())
            .collect();
        let crossinline_params: Vec<String> = f
            .params
            .iter()
            .filter(|p| p.is_crossinline && is_fn_typed(p))
            .map(|p| p.name.name.clone())
            .collect();
        if inline_params.is_empty() && crossinline_params.is_empty() {
            return;
        }
        if let Some(body) = &f.body {
            match body {
                FunctionBody::Block(b) => {
                    self.walk_block_for_inline_escape(b, &inline_params, &crossinline_params)
                }
                FunctionBody::Expr(e) => {
                    self.walk_expr_for_inline_escape(e, &inline_params, &crossinline_params, true)
                }
            }
        }
    }

    fn walk_block_for_inline_escape(
        &mut self,
        b: &Block,
        inline_params: &[String],
        crossinline_params: &[String],
    ) {
        for s in &b.stmts {
            match s {
                Stmt::Expr(e) => self.walk_expr_for_inline_escape(e, inline_params, crossinline_params, false),
                Stmt::Assign { value, .. } => {
                    self.flag_inline_escape(value, inline_params, crossinline_params, "stored in a variable");
                    self.walk_expr_for_inline_escape(value, inline_params, crossinline_params, false);
                }
                Stmt::Decl(Decl::Property(p)) => {
                    if let Some(init) = &p.init {
                        self.flag_inline_escape(init, inline_params, crossinline_params, "stored in a variable");
                        self.walk_expr_for_inline_escape(init, inline_params, crossinline_params, false);
                    }
                }
                _ => {}
            }
        }
    }

    fn walk_expr_for_inline_escape(
        &mut self,
        e: &Expr,
        inline_params: &[String],
        crossinline_params: &[String],
        is_callee: bool,
    ) {
        match e {
            Expr::Path { segments, span } if segments.len() == 1 && !is_callee => {
                let n = &segments[0].name;
                if inline_params.iter().any(|p| p == n) {
                    self.diagnostics.emit(
                        Diagnostic::error(
                            format!(
                                "inline parameter `{n}` cannot escape the function body — only \
                                 direct invocation is allowed"
                            ),
                            *span,
                        )
                        .with_code(codes::TYPE_INLINE_PARAM_LEAK),
                    );
                }
            }
            Expr::Call { callee, args, .. } => {
                self.walk_expr_for_inline_escape(callee, inline_params, crossinline_params, true);
                for a in args {
                    // An argument position is an escape for a bare inline
                    // param reference (we cannot prove the callee is inline).
                    self.flag_inline_escape(a, inline_params, crossinline_params, "passed as an argument");
                    self.walk_expr_for_inline_escape(a, inline_params, crossinline_params, false);
                }
            }
            Expr::Return { value, .. } => {
                if let Some(v) = value {
                    self.flag_inline_escape(v, inline_params, crossinline_params, "returned from the function");
                    self.walk_expr_for_inline_escape(v, inline_params, crossinline_params, false);
                }
            }
            Expr::Block(b) => self.walk_block_for_inline_escape(b, inline_params, crossinline_params),
            Expr::If { cond, then_branch, else_branch, .. } => {
                self.walk_expr_for_inline_escape(cond, inline_params, crossinline_params, false);
                self.walk_expr_for_inline_escape(then_branch, inline_params, crossinline_params, false);
                if let Some(e) = else_branch {
                    self.walk_expr_for_inline_escape(e, inline_params, crossinline_params, false);
                }
            }
            Expr::Member { receiver, .. } => {
                self.walk_expr_for_inline_escape(receiver, inline_params, crossinline_params, false);
            }
            _ => {}
        }
    }

    fn flag_inline_escape(
        &mut self,
        e: &Expr,
        inline_params: &[String],
        crossinline_params: &[String],
        action: &str,
    ) {
        let Expr::Path { segments, span } = e else { return };
        if segments.len() != 1 {
            return;
        }
        let n = &segments[0].name;
        // crossinline: store / return are forbidden; argument-passing is
        // allowed when the action is exactly "passed as an argument" — but
        // we still flag store/return.
        if crossinline_params.iter().any(|p| p == n) && action != "passed as an argument" {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!("crossinline parameter `{n}` cannot be {action}"),
                    *span,
                )
                .with_code(codes::TYPE_CROSSINLINE_PARAM_LEAK),
            );
            return;
        }
        // inline (non-crossinline, non-noinline): any non-callee use is an
        // escape. Already flagged at the bare-Path case for non-call
        // contexts; only flag here when the bare reference is in an
        // argument list.
        if inline_params.iter().any(|p| p == n) && action == "passed as an argument" {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!(
                        "inline parameter `{n}` cannot be {action}"
                    ),
                    *span,
                )
                .with_code(codes::TYPE_INLINE_PARAM_LEAK),
            );
        }
    }

    fn check_inline_property(&mut self, p: &Property) {
        // Spec §4.3.4: an inline property has no backing field. That means
        // no initializer, no `lateinit`, no `by` delegate, and any custom
        // accessor must avoid the `field` identifier (already enforced by
        // T0046 outside an accessor with a backing field — here we reject
        // initializer / lateinit / delegate up front).
        let mut bad = false;
        if p.init.is_some() || p.is_lateinit || p.delegate.is_some() {
            bad = true;
        }
        // An inline property must declare at least one accessor (otherwise
        // it would need a backing field to store its value).
        if p.getter.is_none() && p.setter.is_none() {
            bad = true;
        }
        if bad {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!(
                        "`inline` property `{}` must not have a backing field; declare \
                         explicit accessors that do not reference `field`",
                        p.name.name
                    ),
                    p.name.span,
                )
                .with_code(codes::TYPE_INLINE_PROPERTY_HAS_BACKING_FIELD),
            );
        }
    }

    fn check_const_val(&mut self, p: &Property, scope: PhaseFScope) {
        if p.mutable {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!("`const` modifier is only allowed on `val`, not `var`: `{}`", p.name.name),
                    p.name.span,
                )
                .with_code(codes::TYPE_CONST_VAL_NOT_TOPLEVEL),
            );
        }
        if !matches!(scope, PhaseFScope::TopLevel | PhaseFScope::Object) {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!(
                        "`const val` is only allowed at top level or inside an `object`: `{}`",
                        p.name.name
                    ),
                    p.name.span,
                )
                .with_code(codes::TYPE_CONST_VAL_NOT_TOPLEVEL),
            );
        }
        if p.delegate.is_some() || p.getter.is_some() || p.setter.is_some() {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!(
                        "`const val` cannot have a delegate or custom accessor: `{}`",
                        p.name.name
                    ),
                    p.name.span,
                )
                .with_code(codes::TYPE_CONST_VAL_NON_CONST_INIT),
            );
        }
        if let Some(ty) = &p.ty {
            if !is_const_capable_type_name(&ty.name.name) || ty.nullable {
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!(
                            "`const val` must have a primitive or `String` type: `{}`",
                            p.name.name
                        ),
                        ty.span,
                    )
                    .with_code(codes::TYPE_CONST_VAL_NON_CONST_INIT),
                );
            }
        }
        match &p.init {
            None => {
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!("`const val` requires an initializer: `{}`", p.name.name),
                        p.name.span,
                    )
                    .with_code(codes::TYPE_CONST_VAL_NON_CONST_INIT),
                );
            }
            Some(init) => {
                if !self.is_const_initializer(init) {
                    self.diagnostics.emit(
                        Diagnostic::error(
                            format!(
                                "`const val` initializer must be a compile-time constant: `{}`",
                                p.name.name
                            ),
                            init.span(),
                        )
                        .with_code(codes::TYPE_CONST_VAL_NON_CONST_INIT),
                    );
                }
            }
        }
    }

    /// Structural check: is this expression composed solely of literals,
    /// references to other `const val` declarations, arithmetic /
    /// comparison / string-concat operators over const-capable types, and
    /// string templates whose interpolated parts are also const?
    fn is_const_initializer(&self, e: &Expr) -> bool {
        match e {
            Expr::IntLit { .. }
            | Expr::FloatLit { .. }
            | Expr::BoolLit { .. }
            | Expr::CharLit { .. } => true,
            Expr::NullLit { .. } => false,
            Expr::StringTemplate { parts, .. } => parts.iter().all(|p| match p {
                StringPart::Text(_) => true,
                StringPart::ShortInterp(id) => self.is_const_ref(&id.name),
                StringPart::Interp(inner) => self.is_const_initializer(inner),
            }),
            Expr::Path { segments, .. } => {
                if segments.len() == 1 {
                    self.is_const_ref(&segments[0].name)
                } else {
                    // Permit qualified references when the leaf is a const
                    // val on a known class (best-effort: trailing segment).
                    self.is_const_ref(&segments.last().unwrap().name)
                }
            }
            Expr::Member { receiver, name, safe, .. } => {
                !*safe && self.is_const_initializer(receiver) && self.is_const_ref(&name.name)
            }
            Expr::Unary { op, expr, .. } => {
                matches!(op, UnOp::Neg | UnOp::Pos | UnOp::Not)
                    && self.is_const_initializer(expr)
            }
            Expr::Binary { op, lhs, rhs, .. } => {
                matches!(
                    op,
                    BinOp::Add
                        | BinOp::Sub
                        | BinOp::Mul
                        | BinOp::Div
                        | BinOp::Rem
                        | BinOp::Eq
                        | BinOp::Neq
                        | BinOp::Lt
                        | BinOp::Le
                        | BinOp::Gt
                        | BinOp::Ge
                        | BinOp::And
                        | BinOp::Or
                ) && self.is_const_initializer(lhs)
                    && self.is_const_initializer(rhs)
            }
            _ => false,
        }
    }

    fn is_const_ref(&self, name: &str) -> bool {
        if let Some(b) = self.frames[0].bindings.get(name) {
            if !b.mutable {
                return matches!(
                    b.ty,
                    Type::Int
                        | Type::Long
                        | Type::Short
                        | Type::Byte
                        | Type::Float
                        | Type::Double
                        | Type::Boolean
                        | Type::Char
                        | Type::String
                );
            }
        }
        false
    }

    fn check_value_class(&mut self, c: &Class) {
        let span = c.name.span;
        let emit = |this: &mut Self, msg: String| {
            this.diagnostics.emit(
                Diagnostic::error(msg, span).with_code(codes::TYPE_VALUE_CLASS_SHAPE),
            );
        };
        if c.is_open {
            emit(self, format!("`value class {}` must be final (cannot be `open`)", c.name.name));
        }
        if c.is_abstract {
            emit(self, format!("`value class {}` cannot be `abstract`", c.name.name));
        }
        if c.is_sealed {
            emit(self, format!("`value class {}` cannot be `sealed`", c.name.name));
        }
        if c.is_inner {
            emit(self, format!("`value class {}` cannot be `inner`", c.name.name));
        }
        if c.is_data {
            emit(self, format!("`value class {}` cannot be `data`", c.name.name));
        }
        if c.is_enum {
            emit(self, format!("`value class {}` cannot be `enum`", c.name.name));
        }
        if c.is_annotation {
            emit(self, format!("`value class {}` cannot be `annotation`", c.name.name));
        }
        if !c.init_blocks.is_empty() {
            emit(self, format!("`value class {}` cannot have `init` blocks", c.name.name));
        }
        for sc in &c.secondary_ctors {
            if sc.body.as_ref().map_or(false, |b| !b.stmts.is_empty()) {
                emit(
                    self,
                    format!(
                        "`value class {}` secondary constructors must have empty bodies",
                        c.name.name
                    ),
                );
                break;
            }
        }
        let val_count = c.primary_params.iter().filter(|p| p.property == Some(false)).count();
        let var_count = c.primary_params.iter().filter(|p| p.property == Some(true)).count();
        if var_count > 0 {
            emit(
                self,
                format!(
                    "`value class {}` cannot declare a `var` primary-constructor property",
                    c.name.name
                ),
            );
        }
        if val_count != 1 {
            emit(
                self,
                format!(
                    "`value class {}` must declare exactly one `val` primary-constructor property",
                    c.name.name
                ),
            );
        }
        for m in &c.members {
            match m {
                Decl::Property(p) => {
                    // Body properties with a backing field are forbidden: an
                    // initializer or `lateinit` implies a backing field. A
                    // body property with only a `get()` accessor is allowed.
                    let has_backing_field = p.init.is_some() || p.is_lateinit || p.delegate.is_some();
                    if has_backing_field {
                        emit(
                            self,
                            format!(
                                "`value class {}` cannot declare body properties with backing fields",
                                c.name.name
                            ),
                        );
                    }
                }
                Decl::Function(f) => {
                    if f.is_override && (f.name.name == "equals" || f.name.name == "hashCode") {
                        emit(
                            self,
                            format!(
                                "`value class {}` cannot override `{}`",
                                c.name.name, f.name.name
                            ),
                        );
                    }
                }
                _ => {}
            }
        }
        for s in &c.supertypes {
            if let Some(info) = self.classes.get(&s.name.name) {
                if !info.is_interface {
                    emit(
                        self,
                        format!(
                            "`value class {}` cannot extend non-interface supertype `{}`",
                            c.name.name, s.name.name
                        ),
                    );
                }
            }
        }
    }

    fn check_annotation_class(&mut self, c: &Class) {
        let span = c.name.span;
        let emit = |this: &mut Self, msg: String| {
            this.diagnostics.emit(
                Diagnostic::error(msg, span).with_code(codes::TYPE_ANNOTATION_CLASS_SHAPE),
            );
        };
        if c.is_open {
            emit(self, format!("`annotation class {}` cannot be `open`", c.name.name));
        }
        if c.is_abstract {
            emit(self, format!("`annotation class {}` cannot be `abstract`", c.name.name));
        }
        if c.is_sealed {
            emit(self, format!("`annotation class {}` cannot be `sealed`", c.name.name));
        }
        if c.is_data {
            emit(self, format!("`annotation class {}` cannot be `data`", c.name.name));
        }
        if c.is_enum {
            emit(self, format!("`annotation class {}` cannot be `enum`", c.name.name));
        }
        if c.is_inner {
            emit(self, format!("`annotation class {}` cannot be `inner`", c.name.name));
        }
        if c.is_value {
            emit(self, format!("`annotation class {}` cannot be `value`", c.name.name));
        }
        if !c.secondary_ctors.is_empty() {
            emit(
                self,
                format!(
                    "`annotation class {}` cannot have secondary constructors",
                    c.name.name
                ),
            );
        }
        if !c.init_blocks.is_empty() {
            emit(
                self,
                format!(
                    "`annotation class {}` cannot have `init` blocks",
                    c.name.name
                ),
            );
        }
        if !c.members.is_empty() {
            // A bare companion object inside an annotation class is permitted
            // by kotlinc; everything else (functions, body properties, nested
            // classes) is rejected.
            for m in &c.members {
                let allowed = matches!(m, Decl::Class(inner) if inner.is_companion);
                if !allowed {
                    emit(
                        self,
                        format!(
                            "`annotation class {}` cannot have body declarations",
                            c.name.name
                        ),
                    );
                    break;
                }
            }
        }
        if !c.supertypes.is_empty() {
            emit(
                self,
                format!(
                    "`annotation class {}` cannot declare a supertype",
                    c.name.name
                ),
            );
        }
        for p in &c.primary_params {
            if !is_annotation_param_type(&p.ty.name.name) || p.ty.nullable {
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!(
                            "annotation-class parameter `{}` has unsupported type `{}`",
                            p.name.name, p.ty.name.name
                        ),
                        p.ty.span,
                    )
                    .with_code(codes::TYPE_ANNOTATION_PARAM_TYPE),
                );
            } else if p.ty.name.name == "Array" {
                // Spec §4.1.4: Array element type is restricted to the same
                // allowed-type set (primitives / String / KClass / annotation /
                // enum). Look into the first type-argument; reject anything
                // that isn't a recognised allowed name. `out T` projections
                // are unwrapped via `TypeArg.ty`.
                if let Some(arg) = p.ty.type_args.first() {
                    let inner = &arg.ty.name.name;
                    if !is_annotation_param_type(inner) || arg.ty.nullable {
                        self.diagnostics.emit(
                            Diagnostic::error(
                                format!(
                                    "annotation-class parameter `{}` has `Array` of unsupported \
                                     element type `{}`",
                                    p.name.name, inner
                                ),
                                arg.ty.span,
                            )
                            .with_code(codes::TYPE_ANNOTATION_PARAM_TYPE),
                        );
                    }
                }
            }
        }
    }

    fn check_definitely_non_null_decl(
        &mut self,
        d: &Decl,
        tp_scope: &mut Vec<HashSet<String>>,
    ) {
        match d {
            Decl::Function(f) => {
                let mut frame = HashSet::new();
                for tp in &f.type_params {
                    frame.insert(tp.name.name.clone());
                }
                tp_scope.push(frame);
                if let Some(r) = &f.receiver_type {
                    self.check_dnn_typeref(r, tp_scope);
                }
                for p in &f.params {
                    self.check_dnn_typeref(&p.ty, tp_scope);
                }
                if let Some(rt) = &f.return_type {
                    self.check_dnn_typeref(rt, tp_scope);
                }
                if let Some(body) = &f.body {
                    match body {
                        FunctionBody::Block(b) => self.walk_block_for_dnn(b, tp_scope),
                        FunctionBody::Expr(e) => self.walk_expr_for_dnn(e, tp_scope),
                    }
                }
                tp_scope.pop();
            }
            Decl::Class(c) => {
                let mut frame = HashSet::new();
                for tp in &c.type_params {
                    frame.insert(tp.name.name.clone());
                }
                tp_scope.push(frame);
                for cp in &c.primary_params {
                    self.check_dnn_typeref(&cp.ty, tp_scope);
                }
                for m in &c.members {
                    self.check_definitely_non_null_decl(m, tp_scope);
                }
                tp_scope.pop();
            }
            Decl::Property(p) => {
                if let Some(t) = &p.ty {
                    self.check_dnn_typeref(t, tp_scope);
                }
                if let Some(init) = &p.init {
                    self.walk_expr_for_dnn(init, tp_scope);
                }
            }
            Decl::Object(o) => {
                for m in &o.members {
                    self.check_definitely_non_null_decl(m, tp_scope);
                }
            }
            Decl::TypeAlias(a) => {
                let mut frame = HashSet::new();
                for tp in &a.type_params {
                    frame.insert(tp.name.name.clone());
                }
                tp_scope.push(frame);
                self.check_dnn_typeref(&a.target, tp_scope);
                tp_scope.pop();
            }
        }
    }

    fn check_dnn_typeref(&mut self, t: &TypeRef, tp_scope: &[HashSet<String>]) {
        if t.definitely_non_null {
            let is_tp = tp_scope.iter().any(|s| s.contains(&t.name.name));
            if !is_tp {
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!(
                            "definitely non-nullable type `{} & Any` is only allowed when `{}` is a type parameter",
                            t.name.name, t.name.name
                        ),
                        t.span,
                    )
                    .with_code(codes::TYPE_DEFINITELY_NON_NULL_NOT_TYPE_PARAM),
                );
            }
        }
        for ta in &t.type_args {
            self.check_dnn_typeref(&ta.ty, tp_scope);
        }
        if let Some(f) = &t.function {
            if let Some(r) = &f.receiver {
                self.check_dnn_typeref(r, tp_scope);
            }
            for p in &f.params {
                self.check_dnn_typeref(p, tp_scope);
            }
            self.check_dnn_typeref(&f.ret, tp_scope);
        }
    }

    fn walk_block_for_dnn(&mut self, b: &Block, tp_scope: &mut Vec<HashSet<String>>) {
        for s in &b.stmts {
            match s {
                Stmt::Decl(d) => self.check_definitely_non_null_decl(d, tp_scope),
                Stmt::Expr(e) => self.walk_expr_for_dnn(e, tp_scope),
                Stmt::Assign { value, .. } => self.walk_expr_for_dnn(value, tp_scope),
                Stmt::DestructuringDecl { init, .. } => self.walk_expr_for_dnn(init, tp_scope),
            }
        }
    }

    fn walk_expr_for_dnn(&mut self, e: &Expr, tp_scope: &mut Vec<HashSet<String>>) {
        match e {
            Expr::Block(b) => self.walk_block_for_dnn(b, tp_scope),
            Expr::If { cond, then_branch, else_branch, .. } => {
                self.walk_expr_for_dnn(cond, tp_scope);
                self.walk_expr_for_dnn(then_branch, tp_scope);
                if let Some(eb) = else_branch {
                    self.walk_expr_for_dnn(eb, tp_scope);
                }
            }
            Expr::While { cond, body, .. } => {
                self.walk_expr_for_dnn(cond, tp_scope);
                self.walk_expr_for_dnn(body, tp_scope);
            }
            Expr::DoWhile { body, cond, .. } => {
                if let Some(b) = body {
                    self.walk_expr_for_dnn(b, tp_scope);
                }
                self.walk_expr_for_dnn(cond, tp_scope);
            }
            Expr::For { iter, body, .. } => {
                self.walk_expr_for_dnn(iter, tp_scope);
                self.walk_expr_for_dnn(body, tp_scope);
            }
            Expr::Lambda { body, .. } => self.walk_block_for_dnn(body, tp_scope),
            Expr::IsCheck { ty, .. } => self.check_dnn_typeref(ty, tp_scope),
            Expr::When { subject, subject_binding, branches, .. } => {
                if let Some(s) = subject {
                    self.walk_expr_for_dnn(s, tp_scope);
                }
                if let Some(b) = subject_binding {
                    if let Some(t) = &b.ty {
                        self.check_dnn_typeref(t, tp_scope);
                    }
                }
                for br in branches {
                    for p in &br.patterns {
                        match &p.kind {
                            WhenPatternKind::IsType(t) | WhenPatternKind::NotIsType(t) => {
                                self.check_dnn_typeref(t, tp_scope);
                            }
                            WhenPatternKind::Value(e)
                            | WhenPatternKind::InRange(e)
                            | WhenPatternKind::NotInRange(e) => {
                                self.walk_expr_for_dnn(e, tp_scope);
                            }
                            WhenPatternKind::Else => {}
                        }
                    }
                    self.walk_expr_for_dnn(&br.body, tp_scope);
                }
            }
            Expr::ObjectExpr { members, .. } => {
                for m in members {
                    self.check_definitely_non_null_decl(m, tp_scope);
                }
            }
            _ => {}
        }
    }

    // ---- M28: generics & inline diagnostics --------------------------------

    fn check_m28_decl(&mut self, d: &Decl) {
        match d {
            Decl::Function(f) => self.check_m28_function(f),
            Decl::Class(c) => self.check_m28_class(c),
            Decl::Property(_) | Decl::Object(_) | Decl::TypeAlias(_) => {}
        }
    }

    fn check_m28_function(&mut self, f: &Function) {
        // T0023 — reified outside inline
        for tp in &f.type_params {
            if tp.is_reified && !f.is_inline {
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!(
                            "type parameter `{}` is `reified` but enclosing function is not `inline`",
                            tp.name.name
                        ),
                        tp.span,
                    )
                    .with_code(codes::TYPE_REIFIED_REQUIRES_INLINE),
                );
            }
        }
        // T0026 — crossinline/noinline outside inline
        for p in &f.params {
            if (p.is_crossinline || p.is_noinline) && !f.is_inline {
                let which = if p.is_crossinline { "crossinline" } else { "noinline" };
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!(
                            "`{}` parameter `{}` is only allowed on an `inline` function",
                            which, p.name.name
                        ),
                        p.name.span,
                    )
                    .with_code(codes::TYPE_INLINE_MODIFIER_OUTSIDE_INLINE),
                );
            }
        }
        // T0025 — vararg misuse
        let vararg_idxs: Vec<usize> = f
            .params
            .iter()
            .enumerate()
            .filter(|(_, p)| p.is_vararg)
            .map(|(i, _)| i)
            .collect();
        if vararg_idxs.len() > 1 {
            for &i in vararg_idxs.iter().skip(1) {
                self.diagnostics.emit(
                    Diagnostic::error(
                        "a function may declare at most one `vararg` parameter",
                        f.params[i].name.span,
                    )
                    .with_code(codes::TYPE_VARARG_MISUSE),
                );
            }
        }
        if let Some(&i) = vararg_idxs.first() {
            // Following params are allowed only if they have defaults.
            for (j, p) in f.params.iter().enumerate().skip(i + 1) {
                if p.default.is_none() {
                    self.diagnostics.emit(
                        Diagnostic::error(
                            format!(
                                "parameter `{}` follows a `vararg` and must have a default value",
                                p.name.name
                            ),
                            p.name.span,
                        )
                        .with_code(codes::TYPE_VARARG_MISUSE),
                    );
                }
                let _ = j;
            }
        }
        // Recurse into nested functions/classes inside the body.
        if let Some(body) = &f.body {
            match body {
                FunctionBody::Block(b) => self.walk_block_for_m28(b),
                FunctionBody::Expr(e) => self.walk_expr_for_m28(e),
            }
        }
    }

    fn check_m28_class(&mut self, c: &Class) {
        // T0024 — declaration-site variance positions on member functions.
        for tp in &c.type_params {
            if matches!(tp.variance, klio_ast::Variance::Invariant) {
                continue;
            }
            for m in &c.members {
                if let Decl::Function(f) = m {
                    // J5: `private` member is only accessible via `this`, so
                    // its parameter / return positions are not observable
                    // through the public API. Variance rules don't apply.
                    if matches!(f.visibility, Visibility::Private) {
                        continue;
                    }
                    self.check_member_variance_positions(&tp.name.name, tp.variance, f);
                }
            }
        }
        for m in &c.members {
            self.check_m28_decl(m);
        }
    }

    fn check_member_variance_positions(
        &mut self,
        param: &str,
        variance: klio_ast::Variance,
        f: &Function,
    ) {
        // For `out T`: T must not appear in input positions.
        // For `in T`: T must not appear in output positions.
        match variance {
            klio_ast::Variance::Out => {
                for p in &f.params {
                    if type_ref_uses(&p.ty, param) {
                        self.diagnostics.emit(
                            Diagnostic::error(
                                format!(
                                    "type parameter `{param}` is `out` but appears in an input position of `{}`",
                                    f.name.name
                                ),
                                p.ty.span,
                            )
                            .with_code(codes::TYPE_DECLARATION_VARIANCE_VIOLATION),
                        );
                    }
                }
            }
            klio_ast::Variance::In => {
                if let Some(rt) = &f.return_type {
                    if type_ref_uses(rt, param) {
                        self.diagnostics.emit(
                            Diagnostic::error(
                                format!(
                                    "type parameter `{param}` is `in` but appears in an output position of `{}`",
                                    f.name.name
                                ),
                                rt.span,
                            )
                            .with_code(codes::TYPE_DECLARATION_VARIANCE_VIOLATION),
                        );
                    }
                }
            }
            klio_ast::Variance::Invariant => {}
        }
    }

    fn walk_block_for_m28(&mut self, b: &Block) {
        for s in &b.stmts {
            match s {
                Stmt::Decl(d) => self.check_m28_decl(d),
                Stmt::Expr(e) => self.walk_expr_for_m28(e),
                Stmt::Assign { value, .. } => self.walk_expr_for_m28(value),
                Stmt::DestructuringDecl { init, .. } => self.walk_expr_for_m28(init),
            }
        }
    }

    fn walk_expr_for_m28(&mut self, e: &Expr) {
        match e {
            Expr::Block(b) => self.walk_block_for_m28(b),
            Expr::If { cond, then_branch, else_branch, .. } => {
                self.walk_expr_for_m28(cond);
                self.walk_expr_for_m28(then_branch);
                if let Some(eb) = else_branch {
                    self.walk_expr_for_m28(eb);
                }
            }
            Expr::While { cond, body, .. } => {
                self.walk_expr_for_m28(cond);
                self.walk_expr_for_m28(body);
            }
            Expr::DoWhile { body, cond, .. } => {
                if let Some(b) = body {
                    self.walk_expr_for_m28(b);
                }
                self.walk_expr_for_m28(cond);
            }
            Expr::For { iter, body, .. } => {
                self.walk_expr_for_m28(iter);
                self.walk_expr_for_m28(body);
            }
            Expr::Lambda { body, .. } => self.walk_block_for_m28(body),
            Expr::ObjectExpr { members, .. } => {
                for m in members {
                    self.check_m28_decl(m);
                }
            }
            _ => {}
        }
    }
}

fn type_ref_uses(t: &TypeRef, name: &str) -> bool {
    // `@UnsafeVariance` annotation on the TypeRef itself suppresses the
    // declaration-site variance position check at this occurrence.
    if has_unsafe_variance(&t.annotations) {
        return false;
    }
    if t.name.name == name && t.type_args.is_empty() && t.function.is_none() {
        return true;
    }
    for a in &t.type_args {
        if !a.is_star && type_ref_uses(&a.ty, name) {
            return true;
        }
    }
    if let Some(f) = &t.function {
        if let Some(r) = &f.receiver {
            if type_ref_uses(r, name) {
                return true;
            }
        }
        for p in &f.params {
            if type_ref_uses(p, name) {
                return true;
            }
        }
        if type_ref_uses(&f.ret, name) {
            return true;
        }
    }
    false
}

fn has_unsafe_variance(anns: &[klio_ast::Annotation]) -> bool {
    anns.iter().any(|a| {
        a.path
            .last()
            .map(|seg| seg.name == "UnsafeVariance")
            .unwrap_or(false)
    })
}

fn has_published_api(anns: &[klio_ast::Annotation]) -> bool {
    anns.iter().any(|a| {
        a.path
            .last()
            .map(|seg| seg.name == "PublishedApi")
            .unwrap_or(false)
    })
}

impl<'r> Checker<'r> {

    // ---- top-level declaration intake -----------------------------------

    fn declare_top_level(&mut self, decl: &Decl) {
        match decl {
            Decl::Function(f) => {
                let sig = self.signature_of(f);
                if let Some(recv) = &f.receiver_type {
                    let return_class = f.return_type.as_ref().and_then(class_name_from_typeref);
                    self.extensions
                        .entry(recv.name.name.clone())
                        .or_default()
                        .push(ExtensionSig {
                            name: f.name.name.clone(),
                            sig,
                            return_class,
                        });
                } else {
                    self.fns.entry(f.name.name.clone()).or_default().push(sig);
                    self.fn_visibility
                        .entry(f.name.name.clone())
                        .or_default()
                        .push((f.visibility, f.name.span.file));
                    self.fn_annotations
                        .entry(f.name.name.clone())
                        .or_default()
                        .push(f.annotations.clone());
                }
            }
            Decl::Property(p) => {
                let ty = p
                    .ty
                    .as_ref()
                    .map(convert_type_ref_lossy)
                    .unwrap_or(Type::Unresolved);
                let cn = p.ty.as_ref().and_then(class_name_from_typeref);
                if let Some(recv) = &p.receiver_type {
                    self.extension_properties
                        .entry(recv.name.name.clone())
                        .or_default()
                        .push(ExtensionPropSig {
                            name: p.name.name.clone(),
                            ty,
                            mutable: p.mutable,
                            return_class: cn,
                        });
                } else {
                    self.assigned.insert(p.name.name.clone());
                    self.frames[0].bindings.insert(
                        p.name.name.clone(),
                        Binding { ty, mutable: p.mutable, decl_span: Some(p.name.span), class_name: cn, needs_init: false },
                    );
                    self.prop_visibility
                        .insert(p.name.name.clone(), (p.visibility, p.name.span.file));
                    if let Some(sv) = p.setter_visibility {
                        self.setter_visibility
                            .insert(p.name.name.clone(), (sv, p.name.span.file));
                    } else if let Some(setter) = &p.setter {
                        if let Some(sv) = setter.visibility {
                            self.setter_visibility
                                .insert(p.name.name.clone(), (sv, p.name.span.file));
                        }
                    }
                    self.prop_annotations
                        .insert(p.name.name.clone(), p.annotations.clone());
                }
            }
            Decl::Class(c) => {
                let info = self.class_info(c);
                self.classes.insert(c.name.name.clone(), info);
            }
            Decl::Object(o) => {
                // Treat object singleton like a class with no ctor.
                let mut info = ClassInfo::default();
                info.is_object = true;
                info.decl_file = Some(o.name.span.file);
                self.collect_members(&o.members, &mut info);
                for s in &o.supertypes {
                    info.supertypes.push(s.name.name.clone());
                }
                self.classes.insert(o.name.name.clone(), info);
                self.assigned.insert(o.name.name.clone());
                // Bind the singleton name itself so `Foo.bar` reads pass.
                self.frames[0].bindings.insert(
                    o.name.name.clone(),
                    Binding {
                        ty: Type::Unresolved,
                        mutable: false,
                        decl_span: Some(o.name.span),
                        class_name: Some(o.name.name.clone()), needs_init: false },
                );
            }
            Decl::TypeAlias(a) => {
                self.aliases.insert(
                    a.name.name.clone(),
                    TypeAliasInfo {
                        type_params: a.type_params.iter().map(|p| p.name.name.clone()).collect(),
                        target: a.target.clone(),
                        name_span: a.name.span,
                    },
                );
            }
        }
    }

    fn signature_of(&self, f: &Function) -> FnSig {
        let mut params = Vec::with_capacity(f.params.len());
        let mut has_default = Vec::with_capacity(f.params.len());
        let mut names = Vec::with_capacity(f.params.len());
        let mut is_vararg = Vec::with_capacity(f.params.len());
        for p in &f.params {
            params.push(convert_type_ref_lossy(&p.ty));
            has_default.push(p.default.is_some());
            names.push(p.name.name.clone());
            is_vararg.push(p.is_vararg);
        }
        let return_ty = f
            .return_type
            .as_ref()
            .map(convert_type_ref_lossy)
            .unwrap_or(Type::Unit);
        FnSig { params, has_default, param_names: names, is_vararg, return_ty, is_infix: f.is_infix }
    }

    fn class_info(&self, c: &Class) -> ClassInfo {
        let mut info = ClassInfo {
            is_abstract: c.is_abstract,
            is_interface: c.is_interface,
            is_sealed: c.is_sealed,
            is_open: c.is_open || c.is_abstract || c.is_sealed,
            has_secondary_ctors: !c.secondary_ctors.is_empty(),
            decl_visibility: c.visibility,
            decl_file: Some(c.name.span.file),
            primary_ctor_visibility: c.primary_ctor_visibility,
            ..ClassInfo::default()
        };
        // Primary ctor params that are properties become members.
        for p in &c.primary_params {
            let ty = convert_type_ref_lossy(&p.ty);
            if let Some(mutable) = p.property {
                info.members.insert(p.name.name.clone(), ty.clone());
                info.member_mutable.insert(p.name.name.clone(), mutable);
                info.concrete_members.push(p.name.name.clone());
                if let Some(cn) = class_name_from_typeref(&p.ty) {
                    info.member_class.insert(p.name.name.clone(), cn);
                }
                info.member_visibility.insert(p.name.name.clone(), p.visibility);
                info.member_sigs.insert(
                    p.name.name.clone(),
                    MemberSig::Property { ty: ty.clone(), mutable, visibility: p.visibility },
                );
            }
        }
        let ctor_sig = FnSig {
            params: c
                .primary_params
                .iter()
                .map(|p| convert_type_ref_lossy(&p.ty))
                .collect(),
            has_default: c.primary_params.iter().map(|p| p.default.is_some()).collect(),
            param_names: c.primary_params.iter().map(|p| p.name.name.clone()).collect(),
            is_vararg: c.primary_params.iter().map(|_| false).collect(),
            return_ty: Type::Unresolved,
            is_infix: false,
        };
        if !c.primary_params.is_empty() || !c.is_interface {
            info.ctor = Some(ctor_sig);
        }
        self.collect_members(&c.members, &mut info);
        for s in &c.supertypes {
            info.supertypes.push(s.name.name.clone());
        }
        info
    }

    fn collect_members(&self, members: &[Decl], info: &mut ClassInfo) {
        for m in members {
            match m {
                Decl::Function(f) => {
                    let sig = self.signature_of(f);
                    info.member_sigs.insert(
                        f.name.name.clone(),
                        MemberSig::Function {
                            param_types: sig.params.clone(),
                            return_ty: sig.return_ty.clone(),
                            visibility: f.visibility,
                        },
                    );
                    let ty = Type::Function {
                        params: sig.params,
                        return_type: Box::new(sig.return_ty),
                    };
                    info.members.insert(f.name.name.clone(), ty);
                    if let Some(cn) = f.return_type.as_ref().and_then(class_name_from_typeref) {
                        info.member_class.insert(f.name.name.clone(), cn);
                    }
                    // Interface members and abstract members are implicitly
                    // `open` in Kotlin — record that here so subclass override
                    // diagnostics line up with kotlinc behavior.
                    let implicit_open =
                        info.is_interface || info.is_abstract || f.is_abstract;
                    info.member_flags.insert(
                        f.name.name.clone(),
                        MemberFlags {
                            is_open: f.is_open || implicit_open,
                            is_override: f.is_override,
                            is_abstract: f.is_abstract,
                            is_operator: f.is_operator,
                            is_infix: f.is_infix,
                            has_default_body: f.body.is_some() && !f.is_abstract,
                        },
                    );
                    if f.is_abstract {
                        info.abstract_members.push(f.name.name.clone());
                    } else {
                        info.concrete_members.push(f.name.name.clone());
                    }
                    info.member_visibility.insert(f.name.name.clone(), f.visibility);
                }
                Decl::Property(p) => {
                    let ty = p
                        .ty
                        .as_ref()
                        .map(convert_type_ref_lossy)
                        .unwrap_or(Type::Unresolved);
                    info.member_sigs.insert(
                        p.name.name.clone(),
                        MemberSig::Property {
                            ty: ty.clone(),
                            mutable: p.mutable,
                            visibility: p.visibility,
                        },
                    );
                    info.members.insert(p.name.name.clone(), ty);
                    info.member_mutable.insert(p.name.name.clone(), p.mutable);
                    if let Some(cn) = p.ty.as_ref().and_then(class_name_from_typeref) {
                        info.member_class.insert(p.name.name.clone(), cn);
                    }
                    let implicit_open =
                        info.is_interface || info.is_abstract || p.is_abstract || p.is_override;
                    info.member_flags.insert(
                        p.name.name.clone(),
                        MemberFlags {
                            is_open: p.is_open || implicit_open,
                            is_override: p.is_override,
                            is_abstract: p.is_abstract,
                            is_operator: false,
                            is_infix: false,
                            has_default_body: false,
                        },
                    );
                    if p.is_abstract {
                        info.abstract_members.push(p.name.name.clone());
                    } else {
                        info.concrete_members.push(p.name.name.clone());
                    }
                    info.member_visibility.insert(p.name.name.clone(), p.visibility);
                }
                Decl::Class(_) | Decl::Object(_) | Decl::TypeAlias(_) => {}
            }
        }
    }

    // ---- decl bodies -----------------------------------------------------

    fn check_decl(&mut self, decl: &Decl) {
        match decl {
            Decl::Function(f) => self.check_function(f),
            Decl::Property(p) => self.check_top_level_property(p),
            Decl::Class(c) => self.check_class(c),
            Decl::Object(o) => self.check_object(o),
            Decl::TypeAlias(_) => {}
        }
    }

    fn check_top_level_property(&mut self, p: &Property) {
        if let Some(init) = &p.init {
            let init_ty = self.check_expr(init, None);
            if let Some(annot) = p.ty.as_ref().map(convert_type_ref_lossy) {
                self.check_assignable(&init_ty, &annot, init.span());
            } else {
                // Infer from initializer.
                if let Some(b) = self.frames[0].bindings.get_mut(&p.name.name) {
                    if matches!(b.ty, Type::Unresolved) {
                        b.ty = init_ty;
                    }
                }
            }
        }
        if let Some(d) = &p.delegate {
            self.check_expr(d, None);
            self.check_delegate_operator(p, d);
        }
        self.check_lateinit(p);
        self.check_accessor_return_types(p);
    }

    fn check_function(&mut self, f: &Function) {
        self.check_inline_param_escape(f);
        self.check_anonymous_object_escape(f);
        let saved_assigned = self.assigned.clone();
        self.push_frame();
        for p in &f.params {
            let ty = convert_type_ref_lossy(&p.ty);
            let cn = class_name_from_typeref(&p.ty);
            self.current_frame()
                .bindings
                .insert(p.name.name.clone(), Binding { ty, mutable: false, decl_span: Some(p.name.span), class_name: cn, needs_init: false });
            self.assigned.insert(p.name.name.clone());
            if let Some(default) = &p.default {
                let dty = self.check_expr(default, Some(&convert_type_ref_lossy(&p.ty)));
                self.check_assignable(&dty, &convert_type_ref_lossy(&p.ty), default.span());
            }
        }
        let declared_return = f
            .return_type
            .as_ref()
            .map(convert_type_ref_lossy)
            .unwrap_or(Type::Unit);
        self.fn_return_stack.push(declared_return.clone());
        self.label_stack.push(f.name.name.clone());
        let is_public_inline = f.is_inline && matches!(f.visibility, Visibility::Public);
        self.public_inline_stack.push(is_public_inline);
        let reified = f
            .type_params
            .iter()
            .filter(|tp| tp.is_reified)
            .map(|tp| tp.name.name.clone())
            .collect::<std::collections::HashSet<_>>();
        self.reified_type_params.push(reified);
        let all_tps = f
            .type_params
            .iter()
            .map(|tp| tp.name.name.clone())
            .collect::<std::collections::HashSet<_>>();
        self.type_params_in_scope.push(all_tps);
        if let Some(body) = &f.body {
            match body {
                FunctionBody::Block(b) => {
                    self.check_block(b, Some(&declared_return));
                }
                FunctionBody::Expr(e) => {
                    let ety = self.check_expr(e, Some(&declared_return));
                    if f.return_type.is_some() && !matches!(declared_return, Type::Unit) {
                        self.check_assignable(&ety, &declared_return, e.span());
                    }
                }
            }
        }
        self.fn_return_stack.pop();
        self.label_stack.pop();
        self.public_inline_stack.pop();
        self.reified_type_params.pop();
        self.type_params_in_scope.pop();
        self.pop_frame();
        self.assigned = saved_assigned;
    }

    fn check_class(&mut self, c: &Class) {
        self.class_stack.push(c.name.name.clone());
        // Spec §5.1: data, enum, and annotation classes are always closed
        // and cannot be declared `open`, `abstract`, or `sealed`.
        // `value` / `annotation` shape checks fire their own diagnostics.
        if c.is_data || c.is_enum {
            let kind = if c.is_data { "data" } else { "enum" };
            for (is_set, mod_name) in [
                (c.is_open, "open"),
                (c.is_abstract, "abstract"),
                (c.is_sealed, "sealed"),
            ] {
                if is_set {
                    self.diagnostics.emit(
                        Diagnostic::error(
                            format!(
                                "`{kind} class {}` cannot be declared `{mod_name}`",
                                c.name.name
                            ),
                            c.name.span,
                        )
                        .with_code(codes::TYPE_DATA_OR_ENUM_CLASS_OPEN_OR_ABSTRACT),
                    );
                }
            }
        }
        // Spec §4.1.1: secondary constructor delegation must not form a
        // cycle. Match `this(args)` to a secondary constructor by argument
        // arity (a permissive over-approximation; primary-ctor delegation
        // terminates the chain since the primary cannot delegate further).
        if !c.secondary_ctors.is_empty() {
            let n = c.secondary_ctors.len();
            // Outgoing edges: for each ctor, indices of ctors it might
            // delegate to via `this(args)` of matching arity.
            let mut edges: Vec<Vec<usize>> = vec![Vec::new(); n];
            for (i, sc) in c.secondary_ctors.iter().enumerate() {
                if let CtorDelegation::This(args) = &sc.delegation {
                    let arity = args.len();
                    for (j, other) in c.secondary_ctors.iter().enumerate() {
                        if other.params.len() == arity {
                            edges[i].push(j);
                        }
                    }
                }
            }
            // DFS from each ctor; flag if it reaches itself through a
            // chain composed entirely of secondary-to-secondary edges.
            for start in 0..n {
                let mut stack = vec![start];
                let mut seen = vec![false; n];
                let mut hit_self = false;
                while let Some(cur) = stack.pop() {
                    for &nx in &edges[cur] {
                        if nx == start {
                            hit_self = true;
                            break;
                        }
                        if !seen[nx] {
                            seen[nx] = true;
                            stack.push(nx);
                        }
                    }
                    if hit_self {
                        break;
                    }
                }
                if hit_self {
                    self.diagnostics.emit(
                        Diagnostic::error(
                            format!(
                                "secondary constructor of `{}` participates in a delegation \
                                 cycle",
                                c.name.name
                            ),
                            c.secondary_ctors[start].span,
                        )
                        .with_code(codes::TYPE_CONSTRUCTOR_DELEGATION_CYCLE),
                    );
                }
            }
        }
        // Spec §4.1.2: `data class` shape — must have ≥1 property param,
        // and no vararg property param.
        if c.is_data {
            let n_props = c.primary_params.iter().filter(|p| p.property.is_some()).count();
            if n_props == 0 {
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!(
                            "data class `{}` must declare at least one primary-constructor \
                             property",
                            c.name.name
                        ),
                        c.name.span,
                    )
                    .with_code(codes::TYPE_DATA_CLASS_NO_PROPERTIES),
                );
            }
            for p in &c.primary_params {
                if p.is_vararg && p.property.is_some() {
                    self.diagnostics.emit(
                        Diagnostic::error(
                            format!(
                                "data class `{}` cannot declare a `vararg` property parameter",
                                c.name.name
                            ),
                            p.span,
                        )
                        .with_code(codes::TYPE_DATA_CLASS_VARARG_PROPERTY),
                    );
                }
            }
        }
        // Spec §4.1.2: `data class` cannot explicify `copy` or `componentN`.
        if c.is_data {
            let n_props = c.primary_params.iter().filter(|p| p.property.is_some()).count();
            for m in &c.members {
                if let Decl::Function(f) = m {
                    let n = f.name.name.as_str();
                    if n == "copy" {
                        self.diagnostics.emit(
                            Diagnostic::error(
                                format!(
                                    "`copy` is auto-generated for data class `{}` and cannot be \
                                     explicified",
                                    c.name.name
                                ),
                                f.name.span,
                            )
                            .with_code(codes::TYPE_DATA_CLASS_FORBIDS_COPY_OVERRIDE),
                        );
                    } else if let Some(rest) = n.strip_prefix("component") {
                        if let Ok(idx) = rest.parse::<usize>() {
                            if idx >= 1 && idx <= n_props && f.params.is_empty() {
                                self.diagnostics.emit(
                                    Diagnostic::error(
                                        format!(
                                            "`{}` is auto-generated for data class `{}` and cannot \
                                             be explicified",
                                            n, c.name.name
                                        ),
                                        f.name.span,
                                    )
                                    .with_code(
                                        codes::TYPE_DATA_CLASS_FORBIDS_COMPONENT_OVERRIDE,
                                    ),
                                );
                            }
                        }
                    }
                }
            }
        }
        // Spec §3.9: `kotlin.Enum<T>` declares `equals`, `hashCode`, and
        // `compareTo` as `final`. User-declared enum entries cannot override
        // them. `toString` remains overridable.
        if c.is_enum {
            for m in &c.members {
                if let Decl::Function(f) = m {
                    let n = f.name.name.as_str();
                    if (n == "equals" || n == "hashCode" || n == "compareTo") && f.is_override
                    {
                        self.diagnostics.emit(
                            Diagnostic::error(
                                format!(
                                    "`{}` is `final` on `kotlin.Enum` and cannot be overridden \
                                     (enum class `{}`)",
                                    n, c.name.name
                                ),
                                f.name.span,
                            )
                            .with_code(codes::TYPE_ENUM_FORBIDS_FINAL_OVERRIDE),
                        );
                    }
                }
            }
        }
        // Spec §3.12: subtypes of `kotlin.Throwable` cannot have type
        // parameters. Walk the transitive supertype chain looking for any
        // built-in or user-declared Throwable ancestor.
        if !c.type_params.is_empty() && self.is_throwable_subtype(c) {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!(
                        "Subclasses of `kotlin.Throwable` cannot declare type parameters; \
                         `{}` does",
                        c.name.name
                    ),
                    c.name.span,
                )
                .with_code(codes::TYPE_THROWABLE_TYPE_PARAMS),
            );
        }
        // Spec §5.4: `private` is mutually exclusive with `open`,
        // `abstract`, and `override` on a member declaration.
        for m in &c.members {
            match m {
                Decl::Function(f) => {
                    if matches!(f.visibility, Visibility::Private) {
                        self.check_private_open_or_override(
                            &f.name.name,
                            f.name.span,
                            f.is_open,
                            f.is_abstract,
                            f.is_override,
                        );
                    }
                }
                Decl::Property(p) => {
                    if matches!(p.visibility, Visibility::Private) {
                        self.check_private_open_or_override(
                            &p.name.name,
                            p.name.span,
                            false,
                            p.is_abstract,
                            p.is_override,
                        );
                    }
                }
                _ => {}
            }
        }
        // Spec §5.1: supertype validity. A class may inherit from at most
        // one class (open / abstract / sealed) plus any number of
        // interfaces. Inheriting from a closed (default-final) class or
        // from an `object` type is a compile-time error.
        self.check_supertype_validity(&c.name.name, &c.supertypes);
        // Soft override diagnostics — walk parents and interfaces, gather
        // their (name, MemberFlags) table, and compare against this class's
        // members. Diagnostics here are not fatal; they surface intent
        // mismatches between subclass and supertype declarations.
        let mut inherited = self.collect_inherited_member_flags(c);
        // Spec §5.1.3: function-type supertypes act like interfaces — they
        // contribute an abstract `invoke` slot. Inject it so the
        // override-walk accepts `override fun invoke(...)`.
        {
            let mut sigs_tmp: HashMap<String, MemberSig> = HashMap::new();
            self.inject_function_type_supertypes(c, &mut inherited, &mut sigs_tmp);
        }
        for m in &c.members {
            let (mname, mspan, mflags) = match m {
                Decl::Function(f) => (
                    &f.name.name,
                    f.name.span,
                    MemberFlags {
                        is_open: f.is_open,
                        is_override: f.is_override,
                        is_abstract: f.is_abstract,
                        is_operator: f.is_operator,
                        is_infix: f.is_infix,
                        has_default_body: f.body.is_some() && !f.is_abstract,
                    },
                ),
                Decl::Property(p) => (
                    &p.name.name,
                    p.name.span,
                    MemberFlags {
                        is_open: p.is_open || p.is_override || p.is_abstract,
                        is_override: p.is_override,
                        is_abstract: p.is_abstract,
                        is_operator: false,
                        is_infix: false,
                        has_default_body: false,
                    },
                ),
                _ => continue,
            };
            match inherited.get(mname).copied() {
                Some(parent_flags) => {
                    // Member exists in a parent.
                    if mflags.is_override {
                        // Parent must be open / abstract for the override
                        // to be legitimate.
                        if !(parent_flags.is_open || parent_flags.is_abstract) {
                            self.diagnostics.emit(
                                Diagnostic::error(
                                    format!(
                                        "`{mname}` overrides nothing — parent member is not `open`"
                                    ),
                                    mspan,
                                )
                                .with_code(codes::TYPE_OVERRIDE_BUT_PARENT_NOT_OPEN),
                            );
                        }
                    } else {
                        // No `override`, but a same-name parent member is
                        // open / abstract — Kotlin requires the modifier.
                        if parent_flags.is_open || parent_flags.is_abstract {
                            self.diagnostics.emit(
                                Diagnostic::error(
                                    format!(
                                        "`{mname}` hides a member from a supertype; add `override` modifier"
                                    ),
                                    mspan,
                                )
                                .with_code(codes::TYPE_OVERRIDE_NEEDED),
                            );
                        }
                    }
                }
                None => {
                    if mflags.is_override && !is_builtin_overridable(mname) {
                        self.diagnostics.emit(
                            Diagnostic::error(
                                format!(
                                    "`{mname}` is marked `override` but does not override any supertype member"
                                ),
                                mspan,
                            )
                            .with_code(codes::TYPE_OVERRIDE_BUT_NO_BASE),
                        );
                    }
                }
            }
        }
        // Spec §5.4 override-rule diagnostics — for every member declared
        // with `override`, locate the matching base member by name and
        // verify return-type / property-type / mutability / visibility.
        let mut inherited_sigs = self.collect_inherited_member_sigs(c);
        self.inject_function_type_supertypes(c, &mut inherited, &mut inherited_sigs);
        for m in &c.members {
            match m {
                Decl::Function(f) if f.is_override => {
                    if let Some(MemberSig::Function {
                        return_ty: base_ret,
                        visibility: base_vis,
                        ..
                    }) = inherited_sigs.get(&f.name.name)
                    {
                        // Only check when both ends have explicit return
                        // types — an omitted return type on an expression
                        // body is inferred and may legitimately resolve to
                        // the base's type.
                        let derived_ret = f.return_type.as_ref().map(convert_type_ref_lossy);
                        let check_ret = derived_ret
                            .as_ref()
                            .map(|d| !d.is_subtype_of(base_ret))
                            .unwrap_or(false);
                        if check_ret {
                            let derived_ret = derived_ret.unwrap();
                            self.diagnostics.emit(
                                Diagnostic::error(
                                    format!(
                                        "return type `{derived_ret}` of override `{name}` \
                                         is not a subtype of overridden return type `{base_ret}`",
                                        name = f.name.name
                                    ),
                                    f.name.span,
                                )
                                .with_code(codes::TYPE_OVERRIDE_RETURN_TYPE_MISMATCH),
                            );
                        }
                        self.check_override_visibility(
                            &f.name.name,
                            f.name.span,
                            f.visibility,
                            *base_vis,
                        );
                    }
                }
                Decl::Property(p) if p.is_override => {
                    if let Some(MemberSig::Property {
                        ty: base_ty,
                        mutable: base_mut,
                        visibility: base_vis,
                    }) = inherited_sigs.get(&p.name.name)
                    {
                        let derived_ty = p
                            .ty
                            .as_ref()
                            .map(convert_type_ref_lossy)
                            .unwrap_or(Type::Unresolved);
                        // T0066: mutability cannot strengthen. var base + val
                        // override is forbidden (val is stronger than var).
                        if *base_mut && !p.mutable {
                            self.diagnostics.emit(
                                Diagnostic::error(
                                    format!(
                                        "property `{name}` overrides `var` base with `val`: \
                                         mutability cannot strengthen",
                                        name = p.name.name
                                    ),
                                    p.name.span,
                                )
                                .with_code(codes::TYPE_OVERRIDE_PROPERTY_MUTABILITY),
                            );
                        }
                        // T0067: type subtype, except both `var` requires
                        // equivalent types.
                        let type_ok = if *base_mut && p.mutable {
                            derived_ty == *base_ty
                                || matches!(derived_ty, Type::Unresolved)
                                || matches!(base_ty, Type::Unresolved)
                        } else {
                            derived_ty.is_subtype_of(base_ty)
                        };
                        if !type_ok {
                            let msg = if *base_mut && p.mutable {
                                format!(
                                    "property `{}` overrides `var` base of type `{base_ty}` with \
                                     non-equivalent type `{derived_ty}`",
                                    p.name.name
                                )
                            } else {
                                format!(
                                    "type `{derived_ty}` of override property `{}` is not a \
                                     subtype of overridden type `{base_ty}`",
                                    p.name.name
                                )
                            };
                            self.diagnostics.emit(
                                Diagnostic::error(msg, p.name.span)
                                    .with_code(codes::TYPE_OVERRIDE_PROPERTY_TYPE),
                            );
                        }
                        self.check_override_visibility(
                            &p.name.name,
                            p.name.span,
                            p.visibility,
                            *base_vis,
                        );
                    }
                }
                _ => {}
            }
        }
        // Abstract-member check for concrete classes inheriting from one
        // of our user-defined abstract/interface classes.
        if !c.is_abstract && !c.is_interface {
            let mut required: Vec<String> = Vec::new();
            for (i, s) in c.supertypes.iter().enumerate() {
                // Delegated interfaces have synthesized forwarders; the
                // abstract slots are satisfied by the delegate at runtime.
                let is_delegated = matches!(c.supertype_delegates.get(i), Some(Some(_)));
                if is_delegated {
                    continue;
                }
                if let Some(parent) = self.classes.get(&s.name.name) {
                    if parent.is_abstract || parent.is_interface {
                        for am in &parent.abstract_members {
                            required.push(am.clone());
                        }
                    }
                }
            }
            if !required.is_empty() {
                let info = self.classes.get(&c.name.name).cloned().unwrap_or_default();
                let provided: std::collections::HashSet<&String> =
                    info.concrete_members.iter().collect();
                let missing: Vec<&String> = required.iter().filter(|n| !provided.contains(n)).collect();
                if !missing.is_empty() {
                    let names: Vec<String> = missing.iter().map(|s| (*s).clone()).collect();
                    self.diagnostics.emit(
                        Diagnostic::error(
                            format!(
                                "Class `{}` is not abstract and does not implement abstract member(s): {}",
                                c.name.name,
                                names.join(", ")
                            ),
                            c.name.span,
                        )
                        .with_code(codes::TYPE_ABSTRACT_MEMBER_NOT_IMPLEMENTED),
                    );
                }
            }
        }

        // Diamond inheritance: for each member name, count distinct
        // supertypes that supply a default body. If 2+ supertypes provide
        // a default for the same name and this class does not declare an
        // explicit `override`, Kotlin requires an explicit disambiguation.
        if !c.is_interface {
            let providers = self.collect_default_providers(c);
            let class_overrides: std::collections::HashSet<&str> = c
                .members
                .iter()
                .filter_map(|m| match m {
                    Decl::Function(f) if f.is_override => Some(f.name.name.as_str()),
                    Decl::Property(p) if p.is_override => Some(p.name.name.as_str()),
                    _ => None,
                })
                .collect();
            for (member, supplying) in &providers {
                // Filter out suppliers shadowed by another supplier that is
                // a (transitive) subtype — a subclass's override hides the
                // parent's default, so only "leaf" suppliers conflict.
                let leaves: Vec<&(String, bool)> = supplying
                    .iter()
                    .filter(|(s, _)| {
                        !supplying
                            .iter()
                            .any(|(other, _)| other != s && self.is_subtype_of(other, s))
                    })
                    .collect();
                if leaves.is_empty() {
                    continue;
                }
                let concrete_leaves: Vec<&String> =
                    leaves.iter().filter(|(_, c)| *c).map(|(s, _)| s).collect();
                let abstract_leaves: Vec<&String> =
                    leaves.iter().filter(|(_, c)| !*c).map(|(s, _)| s).collect();
                // Spec §5.3 cases that require explicit override:
                //   - 2+ concrete leaves (classic diamond);
                //   - ≥1 concrete and ≥1 abstract leaf from distinct ancestors.
                // Pure-abstract conflicts are covered by T0007 elsewhere.
                let needs_override = concrete_leaves.len() >= 2
                    || (!concrete_leaves.is_empty() && !abstract_leaves.is_empty());
                if !needs_override {
                    continue;
                }
                if class_overrides.contains(member.as_str()) {
                    continue;
                }
                let names = leaves
                    .iter()
                    .map(|(s, _)| s.as_str())
                    .collect::<Vec<_>>()
                    .join(", ");
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!(
                            "Class `{}` inherits conflicting members for `{member}` from supertypes ({names}); explicit `override` required",
                            c.name.name
                        ),
                        c.name.span,
                    )
                    .with_code(codes::TYPE_DIAMOND_CONFLICT),
                );
            }
        }

        // `lateinit` compile-time rules. Runtime correctness is handled in
        // the interpreter; here we reject the four illegal shapes.
        for m in &c.members {
            if let Decl::Property(p) = m {
                self.check_lateinit(p);
            }
        }

        // Accessor return-type annotation: enforce match against the
        // property's declared type when both are present.
        for m in &c.members {
            if let Decl::Property(p) = m {
                self.check_accessor_return_types(p);
            }
        }

        let class_saved_assigned = self.assigned.clone();
        self.push_frame();
        // Bind primary-ctor params (and the `this` members for any param).
        for p in &c.primary_params {
            let ty = convert_type_ref_lossy(&p.ty);
            let cn = class_name_from_typeref(&p.ty);
            self.current_frame().bindings.insert(
                p.name.name.clone(),
                Binding { ty, mutable: p.property == Some(true), decl_span: Some(p.name.span), class_name: cn, needs_init: false },
            );
            self.assigned.insert(p.name.name.clone());
            if let Some(default) = &p.default {
                let dty = self.check_expr(default, Some(&convert_type_ref_lossy(&p.ty)));
                self.check_assignable(&dty, &convert_type_ref_lossy(&p.ty), default.span());
            }
        }
        // Body properties bind in declaration order.
        for m in &c.members {
            match m {
                Decl::Property(p) => {
                    if let Some(init) = &p.init {
                        let want = p.ty.as_ref().map(convert_type_ref_lossy);
                        let ity = self.check_expr(init, want.as_ref());
                        if let Some(a) = want {
                            self.check_assignable(&ity, &a, init.span());
                        }
                    }
                    let _ = self.handle_accessors(p);
                }
                _ => {}
            }
        }
        // Inheritance-delegation diagnostics: validate each `: I by expr`
        // entry — target must be an interface, delegate expression must be
        // a subtype of the named interface.
        for (i, s) in c.supertypes.iter().enumerate() {
            let Some(Some(delegate_expr)) = c.supertype_delegates.get(i) else { continue };
            let target_name = &s.name.name;
            let target_is_interface = self
                .classes
                .get(target_name)
                .map(|info| info.is_interface)
                .unwrap_or(false);
            if !target_is_interface {
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!(
                            "Only interfaces can be delegated to; `{target_name}` is not an interface"
                        ),
                        s.span,
                    )
                    .with_code(codes::TYPE_DELEGATION_TARGET_NOT_INTERFACE),
                );
            }
            let _ = self.check_expr(delegate_expr, None);
            let delegate_class = self.expr_class.get(&delegate_expr.span()).cloned();
            if target_is_interface {
                if let Some(dcn) = delegate_class {
                    if &dcn != target_name && !self.is_subtype_of(&dcn, target_name) {
                        self.diagnostics.emit(
                            Diagnostic::error(
                                format!(
                                    "Delegate expression of type `{dcn}` is not a subtype of `{target_name}`"
                                ),
                                delegate_expr.span(),
                            )
                            .with_code(codes::TYPE_DELEGATION_TYPE_MISMATCH),
                        );
                    }
                }
            }
        }
        for b in &c.init_blocks {
            self.check_block(b, None);
        }
        // Secondary ctors.
        for sc in &c.secondary_ctors {
            self.check_secondary_ctor(sc);
        }
        for m in &c.members {
            if let Decl::Function(f) = m {
                self.check_function(f);
            }
        }
        for entry in &c.enum_entries {
            self.check_enum_entry(entry);
        }
        self.pop_frame();
        self.assigned = class_saved_assigned;
        self.class_stack.pop();
    }

    /// Walk every declared supertype (transitively) and gather member
    /// flags. The first-seen flags win for a given member name; that's
    /// good enough for diagnostic purposes — the override-correctness
    /// check only cares whether *some* supertype declared an open/abstract
    /// member with that name.
    /// Spec §5.4: an explicit override visibility must not be stronger
    /// than the overridden declaration's visibility. Strength order:
    /// public < internal < protected < private.
    fn check_override_visibility(
        &mut self,
        name: &str,
        span: Span,
        derived: Visibility,
        base: Visibility,
    ) {
        let strength = |v: Visibility| match v {
            Visibility::Public => 0u8,
            Visibility::Internal => 1,
            Visibility::Protected => 2,
            Visibility::Private => 3,
        };
        if strength(derived) > strength(base) {
            let vis_name = |v: Visibility| match v {
                Visibility::Public => "public",
                Visibility::Internal => "internal",
                Visibility::Protected => "protected",
                Visibility::Private => "private",
            };
            self.diagnostics.emit(
                Diagnostic::error(
                    format!(
                        "override `{name}` cannot weaken visibility: declared `{}` is stronger \
                         than overridden `{}`",
                        vis_name(derived),
                        vis_name(base)
                    ),
                    span,
                )
                .with_code(codes::TYPE_OVERRIDE_VISIBILITY_STRONGER),
            );
        }
    }

    fn check_private_open_or_override(
        &mut self,
        name: &str,
        span: Span,
        is_open: bool,
        is_abstract: bool,
        is_override: bool,
    ) {
        let modifier = if is_open {
            Some("open")
        } else if is_abstract {
            Some("abstract")
        } else if is_override {
            Some("override")
        } else {
            None
        };
        if let Some(modifier) = modifier {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!(
                        "`{name}` cannot be both `private` and `{modifier}`"
                    ),
                    span,
                )
                .with_code(codes::TYPE_PRIVATE_AND_OPEN_OR_ABSTRACT_OR_OVERRIDE),
            );
        }
    }

    /// Spec §5.1: check each declared supertype is legal to inherit from.
    /// Closed (default-final) user classes and `object` types are forbidden;
    /// interfaces, `open` / `abstract` / `sealed` classes are allowed. Built-in
    /// supertypes we don't know about (Any, Throwable, etc.) are skipped.
    fn check_supertype_validity(&mut self, derived_name: &str, supertypes: &[TypeRef]) {
        let derived_local = self
            .classes
            .get(derived_name)
            .map(|i| i.is_local_or_anonymous)
            .unwrap_or(false);
        for s in supertypes {
            let name = &s.name.name;
            let Some(parent) = self.classes.get(name) else { continue };
            if parent.is_sealed && derived_local {
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!(
                            "local class `{derived_name}` cannot inherit from sealed type `{name}`: \
                             sealed inheritors must have a fully-qualified name"
                        ),
                        s.span,
                    )
                    .with_code(codes::TYPE_SEALED_INHERITOR_NOT_QUALIFIED),
                );
            }
            if parent.is_object {
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!(
                            "`{derived_name}` cannot inherit from object `{name}`: \
                             object types cannot be inherited from"
                        ),
                        s.span,
                    )
                    .with_code(codes::TYPE_INHERIT_FROM_OBJECT),
                );
                continue;
            }
            if parent.is_interface {
                continue;
            }
            let open = parent.is_open || parent.is_abstract || parent.is_sealed;
            if !open {
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!(
                            "`{derived_name}` cannot inherit from final class `{name}`: \
                             declare it `open`, `abstract`, or `sealed`"
                        ),
                        s.span,
                    )
                    .with_code(codes::TYPE_INHERIT_FROM_FINAL_CLASS),
                );
            }
        }
    }

    fn is_throwable_subtype(&self, c: &Class) -> bool {
        const BUILTIN_THROWABLES: &[&str] = &[
            "Throwable",
            "Exception",
            "RuntimeException",
            "Error",
            "IllegalArgumentException",
            "IllegalStateException",
            "IndexOutOfBoundsException",
            "NullPointerException",
            "ArithmeticException",
            "ClassCastException",
            "NoSuchElementException",
            "UnsupportedOperationException",
            "NumberFormatException",
            "NoWhenBranchMatchedException",
            "UninitializedPropertyAccessException",
        ];
        let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
        let mut stack: Vec<String> =
            c.supertypes.iter().map(|s| s.name.name.clone()).collect();
        while let Some(name) = stack.pop() {
            if !seen.insert(name.clone()) {
                continue;
            }
            if BUILTIN_THROWABLES.contains(&name.as_str()) {
                return true;
            }
            if let Some(info) = self.classes.get(&name) {
                for s in &info.supertypes {
                    stack.push(s.clone());
                }
            }
        }
        false
    }

    /// Synthesize the `invoke` slot for each function-type supertype, so
    /// `class C : () -> Int { override fun invoke(): Int = ... }` resolves
    /// correctly. Spec §5.1.3: function types are treated as interfaces.
    fn inject_function_type_supertypes(
        &self,
        c: &Class,
        flags: &mut HashMap<String, MemberFlags>,
        sigs: &mut HashMap<String, MemberSig>,
    ) {
        for s in &c.supertypes {
            let Some(fnref) = s.function.as_ref() else { continue };
            flags
                .entry("invoke".to_string())
                .or_insert(MemberFlags {
                    is_open: true,
                    is_override: false,
                    is_abstract: true,
                    is_operator: true,
                    is_infix: false,
                    has_default_body: false,
                });
            let param_types: Vec<Type> = fnref
                .params
                .iter()
                .map(convert_type_ref_lossy)
                .collect();
            let return_ty = convert_type_ref_lossy(&fnref.ret);
            sigs.entry("invoke".to_string()).or_insert(MemberSig::Function {
                param_types,
                return_ty,
                visibility: Visibility::Public,
            });
        }
    }

    /// Same walk as `collect_inherited_member_flags`, but collects the
    /// detailed member signatures used by T0065 / T0066 / T0067 / T0068.
    /// The first occurrence wins (closest ancestor in the supertype walk),
    /// matching the inheritance-order rule.
    fn collect_inherited_member_sigs(&self, c: &Class) -> HashMap<String, MemberSig> {
        let mut out: HashMap<String, MemberSig> = HashMap::new();
        let mut frontier: Vec<String> =
            c.supertypes.iter().map(|s| s.name.name.clone()).collect();
        let mut seen: Vec<String> = vec![c.name.name.clone()];
        let mut steps = 0;
        while let Some(parent_name) = frontier.pop() {
            if steps > 64 {
                break;
            }
            steps += 1;
            if seen.iter().any(|s| s == &parent_name) {
                continue;
            }
            seen.push(parent_name.clone());
            let Some(parent) = self.classes.get(&parent_name) else { continue };
            for (n, sig) in &parent.member_sigs {
                out.entry(n.clone()).or_insert_with(|| sig.clone());
            }
            for s in &parent.supertypes {
                frontier.push(s.clone());
            }
        }
        out
    }

    fn collect_inherited_member_flags(
        &self,
        c: &Class,
    ) -> HashMap<String, MemberFlags> {
        let mut out: HashMap<String, MemberFlags> = HashMap::new();
        let mut frontier: Vec<String> =
            c.supertypes.iter().map(|s| s.name.name.clone()).collect();
        let mut seen: Vec<String> = vec![c.name.name.clone()];
        let mut steps = 0;
        while let Some(parent_name) = frontier.pop() {
            if steps > 64 {
                break;
            }
            steps += 1;
            if seen.iter().any(|s| s == &parent_name) {
                continue;
            }
            seen.push(parent_name.clone());
            let Some(parent) = self.classes.get(&parent_name) else { continue };
            for (n, flags) in &parent.member_flags {
                let mut effective = *flags;
                // An override member without explicit `final` is itself
                // overridable in Kotlin. We don't model `final`, so treat
                // any override-marked parent as open for diagnostic purposes.
                if effective.is_override {
                    effective.is_open = true;
                }
                out.entry(n.clone()).or_insert(effective);
            }
            for s in &parent.supertypes {
                frontier.push(s.clone());
            }
        }
        out
    }

    fn check_enum_entry(&mut self, e: &EnumEntry) {
        for a in &e.args {
            self.check_expr(a, None);
        }
        for m in &e.body_members {
            self.check_decl(m);
        }
    }

    fn handle_accessors(&mut self, p: &Property) {
        if let Some(g) = &p.getter {
            self.check_accessor(g);
        }
        if let Some(s) = &p.setter {
            self.check_accessor(s);
        }
        if let Some(d) = &p.delegate {
            self.check_expr(d, None);
            self.check_delegate_operator(p, d);
        }
    }

    /// For `val/var x by EXPR`, when EXPR resolves to a constructor call on a
    /// user class, require that class's `getValue` (and `setValue` for `var`)
    /// carry the `operator` modifier. Emitted as a warning (T0012).
    fn check_delegate_operator(&mut self, p: &Property, delegate: &Expr) {
        let class_name = match delegate {
            Expr::Call { callee, .. } => match callee.as_ref() {
                Expr::Path { segments, .. } => segments.last().map(|s| s.name.clone()),
                _ => None,
            },
            Expr::Path { segments, .. } => segments.last().map(|s| s.name.clone()),
            _ => None,
        };
        let Some(class_name) = class_name else { return };
        let Some(info) = self.classes.get(&class_name) else { return };
        let needed: &[&str] = if p.mutable {
            &["getValue", "setValue"]
        } else {
            &["getValue"]
        };
        for member in needed {
            let Some(flags) = info.member_flags.get(*member) else { continue };
            if !flags.is_operator {
                self.diagnostics.emit(
                    Diagnostic::warning(
                        format!(
                            "`{class_name}.{member}` is used as a property-delegate convention but is missing the `operator` modifier"
                        ),
                        delegate.span(),
                    )
                    .with_code(codes::TYPE_DELEGATE_OPERATOR_REQUIRED),
                );
            }
        }
    }

    /// Compile-time rules for `lateinit`. Kotlin restricts `lateinit` to:
    /// non-null, non-primitive, `var` properties with no initializer.
    fn check_lateinit(&mut self, p: &Property) {
        if !p.is_lateinit {
            return;
        }
        if !p.mutable {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!("`lateinit` modifier is not allowed on `val` (use `lateinit var` for `{}`)", p.name.name),
                    p.name.span,
                )
                .with_code(codes::TYPE_LATEINIT_VAL),
            );
        }
        if let Some(init) = &p.init {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!("`lateinit` property `{}` cannot have an initializer", p.name.name),
                    init.span(),
                )
                .with_code(codes::TYPE_LATEINIT_WITH_INITIALIZER),
            );
        }
        if let Some(ty) = &p.ty {
            if ty.nullable {
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!(
                            "`lateinit` property `{}` may not have a nullable type",
                            p.name.name
                        ),
                        ty.span,
                    )
                    .with_code(codes::TYPE_LATEINIT_NULLABLE),
                );
            }
            if is_primitive_type_name(&ty.name.name) {
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!(
                            "`lateinit` modifier is not allowed on properties of primitive type `{}`",
                            ty.name.name
                        ),
                        ty.span,
                    )
                    .with_code(codes::TYPE_LATEINIT_PRIMITIVE),
                );
            }
        }
    }

    /// Enforce that an accessor's explicit return-type annotation matches
    /// the property's declared type.
    fn check_accessor_return_types(&mut self, p: &Property) {
        let Some(prop_ty_ref) = p.ty.as_ref() else { return };
        let prop_ty = convert_type_ref_lossy(prop_ty_ref);
        for (a, label) in [
            (p.getter.as_ref(), "getter"),
            (p.setter.as_ref(), "setter"),
        ] {
            let Some(a) = a else { continue };
            let Some(rt) = a.return_type.as_ref() else { continue };
            let rty = convert_type_ref_lossy(rt);
            if !self.types_match_for_accessor(&rty, &prop_ty) {
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!(
                            "{label} return type `{}` does not match property type `{}`",
                            type_display(&rty),
                            type_display(&prop_ty)
                        ),
                        rt.span,
                    )
                    .with_code(codes::TYPE_ACCESSOR_RETURN_TYPE_MISMATCH),
                );
            }
        }
    }

    fn types_match_for_accessor(&self, a: &Type, b: &Type) -> bool {
        // Skip the check entirely if either side lowered to Unresolved
        // (user types, generics, etc.) to avoid false positives.
        if matches!(a, Type::Unresolved) || matches!(b, Type::Unresolved) {
            return true;
        }
        a == b
    }

    /// True when `sub` is a transitive supertype-walk descendant of `sup`.
    fn is_subtype_of(&self, sub: &str, sup: &str) -> bool {
        if sub == sup {
            return false;
        }
        let mut frontier = vec![sub.to_string()];
        let mut steps = 0;
        let mut seen: Vec<String> = Vec::new();
        while let Some(name) = frontier.pop() {
            if steps > 64 {
                return false;
            }
            steps += 1;
            if seen.iter().any(|s| s == &name) {
                continue;
            }
            seen.push(name.clone());
            let Some(info) = self.classes.get(&name) else { continue };
            for s in &info.supertypes {
                if s == sup {
                    return true;
                }
                frontier.push(s.clone());
            }
        }
        false
    }

    /// For diamond detection: for every member name supplied by some
    /// supertype, list `(supertype, has_default_body)` pairs. Walks the
    /// transitive supertype set. A `has_default_body == false` entry is
    /// an abstract slot and triggers the spec §5.3 abstract-and-concrete
    /// rule.
    fn collect_default_providers(
        &self,
        c: &Class,
    ) -> HashMap<String, Vec<(String, bool)>> {
        let mut out: HashMap<String, Vec<(String, bool)>> = HashMap::new();
        let mut frontier: Vec<String> =
            c.supertypes.iter().map(|s| s.name.name.clone()).collect();
        let mut seen: Vec<String> = vec![c.name.name.clone()];
        let mut steps = 0;
        while let Some(parent_name) = frontier.pop() {
            if steps > 64 {
                break;
            }
            steps += 1;
            if seen.iter().any(|s| s == &parent_name) {
                continue;
            }
            seen.push(parent_name.clone());
            let Some(parent) = self.classes.get(&parent_name) else { continue };
            for (n, flags) in &parent.member_flags {
                // A supplier is either concrete (has_default_body) or
                // abstract. Body-less interface methods don't carry an
                // explicit `abstract` modifier but are abstract slots for
                // inheritance purposes; the same goes for body-less
                // interface / abstract-class properties.
                let is_abstract_slot = flags.is_abstract
                    || (parent.is_interface && !flags.has_default_body);
                if flags.has_default_body || is_abstract_slot {
                    let entry = out.entry(n.clone()).or_default();
                    if !entry.iter().any(|(s, _)| s == &parent_name) {
                        entry.push((parent_name.clone(), flags.has_default_body));
                    }
                }
            }
            for s in &parent.supertypes {
                frontier.push(s.clone());
            }
        }
        out
    }

    fn check_accessor(&mut self, a: &Accessor) {
        let saved = self.assigned.clone();
        self.push_frame();
        for p in &a.params {
            self.current_frame().bindings.insert(
                p.name.clone(),
                Binding { ty: Type::Unresolved, mutable: false, decl_span: Some(p.span), class_name: None, needs_init: false },
            );
            self.assigned.insert(p.name.clone());
        }
        match &a.body {
            FunctionBody::Block(b) => {
                self.check_block(b, None);
            }
            FunctionBody::Expr(e) => {
                self.check_expr(e, None);
            }
        }
        self.pop_frame();
        self.assigned = saved;
    }

    fn check_secondary_ctor(&mut self, sc: &SecondaryCtor) {
        let saved = self.assigned.clone();
        self.push_frame();
        for p in &sc.params {
            let ty = convert_type_ref_lossy(&p.ty);
            let cn = class_name_from_typeref(&p.ty);
            self.current_frame().bindings.insert(
                p.name.name.clone(),
                Binding { ty, mutable: false, decl_span: Some(p.name.span), class_name: cn, needs_init: false },
            );
            self.assigned.insert(p.name.name.clone());
        }
        match &sc.delegation {
            CtorDelegation::This(args) | CtorDelegation::Super(args) => {
                for a in args {
                    self.check_expr(a, None);
                }
            }
            CtorDelegation::None => {}
        }
        if let Some(b) = &sc.body {
            self.check_block(b, None);
        }
        self.pop_frame();
        self.assigned = saved;
    }

    fn check_object(&mut self, o: &ObjectDecl) {
        let saved = self.assigned.clone();
        self.class_stack.push(o.name.name.clone());
        self.check_supertype_validity(&o.name.name, &o.supertypes);
        self.push_frame();
        for m in &o.members {
            match m {
                Decl::Property(p) => {
                    if let Some(init) = &p.init {
                        let want = p.ty.as_ref().map(convert_type_ref_lossy);
                        let ity = self.check_expr(init, want.as_ref());
                        if let Some(a) = want {
                            self.check_assignable(&ity, &a, init.span());
                        }
                    }
                    let _ = self.handle_accessors(p);
                }
                Decl::Function(f) => self.check_function(f),
                _ => {}
            }
        }
        self.pop_frame();
        self.assigned = saved;
        self.class_stack.pop();
    }

    // ---- statements & blocks --------------------------------------------

    fn check_block(&mut self, block: &Block, expected: Option<&Type>) -> Type {
        self.push_frame();
        let mut last = Type::Unit;
        for (i, s) in block.stmts.iter().enumerate() {
            let is_last = i + 1 == block.stmts.len();
            last = self.check_stmt(s, if is_last { expected } else { None });
        }
        self.pop_frame();
        last
    }

    fn check_stmt(&mut self, stmt: &Stmt, expected: Option<&Type>) -> Type {
        match stmt {
            Stmt::Expr(e) => self.check_expr(e, expected),
            Stmt::Decl(d) => {
                self.check_local_decl(d);
                Type::Unit
            }
            Stmt::Assign { target, op, value, span } => {
                self.check_assign(target, *op, value, *span);
                Type::Unit
            }
            Stmt::DestructuringDecl { names, init, mutable, .. } => {
                let _ = self.check_expr(init, None);
                for n in names {
                    if n.name == "_" {
                        continue;
                    }
                    self.current_frame().bindings.insert(
                        n.name.clone(),
                        Binding {
                            ty: Type::Unresolved,
                            mutable: *mutable,
                            decl_span: Some(n.span), class_name: None, needs_init: false },
                    );
                    self.assigned.insert(n.name.clone());
                }
                Type::Unit
            }
        }
    }

    fn check_local_decl(&mut self, decl: &Decl) {
        match decl {
            Decl::Property(p) => {
                let annot = p.ty.as_ref().map(convert_type_ref_lossy);
                let init_ty = if let Some(init) = &p.init {
                    self.check_expr(init, annot.as_ref())
                } else if let Some(d) = &p.delegate {
                    self.check_expr(d, None);
                    Type::Unresolved
                } else {
                    Type::Unresolved
                };
                let declared = annot.clone().unwrap_or_else(|| init_ty.clone());
                if let (Some(a), Some(init)) = (annot, p.init.as_ref()) {
                    self.check_assignable(&init_ty, &a, init.span());
                }
                let mut cn = p.ty.as_ref().and_then(class_name_from_typeref);
                if cn.is_none() {
                    if let Some(init) = &p.init {
                        cn = self.expr_class.get(&init.span()).cloned();
                    }
                }
                let has_init = p.init.is_some() || p.delegate.is_some();
                let needs_init = !has_init && !p.is_lateinit;
                if !needs_init {
                    self.assigned.insert(p.name.name.clone());
                }
                self.current_frame().bindings.insert(
                    p.name.name.clone(),
                    Binding {
                        ty: declared,
                        mutable: p.mutable,
                        decl_span: Some(p.name.span),
                        class_name: cn,
                        needs_init,
                    },
                );
            }
            Decl::Function(f) => {
                let sig = self.signature_of(f);
                let fn_ty = Type::Function {
                    params: sig.params.clone(),
                    return_type: Box::new(sig.return_ty.clone()),
                };
                self.current_frame().bindings.insert(
                    f.name.name.clone(),
                    Binding { ty: fn_ty, mutable: false, decl_span: Some(f.name.span), class_name: None, needs_init: false },
                );
                self.assigned.insert(f.name.name.clone());
                self.fns.entry(f.name.name.clone()).or_default().push(sig);
                self.check_function(f);
            }
            Decl::Class(c) => {
                let mut info = self.class_info(c);
                info.is_local_or_anonymous = true;
                self.classes.insert(c.name.name.clone(), info);
                self.check_class(c);
            }
            Decl::Object(o) => {
                let mut info = ClassInfo::default();
                info.is_object = true;
                info.is_local_or_anonymous = true;
                info.decl_file = Some(o.name.span.file);
                self.collect_members(&o.members, &mut info);
                self.classes.insert(o.name.name.clone(), info);
                self.check_object(o);
            }
            Decl::TypeAlias(_) => {}
        }
    }

    fn check_assign(&mut self, target: &Expr, op: AssignOp, value: &Expr, _span: Span) {
        // Reassignment-of-val check for the simple identifier case.
        if let Expr::Path { segments, span } = target {
            if segments.len() == 1 {
                let name = &segments[0].name;
                // Spec §4.6: per-accessor visibility on `var x; private set`.
                // Reject the write when use site is outside the setter's
                // declared scope.
                if let Some((sv, decl_file)) = self.setter_visibility.get(name).copied() {
                    if matches!(sv, Visibility::Private) && span.file != decl_file {
                        self.diagnostics.emit(
                            Diagnostic::error(
                                format!(
                                    "Cannot assign to `{name}`: setter is `private` in its \
                                     declaring file"
                                ),
                                *span,
                            )
                            .with_code(codes::TYPE_INVISIBLE_REFERENCE),
                        );
                    }
                }
                let info = self
                    .lookup(name)
                    .map(|b| (b.ty.clone(), b.mutable, b.needs_init));
                if let Some((want, mutable, needs_init)) = info {
                    let already_assigned = self.assigned.contains(name);
                    let is_first_write = needs_init && !already_assigned;
                    // §7.1.2: a compound assignment to a `val` is permitted
                    // when the LHS type carries a matching `*Assign` operator
                    // (the operator-function path mutates in place, never
                    // rebinds the name). Plain `=` reassignment still errors.
                    let compound_with_assign = !matches!(op, AssignOp::Assign)
                        && type_has_compound_assign(&want, op);
                    if !mutable && !is_first_write && !compound_with_assign {
                        self.diagnostics.emit(
                            Diagnostic::error(
                                format!("Val cannot be reassigned: `{name}`"),
                                *span,
                            )
                            .with_code(codes::TYPE_VAL_REASSIGN),
                        );
                    }
                    let got = self.check_expr(value, Some(&want));
                    self.check_assignable(&got, &want, value.span());
                    self.assigned.insert(name.clone());
                    return;
                }
            }
        }
        let _ = self.check_expr(target, None);
        let _ = self.check_expr(value, None);
    }

    // ---- expression typing ----------------------------------------------

    fn check_expr(&mut self, expr: &Expr, expected: Option<&Type>) -> Type {
        let ty = self.compute_expr_ty(expr, expected);
        self.types.insert(expr.span(), ty.clone());
        ty
    }

    #[allow(clippy::too_many_lines)]
    fn compute_expr_ty(&mut self, expr: &Expr, expected: Option<&Type>) -> Type {
        match expr {
            Expr::IntLit { kind, .. } => {
                // Suffix-typed `1L` is unconditionally Long. An unsuffixed
                // integer literal coerces to any narrow integer / Long when
                // an expected type drives the call site (kotlinc-native
                // semantics for constant operands).
                if matches!(kind, klio_ast::IntLitKind::Long) {
                    return Type::Long;
                }
                if let Some(t) = expected {
                    if matches!(t.non_null(), Type::Long | Type::Short | Type::Byte | Type::Int) {
                        return t.non_null().clone();
                    }
                }
                Type::Int
            }
            Expr::FloatLit { kind, .. } => {
                if matches!(kind, klio_ast::FloatLitKind::Float) {
                    return Type::Float;
                }
                if let Some(t) = expected {
                    if matches!(t.non_null(), Type::Float | Type::Double) {
                        return t.non_null().clone();
                    }
                }
                Type::Double
            }
            Expr::BoolLit { .. } => Type::Boolean,
            Expr::CharLit { .. } => Type::Char,
            Expr::NullLit { .. } => Type::Nullable(Box::new(Type::Nothing)),
            Expr::StringTemplate { parts, .. } => {
                for part in parts {
                    if let StringPart::Interp(e) = part {
                        self.check_expr(e, None);
                    }
                }
                Type::String
            }
            Expr::Path { segments, span } => {
                if segments.len() == 1 {
                    let name = &segments[0].name;
                    if let Some(cn) = self.lookup_narrowed_class(name) {
                        self.expr_class.insert(*span, cn);
                    }
                    if let Some(narrowed) = self.lookup_narrowed(name) {
                        return narrowed;
                    }
                    if let Some(b) = self.lookup(name) {
                        let cn = b.class_name.clone();
                        let ty = b.ty.clone();
                        let needs_init = b.needs_init;
                        if let Some((v, f)) = self.prop_visibility.get(name).copied() {
                            self.check_top_level_visibility(name, v, f, *span);
                            let anns = self.prop_annotations.get(name).cloned().unwrap_or_default();
                            self.check_published_api_use(name, v, &anns, *span);
                        }
                        if needs_init && !self.assigned.contains(name) {
                            self.diagnostics.emit(
                                Diagnostic::error(
                                    format!(
                                        "Variable '{name}' must be initialized"
                                    ),
                                    *span,
                                )
                                .with_code(codes::TYPE_VAR_NOT_DEFINITELY_ASSIGNED),
                            );
                        }
                        if let Some(cn) = cn {
                            self.expr_class.insert(*span, cn);
                        }
                        return ty;
                    }
                    if let Some(sigs) = self.fns.get(name) {
                        // Function reference (not a call) — pick the first
                        // declared overload to materialize a function type.
                        if let Some(sig) = sigs.first().cloned() {
                            return Type::Function {
                                params: sig.params,
                                return_type: Box::new(sig.return_ty),
                            };
                        }
                    }
                    if self.classes.contains_key(name) {
                        self.expr_class.insert(*span, name.clone());
                        return Type::Unresolved;
                    }
                    // Resolved by name resolver but not in our tables (e.g.
                    // stdlib). Silently stay tolerant.
                    let _ = span;
                    return Type::Unresolved;
                }
                Type::Unresolved
            }
            Expr::Member { receiver, name, safe, span } => {
                if let Some(key) = dot_path_key(expr) {
                    if let Some(cn) = self.lookup_narrowed_class(&key) {
                        self.expr_class.insert(*span, cn);
                    }
                    if let Some(narrowed) = self.lookup_narrowed(&key) {
                        let _ = self.check_expr(receiver, None);
                        return narrowed;
                    }
                }
                let recv_ty = self.check_expr(receiver, None);
                let recv_class = self.expr_class.get(&receiver.span()).cloned();
                self.check_member_access(
                    &recv_ty,
                    name.name.as_str(),
                    *safe,
                    receiver.span(),
                    recv_class.as_deref(),
                    *span,
                )
            }
            Expr::Call { callee, args, arg_names, span, is_infix, .. } => {
                if let Expr::Path { segments, .. } = callee.as_ref() {
                    if segments.len() == 1 {
                        let name = &segments[0].name;
                        if self.classes.contains_key(name) {
                            self.expr_class.insert(*span, name.clone());
                        }
                    }
                }
                // Spec §4.2: implicit lambda label — bind the call's
                // callee simple name as a label visible inside any lambda
                // argument so `xs.forEach { return@forEach }` checks.
                let implicit_label = match callee.as_ref() {
                    Expr::Path { segments, .. } => segments.last().map(|s| s.name.clone()),
                    Expr::Member { name, .. } => Some(name.name.clone()),
                    _ => None,
                };
                if let Some(l) = &implicit_label {
                    self.label_stack.push(l.clone());
                }
                let result = self.check_call(callee, args, arg_names, *span);
                if implicit_label.is_some() {
                    self.label_stack.pop();
                }
                if *is_infix {
                    self.check_infix_modifier(callee, args, *span);
                }
                result
            }
            Expr::Index { receiver, args, .. } => {
                let _ = self.check_expr(receiver, None);
                for a in args {
                    self.check_expr(a, None);
                }
                Type::Unresolved
            }
            Expr::Binary { op, lhs, rhs, span } => self.check_binary(*op, lhs, rhs, *span),
            Expr::Unary { op, expr, .. } => {
                let t = self.check_expr(expr, None);
                match op {
                    UnOp::Neg | UnOp::Pos => {
                        if is_numeric(&t) {
                            t
                        } else if matches!(t, Type::Unresolved) {
                            Type::Unresolved
                        } else {
                            Type::Unresolved
                        }
                    }
                    UnOp::Not => Type::Boolean,
                    UnOp::PreInc | UnOp::PreDec => t,
                }
            }
            Expr::Postfix { op, expr, .. } => {
                let t = self.check_expr(expr, None);
                match op {
                    PostfixOp::Inc | PostfixOp::Dec => t,
                    PostfixOp::NotNull => match t {
                        Type::Nullable(inner) => *inner,
                        other => other,
                    },
                }
            }
            Expr::If { cond, then_branch, else_branch, .. } => {
                let cond_narrow = self.check_condition(cond);
                let before = self.assigned.clone();
                self.push_frame();
                for (n, t) in &cond_narrow.true_branch {
                    self.current_frame().narrowings.insert(n.clone(), t.clone());
                }
                for (n, cn) in &cond_narrow.true_class {
                    self.current_frame().narrowing_class.insert(n.clone(), cn.clone());
                }
                let then_ty = self.check_expr(then_branch, expected);
                let then_diverges = matches!(then_ty, Type::Nothing);
                let after_then = self.assigned.clone();
                self.pop_frame();
                self.assigned = before.clone();
                let (else_ty, after_else, else_present, else_diverges) = if let Some(e) = else_branch {
                    self.push_frame();
                    for (n, t) in &cond_narrow.false_branch {
                        self.current_frame().narrowings.insert(n.clone(), t.clone());
                    }
                    for (n, cn) in &cond_narrow.false_class {
                        self.current_frame().narrowing_class.insert(n.clone(), cn.clone());
                    }
                    let t = self.check_expr(e, expected);
                    let diverges = matches!(t, Type::Nothing);
                    let after = self.assigned.clone();
                    self.pop_frame();
                    self.assigned = before.clone();
                    (t, after, true, diverges)
                } else {
                    (Type::Unit, before.clone(), false, false)
                };
                // Merge: a name is definitely assigned after the `if` iff
                // it's assigned on every non-diverging branch.
                let mut merged: HashSet<String> = before.clone();
                let then_contrib: Option<&HashSet<String>> = if then_diverges { None } else { Some(&after_then) };
                let else_contrib: Option<&HashSet<String>> = if !else_present {
                    Some(&before)
                } else if else_diverges {
                    None
                } else {
                    Some(&after_else)
                };
                match (then_contrib, else_contrib) {
                    (Some(t), Some(e)) => {
                        for n in t.intersection(e) {
                            merged.insert(n.clone());
                        }
                    }
                    (Some(t), None) => {
                        for n in t {
                            merged.insert(n.clone());
                        }
                    }
                    (None, Some(e)) => {
                        for n in e {
                            merged.insert(n.clone());
                        }
                    }
                    (None, None) => {}
                }
                self.assigned = merged;
                lub(&then_ty, &else_ty)
            }
            Expr::While { cond, body, .. } => {
                self.check_expr(cond, Some(&Type::Boolean));
                let before = self.assigned.clone();
                self.check_expr(body, None);
                // Loop body may run zero times; assignments inside don't
                // count as definite at the join point.
                self.assigned = before;
                Type::Unit
            }
            Expr::DoWhile { body, cond, .. } => {
                // Body always runs at least once, but we still don't promote
                // body-internal definite assignments to the join state because
                // a `break` from the body skips the rest.
                let before = self.assigned.clone();
                if let Some(b) = body {
                    self.check_expr(b, None);
                }
                self.check_expr(cond, Some(&Type::Boolean));
                self.assigned = before;
                Type::Unit
            }
            Expr::For { vars, iter, body, .. } => {
                let _ = self.check_expr(iter, None);
                let before = self.assigned.clone();
                self.push_frame();
                for v in vars {
                    self.current_frame().bindings.insert(
                        v.name.clone(),
                        Binding { ty: Type::Unresolved, mutable: false, decl_span: Some(v.span), class_name: None, needs_init: false },
                    );
                    self.assigned.insert(v.name.clone());
                }
                self.check_expr(body, None);
                self.pop_frame();
                self.assigned = before;
                Type::Unit
            }
            Expr::Return { value, label, span } => {
                if let Some(v) = value {
                    let expected = self.fn_return_stack.last().cloned();
                    let _ = self.check_expr(v, expected.as_ref());
                }
                if let Some(l) = label {
                    if !self.label_stack.iter().any(|x| x == &l.name) {
                        self.diagnostics.emit(
                            Diagnostic::error(
                                format!("label `{}` is not bound here", l.name),
                                *span,
                            )
                            .with_code(codes::TYPE_UNRESOLVED_LABEL),
                        );
                    }
                }
                Type::Nothing
            }
            Expr::Break { label, span } | Expr::Continue { label, span } => {
                if let Some(l) = label {
                    if !self.label_stack.iter().any(|x| x == &l.name) {
                        self.diagnostics.emit(
                            Diagnostic::error(
                                format!("label `{}` is not bound here", l.name),
                                *span,
                            )
                            .with_code(codes::TYPE_UNRESOLVED_LABEL),
                        );
                    }
                }
                Type::Nothing
            }
            Expr::Labeled { label, expr, .. } => {
                if !is_labelable_target(expr) {
                    self.diagnostics.emit(
                        Diagnostic::error(
                            format!(
                                "Label `{}@` can only be attached to a lambda literal, a loop, or a call with a trailing lambda",
                                label.name
                            ),
                            label.span,
                        )
                        .with_code(codes::TYPE_LABEL_TARGET_NOT_LABELABLE),
                    );
                }
                self.label_stack.push(label.name.clone());
                let ty = self.check_expr(expr, expected);
                self.label_stack.pop();
                ty
            }
            Expr::Block(b) => self.check_block(b, expected),
            Expr::Throw { value, .. } => {
                self.check_expr(value, None);
                Type::Nothing
            }
            Expr::Try { body, catches, finally, .. } => {
                let before = self.assigned.clone();
                let body_ty = self.check_block(body, expected);
                let after_body = self.assigned.clone();
                let mut acc = body_ty;
                // Each `catch` could fire at any point in the body — be
                // conservative and start its frame from `before`, not
                // `after_body`. The join keeps only assignments common to
                // body and every catch.
                let mut common: HashSet<String> = after_body.clone();
                for c in catches {
                    self.assigned = before.clone();
                    self.push_frame();
                    self.current_frame().bindings.insert(
                        c.binding.name.clone(),
                        Binding {
                            ty: convert_type_ref_lossy(&c.ty),
                            mutable: false,
                            decl_span: Some(c.binding.span), class_name: None, needs_init: false },
                    );
                    self.assigned.insert(c.binding.name.clone());
                    let cty = self.check_block(&c.body, expected);
                    let after_catch = self.assigned.clone();
                    self.pop_frame();
                    common = common.intersection(&after_catch).cloned().collect();
                    acc = lub(&acc, &cty);
                }
                self.assigned = common;
                if let Some(fb) = finally {
                    self.check_block(fb, None);
                }
                acc
            }
            Expr::Lambda { params, body, .. } => self.check_lambda(params, body, expected),
            Expr::This { qualifier, span } => {
                let target = qualifier
                    .as_ref()
                    .map(|q| q.name.clone())
                    .or_else(|| self.class_stack.last().cloned());
                if let Some(cn) = target {
                    self.expr_class.insert(*span, cn);
                }
                Type::Unresolved
            }
            Expr::Super { .. } => Type::Unresolved,
            Expr::PropertyRef { .. } => Type::Unresolved,
            Expr::MemberRef { receiver, .. } => {
                self.check_expr(receiver, None);
                Type::Unresolved
            }
            Expr::When { subject, subject_binding, branches, span } => {
                let subj_class = if let Some(s) = subject {
                    self.check_expr(s, None);
                    self.expr_class.get(&s.span()).cloned()
                } else {
                    None
                };
                // `when (val v = subject)` — register `v` as an immutable
                // local for the branch bodies.
                let pushed_binding = if let Some(b) = subject_binding {
                    self.push_frame();
                    let ty = if let Some(t) = &b.ty {
                        convert_type_ref_lossy(t)
                    } else {
                        subject.as_ref().and_then(|s| {
                            self.types.get(&s.span()).cloned()
                        }).unwrap_or(Type::Unresolved)
                    };
                    let class_name = subject
                        .as_ref()
                        .and_then(|s| self.expr_class.get(&s.span()).cloned());
                    self.frames.last_mut().unwrap().bindings.insert(
                        b.name.name.clone(),
                        Binding {
                            ty,
                            mutable: false,
                            decl_span: Some(b.name.span),
                            class_name,
                            needs_init: false,
                        },
                    );
                    self.assigned.insert(b.name.name.clone());
                    true
                } else {
                    false
                };
                let before = self.assigned.clone();
                let mut has_else = false;
                let mut branch_assigned: Vec<Option<HashSet<String>>> = Vec::new();
                let mut acc: Option<Type> = None;
                for b in branches {
                    for p in &b.patterns {
                        match &p.kind {
                            WhenPatternKind::Value(e)
                            | WhenPatternKind::InRange(e)
                            | WhenPatternKind::NotInRange(e) => {
                                self.check_expr(e, None);
                            }
                            _ => {}
                        }
                    }
                    if b.patterns.iter().any(|p| matches!(p.kind, WhenPatternKind::Else)) {
                        has_else = true;
                    }
                    self.assigned = before.clone();
                    let t = self.check_expr(&b.body, expected);
                    let after = if matches!(t, Type::Nothing) {
                        None
                    } else {
                        Some(self.assigned.clone())
                    };
                    branch_assigned.push(after);
                    acc = Some(match acc {
                        None => t,
                        Some(a) => lub(&a, &t),
                    });
                }
                // Merge branches when exhaustive (else present). Otherwise
                // the `when` may fall through with the pre-when state.
                if has_else && !branch_assigned.is_empty() {
                    let live: Vec<HashSet<String>> = branch_assigned
                        .into_iter()
                        .flatten()
                        .collect();
                    self.assigned = if live.is_empty() {
                        before
                    } else {
                        let mut iter = live.into_iter();
                        let first = iter.next().unwrap();
                        iter.fold(first, |acc, s| acc.intersection(&s).cloned().collect())
                    };
                } else {
                    self.assigned = before;
                }
                if let Some(cn) = subj_class {
                    self.check_when_exhaustive(&cn, branches, *span);
                }
                if pushed_binding {
                    self.pop_frame();
                }
                acc.unwrap_or(Type::Unit)
            }
            Expr::IsCheck { expr, ty, negated, span } => {
                let lhs_ty = self.check_expr(expr, None);
                // Spec §8.11.1 note: `null is T?` is always `true`; `null is
                // T` (non-nullable) is always `false`. Surface the
                // observation by recording the folded value into the
                // checker types map so downstream reachability passes can
                // pick it up. The literal `null` case fires the strongest
                // narrowing; we also handle the symmetric null-typed value
                // (Nothing? or a `val n: T? = null` after smart-cast).
                let lhs_is_null = matches!(expr.as_ref(), Expr::NullLit { .. })
                    || matches!(&lhs_ty, Type::Nullable(inner) if matches!(**inner, Type::Nothing));
                if lhs_is_null {
                    let always = if ty.nullable { !*negated } else { *negated };
                    let label = if always { "true" } else { "false" };
                    self.diagnostics.emit(
                        Diagnostic::warning(
                            format!(
                                "`{}` is always `{}` — `null` {} `{}` per spec §8.11.1",
                                if *negated { "!is" } else { "is" },
                                label,
                                if always { "is" } else { "is not" },
                                ty.name.name
                            ),
                            *span,
                        )
                        .with_code(codes::TYPE_UNCHECKED_CAST),
                    );
                }
                Type::Boolean
            }
            Expr::As { expr, ty, safe, span } => {
                self.check_expr(expr, None);
                if ty.type_args.iter().any(|a| !a.is_star) {
                    self.diagnostics.emit(
                        Diagnostic::warning(
                            format!("Unchecked cast: target type `{}` has erased type arguments", ty.name.name),
                            ty.span,
                        )
                        .with_code(codes::TYPE_UNCHECKED_CAST),
                    );
                }
                // Spec §8.16: `as?` against a non-reified type parameter T cannot be checked
                // at runtime — the cast may succeed even when the value is not a T.
                if *safe {
                    let target_name = &ty.name.name;
                    let is_type_param = self
                        .type_params_in_scope
                        .iter()
                        .any(|s| s.contains(target_name));
                    let is_reified = self
                        .reified_type_params
                        .iter()
                        .any(|s| s.contains(target_name));
                    if is_type_param && !is_reified {
                        self.diagnostics.emit(
                            Diagnostic::warning(
                                format!(
                                    "Safe cast `as? {target_name}` cannot be checked at runtime — type parameter is not `reified`"
                                ),
                                ty.span,
                            )
                            .with_code(codes::TYPE_CAST_TO_NON_REIFIED_TYPE_PARAMETER),
                        );
                    }
                }
                let target = convert_type_ref_lossy(ty);
                if let Some(cn) = class_name_from_typeref(ty) {
                    self.expr_class.insert(*span, cn);
                }
                if *safe {
                    target.as_nullable()
                } else {
                    target
                }
            }
            Expr::AnonFun { params, return_ty, body, .. } => {
                let saved = self.assigned.clone();
                self.push_frame();
                for p in params {
                    let pty = convert_type_ref_lossy(&p.ty);
                    self.current_frame().bindings.insert(
                        p.name.name.clone(),
                        Binding {
                            ty: pty,
                            mutable: false,
                            decl_span: Some(p.span),
                            class_name: None,
                            needs_init: false,
                        },
                    );
                    self.assigned.insert(p.name.name.clone());
                }
                let ret_expected = return_ty
                    .as_ref()
                    .map(convert_type_ref_lossy)
                    .unwrap_or(Type::Unresolved);
                if let Some(b) = body.as_deref() {
                    match b {
                        FunctionBody::Block(blk) => {
                            self.check_block(blk, Some(&ret_expected));
                        }
                        FunctionBody::Expr(e) => {
                            self.check_expr(e, Some(&ret_expected));
                        }
                    }
                }
                self.pop_frame();
                self.assigned = saved;
                let params_out = params
                    .iter()
                    .map(|p| convert_type_ref_lossy(&p.ty))
                    .collect::<Vec<_>>();
                let r = if matches!(ret_expected, Type::Unresolved) {
                    Type::Unit
                } else {
                    ret_expected
                };
                Type::Function { params: params_out, return_type: Box::new(r) }
            }
            Expr::Spread { expr, .. } => {
                // A bare `*expr` outside a call-arg position is invalid;
                // the call-arg site handles legal use. Recurse so any
                // sub-expression diagnostics still surface.
                self.check_expr(expr, None);
                Type::Unresolved
            }
            Expr::ObjectExpr { supertypes, supertype_args, supertype_delegates, members, .. } => {
                // Spec §5.1.2: anonymous object inheriting from a sealed type
                // is rejected — sealed inheritors require a fully-qualified
                // name. Same code path also catches inherit-from-object /
                // inherit-from-final-class for anonymous objects.
                for s in supertypes {
                    let pname = &s.name.name;
                    let Some(parent) = self.classes.get(pname) else { continue };
                    if parent.is_sealed {
                        self.diagnostics.emit(
                            Diagnostic::error(
                                format!(
                                    "anonymous object cannot inherit from sealed type `{pname}`: \
                                     sealed inheritors must have a fully-qualified name"
                                ),
                                s.span,
                            )
                            .with_code(codes::TYPE_SEALED_INHERITOR_NOT_QUALIFIED),
                        );
                    }
                    if parent.is_object {
                        self.diagnostics.emit(
                            Diagnostic::error(
                                format!(
                                    "anonymous object cannot inherit from object `{pname}`: \
                                     object types cannot be inherited from"
                                ),
                                s.span,
                            )
                            .with_code(codes::TYPE_INHERIT_FROM_OBJECT),
                        );
                        continue;
                    }
                    if !parent.is_interface
                        && !parent.is_open
                        && !parent.is_abstract
                        && !parent.is_sealed
                    {
                        self.diagnostics.emit(
                            Diagnostic::error(
                                format!(
                                    "anonymous object cannot inherit from final class `{pname}`: \
                                     declare it `open`, `abstract`, or `sealed`"
                                ),
                                s.span,
                            )
                            .with_code(codes::TYPE_INHERIT_FROM_FINAL_CLASS),
                        );
                    }
                }
                for d in supertype_delegates.iter().flatten() {
                    self.check_expr(d, None);
                }
                for args in supertype_args.iter().flatten() {
                    for a in args {
                        self.check_expr(a, None);
                    }
                }
                let saved = self.assigned.clone();
                for m in members {
                    match m {
                        Decl::Function(f) => self.check_function(f),
                        Decl::Property(p) => {
                            if let Some(init) = &p.init {
                                self.check_expr(init, None);
                            }
                            self.handle_accessors(p);
                        }
                        _ => {}
                    }
                }
                self.assigned = saved;
                Type::Unresolved
            }
        }
    }

    fn check_member_access(
        &mut self,
        recv_ty: &Type,
        name: &str,
        safe: bool,
        recv_span: Span,
        recv_class: Option<&str>,
        member_span: Span,
    ) -> Type {
        // Null-safety: dereferencing a known nullable without `?.` or `!!`.
        if !safe && matches!(recv_ty, Type::Nullable(_)) {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!(
                        "Only safe (?.) or non-null asserted (!!.) calls are allowed on a nullable receiver of type `{recv_ty}`"
                    ),
                    recv_span,
                )
                .with_code(codes::TYPE_NULL_SAFETY),
            );
        }
        let mut result = Type::Unresolved;
        let mut found_as_member = false;
        if let Some(class) = recv_class {
            if let Some((ty, cn)) = self.lookup_member_through_chain(class, name) {
                result = ty;
                found_as_member = true;
                if let Some(cn) = cn {
                    self.expr_class.insert(member_span, cn);
                }
            }
            self.check_member_visibility(class, name, Some(class), member_span);
        }
        if !found_as_member {
            if let Some(ep) = self.lookup_extension_property(recv_ty, recv_class, name) {
                result = ep.ty.clone();
                if let Some(cn) = ep.return_class.clone() {
                    self.expr_class.insert(member_span, cn);
                }
            }
        }
        if safe {
            result.as_nullable()
        } else {
            result
        }
    }

    fn lookup_extension_property(
        &self,
        recv_ty: &Type,
        recv_class: Option<&str>,
        name: &str,
    ) -> Option<ExtensionPropSig> {
        let mut keys: Vec<String> = Vec::new();
        if let Some(c) = recv_class {
            keys.push(c.to_string());
            let mut seen: HashSet<String> = HashSet::new();
            seen.insert(c.to_string());
            let mut frontier: Vec<String> = vec![c.to_string()];
            let mut steps = 0;
            while let Some(cn) = frontier.pop() {
                if steps > 64 { break; }
                steps += 1;
                let Some(info) = self.classes.get(&cn) else { continue };
                for s in &info.supertypes {
                    if seen.insert(s.clone()) {
                        keys.push(s.clone());
                        frontier.push(s.clone());
                    }
                }
            }
        }
        let head: Option<String> = match recv_ty.non_null() {
            Type::Int => Some("Int".into()),
            Type::Long => Some("Long".into()),
            Type::Double => Some("Double".into()),
            Type::Float => Some("Float".into()),
            Type::Boolean => Some("Boolean".into()),
            Type::String => Some("String".into()),
            Type::Char => Some("Char".into()),
            Type::Byte => Some("Byte".into()),
            Type::Short => Some("Short".into()),
            Type::Generic { name, .. } => Some(name.clone()),
            _ => None,
        };
        if let Some(h) = head {
            if !keys.iter().any(|k| k == &h) {
                keys.push(h);
            }
        }
        keys.push("Any".to_string());
        for key in &keys {
            let Some(list) = self.extension_properties.get(key) else { continue };
            for ep in list {
                if ep.name == name {
                    return Some(ep.clone());
                }
            }
        }
        None
    }

    /// Walk a receiver class's supertype chain plus `Any` looking for a
    /// matching extension by name + arity. Returns the chosen signature
    /// and the declared return user-class name if known.
    fn lookup_extension(
        &self,
        recv_class: &str,
        name: &str,
        args: &[Expr],
    ) -> Option<(FnSig, Option<String>)> {
        let mut keys: Vec<String> = Vec::new();
        keys.push(recv_class.to_string());
        let mut seen: HashSet<String> = HashSet::new();
        seen.insert(recv_class.to_string());
        let mut frontier: Vec<String> = vec![recv_class.to_string()];
        let mut steps = 0;
        while let Some(c) = frontier.pop() {
            if steps > 64 {
                break;
            }
            steps += 1;
            let Some(info) = self.classes.get(&c) else { continue };
            for s in &info.supertypes {
                if seen.insert(s.clone()) {
                    keys.push(s.clone());
                    frontier.push(s.clone());
                }
            }
        }
        keys.push("Any".to_string());
        for key in &keys {
            let Some(list) = self.extensions.get(key) else { continue };
            for ext in list {
                if ext.name != name {
                    continue;
                }
                let min = ext.sig.has_default.iter().filter(|h| !**h).count();
                let max = ext.sig.params.len();
                if args.len() < min || args.len() > max {
                    continue;
                }
                return Some((ext.sig.clone(), ext.return_class.clone()));
            }
        }
        None
    }

    /// Look up the effective visibility a class declares for a member.
    /// Walks the supertype chain so inherited members are seen with the
    /// declaring class's annotation. Returns `(visibility, declaring_class)`.
    fn lookup_member_visibility(
        &self,
        class: &str,
        name: &str,
    ) -> Option<(Visibility, String)> {
        let mut seen: HashSet<String> = HashSet::new();
        let mut frontier: Vec<String> = vec![class.to_string()];
        let mut steps = 0;
        while let Some(c) = frontier.pop() {
            if steps > 64 {
                break;
            }
            steps += 1;
            if !seen.insert(c.clone()) {
                continue;
            }
            let Some(info) = self.classes.get(&c) else { continue };
            if let Some(v) = info.member_visibility.get(name).copied() {
                return Some((v, c));
            }
            if info.members.contains_key(name) {
                return Some((Visibility::Public, c));
            }
            for s in &info.supertypes {
                frontier.push(s.clone());
            }
        }
        None
    }

    /// `protected` access through a receiver is allowed only when (a) the
    /// current enclosing class is the declaring class or a subclass, AND
    /// (b) the receiver's static class is the current enclosing class or
    /// a subclass of it. Matches kotlinc's qualified-access rule.
    fn protected_access_allowed(
        &self,
        declaring_class: &str,
        recv_class: Option<&str>,
    ) -> bool {
        let Some(enclosing) = self.class_stack.last() else { return false };
        let in_subclass = enclosing == declaring_class
            || self.is_subtype_of(enclosing, declaring_class);
        if !in_subclass {
            return false;
        }
        match recv_class {
            None => true,
            Some(rc) => {
                rc == enclosing.as_str()
                    || self.is_subtype_of(rc, enclosing)
                    || rc == declaring_class
                    || self.is_subtype_of(rc, declaring_class)
            }
        }
    }

    /// Emit T0031 when access at `member_span` to `name` on `declaring_class`
    /// is forbidden by visibility. `recv_class` is the receiver's static
    /// user-class when known, used for the `protected` qualified-access rule.
    fn check_member_visibility(
        &mut self,
        declaring_class: &str,
        name: &str,
        recv_class: Option<&str>,
        member_span: Span,
    ) {
        let Some((v, decl_class)) = self.lookup_member_visibility(declaring_class, name) else {
            return;
        };
        let allowed = match v {
            Visibility::Public | Visibility::Internal => true,
            Visibility::Private => {
                self.class_stack
                    .last()
                    .map(|c| c == &decl_class)
                    .unwrap_or(false)
            }
            Visibility::Protected => {
                self.protected_access_allowed(&decl_class, recv_class)
            }
        };
        if allowed {
            return;
        }
        let kind = match v {
            Visibility::Private => "private",
            Visibility::Protected => "protected",
            _ => "invisible",
        };
        self.diagnostics.emit(
            Diagnostic::error(
                format!(
                    "Cannot access `{name}`: it is {kind} in `{decl_class}`"
                ),
                member_span,
            )
            .with_code(codes::TYPE_INVISIBLE_MEMBER),
        );
    }

    /// Constructor / class-as-reference visibility. `private` top-level
    /// class is reachable only from inside its file; `protected` at the
    /// top level is illegal in Kotlin and we conservatively treat it the
    /// same as `private`.
    fn check_class_use_visibility(
        &mut self,
        name: &str,
        info: &ClassInfo,
        use_span: Span,
    ) {
        // Spec §4.6: a per-primary-ctor visibility (`class Foo private
        // constructor(...)`) gates constructor invocations independently of
        // the class visibility itself.
        let same_file = info
            .decl_file
            .map(|f| f == use_span.file)
            .unwrap_or(true);
        if let Some(pcv) = info.primary_ctor_visibility {
            if matches!(pcv, Visibility::Private) && !same_file {
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!("Cannot access `{name}`: primary constructor is private"),
                        use_span,
                    )
                    .with_code(codes::TYPE_INVISIBLE_MEMBER),
                );
                return;
            }
        }
        if matches!(info.decl_visibility, Visibility::Public | Visibility::Internal) {
            return;
        }
        match info.decl_visibility {
            Visibility::Private if same_file => return,
            Visibility::Protected => {
                if self.protected_access_allowed(name, None) {
                    return;
                }
            }
            _ => {}
        }
        let kind = match info.decl_visibility {
            Visibility::Private => "private",
            Visibility::Protected => "protected",
            _ => "invisible",
        };
        self.diagnostics.emit(
            Diagnostic::error(
                format!("Cannot access `{name}`: class is {kind}"),
                use_span,
            )
            .with_code(codes::TYPE_INVISIBLE_MEMBER),
        );
    }

    /// J6: when inside the body of a `public inline` function, references
    /// to an `internal` top-level declaration require `@PublishedApi`.
    fn check_published_api_use(
        &mut self,
        name: &str,
        visibility: Visibility,
        target_anns: &[klio_ast::Annotation],
        use_span: Span,
    ) {
        if !matches!(visibility, Visibility::Internal) {
            return;
        }
        if !self.public_inline_stack.last().copied().unwrap_or(false) {
            return;
        }
        if has_published_api(target_anns) {
            return;
        }
        self.diagnostics.emit(
            Diagnostic::error(
                format!(
                    "Cannot access `{name}` from a public inline function: it is `internal` and not annotated `@PublishedApi`"
                ),
                use_span,
            )
            .with_code(codes::TYPE_INVISIBLE_MEMBER),
        );
    }

    /// Emit T0031/T0032 when a bare-name reference resolves to a `private`
    /// top-level fn / property declared in another file. `decl_file` is the
    /// file of the declaration; `use_span` carries the access site's file.
    fn check_top_level_visibility(
        &mut self,
        name: &str,
        visibility: Visibility,
        decl_file: klio_span::FileId,
        use_span: Span,
    ) {
        if matches!(visibility, Visibility::Public | Visibility::Internal) {
            return;
        }
        // Top-level `protected` is illegal in Kotlin; until we surface a
        // dedicated diagnostic, treat it as `private` and gate by file.
        if use_span.file == decl_file {
            return;
        }
        self.diagnostics.emit(
            Diagnostic::error(
                format!(
                    "Cannot access `{name}`: it is private in its declaring file"
                ),
                use_span,
            )
            .with_code(codes::TYPE_INVISIBLE_REFERENCE),
        );
    }

    /// Walk a class's supertype chain looking for a member by simple name.
    /// Returns the declared `Type` plus the user-class name when the
    /// declared type names a user class (drives `expr_class` propagation
    /// through chains like `foo.bar.baz`).
    fn lookup_member_through_chain(
        &self,
        class: &str,
        name: &str,
    ) -> Option<(Type, Option<String>)> {
        let mut seen: HashSet<String> = HashSet::new();
        let mut frontier: Vec<String> = vec![class.to_string()];
        let mut steps = 0;
        while let Some(c) = frontier.pop() {
            if steps > 64 {
                break;
            }
            steps += 1;
            if !seen.insert(c.clone()) {
                continue;
            }
            let Some(info) = self.classes.get(&c) else { continue };
            if let Some(ty) = info.members.get(name) {
                let cn = info.member_class.get(name).cloned();
                return Some((ty.clone(), cn));
            }
            for s in &info.supertypes {
                frontier.push(s.clone());
            }
        }
        None
    }

    /// `a name b` (`is_infix == true`) must resolve to a function declared
    /// with the `infix` modifier. Walks top-level fns, the lhs's class
    /// members, and extension functions visible on the lhs's class chain;
    /// emits T0029 when no candidate has the modifier set.
    fn check_infix_modifier(&mut self, callee: &Expr, args: &[Expr], call_span: Span) {
        let Expr::Path { segments, .. } = callee else { return };
        if segments.len() != 1 {
            return;
        }
        let name = &segments[0].name;
        let mut found = false;
        let mut any = false;
        if let Some(sigs) = self.fns.get(name) {
            for s in sigs {
                any = true;
                if s.is_infix {
                    found = true;
                }
            }
        }
        if !found {
            if let Some(lhs) = args.first() {
                let lhs_class = self.expr_class.get(&lhs.span()).cloned();
                if let Some(cn) = lhs_class {
                    let mut seen: HashSet<String> = HashSet::new();
                    let mut frontier: Vec<String> = vec![cn.clone()];
                    let mut steps = 0;
                    while let Some(c) = frontier.pop() {
                        if steps > 64 {
                            break;
                        }
                        steps += 1;
                        if !seen.insert(c.clone()) {
                            continue;
                        }
                        if let Some(info) = self.classes.get(&c) {
                            if let Some(flags) = info.member_flags.get(name) {
                                any = true;
                                if flags.is_infix {
                                    found = true;
                                    break;
                                }
                            }
                            for s in &info.supertypes {
                                frontier.push(s.clone());
                            }
                        }
                    }
                    if !found {
                        let mut keys: Vec<String> = vec![cn.clone()];
                        let mut seen2: HashSet<String> = HashSet::new();
                        seen2.insert(cn.clone());
                        let mut f2: Vec<String> = vec![cn.clone()];
                        let mut steps2 = 0;
                        while let Some(c) = f2.pop() {
                            if steps2 > 64 {
                                break;
                            }
                            steps2 += 1;
                            if let Some(info) = self.classes.get(&c) {
                                for s in &info.supertypes {
                                    if seen2.insert(s.clone()) {
                                        keys.push(s.clone());
                                        f2.push(s.clone());
                                    }
                                }
                            }
                        }
                        keys.push("Any".to_string());
                        for key in &keys {
                            if let Some(list) = self.extensions.get(key) {
                                for ext in list {
                                    if ext.name == *name {
                                        any = true;
                                        if ext.sig.is_infix {
                                            found = true;
                                            break;
                                        }
                                    }
                                }
                            }
                            if found {
                                break;
                            }
                        }
                    }
                }
            }
        }
        if any && !found {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!("`{name}` is not declared with the `infix` modifier"),
                    call_span,
                )
                .with_code(codes::TYPE_INFIX_MODIFIER_REQUIRED),
            );
        }
    }

    fn check_call(
        &mut self,
        callee: &Expr,
        args: &[Expr],
        _arg_names: &[Option<String>],
        call_span: Span,
    ) -> Type {
        // Direct named-callable case: `foo(args)` where `foo` is a known
        // user fn or class. Otherwise fall back to tolerant typing.
        if let Expr::Path { segments, span: callee_span } = callee {
            if segments.len() == 1 {
                let name = &segments[0].name;
                if let Some(sigs) = self.fns.get(name).cloned() {
                    if let Some(entries) = self.fn_visibility.get(name).cloned() {
                        for (v, f) in entries {
                            self.check_top_level_visibility(name, v, f, *callee_span);
                        }
                    }
                    if let Some(entries) = self.fn_visibility.get(name).cloned() {
                        let anns_list = self.fn_annotations.get(name).cloned().unwrap_or_default();
                        for (i, (v, _)) in entries.iter().enumerate() {
                            let anns = anns_list.get(i).cloned().unwrap_or_default();
                            self.check_published_api_use(name, *v, &anns, *callee_span);
                        }
                    }
                    return self.check_overloaded_call(&sigs, args, callee.span());
                }
                if name == "listOf" || name == "mutableListOf" {
                    let mut acc: Option<Type> = None;
                    for a in args {
                        let t = self.check_expr(a, None);
                        acc = Some(match acc {
                            None => t,
                            Some(prev) => lub(&prev, &t),
                        });
                    }
                    let elem = acc.unwrap_or(Type::Unresolved);
                    self.list_elem.insert(call_span, elem);
                    let _ = callee_span;
                    return Type::Unresolved;
                }
                if let Some(cls) = self.classes.get(name).cloned() {
                    self.check_class_use_visibility(name, &cls, *callee_span);
                    if cls.has_secondary_ctors {
                        // Multiple constructor arities exist; the interp
                        // picks the matching one at runtime. Skip arity
                        // checking and just type each arg loosely.
                        for a in args {
                            self.check_expr(a, None);
                        }
                        return Type::Unresolved;
                    }
                    if let Some(sig) = cls.ctor.clone() {
                        self.check_arity_and_args(&sig, args, callee.span());
                    } else {
                        for a in args {
                            self.check_expr(a, None);
                        }
                    }
                    return Type::Unresolved;
                }
            }
        }
        // Stdlib chain methods on a `List<T>` seeded by `listOf` /
        // `mutableListOf` flow the element type through `map` / `filter` /
        // `fold` / `forEach` so the lambdas they take get a concrete
        // expected parameter type.
        if let Expr::Member { receiver, name, .. } = callee {
            let recv_ty = self.check_expr(receiver, None);
            let _ = recv_ty;
            if let Some(elem) = self.list_elem.get(&receiver.span()).cloned() {
                match name.name.as_str() {
                    "map" => {
                        if let Some(arg0) = args.first() {
                            let expect = Type::Function {
                                params: vec![elem.clone()],
                                return_type: Box::new(Type::Unresolved),
                            };
                            let ty = self.check_expr(arg0, Some(&expect));
                            let new_elem = match ty {
                                Type::Function { return_type, .. } => *return_type,
                                _ => Type::Unresolved,
                            };
                            self.list_elem.insert(call_span, new_elem);
                            return Type::Unresolved;
                        }
                    }
                    "filter" => {
                        if let Some(arg0) = args.first() {
                            let expect = Type::Function {
                                params: vec![elem.clone()],
                                return_type: Box::new(Type::Boolean),
                            };
                            let _ = self.check_expr(arg0, Some(&expect));
                            self.list_elem.insert(call_span, elem);
                            return Type::Unresolved;
                        }
                    }
                    "forEach" => {
                        if let Some(arg0) = args.first() {
                            let expect = Type::Function {
                                params: vec![elem.clone()],
                                return_type: Box::new(Type::Unit),
                            };
                            let _ = self.check_expr(arg0, Some(&expect));
                            return Type::Unit;
                        }
                    }
                    "fold" if args.len() >= 2 => {
                        let init_ty = self.check_expr(&args[0], None);
                        let expect = Type::Function {
                            params: vec![init_ty.clone(), elem.clone()],
                            return_type: Box::new(init_ty.clone()),
                        };
                        let _ = self.check_expr(&args[1], Some(&expect));
                        return init_ty;
                    }
                    _ => {}
                }
            }
            // Extension-function dispatch on a user class receiver. The
            // receiver was just typed above (its `expr_class` is now in
            // the map); walk the recv class chain looking for an
            // extension matching `name` and first-fit on arg types.
            if let Some(cn) = self.expr_class.get(&receiver.span()).cloned() {
                // Visibility check on member method calls. Runs before
                // extension fallback so a private member on the receiver's
                // class is flagged at the use site.
                if self.lookup_member_visibility(&cn, name.name.as_str()).is_some() {
                    self.check_member_visibility(&cn, name.name.as_str(), Some(&cn), name.span);
                }
                if let Some((sig, return_class)) =
                    self.lookup_extension(&cn, name.name.as_str(), args)
                {
                    if !sig.params.is_empty() {
                        let _ = self.check_overloaded_call(
                            std::slice::from_ref(&sig),
                            args,
                            call_span,
                        );
                    } else {
                        for a in args {
                            self.check_expr(a, None);
                        }
                    }
                    if let Some(cn) = return_class {
                        self.expr_class.insert(call_span, cn);
                    }
                    return sig.return_ty;
                }
            }
        }
        // Lambda value call: if callee has Function type, check params.
        let callee_ty = self.check_expr(callee, None);
        if let Type::Function { params, return_type } = callee_ty {
            if params.len() == args.len() {
                for (a, p) in args.iter().zip(params.iter()) {
                    let at = self.check_expr(a, Some(p));
                    self.check_assignable(&at, p, a.span());
                }
            } else {
                for a in args {
                    self.check_expr(a, None);
                }
            }
            return *return_type;
        }
        for a in args {
            self.check_expr(a, None);
        }
        Type::Unresolved
    }

    /// Picks an overload from `sigs` by first-fit on argument types and
    /// drives arity + assignability diagnostics against the chosen
    /// signature. Falls back to the first arity-matching signature when
    /// no candidate's parameter types are a clean fit, and to the first
    /// declared signature when even arity has no match.
    fn check_overloaded_call(
        &mut self,
        sigs: &[FnSig],
        args: &[Expr],
        call_span: Span,
    ) -> Type {
        if sigs.len() == 1 {
            self.check_arity_and_args(&sigs[0], args, call_span);
            return sigs[0].return_ty.clone();
        }
        // Pre-type each argument once; selection consults these types,
        // and assignability checks against the chosen signature reuse them
        // without re-evaluating.
        let arg_tys: Vec<Type> = args.iter().map(|a| self.check_expr(a, None)).collect();
        let mut chosen: Option<&FnSig> = None;
        let mut arity_match: Option<&FnSig> = None;
        let mut fitting: Vec<&FnSig> = Vec::new();
        for s in sigs {
            let min = s.has_default.iter().filter(|h| !**h).count();
            let max = s.params.len();
            if args.len() < min || args.len() > max {
                continue;
            }
            if arity_match.is_none() {
                arity_match = Some(s);
            }
            let fits = arg_tys
                .iter()
                .zip(s.params.iter())
                .all(|(a, p)| a.is_subtype_of(p));
            if fits {
                fitting.push(s);
            }
        }
        if !fitting.is_empty() {
            // Spec §3.5.1: when an integer literal fits multiple overloads,
            // prefer the one whose parameter has the narrower `Widen()` set.
            // Widen(Int) covers Short/Byte/Long, so a candidate taking `Int`
            // wins over one taking `Short` / `Byte` / `Long` for the same
            // literal. Apply per-parameter then sum to a score.
            let best = fitting
                .iter()
                .copied()
                .min_by_key(|s| widen_score(&s.params))
                .unwrap();
            chosen = Some(best);
        }
        let sig = chosen.or(arity_match).unwrap_or(&sigs[0]).clone();
        let min = sig.has_default.iter().filter(|h| !**h).count();
        let max = sig.params.len();
        if args.len() < min || args.len() > max {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!(
                        "Wrong number of arguments: expected {min}..{max}, got {}",
                        args.len()
                    ),
                    call_span,
                )
                .with_code(codes::TYPE_ARGUMENT_COUNT),
            );
        } else {
            for ((a, p), at) in args.iter().zip(sig.params.iter()).zip(arg_tys.iter()) {
                self.check_assignable(at, p, a.span());
            }
        }
        sig.return_ty
    }

    fn check_arity_and_args(&mut self, sig: &FnSig, args: &[Expr], call_span: Span) {
        let vararg_idx = sig.is_vararg.iter().position(|v| *v);
        // Spread arguments must land on a vararg parameter regardless of
        // arity. Emit T0047 up front so the diagnostic still fires when a
        // mis-spread also produces an arity mismatch.
        if vararg_idx.is_none() {
            for a in args {
                if let Expr::Spread { span, .. } = a {
                    self.diagnostics.emit(
                        Diagnostic::error(
                            "`*` spread argument requires a `vararg` parameter",
                            *span,
                        )
                        .with_code(codes::TYPE_SPREAD_REQUIRES_VARARG),
                    );
                }
            }
        }
        let min_args = sig
            .has_default
            .iter()
            .zip(sig.is_vararg.iter())
            .filter(|(h, v)| !**h && !**v)
            .count();
        let max_args = sig.params.len();
        let arity_ok = if vararg_idx.is_some() {
            args.len() >= min_args
        } else {
            args.len() >= min_args && args.len() <= max_args
        };
        if !arity_ok {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!(
                        "Wrong number of arguments: expected {min_args}..{max_args}, got {}",
                        args.len()
                    ),
                    call_span,
                )
                .with_code(codes::TYPE_ARGUMENT_COUNT),
            );
            for a in args {
                self.check_expr(a, None);
            }
            return;
        }
        // Per-arg typing. Spread args must land on a vararg parameter,
        // otherwise emit T0047.
        for (i, a) in args.iter().enumerate() {
            let is_spread = matches!(a, Expr::Spread { .. });
            // Map positional index i to a parameter slot. Past the vararg
            // index, every additional positional arg lands on the vararg.
            let target_param = match vararg_idx {
                Some(va_i) if i >= va_i => va_i,
                _ => i,
            };
            if is_spread {
                let is_va = sig.is_vararg.get(target_param).copied().unwrap_or(false);
                if !is_va {
                    self.diagnostics.emit(
                        Diagnostic::error(
                            "`*` spread argument requires a `vararg` parameter",
                            a.span(),
                        )
                        .with_code(codes::TYPE_SPREAD_REQUIRES_VARARG),
                    );
                }
                // Recurse into the spread expression for diagnostics.
                if let Expr::Spread { expr, .. } = a {
                    let spread_ty = self.check_expr(expr, None);
                    // §8.21.5: spread expression's element type must be a
                    // subtype of the vararg parameter's element type.
                    if is_va {
                        if let Some(param_elem) = sig.params.get(target_param) {
                            let spread_elem = array_element_type(&spread_ty).or_else(|| {
                                self.expr_class
                                    .get(&expr.span())
                                    .and_then(|cn| primitive_array_elem_by_name(cn))
                            });
                            if let Some(spread_elem) = spread_elem {
                                if !spread_elem.is_subtype_of(param_elem) {
                                    self.diagnostics.emit(
                                        Diagnostic::error(
                                            format!(
                                                "spread argument element type `{spread_elem}` is not a subtype of vararg parameter element type `{param_elem}`"
                                            ),
                                            expr.span(),
                                        )
                                        .with_code(codes::TYPE_SPREAD_TYPE_MISMATCH),
                                    );
                                }
                            }
                        }
                    }
                }
                continue;
            }
            let Some(p) = sig.params.get(target_param) else { continue };
            let at = self.check_expr(a, Some(p));
            if vararg_idx != Some(target_param) {
                self.check_assignable(&at, p, a.span());
            }
        }
        let _ = sig.param_names.len();
    }

    fn check_binary(&mut self, op: BinOp, lhs: &Expr, rhs: &Expr, span: Span) -> Type {
        let l = self.check_expr(lhs, None);
        let r = self.check_expr(rhs, None);
        // Spec §8.9.1 / §8.9.2: an equality between two definitely-distinct
        // types unrelated by subtyping is a compile-time error. Skip when
        // either side is `null` (the spec routes the null arm separately) or
        // when either side typed to `Unresolved` (we have no information).
        if matches!(op, BinOp::Eq | BinOp::Neq | BinOp::IdentEq | BinOp::IdentNeq)
            && !matches!(lhs, Expr::NullLit { .. })
            && !matches!(rhs, Expr::NullLit { .. })
            && !equality_types_compatible(&l, &r)
        {
            let (code, label) = if matches!(op, BinOp::IdentEq | BinOp::IdentNeq) {
                (
                    codes::TYPE_REFERENCE_EQUALITY_DISTINCT_TYPES,
                    "reference equality",
                )
            } else {
                (codes::TYPE_VALUE_EQUALITY_DISTINCT_TYPES, "equality")
            };
            self.diagnostics.emit(
                Diagnostic::error(
                    format!(
                        "{label} between `{}` and `{}` is impossible — types are unrelated",
                        type_label(&l),
                        type_label(&r),
                    ),
                    span,
                )
                .with_code(code),
            );
        }
        match op {
            BinOp::Add => {
                if matches!(l.non_null(), Type::String) || matches!(r.non_null(), Type::String) {
                    Type::String
                } else if is_numeric(&l) || is_numeric(&r) {
                    numeric_lub(&l, &r)
                } else {
                    Type::Unresolved
                }
            }
            BinOp::Sub | BinOp::Mul | BinOp::Div | BinOp::Rem => {
                if is_numeric(&l) || is_numeric(&r) {
                    numeric_lub(&l, &r)
                } else {
                    Type::Unresolved
                }
            }
            BinOp::Eq | BinOp::Neq | BinOp::IdentEq | BinOp::IdentNeq => Type::Boolean,
            BinOp::Lt | BinOp::Le | BinOp::Gt | BinOp::Ge => Type::Boolean,
            BinOp::In | BinOp::NotIn => Type::Boolean,
            BinOp::And | BinOp::Or => Type::Boolean,
            BinOp::Range | BinOp::RangeUntil => Type::Range(Box::new(numeric_lub(&l, &r))),
            BinOp::Elvis => {
                let lhs_non_null = match l {
                    Type::Nullable(inner) => *inner,
                    other => other,
                };
                lub(&lhs_non_null, &r)
            }
            BinOp::Assign => Type::Unit,
        }
    }

    fn check_lambda(&mut self, params: &[klio_ast::Ident], body: &Block, expected: Option<&Type>) -> Type {
        // Pull param types from expected function type, if it's one.
        let (param_tys, ret_expected): (Vec<Type>, Type) = match expected.map(Type::non_null) {
            Some(Type::Function { params: ps, return_type }) => {
                let ps = ps.clone();
                let r = (**return_type).clone();
                (ps, r)
            }
            _ => (
                std::iter::repeat(Type::Unresolved).take(params.len().max(1)).collect(),
                Type::Unresolved,
            ),
        };
        let saved = self.assigned.clone();
        self.push_frame();
        // `it` for zero-explicit-param lambdas.
        if params.is_empty() {
            self.current_frame().bindings.insert(
                "it".to_string(),
                Binding {
                    ty: param_tys.first().cloned().unwrap_or(Type::Unresolved),
                    mutable: false,
                    decl_span: None, class_name: None, needs_init: false },
            );
            self.assigned.insert("it".to_string());
        } else {
            for (i, p) in params.iter().enumerate() {
                self.current_frame().bindings.insert(
                    p.name.clone(),
                    Binding {
                        ty: param_tys.get(i).cloned().unwrap_or(Type::Unresolved),
                        mutable: false,
                        decl_span: Some(p.span), class_name: None, needs_init: false },
                );
                self.assigned.insert(p.name.clone());
            }
        }
        let actual_ret = self.check_block(body, Some(&ret_expected));
        self.pop_frame();
        self.assigned = saved;
        let return_type = if matches!(ret_expected, Type::Unresolved) {
            actual_ret
        } else {
            ret_expected
        };
        let params_out = if params.is_empty() {
            vec![param_tys.into_iter().next().unwrap_or(Type::Unresolved)]
        } else {
            params
                .iter()
                .enumerate()
                .map(|(i, _)| param_tys.get(i).cloned().unwrap_or(Type::Unresolved))
                .collect::<Vec<_>>()
        };
        Type::Function { params: params_out, return_type: Box::new(return_type) }
    }

    // ---- smart casts -----------------------------------------------------

    fn check_condition(&mut self, cond: &Expr) -> CondNarrow {
        let mut nar = CondNarrow::default();
        self.collect_narrowings(cond, true, &mut nar);
        self.check_expr(cond, Some(&Type::Boolean));
        nar
    }

    fn collect_narrowings(&self, cond: &Expr, positive: bool, out: &mut CondNarrow) {
        match cond {
            // `x != null` / `x == null`
            Expr::Binary { op: BinOp::Neq, lhs, rhs, .. }
            | Expr::Binary { op: BinOp::IdentNeq, lhs, rhs, .. } => {
                if let Some(name) = single_path_name(lhs) {
                    if matches!(**rhs, Expr::NullLit { .. }) {
                        let cur = self.lookup_narrowed(&name)
                            .or_else(|| self.lookup(&name).map(|b| b.ty.clone()))
                            .unwrap_or(Type::Unresolved);
                        let nn = match &cur {
                            Type::Nullable(i) => (**i).clone(),
                            other => other.clone(),
                        };
                        if positive {
                            out.true_branch.insert(name, nn);
                        } else {
                            out.false_branch.insert(name, cur);
                        }
                    }
                }
            }
            Expr::Binary { op: BinOp::Eq, lhs, rhs, .. }
            | Expr::Binary { op: BinOp::IdentEq, lhs, rhs, .. } => {
                if let Some(name) = single_path_name(lhs) {
                    if matches!(**rhs, Expr::NullLit { .. }) {
                        let cur = self
                            .lookup_narrowed(&name)
                            .or_else(|| self.lookup(&name).map(|b| b.ty.clone()))
                            .unwrap_or(Type::Unresolved);
                        let nn = match &cur {
                            Type::Nullable(i) => (**i).clone(),
                            other => other.clone(),
                        };
                        if positive {
                            // `x == null` true: x is null; no useful refinement.
                            let _ = nn;
                        } else {
                            out.false_branch.insert(name, nn);
                        }
                    }
                }
            }
            Expr::IsCheck { expr, ty, negated, .. } => {
                if let Some(key) = dot_path_key(expr) {
                    let target = convert_type_ref_lossy(ty);
                    let target_class = class_name_from_typeref(ty);
                    if positive ^ *negated {
                        out.true_branch.insert(key.clone(), target);
                        if let Some(cn) = target_class {
                            out.true_class.insert(key, cn);
                        }
                    } else {
                        // No good non-narrow.
                    }
                }
            }
            Expr::Binary { op: BinOp::And, lhs, rhs, .. } if positive => {
                self.collect_narrowings(lhs, true, out);
                self.collect_narrowings(rhs, true, out);
            }
            Expr::Binary { op: BinOp::Or, lhs, rhs, .. } if !positive => {
                self.collect_narrowings(lhs, false, out);
                self.collect_narrowings(rhs, false, out);
            }
            Expr::Unary { op: UnOp::Not, expr, .. } => {
                self.collect_narrowings(expr, !positive, out);
            }
            _ => {}
        }
    }

    // ---- assignability + diagnostics ------------------------------------

    fn check_assignable(&mut self, src: &Type, dst: &Type, span: Span) {
        if matches!(src, Type::Unresolved) || matches!(dst, Type::Unresolved) {
            return;
        }
        if src.is_subtype_of(dst) {
            return;
        }
        // Don't flag nullable-to-non-null here when src is `Nothing?` (the
        // type of literal `null`) against a nullable dst — already handled
        // by is_subtype_of via Nothing <: T <: T?. The remaining case is
        // assigning `T?` to `T`, which is a real error.
        self.diagnostics.emit(
            Diagnostic::error(
                format!("Type mismatch: inferred type is `{src}` but `{dst}` was expected"),
                span,
            )
            .with_code(codes::TYPE_MISMATCH),
        );
    }

    // ---- env helpers ----------------------------------------------------

    fn push_frame(&mut self) {
        self.frames.push(Frame::default());
    }

    fn pop_frame(&mut self) {
        self.frames.pop();
    }

    fn current_frame(&mut self) -> &mut Frame {
        self.frames.last_mut().expect("frame stack underflow")
    }

    fn lookup(&self, name: &str) -> Option<&Binding> {
        for f in self.frames.iter().rev() {
            if let Some(b) = f.bindings.get(name) {
                return Some(b);
            }
        }
        None
    }

    fn lookup_narrowed(&self, name: &str) -> Option<Type> {
        for f in self.frames.iter().rev() {
            if let Some(t) = f.narrowings.get(name) {
                return Some(t.clone());
            }
        }
        None
    }

    fn lookup_narrowed_class(&self, key: &str) -> Option<String> {
        for f in self.frames.iter().rev() {
            if let Some(cn) = f.narrowing_class.get(key) {
                return Some(cn.clone());
            }
        }
        None
    }

    #[allow(dead_code)]
    fn resolution(&self) -> &Resolution {
        self.resolution
    }

    // ---- sealed-`when` exhaustiveness ----------------------------------

    /// True iff `candidate` is the same class as `target` or a transitive
    /// subclass through the local class table.
    fn is_class_or_subclass(&self, candidate: &str, target: &str) -> bool {
        if candidate == target {
            return true;
        }
        self.is_subtype_of(candidate, target)
    }

    /// All concrete (non-abstract, non-interface, non-sealed) classes whose
    /// transitive supertype chain contains `root`. Used as the leaf set the
    /// branches must cover.
    fn sealed_leaf_subclasses(&self, root: &str) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        for (name, info) in &self.classes {
            if name == root {
                continue;
            }
            if info.is_interface {
                continue;
            }
            if !self.is_subtype_of(name, root) {
                continue;
            }
            // Treat sealed/abstract intermediates as non-leaves — their
            // concrete descendants are listed separately.
            if info.is_sealed || info.is_abstract {
                continue;
            }
            out.push(name.clone());
        }
        out.sort();
        out
    }

    fn check_when_exhaustive(
        &mut self,
        subject_class: &str,
        branches: &[WhenBranch],
        when_span: Span,
    ) {
        let Some(root_info) = self.classes.get(subject_class) else { return };
        if !root_info.is_sealed {
            return;
        }
        // Else branch trivially covers everything.
        for b in branches {
            for p in &b.patterns {
                if matches!(p.kind, WhenPatternKind::Else) {
                    return;
                }
            }
        }
        let leaves = self.sealed_leaf_subclasses(subject_class);
        if leaves.is_empty() {
            return;
        }
        let mut missing: Vec<String> = Vec::new();
        for leaf in &leaves {
            let mut covered = false;
            'b: for br in branches {
                for p in &br.patterns {
                    match &p.kind {
                        WhenPatternKind::IsType(t) => {
                            if self.is_class_or_subclass(leaf, &t.name.name) {
                                covered = true;
                                break 'b;
                            }
                        }
                        _ => {}
                    }
                }
            }
            if !covered {
                missing.push(leaf.clone());
            }
        }
        if !missing.is_empty() {
            let list = missing.join(", ");
            self.diagnostics.emit(
                Diagnostic::error(
                    format!(
                        "'when' expression must be exhaustive, add necessary 'is {}' branches or 'else' branch.",
                        if missing.len() == 1 { missing[0].clone() } else { list.clone() }
                    ),
                    when_span,
                )
                .with_code(codes::TYPE_WHEN_NOT_EXHAUSTIVE),
            );
        }
    }
}

/// Returns the user-class name a `TypeRef` refers to, ignoring nullability.
/// `None` for builtins, function types, and (for now) generic positions
/// where we'd lose precision.
/// Collect every named type reference appearing inside `t` (head name plus
/// every type-argument head, plus function-type receivers, params, and
/// return). Used by the typealias cycle detector to find every potential
/// alias name reachable from the target.
fn collect_aliased_names(t: &TypeRef, out: &mut Vec<String>) {
    if let Some(f) = &t.function {
        if let Some(r) = &f.receiver {
            collect_aliased_names(r, out);
        }
        for p in &f.params {
            collect_aliased_names(p, out);
        }
        collect_aliased_names(&f.ret, out);
    } else {
        out.push(t.name.name.clone());
    }
    for ta in &t.type_args {
        if !ta.is_star {
            collect_aliased_names(&ta.ty, out);
        }
    }
}

fn class_name_from_typeref(t: &TypeRef) -> Option<String> {
    if t.function.is_some() {
        return None;
    }
    if builtin_by_name(&t.name.name).is_some() {
        return None;
    }
    Some(t.name.name.clone())
}

#[derive(Debug, Default, Clone)]
struct CondNarrow {
    true_branch: HashMap<String, Type>,
    false_branch: HashMap<String, Type>,
    /// User-class names recorded alongside the narrowed `Type` so the
    /// branch-frame load can keep `expr_class` propagation alive for
    /// member chains that begin with a narrowed prefix.
    true_class: HashMap<String, String>,
    false_class: HashMap<String, String>,
}

/// Member names that always have a base in the built-in shape hierarchy
/// (`Any` / `Comparable` etc.) — we can't see those bases at type-check
/// time, so an `override` on a member of one of these names with no user
/// supertype-member match isn't necessarily wrong.
fn is_builtin_overridable(name: &str) -> bool {
    matches!(
        name,
        "toString"
            | "equals"
            | "hashCode"
            | "compareTo"
            | "iterator"
            | "next"
            | "hasNext"
            | "get"
            | "set"
            | "size"
            | "length"
    )
}

/// The eight actual Kotlin primitive types. `String` is NOT a primitive,
/// so `lateinit var s: String` remains legal.
fn is_primitive_type_name(name: &str) -> bool {
    matches!(
        name,
        "Int" | "Long" | "Short" | "Byte" | "Float" | "Double" | "Boolean" | "Char"
    )
}

fn is_const_capable_type_name(name: &str) -> bool {
    is_primitive_type_name(name) || name == "String"
}

fn accessor_uses_field(a: &Accessor) -> bool {
    match &a.body {
        FunctionBody::Block(b) => block_uses_field(b),
        FunctionBody::Expr(e) => expr_uses_field(e),
    }
}

fn block_uses_field(b: &Block) -> bool {
    b.stmts.iter().any(|s| match s {
        Stmt::Expr(e) => expr_uses_field(e),
        Stmt::Assign { target, value, .. } => expr_uses_field(target) || expr_uses_field(value),
        Stmt::Decl(Decl::Property(p)) => p.init.as_ref().map_or(false, expr_uses_field),
        _ => false,
    })
}

/// Walk `e` and record any bare-name path segment whose first identifier
/// maps to an entry in `by_name` (the set of top-level properties with
/// initializers). Used by the T0076 cycle detector.
fn collect_property_reads(
    e: &Expr,
    by_name: &std::collections::HashMap<String, usize>,
    out: &mut std::collections::HashSet<usize>,
) {
    match e {
        Expr::Path { segments, .. } => {
            if let Some(first) = segments.first() {
                if let Some(&idx) = by_name.get(&first.name) {
                    out.insert(idx);
                }
            }
        }
        Expr::Member { receiver, .. } => collect_property_reads(receiver, by_name, out),
        Expr::Call { callee, args, .. } => {
            collect_property_reads(callee, by_name, out);
            for a in args {
                collect_property_reads(a, by_name, out);
            }
        }
        Expr::Index { receiver, args, .. } => {
            collect_property_reads(receiver, by_name, out);
            for a in args {
                collect_property_reads(a, by_name, out);
            }
        }
        Expr::Binary { lhs, rhs, .. } => {
            collect_property_reads(lhs, by_name, out);
            collect_property_reads(rhs, by_name, out);
        }
        Expr::Unary { expr, .. } | Expr::Postfix { expr, .. } => {
            collect_property_reads(expr, by_name, out);
        }
        Expr::If { cond, then_branch, else_branch, .. } => {
            collect_property_reads(cond, by_name, out);
            collect_property_reads(then_branch, by_name, out);
            if let Some(eb) = else_branch {
                collect_property_reads(eb, by_name, out);
            }
        }
        Expr::When { subject, branches, .. } => {
            if let Some(s) = subject {
                collect_property_reads(s, by_name, out);
            }
            for b in branches {
                for p in &b.patterns {
                    match &p.kind {
                        klio_ast::WhenPatternKind::Value(e)
                        | klio_ast::WhenPatternKind::InRange(e)
                        | klio_ast::WhenPatternKind::NotInRange(e) => {
                            collect_property_reads(e, by_name, out);
                        }
                        _ => {}
                    }
                }
                collect_property_reads(&b.body, by_name, out);
            }
        }
        Expr::Labeled { expr, .. } => collect_property_reads(expr, by_name, out),
        Expr::Block(b) => {
            for s in &b.stmts {
                if let Stmt::Expr(e) = s {
                    collect_property_reads(e, by_name, out);
                }
            }
        }
        Expr::StringTemplate { parts, .. } => {
            for part in parts {
                match part {
                    klio_ast::StringPart::ShortInterp(id) => {
                        if let Some(&idx) = by_name.get(&id.name) {
                            out.insert(idx);
                        }
                    }
                    klio_ast::StringPart::Interp(e) => collect_property_reads(e, by_name, out),
                    klio_ast::StringPart::Text(_) => {}
                }
            }
        }
        Expr::Return { value: Some(v), .. } | Expr::Throw { value: v, .. } => {
            collect_property_reads(v, by_name, out);
        }
        Expr::IsCheck { expr, .. } | Expr::As { expr, .. } | Expr::Spread { expr, .. } => {
            collect_property_reads(expr, by_name, out);
        }
        _ => {}
    }
}

/// Spec §6.3: labels may only be attached to lambda literals, loop
/// statements, or a call whose trailing argument is a lambda literal.
/// Spec §7.1.2: does the LHS type carry a built-in or stdlib-shipped
/// matching `*Assign` operator function? This is the conservative
/// allowlist that the typeck consults to decide whether a compound
/// assignment to a `val`-bound name should be allowed. User classes that
/// declare their own `operator fun plusAssign` are accepted at runtime
/// through the interpreter's dispatch path; here we only need to greenlight
/// the well-known stdlib shapes so the canonical `val xs = mutableListOf(...);
/// xs += elem` form typechecks. Unresolved or wildcard types are accepted
/// to avoid cascading errors when generics aren't fully reconstructed.
fn type_has_compound_assign(ty: &Type, op: AssignOp) -> bool {
    if matches!(op, AssignOp::Assign) {
        return false;
    }
    // Be permissive when the static type is unknown — runtime can still
    // produce a precise error if no method exists.
    if matches!(ty, Type::Unresolved | Type::TypeParam(_)) {
        return true;
    }
    let head = match ty {
        Type::Generic { name, .. } => name.as_str(),
        Type::Nullable(inner) => return type_has_compound_assign(inner, op),
        _ => return false,
    };
    // Stdlib mutable collections accept `+=` / `-=`. Atomics accept the
    // same plus `*=` (timesAssign) via the kotlin.concurrent.atomics
    // extension surface. Conservative: only emit `true` for ops we know
    // are defined; primitives and immutable collections fall through.
    let allow_plus_minus = matches!(
        head,
        "MutableList"
            | "MutableSet"
            | "MutableMap"
            | "MutableCollection"
            | "MutableIterable"
            | "ArrayList"
            | "HashMap"
            | "HashSet"
            | "LinkedHashMap"
            | "LinkedHashSet"
            | "StringBuilder"
            | "AtomicInt"
            | "AtomicLong"
    );
    match op {
        AssignOp::Add | AssignOp::Sub => allow_plus_minus,
        _ => matches!(head, "AtomicInt" | "AtomicLong"),
    }
}

fn is_labelable_target(e: &Expr) -> bool {
    match e {
        Expr::Lambda { .. } => true,
        Expr::For { .. } | Expr::While { .. } | Expr::DoWhile { .. } => true,
        Expr::Call { args, .. } => matches!(args.last(), Some(Expr::Lambda { .. })),
        _ => false,
    }
}

fn expr_uses_field(e: &Expr) -> bool {
    match e {
        Expr::Path { segments, .. } => {
            segments.len() == 1 && segments[0].name == "field"
        }
        Expr::Block(b) => block_uses_field(b),
        Expr::If { cond, then_branch, else_branch, .. } => {
            expr_uses_field(cond)
                || expr_uses_field(then_branch)
                || else_branch.as_ref().map_or(false, |e| expr_uses_field(e))
        }
        Expr::When { subject, branches, .. } => {
            subject.as_ref().map_or(false, |s| expr_uses_field(s))
                || branches.iter().any(|b| expr_uses_field(&b.body))
        }
        Expr::Call { callee, args, .. } => {
            expr_uses_field(callee) || args.iter().any(expr_uses_field)
        }
        Expr::Member { receiver, .. } => expr_uses_field(receiver),
        Expr::Index { receiver, args, .. } => {
            expr_uses_field(receiver) || args.iter().any(expr_uses_field)
        }
        Expr::Binary { lhs, rhs, .. } => expr_uses_field(lhs) || expr_uses_field(rhs),
        Expr::Unary { expr, .. } => expr_uses_field(expr),
        Expr::Postfix { expr, .. } => expr_uses_field(expr),
        Expr::Return { value, .. } => value.as_ref().map_or(false, |e| expr_uses_field(e)),
        Expr::As { expr, .. } => expr_uses_field(expr),
        Expr::IsCheck { expr, .. } => expr_uses_field(expr),
        Expr::Spread { expr, .. } => expr_uses_field(expr),
        Expr::Labeled { expr, .. } => expr_uses_field(expr),
        _ => false,
    }
}

fn is_annotation_param_type(name: &str) -> bool {
    is_primitive_type_name(name)
        || matches!(
            name,
            "String" | "KClass" | "kotlin.reflect.KClass" | "Array"
        )
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PhaseFScope {
    TopLevel,
    Object,
    Class,
}

fn type_display(t: &Type) -> String {
    format!("{t}")
}

/// Dot-path identity for an `Expr`: returns `Some("a.b.c")` for `Path` /
/// `Member` chains over plain identifiers, `None` for anything containing
/// a call, index, safe-call, or non-identifier prefix. Used as the key
/// for smart-cast narrowings so a check like `n.shape is Circle`
/// narrows the same chain when it's read again.
fn dot_path_key(e: &Expr) -> Option<String> {
    match e {
        Expr::Path { segments, .. } if segments.len() == 1 => Some(segments[0].name.clone()),
        Expr::Member { receiver, name, safe, .. } if !*safe => {
            let lhs = dot_path_key(receiver)?;
            Some(format!("{lhs}.{}", name.name))
        }
        _ => None,
    }
}

fn single_path_name(e: &Expr) -> Option<String> {
    if let Expr::Path { segments, .. } = e {
        if segments.len() == 1 {
            return Some(segments[0].name.clone());
        }
    }
    None
}

/// Element type of a primitive-array class name (`IntArray` → `Int`).
fn primitive_array_elem_by_name(name: &str) -> Option<Type> {
    let short = name.strip_prefix("kotlin.").unwrap_or(name);
    match short {
        "IntArray" => Some(Type::Int),
        "LongArray" => Some(Type::Long),
        "ShortArray" => Some(Type::Short),
        "ByteArray" => Some(Type::Byte),
        "DoubleArray" => Some(Type::Double),
        "FloatArray" => Some(Type::Float),
        "BooleanArray" => Some(Type::Boolean),
        "CharArray" => Some(Type::Char),
        _ => None,
    }
}

/// Extract the element type of an array-shaped value type. Recognizes
/// `Array<T>`, the primitive `IntArray` / `LongArray` / … specializations,
/// and their nullable forms.
fn array_element_type(t: &Type) -> Option<Type> {
    let t = t.non_null();
    match t {
        Type::Generic { name, args } if name == "Array" => {
            args.first().filter(|a| !a.is_star).map(|a| a.ty.clone())
        }
        Type::Generic { name, .. } => match name.as_str() {
            "IntArray" => Some(Type::Int),
            "LongArray" => Some(Type::Long),
            "ShortArray" => Some(Type::Short),
            "ByteArray" => Some(Type::Byte),
            "DoubleArray" => Some(Type::Double),
            "FloatArray" => Some(Type::Float),
            "BooleanArray" => Some(Type::Boolean),
            "CharArray" => Some(Type::Char),
            _ => None,
        },
        _ => None,
    }
}

/// True if `a` and `b` are statically compatible enough that an equality
/// comparison is meaningful (one is a subtype of the other, both are
/// numeric, either is `Unresolved` / `Any` / `Nothing` / a type parameter,
/// or both are user classes whose relationship we cannot decide at typeck).
fn equality_types_compatible(a: &Type, b: &Type) -> bool {
    if matches!(a, Type::Unresolved) || matches!(b, Type::Unresolved) {
        return true;
    }
    if matches!(a, Type::Nothing) || matches!(b, Type::Nothing) {
        return true;
    }
    if matches!(a, Type::Any | Type::Nullable(_)) || matches!(b, Type::Any | Type::Nullable(_)) {
        // Comparing through a nullable / Any reference is always legal.
        if matches!(a.non_null(), Type::Any) || matches!(b.non_null(), Type::Any) {
            return true;
        }
    }
    // Type parameters and generics with unresolved bounds: stay permissive.
    if matches!(a, Type::TypeParam(_)) || matches!(b, Type::TypeParam(_)) {
        return true;
    }
    if a.is_subtype_of(b) || b.is_subtype_of(a) {
        return true;
    }
    // Both numeric: cross-type comparison is allowed (Kotlin's `Number`
    // equality compares mathematical values, `1 == 1L` is true).
    if is_numeric(a) && is_numeric(b) {
        return true;
    }
    // User-class generics where we cannot resolve subtyping precisely: be
    // permissive to avoid false positives on instances flowing through
    // `Type::Generic { name, .. }` whose hierarchy isn't known here.
    if matches!(a, Type::Generic { .. }) || matches!(b, Type::Generic { .. }) {
        return true;
    }
    false
}

fn type_label(t: &Type) -> String {
    format!("{t}")
}

fn is_numeric(t: &Type) -> bool {
    matches!(
        t.non_null(),
        Type::Int | Type::Long | Type::Short | Type::Byte | Type::Double | Type::Float
    )
}

fn numeric_rank(t: &Type) -> Option<u8> {
    Some(match t.non_null() {
        Type::Byte => 1,
        Type::Short => 2,
        Type::Int => 3,
        Type::Long => 4,
        Type::Float => 5,
        Type::Double => 6,
        _ => return None,
    })
}

fn numeric_lub(a: &Type, b: &Type) -> Type {
    match (numeric_rank(a), numeric_rank(b)) {
        (Some(ra), Some(rb)) => {
            let max_rank = ra.max(rb);
            let winner = if ra >= rb { a.non_null().clone() } else { b.non_null().clone() };
            // Byte/Short arithmetic promotes to Int (Kotlin spec).
            if max_rank <= 3 && matches!(winner, Type::Byte | Type::Short) {
                Type::Int
            } else {
                winner
            }
        }
        _ => Type::Unresolved,
    }
}

/// Least upper bound for if/when/try branch unification. Conservative: for
/// non-trivial class types we fall back to `Any`/`Any?`.
fn lub(a: &Type, b: &Type) -> Type {
    if matches!(a, Type::Unresolved) || matches!(b, Type::Unresolved) {
        return Type::Unresolved;
    }
    if a == b {
        return a.clone();
    }
    if matches!(a, Type::Nothing) {
        return b.clone();
    }
    if matches!(b, Type::Nothing) {
        return a.clone();
    }
    if a.is_subtype_of(b) {
        return b.clone();
    }
    if b.is_subtype_of(a) {
        return a.clone();
    }
    // Nullable promotion.
    if a.is_nullable() || b.is_nullable() {
        let na = match a {
            Type::Nullable(i) => (**i).clone(),
            other => other.clone(),
        };
        let nb = match b {
            Type::Nullable(i) => (**i).clone(),
            other => other.clone(),
        };
        return lub(&na, &nb).as_nullable();
    }
    if matches!(a, Type::Unit) || matches!(b, Type::Unit) {
        return Type::Unit;
    }
    if is_numeric(a) && is_numeric(b) {
        return numeric_lub(a, b);
    }
    Type::Any
}

/// Score a parameter list by Widen-rank — lower is more specific. Spec
/// §3.5.1: prefer `Int` over `Short`/`Byte`/`Long` and `Short` over `Byte`
/// when the same literal applies to both overloads. Non-integer types score
/// zero so overloads that don't mix integer parameters are unaffected.
fn widen_score(params: &[Type]) -> u32 {
    fn one(t: &Type) -> u32 {
        match t {
            Type::Int => 0,
            Type::Short => 1,
            Type::Long => 2,
            Type::Byte => 3,
            _ => 0,
        }
    }
    params.iter().map(one).sum()
}

// === Phase K tailrec analysis helpers ===

fn tailrec_is_self_call(callee: &Expr, fn_name: &str) -> bool {
    matches!(callee, Expr::Path { segments, .. }
        if segments.len() == 1 && segments[0].name == fn_name)
}

fn tailrec_walk_block(
    b: &Block,
    tail: bool,
    fn_name: &str,
    sites: &mut std::collections::HashSet<Span>,
) {
    let n = b.stmts.len();
    for (i, s) in b.stmts.iter().enumerate() {
        let is_last = i + 1 == n;
        let stmt_tail = tail && is_last;
        match s {
            Stmt::Expr(e) => tailrec_walk_expr(e, stmt_tail, fn_name, sites),
            Stmt::Decl(_) => {}
            Stmt::Assign { target, value, .. } => {
                tailrec_walk_expr(target, false, fn_name, sites);
                tailrec_walk_expr(value, false, fn_name, sites);
            }
            Stmt::DestructuringDecl { init, .. } => {
                tailrec_walk_expr(init, false, fn_name, sites);
            }
        }
    }
}

fn tailrec_walk_expr(
    e: &Expr,
    tail: bool,
    fn_name: &str,
    sites: &mut std::collections::HashSet<Span>,
) {
    match e {
        Expr::Call { callee, args, span, .. } => {
            if tail && tailrec_is_self_call(callee, fn_name) {
                sites.insert(*span);
            }
            tailrec_walk_expr(callee, false, fn_name, sites);
            for a in args {
                tailrec_walk_expr(a, false, fn_name, sites);
            }
        }
        Expr::If { cond, then_branch, else_branch, .. } => {
            tailrec_walk_expr(cond, false, fn_name, sites);
            tailrec_walk_expr(then_branch, tail, fn_name, sites);
            if let Some(eb) = else_branch {
                tailrec_walk_expr(eb, tail, fn_name, sites);
            }
        }
        Expr::When { subject, branches, .. } => {
            if let Some(s) = subject {
                tailrec_walk_expr(s, false, fn_name, sites);
            }
            for br in branches {
                for p in &br.patterns {
                    match &p.kind {
                        WhenPatternKind::Value(ex)
                        | WhenPatternKind::InRange(ex)
                        | WhenPatternKind::NotInRange(ex) => {
                            tailrec_walk_expr(ex, false, fn_name, sites);
                        }
                        _ => {}
                    }
                }
                tailrec_walk_expr(&br.body, tail, fn_name, sites);
            }
        }
        Expr::Block(b) => tailrec_walk_block(b, tail, fn_name, sites),
        Expr::Return { value, label, .. } => {
            let returns_to_self = match label {
                None => true,
                Some(l) => l.name == fn_name,
            };
            if let Some(v) = value {
                tailrec_walk_expr(v, returns_to_self, fn_name, sites);
            }
        }
        Expr::Labeled { expr, .. } => tailrec_walk_expr(expr, tail, fn_name, sites),
        Expr::Try { body, catches, finally, .. } => {
            tailrec_walk_block(body, false, fn_name, sites);
            for c in catches {
                tailrec_walk_block(&c.body, false, fn_name, sites);
            }
            if let Some(fb) = finally {
                tailrec_walk_block(fb, false, fn_name, sites);
            }
        }
        Expr::While { cond, body, .. } => {
            tailrec_walk_expr(cond, false, fn_name, sites);
            tailrec_walk_expr(body, false, fn_name, sites);
        }
        Expr::DoWhile { body, cond, .. } => {
            if let Some(b) = body {
                tailrec_walk_expr(b, false, fn_name, sites);
            }
            tailrec_walk_expr(cond, false, fn_name, sites);
        }
        Expr::For { iter, body, .. } => {
            tailrec_walk_expr(iter, false, fn_name, sites);
            tailrec_walk_expr(body, false, fn_name, sites);
        }
        Expr::Binary { lhs, rhs, .. } => {
            tailrec_walk_expr(lhs, false, fn_name, sites);
            tailrec_walk_expr(rhs, false, fn_name, sites);
        }
        Expr::Unary { expr, .. } | Expr::Postfix { expr, .. } => {
            tailrec_walk_expr(expr, false, fn_name, sites);
        }
        Expr::Member { receiver, .. } => tailrec_walk_expr(receiver, false, fn_name, sites),
        Expr::Index { receiver, args, .. } => {
            tailrec_walk_expr(receiver, false, fn_name, sites);
            for a in args {
                tailrec_walk_expr(a, false, fn_name, sites);
            }
        }
        Expr::Throw { value, .. } => tailrec_walk_expr(value, false, fn_name, sites),
        Expr::IsCheck { expr, .. } | Expr::As { expr, .. } => {
            tailrec_walk_expr(expr, false, fn_name, sites);
        }
        Expr::Spread { expr, .. } => tailrec_walk_expr(expr, false, fn_name, sites),
        Expr::Lambda { .. } | Expr::AnonFun { .. } | Expr::ObjectExpr { .. } => {}
        _ => {}
    }
}

fn tailrec_collect_all_block(b: &Block, fn_name: &str, out: &mut Vec<Span>) {
    for s in &b.stmts {
        match s {
            Stmt::Expr(e) => tailrec_collect_all_expr(e, fn_name, out),
            Stmt::Assign { target, value, .. } => {
                tailrec_collect_all_expr(target, fn_name, out);
                tailrec_collect_all_expr(value, fn_name, out);
            }
            Stmt::DestructuringDecl { init, .. } => {
                tailrec_collect_all_expr(init, fn_name, out);
            }
            Stmt::Decl(_) => {}
        }
    }
}

fn tailrec_collect_all_expr(e: &Expr, fn_name: &str, out: &mut Vec<Span>) {
    match e {
        Expr::Call { callee, args, span, .. } => {
            if tailrec_is_self_call(callee, fn_name) {
                out.push(*span);
            }
            tailrec_collect_all_expr(callee, fn_name, out);
            for a in args {
                tailrec_collect_all_expr(a, fn_name, out);
            }
        }
        Expr::If { cond, then_branch, else_branch, .. } => {
            tailrec_collect_all_expr(cond, fn_name, out);
            tailrec_collect_all_expr(then_branch, fn_name, out);
            if let Some(eb) = else_branch {
                tailrec_collect_all_expr(eb, fn_name, out);
            }
        }
        Expr::When { subject, branches, .. } => {
            if let Some(s) = subject {
                tailrec_collect_all_expr(s, fn_name, out);
            }
            for br in branches {
                for p in &br.patterns {
                    match &p.kind {
                        WhenPatternKind::Value(ex)
                        | WhenPatternKind::InRange(ex)
                        | WhenPatternKind::NotInRange(ex) => {
                            tailrec_collect_all_expr(ex, fn_name, out);
                        }
                        _ => {}
                    }
                }
                tailrec_collect_all_expr(&br.body, fn_name, out);
            }
        }
        Expr::Block(b) => tailrec_collect_all_block(b, fn_name, out),
        Expr::Return { value, .. } => {
            if let Some(v) = value {
                tailrec_collect_all_expr(v, fn_name, out);
            }
        }
        Expr::Labeled { expr, .. } => tailrec_collect_all_expr(expr, fn_name, out),
        Expr::Try { body, catches, finally, .. } => {
            tailrec_collect_all_block(body, fn_name, out);
            for c in catches {
                tailrec_collect_all_block(&c.body, fn_name, out);
            }
            if let Some(fb) = finally {
                tailrec_collect_all_block(fb, fn_name, out);
            }
        }
        Expr::While { cond, body, .. } => {
            tailrec_collect_all_expr(cond, fn_name, out);
            tailrec_collect_all_expr(body, fn_name, out);
        }
        Expr::DoWhile { body, cond, .. } => {
            if let Some(b) = body {
                tailrec_collect_all_expr(b, fn_name, out);
            }
            tailrec_collect_all_expr(cond, fn_name, out);
        }
        Expr::For { iter, body, .. } => {
            tailrec_collect_all_expr(iter, fn_name, out);
            tailrec_collect_all_expr(body, fn_name, out);
        }
        Expr::Binary { lhs, rhs, .. } => {
            tailrec_collect_all_expr(lhs, fn_name, out);
            tailrec_collect_all_expr(rhs, fn_name, out);
        }
        Expr::Unary { expr, .. } | Expr::Postfix { expr, .. } => {
            tailrec_collect_all_expr(expr, fn_name, out);
        }
        Expr::Member { receiver, .. } => tailrec_collect_all_expr(receiver, fn_name, out),
        Expr::Index { receiver, args, .. } => {
            tailrec_collect_all_expr(receiver, fn_name, out);
            for a in args {
                tailrec_collect_all_expr(a, fn_name, out);
            }
        }
        Expr::Throw { value, .. } => tailrec_collect_all_expr(value, fn_name, out),
        Expr::IsCheck { expr, .. } | Expr::As { expr, .. } => {
            tailrec_collect_all_expr(expr, fn_name, out);
        }
        Expr::Spread { expr, .. } => tailrec_collect_all_expr(expr, fn_name, out),
        Expr::Lambda { .. } | Expr::AnonFun { .. } | Expr::ObjectExpr { .. } => {}
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use klio_lexer::Lexer;
    use klio_parser::Parser;
    use klio_span::SourceMap;

    fn check_src(src: &str) -> TypeCheck {
        let mut map = SourceMap::new();
        let id = map.add("t.kt", src);
        let owned = map.get(id).source.clone();
        let toks = Lexer::new(id, &owned).tokenize();
        let (ast, _diags) = Parser::new(id, &owned, &toks.tokens).parse_file();
        let r = klio_resolver::resolve(&ast);
        typecheck(&ast, &r)
    }

    fn codes(tc: &TypeCheck) -> Vec<&'static str> {
        tc.diagnostics
            .diagnostics()
            .iter()
            .filter_map(|d| d.legacy_code)
            .collect()
    }

    #[test]
    fn literal_types() {
        let tc = check_src("fun main() { val x: Int = 1; val y: String = \"hi\" }");
        assert!(codes(&tc).is_empty(), "diags: {:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn literal_int_fits_long() {
        let tc = check_src("fun main() { val x: Long = 1 }");
        assert!(codes(&tc).is_empty(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn type_mismatch_literal() {
        let tc = check_src("fun main() { val x: Int = \"hi\" }");
        assert!(codes(&tc).contains(&codes::TYPE_MISMATCH));
    }

    #[test]
    fn val_reassign_flagged() {
        let tc = check_src("fun main() { val x = 1; x = 2 }");
        assert!(codes(&tc).contains(&codes::TYPE_VAL_REASSIGN));
    }

    #[test]
    fn var_reassign_ok() {
        let tc = check_src("fun main() { var x = 1; x = 2 }");
        assert!(!codes(&tc).contains(&codes::TYPE_VAL_REASSIGN));
    }

    #[test]
    fn null_deref_flagged() {
        let tc = check_src("fun main() { val s: String? = null; println(s.length) }");
        assert!(codes(&tc).contains(&codes::TYPE_NULL_SAFETY));
    }

    #[test]
    fn safe_call_on_nullable_ok() {
        let tc = check_src("fun main() { val s: String? = null; println(s?.length) }");
        assert!(!codes(&tc).contains(&codes::TYPE_NULL_SAFETY));
    }

    #[test]
    fn smart_cast_after_null_check() {
        let tc = check_src(
            "fun main() { val s: String? = null; if (s != null) { println(s.length) } }",
        );
        assert!(!codes(&tc).contains(&codes::TYPE_NULL_SAFETY), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn arity_mismatch_flagged() {
        let tc = check_src("fun f(a: Int) = a\nfun main() { f(1, 2) }");
        assert!(codes(&tc).contains(&codes::TYPE_ARGUMENT_COUNT));
    }

    #[test]
    fn wrong_arg_type_flagged() {
        let tc = check_src("fun f(s: String) {}\nfun main() { f(1) }");
        assert!(codes(&tc).contains(&codes::TYPE_MISMATCH));
    }

    #[test]
    fn if_lub_string_int_is_any() {
        let tc = check_src(
            "fun main() { val x: Any = if (true) \"hi\" else 1 }",
        );
        assert!(codes(&tc).is_empty(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn is_check_narrows_in_branch() {
        let tc = check_src(
            "fun main() { val a: Any = \"hi\"; if (a is String) { println(a.length) } }",
        );
        // No null-safety should fire; member-access on String is Unresolved
        // (we don't model String members) but that's silent.
        assert!(!codes(&tc).contains(&codes::TYPE_NULL_SAFETY));
    }

    #[test]
    fn binary_string_concat() {
        let tc = check_src("fun main() { val x: String = \"a\" + 1 }");
        assert!(codes(&tc).is_empty(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn user_class_call_type_checks() {
        let tc = check_src(
            r#"
            class Box(val x: Int)
            fun main() { val b = Box(3); println(b.x) }
            "#,
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn user_class_wrong_ctor_arg_type() {
        let tc = check_src(
            r#"
            class Box(val x: Int)
            fun main() { val b = Box("hi") }
            "#,
        );
        assert!(codes(&tc).contains(&codes::TYPE_MISMATCH));
    }

    #[test]
    fn lambda_param_types_from_expected() {
        // Without a known expected type the body uses Unresolved.
        let tc = check_src("fun main() { val f: (Int) -> Int = { x -> x + 1 }; println(f(2)) }");
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn abstract_member_not_implemented() {
        let tc = check_src(
            r#"
            abstract class Shape { abstract fun area(): Int }
            class Square : Shape()
            "#,
        );
        assert!(codes(&tc).contains(&codes::TYPE_ABSTRACT_MEMBER_NOT_IMPLEMENTED));
    }

    #[test]
    fn delegate_with_operator_modifier_ok() {
        let tc = check_src(
            r#"
            class D {
                operator fun getValue(thisRef: Any?, prop: Any?): Int = 1
                operator fun setValue(thisRef: Any?, prop: Any?, value: Int) {}
            }
            var x: Int by D()
            "#,
        );
        assert!(
            !codes(&tc).contains(&codes::TYPE_DELEGATE_OPERATOR_REQUIRED),
            "{:?}",
            tc.diagnostics.diagnostics()
        );
    }

    #[test]
    fn delegate_missing_operator_on_get_value_flagged() {
        let tc = check_src(
            r#"
            class D {
                fun getValue(thisRef: Any?, prop: Any?): Int = 1
            }
            val x: Int by D()
            "#,
        );
        assert!(codes(&tc).contains(&codes::TYPE_DELEGATE_OPERATOR_REQUIRED));
    }

    #[test]
    fn delegate_missing_operator_on_set_value_flagged() {
        let tc = check_src(
            r#"
            class D {
                operator fun getValue(thisRef: Any?, prop: Any?): Int = 1
                fun setValue(thisRef: Any?, prop: Any?, value: Int) {}
            }
            var x: Int by D()
            "#,
        );
        assert!(codes(&tc).contains(&codes::TYPE_DELEGATE_OPERATOR_REQUIRED));
    }

    #[test]
    fn diamond_conflict_flagged() {
        let tc = check_src(
            r#"
            interface A { fun hi(): String = "A" }
            interface B { fun hi(): String = "B" }
            class C : A, B
            fun main() { println(C().hi()) }
            "#,
        );
        assert!(codes(&tc).contains(&codes::TYPE_DIAMOND_CONFLICT));
    }

    #[test]
    fn diamond_conflict_resolved_by_override() {
        let tc = check_src(
            r#"
            interface A { fun hi(): String = "A" }
            interface B { fun hi(): String = "B" }
            class C : A, B { override fun hi(): String = "C" }
            fun main() { println(C().hi()) }
            "#,
        );
        assert!(!codes(&tc).contains(&codes::TYPE_DIAMOND_CONFLICT));
    }

    #[test]
    fn diamond_no_false_positive_for_linear_chain() {
        // Rectangle overrides Shape.area; Square inherits from Rectangle.
        // No diamond: Rectangle <: Shape, so Rectangle's default shadows.
        let tc = check_src(
            r#"
            open class Shape { open fun area(): Int = 0 }
            open class Rectangle : Shape() { override fun area(): Int = 1 }
            class Square : Rectangle()
            fun main() { println(Square().area()) }
            "#,
        );
        assert!(!codes(&tc).contains(&codes::TYPE_DIAMOND_CONFLICT));
    }

    #[test]
    fn lateinit_var_string_ok() {
        let tc = check_src(
            r#"
            class Box { lateinit var s: String }
            fun main() { println(Box()) }
            "#,
        );
        let cs = codes(&tc);
        assert!(!cs.contains(&codes::TYPE_LATEINIT_VAL));
        assert!(!cs.contains(&codes::TYPE_LATEINIT_PRIMITIVE));
        assert!(!cs.contains(&codes::TYPE_LATEINIT_WITH_INITIALIZER));
        assert!(!cs.contains(&codes::TYPE_LATEINIT_NULLABLE));
    }

    #[test]
    fn lateinit_val_flagged() {
        let tc = check_src(
            r#"
            class Box { lateinit val s: String }
            fun main() { println(Box()) }
            "#,
        );
        assert!(codes(&tc).contains(&codes::TYPE_LATEINIT_VAL));
    }

    #[test]
    fn lateinit_primitive_flagged() {
        let tc = check_src(
            r#"
            class Box { lateinit var n: Int }
            fun main() { println(Box()) }
            "#,
        );
        assert!(codes(&tc).contains(&codes::TYPE_LATEINIT_PRIMITIVE));
    }

    #[test]
    fn lateinit_initializer_flagged() {
        let tc = check_src(
            r#"
            class Box { lateinit var s: String = "x" }
            fun main() { println(Box()) }
            "#,
        );
        assert!(codes(&tc).contains(&codes::TYPE_LATEINIT_WITH_INITIALIZER));
    }

    #[test]
    fn lateinit_nullable_flagged() {
        let tc = check_src(
            r#"
            class Box { lateinit var s: String? }
            fun main() { println(Box()) }
            "#,
        );
        assert!(codes(&tc).contains(&codes::TYPE_LATEINIT_NULLABLE));
    }

    #[test]
    fn accessor_return_type_match_ok() {
        let tc = check_src(
            r#"
            class Box {
                val x: Int
                    get(): Int = 1
            }
            fun main() { println(Box().x) }
            "#,
        );
        assert!(!codes(&tc).contains(&codes::TYPE_ACCESSOR_RETURN_TYPE_MISMATCH));
    }

    #[test]
    fn accessor_return_type_mismatch_flagged() {
        let tc = check_src(
            r#"
            class Box {
                val x: Int
                    get(): String = "hi"
            }
            fun main() { println(Box().x) }
            "#,
        );
        assert!(codes(&tc).contains(&codes::TYPE_ACCESSOR_RETURN_TYPE_MISMATCH));
    }

    #[test]
    fn member_access_resolves_through_class_table() {
        let tc = check_src(
            r#"
            class Box(val n: Int)
            fun main() {
                val b = Box(3)
                val y: Int = b.n
            }
            "#,
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn member_access_chains_propagate_class() {
        let tc = check_src(
            r#"
            class Inner(val value: Int)
            class Outer(val inner: Inner)
            fun main() {
                val o = Outer(Inner(7))
                val n: Int = o.inner.value
            }
            "#,
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn extension_function_resolves_through_receiver_chain() {
        let tc = check_src(
            r#"
            open class Animal(val name: String)
            class Dog(n: String) : Animal(n)
            fun Animal.greet(): String = "hi " + this.name
            fun main() {
                val d = Dog("Rex")
                val g: String = d.greet()
                println(g)
            }
            "#,
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn stdlib_chain_infers_lambda_params_and_fold_result() {
        // The fold result is annotated as Int; the lambda parameters get
        // Int (init) and Int (elem). Without the M23 chain inference this
        // annotation would not match a fold whose return is Unresolved.
        let tc = check_src(
            r#"
            fun main() {
                val r: Int = listOf(1, 2, 3)
                    .map { it * 2 }
                    .filter { it > 0 }
                    .fold(0) { acc, x -> acc + x }
                println(r)
            }
            "#,
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn overload_picks_by_first_fit_arg_types() {
        let tc = check_src(
            r#"
            fun f(x: Int): Int = x
            fun f(x: String): String = x
            fun main() {
                val a: Int = f(1)
                val b: String = f("hi")
            }
            "#,
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn overload_picks_int_over_short_per_widen() {
        // Spec §3.5.1: integer literal `2` fits both `Int` and `Short`,
        // but Widen() makes Int the preferred candidate. The variable type
        // annotation forces the chosen return type to be observable.
        let tc = check_src(
            r#"
            fun f(x: Int): Int = x
            fun f(x: Short): Short = x
            fun main() {
                val a: Int = f(2)
            }
            "#,
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn overload_picks_int_over_long_per_widen() {
        let tc = check_src(
            r#"
            fun f(x: Int): Int = x
            fun f(x: Long): Long = x
            fun main() {
                val a: Int = f(2)
            }
            "#,
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn smart_cast_narrows_val_member_chain() {
        let tc = check_src(
            r#"
            open class Shape
            class Circle(val radius: Int) : Shape()
            class Wrapper(val shape: Shape)
            fun area(w: Wrapper): Int {
                if (w.shape is Circle) {
                    return w.shape.radius
                }
                return 0
            }
            "#,
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn member_access_inherits_from_supertype() {
        let tc = check_src(
            r#"
            open class Base(val tag: String)
            class Sub(t: String) : Base(t)
            fun main() {
                val s = Sub("hi")
                val t: String = s.tag
            }
            "#,
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }
}
