# Testing

klio's correctness rests on four layers.

## 1. Unit tests

Each module owns its unit tests as `test {}` blocks inside its
`.zig` files. Integration suites live under `src/itests/`, one test
binary per file for process isolation. They cover happy paths, edge
cases, and every diagnostic the code can emit.

```sh
zig build test
```

## 2. Negative tests

`src/itests/typeck_negative.zig` (fixtures under
`tests/fixtures/typeck_negative/`) pins diagnostic wording per code.
Removing a diagnostic or changing its phrasing fails the matching
case.

## 3. Corpus + parity sweep

The `parity` module is the primary correctness gate:

- Walks every `.kt` under `tests/fixtures/parity_corpus/` and
  `examples/`.
- Compiles each through `kotlinc` and through klio.
- Diffs stdout. Any byte difference fails the sweep.

The harness defaults to JVM `kotlinc` (fast: ~1s compile, jar run)
and targets Kotlin 2.3.21. It auto-installs a pinned `kotlinc` if
none is found; set `KLIO_KOTLINC_JVM_HOME` to point at an existing
distribution, or `KLIO_NO_AUTO_INSTALL_KOTLINC=1` to disable
auto-install (the parity tests then skip).

The `e2e` module runs every `examples/*.kt` in-process against the
checked-in expected output under `tests/corpus/expected/`, so the
example corpus is part of `zig build test`.

The corpus only grows. Removing a `.kt` from it is a deliberate act
that requires reviewer sign-off.

## 4. Pack smoke tests

Every pack ships a smoke flow:

```sh
./zig-out/bin/klio pack build src/kotlinx_datetime
./zig-out/bin/klio pack verify target/packs/kotlinx.datetime.klio-pack \
    --smoke tests/fixtures/<smoke>.kt
```

`pack verify` re-decodes every section through the loader; with
`--smoke` it also runs a program against the pack, exercising both
binding resolution and the shipped Kotlin source.

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

## Before committing

```sh
zig build
zig build test
```

CI runs the same flow on every PR, plus the parity sweep.
