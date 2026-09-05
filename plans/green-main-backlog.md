# Green-main backlog — the plan after CI green

CI went green at 627c341e (`ci-green.md`, run 33953220015). The campaign
that got there left a verified backlog: two gate holes that make the
green run weaker than it looks, two exact-semantics defects found in
passing, one scoping question to settle, and a set of measured compute
floors that are the profile evidence the closed perf era asked for.
This document sequences them; each item's detail lives in the plan that
owns it.

Order of work (each stage ends with the standing gates green:
`scripts/stack.sh`, and CI green on push):

## Stage 1 — make the green run guard what it appears to guard

1. **Ratchet audit** — `census-gates-and-red-mass.md` Track D.
   stdlib's baseline is 151 tests below its pass count; audit every
   suite and ratchet to the measured count. Exit: every baseline equals
   its last green count (or carries a root-caused record for the gap).
2. **The corpus check runs packs lowered from the tree** —
   `verification-speed-plan.md`, root cause opened 2026-09-05 (the CLI
   corpus check is `gate.sh`'s "corpus" phase, not the `check_examples`
   itest, which is a resolver cleanliness test). Exit: a pack-only
   lowering regression turns the corpus phase red (proved by
   reintroducing the reverted coercion in a scratch worktree).

## Stage 2 — resolution residue (`resolution-residue-campaign.md`)

3. **Bare factory vs value-class constructor** (Task 1) — kotlinc-exact
   overload choice between a constructor and same-named functions inside
   the class's own companion. Exit: the example passes; compose graphics
   `Color` initializers unchanged in the in-process e2e.
4. **Char ranges expose Int endpoints** (Task 2). Exit: `'a'..'c'`
   prints `a..c`, endpoints and iteration elements are `Char`, the
   stdlib range tests stay green.
5. **Implicit context arguments through nested subjects** (Task 3) —
   settle whether the runtime chain covers every nesting; extend the
   static walk if not. Exit: the probe program's answer is recorded and,
   if a fix was needed, an example guards it.

## Stage 3 — compute floors (`compute-floors-record.md`)

6. Profile each recorded floor and classify it (per-op, algorithmic,
   genuine compute). Only an algorithmic pathology opens a fix; the rest
   stand as records under their caps. Exit: every row in the record
   carries a verdict; any fix ships with its before/after wall and a
   corpus example. Done 2026-09-05: seven rows classified; two
   algorithmic per-call rebuilds fixed (`classHasUserMethod` walk +
   allocations on every builtin member call, fromEpochDays 166→113 s;
   `enclosingOwnerSet` rebuilt on every uncached extension call,
   validatePotentialDeadlock 547→471 s solo); the rest stand as genuine
   interpreted compute; `examples/nested_receiver_extension_scope.kt`
   guards the memoized paths.

## Not in this plan

The two watch-state items from earlier memories (compose non-trailing
receiver-lambda argument, remember-family receiver publication) were
re-verified fixed on 2026-09-02 (`open-residue-audit.md`); they are
closed, not deferred.

## Register

CLOSED 2026-09-05: Stages 1-3 met their exit conditions (see the Log);
`open-campaigns.md` no longer lists an active plan.

## Log

- 2026-09-05: opened; the owning documents carry the task detail.
- 2026-09-05: Stage 3 landed — every floor profiled under `KLIO_PROF`
  and classified in `compute-floors-record.md`; two per-call rebuilds
  memoized (user-method answer behind builtin member dispatch; the
  enclosing-owner set behind member-extension visibility), the others
  recorded as the interpreter itself; `differential` re-measured on the
  ReleaseSafe universe (176 s, shard weight 18). Battery green, CI
  green. Plan closed.
- 2026-09-05: Stage 2 landed — bare factory vs value-class constructor
  (inside the class the constructor wins when the argument types fit;
  named arguments must name a candidate's parameters), Char ranges
  render and contain Chars, nested-subject context arguments verified
  (no fix). Battery green, every suite at baseline.
- 2026-09-05: Stage 1 landed — stdlib 2301 / coroutines 1299 ratchets
  (every other baseline already exact), `scripts/refresh-local-packs.sh`
  as gate.sh's "packs" phase ahead of the compose-ui gate, proof via the
  regression worktree, and the corpus defect it exposed
  (`channel_segment_namesake.kt` lacked its feature directive).
