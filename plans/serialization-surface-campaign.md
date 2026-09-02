# Serialization-surface campaign: real Json surface, json census, ktor shim swap

STATUS 2026-09-02: NOT STARTED. One vein, two payouts: the
kotlinx.serialization pack grows the real upstream serializer surface,
which (a) lets the json test suite run as a standing census and (b)
unblocks KTOR-SERVER-UPSTREAM.md Phase 2 — the ONE coordinated swap of
the vendored client+server serialization shims for upstream
content-negotiation.

## Measured starting facts (do not re-derive)

- The serialization census covers `core/commonTest` only: 34 files,
  baseline 138, at zero failures. Upstream's json suite is ALREADY in
  the checkout at
  `kotlin-klio/klio-kotlinx-serialization/upstream/formats/json-tests/`
  (185 .kt files) and is completely uncensused; `formats/json/` (the
  format sources) is checked out too.
- The pack today serves JSON through the `__klsx_json*` intrinsics
  behind a bridge (`Json.decodeToClass`); the REAL surface upstream
  compiles against is: `Json : StringFormat`, `serializersModule`,
  `serializerOrNull(KType)` / `getContextual`, and the builtin
  serializers. That exact list is what KTOR-SERVER-UPSTREAM.md Phase 2
  records as the swap blocker, plus: ClientSSESession in the
  ktor-client-core include list, `io/ktor/server/plugins/Errors.kt`
  in server-core, and a decision on `ExperimentalJsonConverter.kt`
  (imports kotlinx-serialization-json-io, absent from the pack —
  exclude it and record why, or pull json-io).
- The census-growth recipe is banked (ktor 322 -> 465, memory
  klio-ktor-commontest-campaign): pack-rebuild-first, add ONLY files a
  failing test names to include lists, per-file children, ratchet the
  floor as fixes land.
- The shims being replaced (`shim/client-serialization`,
  `shim/server-serialization`) both declare
  `io.ktor.serialization.kotlinx.json.json()` on fake configs; they
  must swap TOGETHER, and the ktor e2e gates (all green today) are
  the acceptance harness.

## Task 1 — the serialization lowering pass (REDIRECTED 2026-09-02)

- DECISION (user-directed, 2026-09-02): the reflective serializer
  (klioMain Reflective.kt + the `__klsx_*` host intrinsics) is the
  wrong engine and retires. Upstream's runtime and its json tests are
  written against what the COMPILER PLUGIN generates — nested
  `$serializer` objects over PluginGeneratedSerialDescriptor, the
  element-mask `deserialize` loop, `childSerializers()`, sealed /
  polymorphic / enum / object / value-class / generic forms, property
  annotations pushed into descriptors — and reflection can only
  approximate that contract while living in host intrinsics that the
  static-dispatch, bytecode, leaf, and transpile tiers cannot see
  through. The compose precedent is exact: the implicit hook capped
  out; the lowering plugin made upstream's own tests pass.
- Build a serialization pass that, for every `@Serializable`
  declaration, synthesizes the real generated artifacts as ORDINARY
  KOTLIN DECLARATIONS before lowering (generated source text parsed
  and spliced into the class: the `$serializer` object implementing
  GeneratedSerializer with descriptor/serialize/deserialize/
  childSerializers, the companion `serializer()` (with type-argument
  serializers for generics), the deserialization constructor with
  the seen-mask + missing-field check + default evaluation, and the
  enum/object/sealed/polymorphic/value-class/`with=` forms). One
  choke point right after parse, shared by pack builds and program
  loads, so packs carry generated serializers too. Dumpable under an
  env var for debugging.
- The upstream json module (formats/json/commonMain) is consumed
  verbatim with klio actuals for its five `expect`s (landed
  2026-09-02, plus the `package x;` parser fix it exposed).
  `Json.decodeToClass` stays as a thin bridge over
  `serializerOrNull` until Task 3 deletes the shims.
- Exit for this task: Reflective.kt and the `__klsx_*` intrinsics
  deleted; the core census (138) holds; the json census (Task 2)
  measures fidelity.

## Task 2 — json census

- FIRST COUNT 2026-09-02 (generating pass in, reflective engine gone):
  serialization_json 149 passed / 595 failed / 1 DNC across 126 files
  (klio-census, harness binary). Top failing classes: ContextualTest
  120, JsonCustomSerializersTest 31, SerializersLookupTest 19,
  JsonTreeTest 13, JsonPathTest 12, JsonEnumsCaseInsensitiveTest 12,
  JsonExponentTest 11, JsonEncoderDecoderRecursiveTest 11,
  JsonDecodingErrorMessagesTest 11, InlineClassesTest 10. The core
  census (previously 138/0 on the reflective engine) regressed on the
  swap and is the exit gate to drive back first.
- Suite wiring: `serialization_json` in commontest_support.zig
  (per-file children, `--feature kotlinx.serialization/json` via the
  new `extra_args`), itest `serialization_json_commontest`, the
  `[[test]] feature = "json"` block in klio.toml, and klioTest/json
  stand-ins for the okio / kotlinx-io buffer types and the json-okio /
  json-io adapters (string-backed; the same streaming codec runs).

- Wire `formats/json-tests` (and the json format sources it needs)
  into the serialization suite (or a sibling `serialization_json`
  suite in commontest_support.zig with its own scratch home, packs,
  ratchet floor, and child caps). First full run = the count; then
  drive failures down root-cause-first exactly like the ktor census
  (each failure names an interpreter or pack-surface root; test edits
  never).
- Ratchet the floor at the first stable green count; the plan records
  the count trajectory and the named roots.
- TRAJECTORY 2026-09-02 (klio-census on the harness binary; core /
  json passed): engine swap 68 / 149 -> round four 128 / 312 -> round
  six 129 / 439 -> round seven 123 / 453 (six ModuleBuildersTest
  regressions: a bare `A::class` inside a member extension of the
  outer resolved another file's `A`) -> round eight 129 / 479.
  Named roots landed on the way (each a shared interpreter mechanism,
  no test edits):
  - runtime member-overload pick: a trailing lambda never binds a
    builtin-typed parameter (`cast(value, serialName, tag: String)`
    took the lambda; the inline pick, the own-member preference and
    the extension fallback all fell through to `cast(..., path)`);
  - reified `T` in argument position binds from the callee's declared
    parameter type (function or primary constructor) and from an
    `assertEquals` sibling of statically known type (constructor call,
    typed local); a nested class as a constructor argument renames
    through the CALLER's lexical owner after the callee frame is pushed;
  - a typed local keeps its type arguments into the reified binding
    (`serializer<T>()` behind a `Collection<String>` argument);
  - parser: a trailing lambda may start on the next line after a
    parenthesised call (JsonExponentTest 4 -> 10 of 11);
  - constructor delegation binds named arguments by the target's
    parameter names (`MissingFieldException` swapped message and field
    list; every "but it was missing" assertion depended on it);
  - a type-form reference to an extension property
    (`JsonPrimitive::booleanOrNull`) reads the property on its receiver;
  - generator: an interface-typed property is polymorphic unless the
    interface carries its own `@Serializable`; a generic `with=`
    serializer receives the type-argument serializers;
  - companion singletons register under the enclosing-chain-qualified
    key and never fall to a top-level namesake; `TypeName::class`
    applies the nested rename first;
  - builtin serializer table matches the native platform (unsigned
    types and arrays, Duration, Instant, Uuid).
  Rounds nine to fifteen (2026-09-02, later): core 129 -> 134 / 138,
  json 479 -> 536 / 744. Roots: a nested class constructed as a reified
  argument renames through the CALLER's lexical owner (dotted and
  member-chain constructor paths included); an unannotated enum
  serializes through `createSimpleEnumSerializer`; a generic `with=`
  class gets a factory taking the type-argument serializers; nested
  type-argument heads rename through the caller's owner
  (`ThirdPartyBox<Item>`); the sibling expected-type solver judges the
  `assertEquals` overload whose parameter is a type variable; a member
  property typed only by its initializer call (`val json = Json { }`)
  gets its class at lowering time and the inline pick's receiver gate
  types a bare property receiver through the owner's property heads; an
  explicit-receiver call whose arguments disprove the receiver's own
  member opens the inline path for the reified member extension (the
  JsonTestBase `parametrizedTest` shape); a bare call inside a `Json.`
  extension body splices Json's reified member when no enclosing member
  takes the call by signature (`enclosingMemberTakes` consults registered
  signatures where a lazily lowered body carries no arity mask); the
  applicability scorer rejects a bare type-variable argument for a
  concrete class parameter; a header stub with a declared receiver is an
  extension for the index; the receiver-formed pass applies declared-type
  compatibility; a reified member extension of the enclosing class binds
  its parameter from the call's expected type and lowers as a typed member
  call; a nested class without a companion never answers with a top-level
  namesake's companion.
  Rounds sixteen to eighteen: core 134 -> 135 / 138 (the one regression
  from round fourteen root-fixed: the type-variable rule now lives in
  the lowering's per-argument compatibility with the caller's bounds,
  a bodyless member header is applicable by its declared arity so Map's
  own `get` outranks the `Map<out K, V>.get` extension, a header stub
  with a declared receiver is an extension for the declaration kind, a
  receiver-formed pick checks the extension's receiver against the
  enclosing body's receiver head); generator: a `@Serializable`
  superclass's properties serialize first through the supertype
  arguments (GenericOverrideTest 0 -> 2), `@KeepGeneratedSerializer`
  emits the generated twin plus a companion `generatedSerializer()`
  for classes, value classes, generic classes, enums, forClass
  companions and objects (KeepGeneratedSerializerTest 0 -> 5 of 7);
  lowering: the splice floor hides the caller's locals for extension
  splices too, a narrowed member extension must be visible from the
  enclosing hierarchy, a receiver's own reified inline member opens the
  inline path (the image keeps it bodiless), a member without a
  registered function id splices its AST, a nullable constructor
  parameter binds the class type parameter.
  Json after rounds sixteen to eighteen: 554 / 744.
  Rounds nineteen and twenty (json buckets, all root fixes shared with
  the interpreter): dispatch — an interface default called from a class
  whose DECLARING interface was still an unfilled header bound direct,
  so the json encoder's `encodeSerializableValue` override never ran
  from `AbstractEncoder.encodeSerializableElement` and every sealed or
  polymorphic PROPERTY encoded in array form (an unknown declarer now
  dispatches virtual; SealedClassesSerializationTest 4 -> 11 of 11);
  reads — a bare name inside a spliced receiver lambda binds by the
  subject's STATIC class (kotlinc's implicit-receiver ranking), never
  the runtime object's same-named private field (`descriptor` inside
  `decoder.decodeStructure(descriptor) { }` read the decoder's), and a
  splice subject record keeps the floor-hidden `this` beneath it
  (ClassDiscriminatorModeAllObjectsTest 1 -> 9 of 9, None 11 of 11);
  inference — a star projection never binds a reified parameter
  (`DeserializationStrategy<*>` as an expected type solved `T := *` and
  reached the runtime as a global named `*`), the dotted receiver of a
  companion `serializer()` argument rides as a qualified path resolved
  through the class fqn suffix (`subclass(A.B.C.serializer())`), a
  supertype's nested classifiers are in scope in a subclass body (a
  nested class with a companion lifts mangled, and the alias walk now
  follows the supertype chain), and a typed member call carries the
  full generic spelling to the runtime beside the class binding while
  a registered member with no type-parameter record splices instead;
  generator — the kept object serializer is fully qualified (a test's
  own `object ObjectSerializer` shadowed the builtin) and cached, and
  a generic sealed leaf's serializer takes `PolymorphicSerializer(Any::class)`
  per type argument as the plugin emits.
  Rounds twenty-one and twenty-two: two suite hangs were one root — the
  typed-call KType spelling lookup released the globals borrow twice, so
  the next borrow spun forever (KeepGeneratedSerializerTest 7 of 7,
  SerializersLookupTest 22 -> 28 of 31); a constructor reference
  (`composerAs(::ComposerForUnsignedNumbers)`) now solves the reified
  parameter it returns, so the json encoder's unsigned composer is chosen
  (UnsignedIntegersTest 0 -> 5 of 5); LOCAL `@Serializable` classes get
  their generated shapes as nested members, and the runtime registers a
  local class's companion and nested objects (constructed once, the
  companion reachable through the class value ahead of any `KClass`
  extension, a private nested object of an enclosing class reachable
  through the mangled name) — 65 local declarations across the json
  tests depended on it (JsonPathTest 14 of 14); a generic constructor
  local (`val t = Triple("1", 2, Box(42))`) records its instantiated
  type, a `listOf(42)` argument types through the static call
  derivation without a dangling `T`, a nullable spelling rides the
  typed-call side binding and the sibling solver keeps a spelled `?`;
  descriptor annotations are `@SerialInfo` annotations only (the
  plugin's rule — `@ExperimentalUnsignedTypes` reached the runtime as a
  constructor); a custom or contextual serializer on a primitive-typed
  property routes through the serializer instead of the primitive fast
  path; a 36-field class's masks are signed literals; a `@Contextual`
  element of a `@Serializable` class passes its generated serializer as
  the contextual fallback (core: BasicTypesSerializationTest,
  SerialDescriptorAnnotationsTest, SealedGenericClassesTest all green
  in solos — core 138 of 138 pending the census).
  Census after round twenty-two: core 138 / 138 (the core suite is
  GREEN); json 554 -> 644 / 744 (100 remaining across 40 classes, the
  largest bucket 4: SerialNameCollisionTest, PropertyInitializerTest,
  JsonModesTest, JsonMapPolymorphismTest, JsonCoerceInputValuesTest,
  InlineClassesCompleteTest, then 3s: ValueClassesInSealedHierarchyTest,
  TrailingCommaTest, LocalClassesTest, JsonMapKeysTest,
  JsonListPolymorphismTest, JsonEnumsCaseInsensitiveTest,
  JsonDecodingErrorMessagesTest, GenericCustomSerializerTest,
  BasicTypesSerializationTest). Floor ratcheted to 640 in
  `src/itests/commontest_support.zig` (serialization_json baseline) and
  the json census joins the standing battery.
  Round twenty-three (suite-only failures, all roots shared with plain
  Kotlin programs): (1) a reified inline call in argument position of a
  bare call to an OWN member (`checkNotRegisteredMessage(a, b,
  assertFailsWith { … })`) had no expected type — plain member functions
  are not in the simple-name function index, so the sibling solver now
  resolves the enclosing chain's member through the registered member
  resolution (lambda bodies fall back to the thread's current owner
  class); (2) explicit type arguments on a call to a reified MEMBER
  EXTENSION inherited from a superclass (`json.decodeFromString<B>(text,
  mode)` against JsonTestBase's `Json.decodeFromString`) skipped every
  extension candidate and fell to the pack's one-parameter overload; the
  member-inline pick now admits enclosing-hierarchy extensions, with a
  receiver whose static head is unknown (a local bound from an
  expression-bodied helper) still eligible; (3) a lambda literal bound to
  a `(…) -> Unit` parameter returned its tail value, so JsonTestBase's
  per-mode result comparison saw the four assertFailsWith exceptions
  differ — lambdas now coerce to Unit through the same per-argument
  channel that carries instantiated parameter types (both arg-run loops);
  (4) the klio okio / kotlinx-io stream adapters decoded through the
  string lexer; the test run now composes upstream's json-okio and
  json-io modules unchanged over richer buffer stand-ins, so the stream
  modes exercise ReaderJsonLexer ("Unexpected EOF" messages); (5) a
  bare call `globalFun()` beside a primary-constructor property
  `globalFun: Int` invoked the parameter value — a local whose declared
  type is a plain value (primitive/String, or a class without `invoke`)
  never binds a call, and own-member arity masks now record such
  properties as taking no arity; (6) `Map<String, @Polymorphic InnerBase>`
  ignored the type argument's use-site annotations (the pass passed none),
  encoding `{}`; (7) a type-parameter element (`val boxed: T`) was
  asserted non-null in the generated deserialize, breaking `Box<Int?>`
  with a null payload — it is cast instead; (8) a generic-class parameter
  (`serializer: KSerializer<T>`) against a call argument whose explicit
  type arguments instantiate a dangling/star return
  (`CustomIntSerializer(true).cast<IntBox>()`) now unifies structurally
  (SerializersLookupTest contextual lookups); (9) a user class `E` lost
  to `kotlin.math.E` — an in-scope class outranks an unimported
  top-level property at lowering, and a class-bound `LoadGlobal` never
  falls back to a same-named global of another package at runtime.
  Round twenty-three continued: (10) inside an inner class, a member call
  on an OWN property named like a package segment (`json.decodeFromString(
  d, s, mode)` in JsonTestBase's SwitchableJson) lowered as a package-
  qualified call and bound `Json.Default` as the extension receiver — the
  every-mode coerce/lenient failures (JsonCoerceInputValuesTest,
  JsonModesTest NaN/Infinity/unknown-keys); own members now block the
  package-path route; (11) `@Transient` constructor defaults were absent
  from the generated deserialize, so a later default referencing one
  (`transientRefFromProp = constTransient + 4`) read a field off the
  serializer object — constructor parameters now walk in declaration
  order and transient ones bind their default as a local
  (PropertyInitializerTest 4/4); (12) `KClass.simpleName` of a nested
  class returned the lifted `Outer$Inner` spelling (SerialNameCollision
  messages); (13) a file-private `const val` renamed for a cross-file
  collision was not honored by `$name` string interpolation, and
  `@SerialName("$prefix.Derived")` (a template over a `const val`) was not
  folded to its compile-time string — the pass now collects top-level
  string constants across files first; (14) a resolved extension whose
  target is an image header stub of an inline function was CALLED (a
  bodiless stub) instead of spliced. (15) A receiver's own applicable
  MEMBER now outranks a same-named member extension declared elsewhere on
  both member-inline routes (`Json.decodeFromString(serial, source)` and
  `Json.encodeToString(serializer, value)` spliced JsonTestBase's
  `(source, mode)` / `(value, mode)` extensions with the arguments bound
  to the wrong parameters); the member-inline pick also checks arity, so a
  one-parameter member never preempts a two-parameter sibling. Solo
  verification after (1)-(15): PolymorphismWithAnyTest 7/7, JsonCustom
  SerializersTest 33/33, JsonCommentsTest 9/9, JsonDecodingErrorMessages
  Test 12/12, JsonMapPolymorphismTest 5/5, JsonListPolymorphismTest 3/3,
  InlineClassesCompleteTest 4/4, PropertyInitializerTest 4/4,
  SerialNameCollisionTest 6/6, JsonCoerceInputValuesTest 9/9,
  JsonModesTest 7/9, SerializersLookupTest 29/31.
  Remaining core 3 (after round eighteen):
  BasicTypesSerializationTest.testKvSerialization,
  SealedGenericClassesTest.testQuery,
  SerialDescriptorAnnotationsTest.testCustomAnnotationTransparentForContextual.
  Remaining core 4 (after round fifteen): BasicTypesSerializationTest.testKvSerialization,
  SealedGenericClassesTest.testQuery,
  SerialDescriptorAnnotationsTest.testCustomAnnotationTransparentForContextual,
  SealedInterfacesSerializationTest.testResolved (to re-verify).
  Remaining core 9 (before round nine): InterfaceContextualSerializerTest x2,
  ContextualGenericsTest x2, SerializersLookupNamedCompanionTest,
  SerialDescriptorAnnotationsTest.testCustomAnnotationTransparentForContextual,
  SealedGenericClassesTest.testQuery, SchemaTest.testEnumDescriptors,
  BasicTypesSerializationTest.testKvSerialization. Largest json buckets
  after round eight: JsonCustomSerializersTest (forClass companions +
  nested named-arg ctor as a reified argument), InlineClassesTest (the
  test base's TREE mode calls `encodeToString(tree)` on a local typed
  only by the callee's declared return type: unbound `T` reads a stale
  binding), SerializersLookupTest, JsonTreeTest.

## Task 3 — the coordinated ktor shim swap

- With Task 1's surface in place: replace BOTH serialization shims
  with the vendored upstream modules in one move (same FQN, real
  configs), add ClientSSESession + server Errors.kt to the include
  lists, settle ExperimentalJsonConverter.kt (exclude-with-record or
  pull json-io), delete the shims, and drive the ktor e2e gates +
  ktor census back to green. `Json.decodeToClass` retires with the
  shims unless something else consumes it (then record what).

## Standing policy

- Root-cause only; census floors/ceilings, corpus parity, compose
  gate, litmus never weaken; scripts/stack.sh is the full battery and
  the new json census joins it (or gate.sh) once ratcheted.
- Traps in force: installed packs shadow sources (rebuild first),
  clear the bake cache before pack builds when chasing staleness,
  census = per-file/per-class children, never `zig build` during a
  battery.

Exit: the pack carries the real surface with the upstream converter
modules compiling against it; the json census stands ratcheted in the
verification path with its count trajectory recorded; both shims are
deleted with ktor e2e + census green; full battery green throughout.
