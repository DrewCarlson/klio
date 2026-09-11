# The native C backend

Compile a klio program to C that stands on its own: the emitted code IS the
program, the runtime is a library it calls, and nothing loads a pack or an
image to find out what to do next. Target is JIT parity or better, reached
ahead of time.

## What exists today, and why it is not that

`klio transpile` emits 385 lines that are identical for every program: the
frozen `Value` layout, a handful of inline accessors, and

```c
int main(void) { klio_transpiled_register(); return klio_rt_run_program_image("prog.klio-image"); }
```

The program is the `.klio-image` beside it; the C is a launcher. Two earlier
attempts sit behind env vars:

- `KLIO_TRANSPILE_OPHELPERS=1` emits one call per instruction. Every helper
  takes `(ctx, block, inst_idx)` — `klio_op_escape(ctx, 3, 7)` means "run
  instruction 7 of block 3". That is an interpreter with an extra indirection,
  it needs the module's `Inst` tables at run time, and it measured ~10x slower
  than the interpreter's own drivers. Recorded as "the native floor".
- `KLIO_TRANSPILE_LEAVES=1` emits real C bodies for pure scalar functions. It
  works: `big_callee` runs 247.6ms against the interpreter's 939.4ms. But it
  loses to the JIT's 179.9ms, because every local is a `(int64_t value, int
  grade)` pair and every `+` expands to a grade-dispatch tree. It is the
  interpreter unrolled into straight-line C.

The lesson from both is the same, and it is not "C loses". It is that
**untyped lowering loses**. The JIT wins on identical code because
`inferTypes` gives it static register types, so `+` compiles to `+`. Doing
that inference ahead of time is the whole point of this backend.

A third defect: the leaves path emits **zero leaves for every program**. The
whole-program image path keeps functions in a lazy header table, and the loop
in `transpileEmitLeaves` that walks that table only runs when
`KLIO_TRANSPILE_PKGS` is set. `fun mix(a: Int, b: Int): Int` produces nothing
by default.

## Principles

1. **The emitted C never names `(block, inst_idx)`.** No instruction indices,
   no module at run time, no image load. Constants are C data, functions are C
   functions, classes are C structs with offsets resolved at emit time.
2. **The runtime is a library, not a driver.** `libklio_rt` keeps the GC, the
   object model, strings, collections and coroutines; compiled code CALLS it.
   Nothing in it decides what the program does next.
3. **Lower `ir.Inst`, not `ir.bc`.** The bytecode is a fused fast path over the
   hot ops with `escape` for everything else; the `Inst` union is the complete
   program. A 1:1 lowering of the bytecode would inherit the escape hatch.
4. **Scalars in C locals, objects in a rooted frame.** The GC is precisely
   rooted with no conservative stack scan, so an object reference in a bare C
   local is invisible to it. Statically-typed scalars live in C locals and need
   no rooting; object references live in the activation's register array, which
   is already a root. This is exactly the split the loop JIT runs today, so it
   needs no GC redesign — and it is why typing is load-bearing twice over.
5. **No JIT in a compiled binary.** Ahead-of-time is allowed to be slower to
   build and must not be slower to run.

## Reuse, not reinvention

`src/ir/jit_loop.zig` already decides everything a code generator has to
decide, and three commits this week hardened it: whole-function type inference
(`inferTypes`, `RegType`), the read/def sets, native field access behind a
class guard, native `List`/array indexing, method splicing on a rebound
receiver, and the deopt contract. The C emitter should consume those decisions
rather than grow a second, weaker model. Where the JIT emits machine code, the
backend emits C.

The deopt contract also already matches: a leaf returning 0 means "the runtime
re-runs this call", which is a deopt. Compiled code keeps that edge for the
shapes it cannot type, so coverage can grow without correctness cliffs.

## Stages

Each stage ends with a standalone binary that runs a corpus subset with no
image, and a number against the JIT on the same program.

**The scalar core.** `Int`/`Long`/`Double`/`Float`/`Boolean`, top-level
functions, `if`/`while`/`return`, direct calls, `println` of a scalar. Static
data for constants, one C function per `ir.Func`, blocks as labels, registers
as typed C locals. This forces the whole pipeline to exist end to end and is
the first honest JIT comparison.

**Classes and fields.** Instances allocated through the runtime, field offsets
resolved at emit time, methods as C functions, virtual dispatch through a
static vtable. Object references held in the rooted frame.

**Strings and collections.** Through the runtime library — `String`, `List`,
`Map`, `Array` keep their current implementations; the emitted code calls them.

**Exceptions.** `try`/`catch`/`finally` and `throw`.

**Closures and lambdas.** Captured environments as heap structs; call through
a function pointer plus environment.

**Coroutines.** `suspend` functions as state machines. The largest piece; the
interpreter's continuation model is the reference.

**The long tail.** Reflection, `::class`, reified generics. Each either
compiles or is named as requiring the runtime, with the deopt edge as the
documented fallback.

## Constraints to design against

- **Whole-program reachability.** The stdlib is Kotlin lowered to IR, so
  "compile the program" includes every library function it reaches. Emitting
  all of it is tens of thousands of C functions; emit the reachable closure
  from `main` instead. This bounds compile time and binary size and improves
  what the C compiler can do.
- **Compile time.** A large C file is minutes of optimizer. Measure it as a
  first-class number, not an afterthought.
- **Identifier stability.** Function ids are not stable across bakes. Emitted
  names must derive from fqn plus signature, not from a fid.

## State

The scalar core runs. `klio transpile --native prog.kt -o prog.c` emits a
program that loads no image, links no runtime and runs no interpreter:
`examples/native_scalar_core.kt` compiles warning-clean under `-Wall -Wextra
-Werror` and prints exactly what the interpreter prints.
`scripts/native-c-check.sh` is the gate; `KLIO_CGEN_TRACE=1` names every
function the subset refuses and why, which is the backlog for widening it.

Measured on a 30M-iteration scalar loop, same output all three ways:

| | |
|---|---|
| interpreter | 5593.6ms |
| loop JIT | 1419.0ms |
| compiled C | 150ms |

9.5x over the JIT, 37x over the interpreter, which settles the premise: the C
compiler inlines across the call, allocates registers and strength-reduces,
where the JIT emits from templates.

Covered: `Int`/`Long`/`Double`/`Float`/`Boolean`, `Const`, `Move`, `LoadParam`,
`BinOp` (with Kotlin's shift masking, `ushr`, and the division-by-zero trap),
`UnOp`, `Not`, the numeric conversions in both their call spellings, direct
calls including recursion, `Goto`/`Branch`/`Return`, and `println` of a scalar
rendered the way the reference renderer does (shortest round-trip from two
significant digits, scientific outside [1e-3, 1e7), `.0` on integral values).

Classes and fields run. A compiled program allocates the runtime's own
instances, so a compiled object traces, prints and flows into collections
exactly as an interpreted one does — there are not two object worlds. Classes
are emitted as descriptors and registered before `main`, because a compiled
program has no module to ask; a field is addressed by the index the emitter
resolved, never searched by name.

The rooting works as the plan said it must. A compiled frame publishes its
reference slots through `klio_nat_enter`/`leave` and the collector walks that
chain as a registered root provider; scalars stay in C locals and are never
published, because nothing on the heap depends on them. Safe points sit at loop
back edges. `examples/native_objects.kt` runs identically under
`KLIO_GC_STRESS=1` — a collection at every safe point — which is what proves
the live reference across its allocating loop is actually published;
`scripts/native-c-check.sh` runs that comparison as part of the gate.

Two things a compiled program has to do for itself, both found by watching a
2M-allocation loop reach 966MB of resident memory: the collector is armed by
the `klio_rt_run_*` entries, which compiled code never calls, and `alloc_perm`
starts true and is cleared by `vmRun`, which it also never calls — so every
allocation was minted program-lifetime and never swept. `klio_nat_init` arms
the collector, and `klio_nat_begin` ends the permanent phase after the class
descriptors are registered and before the body runs. The same loop now peaks at
19.5MB.

Methods compile too: `o.m()` lowers to a static call with the receiver moved
into arg 0, so a method is an ordinary C function taking `this` first, and a
property read inside its own class resolves through the synthesized accessor
name to the same field index.

Strings run. A string is a reference like any other and lives in the published
frame; literals, concatenation (either spelled as itself or as `+` with a
string on one side, which renders the other operand as Kotlin does), `length`
in UTF-16 code units, and strings as class fields all compile.

Once the runtime is linked, EVERYTHING prints through its renderer rather than
`printf`. Two renderers is two chances to drift, and they cannot even share a
stream: `printf` is stdio-buffered while the runtime writes the descriptor, so
mixing them printed correct lines in the wrong order. The scalar core still
uses `printf` because it links nothing at all.

Lists run. `listOf`/`mutableListOf`, `size`, indexing, `set` and `add` are
performed directly against the runtime's own list, reached through whichever
spelling the lowering picked — a member call or a virtual one. A compiled list
IS a runtime list, so it traces and prints like any other.

Element types are carried where they can be known: written down in
`List<Int>`, or inferred from a literal whose elements are one scalar kind.
That is what lets `s + xs[i]` compile to an addition rather than a dynamic
unbox, and a list whose element type is unknown yields an untyped reference
that arithmetic refuses rather than guesses at.

Nullability and top-level properties run. A nullable annotation makes a
reference even of a scalar type (`Int?` cannot live in an `int32_t`); `==`
against a reference is the runtime's structural equality, which a null operand
reduces to a null test; and a field access through null raises the same
NullPointerException the interpreter does, so a missed smart-cast is a thrown
exception rather than a wrong answer. A global is a root for the whole program
rather than a frame slot, and only the globals a program actually references
drag their initializer thunks into the compile — the list carries every
top-level property in the program AND its libraries.

A function's result type is read from the register it returns rather than from
its declaration. An unannotated `var counter = 0` lowers to a thunk whose
declared return type is a placeholder, and trusting it typed the global as a
reference and refused every write to it.

Measured across the example corpus, what the backend refuses now, most common
first: class layout (bodies with properties, supertypes, init blocks), lambdas,
constant kinds it has not mapped (`Char`, the unsigned types), and callee
return types. `KLIO_CGEN_TRACE=1` prints that list for any program.

Body properties compile. The IR carries only a class's constructor parameters
— the Vm builds the rest from the AST — but the BUILT module already holds the
full `ClassDef` per class and the initializer thunk for each body property, so
the layout arrives from there and the lowering needs no change. A class's
fields are its constructor properties followed by its body properties, and each
body property's thunk runs at construction, handed the instance and the
constructor's arguments, which is what the interpreter hands it.

Every class layout is resolved once into a table rather than re-derived per
question; a parameter or receiver only has to BE a reference to be passed, and
the layout is demanded at the point a field is actually read.

`Char`, `Short` and `Byte` compile, each carrying its kind in the box because a
Char prints as a character and arithmetic on any of them yields an `Int`. An
`object` declaration compiles to one instance built before the program runs and
rooted for its life, which is what a name referring to it reads.

One relaxation was worth more than any feature: a value only has to BE a
reference to be passed, returned or stored, and its layout is demanded only
where a field is actually read. Requiring the layout everywhere refused every
interface type — interfaces have no layout and never will. Across a 120-example
sample that took class-layout refusals from 73 to 33 and lambda refusals from
92 to 18, because programs stopped being rejected for types they merely
mentioned.

Interfaces, virtual dispatch, superclasses and lambdas compile. An interface
adds no fields, so implementing one leaves a layout alone; a superclass adds its
own, filled by the argument thunks this class passes up. A virtual call becomes
a dispatcher per slot that compares the receiver's class against the handles
registered at startup — they are runtime values, so a chain rather than a
switch — and a receiver no arm answers raises an AbstractMethodError naming the
method rather than running the wrong body. A lambda whose call site can see
which body it holds is called directly with its captures as leading arguments,
so nothing is allocated and nothing is dispatched.

Two rules earned their keep by being wrong first. A function's result comes
from the register it returns — except a declaration with no body, an interface
method, which has no register and must read its annotation. And a value only
has to BE a reference to be passed, returned or stored; demanding its layout
everywhere refused every interface type, and relaxing it moved more programs
than any feature did.

## Still refused

Measured across the example corpus with `KLIO_CGEN_TRACE=1`, most common
first: classes the emitter cannot lay out (enums, abstract classes,
grandparents, init blocks), lambdas that escape into a value, names that are
neither a declared global nor an object, anonymous object literals, `MakeCell`
(a `var` captured by a lambda), and calls with named or generic arguments.

The distance to the goal is honest: a compiled program must contain every
function it reaches, and compose and the packs are Kotlin that must therefore
compile too. Between here and there sit closures that escape, exceptions,
generics and inline functions, and coroutines as state machines. Each is a
stage of the same shape as the ones above — widen what compiles, verify against
the interpreter, keep refusal total so a gap is never a wrong answer.