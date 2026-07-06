# Kotlin 2.4 semantics: annotation targeting and explicit backing fields

Implementation-ready semantics for three features that are stable at language version 2.4.
Sources: KEEP-0402 (`proposals/annotation-target-in-properties.md`), KEEP-0430
(`proposals/explicit-backing-fields.md`, supersedes the 2021/2022 KEEP-278 draft in the same
file), kotlinlang.org (annotations, properties, whatsnew22/23/24), the JetBrains/kotlin
compiler sources (FirAnnotationChecker, FirTypeResolveTransformer, AnnotationTargetUtils,
FirPropertyFieldTypeChecker, FirExplicitBackingFieldForbiddenChecker, FirErrors), and the
local stdlib checkout `kotlin/libraries/stdlib/src/kotlin/annotation/Annotations.kt`.

Language feature gates (from `LanguageVersionSettings.kt`, authoritative):

| Feature | Gate | Since | Issue |
|---|---|---|---|
| `@all` meta-target | `AnnotationAllUseSiteTarget` | LV 2.4 (preview 2.2 via `-Xannotation-target-all`) | KT-73256 |
| param-property defaulting | `PropertyParamAnnotationDefaultTargetMode` | LV 2.4 (preview 2.2 via `-Xannotation-default-target=param-property`) | KT-73255 |
| migration warning (old mode) | `AnnotationDefaultTargetMigrationWarning` | LV 2.2, dead once the mode above is on | KT-73255 |
| explicit backing fields | `ExplicitBackingFields` | LV 2.4 (preview 2.3 via `-Xexplicit-backing-fields`) | KT-14663 |

KLIO targets LV 2.4 semantics only: implement the new defaulting rule as the sole mode,
`@all` always enabled, explicit backing fields always enabled. The migration warning and the
`-X` flags are compiler-history notes, not KLIO behavior.

Shared machinery (used by both A and B). An annotation class `A` has an *allowed use-site
target set* `U(A)` derived from its `@Target` meta-annotation by this map
(`AnnotationTargetUtils.kt`):

| `AnnotationTarget` entry | use-site targets contributed |
|---|---|
| `FIELD` | `field`, `delegate` |
| `PROPERTY` | `property` |
| `PROPERTY_GETTER` | `get` |
| `PROPERTY_SETTER` | `set` |
| `VALUE_PARAMETER` | `param`, `receiver`, `setparam` |
| `FILE` | `file` |
| no `@Target` present | union of all rows above except `file` |

Other `AnnotationTarget` entries (CLASS, FUNCTION, ...) contribute nothing to `U(A)`.

---

## A. `@all:` use-site meta-target for properties

### Anchor rule

`@all:A` is legal only on a **member or top-level property declaration**, including a
`val`/`var` property declared in a primary constructor. It is an error (all severity ERROR,
diagnostic `INAPPLICABLE_ALL_TARGET`, message `'@all:' annotations cannot be applied to {0}.`)
on:

| anchor | `{0}` message argument |
|---|---|
| primary-constructor parameter without `val`/`var` | `constructor parameters without corresponding property (consider adding val/var)` |
| function/secondary-constructor parameter | `value parameters, only properties are allowed` |
| local property | `local properties, only member or top-level properties are allowed` |
| delegated property (`by ...`) | `delegated properties` |
| any non-property declaration (class, function, ...) | `elements other than properties` |

`@all` with multiple-annotation bracket syntax is an error regardless of anchor:
`@all:[A B]` reports `INAPPLICABLE_ALL_TARGET_IN_MULTI_ANNOTATION`
(`Multiple annotation syntax with '@all:' use-site target is forbidden, use '@all:A1 @all:A2 ...' instead.`).

### Expansion

For `@all:A` on property `P`, place a copy of the annotation (with no use-site target) on
each of the following, **skipping silently** any whose use-site target is not in `U(A)`:

1. the primary-constructor parameter (`param`), iff `P` is a primary-constructor property and `param ∈ U(A)`;
2. the property itself (`property`), iff `property ∈ U(A)`;
3. the backing field (`field`), iff `field ∈ U(A)` and `P` has a backing field;
4. the getter (`get`), iff `get ∈ U(A)`;
5. the setter parameter (`setparam`), iff `P` is `var` and `setparam ∈ U(A)`;
6. (JVM records only) the `RECORD_COMPONENT` when the class is `@JvmRecord`. Not applicable to KLIO.

Never propagated to: the property type, extension receiver, context parameters, the setter
as a method (`set`), or the delegate field.

Error case: if steps 1-5 all skip (no expanded target is applicable), the annotation is
reported with `WRONG_ANNOTATION_TARGET_WITH_USE_SITE_TARGET`:
`This annotation is not applicable to target 'property' and use-site target '@all'. Applicable targets: {...}`.
There is no warning for partially applicable sets; one applicable target suffices.

Note `setparam` membership comes from `AnnotationTarget.VALUE_PARAMETER` (see the shared
map), so a `VALUE_PARAMETER`-targeted annotation under `@all` on a `var` constructor
property lands on both `param` and `setparam`.

### Interaction with other rules

- `@all` cannot be combined with another use-site target in the same entry (grammar allows
  one target per entry). Separate entries may overlap; if a non-repeatable annotation ends up
  twice on the same target (e.g. `@all:A @field:A val x` where `field ∈ U(A)`), report
  `REPEATED_ANNOTATION` (`This annotation is not repeatable.`).
- Repeatable annotations may be used with `@all` freely; repetition checking runs per final
  target after expansion.
- `@all` on a property with an *explicit backing field* (feature C) treats that field as the
  backing field for step 3.
- Deprecation: `@all:Deprecated` propagates deprecation to the accessors as well (KT-83460).

### Test matrix A

Annotation declarations used below (Kotlin-declared; retention default RUNTIME):

```kotlin
@Target(AnnotationTarget.VALUE_PARAMETER, AnnotationTarget.PROPERTY,
        AnnotationTarget.FIELD, AnnotationTarget.PROPERTY_GETTER)
annotation class Wide
@Target(AnnotationTarget.FIELD) annotation class FieldOnly
@Target(AnnotationTarget.PROPERTY_GETTER) annotation class GetOnly
@Target(AnnotationTarget.FUNCTION) annotation class FunOnly
@Target(AnnotationTarget.VALUE_PARAMETER) annotation class ParamOnly
```

Expected placement is the observable result: reflection (`ctor.parameters[i].annotations`,
`prop.annotations`, `prop.getter.annotations`, backing-field annotations, setter parameter
annotations) must report exactly the listed targets; all other targets report none.

| # | Program (core) | Expected |
|---|---|---|
| A1 | `class U(@all:Wide val e: String)` | placement: param, property, field, get. No setparam (val). No diagnostic. |
| A2 | `class U(@all:Wide var e: String)` | placement: param, property, field, get, setparam (`VALUE_PARAMETER` covers setparam). |
| A3 | `class U { @all:Wide val e: String = "x" }` | placement: property, field, get. No param (not a constructor property). |
| A4 | `class U { @all:GetOnly val e: String get() = "x" }` (custom getter, no backing field) | placement: get only. No error; one applicable target suffices, field skipped because no backing field exists. |
| A5 | `class U(@all:FunOnly val e: String)` | error `WRONG_ANNOTATION_TARGET_WITH_USE_SITE_TARGET`: not applicable to target 'property' and use-site target '@all'; nothing applies. |
| A6 | `class U { @all:Wide val e: String by lazy { "x" } }` | error `INAPPLICABLE_ALL_TARGET`: `'@all:' annotations cannot be applied to delegated properties.` |
| A7 | `fun f() { @all:Wide val x = 1 }` | error `INAPPLICABLE_ALL_TARGET`: local properties message. |
| A8 | `class U(@all:Wide val e: String, @all:[Wide FieldOnly] val f: String)` | error `INAPPLICABLE_ALL_TARGET_IN_MULTI_ANNOTATION` on the bracketed entry; `e` unaffected (param, property, field, get). |
| A9 | `class U(@all:ParamOnly val e: String)` | placement: param only (property/field/get skipped silently). No diagnostic. |
| A10 | `class U(@all:FieldOnly @field:FieldOnly val e: String)` | error `REPEATED_ANNOTATION` (both entries resolve to the backing field; FieldOnly is not repeatable). |
| A11 | `class U(@all:Wide x: String)` (no val/var) | error `INAPPLICABLE_ALL_TARGET`: constructor-parameters-without-property message. |
| A12 | `@all:Wide val top: Int = 1` (top-level) | placement: property, field, get. Top-level properties are valid anchors. |

---

## B. Defaulting rules for annotations without a use-site target

Applies to an annotation entry `@A` written with **no** use-site target on a property or
primary-constructor property. Only the `param`, `property`, `field` (and `delegate`)
members of `U(A)` participate; `get`/`set`/`setparam`/`receiver` are never defaulted to.

### Old rule (LV <= 2.1; LV 2.2-2.3 kept it plus a warning)

Choose the **first applicable** target from the ordered list `param`, `property`, `field`,
and place the annotation only there. Applicability: `param` requires a primary-constructor
property and `param ∈ U(A)`; `property` requires `property ∈ U(A)`; `field` requires a
backing field and `field ∈ U(A)`. If none of the three is applicable the annotation is
checked against the declaration itself and rejected with `WRONG_ANNOTATION_TARGET`
(`This annotation is not applicable to target '{0}'. Applicable targets: {1}`).

### New rule (LV 2.4, stable; the only mode KLIO implements)

> If the constructor parameter target `param` is applicable, use it.
> If any of `property` or `field` is applicable, ALSO use the first of those.
> It is an error if there are multiple targets and none of `param`, `property`, `field` is applicable.

Normative algorithm for `@A` (no use-site target) on declaration `D`:

1. `D` is a primary-constructor `val`/`var` property and `param ∈ U(A)`:
   - place on `param`;
   - if `property ∈ U(A)`: also place on `property`;
   - else if `D` has a backing field and `field ∈ U(A)` and the containing class is **not an
     annotation class**: also place on `field`;
   - else: `param` only.
2. Otherwise (member/top-level property, or constructor property with `param ∉ U(A)`):
   - if `property ∈ U(A)`: place on `property`;
   - else if `D` has a backing field and `field ∈ U(A)`: place on `field`;
   - else if `D` is delegated and `delegate ∈ U(A)` (i.e. `AnnotationTarget.FIELD` present):
     place on the delegate storage field;
   - else: the annotation stays on the property and normal target checking applies
     (`WRONG_ANNOTATION_TARGET` if the annotation cannot target a property).

Consequences, per the four cases in scope:

| Declaration | `U(A)` contains | Old target | New target(s) |
|---|---|---|---|
| ctor `val`/`var` | param, property, field | param | **param + property** |
| ctor `val`/`var` | param, field (Java-style, no PROPERTY) | param | **param + field** |
| ctor `val`/`var` | param only | param | param (unchanged) |
| ctor `val`/`var` | property, field (no param) | property | property (unchanged) |
| member property with backing field | property (+ anything) | property | property (unchanged) |
| member property with backing field | field, no property | field | field (unchanged) |
| property without backing field (custom getter) | property | property | property (unchanged) |
| property without backing field | field only | error `WRONG_ANNOTATION_TARGET` | error (unchanged) |
| delegated property | property | property | property (unchanged) |
| delegated property | field only (no property) | delegate storage field | delegate storage field (unchanged; explicit `@delegate:` preferred) |
| annotation-class ctor property | param, field, no property | param | param (field placement suppressed inside annotation classes) |

Only case 1 with `property` or `field` also applicable changes behavior; everything else is
identical to the old rule. Annotations with a single relevant target (e.g. a
`@Target(AnnotationTarget.PROPERTY)` `@SerialName`-style annotation) are unaffected.

### Warnings history (not implemented in KLIO, recorded for parity)

- LV 2.2-2.3 default: old placement plus WARNING
  `ANNOTATION_WILL_BE_APPLIED_ALSO_TO_PROPERTY_OR_FIELD`:
  `This annotation is currently applied to the value parameter only, but in the future it will also be applied to {property|field}.`
  Emitted only when the entry has no use-site target and both `param` and one of
  `property`/`field` are applicable. Suppressed for `@Deprecated`, `@DeprecatedSinceKotlin`,
  `@Suppress`, `java.lang.Deprecated`, `java.lang.SuppressWarnings`, `@OptIn`, opt-in marker
  annotations, and for the `field` case inside annotation classes.
- LV 2.4: the param-property mode is on; the warning is retired (its guard disables it when
  the new mode is enabled). The old KEEP flag spelling `-Xannotation-defaulting` shipped as
  `-Xannotation-default-target=first-only|first-only-warn|param-property`.

### Observability in KLIO

Target assignment is visible to reflection-driven libraries: an annotation on `param` is
returned for the constructor `KParameter`, on `property` for the `KProperty`, on `field`
for the backing field (Java field reflection; in KLIO whatever surface exposes field
annotations, including future serialization support). kotlinx.serialization's own
annotations are `@Target(PROPERTY)` so rule B does not move them; the rule matters for
user-defined multi-target annotations and validation-style libraries.

### Test matrix B

Annotations:

```kotlin
@Target(AnnotationTarget.VALUE_PARAMETER, AnnotationTarget.PROPERTY, AnnotationTarget.FIELD)
annotation class PPF
@Target(AnnotationTarget.VALUE_PARAMETER, AnnotationTarget.FIELD) annotation class PF
@Target(AnnotationTarget.VALUE_PARAMETER) annotation class P
@Target(AnnotationTarget.PROPERTY, AnnotationTarget.FIELD) annotation class RF
@Target(AnnotationTarget.FIELD) annotation class F
@Target(AnnotationTarget.PROPERTY_GETTER) annotation class G
```

Expected = exact final placement under LV 2.4 (reflection-observable), or diagnostic.

| # | Program (core) | Expected |
|---|---|---|
| B1 | `class C(@PPF val x: Int)` | param + property. Not field. (Old: param only.) |
| B2 | `class C(@PF val x: Int)` | param + field. (Old: param only.) |
| B3 | `class C(@P val x: Int)` | param only. Unchanged. |
| B4 | `class C(@RF val x: Int)` | property only (param not in `U`). Unchanged. |
| B5 | `class C { @PPF val x = 1 }` | property only (member property, rule 2, property preferred). Unchanged. |
| B6 | `class C { @F val x = 1 }` | field only. Unchanged. |
| B7 | `class C { @F val x: Int get() = 1 }` | error `WRONG_ANNOTATION_TARGET`: not applicable to target 'member property without backing field or delegate'. |
| B8 | `class C { @G val x = 1 }` | error `WRONG_ANNOTATION_TARGET` (never defaults to `get`; explicit `@get:G` required). |
| B9 | `class C { @RF val x: Int by lazy { 1 } }` | property only (delegated; property applicable). |
| B10 | `annotation class Meta(@PF val x: Int)` | param only: field placement suppressed inside annotation classes. |
| B11 | `class C(@PF var x: Int)` | param + field; setter/setparam untouched (defaulting never targets setparam). |
| B12 | `class C(@param:PPF val x: Int)` | param only. An explicit use-site target disables defaulting entirely. |

---

## C. Explicit backing fields

Implemented in KLIO: the parser accepts the field clause on member/top-level
properties (syntax error on constructor/local properties), typeck enforces the
static-rule table and the scope-narrowing access rule below, and lowering
treats the field initializer as the property's storage initializer. Coverage:
`zig build itest-explicit_backing_fields` (the full test matrix C), parser and
typeck unit tests, and `examples/backing_fields.kt`.

### Status and history

Stable at LV 2.4 (preview in 2.3 behind `-Xexplicit-backing-fields`). The shipped design is
KEEP-0430 ("Explicit Backing Fields", Roman Efremov). The earlier draft in the same KEEP
file (2021-2022, prototyped in K2 1.7, discussed as KEEP-278) proposed strictly more:
`internal` field visibility (with `protected` as a future extension), `var` properties,
custom accessors with `field` referring to the explicit field inside them,
compiler-derived getters/setters based on the field/property subtyping direction, `lateinit`
fields, and direct field access that bypassed the getter inside the private scope. **All of
that was cut.** Stable 2.4 ships: `val`-only, accessor-less, implicitly `private` field,
narrowing-through-getter semantics. Any modifier on the field declaration (visibility,
`lateinit`, `const`, `open`, `final`, ...) is rejected with `WRONG_MODIFIER_TARGET`.

### Grammar

`propertyDeclaration` gains an optional field clause in the initializer/delegate slot
(exact KEEP-0430 diff):

```diff
propertyDeclaration ::=
    modifiers? ('val' | 'var') typeParameters?
    (receiverType '.')?
    (multiVariableDeclaration | variableDeclaration)
    typeConstraints?
-   (('=' expression) | propertyDelegate)? ';'?
+   ((('field' (':' type)? )? ('=' expression)?) | propertyDelegate)? ';'?
    ((getter? (semi? setter)?) | (setter? (semi? getter)?))
```

- `field` is a contextual keyword sitting where the property initializer would go: after the
  property header (name, type, type constraints), before any accessor. Same line or a
  following line; conventionally indented on the next line.
- `field: Type = expr`, `field = expr` (type inferred from `expr`), and `field: Type`
  (no initializer; deferred initialization) are all valid. Bare `field` with neither type
  nor initializer takes the property's type (and is then redundant, see below).
- The clause is **parsed only for physical property declarations**: a field clause on a
  primary-constructor property or on a local property is a **syntax error** (the K2 parser
  emits SYNTAX; KLIO should emit its parse diagnostic at the `field` token).
- The property type may be omitted; it is then inferred from the field type (KT-83756 fixed
  resolution for this shape). An inferred property type equals the field type, so the
  `REDUNDANT_EXPLICIT_BACKING_FIELD` warning fires; useful declarations always write the
  property type explicitly.

### Static rules and diagnostics (all ERROR unless noted)

For property `P : Tp` with explicit field `f : Tf`:

| Rule | Diagnostic | Message |
|---|---|---|
| `P` must be `val` | `VAR_PROPERTY_WITH_EXPLICIT_BACKING_FIELD` (on `var` keyword) | `Only 'val' properties with explicit backing fields are supported.` |
| `P` must have no accessor with a body (no custom getter; setter impossible for val) | `PROPERTY_WITH_EXPLICIT_FIELD_AND_ACCESSORS` (on the accessor) | `Properties with explicit backing fields cannot have accessors.` |
| `P` must not also have a property initializer | `PROPERTY_INITIALIZER_WITH_EXPLICIT_FIELD_DECLARATION` (on the initializer) | `Property initializers are prohibited for properties with explicit backing field declaration.` |
| `P` must be effectively final (not `open` in a non-final class, not `override`d-able) | `NON_FINAL_PROPERTY_WITH_EXPLICIT_BACKING_FIELD` | `Properties with explicit backing fields must be final.` |
| `P` must not be `abstract` | `EXPLICIT_BACKING_FIELD_IN_ABSTRACT_PROPERTY` (on `field`) | `Abstract property cannot have a backing field.` |
| not inside an interface | `EXPLICIT_BACKING_FIELD_IN_INTERFACE` (on `field`) | `Backing fields inside interfaces are prohibited.` |
| `P` must not be an extension property | `EXPLICIT_BACKING_FIELD_IN_EXTENSION` (on `field`) | `Extension properties cannot have a backing field.` |
| `P` must not be `expect` | `EXPECT_PROPERTY_WITH_EXPLICIT_BACKING_FIELD` | `'expect' properties are not allowed to declare explicit backing fields.` |
| `P` must not be delegated (`by`) | `BACKING_FIELD_FOR_DELEGATED_PROPERTY` (on `field`) | `Delegated properties cannot have explicit backing field declarations.` |
| `P` must not be `private` (field is private; property must be strictly more visible) | `EXPLICIT_FIELD_VISIBILITY_MUST_BE_LESS_PERMISSIVE` (on the visibility modifier) | `Private properties cannot have explicit backing fields.` |
| `Tf` must be a subtype of `Tp` | `INCONSISTENT_BACKING_FIELD_TYPE` (on the property signature) | `The type of the backing field must be a subtype of the property's type.` |
| `Tf == Tp` | WARNING `REDUNDANT_EXPLICIT_BACKING_FIELD` (on `field`) | `Explicit backing field declaration is unnecessary if it has the same type as the property.` |
| no modifiers on the field clause (any visibility, `lateinit`, `abstract`, `open`, `final`, `const`, `inline`, ...) | `WRONG_MODIFIER_TARGET` (on the modifier) | standard wrong-modifier-target message |
| `@JvmField` on `P` prohibited | (JVM-only; KLIO: reject `@JvmField` here) | |
| `const val` cannot have a field clause | via const-property checks (const requires initializer; field clause forbids it) | |
| field declared without initializer must be definitely assigned in every construction path (init blocks / secondary constructors), assignment `p = v` inside init assigns the field and `v` must conform to `Tf` | `EXPLICIT_FIELD_MUST_BE_INITIALIZED` (on the field declaration) | `Field must be initialized.` |

`PROPERTY_FIELD_DECLARATION_MISSING_INITIALIZER` exists in the compiler's diagnostic list
but has no live reporting site; do not implement it. Deferred initialization plus
`EXPLICIT_FIELD_MUST_BE_INITIALIZED` covers the missing-initializer space.

Annotating the field: use `@field:Ann` on the property (or `@all:` per feature A). The
field clause itself accepts no modifier list in the stable surface.

### Access semantics (narrowing)

- The backing field is compiled/stored with type `Tf`. The property's public type stays `Tp`.
- **Inside the declaring scope**, reads of `P` see type `Tf`. Declaring scope = exactly where
  a `private` property declared in the same position would be accessible: the whole body of
  the declaring class (member functions, init blocks, companion, nested and inner classes),
  or the whole file for a top-level property. The narrowing applies to any receiver, not
  just `this`: inside class `C`, `other.p` for `other: C` also sees `Tf`.
- **Outside** the declaring scope the property has type `Tp` only.
- The access conceptually goes through the getter and is cast: `city.value = x` behaves as
  `(getCity() as MutableLiveData<String>).setValue(x)`. Implementations may read the field
  directly; KLIO should read the field slot directly (no user getter can exist).
- Narrowing is **disabled inside non-private inline functions** (`public`, `internal`,
  `protected` inline members): there `P` is `Tp`. Private inline functions keep `Tf`.
- Narrowing does not flow through callable references: `::p` / `C::p` is a
  `KProperty<Tp>`.
- In init blocks and secondary constructors of the declaring class, `p = expr` (for a field
  declared without initializer) is a field assignment requiring `expr : Tf`.

### Test matrix C

All diagnostics are the exact ones from the table above; "ok" rows must run and print.

| # | Program (core) | Expected |
|---|---|---|
| C1 | `class Cart { val items: List<String>` `field = mutableListOf<String>()` `fun add(s: String) { items.add(s) } }` then `val c = Cart(); c.add("a"); println(c.items)` | ok, prints `[a]`. `items.add` resolves because `items` is `MutableList<String>` inside `Cart`. |
| C2 | same as C1 plus, outside the class: `c.items.add("b")` | error: unresolved reference `add` on `List<String>` (no narrowing outside; KLIO's standard unresolved-member diagnostic on `add`). |
| C3 | `class C { val n: Number` `field: Int = 1` `fun inc() = n + 1 }` | ok; `n` is `Int` inside `C`; `C().inc()` prints `2` when printed. |
| C4 | `class C { var n: Number` `field: Int = 1 }` | error `VAR_PROPERTY_WITH_EXPLICIT_BACKING_FIELD` on `var`. |
| C5 | `class C { val n: Number` `field: Int = 1` `get() = 5 }` | error `PROPERTY_WITH_EXPLICIT_FIELD_AND_ACCESSORS` on the getter. |
| C6 | `class C { val n: Int` `field: String = "x" }` | error `INCONSISTENT_BACKING_FIELD_TYPE` (String is not a subtype of Int). |
| C7 | `class C { val n: Int` `field: Int = 1 }` | warning `REDUNDANT_EXPLICIT_BACKING_FIELD`; program still runs. |
| C8 | `open class C { open val n: Number` `field: Int = 1 }` | error `NON_FINAL_PROPERTY_WITH_EXPLICIT_BACKING_FIELD`. |
| C9 | `interface I { val n: Number` `field: Int = 1 }` | error `EXPLICIT_BACKING_FIELD_IN_INTERFACE`. |
| C10 | `class C { private val n: Number` `field: Int = 1 }` | error `EXPLICIT_FIELD_VISIBILITY_MUST_BE_LESS_PERMISSIVE` on `private`. |
| C11 | `class C { val n: Number` `internal field = 1 }` (likewise `private`, `protected`, `public`, `lateinit`, `open`, `final`, `const` before `field`) | error `WRONG_MODIFIER_TARGET` on the modifier. |
| C12 | `class C { val ns: List<Int>` `field: MutableList<Int>` `init { ns = mutableListOf(1) } fun peek() = ns[0] }` | ok; deferred field init in `init`; `C().peek()` yields `1`. |
| C13 | `class C { val ns: List<Int>` `field: MutableList<Int> }` (no init assignment) | error `EXPLICIT_FIELD_MUST_BE_INITIALIZED` on the field declaration. |
| C14 | `class C(val xs: List<Int> field: MutableList<Int> = mutableListOf())` | syntax error at `field`: field clauses are not allowed on constructor properties. |
| C15 | `fun f() { val xs: List<Int>` `field = mutableListOf<Int>() }` | syntax error at `field`: no local explicit backing fields. |
| C16 | `class C { val n: Number` `field: Int = 1` `by lazy { 2 } }` (delegate plus field) | error `BACKING_FIELD_FOR_DELEGATED_PROPERTY`. |
| C17 | `class C { val n: Number` `field = 1` `inner class I { fun g() = n + 1 } }` | ok; narrowing (`Int`) holds in inner/nested classes; `C().I().g()` yields `2`. |
| C18 | `val top: List<Int>` `field = mutableListOf(1)` `fun main() { top.add(2); println(top) }` (same file) | ok, prints `[1, 2]`; top-level narrowing is file-scoped. |

---

## KLIO implementation notes

- A and B are the same pass: after resolving an annotation entry's `@Target` set, either
  expand `@all` (A) or run the defaulting algorithm (B) and record annotations against
  distinct anchors: constructor parameter, property, backing field, getter, setter
  parameter. KLIO's annotation storage must keep these anchors separate for reflection and
  for serialization metadata.
- The compiler implements B by duplicating a target-less annotation onto both the parameter
  and the property during lowering, then pruning per the algorithm; replicating that shape
  (duplicate then prune) is the simplest way to match placement exactly.
- C needs: parser support for the field clause (property-only), a second type slot on
  property symbols (`Tp` public, `Tf` storage), the narrowing rule keyed to private-property
  accessibility, and the diagnostic set above. The interpreter stores the field at `Tf` and
  serves reads directly; no getter body exists by construction.
