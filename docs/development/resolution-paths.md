# The two resolution paths, and which one your runner uses

klio resolves a bare call through two mechanisms, and which are available
depends on **how the program was launched**. This page states the
precedence, the measured divergence, and the coverage asymmetry that falls
out of it — because a bug once passed under `klio run` and failed in the
in-process harness on the same source, and the reason was not in the
program.

## The mechanisms

**The eager typeck map.** Before lowering, the checker walks the program
and records a resolved target per call site (`ir.pending_eager_calls`,
keyed by span). At the lowering site it is *consumed* in preference to the
lazy answer: it is type-derived and overload-precise where the lazy engine
is shape-based, and it pins the pick against runtime value-typed re-picks
(`res_final.target_final = true`).

**The lazy resolution engine.** Candidate scoring at lowering time from
argument shapes, receiver heads, and scope tiers. Always present.

Precedence is defined, not ambiguous: **where the eager map has an entry,
it wins.** The one exception is guarded in `expr.zig` — a pick that
resolves the call back to the ENCLOSING declaration is distrusted, because
stdlib overload families delegate to same-name siblings and a mis-picked
self-target recurses forever.

## Who builds the eager map

`pending_eager_calls` is populated **only under `src/cli/`** —
`commands.zig` (run/check), `bundle.zig`, `bundle_boot.zig`,
`stdlib_image.zig`. Grep is unambiguous: `src/parity/parity.zig` never
builds it.

| runner | pipeline | eager map |
|---|---|---|
| `klio run` / `klio test` / bundles | CLI | **yes** |
| `corpus_check.py` | spawns the CLI | **yes** |
| e2e, differential, every parity itest, the commontest censuses | in-process `parity` | **no** |

So the configuration users run is not the configuration most of the test
apparatus runs.

## Measured divergence

`KLIO_EAGER_AUDIT=1` prints `[EAGER-AUDIT]` for every call where the two
mechanisms disagree. Over 60 corpus examples:

- **4 disagreements, all of the shape `eager=<fid> lazy=-1`** — the lazy
  engine declined and the eager map supplied a target
  (`class_factory_overload.kt` ×3, `annotated_function_types.kt` ×1).
- **0 cases where both answered and answered differently.**

That is the reassuring half: the paths do not contradict each other. The
eager map supplements; it does not overrule a confident lazy answer.

It is also the risk. Every one of those 4 is a call that resolves under the
CLI and has no answer without the map. That is exactly the shape of the
`positional_lambda_binding` failure: the program ran under `klio run`
(eager supplied the target) and failed in base mode (no map, lazy declined,
the call fell to the value route, which bound the wrong parameter to Null).
The bug was real and lived in the lazy scorer — the eager map had been
hiding it.

## The coverage asymmetry

- The **parity path** is output-pinned: e2e enforces 320 expected outputs.
- The **CLI path** is mostly exit-code-checked: `corpus_check.py` runs all
  335 examples but compares output for only the 16 under
  `tests/corpus/expected-cli/`.

So the resolution configuration users actually get has the weaker
assertions, and the configuration with the strong assertions is one users
never run. Neither is wrong on its own; the asymmetry is worth knowing
before trusting a green corpus as proof about `klio run`.

## Practical rules

- A bug reproducing under one runner and not the other is a resolution-path
  difference until proven otherwise. Check `KLIO_EAGER_AUDIT=1` first.
- A lazy-engine fix is the real fix. If a call only works because the eager
  map supplies it, the lazy scorer has a gap that every in-process driver
  will hit.
- Do not "fix" a parity failure by teaching parity to build the eager map.
  That would hide lazy-engine gaps from the only suites that currently
  catch them.
