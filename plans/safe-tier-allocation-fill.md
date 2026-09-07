# ReleaseSafe allocation fill — the verification tier's memset tax

Profiles taken for the compute-floors record (2026-09-05, in git history) show `memset` as
the largest single symbol on the ReleaseSafe harness: 11.5% of
`validatePotentialDeadlock`, 21% of `JsonHugeDataSerializationTest`, and
the dominant share of `fromEpochDays` before its memo fix. Caller
attribution (`KLIO_PROF_CALLERS=memset`) puts 62% under
`std.mem.Allocator.allocBytesWithAlignment` and 18% under `Allocator.free`:
Zig's standard allocator writes `@memset(bytes, undefined)` on every
allocation and every free (`std/mem/Allocator.zig`), which is a 0xAA fill
whenever runtime safety is on (Debug, ReleaseSafe) and is elided in
ReleaseFast. The same test on `klio-harness-fast` (ReleaseFast) shows
`memset` at 1.2%.

So this is not a tax the shipped `klio` binary pays; it is a tax every
verification wall pays: the ReleaseSafe harness behind the censuses, the
sweep, the corpus check, and all eight CI shards.

Parent plan: `conformance-backlog.md`.

## Tasks

1. **Measure the tier gap.** Run three census suites (datetime, json,
   androidx) on `klio-harness` and `klio-harness-fast` back to back, same
   cores, nothing else running; record wall and pass counts. Exit: a table
   here with the ReleaseSafe/ReleaseFast ratio per suite.
2. **What ReleaseSafe has caught.** From the CI campaign record (git history), the census memories,
   and `git log`, list the defects a safety check (bounds, overflow,
   unreachable, ubsan in C deps) surfaced that ReleaseFast would have run
   past. Exit: the list, with commit ids.
3. **Decide and land one of:**
   - keep ReleaseSafe everywhere and take the fill off the hot containers
     by allocating them through a path that does not go through
     `Allocator.alloc`'s fill (the slab already does for instances:
     `src/runtime/slab.zig`); measure what fraction of the fill that
     removes;
   - run the census/corpus children on `klio-harness-fast` and keep
     ReleaseSafe for the unit tests and one canary suite per shard;
   - leave it, with the measured ratio recorded as the price of the tier.
   Exit: the decision, its numbers, and (if a change) the CI walls before
   and after.

## What the safe tier has caught

The undefined fill is one of several checks the tier turns on; the list
covers the tier, with the check that fired.

| commit | date | defect | check |
|--------|------|--------|-------|
| 222ff8fd | 2026-08-01 | e2e crash: enum-entry patch wrote values from a per-program run arena into cached, program-spanning base instances; the next program's arena reset recycled the memory under them | the free-side fill made the use-after-reset deterministic |
| 879a0af1 | 2026-09-07 | e2e segfault: the thread-local local-class scope stack kept AST name slices of an earlier program | the free-side fill surfaced the dangling names on the ReleaseSafe e2e run |
| e6740915 | 2026-09-04 | a 17th pack overflowed the `u16` pack bitmask | `@intCast` overflow trap (led to `PackMask = u32`) |
| fbf08835 | 2026-07-05 | `StringBuilder.insert`/`append` past the buffer | bounds check |
| b269ad0b | 2026-06-23 | `x in lo..hi step s` widened the step-alignment difference past `i64` | integer overflow trap |
| 5eafcd19 | 2026-08-12 | the lazy-list chain: four roots starting from an index overflow | integer overflow trap |
| f25af403 | 2026-08-11 | mixed-width integer division by zero panicked instead of raising `ArithmeticException` | division-by-zero trap |

What the safe tier did not catch: the construction-site static heads
crash (2b31f971, 2026-09-04) reproduced only on ReleaseFast, where the
dangling thread-local pointers were read before any fill could mark them;
the GC minor-mark self-deadlock (25dcfa5c) is a lock-order defect no
check sees.

## Log

- 2026-09-05: opened from the compute-floors profiles.
