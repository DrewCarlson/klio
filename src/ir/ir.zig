//! `ir` — compact linear IR for the klio interpreter.
//!
//! Replaces the tree-walking interpreter with a flat instruction
//! stream. Each `Func` carries a `[]Block`; each `Block` carries a
//! `[]Inst` plus a `Terminator`. Operands are `Reg` indices, not
//! stack slots. The IR reuses `runtime.Value` so migration can
//! happen function-by-function without forking the runtime
//! representation.

const std = @import("std");
const span = @import("span");
const ast = @import("ast");
const runtime = @import("runtime");
const applicability = @import("applicability");
const FF = runtime.forest.ForestField;

const Allocator = std.mem.Allocator;

pub const Span = span.Span;
pub const FileId = span.FileId;

/// AST → IR lowering, IR builders, and the IR evaluator. Filled in
/// alongside the type definitions in this file.
pub const build = @import("build.zig");
pub const eval = @import("eval.zig");
pub const lower = @import("lower.zig");
pub const jit_loop = @import("jit_loop.zig");
pub const disasm = @import("disasm.zig");

/// Type reference inside the IR. Today this is a textual FQN/name
/// — the evaluator resolves against the class table at runtime.
pub const TypeRef = struct {
    name: []const u8,
    nullable: bool,
    args: []TypeRef,

    pub fn eql(self: TypeRef, other: TypeRef) bool {
        if (!std.mem.eql(u8, self.name, other.name)) return false;
        if (self.nullable != other.nullable) return false;
        if (self.args.len != other.args.len) return false;
        for (self.args, other.args) |a, b| {
            if (!a.eql(b)) return false;
        }
        return true;
    }

    pub fn clone(self: TypeRef, allocator: Allocator) Allocator.Error!TypeRef {
        const args = try allocator.alloc(TypeRef, self.args.len);
        for (self.args, args) |src, *dst| dst.* = try src.clone(allocator);
        return .{
            .name = try allocator.dupe(u8, self.name),
            .nullable = self.nullable,
            .args = args,
        };
    }

    pub fn deinit(self: *TypeRef, allocator: Allocator) void {
        allocator.free(self.name);
        for (self.args) |*a| a.deinit(allocator);
        allocator.free(self.args);
    }
};

/// Identifier for a virtual register inside one function body.
pub const Reg = enum(u32) {
    _,
    pub fn from(v: u32) Reg {
        return @enumFromInt(v);
    }
    pub fn int(self: Reg) u32 {
        return @intFromEnum(self);
    }
};

/// Identifier for a basic block inside one function body.
pub const BlockId = enum(u32) {
    _,
    pub fn from(v: u32) BlockId {
        return @enumFromInt(v);
    }
    pub fn int(self: BlockId) u32 {
        return @intFromEnum(self);
    }
};

/// Identifier for a function inside the IR module.
pub const FuncId = enum(u32) {
    _,
    pub fn from(v: u32) FuncId {
        return @enumFromInt(v);
    }
    pub fn int(self: FuncId) u32 {
        return @intFromEnum(self);
    }
};

/// Stable identity of one virtual override family. A slot is rooted at the
/// declaration selected against the call site's static receiver type; the
/// link step maps `(runtime ClassId, MethodSlotId)` to the concrete `FuncId`.
/// Keeping this distinct from `FuncId` makes the bytecode contract explicit
/// even though the initial stable numbering reuses the root declaration id.
pub const MethodSlotId = enum(u32) {
    _,
    pub fn from(v: u32) MethodSlotId {
        return @enumFromInt(v);
    }
    pub fn fromFunc(id: FuncId) MethodSlotId {
        return @enumFromInt(id.int());
    }
    pub fn int(self: MethodSlotId) u32 {
        return @intFromEnum(self);
    }
};

/// Identifier for a class declared in the IR module.
pub const ClassId = enum(u32) {
    _,
    pub fn from(v: u32) ClassId {
        return @enumFromInt(v);
    }
    pub fn int(self: ClassId) u32 {
        return @intFromEnum(self);
    }
};

/// Constant pool index for literals too large to fit in a `u32`.
pub const ConstId = enum(u32) {
    _,
    pub fn from(v: u32) ConstId {
        return @enumFromInt(v);
    }
    pub fn int(self: ConstId) u32 {
        return @intFromEnum(self);
    }
};

/// One scope-true type rename carried by `Inst.BuildObject`: the simple
/// name a reference uses and the mangled lift name it resolves to in the
/// object expression's lexical scope.
pub const ScopeRename = struct { name: []const u8, renamed: []const u8 };

/// One classifier resolved at an anonymous-object expression's lexical site.
/// Runtime-lowered object members use its exact FQN instead of re-resolving a
/// bare name in their intentionally small side module.
pub const ScopeClassRef = struct {
    name: []const u8,
    fqn: []const u8,
    has_companion: bool,
};

/// One IR instruction. Drives the per-frame evaluator switch.
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
    /// dispatch the member with `args`; otherwise invoke `fallback`
    /// with `recv` prepended.
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
    },
    /// Virtual member call whose overload was resolved statically. `slot`
    /// names the selected declaration's override family; runtime work is one
    /// `(receiver ClassId, slot) -> FuncId` lookup, never a method-name search.
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
    },
    /// Instantiate a class.
    NewInstance: struct {
        dst: Reg,
        class: ClassId,
        args: Reg,
        n_args: u32,
        arg_names: []?ConstId = &.{},
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
    /// Marker for the evaluator's debugger / tracing hook.
    Trace: struct { span: Span },
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
    },
    /// Symmetric write counterpart of `LoadFromThisOrGlobal`: the
    /// innermost implicit receiver with a member named `name` takes the
    /// write (`SetField`); when no receiver owns it, fall back to
    /// `StoreGlobal(name)`.
    StoreToThisOrGlobal: struct {
        this_idx: u16,
        name: ConstId,
        value: Reg,
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

fn visitPayloadRegs(payload: anytype, ctx: anytype, comptime cb: fn (@TypeOf(ctx), Reg, bool) void) void {
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

/// A basic block: linear instruction stream + terminator. When
/// `catches` is non-empty, a `Throw` reaching this block (or any
/// block reached from it without first leaving the try scope)
/// looks up a matching handler before propagating.
pub const Block = struct {
    id: BlockId,
    insts: []Inst,
    terminator: Terminator,
    catches: []CatchHandler = &.{},
    /// Finally-block id to execute on every exit from this block's
    /// try-region (normal fall-through, catches, returns, throws).
    /// Paired with `finally_done` (the synthesized exit sentinel)
    /// so the eval can tell "I'm jumping into finally" apart from
    /// "I've finished finally."
    finally: ?BlockId = null,
    /// The post-finally sentinel for this try-region — control
    /// reaches it only after the user finally body has run to
    /// completion.
    finally_done: ?BlockId = null,
    /// When this block IS the post-finally sentinel for some
    /// try-region, this carries the `BlockId` of that region's body
    /// entry — the matching key for the `TryFrame.body` the eval
    /// popped.
    finally_done_for: ?BlockId = null,
    /// When this block is the JOIN of a catch-only try (no finally),
    /// this carries the try body's entry block. Normal flow arriving
    /// here pops that body's `TryFrame` — without the marker a
    /// catch-only entry only left the stack via a throw, so a loop
    /// body's `try { } catch { }` grew the stack by one per iteration
    /// (and every Goto's finally scan walked it: quadratic in
    /// iterations for a long-lived frame like DeepRecursive's
    /// runCallLoop).
    catch_done_for: ?BlockId = null,
    /// Try-region body-entry ids whose `TryFrame` this block pops when it
    /// exits via `Goto`. Set on the block that carries an inline `return`'s
    /// jump-to-join: the return replays its enclosing finallys inline and
    /// jumps straight to the inline join, bypassing the finally sentinel
    /// that would otherwise pop those frames — so without this the frames
    /// linger and a LATER plain return in the same runtime frame re-runs
    /// the finally (a spliced `try { return … } finally { … }` applied its
    /// snapshot twice).
    pop_on_exit: []const BlockId = &.{},
};

/// A function body in IR form.
/// First-class classification of a lowered function, used by the
/// runtime extension scorer to recognize a member-extension directly
/// instead of probing the `member_ext_owner_class` side table. A
/// *member extension* (`class C { fun R.f(p) { … } }`) lowers to a func
/// with a leading `"this"` param exactly like an `instance_method` and a
/// `top_level_extension`, so `param[0] == "this"` alone cannot tell them
/// apart — this kind makes the distinction authoritative. The owner-class
/// gate that decides member-extension *visibility* stays in
/// `ModuleRegistry.member_ext_owner_class` (keyed by `FuncId`); the kind
/// is the additive predicate that selects which funcs are gated.
pub const FuncKind = enum {
    /// Ordinary top-level / local function, or a constructor/init thunk.
    plain,
    /// Instance method `class C { fun f(p) { … } }` (leading `"this"`).
    instance_method,
    /// Top-level extension `fun R.f(p) { … }` (leading `"this"`).
    top_level_extension,
    /// Member extension `class C { fun R.f(p) { … } }` (leading `"this"`),
    /// gated by its declaring class through `member_ext_owner_class`.
    member_extension,
};

pub const Func = struct {
    id: FuncId,
    name: []const u8,
    fqn: []const u8,
    /// Declaring package path (`"foo.bar"`), the empty string for a
    /// user script with no package header. Uniform on every func — the
    /// symbol index keys bare-call preference on the caller's package,
    /// and `""` is the ordinary "no package" case, not a separate code
    /// path.
    package: []const u8 = "",
    params: []Param,
    return_ty: TypeRef,
    n_locals: u32,
    blocks: []Block,
    /// Lazy IR: `offset + 1` of this function's `blocks` in its module's
    /// `deferred_func_section` when they are deferred (so `blocks` is empty
    /// until the first execution decodes them), `0` when present. A function
    /// "has a body" iff `blocks.len != 0 OR deferred_offset != 0` — see
    /// `hasBody`, which every "is this bodyless?" check must consult so a
    /// deferred function is never mistaken for a native / abstract stub.
    deferred_offset: u32 = 0,
    entry: BlockId,
    is_suspend: bool,
    /// First-class func classification for the extension scorer. Defaults
    /// to `plain`; set to `member_extension` at the member-extension
    /// lowering site, distinguishing it from a same-shaped instance method
    /// or top-level extension.
    kind: FuncKind = .plain,
    is_tailrec: bool = false,
    /// Monomorphic call fast-path plan, cached on first call (the evaluator
    /// fills it via the host). `0` = not yet computed, `1` = ineligible (use the
    /// full dispatch), `>= 2` = eligible with `fast_call - 2` parameters: a plain
    /// top-level user function a positional, exact-arity call dispatches straight
    /// to its body. See `eval`'s `.Call` fast path.
    fast_call: u16 = 0,
    /// Index of `"this"` in `capture_order`, cached on first use by
    /// `callerThisValue` (hot: every GetField in a lambda frame consults
    /// it). `-2` = not yet computed, `-1` = no `this` capture.
    this_cap_idx: i32 = -2,
    /// True when `params[0]` is a *synthesized* `this` receiver — an
    /// instance method's / extension's / local-extension's dispatch
    /// receiver, a constructor's or init thunk's instance under
    /// construction, or any other frame the lowerer injects a leading
    /// `this` for. It distinguishes a genuine receiver from a user
    /// parameter that merely spells its name `this` (`fun f(\`this\`: T)`),
    /// which is not a dispatch receiver. Set wherever the implicit leading
    /// `this` param is bound.
    has_receiver_param: bool = false,
    /// True for synthetic lambda bodies. `return` inside the body
    /// propagates as a non-local return through this frame instead
    /// of being caught locally.
    is_lambda: bool = false,
    /// Declared receiver head of a receiver-lambda body. Unlike a local
    /// extension function this receiver is supplied at invocation rather
    /// than occupying a parameter slot; the VM uses the head to select the
    /// compatible receiver from the implicit-receiver tower.
    lambda_receiver_ty: ?[]const u8 = null,
    /// True for `inline fun`. A non-local `return` from a lambda
    /// passed to an inline function unwinds *through* this frame
    /// (back to the function that wrote the lambda) rather than
    /// being caught here.
    is_inline: bool = false,
    /// Capture-name list in `LoadCapture` index order. Non-empty for
    /// anon-object method bodies that close over outer names — the
    /// dispatch site materialises the capture-value vector in this
    /// order so `Inst.LoadCapture` reads the right snapshot per
    /// instance.
    capture_order: [][]const u8 = &.{},
    /// For a lambda body, the simple name of the function the lambda
    /// literal was passed to (`with`, `apply`, a user HOF). This is the
    /// lambda's implicit label, so `this@with` inside the body resolves
    /// to the receiver this lambda was invoked with. `null` for ordinary
    /// functions and for lambdas not in argument position.
    implicit_label: ?[]const u8 = null,
    /// Marked `@kotlin.internal.LowPriorityInOverloadResolution` or
    /// `@Deprecated(level = DeprecationLevel.ERROR)`. Such a function is
    /// only a valid overload-resolution target when no ordinary candidate
    /// applies. Overload selection skips it while any normal sibling
    /// fits.
    low_priority: bool = false,
    /// An `expect` declaration. Its `actual` may live outside the pack's source
    /// set, in which case NOTHING serves the call — and a bodyless declaration
    /// that nothing serves used to return `Unit` silently, which is the single
    /// most confusing failure klio can produce (the call runs nothing and the
    /// program limps on with a wrong value). Knowing the declaration is an
    /// `expect` lets the runtime say so, and say what to run to list the rest.
    is_expect: bool = false,
    /// Carries the source `override` modifier. Dispatch of a call resolved
    /// against a STATIC receiver type (an implicit-`this` / inline-spliced
    /// own-member call) must exclude a runtime subtype's same-name overload
    /// that is NOT an override — it is out of the static type's member scope.
    is_override: bool = false,
    /// Carries the source `open` modifier. A method that is neither `open` nor
    /// `override` (an `override` is open-by-default) cannot be overridden, so a
    /// `recv.name()` call resolving to it is monomorphic even when the receiver
    /// CLASS is `open` — the static dispatch bake reads this. Serialized with the
    /// func header (like every field), so the bake trusts it on an image-decoded
    /// base method as well as a freshly-lowered one.
    is_open: bool = false,
    /// Carries the source `final` modifier. Meaningful on an `override` member:
    /// `final override fun` seals the method against any further override, so it
    /// is monomorphic despite `is_override`. Redundant (but honored) on a plain
    /// member. The static dispatch bake reads this alongside `is_open`.
    is_final: bool = false,
    /// Resolved fully-qualified candidate names for each source-level
    /// annotation on this function (e.g. `kotlin.test.Test`), so a test
    /// runner can discover `@Test`/`@Ignore`/etc. without re-parsing.
    /// Populated by the in-memory build path; empty for the baked image.
    annotation_names: []const []const u8 = &.{},

    /// True when this function has an IR body — present blocks, or blocks
    /// deferred to the image's lazy-IR section. Distinguishes a real function
    /// (whose body may be lazily decoded) from a native / abstract / `expect`
    /// stub (no blocks, not deferred). Every "is this bodyless?" check uses
    /// this, never a bare `blocks.len`, so deferral stays invisible to dispatch.
    pub fn hasBody(self: *const Func) bool {
        return self.blocks.len != 0 or self.deferred_offset != 0;
    }
};

pub const Param = struct {
    name: []const u8,
    ty: TypeRef,
    default: ?BlockId,
    /// True when the primary-ctor param doubles as a class property
    /// (`val name` / `var name` prefix on the param). The Vm uses
    /// this flag to decide which primary args become instance
    /// fields.
    is_property: bool = false,
    /// `vararg` parameter — variadic, runtime-collected into an
    /// array. The Vm packs trailing positional args into a typed
    /// array before binding.
    is_vararg: bool = false,
    /// True when the parameter declares a default value. The lowered
    /// default expression lives in a separate thunk (so `default` above
    /// stays `null`), but the flag is needed at lower time to decide
    /// whether a same-named factory function is applicable to a given
    /// argument count.
    has_default: bool = false,
};

/// Class declaration.
pub const Class = struct {
    id: ClassId,
    name: []const u8,
    fqn: []const u8,
    /// Declaring package path (`"foo.bar"`), the empty string for a
    /// user script with no package header. Uniform on every class.
    package: []const u8 = "",
    primary_params: []Param,
    methods: []FuncId,
    init_block: ?FuncId,
    companion: ?ClassId,
    supertypes: []ClassId,
    /// Declared class type parameters, in source order. Virtual-slot linking
    /// uses declaration position rather than a simple-name lookup when it
    /// substitutes an inherited generic member signature.
    type_params: []const []const u8 = &.{},
    /// Declared supertype references parallel to `supertypes`, retaining their
    /// type arguments. The resolved `ClassId` supplies nominal identity; this
    /// structural half supplies the substitution along each inheritance edge.
    supertype_refs: []TypeRef = &.{},
    /// `inner class` — instances capture an enclosing-class instance.
    /// Construction-site lowering consults this so a lambda building a
    /// bare `Inner()` captures the enclosing `this` it depends on.
    is_inner: bool = false,
    /// `abstract class` / `interface` / `sealed class` — cannot be
    /// constructed directly. A bare `Name(args)` call against such a class
    /// is therefore never construction; it must resolve to a same-named
    /// factory function, so bare-call lowering must not treat it as a ctor.
    is_abstract: bool = false,
    /// `interface` specifically: its member set is exactly its declared
    /// (+ inherited) AST members, so a static-receiver walk can trust the
    /// registry's transitive method-name set for visibility decisions.
    is_interface: bool = false,
    /// A Kotlin `fun interface`. Its classifier call with one callable
    /// argument is a statically known SAM conversion, not a constructor or
    /// same-simple-name global lookup.
    is_fun_interface: bool = false,
    /// `open` modifier — the class can be subclassed. A class that is neither
    /// `open` nor `is_abstract` (which folds in `abstract`/`interface`/`sealed`)
    /// is FINAL: it can never be subclassed, so its members cannot be overridden
    /// anywhere, and a `recv.method()` call on it is monomorphic even open-world
    /// (used by the static dispatch bake).
    is_open: bool = false,
    /// A named Kotlin `object`. Calling its classifier name resolves the
    /// singleton value and dispatches `operator fun invoke`; it is never a
    /// constructor call despite sharing the class table representation.
    is_object: bool = false,
    /// A Kotlin value class. Its receiver uses a specialized runtime
    /// representation, so ordinary instance-call ABI assumptions do not apply.
    is_value: bool = false,
    /// True only for an as-yet-unfilled `reserveClass` placeholder. A real
    /// class is registered with `methods`/`supertypes`/`init_block` not yet
    /// backpatched, so it is structurally indistinguishable from a stub;
    /// this flag lets `addClass` tell a reserved slot (which the real
    /// declaration overwrites in place) from a genuine same-simple-name
    /// twin in another package (which must keep its own id).
    is_stub: bool = false,
};

/// `class_index` / `func_index` entry: simple name → id.
pub const ClassIndexEntry = struct { name: []const u8, id: ClassId };
pub const FuncIndexEntry = struct { name: []const u8, id: FuncId };

/// `(String, String)` pair key used by several `ModuleRegistry`
/// tables. Hashed/compared structurally.
pub const StrPair = struct {
    a: []const u8,
    b: []const u8,
};

const StrPairContext = struct {
    pub fn hash(_: StrPairContext, key: StrPair) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(key.a);
        h.update(&.{0});
        h.update(key.b);
        return h.final();
    }
    pub fn eql(_: StrPairContext, x: StrPair, y: StrPair) bool {
        return std.mem.eql(u8, x.a, y.a) and std.mem.eql(u8, x.b, y.b);
    }
};

fn StrPairMap(comptime V: type) type {
    return std.HashMap(StrPair, V, StrPairContext, std.hash_map.default_max_load_percentage);
}
const StrPairSet = StrPairMap(void);

const FuncIdMap = std.AutoHashMap;

/// Top-level container.
/// The eager pipeline's hand-off: the driver computes the per-call
/// resolution BEFORE the module exists (lowering starts inside the build),
/// parks it here, and the next module created on this thread adopts it.
pub threadlocal var pending_eager_calls: ?std.AutoHashMap(span.Span, span.Span) = null;
pub threadlocal var pending_file_packages: ?std.AutoHashMap(FileId, []const u8) = null;
/// Companion channel: per-expression static TYPE HEADS from typeck
/// (`Span(expr) -> {head, nullable}`), the declared-type evidence the
/// applicability engine otherwise reconstructs from AST string probes.
pub threadlocal var pending_eager_types: ?std.AutoHashMap(span.Span, EagerTypeHead) = null;

pub const EagerTypeHead = struct { name: []const u8, nullable: bool };
/// Receiver-lambda channel: body-block span -> receiver class head.
pub threadlocal var pending_eager_recv_heads: ?std.AutoHashMap(span.Span, []const u8) = null;
/// Fn-typed lambda-param shapes: param ident span -> {has_receiver, arity}.
pub threadlocal var pending_eager_param_shapes: ?std.AutoHashMap(span.Span, EagerParamShape) = null;

pub const EagerParamShape = struct { has_receiver: bool, arity: u16 };

fn headAllUpper(s_: []const u8) bool {
    for (s_) |c| {
        if (!std.ascii.isUpper(c)) return false;
    }
    return true;
}

/// A local contextual function's context parameters, threaded from
/// declaration lowering into the shared lambda-body lowering.
pub const PendingCtx = struct {
    params: []const ast.ContextParam,
    type_params: []const ast.TypeParam,
};

/// A local `fun`'s identity carried into its body's builder (and nested
/// lambdas): the declared name plus the mangled overload-cell binding a bare
/// self-reference must call through.
pub const SelfLocalFn = struct {
    name: []const u8,
    mangled: []const u8,
};

pub const PendingLocalDeclTypes = struct {
    types: std.StringHashMap([]const u8),
    nullable: std.StringHashMap(void),
    call_returns: std.StringHashMap(EagerTypeHead),
};

pub const Module = struct {
    funcs: std.ArrayList(Func) = .empty,
    /// True when any declaration in this module has a `context(...)`
    /// parameter clause. Gates the per-frame receiver push that feeds the
    /// context-resolution stack, so non-context programs pay nothing.
    has_context_decls: bool = false,
    /// Lowering-only scratch: a local contextual function's context
    /// parameters, stashed just before its body lowers through the shared
    /// lambda-body path and consumed there to emit the context-load
    /// prologue. Not serialized.
    pending_ctx: ?PendingCtx = null,
    /// Lowering-only scratch: the implicit label of the argument lambda whose
    /// body is about to lower (`runTest { … }` → "runTest"). The body binds
    /// `this@<label>` to its receiver so a reference from a nested scope — an
    /// anonymous object's accessor, a further lambda — reaches THAT receiver
    /// instead of the innermost `this`. Not serialized.
    pending_lambda_this_label: ?[]const u8 = null,
    /// The receiver type in scope at the site of the lambda body about to
    /// lower, carried into that body's builder as `enclosing_recv_ty` so a
    /// bare call inside a nested `() -> R` block can still disambiguate a
    /// receiver-lambda argument's arity by the enclosing receiver. Not
    /// serialized.
    pending_lambda_enclosing_recv: ?[]const u8 = null,
    /// The DECLARED extension receiver of the local function whose body is
    /// about to lower (`fun MockViewValidator.value() { … }` inside another
    /// body), carried into that body's builder as its own `recv_ty` so bare
    /// calls resolve exactly as in a top-level extension body — an extension
    /// on the receiver outranks a same-named plain top-level function. Not
    /// serialized.
    pending_lambda_own_recv: ?[]const u8 = null,
    /// The body about to lower belongs to a LOCAL `fun` with a BLOCK body:
    /// its fall-through returns Unit, never the tail statement's value —
    /// `fun f() { 42 }` yields Unit in Kotlin, while a lambda literal yields
    /// its last expression. Same rule `lowerFunctionBodyWithImplicitOwner-
    /// Enclosing` applies to top-level/member block bodies; without it a
    /// restart-wrapped local composable returned its trailing
    /// `endRestartGroup()?.updateScope(..)` null and Compose's
    /// `block?.invoke(c, 1) ?: error("Invalid restart scope")` elvis fired.
    /// Not serialized.
    pending_lambda_fn_block_body: bool = false,
    /// Non-reified type-parameter names in scope at the lambda body about to
    /// lower, carried into that body so an `x as T` cast inside the lambda is
    /// still erased (`forEachScopeOf(v) { scope -> scope as Scope }` inside a
    /// generic class). Not serialized.
    pending_lambda_type_params: ?[]const []const u8 = null,
    /// The LOCAL `fun` whose body (or a lambda nested in it) is about to
    /// lower: its declared name and its mangled overload-cell binding. A bare
    /// self-reference in that body must call through the mangled cell — the
    /// plain-name slot is shared with any later same-named sibling declaration
    /// (last bind wins), so a self re-invoke captured by name (the compose
    /// restart lambda) would run the SIBLING. Not serialized.
    pending_lambda_self_fn: ?SelfLocalFn = null,
    /// Names of enclosing-scope locals with definite NON-callable evidence
    /// (literal init / primitive declared type), carried into the lambda body
    /// about to lower so a bare CALL there does not route through the captured
    /// value (`var key = 0` beside the `key(...) {}` composable). Owned by the
    /// receiving builder once consumed. Not serialized.
    pending_lambda_nonfn_locals: ?std.StringHashMap(void) = null,
    /// Declared type heads of enclosing locals captured by the lambda body
    /// about to lower. The runtime capture carries the value; this parallel
    /// lowering-only carrier preserves the compile-time type Kotlin inferred
    /// for explicit-receiver resolution inside the closure.
    pending_lambda_local_decl_types: ?PendingLocalDeclTypes = null,
    /// Lazy IR: byte section holding deferred functions' `blocks`, each encoded
    /// self-contained, decoded on first execution. Borrows the image buffer;
    /// empty unless this module was loaded from an image.
    deferred_func_section: []const u8 = &.{},
    /// Process-lifetime allocator a decoded `blocks` slice must persist in.
    deferred_func_arena: Allocator = undefined,
    /// Injected decoder (`image.decodeFuncBlocks`), null until installed.
    deferred_func_decode: ?*const fn (Allocator, []const u8, u32) ?[]Block = null,
    /// Lazy IR func HEADERS: per-func self-contained sections + offsets
    /// (`id -> offset+1`, 0 = absent), decoded on first `funcById`. `func_cache`
    /// memoises the decoded `*Func`. All empty/eager unless loaded from an image;
    /// then `funcs.items` is empty and lookups go through the lazy path.
    func_header_section: []const u8 = &.{},
    func_header_offsets: []const u32 = &.{},
    func_header_decode: ?*const fn (Allocator, []const u8, u32) ?Func = null,
    func_cache: []?*Func = &.{},
    func_header_lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// First fqn segment of every lazy base func (distinct) — the lazy-friendly
    /// `packageHeadDeclared` source. Borrowed from the image; empty when eager.
    func_fqn_heads: []const []const u8 = &.{},
    /// Ids of the lazy base's bodyless funcs — the lazy-friendly replacement for
    /// the link-phase scan over all funcs. Borrowed from the image; empty eager.
    bodyless_func_ids: []const u32 = &.{},
    classes: std.ArrayList(Class) = .empty,
    consts: std.ArrayList(Const) = .empty,
    /// Top-level (file-scope) function ids, in declaration order.
    top_level: std.ArrayList(FuncId) = .empty,
    /// Top-level class declarations by simple name → `ClassId`. The
    /// lowering pass populates this so `Foo(args)` Calls become
    /// `NewInstance` instructions when `Foo` resolves to a class.
    class_index: std.ArrayList(ClassIndexEntry) = .empty,
    /// Simple name → first `ClassId`, an O(1) overlay on `class_index`'s linear
    /// scan. Built once after the module is finalized (`buildClassIdMap`, at the
    /// link step) and read lock-free at run time; null until then (`classId`
    /// falls back to the scan, e.g. during lowering). First-entry-wins to match
    /// the scan's duplicate-name behavior.
    class_id_map: ?std.StringHashMap(ClassId) = null,
    /// FQN → `ClassId` overlay on `classIdByFqn`'s linear scan. A duplicated FQN
    /// maps to `class_id_ambiguous` so the lookup returns null (the scan's
    /// ambiguity guard). Built with `class_id_map`; null until then.
    class_fqn_map: ?std.StringHashMap(ClassId) = null,
    /// Allocator for the lowering-phase lookup caches below, stored at
    /// `init`. Null (e.g. a module assembled field-by-field from an image)
    /// disables the caches; every cached lookup then takes its linear scan.
    lookup_cache_gpa: ?Allocator = null,
    /// Lowering-phase package-head set: every dot-aligned FQN prefix of
    /// every declared func/class, plus `func_fqn_heads`. Topped up lazily
    /// by growth counter; `addClass`'s stub-claim (the one in-place FQN
    /// rewrite) adds the claimed FQN's prefixes. Prefixes are only ever
    /// added, so the set never goes stale-positive relative to the scan.
    pkg_head_cache: std.StringHashMapUnmanaged(void) = .empty,
    pkg_head_funcs_n: usize = 0,
    pkg_head_classes_n: usize = 0,
    pkg_head_heads_done: bool = false,
    pkg_head_cache_dead: bool = false,
    /// Lowering-phase simple name → same-name `ClassId`s in `class_index`
    /// order (the scan's first-wins/tier-tie order). Names in `class_index`
    /// are immutable, so growth-counter top-up alone keeps this exact.
    class_name_cache: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(ClassId)) = .empty,
    class_name_cache_n: usize = 0,
    /// Lowering-phase FQN → `ClassId` (or `class_id_ambiguous`). The
    /// stub-claim FQN rewrite patches this in place; an unpatchable case
    /// (a stub FQN that was already ambiguous) kills the cache for the
    /// rest of the build rather than risk divergence from the scan.
    class_fqn_cache: std.StringHashMapUnmanaged(ClassId) = .empty,
    class_fqn_cache_n: usize = 0,
    class_fqn_cache_dead: bool = false,
    /// `internConst` dedup: const hash → first `ConstId` with that hash.
    /// A hash collision falls back to the linear scan for that value.
    const_dedup: std.AutoHashMapUnmanaged(u64, ConstId) = .empty,
    const_dedup_n: usize = 0,
    /// The classifier NESTING TREE, derived once from FQNs: for each class,
    /// its lexical parent class (null for top-level) and, per parent, the
    /// children keyed by their last FQN segment. One id-keyed structure
    /// answers every scoped classifier lookup — no `$`/`.` string-mangled
    /// probing at use sites.
    class_parent: ?std.AutoHashMap(ClassId, ClassId) = null,
    /// The identity channel's lowering half: each lowered declaration's
    /// AST name-span maps to its FuncId. Composed with typeck's
    /// `Span(call) -> decl_span` record, this gives lowering an exact,
    /// type-derived target per call site with no shared symbol table.
    func_by_decl_span: ?std.AutoHashMap(span.Span, FuncId) = null,
    /// The eager pipeline's per-call resolution: `Span(callee) ->
    /// Span(decl)` converted from typeck's records by the driver
    /// (`KLIO_EAGER=1`). Lowering composes it with `func_by_decl_span`;
    /// absent spans keep the lazy path.
    eager_calls: ?std.AutoHashMap(span.Span, span.Span) = null,
    /// Typeck's per-expression type heads (the E2.1 evidence seam).
    eager_types: ?std.AutoHashMap(span.Span, EagerTypeHead) = null,
    eager_recv_heads: ?std.AutoHashMap(span.Span, []const u8) = null,
    /// Extension-candidate index: receiver head -> the extension NAMES
    /// declared on it, plus the generic-receiver names (`fun <T> T.also`)
    /// that apply to every head. Rebuilt lazily when the declaration index
    /// has grown. Answers the E4c membership question the hierarchy sets
    /// cannot: could ANY extension named N serve receiver head H?
    ext_names_by_recv_head: ?std.StringHashMap(std.StringHashMap(void)) = null,
    generic_ext_names: ?std.StringHashMap(void) = null,
    ext_index_decl_count: usize = 0,
    eager_param_shapes: ?std.AutoHashMap(span.Span, EagerParamShape) = null,
    class_children: ?std.AutoHashMap(ClassId, std.StringHashMap(ClassId)) = null,
    /// Top-level function declarations by simple name → `FuncId`.
    /// Lowering routes Path-callees that match a registered name
    /// to `Inst.Call { func }` instead of LoadGlobal+CallValue.
    func_index: std.ArrayList(FuncIndexEntry) = .empty,
    /// Parallel index of `func_index` keyed by simple name for O(1)
    /// `name → all matching FuncIds (in declaration order)` lookup.
    /// Rebuilt from `func_index` via `rebuildFuncNameIndex`.
    func_name_index: std.StringHashMap(std.ArrayList(FuncId)),
    /// Package path for FQN qualification.
    package: ?[]const u8 = null,
    /// Top-level function names declared `tailrec`. Populated by the
    /// driver before bodies are lowered so a tailrec caller's lower
    /// pass can emit `TailCallFunc` for a tail-position call into
    /// another tailrec function whose body hasn't been lowered yet.
    tailrec_fn_names: std.ArrayList([]const u8) = .empty,
    /// Module-scoped runtime metadata: per-class/per-function side
    /// tables that the IR build phase produces and the Vm consults
    /// at dispatch time.
    registry: ModuleRegistry,
    /// Declared user-parameter count (excluding an implicit extension
    /// `this`) per top-level `FuncId`, keyed by `FuncId.int()`.
    /// Lowering-only; not serialized into packs.
    decl_user_params: std.AutoHashMap(u32, u32),
    /// Per top-level `FuncId` (keyed by `FuncId.int()`): the declared
    /// user parameters' `(required, total, has_vararg)`.
    /// Lowering-only; not serialized.
    decl_user_arity: std.AutoHashMap(u32, DeclArity),
    /// Per top-level `FuncId` (keyed by `FuncId.int()`): the declared
    /// user parameters' full structural types — generic arguments and
    /// function-type shapes included — recorded at phase-1 header
    /// registration through the same lowering body params use. Lets the
    /// symbol index prove signature identity for forward references
    /// whose bodies (and thus lowered params) do not exist yet. Names
    /// and arg slices are owned by the module allocator. Lowering-only;
    /// not serialized.
    decl_user_sig: std.AutoHashMap(u32, []TypeRef),
    /// Per top-level `FuncId` (keyed by `FuncId.int()`): the function
    /// declaration's source span, recorded at phase-1 header
    /// registration so resolution diagnostics can point at the
    /// conflicting declarations. Lowering-only; not serialized.
    decl_span: std.AutoHashMap(u32, Span),
    /// Top-level `FuncId`s (keyed by `FuncId.int()`) whose declaration
    /// carries a source body, recorded at phase-1 header registration.
    /// Distinguishes a real function from a bodyless `expect` / header
    /// stub while phase 2 has not placed the bodies yet (the in-memory
    /// two-phase build a `klio test` module lowers user files against).
    /// Lowering-only; not serialized.
    decl_ast_body: std.AutoHashMap(u32, void),
    /// Unified per-`FuncId` declaration record — the canonical-index
    /// substrate for receiver-type membership queries and exact static
    /// binds. Top-level functions fill at phase-1 header registration;
    /// class members fill during class-body lowering (the piece the
    /// split `decl_user_*` tables never covered). Lowering-only; not
    /// serialized.
    decl_sigs: std.AutoHashMap(u32, DeclSig),
    /// Complete owner-scoped member overload sets. The key is
    /// `(declaring-class FQN, source name)` and the value retains every
    /// declaration in source order, including same-arity overloads. Member
    /// headers populate this before any body lowers; image-loaded modules
    /// rebuild it from their declaration records. This is the authoritative
    /// candidate source for member resolution; `member_method_fids` remains
    /// only as a compatibility index for older lowering helpers.
    member_name_index: StrPairMap(std.ArrayList(FuncId)),
    /// Link-time virtual dispatch table. Keys pack a runtime `ClassId` in the
    /// high word and a declaration-rooted `MethodSlotId` in the low word.
    /// Calls consult this table directly; method names never enter dispatch.
    method_dispatch: std.AutoHashMap(u64, FuncId),
    /// Lowering-time resolution diagnostics: ambiguous bare calls the
    /// symbol index refused to pick among. Recorded during lowering and
    /// surfaced by the build driver before the program runs. The name
    /// and FQN slices borrow from the module's own funcs/AST and share
    /// its lifetime.
    resolve_diags: std.ArrayList(ResolveDiag) = .empty,

    /// `(required, total, has_vararg)` for a top-level function's
    /// declared user parameters. `has_vararg` is true for a `vararg`
    /// parameter at ANY position — Kotlin allows a vararg before a
    /// trailing function parameter, and such a candidate matches a call
    /// just as inexactly as a trailing one.
    pub const DeclArity = struct {
        required: u32,
        total: u32,
        has_vararg: bool,
    };

    /// One declaration's resolved signature record (see `decl_sigs`).
    pub const DeclSig = struct {
        /// Enclosing class for an instance method / member extension,
        /// null for top-level declarations.
        enclosing_class: ?ClassId = null,
        /// Declared extension receiver type (structural), else null.
        receiver_ty: ?TypeRef = null,
        /// Declared user-parameter `(required, total, has_vararg)`.
        arity: DeclArity,
        /// Declared user-parameter structural types (`loweredTypeRef`),
        /// excluding any implicit receiver slot.
        sig: []const TypeRef = &.{},
        kind: FuncKind = .plain,
        /// Private member declarations are lexically bound and cannot be
        /// overridden, so a resolved call may target their FuncId directly.
        is_private: bool = false,
        is_inline: bool = false,
        is_suspend: bool = false,
        /// The declaration carries a source body.
        has_body: bool = false,
        /// The declaration has an exact fully-qualified host binding. A
        /// bodyless declaration with this bit uses the ordinary FuncId call
        /// ABI; link finalization attaches the host function to that identity.
        host_backed: bool = false,
    };

    pub const MemberDispatch = enum {
        /// The declaration cannot be overridden at this call site.
        direct,
        /// The declaration is resolved, but the runtime receiver selects an
        /// override. This becomes a numeric method slot in the VM contract.
        virtual,
        /// Static evidence did not identify one declaration.
        deferred,
    };

    pub const MemberResolution = struct {
        target: ?FuncId = null,
        dispatch: MemberDispatch = .deferred,
    };

    pub const MemberResolveCtx = struct {
        /// Lexical class whose body contains the call. Private declarations
        /// are visible only when this is their declaring class.
        lexical_owner: ?ClassId = null,
        /// Restrict the query to private declarations. Used by bare own-member
        /// calls, which can commit directly without considering virtual peers.
        private_only: bool = false,
    };

    pub const ExtensionResolveCtx = struct {
        caller_file: FileId,
        caller_package: []const u8,
    };

    pub const ExtensionResolution = struct {
        target: ?FuncId = null,
    };

    /// One ambiguous bare-call diagnostic: the call-site name and span
    /// plus the first two identical-signature candidates' FQNs and
    /// declaration spans (a span is null when the candidate carries no
    /// phase-1 record).
    pub const ResolveDiag = struct {
        name: []const u8,
        fqn_a: []const u8,
        fqn_b: []const u8,
        span: Span,
        span_a: ?Span = null,
        span_b: ?Span = null,
        kind: Kind = .ambiguous,

        pub const Kind = enum {
            /// Two in-scope candidates nothing can tell apart.
            ambiguous,
            /// Every candidate lives in a package the caller neither
            /// declares, imports, nor sees by default. Kotlin does not
            /// resolve such a reference at all.
            unresolved,
            /// A simple in-scope reference resolves to nothing: notably an
            /// `it` written in a lambda that declares no parameters and is
            /// not invoked with a single argument, where no enclosing
            /// lambda provides an `it` either.
            unresolved_local,
        };

        /// Render the diagnostic with the call site (and declaration
        /// sites) located as `path:line` through `map`. Two identical
        /// FQNs are conflicting overloads — no qualification or import
        /// can separate two declarations sharing one FQN, so the fix is
        /// declaration-side. Distinct FQNs are a cross-package tie the
        /// caller resolves by qualifying the call or importing one
        /// candidate explicitly. An `unresolved` reference names the
        /// out-of-scope candidates and how to bring one into scope.
        pub fn render(self: ResolveDiag, allocator: Allocator, map: *const span.SourceMap) Allocator.Error![]u8 {
            const call_loc = try locOf(allocator, map, self.span);
            defer allocator.free(call_loc);
            if (self.kind == .unresolved_local) {
                return std.fmt.allocPrint(
                    allocator,
                    "{s}: error: unresolved reference `{s}`",
                    .{ call_loc, self.name },
                );
            }
            if (self.kind == .unresolved) {
                if (self.fqn_b.len != 0 and !std.mem.eql(u8, self.fqn_a, self.fqn_b)) {
                    return std.fmt.allocPrint(
                        allocator,
                        "{s}: error: unresolved reference `{s}`: candidates `{s}` and `{s}` exist but neither package is imported here — add an import for one or qualify the call",
                        .{ call_loc, self.name, self.fqn_a, self.fqn_b },
                    );
                }
                return std.fmt.allocPrint(
                    allocator,
                    "{s}: error: unresolved reference `{s}`: `{s}` is declared in package `{s}`, which is not imported here — add `import {s}` or qualify the call",
                    .{ call_loc, self.name, self.fqn_a, packageOfFqn(self.fqn_a, self.name), self.fqn_a },
                );
            }
            if (std.mem.eql(u8, self.fqn_a, self.fqn_b) and self.span_a != null and self.span_b != null) {
                const loc_a = try locOf(allocator, map, self.span_a.?);
                defer allocator.free(loc_a);
                const loc_b = try locOf(allocator, map, self.span_b.?);
                defer allocator.free(loc_b);
                return std.fmt.allocPrint(
                    allocator,
                    "{s}: error: conflicting overloads of `{s}`: identical signatures declared at {s} and {s} — rename or remove one of the declarations",
                    .{ call_loc, self.name, loc_a, loc_b },
                );
            }
            return std.fmt.allocPrint(
                allocator,
                "{s}: error: ambiguous reference `{s}`: candidates `{s}`, `{s}` — qualify the call or import one explicitly",
                .{ call_loc, self.name, self.fqn_a, self.fqn_b },
            );
        }

        fn locOf(allocator: Allocator, map: *const span.SourceMap, s: Span) Allocator.Error![]u8 {
            if (s.file.int() >= map.files.items.len) {
                return std.fmt.allocPrint(allocator, "?:{d}", .{s.start});
            }
            const sf = map.get(s.file);
            const lc = sf.lineCol(s.start);
            return std.fmt.allocPrint(allocator, "{s}:{d}", .{ sf.path, lc.line });
        }
    };

    pub fn init(allocator: Allocator) Module {
        var out__ = Module{
            .lookup_cache_gpa = allocator,
            .func_name_index = std.StringHashMap(std.ArrayList(FuncId)).init(allocator),
            .registry = ModuleRegistry.init(allocator),
            .decl_user_params = std.AutoHashMap(u32, u32).init(allocator),
            .decl_user_arity = std.AutoHashMap(u32, DeclArity).init(allocator),
            .decl_user_sig = std.AutoHashMap(u32, []TypeRef).init(allocator),
            .decl_span = std.AutoHashMap(u32, Span).init(allocator),
            .decl_ast_body = std.AutoHashMap(u32, void).init(allocator),
            .decl_sigs = std.AutoHashMap(u32, DeclSig).init(allocator),
            .member_name_index = StrPairMap(std.ArrayList(FuncId)).init(allocator),
            .method_dispatch = std.AutoHashMap(u64, FuncId).init(allocator),
        };
        if (pending_eager_calls) |pec| {
            out__.eager_calls = pec;
            pending_eager_calls = null;
        }
        if (pending_file_packages) |pfp| {
            out__.registry.file_packages.deinit();
            out__.registry.file_packages = pfp;
            pending_file_packages = null;
        }
        if (pending_eager_types) |pet| {
            out__.eager_types = pet;
            pending_eager_types = null;
        }
        if (pending_eager_recv_heads) |per| {
            out__.eager_recv_heads = per;
            pending_eager_recv_heads = null;
        }
        if (pending_eager_param_shapes) |pep| {
            out__.eager_param_shapes = pep;
            pending_eager_param_shapes = null;
        }
        return out__;
    }

    /// Default-valued constructor.
    pub fn default(allocator: Allocator) Module {
        return Module.init(allocator);
    }

    /// Materialise `func`'s deferred `blocks` from the lazy-IR section, clearing
    /// `deferred_offset` so it is a no-op afterwards. Decoded into the module's
    /// process-lifetime arena so the patch persists across per-program builds.
    pub fn ensureFuncBody(self: *const Module, func: *Func) bool {
        if (func.blocks.len != 0) return true;
        if (func.deferred_offset == 0) return false;
        const decode = self.deferred_func_decode orelse return false;
        if (decode(self.deferred_func_arena, self.deferred_func_section, func.deferred_offset - 1)) |blocks| {
            func.blocks = blocks;
            func.deferred_offset = 0;
        }
        return func.blocks.len != 0;
    }

    /// Look up a function by id. Eager path (fresh build): direct table index.
    /// Lazy path (loaded image, `func_header_offsets` installed): decode the
    /// per-func header section on first touch and memoise it in `func_cache`.
    /// The returned `*const Func` lives for the module's life.
    pub fn funcById(self: *const Module, id: FuncId) ?*const Func {
        const i = id.int();
        const base_n: u32 = @intCast(self.func_header_offsets.len);
        // Ids at/after the lazy base range are this module's own appended funcs,
        // stored densely in `funcs.items` starting at id == base_n.
        if (i >= base_n) return idGet(Func, self.funcs.items, i - base_n);
        // i < base_n: a base func owned by the lazy header section (this module,
        // or the base it was cloned from, shares the section). Decode + memoise.
        if (i >= self.func_cache.len) return null;
        if (self.func_cache[i]) |f| return f;
        const off = self.func_header_offsets[i];
        if (off == 0) return null;
        const decode = self.func_header_decode orelse return null;
        const mut: *Module = @constCast(self);
        while (mut.func_header_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
        defer mut.func_header_lock.store(false, .release);
        if (self.func_cache[i]) |f| return f; // lost the race
        const f = self.deferred_func_arena.create(Func) catch return null;
        f.* = decode(self.deferred_func_arena, self.func_header_section, off - 1) orelse return null;
        mut.func_cache[i] = f;
        return f;
    }

    /// A mutable handle to one of THIS module's own appended funcs (id >= the
    /// lazy base range). Build-time only — base funcs are immutable/lazy.
    pub fn funcByIdMut(self: *Module, id: FuncId) ?*Func {
        const i = id.int();
        const base_n: u32 = @intCast(self.func_header_offsets.len);
        if (i < base_n) return null;
        const j = i - base_n;
        if (j >= self.funcs.items.len) return null;
        return &self.funcs.items[j];
    }

    /// The id the next appended func will take (first id past the lazy base
    /// range + already-appended funcs).
    pub fn nextFuncId(self: *const Module) FuncId {
        return FuncId.from(@intCast(self.func_header_offsets.len + self.funcs.items.len));
    }

    /// Add one declaration to its owner-scoped overload set. Re-registering
    /// the same declaration is harmless: header reservation and body
    /// placement both pass through this API while preserving one stable id.
    pub fn registerMemberDecl(
        self: *Module,
        allocator: Allocator,
        owner_fqn: []const u8,
        name: []const u8,
        id: FuncId,
    ) Allocator.Error!void {
        const gop = try self.member_name_index.getOrPut(.{ .a = owner_fqn, .b = name });
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        for (gop.value_ptr.items) |existing| {
            if (existing.int() == id.int()) return;
        }
        try gop.value_ptr.append(allocator, id);
    }

    /// Every member declaration named `name` directly owned by `owner_fqn`,
    /// in declaration order. An empty slice means the class declares none.
    pub fn memberDecls(self: *const Module, owner_fqn: []const u8, name: []const u8) []const FuncId {
        const list = self.member_name_index.get(.{ .a = owner_fqn, .b = name }) orelse return &.{};
        return list.items;
    }

    pub const MemberDeclGroup = struct {
        owner_fqn: []const u8,
        name: []const u8,
        fids: []const FuncId,
    };

    pub fn memberDeclGroups(self: *const Module, allocator: Allocator) Allocator.Error![]MemberDeclGroup {
        const groups = try allocator.alloc(MemberDeclGroup, self.member_name_index.count());
        var it = self.member_name_index.iterator();
        var i: usize = 0;
        while (it.next()) |entry| : (i += 1) {
            groups[i] = .{
                .owner_fqn = entry.key_ptr.a,
                .name = entry.key_ptr.b,
                .fids = entry.value_ptr.items,
            };
        }
        return groups;
    }

    const MemberCandidate = struct {
        fid: FuncId,
        depth: u16,
    };

    fn collectMemberCandidates(
        self: *const Module,
        allocator: Allocator,
        owner: ClassId,
        name: []const u8,
        depth: u16,
        seen: *std.AutoHashMap(u32, void),
        out: *std.ArrayList(MemberCandidate),
    ) Allocator.Error!void {
        if (owner.int() >= self.classes.items.len or seen.contains(owner.int())) return;
        try seen.put(owner.int(), {});
        const class = &self.classes.items[owner.int()];
        for (self.memberDecls(class.fqn, name)) |fid| {
            var shadowed = false;
            for (out.items) |existing| {
                const existing_sig = self.decl_sigs.get(existing.fid.int()) orelse continue;
                const existing_owner = existing_sig.enclosing_class orelse continue;
                if (try self.overridesSlot(allocator, existing_owner, existing.fid, fid)) {
                    shadowed = true;
                    break;
                }
            }
            if (!shadowed) try out.append(allocator, .{ .fid = fid, .depth = depth });
        }
        for (class.supertypes) |super_id| {
            try self.collectMemberCandidates(allocator, super_id, name, depth + 1, seen, out);
        }
    }

    fn staticTypeHead(name: []const u8) []const u8 {
        var head = applicability.simpleName(name);
        if (std.mem.indexOfScalar(u8, head, '<')) |lt| head = head[0..lt];
        return std.mem.trimEnd(u8, head, "?");
    }

    fn staticSubtypeName(raw: *anyopaque, sub_name: []const u8, super_name: []const u8) bool {
        const self: *const Module = @ptrCast(@alignCast(raw));
        const sub = staticTypeHead(sub_name);
        const super = staticTypeHead(super_name);
        if (std.mem.eql(u8, sub, super)) return false;
        if (self.classIsOrExtends(sub, super)) return true;
        for (applicability.builtinSupersOf(sub)) |candidate| {
            if (std.mem.eql(u8, candidate, super)) return true;
        }
        return false;
    }

    fn staticTypeVar(raw: *anyopaque, fid: FuncId, name: []const u8) bool {
        const self: *const Module = @ptrCast(@alignCast(raw));
        return self.funcTypeParamIndex(fid, staticTypeHead(name)) != null;
    }

    fn staticReceiverAccepts(self: *const Module, fid: FuncId, receiver: TypeRef, param: TypeRef) bool {
        if (receiver.nullable and !param.nullable) return false;
        const actual = staticTypeHead(receiver.name);
        const declared = staticTypeHead(param.name);
        if (actual.len == 0 or declared.len == 0) return false;
        if (std.mem.eql(u8, declared, "Any")) return true;
        if (self.funcTypeParamIndex(fid, declared) != null) {
            if (self.registry.func_type_param_bounds.get(fid)) |bounds| {
                for (bounds) |bound| {
                    if (!std.mem.eql(u8, bound.param, declared)) continue;
                    if (!self.staticReceiverAccepts(fid, receiver, .{
                        .name = bound.bound,
                        .nullable = false,
                        .args = &.{},
                    })) return false;
                }
            }
            return true;
        }
        if (std.mem.eql(u8, actual, declared)) {
            const actual_qualified = std.mem.indexOfScalar(u8, receiver.name, '.') != null;
            const declared_qualified = std.mem.indexOfScalar(u8, param.name, '.') != null;
            if (actual_qualified and declared_qualified and !std.mem.eql(u8, receiver.name, param.name)) return false;
            return true;
        }
        if (self.classIsOrExtends(actual, declared)) return true;
        for (applicability.builtinSupersOf(actual)) |candidate| {
            if (std.mem.eql(u8, candidate, declared)) return true;
        }
        return false;
    }

    fn staticArgAccepts(self: *const Module, fid: FuncId, arg: applicability.ArgShape, param: TypeRef) bool {
        if (arg.ty) |ty| return self.staticReceiverAccepts(fid, ty, param);
        const declared = staticTypeHead(param.name);
        if (std.mem.eql(u8, declared, "Any")) return true;
        if (self.funcTypeParamIndex(fid, declared) != null) return false;
        if (arg.literal_kind) |kind| return switch (kind) {
            .numeric => std.mem.eql(u8, declared, "Byte") or
                std.mem.eql(u8, declared, "Short") or
                std.mem.eql(u8, declared, "Int") or
                std.mem.eql(u8, declared, "Long") or
                std.mem.eql(u8, declared, "Float") or
                std.mem.eql(u8, declared, "Double") or
                std.mem.eql(u8, declared, "UByte") or
                std.mem.eql(u8, declared, "UShort") or
                std.mem.eql(u8, declared, "UInt") or
                std.mem.eql(u8, declared, "ULong") or
                std.mem.eql(u8, declared, "Number"),
            .string => std.mem.eql(u8, declared, "String") or std.mem.eql(u8, declared, "CharSequence"),
            .boolean => std.mem.eql(u8, declared, "Boolean"),
            .char => std.mem.eql(u8, declared, "Char"),
        };
        if (arg.is_lambda) {
            return std.mem.startsWith(u8, declared, "Function") or std.mem.indexOf(u8, param.name, "->") != null;
        }
        return false;
    }

    fn extensionKeyGreater(a: [8]i32, b: [8]i32) bool {
        inline for (0..7) |i| {
            if (a[i] != b[i]) return a[i] > b[i];
        }
        return false;
    }

    fn extensionKeyEquivalent(a: [8]i32, b: [8]i32) bool {
        return std.mem.eql(i32, a[0..7], b[0..7]);
    }

    /// Resolve an explicit-receiver top-level extension call from declaration
    /// metadata alone. Only a statically proven receiver and a unique overload
    /// at the innermost visible scope produce a target; runtime-value evidence
    /// and declaration-order tie breaking are deliberately unavailable here.
    pub fn resolveExtensionCall(
        self: *const Module,
        name: []const u8,
        receiver: TypeRef,
        args: []const applicability.ArgShape,
        ctx: ExtensionResolveCtx,
    ) ExtensionResolution {
        for (args) |arg| {
            if (arg.named != null or arg.is_spread) return .{};
        }

        var scratch = std.heap.ArenaAllocator.init(self.registry.allocator);
        defer scratch.deinit();
        const sa = scratch.allocator();
        var ids: std.ArrayList(FuncId) = .empty;
        var best_tier: u8 = 255;
        for (self.funcsBySimpleName(name)) |fid| {
            const f = self.funcById(fid) orelse continue;
            const ds = self.decl_sigs.get(fid.int());
            const kind = if (ds) |decl| decl.kind else f.kind;
            if (kind != .top_level_extension or f.params.len == 0 or
                !std.mem.eql(u8, f.params[0].name, "this")) continue;
            // Kotlin runtime declarations still mix source bodies with host
            // representations and name-based lexical globals. Their callable
            // ABI becomes statically bindable with the host symbol manifest;
            // ordinary user and library declarations already use the IR ABI.
            if (pkgHeadIs(f.package, "kotlin")) continue;
            const has_body = f.hasBody() or (if (ds) |decl| decl.has_body else false) or
                self.decl_ast_body.contains(fid.int());
            if (!has_body) continue;
            if (self.registry.private_fn_files.get(fid)) |decl_file| {
                if (decl_file.int() != ctx.caller_file.int()) continue;
            }
            const recv_param = if (ds) |decl| decl.receiver_ty orelse f.params[0].ty else f.params[0].ty;
            if (!self.staticReceiverAccepts(fid, receiver, recv_param)) continue;
            if (f.params.len != args.len + 1) continue;
            var has_vararg = false;
            for (f.params[1..]) |param| {
                if (param.is_vararg) {
                    has_vararg = true;
                    break;
                }
            }
            if (has_vararg) continue;
            var args_proven = true;
            for (args, f.params[1..]) |arg, param| {
                if (!self.staticArgAccepts(fid, arg, param.ty)) {
                    args_proven = false;
                    break;
                }
            }
            if (!args_proven) continue;
            const tier = self.scopeTier(f.fqn, f.package, name, ctx.caller_package, ctx.caller_file);
            if (tier > 3 or tier > best_tier) continue;
            if (tier < best_tier) {
                ids.clearRetainingCapacity();
                best_tier = tier;
            }
            ids.append(sa, fid) catch return .{};
        }
        if (ids.items.len == 0) return .{};

        const sigs = sa.alloc(applicability.SigView, ids.items.len) catch return .{};
        for (ids.items, 0..) |fid, i| {
            const f = self.funcById(fid).?;
            sigs[i] = .{
                .params = f.params,
                .has_body = true,
                .low_priority = f.low_priority,
                .is_extension = true,
                .fid = fid,
                .package = f.package,
            };
        }
        const scope = applicability.ApplicabilityScope{
            .member = true,
            .rank_extensions = true,
            .is_extension = true,
            .receiver = .{ .ty = receiver },
            .all_candidates = sigs,
            .ctx = @ptrCast(@constCast(self)),
            .ext_is_subtype_name = staticSubtypeName,
            .ext_known_package = isShippedPackage,
            .type_var = staticTypeVar,
        };

        var any_ordinary = false;
        for (sigs) |*sig| {
            const score = applicability.applicable(sig, args, scope) orelse continue;
            if (score.ext_key.?[0] != 0 and !score.low_priority) any_ordinary = true;
        }
        var best: ?FuncId = null;
        var best_key: [8]i32 = .{std.math.minInt(i32)} ** 8;
        var tied = false;
        for (sigs, ids.items) |*sig, fid| {
            const score = applicability.applicable(sig, args, scope) orelse continue;
            const key = score.ext_key.?;
            if (key[0] == 0 or (any_ordinary and score.low_priority)) continue;
            if (best == null or extensionKeyGreater(key, best_key)) {
                best = fid;
                best_key = key;
                tied = false;
            } else if (extensionKeyEquivalent(key, best_key)) {
                tied = true;
            }
        }
        if (tied) return .{};
        return .{ .target = best };
    }

    /// Resolve one member name against the declarations owned by the static
    /// receiver class. Candidate applicability and overload ranking are shared
    /// with runtime dispatch; this function additionally classifies whether
    /// the resulting declaration can be called directly or needs a virtual
    /// method slot.
    pub fn resolveMemberCall(
        self: *const Module,
        owner: ClassId,
        name: []const u8,
        args: []const applicability.ArgShape,
        ctx: MemberResolveCtx,
    ) MemberResolution {
        if (owner.int() >= self.classes.items.len) return .{};
        const class = &self.classes.items[owner.int()];
        var scratch = std.heap.ArenaAllocator.init(self.registry.allocator);
        defer scratch.deinit();
        const sa = scratch.allocator();
        var candidates: std.ArrayList(MemberCandidate) = .empty;
        var seen = std.AutoHashMap(u32, void).init(sa);
        self.collectMemberCandidates(sa, owner, name, 0, &seen, &candidates) catch return .{};
        if (candidates.items.len == 0) return .{};

        var named = false;
        for (args) |arg| {
            if (arg.named != null) {
                named = true;
                break;
            }
        }
        const scope = applicability.ApplicabilityScope{
            .member = true,
            .named = named,
            .recv_external = named,
        };
        var best: ?FuncId = null;
        var best_score: i32 = std.math.minInt(i32);
        var tied = false;
        for (candidates.items) |candidate| {
            const fid = candidate.fid;
            const ds = self.decl_sigs.get(fid.int()) orelse continue;
            if (ds.kind != .instance_method) continue;
            if (ds.is_private and (ctx.lexical_owner == null or ctx.lexical_owner.?.int() != owner.int())) continue;
            if (ctx.private_only and !ds.is_private) continue;
            const f = self.funcById(fid) orelse continue;
            const sig = applicability.SigView{
                .params = f.params,
                // Member resolution may bind an abstract declaration to a
                // virtual slot; executability belongs to dispatch, not
                // overload applicability.
                .has_body = true,
                .low_priority = f.low_priority,
                .is_member = true,
                .fid = fid,
                .package = f.package,
            };
            const score = applicability.applicable(&sig, args, scope) orelse continue;
            var applied = score.points + if (!named and f.params.len != 0)
                applicability.tyEvidenceBonus(f.params[1..], args)
            else
                0;
            if (score.exact_arity) applied += 5;
            if (score.low_priority) applied -= 1000;
            if (applied > best_score) {
                best = fid;
                best_score = applied;
                tied = false;
            } else if (applied == best_score) {
                tied = true;
            }
        }
        if (best == null or tied) return .{};
        const target = best.?;
        const ds = self.decl_sigs.get(target.int()).?;
        // Native/expect/abstract headers identify an overload but do not carry
        // the ordinary IR-function ABI required by a direct FuncId call.
        if (!ds.has_body) return .{ .target = target, .dispatch = .virtual };
        if (ds.is_private) return .{ .target = target, .dispatch = .direct };
        const f = self.funcById(target) orelse return .{};
        // An unclaimed classifier header carries no trustworthy final/open/
        // interface modifiers. Its declaration identity can still resolve the
        // overload, but dispatch must remain virtual until the class is filled.
        if (class.is_stub) return .{ .target = target, .dispatch = .virtual };
        if (class.is_value) return .{ .target = target, .dispatch = .virtual };
        const declaring_class = if (ds.enclosing_class) |decl_owner|
            (if (decl_owner.int() < self.classes.items.len) &self.classes.items[decl_owner.int()] else null)
        else
            null;
        const declared_on_interface = if (declaring_class) |decl| decl.is_interface else true;
        if (!class.is_interface and (!class.is_open and !class.is_abstract or (!declared_on_interface and methodIsFinal(f)))) {
            return .{ .target = target, .dispatch = .direct };
        }
        return .{ .target = target, .dispatch = .virtual };
    }

    fn methodIsFinal(f: *const Func) bool {
        if (f.is_open) return false;
        if (f.is_override and !f.is_final) return false;
        return true;
    }

    /// Reconstruct the owner-scoped index from serialized declaration records.
    /// Pack images do not serialize this derived table; loading calls this
    /// once after functions, classes, and declaration signatures are available.
    pub fn rebuildMemberNameIndex(self: *Module, allocator: Allocator) Allocator.Error!void {
        var old_it = self.member_name_index.valueIterator();
        while (old_it.next()) |list| list.deinit(allocator);
        self.member_name_index.clearRetainingCapacity();
        var sig_it = self.decl_sigs.iterator();
        while (sig_it.next()) |entry| {
            const owner = entry.value_ptr.enclosing_class orelse continue;
            if (owner.int() >= self.classes.items.len) continue;
            const fid = FuncId.from(entry.key_ptr.*);
            const f = self.funcById(fid) orelse continue;
            try self.registerMemberDecl(allocator, self.classes.items[owner.int()].fqn, f.name, fid);
        }
    }

    fn methodDispatchKey(class: ClassId, slot: MethodSlotId) u64 {
        return (@as(u64, class.int()) << 32) | slot.int();
    }

    /// Concrete implementation selected for `slot` on `runtime_class`.
    pub fn methodSlotTarget(self: *const Module, runtime_class: ClassId, slot: MethodSlotId) ?FuncId {
        return self.method_dispatch.get(methodDispatchKey(runtime_class, slot));
    }

    pub const MethodDispatchEntry = struct {
        runtime_class: ClassId,
        slot: MethodSlotId,
        target: FuncId,
    };

    pub fn methodDispatchEntries(self: *const Module, allocator: Allocator) Allocator.Error![]MethodDispatchEntry {
        const entries = try allocator.alloc(MethodDispatchEntry, self.method_dispatch.count());
        var it = self.method_dispatch.iterator();
        var i: usize = 0;
        while (it.next()) |entry| : (i += 1) {
            const runtime_class = ClassId.from(@intCast(entry.key_ptr.* >> 32));
            const slot = MethodSlotId.from(@truncate(entry.key_ptr.*));
            entries[i] = .{
                .runtime_class = runtime_class,
                .slot = slot,
                .target = entry.value_ptr.*,
            };
        }
        return entries;
    }

    pub fn registerMethodSlotTarget(
        self: *Module,
        runtime_class: ClassId,
        slot: MethodSlotId,
        target: FuncId,
    ) Allocator.Error!void {
        try self.method_dispatch.put(methodDispatchKey(runtime_class, slot), target);
    }

    const TypeBinding = struct {
        name: []const u8,
        ty: TypeRef,
    };

    fn bindingType(bindings: []const TypeBinding, name: []const u8) ?TypeRef {
        for (bindings) |binding| {
            if (std.mem.eql(u8, binding.name, name)) return binding.ty;
        }
        return null;
    }

    fn substituteType(allocator: Allocator, ty: TypeRef, bindings: []const TypeBinding) Allocator.Error!TypeRef {
        if (bindingType(bindings, ty.name)) |replacement| {
            var out = replacement;
            out.nullable = out.nullable or ty.nullable;
            return out;
        }
        const args = try allocator.alloc(TypeRef, ty.args.len);
        for (ty.args, args) |arg, *out| out.* = try substituteType(allocator, arg, bindings);
        return .{ .name = ty.name, .nullable = ty.nullable, .args = args };
    }

    fn ancestorBindings(
        self: *const Module,
        allocator: Allocator,
        current: ClassId,
        target: ClassId,
        current_bindings: []const TypeBinding,
        depth: u8,
    ) Allocator.Error!?[]const TypeBinding {
        if (current.int() == target.int()) return try allocator.dupe(TypeBinding, current_bindings);
        if (depth > 64 or current.int() >= self.classes.items.len) return null;
        const class = &self.classes.items[current.int()];
        for (class.supertypes, 0..) |super_id, edge| {
            if (super_id.int() >= self.classes.items.len) continue;
            const super = &self.classes.items[super_id.int()];
            const super_ref: ?TypeRef = if (edge < class.supertype_refs.len) class.supertype_refs[edge] else null;
            const next = try allocator.alloc(TypeBinding, super.type_params.len);
            for (super.type_params, 0..) |param, i| {
                const supplied: TypeRef = if (super_ref) |ref|
                    (if (i < ref.args.len) ref.args[i] else .{ .name = param, .nullable = false, .args = &.{} })
                else
                    .{ .name = param, .nullable = false, .args = &.{} };
                next[i] = .{ .name = param, .ty = try substituteType(allocator, supplied, current_bindings) };
            }
            if (try self.ancestorBindings(allocator, super_id, target, next, depth + 1)) |found| return found;
        }
        return null;
    }

    fn funcTypeParamIndex(self: *const Module, fid: FuncId, name: []const u8) ?usize {
        const params = self.registry.func_type_params.get(fid) orelse return null;
        for (params.items, 0..) |param, i| {
            if (std.mem.eql(u8, param, name)) return i;
        }
        return null;
    }

    fn overrideTypeClassId(self: *const Module, fid: FuncId, name: []const u8) ?ClassId {
        if (self.classIdByFqn(name) orelse self.classIdByQualifiedSuffix(name)) |id| return id;
        const sig = self.decl_sigs.get(fid.int()) orelse return null;
        const owner = sig.enclosing_class orelse return null;
        if (self.classIdNestedIn(owner, applicability.simpleName(name))) |id| return id;
        if (owner.int() >= self.classes.items.len) return null;
        const owner_fqn = self.classes.items[owner.int()].fqn;
        for (self.classes.items) |class| {
            if (class.fqn.len != owner_fqn.len + name.len + 1) continue;
            if (std.mem.startsWith(u8, class.fqn, owner_fqn) and
                class.fqn[owner_fqn.len] == '.' and
                std.mem.eql(u8, class.fqn[owner_fqn.len + 1 ..], name))
            {
                return class.id;
            }
        }
        return null;
    }

    fn overrideQualifiedPath(ty: TypeRef) ?[]const u8 {
        for (ty.args) |arg| {
            if (std.mem.startsWith(u8, arg.name, "#qual:")) return arg.name["#qual:".len..];
        }
        return null;
    }

    fn overrideArgs(ty: TypeRef) []TypeRef {
        var end = ty.args.len;
        while (end > 0 and std.mem.startsWith(u8, ty.args[end - 1].name, "#qual:")) end -= 1;
        return ty.args[0..end];
    }

    fn overrideTypeEql(
        self: *const Module,
        candidate: FuncId,
        base: FuncId,
        candidate_ty: TypeRef,
        base_ty: TypeRef,
    ) bool {
        const candidate_tp = self.funcTypeParamIndex(candidate, candidate_ty.name);
        const base_tp = self.funcTypeParamIndex(base, base_ty.name);
        if (candidate_tp != null or base_tp != null) return candidate_tp != null and candidate_tp == base_tp;
        const candidate_qualified = overrideQualifiedPath(candidate_ty);
        const base_qualified = overrideQualifiedPath(base_ty);
        if (!std.mem.eql(u8, candidate_ty.name, base_ty.name) or
            candidate_qualified != null or base_qualified != null)
        {
            const candidate_class = self.overrideTypeClassId(
                candidate,
                candidate_qualified orelse candidate_ty.name,
            ) orelse return false;
            const base_class = self.overrideTypeClassId(
                base,
                base_qualified orelse base_ty.name,
            ) orelse return false;
            if (candidate_class.int() != base_class.int()) return false;
        }
        const candidate_args = overrideArgs(candidate_ty);
        const base_args = overrideArgs(base_ty);
        if (candidate_ty.nullable != base_ty.nullable or candidate_args.len != base_args.len) return false;
        for (candidate_args, base_args) |ca, ba| {
            if (!self.overrideTypeEql(candidate, base, ca, ba)) return false;
        }
        return true;
    }

    fn overridesSlot(
        self: *const Module,
        allocator: Allocator,
        owner: ClassId,
        candidate: FuncId,
        base: FuncId,
    ) Allocator.Error!bool {
        const candidate_func = self.funcById(candidate) orelse return false;
        const base_func = self.funcById(base) orelse return false;
        if (!candidate_func.is_override or !std.mem.eql(u8, candidate_func.name, base_func.name)) return false;
        const candidate_sig = self.decl_sigs.get(candidate.int()) orelse return false;
        const base_sig = self.decl_sigs.get(base.int()) orelse return false;
        if (candidate_sig.kind != .instance_method or base_sig.kind != .instance_method) return false;
        if (candidate_sig.is_suspend != base_sig.is_suspend or candidate_sig.sig.len != base_sig.sig.len) return false;
        const base_owner = base_sig.enclosing_class orelse return false;

        const owner_class = &self.classes.items[owner.int()];
        const identity = try allocator.alloc(TypeBinding, owner_class.type_params.len);
        for (owner_class.type_params, 0..) |param, i| {
            identity[i] = .{ .name = param, .ty = .{ .name = param, .nullable = false, .args = &.{} } };
        }
        const bindings = (try self.ancestorBindings(allocator, owner, base_owner, identity, 0)) orelse return false;
        for (candidate_sig.sig, base_sig.sig) |candidate_ty, raw_base_ty| {
            const base_ty = try substituteType(allocator, raw_base_ty, bindings);
            if (!self.overrideTypeEql(candidate, base, candidate_ty, base_ty)) return false;
        }
        return true;
    }

    fn mergeInheritedMethod(
        self: *const Module,
        allocator: Allocator,
        map: *std.AutoHashMap(u32, FuncId),
        slot: u32,
        incoming: FuncId,
    ) Allocator.Error!void {
        const gop = try map.getOrPut(slot);
        if (!gop.found_existing) {
            gop.value_ptr.* = incoming;
            return;
        }
        const existing = gop.value_ptr.*;
        if (existing.int() == incoming.int()) return;

        gop.value_ptr.* = try self.preferredMethodSlotTarget(allocator, existing, incoming);
    }

    /// Choose the more-specific implementation of one inherited virtual slot.
    /// Runtime-defined classes use the same rule when merging the already-linked
    /// slot tables of their declared supertypes.
    pub fn preferredMethodSlotTarget(
        self: *const Module,
        allocator: Allocator,
        existing: FuncId,
        incoming: FuncId,
    ) Allocator.Error!FuncId {
        if (existing.int() == incoming.int()) return existing;

        if (self.decl_sigs.get(existing.int())) |sig| {
            if (sig.enclosing_class) |owner| {
                if (try self.overridesSlot(allocator, owner, existing, incoming)) return existing;
            }
        }
        if (self.decl_sigs.get(incoming.int())) |sig| {
            if (sig.enclosing_class) |owner| {
                if (try self.overridesSlot(allocator, owner, incoming, existing)) {
                    return incoming;
                }
            }
        }
        return existing;
    }

    fn linkMethodClass(
        self: *Module,
        allocator: Allocator,
        maps: []std.AutoHashMap(u32, FuncId),
        state: []u8,
        cid: ClassId,
    ) Allocator.Error!void {
        if (cid.int() >= self.classes.items.len or state[cid.int()] == 2) return;
        if (state[cid.int()] == 1) return;
        state[cid.int()] = 1;
        const class = &self.classes.items[cid.int()];
        for (class.supertypes) |super_id| {
            try self.linkMethodClass(allocator, maps, state, super_id);
            if (super_id.int() >= maps.len) continue;
            var inherited = maps[super_id.int()].iterator();
            while (inherited.next()) |entry| {
                try self.mergeInheritedMethod(
                    allocator,
                    &maps[cid.int()],
                    entry.key_ptr.*,
                    entry.value_ptr.*,
                );
            }
        }

        // `Class.methods` contains executable bodies only; abstract/interface
        // headers are deliberately absent. Slots are declaration metadata, so
        // enumerate the canonical declaration table instead.
        var own_methods: std.ArrayList(FuncId) = .empty;
        defer own_methods.deinit(allocator);
        var decl_it = self.decl_sigs.iterator();
        while (decl_it.next()) |entry| {
            const decl_owner = entry.value_ptr.enclosing_class orelse continue;
            if (decl_owner.int() != cid.int() or entry.value_ptr.kind != .instance_method) continue;
            try own_methods.append(allocator, FuncId.from(entry.key_ptr.*));
        }
        std.mem.sort(FuncId, own_methods.items, {}, struct {
            fn lessThan(_: void, lhs: FuncId, rhs: FuncId) bool {
                return lhs.int() < rhs.int();
            }
        }.lessThan);
        for (own_methods.items) |fid| {
            const sig = self.decl_sigs.get(fid.int()) orelse continue;
            if (sig.kind != .instance_method or sig.is_private) continue;
            const inherited_count = maps[cid.int()].count();
            if (inherited_count != 0) {
                const slots = try allocator.alloc(u32, inherited_count);
                defer allocator.free(slots);
                var slot_it = maps[cid.int()].keyIterator();
                var i: usize = 0;
                while (slot_it.next()) |slot| : (i += 1) slots[i] = slot.*;
                for (slots) |slot| {
                    const base = FuncId.from(slot);
                    if (try self.overridesSlot(allocator, cid, fid, base)) try maps[cid.int()].put(slot, fid);
                }
            }
            try maps[cid.int()].put(MethodSlotId.fromFunc(fid).int(), fid);
        }
        state[cid.int()] = 2;
    }

    /// Build every `(runtime class, virtual slot) -> implementation` entry once
    /// after class and member headers are complete. Generic substitutions are
    /// composed along resolved `ClassId` inheritance edges; runtime dispatch is
    /// consequently numeric and performs no overload or name resolution.
    pub fn linkMethodSlots(self: *Module, allocator: Allocator) Allocator.Error!void {
        self.method_dispatch.clearRetainingCapacity();
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const maps = try sa.alloc(std.AutoHashMap(u32, FuncId), self.classes.items.len);
        for (maps) |*map| map.* = std.AutoHashMap(u32, FuncId).init(sa);
        const state = try sa.alloc(u8, self.classes.items.len);
        @memset(state, 0);
        for (self.classes.items) |class| try self.linkMethodClass(sa, maps, state, class.id);
        for (maps, 0..) |*map, raw_cid| {
            var it = map.iterator();
            while (it.next()) |entry| {
                try self.method_dispatch.put(
                    methodDispatchKey(ClassId.from(@intCast(raw_cid)), MethodSlotId.from(entry.key_ptr.*)),
                    entry.value_ptr.*,
                );
            }
        }
    }

    /// Number of functions addressable by id (eager table length, or the lazy
    /// offset-table length when loaded from an image).
    pub fn funcCount(self: *const Module) usize {
        return self.func_header_offsets.len + self.funcs.items.len;
    }

    pub fn deinit(self: *Module, allocator: Allocator) void {
        self.funcs.deinit(allocator);
        self.classes.deinit(allocator);
        for (self.consts.items) |c| {
            if (c == .String) allocator.free(c.String);
        }
        self.consts.deinit(allocator);
        self.top_level.deinit(allocator);
        self.class_index.deinit(allocator);
        if (self.class_id_map) |*m| m.deinit();
        if (self.class_fqn_map) |*m| m.deinit();
        if (self.class_parent) |*m| m.deinit();
        if (self.func_by_decl_span) |*m| m.deinit();
        if (self.eager_calls) |*m| m.deinit();
        if (self.eager_types) |*m| m.deinit();
        if (self.eager_recv_heads) |*m| m.deinit();
        if (self.ext_names_by_recv_head) |*m| {
            var vit = m.valueIterator();
            while (vit.next()) |v| v.deinit();
            m.deinit();
        }
        if (self.generic_ext_names) |*m| m.deinit();
        if (self.eager_param_shapes) |*m| m.deinit();
        if (self.class_children) |*m| {
            var itc = m.valueIterator();
            while (itc.next()) |v| v.deinit();
            m.deinit();
        }
        self.func_index.deinit(allocator);
        if (self.lookup_cache_gpa) |cg| {
            self.pkg_head_cache.deinit(cg);
            var cn_it = self.class_name_cache.valueIterator();
            while (cn_it.next()) |list| list.deinit(cg);
            self.class_name_cache.deinit(cg);
            self.class_fqn_cache.deinit(cg);
            self.const_dedup.deinit(cg);
        }
        var it = self.func_name_index.valueIterator();
        while (it.next()) |list| list.deinit(allocator);
        self.func_name_index.deinit();
        self.tailrec_fn_names.deinit(allocator);
        self.registry.deinit();
        self.decl_user_params.deinit();
        self.decl_user_arity.deinit();
        {
            var sig_it = self.decl_user_sig.valueIterator();
            while (sig_it.next()) |sig| {
                for (sig.*) |*ty| ty.deinit(allocator);
                allocator.free(sig.*);
            }
            self.decl_user_sig.deinit();
        }
        self.decl_span.deinit();
        self.decl_ast_body.deinit();
        self.decl_sigs.deinit();
        {
            var member_it = self.member_name_index.valueIterator();
            while (member_it.next()) |list| list.deinit(allocator);
            self.member_name_index.deinit();
        }
        self.method_dispatch.deinit();
        self.resolve_diags.deinit(allocator);
        if (self.pending_lambda_nonfn_locals) |*names| names.deinit();
        if (self.pending_lambda_local_decl_types) |*locals| {
            locals.types.deinit();
            locals.nullable.deinit();
            locals.call_returns.deinit();
        }
    }

    /// Clone this module so the copy can be EXTENDED (funcs/classes/consts
    /// appended, new registry keys added) without touching the original.
    /// Container spines are copied onto `a`; leaf data (instruction slices,
    /// strings, param slices, registry values) is shared with the original,
    /// which must outlive the clone and stay immutable. Built for the
    /// once-per-process stdlib base: the base module is lowered once and
    /// each program extends an arena-backed clone. Clones are arena-owned;
    /// never call `deinit` on one outside an arena teardown.
    pub fn cloneForExtend(self: *const Module, a: Allocator) Allocator.Error!Module {
        var out = Module.init(a);
        // Base funcs are delegated by id through the shared lazy header section
        // (ids 0..base_n); with lazy headers `self.funcs.items` is empty so this
        // copies nothing, and this run's own funcs append past the base id range.
        // (Eager base — no header section — copies them; base_n stays 0.)
        try out.funcs.appendSlice(a, self.funcs.items);
        out.func_header_section = self.func_header_section;
        out.func_header_offsets = self.func_header_offsets;
        out.func_header_decode = self.func_header_decode;
        out.func_cache = self.func_cache;
        out.func_fqn_heads = self.func_fqn_heads;
        out.bodyless_func_ids = self.bodyless_func_ids;
        // Carry the lazy-IR section so a deferred base function materialises
        // when the extending run executes it. Decode into the base's own
        // process-lifetime arena (not this run's `a`, which a freeing/gc backend
        // reclaims out from under the patched blocks).
        out.deferred_func_section = self.deferred_func_section;
        out.deferred_func_arena = self.deferred_func_arena;
        out.deferred_func_decode = self.deferred_func_decode;
        try out.classes.appendSlice(a, self.classes.items);
        try out.consts.appendSlice(a, self.consts.items);
        try out.top_level.appendSlice(a, self.top_level.items);
        try out.class_index.appendSlice(a, self.class_index.items);
        try out.func_index.appendSlice(a, self.func_index.items);
        {
            var it = self.func_name_index.iterator();
            while (it.next()) |e| {
                var list: std.ArrayList(FuncId) = .empty;
                try list.appendSlice(a, e.value_ptr.items);
                try out.func_name_index.put(e.key_ptr.*, list);
            }
        }
        out.package = self.package;
        try out.tailrec_fn_names.appendSlice(a, self.tailrec_fn_names.items);
        out.registry = try self.registry.cloneForExtend(a);
        {
            var it = self.decl_user_params.iterator();
            while (it.next()) |e| try out.decl_user_params.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.decl_user_arity.iterator();
            while (it.next()) |e| try out.decl_user_arity.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.decl_user_sig.iterator();
            while (it.next()) |e| try out.decl_user_sig.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.decl_span.iterator();
            while (it.next()) |e| try out.decl_span.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.decl_ast_body.keyIterator();
            while (it.next()) |k| try out.decl_ast_body.put(k.*, {});
        }
        {
            var it = self.decl_sigs.iterator();
            while (it.next()) |e| try out.decl_sigs.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.member_name_index.iterator();
            while (it.next()) |e| {
                var list: std.ArrayList(FuncId) = .empty;
                try list.appendSlice(a, e.value_ptr.items);
                try out.member_name_index.put(e.key_ptr.*, list);
            }
        }
        {
            var it = self.method_dispatch.iterator();
            while (it.next()) |e| try out.method_dispatch.put(e.key_ptr.*, e.value_ptr.*);
        }
        try out.resolve_diags.appendSlice(a, self.resolve_diags.items);
        return out;
    }

    /// Look up a class by simple name.
    pub fn classId(self: *const Module, name: []const u8) ?ClassId {
        if (self.class_id_map) |*m| return m.get(name);
        if (self.classNameCandidates(name)) |ids| {
            return if (ids.len == 0) null else ids[0];
        }
        for (self.class_index.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.id;
        }
        return null;
    }

    /// The `ClassId`s registered under simple `name`, in `class_index`
    /// order — the exact candidate sequence the linear scan visits. Null
    /// when the lazy cache is unavailable (finalized module, no cache
    /// allocator, or OOM); callers then run their scan. `class_index` is
    /// append-only with immutable names, so a growth-counter top-up keeps
    /// the cache an exact mirror.
    fn classNameCandidates(self: *const Module, name: []const u8) ?[]const ClassId {
        if (self.class_id_map != null) return null;
        const gpa = self.lookup_cache_gpa orelse return null;
        const mut: *Module = @constCast(self);
        mut.topUpClassNameCache(gpa) catch return null;
        if (mut.class_name_cache.getPtr(name)) |list| return list.items;
        return &.{};
    }

    fn topUpClassNameCache(self: *Module, gpa: Allocator) Allocator.Error!void {
        while (self.class_name_cache_n < self.class_index.items.len) : (self.class_name_cache_n += 1) {
            const entry = self.class_index.items[self.class_name_cache_n];
            const gop = try self.class_name_cache.getOrPut(gpa, entry.name);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(gpa, entry.id);
        }
    }

    /// Build the `class_id_map` overlay from `class_index` (first entry wins on a
    /// duplicate simple name, matching the linear scan). Idempotent; call once
    /// after the module is finalized and before concurrent execution.
    pub fn buildClassIdMap(self: *Module, allocator: Allocator) Allocator.Error!void {
        var m = std.StringHashMap(ClassId).init(allocator);
        try m.ensureTotalCapacity(@intCast(self.class_index.items.len));
        for (self.class_index.items) |entry| {
            const gop = m.getOrPutAssumeCapacity(entry.name);
            if (!gop.found_existing) gop.value_ptr.* = entry.id;
        }
        if (self.class_id_map) |*old| old.deinit();
        self.class_id_map = m;

        var fm = std.StringHashMap(ClassId).init(allocator);
        try fm.ensureTotalCapacity(@intCast(self.classes.items.len));
        for (self.classes.items) |c| {
            const gop = fm.getOrPutAssumeCapacity(c.fqn);
            gop.value_ptr.* = if (gop.found_existing) class_id_ambiguous else c.id;
        }
        if (self.class_fqn_map) |*old| old.deinit();
        self.class_fqn_map = fm;

        // The nesting tree. A class's parent is the class whose FQN is its
        // own FQN minus the last segment; children key by that last segment.
        // Lifted `$` simple names alias into the same tree (a companion's
        // `Outer$Companion$Key` reaches the child keyed `Key` under Outer's
        // id), so both spellings resolve through ONE structure.
        var pm = std.AutoHashMap(ClassId, ClassId).init(allocator);
        var cm = std.AutoHashMap(ClassId, std.StringHashMap(ClassId)).init(allocator);
        for (self.classes.items) |c| {
            const dot = std.mem.lastIndexOfScalar(u8, c.fqn, '.') orelse continue;
            const parent_fqn = c.fqn[0..dot];
            const seg = c.fqn[dot + 1 ..];
            const pid = blk: {
                const got = fm.get(parent_fqn) orelse break :blk null;
                if (got.int() == class_id_ambiguous.int()) break :blk null;
                break :blk got;
            } orelse continue;
            try pm.put(c.id, pid);
            const gop = try cm.getOrPut(pid);
            if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap(ClassId).init(allocator);
            const cg = try gop.value_ptr.getOrPut(seg);
            if (!cg.found_existing) cg.value_ptr.* = c.id;
        }
        if (self.class_parent) |*old| old.deinit();
        self.class_parent = pm;
        if (self.class_children) |*old| {
            var it = old.valueIterator();
            while (it.next()) |v| v.deinit();
            old.deinit();
        }
        self.class_children = cm;
    }

    /// ONE scoped classifier lookup: resolve simple `name` against the
    /// nesting tree starting from `owner` (a class id), walking outward
    /// through the lexical parents. Answers nested classes, nested objects,
    /// and companions uniformly — the string-mangled `$`/`.` probes derive
    /// from the same FQNs this tree was built from.
    /// Install the eager per-call resolution (driver-owned map).
    pub fn installEagerCalls(self: *Module, m: std.AutoHashMap(span.Span, span.Span)) void {
        if (self.eager_calls) |*old_m| old_m.deinit();
        self.eager_calls = m;
    }
    /// Typeck's static type head for the expression at `sp`, if recorded.
    pub fn eagerTypeOf(self: *const Module, sp: span.Span) ?EagerTypeHead {
        const et = &(self.eager_types orelse return null);
        return et.get(sp);
    }
    /// The declared shape of the fn-typed lambda param declared at `sp`.
    pub fn eagerParamShapeOf(self: *const Module, sp: span.Span) ?EagerParamShape {
        const m = &(self.eager_param_shapes orelse return null);
        return m.get(sp);
    }
    /// Could ANY extension named `name` serve receiver head `head`?
    /// Chain-aware: the head's supertype chain and the builtin-supertype
    /// table are consulted, and generic-receiver extensions answer true
    /// for every head. Conservative on staleness: the index rebuilds when
    /// the declaration index has grown since the last build.
    pub fn extCouldApply(self: *Module, allocator: Allocator, head: []const u8, name: []const u8) bool {
        if (self.ext_names_by_recv_head == null or self.ext_index_decl_count != self.func_index.items.len) {
            self.rebuildExtIndex(allocator) catch return true;
        }
        if (self.generic_ext_names.?.contains(name)) return true;
        const idx = &self.ext_names_by_recv_head.?;
        if (idx.get(head)) |set| {
            if (set.contains(name)) return true;
        }
        for (applicability.builtinSupersOf(head)) |sup| {
            if (idx.get(sup)) |set| {
                if (set.contains(name)) return true;
            }
        }
        if (self.registry.class_super_names.get(head)) |chain| {
            for (chain) |sup| {
                if (idx.get(sup)) |set| {
                    if (set.contains(name)) return true;
                }
            }
        }
        return false;
    }

    fn rebuildExtIndex(self: *Module, allocator: Allocator) Allocator.Error!void {
        if (self.ext_names_by_recv_head) |*m| {
            var vit = m.valueIterator();
            while (vit.next()) |v| v.deinit();
            m.deinit();
        }
        if (self.generic_ext_names) |*m| m.deinit();
        var idx = std.StringHashMap(std.StringHashMap(void)).init(allocator);
        var gen = std.StringHashMap(void).init(allocator);
        for (self.func_index.items) |entry| {
            const ds = self.decl_sigs.get(entry.id.int());
            const f = if (ds == null) self.funcById(entry.id) else null;
            const kind = if (ds) |sig| sig.kind else if (f) |func| func.kind else continue;
            const is_ext = kind == .top_level_extension or kind == .member_extension;
            if (!is_ext) continue;
            const receiver_ty = if (ds) |sig|
                sig.receiver_ty
            else if (f) |func|
                if (func.params.len != 0) func.params[0].ty else null
            else
                null;
            const raw_head = (receiver_ty orelse continue).name;
            const head = staticTypeHead(raw_head);
            if (self.funcTypeParamIndex(entry.id, head) != null or
                (head.len <= 2 and headAllUpper(head)))
            {
                try gen.put(entry.name, {});
                continue;
            }
            const gop = try idx.getOrPut(head);
            if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap(void).init(allocator);
            try gop.value_ptr.put(entry.name, {});
        }
        self.ext_names_by_recv_head = idx;
        self.generic_ext_names = gen;
        self.ext_index_decl_count = self.func_index.items.len;
    }

    /// The receiver class head typeck bound for the lambda body at `sp`.
    pub fn eagerRecvHeadOf(self: *const Module, sp: span.Span) ?[]const u8 {
        const m = &(self.eager_recv_heads orelse return null);
        return m.get(sp);
    }
    /// The typeck-resolved target FuncId for the call at `callee_span`:
    /// eager record composed with the lowered-declaration identity map.
    pub fn eagerCallTarget(self: *const Module, callee_span: span.Span) ?FuncId {
        const ec = &(self.eager_calls orelse return null);
        const decl = ec.get(callee_span) orelse return null;
        const got = self.funcByDeclSpan(decl);
        if (got == null and std.c.getenv("KLIO_EAGER_HITS") != null) {
            const n: usize = if (self.func_by_decl_span) |m| m.count() else 0;
            std.debug.print("[EAGER-MISS2] decl f{d}:{d}-{d} not lowered (map n={d})\n", .{ decl.file.int(), decl.start, decl.end, n });
        }
        return got;
    }

    /// Record a lowered declaration's identity (its AST name-span).
    pub fn recordFuncDeclSpan(self: *Module, allocator: Allocator, decl_span: span.Span, id: FuncId) Allocator.Error!void {
        if (self.func_by_decl_span == null) {
            self.func_by_decl_span = std.AutoHashMap(span.Span, FuncId).init(allocator);
        }
        try self.func_by_decl_span.?.put(decl_span, id);
    }
    /// The FuncId lowered for the declaration at `decl_span`, if any.
    pub fn funcByDeclSpan(self: *const Module, decl_span: span.Span) ?FuncId {
        const m = &(self.func_by_decl_span orelse return null);
        return m.get(decl_span);
    }

    /// The DIRECT child class named `name` of `owner` (no enclosing-chain walk),
    /// e.g. `owner`'s own `Companion` or nested class. Null if `owner` has no such
    /// direct child, or the nesting tree is not yet built.
    pub fn classDirectChild(self: *const Module, owner: ClassId, name: []const u8) ?ClassId {
        const cm = &(self.class_children orelse return null);
        if (cm.get(owner)) |kids| return kids.get(name);
        return null;
    }

    pub fn classIdNestedIn(self: *const Module, owner: ClassId, name: []const u8) ?ClassId {
        const cm = &(self.class_children orelse return null);
        const pm = &(self.class_parent orelse return null);
        var cur: ?ClassId = owner;
        var hops: u8 = 0;
        while (cur) |cid| : (hops += 1) {
            if (hops > 16) break;
            if (cm.get(cid)) |kids| {
                if (kids.get(name)) |hit| return hit;
                // A companion's members are reachable without naming it:
                // probe one level through a companion child.
                if (kids.get("Companion")) |comp| {
                    if (cm.get(comp)) |ckids| {
                        if (ckids.get(name)) |hit| return hit;
                    }
                }
            }
            cur = pm.get(cid);
        }
        return null;
    }

    /// Resolve a class written with a dotted qualifier (`Outer.Inner`) by
    /// matching it as a `.`-aligned suffix of a registered class's FQN. This
    /// disambiguates a nested base from a same-simple-name class in scope
    /// (including a subtype named like its base), which a simple-name lookup
    /// cannot. Prefers the shortest FQN among matches (the least-nested, most
    /// specific qualification). Returns null when the path is unqualified or
    /// no class FQN ends with it.
    pub fn classIdByQualifiedSuffix(self: *const Module, qualified: []const u8) ?ClassId {
        if (std.mem.indexOfScalar(u8, qualified, '.') == null) return null;
        var best: ?ClassId = null;
        var best_len: usize = std.math.maxInt(usize);
        for (self.class_index.items) |entry| {
            const c = idGet(Class, self.classes.items, entry.id.int()) orelse continue;
            const fqn = c.fqn;
            if (!std.mem.endsWith(u8, fqn, qualified)) continue;
            // Require a `.`-aligned boundary so `X.Configuration` does not
            // match `OtherX.Configuration`.
            const at = fqn.len - qualified.len;
            if (at != 0 and fqn[at - 1] != '.') continue;
            if (fqn.len < best_len) {
                best_len = fqn.len;
                best = entry.id;
            }
        }
        return best;
    }

    /// Resolve a class by simple name from the caller's scope, ranking
    /// same-simple-name classes from different packages under the bare-
    /// call tier order over `Class.package` (named import, own package,
    /// wildcard import, default import, shipped, other). Declaration
    /// order breaks a same-tier tie, so a single-candidate lookup
    /// matches `classId` exactly while a cross-package collision binds
    /// the class the caller can actually see.
    pub fn classIdIndexed(self: *const Module, name: []const u8, caller_pkg: []const u8, caller_file: FileId) ?ClassId {
        var best: ?ClassId = null;
        var best_tier: u8 = 255;
        if (self.classNameCandidates(name)) |ids| {
            for (ids) |cid| {
                const c = idGet(Class, self.classes.items, cid.int()) orelse continue;
                const t = self.scopeTier(c.fqn, c.package, name, caller_pkg, caller_file);
                if (t < best_tier) {
                    best_tier = t;
                    best = cid;
                }
            }
            return best;
        }
        for (self.class_index.items) |entry| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            const c = idGet(Class, self.classes.items, entry.id.int()) orelse continue;
            const t = self.scopeTier(c.fqn, c.package, name, caller_pkg, caller_file);
            if (t < best_tier) {
                best_tier = t;
                best = entry.id;
            }
        }
        return best;
    }

    /// Rebuild `func_name_index` from the declaration-order
    /// `func_index`. The IR build pipelines call this whenever
    /// they're done extending `func_index`; incremental writers pair
    /// every `func_index` append with a name-index push, so the name
    /// index is authoritative at all times.
    pub fn rebuildFuncNameIndex(self: *Module, allocator: Allocator) Allocator.Error!void {
        var it = self.func_name_index.valueIterator();
        while (it.next()) |list| list.deinit(allocator);
        self.func_name_index.clearRetainingCapacity();
        for (self.func_index.items) |entry| {
            const gop = try self.func_name_index.getOrPut(entry.name);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, entry.id);
        }
    }

    /// All `FuncId`s registered under the given simple name, in
    /// declaration order. Returns an empty slice when no match exists
    /// or when the `func_name_index` hasn't been populated for a
    /// freshly-deserialized module.
    pub fn funcsBySimpleName(self: *const Module, name: []const u8) []const FuncId {
        if (self.func_name_index.get(name)) |list| return list.items;
        return &.{};
    }

    /// First-wins order-based pick for a simple name, over the name
    /// index — the single authority: every build pipeline pairs each
    /// `func_index` append with a name-index push (member extensions
    /// via `funcNameIndexPush`, header stubs in the phase-1 loop) and
    /// rebuilds after batch mutation, and the pack format never
    /// serializes a `Module`, so no stale-index module exists.
    pub fn funcId(self: *const Module, name: []const u8) ?FuncId {
        const candidates = self.funcsBySimpleName(name);
        var first: ?FuncId = null;
        var first_user: ?FuncId = null;
        var first_body: ?FuncId = null;
        // A `@Deprecated(level = ERROR|HIDDEN)` / `@LowPriorityInOverloadResolution`
        // overload is not a source-level candidate — it must never be the
        // canonical heuristic pick while an ordinary same-name overload exists
        // (a hidden binary-compat form that delegates to the real overload by
        // name would otherwise self-recurse). Keep it only as the last resort
        // for a name whose every overload is low-priority.
        var first_lp: ?FuncId = null;
        for (candidates) |id| {
            if (self.funcById(id)) |f| {
                if (f.low_priority) {
                    if (first_lp == null) first_lp = id;
                    continue;
                }
            }
            if (first == null) first = id;
            if (self.funcById(id)) |f| {
                if (first_body == null and f.hasBody()) first_body = id;
                if (first_user != null) continue;
                if (!isShippedPackage(f.package)) first_user = id;
            }
        }
        // Prefer body over bodyless: a same-name `expect` (bodyless)
        // should not hide a same-name `actual` / non-expect body
        // sibling.
        return first_user orelse first_body orelse first orelse first_lp;
    }

    /// `funcId`'s order-based pick restricted to the candidates a BARE call
    /// at a site enclosed by `ctx_owner` can actually bind: a member
    /// extension out of that scope is not a candidate at all
    /// (`memberExtOutOfScope`). Without the restriction the user-over-shipped
    /// preference hands a bare `with(x) { … }` an unrelated class's
    /// `KeyframeEntity.with` ahead of `kotlin.with`.
    fn funcIdForBareCall(self: *const Module, name: []const u8, ctx_owner: ?[]const u8) ?FuncId {
        const candidates = self.funcsBySimpleName(name);
        var first: ?FuncId = null;
        var first_user: ?FuncId = null;
        var first_body: ?FuncId = null;
        var first_lp: ?FuncId = null;
        for (candidates) |id| {
            if (self.memberExtOutOfScope(id, ctx_owner)) continue;
            if (self.funcById(id)) |f| {
                if (f.low_priority) {
                    if (first_lp == null) first_lp = id;
                    continue;
                }
            }
            if (first == null) first = id;
            if (self.funcById(id)) |f| {
                if (first_body == null and f.hasBody()) first_body = id;
                if (first_user != null) continue;
                if (!isShippedPackage(f.package)) first_user = id;
            }
        }
        return first_user orelse first_body orelse first orelse first_lp;
    }

    /// Overload pick for a call carrying a `*spread` argument. Kotlin only
    /// lets a spread bind to a `vararg` parameter, so fixed-arity overloads
    /// are not candidates at all — without the restriction the arg-blind
    /// by-name pick hands `mutableStateListOf(*arr)` the zero-arg overload
    /// and the spread's elements are silently dropped. Ordering within the
    /// vararg-bearing candidates mirrors `funcIdForBareCall`.
    pub fn funcIdForSpreadCall(self: *const Module, name: []const u8, ctx_owner: ?[]const u8) ?FuncId {
        const candidates = self.funcsBySimpleName(name);
        var first: ?FuncId = null;
        var first_user: ?FuncId = null;
        var first_body: ?FuncId = null;
        var first_lp: ?FuncId = null;
        for (candidates) |id| {
            if (self.memberExtOutOfScope(id, ctx_owner)) continue;
            const f = self.funcById(id) orelse continue;
            var has_vararg = false;
            for (f.params) |p| {
                if (p.is_vararg) {
                    has_vararg = true;
                    break;
                }
            }
            if (!has_vararg) continue;
            if (f.low_priority) {
                if (first_lp == null) first_lp = id;
                continue;
            }
            if (first == null) first = id;
            if (first_body == null and f.hasBody()) first_body = id;
            if (first_user == null and !isShippedPackage(f.package)) first_user = id;
        }
        return first_user orelse first_body orelse first orelse first_lp;
    }

    /// Whether any top-level function with this simple name exists.
    /// Pure existence — no order-based pick — for callers that only
    /// gate on the name being callable. Answers over the name index,
    /// the single authority (see `funcId`).
    pub fn hasFuncNamed(self: *const Module, name: []const u8) bool {
        return self.funcsBySimpleName(name).len != 0;
    }

    /// Look up a top-level function by fully-qualified name (matches
    /// `Func.fqn`). Use this when a call site already resolved the
    /// FQN so a same-simple-name pack function in a different package
    /// can't shadow the intended target.
    pub fn funcIdByFqn(self: *const Module, fqn: []const u8) ?FuncId {
        // Match by simple name (lazy-friendly via the name index), then confirm
        // the full fqn — decoding only same-simple-name candidates rather than
        // sweeping the (possibly lazy) func table.
        const simple = if (std.mem.lastIndexOfScalar(u8, fqn, '.')) |dot| fqn[dot + 1 ..] else fqn;
        for (self.funcsBySimpleName(simple)) |id| {
            const f = self.funcById(id) orelse continue;
            if (std.mem.eql(u8, f.fqn, fqn)) return id;
        }
        return null;
    }

    /// True when `head` is the first dotted segment of some declared
    /// top-level symbol's FQN — i.e. `head` names a real package the
    /// program contributes a function or class to (`head.` is a known
    /// package prefix). Lets a dotted-head reference distinguish a
    /// package-qualified global (`mypkg.foo(...)`) from a member of an
    /// implicit receiver (`inner.value`) by package membership rather
    /// than lambda nesting: the FQN headers are complete after phase-1
    /// registration, so this answer is independent of declaration order
    /// and of whether the reference is lexically inside a lambda.
    pub fn packageHeadDeclared(self: *const Module, head: []const u8) bool {
        if (head.len == 0) return false;
        if (self.class_id_map == null and !self.pkg_head_cache_dead) {
            if (self.lookup_cache_gpa != null) {
                const mut: *Module = @constCast(self);
                if (mut.topUpPkgHeads()) {
                    return mut.pkg_head_cache.contains(head);
                } else |_| {}
            }
        }
        for (self.func_fqn_heads) |h| {
            if (std.mem.eql(u8, h, head)) return true;
        }
        for (self.funcs.items) |f| {
            if (fqnHasHeadSegment(f.fqn, head)) return true;
        }
        for (self.classes.items) |c| {
            if (fqnHasHeadSegment(c.fqn, head)) return true;
        }
        return false;
    }

    /// Bring `pkg_head_cache` up to date with the append-only func/class
    /// tables. Prefix inserts are idempotent, so a partially-applied OOM
    /// leaves the counters short and the next call resumes exactly there.
    fn topUpPkgHeads(self: *Module) Allocator.Error!void {
        const gpa = self.lookup_cache_gpa.?;
        if (!self.pkg_head_heads_done) {
            for (self.func_fqn_heads) |h| try self.pkg_head_cache.put(gpa, h, {});
            self.pkg_head_heads_done = true;
        }
        while (self.pkg_head_funcs_n < self.funcs.items.len) : (self.pkg_head_funcs_n += 1) {
            try insertFqnPrefixes(&self.pkg_head_cache, gpa, self.funcs.items[self.pkg_head_funcs_n].fqn);
        }
        while (self.pkg_head_classes_n < self.classes.items.len) : (self.pkg_head_classes_n += 1) {
            try insertFqnPrefixes(&self.pkg_head_cache, gpa, self.classes.items[self.pkg_head_classes_n].fqn);
        }
    }

    /// The full segment path of the first non-wildcard import whose
    /// leaf is `name`, as seen from source file `file`. A named import
    /// is file-scoped, so only imports declared in `file` are consulted.
    /// The declared package of source file `file`, when known. Spliced
    /// inline bodies carry donor-file spans; scope judgments follow the
    /// span's file.
    pub fn packageOfFile(self: *const Module, file: FileId) ?[]const u8 {
        return self.registry.file_packages.get(file);
    }

    pub fn importAliasIn(self: *const Module, file: FileId, name: []const u8) ?[]const []const u8 {
        const paths = self.importAliasPathsIn(file, name);
        if (paths.len == 0) return null;
        return paths[0].segs;
    }

    /// Every non-wildcard import in `file` whose bound leaf is `name`,
    /// in declaration order. More than one entry means the file imports
    /// the same leaf from several paths — Kotlin keeps every such
    /// import in scope, so an identical-signature pair behind two
    /// same-leaf imports is an ambiguity, never a shadow.
    pub fn importAliasPathsIn(self: *const Module, file: FileId, name: []const u8) []const ModuleRegistry.ImportPath {
        if (self.registry.import_aliases.get(file)) |m| {
            if (m.get(name)) |paths| return paths.items;
        }
        return &.{};
    }

    /// Whether source file `file` declares `import <pkg>.*`. A wildcard
    /// import is file-scoped like a named one.
    pub fn importWildcardIn(self: *const Module, file: FileId, pkg: []const u8) bool {
        if (pkg.len == 0) return false;
        if (self.registry.import_wildcards.get(file)) |list| {
            for (list.items) |path| {
                if (std.mem.eql(u8, path, pkg)) return true;
            }
        }
        return false;
    }

    /// Packages whose top-level entities are implicitly visible in every
    /// Kotlin source file. Mirrors the canonical
    /// `stdlib.IMPLICITLY_IMPORTED_PACKAGES` (the `ir` module cannot
    /// depend on `stdlib`); an interp-side test keeps the two in
    /// lockstep.
    pub const default_import_packages = [_][]const u8{
        "kotlin",
        "kotlin.annotation",
        "kotlin.collections",
        "kotlin.comparisons",
        "kotlin.io",
        "kotlin.ranges",
        "kotlin.sequences",
        "kotlin.text",
    };

    fn isDefaultImportPackage(pkg: []const u8) bool {
        for (default_import_packages) |p| {
            if (std.mem.eql(u8, p, pkg)) return true;
        }
        return false;
    }

    /// The lowest tier whose candidates are visible to the caller under
    /// Kotlin scoping (named import / own package / wildcard import /
    /// default import). An identical-signature tie above this line is a
    /// real ambiguity; below it Kotlin would not resolve the call at all
    /// and klio's lenient pick stays heuristic.
    pub const last_in_scope_tier: u8 = 3;
    /// The tier of a candidate in a package the caller neither
    /// declares, imports, nor sees by default or via the shipped
    /// surface — Kotlin does not resolve such a reference at all.
    pub const other_package_tier: u8 = 5;

    /// Bare-call preference tier of a candidate func, ranked low-to-high
    /// urgency: 0 = file-named-import, 1 = own package, 2 = file-
    /// wildcard-import package, 3 = default-import package, 4 = built-in
    /// stdlib, 5 = any other package. This is Kotlin's resolution order
    /// for an unqualified top-level callable: the file's explicit
    /// imports outrank even a same-file declaration, then the declaring
    /// package's own scope, then star imports, then the implicitly
    /// imported packages. `caller_pkg` is the caller's declaring package
    /// (`""` for a user script). A non-wildcard import of `name` in
    /// `caller_file` whose full path equals the candidate's FQN matches
    /// tier 0; a wildcard import of the candidate's package matches
    /// tier 2.
    fn bareCallTier(self: *const Module, f: *const Func, name: []const u8, caller_pkg: []const u8, caller_file: FileId) u8 {
        return self.scopeTier(f.fqn, f.package, name, caller_pkg, caller_file);
    }

    /// The scope tier of one declared symbol (function or class) at a
    /// reference site, over its FQN and declaring package. Shared by
    /// `bareCallTier` and `classIdIndexed` so both kinds rank under the
    /// same Kotlin scoping order.
    /// The class/object this file EXACT-imports under `name` (tier-0
    /// resolution only). A read where a same-named top-level property would
    /// otherwise win by default still binds an explicitly imported
    /// classifier — kotlinc gives the exact import precedence over a
    /// cross-package property (ktor: `import ...server...ContentNegotiation`
    /// must not read the client package's same-named top-level val).
    pub fn classIdExactImport(self: *const Module, name: []const u8, caller_file: FileId) ?ClassId {
        // Resolve the imported FQN directly rather than requiring a
        // `class_index` entry whose SIMPLE name is `name`: a collision-mangled
        // class (`import a.Widget` where a same-named `b.Widget` mangled both
        // to `Widget$fN`) is registered only under its mangled name, so the
        // simple-name scan misses it — but its FQN still resolves.
        for (self.importAliasPathsIn(caller_file, name)) |p| {
            if (self.classIdByFqn(p.fqn)) |cid| return cid;
        }
        return null;
    }

    pub fn scopeTier(self: *const Module, fqn: []const u8, pkg: []const u8, name: []const u8, caller_pkg: []const u8, caller_file: FileId) u8 {
        for (self.importAliasPathsIn(caller_file, name)) |p| {
            if (std.mem.eql(u8, p.fqn, fqn)) return 0;
        }
        if (std.mem.eql(u8, pkg, caller_pkg)) return 1;
        if (self.importWildcardIn(caller_file, pkg)) return 2;
        if (isDefaultImportPackage(pkg)) return 3;
        if (isShippedPackage(pkg)) return 4;
        return 5;
    }

    /// Number of *user* parameters a func declares (excluding a leading
    /// synthesized extension/member `this`).
    fn funcUserArity(f: *const Func) usize {
        if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) {
            return f.params.len - 1;
        }
        return f.params.len;
    }

    /// True for a func declared with a leading synthesized `this`
    /// param — an instance method, a top-level extension, or a member
    /// extension. A true bare call (no qualifier) only ever binds a
    /// *non-extension* top-level function; receiver-based resolution of
    /// the extension forms is the heuristic's domain, not the index's.
    fn funcHasImplicitThis(f: *const Func) bool {
        return f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this");
    }

    /// The applicability `SigView` for a candidate at LOWERING time
    /// (distinct from the module-internal `SigView` above, which the
    /// index uses only for the `sameUserSig` identity check). Strips a
    /// leading synthesized `this` so the shared scorer ranks value args
    /// against user parameters. A phase-one header whose declaration has a
    /// body is equally rankable: its params already carry the complete types,
    /// defaults, and vararg flags even though its IR blocks are not lowered
    /// yet. Truly bodyless declarations remain ineligible.
    ///
    /// `func_defaults` lives on `ProgramImage`, not on `Module`, so the
    /// lowering adapter cannot read it; it carries defaults on the params
    /// (`paramHasDefault`'s null-`defaults` fallback).
    fn sigViewForApplicability(self: *const Module, id: FuncId) ?applicability.SigView {
        const f = self.funcById(id) orelse return null;
        const declared_executable = if (self.decl_sigs.get(id.int())) |ds|
            ds.has_body or ds.host_backed
        else
            false;
        if (!f.hasBody() and !declared_executable) return null;
        const off: usize = if (funcHasImplicitThis(f)) 1 else 0;
        return .{
            .params = f.params[off..],
            .defaults = null,
            .has_body = true,
            .low_priority = f.low_priority,
            .is_member = off == 1 and f.kind == .instance_method,
            .is_extension = off == 1,
            .fid = id,
            .package = f.package,
        };
    }

    /// Why the symbol index declined to resolve a bare call. Every
    /// deferral carries one of these so an audit sweep can prove that
    /// the heuristic fallback only ever handles classified structural
    /// shapes, never an unclassified pick.
    pub const ResolveDeferReason = enum {
        /// No top-level function with this simple name exists.
        no_candidates,
        /// Every candidate takes an implicit receiver `this` (instance
        /// method, top-level or member extension); receiver-based
        /// resolution is the heuristic's domain.
        extension_form,
        /// The lowerer always routes this bare name to an intrinsic; the
        /// index defers so it never binds the body the lowerer skips.
        intrinsic_owned,
        /// More than one exact match in a winning tier the caller can
        /// SEE (named import, own package, wildcard import, or default
        /// import), every match with the SAME full parameter type
        /// signature — generic arguments and function-type shapes
        /// included — so nothing can tell them apart, at lowering or at
        /// runtime. Kotlin rejects such a set as conflicting overloads.
        ambiguous_tier,
        /// More than one exact match in the winning tier, but the
        /// matches differ in parameter types: an overload set the
        /// runtime resolves by argument type.
        type_overload,
        /// More than one identical exact match, but every match lives in
        /// a package the caller neither declares, imports, nor sees by
        /// default — Kotlin would not resolve the call at all, so klio's
        /// lenient cross-package pick stays with the heuristic.
        unimported_set,
        /// The winning tier has candidates, but none matches the call's
        /// arity exactly.
        arity_mismatch,
        /// Candidates have defaults, but the positional call cannot bind
        /// them, or a legacy header lacks per-parameter default flags.
        default_param_shape,
        /// Only header stubs / bodyless decls with no declared-arity
        /// record were available.
        bodyless_only,
        /// The only exact matches are low-priority overloads.
        low_priority_only,
        /// The only near matches take a trailing vararg.
        vararg_only,
        /// The call's trailing lambda spans a default-parameter gap, a
        /// shape the index does not model.
        trailing_lambda_shape,
        /// Same-tier same-arity overload set disambiguated by an `as`
        /// cast at the call site. Assigned by the lowerer (which sees
        /// the cast), never produced by the index itself.
        cast_disambiguated,
    };

    /// Result of `resolveBareCallIndexed`: either a unique `FuncId` or a
    /// reason-tagged deferral to the heuristic, plus the winning tier and
    /// its best-match count for the resolve audit's readout.
    pub const BareCallResolution = struct {
        pub const Outcome = union(enum) {
            resolved: FuncId,
            deferred: ResolveDeferReason,
        };
        outcome: Outcome,
        /// Winning preference tier (0..5), or 255 when no candidate
        /// established one.
        tier: u8 = 255,
        /// Best-ranked positional matches counted within the winning tier.
        tier_count: usize = 0,
        /// First two best-ranked matches in the winning tier; both set when
        /// the outcome is `ambiguous_tier`.
        first: ?FuncId = null,
        second: ?FuncId = null,

        /// The resolved id, or null on any deferral.
        pub fn pick(self: BareCallResolution) ?FuncId {
            return switch (self.outcome) {
                .resolved => |id| id,
                .deferred => null,
            };
        }

        /// Deferred because every candidate that matched is
        /// `@LowPriorityInOverloadResolution` / a deprecated stub. Binding the
        /// heuristic here would statically pick such a stub over a same-name
        /// class constructor (kotlinx-datetime's `fun LocalDateTime`), which
        /// self-recurses; the caller must emit a dynamic call instead.
        pub fn lowPriorityOnly(self: BareCallResolution) bool {
            return switch (self.outcome) {
                .deferred => |r| r == .low_priority_only,
                .resolved => false,
            };
        }

        fn deferred(reason: ResolveDeferReason) BareCallResolution {
            return .{ .outcome = .{ .deferred = reason } };
        }
    };

    /// Whether a phase-1 header stub's *declared* user arity exactly
    /// matches the call: no defaults (`required == total`), no vararg at
    /// any position, and exactly `want` parameters. Stubs carry no
    /// lowered params, so this is the order-independent arity source for
    /// ranking forward references; defaults/vararg/trailing-lambda
    /// shapes on a stub stay deferred to the heuristic.
    fn stubDeclArity(self: *const Module, id: FuncId) ?DeclArity {
        return self.decl_user_arity.get(id.int());
    }

    /// Preference tier of one specific candidate at a call site. The
    /// resolve audit uses this to grade a heuristic pick against the
    /// index's: a divergence where the index pick ranks strictly better
    /// is a package-preference correction, not a mis-bind.
    pub fn bareCallTierOf(self: *const Module, id: FuncId, name: []const u8, caller_pkg: []const u8, caller_file: FileId) ?u8 {
        const f = self.funcById(id) orelse return null;
        return self.bareCallTier(f, name, caller_pkg, caller_file);
    }

    /// A candidate's user-parameter type signature: lowered params for
    /// a body-bearing func, the phase-1 declared record for a header
    /// stub. Both render through `lower.decl.loweredTypeRef`, so a stub
    /// and its later-lowered body expose identical structures. `null`
    /// when the signature is unknowable (a bodyless func with no
    /// declared record), which forfeits any identity proof.
    const SigView = union(enum) {
        body: *const Func,
        decl: []const TypeRef,

        fn len(self: SigView) usize {
            return switch (self) {
                .body => |f| funcUserArity(f),
                .decl => |s| s.len,
            };
        }

        fn at(self: SigView, i: usize) TypeRef {
            return switch (self) {
                .body => |f| blk: {
                    const off: usize = if (funcHasImplicitThis(f)) 1 else 0;
                    break :blk f.params[off + i].ty;
                },
                .decl => |s| s[i],
            };
        }
    };

    fn sigViewOf(self: *const Module, id: FuncId, f: *const Func) ?SigView {
        if (f.hasBody()) return .{ .body = f };
        if (self.decl_user_sig.get(id.int())) |sig| return .{ .decl = sig };
        return null;
    }

    /// Whether two candidates declare the same user parameter type
    /// signature (leading synthesized `this` excluded), compared over
    /// the FULL declared structure: head name, nullability, and the
    /// recursive argument shapes — generic arguments, and a function
    /// type's suspend marker, receiver, parameter, and return types.
    /// Only a set equal at this granularity is a true duplicate that
    /// Kotlin rejects as conflicting overloads; any structural
    /// difference leaves a type-dispatched overload set.
    fn sameUserSig(a: SigView, b: SigView) bool {
        if (a.len() != b.len()) return false;
        var i: usize = 0;
        while (i < a.len()) : (i += 1) {
            if (!a.at(i).eql(b.at(i))) return false;
        }
        return true;
    }

    /// Whether any parameter is declared `vararg`, at any position —
    /// the body-side mirror of `DeclArity.has_vararg`, so the stub and
    /// body gates skip the same candidate shapes.
    fn anyParamVararg(f: *const Func) bool {
        for (f.params) |p| {
            if (p.is_vararg) return true;
        }
        return false;
    }

    /// Number of positional arguments omitted from the end of `f` while still
    /// producing a valid call. Kotlin permits the omission only when every
    /// omitted parameter has a default; a required parameter after an earlier
    /// default therefore remains required for a positional call.
    fn positionalDefaultsUsed(f: *const Func, want: usize) ?usize {
        const off: usize = if (funcHasImplicitThis(f)) 1 else 0;
        const params = f.params[off..];
        if (want > params.len) return null;
        for (params[want..]) |p| {
            if (!p.has_default) return null;
        }
        return params.len - want;
    }

    fn omittedPositionHasDefault(f: *const Func, want: usize) bool {
        const off: usize = if (funcHasImplicitThis(f)) 1 else 0;
        const params = f.params[off..];
        if (want >= params.len) return false;
        for (params[want..]) |p| {
            if (p.has_default) return true;
        }
        return false;
    }

    /// Whether the call's trailing lambda can bind `f`'s last (function-
    /// typed) parameter with every gap parameter defaulted — the shape
    /// the heuristic's trailing-lambda rung accepts and the index defers.
    fn tlShapeMatches(f: *const Func, want: usize) bool {
        const up = funcUserArity(f);
        const last_is_fn = f.params.len != 0 and
            std.mem.startsWith(u8, f.params[f.params.len - 1].ty.name, "Function");
        if (!f.hasBody() or !last_is_fn or up < want or want < 1) return false;
        const this_off: usize = if (funcHasImplicitThis(f)) 1 else 0;
        const lead = want - 1;
        const last_user = up - 1;
        var i = lead;
        while (i < last_user) : (i += 1) {
            if (this_off + i >= f.params.len or !f.params[this_off + i].has_default) return false;
        }
        return true;
    }

    /// Principled bare-call resolution: resolve `name` (called with
    /// `want_arity` user args, `last_arg_lambda` set when a trailing
    /// lambda is supplied) to a UNIQUE `FuncId` as a function of the
    /// caller's package + imports + the complete header set, independent
    /// of declaration order. Phase-1 header stubs (forward references,
    /// `expect` decls) rank by their recorded declared arity, so the
    /// answer does not depend on whether a candidate's body has been
    /// lowered yet.
    ///
    /// Preference order — file-named imports, then the caller's own
    /// package, then wildcard imports, then the default-import packages,
    /// then built-in stdlib (Kotlin's scoping order) — picks the highest
    /// non-empty tier; within that tier the candidate is returned only when
    /// exactly one non-extension func matches the positional call. Exact
    /// arity outranks a call that consumes defaults, then fewer consumed
    /// defaults wins. Extension funcs (a leading
    /// synthesized `this`) are never index-resolved: a bare call to one
    /// needs a receiver the index does not model, so it is left to the
    /// order-based heuristic. A name the index cannot resolve to a
    /// single non-extension target defers with a reason classifying
    /// why. Where the index and the heuristic both resolve, they agree
    /// — except when the heuristic's declaration-order pick sits in a
    /// strictly worse preference tier or matches the call less exactly
    /// (a vararg/default/arity-mismatched fallback where the index found
    /// an exact overload); the resolve audit grades every divergence as
    /// one of those corrections, a receiver-preference the heuristic
    /// retains, or a bug.
    pub fn resolveBareCallIndexed(
        self: *const Module,
        name: []const u8,
        caller_pkg_in: []const u8,
        caller_file: FileId,
        want_arity: usize,
        last_arg_lambda: bool,
    ) BareCallResolution {
        // Scope follows the call span's FILE: a spliced inline body carries
        // the donor file's spans, so its bare calls resolve in the donor's
        // package (`withFrameNanos` inside `withFrameMillis`'s body is a
        // same-package call wherever the splice lands).
        const caller_pkg = self.packageOfFile(caller_file) orelse caller_pkg_in;
        const cands = self.funcsBySimpleName(name);
        if (cands.len == 0) return BareCallResolution.deferred(.no_candidates);

        // Highest-priority tier among the non-extension candidates:
        // body-bearing funcs, plus header stubs with a declared-arity
        // record (rankable without a lowered body).
        var best_tier: u8 = 255;
        var all_ext = true;
        var ext_in_scope = false;
        for (cands) |id| {
            const f = self.funcById(id) orelse continue;
            if (funcHasImplicitThis(f)) {
                if (self.bareCallTier(f, name, caller_pkg, caller_file) < other_package_tier) {
                    ext_in_scope = true;
                }
                continue;
            }
            all_ext = false;
            if (!f.hasBody() and self.stubDeclArity(id) == null) continue;
            const t = self.bareCallTier(f, name, caller_pkg, caller_file);
            if (t < best_tier) best_tier = t;
        }
        if (best_tier == 255) {
            return BareCallResolution.deferred(if (all_ext) .extension_form else .bodyless_only);
        }
        // Every rankable non-extension candidate lives in a package the
        // caller cannot see, while an in-scope extension (or member) form
        // exists. Kotlin resolves the call against an implicit receiver's
        // extension long before it would even consider the invisible
        // package, so receiver-based resolution — the heuristic's
        // domain — decides; binding (or rejecting) the invisible
        // function here would be wrong on both counts.
        if (best_tier == other_package_tier and ext_in_scope) {
            return BareCallResolution.deferred(.extension_form);
        }

        // Within the best tier, look for a unique positional,
        // non-low-priority, non-extension candidate. Exact arity outranks a
        // candidate that consumes defaults; among defaulted candidates, the
        // one consuming fewer defaults outranks one consuming more. Track the
        // closest miss so a zero-match tier defers with the blocking shape.
        var chosen: ?FuncId = null;
        var second: ?FuncId = null;
        var count: usize = 0;
        var best_defaults_used: usize = std.math.maxInt(usize);
        // Whether every best-ranked match has the same user
        // parameter type signature as the first one. Distinguishes a
        // true ambiguity from a type-dispatched overload set.
        var sigs_identical = true;
        var saw_tl = false;
        var saw_arity = false;
        var saw_default = false;
        var saw_vararg = false;
        var saw_low = false;
        var saw_bodyless = false;
        for (cands) |id| {
            const f = self.funcById(id) orelse continue;
            if (funcHasImplicitThis(f)) continue;
            if (self.bareCallTier(f, name, caller_pkg, caller_file) != best_tier) continue;
            const is_stub = !f.hasBody();
            // The stub and body gates accept the same positional/default
            // shapes so resolution never depends on whether the body has
            // already replaced its phase-1 header.
            const defaults_used: usize = if (is_stub) blk: {
                const da = self.stubDeclArity(id) orelse {
                    saw_bodyless = true;
                    continue;
                };
                if (f.low_priority) {
                    saw_low = true;
                    continue;
                }
                if (da.has_vararg) {
                    saw_vararg = true;
                    continue;
                }
                if (want_arity > da.total) {
                    saw_arity = true;
                    continue;
                }
                // Legacy/test stubs may carry only the aggregate declared
                // arity. Full arity needs no per-parameter default evidence.
                if (want_arity == da.total) break :blk 0;
                const used = positionalDefaultsUsed(f, want_arity) orelse {
                    if (want_arity < da.total and da.required != da.total) {
                        saw_default = true;
                    } else {
                        saw_arity = true;
                    }
                    continue;
                };
                if (used != 0) saw_default = true;
                break :blk used;
            } else blk: {
                if (f.low_priority) {
                    saw_low = true;
                    continue;
                }
                if (anyParamVararg(f)) {
                    saw_vararg = true;
                    continue;
                }
                const used = positionalDefaultsUsed(f, want_arity) orelse {
                    if (last_arg_lambda and tlShapeMatches(f, want_arity)) {
                        saw_tl = true;
                    } else if (omittedPositionHasDefault(f, want_arity)) {
                        saw_default = true;
                    } else {
                        saw_arity = true;
                    }
                    continue;
                };
                if (used != 0) saw_default = true;
                break :blk used;
            };
            if (defaults_used > best_defaults_used) continue;
            if (defaults_used < best_defaults_used) {
                chosen = null;
                second = null;
                count = 0;
                sigs_identical = true;
                best_defaults_used = defaults_used;
            }
            if (chosen) |first_id| {
                if (second == null) second = id;
                // Identity is proven over lowered params for bodies and
                // the phase-1 declared record for stubs; a candidate
                // with neither forfeits the proof.
                if (sigs_identical) {
                    const first_f = self.funcById(first_id);
                    const first_view: ?SigView = if (first_f) |ff| self.sigViewOf(first_id, ff) else null;
                    const this_view = self.sigViewOf(id, f);
                    if (first_view == null or this_view == null or
                        !sameUserSig(first_view.?, this_view.?))
                    {
                        sigs_identical = false;
                    }
                }
            } else {
                chosen = id;
            }
            count += 1;
        }
        if (count == 1) {
            // A unique match in a package the caller cannot see is not a
            // resolution: kotlinc rejects the reference outright. Defer as
            // an unimported set — the diagnostic layer reports it and the
            // dynamic path keeps klio's lenient last resort. A candidate
            // with no recorded package is a lift artifact with unreliable
            // scoping metadata and keeps the lenient resolution.
            const chosen_pkg_known = blk: {
                const cfn = self.funcById(chosen.?) orelse break :blk false;
                break :blk cfn.package.len != 0;
            };
            if (best_tier == other_package_tier and chosen_pkg_known) {
                return .{
                    .outcome = .{ .deferred = .unimported_set },
                    .tier = best_tier,
                    .tier_count = count,
                    .first = chosen,
                };
            }
            return .{
                .outcome = .{ .resolved = chosen.? },
                .tier = best_tier,
                .tier_count = count,
                .first = chosen,
            };
        }
        if (count > 1) {
            const reason: ResolveDeferReason = if (!sigs_identical)
                .type_overload
            else if (best_tier <= last_in_scope_tier)
                .ambiguous_tier
            else
                .unimported_set;
            return .{
                .outcome = .{ .deferred = reason },
                .tier = best_tier,
                .tier_count = count,
                .first = chosen,
                .second = second,
            };
        }
        const reason: ResolveDeferReason = if (saw_tl)
            .trailing_lambda_shape
        else if (saw_default)
            .default_param_shape
        else if (saw_arity)
            .arity_mismatch
        else if (saw_vararg)
            .vararg_only
        else if (saw_low)
            .low_priority_only
        else if (saw_bodyless)
            .bodyless_only
        else
            .arity_mismatch;
        return .{ .outcome = .{ .deferred = reason }, .tier = best_tier, .tier_count = 0 };
    }

    // -----------------------------------------------------------------
    // `resolveCall` — the single index-primary, type-aware, 3-tier
    // bare-call resolver (plans/p3-resolvecall-design.md §1). Built
    // additively and shadowed behind KLIO_RESOLVE_AUDIT against the
    // current lowering ladder until zero-disagreement; the legacy ladder
    // stays the live pick until the flip.
    // -----------------------------------------------------------------

    /// The three-tier static/dynamic boundary as a resolver verdict.
    ///   exact   — a committed static target; the emitted IR is a direct Call.
    ///   virtual — the slot / candidate is static, the leaf chosen at runtime
    ///             (member-vs-global on an implicit receiver, or a receiver-
    ///             bound extension): CallMember / CallMemberOrGlobal.
    ///   deferred— no static target: unknown receiver or no unique applicable
    ///             candidate; the runtime probe.
    pub const Confidence = enum { exact, virtual, deferred };

    /// The IR emission shape the lowerer switches on — one enum in place of
    /// the per-path re-decision across emitBareFuncCall / emitExtBareCall /
    /// lowerImplicitThisCall / lowerUnresolvedBareCall.
    pub const EmitForm = enum {
        Call,
        CallMember,
        CallMemberOrGlobal,
        CallValue,
    };

    /// A resolved bare call: the committed target (null on a pure deferral),
    /// its confidence, the IR emission form, the in-scope candidate set for
    /// the runtime walk / diagnostics, and the index classification carried
    /// through unchanged.
    pub const Resolution = struct {
        target: ?FuncId,
        confidence: Confidence,
        emit_form: EmitForm,
        candidate_set: []const FuncId = &.{},
        reason: ?ResolveDeferReason = null,
        tier: u8 = 255,
        tier_count: usize = 0,
        /// Every positional argument carried declared-type evidence whose
        /// head PROVED the target's parameter (exact head, or type-param
        /// against type-param). Such a static pick is final — the emitted
        /// `Call` is `exact`, so the runtime's value-typed overload re-pick
        /// (which cannot see the call site's static types) never overrides
        /// it (`minOf(a, b)` with `a: T` stays on the generic overload even
        /// though the runtime args are `Double`).
        ty_proven: bool = false,
    };

    /// The receiver-context bits the lowerer computes on the FuncBuilder,
    /// passed in so `resolveCall` stays a pure function of (call site, sig
    /// index, receiver context) and never reaches into FuncBuilder. Each
    /// field maps 1:1 to an existing lowering gate.
    pub const ResolveCtx = struct {
        in_receiver_context: bool = false,
        unknown_receiver: bool = false,
        enclosing_has_member: bool = false,
        /// The body's receiver type is statically known (a plain method
        /// body): the member-shadow question was answered precisely by its
        /// own hierarchy in `enclosing_has_member`, so Phase C must not
        /// widen it back through the program-wide member-name universe.
        receiver_known: bool = false,
        has_type_args: bool = false,
        cast_pick: ?FuncId = null,
        recv_ty: ?[]const u8 = null,
        is_value_capture: bool = false,
        /// The caller sits in a tailrec function body (`tailrecSelf() != null`).
        /// A positional call to a tailrec target from such a body emits a static
        /// tail `Call`, ahead of the member-shadowable walk — the receiver
        /// gate never re-routes a tail call.
        in_tailrec_body: bool = false,
        /// A lambda argument contains a bare non-local `return`, which is
        /// only legal against an INLINE callee: kotlinc resolves the call
        /// statically to the inline function, so the member-shadowable
        /// deferral must not re-route it (`synchronized(this) { … return
        /// false … }` framed the block, and a park inside it lost the
        /// enclosing frame the labeled return targets).
        nonlocal_return_lambda: bool = false,
        /// The class whose body lexically encloses the call, when there is
        /// one. Scopes the member-extension candidates: only a call inside
        /// the declaring class (or a subclass) has that class as an implicit
        /// dispatch receiver, so only there is one bindable by a bare call.
        owner_class: ?[]const u8 = null,
    };

    fn funcIsInline(self: *const Module, id: FuncId) bool {
        const f = self.funcById(id) orelse return false;
        return f.is_inline;
    }

    fn isNonExtFid(self: *const Module, id: FuncId) bool {
        const f = self.funcById(id) orelse return true;
        return !funcHasImplicitThis(f);
    }

    /// Whether a member-extension candidate is out of scope for a BARE call
    /// whose enclosing class is `ctx_owner`. A member extension (`fun A.f()`
    /// declared in the body of class B) needs two receivers: B to dispatch on
    /// and A as the extension receiver. A bare call carries one implicit
    /// `this`, so it can only bind such a candidate from inside B (or a
    /// subclass), where B's receiver is implicit — or when B is an object,
    /// whose single instance is always reachable. Everywhere else the
    /// candidate does not exist: `with(x) { … }` in `MultiParagraph` is
    /// `kotlin.with`, never `KeyframesSpecConfig`'s `KeyframeEntity.with`.
    /// The runtime applies the same gate in `memberExtVisible`; without it
    /// here, lowering commits to a target the runtime would have rejected.
    fn memberExtOutOfScope(self: *const Module, id: FuncId, ctx_owner: ?[]const u8) bool {
        const f = self.funcById(id) orelse return false;
        if (f.kind != .member_extension) return false;
        const owner = self.registry.member_ext_owner_class.get(id) orelse return false;
        for (self.registry.object_names.items) |o| {
            if (std.mem.eql(u8, o, owner)) return false;
        }
        const start = ctx_owner orelse return true;
        return !self.classIsOrExtends(start, owner);
    }

    /// Body-bearing, last-param-not-vararg, user arity == want — the body-side
    /// gate `expr.zig`'s `arityMatch` applies, mirrored here so the receiver
    /// rebind ranks candidates identically.
    fn arityMatchFid(self: *const Module, id: FuncId, want: usize) bool {
        // Canonical record first: stub-safe during two-phase / pack lowering
        // (the lowered body params do not exist yet, but the declaration's
        // arity is known from phase-1).
        if (self.decl_sigs.get(id.int())) |ds| {
            if (!ds.has_body) return false;
            if (ds.arity.has_vararg) return false;
            return ds.arity.total == want;
        }
        const f = self.funcById(id) orelse return false;
        if (!f.hasBody()) return false;
        if (f.params.len != 0 and f.params[f.params.len - 1].is_vararg) return false;
        return funcUserArity(f) == want;
    }

    /// The candidate's declared receiver head equals `recv` — a body-bearing
    /// extension whose synthesized `this` matches the enclosing receiver.
    fn matchesRecvFid(self: *const Module, id: FuncId, recv: []const u8) bool {
        // The canonical record first: it carries the declared receiver even
        // while the candidate is a phase-1 header stub (two-phase and pack
        // lowering resolve bodies against stubs, so a body requirement here
        // would blind the receiver-match rule exactly when it matters).
        if (self.decl_sigs.get(id.int())) |ds| {
            if (ds.receiver_ty) |rt| return std.mem.eql(u8, rt.name, recv);
        }
        const f = self.funcById(id) orelse return false;
        if (f.params.len == 0) return false;
        return std.mem.eql(u8, f.params[0].name, "this") and
            std.mem.eql(u8, f.params[0].ty.name, recv);
    }

    /// Phase B — the applicability ladder over the simple-name candidate set,
    /// reproducing the order-based heuristic rungs (non-ext exact, ext exact,
    /// ext trailing-lambda, non-ext trailing-lambda) with the shared
    /// `applicable()` as the per-candidate gate. Body-bearing candidates only;
    /// stubs are the INDEX's domain. Returns null when no candidate applies.
    /// Lowering-side hierarchy oracle for the applicability engine: walks
    /// `class_super_names` by evidence head (lift-mangle stripped), so
    /// declared-type evidence can prove a subtype match where the plain
    /// head comparison cannot. Interfaces and classes both live in the
    /// registry chain.
    fn evidenceSubtypeCb(ctx: *anyopaque, sub: []const u8, super: []const u8) bool {
        const self: *const Module = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, sub, super)) return true;
        var cur_buf: [32][]const u8 = undefined;
        var stack_len: usize = 0;
        cur_buf[stack_len] = sub;
        stack_len += 1;
        var seen_buf: [128][]const u8 = undefined;
        var seen_len: usize = 0;
        while (stack_len != 0) {
            stack_len -= 1;
            const cur = cur_buf[stack_len];
            var already = false;
            for (seen_buf[0..seen_len]) |s2| {
                if (std.mem.eql(u8, s2, cur)) {
                    already = true;
                    break;
                }
            }
            if (already) continue;
            if (seen_len < seen_buf.len) {
                seen_buf[seen_len] = cur;
                seen_len += 1;
            }
            const chain = self.registry.class_super_names.get(cur) orelse
                (if (self.registry.mangled_nested.get(cur)) |m| self.registry.class_super_names.get(m) else null) orelse
                continue;
            for (chain) |sup_raw| {
                var sn = sup_raw;
                if (std.mem.lastIndexOfScalar(u8, sn, '.')) |i| sn = sn[i + 1 ..];
                if (std.mem.indexOfScalar(u8, sn, '<')) |lt| sn = sn[0..lt];
                if (std.mem.lastIndexOfScalar(u8, sn, '$')) |i| {
                    if (i + 1 < sn.len) sn = sn[i + 1 ..];
                }
                if (std.mem.eql(u8, sn, super)) return true;
                if (stack_len < cur_buf.len) {
                    cur_buf[stack_len] = sn;
                    stack_len += 1;
                }
            }
        }
        return false;
    }

    /// Whether an EXTENSION candidate's declared receiver could be supplied
    /// by the statically-known receiver context: the owner class's chain or
    /// an enclosing class's. Consulted only when the call site's receiver
    /// types are statically known (a plain method body) — a bare call there
    /// can only reach an extension through `this`/outer instances, so a
    /// declared receiver provably outside every chain disqualifies the
    /// candidate (`TestScope.runTest` inside a plain test class). A
    /// type-parameter, function-type, or unresolvable receiver head keeps
    /// the candidate.
    fn extReceiverPlausible(self: *const Module, id: FuncId, f: *const Func, owner: ?[]const u8) bool {
        const dbg = if (runtime.getenvSlice("KLIO_EXT_TRACE")) |w| std.mem.eql(u8, w, f.name) else false;
        if (dbg) std.debug.print("[extplaus] fid={d} fqn={s} recv_ty={s} owner={?s}\n", .{ id.int(), f.fqn, if (f.params.len != 0) f.params[0].ty.name else "-", owner });
        if (f.params.len == 0) return true;
        var head = applicability.simpleName(f.params[0].ty.name);
        head = std.mem.trimEnd(u8, head, "?");
        if (std.mem.indexOfScalar(u8, head, '<')) |lt| head = head[0..lt];
        if (head.len == 0 or std.mem.eql(u8, head, "Any")) return true;
        if (std.mem.startsWith(u8, head, "Function")) return true;
        if (self.registry.func_type_params.get(id)) |tps| {
            for (tps.items) |tp| {
                if (std.mem.eql(u8, tp, head)) return true;
            }
        }
        // The head must name a class this build knows, or nothing is provable.
        if (self.classId(head) == null and !self.registry.class_super_names.contains(head)) return true;
        var owner_cur: ?[]const u8 = owner orelse return false;
        var hops: usize = 0;
        while (owner_cur) |oc| : (hops += 1) {
            if (hops > 16) break;
            const oc_head = applicability.simpleName(oc);
            if (std.mem.indexOfScalar(u8, oc_head, '$') != null) {
                // A lifted nested class's mangled tail still names it.
                if (std.mem.endsWith(u8, oc_head, head)) return true;
            }
            if (std.mem.eql(u8, oc_head, head)) return true;
            if (self.registry.class_super_names.get(oc)) |chain| {
                for (chain) |sup| {
                    var sn = applicability.simpleName(sup);
                    if (std.mem.indexOfScalar(u8, sn, '<')) |lt2| sn = sn[0..lt2];
                    sn = std.mem.trimEnd(u8, sn, "?");
                    if (std.mem.eql(u8, sn, head)) return true;
                }
            } else {
                // Unknown chain: cannot disprove.
                return true;
            }
            owner_cur = self.registry.enclosing_class.get(oc);
        }
        return false;
    }

    fn phaseBLadder(self: *const Module, name: []const u8, args: []const applicability.ArgShape, caller_pkg: []const u8, caller_file: FileId, ctx_owner: ?[]const u8, receiver_known: bool) ?FuncId {
        const scope = applicability.ApplicabilityScope{
            .ctx = @constCast(@ptrCast(self)),
            .ext_is_subtype_name = evidenceSubtypeCb,
        };
        var best: ?FuncId = null;
        var best_rung: u8 = 255;
        var best_bonus: i32 = 0;
        // A candidate in a package the caller cannot see (no import, not
        // the own/default/shipped surface) is not a Kotlin resolution
        // target. It never outranks a visible candidate — including the
        // bodyless intrinsic stubs the ladder cannot rank (`kotlin.math.
        // max` vs an unimported pack's `max(Dp, Dp)`), so an invisible
        // applicable body must not preempt the declared-arity fallback.
        // It is kept only as a last-resort lenient pick.
        var best_invisible: ?FuncId = null;
        var best_inv_rung: u8 = 255;
        var best_inv_bonus: i32 = 0;
        for (self.funcsBySimpleName(name)) |id| {
            const f = self.funcById(id) orelse continue;
            if (f.low_priority) continue;
            if (self.memberExtOutOfScope(id, ctx_owner)) continue;
            if (f.params.len != 0 and f.params[f.params.len - 1].is_vararg) continue;
            const sv = self.sigViewForApplicability(id) orelse continue;
            const sc = applicability.applicable(&sv, args, scope) orelse continue;
            const is_ext = funcHasImplicitThis(f);
            if (is_ext and receiver_known and !self.extReceiverPlausible(id, f, ctx_owner)) continue;
            const rung: u8 = if (sc.exact_arity)
                (if (is_ext) 1 else 0)
            else if (sc.binding.trailing_lambda_param != null)
                (if (is_ext) 2 else 3)
            else
                (if (is_ext) 5 else 4);
            // Declared-type evidence breaks same-rung ties: an argument whose
            // declared head matches the candidate's parameter head promotes
            // that candidate (`minOf(a, b)` with `a: T` picks the generic
            // overload). Zero for every candidate when no arg carries
            // evidence, so evidence-free calls rank exactly as before.
            const bonus = applicability.tyEvidenceBonusScoped(sv.params, args, scope);
            // Extensions stay in the visible pool regardless of tier:
            // receiver-based resolution, not package scope, is their
            // discriminator (an implicit receiver can supply them).
            const invisible = !is_ext and
                self.scopeTier(f.fqn, f.package, name, caller_pkg, caller_file) == other_package_tier;
            if (invisible) {
                if (rung < best_inv_rung or (rung == best_inv_rung and bonus > best_inv_bonus)) {
                    best_inv_rung = rung;
                    best_inv_bonus = bonus;
                    best_invisible = id;
                }
                continue;
            }
            if (rung < best_rung or (rung == best_rung and bonus > best_bonus)) {
                best_rung = rung;
                best_bonus = bonus;
                best = id;
            }
        }
        if (best != null) return best;
        // No visible body candidate. When a visible bodyless/intrinsic
        // form exists, defer to the declared-arity fallback (it ranks
        // stubs); otherwise keep the lenient out-of-scope pick. An alias
        // name is intrinsic-backed by definition — the host global serves
        // it even when no Func entry exists to prove visibility.
        if (best_invisible != null) {
            if (isAliasName(name)) return null;
            for (self.funcsBySimpleName(name)) |id| {
                const f = self.funcById(id) orelse continue;
                if (funcHasImplicitThis(f)) continue;
                if (f.hasBody()) continue;
                if (self.scopeTier(f.fqn, f.package, name, caller_pkg, caller_file) < other_package_tier) {
                    return null;
                }
            }
        }
        return best_invisible;
    }

    fn declArityOf(self: *const Module, id: FuncId) ?u32 {
        return self.decl_user_params.get(id.int());
    }


    /// The declared-arity fallback, reproducing `expr.zig`'s
    /// `fallbackByDeclArity`: the order-based `funcId` pick when its declared
    /// arity fits (or is unknown), otherwise a same-declared-arity candidate,
    /// with the out-of-scope-fallback-over-in-scope-extension and the
    /// all-extension-zero-arity guards. Covers the header-stub / intrinsic-
    /// backed forms the body-only ladder cannot rank. The alias gate stays
    /// caller-side (a bare alias with no ladder pick leaves the legacy target
    /// null, which the audit does not compare).
    /// Whether a candidate's DECLARED signature can bind the call's argument
    /// shapes. The declared-arity fallback ranks header stubs the body-only
    /// ladder cannot see; without this check it picks by arity alone and an
    /// `Int` argument binds a same-arity `String` parameter (`Box(s.length)`
    /// inside `fun Box(s: String)` self-recursing past the constructor). No
    /// signature view, or no refuting evidence, keeps the candidate.
    pub fn declSigScore(self: *const Module, fid: FuncId, args: []const applicability.ArgShape) ?applicability.Score {
        const sv = self.sigViewForApplicability(fid) orelse return .{ .points = 0 };
        return applicability.applicable(&sv, args, .{});
    }

    pub fn declSigCompatible(self: *const Module, fid: FuncId, args: []const applicability.ArgShape) bool {
        return self.declSigScore(fid, args) != null;
    }

    /// Among the exact-declared-arity, non-extension candidates, the one whose
    /// `FunctionN`-headed parameters best fit the call's lambda LITERALS:
    /// exact header-count match scores highest, a headerless literal (arity
    /// 0) serving a 1-param type via implicit `it` just below. Null unless a
    /// single candidate strictly wins with positive functional evidence, so
    /// evidence-free calls keep the established fallback order.
    fn fnArityBestPick(self: *const Module, name: []const u8, want_arity: u32, args: []const applicability.ArgShape, ctx_owner: ?[]const u8) ?FuncId {
        var any_literal = false;
        for (args) |a| {
            if (a.lambda_is_literal and a.lambda_arity != null) any_literal = true;
        }
        if (!any_literal) return null;
        var best: ?FuncId = null;
        var best_score: i32 = 0;
        var tied = false;
        for (self.funcsBySimpleName(name)) |fid| {
            if (self.funcById(fid)) |ff| if (ff.low_priority) continue;
            if (!self.isNonExtFid(fid)) continue;
            if (self.memberExtOutOfScope(fid, ctx_owner)) continue;
            if (self.declArityOf(fid) != want_arity) continue;
            const f = self.funcById(fid) orelse continue;
            const sv = self.sigViewOf(fid, f) orelse continue;
            if (sv.len() != args.len) continue;
            var score: i32 = 0;
            for (args, 0..) |a, i| {
                if (!a.lambda_is_literal) continue;
                const got = a.lambda_arity orelse continue;
                const head = sv.at(i).name;
                const hn = if (std.mem.lastIndexOfScalar(u8, head, '.')) |dot| head[dot + 1 ..] else head;
                if (!std.mem.startsWith(u8, hn, "Function")) continue;
                const want = std.fmt.parseInt(usize, hn["Function".len..], 10) catch continue;
                if (got == want) {
                    score += 3;
                } else if (got == 0 and want == 1) {
                    score += 2;
                } else {
                    score -= 1;
                }
            }
            if (score > best_score) {
                best = fid;
                best_score = score;
                tied = false;
            } else if (score == best_score and best != null) {
                tied = true;
            }
        }
        if (tied) return null;
        return best;
    }

    fn phaseBFallback(self: *const Module, name: []const u8, caller_pkg: []const u8, caller_file: FileId, want: usize, args: []const applicability.ArgShape, ctx_owner: ?[]const u8, receiver_known: bool) ?FuncId {
        // A `@Deprecated(level = ERROR|HIDDEN)` / `@LowPriorityInOverloadResolution`
        // overload is not a source-level candidate (kotlinc hides it; it exists
        // only for binary compatibility). The index and `phaseBLadder` already
        // skip it; the declared-arity fallback must too, or a bare call whose
        // arity matches ONLY the hidden overload (`lightColorScheme(primary =
        // c)` — the hidden binary-compat form has the same leading params)
        // statically binds it, and a hidden form that delegates to the real
        // overload by name self-recurses.
        const fallback = blk: {
            const f = self.funcIdForBareCall(name, ctx_owner) orelse break :blk null;
            if (self.funcById(f)) |ff| {
                if (ff.low_priority) break :blk null;
                if (funcHasImplicitThis(ff) and receiver_known and
                    !self.extReceiverPlausible(f, ff, ctx_owner)) break :blk null;
            }
            break :blk f;
        };
        const want_u32: u32 = @intCast(want);
        const fallback_fits = blk: {
            if (fallback) |fid| {
                if (self.declArityOf(fid)) |n| break :blk n == want_u32 and self.declSigCompatible(fid, args);
            } else break :blk false;
            break :blk true;
        };
        if (fallback) |fid| {
            const tier = self.bareCallTierOf(fid, name, caller_pkg, caller_file) orelse 255;
            if (tier == other_package_tier) {
                for (self.funcsBySimpleName(name)) |cid| {
                    if (self.funcById(cid)) |cf| if (cf.low_priority) continue;
                    if (self.isNonExtFid(cid)) continue;
                    if (self.memberExtOutOfScope(cid, ctx_owner)) continue;
                    if (self.declArityOf(cid) != want_u32) continue;
                    if (!self.declSigCompatible(cid, args)) continue;
                    const ct = self.bareCallTierOf(cid, name, caller_pkg, caller_file) orelse continue;
                    if (ct < other_package_tier) return cid;
                }
            }
        }
        // Same-name overloads that differ ONLY in a functional parameter's
        // arity (`movableContentOf` takes `() -> Unit` … `(P1..P4) -> Unit`,
        // all user arity 1): the order-based fallback blind-binds one, and
        // `declSigCompatible` keeps every stub. When the call carries a
        // LAMBDA LITERAL, rank the declared-arity candidates by how their
        // `FunctionN` param heads fit the literal's header count and bind a
        // strictly-best candidate. Ties (including no functional evidence)
        // fall through to the established order.
        if (self.fnArityBestPick(name, want_u32, args, ctx_owner)) |pick| return pick;
        if (fallback_fits) return fallback;
        for (self.funcsBySimpleName(name)) |fid| {
            if (self.funcById(fid)) |ff| if (ff.low_priority) continue;
            if (self.isNonExtFid(fid) and self.declArityOf(fid) == want_u32 and self.declSigCompatible(fid, args)) return fid;
        }
        for (self.funcsBySimpleName(name)) |fid| {
            if (self.funcById(fid)) |ff| {
                if (ff.low_priority) continue;
                if (funcHasImplicitThis(ff) and receiver_known and
                    !self.extReceiverPlausible(fid, ff, ctx_owner)) continue;
            }
            if (self.memberExtOutOfScope(fid, ctx_owner)) continue;
            if (!self.isNonExtFid(fid) and self.declArityOf(fid) == want_u32 and self.declSigCompatible(fid, args)) return fid;
        }
        if (want > 0) {
            var all_ext_zero_arity = self.funcsBySimpleName(name).len != 0;
            for (self.funcsBySimpleName(name)) |fid| {
                if (self.isNonExtFid(fid) or self.declArityOf(fid) != 0) {
                    all_ext_zero_arity = false;
                    break;
                }
            }
            if (all_ext_zero_arity) return null;
        }
        // No exact-arity candidate fit: a UNIQUE overload whose vararg
        // absorbs the surplus is Kotlin's pick — a plugin-threaded
        // `remember(k1..k4, calculation, $composer, $changed)` (7 args) can
        // only be the `vararg keys` overload, never the first-declared
        // zero-key one the plain fallback would blind-bind.
        if (fallback != null and !fallback_fits) {
            var only: ?FuncId = null;
            var count: usize = 0;
            for (self.funcsBySimpleName(name)) |fid| {
                if (self.funcById(fid)) |ff| if (ff.low_priority) continue;
                if (self.memberExtOutOfScope(fid, ctx_owner)) continue;
                if (!self.varargArityFits(fid, want)) continue;
                only = fid;
                count += 1;
                if (count > 1) break;
            }
            if (count == 1) return only;
        }
        return fallback;
    }

    /// Whether `id` declares a vararg and can absorb a `want`-argument call:
    /// at least the required (non-defaulted, non-vararg) parameter count.
    /// The exact-arity helpers deliberately exclude vararg candidates; this
    /// is their positive complement for the no-exact-fit fallback.
    fn varargArityFits(self: *const Module, id: FuncId, want: usize) bool {
        if (self.decl_sigs.get(id.int())) |ds| {
            if (!ds.has_body and !ds.host_backed) return false;
            if (!ds.arity.has_vararg) return false;
            return want >= ds.arity.required;
        }
        const f = self.funcById(id) orelse return false;
        if (!f.hasBody()) return false;
        // Defaults live on ProgramImage, not here: count every non-vararg
        // param as required. Conservative — a defaulted param only ever
        // RAISES this bound, so a fit found here is always a real fit.
        var has_vararg = false;
        var required: usize = 0;
        for (f.params, 0..) |p, i| {
            if (i == 0 and std.mem.eql(u8, p.name, "this")) continue;
            if (p.is_vararg) {
                has_vararg = true;
                continue;
            }
            required += 1;
        }
        return has_vararg and want >= required;
    }

    /// Index-refined target: the heuristic's ladder pick refined by the
    /// index's unique FQN target, except a receiver-matched extension the
    /// index (blind to receivers) would override with its non-extension
    /// namesake, which the extension retains (`preferredBareTarget`).
    fn preferredBareTargetLike(
        self: *const Module,
        heur: FuncId,
        index_pick: ?FuncId,
        name: []const u8,
        caller_pkg: []const u8,
        caller_file: FileId,
        args: []const applicability.ArgShape,
    ) FuncId {
        const idx = index_pick orelse return heur;
        if (!self.isNonExtFid(heur) and self.isNonExtFid(idx)) return heur;
        // The index ranks package and arity but not argument types. Within
        // the same scope tier it must not replace the applicability pick with
        // a candidate the static argument shape disproves. This occurs when
        // a trailing lambda binds a default-gap function parameter while a
        // sibling overload has the same positional arity but a scalar head.
        const hf = self.funcById(heur);
        const inf = self.funcById(idx);
        if (hf != null and inf != null and
            self.bareCallTier(hf.?, name, caller_pkg, caller_file) ==
                self.bareCallTier(inf.?, name, caller_pkg, caller_file) and
            !self.declSigCompatible(idx, args))
        {
            return heur;
        }
        return idx;
    }

    /// The in-scope candidate set (scopeTier <= `tier`) in sig-index order,
    /// borrowed from `alloc`. Carried on the virtual / deferred forms for the
    /// runtime member-first walk and the ambiguity / out-of-scope diagnostics.
    fn candidateSet(
        self: *const Module,
        alloc: std.mem.Allocator,
        name: []const u8,
        caller_pkg: []const u8,
        caller_file: FileId,
        tier: u8,
    ) std.mem.Allocator.Error![]const FuncId {
        if (tier == 255) return &.{};
        var list: std.ArrayList(FuncId) = .empty;
        for (self.funcsBySimpleName(name)) |id| {
            const f = self.funcById(id) orelse continue;
            if (self.bareCallTier(f, name, caller_pkg, caller_file) <= tier)
                try list.append(alloc, id);
        }
        return list.toOwnedSlice(alloc);
    }

    /// The authoritative package/import-scoped callable set for a deferred
    /// bare call. `null` means the module has no complete, rankable declaration
    /// set for `name` (the remaining host-only/incomplete-header boundary); a
    /// non-null slice is bounded by Kotlin visibility, and may be empty when
    /// rankable declarations exist but none are visible from this site.
    pub fn boundedCallCandidates(
        self: *const Module,
        alloc: std.mem.Allocator,
        name: []const u8,
        caller_pkg_in: []const u8,
        caller_file: FileId,
        user_arg_count: usize,
    ) std.mem.Allocator.Error!?[]const FuncId {
        if (self.funcsBySimpleName(name).len == 0) return null;
        const caller_pkg = self.packageOfFile(caller_file) orelse caller_pkg_in;
        const first_tier = self.lowestVisibleGlobalTier(name, caller_pkg, caller_file);
        if (first_tier == 255) return null;
        if (first_tier >= other_package_tier) {
            return try alloc.alloc(FuncId, 0);
        }
        var list: std.ArrayList(FuncId) = .empty;
        var any_arity_match = false;
        for (self.funcsBySimpleName(name)) |id| {
            const f = self.funcById(id) orelse continue;
            if (self.declarationKind(id, f) != .plain) continue;
            if (self.bareCallTier(f, name, caller_pkg, caller_file) >= other_package_tier) continue;
            try list.append(alloc, id);
            if (self.globalArityCanBind(id, f, user_arg_count)) any_arity_match = true;
        }
        if (!any_arity_match) {
            list.deinit(alloc);
            return null;
        }
        return @as(?[]const FuncId, try list.toOwnedSlice(alloc));
    }

    /// The authoritative package/import-scoped overload set for a bare call
    /// containing a spread argument. Scope is chosen before applicability and
    /// only declarations with a `vararg` parameter survive: Kotlin never lets
    /// a spread bind a fixed parameter. A non-null empty slice means the
    /// winning scope tier has declarations for the name but no vararg target;
    /// callers must diagnose that miss rather than widen to another package.
    pub fn boundedSpreadCandidates(
        self: *const Module,
        alloc: std.mem.Allocator,
        name: []const u8,
        caller_pkg_in: []const u8,
        caller_file: FileId,
    ) std.mem.Allocator.Error!?[]const FuncId {
        if (self.funcsBySimpleName(name).len == 0) return null;
        const caller_pkg = self.packageOfFile(caller_file) orelse caller_pkg_in;
        const tier = self.lowestVisibleGlobalTier(name, caller_pkg, caller_file);
        if (tier == 255) return null;
        if (tier >= other_package_tier) return try alloc.alloc(FuncId, 0);

        var list: std.ArrayList(FuncId) = .empty;
        for (self.funcsBySimpleName(name)) |id| {
            const f = self.funcById(id) orelse continue;
            if (self.declarationKind(id, f) != .plain) continue;
            if (self.bareCallTier(f, name, caller_pkg, caller_file) > tier) continue;
            if (!self.declarationHasVararg(id, f)) continue;
            try list.append(alloc, id);
        }
        return @as(?[]const FuncId, try list.toOwnedSlice(alloc));
    }

    /// Header registration records the declaration kind before a function body
    /// is placed. During that window the placeholder `Func.kind` may still be
    /// its default `.plain`; resolution must trust the canonical declaration
    /// record so extension headers never enter a receiverless global set.
    fn declarationKind(self: *const Module, id: FuncId, f: *const Func) FuncKind {
        if (self.decl_sigs.get(id.int())) |ds| return ds.kind;
        return f.kind;
    }

    fn declarationHasVararg(self: *const Module, id: FuncId, f: *const Func) bool {
        if (self.decl_sigs.get(id.int())) |ds| return ds.arity.has_vararg;
        if (self.stubDeclArity(id)) |arity| return arity.has_vararg;
        return anyParamVararg(f);
    }

    /// Whether declaration metadata proves that a receiverless call count can
    /// bind. If no scoped declaration can bind, the host/incomplete-header
    /// compatibility boundary remains active until P10 supplies a complete
    /// declaration for the host shape.
    fn globalArityCanBind(self: *const Module, id: FuncId, f: *const Func, want: usize) bool {
        if (self.decl_sigs.get(id.int())) |ds| {
            if (want < ds.arity.required) return false;
            return ds.arity.has_vararg or want <= ds.arity.total;
        }
        var required: usize = 0;
        var total: usize = 0;
        var has_vararg = false;
        for (f.params) |p| {
            total += 1;
            if (p.is_vararg) {
                has_vararg = true;
            } else if (!p.has_default) {
                required += 1;
            }
        }
        if (want < required) return false;
        return has_vararg or want <= total;
    }

    /// The best visible tier among receiverless package-scope functions.
    /// Members and extensions are handled by the receiver leg of
    /// `CallMemberOrGlobal`; allowing them to establish this tier would let an
    /// own-class test method hide an imported top-level function from the
    /// terminal global leg.
    fn lowestVisibleGlobalTier(self: *const Module, name: []const u8, caller_pkg: []const u8, caller_file: FileId) u8 {
        var best: u8 = 255;
        for (self.funcsBySimpleName(name)) |id| {
            const f = self.funcById(id) orelse continue;
            if (self.declarationKind(id, f) != .plain) continue;
            if (!f.hasBody() and self.stubDeclArity(id) == null) continue;
            const t = self.bareCallTier(f, name, caller_pkg, caller_file);
            if (t < best) best = t;
        }
        return best;
    }

    /// The lowest scope tier among the rankable (body, or stub with a declared
    /// arity record) candidates named `name`, or 255 when none exists.
    fn lowestVisibleTier(self: *const Module, name: []const u8, caller_pkg: []const u8, caller_file: FileId) u8 {
        var best: u8 = 255;
        for (self.funcsBySimpleName(name)) |id| {
            const f = self.funcById(id) orelse continue;
            if (!f.hasBody() and self.stubDeclArity(id) == null) continue;
            const t = self.bareCallTier(f, name, caller_pkg, caller_file);
            if (t < best) best = t;
        }
        return best;
    }

    /// Resolve a bare `name` call to a `Resolution{ target, confidence,
    /// emit_form, candidate_set }` — a pure function of (call site, sig index,
    /// receiver context). The INDEX (`resolveBareCallIndexed`) establishes the
    /// winning tier and unique FQN target; the APPLICABILITY ladder ranks the
    /// tier; the emit form is derived from `(outcome, ctx)` exactly once.
    ///
    /// While the legacy lowering ladder stays authoritative (the audited
    /// migration), `resolveCall` reproduces its pick: the heuristic ladder is
    /// the primary selector and the index refines it through
    /// `preferredBareTargetLike`, exactly as `lowerPathCall` does today. The
    /// flip to index-primary is a later slice.
    pub fn resolveCall(
        self: *const Module,
        alloc: std.mem.Allocator,
        name: []const u8,
        caller_pkg_in: []const u8,
        caller_file: FileId,
        args: []const applicability.ArgShape,
        last_arg_lambda: bool,
        ctx: ResolveCtx,
    ) std.mem.Allocator.Error!Resolution {
        // Same file-follows-span package rule as `resolveBareCallIndexed`.
        const caller_pkg = self.packageOfFile(caller_file) orelse caller_pkg_in;
        // Phase A — INDEX (authoritative when it resolves a unique FQN target).
        var ires = self.resolveBareCallIndexed(name, caller_pkg, caller_file, args.len, last_arg_lambda);
        if (ctx.cast_pick != null) {
            switch (ires.outcome) {
                .deferred => |r| {
                    if (r == .ambiguous_tier or r == .type_overload)
                        ires.outcome = .{ .deferred = .cast_disambiguated };
                },
                .resolved => {},
            }
        }
        const reason: ?ResolveDeferReason = switch (ires.outcome) {
            .resolved => null,
            .deferred => |r| r,
        };
        const index_pick = ires.pick();

        // Phase B — APPLICABILITY ladder. A cast at the call site pre-picks the
        // overload; otherwise the applicable() ladder ranks the body candidates,
        // then a declared-arity fallback covers the header-stub / intrinsic-
        // backed forms the ladder (body-only) cannot rank.
        var heur: ?FuncId = if (ctx.cast_pick) |cp| cp else self.phaseBLadder(name, args, caller_pkg, caller_file, ctx.owner_class, ctx.receiver_known);
        if (heur == null and ctx.cast_pick == null and
            (!isAliasName(name) or self.hasHostBackedCandidate(name)))
        {
            heur = self.phaseBFallback(name, caller_pkg, caller_file, args.len, args, ctx.owner_class, ctx.receiver_known);
        }
        // Prefer the same-name extension overload whose declared receiver
        // matches the enclosing extension's receiver.
        var heur_recv_matched = false;
        if (heur) |chosen| {
            if (ctx.recv_ty) |recv| {
                if (self.matchesRecvFid(chosen, recv)) {
                    heur_recv_matched = true;
                } else {
                    for (self.funcsBySimpleName(name)) |cid| {
                        if (self.memberExtOutOfScope(cid, ctx.owner_class)) continue;
                        if (self.arityMatchFid(cid, args.len) and self.matchesRecvFid(cid, recv)) {
                            // Receiver preference never overrides argument
                            // applicability: a candidate one of the args'
                            // type evidence excludes is not Kotlin's pick
                            // no matter how well its receiver matches.
                            if (self.sigViewForApplicability(cid)) |sv| {
                                if (applicability.applicable(&sv, args, .{}) == null) continue;
                            }
                            heur = cid;
                            heur_recv_matched = true;
                            break;
                        }
                    }
                }
            }
        }

        // A receiver-matched pick is Kotlin's static resolution: inside
        // `FlowCollector<T>.emitAllImpl`, bare `ensureActive()` binds the
        // FlowCollector extension, never the Job one the index may have
        // ranked first. Only an index pick with the SAME declared receiver
        // may still take precedence.
        // A phase-B pick that is an EXTENSION whose declared receiver no
        // statically-known receiver could supply is not Kotlin's target
        // (`TestScope.runTest` inside a plain test class). Drop it to a
        // deferred emit so the runtime resolves against real values, unless
        // a plausible sibling can be re-picked below.
        if (heur) |h| {
            if (ctx.receiver_known and ctx.cast_pick == null) {
                if (self.funcById(h)) |hf| {
                    if (funcHasImplicitThis(hf) and !self.extReceiverPlausible(h, hf, ctx.owner_class)) {
                        heur = null;
                    }
                }
            }
        }
        if (runtime.getenvSlice("KLIO_EXT_TRACE")) |w| {
            if (std.mem.eql(u8, w, name)) std.debug.print("[rescall] {s} heur={?d} idx={?d} recv_known={} owner={?s}\n", .{ name, if (heur) |h| h.int() else null, if (index_pick) |ip| ip.int() else null, ctx.receiver_known, ctx.owner_class });
        }
        const target: ?FuncId = if (heur) |h| blk: {
            if (heur_recv_matched) {
                const idx_also_matches = if (index_pick) |ip|
                    self.matchesRecvFid(ip, ctx.recv_ty.?)
                else
                    false;
                if (!idx_also_matches) break :blk h;
            }
            break :blk self.preferredBareTargetLike(h, index_pick, name, caller_pkg, caller_file, args);
        } else null;
        // A `@LowPriorityInOverloadResolution` / deprecated-stub function never
        // statically binds when a same-name class constructor exists: kotlinc
        // ranks the constructor above it, and a stub whose body re-calls the
        // name (kotlinx-datetime's `fun LocalDateTime(...) = LocalDateTime(...)`)
        // would self-recurse. Drop to a dynamic emit so runtime binds the
        // constructor. The index never resolves TO a low-priority candidate
        // (it skips them), so this only overrides a phase-B heuristic pick.
        const target_lp: ?FuncId = if (target) |t| blk: {
            const tf = self.funcById(t) orelse break :blk t;
            if (tf.low_priority and self.classId(name) != null) break :blk null;
            break :blk t;
        } else null;
        const tier: u8 = if (ires.tier != 255) ires.tier else self.lowestVisibleTier(name, caller_pkg, caller_file);

        // Phase C — EMIT FORM.
        var res = try self.emitFormFor(alloc, name, caller_pkg, caller_file, target_lp, tier, reason, ires.tier_count, args, ctx);
        if (res.emit_form == .Call) {
            // A declared-receiver-matched extension pick is Kotlin's static
            // resolution — final like a cast pick; the runtime value-typed
            // re-pick must not override it (a fun-interface receiver arrives
            // as a plain closure and would mis-score against unrelated
            // receiver types).
            const recv_final = heur_recv_matched and if (res.target) |t|
                (if (heur) |h| t.int() == h.int() else false)
            else
                false;
            if (res.target) |t| {
                res.ty_proven = self.tyProvenPick(t, args) or recv_final or
                    self.uniqueHostBackedPick(t, name, caller_pkg, caller_file, args);
            }
        }
        return res;
    }

    fn hasHostBackedCandidate(self: *const Module, name: []const u8) bool {
        for (self.funcsBySimpleName(name)) |id| {
            if (self.decl_sigs.get(id.int())) |ds| {
                if (ds.host_backed) return true;
            }
        }
        return false;
    }

    /// A unique applicable host declaration is overload-final at lowering.
    /// This makes the exact FuncId call skip the VM's value-typed overload
    /// retry while preserving that retry for source families whose static
    /// evidence is still incomplete.
    fn uniqueHostBackedPick(
        self: *const Module,
        target: FuncId,
        name: []const u8,
        caller_pkg: []const u8,
        caller_file: FileId,
        args: []const applicability.ArgShape,
    ) bool {
        const target_sig = self.decl_sigs.get(target.int()) orelse return false;
        if (!target_sig.host_backed) return false;
        const target_func = self.funcById(target) orelse return false;
        const tier = self.bareCallTier(target_func, name, caller_pkg, caller_file);
        var applicable_count: usize = 0;
        for (self.funcsBySimpleName(name)) |id| {
            const f = self.funcById(id) orelse continue;
            const ds = self.decl_sigs.get(id.int()) orelse continue;
            if (!ds.host_backed or ds.kind != .plain) continue;
            if (self.bareCallTier(f, name, caller_pkg, caller_file) != tier) continue;
            const sv = self.sigViewForApplicability(id) orelse continue;
            if (applicability.applicable(&sv, args, .{}) == null) continue;
            applicable_count += 1;
            if (applicable_count > 1) return false;
        }
        return applicable_count == 1;
    }

    /// Whether every positional argument carries declared-type evidence whose
    /// head proves the target's parameter (see `Resolution.ty_proven`). Exact
    /// arity, all-positional, no runtime shapes — the strict form only.
    fn tyProvenPick(self: *const Module, id: FuncId, args: []const applicability.ArgShape) bool {
        if (args.len == 0) return false;
        const f = self.funcById(id) orelse return false;
        const off: usize = if (funcHasImplicitThis(f)) 1 else 0;
        if (f.params.len - off != args.len) return false;
        for (args, 0..) |*a, i| {
            if (a.named != null or a.runtime_class != null) return false;
            const aty = a.ty orelse return false;
            const s = applicability.tyEvidenceScore(f.params[off + i].ty.name, aty.name, false) orelse return false;
            if (s < 100) return false;
        }
        return true;
    }

    /// Whether a bare call binding target `id` is a tail call: exactly when
    /// the committed target itself is `tailrec`. (The name-list arm this
    /// replaced could mark a call to a non-tailrec target as a tail call
    /// just because a same-name sibling was tailrec.)
    fn calleeIsTailrec(self: *const Module, id: FuncId, name: []const u8) bool {
        _ = name;
        if (self.funcById(id)) |f| {
            if (f.is_tailrec) return true;
        }
        return false;
    }

    /// Phase C — the single member-vs-global decision, folding the receiver
    /// gates once. `Call → exact`, `CallMember`/`CallMemberOrGlobal → virtual`
    /// (target non-null) or `deferred` (target null), `CallValue → deferred`.
    fn emitFormFor(
        self: *const Module,
        alloc: std.mem.Allocator,
        name: []const u8,
        caller_pkg: []const u8,
        caller_file: FileId,
        target: ?FuncId,
        tier: u8,
        reason: ?ResolveDeferReason,
        tier_count: usize,
        args: []const applicability.ArgShape,
        ctx: ResolveCtx,
    ) std.mem.Allocator.Error!Resolution {
        const member_shadowable = ctx.unknown_receiver or ctx.enclosing_has_member or
            (!ctx.receiver_known and self.registry.class_member_names.contains(name));
        const cast_static = if (ctx.cast_pick) |cp| (if (target) |t| cp.int() == t.int() else false) else false;
        if (target) |t| {
            const is_ext = if (self.funcById(t)) |f| funcHasImplicitThis(f) else false;
            if (is_ext) {
                // Extension member-first defer: in a receiver context a member of
                // the implicit receiver could shadow the extension, so it
                // dispatches member-first. Unlike the non-extension gate, a cast
                // or explicit type arguments do NOT suppress this.
                if (ctx.in_receiver_context and member_shadowable) {
                    const cs = try self.candidateSet(alloc, name, caller_pkg, caller_file, tier);
                    return .{ .target = t, .confidence = .virtual, .emit_form = .CallMemberOrGlobal, .candidate_set = cs, .reason = reason, .tier = tier, .tier_count = tier_count };
                }
                // Static-receiver extension bind: a cast keeps the static Call,
                // otherwise the member-precedence CallMember on `this`.
                if (cast_static) {
                    return .{ .target = t, .confidence = .exact, .emit_form = .Call, .reason = reason, .tier = tier, .tier_count = tier_count };
                }
                return .{ .target = t, .confidence = .virtual, .emit_form = .CallMember, .reason = reason, .tier = tier, .tier_count = tier_count };
            }
            // A positional tail call to a tailrec target from a tailrec body
            // emits a static `Call` (lowered to a `TailCallFunc`), ahead of the
            // member-shadowable gate — a tail call is never redispatched.
            if (ctx.in_tailrec_body and self.calleeIsTailrec(t, name) and allShapeNamesNull(args)) {
                return .{ .target = t, .confidence = .exact, .emit_form = .Call, .reason = reason, .tier = tier, .tier_count = tier_count };
            }
            // Non-extension: the member-shadowable gate, suppressed by a cast or
            // explicit type arguments (the static-resolution forms).
            const static_ok = cast_static or ctx.has_type_args or
                (ctx.nonlocal_return_lambda and self.funcIsInline(t));
            const shadow = ctx.in_receiver_context and member_shadowable and !static_ok;
            if (runtime.getenvSlice("KLIO_EF_TRACE")) |w| {
                if (std.mem.eql(u8, w, name)) std.debug.print("[ef] {s} t={d} inline={} nlr={} recvctx={} shadowable={} shadow={} file={d}\n", .{ name, t.int(), self.funcIsInline(t), ctx.nonlocal_return_lambda, ctx.in_receiver_context, member_shadowable, shadow, caller_file.int() });
            }
            if (!shadow) {
                return .{ .target = t, .confidence = .exact, .emit_form = .Call, .reason = reason, .tier = tier, .tier_count = tier_count };
            }
            const cs = try self.candidateSet(alloc, name, caller_pkg, caller_file, tier);
            return .{ .target = t, .confidence = .virtual, .emit_form = .CallMemberOrGlobal, .candidate_set = cs, .reason = reason, .tier = tier, .tier_count = tier_count };
        }
        if (ctx.is_value_capture) {
            return .{ .target = null, .confidence = .deferred, .emit_form = .CallValue, .reason = reason, .tier = tier, .tier_count = tier_count };
        }
        if (ctx.in_receiver_context) {
            const cs = try self.candidateSet(alloc, name, caller_pkg, caller_file, tier);
            return .{ .target = null, .confidence = .deferred, .emit_form = .CallMemberOrGlobal, .candidate_set = cs, .reason = reason, .tier = tier, .tier_count = tier_count };
        }
        return .{ .target = null, .confidence = .deferred, .emit_form = .CallValue, .reason = reason, .tier = tier, .tier_count = tier_count };
    }

    /// Value-position bare-reference resolution: resolve `name` (a bare
    /// identifier read, not a call) to a unique `FuncId` under the same
    /// scope tiers as `resolveBareCallIndexed`, with no arity filter — a
    /// reference denotes the declaration itself, so a vararg or
    /// defaulted signature is as referenceable as any other. Extension
    /// forms never resolve (a bare read cannot supply the receiver),
    /// intrinsic-owned names defer to the lowerer's intrinsic routing,
    /// and the winning tier must hold exactly one candidate. A phase-1
    /// header stub resolves too: its FQN is final and phase-2 fills the
    /// same slot, so the answer is declaration-order independent.
    pub fn resolveBareRefIndexed(
        self: *const Module,
        name: []const u8,
        caller_pkg: []const u8,
        caller_file: FileId,
    ) ?FuncId {
        const cands = self.funcsBySimpleName(name);
        if (cands.len == 0) return null;
        var best_tier: u8 = 255;
        for (cands) |id| {
            const f = self.funcById(id) orelse continue;
            if (funcHasImplicitThis(f)) continue;
            if (!f.hasBody() and self.stubDeclArity(id) == null) continue;
            const t = self.bareCallTier(f, name, caller_pkg, caller_file);
            if (t < best_tier) best_tier = t;
        }
        if (best_tier == 255) return null;
        var chosen: ?FuncId = null;
        var count: usize = 0;
        for (cands) |id| {
            const f = self.funcById(id) orelse continue;
            if (funcHasImplicitThis(f)) continue;
            if (!f.hasBody() and self.stubDeclArity(id) == null) continue;
            if (self.bareCallTier(f, name, caller_pkg, caller_file) != best_tier) continue;
            if (chosen == null) chosen = id;
            count += 1;
        }
        if (count == 1) return chosen;
        return null;
    }

    /// The best (lowest) scope tier among the value-referenceable
    /// non-extension funcs of `name` at a reference site, or `null` when
    /// no such func exists. A value reference (`::name` / a bare read)
    /// denotes the declaration itself, so this ranks under the same
    /// scoping order as `resolveBareRefIndexed` but ignores arity and
    /// uniqueness. `other_package_tier` means every candidate lives in a
    /// package the caller neither declares, imports, nor sees by default
    /// or via the shipped surface — Kotlin does not resolve such a
    /// reference at all, so the lowerer rejects it (kotlinc:
    /// `unresolved reference`).
    pub fn bareRefTier(
        self: *const Module,
        name: []const u8,
        caller_pkg: []const u8,
        caller_file: FileId,
    ) ?u8 {
        const cands = self.funcsBySimpleName(name);
        if (cands.len == 0) return null;
        var best_tier: u8 = 255;
        for (cands) |id| {
            const f = self.funcById(id) orelse continue;
            if (funcHasImplicitThis(f)) continue;
            if (!f.hasBody() and self.stubDeclArity(id) == null) continue;
            const t = self.bareCallTier(f, name, caller_pkg, caller_file);
            if (t < best_tier) best_tier = t;
        }
        if (best_tier == 255) return null;
        return best_tier;
    }

    /// The best (lowest) scope tier among the classes named `name` at a
    /// reference site, or `null` when no such class exists. Mirrors
    /// `bareRefTier` for `::Ctor` callable references and bare type-name
    /// value reads; `other_package_tier` means the only matching class is
    /// in an unimported package.
    pub fn classRefTier(
        self: *const Module,
        name: []const u8,
        caller_pkg: []const u8,
        caller_file: FileId,
    ) ?u8 {
        var best_tier: u8 = 255;
        for (self.class_index.items) |entry| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            const c = idGet(Class, self.classes.items, entry.id.int()) orelse continue;
            const t = self.scopeTier(c.fqn, c.package, name, caller_pkg, caller_file);
            if (t < best_tier) best_tier = t;
        }
        if (best_tier == 255) return null;
        return best_tier;
    }

    /// The best (lowest) scope tier among the top-level property
    /// declarations named `name` at a reference site, or `null` when no
    /// such property is known. A bare property read resolves under the
    /// same Kotlin scoping order as a call; `other_package_tier` means
    /// every declaration is in an unimported package, so kotlinc rejects
    /// the read as unresolved.
    pub fn topLevelPropRefTier(
        self: *const Module,
        name: []const u8,
        caller_pkg: []const u8,
        caller_file: FileId,
    ) ?u8 {
        const list = self.registry.top_level_prop_pkgs.get(name) orelse return null;
        var best_tier: u8 = 255;
        for (list.items) |pd| {
            const t = self.scopeTier(pd.fqn, pd.package, name, caller_pkg, caller_file);
            if (t < best_tier) best_tier = t;
        }
        if (best_tier == 255) return null;
        return best_tier;
    }

    /// The literal value of the top-level `const val` a bare reference to
    /// `name` resolves to at this site, or null when the best-scoped
    /// declaration is not a recorded compile-time constant (or the pick is
    /// ambiguous). Kotlin inlines const vals at every reference; emitting
    /// the literal keeps the read immune to the flat runtime global table,
    /// where a same-simple-name value from another module can win.
    pub fn topLevelConstLiteral(
        self: *const Module,
        name: []const u8,
        caller_pkg: []const u8,
        caller_file: FileId,
    ) ?Const {
        const list = self.registry.top_level_prop_pkgs.get(name) orelse return null;
        var best_tier: u8 = 255;
        var best_fqn: ?[]const u8 = null;
        var ambiguous = false;
        for (list.items) |pd| {
            const t = self.scopeTier(pd.fqn, pd.package, name, caller_pkg, caller_file);
            if (t < best_tier) {
                best_tier = t;
                best_fqn = pd.fqn;
                ambiguous = false;
            } else if (t == best_tier and best_fqn != null and !std.mem.eql(u8, best_fqn.?, pd.fqn)) {
                ambiguous = true;
            }
        }
        if (ambiguous or best_tier == 255) return null;
        const fqn = best_fqn orelse return null;
        return self.registry.top_level_const_vals.get(fqn);
    }

    /// The FQN of the first known top-level property declaration named
    /// `name`, for an out-of-scope value-reference diagnostic.
    pub fn topLevelPropFqn(self: *const Module, name: []const u8) ?[]const u8 {
        const list = self.registry.top_level_prop_pkgs.get(name) orelse return null;
        if (list.items.len == 0) return null;
        return list.items[0].fqn;
    }

    /// Register a class declaration and return its id. If the name
    /// was previously `reserveClass`d, the reserved slot/id is reused
    /// so forward references that resolved to that id stay valid.
    pub fn addClass(self: *Module, allocator: Allocator, class_in: Class) Allocator.Error!ClassId {
        var class = class_in;
        // Match the reserved stub / a prior lowering by FULLY-QUALIFIED name,
        // not simple name: two classes that share a simple name in different
        // packages each keep their own slot (a `reserveClassFqn` pre-pass gives
        // both a distinct stub up front so neither shadows the other at its own
        // construction sites). A legacy stub reserved without an FQN
        // (`reserveClass`, e.g. a nested class) carries `fqn == simple name`
        // and is claimed only when no exact-FQN slot exists.
        // Fast path: no class with this simple name yet → definitely new, so
        // skip the same-name scan (the common, no-collision case stays cheap).
        if (self.classIndexEntryByName(class.name) != null) {
            var legacy_stub: ?ClassId = null;
            if (self.classNameCandidates(class.name)) |ids| {
                for (ids) |cid| {
                    const existing = &self.classes.items[cid.int()];
                    if (std.mem.eql(u8, existing.fqn, class.fqn)) {
                        class.is_object = class.is_object or existing.is_object;
                        class.id = cid;
                        self.classes.items[cid.int()] = class;
                        return cid;
                    }
                    if (legacy_stub == null and existing.is_stub and std.mem.eql(u8, existing.fqn, class.name)) {
                        legacy_stub = cid;
                    }
                }
            } else for (self.class_index.items) |entry| {
                if (!std.mem.eql(u8, entry.name, class.name)) continue;
                const existing = &self.classes.items[entry.id.int()];
                if (std.mem.eql(u8, existing.fqn, class.fqn)) {
                    class.is_object = class.is_object or existing.is_object;
                    class.id = entry.id;
                    self.classes.items[entry.id.int()] = class;
                    return entry.id;
                }
                if (legacy_stub == null and existing.is_stub and std.mem.eql(u8, existing.fqn, class.name)) {
                    legacy_stub = entry.id;
                }
            }
            if (legacy_stub) |id| {
                class.is_object = class.is_object or self.classes.items[id.int()].is_object;
                class.id = id;
                self.classes.items[id.int()] = class;
                self.fixupStubClaimCaches(id, class.name, class.fqn);
                return id;
            }
        }
        const id = ClassId.from(@intCast(self.classes.items.len));
        class.id = id;
        try self.class_index.append(allocator, .{ .name = class.name, .id = id });
        try self.classes.append(allocator, class);
        return id;
    }

    pub fn classIndexEntryByName(self: *const Module, name: []const u8) ?ClassId {
        if (self.classNameCandidates(name)) |ids| {
            return if (ids.len == 0) null else ids[0];
        }
        for (self.class_index.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.id;
        }
        return null;
    }

    /// Resolve a class by its fully-qualified name. Distinguishes
    /// same-simple-name classes from different packages that
    /// `addClass` keeps as separate definitions.
    /// Sentinel stored in `class_fqn_map` for a duplicated FQN — the lookup
    /// returns null so an ambiguous FQN never silently binds the wrong class.
    const class_id_ambiguous: ClassId = @enumFromInt(std.math.maxInt(u32));

    /// The fully-qualified name of the class with id `id`, or null if out of range.
    pub fn classFqnById(self: *const Module, id: ClassId) ?[]const u8 {
        const c = idGet(Class, self.classes.items, id.int()) orelse return null;
        return c.fqn;
    }

    pub fn classIdByFqn(self: *const Module, fqn: []const u8) ?ClassId {
        if (self.class_fqn_map) |*m| {
            const id = m.get(fqn) orelse return null;
            return if (id == class_id_ambiguous) null else id;
        }
        if (self.classFqnCacheLive()) {
            const mut: *Module = @constCast(self);
            if (mut.topUpClassFqnCache()) {
                const id = mut.class_fqn_cache.get(fqn) orelse return null;
                return if (id == class_id_ambiguous) null else id;
            } else |_| {}
        }
        // Only resolve when the FQN is unambiguous. A residual
        // collision must not silently bind the wrong class.
        var found: ?ClassId = null;
        for (self.classes.items) |c| {
            if (!std.mem.eql(u8, c.fqn, fqn)) continue;
            if (found != null) return null;
            found = c.id;
        }
        return found;
    }

    fn classFqnCacheLive(self: *const Module) bool {
        return self.class_fqn_map == null and !self.class_fqn_cache_dead and
            self.lookup_cache_gpa != null;
    }

    fn topUpClassFqnCache(self: *Module) Allocator.Error!void {
        const gpa = self.lookup_cache_gpa.?;
        while (self.class_fqn_cache_n < self.classes.items.len) : (self.class_fqn_cache_n += 1) {
            const c = self.classes.items[self.class_fqn_cache_n];
            const gop = try self.class_fqn_cache.getOrPut(gpa, c.fqn);
            if (gop.found_existing) {
                if (gop.value_ptr.* != c.id) gop.value_ptr.* = class_id_ambiguous;
            } else gop.value_ptr.* = c.id;
        }
    }

    /// Patch the lookup caches after `addClass` claims a reserved stub —
    /// the one place a class's FQN changes in an existing slot. The FQN
    /// map swaps the stub key for the real one (killing the cache when
    /// the stub key was already ambiguous, where precise repair is
    /// impossible); the package-head set gains the real FQN's prefixes
    /// (prefixes are add-only, so nothing needs removing).
    fn fixupStubClaimCaches(self: *Module, id: ClassId, stub_fqn: []const u8, new_fqn: []const u8) void {
        if (std.mem.eql(u8, stub_fqn, new_fqn)) return;
        const gpa = self.lookup_cache_gpa orelse return;
        if (!self.class_fqn_cache_dead and id.int() < self.class_fqn_cache_n) {
            var dead = false;
            if (self.class_fqn_cache.get(stub_fqn)) |old| {
                if (old == id) {
                    _ = self.class_fqn_cache.remove(stub_fqn);
                } else if (old == class_id_ambiguous) {
                    dead = true;
                }
            }
            if (!dead) {
                if (self.class_fqn_cache.getOrPut(gpa, new_fqn)) |gop| {
                    if (gop.found_existing) {
                        if (gop.value_ptr.* != id) gop.value_ptr.* = class_id_ambiguous;
                    } else gop.value_ptr.* = id;
                } else |_| dead = true;
            }
            if (dead) {
                self.class_fqn_cache.clearRetainingCapacity();
                self.class_fqn_cache_n = 0;
                self.class_fqn_cache_dead = true;
            }
        }
        if (!self.pkg_head_cache_dead and id.int() < self.pkg_head_classes_n) {
            insertFqnPrefixes(&self.pkg_head_cache, gpa, new_fqn) catch {
                self.pkg_head_cache_dead = true;
            };
        }
    }

    /// Whether class `sub` is `super_name` itself, or transitively
    /// extends / implements it, judged over the simple-name hierarchy
    /// recorded at build time (`registry.class_super_names`). Receiver
    /// applicability for extension narrowing: an extension declared on
    /// a base class accepts a subclass receiver.
    pub fn classIsOrExtends(self: *const Module, sub: []const u8, super_name: []const u8) bool {
        if (std.mem.eql(u8, sub, super_name)) return true;
        const supers = self.registry.class_super_names.get(sub) orelse return false;
        for (supers) |s| {
            if (std.mem.eql(u8, s, super_name)) return true;
        }
        return false;
    }

    /// Pre-register a class name so `classId` resolves it before its
    /// body is lowered. Makes cross-class references order-independent.
    /// The placeholder is overwritten by the real definition when
    /// `addClass` runs for the same name. `is_inner` is stamped on the
    /// stub so construction-site lowering reads the right value for a
    /// class whose body has not been lowered yet — the lambda capture
    /// rule for a bare `Inner()` must not depend on declaration order.
    pub fn reserveClass(self: *Module, allocator: Allocator, name: []const u8, is_inner: bool) Allocator.Error!ClassId {
        if (self.classIndexEntryByName(name)) |id| return id;
        const id = ClassId.from(@intCast(self.classes.items.len));
        try self.class_index.append(allocator, .{ .name = name, .id = id });
        try self.classes.append(allocator, .{
            .id = id,
            .name = name,
            .fqn = name,
            .primary_params = &.{},
            .methods = &.{},
            .init_block = null,
            .companion = null,
            .supertypes = &.{},
            .is_inner = is_inner,
            .is_stub = true,
        });
        return id;
    }

    /// Reserve a class placeholder keyed by its FULLY-QUALIFIED name + package.
    /// Unlike `reserveClass` (simple-name dedup), two classes that share a
    /// simple name across packages each get their own stub, so a same-named
    /// class from another pack cannot shadow this one at its construction sites
    /// during the window before its body lowers. Dedups only an exact-FQN
    /// re-reservation of the SAME class.
    pub fn reserveClassFqn(self: *Module, allocator: Allocator, name: []const u8, fqn: []const u8, pkg: []const u8, is_inner: bool) Allocator.Error!ClassId {
        // Fast path: a simple-name collision is rare, so only scan when one
        // exists; otherwise this is definitely a new class.
        if (self.classIndexEntryByName(name) != null) {
            for (self.class_index.items) |entry| {
                if (!std.mem.eql(u8, entry.name, name)) continue;
                if (std.mem.eql(u8, self.classes.items[entry.id.int()].fqn, fqn)) return entry.id;
            }
        }
        const id = ClassId.from(@intCast(self.classes.items.len));
        try self.class_index.append(allocator, .{ .name = name, .id = id });
        try self.classes.append(allocator, .{
            .id = id,
            .name = name,
            .fqn = fqn,
            .package = pkg,
            .primary_params = &.{},
            .methods = &.{},
            .init_block = null,
            .companion = null,
            .supertypes = &.{},
            .is_inner = is_inner,
            .is_stub = true,
        });
        return id;
    }

    /// Append a constant to the pool, returning its id. Today's pool
    /// is unsorted-and-unique by structural equality; lowering passes
    /// can deduplicate when they care.
    ///
    /// String consts are *owned* by the pool: the byte slice is duped
    /// into `allocator` (the module's long-lived allocator) so callers
    /// may free their temporary name/text buffer after interning.
    /// `Module.deinit` frees these copies.
    pub fn internConst(self: *Module, allocator: Allocator, c: Const) Allocator.Error!ConstId {
        // Hash-keyed dedup over the append-only pool; first id with a
        // given hash wins the slot (matching the scan's first-match), and
        // a colliding value falls back to the scan for that call.
        if (self.topUpConstDedup(allocator)) {
            const h = constHash(c);
            if (self.const_dedup.get(h)) |id| {
                if (Const.eql(self.consts.items[id.int()], c)) return id;
            } else {
                const id = ConstId.from(@intCast(self.consts.items.len));
                try self.consts.ensureUnusedCapacity(allocator, 1);
                const owned: Const = switch (c) {
                    .String => |s| .{ .String = try allocator.dupe(u8, s) },
                    else => c,
                };
                self.consts.appendAssumeCapacity(owned);
                self.const_dedup_n = self.consts.items.len;
                try self.const_dedup.put(allocator, h, id);
                return id;
            }
        } else |_| {}
        for (self.consts.items, 0..) |k, i| {
            if (Const.eql(k, c)) return ConstId.from(@intCast(i));
        }
        const id = ConstId.from(@intCast(self.consts.items.len));
        try self.consts.ensureUnusedCapacity(allocator, 1);
        const owned: Const = switch (c) {
            .String => |s| .{ .String = try allocator.dupe(u8, s) },
            else => c,
        };
        self.consts.appendAssumeCapacity(owned);
        return id;
    }

    fn topUpConstDedup(self: *Module, gpa: Allocator) Allocator.Error!void {
        while (self.const_dedup_n < self.consts.items.len) : (self.const_dedup_n += 1) {
            const h = constHash(self.consts.items[self.const_dedup_n]);
            const gop = try self.const_dedup.getOrPut(gpa, h);
            if (!gop.found_existing) gop.value_ptr.* = ConstId.from(@intCast(self.const_dedup_n));
        }
    }
};

/// A known stdlib host-served global alias (`min`, `listOf`, …). A bare call
/// to such a name whose overload set has no applicable body candidate routes
/// to the runtime global rather than a declared-arity fallback. Shared by
/// `resolveCall` (the Phase-B fallback gate) and the lowerer's alias /
/// value-ref paths so both classify the same names.
///
/// This name list is a cataloged hatch (resolution-unification plan, RC-H /
/// P10). A registry-derived replacement was attempted and measured unsound
/// three ways: the intrinsic registry maps FQNs to function pointers with no
/// declaration shape, so it cannot distinguish a value-position global
/// (`kotlin.collections.listOf`) from a package-level link binding for a
/// bodyless receiver-formed declaration (`kotlin.text.nativeIndexOf` binds
/// `String.nativeIndexOf`), and the implicit-alias table covers only part of
/// this surface (`reverseOrder`, the array builders are absent). The
/// classification these call sites need lives in DECLARATIONS the current
/// pipeline drops — P10 (the no-holes symbol table) restores those
/// declarations and deletes this list outright.
pub fn isAliasName(name: []const u8) bool {
    const names = [_][]const u8{
        "maxOf",           "minOf",      "max",                 "min",
        "print",           "println",    "listOf",              "mutableListOf",
        "arrayListOf",     "setOf",      "mutableSetOf",        "hashSetOf",
        "linkedSetOf",     "mapOf",      "mutableMapOf",        "hashMapOf",
        "linkedMapOf",     "arrayOf",    "arrayOfNulls",        "emptyArray",
        "emptyList",       "emptySet",   "emptyMap",            "listOfNotNull",
        "setOfNotNull",    "buildList",  "buildSet",            "buildMap",
        "buildString",     "TODO",       "error",               "compareValues",
        "compareValuesBy", "compareBy",  "compareByDescending", "naturalOrder",
        "reverseOrder",    "sequenceOf", "emptySequence",       "generateSequence",
        "sequence",        "iterator",   "readLine",            "sortedSetOf",
        "sortedMapOf",
    };
    for (names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

/// Whether every argument shape is positional (no named argument) — the
/// `allNull(arg_names)` gate a tail-call / trailing-lambda binding needs.
fn allShapeNamesNull(args: []const applicability.ArgShape) bool {
    for (args) |a| {
        if (a.named != null) return false;
    }
    return true;
}

/// True when `head` is the first dotted segment of `fqn` and `fqn` has
/// at least one further segment — i.e. `fqn` is `head.<rest>`, so `head`
/// is a package prefix of a real symbol rather than the symbol's own
/// simple name.
fn fqnHasHeadSegment(fqn: []const u8, head: []const u8) bool {
    return fqn.len > head.len and
        std.mem.startsWith(u8, fqn, head) and
        fqn[head.len] == '.';
}

/// Insert every dot-aligned prefix of `fqn` — exactly the `head` values
/// `fqnHasHeadSegment(fqn, head)` accepts — into `set`. Keys alias `fqn`,
/// which outlives the module's lookup caches.
fn insertFqnPrefixes(set: *std.StringHashMapUnmanaged(void), gpa: Allocator, fqn: []const u8) Allocator.Error!void {
    for (fqn, 0..) |ch, i| {
        if (ch == '.') try set.put(gpa, fqn[0..i], {});
    }
}

/// Structural hash paired with `Const.eql`: scalars hash their bit
/// pattern (so NaN and ±0.0 follow the interning pool's bit-level
/// equality), strings hash their bytes, and the tag seeds the hash so
/// same-width variants stay distinct.
fn constHash(c: Const) u64 {
    var h = std.hash.Wyhash.init(@intFromEnum(std.meta.activeTag(c)));
    switch (c) {
        .Unit, .Null => {},
        .Int => |v| h.update(std.mem.asBytes(&v)),
        .Long => |v| h.update(std.mem.asBytes(&v)),
        .UInt => |v| h.update(std.mem.asBytes(&v)),
        .ULong => |v| h.update(std.mem.asBytes(&v)),
        .UShort => |v| h.update(std.mem.asBytes(&v)),
        .UByte => |v| h.update(std.mem.asBytes(&v)),
        .Short => |v| h.update(std.mem.asBytes(&v)),
        .Byte => |v| h.update(std.mem.asBytes(&v)),
        .Double => |v| {
            const bits: u64 = @bitCast(v);
            h.update(std.mem.asBytes(&bits));
        },
        .Float => |v| {
            const bits: u32 = @bitCast(v);
            h.update(std.mem.asBytes(&bits));
        },
        .Bool => |v| h.update(std.mem.asBytes(&v)),
        .Char => |v| h.update(std.mem.asBytes(&v)),
        .String => |s| h.update(s),
    }
    return h.final();
}

/// The declaring package of a top-level decl whose fully-qualified name
/// is `fqn` and whose simple name is `simple`: the FQN with its trailing
/// `.{simple}` stripped, the empty string when the FQN equals the simple
/// name (no package header). One uniform derivation — `""` is the
/// no-package case, not a separate branch.
pub fn packageOfFqn(fqn: []const u8, simple: []const u8) []const u8 {
    if (std.mem.eql(u8, fqn, simple)) return "";
    if (fqn.len > simple.len + 1 and
        std.mem.endsWith(u8, fqn, simple) and
        fqn[fqn.len - simple.len - 1] == '.')
    {
        return fqn[0 .. fqn.len - simple.len - 1];
    }
    if (std.mem.lastIndexOfScalar(u8, fqn, '.')) |dot| return fqn[0..dot];
    return "";
}

/// Whether `pkg` names a package the runtime ships (the embedded stdlib,
/// the kotlinx packs, java interop): its head segment is `kotlin`,
/// `kotlinx`, or `java`. Classifies a declaration by its declaring
/// package — the same field the scope tiers rank on — so user-package
/// candidates outrank shipped ones in the order-based fallbacks.
fn isShippedPackage(pkg: []const u8) bool {
    return pkgHeadIs(pkg, "kotlin") or pkgHeadIs(pkg, "kotlinx") or pkgHeadIs(pkg, "java");
}

/// Whether an FQN's head segment marks a shipped declaration (stdlib,
/// kotlinx pack, java interop). The runtime class registry's simple-name
/// view ranks a user class above a shipped one for the same simple name.
pub fn shippedFqnHead(fqn: []const u8) bool {
    return isShippedPackage(fqn);
}

fn pkgHeadIs(pkg: []const u8, head: []const u8) bool {
    if (!std.mem.startsWith(u8, pkg, head)) return false;
    return pkg.len == head.len or pkg[head.len] == '.';
}

/// Index into a slice by a `u32` id, returning a pointer or `null`
/// when out of range.
fn idGet(comptime T: type, items: []const T, idx: u32) ?*const T {
    if (idx >= items.len) return null;
    return &items[idx];
}

/// Module-scoped side tables consumed by the Vm at dispatch time.
/// Populated by `interp_ir`'s build pass; serialized into pack files
/// so a pre-built pack can ship its registry alongside the frozen IR
/// module.
pub const ModuleRegistry = struct {
    /// Names of `object` singletons. The Vm allocates one instance
    /// per name at startup and publishes it as a global so bare-name
    /// reads resolve.
    object_names: std.ArrayList([]const u8) = .empty,
    /// Outer-class → companion-singleton global name. Reads on
    /// `Foo.X` fall through to the companion instance when `X` is
    /// not a member of `Foo` itself.
    companion_singletons: std.StringHashMap([]const u8),
    /// Inner class → outer class name. Resolves `this@Outer` and
    /// outer-chain field reads for nested classes lifted to top level.
    enclosing_class: std.StringHashMap([]const u8),
    /// Per-function type-parameter names (in source order). Used by
    /// reified-call dispatch to bind `T` → `Value.Class(arg)` as a
    /// global for the call's lifetime.
    func_type_params: std.AutoHashMap(FuncId, std.ArrayList([]const u8)),
    /// Declared upper bounds of a function's type parameters (`<T : Number>`
    /// inline bounds plus `where` clauses), one entry per (param, bound)
    /// pair. The strict extension-receiver prover consults these: a
    /// bounded type-parameter receiver is proven only when the actual
    /// receiver satisfies every bound; an unbounded one accepts anything.
    func_type_param_bounds: std.AutoHashMap(FuncId, []const TypeParamBound),
    /// Declared upper bounds of each CLASS's type parameters
    /// (`class EnumEntriesList<T : Enum<T>>`), keyed by class simple name.
    /// Method dispatch disproves a wrong-typed argument against a param
    /// declared as the class type param (the Kotlin collection-stub
    /// bridge: `indexOf(nonEnum)` on an `EnumEntries` answers -1 through
    /// the inherited implementation instead of running the override).
    class_type_param_bounds: std.StringHashMap([]const TypeParamBound),
    /// Top-level property names declared with `by <delegate>`.
    /// Reads/writes route through the stored delegate's `getValue` /
    /// `setValue` methods.
    top_level_delegated_props: std.StringHashMap(void),
    /// Class simple name → the set of member *function* names it
    /// declares or inherits (transitively over supertypes). Lets the
    /// lowerer honor Kotlin's separate function/property namespaces.
    hierarchy_methods: std.StringHashMap(std.StringHashMap(void)),
    /// Private stored properties that SHADOW a same-name declaration in a
    /// strict supertype, keyed "Class\x1fprop". Kotlin gives a shadow its
    /// own storage cell (a private base field and a private derived field
    /// are distinct); construction stores these under the owner-mangled
    /// key and the scope-qualified read/write paths address exactly that
    /// cell, so the base class's cell is never clobbered. Lowering-only.
    private_shadow_props: std.StringHashMap(void),
    /// Initialized `override val/var` properties whose supertype STORES the
    /// same name, keyed "Class\x1fprop". Each class keeps its own backing
    /// cell (JVM semantics): reads dispatch to the most-derived cell,
    /// `super.x` reads the base's plain cell. Lowering-only.
    override_cell_props: std.StringHashMap(void),
    /// Per-class transitive member-NAME set for the member-shadow gate —
    /// every kind a bare name could bind through the implicit receiver —
    /// plus whether the supertype chain fully resolved (`complete`). An
    /// incomplete set must not prove non-shadowability. Lowering-only.
    hierarchy_shadow_names: std.StringHashMap(HierarchyShadowSet),
    /// `(declaring class, method name)` → trailing-lambda shapes collected
    /// from every member declaration before any body lowers. This keeps
    /// receiver-lambda typing independent of source order when a subclass
    /// calls an inherited method whose body has not produced a `FuncId` yet.
    /// Lowering-only; installed packs use their serialized lowered methods.
    member_trailing_lambda_shapes: StrPairMap(std.ArrayList(MemberTrailingLambdaShape)),
    /// `"<class>\x00<method>\x00<userArity>"` → the lowered method's FuncId,
    /// populated incrementally as each class's method bodies are lowered. Lets
    /// a method body statically reach a SIBLING member method's lowered
    /// signature (e.g. the declared parameter types of `testPlus`) at lower
    /// time, when `Class.methods` is not yet patched and members are absent
    /// from the simple-name / fqn indexes. Owner-scoped, so a same-named member
    /// in an unrelated class is never confused for it.
    member_method_fids: std.StringHashMap(FuncId),
    /// Every member name (function, property, primary-ctor property,
    /// companion member) declared by ANY class in the program. A bare
    /// name in a receiver context can only be shadowed by a runtime
    /// receiver when some class declares a member of that name, so
    /// lowering keeps the static classification for everything else.
    class_member_names: std.StringHashMap(void),
    /// Class simple name → its transitive supertype simple names,
    /// nearest first (each direct supertype followed by its own chain).
    /// Recorded from the AST hierarchy before body lowering, so a
    /// method body can rank extension receivers against the enclosing
    /// class — including extensions declared on a base class — while
    /// the IR-side `Class.supertypes` slots are still being filled.
    class_super_names: std.StringHashMap([]const []const u8),
    /// Body-property `(class, prop)` pairs declared with `by`.
    delegated_body_props: StrPairSet,
    /// (class, property) pairs whose declared type is a RECEIVER function
    /// type (`suspend Scope.() -> Unit`): a bare invocation of the stored
    /// value inside a receiver context binds the implicit `this` as the
    /// lambda's receiver (`_deprecatedPointerInputHandler!!()` inside the
    /// pointer-input node runs the handler on the node's scope). The value
    /// is the DECLARED receiver type's simple head (`Scope`), so dispatch
    /// binds the innermost implicit receiver of that type — the owning
    /// instance when it implements the head, an enclosing receiver
    /// otherwise (`block()` inside `with(cacheDrawScope) { … }` where
    /// `block: CacheDrawScope.() -> DrawResult` lives on the node).
    recv_fn_props: StrPairMap([]const u8),
    /// `(class simple name, property name)` → the property's DECLARED
    /// type head, with a class type-parameter name substituted by its
    /// bound's head (`data: T` in `IterableTests<T : Iterable<String>>`
    /// records `Iterable`). Consumed by the binop/member lowering so a
    /// call on the property resolves against the static type, as
    /// kotlinc does.
    class_prop_type_heads: StrPairMap([]const u8),
    /// `FuncId` → declaring-class simple name for *member extension
    /// functions* (`class C { fun R.f(...) { … } }`). Empty for
    /// top-level extensions.
    member_ext_owner_class: std.AutoHashMap(FuncId, []const u8),
    /// `FuncId` → declaring FILE of a `private` top-level function. Kotlin
    /// scopes a private top-level declaration to its file, so a dispatch
    /// walk must never pick a private extension from another file (a
    /// file-private `Rect.size()` capturing `LongSparseArray.size()`).
    private_fn_files: std.AutoHashMap(FuncId, FileId),
    /// (interface, method) → declared extension-receiver type head for
    /// ABSTRACT member-extension declarations (`fun interface
    /// MeasurePolicy { fun MeasureScope.measure(...) }`). The abstract
    /// slot lowers no func, so the SAM dispatch reads the receiver type
    /// here to bind the lambda's implicit `this`.
    iface_member_ext_recv: StrPairMap([]const u8),
    /// Top-level `const val` literal values keyed by declaration FQN.
    /// Kotlin inlines compile-time constants at every reference, so the
    /// lowering reads the value here and emits the literal directly — a
    /// bare `Empty` inside androidx.collection can never be captured by a
    /// same-simple-name global another module published.
    top_level_const_vals: std.StringHashMap(Const),
    /// Per-local-function default-arg thunks. Keyed by the local fn's
    /// lowered body `FuncId`; each slot holds the `FuncId` of a 0-arg
    /// thunk producing that parameter's default, or `null` for a
    /// required param.
    local_fn_defaults: std.AutoHashMap(FuncId, std.ArrayList(?FuncId)),
    /// Default-arg thunks for *bodyless* (abstract / interface) member
    /// declarations, keyed by `(class simple name, method name)`.
    abstract_member_defaults: StrPairMap(std.ArrayList(?FuncId)),
    /// `typealias Name = Target` → `Name` ↦ `Target`'s simple head
    /// name.
    type_aliases: std.StringHashMap([]const u8),
    /// Function-type aliases whose target declares an extension RECEIVER
    /// (`typealias Workflow = suspend WScope.() -> Unit`) → the target's
    /// VALUE-parameter count. The `Function{N}` tag in `type_aliases`
    /// deliberately drops the receiver; a bare call through a param of
    /// such an alias must still bind the enclosing `this`.
    recv_fn_aliases: std.StringHashMap(u8),
    /// Per-file (`FileId`) non-wildcard import leaf → every import in
    /// the file bound to that leaf, in declaration order. Keyed by file
    /// because a Kotlin named import is file-scoped; a list because
    /// Kotlin keeps every same-leaf import in scope (a second import of
    /// the same leaf is an ambiguity at the use site, not a shadow).
    import_aliases: std.AutoHashMap(FileId, std.StringHashMap(std.ArrayList(ImportPath))),
    /// Per-file (`FileId`) wildcard-import package paths (dotted,
    /// owned). A `import pkg.*` makes every `pkg` declaration visible
    /// to the file, outranking the implicitly-imported built-ins in
    /// bare-call preference.
    import_wildcards: std.AutoHashMap(FileId, std.ArrayList([]const u8)),
    /// Per-file (`FileId`) declared package path. A spliced inline body
    /// carries the DONOR file's spans, so bare-call scope judgments must
    /// follow the span's file — its package and imports — not the
    /// recipient function's package.
    file_packages: std.AutoHashMap(FileId, []const u8),
    /// Nested-object simple-name aliases, keyed by enclosing class
    /// name.
    nested_object_aliases: std.StringHashMap(std.StringHashMap([]const u8)),
    /// Qualified nested-class name (`Outer.Inner`) → mangled lift name,
    /// for nested classes the lift renamed (private, or colliding with
    /// a top-level type). A qualified type reference (`x is
    /// Outer.Inner`, `x as Outer.Inner`) resolves through this so it
    /// binds the lifted class, never a same-simple-name top-level one.
    mangled_nested: std.StringHashMap([]const u8),
    /// `(class_name, member_name) → Const` for class / companion
    /// `const val name = <literal>`.
    class_const_inits: StrPairMap(Const),
    /// Top-level (file-scope) property simple name → every declaration of
    /// that name, each carrying its FQN and declaring package. A bare read
    /// of such a property resolves under Kotlin scoping, so the lowerer
    /// ranks the read's tier the same way it ranks a bare call: a read
    /// whose only declaration is in an unimported package is unresolved.
    top_level_prop_pkgs: std.StringHashMap(std.ArrayList(PropDecl)),
    /// Top-level property simple name → 0-arg getter `FuncId`, for a
    /// `val`/`var` declared with only a custom getter (no initializer,
    /// no backing field, no delegate). A `LoadGlobal` of such a name
    /// re-invokes the getter on every read.
    top_level_prop_getters: std.StringHashMap(FuncId),
    /// Top-level `var` custom setters. A `StoreGlobal` of the property
    /// name invokes the setter thunk; the thunk's own `field =` write
    /// lands on the `__klio_topfield__<name>` storage binding.
    top_level_prop_setters: std.StringHashMap(FuncId),

    allocator: Allocator,

    /// One top-level property declaration's scoping identity.
    pub const PropDecl = struct {
        fqn: []const u8,
        package: []const u8,
    };

    /// One non-wildcard import: its full dotted path (owned by the
    /// registry allocator) and the same path as segments (an owned
    /// slice of name slices borrowed from the AST).
    pub const ImportPath = struct {
        fqn: []const u8,
        segs: []const []const u8,
    };

    pub const TypeParamBound = struct {
        param: []const u8,
        bound: []const u8,
    };

    /// One class's transitive shadow-name set + chain completeness.
    pub const HierarchyShadowSet = struct {
        names: std.StringHashMap(void),
        complete: bool,
    };

    pub const MemberTrailingLambdaShape = struct {
        /// Bit `n` is set when `n` positional user arguments, including the
        /// trailing lambda, can bind this declaration.
        accepted_arities: u64,
        value_arity: i16,
        receiver_head: ?[]const u8,
    };

    pub fn init(allocator: Allocator) ModuleRegistry {
        return .{
            .companion_singletons = std.StringHashMap([]const u8).init(allocator),
            .enclosing_class = std.StringHashMap([]const u8).init(allocator),
            .func_type_params = std.AutoHashMap(FuncId, std.ArrayList([]const u8)).init(allocator),
            .func_type_param_bounds = std.AutoHashMap(FuncId, []const TypeParamBound).init(allocator),
            .class_type_param_bounds = std.StringHashMap([]const TypeParamBound).init(allocator),
            .top_level_delegated_props = std.StringHashMap(void).init(allocator),
            .hierarchy_methods = std.StringHashMap(std.StringHashMap(void)).init(allocator),
            .hierarchy_shadow_names = std.StringHashMap(HierarchyShadowSet).init(allocator),
            .member_trailing_lambda_shapes = StrPairMap(std.ArrayList(MemberTrailingLambdaShape)).init(allocator),
            .private_shadow_props = std.StringHashMap(void).init(allocator),
            .override_cell_props = std.StringHashMap(void).init(allocator),
            .member_method_fids = std.StringHashMap(FuncId).init(allocator),
            .class_member_names = std.StringHashMap(void).init(allocator),
            .class_super_names = std.StringHashMap([]const []const u8).init(allocator),
            .delegated_body_props = StrPairSet.init(allocator),
            .recv_fn_props = StrPairMap([]const u8).init(allocator),
            .class_prop_type_heads = StrPairMap([]const u8).init(allocator),
            .member_ext_owner_class = std.AutoHashMap(FuncId, []const u8).init(allocator),
            .private_fn_files = std.AutoHashMap(FuncId, FileId).init(allocator),
            .iface_member_ext_recv = StrPairMap([]const u8).init(allocator),
            .top_level_const_vals = std.StringHashMap(Const).init(allocator),
            .local_fn_defaults = std.AutoHashMap(FuncId, std.ArrayList(?FuncId)).init(allocator),
            .abstract_member_defaults = StrPairMap(std.ArrayList(?FuncId)).init(allocator),
            .type_aliases = std.StringHashMap([]const u8).init(allocator),
            .recv_fn_aliases = std.StringHashMap(u8).init(allocator),
            .import_aliases = std.AutoHashMap(FileId, std.StringHashMap(std.ArrayList(ImportPath))).init(allocator),
            .import_wildcards = std.AutoHashMap(FileId, std.ArrayList([]const u8)).init(allocator),
            .file_packages = std.AutoHashMap(FileId, []const u8).init(allocator),
            .nested_object_aliases = std.StringHashMap(std.StringHashMap([]const u8)).init(allocator),
            .mangled_nested = std.StringHashMap([]const u8).init(allocator),
            .class_const_inits = StrPairMap(Const).init(allocator),
            .top_level_prop_pkgs = std.StringHashMap(std.ArrayList(PropDecl)).init(allocator),
            .top_level_prop_getters = std.StringHashMap(FuncId).init(allocator),
            .top_level_prop_setters = std.StringHashMap(FuncId).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ModuleRegistry) void {
        const a = self.allocator;
        self.object_names.deinit(a);
        self.companion_singletons.deinit();
        self.enclosing_class.deinit();
        {
            var it = self.func_type_params.valueIterator();
            while (it.next()) |list| list.deinit(a);
            self.func_type_params.deinit();
        }
        {
            var it = self.func_type_param_bounds.valueIterator();
            while (it.next()) |list| a.free(list.*);
            self.func_type_param_bounds.deinit();
        }
        {
            var it = self.class_type_param_bounds.valueIterator();
            while (it.next()) |list| a.free(list.*);
            self.class_type_param_bounds.deinit();
        }
        self.top_level_delegated_props.deinit();
        {
            self.private_shadow_props.deinit();
            self.override_cell_props.deinit();
        }
        {
            var itsn = self.hierarchy_shadow_names.valueIterator();
            while (itsn.next()) |v| v.names.deinit();
            self.hierarchy_shadow_names.deinit();
        }
        {
            var it = self.member_trailing_lambda_shapes.valueIterator();
            while (it.next()) |list| list.deinit(a);
            self.member_trailing_lambda_shapes.deinit();
        }
        {
            var it = self.hierarchy_methods.valueIterator();
            while (it.next()) |inner| inner.deinit();
            self.hierarchy_methods.deinit();
        }
        {
            var it = self.member_method_fids.keyIterator();
            while (it.next()) |k| self.allocator.free(k.*);
            self.member_method_fids.deinit();
        }
        self.class_member_names.deinit();
        {
            var it = self.class_super_names.valueIterator();
            while (it.next()) |names| a.free(names.*);
            self.class_super_names.deinit();
        }
        self.delegated_body_props.deinit();
        self.recv_fn_props.deinit();
        self.class_prop_type_heads.deinit();
        self.member_ext_owner_class.deinit();
        self.private_fn_files.deinit();
        self.iface_member_ext_recv.deinit();
        self.top_level_const_vals.deinit();
        {
            var it = self.local_fn_defaults.valueIterator();
            while (it.next()) |list| list.deinit(a);
            self.local_fn_defaults.deinit();
        }
        {
            var it = self.abstract_member_defaults.valueIterator();
            while (it.next()) |list| list.deinit(a);
            self.abstract_member_defaults.deinit();
        }
        self.type_aliases.deinit();
        self.recv_fn_aliases.deinit();
        {
            var it = self.import_aliases.valueIterator();
            while (it.next()) |inner| {
                var inner_it = inner.valueIterator();
                while (inner_it.next()) |paths| {
                    for (paths.items) |p| {
                        a.free(p.fqn);
                        a.free(p.segs);
                    }
                    paths.deinit(a);
                }
                inner.deinit();
            }
            self.import_aliases.deinit();
        }
        {
            var it = self.import_wildcards.valueIterator();
            while (it.next()) |list| {
                for (list.items) |path| a.free(path);
                list.deinit(a);
            }
            self.import_wildcards.deinit();
        }
        self.file_packages.deinit();
        {
            var it = self.nested_object_aliases.valueIterator();
            while (it.next()) |inner| inner.deinit();
            self.nested_object_aliases.deinit();
        }
        self.mangled_nested.deinit();
        self.class_const_inits.deinit();
        {
            var it = self.top_level_prop_pkgs.valueIterator();
            while (it.next()) |list| list.deinit(a);
            self.top_level_prop_pkgs.deinit();
        }
        self.top_level_prop_getters.deinit();
        self.top_level_prop_setters.deinit();
    }

    /// Clone for extension (see `Module.cloneForExtend`). Outer container
    /// spines are copied onto `a`; inner containers and value slices are
    /// SHARED with the original by value-copy. That is sound because the
    /// extending build only ever inserts NEW keys (new files, new classes,
    /// new FuncIds — cross-boundary name collisions fall back to a full
    /// rebuild) and replaces whole entries; it never appends into an inner
    /// container reached through an existing key.
    pub fn cloneForExtend(self: *const ModuleRegistry, a: Allocator) Allocator.Error!ModuleRegistry {
        var out = ModuleRegistry.init(a);
        try out.object_names.appendSlice(a, self.object_names.items);
        {
            var it = self.companion_singletons.iterator();
            while (it.next()) |e| try out.companion_singletons.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.enclosing_class.iterator();
            while (it.next()) |e| try out.enclosing_class.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.func_type_params.iterator();
            while (it.next()) |e| {
                var list: std.ArrayList([]const u8) = .empty;
                try list.appendSlice(a, e.value_ptr.items);
                try out.func_type_params.put(e.key_ptr.*, list);
            }
        }
        {
            var it = self.func_type_param_bounds.iterator();
            while (it.next()) |e| try out.func_type_param_bounds.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.class_type_param_bounds.iterator();
            while (it.next()) |e| try out.class_type_param_bounds.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.top_level_delegated_props.keyIterator();
            while (it.next()) |k| try out.top_level_delegated_props.put(k.*, {});
        }
        {
            var it = self.hierarchy_methods.iterator();
            while (it.next()) |e| try out.hierarchy_methods.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.member_trailing_lambda_shapes.iterator();
            while (it.next()) |e| {
                var list: std.ArrayList(MemberTrailingLambdaShape) = .empty;
                try list.appendSlice(a, e.value_ptr.items);
                try out.member_trailing_lambda_shapes.put(e.key_ptr.*, list);
            }
        }
        {
            var it = self.member_method_fids.iterator();
            while (it.next()) |e| try out.member_method_fids.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.private_shadow_props.keyIterator();
            while (it.next()) |k| try out.private_shadow_props.put(k.*, {});
        }
        {
            var it = self.override_cell_props.keyIterator();
            while (it.next()) |k| try out.override_cell_props.put(k.*, {});
        }
        {
            var it = self.hierarchy_shadow_names.iterator();
            while (it.next()) |e| try out.hierarchy_shadow_names.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.class_member_names.keyIterator();
            while (it.next()) |k| try out.class_member_names.put(k.*, {});
        }
        {
            var it = self.class_super_names.iterator();
            while (it.next()) |e| try out.class_super_names.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.delegated_body_props.keyIterator();
            while (it.next()) |k| try out.delegated_body_props.put(k.*, {});
        }
        {
            var it = self.class_prop_type_heads.iterator();
            while (it.next()) |e| try out.class_prop_type_heads.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.member_ext_owner_class.iterator();
            while (it.next()) |e| try out.member_ext_owner_class.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.private_fn_files.iterator();
            while (it.next()) |e| try out.private_fn_files.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.iface_member_ext_recv.iterator();
            while (it.next()) |e| try out.iface_member_ext_recv.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.top_level_const_vals.iterator();
            while (it.next()) |e| try out.top_level_const_vals.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.local_fn_defaults.iterator();
            while (it.next()) |e| {
                var list: std.ArrayList(?FuncId) = .empty;
                try list.appendSlice(a, e.value_ptr.items);
                try out.local_fn_defaults.put(e.key_ptr.*, list);
            }
        }
        {
            var it = self.abstract_member_defaults.iterator();
            while (it.next()) |e| {
                var list: std.ArrayList(?FuncId) = .empty;
                try list.appendSlice(a, e.value_ptr.items);
                try out.abstract_member_defaults.put(e.key_ptr.*, list);
            }
        }
        {
            var it = self.type_aliases.iterator();
            while (it.next()) |e| try out.type_aliases.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.import_aliases.iterator();
            while (it.next()) |e| try out.import_aliases.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.import_wildcards.iterator();
            while (it.next()) |e| try out.import_wildcards.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.file_packages.iterator();
            while (it.next()) |e| try out.file_packages.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.nested_object_aliases.iterator();
            while (it.next()) |e| try out.nested_object_aliases.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.mangled_nested.iterator();
            while (it.next()) |e| try out.mangled_nested.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.class_const_inits.iterator();
            while (it.next()) |e| try out.class_const_inits.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.top_level_prop_pkgs.iterator();
            while (it.next()) |e| {
                var list: std.ArrayList(PropDecl) = .empty;
                try list.appendSlice(a, e.value_ptr.items);
                try out.top_level_prop_pkgs.put(e.key_ptr.*, list);
            }
        }
        {
            var it = self.top_level_prop_getters.iterator();
            while (it.next()) |e| try out.top_level_prop_getters.put(e.key_ptr.*, e.value_ptr.*);
            var sit = self.top_level_prop_setters.iterator();
            while (sit.next()) |e| try out.top_level_prop_setters.put(e.key_ptr.*, e.value_ptr.*);
        }
        return out;
    }
};

/// Constant pool entry. Anything not representable as a `u32`
/// (strings, large integers, types) lives here.
pub const Const = union(enum) {
    Unit,
    Int: i32,
    Long: i64,
    UInt: u32,
    ULong: u64,
    UShort: u16,
    UByte: u8,
    Short: i16,
    Byte: i8,
    Double: f64,
    Float: f32,
    Bool: bool,
    /// UTF-16 code unit (see `runtime.Value.Char`).
    Char: u16,
    String: []const u8,
    Null,

    /// Structural equality used by the interning pool. `Double` /
    /// `Float` compare by bit pattern so NaN interns total and
    /// +0.0 / -0.0 stay distinct.
    pub fn eql(self: Const, other: Const) bool {
        return switch (self) {
            .Unit => other == .Unit,
            .Int => |a| other == .Int and a == other.Int,
            .Long => |a| other == .Long and a == other.Long,
            .UInt => |a| other == .UInt and a == other.UInt,
            .ULong => |a| other == .ULong and a == other.ULong,
            .UShort => |a| other == .UShort and a == other.UShort,
            .UByte => |a| other == .UByte and a == other.UByte,
            .Short => |a| other == .Short and a == other.Short,
            .Byte => |a| other == .Byte and a == other.Byte,
            .Double => |a| other == .Double and @as(u64, @bitCast(a)) == @as(u64, @bitCast(other.Double)),
            .Float => |a| other == .Float and @as(u32, @bitCast(a)) == @as(u32, @bitCast(other.Float)),
            .Bool => |a| other == .Bool and a == other.Bool,
            .Char => |a| other == .Char and a == other.Char,
            .String => |a| other == .String and std.mem.eql(u8, a, other.String),
            .Null => other == .Null,
        };
    }
};

const testing = std.testing;

test {
    // Force analysis of every public declaration so the full IR
    // type surface is type-checked, not just the paths the named
    // tests exercise.
    testing.refAllDecls(@This());
    inline for (.{
        TypeRef,        Reg,        BlockId,    FuncId,
        ClassId,        ConstId,    Inst,       SpreadPart,
        BinOp,          UnOp,       Terminator, SwitchArm,
        CatchHandler,   Block,      Func,       Param,
        Class,          Module,     ModuleRegistry, Const,
        ClassIndexEntry, FuncIndexEntry, StrPair,
    }) |T| {
        testing.refAllDecls(T);
    }
}

test "intern dedups equal constants" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    const a = try m.internConst(testing.allocator, .{ .Int = 42 });
    const b = try m.internConst(testing.allocator, .{ .Int = 42 });
    try testing.expectEqual(a, b);
    try testing.expectEqual(@as(usize, 1), m.consts.items.len);
}

test "intern distinguishes typed zeros" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    const i = try m.internConst(testing.allocator, .{ .Int = 0 });
    const l = try m.internConst(testing.allocator, .{ .Long = 0 });
    try testing.expect(i != l);
    try testing.expectEqual(@as(usize, 2), m.consts.items.len);
}

test "float nan does not collapse" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    _ = try m.internConst(testing.allocator, .{ .Double = std.math.nan(f64) });
    _ = try m.internConst(testing.allocator, .{ .Double = std.math.nan(f64) });
    // Two interns of NaN compare equal under bit comparison when both
    // share a bit pattern; the canonical quiet-NaN collapses to one
    // entry. This guards that interning is total — it never traps on
    // NaN.
    try testing.expect(m.consts.items[0] == .Double);
}

test "string consts are owned by the pool" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);

    // A caller-owned temporary that is freed right after interning. The
    // pool must keep its own copy, so the stored slice cannot alias the
    // freed buffer.
    const tmp = try testing.allocator.dupe(u8, "kotlin.math.abs");
    const id = try m.internConst(testing.allocator, .{ .String = tmp });
    testing.allocator.free(tmp);

    try testing.expect(m.consts.items[id.int()] == .String);
    try testing.expectEqualStrings("kotlin.math.abs", m.consts.items[id.int()].String);
    // The stored copy is distinct memory from the freed temporary.
    try testing.expect(m.consts.items[id.int()].String.ptr != tmp.ptr);

    // Interning an equal string dedups to the same id without leaking a
    // second copy.
    const tmp2 = try testing.allocator.dupe(u8, "kotlin.math.abs");
    const id2 = try m.internConst(testing.allocator, .{ .String = tmp2 });
    testing.allocator.free(tmp2);
    try testing.expectEqual(id, id2);
    try testing.expectEqual(@as(usize, 1), m.consts.items.len);
}

test "packageOfFqn strips the trailing simple name" {
    try testing.expectEqualStrings("", packageOfFqn("foo", "foo"));
    try testing.expectEqualStrings("a.b", packageOfFqn("a.b.foo", "foo"));
    try testing.expectEqualStrings("kotlin.math", packageOfFqn("kotlin.math.abs", "abs"));
    // A mangled nested FQN: the package is everything up to the last dot.
    try testing.expectEqualStrings("pkg", packageOfFqn("pkg.Outer$Name", "Name"));
}

test "extension candidate index uses declaration metadata for bodyless headers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    const min = try pushTestFuncOpts(
        &m,
        a,
        "min",
        "sample.min",
        "sample",
        0,
        .{ .extension = true, .stub = true },
    );
    m.funcs.items[min.int()].params = &.{};
    try m.decl_sigs.put(min.int(), .{
        .receiver_ty = .{ .name = "IntArray", .nullable = false, .args = &.{} },
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .kind = .top_level_extension,
        .has_body = true,
    });

    try testing.expect(m.extCouldApply(a, "IntArray", "min"));
    try testing.expect(!m.extCouldApply(a, "String", "min"));
    try testing.expect(!m.extCouldApply(a, "IntArray", "max"));
}

test "method slots link generic overrides and multiple interface roots" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    const base = try m.addClass(a, .{
        .id = ClassId.from(0), .name = "Base", .fqn = "sample.Base", .primary_params = &.{},
        .methods = &.{}, .init_block = null, .companion = null, .supertypes = &.{},
        .type_params = &.{"T"}, .is_abstract = true,
    });
    const base_args = try a.alloc(TypeRef, 1);
    base_args[0] = .{ .name = "String", .nullable = false, .args = &.{} };
    const child_supers = try a.alloc(TypeRef, 1);
    child_supers[0] = .{ .name = "Base", .nullable = false, .args = base_args };
    const child_super_ids = try a.dupe(ClassId, &.{base});
    const child = try m.addClass(a, .{
        .id = ClassId.from(0), .name = "Child", .fqn = "sample.Child", .primary_params = &.{},
        .methods = &.{}, .init_block = null, .companion = null, .supertypes = child_super_ids,
        .supertype_refs = child_supers, .is_open = true,
    });
    const redundant_supers = try a.alloc(TypeRef, 2);
    redundant_supers[0] = .{ .name = "Child", .nullable = false, .args = &.{} };
    redundant_supers[1] = .{ .name = "Base", .nullable = false, .args = base_args };
    const redundant_super_ids = try a.dupe(ClassId, &.{ child, base });
    const redundant = try m.addClass(a, .{
        .id = ClassId.from(0), .name = "Redundant", .fqn = "sample.Redundant", .primary_params = &.{},
        .methods = &.{}, .init_block = null, .companion = null, .supertypes = redundant_super_ids,
        .supertype_refs = redundant_supers,
    });
    const left = try m.addClass(a, .{
        .id = ClassId.from(0), .name = "Left", .fqn = "sample.Left", .primary_params = &.{},
        .methods = &.{}, .init_block = null, .companion = null, .supertypes = &.{}, .is_abstract = true, .is_interface = true,
    });
    const right = try m.addClass(a, .{
        .id = ClassId.from(0), .name = "Right", .fqn = "sample.Right", .primary_params = &.{},
        .methods = &.{}, .init_block = null, .companion = null, .supertypes = &.{}, .is_abstract = true, .is_interface = true,
    });
    const both_supers = try a.alloc(TypeRef, 2);
    both_supers[0] = .{ .name = "Left", .nullable = false, .args = &.{} };
    both_supers[1] = .{ .name = "Right", .nullable = false, .args = &.{} };
    const both_super_ids = try a.dupe(ClassId, &.{ left, right });
    const both = try m.addClass(a, .{
        .id = ClassId.from(0), .name = "Both", .fqn = "sample.Both", .primary_params = &.{},
        .methods = &.{}, .init_block = null, .companion = null, .supertypes = both_super_ids,
        .supertype_refs = both_supers,
    });

    const base_put = try pushTestFuncOpts(&m, a, "put", "sample.Base.put", "sample", 1, .{ .stub = true, .param_ty = "T" });
    const child_put = try pushTestFuncOpts(&m, a, "put", "sample.Child.put", "sample", 1, .{ .param_ty = "String" });
    const left_run = try pushTestFuncOpts(&m, a, "run", "sample.Left.run", "sample", 1, .{ .stub = true, .param_ty = "Int" });
    const right_run = try pushTestFuncOpts(&m, a, "run", "sample.Right.run", "sample", 1, .{ .stub = true, .param_ty = "Int" });
    const both_run = try pushTestFuncOpts(&m, a, "run", "sample.Both.run", "sample", 1, .{ .param_ty = "Int" });
    for ([_]FuncId{ base_put, child_put, left_run, right_run, both_run }) |fid| m.funcs.items[fid.int()].kind = .instance_method;
    m.funcs.items[child_put.int()].is_override = true;
    m.funcs.items[both_run.int()].is_override = true;
    m.classes.items[base.int()].methods = try a.dupe(FuncId, &.{base_put});
    m.classes.items[child.int()].methods = try a.dupe(FuncId, &.{child_put});
    m.classes.items[both.int()].methods = try a.dupe(FuncId, &.{both_run});

    const owners = [_]ClassId{ base, child, left, right, both };
    const funcs = [_]FuncId{ base_put, child_put, left_run, right_run, both_run };
    const types = [_][]const u8{ "T", "String", "Int", "Int", "Int" };
    for (funcs, owners, types) |fid, owner, ty| {
        try m.decl_sigs.put(fid.int(), .{
            .enclosing_class = owner,
            .arity = .{ .required = 1, .total = 1, .has_vararg = false },
            .sig = &.{.{ .name = ty, .nullable = false, .args = &.{} }},
            .kind = .instance_method,
            .has_body = m.funcs.items[fid.int()].hasBody(),
        });
        try m.registerMemberDecl(a, m.classes.items[owner.int()].fqn, m.funcs.items[fid.int()].name, fid);
    }

    try m.linkMethodSlots(a);
    try testing.expectEqual(child_put, m.methodSlotTarget(child, MethodSlotId.fromFunc(base_put)).?);
    try testing.expectEqual(child_put, m.methodSlotTarget(redundant, MethodSlotId.fromFunc(base_put)).?);
    try testing.expectEqual(both_run, m.methodSlotTarget(both, MethodSlotId.fromFunc(left_run)).?);
    try testing.expectEqual(both_run, m.methodSlotTarget(both, MethodSlotId.fromFunc(right_run)).?);
    const string_args = [_]applicability.ArgShape{.{
        .ty = .{ .name = "String", .nullable = false, .args = &.{} },
    }};
    const inherited = m.resolveMemberCall(child, "put", &string_args, .{});
    try testing.expectEqual(Module.MemberDispatch.virtual, inherited.dispatch);
    try testing.expectEqual(child_put, inherited.target.?);

    const modifier = try m.addClass(a, .{
        .id = ClassId.from(0), .name = "Modifier", .fqn = "sample.Modifier", .primary_params = &.{},
        .methods = &.{}, .init_block = null, .companion = null, .supertypes = &.{},
        .is_abstract = true, .is_interface = true,
    });
    _ = try m.addClass(a, .{
        .id = ClassId.from(0), .name = "Modifier.Element", .fqn = "sample.Modifier.Element", .primary_params = &.{},
        .methods = &.{}, .init_block = null, .companion = null, .supertypes = &.{},
        .is_abstract = true, .is_interface = true,
    });
    const combined = try m.addClass(a, .{
        .id = ClassId.from(0), .name = "Combined", .fqn = "sample.Combined", .primary_params = &.{},
        .methods = &.{}, .init_block = null, .companion = null,
        .supertypes = try a.dupe(ClassId, &.{modifier}),
        .supertype_refs = try a.dupe(TypeRef, &.{.{
            .name = "Modifier", .nullable = false, .args = &.{},
        }}),
    });
    const root_all = try pushTestFuncOpts(&m, a, "all", "sample.Modifier.all", "sample", 1, .{
        .stub = true, .param_ty = "Element",
    });
    const combined_all = try pushTestFuncOpts(&m, a, "all", "sample.Combined.all", "sample", 1, .{
        .param_ty = "Modifier.Element",
    });
    m.funcs.items[root_all.int()].kind = .instance_method;
    m.funcs.items[combined_all.int()].kind = .instance_method;
    m.funcs.items[combined_all.int()].is_override = true;
    m.classes.items[modifier.int()].methods = try a.dupe(FuncId, &.{root_all});
    m.classes.items[combined.int()].methods = try a.dupe(FuncId, &.{combined_all});
    const qualified_element_args = try a.dupe(TypeRef, &.{.{
        .name = "#qual:Modifier.Element",
        .nullable = false,
        .args = &.{},
    }});
    const all_types = [_]TypeRef{
        .{ .name = "Element", .nullable = false, .args = &.{} },
        .{
            .name = "Element",
            .nullable = false,
            .args = qualified_element_args,
        },
    };
    for (
        [_]FuncId{ root_all, combined_all },
        [_]ClassId{ modifier, combined },
        all_types,
    ) |fid, owner, ty| {
        try m.decl_sigs.put(fid.int(), .{
            .enclosing_class = owner,
            .arity = .{ .required = 1, .total = 1, .has_vararg = false },
            .sig = try a.dupe(TypeRef, &.{ty}),
            .kind = .instance_method,
            .has_body = m.funcs.items[fid.int()].hasBody(),
        });
        try m.registerMemberDecl(a, m.classes.items[owner.int()].fqn, "all", fid);
    }
    try m.linkMethodSlots(a);
    try testing.expectEqual(
        combined_all,
        m.methodSlotTarget(combined, MethodSlotId.fromFunc(root_all)).?,
    );
}

/// Options for the symbol-index test func pusher.
const TestFuncOpts = struct {
    /// `null` = body-bearing; otherwise a header stub with no blocks.
    stub: bool = false,
    low_priority: bool = false,
    /// Mark the last parameter `vararg`.
    last_vararg: bool = false,
    /// Give every parameter but the last a default, and type the last
    /// parameter `Function0` (the trailing-lambda gap shape).
    fn_tail_with_defaults: bool = false,
    /// First parameter is a synthesized receiver `this`.
    extension: bool = false,
    /// Type name for every user parameter (default `Int`).
    param_ty: []const u8 = "Int",
};

/// Push a top-level func with the given simple name, FQN, package, and
/// user-parameter count, returning its id. Used by the symbol-index tests.
fn pushTestFuncOpts(m: *Module, a: Allocator, name: []const u8, fqn: []const u8, package: []const u8, user_params: usize, opts: TestFuncOpts) !FuncId {
    const id = m.nextFuncId();
    const n_params = user_params + @as(usize, if (opts.extension) 1 else 0);
    const params = try a.alloc(Param, n_params);
    for (params, 0..) |*p, i| {
        p.* = .{ .name = "x", .ty = .{ .name = opts.param_ty, .nullable = false, .args = &.{} }, .default = null };
        if (opts.extension and i == 0) {
            p.name = "this";
            p.ty.name = "String";
        }
        if (opts.fn_tail_with_defaults) {
            if (i + 1 == n_params) {
                p.ty.name = "Function0";
            } else if (!(opts.extension and i == 0)) {
                p.has_default = true;
            }
        }
        if (opts.last_vararg and i + 1 == n_params) p.is_vararg = true;
    }
    const blocks = try a.alloc(Block, if (opts.stub) 0 else 1);
    if (!opts.stub) {
        blocks[0] = .{ .id = BlockId.from(0), .insts = &.{}, .terminator = .{ .Return = null } };
    }
    try m.funcs.append(a, .{
        .id = id,
        .name = name,
        .fqn = fqn,
        .package = package,
        .params = params,
        .return_ty = .{ .name = "Unit", .nullable = false, .args = &.{} },
        .n_locals = 0,
        .blocks = blocks,
        .entry = BlockId.from(0),
        .is_suspend = false,
        .low_priority = opts.low_priority,
    });
    try m.func_index.append(a, .{ .name = name, .id = id });
    return id;
}

fn pushTestFunc(m: *Module, a: Allocator, name: []const u8, fqn: []const u8, package: []const u8, user_params: usize) !FuncId {
    return pushTestFuncOpts(m, a, name, fqn, package, user_params, .{});
}

fn deferReasonOf(res: Module.BareCallResolution) ?Module.ResolveDeferReason {
    return switch (res.outcome) {
        .resolved => null,
        .deferred => |r| r,
    };
}

fn freeTestModule(m: *Module, a: Allocator) void {
    for (m.funcs.items) |f| {
        a.free(f.params);
        a.free(f.blocks);
    }
    m.deinit(a);
}

test "a bare call never binds a member extension of an unrelated class" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // `kotlin.with(receiver, block)` and, in another library, the member
    // extension `KeyframeEntity.with(easing)` declared inside
    // `KeyframesSpecConfig`. Both are header stubs with no declared-arity
    // record, so the applicability ladder ranks neither and the pick falls to
    // the declared-arity fallback -- whose user-over-shipped preference used
    // to hand a bare `with(x) { … }` the member extension.
    const std_with = try pushTestFuncOpts(&m, a, "with", "kotlin.with", "kotlin", 2, .{ .stub = true });
    const member_with = try pushTestFuncOpts(&m, a, "with", "with", "", 1, .{ .stub = true, .extension = true });
    m.funcs.items[member_with.int()].kind = .member_extension;
    try m.registry.member_ext_owner_class.put(member_with, "KeyframesSpecConfig");
    try m.rebuildFuncNameIndex(a);

    const args = [_]applicability.ArgShape{ .{}, .{} };
    // A caller inside an unrelated class has no `KeyframesSpecConfig`
    // receiver, so the member extension is not a candidate: `kotlin.with`.
    const res = try m.resolveCall(a, "with", "androidx.compose.ui.text", FileId.from(0), &args, true, .{
        .in_receiver_context = true,
        .owner_class = "MultiParagraph",
    });
    defer a.free(res.candidate_set);
    try testing.expect(res.target != null);
    try testing.expectEqual(std_with.int(), res.target.?.int());

    // Inside the declaring class the member extension IS in scope.
    const own = try m.resolveCall(a, "with", "androidx.compose.animation.core", FileId.from(0), &args, true, .{
        .in_receiver_context = true,
        .owner_class = "KeyframesSpecConfig",
    });
    defer a.free(own.candidate_set);
    try testing.expect(own.target != null);
    try testing.expectEqual(member_with.int(), own.target.?.int());
}

test "extension resolver proves receiver, scope, and overload identity" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    const int_arg = try pushTestFuncOpts(&m, a, "paint", "app.paint", "app", 1, .{ .extension = true });
    m.funcs.items[int_arg.int()].kind = .top_level_extension;
    const string_arg = try pushTestFuncOpts(&m, a, "paint", "app.paint", "app", 1, .{ .extension = true, .param_ty = "String" });
    m.funcs.items[string_arg.int()].kind = .top_level_extension;
    const int_receiver = try pushTestFuncOpts(&m, a, "paint", "app.paint", "app", 1, .{ .extension = true });
    m.funcs.items[int_receiver.int()].kind = .top_level_extension;
    m.funcs.items[int_receiver.int()].params[0].ty.name = "Int";
    _ = try pushTestFuncOpts(&m, a, "hidden", "other.hidden", "other", 0, .{ .extension = true });
    m.funcs.items[m.funcs.items.len - 1].kind = .top_level_extension;
    try m.rebuildFuncNameIndex(a);

    const typed_args = [_]applicability.ArgShape{.{
        .ty = .{ .name = "Int", .nullable = false, .args = &.{} },
    }};
    const resolved = m.resolveExtensionCall("paint", .{
        .name = "String",
        .nullable = false,
        .args = &.{},
    }, &typed_args, .{ .caller_file = FileId.from(0), .caller_package = "app" });
    try testing.expect(resolved.target != null);
    try testing.expectEqual(int_arg.int(), resolved.target.?.int());

    const ambiguous = m.resolveExtensionCall("paint", .{
        .name = "String",
        .nullable = false,
        .args = &.{},
    }, &.{.{}}, .{ .caller_file = FileId.from(0), .caller_package = "app" });
    try testing.expect(ambiguous.target == null);

    const out_of_scope = m.resolveExtensionCall("hidden", .{
        .name = "String",
        .nullable = false,
        .args = &.{},
    }, &.{}, .{ .caller_file = FileId.from(0), .caller_package = "app" });
    try testing.expect(out_of_scope.target == null);
}

test "symbol index prefers the caller's own package" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // Two same-name, same-arity funcs in different packages.
    const own = try pushTestFunc(&m, a, "greet", "app.greet", "app", 0);
    _ = try pushTestFunc(&m, a, "greet", "lib.greet", "lib", 0);
    try m.rebuildFuncNameIndex(a);

    // A caller in package `app` resolves its own `greet`, not lib's.
    const got = m.resolveBareCallIndexed("greet", "app", FileId.from(0), 0, false);
    try testing.expect(got.outcome == .resolved);
    try testing.expectEqual(own.int(), got.outcome.resolved.int());
    try testing.expectEqual(@as(u8, 1), got.tier);
    try testing.expectEqual(@as(usize, 1), got.tier_count);
}

test "symbol index ranks a named import above the caller's own package" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // Kotlin's scoping: an explicit `import lib.greet` outranks even a
    // declaration in the caller's own package (and file).
    _ = try pushTestFunc(&m, a, "greet", "app.greet", "app", 0);
    const imported = try pushTestFunc(&m, a, "greet", "lib.greet", "lib", 0);
    var paths: std.ArrayList(ModuleRegistry.ImportPath) = .empty;
    const segs = try a.alloc([]const u8, 2);
    segs[0] = "lib";
    segs[1] = "greet";
    try paths.append(a, .{ .fqn = try a.dupe(u8, "lib.greet"), .segs = segs });
    var inner = std.StringHashMap(std.ArrayList(ModuleRegistry.ImportPath)).init(a);
    try inner.put("greet", paths);
    try m.registry.import_aliases.put(FileId.from(0), inner);
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("greet", "app", FileId.from(0), 0, false);
    try testing.expect(got.outcome == .resolved);
    try testing.expectEqual(imported.int(), got.outcome.resolved.int());
    try testing.expectEqual(@as(u8, 0), got.tier);

    // From a file without the import the own-package declaration wins.
    const got2 = m.resolveBareCallIndexed("greet", "app", FileId.from(1), 0, false);
    try testing.expect(got2.outcome == .resolved);
    try testing.expectEqual(@as(u8, 1), got2.tier);
}

test "symbol index defers an out-of-scope pick when an in-scope extension exists" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // The only non-extension candidate lives in a package the caller
    // (kotlin.text) cannot see; a same-package extension also exists.
    // The call may bind the extension via an implicit receiver, so the
    // index must defer to the receiver-aware heuristic instead of
    // resolving (and later rejecting) the invisible function.
    _ = try pushTestFunc(&m, a, "firstOrNull", "firstOrNull", "", 1);
    _ = try pushTestFuncOpts(&m, a, "firstOrNull", "kotlin.text.firstOrNull", "kotlin.text", 1, .{ .extension = true });
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("firstOrNull", "kotlin.text", FileId.from(0), 1, false);
    try testing.expectEqual(Module.ResolveDeferReason.extension_form, deferReasonOf(got).?);

    // Without the extension, the invisible candidate still resolves (the
    // out-of-scope diagnostic is the lowering's call), tier 5.
    var m2 = Module.default(a);
    defer freeTestModule(&m2, a);
    _ = try pushTestFunc(&m2, a, "firstOrNull", "firstOrNull", "", 1);
    try m2.rebuildFuncNameIndex(a);
    const got2 = m2.resolveBareCallIndexed("firstOrNull", "kotlin.text", FileId.from(0), 1, false);
    try testing.expect(got2.outcome == .resolved);
    try testing.expectEqual(Module.other_package_tier, got2.tier);
}

test "symbol index defers when the preferred tier is ambiguous" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // Two same-name, same-arity, same-signature funcs in the CALLER's
    // package: in scope and indistinguishable, the index must defer as
    // ambiguous rather than pick one.
    const p_id = try pushTestFunc(&m, a, "h", "user.h", "user", 1);
    const q_id = try pushTestFunc(&m, a, "h", "user.x.h", "user", 1);
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("h", "user", FileId.from(0), 1, false);
    try testing.expectEqual(Module.ResolveDeferReason.ambiguous_tier, deferReasonOf(got).?);
    try testing.expectEqual(@as(usize, 2), got.tier_count);
    try testing.expectEqual(p_id.int(), got.first.?.int());
    try testing.expectEqual(q_id.int(), got.second.?.int());
}

test "symbol index classifies an out-of-scope identical set as unimported" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // Two identical funcs in two packages the caller neither declares
    // nor imports: Kotlin would resolve neither, so klio's lenient
    // cross-package pick stays with the heuristic instead of erroring.
    _ = try pushTestFunc(&m, a, "h", "p.h", "p", 1);
    _ = try pushTestFunc(&m, a, "h", "q.h", "q", 1);
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("h", "user", FileId.from(0), 1, false);
    try testing.expectEqual(Module.ResolveDeferReason.unimported_set, deferReasonOf(got).?);
}

test "symbol index ranks a default-import package above other built-ins" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // `kotlin.collections` is implicitly imported in every file; a
    // same-name sibling in a non-default kotlinx package is not in
    // scope, so the default-import candidate resolves uniquely.
    const dflt = try pushTestFunc(&m, a, "chk", "kotlin.collections.chk", "kotlin.collections", 1);
    _ = try pushTestFunc(&m, a, "chk", "kotlinx.other.chk", "kotlinx.other", 1);
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("chk", "user", FileId.from(0), 1, false);
    try testing.expect(got.outcome == .resolved);
    try testing.expectEqual(dflt.int(), got.outcome.resolved.int());
    try testing.expectEqual(@as(u8, 3), got.tier);
}

test "symbol index prefers a wildcard-imported package over other packages" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // Same name/arity in two non-caller packages; the caller's file
    // wildcard-imports one of them, which disambiguates (real Kotlin
    // scoping: explicit imports outrank everything but the own package).
    const imported = try pushTestFunc(&m, a, "sync", "locks.sync", "locks", 1);
    _ = try pushTestFunc(&m, a, "sync", "other.sync", "other", 1);
    var wl: std.ArrayList([]const u8) = .empty;
    try wl.append(a, try a.dupe(u8, "locks"));
    try m.registry.import_wildcards.put(FileId.from(0), wl);
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("sync", "user", FileId.from(0), 1, false);
    try testing.expect(got.outcome == .resolved);
    try testing.expectEqual(imported.int(), got.outcome.resolved.int());
    try testing.expectEqual(@as(u8, 2), got.tier);

    // From a different file (no wildcard import) neither candidate is in
    // scope; the identical tie defers to the lenient heuristic.
    const got2 = m.resolveBareCallIndexed("sync", "user", FileId.from(1), 1, false);
    try testing.expectEqual(Module.ResolveDeferReason.unimported_set, deferReasonOf(got2).?);
}

test "symbol index classifies a type-distinguishable overload set" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // Same package, same arity, DIFFERENT parameter types: runtime
    // argument types pick the overload, so this is never an ambiguity.
    _ = try pushTestFuncOpts(&m, a, "f", "app.f", "app", 1, .{ .param_ty = "Int" });
    _ = try pushTestFuncOpts(&m, a, "f", "app.f", "app", 1, .{ .param_ty = "String" });
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("f", "app", FileId.from(0), 1, false);
    try testing.expectEqual(Module.ResolveDeferReason.type_overload, deferReasonOf(got).?);
    try testing.expectEqual(@as(usize, 2), got.tier_count);
}

test "bounded call candidates never widen beyond the caller scope" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    const app_int = try pushTestFuncOpts(&m, a, "choose", "app.choose", "app", 1, .{ .param_ty = "Int" });
    const app_string = try pushTestFuncOpts(&m, a, "choose", "app.choose", "app", 1, .{ .param_ty = "String" });
    _ = try pushTestFuncOpts(&m, a, "choose", "lib.choose", "lib", 1, .{ .param_ty = "Int" });
    try m.rebuildFuncNameIndex(a);

    const scoped = (try m.boundedCallCandidates(a, "choose", "app", FileId.from(0), 1)).?;
    defer a.free(scoped);
    try testing.expectEqual(@as(usize, 2), scoped.len);
    try testing.expectEqual(app_int.int(), scoped[0].int());
    try testing.expectEqual(app_string.int(), scoped[1].int());

    const invisible = (try m.boundedCallCandidates(a, "choose", "other", FileId.from(0), 1)).?;
    defer a.free(invisible);
    try testing.expectEqual(@as(usize, 0), invisible.len);
    try testing.expect((try m.boundedCallCandidates(a, "missing", "app", FileId.from(0), 0)) == null);
}

test "bounded call candidates retain lower visible tiers for applicability" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    const local = try pushTestFuncOpts(&m, a, "assertContentEquals", "test.text.assertContentEquals", "test.text", 2, .{ .param_ty = "String" });
    const imported = try pushTestFuncOpts(&m, a, "assertContentEquals", "kotlin.test.assertContentEquals", "kotlin.test", 2, .{ .param_ty = "Sequence" });
    _ = try pushTestFuncOpts(&m, a, "assertContentEquals", "other.assertContentEquals", "other", 2, .{});
    var wildcards: std.ArrayList([]const u8) = .empty;
    try wildcards.append(a, try a.dupe(u8, "kotlin.test"));
    try m.registry.import_wildcards.put(FileId.from(0), wildcards);
    try m.rebuildFuncNameIndex(a);

    const scoped = (try m.boundedCallCandidates(a, "assertContentEquals", "test.text", FileId.from(0), 2)).?;
    defer a.free(scoped);
    try testing.expectEqual(@as(usize, 2), scoped.len);
    try testing.expectEqual(local.int(), scoped[0].int());
    try testing.expectEqual(imported.int(), scoped[1].int());
}

test "bounded call candidates preserve the incomplete-header host boundary" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    _ = try pushTestFuncOpts(&m, a, "hostOnly", "platform.hostOnly", "platform", 1, .{ .stub = true });
    try m.rebuildFuncNameIndex(a);

    try testing.expect((try m.boundedCallCandidates(a, "hostOnly", "app", FileId.from(0), 1)) == null);
}

test "bounded global candidates ignore a same-name member tier" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    const global = try pushTestFuncOpts(&m, a, "minOf", "kotlin.comparisons.minOf", "kotlin.comparisons", 2, .{});
    const member = try pushTestFuncOpts(&m, a, "minOf", "test.collections.CollectionTest.minOf", "test.collections", 0, .{});
    try m.decl_sigs.put(member.int(), .{
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .kind = .instance_method,
        .has_body = true,
    });
    try m.rebuildFuncNameIndex(a);

    const scoped = (try m.boundedCallCandidates(a, "minOf", "test.collections", FileId.from(0), 2)).?;
    defer a.free(scoped);
    try testing.expectEqual(@as(usize, 1), scoped.len);
    try testing.expectEqual(global.int(), scoped[0].int());
    try testing.expect((try m.boundedCallCandidates(a, "minOf", "test.collections", FileId.from(0), 4)) == null);
}

test "bounded spread candidates keep only varargs in the winning scope" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    _ = try pushTestFuncOpts(&m, a, "pick", "app.pick", "app", 2, .{});
    const app_ints = try pushTestFuncOpts(&m, a, "pick", "app.pick", "app", 2, .{ .last_vararg = true, .param_ty = "Int" });
    const app_strings = try pushTestFuncOpts(&m, a, "pick", "app.pick", "app", 2, .{ .last_vararg = true, .param_ty = "String" });
    _ = try pushTestFuncOpts(&m, a, "pick", "other.pick", "other", 2, .{ .last_vararg = true });
    try m.rebuildFuncNameIndex(a);

    const scoped = (try m.boundedSpreadCandidates(a, "pick", "app", FileId.from(0))).?;
    defer a.free(scoped);
    try testing.expectEqual(@as(usize, 2), scoped.len);
    try testing.expectEqual(app_ints.int(), scoped[0].int());
    try testing.expectEqual(app_strings.int(), scoped[1].int());
}

test "bounded spread candidates do not widen past a fixed-only tier" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    _ = try pushTestFuncOpts(&m, a, "pick", "imports.pick", "imports", 2, .{});
    _ = try pushTestFuncOpts(&m, a, "pick", "app.pick", "app", 2, .{ .last_vararg = true });
    var paths: std.ArrayList(ModuleRegistry.ImportPath) = .empty;
    const segs = try a.alloc([]const u8, 2);
    segs[0] = "imports";
    segs[1] = "pick";
    try paths.append(a, .{ .fqn = try a.dupe(u8, "imports.pick"), .segs = segs });
    var inner = std.StringHashMap(std.ArrayList(ModuleRegistry.ImportPath)).init(a);
    try inner.put("pick", paths);
    try m.registry.import_aliases.put(FileId.from(0), inner);
    try m.rebuildFuncNameIndex(a);

    const scoped = (try m.boundedSpreadCandidates(a, "pick", "app", FileId.from(0))).?;
    defer a.free(scoped);
    try testing.expectEqual(@as(usize, 0), scoped.len);
}

/// Record a declared-signature entry (all params `ty_name`, non-null,
/// no generic args) for a stub, mirroring phase-1 header registration.
fn putTestDeclSig(m: *Module, a: Allocator, id: FuncId, ty_name: []const u8, n: usize) !void {
    const sig = try a.alloc(TypeRef, n);
    for (sig) |*ty| ty.* = .{ .name = try a.dupe(u8, ty_name), .nullable = false, .args = &.{} };
    try m.decl_user_sig.put(id.int(), sig);
}

test "symbol index proves stub signatures through the declared record" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // One lowered body plus one forward-referenced stub of the same
    // name/arity. With a matching declared signature recorded at phase 1
    // the set is provably identical (ambiguous); without any record the
    // proof is forfeited (type overload).
    _ = try pushTestFunc(&m, a, "g", "app.g", "app", 1);
    const stub = try pushTestFuncOpts(&m, a, "g", "app.g2.g", "app", 0, .{ .stub = true });
    try m.decl_user_arity.put(stub.int(), .{ .required = 1, .total = 1, .has_vararg = false });
    try m.rebuildFuncNameIndex(a);

    const unproven = m.resolveBareCallIndexed("g", "app", FileId.from(0), 1, false);
    try testing.expectEqual(Module.ResolveDeferReason.type_overload, deferReasonOf(unproven).?);

    try putTestDeclSig(&m, a, stub, "Int", 1);
    const proven = m.resolveBareCallIndexed("g", "app", FileId.from(0), 1, false);
    try testing.expectEqual(Module.ResolveDeferReason.ambiguous_tier, deferReasonOf(proven).?);
}

test "resolveCall ranks a body-declared forward overload" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    _ = try pushTestFuncOpts(&m, a, "choose", "app.choose", "app", 1, .{ .param_ty = "String" });
    const forward = try pushTestFuncOpts(&m, a, "choose", "app.choose", "app", 1, .{ .stub = true, .param_ty = "Boolean" });
    try m.decl_user_arity.put(forward.int(), .{ .required = 1, .total = 1, .has_vararg = false });
    try putTestDeclSig(&m, a, forward, "Boolean", 1);
    try m.decl_sigs.put(forward.int(), .{
        .arity = .{ .required = 1, .total = 1, .has_vararg = false },
        .sig = m.decl_user_sig.get(forward.int()).?,
        .has_body = true,
    });
    try m.rebuildFuncNameIndex(a);

    const args = [_]applicability.ArgShape{.{
        .ty = .{ .name = "Boolean", .nullable = false, .args = &.{} },
    }};
    const resolved = try m.resolveCall(a, "choose", "app", FileId.from(0), &args, false, .{});
    defer a.free(resolved.candidate_set);
    try testing.expectEqual(forward.int(), resolved.target.?.int());
    try testing.expectEqual(Module.Confidence.exact, resolved.confidence);
}

test "resolveCall keeps an applicable trailing-lambda overload over the arity index" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    const trailing = try pushTestFuncOpts(&m, a, "verify", "app.verify", "app", 2, .{
        .fn_tail_with_defaults = true,
    });
    const scalar = try pushTestFuncOpts(&m, a, "verify", "app.verify", "app", 2, .{
        .param_ty = "Boolean",
    });
    m.funcs.items[scalar.int()].params[1].ty.name = "String";
    m.funcs.items[scalar.int()].params[1].has_default = true;
    try m.rebuildFuncNameIndex(a);

    const args = [_]applicability.ArgShape{.{
        .is_lambda = true,
        .lambda_arity = 0,
        .lambda_is_literal = true,
    }};
    const indexed = m.resolveBareCallIndexed("verify", "app", FileId.from(0), 1, true);
    try testing.expectEqual(scalar.int(), indexed.pick().?.int());
    const resolved = try m.resolveCall(a, "verify", "app", FileId.from(0), &args, true, .{});
    defer a.free(resolved.candidate_set);
    try testing.expectEqual(trailing.int(), resolved.target.?.int());
}

test "symbol index distinguishes overloads by generic arguments" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // Two same-package stubs whose declared params differ only in the
    // generic argument (`List<Int>` vs `List<String>`): a legal Kotlin
    // overload set the runtime dispatches by argument type, never an
    // ambiguity. Rewriting the second record to `List<Int>` makes the
    // pair a true duplicate and the verdict flips to ambiguous.
    const s1 = try pushTestFuncOpts(&m, a, "pick", "app.pick", "app", 0, .{ .stub = true });
    try m.decl_user_arity.put(s1.int(), .{ .required = 1, .total = 1, .has_vararg = false });
    {
        const sig = try a.alloc(TypeRef, 1);
        const args = try a.alloc(TypeRef, 1);
        args[0] = .{ .name = try a.dupe(u8, "Int"), .nullable = false, .args = &.{} };
        sig[0] = .{ .name = try a.dupe(u8, "List"), .nullable = false, .args = args };
        try m.decl_user_sig.put(s1.int(), sig);
    }
    const s2 = try pushTestFuncOpts(&m, a, "pick", "app.pick", "app", 0, .{ .stub = true });
    try m.decl_user_arity.put(s2.int(), .{ .required = 1, .total = 1, .has_vararg = false });
    {
        const sig = try a.alloc(TypeRef, 1);
        const args = try a.alloc(TypeRef, 1);
        args[0] = .{ .name = try a.dupe(u8, "String"), .nullable = false, .args = &.{} };
        sig[0] = .{ .name = try a.dupe(u8, "List"), .nullable = false, .args = args };
        try m.decl_user_sig.put(s2.int(), sig);
    }
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("pick", "app", FileId.from(0), 1, false);
    try testing.expectEqual(Module.ResolveDeferReason.type_overload, deferReasonOf(got).?);

    // Make the second stub's declared type IDENTICAL (`List<Int>`):
    // now nothing distinguishes the pair and it is a real ambiguity.
    {
        const old = m.decl_user_sig.fetchRemove(s2.int()).?;
        for (old.value) |*ty| ty.deinit(a);
        a.free(old.value);
        const fresh = try a.alloc(TypeRef, 1);
        const args = try a.alloc(TypeRef, 1);
        args[0] = .{ .name = try a.dupe(u8, "Int"), .nullable = false, .args = &.{} };
        fresh[0] = .{ .name = try a.dupe(u8, "List"), .nullable = false, .args = args };
        try m.decl_user_sig.put(s2.int(), fresh);
    }
    const got2 = m.resolveBareCallIndexed("pick", "app", FileId.from(0), 1, false);
    try testing.expectEqual(Module.ResolveDeferReason.ambiguous_tier, deferReasonOf(got2).?);
}

test "symbol index distinguishes a stub overload by its declared types" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // Body takes Int, forward-referenced stub declares String: a
    // type-dispatched overload set even though one body is unlowered.
    _ = try pushTestFunc(&m, a, "h2", "app.h2", "app", 1);
    const stub = try pushTestFuncOpts(&m, a, "h2", "app.x.h2", "app", 0, .{ .stub = true });
    try m.decl_user_arity.put(stub.int(), .{ .required = 1, .total = 1, .has_vararg = false });
    try putTestDeclSig(&m, a, stub, "String", 1);
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("h2", "app", FileId.from(0), 1, false);
    try testing.expectEqual(Module.ResolveDeferReason.type_overload, deferReasonOf(got).?);
}

test "resolveCall: an exact non-extension resolves to a static Call" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    const g = try pushTestFunc(&m, a, "g", "app.g", "app", 1);
    try m.rebuildFuncNameIndex(a);
    const args = [_]applicability.ArgShape{.{}};
    const res = try m.resolveCall(a, "g", "app", FileId.from(0), &args, false, .{});
    defer a.free(res.candidate_set);
    try testing.expectEqual(Module.EmitForm.Call, res.emit_form);
    try testing.expectEqual(Module.Confidence.exact, res.confidence);
    try testing.expectEqual(g.int(), res.target.?.int());
}

test "resolveCall binds bodyless host declarations by FuncId" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    const println = try pushTestFuncOpts(&m, a, "println", "kotlin.io.println", "kotlin.io", 1, .{ .stub = true });
    try m.decl_user_arity.put(println.int(), .{ .required = 1, .total = 1, .has_vararg = false });
    try putTestDeclSig(&m, a, println, "Any", 1);
    try m.decl_sigs.put(println.int(), .{
        .arity = .{ .required = 1, .total = 1, .has_vararg = false },
        .sig = m.decl_user_sig.get(println.int()).?,
        .host_backed = true,
    });

    const ints = try pushTestFuncOpts(&m, a, "intArrayOf", "kotlin.intArrayOf", "kotlin", 1, .{
        .stub = true,
        .last_vararg = true,
    });
    try m.decl_user_arity.put(ints.int(), .{ .required = 0, .total = 1, .has_vararg = true });
    try putTestDeclSig(&m, a, ints, "Int", 1);
    try m.decl_sigs.put(ints.int(), .{
        .arity = .{ .required = 0, .total = 1, .has_vararg = true },
        .sig = m.decl_user_sig.get(ints.int()).?,
        .host_backed = true,
    });
    try m.rebuildFuncNameIndex(a);

    const println_args = [_]applicability.ArgShape{.{
        .ty = .{ .name = "String", .nullable = false, .args = &.{} },
    }};
    const print_res = try m.resolveCall(a, "println", "app", FileId.from(0), &println_args, false, .{});
    defer a.free(print_res.candidate_set);
    try testing.expectEqual(println.int(), print_res.target.?.int());
    try testing.expectEqual(Module.EmitForm.Call, print_res.emit_form);
    try testing.expect(print_res.ty_proven);

    const int_args = [_]applicability.ArgShape{
        .{ .ty = .{ .name = "Int", .nullable = false, .args = &.{} } },
        .{ .ty = .{ .name = "Int", .nullable = false, .args = &.{} } },
        .{ .ty = .{ .name = "Int", .nullable = false, .args = &.{} } },
    };
    const ints_res = try m.resolveCall(a, "intArrayOf", "app", FileId.from(0), &int_args, false, .{});
    defer a.free(ints_res.candidate_set);
    try testing.expectEqual(ints.int(), ints_res.target.?.int());
    try testing.expectEqual(Module.EmitForm.Call, ints_res.emit_form);
    try testing.expect(ints_res.ty_proven);
}

test "resolveCall: a resolved extension in a receiver context defers to CallMemberOrGlobal" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // The only candidate is an extension; the index never resolves an ext, so
    // Phase B's ladder picks it and Phase C routes it to the member-first walk.
    const ext = try pushTestFuncOpts(&m, a, "ext", "app.ext", "app", 1, .{ .extension = true });
    try m.rebuildFuncNameIndex(a);
    const args = [_]applicability.ArgShape{.{}};
    const res = try m.resolveCall(a, "ext", "app", FileId.from(0), &args, false, .{
        .in_receiver_context = true,
        .unknown_receiver = true,
    });
    defer a.free(res.candidate_set);
    try testing.expectEqual(Module.EmitForm.CallMemberOrGlobal, res.emit_form);
    try testing.expectEqual(Module.Confidence.virtual, res.confidence);
    try testing.expectEqual(ext.int(), res.target.?.int());
}

test "resolveCall: a type-distinguishable stub overload defers to a receiver probe" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // Two same-arity stubs of different declared types under an intrinsic-
    // alias name: the index classifies type_overload; the applicability ladder
    // is body-only and the declared-arity fallback is gated off for aliases,
    // so Phase B finds nothing and the call defers to the runtime probe.

    const s1 = try pushTestFuncOpts(&m, a, "minOf", "app.minOf", "app", 0, .{ .stub = true });
    try m.decl_user_arity.put(s1.int(), .{ .required = 1, .total = 1, .has_vararg = false });
    try putTestDeclSig(&m, a, s1, "Int", 1);
    const s2 = try pushTestFuncOpts(&m, a, "minOf", "app.x.minOf", "app", 0, .{ .stub = true });
    try m.decl_user_arity.put(s2.int(), .{ .required = 1, .total = 1, .has_vararg = false });
    try putTestDeclSig(&m, a, s2, "String", 1);
    try m.rebuildFuncNameIndex(a);
    const args = [_]applicability.ArgShape{.{}};
    const res = try m.resolveCall(a, "minOf", "app", FileId.from(0), &args, false, .{ .in_receiver_context = true });
    defer a.free(res.candidate_set);
    try testing.expectEqual(Module.ResolveDeferReason.type_overload, res.reason.?);
    try testing.expect(res.target == null);
    try testing.expectEqual(Module.EmitForm.CallMemberOrGlobal, res.emit_form);
    try testing.expectEqual(Module.Confidence.deferred, res.confidence);
}

test "resolveCall: a shadowed value capture defers to CallValue" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // No same-name top-level function exists; the name is a captured local.
    try m.rebuildFuncNameIndex(a);
    const args = [_]applicability.ArgShape{.{}};
    const res = try m.resolveCall(a, "cb", "app", FileId.from(0), &args, false, .{ .is_value_capture = true });
    defer a.free(res.candidate_set);
    try testing.expectEqual(Module.EmitForm.CallValue, res.emit_form);
    try testing.expectEqual(Module.Confidence.deferred, res.confidence);
    try testing.expect(res.target == null);
}

test "symbol index never resolves an extension form" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // One candidate, an extension (leading `this` param): the index does
    // not model receiver resolution, so it defers to the heuristic.
    _ = try pushTestFuncOpts(&m, a, "ext", "app.ext", "app", 0, .{ .extension = true });
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("ext", "app", FileId.from(0), 0, false);
    try testing.expectEqual(Module.ResolveDeferReason.extension_form, deferReasonOf(got).?);
}

test "symbol index defers an unknown name as no_candidates" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("nope", "app", FileId.from(0), 0, false);
    try testing.expectEqual(Module.ResolveDeferReason.no_candidates, deferReasonOf(got).?);
}

test "symbol index resolves an intrinsic-backed name like any other symbol" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // `compareValues` is an ordinary symbol: it resolves through the index like
    // any other function. Its native intrinsic attaches at run time via
    // `resolvedNativeForm`, not through a name-based index escape hatch.
    const fid = try pushTestFunc(&m, a, "compareValues", "kotlin.comparisons.compareValues", "kotlin.comparisons", 2);
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("compareValues", "app", FileId.from(0), 2, false);
    try testing.expectEqual(fid, got.pick().?);
}

test "symbol index defers an arity mismatch in the winning tier" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    _ = try pushTestFunc(&m, a, "f", "app.f", "app", 2);
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("f", "app", FileId.from(0), 1, false);
    try testing.expectEqual(Module.ResolveDeferReason.arity_mismatch, deferReasonOf(got).?);
    try testing.expectEqual(@as(u8, 1), got.tier);
}

test "symbol index defers a bodyless decl with no declared-arity record" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // A bodyless func without a `decl_user_arity` entry cannot be ranked.
    _ = try pushTestFuncOpts(&m, a, "g", "app.g", "app", 0, .{ .stub = true });
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("g", "app", FileId.from(0), 0, false);
    try testing.expectEqual(Module.ResolveDeferReason.bodyless_only, deferReasonOf(got).?);
}

test "symbol index defers when only a low-priority overload matches" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    _ = try pushTestFuncOpts(&m, a, "lp", "app.lp", "app", 1, .{ .low_priority = true });
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("lp", "app", FileId.from(0), 1, false);
    try testing.expectEqual(Module.ResolveDeferReason.low_priority_only, deferReasonOf(got).?);
}

test "symbol index defers a trailing-vararg candidate" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    _ = try pushTestFuncOpts(&m, a, "va", "app.va", "app", 1, .{ .last_vararg = true });
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("va", "app", FileId.from(0), 1, false);
    try testing.expectEqual(Module.ResolveDeferReason.vararg_only, deferReasonOf(got).?);
}

test "symbol index defers a default-gap trailing-lambda shape" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // `fun tl(x: Int = 0, body: () -> Unit)` called as `tl { ... }`:
    // one supplied arg (the lambda), the gap param defaulted — the
    // heuristic's trailing-lambda rung handles this, the index defers.
    _ = try pushTestFuncOpts(&m, a, "tl", "app.tl", "app", 2, .{ .fn_tail_with_defaults = true });
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("tl", "app", FileId.from(0), 1, true);
    try testing.expectEqual(Module.ResolveDeferReason.trailing_lambda_shape, deferReasonOf(got).?);

    // Without the trailing lambda the same call is a plain arity miss.
    const got2 = m.resolveBareCallIndexed("tl", "app", FileId.from(0), 1, false);
    try testing.expectEqual(Module.ResolveDeferReason.arity_mismatch, deferReasonOf(got2).?);
}

test "symbol index ranks a forward-referenced stub by declared arity" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // An own-package phase-1 stub (body not lowered yet) with a recorded
    // exact declared arity resolves, independent of lowering order.
    const stub = try pushTestFuncOpts(&m, a, "fwd", "app.fwd", "app", 0, .{ .stub = true });
    try m.decl_user_arity.put(stub.int(), .{ .required = 1, .total = 1, .has_vararg = false });
    _ = try pushTestFunc(&m, a, "fwd", "lib.fwd", "lib", 1);
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("fwd", "app", FileId.from(0), 1, false);
    try testing.expect(got.outcome == .resolved);
    try testing.expectEqual(stub.int(), got.outcome.resolved.int());
    try testing.expectEqual(@as(u8, 1), got.tier);
}

test "symbol index resolves a default-compatible stub and defers varargs" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    const dflt = try pushTestFuncOpts(&m, a, "d", "app.d", "app", 2, .{ .stub = true });
    m.funcByIdMut(dflt).?.params[1].has_default = true;
    try m.decl_user_arity.put(dflt.int(), .{ .required = 1, .total = 2, .has_vararg = false });
    const va = try pushTestFuncOpts(&m, a, "v", "app.v", "app", 1, .{ .stub = true, .last_vararg = true });
    try m.decl_user_arity.put(va.int(), .{ .required = 0, .total = 1, .has_vararg = true });
    try m.rebuildFuncNameIndex(a);

    const got_d = m.resolveBareCallIndexed("d", "app", FileId.from(0), 1, false);
    try testing.expect(got_d.outcome == .resolved);
    try testing.expectEqual(dflt.int(), got_d.outcome.resolved.int());
    const got_v = m.resolveBareCallIndexed("v", "app", FileId.from(0), 1, false);
    try testing.expectEqual(Module.ResolveDeferReason.vararg_only, deferReasonOf(got_v).?);
}

test "symbol index resolves a default-bearing body" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // `fun d(x: Int, y: Int = 0)` binds both its full and under-applied
    // positional forms to the same static target.
    const body = try pushTestFuncOpts(&m, a, "d", "app.d", "app", 2, .{});
    m.funcByIdMut(body).?.params[1].has_default = true;
    try m.rebuildFuncNameIndex(a);

    const full = m.resolveBareCallIndexed("d", "app", FileId.from(0), 2, false);
    try testing.expect(full.outcome == .resolved);
    try testing.expectEqual(body.int(), full.outcome.resolved.int());
    const omitted = m.resolveBareCallIndexed("d", "app", FileId.from(0), 1, false);
    try testing.expect(omitted.outcome == .resolved);
    try testing.expectEqual(body.int(), omitted.outcome.resolved.int());
}

test "symbol index prefers exact arity over a default-consuming overload" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    const exact = try pushTestFuncOpts(&m, a, "d", "app.d1", "app", 1, .{});
    const wider = try pushTestFuncOpts(&m, a, "d", "app.d2", "app", 2, .{});
    m.funcByIdMut(wider).?.params[1].has_default = true;
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("d", "app", FileId.from(0), 1, false);
    try testing.expect(got.outcome == .resolved);
    try testing.expectEqual(exact.int(), got.outcome.resolved.int());
}

test "resolveCall emits a static Call for an omitted default" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    const target = try pushTestFuncOpts(&m, a, "Job", "app.Job", "app", 1, .{});
    m.funcByIdMut(target).?.params[0].has_default = true;
    try m.rebuildFuncNameIndex(a);

    const res = try m.resolveCall(a, "Job", "app", FileId.from(0), &.{}, false, .{});
    defer a.free(res.candidate_set);
    try testing.expectEqual(Module.EmitForm.Call, res.emit_form);
    try testing.expectEqual(Module.Confidence.exact, res.confidence);
    try testing.expectEqual(target.int(), res.target.?.int());
}

test "packageHeadDeclared distinguishes a package head from a member head" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer {
        for (m.funcs.items) |f| {
            a.free(f.params);
            a.free(f.blocks);
        }
        m.deinit(a);
    }
    // A top-level func in package `mypkg` makes `mypkg` a declared package
    // head; a top-level func with no package (`helper`) is not a head.
    _ = try pushTestFunc(&m, a, "build", "mypkg.build", "mypkg", 0);
    _ = try pushTestFunc(&m, a, "helper", "helper", "", 0);

    // `mypkg.build(...)` — `mypkg` is the first segment of a declared FQN,
    // so it is a package head that flattens to a global load.
    try testing.expect(m.packageHeadDeclared("mypkg"));
    // `helper.foo` — `helper` names a top-level symbol, not a package
    // prefix, so it is a member/receiver head, not a package head.
    try testing.expect(!m.packageHeadDeclared("helper"));
    // A name with no declaration at all (a receiver member like `inner`)
    // is never a package head.
    try testing.expect(!m.packageHeadDeclared("inner"));
    try testing.expect(!m.packageHeadDeclared(""));
}

test "funcId ranks a user declaration above a shipped same-name" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // Shipped decl concatenates first (packs precede user sources).
    _ = try pushTestFunc(&m, a, "shuffle", "kotlin.collections.shuffle", "kotlin.collections", 1);
    const user = try pushTestFunc(&m, a, "shuffle", "shuffle", "", 1);
    try m.rebuildFuncNameIndex(a);
    try testing.expectEqual(user.int(), m.funcId("shuffle").?.int());

    // The package classification is a head-segment match, not a raw
    // prefix: a user package starting with `kotlinx2` is not shipped.
    var m2 = Module.default(a);
    defer freeTestModule(&m2, a);
    _ = try pushTestFunc(&m2, a, "go", "kotlinx.coroutines.go", "kotlinx.coroutines", 0);
    const user2 = try pushTestFunc(&m2, a, "go", "kotlinx2.go", "kotlinx2", 0);
    try m2.rebuildFuncNameIndex(a);
    try testing.expectEqual(user2.int(), m2.funcId("go").?.int());
}

test "funcId prefers a body sibling over a bodyless shipped pair" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // Both shipped: the bodyless `expect` must not hide the body sibling.
    _ = try pushTestFuncOpts(&m, a, "now", "kotlin.time.now", "kotlin.time", 0, .{ .stub = true });
    const actual = try pushTestFunc(&m, a, "now", "kotlin.time.now.actual", "kotlin.time", 0);
    try m.rebuildFuncNameIndex(a);
    try testing.expectEqual(actual.int(), m.funcId("now").?.int());
}

test "hasFuncNamed answers over the name index" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    _ = try pushTestFunc(&m, a, "f", "pkg.f", "pkg", 0);
    try m.rebuildFuncNameIndex(a);
    try testing.expect(m.hasFuncNamed("f"));
    try testing.expect(!m.hasFuncNamed("g"));
}

fn pushTestClass(m: *Module, a: Allocator, name: []const u8, fqn: []const u8, package: []const u8) !ClassId {
    return m.addClass(a, .{
        .id = ClassId.from(0),
        .name = name,
        .fqn = fqn,
        .package = package,
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
}

test "classIdIndexed prefers the caller's own package on a collision" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer m.deinit(a);
    const lib = try pushTestClass(&m, a, "Config", "lib.Config", "lib");
    const app = try pushTestClass(&m, a, "Config", "app.Config", "app");
    // Flat lookup returns the first declaration regardless of caller.
    try testing.expectEqual(lib.int(), m.classId("Config").?.int());
    // The indexed lookup binds the class the caller's package declares.
    try testing.expectEqual(app.int(), m.classIdIndexed("Config", "app", FileId.from(0)).?.int());
    try testing.expectEqual(lib.int(), m.classIdIndexed("Config", "lib", FileId.from(0)).?.int());
    // A caller in neither package keeps the declaration-order pick.
    try testing.expectEqual(lib.int(), m.classIdIndexed("Config", "other", FileId.from(0)).?.int());
    try testing.expect(m.classIdIndexed("Missing", "app", FileId.from(0)) == null);
}

test "bare-ref index resolves a unique candidate with no arity filter" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // Vararg and defaulted shapes the CALL index defers on still
    // resolve as references.
    const f = try pushTestFuncOpts(&m, a, "fmt", "app.fmt", "app", 2, .{ .last_vararg = true });
    try m.rebuildFuncNameIndex(a);
    try testing.expectEqual(f.int(), m.resolveBareRefIndexed("fmt", "app", FileId.from(0)).?.int());
    // Cross-package: the caller's own package wins over another package.
    const own = try pushTestFunc(&m, a, "pick", "app.pick", "app", 0);
    _ = try pushTestFunc(&m, a, "pick", "lib.pick", "lib", 0);
    try m.rebuildFuncNameIndex(a);
    try testing.expectEqual(own.int(), m.resolveBareRefIndexed("pick", "app", FileId.from(0)).?.int());
}

test "bare-ref index defers ambiguity, extensions, and unknown names" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // Two same-tier candidates: ambiguous, defer.
    _ = try pushTestFunc(&m, a, "h", "app.h", "app", 0);
    _ = try pushTestFunc(&m, a, "h", "app.util.h", "app", 1);
    // A single extension-form candidate: never a bare reference.
    _ = try pushTestFuncOpts(&m, a, "ext", "app.ext", "app", 1, .{ .extension = true });
    try m.rebuildFuncNameIndex(a);
    try testing.expect(m.resolveBareRefIndexed("h", "app", FileId.from(0)) == null);
    try testing.expect(m.resolveBareRefIndexed("ext", "app", FileId.from(0)) == null);
    try testing.expect(m.resolveBareRefIndexed("missing", "app", FileId.from(0)) == null);
    try testing.expect(m.resolveBareRefIndexed("compareValues", "app", FileId.from(0)) == null);
}

test "classIdIndexed ranks a named import above the own package" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer m.deinit(a);
    _ = try pushTestClass(&m, a, "Config", "app.Config", "app");
    const imported = try pushTestClass(&m, a, "Config", "lib.Config", "lib");
    var paths: std.ArrayList(ModuleRegistry.ImportPath) = .empty;
    const segs = try a.alloc([]const u8, 2);
    segs[0] = "lib";
    segs[1] = "Config";
    try paths.append(a, .{ .fqn = try a.dupe(u8, "lib.Config"), .segs = segs });
    var inner = std.StringHashMap(std.ArrayList(ModuleRegistry.ImportPath)).init(a);
    try inner.put("Config", paths);
    try m.registry.import_aliases.put(FileId.from(0), inner);
    try testing.expectEqual(imported.int(), m.classIdIndexed("Config", "app", FileId.from(0)).?.int());
    // A file without the import resolves the own-package class.
    try testing.expectEqual(
        m.classIdByFqn("app.Config").?.int(),
        m.classIdIndexed("Config", "app", FileId.from(1)).?.int(),
    );
}
