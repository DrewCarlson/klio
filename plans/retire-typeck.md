# Retiring the old checker

`klio check` still runs the resolver and the type checker (`src/resolver`,
`src/typeck`, with `src/cfa` and `src/types` under them); `klio run` runs
sema. This plan moves every diagnostic the old checker reports that kotlinc
also reports into sema, switches `klio check` to sema, and deletes the old
checker (about 29k lines).

The old checker is not the oracle: it reports errors in 211 of the 673
examples, which run and which kotlinc accepts. Every check is judged against
kotlinc 2.4.20 (the pinned dist in the main checkout's `target/parity-cache`).

## Rules the diff enforces

Per input and per line, over `examples/`, `tests/fixtures/typeck_negative`,
`tests/fixtures/*.kt`, the itests' inline diagnostic cases, the packs' own
sources and the box corpus's valid files:

1. Every old diagnostic that kotlinc also reports at that line has a sema
   diagnostic there with kotlinc's factory.
2. An old diagnostic may disappear only where kotlinc accepts the line.
3. Every sema diagnostic matches a kotlinc one.
4. The severity is kotlinc's.

## Tools

- `klio check --engine sema`: the files analyzed as `klio run` analyzes
  them, with kotlinc's factory names as codes (`--format json` for tools).
- `scripts/sema-oracle.sh --diagnostics FILE...`: kotlinc's diagnostics.
  From a worktree set `SEMA_ORACLE_KOTLINC` to the main checkout's
  `target/parity-cache/kotlinc-2.4.20`. Probing kotlinc with a small file is
  how every rule below was settled; do that before writing a check.
- `scripts/check-diff.py`: both engines and kotlinc over the inputs, the four
  rules, per category. `--save DIR` keeps each side; `--old`, `--sema`,
  `--kotlinc` reuse one (the old side is 20 minutes, the sema side about 30 on
  a fresh binary, which bakes each compose base image once).
- `KLIO_CHECK_PACKS=1` (docs/development/debugging.md): the declaration,
  annotation and use checks also run over the installed packs' sources, which
  kotlinc compiled, so a finding there is a false positive or klio-authored
  code kotlinc would refuse. Run `klio sema --bodies all` over a probe that
  imports the pack, as `scripts/sema-census.py` does. `use` findings there are
  noise: the packs build with module `-opt-in` flags and `@file:Suppress`.

## Where the code is

- `src/sema/census.zig`: a site's severity (warnings are kept apart and never
  counted), `Factory` (every name sema reports; a cli test holds each to a
  factory kotlinc or klio declares), related places, notes.
- `src/sema/suppress.zig`: `@Suppress` regions.
- `src/cli/sema_diagnostics.zig`: sites to `Diagnostic`s; no warning is shown
  when there is an error.
- `src/sema/declcheck.zig` (B1), `src/sema/annocheck.zig` and
  `src/sema/usecheck.zig` (B2): run from `body.resolveAll` after the
  program's bodies.

## Order and status

A. Infrastructure. Done: census severities and factory names, `@Suppress`,
`klio check --engine sema`, the oracle's `--diagnostics`, `check-diff.py`.

B. Port the missing checks by category, errors before warnings, with sema
unit tests; `typeck_negative` is the acceptance list.

- B1. Declarations, modifiers and overrides. Done (`declcheck.zig`):
  modifiers that exclude each other or do not apply; data, value and enum
  classes; supertypes (final, an object, sealed from a local class, `by` to a
  class, uninitialized, a generic `Throwable`); `lateinit`, `const`,
  extension, inline and explicit-backing-field properties; reified,
  `crossinline`, `noinline`, vararg parameters; overrides (nothing, final,
  visibility, return and property type, `var` by `val`, `suspend`);
  unimplemented abstract members and members several supertypes implement;
  operator and infix shapes, and `OPERATOR_MODIFIER_REQUIRED` /
  `INFIX_MODIFIER_REQUIRED` at the call; constructor cycles; an escaping
  object expression's type; a vararg of a value class without
  `FullValueClasses` (`FORBIDDEN_VARARG_PARAMETER_TYPE`). Warnings `NOTHING_TO_INLINE`,
  `PARAMETER_NAME_CHANGED_ON_OVERRIDE`, `REDUNDANT_EXPLICIT_BACKING_FIELD`.
- B2. Annotations, targets, opt-in and deprecation. Partly done:
  - done: annotation class shape (members, parameter types, `val`, constant
    defaults, cycles), `REPEATED_ANNOTATION`, `DEPRECATION`,
    `DEPRECATION_ERROR` (with `@DeprecatedSinceKotlin` against 2.4) at calls,
    reads, constructors and header types, `OVERRIDE_DEPRECATION`;
  - done (`annocheck.targets`): `WRONG_ANNOTATION_TARGET` where an
    annotation's class does not admit its place: a classifier (named as
    kotlinc names it: class, interface, enum class, standalone or
    companion object, local class, annotation class), a function (top
    level, member, local), a property (with a backing field it admits
    `FIELD` too; kotlinc names whether it has one or a delegate), a getter
    or setter, a value parameter (a `val` one admits `PROPERTY` and
    `FIELD`), a constructor, an enum entry, a type alias, a type parameter,
    a local variable, a lambda (`FUNCTION` or `EXPRESSION`), a type usage,
    a file; `WRONG_ANNOTATION_TARGET_WITH_USE_SITE_TARGET` for a use-site
    target (`@get:`, `@field:`, `@file:`, ...) its class does not admit;
    `RESTRICTED_RETENTION_FOR_EXPRESSION_ANNOTATION_ERROR` for an
    `EXPRESSION` annotation class not kept `SOURCE`. A class's targets are
    its `@Target`'s or the default set.
  - not done: the targets of an annotation class read from an
    image, whose `@Target` is not baked; the `@all:` expansion
    (`ast.annotation_targets`, the 13 diagnostic rows of the
    `annotation_targets` itest); `ANNOTATION_ARGUMENT_MUST_BE_CONST`;
  - done (`optin.zig`): opt-in. A `@RequiresOptIn` class is a marker at
    its level (`ERROR` unless it says `WARNING`; the base's are baked into
    its image, format 110). A use is reported where the used declaration
    carries a marker (a constructor its class's; `EC.make()` names the
    class of the companion it reaches) or where it gives a value whose
    class carries one (`e` read as an `EC`, a call returning one), and a
    header type naming a marked class: `OPT_IN_USAGE_ERROR`, or
    `OPT_IN_USAGE` for a warning marker, naming the marker by its qualified
    name. A member of a marked class is not reported itself: its receiver
    is (kotlinc reports `e` in `e.m()`, and nothing more in `EC().m()`). A
    use opts in under a declaration, a file (`@file:OptIn`) or an
    expression annotated with the marker or `@OptIn(M::class)` (qualified
    names too), and everywhere under `--opt-in=` (kotlinc's `-opt-in`; the
    box runner passes its `OPT_IN` directive). An override of a marked
    member is `OPT_IN_OVERRIDE_ERROR` / `OPT_IN_OVERRIDE`. Code a compiler
    plugin adds is exempt (a node numbered from the file's
    `parsed_node_count` on: the serialization pass's splices), as are
    packs' sources, which their builds opt in by compiler flag. Two
    examples used marked library API without the opt-in kotlinc requires
    (`InstantComponentSerializer` is `@ExperimentalTime`,
    `buildSerialDescriptor` `@InternalSerializationApi`) and now opt in;
    `kotlin.time.Instant` itself is stable in 2.4.
  - annotations on an expression are kept (`KotlinFile.annotated_exprs`,
    the whole postfix expression they stand on) for these checks: an
    `@OptIn` there opts the expression in, and its targets are checked
    (`EXPRESSION`; an anonymous function's admits `FUNCTION` too).
- B3. Visibility and names, context parameters. Partly done:
  `RECURSIVE_TYPEALIAS_EXPANSION` (an alias whose expansion reaches it
  again, every alias of the cycle at its target; one that only names a
  cyclic alias is not reported) and `DSL_SCOPE_VIOLATION` (a call, read or
  operator reaching an implicit receiver when a closer one carries one of
  its `@DslMarker` annotations, on its class or a supertype; checked as
  the reference is recorded, cheaply when the receiver used is the
  innermost); `NOT_A_SUPERTYPE` for `super<X>` naming a class that is not
  a direct supertype (`Any` is not, when the class names only interfaces);
  `NOT_A_LOOP_LABEL` for a labeled `break` or `continue` no enclosing loop
  carries, and `BREAK_OR_CONTINUE_JUMPS_ACROSS_FUNCTION_BOUNDARY` for one
  whose loop is outside a function, class or lambda that is not inlined (a
  lambda or anonymous function passed to an inline function is). Not done:
  the marker written on a function type's receiver (`fun q(b: @M Q.() ->
  Unit)`), which needs the annotation carried on the lambda's receiver
  type. Done too: an extension property's accessor has no `field`
  (`UNRESOLVED_REFERENCE`).
- B4. Types. Partly done:
  - done (`body.checkFits`): a value against the type its place declares,
    `INITIALIZER_TYPE_MISMATCH` (property, local, parameter default,
    name-based destructuring entry), `RETURN_TYPE_MISMATCH` (`return`,
    expression body, getter, a lambda's last expression when the call does
    not infer its result), `ASSIGNMENT_TYPE_MISMATCH`, `TYPE_MISMATCH`
    (`throw`, `by` delegation), `WRONG_GETTER_RETURN_TYPE`,
    `COMPONENT_FUNCTION_RETURN_TYPE_MISMATCH`. `klio run` refuses these as
    kotlinc does. They needed sema to infer as K2 does: integer literal
    operators (`+ - * / %`, `shl shr ushr and or xor inv`, unary minus and
    plus) give `Int` or `Long`, computed in `Int` and widened; a `var`
    initialized from a smart-cast value takes the declared type; a Boolean
    `val` holding a condition smart-casts where it is tested; a `while` or
    `do-while` without a `break` leaves its condition false; `===` and `!==`
    narrow to the other side's type unless that side is a constant; a
    destructured entry with a written type takes it.
  - the checks judge only known types: a type still being inferred, an error
    type, or one naming a type parameter no enclosing declaration declares
    (sema left a generic declaration's type uninstantiated) says nothing.
    Three box tests reach the last: a context-parameter property read bare
    (`contextParameters/inferGenericPropertyType`), an inner class's
    constructor reference (`callableReference/function/constructorFromInnerClassWithTypeParam`)
    and a generic member reference through an inner class
    (`innerClass/inCallableReferenceLHSwithGenericFun`); sema's inference
    there is the work.
  - done (`calls.reportInapplicable`): a call no candidate accepts is
    reported as kotlinc reports it. The candidates are ranked by how far
    each gets (a receiver that does not fit, below it one a default import
    brings, which is a plain `UNRESOLVED_REFERENCE`; then arguments that do
    not map; then an argument that does not fit); of the latest group the
    most specific is taken when there is one; several are
    `NONE_APPLICABLE`, listing that group; one names its problems:
    `ARGUMENT_TYPE_MISMATCH` per argument (the expected type as the other
    arguments fix it, a type parameter nothing fixed shown as its bound and
    reported `CANNOT_INFER_PARAMETER_TYPE`), `NULL_FOR_NONNULL_TYPE`,
    `TOO_MANY_ARGUMENTS` per extra argument, `NO_VALUE_FOR_PARAMETER`,
    `NAMED_PARAMETER_NOT_FOUND`, `ARGUMENT_PASSED_TWICE`, `NON_VARARG_SPREAD`,
    `UNRESOLVED_REFERENCE_WRONG_RECEIVER`, and `INAPPLICABLE_CANDIDATE` with
    `UPPER_BOUND_VIOLATED` for a written type argument. Positions are
    kotlinc's: the AST keeps a named argument's label and the `=` of an
    initializer, a default and an assignment.
  - not done: a lambda whose parameter count does not fit
    (`ARGUMENT_TYPE_MISMATCH` naming the lambda's type, and
    `CANNOT_INFER_VALUE_PARAMETER_TYPE`), which stays `NONE_APPLICABLE`;
    `@OnlyInputTypes` (`TYPE_INFERENCE_ONLY_INPUT_TYPES_ERROR`, sema says
    `ARGUMENT_TYPE_MISMATCH` for `m.getOrDefault("k", 1)` on a
    `Map<Int, String>`).
  - done (`declcheck.memberVariance`): `TYPE_VARIANCE_CONFLICT_ERROR` where
    a class's `in` or `out` type parameter stands in a member's type, a
    supertype or an inner class's member against its variance (parameter,
    receiver and bound types read `in`, a return type and a `val`'s type
    `out`, a `var`'s both; a private member is exempt; `@UnsafeVariance`
    skips its place). Through a type alias, kotlinc walks the expansion and
    places a finding by the expansion's argument index among the written
    arguments (read from its bytecode); a parameter standing directly in
    the expansion is `TYPE_VARIANCE_CONFLICT_IN_EXPANDED_TYPE`. The alias's
    written target is walked for its `@UnsafeVariance` places. Alias
    expansion now keeps a projected argument (`ML<out T>` for
    `MutableList<K>` is `MutableList<out T>`), which it dropped before.
  - done: `CYCLIC_GENERIC_UPPER_BOUND` (type parameters bounded by each
    other in a circle, at a function's parameter names and at a class's
    closing bounds); `TYPE_PARAMETER_IN_CATCH_CLAUSE` (at the catch
    parameter); `TYPE_PARAMETER_AS_REIFIED` for `T::class` and at a written
    type argument (the `Array` constructor reifies its `T`);
    `EXPRESSION_OF_NULLABLE_TYPE_IN_CLASS_LITERAL_LHS`;
    `INCORRECT_LEFT_COMPONENT_OF_INTERSECTION` (`X & Any` where `X` is not a
    type parameter whose bound admits null); `CANNOT_CHECK_FOR_ERASED` for an
    `is` (and a `when` branch's) on a type parameter that is not reified or
    a class whose non-star type arguments the subject's type does not fix
    through the class's supertype.
  - done (`calls.assignAmbiguity`): `ASSIGN_OPERATOR_AMBIGUITY` for `a += b`
    when `a` is a `var` (a setter's visibility does not matter), both
    `plusAssign` and `plus` apply and `plus`'s result fits `a`'s declared
    type; for `a[i] += b` the other reading is `set`. The message lists the
    two candidates in order.
  - done (`body.checkEquality`): `==` and `===` over types no value has both
    of (`subtyping.emptyIntersection`): two enums are
    `INCOMPATIBLE_ENUM_COMPARISON_ERROR`; an identity test is
    `FORBIDDEN_IDENTITY_EQUALS` when a side is a primitive, else
    `EQUALITY_NOT_APPLICABLE`; an equality is `EQUALITY_NOT_APPLICABLE` when
    a side is a built-in value type (a primitive, `String`, an unsigned
    type), and between other classes only a warning kotlinc gives
    (`INCOMPATIBLE_TYPES`, not reported yet). An integer literal is its
    `Int` there (`l == 1` for a `Long` is refused); a smart-cast value is
    judged by its declared type, as kotlinc only warns of a smart cast's.
- B5. Null safety and casts. Partly done:
  - done: a member, operator, `invoke` or iteration reached on a value that
    may be null without `?.` is resolved on its non-null type, as kotlinc
    resolves it, and reported: `UNSAFE_CALL` for a property read or a call
    (at the `.`; for an implicit receiver of nullable type, at the name),
    an index (at the receiver), a unary operator and `++`/`--` (at the
    operator); `UNSAFE_OPERATOR_CALL` for a binary operator, `in`, a
    comparison and a compound assignment (at the operator);
    `UNSAFE_IMPLICIT_INVOKE_CALL` for `f()` on a nullable value;
    `ITERATOR_ON_NULLABLE`. A call is unsafe only when nothing applies on
    the receiver as it is (an extension on the nullable type, as
    `Any?.toString()`, wins) and some candidate takes the non-null
    receiver. Before this, sema accepted `b.v` on a `Box?` and `f()` on an
    `(() -> Int)?`, so `klio run` ran programs kotlinc rejects. An
    operator whose candidates take the operand but not the arguments is
    diagnosed as a call is, at the operator. It needed two smart casts
    kotlinc makes: an equality with an operand whose type is not nullable
    (`pointer?.type == Kind.Mouse`) makes the other side not null, and a
    smart cast of a stable property reaches its `invoke`
    (`if (calculate !== null) calculate(d)`).
  - not done: `UNSAFE_INFIX_CALL`; `UNCHECKED_CAST`, `CANNOT_CHECK_FOR_ERASED`,
    `USELESS_CAST`, `UNNECESSARY_SAFE_CALL`, `UNNECESSARY_NOT_NULL_ASSERTION`.
- B6. Control flow: a structured flow pass over the syntax and sema's
  records, not cfa. Partly done (`flowcheck.zig`, a program's bodies):
  `UNINITIALIZED_VARIABLE` for a local read where some path reaches it
  unassigned, `VAL_REASSIGNMENT` for a `val` (local, parameter, loop or
  catch variable, a property with an initializer) assigned where it may be
  assigned already (a second time, again round a loop, in a lambda that
  does not run in place), and `NO_RETURN_IN_FUNCTION_WITH_BLOCK_BODY` where
  a block body with a result can reach its end. Paths end at `return`,
  `throw`, a jump, an expression of type `Nothing` and an exhaustive `when`
  whose branches all end (sema records which `when`s without `else` match
  every subject); a lambda passed for a parameter its callee's contract
  `callsInPlace` runs where the call is (sema reads `callsInPlace` with the
  `returns` contracts; klio's `synchronized` declares it as the JVM's
  does); a `finally` that never completes takes over the jumps through it.
  A loop or a repeatable in-place lambda is walked once: a write in it to
  a `val` declared before it, maybe assigned where the body goes round
  again, is the reassignment. A pack's or the base's bodies are left out:
  sema resolves them only where the program reaches them. A file's, a
  class's, an object's (an object expression's too) property initializers
  and `init` blocks are one path in the order they run, each property with
  a backing field (not `const`, not `lateinit`) tracked as a local is: a
  read before its initializer, delegate or an `init` block's assignment
  runs is `UNINITIALIZED_VARIABLE`, directly, through `this.x` or in a
  lambda run in place (an inline function's too), but not in a lambda,
  function or accessor, which may run later. A local class or object
  expression is initialized on its own after the file's walks. Not done:
  `INSTANCE_ACCESS_BEFORE_SUPER_CALL` (a constructor default reading a
  member), `INITIALIZATION_BEFORE_DECLARATION`,
  `CAPTURED_MEMBER_VAL_INITIALIZATION`, `CAPTURED_VAL_INITIALIZATION`,
  `UNREACHABLE_CODE` and the other warnings.
- B7. suspend, inline, tailrec. Partly done: a suspend call where it is
  written (`calls.checkSuspendCall`) stands in a suspend function or
  suspend lambda, through lambdas an inline function runs in place;
  elsewhere it is `NON_LOCAL_SUSPENSION_POINT` when a suspend function or
  lambda encloses the literal or local function it is in, and
  `ILLEGAL_SUSPEND_FUNCTION_CALL` otherwise. A lambda's scope records how
  it runs (suspend, in place, plain, or not known while its expected type
  is a variable, which says nothing). Done too: an inline parameter used
  other than called or passed on to be inlined is `USAGE_IS_NOT_INLINABLE`,
  and called in a body that is not inlined (a lambda passed to a function
  that does not inline it, or to a `crossinline` parameter, a local
  function or class) `NON_LOCAL_RETURN_NOT_ALLOWED` unless `crossinline`
  (`flowcheck.zig`; `inline constructor` is kept, so `Array(n) { ... }`
  inlines its lambda); `NULLABLE_INLINE_PARAMETER`;
  `TAILREC_ON_VIRTUAL_MEMBER_ERROR` (at the name, where kotlinc places it at
  the modifier: the parser keeps no modifier positions, as for the other
  modifier diagnostics); `NON_PUBLIC_CALL_FROM_PUBLIC_INLINE` for a call of
  a private or internal function that is not `@PublishedApi` from an
  effectively public inline function, `NON_PUBLIC_INLINE_CALL_FROM_PUBLIC_INLINE`
  when that function is inline; an `actual` is published where its
  `expect` is (Compose's `synchronized`, the stdlib's `mapCapacity`). Not done: `NO_TAIL_CALLS_FOUND`,
  `NON_TAIL_RECURSIVE_CALL`, a non-public property or class read from a
  public inline function, a suspend operator or a suspend `invoke` of a
  value.

C. Switch: `klio check` defaults to sema; `typeck_negative` asserts kotlinc
factory names from `klio check` (its 8 inline cases become fixtures); the 46
diagnostic rows of `annotation_targets`, `context_parameters` and
`explicit_backing_fields` move to the sema engine (their run rows stay);
`check_examples` covers every example kotlinc accepts; the JSON
`legacy_code` field goes; `scripts/stdlib-surface-inventory.py` greps check's
"unresolved reference" text and needs the new wording. check-diff joins
`scripts/gate.sh`.

D. Delete, each step building:

1. The pack typeck section: `pack_build.zig` `buildTypeckBundle`,
   `pack/schema.zig` `TypeckBundle`; drop `types` from pack's deps.
2. The CLI's use: `check_cmd.zig`'s old engine, `cli.zig`
   `resolver.pool_backing`, the `mem_census.zig` row.
3. The itests' use; `cfa_builder` and `cfa_smartcast` go with cfa.
4. `src/typeck` (19,988 lines) and `src/resolver` (2,026).
5. `src/cfa` (4,280).
6. `src/types` (2,587), then `stdlib.isKnownPackage`. Keep
   `ast.annotation_targets` if B2's targets use it.

The mirrors to edit with each: `build.zig` `mod_list` (it panics on a stale
dependency), `scripts/zigcheck.py` `GRAPH`, `itests.zig`, and the debugging
knobs (`KLIO_TC_*`, `KLIO_RESOLVE_THREADS`) in the docs.

## Where it stands

`scripts/check-diff.py` over the 807 inputs (kotlinc judges 524 examples,
every typeck_negative fixture and 4 fixtures; the rest import a library the
pinned kotlinc does not ship and are taken as valid):

| | Baseline | After B1 | After B2 (part) |
|---|---:|---:|---:|
| rule 1: typeck_negative kept | 9 | 69 | 76 |
| rule 1: typeck_negative missing | 110 | 50 | 43 |
| rule 1: examples missing (warnings) | 11 | 11 | 11 |
| rule 2: old false positives dropped | 785 | 785 | 785 |
| rule 3: sema matches kotlinc, typeck_negative | 8 | 77 | 85 |
| rule 3: sema matches kotlinc, examples | 0 | 16 | about 20 |
| rule 3: sema misses | 9 | 6 | 6 |
| rule 4: wrong severity | 0 | 0 | 0 |

Sema reports no error in the examples kotlinc judges. After B4's value and
call checks, of typeck_negative's 133 kotlinc diagnostics sema reports 98
and matches 97; kotlinc reports 36 sema does not (44 before them). The one
rule-3 miss is a `NOTHING_TO_INLINE` warning kotlinc leaves out beside the
`NON_PUBLIC_CALL_FROM_PUBLIC_INLINE` error sema does not report yet (B3).

The typeck_negative files `klio run` still runs though kotlinc rejects them
(2026-10-03): none. The examples kotlinc rejects use klio's JVM-only API
or a library's internals, as intended.

What sema still misses of kotlinc's diagnostics over the inputs
(2026-10-03, by the category that will cover it):

- errors in typeck_negative: `NO_VALUE_FOR_PARAMETER` beside `DELEGATION_NOT_TO_INTERFACE` for
  `class B : A by a` naming a class without its constructor call (B4; the
  file is refused for the other two).
- errors in programs, not reported yet: `NOT_YET_SUPPORTED_LOCAL_INLINE_FUNCTION`
  (kotlinc's JVM backend refuses `inline` on a local function, "local inline
  functions are not yet supported"). Packs keep them: kotlinx-datetime's
  commonKotlin `readTzFile` declares one, which Native and JS compile, so
  the lowering instantiates a local inline function as a top-level one and
  the error belongs to checked program files only.
- errors in examples, intended: klio's JVM-only API (`native_identity_hash`,
  `weak_references`, `thread_handle_values`) and kotlinx.coroutines
  internals (`channel_undelivered_element`, `INVISIBLE_REFERENCE`).
- warnings (B5 and the rest): `USELESS_IS_CHECK` (32), `UNCHECKED_CAST` (9),
  `USELESS_CAST`, `UNUSED_EXPRESSION`, `CAST_NEVER_SUCCEEDS`,
  `DIVISION_BY_ZERO`, `EXTENSION_SHADOWED_BY_MEMBER`,
  `REDUNDANT_CALL_OF_CONVERSION_METHOD`,
  `REDUNDANT_SPREAD_OPERATOR_IN_NAMED_FORM_IN_FUNCTION`,
  `NON_TAIL_RECURSIVE_CALL` and `NO_TAIL_CALLS_FOUND` (B7),
  `EQUALITY_NOT_APPLICABLE_WARNING`,
  `MULTIPLE_DEFAULTS_INHERITED_FROM_SUPERTYPES_DEPRECATION_WARNING`,
  `FINAL_UPPER_BOUND`, `REDUNDANT_ELSE_IN_WHEN`, `UNNECESSARY_SAFE_CALL`,
  `UNNECESSARY_NOT_NULL_ASSERTION`.

The pack-source check (`KLIO_CHECK_PACKS=1`) finds no declaration,
annotation or type-mismatch site in any pack. The base check
(`KLIO_CHECK_BASE=1`, the stdlib and klio's actuals) finds no type mismatch
and 13 declaration sites a program does not reproduce: `@Suppress` on an
`expect` function and on a constructor parameter not honored
(`REIFIED_TYPE_PARAMETER_NO_INLINE` twice, `DEPRECATION_ERROR`), the
unsigned types' `const val MIN_VALUE: UByte = UByte(0)` and its kin (8), the
annotation default `ReplaceWith("")` in `Deprecated`, and klio's
`external val Throwable.stackTrace`; besides them klio's coroutine
intrinsics (`Intrinsics.kt`) call a suspend `invoke` from functions that are
not suspend (6), where the JVM's are compiler intrinsics. klio's own inline
helpers reach their natives through `@PublishedApi` declarations, as
kotlinc requires. The klio glue it once flagged
(`KlioComposeOwner`, `KlioPointerIconService`) is gone: ui's host is
upstream's RootNodeOwner and scene now.

## What kotlinc 2.4.20 does

Settled by probing the pinned kotlinc; each shaped a check.

- It prints no warning of a compilation that has an error (the real
  `kotlinc` binary does the same), so `klio check` shows warnings only when
  there is no error.
- It holds `inc` and `dec` to no parameter count, and checks an operator's
  name (`illegal function name`) before its placement (`must be a member or
  an extension function`).
- It reports the abstract members a class leaves unimplemented in one
  diagnostic per class and kind (an interface's, a class's), and a member
  several supertypes implement once per member; a hidden (`@Deprecated`
  `HIDDEN`) member still overrides and implements.
- A data class's own `componentN` or `copy` is `CONFLICTING_OVERLOADS` at the
  function and at the class.
- `class D : O()` for an object `O` is `SINGLETON_IN_SUPERTYPE` and
  `UNRESOLVED_REFERENCE`.
- An annotation parameter cycle through an array is accepted; a direct one
  is `CYCLE_IN_ANNOTATION_PARAMETER_ERROR`. Only `kotlin.annotation.Repeatable`
  makes an annotation repeatable, not a class of that name elsewhere.
- A deprecated class is reported where a type or constructor call names it,
  not at its members' uses; an override of a deprecated member is
  `OVERRIDE_DEPRECATION`; a use inside a deprecated declaration is still
  reported. `@DeprecatedSinceKotlin` decides the level against the language
  version. The JVM's `String(CharArray)` is not deprecated where the common
  `expect` is, so sema leaves an `expect`'s deprecation to its `actual`.
- `abstract value class` and value classes of several properties need
  `-XXLanguage:+FullValueClasses`, which klio records per file.

## Measurements

Time: median 0.42 s a file against the old engine's 0.58 s. A compose
program's first check on a new binary bakes its base image (about 25 s);
after that it takes 3 s against the old engine's 18 s.
