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
  closed-by-record (floor 440), io 1140, datetime 457 (floor 450,
  raised this round from 210), atomicfu 63,
  serialization 60 (floor 60).
- Perf: the aacbench rig fell ~10.2% last week (3649 -> 3275 ms/rep);
  compose_foundation_lazy warm 42.6s -> 1.069s (40x); ReleaseFast now at
  parity with ReleaseSafe (the no-fill lever removed the poison-memset
  gap).
- Census conformance after this round: coroutines 1073, datetime 457,
  io 1157, serialization 60, ktor 448, atomicfu 63.
- Scale: ~290k lines of Zig; the three former giant modules are
  21.5k / 13.6k / 9.6k after one split each.

The blind spot (CLOSED 2026-08-18 — kept as the record of what was
hidden and how it was found):

- `coroutines_commontest` was **350 passed / 896 failed / 3 incomplete**
  behind a ratchet floor of **340** — CI green while 72% of the suite was
  red. 98.3% of those failures were three resolution shapes and only ~14
  were real assertion failures. Root: upstream's commonTest extends
  `TestBase` from `kotlinx.coroutines.testing`, which lives in the pack's
  `[[test]]` roots and never reached the child. Wiring it as
  `extra_support`: **1073 passed / 137 failed**, floor 340 -> 1040.
- `serialization_commontest` was **9 / 129** behind a floor of 9. Two
  roots: a missing `expect val currentPlatform` actual (klio reports
  NATIVE, mirroring upstream's nativeTest), then a deliberately narrow
  17-file pack include list. **60 / 78**, floor 9 -> 60.
- `datetime_commontest` was **212 / 291** behind a floor of 205 — a MIX,
  not one root: eleven distinct roots, nine of them in the interpreter and
  shared by every program. **457 / 62**, floor 210 -> 450.
- Corpus: 18 `.out` files sat in `examples/` while e2e reads only
  `tests/corpus/expected/`, so those guards were never enforced (all 18
  matched current behavior — nothing had regressed behind the gap). Pins
  292 -> 320 enforced by e2e, plus 16 in `tests/corpus/expected-cli/` for
  the programs the in-process runner cannot execute at all.
- Ratchets were pass-count FLOORS only. Every census now carries
  `max_failed` and `max_incomplete` ceilings seeded from a solo
  measurement, verified by negative control.

The lesson worth carrying: three censuses in a row were not measuring
their libraries, they were measuring klio's own resolution and receiver
machinery. Conformance work IS interpreter work.

## Track C — Conformance

- [x] C1. Characterize the coroutines 896. Census every failure by error
      shape before fixing anything (the 44-crash census family collapsed
      to seven roots; expect the same shape here). Sampled evidence from
      five files (49 failures): `Vm::call_value on X` 67%,
      `unresolved global X` 24%, `Vm::get_field X on X` 8%. Deliverable:
      a full error-shape histogram with a named candidate root per
      bucket, ranked by blast radius.
- [x] C2. The `kotlinx.coroutines.testing` support surface. Upstream's
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
- [x] C3. Ratchet honesty. Pass-count floors cannot see a regression
      inside the red mass. Add a failure-count ceiling (and a
      did-not-complete ceiling) alongside the floor for every census
      suite, seeded from the current measured numbers, so both directions
      are gated. Note the coroutines suite's floor (340) sits far below
      its own solo pass count (350) — floors that lag reality hide
      movement in both directions.
- [x] C4. Corpus pinning. 44 examples run with no expected output. For
      each: pin the output (kotlinc-verified where the program is
      representable) or mark it `// corpus: interactive` with the reason.
      An example that asserts nothing is a smoke test wearing a
      conformance badge.
- [x] C5. Stdlib surface inventory. `kotlin.system.measureTimeMillis`
      was simply never shipped and was found only because a perf rig
      happened to call it. Build the inventory that would have caught it:
      what upstream declares (the curated include lists +
      `kotlin/libraries/stdlib`) versus what klio resolves, as a
      generated report. Do not chase the diff to zero; rank it and record
      the deliberate omissions.
      DONE 2026-08-18 — `scripts/stdlib-surface-inventory.py` (fc1472e9).
      klio provides 986 public top-level names across 28 packages; upstream
      declares 1791 across 87; 805 names in 51 packages are absent, most
      correctly out of scope (org.w3c.* 180+, kotlin.js, kotlin.jvm
      internals). `--probe <pkg>` CONFIRMS a package's suspects by
      compiling references to them, because the static diff alone
      misleads: runtime builtins (Comparator, AssertionError,
      ArithmeticException) show as false positives, and `check` only
      resolves a reference inside `main`'s body — a bare `run { X }` in an
      unreferenced function reported nothing even for names that do not
      exist. Confirmed gaps worth reading: kotlin.text 21/34 (Charsets,
      codePointAt, concat, intern), kotlin.io 42/49, kotlin.collections
      12/18, kotlin.concurrent 9/11 (withLock, timer, getOrSet). These are
      the measureTimeMillis class — recorded, not chased.

### Round record — kotlinx-datetime (2026-08-18)

Measured, solo, on `zig-out/bin/klio-harness`:
`itest-datetime_commontest` **212 passed / 291 failed / 1 incomplete ->
457 passed / 62 failed / 0 incomplete** across the same 56 files. Ratchet
raised 210 -> 450, `max_failed` lowered 300 -> 70, `max_incomplete` 5 -> 1.

The census said the suite was a MIX, not one root, and it was: eleven
distinct roots, nine of them in the interpreter and shared by every
program. Ranked by the failures each closed:

1. **Format DSL absent from the pack** (~155). The `klio.toml` include list
   skipped `format/**` + `internal/format/**` on the premise that klio has
   no `kotlin.time`; that premise is stale (kotlin.time ships). Consuming
   them, plus the `Format`/`Formats`/`parse(input, format)` members on the
   klio-supplied value types, is what the whole format half of the suite
   needed.
2. **A bound reference used as a receiver-function** took the supplied
   `this` as its DISPATCH receiver instead of its first ARGUMENT
   (`obj.condition()` is `predicate.test(obj)`).
3. **`::localFn` in a `T.() -> R` slot** was dispatched as a plain value
   call, so the receiver never reached the parameter it fills.
4. **An inline splice suspended receiver-lambda marks by NAME**, so a
   caller parameter that happened to share the inline function's parameter
   name lost its receiver (`fun mk(block: C.() -> Unit) = C().apply { block() }`).
5. **A lambda argument bound a member whose slot is the owner's type
   variable** even though a same-arity extension declared that slot as a
   function type — Kotlin ranks members over extensions only among
   APPLICABLE candidates.
6. **The integral range builders** (`until`/`downTo`/`step`) are probed by
   package FQN before the extension fallback, so `date.until(other, unit)`
   and `range.step(period)` were captured by the builtin. They now decline a
   non-integral argument, and a property GETTER binding declines an
   argument-bearing call.
7. **A companion member lost to a same-named global class**: the
   nested-class probe on a class receiver fell back to the global
   simple-name index before companion forwarding, so
   `ParseResult.Error(pos) { … }` constructed `kotlin.Error`.
8. **A local extension function could not call itself** — the
   self-reference scan never looked in member-call position, the name was
   not bound before the body lowered, and a cell-valued callee did not
   deref in `CallValueWithThis`.
9. **A fully solved generic call discarded its substituted return** when
   the CALLER's own type parameter remained in it, so
   `List<Box<T>>.asReversed()` typed as the callee's erased `List<T>`.
10. **An extension type-parameter bound that is itself a type parameter**
    (`C : R` on `ifEmpty`) refuted every receiver.
11. **A bare CALL in a constructor-delegation thunk routed a PROPERTY name
    to the owner class** (`: this(totalMonths(y, m), d)` next to a
    `val totalMonths`).

Harness: `commontest_support.zig` gains `whole_source_set`, which compiles
the whole test source set into each child and runs only the target file's
tests (`klio test --only-file`). Upstream commonTest is one compilation
unit, so a helper declared top-level in one `@Test`-bearing file
(`checkComponents`) is visible from another; the one-target-per-child model
could not see it. Opted into per suite; datetime is the first user.
`scripts/commontest-census.py` reads the same flag.

Recorded, not fixed:

- The pure-Kotlin IANA tz database (`Tzfile`/`TimeZoneRules`/`PosixTzString`)
  is not ported — klio resolves zones through a chrono-backed host binding
  instead. `TimeZoneRulesTest` / `ThreeTenBpTimeZoneTest` test that port
  directly and cannot pass without it (4 cases).
- `LocalDateTest.fromEpochDays` walks ~1.4M epoch days constructing a
  LocalDate per step: ~3 minutes interpreted. That is a compute floor, not
  a hang; the suite's per-file budget was raised to let it finish instead
  of silently dropping the file's results.
- `println(listOf(userObject))` renders element identity rather than the
  element's `toString` (pre-existing; confirmed against the pre-round
  binary). Not on the datetime path.

## Track H — Hardening

The weak spots the last campaign's root-cause work exposed. Each one is
evidence-backed; none is a hypothetical.

- [x] H1. Cross-program state in one process. SEVEN distinct roots landed
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
      DONE 2026-08-18 — audit in `docs/development/process-globals.md`.
      All 53 contamination-capable globals across ir/interp_ir/runtime/
      stdlib enumerated and classified: every one carries a defense or is
      immortal by construction, and NO undefended per-program global
      remained (the seven roots fixed last campaign were the real ones).
      The audit's value is naming the four defenses the codebase already
      uses ad hoc — boundary reset, generation stamping, identity
      verification on lookup, scoped lifetime — with when each applies and
      their reference implementations, plus a contract that new global
      state must declare its defense in the same commit. Recorded
      exception: `lenient_warned` is not reset per program, so a second
      program can lose a leniency warning (suppresses a diagnostic, never
      changes a result).
- [x] H2. Two resolution paths that can disagree. `positional_lambda_binding`
      passed through the CLI's eager typeck map and FAILED through the
      lazy engine in base mode — the same program, two answers, and the
      divergence was invisible until a driver switched paths. Establish
      whether the eager map and the lazy engine are meant to be
      equivalent; if yes, build the differential that proves it (run the
      corpus both ways and diff the resolved targets, the way
      `KLIO_RESOLVE_AUDIT` already reports per-call decisions); if no,
      document which is authoritative where. Correctness that depends on
      which driver ran is not correctness.
      DONE 2026-08-18 — `docs/development/resolution-paths.md`. They are
      NOT meant to be equivalent and the precedence is already defined:
      where the eager typeck map has an entry it WINS (type-derived and
      overload-precise vs the lazy engine's shape-based scoring), with one
      guard against a pick that resolves back to the enclosing declaration.
      MEASURED with KLIO_EAGER_AUDIT over 60 corpus examples: 4
      disagreements, ALL of the shape `eager=<fid> lazy=-1` — the lazy
      engine declining and eager supplying — and ZERO cases where both
      answered differently. So the paths never contradict; eager
      supplements.
      The real finding is structural: `pending_eager_calls` is built ONLY
      under `src/cli/` — `src/parity/parity.zig` never builds it. So
      `klio run`, `klio test`, bundles and corpus_check.py resolve WITH
      the map, while e2e, differential, every parity itest and the
      commontest censuses resolve WITHOUT it. That is precisely the
      positional_lambda_binding shape: it ran under the CLI and failed in
      base mode, and the eager map had been hiding a real lazy-scorer gap.
      Coverage asymmetry recorded: the parity path is output-pinned (320
      expected outputs) while the CLI path — the one users run — is mostly
      exit-code-checked (16 pins). Rule written down: never "fix" a parity
      failure by teaching parity to build the eager map; that would hide
      lazy-engine gaps from the only suites that catch them.
- [x] H3. The coroutine park/wake contract. Three real bugs in one week:
      a cross-thread activation resume dereferencing the parker's dead
      TLS (SEGV), a dispatched task's internal failure never waking the
      parked root (silent hang), and the pool's `first_error` being read
      only at the run boundary. The machinery (pump, gate, park tokens,
      abandon flags) is complex and its invariants live in comments.
      Write the contract down in `COROUTINE-MODEL.md` as testable
      statements, then add litmus fixtures for the ones with no coverage
      — every terminal state of a dispatched task, not just the
      user-throwable path that `tl_dispatched_failure_*` pins.
      DONE 2026-08-18 (70887b3b). COROUTINE-MODEL.md now opens with the
      terminal-state contract as a table of testable statements: each state
      a dispatched task can reach, its required observable outcome, and the
      fixture pinning it — so an unpinned state reads as a gap, not a
      convention. Plus the two invariants learned from the failures (a
      resume may land on a different thread than the park; an internal
      error is not a Kotlin throwable, so nothing will ever resume a root
      waiting on it).
      Two uncovered states probed, verified correct, then pinned:
      CancellationException from a dispatched child is NOT a failure (the
      parent survives — one `throw` from the fixtures pinning the
      opposite), and a throw AFTER suspension lands on the resuming worker
      yet must behave identically to the pre-suspension case. Litmus
      58 -> 60. One probe of mine initially read rc=0 for an uncaught
      exception; that was my own pipeline taking `tail`'s exit code, not
      klio's — the behavior was correct throughout.
- [x] H4. Dispatch-ladder density. `host_call_member.zig` is 13.6k lines
      after extraction and measures 50-67 lines per `pub` extractable,
      meaning nearly every decl touches shared state. It is both the
      largest bug surface and a measured perf tax (A2 found late-resolving
      calls re-probing four sites per call at ~1.2us each; the fix was a
      cacheability gate reading the wrong candidate count). Not a
      splitting exercise — the goal is to reduce the number of tiers a
      single call can traverse, measured by the `member_ladder` counter
      and the rig.
      CLOSED 2026-08-18 BY MEASUREMENT — the premise was already satisfied
      and the honest answer is that no further work here is justified.
      `KLIO_DISPATCH_STATS` on the aacbench rig: 40.5M dispatches, of which
      `member_ladder` is **40,318 = 0.10%**. The A3 round's relaxed-key
      cacheability fix took it 160k -> 40k, so the ladder is no longer a
      measurable perf tax; the profile's top entries are now memset 7.6%,
      runFrameExec 7.4%, eqlBytes 3.8% — none of them the ladder. Rig at
      3345 ms/rep.
      The structural half is bounded rather than open: the S2 landing took
      the file 16057 -> 13628 and MEASURED its extraction ceiling at ~50-67
      lines per `pub`, with every route-shaped candidate rejected because
      module state crosses the boundary (the positional-call route alone
      would drag 12 state variables; the cache tier cannot move at all
      because `tl_perm_cache`/`tl_resolve_cache` are read from outside it).
      Cutting further is deliberate churn, not cleanup.
      What would reopen this: a profile where a dispatch route, not the
      frame loop or the allocator, tops the list.
- [x] H5. Memory model. Per-program cells are minted permanent and never
      swept, with a boundary sweep added last week (program-perm
      generation, `drainRemembered`, boundary trims, base-key grouping).
      That is a mitigation, not a model. Decide whether the in-process
      drivers should get a real per-program heap; the acceptance number
      is the 6.5GB itest cap, which e2e and differential now clear but
      without much headroom.
      DECIDED 2026-08-18 — no per-program heap, and here is the number the
      decision rests on. MaxRSS from the build runner, solo:
        e2e           4G against the 6.5G cap  (~38% headroom)
        differential  6G against the 6.5G cap  (~8% headroom)
      e2e is comfortable. differential runs at ~92% of the cap because it
      is inherently the worst case: the whole corpus times two load modes
      in one process, with a base cache of 2 (one base per mode of the
      current mask — it cannot drop to 1 the way e2e's did).
      A real per-program heap is a large architectural change and the
      evidence does not justify it: both suites pass, and the mitigation
      landed last campaign (program-perm generation, boundary drains,
      malloc_trim, forced slab reclaim, base-key grouping) is what took
      differential from over-cap to green for the first time on record.
      TRIP-WIRE, recorded so this is a decision rather than an omission:
      differential's ~8% margin is the thing to watch. If it trips, the
      cheap lever is to shard it by load mode into two processes — the
      same fix that solved e2e's RSS problem — and only if THAT proves
      insufficient does a per-program heap become the motivated change.

## Track P — Carried perf roads (measurement-gated)

Open ONLY on a motivating measurement, per their own plans.

EVALUATED 2026-08-18 — the measurement was taken and does NOT motivate any
of them, which is the completion criterion for a gated item. Evidence, on
`zig-out/bin/klio-harness` at this campaign's HEAD:

- aacbench rig **3342 / 3328 / 3352 ms per rep**, statistically identical
  to the 3275-3345 measured after the A2/A3 rounds. So the ~25 interpreter
  fixes this campaign landed (parser, lowering, reified inference, member
  and receiver dispatch, range builders) cost NOTHING in wall time — worth
  stating, because a conformance campaign that quietly taxed the hot loop
  would be a bad trade even with the pass counts up.
- `KLIO_DISPATCH_STATS`: 40.5M dispatches, `member_ladder` **0.10%**. No
  dispatch route is hot (H4).
- `KLIO_PROF` top: memset 7.6%, runFrameExec 7.4%, eqlBytes 3.8%. The
  frame loop and the allocator, not any P item — and A2 already built the
  obvious lever there (const+binop fusion), measured it NEGATIVE (+0.95%),
  and reverted it.
- Module sizes after the S2 first pass: eval.zig 9637, expr.zig 21623,
  host_call_member.zig 13795, with measured extraction ceilings saying
  further cuts are churn (P1).

Each item below therefore stays closed-until-motivated, with its trigger
named. Reopening one without a fresh measurement would violate this plan's
own first ground rule.

- [x] P1. Cheapest module cuts left, measured: in `eval.zig` the
      value-operation band (arithmetic / comparison / rendering / const
      materialisation) at 1486 lines for 10 `pub`s, and suspend
      snapshot+liveness at 442/5 — both zero-state-crossing. In
      `expr.zig` and `host_call_member.zig` every remaining candidate
      either crosses module state or pays worse than what already landed;
      cutting there is churn, not cleanup.
- [x] P2. A2 residuals: ~920k per-run cache-hit `irMethodWalk` entries on
      scoped routes still using the recursive invoker; trace ops are
      15.3% of executed dispatches.
- [x] P3. Transpiler C-to-C frames (non-leaf callees) and wider hot-op
      coverage — `c-transpiler-plan.md`.
- [x] P4. Value 24 -> 16 endgame (both IrClosure and Array must drop under
      8B or it pays nothing) — `value-layout-campaign.md`; gate any
      candidate on the compose suite wall as well as rangebench.
- [x] P5. The ~300x interpreted compute floor (the compose suite wall) is
      measured and understood; it moves only on a generic speed lever or
      the transpiler. Not a front — a floor.

## Carried standing items (watch-state and rules, not work)

These are deliberately not checkboxes: none is a task with a completion
condition. They are things to watch for, and one rule that must never be
"done".

- WATCH: `tl_atomic_update_contended` litmus flake — watch state, postmortem
      on the next natural occurrence (the sweep prints got-vs-expected).
- RISK: ktor's widened pack includes are validated by the commontest
      census only; the ktor_server/client e2e itests gate them in CI.
      `KTOR-SERVER-UPSTREAM.md` residue: the serialization shim swap
      (blocked upstream) and the start-path connector-logging flake.
- LATENT: compose's movableContentOf factory-wrap widening and the group
      start/end imbalance op-trace probe (both latent, waiting for a
      failure that names them); non-private member-extension-property
      tower gating (the public half cost ~400 tests — needs receiver-tower
      emulation).
- RULE: the 2 ktor URLBuilder scheme-with-digits failures are CLOSED BY
  RECORD — klio matches Kotlin semantics (upstream's own URLProtocol
  rejects digit schemes on the JVM too) and they must NEVER be "fixed".
  A future round that "improves" the ktor count by touching these has
  made the interpreter wrong.

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
