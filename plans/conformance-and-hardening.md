# Conformance and hardening

The running plan for the next stretch. Two tracks — proving what the
interpreter actually passes (Conformance), and closing the structural
weak spots the last campaign's root-cause work exposed (Hardening) —
plus the carried measurement-gated perf roads.

Written 2026-08-18, directly after `simplify-validate-accelerate.md`
closed with `scripts/gate.sh` GREEN. That campaign fixed what the census
named; this one asks what the census does not name.

## Ground rules

- Measured-first, and the measurement is quoted in the record — including
  negatives, disproven premises, and floors. A round that disproves its
  own premise is a successful round if the disproof is written down.
- Measure on `zig-out/bin/klio-harness` (ReleaseSafe). The plain
  `zig build` binary is Debug and its profile is fiction.
- Heavy commontest suites are censused SOLO. Concurrent compose+ktor
  reported compose 1374 vs 1375 solo — contention flake reads exactly
  like a ratchet regression.
- The Zig build runner renders a PASSING run step that writes to stderr
  as "failed command". Trust `Build Summary: N/N steps succeeded` and the
  test counts, and use `--summary all`.
- Root-cause only. A conformance number that moves because a test was
  weakened, skipped, or re-pinned to observed output is a regression in
  this plan's terms, not progress.
- Big-changes-over-green still applies: a multi-commit red middle is fine
  when the plan is valid.

## State snapshot (measured 2026-08-17/18, not recalled)

Green where measured:

- `scripts/gate.sh` GREEN: unit, the 12-suite litmus batch, harness build,
  the 117-file stdlib dual-eager sweep.
- Corpus 335 programs run clean; e2e pins 292 outputs; differential 2/2
  (green for the first time on record); parity_corpus_pinned 251/251;
  threaded litmus 58 (conformance folded in).
- Ratchets: compose plugin 1375 (floor 1370), ktor 448 pass / 2
  closed-by-record (floor 440), io 1140, datetime 205, atomicfu 63,
  serialization 9.
- Perf: the aacbench rig fell ~10.2% last week (3649 -> 3275 ms/rep);
  compose_foundation_lazy warm 42.6s -> 1.069s (40x); ReleaseFast now at
  parity with ReleaseSafe (the no-fill lever removed the poison-memset
  gap).
- Scale: ~290k lines of Zig; the three former giant modules are
  21.5k / 13.6k / 9.6k after one split each.

The blind spot:

- `coroutines_commontest`: **350 passed, 896 failed, 3 did not complete**
  across 148 files, ratchet baseline **340**. CI is green while 72% of
  that suite is red. The register's "coroutine cluster CORRECTNESS
  COMPLETE" is true only of *recorded bugs*; it is not a conformance
  claim, and the two have been easy to conflate.
- 44 of 339 examples have no pinned expected output (3 are legitimately
  `// corpus: interactive`). They prove "runs without crashing", not
  "produces the right answer".
- Ratchets are pass-count FLOORS. A suite can sit at 28% passing forever
  and gate green.

## Track C — Conformance

- [ ] C1. Characterize the coroutines 896. Census every failure by error
      shape before fixing anything (the 44-crash census family collapsed
      to seven roots; expect the same shape here). Sampled evidence from
      five files (49 failures): `Vm::call_value on X` 67%,
      `unresolved global X` 24%, `Vm::get_field X on X` 8%. Deliverable:
      a full error-shape histogram with a named candidate root per
      bucket, ranked by blast radius.
- [ ] C2. The `kotlinx.coroutines.testing` support surface. Upstream's
      commonTest files all extend `TestBase` from that package, and every
      `runTest`/`expect`/`finish` call goes through it. The census
      (`src/itests/commontest_support.zig` + `coroutines_commontest.zig`)
      collects `.kt` only from `upstream/kotlinx-coroutines-core/common/test`
      and passes the no-`@Test` files as support; `TestBase` lives in
      `upstream/test-utils/common/src` + `klioTestUtils`, which are
      `[[test]]` roots of the pack but are NOT in the census's
      `test_roots`, so they never reach the child `klio test`.
      EVIDENCE, and the limit of it: hand-passing the three test-utils
      files changed the error from `unresolved global runTest` to
      `Vm::call_member runTest on kotlinx.coroutines.AsyncTest` — the
      support surface demonstrably matters, but that does NOT finish the
      job; something in the expect/actual chain still does not complete.
      Minimal `expect open class` repros PASS, including one with a
      superclass plus interface delegation (`by`), so this is narrower
      than a basic expect/actual gap. Find the real mechanism; do not
      assume the wiring fix is sufficient.
- [ ] C3. Ratchet honesty. Pass-count floors cannot see a regression
      inside the red mass. Add a failure-count ceiling (and a
      did-not-complete ceiling) alongside the floor for every census
      suite, seeded from the current measured numbers, so both directions
      are gated. Note the coroutines suite's floor (340) sits far below
      its own solo pass count (350) — floors that lag reality hide
      movement in both directions.
- [ ] C4. Corpus pinning. 44 examples run with no expected output. For
      each: pin the output (kotlinc-verified where the program is
      representable) or mark it `// corpus: interactive` with the reason.
      An example that asserts nothing is a smoke test wearing a
      conformance badge.
- [ ] C5. Stdlib surface inventory. `kotlin.system.measureTimeMillis`
      was simply never shipped and was found only because a perf rig
      happened to call it. Build the inventory that would have caught it:
      what upstream declares (the curated include lists +
      `kotlin/libraries/stdlib`) versus what klio resolves, as a
      generated report. Do not chase the diff to zero; rank it and record
      the deliberate omissions.

## Track H — Hardening

The weak spots the last campaign's root-cause work exposed. Each one is
evidence-backed; none is a hypothetical.

- [ ] H1. Cross-program state in one process. SEVEN distinct roots landed
      last week (shared anon side-module and its clone crossing a
      boundary, generation-stamped dispatch caches, the bytecode stream
      cache, intrinsic intern keys, the GC remembered set, the
      expr-body member AST registry). The runtime was built
      one-program-per-process; every process-global cache, registry and
      side-module is a latent contamination bug for the in-process
      drivers. Do the systematic pass the incremental fixes never did:
      enumerate every process-global mutable in `src/` that outlives a
      program, classify each (per-program / shared-immortal /
      shared-mutable), and give the per-program ones a single audited
      reset path instead of the current scatter of hand-written resets.
      `KLIO_GC_STRESS` and the differential order test are the oracles.
- [ ] H2. Two resolution paths that can disagree. `positional_lambda_binding`
      passed through the CLI's eager typeck map and FAILED through the
      lazy engine in base mode — the same program, two answers, and the
      divergence was invisible until a driver switched paths. Establish
      whether the eager map and the lazy engine are meant to be
      equivalent; if yes, build the differential that proves it (run the
      corpus both ways and diff the resolved targets, the way
      `KLIO_RESOLVE_AUDIT` already reports per-call decisions); if no,
      document which is authoritative where. Correctness that depends on
      which driver ran is not correctness.
- [ ] H3. The coroutine park/wake contract. Three real bugs in one week:
      a cross-thread activation resume dereferencing the parker's dead
      TLS (SEGV), a dispatched task's internal failure never waking the
      parked root (silent hang), and the pool's `first_error` being read
      only at the run boundary. The machinery (pump, gate, park tokens,
      abandon flags) is complex and its invariants live in comments.
      Write the contract down in `COROUTINE-MODEL.md` as testable
      statements, then add litmus fixtures for the ones with no coverage
      — every terminal state of a dispatched task, not just the
      user-throwable path that `tl_dispatched_failure_*` pins.
- [ ] H4. Dispatch-ladder density. `host_call_member.zig` is 13.6k lines
      after extraction and measures 50-67 lines per `pub` extractable,
      meaning nearly every decl touches shared state. It is both the
      largest bug surface and a measured perf tax (A2 found late-resolving
      calls re-probing four sites per call at ~1.2us each; the fix was a
      cacheability gate reading the wrong candidate count). Not a
      splitting exercise — the goal is to reduce the number of tiers a
      single call can traverse, measured by the `member_ladder` counter
      and the rig.
- [ ] H5. Memory model. Per-program cells are minted permanent and never
      swept, with a boundary sweep added last week (program-perm
      generation, `drainRemembered`, boundary trims, base-key grouping).
      That is a mitigation, not a model. Decide whether the in-process
      drivers should get a real per-program heap; the acceptance number
      is the 6.5GB itest cap, which e2e and differential now clear but
      without much headroom.

## Track P — Carried perf roads (measurement-gated)

Open ONLY on a motivating measurement, per their own plans.

- [ ] P1. Cheapest module cuts left, measured: in `eval.zig` the
      value-operation band (arithmetic / comparison / rendering / const
      materialisation) at 1486 lines for 10 `pub`s, and suspend
      snapshot+liveness at 442/5 — both zero-state-crossing. In
      `expr.zig` and `host_call_member.zig` every remaining candidate
      either crosses module state or pays worse than what already landed;
      cutting there is churn, not cleanup.
- [ ] P2. A2 residuals: ~920k per-run cache-hit `irMethodWalk` entries on
      scoped routes still using the recursive invoker; trace ops are
      15.3% of executed dispatches.
- [ ] P3. Transpiler C-to-C frames (non-leaf callees) and wider hot-op
      coverage — `c-transpiler-plan.md`.
- [ ] P4. Value 24 -> 16 endgame (both IrClosure and Array must drop under
      8B or it pays nothing) — `value-layout-campaign.md`; gate any
      candidate on the compose suite wall as well as rangebench.
- [ ] P5. The ~300x interpreted compute floor (the compose suite wall) is
      measured and understood; it moves only on a generic speed lever or
      the transpiler. Not a front — a floor.

## Carried open items

- [ ] `tl_atomic_update_contended` litmus flake — watch state, postmortem
      on the next natural occurrence (the sweep prints got-vs-expected).
- [ ] ktor: the widened pack includes are validated by the commontest
      census only; the ktor_server/client e2e itests gate them in CI.
      `KTOR-SERVER-UPSTREAM.md` residue: the serialization shim swap
      (blocked upstream) and the start-path connector-logging flake.
- [ ] compose: movableContentOf factory-wrap widening and the group
      start/end imbalance op-trace probe (both latent, waiting for a
      failure that names them); non-private member-extension-property
      tower gating (the public half cost ~400 tests — needs receiver-tower
      emulation).
- [ ] The 2 ktor URLBuilder scheme-with-digits failures are CLOSED BY
      RECORD — klio matches Kotlin semantics and must NOT be "fixed".

## Order of work

1. C1 characterize the 896 — everything else in Track C is scoped by what
   the histogram says.
2. C2 the testing-support mechanism — the largest single bucket, and the
   one with a live unproven hypothesis.
3. C3 ratchet ceilings — cheap, and it stops the next blind spot from
   forming while the rest of the work runs.
4. H1 the process-global audit — the highest-density bug class found so
   far, and it protects every census run that follows.
5. H2 resolution-path equivalence — correctness-by-luck is the most
   uncomfortable thing on this list.
6. C4/C5, then H3/H4/H5 as their evidence accumulates.
7. Track P only when a measurement motivates it.

Each landing runs the full battery (harness sweep, litmus, compose plugin
ratchet solo, ktor ratchet solo, corpus, module unit tests) and commits
directly to main.
