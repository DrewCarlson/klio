# Simplify / Validate / Accelerate

The running plan for the next stretch of work. Three tracks — codebase
simplification, test/validation repair, and whole-project performance
(interpreter execution + memory management) — plus the carried-over open
items from the previous round. Worked in the order given at the bottom;
each landing runs the full battery (harness sweep, litmus, compose plugin
ratchet, corpus, module unit tests) and commits directly to main.

Ground rules carried forward:
- Measured-first for every perf lever: baseline on the rig, land, re-measure,
  record the number (including measured-negative results).
- Measure on `zig-out/bin/klio-harness` (ReleaseSafe). The plain `zig build`
  binary is Debug and its profile is fiction (hash/eql dominate there).
- Simplification changes are behavior-frozen: the battery must hold
  byte-identical corpus output and unchanged suite counts. A refactor that
  moves a number is a bug in the refactor.
- Big-changes-over-green still applies to the structural perf work: a
  multi-commit red middle is fine when the plan is valid.

## Carried-over open items (inherited state)

- The concurrency perf campaign is mid-flight: round 3 landed
  (member-resolve file-keyed caching ~11%, leaf no-fill, profiler
  leaf-caller recovery). Standing solo on the ReleaseSafe harness:
  addAll_clear 30.6s/30s, concurrentGlobalModifications_addAll 32.0s/30s
  (both marginal), addAll_removeRange 69.7s/30s,
  concurrentGlobalModification_add 10.2s/10s. Ranked next candidates and
  the measurement rig are recorded in plans/worklist.md (E4 entry). This
  plan's Accelerate track is that campaign's continuation.
- Measured-first recorded roads (open only when a measurement motivates):
  Value 24 -> 16 (value-layout-campaign.md), C-transpiler C-to-C frames +
  inline hot-view sub-ABI (c-transpiler-plan.md), nullable member-ext
  gating / tower strength (worklist C2).
- tl_atomic_update_contended litmus flake: watch-state; the sweep prints
  got-vs-expected tails, postmortem on next natural occurrence.
- ktor widened pack includes are validated by the commontest census only;
  the ktor e2e itests gate them in CI (risk note in open-campaigns.md §4).
- plans/open-campaigns.md §3 still lists combine/zip as LIVE — both were
  fixed since (extension-arity trailing-lambda rule + receiver-tower head
  binding; guards examples/flow_zip.kt, examples/flow_combine.kt).
  Reconciling that register is Simplify item S3.

## Track S — Simplify

- [ ] S1. Delete the dead compose-plugin gate. `composePluginEnabled()`
      hard-returns `true` (the cutover flipped); ~8 files still branch on
      it (host_call_func, host_call_member, host_call_value,
      host_instances, interp_ir/build, compose_pass, stdlib_image hash,
      itest env). Inline the true arms, delete the dead alternatives, drop
      the KLIO_COMPOSE_PLUGIN env plumbing (itest env-set, pack-cache
      image-hash tag, docs). This is the recorded final step of the
      cutover ("flip default + DELETE implicit impl"); grep for any other
      implicit-composer-era remnants while there. Battery must be
      count-identical.
- [ ] S2. Split the three giant modules, behavior-frozen:
      - src/ir/lower/expr.zig (23.8k lines) — per-concern submodules
        (bare-call resolution arms, lambda lowering, receiver/tower
        machinery, call emission, static type derivation).
      - src/interp_ir/vm/host_call_member.zig (16.0k) — dispatch tails by
        route (member walk, extension fallback, stdlib ladder, caches,
        overload scoring already partly in overload_match.zig).
      - src/ir/eval.zig (12.8k) — exec arms by instruction family, frame
        machinery, leaf serve, liveness.
      One module per landing, imports rewired via build.zig, zigcheck +
      battery after each. No logic edits ride along with a move.
- [ ] S3. Plan-register hygiene: 44 docs under plans/. Reconcile
      open-campaigns.md against current reality (zip/combine fixed, ktor
      census 465/2/0, coroutine cluster closed), move finished campaign
      logs into PLAN-archive.md, and make open-campaigns.md the single
      live register that every other doc points into. worklist.md's closed
      round folds in too.
- [ ] S4. Trace-knob audit: ~240 env probes across the three big modules
      alone. Inventory every KLIO_* knob (grep), delete the dead ones
      (knobs whose print sites were removed), converge the remaining reads
      on runtime.envOnce, and complete the docs/development/debugging.md
      table so it IS the inventory. No knob exists undocumented.
- [ ] S5. Itest inventory: 69 suites under src/itests. Identify
      superseded/overlapping ones (anything targeting deleted paths, e.g.
      implicit-composer-era coverage) and fold or delete. CI time is a
      budget; every suite should earn its wall.
      AUDIT DONE (all 69 read; verdict per suite recorded): nothing is
      superseded — the implicit-composer suite was already deleted at
      cutover (3 stale comment references remain in
      compose_plugin_commontest.zig). All census suites, child-spawn
      gates, corpus/differential/isolation/fuzz heavies, the Kotlin 2.4
      acceptance matrices, and the gate.sh litmus set are CORE. The
      realizable win is compile-side: retire parity_coroutine_smoke
      (its 9-fixture runner moves into parity_coroutines_realistic; the
      fixture dir stays — differential reads it) and collapse ~14
      weight-1 micro-suite binaries into their canonical homes after
      moving ~13 named unique pins (collections trio; strings pair;
      ranges_arrays→array_bulk_ops; closures_advanced→closures_deep;
      functional_patterns+advanced_idioms folds; the two visibility
      suites merge with interface tests moving to inheritance_dispatch;
      atomicfu_arrays'/kotlinx_io_read's resolution pins move into
      resolve_ambiguity; conformance+threaded_litmus co-binary). Net
      69 → ~57 binaries, ~12 fewer whole-program links per cold shard.

## Track V — Validate

- [x] V1. Fresh red-set census RUN (test-all, full log in session
      scratchpad census_testall.log; red set distilled to redset.txt).
      Result: 2452/2527 tests — 15 fail + 44 crash across 23 failed
      steps, and the recorded assumptions were stale in BOTH directions:
      - TWO itests did not even compile (e2e.zig missing runtime import
        on a trace line; stdlib_image bool-result ignored) — nobody had
        run test-all in a long while. Both fixed.
      - check_examples: the resolver's REDECLARATION check keyed
        signatures without vararg-ness, so `select(vararg values: Int)`
        vs `select(value: Int)` — legal overloads — flagged as
        duplicates. Fixed (vararg marker in the sig key); suite green.
      - THE BIG ONE: a deterministic SEGFAULT family across the parity
        itest drivers — 44 crashes (parity_inner_classes 12/24,
        parity_corpus_pinned ~19, data_class_features 3, generics,
        inheritance, fuzz, differential...). All crash in
        `declaringClassSimpleName` iterating `module.classes.items`
        with a garbage Class entry, from a bare call inside an anon
        method (`frame.module` = the anon registry's module ref).
        PRE-EXISTS this work (bisect worktree at the previous session
        start crashes identically 12/24). The same programs pass via
        `klio run` — the crash is specific to the parity in-process
        driver + base-image path. ONE root, ~40 reds.
      - Suites ABOVE their baselines (raise in V2): coroutines 350 vs
        220, io 1157 vs 1050, serialization 9 vs 6, datetime 212 vs 70,
        atomicfu 63 (4 fails under census load), ktor 448/2 under load
        (465/2 recorded solo), compose plugin 1373 vs 1365.
      - Singles to triage: ktor_server start(wait=false) daemon-abandon
        test, resolve_ambiguity default-param twins (2),
        parity_threaded_litmus suite-completeness + eager parity,
        parity_lambdas_and_dispatch member_prop_invoke shadow,
        atomicfu locks_run_uncontended, explicit_backing_fields 1,
        one load-flaky unit binary (75/75 solo).
      Remaining census follow-through: gate.sh after the parity crash
      fix (its litmus phase includes the crashing suites).
      CENSUS REPAIR LANDED (running record):
      - The 44-crash family: FOUR roots, all fixed — the shared anon
        side-module now rebuilds on run-module identity change; every
        pointer-keyed dispatch cache carries a generation stamp bumped
        per in-process program; the bytecode stream cache resets (and
        FREES) per program; the intrinsic intern owns its key bytes.
        12 of 17 affected suites fully green.
      - parity_corpus_pinned 236 -> 249/251: the scope-conflation
        bound-refutation fix, explicit-type-arg instantiation +
        concrete-gated emission enrichment, receiver-instantiated
        extension returns, least-upper-bound element joins, and the
        vararg-before-defaulted trio. The last 2 are CLOSED — both were
        real bugs, not driver context:
        - operator_member_return: the stdlib gate and pack mask counted
          IMPORT prefixes only, so a bare-FQN reference
          (`kotlin.time.Duration` with no import — legal Kotlin) was
          served a gate0 base without kotlin.time. The driver now also
          scans source for `kotlin`/`kotlinx`-rooted dotted tokens
          (collectQualifiedPrefixes; comment/string matches over-open
          the gate, costing base-build time only).
        - file_private_types: two stacked interpreter bugs. A
          default-package typealias registers under its BARE name, which
          scopedTypeAliasFqn's dotted own-package probe could never find;
          and the bare CONSTRUCTOR path (`Node("a")`) never consulted the
          alias registry at all — it now retries the classifier lookup
          through resolveTypeAliasAt at the reference site. Guard:
          examples/typealias_ctor_default_package.kt. Suite 251/251.
      - stdlib_image 7/7: compile break fixed; the round-trip fixture
        now speaks dep-only (its printlns tripped the Aug-03
        provably-unresolved rejection, correctly).
      - atomicfu 4 fails: census-load flakes (solo green).
      - differential 0/2: PRE-EXISTS the session (verified at the
        prior baseline commit); current failure mode is the 6.5GB RSS
        cap across corpus x load modes in one process — an A5 memory
        acceptance target, not a quick fix.
      - e2e (post-gate follow-through; all three roots pre-existing —
        the suite had not compiled since before the session start):
        - GP faults across the corpus: the parity driver flipped
          `alloc_perm = false` BEFORE `Vm.fromBuilt`, minting
          VM-structural cells (closure spine, output sink) as NURSERY
          while `gcMarkAllVms` deliberately does not shade them — the
          first mid-run major swept them and later borrows read freed
          memory (`reclaimDead` GP, `Output.writeln` GP). Fixed by
          restoring the perm invariant: `vmRun` closes the permanent
          generation itself, same as the CLI.
        - positional_lambda_binding mismatch: the scorer's
          trailing-lambda arm REJECTED the whole candidate when the
          out-of-sequence reading could not bind (non-defaulted gap),
          instead of falling through to the plain positional fill.
          The CLI masked it via the eager typeck map; the base-backed
          driver has no eager map and fell to the value route, whose
          binder gapped `trailing` with Null. Scorer arm now falls
          through (unit test added; examples/positional_lambda_binding
          is the e2e guard). Known residual mis-ordering recorded: with
          a fully-defaulted gap the arm still prefers the trailing
          reading over positional for parenthesized args.
        - Residual RSS creep: full corpus in one process peaks ~35MB
          over the 6.5GB cap — the A5 target; per-program VM-structural
          cells now leak by design (perm) until an explicit boundary
          release exists.
      - Singles, all closed:
        - threaded_litmus 45/45: manifest additions committed; the eager
          parity fail was the plus static commit lost to the advisory
          rule — fixed by resolving a bare type-parameter return at its
          DECLARING scope's upper bound (fn-level `<T : B>` first, then
          the declaring class's `<T : B>`; fn-level unbounded stays
          unknown), in the forward-reference AST arm and the
          memberCallReturnTypeRef member-ext arm. Guard:
          examples/class_bound_generic_return.kt.
        - resolve_ambiguity: the default-param-twins test pinned the OLD
          leniency (kotlinc rejects the pair; klio's conflicting-overloads
          diagnostic now covers default-param shapes) — test updated to
          expect the diagnostic in both declaration orders. The
          same-arity ABRT was the FIFTH stale-state root of the census
          contamination family: the GC remembered set held pointers into
          arena-owned permanent cells (base-image ClassDefs) after their
          arena died — base-cache EVICTION frees a base's whole arena
          mid-process, and diagnostic-only programs release their compile
          arena without ever reaching the run-boundary collect. The next
          collection's drain then cleared flags through unmapped pages
          (silent corruption when the page was still mapped; SEGV once
          reclaimed). Fix: `gc.drainRemembered()` — drain while cells are
          still mapped — called at base eviction, base-build error paths,
          the program teardown before `vm.deinit`, and the driver's
          gc-restore defer (covers diag failures); the collector now also
          holds `remembered_lock` across its own re-trace and drain.
          Suite 26/26 across three consecutive listen-mode runs.
        - lambdas_and_dispatch member_prop_invoke: REAL miss — an
          implicit receiver's function-typed property (invoke convention)
          must outrank a top-level fn. Bare-call commit now re-routes a
          plain top-level pick to CallMemberOrGlobal when a receiver in
          the tower declares a same-named `FunctionN`/`<function>`-headed
          property. Guard: examples/prop_invoke_shadows_top_level.kt.
        - ktor_server start(wait=false): passes manually (rc=0, exact
          output) — census-load flake on the Debug CLI under the 30s cap;
          re-verified solo below.
- [ ] V2. Make the ratchets ratchet:
      - src/itests/ktor_commontest.zig has `.baseline = 0` — it can never
        fail. Set it to the census floor (last recorded 465 passed / 2
        failed / 0 incomplete; margin for CI variance).
      - compose_plugin_commontest BASELINE 1365 vs observed 1371-1374 this
        week — raise to the observed floor.
      - Audit the other suites for zero/soft baselines while there.
- [x] V3. The 2 remaining ktor_commontest fails: CLOSED BY RECORD —
      both are URLBuilderTest scheme-with-digits, where klio MATCHES
      real Kotlin semantics (upstream URLProtocol's own require
      rejects digit schemes on the JVM; how upstream CI passes them is
      unclear) and the recorded verdict is do-not-diverge. The raised
      440 baseline absorbs them; open-campaigns.md §4 carries the full
      anatomy.
- [ ] V4. The 4 concurrency stress tests + validatePotentialDeadlock +
      the 2 PausableCompositionTests background tests: all compute-bound
      (measured, not mechanism bugs). They are the ACCEPTANCE METRIC for
      Accelerate work, not independent fixes — each Accelerate round
      re-runs them solo against their declared budgets and records the
      new standing.
- [ ] V5. Leniency follow-through: the unimported-extension warning landed
      (once-per-declaration, exact import named). Consider the next
      escalation once import tracking is trusted: a `klio check` /
      diagnostic-mode error for the same evidence, keeping `klio run`
      lenient-but-loud. Blocked on confidence in wildcard/alias/default
      import coverage; not before.

## Track A — Accelerate

Interpreter execution (the campaign continuation; rig:
scratchpad reprosrc/aacbench.kt on the harness, plus the ratchet wall and
the V4 tests as acceptance):

- [ ] A1. Cross-thread borrow/refcount cost (~4% solo, amplified under
      the suite's 8-way contention; the ~6% futex bucket is the same
      locks contended). Candidates in order of risk:
      - NoopRwLock adoption for provably-immutable cell types (the opt-in
        `objref_immutable` machinery exists; audit ClassDef and other
        registry-frozen types for post-load immutability, freeze-point
        them if needed).
      - Read-mostly seqlock or RCU-style snapshot for class metadata reads
        (the class.borrow() on every instance op).
      - Per-cell thread-bias is recorded as the expensive last resort
        (revocation needs safepoint coordination).
- [ ] A2. Core-loop round: extend instruction fusion coverage (the
      jump/br/cmp_br streams exist; measure getfield+call and
      const+binop pair frequency first), and framed-register fill masking
      (the leaf-serve def-before-use/no-fill landed; the framed path still
      pays appendNTimes ~1% — needs a per-frame written mask that gcMark
      and suspension snapshots respect, so it is a real change, not a
      tweak).
- [ ] A3. Name-keyed map pressure: getIndex ~2.8% + eqlBytes ~3.5% spread
      across registry/dispatch maps. The structural direction is
      intern-once: resolve names to integer ids at lowering/link time so
      runtime probes are integer-keyed (the member-resolve name_p identity
      cache is the pattern; extend it toward funcsBySimpleName,
      field lookup, and the import-scope maps). Measure per-map first via
      KLIO_PROF_CALLERS=getIndex before converting anything.
- [ ] A4. Re-measure under CONTENTION, not just solo: the stress tests
      fail in-suite worse than solo. Add an 8-way contention variant of
      the rig (run 8 aacbench processes pinned) so lever measurements see
      the cache-line and futex effects the suite sees.

Memory management:

- [ ] A5. Slab footprint and churn: one 4-rep bench maps 703MB
      (KLIO_SLAB_STAT) and newSlab threading costs ~2.6% of wall; a
      GC_GROWTH sweep moved memory (up to 1.25GB) but not wall. Questions
      to answer with KLIO_GC_HIST + KLIO_SLAB_TRACE/KLIO_CELL_TRACE:
      what class sizes dominate, why do slabs keep mapping instead of
      reusing (spare/dormant policy), what is actually live at peak per
      rep (~175MB — retention vs trigger lag). Then pick the lever:
      trigger pacing, dormant-page revival policy, or per-class spare
      tuning. Suite RSS is the acceptance number (KLIO_RSS_CAP_KB=6.5GB
      exists in the ratchet — how close does it run?).
- [ ] A6. Wall-clock outliers as memory/dispatch probes:
      compose_foundation_lazy at 3m42 warm and the 55s background-yield
      round-trip (a yield on Dispatchers.Default costs a cross-thread
      dispatch cycle — profile the hop: gate wake, child-Vm materialize,
      repost). Each gets one profiling pass and either a lever or a
      recorded floor.
- [ ] A7. Ship-mode numbers: record ReleaseFast (the ~3% ReleaseSafe
      undefined-poison memset and safety checks vanish there) alongside
      harness numbers when reporting user-facing performance;
      ReleaseSafe stays the itest/battery build on purpose.

Recorded measured-first roads (open only on a motivating measurement, per
their own plans): Value 24 -> 16; C-transpiler C-to-C frames + inline
hot-view sub-ABI; nullable member-ext gating / tower strength.

## Order of work

1. V1 fresh census (test-all + gate) — anchor everything on the true
   current red set.
2. S1 dead plugin-gate deletion — small, immediate clarity win, and it
   de-noises every file the later splits touch.
3. V2 baseline honesty (ktor floor, plugin floor) — cheap, makes every
   later regression visible.
4. V3 the 2 ktor fails.
5. A1 + A4 (contention rig, then the borrow/lock round) — the highest-value
   perf front; V4 tests re-measured after.
6. S2 module splits, interleaved between perf rounds (they touch the same
   files; split AFTER a round lands, never mid-round).
7. A5 memory round (slab/GC), then A6 outliers.
8. A2/A3 as the following interpreter rounds.
9. S3/S4/S5 hygiene passes fill the gaps between rounds.
