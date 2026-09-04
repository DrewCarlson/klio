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
  JsonModesTest 7/9, SerializersLookupTest 29/31. Then (16) a local
  initialized from another file's nested constructor typed as nothing
  because the class row was still a header when the caller lowered, and
  a bare reference to a nested `object` had no static type — both feed
  the sibling solver (JsonModesTest 9/9, SerializersLookupTest 31/31).
  Census after round twenty-three: core 138 / 138; json 644 -> 688 / 744
  (54 failed, 2 did not complete). Floor ratcheted 640 -> 680. Remaining
  54 across 30 classes, largest 3: ValueClassesInSealedHierarchyTest,
  TrailingCommaTest, LocalClassesTest, JsonMapKeysTest,
  GenericCustomSerializerTest.

  Real json-io streaming surface: the 688 count was measured with the
  KXIO_STREAMS branch of upstream's JsonTestBase.parametrizedTest a
  no-op (json-io was never packaged). Wiring the real surface exposed
  two roots. (1) A pack `[features].sources` prefix only GATES already
  collected files; it never adds a source root. json-io therefore
  compiled into nothing (0 symbols in the pack) and every parametrized
  test's KXIO branch hit `unresolved encodeToSink / decodeFromSource`,
  cascading ~330 failures. Fixed with a real `[[source]]` root for
  `upstream/formats/json-io/commonMain/src`, gated to the json feature.
  With json-io packaged, `Json.encodeToSink(serializer, value, sink)`,
  the reified `encodeToSink<T>` / `decodeFromSource<T>`, and the
  explicit-serializer `decodeFromSource` all round-trip through the
  real kotlinx.io Buffer. Census core 138 / 138; json 358 -> 520 / 744.
  (2) The remaining ~200 KXIO failures were ONE root, not shape gaps:
  the json-io writer / reader dispatch a cross-pack kotlinx.io extension
  (`sink.writeCodePointValue`, `Sink.writeString`) on a receiver typed
  `Sink` holding a `kotlinx.io.Buffer`. Baked into the pack image the
  call dispatches dynamically through extensionFnFallback, whose
  argDefinitelyNotParamType decided Buffer-IS-A-Sink by reading
  class_super_names.get("Buffer") -- a SIMPLE-name key colliding with the
  okio stand-in Buffer (StreamSupport), whose chain lacks Sink, so every
  quoted / string / codepoint write totally missed. Fixed by proving
  IS-A from the instance's OWN runtime ClassDef (classDefIsA: real
  supertype names + resolved interface handles), immune to the collision.
  InlineClassesTest 1 -> 13, JsonCustomSerializersTest 17 -> 33,
  JsonModesTest 6 -> 9. Census json 520 -> 688 / 744 -- the pre-KXIO
  floor+8 WITH the real streaming surface running. Remaining 54 are the
  same pre-KXIO buckets (ValueClassesInSealedHierarchyTest,
  TrailingCommaTest, LocalClassesTest, JsonMapKeysTest,
  GenericCustomSerializerTest): reified-T binding + generator fidelity,
  the pre-existing 744 tail. Ratchet the floor to 688.

  Diagnosed json-tail roots (2026-09-03, each reproduces standalone):
  (a) LocalClassesTest — reified `Json.encodeToString(localValue)` /
  `serializer<Local>()` for a LOCAL `@Serializable` class fails
  ("unresolved global `Local$lcmain`" / "Serializer for class 'Local'
  not found"). `Local.serializer()` and `Local::class` both work
  directly, but `__klsx_companionSerializer` resolves through the class's
  `$companion` PROPERTY, which a local class's synthesized companion is
  not reachable by; and the reified splice emits a bare `LoadGlobal
  Local$lcmain` for the mangled local-class name. Fix: make the local
  class's synthesized serializer companion reachable via `$companion`
  (and/or map the `$lc<fn>`-mangled reified name to `<Name>$serializer`). A naive
  fallback (invoke `serializer` straight on the class value when the
  `$companion` lookup is null) makes `serializer<Local>()` resolve but
  REGRESSES json 688->682 and core 138->132 — it fires for classes whose
  null was correct. The fix must target local classes specifically. Precise encodeToString
  root: the reified splice emits `Local$lcmain.serializer()` at the call
  site; the local class registers at runtime under `Local` (simple name,
  host_classes registerClass uses class.name.name) but is referenced by
  the `$lc<fn>`-mangled name, so the member-call receiver classifier does
  not find a class for `Local$lcmain` and lowers a bare `LoadGlobal`
  (fails). `Local.serializer()` works because the source name resolves.
  Fix candidates: register the local class under its mangled name too, or
  have the member-receiver class classification strip / resolve the
  `$lc<fn>` mangle to the class-table entry. PARTIAL fix landed: the
  LoadGlobal miss path strips `$lc` and retries (so the mangled name
  resolves the local class). Remaining: the reified KType classifier keeps
  the mangled string (`makeKTypeValue("Local$lcmain")`), so
  serializerOrNull gets a synthetic KClass with the mangled name and its
  `$companion` lookup misses. The KType classifier must resolve the local
  class (strip `$lc` when building the KType's KClass). THREE-part fix landed
  (LoadGlobal `$lc` strip + `$companion` published-global fallback + KType
  `$lc` strip): a SINGLE local `@Serializable` class now serializes reified
  end to end (`serializer<Local>()` and `Json.encodeToString(localValue)`
  round-trip; verified), core 138 / json 688 unchanged. LocalClassesTest
  still fails on a SUITE-only `unresolved global Local$serializerImpl` — it
  does NOT reproduce with same-named locals across functions or class
  methods (those pass); it needs the full JsonTestBase + the file's
  object/custom-serializer locals. Remaining root: the `$serializerImpl`
  factory reference in the multi-local-class suite context.
  (b) GenericCustomSerializerTest — IndexOutOfBounds (Index 0, length 0)
  in a generated serializer. Both are distinct from the suite-only enum /
  streaming failures.

  Task 3 (ktor swap) status: the content-negotiation + serialization
  sources are vendored and the shims deleted (committed). The ktor
  commontest census regressed to 0/450 on the swap: `klio test` with no
  --feature implicitly activates ALL of a pack's features, and the new
  client-serialization / server-serialization features require the
  kotlinx.serialization pack the ktor census home does not carry, so the
  load failed pack-wide. The commonTest surface is ktor-io / ktor-utils /
  ktor-http (+ the io.ktor.test dispatcher), so the census now pins
  `--feature io.ktor/http --feature io.ktor/test-base`; the typed
  serialization surface is covered by the ktor_client_get / ktor_server
  e2e gates. With the pin and the ClassDef IS-A fix the ktor census is
  438 -> (see census); the residue is the unit-mask bleed below.

  OPEN root (pre-existing, round twenty-three): a chained flow terminal
  `X.map { }.firstOrNull { }` mis-coerces the outer predicate to Unit
  (`non-bool in branch: kotlin.Unit`). map inline-splices to
  `unsafeTransform`, whose `-> Unit` transform legitimately sets the Unit
  mask; the outer firstOrNull predicate, lowered in the same spliced arg
  context, captures that mask. Standalone (`fm7`) it is correct; only the
  two-statement / chained shape triggers it. Breaks CookieDateParserTest
  (3), the ktor typed-body converter (asFlow().map{}.firstOrNull{}), and
  a few json cases. The staged-mask experiment did not fix it (the leak
  is through the splice arg context, not the speculative-resolve path).
  Fix is in the map->unsafeTransform splice arg hygiene.

  Update: the receiver-side bleed (`X.map { }.firstOrNull { }`, fm6) is
  fixed — `lowerReceiver` shields pending_arg_broad_masks /
  fn_generic / lambda_param_types but the round-23 unit mask
  (pending_arg_lambda_unit) was never added to that shield; adding it
  stops a receiver splice's `-> Unit` operator from tagging the outer
  call's lambda. A SECOND path remains in CookieDateParser
  (`lexer.capture { accept { it.isDigit() }.otherwise { } }`): the
  trace shows `accept`'s OWN `(Char) -> Boolean` predicate flagged Unit
  (`fnTypeReturnsUnit(func.params[pi].ty)` true for a Function1 whose
  declared return is Boolean). Suspected `func` pointer read after the
  module function table moved during a nested lambda-body lowering (the
  same hazard the ext-call path warns about for `target`); confirm and
  snapshot the param type before the receiver / block lowers.

  ktor typed-body e2e (client-serialization) remaining root: the
  converter list `deserialize` (ContentConverter.kt:111) is
  `asFlow().map { converter -> converter.deserialize(...) }
  .firstOrNull { ... }` inside the extension `List<ContentConverter>
  .deserialize`. The unit-mask shield unblocked the predicate coercion,
  but `this.asFlow().map { }` on an EXTENSION receiver breaks the flow
  collector: `Vm::call_member emit on $anon$1`. Plain
  `list.asFlow().map { }.toList()` works; only the extension-receiver
  `this.asFlow()` form fails (map's spliced `unsafeTransform` emits on
  the wrong collector). NOTE (current): the inline-splice receiver shield now also covers the
  unit mask (committed), fixing the simple accept.otherwise / flow-map
  bleeds; ktor 447/3, json 688, core 138, compose 446/6 all hold. The
  deeper CookieDateParser nesting (capture inside an inline `-> Unit`
  param) needs a PER-ARGUMENT splice mask thread; a first attempt
  over-reset pending_ref_lambda_unit for every splice param and regressed
  ktor to 373 with DNCs, so it was reverted. The surgical version must
  set the mask ONLY for the matched argument slot and leave every other
  splice param's flag as the round-23 feature computed it.

  This is the last blocker for the typed
  client/server serialization gates; the plain GET path is green.

  Narrowed 2026-09-03: the failure is the ENCLOSING EXTENSION-FUNCTION
  CONTEXT, not the chaining. `items.asFlow().map { e -> ... }.toList()`
  works verbatim inside a plain function OR a member method; the SAME
  code inside a top-level extension (`List<T>.f() = asFlow().map{}...`)
  binds the map lambda's parameter to a closure (`e = {ir-closure#N}`,
  the flow only emits once with that closure). Assigning asFlow() to a
  local first does NOT help, so it is the extension receiver in scope,
  not `this.asFlow()`. The map inline expands to unsafeTransform (a
  multi-level flow splice: map -> unsafeTransform -> flow/collect); one
  of those spliced lambdas mis-binds its value parameter when an
  extension receiver is present. The `resolve("this")` receiver fallback
  in spliceInlineLambda was ruled out (the transform lambda traces
  rlp=false, recv=null). Two prior speculative splice changes both
  regressed (ktor 447 -> 373 with DNCs), so this needs the exact
  register mis-bind identified before any change.

  RESOLVED 2026-09-03 (both bleeds). Two root fixes landed:
  (1) inline-splice Unit-mask clear. The deeper CookieDateParser nesting
  (`capture { repeat(2) { accept { }.otherwise { } } }`) was NOT a
  register mis-bind: an inline call binds its lambda arguments by
  body-expansion, never through lowerArgRun, so the `-> Unit` mask that
  argument typing writes to pending_arg_lambda_unit had no consumer on
  the splice path and dangled. An enclosing `also { }` (in accept's body)
  set the mask; the splice's own receiver shield then faithfully
  save/restored that stale mask across the nested `accept { }` predicate,
  coercing it to Unit. Fix = clear pending_arg_lambda_unit once typing is
  done on the inlineSplice path (expr.zig, after argLambdaParamTypesRecv).
  CookieDateParser 4/4; ktor commontest 447 -> 450 (GREEN).
  (2) splice-receiver priority. The extension-function flow-map failure
  was resolveCtxFor setting a bare call's receiver head from the frame's
  own recv_ty AHEAD of the splice channel. Inside an active splice the
  frame recv_ty is the CALLER's; when the caller is an extension function
  its receiver shadowed the spliced map body's own Flow receiver, so the
  bare `transform { }` (aliased Flow.unsafeTransform) resolved against
  String/List, fell through to the bound `transform` param, and the map
  lambda got a closure. Fix = during an active splice with a set frame
  recv_ty, use spliceRecvTy() instead (mirrors bareStaticRecvHead);
  spliceRecvForName's local gate cannot serve the collided `transform`.
  `flowOf().map{}` / `asFlow().map{}` now work in extension functions.
  Censuses after both: json 688, core 138, ktor 450/0, compose_ui 448/4 —
  no regressions.
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

STATUS 2026-09-02 (late): the swap is IN. Both shims
(`shim/client-serialization`, `shim/server-serialization`) are deleted
and `Json.decodeToClass` (JsonBridge.kt) retired with them. The ktor
pack now vendors, unchanged: ktor-client-content-negotiation and
ktor-server-content-negotiation (common + posix `DefaultIgnoredTypesNix`),
ktor-serialization's ContentConverter contract (`ContentConverter.kt`,
`ContentConvertException.kt` — the WebSocket converter pair
`WebsocketContentConverter.kt` / `KotlinxWebsocketSerializationConverter.kt`
is excluded WITH RECORD: it needs the websocket session surface the pack
does not carry; the frame model `Frame`/`FrameType`/`CloseReason` rides
along because `WebsocketDeserializeException` names it), the kotlinx
converter (`KotlinxSerializationConverter`, `Extensions` +
`ExtensionsNative`, `SerializerLookup`) and kotlinx-json
(`JsonSupport`, `KotlinxSerializationJsonExtensions` +
`JsonExtensionsNative`, and `ExperimentalJsonConverter` — settled by
PULLING json-io: the serialization pack's `json` feature now includes
upstream `formats/json-io` and depends on the real `kotlinx.io` pack, so
the json census's KXIO mode runs the pack's own module and the klioTest
kotlinx-io stand-in is gone). `ClientSSESession.kt` joined the client-core
include list and ktor-sse's `ServerSentEvent.kt` a new source block.
Verified in run mode: `KotlinxSerializationConverter(DefaultJson)`
serializes/deserializes a @Serializable class through `typeInfo<T>()` and
`HttpClient { install(ContentNegotiation) { json() } }` constructs; the
ktor e2e gates and the ktor census run next.

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

Round (2026-09-03, reified nested-class): SealedPolymorphismTest 2/2 GREEN,
json census 690 -> 692 / 744. Root: an INFERRED reified type argument for a
sealed subclass nested in the test class (`T` = `Foo.Bar` from a `Foo.Bar(1)`
value arg to `inline fun <reified T>`, exercised by
`assertStringFormAndRestored(..., PolymorphicSerializer(Foo::class))`) arrived
with its dotted spelling in the TypeRef `name`, not `qualified_path`, so
`reifiedQualifiedName` missed it and the reified bind loaded a bare `Foo.Bar`
global -> "unresolved global Foo.Bar". Fix = resolve a dotted `name` as a
`.`-aligned suffix of the nested class's lifted fqn (inline_call.zig). Minimal
repro: reified inline + PolymorphicSerializer + sealed class NESTED in the
test class (top-level sealed Foo, concrete serializer, or a Foo-typed var all
PASS). REMAINING json 50, largely SUITE/STATE-only (pass when filtered to one
test, fail in the per-class census run): TrailingCommaTest testWithMap/
testMultipleFields fail only in STREAMING mode within the class run (a
generated `<Class>$serializer` object read as a getfield on a DOUBLE companion
`X$Optional$Companion$Companion`, recovered for the first test but fatal under
inter-test state); a lookupGlobal getfield-miss fallback is neutral there.

Round (2026-09-03, sibling-property reified inference + census-err tooling):
json census **685 -> 695 / 744** (floor ratcheted 685 -> 693). All other
suites unchanged (core 138/0, ktor 450/0, compose_ui 451/1); corpus parity
unaffected (the 16 corpus "fails" in an ad-hoc run are compose-plugin-pack
gating — identical embedded vs .klio-local, need `KLIO_COMPOSE_PLUGIN=1`
installed packs; NOT a regression).

Root fixed (TrailingCommaTest testMultipleFields/testWithMap/testWithList/
testMixed + SealedPolymorphismTest, canonical census): a reified `serializer<T>()`
whose `T` is inferred from a SIBLING argument that is a class-level `val`
(`assertEquals(expected, decode(...))`, `expected` a member property of a
nested type) typed as nothing, because the lazy argument typer
(`argDeclTypeRefLazyUncached`) knew only locals + splice params, not a bare
implicit-`this` property read. Fix (three layers, all landed):
1. type a bare one-segment name against the enclosing receiver's
   `class_prop_type_heads` and qualify a nested head through `scopeTypeRenameFrom`
   (expr.zig) — the guard must rely on `isTypeParam`, NOT a length<=2+uppercase
   heuristic, or a real 2-letter class head (`MF`) is dropped as type-param-like;
2. record INFERRED property heads for a `val x = MF(...)` initializer whose
   ctor names a class NESTED in the property's own class — `propCtorHeadEvidence`
   now takes the enclosing class and checks its nested members (build.zig);
3. qualification via `scopeTypeRenameFrom` (layer 1).

Tooling: `KLIO_CENSUS_ERRS=1` (with `KLIO_CENSUS_NAMES=1`) makes klio-census
print each failing case's error line (`[census-err]`), so the census is
diagnosable without by-hand re-runs.

TRAP (measurement): an ad-hoc "compile every json-tests file + `--feature`"
runner is UNRELIABLE — it batches all files so multiple same-named types
(`Bar`, `SealedMid`) collide and produce PHANTOM failures (`get_field Bar on
Foo$serializer`) the canonical census never sees. serialization_json is
`whole_source_set=false`: the census compiles each target with only its
providerClosure. ONLY `klio-census serialization_json` (with installed packs)
counts. A default-value-qualification fix in serialization_pass.zig chased one
such phantom and was correctly REVERTED as neutral on the canonical census.

Remaining canonical census failures (47), by root family (from
KLIO_CENSUS_ERRS):
- Reified `serializer()` inference returns an empty/`{}` serializer (T inferred
  transitively through a generic helper's type param): KeyValueSerializersTest
  testPair/testTriple (`"second":{}`), SealedInterfacesJsonSerializationTest,
  SealedInterfacesInlineSerialNameTest, JsonNullablePolymorphicTest,
  JsonNumericKeysTest (`{}`). ~6 tests, likely one root.
- File-level / typealias custom serializer not applied -> default encoding
  off by the serializer's delta: SerializationForNullableTypeOnFileTest
  (52 vs 50), NotNullSerializersCompatibilityOnFileTest (52 vs 50),
  SerializableOnPropertyTypeAndTypealiasTest (`c#/d#` vs `c/d`),
  UseSerializersTest (84 vs 21). ~4-5 tests.
- Callable reference `::JsonPrimitive` to an OVERLOADED factory beside the
  sealed class: the reference binds the (uninvocable) abstract-class ctor, so
  `.map(::JsonPrimitive)` over `Collection<Number?>` crashes
  `JsonPrimitive() expects 0 args, got 1` (JsonBuildersTest.testBuildJsonArrayAddAll,
  JsonArraySerializerTest.testWhitespaces). REPRODUCED (scratch cref2.kt:
  sealed class + same-named factory overloads + `::Name` in `.map`). Two-site
  fix needed: (a) lowering — an abstract/sealed/interface class must not shadow
  a same-named function in a `::` PropertyRef pick (expr.zig class_pick), AND
  (b) runtime — the bare-name reference invocation must rank the function
  overloads (with `Int <: Number?` subtyping) above the abstract class ctor.
  Layer (a) alone is neutral; deferred as a coordinated fix.
- Value-class map key equality: JsonMapKeysTest (3) decode == expect as
  STRINGS yet assertEquals fails (value-class `equals`).
- `Vm::call_member serialize on kotlin.reflect.KClass`:
  ValueClassesInSealedHierarchyTest (3).
- `Vm::get_field descriptor on kotlin.Nothing`: GenericCustomSerializerTest (3).
- Local class serialization (`get_field base on Local`,
  `unresolved global Local$serializerImpl`): LocalClassesTest (3).
- `Vm::get_field SealedMid on Holder$serializer` (nested type in a generated
  childSerializer): JsonNamingStrategyTest (2).
- Special float parsing: SpecialFloatingPointValuesTest testNans/testInfinities
  (decoder can't parse `NaN`/`-Infinity` tokens under
  `allowSpecialFloatingPointValues=true`), JsonExponentTest (NumberFormatException
  for `1e-1e-1` must be SerializationException).
- Misc singletons: SealedDiamondTest (descriptor missing `E`),
  PolymorphismForCustomTest (`unresolved global V`), JsonEncoderDecoderRecursiveTest
  (`cast to Map failed`), PolymorphicOnClassesTest / PolymorphicSealedChildTest /
  ObjectSerializationTest / JsonProhibitedPolymorphicKindsTest (`exception`) /
  JsonNamesTest / JsonEnumsCaseInsensitiveTest testTopLevelList,testDocSample.

Round (2026-09-03 cont., file-level UseSerializers): json **695 -> 697 / 744**
(floor 695). Two landed roots, both in serialization_pass.zig:
- `@file:UseSerializers` serializer for a PRIMITIVE-typed element was recorded
  in childSerializers but the generated serialize/deserialize took the
  primitive element codec (`encodeIntElement`) and ignored it. `elemPrim` now
  yields when the file-level policy names a serializer for the head, so the
  element routes through `encodeSerializableElement`
  (NotNullSerializersCompatibilityOnFileTest.testFileLevel).
- Nullable-target distinction: `KSerializer<Int?>` vs `KSerializer<Int>` both
  keyed a bare `Int`, so a nullable property picked whichever registered last.
  `serializerTargetHead` now reports the target's nullability;
  `use_serializers_nullable` holds `KSerializer<T?>` serializers; a nullable
  property whose type matches binds it DIRECTLY (serializer handles null), not
  a `.nullable` wrap (SerializationForNullableTypeOnFileTest.testFileLevel).

Deferred roots now precisely diagnosed:
- `@Serializer(forClass = X::class)` serializer objects have NO `KSerializer<X>`
  supertype, so `serializerTargetHead` cannot find their target head; a
  `@file:UseSerializers` listing such an object is not applied
  (UseSerializersTest.testOnFile: `a:IntHolder` gets IntHolder's default
  serializer -> 21, not the file's MultiplyingIntHolderSerializer -> 84). Fix =
  read the `@Serializer(forClass=)` annotation for the target when no
  KSerializer supertype is present.
- JsonMapKeysTest (3) is NOT a serialization bug: `mapOf(k to 1)` flowing into
  a `Map<_, Long>` parameter keeps the literal `1` as Int (decoded side is
  correctly Long), so the boxed `Int(1) != Long(1)` and the map compares
  unequal. Root = expected-type propagation of an integer literal to Long
  through `to`/`mapOf`/the constructor (a general numeric-literal-typing gap).
- The `{}`-empty family is reified `serializer()` whose T is inferred
  TRANSITIVELY through a generic helper's type parameter
  (`testPair(pairInstance, kSer, serializer(), ...)` with V bound by
  `pairInstance`'s type) — deeper than the direct-sibling case already fixed.

Round (2026-09-03 cont., inline catch-only-try fix): json **698 -> 700 / 744**
(floor 698); coroutines **1295 -> 1299** (floor 1297); all other suites held
(core 138/0, ktor 450/0, compose_ui 451/1, io 1191/0, datetime 519/0,
atomicfu 67/0); fast unit tests green.

Root (SpecialFloatingPointValuesTest testNans/testInfinities, and a GENERAL
inline+try bug): an inline fn `try { return block() } catch (e) { … }`
(kotlinx's `parseString`) left its runtime `TryFrame` armed after the inlined
`return`. The inline return jumps straight to the call's join, bypassing the
try's `catch_done` exit that normally pops the frame, so the catch stayed live
over the code AFTER the inlined call — the decoder's
`throwInvalidFloatingPointDecoded` (thrown after `parseString("double"){toDouble()}`
returned NaN) was wrongly caught by parseString's `catch (IllegalArgumentException)`
and re-reported as "Failed to parse type 'double'". Fix: track catch-only try
bodies parallel to `finally_body_stack` (`catch_body_stack` in FuncBuilder),
and on an inline return add them to the jumping block's `pop_on_exit` (order-free:
the eval removes each `TryFrame` by body id). Repro: scratch inlcatch.kt
(inline `try{return block()}catch`, then a throw after — was CAUGHT-WRONGLY).
NOTE (open, same class): break/continue out of a catch-only try inside an
inline lambda still leaks (they use replayFinallysForJump without the catch pop);
not yet exercised by a census failure.

Ktor shim swap VERIFIED complete (prior session): the real upstream
`KotlinxSerializationConverter` + json `JsonSupport`/`ExperimentalJsonConverter`
are vendored and included for client AND server content-negotiation; no
serialization-converter shim (`decodeToClass` etc.) remains; ktor census 450/0
and both e2e gates green. The residual `kotlin-klio/klio-ktor/shim/` is klio
platform actuals (crypto, transport, dispatchers), not serialization shims.

json 42 remain: reified serializer() transitive `{}` (~6), value-class mapkey
Int-vs-Long literal typing (3), serialize-on-KClass (3), descriptor-on-Nothing
(3), local-class (3), callable-ref `::JsonPrimitive` (2), JsonNamingStrategy
nested-childSerializer `get_field SealedMid` (2), plus singletons.

Rounds (2026-09-03, sibling/receiver/collision series): json **700 -> 714 / 744**
(canonical klio-census), then **714 -> 716** (jc17), then **716 -> 723** (jc18,
floor still 693 in `commontest_support.zig` — ratchet pending the next clean
run); coroutines 1299 (floor 1297); every other suite held (core 138/0,
ktor 450/0, compose_ui 451/1 ShadowTest.testLerp, io 1191/0, datetime 519/0,
atomicfu 67/0); unit tests green after every build.

Roots landed (each with an example + baked output):
- `Gen.qualifyTy` / generic custom serializer (`@Serializable(with =
  Generic::class)` on a generic class passes the type-argument serializers);
  `customSerializerRef(t, w)` takes the type.
- Sibling reified inference: instantiated-solver yields on own-type-param or
  star (`irTypeMentionsAny`); zero-arg branch solves from ctor/static siblings,
  own-member outers through `enclosingChainMethodsNamed`
  (reified_serializer_from_sibling).
- Receiver-lambda labels: `spliceInlineLambdaOn` binds `this@<inlineFn>` to the
  subject (receiver_lambda_label_shadow).
- `NumberFormatException` is-a `IllegalArgumentException` in the builtin
  throwable lattice (catch_number_format_as_iae).
- `classReceiverField` probes `{cls}.Companion.{name}` for a bare companion
  member read (companion_nested_object_vs_import).
- Pass batch: `@Polymorphic` on a type parameter -> `PolymorphicSerializer(Any)`;
  local `with=` classes get a spliced companion `serializer()`; sealed enum
  leaves via `createSimpleEnumSerializer`; out-of-index `with=` stays a bare
  reference; InstantComponentSerializer included
  (serializable_local_with_and_polymorphic_param, sealed_enum_leaf_descriptor,
  serializable_local_class_scope, instant_component_serializer).
- `Error`-named polymorphic subclass: `reifiedQualifiedName` keeps the written
  receiver path; the `KSerializer<T>` factory-receiver arm overrides a bare
  prior binding of the same simple name, and MERGES the qualified path into a
  prior binding that carries type arguments (`ParametrizedData<Data>` from
  `value: T` stays intact) (polymorphic_subclass_named_error,
  reified_serializer_generic_prior_binding).
- Private member with a receiver-lambda parameter called bare: the direct
  private-dispatch path records the lambda's declared receiver
  (`recordLambdaArgReceivers`), so `subclass(Int::class)` inside splices with
  `T` bound (private_member_receiver_lambda).
- `@Serializer(forClass = X::class)` bodiless object gets the `KSerializer<X>`
  supertype in the splice; declaration supertype matching compares the simple
  head (serializer_for_class_object_subclass).
- `@Contextual` on a generic type passes `arrayOf(typeArgSerializers)` and a
  generic serializable fallback `X.serializer(args)` (contextual_generic_type_args).
- `@Polymorphic` on a class declaration is indexed (`polymorphic_classes`) and
  properties of that type serialize polymorphically (polymorphic_class_annotation).
- Own-member scope order: an APPLICABLE own FUNCTION shadows a same-named
  top-level function or class (`private fun Json(arrays, build:
  PolymorphicModuleBuilder<Any>.() -> Unit)` beside the library `Json`): the
  lowerCall pre-record, `emitMemberOrGlobal`, and the ctor/factory path route
  through the implicit-this path first; the gate is `ownFunctionApplicable`
  (functions only — nested-class ctor calls keep the ctor path; the permissive
  `ownMemberApplicable` regressed `DiscriminatorHolder(...)`/`GenericClass(...)`
  on the first jc18 launch) (own_member_over_library_function).
- `is S.A` through a PRIVATE nested owner: `loweredCheckTypeName` renames the
  path's first segment through the owner's scope alias before the two-segment
  `mangled_nested` key (nested_private_sealed_is_check).
- Callable reference to a sealed class + factory functions (`::JsonPrimitive`):
  the boxed numerics list `Number`/`Comparable` as builtin supertypes
  (`applicability.builtinSupersOf`, nullable param compare trims `?`), so
  `pickFactory` accepts an `Int` for `Number?`; under a typed expected function
  type the overload is picked statically (class_pick cleared for an abstract
  class) (callable_ref_factory_over_sealed_class).
- Zero-arg reified `serializer()` beside a generic sibling call instantiates the
  sibling's return type (`instantiatedCallIrType`: `solveCallBindings` over
  static arg shapes, infix/member callees, recursion two levels, constructor
  instantiation by positional bind, vararg least-upper-bound head)
  (reified_serializer_from_infix_sibling).

Census mechanics learned: `klio-census` takes ONE comma-separated suite arg
(`serialization_json,serialization,ktor,...`); a space-separated list silently
runs only the first suite (jc17 ran json alone). `KLIO_CENSUS_ARGV=1` (added)
echoes each job's argv so a closure-dependent failure can be replayed exactly.
`corpus_check.py` needs `KLIO_HOME=$PWD/.klio-local` for `--feature` examples.

In flight (edited, not yet censused): typealias + type-use `@Serializable(S::class)`
in the pass (`type_aliases` index; `serializerExprNonNull` checks `t.annotations`
then recurses on a non-generic alias target); abstract/open `@Serializable`
children are sealed LEAVES with their polymorphic serializer (so
`subclassesOfSealed<FooOpen>()` rejects the incomplete hierarchy as kotlinx
does); `argDeclSupertypeMatching` consults the scope alias first (a nested
object named `ContextualSerializer` no longer answers the library class's
`KSerializer<T>`).

Remaining json families (closure-dependent unless noted): LocalClassesTest (2)
and EncodingExtensionsTest (1) and JsonEnumsCaseInsensitive (2) and JsonNames
(2) pass in isolation — same-name collisions inside the census provider closure
(replay via KLIO_CENSUS_ARGV); JsonMapKeys (3) = Int-vs-Long literal typing
through `to`/`mapOf`/ctor expected type (interpreter, not serialization);
KeyValue (2) transitive Pair (ctor instantiation now landed, verify);
SealedInterfaces (2) LUB `List<I>` (vararg LUB landed, verify);
SerializableOnPropertyTypeAndTypealias (2) (typealias landed, verify);
PolymorphicSealedChild (1) (leaf change landed, verify); NotNull contextual (1)
(scope-alias supertype landed, verify).

Round (2026-09-03, jc21): json **728 -> 738 / 744** (floor 725); the ten flips
were closure-scoped: local-class identities (`$lc` aliases for explicit type
arguments, lifted names for constructor-call bindings, scope-first class
resolution ahead of the package index), lambda-local classes reached by the
pass (recursive walk + source-text file gate), `subclassesOfSealed` past the
inline expansion cap (reified callees get a 3x cap), a plain enum's annotated
entries (`createAnnotatedEnumSerializer` in place), the sibling solver's
generic-slot projection (`pair: Pair<K, V>` -> `V`), qualified LUB heads with
value-class constructors, and the explicit-type-arg local typing through a
member reified helper (`explicitBareReturn`).

REGRESSIONS in the same run (coroutines 1299 -> 1296, ktor 450 -> 449), both
from the "splice a reified inline callee first" rule and the `$lc` aliases
reaching runtime-facing names:
- `flow.catch { }` spliced `LaunchFlowBuilder.catch`'s body (a same-named
  reified inline MEMBER found by simple name) onto a Flow receiver
  (`get_field onEach on SubscribedStateFlow`); the splice-first rule now
  requires the registered target's receiver head to match the declaration's.
- `filterIsInstance<Super>()` and `catch (e: MyException)` over function-local
  classes bound `Super$lc<fn>` / `MyException$lc<fn>`, which the runtime
  (classes register under their bare name) never matched; `instanceOf` strips
  the `$lc` alias before resolving.

Parked residue (json 4): JsonMapKeys x3 (Int-vs-Long literal typing through
`to`/`mapOf`/constructor expected types — interpreter-level expected-type
propagation, not serialization) and JsonNamesTest.testThrowsAnErrorOnDuplicateNames
(a NAMED argument inside a lambda handed to a reified inline wrapper
(`assertFailsWithMessage<…> { json.decodeFromString(serializer, s,
jsonTestingMode = streaming) }`) invokes the captured `serializer` object with
one argument before any `decodeFromString` runs; positional form passes; the
plain non-serialization shape passes — still open).

Round (2026-09-04, jc22 -> jc23): jc22 confirmed the regression fixes
(coroutines 1299/0, ktor 450/0, json 738/4). Landed after it:
- Expected-type integer literals (`applyExpectedLiteralKinds`): a declared
  local type, a callee parameter type (`argLambdaParamTypes`/`emitCall`), or a
  constructor primary parameter binds the factory's type parameters
  (`positionalBind` of the return type against the expectation) and rewrites
  the literal kinds inside, infix `to` and generic constructors included.
  JsonMapKeys x3 pass in the closure replay.
- Function-local class `: Exception("msg")` keeps its message: the local
  parent chain binds throwable args for a builtin parent by name, whether or
  not the stdlib `Exception` class def is the parent.
- `hostHasMember` resolves a CLASS receiver through its companion/object
  singleton (so `X.serializer()` beside a same-named local is a member call).
Remaining json residue (1): JsonNamesTest.testThrowsAnErrorOnDuplicateNames —
a reified inline splice (`assertFailsWithMessage<T> { }` or any user-defined
reified inline wrapper) around `json.decodeFromString(serializer, s,
jsonTestingMode = streaming)` (a member-extension of the test base with a
NAMED argument) ends in `invoke` on the serializer object; positional form,
non-inline wrappers, and non-reified inline wrappers all pass; the spliced IR
is a plain `CallMember json.'decodeFromString'(serializer, s, streaming)` with
consistent captures, so the fault is in the runtime named dispatch of the
member-extension under the splice's global `T`. Open.

### Round jc23 → jc24: the last json residue, plus the compose ShadowTest root

`JsonNamesTest.testThrowsAnErrorOnDuplicateNames` (json 741 → 742/744 expected).
The runtime-lowered lambda spliced JsonTestBase's TWO-parameter reified
`Json.decodeFromString(source, jsonTestingMode)` for the THREE-argument call
`json.decodeFromString(serializer, "...", jsonTestingMode = streaming)`: the
splice placed arguments in written order, so the string literal took slot 1
and the later named argument silently overwrote it (no overflow, no
collision). The helper body then bound `source` to the serializer object and
its `serializersModule.serializer<T>()` resolved the bare `serializer(typeOf<T>())`
to the call-site local `serializer` — the `invoke` on the serializer object.
Root fix (`inline_call.zig`): a named argument that names a slot a positional
argument already filled is Kotlin's "argument passed twice" and marks the
candidate as the wrong overload (`named-collision` bail, both the vararg and
plain branches). The call then binds the three-parameter member extension.
Example: `examples/named_arg_collision_reified_overload.kt`.

Compose `ShadowTest.testLerp` (compose_ui 451/1 → 452/0 expected). Not a
runtime re-rank: the PACK body of `graphics.lerp(Shadow, Shadow, Float)`
(Shadow.kt:71, lowered lazily at first call) statically bound
`lerp(start.offset, stop.offset, fraction)` to `unit.lerp(DpOffset, DpOffset, Float)`
(tier 5, never imported) because the argument SHAPE of `start.offset` was
`DpOffset`: `class_prop_type_heads` is keyed by SIMPLE class name, and
`androidx.compose.ui.graphics.shadow.Shadow.offset: DpOffset` (indexed
later) clobbered `androidx.compose.ui.graphics.Shadow.offset: Offset`.
Root fix: the index records every class/object property head under the
declaration's QUALIFIED name too (`declFqnAt`: override by decl span, else
the decl file's package — the primary file's prefix is empty in a merged
build), and the member-read typing route (`argDeclTypeRefLazyUncached`'s
`.Member` block, `propTypeHeadOn`, the qualified-receiver arm) consults the
site's own view of the owner first — the written `#qual:` marker when the
declaration spelled a qualified type, else `classIdIndexed` through the
site file. Single-file regression: `examples/namesake_class_property_types.kt`
(user `demo.Regex.pattern: Int` vs `kotlin.text.Regex.pattern: String`; a
read through the qualified type bound the user's `Int` overload before).
Tooling: `KLIO_BARE_TRACE` now prints each candidate's parameter types
(`[bare-cand-param]`) and the site's argument shapes (`[bare-shape]`);
`KLIO_CIX_TRACE=<Class>` prints the scoped property-owner picks
(`[cix-prop]`, `[cix-route]`); `KLIO_DUMP_FN` shows `CallMemberOrGlobal`
name/func/candidate count.

The same mechanism covers NESTED classes sharing a simple name across
different outers (`Board.Item(val offset: Int)` / `Text.Item(val offset: String)`
collided under the bare `Item` key and `show(b.offset)` picked the `String`
overload): the flattened nested declaration's override yields `Board.Item`,
the twin key holds it, and the receiver type of the producing member already
carries the dotted name. Example: `examples/nested_namesake_property_types.kt`.

### Round jc24 → jc25: the two did-not-complete files, and what hid behind them

jc24: json **742 / 744, 0 failed, 2 did not complete** (all other suites at
floor; compose_ui 452/0). The census could not name the two silent jobs, so
it now does (`[census-hung]` for a runner error, `[census-nosummary]` with
the child's stderr tail for a timeout or crash): `JsonHugeDataSerializationTest`
and `JsonUnicodeTest`, both killed at the 120s cap.

Behind the Unicode timeout were three REAL failures the whole-file timeout
had hidden: `testUnicodeKeys`, `testUnicodeValues`, `testLongEscapeSequence`
all failed in 30ms with `get_field UnicodeKeys$serializer` — the
serialization pass generated no serializer for the FILE because
`@SerialName("\"")` was written back into generated Kotlin as `"""` (the
lexer hands the pass the unescaped literal). Root fix: every serial name
the pass writes into generated source is re-escaped (`kq`: quote,
backslash, dollar, control characters). Example:
`examples/serial_name_needs_escaping.kt`.

The timeouts themselves were three string-runtime roots, all quadratic:
- Non-ASCII `s[i]` walked from byte 0 on every read (2.6k chars 24ms → 10.6k
  chars 377ms). `StringData` now carries an atomic UTF-16/byte cursor and the
  builtins resume from it (`utf16UnitAt`, `utf16IndexToByte`,
  `byteToCharIndex`), walking BACKWARDS when the cursor is ahead (an escaper
  reads `text[i]` then appends `text[last, i)`).
- `substring`, `startsWith`, `regionMatches`-style builtins rescanned the
  whole receiver for ASCII-ness (`asciiScan`) or converted it to UTF-16
  (`utf16Units`) per call: 400 `substring` calls over an 80k-char ASCII
  string took 1.7s. The receiver's cached header meta (`ascii`, `u16_len`)
  now reaches the builtins through a per-thread receiver memo re-pointed at
  every receiver extraction; `substring` slices bytes between exact
  boundaries and `startsWith` compares bytes for surrogate-free prefixes.
- `StringBuilder.appendRange(String, from, to)` converted BOTH the value and
  the whole builder to UTF-16, concatenated, and re-encoded the builder
  (1.64s for 400 small ranges over an 80k builder; the `memset` at the top
  of the profile). It now appends the value's byte range through the
  string's cursor.
Measured: JSON decode of the Huge shape n=50/100/200/400 went from
174/443/1350ms (super-linear) to 103/198/400/778ms (linear); the
random-escape shape (300 strings) 7.1s → 5.5s with a flat interpreter-bound
profile (`fromHexChar`, `repeat`, `Random`, `printQuoted`). `JsonUnicodeTest`
completes 5/5 in 195s solo. Example: `examples/string_index_paths_unicode.kt`.

Census shape: both files are `split_files` (each test its own child, queued
first) and the json `timeout_ms` is 400s (datetime's precedent for its
100s+ compute children), so the fast tests count regardless and the heavy
ones count when they fit.

The Huge file's remaining time was the okio mode, whose reader shim
(`klioTest/json/StreamSupport.kt`, a `StringBuilder`-backed `okio.Buffer`)
reads the JSON one code point at a time through `sb[pos++]` and `sb.length`
— and `StringBuilder.get` re-encoded the WHOLE buffer to UTF-16 per call
while `length` re-counted it (n=25/50/100 okio decode: 0.43s → 1.57s →
5.3s). A builder now carries a reader-side memo (ASCII-ness, UTF-16 length,
a UTF-16/byte cursor) keyed by its cell and buffer identity, invalidated by
every mutating builtin (`sbMut`) and by construction; `get`/`length` are
O(1) on ASCII buffers and cursor-walked otherwise. okio decode: 0.16s →
0.31s → 0.62s (linear). Example: `examples/stringbuilder_index_paths.kt`.

jc26 (after the string-runtime and escaping roots, both heavy files split):
json **747 passed, 0 failed, 0 did not complete** — every test in the
json-tests tree counts (the split children each re-count the support
file's `ContextualTest`, hence 747 over the 744 universe). All other suites
at or above floor: core 138/0, ktor 450/0, coroutines 1299/0, compose_ui
452/0, io 1191/0, datetime 519/0, atomicfu 67/0. The json suite now stands
at zero: baseline 747, `max_failed = 0`, `max_incomplete = 0`.
