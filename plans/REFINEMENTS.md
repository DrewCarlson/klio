# Refinements & follow-on work

Tracking the punch list called out after the pack-system + kotlinx +
ktor-client round. Updated as items land. Uncommitted (lives under
`plans/`).

Legend: `[ ]` pending · `[~]` in progress · `[x]` done · `[-]` deferred / out of scope this pass

## Pack system gaps

- [x] mmap-backed `PackReader` (`memmap2`) — `from_path_mmap`; CLI uses it with bytes fallback. Workspace lint relaxed to `deny` so klio-pack alone can `allow(unsafe_code)`.
- [x] Pack-cache sidecar index (`~/.klio/packs/index.json`) — install/remove regenerate; loader uses fast path.
- [x] `klio pack migrate <old> <new>` — passthrough round-trip today; in place for v2.
- [ ] Dictionary-trained zstd across stdlib + kotlinx packs.
- [ ] Frozen `resolved` + `typeck` sections (Phase 7 ships AST only; resolver/typeck recomputes per load).

## Interp / language fixes

- [x] Companion-object eager init bug: `class { companion { val X = Outer() } }` works — companion now constructed AFTER outer class is bound to env. (ClassDef.companion moved to RefCell<Option>; build_class_shell defers construction.)
- [ ] Getter-only companion property resolves to `Nothing` at typeck. (`M.Get` where Get is `val get() = M(...)`.) Separate typeck investigation; eager-val form is the working idiom.
- [-] Pack-source file load order: cross-file forward refs work in practice — property initializers fire at instantiation, not registration. Deferred unless a real case surfaces.
- [ ] Unify top-level binding shadow with member/extension binding paths (currently distinct lookups).

## kotlinx coverage

- [x] `kotlinx.io`: `Buffer.size` is a property; `Source` / `Sink` interfaces added (Buffer implements both); codec coverage beyond UTF-8/BE primitives remains deferred (base64/hex/varint not yet worth backporting).
- [-] `kotlinx.coroutines`: real scheduler / `select` / structured concurrency / cancellation. (M31 in PLAN; deferred — full coroutine runtime is its own milestone.)
- [x] `kotlinx.datetime`: `DateTimePeriod` (calendar-aware months/days via chrono::Months) + `Instant.plusPeriod`/`minusPeriod`; Int/Long extension properties (`.hours`, `.minutes`, `.days`, …). `DateTimeUnit` deferred (DateTimePeriod covers most use cases).
- [-] `kotlinx.atomicfu`: fence semantics. (Single-threaded interp; no observable difference. Keep deferred.)

## ktor-client

- [-] Streaming body — kotlinx.io has Source/Sink interfaces now, but ureq can't stream-write request bodies; deferred until reqwest/hyper path lands.
- [x] Request DSL — `getWith`/`postWith`/`requestWith` accept a builder lambda.
- [-] TLS configuration knobs (custom roots, pinning) — ureq's TLS is rustls-defaults today; configurable agent surface deferred.
- [x] Engine plugin slot — documented: register a competing `__kktor_request` binding after `klio_ktor_client::host_bindings()` in `merged_host_bindings`. Last write wins.

## Boilerplate

- [x] `klio_stdlib::host_bindings!` declarative macro — used by atomicfu, io, datetime, coroutines, ktor-client.
- [x] Auto-emit `[bindings]` table at pack-build time. klio.toml `[library] auto_bindings = true` (with optional `binding_auto_prefixes`) tells the pack builder to pull every host_symbol from the merged HostBindings registry whose FQN starts with the library id (or a custom prefix). All five shipped packs now use it; klio.toml dropped from ~25 LOC to 8 LOC.
- [-] Publish / registry — explicitly deferred this round.

## Interpreter → IR

Biggest item. Replace tree-walking with a compact IR + a switch-based
evaluator.

- [x] Define `klio-ir` crate: `Inst`, `BinOp`/`UnOp`, `Block`/`Terminator`, `Func`/`Param`, `Class`, `Module`, `Const` pool with intern + dedup. Uses `TypeRef` (textual) until `klio-types::Type` gains serde derives.
- [~] AST → IR lowering pass. Slice 1 (literals, BinOp, UnOp, If, Block, Return, Throw) and Slice 2 (scope stack, Path resolution, StringTemplate, While, DoWhile, bind_params helper) landed. Remaining: Member/Call (slice 3), break/continue/for-in/try/when (slice 4), Lambda/AnonFun/ObjectExpr (slice 5), val/var bindings + property assignment (slice 6), class/object dispatch (slice 7).
- [~] IR-driven evaluator running on `Vec<Inst>`. Minimum-viable slice landed: handles Const / Move / Not / UnOp / BinOp / Trace + Goto / Branch / Switch / Return / Throw / Unreachable. Unsupported ops trap clearly so the evaluator grows alongside the lowering pass.
- [ ] Migrate `klio-interp` consumers to the new evaluator behind a `--ir` feature flag; flip default once parity holds.
- [ ] Drop dead tree-walking code paths after one release.

## Session log (rolling)

This session's commits (in order):

1. `klio-pack: mmap-backed PackReader`
2. `klio-cli: pack-cache sidecar index + klio pack migrate`
3. `klio-stdlib: host_bindings! macro + adopt across kotlinx crates`
4. `interp: defer companion-object construction until outer class is bound`
5. `kotlinx-io: Buffer.size as property + Source/Sink interfaces`
6. `kotlinx-datetime: DateTimePeriod + Int/Long Duration extension properties`
7. `klio-ktor-client: DSL builder lambdas + document engine plugin slot`
8. `klio-ir: scaffold linear IR crate`
9. `klio-ir: FuncBuilder + first expression-lowering slice`
10. `klio-ir: minimum-viable evaluator over the lowered Inst subset`
11. `klio-ir: lowering slice 2 — scope stack, paths, strings, loops`
12. `klio-ir: lowering slice 3 — Member access + Call dispatch`
13. `klio-ir: statement lowering — val/var decls + assignments`
14. `klio-ir: lower::lower_function — AST Function -> IR Func`

## Remaining IR work (multi-session)

The IR rewrite is genuinely months of work. Roadmap from here:

- **Slice 4 — control flow.** `for`-in (iterator-desugared), `try`/`catch`/`finally`,
  `break`/`continue` with labelled targets, `when` (with subject + bare).
- **Slice 5 — closures & objects.** `Lambda` (capture env), `AnonFun`,
  `ObjectExpr`, `is` / `as` / `as?` / `!!`.
- **Slice 6 — class & dispatch.** `NewInstance` against a class table,
  method tables, companion lookup, virtual / super dispatch.
- **Evaluator parity.** Each new Inst variant gets a match arm in
  `eval::exec_inst`; cross-check against `klio-interp` results on
  the parity corpus.
- **Cutover.** Behind `--ir-eval` until the corpus is byte-identical
  through the IR. Flip default; remove dead tree-walking paths.

## Tracking doc maintenance

- This file lives under `plans/` (uncommitted) per CLAUDE.md.
- Update each item on landing; do not delete completed entries — flip the marker.
