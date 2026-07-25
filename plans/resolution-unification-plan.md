# Resolved IR — Static Representation, One Engine, Tiered Execution

## North star

KLIO should turn scripts into **as static a representation as possible without
eliminating the runtime's dynamic nature.** Concretely:

- Loading a script produces a **resolved IR**: every call, variable access, field
  access, and type test carries direct, fully-qualified information (a `FuncId`, a
  method slot, a declaring-class + field slot, a `ClassId`) wherever that can be
  determined statically — not a name to be re-looked-up at runtime.
- Type checking / validation is an **optional** pass that (a) powers tooling
  (syntax/type/resolution diagnostics, go-to-definition, hover types) and (b) feeds
  its results back into lowering so *more* of the IR resolves statically.
- What genuinely cannot be resolved statically (runtime-polymorphic receivers,
  unknown scope-function receiver types) stays dynamic — but as a resolved
  *candidate set* or a *virtual slot*, never a bare name probe.

Stdlib code is ordinary code from the stdlib pack and resolves exactly like user
code; native intrinsics exist only as the backing implementation of a resolved
stdlib declaration, never as a parallel resolution path or a name-list shortcut.

This document supersedes the earlier RC-1..RC-5 sketch. Every root cause below was
confirmed against the current code with a live reproduction.

## The completeness invariant — no escape hatches

The purpose of this work is to **retire the entire accumulation of highly-specific
branches** that patch individual execution / stdlib / resolution-ordering issues.
Every one of those was added only because resolution was incomplete (RC-A), type-blind
(RC-B), or decided by a program-wide name set instead of the receiver type (RC-C). A
principled engine makes them unnecessary; their **deletion is the acceptance test** —
if a hatch cannot be deleted, the engine is not yet correct there.

Two things must be distinguished so this stays precise:

- **Legitimate** — a native intrinsic as the *backing implementation* of a resolved
  stdlib declaration, reached through the normal resolved symbol. These stay. The
  declaration is registered once; the engine routes to it by type.
- **A hatch (must die)** — any name-list, FQN pattern, or per-method special-case
  branch used as a *resolution shortcut* or a *dispatch fixup* that papers over the
  index / applicability / receiver-type resolver being incomplete. These go.

The catalog to delete (grown by the stdlib grind, not only the RC-H lists):
`isAliasName`, the two duplicate builtin-supertype tables, the three Throwable lists,
`class_member_names`, `prefer_member`, `concreteSibling`, `tailrec_fn_names` as a
gate, `shadowed_inline_names`, `isPrimitiveConv`, `CONTROL_INTRINSICS`,
`isKnownPackage`/`shippedFqnHead` discriminators, the broad-`kotlin.text.X` vs
`kotlin.text.StringBuilder.<m>`-specific registration split (dispatch by type removes
the need to register per-overload), the `.names` argument-name tables used to force a
binding the resolver should compute, and the assorted per-method dispatch fixups in
`host_call_member.zig` (the inline `.Range` `contains`, unsigned-array synth cases,
etc.). Two stopgaps from the post-flip sweep join the catalog: the `is_ctor_name`
class-exists gate in `execCallMemberOrGlobal` (a capitalized bare callee should be
resolved by the index, not a runtime capitalization heuristic) and the
`instance_prop_private` walk skip (a resolved property slot makes the virtual walk
itself unnecessary) — both deletable once P4/P7 land. The Compose pass contributes its
own set (RC-I): `NameSetOracle`, `active_sink_arity`, `active_sink_last_param`,
`active_sink_content_reach`, `active_composable_props`, `active_composable_getter_props`,
`active_inline_fns`, `active_factories`, `active_composable_receiver_names`, plus the
`isGeneratedComposeArg` absorber in `applicability.zig` that exists only to tolerate the
pass's wrong guesses. Each deletion is gated on `KLIO_RESOLVE_AUDIT` zero-disagreement +
the full sweep; a hatch that *can't* be removed pins the next fix.

The structural invariant this enforces: **resolution is a pure function of (call site,
sig index, receiver type)** — zero name-list lookups remain in the dispatch/resolution
path, and any two run-modes (lazy lowering, eager typeck, runtime) pick the same target
for every non-runtime-polymorphic call.

## Completed (landed P0–P9)

The static-representation, one-engine, tiered-execution work below landed and
is committed to `main`; the stdlib commonTest canonical passes 100% per-file
(2,150). Summary of what shipped:

- **Test-suite split**: `zig build test` (fast unit), `itest` (integration),
  `test-all` (both).
- **P1 — canonical index ordering**: top-level function headers register before
  class-body lowering, so method bodies resolve against the complete index;
  `memberShadowPossible` guard defers a resolved top-level extension a member
  could shadow to the runtime member-first walk.
- **P2 — one shared applicability engine** (`src/ir/applicability.zig`):
  `ArgShape`/`Score`/`SigView`/`builtinSupersOf`/`applicable()` is the live
  scorer for `pickOverload`, `pickNamedOverloadId`, `pickMethodOverload`, and
  `scoreExtCandidates`; the legacy scorers and the duplicate member
  builtin-supertype table are deleted.
- **P3 — `Module.resolveCall`**: bare-call lowering is one path
  (`buildArgShapes` → applicability-ranked `resolveCall` / one emit-form
  decision → the four pure emitters `emitCall`/`emitCallMember`/
  `emitMemberOrGlobal`/`emitValueCall`). The parallel captured-write lowerers
  and the lowering-side `preferredBareTarget`/heuristic audit ladder are
  deleted. `phaseBLadder`, `phaseBFallback`, `preferredBareTargetLike`, and
  their declared-arity/name reconciliation helpers are also gone: complete
  declarations pass through the shared applicability engine before the
  winning scope tier is selected. Authoritative source types then remove
  statically incompatible candidates through the identity-aware structural
  proof; additive eager heads cannot reject or finalize a target. A uniquely
  best proven declaration becomes an exact IR target, while uncertain
  multi-candidate families remain non-final rather than acquiring a
  declaration-order identity. Ordinary names and renamed imports now enter the
  same candidate enumeration; an alias contributes every declaration at its
  exact imported FQN, and calls, spreads, references, extensions, inline
  targets, captured-value precedence, and candidate-existence gates all
  consume that set. The alias-specific overload picker, direct import binding,
  qualified-call rewrite, and post-resolution override are deleted.
  A proven renamed-import extension becomes exact only after the complete
  receiver tower excludes applicable ordinary members; the imported extension
  itself is not treated as a member-precedence conflict. An incomplete tower
  retains member-first dispatch with the exact imported `FuncId` as fallback.
  Bound and unbound references retain the selected declaration identity
  through invocation; unbound extension references retain their type receiver,
  and expected receiver-function shapes survive unresolved generic returns.
  Bounded spread calls retain their source-scope package across synthesized
  frames. Inline substitution checks the source parameter shape before
  replacing a same-named function parameter, including inside nested lambdas.
  Ordinary extension calls stay member-first until builtin member
  surfaces join the canonical declaration index. Fixed overloads outrank equal
  varargs on both positional and named calls. Constructor/classifier candidates
  share the same scope tiers: a nearer classifier emits a static construction,
  and an
  equal-tier runtime comparison consumes the already-bound `ClassId` instead of
  reopening a simple name. Infix return inference uses
  explicit-receiver resolution. A known
  complete static extension/dispatch receiver tower now defers only for an
  applicable member or extension, while outer, companion, and incomplete scopes
  remain conservative. Generic receiver proofs preserve the structural owner
  and require complete, identity-safe bounds; dependent, cyclic, lossy, or
  ambiguously qualified evidence stays dynamic rather than becoming a false
  negative. A uniquely scoped generic extension such as
  `T.apply(block: T.() -> R)` binds the explicit receiver into the receiver
  lambda before its body lowers; the lambda's own `this` type then replaces,
  rather than inherits, an outer class receiver. Exact operator selection
  likewise excludes lossy eager type heads
  when a declaration-derived structural return type is available. Generic
  member headers preserve their owner arguments; class/function parameter
  scopes and inherited receiver projections are substituted before a return
  type becomes static evidence. Generic class shells expose those parameters
  before member headers reserve stable IDs, and ancestor projection carries
  source plus owner-qualified binding keys so generic overrides link to their
  executable bodies. Qualified classifiers remain distinct from same-named
  type parameters, and member-extension class parameters bind from the
  dispatch receiver rather than the extension receiver. Exact
  member-extension calls carry their declaration identity and an explicit
  dispatch-receiver register in `CallMember`; the ordinary receiver remains the
  extension receiver. The loop JIT carries the same exact identity and both
  operands through its host-call trampoline. Declaring-owner metadata uses class
  FQNs, and object or companion dispatch receivers load by exact `ClassId`.
  Runtime invocation consumes both operands without reconstructing the owner
  from a simple name or scanning the enclosing-receiver chain. An applicable
  ordinary member that lacks a complete exact or virtual ABI remains deferred
  and still shadows extensions. Class-owned type parameters use unambiguous
  owner-qualified identities in member parameters, returns, owner receiver
  arguments, and bound evidence, so method parameters can shadow their source
  name without corrupting receiver substitution or overload selection. Runtime
  applicability parses the same identities and receives complete `TypeRef`
  evidence, so qualified nominal types never collapse into same-named class or
  function parameters. Explicit generic constructor arguments remain attached
  to receiver evidence. Nullable receivers cannot bind non-null member
  operators ahead of nullable extensions. Control-flow non-null facts from
  `x != null` and the false branch of `x == null` preserve the local's complete
  declared type while removing nullability in `if` and `while` bodies, so
  overload resolution remains static after Kotlin smart casts.
  Compose bare declaration calls also stay source-shaped until this resolver
  selects their exact `FuncId`; lowering then completes only the selected
  declaration's synthetic composer ABI. Direct calls, inline splices, and
  deferred implicit-receiver probes share the same selected-parameter binding,
  including trailing lambdas across omitted defaults. Receiver-formed
  extension candidates require a real implicit receiver context rather than
  consuming an ordinary argument as a synthetic receiver.
  Reserved class shells now receive their exact numeric superclass edges before
  any method body lowers, so subtype applicability is independent of class
  declaration order. Private top-level headers likewise carry their declaring
  file during initial registration, allowing earlier class bodies to bind a
  later same-file declaration directly.
- **P4 — DeclSig substrate**: hierarchy-precise member-shadow
  (`memberShadowPossible`/`anyReceiverClassDeclares`, own + lifted-outer
  chains), declared-nullability evidence, and the `declared_recv` channel that
  constrains extension selection by the receiver's declared type.
- **P5 — distinct field storage**: private shadows and initialized
  `override val`s each keep their own cell under owner-mangled keys; `super.x`
  reads the base's cell.
- **P7 — eager half**: `TypeCheck.resolved_calls` records the overload
  checker's pick per call span. The consumption half (typeck-informed
  lowering) is tracked in `eager-resolution-plan.md`.
- **P8 — hatch deletions**: the tailrec name-list arm, `concreteSibling`,
  `isPrimitiveConv`, the duplicate builtin-supertype table, the `is_ctor_name`
  classId arm, and the `instance_prop_private`-era stopgaps are gone.
- **Class-owned lowering metadata is FQN-keyed**: constructor signature
  pre-registration and body-property initializer lowering resolve the exact
  declaring `ClassId`. A dependency's same-simple-name class can no longer
  donate unrelated constructor parameter types and change overload selection.
  `atomic_ctor_param_overload.kt` pins this through the atomicfu pack.

### Verification infrastructure (use these; the canonical alone is NOT enough)

- `python3 scripts/resolve_audit_sweep.py --build` — ~2 min: Debug rebuild + all 102
  stdlib commonTest files under `KLIO_RESOLVE_AUDIT`, greps
  `] (member|scorer|named|call2) ... divergent=1`. Zero divergence is the scorer-
  equivalence proof. THE fast loop for scorer/resolver changes.
- **threaded-litmus sweep** — ~1 min, REQUIRED for any resolution/dispatch change (the
  canonical has zero threaded-dispatcher coverage and missed a 25-program cluster):
  `ls tests/fixtures/threaded_litmus/*.kt | xargs -P8 -I{} sh -c 'timeout 25
  ./zig-out/bin/klio run {} >/dev/null 2>&1 || echo {} failed'`.
  Baseline: exactly 4 pre-existing failures (`tl_dispatched_failure_join`,
  `tl_dispatched_failure_no_join`, `tl_io_elastic`, `tl_early_error_with_thread`).
- Per-file stdlib run: `./zig-out/bin/klio test --only-file=<F> tests/
  stdlib_commontest_actuals/{PlatformActuals,EncodingActuals,JsCollectionFactories}.kt
  <same-dir sibling .kt files> <F>` (drop same-dir siblings ONLY if double-registration
  conflicts appear; the canonical harness dedupes).
- Milestone gates: `zig build itest-stdlib_commontest` (the canonical, ReleaseSafe,
  ~18 min) and `zig build itest` (everything; currently ~14+ min AFTER the wedge fix —
  runtime cost flagged to be addressed separately).
- Diagnosis pattern (worked 3×): A/B fixture sweep vs the pre-campaign baseline
  `d2a927db` → bisect ONE deterministic representative → `KLIO_OR_AUDIT` emit-site +
  run-arm diff between the two binaries → one env-gated debug print at the suspect
  fallback dumping the gate flags → minimal repro or direct fix.

### Host-builtin and lazy-mode boundaries (kept by design)

Not every name list is a hatch. `isAliasName`, `CONTROL_INTRINSICS`, the
Throwable lists, and the single builtin-supers table are the **host-builtin
boundary**: metadata about Zig-implemented entities the Kotlin index cannot
contain without declaring Kotlin headers for the whole host surface (P10 step 2
territory). The `class_member_names` fallbacks are the **lazy-mode conservative
boundary** (unknown receivers are real in lazy mode, per the two-modes design).
`shadowed_inline_names` is a dynamic per-program mechanism, not a name list.

## Open work, in order

### Architecture checkpoint (2026-07-21)

An adversarial review of the current lowerer, evaluator, VM dispatch paths, image
format, recent static-bake commits, and the JIT/bytecode plans found one ordering
error in the migration: `Module.resolveCall` already computes a scoped
`candidate_set`, but deferred emission discarded it. `CallMemberOrGlobal` then
reconstructed candidates from the program-wide simple-name index at runtime. That
made the runtime a second resolver and allowed a correct lowering-time scope decision
to widen again.

The first correction is now in the tree:

- `CallMemberOrGlobal.candidates` carries the package/import-scoped `FuncId` set.
  A non-null set is authoritative, including an empty set; runtime overload ranking
  may use runtime value shapes only within that set and may not fall back to every
  declaration sharing the simple name.
- `null` has one explicit meaning: no complete, rankable Kotlin declaration set
  exists for the symbol, so the host-only/incomplete-header compatibility boundary
  may still resolve it. P10 removes this state by giving every host callable a
  complete declaration.
- The image format and IR disassembly expose this representation (`DYN-bounded N
  candidates`), so packs preserve it and dispatch audits can distinguish a bounded
  deferred site from a bare-name probe.
- `CallSpread` follows the same rule. A bare overloaded spread call carries only
  the `vararg` declarations from its winning package/import tier; after flattening,
  runtime value shapes select within that set and dispatch the chosen `FuncId`
  exactly. This replaces `funcIdForSpreadCall`'s former first-candidate execution
  for bounded calls. Empty spreads are valid zero-element varargs, and the shared
  applicability engine now models that binding directly.

This establishes the exact/virtual/deferred contract in data, but does not finish it.
The next implementation order is:

1. Complete `DeclSig` registration for constructors and every class-member header
   before any method body lowers. The current incremental member tables lose
   same-name/same-arity overloads and cannot resolve forward private calls.
2. Add owner-scoped member candidate sets and one `resolveMemberCall` entry point
   using `applicability.zig`. Exact private/final calls become `Call(FuncId)`;
   overridable calls become `CallVirtual(MethodSlotId)`.
3. Give each override family a stable method slot. Runtime virtual dispatch becomes
   `(receiver class, slot) -> FuncId`, with no method-name or program-wide function
   search.
4. Move explicit-receiver resolution into expression lowering. This is now the
   only source of exact member and member-extension targets. The post-lowering
   simple-name/arity bake is deleted; an unresolved call remains explicitly
   deferred rather than acquiring a declaration identity after lowering.
5. Finish P10's host declaration manifest, after which
   `CallMemberOrGlobal.candidates == null` and runtime global lookup by simple name
   are invalid states for Kotlin calls.

The virtual-call representation is now live for ordinary object-ABI classes and
positional interface calls. `MethodSlotId` is rooted at the statically selected
declaration, a link step composes generic supertype substitutions and maps every
`(ClassId, slot)` to its concrete `FuncId`, and lowering emits
`CallVirtual(slot)`. Abstract interface headers come from the canonical
declaration table, so one implementation can populate several interface-root
slots. Synthetic SAM instances and callable-backed SAM parameters execute the
selected abstract slot through their stored callable without name resolution;
the fun-interface classifier call itself lowers directly to `NewInstance` with
its resolved `ClassId`. Named open-class calls carry source-argument to
declaration-parameter indices in `CallVirtual`, so override selection never
rebinds names against the leaf implementation.
Every IR class now carries an explicit receiver ABI from the canonical runtime
classifier manifest. Source-backed classes use numeric instance slots;
specialized scalar/collection values and host-synthesized instances such as
`Grouping` use the host member ABI. This replaces the former `kotlin.*`
package heuristic while allowing source-backed stdlib interfaces such as
`DropTakeSequence` to dispatch statically. Named,
defaulted, and vararg interface calls, including wrapped and callable-backed
SAM receivers, use numeric declaration-parameter maps. Static spread calls
retain their virtual slot while expansion duplicates the selected vararg index,
and omitted defaults come from the exact slot-root declaration. Abstract
default thunks are keyed by their reserved `FuncId`, avoiding the prior
class/name collision between overloads. `dump-ir` reports virtual calls
separately from name-dynamic calls so migration coverage is measurable.

Executable images now preserve both the owner-scoped declaration groups and the
fully linked `(runtime ClassId, MethodSlotId) -> FuncId` table. Loaders restore
those exact host-baked identities while function bodies remain lazy; they do not
repeat override resolution from header-only image state. Override linking compares
nominal `ClassId` identity when source spellings differ, including qualified nested
class paths retained in structural type markers. The Android ARM64 on-screen smoke
loads a host-baked Compose image, executes virtual calls through that table, and
drives rendered frames and input without a bodyless dispatch target.

Runtime-defined anonymous and local classes now participate in the same numeric
slot contract. Their first `(runtime class identity, MethodSlotId)` call links
either to the exact override body in its side module or to the most-specific
already-linked supertype implementation, then caches that typed target. The hot
path is consequently a class/slot hash lookup followed by direct execution; it
does not reopen method-name lookup or overload selection. Named/defaulted calls
bind against the slot-root declaration before entering an anonymous override,
so inherited defaults retain Kotlin's declaration semantics. The corpus pins
both an inherited interface default and an anonymous override in eager-emitted
`CallVirtual` form, with and without a named argument.

Explicit-receiver top-level extensions now resolve through
`Module.resolveExtensionCall`, using the same declaration index and shared
applicability engine as the other call forms. A direct target requires an
in-scope declaration, a statically assignable receiver, positive type evidence
for every value argument, and a unique overload before the stable `FuncId`
tiebreak. Non-inline user and library extensions then emit exact
`Call(FuncId)` instructions; the extension canary's `shout`, inherited-receiver
`greet`, and generic-receiver `doubled` calls are all direct in eager-on and
eager-off lowering. Positional calls may omit trailing default parameters once
every omitted declaration slot is proven defaulted; execution then uses the
selected `FuncId`'s default thunks. Named/spread calls and inline extensions
remain deferred. Inline targets still need a resolved inline lowering strategy
that preserves the declaration's lexical helper identities.

The exact host-ABI identity slice is now live for receiverless and
receiver-formed declarations. `DeclSig.host_symbol` records the exact
fully-qualified host ABI symbol selected for each source declaration; an absent
value means the declaration has no proven host form. The mapping is computed
once while headers register, is restricted to the Kotlin host surface, and is
serialized in image format 34. The same declaration record now preserves all
four Kotlin visibility levels instead of collapsing member visibility to a
private bit. A proven non-inline Kotlin extension therefore
resolves through `Module.resolveExtensionCall` and emits `Call(FuncId)` without
a runtime receiver/name probe.

Source-bodied Kotlin extensions use the same rule: their reserved `FuncId` is
already their executable ABI, so they no longer need a host symbol to become an
exact call. Scope selection now happens after applicability, keeping a
non-applicable inner tier from hiding an applicable outer tier. Structural
generic arguments must match exactly before this path commits; variance-aware
substitution can relax that conservative boundary later. A possible member
extension keeps the call deferred because its ABI also needs an implicit
dispatch-owner receiver, and open member extensions select overrides on that
owner. The `stdlib_string_ops.kt` main now reports 59 direct and 13 dynamic
calls, improved from 36 direct and 36 dynamic; this gives the work a repeatable
static-dispatch coverage measure.

Structural type evidence now crosses locals, captures, lambda parameters,
receiver functions, declaration return types, and image serialization without
collapsing generic arguments to simple heads. Argument lowering snapshots this
metadata per call, so lowering a nested earlier argument cannot erase the
expected types of a later lambda. Smart casts of both named values and `this`
update the same structural receiver channel in `if`, subject-bound `when`, and
subjectless `when` branches.

Binary `+` and `-` use the explicit-call resolver before the compatibility
`BinOp` path. Chained operators recursively instantiate the selected
declaration's return type, so `Iterable<T>.plus` followed by another `plus`
continues from `List<T>`, and a `Sequence<T>` argument selects the sequence
overload. Proven operators emit exact `Call(FuncId)` or
`CallVirtual(MethodSlotId)` instructions instead of asking the runtime to
select an overload by the receiver value.

Host identity and executable-form selection remain separate. A body-bearing
receiver declaration keeps its Kotlin body because that declaration accepts
user-defined subtypes while a native implementation may cover only KLIO's
builtin value representation. A bodyless declaration links its `FuncId`
directly to `host_symbol`. This distinction is structural and tested with two
declarations carrying the same host symbol. `CharSequence.repeat` also has an
ABI-aligned registry identity, so `"xy".repeat(3)` is direct IR while
StringBuilder and user-defined CharSequence receivers remain correct. Runtime
applicability consults the link-settled executable form, and its argument-shape
storage grows past the stack fast path instead of reopening an unbounded name
lookup for large calls. The embedded source set includes
`unsigned/src/kotlin/UMath.kt`, so the bounded `kotlin.math.min`/`max` families
contain their real UInt and ULong overloads.

The concrete correctness canary for item 1 is a class containing two private
same-name, same-arity overloads (`pick(Int)` and `pick(String)`). Today the
declaration-order map keeps one `FuncId`, so both calls can reach that sibling. The
fix is the complete owner-scoped overload index, not another arity/name exception.

0. **P10 — the no-holes symbol table (intrinsics become symbols). THE PRIORITY.**
   The direct order (2026-07-04): get resolution and execution in line with the
   official Kotlin compiler so building on KLIO starts from a correct base — stop
   the whack-a-mole. The root cause the whole hatch pile patches: intrinsic-backed
   names are HOLES in the declaration table (`retainDecl` drops their source), so
   every resolution layer needs a side-channel to know the host serves them, and
   the intrinsic registry maps FQNs to function POINTERS with no declaration
   shape — it cannot answer resolution questions (`kotlin.text.nativeIndexOf`
   binds a receiver-formed helper; `kotlin.collections.listOf` is a value-position
   global; the registry cannot tell them apart, measured 2026-07-04). kotlinc has
   no such concept: resolution is one pure function over one complete symbol
   table, and native-ness is a codegen/link detail (spec: Overload resolution —
   candidate sets are built from declarations in scope, receivers first, then
   package/default-import scope; spec PDFs restored under
   `kotlin-language-spec/`). Three steps:
   1. **Retain every intrinsic-backed source declaration — LANDED.** `retainDecl`'s
      function drop-lists (`isSequenceFactoryName`, `isCollectionFactoryName`, the
      `emptyList`/`emptySet`/`emptyMap` drops) are deleted; the declarations lower
      like any other source and `linkResolvedForms` binds them `resolved_native` —
      the mechanism that already works for `require`/`minOf`-with-source.
      `expect` drops remain where an `actual` replaces the declaration.
      Receiverless and uniquely mapped receiver-formed host declarations retain
      their headers and carry `DeclSig.host_symbol`; bodyless headers link by
      this exact identity, while body-bearing headers retain their source body.
      This removes package-FQN versus receiver-ABI guessing from call dispatch.
      First unlocked hatch deletions shipped with it:
      `inline_state.isDroppedStdlibFactory` (its premise — no lowered `FuncId` —
      is now false) and both factory name-list helpers. Verified: the full dual
      gate is at the existing baseline, inventory unchanged at 117, and eager
      ON/OFF results are identical.

      *Step-2, first slice — LANDED (2026-07-04): headers stay bodyless.*
      Phase 2 of the module build SKIPS body-null functions (`f.body ==
      null` keeps the phase-1 stub: declared params, empty blocks), so
      `hasBody()` is false and `linkBodyless` settles their executable
      form — before this, every retained header got a manufactured
      one-block `return Unit` body that shadowed real dispatch. The
      unsettled-header dispatch semantics live in exactly three places:
      (a) `executableForm` (host_call_func.zig) — body ∨ resolved-native ∨
      same-FQN intrinsic ∨ body-sibling redirect; (b) `extensionFnFallback`
      skips non-executable candidates at collection (an unsettled header
      never competes, and can no longer cycle the walk — the cycle killed
      ktor_client_get via `HttpClient.platformResponseDefaultTransformers`,
      an `expect` whose platform `actual` is outside the pack's source
      set); (c) a call that still lands on an unsettled header no-ops to
      Unit — statically-bound calls in `callFunc`'s bodyless arm (member
      walk first, canonical miss → Unit), deferred bare calls via
      `bareUnsettledHeaderNoOp` at the very end of `CallMemberOrGlobal`'s
      ladder (eval.zig), before the unresolved-global raise. One hard
      lesson recorded: converting the walk's canonical miss to Unit INSIDE
      the walk is wrong — the `Vm::call_member` miss message is a protocol
      that downstream fallbacks pattern-match (the compound-assign
      `plusAssign`→`plus` chain, singleton forwarding); the no-op belongs
      only at ladder ends.
      Verified: unit suite green; e2e, check_examples, litmus set
      (threaded_litmus, corpus_pinned, lambdas_and_dispatch,
      inheritance_dispatch, extension_resolution, object_init), ktor_server,
      ktor_channel_async, concurrency_stress all green; full dual
      stdlib-commontest gate byte-identical eager ON/OFF (perfile and
      perfail), and the four files that crashed the pre-fix gate
      (ArraysTest/CollectionTest/EnumEntriesFactoryTest/NumbersTest) run to
      completion under both modes. Honest inventory: 119 failures both
      modes. The earlier "117 → 102" claim did not survive the crash fix —
      the 102 was measured on a tree whose walk-bounce could crash or
      serve by recursion luck; against the last comparable sweep (122):
      9 fixed, 6 surfaced. The 6 (ArraysTest.contentDeepToStringNoRecursion,
      ArraysTest.shuffle, CollectionTest.abstractCollectionToArray,
      CollectionTest.toStringContainingThis, NumbersTest.doubleToBits,
      NumbersTest.floatToBits) are one class: an expect-with-impl header the
      step-1 drop conditions missed (e.g. `Double.Companion.fromBits` — its
      lowered FQN does not match the registry's member-form registration),
      so the retained header hijacks a call site whose serving used to come
      from the manufactured body's mis-bound-overload intrinsic fallback
      (`f.hasBody()`-gated, now skipped). Fix is the already-planned step-2
      precondition — declaration-aligned registry entries / the manifest —
      NOT six point patches.
      Known-red, pre-existing (verified identical at the pre-slice commit
      via stash): ktor_client_get (all 4 tests) — after the engine executes
      a request, a second HttpRequestBuilder replays the get-block closure
      chain and dies on `plusAssign` on `kotlin.coroutines.CombinedContext`;
      suspend-resume/replay-shaped, needs its own root-cause session.

      *Follow-up findings (2026-07-04, after the slice landed):*
      - **Link-time receiver-qualified settling is a dead end — do not
        retry it.** An experiment taught `linkBodyless` to probe the
        registry under `<pkg>.<Receiver>.<name>`; the link audit showed
        ~40 headers settling, and any call site that LOST its receiver at
        lowering (bare/companion calls binding one shared header fid for
        every receiver's overload) then silently ran the wrong type's
        intrinsic — `Double.fromBits` through `float_from_bits`. A
        unique-receiver guard still cascaded (newly-executable headers
        started competing in the extension fallback). Reverted whole. The
        per-call bodyless arm (member walk on the actual receiver) is the
        receiver-faithful mechanism; the missing piece is call sites
        CARRYING their receivers — P10 step 3, not link work.
      - **Bound companion references — FIXED (`61975f46`).**
        `Double.Companion::fromBits` was classified unbound because
        `hostHasMember` cannot see intrinsic-backed companion surface;
        `companionServesName` (host_call_value.zig) also consults the
        companion-FQN registry probe and declared companion-receiver
        headers. NumbersTest.doubleToBits/floatToBits pass.
      - **Canonical NaN — FIXED (`61975f46`).** Upstream declares
        `Double.NaN = -(0.0/0.0)`; KLIO's negation did the IEEE sign flip
        where every Kotlin platform's constant evaluation yields the
        canonical positive quiet NaN. Unary minus on NaN now keeps the
        canonical form (eval `Neg` arm + `num_unary_minus`).
      - **The "nondeterminism" scare was tool error — RETRACTED.**
        `commontest-sweep.py --filter` narrowed the target list that also
        supplied each child's sibling context, so filtered runs compiled
        WITHOUT their same-directory siblings and failed on the siblings'
        helper declarations (`unresolved global Sortable`,
        `assertAlmostEquals`, `assertSorted`). Fixed: a filter narrows
        what RUNS, never what compiles alongside. Resolution outcomes are
        deterministic per argv — verified by exact-argv reruns. The
        119-inventory numbers from full sweeps were always correct.
      - **Descending natural-order sorts over host-comparable elements —
        FIXED.** `sortWith`/`sortedWith` with an empty-step
        `reverseOrder()` comparator (the body of `sortDescending`) took
        the scalar-only natural sort and returned `Unimplemented` on user
        `Comparable` instances; `sortListHostAwareDesc` runs the stable
        host-aware merge sort with the direction flip, and
        `array_sort_with`/`iterSortedWith` route empty-step comparators
        through it. ArraysTest.sortStable passes.
      - **Inapplicable local callables yield to extensions — FIXED
        (`4ef74e32`), inventory 119 → 115 dual-identical.** The
        `CallMemberOrValue` value arm invoked a same-named local lambda
        regardless of arity, Null-padding its params
        (`subList(..).sortDescending()` next to a
        `sortDescending: TArray.(Int, Int) -> Unit` param ran the local
        with Null indices; the walk then bound the `(fromIndex, toIndex)`
        Array variant for the list because the LENIENT extension pass had
        no arity check at all). Three pieces: `callableAcceptsArgs`
        (closure applicability via the body func's DeclSig — local
        functions lower as closures and may carry defaults),
        member/extension-first dispatch for proven misfits with a
        canonical-miss fallback to the local (the proof is conservative),
        and `declArityRefuses` in the lenient extension pass (DECLARED
        required/vararg — per-fid default thunks are not authoritative
        for pack functions; judging by them broke every defaulted
        kotlinx extension, caught by threaded_litmus). Also in the batch:
        `sortListHostAwareDesc` covers `array_sort_with`'s empty-step
        comparators (ArraysTest.sortDescendingRangeInPlace).
      - **Reified type args do not survive the inline splice.**
        `enumEntries<E>()` splices (inline + reified), binding `T` as a
        RUNTIME class value (`bindReifiedType` + StoreGlobal) — but the
        spliced body's `enumEntriesIntrinsic()` call emits with no static
        type args, so the typed dispatch arm never sees `E` and the
        unsettled header no-ops to Unit. `callFuncTyped` now serves
        `enumEntries`/`enumEntriesIntrinsic` like `enumValues` (fixed
        EnumEntriesFactoryTest.testEquality — the direct CallTyped
        shape); the two remaining cases need the splice to STAMP
        substituted type args onto nested calls whose callee's
        type-parameter names are bound in the active reified
        substitution (`effective_type_args` knows the names at splice
        time; record them alongside the reg binding and consult at
        call-emit). P10 step-3 adjacent — do it as lowering work, not
        another runtime probe.
      - **Checkpoint 2026-07-05: inventory 97, dual-identical, gate green
        at every commit.** The batch since 115: bound companion refs,
        canonical NaN, local-callable applicability + lenient declared
        arity, `Type::member` receiver loading, declared-lambda-overload
        precedence over arity-blind intrinsics, splice-reified type-arg
        stamping, Array shuffle/toString, windowed/chunked transform,
        erased receiver-type-arg ties declining to element-tag-aware
        dynamic arms (Iterable/Set/Array sum-min-max-average now
        registered and iterable-generic), unsigned array views tagging
        through the subscript fast path and wrap ctors, explicit type
        args surviving deferred/value dispatch (unsigned literal
        coercion), unsigned range membership. Remaining in-test-only
        mysteries (sizeInBitsAndBytes Type, sortedTests toArray-on-String,
        compareToIgnoreCase overflow) share a local-fn + test-class
        context pattern — investigate with child-level traces.
      - **Checkpoint 2026-07-05b: inventory 94 dual-identical.** ArraysTest,
        NumbersTest, UnsignedArraysTest, RandomTest fully green. Landed
        since 97: type-in-value-position Any surface (uppercase field
        reads skip constructor intrinsics; Class/Function/Intrinsic
        toString), local functions keep vararg shape through closure
        lowering (non-final-vararg reorder route in callFunc,
        callFuncFast exclusion, named-local-fn bypass in
        callValueWithThis).
        The two big remaining clusters, root-caused and ready to
        implement:
        1. **Set/Iterable `minus` family (12 tests)** — kotlinc resolves
           `data - "foo"` against `data`'s STATIC type (`T : Iterable`
           bound → `Iterable.minus` → List); KLIO dispatches dynamically
           on the runtime Set (→ Set). Needs a static-receiver-head
           channel at lowering: class-property declared types resolved
           through class type-parameter BOUNDS, feeding the binop/member
           lowering (`static_recv`-style) so the walk picks the
           bound-typed overload. P10 step-3 shaped.
        2. **windowed-over-Iterable tail (3 tests) + likely more** — the
           source `windowedIterator` yields the raw `RingBuffer` for the
           last partial window (by design — it IS a List on JVM);
           `assertEquals(listOf(6), window)` needs List↔list-like-Instance
           equality bridging (drain the AbstractList-subclass instance and
           compare elements), the same bridge the LinkedStringSet
           `minus`-display mismatches hint at for Sets.
      - **Checkpoint 2026-07-05c: IterableTests fully green (static-head
        channel landed, `0bb6b7fb`); inventory ~79.** SequenceTest (13) is
        the next cluster, design ready:
        * Six `Type` failures = scan / runningFold / runningReduce /
          zipWithNext / chunked / windowed are NOT streaming `SeqOp`s —
          they batch-materialize, and the tests run them over the
          INFINITE `generateSequence(0){it+1}`. Implement as stateful
          streaming ops in `src/stdlib/implementations/sequence.zig`'s
          pull driver (the `st.indices/taken/...` state arrays gain
          per-op Value state: Scan{initial,op} emits acc (initial first),
          RunningReduce{op}, ZipWithNext{transform?} keeps prev,
          Chunked{size,transform?} and Windowed{size,step,partial,
          transform?} keep a buffer and need an END-OF-SOURCE FLUSH hook
          in the driver plus emit-cardinality handling (buffer-until-full
          → emit). Extend the streamability gate + the member arms that
          append `SeqOp`s (host_call_member ~5290 region) + `SeqOp`
          gcTrace for captured Values.
        * ConstrainedOnceSequence trio: `iterator` member missing on the
          wrapper + constrain-once IllegalStateException on second
          iteration.
        * flatten on Sequence; Sequence.minus laziness
          (minusIsLazyIterated); orEmpty returning [] instead of the
          Sequence.
      - **Checkpoint 2026-07-05d: inventory ~70 dual-identical.**
        SequenceTest 13→2 (scan family lazy via source, IteratorFn SAM
        source, constrain-once actual + hatch deletion, generateSequence
        one-shot/seed-fn semantics). decl_sigs ride the stdlib image
        (DeclSigLite): every declared-signature mechanism now works in
        image-loaded runs — bake-vs-image nondeterminism killed. Hatches
        deleted this arc: constrainOnce no-op; Set/Iterable min-max
        family served by declarations. NOTE: kotlin.test packs are
        INSTALLED state under ~/.klio/packs — never delete .klio
        wholesale (restore: klio pack build kotlin-klio/klio-kotlin-test
        + pack install, both homes).
        Remaining clusters, mechanisms identified:
        * StringTest 6 / ContainerBuilder 6 — orEmpty null-receiver
          overload pick; build-list identity ("is not same"), subList
          views, map-entry setValue guard.
        * ReversedViews 5 + ArrayDeque 5 — need source-class instances
          (views with write-through; ArrayDeque internalStructure) —
          the P10 de-hatching direction.
        * Anon-capture chain bug (blocks Sequence.minus laziness +
          GroupingTest countEach): a lambda inside a runtime-lowered
          anon-object method reads enclosing-fn captures as Null; bare
          member reads inside stdlib anon methods can hit package
          intrinsics (`iterator` → the builder). Root in the
          buildObject → lowerMethod capture threading.
        * PropertyReference 4 (bound property refs), KClass 3
          (safeCast, qualifiedName), Regex 3 (options field, matchAt
          bounds, empty-match split around surrogates), EnumEntries
          factory 3, GroupingTest others (local-fn-on-String ext
          countVowels, groupingProducers recursion depth).
      - **Checkpoint 2026-07-05e: inventory ~63 (from 66 pre-anon-fix;
        full sweep pending).** Landed since 66: anon-object capture chain
        (resolveCapture anon branch, labeled-receiver capture without
        scope caching) — the WHOLE stdlib object-expression family works
        (Sequence.minus lazy + family, FilteringSequence nested anons,
        Grouping fold/reduce/countEach); Type::localExt references;
        keyed Grouping.fold passes the key; nullable declared receivers
        carry their head (String?.orEmpty picks by static type); user
        CharSequence implementations re-dispatch text ops via toString.
        StringTest's remaining 5 all pass standalone — they need
        in-test-class replication (local operator funs shadowing `in`,
        StringBuilder-wrapped args via withTwoCharSequenceArgs); use the
        MiniSizes.kt technique. SequenceTest.orEmpty residue =
        emptySequence() must be a per-process singleton for identity
        asserts. ContainerBuilder "is not same" trio = same singleton
        story for emptyList/Set/Map after build of empty builders.
      - **Checkpoint 2026-07-05f: inventory 45 dual-identical (119 at
        session start; ~98% of ~2150 passing).** Parallel-agent batch
        model landed: four investigation agents (no builds) produce
        patch-ready root causes per bucket; patches apply centrally;
        one build + one gate + one full sweep per batch. Landed:
        ArrayDeque de-hatched AND fully green (ctor family scoring,
        terminateCollectionToArray actual, copyInto named args);
        iterator last-returned protocol; property-reference delegation;
        KClass cast/safeCast/KClassifier; anon reflective names null;
        regex fold/lookaround/matchAt/options; String.windowed peel;
        local-callable call-fit; empty-collection singletons; read-only
        entry guards; captured-name call arbitration.
        Remaining tail (no cluster >3): PropertyReference 3 (ext-prop
        delegates — agent design recorded), EnumEntriesFactory 3 +
        EnumEntriesList 2 (expected-type propagation into args/callable
        refs — agent design recorded), MapTest 3 (incl.
        entriesCovariantRemove regression from the entries-mutability
        gate), ContainerBuilder 3 (subList live views — agent design
        recorded), CollectionTest 3, Uuid 2, Exception 2, StringTest ~2
        (local fn overload selection — agent design recorded), singles.
      - **EXACT STATE 2026-07-05 (batch-3 landed + compose regression
        root-caused and fixed): 36 failures dual-identical** (45 at
        2bfaeef9, 119 at session start), gate green, ratchet 2080 holds
        (~2114 passes).
        The compose regression's real mechanism: the failing dispatch arm
        was `resolveExtOverloadLocal` (host_call_member.zig), the
        named-arg extension picker behind `userMethodNamed` — the third
        path, reached by `content.fill(null, fromIndex=…, toIndex=…)` in
        MutableVector.kt after `stdlibNamedDispatch`'s probe chain broke
        on `kotlin.collections.fill` (paramNames hit, intrinsic miss →
        loop break). It collected candidates with NO receiver disproof,
        so the four unsigned-array `fill` source decls (the only
        surviving same-name source candidates once the MutableList.fill
        actual shifted the set) were scored on a plain `Array` receiver
        and UIntArray.fill won. Fix: the candidate loop now applies the
        same disproof trio as the lenient ext pass
        (`receiverViolatesTypeParamBound`, `builtinReceiverDisproven`,
        `argDefinitelyNotParamType` on the receiver). Landing it exposed
        a LATENT bug in `builtinReceiverDisproven` itself: it compared
        the declared receiver ("UByteArray") against the prim view's
        ELEMENT name (`PrimitiveArrayKind.simpleName()` = "UByte"), so
        every genuine unsigned-array receiver was disproven against its
        own extensions — harmless on the old cold path, a 40+-failure
        sweep regression on the hot one. Fixed to compare
        `simpleName(view.typeFqn())`; unit test pins the relation. Net:
        the trio also fixed real mis-binds (MutableCollectionTest
        listFill now passes; ArraysTest sortedTests /
        contentDeepToStringNoRecursion / copyRangeInto /
        copyOfWithInitializer and NumbersTest.sizeInBitsAndBytes cleared
        with batch-3).
        Verification-loop lesson recorded: `commontest-sweep.py
        --filter` matches fewer files than the filter list suggests —
        trust only full-sweep counts for regression verdicts; and the
        gate's sweep step does NOT enforce the 2080 ratchet (that lives
        in itest-stdlib_commontest only), so GATE GREEN alone does not
        prove the ratchet.
        BATCH-3 (landed with the above):
        * emptySequence() process singleton (arena profile) + reset hook.
        * subList live-view read-through (Value.refreshSublistView +
          call sites; arena-only, reclaim guarded).
        * Builder freeze bit (FROZEN_MOD_BIT in shared mod_count;
          readOnlyMutationGuard honors it) — leaked builder subLists
          reject mutation after build().
        * MutableList.fill/shuffle + collectionToArray×2 actuals
          (actual-marked; collectionToArray earlier caused a
          conflicting-overload diagnostic when non-actual — fixed).
        * Map.toMap(destination) merges into the destination (was:
          ignored it and returned a read-only snapshot) — root of
          MapTest.entriesCovariantRemove/nullKeyAndValue UOEs.
        * Init-block/accessor thunks treat their own `this` as a
          dispatch receiver (eval own_is_subject fix) — root of the
          `checkPositionIndex` unresolved trio.
        * companionWithMember BFS also walks the lexically enclosing
          class prefix (inner classes reach the outer companion).
        * Comparator structural equality (shared-steps + descending);
          comparator compare falls back to user compareTo (Uuid
          lexicalOrder, naturalOrder over user Comparables).
        * data/value-class equals/hashCode are structural in
          anyInstanceFallback even when an interface redeclares them
          (TimeMarkTest).
        * Inline-splice lambda args get pending_lambda_arity from the
          declared function-type param (UuidTest.parseInvalid
          `assertFailsWith { it() }` shape).
        AGENT ROOT-CAUSE BACKLOG, DESIGNS RECORDED BUT NOT IMPLEMENTED
        (all have concrete file/line anchors in this session's agent
        reports; re-derive with the named repro shapes if needed):
        1. LANDED — Local fn OVERLOADS collapse to last declaration
           (StringTest.compareToIgnoreCase stack overflow, also the
           GroupingTest.groupingProducers recursion in item 19).
           Implemented exactly per the design: each same-named local
           decl also binds a module-lifetime mangled name (`name$ovl<k>`)
           through a dedicated cell registered BEFORE its body lowers
           (so sibling bodies select against the full set), a
           disproof-only static selector (arity, named args,
           literal/declared type heads) at the single-name call arm, and
           overload-table inheritance into nested lambda bodies.
           Lifetime lesson: names shipped in AstLambda captured-name
           lists are read at runtime — allocate from the module
           allocator, never the builder's. Beneath the recursion sat
           TWO case-fold bugs the test then exposed: string.zig's
           hand-rolled scalarToLower/Upper range subsets missed real
           mappings (KELVIN -> 'k') — now delegated to char.zig's full
           tables — and both `equals(ignoreCase)` (whole-string
           lowercase) and the per-unit fold used the wrong rule; both
           now apply Kotlin's per-char uppercase-then-lowercase fold
           ('ſ'=='S', 'ϑ'=='ϴ', and "ß" != "SS" via the length gate).
        2. Enum expected-type propagation (EnumEntriesFactoryTest ×3):
           per-arg expected types with sibling-arg solving in emitCall/
           emitMemberOrGlobal (unifyTypeParam against param tys), enum
           recognition for the oracle, callable-ref-against-expected-
           fn-type lowering (::enumEntries), plus a loud-failure guard
           in the enumEntries intrinsic when type args are lost.
        3. LANDED — Ext-property DELEGATES dropped by lowering
           (PropertyReference extensionProperties / covariantProperties /
           memberProperties, all three now pass). Implemented per the
           design: `val R.x by expr` lowers a 0-arg delegate thunk in
           the interp build ext-prop loop, registered in the new
           `extension_prop_delegates` (recv,name)→fid map (plumbed
           through Program, run transfer, AND the baked-image codec —
           FORMAT_VERSION 12→13), with read/write probes in host_fields
           that materialise the delegate once (cached as a hidden
           global keyed by the DECLARING receiver so subtype receivers
           share it) and route getValue/setValue with a PropertyRef.
           Two more root causes surfaced beneath: (a) a bound property
           reference's `get()` required `memberIsProperty`, so a bound
           EXT-property ref fell through to a member call and died —
           `get()` now tries the full field path (which resolves ext
           getters + delegates) before the bound-method forward; (b)
           `Value.structuralEq` had NO StringBuilder arm, so `==` on
           the SAME builder was false — now identity, as on the JVM
           (covariantProperties' CharSequence-typed delegate read).
        4. EnumEntriesListTest ordinal faults: deferred bare-call arity
           readout must see class-member overloads hosting trailing
           lambdas (overloadHostingTrailingLambda misses members at
           extension-body sites) — plus contains/indexOf on wrong-typed
           args should disprove via class type-param bounds and fall to
           AbstractList iteration.
        5. Anon side-module overloads (CoroutinesReferenceValuesTest.
           testBadClass, also latent everywhere): callNamedOverload only
           scans frame.module.func_index — empty in anon side modules;
           re-collect from the closure's OWNING module. Plus anon
           captured-var WRITES don't propagate: ObjectExpr missing from
           assignedInLambdasExpr (never boxed) and storeGlobal replaces
           the transient capture layer instead of writing through the
           Cell.
        6. Base64Test.common: sibling local fn vs same-named private
           member — emit CallValueOrMember with the captured local +
           param-type disproof in its value arm.
        7. Sequence.zip must be a lazy alternating-pull merge (remove
           from isSequenceTerminal + lazy pairing source)
           (SequenceBuilderTest.testParallelIteration).
        8. builderStep needs a `failed` flag: after a builder body
           throws, hasNext/next must throw IllegalStateException
           (testExceptionInCoroutine).
        9. CoroutineContextTest.testInterceptor: lowerCallSpread must
           route a bare member-fn callee with *spread through `this`
           (currently lowers as a field read).
        10. sumOf must keep the lambda's numeric kind (Long/UInt/ULong/
            Double accumulator seeded from first result; empty-receiver
            kind needs lambda return_ty population)
            (CollectionTest.sumOf).
        11. plus-inference: `list + (x as Any)` must call plusElement
            when RHS static head is Any/generic (CollectionTest.
            plusCollectionInference).
        12. Local classes never register property ACCESSORS
            (host_classes.lowerAndRegisterMethods lacks the .Property
            arm buildObject has) + toTypedArray must re-dispatch a user
            toArray override (CollectionTest.abstractCollectionToArray).
        13. Short/Byte literal narrowing (widenNumericLiteral only does
            Long) (SetOperationsTest.intersectShort/ByteArray).
        14. MapEntry live read-through + CME (mod_count/exp_mod stamped
            at creation; value reads through backing; throws
            ConcurrentModificationException after structural change)
            (MapTest.modifiedBackingMapOfEntry).
        15. LANDED — formatThrowable now renders the JVM enclosed
            shape: Suppressed: sections (one tab deeper per level),
            causes at the parent indent, and an identity-keyed dejaVu
            set emitting [CIRCULAR REFERENCE: <header>] instead of
            re-walking (both ExceptionTest detailed-trace tests pass).
        16. kotlin.reflect.typeOf needs a reified intrinsic returning a
            KType (KTypeProjectionTest).
        17. LANDED — append/insert guard: when the argument's length is
            knowable (strings, builders, user CharSequences via their
            `length` property) and the sum exceeds Int.MAX_VALUE, throw
            OutOfMemoryError before materialising anything
            (StringBuilderTest.overflow passes).
        18. Duration formatToExactDecimals saturates at Long range —
            exact digit expansion for |value|>=2^63
            (DurationTest.parseAndFormatInUnits).
        19. LANDED with item 1 — GroupingTest.groupingProducers was the
            same local-fn-overload collapse (same-named local fns in the
            test body recursing through the shared binding).
        20. SequenceTest.orEmpty residue — VERIFIED NOT fixed by the
            emptySequence singleton (still fails post-batch: `Expected
            <Sequence>, actual <Sequence>` — an identity, not type,
            mismatch); still open.
      - **2026-07-06: ZERO known per-file failures expected (sweep
        verifying)**. The final six fell to four mechanisms:
        * Items 2+4+13 COMPLETE (the expected-type engine, implemented as
          designed): sibling-arg solving records a per-arg-node expected
          type consumed by the arg-lowering loops (which otherwise
          deliberately null the hint); the inline splice's existing
          return-type unification stamps the reified argument. Enum
          recognition rides class_super_names (enums now record their
          implicit `Enum` supertype). Same-simple-name enums stamp
          OWNER-QUALIFIED names resolved by FQN suffix in the runtime enum
          arm. `::enumEntries` against a declared `() -> EnumEntries<E>`
          lowers as a zero-arg closure over the stamped call. The deferred
          CallMemberOrGlobal form carries reified splice substitutions and
          serves committed bodyless headers through the typed dispatch.
        * Item 4's dispatch half: class_type_param_bounds (new registry +
          image FORMAT_VERSION 14) drive the Kotlin collection-stub bridge
          at resolveInstanceMethod — a candidate whose declared param
          names a class type param with a bound the runtime arg refutes
          falls through to the inherited implementation.
        * ConcurrentModificationTest.subList's last layer: the
          inner-class OUTER field walk swallowed accessor throws as
          walkable misses (SubList.size's CME from IteratorImpl.hasNext).
          Only Unimplemented is a miss now, matching the bare-name walk.
        * SetOperations (13): Int-tagged list literals narrow to the
          declared Short/Byte element kind at the callee boundary (the
          arrayOf<ULong> retag discipline). LESSON (Zig): building a
          union value from its own current payload in one assignment
          (`v.* = .{ .Short = @intCast(v.Int) }`) trips result-location
          clobbering — read into a temp first.
      - **Engine round 3 (2026-07-06, commits 1a19d0be/13586aa1)**: the
        comptime register visitor (ir.visitInstRegs — every operand
        enumerated from the union's own shape) unblocked the Move-fusion
        peephole at finish (single-use temps write their target
        directly; ~7% on loops). Field reads memoize per (fqn, name) on
        the program image, consulted at getFieldInner entry
        (interpreted-class field code 15-18% faster). DeepRecursive's
        wall was QUADRATIC, twice over: catch-only try frames never
        popped on normal flow (fixed with catch_done_for on the join
        block, image v15 — runCallLoop's per-iteration try/catch grew
        the stack every level while every Goto scanned it), and each
        re-suspend copied all pending outer snapshots (fixed with O(1)
        TailSeg linking). 150k levels: 62s -> 33s shipped (17s with
        KLIO_GC_EXT=1). The external-bytes Appel accounting is GATED
        (KLIO_GC_EXT): its collection pressure exposed latent keepalive
        holes — two real ones fixed (SeqIterState.iter_obj untraced;
        fresh builder cursors un-rooted during host drive loops), and
        the gate doubles as a deterministic hole-hunting stress mode.
        NEXT: sweep under KLIO_GC_EXT=1 + KLIO_GC_POISON=1, fix the
        remaining holes, then flip the accounting default on. Also
        discovered: `klio run` (embedded image) leaves
        startCoroutineUninterceptedOrReturn on fn values to runtime ext
        resolution which misses — DeepRecursiveFunction works under
        `klio test` but not `klio run` (repro: scratchpad deeprec2.kt);
        root-cause the ext-vs-image lowering divergence.
      - **Perf+GC round 2 (2026-07-06, commits 9eb68324/57134116)**:
        `i++` no longer runs the string-keyed member ladder — scalar
        unary ops apply natively when no enclosing instance is in scope
        (member-extension operators like the DSL `Int.unaryPlus` keep the
        probe; parity-pinned). Counting loops ~5x faster JIT-off
        (0.95us -> ~0.2us/iter). `reclaimEnabled` is a shared atomic
        (the per-register-write TLV lookup was ~13% of the loop profile).
        GC idle reclamation: a burst-then-quiet program pinned its whole
        burst heap forever (no allocations -> no collection); the
        safe-point poll now fires ONE bonus collection per quiescent
        period (1s after the last collect; real allocation re-arms the
        latch) — the memtail repro drops 576MB -> 34MB, under the
        hello-world baseline. Phased-allocation RSS is flat across
        phases (no growth); decommit verified. ReleaseFast harness: ~2x
        on call/dispatch-heavy code, nothing on pure loops; ship the
        product binary ReleaseFast, keep CI ReleaseSafe. Remaining
        engine levers unchanged: copy-propagation/Move fusion at
        lowering (needs a generic Inst reg-visitor first), per-callsite
        member-dispatch caching for interpreted-class bodies, flat
        bytecode.
      - **Perf work (same day, user-directed)**: callNamedOverload's
        whole-func-index linear scan (the top profile frame) now uses the
        name index; isKnownPackage memoizes the package set; frame
        REGISTER BUFFERS pool under the tracing GC via libc storage (the
        collector traces values through the frame chain and never sweeps
        foreign buffers) — interpreted-class member ops ~31% faster,
        whole corpus 709s -> 614s serially. Per-test wall times stream to
        stderr (`[test] Name PASSED 12ms`). DeepRecursiveTest remains the
        outlier (~280s: per-level interpreted trampoline machinery;
        runFrameInner-self ~68% busy with GC off) — the flat-bytecode /
        per-callsite-caching engine item is the lever, not hot-spot
        patches. Cross-file interference (~53 failures when the corpus
        runs as ONE module, kotlinc's actual mode) recorded as a distinct
        work stream.
      - **2026-07-05 second batch: 28 -> ~6-8 expected (13 measured
        mid-batch, remainder fixed after that sweep)**. Landed, each
        repro-verified (commits 'collections: chained subList live
        views...' through 'local classes: register property
        accessors...'):
        * Collections view family (items 14 + the ContainerBuilder/
          ConcurrentModification/ReversedViews cluster): subList views
          CHAIN through their immediate parent (parent_backing +
          parent-relative windows; syncSublistChain splices ancestors and
          re-stamps their comod expectation; refreshSublistCell recurses),
          comod stamps (exp_mod vs shared counter, FROZEN_MOD_BIT masked)
          guarded at recvListItems / size / iterator creation / hashCode /
          equals / toString / the fastIndexGet bail; freeze inheritance
          into iterator minting and keys/values views (+ the missing
          buildMap freeze); addAll unconditional bump; MapEntry stamped
          live view (exp_mod, by-key value refresh, yield-time re-stamp);
          iterator remove-before-next ISE. LESSON: mutator defers
          (bumpModCount/syncSublist) run on ERROR returns too — comod
          guards must be hoisted ABOVE the defers or a refused mutation
          resyncs the stale stamp.
        * Item 5 (testBadClass): callNamedOverload re-collects from the
          main module in side-module frames; ObjectExpr member bodies
          count for capture boxing (both the assigned and referenced
          scans); storeGlobal/setField write THROUGH Cell bindings;
          lookupGlobal + the member-walk read unwrap Cells; BinOp is
          Cell-transparent (the `x == null` null-check fast path compared
          the raw Cell).
        * Item 6 (Base64): local-fn-vs-private-member arbitration —
          CallValueOrMember emitted for captured locals (new spread and
          bare-call arms) AND for resolved local fns with a same-named
          enclosing member (redirect_to_member widened: hasEnclosingMember
          + capture-aware `this`); its value arm falls to the member when
          closureParamsDisproven refutes the args (array-on-scalar
          included). REGRESSION LESSON: the bare-spread arm must skip
          names that are also known top-level fns (`maxOf(a, *rest)`), or
          the over-approximate member set hijacks global calls
          (NaNPropagationTest).
        * Items 7/8: Sequence.zip is a lazy Merged source (strict
          left-right interleave, transform overload, wired through
          SeqIter + both materialise paths); builder blocks that throw
          flip a `failed` flag -> later pulls throw ISE.
        * Items 9-12, 16-18, 20 + orEmptyNull/parseInvalid/shuffle:
          spread-through-this; sumOf numeric kinds (callable_return_ty
          hook + literal lambda return_ty); plusElement for Any-cast RHS;
          local-class accessor/$init$ thunks + toTypedArray-observes-
          toArray (Iterable fallback keeps the instance receiver;
          builtinReceiverDisproven rejects Instance-vs-builtin-array);
          typeOf<T>() intrinsic (splice-gated, synthetic KType);
          Duration exact big-integral expansion; Sequence identity
          equality + singleton; Array?.orEmpty actual; trailing-lambda
          binding in closure/local-ctor named binders; companion
          declares-gate on the initialized fast path.
        * REMAINING (the enum expected-type engine + 1 uncovered layer):
          EnumEntriesFactoryTest x3 / EnumEntriesListTest x2 /
          SetOperations intersectShort/ByteArray (items 2+4+13 - the
          sibling-arg expected-type propagation engine, still not
          started) and ConcurrentModificationTest.subList, which now
          fails DEEPER: the earlier ops pass and the ArrayDeque block
          surfaces `get_field size on AbstractMutableList.IteratorImpl`
          - the interpreted native-wasm SubList.size getter (private
          nested class) is not found from the inner IteratorImpl's
          hasNext during a remove-loop; suspect the nested-private
          class's accessor registration keying, NOT the new comod
          machinery (benign deque subList iteration works).
      - **Now 28 dual-identical**: local-fn overloads cleared
        GroupingTest.groupingProducers + StringTest.compareToIgnoreCase
        (36→34); ext-property delegates cleared PropertyReferenceTest ×3
        (34→31); the StringBuilder overflow guard and the JVM
        printStackTrace shape cleared StringBuilderTest.overflow +
        ExceptionTest ×2 (31→28). Nothing added at any step. NOTE:
        SetOperationsTest intersectShort/ByteArray (item 13) is NOT a
        standalone literal-narrowing patch — `listOf(5)` must infer
        List<Short> from intersect's `Iterable<Short>` param, i.e. item
        2's expected-type propagation engine; treat 13 as part of 2.
      - **Named remainder (the full 36, post-batch, dual-identical)**:
        ArraysTest.orEmptyNull (pre-existing at 2bfaeef9, verified via
        worktree build); Base64Test.common; CollectionTest
        abstractCollectionToArray / plusCollectionInference / sumOf;
        ConcurrentModificationTest mutableList / subList;
        ContainerBuilderTest buildList / buildMap / listBuilderSubList;
        CoroutineContextTest.testInterceptor;
        CoroutinesReferenceValuesTest.testBadClass;
        DurationTest.parseAndFormatInUnits; EnumEntriesFactoryTest ×3;
        EnumEntriesListTest ×2; ExceptionTest ×2;
        GroupingTest.groupingProducers;
        KTypeProjectionTest.constructorArgumentsValidation;
        MapTest.modifiedBackingMapOfEntry; MutableCollectionTest.shuffle
        (`lastIndex` on ArrayDeque.Companion); PropertyReferenceTest
        extensionProperties / covariantProperties / memberProperties;
        ReversedViewsTest.testIteratorRemove;
        SequenceBuilderTest testExceptionInCoroutine /
        testParallelIteration; SequenceTest.orEmpty; SetOperationsTest
        intersectByteArray / intersectShortArray;
        StringBuilderTest.overflow; StringTest.compareToIgnoreCase;
        UuidTest.parseInvalid. Every one maps to a backlog item above.
      Also recorded: the remaining expect-with-impl drops in `retainDecl`
      stay until the registry carries declaration-aligned entries (the
      `retainDecl` comment marks it); `kotlin.String.repeat` vs
      `kotlin.text.repeat` is the canonical mismatch example.
   2. **Host-only functions get declarations.** The few intrinsics with no Kotlin
      source (`arrayOf` family, platform helpers) get real Kotlin header
      declarations in a klio-authored manifest file lowered like source, so every
      callable the runtime can serve has a `FuncId` + `DeclSig`. After this the
      intrinsic registry is consulted at exactly one place — link time — never
      during resolution.
   3. **Bare-call resolution = the spec's scope walk over the one table.** Locals
      → members of the receiver chain → extensions in scope → package → default
      imports, with constructors in the candidate set (RC-A's ctor `DeclSig`s,
      keyed by class simple name), decided eagerly at lowering; the deferred
      runtime arms shrink to genuinely runtime-polymorphic receivers.
   **Acceptance (the completeness invariant):** DELETE `ir.host_bare_global_check`
   + `installHostBareGlobals` (the 2026-07-04 stopgap classifier), the alias
   arms, `shadowedByClass`'s literal-kind mini-resolver and the `class_competes`
   interim gate, and CMG's `is_ctor_name` — plus spec-derived conformance
   fixtures for the scope walk (bare calls vs members vs extensions vs
   default-imports; ctor-vs-factory by argument type per the `Box`/`Tag`/`Pt`
   corpus). A hatch that cannot be deleted pins the next fix.

1. **DeepRecursive coroutine intrinsics — LANDED (`135bc4be`).** Implemented exactly
   per the design: `coroutineStartRootOrSuspended` + `coroutineHasDriver` engine fns,
   the `__klio_co_startRootOrSuspended` / `__klio_co_hasDriver` intrinsics, and the
   `startBlock` branch with the captured-`suspended`-flag completion delivery. The
   landing surfaced a second mechanism: DeepRecursive's trampoline unwinds one resume
   per recursion level, and each resume of a PERSISTED coroutine nested a whole native
   `driveResumed` (bus error near depth 2000) — `adoptPersisted` now folds such
   resumes into the live pump as ready coroutines (the resume-chain flattener, klio's
   analogue of `BaseContinuationImpl.resumeWith`'s loop); `depth(100000)` completes
   with linear cost. Verified: coroutine_smoke 9/9, coroutines_realistic 22/22,
   ktor_channel_async, concurrency_stress, stdlib_image all green; litmus at the
   4-failure baseline. Residuals: (a) the **stdlib-gate closure hole** — an
   implicit-package stdlib file (`kotlin/util/DeepRecursive.kt`) depends on a
   gated-out package (`kotlin.coroutines.intrinsics`), so a program with NO imports
   gets zero candidates for `startCoroutineUninterceptedOrReturn`; the gate should
   chase included files' own imports transitively; (b) deep unwinds cost ~0.6 ms/level
   under the Debug interpreter (linear, but the 100k stdlib case wants the ReleaseSafe
   harness).
2. **P2 loose ends**: `callNamedOverload` — LANDED (`9ab882d1`): dual-compute audit
   at zero divergence over the full sweep, flipped onto
   `positionalPoints`/`applicable()`, legacy `overloadScore` deleted (the historical
   `assertContentEquals` divergence no longer reproduces after the trailing-lambda
   engine fixes). COMPLETE: construction factories, primary-constructor
   compatibility, extension fallback, and named-member ranking now consume
   `applicable()` as well; all three legacy per-argument scorer implementations
   and their call sites are deleted. The `overload_match.zig` tri-state helpers
   stay as the shared engine's legitimate runtime-evidence backing.
3. **P4 completion — first slice LANDED (`5d5d4ebb`)**: the central member-shadow gate
   (`memberShadowPossible` + Phase C, via `ResolveCtx.receiver_known`) now keys on the
   owner class AND its lifted-outer chain through the new `HierarchyShadowSet` registry
   (all member kinds, transitive cross-file supertypes, completeness proven — an
   unresolvable chain stays conservative). Substrate: the unified per-FuncId `DeclSig`
   (`dbec6ecb`) with the member half filled at class-body lowering. Two dip-and-recover
   lessons recorded in the commit: methods-only sets and owner-only chains both
   mis-bind. Group-1 flip COMPLETE: the (a) question ("could this receiver's
   member shadow the name") is `memberShadowPossible`; the (b) question ("does
   any class this receiver could be declare the name") is
   `anyReceiverClassDeclares` — hierarchy-precise for plain method bodies,
   program-wide otherwise; the five direct-bind guards route through it.
   `class_member_names` is now read ONLY in those two helpers' unknown-receiver
   fallbacks and Phase C's `!receiver_known` arm — that pair is P7's deletion
   precondition. REMAINING (one item): explicit-receiver (`obj.foo()`) static
   typing — ATTEMPTED and reverted with a precise finding: `CallMember.
   static_recv`'s established meaning in the member-dispatch walk is the
   extension-BODY receiver (the emitExtBareCall shape), and tagging arbitrary
   qualified receivers with their declared type hangs member self-dispatch
   (MutableCollectionsTest looped in irMethodWalk). The slice needs either a
   SEPARATE instruction field (`declared_recv`) consumed only by the extension
   selection, or an audit of every static_recv consumer disambiguating the two
   meanings. Declared-type evidence now carries nullability (local_decl_nullable)
   as groundwork. The ktor server chain (fully fixed: six mechanisms, commits
   d0a9242f..d710630b) remains the concrete evidence for this item.
4. **P5** distinct-keyed inherited fields (RC-D; `c_shadow` 1/2/1/1). **P7** eager
   typeck records+reuses resolution (RC-G) — also unlocks index-primary/type-aware
   resolveCall and the full NaN-style static-overload class. **P8** hatch deletion
   (the completeness invariant; includes `isAliasName`, `isPrimitiveConv`,
   `CONTROL_INTRINSICS`, the Throwable lists). **P9** optional flat bytecode +
   pack serialization.
5. Litmus baseline residue (pre-existing, NOT from this campaign): the 4 fixtures
   above fail at `d2a927db` too; uninvestigated.
6. Non-resolution stdlib residuals (windowed/RingBuffer, orEmpty static dispatch,
   local-fn overload-by-type, entry-CME, sequence streaming) are tracked in the
   stdlib-grind memory notes, out of scope here.

## The three-tier static/dynamic boundary

Every call and access lowers to exactly one tier. The tiers *are* the boundary
between "static as possible" and "still dynamic where it must be":

1. **exact** — a direct target. `Call(FuncId)`, `GetField(class_id, slot)`,
   `Is(ClassId)`. Fully static: top-level funcs, final/non-virtual members, resolved
   extensions, locals, resolved property backing fields.
2. **virtual** — the *slot* is static, the *leaf* is runtime. `CallVirtual(recv,
   slot)` where `slot` is a method key on a known declaring type; the concrete
   override is chosen at runtime. This is how **dynamic dispatch is preserved while
   still carrying full type/signature/slot information** — open classes, interfaces.
3. **deferred** — the genuine escape valve. `CallMemberOrGlobal(candidate_set)` when
   the receiver's type is unknown at lowering (e.g. a `with(x){ … }` scope-function
   body). Carries the *resolved candidate set*, not a bare name. This tier shrinks
   toward zero as the eager engine (typeck) runs.

"Static as possible" = the engine collapses tier 3 → tier 1/2 wherever it can prove
the type. "Dynamic preserved" = tiers 2 and 3 still exist by design.

## One engine, two modes

There are **not** two systems (a resolver and a type-checker). There is **one
inference/resolution engine** run in two modes:

- **lazy mode** — the lowering default (`klio run`/`test`). Run the engine locally,
  keep what resolves, tolerate gaps. Literals, `val x = Ctor()`, declared params,
  direct member chains → tier 1/2. The genuinely-hard residual (scope-function
  receiver types, generic instantiation across lambdas, smart-cast-dependent
  dispatch) stays tier 3. Reaches ~90% static **without running typeck at all** —
  the runtime is tolerant of the residual.
- **eager mode** — the type-check / validation pass (`klio check`, LSP, a strict
  mode). Run the *same* engine over the whole tree, compute every expression's type,
  record `Span→Type` + `Span→FuncId`, emit diagnostics. Collapses the residual
  tier-3 into tier 1/2 and is the **only** source of tooling diagnostics.

Consequences:

- Typeck is the **amplifier**, not the foundation. The index + applicability is the
  foundation (a mostly-resolved runnable IR needs no typeck run); typeck resolves the
  hard last ~10% and produces diagnostics.
- The error/reporting infrastructure already built becomes the **diagnostics layer of
  the eager mode** — reused, not discarded, not an independent type system.
- Because both modes are the *same* engine, `run` and `check` cannot disagree on a
  resolution. This is what makes RC-G real and kills the three-drifting-oracle
  problem below.

## Execution engine — resolved IR → bytecode → JIT

The resolved IR is the single source every execution tier consumes.

- **Today:** the IR is already register-based and block-structured; all references
  are `enum(u32)` integer indices (`Reg`/`FuncId`/`ClassId`/`ConstId`/`BlockId`,
  `ir.zig`), and blocks already have a byte-encoded serialized form (the lazy-IR
  `deferred_func_section`). Execution walks `[]Block` of `[]Inst` (a `union(enum)`),
  dispatching per instruction. This is in-memory bytecode in all but the dispatch
  loop.
- **Flat bytecode (optional, post-resolution):** linearize the resolved IR into a
  flat instruction stream with a switch / computed-goto (direct-threaded) dispatch
  loop and superinstruction fusion. Payoff is bounded and specific: tighter dispatch
  (~1.3–2× on dispatch-bound non-loop code), compactness, and **encoding unification**
  — the flat stream is simultaneously executed *and* serialized. Its value is
  proportional to how resolved the operands are: tier-1 becomes a direct indexed
  dispatch, tier-2 a vtable-slot op, tier-3 the (now-rare) probe. Linearizing before
  resolving only encodes slow probes compactly, so this phase follows resolution and
  is gated on a measurement that the baseline dispatch loop is a real bottleneck (our
  measurements show the interpreter is largely compute-bound; the transformational
  perf already came from the loop JIT at 60–79× and the structural method-dispatch
  fixes at 10–12×).
- **JIT (exists):** `src/ir/jit_loop.zig` compiles hot loops/functions from the same
  resolved IR. Bytecode baseline and JIT coexist — JIT owns hot regions, the baseline
  owns the rest.

**The bytecode stream and the serialized artifact are the same object** (see
Serialization). So "flat bytecode" and "separate serializable artifact" are one
decision with one answer.

## Serialization (pack sections already reserved)

The pack format already reserves the sections this needs — `sources`, `ast`,
`resolved`, `typeck`, `symbols`, `bindings` — and the schema already has a
`TypeckBundle` of sorted `(Span, Type)` pairs (`src/pack/schema.zig`,
`src/pack/format.zig`). They are **empty today**: no `resolved` bundle is emitted,
`write.zig` doesn't populate them, and typeck never runs to fill `typeck`.

Serialization is therefore a **later optimization, decoupled from the in-memory
resolved-IR work**, justified only by startup speed (skip re-lowering the stdlib per
run) and RSS (compact on-disk form). It is **not on the correctness path**. When we
want it, we populate the reserved sections — the linearized resolved bytecode becomes
the `resolved` section, typeck's `Span→Type`/`Span→FuncId` maps become `typeck`, the
sig index becomes `symbols`. No new format is invented.

## Root causes (the means)

- **RC-A — no canonical index.** No single signature index over all provenances
  populated before any body lowers. `func_name_index` is built in the wrong order and
  consulted while incomplete: class bodies lower (`interp_ir/build.zig:1470`) before
  the phase-1 header loop (`:1489-1561`), so `funcsBySimpleName`/`funcId`/
  `decl_user_arity` are empty for user top-level funcs when any class method (incl. a
  `@Test` method) lowers. The `klio run` extend path pre-seeds the index via
  `cloneForExtend` (`ir.zig:1142-1150`), masking the bug; `klio test` goes straight to
  `buildModuleFiles` with no pre-seed, exposing it. Members and inline members get no
  arity-queryable entry at all. The index is consulted as a refiner, not a primary.
  *This is the true root of run-vs-test divergence.* Evidence: `factRun`.

- **RC-B — no shared, type-aware applicability.** Applicability/overload matching is
  reimplemented at least three times (lowering ladder, runtime global scorer, runtime
  member scorer) with no shared core, and the lowering ladder is arity-only and
  type-blind. `shadowedByClass` + `findCand`/`arityMatch` (`expr.zig:4324-4364`) bind
  `Box(5)` to `fun Box(String)`; only `overload_match.zig:124` `builtinKindMismatch`
  rejects it at runtime, and only when the call deferred. The runtime re-rank
  (`pickOverloadCached`, `host_call_func.zig:1266`) is a safety net bypassed by exact
  casts (`eval.zig:2586`), `TailCallFunc`, and any lowering-only decision.
  `src/ir/applicability.zig` does not exist. Evidence: `factRun`.

- **RC-C — member-vs-global by a program-wide name set.** The decision uses
  `class_member_names` (a union over ALL pack+user classes) plus `inReceiverContext`,
  not the enclosing receiver TYPE's members. Six gate sites
  (`expr.zig:1099,3804,3961,4521,4931,4979`). `inReceiverContext` is true for any
  method body, false for top-level `main`, so identical bodies lower to different IR
  under run vs test. Evidence: `crossmember.kt`. This is the root of the null/broad
  receiver static-dispatch cluster (`orEmpty`, `minus`, local-ext-shadows-stdlib).

- **RC-D — name-keyed field storage.** `InstanceData.fields` is a flat
  `ArrayList(Field{name,value})` keyed by name only (`class.zig:318-353`); `define`
  overwrites. A subclass field with a parent's name aliases the parent's cell. Kotlin
  needs two distinct cells keyed by (declaring class, name) for a shadow, one shared
  cell for an override. A value-layer root cause below the dispatch layer; reproduces
  byte-identically run-vs-test. Evidence: `c_shadow` prints 2/2/2/2, expected 1/2/1/1.

- **RC-E — non-final vararg on the positional path.** The positional binders pack
  varargs only when the vararg is LAST (`host_call_func.zig:93`, member twin
  `host_call_member.zig:374`). A non-final vararg before a defaulted param crashes on
  a purely-positional call. The named binder handles it. Evidence: `e_vararg`.
  *(Landed — see below.)*

- **RC-F — reified inference is return-type-only.** `inferReifiedTypeArgs`
  (`inline_call.zig:276-313`) unifies only `f.return_type`, so a reified `T` inferable
  only from a lambda parameter annotation stays unbound and `x is T` is always-true.
  Evidence: `j2`. *(Landed — see below.)*

- **RC-G — typeck resolution discarded.** Typeck resolves overloads internally
  (`checkOverloadedCall`) but records nothing; `TypeCheck` exposes no `Span→FuncId`
  map (`check.zig:72-88`), and `klio run`/`test` never invoke typeck. Three overload
  oracles share no resolved-symbol channel. **The one-engine-two-modes design is the
  fix:** typeck is the eager mode of the same engine, so there is one oracle recorded
  once.

- **RC-H — hatch name-lists.** `isAliasName` (41 names), two near-duplicate
  builtin-supertype tables, three Throwable lists, `concreteSibling`, `tailrec_fn_names`,
  `shadowed_inline_names`, `isPrimitiveConv`, `CONTROL_INTRINSICS`. These exist only
  because the index is incomplete and applicability isn't shared/type-aware. Deleting
  them is the proof those fixes are complete.

  *Progress:* `isAliasName`'s hand list is deleted. The classifier is now an
  injected hook (`ir.host_bare_global_check`) built once per process from the
  implicit-alias table filtered by an existing implementation — exactly the
  set `vmNew` pre-installs into globals — so lowering and runtime classify
  bare host globals from one authority. The wider intrinsic registry is
  deliberately not swept into it: its package-level FQNs double as link-time
  bindings for bodyless receiver-formed declarations (`kotlin.text.nativeIndexOf`
  binds `String.nativeIndexOf`), and the registry carries no declaration shape
  to tell the two apart — the measured cost of intrinsics being holes instead
  of symbols, and the direct motivation for the north star above. The
  `to`/`downTo`-style exclusions stopped being a list too: the bare-call arms
  now ask `extensionCandidateFitsArity` (a same-named extension candidate
  whose value-parameter shape fits the argument count keeps the call on
  receiver-bound dispatch), answered from the now-complete phase-1 headers.
  Still cataloged for the same treatment: `stdlib.isToplevelFunction`'s
  `receiver_infix` exclusions, `isArrayBuilder`, `retainDecl`'s
  `isSequenceFactoryName`/`isCollectionFactoryName` curation lists,
  `emptyContainerCreatorArity`, and `ir.Module.default_import_packages`
  (mirrored from `stdlib.IMPLICITLY_IMPORTED_PACKAGES`, sync-tested only).

## Target architecture

1. **One canonical signature index (RC-A).** A per-`FuncId` `DeclSig` in `ir.zig`
   (subsuming `decl_user_arity`/`decl_user_sig`/`decl_user_params`): `{ fqn, package,
   simple_name, kind, enclosing_class, receiver_ty, params: []ParamSig{name, ty,
   has_default, is_vararg, is_function_typed}, type_params, is_inline, is_suspend }`.
   A new **phase 0** in `buildModuleWithOverrides` registers a `DeclSig` for every
   declaration — top-level funcs, constructors (keyed by class simple name), member
   methods, inline funcs — BEFORE class-lowering and phase-1. Three phases: (0) sig
   registration over all decls, (1) class body lowering, (2) top-level body lowering.
   `runTestFiles` routed through the same extend/image assembly as `run`.

2. **One type-aware applicability function (RC-B, RC-E).** New
   `src/ir/applicability.zig`: `pub fn applicable(sig, args: []const ArgShape, scope)
   ?Score`. `ArgShape = { ty: ?TypeRef, is_lambda, lambda_arity, lambda_param_types,
   is_named, is_spread }`, populated from lowering (lowered expr type / literal kind),
   runtime (value class name), or the eager engine (checked Type lowered to TypeRef).
   Folds in one place: named-arg-to-param, default padding, vararg packing at ANY
   position, trailing-lambda binding, per-arg type scoring. The two builtin-supertype
   tables merge into one relation derived from the hierarchy. Three callers, one
   function: lowering's `resolveCall`, runtime `pickOverload`/`pickMethodOverload`,
   eager `checkOverloadedCall`.

3. **`Module.resolveCall` — one resolver, index primary (RC-A, RC-B).** Tiers
   candidates by Kotlin scope, ranks the best non-empty tier by `applicable`, returns
   `Resolution{ target: FuncId, confidence: {exact, virtual, deferred},
   candidate_set }` — the three tiers above. A unique best → resolved `Call`/
   `CallVirtual`. A tie or runtime-only receiver → `CallMemberOrGlobal` carrying the
   candidate set. The heuristic ladder, `preferredBareTarget`,
   `resolveBareCallIndexed`-as-refiner, and the inline-vs-noninline split collapse into
   this. Constructors are ordinary candidates.

4. **Member-vs-global by enclosing-receiver type (RC-C).** Delete `class_member_names`
   and the `inReceiverContext` discriminator. A bare call inside a method queries the
   enclosing receiver type's member set via the sig index (walking the supertype
   closure by `ClassId`). Member-shadowable iff THIS receiver type (or a supertype) has
   an applicable member of that name+shape. Pure function of (call-site receiver type,
   sig index); independent of main-vs-`@Test`.

5. **Distinct-keyed inherited fields (RC-D) → the exact/virtual field tiers.** Change
   `InstanceData.Field` key from name to `(declaring_class: ClassId, name)`, exposed as
   a resolved `slot`. An override writes one cell (most-derived); a shadow writes a
   separate cell. A bare `x` in a method of class C resolves to the C-or-nearest-
   supertype cell; `super.x` reads the parent's; `(b as Base).x` reads via static type.
   Also fix `firstSupertypeName` to skip interfaces (`host_call_member.zig:6901`) and
   FQN-qualify the method walk after the first hop.

6. **Position-agnostic vararg packing (RC-E).** Unify the positional and named binders
   onto `applicability.zig`'s position-agnostic bind step. *(Landed.)*

7. **Reified inference from parameter positions (RC-F).** *(Landed.)*

8. **Eager mode records + reuses resolution (RC-G).** `TypeCheck.resolved_calls:
   Span→FuncId` + `Span→Type`. The eager engine calls the shared `resolveCall`/
   `applicable`. Lowering consumes `resolved_calls` when present (typeck-informed
   fidelity) and runs the same engine lazily when absent. Records feed the pack
   `typeck` section.

9. **Delete the hatches (RC-H) — the completeness proof.** After 1-5 land: delete
   `isAliasName`, the merged-away duplicate builtin table, `class_member_names`,
   `prefer_member`, `CONTROL_INTRINSICS`, `tailrec_fn_names` as an overload gate, the
   `concreteSibling` redirect (abstract instantiation → diagnostic), `isPrimitiveConv`,
   and the Throwable lists. Each deletion gated on `KLIO_RESOLVE_AUDIT`
   zero-disagreement + the full sweep.

10. **(Optional, post-resolution) flat bytecode + serialization.** Linearize the
    resolved IR into a flat threaded-dispatch stream; the same stream populates the
    pack `resolved` section. Gated on a dispatch-bottleneck measurement; unifies the
    in-memory `Inst` union with the lazy-IR byte section into one canonical stream.

## Working rule for this plan

Per CLAUDE.md ("Scope and regressions") and the user's directive: these are **big
coupled changes**, not green-preserving slivers. RC-A and RC-C must land **together**
(completing the index during class-body lowering flips member-vs-global decisions, so
the reorder is only safe once member-vs-global is receiver-type-aware — a P1-alone
attempt regressed −16, documented below). The canonical count is expected to dip for
several commits before climbing past the old baseline. Land the big change, then drive
it green. Root-causing still holds: never hide a failure; only the stay-green-every-
commit constraint is relaxed.

## Phases (big coupled changes, not shipped as unused abstractions)

- **P0 — Parity harness + unblock `klio test` resolution.** *(Landed.)* Each fixture
  emitted twice (`fun main` and `@Test`), byte-identical stdout. `kotlin.test` resolves
  under `klio test`.
- **P1+P4 (coupled) — canonical index (RC-A) + member-vs-global by receiver type
  (RC-C).** Build the phase-0 `DeclSig` index; switch member-vs-global to receiver-type
  membership; delete `class_member_names`. Expect a mid-flight dip. Verify: `factRun`
  5/5 and `crossmember.kt` no downgrade under run AND test; run-vs-test parity harness
  byte-identical.
- **P2 — `applicability.zig` (RC-B, RC-E).** One shared type-aware scorer +
  position-agnostic bind; merge the two builtin tables. Runtime callers switch first.
  Verify: `e_vararg` under run AND test; overload-by-type cluster (sumOf,
  compareToIgnoreCase, minus, NaN minOf/maxOf) resolves.
- **P3 — `Module.resolveCall`, switch bare-call emission (RC-A, RC-B).** Shadow behind
  `KLIO_RESOLVE_AUDIT` to zero disagreement, then switch. Verify: `factRun` 5/5.
- **P5 — Distinct-keyed inherited fields (RC-D) + super/method-walk fixes.** Verify:
  `c_shadow` 1/2/1/1; override still correct; `super.method` interface-skip correct.
- **P6 — Reified inference from parameter positions (RC-F).** *(Landed.)*
- **P7 — Eager mode records + reuses resolution (RC-G).** Typeck runs the shared
  engine, records `Span→FuncId`/`Span→Type`, emits diagnostics; lowering consumes them.
  Verify: typeck-vs-lowering zero disagreement; `klio check` diagnostics wired.
- **P8 — Delete the hatch name-lists (RC-H).** Each deletion audit-gated + full sweep.
- **P9 — (Optional) flat bytecode + pack `resolved`/`typeck`/`symbols` serialization.**
  Gated on a dispatch-bottleneck measurement and a startup/RSS justification.

## Verification

- **Ratchet:** stdlib commonTest baseline (`stdlib_commontest.zig`). Risky phases run
  the FULL sweep; the baseline is raised only after a real fix. A phase may *temporarily*
  drop the count (big coupled changes) but must climb past the prior baseline before the
  phase is called done.
- **`KLIO_RESOLVE_AUDIT` zero-disagreement** before switching any resolution path and
  before each hatch deletion; extended to flag type-blind agreement (index+heuristic
  agreeing on a wrong pick — the `factRun` blind spot).
- **Run-vs-test parity harness** (P0, required from P1+P4): each fixture emitted twice,
  byte-identical stdout.
- **Repro ratchet:** `factRun` → 5/5; `e_vararg` → `T4 [6,7,8] end`; `c_shadow` →
  1/2/1/1; `j2` → is/no. Each under BOTH run and test, each failing if its fix reverts.
- **Structural invariants:** (a) every bare-call resolution is a pure function of (call
  site, sig index); (b) `funcsBySimpleName` at file=0 == at any later file; (c) zero
  name-list lookups in the dispatch path; (d) runtime pick == lowering pick == eager pick
  for every non-runtime-polymorphic call.
- **Negative tests:** abstract instantiation diagnoses; a user class named
  `Error`/`Exception`/`Random` constructs via its own declaration; named args on a
  function-typed value diagnose rather than silently drop.

## RC-I — the Compose lowering pass is a second resolution engine

`compose_pass` runs as an AST transform from `buildModuleWithOverrides`, **before any
call is resolved**. To decide "is this callee composable", "how many leading value slots
does this lambda need", "does this callee inline its lambda", it consults program-wide
**simple-name maps**: `NameSetOracle`, `active_sink_arity`, `active_sink_last_param`,
`active_sink_content_reach`, `active_composable_props`, `active_composable_getter_props`,
`active_inline_fns`, `active_factories`, `active_composable_receiver_names`.

That is RC-C verbatim — decided by a program-wide name set instead of the receiver type —
living outside the resolver. Confirmed instances, each reproduced minimally:

- `contentColorFor`: the name is composable, so a *non*-composable `ColorScheme`
  extension of the same name was threaded and dispatch missed.
- `containerColor`: declared ~13 times across material3, mixed `@Stable` and
  `@Composable`, and `NavigationDrawerItemColors.containerColor(selected)` is composable
  with the **same arity** as the non-composable `CardColors.containerColor(enabled)`.
  No name-keyed or name+arity rule can separate them; only the receiver type can.
- sink arity: a `Scope.() -> Unit` sink reserves a leading receiver slot at the value
  invocation but not when the sink inlines. The shape depends on the callee, which the
  pass does not have.

Two properties make this worse than an ordinary hatch:

1. The pass's decisions are **irreversible AST edits**. Once `$composer` is appended to
   the wrong call, resolution only ever sees a call carrying two extra arguments.
2. Therefore every wrong guess must be **absorbed** downstream. `isGeneratedComposeArg`
   in `applicability.zig` is exactly such an absorber and joins the deletion catalog.

This also explains why progress on this plan presents as Compose regressions: the old
resolver's leniency was silently absorbing bad guesses, and tightening resolution removes
the shock absorber. `Scaffold` is the clean example — it passed only because the
baked-base sink-arity walk under-counted receivers, and unifying that walk removed the
compensating error.

### The split that makes the inversion tractable

- **Declaration side stays pre-resolution.** "Is this declaration `@Composable`" is a
  local, unambiguous annotation fact. Appending `$composer`/`$changed` to signatures and
  to function types, and emitting the restart bracket, needs no name lookup.
- **Call side defers to lowering.** Appending arguments, choosing lambda synthetic slots,
  and memo-wrapping all require the callee. The pass marks the site; lowering, which has
  `resolveCall` -> target `FuncId` + signature, decides.

Phase order dissolves the apparent chicken-and-egg (resolution needs signatures, and
threading changes signatures): declaration rewrite, then index, then resolve calls
against already-threaded signatures. This is what kotlinc does — its Compose plugin is an
IR lowering that runs after frontend resolution; klio's runs before.

### Phases

- **P10 — Compose decision audit.** For every threaded call site record the pass's
  decision; at lowering record the resolved target and whether it declares `$composer`.
  Report disagreements under the `KLIO_RESOLVE_AUDIT` family. This converts an open-ended
  crash stream into a finite, measurable worklist over the whole corpus, *including the
  wrong guesses that currently do not crash because something absorbs them*. Gate: the
  count may fall, never rise. **This lands before any further Compose refactoring.**

  LANDED (2026-07-25). The audit compares three things at the static-selection point:
  the generated pair vs the target's ABI (`selectedCallArgs` counts agreement and the
  silent strip), the lowering-side pair completion, and a pass-shaped lambda's param
  count vs the resolved parameter's declared arity. `KLIO_RESOLVE_AUDIT=1` prints one
  line per disagreement plus a cumulative summary per module build. Dynamic emission
  paths (`CallMemberOrGlobal` runtime re-dispatch) are not yet audited.

  **Baseline, material3 fixture set (2026-07-25): agree=8, pair-stripped=0,
  pair-completed=2335, lambda-arity=0.** Reading: at statically selected call sites the
  pass's appended pair almost never survives to emission — 99.7% of threaded calls get
  their pair from the LOWERING completion, which already implements "threading decided
  against the resolved callee". The P11 inversion is therefore mostly a matter of
  removing the pass's call-side append and widening the completion path, not building a
  new mechanism. The pass's remaining load-bearing work is declaration-side ABI and
  lambda shaping.
- **P11 — Call-side threading becomes resolution-driven.** Deletions:
  `active_composable_receiver_names`, `isGeneratedComposeArg`.
- **P12 — Lambda shaping from the resolved parameter type.** Deletions:
  `active_sink_arity`, `active_sink_last_param`, `active_sink_content_reach`,
  `active_composable_props`, `active_composable_getter_props`, `active_factories`.
- **P13 — Inline-ness from the declaration.** Deletions: `active_inline_fns` and its
  hardcoded stdlib inline list (`is_inline` survives the image — verified when the
  baked-base sink-arity walk was unified, so this may already be deletable).

### Two conformance targets, kept distinct

The Kotlin spec governs the **resolver**. Compose threading is a **compiler-plugin ABI**,
not spec behavior; its conformance target is kotlinc's plugin output. Keeping these
separate settles which document decides a given bug, and stops spec-compliance work from
being blamed for plugin-ABI mismatches.

### Invariants this adds

- (e) every composer-threading decision is a pure function of (call site, resolved target
  signature) — never of a simple name.
- (f) zero name-keyed maps remain in the Compose decision path; each deletion is the
  acceptance test for its phase.
