# Resolution residue campaign — running plan

Scope: the two exact-semantics defects the CI campaign surfaced in
passing (both reproduce on `main` before that work; neither is covered by
a gate today), plus the one scoping limitation the context-parameter fix
left recorded. Root-cause only; every fix ships an example under
`examples/` with `tests/corpus/expected/<name>.out` and a README row.
Verify with the harness + sweep playbook (`verification-speed-plan.md`),
full battery once at the end (`scripts/stack.sh`).

Parent plan: `green-main-backlog.md`.

## Task 1 — bare factory call vs value-class constructor

Repro (fails on `main`, `runtime error: IR eval: ULong constructor
requires an integer`):

```kotlin
@JvmInline
value class Color(val value: ULong) {
    companion object { val Red = Color(0xFFFF0000) }
}
fun Color(color: Long): Color = Color(value = (color.toULong() and 0xffffffffUL) shl 32)
fun main() { println(Color.Red.value) }
```

kotlinc resolves `Color(0xFFFF0000)` among the constructor and the
same-named functions by argument type: the literal is a `Long`, the
constructor takes `ULong`, so `fun Color(Long)` wins. klio's
`bare_ctor_shadowed_by_class` arm (`KLIO_OR_AUDIT=1` names it: `emit
site=bare_ctor_shadowed_by_class inst=NewInstance name=Color recvctx=1
recv=Color$Companion$Companion`) commits to `NewInstance` when the call
sits inside the class's own companion, while the same call from `main`
takes `class_or_factory_call` / `type_overload_deferred` and the runtime
overload choice picks the factory. The compose graphics pack only works
because its `Color.Red` initializer happens to take the deferred route.

Fix shape: the ctor arm must not commit when same-named function
candidates exist (`cmgCandidates` non-empty) and the argument's static
type cannot be the constructor's parameter type; defer to the runtime
choice exactly as the top-level site does. Do NOT re-type the literal at
the call site (the CI campaign tried and reverted that: it made the
runtime choice see a `ULong`; see `ci-green.md` "constructor literal
typing").

Example: `examples/value_class_factory_over_ctor.kt`.

- [ ] root fix in the ctor arm
- [ ] example + `.out` + README row
- [ ] the compose graphics pack's `Color` initializers still resolve
      (in-process e2e `compose_paint`, `compose_colorspace`)

## Task 2 — Char ranges expose Int endpoints

Repro: `println(('a'..'c').toString())` prints `97..99`; kotlinc prints
`a..c`. `('a'..'c').first` is an `Int`. Yet `CharRange.EMPTY.toString()`
(built through `CharRange(1.toChar(), 0.toChar())`) renders its two
control characters correctly, so the defect is in `Char.rangeTo` (the
range value built for a char operand carries the Int kind) rather than
in the `CharRange` class. Check `CharProgression` (`'a'..'e' step 2`),
`downTo`, `until`, `reversed()`, iteration element type (`for (c in
'a'..'c') println(c is Char)`), and `contains`.

Example: `examples/char_range_endpoints.kt`.

- [ ] root fix in the char range construction / `first`/`last` kind
- [ ] example + `.out` + README row
- [ ] stdlib `ranges/RangeIterationTest.kt` and `RangeTest.kt` still
      green (sweep `--filter Range`)

## Task 3 — implicit context arguments through nested subjects

The context-parameter fix (`kotlin24-context-parameters.md`, CI campaign
Task 6) resolves an implicit call's context arguments from the innermost
spliced subject, then the declaration's own receiver, else `CtxLoad`
(which also walks the runtime enclosing chain). A subject that is
neither innermost nor the entry `this` — `with(3) { with("s") { f(true)
} }` for `f: context(String, Int) (Boolean) -> Unit` — is found only
through the runtime chain. Verify the runtime chain always sees it
(the subject is `EnclosingPush`ed for the body's extent) and record the
answer; if a shape misses, extend `implicitReceiverOfType` to walk every
`subject_binds` entry (already innermost-first) before falling back.

- [ ] probe program with two and three nested subjects, mixed with a
      `context(...)` scope in between; add it to
      `examples/context_parameters_implicit_receiver.kt` if it passes,
      as its own example if it needed a fix

## Not tasks (already settled)

`open-residue-audit.md` (2026-09-02) re-verified the two watch-state
items the CI campaign's closing notes listed as candidates: the compose
graphics "non-trailing receiver-lambda argument loses its receiver"
note (a fresh minimal probe passes; the memory line was stale) and the
remember-family receiver-publication note (the plugin suite carries every
remember* test at 1390/0). Nothing to do.

## Log

- 2026-09-05: opened from the CI campaign's closing notes.
