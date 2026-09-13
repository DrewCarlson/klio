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
    Const: struct { dst: Reg, value: ConstId },
    /// Suspend-resume marker: `state` picks the resume block from the entry dispatch table.
    SuspendResumePoint: struct { state: u32 },
    LoadParam: struct { dst: Reg, idx: u16 },
    LoadCapture: struct { dst: Reg, idx: u16 },
    Move: struct { dst: Reg, src: Reg },
    /// Box `src` into a capture cell for a `var` a nested lambda captures (Kotlin `Ref`).
    MakeCell: struct { dst: Reg, src: Reg },
    CellGet: struct { dst: Reg, cell: Reg },
    /// Store through the capture cell in `cell`, keeping the shared cell so every holder sees it.
    CellSet: struct { cell: Reg, value: Reg },
    GetField: struct {
        dst: Reg,
        receiver: Reg,
        field: ConstId,
        /// Site memo, single-fill: the first resolving class claims it (CAS from 0) and only
        /// the winner writes `site_route`, so the pair cannot tear. A stale value stays slow.
        site_cls: u64 = 0,
        site_route: u64 = 0,
        /// The claiming receiver's layout identity (`InstanceData.shapeOf`) stored with the
        /// route: matching class AND shape proves the index. Shape alone is not a claim key.
        site_shape: u64 = 0,
        /// Serving a null stored slot: 0 = unasked, 1 = an unset-`lateinit` shape the ladder
        /// must adjudicate, 2 = a plain null this site may serve.
        null_ok: u8 = 0,
    },
    SetField: struct {
        receiver: Reg,
        field: ConstId,
        value: Reg,
        /// `super.prop = v`: the class whose body wrote it. The setter search starts at its
        /// supertypes, so an overriding setter reaches the base accessor instead of recursing.
        super_owner: ?ConstId = null,
    },
    /// `recv.field <op>= value`. A field value carrying the in-place operator (the
    /// `plusAssign` family) is dispatched with NO write-back, since Kotlin mutates in
    /// place; otherwise this is read-modify-write.
    CompoundField: struct {
        receiver: Reg,
        field: ConstId,
        op: BinOp,
        value: Reg,
    },
    Index: struct { dst: Reg, receiver: Reg, index: Reg },
    IndexSet: struct {
        receiver: Reg,
        index: Reg,
        value: Reg,
    },
    /// Static call by id; args are a run of registers from `args`. `arg_names` holds one
    /// optional `ConstId` per slot, and is empty when every argument is positional.
    Call: struct {
        dst: Reg,
        func: FuncId,
        args: Reg,
        n_args: u32,
        arg_names: []?ConstId = &.{},
        /// Call-site type arguments in declaration order, each an interned type name.
        /// Consumed by reified dispatch when the callee is an `inline fun <reified T>`.
        type_args: []ConstId = &.{},
        /// The overload was selected at lower time from an explicit cast (`f(x as T)`), so
        /// runtime re-resolution must not override it by the argument's runtime type.
        exact: bool = false,
        /// Site verdict for a callee whose plan carries `FAST_CALL_AMBIG_FLAG`: 0 = unasked,
        /// 1 = the fusion must not take this call, 2 = the baked target is right here.
        fuse_site: u8 = 0,
        /// The final argument came as a trailing lambda, which Kotlin binds to the LAST
        /// parameter; a positional lambda binds its own slot. Under-application binds by syntax.
        trailing_lambda: bool = false,
    },
    /// `receiver.lambda(args)`: invoke a callable with `receiver` bound as `this`.
    CallValueWithThis: struct {
        dst: Reg,
        callee: Reg,
        receiver: Reg,
        args: Reg,
        n_args: u32,
        arg_names: []?ConstId = &.{},
        /// Lowering proved the callee's declared type is a receiver function, so the VM may
        /// adapt a plain underlying function positionally instead of inferring a receiver.
        receiver_shape_exact: bool = false,
        /// Declared receiver head of a receiver-lambda parameter invoked bare. Kotlin binds
        /// the innermost implicit receiver OF THAT TYPE; null keeps the passed receiver.
        recv_head: ?ConstId = null,
    },
    CallValue: struct {
        dst: Reg,
        callee: Reg,
        args: Reg,
        n_args: u32,
        arg_names: []?ConstId = &.{},
        /// Call-site type argument heads, recorded for the bare-call-to-global form so an
        /// intrinsic container creator (`emptyList<String>()`) can stamp its element type.
        type_args: []ConstId = &.{},
    },
    /// Call a callable value with mixed positional and spread args; each spread part's
    /// array or list items are flattened into positional args at evaluation time.
    CallSpread: struct {
        dst: Reg,
        callee: Reg,
        parts: []SpreadPart,
        arg_names: []?ConstId = &.{},
        /// Statically resolved member slot. When present, `callee` is the receiver and
        /// `arg_params` maps each source part to its parameter before spread expansion.
        virtual_slot: ?MethodSlotId = null,
        arg_params: ?[]u32 = null,
        trailing_lambda: bool = false,
        /// When set, the flattened args go to method `member` on the receiver in `callee`
        /// rather than invoking `callee`, so `recv.method(*array)` dispatches as a member.
        member: ?ConstId = null,
        /// Bare top-level name whose overload set lowering bounded by call-site scope.
        /// `candidates` is authoritative when non-null, empty slice included.
        name: ?ConstId = null,
        candidates: ?[]const FuncId = null,
        /// Declaring package of the lowering-selected candidate set. A synthesized lambda
        /// frame has no package of its own; this keeps applicability in the resolved scope.
        anchor_pkg: ?ConstId = null,
    },
    /// `super.method(args)`: resolved against the parent of `owner_class`, not the leaf
    /// class. A non-null `qualifier` is `super<Qual>.method()`, dispatched on `Qual`.
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
    /// `name(args)` where `name` is both an in-scope value and a member of the enclosing
    /// class: invoke `callee` if invocable, else dispatch `name` on `this_recv`.
    CallValueOrMember: struct {
        dst: Reg,
        callee: Reg,
        this_recv: Reg,
        name: ConstId,
        args: Reg,
        n_args: u32,
        arg_names: []?ConstId = &.{},
    },
    /// `recv.name(args)` where `name` is also a callable local: dispatch the member when
    /// `recv` has one, otherwise invoke `fallback`.
    CallMemberOrValue: struct {
        dst: Reg,
        receiver: Reg,
        name: ConstId,
        fallback: Reg,
        args: Reg,
        n_args: u32,
        arg_names: []?ConstId = &.{},
        /// The receiver's static type is an unbounded type parameter, so it declares no
        /// members: Kotlin binds `receiver.block()` to the in-scope callable, never a member.
        recv_erased: bool = false,
        /// The fallback is receiver-typed, so the call receiver binds its extension receiver.
        fallback_takes_receiver: bool = false,
        /// Lowering proved the fallback's shape; false keeps the compatibility path.
        fallback_receiver_shape_known: bool = false,
    },
    CallMember: struct {
        dst: Reg,
        receiver: Reg,
        name: ConstId,
        args: Reg,
        n_args: u32,
        arg_names: []?ConstId = &.{},
        /// Trailing-lambda syntax bit; see `Inst.Call.trailing_lambda`.
        trailing_lambda: bool = false,
        /// The receiver's declared type head when lowering knows it. Kotlin resolves
        /// extension calls against the static type, not a subtype's same-name extension.
        static_recv: ?ConstId = null,
        /// The receiver expression's declared type head, used only by the extension-selection
        /// filter; `static_recv`, the extension-BODY receiver, drives the member walk instead.
        declared_recv: ?ConstId = null,
        /// A lowering-resolved, provably monomorphic target: called directly, skipping all
        /// name-based resolution. Set only where the target cannot vary; null stays virtual.
        resolved: ?FuncId = null,
        /// Site memo, single-fill (see `GetField.site_cls`): the first Instance class whose
        /// by-name dispatch flat-resolved claims it, `site_sig` the argument signature it was
        /// keyed under, `site_route` the packed target (`FuncId << 1 | 1`, never 0 if filled).
        site_cls: u64 = 0,
        site_sig: u64 = 0,
        site_route: u64 = 0,
        /// Dispatch receiver for a resolved member-extension target, picked by the implicit
        /// receiver tower; the extension receiver stays in `receiver`. Null for plain members.
        dispatch_receiver: ?Reg = null,
    },
    /// Virtual member call whose overload was resolved statically; `slot` names the selected
    /// override family. Runtime work is one `(ClassId, slot) -> FuncId` lookup, which a
    /// host-backed receiver lacks, so it walks by member name.
    CallVirtual: struct {
        dst: Reg,
        receiver: Reg,
        slot: MethodSlotId,
        args: Reg,
        n_args: u32,
        /// Declaration parameter index filled by each source-order argument (receiver
        /// excluded). Null selects positional binding; a non-null empty map is an indexed
        /// zero-argument call such as an empty vararg. Resolved against the slot root.
        arg_params: ?[]u32 = null,
        arg_names: []?ConstId = &.{},
        trailing_lambda: bool = false,
        /// Site memo, single-fill (see `GetField.site_cls`), for a host-backed receiver:
        /// `site_cls` interns the receiver type FQN pointer (CAS from 0), `site_name_*` the
        /// member name, `site_native` the native form, stored LAST with release as the gate.
        site_cls: u64 = 0,
        site_native: u64 = 0,
        site_name_ptr: u64 = 0,
        site_name_len: u32 = 0,
    },
    NewInstance: struct {
        dst: Reg,
        class: ClassId,
        args: Reg,
        n_args: u32,
        arg_names: []?ConstId = &.{},
        /// Declared type head of each argument where lowering knows one. Kotlin picks a
        /// constructor overload from static types, which an interpreted value cannot supply.
        arg_static_heads: []?ConstId = &.{},
    },
    NewList: struct { dst: Reg, args: Reg, n_args: u32 },
    /// `this@Qualifier`: walk the receiver's outer chain for an instance of `qualifier`.
    QualifiedThis: struct {
        dst: Reg,
        receiver: Reg,
        qualifier: ConstId,
        /// A miss writes Null instead of raising: a local class snapshots the enclosing member
        /// extension's dispatch receiver, and a body that never reads it must not fail.
        soft: bool = false,
    },
    /// `::name`: a `KProperty`-shaped reference value carrying the property name.
    PropertyRef: struct { dst: Reg, name: ConstId },
    /// `Receiver::name`: bind a callable reference to the receiver value.
    MemberRef: struct {
        dst: Reg,
        receiver: Reg,
        name: ConstId,
        /// Exact top-level extension selected at lowering; null dispatches by name.
        func: ?FuncId = null,
        /// Expected value-parameter count at the reference site, -1 when unknown. The
        /// runtime stamps the reference adapted when the shape differs from the target's.
        adapt_arity: i16 = -1,
        adapt_unit: bool = false,
        /// Expected parameter type heads joined by `|`; null when unknown. A vararg slot
        /// expecting an array is not an adaptation.
        adapt_heads: ?ConstId = null,
    },
    /// Binary primitive operation; typeck guarantees the operand types.
    BinOp: struct {
        dst: Reg,
        op: BinOp,
        lhs: Reg,
        rhs: Reg,
        /// The combine step of a compound assignment. For a mutable collection left operand
        /// the evaluator dispatches the in-place `<op>Assign`, keeping the receiver mutable.
        compound: bool = false,
    },
    UnOp: struct { dst: Reg, op: UnOp, operand: Reg },
    Not: struct { dst: Reg, src: Reg },
    /// `as T` / `as? T`; the type resolves by name, and CFA smart casts can elide the check.
    Cast: struct {
        dst: Reg,
        src: Reg,
        ty: TypeRef,
        safe: bool,
    },
    InstanceOf: struct { dst: Reg, src: Reg, ty: TypeRef },
    /// Resolve the nearest in-scope context value whose runtime type is a subtype of `ty`;
    /// `erased` takes the innermost value regardless. Writes `.Null` when none is in scope.
    CtxLoad: struct { dst: Reg, ty: ConstId, erased: bool = false },
    /// The stdlib `context(v..., block)`: push the `n_ctx` values at `ctx_args`, invoke
    /// `block` with no value args, then pop. They serve context resolution, not receivers.
    CtxScope: struct { dst: Reg, ctx_args: Reg, n_ctx: u32, block: Reg },
    /// Fully-positional invocation of a contextual function-type value: the leading `n_ctx`
    /// args push as contexts, `callee` runs with the rest, then they pop. `args` is one
    /// contiguous run so the register visitor keeps every operand live.
    CtxCall: struct {
        dst: Reg,
        callee: Reg,
        args: Reg,
        n_args: u32,
        n_ctx: u32,
        arg_names: []?ConstId = &.{},
    },
    NotNullAssert: struct { dst: Reg, src: Reg },
    /// Read of a local `lateinit var`: `src` still holding the declaration's `Null` means
    /// unassigned, which throws `kotlin.UninitializedPropertyAccessException` naming `name`.
    LateinitCheck: struct { dst: Reg, src: Reg, name: ConstId },
    Trace: struct { span: Span },
    /// Push `src` onto the frame's enclosing-receiver chain as a `with`-subject for a spliced
    /// receiver-lambda region (`EnclosingPop` ends it). Frame-owned, so a skipped pop heals.
    /// so a non-local exit that skips the pop is healed at frame teardown.
    EnclosingPush: struct { src: Reg },
    EnclosingPop: struct {},
    /// Resolve a bare global identifier through the Host. `func`/`class` carry an exact identity
    /// when the index found one; `ctor_ref` makes `::C` the CONSTRUCTOR, not a companion.
    /// index found one. `ctor_ref`: `::C` denotes the CONSTRUCTOR, not a published companion.
    LoadGlobal: struct { dst: Reg, name: ConstId, func: ?FuncId = null, class: ?ClassId = null, ctor_ref: bool = false },
    /// Bare-name read in a receiver context that is no local, capture, or own member: the
    /// runtime searches the implicit receivers innermost first, then the global.
    /// enclosing-`this` chain, each dispatch receiver's nesting tower) innermost first.
    LoadFromThisOrGlobal: struct {
        dst: Reg,
        this_idx: u16,
        name: ConstId,
        func: ?FuncId = null,
        class: ?ClassId = null,
        /// Site memo for the implicit-receiver walk: a packed {shape-hash, winner-index,
        /// verdict} word filled in place under the same benign-race convention as
        /// `Func.fast_call`. The hash folds class identity and field count, so stale re-fills.
        site_cache: u64 = 0,
    },
    /// Write counterpart of `LoadFromThisOrGlobal`: the innermost implicit receiver with
    /// a member named `name` takes the write, else it falls back to `StoreGlobal(name)`.
    StoreToThisOrGlobal: struct {
        this_idx: u16,
        name: ConstId,
        value: Reg,
        /// Statically known innermost implicit receiver when lowering holds it in a register. An
        /// inline extension's spliced body binds its receiver as an ordinary register of the
        /// CALLER's frame, so `this_idx` names an unpopulated slot. Tried first, still checked.
        recv: ?Reg = null,
    },
    /// Bare-name call inside a lambda body that may run with a this-receiver: dispatch as
    /// a member when the captured `this` has one, else fall back to a top-level lookup.
    CallMemberOrGlobal: struct {
        dst: Reg,
        this_idx: u16,
        name: ConstId,
        args: Reg,
        n_args: u32,
        arg_names: []?ConstId,
        /// Trailing-lambda syntax bit; see `Inst.CallMember.trailing_lambda`.
        trailing_lambda: bool = false,
        /// Scope-resolved class when the bare name is a constructor call; the global leg
        /// constructs exactly this class.
        class: ?ClassId = null,
        /// Lowering-resolved top-level function for a bare call a runtime receiver member
        /// can shadow; the global leg calls exactly this declaration.
        func: ?FuncId = null,
        /// Call-site evidence committed `func` among a return-variant family: the global leg must
        /// not value-re-rank past it, a closure argument carrying no return type. The member
        /// leg still runs first.
        func_final: bool = false,
        /// Package/import-scoped callable set from the lowering resolver. Null is the host-symbol
        /// boundary, where the runtime may consult the name index; a non-null slice is
        /// authoritative, empty included.
        candidates: ?[]const FuncId = null,
        /// An inline-splice's bound receiver, in a local register rather than the frame's
        /// `this` slot. When set it is the innermost implicit-receiver candidate.
        recv: ?Reg = null,
        /// The enclosing extension's declared receiver head, so the walk resolves same-name
        /// extensions against the STATIC type even inside a synthesized closure frame.
        static_recv: ?ConstId = null,
        /// Explicit call-site type arguments, preserved through the deferred form so the
        /// global leg can type its dispatch (unsigned literal coercion, reified serving).
        type_args: []ConstId = &.{},
        /// Site memo for the member-probe skip: the receiver class and argument signature for
        /// which a previous execution found no member or extension and took the global leg.
        skip_cls: u64 = 0,
        skip_sig: u64 = 0,
        /// The global-leg target a previous execution resolved for `skip_cls`/`skip_sig`,
        /// stored as `FuncId + 1` (0 = unclaimed). Claimed only for a plain positional call
        /// the overload terminal answered with a fused activation, so a replay is exact.
        global_fid: u32 = 0,
    },
    /// Write a top-level binding, routed through `Host.store_global` so a delegated
    /// top-level property's setter (or a plain top-level `var`) is updated.
    StoreGlobal: struct { name: ConstId, value: Reg },
    /// Register a class declared inside a function body; it lives for the call's duration.
    RegisterClass: struct {
        class: FF(ast.Class),
        /// Capture-name slots so the class methods see the enclosing function's locals.
        captured_names: [][]const u8,
        captures: []Reg,
        /// Receives the registered class as a `.Class` value, so a later `C(args)` constructs
        /// the local class rather than a same-named top-level function, as Kotlin requires.
        dst: ?Reg = null,
    },
    /// Build an anonymous-object instance from an `object { … }` AST node: synthesise a
    /// `ClassDef`, fill its env from `captures`, run its init pipeline, return the instance.
    BuildObject: struct {
        dst: Reg,
        ast: FF(ast.Expr),
        captured_names: [][]const u8,
        captures: []Reg,
        /// Scope-true type renames visible at the object expression's lexical site. Member bodies
        /// lower at runtime into a fresh side module with none of the build's scope registries,
        /// so the renames must ride on the instruction.
        scope_renames: []const ScopeRename = &.{},
        /// Exact classifier identities referenced by the object subtree.
        scope_classes: []const ScopeClassRef = &.{},
    },
    /// Materialise a lambda value: `captures` lists the registers the evaluator snapshots
    /// into a closure env, and `body_func` is the body lowered as a separate Func.
    Lambda: struct {
        dst: Reg,
        body_func: FuncId,
        captures: []Reg,
    },
    /// Materialise a closure from a stashed AST `Block` plus captured registers indexed
    /// by name; the VM builds an `IrClosure` over `body_func` and the captured values.
    AstLambda: struct {
        dst: Reg,
        params: [][]const u8,
        body_ast: ast.Block,
        captures: []Reg,
        captured_names: [][]const u8,
        /// True for an anonymous function expression, whose `return` exits the function
        /// itself; false for a lambda, where the enclosing function is the return target.
        absorb_return: bool = false,
        /// `FuncId` of the IR-lowered body, emitted alongside the AST snapshot so call
        /// sites can dispatch without the tree walker. Null when only the AST form exists.
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
    /// Equality on a value that came through `as Any` or a statically-Any-typed path.
    /// `Double` and `Float` compare bitwise, so NaN == NaN and +0.0 != -0.0.
    BoxedEq,
    BoxedNotEq,
    /// `===` / `!==`: compares heap values by backing-cell pointer, never dispatching `equals`.
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

/// Visit every register operand of one instruction, generically over the `Inst` union:
/// `Reg`, `?Reg`, `[]Reg`, `SpreadPart` slices, and the `args`+`n_args` contiguous-run
/// convention. A field named `dst` reports `is_def = true`. Comptime-generated, so a new
/// variant is covered by construction.
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
                    // `CtxScope` pairs its context-value run with `n_ctx`, while `CtxCall`'s single
                    // `args` run already spans its context prefix.
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

/// Rewrite an instruction's `dst` register; false when the variant carries none.
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
    /// Tail-recursive jump to the function's entry: rebind the param regs from this
    /// contiguous register run and restart execution without pushing a call frame.
    TailJump: struct {
        args: Reg,
        n_args: u32,
    },
    /// Cross-function tail call: replace the frame's function with `func`, rebind its
    /// params from the register run at `args`, and restart at the new entry block.
    TailCallFunc: struct {
        func: FuncId,
        args: Reg,
        n_args: u32,
    },
    /// Propagates `EvalError.NonLocalReturn` up through enclosing lambda frames until a
    /// non-lambda function catches it and converts it into a normal return value.
    NonLocalReturn: ?Reg,
    /// `return@label`: propagates as `EvalError.LabeledReturn` through enclosing frames
    /// until the frame whose name matches `label` catches it.
    LabeledReturn: struct { label: []const u8, value: ?Reg },
};

/// One `Terminator.Switch` arm: a constant key and the block to jump to on a match.
pub const SwitchArm = struct {
    key: ConstId,
    target: BlockId,
};

/// Catch handler on a try-body block: on a Throw the evaluator pops handlers in stack
/// order and jumps to the first whose `type_name` matches; `exception_reg` gets the value.
pub const CatchHandler = struct {
    type_name: []const u8,
    handler: BlockId,
    exception_reg: Reg,
};

/// Absorption point for a labeled return targeting an inline function spliced into the
/// enclosing one: a `return@name` crossing a real frame unwinds as a `LabeledReturn`,
/// and the splice's frame catches it and resumes at `handler` with `value_reg`.
pub const LrAbsorb = struct {
    label: []const u8,
    handler: BlockId,
    value_reg: Reg,
};
