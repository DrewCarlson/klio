# kotlinc box-test conformance corpus

The upstream `compiler/testData/codegen/box` corpus (7,351 programs, 6,371
selected by directive, 980 excluded) run through `klio`, each asserting
`box() == "OK"`. Stage 2 of `conformance-backlog.md`; the runner, the
ratchet, and the CI shard landed 2026-09-05, and the fixed clusters live in
git history under this file's name.

## State (2026-09-07, a1f95fb5)

Census 5951 passed / 398 failed / 8 did not complete (994 excluded: the
runner now also skips `DONT_TARGET_EXACT_BACKEND: JVM*` files). Ratchet
`BASELINE = 5951`, `MAX_FAILED = 398` in `src/itests/box_support.zig`.
Landed since 5751/609: function-type `is`/`as` by arity, companion and
enum-entry `invoke`, inner constructor refs, bound extension and vararg
refs, property references reading extension properties, callable-typed
properties invoked by name, enclosing-companion reads from nested classes,
`MutableMap.MutableEntry` checks, lateinit (27/27), enums (93/93, lazy
initialization), super (38/38), localClasses (41/41), typealias (28/28,
an alias expansion pass), value classes (38 → 12), Char arithmetic by
name, mixed Char comparisons, collection type-check bridges,
`Throwable(cause)`, `field` inside nested objects.

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

## Left: clusters of five or more (2026-09-07 census, a1f95fb5)

Fix each, or record a verdict here, until none remains; then write the
residue list (every cluster under five) as the seed of the next campaign.

| Cluster | Fails | Dominant shape |
| --- | --- | --- |
| contextParameters | 23 | verdict recorded below |
| callableReference/adaptedReferences | 15 | context-parameter refs (5), suspend conversion of extension/context refs as supertypes (6: `startCoroutine` on the receiver), vararg/default adaptation (4) |
| coroutines | 13 (+10 in subdirs) | intrinsic semantics (`startCoroutineUninterceptedOrReturn`, `intercepted`), suspend function types as supertypes, `handleResult` try/finally shapes |
| extensionFunctions | 10 (+1 crash) | anonymous extension function values, extension in a value class, local extension in a SAM, `last` set on a builtin list |
| fir | 9 | overloads differing only in type-parameter bounds (3), context-sensitive resolution of enum entries (2), anonymous/local override with defaults (3) |
| delegatedProperty | 8 | `getValue`/`setValue` as member extensions of the enclosing class, delegate to a singleton/null, `Delegates.notNull` |
| secondaryConstructors | 7 | field initializer order with secondary constructors, local subclass delegation, varargs |
| inline | 7 | local inline extension functions inside lambdas, references to local functions |
| evaluate | 7 (+4) | const evaluation of unsigned named operations (`plus1`), `kCallableName`, char ops, enum name in init |
| collectionLiterals | 7 | the `[a, b]` collection literal syntax with the `of` operator convention (not parsed yet) |
| casts | 7 | `Unit as Any`, definitely-not-null casts, generic `as` failures |
| properties | 6 | eager initialization, private constructor properties, generic names |
| operatorConventions | 6 | convention resolution edges |
| objects | 6 | companion access from an anonymous object in a nested class, object init order |
| inlineClasses/inlineClassCollection | 6 | anonymous object implementing `List<VC>` reading the value class's field |
| functions/localFunctions | 6 | local function capture |
| controlStructures | 6 (+6 breakContinueInExpressions) | `break`/`continue` inside inlined lambdas and loop conditions, `finally` ordering |
| callableReference/function | 6 | local extension refs by receiver type, `overloadedFunVsVal`, companion member refs |
| defaultArguments | 5 (+8 in subdirs) | defaults on convention operators (`set`), fake overrides with defaults, 32-argument masks |
| callableReference/equality | 5 | adapted references must not be equal to each other |
| strings, intrinsics, increment, finally, arrays | 5 each | single-file mismatches; arrays: two-index `get`/`set` on an `ArrayList` instance and non-local return from an array constructor lambda |

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
- properties/fieldInsideField (1): an anonymous object's property with
  both an initializer and a `field`-reading getter stores the initializer
  under the plain name, not the raw backing slot.
