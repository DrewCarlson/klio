# Open-residue audit: verify every standing OPEN, fix live, close stale

STATUS 2026-09-01: NOT STARTED. Hygiene campaign: the memory/plan
registers carry OPEN items that predate weeks of resolution and
coroutine work — some are certainly stale, some are live bugs with
named repros. The census-gap lesson says untruthful registers cost
more than the audit does. Every item below gets a verdict on current
main: FIXED-BY-INTERIM (close with the verifying commit/run), LIVE
(root-fix now), or BLOCKED-WITH-TERMS (record the precise blocker).

## The audit list (source register in parentheses) — ALL VERDICTS IN

1. withTransform receiver loss — FIXED-BY-INTERIM 2026-09-02: the
   guard example examples/receiver_lambda_multiarg.kt (written for
   exactly this shape) byte-matches its corpus expected output, and
   examples/compose_drawscope.kt runs to `drawscope drew=true`; a
   fresh minimal non-trailing receiver-lambda probe also passes. The
   graphics memory's OPEN line was stale.
2. with_timeout preempt + private_shadow — FIXED-BY-INTERIM (the
   memory FILE itself recorded RESOLVED re-verified 2026-08-14; only
   the index line was stale). Re-verified 2026-09-02 on main:
   withTimeoutOrNull(5){delay(50)} = null standalone and nested,
   private shadow fields keep distinct cells.
3. Nested-`it` capture — LIVE, ROOT-FIXED 2026-09-02 (7e9a5b2a): the
   July diagnosis had drifted; today's mechanism was that a bare call
   to an OWN MEMBER records no expected lambda arity (members are
   absent from func_name_index), so a `() -> Unit` trailing lambda
   kept a phantom `it` shadowing the enclosing lambda's as null
   (`listOf(..).let { mrun { println(it) } }` in a method). Fixed via
   the registered member AST keyed (owner, name, arity); the July
   repro passes unmodified. Note: `{ println(it) }()` with no
   expected type is INVALID Kotlin (kotlinc rejects it) — not a bug.
4. remember-family receiver-publication — FIXED-BY-INTERIM: the
   compose plugin suite carries every remember* test and stands at
   1390/0 in today's batteries.
5. Unconfined resume order — VERIFIED MATCHING 2026-09-02: oracle
   built with the IDEA-bundled kotlinc 2.2.20
   (/opt/idea/plugins/Kotlin/kotlinc/bin/kotlinc) against the gradle
   wrapper's kotlinx-coroutines-core-jvm-1.10.2.jar; eager-start and
   yield-ordering probe output is byte-identical between the JVM and
   klio. The oracle recipe is reusable for future ordering disputes.
6. Duration toString in containers — LIVE, ROOT-FIXED 2026-09-02
   (f654d377): not env-shaped — println/print rendered containers via
   the runtime's structural Display walker, which cannot dispatch a
   user toString override per element ("$list" and .toString() were
   already correct). Containers now route through the member-dispatch
   toString like Instance/Result.
7. Register hygiene (no code) — DONE 2026-09-02: open-campaigns §2
   call-half bullet marked LANDED with the four-mechanism record, the
   active-plan pointer now names the two live campaigns, both are in
   the doc register, and klio-census-state is marked SUPERSEDED in the
   file and the memory index (evidence: the register commit on main).

## Method

- One item at a time: reproduce first on current main with the
  original repro (or build the minimal one the record describes),
  verdict, then fix or close. No fix without a failing repro in hand;
  no closure without a passing run recorded.
- Fixes follow root-cause rules: interpreter mechanism, never test
  edits; big change if the mechanism demands it.
- Each verdict lands in the owning memory/plan as one line with date
  and evidence (commit or run), so the registers read true afterward.

## Standing policy

- Correctness gates never weaken; scripts/stack.sh is the full
  battery and runs once per landed fix cluster, not per item.
- Traps in force: installed packs shadow sources (rebuild before
  judging a pack-code repro), litmus failures are real (45/45
  baseline), memory records reflect when-written state — verify
  before trusting.

Exit: all seven items carry dated verdicts with evidence; every LIVE
item is root-fixed with its repro passing unmodified; the registers
(open-campaigns, the touched memories) read true; full battery green.
