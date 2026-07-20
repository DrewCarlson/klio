# KLIO

KLIO is an experimental interpreter for the Kotlin programming language, built using the Zig programming language.

This is a large long-term project that we're treating as an experiment for now, you will follow these rules.

- Avoid language suggesting any part of the project is complex or difficult in a way that limits what we are trying to build.
- Do not add large comments that: document intermediate changes as new code/features are added, suggest the code was written by an LLM, or contain AI embellishments like emdashes or phrases like "defense in depth".
- Use adversarial agents with strong prompts to build, evalute, and improve each part of the project we build.  For example we should use role based agents like "Compiler Programmer", "Language Designer", etc with strong prompts defining the role to produce good results from those agents.

## Project shape

KLIO is implemented entirely in Zig (it was originally written in Rust and has been
fully ported). The interpreter is one Zig module per subsystem under `src/`, wired by
the data-driven `build.zig` (`mod_list`): span, diagnostics, ast, runtime, types, lexer,
pack, parser, ir, stdlib, cfa, resolver, interp_ir, typeck, the kotlinx_*/ktor_client
libraries, and the cli (the `klio` binary). Build with `zig build`. `zig build
test` runs the fast module unit tests (seconds); `zig build itest` runs the slow
integration suite (interprets whole programs — minutes); `zig build test-all`
runs both (what CI runs). Run a program with `./zig-out/bin/klio run file.kt`.

The Kotlin source *data* the interpreter consumes at runtime is data, not code: the
upstream stdlib lives under `kotlin/libraries/stdlib`, klio-authored actuals and the
kotlinx packs under `kotlin-klio/`, test fixtures under `tests/fixtures/`, and baked
end-to-end expected output under `tests/corpus/expected/`.

When changing behavior, match Kotlin semantics exactly and fix the real root
cause. Verify per-module in isolation with `python3 scripts/zigcheck.py <module>`.

Verification speed — follow the playbook in `plans/verification-speed-plan.md`:
Debug harness (`zig build klio-harness -Dharness-optimize=Debug`, ~16s, installs
as `zig-out/bin/klio-harness-Debug`) for edit-repro loops;
`scripts/commontest-sweep.py BIN --filter <File> --eager both` for targeted
stdlib-test checks (~16s); `zig build itest-<suite>` for one suite;
`scripts/gate.sh` for the full pre-commit gate. Never build `itest-bin` (all ~56
binaries) during iteration; never use `--watch -fincremental` (broken for this
graph — see the plan); prune the GC-less cache with `scripts/prune-zig-cache.sh`
when it grows.

Debugging knobs:

The interpreter honors a large set of environment variables for tracing and
diagnosis; the full catalogue (accepted values, output tags, workflow recipes)
is `docs/development/debugging.md`. The highest-value ones when debugging the
interpreter:

| Variable | Use |
|----------|-----|
| `KLIO_ERR_TRACE=1` | frame chain + miss detail on traceless Vm failures; full throwable rendering in `klio test` (`[errtrace]`) |
| `KLIO_THROW_TRACE=1` (+ `KLIO_THROW_STACK=1`) | one line per throw as it unwinds, optionally with the frame chain (`[throw-trace]`) |
| `KLIO_PUMP_DIAG=1` | coroutine pump loop + park/adopt/persist token lifecycle, stalled-pump dumps (`[PUMP]`, `[tok]`) |
| `KLIO_RESUME_TRACE=1` | who resumed a continuation and every frame the resume re-ran, with file:line and route (`[resume-call]`, `[resume-frame]`) |
| `KLIO_SPIN_TRACE=10` | frame-chain + register dump every 10s of a run that never returns (`[spin]`) |
| `KLIO_BARE_TRACE=<fn>` | static: how the bare call resolved at lowering (`[bare]`) |
| `KLIO_MISS_TRACE=<fn>` | dynamic: which runtime dispatch tail missed for that name (`[member-miss]`, `[extfb]`, ...) |
| `KLIO_NU_TRACE=<fn>` | candidate/visibility detail for hard dispatch cases (`[mev]`, `[strictext]`, ...) |
| `KLIO_COMPOSE_MEMO=0` / `KLIO_COMPOSE_SKIP=0` | bisect the plugin's lambda-memoization / skip-calculus emission |
| `kotlinx_coroutines_test_default_timeout=10s` | cap runTest's 60s default timeout (dots-to-underscores env alias for the property) |

Note that `zig build` forwards only a fixed passthrough list of these to itest
child processes (see the docs page); an exported trace variable reaches
`klio run` and a hand-run itest binary, but not necessarily `zig build itest-*`.

Scope and regressions — big changes are expected:

Risk is not a reason to stay small. When there is a valid plan to get from A to B,
regressions and temporary failures *in between* are irrelevant — they are the normal
cost of real structural progress. Do NOT limit yourself to small patches that keep
everything green when the actual fix is a large change to a core path (resolution,
dispatch, field storage, lowering). "Minimal" means minimal for the true root cause,
NOT the smallest diff that dodges a regression. A multi-phase refactor that sets the
test count back for several commits before it climbs past the old baseline is the
right way to work, not something to avoid. Land the big change, then drive it green.
Keep going until the end goal is reached — never abandon a valid plan because the
middle is red. (This does not relax root-causing: still fix the real mechanism, never
hide a failure. It relaxes only the stay-green-every-commit constraint.)

Resources:

The `kotlin-language-spec` folder contains PDFs for each section of the Kotlin Language Spec.
Use your existing knowledge when working with high-level details of the language and use the spec PDFs
when reasoning about and implementing complex internal details of the language.

Environment:

Zig is fully available to you. The toolchain is installed at `/config/.local/zig-0.16.0`
and is on `PATH` as `zig` (version 0.16.0). Build with `zig build`, run the fast
unit tests with `zig build test` (full suite: `zig build test-all`), run a file
with `zig run`. Use the standard library and Zig's built-in
build system; do not over-rely on 3rd party dependencies where it can be avoided.
Structure and build the project using modern best practices for a large Zig project:
a top-level `build.zig` + `build.zig.zon`, one module per subsystem under `src/`, and
explicit module imports wiring the dependency graph.

Memory management is manual in Zig. Thread an allocator explicitly; prefer arena
allocators for phase-scoped data (a parse/lower pass), and document ownership at API
boundaries. Match the Rust ownership model when porting (what Rust freed at scope exit,
free explicitly or via arena reset).

Documentation:

As we build out the project, maintain meaningful and clear documentation, including a README.md and a markdown docs folder for everything else.
Use running plan documents for everything, keeping them up to date with all the evolving information and the completeness of the work we do.

Root-cause only — no symptom hiding:

Always fix the real root cause. Never paper over a failure by editing the
test program or the example to dodge the bug. Concretely: if a program
fails because of a name clash — e.g. a sealed subtype named `Error`
clashing with `kotlin.Error`, or any user identifier colliding with a
builtin/stdlib name — renaming the user's type (e.g. `Error` → `Failed`)
is NOT a solution and must never be used as one, in tests, examples, or
anywhere. The interpreter must resolve the clash correctly (here: a
user/nested type resolves to the user's declaration, not the builtin).
The same rule applies to every class of bug: do not hide, bury, skip,
`xfail`, or work around it. Diagnose and fix the underlying mechanism.
Using a renamed/simplified throwaway repro to *bisect* and confirm a
root cause is fine, but the real test/example/program must pass unmodified
once the fix lands. During the migration, a Zig port that diverges from the
Rust original is a bug in the port — fix the port, do not weaken the test.

Diagnostic messages:

User-facing diagnostic messages must not reference the Kotlin Language Spec (no `(spec §X.Y)` tails, no "per spec ...", etc.). Spec citations are useful internally and belong in `///` doc comments above the emitting code or in the PLAN; the message itself should describe the problem and the fix in terms the user can act on. Example: prefer "`f` cannot be both `private` and `open`" over "`f` cannot be both `private` and `open` (spec §5.4)".

Testing:

Every step ships with comprehensive test coverage. For each piece of language functionality we implement — including complex behavior like string templates, smart casts, lambdas, when-exhaustiveness, coroutines — we add:
- Unit tests at the module level (Zig `test {}` blocks) covering the happy path, edge cases, and diagnostic cases. These run under `zig build test`.
- Integration / end-to-end tests that exercise the feature through the real pipeline (lexer → parser → resolver → interpreter), asserting both program output and emitted diagnostics.
- A maintained corpus of `.kt` sample programs under `tests/corpus/` (per module where it makes sense, plus a workspace-level corpus) that grows monotonically with every feature.
When porting, translate the original Rust crate's unit/integration tests into Zig tests so coverage carries over. Never mark a feature (or a ported file) done without tests that fail when the feature is removed or regressed.

Examples:

Alongside tests, maintain a growing set of runnable example programs under `examples/`. Every new language feature ships with at least one new (or extended) example demonstrating it end-to-end through the real `klio` binary. Examples should print deterministic output so a future harness can assert against them, and the index at `examples/README.md` must be kept in sync.

Committing:

You can commit work as you go.

Do not mention intermediate work in comments, markdown docs, or commit messages.  Things like "Phase X" or "Milestone X" or "MX" in relation to plan documents should not be mentioned ('Phase' is ok in terms of compiler/interpreter processes.)

Commits do not need to stay green if the immediate followup is to fix it and make it green again. A commit that intentionally breaks the build/tests is fine as long as the very next work restores it; do not stall progress to keep every commit green.

Always work on `main`. Do not park half-finished work on a side branch — commit it to `main` and keep going there until it is done. There is no such thing as a "multi-session build": loop and continue with any amount of work until the task is complete. When the end goal is known and the bugs are defined or discovered, there is no scope limit that justifies stopping early — keep going (including any interpreter work the task requires) until everything is fixed and green.
