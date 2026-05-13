# Interpreter

`klio-interp` is a tree-walking interpreter that drives a typed AST
to completion. It does not produce bytecode and does not maintain a
separate IR; every expression is evaluated directly off the AST node
the parser produced.

## Values

`klio_runtime::Value` is the union of every runtime representation:

| Variant                       | Notes                                                              |
|-------------------------------|--------------------------------------------------------------------|
| `Int`, `Long`, `Short`, `Byte`| Signed integers stored as the natural Rust width.                   |
| `UInt`, `ULong`, `UShort`, `UByte` | Unsigned counterparts (parser+typeck scaffolding in place).    |
| `Double`, `Float`             | IEEE 754 — `Float` is stored as `f32` for byte-identical parity.    |
| `Bool`, `Char`, `String`      | Strings are `Rc<String>` for cheap sharing.                         |
| `Range`                       | Inclusive integer progression with signed step.                     |
| `Function`, `Lambda`          | Closure with captured env.                                          |
| `Intrinsic`, `BoundMethod`    | Native `StdlibFn` references (stdlib + pack bindings).              |
| `Class`, `Instance`           | User-defined class metadata and per-instance state.                 |
| `Array`                       | Boxed or primitive-typed array with shared mutability.              |
| `List`, `Map`, `Set`          | Collection literals & builders.                                     |
| `CoroutineSuspended`          | Sentinel returned by suspending calls awaiting resume.              |

`InstanceData` carries each instance's fields, identity counter, and
an optional `native_state` slot used by host bindings (e.g.
`kotlinx.io.Buffer` stashes its `VecDeque<u8>` there).

## Dispatch

The interpreter resolves callable expressions through a layered
lookup:

1. Per-instance method tables (for user-defined classes).
2. Installed-binding table populated by loaded packs.
3. The static `klio_stdlib::implementation` table.
4. The user's top-level scope.

When a pack-source file registers a top-level Kotlin function whose
qualified FQN matches an installed native binding, the loader binds
the simple name to `Value::Intrinsic` instead of `Value::Function`.
This is what makes shim libraries Just Work: the Kotlin body in the
shim acts as a documentation stub; the native binding wins at
dispatch.

## Coroutines

The interpreter natively understands `suspend` (spec §18):

- `runBlocking { ... }` is recognised at the call site and drives
  the suspend-lowered body to completion.
- `suspendCoroutine` / `suspendCoroutineUninterceptedOrReturn` push
  a `ContinuationSlot` onto a stack and yield `COROUTINE_SUSPENDED`.
- A resumed continuation steps the state machine produced by
  `suspend_lower::lower` until completion.

The high-level `kotlinx.coroutines` API (Dispatchers, CoroutineScope,
launch/async, Channel, Flow) lives in the `kotlinx.coroutines` pack
on top of this primitive surface.

## Output

All printed values flow through the `klio_runtime::Output` trait so
the REPL, smoke harness, and parity sweep can capture stdout
without diverting `println!` directly.
