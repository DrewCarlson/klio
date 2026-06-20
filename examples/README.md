# Examples

Runnable `.kt` programs that exercise klio through the real `klio`
binary. Every program here produces deterministic output and passes
the `klio-parity` sweep — its stdout is byte-identical to `kotlinc`
(Kotlin 2.3.21). The set grows monotonically: every new language
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
| `anon_local.kt`, `anon_object_tostring.kt` | Anonymous objects and local classes.           |
| `anon_object_init.kt`      | Anonymous-object initialization: property initializers over the enclosing scope (top-level properties, object singletons, inline-HOF calls, captured locals), supertype ctor-arg expressions, init-block interleaving. |
| `enums.kt`, `enum_companion.kt`, `enum_entries_interface.kt` | Enum entries, ctor args, per-entry overrides, `entries`/`values()`, enum companions. |
| `sealed_when.kt`, `sealed_when_exhaustive.kt` | Sealed hierarchies with exhaustive `when`.  |
| `data_object.kt`           | `data object`.                                                 |
| `object_lazy_init.kt`      | Lazy first-access `object`/companion initialization: unused objects never initialize, init/property interleaving, companion init at first instantiation, anon-object init blocks, init-failure wrapping (`FileFailedToInitializeException`) without retry. |
| `value_class.kt`           | Inline `value class`.                                           |
| `annotation_class.kt`      | `annotation class` declarations.                               |
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
| `extension_functions.kt`, `extension_property.kt`, `extension_nullable_receiver.kt` | Extensions, incl. nullable receivers. |
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
| `reified_filter.kt`        | `reified` type parameters: `filterIsInstance<T>()` over lists, and a user-defined `inline fun <reified T>` extension that composes with it. |
| `text_transforms.kt`       | `chunked(size) { transform }`, `Regex.replace`/`replaceFirst` with a `(MatchResult)->CharSequence` lambda and `$group` replacement templates. |
| `map_views.kt`             | Live `MutableMap` `keys`/`values`/`entries` views: `remove`/`removeAll`/`retainAll`/`clear` and `MutableEntry.setValue` write through to the map. |
| `m6b_taste.kt`             | Exceptions, lambdas, scope functions, and the broad numeric/string/char intrinsic surface together. |
| `jit_capture_cell_loop.kt` | A hot loop mutating `var`s captured by a nested lambda (boxed cells); output is identical with the loop JIT off or on. |

## Integration showcases

These exercise many features together — the kind of "tricky but
valid" Kotlin a real program mixes — and are each byte-identical to
`kotlinc`.

| File                       | Exercises                                                      |
|----------------------------|----------------------------------------------------------------|
| `complex_sealed_dsl.kt`    | Sealed-interface hierarchy, generics, deeply nested lambdas, operator overloading (`get`/`plus`/`invoke`), data-class destructuring, constructor references, a small expression-evaluator DSL, `Map + Pair`, range higher-order ops. |
| `complex_oop_delegation.kt`| Interface delegation (`by`), custom property delegates (`getValue`/`setValue`), generic declaration-site variance, `enum` with abstract members, inner/nested classes, companion factories with `vararg`, `operator fun invoke`, `infix`, `by lazy`, local extension functions. |
| `complex_lambdas_generics.kt`| Deeply nested lambdas/closures, function composition and currying, memoization via a captured map, a recursive closure through a `lateinit var`, a generic recursive `Tree` with `fold`/`map`, tail recursion, lambda pipelines via `fold`, closure-over-mutable, generic `zipWith`. |
