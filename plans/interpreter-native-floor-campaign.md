# Interpreter native-floor campaign: the 300x compute floor and the last frames

STATUS 2026-08-31: NOT STARTED. Successor to
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

The dispatch census shows 3.6M frame pushes per replica run
(frame_push + frame_push_flattenable = 35% of events; ~6000 activations
per composed frame), and the drivers bucket is ~15% of the replica
profile. The fused walker already serves the fusable subset — the vein
is the REMAINING framed opens: what share is `frame_push_flattenable`
that the flat driver could take but does not, and what does a framed
open actually cost (pool hit, register-file seed, chain wiring,
teardown)? Measure first: a census of who opens frames (caller shape,
body size, why-not-flat / why-not-fused reason codes), then attack the
largest reason code only if it clears the threshold. The A1d
materialize machinery and the flat driver are the substrates; no new
tier (the law). Exit: banked win or the reason-code census recorded as
dust-spread.

## Task 4 — the gate wall beyond vpd (suite-level)

The suite's wall floor is NOT one test: compute-heavy benchmark tests
(SlotTableBuilderTests/SlotTableTests families) run interpreted ~300x
native under 8-way contention (a 22s class costs 320s in the sweep era;
KLIO_MAX_WORKERS=5 was the last fix), plus the coroutine timeout-tail.
Levers, in measure-first order:
- Re-census the per-class child walls in a current gate log: what is
  the wall-clock-critical chain of children (the max, and what runs
  beside it)? A smarter shard order (longest-first) or worker count may
  buy minutes for free.
- The benchmark-shaped tests are Task 1's natural beneficiary — if the
  sub-ABI lands, evaluate AOT-ing the heavy bodies (or accept the tests
  as the recorded compute floor).
- The timeout-tail: which classes still spend wall in
  waiting-for-timeout rather than computing (the wall-cap dump names
  them)?
TRAP: lowering the runTest dispatch cap is HARMFUL (teardown-deadlock
hangs — recorded in the compose-suite-perf memory); per-test wall caps
must never fire before klio's own hang guard. Exit: minutes banked into
the gate wall (and the vpd ratchet where vpd itself moves), or the
floor recorded as compute-bound pending Task 1.

## Task 5 — per-thread critical-path attribution (conditional tooling)

The recorded method gap: KLIO_PROF aggregates threads, so on
multi-thread workloads a profile share is only a ceiling. Build this
ONLY if Tasks 1-4's A/Bs come back flat against their profile-share
predictions: extend prof.zig to bucket samples by thread (the composer
thread vs workers — thread id is already in hand at sample time), so
the critical path is read directly instead of inferred through the
replica proxy. Small, bounded; exit is the tool existing and one
attribution run recorded, or closure because Tasks 1-4 never needed it.

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
