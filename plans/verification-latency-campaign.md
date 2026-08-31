# Verification-latency campaign: the full stack in minutes, not hours

STATUS 2026-08-31: NOT STARTED (queued behind the red-mass closeout).
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

## Task 3 — the coroutines suite's own structure

Whatever Task 1 shows, the known shapes: children re-lower the same
source closure per target; per-directory batching (compile once, run
each) took the stdlib sweep from hours-shaped to minutes and is the
proven template; suite children run with bounded workers but the
scheduling may leave the box idle behind stragglers. Apply batching /
warm shared images / worker tuning until the suite's cost is its TEST
EXECUTION, then attack that (below). Target: the coroutines census
within a few minutes on a warm tree.

## Task 4 — caching across the stack

- Pack bakes: content-addressed and reused across `zig build`
  invocations (the "every zig build = full re-bake" trap dies).
- Baked base images for test children: a census run's children share
  one pinned image instead of re-lowering the world (the transpiler's
  pinned-image machinery is the precedent).
- Suite-level result caching keyed on (tree hash, suite): an unchanged
  suite on an unchanged tree is a no-op — the full stack after a
  plans-only commit should cost seconds.

## Task 5 — the production-runtime share of the floor

The test-execution residue after Tasks 2-4 is interpreter/JIT/AOT
throughput on real workloads — vpd's 562s above all. This half is NOT
"perf is done" territory: the perf era closed per-op micro-veins, not
the macro question of what a 9-minute single test costs the pipeline.
Levers, measured-first per the standing law:
- The kl_ scalar sub-ABI is proven at 34x; census children whose hot
  bodies are kl_-eligible could run through transpiled binaries where
  parity is byte-exact (the corpus check already does exactly this at
  401/401). Evaluate AOT-backed census children for the compute-heavy
  suites.
- Widening kl_ eligibility (more inst kinds/type groups) driven by the
  actual hot bodies of the slowest children — the recorded future vein
  from the native-floor campaign, now with a concrete customer.
- vpd itself: either its recomposition throughput moves (the 645
  ratchet tracks it) or its ROLE moves (a shorter statistically-equal
  variant for iteration with the full test kept for CI) — decided by
  measurement, not by tolerance.

## Discovered items

- [ ] WriterReaderTest.testWriterOnCancelled is a real cancellation-race
      flake (ktor): `GlobalScope.writer(coroutineContext = cancelledJob)`
      then `channel.readByte()` must throw CancellationException; klio
      sometimes doesn't (3-of-4 failing solo, then 0-of-5 — both
      directions observed 2026-08-31). The writer's cancellation close
      races the first channel read. Root-cause in the utils.io
      writer/channel bridge; the ktor ceiling of 1 absorbs exactly this
      until then.
- [ ] Full-parallel stacks oversubscribe (each suite spawns its own
      8-worker pool): one coroutines child DNC'd and two litmus tests
      wall-capped under 64 workers on 32 cores. A shared worker budget
      across concurrently-running suites (or KLIO_ITEST_JOBS tuning in
      scripts/stack.sh) removes the load flakes from the stack path.

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
