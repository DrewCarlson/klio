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
| `labeled_return_scope.kt` | `return@apply` exits the block only — the scoped function still returns its receiver, including when the receiver is itself a constructor call and when the return crosses a nested inline lambda. |
| `nonlocal_return_finally.kt` | A bare `return` in an argument lambda returns from the function the lambda is written in — a LOCAL fun included — and runs every `finally` the unwind crosses, through a non-spliced inline callee's real frame. |
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
| `local_fn_nested_recursion.kt` | A nested local function calling back into its enclosing local function (`fun inner` inside `fun step` invoking `step`), routed through the pre-bound overload cell; includes a `?.let` chain over the recursive result. |
| `local_fn_overloads.kt`    | Same-named local functions as true overloads: call-site selection by arity and argument types, one overload calling its sibling (no self-recursion through the shared binding), selection from a nested lambda. |
| `extension_property_delegates.kt` | Delegated extension properties (`val R.x by …`): bound-reference and top-level-var delegates, writes through `setValue`, a custom `getValue` operator receiving the `KProperty`, and bound property references (`obj::extVal`) reading through the delegate. |
| `anon_object_init.kt`      | Anonymous-object initialization: property initializers over the enclosing scope (top-level properties, object singletons, inline-HOF calls, captured locals), supertype ctor-arg expressions, init-block interleaving. |
| `anon_object_setter.kt`    | An anonymous object overriding a `var` with a custom setter dispatches that setter on writes (the write-through `drawContext` pattern). |
| `anon_object_captures_fn_named_local.kt` | A non-callable local whose name matches a top-level extension fn still value-captures into an anonymous object — `read.add(...)` in the object's lambda reads the captured list, the extension keeps serving calls. |
| `enums.kt`, `enum_companion.kt`, `enum_entries_interface.kt` | Enum entries, ctor args, per-entry overrides, `entries`/`values()`, enum companions. |
| `sealed_when.kt`, `sealed_when_exhaustive.kt` | Sealed hierarchies with exhaustive `when`.  |
| `data_object.kt`           | `data object`.                                                 |
| `object_lazy_init.kt`      | Lazy first-access `object`/companion initialization: unused objects never initialize, init/property interleaving, companion init at first instantiation, anon-object init blocks, init-failure wrapping (`FileFailedToInitializeException`) without retry. |
| `value_class.kt`           | Inline `value class`.                                           |
| `annotation_class.kt`      | `annotation class` declarations.                               |
| `annotated_function_types.kt` | Type-use-site annotations on function types (`@Composable () -> Unit`): params, return types, nullable, receiver, generic args, typealias, property getter, and annotated lambda expressions. |
| `plain_class_tostring.kt`  | Default and overridden `toString`.                             |
| `ir_instance_identity.kt`  | Reference identity of instances.                               |
| `collection_contract_equality.kt` | `==` dispatches on the LEFT operand: a native collection's equals is the collection contract, so `setOf(1) == MySet([1])` is true without an equals override on MySet (and stays identity-false the other way), nested Pairs included. |
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
| `private_member_beats_extension.kt` | A bare call inside a class binds the class's OWN member — private inline included — over same-named top-level inline extensions, and never re-picks a top-level namesake at runtime; explicit-receiver calls still reach the extensions. |
| `lexical_receiver_scope.kt`   | Lexical (creation-site) receiver scope for closures and anonymous functions: a no-receiver lambda writes the top-level var from inside a member dispatch; a `with`-created lambda keeps its receiver wherever it is invoked. |
| `operator_overload_arith.kt`  | Operator overloading.                                       |
| `tailrec.kt`                  | Direct and mutual tail-call optimization.                   |
| `sam_conversion.kt`           | SAM conversion.                                             |
| `dsl_marker.kt`, `build_helpers.kt` | `@DslMarker` and builder-style DSLs.                 |
| `dsl_dotted_head.kt`          | Dotted-head resolution inside receiver lambdas: a package-qualified head (`kotlin.math.*`) flattens to a global while a receiver-member dotted access walks `this`. |
| `vararg_spread.kt`            | `vararg` and the spread operator.                           |
| `deep_call_chain.kt`         | A 40-deep method-call chain (`sb.append(x).append(x)…`) — a type-checker regression guard: re-typing the receiver at each level was O(2^depth). |
| `ctor_trailing_lambda.kt`   | Kotlin binds a trailing lambda to the LAST parameter whatever gap the named arguments leave: `Panel("p", n = 11) { … }` fills `content` and defaults `flag`. A constructor must agree with a function here — the constructor's named binder used to drop the block into the first free slot and shift everything after it. |
| `trailing_lambda_member_defaults.kt` | A member/companion/object call with defaulted function-typed middle parameters binds the trailing lambda to the LAST parameter (`observe({}) { … }` fills `block`, defaults `writeObserver`) — the explicit-receiver member-call lowering must carry the trailing-lambda syntax bit. |
| `ctor_vs_factory.kt`         | A class with a same-named factory that fills a default parameter — a single-arg call (`Packed(3f)`) must pick the factory, not the value-class constructor. |
| `ctor_default_companion.kt`  | A primary-constructor default value reading a companion-object member (`cap = DefaultCap`, like androidx `Stroke`) resolves against the companion, not a null `this`; a default reading a previous parameter resolves by name. |
| `qualified_object.kt`        | A package-qualified reference to an `object` (`demo.Config`) resolves to the one singleton — identical to the bare name, with writes visible through both — not a separate class classifier. |
| `receiver_lambda_multiarg.kt`| A receiver-lambda argument that is *not* the trailing argument of a multi-arg call (`withPainter({ dot(n) }, finish)`) still resolves its bare member calls through the receiver — the pattern behind `DrawScope.rotate`/`scale`/`clipRect`. |
| `vararg_nonfinal.kt`         | `vararg` before a trailing defaulted parameter, called positionally (top-level, inline, member). |
| `class_factory_overload.kt`  | Same-name factory function vs constructor, disambiguated by argument type and arity. |
| `trailing_lambda_overload_writeback.kt` | A trailing-lambda call whose block mutates a captured variable still binds the lambda-hosting overload (a receiver extension), not a same-named top-level function whose last parameter is a scalar — the pattern behind `SlotWriter.group(key) { ... }`. |
| `qualified_constructor_call.kt` | A fully-qualified constructor call (`demo.app.Widget(...)`) from inside a class method resolves the package-qualified class, not a field access on the implicit receiver — the pattern behind the engine's `androidx.compose.runtime.composer.gapbuffer.SlotTable()`. |
| `reified_function_type.kt` | A reified type parameter bound to a function type (`boxOf<() -> Unit>()`) erases to Any instead of loading the synthetic `<function>` global — the pattern behind the engine's `mutableVectorOf<() -> Unit>()` side-effect list. |
| `reified_param_inference.kt` | A reified type parameter inferred from a value/lambda-parameter position (not just the return type). |
| `reified_inline_property_receiver.kt` | A reified inline extension spliced on a CLASS PROPERTY receiver, so `is T` tests the real class (the receiver type comes from the enclosing class's members, not just locals/params). |
| `smartcast_extension_receiver.kt` | Smart casts narrow the receiver's STATIC type, so an extension resolves against the narrowed type (`is String` -> `CharSequence.isEmpty`), in both the `when`-subject and `if (x is T)` forms. |
| `fn_param_name_shadows_operator.kt` | A function-typed parameter does not shadow a same-named function for a trailing-lambda call it cannot accept (`Flow.map`'s `crossinline transform` vs the `transform` operator). |
| `backing_field_in_nested_scope.kt` | The accessor's `field` binding is visible inside a nested scope (lambda, `when`, loop, `try`), not just the flat accessor body. |
| `yield_dispatches_to_the_pump.kt` | `yield()` reschedules through the coroutine's DISPATCHER (a queued child runs before it resumes), and a property reference works as a `compareValuesBy` key selector. |
| `super_property_setter.kt` | `super.prop = value` reaches the superclass accessor, so an overriding setter that writes through `super` does not re-enter itself. |
| `stored_override_of_accessor.kt` | A field-backed `override var` overrides an inherited accessor property, so a write stores the field and never reaches the base's custom setter. |
| `local_fun_arity_shadowing.kt` | A local function shadows an outer one by name only for calls it can take: `validate { … }` inside a no-arg local `validate()` resolves outward. |
| `labeled_this_in_object_literal.kt` | Inside an object literal written in a receiver lambda, `this@build` names the lambda's receiver, and a bare name the object does not own resolves against it. |
| `delegated_var_reads_through.kt` | A `var x by D` local reads through the delegate on every read (including inside a string template and a lambda), rather than caching the value at the declaration. |
| `atomic_named_compare_and_set.kt` | A named-argument call into a host-backed library member (`compareAndSet(expect = …, update = …)`) binds exactly as the positional form does. |
| `member_wins_over_extension.kt` | A member wins over a same-named extension, including on builtin types, so an extension that forwards to `this.<member>()` reaches the member instead of itself. |
| `scalar_typealias_overload.kt` | A scalar typealias (`= Long`) is transparent for overload resolution, so a Long argument matches an aliased parameter even against a zero-arg overload of the same name. |
| `reified_generic_arg.kt`      | A reified type parameter inferred from a generic-class argument's type args (`kind: NodeKind<T>` bound from `Nodes.Draw`), so `is T` in the spliced body checks the real class. |
| `const_val_inline.kt`         | Top-level `const val`s inline at reference sites (compile-time constants, incl. unary minus). |
| `function_type_named_params.kt` | Named parameters inside function types, incl. the annotated parenthesized forms `@Ann ((name: T) -> Unit)?` / `(@Ann (() -> Unit))?` / `@Ann ((T) -> Unit)` and annotated setter parameters. |
| `nullable_receiver_ext_prop.kt` | An extension property on a nullable receiver (`val T?.weight`) dispatches for a null receiver. |
| `value_class_overload_pick.kt` | A value-class argument (an object property of inferred value-class type) binds the value-class overload over the underlying-primitive sibling, incl. at inline-splice sites forced by a non-local return. |
| `sam_member_ext_receiver.kt` | A fun interface whose single abstract method is a member extension: the SAM lambda body is scoped with the extension receiver as `this`, and explicit-receiver calls through the SAM dispatch it. |
| `member_ext_sibling_named.kt` | A member-extension invoked with named arguments seeds its owner as an enclosing receiver, so a bare sibling member-extension call inside the body resolves. |
| `bounded_typeparam_receiver.kt` | A `where`-bounded generic extension never binds a receiver outside its bounds, even when the static receiver hint says otherwise. |
| `delegated_member_named_args.kt` | Class delegation serving a member invoked with named arguments binds parameters by name through the forward. |
| `positional_lambda_binding.kt` | Two positional lambdas with a defaulted third lambda parameter bind positionally; the trailing-lambda shift fires only when the callable does not fit its positional slot. |
| `companion_import_identity.kt` | A named companion-member import aliases the same value as the qualified read and outranks a same-named class in expression position. |
| `member_shadows_imported_class.kt` | A member function named like an imported class wins the bare call from the method body, lambdas, nested lambdas, and coroutine blocks — never the imported constructor. |
| `inline_member_owner_pick.kt` | A bare call inside an extension splices the receiver class's own `internal inline` member, not a same-named member of an unrelated class that registered first. |
| `block_body_returns_unit.kt` | A block-bodied function with no `return` yields Unit, never its last statement's value. |
| `ctor_over_inline_factory.kt` | A bare constructor call in the class's own body binds the constructor over a same-named reified inline factory of the same arity. |
| `long_property_literal_init.kt` | A Long-typed property initialized with a bare Int literal stores a Long in every property position (top-level, object, companion, ctor default, body field). |
| `generic_class_type_param_dispatch.kt` | A method param typed as a full-word CLASS type parameter (`put(key: Key)` on `Store<Key, Value>`) accepts any argument even when an unrelated class named `Key` exists. |
| `nested_class_name_collision.kt` | Two nested classes sharing a simple name under different outers keep distinct identities and enclosing-companion scopes. |
| `typealias.kt`                | `typealias`.                                                |
| `typealias_receiver_member_ext.kt` | A member extension declared on a typealias receiver (`fun AliasedUnit.report()` where `typealias AliasedUnit = Unit`) dispatches on values of the aliased type through the enclosing scope. |
| `throwable_suppressed_user_class.kt` | `addSuppressed`/`suppressedExceptions` on a user-defined throwable class: the suppressed set is shared across aliases and survives throw/catch. |
| `captured_counter_in_object_method.kt` | A captured outer `var` incremented (`++`) inside an anonymous object's method and inside a local class's method writes through to the declaration site, like a lambda capture. |
| `local_class_init_block.kt` | A local class's `init { }` blocks run at construction — interleaved with property initializers in declaration order — and read/write the enclosing function's captured vars through shared cells. |
| `local_fn_shadows_imported_class.kt` | A local `fun Test(a, b)` shadows an imported same-named class (`kotlin.test.Test`) at a bare call, including from inside a closure where the binding arrives as a capture. |
| `local_class_shadows_nested.kt` | A local `data class Value` shadows a same-simple-name nested class of another owner at a bare constructor call — in the declaring body and from inside a nested lambda that captures the binding. |
| `capture_load_across_branches.kt` | A captured name referenced on both arms of an elvis loads from the closure slot on whichever arm runs — the capture load is hoisted to the frame entry, never left in a not-taken branch. |
| `local_var_shadows_fn_call.kt` | A local `var` initialized with a literal does not shadow a same-named function at a call site — an Int is not invokable, so the call binds the function. |
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
| `finally_own_throw.kt`     | A throw or return raised inside a `finally` exits the region without re-running that finally (single-block and multi-block finallys, catch sees the finally's own exception). |
| `local_ext_fn_receiver_overload.kt` | A bare call with an implicit receiver in scope (top-level extension body, receiver lambda, LOCAL extension function) binds the receiver's extension over a same-named plain top-level function. |
| `receiver_fn_typealias_param.kt` | A parameter typed as an ALIASED receiver function type (`typealias Workflow = WScope.() -> Unit`) binds the enclosing receiver when invoked bare. |
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
| `compose_subcompose.kt`    | Subcomposition: `rememberCompositionContext()` gives a child `Composition` a context so it emits into its own node tree yet recomposes under the parent's `Recomposer` — a state write only the child read recomposes just the child. The primitive `SubcomposeLayout` (lazy lists) is built on. |
| `compose_ui.kt`            | Compose UI core (`klio.compose.ui`) rendered by Skia: a `Column`/`Row`/`Box`/`Text` tree emits `LayoutNode`s; a measure pass lays them out (arrangement + padding + size) and a draw pass records a display list of draw ops (fills, `border` outlines, text). The display list is the deterministic render artifact (a real Skia raster surface paints it to a PNG via `savePng`). A state write recomposes and re-renders (the counter text updates) — the LayoutNode + measure/layout/draw path a real Compose UI uses. |
| `compose_ui_click.kt`      | The full interactive Compose UI loop: a clickable `Button` + counter `Text`; a simulated pointer click hit-tests the button, invokes its `onClick` (writing state), recomposes, and re-records the display list (`N 0` → `N 1` → `N 2`) — input → state → recompose → draw, driven deterministically. |
| `compose_ui_lazy.kt`       | `LazyColumn` — a lazy list: only the items scrolled into view are composed (a 100-item list emits ~5 nodes; the composed-item counter proves off-screen items never run), and changing the scroll offset recomposes a different window (`I 0`…`I 4` → `I 10`…`I 14`). Each item is keyed by index. |
| `compose_ui_material.kt`   | The material layer: a `MaterialTheme` provides a `ColorScheme` through the compose runtime's `CompositionLocal`; a `Card` (themed surface + outline), `PrimaryButton` (theme primary), and `Text` (theme onSurface) all read the nearest theme via `.current`. The same `Screen()` renders in a light and a dark palette. |
| `compose_ui_png.kt`        | The Skia rendering sink: the draw pass records a display list, and the native backend (`src/compose_ui` + `libklio_skia`, dlopened) replays it onto a real Skia raster surface and encodes a PNG via `savePng`. The printed display list is the deterministic, backend-independent artifact; the PNG is produced when the Skia library is available. |
| `compose_ui_text.kt`       | The `Paragraph` composable: word-wrapped, multi-line, aligned (left/center/right) text laid out within a fixed width — the Skia backend wraps on real font metrics, headless layout estimates the line count. Emits a `para` display-list op; the printed list is the deterministic artifact. |
| `compose_ui_window.kt`     | A live **windowed** Compose UI app: `runApp` opens an on-screen window (Skia rendered via SDL — raster texture, or the GPU with `-Dgpu`), runs the event loop, and dispatches real pointer clicks through hit-testing → state → recompose → redraw (an ADD button increments a counter on screen). Requires the Skia library + a display; `runApp` returns immediately with no windowing backend, so it is headless-safe and has no baked corpus output. |
| `compose_ui_input.kt`      | The full input surface in a live window: a `TextField` you click to focus and **type** into (Backspace deletes), an ADD button that **highlights on hover** and increments a counter on click, and **window resize** → relayout. Exercises keyboard/hover/pointer/resize events through the SDL backend. Requires the Skia library + a display; headless-safe (no corpus output). |
| `compose_ui_dashboard.kt`  | An advanced **windowed Material 3** app that stays open (`maxFrames = -1`): a light/dark **theme toggle** that re-themes the whole tree via `MaterialTheme`/`LocalColorScheme`, **tab navigation** (Counter / Tasks / About), an interactive **counter** (+/-/reset), a **toggleable task list** (click to check, done items dim), and an **About** pane with a wrapped `Paragraph` — themed `Card`/`Row`/`Column`/`Chip` widgets with hover borders, the full click → state → recompose → Skia draw loop. Requires the Skia library + a display; headless-safe (no corpus output). |
| `compose_color.kt`         | The real `androidx.compose.ui.graphics.Color` — the genuine upstream inline value class over a packed `ULong`, backed by the vendored color-science `colorspace` package (`Rgb`/`ColorSpaces`/the XYZ transforms). Constructs from packed `0xAARRGGBB`, float channels, and 8-bit int channels; decodes the sRGB channels back; computes relative luminance (the exact 0.21/0.72/0.07 sRGB weights); `copy()` overrides a channel; reports the colorspace name. |
| `compose_density.kt`       | The real `androidx.compose.ui.unit.Density` — the interface whose entire API is member-extension conversions between px / `Dp` / `Sp` (`fun Dp.toPx()`, `fun Int.toDp()`, `fun TextUnit.toDp()`), invoked through `with(density) { … }`. Exercises the interface member-extension dispatch the compose layout system runs on. |
| `compose_path.kt`          | The real `androidx.compose.ui.graphics.Path` — building a path from primitive move/line/cubic segments and higher-level shapes (`addRect`/`addOval`/`addRoundRect`), then reading back its control-point bounds, convexity, `addPath` with an offset, and iterating its `PathSegment`s. Backed by klio's pure-Kotlin command buffer (higher-level shapes are decomposed to cubics on add). |
| `compose_paint.kt`         | The real `androidx.compose.ui.graphics.Paint` — the drawing-parameter object the DrawScope configures before rasterizing a shape: fill vs stroke, colour, stroke width/cap/join/miter, blend mode, alpha, anti-aliasing. Backed by klio's plain value object; the shader / colour-filter / path-effect slots default to null. |
| `compose_pathop.kt`        | The real `Path.op` boolean operations — union / intersect / difference / xor of two paths, computed by the Skia shim's `SkPathOps`. Two overlapping squares are combined every way; the result path's control-point bounds and emptiness confirm the op. |
| `compose_canvas.kt`        | The real `androidx.compose.ui.graphics.Canvas` — `drawRect`/`drawCircle`/`drawRoundRect`/`drawPath`/`drawLine` with real `Paint` (fill + stroke) onto an offscreen Skia surface, saved as a PNG. `KlioCanvas` drives an `SkCanvas` through the shim; the coming `DrawScope` render path wraps the same Canvas. |
| `compose_drawscope.kt`     | The real `graphics.drawscope.DrawScope` — the upstream drawing DSL a desktop Compose `Canvas { … }` runs. The vendored `CanvasDrawScope` drives `KlioCanvas` over the shim; `klioRenderToPng` renders a `DrawScope` block (rect/circle/path/line with `Color`) to a PNG. |
| `compose_shape.kt`         | The real `graphics.Shape` / `Outline` — a Shape maps a size to an Outline (Rectangle / Rounded / Generic). `RectangleShape` and a custom `TriangleShape` (a Generic outline over a `Path`) print their outline kind + bounds. |
| `compose_brush.kt`         | The real `graphics.Brush` — `SolidColor` applied to a `Paint` sets that flat colour; a gradient brush builds from its stops. |
| `compose_gradient.kt`      | Gradient brushes — `Brush.linearGradient` / `radialGradient` paint real Skia gradient shaders through the DrawScope brush path (the brush serializes its stops + geometry; the shim reconstructs the `SkShader`). |
| `compose_animation.kt`     | The real `androidx.compose.animation.core` easing curves (`LinearEasing`, `FastOutSlowInEasing`, a custom `CubicBezierEasing`), vendored verbatim as a klio pack over ui-graphics; sampled across the unit interval for deterministic output. |
| `compose_text.kt`          | The real `androidx.compose.ui.text` model — `AnnotatedString`, `buildAnnotatedString { append/pushStyle/pop }`, `SpanStyle(color, fontWeight)`, `FontWeight`, `TextAlign` — running through the vendored ui-text pack. |
| `compose_layout.kt`        | The real `androidx.compose.foundation.layout` API — `PaddingValues`, `Arrangement`, and the `Modifier` layout factories (`padding`/`size`/`fillMaxWidth`) — resolved through the vendored foundation-layout pack. |
| `compose_foundation.kt`    | The real `androidx.compose.foundation` layer — `BorderStroke`, `RoundedCornerShape`, and `ScrollState` (whose interaction plumbing builds a kotlinx `MutableSharedFlow`) — through the vendored foundation pack. |
| `compose_material3.kt`     | The real `androidx.compose.material3` API surface + `MaterialTheme` composable theming — `lightColorScheme`/`darkColorScheme`/`Typography`/`Shapes`/`ColorScheme.copy` build the theme, and reading `MaterialTheme.colorScheme`/`typography`/`shapes` back through the theme's `CompositionLocal`s inside a composition returns the provided values, including a nested `MaterialTheme` that overrides its subtree and restores the outer theme afterward. |
| `mosaic_hello.kt`          | Mosaic (`com.jakewharton.mosaic`) — a terminal UI on the compose runtime's node-emission path. A `Text`/`Row`/`Column` tree emits `MosaicNode`s through `ComposeNode` into a `MosaicNodeApplier`, which measures/lays-out/renders to text; a state write + recompose re-renders the changed nodes (`[]` → `[###]` → `[#######]`) in place. |
| `androidx_collection.kt`   | `androidx.collection` — the memory-lean collections the compose runtime builds on: scatter map/set, object + primitive value lists (in-place `sort`/`sortDescending`), a primitive `IntIntMap`, the ordered scatter set (insertion-order iteration), `SparseArrayCompat`, and `LruCache` with least-recently-used eviction. |
| `compose_window.kt`        | Desktop-style `application { Window(onCloseRequest = ::exitApplication) { … } }` entrypoints over the REAL `androidx.compose.ui` engine: with a windowing backend the material3 counter opens in a native (SDL2) window driven frame-by-frame through compose → measure/layout → draw, with clicks dispatched through the engine's `PointerInputEventProcessor`; headless it reports `window opened=false` and exits cleanly, so the output is deterministic in both environments. |
| `compose_multiwindow.kt`   | Multi-window compose application with recomposition-driven window parameters: two `Window`s compose side by side inside one `application {}` block, the first window's TITLE follows counter state (`__composeui_winSetTitle` on the live native window), the second window is GATED on state — flipping it recomposes the app block and `DisposableEffect` closes that native window — and `exitApplication()` ends the loop. Per-window SDL event routing keeps each window's input on its own queue. Headless the windows never open and the same composition trace prints. |
| `compose_uitext.kt`        | The real `androidx.compose.ui.text` pack: `buildAnnotatedString` spans (`SpanStyle` color/weight/decoration ranges), `TextStyle.merge`, and `Paragraph` construction through `createFontFamilyResolver`. With a Skia backend the same paragraph engine shapes/wraps with real font metrics and paints spans as styled runs (per-span color, synthetic bold/italic, underline/strikethrough); the example reports the style MODEL so output is deterministic in both environments. |
| `compose_foundation_lazy.kt` | The real `androidx.compose.foundation` `LazyColumn` through the real UI engine: `SubcomposeLayout` subcomposes only the visible window (9 of 30 items compose), items measure through the real text stack (`BasicText`), and `LazyListState(initialFirstVisibleItemIndex = 10)` positions the scroll window — `layoutInfo.visibleItemsInfo` reports the measured window back. With a Skia backend the same run rasterizes the list to a PNG (real glyph metrics shift the composed-count line). |
| `compose_foundation_draw.kt` | The real `androidx.compose.foundation` draw modifiers through the real UI engine: `Modifier.background` (colour and shape), `Modifier.border`, and `Image` over an `ImageBitmap`. `border` installs a `CacheDrawModifierNode` whose cached draw block is a `CacheDrawScope.() -> DrawResult` field invoked with its receiver passed positionally; `Image` reaches `DrawScope.drawImage`, whose concrete interface-default overload delegates by name to its abstract sibling. Prints the engine's account of the pass, so it is deterministic with or without a Skia backend; the PNG is the visual proof when one is present. |
| `compose_colorspace.kt`    | Color-space conversion through the vendored `androidx.compose.ui.graphics` colorspace module: RGB↔XYZ↔Lab connectors with chromatic adaptation (sRGB/CieXyz/CieLab/DisplayP3 roundtrips), the Oklab-backed `lerp`, linear-space `compositeOver`, and `luminance`. |
| `compose_material3_text.kt` | material3 `Text` over the real text stack: upstream material3 routes through foundation `BasicText` into the real `androidx.compose.ui.text` engine, and `MaterialTheme.typography` drives real measured metrics — `onTextLayout` results order strictly by the typography scale (headline > body > label), identically headless and Skia-backed. |
| `select_and_semaphore.kt`  | `kotlinx.coroutines.selects.select` over channel `onReceive`/`onSend` + `onTimeout` clauses, including a fan-in select loop over a *rendezvous* channel whose producer parks between sends and an `onSend` select that parks until a receiver arrives, plus a `Semaphore` limiting concurrent permits with `withPermit` under contention. |
| `select_on_timeout_loses.kt` | A parked `select` whose `onTimeout` clause *loses* to a channel `onReceive` that arrives first — the registered (but unfired) timeout `Runnable` is invoked as a value on resume and dispatches `run()`. |
| `flow_operators.kt`        | Flow operators `drop`/`dropWhile`/`buffer`/`flowOn`/`onCompletion` — the bare-extension receiver walk, the channel-backed `buffer`/`flowOn` (correct `produce` overload), and `onCompletion`. |
| `channel_invoke_on_close.kt` | `SendChannel.invokeOnClose { cause -> … }` runs the handler once when the channel closes, before the buffered elements are drained. |
| `sharedflow_collect.kt`    | A `MutableSharedFlow` collector that suspends and takes several successive `emit`s (the hot-flow suspending collector / field-receiver-lambda park). |
| `context_parameters.kt`    | Context parameters (Kotlin 2.4): a `context(name: Type)` clause on functions and a property, the stdlib `context(value) { … }` scope and `contextOf<T>()`, implicit forwarding between contextual functions, a generic context parameter with an explicit type argument, and a member resolving its context from the dispatch receiver. |
| `coroutine_context_completion.kt` | The `coroutineContext` intrinsic read from a class member suspend function launched via `startCoroutine(Continuation(ctx) {})` — the intrinsic resolves to the current continuation's context (the factory completion declares only `context`), matching the top-level read. |
| `ctor_overload_builtin_supers.kt` | Constructor overload routing where the argument's builtin runtime type satisfies the declared parameter head through its nominal supertypes (`mutableListOf(...)` into a `List<T>` primary-ctor slot) instead of misrouting to a secondary constructor. |
| `multi_dollar_strings.kt`  | Multi-dollar string interpolation (`$$"..."`): N leading dollars set the template marker length, shorter runs are literal; raw strings close on the last three quotes of a quote run. |
| `import_alias_functions.kt` | Renaming imports of functions (`import kotlin.math.max as biggest`) for bare calls and explicit-receiver extension calls (`"hi".shout()`). |
| `local_fn_param_shadows_inline.kt` | A local function-typed binding (`body: () -> T`) shadows top-level namesakes for a bare call — never inline-spliced over. |
| `typealias_is_as.kt`       | `is`/`as` against a typealias head behave as against the aliased target (including `Unit` aliases). |
| `private_helper_overload_capture.kt` | Private same-named class helpers decline calls their parameter/receiver types definitely cannot bind; Char numeric conversions. |
| `range_in_range_operator.kt` | A user `operator LongRange.contains(LongRange)` decides range-in-range membership over the builtin element `contains`. |
| `vararg_overload_binding.kt` | Non-final vararg binding (middle args absorbed, trailing defaults kept, named args past the vararg), List-vs-vararg overload selection, and the materialized Array type of a vararg param in its body. |
