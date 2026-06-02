//! Tolerant static type checker.

pub(crate) use std::collections::{HashMap, HashSet};

pub(crate) use klio_ast::{
    Accessor, AssignOp, BinOp, Block, Class, CtorDelegation, Decl, EnumEntry, Expr,
    Function, FunctionBody, KotlinFile, ObjectDecl, Param, PostfixOp, Property,
    SecondaryCtor, Stmt, StringPart, TypeParam, TypeRef, UnOp, Visibility, WhenBranch,
    WhenPatternKind, WhereBound,
};
pub(crate) use klio_diagnostics::{Diagnostic, DiagnosticSink};
pub(crate) use klio_resolver::Resolution;
pub(crate) use klio_span::Span;
pub(crate) use klio_types::{builtin_by_name, convert_type_ref_lossy, GenericArg, Type, Variance};

/// Output of the type-checking pass.
#[derive(Debug)]
pub struct TypeCheck {
    /// Type assigned to each expression by its span. Statements have no
    /// entry. Spans not in this map were either skipped or assigned
    /// `Type::Unresolved`.
    pub types: HashMap<Span, Type>,
    pub diagnostics: DiagnosticSink,
    /// CFGs built during type checking, keyed by the source span of the
    /// owning function. Populated for every function body the checker
    /// visits. Consumers (notably the dataflow analyses in `klio-cfa`)
    /// read this to ground reachability / VIA / smart-cast queries
    /// during the M-CFA migration.
    pub cfgs: HashMap<Span, klio_cfa::Cfg>,
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
    klio_cfa::analyses::contracts::set_user_inline_contracts(scan_user_inline_contracts(file));
    let mut tc = Checker::new(resolution);
    tc.run(file);
    apply_suppress_annotations(file, &mut tc.diagnostics);
    klio_cfa::analyses::contracts::set_user_inline_contracts(std::collections::HashMap::new());
    TypeCheck {
        types: tc.types,
        diagnostics: tc.diagnostics,
        cfgs: tc.cfgs,
    }
}

/// Walk every top-level `inline fun` in `file` and record any
/// `contract { callsInPlace(p, InvocationKind.EXACTLY_ONCE) }`
/// declarations as a map of fn-simple-name → exactly-once param
/// names. Consumed by `klio-cfa`'s lowering to extend its
/// trailing-lambda inline scheme to user contracts so a `val`
/// assigned inside the lambda is observed as definitely assigned
/// at the call site.
fn scan_user_inline_contracts(
    file: &KotlinFile,
) -> std::collections::HashMap<String, Vec<String>> {
    use klio_ast::{Decl, Expr, FunctionBody, Stmt};
    let mut out: std::collections::HashMap<String, Vec<String>> =
        std::collections::HashMap::new();
    for d in &file.decls {
        let Decl::Function(f) = d else { continue };
        if !f.is_inline {
            continue;
        }
        let stmts: &[Stmt] = match &f.body {
            Some(FunctionBody::Block(b)) => &b.stmts,
            _ => continue,
        };
        let Some(first) = stmts.first() else { continue };
        let Stmt::Expr(Expr::Call { callee, args, .. }) = first else { continue };
        if !matches!(callee.as_ref(), Expr::Path { segments, .. } if segments.last().is_some_and(|s| s.name == "contract"))
        {
            continue;
        }
        let Some(Expr::Lambda { body, .. }) = args.last() else { continue };
        let mut once: Vec<String> = Vec::new();
        for s in &body.stmts {
            let Stmt::Expr(Expr::Call { callee, args, .. }) = s else { continue };
            if !matches!(callee.as_ref(), Expr::Path { segments, .. } if segments.last().is_some_and(|s| s.name == "callsInPlace"))
            {
                continue;
            }
            if args.len() < 2 {
                continue;
            }
            let Expr::Path { segments: target_segs, .. } = &args[0] else { continue };
            let Some(target_name) = target_segs.last().map(|s| s.name.clone()) else { continue };
            let kind_tail = match &args[1] {
                Expr::Path { segments, .. } => segments.last().map(|s| s.name.clone()),
                Expr::Member { name, .. } => Some(name.name.clone()),
                _ => None,
            };
            if kind_tail.as_deref() != Some("EXACTLY_ONCE") {
                continue;
            }
            once.push(target_name);
        }
        if !once.is_empty() {
            out.insert(f.name.name.clone(), once);
        }
    }
    out
}

/// Multi-file entry point. Synthesizes a merged `KotlinFile` whose decls
/// and imports are the concatenation of every input file's; per-decl
/// `Span::file` is preserved so cross-file visibility checks (T0032)
/// continue to work.
#[must_use]
pub fn typecheck_module(files: &[KotlinFile], resolution: &Resolution) -> TypeCheck {
    let merged = merge_module_files(files);
    typecheck(&merged, resolution)
}

fn merge_module_files(files: &[KotlinFile]) -> KotlinFile {
    let mut iter = files.iter();
    let Some(first) = iter.next() else {
        return KotlinFile {
            package: None,
            imports: Vec::new(),
            decls: Vec::new(),
            span: klio_span::Span { file: klio_span::FileId(0), start: 0, end: 0 },
        };
    };
    let mut out = first.clone();
    for f in iter {
        out.decls.extend(f.decls.iter().cloned());
        out.imports.extend(f.imports.iter().cloned());
    }
    out
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
    /// A function used at an operator-overloading dispatch site (`+ - * /
    /// % ..` / unary / `[]` / `++` / `--` / `in` / `invoke` / `iterator` /
    /// `componentN` / `provideDelegate` …) lacks the `operator` modifier.
    /// Spec ch.9: every convention call site requires `operator`. Emitted
    /// as a warning to stay parity-safe.
    pub const TYPE_OPERATOR_KEYWORD_MISSING: &str = "T0087";
    /// An `operator fun` declaration's signature does not match the shape
    /// required by its name (`inc`/`dec` take no args; `componentN` takes
    /// no args; `get` needs ≥1 arg; `set` needs ≥2 args; `compareTo`
    /// returns `Int`; `contains` returns `Boolean`; …). Spec ch.9.
    pub const TYPE_OPERATOR_SIGNATURE_MISMATCH: &str = "T0088";
    /// A call uses a named argument whose name matches no parameter of any
    /// candidate function in the overload set. Spec §11.2.6.
    pub const TYPE_NAMED_PARAMETER_NOT_FOUND: &str = "T0089";
    /// A call's overload set has no candidate whose arity and parameter
    /// types accept the supplied arguments. Spec §11.3.
    pub const TYPE_NONE_APPLICABLE: &str = "T0090";
    /// Multiple overload candidates remain equally specific after applying
    /// the MSC tiebreakers. Spec §11.4.
    pub const TYPE_OVERLOAD_RESOLUTION_AMBIGUITY: &str = "T0091";
    /// A call provides an explicit type-argument list (`f<T>(...)`) whose
    /// length does not match the type-parameter count of any candidate in
    /// the overload set. Spec §11.2.8.
    pub const TYPE_TYPE_ARGUMENT_COUNT_MISMATCH: &str = "T0092";
    /// `super.member` is ambiguous: multiple supertypes contribute a
    /// member with this name. Spec §11.2.2 "Call with an explicit
    /// super-form receiver" — basic super-form requires exactly one
    /// supertype to define the member; otherwise the caller must
    /// disambiguate with `super<TypeName>.member`.
    pub const TYPE_AMBIGUOUS_SUPER: &str = "T0093";
    /// Two callables declared in the same scope, on the same c-level
    /// partition, are "definitely interlinked" (spec §11.8): they always
    /// participate together in overload resolution. When the phantom
    /// call-site MSC procedure picks neither as more specific, the
    /// declaration pair is a compile-time conflict.
    pub const TYPE_CONFLICTING_OVERLOADS: &str = "T0094";
    /// Code emitted at a statement that the control-flow analysis has
    /// proven is dead — preceded by a `Nothing`-typed expression such as
    /// `return`, `throw`, `break`, `continue`, or a call to a function
    /// whose return type is `Nothing`. Spec §12.1.5.
    pub const WARN_UNREACHABLE_CODE: &str = "W0002";
    /// Code emitted at a comparison whose result is statically known
    /// from the flow-sensitive type of one side (e.g. `x == null` where
    /// `x` is proven non-null). Spec §12.
    pub const WARN_SENSELESS_COMPARISON: &str = "W0003";
    /// Code emitted at an `as T` whose subject is already proven to be
    /// of type `T` along this path. Spec §12.
    pub const WARN_USELESS_CAST: &str = "W0004";
    /// Code emitted at an elvis (`?:`) whose left side is proven
    /// non-null on this path. Spec §12.
    pub const WARN_USELESS_ELVIS: &str = "W0005";
    /// Write through a star-projected generic receiver where the RHS
    /// static type is not `Nothing`. Spec §13.2.1 bivariant rule.
    pub const TYPE_STAR_PROJECTION_WRITE: &str = "T0095";
    /// `where` clause forms a cycle through type-parameter bounds
    /// (e.g. `where T : U, U : T`). Spec §13.
    pub const TYPE_CIRCULAR_TYPE_BOUND: &str = "T0096";
    /// Constraint solver could not find a substitution for one or more
    /// inference variables at a call site. Spec §13.2.
    pub const TYPE_INFERENCE_FAILED: &str = "T0097";
    /// Constraint solver found multiple non-comparable substitutions
    /// at a call site with no optimal pick. Spec §13.2.
    pub const TYPE_INFERENCE_AMBIGUOUS: &str = "T0098";
    /// Constraint solver detected a circular dependency between
    /// inference variables that the staged resolver cannot break.
    pub const TYPE_INFERENCE_CYCLE: &str = "T0099";
    /// `x is T` (or `x !is T`) where `T` is a type parameter that is not
    /// `reified`. The runtime has no way to check membership of an erased
    /// type parameter. Spec §15.1: type checks require a runtime-available
    /// target type.
    pub const TYPE_CANNOT_CHECK_FOR_ERASED_TYPE_PARAMETER: &str = "T0100";
    /// `T?::class` — the LHS of a class literal cannot be a nullable
    /// type. Spec §15.1.
    pub const TYPE_NULLABLE_CLASS_LITERAL_LHS: &str = "T0101";
    /// `T::class` where `T` is a type parameter that is not `reified` (or
    /// is reified but has a nullable upper bound). Spec §15.1.
    pub const TYPE_NON_REIFIED_CLASS_LITERAL: &str = "T0102";
    /// `expr::class` where `expr` is neither a classifier name nor a
    /// value whose static type is a classifier / function type. Spec §15.
    pub const TYPE_CLASS_LITERAL_LHS_NOT_A_CLASS: &str = "T0103";
    /// `Foo<X>::class` — generic class literals must use the raw or
    /// star-projected form. Spec §15.1.
    pub const TYPE_CLASS_LITERAL_WITH_TYPE_ARGUMENTS: &str = "T0104";
    /// `catch (e: T)` where `T` is a type parameter that is not
    /// `reified`, or a generic exception type with non-star arguments.
    /// Spec §15.1: exception types in `catch` must be runtime-available.
    pub const TYPE_RUNTIME_UNAVAILABLE_CATCH_TYPE: &str = "T0105";
    /// `throw e` where `e`'s static type is not a subtype of
    /// `kotlin.Throwable`. Spec §16.2: only values of exception types may
    /// be thrown.
    pub const TYPE_THROW_NON_THROWABLE: &str = "T0106";
    /// Spec §17.1: annotation type cannot reference itself directly or
    /// transitively (via `Array<A>` or another annotation type).
    pub const TYPE_ANNOTATION_CYCLE: &str = "T0107";
    /// Spec §17.1: annotation-class primary-ctor parameter default values
    /// must be compile-time constant expressions of the allowed types.
    pub const TYPE_ANNOTATION_PARAM_DEFAULT_NOT_CONST: &str = "T0108";
    /// Spec §17.4: non-repeatable annotations cannot be applied to the
    /// same entity more than once.
    pub const TYPE_ANNOTATION_NOT_REPEATABLE: &str = "T0109";
    /// Spec §17.3: annotation application site does not match any of the
    /// declared `@Target` entries on the annotation class.
    pub const TYPE_ANNOTATION_TARGET_MISMATCH: &str = "T0110";
    /// Spec §17.5.5: use site references a declaration marked
    /// `@Deprecated(level = DeprecationLevel.ERROR)` or HIDDEN.
    pub const TYPE_DEPRECATED_ERROR: &str = "T0111";
    /// Spec §17.5.4: use site references a declaration marked
    /// `@RequiresOptIn(level = Level.ERROR)` without an enclosing `@OptIn`
    /// for the matching marker.
    pub const TYPE_OPT_IN_REQUIRED: &str = "T0112";
    /// Spec §17.5.9: member call resolves through a shadowed implicit
    /// receiver that belongs to the same DSL.
    pub const TYPE_DSL_SCOPE_VIOLATION: &str = "T0113";
    /// Spec §18.1: `suspend` modifier on a function shape that cannot be
    /// suspending — constructor, property accessor, anonymous function,
    /// or delegation operator (`getValue` / `setValue` / `provideDelegate`).
    pub const TYPE_SUSPEND_NOT_ALLOWED: &str = "T0114";
    /// Spec §18.1: a suspending function (or `suspend` lambda) is called
    /// from a non-suspending context.
    pub const TYPE_SUSPEND_CALL_FROM_NON_SUSPEND: &str = "T0115";
    /// Spec §18.1 / §5.4: an `override fun` disagrees with its overridden
    /// declaration on the `suspend` modifier.
    pub const TYPE_OVERRIDE_SUSPEND_MISMATCH: &str = "T0069";
    /// Spec §18.1 cross §4.1: assignment / argument-passing between a
    /// `suspend (…) -> R` and a non-suspending `(…) -> R` function type.
    pub const TYPE_SUSPEND_FUNCTION_TYPE_MISMATCH: &str = "T0116";
    /// Spec §7.1.2: a compound assignment `A op= B` resolves both
    /// `A.opAssign(B)` and `A = A.op(B)` — ambiguity. Kotlin requires the
    /// receiver type to provide at most one of the two for a given operator.
    pub const TYPE_ASSIGN_OPERATOR_AMBIGUITY: &str = "T0079";
    /// Spec §11.2.2: `super<Q>.member` where `Q` is not an immediate
    /// supertype of the enclosing class.
    pub const TYPE_SUPER_QUALIFIER_NOT_SUPERTYPE: &str = "T0073";
    /// Spec §7.1 note: assignments are statements, not expressions, and may
    /// not appear in expression contexts (`val y = (x = 1)`, `if (x = 1)`,
    /// `f(x = 1)` positional). Matches kotlinc-native
    /// `ASSIGNMENT_IN_EXPRESSION_CONTEXT`.
    pub const TYPE_ASSIGNMENT_IN_EXPRESSION_CONTEXT: &str = "T0117";
    /// Spec §17.5.5: WARNING level deprecation.
    pub const WARN_DEPRECATED: &str = "W0006";
    /// Spec §17.5.4: WARNING level opt-in.
    pub const WARN_OPT_IN: &str = "W0007";
}

/// A scope frame mapping local names to their declared/inferred types
/// and mutability. Frames stack lexically.
/// Symbol environment frame. The smart-cast / bound-alias data that
/// used to live here has moved to the CFG; the frame now only holds
/// the binding map.
#[derive(Debug, Default, Clone)]
pub(crate) struct Frame {
    bindings: HashMap<String, Binding>,
}

#[derive(Debug, Clone)]
pub(crate) struct Binding {
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
    /// Original declared-type name when the binding was annotated with a
    /// bare identifier (e.g. `t: T` for a type parameter). Lets
    /// runtime-availability checks recover the spelling that
    /// `convert_type_ref_lossy` collapsed to `Type::Unresolved`.
    decl_type_name: Option<String>,
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
pub(crate) struct ExtensionPropSig {
    name: String,
    ty: Type,
    #[allow(dead_code)]
    mutable: bool,
    return_class: Option<String>,
}

/// Description of a user-declared function, used to check call sites
/// when the callee resolves to a top-level function or a member.
#[derive(Debug, Clone)]
pub(crate) struct FnSig {
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
    /// Number of declaration-site type parameters. Used to filter the OCS
    /// against an explicit call-site `<...>` list. Spec §11.2.8.
    type_param_count: usize,
    /// Names of the declaration-site type parameters in order, matching
    /// `type_param_count`. Used by T0022 bound enforcement to look up
    /// `where`-bound substitutions.
    type_param_names: Vec<String>,
    /// Per-type-parameter upper bounds (inline `<T : B>` plus matching
    /// `where T : ...` clauses). Each inner Vec is the bound list for
    /// the corresponding type parameter, in declaration order. Empty when
    /// the parameter has no declared bound (implicit `Any?`).
    type_param_bounds: Vec<Vec<Type>>,
    /// User-class simple name for each parameter whose declared type names
    /// a known class. `None` for primitive / function / unresolved slots.
    /// Used by MSC's pairwise forwarding test (§11.4.2) to distinguish
    /// otherwise-collapsed `Type::Unresolved` slots.
    param_class_names: Vec<Option<String>>,
    /// Declaration-name span. `None` for synthetic / constructor sigs.
    /// Used by the §11.8 conflicting-overloads pass to attach diagnostics
    /// to the offending declaration sites.
    decl_span: Option<Span>,
    /// True when declared with the `suspend` modifier. Drives the §18.1
    /// function-colouring check at call sites.
    is_suspend: bool,
    /// True when the function is declared `inline` and the
    /// parameter at the same index is marked `crossinline`. Drives
    /// the call-site check that a lambda literal passed to a
    /// `crossinline` parameter contains no non-local `return`
    /// targeting the caller (T0056 — spec §4.2.5).
    is_crossinline_param: Vec<bool>,
}

/// Description of a user-declared class.
#[derive(Debug, Clone, Default)]
pub(crate) struct ClassInfo {
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
    /// Typed supertypes paired with type-arg lists, in declaration
    /// order. Each entry is `(supertype_name, [Type, Type, ...])`.
    /// Drives the GADT static refinement: when a smart-cast narrows
    /// a value of declared type `Super<T>` to a class whose typed
    /// supertypes include `Super<Int>`, the typechecker derives
    /// `T -> Int` for the branch body.
    typed_supertypes: Vec<(String, Vec<Type>)>,
    /// Type parameter names declared on this class. Parallel to
    /// `typed_supertypes` for substitution lookups.
    type_param_names: Vec<String>,
    is_abstract: bool,
    is_interface: bool,
    is_sealed: bool,
    #[allow(dead_code)]
    is_open: bool,
    /// `object` singleton — registered in `classes` so member lookup works
    /// but never inheritable and never instantiable.
    is_object: bool,
    /// `enum class` flag. Drives const-expression evaluation of
    /// enum-entry access at `const val` initializer sites (spec §8.2).
    is_enum: bool,
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
pub(crate) enum MemberSig {
    Function {
        #[allow(dead_code)]
        param_types: Vec<Type>,
        return_ty: Type,
        visibility: Visibility,
        is_suspend: bool,
    },
    Property {
        ty: Type,
        mutable: bool,
        visibility: Visibility,
    },
}

#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct MemberFlags {
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

pub(crate) struct Checker<'a> {
    resolution: &'a Resolution,
    types: HashMap<Span, Type>,
    /// User-class name attached to an expression by span — populated for
    /// path / `this` / constructor-call sites whose static type is a
    /// user-declared class. The plain `Type` enum collapses user classes
    /// to `Unresolved`, so this side map carries the identity that
    /// sealed-`when`, member access, and smart casts need.
    expr_class: HashMap<Span, String>,
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
    /// the J6 @`PublishedApi` visibility check: inside a public-inline body,
    /// references to `internal` declarations are forbidden unless the
    /// target carries `@PublishedApi`.
    public_inline_stack: Vec<bool>,
    /// Stack tracking whether each enclosing function / lambda is a
    /// suspending context. Spec §18.1: a suspending function may call
    /// other suspending functions; a non-suspending function may not.
    /// An inline lambda inherits its enclosing scope's suspending bit.
    suspend_context_stack: Vec<bool>,
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
    /// File-level set of `annotation class` simple names. Populated before
    /// Phase F so `check_annotation_class` can accept another annotation
    /// type as a primary-ctor parameter type per spec §17.1.
    annotation_class_names: HashSet<String>,
    /// File-level set of `enum class` simple names. Populated before
    /// Phase F so `check_annotation_class` can accept enum types as
    /// primary-ctor parameter types per spec §17.1.
    enum_class_names: HashSet<String>,
    /// Annotation-class names that are themselves marked `@DslMarker`.
    /// Spec §17.5.9: classes carrying any such annotation participate in
    /// the dsl-scope tower-shadowing check.
    dsl_marker_annotations: HashSet<String>,
    /// Class name → set of dsl-marker annotation names applied to that
    /// class.
    dsl_class_markers: HashMap<String, HashSet<String>>,
    /// Stack of currently-active implicit `this` receivers and their dsl
    /// markers. Pushed by `check_lambda_in_place` when a lambda binds
    /// `this` to a class-typed receiver.
    dsl_receiver_stack: Vec<(String, HashSet<String>)>,
    /// CFGs built during type checking, keyed by owning function span.
    /// Populated by `check_function` for every function body it visits;
    /// surfaced on the public [`TypeCheck`] output for downstream
    /// dataflow consumers.
    cfgs: HashMap<Span, klio_cfa::Cfg>,
    /// Full lowering output per function: CFG + side tables. The
    /// smart-cast / VIA / reachability queries need `span_to_pos` and
    /// aliases, which the CFG itself doesn't carry.
    lowerings: HashMap<Span, std::rc::Rc<klio_cfa::lower::Lowered>>,
    /// Stack of currently-active function spans so per-expression
    /// queries know which CFG to read.
    cfg_fn_stack: Vec<Span>,
    /// Active multi-call inference session, if any. When `Some`,
    /// a nested generic call defers its solve and contributes its
    /// fresh inference vars and bounds to this session; the root
    /// call solves and substitutes once.
    inference_session: Option<InferenceSession>,
    /// Set while typing a call whose callee is annotated
    /// `@BuilderInference`. The flag suppresses T0097 inference-
    /// failure diagnostics and lets the lambda body's calls drive
    /// type-parameter binding at runtime instead. Spec §14.
    builder_inference_active: bool,
}

/// Shared constraint system threaded through every generic call in a
/// single source-level expression. Replaces the per-call one-shot
/// solve when a call is nested inside another generic call's
/// arguments, so the outer call can incorporate constraints derived
/// from the inner one's return type before any variable is fixed.
struct InferenceSession {
    cs: klio_types::constraints::ConstraintSystem,
    /// True when a nested call is currently using the session.
    /// The outermost entry resets to `false` on exit and solves.
    depth: u32,
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

mod decl;
mod phases;
mod expr;
mod expr_calls;
mod visibility;
mod narrowing;
mod helpers;
mod annotations;

pub(crate) use helpers::*;
pub(crate) use annotations::*;

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
    fn smart_cast_after_unsafe_as() {
        let tc = check_src(
            "fun main() { val a: Any = \"hi\"; val s = a as String; println(a.length) }",
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn smart_cast_safe_as_does_not_narrow_subject() {
        // `a as? String` yields String? but does NOT narrow a — a may still be the original Any.
        let tc = check_src(
            "fun main() { val a: Any = \"hi\"; val s = a as? String; val x: Any = a }",
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn smart_cast_after_while_true_with_return() {
        // Spec §14.1.4: `while (true)` body is definitely entered, so
        // narrowings from an `if (a == null) return` inside propagate past
        // the loop.
        let tc = check_src(
            "fun f(a: String?): Int { while (true) { if (a == null) return -1; break }; return a.length }",
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn smart_cast_after_do_while() {
        let tc = check_src(
            "fun f(a: String?): Int { do { if (a == null) return -1 } while (false); return a.length }",
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn builder_call_typechecks() {
        // Spec §14.5: builder-style entry points typecheck through. Real
        // postponed-type-variable inference is not implemented; we just
        // ensure the surface call shape isn't a hard error.
        let tc = check_src("fun main() { val xs = buildList<Int> {} }");
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
        let tc = check_src("fun main() { val m = buildMap<String, Int> {} }");
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn bare_type_argument_inference_is_check() {
        // Spec §14.4: `x is List` / `x is Map` (no <T>) accepted; type
        // arguments are inferred to star projections.
        let tc = check_src(
            "fun f(x: Any) { if (x is List) {}; if (x is Map) {} }",
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn bare_type_argument_inference_user_generic() {
        let tc = check_src(
            "class Box<T>(val v: T); fun f(x: Any) { if (x is Box) {}; val y = x as Box }",
        );
        // The unsafe cast may emit an UNCHECKED_CAST warning, but no errors.
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn lambda_zero_arity_against_unit_callable() {
        // Spec §14.3.2 step 3: when the expected callable has zero params,
        // a zero-`->` lambda is treated as zero-arity (no phantom `it`),
        // and its body's non-Unit final expression is accepted under the
        // Unit-fallback rule (bullet 2 of step 5).
        let tc = check_src(
            "fun foreach(action: () -> Unit) {}; fun main() { foreach { 1 + 2 } }",
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn lambda_one_arity_with_it_against_one_arity_callable() {
        let tc = check_src(
            "fun action(a: (Int) -> Int): Int { return a(1) }; fun main() { action { it + 1 } }",
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn smart_cast_bound_alias_narrows_source() {
        // Spec §14.1.5: `val b = a; if (b is String) a.length`
        let tc = check_src(
            "fun f(a: Any): Int { val b = a; if (b is String) { return a.length }; return -1 }",
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn smart_cast_bound_alias_narrows_copy() {
        // The reverse: narrow the source, copy sees it.
        let tc = check_src(
            "fun f(a: Any): Int { val b = a; if (a is String) { return b.length }; return -1 }",
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn smart_cast_bound_alias_chain() {
        let tc = check_src(
            "fun f(a: Any): Int { val b = a; val c = b; if (a is String) { return c.length }; return -1 }",
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn smart_cast_after_not_is_return() {
        let tc = check_src(
            "fun f(x: Any): Int { if (x !is String) return -1; return x.length }",
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn smart_cast_not_is_else_branch() {
        let tc = check_src(
            "fun f(x: Any): Int = if (x !is String) -1 else x.length",
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn smart_cast_when_subject_is_branch() {
        let tc = check_src(
            "fun f(x: Any): Int = when (x) { is String -> x.length; else -> 0 }",
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn smart_cast_when_with_subject_binding() {
        // `when (val v = ...) { is T -> v.use }`
        let tc = check_src(
            "fun f(): Int = when (val v: Any = \"hi\") { is String -> v.length; else -> 0 }",
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn smart_cast_cross_variable_ref_eq() {
        let tc = check_src(
            "fun main() { val a: Any? = \"hi\"; val b: String = \"bye\"; if (a === b) { val x: String = a; } }",
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn smart_cast_cross_variable_ref_neq_in_else() {
        // `a !== b` is true on the then-branch → no narrowing there. On the
        // else, a and b must alias → narrow a to the narrower of the two.
        let tc = check_src(
            "fun main() { val a: Any? = \"x\"; val b: String = \"y\"; if (a !== b) {} else { val s: String = a } }",
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn smart_cast_after_elvis_return() {
        let tc = check_src(
            "fun greet(name: String?) { val n = name ?: return; println(name.length) }",
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn smart_cast_after_elvis_throw() {
        let tc = check_src(
            "fun greet(name: String?) { name ?: throw RuntimeException(\"x\"); println(name.length) }",
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn smart_cast_after_if_null_return() {
        let tc = check_src(
            "fun greet(name: String?) { if (name == null) return; println(name.length) }",
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn smart_cast_after_if_nonnull_else_return() {
        // when the else diverges, the true-branch narrowings survive past the if.
        let tc = check_src(
            "fun greet(name: String?) { if (name != null) {} else return; println(name.length) }",
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
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
            r"
            class Box(val x: Int)
            fun main() { val b = Box(3); println(b.x) }
            ",
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
            r"
            abstract class Shape { abstract fun area(): Int }
            class Square : Shape()
            ",
        );
        assert!(codes(&tc).contains(&codes::TYPE_ABSTRACT_MEMBER_NOT_IMPLEMENTED));
    }

    #[test]
    fn delegate_with_operator_modifier_ok() {
        let tc = check_src(
            r"
            class D {
                operator fun getValue(thisRef: Any?, prop: Any?): Int = 1
                operator fun setValue(thisRef: Any?, prop: Any?, value: Int) {}
            }
            var x: Int by D()
            ",
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
            r"
            class D {
                fun getValue(thisRef: Any?, prop: Any?): Int = 1
            }
            val x: Int by D()
            ",
        );
        assert!(codes(&tc).contains(&codes::TYPE_DELEGATE_OPERATOR_REQUIRED));
    }

    #[test]
    fn delegate_missing_operator_on_set_value_flagged() {
        let tc = check_src(
            r"
            class D {
                operator fun getValue(thisRef: Any?, prop: Any?): Int = 1
                fun setValue(thisRef: Any?, prop: Any?, value: Int) {}
            }
            var x: Int by D()
            ",
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
            r"
            open class Shape { open fun area(): Int = 0 }
            open class Rectangle : Shape() { override fun area(): Int = 1 }
            class Square : Rectangle()
            fun main() { println(Square().area()) }
            ",
        );
        assert!(!codes(&tc).contains(&codes::TYPE_DIAMOND_CONFLICT));
    }

    #[test]
    fn lateinit_var_string_ok() {
        let tc = check_src(
            r"
            class Box { lateinit var s: String }
            fun main() { println(Box()) }
            ",
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
            r"
            class Box { lateinit val s: String }
            fun main() { println(Box()) }
            ",
        );
        assert!(codes(&tc).contains(&codes::TYPE_LATEINIT_VAL));
    }

    #[test]
    fn lateinit_primitive_flagged() {
        let tc = check_src(
            r"
            class Box { lateinit var n: Int }
            fun main() { println(Box()) }
            ",
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
            r"
            class Box { lateinit var s: String? }
            fun main() { println(Box()) }
            ",
        );
        assert!(codes(&tc).contains(&codes::TYPE_LATEINIT_NULLABLE));
    }

    #[test]
    fn accessor_return_type_match_ok() {
        let tc = check_src(
            r"
            class Box {
                val x: Int
                    get(): Int = 1
            }
            fun main() { println(Box().x) }
            ",
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
            r"
            class Box(val n: Int)
            fun main() {
                val b = Box(3)
                val y: Int = b.n
            }
            ",
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn member_access_chains_propagate_class() {
        let tc = check_src(
            r"
            class Inner(val value: Int)
            class Outer(val inner: Inner)
            fun main() {
                val o = Outer(Inner(7))
                val n: Int = o.inner.value
            }
            ",
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
        // Int (init) and Int (elem). Without the stdlib chain
        // inference this annotation would not match a fold whose
        // return is Unresolved.
        let tc = check_src(
            r"
            fun main() {
                val r: Int = listOf(1, 2, 3)
                    .map { it * 2 }
                    .filter { it > 0 }
                    .fold(0) { acc, x -> acc + x }
                println(r)
            }
            ",
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
            r"
            fun f(x: Int): Int = x
            fun f(x: Short): Short = x
            fun main() {
                val a: Int = f(2)
            }
            ",
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn named_arg_picks_matching_overload() {
        // Spec §11.2.6: a named argument filters the OCS to candidates that
        // declare the name. Without filtering, the first-fit picker would
        // pick `f(x: Int)` since the literal `1` fits — but `name = "hi"`
        // matches only the second overload.
        let tc = check_src(
            r#"
            fun f(x: Int): Int = x
            fun f(name: String): String = name
            fun main() {
                val s: String = f(name = "hi")
            }
            "#,
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn named_arg_unknown_param_reports_t0089() {
        let tc = check_src(
            r"
            fun f(x: Int): Int = x
            fun f(y: Int): Int = y
            fun main() { val _r = f(z = 1) }
            ",
        );
        assert!(codes(&tc).contains(&codes::TYPE_NAMED_PARAMETER_NOT_FOUND));
    }

    #[test]
    fn type_arg_count_filters_overloads() {
        // Spec §11.2.8: `f<Int>(...)` filters OCS by exact tp-count.
        let tc = check_src(
            r"
            fun <T> f(x: T): T = x
            fun <T, U> f(x: T, y: U): T = x
            fun main() { val r: Int = f<Int>(1) }
            ",
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn msc_picks_more_specific_subtype() {
        // Spec §11.4.2: when one candidate's parameter is a subtype of
        // another's, the subtype wins. Here `Dog` is a subtype of `Animal`,
        // so the `Dog` overload is more specific.
        let tc = check_src(
            r#"
            open class Animal
            class Dog : Animal()
            fun f(a: Animal): Int = 1
            fun f(d: Dog): String = "dog"
            fun main() { val r: String = f(Dog()) }
            "#,
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn msc_non_parameterized_beats_parameterized() {
        // Spec §11.4.2 case 3 tiebreaker: a non-generic candidate wins
        // over a generic one when applicability is otherwise equal.
        let tc = check_src(
            r"
            fun f(x: Int): Int = x
            fun <T> f(x: T): Int = 0
            fun main() { val _r: Int = f(1) }
            ",
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn conflicting_overloads_reports_t0094() {
        // Spec §11.8: both functions accept the same fully-specified call
        // shape (one parameter, identical erased type), so any call site
        // would be ambiguous. Detect at declaration time.
        let tc = check_src(
            r"
            fun f(x: Int): Int = x
            fun f(y: Int): Int = y
            ",
        );
        assert!(codes(&tc).contains(&codes::TYPE_CONFLICTING_OVERLOADS));
    }

    #[test]
    fn distinct_overloads_no_conflict() {
        let tc = check_src(
            r"
            fun f(x: Int): Int = x
            fun f(x: String): String = x
            ",
        );
        assert!(!codes(&tc).contains(&codes::TYPE_CONFLICTING_OVERLOADS),
            "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn super_ambiguous_reports_t0093() {
        // Spec §11.2.2: both supertypes define `f`, basic `super.f` is
        // ambiguous; require `super<TypeName>.f`.
        let tc = check_src(
            r"
            interface A { fun f(): Int }
            interface B { fun f(): Int }
            class C : A, B {
                override fun f(): Int = super.f() + 1
            }
            ",
        );
        assert!(codes(&tc).contains(&codes::TYPE_AMBIGUOUS_SUPER));
    }

    #[test]
    fn super_qualified_unambiguous_ok() {
        let tc = check_src(
            r"
            interface A { fun f(): Int { return 1 } }
            interface B { fun f(): Int { return 2 } }
            class C : A, B {
                override fun f(): Int = super<A>.f() + super<B>.f()
            }
            ",
        );
        let cs = codes(&tc);
        assert!(!cs.contains(&codes::TYPE_AMBIGUOUS_SUPER), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn nothing_receiver_uses_extension_only() {
        // Spec §11.3.2: a receiver of type `Nothing` is not applicable
        // for any member callable; only extensions remain. Without the
        // class-chain walk firing on `Nothing`, the extension here must
        // resolve cleanly even though no class declares `describe()`.
        let tc = check_src(
            r#"
            fun Any?.describe(): String = "x"
            fun bottom(): Nothing = throw RuntimeException("x")
            fun main() {
                val s: String = bottom().describe()
                println(s)
            }
            "#,
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn msc_ambiguous_reports_t0091() {
        // Spec §11.4.2: both candidates are equally specific (sibling
        // unrelated types fit the literal `Any?` slot), no tiebreaker
        // distinguishes them, so emit T0091.
        let tc = check_src(
            r"
            class A
            class B
            fun f(a: A): Int = 1
            fun f(b: B): Int = 2
            fun g(x: Any): Int = 0
            fun main() { val _r: Int = g(1) ; val _s: Int = f(A()) }
            ",
        );
        // Sanity: the call to f(A()) above is unambiguous. We need an
        // actually-ambiguous pair. Force ambiguity via unrelated supers.
        let tc2 = check_src(
            r"
            interface I
            interface J
            class Both : I, J
            fun f(x: I): Int = 1
            fun f(x: J): Int = 2
            fun main() { val _r: Int = f(Both()) }
            ",
        );
        let _ = tc;
        assert!(codes(&tc2).contains(&codes::TYPE_OVERLOAD_RESOLUTION_AMBIGUITY),
            "{:?}", tc2.diagnostics.diagnostics());
    }

    #[test]
    fn expect_actual_pair_is_not_ambiguous() {
        // An `expect`/`actual` pair with an identical signature is one
        // logical function, not an overload set — resolving a call to
        // it must not report T0091 (regression: upstream
        // kotlinx.atomicfu `atomic(...)` was flagged `(T), (T)`).
        let tc = check_src(
            r"
            expect fun mk(x: Int): Int
            actual fun mk(x: Int): Int = x
            fun main() { val _r: Int = mk(1) }
            ",
        );
        assert!(
            !codes(&tc).contains(&codes::TYPE_OVERLOAD_RESOLUTION_AMBIGUITY),
            "expect/actual pair must not be ambiguous: {:?}",
            tc.diagnostics.diagnostics()
        );
    }

    #[test]
    fn msc_no_vararg_beats_vararg() {
        let tc = check_src(
            r"
            fun f(x: Int): Int = x
            fun f(vararg xs: Int): Int = 0
            fun main() { val _r: Int = f(1) }
            ",
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn none_applicable_reports_t0090() {
        // Spec §11.3: no candidate accepts 3 args.
        let tc = check_src(
            r"
            fun f(x: Int): Int = x
            fun f(x: Int, y: Int): Int = x + y
            fun main() { val _r = f(1, 2, 3) }
            ",
        );
        assert!(codes(&tc).contains(&codes::TYPE_NONE_APPLICABLE));
    }

    #[test]
    fn type_arg_count_mismatch_reports_t0092() {
        let tc = check_src(
            r"
            fun f(x: Int): Int = x
            fun main() { val _r = f<Int>(1) }
            ",
        );
        assert!(codes(&tc).contains(&codes::TYPE_TYPE_ARGUMENT_COUNT_MISMATCH));
    }

    #[test]
    fn overload_picks_int_over_long_per_widen() {
        let tc = check_src(
            r"
            fun f(x: Int): Int = x
            fun f(x: Long): Long = x
            fun main() {
                val a: Int = f(2)
            }
            ",
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn smart_cast_narrows_val_member_chain() {
        let tc = check_src(
            r"
            open class Shape
            class Circle(val radius: Int) : Shape()
            class Wrapper(val shape: Shape)
            fun area(w: Wrapper): Int {
                if (w.shape is Circle) {
                    return w.shape.radius
                }
                return 0
            }
            ",
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn unreachable_after_return() {
        let tc = check_src(
            r#"
            fun main() {
                return
                println("dead")
            }
            "#,
        );
        assert!(codes(&tc).contains(&codes::WARN_UNREACHABLE_CODE));
    }

    #[test]
    fn unreachable_after_throw() {
        let tc = check_src(
            r#"
            fun main() {
                throw RuntimeException("x")
                println("dead")
            }
            "#,
        );
        assert!(codes(&tc).contains(&codes::WARN_UNREACHABLE_CODE));
    }

    #[test]
    fn senseless_comparison_nonnull_eq_null() {
        let tc = check_src(
            r#"
            fun main() {
                val x: Int = 5
                if (x == null) { println("nope") }
            }
            "#,
        );
        assert!(codes(&tc).contains(&codes::WARN_SENSELESS_COMPARISON));
    }

    #[test]
    fn useless_cast_same_type() {
        let tc = check_src(
            r"
            fun main() {
                val x: Int = 5
                val y = x as Int
                println(y)
            }
            ",
        );
        assert!(codes(&tc).contains(&codes::WARN_USELESS_CAST));
    }

    #[test]
    fn useless_elvis_nonnull_lhs() {
        let tc = check_src(
            r"
            fun main() {
                val x: Int = 5
                val y = x ?: 0
                println(y)
            }
            ",
        );
        assert!(codes(&tc).contains(&codes::WARN_USELESS_ELVIS));
    }

    #[test]
    fn finally_return_makes_continuation_unreachable() {
        let tc = check_src(
            r#"
            fun main() {
                try {
                    println("try")
                } finally {
                    return
                }
                println("dead")
            }
            "#,
        );
        assert!(codes(&tc).contains(&codes::WARN_UNREACHABLE_CODE));
    }

    #[test]
    fn var_reassign_kills_narrowing() {
        let tc = check_src(
            r#"
            fun src(): String? = null
            fun main() {
                var x: String? = "ok"
                if (x != null) {
                    while (true) {
                        x = src()
                        println(x.length)
                    }
                }
            }
            "#,
        );
        assert!(codes(&tc).contains(&codes::TYPE_NULL_SAFETY));
    }

    #[test]
    fn class_val_property_uninit_in_init_block() {
        let tc = check_src(
            r"
            class Foo(b: Boolean) {
                val x: Int
                init {
                    if (b) { x = 1 }
                }
            }
            fun main() { println(Foo(true).x) }
            ",
        );
        assert!(codes(&tc).contains(&codes::TYPE_VAR_NOT_DEFINITELY_ASSIGNED));
    }

    #[test]
    fn class_val_property_initialized_in_all_init_branches() {
        let tc = check_src(
            r"
            class Foo(b: Boolean) {
                val x: Int
                init {
                    if (b) { x = 1 } else { x = 2 }
                }
            }
            fun main() { println(Foo(true).x) }
            ",
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn notnull_narrows_subject() {
        let tc = check_src(
            r#"
            fun main() {
                val s: String? = "hi"
                s!!
                val n: Int = s.length
                println(n)
            }
            "#,
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn as_cast_narrows_subject() {
        let tc = check_src(
            r#"
            fun main() {
                val a: Any = "hi"
                val s = a as String
                val n: Int = a.length
                println(s)
                println(n)
            }
            "#,
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn contract_run_initializes_val() {
        let tc = check_src(
            r"
            fun main() {
                val x: Int
                run { x = 4 }
                println(x)
            }
            ",
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn contract_check_introduces_smartcast() {
        let tc = check_src(
            r"
            fun main() {
                val x: Any = 42
                check(x is Int)
                val y: Int = x + 1
                println(y)
            }
            ",
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn contract_require_nonnull() {
        let tc = check_src(
            r#"
            fun f(s: String?): Int {
                require(s != null)
                return s.length
            }
            fun main() { println(f("hi")) }
            "#,
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn infer_call_return_propagates_arg_type() {
        // Spec §13: `id(5)` with `fun <T> id(x: T): T` should infer T = Int,
        // so the result is assignable to `Int`.
        let tc = check_src(
            r#"
            fun <T> id(x: T): T = x
            fun main() {
                val n: Int = id(5)
                val s: String = id("hi")
                println(n)
                println(s)
            }
            "#,
        );
        assert!(!tc.diagnostics.has_errors(), "{:?}", tc.diagnostics.diagnostics());
    }

    #[test]
    fn opt_in_marker_propagates() {
        let src = r"
            @RequiresOptIn
            annotation class Experimental

            @Experimental
            fun risky(): Int = 1

            fun unsafe(): Int = risky()

            @OptIn(Experimental::class)
            fun safe(): Int = risky()
        ";
        let tc = check_src(src);
        let cs = codes(&tc);
        let opt_in_errors = cs.iter().filter(|c| **c == codes::TYPE_OPT_IN_REQUIRED).count();
        assert_eq!(opt_in_errors, 1, "expected one T0112 for `unsafe`, got: {cs:?}");
    }

    #[test]
    fn suppress_silences_deprecation_warning() {
        // Without @Suppress the call site fires W0006; with it the
        // diagnostic is filtered out of the sink.
        let src_unsuppressed = r#"
            @Deprecated("gone")
            fun foo(): Int = 1
            fun caller(): Int = foo()
        "#;
        let tc = check_src(src_unsuppressed);
        assert!(codes(&tc).contains(&codes::WARN_DEPRECATED));
        let src_suppressed = r#"
            @Deprecated("gone")
            fun foo(): Int = 1
            @Suppress("W0006")
            fun caller(): Int = foo()
        "#;
        let tc = check_src(src_suppressed);
        assert!(!codes(&tc).contains(&codes::WARN_DEPRECATED));
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

    #[test]
    fn suspend_call_from_suspend_ok() {
        let tc = check_src(
            r"
            suspend fun a() {}
            suspend fun b() { a() }
            fun main() {}
            ",
        );
        let cs = codes(&tc);
        assert!(!cs.contains(&codes::TYPE_SUSPEND_CALL_FROM_NON_SUSPEND), "{cs:?}");
    }

    #[test]
    fn suspend_call_from_non_suspend_flagged() {
        let tc = check_src(
            r"
            suspend fun a() {}
            fun main() { a() }
            ",
        );
        assert!(codes(&tc).contains(&codes::TYPE_SUSPEND_CALL_FROM_NON_SUSPEND));
    }

    #[test]
    fn suspend_call_inside_anon_fun_marked_suspend() {
        // Spec §18.1: an anonymous-function expression with a `suspend`
        // function type still has no syntactic way to be marked suspending
        // today; ensure a non-suspending anon-fun body can NOT call
        // suspending functions. (Lambda-target carve-out for
        // `suspend (…) -> R` slots requires the `{…}` initializer to be
        // parsed as a lambda — tracked separately.)
        let tc = check_src(
            r"
            suspend fun a() {}
            fun outer() {
                val f = fun() { a() }
                f()
            }
            ",
        );
        assert!(codes(&tc).contains(&codes::TYPE_SUSPEND_CALL_FROM_NON_SUSPEND));
    }
}
