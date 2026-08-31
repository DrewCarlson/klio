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
Do it measure-first: transpile the replica and one compute-heavy gate
body (a SlotTable benchmark test program), count the kv_ call sites the
hot view could absorb (a static census, no codegen), and only then
implement absorption in call-count order. TRAPS carried from the
C-transpiler campaign: ids need the PINNED image artifact (bakes are
not cross-process id-stable); the initial thread needs the 256MB runCli
stack (GNU_STACK size is ignored); KLIO_NATIVE_TRACE is the engagement
oracle. Exit: a measured speedup on a transpiled compute body (target:
2x+ on a benchmark-shaped corpus program — anything less means the ABI
was not actually escaped), or closure by a census showing the absorbable
call share is too small.

## Task 2 — Value 24B -> 16B (stage 5b, measure-first)

The value-layout campaign closed at 56B -> 40B -> 24B with stage 5b
(16B: tag-in-pointer or split-bank encoding) recorded measure-first.
Value size taxes EVERYTHING: frame register files, capture vectors,
field storage, argument copies (`copyFixedLength` in every profile).
First measure the ceiling: instrument (or estimate from the existing
profiles) the share of replica time in Value moves/copies at 24B, and
prototype the 16B encoding's decode cost on the hottest read path
before committing to the representation change. This is a land-big
change if it goes: every Value producer/consumer sees the layout. Exit:
banked wall win, or the ceiling measurement recorded as too small.

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
