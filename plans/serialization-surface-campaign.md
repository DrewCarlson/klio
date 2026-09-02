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
  Remaining core 4: BasicTypesSerializationTest.testKvSerialization,
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
