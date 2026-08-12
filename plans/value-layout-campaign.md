# Value layout campaign: 56B toward 16B

## Where the bytes are

`@sizeOf(Value)` is 56: a 48-byte max payload plus the union tag rounded up
to 8-byte alignment. The census (unit test `value layout census` in
`src/runtime/value.zig`) puts the payloads at:

| payload | size | notes |
|---------|------|-------|
| Exception | 48 | fqn StringRef + message + cause + stack + identity + suppressed |
| List | 48 | items ValueList + flags + backing + declared_elem (?[]const u8 = 16!) + mod_count |
| Set | 48 | same family as List |
| Map | 48 | entries ObjRef + mutable + declared_key/value (2 × ?[]const u8) |
| Range | 32 | start/end/step i64 + kind + progression |
| BoundMethod | 32 | fqn + func + receiver box |
| MapEntry | 32 | key/value boxes + backing + exp_mod |
| Intrinsic, Array, Triple | 24 | |

Every `Value` copy (register writes, arg pushes, capture stores) moves the
full 56 bytes. The plan: box the 48-byte payloads behind one pointer each
(56 → 40), then the 32/24-byte payloads (40 → 16, the pointer-plus-tag
floor).

## Box representation

`Map: *MapData` — a raw pointer to the payload struct stored inside a
standard `objcell` control block (`ObjRef(MapData).Cell`), pointing at the
cell's `data` field:

- **Read sites keep compiling.** Zig auto-derefs pointers on field access,
  so `v.Map.entries` and `.Map => |m| m.mutable` are unchanged. Only
  construction sites and the ownership core change.
- **Ownership.** `retain`/`release`/`gcMark` recover the control block with
  `@fieldParentPtr("data", ptr)` and clone/deinit the recovered `ObjRef`.
  The payload struct carries the `deinit`/gcTrace behavior the cell thunks
  already dispatch to. Under the arena fast path all of it is skipped, as
  today.
- **Construction** goes through one helper per type
  (`Value.newMap(allocator, MapData{...})`) so the 9–53 sites per type stay
  one-liners. Static/empty singletons (if any) get a permanent cell.
- **Copy semantics change on purpose.** Today a `Value` copy duplicates the
  payload struct (sharing the inner cells); after boxing, copies share the
  payload struct itself. The interior mutability the interpreter relies on
  (mod_count, entries, backing) already lives behind shared cells, and no
  site takes a `|*x|` mutable payload binding for Map (grep: zero), so
  sharing the struct is observationally equivalent there. List/Set/Exception
  sites that rebuild the payload in place get reviewed one by one at their
  stage.

## Stages

Each stage lands separately, battery-verified (quick-gate + compose
ratchet), and the census test pins the size it achieves. Value stays 56
until the last 48-byte payload boxes, so the wins land at stage ends:

1. **Map** (pilot: 9 ctor sites, 43 reads, zero mutable matches) — proves
   the pattern end to end: cell recovery in retain/release/gcMark, clone,
   eql (`ptrEq` moves to the box pointer), hash, toString.
2. **Set** (13 ctors).
3. **List** (37 ctors; the enum_entries/backing/subList family needs the
   in-place-rebuild review).
4. **Exception** (53 ctors but centralized in the throw paths; `===`
   identity IMPROVES — the boxed pointer IS the identity, and the `identity:
   u64` field can retire at the end of the stage).
   → **Value = 40.**
5. Range/BoundMethod/MapEntry (32B), then the 24B tail → **Value = 16.**
   Range is hot (loops); measure before boxing it — a packed i48/i32
   in-place shrink may beat a heap box there. Decide on numbers.

## Perf guardrails

- `zig build klio-harness` + commontest sweep wall must not regress.
- Boxing adds one allocation per collection VALUE construction (not per
  copy). Collections were already cell-allocating (items/entries), so the
  marginal cost is one more small cell; the copy path gets 16 bytes
  cheaper per move. If a stage regresses the sweep wall, its type gets a
  slab size-class or stays unboxed with an in-place shrink instead.

## Status

- [x] Stage 1: Map — boxed, module tests green
- [x] Stage 2: Set — boxed, module tests green
- [x] Stage 3: List — boxed, module tests green
- [x] Stage 4: Exception — boxed; **Value = 48** (RangeIter at 40 is the new
      ceiling, not the expected 40 — it joins stage 5)
- [ ] **Stage 4a (OPEN, blocking): GC minor-collection edge.** The full
      commontest sweep crashes (`kotlin/libraries/stdlib/test/text/StringTest.kt`
      aborts at `zipWithNext` after ~86 earlier tests shape the heap; two
      RangeIteration overflow tests misfire; sweep wall 133s → 1801s under the
      harness GC profile). Diagnosis so far, all reproduced deterministically:
      - `KLIO_GC_NOFREE=1` makes the crash vanish → the GC SWEEP frees a live
        box. Refcount teardown is exonerated (`KLIO_RC_DETECT` silent; a
        boxdie trace on view-list release never fired).
      - Solo/filtered runs pass; `KLIO_GC_STRESS` on small repros passes; the
        crash needs the tenuring boundary → MINOR-collection specific
        (`KLIO_GC_GEN=0` didn't crash before timing out).
      - The crash reads a dangling `*ListData` whose CHILD cells look intact —
        the shape of a NURSERY box over TENURED inner handles (the
        new-box-around-old-handles constructors: `arrayAsListView`,
        `makeList(items.cell.allocator, …)`, subList) swept by a minor while
        its only reference sits in a tenured cell that never joined the
        remembered set.
      - The write barrier only fires through `tryBorrowMut`/`asPtr`
        (objcell.zig); RAW writes through the boxed payload pointer
        (`v.List.declared_elem = …`, `l.mutable = false`,
        `attachStackTrace`'s `e.stack = …`) have NO barrier — pre-boxing these
        fields lived inside the `Value` itself and were re-traced as roots.
        Child-store hazard (nursery StackRef into tenured Exception box) is
        real even if not this crash.
      **Negative result that re-aims the hunt:** minors tracing THROUGH
      tenured cells (`minor_stops_at_tenured=false`, now the default — the
      `KLIO_GC_MINOR_STOP=1` knob restores the shortcut) still crash. The
      box is unreachable from EVERY registered root at mark time, so this is
      a ROOT HOLE, not a remembered-set miss. Safe points fire only at eval
      block boundaries, so the missed holder is a host-side or runner-side
      slot alive across a safe point: audit `host_keepalive` coverage
      (an intrinsic that re-enters eval without `keepalivePush` on a
      Value it holds in a Zig local), `frame.flat_call` prep state, and the
      access/enclosing chains pushed by `pushAccessEnclosingSubject` during
      member dispatch. Note pre-boxing the same hole would sweep the INNER
      cells of the held Value (items) but the first field read stayed inside
      the inline payload — boxing made the latent hole crash on the first
      deref. Repro: 22s (`cp StringTest.kt` to scratch + the bisect argv in
      scratchpad/bisect.py; crash needs the first ~86 tests' heap shaping,
      dies in zipWithNext). `KLIO_GC_NOFREE=1` green-lights everything else.
- [ ] Stage 5: RangeIter(40)/Range/BoundMethod/MapEntry(32), 24B tail
      (Value → 16)
