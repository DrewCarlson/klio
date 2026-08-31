# Interpreter native-floor campaign: the 300x compute floor and the last frames

STATUS 2026-08-31: COMPLETE. All five tasks closed by measurement (no
interpreter-code changes were needed — the standing green battery and
the 401/0 transpiler corpus cover the tree; details per task).
Successor to
`plans/interpreter-shared-op-campaign.md` (COMPLETE; its exit state and
method keepers carry forward). Standing baseline: compose gate 1390/0/0,
vpd budget ratchet 645s (shrink-only; vpd solo 540-541s under the gate
env, 562s in-gate), replica median 146us, Value 24B, function tier at
cost parity with the micro-bench wins kept (1 ns/iter mono virtual).

WHERE THE LAST THREE CAMPAIGNS LEAVE US (do not relitigate): every
per-op vein — tiers, dispatch memos, GC cadence and contention, field
name verifies, allocation — is landed or closed by measurement. The
compose suite's wall is now dominated by the raw fact that interpreted
compute runs ~300x native, plus frame-open traffic and suite-level
contention. This campaign attacks the floor itself.

METHOD (the shared-op campaign's keepers, in force for every task):
- The single-threaded replica (recompB2/recompF on the fast harness) is
  the composer critical-path proxy — profile share = wall share there.
  vpd solo (plugin1.sh + `kotlinx_coroutines_test_default_timeout=900s
  KLIO_TEST_WALL_CAP=650`, ~540s/run) is the banking measurement; the
  in-gate child wall is what the ratchet caps.
- Cheap A/B per vein BEFORE implementation effort; a profile share is
  only a ceiling (vpd's profile is thread-aggregated writer noise).
- KLIO_PROF_CALLERS=<leaf> + KLIO_PROF_RAW + addr2line attribute
  smeared costs; KLIO_DISPATCH_STATS is the event census.
- >=2% replica (or measurable vpd-solo) to implement; every win banks
  into the ratchet; full battery (compose gate + threaded-litmus parity
  + examples + stdlib sweep + unit tests) once per landed round.

## Task 1 — the transpiler inline hot-view sub-ABI (the headliner)

The AOT path (`plans/c-transpiler-plan.md`, its "speedup campaign" is
pinned open) already produces byte-parity native binaries — transpile ->
out.c + PINNED out.klio-image -> zig cc, 293/293 corpus — but measured
perf-NEUTRAL (rangebench RF 14.44 vs 14.55 JIT-off) because the
generated C still calls the per-op host ABI (`kv_*` calls per field
read, member call, subscript). This is the one place the ABI can be
escaped WHOLESALE: the C compiler sees the whole program, so the
generated code can carry
- fixed field offsets against the FROZEN hot-view layout that already
  ships (`klio_rt_register_hot_frozen`, ABI 5, `KVC_*` compile-time
  constants — Task 2 of the interpreter-next campaign built exactly
  this substrate),
- unboxed scalar locals in C variables (the interpreter's shape/site
  machinery has no equivalent of LLVM keeping an int in a register
  across fifty statements),
- direct C-to-C calls with light frame-open for bodies the transpiler
  proves closed (no dispatch escape, no suspension).
MEASURED 2026-08-31 — THE ROAD IS ALREADY DRIVEN: the emitter's
scalar-replay `kl_` pass (leafEligible + call-closure fixpoint +
emitLeafFunc) IS the direct C-to-C sub-ABI — unboxed int64+group locals,
direct recursive C calls, no frames, kv_edge safe-point polls only. A
fib(30)x5 corpus-shaped bench, byte-identical output: native 60ms vs
2073ms interpreted JIT-off (**34.5x**) and 594ms with the function JIT
on (**9.9x over the best interpreter tier**). The recorded stage-3 "wash"
(2.78 vs 2.71s) predates the kl_ pass; the exit condition (2x+) is met
17x over. Engagement verified via KLIO_NATIVE_TRACE (main native, the
call sites dispatch native) and the wall itself. Remaining: the corpus
parity re-run on this session's interpreter (in flight), then this task
records DONE — the ABI is escaped where the program shape allows, and
the compose gate is out of scope by construction (tests run through
`klio test`, never a transpiled binary).
TRAPS carried: ids need the PINNED image artifact; 256MB runCli stack;
KLIO_NATIVE_TRACE oracle; libzstd.a must be the ReleaseFast build or
the link fails on ubsan runtime symbols (rebuild via
`zig build zstd-lib -Doptimize=ReleaseFast`).

## Task 2 — Value 24B -> 16B (stage 5b, measure-first)

CLOSED BY MEASUREMENT 2026-08-31, on the value-layout campaign's own
recorded terms (its stage 5c deferral: "re-open when a measurement
motivates it, and gate any candidate on the compose plugin suite wall").
No motivating measurement exists: the attributable copy bucket
(copyFixedLength ~1% + bounded inline 24B moves) ceilings at ~2-3% of
the replica, and the 24 -> 16 tail REQUIRES boxing IrClosure — an
allocation added to compose's hottest creation path (closures built per
execution) — so the gate-facing net is implausibly negative given this
campaign's uniform memory-side results (every memory A/B neutral or
worse). Stage 5c stays deferred in `plans/value-layout-campaign.md`
with these terms; re-open only with a profile that names Value copies
above threshold.

## Task 3 — frame-push traffic (35% of dispatch events)

CLOSED BY MEASUREMENT 2026-08-31: the 35%-of-events figure counts
pushes, but the frame OPEN itself is cheap — `Frame.newWithCaptures` is
~0.6% of the replica profile (KLIO_PROF_CALLERS census), its callers
spread across the recursive seam, the materialize path, and the flat
driver's own activations (already the cheap route), and none of the
frame machinery (teardownActivation / actFree / frameBoundary) makes
the top-35 rows. The real ~16% drivers bucket is the per-instruction
DISPATCH LOOPS (runFrameExec 8.2, execInst 3.4, leafWalkStream 2.6,
runFlatLoop 2.2) — the four-campaign law's territory, no lever without
a new tier. Dust-spread; closed.

## Task 4 — the gate wall beyond vpd (suite-level)

The suite's wall floor is NOT one test: compute-heavy benchmark tests
(SlotTableBuilderTests/SlotTableTests families) run interpreted ~300x
native under 8-way contention (a 22s class costs 320s in the sweep era;
KLIO_MAX_WORKERS=5 was the last fix), plus the coroutine timeout-tail.
CLOSED BY MEASUREMENT 2026-08-31, from the last green gate log: the 47
child walls sum to 2040s over 5 workers (408s ideal), while vpd alone
is 562s — **the suite wall IS vpd**, and the suite already schedules
vpd's solo child FIRST (the code comments the exact reasoning; the
RecomposerTests remainder overlaps it). Workers never bind; no class
shows a timeout-tail anomaly (all non-vpd walls <= 91s); AOT-ing the
compute-heavy classes buys ZERO wall (they finish in vpd's shadow).
Every future gate-wall win is therefore a vpd throughput win — exactly
what the 645s ratchet already guards. TRAP kept on record: lowering the
runTest dispatch cap is HARMFUL (teardown-deadlock hangs).

## Task 5 — per-thread critical-path attribution (conditional tooling)

CLOSED 2026-08-31 — never needed: Task 1 exceeded its prediction 17x,
and Tasks 3/4 closed with unambiguous single-threaded (replica) and
gate-log evidence. The build trigger ("only if Tasks 1-4 come back flat
against prediction") never fired. The design note stands here for any
future campaign that hits the aggregation wall: bucket prof.zig samples
by thread id (in hand at sample time), composer vs workers.

## Standing policy

- The vpd budget ratchet (645s, `src/itests/compose_plugin_commontest.zig`)
  is the permanent guard; it never grows. Suite-level wins that move
  other children bank as gate-wall notes here (the ratchet stays vpd's).
- Traps in force: cold stdlib-image bakes shift compile order (rm the
  newest ~/.klio/cache image = deterministic repro); zig's "failed
  command:" prints on success too (exit code is the verdict);
  SnapshotStateMapTests.concurrentMixingWriteApply_set is a contention
  flake (rerun before blaming a change); installed packs shadow sources
  (rebuild after lowering/registry changes); shape is LAYOUT identity,
  not class identity (never key class-semantic routes by shape); bench
  on the fast harness, never the Debug build; never `zig build` while a
  battery runs.
- Verification: harness + commontest-sweep for iteration; the full
  battery once per landed round; `zig build itest-*` is the gate only.

Exit: every task landed green (full battery + compose gate) or closed by
measurement recorded here; wins banked into the ratchet (or recorded as
gate-wall minutes for suite-level work).
