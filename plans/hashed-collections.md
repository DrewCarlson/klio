# Hashed collections

Two gaps between klio's sets and maps and the JVM's: what an operation
costs, and the order a `HashMap` or `HashSet` iterates in.

## Cost

A set is an ordered list of its elements and nothing else. `add`,
`contains` and `remove` scan it, comparing each element, and `add` copies
the whole list first (the comparison may dispatch `equals`, which must not
run under the list's borrow): building a set of n elements is quadratic.
`HashSet<Int>` with 40,000 adds and 40,000 `contains` takes 17.3 s (5,000:
0.27 s; doubling n quadruples it), where the JVM takes milliseconds. The
builders dedupe the same way: `setOf`, `toSet`, `toMutableSet`, `distinct`,
`HashSet(collection)` and `mapOf`/`mutableMapOf` of many pairs compare
every element with every one kept before it. A map is hashed
(`MapStore`), but removing an entry shifts every later entry and rebuilds
their bucket links, so removing many entries is quadratic too.

The JVM's `HashSet` is a `HashMap` over its elements. The fix gives a set
the same: a `MapStore` index over its elements (each an entry with no
value), which `contains`, `add` and `remove` read, kept in step with the
list by `add` and rebuilt after any other change (the index records the
list's length and write sequence it covers); and the builders dedupe
through a store too, hashing simple values as `MapStore.find` does and
asking the host for an instance's `hashCode` and `equals` where the
builder's comparison does.

## Order

klio keeps every map and set in insertion order, as `LinkedHashMap` and
`LinkedHashSet` do. On the JVM a `HashMap` or `HashSet` iterates in its
table's order: by bucket, `(h ^ (h >>> 16)) & (capacity - 1)` of each key's
`hashCode()`, and within a bucket in insertion order. A program that prints
or iterates one prints in that order, so klio's output differs from
kotlinc's wherever a program uses `HashMap()`, `HashSet()`, `hashMapOf`,
`hashSetOf` or `toHashSet()`:

```kotlin
val m = HashMap<String, Int>()
for (w in listOf("w10", "w3", "w2101", "w1398", "zeta", "alpha", "b", "a")) m[w] = w.length
println(m)
// JVM:  {zeta=4, a=1, b=1, w2101=5, w10=3, alpha=5, w1398=5, w3=2}
// klio: {w10=3, w3=2, w2101=5, w1398=5, zeta=4, alpha=5, b=1, a=1}
```

`bench/memcompare/klio/strings.kt` reports a different most frequent word
for the same reason (it takes the first of the ties in iteration order).

## What decides the JVM's order

- **The key's `hashCode()`**: `String`'s over its UTF-16 units, the boxed
  primitives' (`Long` and `Double` fold their halves, `Boolean` 1231/1237),
  a data class's generated one, a user override. An instance with no
  override, an enum constant or a lambda hashes by identity, which differs
  between JVM runs: any order klio picks for those is one the JVM can
  print.
- **The table's capacity**: a power of two, made on the first insertion
  from the initial capacity (16, or `tableSizeFor(initialCapacity)` for
  `HashMap(n)`), doubled when the size passes 0.75 of it, never shrunk
  (`clear()` keeps it). `HashMap(map)` and `putAll` into an empty table
  size it for the incoming entries first (`tableSizeFor(size / 0.75 + 1)`),
  `HashSet(collection)` makes `HashMap(max(size / .75 + 1, 16))`.
  Kotlin's `hashMapOf(pairs)`, `hashSetOf(elements)` and `toHashSet()` pass
  `mapCapacity(n)` (`n + 1` below 3, else `n / 0.75 + 1`).
- **Within a bucket**, insertion order of the entries present: a resize
  splits a chain keeping its order, a removal unlinks one, a put of a key
  already there keeps its place.
- A bucket of eight or more entries in a table of 64 or more becomes a tree
  whose iteration order follows tree insertion. Out of scope here: it takes
  eight keys with one bucket.

So the order is the insertion order, stably sorted by bucket.

## Design

- `MapData` and `SetData` gain the order they iterate in (`insertion` for
  the linked kinds and everything built by `mapOf`, `mutableMapOf`,
  `setOf`, `groupBy` and the rest, `hash` for `HashMap`/`HashSet` and their
  builders) and, for `hash`, the table capacity the JVM would have.
  `LinkedHashMap`/`LinkedHashSet` get constructors of their own.
- Every insertion into a `hash` store keeps the key's `hashCode()`: the
  value's own for a scalar or a string, the host's for anything else (the
  store keeps that already for maps past the scan threshold; a hash-ordered
  store keeps it at every size), and grows the capacity as the JVM does.
- Iteration goes through one accessor that answers the store's entries in
  order: the stored order for `insertion`; for `hash`, a permutation sorted
  by bucket, kept until the next structural change (the store's mod count).
  Every host path that walks a store's pairs or items in order (iterators,
  views, `toString`, `forEach`, the transforms) reads through it; lookups
  keep indexing directly.
- `is LinkedHashMap` and `::class` answer per kind.

## Stages

| Id | Stage | State |
|----|-------|-------|
| `hash/index` | A set past eight elements keeps a hash index over its list (`runtime.ValueIndex`, its own collected cell, under the list's lock, valid for the list's write sequence it records); `contains`, `add`, `remove`, `addAll`, `containsAll` read and keep it, and a list changed another way builds it again. Each element's `hashCode()` as Kotlin answers it (`Value.javaHashCode` for numbers and strings, the host for an instance, the data-class formula for `Pair` and `Triple`), taken once as the element joins, then `equals` as before. The builders and the operations that dedupe or test membership against another collection (`setOf`, `toSet`, `distinct`, `distinctBy`, `plus`, `minus`, `intersect`, `removeAll`, `retainAll`, the sequences' `distinct`) go through a hashed dedupe (`hashing.Seen`), and the map builders (`mapOf` of pairs, `associate*`, `groupingBy` folds, `Map.minus`) through a hashed key index (`hashing.KeyIndex`). A `Pair` or `Triple` of simple values is a hashed map key (`MapStore.keyHash`). | done |
| `hash/remove` | A removed map entry or set element leaves a hole in its slot, which the index unlinks, and every other keeps its place, as a `LinkedHashMap` unlinks a node; the holes close up (`compact`) once they are as many as the entries, or before a reader that takes the entries as one slice (`MapStore.dense`, `mapBorrowDense`, `SetData.dense`). Lookups, sizes, the walks in order, `remove`, `add` and `put` pass over holes as they stand; the field each store keeps its entries in is renamed (`slots`, `elems`) so every reader chose one or the other. A set's own iterator walks its list over the holes from past the leading ones (`SetData.head`), leaves a hole on `remove`, and finds its place again by the elements it has passed when a compaction moved them (`SetData.epoch`). | done |
| `hash/kinds` | Store order and capacity on maps and sets; the four constructors and the builders choose them; class names and `is` checks per kind. | open |
| `hash/order` | Keys' `hashCode()` kept for hash-ordered stores; the ordered accessor; every in-order walk through it. Examples against kotlinc for strings, numbers, data classes, resizes, removals, `HashMap(map)`, `HashSet(list)`, `hashMapOf`, `toHashSet`. | open |
| `hash/read-only` | A read-only map or set (`mapOf`, `setOf`, a built map) refuses every change with `UnsupportedOperationException`, where the JVM's `mapOf` of two or more pairs is a `LinkedHashMap`: `(mapOf(..) as MutableMap).put`, `setValue` on one of its entries (`map_walks.kt` keeps to mutable maps for this) and a mutation through its views succeed there. Decide whether klio's read-only maps behave as the JVM's do; a built map (`buildMap`) refuses on the JVM too. | open |
| `hash/speed` | Loops over a map and its views are 5 to 9x the JVM's (`interpreter-speed.md`, `collections/map-iteration`). | open |

## Log

- 2026-10-01: plan, from a `bench/memcompare` run against the JVM (the order) and a set-building timing (the cost).
- 2026-10-01: `hash/index`. A program of 20,000 elements a row, ms, before,
  after and the JVM's: `HashSet<Int>` adds and finds 4,516, 4, 5; a set of
  strings 1,196, 3, 6; of pairs 3,759, 7, 7; of data-class instances 76,942,
  36, 10; a `HashMap` keyed by pairs 2,573, 5, 6; `toSet` 278, 6, 10;
  `distinct` 343, 2, 4; union, intersect and subtract 8,326, 19, 9. A
  `hashCode` that throws now reaches the caller, and a user `hashCode` runs
  once for each add, lookup and removal, as on the JVM (the scans never
  called it). Removal is still the list's shift: half of a 20,000-element
  set removed 1,359 to 191 ms, a map's 393 to 376 (`hash/remove`). The
  example under `KLIO_GC_STRESS_EVERY=16` with `KLIO_GC_VERIFY` ran 85,816
  collections with no report.
- 2026-10-01: a live map entry keeps where its key last was in the store and
  checks that slot before scanning, so reading `key` or `value` while
  iterating a map's entries is constant time (20,000 entries: 987 ms to 4,
  and `toSortedMap` 33.8 s to 133 ms).
- 2026-10-01: a map's `keys`, `values` and `entries` were snapshots taken by
  every call: a view held across a change to the map missed it (and a removal
  through a stale view rebuilt the map from the stale elements, dropping keys
  added since), an iterator's `remove` on `keys` or `values` never reached the
  map, and `x in map.keys` copied every key and indexed the copy, so a loop of
  it was quadratic (20,000 lookups: 7,514 ms, the JVM's 3). A map now makes
  each view once and keeps it (`MapData.views`), as the JVM's maps do; a view
  is brought up to its map in the accessors every collection function reads
  through (`views.refreshMapView`: `keys` and `entries` when the map's
  structural count moved, `values` on every read), renders from the map,
  answers `size` and `isEmpty` from it, and `keys` answers `contains` with the
  map's own lookup (7,514 to 2 ms); a view's iterator takes the pair at the
  same position out of the map on `remove`.
- 2026-10-02: `hash/remove`. 20,000 entries, half removed by key, ms, before,
  after and the JVM's: a `HashSet<Int>` 192, 7, 1; a `HashMap<Int, Int>` 377,
  4, 1. Every entry removed from the front by key: a map 767 to 4, a set 279
  to 9; a set emptied by `first()` and `remove` 290 to 18 (the JVM's 10); half
  of a map removed through its entries' iterator 957 to 38 (5); a map kept at
  1,000 entries by a removal and a put per step 46 to 2. Removing through a
  map's `keys` or `values` iterator still finds the entry's slot by position,
  and a map's `entries` iterator and its views still copy the map, as the
  entry above describes. `collection_removals.kt` under `KLIO_GC_STRESS=1`
  with `KLIO_GC_VERIFY` prints the JVM's output with no report.
- 2026-10-02: a map's entry objects threw `ConcurrentModificationException`
  on any read after a structural change to the map, as Kotlin's own
  `HashMap` does on JS and Native, where the JVM's are the map's nodes. An
  entry is its node now: the store keeps a value box per node that an entry
  object was made of (`MapStore.boxes`, shared by every entry of the node),
  an entry reads the map's value while its node is in the map, and a node
  that leaves (a removal, a `clear`) gives its box its last value, so the
  entry keeps it; a key added back is a new node. A `buildMap` builder's
  map (`MapStore.builder`) keeps failing fast, as `MapBuilder` does on
  every platform. The stdlib commontests run as the JVM platform now
  (`TestPlatform.Jvm`), which also asks for the JVM's `toArray(array)`
  null after the last element and `StringBuilder.append(chars, offset,
  len)`; the second is the common library's error-deprecated extension
  there, which a declaration in klio's own library now hides
  (`linkPlatformShadows`), as the JVM's member does. The sweep stays at
  149 files, 0 failures.
- 2026-10-02: a map's `keys`, `values` and `entries` held a copy of the map's
  elements, brought up to the map when it changed (`values` on every read),
  and the map functions copied the entries before walking them. Neither is
  something the JVM or Kotlin/Native does. The views are now classes of klio's
  library over the map, as Kotlin/Native declares them (`HashMapKeys`,
  `HashMapValues`, `HashMapEntrySet` in `MapViews.kt`): `size`, `contains` and
  `remove` go to the map's own lookups, the iterator walks the map's slots
  (`collections.mapIterator`), a `for` loop over a view reads the map by
  position (`ClassDef.map_view`), and a bulk change to a map that may not
  change throws before reading any element. So `values is List` is false,
  `values == listOf(..)` compares identity, `keys` and `entries` compare as
  sets, and `entries.contains` takes an entry of any kind. Printing,
  equality, hashing, `putAll` and `toMap(destination)` walk the entries
  where they stand (`MapWalk`); `toMutableMap`, `HashMap(map)`, `plus`,
  `minus` and `toSortedMap` copy the map once (`MapStore.copyLive`). An
  iterator over a map or a set answers `hasNext` from the element it last
  gave (`IterCursor.ended`), as `LinkedHashMap`'s does: an element added
  after the last ends the walk with no exception. A removal past a small
  map's index now moves `epoch`, which an iterator's next step missed before,
  passing over an entry. Before and after: fifty loops over the `values` of
  20,000 entries 40 to 24 ms (the JVM's 3); equality of two maps of 2,000
  data-class keys in other orders 211 to 1 ms. The sweep stays at 149 files,
  0 failures.

