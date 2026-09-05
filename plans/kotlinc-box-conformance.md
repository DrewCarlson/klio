# kotlinc box-test conformance corpus

The Kotlin compiler's own `compiler/testData/codegen/box` suite is the widest
executable oracle for a Kotlin implementation: 7,351 `.kt` programs at the
pinned `kotlin` submodule revision (build-2.4.10-RC), each declaring
`fun box(): String` that must return `"OK"`. klio runs none of them today: the
`kotlin` submodule is a blobless sparse clone of `libraries/stdlib` and
`libraries/kotlin.test` only (`scripts/init-kotlin-submodule.sh`, CI's
"populate kotlin" step in `.github/workflows/ci.yml`).

Parent plan: `conformance-backlog.md`. Verification practice:
`verification-speed-plan.md` (harness + sweep, census children, ratchets);
gate wiring: `census-gates-and-red-mass.md`.

## Why this corpus

- Every program is small, deterministic, and self-checking; a failure is a
  semantic gap, not a flaky wall.
- It covers the language surface systematically (directories are features:
  `when`, `ranges`, `inlineClasses`, `coroutines`, `delegatedProperty`,
  `smartCasts`, `varargs`, `properties`, `sealed`, `contracts`, ...), so
  failures cluster by mechanism and each root fix closes many at once.
- It is the same oracle kotlinc gates itself on: matching it IS matching
  Kotlin semantics.

## Corpus facts to design against

- Directives are `// NAME` or `// NAME: value` header comments. Seen in a
  40-file sample of `box/ranges`: `WITH_STDLIB` (37), `FILE: name.kt` (18,
  splits one test into several source files), `LANGUAGE: +Feature` (7),
  `KJS_WITH_FULL_RUNTIME` (6). Others across the corpus: `TARGET_BACKEND`,
  `DONT_TARGET_EXACT_BACKEND`, `IGNORE_BACKEND`, `MODULE: name(deps)`,
  `WITH_COROUTINES` (pulls the framework's coroutine helpers),
  `WITH_REFLECT`, `FULL_JDK`, `JVM_TARGET`, `ASSERTIONS_MODE`.
- Multi-module tests (`MODULE:`) and JVM-only tests (`TARGET_BACKEND: JVM`,
  `FULL_JDK`, `WITH_REFLECT`, anything importing `java.*`) are out of klio's
  model; they are excluded BY DIRECTIVE, never by name.
- The sparse checkout must add `compiler/testData/codegen/box` and the
  helpers the directives reference (`WITH_COROUTINES` helpers live beside
  the corpus under `compiler/testData/codegen/helpers`; confirm the path
  when populating). Blobless clones fetch blobs lazily: the runner must
  never read the corpus through `git show`; populate once.

## Tasks

1. **Populate.** Extend `scripts/init-kotlin-submodule.sh` and the CI
   "populate kotlin" step with the two directories; `scripts/bootstrap.sh
   --packs` stays the one-shot. Exit: `kotlin/compiler/testData/codegen/box`
   present locally and on CI (the CI campaign's rule: populate every
   `update = none` submodule a corpus reads).
2. **Runner.** A census suite `box` (`src/itests/box_conformance.zig`,
   registered in `src/itests/census_main.zig`, driven by
   `zig-out/bin/klio-census box` with `KLIO_ITEST_BIN`) that: parses the
   directives; splits `FILE:` sections into files; selects by directive
   (an allowlist of directives klio honors, a denylist of JVM/JS/module
   ones, every exclusion counted and printed by reason); synthesizes
   `fun main() { val r = box(); if (r != "OK") throw AssertionError(r) }`
   as a trailing file (never edits the test); batches one directory per
   child like the sweep (`--no-batch` for isolation); per-file wall cap;
   names every failure (`[box-fail] dir/file.kt: <first line>`) and every
   exclusion reason. Exit: the suite runs end to end and prints
   `passed / failed / excluded(by reason) / did-not-complete`.
3. **Baseline.** Record the first full census (wall, pass count, exclusion
   census) here; ratchet `BASELINE` to the measured pass count with
   `MAX_FAILED 0`; add the suite to `scripts/stack.sh` and to a CI shard
   with a measured weight (4-core ReleaseSafe seconds ÷ 10). Exit: green
   battery and CI with the box suite standing.
4. **Root-fix by cluster.** Group failures by the first diagnostic or miss
   trace (`KLIO_ERR_TRACE`, `KLIO_MISS_TRACE`, `KLIO_BARE_TRACE`), take the
   largest cluster, root-fix the mechanism (never the test), re-census,
   ratchet up. Every fix ships an `examples/` program with its `.out` and
   README row, as the resolution-residue work did. Exit for this plan:
   every cluster of size ≥ 5 is either root-fixed or carries a verdict
   here (unsupported-by-design with the directive that should exclude it,
   or a named open mechanism with its repro); the residue list is the
   seed of the next campaign.

## Traps (from the stdlib and library censuses)

- A per-file compile that loses its helper files fails for starvation, not
  semantics (`klio-library-100-campaign` keeper): batch per directory.
- The census names must always print; a bare count is undiagnosable.
- Child timeouts must sit ≥ 1.5× the slowest healthy child on a 4-vCPU
  runner; harness Debug builds run ~4× slower (`harnessSlowdown`).
- A renamed or simplified copy of a failing test is for bisecting only;
  the corpus file must pass unmodified.

## Log

- 2026-09-05: opened.
