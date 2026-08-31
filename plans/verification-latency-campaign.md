# Verification-latency campaign: the full stack in minutes, not hours

STATUS 2026-08-31: IN PROGRESS — Tasks 1-2 DONE, Task 3 datetime+
coroutines drilled to measured floors, gate-shielded stack landed
(measuring).
MANDATE (user, 2026-08-31, verbatim intent): a full verification cycle
taking ~2 hours is unacceptable; the next major focus after the current
correctness work is shaving it to a few minutes — addressed "completely
and correctly as it relates to all of our tests and verification
infrastructure as well as the actual production runtime of the
interpreter, jit code, and transpiled C."

THE BUDGET (Task 1 CORRECTED 2026-08-31 — the instrumented rows
overturned the opening estimate):
- The "~2 hour" experience decomposed as: sequential per-suite
  invocations + serialized relinks after tree changes + THE SESSION
  TOOLING'S OWN TASK-QUEUE DEFERRAL (background tasks sat queued for up
  to an hour before starting — an agent-harness artifact, not project
  cost). The project's true numbers:
- Coroutines census, instrumented (KLIO_CENSUS_TIMES): **107s total**
  — 148 children, sum 650s over 8 workers; hottest children
  SharedFlowTest 37s, BufferedChannelTest 34s, ImmediateYield 19s.
  The 157-file closure compiles in ~7s per child.
- Datetime: wall == its hottest single child (TimeZoneRulesTest 171s,
  compute); 56 children x 60 files, sum 614s. A one-child whole-suite
  run reproduces the census exactly (519/0) in 236s serial — per-file
  isolation costs ~56x redundant lowering but parallelism hides it.
- **ONE-INVOCATION FULL STACK** (`zig build itest-a itest-b ...`, all
  ten steps, links + runs parallel on 32 cores): **710s = 11.8 min**
  WITH all ten binaries relinking (tree-changed worst case). The
  sequential-scripts habit, not the project, made it hours.
- Remaining structure inside the 710s: the compose gate (~10 min,
  vpd 562s floor) IS the critical path; everything else overlaps it.
- Library census workers clamp at 8 of 32 cores
  (commontest_support.workerCount); full-parallel stacks oversubscribe
  (64 workers dropped one coroutines child to DNC — floors carry load
  margin, coroutines 1285 vs solo 1299).
- MEASUREMENT TRAP (cost this table its first draft): `rc=$?` must be
  captured BEFORE any further command (a date call overwrote it), and
  log-mtime timelines lie when the task queue defers the start.
- Datetime CORRECTED: the wall child is LocalDateTest 168s (the first
  census-time table mis-attributed targets under whole_source_set —
  fixed), inside it fromEpochDays 100s + toEpochDays 56s. Both are
  dispatch-heavy compute: direct A/B (same body, run mode AND test
  mode, klio-harness) shows the loop JIT NEUTRAL on the
  assertEquals-dominated shape (7.7s vs 8.2s over 200k iters) while a
  ctor+equals shape does JIT 1.78x — the four-campaign law, not a
  test-mode suppression bug. Per-test SPLITTING is the lever that
  works: `split_files` in the suite registry emits one child per @Test
  for named files; datetime census 168s -> 128s, same 519/0. Floor is
  now fromEpochDays' own 100s of interpreted content.
- Coroutine dispatch macro-costs (klio-harness-fast, 2026-08-31):
  yield 92us, launch+join 389us, fan-out dispatch 203us. KLIO_PROF on
  the bench is FLAT (libc 7%, fetchAdd 5.7%, eqlBytes 4.5%, rest dust)
  — diffuse interpreter work, no dominating macro cost to extract. vpd
  throughput is measured-exhausted per-op AND per-macro-op.
- Compose-gate lead-in: the five pack builds cost 2.2s TOTAL warm
  (atomicfu 12ms .. engine 1.1s) — pack baking is NOT a sink on the
  gate path; the warm-stack floor is vpd under census contention
  (626-646s vs 540-562s solo).

## Task 1 — measure where every minute goes (no guessing)

Instrument one full stack run with per-phase wall times split into:
binary link / pack bake / per-child Kotlin lowering / test execution /
scheduler idle, per suite. The coroutines suite gets a per-child
breakdown (which children, how long, compile vs run). Deliverable: a
budget table in this plan naming the top five sinks with minutes
attached. Everything below executes in measured-sink order, biggest
first.

## Task 2 — kill the per-suite binary links for iteration

The ten itest binaries exist for CI isolation; iteration should never
pay ten LLVM links. Build ONE census driver on the installed
`klio-harness` (the commontest_support logic — file collection,
provider closures, per-class children, ceilings — extracted into a
runnable form: a `klio census <suite>` subcommand or a script driving
the harness the way `plugin1.sh` already does for compose classes).
Target: tree-change -> any single suite census = harness rebuild
(~1 min) + run; zero itest links outside CI. The itest gates remain the
CI/pre-commit instrument, unchanged.

## Task 3 — suite structure (DONE for the measured walls)

Coroutines census 107s (already under target). Datetime drilled: the
wall was one child with two 100s+56s compute tests; `split_files`
(per-@Test children over the same closure) landed it at 128s / 519-0.
JIT-neutrality of the hot bodies established by direct A/B in both
modes (budget notes above), so the residue is interpreted content, not
machinery. Remaining structural lever if 128s must shrink: shared
pinned base images per suite (Task 4) to cut each child's closure
lowering.

The full-stack critical path is the compose gate: stack.sh now runs
the gate at normal priority and everything else under `nice -n 15` in
a concurrent second `zig build`, so vpd's threads win the scheduler
while the census suites stretch into vpd's tail slack.

## Task 4 — caching across the stack

- Pack bakes: content-addressed and reused across `zig build`
  invocations (the "every zig build = full re-bake" trap dies).
- Baked base images for test children: a census run's children share
  one pinned image instead of re-lowering the world (the transpiler's
  pinned-image machinery is the precedent).
- Suite-level result caching keyed on (tree hash, suite): an unchanged
  suite on an unchanged tree is a no-op — the full stack after a
  plans-only commit should cost seconds.

## Task 5 — the production-runtime share of the floor (CLOSED by
measurement 2026-08-31)

Every wall-dominating test body was inspected against the kl_ scalar
sub-ABI's eligibility: datetime's fromEpochDays/toEpochDays (LocalDate
construction + equals dispatch per iteration), coroutines'
SharedFlowTest/BufferedChannelTest (coroutine machinery), compose's
SlotTable*/CompositionTests and vpd (recomposition + snapshot objects)
— all object/dispatch-bound, none expressible in the scalar sub-ABI,
so AOT-backed census children cannot move the measured floors today.
Widening kl_ eligibility to object graphs is the C-transpiler speedup
campaign already pinned open in plans/c-transpiler-plan.md — a perf
campaign, not verification machinery. The JIT was re-checked directly
on the hot datetime shape in BOTH run and test mode: neutral (budget
notes). vpd's throughput is measured-exhausted across five campaigns
(tiers neutral, per-op and macro-op profiles flat); its ROLE stays the
full test — gates never weaken — so vpd's ~540-560s solo wall is the
recorded full-stack floor term.

## Discovered items

- [x] WriterReaderTest.testWriterOnCancelled root-caused and FIXED
      (2026-08-31): an UPSTREAM ktor ByteChannel race — `awaitContent`
      rethrows the close cause at entry, but a `cancel(cause)` landing
      between that check and `sleepWhile`'s condition makes the sleep
      no-op and awaitContent return false with the cause swallowed, so
      `readByte` throws EOFException instead of CancellationException.
      Nanoseconds wide on the JVM, wide interpreted (3-of-8 solo).
      Chased via a cloned writer builder with path markers: the
      completion handler ran with the right cause and DID cancel the
      channel, closedCause read back correct — only the reader's window
      lost it. Fix: curated shim copy of ByteChannel.kt (upstream file
      dropped from the klio.toml include list) adding one line — rethrow
      when awaitContent returns short. 12-of-12 solo + 50-iteration
      repro clean; ktor ratchet tightened 449/1 -> 450/0 (census 62s
      link-free).
- [x] Oversubscription CLOSED by the priority-shield model instead of a
      shared worker budget: stack.sh bounds census workers
      (KLIO_ITEST_JOBS=4) and runs the census half under `nice -n 15`
      while the compose gate keeps normal priority; inside the gate,
      every sibling of vpd spawns under `nice -n 10`. Suites with slack
      stretch into vpd's tail; the wall-owning threads keep the
      scheduler. Verified green across three consecutive full stacks
      (coroutines 1299/0/0, no DNCs, no litmus wall-caps).

## Standing policy

- Budgets are wall-clock minutes; every landed task updates the budget
  table with before/after. The campaign target: full stack <= 10 min
  warm, single-suite iteration <= 2 min.
- Correctness gates never weaken: same tests, same ceilings, same
  baselines — only the machinery that runs them gets faster. Any
  caching layer must be content-keyed and fail OPEN (cache miss = run).
- Traps in force: installed packs shadow sources; cold stdlib-image
  bakes shift JIT compile order; the itest binaries stay authoritative
  for CI; never `zig build` while a battery runs.

Exit: the budget table shows the targets met, every task landed green
(full battery + compose gate) or closed by measurement recorded here.
