# kotlinc box-test conformance corpus

The upstream `compiler/testData/codegen/box` corpus (7,351 programs, 6,371
selected by directive, 980 excluded) run through `klio`, each asserting
`box() == "OK"`. Stage 2 of `conformance-backlog.md`; the runner, the
ratchet, and the CI shard landed 2026-09-05, and the fixed clusters live in
git history under this file's name.

## State (2026-09-07, 8c8c613a, CI green)

Census 6002 passed / 352 failed / 3 did not complete (994 excluded: the
runner now also skips `DONT_TARGET_EXACT_BACKEND: JVM*` files). Ratchet
`BASELINE = 6002`, `MAX_FAILED = 352` in `src/itests/box_support.zig`.
Landed since 5751/609: function-type `is`/`as` by arity, companion and
enum-entry `invoke`, inner constructor refs, bound extension and vararg
refs, property references reading extension properties, callable-typed
properties invoked by name, enclosing-companion reads from nested classes,
`MutableMap.MutableEntry` checks, lateinit (27/27), enums (93/93, lazy
initialization), super (38/38), localClasses (41/41), typealias (28/28,
an alias expansion pass), value classes (38 → 12), Char arithmetic by
name, mixed Char comparisons, collection type-check bridges,
`Throwable(cause)`, `field` inside nested objects, null string plus, nullable and array `compareTo` extensions, `set` value binding with defaults and varargs, delegate operators as member extensions, jumps leaving try frames before finally replay (finally 24/24), do-while `continue`, nullable-local `++`/`--` through `inc`/`dec` extensions, `null as T` NPE and declared one-letter cast targets (casts 57/61), `super.Inner(args)`, imported object member writes.

## How to work it

- Runner: `src/itests/box_support.zig` (shared by the `box_conformance`
  itest and `klio-census box`). One child `klio run` per test; sections
  become numbered files under `/tmp/klio_itest_box_home/cases/<path>/`; a
  synthesized `__box_main.kt` throws unless `box() == "OK"`; the
  `WITH_COROUTINES` helpers are appended; `OPTIONAL_JVM_INLINE_ANNOTATION`
  becomes `@JvmInline`.
- One directory: `KLIO_ITEST_BIN=zig-out/bin/klio-harness
  KLIO_BOX_FILTER=enum/ KLIO_BOX_JOBS=4 zig-out/bin/klio-census box`
  (`KLIO_BOX_FILTER` is a path substring; `enum` also matches `enumEntries`).
  Full census: drop the filter, `KLIO_BOX_JOBS=12`, about six minutes.
  `KLIO_BOX_TIMEOUT_MS` defaults to 60 s (×4 on a Debug harness).
- One test by hand: copy the file, append `fun main() { println(box()) }`,
  run it through the harness with `KLIO_HOME=$PWD/.klio-local`.
- Cluster a census by the first two path segments and count `[box-crash]`
  lines with the `[box-fail]` lines; a crash is a panic in the interpreter
  (`KLIO_ERR_TRACE=1` prints the frame chain).
- Every fix ships an `examples/` program, its
  `tests/corpus/expected/<name>.out`, and a README row; the corpus file
  must pass unmodified (a renamed or simplified copy is for bisecting
  only); kotlinc semantics exactly, oracle where in doubt.
- Before the push: the whole battery (`scripts/stack.sh`) plus
  `itest-e2e`, `itest-parity_corpus_pinned` and the CLI corpus check; the
  stdlib sweep does not cover the coroutines census or the pinned parity
  corpus, and both have caught lowering regressions the sweep passed.

## Left: clusters of five or more (2026-09-07 census, a1f95fb5; CI green at 94104fbd)

Fix each, or record a verdict here, until none remains; then write the
residue list (every cluster under five) as the seed of the next campaign.

| Cluster | Fails | Dominant shape |
| --- | --- | --- |
| contextParameters | 23 | verdict recorded below |
| callableReference/adaptedReferences | 15 | context-parameter refs (5), suspend conversion of extension/context refs as supertypes (6), vararg/default adaptation (4) |
| coroutines | 13 (+10 in subdirs) | intrinsic semantics (`startCoroutineUninterceptedOrReturn`, `intercepted`), suspend function types as supertypes, `handleResult` try/finally shapes |
| extensionFunctions | 10 (+1 crash) | anonymous extension function values, extension in a value class, local extension in a SAM, `last` set on a builtin list |
| fir | 9 | overloads differing only in type-parameter bounds (3), context-sensitive resolution of enum entries (2), anonymous/local override with defaults (3) |
| secondaryConstructors | 7 | field initializer order against a super constructor's virtual call, default-argument constructor chains, local subclass delegation, mixed spread in super arguments |
| evaluate | 7 (+4) | unsigned `const val` receivers (verdict below), `kCallableName`, char ops, enum name in init |
| collectionLiterals | 7 | the `[a, b]` collection literal syntax with the `of` operator convention (not parsed) |
| casts | 4 | `asWithGeneric`, `kt50577`, `unitAsAny`/`unitAsSafeAny` (pass alone; the census-side runner marker now goes through `kotlin.io.println`) |
| properties, operatorConventions, objects, inlineClasses/inlineClassCollection, inline, functions/localFunctions, delegatedProperty, controlStructures/breakContinueInExpressions, classes, callableReference/function | 6 each | single-file shapes; the breakContinueInExpressions six are `break`/`continue` inside inlined lambdas |
| defaultArguments, coroutines/intrinsicSemantics, coroutines/featureIntersection, callableReference/equality, arrays | 5 each | single-file shapes; arrays: two-index operators on a stub-class instance (verdict below) and non-local return from an array constructor lambda |

## Verdicts recorded (closed; reopen only with a new mechanism)

- contextParameters (21): five mechanisms, each under five: a named
  argument naming a context parameter on a member with context and
  no-context overloads; a context parameter shadowed by the extension
  receiver's same-named member; a companion object as a context value; a
  context parameter used as another parameter's default; an outer inline
  receiver splice's subject not feeding a contextual callee's context
  (the fused tier's chain window seeds from the in-flight pushes above
  its base).
- inlineClasses `zs.contains(object {} as Any)` (six files): the static
  half landed (an explicit `as Any` argument is inapplicable to a
  concrete parameter); the extension resolver still rejects
  `Iterable<T>.contains` because `T` bound from the receiver conflicts
  with the `Any` argument where kotlinc unifies to `Any`.
- ranges (3): `inComparableRange` and
  `forInCharSequenceWithCustomIterator` pick an extension by the runtime
  receiver where kotlinc binds by the static type inside a generic or
  supertype-typed body; `inDoubleRangeLiteralVsComparableRangeLiteral`
  needs a `Comparable`-typed `..` to build a `ComparableRange`.
- typeErasure (3): a local declared `Any?` reaches the reified binder as
  `Any` (its nullability record is not visible at the unification site);
  two context-parameter shapes.
- arrays two-index operators (2): `s[1, -1]` on an `ArrayList` INSTANCE
  (a stub-class instance, not a host list) reaches the stdlib `get`
  intrinsic through the instance route before the user extension; the
  arity gate (`memberDeclArityMisfit`) covers host receivers only.
- typealias expansion on shipped sources (scope): the AST alias pass
  rewrites the program's files only; expanding a library's aliases
  (compose's `VirtualGroupHandle` = `GroupHandle` = `Long`) made a
  file-private extension property on the aliased scalar, read bare inside
  a spliced inline extension, miss (`isInsertHandle` on `LinkComposer`,
  291 compose plugin tests). A library's aliases are still collected, so
  a program using them expands them.
- evaluate unsigned const receivers (3-5): `const val one = 1u` then
  `one.plus(2u)` dispatches `plus` on a receiver that reads as `Int` at
  the member-call site (`two.plus(2u)` with a plain `val two = 2u` works;
  `one is UInt` is true; the initializer thunk returns a `UInt` const),
  so top-level `const val` unsigned operations (`plus1`, `and1`) miss;
  the binding path was not isolated.
- functions/localFunctions overloadedLocalFunction (2): a nested-scope
  local `fun foo(x: String)` shadows the outer `fun foo(x: String, y: Int)`
  by name; kotlinc picks the outer by arity, which needs an enumeration of
  every binding of the name across the scope chain.
- operatorConventions/kt4987 (1): `counter++` on a null `Int?` with a
  LOCAL `Int?.inc()` extension reaches the member call on a null
  receiver instead of the local closure.
- callableReference/adaptedReferences (15): five are context-parameter
  references (the contextParameters verdict); six are `suspend` conversion
  of an extension or context reference used as a SUPERTYPE (`class A :
  suspend () -> Unit`, `startCoroutine` on the instance), which needs the
  `SuspendFunctionN` interfaces modeled as classes an object can extend;
  four adapt a vararg or a defaulted parameter through an inner or nested
  constructor reference (`innerConstructorWithVararg`,
  `nestedClassConstructorWithDefault`, `varargOverloads`,
  `adaptedVarargFunImportedFromObject`), where the adapter stamps only
  functions with a body.
- callableReference/equality (5): adapted references (unit coercion,
  vararg-as-array, suspend conversion) must be distinct objects that are
  not equal to each other or to the plain reference; klio's references are
  closures keyed by function id, so two adaptations of one function
  compare equal.
- coroutines (mechanisms landed 8c8c613a..): function types as
  supertypes, suspend is-checks, callable instances, and inline-resumed
  `startCoroutineUninterceptedOrReturn`/
  `suspendCoroutineUninterceptedOrReturn` are fixed. The remaining
  interception trio (`intercepted`, `releaseIntercepted`,
  `startCoroutineUninterceptedOrReturnInterception`) needs the
  `ContinuationInterceptor` model (a wrapper counted per resume); `handleResult` try/finally shapes
  (`try*WithHandleResult`) expect the exception thrown from
  `handleResult` to unwind through the coroutine's finally blocks; the
  rest are single files (`accessorForSuspend`, `createCoroutinesOnManualInstances`,
  `functionReference_invokeAsFunction`, `innerSuspensionCalls`, `kt15930`,
  `kt46813`, `kt51530`, `nestedLocals`, `rethrowInFinallyWithSuspension`,
  `suspendConversionBetweenFunInterfaces`, `operators`,
  `manyParametersNoCapture`, `crossinline`, `varargCallFromSuspend`).
- extensionFunctions (8 + 1 crash): `extensionFunctionWithExtensionInSAMInterface`
  (and its callableReference/function twin) recurse without bound: a fun
  interface whose single method is a member extension, implemented by a
  reference, re-dispatches to itself; the rest are single files
  (`delegatedPropertyWithExtensionType`, `extensionFunctionInValueClass`,
  `extensionFunctionLocal`, `functionWithTheSameDispatchAndExtensionReceiver`,
  `kt1953`, `kt475` (`last` set on a builtin list), `kt606`,
  `suspendConversionForExtensionFunAsASuperType`).
- fir (rest): `contextSensitiveResolution` (2) is the Kotlin 2.2 bare enum
  entry in a `when` over an enum subject; the anonymous/local override
  with defaults (3) resolves `super.foo` on a local or anonymous override
  and renders `Unit`; `localInvokeExtension` (1).
- secondaryConstructors (7, needs a fix — not JVM-only): two roots.
  (1) LOCAL-class secondary constructors do not run — `synthLocalClassDef`
  (`host_classes.zig`) registers a local class with `secondary_ctors =
  &.{}`, and the build-time entry builder (`build.zig` ~3928) walks only
  top-level `decls`, so a local `constructor() : this(...)` never runs the
  primary's field init: `callFromLocalSubClass`, `clashingDefaultConstructors`,
  `localClasses` fail with `get_field x on B`. The fix recurses the entry
  builder into function-body classes (delegation-arg and body thunks
  lowered in the local scope; capture-free cases first) or synthesises
  entries at registration. (2) `init` blocks interleave with secondary
  constructor bodies in DECLARATION order between the super call and the
  body (`superCallSecondary`, `innerClassesInheritance`). `fieldInitializerOptimization`
  and `varargs` are single files.
- evaluate (8 left): the unsigned `const val` receiver bug is FIXED
  (`literalToConst` folded `2u` to `Int`, so a const-val global lost its
  unsigned type; `uintOperations`, `ulongOperations`, `unsignedConst` now
  pass). `ubyteOperations`/`ushortOperations` still fail because
  `UByte.and`/`UShort.and` return `Byte`/`Short` not the unsigned type (a
  value-class boundary, the inlineClasses cluster). The rest: `kCallableName*` need `::name` on a KCallable
  evaluated as a constant; `charOperations`, `enumNameWithInit`, `incDec`,
  `stringConcatenationWithObject` are single files.
- collectionLiterals (7): the `[a, b]` collection literal expression
  (`-XXLanguage:+CollectionLiterals`, `operator fun of`) is not parsed
  outside annotations.
- controlStructures/breakContinueInExpressions (6): `break`/`continue`
  from a lambda passed to an inline function (`inlinedBreakContinue/*`,
  `-Xnon-local-break-continue`) surface as `LabeledReturn`; the splice
  does not carry the enclosing loop's targets into the lambda body.
- objects (5): `useImportedMember*` import overloaded companion members
  by name and pick among `f(Int)`/`f(String)`/`Boolean.f()`; `kt3684`,
  `objectLiteral`, `thisRefToObjectInNestedClassConstructorCall` are
  single files.
- properties (4 left): `kt4140`/`companionFieldInsideLambda` FIXED — a
  companion property read (`companionMemberOfClass`) returned the stored
  backing field before checking for a custom getter, so `var p = 1; get()
  = field++` skipped the getter and its write; the getter now runs whenever
  one is registered. Remaining: `classFieldInsideLocalInSetter` (a local fn
  in a setter writing `field`), `fieldInsideField` (verdict above),
  `genericWithSameName`, `privatePropertyInConstructor` (a private
  constructor property shadowed by a subclass's same-named property;
  instance field storage is keyed by name alone).
- operatorConventions (3 left): the lvalue-caching mechanism landed (a
  member target's receiver is evaluated before the value; an indexed
  target's receiver and indices are evaluated once for the read and the
  write; a prefix increment's value is a fresh read); the rest are
  `infixFunctionOverBuiltinMember`, `kt14201_2`, `kt4987` (verdict above).
- inline (6): local `inline` extension functions used inside lambdas
  (`localInlineExtensionFunction`, `localInlineFunctionComplex`),
  references to local functions (`callableReferenceOfLocalFun`,
  `callableReferenceOfLocalInline`), `continueInLoopWithInlinableCondition`,
  `inline25`, `operators`.
- functions/localFunctions (6): the nested-scope overload verdict above
  (2), `kt4119`, `kt4783`/`kt4784` (a local function whose receiver is a
  type parameter), `kt4989`.
- classes (4 left): the `Int?.inc` smart-cast/`!!` recursion is FIXED for
  kt723 and kt725 (a `!!`-asserted or `if (this != null)`-narrowed receiver
  resolves against the NON-null type -> builtin `Int.inc`, not the nullable
  extension). Remaining: kt2711 (below), `extensionFunWithDefaultParam`,
  `kt2477`, `nestedInitBlocksWithLambda` (kt2711 also fixed).
- callableReference/function (6): `extensionFunctionLocal` (two local
  extensions of the same name told apart by receiver type),
  `extensionWithNestedFunction`, `genericCallableReferenceWithReifiedTypeParam`,
  `overloadedFunVsVal` (a property and a function of one name picked by
  the expected type), `referenceToCompanionMember` (`Function0`/`Function1`
  checks on a bound-reference instance), `genericConstructorReference`.
- defaultArguments (5 + 8 in subdirs): defaults on convention operators
  with 32-argument masks (`innerClass32Args`, `memberFunctionManyArgs`),
  fake overrides with defaults (`implementedByFake*`, `funInTraitChain`),
  `kt36188*`, `kt36853_fibonacci`, `kt47073_nested`, `incWithDefaultInGetter`.
- arrays (2 left): the multi-index `a[i, j]` / `a[i, j] = v` operator is
  FIXED — a builtin collection's `get`/`set` no longer swallows the extra
  index; `stdlibMemberDispatch` declines an over-arity `get`(>1)/`set`(>2)
  so the user operator resolves (`collectionGetMultiIndex`,
  `collectionAssignGetMultiIndex`). Remaining: `nonLocalReturnArrayConstructor`
  (a non-local `return` from an `Array(n) { }` initializer: the constructor
  is an intrinsic, not an inline splice), `kt4348` (`operator fun
  String.get(vararg)`).
- delegatedProperty (remaining 13, cluster 6): `delegateToNull`/
  `delegateToSingleton` (a `val x by null`/object delegate),
  `delegateWithPrivateSet` (`Delegates.notNull` unresolved),
  `delegatedByExtensionProperty`, `custom`, `genericDelegateUncheckedCast2`,
  `kt9712`/`commonCaseForInference` (parse and inference diagnostics),
  `kt40815_2`, `memberExtension`/`noInitializationOfOuterClass` (file
  initialization order), `referenceEnclosingClassFieldInReceiver*`.
- fir/functionsDifferInTypeParameterBounds2, 3 (2): overloads that differ
  only in which of several parameters carry a bound (`<S1, S2 : B, S3>`
  against `<S11 : A, S12 : B, S13 : C>`): applicability now judges a
  bounded parameter by its bound (the single-parameter case passes), but
  the scorer does not rank a candidate by how many bounds it satisfies,
  so the first applicable overload wins.
- inlineClasses/inlineClassCollection (6): the `zs.contains(object {} as
  Any)` verdict above (a value class implementing `List<Z>`).
- classes/kt2711 (1): a user class NAMED `IntRange` shadows the builtin;
  `(1..2).contains(a)` inside its `contains` must bind the BUILTIN range's
  contains, not re-enter the user class's same-named method (a
  same-name-as-builtin resolution clash). FIXED: the range-type derivation
  drops the static type when a USER (non-`kotlin.`) class shadows the range
  name, so `.contains` dispatches to the builtin range value. kt723/kt725/
  kt2711 ALL FIXED — the classes crash trio is closed.
- properties/fieldInsideField (1): an anonymous object's property with
  both an initializer and a `field`-reading getter stores the initializer
  under the plain name, not the raw backing slot.

## Residue (clusters under five at 6017 / 337 / 3, 34d1a79f)

Every directory with five or more failures above has a fix or a verdict.
The remaining failures, grouped by directory, are the seed of the next
campaign; the first column is the failure count.

| n | directory | shape |
|---|-----------|-------|
| 4 | strings | `String.format` locale forms, `trimMargin` on raw templates, `Char.code` in templates |
| 4 | intrinsics | JVM intrinsic bridges (`hashCode` on nullable, `arrayOfNulls` typed) |
| 4 | initializers | init-order across companion and nested object initializers |
| 4 | inference | PCLA builder inference through generic receivers |
| 4 | extensionProperties | extension property on a type parameter / nullable receiver, `by` on an extension |
| 4 | evaluate/intrinsicConst | `const val` folding of intrinsics (`Int.MAX_VALUE.toString()`, `length`) |
| 4 | delegation | delegation to a type-parameter-typed field, `by` an interface with generic defaults |
| 4 | defaultArguments/function | 32/33-argument mask boundaries, defaults reading earlier defaults |
| 4 | coroutines/featureIntersection | coroutines with bound refs, inline classes, tail calls |
| 4 | companionBlocksAndExtensions | companion extension shadowing and `init` blocks |
| 4 | closures | captured `var` in nested closures inside super-constructor calls |
| 4 | callableReference/bound | bound references to `Any` members and to value-class receivers |
| 3 | typeErasure | the erased-cast verdict |
| 3 | reified | `Array<T>` construction with a reified `T`, `T::class` on a nested class |
| 3 | regressions | assorted kt-numbered regressions |
| 3 | reflection/classes | `KClass.simpleName`/`qualifiedName` on local and anonymous classes |
| 3 | primitiveTypes | `-0.0` equality, `Long` to `Char`, boxed identity |
| 3 | operatorConventions | `infixFunctionOverBuiltinMember`, `kt14201_2`, `kt4987` |
| 3 | multiDecl | destructuring an `Iterator` via extension `componentN` |
| 3 | inlineClasses | value-class boxing at `Any` boundaries |
| 3 | ieee754 | `Double`-vs-`Float` comparison rules under smart casts |
| 3 | funInterface | fun interface SAM conversion with default methods |
| 3 | functions | `nothisnoclosure` (memory cap) and two `invoke` shapes |
| 3 | function | `Function22`/`FunctionN` arity limits |
| 3 | dataClasses | `copy` with defaults from the primary, `toString` of nested arrays |
| 3 | controlStructures | `for` over a custom iterator with `hasNext` side effects |
| 3 | callableReference/property | references to extension properties on generic receivers |
| 3 | binaryOp | `Long shl Int`, `compareTo` between mixed numerics |
| 3 | basics | assorted single files |
| 2 | unsignedTypes, traits, topLevelInitializtion, super, statics, reified/catchParameter, reflection/typeOf/noReflect/nonReifiedTypeParameters, ranges/contains, multiDecl/forRange, mixedNamedPosition, ir, innerNested/superConstructorCall, innerNested, inlineEvaluationOrder, inlineClasses/funInterface, functions/invoke, functions/functionExpression, fir/contextSensitiveResolution, diagnostics/functions/tailRecursion, delegatedProperty/provideDelegate, delegatedProperty/delegateToSingleton, dataObjects, dataClasses/toString, controlflow, collections, casts, callableReference | pairs |
| 1 | 66 directories | singletons (`[box-fail]` lines of the census log) |

Crashes (3): the two `extensionFunctionWithExtensionInSAMInterface` files
(unbounded recursion, verdict above) and `functions/nothisnoclosure` (the
process memory cap: a 100k-iteration loop allocating a closure per call).
