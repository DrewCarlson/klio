# Heap

An allocation costs about 47 ns in klio with the JIT (`Point(it, 1).x` in
`mb_ops.kt`) and `IntArray(4)` about 92, against 2.6 and 1.2 on the JVM
with its JIT and 57 and 68 in `java -Xint`. In the recompose profile
allocation is 12% of the main thread and the collector 4%. The goal: an
allocation as cheap as the JVM's in both tiers, and a collector whose cost
follows the live set, without changing what a program can observe.

## What stays

- **Sharing between threads is the JVM's.** Objects never move; a
  reference published to another thread is valid there at once; the cell
  lock's acquire and release order a payload's stores; the write barrier
  records every store of a reference into a tenured cell; a collection
  stops every mutator at a safe point. Nothing here changes a barrier, a
  lock or the stop.
- **Precise and generational.** A cell tenures on surviving a collection,
  minors stop at tenured cells, spanning majors trace between stops on the
  marking thread, and the sweep runs on the sweeper thread while the
  mutators run.
- **Every debug mode keeps working.** `KLIO_GC_VERIFY`, `KLIO_GC_POISON`,
  `KLIO_GC_HIST` and `KLIO_GC_NOFREE` walk or keep every cell on the lists,
  so they allocate every cell the old way.

## Design

**Where a cell lives.** A cell of at most 8 KB that a mutator thread mints
on the process heap, outside the permanent generation, is a region cell:
it is bumped out of the thread's current hole in a 256 KB block. A block
is 2048 lines of 128 bytes; its first lines hold its header and one mark
byte per line. Every other cell (permanent, minted by a thread outside the
mutator set, on the build heap or a test allocator, or larger) is
allocated as before, one slab cell each.

**Which cells are on the lists.** The lists exist to find the cells a
collection frees. A region cell needs finding only when freeing it must
free something else: a payload buffer outside the cell, an instance's
native state or throwable stack. Only those join the lists, at mint or
when they take the buffer. A cell whose payload is all in its cell is on
no list; the collection that finds it white does nothing with it, and its
lines are reused once no live cell overlaps them.

**Marks on lines.** A cell's trace marks every line it overlaps with the
current cycle, a byte that advances when a major begins. A line is live
while its mark falls between the cycle of the last major that finished
and the current one: a major's mark rewrites the lines of every tenured
cell it reaches, a minor marks the lines of the cells it tenures, and
tenured lines stay marked through the minors between majors, so a minor
frees exactly the lines of the nursery cells it did not reach. Dead lines
are reset to zero when their block is swept, so a mark is always within a
few cycles of the current one.

**Blocks through a collection.** Every stop retires every mutator's hole.
The blocks the mutators took since the last collection are swept after
every collection, and every other block after a major: the sweeper first
finalizes the dead cells on the lists, then reads each block's marks and
files it as free, recyclable (at least 8 free lines) or full. A mutator
takes a recyclable block first, then a free one, then maps a new one, and
bumps through each run of free lines in turn. A block in a sweep is on no
list, so no mutator allocates in it until the sweeper has read it; the
marking thread writes only lines of tenured cells, which the sweeper reads
as live either way.

**The trigger.** A thread counts the bytes of each hole it takes, and a
region cell's external bytes at mint, towards the collection threshold,
flushed in 64 KB steps as before.

## Stages

| Stage | What | State |
|---|---|---|
| `heap/regions` | Region cells, line marks, the block sweep, finalizable-only lists. | done |
| `heap/one-alloc` | Done: a primitive array holds its elements after its cell and needs no finalizer, and `new` of a primitive array class with a size makes it without the host call. A region cell's list, map and builder grow their buffers in region memory (`gc.buffer_allocator`), headerless, whose lines the owner's trace marks; a tenured owner whose buffer moves takes the write barrier so the next minor marks the new lines, and the process heap leaves a region buffer alone when it is freed or resized. A collection's count of structural changes is read and bumped with atomics and takes no lock. Left: a collection cell whose buffers are all the region's off the lists (it needs no finalizer), and the host functions that grow a collection outside the intrinsics on region buffers too. | in progress |
| `heap/header` | The header shrinks to what a cell needs. Done: one descriptor pointer for trace, finalize and type name (`GcDesc`), a 32-bit mark, the generation and flags, 32 bytes where it was 48; a region cell carries no refcount and no allocator, and every other cell carries them in a prefix before it (`CellPrefix`), and an instance's identity is the header's spare word, 32 bits as `hashCode` is: a `Point(x, y)` is 112 bytes where it was 160. Left: an instance's slots found after its cell rather than through a slice. | in progress |
| `heap/inline-new` | Done: a class's instance as `new` makes it (cell, class, seeds) is a template the constructor's streams keep; the interpreter's `new` copies it into the hole, and the JIT's `new` bumps the hole, copies the template a pair of words at a time and stores the fields in line, falling to the handler when the hole has no room. A cell over a line that does not fit the hole takes the overflow run only while the hole keeps at least four lines, so a run of cells a little over a line keeps to the hole compiled code bumps. | done |
| `heap/young` | Survival counts before tenure, a floor that follows the collection's cost, a faster mark. | open |

## Measuring

```sh
bench/compose/run.py --jit both --programs bench/interp/programs --rounds 1
bench/compose/run.py --jit both --only hb_recompose,hb_canvas,hb_list,hb_form
```

`KLIO_GC_REGION=0` allocates every cell the old way, for an A/B in one
binary. `KLIO_GC_DEBUG=1` reports each collection and each sweep.

## Log

- 2026-09-29: region heap and one-allocation primitive arrays. Operations,
  ns, JIT off: object allocation 49.8 to 33.0, `IntArray(4)` 138 to 64.1
  (`java -Xint` 56.8 and 68.3), string template 122 to 90; JIT on: object
  allocation 48.5 to 28.1, `IntArray(4)` 92 to 18.2. Compose frames, JIT
  off, `KLIO_GC_REGION` on against off in one binary, twice each: 300
  changing texts 77.5 to 72.5 ms, list 2.00 to 1.93, form 0.21 to 0.19,
  circles 8.04 to 7.99; the texts' peak footprint 179 to 189 MB. Where an
  allocation's time goes with the JIT (`Point(i, 1)`): the `new` handler
  32%, `newTrailing` 17%, `instantiate` 13% (an atomic per instance for its
  identity among them), compiled code 30%, the hole refill 5%.
- 2026-09-29: `new` from a template. Object allocation, ns: JIT off 33.0
  to 29.7, JIT on 28.1 to 18.5 (`java -Xint` 56.8, JVM JIT 2.6). Before the
  hole rule, 16 of every 20 compiled `new`s fell to the handler: a
  160-byte instance left a 128-byte rest that the rule kept for smaller
  cells, so the hole never refilled. With the JIT, a loop making `Point(i,
  1)` and reading `.x` is now about 150 instructions, most of them the
  baseline tier's: every register in memory, a type check per operand, the
  field read's sequence protocol, the write mask; the allocation itself is
  about a third. An identity add with acquire and release ordering waited
  for the template's stores to drain; the counter only needs a relaxed
  add (`ldadd`).
- 2026-09-29: an instance takes its identity number on the first ask
  (`hashCode`, `toString`, an identity-keyed map), with a relaxed
  compare-and-swap, compiled code taking it in place; `new` no longer adds
  to a counter every allocating thread shares. With the JIT, ns: object
  allocation 9.46 to 8.52 (`mb_ops.kt`), a value class made 5.49 to 4.69,
  an allocation in a nested loop 9.2 to 8.3, an allocation then its
  `hashCode` 10.1 to 9.6. Of that nested loop's 8.3 ns the collector
  takes 0.14 (1161 minors over 60M dead objects); the rest is compiled
  code, a third of it the allocation (the bump and a 160-byte template
  copy) and the rest the baseline tier's register traffic.
- 2026-09-29: a smaller header. Every region cell 40 bytes smaller: the
  header's trace, finalize and type name one descriptor pointer, its mark
  32 bits, the refcount and allocator in a prefix only other cells carry.
  With the JIT, ns: `IntArray(4)` 6.77 to 5.97, object allocation 8.50 to
  7.84, string template 84.4 to 81.6; interpreted about 1% faster. Peak
  resident memory holding 3M `Point`s and 1M strings 837 to 700 MB.
- 2026-09-30: an instance's identity moved into the header's spare word,
  16 bytes off every instance (a `Point` 128 to 112). With the JIT, ns:
  object allocation 7.65 to 7.3, an allocation then its `hashCode` 9.05 to
  8.7. Peak memory holding 3M `Point`s and 1M strings 699 to 653 MB.
- 2026-09-30: collection buffers in region memory. Lists, maps and
  builders grown through the intrinsics, and lists `listOf` and its kin
  make, take their buffers from the thread's region hole instead of the
  process heap, and their finalizers' frees of those do nothing; a
  collection's structural count is atomic, so an append or a put takes one
  lock where it took two. With the JIT, ns: an `ArrayList` made and four
  adds 117 to 84, a `HashMap` made and two puts 104 to 78, a
  `StringBuilder` made, appended twice and read 186 to 152; interpreted 161
  to 122, 146 to 115 and 195 to 171.
