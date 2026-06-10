# The Vm

klio executes a register-based intermediate representation. The
front end lowers each source file to IR; the Vm in `interp_ir`
runs that IR to completion. There is no AST evaluator on the
execution path.

## Lowering

`ir` turns an `ast.KotlinFile` into a `Module`:

- **`Func`** — a lowered function body: a list of basic blocks, each
  a sequence of `Inst` ending in a `Terminator` (branch, return,
  switch). Top-level functions, methods, constructors, accessors,
  lambda bodies, and suspend state machines are all `Func`s.
- **`Class`** — class metadata: field layout, method table,
  supertypes, and the `FuncId`s of its constructors and init blocks.
- **`Module`** — the program: functions, classes, globals, top-level
  properties, extensions, type aliases, and the intrinsic/binding
  registry.

Every supported construct lowers to structured IR. Lambdas become
closures with explicit captures; mutable captured variables go
through shared cells; `suspend fun` bodies become state machines
with explicit resume edges; reflection references resolve to
`ClassId` / `FuncId`; data-class members (`equals`, `hashCode`,
`toString`, `copy`, `componentN`) are generated as real `Func`s at
class-lowering time.

## The Vm

`interp_ir.Vm` holds the module, the mutable globals, the
coroutine scheduler, and the call stacks. `Vm.fromBuilt` consumes
a `BuiltModule` (produced by `interp_ir.build`) and returns the
Vm plus the entry `FuncId`; `Vm.run(main, out)` executes it.

Execution is a switch over `Inst`:

- Register moves, constants, arithmetic, comparisons.
- Field access by index against a class's static field layout.
- Calls: direct (`FuncId`), virtual (method table walk over
  supertypes), closure (`CallValue`), and intrinsic.
- Object construction, including constructor chaining and init
  blocks.
- Coroutine suspend/resume against the scheduler.

## Values

Runtime values are `runtime.Value`: the Kotlin primitives
(`Int`, `Long`, `Double`, `Float` stored as `f32` for byte-identical
parity, `Bool`, `Char`, `String` as a reference-counted `StringRef`,
the unsigned siblings), `Unit` / `Null`, integer `Range`, collections
(`List`, `Set`, `Map`, `Array`), user `Instance` data, closures,
bound method references, exceptions, and the `CoroutineSuspended`
sentinel.

`InstanceData` carries each instance's fields plus an opaque
`native_state` slot that host bindings use for per-instance native
state (for example `kotlinx.io.Buffer` stashes a byte
`std.ArrayList(u8)` there).

## Object and companion initialization

`object` singletons and companions initialize lazily, matching
kotlinc: construction happens at the first access (bare-name read,
qualified member access, `::class.objectInstance`, a pack native's
lookup), and a companion additionally initializes at the first
instantiation of its owning class — the class's own companion before
its ancestors'. A never-referenced object never runs its
initializers. Property initializers and `init` blocks run interleaved
in declaration order, for object declarations and object expressions
alike.

Initialization is once-only across threads: a shared per-program
state table (`Vm.object_states`) serializes the first-access claim.
The claiming thread constructs and publishes into globals only after
construction completes; other threads racing the same name wait, and
the constructing thread's own re-entrant reads observe the in-flight
instance (an object may reference itself during its own init). A
throw during initialization propagates to the access site wrapped in
`FileFailedToInitializeException` (an `Error`, not an `Exception`)
with the user throwable as its cause; the initializer is never
retried — every later access throws the same wrapper without the
cause. Top-level property initializers stay eager (file order at
program start), matching kotlinc's main-file semantics.

## Dispatch and intrinsics

Stdlib and pack functionality is host-bound. The Vm does not special
-case specific FQNs: `stdlib.implementation(fqn)` is the single
resolution path, and higher-order stdlib functions (`map`, `fold`,
`forEach`, `apply`, `let`, …) receive a callback to invoke a closure
argument back through the Vm.

When a pack ships a Kotlin top-level function whose FQN matches an
installed native binding, the loader binds the name to the intrinsic
instead of the lowered Kotlin body. This is why shim libraries work:
the Kotlin source documents the surface, and the native binding wins
at dispatch. See [Native Bindings](../packs/native-bindings.md).

## Coroutines

`suspend` is implemented natively (Kotlin Language Specification §18):

- A `suspend fun` lowers to a state machine — a `switch` on the
  state register into per-suspension-point blocks, with explicit
  resume edges that read the resumed value into a destination
  register.
- A continuation carries its function, state, captured locals, and
  module reference; `resume` / `resumeWithException` step the state
  machine forward.
- `runBlocking` is a stdlib intrinsic that pumps the scheduler until
  the lambda's continuation reports completion.

The high-level `kotlinx.coroutines` API (scopes, dispatchers,
`launch`/`async`, `Channel`) layers on top of these primitives via
the `kotlinx.coroutines` pack.

## Output

All program output flows through the `runtime.Output` interface so
the parity sweep and pack smoke harness can capture stdout without
intercepting writes to the real stdout directly.
