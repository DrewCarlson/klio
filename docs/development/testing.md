# Testing and verification

klio's correctness rests on five layers, and the tooling under
`scripts/` keeps every check in the minutes range.

## 1. Unit tests

Each module owns its unit tests as `test {}` blocks inside its
`.zig` files. Integration suites live under `src/itests/`, one test
binary per file for process isolation. They cover happy paths, edge
cases, and every diagnostic the code can emit.

The suite is split by cost:

- `zig build test` — the fast module unit tests only (seconds). Use
  this in the inner dev loop.
- `zig build itest` — the integration suite: it interprets whole
  programs (the `parity` sweep, `e2e`, `stdlib_commontest`, etc.), so
  it takes minutes. Run one in isolation with `zig build itest-<name>`.
- `zig build test-all` — both.
- `-Ditest-shard=K/N` — run only shard K of the integration suite. The
  suites (plus `e2e` and `bench`) are packed into N weight-balanced
  bins from the `weight` field on each `Itest` entry in `build.zig`;
  CI fans the suite across parallel shard jobs this way, with the unit
  tests as their own fast job. Keep the weights of the heavy suites
  roughly current when their cost changes materially.

Fast resolution-audit cycle: the overload-resolution unification work
(`plans/resolution-unification-plan.md`) verifies a scorer slice with
`scripts/resolve_audit_sweep.py --build`, not the ~18-minute ReleaseSafe
canonical. It rebuilds the fast Debug `klio` (~2s incremental) and sweeps the
whole stdlib commonTest corpus with `KLIO_RESOLVE_AUDIT=1`, reporting every
`[KLIO_RESOLVE_AUDIT] <member|scorer> ... divergent=1` line where the shared
`applicable()` disagrees with the legacy scorer (~2 minutes, 32-way). Zero
divergence proves the shared engine reproduces the legacy scorer before the
flip — a stronger check than the flaky ±3 canonical count. Reserve the
ReleaseSafe canonical (`zig build itest-stdlib_commontest`) for the flip
milestones.

## 2. Negative tests

`src/itests/typeck_negative.zig` (fixtures under
`tests/fixtures/typeck_negative/`) pins diagnostic wording per code.
Removing a diagnostic or changing its phrasing fails the matching
case.

## 3. Corpus + parity sweep

The `parity` module is a primary correctness gate:

- Walks every `.kt` under `tests/fixtures/parity_corpus/` and
  `examples/`.
- Compiles each through `kotlinc` and through klio.
- Diffs stdout. Any byte difference fails the sweep.

The harness defaults to JVM `kotlinc` (fast: ~1s compile, jar run)
and targets Kotlin 2.4.0. It auto-installs a pinned `kotlinc` if
none is found; set `KLIO_KOTLINC_JVM_HOME` to point at an existing
distribution, or `KLIO_NO_AUTO_INSTALL_KOTLINC=1` to disable
auto-install (the parity tests then skip).

The `e2e` module runs every `examples/*.kt` in-process against the
checked-in expected output under `tests/corpus/expected/`, so the
example corpus is part of `zig build itest` (it interprets programs,
so it rides the integration suite, not the fast unit step).

In-process parity/e2e execution uses the same runtime profile as the CLI:
`safe` by default (interpreter plus tracing GC), `fast` when requested, and
the no-GC phase arena only under the explicit `off` profile. Parsing and IR
lowering remain arena-scoped compiler phases; VM cells use the production
page-returning slab allocator and are collected at each program boundary.

The corpus only grows. Removing a `.kt` from it is a deliberate act
that requires reviewer sign-off.

## 4. Stdlib commonTest suite

The upstream stdlib's own `commonTest` sources
(`kotlin/libraries/stdlib/test`, 117 files, ~2,150 tests) run
directly under the interpreter through `klio test`. Two entry
points:

- `zig build itest-stdlib_commontest` — the canonical ratcheted
  suite (`src/itests/stdlib_commontest.zig` enforces a minimum pass
  count that only goes up).
- `scripts/stack.sh` — the full local battery, run once per stage: the
  leaf-pack build, the compose plugin gate on its own L3 domain, ten library
  censuses in two waves plus `itest-check_examples`, the stdlib commontest
  sweep (117 upstream files, scraped for `0 failures`), the compose-ui gate,
  and the threaded litmus last. `STACK_NO_CACHE=1` forces a run on an
  unchanged tree.
- `scripts/corpus_check.py` — every `examples/*.kt` through the CLI route
  against `tests/corpus/expected/`. It refuses to run against the shared
  `~/.klio` data home (its installed packs shadow the tree): run
  `scripts/refresh-local-packs.sh` and pass `KLIO_HOME=$PWD/.klio-local`, or
  `--allow-shared-home` on purpose. `--list-fail` names the failures.
- `zig build itest-box_conformance` / `zig-out/bin/klio-census box` — the
  kotlinc box-test corpus (`kotlin/compiler/testData/codegen/box`, populated
  by `scripts/init-kotlin-submodule.sh`): one child `klio run` per selected
  test, `box()` must return `"OK"`. Selection is by header directive
  (`src/itests/box_support.zig`); every run prints the exclusion census
  (`[box-excluded] reason: n`) and names each failure (`[box-fail] path:
  first line`). `KLIO_BOX_FILTER=<substring>` runs a subset,
  `KLIO_BOX_TIMEOUT_MS` sets the per-test wall.
- `scripts/commontest-sweep.py BIN` — the iteration driver: per-file
  pass counts and failed test names for any klio binary.
  `--filter <File>` runs one file (~16 s), `--passes` prints
  per-file counts, and `--eager both` runs the whole corpus under
  eager resolution OFF and ON and reports any divergence between the
  two modes.

## 4a. Library commonTest suites (project mode)

Each kotlinx/ktor library is a *project* (`kotlin-klio/klio-*`) whose
`klio.toml` declares `[[test]]` source sets pointing at the upstream
`commonTest` tree. `klio test <library-dir>` builds+installs the pack
and composes those test sources into ONE module — the accurate way to
run a library's own suite (running files individually breaks
cross-file resolution and mis-counts). Native runner options replace
the external sweep's ad-hoc flags:

- `--filter <substring>` — one class/method/file (retires the sweep's
  `--filter`).
- `--format json` — machine-readable counts + per-test status for a CI
  ratchet (`klio test <library> --format=json` + a floor assertion).
- `--list` — enumerate `@Test` names without running.
- `--isolate [--timeout <s>]` — opt-in debug: one sub-process per test
  with a per-test timeout, to pinpoint a hanging (`TIMEOUT`) or crashing
  (`CRASH`) test. The default single in-process run is faster and is
  the norm; a genuine hang is an interpreter/test bug to fix, not to
  paper over. See [Testing with KLIO](../testing.md#runner-options).

The `src/itests/*_commontest.zig` suites drive these per library and
ratchet the pass count. The migration from the per-file driver + the
Python sweep to a single `klio test <project> --format=json` is
tracked in `plans/project-manifest.md`.

## 5. Pack smoke tests

Every pack ships a smoke flow:

```sh
./zig-out/bin/klio pack build kotlin-klio/klio-kotlinx-datetime
./zig-out/bin/klio pack verify target/packs/kotlinx.datetime.klio-pack \
    --smoke tests/fixtures/<smoke>.kt
```

`pack verify` re-decodes every section through the loader; with
`--smoke` it also runs a program against the pack, exercising both
binding resolution and the shipped Kotlin source.

## Checking one module in isolation

`python3 scripts/zigcheck.py <module>` compiles and tests a single
Zig module with its dependency graph wired via explicit `-M` flags —
no `build.zig` edit, no rebuilding of unrelated modules. Pass
`--build-only` to just compile.

## Harness build modes and the shared stdlib base

Two mechanisms keep the suite fast:

- **Harness optimize mode.** The program-running test binaries (the
  `parity_*` itests, `e2e`, `bench`, the fuzzer, the differential, and
  the child-spawning ktor/json gates) compile ReleaseSafe — safety
  checks stay on — via the `-Dharness-optimize` option (default
  `ReleaseSafe`). Per-module unit tests and the installed
  `zig-out/bin/klio` keep the default optimize mode, so the
  `testing.allocator` leak/UAF discipline and developer-facing
  behavior are unchanged. The child-spawning itests run programs
  through `zig-out/bin/klio-harness` (also buildable directly with
  `zig build klio-harness`); set `KLIO_ITEST_BIN` to point them at a
  different binary.
- **Once-per-process stdlib base.** The in-process harness path
  (`parity.runInMode` and everything built on it) lowers the stdlib
  and pack sources once per (load mode, pack subset, stdlib gate) into
  an immutable snapshot, then extends an arena-backed clone with just
  each program's declarations. A program that redeclares a base
  top-level name (or uses expect/actual, a base package, or a
  function-type alias matching a base parameter type) takes the
  original whole-program build instead, so resolution semantics are
  never approximated. Set `KLIO_TRACE_STDLIB_BASE=1` to print one
  `fast`/`fallback` line per program. The
  `parity_stdlib_isolation` itest and the differential's
  order-independence test gate cross-program contamination.
- **Build-time baked parity bases.** The `parity-base-gen` build step
  bakes the EmbeddedOnly bases (both stdlib gate variants) to
  `zig-out/parity-base/embedded-gate{0,1}.klio-image` once per build,
  and every parity-data run step points its processes at them via
  `KLIO_PARITY_BASE_IMAGES`, so each test binary loads the lowered
  stdlib instead of re-parsing and re-lowering it at startup. The
  image bytes are declared run-step cache inputs, and any read or
  decode failure falls back to the per-process source build. When
  running an installed `zig-out/bin/itest-*` binary by hand, export
  `KLIO_PARITY_BASE_IMAGES=zig-out/parity-base` to keep the fast
  startup.
- **Baked stdlib image (the CLI's equivalent).** `klio run` serializes
  the same kind of lowered base to `~/.klio/cache` on first use and
  loads + extends it on every later run (`src/interp_ir/image.zig`,
  `src/cli/stdlib_image.zig`). The `stdlib_image` itest gates it: bake
  → hit → fallback → corrupted image → stale stdlib source, each
  byte-compared against the legacy whole-program build, plus an
  in-process bake/load round trip over the lowered tables. The codec
  itself (memoizing postcard variant) has unit tests in
  `src/interp_ir/image.zig`. Set `KLIO_STDLIB_IMAGE=0` to disable and
  `KLIO_TRACE_STDLIB_IMAGE=1` to trace.

## The iteration playbook

Match the check to the size of the change
(`plans/verification-speed-plan.md` is the working record):

- **Edit-repro loop** (fixing one bug, running one program):
  `zig build klio-harness -Dharness-optimize=Debug` (~16 s per
  rebuild, installs as `zig-out/bin/klio-harness-Debug`). The Debug
  interpreter runs ~4x slower — fine for single repros.
- **Targeted commontest check** (one file, both eager modes):
  `python3 scripts/commontest-sweep.py zig-out/bin/klio-harness --filter ArraysTest --eager both`
- **One suite**: `zig build itest-<name>`. Never build `itest-bin`
  (all standalone itest binaries) during iteration.
- **Full gate before a commit**: `scripts/gate.sh` — unit tests, the
  litmus/e2e/examples/ktor/concurrency suites, the compose-ui gate, a
  tree-keyed reinstall of every shipped pack into `.klio-local`
  (`scripts/refresh-local-packs.sh`, so the CLI corpus check below runs
  pack IR lowered from this tree, not whatever installed it last), the
  full example corpus through the CLI, then the commontest dual eager
  gate. `--no-sweep` skips the slow tail.
- **Cache**: `scripts/prune-zig-cache.sh [days]` when `.zig-cache`
  grows unreasonably (Zig has no cache GC of its own).

CI runs `zig build test-all`, sharded across parallel jobs with
`-Ditest-shard=K/N`.
