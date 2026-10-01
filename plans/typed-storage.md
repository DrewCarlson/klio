# Typed storage

Every register, field, argument and collection element in klio is a
`Value`: an eight-byte payload and a tag, sixteen bytes, whatever the
static type says it holds. The JVM stores an `Int` field in four bytes, a
reference in four or eight, and knows from its types which is which, so it
checks nothing when it reads one. A `Point(x: Int, y: Int)` is 112 bytes in
klio (a 32-byte cell header, the instance record, a slots pointer, two
16-byte slots) and 16 to 24 on the JVM; every register write stores a tag
beside its payload and every read of an operand checks one. The JIT's kinds
analysis takes most tag checks out of compiled code, but nothing takes the
bytes out of memory: a program holding 3M Points and 1M strings peaks at
653 MB.

The goal: storage laid out by static type wherever the static type fixes
the representation, the tagged `Value` only where it does not (`Any`, a
type parameter, a nullable primitive), with no change to what a program can
observe.

This plan follows `plans/frames.md`: the frame rewrite's liveness maps are
the reference maps typed frames need, and its single frame layout is the
one place registers change shape.

## What stays

- **Kotlin's semantics, boxing included.** An `Int` stored as `Any` is a
  value a program can compare, hash and print exactly as today; `===` on
  boxed numbers answers as the JVM's does (klio's rules, already matched
  against kotlinc, do not move).
- **The JVM's sharing between threads.** A field of eight bytes or fewer
  is read and written in one access, as the JVM's `int`, `long` (on
  64-bit) and references are; a `@Volatile` field keeps its ordering; a
  reference field published to another thread is valid there at once. A
  16-byte tagged field keeps today's plain-slot protocol.
- **Precise collection.** The collector finds every reference: in a typed
  frame through its reference map, in a typed object through its class's
  layout, in a tagged slot through its tag.
- **Host code sees `Value`s.** Natives, the stdlib's host functions and
  the packs' bindings keep taking and returning `Value`; the boundary
  converts, as the JVM boxes at a generic call.

## Design

**Storage classes.** Sema's type of a register, a property or a parameter
picks one:
- `i32` (`Int`, `Char` as u16, `Short`, `Byte`, `Boolean`, the unsigned
  types of those widths), `i64` (`Long`, `ULong`), `f32`, `f64`: raw bits,
  no tag;
- `ref`: a non-null reference to an instance, a string, an array or a
  collection, eight bytes, its kind in the referent's header;
- `nref`: a nullable reference, eight bytes, zero for null;
- `any`: a tagged `Value`, sixteen bytes: `Any`, `Any?`, a type parameter,
  a nullable primitive, a function value, a value class over any of these.

**Frames.** A function's registers are laid out by class at lowering, the
eight-byte ones first; the frame's liveness map (`frames/maps`) becomes a
reference map (which live slots hold `ref`/`nref`/`any`). Ops come in
typed forms (`add.i32`, `get_field.ref`), chosen at lowering from the
types, so the interpreter checks no tag an operand's static type proves
and the JIT's kinds pass starts from facts rather than guesses. An
operand whose type is `any` keeps today's tag-checking ops.

**Objects.** A class's layout is computed from its properties' storage
classes and its superclass's layout: typed fields at fixed offsets inside
the cell, no slots pointer, eight-byte alignment for the eight-byte
classes, sixteen for `any`. A field read is one load at a constant offset.
The instance record keeps the class, the identity word and the extra
record. `Point(x, y)` becomes a 32-byte header and 8 bytes of fields.
Reflection-like host paths (`toString` of a data class, `equals`,
`copy`, serialization) read fields through the layout's descriptors.

**Arrays and collections.** Primitive arrays already store raw elements.
`Array<T>` and the collections stay `any` elements (their element type is
erased, as on the JVM), with one change: an element known at the site to
be a reference (`Array<String>`) may use an eight-byte `ref` array, chosen
where the array is made, as the JVM's arrays of references are.

**Boundaries.** A typed value passed where `any` is expected is tagged in
place (no allocation: the tag is the static type's); an `any` passed
where a typed class is expected is checked and untagged, which the
checker already guarantees for a well-typed program (a cast's check
stays).

## Stages

| Id | Stage | State |
|----|-------|-------|
| `typed/classes` | Storage classes from sema's types for every IR register, parameter and property; a census of how many registers and fields each class takes over the stdlib, the packs and the corpus. | open |
| `typed/frames` | Frames laid out by class, reference maps from the liveness maps, typed ops for the arithmetic, compares, moves and field access over `i32`/`i64`/`f64`/`ref`. | open |
| `typed/objects` | Class layouts with typed fields in the cell, field ops at constant offsets, the host's field access through layout descriptors, the collector's trace by layout. | open |
| `typed/jit` | The baseline and the optimizing tier compile the typed ops and layouts; the kinds pass seeds from the storage classes. | open |
| `typed/arrays` | Reference arrays for `Array<T>` of a known reference type; element reads with no tag check. | open |

Every stage runs the three gates (regular, JIT-forced, tier-forced) and
reports bytes per object and ns per operation against the stage before.

## Measures

`bench/interp/programs/mb_ops.kt`'s field read, field write, object
allocation and `IntArray(4)` rows interpreted and compiled; bytes of a
`Point(x, y)`, peak memory holding 3M Points and 1M strings; the compose
workloads' CPU time.

## Log

- 2026-09-30: plan.
