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

The fix the user commissioned: make typeck the eager mode of the one engine,
let lowering consume its answers, and replace the heuristics with systems.
No one-off patches for global/bare member handling.

## Architecture

Pipeline today: `run`/`test` = parse → lower → eval (lazy; typeck never runs).
`check` = parse → resolve → typeck (never lowers). The two sides resolve in
separate universes: typeck works off the resolver's `Resolution`+`FnSig`s;
lowering works off the IR module index (`FuncId`/`ClassId`).

Target pipeline: `run`/`test` = parse → resolve → typeck → lower(consuming
typeck) → eval. Typeck failures never block execution: any file typeck cannot
finish falls back to today's lazy lowering (recorded, auditable) — eagerness
is an accuracy upgrade, not a gate.

### The identity channel: call-span → decl-span → FuncId

Typeck cannot know `FuncId`s (it runs before lowering, on resolver output).
The bridge is source identity: every declaration has a span, both universes
see the same AST. Typeck records, per resolved call site,
`Span(call) → Span(decl)` (plus the rendered signature it already records).
Lowering maintains `Span(decl) → FuncId` as it lowers declarations (it
already knows each func's source span). Composing the two gives lowering an
exact, type-derived `FuncId` commitment per call site with no shared symbol
table and no name keys.

Similarly `Span(expr) → Type` (typeck's existing `types` map) gives lowering
declared/inferred types for receivers, arguments, and parameters — the
evidence the applicability engine currently reconstructs from AST string
probes (`argDeclTypeRef`, `local_decl_types`, `local_decl_nullable`).

## Phases

- **E0 — Identity substrate.** Typeck's `resolved_calls` gains the decl-span
  identity (`Span(call) → ResolvedCall{decl_span, render}`); the checker's
  `FnSig` carries the declaring function's span (threaded from the resolver's
  decl records). Lowering records `decl_span → FuncId` in the module as it
  lowers. Unit-tested round trip: an overloaded call's pick maps to the right
  `FuncId`.

- **E1 — Typeck in the run pipeline (off by default).** `klio run`/`test`
  under `KLIO_EAGER=1` run resolver+typeck over the user files (the stdlib
  stays image-loaded and is not re-typechecked; typeck already resolves
  stdlib callees through the resolver's builtin headers, as `klio check`
  does today). Results land on the module as `eager: ?EagerInfo` (the maps
  above, per file). A typeck panic or unresolved file simply leaves its
  spans absent. Perf is measured on the corpus before any default flip.

- **E2 — Consumption seams.** One at a time, each gated on E3's audit and
  the full battery; the lazy path stays the fallback for spans typeck did
  not answer:
  1. **Declared-type evidence**: receiver/argument typing consults
     `Span → Type` ahead of the AST string probes.
  2. **Bare-call commitment**: `resolveCall` consults the identity channel
     first; a typeck-committed target lowers as a direct call — the deferred
     CMG form is emitted only where typeck also had no answer.
  3. **Member-vs-global**: the receiver's type answers the membership
     question; the `class_member_names` conservative fallbacks become
     unreachable where types exist.
  4. **Param classification**: fn-typed / receiver-fn-typed / arity for
     every param (top-level, member, local, lambda) from typeck — replacing
     the `receiver_lambda_params` / `non_fn_params` marking system.
  5. **Classifier reads**: `C` vs `::C` vs nested-class references resolve
     through typeck's scope answer — subsuming `scopedClassIdForRead`.

- **E3 — Zero-disagreement audit.** `KLIO_EAGER_AUDIT=1` computes both
  answers wherever both exist and prints disagreements (reusing the
  `KLIO_RESOLVE_AUDIT` plumbing). Each E2 seam flips only at zero
  disagreements across the corpus battery; the audit stays wired as the
  permanent regression tripwire.

- **E4 — Heuristic replacement.** With seams live, each runtime heuristic is
  narrowed to the truly-dynamic residue or deleted, battery-gated:
  - `CallMemberOrValue`'s invocability guessing → exact emission per typeck
    (member, value-with-receiver, or ctor), the guessing arm kept only for
    spans with no eager answer;
  - the closure "+1 arity → receiver" rebind → explicit receiver-binding
    emitted from declared types;
  - the `hasOwnMember` implicit-this arm → typeck's member answer;
  - the CMG unknown-receiver fallbacks and `class_member_names` → deleted
    once receiver types cover the corpus (the old plan's P8 endgame).

- **E5 — Registry systems (typeck-independent, start immediately).** Two
  structural fixes the heuristics currently paper over:
  1. **One mangling, one lookup.** Nested classifiers register under a single
     canonical qualified form; every simple-name probe goes through one
     scope-walking lookup function (subsuming the `$`/`.` double-probe).
  2. **Id-keyed globals.** Class/object/companion singletons are keyed by
     `ClassId` in an id-keyed table; the name-keyed `globals` map becomes a
     view for user bindings only. Kills publication shadowing (a companion
     init can never change what a committed class read yields) and removes
     hash-order sensitivity from classifier reads.

## Verification

Every step: `zig build test`, the itest battery (litmus, e2e, corpus,
lambdas, inheritance, ext_res, object_init, ktor, typeck_negative), and the
per-file stdlib canonical (gains-only). The eager default flip additionally
requires zero `KLIO_EAGER_AUDIT` disagreements over the whole stdlib corpus
and a corpus wall-time measurement within budget. The stdlib failure
inventory (scratchpad perfail) is the campaign scoreboard: the goal is the
clusters dying by system, not by patch.
