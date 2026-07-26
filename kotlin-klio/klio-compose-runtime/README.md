# klio-compose-runtime (submodule host)

This directory exists only to host the `upstream/` sparse git submodule
(compose-multiplatform-core), which supplies:

- the curated `androidx.compose.runtime` sources the
  `klio-compose-runtime-engine` pack consumes (see its `klio.toml`
  source roots pointing at `../klio-compose-runtime/upstream/...`), and
- the compose-runtime commonTest / nonEmulatorCommonTest / test-utils
  sources the compose itest, `scripts/compose-test.sh`, and
  `scripts/compose-fleet.py` compile.

It is NOT a pack: the installable `androidx.compose.runtime.klio-pack`
builds from `kotlin-klio/klio-compose-runtime-engine`. A `klio.toml`
here once defined a parallel pack with the same id that built a broken
artifact (missing the engine layer — `unresolved global SlotTable` at
run time); it was removed so the wrong directory can no longer be built
into a pack at all.
