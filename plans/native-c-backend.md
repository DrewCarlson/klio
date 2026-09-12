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

Inheritance chains compile. A class is initialized by its own emitted
initializer, which fills an instance the caller allocated and hands that same
instance up to its superclass's; the layout is the flattened chain, superclass
fields first, so a field index means the same thing read through any type in
it. The one-level model this replaced spliced a superclass's argument thunks
into the construction site, which could not compose one class's thunks through
another's — so a grandparent was refused — and could not lay out an abstract
base at all, though only its subclasses are ever constructed.

That work also fixed a typing hole under it: a synthesized accessor's
parameters were all typed Unit, so a body-property initializer reading
`side * 2` off an `Int` constructor parameter was an operation on two unknowns.
They now carry the types they were declared with.

Exceptions match by type, not by name. The program's throwable types are
numbered in preorder from the module's own class table — user types and the
ones the stdlib pack declares alike — so every subtype of a type occupies one
contiguous interval. A thrown value carries its own number and a handler
compares it against two integers, which makes `catch (e: AppError)` see an
AppError subtype however deep it sits at the same cost as catching the exact
type. Nothing about the hierarchy is written into the emitter: a name the
lowering did not declare is refused rather than assumed.

A `return` out of an armed try region restores the handler stack it found on
entry. Leaving a region without reaching the block that disarms it left it
armed after the frame was gone, and the next region armed anywhere chained onto
a `klio_try` that no longer existed.

Enums compile. Each entry is one instance built before the program runs and
rooted for its life, exactly as an `object` declaration is; every entry carries
its own `name` and `ordinal`, which is what a comparison, a print and a `when`
over the entries read, and the enum's constructor runs with the arguments the
entry's declaration writes. The enum's own name is a QUALIFIER rather than
storage: `Color.RED` is a register that names a class, typed Unit with the
class recorded, resolved at emit time and occupying nothing at run time. That
shape was behind most of what the backend had been calling an undeclared
global.

Default arguments compile. A default belongs to the call, not to the body: the
callee takes every parameter like any other, and a call that omits one runs the
thunk its declaration lowered, handed the arguments ahead of it. Each lands in
a C local first, because a later default may read an earlier one — and the
local's type comes from what the thunk's COMPILED body returns, not from its
declared return type, which for a synthesized thunk is a placeholder.

A member call the lowering left by name resolves here. The declaration it binds
to is the topmost one on the receiver's chain at that name and arity, which is
the same slot a resolved `CallVirtual` would name, so both go through one
dispatcher and an override answers either spelling.

The typing pass walks blocks in reverse postorder. Source order does not put a
definition before its uses: a `when` writes its result in the arm blocks, which
sit after the block that returns it, so every `when` whose value was returned
refused as an undefined register.

Arrays compile. A primitive array is a packed scalar buffer, so an `IntArray`
holds int32 elements and an indexed read is a load rather than an unbox; the
element kind comes from the array's own type name. A reference `Array<T>` holds
boxed values and says what it holds in its type argument. An array is a runtime
value rather than an instance the emitter lays out, so constructing one drags
in no class descriptor and no initializer.

Scope functions compile. `with`, `apply`, `let` and `run` splice their bodies
inline and push their subject onto the interpreter's implicit-receiver chain,
which exists for resolution at run time. Compiled code has no chain: the
emitter walks the same receivers once, at emit time, and a bare name inside
such a body becomes the field, the accessor, or the top-level property it
actually meant. The chain instructions themselves are then nothing to emit.

A property the source left unannotated takes the type its initializer computes.
Asking the initializer needs the layouts resolved so far — including the fields
of its own class ahead of it — so the class table is built to a fixed point
rather than in one pass, publishing each round's partial layout for the next to
build on. A class still missing a property at the end has no layout at all: a
partial one would address the wrong field.

A register lives in one C local, so it holds one machine type. The lowering
declares a result register by writing Unit into it before the body that fills
it runs; that is a placeholder rather than a second type, and the constant is
emitted in whatever spelling the register settled on. Two genuinely different
types in one register is refused rather than silently resolved to whichever
write came last, which is what it had been doing.

Function values compile. A lambda whose value has to exist becomes an instance
of a class the emitter synthesizes for that body, one field per capture: the
collector traces it like any other instance, and a call through the value finds
the body again by its class handle, exactly as a virtual call finds an
override. A lambda every use of which is a direct call is still never
materialised, so the case the JIT cares about allocates nothing.

Arguments and results pass boxed through a function value, because which body
runs is a run-time answer and two bodies of the same shape need not agree on
machine types; one adapter per body unboxes into the body's real signature. A
lambda's own parameters carry no declared types — the source writes
`{ x -> x + n }` — so they come from the function type the value is expected to
have, read off where the value goes: the declaration's return type when it is
returned, the parameter's or the constructor's when it is passed.

A builtin type's name used as a qualifier resolves to the language's own
numbers. `Int.MAX_VALUE`, `Double.NaN`, `Long.SIZE_BYTES` and the rest are
constants of the language rather than something a pack computes, so the emitter
writes them directly; the register naming the type carries no value at all.
That one shape was the first refusal in 380 of the example programs, because
the stdlib's own property initializers reach for it.

Named arguments reach the callee in ITS order. A call binds positional
arguments in order and named ones by name, and a parameter nothing binds takes
its default — the same rule for a constructor as for a function. Type arguments
say nothing about which body runs for a call the lowering already resolved, so
they no longer refuse one.

### One implementation, not two

`libklio_rt` is built from the interpreter's own modules, so a `klio_nat_*`
entry is a C-ABI shim over the same code the interpreter runs: the collector,
the object model, strings, lists, arrays, maps, exceptions, structural
equality, and the value RENDERER. 96 of the 97 entries delegate; none
reimplements.

The emitter had one real duplicate: 44 lines of C reproducing Kotlin's float
rendering, for programs that linked nothing at all. That is gone — everything
prints through `klio_nat_println`, so how Kotlin renders a value is stated once
— and division by zero now raises a real throwable rather than printing its own
copy of the message.

What remains in the emitter is code GENERATION, not runtime code: the
arithmetic expressions themselves (wrapping add, masked shifts), the `setjmp`
machinery for `try` — which cannot move into a library, because `setjmp` has to
be called in the frame that catches — and the frame/dispatch glue. The
arithmetic rules are stated in two places and could drift, which is exactly
what `native-c-sweep.sh` exists to catch: it found the overflow bug.

### What is general and what is an intrinsic

Everything that decides program shape is general and applies to a pack class
exactly as it does to a user class: layouts and the inheritance chain, virtual
dispatch, closures, default arguments and named ones, catch intervals, the
bare-name resolution inside an inlined receiver body, and the type each
register settles on. None of it names a type.

What is named is the set of stdlib declarations with no Kotlin body — `expect`
or external, implemented by the platform. `println`, `print`, `max`, `min`,
`abs`, `listOf`, `arrayOf` and its siblings, `emptyArray`, `arrayOfNulls`, the
array constructors, `Int.MAX_VALUE` and the other language constants: there is
no body to compile, so the emitter performs the operation. That is the same
reason the interpreter has builtins for them. The one place this leaked into
the general machinery was the array constructor's `(size, init)` form, which
had grown its own scan for "is this lambda an array initializer"; it now feeds
the ONE mechanism that answers what type a lambda is expected to have, as one
more declared signature among the callee's own.

Two rules earned their keep by being wrong first. A function's result comes
from the register it returns — except a declaration with no body, an interface
method, which has no register and must read its annotation. And a value only
has to BE a reference to be passed, returned or stored; demanding its layout
everywhere refused every interface type, and relaxing it moved more programs
than any feature did.

## Coroutines: one driver, two kinds of frame

The coroutine driver — the scheduler, the virtual clock, the Job graph, the
park/resume order, `delay`, `runBlocking` — is 3800 lines of the interpreter's
most delicate code. A compiled program must not get a second one: two
schedulers would drift on exactly the ordering questions that are hardest to
get right.

So the driver is now host-generic, and a compiled program presents its own
host. It asks for two things — start a queued block, resume a parked
continuation — and in a compiled program both are native calls. A parked
activation is a `FrameSnapshot` as before, with one new shape: a COMPILED
continuation, the emitted resume function plus the heap frame it resumes into.
Replaying one is a call rather than a frame rebuild, so a purely-compiled
suspension needs no module, no register file to rebuild, and no evaluator
instantiated against a stub host.

The protocol compiled code follows:

- a suspending call answers its result or `klio_nat_suspended()`;
- a frame that sees SUSPENDED saves its resume label and calls
  `klio_nat_coro_park(resume_fn, frame)`, which appends its continuation to the
  suspension being built and answers SUSPENDED in turn — so the state is built
  innermost-first as the C stack unwinds, which is the order the driver
  replays;
- `delay` is the same with a wake time;
- `runBlocking` enters `driveRootNative`, which is `driveRoot` with the start
  replaced by a native call and everything after it identical.

### The emitted side

A `suspend` body compiles to a state machine over a HEAP frame. Its registers,
parameters and captures are frame fields rather than C locals, because the body
returns in the middle of itself and is re-entered later — a local would not
survive that. The frame is rooted for as long as it exists, since the collector
never scans the native stack and a parked frame is on no thread's chain at all.

Each body emits three pieces: `kfr_N`, the frame; `kcf_N`, which builds one;
and `kco_N`, the continuation, entered fresh and again at every resume through
a `switch` on the saved label. The declared entry builds a frame and runs it.

At a suspending call the state is saved first; if the callee answers SUSPENDED
this frame records its own continuation and answers SUSPENDED in turn. `delay`
is the primitive: the wait IS the suspension, so it parks the calling frame
directly rather than calling a body. `runBlocking` hands the driver a frame it
built but did not run.

A body the lowering did not MARK `suspend` still needs the shape when it calls
something that does — a `runBlocking` block is written without the keyword.

When an inner frame suspends AGAIN during a replay, the frames outside it have
not run yet: they are still waiting on the value it will eventually produce, so
they move to the new suspension. Dropping them stranded every caller of a
function that suspends more than once, which is what a `delay` in a loop is.

`launch { … }` queues a child on the driver that is running. The driver is
handed the closure VALUE, so a compiled program registers a STARTER per lambda
class: the emitted entry that unpacks that closure's captures and runs its
body. That is how the driver finds code to run when all it holds is a value.
A child with no enclosing pump runs eagerly through whichever host is driving —
the interpreter invokes the callable, a compiled program starts the emitted
body.

## Correctness net

`scripts/native-c-check.sh` is the gate: a fixed set of programs that must keep
compiling warning-clean and printing what the interpreter prints, including
under `KLIO_GC_STRESS=1`. `scripts/native-c-sweep.sh` is the wider net: it
compiles EVERY example the backend accepts and compares it, so a program the
backend takes and then gets wrong surfaces without having to be in the curated
set. It found eight, and each was a real hole rather than a missing feature:

- Kotlin's integer arithmetic wraps; C leaves signed overflow undefined and an
  optimizer may assume it never happens. Add, subtract, multiply and negate now
  run in the unsigned type of the same width, and the most negative value
  divided by -1 is handled where C's division is undefined too.
- A register's type is what its C local declares, and the lowering reuses one
  register for values of both shapes, so a call's result and its arguments
  convert at the point of use rather than assuming the declaration.
- A class that does not override still answers a dispatcher with what it
  inherits, from a superclass or from an interface's default body. It had been
  answering with AbstractMethodError.
- An override may declare parameters the call site omits; the dispatcher runs
  their default thunks.
- A class satisfying an interface by DELEGATION has the member and no body for
  it. That is refused rather than compiled into a missing arm.
- An `init { … }` block is not carried by the IR, so a class with one was being
  constructed without running it. Refused.
- A Unit result is still a result. Boxing or unboxing one returned a bare
  constant and DROPPED the expression that produced it, so a call whose value
  is Unit — which is most calls — never happened when it went through either.
- Kotlin renders a value by calling its `toString`, so a compiled program calls
  it too rather than handing the value to the runtime's renderer, which knows
  the shape of a class but not what the program wrote for it. The descriptor
  the emitter registers now records whether a class is data, an enum or an
  object, so the renderer answers the same way for the shapes with no override.
- A constructor argument whose class is not the field's is a call to a
  SECONDARY constructor, which runs a body the emitter does not have. Matching
  arity alone made it look like the primary and stored the argument as it came.
  Refused.
- A property declared without storage where the receiver stands — an
  interface's `val` — reads through a dispatcher on the receiver's class, and
  an override that STORES it answers with the field.
- A property with a declared getter is READ through it even when it also has a
  backing field; only a `field` access inside the accessor reaches the storage.
  Reading the field directly skipped every custom accessor in the program.
- A condition is a Boolean in Kotlin even when it arrives boxed, so it unboxes
  at the branch rather than being tested as a reference.

ONE place decides how a property is accessed — field, accessor, or dispatcher —
because the typing pass, the emission, the reachable set and the dispatcher
list all have to give the same answer, and they had drifted: the emitter called
a dispatcher the collector had decided not to emit.

`$sgetter$<owner>` is NOT a backing-field access. It is an ordinary property
read that names the owner it was written against and resolves to whatever the
receiver's own class declares; only `__klio_field__` bypasses the accessor.
Reading the first as the second refused 381 of the example programs at once,
which is how obvious it was.

Init blocks run. They were already lowered as thunks taking the instance and
the constructor's arguments, so the layout carries them with the body-property
index each one runs BEFORE, and a class's own declarations run in source order:
an init block sits between the properties it was written between. A backing
field holds its type's zero from ALLOCATION rather than from its initializer —
the class descriptor names each field's zero — so a superclass constructor that
calls an overridden method sees the subclass's field as 0/false/null, exactly
as on the JVM.

Unsigned integers compile. Kotlin's are VALUE classes over the signed widths,
so they hold the same bits and constructing one — which is what `n.toUInt()`
does — reinterprets rather than allocates; only comparison, division and the
right shift read them differently, which is exactly what C's unsigned types
give. An unsigned type mixes only with its own kind, because Kotlin has no
implicit conversion between a signed and an unsigned integer.

A class answers a virtual slot only if its TYPE includes the declaration. Name
and arity alone made every same-named method across the stdlib look like an
override, so one `next()` call pulled whole families of unrelated iterators
into the compile and the program refused on one of them. With that and the
unsigned types, a `for` over a range compiles.

The sweep now reports every accepted program matching the interpreter.

## Still refused

Measured across the example corpus with `KLIO_CGEN_TRACE=1`, most common
first: `runBlocking` and the rest of the coroutine surface, calls with named or
generic arguments, the `List` members the backend performs directly, anonymous
object literals, `MakeCell` (a `var` a lambda captures), `finally`, and the
companion-object side of a class name used as a qualifier.

A refusal is reported against the thing that blocked a program, not against
every candidate the emitter examined. The class-layout table is built for every
class in the module, so reporting during the build named classes nothing ever
asked about — mostly library interfaces, which have no layout by their nature,
and which made up 93 of 125 layout refusals in one sweep.

The distance to the goal is honest: a compiled program must contain every
function it reaches, and compose and the packs are Kotlin that must therefore
compile too. Between here and there sit closures that escape, exceptions,
generics and inline functions, and coroutines as state machines. Each is a
stage of the same shape as the ones above — widen what compiles, verify against
the interpreter, keep refusal total so a gap is never a wrong answer.