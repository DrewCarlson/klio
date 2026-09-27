# Compose UI benchmarks

Eight Compose programs run on klio and on Compose Desktop (the JVM), for frame
cost, frame rate, idle CPU, launch time and memory. The same Kotlin source runs
unchanged on both.

| Program | What it does |
|---|---|
| `hb_list` | A 5,000-row `LazyColumn` scrolled 23 px every frame |
| `hb_recompose` | 300 `BasicText`s whose text changes every frame |
| `hb_canvas` | 2,000 circles moving on a `Canvas` |
| `hb_form` | A 40-row form of text fields and toggles, then idle frames |
| `wb_idle` | A window with nothing to do for 10 s |
| `wb_anim` | A window animating for 10 s |
| `wb_churn` | A second window opened and closed 150 times |
| `wb_long` | A window scrolling a list up and down for 45 s |

The `hb_` programs are headless scenes (`KlioComposeScene` on klio,
`ImageComposeScene` on the JVM), each frame advancing a virtual 16.67 ms clock,
and print their own frame timings: 60 warm-up frames, then 300 timed ones. The
`wb_` programs open real windows, drive themselves with no input and close.

## Running

```sh
zig build klio-harness-fast          # the ReleaseFast binary the runs use
bench/compose/run.py                 # every program, klio and the JVM, 3 rounds
```

The runs alternate between klio and the JVM, round by round. The results go
to `target/bench-compose/<time>.json`, and the summary is printed at the end:

```
program       metric                klio   jvm  klio/jvm
hb_list       frame ms (mean)       3.03  0.90      3.4x
              frame ms (p95)        4.19  1.52      2.8x
              first composition ms  42.3   154      0.3x
              peak footprint MB      158   493      0.3x
```

| Flag | |
|---|---|
| `--only hb_list,wb_anim` | Just these programs |
| `--rounds 1` | One round instead of three |
| `--no-jvm`, `--no-klio` | One side only |
| `--klio BIN` | Another klio binary (default `zig-out/bin/klio-harness-fast`) |
| `--home DIR` | Its `KLIO_HOME` (default `.klio-local`, the repo's local packs) |
| `--env K=V` | An environment variable for the klio runs, e.g. `KLIO_GC_DEBUG=1` |
| `--no-warm` | Skip the untimed first run per program |
| `--out FILE` | Where the results go |

To compare two klio builds, run the JVM once with the first and klio alone
with the second, then summarize the second against the first. The JVM numbers
come from the baseline:

```sh
bench/compose/run.py --out target/bench-compose/before.json
# ...change klio, zig build klio-harness-fast...
bench/compose/run.py --no-jvm --out target/bench-compose/after.json
bench/compose/summarize.py target/bench-compose/after.json --baseline target/bench-compose/before.json
```

A single program by hand, to watch its output:

```sh
KLIO_HOME=$PWD/.klio-local zig-out/bin/klio-harness-fast run bench/compose/programs/hb_recompose.kt
```

## What the numbers are

- **Frame times** are the median, across rounds, of each run's own mean and
  p95. **First composition** is `setContent` to the first frame.
- **Launch** is the time from spawning the process to the program printing its
  first frame.
- **CPU per frame** is the run's whole CPU time over its frames, startup
  included.
- **Idle CPU** runs from 3 s after the first frame to the end of the idle run,
  sampled from `ps`.
- **Peak footprint and RSS** come from `/usr/bin/time`, as the highest of any
  round. On Linux GNU `time -v` reports only RSS, which stands in for both.

## Before trusting a number

- **Warm-up run.** A klio binary's first run of a program bakes that program's
  image: about two seconds and 2 GB. The runner does this untimed before the
  rounds unless `--no-warm` is given; a program run by hand needs the same.
- **Nothing else building.** Timings on a machine running a build or the gate
  are not comparable. The window programs need a logged-in desktop session.
- **JVM side.** It builds each program with the pinned kotlinc and the Compose
  plugin through `scripts/compose-oracle.py`, into
  `target/bench-compose/jvm`, and fetches Compose Desktop's jars on first use.
- **Differences worth recording.** A difference under a few percent between
  two runs is noise; alternate the builds and run three rounds before recording
  one.
