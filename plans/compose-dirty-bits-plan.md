# Compose skip-calculus: per-param $changed/$dirty bits

The campaign pinned open by `plans/open-campaigns.md` §2 (checkboxLike
slot anchor). Goal: replace the plugin's capture-keyed lambda memo
(`remember(k1, k2) { lam }`, one stored slot PER KEY) with kotlinc's
per-parameter changed/dirty bit calculus — zero key slots, one cache
slot — closing checkboxLike's +6 slot excess (klio 24 memo-on vs
kotlinc's 18) without breaking `funInterface_isMemoized` (memoized
identity must survive recompositions whose captures did not change).

## kotlinc's layout (reference emission)

Every `@Composable fun F(p0, p1, ...)` gets a trailing `$changed: Int`
(plus `$changed1` per 10 params). Per param, 3 bits + 1:

- bits `0b001` (STATIC): the argument is statically known certain —
  a literal, a singleton, a stable callable reference.
- bits `0b010` (CERTAIN/same): the caller KNOWS the value is the same
  as the previous composition (its own dirty analysis proved it).
- bits `0b100` (UNCERTAIN/different): the caller knows it changed.
- `0b000` = the caller knows nothing; the callee must `changed(p)`
  against its slot.

`$dirty` starts as `$changed`; for each unknown param the callee ORs in
`composer.changed(pN) ? 0b100 : 0b010` (shifted per index). The skip
gate is `if ($dirty and <mask> != <all-certain-same> || !skipping)
body else skipToGroupEnd()`. Restart lambdas re-invoke with
`$changed or 0b1` (forced).

Memoized lambdas: `composableLambda(composer, key, tracked)` stores ONE
slot; invalidation flows through the RestartableRenderer's scope, not
through stored keys. A non-composable captured lambda memo
(`remember { ... }` strong-skipping wrap) keys on captures — kotlinc
also emits `startReplaceGroup` + `rememberedValue/updateRememberedValue`
with the CHANGED BITS deciding validity, again no per-key slots: the
comparison happens against the live capture values via `changed()`
calls WITHOUT storing them (`changed` compares against the single
cached instance's captured fields? NO — kotlinc emits
`composer.changed(captureN)` per capture, and `changed` stores each
compared value in ITS OWN slot...). VERIFY with a golden dump before
building: `changedInstance` vs `changed` slot behavior on kotlinc
bytecode for the checkboxLike shape is the first measurement (the +6
may be 4 key slots + 2 group slots, not 6 key slots).

## Measurement anchors (all in tree today)

- checkboxLike slot dump: in-situ `CompositionGroup.data` print in
  `slotExpect` (recipe in memory klio-compose-plugin-triage (43));
  klio 24 slots memo-on / 21 memo-off vs kotlinc 18; groups 6 (fine).
- `funInterface_isMemoized`: identity stability gate — any calculus
  that over-invalidates fails it (measured: coarse single-bit does).
- Ratchet: compose_plugin_commontest baseline 1305, current ~1371.

## Phases

1. **Golden measurement.** Decompile kotlinc's checkboxLike-shaped
   output (Compose compiler plugin, strong skipping on) and write the
   exact slot-by-slot table klio must produce. Decide whether the memo
   wrap's key slots are the whole +6 or part group-shape.
2. **Thread $changed.** The plugin already appends the composer pair
   ($rc/$changed exist — restart lambdas re-invoke with `$changed or
   1`). Extend the compose_pass to compute caller-side certainty bits
   per argument (literal/singleton/stable-ref → STATIC; forwarded
   param whose own dirty bit is certain-same → CERTAIN) instead of
   always-unknown.
3. **Callee $dirty + skip gate.** Emit the per-param
   `if ($dirty and mask == same && skipping) skipToGroupEnd()` gate in
   restart-wrapped composables, replacing (or refining) the current
   skip emission. This is where the 24→18 slot drop lands: the memo
   wrap for capturing lambdas switches from `remember(keys){...}` to
   `changed(capture)`-driven updateRememberedValue with no key slots.
4. **Child-call masks.** Propagate certainty into nested composable
   calls (bit shifting per param index; `$changed or 1` on restart).
5. **Gates.** checkboxLike slot-exact (18), funInterface_isMemoized,
   remember-family 26/26 solo, full ratchet >= baseline, corpus
   compose family.

## Risks / recorded traps

- The engine pack re-lowers from source at load; every plugin emission
  change needs `scripts/install-local-packs.sh` (or census-home pack
  rebuild) before measuring — stale packs faked results twice before.
- Restart-wrap only REAL scope owners (65633c7b) — the gate emission
  must not widen wrap coverage.
- `KLIO_COMPOSE_MEMO=0` / `KLIO_COMPOSE_SKIP=0` bisect knobs must keep
  working (single-binary A/B).
- Closure interning at buildClosure is the companion road but UNSOUND
  naively (closures capture the creation-time receiver chain).
