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

## Phase 1 result — golden emission MEASURED (2026-08-15)

Toolchain (session scratchpad): kotlinc 2.2.20 +
`kotlin-compose-compiler-plugin` 2.2.20 (the NON-embeddable artifact —
the embeddable one NoClassDefFoundErrors against the CLI compiler) +
`org.jetbrains.compose.runtime:runtime-desktop:1.8.2`. Probe gold1.kt:
`Leaf(n: Int, onClick: () -> Unit)` called as
`Leaf(1) { onCheckedChange(checked) }` from
`Probe(checked: Boolean, onCheckedChange: (Boolean) -> Unit)`.
javap -c of the emission:

- **Function prologue** (both fns): `$dirty = $changed;
  if ($changed & 0b110 == 0) $dirty |= changed(p0) ? 4 : 2;
  if ($changed & 0b110000 == 0) $dirty |= changedInstance(p1) ? 32 : 16`
  — 3 bits per param starting at bit 1; scalar params probe `changed`,
  reference params `changedInstance`.
- **Skip gate**: `composer.shouldExecute($dirty & 19 != 18, $dirty & 1)`
  — the compose-1.8 pausable-aware gate, NOT bare
  `skipping+skipToGroupEnd`; else-branch `skipToGroupEnd()`.
- **Memoized capturing lambda argument — THE ANSWER: ZERO key slots,
  ZERO groups.** The site emits
  `invalid = ($dirty & 112) == 32 || ($dirty & 14) == 4;
  v = rememberedValue();
  if (invalid || v === Empty) { v = <closure>; updateRememberedValue(v) }`
  — validity is READ OFF the enclosing `$dirty` for the captured
  PARAMS; only non-param captures would add inline
  `changedInstance(local)` probes (each consuming its own slot). One
  stored slot (the cache), no `startReplaceGroup` around the memo.
  klio's `remember(k1, k2) { lam }` wrap stores each key = the whole
  +6 slot excess.
- **Call-site certainty**: `Leaf(1, v, composer, 0b110)` — the literal
  arg carries caller-certainty bits; the memoized lambda passes 0 and
  the CALLEE's `changedInstance` (stable memo identity) resolves it to
  certain-same. Caller-side certainty for forwarded lambdas is NOT
  claimed by kotlinc — identity stability does the work.
- **Restart lambda**: `endRestartGroup()?.updateScope { F(args,
  composer, $changed | 1) }`.

## Landed (2026-08-15): checkboxLike 24 → 19 slots

- Per-param 3-bit `$dirty` triples (dirtyOrProbe/dirtySame/dirtyChanged,
  bit 0 = forced; receiver triple after the value params; index 9 =
  shared overflow). `$dirty = $changed` full copy; gate
  `($dirty and <forced+same-mask>) != <all-same> || !skipping` inside
  shouldExecute.
- Guarded probes: `if ($changed and (0b110 << 3i) == 0) { probe }` —
  a caller that claims certainty (constantly, per site) suppresses the
  callee's probe AND its slot.
- Call-site `$changed` bits at the LOWERING pair-completion
  (`composeChangedBits` in lower/expr.zig — P11 moved ordinary calls
  there; the AST pass's threadCall only serves value invocations, its
  `childChangedBits` covers those): literals → STATIC `0b110 << 3i`;
  a bare forward of a caller value param recombines the caller's live
  `$dirty` triple (`(($dirty shr 3j) and 6) shl 3i`), with exact
  named-arg mapping via the resolved callee signature
  (FuncBuilder.compose_value_params carries the caller's order);
  `$composer.cache(false, …)` args and lifted singletons are STATIC.
- Memo shapes by capture class: params-only captures →
  `$composer.cache(<$dirty terms>, calc)` (ZERO key slots); zero
  captures, empty body → LIFTED to a top-level singleton val
  (`$klio$memo$<key>`, pending_memo_lifts appended by the driver —
  kotlinc's static instance, zero slots); zero captures with a body →
  `cache(false, calc)` (identity permanent, one slot); local captures
  → the remember(keys) wrap (same slot count as changed-probes would
  be). Shadowing guards: local decls and inline-lambda params retire a
  param name from `$dirty` reuse (shadowed_triples).
- Verified: remember-family 26/26, funInterface_isMemoized, litmus
  45/45, sweep 117/0, module tests 21/21. checkboxLike counts 6 groups
  / 19 slots vs kotlinc's 8 / 18.

## ANCHOR GREEN (2026-08-15, 03e41d70)

checkboxLike PASSES slot-exact (<= 8 groups / <= 18 slots; campaign
start was 24 slots): the final two slots were forwarded DEFAULTED
params — the plugin renames them `p$arg` and the body reads the
prologue local `p`, but the triple is live either way (a taken default
sets the same-bit), so the forward recombination now matches by the
`$arg` suffix. GroupSizeValidationTests 5/5. Multi-hop certainty works
by construction (each hop recombines its own live `$dirty`).
Correction to the earlier tooling note: the nested CompositionGroup
surface is FINE (a scratch walk test traverses the full tree) — the
earlier dump crash was calling methods on raw value-class slot VALUES,
which is the separate known inline-class dispatch family. Slot-dump
recipe that works: walk `g.data` with a per-item try/catch
(scratchpad reprosrc/CheckboxSlotDumpTests.kt).

## Remaining (post-anchor polish, not blocking)

- `$default`-mask parity is approximated by the marker-default
  prologue + same-bit; kotlinc's static-bits-for-defaults differ in
  shape but not observed behavior.
- Value-class slot values crash `::class`/`toString` in tooling walks
  (the inline-class dispatch family) — recorded, separate.

## Phases

1. Golden measurement — DONE (result above).
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
