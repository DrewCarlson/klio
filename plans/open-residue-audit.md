# Open-residue audit: verify every standing OPEN, fix live, close stale

STATUS 2026-09-01: NOT STARTED. Hygiene campaign: the memory/plan
registers carry OPEN items that predate weeks of resolution and
coroutine work — some are certainly stale, some are live bugs with
named repros. The census-gap lesson says untruthful registers cost
more than the audit does. Every item below gets a verdict on current
main: FIXED-BY-INTERIM (close with the verifying commit/run), LIVE
(root-fix now), or BLOCKED-WITH-TERMS (record the precise blocker).

## The audit list (source register in parentheses)

1. Non-trailing receiver-lambda arg loses its receiver —
   `withTransform` stack-overflow (klio-compose-graphics-stack). The
   one item with a named crash. Verify with a minimal withTransform
   scene; if live, this is a receiver-binding root fix in the
   call-arm, not a graphics fix.
2. `with_timeout` preempt + `private_shadow` cells
   (klio-hang-tooling-and-coroutine-barrier, OPEN tail). The
   coroutine-flow record later says with_timeout/private_shadow PASS —
   the two records conflict; run the litmus pair and reconcile.
3. Nested-`it` capture (klio-stdlib-grind-campaign,
   diagnosed-not-landed). Re-run the diagnosing repro; land the fix if
   the diagnosis still holds.
4. remember-family receiver-publication (klio-coroutine-flow-campaign,
   listed LIVE). The compose plugin era rebuilt that machinery;
   verify against the remember* suite standing at 1390/0.
5. Unconfined resume order (same memory: "needs kotlinc oracle").
   Build the oracle comparison once (kotlinc on the JVM vs klio),
   record match or divergence; if divergent, fix or record terms.
6. `println(5.seconds)` prints `Duration(rawValue=2000000000)` in a
   bare `klio-harness run` against the repo-local home (seen
   2026-09-01 during the tower campaign). Census suites print
   Duration correctly, so this is env-shaped: missing pack in the
   bare-run resolution or a real toString dispatch gap. Root it.
7. Register hygiene (no code): `plans/open-campaigns.md` §2 still
   records the call-half ~400 terms as open — landed strict-by-default
   2026-09-01 (plans/native-floor-and-tower-campaign.md); its "active
   plan" pointer predates the red-mass closeout; `klio-census-state`
   memory is superseded by the red-mass zeros. Update all three, and
   register the two new campaigns in the doc register.

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
