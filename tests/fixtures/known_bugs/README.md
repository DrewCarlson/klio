# Known-bug reproductions

Standalone programs that reproduce a diagnosed but unfixed defect. Each one is
referenced from the plan document that describes the defect, and each is written
to fail loudly with the smallest useful message rather than to be asserted by a
suite — nothing here is wired into `zig build test` or `itest`, because these
programs are expected to fail until the defect is fixed.

When a defect is fixed, the reproduction moves to `tests/fixtures/parity_corpus`
with its output pinned, and the plan entry is updated.

| File | Defect |
|------|--------|
| `catch_param_type_drops_cause.kt` | `kotlin-klio/kotlin-internal/ThrowableActuals.kt` defines `Throwable.stackTraceToString()` as `this.toString()`, a placeholder that discards frames, cause and suppressed. It is unreachable while receivers are untyped (klio's host renderer serves instead), and shadows the host renderer as soon as a receiver IS typed. Prints `true` as-is; prints `false` once a catch parameter's declared type is recorded. See the static-dispatch campaign plan. |
