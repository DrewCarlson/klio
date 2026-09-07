# Benchmarks

KLIO ships a benchmark harness (`src/bench/`) that times every stage of the pipeline (`lex → parse → resolve → typeck → e2e`) plus end-to-end runs. The goal is to make every performance- or memory-shaped change measurable in numbers before and after the diff, so optimization work targets real bottlenecks rather than guesses.

## Layout

```
src/bench/
  bench.zig               corpus loader, per-stage pipeline runners, timing
  main.zig                driver: emits JSON, can diff against a baseline
  refrunner.zig           kotlinc-native + kotlinc-jvm reference runners
  schema.zig              stable JSON schema + regression classification
tests/fixtures/bench_corpus/{micro,macro,game,stress}/*.kt
benches-baseline/HEAD.json    checked-in baseline (numbers from main)
```

## Running

The bench module runs as a program-running suite through the build
system (it rides the integration tier, not the fast unit step):

```sh
zig build itest-bench
```

The driver surface (`bench.main.run`) supports `--full` (extended
budgets), `--json`, `--out <file>`, `--filter <workload>`, and
`--diff <baseline.json>`; a standalone installed `klio-bench` binary
is a follow-up (see `.github/workflows/bench.yml` — benchmarking is
manual for now, and the workflow keeps the module compiling).

## Reference runners

End-to-end runs can be compared to the official Kotlin compilers
through `refrunner.zig`. Compiled artifacts are cached under
`target/bench-cache/` keyed by source-content hash, so repeated
passes don't recompile. The JVM runner needs a `java`; per-workload
records gain `ref_kotlinc_native_ns` / `ref_kotlinc_jvm_ns` when
populated.

## Baselines & regression diff

A checked-in baseline at `benches-baseline/HEAD.json` represents
`main`'s numbers on the hardware that last touched it. Hardware
variability is unavoidable; a diff is most meaningful when re-run on
the same machine. Per-row regression thresholds (median wall time,
current / baseline), from `schema.zig`:

| Ratio       | Level    |
|-------------|----------|
| `< 1.05`    | green    |
| `1.05–1.15` | yellow   |
| `≥ 1.15`    | red      |

The diff path exits non-zero when any row is red.

## Reading the schema

```json
{
  "git_sha": "abcd123",
  "host": "macos-aarch64",
  "records": [
    {
      "stage": "e2e",
      "workload": "game/entity_tick",
      "median_ns": 14000000,
      "p99_ns": 15200000,
      "iters": 12,
      "allocs": 42018,
      "alloc_bytes": 1284911,
      "ref_kotlinc_native_ns": 31000000,
      "ref_kotlinc_jvm_ns": 940000000
    }
  ]
}
```

Optional fields are omitted when absent.

## What we measure, and why each thing matters

- **Lexer / parser / resolver / typeck stages** — attribution. When end-to-end regresses, the per-stage rows say which stage moved.
- **End-to-end (`e2e`) stage** — the hot path: lowering plus Vm execution, the cost a user actually pays.
- **Game corpus** — entity tick, behavior tree, event bus. These shape decisions for long-running scripts where steady-state allocation, dispatch overhead, and `Value` size dominate.
- **Stress corpus** — deep nesting, wide decls, allocation churn. Catches super-linear blowups in the static stages and pathological heap shapes in the runtime.
- **`Value` size pinned test** (`value_size_is_pinned` in `bench.zig`) — the Vm's cost scales with `@sizeOf(runtime.Value)`; the test fails if a new variant inflates it past 64 bytes.

Deeper performance campaigns are recorded in
`CPU-EFFICIENCY-CAMPAIGN.md`, `MEMORY-PARITY-CAMPAIGN.md`, and
`JIT-DESIGN.md`.
