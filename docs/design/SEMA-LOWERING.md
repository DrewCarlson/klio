# Lowering from sema

This is the design for the cutover in `plans/resolved-interpreter.md` (the
`cut/*` items). Lowering stops deriving types, callees and receivers and
translates what `src/sema` decided. The by-name instructions leave `Inst`, and
the runtime paths that serve them are deleted. Each section answers one
question with a decision; the last two give the order of work and the risks.

| Question | Decision |
|----------|----------|
| How lowering finds sema's answer | Dense per-file node ids in the AST; sema writes per-file tables indexed by node id |
| Where sema runs | After the serialization pass, on the AST lowering consumes. Alias expansion, renames, the file merge and lifting are deleted; compose becomes a lowering pass keyed on resolved callees |
| One identity per declaration | A serial bridge pass allocates every `ClassId`, `FuncId`, static and slot from sema's symbols, in symbol order |
| The base image | At the cutover a program re-collects the base declarations from the source text the image already carries and checks a digest; the end state serializes the symbol table (`sema/image`) |
| The instruction set | 37 variants: 19 of today's survive, 18 are new, 31 are deleted. No name reaches execution |
| Lowering's layout | About 8.5k new lines translate records and instantiate inline functions; about 60k lines of derivers, ladders and link passes are deleted |
| Order of work | Four green commits, one switch commit, then four bounded fix-forward items |

## 1. Record addressing

**Not spans, not pointers.** Sema keeps one flat list of `Ref`s keyed by an
anchor span (`src/sema/records.zig:83`). Spans collide: `for` records
`iterator`, `hasNext` and `next` at one span (`calls.zig:1886`), a delegate
three calls at one span (`calls.zig:1903`), `invoke` on a property a read and a
call at one name (`calls.zig:1300`), and passes synthesize nodes with copied
spans; the span-keyed typeck bridge (`src/ir/ir.zig:133-151`) is the precedent.
Pointers do not survive either: the build copies `Decl` values when it
concatenates files (`src/interp_ir/build/module.zig:228-246`), lifting makes
shallow copies, inline bodies come back from the image as new allocations
(`src/ir/lower/inline_state.zig:38-47`), and a pointer map cannot be
serialized.

**Node ids.** `ast.NodeId` is a `u32`, dense and unique within a file. The
parser assigns ids in source order and keeps the next free one in
`KotlinFile.node_count`; a pass that synthesizes a node takes ids from it. Ids
live on every `Expr` payload, on `Block`, `AssignStmt`,
`DestructuringDeclStmt`, `Property` and `Catch`, on the declarations and
parameters, and on `StringPart.ShortInterp` (through `Ident.id`, which fills
the identifier's padding and is `none` on every other identifier). Ids start
at 1; 0 is `none`. A local introduced by a bare identifier (lambda parameter,
`for` variable, catch binding, destructuring entry) has no id; its symbol rides
the record of the node that declares it. A test pins `@sizeOf(ast.Expr)` at 80
bytes (`ast.zig:610`); if the id would grow `Call`, its rare `arg_names` and
`type_args` move behind one box. In Debug, `ast.checkIds(file)` runs after the
last syntax pass and asserts each id appears once, so a pass that copies an
`Expr` fails there instead of producing a wrong answer later.

**What sema stores**, per file, in its arena:

```zig
pub const FileRecords = struct {
    rec: []u32,      // node id -> index into the pool the node's kind implies; 0 = none
    ty: []TypeId,    // node id -> the expression's type, zonked
    calls: std.ArrayList(CallRec),
    names: std.ArrayList(NameRec),
    recvs: std.ArrayList(RecvRec),
    tests: std.ArrayList(TypeTestRec),
    groups: std.ArrayList(GroupRec),
};
pub const CallRec = struct {
    callee: Sym,               // function, constructor, accessor, FunctionN.invoke
    form: CallForm,            // plain, super_, value_invoke, ctor, this_delegation,
                               // super_delegation, sam_ctor
    dispatch: Receiver,        // none | expr | implicit{kind, owner}
    extension: Receiver,
    super_class: Sym = .none,  // super<T>, super@L
    via: u32 = 0,              // the NameRec an invoke on a value reads first
    args: []const ArgSource,   // per callee value parameter, in declaration order
    context: []const Receiver, // per callee context parameter
    type_args: []const TypeId, // the callee's type parameters, substituted
    conv: []const Conv,        // per argument: none, sam(iface), suspend, unit
};
pub const ArgSource = union(enum) { arg: u16, default, vararg: []const VarargPart };
```

- **Calls**, including the desugared ones (operators, `for`, `componentN`,
  delegates, `+=`, `in`, ranges, `==`). Reified arguments are the `type_args`
  whose parameter is `reified`.
- **Names**: target (local, parameter, property, enum entry, object,
  companion), read or write, receivers, and a `backing_field` kind for `field`
  in an accessor (today a synthetic local, `body.zig:424`).
- **Receivers**: `{kind, owner}` for `this` and `this@L`.
- **Type tests** for `is`, `as`, catch and class literals: `TypeId`, erased
  class, nullability.
- **Groups** hang several calls off one construct's node: `for`, destructuring,
  compound assignment and `++`/`--` (get, operator, set, and whether `opAssign`
  or `op` then assign was chosen), `when` (per pattern), `try` (per catch),
  lambdas (symbol, type, parameters, `it`), object expressions and local
  classes (class symbol). A dotted `Path`, which the parser cannot split into a
  qualifier and member reads, holds one name record per segment that yields a
  value; as a call's callee it holds the chain for its prefix, and the `Call`
  node holds the call.
- **Declaration records**, keyed by symbol: supertype constructor calls,
  secondary delegation, enum entry arguments, property delegates.
- **Expression types** for every expression node, for the choices Kotlin makes
  by static type: a literal's kind, IEEE versus boxed `==` on floating types,
  `Unit` coercion of a lambda's result, template conversion.

Sema must add the argument map (it has it as `Applied.slots`,
`calls.zig:100`), the solved type arguments, conversions, context arguments
(not resolved for calls today) and `backing_field`. `klio sema --dump` then
prints from the tables, so the oracle checks exactly what lowering reads.

**Speculation.** Sema resolves some expressions more than once: a buffered
argument is dropped (`calls.zig:200`), a lambda is resolved muted to learn its
result (`calls.zig:1141`), and each resolution of a lambda makes a new symbol
(`calls.zig:1359`). Every table write follows the rules `Ctx.addRef` already
has (`body.zig:88`): nothing while muted, buffered writes into the buffer, a
commit copies them into the tables. In Debug a second committed write to a
node asserts. A dropped resolution's symbols are named by no record, so no id
is ever allocated for them.

**Lookup.** `FuncBuilder` holds the body's `*const FileRecords`, the sema and
the bridge; lowering reads `b.call(id)`, `b.name(id)`, `b.recv(id)`,
`b.test(id)`, `b.group(id)`, `b.exprType(id)`. A missing record is an internal
error naming the span; the function fails to build and nothing falls back. A
new census reason, `unrecorded`, counts resolution-bearing nodes without a
record, so the gap shows in `klio sema` before it can reach lowering.

**Inline and image bodies.** A body's records are read once, while it lowers.
An inline function is lowered once, at its declaration, and call sites
instantiate its IR (section 4), so a program never needs a base body's records
or AST and the image carries neither. Local classes and object expressions
lower at build time, which ends the AST pinned by `AstLambda`, `RegisterClass`
and `BuildObject`. Records are dropped with the build heap; `--lazy-bodies`
keeps the sema arena until its last body lowers.

## 2. Pipeline order

typeck checks a user program on the raw parse
(`src/cli/stdlib_image.zig:1177`), as does `klio sema`
(`src/cli/sema_cmd.zig:663-672`), while lowering consumes the AST after nine
more steps (`module.zig:217-605`, `overrides.zig:409-860`). After the cutover:

```
parse -> serialization (generated source) -> sema -> bridge -> lowering (with compose)
```

| Step today | Decision | Lines |
|------------|----------|------:|
| Serialization, `module.zig:217` | Stays before sema. It generates Kotlin text and re-parses it (`serialization_pass.zig:1677-1690`); sema resolves the result like any source | 0 |
| `alias_expand`, `module.zig:221` | Deleted; sema resolves aliases by identity (`calls.zig:501`, `body.zig:1892`) | -1.1k |
| Concatenation and merge into one file, `module.zig:228-246, 599-604` | Deleted; lowering walks sema's files and imports stay per file | -0.1k |
| Renames, `module.zig:346-597` | Deleted; two private `foo`s are two symbols | -0.3k |
| `liftFileDecls`, supertype repointing, `overrides.zig:409, 771-813` | Deleted; nested and local classes get ids from symbols | -0.9k |
| Expect-default copying, `overrides.zig:816-860` | Deleted; sema links actual to expect (`decls.zig:624`) and an omitted argument uses the expect's default node | -0.1k |
| `field` rewriting, `lift.zig:58-193` | Deleted; the `backing_field` record | -0.15k |
| Compose AST pass, `module.zig:252-343` | Moves into lowering | +3k / -5.1k |
| typeck | Runs for diagnostics only; lowering reads none of its tables (`cut/switch`) | -5k |

**Compose.** The pass decides composability from the last segment of an
annotation name and six name lists (`src/compose_pass/pass/collect.zig`,
`stability.zig`, `lambda.zig`). It already leaves calls to named composables
unthreaded (`walker.zig:1171`); lowering completes `$composer`/`$changed` once
it has the callee (`src/ir/lower/expr/compose.zig:320-352`). Before sema, the
name sets stay and sema would resolve calls against declarations that already
carry two extra parameters no call site maps. After sema as an AST pass, it
would have to write records for every node it synthesizes. Kotlin's own
compose support is an IR lowering after resolution, and so is klio's: sema
resolves `@Composable` on declarations and function types by identity;
lowering adds the hidden parameters and arguments, emits the restart, replace
and movable groups, `$dirty` and the skip gate, and computes stability from
class symbols and `@Stable`/`@Immutable`. Group keys keep today's function of
`(file, start, end)` (`compose_pass.zig:64-73`). The pass's 1316 lines of tests
become lowering tests over the emitted group calls.

## 3. Identity

**One identity per declaration.** After sema and before any body lowers, a
serial bridge pass walks the committed symbols in symbol order and allocates:

- a `ClassId` per class symbol, including nested, local, anonymous and
  companion classes, enum entries with bodies, `FunctionN`, and one SAM class
  per SAM-converted fun interface;
- a `FuncId` per function, constructor and accessor with a body or native
  binding, per committed lambda and local function, per defaults bridge, and
  per callable-reference adapter;
- a static slot per top-level property with storage and per enum entry, owned
  by an init unit (file or enum class) that runs on first access; a file's
  `@kotlin.native.EagerInitialization` properties get a unit of their own,
  which the program's start runs before `main` (`Resolved.eager_units`, in
  file order), as Kotlin/Native does, while the file's other properties stay
  lazy;
- a field slot per backing field (superclass slots, own, an inner class's outer
  instance, a local class's captures);
- a vtable slot per open member and an itable slot per interface member, from
  override links sema must record (`members.lookup` only implies them today).

The result is arrays indexed by symbol (`func_of`, `class_of`, `static_of`,
`field_of`, `vslot_of`, `native_of`). No id depends on the order the body pool
runs in; the pool only fills bodies.

**The base image at the cutover.** Collection is deterministic, so the bake and
a program get the same symbol prefix if they collect the same files in the same
order and nothing in the prefix is made on demand. Two changes make that hold:
`Sema.addFiles` runs per layer (base, then program), because today
`synthesizeAll` runs after all files (`decls.zig:574`) and would number base
data-class members after program declarations; and `FunctionN`,
`SuspendFunctionN` and SAM constructors are synthesized in the base layer, not
on first use (`sema.zig:271`). The image stores the prefix length, a digest of
`(kind, name, owner)` over it, and the bridge arrays. At load a program parses
the base sources the image already carries (7.5 MB of its 10 MB,
`docs/development/cold-start.md:416`), runs the base layer, checks the digest,
and resolves its files with lazy headers. On the Debug binary `klio sema`
spends 70 ms on stdlib headers and 173 ms with the compose packs, and the
stdlib parse is 5 to 10 ms of wall time (`cold-start.md:241, 434`). At the
usual Debug-to-ReleaseFast ratio that estimates 20 to 30 ms for the stdlib
against a 16 ms warm run today (step 3 measures it), accepted while the
cutover lands.

**The end state (`sema/image`).** The image serializes the prefix's symbols,
resolved headers and type store, decoded lazily per class, with the bridge
arrays beside them; a program parses nothing of the base. With inline
functions instantiated from IR and local classes lowered at build time, the
image also stops carrying base AST and most source text.

**Method slots at the switch** keep today's id scheme: a slot is the root
declaration's `FuncId` (`src/ir/core/ids.zig:100-125`) and `method_dispatch`
maps `(ClassId, slot)` to the override (`ir.zig:448-450`), now linked from
sema's override links instead of `overridesSlot`'s signature match
(`module_methods.zig:1050-1156`). `cut/objects` replaces the map with dense
vtables and itables.

## 4. Instruction set

Operands are registers, ids or literals. A member call's receiver is `args[0]`;
the extension receiver, context arguments and hidden arguments (continuation,
reified type values, `$composer`, `$changed`, defaults mask) are ordinary
positions in the callee's declared order.

| Variant | Fields | Produced from |
|---------|--------|---------------|
| `Const` | dst, value (literal) | literals, kind from the expression type |
| `SuspendResumePoint` | state | suspend calls |
| `LoadParam` | dst, idx | parameters; receivers the current body owns |
| `LoadCapture` | dst, idx | locals and receivers of an enclosing body |
| `Move`, `MakeCell`, `CellGet`, `CellSet` | registers | locals by symbol; captured `var`s |
| `GetFieldSlot`, `SetFieldSlot` | obj, slot, dst/value | a property read or written as its stored field; `this@Outer` in an inner class |
| `LoadStatic`, `StoreStatic` | static, dst/value | top-level properties with storage; enum entries |
| `LoadObject` | dst, class | objects and companions |
| `CallStatic` | dst, func, args, n_args | top-level, private, final and `super` targets; delegation; defaults bridges |
| `CallVirtual` | dst, slot, args, n_args | open members through a class type |
| `CallInterface` | dst, iface, slot, args, n_args | members through an interface type |
| `CallNative` | dst, native, args, n_args | declarations bound to a native body |
| `CallValue` | dst, callee, args, n_args | `FunctionN.invoke`; an extension function type's receiver is `args[0]` |
| `NewInstance` | dst, class, ctor, args, n_args | constructors; SAM constructors |
| `MakeClosure` | dst, func, captures | lambdas, anonymous functions |
| `FunctionRef` | dst, adapter, target, bound | function references (`target` answers equality and `name`) |
| `PropertyRef` | dst, getter, setter, bound, name | property references (`name` is `KProperty.name`, a value) |
| `ClassLiteral`, `ClassOf` | dst, class / src | `C::class`; `x::class` and reified `T::class` |
| `InstanceOf`, `Cast` | dst, src, class, nullable (+safe) | type tests, erased |
| `InstanceOfDyn`, `CastDyn` | dst, src, ty (register), nullable (+safe) | tests against a reified value |
| `NotNullAssert`, `LateinitCheck` | dst, src (+message name) | `!!`; `lateinit` reads |
| `BinOp`, `UnOp`, `Not` | primitive operands only | operator calls whose callee binds to a primitive operation |
| `ArrayGet`, `ArraySet` | registers | `get`/`set` bound to an array or string element intrinsic |
| `NewArray` | dst, class, args, n_args | vararg packing, `arrayOf` |
| `Trace` | span | debugging |

Terminators keep `Goto`, `Branch`, `Switch`, `Return`, `Throw`,
`Unreachable`, `TailJump` and `TailCallFunc`. `NonLocalReturn`,
`LabeledReturn` and the `LrAbsorb` region go: instantiation turns a return out
of an inline lambda into a jump in the caller's frame, and a labeled return
from any other lambda is that lambda's own `Return`. `CatchHandler` carries a
`ClassId` instead of `type_name` (`src/ir/core/inst.zig:854-911`).

**Deleted**: `LoadDispatchThis`, `LoadOuterThis`, `LoadContextParam`,
`ContextPush`, `ContextPop`, `EnclosingPush`, `EnclosingPop`, `QualifiedThis`,
`GetField`, `SetField`, `CompoundField`, `Index`, `IndexSet`, `Call`,
`CallValueWithThis`, `CallValueOrMember`, `CallMemberOrValue`, `CallMember`,
`CallSpread`, `CallMemberOrGlobal`, `AstLambda`, `BuildObject`,
`RegisterClass`, `MemberRef`, the name-based `PropertyRef`, `LoadGlobal`,
`StoreGlobal`, `LoadFromThisOrGlobal`, `StoreToThisOrGlobal`, `Lambda`,
`NewList`, and every run-time memo word. `Call`, `Lambda` and `NewList` return
as `CallStatic` (without `arg_names`, `type_args`, `exact`, `fuse_site`,
`trailing_lambda`), `MakeClosure` and `NewArray`.

**Translation rules for the harder forms:**

- **Implicit receivers.** Each body keeps an environment from `{kind, owner}`
  to a location: the current class's `this` is `LoadParam 0`, an outer class's
  a chain of `GetFieldSlot` on outer slots, an extension or lambda receiver or
  a context parameter its owner's parameter, anything from an enclosing body a
  capture, an object `LoadObject`. The enclosing-receiver chain
  (`src/ir/eval/chain.zig`, `frame.zig:219-251`) has nothing left to serve.
- **Dispatch.** Sema says what is called; lowering decides how from the
  callee's declaration: `CallNative` when natively bound, `CallStatic` when
  top-level, private, final or reached by `super`, `CallInterface` when owned
  by an interface, `CallVirtual` otherwise.
- **Arguments** are evaluated in source order, then permuted into declaration
  order. An omitted defaulted argument calls the declaration's defaults bridge
  with a mask; the bridge evaluates defaults in the declaring class and calls
  the target with its own dispatch, as kotlinc's `$default` does. Varargs pack
  with `NewArray`.
- **Properties.** A read is `GetFieldSlot` when the property has a backing
  field and the site may read it directly (final property, `field`, or a
  private property in its own class); otherwise a getter call. Writes mirror
  reads.
- **Constructors.** `NewInstance{class, ctor}` allocates and calls the
  constructor with the instance as `args[0]` and an inner class's outer
  instance next; delegation and supertype calls are `CallStatic` on the same
  instance. `Shape(3)` is whatever the record names: a constructor or
  `Companion.invoke`.
- **Inline functions.** An inline function is lowered once, at its
  declaration, as an ordinary function: an inline lambda parameter is invoked
  by `CallValue`, and a reified type parameter is a hidden parameter holding a
  runtime type value that `is T`, `as T`, `T::class` and `typeOf<T>()` read. A
  call site instantiates it. The IR is copied into the caller with registers
  and suspend states renumbered and parameters bound to the argument
  registers. Each `CallValue` on an inline lambda parameter becomes the lambda
  literal lowered in place, so its `return` returns from the caller, its
  `break` leaves the caller's loop and its suspend calls suspend the caller.
  Each dynamic reified test becomes a static one when the type argument is
  concrete. A `crossinline` parameter invoked from a nested closure, a
  `noinline` parameter and a non-literal argument are passed as values. The
  ordinary function stays the target of references to it. There is no
  separate template format, and it replaces the AST splice outright.

**The guard.** A comptime test walks `@typeInfo(Inst)` and fails the build on
a payload field that is a `[]const u8`, a `TypeRef`, a `ConstId` outside the
allow-list (`Const.value`, `LateinitCheck.name`, `PropertyRef.name`), a boxed
extra, or named `site_*`, and pins `@sizeOf(Inst)` at 64 bytes. A link-time
verifier checks id ranges, that a constructor belongs to its class, and that a
slot is inside its table.

## 5. Lowering after the cutover

A per-file audit of `src/ir/lower`, `src/ir/core`, `applicability.zig`,
`build.zig` and `exec_call.zig` (85.7k lines) finds about 21k lines of
translation that survive and 62.8k that derive, rank or look up by name. In
`src/ir/lower` alone it is 40k of 54.9k, so the plan's 34k undercounts; about
9k of the deleted lines are tests of that machinery and 2k are run-time arms.

| Fate | Files |
|------|-------|
| Survive | `lower.zig`, `mod.zig`, `literals.zig`, `when_expr.zig`, `expr/block.zig`, `thunks.zig`, `ast_scan.zig` (re-keyed by symbol); `core/class.zig`, `consts.zig`, `func.zig`, `ids.zig`, `names.zig`, `remap.zig`, `inst.zig` (new union); the layout links `linkMethodSlots`, `linkFieldSlots`, `linkPropertySlots`, `linkClassAncestors`, now fed by the bridge |
| Keep the translating part, read records (about 15k) | `decl.zig` (1.9k of 3.9k), `stmt.zig` (1.1k of 3.0k), `expr.zig`, `for_loop.zig`, `binary.zig`, `control.zig`, `refs.zig`, `helpers.zig`, `paths.zig` (string templates only), `lambda_body.zig`, `emit.zig`; `build.zig`'s block, register and scope core (`FuncBuilder` keeps about 45 of 141 fields, locals keyed by symbol); `module_lookup`, `module_methods`, `module_fields`, `module_props` without probes and links |
| Delete | `static_call_type`, `static_type`, `type_probe`, `probe`, `implicit_walk`, `expected`, `arg_shape`, `inline_target`, `bare_call`, `member_call`, `call_general`, `call`, `local_call`, `member`, `receiver`, `audit`, `tests_dispatch`, `tests_shapes`, `inline_call`, `inline_state` (the AST splice; instantiation replaces it); `module_bare`, `module_calls`, `module_refs`, `module_regclass`, `module_resolve_call`, `module_static`, `registry`, `core/tests_*`; `applicability.zig`, `site_census.zig`; the eleven compensating `link*` and eight `probe*` passes; the `pending_lambda_*` channels (`ir.zig:258-338`) |

New files in `src/ir/lower`, about 8.5k lines, written in step 4:

| File | Content | Lines |
|------|---------|------:|
| `records.zig` | record lookup on `FuncBuilder`, internal errors | 0.2k |
| `env.zig` | locals, cells and captures by symbol; the receiver environment | 0.5k |
| `call.zig` | `CallRec`: argument order and permutation, defaults bridge, varargs, context and hidden arguments, conversions | 1.3k |
| `dispatch.zig` | static, virtual, interface or native from the callee declaration | 0.2k |
| `name.zig` | `NameRec`: locals, field slots, accessors, statics, objects, enum entries | 0.6k |
| `operator.zig` | primitive operation table, `==` by static type, compound assignment, `++`/`--`, `in`, ranges | 0.6k |
| `refs.zig` | callable references, adapters, class literals | 0.5k |
| `types.zig` | type tests, casts, catch handlers, reified values | 0.3k |
| `classes.zig` | layouts, constructors, init order, enum entries, objects, local classes, object expressions; data, enum and value-class members as IR | 1.0k |
| `lambda.zig` | closures, receiver lambdas, SAM classes | 0.5k |
| `inline.zig` | instantiation: copy and renumber, bind parameters, lambda literals in place, static reified tests, suspend state renumbering | 1.5k |
| `core/bridge.zig` | symbol-to-id allocation and the image arrays | 0.8k |

`compose/` follows in step 6.

## 6. Order of work

The cutover starts when sema's exit holds: zero unresolved references over the
base, every pack and the corpus, and agreement with the oracle. Four green
commits come first and shorten the red.

| Step | Content | Size | Green at its end | Verified by |
|------|---------|-----:|------------------|-------------|
| 1 `front/node-ids` | `NodeId`, allocation, `ast.checkIds` | +1.5k | all; ids are inert | parser tests; `checkIds` over base, pack and corpus builds; the `Expr` size test; `itest-e2e` |
| 2 `sema/output` | per-file tables, full call records, expression types, write rules, `unrecorded`, `--dump` from the tables | +2.5k | all | sema tests; `unrecorded` zero; `scripts/sema-oracle-diff.py` unchanged |
| 3 `sema/facts` | override links, annotations by identity, `composable`, context arguments, per-layer `addFiles`, eager `FunctionN`/SAM symbols, Kotlin declarations for every `__klio_*` and pack native, `NativeId` by symbol | +1.5k | all | sema tests; census zero over base, packs, corpus; prefix digest stable across runs |
| 4 `lower/sema` | the section 5 files including instantiation, the new variants beside the old with eval arms, a driver running sema, bridge, lowering and the VM over `mini_kotlin` (`src/sema/tests.zig:18`) | +8.5k | all; not wired | `zig build test`: an executing test per construct in section 4 and per lowering acceptance fact in the plan |
| 5 `cut/switch` | sema at bake and at run; deletes the old lowering (-60k), the typeck bridge (-5k), the section 2 passes and the compose pass (-8k), the by-name variants and their eval and cgen arms (-3k), `site_census`, the resolution ratchet and the by-name audit sweeps; the guard lands; `FORMAT_VERSION` bump | +1k / -76k | build, unit tests, hello world; the non-compose corpus climbs from here | the base bakes with no function failing; `klio run` hello world; commontest sweep and example corpus counts logged as the red baseline |
| 6 `cut/compose` | compose lowering | +3k | compose | ported pass tests; compose runtime suite; `KLIO_SKIA_DUMP` screenshots |
| 7 `cut/objects` | slot-array instances with a `ClassId` header; dense vtables and itables of `FuncId` or `NativeId`; host-backed classes with tables; well-known slots for native callbacks | +3k / -2k | pack suites | sweep; corpus; `plans/pack-suites-to-green.md` floors |
| 8 `cut/runtime` | the by-name runtime paths; natives keyed by `NativeId` | +1k / -32k | everything the IR reaches | the compiler (a deleted path with a caller fails the build); `scripts/gate.sh` |
| 9 `cut/backends` | cgen and the loop JIT read the resolved variants; unhandled shapes decline | +1k / -1.5k | the gate | `scripts/native-c-sweep.sh`; JIT A/B against `KLIO_JIT=0` |

The red runs from step 5 to step 9 and is bounded by their sizes, about +9k
and -112k. Inline instantiation is written in step 4 and replaces the splice
at the switch, so suspend calls, `return` and `break` in inline lambdas stay
correct throughout. Local classes and object expressions lower at build time
from step 4; run-time `lowerMethod` is deleted in step 8. The runtime by-name
paths go in step 8, not earlier: from step 5 no instruction reaches them, but
until step 7 gives natives well-known slots, native code still calls into
Kotlin through them, and a virtual call on a host value finds its native
through the `"type.name"` probe
(`src/interp_ir/vm/host_call_member/virtual_tail.zig:170`) with the name taken
from the slot's root function. The gate runs at the end of step 9 and after
every later item.

## 7. Risks

| Risk | Mitigation |
|------|------------|
| An unresolved or unrecorded site reaches lowering | The switch waits for census zero including `unrecorded`; a missing record fails only its function and names the span; the census stays a gate step |
| Sema disagrees with kotlinc | The oracle over the corpus before the switch; each disagreement becomes a sema test; the plan's acceptance facts are tests before step 5 |
| A speculative resolution leaves a record behind | All writes follow the buffer rules; a second committed write to a node asserts in Debug |
| Base symbols differ between bake and load | Per-layer collection, no on-demand symbols in the prefix, the length and digest check; a mismatch rebakes |
| Instantiation meets a shape it cannot copy | A `crossinline` lambda invoked from a nested closure is passed as a closure, which is its Kotlin meaning; executing tests cover suspend calls, `return` and `break` in inline lambdas, nested reified calls and `suspend inline` functions before step 5 |
| Compose changes behaviour as a lowering | Group keys keep their function; the pass's tests are ported before it is deleted; the compose runtime suite returns to 100% |
| A pass copies an `Expr` and two nodes share an id | `ast.checkIds` |
| Id allocation depends on pool order | Only the serial bridge pass allocates |
| Records cost memory | They live with the build heap and are dropped with it; the image carries none |
| Debugging loses names | Display names stay as data beside the ids and `ir/disasm.zig` prints them; execution never reads them |
| A debugging knob loses its subject | It leaves `docs/development/debugging.md` in the same commit that deletes its path |
