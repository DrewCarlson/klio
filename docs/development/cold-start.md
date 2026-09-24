# Cold start

A cold `klio run` is one whose base image is not in the cache: after the
interpreter is rebuilt (the image key carries the executable's stamp), after
the stdlib or a pack's sources change, or for a pack combination the cache has
not seen. The run then analyzes and lowers the base (the stdlib and the
program's declared packs) before the program, bakes what it produced to the
cache, and runs the program over it. A warm run reads the image and analyzes
and lowers only the program.

## The steps

`sema_run.buildRun` (`src/cli/sema_run.zig`) decides which kind of run it is:

1. The cache path is `$KLIO_HOME/.klio/cache/sema-base-<key>.klio-sema`, keyed
   by the binary and every base file's path and text
   (`src/cli/sema_base_cache.zig`). A missing entry falls back to the copy the
   build installed under `share/klio/cache` beside the binary.
2. An image that reads back is extended with the program
   (`pipeline.buildOnBase`): sema analyzes the program's files over the base's
   symbols, the bridge extends the base's, and only the program's bodies lower.
3. With no usable image, `pipeline.bakeBase` analyzes and lowers the base
   alone, encodes its bridge and bodies (`src/lower_driver/base_image.zig`),
   writes the cache entry, and the run continues as in step 2 over the bytes it
   just baked. An image of another base, or of an older format, bakes afresh
   the same way.

`klio bake` fills the cache without running anything; `klio bake-image`
writes a self-contained image (`src/cli/sema_image.zig`) that also carries the
base's sources, which `klio run-image` and bundles boot from.

## Measuring

`KLIO_SEMA_TIMING=1` prints the milliseconds of each step (load and parse,
collect, headers, bodies, records, bridge, lowering, the bake, execution);
`KLIO_TRACE_RUN=1` adds the run's own steps. Run against a fresh data home and
with the shipped image ignored, or the run is a warm one:

```sh
rm -rf /tmp/klio-cold && KLIO_HOME=/tmp/klio-cold KLIO_STDLIB_IMAGE_SHIPPED=0 \
  KLIO_SEMA_TIMING=1 ./zig-out/bin/klio run hello.kt
```

`KLIO_SEMA_IMAGE=0` turns the cache off, so every run analyzes and lowers the
base; comparing a run with it against a warm run separates the base's cost
from the program's.

The default `zig build` produces a Debug binary, whose numbers are two to three
times a ReleaseSafe or ReleaseFast build's; time a release build for anything
you report.
