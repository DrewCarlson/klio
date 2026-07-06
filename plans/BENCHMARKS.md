# Benchmarks

KLIO ships a continuous benchmark harness that times every stage of the pipeline (`lex → parse → resolve → typeck → interp`) plus end-to-end runs, on both **wall time** and (opt-in) **heap allocation traffic**. The goal is to make every performance- or memory-shaped change measurable in numbers before and after the diff, so optimization work targets real bottlenecks rather than guesses.

## Layout

```
crates/klio-bench/                # driver + shared plumbing + corpus
  src/lib.rs                      # stage runners, timing, JSON schema
  src/refrunner.rs                # kotlinc-native + kotlinc-jvm (auto-installed)
  src/bin/klio-bench.rs           # driver binary: emits JSON, can diff baselines
  benches/e2e_pipeline.rs         # criterion: full pipeline across corpus
  benches/runtime_micro.rs        # criterion: synthetic runtime micros
  benches/memory_profile.rs       # criterion + dhat: allocation workloads
  corpus/{micro,macro,game,stress}/*.kt
crates/klio-lexer/benches/lex.rs
crates/klio-parser/benches/parse.rs
crates/klio-resolver/benches/resolve.rs
crates/klio-typeck/benches/typeck.rs
crates/klio-interp/benches/eval.rs
crates/klio-stdlib/benches/intrinsics.rs
benches-baseline/HEAD.json        # checked-in baseline (numbers from main)
```

## Running

Fast end-to-end pass (used in CI on every PR):

```sh
cargo run --release -p klio-bench -- --json --out current.json
```

Full pass with longer budgets:

```sh
cargo run --release -p klio-bench -- --full --json --out current.json
```

Filter to one workload while iterating:

```sh
cargo run --release -p klio-bench -- --filter game/entity_tick
```

Per-stage criterion benches:

```sh
cargo bench -p klio-lexer
cargo bench -p klio-parser
cargo bench -p klio-resolver
cargo bench -p klio-typeck
cargo bench -p klio-interp
cargo bench -p klio-stdlib
cargo bench -p klio-bench --bench e2e_pipeline
cargo bench -p klio-bench --bench runtime_micro
```

## Memory profiling (dhat)

Heap allocation count + max-live bytes:

```sh
cargo run --release -p klio-bench --features dhat -- --filter game/
# produces dhat-heap.json in cwd; load it at https://nnethercote.github.io/dh_view/dh_view.html
```

The bench memory profile is also runnable as a criterion bench:

```sh
cargo bench -p klio-bench --bench memory_profile --features dhat
```

## Reference runners (`--features ref`)

End-to-end runs can be compared to the official Kotlin compilers. Both are auto-downloaded on first use; **neither is assumed on `PATH`**.

- `kotlinc-native` 2.4.0 — extracted under `~/.konan/` (managed by `klio-parity`).
- `kotlinc` JVM 2.4.0 — extracted under `target/bench-cache/kotlinc-2.4.0/`. The JVM runner additionally needs a `java` binary; the bench harness looks at `JAVA_HOME` then `PATH` and reports `NoJava` if neither is available.

```sh
cargo run --release -p klio-bench --features ref -- --full --json --out current.json
```

Per-workload records gain `ref_kotlinc_native_ns` and `ref_kotlinc_jvm_ns` when populated.

## Baselines & regression diff

A checked-in baseline at `benches-baseline/HEAD.json` represents `main`'s numbers on the contributor's hardware that last touched it. Hardware variability is unavoidable; the diff is most meaningful when re-run on the same machine.

```sh
cargo run --release -p klio-bench -- --json --out current.json --diff benches-baseline/HEAD.json
```

Per-row regression thresholds (median wall time, current / baseline):

| Ratio       | Level    |
|-------------|----------|
| `< 1.05`    | green    |
| `1.05–1.15` | yellow   |
| `≥ 1.15`    | red      |

The driver exits non-zero when any row is red.

To refresh the baseline (after a deliberate perf change has landed):

```sh
cargo run --release -p klio-bench -- --json --out benches-baseline/HEAD.json
git add benches-baseline/HEAD.json
git commit -m "bench: refresh baseline"
```

## Reading the schema

```json
{
  "git_sha": "abcd123",
  "host": "macos-aarch64",
  "records": [
    {
      "stage": "e2e",                 // lex | parse | resolve | typeck | e2e
      "workload": "game/entity_tick",
      "median_ns": 14000000,
      "p99_ns": 15200000,
      "iters": 12,
      "allocs": 42018,                // present only when dhat is on
      "alloc_bytes": 1284911,
      "ref_kotlinc_native_ns": 31000000,
      "ref_kotlinc_jvm_ns": 940000000
    }
  ]
}
```

## What we measure, and why each thing matters

- **Lexer / parser / resolver / typeck stages** — attribution. When end-to-end regresses, the per-stage rows say which stage moved.
- **Interpreter (`eval`) stage** — the hot path. Tree-walking cost dominates almost every program once parsing settles.
- **`runtime_micro`** — synthetic hot loops that magnify a single concern (arith, lambda call, dispatch, templating, list churn). Each maps onto one optimization dial in `klio-interp` / `klio-runtime`.
- **Game corpus** — entity tick, behavior tree, event bus. These shape decisions for long-running scripts where steady-state allocation, dispatch overhead, and `Value` size dominate.
- **Stress corpus** — deep nesting, wide decls, allocation churn. Catches super-linear blowups in the static stages and pathological heap shapes in the runtime.
- **`Value` size pinned test** in `klio-bench` library tests — the tree-walker's cost scales with `size_of::<Value>()`. A red number on that single test usually outweighs whatever convenience justified the new variant.

## Known shallow areas

- **Reference comparison** depends on a working JDK on the bench host for the JVM runner; CI uses `actions/setup-java@v4`. Local first runs incur a one-time ~80 MB download.
- **Allocator** is the system allocator; we intentionally do not pin `mimalloc` for benches because honest numbers matter more to embedders than peak throughput. Switch only after an explicit decision.
- **Peak RSS** is not sampled in the default path; dhat covers the heap side authoritatively and a process-level RSS sampler is on the to-do list once we have a tool that doesn't require new `unsafe`-bearing deps.
