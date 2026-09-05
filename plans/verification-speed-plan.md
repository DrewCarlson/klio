# Verification-loop speed plan

Directive (2026-07-04): every verification — build one harness, run one suite,
one dual gate — must cost minutes, not 10-30. Fix root causes across the whole
loop: redundant build work, redundant test children, slow interpreted
iterations, cache pathology. This is the working document; keep measurements
and decisions here.

> **Superseded in part (2026-07-25).** The ~12 s material3 bake below has regressed to
> **302 s** (lower 284.5 s of it). The development loop — binary, packs, image bake, one
> program — is planned separately in `feedback-loop-plan.md`; this document remains the
> plan for the test-suite loop.

## Compose pack-set bake + warm run (2026-07-11 — LANDED)

The compose dev loop's dominant costs both fell an order of magnitude:

| Operation | Before | After | Fix |
| --- | --- | --- | --- |
| material3-set fresh bake | 117 s (lower 101.7 s) | **~12 s** (lower 6.5 s) | lazy lookup caches on `Module` (`packageHeadDeclared` prefix set, class name/FQN caches, const-intern dedup) — the lowering was O(refs × decls) in four linear scans |
| warm-run pack load | 2.24 s per run | **0.52 s** | packs carry a precomputed `imports` section; the image hit path (`asts_needed=false`) skips lex+parse of every pack source |
| warm realclick run, end to end | ~13 s | **~8.8 s** | above (prepare ≈ 1.7 s of it) |

The image key includes the exe stamp (size+mtime), so a `zig build` forces a
re-bake automatically — at ~12 s that is part of the loop, not a hazard.
Rebuilding/installing a pack changes its hash and therefore the image key.

Profiling tools that found this (all committed): `KLIO_PROF_ALL=1` starts the
SIGPROF sampler at process ENTRY (the run-command hook only wraps the VM — a
bake profiled without this collects almost nothing and the histogram lies);
`KLIO_PROF_CALLERS=<substr>` prints caller/grandcaller attribution for leaf
frames matching the substring; `KLIO_TRACE_STDLIB_IMAGE=1` bake lines carry
parse/lower/serialize ms.

## Measurements (2026-07-04, M-series 10-core/64 GB, macOS, zig 0.16.0)

| Operation | Cost | Notes |
| --- | --- | --- |
| `zig build klio-harness` no-op | **0.7 s** | healthy; the 1:37 outlier right after a cache prune is one-time revalidation |
| one-edit rebuild, ReleaseSafe harness | **83 s** | 100% single-core — whole-program LLVM codegen, no parallelism |
| one-edit rebuild, Debug harness (`-Dharness-optimize=Debug`) | **16 s** | 5.2× faster than ReleaseSafe |
| `-fincremental` one-shot | 21 s | worse than plain — incremental state dies with the process |
| `--watch -fincremental` | **BROKEN — do not use** | see below |
| one commontest child (ArrayDequeTest), ReleaseSafe | **7.9 s** | dominated by re-lowering ~40 same-dir sibling files per child |
| same child, Debug interpreter | **34 s** | 4.3× runtime penalty — sweeps must stay ReleaseSafe |
| full dual commontest gate (old way) | ~20 min | 4 full sweeps × ~106 children |
| single-file dual gate (`commontest-sweep.py --filter X --eager both`) | **~16 s** | new tool |
| `.zig-cache` growth | ~68 GB/day under heavy iteration | 152 GB found; no GC |

## Measurements (2026-07-13, 32-core Linux, after the slab-thrash fix)

The dominant cost was not the build or the harness: the slab allocator
unmapped a slab the instant its last live cell freed, and the interpreted
receiver chain holds exactly one live cell per frame — so every method call
under the **arena profile** (which every in-process harness uses) mapped,
threaded, and unmapped a 256 KB slab. Fixing that (one parked spare slab per
size class) moved the gates far more than any parallelism work:

| Gate | Before | After | Notes |
| --- | --- | --- | --- |
| `examples/jit_object_traversal_loop.kt`, arena + JIT | 3 min 04 s | **12.1 s** | sys time 2 m 23 s → 0.03 s |
| e2e corpus, **both** JIT modes | ~20 min | **56 s** | one process; `zig build itest-e2e` runs both |
| commontest dual sweep, ReleaseSafe harness | 33 min | **5 min 54 s** | `--jobs` now defaults to cores−2, not 6 |
| one commontest child (StringTest), Debug harness | 50 s | — | **never sweep on Debug** (see below) |
| same child, ReleaseSafe harness | **11.8 s** | — | 4.2× — matches the 2026-07-04 finding |

Two standing traps this re-confirmed:

- **Never run a full sweep against `klio-harness-Debug`.** It is 4–5× slower
  per child; a full dual sweep on it is ~33 min versus ~6 min on ReleaseSafe.
  Debug is for the *edit-repro loop* (fast rebuilds), never for a gate.
- **The arena profile is what the harnesses run.** The shipped `klio` binary
  defaults to the GC profile, so a perf bug that only bites the arena profile
  is invisible from the CLI and shows up only as a slow (or hung) gate. When a
  gate is inexplicably slow, reproduce it standalone with
  `KLIO_RECLAIM=arena` before blaming the harness.

## The iteration playbook (use these, not the old habits)

- **Edit-repro loop** (fixing one bug, running one program):
  `zig build klio-harness -Dharness-optimize=Debug` → 16 s per rebuild,
  installs as `zig-out/bin/klio-harness-Debug` (non-ReleaseSafe modes get
  their own name so they can never shadow the sweep binary). The Debug
  interpreter is ~4× slower per run — fine for single repros.
- **Targeted commontest check** (one file, both eager modes):
  `python3 scripts/commontest-sweep.py zig-out/bin/klio-harness --filter ArraysTest --eager both`
- **Threaded-litmus sweep** (~40 s, all 41 fixtures out-of-process):
  `python3 scripts/litmus-sweep.py [harness] [--filter substr]` — mirrors the
  `parity_threaded_litmus` itest without an itest rebuild. Part of the
  default battery: it caught a pre-run-rejection regression (intrinsic-only
  `thread` import) and a member-binding link hole the commontest and corpus
  sweeps cannot see.
- **One suite**: `zig build itest-<name>` (builds and runs just that suite).
  Never run `zig build itest-bin` (all ~56 binaries) during iteration.
- **Full gate before a commit**: `scripts/gate.sh` (unit + litmus set + e2e +
  examples + ktor/concurrency + commontest dual sweep). `--no-sweep` skips
  the slow tail.
- **Cache**: `scripts/prune-zig-cache.sh [days]` (default 2) whenever
  `.zig-cache` bothers you; safe at any time, first build after pays a
  revalidation pass (~90 s).

## Root causes still open (in impact order)

1. **Per-child sibling re-lowering** (commontest) — ADDRESSED (2026-07-21) by
   directory batching in `commontest-sweep.py`. Each child re-parsed and
   re-lowered every same-directory sibling (~40 files, ~7 s of the 7.9 s child);
   `sweep()` now groups run-targets by directory and runs each directory in ONE
   child (`run_dir`): compile the directory's files once, discover tests via a
   repeated `--only-file` per target (the harness already supports the multi-file
   form). This matches the canonical itest (which likewise compiles all files
   together) — verified IDENTICAL failure set to the per-file sweep across the
   full stdlib suite. `--no-batch` restores per-file children for hang isolation.

   Measured caveat: on a 32-core box the full-suite wall barely moved (172 s →
   168 s) because a few genuinely compute-heavy tests set the floor there —
   `DeepRecursiveTest.testBadClass` alone runs ~150 s interpreted (the ~300x
   raw-interpreter cost), and parallelism already hides the sibling redundancy.
   The batching win is on **limited-core CI** (4 vCPU), where the per-file
   redundancy cannot be parallelized away and each of ~40 files in a directory
   otherwise re-lowers the same siblings serially. The remaining full-suite floor
   is the compute-heavy tests, i.e. the raw-interpreter perf campaign — not the
   verification loop. The alternative fix (relax `canExtendBase` to cover sibling
   sets) is no longer needed for the sweep, but would still help any single-file
   run that re-lowers siblings.
2. **Whole-program LLVM rebuild on one edit** (83 s ReleaseSafe, single
   core). Mitigated by the Debug playbook. `--watch -fincremental` was
   tried and is BROKEN for this graph (zig 0.16.0): the incremental-built
   `stdlib-embed-gen` tool failed to spawn as `InvalidExe` when its run
   step fired, and the daemon (a resident build runner plus per-artifact
   compile servers) survives its stdout pipe closing, refires on every
   source-mtime change, and reinstalls its binary over `zig-out/bin` —
   it silently replaced the ReleaseSafe harness with a Debug one 20
   minutes after the experiment "ended". Distinct per-optimize binary
   names now bound the blast radius (`klio-harness-Debug`), but do not
   run a watch daemon until zig's incremental exe emission is reliable
   for run-step tools; re-evaluate on the next zig upgrade.
3. **itest-bin all-or-nothing**: ~56 ReleaseSafe links. Per-suite steps
   already exist (`zig build itest-<name>`); itest-bin stays a CI/stress
   tool. Consider trimming the default suite list or splitting
   fast/slow tiers if CI time regresses.
4. **Cache GC**: no upstream GC; `scripts/prune-zig-cache.sh` is the local
   policy (CI already wipes past 5 GB). Consider a launchd/cron weekly run.

## Log

- 2026-07-21: directory batching in `commontest-sweep.py` (root cause #1);
  strengthened the AGENTS.md playbook to make harness+sweep the default and flag
  `zig build itest-<suite>` as CI-only (it recompiles the whole itest binary —
  minutes — every run). Re-confirmed the full-suite dev-box floor is a few
  compute-heavy tests (`DeepRecursiveTest` ~150 s), not the loop.
- 2026-07-04: plan created; directive recorded in session memory.
- 2026-07-13: root-caused the gate's real cost to the slab allocator's
  empty-slab thrash (an mmap + 16 K-cell threading pass + munmap per
  interpreted method call under the arena profile); parked one spare slab per
  size class. e2e both-JIT ~20 min → 56 s, and a JIT corpus program that
  effectively hung the e2e gate now runs in 5.7 s in-process. Also raised
  `commontest-sweep.py --jobs` to default to cores−2 (was a fixed 6), and gave
  the e2e module test a `KLIO_E2E_SHARD=K/N` selector, a `KLIO_E2E_TRACE`
  progress print, and an installable `zig build itest-e2e-bin` so the corpus
  can be driven and bisected as a plain process.
- 2026-07-04: measurements above; shipped `scripts/commontest-sweep.py`
  (filtered dual-eager sweeps, replaces session-local perfile/perfail),
  `scripts/gate.sh` (one full-gate entry point), `scripts/prune-zig-cache.sh`
  (152 GB → 68 GB on first run). Old Rust-era `klio-parity-sweep.sh` deleted
  (parity runs through the `itest-parity_*` suites and `corpus_check.py`);
  `klio-guard.sh` and `klio-smoke.sh` repointed at `zig-out/bin/klio`.


## Root cause opened 2026-09-05 — the corpus check runs stale pack IR

The CLI-route corpus check is `scripts/corpus_check.py`, run by
`scripts/gate.sh`'s "corpus" phase against the repo-local data home (the
itest named `check_examples` is a resolver/typecheck cleanliness test on
four files, and CI has no CLI-route corpus run; the in-process e2e covers
the corpus there with packs lowered from source). The CLI loads the
INSTALLED packs: pre-lowered pack IR built by whichever klio installed
them. The compose-ui gate refreshes only its family (`PACK_FILTER`:
compose-*, kotlin-test, coroutines, atomicfu, androidx-collection), so a
lowering change that shows only inside another pack stays invisible:
the CI campaign's constructor-literal coercion broke `DatePeriod(days =
1)` in the datetime pack, and the corpus check kept passing on the stale
installed copy while the census (fresh pack) failed.

Fix (landed 2026-09-05): `scripts/refresh-local-packs.sh` reinstalls
EVERY shipped pack into `.klio-local` from the tree, keyed on the tree
content + installer binary (a no-op when unchanged); `gate.sh` runs it as
the "packs" phase right before "corpus". Parent plan:
`green-main-backlog.md`.

- [x] the refresh script + gate phase (ordered BEFORE the compose-ui
      gate so its example runs warm the bake cache the corpus reuses;
      corpus timeout 180 s — a cold compose bake is ~70 s locally, warm
      ~2 s)
- [x] proved 2026-09-05: a scratch worktree carrying the reverted
      call-site coercion, packs refreshed from that tree, turns the
      corpus phase red on `compose_colorspace` (`compose_paint` happens
      to survive on the CLI route; the in-process e2e caught both)
- [x] the rule in `ci-green.md`
- [x] what the refreshed corpus found on `main` itself:
      `channel_segment_namesake.kt` needs `--feature io.ktor/io` and
      carried no `// Run with:` directive, so the CLI corpus had been
      failing it (the in-process e2e has no feature gating and passed).
      Directive added; the rest of the corpus is green with fresh packs.
