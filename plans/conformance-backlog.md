# Conformance backlog — after the green-main work

Register for the next block of work, in stage order. Each stage's exit
conditions must be met before the next begins; the owning documents carry
the task detail and their own logs.

Opened 2026-09-05 after `green-main-backlog.md` closed (CI green at
d0d1541d, every census at baseline, every compute floor classified).

## Stage 1 — the battery is the whole gate (`verification-speed-plan.md`)

1. Fold the stdlib sweep into `scripts/stack.sh` (the example corpus was
   already there as `itest-check_examples`, and the litmus runs last);
   make `corpus_check.py` refuse the shared data home by default. Exit: one
   `stack.sh` run is the whole local gate, its wall recorded (977 s
   before).

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
- 2026-09-06: Stage 2 Task 4 #12 adapted callable references (omitted
  varargs empty on every call route, SAM methods pass their context
  parameters): census 5,560 / 792 / 19, sweep 117/0, corpus 465/465.
- 2026-09-06: CI red on a8a753a3/84e43df9 (shards 0 and 5): five mechanisms
  root-fixed in 45b99090 (hidden secondary constructors in header resolution,
  keepalive slices freed under the marker, entries unreachable between
  constructions, page-allocated name preset, marker field grown through the
  patch allocator); record #11 in `kotlinc-box-conformance.md`.
- 2026-09-05: Stage 2 Task 4 in progress — ten cluster fixes landed
  (destructuring forms, explicit primitive rangeTo, invoked lambda
  arguments, enum entry bodies as subclasses, language feature flags and
  the name-based short form, corpus syntax gaps, contextual anonymous
  functions, tailrec in every form, bare accessors and enum secondary
  constructors, parent secondary constructors and enum virtual dispatch):
  census 5,246 / 1,105 → 5,553 / 799 / 19. Records and verdicts in
  `kotlinc-box-conformance.md`.
- 2026-09-05: Stage 2 Tasks 1-3 landed (b5e42fd8) — corpus populated locally
  and on CI, `box_support.zig` runner + `box_conformance` itest +
  `klio-census box`, first census 5,246 / 1,105 / 20 of 6,371 selected
  (980 excluded by directive), ratchet 5246 / 1105, shard weight 35,
  stack.sh wave 2 (battery 948 s with the suite at 4 workers; the runner
  now takes `KLIO_BOX_JOBS`, 12 in stack.sh). Task 4 (root-fix by
  cluster) next.
- 2026-09-05: Stage 1 landed — `stack.sh` runs the stdlib sweep after the
  census waves and scrapes its zero-failure line into the verdict;
  `corpus_check.py` refuses an unset or shared `KLIO_HOME` unless
  `--allow-shared-home`; `quick-gate.sh` passes the local home. Battery
  728 s, every suite at baseline, sweep 117/0.
