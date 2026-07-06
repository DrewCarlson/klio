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

## Runner ergonomics

The DEFAULT `klio test <project>` is a single in-process run of the composed
module — fast, simple, correct. The existing global run deadline
(`runtime.startRunDeadline()`) is the only safety net needed against a runaway
test; a genuinely hanging or stack-overflowing test is an interpreter/test BUG
to fix in the grind, not something to paper over with per-test process
isolation. (Composing atomicfu as one module already fixed its cross-file
failures AND surfaced a real test-runner class-collision bug — resolving bugs,
not hiding them, is the point.)

- `--filter <glob>` on `Class`, `Class.method`, or file — native; retires the
  sweep's filtering.
- `--isolate` (opt-in, debugging): run each test/file in its own sub-process
  with a per-test timeout, to pinpoint WHICH test hangs or crashes. Off by
  default. `--jobs N` parallel sub-processes compose with it. This is what the
  Zig harness's process pool did; it becomes an optional aid, not the norm.
- `--format=json` machine-readable summary (counts + per-test status +
  failure reasons) for CI. A commonTest itest becomes
  `klio test <library> --format=json` + a ratchet assertion.
- The runner must never SILENTLY drop tests: a discovered `@Test` that fails to
  register (name collision, load failure) has to surface, not vanish into an
  all-green count. (First instance fixed: the simple-name class-index collision.)
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

- [x] Phase 1 — manifest + resolver. `[[test]]` in the schema/parser;
  `src/cli/project.zig` resolver; `klio test <project>` composes the active
  test sets against the built+installed pack. atomicfu runs 67/67 in project
  mode. Path-dep auto-build is a remaining refinement (deps currently relied on
  as pre-installed).
- [x] Test-runner correctness — collect a class's tests from its own decl (not
  a same-named class in another package); "no tests found" for empty runs.
- [~] Phase 2 — runner ergonomics: `--filter` DONE (class + method name
  substring, retires the sweep's filter); feature selection DONE (`--all` /
  `--feature X`, default = all feature modules). Remaining: `--isolate`
  (opt-in debug), `--format=json`.
- [ ] Phase 3 — migrate harness + packs; retire the sweep.
- [~] Phase 4 — grind each pack's commonTest to 100%. Interpreter bugs found +
  fixed (not worked around):
  - Low-priority overload vs constructor (a general resolution bug): a
    `@LowPriorityInOverloadResolution` deprecated factory could statically bind
    over a same-name class constructor and self-recurse to a stack overflow
    (kotlinx-datetime `fun LocalDate`/`LocalDateTime`). Fixed across
    resolveCall / bare-call lowering / callNamedOverload / lookupGlobalById.
    Datetime composed run now COMPLETES: 72/523 (was: crash). Grind = library
    gaps (TimeZone.UTC/FixedOffsetTimeZone, format pkg, offsets).
  - datetime isLeapYear cross-package ambiguity — fixed (consumed upstream).
  Pack states in project mode:
  - atomicfu 67/67 (100%).
  - datetime 72/523 completes (library grind).
  - io / serialization: a SEPARATE composition-only crash remains (no single
    file crashes; deep-stack/null on the fully composed module — not the
    low-priority bug). Needs isolation to the triggering combination.
  - coroutines / ktor: need test-base actuals before they run.
