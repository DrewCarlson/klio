# A resolved interpreter

klio executes a **fully resolved IR**. Every call, field access, receiver and
name reference that Kotlin decides statically is bound before execution to a
declaration identity: a `FuncId`, a class-relative method slot, a field slot, a
static slot, or a receiver register. The runtime never re-derives one by name,
and the IR has no way to express a site that is not bound.

Speed is the consequence, and so is correctness: a Kotlin call has one meaning,
fixed by the declaration it resolves to, and an interpreter that re-decides it
per execution can decide it differently.

The campaign log that preceded this rewrite of the plan (2026-09-19 to
2026-09-23) is in git history before the commit that replaced it. Its findings
are summarised under "Why the first approach stalled" and its soundness facts
are carried forward under "Acceptance facts".

## Why the first approach stalled

Measured over the 263 commits of the first campaign:

| What | Start | End |
|------|------:|----:|
| Static unresolved sites (corpus census) | 9.40% | 1.85% |
| Trivial instruction | 2.10 ns | 2.10 ns |
| Cheapest activation | 46 ns | 46 ns |
| `Inst` variants | 49 | 50 |
| Variants "Done means" requires deleted | 7 | 7 |
| `src/` lines | | +20 215 / -1 962 |
| Compensating `link*` passes | | +14 |

The census fell and nothing the goal measures moved. The reason is structural:
**nothing in the pipeline produces resolution.** There are three resolvers and
all three are keyed by name:

- `src/resolver` builds a lexical scope table whose output nothing downstream
  reads.
- `src/typeck` is a tolerant checker. Its class table is keyed by simple name;
  a user class types as `Type.Unresolved`; `isSubtypeOf` answers true for any
  user class and any type parameter; type parameters and inference variables
  are strings. Its answers reach lowering as span-keyed tables of name heads
  with the type arguments stripped. It checks the raw parse while lowering
  consumes the AST after the serialization, alias, lift and compose passes
  rewrote it.
- Lowering guesses. About 23k lines of `src/ir/lower` derive a static type,
  receiver, callee or overload from local evidence, another 11k are the
  fallback ladders around them (`lowerCall` tries 16 things, then
  `lowerCallGeneral` 29), and 110 emission points end in a by-name
  instruction because every ladder is allowed to.

Each commit therefore taught one lowering arm one more receiver shape, found the
soundness conditions of that shape one failure at a time, and patched the rest
with a link pass. The runtime meanwhile carries about 35k lines that serve
by-name sites, and several sites the census counts as resolved still resolve by
name at run time (a host `CallVirtual` builds a `"type.name"` string first; a
claimed field slot compares names on every read; `catch` and `is` match strings;
named arguments re-pick the overload per call).

## The strategy

1. **One authority.** A new frontend module, `sema`, resolves every reference in
   every body to a declaration identity and types every expression, with generic
   substitution, smart casts and the implicit-receiver tower. Lowering
   translates what sema decided. It never infers, ranks, guesses or falls back.
2. **The IR cannot express an unresolved site.** The by-name variants leave
   `Inst`. A comptime test walks `@typeInfo(Inst)` and fails the build if any
   payload carries a name (`ConstId`, `[]const u8` or a string `TypeRef`)
   outside a short allow-list. A lowering that meets a site sema did not resolve
   reports an internal error with the site's span and the function fails to
   build. There is no runtime fallback anywhere.
3. **Measure at the frontend.** Sema runs without executing anything. Its census
   counts unresolved references by reason over the stdlib, every shipped pack
   and the corpus in seconds, and a kotlinc oracle compares its answer at every
   call site of the corpus with the one kotlinc 2.4.20 chose. Execution-cost
   numbers are re-taken at the cutover and after, because they are the goal.
4. **The old resolution path is frozen, then deleted, never migrated.** No
   further binding work lands on the current lowering or runtime. It is kept
   building until the cutover, which deletes it in one sweep.
5. **Size bounds the red.** Failing tests are acceptable while the path to green
   is bounded, and the bound is stated in lines of code for every item below.
   Deletion is a deliverable: each item lists what it removes.

## Sema

### What it produces

For every body (function, accessor, initializer, lambda, default argument,
local class member), a dense table indexed by AST node id:

- **Expression type** as an interned `TypeId`, fully substituted.
- **Call record** for every call, including the desugared ones (operators,
  `for`'s `iterator`/`hasNext`/`next`, `componentN`, delegates'
  `getValue`/`setValue`/`provideDelegate`, `+=` choosing `plusAssign` or
  `plus` then assign, `==` to `equals`, template `toString`): the callee
  declaration; its dispatch kind (static, virtual, interface, super,
  invoke-on-value, constructor, primitive operation); the dispatch receiver and
  the extension receiver, each either an expression or an implicit receiver
  named by its lexical position; context arguments; the argument-to-parameter
  map with defaults, varargs and spread; substituted type arguments, with
  reified ones marked; SAM and suspend conversions.
- **Name record** for every name: local (declaration id), parameter, context
  parameter, property (declaration and receiver), object or companion
  singleton, enum entry, class literal, reified type parameter.
- **Receiver record** for every `this`, `this@L`, `super`, `super<T>@L`.
- **Type record** for every `is`, `as`, `catch` and class literal, as a
  `TypeId` with its erasure.

### Model

- **Symbols with identity**: packages, classes (including nested, local,
  anonymous, companion), type parameters, functions, constructors, properties
  and their accessors and backing fields, value parameters, locals, type
  aliases, enum entries. Dense ids. Lowering's `FuncId` and `ClassId` are
  allocated from these one to one, so there is a single identity per
  declaration.
- **Types by identity**: class type (symbol, arguments, nullability), type
  parameter (symbol), function type (receiver, context, parameters, return,
  suspend), intersection, definitely-non-null, captured, error. Subtyping walks
  the declared supertype graph with declaration- and use-site variance.
  Primitives, `Any`, `Nothing`, arrays and `FunctionN` are ordinary classes
  declared by Kotlin source.
- **Builtins from source.** `kotlin.Int`, `String`, `Any`, `Array` and the rest
  are declared by Kotlin source in the base source set, the way every other
  platform declares them. Native implementations bind to those symbols once at
  link time through a `NativeId` table, never by name at a call.
- **Member scopes**: declared plus inherited members with override grouping
  (fake overrides), property families keyed by name, `by` delegation,
  synthesized data/enum/value-class/fun-interface members, expect/actual.
- **Scope tower**: locals, the implicit receivers (class `this` and its outers,
  extension receivers, lambda receivers, context parameters, companions),
  explicit/star/alias imports, default imports, package members.
- **Calls**: candidates collected per tower level, applicability with argument
  mapping, most-specific selection, a constraint system for generic inference
  (ported from `src/types/constraints.zig` onto the identity subtyping),
  postponed lambda analysis, builder inference, callable references with
  adaptation, integer literal types, `@kotlin.internal` resolution annotations
  (`OnlyInputTypes`, `HidesMembers`, `LowPriorityInOverloadResolution`).
- **Smart casts**: the `cfa` module's CFG and lattices, re-keyed from names to
  local, property and receiver identities.
- **Image symbols**: the base image carries a serialized symbol table and type
  store, loaded lazily, so a program is resolved against the base without
  re-resolving it. `FORMAT_VERSION` bumps with it.

### Pipeline

```
parse -> serialization (generated source) -> sema -> bridge -> lowering (with compose)
```

Serialization stays ahead of sema because it generates Kotlin source, which
sema resolves like any other. Alias expansion, renames, the merge into one
file, lifting, expect-default copying and the `field` rewrite are deleted:
sema answers each of them by identity. Compose becomes part of lowering and
keys on resolved `@Composable` symbols instead of name sets. `typeck` keeps
running for diagnostics until its checks are ported onto sema, and lowering
stops reading any of its tables at the switch.

## The work

Status values: `todo`, `doing`, `done`. Sizes are lines of Zig, new (+) and
removed (-), and are the bound on how long the related failures last. The
order below is the order of work in `docs/design/SEMA-LOWERING.md` section 6.

### Foundations

| Id | Item | Size | Status |
|----|------|-----:|--------|
| `front/oracle` | `tools/sema-oracle`, a kotlinc FIR extension built with the pinned kotlinc, prints every resolved call and name (offset, callable id, dispatch and extension receivers). `scripts/sema-oracle-compare.sh` diffs it against `klio sema --dump` over a corpus and `sema-oracle-triage.py` groups the disagreements. | +0.8k | done |
| `front/census` | `klio sema` over the base, the installed packs, or files: unresolved references by reason and by file (`--sites`, `--each`, `--dump`). | +0.6k | done |
| `front/node-ids` | `ast.NodeId`, dense per file, on every resolution-bearing node, assigned by the parser and by any pass that synthesizes nodes; `ast.checkIds` asserts uniqueness in Debug. Ids are inert until `sema/output` keys on them. | +1.5k | done |

### Sema

Strict from its first line: a reference sema cannot resolve is a diagnostic
naming the construct and the reason, never a guess.

| Id | Item | Size | Status |
|----|------|-----:|--------|
| `sema/resolve` | Types, headers, scopes, the receiver tower, calls with constraint inference, lambdas, smart casts, operators and every expression form (the former `sema/types` through `sema/expressions`). | +9.7k | done |
| `sema/tail` | Close the census to zero over the base, every pack and the corpus, and the oracle disagreements sema owns. The open items are in the log. | +1.5k | done |
| `sema/output` | Per-file tables keyed by node id: call records with the argument-to-parameter map, solved type arguments, conversions and context arguments; name, receiver and type-test records; groups for `for`, destructuring, compound assignment, `when`, `try` and lambdas; the expression type of every expression; the `backing_field` name kind. Writes follow the muted and buffered rules. A new census reason, `unrecorded`, counts nodes without a record; `--dump` prints from the tables. Landed: records indexed by node with the `unrecorded` census (zero over the base, corpus and compose), `CallRec` details, records for `this`, returns, declarations, type tests, lambdas, destructuring, loop variables and callable references, lambda labels, and the typed lookups of `docs/design/LOWER-SEMA-PACKAGES.md` section 7. | +2.5k | done |
| `sema/facts` | Override links, annotations by identity, `@Composable` on declarations and function types, context arguments at call sites, per-layer `addFiles` with `FunctionN`/`SuspendFunctionN`/SAM symbols made in the base layer so the base symbol prefix is deterministic, a Kotlin declaration for every `__klio_*` and pack native, `NativeId` by symbol. Landed: override links, per-layer symbol order with eager function classes and SAM constructors and `prefixDigest`, annotations and `@Composable` by identity, context arguments, delegated members. | +1.5k | doing |
| `sema/image` | The base image serializes the symbol prefix, headers and type store, decoded lazily per class; a program parses nothing of the base. Until then a program re-collects the base from the source text the image carries and checks a digest. Landed, that interim: `lower_driver/base_image.zig` bakes the base alone (sema, `bridge.build` with the base layer, every body lowered) and serializes the bridge, the module and `Resolved` (natives rebound by table and key, `ClassDef`s rebuilt with `classDefOf`); a run collects the base, checks the prefix digest, decodes the image, resolves the program's bodies only, extends the bridge (`bridge.buildOver`) and lowers the program (`lowerProgramOver`), base bodies decoding on first use. Cached as `sema-base-<key>.klio-sema`, keyed by the binary and the base's text. | +3.5k | doing |
| `sema/tests` | Module tests per behaviour, and the acceptance facts below as sema tests. | +15k | doing |

**Exit:** the base source set, every shipped pack and the whole corpus resolve
with zero unresolved and zero unrecorded references, and the oracle agrees
with kotlinc at every call and name site of the corpus. The census and the
oracle are the measure here, and both run in seconds.

### Cutover

`lower/sema` lands green beside the old lowering. The switch is one commit;
the items after it are red until `cut/backends` and are bounded by their
sizes, about +9k and -112k in all.

| Id | Item | Size | Status |
|----|------|-----:|--------|
| `lower/sema` | The new lowering in `src/ir/lower` (`records`, `env`, `call`, `dispatch`, `name`, `operator`, `refs`, `types`, `classes`, `lambda`, `inline`) and `core/bridge` (every `ClassId`, `FuncId`, static, field and method slot allocated serially from symbols). The resolved `Inst` variants of design section 4 land beside the old ones with eval arms. Inline functions lower once and are instantiated from IR at each call site, lambda literals in place, so `return`, `break` and suspend calls in inline lambdas are the caller's. Local classes and object expressions lower at build time. Not wired in; an executing unit test per construct and per acceptance fact, driven over the miniature base. Work packages and file ownership: `docs/design/LOWER-SEMA-PACKAGES.md`. | +13k | done |
| `cut/switch` | Sema runs at bake and at run and lowering reads only its records. Deleted: the old lowering's derivers, ladders, pickers and link passes (design section 5), the typeck bridge (`computeEagerCalls`, `pending_eager_*`, `ExternDecls`, `KLIO_EAGER_*`), the pre-sema syntax passes, the compose AST pass, the by-name `Inst` variants with their eval and cgen arms, the AST splice, `site_census`, the resolution ratchet and the by-name audit sweeps. The comptime guard refusing names, `TypeRef`s and memo words in `Inst` lands; `FORMAT_VERSION` bumps. | +1k / -76k | done; nothing emits a by-name `Inst` variant, their deletion is `cut/runtime`'s |
| `cut/compose` | Compose as lowering: hidden `$composer`/`$changed` parameters and arguments, restart, replace and movable groups, `$dirty` and the skip gate, stability from class symbols. Group keys keep their function of the source range. | +3k | done |
| `cut/objects` | Instances hold a fixed slot array sized from the class layout, and the instance header carries the `ClassId`; a value tag maps to a `ClassId` for host values; dense per-class vtables and interface tables whose entries are `FuncId` or `NativeId`; host-backed classes get tables like any other class; native code calls back into Kotlin through well-known slots (`toString`, `equals`, `hashCode`, `iterator`, `hasNext`, `next`, `compareTo`, `compare`). Deleted: the `{name, value}` field lists, the FQN to `ClassId` lookup copied into six places, `method_dispatch`'s hash map, `irMethodWalk`, the `"type.name"` intrinsic probe ahead of the vtable, the `IntrinsicHost` by-name callbacks. | +3k / -2k | doing |
| `cut/runtime` | Every runtime path that resolves by name. Deleted: the member ladder (`callMemberInnerStatic`), the getter ladder (`getFieldInner`), `setFieldInner`, `execCallMemberOrGlobal`, `execArmLoadFromThisOrGlobal`, the extension fallback walk and extension-property resolution, `qualifiedThis`, the enclosing-this chain and its closure and coroutine snapshots, `callNamedOverload`, `pickMethodOverload`, `resolveInstanceMethod`, `overload_match`, constructor scoring and `newInstanceNamed`, by-name `lookupGlobal`/`storeGlobal`, by-name `instanceOf`, per-call named-argument binding, the run-time memo fields in `Inst` and the code that serves them, the argument-signature folds, the name-keyed registry maps and `ProgramImage` caches the VM reads, run-time `lowerMethod`. About 3.4k lines of native bodies move to `NativeId` keys rather than dying. | +1k / -32k | doing |
| `cut/backends` | cgen and the JIT read the resolved variants; a shape they do not handle declines to the interpreter. | +1k / -1.5k | cgen done (native C gate 41/41, `native_coroutines` refused); no sema body reached the JIT, which leaves the build for `archive/jit/` as reference; the leaf tier goes with `engine/one` |

**Exit:** everything builds with the name guard in place, and every
program that builds runs without a runtime name lookup on any call, field,
receiver or global path.

`cut/runtime` lands in this order:

1. The host's by-name callbacks go: iterator protocol and coroutine
   objects through well-known slots and objects, serialization's
   fallback through `Resolved.serializers`, and `invoke_method`,
   `get_property`, `construct_named`, `lookup_global` leave
   `IntrinsicHost`. About +300 / -800.
2. The snapshot map's whole-put fast path as a fronted try, reading the
   compose statics by declaration. About +300 / -250.
3. The by-name `Inst` variants, their eval, fused, codec, disasm and cgen
   arms, the run-time memo fields, the enclosing chain, `compose_fast`
   and `site_census`; `FORMAT_VERSION` bumps and the name guard lands.
   About -12k.
4. The ladders nothing reaches after that: `host_call_member`,
   `host_fields`, `host_instances`, the by-name halves of the call and
   global paths, `overload_match`, `applicability`, the module's by-name
   resolvers and registry name maps, `ProgramImage`'s link caches and
   `method_dispatch`. About -35k; about 3.4k of native bodies move under
   declaration keys.
5. The fixed slot array: `InstanceData` holds `[]Value` by layout. About
   +1k / -1.5k.

### Green

| Id | Item | Status |
|----|------|--------|
| `green/corpus` | `itest-e2e`, the example corpus and the stdlib commontest sweep at their floors. | done: corpus 551/551 |
| `green/packs` | Every pack suite in `plans/pack-suites-to-green.md` at or above its floor, compose runtime at 100%. | doing |
| `green/box` | The kotlinc box corpus at or above its ratchet. | doing: 6262/90 ratchet, the old path 6019 |
| `green/measure` | Re-take the headline costs, the executed dispatch census and `benchRecompose`, before and after, in the log below. | todo |

### Speed

After `cut/runtime`, and part of done. The acceptance is the compose
runtime's throughput-bound tests: `derivedStateOfLeak`,
`validatePotentialDeadlock` and `resumeOnBackgroundThread` pass under the
fleet's 10 s runTest cap, with before and after numbers for them, fib,
bench_oo, bench_fn and `benchRecompose` in the log.

| Id | Item | Size | Status |
|----|------|-----:|--------|
| `engine/one` | One interpreter loop over one representation. The leaf, fused, bytecode and framed tiers merge; the per-`Func` verdict bytes and their classification go. | -5k | todo |
| `stack/value-stack` | One contiguous per-thread value stack; frames are windows into it; arguments stay where the caller computed them; the collector scans the stack; `Frame` becomes a header. No allocation on the call path. | todo | todo |

### After done

The long tail: the box failures left under the ratchet and any suite item
outside the floors, then `retire/typeck`.

| Id | Item | Size | Status |
|----|------|-----:|--------|
| `retire/typeck` | The checker's diagnostics run over sema's records; `src/typeck`'s resolution core, `src/types`' string `Type` and `src/resolver` go. | +5k / -15k | todo |

## Instruments

- **Sema census** (`front/census`): unresolved references by reason. Zero is
  the exit of the sema section, and it stays a gate step afterwards.
- **kotlinc oracle** (`front/oracle`): per-site agreement with kotlinc on the
  corpus. A disagreement is a sema bug, fixed by mechanism, with the site added
  as a sema test.
- **The name guard**: the comptime test on `Inst` is the permanent proof that
  the IR resolves.
- **Execution cost**: `scripts/headline-costs.sh`, the executed dispatch
  census, `benchRecompose`, with the interleaved CPU-time A/B in
  `plans/pack-suites-to-green.md`. These are the numbers the goal is measured
  by.
- **The gate**: `scripts/gate.sh`, run with nothing else touching
  `.zig-cache`, at the end of the cutover and of every item after it. Its
  resolution ratchet step and `plans/resolution-ceiling.json` go with the
  by-name variants, since there is nothing left for them to count.

The first campaign's lessons about measurement stand: a counter must be proved
to fire before its zero is trusted, a threadlocal counter under the worker pool
under-reports, an audit that fires only when both sides agree on the kind of
answer proves nothing, a total can hide a swap between kinds, and
`corpus_check --no-rust` checks exit codes only (`itest-e2e` checks output).

## What must not weaken

1. No test is deleted, skipped, `xfail`ed, renamed around, or weakened. Suite
   counts in `plans/pack-suites-to-green.md` are floors at the end of the
   cutover.
2. No gate step is removed or made non-blocking, except the resolution ratchet,
   which is replaced by the name guard and the sema census.
3. A golden file is re-baked only when the changed value is provably an opaque
   implementation detail, with the proof in the commit message.
4. Diagnostics are not casualties: a knob whose subject is deleted is removed
   from `docs/development/debugging.md` in the same commit, and user-facing
   diagnostics keep working through the `retire/typeck` port.

## Acceptance facts

Semantics the first campaign established one failure at a time. Each becomes a
sema or lowering test, so the rewrite cannot re-learn them the same way.

**Properties and storage**
- A body property's slot holds its seed until its initializer runs; an open
  base's body property is written partway through subclass construction.
- The nearest class declaring a property decides whether a cell or an accessor
  answers, whichever class owns the cell (`Counted : Tagged` overriding a
  constructor `label` with a getter).
- An accessor-only override contributes no slot; `override var x get() set()`
  produces no stored field.
- A primary-constructor `override val` is a declared member of its class
  (`TextContent.status` overriding `OutgoingContent`'s `get() = null`).
- A host-backed class keeps its state in the host object (`Log : ArrayList`).
- A `by`-delegating class forwards the member to its delegate.
- A property can have several cells (private shadow, override cell); a read
  takes the nearest owner's.
- A read and a write of the same property can resolve differently (plain read,
  setter write).
- A value-class accessor takes the underlying value, not the box.
- A class that plainly stores a property answers from its cell even when a
  base declares a getter.
- A companion constant (`Color.Unspecified`) lives in the companion
  singleton's slot.
- An inline extension property (`Int.dp`) has no accessor; it is spliced.
- Properties do not overload; an abstract property has no getter body.
- `UIntArray.size` is a declared property over `storage`.

**Super, type tests, the class graph**
- A `super` call is non-virtual; `super@A` picks the instance, `super<A>` the
  supertype; the class supertype precedes interfaces; an interface that
  restates a method is not its declarer; a bodyless header is not a target.
- `Any` is every class's supertype; a missing ancestor edge makes `is` false
  and `as` throw.
- `is T?` admits null; `is List<String>` is erased.
- Forward-referenced supertypes are supertypes.

**Members, extensions, overloads**
- A member beats an extension only when applicable, not merely by arity
  (`Random.nextLong(LongRange)`).
- A non-`operator` member does not serve a convention call.
- An extension's declared receiver must accept the receiver's type
  (`DeepRecursiveFunction.invoke` must not take closure invokes).
- A member function shadows a top-level function for a bare call.
- Extension scope tiers decide between same-named extensions
  (`kotlin.ranges.contains` against `androidx.collection.contains`).
- An integer literal is not evidence for a `Double` parameter.
- The same simple name in several packages (`AtomicInt` in three) resolves by
  import scope; a file's package is not its import scope.
- A host intrinsic supersedes the source getter (`COROUTINE_SUSPENDED`).
- A capitalised call checks the constructors' arities before a companion
  `invoke` (`Shape(3)` is `Shape.Companion.invoke(3)` when no one-argument
  constructor exists).
- A `@Deprecated(HIDDEN)` constructor is not offered to source; a class with
  no parameter list has the implicit no-argument constructor.
- A qualified path is package-qualified only when its head is a package.

**Receivers, lambdas, inline**
- In `x.let { p -> }` the subject is a parameter, not a receiver; `this@let`
  names the innermost `let`.
- A spliced subject that `this` reaches precedes the body's own receiver
  (`with(other) { 5.scaled() }`).
- A fun interface's `this` is the interface; a member-extension SAM hands its
  extension receiver to the literal.
- A lambda used as an untyped initializer, a branch or a statement has no
  receiver; a receiverless lambda invoked through a receiver keeps its
  captured `this`.
- A receiver that extends the wanted class is that instance (`Density` behind
  `MeasureScope`).
- A member extension has a dispatch receiver and an extension receiver.
- An inner class's constructor binds `this` to the enclosing instance; a nested
  class has no outer instance.
- Context parameters are passed by the caller.
- A class value invoked with receiver syntax is its constructor with the
  receiver as the first argument (`::Char` as `Int.() -> Char`).
- A composable call takes `$composer` and `$changed` after the declared
  parameters; for `suspend R.() -> T` the extension receiver precedes the
  value parameters and the continuation follows them.

**Runtime and image**
- A string subscript's fast path is ASCII-only.
- Whatever lowering binds must not depend on the order the body pool runs in.
- A baked site's side table is rebuilt at image load, and a new instruction or
  layout field bumps `FORMAT_VERSION`.

## Open correctness bugs carried

- `Shape(3)` constructs `Shape` where kotlinc calls `Companion.invoke`.
- The `operator` modifier is not recorded in the IR.
- An `override val` with an expression getter infers its own type (unconfirmed
  against kotlinc).
- cgen lays `AbstractCoroutine` out without its superclass prefix, and ignores
  `ctor_pick`.
- `TimeoutTest.testSharedFlowCancelledNoTimeout` fails with `call_value on
  kotlin.Nothing`.
- `SnapshotStateMapTests.concurrentMixingWriteApply_set`,
  `CompositionTests.derivedStateOfLeak`.
- `zig build test` aborts intermittently after the `Value size=16` line.
- The extension index is rebuilt lazily during parallel lowering.
- The compose runtime plugin suite fell from 1402/2 to 903/353 at 3a769883
  (the implicit-receiver walk at lowering; bisected over 7aa9c30e..7a6e8f4b,
  the packs ruled out). `CompositionLocalTests.testSingleProvideDefaultValue`
  fails with `Vm::call_member predicate on $anon$10`: a bare `predicate(...)`
  call on an inline function's lambda parameter in the coroutines pack
  (`[bare] predicate -> NONE ... known_none=true`) becomes a by-name member
  call on the anonymous object in scope. The walk and the splice it reads are
  what `cut/switch` deletes; the new lowering calls the parameter by record.
  The `MovableContentTests` and `GroupSizeValidationTests` failures (81 in
  shard 0/3 on 2026-09-24, the same before 2026-09-23's commits) are the
  same walk: `toSlotTable.read { withReader(this@read) {...} }` in
  `LinkComposer` lowers with no receiver shape, the namesake consensus
  between the gap and link `SlotTable.read` disagrees, and the lambda's
  receiver lands in its `this` capture (`get_field reader` on
  `SlotTableReader`).
- The stdlib sweep fails `StringTest.stringFromCharArray` and
  `stringFromCharArrayUnicodeSurrogatePairs`, already before 2026-09-23's
  commits: inside a class, `String(chars)` lowers to a `CallMemberOrGlobal`
  whose member side answers with the receiver's `toString`, though the static
  bind names `kotlin.text.String(CharArray)`. The same shape as the entry
  above (a bare call made by-name on the implicit receiver), not bisected.
  The new pipeline calls it by record and prints the string.

Sema subsumes the first four: each is a resolution answer it gives by
construction, and each gets a test.

## Done means

1. Every item in Cutover, Green and Speed is `done`.
2. `Inst` declares only resolved variants and the name guard compiles.
3. The sema census reads zero over the base, every pack and the corpus, and
   the oracle agrees with kotlinc on the corpus.
4. `scripts/gate.sh` is green, run with nothing else touching `.zig-cache`.
5. Every suite count in `plans/pack-suites-to-green.md` is at or above its
   floor, and the compose runtime suite is at 100%, its throughput-bound
   tests included.
6. The log carries measured before and after numbers for the trivial
   instruction, the cheapest activation, the executed dispatch census and
   `benchRecompose`.

## Log

Newest last. One line per landed item: what moved, what was deleted, the
measurement.

- 2026-09-23: plan rewritten around sema. Baseline for the cutover: `Inst` 50
  variants, 110 by-name emission points in lowering, about 34k lines of
  lowering-side guessing and 35k lines of runtime by-name resolution.
- 2026-09-23: `sema/types`, `sema/headers`, `sema/scopes`, `sema/tower`,
  `sema/calls`, `sema/lambdas`, `sema/operators`, `sema/expressions` and a
  first `sema/smart-casts` landed as one resolver (about 9k lines in
  `src/sema`). `front/census` is `klio sema` (with `--each`, packs loaded from
  the klio data home, `KLIO_SEMA_TRACE=<name>` for candidate rejections);
  `front/oracle` is `tools/sema-oracle` with `scripts/sema-oracle-diff.py`.
  Measured, bodies resolved per stack (resolved / unresolved, time on one
  thread): stdlib 57 386 / 13 (1.2 s); compose and stdlib, 1 112 files,
  234 413 / 954 (4.3 s); ktor 78 540 / 202; kotlinx.coroutines 72 598 / 156;
  kotlinx.serialization 62 319 / 92; kotlinx.datetime 74 427 / 207. Example
  programs without packs: 21 175 / 185 over 461 programs.
- Source defects the analysis surfaced, to fix in the sources rather than
  model: 16 `minOf`/`maxOf` and `toSingletonMapOrSelf` klio actuals missing
  the `inline` their expects carry; `kotlin-coroutines/Intrinsics.kt`
  redeclares `suspendCoroutineUninterceptedOrReturn` (declared with a body
  upstream), declares its actuals without `actual`, and overloads
  `createCoroutineUnintercepted` on `suspend R.() -> T` and `suspend (P) -> T`,
  which Kotlin treats as one type; `__klio_co_*` natives and pack natives
  (`__kxco_*`, `__kktor_*`, `__kxdt_*`) have no declaration; pack builds
  exclude files other pack files import (`GraphicsLayer`, animation
  `fadeIn`); `UStrings.kt`/`UNumbers.kt` are not in the base set; examples
  such as `ctor_param_captured_by_member.kt` are not valid Kotlin.
- 2026-09-23: the cutover design landed (`docs/design/SEMA-LOWERING.md`):
  records keyed by per-file node ids, a serial symbol-to-id bridge, 37
  resolved `Inst` variants, inline functions instantiated from IR, compose as
  lowering. An audit puts the lowering-side guessing at 62.8k lines, not 34k;
  about 21k lines of translation survive. The work table follows its order.
  `sema/tests` gained resolution tests that assert the declaration recorded at
  a marked site (26 module tests).
- 2026-09-23: `klio sema` runs the serialization pass before the analysis
  and takes `--feature` (and, under `--each`, a program's `// Run with:`
  flags), so generated serializers and pack features are analyzed as the
  pipeline will see them. Sema gained context parameters, constructors
  through type aliases, inner-class types that carry their outer's
  arguments, constructor references, explicit backing fields, bounded
  overloads and duplicate-import handling. Example corpus, 594 programs:
  program sites unresolved 508 -> 124, resolved 26 457 -> 32 461; base
  stdlib 54 044 / 47 (all source defects); compose + material3 1 861 files,
  375 010 / 1 867, most of it the pack curation gap below. 40 module tests.
- Two source-set findings. The compose packs exclude files other pack files
  import (`androidx.compose.ui.graphics.layer.GraphicsLayer`,
  `GraphicsContext`, `androidx.compose.animation.*`, `androidx.annotation`
  and the `ExperimentalComposeUiApi` family: 218 import sites), and most of
  the compose census follows from them. 25 corpus examples do not compile
  with kotlinc 2.4.20 (the oracle's `oracle.stderr` lists them): some use
  language features that need a later version or an experimental flag
  (name-based destructuring), the rest are invalid Kotlin that the current
  interpreter accepts (`ctor_param_captured_by_member.kt`,
  `vararg_middle_defaulted.kt:11`, `typealias_expansion.kt:45`,
  `sam_conversion.kt:19`, `function_type_receiver_overload.kt:9`, ...).
  Sema's census agrees with kotlinc at those sites; the examples need to
  become valid Kotlin or carry the flags they depend on.
- 2026-09-23: `front/node-ids` landed. Every expression, block, statement,
  catch, declaration, parameter and `$name` template part carries an
  `ast.NodeId`, numbered by the parser in source order from 1, with the next
  free id in `KotlinFile.node_count`; the serialization pass parses its
  splices from the host file's count and no longer writes into the original
  file's nested members or bodies. `ast.checkIds` runs in Debug after the
  parse and after that pass. `Expr` stays 80 bytes: a call's labels and type
  arguments sit behind one box, shared per argument count for positional
  calls; `Decl` grows 256 -> 264. Image `FORMAT_VERSION` 85. Commontest sweep
  149 files, 2 466 passes, identical to the tree without it; `itest-e2e` green.
- 2026-09-23: `lower/sema` is broken into packages, with its record API,
  calling convention and order of work, in `docs/design/LOWER-SEMA-PACKAGES.md`.
- 2026-09-23: the base set's source defects are fixed. The numeric
  `minOf`/`maxOf` actuals are `inline` like their expects; `intercepted`,
  `createCoroutineUnintercepted` and `startCoroutineUninterceptedOrReturn`
  are marked `actual` with their expects' `inline` and visibility, and the
  `suspend (P) -> T` overloads that clashed with `suspend R.() -> T` are gone;
  klio's `kotlin-coroutines/Intrinsics.kt` replaces upstream's
  `coroutines/intrinsics/Intrinsics.kt` in the base set, declaring
  `suspendCoroutineUninterceptedOrReturn` with upstream's `suspend inline`
  signature over klio's body; the `__klio_co_*` calls import their natives,
  and `__kxco_dispatchIo` and `__skia_c_draw_text2` gained declarations;
  `UStrings.kt` and `UNumbers.kt` joined the base. Splicing the intrinsic
  exposed three interpreter bugs, fixed at the root: a host-bound top-level
  property's getter was bound statically (two `COROUTINE_SUSPENDED` values),
  a declined extension splice left its solved bindings for the next splice
  (heap corruption on the body pool), and a spliced literal took the
  innermost inline function's name as its label. `klio sema --bodies base`
  68 381 resolved / 47 unresolved -> 68 680 / 1; with packs, a
  kotlinx.coroutines program 84 198 / 135 -> 84 498 / 68 and a compose ui
  graphics program 253 778 / 695 -> 254 080 / 627, no native unresolved.
  The one base site left, `toSingletonMapOrSelf`'s `actual inline` over a
  plain `expect`, is valid Kotlin: kotlinc requires only the expect's
  `inline`, `infix` and `operator` on the actual, and sema compares them for
  equality. Commontest sweep 149 files, 2 466 passes, identical; examples
  identical; coroutines and compose ui censuses unchanged, ktor one more
  pass; `itest-e2e` green.
- 2026-09-23: the `lower/sema` skeleton landed. `Inst` gains the 23
  variants of the packages' section 2.3 at its end (the six reshaped ones
  `R`-prefixed), `CatchHandler.class_raw`, `NativeId`, `StaticId` and
  `NO_FUNC`; the run-time tables are in `ir/core/resolved.zig` behind
  `Module.resolved`, and `ClassDef.ir_class` names an instance's class.
  `execInst` routes each new variant to `ir/eval/resolved.zig`, the fused
  tier rejects them, the site census counts them plain. Every public
  function of packages A to E is declared and compiles: `ir/core/bridge.zig`,
  `ir/lower/sema/` (the `Builder`, its record lookups over `sema.output`,
  and the expression and statement switches routing every AST kind), and
  the `lower_driver` module, whose tests run under `zig build test`. `ir`
  depends on `sema`. Image `FORMAT_VERSION` 87. Commontest sweep 149 files,
  2 466 passes, identical to the tree without it; `itest-e2e` green.
- 2026-09-23: the base source set resolves with no unresolved reference
  (70 386 resolved) and the `unrecorded` census is zero over the base, the
  example corpus and compose. Sema gained typed call records, records for
  `this`, returns, declarations, type tests, lambdas, destructuring and
  references, lambda labels, `KFunctionN` reference types, common
  supertypes that join arguments, cast smart casts, low-priority overloads
  and literal joins. Pack censuses, unresolved sites: compose with
  material3 1 416 (from 1 867; the pack source-set gap is being closed),
  kotlinx.datetime 94 (from 234), ktor http 108 (from 261), kotlinx
  coroutines with ktor io 42 (from 164), kotlinx.serialization 22 (from
  111). Oracle: 17 217 sites agree, 59 sema-owned disagreements (from about
  200). The `lower/sema` skeleton landed and packages A, B with E, C1, C2
  and C3 are being built in parallel against it.
- 2026-09-23: the compose packs are closed source sets: every import and
  same-package name their sources use resolves within the pack or its
  declared dependencies. `klio sema --bodies all examples/compose_material3.kt`
  1 511 -> 802 unresolved (resolved 453 976 -> 468 045), unresolved imports
  226 -> 0. A new `androidx.annotation` pack holds the androidx annotation
  markers the modules and androidx.collection import; the animation pack
  vendors its whole commonMain; ui-graphics carries `GraphicsContext`,
  `GraphicsLayer` (properties only, klio composites no layers) and a Kotlin
  `PathMeasure`; the runtime pack declares the runtime-annotation markers
  and runtime-retain's store; foundation's text layer is closed over klio's
  platform. The rest of the compose census is sema-side with its cascades,
  and one klio source defect: `kotlin.concurrent.Thread` declares no
  `currentThread()` though the host serves it. The
  resolution ceiling is re-recorded for the larger sources: cold over the
  590 programs on main, main's packs count 2 244 828 unresolved sites and
  the closed packs 2 289 428 (+44 600, with +887 268 resolved), because
  every compose program lowers the files the packs used to leave out; with
  `compose_pathmeasure` the corpus is 591 programs and 2 312 055.
- 2026-09-23: the non-compose packs and the base platform surface. Pack
  censuses, unresolved sites (base excluded): kotlinx.datetime 87 -> 21,
  kotlinx.coroutines with ktor io 42 -> 17, ktor http 96 -> 24, every ktor
  feature together 254 -> 92, kotlinx.serialization json 16 -> 14; the two
  base examples 3 -> 0. What remains is sema-side (flow smart casts,
  contracts, companion references through the class name, suspend
  conversion, typealias star projections, a qualified reference to a
  same-named alias) plus ktor-io's `Input` alias, which reads `Source`
  unqualified at `fun Input.readAvailable` in the pack while a program with
  the same text resolves. The packs now carry what their sources name: the
  datetime serializers, and klio's LocalDate / LocalTime / LocalDateTime
  actuals carry the expects' `@Serializable(with = ...)` (the serialization
  pass generates for an actual, never an expect); ktor-io's pools,
  `ByteOrder`, `JvmSerializable`, `Closeable` and error aliases; ktor-utils'
  stack frames, `internal`, `cio`, `TreeLike`, `NetworkAddress`; the client's
  proxy, timeouts, SSE and upgrade content with a new `http-cio` feature;
  the server's hostname escape as a klio actual. The base declares the JVM
  members programs use: `StringBuilder.setCharAt`, `Throwable.stackTrace`
  over `java.lang.StackTraceElement`, and `Thread` is `java.lang.Thread`
  with its statics, now that java.lang is a default import.
  `CancellationException(message, cause)` keeps its cause, and the runtime
  links a superclass through the declaring file's imports (coroutines'
  `NodeList` took ktor-utils' namesake `LockFreeLinkedListHead` once both
  were packed). The resolution ceiling is re-recorded cold over 593 programs
  (the two new examples) at 2 321 641 unresolved sites; main's tree counts
  2 321 180 over the same programs with `datetime_serializers` failing, so the
  added pack sources and that example account for +461.
- 2026-09-23: sema closes most of the pack and corpus tail. Against packs
  rebuilt from source (`scripts/install-local-packs.sh`, `KLIO_HOME` at
  `.klio-local`): the example corpus, 599 programs, 453 -> 55 unresolved
  sites; compose + material3 1 116 -> 98; the base stays at 0. New in sema:
  smart casts follow the data flow (a block leaves its casts to the code
  after it, `if`/`when` join their completing branches, an assignment
  narrows a local `var`, `x ?: return`, `r?.m != null` and `r?.m is T`, a
  safe call's arguments see the receiver non-null); contracts
  (`returns() implies`, `returns(true|false) implies`) read from the
  callee's body; an actual's parameters link to the expect's resolved
  defaults (`ParamInfo.default_from`); a delegate infers from its
  property's declared type; lambdas in branches of an argument and in an
  indexed set take the parameter's type; a SAM-converting overload loses a
  tie to a function-type one; a spread needs a vararg; `e!!` passes its
  expected type on; unqualified `super` takes the most derived override;
  suspend conversion of function values; star projections of type
  aliases; qualified type aliases; a local function does not hide an outer
  value; member extension properties coexist with plain ones; inner
  classes built on an extension receiver; extension properties of
  function type invoked on their receiver; `java.lang` and `kotlin.jvm`
  are default imports. The compose runtime plugin suite fell from 1402/2
  to 903/353 at 3a769883 in the old lowering (see the open bugs), and
  `klio run --sema-pipeline` runs 168 of 537 corpus programs end to end
  on the new path.
- 2026-09-23: first timings of `klio run --sema-pipeline` (ReleaseFast,
  `KLIO_JIT=0`, user time). Hello world: 20 ms on the image path, about
  240 ms on the new path, which analyzes and lowers the whole base every
  run; the bake of the lowered base and the sema prefix digest (the cutover
  base image) closes that. `fib(32)`: 0.84 s old, 2.1 s new: the resolved
  call instructions run on the frame interpreter without the fast tiers
  the by-name path had. Five million allocations with a member call each:
  4.7 s old, 4.0 s new. Resolution agreement with kotlinc over the corpus:
  17 266 sites match; of 869 differences 816 are the JVM-only `println`
  overloads and 28 JVM-declared members; sema's own are six object
  qualifiers kotlinc prints and klio need not evaluate, and three members
  klio declares as extensions. The census: base 0, corpus 55 (invalid
  examples being made valid), compose + material3 14.
- 2026-09-23: sema census against packs rebuilt from source: the base 0;
  the plain corpus 0; the corpus with packs 10, all in
  `file_private_collision`, a multi-file program `--each` analyzes a file at
  a time; compose + material3 1. The one left is
  `TargetBasedAnimation(..., typeConverter = TwoWayConverter({ it }, { it }))`
  (Animation.kt:116): the argument resolves tentatively by builder inference
  with both variables fixed from their declared bounds, where kotlinc takes
  them from the constructor's parameter. Telling a bound that came from a
  declared bound apart from one the lambda's body supplied needs bound
  provenance in the constraint system; `keyframes { 0f at ... }` is the case
  that must keep resolving tentatively. Traced further (a standalone
  `Conv({ it }, { it })` passed to a generic constructor reproduces it): the
  first lambda's input is left open as a builder variable and its body only
  relates it to the other variable (`T <: V`); the second lambda's input is
  then fixed in its trial from a chain that ends at `V`'s declared bound, so
  its hint is `(Vec) -> Vec` and the guess reaches `T` through the lambda's
  type. Flagging a lambda input fixed at a declared bound misses it (the
  variable is fixed from a lower bound whose own fix was the guess); the
  provenance has to follow fixes through bounds. Oracle over the corpus: 18 503 sites
  match; sema's remaining differences are representation (object qualifiers
  kotlinc prints, inner-class outer receivers printed as extension
  receivers) and three members klio declares as extensions.
- 2026-09-23: the kotlinx-io `AbstractSourceTest` crash under
  `KLIO_GC_THRESHOLD_KB=512` was a missed write barrier, not a fused
  register. A field store lowering had claimed a slot for wrote through a
  shared borrow, which runs no barrier, so a tenured `Buffer` took a nursery
  `Segment` into `head`/`tail` unrecorded and the next minor swept it.
  `InstanceData.storeSlot` stores under the exclusive borrow; the run is
  744/744. `KLIO_GC_VERIFY` checks every tenured cell's nursery children
  after each minor mark and names the class and field of a missed edge.
- 2026-09-23: the base image. A hello world on `klio run --sema-pipeline`
  (ReleaseFast) takes 50 ms, from about 210 ms: load and parse 31 ms,
  collect 3 ms, image decode 7 ms, the program's bodies, records, bridge
  extension and lowering 5 ms together. The bake is 170 ms, once per base.
  The non-compose corpus runs in 7 s (23 s before), 504/510 with the same
  failures as without the image. The parse of the base's source is now the
  largest cost; the end state of `sema/image` removes it. Program files take
  their source ids after the base so the image's spans hold in every run.
- 2026-09-24: the switch. `klio run` and `klio test` take the sema pipeline
  by default (`--legacy-pipeline` / `KLIO_SEMA_PIPELINE=0` select the old
  one while it is deleted); `itest-e2e` runs the corpus through the klio
  binary over a data home with every shipped pack installed, 539/541 with
  the loop JIT on and off. On the sema pipeline: kotlinx.coroutines 1299/0,
  atomicfu 67/0, the coroutines test group 73/0, androidx.collection
  1841/0, kotlinx.io 1191/0, kotlinx.datetime 519/0 (each at its floor),
  serialization 137/1, serialization json 740/7, ktor 461/3, compose ui
  452/0; the box census 6036/358 against the old path's 6044/349. The
  stdlib commontest sema census fell from 27 sites to 2. What deleting the
  old pipeline takes, the gaps the switch showed and the order of the
  deletion are in `plans/cutover-map.md`.
- 2026-09-24: the program-running suites are on the child runner
  (`src/itests/klio_child.zig`). Every suite that ran Kotlin in process on
  the name-resolving pipeline runs it through the harness, and every suite
  that needs packs runs in one data home the build installs every shipped
  pack into once per tree and harness (`klio-test-home`, 0.9 s warm), so no
  suite builds or installs a pack at run time (the compose plugin's three
  shards collided doing that). `src/parity` is gone; the kotlinc helpers
  are `src/itests/kotlinc_support.zig`; the bench times sema's stages and
  runs the harness end to end. The gate's ratchet phase is the sema census
  (`scripts/sema-census.py`, 23 s): base 0, corpus 0, packs 7 sites, all
  listed in `tests/sema-census-open.txt` (compose's `TargetBasedAnimation`,
  six in ktor server core); a site not listed fails, and so does a listed
  one that is gone. The stdlib sweep drops `--eager both`. Four test
  programs that only the old pipeline accepted are now as kotlinc 2.4.20
  compiles them. Measured on the sema pipeline, pass/total, each the
  suite's floor now: `group_parity_core` 379/392 (`parity_corpus_pinned`
  252/262, `parity_array_bulk_ops` 18/21, the other six at 100%),
  `group_parity_types` 182-183/191 (`parity_object_init` 29-30/37, one
  failure in `generics_advanced`), `group_parity_shapes` 85/91
  (`parity_stdlib_isolation` 0/4, one each in `properties_accessors` and
  `type_system_shapes`), `parity_threaded_litmus` 54-55/59,
  `group_lang_features` 95/103 (`context_parameters` 21/24,
  `resolve_ambiguity` 26/31, the rest at 100%), `differential` 2/2,
  `stdlib_image` 4/6, `e2e` 540/542 in both JIT modes, `bench` 10/10. In
  the shared home: the compose plugin 1394/10 with its three shards at once,
  stdlib commontest 2452/14 (all 14 fail the same in a home holding only
  kotlin.test), and every library census at its floor (coroutines 1299,
  atomicfu 67, androidx.collection 1841, io 1191, datetime 519,
  serialization 138, json 747, ktor 464, compose ui 452, all with 0
  failed). The 41 failures by cause:
  - Resolution, where kotlinc resolves (14): `String.toByteArray`,
    `String(ByteArray)`, `decodeToString` (2); the
    `kotlinx.io.bytestring.substring` import; JVM surface the base lacks,
    `toSortedMap`, `String.format`, `toDuration` (3); a suspend against a
    plain function-type overload is ambiguous; a vararg before a defaulted
    parameter through `::report`; the wrong overload for
    `List<List<String>> + List<String>`; member-extension shadowing of
    `String.startsWith`; `::deco` binds the extension twin;
    `(OnSomeObject<Any>::foo)(SomeObject)`; a smart cast of a context
    parameter and a local function's context parameter (2).
  - Lowering (8): a compound assignment to an object's property through
    its name, `Registry.total += 1`, has no name record (the four
    `parity_stdlib_isolation` tests and two `stdlib_image` tests, whose
    probe does it); `val SameType.x by ::prop` has no extension receiver;
    `arrayOf(a, b)` of a type parameter has no run-time type value.
  - Run time (11, and three intermittent): `String::length` as a value
    ("virtual method target is not executable", intermittently
    `tl_wakeup_hammer` too); a context-parameter `var` setter writes a
    field of a String; `expect fun intArrayOf` over an intrinsic has no
    body; initialization order, a superclass's companion before its
    subclass's (2), a forward-referenced top-level property, a file's
    initializers before `main` (`tl_early_error_with_thread`); threads,
    atomicfu updates lose increments, `ReentrantLock` is not exclusive
    (2), and intermittently an object initializes twice under racing
    threads and `tl_io_elastic` throws an NPE; a lambda's class
    `simpleName` is `Function0`.
  - Rendering (7): an uncaught throwable prints no stack frames or cause
    chain (4); no import hint for an unimported cross-package call; an
    `expect` with no `actual` fails at run time instead of being reported
    (2). The identical-signature pairs pass on sema's call-site
    `ambiguous` message, which no longer names the two declarations.
  - `tl_dispatched_internal_error_fails_run`: its unresolvable callee is
    now rejected before the run, as kotlinc does. The only internal error
    a valid program still reaches at run time is the evaluation-depth
    stack overflow, which Kotlin makes a catchable `StackOverflowError`
    and klio does not catch on either pipeline, so it is no honest
    trigger for the dispatched internal-error path.
- 2026-09-24: the box census on the sema pipeline, 4 jobs: 6141 passed and
  211 failed of 6352 selected, above the ratchet's 6036/315 (the old
  path's last run was 6019/332); the one test that run newly failed, a
  tailrec override leaving out an inherited default, passes since. The harness now puts its entry in a
  package of its own, so a test's own `main` is no overload of it, and
  excludes the 42 tests `IGNORE_BACKEND` mutes on the JVM; `main` is the
  entry point the JVM would run. The runtime and lowering fixes since
  6016/336: a file initializes when one of its functions is entered and
  before `main`; a failed body reports at its declaration or reference;
  `Obj.x += 1` through a qualifier; a lambda in an object reads the
  singleton; reified catch clauses; a prefix increment re-reads its
  target; tailrec calls leaving defaults out or returning from an inline
  lambda; `return Unit` in a constructor; data object `hashCode`; value
  class property order; annotation `toString`; dropped default field
  initializers. Of the 211: 103 sema resolution sites, about 95
  run-time divergences (the fun-interface/SAM group, coroutine function
  references and intrinsics, companion initialization order, IEEE
  equality under smart casts, adapted references), 5 lowering errors, 6
  VM errors, 6 parse errors.
- 2026-09-24: the old front end is deleted, net -86 437 lines: the
  name-resolving lowering (`src/ir/lower` outside `sema`, 55k), the old
  builder, prune and image (the codec stays as `interp_ir/codec.zig`), the
  compose AST pass, the old stdlib image, the typeck hand-off, the run-time
  lowering with the `AstLambda`/`BuildObject`/`RegisterClass` variants, and
  the legacy run, test and bundle paths. Every command runs on the sema
  pipeline, the transpiler and the native C backend included (435/435
  native sweep programs match the interpreter). The example corpus passes
  546/546; box 6141/211 against the old path's last 6019/332; every library
  suite at its floor. `cut/objects` has host members by declaration, natives
  calling back through well-known slots and dense vtables/itables
  (bench_fn 5.20 s to 3.34 s, the old path 3.6 s). Left of the old pipeline:
  the by-name `Inst` variants and their arms, `ProgramImage`'s link tables
  and the runtime ladders (`cut/runtime`), and typeck/resolver behind
  `klio check` (`retire/typeck`).
- 2026-09-24: bench_fn on main reads 3.14-3.19 s. A reported rise to
  3.88 s bisected to the transpile commit, which changed no interpreter
  code: `dispatchRun` tripled its samples from code placement alone, and
  later main recovered it. A/B against a fresh main build, never an older
  snapshot. The gc external-bytes delta moved off the thread-local block
  (every arg carrier paid a `_tlv_get_addr`), about 1%.
- 2026-09-24: a host fast path fronts a declaration's body and may
  decline into it (`Resolved.func_try`, bound by declaration key, carried
  by the image): the persistent collections' builders, scans and equality
  the compose snapshot tests spend their time in. Three of the four
  compose tests the old path passed only on its by-name fast paths pass
  again; `SnapshotStateMapTests.concurrentMixingWriteApply_clear` waits
  on a whole-put fast path that reads compose statics by declaration,
  with `cut/runtime`. bench_fn 3.02 s, fib and bench_oo at parity. The
  fused tier's `CallStatic` arm is an IPC-5 loop: an untaken check inside
  it cost fib 35% with the same instructions retired, so a decision about
  a call belongs in `funcRunsItsBody`, never in the fused arm.
- 2026-09-24: JVM run-time behaviour on the new path: an uncaught
  throwable prints the default handler's trace, a thread's goes to its
  handler as `Thread-N` and the run carries on, a failed initializer
  throws ExceptionInInitializerError then NoClassDefFoundError, an
  object or file initializer runs once across threads, a join counts as
  parked for a collection, recursion reaches JVM depths with the stack
  itself as the guard, and a captured trace keeps 1024 frames. Box
  6239/113. The native C gate is 39/2/1: klio_rt fills the old
  `method_dispatch` map and not the dense vtables the well-known
  callbacks read, and calls compiled lambdas by name; both go with
  `cut/runtime`. Open: `tl_dispatch_many` failed once under a 4-job
  litmus with a base getter bodiless and unbound, a publication race in
  lazy decode or binding.
- 2026-09-24: three compose runtime tests fail on throughput alone, with
  Compose's own frame counts: `derivedStateOfLeak` passes in 160 s
  (31 200 self-invalidating frames, about 1.9 ms a frame),
  `validatePotentialDeadlock` needs 196 s over its two composer modes (312
  frames of 200 Texts per advance), and `resumeOnBackgroundThread`
  finishes in 15 s against the fleet's 10 s runTest cap. The main thread
  is in broad interpreted dispatch, GC marking about 5%. They are the
  acceptance workloads for `engine/one` and `stack/value-stack`; the cap
  stays.
- 2026-09-24: the sema census counts what does not lower. The json and
  ktor probes had run without `--bodies all`, so pack bodies never
  resolved and the census read zero over bodies it never saw. `klio sema
  --all-packs --bodies all --lower` loads every installed pack; the gate
  lists each lowering failure as a site (`tests/sema-census-open.txt`,
  167). Sema sites: 0 everywhere. Lowering: 69 of 73 437 bodies fail
  (ktor route builders' reified lambdas unrecorded 12, expect-class
  defaults and superseded statics with no getter or storage 28, compose
  calls outside a composable 16, expect inline functions with no body 13)
  and 100 bodyless declarations have no native, nearly all compose
  platform surfaces (popups, dialogs, clipboard, atomics) and 3 ktor
  transforms.
- 2026-09-24: natives call back into Kotlin only through well-known slots
  and objects: `invoke_method`, `get_property`, `construct_named`,
  `lookup_global` and `lookup_global_func` left `IntrinsicHost`. The JIT
  left the build for `archive/jit/` (unchanged sources, the last commit
  that compiled them in its README), and taking its hooks out of the
  evaluator made every benchmark faster: fib 1.03 to 0.96 s, bench_oo
  1.46 to 1.27 s, bench_fn 3.13 to 2.97 s. The 37 `examples/jit_*.kt`
  stay as interpreter programs; their headers still describe the JIT.
