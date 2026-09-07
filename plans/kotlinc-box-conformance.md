# kotlinc box-test conformance corpus

The upstream `compiler/testData/codegen/box` corpus (7,351 programs, 6,371
selected by directive, 980 excluded) run through `klio`, each asserting
`box() == "OK"`. Stage 2 of `conformance-backlog.md`; the runner, the
ratchet, and the CI shard landed 2026-09-05, and the fixed clusters live in
git history under this file's name.

## State (2026-09-07, eb4d1fcc)

Census 5751 passed / 609 failed / 11 did not complete. Ratchet
`BASELINE = 5751`, `MAX_FAILED = 609` in `src/itests/box_support.zig`
(pass floor and failure ceiling, no slack). The suite stands in
`scripts/stack.sh` and in CI at shard weight 35.

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

## Left: clusters of five or more (2026-09-07 census)

Fix each, or record a verdict here, until none remains; then write the
residue list (every cluster under five) as the seed of the next campaign.

| Cluster | Fails | Dominant shape |
| --- | --- | --- |
| callableReference/adaptedReferences | 18 | `invoke_callable_with_this` on a `KClass` value; `startCoroutine` on the receiver of a suspend reference |
| inlineClasses | 18 (+2 crash) | field read on an anonymous object standing for a value class; member extension on a value class; secondary constructors of generic value classes crash |
| typealias | 13 | explicit type arguments on an alias call reaching the constructor as values; alias targets from a class body; an alias of a companion as a value; aliases in anonymous object types and super calls; alias-typed extensions |
| coroutines | 13 | exception expected from a suspend path not thrown; intrinsic semantics and feature intersection |
| callableReference/function | 12 (+1 crash) | `invoke_callable_with_this` on a `KClass`; a reference cast to `Function1` fails; an extension in a SAM interface recurses |
| super | 12 (+1 crash) | `super` call resolving to the subclass override (`test1 B.bar`); a `super<Interface>` chain crashes |
| casts/functions | 11 | `Function0` unresolved as a global (function-type `is`/`as` checks) |
| localClasses | 11 | `this@C` unbound inside a local class; captured locals read null |
| extensionFunctions | 11 | one recursion (SAM interface extension), the rest single-file mismatches |
| enum | 11 | entry initialization order against companion and static init (`Foo.FOO;Foo.B…` order); lazy entry init |
| properties/lateinit | 10 | `isInitialized` from another class; uninitialized access must throw; a Unit value where the property was expected |
| fir | 10 | member call on an anonymous object; `Unit` rendered into a string |
| diagnostics/functions | 10 | constant `ONE` read on a `KClass`; two recursions; constructor arity through a reference |
| delegatedProperty | 10 | file initialization failure on a top-level delegate; `provideDelegate` inference cases |
| properties | 9 | accessor shapes (see the file names) |
| binaryOp | 9 | operator convention edges |
| specialBuiltins | 8 | JVM builtin stubs (`extendJavaClasses`) |
| objects/companionObjectAccess | 8 | companion members through the class value |
| extensionProperties | 8 | extension property accessors |
| callableReference | 8 | property, bound, equality subgroups (6, 5, 5) |
| secondaryConstructors | 7 | delegation chains |
| inline | 7 | inline function edges |
| evaluate | 7 | unsigned constant operations (`plus1` unresolved), `kCallableName` |
| collectionLiterals | 7 | array literals in annotations |
| classes | 7 | class body shapes |
| casts/mutableCollections | 7 | `as MutableList` checks on read-only collections |
| operatorConventions | 6 | convention resolution edges |
| increment | 6 | `++`/`--` on properties and indexed receivers |
| functions/localFunctions | 6 | local function capture |
| defaultArguments | 6 | default parameter evaluation |
| controlStructures/breakContinueInExpressions | 6 | `break`/`continue` inside expressions |
| closures | 6 | capture shapes |
| builtinStubMethods/extendJavaClasses | 6 | JVM stub methods |
| arrays | 6 | multi-index `get`/`set` (`collectionGetMultiIndex`) |
| strings, intrinsics, finally | 5 each | single-file mismatches |

The `functions/nothisnoclosure.kt` crash is an RSS-cap abort (6.4 GB); it
is a memory blow-up, not a semantic miss.

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
