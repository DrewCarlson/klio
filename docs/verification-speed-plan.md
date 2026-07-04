# Verification-loop speed plan

Directive (2026-07-04): every verification — build one harness, run one suite,
one dual gate — must cost minutes, not 10-30. Fix root causes across the whole
loop: redundant build work, redundant test children, slow interpreted
iterations, cache pathology. This is the working document; keep measurements
and decisions here.

## Observed costs (2026-07-04 session, M-series 10-core/64 GB, macOS)

- `zig build klio-harness` after one edit in `src/interp_ir/vm`: minutes per
  rebuild (ReleaseSafe via LLVM), and the session needed six of them.
- `zig build itest-bin`: ~56 standalone binaries, each linking the whole
  interpreter (ReleaseSafe); first build ~30+ min, warm rebuild after an
  interp edit still relinks every binary.
- Dual stdlib-commontest gate: 4 full sweeps (perfile/perfail × eager ON/OFF),
  each spawning ~106 `klio test` children; each child re-parses and re-lowers
  its sibling files and any needed packs (the baked stdlib image covers only
  the stdlib).
- Two optimize universes by design (`optimize=Debug` for unit tests,
  `harness-optimize=ReleaseSafe` for program-running harnesses); an explicit
  `-Dharness-optimize=Debug` run builds a third graph.
- `.zig-cache` measured at **152 GB** (no GC); CI already wipes past 5 GB
  because unbounded caches killed jobs.

## Hypotheses to measure (in order)

1. **Cache pathology**: does a 152 GB `.zig-cache` slow hash/lookup or disk?
   Measure warm no-op `zig build klio-harness` before/after a cache reset.
2. **Link dominance**: for a one-file interp edit, how much of the harness
   rebuild is LLVM codegen vs link? (`zig build --verbose` timing / `-ftime-report`.)
   If link-dominated: fewer, thinner binaries.
3. **Per-binary duplication in itest-bin**: do the 56 binaries share object
   cache (same flags → hits) and only pay links, or recompile? If links: stop
   installing all 56 by default; build-on-demand per suite.
4. **Debug-backend iteration builds**: Zig 0.16 self-hosted backend for
   Debug on aarch64-macos — is a Debug harness build seconds instead of
   minutes, and is the Debug interpreter fast enough for the sweeps
   (commontest child ~0.4s parity cost claimed in CI notes)? If yes: default
   local verification to Debug harness, keep ReleaseSafe for perf-sensitive
   suites and CI-weekly.
5. **Child-process redundancy**: commontest children re-lower sibling targets
   and packs per child. Extend the baked-image fast path (relax
   `canExtendBase` — known open item), or run targets in-process batches.
6. **Sweep granularity**: perfail/perfile rerun all ~106 files to answer
   questions about 4; need a single-file/filtered mode (`--only-file` exists —
   the sweep tooling just never exposes it).

## Decisions / work items

- [ ] Measure 1-6 above; record numbers here.
- [ ] Pick the default local iteration universe (likely Debug self-hosted
      harness + ReleaseSafe only where measured necessary).
- [ ] itest-bin: per-suite named build steps instead of all-56 default.
- [ ] Cache policy: bounded local cache (periodic prune or `--cache-dir`
      rotation), matching the CI 5 GB wipe.
- [ ] Filtered sweep mode for commontest (single file / file list, both eager
      modes in one invocation).
- [ ] Fold the session gate scripts (litmus set + dual sweep) into a checked-in
      `scripts/` entry point so every session stops rebuilding its own harness.

## Log

- 2026-07-04: plan created; directive recorded in session memory.
