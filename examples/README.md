# Examples

Runnable `.kt` programs that exercise klio through the real `klio`
binary. Every program here produces deterministic output and passes
the parity sweep — its stdout is byte-identical to `kotlinc`
(Kotlin 2.4.0). The set grows monotonically: every new language
feature lands with at least one example demonstrating it end-to-end.

Run any program with:

```sh
./zig-out/bin/klio run examples/<name>.kt
```

## Language basics

| File                     | Exercises                                                        |
|--------------------------|------------------------------------------------------------------|
| `hello.kt`               | Smallest end-to-end slice: `println(1 + 1)`.                     |
| `showcase.kt`            | Operators and precedence, `val`/`var`, `if`/`when` as expressions, loops with `break`/`continue`, functions, recursion. |
| `functions.kt`           | Default args, recursion, mutual recursion, top-level properties, local functions closing over scope. |
| `compound_assign.kt`     | Compound assignment operators.                                   |
| `do_while.kt`            | `do`/`while` loops.                                              |
| `labeled_jumps.kt`       | Labeled `break` / `continue` / `return`.                         |
| `const_val.kt`           | `const val` and compile-time constants.                          |
| `top_level_computed_val.kt` | Top-level `val` with a custom getter (no backing field) re-evaluating per read. |
| `definite_assignment.kt` | Definite-assignment behavior for `val`.                          |
| `visibility.kt`          | `private` / `internal` / `public` visibility.                    |

## Types, classes, and objects

| File                       | Exercises                                                      |
|----------------------------|----------------------------------------------------------------|
| `classes.kt`               | Primary-ctor properties, methods, `data class`, `companion object`, `object`, `operator fun compareTo`. |
| `inheritance.kt`           | `open`/`override`, super-constructor calls, `super.method()`, polymorphic dispatch. |
| `inheritance_delegation.kt`, `delegated_inheritance.kt` | Interface and inherited-delegate resolution (`by`). |
| `interfaces.kt`            | Abstract members, default methods, multiple interfaces, marker interfaces. |
| `abstract_inner.kt`        | `abstract` classes, secondary constructors, inner classes.     |
| `inner_outer_property.kt`  | An inner class reads the outer instance's overridden property (virtual getter dispatch), incl. an `AbstractMutableList` subclass. |
| `anon_local.kt`, `anon_object_tostring.kt` | Anonymous objects and local classes.           |
| `local_fn_overloads.kt`    | Same-named local functions as true overloads: call-site selection by arity and argument types, one overload calling its sibling (no self-recursion through the shared binding), selection from a nested lambda. |
| `extension_property_delegates.kt` | Delegated extension properties (`val R.x by …`): bound-reference and top-level-var delegates, writes through `setValue`, a custom `getValue` operator receiving the `KProperty`, and bound property references (`obj::extVal`) reading through the delegate. |
| `anon_object_init.kt`      | Anonymous-object initialization: property initializers over the enclosing scope (top-level properties, object singletons, inline-HOF calls, captured locals), supertype ctor-arg expressions, init-block interleaving. |
| `enums.kt`, `enum_companion.kt`, `enum_entries_interface.kt` | Enum entries, ctor args, per-entry overrides, `entries`/`values()`, enum companions. |
| `sealed_when.kt`, `sealed_when_exhaustive.kt` | Sealed hierarchies with exhaustive `when`.  |
| `data_object.kt`           | `data object`.                                                 |
| `object_lazy_init.kt`      | Lazy first-access `object`/companion initialization: unused objects never initialize, init/property interleaving, companion init at first instantiation, anon-object init blocks, init-failure wrapping (`FileFailedToInitializeException`) without retry. |
| `value_class.kt`           | Inline `value class`.                                           |
| `annotation_class.kt`      | `annotation class` declarations.                               |
| `annotated_function_types.kt` | Type-use-site annotations on function types (`@Composable () -> Unit`): params, return types, nullable, receiver, generic args, typealias, property getter, and annotated lambda expressions. |
| `plain_class_tostring.kt`  | Default and overridden `toString`.                             |
| `ir_instance_identity.kt`  | Reference identity of instances.                               |
| `smart_cast_field.kt`, `as_cast.kt` | Smart casts and `as` / `as?`.                         |
| `when_binding.kt`          | `when` with a bound subject.                                    |
| `qualified_this.kt`        | Qualified `this@Label` through inner/outer chains.             |

## Functions, lambdas, and generics

| File                          | Exercises                                                   |
|-------------------------------|-------------------------------------------------------------|
| `anon_fun.kt`                 | Anonymous function expressions.                             |
| `function_types.kt`, `inherit_function_type.kt` | Function types and SAM-shaped values.     |
| `inline_modifiers.kt`         | `inline` / `crossinline` / `noinline`.                      |
| `reified.kt`                  | Reified type parameters in `inline` functions.              |
| `bounds.kt`, `variance.kt`    | Generic bounds and declaration-site variance.               |
| `extension_functions.kt`, `extension_property.kt`, `extension_nullable_receiver.kt`, `companion_extension_property.kt` | Extensions, incl. nullable receivers and companion-object extension properties accessed via the class name. |
| `infix_calls.kt`              | `infix` functions.                                          |
| `scoping_fns_top_level.kt`    | `let` / `also` / `apply` / `run` / `with` / `takeIf`.       |
| `receiver_member_precedence.kt` | Implicit-receiver precedence for bare reads, writes, and calls: innermost receiver first, member over extension within one receiver, receiver member over top-level binding, inner-class nesting tower. |
| `lexical_receiver_scope.kt`   | Lexical (creation-site) receiver scope for closures and anonymous functions: a no-receiver lambda writes the top-level var from inside a member dispatch; a `with`-created lambda keeps its receiver wherever it is invoked. |
| `operator_overload_arith.kt`  | Operator overloading.                                       |
| `tailrec.kt`                  | Direct and mutual tail-call optimization.                   |
| `sam_conversion.kt`           | SAM conversion.                                             |
| `dsl_marker.kt`, `build_helpers.kt` | `@DslMarker` and builder-style DSLs.                 |
| `dsl_dotted_head.kt`          | Dotted-head resolution inside receiver lambdas: a package-qualified head (`kotlin.math.*`) flattens to a global while a receiver-member dotted access walks `this`. |
| `vararg_spread.kt`            | `vararg` and the spread operator.                           |
| `vararg_nonfinal.kt`         | `vararg` before a trailing defaulted parameter, called positionally (top-level, inline, member). |
| `class_factory_overload.kt`  | Same-name factory function vs constructor, disambiguated by argument type and arity. |
| `reified_param_inference.kt` | A reified type parameter inferred from a value/lambda-parameter position (not just the return type). |
| `typealias.kt`                | `typealias`.                                                |
| `captured_var_carrier.kt`     | A captured `var` mutated inside a lambda round-trips identically whether the closure is called directly, passed to a stdlib HOF (`forEach`/`fold`), spliced through an `inline` HOF, or captured across a `launch`/`suspend`. |
| `receiver_across_suspend.kt`  | The enclosing-`this` (implicit receiver) chain survives a coroutine park: a member-extension body suspends at a `delay`, then after resume resolves a bare member of an *enclosing* receiver reachable only through the implicit-receiver chain. Interleaved `async` Owners each resolve their own enclosing receiver (innermost wins). |
| `receiver_bound_suspend_value_call.kt` | A `suspend Receiver.() -> Unit` value invoked with a bound receiver (`b.block()`, where `block` is a fun-typed parameter) parks at a `delay` inside its body and resumes — single park, multiple parks across one body, and two such calls interleaving under `async` each against their own receiver. |
| `inner_class_suspend.kt`      | A bare `Inner()` captures this@Outer as its outer from every construction context: a member body, a `with` receiver lambda (the subject is not captured, even when it declares a same-named property), a user-defined HOF, an HOF lambda, a member of Inner constructing a sibling `Inner()` (through its own outer link, even with an unrelated `with` subject on the caller's chain), a later-declared sibling inner class built from a lambda, and suspend members that park at `delay` before constructing — interleaved `async` Outers each bind their own instance. |

## Properties and delegation

| File                           | Exercises                                                   |
|--------------------------------|-------------------------------------------------------------|
| `delegates.kt`                 | Custom getters/setters, `by lazy`, `Delegates.observable`/`notNull`, user delegate classes. |
| `accessor_return_type.kt`      | Accessor return-type inference.                             |
| `backing_fields.kt`            | Explicit backing fields (`val items: List<T>` + `field = mutableListOf()`): field-typed reads inside the declaring scope, subtyped field types, deferred init-block assignment, top-level fields. |
| `serial_names.kt`              | `@SerialName` wire-name renaming through `Json.encodeToString`/`decodeFromString` under target-less, `@property:`, and `@all:` placements (needs `--feature kotlinx.serialization/json`). |
| `interface_companion_state.kt` | Shared companion-object state on an interface.              |
| `safe_assign.kt`               | Safe-call assignment.                                       |

## Stdlib and runtime semantics

| File                       | Exercises                                                      |
|----------------------------|----------------------------------------------------------------|
| `stdlib_taste.kt`, `stdlib_broad.kt` | `kotlin.math`, String/Int members, conversions.      |
| `collections.kt`           | List/Set/Map builders, `map`/`filter`/`fold`/`reduce`, iteration, indexing. |
| `arrays.kt`                | `Array` and primitive arrays.                                  |
| `array_bytes.kt`           | Bulk array ops (`copyInto`, `copyOf`, `copyOfRange`, `fill`) and `String` <-> `ByteArray` UTF-8 round-trips (`encodeToByteArray`/`toByteArray`/`decodeToString`). |
| `base64.kt`                | `kotlin.io.encoding.Base64`: default / URL-safe alphabets, `PaddingOption`, encode/decode round-trips, and a basic-auth credential header. |
| `string_builder.kt`, `string_ordering.kt` | `StringBuilder`, string comparison.             |
| `char_unicode.kt`          | `Char` and Unicode handling.                                   |
| `utf16_surrogates.kt`      | `Char` as a UTF-16 code unit: astral `String` length/indexing/iteration, surrogate pairs, `isHighSurrogate`/`isLowSurrogate`, `Char.MIN/MAX_VALUE`, `Int`→`Char` narrowing. |
| `numeric_fidelity.kt`      | Integer/float width and rounding fidelity.                     |
| `numeric_literal_coercion.kt` | Unsuffixed integer literals taking a `Long` binding or parameter-default type, including recursive local `tailrec` accumulators. |
| `regex.kt`                 | `Regex` basics.                                                |
| `for_user_iterator.kt`     | `for` over a user-defined `iterator()`.                        |
| `notnull_assertion.kt`     | The `!!` operator.                                             |
| `user_exception_hierarchy.kt` | `throw` / `try` / `catch` / `finally` over a user exception hierarchy. |
| `reflection_lite.kt`       | `::class`, `::member`, basic `KClass` introspection.           |
| `member_references.kt`     | Bound and unbound property / getter / function references, invoked directly and passed as transforms (`map(Class::prop)`, `map(::topLevelFun)`). |
| `top_level_property_reference.kt` | Unbound top-level property references as `KProperty0`/`KMutableProperty0`: `get()`/`invoke()` read a stored or custom-getter `val`, and `set()` writes a `var` through to the real property. |
| `sequence_iterator_builder.kt` | The `iterator { yield(...) }` builder resolves to the coroutine builder rather than the no-arg `Iterator.iterator()` extension. |
| `reified_filter.kt`        | `reified` type parameters: `filterIsInstance<T>()` over lists, and a user-defined `inline fun <reified T>` extension that composes with it. |
| `text_transforms.kt`       | `chunked(size) { transform }`, `Regex.replace`/`replaceFirst` with a `(MatchResult)->CharSequence` lambda and `$group` replacement templates. |
| `map_views.kt`             | Live `MutableMap` `keys`/`values`/`entries` views: `remove`/`removeAll`/`retainAll`/`clear` and `MutableEntry.setValue` write through to the map. |
| `m6b_taste.kt`             | Exceptions, lambdas, scope functions, and the broad numeric/string/char intrinsic surface together. |
| `jit_capture_cell_loop.kt` | A hot loop mutating `var`s captured by a nested lambda (boxed cells); output is identical with the loop JIT off or on. |
| `mutable_iterator_remove.kt` | `MutableIterator.remove()` over a `MutableList` writes through to the source list. |
| `jit_double_loop.kt`       | Hot `Double` arithmetic + comparison over a `DoubleArray` (loop JIT → SSE2); identical output JIT off or on, incl. NaN comparison semantics. |
| `jit_int_double_mix.kt`    | Hot loop mixing an `Int` counter with `Double` math via `i.toDouble()` (loop JIT compiles the int→double conversion inline). |
| `jit_float_loop.kt`        | Hot `Float` (f32) arithmetic/comparison over a `FloatArray` + `Int→Float` conversion (loop JIT → single-precision SSE2); identical output JIT off or on. |
| `generic_stdlib_calls.kt`  | Repeated `maxOf`/`minOf` calls in a loop; overload resolution is cached per `(function, argument-type)` so the hot path skips re-scanning overloads. |
| `jit_float_to_int.kt`      | `Float`/`Double` → `Int`/`Long` in a hot loop with Kotlin clamping (NaN→0, overflow→MIN/MAX); loop JIT compiles the conversion; identical output JIT off or on. |
| `jit_bitwise_loop.kt`      | Hot loop of bitwise infix ops (`and`/`or`/`xor`/`shl`/`shr`) on `Int` and `Long`; loop JIT emits native bitwise/shift ops with correct width-based count masking and sign-extension; identical output JIT off or on. |
| `jit_call_loop.kt`         | Hot loop calling a top-level function each iteration; loop JIT trampolines the call (reboxes scalar args, runs the callee interpreted, reboxes the scalar result) for `Int`/`Long`/`Double`-returning and `Unit` side-effecting callees; identical output JIT off or on. |
| `jit_nested_call_loop.kt`  | Hot outer loop trampolining a call to a function that runs its own hot inner loop (the callee's parameter type is seeded from the live argument); the inner loop runs natively while re-entered from inside the outer native loop; identical output JIT off or on. |
| `jit_member_call_loop.kt`  | Hot loop calling methods on a loop-invariant object; loop JIT trampolines the member call (receiver stays boxed and its class is re-checked at loop entry, scalar args/result move through slots) for `Int`/`Long`-returning and `Unit` side-effecting methods; identical output JIT off or on. |
| `jit_field_read_loop.kt`   | Hot loop reading scalar fields (`Int`/`Long`/`Double`) of a loop-invariant object, including a field mutated through a method then read back; loop JIT trampolines the read as a direct stored-field load (a custom getter falls back to the interpreter); identical output JIT off or on. |
| `jit_object_traversal_loop.kt` | Hot loop walking a linked structure: a boxed cursor reassigned through an object field, an object-vs-null loop guard, a scalar field read and a method call per node; loop JIT keeps the cursor in the register array (a GC root) and drives the traversal natively; identical output JIT off or on. |
| `jit_object_subscript_loop.kt` | Hot loop indexing a polymorphic `List` of objects and dispatching a method on each element; loop JIT reads the element with a direct subscript into a boxed register and dispatches dynamically, re-checking the receiver class each call; identical output JIT off or on. |
| `jit_inferred_return_loop.kt` | Hot loops calling functions/methods with inferred (expression-body) return types; loop JIT infers each callee's scalar return type from its body (params carry declared types, arithmetic promotes per Kotlin) so the result is slot-typed and the call trampolined; identical output JIT off or on. |
| `jit_nullable_scalar_loop.kt` | Null-safe chains whose result is a nullable scalar (`Int?` from `?.` on a scalar field) folded with `?:`; loop JIT carries the nullable scalar as a value slot plus a companion null-flag slot, running the null tests, Elvis default, and arithmetic natively; identical output JIT off or on. |
| `jit_closure_call_loop.kt` | Hot loop invoking a loop-invariant closure (which captures and mutates an outer variable); loop JIT keeps the closure boxed in the register array and trampolines the call while the loop control runs natively; identical output JIT off or on. |
| `jit_map_ops_loop.kt`      | Hot loops storing into and loading from a loop-invariant map; loop JIT trampolines `map[k] = v` and `map[k]` (a nullable scalar folded with `?:`, a missing key reading back as null) while keys, the Elvis default, and accumulation run natively; identical output JIT off or on. |
| `jit_inline_call_loop.kt`  | Hot loop calling small pure functions; loop JIT inlines a single-block scalar callee directly into the native code (registers remapped into an extended space) so the calls become native arithmetic with no dispatch — covering `Int`/`Long`/`Double` results, conversions, and a callee inlined at multiple sites; identical output JIT off or on. |
| `jit_field_store_loop.kt`  | Hot loop reading, computing, and writing back scalar fields (`Int`/`Long`) of a loop-invariant object; loop JIT compiles the stores as direct writes into the boxed receiver's stored fields (plain properties — no custom setter); identical output JIT off or on. |
| `jit_inline_method_loop.kt` | Hot loop calling a small method on a loop-invariant object; loop JIT inlines the method body (scalar arithmetic native, `this`-field reads/writes as direct field accesses) so the per-iteration dispatch is eliminated; a polymorphic receiver would keep dynamic dispatch; identical output JIT off or on. |
| `jit_recursion.kt` | Recursive scalar functions with no enclosing loop (`fib`, `fact`, Ackermann, mutual even/odd); the opt-in whole-function JIT (`KLIO_JIT=1 KLIO_FUNC_JIT=1`) compiles each body and recurses natively through the call trampoline (no interpreter frame per call), while a div-by-zero still raises a catchable `ArithmeticException` via the deopt fallback; identical output with the JIT off, the loop JIT on, or the function JIT on. |
| `string_ascii_fastpath.kt` | String `length`/`indexOf`/`substring`/indexing on ASCII vs non-ASCII text (ASCII takes a byte-length fast path; non-ASCII falls back to a UTF-16 walk). |

## Integration showcases

These exercise many features together — the kind of "tricky but
valid" Kotlin a real program mixes — and are each byte-identical to
`kotlinc`.

| File                       | Exercises                                                      |
|----------------------------|----------------------------------------------------------------|
| `complex_sealed_dsl.kt`    | Sealed-interface hierarchy, generics, deeply nested lambdas, operator overloading (`get`/`plus`/`invoke`), data-class destructuring, constructor references, a small expression-evaluator DSL, `Map + Pair`, range higher-order ops. |
| `complex_oop_delegation.kt`| Interface delegation (`by`), custom property delegates (`getValue`/`setValue`), generic declaration-site variance, `enum` with abstract members, inner/nested classes, companion factories with `vararg`, `operator fun invoke`, `infix`, `by lazy`, local extension functions. |
| `complex_lambdas_generics.kt`| Deeply nested lambdas/closures, function composition and currying, memoization via a captured map, a recursive closure through a `lateinit var`, a generic recursive `Tree` with `fold`/`map`, tail recursion, lambda pipelines via `fold`, closure-over-mutable, generic `zipWith`. |
| `user_shadows_stdlib.kt`   | A same-file top-level function (`emptyList`/`emptySet`/`emptyMap`/`error`/`listOf`) shadows the implicitly imported stdlib function of the same name; the canonical `kotlin.collections.*` form stays reachable. |
| `user_extension_shadows_stdlib.kt`| A same-file top-level extension (`infix fun Int.to`) shadows the implicitly imported stdlib extension of the same name on the same receiver; a receiver type the user extension does not cover keeps the stdlib `to` (Pair). |
| `stack_trace.kt`           | A thrown exception captures the call stack at the throw site; `stackTraceToString` renders each frame with its function and source position (file:line) for user, stdlib, and pack frames. |
| `interface_companion.kt`   | A bare reference to an interface's own companion object resolves to that companion — from a default member, from an implementor's method, and through a companion that carries a supertype (the `CoroutineContext.Element` / `companion object Key : Key<…>` pattern). |
| `compose_state.kt`         | `androidx.compose.runtime` observable state: `mutableStateOf` reads/writes, `by` delegation, destructuring, and the structural-equality mutation policy. |
| `compose_remember.kt`      | A `@Composable` tree composes in source order; `remember` memoizes a value across recompositions of the same content. |
| `compose_recomposition.kt` | A state write recomposes only the composable that read the state (and its ancestors); a sibling that did not read it is skipped. |
| `compose_locals.kt`        | `CompositionLocal`: a value provided to a subtree via `CompositionLocalProvider`, with nested overrides and a default. |
| `compose_effects.kt`       | `SideEffect` runs after each composition that ran it; `DisposableEffect` runs setup once and `onDispose` when the composition is disposed. |
| `compose_counter.kt`       | A counter "app": state + `remember` + a `@Composable` tree re-rendered each frame after a state write drives recomposition (unchanged labels are skipped). |
| `compose_todo.kt`          | Observable `SnapshotStateList` + `mutableIntStateOf` + `derivedStateOf` (a computed "remaining" count): mutating the model recomposes the view and the derived value updates. |
| `compose_key.kt`           | `key{}` gives each list item identity tied to its key, so its remembered state follows the item across a reorder (contrasted with the unkeyed, position-based run). |
| `compose_frame_clock.kt`   | The upstream frame clock (`MonotonicFrameClock` / `BroadcastFrameClock`): a `Recomposer` driven inside `runBlocking` fans a frame to `withFrameNanos` awaiters each pass, so a `LaunchedEffect` advances animation state frame-by-frame and each advance recomposes. |
| `compose_snapshot_flow.kt` | `snapshotFlow` turns a state read into a cold Flow that re-emits on change; `collectAsState` mirrors a Flow back into a `State`, driving recomposition. |
| `compose_stateflow.kt`     | `StateFlow.collectAsState` mirrors a hot `MutableStateFlow` into a `State`: its collector runs under the `Recomposer`, and each StateFlow update resumes it, updates the `State`, and recomposes. |
| `compose_nodes.kt`         | Node emission (the `Applier` path): a `@Composable` tree emits typed nodes through `ComposeNode` into a custom `Applier`; recomposition mutates a node's property in place (no rebuild), a conditional inserts/removes a node, and `key{}` reorders a node while its remembered state follows the key. |
| `mosaic_hello.kt`          | Mosaic (`com.jakewharton.mosaic`) — a terminal UI on the compose runtime's node-emission path. A `Text`/`Row`/`Column` tree emits `MosaicNode`s through `ComposeNode` into a `MosaicNodeApplier`, which measures/lays-out/renders to text; a state write + recompose re-renders the changed nodes (`[]` → `[###]` → `[#######]`) in place. |
| `androidx_collection.kt`   | `androidx.collection` — the memory-lean collections the compose runtime builds on: scatter map/set, object + primitive value lists (in-place `sort`/`sortDescending`), a primitive `IntIntMap`, the ordered scatter set (insertion-order iteration), `SparseArrayCompat`, and `LruCache` with least-recently-used eviction. |
| `select_and_semaphore.kt`  | `kotlinx.coroutines.selects.select` over channel `onReceive`/`onSend` + `onTimeout` clauses, including a fan-in select loop over a *rendezvous* channel whose producer parks between sends and an `onSend` select that parks until a receiver arrives, plus a `Semaphore` limiting concurrent permits with `withPermit` under contention. |
| `select_on_timeout_loses.kt` | A parked `select` whose `onTimeout` clause *loses* to a channel `onReceive` that arrives first — the registered (but unfired) timeout `Runnable` is invoked as a value on resume and dispatches `run()`. |
| `flow_operators.kt`        | Flow operators `drop`/`dropWhile`/`buffer`/`flowOn`/`onCompletion` — the bare-extension receiver walk, the channel-backed `buffer`/`flowOn` (correct `produce` overload), and `onCompletion`. |
| `channel_invoke_on_close.kt` | `SendChannel.invokeOnClose { cause -> … }` runs the handler once when the channel closes, before the buffered elements are drained. |
| `sharedflow_collect.kt`    | A `MutableSharedFlow` collector that suspends and takes several successive `emit`s (the hot-flow suspending collector / field-receiver-lambda park). |
| `context_parameters.kt`    | Context parameters (Kotlin 2.4): a `context(name: Type)` clause on functions and a property, the stdlib `context(value) { … }` scope and `contextOf<T>()`, implicit forwarding between contextual functions, a generic context parameter with an explicit type argument, and a member resolving its context from the dispatch receiver. |
