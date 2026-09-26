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
- `zig build itest` — the integration suite: it runs whole programs
  through the harness binary (the `parity_*` suites, `e2e`,
  `stdlib_commontest`, etc.), so it takes minutes. Run one in isolation
  with `zig build itest-<name>`.
- `zig build test-all` — both.
- `-Ditest-shard=K/N` — run only shard K of the integration suite. The
  suites (plus `e2e` and `bench`) are packed into N weight-balanced
  bins from the `weight` field on each `Itest` entry in `build.zig`;
  CI fans the suite across parallel shard jobs this way, with the unit
  tests as their own fast job. Keep the weights of the heavy suites
  roughly current when their cost changes materially.

## 2. Negative tests

`src/itests/typeck_negative.zig` (fixtures under
`tests/fixtures/typeck_negative/`) pins diagnostic wording per code.
Removing a diagnostic or changing its phrasing fails the matching
case.

## 3. Corpus + parity suites

Every program-running suite runs Kotlin the way a user does: through the
harness binary (`KLIO_ITEST_BIN`) as a child `klio run`, over a data home
with the shipped packs installed. `src/itests/klio_child.zig` is the shared
runner. The build's `klio-test-home` step builds and installs every pack
once into `zig-out/klio-test-home` with the harness, keyed by the harness
binary and every pack source, and names it in `KLIO_ITEST_HOME`; a suite
binary started by hand without it installs the packs into
`/tmp/klio_itest_home` on first use.

- The `parity_*` suites (folded into the `group_parity_core`, `_types` and
  `_shapes` binaries) and `parity_corpus_pinned`
  (`tests/fixtures/parity_corpus/`) pin kotlinc's output for each program.
  They run with `--virtual-time`, and compare stdout line by line with
  every line newline-terminated.
- `parity_threaded_litmus` runs `tests/fixtures/threaded_litmus/` and the
  memory-model conformance programs on real threads.
- `differential` runs every example and coroutine smoke program over the
  cached base image and over a base analyzed afresh (`KLIO_SEMA_IMAGE=0`);
  the outcomes must be identical, and independent of program order.
- The Compose examples have their own oracle: Compose Desktop 1.12.0 on the
  JVM. `scripts/compose-oracle.py <example>...` compiles an example that
  uses `KlioComposeScene`, the headless helper klio's ui pack defines over
  upstream's ImageComposeScene, with kotlinc 2.4.20 and the Compose compiler
  plugin, beside the same helper over Compose Desktop's ImageComposeScene,
  runs it headless, runs it on klio, and diffs the two
  outputs (pixels read back, text metrics, event sequences). `--jvm-only`
  prints the JVM output, which is the expected output for a new example.
  The classpath is resolved from Maven by `scripts/compose-oracle-fetch.py`
  into `target/parity-cache/compose-desktop-1.12.0` on first use.
- The `e2e` module runs every `examples/*.kt` against the checked-in
  expected output under `tests/corpus/expected/`, byte for byte, with JIT on
  and off.

`src/itests/kotlinc_support.zig` locates or installs the reference compiler.
It defaults to JVM `kotlinc` (fast: ~1s compile, jar run) and targets Kotlin
2.4.20, auto-installing a pinned `kotlinc` under `target/parity-cache` if
none is found; set `KLIO_KOTLINC_JVM_HOME` to point at an existing
distribution, or `KLIO_NO_AUTO_INSTALL_KOTLINC=1` to disable auto-install.
The fuzzer diffs a failing program against it.

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
  per-file counts, and `--eager both` runs the whole corpus twice and
  reports any run-to-run divergence.

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
tracked in `plans/open-campaigns.md`.

A suite whose tests call a server over the network declares it as a
`service` in its `commontest_support.suites` entry: the `klio` arguments
that start it and the port it listens on. The census starts the
service before the suite's children, waits until the port accepts on
127.0.0.1 (`ready_ms`), and kills it when the suite ends. Its output
goes to `klio-census-<suite>-service.log` in the temporary directory,
and the census prints the log's tail when the service never answers or
the suite fails. Port zero picks a free port, which the service and
every child read from `KLIO_SERVICE_PORT`; a fixed port is for tests
that name one (ktor's client suites call its test server at
127.0.0.1:8080), and suites sharing a fixed port take turns on a lock
file in the temporary directory, across worktrees too.

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

## Harness build modes and the base image

- **Harness optimize mode.** The program-running suites spawn
  `zig-out/bin/klio-harness`, which compiles ReleaseSafe — safety
  checks stay on — via the `-Dharness-optimize` option (default
  `ReleaseSafe`). Per-module unit tests and the installed
  `zig-out/bin/klio` keep the default optimize mode, so the
  `testing.allocator` leak/UAF discipline and developer-facing
  behavior are unchanged. `zig build klio-harness` builds it directly;
  set `KLIO_ITEST_BIN` to point a suite at a different binary.
- **The base image.** `klio run` bakes the analyzed and lowered base (the
  stdlib and the packs a program loads) to
  `$KLIO_HOME/.klio/cache/sema-base-<key>.klio-sema` on first use, keyed by
  the binary and the base's text, and builds every later program over it.
  The `stdlib_image` itest gates it: bake → hit, a redeclared stdlib name,
  a corrupted image, a stale stdlib source and an installed pack, each
  compared byte for byte against a run over a base analyzed afresh
  (`KLIO_SEMA_IMAGE=0`). The image's own encoding is tested in the
  `lower_driver` module (`src/lower_driver/tests/image.zig`).
  `parity_stdlib_isolation` and the differential's order-independence
  test gate cross-program contamination through the cached image.

## The iteration playbook

Match the check to the size of the change
(`docs/development/verification-playbook.md` is the working record):

- **Edit-repro loop** (fixing one bug, running one program):
  `zig build klio-harness -Dharness-optimize=Debug` (~16 s per
  rebuild, installs as `zig-out/bin/klio-harness-Debug`). The Debug
  interpreter runs ~4x slower — fine for single repros.
- **Targeted commontest check** (one file):
  `python3 scripts/commontest-sweep.py zig-out/bin/klio-harness --filter ArraysTest`
- **One suite**: `zig build itest-<name>`. Never build `itest-bin`
  (all standalone itest binaries) during iteration.
- **Full gate before a commit**: `scripts/gate.sh` — the Skia shim
  (`scripts/fetch-skia.sh`, then `zig build skia-lib`; see the verification
  playbook), unit tests, the parity groups, the threaded litmus, e2e and the ktor/concurrency suites,
  a tree-keyed reinstall of every shipped pack into `.klio-local`
  (`scripts/refresh-local-packs.sh`), the compose-ui gate, the full example
  corpus through the CLI, the sema census (`scripts/sema-census.py`: no
  unresolved or unrecorded reference in the base, any installed pack or the
  corpus beyond `tests/sema-census-open.txt`), then the commontest sweep.
  `--no-sweep` skips the slow tail.
- **Cache**: `scripts/prune-zig-cache.sh [days]` when `.zig-cache`
  grows unreasonably (Zig has no cache GC of its own).

CI runs `zig build test-all`, sharded across parallel jobs with
`-Ditest-shard=K/N`.
