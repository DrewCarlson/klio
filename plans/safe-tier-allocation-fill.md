# ReleaseSafe allocation fill — the verification tier's memset tax

Profiles taken for `compute-floors-record.md` (2026-09-05) show `memset` as
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
2. **What ReleaseSafe has caught.** From `ci-green.md`, the census memories,
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

## Log

- 2026-09-05: opened from the compute-floors profiles.
