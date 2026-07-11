# Verification-loop speed plan

Directive (2026-07-04): every verification — build one harness, run one suite,
one dual gate — must cost minutes, not 10-30. Fix root causes across the whole
loop: redundant build work, redundant test children, slow interpreted
iterations, cache pathology. This is the working document; keep measurements
and decisions here.

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

## The iteration playbook (use these, not the old habits)

- **Edit-repro loop** (fixing one bug, running one program):
  `zig build klio-harness -Dharness-optimize=Debug` → 16 s per rebuild,
  installs as `zig-out/bin/klio-harness-Debug` (non-ReleaseSafe modes get
  their own name so they can never shadow the sweep binary). The Debug
  interpreter is ~4× slower per run — fine for single repros.
- **Targeted commontest check** (one file, both eager modes):
  `python3 scripts/commontest-sweep.py zig-out/bin/klio-harness --filter ArraysTest --eager both`
- **One suite**: `zig build itest-<name>` (builds and runs just that suite).
  Never run `zig build itest-bin` (all ~56 binaries) during iteration.
- **Full gate before a commit**: `scripts/gate.sh` (unit + litmus set + e2e +
  examples + ktor/concurrency + commontest dual sweep). `--no-sweep` skips
  the slow tail.
- **Cache**: `scripts/prune-zig-cache.sh [days]` (default 2) whenever
  `.zig-cache` bothers you; safe at any time, first build after pays a
  revalidation pass (~90 s).

## Root causes still open (in impact order)

1. **Per-child sibling re-lowering** (commontest): each child re-parses and
   re-lowers every same-directory sibling (~40 files in `collections/`) —
   ~7 s of the 7.9 s child. Fixes: extend the baked-image fast path to
   cover sibling sets (relax `canExtendBase` — known open item), or batch
   children per directory (one process compiles siblings once, runs each
   target's tests with successive `--only-file` filters).
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

- 2026-07-04: plan created; directive recorded in session memory.
- 2026-07-04: measurements above; shipped `scripts/commontest-sweep.py`
  (filtered dual-eager sweeps, replaces session-local perfile/perfail),
  `scripts/gate.sh` (one full-gate entry point), `scripts/prune-zig-cache.sh`
  (152 GB → 68 GB on first run). Old Rust-era `klio-parity-sweep.sh` deleted
  (parity runs through the `itest-parity_*` suites and `corpus_check.py`);
  `klio-guard.sh` and `klio-smoke.sh` repointed at `zig-out/bin/klio`.
