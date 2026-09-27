# Cold start

A cold `klio run` is one whose base image is not in the cache: after the
interpreter is rebuilt (the image key carries the executable's stamp), after
the stdlib or a pack's sources change, or for a pack combination the cache has
not seen. The run then analyzes and lowers the base (the stdlib and the
program's declared packs) before the program, bakes what it produced to the
cache, and runs the program over it. A warm run reads the image and analyzes
and lowers only the program.

## The steps

`sema_cmd.loadSources` and `sema_run.buildRun` (`src/cli/sema_run.zig`) decide
which kind of run it is:

1. The base is named before any of it parses (`sema_base_cache.Key`): the
   binary, the image layout, the stdlib's and klio's actuals' texts, and the
   content hash and features of each pack the program selects. The cache path
   is `$KLIO_HOME/.klio/cache/sema-base-<key>.klio-sema`; a missing entry falls
   back to the copy the build installed under `share/klio/cache` beside the
   binary.
2. An image that reads back gives the run its base whole: the base's files
   join the source map with their lines only, and the program is analyzed,
   bridged and lowered over the base's sema, bridge and module
   (`pipeline.buildOnImage`). No base file parses.
3. With no usable image, the base parses, and `pipeline.bakeBase` analyzes and
   lowers it alone, encodes its sema, bridge and bodies
   (`src/lower_driver/base_image.zig`, `docs/design/SEMA-IMAGE.md`), writes the
   cache entry, and the run continues as in step 2 over the bytes it just
   baked.

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
