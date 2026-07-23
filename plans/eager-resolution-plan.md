# Eager resolution: typeck-informed lowering and the end of dispatch heuristics

## Why

The resolution-unification plan unified the LOWERING-TIME engine: when klio can
commit a call statically, the index answers and the answer is right. What it
deferred (its own P7 "consumption half") is the other layer: whenever lowering
cannot commit — generic parameters, callable references, function-typed values,
unknown receivers — it emits a deferred instruction and the RUNTIME re-decides
the name's meaning with name-keyed lookups and shape heuristics. Every
stdlib-corpus failure cluster of the past campaign lived in that layer:

- `CallMemberOrValue` guessing invocability by value tag, then racing a
  member probe against a fallback local;
- the closure invoke path guessing "arity+1 means the first arg is a
  receiver";
- `hasOwnMember` treating a nested CLASS name as a callable member;
- one `LoadGlobal` serving both `C` (companion in value position) and `::C`
  (constructor), so a companion init could shadow a constructor reference;
- two mangling conventions (`Outer.Nested` vs `Outer$Companion`) behind
  simple-name registries, so scoped-classifier probes need per-site fixes;
- picks that flip between builds (hash-order-dependent iteration), which by
  definition cannot be hardened test-by-test.

The fix: make typeck the eager mode of the one engine, let lowering consume its
answers, and replace the heuristics with systems. No one-off patches for
global/bare member handling.

## Completed (E0–E3)

- **Identity substrate (E0).** Typeck records, per resolved call site,
  `Span(call) → ResolvedCall{decl_span, render}` in `resolved_calls`
  (`src/typeck/check.zig`, filled in `expr_calls.zig`); lowering maintains
  `decl_span → FuncId` (`func_by_decl_span` + `eagerCallTarget`, `src/ir/ir.zig`).
  Composing the two gives lowering an exact, type-derived `FuncId` per call site
  with no shared symbol table and no name keys. `Span(expr) → Type` supplies
  declared/inferred types for receivers, arguments, and parameters.
- **Typeck in the run pipeline (E1).** `KLIO_EAGER=1` runs resolver+typeck over
  the user files ahead of lowering (`src/cli/commands.zig`); results land on the
  module as `eager: ?EagerInfo`. Typeck failures never gate execution — any file
  typeck cannot finish falls back to lazy lowering. `KLIO_EAGER_AUDIT` /
  `KLIO_EAGER_HITS` are wired; the parity harness runs with `KLIO_EAGER=1`.
- **Consumption seams (E2), live:** seam 1 (declared-type evidence — receiver /
  argument typing consults `Span → Type` ahead of the AST string probes,
  additive-only with primitives excluded) and seam 2 (bare-call commitment —
  `resolveCall` consults the identity channel first; the deferred CMG form is
  emitted only where typeck had no answer).
- **Zero-disagreement audit (E3).** `KLIO_EAGER_AUDIT=1` computes both answers
  wherever both exist and prints disagreements (reusing `KLIO_RESOLVE_AUDIT`
  plumbing); each seam flips only at zero disagreements and the audit stays wired
  as the permanent regression tripwire.

The still-open consumption seams (E2 seams 3–5: member-vs-global, param
classification, classifier reads) advance behind E4 below as their trust surface
is completed.

## Open work

### E4 — heuristic replacement

Each runtime heuristic narrows to the truly-dynamic residue or is deleted,
battery-gated; every narrowing's prerequisite is that the identity/type channel
covers the heuristic's full decision context first. Queue state:

- **implicit-this redirect: LANDED** — the member-shadow record gate walks
  declared AND inherited members (`classChainHasMember`), and a
  channel-committed `.plain` target skips the redirect.
- **closure +1-arity rebind: LANDED AS DECLARED SHAPE.** Under live HTTP traffic
  the ktor pipeline fired the binding 174 times across a short request set, so
  the behavior is required for host-driven receiver-lambda invocations.
  `Func.lambda_has_receiver` now records the typeck/lowering answer,
  `ClosureInfo.has_receiver` carries it into invocation, and the VM splits the
  leading receiver only when that bit is set. A `this` capture is no longer used
  as receiver evidence. Receiver lambdas that never read their receiver are
  covered explicitly, as are anonymous functions with a declared receiver; the
  image format is version 29 so the bit is identical in baked and direct runs.
- **`CallMemberOrValue` exact value emission: landed for proven calls.**
  First: the hierarchy sets cannot disprove EXTENSIONS (stdlib extensions on the
  receiver's type win over a local callable — the MinMax family measured it).
  Second: the extension-candidate index (`Module.extCouldApply` — landed, kept)
  was unsound at lowering time against the image's lazily-decoded func headers:
  a deferred `IntArray.min` header carried no receiver param until its body
  decoded, so the index answered "no extension" while one existed
  (`elements.min()` bound the Int param named `min`). The index now derives from
  the complete declaration index and image-preserved `DeclSig.receiver_ty`,
  including the lazy base-function range; it no longer reads materialized
  function parameters. Source and image tests pin the bodyless-header case.
  The lowerer now emits `CallValueWithThis` when the in-scope value is known to
  have a receiver-function shape and the receiver's complete hierarchy plus the
  extension index prove no member or extension can compete. Known or incomplete
  member and extension surfaces retain `CallMemberOrValue`. An unbounded
  type-parameter receiver removes the member leg but does not prove a same-named
  local callable, so it takes the exact path only with declared
  receiver-function shape. All generated MinMax
  `min`/`max` sites remain deferred, while the audit shows exact production
  sites for `block`, `contains`, `get`, and `iterator`. The full 117-file sweep
  is unchanged and eager-identical at its one existing ULong range-sort failure.
  A Compose exact-vs-deferred A/B reached the same stale field read after 18
  `SnapshotStateMap` tests, proving the static call form was not its cause. The
  failure was the native-intrinsic GC boundary: intrinsic args, iterator
  results, and user `Map.Entry` values were invisible during Kotlin re-entry.
  Those values are now rooted, and the former failing map-copy test passes
  under collect-at-every-safe-point; the Compose gate runs that stress check
  before its pass-count sweep.
- **literal-coercion gap: NEUTRALIZED** — the only live path was eager primitive
  fills, which the channel excludes. The enhancement that would let primitives
  fill is a numeric-family-aware evidence comparison in applicability (Int
  evidence vs Byte param is not definite for literal-typed values); worthwhile,
  canonical-gated, not urgent.

With the seams live, the endgame per heuristic: `CallMemberOrValue`'s
invocability guessing remains only where member or extension competition is
real or declaration metadata is incomplete; the closure
"+1 arity → receiver" rebind → explicit receiver-binding from declared types;
the `hasOwnMember` implicit-this arm → typeck's member answer; the CMG
unknown-receiver fallbacks and `class_member_names` → deleted once receiver
types cover the corpus.

### E5 — registry systems (typeck-independent, start immediately)

Two structural fixes the heuristics currently paper over; unstarted:

1. **One mangling, one lookup.** Nested classifiers register under a single
   canonical qualified form; every simple-name probe goes through one
   scope-walking lookup function (subsuming the `$`/`.` double-probe).
2. **Id-keyed globals.** Class/object/companion singletons are keyed by
   `ClassId` in an id-keyed table; the name-keyed `globals` map becomes a view
   for user bindings only. Kills publication shadowing (a companion init can
   never change what a committed class read yields) and removes hash-order
   sensitivity from classifier reads.

## Verification

Every step: `zig build test`, the itest battery (litmus, e2e, corpus, lambdas,
inheritance, ext_res, object_init, ktor, typeck_negative), and the per-file
stdlib canonical (gains-only). An eager default flip additionally requires zero
`KLIO_EAGER_AUDIT` disagreements over the whole stdlib corpus and a corpus
wall-time measurement within budget. The goal is the failure clusters dying by
system, not by patch.
