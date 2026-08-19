# Census gates and the red mass

Two tracks, one goal: make every census gate honest in both directions, then
drive the tolerated failure mass down.

The predecessor campaign (`conformance-and-hardening.md`, closed) added
failure ceilings to the census suites — but only to the six that run through
`commontest_support.zig`. Its item C3 said "for every census suite" and the
landing commit said "bound every census in both directions". Neither was true:
`stdlib`, `compose_plugin`, and `androidx_collection` predate the shared
helper, have their own bespoke tallies, and counted passes only. This plan
closes that and then attacks what the ceilings expose.

## Track A — every census bounded in both directions (9/9)

A pass-count floor cannot see a regression *inside* the red mass: a change
that turns one failure into a pass while breaking a different test leaves the
floor untouched. Each suite needs a failure ceiling seeded from a measured
solo run.

- [x] A1. `stdlib` — count failures from the child summary line, mirror of
      `passedCount`. Measured solo across both shards: 1024 + 1277 passed,
      **0 failed**, 0 build-blocked. Ceiling seeded at 0: every stdlib case
      that runs, passes, so one new failure is a real regression. (A file that
      cannot produce a summary is counted `build-blocked`, not failed.)
- [x] A2. `compose_plugin` — count `FAILED` lines, mirror of
      `passedLineCount`, with the same streamed-stderr fallback the pass
      counter uses for a class killed mid-run. Measured solo: 1375 passed,
      **15 failed**, 0 did not complete. Ceiling seeded at 15. Deliberately no
      did-not-complete ceiling: DNC here is throughput-bound and varies by
      ~40 between runs, so a DNC gate would be a flake rather than a signal.
- [x] A3. `androidx_collection` — count `FAILED` lines. **Its ratchet had
      never run.** The sparse-checkout set in
      `scripts/init-androidx-collection-submodule.sh` pulled `commonMain`,
      `nonJvmMain`, and `jbMain` but not `commonTest`, so `TEST_ROOT` did not
      exist and the suite took its `SkipZigTest` path — and a skipped suite
      reads as a pass. Added `commonTest` to the sparse set; 43 test files now
      present and the suite runs for real.
- [x] A4. Negative controls. A ceiling seeded from a measured `0` is only
      trustworthy if the counter can see a non-zero. Each of the three counters
      has a unit test over synthetic child output asserting it counts failures,
      ignores passes, and that the pass parser is not fooled by the failure
      field.

Standing rule: a suite that *skips* is not a suite that *passes*. When a
census cannot find its sources it currently prints and skips, which is right
for a checkout without submodules but silent in a checkout that should have
them. Any new census must state which it is.

## Track B — the red mass

Failures tolerated by the ceilings, worst ratio first:

| suite | passes | failures | conforming |
|---|---|---|---|
| serialization | 60 | 78 | 43% |
| datetime | 450 | 70 | 87% |
| coroutines | 1040 | 150 | 87% |
| io | 1150 | 45 | 96% |
| compose_plugin | 1375 | 15 | 99% |
| atomicfu | 63 | 8 | 89% |
| ktor | 440 | 6 | 99% |
| stdlib | 2301 | 0 | 100% |

- [ ] B1. **serialization descriptor fidelity.** klio has no serialization
      compiler plugin, so `T.serializer()` resolves to a reflective
      replacement whose descriptor was type-erased: `isElementOptional` was
      hardcoded `false`, `getElementDescriptor` returned a neutral
      placeholder, and `getElementAnnotations` returned `emptyList()`. The
      runtime already carried the answers — `ClassParamDef` has
      `declared_shape`, `default`, and per-property `anchors` — they were
      simply never exposed.

      Landed so far: `__klsx_ctorParamTypes` and `__klsx_ctorParamOptional`
      host helpers, and a `ReflectiveDescriptor` that answers
      `isElementOptional` from the parameter's default and names a real
      primitive descriptor per element (falling back to neutral rather than
      claiming a structure the type-erased path cannot produce).
      Still open: per-element annotations, which need the anchors exposed the
      same way.
- [ ] B2. Census the remaining serialization failures and rank the roots.
      `scripts/commontest-census.py serialization --errors` gives the
      per-failure error shapes; it reads the suite config straight out of the
      Zig itest so it cannot drift from the gate.
- [ ] B3. Identify the 15 compose_plugin failures by name. The census tool
      only supports the six `runSuite` suites, so this needs either a direct
      run or extending the tool to the bespoke three.
- [ ] B4. coroutines (150) and datetime (70) — the largest absolute masses.

## Traps

- `zig-out/bin/klio` goes stale silently. A pack build against a stale binary
  fails with errors that look like interpreter bugs but are not; the itest
  suites build their own current binary, which is why a suite can pass while
  a hand-run pack build fails. Check the binary's date against recent commits
  before believing a parse error.
- Heavy census suites must be measured **solo**. Concurrent runs skew the
  counts, and compose_plugin's per-class timeout makes it the most sensitive.
