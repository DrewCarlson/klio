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
        /// When set, this is a member-dispatched spread call: the
        /// flattened args are passed to method `member` on the value in
        /// `callee` (the receiver), rather than invoking `callee` as a
        /// callable. Lets `recv.method(*array)` / a bare own-member
        /// `m(*array)` dispatch through member resolution.
        member: ?ConstId = null,
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
        /// The receiver's DECLARED type head when lowering knows it (a
        /// bare call on the implicit `this` of an extension body, whose
        /// static type is the extension's declared receiver). Kotlin
        /// resolves extension calls against the static receiver type, so
        /// dispatch must not bind a runtime subtype's same-name
        /// extension when this is set.
        static_recv: ?ConstId = null,
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
    LoadGlobal: struct { dst: Reg, name: ConstId, func: ?FuncId = null, class: ?ClassId = null },
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
        /// The scope-resolved class when the bare name is a constructor
        /// call the index bound; the global leg constructs exactly this
        /// class instead of re-resolving the simple name.
        class: ?ClassId = null,
        /// The lowering-resolved top-level function when the bare call
        /// would have bound statically but a runtime receiver member can
        /// shadow it; the global leg calls exactly this declaration
        /// instead of re-resolving the simple name.
        func: ?FuncId = null,
        /// An inline-splice's bound receiver, held in a local register rather
        /// than the frame's `this` slot or a capture. When set it is the
        /// innermost implicit-receiver candidate, ahead of the frame `this`
        /// and the enclosing chain — so a bare extension call inside a spliced
        /// receiver-lambda (`collect` in `FlowCollector.()`) can miss the
        /// lambda receiver and bind the outer one.
        recv: ?Reg = null,
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
    /// `inner class` — instances capture an enclosing-class instance.
    /// Construction-site lowering consults this so a lambda building a
    /// bare `Inner()` captures the enclosing `this` it depends on.
    is_inner: bool = false,
    /// `abstract class` / `interface` / `sealed class` — cannot be
    /// constructed directly. A bare `Name(args)` call against such a class
    /// is therefore never construction; it must resolve to a same-named
    /// factory function, so bare-call lowering must not treat it as a ctor.
    is_abstract: bool = false,
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
pub const Module = struct {
    funcs: std.ArrayList(Func) = .empty,
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
        return .{
            .func_name_index = std.StringHashMap(std.ArrayList(FuncId)).init(allocator),
            .registry = ModuleRegistry.init(allocator),
            .decl_user_params = std.AutoHashMap(u32, u32).init(allocator),
            .decl_user_arity = std.AutoHashMap(u32, DeclArity).init(allocator),
            .decl_user_sig = std.AutoHashMap(u32, []TypeRef).init(allocator),
            .decl_span = std.AutoHashMap(u32, Span).init(allocator),
        };
    }

    /// Mirrors Rust's `#[derive(Default)]` constructor.
    pub fn default(allocator: Allocator) Module {
        return Module.init(allocator);
    }

    /// Materialise `func`'s deferred `blocks` from the lazy-IR section, clearing
    /// `deferred_offset` so it is a no-op afterwards. Decoded into the module's
    /// process-lifetime arena so the patch persists across per-program builds.
    pub fn ensureFuncBody(self: *const Module, func: *Func) void {
        if (func.deferred_offset == 0) return;
        const decode = self.deferred_func_decode orelse return;
        if (decode(self.deferred_func_arena, self.deferred_func_section, func.deferred_offset - 1)) |blocks| {
            func.blocks = blocks;
            func.deferred_offset = 0;
        }
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
        self.func_index.deinit(allocator);
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
        self.resolve_diags.deinit(allocator);
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
        try out.resolve_diags.appendSlice(a, self.resolve_diags.items);
        return out;
    }

    /// Look up a class by simple name.
    pub fn classId(self: *const Module, name: []const u8) ?ClassId {
        if (self.class_id_map) |*m| return m.get(name);
        for (self.class_index.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.id;
        }
        return null;
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
        for (candidates) |id| {
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
        return first_user orelse first_body orelse first;
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

    /// The full segment path of the first non-wildcard import whose
    /// leaf is `name`, as seen from source file `file`. A named import
    /// is file-scoped, so only imports declared in `file` are consulted.
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
        "kotlin.math",
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
    fn scopeTier(self: *const Module, fqn: []const u8, pkg: []const u8, name: []const u8, caller_pkg: []const u8, caller_file: FileId) u8 {
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
        /// Every near match declares a default parameter — a
        /// `required..total` acceptance range the index does not rank.
        /// Stubs and bodies defer this shape alike, so the verdict never
        /// depends on whether a candidate's body has been lowered yet.
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
    /// its exact-match count for the resolve audit's readout.
    pub const BareCallResolution = struct {
        pub const Outcome = union(enum) {
            resolved: FuncId,
            deferred: ResolveDeferReason,
        };
        outcome: Outcome,
        /// Winning preference tier (0..5), or 255 when no candidate
        /// established one.
        tier: u8 = 255,
        /// Exact-arity matches counted within the winning tier.
        tier_count: usize = 0,
        /// First two exact matches in the winning tier; both set when
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

    /// Whether any user parameter (leading synthesized `this` excluded)
    /// declares a default value.
    fn anyUserParamDefault(f: *const Func) bool {
        const off: usize = if (funcHasImplicitThis(f)) 1 else 0;
        for (f.params[off..]) |p| {
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
    /// non-empty tier; within that tier the candidate is returned only
    /// when exactly one non-extension func matches the requested arity
    /// exactly with no default parameters. Extension funcs (a leading
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
        caller_pkg: []const u8,
        caller_file: FileId,
        want_arity: usize,
        last_arg_lambda: bool,
    ) BareCallResolution {
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

        // Within the best tier, look for a unique exact-arity,
        // non-low-priority, non-extension candidate. Track the closest
        // miss so a zero-match tier defers with the blocking shape.
        var chosen: ?FuncId = null;
        var second: ?FuncId = null;
        var count: usize = 0;
        // Whether every exact match is body-bearing with the same user
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
            // The stub and body gates must accept the SAME candidate
            // shapes (exact arity, no defaults, no vararg at any
            // position) so the resolution — and the ambiguity verdict —
            // never depends on whether a candidate's body lowered
            // before the call site.
            if (is_stub) {
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
                if (da.total != want_arity) {
                    saw_arity = true;
                    continue;
                }
                if (da.required != da.total) {
                    saw_default = true;
                    continue;
                }
            } else {
                if (f.low_priority) {
                    saw_low = true;
                    continue;
                }
                if (anyParamVararg(f)) {
                    saw_vararg = true;
                    continue;
                }
                if (funcUserArity(f) != want_arity) {
                    if (last_arg_lambda and tlShapeMatches(f, want_arity)) {
                        saw_tl = true;
                    } else {
                        saw_arity = true;
                    }
                    continue;
                }
                if (anyUserParamDefault(f)) {
                    saw_default = true;
                    continue;
                }
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
            for (self.class_index.items) |entry| {
                if (!std.mem.eql(u8, entry.name, class.name)) continue;
                const existing = &self.classes.items[entry.id.int()];
                if (std.mem.eql(u8, existing.fqn, class.fqn)) {
                    class.id = entry.id;
                    self.classes.items[entry.id.int()] = class;
                    return entry.id;
                }
                if (legacy_stub == null and existing.is_stub and std.mem.eql(u8, existing.fqn, class.name)) {
                    legacy_stub = entry.id;
                }
            }
            if (legacy_stub) |id| {
                class.id = id;
                self.classes.items[id.int()] = class;
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

    pub fn classIdByFqn(self: *const Module, fqn: []const u8) ?ClassId {
        if (self.class_fqn_map) |*m| {
            const id = m.get(fqn) orelse return null;
            return if (id == class_id_ambiguous) null else id;
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
    /// `Module.deinit` frees these copies, matching how Rust's
    /// `Const::String(String)` owns and drops its data.
    pub fn internConst(self: *Module, allocator: Allocator, c: Const) Allocator.Error!ConstId {
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
};

/// True when `head` is the first dotted segment of `fqn` and `fqn` has
/// at least one further segment — i.e. `fqn` is `head.<rest>`, so `head`
/// is a package prefix of a real symbol rather than the symbol's own
/// simple name.
fn fqnHasHeadSegment(fqn: []const u8, head: []const u8) bool {
    return fqn.len > head.len and
        std.mem.startsWith(u8, fqn, head) and
        fqn[head.len] == '.';
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
/// when out of range. Mirrors Rust's `slice.get(idx)`.
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
    /// Top-level property names declared with `by <delegate>`.
    /// Reads/writes route through the stored delegate's `getValue` /
    /// `setValue` methods.
    top_level_delegated_props: std.StringHashMap(void),
    /// Class simple name → the set of member *function* names it
    /// declares or inherits (transitively over supertypes). Lets the
    /// lowerer honor Kotlin's separate function/property namespaces.
    hierarchy_methods: std.StringHashMap(std.StringHashMap(void)),
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
    /// `FuncId` → declaring-class simple name for *member extension
    /// functions* (`class C { fun R.f(...) { … } }`). Empty for
    /// top-level extensions.
    member_ext_owner_class: std.AutoHashMap(FuncId, []const u8),
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

    pub fn init(allocator: Allocator) ModuleRegistry {
        return .{
            .companion_singletons = std.StringHashMap([]const u8).init(allocator),
            .enclosing_class = std.StringHashMap([]const u8).init(allocator),
            .func_type_params = std.AutoHashMap(FuncId, std.ArrayList([]const u8)).init(allocator),
            .func_type_param_bounds = std.AutoHashMap(FuncId, []const TypeParamBound).init(allocator),
            .top_level_delegated_props = std.StringHashMap(void).init(allocator),
            .hierarchy_methods = std.StringHashMap(std.StringHashMap(void)).init(allocator),
            .class_member_names = std.StringHashMap(void).init(allocator),
            .class_super_names = std.StringHashMap([]const []const u8).init(allocator),
            .delegated_body_props = StrPairSet.init(allocator),
            .member_ext_owner_class = std.AutoHashMap(FuncId, []const u8).init(allocator),
            .local_fn_defaults = std.AutoHashMap(FuncId, std.ArrayList(?FuncId)).init(allocator),
            .abstract_member_defaults = StrPairMap(std.ArrayList(?FuncId)).init(allocator),
            .type_aliases = std.StringHashMap([]const u8).init(allocator),
            .import_aliases = std.AutoHashMap(FileId, std.StringHashMap(std.ArrayList(ImportPath))).init(allocator),
            .import_wildcards = std.AutoHashMap(FileId, std.ArrayList([]const u8)).init(allocator),
            .nested_object_aliases = std.StringHashMap(std.StringHashMap([]const u8)).init(allocator),
            .mangled_nested = std.StringHashMap([]const u8).init(allocator),
            .class_const_inits = StrPairMap(Const).init(allocator),
            .top_level_prop_pkgs = std.StringHashMap(std.ArrayList(PropDecl)).init(allocator),
            .top_level_prop_getters = std.StringHashMap(FuncId).init(allocator),
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
        self.top_level_delegated_props.deinit();
        {
            var it = self.hierarchy_methods.valueIterator();
            while (it.next()) |inner| inner.deinit();
            self.hierarchy_methods.deinit();
        }
        self.class_member_names.deinit();
        {
            var it = self.class_super_names.valueIterator();
            while (it.next()) |names| a.free(names.*);
            self.class_super_names.deinit();
        }
        self.delegated_body_props.deinit();
        self.member_ext_owner_class.deinit();
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
            var it = self.top_level_delegated_props.keyIterator();
            while (it.next()) |k| try out.top_level_delegated_props.put(k.*, {});
        }
        {
            var it = self.hierarchy_methods.iterator();
            while (it.next()) |e| try out.hierarchy_methods.put(e.key_ptr.*, e.value_ptr.*);
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
            var it = self.member_ext_owner_class.iterator();
            while (it.next()) |e| try out.member_ext_owner_class.put(e.key_ptr.*, e.value_ptr.*);
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

// -------------------------------------------------------------------------
// Tests (mirrors the Rust crate's `lib.rs` `mod tests`)
// -------------------------------------------------------------------------

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

test "symbol index defers a stub whose declared arity has defaults or varargs" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // required < total (a default param): only an exact no-default
    // declared arity is rankable without the lowered body.
    const dflt = try pushTestFuncOpts(&m, a, "d", "app.d", "app", 0, .{ .stub = true });
    try m.decl_user_arity.put(dflt.int(), .{ .required = 1, .total = 2, .has_vararg = false });
    const va = try pushTestFuncOpts(&m, a, "v", "app.v", "app", 0, .{ .stub = true });
    try m.decl_user_arity.put(va.int(), .{ .required = 0, .total = 1, .has_vararg = true });
    try m.rebuildFuncNameIndex(a);

    const got_d = m.resolveBareCallIndexed("d", "app", FileId.from(0), 2, false);
    try testing.expectEqual(Module.ResolveDeferReason.default_param_shape, deferReasonOf(got_d).?);
    const got_v = m.resolveBareCallIndexed("v", "app", FileId.from(0), 1, false);
    try testing.expectEqual(Module.ResolveDeferReason.vararg_only, deferReasonOf(got_v).?);
}

test "symbol index defers a default-bearing body exactly like its stub" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // `fun d(x: Int, y: Int = 0)` as a lowered BODY: a full-arity call
    // must defer the same way the phase-1 stub gate defers
    // `required != total`, so the verdict cannot flip with declaration
    // order once the body lowers.
    const body = try pushTestFuncOpts(&m, a, "d", "app.d", "app", 2, .{});
    m.funcByIdMut(body).?.params[1].has_default = true;
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("d", "app", FileId.from(0), 2, false);
    try testing.expectEqual(Module.ResolveDeferReason.default_param_shape, deferReasonOf(got).?);
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
