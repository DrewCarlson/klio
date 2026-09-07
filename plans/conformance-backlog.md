# Conformance backlog

The active plan (register: `open-campaigns.md`). Stages run in order and
each stage's exit conditions are met before the next begins. Stage 1 (the
battery as the whole local gate) closed 2026-09-05; Stage 2 Tasks 1-3 (the
box corpus populated, the runner, the first census and ratchet, the CI
shard) closed 2026-09-05. The log of what landed is git history.

## Stage 2 — Task 4: root-fix the box corpus by cluster

Owner: `kotlinc-box-conformance.md`. Closed 2026-09-07 at 8c8c613a: census
5991 / 363 / 3 from 5751 / 609 / 11, ratchet 5991 / 363, every cluster of
five or more with a fix or a verdict, the residue table written there as
the seed of the next campaign, CI green.

Exit met.

## Stage 3 — the verification tier's allocation fill

Owner: `safe-tier-allocation-fill.md`. Closed 2026-09-07.

The ratio on three suites (datetime 1.22, serialization_json 1.14,
coroutines 1.40, identical pass counts), the seven-entry catch list with
commit ids, and the decision: keep ReleaseSafe on every verification
wall, the ratio recorded as its price. No change landed.

Exit met: the decision and its numbers are in that record.

## Rules that hold throughout

Root cause only, never a symptom hidden or a test edited; verify with the
playbook (`docs/development/verification-playbook.md`); the whole battery
once per stage plus e2e, pinned parity and the CLI corpus before a push;
CI green on every push; commits straight to `main`; this file and the
register updated as each stage closes.

## Close

Closed 2026-09-07: Stages 2 and 3 have their exit conditions met. The
register's active plan moves to the box residue.
