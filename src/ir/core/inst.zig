const std = @import("std");
const ast = @import("ast");
const runtime = @import("runtime");
const FF = runtime.forest.ForestField;
const root_ir = @import("../ir.zig");
const core_ids = @import("ids.zig");

const BlockId = core_ids.BlockId;
const ClassId = core_ids.ClassId;
const ConstId = core_ids.ConstId;
const FuncId = core_ids.FuncId;
const MethodSlotId = core_ids.MethodSlotId;
const Reg = core_ids.Reg;
const ScopeClassRef = core_ids.ScopeClassRef;
const ScopeRename = core_ids.ScopeRename;
const Span = root_ir.Span;
const TypeRef = core_ids.TypeRef;

pub const Inst = union(enum) {
    /// Materialise a constant into a register.
    Const: struct { dst: Reg, value: ConstId },
    /// Suspend-resume marker for IR-lowered suspend bodies. A
    /// `state` integer identifies which resume target the
    /// suspending call site corresponds to so the dispatch table
    /// at the function entry can route a resumption to the
    /// matching block.
    SuspendResumePoint: struct { state: u32 },
    /// Load a parameter into a register.
    LoadParam: struct { dst: Reg, idx: u16 },
    /// Load a captured variable from the enclosing env.
    LoadCapture: struct { dst: Reg, idx: u16 },
    /// Move one register's value into another.
    Move: struct { dst: Reg, src: Reg },
    /// Box `src` into a fresh capture cell (`Value::Cell`) and put
    /// it in `dst`. Emitted for a `var` declaration when the var is
    /// captured by a nested lambda (Kotlin `Ref` boxing).
    MakeCell: struct { dst: Reg, src: Reg },
    /// Read the value held by the capture cell in `cell` into `dst`.
    CellGet: struct { dst: Reg, cell: Reg },
    /// Store `value` through the capture cell in `cell`, keeping the
    /// shared `Rc` so every holder observes the write.
    CellSet: struct { cell: Reg, value: Reg },
    /// Read a local property of a class instance.
    GetField: struct {
        dst: Reg,
        receiver: Reg,
        field: ConstId,
        /// Runtime site memo, single-fill: the first resolving class's
        /// identity claims the site (CAS from 0), then `site_route`
        /// holds that class's packed field-read route. Only the CAS
        /// winner ever writes `site_route`, so the pair can never tear.
        /// A stale baked value mismatches every live identity and the
        /// site just stays on the slow path.
        site_cls: u64 = 0,
        site_route: u64 = 0,
        /// The claiming receiver's LAYOUT identity (`InstanceData.shapeOf`)
        /// recorded alongside a STORED route: when the live receiver matches
        /// BOTH the class claim and this shape, the stored index provably
        /// names the property and the per-hit name re-verify is skipped.
        /// Shape alone is not a claim key — two classes can share a layout
        /// while routing the same name differently (a custom getter on one).
        site_shape: u64 = 0,
        /// Site verdict for serving a NULL stored slot: 0 = unasked, 1 = the
        /// property is an unset-`lateinit` shape the ladder must adjudicate,
        /// 2 = a plain null this site may serve.
        null_ok: u8 = 0,
    },
    /// Write a local property of a class instance.
    SetField: struct {
        receiver: Reg,
        field: ConstId,
        value: Reg,
        /// `super.prop = v`: the class whose body wrote it. The setter search
        /// then STARTS at that class's supertypes — an overriding setter whose
        /// body writes `super.prop` must reach the base accessor, not itself
        /// (`ViewApplier.current`'s setter does exactly that, and re-entering it
        /// recursed until the stack died). Null for an ordinary write.
        super_owner: ?ConstId = null,
    },
    /// Compound-assign to a property: `recv.field <op>= value`. The
    /// evaluator reads the current field value and, when that value
    /// carries the in-place operator (`plusAssign` family — built-in
    /// mutable collections, a user `operator fun plusAssign`), dispatches
    /// it on the field value and performs NO write-back: Kotlin mutates the
    /// receiver in place and never reassigns the (often read-only)
    /// property. Otherwise it falls back to read-modify-write
    /// (`recv.field = recv.field.<op>(value)`), which is what `Int` and
    /// other scalar properties need.
    CompoundField: struct {
        receiver: Reg,
        field: ConstId,
        op: BinOp,
        value: Reg,
    },
    /// Index a `List`, `Map`, or `Array`. Range checks happen in
    /// the evaluator.
    Index: struct { dst: Reg, receiver: Reg, index: Reg },
    /// Store at an indexed slot.
    IndexSet: struct {
        receiver: Reg,
        index: Reg,
        value: Reg,
    },
    /// Call a static function by id, with the args pulled from a
    /// run of registers starting at `args`. `arg_names` carries an
    /// optional `?ConstId` per slot — non-null for `foo(a = 1)`,
    /// null for positional. Empty when every arg is positional.
    Call: struct {
        dst: Reg,
        func: FuncId,
        args: Reg,
        n_args: u32,
        arg_names: []?ConstId = &.{},
        /// Call-site type arguments, in declaration order. Each entry
        /// is the interned simple type name (or fully-qualified name)
        /// the source wrote. Consumed by reified type-parameter
        /// dispatch when the callee is an `inline fun <reified T>`.
        type_args: []ConstId = &.{},
        /// The overload was resolved statically at lower time using an
        /// explicit argument cast (`f(x as T)`). Runtime overload
        /// re-resolution must NOT override it by the argument's runtime
        /// value type — the cast is the source's deliberate selection.
        exact: bool = false,
        /// Site verdict for a callee whose plan carries `FAST_CALL_AMBIG_FLAG`:
        /// 0 = unasked, 1 = the fusion must not take this call, 2 = the baked
        /// target is what scope resolution picks here. Single-fill.
        fuse_site: u8 = 0,
        /// The source supplied the final argument as a trailing lambda
        /// (`f(x) { … }`). Kotlin binds that lambda to the LAST
        /// parameter; a positional lambda (`f(x, { … })`) binds its own
        /// slot. The bit survives lowering so an under-applied call over
        /// defaulted middle params binds by syntax, not by a fit guess.
        trailing_lambda: bool = false,
    },
    /// `receiver.lambda(args)` — invoke a callable with a
    /// receiver bound as `this` inside the body. Used for
    /// receiver-typed lambda invocations on a local that's not
    /// a method on the receiver's class.
    CallValueWithThis: struct {
        dst: Reg,
        callee: Reg,
        receiver: Reg,
        args: Reg,
        n_args: u32,
        arg_names: []?ConstId = &.{},
        /// Lowering proved that the callee's declared type is a receiver
        /// function. The VM may therefore adapt a plain underlying function
        /// positionally instead of using compatibility receiver inference.
        receiver_shape_exact: bool = false,
        /// The DECLARED receiver head of a receiver-lambda param invoked
        /// bare (`transform(x)` for `transform: FlowCollector.(A) -> R`).
        /// The syntactic innermost `this` register can be a coroutine that
        /// rebound the enclosing block's capture slot; Kotlin binds the
        /// innermost implicit receiver OF THE DECLARED TYPE, so the VM
        /// re-selects by this head before dispatch. Null keeps the passed
        /// receiver.
        recv_head: ?ConstId = null,
    },
    /// Call a callable value held in a register.
    CallValue: struct {
        dst: Reg,
        callee: Reg,
        args: Reg,
        n_args: u32,
        arg_names: []?ConstId = &.{},
        /// Call-site type arguments (interned head names), recorded for
        /// the bare-call-to-global form so a stdlib container creator
        /// dispatched as an intrinsic value (`emptyList<String>()`) can
        /// stamp its result's declared element type.
        type_args: []ConstId = &.{},
    },
    /// Call a callable value with a mix of positional and spread
    /// args. Each `SpreadPart` is one source register; spread
    /// parts are flattened (each item of the array/list becomes a
    /// positional arg) at evaluation time.
    CallSpread: struct {
        dst: Reg,
        callee: Reg,
        parts: []SpreadPart,
        arg_names: []?ConstId = &.{},
        /// Statically resolved member slot for a spread call. When present,
        /// `callee` is the receiver and `arg_params` maps each source part to
        /// its declaration parameter before spread expansion duplicates it.
        virtual_slot: ?MethodSlotId = null,
        arg_params: ?[]u32 = null,
        trailing_lambda: bool = false,
        /// When set, this is a member-dispatched spread call: the
        /// flattened args are passed to method `member` on the value in
        /// `callee` (the receiver), rather than invoking `callee` as a
        /// callable. Lets `recv.method(*array)` / a bare own-member
        /// `m(*array)` dispatch through member resolution.
        member: ?ConstId = null,
        /// The bare top-level name whose overload set lowering bounded by the
        /// call site's package/import scope. `candidates` is authoritative
        /// when non-null (including an empty slice); the evaluator selects
        /// from it after spread parts have been flattened instead of invoking
        /// the arg-blind function value in `callee`.
        name: ?ConstId = null,
        candidates: ?[]const FuncId = null,
        /// Declaring package of the lowering-selected candidate set. A
        /// synthesized lambda frame may have no package of its own; this keeps
        /// runtime applicability inside the already-resolved source scope.
        anchor_pkg: ?ConstId = null,
    },
    /// `super.method(args)` — dispatch the named method on the
    /// receiver's value, but resolved against the parent of
    /// `owner_class` rather than the leaf class. When `qualifier`
    /// is non-null, this is `super<Qual>.method()` — the host
    /// dispatches directly on `Qual` instead of walking to the
    /// parent.
    CallSuper: struct {
        dst: Reg,
        receiver: Reg,
        owner_class: ConstId,
        qualifier: ?ConstId = null,
        name: ConstId,
        args: Reg,
        n_args: u32,
        arg_names: []?ConstId = &.{},
    },
    /// `name(args)` where `name` resolves to an in-scope value that
    /// also names a member function of the enclosing class. Invoke
    /// `callee` if invocable, else dispatch `name` as a member on
    /// `this_recv`.
    CallValueOrMember: struct {
        dst: Reg,
        callee: Reg,
        this_recv: Reg,
        name: ConstId,
        args: Reg,
        n_args: u32,
        arg_names: []?ConstId = &.{},
    },
    /// Explicit-receiver call `recv.name(args)` where `name` is also
    /// a callable local/param in scope. If `recv` has member `name`,
    /// dispatch the member with `args`; otherwise invoke `fallback`.
    CallMemberOrValue: struct {
        dst: Reg,
        receiver: Reg,
        name: ConstId,
        fallback: Reg,
        args: Reg,
        n_args: u32,
        arg_names: []?ConstId = &.{},
        /// The receiver's STATIC type is an unbounded type parameter, so it
        /// declares no members: Kotlin compiles the body once against the
        /// bound (`Any?`), and a call like `receiver.block()` inside
        /// `fun <T, R> with(receiver: T, block: T.() -> R)` can only bind the
        /// in-scope callable. Without this the receiver's RUNTIME class gets
        /// consulted, and a same-named member on it hijacks the parameter --
        /// `with(node) { ... }` on a node that happens to own a `block` field
        /// ran that field instead of `with`'s own block.
        recv_erased: bool = false,
        /// The fallback's declared type is a receiver function, so the call
        /// receiver binds its extension receiver. A plain callable fallback
        /// receives only `args`.
        fallback_takes_receiver: bool = false,
        /// Lowering proved whether the fallback is receiver-typed. When false,
        /// invocation keeps the compatibility path for incomplete cross-pack
        /// callable metadata.
        fallback_receiver_shape_known: bool = false,
    },
    /// Member call on a receiver. The evaluator resolves the
    /// method through the receiver's class table at runtime.
    CallMember: struct {
        dst: Reg,
        receiver: Reg,
        name: ConstId,
        args: Reg,
        n_args: u32,
        arg_names: []?ConstId = &.{},
        /// The source supplied the final argument as a trailing lambda
        /// (`recv.f(x) { … }`). Kotlin binds that lambda to the LAST
        /// parameter of an under-applied call; without the bit the binder
        /// falls back to an arity-fit guess. See `Inst.Call.trailing_lambda`.
        trailing_lambda: bool = false,
        /// The receiver's DECLARED type head when lowering knows it (a
        /// bare call on the implicit `this` of an extension body, whose
        /// static type is the extension's declared receiver). Kotlin
        /// resolves extension calls against the static receiver type, so
        /// dispatch must not bind a runtime subtype's same-name
        /// extension when this is set.
        static_recv: ?ConstId = null,
        /// The receiver expression's DECLARED type head (a typed local/param,
        /// an unsafe cast), consumed ONLY by the extension-selection filter:
        /// Kotlin resolves member-vs-extension against the static type. Never
        /// touches the member walk (unlike `static_recv`, whose meaning is
        /// the extension-BODY receiver).
        declared_recv: ?ConstId = null,
        /// A lowering-resolved, provably-monomorphic dispatch target. When set,
        /// the runtime calls it directly and skips all name-based resolution
        /// (the `funcsBySimpleName` walk, the applicability/subtype filters, the
        /// simple-name-from-FQN scans). Only set where the target cannot vary at
        /// runtime — a builtin receiver whose static type is known, a final
        /// member — so direct dispatch stays sound. Null keeps the virtual
        /// name-based path.
        resolved: ?FuncId = null,
        /// Runtime site memo, single-fill (see `GetField.site_cls`): the first
        /// Instance class whose by-name dispatch flat-resolved claims the
        /// site; `site_sig` records the argument-type signature that
        /// resolution was keyed under and `site_route` the packed target
        /// (`FuncId << 1 | 1`, so a filled route is never 0). A later call
        /// with the same receiver class and signature replays the target
        /// without the string-keyed cache probe or the ladder.
        site_cls: u64 = 0,
        site_sig: u64 = 0,
        site_route: u64 = 0,
        /// Declaring instance for a resolved member-extension target. The
        /// extension receiver remains in `receiver`; this second operand is
        /// the lexical/object dispatch receiver selected by Kotlin's implicit
        /// receiver tower. Null for ordinary members and top-level extensions.
        dispatch_receiver: ?Reg = null,
    },
    /// Virtual member call whose overload was resolved statically. `slot`
    /// names the selected declaration's override family.
    ///
    /// The intended runtime work is one `(receiver ClassId, slot) -> FuncId`
    /// lookup. That holds for every receiver whose class carries slot entries,
    /// which is every user-declared class. It does NOT yet hold for a
    /// HOST-BACKED receiver: a `.List`/`.Set`/`.Map` value reports a
    /// collection interface as its type, that interface has no Kotlin
    /// declaration in any source klio reads, so `methodSlotTarget` has nothing
    /// to return and `invokeVirtualMember` falls back to a member-name walk.
    /// `KLIO_SLOT_BYNAME` counts those; they are the gap between this comment
    /// and the implementation, and closing it is the builtin-member
    /// declaration work, not a change to this instruction.
    CallVirtual: struct {
        dst: Reg,
        receiver: Reg,
        slot: MethodSlotId,
        args: Reg,
        n_args: u32,
        /// The declaration parameter index filled by each source-order
        /// argument (receiver excluded). Null selects ordinary positional
        /// binding; a non-null empty map represents an indexed zero-argument
        /// call such as an empty vararg. This is resolved against the slot root
        /// during lowering, so override parameter names are irrelevant.
        arg_params: ?[]u32 = null,
        arg_names: []?ConstId = &.{},
        trailing_lambda: bool = false,
        /// Runtime site memo, single-fill (see `GetField.site_cls`), for the
        /// HOST-BACKED receiver gap documented above: the first host-shape
        /// receiver whose member the by-name walk dispatched DIRECTLY to a
        /// native form claims the site. `site_cls` is the interned pointer of
        /// the receiver's type FQN (CAS from 0), `site_name_*` the
        /// module-owned member name, and `site_native` the native form —
        /// stored LAST with release as the validity gate. Replays skip the
        /// class-registry probe, the FQN composition, and the string-keyed
        /// intrinsic lookup. A stale baked value mismatches every live
        /// pointer identity and the site just stays on the slow path.
        site_cls: u64 = 0,
        site_native: u64 = 0,
        site_name_ptr: u64 = 0,
        site_name_len: u32 = 0,
    },
    /// Instantiate a class.
    NewInstance: struct {
        dst: Reg,
        class: ClassId,
        args: Reg,
        n_args: u32,
        arg_names: []?ConstId = &.{},
        /// The DECLARED type head of each argument, where lowering knows one.
        /// Kotlin selects a constructor overload from the static types, and
        /// an interpreted instance reports no class of its own at run time —
        /// `Box(circle)` and `Box(shapeTypedCircle)` are indistinguishable to
        /// a value-only ranking, which then took the first declaration.
        arg_static_heads: []?ConstId = &.{},
    },
    /// Build a `List` from a range of registers.
    NewList: struct { dst: Reg, args: Reg, n_args: u32 },
    /// `this@Qualifier` — walk the receiver's outer chain
    /// looking for an instance whose class matches `qualifier`,
    /// and write that instance into `dst`.
    QualifiedThis: struct {
        dst: Reg,
        receiver: Reg,
        qualifier: ConstId,
        /// A miss writes Null instead of raising: a local class declaration
        /// snapshots the enclosing member extension's dispatch receiver for
        /// its `this@Owner` reads, and the snapshot must not fail a body
        /// that never reads it.
        soft: bool = false,
    },
    /// `::name` — produce a `KProperty`-shaped reference value
    /// carrying the property name. Reflection target.
    PropertyRef: struct { dst: Reg, name: ConstId },
    /// `Receiver::name` — bind a callable reference to the
    /// receiver value. The host resolves the right shape from the
    /// receiver's class table.
    MemberRef: struct {
        dst: Reg,
        receiver: Reg,
        name: ConstId,
        /// Exact top-level extension declaration selected at lowering. Null
        /// keeps ordinary member/property reference dispatch by name.
        func: ?FuncId = null,
        /// The expected function shape at the reference site (a
        /// function-typed argument slot): value-parameter count, -1 when
        /// unknown, and whether the result is coerced to Unit. The runtime
        /// stamps the reference as adapted when the shape differs from the
        /// target's signature.
        adapt_arity: i16 = -1,
        adapt_unit: bool = false,
        /// The expected parameter type heads joined by `|` (a vararg slot
        /// expecting an array is not an adaptation); null when unknown.
        adapt_heads: ?ConstId = null,
    },
    /// Binary primitive operation. Operands are guaranteed to be
    /// the right type by typeck.
    BinOp: struct {
        dst: Reg,
        op: BinOp,
        lhs: Reg,
        rhs: Reg,
        /// Set when this BinOp is the combine step of a compound assignment
        /// (`a += b` lowered to `a = a.<op>(b)`). For a mutable collection
        /// left operand the evaluator then dispatches the in-place
        /// `<op>Assign` (Kotlin prefers `MutableCollection.plusAssign`),
        /// keeping the receiver mutable instead of producing a read-only
        /// `plus` result that a later mutation would reject.
        compound: bool = false,
    },
    /// Unary primitive operation.
    UnOp: struct { dst: Reg, op: UnOp, operand: Reg },
    /// Boolean negation.
    Not: struct { dst: Reg, src: Reg },
    /// Type-cast (`as T`) or safe-cast (`as? T`). The evaluator
    /// resolves the type by name; smart-cast info from CFA can
    /// elide checks.
    Cast: struct {
        dst: Reg,
        src: Reg,
        ty: TypeRef,
        safe: bool,
    },
    /// `is T` check; result is a `Bool`.
    InstanceOf: struct { dst: Reg, src: Reg, ty: TypeRef },
    /// Resolve the nearest in-scope context value whose runtime type is a
    /// subtype of `ty` and write it to `dst`. Emitted for a named context
    /// parameter's binding in a contextual declaration's body and for
    /// `contextOf<T>()`. `erased` (a generic context-parameter type, or a
    /// `*` type argument) takes the innermost value regardless of type.
    /// Writes `.Null` when no compatible value is in scope — an unresolved
    /// context is diagnosed statically by typeck, not here.
    CtxLoad: struct { dst: Reg, ty: ConstId, erased: bool = false },
    /// The stdlib `context(v..., block)`: push the `n_ctx` context values in
    /// the register run at `ctx_args` onto the context stack, invoke the
    /// callable in `block` with no value arguments, then pop them. `dst`
    /// receives the block's result. Context values are made available for
    /// context resolution only, never as implicit receivers.
    CtxScope: struct { dst: Reg, ctx_args: Reg, n_ctx: u32, block: Reg },
    /// Fully-positional invocation of a contextual function-type value:
    /// `f(c0, c1, a0, ...)` where `f: context(C0, C1) (A0, ...) -> R`. The
    /// leading `n_ctx` args are pushed as context values, `callee` is
    /// invoked with the remaining `n_args - n_ctx` args, then the pushed
    /// contexts are popped. `args` is one contiguous run so the register
    /// visitor keeps every operand live.
    CtxCall: struct {
        dst: Reg,
        callee: Reg,
        args: Reg,
        n_args: u32,
        n_ctx: u32,
        arg_names: []?ConstId = &.{},
    },
    /// `!!` not-null assertion.
    NotNullAssert: struct { dst: Reg, src: Reg },
    /// Read of a local `lateinit var`: `src` still holding the declaration's
    /// `Null` means the variable was never assigned, which throws
    /// `kotlin.UninitializedPropertyAccessException` naming `name`.
    LateinitCheck: struct { dst: Reg, src: Reg, name: ConstId },
    /// Marker for the evaluator's debugger / tracing hook.
    Trace: struct { span: Span },
    /// Push the value in `src` onto the executing frame's
    /// enclosing-receiver chain as a `with`-subject for the duration of a
    /// spliced receiver-lambda region (`EnclosingPop` ends it). Runtime
    /// dispatch — bare-name walks, member-extension owners, operators —
    /// then sees the subject exactly as the framed route would. The chain
    /// is frame-owned, so a non-local exit that skips the pop is healed
    /// at frame teardown.
    EnclosingPush: struct { src: Reg },
    EnclosingPop: struct {},
    /// Resolve a bare global identifier through the Host. Used when
    /// Path lowering cannot bind the name to a local register —
    /// covers top-level stdlib calls (`println`, `listOf`) and any
    /// other module-scoped reference. When the lowerer's symbol index
    /// resolved the reference to a unique declaration, `func` / `class`
    /// carry that exact identity and the host binds it directly — the
    /// name string remains for traces and as the unresolved fallback.
    /// `ctor_ref`: `::C` denotes the CONSTRUCTOR — the read yields the
    /// class value even when a companion is published (a value-position
    /// `C` is the companion singleton).
    LoadGlobal: struct { dst: Reg, name: ConstId, func: ?FuncId = null, class: ?ClassId = null, ctor_ref: bool = false },
    /// Bare-name read in a receiver context that doesn't resolve as a
    /// local / capture / own member. The runtime searches the implicit
    /// receivers (the captured `this` at `this_idx`, the enclosing-`this`
    /// chain, and each dispatch receiver's class-nesting tower) innermost
    /// first for a field/member named `name`; otherwise it falls back to
    /// the global. When the lowerer's symbol index resolved the global
    /// fallback to a unique declaration, `func` / `class` carry that
    /// exact identity so the global arm binds directly.
    LoadFromThisOrGlobal: struct {
        dst: Reg,
        this_idx: u16,
        name: ConstId,
        func: ?FuncId = null,
        class: ?ClassId = null,
        /// Runtime site memo for the implicit-receiver walk: a packed
        /// {shape-hash, winner-index, verdict} word filled in place under
        /// the same benign-race convention as `Func.fast_call`. The shape
        /// hash folds each candidate's class identity and field count, so
        /// a stale entry (including one baked into an image by another
        /// process) mismatches and the full walk re-fills it.
        site_cache: u64 = 0,
    },
    /// Symmetric write counterpart of `LoadFromThisOrGlobal`: the
    /// innermost implicit receiver with a member named `name` takes the
    /// write (`SetField`); when no receiver owns it, fall back to
    /// `StoreGlobal(name)`.
    StoreToThisOrGlobal: struct {
        this_idx: u16,
        name: ConstId,
        value: Reg,
        /// Statically known innermost implicit receiver, when lowering has it
        /// in a register. An inline extension's spliced body binds its
        /// receiver as an ordinary register of the CALLER's frame, so the
        /// capture slot `this_idx` names is never populated and the walk below
        /// cannot see the receiver at all — a bare-name write inside
        /// `x.apply { … }` fell through to the global and was silently lost.
        /// Tried FIRST (it is the innermost receiver) and still subject to the
        /// same ownership check, so a receiver that does not declare the
        /// property falls through exactly as before.
        recv: ?Reg = null,
    },
    /// Call a bare-name function inside a lambda body that may be
    /// invoked with a this-receiver. If the captured this is an
    /// instance with a method named `name`, dispatch as a member
    /// call on it; otherwise fall back to a top-level lookup +
    /// invoke.
    CallMemberOrGlobal: struct {
        dst: Reg,
        this_idx: u16,
        name: ConstId,
        args: Reg,
        n_args: u32,
        arg_names: []?ConstId,
        /// Trailing-lambda syntax bit; see `Inst.CallMember.trailing_lambda`.
        trailing_lambda: bool = false,
        /// The scope-resolved class when the bare name is a constructor
        /// call the index bound; the global leg constructs exactly this
        /// class instead of re-resolving the simple name.
        class: ?ClassId = null,
        /// The lowering-resolved top-level function when the bare call
        /// would have bound statically but a runtime receiver member can
        /// shadow it; the global leg calls exactly this declaration
        /// instead of re-resolving the simple name.
        func: ?FuncId = null,
        /// Call-site EVIDENCE committed `func` among a return-variant
        /// family (an `as` cast or the trailing lambda's derived return):
        /// the global leg must not value-re-rank past it - a closure
        /// argument carries no return type, so the re-rank would run the
        /// first-declared variant (the Double sumOf, printing 3.0 where
        /// kotlinc prints 3). The member leg still runs first.
        func_final: bool = false,
        /// The package/import-scoped callable set computed by the lowering
        /// resolver. `null` is the legacy/host-symbol boundary: no complete,
        /// rankable declaration set was available, so the runtime may consult
        /// the name index. A non-null slice is authoritative, including an
        /// empty slice (no package-scope callable is visible): runtime
        /// overload selection must stay within these FuncIds and may not
        /// widen back to every same-simple-name declaration in the program.
        candidates: ?[]const FuncId = null,
        /// An inline-splice's bound receiver, held in a local register rather
        /// than the frame's `this` slot or a capture. When set it is the
        /// innermost implicit-receiver candidate, ahead of the frame `this`
        /// and the enclosing chain — so a bare extension call inside a spliced
        /// receiver-lambda (`collect` in `FlowCollector.()`) can miss the
        /// lambda receiver and bind the outer one.
        recv: ?Reg = null,
        /// The enclosing extension's declared receiver type head, recorded at
        /// lowering so the runtime walk resolves same-name extensions against
        /// the STATIC type, as kotlinc does — even when the executing frame is
        /// a synthesized closure (a suspend body) whose own kind carries no
        /// receiver.
        static_recv: ?ConstId = null,
        /// Explicit call-site type arguments (`arrayOf<ULong>(...)`),
        /// preserved through the deferred form so the global leg can
        /// type its dispatch (unsigned literal coercion, reified serving).
        type_args: []ConstId = &.{},
        /// Site memo for the member-probe skip: the receiver class identity
        /// (and argument signature) for which a previous execution of THIS
        /// instruction found no member or extension and settled on the global
        /// leg. A match skips the implicit-receiver walk. Single-fill under
        /// the same benign-race convention as `CallMember`'s site route; the
        /// host keeps an equivalent hash-keyed memo, which this shortcut
        /// answers ahead of, without a borrow or a hash.
        skip_cls: u64 = 0,
        skip_sig: u64 = 0,
        /// The global-leg target a previous execution of this instruction
        /// resolved for `skip_cls`/`skip_sig`, stored as `FuncId + 1` (0 =
        /// unclaimed). Claimed only for a plain positional call the overload
        /// terminal answered with a fused activation and nothing else — no
        /// constructor, no type arguments, no scoped rebinding, no receiver
        /// prepended — so replaying it reproduces that dispatch exactly while
        /// skipping the ranking.
        global_fid: u32 = 0,
    },
    /// Write a global / top-level binding. Mirrors `LoadGlobal` for
    /// the write side: routed through `Host.store_global` so a
    /// delegated top-level property's setter (or a plain top-level
    /// `var`) gets updated.
    StoreGlobal: struct { name: ConstId, value: Reg },
    /// Register a class declaration encountered inside a function
    /// body. Local classes live for the duration of the call.
    RegisterClass: struct {
        class: FF(ast.Class),
        /// Capture-name slots so the class methods see the enclosing
        /// function's locals.
        captured_names: [][]const u8,
        captures: []Reg,
        /// When set, receives the registered class as a `.Class` value so
        /// the declaration name can bind to it. A subsequent `C(args)` in
        /// scope then constructs the local class rather than resolving a
        /// same-named top-level function (Kotlin: a local class shadows it).
        dst: ?Reg = null,
    },
    /// Build an anonymous-object instance from an `object { … }` /
    /// `object : Parent(args) { … }` AST node. The host synthesises a
    /// fresh `ClassDef` from the AST, populates its captured env from
    /// the snapshotted `captures`, runs its init pipeline, and returns
    /// the `Value.Instance`.
    BuildObject: struct {
        dst: Reg,
        ast: FF(ast.Expr),
        captured_names: [][]const u8,
        captures: []Reg,
        /// Scope-true type renames visible at the object expression's
        /// lexical site (mangled private nested classes along the
        /// enclosing-class chain, renamed file-private types of the
        /// declaring file), flattened at lowering time. Anon-object
        /// member bodies lower at runtime into a fresh side module
        /// with none of the build's scope registries, so the lexical
        /// renames ride on the instruction.
        scope_renames: []const ScopeRename = &.{},
        /// Exact classifier identities referenced by the object subtree.
        scope_classes: []const ScopeClassRef = &.{},
    },
    /// Materialise a lambda value capturing the current scope's
    /// registers. The captures are listed as a `[]Reg`; the
    /// evaluator snapshots the live values into a closure env.
    /// `body_func` is the lambda body lowered as a separate Func.
    Lambda: struct {
        dst: Reg,
        body_func: FuncId,
        captures: []Reg,
    },
    /// Materialise a closure from a stashed AST `Block` plus a
    /// snapshot of captured registers indexed by name. The body is
    /// lowered as a separate Func referenced by `body_func`; the VM
    /// builds an `IrClosure` over the captured values.
    AstLambda: struct {
        dst: Reg,
        params: [][]const u8,
        body_ast: ast.Block,
        captures: []Reg,
        captured_names: [][]const u8,
        /// `true` for anonymous function expressions (`fun(x): T = …`)
        /// where `return` is a local return out of the fn rather
        /// than a non-local one. `false` for ordinary `{ x -> … }`
        /// lambdas — the enclosing function is the return target.
        absorb_return: bool = false,
        /// `FuncId` of the IR-lowered body. The lambda lowering also
        /// emits an IR Func for the body in parallel with the AST
        /// snapshot; call sites that recognise IR-lowered lambdas
        /// can dispatch through this `FuncId` without going through
        /// the tree walker. `null` for legacy emissions that
        /// haven't been migrated.
        body_func: ?FuncId = null,
    },
};

pub const SpreadPart = struct {
    reg: Reg,
    is_spread: bool,

    pub fn eql(self: SpreadPart, other: SpreadPart) bool {
        return self.reg == other.reg and self.is_spread == other.is_spread;
    }
};

pub const BinOp = enum {
    Add,
    Sub,
    Mul,
    Div,
    Mod,
    Pow,
    Eq,
    NotEq,
    Less,
    LessEq,
    Greater,
    GreaterEq,
    /// Equality on a value that came through an `as Any` cast or
    /// a statically-Any-typed path. Uses bitwise comparison for
    /// `Double` / `Float` so NaN == NaN and +0.0 != -0.0.
    BoxedEq,
    BoxedNotEq,
    /// Referential identity (`===` / `!==`). Compares heap values by
    /// backing-cell pointer and never dispatches a user `equals`.
    IdentEq,
    IdentNeq,
    And,
    Or,
    Xor,
    Shl,
    Shr,
    UShr,
    RangeTo,
    RangeUntil,
    DownTo,
    Elvis,
    StringConcat,
};

pub const UnOp = enum {
    Neg,
    Plus,
    Inc,
    Dec,
};

/// Terminator at the end of every block.
/// Visit every REGISTER operand of one instruction, generically over the
/// `Inst` union: plain `Reg` fields, `?Reg`, `[]Reg`, `SpreadPart`
/// slices, and the `args`+`n_args` contiguous-run convention (each
/// register of the run is reported). A field named `dst` reports
/// `is_def = true`. Comptime-generated from the union's own shape, so a
/// new instruction variant is covered by construction — the foundation
/// the Move-fusion pass (and any future register analysis) builds on.
pub fn visitInstRegs(inst: *const Inst, ctx: anytype, comptime cb: fn (@TypeOf(ctx), Reg, bool) void) void {
    switch (inst.*) {
        inline else => |*payload| visitPayloadRegs(payload, ctx, cb),
    }
}

/// Same enumeration for a block terminator.
pub fn visitTerminatorRegs(t: *const Terminator, ctx: anytype, comptime cb: fn (@TypeOf(ctx), Reg, bool) void) void {
    switch (t.*) {
        inline else => |*payload| visitPayloadRegs(payload, ctx, cb),
    }
}

pub fn visitPayloadRegs(payload: anytype, ctx: anytype, comptime cb: fn (@TypeOf(ctx), Reg, bool) void) void {
    const P = @TypeOf(payload.*);
    if (P == Reg) {
        cb(ctx, payload.*, false);
        return;
    }
    if (P == ?Reg) {
        if (payload.*) |r| cb(ctx, r, false);
        return;
    }
    switch (@typeInfo(P)) {
        .@"struct" => |st| {
            inline for (st.fields) |f| {
                const is_def = comptime std.mem.eql(u8, f.name, "dst");
                if (f.type == Reg) {
                    if (comptime std.mem.eql(u8, f.name, "args")) {
                        if (comptime @hasField(P, "n_args")) {
                            var k: u32 = 0;
                            while (k < payload.n_args) : (k += 1) {
                                cb(ctx, Reg.from(@field(payload, f.name).int() + k), false);
                            }
                            continue;
                        }
                    }
                    // `CtxScope`'s context-value run pairs `ctx_args` with
                    // `n_ctx` (`CtxCall`'s single `args` run already spans
                    // its context prefix via `n_args`). Without the
                    // expansion, register analyses missed every context
                    // value past the run base.
                    if (comptime std.mem.eql(u8, f.name, "ctx_args")) {
                        if (comptime @hasField(P, "n_ctx")) {
                            var k: u32 = 0;
                            while (k < payload.n_ctx) : (k += 1) {
                                cb(ctx, Reg.from(@field(payload, f.name).int() + k), false);
                            }
                            continue;
                        }
                    }
                    cb(ctx, @field(payload, f.name), is_def);
                } else if (f.type == ?Reg) {
                    if (@field(payload, f.name)) |r| cb(ctx, r, is_def);
                } else if (f.type == []Reg or f.type == []const Reg) {
                    for (@field(payload, f.name)) |r| cb(ctx, r, false);
                } else if (f.type == []SpreadPart or f.type == []const SpreadPart) {
                    for (@field(payload, f.name)) |part| cb(ctx, part.reg, false);
                }
            }
        },
        else => {},
    }
}

/// Rewrite an instruction's `dst` register (every variant that has one).
/// Returns false when the variant carries no `dst`.
pub fn setInstDst(inst: *Inst, new_dst: Reg) bool {
    switch (inst.*) {
        inline else => |*payload| {
            const P = @TypeOf(payload.*);
            if (@typeInfo(P) == .@"struct" and @hasField(P, "dst")) {
                if (@FieldType(P, "dst") == Reg) {
                    payload.dst = new_dst;
                    return true;
                }
            }
            return false;
        },
    }
}

pub const Terminator = union(enum) {
    Goto: BlockId,
    Branch: struct {
        cond: Reg,
        t: BlockId,
        f: BlockId,
    },
    Switch: struct {
        reg: Reg,
        arms: []SwitchArm,
        default: BlockId,
    },
    Return: ?Reg,
    Throw: Reg,
    Unreachable,
    /// Tail-recursive jump to the current function's entry with
    /// new param values. The evaluator rebinds the param regs
    /// from this contiguous register run and restarts execution
    /// without pushing a new call frame.
    TailJump: struct {
        args: Reg,
        n_args: u32,
    },
    /// Cross-function tail call: replace the current frame's function
    /// with `func`, rebind its params from the contiguous register run
    /// at `args`, and restart the new entry block.
    TailCallFunc: struct {
        func: FuncId,
        args: Reg,
        n_args: u32,
    },
    /// Non-local return — propagates an `EvalError.NonLocalReturn`
    /// up through enclosing lambda frames until a non-lambda fn
    /// catches it and converts it into a normal return value.
    NonLocalReturn: ?Reg,
    /// `return@label` — return the value from the function whose
    /// name matches `label`. Propagates as `EvalError.LabeledReturn`
    /// through enclosing frames until the labeled frame catches it.
    LabeledReturn: struct { label: []const u8, value: ?Reg },
};

/// One arm of a `Terminator.Switch`: a constant key paired with the
/// block to jump to when the switched register matches.
pub const SwitchArm = struct {
    key: ConstId,
    target: BlockId,
};

/// Catch handler frame attached to a try-body block. When a Throw
/// fires inside the body, the evaluator pops handlers in stack
/// order and jumps to the first whose `type_name` matches the
/// thrown value's nominal type. `exception_reg` is the register
/// the handler body reads the bound exception value from.
pub const CatchHandler = struct {
    type_name: []const u8,
    handler: BlockId,
    exception_reg: Reg,
};

/// Runtime absorption point for a labeled return that targets an inline
/// function SPLICED into the enclosing function. A `return@name` written in
/// a closure that crosses a real frame (a lambda handed to a non-spliced
/// inline call inside the spliced body) unwinds as a `LabeledReturn` error;
/// the frame that ran the splice catches it here and control resumes at
/// `handler` (the splice join) with the value in `value_reg` — exactly the
/// early-exit the label means. Disarmed by `catch_done_for` on the join.
pub const LrAbsorb = struct {
    label: []const u8,
    handler: BlockId,
    value_reg: Reg,
};
