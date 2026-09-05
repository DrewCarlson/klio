# Conformance backlog — after the green-main work

Register for the next block of work, in stage order. Each stage's exit
conditions must be met before the next begins; the owning documents carry
the task detail and their own logs.

Opened 2026-09-05 after `green-main-backlog.md` closed (CI green at
d0d1541d, every census at baseline, every compute floor classified).

## Stage 1 — the battery is the whole gate (`verification-speed-plan.md`)

1. Fold the stdlib sweep and the gate-env example corpus check into
   `scripts/stack.sh`; make `corpus_check.py` refuse the shared data home
   by default. Exit: one `stack.sh` run is the whole local gate, its wall
   recorded (977 s before).

## Stage 2 — kotlinc box-test conformance (`kotlinc-box-conformance.md`)

2. Populate `compiler/testData/codegen/box` (+ helpers) in the sparse
   `kotlin` checkout, locally and on CI.
3. The `box` census runner: directive parser, `FILE:` splitting,
   directive-based selection with counted exclusion reasons, synthesized
   `main` asserting `"OK"`, per-directory batching, named failures.
4. First full census recorded; baseline ratcheted with `MAX_FAILED 0`;
   suite standing in `stack.sh` and a CI shard with a measured weight.
5. Root-fix by cluster until every cluster of size ≥ 5 is fixed or carries
   a verdict; each fix with an `examples/` program, its `.out`, and a
   README row. Exit: the residue list is written as the seed of the next
   campaign.

## Stage 3 — the verification tier's allocation fill (`safe-tier-allocation-fill.md`)

6. Measure the ReleaseSafe/ReleaseFast census ratio, list what the safe
   tier has caught, decide (take the fill off hot containers / run
   children on the fast harness with canaries / keep and record), and land
   the decision with before/after CI walls. Exit: the decision and its
   numbers in the record.

## Not in this plan

- kotlinx-io pack actuals (`SegmentPool`, `isWindows`, line separator) —
  `LANGUAGE-GAPS.md` "Pack-actual residuals"; reopen when a kotlinx-io
  path contends.
- Base-image reuse across load modes for `differential` — `LAZY-IMAGE.md`.
- Widening `kl_` leaf eligibility — `c-transpiler-plan.md`; needs a real
  program that misses it.

## Register

Listed as the active plan in `open-campaigns.md`. Close this document when
Stages 1-3 have their exit conditions met and the register's "active plan"
moves on.

## Log

- 2026-09-05: opened; the owning documents carry the task detail.
