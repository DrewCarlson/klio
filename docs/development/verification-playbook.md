# Verification playbook

How to verify a change at each scope, from one program to the whole local
gate. Every step here costs seconds to minutes; the rule is to pick the
narrowest step that answers the question and to run the whole battery once
per stage, not per edit.

## Binaries

- `zig build klio-harness` installs the ReleaseSafe harness at
  `zig-out/bin/klio-harness`. A no-op rebuild is about a second; a one-edit
  rebuild is one whole-program link (single-core LLVM, about 80 s).
- `zig build klio-harness -Dharness-optimize=Debug` installs
  `zig-out/bin/klio-harness-Debug` (about 16 s per rebuild). Its
  interpreter runs about four times slower, so it serves the edit-repro loop
  for one program and never a sweep or a gate.
- `zig build` alone produces a Debug `klio` CLI; benchmarks and gates use
  the harness or a ReleaseFast build, never that binary.
- Non-ReleaseSafe harness builds get their own names so they can never
  shadow the sweep binary.

## Steps by scope

| Question | Command | Cost |
| --- | --- | --- |
| Does one program behave? | `KLIO_HOME=$PWD/.klio-local zig-out/bin/klio-harness run file.kt` (add the `// Run with:` header flags an example declares, e.g. `--feature kotlinx.serialization/json`) | seconds |
| One stdlib commontest file, both eager modes | `python3 scripts/commontest-sweep.py zig-out/bin/klio-harness --filter ArraysTest --eager both` | ~15 s |
| The whole stdlib commontest | `python3 scripts/commontest-sweep.py zig-out/bin/klio-harness` (per-directory batching; `--no-batch` isolates a hang) | minutes |
| One box conformance directory | `KLIO_ITEST_BIN=zig-out/bin/klio-harness KLIO_BOX_FILTER=ranges/ KLIO_BOX_JOBS=4 zig-out/bin/klio-census box` (`KLIO_BOX_FILTER` is a path substring: use `enum/`, not `enum`) | ~1 min |
| One box test by hand | copy the file, append `fun main() { println(box()) }`, run it through the harness | seconds |
| One library census | `KLIO_ITEST_BIN=zig-out/bin/klio-harness zig-out/bin/klio-census <coroutines|datetime|serialization|serialization_json|io|atomicfu|ktor|compose_ui|box>` | minutes |
| One compose plugin class | `HOME=/tmp/klio_itest_compose_plugin_home KLIO_COMPOSE_PLUGIN=1 zig-out/bin/klio-harness test <the plugin file list> --filter=<Class[.test]>` (never the whole list in one process) | seconds |
| The example corpus on the CLI route | `KLIO_BIN=zig-out/bin/klio-harness scripts/refresh-local-packs.sh` then `KLIO_HOME=$PWD/.klio-local python3 scripts/corpus_check.py --zig zig-out/bin/klio-harness --no-rust --timeout 180 --list-fail --jobs 4` | minutes |
| The threaded litmus set | `python3 scripts/litmus-sweep.py [harness] [--filter substr]` | ~40 s |
| The in-process e2e corpus (both JIT modes) | `zig build itest-e2e -Dharness-optimize=ReleaseSafe` | ~10 min |
| The pinned parity corpus | `zig build itest-parity_corpus_pinned -Dharness-optimize=ReleaseSafe` | minutes |
| The whole local gate | `scripts/stack.sh` | ~23 min warm |
| The CI shape | `taskset -c 0-3 zig build itest -Ditest-shard=K/8 -Dharness-optimize=ReleaseSafe` | 12-21 min per shard |

`zig build itest-<suite>` recompiles the whole itest binary every time
(minutes of single-core LLVM). It is the CI and pre-commit form of a suite,
not an iteration tool; the harness plus the census or sweep answers the
same question in seconds.

## What the local gate covers, and what it does not

`scripts/stack.sh` builds the leaf packs, runs the compose plugin gate, the
library censuses (coroutines, io, androidx collection, ktor, datetime,
serialization, serialization json, compose ui, atomicfu), the example
corpus lowered from the tree (`itest-check_examples`), the box conformance
census, the stdlib commontest sweep, the compose-ui gate, and the threaded
litmus last. It does not run the in-process e2e corpus, the pinned parity
corpus, or the CLI-route corpus check; run those three separately when a
change touches lowering, reification, or pack loading.

Two suites that are not in the stdlib sweep have caught lowering
regressions the sweep passed: the coroutines census (an inline reified
binding) and the pinned parity corpus. A lowering change needs both.

## Packs and the data home

`klio run` loads the installed packs from the data home, which shadow the
`kotlin-klio/` sources. All local pack work points `KLIO_HOME` at the
repo-local `.klio-local` (`scripts/klio-local.sh`,
`scripts/install-local-packs.sh`); the installed packs live under
`.klio-local/.klio/packs`. `scripts/refresh-local-packs.sh` reinstalls
every shipped pack from the tree, keyed on the tree content and the
installer binary (a no-op when unchanged); `PACKS_NO_CACHE=1` forces the
re-bake. A pack image embeds lowering decisions, so a lowering or registry
change needs a refresh before the corpus check means anything, and an
image format bump invalidates the installed packs.

`corpus_check.py` refuses an unset or shared `KLIO_HOME` unless
`--allow-shared-home`; the shared `~/.klio` reports fake failures from
stale packs.

## Standing rules and traps

- Never run a full sweep or census on the Debug harness; it is four to
  five times slower per child.
- Never rebuild `zig-out/bin/klio-harness` (and never `git stash`) while a
  lane is using it; build to another prefix (`zig build klio-harness
  --prefix <dir>`) to test an edit alongside running lanes.
- A ratchet's `BASELINE` is the measured pass floor and `MAX_FAILED` the
  measured failure ceiling with no slack; count `[box-crash]` lines as well
  as `[box-fail]` lines when clustering a census.
- The arena profile is what the harnesses run; the shipped CLI defaults to
  the GC profile. Reproduce an inexplicably slow gate standalone with
  `KLIO_RECLAIM=arena` before blaming the harness.
- `pgrep -f`/`pkill -f` match the calling shell's own command line; put
  kill patterns in a script file and invoke it by path.
- `--watch -fincremental` is broken for this build graph (zig 0.16): the
  daemon reinstalls a Debug binary over `zig-out/bin`. Do not use it.
- `.zig-cache` has no GC; `scripts/prune-zig-cache.sh [days]` (default 2)
  is the local policy, safe at any time.
- CI runs the ReleaseSafe harness on 4 vCPU; child timeouts must sit at
  least 1.5 times above the slowest healthy local child, and shard
  weights are measured 4-core seconds divided by ten.
- When CI is red, `gh run view <id> --log-failed` names the failing
  suite and tests; reproduce with the matching census or suite locally
  before changing anything.
