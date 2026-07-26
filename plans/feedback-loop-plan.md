# Development feedback-loop plan

Companion to `verification-speed-plan.md`, which covers the **test-suite** loop (harness
builds, commontest sweep). This document covers the **development** loop that the
resolution-unification and Compose work actually runs on:

    edit source -> build klio -> (rebuild packs) -> bake image -> run one program

The test-suite loop is already fast. This loop is not, and it is the one that gates every
iteration of `resolution-unification-plan.md` (RC-A..RC-I).

## Measurements (2026-07-25, M-series macOS, zig 0.16.0)

| Operation | Cost | Notes |
| --- | --- | --- |
| `zig build` no-op | **0.6 s** | healthy |
| cold material3 bake + run | **302 s** | 99% single-core |
| ... of which `lower` | **284.5 s** | parse 2.9 s, serialize 2.3 s |
| warm run, same program | **13.5 s** | |
| `scripts/install-local-packs.sh` (23 packs) | **~6 min** | full rebuild+install |

Reference point: `verification-speed-plan.md` records the material3-set fresh bake at
**~12 s** after the 2026-07-11 fix that removed the `O(refs x decls)` linear scans, and
concludes "at ~12 s that is part of the loop, not a hazard". It is now **302 s**.

## Root causes, in impact order

### 1. Lowering has regressed ~25x on the material3 set — FIXED (2026-07-25)

Profiled with macOS `sample` (note: the built-in `KLIO_PROF` sampler is
Linux-only — `prof.zig` returns early on other OSes, so `KLIO_PROF_ALL=1` on a
Mac collects nothing; attach `sample <pid>` externally instead). ~70% of all
lowering samples landed in two per-reference linear scans over every class in
the module universe, each recomputing `simpleName(fqn)` per class per call:

- `Module.uniqueClassIdBySimpleName` — the simple-classifier-head resolver
- `Module.staticBuiltinIdentity` — the "is this head shadowed outside kotlin.*"
  check

Both now answer from one lazy simple-name cache (`unique_simple_cache`,
growth-counter top-up like the FQN cache; reset on a stub-claim FQN rewrite).
Result: `lower` 290.7 s -> **25.8 s**, cold material3 bake ~31 s — back to the
target order of magnitude. The commontest sweep failure list is byte-identical
before/after. Seven more `for (self.classes.items)` scans remain in `ir.zig`;
none profiled hot on this corpus.

`lower` is 284.5 s of the 302 s bake — 94%. Parse and serialize are unchanged and
negligible, so this is not I/O, pack size, or the image format; it is the lowering pass
itself, single-threaded.

The 2026-07-11 win came from removing four `O(refs x decls)` linear scans. The
resolution-unification work since then has added candidate enumeration and applicability
scoring to paths that previously took a cheap name-keyed shortcut — which is the intended
direction, but it re-introduces a per-reference cost proportional to the candidate set. On
a corpus the size of material3 that is the whole bake.

This is simultaneously a **dev-loop blocker** and a **user-visible startup cost**, and it
sits inside the very engine the plan is centralizing. It is the first thing to fix.

Approach: profile it before changing anything — `KLIO_PROF_ALL=1` (starts the sampler at
process entry; the run-command hook only wraps the VM and a bake profiled without it
collects almost nothing) plus `KLIO_PROF_CALLERS=<substr>` for caller attribution, and
`KLIO_TRACE_STDLIB_IMAGE=1` for the parse/lower/serialize split. Expect the answer to be a
per-call-site scan that should be an index lookup, or a candidate set rebuilt per
reference instead of once per name.

### 2. One interpreter rebuild invalidates every image

The image key includes the exe stamp (size + mtime), so any `zig build` re-bakes. That was
a deliberate, correct trade at 12 s. At 302 s it dominates.

It also multiplies: images are keyed per **feature set**, so the compose-ui-only,
material3+ui, material3-only and collection-only programs in the current fixture set are
four separate cold bakes after one edit. A single interpreter change therefore costs
several hundred seconds before the first assertion runs.

Two independent mitigations, both worth having:

- **Make the cost small** (item 1). Everything else is secondary to this.
- **Make the invalidation precise.** The exe stamp is maximally pessimistic: an edit to
  the JIT, the GC, or a CLI flag re-bakes lowering output that cannot have changed. A key
  derived from the inputs that actually determine lowering output (a hash over the
  lowering/resolution/compose-pass module sources, or an explicit `LOWERING_VERSION`
  constant bumped by those modules' owners) keeps correctness while letting unrelated
  edits reuse images.

### 3. Pack rebuilds are ordered, slow, and silently skew

`install-local-packs.sh` rebuilds all 23 packs in ~6 min and must run **after** the
binary, since packs are built by the binary. Getting that order wrong produces packs that
load but behave inconsistently, with no diagnostic — this cost real time this session, and
`AGENTS.md` already warns that a stale installed pack silently shadows source.

Wanted:

- **A staleness check, not a convention.** A pack records the lowering identity it was
  built with; loading a pack built by a different identity warns (or fails) with the
  rebuild command, instead of misbehaving.
- **Rebuild only what changed.** Pack sources change rarely; the common case after an
  interpreter edit is that no pack needs rebuilding at all. Content-hash each pack's
  source roots and skip unchanged packs.

### 4. No fast path to test a lowering or Compose decision

Every Compose decision today is validated end to end: build, bake, run a program, read a
crash. That is minutes per question, and it only covers call sites that happen to crash.

Wanted, in order of value:

- **A pass-level unit harness.** Given a small decl set plus a call site, assert the
  Compose pass's decision (threads or not, sink arity, memo wrap). Runs under
  `zig build test` in milliseconds and needs no bake. This is what makes RC-I's P11..P13
  drivable — the end-to-end fixtures become the final gate, not the primary loop.
- **The P10 decision audit** (see `resolution-unification-plan.md`). Coverage over the
  whole corpus in one run rather than one crash at a time.
- **A lowering-only entry point.** `klio dump-ir` already lowers without running, but it
  materialises the whole universe and was unusable on the material3 set here (no output
  within 100 s). A `--func`-scoped form that lowers only what a query needs would make IR
  inspection a first-class debugging tool instead of a last resort.

### 5. Loop ergonomics

Small, cheap, and immediately useful:

- **One entry point that gets the order right**: build binary, rebuild only stale packs,
  warm the images for the fixture set, then run. Encodes the ordering hazard from item 3
  so it cannot be got wrong by hand.
- **Warm-the-images target.** After an interpreter change the first run of each feature
  set pays the bake serially and on demand. Baking the known fixture feature sets in
  parallel up front converts N serial cold bakes into one wall-clock bake.
- **Cold-bake visibility.** A bake that takes minutes currently prints nothing until it
  finishes, which reads exactly like a hang; two runs were misdiagnosed that way this
  session. `KLIO_TRACE_STDLIB_IMAGE=1` output on by default for bakes over a few seconds
  would have prevented both.

## Order of work

1. ~~Profile and fix the lowering regression (item 1).~~ Done — lower 290.7 s ->
   25.8 s, cold bake ~31 s (see item 1).
2. Pack staleness stamp + skip-unchanged rebuild (item 3) — removes a silent-corruption
   class, not just time.
3. Pass-level unit harness (item 4) — unblocks RC-I P11..P13 without bakes.
4. Precise image invalidation (item 2) and the loop entry point + image warming (item 5).

## Success criteria

- Material3 cold bake back to the same order of magnitude as the 2026-07-11 result.
- An interpreter edit that cannot affect lowering does not re-bake.
- A stale pack is reported, never silently loaded.
- A Compose threading question is answerable by a test that runs in under a second.

## Session addendum (2026-07-26): the measurement loop for compose stability

Two additions from the gate-deficit investigation, which was itself an exercise
in these loops:

- **`scripts/compose-fleet.py`** — the per-class compose-runtime commontest
  fleet, mirroring the itest gate's environment (HOME-scoped data home,
  KLIO_COMPOSE_PLUGIN=1, capped timeouts) without its recompile cost. One
  class ~1 min; the full 46-class fleet ~10-15 min at 4 jobs; per-class logs
  under `.fleet-logs/` and a failure-signature census at the end. This is the
  ratchet-progress measure for driving the itest baseline back past 1210.

- **Item 3's silent-skew hazard, realized.** The repo-local `.klio-local`
  packs (installed 09:11) silently shadowed a different universe than the
  itest's freshly built packs: a fleet run against them produced failures that
  looked like regressions but were environment artifacts, costing a full
  diagnosis round. Until the staleness stamp lands, compose-fleet.py refuses
  to run without an explicit installed-pack home, and itest-environment work
  must use the itest's own home.

Working recipe for pack-source instrumentation (used to localize the Link-arm
failure): edit the upstream Kotlin under `kotlin-klio/*/upstream`, rebuild the
one pack (`klio-harness pack build kotlin-klio/klio-compose-runtime-engine`,
~30 s) and install it into the scratch home, run the one filtered test, revert
the submodule. Each probe cycle is ~2 min; println placement matters — a
statement added inside a hot inline chain (`guardChanges { ... .also {} }`)
perturbed lowering enough to change behavior, so wrap at function boundaries
instead (expression-body -> named inner function).

## Interpreter performance: the DeepRecursive commontest investigation (2026-07-26)

`DeepRecursiveTest.kt` end-to-end: **166 s -> 117 s** this session, all of it
in four tests that drive ~460k coroutine suspend/resume cycles (~250 us per
recursion step against kotlinc/JVM's sub-second total). Landed, each measured:

- `getenvSlice` memoization — libc `getenv` takes a process-wide lock and the
  trace gates consult it per dispatch; it profiled at a quarter of on-CPU
  time (~5% wall after caching because other costs dominate).
- Post-collection RSS trim rate-limited to 32 MB of freed bytes — the
  per-collection `malloc_zone_pressure_relief` was steady mmap/munmap
  traffic; ~25% wall on this workload.
- `KLIO_GC_GROWTH` Appel-multiplier knob — measured nearly flat (149 s at 8x
  vs 151 s at 4x vs 157 s at 2x), which disproves GC marking as the dominant
  cost despite its sample share.

What the profile actually says (macOS `sample`, top-of-stack census plus
call-tree): the cost is the interpreter's PER-CALL machinery, not one hog —
member-dispatch walks (an instance-method inline cache exists and hits; the
surrounding probe ladder and value plumbing still cost), the suspension
snapshot capture/rebuild per park/resume pair, and a full pump lifecycle
(coroPush + pumpLoop + pumpExit + persisted-registry traffic) TWICE per
DeepRecursive step because the interpreted `joinBlocking` driver leaves no
native pump on the thread (`coroTop() == null` forces the fresh-root and
driveResumed paths). Disproved along the way: resume-chain native nesting
(the new KLIO_PUMP_DIAG depth counter shows single digits).

The structural root cause, for the record: eval executes every interpreted
call by NATIVE recursion (~10 native frames per interpreted frame). That is
why 100k-deep plain recursion segfaults (measured), why suspension must
snapshot/rebuild frames instead of repointing them, and why per-step costs
cannot drop to JVM-order without restructuring. The proper fix is an
iterative frame loop for direct calls (explicit interpreter stack; native
recursion only at host boundaries) — it removes the eval-depth limit,
makes suspend/resume O(1) frame repointing, and shrinks every call's cost.
That is a planned interpreter restructure, not a patch; a DeepRecursive
host trampoline was prototyped and REJECTED as special-casing.

Also found (and fixed): the streamed `[test] ... Nms` duration was the delta
since the PREVIOUS record with an unset base, so the FIRST test always
printed 0 ms — under `--filter` that is the target test, which read as "did
not run" and briefly derailed this investigation. The base is now stamped at
run start.
