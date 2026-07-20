# CI green + interpreter quality — running plan

Treat CI-green as its own work (independent of the compose cutover, which is done).
Goal: a fully green CI, no hangs, converge custom-Kotlin-runtime env flags on
upstream behavior, and improve interpreter speed. Work each issue to resolution;
do not abandon a bug because it took several rounds.

CI has been red for weeks (pre-existing debt) — every run since ~2026-07-09 is
failure/cancelled. Runs on `ubuntu-latest`, Zig 0.16 Debug harness: `unit tests`
+ 5 weight-balanced itest shards (`zig build itest -Ditest-shard=K/5
-Dharness-optimize=Debug`). No `gh`/token here; query CI via the public API
(`curl .../actions/runs?...`), reproduce failing shards locally.

## Failure taxonomy

1. **CPU-contention starvation (infra)** — DOMINANT class. Each commontest suite
   spawns a per-core worker pool; zig build ran several suites in parallel per
   shard → ~3x oversubscription → compute-heavy suites drop below ratchets set
   for un-contended runs (io_commontest 1120 alone → 368 in-shard; e2e jit-off
   SIGKILLed). FIXED (65665357): serialize the shard's run steps in build.zig
   (`prev_itest_run` chain) so one suite runs at a time with full CPU. Shard 4
   fell from ~5min to ~22s. NOTE: the chain skips later suites on a failure, so
   a genuine failure early in a shard masks the rest until it's fixed.

2. **Genuine pre-existing interpreter bugs** (reproduce alone, `KLIO_COMPOSE_PLUGIN=0`
   too — not compose):
   - [IN PROGRESS] `parity_lambdas_and_dispatch.bounded_type_param_ext_requires_bound`:
     `class Outer{fun halve()="outer-member"}; fun <T:Number> T.halve()="number-ext";
     with(Outer()){with("str"){halve()}}` prints `number-ext`, expects `outer-member`
     (String does not satisfy `T:Number`, so the outer member must win). ROOT CAUSE
     traced: the bound IS registered (`typeParamOf(5972,"T")=true`, bounds.len=1 for
     `T:Number`); `strictReceiverProvenName` enters the bound check and recurses to
     `(String,"Number")` where `receiverImplementsHead`→`Value.isRuntimeType(String,
     "Number")` = false (String arm at value.zig:2092 correctly lacks Number). YET
     the ext is selected and `[strictext] recv=String -> ok`. So the selection is NOT
     gated solely by `strictReceiverProvenName` — the ext-fallback (`[extfb]`) /
     lenient applicability pass (applicability.zig `isTopOrGenericType`, host_call_member
     ~line 361 / 1320: a short all-upper head like `T` is treated as an unconstrained
     wildcard that matches anything) accepts String and preempts the outer member.
     FIX DIRECTION: make the `extfb`/lenient applicability path enforce the type-param
     bound too (not just the strict path) — or make both paths consult
     `func_type_param_bounds` for a bounded receiver type param. Verify: itest-parity_lambdas_and_dispatch
     green + stdlib both shards still 1020/1276 (dispatch is highest-blast-radius).
   - [TODO] `parity_inheritance_dispatch.private_shadow_field_distinct_cells` +
     `private_shadow_var_writes_own_cell`.
   - [TODO] `ktor_server` routing: GET returns non-200. Coroutine divergence — with
     `persistResumeGate=false` the served coroutine DEADLOCKS (29min spin then futex),
     with gate=true (current) it returns wrong data. Fix = converge coroutine resume
     on Kotlin, don't pick a gate. See front C.
   - [TODO] enumerate the rest: run the fast dispatch/resolution suites individually
     (parity_*, cfa_*, typeck_negative, resolve_ambiguity, context_parameters,
     explicit_backing_fields, annotation_targets, json_reified_inline,
     runtime_objref_threads). Skip the slow commontest suites for enumeration (they
     pass alone; contention-only). CAUTION: never `pkill -f "zig build"`/"seed=..."
     patterns — they match the enum's own shell and self-kill it; kill by PID only.

3. **Hangs** — root-cause, don't wait out. The ktor gate=false deadlock (front C).
   Compose "did-not-complete" classes under contention (may resolve via serialization).

## Fronts (in order)

- **A — Correctness → green CI.** Fix each genuine bug above to completion, one at a
  time, verified against its suite + stdlib no-regress. Then a final full serialized
  itest run (all shards) to confirm green.
- **B — Hangs.** Root-cause spin/deadlock cases.
- **C — Flag convergence + coroutine correctness.** Keep interpreter-inherent flags
  (JIT/GC/safe-mode/compose lowering); converge custom-Kotlin-runtime flags — start
  with the coroutine gates (`persistResumeGate` / `resumePersistedOnTop`) — by making
  coroutine semantics match Kotlin so the flag disappears. Overlaps A's ktor fix.
- **D — Interpreter performance.** Tree-walker; prior CPU campaign already did loop-JIT
  (60–79x), packed arrays, and found much is compute-bound. Profile with KLIO_PROF,
  land targeted hotspot wins; be honest that native/JVM parity needs a bytecode VM/JIT
  (its own large project). Verification infra is slow largely because it interprets
  whole Kotlin programs (stdlib ~6min, compose ~12min).

## Tooling / devloop (front B foundation)

- **Hang wall-cap (DONE, uncommitted→commit):** the in-process itest harnesses
  (parity/e2e/differential, all funnel through `parity.runMainEntry` → `Vm.run`)
  now arm the eval-loop wall deadline (`interp_ir.armTestWallDeadlineMs`, default
  60s, `KLIO_ITEST_WALL_CAP` seconds override, 0=off). A SPINNING test aborts with
  "test wall-clock deadline exceeded" and names itself instead of hanging the
  binary for 40min. Catches infinite loops in the eval loop; does NOT catch a
  pure DEADLOCK (futex-blocked off the eval loop, e.g. the ktor case) — that
  needs a watchdog thread (TODO front B).
- **DEVLOOP LESSON (root of the "verification is slow" pain):** `zig build itest-X`
  RECOMPILES core modules on every core-file change (minutes, Debug). The RUN
  itself is ~10s. So: build the itest binary ONCE, then run the built binary
  DIRECTLY for iteration — `BIN=$(ls -t .zig-cache/o/*/test | first-with <a test-name
  string>); KLIO_PARITY_BASE_IMAGES=$PWD/zig-out/parity-base timeout 60 $BIN`. Do
  NOT re-run `zig build itest-X` per iteration. (Interpreter runtime itself is also
  slow — front D — but the biggest verification-time sink is repeated rebuilds.)
- **OPERATIONAL: never `pkill -f "zig build"|"seed=0x6b6c696f"|"itest"`** — the
  pattern matches the running command's OWN shell and self-kills it (cost real
  time twice). Kill stale procs by PID only.

## Landed (pushed, origin/main @ 65665357)

- Compose cutover complete; two e2e coroutine bugs; corpus memory bound (not cap raise);
  itest serialization. Details in memory `klio-compose-plugin-triage` and this file.
