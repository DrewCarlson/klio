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
| `catch_param_type_drops_cause.kt` | Recording a catch parameter's declared type drops the `Caused by:` chain from `stackTraceToString()` (`MISSING <Root cause>`). Passes as-is; fails once the catch parameter's type is recorded at its binding. See the static-dispatch campaign plan. |
