# Conformance backlog

The active plan (register: `open-campaigns.md`). Stages run in order and
each stage's exit conditions are met before the next begins. Stage 1 (the
battery as the whole local gate) closed 2026-09-05; Stage 2 Tasks 1-3 (the
box corpus populated, the runner, the first census and ratchet, the CI
shard) closed 2026-09-05. The log of what landed is git history.

## Stage 2 — Task 4: root-fix the box corpus by cluster

Owner: `kotlinc-box-conformance.md`. State 2026-09-07: census 5751 / 609 /
11, ratchet 5751 / 609, 43 clusters of five or more remain (listed there).

Left: fix every cluster of five or more or record its verdict, each fix
shipping an `examples/` program, its `.out`, and a README row, matching
kotlinc exactly and never by editing the corpus; ratchet after every
landed batch; write the residue list (clusters under five) as the seed of
the next campaign.

Exit: no cluster of five or more without a fix or a verdict; the residue
list written; the ratchet at the final census; CI green.

## Stage 3 — the verification tier's allocation fill

Owner: `safe-tier-allocation-fill.md`. Not started.

Left: measure the ReleaseSafe/ReleaseFast census ratio on three suites;
list what the safe tier has caught, with commit ids; decide among taking
the fill off the hot containers, running census children on the fast
harness with a canary per shard, or keeping the tier with its price
recorded; land the decision with before/after CI walls.

Exit: the decision and its numbers in that record.

## Rules that hold throughout

Root cause only, never a symptom hidden or a test edited; verify with the
playbook (`docs/development/verification-playbook.md`); the whole battery
once per stage plus e2e, pinned parity and the CLI corpus before a push;
CI green on every push; commits straight to `main`; this file and the
register updated as each stage closes.

## Close

Close this document, and move the register's active plan on, when Stages
2 and 3 have their exit conditions met.
