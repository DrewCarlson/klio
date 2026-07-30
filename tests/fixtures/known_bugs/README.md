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
| `catch_param_type_drops_cause.kt` | A bodyless `expect` admitted only because it carries a host symbol is lowered as an interpreted call, so `Throwable.stackTraceToString()` enters an empty frame instead of klio's host renderer and drops the `Caused by:` chain. Prints `true` as-is; prints `false` once a catch parameter's declared type is recorded, which is what makes the receiver statically typed. See the static-dispatch campaign plan. |
