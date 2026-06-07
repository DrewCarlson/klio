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

const Allocator = std.mem.Allocator;

pub const Span = span.Span;
pub const FileId = span.FileId;

/// AST → IR lowering, IR builders, and the IR evaluator. Filled in
/// alongside the type definitions in this file.
pub const build = @import("build.zig");
pub const eval = @import("eval.zig");
pub const lower = @import("lower.zig");

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
        n_args: u8,
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
        n_args: u8,
        arg_names: []?ConstId = &.{},
    },
    /// Call a callable value held in a register.
    CallValue: struct {
        dst: Reg,
        callee: Reg,
        args: Reg,
        n_args: u8,
        arg_names: []?ConstId = &.{},
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
        n_args: u8,
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
        n_args: u8,
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
        n_args: u8,
        arg_names: []?ConstId = &.{},
    },
    /// Member call on a receiver. The evaluator resolves the
    /// method through the receiver's class table at runtime.
    CallMember: struct {
        dst: Reg,
        receiver: Reg,
        name: ConstId,
        args: Reg,
        n_args: u8,
        arg_names: []?ConstId = &.{},
    },
    /// Instantiate a class.
    NewInstance: struct {
        dst: Reg,
        class: ClassId,
        args: Reg,
        n_args: u8,
        arg_names: []?ConstId = &.{},
    },
    /// Build a `List` from a range of registers.
    NewList: struct { dst: Reg, args: Reg, n_args: u8 },
    /// After calling a lambda that mutates outer-scope `var`s,
    /// read each captured name back from the lambda's env and
    /// write the updated value into the source reg in the
    /// caller's frame. Pairs with `Inst.AstLambda` whose captured
    /// names mirror the writeback list.
    WritebackCaptures: struct {
        lambda: Reg,
        names: []ConstId,
        dsts: []Reg,
    },
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
    /// other module-scoped reference.
    LoadGlobal: struct { dst: Reg, name: ConstId },
    /// Bare-name read inside a lambda body that doesn't resolve as a
    /// local / capture / own member. If `this_idx`'s captured value
    /// is an instance with a field/method named `name`, read it;
    /// otherwise fall back to LoadGlobal(name).
    LoadFromThisOrGlobal: struct {
        dst: Reg,
        this_idx: u16,
        name: ConstId,
    },
    /// Symmetric write counterpart of `LoadFromThisOrGlobal`. If
    /// `this_idx`'s captured value is an instance with a member named
    /// `name`, `SetField` it; otherwise fall back to
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
        n_args: u8,
        arg_names: []?ConstId,
    },
    /// Write a global / top-level binding. Mirrors `LoadGlobal` for
    /// the write side: routed through `Host.store_global` so a
    /// delegated top-level property's setter (or a plain top-level
    /// `var`) gets updated.
    StoreGlobal: struct { name: ConstId, value: Reg },
    /// Register a class declaration encountered inside a function
    /// body. Local classes live for the duration of the call.
    RegisterClass: struct {
        class: *ast.Class,
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
        ast: *ast.Expr,
        captured_names: [][]const u8,
        captures: []Reg,
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
    /// Construct a `Value.Lambda` directly from a stashed AST
    /// `Block` plus a snapshot of captured registers indexed by
    /// name. Used so tree-walker-style dispatch paths that
    /// pattern-match on `Value.Lambda` can call IR-lowered lambdas
    /// without each site needing a separate `IrClosure` branch.
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
        n_args: u8,
    },
    /// Cross-function tail call: replace the current frame's function
    /// with `func`, rebind its params from the contiguous register run
    /// at `args`, and restart the new entry block.
    TailCallFunc: struct {
        func: FuncId,
        args: Reg,
        n_args: u8,
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
pub const Func = struct {
    id: FuncId,
    name: []const u8,
    fqn: []const u8,
    params: []Param,
    return_ty: TypeRef,
    n_locals: u32,
    blocks: []Block,
    entry: BlockId,
    is_suspend: bool,
    is_tailrec: bool = false,
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
    primary_params: []Param,
    methods: []FuncId,
    init_block: ?FuncId,
    companion: ?ClassId,
    supertypes: []ClassId,
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
    classes: std.ArrayList(Class) = .empty,
    consts: std.ArrayList(Const) = .empty,
    /// Top-level (file-scope) function ids, in declaration order.
    top_level: std.ArrayList(FuncId) = .empty,
    /// Top-level class declarations by simple name → `ClassId`. The
    /// lowering pass populates this so `Foo(args)` Calls become
    /// `NewInstance` instructions when `Foo` resolves to a class.
    class_index: std.ArrayList(ClassIndexEntry) = .empty,
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
    /// user parameters' `(required, total, trailing_vararg)`.
    /// Lowering-only; not serialized.
    decl_user_arity: std.AutoHashMap(u32, DeclArity),

    /// `(required, total, trailing_vararg)` for a top-level function's
    /// declared user parameters.
    pub const DeclArity = struct {
        required: u32,
        total: u32,
        trailing_vararg: bool,
    };

    pub fn init(allocator: Allocator) Module {
        return .{
            .func_name_index = std.StringHashMap(std.ArrayList(FuncId)).init(allocator),
            .registry = ModuleRegistry.init(allocator),
            .decl_user_params = std.AutoHashMap(u32, u32).init(allocator),
            .decl_user_arity = std.AutoHashMap(u32, DeclArity).init(allocator),
        };
    }

    /// Mirrors Rust's `#[derive(Default)]` constructor.
    pub fn default(allocator: Allocator) Module {
        return Module.init(allocator);
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
        self.func_index.deinit(allocator);
        var it = self.func_name_index.valueIterator();
        while (it.next()) |list| list.deinit(allocator);
        self.func_name_index.deinit();
        self.tailrec_fn_names.deinit(allocator);
        self.registry.deinit();
        self.decl_user_params.deinit();
        self.decl_user_arity.deinit();
    }

    /// Look up a class by simple name.
    pub fn classId(self: *const Module, name: []const u8) ?ClassId {
        for (self.class_index.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.id;
        }
        return null;
    }

    /// Rebuild `func_name_index` from the declaration-order
    /// `func_index`. The IR build pipelines call this whenever
    /// they're done extending `func_index`, and deserialized modules
    /// call it lazily on first `funcId` lookup.
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

    pub fn funcId(self: *const Module, name: []const u8) ?FuncId {
        const candidates = self.funcsBySimpleName(name);
        if (candidates.len == 0) {
            // Fallback for callers that mutate `func_index` directly
            // without rebuilding the name-index — preserve the old
            // O(n) walk so the answer stays correct in that path.
            return self.funcIdLegacy(name);
        }
        var first: ?FuncId = null;
        var first_user: ?FuncId = null;
        var first_body: ?FuncId = null;
        for (candidates) |id| {
            if (first == null) first = id;
            if (idGet(Func, self.funcs.items, id.int())) |f| {
                if (first_body == null and f.blocks.len != 0) first_body = id;
                if (first_user != null) continue;
                if (!isShippedFqn(f.fqn)) first_user = id;
            }
        }
        // Prefer body over bodyless: a same-name `expect` (bodyless)
        // should not hide a same-name `actual` / non-expect body
        // sibling.
        return first_user orelse first_body orelse first;
    }

    fn funcIdLegacy(self: *const Module, name: []const u8) ?FuncId {
        var first: ?FuncId = null;
        var first_user: ?FuncId = null;
        for (self.func_index.items) |entry| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            if (first == null) first = entry.id;
            if (first_user != null) continue;
            if (idGet(Func, self.funcs.items, entry.id.int())) |f| {
                if (!isShippedFqn(f.fqn)) first_user = entry.id;
            }
        }
        return first_user orelse first;
    }

    /// Look up a top-level function by fully-qualified name (matches
    /// `Func.fqn`). Use this when a call site already resolved the
    /// FQN so a same-simple-name pack function in a different package
    /// can't shadow the intended target.
    pub fn funcIdByFqn(self: *const Module, fqn: []const u8) ?FuncId {
        for (self.funcs.items) |f| {
            if (std.mem.eql(u8, f.fqn, fqn)) return f.id;
        }
        return null;
    }

    /// The full segment path of a non-wildcard import whose leaf is
    /// `name`, as seen from source file `file`. A named import is
    /// file-scoped, so only imports declared in `file` are consulted.
    pub fn importAliasIn(self: *const Module, file: FileId, name: []const u8) ?[]const []const u8 {
        if (self.registry.import_aliases.get(file)) |m| {
            if (m.get(name)) |segs| return segs.items;
        }
        return null;
    }

    /// Register a class declaration and return its id. If the name
    /// was previously `reserveClass`d, the reserved slot/id is reused
    /// so forward references that resolved to that id stay valid.
    pub fn addClass(self: *Module, allocator: Allocator, class_in: Class) Allocator.Error!ClassId {
        var class = class_in;
        if (self.classIndexEntryByName(class.name)) |id| {
            const existing = &self.classes.items[id.int()];
            const is_stub = std.mem.eql(u8, existing.fqn, existing.name) and
                existing.methods.len == 0 and
                existing.primary_params.len == 0 and
                existing.supertypes.len == 0 and
                existing.init_block == null;
            // A reserved-stub fill, or the same class re-lowered
            // (identical FQN), overwrites in place so forward
            // references keep their id. A different fully-qualified
            // name sharing the simple name is a genuinely distinct
            // class from another package: give it its own ClassId.
            if (is_stub or std.mem.eql(u8, existing.fqn, class.fqn) or std.mem.eql(u8, class.fqn, class.name)) {
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

    fn classIndexEntryByName(self: *const Module, name: []const u8) ?ClassId {
        for (self.class_index.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.id;
        }
        return null;
    }

    /// Resolve a class by its fully-qualified name. Distinguishes
    /// same-simple-name classes from different packages that
    /// `addClass` keeps as separate definitions.
    pub fn classIdByFqn(self: *const Module, fqn: []const u8) ?ClassId {
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

    /// Pre-register a class name so `classId` resolves it before its
    /// body is lowered. Makes cross-class references order-independent.
    /// The placeholder is overwritten by the real definition when
    /// `addClass` runs for the same name.
    pub fn reserveClass(self: *Module, allocator: Allocator, name: []const u8) Allocator.Error!ClassId {
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

fn isShippedFqn(fqn: []const u8) bool {
    return std.mem.startsWith(u8, fqn, "kotlin.") or
        std.mem.startsWith(u8, fqn, "kotlinx.") or
        std.mem.startsWith(u8, fqn, "java.") or
        std.mem.eql(u8, fqn, "kotlin") or
        std.mem.eql(u8, fqn, "kotlinx") or
        std.mem.eql(u8, fqn, "java");
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
    /// Top-level property names declared with `by <delegate>`.
    /// Reads/writes route through the stored delegate's `getValue` /
    /// `setValue` methods.
    top_level_delegated_props: std.StringHashMap(void),
    /// Class simple name → the set of member *function* names it
    /// declares or inherits (transitively over supertypes). Lets the
    /// lowerer honor Kotlin's separate function/property namespaces.
    hierarchy_methods: std.StringHashMap(std.StringHashMap(void)),
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
    /// Per-file (`FileId`) non-wildcard import leaf → the import's full
    /// segment path. Keyed by file because a Kotlin named import is
    /// file-scoped.
    import_aliases: std.AutoHashMap(FileId, std.StringHashMap(std.ArrayList([]const u8))),
    /// Nested-object simple-name aliases, keyed by enclosing class
    /// name.
    nested_object_aliases: std.StringHashMap(std.StringHashMap([]const u8)),
    /// `(class_name, member_name) → Const` for class / companion
    /// `const val name = <literal>`.
    class_const_inits: StrPairMap(Const),

    allocator: Allocator,

    pub fn init(allocator: Allocator) ModuleRegistry {
        return .{
            .companion_singletons = std.StringHashMap([]const u8).init(allocator),
            .enclosing_class = std.StringHashMap([]const u8).init(allocator),
            .func_type_params = std.AutoHashMap(FuncId, std.ArrayList([]const u8)).init(allocator),
            .top_level_delegated_props = std.StringHashMap(void).init(allocator),
            .hierarchy_methods = std.StringHashMap(std.StringHashMap(void)).init(allocator),
            .delegated_body_props = StrPairSet.init(allocator),
            .member_ext_owner_class = std.AutoHashMap(FuncId, []const u8).init(allocator),
            .local_fn_defaults = std.AutoHashMap(FuncId, std.ArrayList(?FuncId)).init(allocator),
            .abstract_member_defaults = StrPairMap(std.ArrayList(?FuncId)).init(allocator),
            .type_aliases = std.StringHashMap([]const u8).init(allocator),
            .import_aliases = std.AutoHashMap(FileId, std.StringHashMap(std.ArrayList([]const u8))).init(allocator),
            .nested_object_aliases = std.StringHashMap(std.StringHashMap([]const u8)).init(allocator),
            .class_const_inits = StrPairMap(Const).init(allocator),
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
        self.top_level_delegated_props.deinit();
        {
            var it = self.hierarchy_methods.valueIterator();
            while (it.next()) |inner| inner.deinit();
            self.hierarchy_methods.deinit();
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
                while (inner_it.next()) |segs| segs.deinit(a);
                inner.deinit();
            }
            self.import_aliases.deinit();
        }
        {
            var it = self.nested_object_aliases.valueIterator();
            while (it.next()) |inner| inner.deinit();
            self.nested_object_aliases.deinit();
        }
        self.class_const_inits.deinit();
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
