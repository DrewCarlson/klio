# Context parameters (Kotlin 2.4, stable) — semantics for KLIO

Normative source: KEEP-367 (`Kotlin/KEEP` `proposals/KEEP-0367-context-parameters.md`),
cross-checked against the Kotlin 2.4.0 compiler (FIR checkers, parser, diagnostic test
data) and the local `kotlin/` checkout (2.4-era, `build-2.4.10-RC-284`), which is
authoritative for stdlib signatures. Section citations below name KEEP-367 paragraphs
(`§n.m`) and their enclosing KEEP section titles.

Stability (Kotlin 2.4.0 release notes): context parameters are **Stable, no opt-in
flag**, *except* two carve-outs that remain experimental/unsupported:

1. **Explicit context arguments** (KEEP-448, behind `-Xexplicit-context-arguments`).
2. **Callable references to declarations with context parameters** (rejected).

KLIO scope: implement declarations and implicit resolution. The two carve-outs above
are **out of scope** and MUST be rejected with the diagnostics given in §K below.

---

## 1. Grammar and parsing

### 1.1 Positions (KEEP §1.1, §7.1 "Syntax"; kotlinc `FirContextParametersDeclarationChecker`)

`context(...)` is syntactically a **modifier** living inside the modifier list:

```
functionModifier: ... | contextParameterList
propertyModifier: ... | contextParameterList
contextParameterList: 'context' '(' contextParameter { ',' contextParameter } [','] ')'
contextParameter: [annotation*] [parameterModifier*] simpleIdentifier ':' type
functionType: [functionTypeContext] [receiverType '.'] '(' params ')' '->' type
functionTypeContext: 'context' '(' type { ',' type } [','] ')'
```

Allowed positions:
- **Named functions**: top-level, member, extension, **local**, and anonymous
  functions (`context(a: A) fun() {}` in expression position).
- **Properties with accessors**: top-level, member, extension, `val` and `var`.
  The context list belongs to the property as a whole (KEEP §1.3).
- **Operators**, except the property-delegation operators `getValue`, `setValue`,
  `provideDelegate` (KEEP §1.1).
- **Function types** (types only, no names — see §7 below).

Rejected positions — each MUST produce an error (kotlinc emits `UNSUPPORTED` with
these exact message strings):
- constructors (primary and secondary): "Context parameters on constructors are
  unsupported." / "Context parameters on primary constructors are unsupported."
  (KEEP §6.1 "Context and classes")
- classes/objects/interfaces: "Context parameters on classes are unsupported."
- property accessors (a `context(...)` on `get`/`set` itself): "Context parameters
  on property accessors are unsupported." (KEEP §1.3)
- **local properties**: "Context parameters on local properties are unsupported."
- delegated properties (`by`): "Context parameters on delegated properties are
  unsupported." (KEEP §1.3)
- type aliases, enum entries, init blocks, backing fields: "...are unsupported."

### 1.2 Structural rules

- Exactly **one** context list per declaration. A second list → error
  `MULTIPLE_CONTEXT_LISTS`: "Multiple context parameter lists are forbidden. Put all
  context parameters in one list."
- An **empty** list `context()` → parse error "Empty context parameter list"
  (KEEP §1.2).
- A trailing comma is allowed.
- Every parameter MUST be `name: Type`. A bare type (`context(String)` — the old
  context-receiver syntax) → error `CONTEXT_PARAMETER_WITHOUT_NAME`: "Context
  parameters must be named. Use '_' to declare an anonymous context parameter."
- `_` declares an anonymous parameter: it participates in resolution but is not
  accessible by name (KEEP §1.1). Multiple `_` (also backtick-quoted `` `_` ``) do
  not clash.
- Duplicate names among context parameters, or between a context parameter and a
  value parameter (including a property setter's parameter) → `REDECLARATION` on
  both occurrences (KEEP §1.2). A context parameter may shadow outer names and may
  coincide with the function's own name or type-parameter names. The implicit setter
  parameter name `value` does NOT clash with a context parameter named `value`.
- **Default values** are forbidden → `CONTEXT_PARAMETER_WITH_DEFAULT`: "Context
  parameters cannot have default values." (parse the default, then reject).
- Parameter modifiers: only `noinline` and `crossinline` parse as applicable;
  everything else (`vararg`, `val`, `var`, ...) → `WRONG_MODIFIER_TARGET`
  ("Modifier 'vararg' is not applicable to 'context parameter'"). In an `inline`
  function a function-typed context parameter MUST be `noinline`; `crossinline` or
  bare → `CONTEXT_PARAMETER_MUST_BE_NOINLINE`: "Context parameter 'x' of 'f' must
  be 'noinline'. Inlining context parameters is not yet supported."
- Annotations on context parameters are allowed (KEEP §7.1).
- A context parameter whose declared type is `kotlin.coroutines.CoroutineContext`
  (directly, via typealias expansion, or nullable `CoroutineContext?`) → error
  `COROUTINE_CONTEXT_AS_CONTEXT_PARAMETER_IS_RESERVED` ("Context parameter of type
  'kotlin.coroutines.CoroutineContext' is reserved for future use.", KEEP-443). Same
  for contextual function types after substitution where detectable.
  `EmptyCoroutineContext`, `Any`, and generic parameters merely *bounded* by
  `CoroutineContext` are allowed.
- Position relative to other modifiers: the context list is a member of the modifier
  list and MAY appear intermixed with annotations and other modifiers in any order;
  recommended style is annotations, then `context(...)`, then remaining modifiers
  (KEEP §7.1). Both `public context(c: C) fun f()` and `context(c: C) public fun f()`
  parse.
- Subtyping between the types of two context parameters of one declaration is
  **allowed** (`context(_: String, _: Any)` is legal; the old context-receiver
  restriction is dropped — KEEP Q&A "Why drop the subtyping restriction").
- Two context parameters of the **same type** on one declaration are legal at the
  declaration; uses that need that type by resolution are ambiguous (see §3).

### 1.3 Soft-keyword disambiguation (KEEP §7.2 "Syntax")

`context` stays a soft keyword. `kotlin.context(...)` is a real stdlib function, so
`context(` at statement level is ambiguous. Rules (mirrors kotlinc
`KotlinParsing.doParseModifierListBody` + `parseContextParameterOrReceiverList`):

1. While parsing a **modifier list**, `context` followed immediately by `(` starts a
   tentative context parameter list.
2. Parse the parenthesized list. If every element parses as a value parameter
   (`[modifiers] name ':' type`), it IS a context parameter list; continue parsing
   the modified declaration.
3. Otherwise (any element is a bare type/expression — equivalently, KEEP's rule: the
   token after `(` is not `identifier`-then-`:`), and the parser is at **statement
   level** (local declaration attempt), **roll back the whole `context(...)`** and
   re-parse it as an expression — i.e. a call to a function named `context`.
   At non-local declaration level there is no call interpretation; a bare-type list
   is kept and diagnosed as `CONTEXT_PARAMETER_WITHOUT_NAME`.
4. A context list not followed by a declaration head (`fun`/`val`/`var`/...) is a
   dangling modifier list → syntax error.

Consequences that MUST hold: `context(users) { ... }`, `context(C::class) { ... }`,
`context(fun () {}) { ... }`, `context(a, b) { ... }` are calls;
`context(c: String) fun local() { ... }` at statement level is a local function.

## 2. Scoping inside the body (KEEP §7.3 "Extended resolution algorithm")

- Named context parameters are in scope in the declaration body exactly like value
  parameters, in the same scope level as the value parameters (no shadowing between
  them; names are unique per §1.2). For a property, they are in scope in **both**
  accessors; for a local function, only inside that function.
- Context parameters are **NOT implicit receivers** (unlike the abandoned context
  receivers). Members of a context parameter are only reachable through the
  parameter name (`logger.log(...)`), through `contextOf<T>()`, or via bridge
  functions (KEEP §3.1 "Simulating receivers"). An unqualified call NEVER
  dispatches on a context parameter.
- Anonymous (`_`) context parameters and context parameters of contextual function
  types are in scope only for context resolution and `contextOf` (KEEP §1.8).
- `with`/`run`/`apply` etc. are unchanged: they introduce implicit *receivers*.
  Receivers additionally act as context-argument sources (see §3); context values do
  not act as receivers.

## 3. Implicit context resolution (KEEP §1.4, §7.5 "Extended resolution algorithm")

When a call's candidate declares context parameters, an extra **context resolution**
phase runs after applicability checking, once per candidate, once per context
parameter, independently:

1. Build the **tower of implicit scope levels**, innermost first. Each level holds
   the implicit values introduced at that lexical scope:
   - a lambda/`with` block level holds that lambda's receiver AND its contextual
     function type's context values (one level);
   - a function declaration level holds its extension receiver AND all of its
     context parameters (one level — so an extension receiver and a same-typed
     context parameter of the same function are ambiguous with each other);
   - a class body level holds the dispatch receiver `this` (outer relative to its
     members' own parameter levels);
   - outer functions/classes/file follow outward.
2. For context parameter `p` of type `T` (after substitution of already-fixed type
   arguments), walk levels from innermost to outermost. At each level collect every
   implicit value — **context value or implicit receiver** — whose type (including
   smart-cast-narrowed type, KEEP §7.6) is a **subtype of `T`**.
   - If `T` mentions not-yet-fixed type variables of the candidate, add the
     corresponding constraints to that candidate's constraint system using the first
     found value; if the system fails, the candidate is **inapplicable** — no other
     implicit value is retried (KEEP §7.5).
3. At the first (most nested) level with exactly **one** compatible value: that value
   is the context argument. Values at outer levels are shadowed — no error.
4. At the first level with **two or more** compatible values: error
   `AMBIGUOUS_CONTEXT_ARGUMENT` — "Multiple potential context arguments for 'p' in
   scope." (one error per parameter).
5. If no level has a compatible value: the candidate is inapplicable; if that kills
   the whole candidate set, report `NO_CONTEXT_ARGUMENT` — "No context argument for
   'p' found." (one per missing parameter; a call missing two contexts reports two).

Facts the implementation MUST reproduce:
- One implicit value MAY fill several slots at once: `with(A())` can supply the
  dispatch/extension receiver AND any number of `A`-typed context parameters of the
  same call.
- A member `context(a: A) fun A.f()`/`fun funMember()` inside `class A` resolves its
  `A` context from the dispatch receiver — a single source, no ambiguity.
- Two same-typed context parameters of the *caller* (same level) make any use that
  needs that type by resolution ambiguous, though both remain usable by name.
- Resolution is purely compile-time/static; the interpreter passes the resolved
  values as hidden arguments in declaration order.

### 3.1 Receiver-shadowed-by-context errors (KEEP §7.10 "Extended scoping rules")

Mixing receivers and context values across levels is restricted; both directions
report `RECEIVER_SHADOWED_BY_CONTEXT_PARAMETER` ("Call to X uses an implicit
receiver shadowed by a context parameter. ..."):

- (a) An unqualified call (or property access) binds an **implicit receiver** at
  level `Lr` while a context value exists at a strictly more nested level whose type
  is compatible with that receiver's use — error, even when no contextual overload
  exists (the KEEP `Cow` example).
- (b) A context argument resolves to a **context value** at level `Lk` while an
  implicit **receiver** at a strictly outer level is also compatible with the same
  context parameter — error (kotlinc test `receiverShadowedSubtype.kt`: the check is
  applicability-based, not name-based).
- No error when the winner is the more nested *receiver* (KEEP §7.5 `example4`:
  `with(console) { ... }` inside contextual scope is fine), when both values are
  context values (inner simply shadows outer, `example2`), or when the call
  qualifies explicitly (`this.foo()`, `this@with.o`, `contextOf<Foo>().foo()`).

### 3.2 `@DslMarker` (KEEP §7.7)

A value is X-DSL-marked if its type is annotated with `@X` where `X` has
`@DslMarker`. If a potential contextual X-marked value is in scope at some level and
context resolution selects an X-marked value from an outer level — error (extends
the classic receiver rule; receivers-used-as-receivers and context values do not
conflict with each other under the old rule).

## 4. Overloading, specificity, overriding, expect/actual

### 4.1 Declaration conflicts (KEEP §1.5)

- Two overloads whose context parameter **type sets are identical** (order and names
  irrelevant) conflict: `CONFLICTING_OVERLOADS` ("Conflicting overloads: ...") for
  functions, `REDECLARATION` for properties.
- Overload `D` gets warning `CONTEXTUAL_OVERLOAD_SHADOWED` ("The following overloads
  conflict with this contextual declaration. Calls will be ambiguous because context
  arguments are not used for overload resolution....") when another overload `D'`
  with the same value-parameter signature is applicable whenever `D` is — i.e.
  every context parameter of `D'` is satisfied by a supertype-or-equal of some
  context of `D` (includes: contextual `D` vs context-free `D'`; `context(_: String)`
  vs `context(_: Any)`; `context(_: String, _: Any)` vs `context(_: Any)`). The
  warning goes on the more-constrained declaration.

### 4.2 Call-site specificity (KEEP §7.8 "most specific candidate")

Context parameters play **no role** in choosing the most specific candidate. If two
otherwise-equal candidates differ only in contexts and both survive applicability
(including context resolution), the call is `OVERLOAD_RESOLUTION_AMBIGUITY`. A
candidate whose context cannot be resolved drops out first, so `fun f()` +
`context(a: A) fun f()` resolves to the context-free one when no `A` is in scope and
is ambiguous when one is. Receiver-based candidates found at a more nested tower
level still win over candidates found at outer levels as usual (a `with`-receiver
extension beats a top-level contextual overload; when only the contextual candidate
is applicable, it wins).

### 4.3 Overriding (KEEP §1.5; kotlinc `overrides/` test data)

Context parameters are part of the signature:
- An override MUST declare context parameters with the **same types in the same
  order** as the overridden member. Any deviation (missing list, reordered, extra,
  moved to value parameters or receiver, different type) → the member overrides
  nothing: `NOTHING_TO_OVERRIDE`.
- Parameter **names** may differ; kotlinc reports warning
  `PARAMETER_NAME_CHANGED_ON_OVERRIDE` on functions (not on properties).
- Not overriding (inheriting) a contextual member is fine; callers resolve the
  inherited signature's contexts normally. Interface members (incl. abstract
  contextual `val`/`var` and members with default bodies) follow the same rules.

### 4.4 expect/actual (kotlinc `multiplatform/` test data)

Expect and actual MUST declare identical context parameter lists (types and order);
mismatch → the pair does not match (`ACTUAL_WITHOUT_EXPECT`). Differing context
parameter **names** → `EXPECT_ACTUAL_INCOMPATIBLE_CONTEXT_PARAMETER_NAMES`.

## 5. Contextual properties (KEEP §1.3)

- The context list attaches to the property; both accessors see the parameters.
- A contextual property has **no backing field**, hence:
  - `val` with initializer → `CONTEXT_PARAMETERS_WITH_BACKING_FIELD` ("Property with
    context parameters cannot be initialized because it has no backing field.");
  - `var` with initializer + accessors → `PROPERTY_INITIALIZER_NO_BACKING_FIELD`,
    and `field` inside accessors is unresolved;
  - `lateinit` is likewise invalid.
- No delegation (`by ...`) — rejected (§1.1 list).
- No per-accessor context lists — `context(...)` on `get`/`set` is rejected (§1.1).
- No context parameters on constructors — ever (KEEP §6.1); the
  companion-`invoke` pattern is the sanctioned workaround (KEEP §6.2).

## 6. Standard library (authoritative: local checkout `kotlin/libraries/stdlib/src/kotlin/contextParameters/`)

Shipped stable (declarations carry `@SinceKotlin("2.2")`, no opt-in annotation), all
in package `kotlin`, `@kotlin.internal.InlineOnly`, JVM facade
`ContextParametersKt`:

```kotlin
// Context.kt — arities 1..6, each with contract callsInPlace(block, EXACTLY_ONCE)
public inline fun <T, R> context(with: T, block: context(T) () -> R): R = block(with)
public inline fun <A, B, R> context(a: A, b: B, block: context(A, B) () -> R): R = block(a, b)
// ... likewise for (A,B,C), (A,B,C,D), (A,B,C,D,E), (A,B,C,D,E,F)

// ContextOf.kt
context(context: @NoInfer A)
public inline fun <A> contextOf(): @NoInfer A = context
```

- `context(v, block)` makes `v` available **for context resolution only** — not as
  an implicit receiver (doc text: "As opposed to `with` ...").
- `contextOf<A>()` returns the nearest implicit value (context value, extension or
  dispatch receiver) compatible with `A`. `@NoInfer` means `A` is never inferred
  *from* the candidate implicit values — it must come from an explicit type argument
  or the expected type; given a fixed `A`, mismatching nearer values are skipped and
  the nearest `A`-compatible value wins (KEEP §2.2; kotlinc `inference/noInfer`
  tests).
- `kotlin.ExperimentalContextParameters` annotation class exists (legacy opt-in
  marker); nothing stable requires it.
- KLIO: implement `context` as ordinary stdlib functions (the contextual-function-
  type conversion in §7 must make `block(with)` positional invocation work), and
  `contextOf` as a contextual generic function per its source.

## 7. Contextual function types and lambdas (KEEP §1.7, §1.8, §7.4, §7.9)

Stable in 2.4 (the stdlib `context` function depends on them).

- Syntax: `context(A, B) R.(P) -> T`. The context block comes first, then optional
  receiver, then parameters. **Types only**: `context(s: String) () -> Unit` in a
  type position → `NAMED_CONTEXT_PARAMETER_IN_FUNCTION_TYPE` ("Named context
  parameters in function types are unsupported. Use syntax 'context(Type)'
  instead."), `_:` included.
- Typing equivalence (KEEP §1.7): `context(A, B) R.(P) -> T` is the same *type* as
  `(A, B, R, P) -> T` with contexts, then receiver, then parameters flattened in
  order. Representation: `Function{n}` with annotations recording the context count
  (KLIO may model it directly). Assignability among the equivalent forms MUST work
  in both directions (kotlinc `contextAndExtensionTypesTogether.kt`).
- Invoking a value `f: context(A, B) R.(P) -> T`:
  - implicit style: `r.f(p)` / `f(p)` — the context arguments are resolved from
    scope per §3 (missing → `NO_CONTEXT_ARGUMENT` per parameter, ambiguous →
    `AMBIGUOUS_CONTEXT_ARGUMENT`);
  - fully explicit positional style: `f(a, b, r, p)` — all contexts and receiver
    passed as leading value arguments (this is invocation of the equivalent plain
    function type, KEEP §1.7). Mixed forms (`r.f(a, b, p)`) are invalid.
- Lambdas: a lambda acquires context parameters only when a contextual function
  type is **expected** for it (declared parameter type, variable type, return type);
  they behave as if named `_` (KEEP §1.8): in scope for resolution and `contextOf`,
  no name, and NOT receivers. Lambda applicability strips the context block from the
  expected type before matching the literal's own parameters (KEEP §7.4,
  *nocontext(U)*). Context parameter types are never inferred from the lambda body
  (KEEP §7.9).
- Anonymous functions may declare their own `context(name: Type)` modifier; names
  are then usable in the body.
- Contextual function types are invalid as supertypes
  (`SUPERTYPE_IS_EXTENSION_OR_CONTEXT_FUNCTION_TYPE`) and as upper bounds
  (`UPPER_BOUND_IS_EXTENSION_OR_CONTEXT_FUNCTION_TYPE`), same as extension function
  types.

## 8. Excluded forms — reject with diagnostics (KLIO carve-outs)

- **Explicit context arguments** (KEEP-448): passing a context argument at a call
  site by name, `needsA(a = A())`. kotlinc 2.4 without `-Xexplicit-context-arguments`
  reports `UNSUPPORTED_FEATURE` on the named argument (feature
  `ExplicitContextArguments`: "The feature \"explicit context arguments\" is
  experimental and should be enabled explicitly") AND still runs implicit
  resolution, so `NO_CONTEXT_ARGUMENT` accompanies it when the context is otherwise
  absent. A named argument matching no value parameter and no context parameter
  stays `NAMED_PARAMETER_NOT_FOUND`. Positional extra arguments remain
  `TOO_MANY_ARGUMENTS`. KLIO MUST reject the named form targeting a context
  parameter with a dedicated diagnostic (message modeled on kotlinc, e.g. "Explicit
  context arguments are not supported.") plus the normal `NO_CONTEXT_ARGUMENT` if
  unresolved.
- **Callable references** to any callable with context parameters (`::save`,
  `User::doStuff`, `::firstUser`): kotlinc 2.4 unconditionally reports
  `CALLABLE_REFERENCE_TO_CONTEXTUAL_DECLARATION` — "Callable reference to 'X' is
  unsupported because it has context parameters." (KEEP §5.1's eager resolution is
  NOT shipped in 2.4.) KLIO MUST emit the equivalent error.

JVM ABI/name mangling (KEEP §7.11–§7.13): not applicable to KLIO; internally,
context arguments precede the extension receiver which precedes value arguments in
the call layout.

## 9. Diagnostics summary (kotlinc names — KLIO mirrors these)

| Name | Severity | Trigger |
|---|---|---|
| `NO_CONTEXT_ARGUMENT` | error | no compatible implicit value for a context parameter (per parameter) |
| `AMBIGUOUS_CONTEXT_ARGUMENT` | error | ≥2 compatible values at the nearest matching level (per parameter) |
| `MULTIPLE_CONTEXT_LISTS` | error | two `context(...)` lists on one declaration |
| `CONTEXT_PARAMETER_WITHOUT_NAME` | error | bare-type (legacy receiver) entry |
| `CONTEXT_PARAMETER_WITH_DEFAULT` | error | default value on a context parameter |
| `CONTEXT_PARAMETERS_WITH_BACKING_FIELD` | error | contextual property with initializer/backing field |
| `NAMED_CONTEXT_PARAMETER_IN_FUNCTION_TYPE` | error | `name:`/`_:` inside a function type's context block |
| `CALLABLE_REFERENCE_TO_CONTEXTUAL_DECLARATION` | error | `::ref` to contextual callable |
| `RECEIVER_SHADOWED_BY_CONTEXT_PARAMETER` | error | §3.1 receiver/context cross-level mixing |
| `CONTEXTUAL_OVERLOAD_SHADOWED` | warning | overload always shadowed per §4.1 |
| `CONFLICTING_OVERLOADS` / `REDECLARATION` | error | identical context sets / duplicate names |
| `NOTHING_TO_OVERRIDE` | error | context list mismatch in override |
| `PARAMETER_NAME_CHANGED_ON_OVERRIDE` | warning | renamed context parameter in function override |
| `WRONG_MODIFIER_TARGET` | error | `vararg`/`val`/`var`/... on a context parameter |
| `CONTEXT_PARAMETER_MUST_BE_NOINLINE` | error | inlinable function-typed context parameter of an inline function |
| `COROUTINE_CONTEXT_AS_CONTEXT_PARAMETER_IS_RESERVED` | error | `CoroutineContext`-typed context parameter |
| `UNSUPPORTED` ("Context parameters on X are unsupported.") | error | invalid positions per §1.1 |
| `OVERLOAD_RESOLUTION_AMBIGUITY` | error | overloads differing only in contexts, both applicable |
| `ACTUAL_WITHOUT_EXPECT` / `EXPECT_ACTUAL_INCOMPATIBLE_CONTEXT_PARAMETER_NAMES` | error | expect/actual context mismatch / name mismatch |

Per project policy, KLIO's user-facing message texts mirror the kotlinc texts above
and never cite spec sections.

## 10. Test matrix

Each program is standalone (`klio run`). "OK:" lines are the exact stdout;
diagnostics name the required error/warning at the marked call.

T1 — happy path, named parameter + stdlib `context`:
```kotlin
interface Logger { fun log(m: String) }
context(logger: Logger) fun say(m: String) = logger.log("L: $m")
fun main() = context(object : Logger { override fun log(m: String) = println(m) }) {
    say("hi")
}
```
OK: `L: hi`

T2 — `_` parameter + bridge via named forwarder:
```kotlin
class Scope { fun greet() = println("hello") }
context(s: Scope) fun greet() = s.greet()
context(_: Scope) fun run2() = greet()
fun main() = context(Scope()) { run2() }
```
OK: `hello`

T3 — contextual property (getter), receiver-as-context source:
```kotlin
class Users { fun byId(i: Int) = "User $i" }
context(u: Users) val firstUser: String get() = u.byId(1)
fun main() = with(Users()) { println(firstUser) }
```
OK: `User 1` (the `with` receiver satisfies the context parameter)

T4 — contextual `var` with both accessors:
```kotlin
class Store { var cell = "" }
context(s: Store) var slot: String
    get() = s.cell
    set(value) { s.cell = value }
fun main() = context(Store()) { slot = "x"; println(slot) }
```
OK: `x`

T5 — nesting: inner context value shadows outer (no ambiguity):
```kotlin
context(s: String) fun show() = println(s)
context(_: String) fun main2() = context("inner") { show() }
fun main() = context("outer") { main2() }
```
OK: `inner`

T6 — ambiguity at one level → AMBIGUOUS_CONTEXT_ARGUMENT:
```kotlin
context(s: String) fun show() = println(s)
fun main() = context("a", "b") { show() }
```
Error: `AMBIGUOUS_CONTEXT_ARGUMENT` on `show` ("Multiple potential context arguments for 's' in scope.")

T7 — missing context → NO_CONTEXT_ARGUMENT:
```kotlin
context(s: String) fun show() = println(s)
fun main() { show() }
```
Error: `NO_CONTEXT_ARGUMENT` on `show` ("No context argument for 's' found.")

T8 — two same-type params on one declaration: named use OK, resolved use ambiguous:
```kotlin
context(s: String) fun show() = println(s)
context(a: String, b: String) fun f() { println(a + b); show() }
fun main() = context("x") { f() }   // one value fills both a and b
```
Error: `AMBIGUOUS_CONTEXT_ARGUMENT` on `show`; without that line prints `xx`.

T9 — extension receiver vs same-declaration context param are one level:
```kotlin
class A
context(ctx: T) fun <T> implicit(): T = ctx
context(a: A) fun A.f() { implicit<A>() }
fun main() = with(A()) { context(A()) { } }
```
Error: `AMBIGUOUS_CONTEXT_ARGUMENT` on `implicit`.

T10 — dispatch receiver satisfies a member's context (single source, OK):
```kotlin
class A {
    context(a: A) fun m() = println("m")
    fun go() = m()
}
fun main() = A().go()
```
OK: `m`

T11 — receiver shadowed by context → error:
```kotlin
class Cow { fun moo() {}
    fun test() = context(Cow()) { moo() } }
fun main() { Cow().test() }
```
Error: `RECEIVER_SHADOWED_BY_CONTEXT_PARAMETER` on `moo` (fix: `this.moo()` or `contextOf<Cow>().moo()`).

T12 — generic context parameter, explicit type argument:
```kotlin
context(ctx: T) fun <T> implicit(): T = ctx
fun main() = context(21) { println(implicit<Int>() * 2) }
```
OK: `42`

T13 — `contextOf` through a contextual-function-type lambda:
```kotlin
interface Logger { fun log(m: String) }
fun <A> withLog(block: context(Logger) () -> A): A =
    context(object : Logger { override fun log(m: String) = println(m) }) { block() }
fun main() { withLog { contextOf<Logger>().log("go") } }
```
OK: `go`

T14 — positional invocation of a contextual function type value:
```kotlin
fun call(f: context(String, Int) (Boolean) -> Unit) {
    f("s", 1, true)                       // all-positional
    context("t") { with(2) { f(false) } } // all-implicit
}
fun main() = call { b -> println("$b ${contextOf<String>()} ${contextOf<Int>()}") }
```
OK: `true s 1` then `false t 2`

T15 — overloads differing only in context: ambiguous with context, plus declaration warning:
```kotlin
fun f() = println("plain")
context(_: Any) fun f() = println("ctx")   // warning: CONTEXTUAL_OVERLOAD_SHADOWED
fun main() { f(); context("x" as Any) { f() } }
```
First call OK (`plain`); second: `OVERLOAD_RESOLUTION_AMBIGUITY` on `f`.

T16 — smart cast on a context parameter (KEEP §7.6):
```kotlin
context(s: String) fun bar() = println(s.length)
context(ctx: Any) fun foo() { if (ctx is String) bar() }
fun main() = context("abcd" as Any) { foo() }
```
OK: `4`

T17 — constructor context list rejected:
```kotlin
class A
class T context(c: A) constructor(x: Int)
```
Error: "Context parameters on constructors are unsupported." (kotlinc: `UNSUPPORTED` on the context list)

T18 — contextual property with initializer rejected:
```kotlin
class A
context(c: A) val p: String = ""
```
Error: `CONTEXT_PARAMETERS_WITH_BACKING_FIELD` on `context`.

T19 — multiple lists / default value / vararg rejected:
```kotlin
class A
context(a: A) context(b: A) fun f1() {}       // MULTIPLE_CONTEXT_LISTS
context(a: A = A()) fun f2() {}               // CONTEXT_PARAMETER_WITH_DEFAULT
context(vararg a: String) fun f3() {}         // WRONG_MODIFIER_TARGET
context(String) fun f4() {}                   // CONTEXT_PARAMETER_WITHOUT_NAME
```

T20 — statement-level disambiguation (call vs local declaration):
```kotlin
fun main() {
    context("v") { println(contextOf<String>()) }   // call to stdlib context
    context(c: Int) fun local() = println(c)        // local contextual function
    context(7) { local() }
}
```
OK: `v` then `7`

T21 — override must match; name change allowed:
```kotlin
class A
open class Base { context(a: A) open fun foo() = println("base") }
class D1 : Base() { override fun foo() = println("d1") }          // NOTHING_TO_OVERRIDE
class D2 : Base() { context(x: A) override fun foo() = println("d2") } // OK (name-change warning)
fun main() = with(A()) { D2().foo() }
```
Error on `D1.foo`: `NOTHING_TO_OVERRIDE`; with `D1` removed, OK: `d2`.

T22 — excluded: explicit context argument:
```kotlin
class A
context(a: A) fun needsA() = println("x")
fun main() { needsA(a = A()) }
```
Error: explicit context arguments unsupported (kotlinc: `UNSUPPORTED_FEATURE` on `a = A()` + `NO_CONTEXT_ARGUMENT` on `needsA`).

T23 — excluded: callable reference to a contextual declaration:
```kotlin
class A
context(a: A) fun save(x: Int) {}
fun main() = context(A()) { val r = ::save }
```
Error: `CALLABLE_REFERENCE_TO_CONTEXTUAL_DECLARATION` on `::save` ("Callable reference to 'save' is unsupported because it has context parameters.")

T24 — `NO_CONTEXT_ARGUMENT` reported per missing parameter:
```kotlin
context(a: String, b: Int) fun f() {}
fun main() { f() }
```
Errors: two `NO_CONTEXT_ARGUMENT` (for `a` and for `b`) on `f`.

## 11. Implementation status (KLIO)

Declarations and implicit resolution are implemented end to end.

- Parser: the `context(...)` modifier clause on functions (incl. local),
  accessor-only properties, and the leading `context(A, B)` block of a
  contextual function type; the statement-level call-vs-clause
  disambiguation (`context(x) { … }` call vs `context(c: T) fun …`
  declaration); structural rejections (`MULTIPLE_CONTEXT_LISTS`,
  `CONTEXT_PARAMETER_WITH_DEFAULT`, `WRONG_MODIFIER_TARGET`,
  `CONTEXT_PARAMETER_WITHOUT_NAME`, `NAMED_CONTEXT_PARAMETER_IN_FUNCTION_TYPE`,
  constructor `context` clause `UNSUPPORTED`).
- Resolver: context parameters are in scope by name in the body (functions,
  members, local functions, both property accessors); the overload key
  includes context types so context-differing overloads are not
  redeclarations.
- Runtime: a thread-local context stack (`CtxLoad`/`CtxScope` ir ops plus a
  per-frame receiver push) drives resolution. `context(v…) { block }` and
  `contextOf<T>()` are lowered directly; named context parameters load from
  the nearest compatible in-scope value; dispatch/extension/`with` receivers
  are context sources.
- Typeck: static resolution surfaces `NO_CONTEXT_ARGUMENT`,
  `AMBIGUOUS_CONTEXT_ARGUMENT`, `RECEIVER_SHADOWED_BY_CONTEXT_PARAMETER`,
  `CONTEXT_PARAMETERS_WITH_BACKING_FIELD`, `NOTHING_TO_OVERRIDE` +
  `PARAMETER_NAME_CHANGED_ON_OVERRIDE`, `CONTEXTUAL_OVERLOAD_SHADOWED` +
  `OVERLOAD_RESOLUTION_AMBIGUITY`, and the excluded-form diagnostics
  (`UNSUPPORTED` explicit context arguments,
  `CALLABLE_REFERENCE_TO_CONTEXTUAL_DECLARATION`).

Test matrix: all 24 rows pass (`src/itests/context_parameters.zig`). T14's
fully-positional invocation of a multi-context contextual function-type
value (`f("s", 1, true)`) lowers to a `CtxCall` op: a call site whose
callee is a parameter of contextual function type, passed `n_ctx +
n_regular` positional arguments, pushes its leading `n_ctx` arguments onto
the context stack and invokes the value with the rest. The implicit form
(`f(false)`, contexts from scope) keeps the ordinary value-call path.
