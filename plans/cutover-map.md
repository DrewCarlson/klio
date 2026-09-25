# Deleting the name-resolving pipeline

`klio run` and `klio test` run the sema pipeline by default
(`--legacy-pipeline` / `KLIO_SEMA_PIPELINE=0` select the old one while it is
deleted). This is the map of what the old pipeline still carries, what must be
ported or migrated before it goes, and the order of the deletion. Items and
sizes follow `plans/resolved-interpreter.md` (`cut/switch`, `cut/backends`,
`cut/objects`, `cut/runtime`, `retire/typeck`, `engine/one`).

The new lowering (`src/ir/lower/sema`) imports nothing from the old lowering.
It emits only resolved variants and the shared simple ones; never
`NonLocalReturn`, `LabeledReturn`, `TailJump`, `TailCallFunc` or a by-name
variant.

## Gaps on the default path

Regressions the switch made visible. Each is fixed before the deletion.

1. Parse and lex errors are never reported: `sema_cmd.addSource` drops
   `lexed.diagnostics` and `p.diagnostics`; the old path rendered them and
   exited 1 (`commands.zig:251-261`).
2. A project running its own sources with its pack installed declares
   everything twice: `sema_cmd.loadSources` passes neither
   `exclude_lib_ids` nor `declared_lib_ids`, and `report_failures = false`
   skips an undecodable pack silently.
3. Hosted UI (mobile): `pipeline.execute` deinits the VM and `sema_run.run`
   frees its arena, while `compose_ui.hostedActive()` needs both alive
   (`commands.zig:3882-3926` kept them).
4. `pipeline.execute` never sets `vm.program_args` (run-image and bundles
   need it).
5. `KLIO_PROF`, the op/fn profiles, frame counts, `runstats`,
   `KLIO_TRACE_RUN`, `KLIO_PUMP_DIAG` are wired only into the old run path
   (`commands.zig:241-247, 3943-3968, 3408-3440, 4160-4168`); wire the ones
   that are not about by-name dispatch into `sema_run`/`sema_test`, or
   remove them from `docs/development/debugging.md`.
6. `--lazy-bodies` does nothing on the new path; keep it accepted as a
   documented no-op (the base image subsumes it).

## Commands

| Command | Today | Work |
|---|---|---|
| `run`, `test` (all modes) | sema | delete the legacy branches; move the shared helpers out of `commands.zig` (`TestFormat`, `printTestReport`, `runTestsIsolated`, `runTestGroups`) |
| `check` | resolver + typeck | stays until `retire/typeck`, then over sema's diagnostics |
| `lex`, `parse`, `repl`, `sema`, `pack *`, `ide` | shared | move out of `commands.zig` where they live there; `pack build` writes a `typeck` section nothing reads (drop it in `retire/typeck`) |
| `dump-ir`, `transpile-dump` | old only | port: build through `sema_cmd.loadSources` + `sema_run.buildRun`, dump `br.m` |
| `bake`, `bake-image`, `bake-image --stdlib-cache` (run by every `zig build` install, `build.zig:746-766`), `run-image` | old only | port onto a self-contained sema image (below) |
| `bundle`, bundle boot (`bundle_boot.zig`) | old only in the program part | port: payload = sema image + base pack sources + program sources; bump the payload format (`bundle_boot.zig:180`) |
| `transpile` (launcher) and `klio_rt` | old only | port with the backends: `klio_rt` boots the sema image |
| `transpile --native` (cgen, `src/cli/cgen*`, 9.5k) | old only; handles only by-name variants | port cgen over resolved IR and the bridge's layouts; acceptance is `scripts/native-c-check.sh` |
| `KLIO_LEAVES` leaf library | old leaf tier only | delete with the leaf tier |

**A self-contained sema image.** `lower_driver/base_image.zig` holds no source
text; a run re-parses the base sources and checks the digest. `bake-image`,
`run-image`, bundles and transpiled binaries need one artifact holding the base
image bytes, the selected packs' sources (or frozen AST sections) and the
feature selection, with `loadSources` taking an injectable pack provider rather
than reading `KLIO_HOME`. About +250 lines, shared by those four ports.

## Tests and gates

| Suites | Old entry | Work |
|---|---|---|
| `e2e` | done: spawns the harness over a scratch home with every pack installed | extract its child runner for the rest |
| 26 `parity_*` suites (groups `group_parity_core/types/shapes`), `parity_corpus_pinned` (733 tests) | `parity.runWithPacks` / `runFilesWithPacks` | migrate onto the child runner (`src/itests/klio_child.zig`, from `e2e.zig`); mark `needs_exe`, drop `parity_data`; programs and expected output unchanged |
| `parity_threaded_litmus` | `runWithPacks`; an eager-parity test over `dump-ir` + `KLIO_EAGER` | migrate the runner; delete the eager-parity test with the typeck bridge |
| `resolve_ambiguity` (31) | `runFilesWithPacks`, `setResolveStrictForTest` | migrate the runner; its diagnostic needles come from sema's rendered errors |
| `annotation_targets`, `context_parameters`, `explicit_backing_fields` | typeck diagnostics + `runWithPacks` (+ `interp_ir.build` anchor records) | run halves onto the child; diagnostic halves stay until `retire/typeck`; anchors become sema annotation-target tests |
| `check_examples` | `parity.loadProgram` + resolver + typeck | spawn `klio check <file>` |
| `differential`, `fuzz_closures_suspend` | SourcePacks vs CompiledPacks | axis becomes base-image build vs cold build (`KLIO_SEMA_IMAGE=0`) |
| `stdlib_image` (9) | the old `.klio-image` cache; already red on the default path | retarget to `sema-base-*.klio-sema` and `KLIO_SEMA_IMAGE`; the in-process round trips move to `lower_driver/tests/image.zig` |
| `bench` module | `buildModule`, `Vm.fromBuilt`, resolver/typeck stages | stages become sema's (headers, bodies, records, bridge, lower); `runFull` spawns the harness |
| `typeck_negative`, `cfa_builder`, `cfa_smartcast` | typeck / cfa | stay until `retire/typeck` |
| `bundle_smoke`, `bundle_cross`, `bundle_ui` | black box over the old boot | validate the bundle port; reframe "program-image is the default entry" |
| every `*_commontest`, `klio-census`, box, ktor/concurrency itests | spawn `klio` | already on the sema pipeline; re-measure against the floors |

Install packs once into a shared, tree-keyed test home as a build step the
child suites depend on, rather than per suite.

Gate scripts: `scripts/gate.sh`'s litmus phase moves with the suites; its
ratchet phase is replaced by the name guard and a `klio sema --each`
census-zero step; drop `--eager both`. `scripts/quick-gate.sh`'s census phase
becomes the sema census. The by-name audit scripts (the site and dispatch
censuses, the Or-arm and emit audits) and the resolution ceiling have gone
with the by-name variants.

## Order of the deletion

1. **Ports and migrations**, three streams while `--legacy-pipeline` still
   exists so any regression A/Bs in one binary:
   - tests onto the child runner (then `src/parity` and its `build.zig` wiring
     go, keeping the kotlinc helpers in `src/itests/kotlinc_support.zig`);
   - command ports, the gaps above, the self-contained sema image;
   - backends over resolved IR (cgen, the transpile launcher, `klio_rt`).
2. **The old front end** (~89k): `src/ir/lower/**` outside `sema`,
   `src/ir/build.zig`, `src/interp_ir/build*`, old `image.zig` (keep its codec,
   which `base_image.zig` uses), `prune.zig`, `src/compose_pass`,
   `ast/alias_expand.zig` + `annotation_targets.zig`, `cli/stdlib_image.zig`,
   the old run/test/eager paths in `commands.zig`, the typeck bridge
   (`ir.zig:144-211`, `eagerTypeOf`), the run-time lowering in
   `host_classes.zig` and `host_instances/build_object.zig` with the
   `AstLambda`/`RegisterClass`/`BuildObject` variants, old `vm/run.zig` and
   `ProgramImage.linkResolvedForms`, old test discovery, and the legacy flags.
3. **The by-name variants** (~12k) and the name guard: their payloads and
   arms (`inst.zig`, `exec_call.zig`), `chain.zig`, `leaf.zig`,
   `compose_fast.zig`, `snapshot_fast.zig`, `site_census.zig`, the JIT's
   member/virtual/field site resolvers; `FORMAT_VERSION` bumps.
4. **`cut/objects` + `cut/runtime`** (−35-45k): the by-name runtime ladders
   (`host_call_member/*`, `host_fields/*`, `host_instances/*`, the by-name
   `ir/core` modules, `applicability`), once instances, vtables and natives
   are addressed by id.
5. **`retire/typeck`** (−29k), independent of 4: `klio check` over sema.
6. **`engine/one`** (−5k).

## Couplings to cut first

- `lower_driver/base_image.zig` uses `interp_ir.image`'s codec.
- Types the live VM uses are defined in old files: `interp_ir/build/types.zig`
  (`ClassTable`, `NameFunc`, …), `exec_call` helpers used by
  `eval/resolved.zig`, `ensureFuncBody` in `module_lookup.zig`, `FuncBuilder`
  in `ir/build.zig` (tests).
- The new path still reaches the by-name runtime: `host_resolved.callNative`
  ends in `dispatchIntrinsic` by name, `callHostMember` in the member ladder,
  `pipeline.execute` renders an uncaught throwable through
  `callMethod(..., "toString")`. New behaviour goes into `host_resolved` and
  the well-known slot tables, never into a ladder.
- `ast.expandFileClassAliases` runs in the shared pack loader and pack build;
  removing it changes sema's input and needs a pack rebuild.
- The default `zig build` install runs the old `bake-image --stdlib-cache`.
