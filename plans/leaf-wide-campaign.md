# Leaf-wide campaign: real inline bodies, wider ops, cheaper doorway

STATUS 2026-09-02: Task 1 LANDED AND CORRECTED — the "inline stub"
record was a MISDIAGNOSIS: standalone inline bodies are real; the
Map.iterator incident was a registration KEY COLLISION (the identity
`Iterator<T>.iterator() = this` overwrote Map's entry under the shared
single-char 'o' sig). Fixed at the root: leafKeyAlloc keys non-scalar
params by declared type head (`#{Map}` vs `#{Iterator}`, unit-tested),
inline gate deleted, wide leaves 3200 -> 3402, full battery green
(ktor 450/0 — the incident's own detector). Task 2 first rung LANDED:
escape histogram (CallMember 710, LoadGlobal 589, LoadCapture 354,
AstLambda 183, LoadFromThisOrGlobal 156, Cast 80, EnclosingPush 79,
SetField 67, CallValue 56); genre-9 enum statics (class-bound
LoadGlobal emits a name-handle literal; kl_getfield genre-9 resolves
enum entries via the new statics_route — entries are eager ClassDef
singletons, the one borrow-safe static family) unlocked 342 bodies
(3402 -> 3744, Duration.inWhole* among them); PLUS the property-getter
dispatch path gained the kl_ leaf gate it was missing (it had only the
frameless evaluator) — inWhole* micro 9.5 -> 8.8s, 900k serves.
Successor to
plans/native-floor-and-tower-campaign.md (closed complete). The one
future vein `plans/open-campaigns.md` §1 records — "widening kl_
eligibility, driven by a real program that misses it" — plus the
doorway vein that campaign recorded under its Task 1.

## Measured starting facts (do not re-derive)

- Wide leaf surface today: 3200 bodies served (kotlin./kotlinx.).
  Miss census over the same surface (KLIO_LEAF_TRACE=1 on the
  build-leaf-packs transpile):
  inline 2304, escape-op 1937, nonscalar-const 878, virt 746,
  obj-mid 324, term 101, call-shape 95, bin-kind 51,
  member-shadow 33, no-stream 29.
- INLINE is the single biggest vein and it is a SOUNDNESS gate, not a
  capability gap: an inline fn's standalone lowered body can be an
  identity stub because call sites splice the AST (Map.iterator's
  stub served the receiver map — the ktor 410/40 incident). The gate
  is `f.is_inline` in leafEligible.
- escape-op (1937) has NO per-inst breakdown: `[leaf-miss-inst]`
  prints only when KLIO_LEAF_TRACE names one fn exactly.
- Doorway: leaf-served micros are gate-bound, not body-bound.
  toEpochDays 290ms/300k calls (~970ns/iter incl. loop+dispatch);
  equals 420ms/600k (~700ns/call). Profile split on toepoch: leaf
  body ~41% (kl_8 22.6 + kv_edge 8.7 + kl_getfield 6 + kv_tag 3.5),
  doorway ~20% named (call 5.2, funcById 4.3, callMemberNamedInner
  3.5, callMemberInnerStatic 3.5, tryLeafValues 2.6) + marshal dust.
  Back-edge-only polling landed and measured noise-level.
- The anon-invoker leaf_route memo already lives on the MODULE's Func
  record (leaf-production campaign) — the doorway levers left are the
  member-site memos / fast_call plans (route resolved per call today)
  and the per-call interp edge-view build in tryLeafValues.
- Traps in force: leaves .so must match the body-transforming env;
  refresh zig-out/include/klio_rt.h after include/ edits (the pack cc
  compiles against the installed copy); frozen-layout compare is
  field-by-field; the field-route claim identity is not comparable to
  the receiver's class word; never `zig build` while a battery runs.

## Task 1 — inline standalone bodies made REAL

- Root-fix the stub class: lower every inline fn's standalone body as
  its true semantics (the same lowering a call-site splice produces,
  minus the splice-only context), so `f.is_inline` stops being a
  leaf-eligibility gate. Reified type parameters stay ineligible
  (their semantics genuinely need the splice context) — gate THOSE,
  not all inline fns.
- This is a lowering change with blast radius beyond leaves (any
  path that falls back to the standalone body gets better semantics);
  land it whole, then drive the battery green.
- Acceptance: the identity-stub shape is impossible by construction
  (a probe test asserts Map.iterator's standalone body is not an
  identity), the inline gate in leafEligible is deleted or narrowed
  to reified-only, and the wide leaf count reflects the unlocked
  bodies with the full battery green.

## Task 2 — escape-op breakdown, top ops landed measured-first

- First instrument: make `[leaf-miss-inst]` aggregate under
  KLIO_LEAF_TRACE=1 (tag histogram over the wide surface), and rank
  escape-op's 1937 by inst tag and by unlocked-body count (a body
  blocked by two ops only unlocks when both land).
- Then land the top 1-2 ops by the InstanceOf recipe (eligibility arm
  + kl_ helper with per-site class-word binding + edge-view route
  where resolution is needed), each with a named micro and a census
  number, or close the tag by measurement (obj-mid-style verdicts are
  acceptable: some tags have nowhere to live natively).
- nonscalar-const (878) is in scope only if the breakdown shows a
  cheap sound shape (e.g. string-const identity compare); do not
  build a string runtime into leaves.

## Task 2 verdicts (2026-09-02)

- LANDED: genre-9 enum statics (+342 bodies) and kl_cast pass-through
  (+20, near-free InstanceOf sibling; failed casts bail to the exact
  throw). Wide leaves 3200 -> 3764 across the rungs.
- CLOSED BY MEASUREMENT — CallMember (710), LoadCapture (354),
  AstLambda (183): the blocked-body sample is lambda-shaped (456 of
  the escape-blocked fqns are `<lambda>` bodies, which LoadCapture
  blocks anyway — leaf lambdas need a capture-marshal vehicle, a
  different design) and generic-dispatch-shaped (minOf/maxOf families
  need runtime fid resolution with BOTH sides leafed). No named census
  family sits behind either; the hot datetime bodies already serve.
  Revisit when a real customer names one. The remaining LoadGlobal
  residue is fn-bound globals (589 raw hits incl. the served class
  half) — same verdict.

## Task 3 — doorway: cheaper serve path

- Measure first: split the serve path cost on the equals micro
  (route lookup / funcRunsItsBody check / marshal / edge-view build /
  the C call itself) with counters, not samples.
- Levers, in recorded order: (a) leaf route hung off the member-site
  memo / fast_call plan so a monomorphic site skips the fqn#sig
  lookup entirely; (b) threadlocal cached interp edge view (rebuild
  only on GC-relevant state change) so tryLeafValues stops
  constructing it per call.
- Target: the equals micro's ~700ns/call moves materially (the replay
  path suggests low-100s ns is available) and the datetime census
  wall confirms or bounds the win. Land what measures, record what
  does not.
- VERDICTS (2026-09-02): threadlocal cached edge view LANDED —
  rebuilt only on host change, per-call work = two mode-flag stores;
  toEpochDays 290 -> 276ms (+5%), equals neutral. The site-memo
  leaf-route lever is ALREADY EFFECTIVELY PRESENT: the route memo
  lives on ir.Func (one atomic load post-resolution; tryLeafValues
  was 2.6% of the profile), so there is no lookup left to kill. The
  residual ~600ns/call is the interpreter's dispatch walk REACHING
  the commit point plus marshal — the per-op law again; closed with
  terms. NEW COMMIT POINT: the property-getter dispatch path gained
  the kl_ gate it lacked (see STATUS) — gate coverage, not doorway
  cost, was the real remaining lever.

## Standing policy

- Measurement-first; every landed piece shows before/after on a named
  number (micro wall, census wall, serve/bail counters, leaf count).
- Correctness gates never weaken: corpus parity 401/0, every census
  floor/ceiling, the compose gate, litmus. scripts/stack.sh is the
  full battery; leaves stay fail-open at every layer.
- Big changes land whole and are driven green (Task 1 especially).

Exit: Task 1's inline bodies are real with the gate narrowed to
reified-only and the battery green; Task 2's breakdown exists and its
top tags are landed-with-numbers or closed by measurement; Task 3's
doorway split is measured with each lever landed or its negative
verdict recorded; the wide leaf count and at least one census wall
carry the campaign's numbers. Full battery green throughout.
