# Project manifest — generalizing packs into runnable/testable projects

Goal: let klio operate on a *project* (a directory + manifest), not just
hand-listed files. `klio test [.]` and `klio run [.]` resolve a manifest,
compose the right source sets into one module, and run — with filtering,
parallelism, and test isolation built in. This dissolves the commonTest
harness (per-file argv, cross-file breakage) and the external
`commontest-sweep.py`, and it is the vehicle for running every kotlinx/ktor
pack's own `commonTest` and grinding each to 100%.

## Grounding facts (verified)

- `klio test <dir>` already composes a whole directory into ONE module: it
  recurses subdirs, resolves cross-file references, and runs every `@Test`.
  Running the same files *individually* (what the harness/sweep do) breaks
  cross-file resolution and undercounts — atomicfu is 58/59 as a directory
  vs 63-with-4-failures file-by-file.
- The pack manifest (`klio.toml`, schema in `src/pack/schema.zig`) already
  carries: `[library] id/version/abi`, multiple `[[source]] root + include`,
  `[[deps]] id + features`, and `[[features]]` (name, source patterns, deps,
  transitively-activated features). It describes a library to *pack*, not a
  project to *run/test*.
- `klio test` already accepts `<file|dir...>` and `--only-file=<path>` (compile
  everything, run only that file's tests). No name/class filtering yet; no
  built-in per-test timeout or parallelism (those live in the Zig itest
  harness + python sweep).

## Feature-scoped test sources (ktor)

Packs support Gradle/Maven-style *feature* modules (`io.ktor/server`,
`io.ktor/content-negotiation`, …). Each feature module ships its OWN
`common/test` tree, separate from the core module's. So test source sets must
be feature-scoped: a feature's tests are composed only when that feature is
active (default features, or `--feature <pack>/<feat>`), exactly as the
feature's `[[source]]` files already are. The core/default `[[test]]` is
always active; feature `[[test]]` stanzas gate on their feature.

## Manifest changes

Extend the existing manifest (same `klio.toml`, additive):

- `[[test]]` source sets: `root`, optional `include`, optional
  `feature = "<name>"`. Untagged `[[test]]` is core (always active); a tagged
  one composes only when its feature is active. Test sources are never packed
  or symbol-indexed — they exist only for `klio test`.
- Test-scoped deps: a dep marked `test = true` (e.g. `kotlin.test`) loads for
  `klio test` but not for a normal `run`/pack build. A library's own
  `[[source]]` is always an implicit dep of its `[[test]]`.
- Path deps: `[[deps]] path = "../klio-kotlinx-io"` builds+installs a sibling
  project's pack from source (Cargo path-dep style), so an in-repo project can
  depend on an unpublished sibling. Resolution order is the dependency DAG.
- Entry point for `run`: inferred (the decl with `fun main`), overridable via
  `[project] main = "..."`. A `[library]` project is just a project whose
  `[[source]]` is additionally packable; a plain app omits the packable bits.
  Same file, same resolver.
- Workspace: an optional root manifest listing member project dirs
  (`members = ["kotlin-klio/*"]`). `klio test` / `klio run` at the workspace
  root fans out over members. This makes the repo a workspace of projects.

## Command model

- `klio test [path]` / `klio run [path]`, `path` defaults to `.`.
  - Resolve the NEAREST manifest by walking up from `path` (package.json /
    Cargo.toml style). If `path` is a subdir of the project, tests still
    compose the whole project but the run is filtered to that subtree.
  - No manifest anywhere up-tree → infer: treat the dir as a source set
    (today's `klio test <dir>`), auto-add `kotlin.test` for `test`.
  - A file path keeps today's behavior.
  - A workspace manifest → run each member.
- Resolution pipeline (both commands): find manifest → resolve deps (build +
  install path deps, load installed ones, honor active features) → compose
  source sets (main + `[[test]]` for `test`, + actuals) into the load set →
  hand the composed file list to the EXISTING `runTestFiles` / run pipeline.

## Runner ergonomics (the only genuinely new engine work)

- `--filter <glob>` on `Class`, `Class.method`, or file — native; retires the
  sweep's filtering.
- Isolation with correct composition: compile the whole module ONCE (so
  cross-file resolution holds), then run each test under a per-test watchdog
  timeout so a single runaway test (1M-iteration stress loops) cannot sink the
  suite. With `--jobs > 1`, shard the composed module's tests across worker
  sub-processes. This is what the Zig harness's process pool did; it moves into
  klio.
- `--format=json` machine-readable summary (counts + per-test status +
  failure reasons) for CI. A commonTest itest becomes
  `klio test <library> --format=json` + a ratchet assertion.
- Keep `--eager`/`--opt`/`--feature`/`--virtual-time` as they are.

## Phased implementation

1. **Manifest + resolver.** Extend `src/pack/schema.zig` (`[[test]]` with
   feature scope; `test`/`path` deps). Add a `project` resolver: nearest-
   manifest walk-up, dependency DAG resolution (build+install path deps),
   source-set composition honoring `include` + active features. Wire
   `klio test`/`klio run` to default their path to `.` and feed the composed
   file set to the existing pipeline. Low risk — glue over working machinery;
   immediately improves commonTest accuracy.
2. **Runner ergonomics.** `--filter`, per-test watchdog timeout, `--jobs`
   sharding, `--format=json`. New engine code in the test runner.
3. **Migrate.** Add `[[test]]` stanzas (core + per-feature) to each library
   `klio.toml`; replace `commontest_support.zig`'s per-file argv with
   `klio test <library-project>`; retire `commontest-sweep.py`. Every baseline
   likely rises from correct whole-module composition alone.
4. **Grind.** With correct composition + native filtering, drive each
   kotlinx/ktor pack's commonTest to 100% (actuals first, then interpreter /
   library gaps), ratcheting each suite.

## Status

- [ ] Phase 1 — manifest + resolver
- [ ] Phase 2 — runner ergonomics
- [ ] Phase 3 — migrate harness + packs; retire the sweep
- [ ] Phase 4 — grind each pack's commonTest to 100%
