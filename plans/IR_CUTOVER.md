# IR-native interpreter — clean rebuild

## Premise

The existing `klio-interp` is a tree walker that the IR partially
dispatches through. Every time we try to migrate one piece, we end up
patching the bridge between IR Insts and the tree walker's `eval_*`
methods; the bridge has grown more code than the migration removes.
Stop bridging. Build a new IR-only interpreter alongside the old one,
swap the CLI entry point when it reaches feature parity, then delete
the tree walker in one shot.

## Goals

1. A new crate `klio-interp-ir` whose runtime is pure IR — no AST
   eval, no tree-walker fallback, no `IrHost` shim that calls back
   into AST methods.
2. Lowering produces a complete IR program — including everything
   the existing tree walker currently handles directly (class
   construction, suspend bodies, anonymous objects, SAM, inner-class
   outer binding, shared-cell var captures, non-local return, reified
   inline, reflection).
3. `klio-cli` runs against the new interpreter once the parity sweep
   matches Kotlin output on the corpus + examples.
4. The old `klio-interp` is deleted after the cutover. The IR + new
   runtime are the only execution path.

Failing parity / corpus tests are acceptable mid-build while the new
crate is being filled in. The old interp keeps green as a reference
until we flip the switch.

## Workstreams (parallelisable)

Each workstream owns a sub-area of the IR and runtime. They share
the IR + runtime crates but otherwise touch disjoint files. Workstreams
can run in any order once their inputs land; later workstreams depend
on earlier ones only at the IR-shape level.

### W1 — Frozen IR contract

Pin the IR shape that the new interpreter consumes. The IR today is
in flux (Insts added per migration step). Freeze a "v1" before the
new interpreter starts so workstreams can target a stable target.

**Deliverables**
- `klio-ir` crate: every Inst variant the new runtime needs is
  defined; no `EvalAst`, no `BuildObject` AST-carrying variant, no
  tree-walker fallback hook.
- Add these new Insts (designs in §New IR variants below):
  - `ClosureNew { dst, body_func, captures }` — heap closure value.
  - `SharedCellNew { dst }` / `SharedCellRead { dst, cell }` /
    `SharedCellWrite { cell, value }` — for mutable var captures.
  - `SuspendResume { state, dst }` — explicit resume edge for the
    state machine.
  - `ReflectClass { dst, class }` / `ReflectFn { dst, func }` —
    KClass / KFunction reflection.
  - `OuterRef { dst }` — inner-class outer-instance read.
  - `BuildSamInstance { dst, iface_class, body_func, captures }` —
    SAM wrapper.
- Each Inst's evaluator (in the new runtime) is the only consumer.
- `klio_ir::lower` produces every shape end-to-end. No
  `Inst::Trace` / `Const::Unit` fallbacks for unhandled forms — every
  AST Expr lowers to a structured Inst sequence or fails the build
  loudly.

### W2 — `klio-runtime-ir` value + frame model

Replace `klio-runtime`'s Value enum with one that matches the new IR.

**Deliverables**
- `klio-runtime-ir::Value`:
  - `Closure { body: FuncId, module: Rc<Module>, captures: Vec<Value> }`
    replacing `Value::Lambda { params, body: Rc<Block>, env, ... }`.
    No AST.
  - `SharedCell(Rc<RefCell<Value>>)` for mutable captures.
  - Removes `Function { decl, env }` — top-level fns are just
    `FuncId` references resolved through the module.
  - Removes `BoundMethod { func, receiver }` AST carrier — bound
    methods become `Closure` with the receiver prepended to captures.
  - `IrClosure` is collapsed into `Closure` (no separate variant).
- `Frame` carries registers + captures only — no env Rc chain.
- `Class` is the IR-side `ClassDef` (synthetic primary ctor body
  FuncId, method FuncId table, supertype ClassIds, init-block
  FuncIds).
- `Instance.fields` is a `Vec<Value>` keyed by index, not name.
  Field-by-index Inst variants drop the per-call string lookup.

### W3 — `klio-interp-ir` core dispatch

The new interpreter binary. Pure IR execution.

**Deliverables**
- A `Vm` struct: `{ module, globals, scheduler, stacks }`.
- `Vm::run(module, main_fn)` walks the IR end-to-end via a switch
  on Inst, with no host trait. Stdlib intrinsics dispatch through
  the module's intrinsic table (already populated by `klio-stdlib`).
- No `IrHost` indirection. Methods that the existing `IrHost` calls
  back into the tree walker (`get_field`, `set_field`, `call_member`,
  `call_value_with_this`, `qualified_this`, `build_object`,
  `member_ref`, `register_class`, `lookup_global_throwing`,
  `dispatch_member_via_ast`) are gone — their semantics live as IR
  Insts or as direct Vm methods.
- Single-file program: lex → parse → typecheck → lower →
  `Vm::run`. The Vm never sees an AST.

### W4 — Class construction lowering

All class shapes lower to IR ctors. No runtime ClassDef-from-AST.

**Deliverables**
- Primary ctor → IR Func taking `(this, ctor_args...)`, returning
  Unit. Body: parent ctor chain call, body-prop init, init blocks.
- Secondary ctors → additional IR Funcs reachable through a per-
  class dispatch table.
- Inner class ctor → primary ctor takes `(this, outer, ...)`.
  `OuterRef` Inst reads the stored `__outer` field.
- Anonymous-object `object : T { ... }` → synthesises an IR Class
  inside `klio_ir::lower` at the call site. The synthesised class
  is registered in the module's classes vec and the call site
  emits `Inst::NewInstance` against its ClassId.
- SAM conversion (`SamIface { lambda }`) → `BuildSamInstance` Inst
  with the synthesised single-method class.
- Data class auto members → generated IR FuncIds at class lowering
  time. No runtime synthesis. `componentN` / `equals` / `hashCode`
  / `toString` / `copy` are real Funcs.

### W5 — Lambda / closure / capture lowering

Every lambda is a real `ClosureNew` with explicit captures.

**Deliverables**
- `Expr::Lambda` → emit `ClosureNew { body_func, captures }`.
  Captures are computed at lower time; mutable-var captures get a
  `SharedCell` wrapper allocated at the var's declaration site.
- `Closure` invocation goes through `Inst::CallValue` on the
  closure. The Vm reads body_func, sets up the frame with captures.
- `it` is bound as the closure's first param by lowering. No
  runtime "implicit it" handling.
- Receiver-typed lambdas (`String.() -> Unit`) bind `this` as the
  first param. Scope fns (`apply`, `with`, `run`) pass the receiver
  as the leading arg. No special this-binding path in the Vm.
- Non-local return in inline lambdas → `Inst::NonLocalReturn { fn_id, value }`
  emitted at lower time. The Vm pops frames until the matching
  fn_id and unwinds with the value.

### W6 — Suspend / coroutine state machine

Every `suspend fun` lowers to a state machine in IR.

**Deliverables**
- Entry block: `Switch state_reg → state_block[0..N]`.
- Each suspension point: `Inst::SuspendResume { state }` followed
  by `Terminator::Return(COROUTINE_SUSPENDED)`. The resume edge
  reads the resumed value into a destination reg and falls
  through.
- Continuation value carries `(FuncId, state, locals_snapshot,
  module_rc)`. `resume` / `resumeWith` / `resumeWithException` are
  Vm-side methods (no AST synthesis).
- `runBlocking` is a stdlib intrinsic that pumps `Scheduler::drain`
  until the lambda's continuation reports Done.

### W7 — Property accessors + delegates

All property accesses dispatch through real IR funcs.

**Deliverables**
- Plain `var n: Int` — `GetFieldByIdx { dst, receiver, idx }` /
  `SetFieldByIdx { receiver, idx, value }`. Field indices come from
  the class's static field layout (assigned at lower time).
- Custom getter/setter → its own IR FuncId; `GetField` Inst
  carries the optional accessor FuncId and routes through it when
  present. `field` keyword lowers to direct `GetFieldByIdx` on
  `this` — no AST rewriting.
- Delegated property → `__delegate$name` field (assigned at class
  layout time) + a generated accessor IR FuncId that calls
  `delegate.getValue(this, KPropertyN(name))` /
  `delegate.setValue(...)`.
- Built-in `lazy` / `Delegates.observable` / `Delegates.notNull`
  → stdlib host bindings that implement getValue/setValue. The Vm
  dispatches them through `CallValue` on the binding.

### W8 — Reflection

Reflection is structural.

**Deliverables**
- `::ClassName` → `Inst::ReflectClass { class: ClassId }`.
- `::topFn` → `Inst::ReflectFn { func: FuncId }`.
- `ClassRef::method` / `instance::method` → `Inst::ReflectMethod`
  with the resolved FuncId or method index.
- KClass / KFunction / KProperty values carry their ClassId / FuncId
  directly. `.simpleName` / `.parameters` / `.memberFunctions` read
  from the module's class table.
- Reified type params → `Inst::Const(TypeRef)` pushed as an extra
  call arg at lower time. `is T` / `T::class` consult the call
  frame's reified slot, not a tree-walker stack.

### W9 — Stdlib intrinsic + HOF dispatch

Stdlib is host-bound everywhere. The Vm doesn't know specific FQNs.

**Deliverables**
- Every HOF (`map`, `forEach`, `fold`, `groupBy`, `apply`, `let`,
  …) is a `klio-stdlib` host binding. The binding receives a
  `CallCtx` with an `invoke_closure(value: &Value, args: &[Value])`
  hook and dispatches the lambda through it.
- Scope fns + builders + comparator + sequence + array ctors all
  live in `klio-stdlib`.
- Sentinel routing (`__klio_intrinsic_*`) deleted.
- `klio_stdlib::implementation(fqn)` is the single resolution path.

### W10 — Top-level module registry

Module-scoped state lives on the Module itself, not the Vm.

**Deliverables**
- `klio_ir::Module` carries `classes`, `funcs`, `globals`,
  `top_level_properties`, `extensions`, `extension_properties`,
  `type_aliases`, `import_renames`, `suspend_fn_names`,
  `annotation_retentions`. Lowered at module build time; the Vm
  reads them.
- `Vm::globals` is the only mutable runtime state — initial values
  set by lowered top-level property init Funcs running at startup.
- No `ModuleRegistry` / `ModuleRegistryOwned` indirection.

### W11 — Pack loading

Packs register classes + funcs + bindings against the IR module.

**Deliverables**
- A pack contributes `Vec<Class>` + `Vec<Func>` + `Vec<NativeBinding>`
  that merge into the program's IR module before main runs.
- `klio-stdlib-pack` produces a frozen IR snapshot at build time —
  no AST loaded into the new Vm.
- Per-pack scheduler is registered via `Module::set_scheduler`.

### W12 — CLI cutover

Swap `klio` to the new Vm once parity sweeps green.

**Deliverables**
- `klio-cli` calls `klio_interp_ir::Vm` instead of `klio_interp`.
- Old `klio-interp` is deleted: `eval_expr`, `eval_call`, `eval_stmt`,
  `eval_block`, `call_function*`, `call_lambda*`, `call_method*`,
  `construct_*`, `run_ctor_chain`, `run_*_initializers`,
  `drive_suspend_*`, `run_blocking`, `eval_suspend_coroutine`,
  `eval_property_access`, `try_extension_property_*`,
  `materialize_sequence`, `try_eval_higher_order`, the whole
  IrHost shim, and every `eval_property_init_via_ir`-style
  bridge. The crate itself is removed from the workspace.
- `klio-runtime` and `klio-runtime-ir` consolidate.

## New IR variants

Sketches of the Insts each workstream introduces (final shape lives
in `klio-ir/src/lib.rs` once the workstream lands).

```rust
ClosureNew {
    dst: Reg,
    body_func: FuncId,
    captures: Reg,       // start of contiguous capture-reg run
    n_captures: u8,
}

SharedCellNew { dst: Reg, initial: Reg }
SharedCellRead { dst: Reg, cell: Reg }
SharedCellWrite { cell: Reg, value: Reg }

SuspendResume {
    state: u32,
    dst: Reg,            // where the resumed value lands
}

NonLocalReturn {
    enclosing_fn: FuncId,
    value: Reg,
}

OuterRef { dst: Reg, this: Reg }

BuildSamInstance {
    dst: Reg,
    iface_class: ClassId,
    body_func: FuncId,
    captures: Reg,
    n_captures: u8,
}

GetFieldByIdx { dst: Reg, receiver: Reg, idx: u16 }
SetFieldByIdx { receiver: Reg, idx: u16, value: Reg }

ReflectClass { dst: Reg, class: ClassId }
ReflectFn { dst: Reg, func: FuncId }
ReflectMethod { dst: Reg, receiver: Reg, method: FuncId }
```

## Sequencing

The strict order:

1. **W1** (frozen IR) and **W2** (runtime values) land first. Both
   are small and unblock everything else.
2. **W3** (Vm skeleton) plus **W9** (stdlib invocation hook) land
   together — gives a runnable hello-world Vm.
3. **W4** (classes), **W5** (lambdas), **W7** (properties) can run
   in parallel after W3. Each grows the Vm's correctness against
   its own slice of the corpus.
4. **W6** (suspend), **W8** (reflection), **W10** (registry), **W11**
   (packs) land after the above; they reuse the closures /
   ctor / property infrastructure.
5. **W12** (CLI cutover + deletion) closes out.

## Status

`klio-interp` (the existing tree walker + IR bridge) stays untouched
behind the `klio` binary as a reference implementation until W12.
Today's `klio-interp` will be deleted in its entirety once the new
Vm matches its corpus + examples output.

Today's incremental state — the IR-host fallback patches built up
during the previous migration attempts — is moot under this plan.
The compatibility layer in `klio-interp/src/lib.rs` will be removed
wholesale at W12. Until then we accept that the existing parity
sweep may drift; the new Vm's sweep is the success metric.

### Currently working through `--ir-vm`

**Corpus + examples passing through the new Vm: 353 / 353. klio-interp deleted.**

The new Vm (`klio_interp_ir::Vm`, no `klio-interp` dependency) runs:

- `main` returns + `println`, arithmetic, control flow.
- Top-level `var` / `val` reads + writes.
- Top-level function calls + recursion.
- String templates with short interpolation.
- Stdlib calls: `listOf`, `println`, exception ctors via
  `IMPLICIT_ALIASES`.
- Classes with simple primary ctors (`val` / `var` params); member
  method calls including supertype walk; mutable state on instance
  fields; bare-name + qualified field reads.
- `data class` with field access.
- Body property initialisers (`val x: Int = 42` in a class body).
- Lambdas: closures with read-only captures, implicit-`it`,
  anonymous-fn, passed-as-arg.
- HOF stdlib bindings — `map`, `forEach`, `filter`, `let` — with
  recursive lambda invocation through `IntrinsicHost`.
- Built-in property reads via stdlib probe (`"abc".length` etc.).
- Member calls via stdlib FQN probe.
- Inheritance: method dispatch walks `supertype_names`.

Still returns `Unimplemented` on: write-back var captures
(`var sum = 0; xs.forEach { sum += it }`), custom getters / setters,
property delegates, suspend functions, inner classes, anonymous-
object expressions, SAM construction, init blocks, secondary ctors,
parent ctor chains, reflection refs.
