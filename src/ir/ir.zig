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
pub fn runtimeEnvSetOnce(comptime n: [:0]const u8) bool { return runtime.envSetOnce(n); }
const applicability = @import("applicability");
const types_mod = @import("types");
const FF = runtime.forest.ForestField;

const Allocator = std.mem.Allocator;

pub const Span = span.Span;
pub const FileId = span.FileId;

/// AST → IR lowering, IR builders, and the IR evaluator. Filled in
/// alongside the type definitions in this file.
pub const build = @import("build.zig");
pub const eval = @import("eval.zig");
pub const bc = @import("bc.zig");
pub const lower = @import("lower.zig");
pub const hot_layout = @import("hot_layout.zig");
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
        var initialized: usize = 0;
        errdefer {
            for (args[0..initialized]) |*arg| arg.deinit(allocator);
            allocator.free(args);
        }
        for (self.args, args) |src, *dst| {
            dst.* = try src.clone(allocator);
            initialized += 1;
        }
        const name = try allocator.dupe(u8, self.name);
        return .{
            .name = name,
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

/// One implicit-receiver tower entry: the receiver's type head, plus the
/// label under which its VALUE is addressable from nested scopes
/// (`this@<label>` — the extension fn or receiver lambda name), when one
/// is bound. A null label still serves resolution/derivation; only static
/// EMISSION with an outer receiver needs the value channel.
/// One contextual function-type parameter shape carried into a lambda body.
pub const PendingCtxFnShape = struct {
    name: []const u8,
    ctx_types: []const []const u8,
    n_regular: usize,
};

pub const ReceiverTowerEntry = struct {
    head: []const u8,
    label: ?[]const u8 = null,
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
/// Handles into a `CallVirtual` instruction's host-receiver site memo
/// (see the field docs there). Built by the exec arm from the live
/// instruction and threaded into the host's virtual dispatch so the
/// resolution can stamp the site; null when the call carries argument
/// names or a parameter map (the memoized direct dispatch binds
/// positionally).
pub const VirtNativeSite = struct {
    cls: *u64,
    native: *u64,
    name_ptr: *u64,
    name_len: *u32,
};

/// One reified type-parameter substitution: the parameter's name and the
/// rendered actual type it stands for.
pub const ReifiedName = struct { name: []const u8, actual: []const u8 };

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

pub fn classTypeParamIdentity(
    allocator: Allocator,
    owner: ClassId,
    param: []const u8,
) Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "$class$\x00{d}\x00{d}:{s}",
        .{ owner.int(), param.len, param },
    );
}

pub const ClassTypeParamIdentity = struct {
    owner: ClassId,
    param: []const u8,
};

pub fn parseClassTypeParamIdentity(raw_name: []const u8) ?ClassTypeParamIdentity {
    var name = raw_name;
    if (std.mem.startsWith(u8, name, "out#")) {
        name = name["out#".len..];
    } else if (std.mem.startsWith(u8, name, "in#")) {
        name = name["in#".len..];
    }
    const prefix = "$class$\x00";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    const owner_end = std.mem.indexOfScalar(u8, name[prefix.len..], 0) orelse return null;
    const owner_text = name[prefix.len .. prefix.len + owner_end];
    const owner_int = std.fmt.parseInt(u32, owner_text, 10) catch return null;
    const length_start = prefix.len + owner_end + 1;
    const colon = std.mem.indexOfScalar(u8, name[length_start..], ':') orelse return null;
    const length_text = name[length_start .. length_start + colon];
    const param_len = std.fmt.parseInt(usize, length_text, 10) catch return null;
    const param = name[length_start + colon + 1 ..];
    if (param.len != param_len) return null;
    return .{ .owner = ClassId.from(owner_int), .param = param };
}

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
pub const snapshot_fast = @import("snapshot_fast.zig");

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
    /// Entering this block arms a labeled-return absorption region for a
    /// splice of the named inline function (see `LrAbsorb`).
    lr_absorb: ?LrAbsorb = null,
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

/// `Func.fast_call` flag: the eligible body carries its receiver as the
/// leading `"this"` param, so the fast dispatch seeds the caller's instance
/// `this` as an enclosing receiver exactly as the full path does.
pub const FAST_CALL_EXT_FLAG: u16 = 0x4000;

/// `Func.fast_call` flag: the callee's simple name has same-arity peers, so
/// only the CALL SITE can say whether the baked target is the one scope
/// resolution picks. Eligible in every other respect; the site resolves the
/// question once and caches the verdict on its own instruction.
pub const FAST_CALL_AMBIG_FLAG: u16 = 0x2000;

/// Whether the declaration currently LOWERING carries
/// `@Suppress("DEPRECATION_ERROR")`: under it kotlinc restores
/// `@Deprecated(level = ERROR)` candidates to ordinary overload ranking,
/// so the resolvers consult this when filtering low-priority overloads.
threadlocal var suppress_deprecation_error: bool = false;

pub fn setSuppressDeprecationError(v: bool) bool {
    const prev = suppress_deprecation_error;
    suppress_deprecation_error = v;
    return prev;
}

/// The effective low-priority rank of a candidate at the current site: a
/// deprecation-ERROR overload ranks ordinary under the suppression.
pub fn rankLowPriority(f: *const Func) bool {
    return f.low_priority and !(f.deprecated_error and suppress_deprecation_error);
}

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
    /// Whether `return_ty` came from an explicit `: T` in the source. A
    /// function with an expression body and no annotation gets `Unit` as a
    /// PLACEHOLDER, so `return_ty` alone cannot distinguish "returns Unit"
    /// from "return type not recorded". Any consumer that treats the return
    /// type as a fact about the function must check this first.
    return_ty_declared: bool = false,
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
    /// full dispatch), otherwise the low 14 bits are the eligible parameter
    /// count + 2: a user function a positional, exact-arity call dispatches
    /// straight to its body. `FAST_CALL_EXT_FLAG` marks a receiver-carrying
    /// body (baked extension / member) whose dispatch must seed the caller's
    /// `this` as an enclosing receiver. See `eval`'s `.Call` fast path.
    fast_call: u16 = 0,
    /// Which argument-coercion walks can ever apply to this func's declared
    /// params, computed on first frame entry: bit0 = computed, bit1 = a
    /// non-vararg `Long` param exists (Int->Long widening), bit2 = >=2 params
    /// with a type-variable-typed one (generic Int/Long peer widening).
    /// Filled in place under the same benign-race convention as `fast_call`.
    coerce_plan: u8 = 0,
    /// VM-plan P2 classification: 0 unknown, 1 flattenable (every
    /// instruction in the simple subset, no catches/finally), 2 not.
    /// Filled lazily under the same benign-race convention as
    /// `coerce_plan`.
    flat_class: u8 = 0,
    /// Index of `"this"` in `capture_order`, cached on first use by
    /// `callerThisValue` (hot: every GetField in a lambda frame consults
    /// it). `-2` = not yet computed, `-1` = no `this` capture.
    this_cap_idx: i32 = -2,
    /// Accessor-shape memo (benign-race fill): 0 = unknown, 1 = not an
    /// accessor, 2 = the body is exactly `LoadParam #0; GetField; return`
    /// with `acc_field` holding the GetField name ConstId. See
    /// `accessorFieldConst`.
    acc_state: u8 = 0,
    acc_field: u32 = 0,
    /// Single-fill (CAS from 0) claimed receiver-class identity and its
    /// packed stored-slot route for the frameless accessor read; only the
    /// CAS winner writes `acc_route`, so the pair never tears. A stale
    /// baked value mismatches every live identity harmlessly.
    acc_cls: u64 = 0,
    acc_route: u64 = 0,
    /// Cached `leafExprBody` verdict: 0 = unasked, 1 = no, 2 = yes.
    leaf_state: u8 = 0,
    /// Fused-tier verdict, memoized like `leaf_state`: 0 = unasked, 1 =
    /// eligible (this body and, transitively, every statically-resolved
    /// callee), 2 = ineligible, 3 = classification in progress (a cycle
    /// reads as eligible for the frame asking and settles when the root
    /// classification completes).
    fuse_state: u8 = 0,
    /// Trivial property-initializer memo (benign-race fill): 0 = unasked,
    /// 1 = not trivial, 2 = the body returns one constant
    /// (`triv_init_val` = ConstId), 3 = it echoes one parameter
    /// (`triv_init_val` = param index). Construction serves 2/3 without a
    /// framed eval — a builder-heavy write path otherwise pays one full
    /// eval per `= 0`-style field.
    triv_init_state: u8 = 0,
    triv_init_val: u32 = 0,
    /// Host-served static routing memo (snapshot_fast): 0 = unasked,
    /// then a `snapshot_fast.Route` value.
    host_route: u8 = 0,
    /// Compose fast-path verdict for this body (`compose_fast.Route`),
    /// classified once on first execution like `host_route`.
    compose_route: u8 = 0,
    /// Throw-capable host-serve route (`hostRouteServeThrowing`): 0 unasked,
    /// 1 none, 2 the gap-buffer changelist wrapper, 3 the link-buffer one.
    throw_route: u8 = 0,
    /// Cached `frameNoFill` verdict: 0 = unasked, 1 = must fill,
    /// 2 = register file may start unfilled.
    frame_fill_state: u8 = 0,
    /// Scalar-replay (`kl_`) route memo: 0 unresolved, 1 none, else the
    /// registered NativeLeafFn as an address. The table is write-once
    /// before the program runs, so the first resolution is final;
    /// benign-race fill.
    leaf_route: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// Leaf bail damper: bit 31 = the leaf SERVED at least once (sticky —
    /// a genre-mixed fn must never be disabled); low bits count bails
    /// while never-served. A leaf that only ever bails is structural for
    /// this program's call shapes, and every attempt still pays marshal +
    /// a partial body — past the threshold the route flips to `none`.
    leaf_bail_probe: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// The bytecode-stream table for this func (`bc.funcStreams` memo):
    /// 0 unresolved, 1 none, else a `*const bc.FuncStreams` address.
    /// `bc_memo_fuse` records which allow_fuse variant the memo holds
    /// (1 = false, 2 = true); a caller wanting the other variant takes
    /// the shared-cache path. Benign-race fill.
    bc_memo: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    bc_memo_fuse: u8 = 0,
    /// Function-JIT hotness probe, shared across threads so the per-activation
    /// cost is one atomic load instead of a per-thread state-map lookup: low
    /// bits count activations, bit 30 = some thread compiled a body (consult
    /// the per-thread state), bit 31 = compilation declined (sticky; stop
    /// probing). See `jit_loop` for the encoding.
    func_jit_probe: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// `bc.streamGen()` at fill time; a cache reset frees the streams the
    /// memo points at, so a stale generation must fall to the shared path.
    bc_memo_gen: u32 = 0,
    /// The frameless leaf serve hit a STRUCTURALLY unsupported
    /// instruction in this body: every future serve would abandon at the
    /// same instruction, so the attempt (which may execute half the body
    /// before abandoning, doubling the call's work) is skipped outright.
    /// Value-dependent abandons never set this. Benign-race fill.
    leaf_hopeless: u8 = 0,
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
    /// True when lowering had a declared function-type shape for this
    /// closure. When false, `lambda_has_receiver == false` means unknown
    /// rather than a proven receiver-less function.
    lambda_receiver_shape_known: bool = false,
    /// True when this callable's function type declares an extension
    /// receiver. The receiver is supplied at invocation and is not counted
    /// in `params`; keeping that shape explicitly prevents the VM from
    /// inferring receiver binding from an extra argument or a `this` capture.
    lambda_has_receiver: bool = false,
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
    /// The low-priority mark came from `@Deprecated(level = ERROR|HIDDEN)`
    /// (not `@LowPriorityInOverloadResolution`): a caller-side
    /// `@Suppress("DEPRECATION_ERROR")` restores such a candidate to
    /// ordinary ranking, exactly as kotlinc resolves under the suppression.
    deprecated_error: bool = false,
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
    /// class is `open`. Serialized with the function header.
    is_open: bool = false,
    /// Carries the source `final` modifier. Meaningful on an `override` member:
    /// `final override fun` seals the method against any further override, so it
    /// is monomorphic despite `is_override`. Redundant (but honored) on a plain
    /// member.
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

    /// The GetField name ConstId when this function's body is exactly the
    /// accessor shape `LoadParam #0; GetField; return` — the canonical
    /// property-getter lowering — else null. Cached in place under the
    /// `fast_call` benign-race convention. An image func's body decodes
    /// lazily; classify the real instructions (`accessorFieldConstIn`),
    /// or never for a caller without the module in hand.
    pub fn accessorFieldConstIn(self: *const Func, module: *const Module) ?ConstId {
        if (self.acc_state == 0 and self.blocks.len == 0) {
            _ = module.ensureFuncBody(@constCast(self));
        }
        return self.accessorFieldConst();
    }

    pub fn accessorFieldConst(self: *const Func) ?ConstId {
        switch (self.acc_state) {
            1 => return null,
            2 => return @enumFromInt(self.acc_field),
            else => {},
        }
        if (self.blocks.len == 0) return null;
        const verdict: ?ConstId = blk: {
            if (self.params.len != 1 or self.is_suspend or self.blocks.len != 1) break :blk null;
            const b = &self.blocks[0];
            if (b.catches.len != 0 or b.insts.len != 2) break :blk null;
            const lp = switch (b.insts[0]) {
                .LoadParam => |lp| lp,
                else => break :blk null,
            };
            if (lp.idx != 0) break :blk null;
            const gf = switch (b.insts[1]) {
                .GetField => |gf| gf,
                else => break :blk null,
            };
            if (gf.receiver != lp.dst) break :blk null;
            const ret = switch (b.terminator) {
                .Return => |r| r orelse break :blk null,
                else => break :blk null,
            };
            if (ret != gf.dst) break :blk null;
            break :blk gf.field;
        };
        if (verdict) |f| {
            @constCast(self).acc_field = @intCast(f.int());
            @constCast(self).acc_state = 2;
            return f;
        }
        @constCast(self).acc_state = 1;
        return null;
    }

    /// Whether this body is a *leaf expression*: one block, no handlers, a
    /// `Return` of a register, and nothing but parameter loads, constants,
    /// stored-field reads, moves and primitive operators in between. Such a
    /// body observes nothing beyond its arguments and the fields it reads,
    /// so it can be evaluated without building a frame at all.
    ///
    /// The classification is a pure function of the lowered body; cache it
    /// on first ask under the same benign-race convention as `acc_state`.
    pub fn leafExprBody(self: *const Func) bool {
        switch (self.leaf_state) {
            1 => return false,
            2, 3 => return true,
            else => {},
        }
        // A DEFERRED body carries no blocks until the image section decodes
        // it. Classifying one here would cache "not a leaf" for a function
        // that becomes a leaf the moment it loads, which is how `Stack.isEmpty`
        // and every other tiny library accessor lost the frameless tier.
        if (self.blocks.len == 0) return false;
        const verdict = self.classifyLeafExprBody();
        @constCast(self).leaf_state = if (!verdict)
            1
        else if (self.leafDefBeforeUse())
            3
        else
            2;
        return verdict;
    }

    /// Whether every register read in the body is dominated by a write: a
    /// read is admitted when an earlier instruction of the SAME block wrote
    /// the register, or the ENTRY block wrote it (the entry runs before any
    /// other block, so its writes dominate everything). When this holds the
    /// leaf serve can skip zero-filling its register bank — no path can
    /// observe a stale slot.
    pub fn leafNoFill(self: *const Func) bool {
        return self.leaf_state == 3;
    }

    fn leafDefBeforeUse(self: *const Func) bool {
        const Ctx = struct {
            uses: u64 = 0,
            defs: u64 = 0,
            oob: bool = false,
            fn visit(c: *@This(), reg: Reg, is_def: bool) void {
                const r = reg.int();
                if (r >= 64) {
                    c.oob = true;
                    return;
                }
                const bit = @as(u64, 1) << @intCast(r);
                if (is_def) c.defs |= bit else c.uses |= bit;
            }
        };
        var entry_written: u64 = 0;
        for (self.blocks, 0..) |*b, bi| {
            var written: u64 = entry_written;
            for (b.insts) |*inst| {
                var c: Ctx = .{};
                visitInstRegs(inst, &c, Ctx.visit);
                if (c.oob) return false;
                if (c.uses & ~written != 0) return false;
                written |= c.defs;
            }
            var c: Ctx = .{};
            visitTerminatorRegs(&b.terminator, &c, Ctx.visit);
            if (c.oob) return false;
            if (c.uses & ~written != 0) return false;
            written |= c.defs;
            if (bi == 0) entry_written = written;
        }
        return true;
    }

    /// Whether a fresh frame for this func may leave its register file
    /// unfilled: every register read in the body is preceded by a write on
    /// ALL paths from entry, so no path can observe a stale slot. Beyond
    /// `leafNoFill`'s same-block/entry rule this runs a must-written
    /// dataflow over the CFG (join = intersection over predecessors), so
    /// branch-and-join initialization (`val x = if (c) a else b`) proves
    /// too. Funcs with catch/finally/labeled-return absorption keep the
    /// eager fill — an exception edge can enter a handler with only part
    /// of a block's writes done. The proof covers program reads only; the
    /// frame layer's written mask keeps the collector and suspension
    /// snapshots away from unwritten slots.
    pub fn frameNoFill(self: *const Func) bool {
        switch (self.frame_fill_state) {
            1 => return false,
            2 => return true,
            else => {},
        }
        // A deferred body has no blocks to analyze yet; decide (and cache)
        // only once it is decoded.
        if (self.blocks.len == 0) return false;
        const verdict = self.frameDefBeforeUse();
        @constCast(self).frame_fill_state = if (verdict) 2 else 1;
        return verdict;
    }

    fn frameDefBeforeUse(self: *const Func) bool {
        if (self.n_locals > FRAME_FILL_MAX_REGS) return false;
        const nb = self.blocks.len;
        if (nb == 0 or nb > FRAME_FILL_MAX_BLOCKS) return false;
        const entry_idx = self.entry.int();
        if (entry_idx >= nb) return false;
        for (self.blocks) |*b| {
            if (b.catches.len != 0 or b.finally != null or b.lr_absorb != null) return false;
        }
        const Ctx = struct {
            uses: RegSet = regSetEmpty(),
            defs: RegSet = regSetEmpty(),
            oob: bool = false,
            fn visit(c: *@This(), reg: Reg, is_def: bool) void {
                const r = reg.int();
                if (r >= FRAME_FILL_MAX_REGS) {
                    c.oob = true;
                    return;
                }
                if (is_def) regSetSet(&c.defs, r) else regSetSet(&c.uses, r);
            }
        };
        // Per-block summary: `gen` = registers the block writes, `exposed` =
        // registers it reads before writing them itself. An instruction's own
        // def never covers its own use (operands are read first), so uses are
        // checked against strictly earlier instructions only. The scratch
        // lives in TLS: stack arrays this size are poisoned on every call
        // under the safe builds, and every slot consulted below is written
        // first (`gen`/`exposed` per block, `in` in the explicit init loop).
        const gen = &frame_fill_scratch[0];
        const exposed = &frame_fill_scratch[1];
        for (self.blocks, 0..) |*b, bi| {
            var written: RegSet = regSetEmpty();
            var expo: RegSet = regSetEmpty();
            for (b.insts) |*inst| {
                // `CtxScope.ctx_args` is a contiguous run of `n_ctx`
                // registers, but the register visitor's run convention
                // covers only the `args`+`n_args` field pair — the run's
                // tail registers would go unreported as uses. Keep the
                // eager fill for such bodies.
                if (inst.* == .CtxScope) return false;
                var c: Ctx = .{};
                visitInstRegs(inst, &c, Ctx.visit);
                if (c.oob) return false;
                regSetOrAndNot(&expo, c.uses, written);
                regSetOr(&written, c.defs);
            }
            var c: Ctx = .{};
            visitTerminatorRegs(&b.terminator, &c, Ctx.visit);
            if (c.oob) return false;
            regSetOrAndNot(&expo, c.uses, written);
            regSetOr(&written, c.defs);
            gen[bi] = written;
            exposed[bi] = expo;
        }
        // Forward must-written fixpoint. Unreachable blocks keep the ALL
        // set and verify vacuously — they never run. A `TailJump` resets
        // the register file, so it contributes no edge (the entry's in-set
        // is pinned empty anyway); `TailCallFunc` leaves the function.
        const in = &frame_fill_scratch[2];
        for (0..nb) |bi| in[bi] = regSetFull();
        in[entry_idx] = regSetEmpty();
        var rounds: usize = 0;
        while (rounds < nb + 8) : (rounds += 1) {
            var changed = false;
            for (self.blocks, 0..) |*b, bi| {
                var out = in[bi];
                regSetOr(&out, gen[bi]);
                switch (b.terminator) {
                    .Goto => |t| {
                        if (t.int() >= nb) return false;
                        if (t.int() != entry_idx and regSetAndInto(&in[t.int()], out)) changed = true;
                    },
                    .Branch => |br| {
                        for ([2]BlockId{ br.t, br.f }) |t| {
                            if (t.int() >= nb) return false;
                            if (t.int() != entry_idx and regSetAndInto(&in[t.int()], out)) changed = true;
                        }
                    },
                    .Switch => |sw| {
                        for (sw.arms) |arm| {
                            const t = arm.target;
                            if (t.int() >= nb) return false;
                            if (t.int() != entry_idx and regSetAndInto(&in[t.int()], out)) changed = true;
                        }
                        const t = sw.default;
                        if (t.int() >= nb) return false;
                        if (t.int() != entry_idx and regSetAndInto(&in[t.int()], out)) changed = true;
                    },
                    .Return, .Throw, .Unreachable, .TailJump, .TailCallFunc, .NonLocalReturn, .LabeledReturn => {},
                }
            }
            if (!changed) break;
        } else return false;
        for (0..nb) |bi| {
            if (regSetAnyOutside(exposed[bi], in[bi])) return false;
        }
        return true;
    }

    /// Structural admission only. Which INSTRUCTIONS a leaf serve can
    /// actually execute is decided per instruction as it runs, because a
    /// body may reach a value-returning path made entirely of leaf work
    /// while an untaken branch does something the serve cannot do — the
    /// guard shape `if (!ok) reportFailure(lazyMessage())` is the common
    /// case, and its taken path is a constant and a return.
    fn classifyLeafExprBody(self: *const Func) bool {
        if (self.is_suspend or self.is_lambda) return false;
        if (self.blocks.len == 0 or self.blocks.len > LEAF_MAX_BLOCKS) return false;
        if (self.n_locals > LEAF_MAX_REGS) return false;
        var total: usize = 0;
        for (self.blocks) |*b| {
            // A finally-carrying body needs the try-stack machinery: the
            // frameless walk would return straight out of the try region
            // and never run the finally.
            if (b.catches.len != 0 or b.finally != null or b.lr_absorb != null) return false;
            total += b.insts.len;
            if (total > LEAF_MAX_INSTS) return false;
            switch (b.terminator) {
                // A `Return` with no register is a `Unit` return — the shape
                // of every guard helper, which is exactly what this admits.
                .Return, .Goto, .Branch => {},
                // A guard's FAILING arm (`if (!ok) throw ...`) never runs on
                // the path this exists to serve. Admit it structurally and let
                // the walk abandon if it ever lands there, the same rule the
                // instruction set follows — otherwise every `assert`/`require`
                // helper builds an activation to evaluate one comparison.
                .Throw, .Unreachable => {},
                else => return false,
            }
        }
        for (self.params) |*p| {
            if (p.is_vararg or p.default != null) return false;
        }
        return true;
    }
};

/// Bounds for `leafExprBody`. A leaf serve keeps its registers in a fixed
/// stack array, so both the register count and the body length are capped;
/// the block bound keeps a guard-shaped body admissible without admitting
/// real control flow, and `LEAF_MAX_STEPS` bounds the walk itself.
pub const LEAF_MAX_REGS: u32 = 64;

/// CFG size bound for `frameNoFill`'s dataflow: the scratch sets are fixed
/// buffers, and a body past this many blocks keeps the eager fill.
const FRAME_FILL_MAX_BLOCKS: usize = 256;

/// Register-set width for `frameDefBeforeUse`, in 64-bit words. Compose's
/// composables and slot-table walkers run 70-500 locals (`GapComposer.end`
/// alone carries 502); capping the analysis at one word sent every one of
/// them to the eager fill.
pub const FRAME_FILL_WORDS: usize = 8;
pub const FRAME_FILL_MAX_REGS: u32 = FRAME_FILL_WORDS * 64;

const RegSet = [FRAME_FILL_WORDS]u64;

inline fn regSetEmpty() RegSet {
    return @splat(0);
}
inline fn regSetFull() RegSet {
    return @splat(~@as(u64, 0));
}
inline fn regSetHas(a: RegSet, i: usize) bool {
    return (a[i >> 6] >> @as(u6, @truncate(i))) & 1 != 0;
}
inline fn regSetSet(a: *RegSet, i: usize) void {
    a[i >> 6] |= @as(u64, 1) << @as(u6, @truncate(i));
}
inline fn regSetOrAndNot(dst: *RegSet, x: RegSet, notted: RegSet) void {
    for (dst, x, notted) |*d, xv, nv| d.* |= xv & ~nv;
}
inline fn regSetOr(dst: *RegSet, x: RegSet) void {
    for (dst, x) |*d, xv| d.* |= xv;
}
inline fn regSetAndInto(dst: *RegSet, x: RegSet) bool {
    var changed = false;
    for (dst, x) |*d, xv| {
        const nv = d.* & xv;
        if (nv != d.*) {
            d.* = nv;
            changed = true;
        }
    }
    return changed;
}
inline fn regSetAnyOutside(a: RegSet, b: RegSet) bool {
    for (a, b) |av, bv| {
        if (av & ~bv != 0) return true;
    }
    return false;
}

/// `frameDefBeforeUse` scratch (gen / exposed / in). Thread-local so the
/// once-per-func analysis never pays the safe builds' stack poisoning, and
/// concurrent first-asks on different threads stay independent.
threadlocal var frame_fill_scratch: [3][FRAME_FILL_MAX_BLOCKS]RegSet = undefined;
pub const LEAF_MAX_INSTS: usize = 96;
pub const LEAF_MAX_BLOCKS: usize = 32;
pub const LEAF_MAX_STEPS: usize = 160;

pub const Param = struct {
    name: []const u8,
    ty: TypeRef,
    default: ?BlockId,
    /// Source function-type arity when this parameter is `@Composable`.
    /// Null distinguishes an ordinary function parameter from a composable
    /// zero-argument parameter.
    composable_arity: ?u8 = null,
    /// Extension-receiver + context slots of a `@Composable` function-typed
    /// parameter — the leading value slots a NON-inline sink's lambda takes
    /// beyond `composable_arity` when invoked through the value protocol.
    composable_recv_slots: u8 = 0,
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
    /// Declaration-site variance parallel to `type_params`.
    type_param_variance: []const ast.Variance = &.{},
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
    /// is final: it can never be subclassed, so its members cannot be overridden.
    is_open: bool = false,
    /// An enum class: its entries' bodies may override its `open`/`abstract`
    /// members, so member dispatch stays virtual for those.
    is_enum: bool = false,
    /// A named Kotlin `object`. Calling its classifier name resolves the
    /// singleton value and dispatches `operator fun invoke`; it is never a
    /// constructor call despite sharing the class table representation.
    is_object: bool = false,
    /// A Kotlin value class. Its receiver uses a specialized runtime
    /// representation, so ordinary instance-call ABI assumptions do not apply.
    is_value: bool = false,
    /// Runtime representation of values observed through this classifier.
    /// Only `instance` classifiers can use the numeric virtual-call ABI.
    receiver_abi: runtime.ReceiverAbi = .instance,
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
/// Companion to `pending_eager_calls` for picks whose declaration came from
/// a prebuilt image: those carry a FuncId, never a span.
pub threadlocal var pending_eager_call_fids: ?std.AutoHashMap(span.Span, u32) = null;
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

/// One full type-parameter bound ref (with type arguments) carried into a
/// pending lambda/local-fn body. Owned by the module allocator.
pub const RecvHeadKV = struct { name: []const u8, head: ?[]const u8 };

pub const PendingBoundRef = struct {
    param: []const u8,
    ref: TypeRef,
};

pub const PendingLocalDeclTypes = struct {
    types: std.StringHashMap(TypeRef),
    nullable: std.StringHashMap(void),
    call_returns: std.StringHashMap(EagerTypeHead),
};

pub const Module = struct {
    /// REQUIREMENT, not merely an observation: a `Module` may be written
    /// only during single-threaded setup, before any interpreter thread
    /// runs. Today the sole such writer is the class-id overlay built by
    /// `linkProgramForms` at `Vm` init. Anything that needs to mutate a
    /// module once execution has started must arrange its own
    /// synchronisation — the cell no longer provides any.
    ///
    /// The reader lock this drops was guarding against a writer that cannot
    /// exist concurrently, at a cost of a `cmpxchg` plus a `fetchSub` on
    /// every borrow, and the module is borrowed on most dispatches. It was
    /// never protecting the per-`Func` dispatch memos anyway: those are
    /// written through `@constCast` under their own single-fill/atomic
    /// discipline, deliberately outside the cell's borrow rules.
    pub const objref_immutable = true;

    /// Direct-mapped pointer-identity memo for `classIdByFqn` probes whose
    /// key is a STATIC string (the comptime `Value.typeFqn` literals the
    /// virtual-dispatch fallback hashes per call). Keys claim a slot by
    /// pointer CAS from 0; the value (0 = unset, 1 = no class, else
    /// ClassId + 2) is release-stored after the claim as the validity gate.
    /// Written through `@constCast` under the same single-fill discipline as
    /// the per-`Func` dispatch memos (`classIdByStaticFqn`). Callers must
    /// guarantee the key pointer's content can never change (a
    /// stack-composed FQN must NOT use this).
    cid_memo_keys: [cid_memo_slots]std.atomic.Value(usize) = @splat(std.atomic.Value(usize).init(0)),
    cid_memo_vals: [cid_memo_slots]std.atomic.Value(u64) = @splat(std.atomic.Value(u64).init(0)),

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
    /// Lowering-only scratch: the DECLARED types of the parameters a
    /// synthesized parameter thunk is about to bind, parallel to its name
    /// list. A constructor-delegation argument or a default-value
    /// expression is lowered in its own builder, which knew the parameter
    /// NAMES only, so `seed1.inv()` inside `: this(..., seed1.inv(), ...)`
    /// had no receiver type at all. Not serialized.
    pending_param_types: ?[]const ?ast.TypeRef = null,
    /// The EXPECTED type of the next parameter-thunk expression (a parent
    /// constructor argument's declared parameter type, instantiated by the
    /// written supertype arguments), consumed by the thunk lowering.
    pending_thunk_expected: ?ast.TypeRef = null,
    /// Lowering-only scratch: the callable arity mask of the owner class's
    /// members, for a synthesized parameter thunk that also gets an
    /// `own_members` set. A member name that is a PROPERTY and never a
    /// function carries mask 0, so a bare CALL of that name in a
    /// constructor-delegation argument is not mistaken for a companion
    /// call on the owner class. Not serialized.
    pending_own_member_arity: ?*const std.StringHashMap(u64) = null,
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
    /// Full implicit receiver tower for the lambda body about to lower,
    /// innermost first. Not serialized.
    pending_lambda_receiver_tower: ?[]const ReceiverTowerEntry = null,
    /// Structural type of `pending_lambda_own_recv`, transferred into the
    /// lambda body's builder. Not serialized.
    pending_lambda_own_recv_type: ?TypeRef = null,
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
    /// The pending lambda literal binds a `(...) -> Unit` parameter: its
    /// tail expression is evaluated for effect and the lambda returns Unit.
    /// Consumed on entry to the lambda body so it never leaks inward.
    pending_lambda_unit: bool = false,
    /// Non-reified type-parameter names in scope at the lambda body about to
    /// lower, carried into that body so an `x as T` cast inside the lambda is
    /// still erased (`forEachScopeOf(v) { scope -> scope as Scope }` inside a
    /// generic class). Not serialized.
    pending_lambda_type_params: ?[]const []const u8 = null,
    /// The enclosing splice's REIFIED type-parameter substitutions, carried
    /// into a lambda body lowered inside that splice. `filter { it is R }` in
    /// a spliced `filterIsInstance<reified R>` reads `R` from here; without
    /// it the body falls back to the runtime's bound class value, which
    /// cannot carry nullability. Not serialized.
    pending_lambda_reified_names: ?[]const ReifiedName = null,
    /// Effective upper bounds parallel to the type-parameter names carried
    /// into the pending lambda/local-function body. Not serialized.
    pending_lambda_type_param_bounds: ?[]const ModuleRegistry.TypeParamBound = null,
    /// Full bound REFS (with type arguments) for the pending body, so a
    /// receiver typed by a parameter substitutes inside nested lambdas too
    /// (`data.any { it.startsWith("f") }` in a test method's expect-lambda).
    /// Owned pairs; the lambda body takes ownership. Not serialized.
    pending_lambda_type_param_bound_refs: ?[]PendingBoundRef = null,
    /// Contextual function-type parameters of the enclosing builder, handed
    /// to a lambda body so an implicit call `f(a..)` inside it still splits
    /// its context arguments.
    pending_lambda_ctx_fn_shapes: ?[]PendingCtxFnShape = null,
    /// Receiver-lambda param names -> declared receiver heads of the
    /// ENCLOSING builder, carried into a nested lambda body so a captured
    /// receiver-fn param invoked bare there re-selects by its declared
    /// head. Registry/arena-stable slices; the lambda body copies the
    /// entries and frees the slice. Not serialized.
    pending_lambda_recv_heads: ?[]RecvHeadKV = null,
    /// Engine step four: the caller's SOLVED fn-tp bindings for an inline
    /// splice, registered as window bound refs at entry. Names are
    /// registry-stable fn-tp slices; tys owned by the lowering allocator
    /// (the consumer moves them into the builder's ref map).
    pending_splice_solved: ?[]Module.TypeBinding = null,
    /// Instantiated value-parameter types for the pending lambda literal,
    /// derived from its resolved call-argument slot. The lambda body takes
    /// ownership and records them as ordinary local declared types.
    pending_lambda_param_types: ?[]TypeRef = null,
    /// Context parameters of the anonymous function whose body is lowered
    /// next; the body lowering binds each from the context stack at entry.
    pending_lambda_ctx_params: ?[]const ast.ContextParam = null,
    /// The LOCAL `fun` whose body (or a lambda nested in it) is about to
    /// lower: its declared name and its mangled overload-cell binding. A bare
    /// self-reference in that body must call through the mangled cell — the
    /// plain-name slot is shared with any later same-named sibling declaration
    /// (last bind wins), so a self re-invoke captured by name (the compose
    /// restart lambda) would run the SIBLING. Not serialized.
    pending_lambda_self_fn: ?SelfLocalFn = null,
    /// The next lambda body's declared shape is KNOWN to take no receiver
    /// (a plain `(T) -> R` slot): its bare calls may consult the enclosing
    /// receiver tier, exactly Kotlin's implicit-receiver chain. A lambda
    /// whose receiver is merely UNTYPED must not (the ArrayDeque hazard).
    pending_lambda_no_receiver: bool = false,
    /// Names of enclosing-scope locals with definite NON-callable evidence
    /// (literal init / primitive declared type), carried into the lambda body
    /// about to lower so a bare CALL there does not route through the captured
    /// value (`var key = 0` beside the `key(...) {}` composable). Owned by the
    /// receiving builder once consumed. Not serialized.
    pending_lambda_nonfn_locals: ?std.StringHashMap(void) = null,
    /// Names of the local `fun`'s vararg parameters for the body about to
    /// lower: inside the body such a parameter's static type is the
    /// MATERIALIZED array, never the element the annotation names, so the
    /// declared-annotation registration must not record the element head.
    /// Borrowed from the caller's AST for the lowering call's duration.
    pending_lambda_vararg_params: ?[]const []const u8 = null,
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
    /// Lowering-phase simple name → what the per-name class scans would
    /// find: the `ClassId` `uniqueClassIdBySimpleName` returns (or
    /// `class_id_ambiguous`), plus whether any class under the name lives
    /// outside the `kotlin` packages (`staticBuiltinIdentity`'s scan).
    /// Each class contributes under both its `name` and its FQN's last
    /// segment. Entries fold many classes, so the stub-claim FQN rewrite
    /// cannot patch one contribution out; a claim that touches the cached
    /// range resets the cache for a lazy rebuild.
    unique_simple_cache: std.StringHashMapUnmanaged(SimpleNameInfo) = .empty,
    unique_simple_cache_n: usize = 0,
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
    /// A per-anon-site image clone runtime-synthesized members lower into.
    /// Decl-span reservations are disabled on it: synthesized getter/setter
    /// thunks share their property ident's span, and the reservation channel
    /// made the second thunk OVERWRITE the first at the adopted id.
    anon_side: bool = false,
    /// The eager pipeline's per-call resolution: `Span(callee) ->
    /// Span(decl)` converted from typeck's records by the driver
    /// Lowering composes it with `func_by_decl_span`;
    /// absent spans keep the lazy path.
    eager_calls: ?std.AutoHashMap(span.Span, span.Span) = null,
    eager_call_fids: ?std.AutoHashMap(span.Span, u32) = null,
    /// Typeck's per-expression type heads (the E2.1 evidence seam).
    eager_types: ?std.AutoHashMap(span.Span, EagerTypeHead) = null,
    eager_recv_heads: ?std.AutoHashMap(span.Span, []const u8) = null,
    /// Extension-candidate index: receiver head -> the extension NAMES
    /// declared on it, plus the generic-receiver names (`fun <T> T.also`)
    /// that apply to every head. Rebuilt lazily when the declaration index
    /// has grown. Answers the E4c membership question the hierarchy sets
    /// cannot: could ANY extension named N serve receiver head H?
    ext_names_by_recv_head: ?std.StringHashMap(std.StringHashMap(ExtArity)) = null,
    generic_ext_names: ?std.StringHashMap(ExtArity) = null,
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
        visibility: ast.Visibility = .Public,
        is_inline: bool = false,
        is_suspend: bool = false,
        /// The declaration carries a source body.
        has_body: bool = false,
        /// Exact fully-qualified host ABI symbol for this declaration. A
        /// bodyless declaration with this identity uses the ordinary FuncId
        /// call ABI; link finalization attaches the host function once.
        host_symbol: ?[]const u8 = null,
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
        /// Unique declaration identity when the candidate set proves one.
        /// A deferred result may still carry this as expected-type metadata
        /// for arguments while withholding a static dispatch commitment.
        target: ?FuncId = null,
        dispatch: MemberDispatch = .deferred,
        /// At least one visible member accepts the supplied call shape.
        /// This remains true for an ambiguity or incomplete static type proof,
        /// where `target` must stay null but the member still shadows a
        /// same-named package function.
        applicable: bool = false,
    };

    pub const MemberResolveCtx = struct {
        /// Source file containing the call. Together with the declaration
        /// span this identifies Kotlin `internal` visibility.
        caller_file: ?FileId = null,
        /// Innermost lexical class whose body contains the call. Visibility
        /// walks its enclosing-class chain.
        lexical_owner: ?ClassId = null,
        /// Restrict the query to private declarations. Used by bare own-member
        /// calls, which can commit directly without considering virtual peers.
        private_only: bool = false,
        actual_type_param_bounds: []const ModuleRegistry.TypeParamBound = &.{},
        receiver_type: ?TypeRef = null,
    };

    pub const ExtensionResolveCtx = struct {
        /// The caller's MEMBER resolution statically refuted every member
        /// candidate: kotlinc's answer can only be an extension, so a sole
        /// receiver-proven survivor commits even with unknown args.
        member_refuted: bool = false,
        caller_file: FileId,
        caller_package: []const u8,
        /// Ordered implicit receiver heads that can supply a member
        /// extension's dispatch owner, innermost first.
        implicit_dispatch_owners: []const []const u8 = &.{},
        /// Lexically enclosing class or object, retained separately from an
        /// inner receiver-lambda head.
        lexical_owner: ?[]const u8 = null,
        /// Source-visible alias used for member-extension shadow checks.
        call_name: ?[]const u8 = null,
        /// Bounds of type parameters owned by the enclosing declaration. They
        /// make a receiver such as `Array<T>` fully static when `T` itself is
        /// the caller's bounded type parameter.
        actual_type_param_bounds: []const ModuleRegistry.TypeParamBound = &.{},
    };

    pub const ExtensionResolution = struct {
        target: ?FuncId = null,
        dispatch_owner: ?ClassId = null,
        /// At least one visible extension accepts the receiver and arguments.
        /// A tie or incomplete proof keeps `target` null without making the
        /// extension disappear from the candidate scope.
        applicable: bool = false,
        /// The same source argument list can bind a visible extension after
        /// appending the Compose compiler ABI pair.
        compiler_abi_applicable: bool = false,
        /// A strict-key winner whose only weakness is an UNKNOWN argument
        /// verdict. Its identity is not in doubt — RETURN-TYPE derivation
        /// may use it (the `joinTo(StringBuilder(), ...)` chain); emission
        /// must NOT, dispatch commitment still requires proof (the
        /// trimIndent hazard is precisely about emission).
        sole_unknown: ?FuncId = null,
        /// A TIED set whose candidates all declare the same parameter list
        /// except each function-typed parameter's RETURN position — the
        /// `flatMapIndexed` shape, overloaded on the lambda's return alone.
        /// Only LAMBDA-PARAMETER typing may read this candidate: the tie is
        /// real (return types and dispatch identity stay unresolved), but
        /// every candidate hands the closure the same parameter types.
        param_rep: ?FuncId = null,
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
        if (pending_eager_call_fids) |pf| {
            out__.eager_call_fids = pf;
            pending_eager_call_fids = null;
        }
        if (pending_eager_calls) |pec| {
            out__.eager_calls = pec;
            pending_eager_calls = null;
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
        // Serialize the decode + publication: two threads first-touching the
        // same deferred body raced the two-word `blocks` slice write (a
        // reader could observe a torn ptr/len pair), and an unfenced
        // publication let a second core see downstream state (a memoized
        // fused verdict) before the blocks themselves. The header lock's
        // acquire/release brackets are the ordering edge.
        const mut: *Module = @constCast(self);
        while (mut.func_header_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
        defer mut.func_header_lock.store(false, .release);
        if (func.blocks.len != 0) return true;
        if (func.deferred_offset == 0) return false;
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

    fn classIdIsOrExtendsDepth(
        self: *const Module,
        sub: ClassId,
        super: ClassId,
        depth: u8,
    ) bool {
        if (sub == super) return true;
        if (depth >= 64 or sub.int() >= self.classes.items.len) return false;
        for (self.classes.items[sub.int()].supertypes) |parent| {
            if (self.classIdIsOrExtendsDepth(parent, super, depth + 1)) return true;
        }
        return false;
    }

    /// Class-identity hierarchy check used where simple names are not enough
    /// to prove Kotlin visibility or dispatch ownership.
    pub fn classIdIsOrExtends(self: *const Module, sub: ClassId, super: ClassId) bool {
        if (super.int() >= self.classes.items.len) return false;
        return self.classIdIsOrExtendsDepth(sub, super, 0);
    }

    /// Whether `cls` or any supertype declares a member named `name`,
    /// arity-blind. The declaration-completeness audit's member probe: it
    /// answers "can resolution see SOME declaration for this name on this
    /// receiver", which an empty-shape resolveMemberCall cannot (a member
    /// with required parameters refuses a zero-arg probe).
    pub fn classHierarchyDeclaresMember(self: *const Module, cls: ClassId, name: []const u8) bool {
        return self.classHierarchyDeclaresMemberDepth(cls, name, 0);
    }

    fn classHierarchyDeclaresMemberDepth(self: *const Module, cls: ClassId, name: []const u8, depth: u8) bool {
        if (depth >= 64 or cls.int() >= self.classes.items.len) return false;
        const c = &self.classes.items[cls.int()];
        for (c.methods) |mid| {
            if (self.funcById(mid)) |mf| {
                if (std.mem.eql(u8, mf.name, name)) return true;
            }
        }
        // The builtin headers' rows often carry NO method FuncIds — their
        // member declarations live in decl_sigs and reach dispatch through
        // the member-name index instead.
        if (self.memberDecls(c.fqn, name).len != 0) return true;
        // PROPERTY members (`size`, `length`, `entries`) appear in neither
        // list; the hierarchy shadow-name set is the registry's transitive
        // member-name record and carries them.
        if (self.registry.hierarchy_shadow_names.get(c.name)) |hs| {
            if (hs.names.contains(name)) return true;
        }
        for (c.supertypes) |p| {
            if (self.classHierarchyDeclaresMemberDepth(p, name, depth + 1)) return true;
        }
        return false;
    }

    fn enclosingClassId(self: *const Module, child: ClassId) ?ClassId {
        if (child.int() >= self.classes.items.len) return null;
        const class = &self.classes.items[child.int()];
        const enclosing_name = self.registry.enclosing_class.get(class.name) orelse
            self.registry.enclosing_class.get(class.fqn) orelse return null;
        for (self.classes.items) |candidate| {
            if (!std.mem.eql(u8, candidate.package, class.package)) continue;
            if (std.mem.eql(u8, candidate.name, enclosing_name) or
                std.mem.eql(u8, candidate.fqn, enclosing_name)) return candidate.id;
        }
        return self.classIdByFqn(enclosing_name) orelse
            self.classIdByQualifiedSuffix(enclosing_name) orelse
            self.classId(enclosing_name);
    }

    fn lexicalChainContains(self: *const Module, start: ClassId, target: ClassId) bool {
        var current: ?ClassId = start;
        var depth: u8 = 0;
        while (current) |id| : (depth += 1) {
            if (id == target) return true;
            if (depth >= 64) return false;
            current = self.enclosingClassId(id);
        }
        return false;
    }

    fn protectedAccessOwner(
        self: *const Module,
        start: ClassId,
        declared_owner: ClassId,
    ) ?ClassId {
        var current: ?ClassId = start;
        var depth: u8 = 0;
        while (current) |id| : (depth += 1) {
            if (self.classIdIsOrExtends(id, declared_owner)) return id;
            if (depth >= 64) return null;
            current = self.enclosingClassId(id);
        }
        return null;
    }

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

    fn staticTypeVar(raw: *anyopaque, fid: FuncId, ty: *const TypeRef) bool {
        const self: *const Module = @ptrCast(@alignCast(raw));
        for (ty.args) |arg| {
            if (std.mem.startsWith(u8, arg.name, "#qual:")) return false;
        }
        return self.funcTypeParamIndex(fid, staticTypeHead(ty.name)) != null;
    }

    fn staticTypeArgsEqual(actual: []const TypeRef, declared: []const TypeRef) bool {
        if (actual.len != declared.len) return false;
        for (actual, declared) |a, d| {
            if (a.nullable != d.nullable or !std.mem.eql(u8, a.name, d.name) or
                !staticTypeArgsEqual(a.args, d.args)) return false;
        }
        return true;
    }

    pub const StaticCompatibility = enum {
        incompatible,
        unknown,
        compatible,
    };

    fn staticDeclTypeParam(self: *const Module, fid: FuncId, ty: TypeRef) bool {
        if (overrideQualifiedPath(ty) != null) return false;
        const name = staticTypeHead(ty.name);
        if (self.funcTypeParamIndex(fid, name) != null) return true;
        const owner = (self.decl_sigs.get(fid.int()) orelse return false).enclosing_class orelse
            return false;
        if (owner.int() >= self.classes.items.len) return false;
        if (parseClassTypeParamIdentity(name)) |identity| {
            if (identity.owner != owner) return false;
            for (self.classes.items[owner.int()].type_params) |param| {
                if (std.mem.eql(u8, param, identity.param)) return true;
            }
            return false;
        }
        return false;
    }

    pub fn staticFuncTypeParamBound(
        self: *const Module,
        fid: FuncId,
        name: []const u8,
    ) ?[]const u8 {
        if (self.funcTypeParamIndex(fid, name) == null) return null;
        if (self.registry.func_type_param_bounds.get(fid)) |bounds| {
            for (bounds) |entry| {
                if (std.mem.eql(u8, entry.param, name)) return entry.bound;
            }
        }
        return "kotlin.Any";
    }

    fn staticTypeContainsFuncParam(
        self: *const Module,
        fid: FuncId,
        ty: TypeRef,
    ) bool {
        if (overrideQualifiedPath(ty) != null) return false;
        // A use-site projection hides the parameter from the raw head:
        // `Array<out T>` contains T even though its argument's head spells
        // `out#T` — without the strip the whole parameter routed through
        // receiver compatibility and the generic proof never ran.
        var head = staticTypeHead(ty.name);
        if (std.mem.startsWith(u8, head, "out#")) {
            head = head["out#".len..];
        } else if (std.mem.startsWith(u8, head, "in#")) {
            head = head["in#".len..];
        }
        if (self.funcTypeParamIndex(fid, head) != null) return true;
        for (overrideArgs(ty)) |arg| {
            if (self.staticTypeContainsFuncParam(fid, arg)) return true;
        }
        return false;
    }

    /// Prove one actual argument against a parameter containing declaration
    /// type variables. Classifier compatibility is checked structurally; a
    /// direct type variable accepts any value satisfying its upper bound.
    fn staticGenericArgCompatibility(
        self: *const Module,
        fid: FuncId,
        actual: TypeRef,
        param: TypeRef,
        depth: u8,
    ) StaticCompatibility {
        if (depth >= 32) return .unknown;
        // A use-site variance projection is transparent to compatibility:
        // `Array<String>` against `Array<out T>` adjudicates String-vs-T,
        // not String-vs-`out#T` (whose head names nothing and left the
        // Array overload of `minus` unknown at the argument step).
        if (std.mem.startsWith(u8, param.name, "out#") or
            std.mem.startsWith(u8, param.name, "in#"))
        {
            var stripped = param;
            stripped.name = if (std.mem.startsWith(u8, param.name, "out#"))
                param.name["out#".len..]
            else
                param.name["in#".len..];
            return self.staticGenericArgCompatibility(fid, actual, stripped, depth + 1);
        }
        if (std.mem.startsWith(u8, actual.name, "out#") or
            std.mem.startsWith(u8, actual.name, "in#"))
        {
            var stripped = actual;
            stripped.name = if (std.mem.startsWith(u8, actual.name, "out#"))
                actual.name["out#".len..]
            else
                actual.name["in#".len..];
            return self.staticGenericArgCompatibility(fid, stripped, param, depth + 1);
        }
        const param_head = staticTypeHead(param.name);
        if (overrideQualifiedPath(param) == null) {
            if (self.staticFuncTypeParamBound(fid, param_head)) |bound| {
                if (std.mem.eql(u8, applicability.simpleName(staticTypeHead(bound)), "Any")) return .compatible;
                return self.staticReceiverCompatibility(
                    null,
                    actual,
                    .{ .name = bound, .nullable = false, .args = &.{} },
                );
            }
        }
        if (actual.nullable and !param.nullable) return .incompatible;

        var actual_erased = actual;
        actual_erased.args = &.{};
        var param_erased = param;
        param_erased.args = &.{};
        const actual_head = staticTypeHead(actual_erased.name);
        const param_erased_head = staticTypeHead(param_erased.name);
        if (!std.mem.eql(u8, actual_head, param_erased_head)) {
            // `Any` is the universal supertype: every classifier satisfies
            // it, and the class table records no edges to it.
            if (std.mem.eql(u8, applicability.simpleName(param_erased_head), "Any")) return .compatible;
            const actual_id = self.staticTypeClassId(actual_erased);
            var param_id = self.staticTypeClassId(param_erased);
            // A param head written inside its declaring class resolves in
            // that class's scope first: `get(key: Key<E>)` inside
            // `CoroutineContext` means the NESTED `CoroutineContext.Key`,
            // which a bare simple-name lookup misses (every companion is
            // named `Key`) — and the missed resolution judged the actual's
            // companion INCOMPATIBLE against the interface's own member.
            if (param_id == null) {
                if (self.decl_sigs.get(fid.int())) |ds| {
                    if (ds.enclosing_class) |ec| {
                        if (ec.int() < self.classes.items.len) {
                            var qb: [160]u8 = undefined;
                            if (std.fmt.bufPrint(&qb, "{s}.{s}", .{
                                self.classes.items[ec.int()].name,
                                param_erased_head,
                            }) catch null) |q| {
                                param_id = self.classIdByQualifiedSuffix(q);
                            }
                        }
                    }
                }
            }
            if (actual_id != null and param_id != null and
                !self.classIdIsOrExtends(actual_id.?, param_id.?))
            {
                return .incompatible;
            }
            if (self.staticBuiltinIdentity(actual_erased, actual_head) == .yes and
                self.staticBuiltinIdentity(param_erased, param_erased_head) == .yes and
                !evidenceSubtypeCb(
                    @ptrCast(@constCast(self)),
                    actual_head,
                    param_erased_head,
                ))
            {
                return .incompatible;
            }
            // A Kotlin Array is NOT an Iterable/Collection/Sequence. The
            // runtime models arrays against those interfaces for member
            // dispatch convenience, but overload REFUTATION follows
            // kotlinc: `minus(elements: Iterable<T>)` never takes an Array
            // argument, so the Array sibling resolves statically instead
            // of deferring the whole overload set to a runtime value pick.
            if (arrayVsCollectionParam(actual_head, param_erased_head)) {
                return .incompatible;
            }
        }
        // A param head that resolves in its DECLARING class's scope can be
        // proven by the class graph where the name-level classifier fails:
        // `get(key: Key<E>)` inside CoroutineContext means the nested
        // `CoroutineContext.Key`, and the actual's companion
        // `ContinuationInterceptor.Key` extends it — same SIMPLE name, so
        // the erased-head walk above never adjudicated them.
        var scoped_related = false;
        if (self.staticTypeClassId(actual_erased)) |aid| {
            if (self.decl_sigs.get(fid.int())) |ds| {
                if (ds.enclosing_class) |ec| {
                    if (ec.int() < self.classes.items.len) {
                        var qb: [160]u8 = undefined;
                        if (std.fmt.bufPrint(&qb, "{s}.{s}", .{
                            self.classes.items[ec.int()].name,
                            param_erased_head,
                        }) catch null) |q| {
                            if (self.classIdByQualifiedSuffix(q)) |pid| {
                                scoped_related = self.classIdIsOrExtends(aid, pid);
                            }
                        }
                    }
                }
            }
        }
        const classifier: StaticCompatibility = if (scoped_related)
            .compatible
        else
            self.staticReceiverCompatibility(
                null,
                actual_erased,
                param_erased,
            );
        if (classifier != .compatible) return classifier;

        const param_args = overrideArgs(param);
        if (param_args.len == 0) return .compatible;
        const actual_args = overrideArgs(actual);
        // A head-matching actual whose ARGS are absent (a derivation that
        // kept only the head — `arrayOf("foo","g")` shapes as bare `Array`)
        // still satisfies a parameter whose every argument is one of the
        // callee's OWN inferable type parameters: kotlinc binds them by
        // inference, and applicability is not instantiation proof.
        if (actual_args.len == 0 and param_args.len != 0) {
            var all_own_tp = true;
            for (param_args) |pa| {
                var n = pa.name;
                if (std.mem.startsWith(u8, n, "out#")) {
                    n = n["out#".len..];
                } else if (std.mem.startsWith(u8, n, "in#")) {
                    n = n["in#".len..];
                }
                if (self.funcTypeParamIndex(fid, staticTypeHead(n)) == null) {
                    all_own_tp = false;
                    break;
                }
            }
            if (all_own_tp) return .compatible;
        }
        if (actual_args.len != param_args.len) return .unknown;
        var result: StaticCompatibility = .compatible;
        for (actual_args, param_args) |actual_arg, param_arg| {
            const nested = self.staticGenericArgCompatibility(
                fid,
                actual_arg,
                param_arg,
                depth + 1,
            );
            if (nested == .incompatible) return .incompatible;
            if (nested == .unknown) result = .unknown;
        }
        return result;
    }

    /// The promotion proof, third derivation (the first two measured zero
    /// for lack of argument authority — the typing channels now supply it):
    /// a deferred member commits when every supplied argument is
    /// AUTHORITATIVE and member-compatible, and every same-name extension
    /// reachable from the receiver's chain is refuted by arity or by an
    /// argument. Conservative everywhere: an unjudgeable candidate keeps
    /// the deferral.
    pub threadlocal var mpp_why: []const u8 = "-";

    /// Whether a STAR-ERASED parameter is satisfied by this argument on the
    /// head alone. The erasure convention says the arguments neither prove
    /// nor refute, so a `Collection<*>` slot is decided entirely by whether
    /// the argument's class is a `Collection` — which is exactly what
    /// Kotlin checks when it gives `set.addAll(collection)` to the member
    /// rather than the `Iterable` extension beside it.
    /// The mirror of `erasedHeadProves`: a star-erased slot the argument's
    /// head does NOT satisfy is a definite mismatch, so the member is not
    /// the target and the same-named extension beside it is. Restricted to
    /// heads the module KNOWS, so an unresolved or host-only name — whose
    /// hierarchy this module cannot see — never refutes.
    fn erasedHeadRefutes(
        self: *const Module,
        erased: bool,
        param_ty: TypeRef,
        sh: applicability.ArgShape,
    ) bool {
        if (!erased) return false;
        const arg_ty = sh.ty orelse return false;
        if (sh.is_lambda or sh.is_null or sh.is_spread) return false;
        const ah = applicability.simpleName(staticTypeHead(std.mem.trimEnd(u8, arg_ty.name, "?")));
        const ph = applicability.simpleName(staticTypeHead(std.mem.trimEnd(u8, param_ty.name, "?")));
        if (ah.len == 0 or ph.len == 0) return false;
        if (ah.len <= 2 and std.ascii.isUpper(ah[0])) return false;
        if (ph.len <= 2 and std.ascii.isUpper(ph[0])) return false;
        if (std.mem.eql(u8, ah, ph)) return false;
        if (self.uniqueClassIdBySimpleName(ah) == null and self.classIdByFqn(ah) == null) return false;
        if (self.uniqueClassIdBySimpleName(ph) == null and self.classIdByFqn(ph) == null) return false;
        return !self.classIsOrExtends(ah, ph);
    }

    fn erasedHeadProves(
        self: *const Module,
        erased: bool,
        param_ty: TypeRef,
        sh: applicability.ArgShape,
    ) bool {
        if (!erased) return false;
        const arg_ty = sh.ty orelse return false;
        if (arg_ty.nullable and !param_ty.nullable) return false;
        const ah = applicability.simpleName(staticTypeHead(std.mem.trimEnd(u8, arg_ty.name, "?")));
        const ph = applicability.simpleName(staticTypeHead(std.mem.trimEnd(u8, param_ty.name, "?")));
        if (ah.len == 0 or ph.len == 0) return false;
        if (ah.len <= 2 and std.ascii.isUpper(ah[0])) return false;
        return std.mem.eql(u8, ah, ph) or self.classIsOrExtends(ah, ph);
    }

    pub fn memberPromotionProven(
        self: *const Module,
        member_fid: FuncId,
        head: []const u8,
        name: []const u8,
        recv_ty: TypeRef,
        shapes: []const applicability.ArgShape,
        actual_bounds: []const ModuleRegistry.TypeParamBound,
    ) bool {
        mpp_why = "-";
        const mf = self.funcById(member_fid) orelse {
            mpp_why = "no-member-fn";
            return false;
        };
        const m_off: usize = @intFromBool(funcHasImplicitThis(mf));
        if (mf.params.len < m_off + shapes.len) {
            mpp_why = "member-arity";
            return false;
        }
        var member_fully_proven = true;
        // The receiver's instantiation substitutes the owner's own type
        // parameters positionally: `contains(element: E)` on an
        // `Iterable<String>` receiver proves against String. Only the
        // direct-instantiation case (receiver head IS the owner) is
        // taken; projections keep the raw param and the conservative
        // unknown below.
        const owner_tps: []const []const u8 = blk: {
            const ds = self.decl_sigs.get(member_fid.int()) orelse break :blk &.{};
            const oid = ds.enclosing_class orelse break :blk &.{};
            if (oid.int() >= self.classes.items.len) break :blk &.{};
            const ocls = &self.classes.items[oid.int()];
            if (!std.mem.eql(u8, applicability.simpleName(ocls.name), applicability.simpleName(staticTypeHead(std.mem.trimEnd(u8, recv_ty.name, "?")))))
                break :blk &.{};
            break :blk ocls.type_params;
        };
        for (shapes, mf.params[m_off .. m_off + shapes.len]) |sh, p| {
            if (sh.ty == null and sh.literal_kind == null and !sh.is_lambda) {
                mpp_why = "arg-unauthoritative";
                return false;
            }
            if (sh.named != null or sh.is_spread) {
                mpp_why = "named-or-spread";
                return false;
            }
            var param_ty = p.ty;
            var ph = staticTypeHead(std.mem.trimEnd(u8, param_ty.name, "?"));
            if (parseClassTypeParamIdentity(ph)) |ident| ph = ident.param;
            for (owner_tps, 0..) |tp, i| {
                if (std.mem.eql(u8, tp, ph) and i < recv_ty.args.len and
                    recv_ty.args[i].name.len != 0 and
                    !std.mem.eql(u8, recv_ty.args[i].name, "*"))
                {
                    param_ty = recv_ty.args[i];
                    break;
                }
            }
            // Unsubstitutable class-parameter ARGS erase to `*` for the
            // proof: `Collection<E>` under a head-only receiver behaves as
            // `Collection<*>` — the head adjudicates, the parameter proves
            // and refutes nothing (the star-erasure convention). This is
            // what lifts removeAll/addAll/putAll members to the
            // scope-order tier.
            var star_buf: [8]TypeRef = undefined;
            var param_args_erased = false;
            if (param_ty.args.len != 0 and param_ty.args.len <= star_buf.len) {
                var all_tp = true;
                for (param_ty.args) |pa| {
                    var ah = staticTypeHead(std.mem.trimEnd(u8, pa.name, "?"));
                    if (std.mem.startsWith(u8, ah, "out#")) ah = ah["out#".len..];
                    if (std.mem.startsWith(u8, ah, "in#")) ah = ah["in#".len..];
                    var is_tp = parseClassTypeParamIdentity(ah) != null or
                        (ah.len > 0 and ah.len <= 2 and std.ascii.isUpper(ah[0]));
                    if (!is_tp) for (owner_tps) |tp| {
                        if (std.mem.eql(u8, tp, ah)) {
                            is_tp = true;
                            break;
                        }
                    };
                    if (!is_tp) {
                        all_tp = false;
                        break;
                    }
                }
                if (all_tp) {
                    param_args_erased = true;
                    for (0..param_ty.args.len) |i| {
                        star_buf[i] = .{ .name = "*", .nullable = false, .args = &.{} };
                    }
                    param_ty = .{
                        .name = param_ty.name,
                        .nullable = param_ty.nullable,
                        .args = star_buf[0..param_ty.args.len],
                    };
                }
            }
            // Two tiers. A member PROVEN applicable on every argument
            // commits by Kotlin's scope order alone — members outrank
            // extensions, no refutation needed. A member merely
            // NON-refuted (the removeAll/addAll/putAll family, whose
            // `Collection<E>` params stay unknown without a receiver
            // instantiation) still commits, but only when every reachable
            // extension is refuted below.
            // A parameter that is STILL a bare type parameter after the
            // receiver substitution accepts whatever the source passed: the
            // program compiled, so the argument conforms to whatever the
            // instantiation makes it. It is the same star-erasure convention
            // applied one level up — the head adjudicates, the parameter
            // neither proves nor refutes — except that an unprovable
            // parameter must not cost the member its PROOF, or a
            // `map.get(key)` loses to any same-named extension in scope.
            const param_still_tp = blk_tp: {
                var ph2 = staticTypeHead(std.mem.trimEnd(u8, param_ty.name, "?"));
                if (parseClassTypeParamIdentity(ph2)) |ident| ph2 = ident.param;
                if (ph2.len == 0) break :blk_tp false;
                if (self.funcTypeParamIndex(member_fid, ph2) != null) break :blk_tp true;
                for (owner_tps) |tp| {
                    if (std.mem.eql(u8, tp, ph2)) break :blk_tp true;
                }
                break :blk_tp ph2.len <= 2 and std.ascii.isUpper(ph2[0]);
            };
            switch (self.staticArgCompatibility(member_fid, sh, param_ty, actual_bounds)) {
                .incompatible => {
                    if (param_still_tp) continue;
                    mpp_why = "member-arg-refuted";
                    if (runtime.envSetOnce("KLIO_PROMO_NAMES")) {
                        std.debug.print("[promo-pair] {s}.{s} param={s}<{d}> arg={s}<{d}>\n", .{
                            head,
                            name,
                            param_ty.name,
                            param_ty.args.len,
                            if (sh.ty) |t| t.name else "?",
                            if (sh.ty) |t| t.args.len else 0,
                        });
                    }
                    return false;
                },
                .unknown => if (erasedHeadRefutes(self, param_args_erased, param_ty, sh)) {
                    mpp_why = "member-arg-refuted";
                    return false;
                } else if (!param_still_tp and !erasedHeadProves(self, param_args_erased, param_ty, sh)) {
                    if (runtime.envSetOnce("KLIO_PROMO_NAMES")) {
                        std.debug.print("[promo-unknown] {s}.{s} param={s}<{d}> arg={s}<{d}> lit={} lam={}\n", .{
                            head,
                            name,
                            param_ty.name,
                            param_ty.args.len,
                            if (sh.ty) |t| t.name else "?",
                            if (sh.ty) |t| t.args.len else 0,
                            sh.literal_kind != null,
                            sh.is_lambda,
                        });
                    }
                    member_fully_proven = false;
                },
                .compatible => {},
            }
        }
        if (member_fully_proven) return true;
        const chain: []const []const u8 = self.registry.class_super_names.get(head) orelse &.{};
        for (self.funcsBySimpleName(name)) |fid| {
            if (fid.int() == member_fid.int()) continue;
            const f = self.funcById(fid) orelse continue;
            const kind = self.declarationKind(fid, f);
            if (kind != .top_level_extension and kind != .member_extension) continue;
            const ds = self.decl_sigs.get(fid.int()) orelse {
                mpp_why = "ext-no-sig";
                return false;
            };
            const recv_ref = ds.receiver_ty orelse
                (if (f.params.len != 0) f.params[0].ty else continue);
            var r_head = applicability.simpleName(staticTypeHead(std.mem.trimEnd(u8, recv_ref.name, "?")));
            if (std.mem.startsWith(u8, r_head, "out#")) r_head = r_head["out#".len..];
            if (std.mem.startsWith(u8, r_head, "in#")) r_head = r_head["in#".len..];
            const generic_recv = self.funcTypeParamIndex(fid, r_head) != null or
                (r_head.len <= 2 and r_head.len > 0 and std.ascii.isUpper(r_head[0]));
            var reachable = generic_recv or std.mem.eql(u8, r_head, head);
            if (!reachable) {
                for (applicability.builtinSupersOf(head)) |sup| {
                    if (std.mem.eql(u8, r_head, sup)) {
                        reachable = true;
                        break;
                    }
                }
            }
            if (!reachable) {
                for (chain) |sup| {
                    if (std.mem.eql(u8, r_head, applicability.simpleName(staticTypeHead(sup)))) {
                        reachable = true;
                        break;
                    }
                }
            }
            if (!reachable) continue;
            // Arity refutation first: the DeclSig arity counts user args.
            const required: usize = ds.arity.required;
            const total: usize = if (ds.arity.has_vararg) std.math.maxInt(u32) else ds.arity.total;
            if (shapes.len < required or shapes.len > total) continue;
            if (f.params.len < 1 + shapes.len and !ds.arity.has_vararg) continue;
            var refuted = false;
            const n = @min(shapes.len, f.params.len -| 1);
            for (shapes[0..n], f.params[1 .. 1 + n]) |sh, p| {
                if (self.staticArgCompatibility(fid, sh, p.ty, actual_bounds) == .incompatible) {
                    refuted = true;
                    break;
                }
            }
            if (!refuted) {
                mpp_why = "ext-unrefuted";
                if (runtime.envSetOnce("KLIO_PROMO_NAMES")) {
                    std.debug.print("[promo-ext-alive] {s}.{s} ext={s} recv={s}\n", .{
                        head,
                        name,
                        f.fqn,
                        recv_ref.name,
                    });
                }
                return false;
            }
        }
        return true;
    }

    fn recvRefuteOn() bool {
        const S = struct {
            var cached: ?bool = null;
        };
        if (S.cached) |v| return v;
        const on = runtime.envSetOnce("KLIO_RECV_REFUTE");
        S.cached = on;
        return on;
    }

    fn arrayVsCollectionParam(actual_head: []const u8, param_head: []const u8) bool {
        const is_array = std.mem.eql(u8, actual_head, "Array") or
            for ([_][]const u8{
                "BooleanArray", "ByteArray",  "ShortArray", "IntArray",
                "LongArray",    "CharArray",  "FloatArray", "DoubleArray",
                "UByteArray",   "UShortArray", "UIntArray", "ULongArray",
            }) |n| {
                if (std.mem.eql(u8, actual_head, n)) break true;
            } else false;
        if (!is_array) return false;
        for ([_][]const u8{
            "Iterable", "MutableIterable",   "Collection", "MutableCollection",
            "List",     "MutableList",       "Set",        "MutableSet",
            "Sequence",
        }) |n| {
            if (std.mem.eql(u8, param_head, n)) return true;
        }
        return false;
    }

    const StaticAliasHead = struct {
        name: []const u8,
        changed: bool,
        structure_lost: bool,
    };

    fn staticAliasHead(self: *const Module, ty: TypeRef) StaticAliasHead {
        var current = staticTypeHead(ty.name);
        var changed = false;
        var hops: u8 = 0;
        while (hops < 8) : (hops += 1) {
            const next = self.registry.type_aliases.get(current) orelse break;
            const next_head = staticTypeHead(next);
            if (std.mem.eql(u8, current, next_head)) break;
            changed = true;
            current = next_head;
        }
        const still_alias = hops == 8 and self.registry.type_aliases.contains(current);
        return .{
            .name = current,
            .changed = changed,
            // Alias metadata is currently keyed by simple name across the
            // whole module universe, so it cannot prove which same-named
            // package declaration a call-site type denotes.
            .structure_lost = still_alias or changed,
        };
    }

    fn staticBuiltinConcrete(head: []const u8) bool {
        inline for (.{
            "Any",         "Nothing",     "Unit",         "Boolean",   "Char",
            "Byte",        "Short",       "Int",          "Long",      "Float",
            "Double",      "UByte",       "UShort",       "UInt",      "ULong",
            "Array",       "ByteArray",   "ShortArray",   "IntArray",  "LongArray",
            "FloatArray",  "DoubleArray", "BooleanArray", "CharArray", "UByteArray",
            "UShortArray", "UIntArray",   "ULongArray",
        }) |candidate| {
            if (std.mem.eql(u8, head, candidate)) return true;
        }
        return false;
    }

    const StaticBuiltinIdentity = enum {
        no,
        ambiguous,
        yes,
    };

    fn staticBuiltinIdentity(
        self: *const Module,
        ty: TypeRef,
        head: []const u8,
    ) StaticBuiltinIdentity {
        const is_builtin = staticBuiltinConcrete(head) or
            applicability.builtinSupersOf(head).len != 0 or
            std.mem.eql(u8, head, "Number") or
            std.mem.eql(u8, head, "CharSequence") or
            std.mem.eql(u8, head, "Comparable") or
            std.mem.eql(u8, head, "Iterable") or
            std.mem.eql(u8, head, "Collection") or
            std.mem.eql(u8, head, "Sequence");
        if (!is_builtin) return .no;
        const qualified = overrideQualifiedPath(ty) orelse blk: {
            if (std.mem.indexOfScalar(u8, ty.name, '.') != null) {
                break :blk ty.name;
            }
            break :blk null;
        };
        if (qualified) |path| {
            if (std.mem.startsWith(u8, path, "kotlin.") and
                std.mem.eql(u8, applicability.simpleName(path), head)) return .yes;
            return .no;
        }
        if (self.class_fqn_map != null) {
            // Finalized module: lock-free read of the completed cache (see
            // `uniqueClassIdBySimpleName`).
            if (self.unique_simple_cache_n == self.classes.items.len) {
                const info = self.unique_simple_cache.get(head) orelse return .yes;
                return if (info.non_kotlin) .ambiguous else .yes;
            }
        } else if (self.lookup_cache_gpa != null) {
            const mut: *Module = @constCast(self);
            if (mut.topUpUniqueSimpleCache()) {
                const info = mut.unique_simple_cache.get(head) orelse return .yes;
                return if (info.non_kotlin) .ambiguous else .yes;
            } else |_| {}
        }
        for (self.classes.items) |class| {
            if (!std.mem.eql(u8, applicability.simpleName(class.fqn), head) and
                !std.mem.eql(u8, class.name, head)) continue;
            if (!std.mem.eql(u8, class.package, "kotlin") and
                !std.mem.startsWith(u8, class.package, "kotlin.")) return .ambiguous;
        }
        return .yes;
    }

    fn staticTypeClassId(self: *const Module, ty: TypeRef) ?ClassId {
        if (overrideQualifiedPath(ty)) |path| {
            return self.classIdByFqn(path) orelse self.classIdByQualifiedSuffix(path);
        }
        if (std.mem.indexOfScalar(u8, ty.name, '.') != null) {
            return self.classIdByFqn(ty.name) orelse self.classIdByQualifiedSuffix(ty.name);
        }
        return self.uniqueClassIdBySimpleName(staticTypeHead(ty.name));
    }

    fn staticTypesShareClassifier(
        self: *const Module,
        actual: TypeRef,
        declared: TypeRef,
    ) bool {
        const actual_id = self.staticTypeClassId(actual);
        const declared_id = self.staticTypeClassId(declared);
        if (actual_id != null or declared_id != null) {
            return actual_id != null and declared_id != null and
                actual_id.? == declared_id.?;
        }
        const actual_head = staticTypeHead(actual.name);
        const declared_head = staticTypeHead(declared.name);
        if (!std.mem.eql(u8, actual_head, declared_head)) return false;
        return self.staticBuiltinIdentity(actual, actual_head) == .yes and
            self.staticBuiltinIdentity(declared, declared_head) == .yes;
    }

    fn staticBoundProofComplete(
        self: *const Module,
        bound: ModuleRegistry.TypeParamBound,
        bounds: []const ModuleRegistry.TypeParamBound,
        depth: u8,
    ) bool {
        if (!bound.complete or depth >= 64) return false;
        const head = staticTypeHead(bound.bound);
        if (rawBoundNamesDeclaredParam(bounds, bound.bound)) {
            var matched = false;
            for (bounds) |dependent| {
                if (!std.mem.eql(u8, dependent.param, head)) continue;
                matched = true;
                if (!self.staticBoundProofComplete(
                    dependent,
                    bounds,
                    depth + 1,
                )) return false;
            }
            return matched;
        }
        const ty = TypeRef{ .name = bound.bound, .nullable = false, .args = &.{} };
        const alias = self.staticAliasHead(ty);
        if (alias.structure_lost) return false;
        return self.staticBuiltinIdentity(ty, alias.name) == .yes or
            self.staticTypeClassId(ty) != null;
    }

    /// Like `staticBoundProofComplete`, but for DISPROOF: a head-only bound
    /// record still names the one classifier the parameter is bounded by,
    /// and dropped bound ARGUMENTS only narrow a bound — they never add a
    /// supertype. Knowing the head is therefore enough to conclude that a
    /// failed subtype check against a concrete classifier is a real NO.
    fn staticBoundProofHead(
        self: *const Module,
        bound: ModuleRegistry.TypeParamBound,
        bounds: []const ModuleRegistry.TypeParamBound,
        depth: u8,
    ) bool {
        if (!(bound.complete or bound.head_only) or depth >= 64) return false;
        const head = staticTypeHead(bound.bound);
        if (rawBoundNamesDeclaredParam(bounds, bound.bound)) {
            var matched = false;
            for (bounds) |dependent| {
                if (!std.mem.eql(u8, dependent.param, head)) continue;
                matched = true;
                if (!self.staticBoundProofHead(
                    dependent,
                    bounds,
                    depth + 1,
                )) return false;
            }
            return matched;
        }
        const ty = TypeRef{ .name = bound.bound, .nullable = false, .args = &.{} };
        const alias = self.staticAliasHead(ty);
        if (alias.structure_lost) return false;
        return self.staticBuiltinIdentity(ty, alias.name) == .yes or
            self.staticTypeClassId(ty) != null;
    }

    /// `staticTypeProofComplete` for the NEGATIVE direction only: consumers
    /// use it to turn a failed subtype check into `.incompatible`. A declared
    /// type parameter whose bound names its classifier (`T : Comparable<T>`,
    /// recorded head-only) is fully known for that purpose — kotlinc rules
    /// `Array<out Double>.minOrNull` out for an `Array<T>` receiver at the
    /// declaration, whatever T is later instantiated to. Gated by
    /// `KLIO_TP_DISPROOF` for single-binary A/B.
    fn staticTypeDisproofComplete(
        self: *const Module,
        raw_ty: TypeRef,
        bounds: []const ModuleRegistry.TypeParamBound,
    ) bool {
        const relaxed = if (std.c.getenv("KLIO_TP_DISPROOF")) |v|
            !std.mem.eql(u8, std.mem.span(v), "0")
        else
            true;
        if (!relaxed) return self.staticTypeProofComplete(raw_ty, bounds);
        const projected = projectionType(raw_ty);
        if (projected.star) return false;
        const ty = projected.ty;
        const head = staticTypeHead(ty.name);
        if (head.len == 0 or ty.name[0] == '#') return false;
        if (typeRefIsDeclaredParam(bounds, ty)) {
            for (bounds) |bound| {
                if (std.mem.eql(u8, bound.param, head) and
                    !self.staticBoundProofHead(bound, bounds, 0)) return false;
            }
            return true;
        }
        const alias = self.staticAliasHead(ty);
        if (alias.structure_lost) return false;
        const identity = self.staticBuiltinIdentity(ty, alias.name);
        if (identity != .yes and self.staticTypeClassId(ty) == null) return false;
        for (overrideArgs(ty)) |arg| {
            if (!self.staticTypeDisproofComplete(arg, bounds)) return false;
        }
        return true;
    }

    fn staticReceiverCompatibility(
        self: *const Module,
        fid: ?FuncId,
        receiver: TypeRef,
        param: TypeRef,
    ) StaticCompatibility {
        const actual_alias = self.staticAliasHead(receiver);
        const declared_alias = self.staticAliasHead(param);
        if (actual_alias.structure_lost or declared_alias.structure_lost) return .unknown;
        const actual = actual_alias.name;
        const declared = declared_alias.name;
        if (actual.len == 0 or declared.len == 0) return .unknown;
        // Exact generic inference needs one substitution environment shared
        // by the receiver and every value argument. Until that environment is
        // part of this proof, a declaration type parameter stays unresolved.
        if (fid) |decl_id| {
            if (self.staticDeclTypeParam(decl_id, param)) return .unknown;
        }
        if (receiver.nullable and !param.nullable) return .incompatible;
        if (std.mem.eql(u8, actual, "Nothing") and receiver.nullable) {
            return if (param.nullable) .unknown else .incompatible;
        }
        if (std.mem.eql(u8, actual, "Nothing")) return .compatible;
        if (std.mem.eql(u8, declared, "Any")) return switch (self.staticBuiltinIdentity(param, declared)) {
            .yes => .compatible,
            .ambiguous => .unknown,
            .no => .incompatible,
        };
        if (std.mem.eql(u8, actual, declared)) {
            const actual_qualified = std.mem.indexOfScalar(u8, receiver.name, '.') != null;
            const declared_qualified = std.mem.indexOfScalar(u8, param.name, '.') != null;
            if (!actual_alias.changed and !declared_alias.changed and
                actual_qualified and declared_qualified and
                !std.mem.eql(u8, receiver.name, param.name)) return .incompatible;
            const actual_builtin = self.staticBuiltinIdentity(receiver, actual);
            const declared_builtin = self.staticBuiltinIdentity(param, declared);
            if (actual_builtin == .ambiguous or declared_builtin == .ambiguous) {
                return .unknown;
            }
            if ((actual_builtin == .yes) != (declared_builtin == .yes)) {
                return .incompatible;
            }
            if (actual_builtin == .no) {
                const actual_id = self.staticTypeClassId(receiver) orelse return .unknown;
                const declared_id = self.staticTypeClassId(param) orelse return .unknown;
                if (actual_id != declared_id) return .incompatible;
            }
            if (staticTypeArgsEqual(receiver.args, param.args)) return .compatible;
            // Unequal arguments are incompatible when at least one pair is
            // provably disjoint in both subtype directions. This remains
            // valid for invariant, covariant, and contravariant classifiers;
            // one-way compatibility still needs declaration-site variance
            // and therefore stays unknown.
            if (receiver.args.len == param.args.len and receiver.args.len != 0) {
                for (receiver.args, param.args) |actual_arg, declared_arg| {
                    if (actual_arg.eql(declared_arg)) continue;
                    if (actual_arg.name.len == 0 or declared_arg.name.len == 0 or
                        actual_arg.name[0] == '#' or declared_arg.name[0] == '#' or
                        std.mem.eql(u8, actual_arg.name, "*") or
                        std.mem.eql(u8, declared_arg.name, "*")) return .unknown;
                    if (self.staticReceiverCompatibility(null, actual_arg, declared_arg) == .incompatible and
                        self.staticReceiverCompatibility(null, declared_arg, actual_arg) == .incompatible)
                    {
                        return .incompatible;
                    }
                }
            }
            // Variance and type-parameter substitution belong to the
            // declared classifier. Other unequal generic arguments cannot
            // prove compatibility without both.
            return .unknown;
        }
        if (param.args.len != 0) {
            // Builtin hierarchy with matching arguments: a
            // `MutableList<Int>` receiver satisfies a `List<Int>` bound
            // through the table below, and equal args need no variance
            // reasoning. Without this the non-star fallthrough returned
            // `.unknown`, which refuted lexical local extensions on
            // declared builtin receivers (`val l = mutableListOf<Int>()`
            // then `fun List<Int>.f()` never bound).
            if (self.staticBuiltinIdentity(receiver, actual) == .yes and
                staticBuiltinArgsNonRefuting(receiver.args, param.args))
            {
                for (applicability.builtinSupersOf(actual)) |candidate| {
                    if (std.mem.eql(u8, candidate, declared)) return .compatible;
                }
            }
            // All-star arguments prove and refute nothing (the star-erasure
            // convention): `List<String>` against `Collection<*>`
            // adjudicates by HEAD alone below.
            var all_star = true;
            for (param.args) |pa| {
                if (!std.mem.eql(u8, pa.name, "*")) {
                    all_star = false;
                    break;
                }
            }
            if (!all_star) return .unknown;
        }
        if (self.staticTypeClassId(receiver)) |actual_id| {
            // An unqualified declared head means whatever the DECLARATION's
            // own file scope says (a test file's private `Modifier` beside
            // the shipped androidx one), so the decl-file resolution is the
            // authoritative one; the module-unique lookup is the fallback
            // for declarations with no recorded source.
            const decl_scoped: ?ClassId = blk: {
                if (std.mem.indexOfScalar(u8, param.name, '.') != null) break :blk null;
                const decl_id = fid orelse break :blk null;
                const decl_source = self.decl_span.get(decl_id.int()) orelse break :blk null;
                const decl_pkg = if (self.funcById(decl_id)) |df| df.package else "";
                // Kotlin scope order: an exact import outranks the
                // declaring package. The same-package FQN probe is what
                // reaches a collision-mangled file-private classifier —
                // its `class_index` entry carries the `$fN` mangle, so the
                // simple-name candidates `classIdIndexed` ranks never
                // contain it, but its FQN stays clean.
                if (self.classIdExactImport(declared, decl_source.file)) |cid| break :blk cid;
                if (decl_pkg.len != 0 and declared.len < 200) {
                    var fqn_buf: [256]u8 = undefined;
                    if (std.fmt.bufPrint(&fqn_buf, "{s}.{s}", .{ decl_pkg, declared })) |fqn| {
                        if (self.classIdByFqn(fqn)) |cid| break :blk cid;
                    } else |_| {}
                }
                break :blk self.classIdIndexed(declared, decl_pkg, decl_source.file);
            };
            if (bargTraceEnv() != null) {
                const afqn = if (idGet(Class, self.classes.items, actual_id.int())) |c| c.fqn else "?";
                const dfqn = if (decl_scoped) |d| (if (idGet(Class, self.classes.items, d.int())) |c| c.fqn else "?") else "-";
                std.debug.print("[barg-ids] actual={s}->{d}({s}) declared={s} decl_scoped={?d}({s}) unique={?d} fid={?d}\n", .{ receiver.name, actual_id.int(), afqn, param.name, if (decl_scoped) |d| d.int() else null, dfqn, if (self.staticTypeClassId(param)) |d| d.int() else null, if (fid) |f| f.int() else null });
            }
            if (decl_scoped orelse self.staticTypeClassId(param)) |did| {
                if (self.classIdIsOrExtends(actual_id, did)) return .compatible;
            }
        }
        const actual_builtin = self.staticBuiltinIdentity(receiver, actual);
        if (actual_builtin == .yes) {
            for (applicability.builtinSupersOf(actual)) |candidate| {
                if (std.mem.eql(u8, candidate, declared)) return .compatible;
            }
        }
        if (actual_builtin == .ambiguous) return .unknown;
        // The registered supertype chain is evidence the hardcoded builtin
        // table lacks: `MutableCollection` IS a `Collection` through the
        // shipped source hierarchy, and the blind refutation below held the
        // whole removeAll/addAll member family.
        if (evidenceSubtypeCb(@ptrCast(@constCast(self)), actual, declared)) {
            return .compatible;
        }
        if (!(actual_builtin == .yes and staticBuiltinConcrete(actual)) and
            applicability.builtinSupersOf(actual).len == 0 and
            self.staticTypeClassId(receiver) == null and
            !self.registry.class_super_names.contains(actual)) return .unknown;
        return .incompatible;
    }

    /// Compare two concrete call-site types with the same identity-aware,
    /// nullability-aware proof used by member and extension resolution.
    /// Declaration-owned type parameters are supplied by the caller as
    /// unknown type heads and therefore remain conservative.
    pub fn staticTypeCompatibility(
        self: *const Module,
        actual: TypeRef,
        declared: TypeRef,
    ) StaticCompatibility {
        return self.staticReceiverCompatibility(null, actual, declared);
    }

    fn staticAliasType(
        self: *const Module,
        allocator: Allocator,
        ty: TypeRef,
        depth: u8,
    ) Allocator.Error!TypeRef {
        if (depth >= 16) return ty;
        const alias_name = overrideQualifiedPath(ty) orelse staticTypeHead(ty.name);
        const shape = self.registry.type_alias_types.get(alias_name) orelse return ty;
        const supplied_args = overrideArgs(ty);
        if (shape.type_params.len != supplied_args.len) {
            if (shape.type_params.len != 0) return ty;
        }
        const bindings = try allocator.alloc(TypeBinding, shape.type_params.len);
        for (shape.type_params, 0..) |param, index| {
            bindings[index] = .{ .name = param, .ty = supplied_args[index] };
        }
        var expanded = try substituteType(allocator, shape.target, bindings);
        expanded.nullable = expanded.nullable or ty.nullable;
        return self.staticAliasType(allocator, expanded, depth + 1);
    }

    fn scopedTypeAliasFqn(
        self: *const Module,
        allocator: Allocator,
        ty: TypeRef,
        file: ?FileId,
        package: []const u8,
    ) Allocator.Error!?[]const u8 {
        if (overrideQualifiedPath(ty)) |path| {
            return if (self.registry.type_alias_types.contains(path)) path else null;
        }
        const name = staticTypeHead(ty.name);
        if (std.mem.indexOfScalar(u8, ty.name, '.') != null and
            self.registry.type_alias_types.contains(ty.name))
        {
            return ty.name;
        }
        if (file) |source_file| {
            var imported: ?[]const u8 = null;
            for (self.importAliasPathsIn(source_file, name)) |path| {
                if (!self.registry.type_alias_types.contains(path.fqn)) continue;
                if (imported != null and !std.mem.eql(u8, imported.?, path.fqn)) {
                    return null;
                }
                imported = path.fqn;
            }
            if (imported) |path| return path;
        }
        if (package.len != 0) {
            const own = try std.fmt.allocPrint(
                allocator,
                "{s}.{s}",
                .{ package, name },
            );
            defer allocator.free(own);
            if (self.registry.type_alias_types.getKey(own)) |key| return key;
        } else if (self.registry.type_alias_types.getKey(name)) |key| {
            // Default-package aliases register under their bare name — the
            // dotted own-package probe above can never find them.
            return key;
        }
        if (file) |source_file| {
            var wildcard: ?[]const u8 = null;
            if (self.registry.import_wildcards.get(source_file)) |packages| {
                for (packages.items) |imported_package| {
                    const candidate = try std.fmt.allocPrint(
                        allocator,
                        "{s}.{s}",
                        .{ imported_package, name },
                    );
                    defer allocator.free(candidate);
                    const key = self.registry.type_alias_types.getKey(candidate) orelse
                        continue;
                    if (wildcard != null and !std.mem.eql(u8, wildcard.?, key)) {
                        return null;
                    }
                    wildcard = key;
                }
            }
            if (wildcard) |path| return path;
        }
        var default_import: ?[]const u8 = null;
        for (default_import_packages) |imported_package| {
            const candidate = try std.fmt.allocPrint(
                allocator,
                "{s}.{s}",
                .{ imported_package, name },
            );
            defer allocator.free(candidate);
            const key = self.registry.type_alias_types.getKey(candidate) orelse
                continue;
            if (default_import != null and
                !std.mem.eql(u8, default_import.?, key))
            {
                return null;
            }
            default_import = key;
        }
        return default_import;
    }

    /// Expand a source typealias using the imports and package of its exact
    /// reference site. The FQN-keyed alias registry keeps a same-simple-name
    /// alias from another package out of the proof.
    pub fn resolveTypeAliasAt(
        self: *const Module,
        allocator: Allocator,
        ty: TypeRef,
        file: ?FileId,
        package: []const u8,
    ) Allocator.Error!TypeRef {
        const alias_fqn = (try self.scopedTypeAliasFqn(
            allocator,
            ty,
            file,
            package,
        )) orelse
            return ty;
        const source_args = overrideArgs(ty);
        const args = try allocator.alloc(TypeRef, source_args.len + 1);
        @memcpy(args[0..source_args.len], source_args);
        args[source_args.len] = .{
            .name = try std.fmt.allocPrint(allocator, "#qual:{s}", .{alias_fqn}),
            .nullable = false,
            .args = &.{},
        };
        var qualified = ty;
        qualified.args = args;
        return self.staticAliasType(allocator, qualified, 0);
    }

    fn projectionType(ty: TypeRef) struct { variance: ?ast.Variance, ty: TypeRef, star: bool } {
        if (std.mem.eql(u8, ty.name, "*")) {
            return .{ .variance = null, .ty = ty, .star = true };
        }
        var out = ty;
        if (std.mem.startsWith(u8, out.name, "out#")) {
            out.name = out.name["out#".len..];
            return .{ .variance = .Out, .ty = out, .star = false };
        }
        if (std.mem.startsWith(u8, out.name, "in#")) {
            out.name = out.name["in#".len..];
            return .{ .variance = .In, .ty = out, .star = false };
        }
        return .{ .variance = null, .ty = out, .star = false };
    }

    fn staticTypeIsSubtypeInner(
        self: *const Module,
        allocator: Allocator,
        raw_actual: TypeRef,
        raw_declared: TypeRef,
        actual_bounds: []const ModuleRegistry.TypeParamBound,
        depth: u8,
    ) Allocator.Error!bool {
        if (depth >= 64) return false;
        const actual = try self.staticAliasType(allocator, raw_actual, 0);
        const declared = try self.staticAliasType(allocator, raw_declared, 0);
        if (actual.nullable and !declared.nullable) return false;
        const actual_head = staticTypeHead(actual.name);
        const declared_head = staticTypeHead(declared.name);
        if (actual_head.len == 0 or declared_head.len == 0) return false;
        if (actual.eql(declared)) {
            if (typeRefIsDeclaredParam(actual_bounds, actual) and
                typeRefIsDeclaredParam(actual_bounds, declared) or
                self.staticTypesShareClassifier(actual, declared)) return true;
        }
        var saw_actual_bound = false;
        if (typeRefIsDeclaredParam(actual_bounds, actual)) {
            for (actual_bounds) |bound| {
                if (!std.mem.eql(u8, bound.param, actual_head)) continue;
                saw_actual_bound = true;
                if (!self.staticBoundProofComplete(bound, actual_bounds, 0)) continue;
                if (try self.staticTypeIsSubtypeInner(
                    allocator,
                    .{ .name = bound.bound, .nullable = false, .args = &.{} },
                    declared,
                    actual_bounds,
                    depth + 1,
                )) return true;
            }
        }
        if (saw_actual_bound) return false;
        if (typeRefIsDeclaredParam(actual_bounds, declared)) return false;
        if (std.mem.eql(u8, actual_head, "Nothing")) return !actual.nullable or declared.nullable;
        if (std.mem.eql(u8, declared_head, "Any")) {
            return self.staticBuiltinIdentity(declared, declared_head) == .yes;
        }

        const actual_id = self.staticTypeClassId(actual);
        const declared_id = self.staticTypeClassId(declared);
        const same_classifier = self.staticTypesShareClassifier(actual, declared);
        if (same_classifier) {
            if (actual.nullable and !declared.nullable) return false;
            const actual_args = overrideArgs(actual);
            const declared_args = overrideArgs(declared);
            if (declared_args.len == 0) return true;
            // An argless actual on the SAME classifier is an erased
            // derivation (`mutableListOf<Int>()` derives `MutableList`
            // with the call-site argument dropped), not proof of a
            // different instantiation — unknown arguments must not
            // disprove, per this judgment's own convention for
            // statically unresolvable evidence.
            if (actual_args.len == 0) return true;
            if (actual_args.len != declared_args.len) return false;
            const class = if (declared_id) |id|
                (if (id.int() < self.classes.items.len) &self.classes.items[id.int()] else null)
            else
                null;
            for (actual_args, declared_args, 0..) |raw_actual_arg, raw_declared_arg, index| {
                const actual_arg = projectionType(raw_actual_arg);
                const declared_arg = projectionType(raw_declared_arg);
                if (declared_arg.star) continue;
                if (actual_arg.star) return false;
                const declaration_variance = if (class) |c|
                    (if (index < c.type_param_variance.len)
                        c.type_param_variance[index]
                    else
                        .Invariant)
                else
                    .Invariant;
                if (actual_arg.variance != null) {
                    const redundant = declaration_variance != .Invariant and
                        actual_arg.variance.? == declaration_variance;
                    const same_projection = declared_arg.variance != null and
                        actual_arg.variance.? == declared_arg.variance.?;
                    if (!redundant and !same_projection) return false;
                }
                const variance = declared_arg.variance orelse
                    declaration_variance;
                const fits = switch (variance) {
                    .Invariant => actual_arg.ty.eql(declared_arg.ty),
                    .Out => try self.staticTypeIsSubtypeInner(
                        allocator,
                        actual_arg.ty,
                        declared_arg.ty,
                        actual_bounds,
                        depth + 1,
                    ),
                    .In => try self.staticTypeIsSubtypeInner(
                        allocator,
                        declared_arg.ty,
                        actual_arg.ty,
                        actual_bounds,
                        depth + 1,
                    ),
                };
                if (!fits) return false;
            }
            return true;
        }

        // The builtin collection hierarchy adjudicates before the module
        // class walk: the stdlib pack's List/MutableList classes carry
        // ids whose `classIdIsOrExtends` rows do not encode the builtin
        // subinterface edges, so the walk below refuted
        // `MutableList <: List<Int>` and dropped lexical local
        // extensions on declared builtin receivers. Equal arguments need
        // no variance reasoning; an argless actual is an erased
        // derivation and must not disprove.
        if (self.staticBuiltinIdentity(actual, actual_head) == .yes and
            staticBuiltinArgsNonRefuting(overrideArgs(actual), overrideArgs(declared)))
        {
            for (applicability.builtinSupersOf(actual_head)) |candidate| {
                if (std.mem.eql(u8, candidate, declared_head)) return true;
            }
        }

        if (actual_id) |sub_id| {
            if (declared_id) |super_id| {
                if (!self.classIdIsOrExtends(sub_id, super_id)) return false;
                if (sub_id.int() >= self.classes.items.len or
                    super_id.int() >= self.classes.items.len) return false;
                const sub = &self.classes.items[sub_id.int()];
                const identity = try allocator.alloc(TypeBinding, sub.type_params.len * 2);
                for (sub.type_params, 0..) |param, index| {
                    const identity_name = try classTypeParamIdentity(
                        allocator,
                        sub_id,
                        param,
                    );
                    const actual_ty = if (index < actual.args.len)
                        actual.args[index]
                    else
                        TypeRef{ .name = identity_name, .nullable = false, .args = &.{} };
                    identity[index * 2] = .{ .name = param, .ty = actual_ty };
                    identity[index * 2 + 1] = .{ .name = identity_name, .ty = actual_ty };
                }
                const inherited = (try self.ancestorBindings(
                    allocator,
                    sub_id,
                    super_id,
                    identity,
                    0,
                )) orelse return false;
                const super_class = &self.classes.items[super_id.int()];
                const args = try allocator.alloc(TypeRef, super_class.type_params.len);
                for (super_class.type_params, 0..) |param, index| {
                    const identity_name = try classTypeParamIdentity(
                        allocator,
                        super_id,
                        param,
                    );
                    args[index] = bindingType(inherited, identity_name) orelse
                        .{ .name = identity_name, .nullable = false, .args = &.{} };
                }
                return self.staticTypeIsSubtypeInner(
                    allocator,
                    .{ .name = super_class.fqn, .nullable = actual.nullable, .args = args },
                    declared,
                    actual_bounds,
                    depth + 1,
                );
            }
        }
        return self.staticReceiverCompatibility(null, actual, declared) == .compatible;
    }

    /// Complete proof used to decide whether a statically typed receiver can
    /// bind a lexical local extension. Unknown evidence is not applicability.
    pub fn staticTypeIsSubtype(
        self: *const Module,
        allocator: Allocator,
        actual: TypeRef,
        declared: TypeRef,
    ) Allocator.Error!bool {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        return self.staticTypeIsSubtypeInner(arena.allocator(), actual, declared, &.{}, 0);
    }

    /// Whether the builtin-hierarchy escapes may adjudicate by HEAD:
    /// every actual argument equals its declared counterpart, or is a
    /// bare unresolved type parameter (`MutableList<T>` — a factory
    /// return the deriver did not substitute; per the judgment's
    /// convention, statically unresolvable evidence must not disprove),
    /// or the actual is an erased argless derivation.
    fn staticBuiltinArgsNonRefuting(actual_args: []const TypeRef, declared_args: []const TypeRef) bool {
        if (actual_args.len == 0) return true;
        if (actual_args.len != declared_args.len) return false;
        for (actual_args, declared_args) |a, d| {
            if (a.eql(d)) continue;
            const h = staticTypeHead(a.name);
            const bare_param = h.len >= 1 and h.len <= 2 and
                std.ascii.isUpper(h[0]) and a.args.len == 0 and
                std.mem.indexOfScalar(u8, a.name, '.') == null;
            if (!bare_param) return false;
        }
        return true;
    }

    pub fn staticTypeIsSubtypeWithBounds(
        self: *const Module,
        allocator: Allocator,
        actual: TypeRef,
        declared: TypeRef,
        actual_bounds: []const ModuleRegistry.TypeParamBound,
    ) Allocator.Error!bool {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        return self.staticTypeIsSubtypeInner(
            arena.allocator(),
            actual,
            declared,
            actual_bounds,
            0,
        );
    }

    fn isDeclaredTypeParam(
        params: []const ModuleRegistry.TypeParamBound,
        name: []const u8,
    ) bool {
        for (params) |param| {
            if (std.mem.eql(u8, param.param, name)) return true;
        }
        return false;
    }

    fn rawBoundNamesDeclaredParam(
        params: []const ModuleRegistry.TypeParamBound,
        bound: []const u8,
    ) bool {
        if (std.mem.indexOfScalar(u8, bound, '.') != null or
            std.mem.startsWith(u8, bound, "#qual:")) return false;
        return isDeclaredTypeParam(params, staticTypeHead(bound));
    }

    fn typeRefIsDeclaredParam(
        params: []const ModuleRegistry.TypeParamBound,
        ty: TypeRef,
    ) bool {
        if (overrideQualifiedPath(ty) != null or
            std.mem.indexOfScalar(u8, ty.name, '.') != null) return false;
        return isDeclaredTypeParam(params, staticTypeHead(ty.name));
    }

    fn staticTypeProofComplete(
        self: *const Module,
        raw_ty: TypeRef,
        bounds: []const ModuleRegistry.TypeParamBound,
    ) bool {
        const projected = projectionType(raw_ty);
        if (projected.star) return false;
        const ty = projected.ty;
        const head = staticTypeHead(ty.name);
        if (head.len == 0 or ty.name[0] == '#') return false;
        if (typeRefIsDeclaredParam(bounds, ty)) {
            for (bounds) |bound| {
                if (std.mem.eql(u8, bound.param, head) and
                    !self.staticBoundProofComplete(bound, bounds, 0)) return false;
            }
            return true;
        }
        const alias = self.staticAliasHead(ty);
        if (alias.structure_lost) return false;
        const identity = self.staticBuiltinIdentity(ty, alias.name);
        if (identity != .yes and self.staticTypeClassId(ty) == null) return false;
        for (overrideArgs(ty)) |arg| {
            if (!self.staticTypeProofComplete(arg, bounds)) return false;
        }
        return true;
    }

    fn bindReceiverTypeParams(
        self: *const Module,
        allocator: Allocator,
        raw_actual: TypeRef,
        raw_pattern: TypeRef,
        params: []const ModuleRegistry.TypeParamBound,
        bindings: *std.ArrayList(TypeBinding),
        depth: u8,
    ) Allocator.Error!bool {
        if (depth >= 64) return false;
        const actual_projection = projectionType(try self.staticAliasType(allocator, raw_actual, 0));
        const pattern_projection = projectionType(try self.staticAliasType(allocator, raw_pattern, 0));
        if (actual_projection.star or pattern_projection.star) return pattern_projection.star;
        const actual = actual_projection.ty;
        const pattern = pattern_projection.ty;
        if (typeRefIsDeclaredParam(params, pattern)) {
            if (bindingType(bindings.items, staticTypeHead(pattern.name))) |bound| {
                return bound.eql(actual);
            }
            try bindings.append(allocator, .{
                .name = staticTypeHead(pattern.name),
                .ty = actual,
            });
            return true;
        }
        const actual_id = self.staticTypeClassId(actual);
        const pattern_id = self.staticTypeClassId(pattern);
        const same_classifier = self.staticTypesShareClassifier(actual, pattern);
        if (!same_classifier and actual_id != null and pattern_id != null and
            self.classIdIsOrExtends(actual_id.?, pattern_id.?))
        {
            const actual_class = &self.classes.items[actual_id.?.int()];
            const identity = try allocator.alloc(TypeBinding, actual_class.type_params.len * 2);
            for (actual_class.type_params, 0..) |param, i| {
                const identity_name = try classTypeParamIdentity(
                    allocator,
                    actual_id.?,
                    param,
                );
                const actual_ty = if (i < overrideArgs(actual).len)
                    overrideArgs(actual)[i]
                else
                    TypeRef{ .name = identity_name, .nullable = false, .args = &.{} };
                identity[i * 2] = .{ .name = param, .ty = actual_ty };
                identity[i * 2 + 1] = .{ .name = identity_name, .ty = actual_ty };
            }
            const inherited = (try self.ancestorBindings(
                allocator,
                actual_id.?,
                pattern_id.?,
                identity,
                0,
            )) orelse return false;
            const pattern_class = &self.classes.items[pattern_id.?.int()];
            const projected_args = try allocator.alloc(TypeRef, pattern_class.type_params.len);
            for (pattern_class.type_params, 0..) |param, i| {
                const identity_name = try classTypeParamIdentity(
                    allocator,
                    pattern_id.?,
                    param,
                );
                projected_args[i] = bindingType(inherited, identity_name) orelse
                    .{ .name = identity_name, .nullable = false, .args = &.{} };
            }
            return self.bindReceiverTypeParams(
                allocator,
                .{
                    .name = pattern_class.fqn,
                    .nullable = actual.nullable,
                    .args = projected_args,
                },
                pattern,
                params,
                bindings,
                depth + 1,
            );
        }
        if (!same_classifier or actual.nullable and !pattern.nullable) return false;
        const actual_args = overrideArgs(actual);
        const pattern_args = overrideArgs(pattern);
        if (actual_args.len != pattern_args.len) return pattern_args.len == 0;
        for (actual_args, pattern_args) |actual_arg, pattern_arg| {
            if (!try self.bindReceiverTypeParams(
                allocator,
                actual_arg,
                pattern_arg,
                params,
                bindings,
                depth + 1,
            )) return false;
        }
        return true;
    }

    /// Applicability for a generic lexical extension receiver. The receiver
    /// pattern first binds the local declaration's type parameters, validates
    /// their upper bounds, then enters the ordinary subtype proof with the
    /// enclosing body's type-parameter bounds.
    pub fn staticGenericReceiverApplicable(
        self: *const Module,
        allocator: Allocator,
        actual: TypeRef,
        pattern: TypeRef,
        declared_params: []const ModuleRegistry.TypeParamBound,
        actual_bounds: []const ModuleRegistry.TypeParamBound,
    ) Allocator.Error!bool {
        return self.staticGenericReceiverApplicableMode(allocator, actual, pattern, declared_params, actual_bounds, .prove);
    }

    /// Could-apply variant: a bound whose recorded form is INCOMPLETE (a
    /// head-only `Comparable` standing in for `Comparable<T>`) does not
    /// refute — kotlinc already accepted the declaration, and for a LOCAL
    /// extension nothing else can serve the call, so an unprovable bound
    /// must not make the sole candidate vanish. Prove callers keep
    /// declining on incomplete bounds through the wrapper above.
    pub fn staticGenericReceiverCouldApply(
        self: *const Module,
        allocator: Allocator,
        actual: TypeRef,
        pattern: TypeRef,
        declared_params: []const ModuleRegistry.TypeParamBound,
        actual_bounds: []const ModuleRegistry.TypeParamBound,
    ) Allocator.Error!bool {
        return self.staticGenericReceiverApplicableMode(allocator, actual, pattern, declared_params, actual_bounds, .could_apply);
    }

    fn staticGenericReceiverApplicableMode(
        self: *const Module,
        allocator: Allocator,
        actual: TypeRef,
        pattern: TypeRef,
        declared_params: []const ModuleRegistry.TypeParamBound,
        actual_bounds: []const ModuleRegistry.TypeParamBound,
        mode: enum { prove, could_apply },
    ) Allocator.Error!bool {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var bindings: std.ArrayList(TypeBinding) = .empty;
        const gra_trace = blk: {
            const w = std.c.getenv("KLIO_GRA_TRACE") orelse break :blk false;
            break :blk std.mem.eql(u8, std.mem.span(w), staticTypeHead(actual.name));
        };
        // The HEADS must relate before argument binding proves anything: a
        // `Sequence<T>` receiver pattern never applies to an
        // `Iterable<String>` actual — kotlinc drops the candidate outright —
        // and binding `T := String` head-blind committed
        // `kotlin.sequences.minus` for an Iterable-typed receiver. A pattern
        // head that is itself one of the declaration's parameters keeps the
        // binding walk as the authority.
        {
            const pat_head = applicability.simpleName(staticTypeHead(std.mem.trimEnd(u8, pattern.name, "?")));
            var pat_is_param = false;
            for (declared_params) |dp| {
                if (std.mem.eql(u8, dp.param, pat_head)) {
                    pat_is_param = true;
                    break;
                }
            }
            if (!pat_is_param) {
                const act_head = applicability.simpleName(staticTypeHead(std.mem.trimEnd(u8, actual.name, "?")));
                if (act_head.len != 0 and pat_head.len != 0 and
                    !std.mem.eql(u8, act_head, pat_head))
                {
                    var act_erased = actual;
                    act_erased.args = &.{};
                    var pat_erased = pattern;
                    pat_erased.args = &.{};
                    const act_id = self.staticTypeClassId(act_erased);
                    const pat_id = self.staticTypeClassId(pat_erased);
                    const unrelated = if (act_id != null and pat_id != null)
                        !self.classIdIsOrExtends(act_id.?, pat_id.?)
                    else
                        self.staticBuiltinIdentity(act_erased, act_head) == .yes and
                            self.staticBuiltinIdentity(pat_erased, pat_head) == .yes and
                            !evidenceSubtypeCb(@ptrCast(@constCast(self)), act_head, pat_head);
                    if (unrelated) {
                        if (gra_trace) std.debug.print("[gra] {s} vs {s}: head unrelated\n", .{ actual.name, pattern.name });
                        return false;
                    }
                }
            }
        }
        // A bare actual HEAD whose class relates to the pattern carries no
        // arguments to bind the pattern's parameters against. It cannot
        // DISPROVE the candidate — the head relation already held above —
        // so the lenient mode keeps it and the runtime receiver decides.
        // Refusing here turned a derived-but-argless receiver record into a
        // dropped local extension and a runtime member miss.
        if (mode == .could_apply and actual.args.len == 0 and
            overrideArgs(actual).len == 0 and pattern.args.len != 0)
        {
            if (gra_trace) std.debug.print("[gra] {s} vs {s}: bare actual head, could apply\n", .{ actual.name, pattern.name });
            return true;
        }
        if (!try self.bindReceiverTypeParams(
            a,
            actual,
            pattern,
            declared_params,
            &bindings,
            0,
        )) {
            if (gra_trace) {
                std.debug.print("[gra] {s} vs {s}: bind FAILED act_args=", .{ actual.name, pattern.name });
                for (actual.args) |aa| std.debug.print("{s},", .{aa.name});
                std.debug.print(" pat_args=", .{});
                for (pattern.args) |pa| std.debug.print("{s},", .{pa.name});
                std.debug.print("\n", .{});
            }
            return false;
        }
        if (gra_trace) {
            std.debug.print("[gra] {s} vs {s}: bound n={d}", .{ actual.name, pattern.name, bindings.items.len });
            for (bindings.items) |bd| std.debug.print(" {s}:={s}", .{ bd.name, bd.ty.name });
            std.debug.print(" params={d}\n", .{declared_params.len});
        }
        for (declared_params) |param| {
            // The pattern head's own parameter IS the receiver: a missing
            // binding entry must not silently skip its bound check, or a
            // `where`-bounded receiver (`T.observe() where T : Node`)
            // accepts any receiver at all.
            const bound_actual = bindingType(bindings.items, param.param) orelse
                (if (std.mem.eql(u8, param.param, staticTypeHead(pattern.name)))
                    actual
                else
                    continue);
            if (gra_trace) std.debug.print("[gra]  param {s}<:{s} complete={} actual={s}\n", .{ param.param, param.bound, param.complete, bound_actual.name });
            if (!self.staticBoundProofComplete(param, declared_params, 0)) {
                if (mode == .could_apply) continue;
                return false;
            }
            const dependent_bound = rawBoundNamesDeclaredParam(
                declared_params,
                param.bound,
            );
            if (!dependent_bound and
                std.mem.eql(u8, staticTypeHead(param.bound), "Any") and
                self.staticBuiltinIdentity(
                    .{ .name = param.bound, .nullable = false, .args = &.{} },
                    "Any",
                ) == .yes)
            {
                continue;
            }
            // A dependent bound whose referenced parameter has NO receiver
            // binding constrains nothing here: in `<S, T : S>` on an
            // `Iterable<T>` receiver, `S` appears only in value-parameter
            // and return positions, so inference chooses it at the call
            // (`S := T` always satisfies `T : S`), and kotlinc keeps the
            // candidate — `runningReduce` on an `Iterable<String>` receiver
            // must not vanish. `S`'s own bounds get their own loop entry.
            const required_bound = if (dependent_bound)
                bindingType(bindings.items, staticTypeHead(param.bound)) orelse
                    continue
            else
                TypeRef{ .name = param.bound, .nullable = false, .args = &.{} };
            if (!try self.staticTypeIsSubtypeInner(
                a,
                bound_actual,
                required_bound,
                actual_bounds,
                0,
            )) return false;
        }
        const substituted = try substituteType(a, pattern, bindings.items);
        return self.staticTypeIsSubtypeInner(a, actual, substituted, actual_bounds, 0);
    }

    /// Diagnostic: the last route staticArgCompatibility answered through,
    /// for the rex-arg row. Set on every return path below.
    threadlocal var sac_route: []const u8 = "-";

    fn staticArgCompatibility(
        self: *const Module,
        fid: FuncId,
        arg: applicability.ArgShape,
        param: TypeRef,
        actual_bounds: []const ModuleRegistry.TypeParamBound,
    ) StaticCompatibility {
        sac_route = "-";
        const declared = staticTypeHead(param.name);
        // A `*` in the PARAM position is the deriver's own erasure product
        // (an unbound class param star-projected by the receiver record);
        // it proves nothing and must not refute.
        if (std.mem.eql(u8, declared, "*")) {
            sac_route = "star-neutral";
            return .unknown;
        }
        if (overrideQualifiedPath(param) == null and
            self.funcTypeParamIndex(fid, declared) != null)
        {
            if (arg.ty) |ty| {
                sac_route = "fn-tp-generic";
                return self.staticGenericArgCompatibility(
                    fid,
                    ty,
                    param,
                    0,
                );
            }
            const bound = self.staticFuncTypeParamBound(fid, declared).?;
            sac_route = "fn-tp-bound";
            if (std.mem.eql(u8, applicability.simpleName(staticTypeHead(bound)), "Any")) return .compatible;
            return .unknown;
        }
        // A class-owned type parameter needs the receiver's class
        // substitution environment, which this per-argument probe does not
        // yet carry.
        if (self.staticDeclTypeParam(fid, param)) {
            if (parseClassTypeParamIdentity(declared)) |identity| {
                const owner = if (identity.owner.int() < self.classes.items.len)
                    &self.classes.items[identity.owner.int()]
                else
                    return .unknown;
                const bounds = self.registry.class_type_param_bounds.get(owner.fqn) orelse
                    return .unknown;
                var required: ?TypeRef = null;
                for (bounds) |bound| {
                    if (std.mem.eql(u8, bound.param, identity.param)) {
                        required = .{
                            .name = bound.bound,
                            .nullable = param.nullable,
                            .args = &.{},
                        };
                        break;
                    }
                }
                if (required != null and arg.ty != null) {
                    // A bare type-parameter ARGUMENT is never definite: the
                    // caller's own `T` offered to the owner's `T` slot
                    // (EnumEntriesList.indexOf(element: T) from a generic
                    // body) can bind anything its bound admits.
                    {
                        var ah = staticTypeHead(std.mem.trimEnd(u8, arg.ty.?.name, "?"));
                        if (parseClassTypeParamIdentity(ah)) |ident2| ah = ident2.param;
                        var tp_bound: ?ModuleRegistry.TypeParamBound = null;
                        for (actual_bounds) |ab| {
                            if (std.mem.eql(u8, ab.param, ah)) {
                                tp_bound = ab;
                                break;
                            }
                        }
                        if (tp_bound) |ab| {
                            // Judge the parameter THROUGH its bound: every
                            // instantiation of T satisfies the bound, so
                            // bound <: required proves the argument, and a
                            // provably disjoint bound/required pair refutes
                            // it. Anything else is unknown.
                            var barg_buf: [8]TypeRef = undefined;
                            var bref = TypeRef{ .name = ab.bound, .nullable = false, .args = &.{} };
                            if (ab.args.len != 0 and ab.args.len <= barg_buf.len) {
                                for (ab.args, 0..) |an, i| {
                                    barg_buf[i] = .{ .name = an, .nullable = false, .args = &.{} };
                                }
                                bref.args = barg_buf[0..ab.args.len];
                            }
                            if (self.staticTypeIsSubtypeWithBounds(
                                self.registry.allocator,
                                bref,
                                required.?,
                                actual_bounds,
                            ) catch false) return .compatible;
                            // Refutation-by-bound needs a bare `T` that
                            // provably names the CALLER's own parameter (an
                            // authoritative shape). A call-return-derived
                            // `T` names the CALLEE's parameter; a
                            // same-named caller bound (`fun <T :
                            // CharSequence>` shadowing the class's `T :
                            // Number`) then refuted the overload kotlinc
                            // picks. Advisory shapes never refute here.
                            if (arg.ty_authoritative and
                                self.staticReceiverCompatibility(null, bref, required.?) == .incompatible and
                                self.staticReceiverCompatibility(null, required.?, bref) == .incompatible)
                            {
                                return .incompatible;
                            }
                            return .unknown;
                        }
                        if (ah.len > 0 and ah.len <= 2 and std.ascii.isUpper(ah[0])) return .unknown;
                    }
                    if (self.staticTypeIsSubtypeWithBounds(
                        self.registry.allocator,
                        arg.ty.?,
                        required.?,
                        actual_bounds,
                    ) catch false) return .compatible;
                    if (self.staticTypeDisproofComplete(arg.ty.?, actual_bounds) and
                        self.staticTypeDisproofComplete(required.?, actual_bounds))
                    {
                        return .incompatible;
                    }
                }
            }
            return .unknown;
        }
        if (arg.is_null) return if (param.nullable) .compatible else .incompatible;
        if (arg.literal_kind) |kind| {
            const builtin_identity = self.staticBuiltinIdentity(param, declared);
            if (builtin_identity == .ambiguous) return .unknown;
            if (builtin_identity == .no) return .incompatible;
            if (kind == .numeric) {
                const numeric_target = std.mem.eql(u8, declared, "Byte") or
                    std.mem.eql(u8, declared, "Short") or
                    std.mem.eql(u8, declared, "Int") or
                    std.mem.eql(u8, declared, "Long") or
                    std.mem.eql(u8, declared, "Float") or
                    std.mem.eql(u8, declared, "Double") or
                    std.mem.eql(u8, declared, "UByte") or
                    std.mem.eql(u8, declared, "UShort") or
                    std.mem.eql(u8, declared, "UInt") or
                    std.mem.eql(u8, declared, "ULong");
                if (std.mem.eql(u8, declared, "Any") or
                    std.mem.eql(u8, declared, "Number")) return .compatible;
                if (!numeric_target) return .incompatible;
                if (arg.ty) |ty| {
                    if (std.mem.eql(u8, staticTypeHead(ty.name), declared)) {
                        return .compatible;
                    }
                    // An integer literal IS a Long in a Long slot (kotlinc
                    // literal typing): `onTimeout(1000) { }` binds the
                    // `timeMillis: Long` overload outright — leaving it
                    // unknown withheld the sole survivor and deferred a
                    // call kotlinc resolves statically.
                    if (std.mem.eql(u8, staticTypeHead(ty.name), "Int") and
                        std.mem.eql(u8, declared, "Long"))
                    {
                        return .compatible;
                    }
                }
                // Integer literal coercion and floating/integral literal
                // distinctions need value-aware evidence. A different
                // additive type head cannot reject this candidate.
                return .unknown;
            }
            return switch (kind) {
                .numeric => unreachable,
                .string => if (std.mem.eql(u8, declared, "String") or
                    std.mem.eql(u8, declared, "CharSequence") or
                    std.mem.eql(u8, declared, "Any")) .compatible else .incompatible,
                .boolean => if (std.mem.eql(u8, declared, "Boolean") or
                    std.mem.eql(u8, declared, "Any")) .compatible else .incompatible,
                .char => if (std.mem.eql(u8, declared, "Char") or
                    std.mem.eql(u8, declared, "Any")) .compatible else .incompatible,
            };
        }
        if (arg.ty) |ty| {
            if (self.staticTypeContainsFuncParam(fid, param)) {
                sac_route = "contains-fn-tp";
                return self.staticGenericArgCompatibility(fid, ty, param, 0);
            }
            if (typeContainsBoundParam(ty, actual_bounds)) {
                // An UNBOUNDED type variable of the caller (`value: T` with
                // bound `Any`) is only an `Any`: it never binds a concrete
                // class parameter (`mode: Mode`), exactly as kotlinc rejects
                // it. A bounded one is judged through its bound below.
                if (ty.args.len == 0) {
                    const ah0 = staticTypeHead(std.mem.trimEnd(u8, ty.name, "?"));
                    for (actual_bounds) |ab| {
                        if (!std.mem.eql(u8, ab.param, ah0)) continue;
                        const bound_any = std.mem.eql(u8, applicability.simpleName(staticTypeHead(ab.bound)), "Any");
                        if (bound_any and !std.mem.eql(u8, applicability.simpleName(declared), "Any") and
                            self.staticTypeClassId(param) != null and
                            self.funcTypeParamIndex(fid, declared) == null and !self.staticDeclTypeParam(fid, param))
                        {
                            sac_route = "unbounded-tv-vs-class";
                            return .incompatible;
                        }
                        break;
                    }
                }
                if (self.staticTypeIsSubtypeWithBounds(
                    self.registry.allocator,
                    ty,
                    param,
                    actual_bounds,
                ) catch false) return .compatible;
                // Judging the arg's bare `T` THROUGH the caller's bound is
                // only sound when the shape provably names the caller's own
                // parameter (authoritative). A call-return-derived `T` is the
                // CALLEE's parameter; a same-named caller bound (`fun <T :
                // CharSequence>` shadowing the class's `T : Number`) then
                // refuted the overload kotlinc picks. Advisory shapes never
                // refute.
                if (arg.ty_authoritative and
                    self.staticTypeDisproofComplete(ty, actual_bounds) and
                    self.staticTypeDisproofComplete(param, actual_bounds))
                {
                    return .incompatible;
                }
                return .unknown;
            }
            if (nonCallableBuiltinHead(declared) and
                std.mem.startsWith(u8, staticTypeHead(ty.name), "Function"))
            {
                return .incompatible;
            }
            // A generic pair judges through the args-aware prover: the
            // head-only tail proved `List<String>` against an instantiated
            // `List<List<String>>` (`Box<List<String>>.put(xs: List<T>)`)
            // and the wrong overload won. Heads still adjudicate first
            // inside; absent-args grace and projections apply there. Routed
            // only when the PARAM carries arguments: an instantiated actual
            // against a plain-headed param (`MutableState<Int>` vs `Any?` on
            // the memoized `remember`) is the ordinary erased-head question,
            // and the prover's class-table walk has no edge to `Any`.
            if (param.args.len != 0) {
                sac_route = "generic-tail";
                return self.staticGenericArgCompatibility(fid, ty, param, 0);
            }
            sac_route = "recv-compat-tail";
            return self.staticReceiverCompatibility(fid, ty, param);
        }
        if (arg.is_lambda or arg.lambda_arity != null or arg.func_typed) {
            const head = staticTypeHead(param.name);
            if (std.mem.startsWith(u8, head, "Function")) {
                const suffix = head["Function".len..];
                const expected = std.fmt.parseInt(usize, suffix, 10) catch
                    return .unknown;
                if (arg.lambda_arity) |arity| {
                    const got: usize = arity;
                    if (got == expected or (got > 0 and got - 1 == expected) or
                        (got == 0 and expected == 1))
                    {
                        return .compatible;
                    }
                }
            }
            // Callable arity proves the FunctionN surface, but not a SAM
            // conversion or an unknown callable's parameter/return types.
            // A non-callable BUILTIN parameter, though, is a definite
            // refutation: no lambda converts to Unit or a primitive, so
            // `tryResume(value: T := Unit)` drops for the onCancellation
            // argument and the file-private Boolean extension binds. User
            // classes stay unknown (a fun-interface SAM target).
            if (nonCallableBuiltinHead(head)) return .incompatible;
            // A resolvable NON-fun-interface class param is a definite
            // refutation too: a lambda converts only to a function type or
            // a fun interface (`propertyEquals(property: KProperty1<..>)`
            // drops for a lambda argument; its getter sibling binds).
            if (lambdaRefuteOn()) {
                if (self.staticTypeClassId(.{ .name = head, .nullable = false, .args = &.{} })) |pcid| {
                    if (pcid.int() < self.classes.items.len and
                        !self.classes.items[pcid.int()].is_fun_interface)
                    {
                        return .incompatible;
                    }
                }
            }
            return .unknown;
        }
        // The reverse refutation: a definitely NON-callable argument (a
        // String/scalar static type, no lambda and no callable surface)
        // never satisfies a FUNCTION-TYPE parameter, whatever its
        // spelling — the parser's `<function>` tag, a spelled
        // `(A) -> B`, or the erased `FunctionN` names. `url(urlString)`
        // must drop the member `url(block)` so the String extension
        // binds; without this the head named no registered class and the
        // probe answered `.unknown`, letting the member survive.
        if (!arg.is_lambda and arg.lambda_arity == null and !arg.func_typed) {
            if (headIsFunctionSpelling(param.name)) {
                if (arg.ty) |aty| {
                    if (nonCallableBuiltinHead(staticTypeHead(aty.name))) return .incompatible;
                }
            }
        }
        return .unknown;
    }

    fn lambdaRefuteOn() bool {
        const S = struct {
            var cached: bool = false;
            var val: bool = true;
        };
        if (!S.cached) {
            S.val = std.c.getenv("KLIO_LAMBDA_REFUTE") == null or
                !std.mem.eql(u8, std.mem.span(std.c.getenv("KLIO_LAMBDA_REFUTE").?), "0");
            S.cached = true;
        }
        return S.val;
    }

    /// Whether a param-type NAME denotes a function type in any spelling:
    /// the parser's `<function>` tag, a spelled-out `(A) -> B`, or the
    /// erased `FunctionN`/`SuspendFunctionN`/`KFunctionN` names (digit
    /// tail required so a user class named `FunctionTable` never claims
    /// the surface).
    fn headIsFunctionSpelling(name: []const u8) bool {
        if (std.mem.eql(u8, name, "<function>")) return true;
        if (std.mem.indexOf(u8, name, "->") != null) return true;
        var head = staticTypeHead(name);
        for ([_][]const u8{ "Function", "SuspendFunction", "KFunction", "KSuspendFunction" }) |p| {
            if (std.mem.startsWith(u8, head, p) and head.len > p.len) {
                var all_digits = true;
                for (head[p.len..]) |c| {
                    if (c < '0' or c > '9') {
                        all_digits = false;
                        break;
                    }
                }
                if (all_digits) return true;
            }
        }
        return false;
    }

    /// Whether the params a trailing-callable mapping would SKIP — those
    /// between the last positional arg and the final parameter — all carry
    /// defaults. Kotlin fills that gap from defaults only; mapping across
    /// an undefaulted middle fabricates an applicability kotlinc rejects.
    fn bargTraceEnv() ?[]const u8 {
        const S = struct {
            var cached: bool = false;
            var val: ?[]const u8 = null;
        };
        if (!S.cached) {
            S.val = if (std.c.getenv("KLIO_BARG_TRACE")) |w| std.mem.span(w) else null;
            S.cached = true;
        }
        return S.val;
    }

    fn dropTraceEnv() ?[]const u8 {
        const S = struct {
            var cached: bool = false;
            var val: ?[]const u8 = null;
        };
        if (!S.cached) {
            S.val = if (std.c.getenv("KLIO_DROP_TRACE")) |w| std.mem.span(w) else null;
            S.cached = true;
        }
        return S.val;
    }

    fn trailingGapDefaulted(params: []const Param, n_args: usize) bool {
        if (n_args == 0 or n_args > params.len) return true;
        var i = n_args - 1;
        while (i + 1 < params.len) : (i += 1) {
            if (!params[i].has_default) return false;
        }
        return true;
    }

    /// Builtin classifier heads no function value can convert to: the
    /// definite-refutation set for a callable argument.
    fn nonCallableBuiltinHead(head: []const u8) bool {
        const set = [_][]const u8{
            "Unit",  "Int",    "Long",  "Short",  "Byte",  "Boolean",
            "Char",  "Float",  "Double", "String", "UInt",  "ULong",
            "UShort", "UByte",
        };
        for (set) |n| {
            if (std.mem.eql(u8, head, n)) return true;
        }
        return false;
    }

    fn staticMemberArgsCompatibility(
        self: *const Module,
        allocator: Allocator,
        fid: FuncId,
        f: *const Func,
        args: []const applicability.ArgShape,
        actual_bounds: []const ModuleRegistry.TypeParamBound,
        receiver: ?TypeRef,
    ) StaticCompatibility {
        const skip: usize = if (f.params.len != 0 and
            std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        const params = f.params[skip..];
        if (std.c.getenv("KLIO_SMAC_TRACE")) |w| {
            if (std.mem.eql(u8, std.mem.span(w), f.name)) {
                std.debug.print("[smac] rt={} {s}#{d} nargs={d} recv={s} recv_args={d} nf={d}\n", .{
                    eval.currentFrameFunc() != null,
                    f.fqn,
                    fid.int(),
                    args.len,
                    if (receiver) |r| r.name else "-",
                    if (receiver) |r| r.args.len else 0,
                    self.funcs.items.len,
                });
            }
        }
        for (args) |arg| {
            if (arg.named != null or arg.is_spread) return .unknown;
        }
        for (params) |param| {
            if (param.is_vararg) return .unknown;
        }
        if (args.len > params.len) return .incompatible;
        var bindings: std.ArrayList(TypeBinding) = .empty;
        // The receiver's type arguments exist to instantiate the PARAMETER
        // types below. A zero-argument call has none to instantiate, so a
        // receiver that cannot project (a bare `Set` head from a lambda body)
        // must not turn `iterator()` unknown.
        if (args.len != 0) if (receiver) |actual_receiver| {
            if (self.decl_sigs.get(fid.int())) |sig| {
                if (sig.enclosing_class) |owner| {
                    if (owner.int() < self.classes.items.len) {
                        const projected = (self.projectTypeToClass(
                            allocator,
                            actual_receiver,
                            owner,
                        ) catch null) orelse return .unknown;
                        const owner_class = &self.classes.items[owner.int()];
                        const projected_args = overrideArgs(projected);
                        if (projected_args.len < owner_class.type_params.len) {
                            return .unknown;
                        }
                        for (owner_class.type_params, 0..) |param, i| {
                            bindings.append(allocator, .{
                                .name = classTypeParamIdentity(
                                    allocator,
                                    owner,
                                    param,
                                ) catch return .unknown,
                                .ty = projected_args[i],
                            }) catch return .unknown;
                        }
                    }
                }
            }
        };
        var result: StaticCompatibility = .compatible;
        // A trailing lambda maps to the LAST parameter across DEFAULTED
        // middles, exactly as the extension ranker and arity mapping do.
        // Kotlin fills the gap from defaults only: without the default
        // check the single callable of `cont.tryResume(onCancellation)`
        // mapped past the member's undefaulted `(value, idempotent)` and
        // the token-returning member outranked the Boolean extension —
        // a Symbol reached a branch and every `select` rendezvous hung.
        const trailing_lambda_arg = args.len != 0 and
            (args[args.len - 1].is_lambda or args[args.len - 1].lambda_arity != null or
                args[args.len - 1].func_typed) and
            trailingGapDefaulted(params, args.len);
        for (args, 0..) |arg, ai| {
            const param = if (trailing_lambda_arg and ai + 1 == args.len and
                args.len <= params.len)
                params[params.len - 1]
            else
                params[ai];
            const instantiated_param = if (bindings.items.len == 0)
                param.ty
            else
                substituteType(
                    allocator,
                    param.ty,
                    bindings.items,
                ) catch return .unknown;
            const arg_result = self.staticArgCompatibility(
                fid,
                arg,
                instantiated_param,
                actual_bounds,
            );
            if (std.c.getenv("KLIO_SMAC_TRACE")) |w| {
                if (std.mem.eql(u8, std.mem.span(w), f.name)) {
                    std.debug.print("[smac-arg] param={s}<{d}> inst={s}<{d}> arg_ty={s} route={s} -> {s}\n", .{
                        param.ty.name,
                        param.ty.args.len,
                        instantiated_param.name,
                        instantiated_param.args.len,
                        if (arg.ty) |t| t.name else "-",
                        sac_route,
                        @tagName(arg_result),
                    });
                }
            }
            if (arg_result == .incompatible) return .incompatible;
            if (arg_result == .unknown) result = .unknown;
        }
        return result;
    }

    fn extensionKeyGreater(a: [9]i32, b: [9]i32) bool {
        inline for (0..8) |i| {
            if (a[i] != b[i]) return a[i] > b[i];
        }
        return false;
    }

    fn extensionKeyEquivalent(a: [9]i32, b: [9]i32) bool {
        return std.mem.eql(i32, a[0..8], b[0..8]);
    }

    /// True when two function-typed parameter refs agree on everything a
    /// closure body can observe: same arity head and same argument types in
    /// every position but the LAST (the function's return).
    fn functionParamArgsAgree(a: TypeRef, b: TypeRef) bool {
        if (!std.mem.eql(u8, staticTypeHead(a.name), staticTypeHead(b.name))) return false;
        if (a.args.len != b.args.len or a.args.len == 0) return false;
        for (a.args[0 .. a.args.len - 1], b.args[0 .. b.args.len - 1]) |aa, ba| {
            if (!aa.eql(ba)) return false;
        }
        return true;
    }

    /// A representative for LAMBDA-PARAMETER typing out of a tied candidate
    /// set: non-null only when every candidate declares the same parameter
    /// list up to function-return positions, so whichever overload the tie
    /// eventually resolves to hands the closures the same parameter types.
    fn tiedLambdaParamRep(self: *const Module, fids: []const FuncId) ?FuncId {
        if (fids.len < 2) return null;
        const first = self.funcById(fids[0]) orelse return null;
        for (fids[1..]) |fid| {
            const other = self.funcById(fid) orelse return null;
            if (other.params.len != first.params.len) return null;
            for (first.params, other.params) |fp, op| {
                if (fp.ty.eql(op.ty)) continue;
                const fh = staticTypeHead(fp.ty.name);
                const is_fn = std.mem.startsWith(u8, fh, "Function") or
                    std.mem.startsWith(u8, fh, "SuspendFunction") or
                    std.mem.startsWith(u8, fh, "KFunction");
                if (!is_fn or !functionParamArgsAgree(fp.ty, op.ty)) return null;
            }
        }
        return fids[0];
    }

    fn staticReceiverCouldAccept(self: *const Module, fid: FuncId, receiver: TypeRef, param: TypeRef) bool {
        return self.staticReceiverCompatibility(fid, receiver, param) != .incompatible;
    }

    fn memberExtensionOwnerIsObject(self: *const Module, fid: FuncId) ?[]const u8 {
        const owner = self.registry.member_ext_owner_class.get(fid) orelse return null;
        if (self.classIdByFqn(owner)) |id| {
            if (id.int() < self.classes.items.len and self.classes.items[id.int()].is_object) {
                return owner;
            }
        }
        for (self.registry.object_names.items) |object_name| {
            if (std.mem.eql(u8, object_name, owner)) return owner;
        }
        return null;
    }

    fn scopedClassId(
        self: *const Module,
        name: []const u8,
        ctx: ExtensionResolveCtx,
    ) ?ClassId {
        return if (std.mem.indexOfScalar(u8, name, '.') != null)
            self.classIdByFqn(name)
        else
            self.classIdIndexed(name, ctx.caller_package, ctx.caller_file);
    }

    fn dispatchOwnerInChain(
        self: *const Module,
        start: []const u8,
        owner: []const u8,
        ctx: ExtensionResolveCtx,
    ) bool {
        const owner_id = self.scopedClassId(owner, ctx);
        var current: ?[]const u8 = start;
        var hops: u8 = 0;
        while (current) |candidate| : (hops += 1) {
            if (hops > 16) break;
            if (owner_id) |target| {
                if (self.scopedClassId(candidate, ctx)) |candidate_id| {
                    if (self.classIdIsOrExtends(candidate_id, target)) return true;
                }
            } else if (std.mem.eql(u8, candidate, owner) or
                (std.mem.indexOfScalar(u8, owner, '.') == null and
                    std.mem.eql(u8, staticTypeHead(candidate), staticTypeHead(owner))))
            {
                return true;
            }
            const candidate_head = staticTypeHead(candidate);
            current = self.registry.enclosing_class.get(candidate) orelse
                self.registry.enclosing_class.get(candidate_head);
        }
        return false;
    }

    fn lexicalOwnerChainContains(
        self: *const Module,
        start: []const u8,
        owner: []const u8,
        ctx: ExtensionResolveCtx,
    ) bool {
        var current: ?[]const u8 = start;
        var hops: u8 = 0;
        while (current) |candidate| : (hops += 1) {
            if (hops > 16) break;
            if (self.dispatchOwnerInChain(candidate, owner, ctx)) return true;
            current = self.registry.enclosing_class.get(candidate) orelse
                self.registry.enclosing_class.get(staticTypeHead(candidate));
        }
        return false;
    }

    fn lexicalOwnerCompanionMatches(
        self: *const Module,
        start: []const u8,
        owner: []const u8,
        ctx: ExtensionResolveCtx,
    ) bool {
        var current: ?[]const u8 = start;
        var hops: u8 = 0;
        while (current) |candidate| : (hops += 1) {
            if (hops > 16) break;
            const head = staticTypeHead(candidate);
            const companion = self.registry.companion_singletons.get(candidate) orelse
                self.registry.companion_singletons.get(head);
            if (companion) |name| {
                if (self.dispatchOwnerInChain(name, owner, ctx)) return true;
            }
            current = self.registry.enclosing_class.get(candidate) orelse
                self.registry.enclosing_class.get(head);
        }
        return false;
    }

    fn memberDispatchOwnerInScope(self: *const Module, owner: []const u8, ctx: ExtensionResolveCtx) bool {
        for (ctx.implicit_dispatch_owners) |implicit| {
            if (self.dispatchOwnerInChain(implicit, owner, ctx)) return true;
        }
        if (ctx.lexical_owner) |lexical| {
            if (self.dispatchOwnerInChain(lexical, owner, ctx) or
                self.lexicalOwnerCompanionMatches(lexical, owner, ctx)) return true;
        }
        return false;
    }

    fn memberExtensionScopeTier(
        self: *const Module,
        owner: []const u8,
        ctx: ExtensionResolveCtx,
    ) u8 {
        for (ctx.implicit_dispatch_owners, 0..) |implicit, index| {
            if (self.dispatchOwnerInChain(implicit, owner, ctx)) {
                return @intCast(@min(index, 31));
            }
        }
        if (ctx.lexical_owner) |lexical| {
            if (self.dispatchOwnerInChain(lexical, owner, ctx) or
                self.lexicalOwnerCompanionMatches(lexical, owner, ctx))
            {
                return @intCast(@min(ctx.implicit_dispatch_owners.len, 31));
            }
        }
        return 32;
    }

    fn objectMemberExtensionInScope(
        self: *const Module,
        fid: FuncId,
        f: *const Func,
        name: []const u8,
        owner: []const u8,
        ctx: ExtensionResolveCtx,
    ) bool {
        if (self.memberDispatchOwnerInScope(owner, ctx)) return true;
        for (self.importAliasPathsIn(ctx.caller_file, name)) |path| {
            if (std.mem.eql(u8, path.fqn, f.fqn)) return true;
        }
        const owner_fqn = blk: {
            if (self.decl_sigs.get(fid.int())) |decl| {
                if (decl.enclosing_class) |owner_id| {
                    if (owner_id.int() < self.classes.items.len) {
                        break :blk self.classes.items[owner_id.int()].fqn;
                    }
                }
            }
            const dot = std.mem.lastIndexOfScalar(u8, f.fqn, '.') orelse return false;
            break :blk f.fqn[0..dot];
        };
        return self.importWildcardIn(ctx.caller_file, owner_fqn);
    }

    fn memberExtensionInScope(
        self: *const Module,
        fid: FuncId,
        f: *const Func,
        decl: ?DeclSig,
        ctx: ExtensionResolveCtx,
    ) bool {
        const owner = self.registry.member_ext_owner_class.get(fid) orelse return false;
        if (decl) |sig| switch (sig.visibility) {
            .Private => {
                const lexical = ctx.lexical_owner orelse return false;
                if (!self.lexicalOwnerChainContains(lexical, owner, ctx) and
                    !self.lexicalOwnerCompanionMatches(lexical, owner, ctx)) return false;
            },
            .Protected => {
                const lexical = ctx.lexical_owner orelse return false;
                if (!self.dispatchOwnerInChain(lexical, owner, ctx) and
                    !self.lexicalOwnerCompanionMatches(lexical, owner, ctx)) return false;
            },
            .Public, .Internal => {},
        };
        if (self.memberExtensionOwnerIsObject(fid)) |object_owner| {
            return self.objectMemberExtensionInScope(
                fid,
                f,
                ctx.call_name orelse f.name,
                object_owner,
                ctx,
            );
        }
        return self.memberDispatchOwnerInScope(owner, ctx);
    }

    fn genericReceiverSuppliesLambdaReceiver(
        self: *const Module,
        fid: FuncId,
        args: []const applicability.ArgShape,
    ) bool {
        const f = self.funcById(fid) orelse return false;
        if (self.declarationKind(fid, f) != .top_level_extension or
            f.params.len < 2 or
            args.len != f.params.len - 1)
        {
            return false;
        }
        const receiver_param = staticTypeHead(f.params[0].ty.name);
        if (self.funcTypeParamIndex(fid, receiver_param) == null) return false;
        var supplied = false;
        for (args, f.params[1..]) |arg, param| {
            if (param.is_vararg) return false;
            if (!arg.lambda_is_literal) {
                if (arg.ty == null and arg.literal_kind == null) return false;
                continue;
            }
            if (!std.mem.startsWith(u8, applicability.simpleName(param.ty.name), "Function") or
                param.ty.args.len < 2 or
                !std.mem.eql(
                    u8,
                    staticTypeHead(param.ty.args[0].name),
                    receiver_param,
                ))
            {
                return false;
            }
            supplied = true;
        }
        return supplied;
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
            if (arg.is_spread) return .{};
        }
        var scratch = std.heap.ArenaAllocator.init(self.registry.allocator);
        defer scratch.deinit();
        const sa = scratch.allocator();
        var scoped_receiver = self.resolveTypeAliasAt(
            sa,
            receiver,
            ctx.caller_file,
            ctx.caller_package,
        ) catch return .{};
        // A receiver still HEADED by a type parameter ranks with its full
        // bound substituted: `data - "foo"` on a `T : Iterable<String>`
        // receiver must refute `Set.minus` exactly as kotlinc does — an
        // unresolved `T` head leaves every receiver-shaped candidate
        // applicable, and the wrong overload can outrank the bound's own.
        if (scoped_receiver.args.len == 0) {
            const rhead = staticTypeHead(std.mem.trimEnd(u8, scoped_receiver.name, "?"));
            if (runtime.envSetOnce("KLIO_HOP_TRACE")) {
                std.debug.print("[hop] {s} recv={s} nbounds={d}\n", .{ name, rhead, ctx.actual_type_param_bounds.len });
                for (ctx.actual_type_param_bounds) |b0| {
                    std.debug.print("[hop]   {s} : {s} args={d}\n", .{ b0.param, b0.bound, b0.args.len });
                }
            }
            for (ctx.actual_type_param_bounds) |b| {
                if (!std.mem.eql(u8, b.param, rhead)) continue;
                if (b.args.len == 0) break;
                if (sa.alloc(TypeRef, b.args.len)) |hop_args| {
                    for (b.args, hop_args) |an, *dst| {
                        dst.* = .{ .name = an, .nullable = false, .args = &.{} };
                    }
                    scoped_receiver = .{
                        .name = b.bound,
                        .nullable = false,
                        .args = hop_args,
                    };
                } else |_| {}
                break;
            }
        }
        var ids: std.ArrayList(FuncId) = .empty;
        var tiers: std.ArrayList(u8) = .empty;
        var unknowns: std.ArrayList(bool) = .empty;
        var named_maps: std.ArrayList(?[]const usize) = .empty;
        var named_skips: std.ArrayList(bool) = .empty;
        var unknown_best_tier: u8 = 255;
        // The per-call window delimiter for the rex trace: every candidate
        // row until the next rex-call row belongs to this resolution.
        if (runtime.envSetOnce("KLIO_REX_TRACE")) {
            if (applicability.trace_call_span) |sp| {
                std.debug.print("[rex-call] {s} recv={s} rargs={d} at=f{d}:{d}\n", .{ name, scoped_receiver.name, scoped_receiver.args.len, sp.file.int(), sp.start });
            } else {
                std.debug.print("[rex-call] {s} recv={s} rargs={d}\n", .{ name, scoped_receiver.name, scoped_receiver.args.len });
            }
        }
        var candidate_it = self.bareCallCandidateIterator(name, ctx.caller_file);
        var receiver_pruned: usize = 0;
        candidate_loop: while (candidate_it.next()) |fid| {
            const f = self.funcById(fid) orelse continue;
            const ds = self.decl_sigs.get(fid.int());
            const kind = if (ds) |decl| decl.kind else f.kind;
            const is_member_extension = kind == .member_extension;
            const rex_trace = runtime.envSetOnce("KLIO_REX_TRACE");
            if (rex_trace) std.debug.print("[rex] {s} fid={d} kind={s} enter recv={s} rargs={d}\n", .{ name, fid.int(), @tagName(kind), scoped_receiver.name, scoped_receiver.args.len });
            if ((kind != .top_level_extension and !is_member_extension) or
                f.params.len == 0 or
                !std.mem.eql(u8, f.params[0].name, "this")) continue;
            // `@Deprecated(level = ERROR|HIDDEN)` is UN-CALLABLE at any
            // site that does not `@Suppress("DEPRECATION_ERROR")`: kotlinc
            // reports an error rather than binding it, so it must never be
            // a static commit — not even as a sole survivor after a member
            // refutation (the stdlib's Java-compat
            // `MutableList<T>.remove(index: Int) = removeAt(index)` bound
            // `subList.remove(3)` to REMOVE-AT semantics through exactly
            // that hole).
            if (f.deprecated_error and !suppress_deprecation_error) continue;
            // Ordered named arguments bind by parameter IDENTITY, and may
            // skip parameters Kotlin fills from defaults: `rangesDelimitedBy(
            // delimiters, ignoreCase = x, limit = y)` skips the defaulted
            // `startIndex`, and kotlinc still resolves the call statically.
            // Build the arg -> param mapping monotonically (each named
            // argument binds the next parameter carrying its name; every
            // parameter it skips must default); the scorer then judges each
            // argument against ITS parameter instead of the raw position.
            // Backwards-reordered named calls and vararg declarations keep
            // the strict in-position rule and stay deferred.
            var named_map: ?[]const usize = null;
            var named_map_skips = false;
            {
                var any_named = false;
                for (args) |arg0| {
                    if (arg0.named != null) {
                        any_named = true;
                        break;
                    }
                }
                var vararg_decl = false;
                for (f.params[1..]) |param| {
                    if (param.is_vararg) {
                        vararg_decl = true;
                        break;
                    }
                }
                if (any_named and vararg_decl) {
                    for (args, 0..) |arg, i| {
                        const arg_name = arg.named orelse continue;
                        const param_index = i + 1;
                        if (param_index >= f.params.len or
                            !applicability.paramNameMatchesArg(
                                f.params[param_index].name,
                                arg_name,
                            ))
                        {
                            continue :candidate_loop;
                        }
                    }
                } else if (any_named) {
                    const map_buf = sa.alloc(usize, args.len) catch return .{};
                    var next: usize = 1;
                    for (args, 0..) |arg, i| {
                        if (arg.named) |arg_name| {
                            var j = next;
                            var gap_defaulted = true;
                            const found: ?usize = while (j < f.params.len) : (j += 1) {
                                if (applicability.paramNameMatchesArg(f.params[j].name, arg_name)) break j;
                                if (!f.params[j].has_default and f.params[j].default == null)
                                    gap_defaulted = false;
                            } else null;
                            const pj = found orelse continue :candidate_loop;
                            if (!gap_defaulted) continue :candidate_loop;
                            map_buf[i] = pj;
                            next = pj + 1;
                        } else {
                            // The trailing-callable rule applies inside the
                            // mapping too: a last positional lambda fills the
                            // LAST parameter across a defaulted gap.
                            if (i + 1 == args.len and
                                (arg.is_lambda or arg.lambda_arity != null or arg.func_typed) and
                                next < f.params.len - 1 and
                                applicability.isFunctionTypeRef(&f.params[f.params.len - 1].ty))
                            {
                                const gap_defaulted = for (f.params[next .. f.params.len - 1]) |param| {
                                    if (!param.has_default and param.default == null) break false;
                                } else true;
                                if (gap_defaulted) {
                                    map_buf[i] = f.params.len - 1;
                                    next = f.params.len;
                                    continue;
                                }
                            }
                            if (next >= f.params.len) continue :candidate_loop;
                            map_buf[i] = next;
                            next += 1;
                        }
                    }
                    // Everything left unbound past the last binding must
                    // default; skipped middles were checked as they were
                    // crossed.
                    for (f.params[next..]) |param| {
                        if (!param.has_default and param.default == null)
                            continue :candidate_loop;
                    }
                    named_map = map_buf;
                    for (map_buf, 0..) |pj, i| {
                        if (pj != i + 1) {
                            named_map_skips = true;
                            break;
                        }
                    }
                }
            }
            if (is_member_extension and
                !self.memberExtensionInScope(fid, f, ds, ctx)) continue;
            const has_source_body = f.hasBody() or
                (if (ds) |decl| decl.has_body else false) or
                self.decl_ast_body.contains(fid.int()) or
                f.is_inline;
            const has_host_symbol = if (ds) |decl| decl.host_symbol != null else false;
            if (!has_source_body and !has_host_symbol) continue;
            const tier: u8 = if (is_member_extension)
                self.memberExtensionScopeTier(
                    self.registry.member_ext_owner_class.get(fid) orelse continue,
                    ctx,
                )
            else
                64 + @min(
                    self.scopeTier(
                        f.fqn,
                        f.package,
                        name,
                        ctx.caller_package,
                        ctx.caller_file,
                    ) + 1,
                    191,
                );
            if (!is_member_extension and
                tier > 64 + last_in_scope_tier + 1) continue;
            if (ds) |decl| {
                switch (decl.visibility) {
                    .Private => {
                        if (!is_member_extension) {
                            const decl_file = self.registry.private_fn_files.get(fid) orelse {
                                unknown_best_tier = @min(unknown_best_tier, tier);
                                continue;
                            };
                            if (decl_file.int() != ctx.caller_file.int()) continue;
                        } else {
                            // A private MEMBER extension is visible only in
                            // its declaring class's lexical family — nesting
                            // in either direction covers a companion's
                            // privates in the enclosing class — and never
                            // through inheritance: PrivateDerived does not
                            // see PrivateBase's private extension, so the
                            // stdlib candidate must win there.
                            const owner_name = self.registry.member_ext_owner_class.get(fid) orelse continue;
                            const owner_cid = (self.classIdByFqn(owner_name) orelse
                                self.classId(owner_name)) orelse continue;
                            const lex_name = ctx.lexical_owner orelse continue;
                            const lex_cid = (if (std.mem.indexOfScalar(u8, lex_name, '.') != null)
                                self.classIdByFqn(lex_name)
                            else
                                self.classId(lex_name)) orelse continue;
                            if (!self.lexicalChainContains(lex_cid, owner_cid) and
                                !self.lexicalChainContains(owner_cid, lex_cid)) continue;
                        }
                    },
                    .Internal => {
                        if (self.internalVisibleFrom(fid, ctx.caller_file)) |visible| {
                            if (!visible) continue;
                        } else {
                            unknown_best_tier = @min(unknown_best_tier, tier);
                            continue;
                        }
                    },
                    .Protected => if (!is_member_extension) continue,
                    .Public => {},
                }
            } else if (self.registry.private_fn_files.get(fid)) |decl_file| {
                if (decl_file.int() != ctx.caller_file.int()) continue;
            }
            var has_vararg = false;
            for (f.params[1..]) |param| {
                if (param.is_vararg) {
                    has_vararg = true;
                    break;
                }
            }
            if (has_vararg) {
                const required = if (ds) |decl| decl.arity.required else blk: {
                    var count: usize = 0;
                    for (f.params[1..]) |param| {
                        if (!param.is_vararg and !param.has_default and param.default == null) {
                            count += 1;
                        }
                    }
                    break :blk count;
                };
                if (args.len < required) continue;
            } else if (named_map == null) {
                if (args.len > f.params.len - 1) continue;
                // Trailing-callable rule at the ARITY gate: the last arg
                // fills the LAST param when that param is function-typed,
                // so only the MIDDLE gap must default — `windowed(2, 3)
                // { transform }` binds the 4-value-param transform
                // overload with `partialWindows` defaulted; the
                // positional walk instead demanded `transform` itself
                // default and dropped the overload kotlinc picks.
                // A named-mapped candidate already proved its skipped and
                // trailing parameters default while the map was built.
                const trailing_call = args.len > 0 and args.len < f.params.len - 1 and
                    (args[args.len - 1].is_lambda or
                        args[args.len - 1].lambda_arity != null or
                        args[args.len - 1].func_typed) and
                    applicability.isFunctionTypeRef(&f.params[f.params.len - 1].ty);
                var omitted_defaults = true;
                if (trailing_call) {
                    for (f.params[args.len .. f.params.len - 1]) |param| {
                        if (!param.has_default and param.default == null) {
                            omitted_defaults = false;
                            break;
                        }
                    }
                } else {
                    for (f.params[1 + args.len ..]) |param| {
                        if (!param.has_default and param.default == null) {
                            omitted_defaults = false;
                            break;
                        }
                    }
                }
                if (!omitted_defaults) continue;
            }
            const recv_param = if (ds) |decl| decl.receiver_ty orelse f.params[0].ty else f.params[0].ty;
            const decl_file = if (self.decl_span.get(fid.int())) |decl_source|
                decl_source.file
            else
                null;
            const scoped_recv_param = self.resolveTypeAliasAt(
                sa,
                recv_param,
                decl_file,
                f.package,
            ) catch return .{};
            var compatibility = self.staticReceiverCompatibility(
                fid,
                scoped_receiver,
                scoped_recv_param,
            );
            // KLIO_RECV_REFUTE=1 (A/B, default OFF): kotlinc's static
            // receiver semantics — a candidate whose declared receiver
            // classifier is provably unrelated to the PROVEN static receiver
            // is not a candidate at all (`Map.minus` never binds an
            // Iterable-typed receiver). The lazy default keeps the
            // runtime-polymorphic leniency until the audit adjudicates.
            if (compatibility == .unknown and scoped_receiver.args.len != 0 and
                recvRefuteOn())
            {
                const rh = staticTypeHead(std.mem.trimEnd(u8, scoped_receiver.name, "?"));
                const ph = staticTypeHead(std.mem.trimEnd(u8, scoped_recv_param.name, "?"));
                if (!std.mem.eql(u8, rh, ph) and
                    self.staticBuiltinIdentity(scoped_receiver, rh) == .yes and
                    self.staticBuiltinIdentity(scoped_recv_param, ph) == .yes and
                    !evidenceSubtypeCb(@ptrCast(@constCast(self)), rh, ph))
                {
                    compatibility = .incompatible;
                }
            }
            const declared_bounds = self.declaredTypeParamBounds(sa, fid) catch return .{};
            if (rex_trace) {
                std.debug.print("[rex] {s} fid={d} bounds={d} compat0={s}", .{ name, fid.int(), declared_bounds.len, @tagName(compatibility) });
                for (declared_bounds) |db| std.debug.print(" {s}<:{s}", .{ db.param, db.bound });
                std.debug.print("\n", .{});
            }
            if (declared_bounds.len != 0) {
                const generic_applies = self.staticGenericReceiverApplicable(
                    sa,
                    scoped_receiver,
                    scoped_recv_param,
                    declared_bounds,
                    ctx.actual_type_param_bounds,
                ) catch return .{};
                if (rex_trace) std.debug.print("[rex] {s} fid={d} generic_applies={}\n", .{ name, fid.int(), generic_applies });
                if (generic_applies) {
                    compatibility = .compatible;
                } else {
                    // A bound HEAD the actual receiver provably fails refutes
                    // the candidate outright: `where T : Node, T : Observer`
                    // never binds a CanvasScope receiver, and kotlinc drops
                    // the candidate at the declaration. Sound even for
                    // records marked incomplete — dropped bound arguments
                    // only narrow a bound — but only when BOTH classifiers
                    // are known classes with a provably absent relation.
                    var head_refuted = false;
                    const recv_head_name = staticTypeHead(std.mem.trimEnd(u8, scoped_receiver.name, "?"));
                    const recv_cid: ?ClassId = if (std.mem.indexOfScalar(u8, recv_head_name, '.') != null)
                        self.classIdByFqn(recv_head_name)
                    else
                        self.classId(recv_head_name);
                    if (recv_cid != null) {
                        const recv_param_head = staticTypeHead(std.mem.trimEnd(u8, scoped_recv_param.name, "?"));
                        for (declared_bounds) |db| {
                            if (!std.mem.eql(u8, db.param, recv_param_head)) continue;
                            var bh = staticTypeHead(db.bound);
                            if (std.mem.indexOfScalar(u8, bh, '<')) |lt| bh = bh[0..lt];
                            bh = std.mem.trimEnd(u8, std.mem.trim(u8, bh, " "), "?");
                            if (std.mem.eql(u8, bh, "Any") or std.mem.eql(u8, bh, "kotlin.Any")) continue;
                            const bound_cid: ?ClassId = if (std.mem.indexOfScalar(u8, bh, '.') != null)
                                self.classIdByFqn(bh)
                            else
                                self.classId(bh);
                            if (bound_cid == null) continue;
                            if (!self.classIdIsOrExtends(recv_cid.?, bound_cid.?)) {
                                head_refuted = true;
                                break;
                            }
                        }
                    }
                    if (rex_trace) std.debug.print("[rex] {s} fid={d} head_refuted={}\n", .{ name, fid.int(), head_refuted });
                    if (head_refuted) {
                        compatibility = .incompatible;
                        receiver_pruned += 1;
                    } else {
                        var erased_receiver = scoped_receiver;
                        erased_receiver.args = &.{};
                        var erased_param = scoped_recv_param;
                        erased_param.args = &.{};
                        compatibility = if (self.staticReceiverCompatibility(
                            null,
                            erased_receiver,
                            erased_param,
                        ) == .incompatible)
                            .incompatible
                        else
                            .unknown;
                    }
                }
            } else if (compatibility == .unknown) {
                const receiver_id = self.staticTypeClassId(scoped_receiver);
                const param_id = self.staticTypeClassId(scoped_recv_param);
                const disjoint_known_classifiers = receiver_id != null and
                    param_id != null and
                    !self.classIdIsOrExtends(receiver_id.?, param_id.?);
                const known_classifier_path = receiver_id != null and
                    param_id != null and
                    self.classIdIsOrExtends(receiver_id.?, param_id.?);
                const same_known_classifier = scoped_receiver.args.len != 0 and
                    scoped_recv_param.args.len != 0 and
                    ((receiver_id != null and param_id != null and
                        receiver_id.? == param_id.?) or
                        (std.mem.eql(
                            u8,
                            staticTypeHead(scoped_receiver.name),
                            staticTypeHead(scoped_recv_param.name),
                        ) and
                            self.staticBuiltinIdentity(
                                scoped_receiver,
                                staticTypeHead(scoped_receiver.name),
                            ) == .yes and
                            self.staticBuiltinIdentity(
                                scoped_recv_param,
                                staticTypeHead(scoped_recv_param.name),
                            ) == .yes));
                if (disjoint_known_classifiers) {
                    compatibility = .incompatible;
                } else if (known_classifier_path or same_known_classifier or
                    typeContainsBoundParam(receiver, ctx.actual_type_param_bounds))
                {
                    const subtype = self.staticTypeIsSubtypeWithBounds(
                        sa,
                        scoped_receiver,
                        scoped_recv_param,
                        ctx.actual_type_param_bounds,
                    ) catch return .{};
                    if (runtime.envSetOnce("KLIO_DISPROOF_TRACE")) {
                        std.debug.print("[disproof] {s} fid={d} recv={s}<{d}> param={s}<{d}> subtype={} recv_dis={} param_dis={}\n", .{
                            name,
                            fid.int(),
                            scoped_receiver.name,
                            scoped_receiver.args.len,
                            scoped_recv_param.name,
                            scoped_recv_param.args.len,
                            subtype,
                            self.staticTypeDisproofComplete(scoped_receiver, ctx.actual_type_param_bounds),
                            self.staticTypeDisproofComplete(scoped_recv_param, ctx.actual_type_param_bounds),
                        });
                    }
                    if (subtype) {
                        compatibility = .compatible;
                    } else if (self.staticTypeDisproofComplete(
                        scoped_receiver,
                        ctx.actual_type_param_bounds,
                    ) and
                        self.staticTypeDisproofComplete(
                            scoped_recv_param,
                            ctx.actual_type_param_bounds,
                        ))
                    {
                        compatibility = .incompatible;
                        receiver_pruned += 1;
                    }
                }
            }
            if (compatibility == .incompatible) continue;
            if (has_vararg) {
                // `applicability.applicable` maps fixed/default/vararg
                // positions below. Keep the extra static compatibility proof
                // conservative until it models repeated vararg element slots.
                compatibility = .unknown;
            } else {
                // A trailing lambda fills the LAST parameter even when
                // DEFAULTED parameters are omitted between (`windowed(2, 3)
                // { transform }` maps the lambda past `partialWindows`);
                // judging it positionally refuted the overload kotlinc
                // binds. The skipped middle must be all-defaulted (Kotlin
                // fills the gap from defaults only) — see the member-side
                // mapping's tryResume note.
                const trailing_lambda_arg = args.len != 0 and
                    (args[args.len - 1].is_lambda or args[args.len - 1].lambda_arity != null or
                        args[args.len - 1].func_typed) and
                    trailingGapDefaulted(f.params[1..], args.len);
                for (args, 0..) |arg, ai| {
                    const pi = if (named_map) |mp|
                        mp[ai]
                    else if (trailing_lambda_arg and ai + 1 == args.len and
                        1 + args.len <= f.params.len)
                        f.params.len - 1
                    else
                        1 + ai;
                    const param = f.params[pi];
                    // The RECEIVER's instantiation constrains the callee's
                    // own type parameters before any argument is judged:
                    // `plus(elements: Iterable<T>)` on a `List<List<String>>`
                    // receiver requires `Iterable<List<String>>`, so a
                    // `List<String>` argument REFUTES the candidate — the
                    // raw `Iterable<T>` judged String-vs-T as "own tp,
                    // anything goes" and falsely proved it. Substitute what
                    // the receiver binds, then judge; unbound params keep
                    // the raw path.
                    var judged_param = param.ty;
                    var subst_param: ?TypeRef = null;
                    if (arg.ty != null and
                        self.staticTypeContainsFuncParam(fid, param.ty))
                    {
                        if (self.instantiatedTypeFromReceiverPartial(
                            sa,
                            fid,
                            param.ty,
                            scoped_receiver,
                        ) catch null) |s| {
                            subst_param = s;
                            judged_param = s;
                        }
                    }
                    const arg_compatibility = if (subst_param != null and
                        !self.staticTypeContainsFuncParam(fid, judged_param))
                        self.staticGenericArgCompatibility(fid, arg.ty.?, judged_param, 0)
                    else
                        self.staticArgCompatibility(
                            fid,
                            arg,
                            judged_param,
                            ctx.actual_type_param_bounds,
                        );
                    if (rex_trace) {
                        std.debug.print("[rex-arg] {s} fid={d} param={s} arg_ty={s} -> {s} route={s}\n", .{
                            name,
                            fid.int(),
                            param.ty.name,
                            if (arg.ty) |t| t.name else "-",
                            @tagName(arg_compatibility),
                            sac_route,
                        });
                    }
                    if (arg_compatibility == .incompatible) {
                        compatibility = .incompatible;
                        break;
                    }
                    if (arg_compatibility == .unknown) compatibility = .unknown;
                }
            }
            if (compatibility == .incompatible) continue;
            if (rex_trace) std.debug.print("[rex] {s} fid={d} KEPT {s}\n", .{ name, fid.int(), @tagName(compatibility) });
            ids.append(sa, fid) catch return .{};
            tiers.append(sa, tier) catch return .{};
            unknowns.append(sa, compatibility == .unknown) catch return .{};
            named_maps.append(sa, named_map) catch return .{};
            named_skips.append(sa, named_map_skips) catch return .{};
        }
        if (ids.items.len == 0) {
            return .{ .applicable = unknown_best_tier != 255 };
        }

        var proof_receiver = scoped_receiver;
        const receiver_alias = self.staticAliasHead(proof_receiver);
        if (receiver_alias.changed and !receiver_alias.structure_lost) {
            proof_receiver.name = receiver_alias.name;
        }
        const proof_args = sa.dupe(applicability.ArgShape, args) catch return .{};
        for (proof_args) |*arg| {
            arg.named = null;
            if (arg.ty) |*ty| {
                const alias = self.staticAliasHead(ty.*);
                if (alias.changed and !alias.structure_lost) ty.name = alias.name;
            }
        }
        const sigs = sa.alloc(applicability.SigView, ids.items.len) catch return .{};
        for (ids.items, 0..) |fid, i| {
            const f = self.funcById(fid).?;
            // A named-mapped candidate presents COMPACTED parameters: the
            // scorer judges positionally, so each argument's slot must hold
            // the parameter its name bound, not the raw declaration order.
            const params = if (named_maps.items[i]) |mp| blk_cp: {
                const cp = sa.alloc(Param, mp.len + 1) catch return .{};
                cp[0] = f.params[0];
                for (mp, cp[1..]) |pj, *dst| dst.* = f.params[pj];
                break :blk_cp cp;
            } else sa.dupe(Param, f.params) catch return .{};
            if (params.len != 0) {
                const declared_receiver = if (self.decl_sigs.get(fid.int())) |decl|
                    decl.receiver_ty orelse params[0].ty
                else
                    params[0].ty;
                const decl_file = if (self.decl_span.get(fid.int())) |decl_source|
                    decl_source.file
                else
                    null;
                params[0].ty = self.resolveTypeAliasAt(
                    sa,
                    declared_receiver,
                    decl_file,
                    f.package,
                ) catch return .{};
            }
            for (params) |*param| {
                const alias = self.staticAliasHead(param.ty);
                if (alias.changed and !alias.structure_lost) param.ty.name = alias.name;
            }
            sigs[i] = .{
                .params = params,
                .has_body = true,
                .low_priority = rankLowPriority(f),
                .is_extension = true,
                .fid = fid,
                .package = f.package,
            };
        }
        const scope = applicability.ApplicabilityScope{
            .member = true,
            .rank_extensions = true,
            .is_extension = true,
            .receiver = .{ .ty = proof_receiver },
            .all_candidates = sigs,
            .ctx = @ptrCast(@constCast(self)),
            .ext_is_subtype_name = evidenceSubtypeCb,
            .type_var = staticTypeVar,
        };

        var best_tier: u8 = 255;
        for (sigs, tiers.items) |*sig, tier| {
            const score = applicability.applicable(sig, proof_args, scope) orelse continue;
            if (score.ext_key.?[0] != 0 and tier < best_tier) best_tier = tier;
        }
        if (best_tier == 255) {
            if (runtime.envSetOnce("KLIO_REX_TRACE")) {
                if (applicability.trace_call_span) |sp| std.debug.print("[rex-exit] {s} no-applicable-tier at=f{d}:{d}\n", .{ name, sp.file.int(), sp.start });
            }
            return .{};
        }
        // A same-or-inner-tier declaration whose visibility metadata is not
        // complete cannot be compared safely with the ranked set.
        if (unknown_best_tier <= best_tier) {
            if (runtime.envSetOnce("KLIO_REX_TRACE")) {
                if (applicability.trace_call_span) |sp| std.debug.print("[rex-exit] {s} unknown-tier {d}<={d} at=f{d}:{d}\n", .{ name, unknown_best_tier, best_tier, sp.file.int(), sp.start });
            }
            return .{ .applicable = true };
        }

        var ranked_sigs: std.ArrayList(applicability.SigView) = .empty;
        var ranked_ids: std.ArrayList(FuncId) = .empty;
        var ranked_unknowns: std.ArrayList(bool) = .empty;
        for (sigs, ids.items, tiers.items, unknowns.items) |sig, fid, tier, unknown| {
            if (tier != best_tier) continue;
            ranked_sigs.append(sa, sig) catch return .{};
            ranked_ids.append(sa, fid) catch return .{};
            ranked_unknowns.append(sa, unknown) catch return .{};
        }
        var ranked_scope = scope;
        ranked_scope.all_candidates = ranked_sigs.items;

        var any_ordinary = false;
        for (ranked_sigs.items) |*sig| {
            const score = applicability.applicable(sig, proof_args, ranked_scope) orelse continue;
            if (score.ext_key.?[0] != 0 and !score.low_priority) any_ordinary = true;
        }
        var best: ?FuncId = null;
        var best_key: [9]i32 = .{std.math.minInt(i32)} ** 9;
        var best_unknown = false;
        var best_recv_param: ?TypeRef = null;
        var best_fid_for_recv: ?FuncId = null;
        var tied = false;
        var tied_ids: std.ArrayList(FuncId) = .empty;
        for (ranked_sigs.items, ranked_ids.items, ranked_unknowns.items) |*sig, fid, unknown| {
            const maybe_score = applicability.applicable(sig, proof_args, ranked_scope);
            if (maybe_score == null and runtime.envSetOnce("KLIO_REX_TRACE")) {
                if (applicability.trace_call_span) |sp| std.debug.print("[rex-key] {s} fid={d} DISQUALIFIED at=f{d}:{d}\n", .{ name, fid.int(), sp.file.int(), sp.start });
            }
            const score = maybe_score orelse continue;
            const key = score.ext_key.?;
            if (runtime.envSetOnce("KLIO_REX_TRACE")) {
                if (applicability.trace_call_span) |sp| {
                    std.debug.print("[rex-key] {s} fid={d} key={any} low={} unknown={} at=f{d}:{d}\n", .{ name, fid.int(), key, score.low_priority, unknown, sp.file.int(), sp.start });
                } else {
                    std.debug.print("[rex-key] {s} fid={d} key={any} low={} unknown={}\n", .{ name, fid.int(), key, score.low_priority, unknown });
                }
            }
            if (key[0] == 0 or (any_ordinary and score.low_priority)) continue;
            if (best == null or extensionKeyGreater(key, best_key)) {
                best = fid;
                best_key = key;
                best_unknown = unknown;
                best_recv_param = if (sig.params.len != 0) sig.params[0].ty else null;
                best_fid_for_recv = fid;
                tied = false;
                tied_ids.clearRetainingCapacity();
                tied_ids.append(sa, fid) catch return .{};
            } else if (extensionKeyEquivalent(key, best_key)) {
                tied = true;
                tied_ids.append(sa, fid) catch return .{};
            }
        }
        const renamed_best = if (best) |target|
            self.renamedImportDenotesFunc(
                ctx.call_name orelse name,
                ctx.caller_file,
                target,
            )
        else
            false;
        // A renamed import fixes the declaration family by exact FQN. Once
        // ordinary applicability selects one overload from that family, an
        // unknown argument type does not erase the identity; receiver/member
        // precedence is still decided by `emitFormFor`.
        const receiver_supplies_lambda = if (best) |target|
            ranked_sigs.items.len == 1 and
                self.genericReceiverSuppliesLambdaReceiver(target, args)
        else
            false;
        // Every other candidate was ELIMINATED by proof and exactly one
        // remains: kotlinc commits it — an unproven receiver instantiation
        // does not change that there is nothing else the call could resolve
        // to. Guarded to receivers that carry explicit type arguments
        // (`Array<T>`), so a bare conservative head keeps the withhold.
        const sole_off = if (std.c.getenv("KLIO_SOLE_EXT")) |v|
            std.mem.eql(u8, std.mem.span(v), "0")
        else
            false;
        // A member-refuted call may commit its sole survivor only when the
        // candidate is declared in the CALLER'S OWN FILE — the file-private
        // shape (Select.kt's tryResume) kotlinc must bind, and narrow
        // enough that cross-file stdlib chains keep their deferral
        // (a wider member_refuted commit re-broke trimIndent).
        const sole_same_file = ids.items.len == 1 and blk: {
            const sp = self.decl_span.get(ids.items[0].int()) orelse break :blk false;
            break :blk sp.file.int() == ctx.caller_file.int();
        };
        const sole_survivor = !sole_off and ids.items.len == 1 and
            ranked_sigs.items.len == 1 and scoped_receiver.args.len != 0 and
            (receiver_pruned != 0 or (ctx.member_refuted and sole_same_file));
        // The widened member-refuted commit: when the MEMBER was refuted by
        // an authoritative argument, the strict ext_key winner commits even
        // with an unproven receiver instantiation — every supplied argument
        // is authoritative (unauthoritative args cannot refute a member, so
        // reaching here with member_refuted implies authority), the key
        // strictly beat every rival (untied), and kotlinc has no member to
        // prefer. The trimIndent hazard was the FILE-blind sole rule
        // without key strictness; this rule requires both.
        var refuted_args_authoritative = true;
        for (proof_args) |pa| {
            if (pa.ty == null and pa.literal_kind == null and
                !pa.is_lambda and pa.lambda_arity == null)
            {
                refuted_args_authoritative = false;
                break;
            }
        }
        // The winner's declared receiver must RELATE to the static
        // receiver (same head, proven subtype, or the winner's own type
        // parameter): an argument-keyed winner on an unrelated receiver is
        // exactly the over-commit that put a Map-family extension on a
        // Sequence (SequenceTest.flatten).
        const winner_recv_related = blk: {
            const brp = best_recv_param orelse break :blk false;
            var wh = applicability.simpleName(staticTypeHead(std.mem.trimEnd(u8, brp.name, "?")));
            if (std.mem.startsWith(u8, wh, "out#")) wh = wh["out#".len..];
            if (std.mem.startsWith(u8, wh, "in#")) wh = wh["in#".len..];
            const bfid = best_fid_for_recv orelse break :blk false;
            if (self.funcTypeParamIndex(bfid, wh) != null) break :blk true;
            if (wh.len > 0 and wh.len <= 2 and std.ascii.isUpper(wh[0])) break :blk true;
            const rh = applicability.simpleName(staticTypeHead(std.mem.trimEnd(u8, scoped_receiver.name, "?")));
            if (rh.len == 0) break :blk false;
            if (std.mem.eql(u8, rh, wh)) break :blk true;
            if (evidenceSubtypeCb(@ptrCast(@constCast(self)), rh, wh)) break :blk true;
            for (applicability.builtinSupersOf(rh)) |sup| {
                if (std.mem.eql(u8, sup, wh)) break :blk true;
            }
            break :blk false;
        };
        const refuted_member_strict_winner = ctx.member_refuted and
            best != null and !tied and refuted_args_authoritative and
            winner_recv_related;
        if (tied or
            (best_unknown and !receiver_supplies_lambda and !renamed_best and
                !sole_survivor and !refuted_member_strict_winner))
            return .{
                .applicable = true,
                .sole_unknown = if (!tied) best else null,
                .param_rep = if (tied) self.tiedLambdaParamRep(tied_ids.items) else null,
            };
        // A winner whose named arguments SKIPPED defaulted parameters COMMITS:
        // the emitted Call carries the argument names, and the host boundary
        // binds them by declaration parameter — callFuncNamed fills a
        // defaultless hole before a bound slot with Null (the convention the
        // natives read as "defaulted") instead of dropping the bound tail,
        // and the incompatible-receiver guard knows the full builtin family
        // (`ByteArray` was classified a user class, which stripped the names
        // off `decodeToString(throwOnInvalidSequence = true)` on re-dispatch).
        // `KLIO_NAMED_COMMIT=0` demotes back to the typing-only channel for
        // single-binary A/B.
        if (best) |target| {
            for (ids.items, named_skips.items) |fid, skipped| {
                if (fid != target) continue;
                if (skipped and
                    std.mem.eql(u8, runtime.envOnce("KLIO_NAMED_COMMIT") orelse "1", "0"))
                    return .{ .applicable = true, .sole_unknown = target };
                break;
            }
        }
        const dispatch_owner = if (best) |target|
            (if (self.registry.member_ext_owner_class.get(target)) |owner|
                self.classIdByFqn(owner)
            else
                null)
        else
            null;
        return .{
            .target = best,
            .dispatch_owner = dispatch_owner,
            .applicable = best != null,
        };
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
        var unknown: ?FuncId = null;
        var unknown_count: usize = 0;
        var visibility_unknown = false;
        var any_applicable = false;
        // A `@Deprecated(level = ERROR|HIDDEN)` member is not a source-level
        // candidate while an ordinary same-name member exists: kotlinc never
        // binds `Updater.set(value: Int, ...)` (HIDDEN) beside the generic
        // `set(value: V, ...)`, and counting it as a second unknown for a
        // type-parameter-shaped argument left the call with no target at all.
        // Kept as the last resort for a name whose every overload is hidden,
        // mirroring `funcId`.
        var any_ordinary = false;
        for (candidates.items) |candidate| {
            const cf = self.funcById(candidate.fid) orelse continue;
            if (!cf.deprecated_error) {
                any_ordinary = true;
                break;
            }
        }
        for (candidates.items) |candidate| {
            const fid = candidate.fid;
            const ds = self.decl_sigs.get(fid.int()) orelse continue;
            if (any_ordinary) {
                if (self.funcById(fid)) |cf| if (cf.deprecated_error) continue;
            }
            if (ds.kind != .instance_method) continue;
            const declared_owner = ds.enclosing_class orelse owner;
            if (ds.visibility == .Private and
                (ctx.lexical_owner == null or
                    !self.lexicalChainContains(ctx.lexical_owner.?, declared_owner))) continue;
            if (ds.visibility == .Protected) {
                const lexical = ctx.lexical_owner orelse continue;
                // Kotlin exposes a protected declaration only within its
                // declaring class hierarchy, and a subclass may access it
                // only through a receiver from that subclass hierarchy.
                const access_owner = self.protectedAccessOwner(
                    lexical,
                    declared_owner,
                ) orelse continue;
                if (!self.classIdIsOrExtends(owner, access_owner)) continue;
            }
            if (ctx.private_only and ds.visibility != .Private) continue;
            const f = self.funcById(fid) orelse continue;
            // A bodyless member header that lists no value parameters yet
            // (an interface member such as `Map.get(key)` before its body
            // lowers) is judged by its DECLARED arity: an applicable member
            // outranks any same-named extension, and treating it as
            // inapplicable let `Map<out K, V>.get` bind `map[key]` and call
            // itself from its own body.
            const lists_this = f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this");
            const listed_values = f.params.len - @intFromBool(lists_this);
            if (ds.arity.total != 0 and listed_values < ds.arity.required and (!f.hasBody() or listed_values < ds.arity.total)) {
                if (args.len >= ds.arity.required and (args.len <= ds.arity.total or ds.arity.has_vararg)) {
                    if (std.c.getenv("KLIO_RMC_TRACE")) |w| {
                        if (std.mem.eql(u8, std.mem.span(w), name)) std.debug.print("[rmc] {s} cand={s}#{d} STUB-UNKNOWN params={d} body={} required={d} total={d}\n", .{ name, f.fqn, fid.int(), f.params.len, f.hasBody(), ds.arity.required, ds.arity.total });
                    }
                    any_applicable = true;
                    unknown = fid;
                    unknown_count += 1;
                }
                continue;
            }
            const sig = applicability.SigView{
                .params = f.params,
                // Member resolution may bind an abstract declaration to a
                // virtual slot; executability belongs to dispatch, not
                // overload applicability.
                .has_body = true,
                .low_priority = rankLowPriority(f),
                .is_member = true,
                .fid = fid,
                .package = f.package,
            };
            const score = applicability.applicable(&sig, args, scope) orelse continue;
            if (ds.visibility == .Internal) {
                const caller_file = ctx.caller_file orelse {
                    any_applicable = true;
                    visibility_unknown = true;
                    continue;
                };
                if (self.internalVisibleFrom(fid, caller_file)) |visible| {
                    if (!visible) continue;
                } else {
                    any_applicable = true;
                    visibility_unknown = true;
                    continue;
                }
            }
            const rmc_verdict = self.staticMemberArgsCompatibility(
                sa,
                fid,
                f,
                args,
                ctx.actual_type_param_bounds,
                ctx.receiver_type,
            );
            if (runtime.envOnce("KLIO_RMC_TRACE")) |w| {
                if (std.mem.eql(u8, w, name))
                    std.debug.print("[rmc] {s} cand={s}#{d} verdict={s} params={d} body={}\n", .{ name, f.fqn, fid.int(), @tagName(rmc_verdict), f.params.len, f.hasBody() });
            }
            switch (rmc_verdict) {
                .incompatible => continue,
                .unknown => {
                    any_applicable = true;
                    unknown = fid;
                    unknown_count += 1;
                    continue;
                },
                .compatible => {},
            }
            any_applicable = true;
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
                // Redeclarations of one virtual family are not an overload
                // tie: `Set.iterator` overrides `Collection.iterator`
                // overrides `Iterable.iterator`, and every one of them names
                // the same slot family. Keep the overriding declaration; a
                // genuine tie between unrelated members still defers.
                const existing = best.?;
                var family = false;
                if (self.decl_sigs.get(fid.int())) |cs| if (cs.enclosing_class) |co| {
                    if (self.overridesSlot(sa, co, fid, existing) catch false) {
                        best = fid;
                        family = true;
                    }
                };
                if (!family) if (self.decl_sigs.get(existing.int())) |es| if (es.enclosing_class) |eo| {
                    if (self.overridesSlot(sa, eo, existing, fid) catch false) family = true;
                };
                if (!family) {
                    // DIAMOND family: neither declaration overrides the
                    // other, but both override one slot the RESOLUTION
                    // owner inherits (`AbstractMutableCollection` sees
                    // `iterator` from both `AbstractCollection` and
                    // `MutableCollection`). Kotlin merges these into one
                    // intersection slot; keep the declaration with the
                    // more specific return type.
                    const cand_o = self.overridesSlot(sa, owner, fid, existing) catch false;
                    const exist_o = self.overridesSlot(sa, owner, existing, fid) catch false;
                    if (cand_o or exist_o) {
                        family = true;
                        const cf = self.funcById(fid);
                        const ef = self.funcById(existing);
                        if (cf != null and ef != null and
                            self.staticReceiverCompatibility(null, cf.?.return_ty, ef.?.return_ty) == .compatible and
                            self.staticReceiverCompatibility(null, ef.?.return_ty, cf.?.return_ty) != .compatible)
                        {
                            best = fid;
                        }
                    }
                }
                if (!family) tied = true;
            }
        }
        if (visibility_unknown or tied or unknown_count != 0 and best != null) {
            return .{ .applicable = any_applicable };
        }
        if (best == null) {
            if (unknown_count == 1) {
                return .{ .target = unknown, .dispatch = .deferred, .applicable = true };
            }
            return .{ .applicable = any_applicable };
        }
        const target = best.?;
        const ds = self.decl_sigs.get(target.int()).?;
        // Native/expect/abstract headers identify an overload but do not carry
        // the ordinary IR-function ABI required by a direct FuncId call.
        if (!ds.has_body) return .{ .target = target, .dispatch = .virtual, .applicable = true };
        if (ds.visibility == .Private) return .{ .target = target, .dispatch = .direct, .applicable = true };
        const f = self.funcById(target) orelse return .{};
        // An unclaimed classifier header carries no trustworthy final/open/
        // interface modifiers. Its declaration identity can still resolve the
        // overload, but dispatch must remain virtual until the class is filled.
        if (class.is_stub) return .{ .target = target, .dispatch = .virtual, .applicable = true };
        const declaring_class = if (ds.enclosing_class) |decl_owner|
            (if (decl_owner.int() < self.classes.items.len) &self.classes.items[decl_owner.int()] else null)
        else
            null;
        // The DECLARING class may still be an unclaimed header when the
        // owner's bodies lower ahead of it (a pack's `AbstractEncoder`
        // lowered before `Encoder` was filled): its `is_interface` reads
        // false and the interface default bound direct, so the implementing
        // class's override never ran. Unknown declarer: virtual.
        const declared_on_interface = if (declaring_class) |decl| (decl.is_interface or decl.is_stub) else true;
        // An enum class is extensible by its entries' bodies, which override
        // its `open`/`abstract` members: only a final member is bound direct.
        const closed_class = !class.is_open and !class.is_abstract and !class.is_enum;
        const direct = !class.is_interface and (closed_class or (!declared_on_interface and methodIsFinal(f)));
        if (std.c.getenv("KLIO_DISPATCH_TRACE")) |w| {
            if (std.mem.eql(u8, std.mem.span(w), name)) std.debug.print("[dispatch] {s} owner={s} iface={} open={} abstract={} stub={} decl_owner={s} decl_iface={} decl_stub={} final={} -> {s}\n", .{ name, class.fqn, class.is_interface, class.is_open, class.is_abstract, class.is_stub, if (declaring_class) |d| d.fqn else "-", declared_on_interface, if (declaring_class) |d| d.is_stub else false, methodIsFinal(f), if (direct) "direct" else "virtual" });
        }
        if (direct) {
            return .{ .target = target, .dispatch = .direct, .applicable = true };
        }
        return .{ .target = target, .dispatch = .virtual, .applicable = true };
    }

    /// The `direct` vs `virtual` choice for an already-identified target,
    /// factored out of `resolveMemberCall` so a caller that promotes a
    /// deferred-but-identified resolution reaches the SAME answer instead of
    /// assuming `virtual`. Assuming virtual is wrong for a final or private
    /// method: it has no vtable slot at all, and the call fails at runtime with
    /// "virtual method slot is not linked for receiver class" even when the
    /// receiver's class is exactly the declaring one.
    pub fn dispatchForTarget(self: *const Module, owner: ClassId, target: FuncId) ?MemberDispatch {
        if (owner.int() >= self.classes.items.len) return null;
        const class = &self.classes.items[owner.int()];
        const ds = self.decl_sigs.get(target.int()) orelse return null;
        if (!ds.has_body) return .virtual;
        if (ds.visibility == .Private) return .direct;
        const f = self.funcById(target) orelse return null;
        // An unclaimed classifier header carries no trustworthy final/open/
        // interface modifiers: every flag reads false whether the class is
        // closed or merely unlowered, so "closed and final" cannot be told
        // from "unknown". Answer virtual, exactly as `resolveMemberCall`
        // does — reading the placeholder as closed bound a defaulted
        // INTERFACE member by fid and the implementing class's override
        // never ran (`SerializersModuleCollector.contextual`, whose default
        // forwards to the provider overload, registered every serializer as
        // a provider). Value classes never reach here as stubs; their
        // receivers take the ordinary final-class rule below.
        if (class.is_stub) return .virtual;
        const declaring_class = if (ds.enclosing_class) |decl_owner|
            (if (decl_owner.int() < self.classes.items.len) &self.classes.items[decl_owner.int()] else null)
        else
            null;
        const declared_on_interface = if (declaring_class) |decl| (decl.is_interface or decl.is_stub) else true;
        if (!class.is_interface and ((!class.is_open and !class.is_abstract and !class.is_enum) or (!declared_on_interface and methodIsFinal(f)))) {
            return .direct;
        }
        return .virtual;
    }

    fn methodIsFinal(f: *const Func) bool {
        if (f.is_open) return false;
        if (f.is_override and !f.is_final) return false;
        return true;
    }

    fn internalVisibleFrom(
        self: *const Module,
        fid: FuncId,
        caller_file: FileId,
    ) ?bool {
        const caller_module = self.registry.file_modules.get(caller_file);
        const decl_file = if (self.decl_span.get(fid.int())) |decl|
            decl.file
        else
            self.registry.private_fn_files.get(fid) orelse return null;
        const declaration_module = self.registry.file_modules.get(decl_file);
        if (caller_module == null or declaration_module == null) return null;
        return caller_module.? == declaration_module.?;
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

    pub const TypeBinding = struct {
        name: []const u8,
        ty: TypeRef,
        /// The call site wrote this type argument out. Kotlin takes an
        /// explicit argument as final and does not infer the parameter from
        /// the value arguments at all, so a later value argument may be a
        /// SUBTYPE of it without contradicting it.
        explicit: bool = false,
    };

    fn bindingType(bindings: []const TypeBinding, name: []const u8) ?TypeRef {
        for (bindings) |binding| {
            if (std.mem.eql(u8, binding.name, name)) return binding.ty;
        }
        return null;
    }

    fn bindingIsExplicit(bindings: []const TypeBinding, name: []const u8) bool {
        for (bindings) |binding| {
            if (std.mem.eql(u8, binding.name, name)) return binding.explicit;
        }
        return false;
    }

    fn widenBinding(bindings: []TypeBinding, name: []const u8, ty: TypeRef) void {
        for (bindings) |*binding| {
            if (std.mem.eql(u8, binding.name, name)) binding.ty = ty;
        }
    }

    /// Engine helper for external consumers: substitute `ty` through a
    /// solved binding set (arena-scoped result).
    pub fn substituteBoundType(allocator: Allocator, ty: TypeRef, bindings: []const TypeBinding) Allocator.Error!TypeRef {
        return substituteType(allocator, ty, bindings);
    }

    fn substituteType(allocator: Allocator, ty: TypeRef, bindings: []const TypeBinding) Allocator.Error!TypeRef {
        const projection_prefix: ?[]const u8 = if (std.mem.startsWith(u8, ty.name, "out#"))
            "out#"
        else if (std.mem.startsWith(u8, ty.name, "in#"))
            "in#"
        else
            null;
        const binding_name = if (projection_prefix) |prefix| ty.name[prefix.len..] else ty.name;
        if (overrideQualifiedPath(ty) == null and
            std.mem.indexOfScalar(u8, ty.name, '.') == null)
        {
            if (bindingType(bindings, binding_name)) |replacement| {
                var out = replacement;
                if (projection_prefix) |prefix| {
                    out.name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, replacement.name });
                }
                out.nullable = out.nullable or ty.nullable;
                return out;
            }
        }
        const args = try allocator.alloc(TypeRef, ty.args.len);
        for (ty.args, args) |arg, *out| out.* = try substituteType(allocator, arg, bindings);
        return .{ .name = ty.name, .nullable = ty.nullable, .args = args };
    }

    fn callTypeParam(
        params: []const []const u8,
        name: []const u8,
    ) bool {
        const head = staticTypeHead(name);
        for (params) |param| {
            if (std.mem.eql(u8, param, head)) return true;
        }
        return false;
    }

    fn callTypeRefParam(
        params: []const []const u8,
        ty: TypeRef,
    ) bool {
        if (overrideQualifiedPath(ty) != null or
            std.mem.indexOfScalar(u8, ty.name, '.') != null) return false;
        return callTypeParam(params, ty.name);
    }

    pub fn projectTypeToClass(
        self: *const Module,
        allocator: Allocator,
        actual: TypeRef,
        target: ClassId,
    ) Allocator.Error!?TypeRef {
        const actual_id = self.staticTypeClassId(actual) orelse return null;
        if (!self.classIdIsOrExtends(actual_id, target)) return null;
        if (actual_id.int() >= self.classes.items.len or
            target.int() >= self.classes.items.len) return null;

        const actual_class = &self.classes.items[actual_id.int()];
        const actual_args = overrideArgs(actual);
        if (actual_args.len < actual_class.type_params.len) return null;
        if (actual_id.int() == target.int()) return actual;

        const identity = try allocator.alloc(TypeBinding, actual_class.type_params.len * 2);
        for (actual_class.type_params, 0..) |param, i| {
            const identity_name = try classTypeParamIdentity(allocator, actual_id, param);
            identity[i * 2] = .{ .name = param, .ty = actual_args[i] };
            identity[i * 2 + 1] = .{ .name = identity_name, .ty = actual_args[i] };
        }
        const inherited = (try self.ancestorBindings(
            allocator,
            actual_id,
            target,
            identity,
            0,
        )) orelse return null;
        const target_class = &self.classes.items[target.int()];
        const projected_args = try allocator.alloc(TypeRef, target_class.type_params.len);
        for (target_class.type_params, 0..) |param, i| {
            projected_args[i] = bindingType(
                inherited,
                try classTypeParamIdentity(allocator, target, param),
            ) orelse return null;
        }
        return .{
            .name = target_class.fqn,
            .nullable = actual.nullable,
            .args = projected_args,
        };
    }

    fn bindCallType(
        self: *const Module,
        allocator: Allocator,
        raw_pattern: TypeRef,
        raw_actual: TypeRef,
        params: []const []const u8,
        bindings: *std.ArrayList(TypeBinding),
        depth: u8,
    ) Allocator.Error!bool {
        if (depth >= 64) return false;
        const pattern_projection = projectionType(try self.staticAliasType(allocator, raw_pattern, 0));
        const actual_projection = projectionType(try self.staticAliasType(allocator, raw_actual, 0));
        if (pattern_projection.star) return true;
        const pattern = pattern_projection.ty;
        const actual = actual_projection.ty;
        const pattern_head = staticTypeHead(pattern.name);
        if (callTypeRefParam(params, pattern)) {
            if (bindingType(bindings.items, pattern_head)) |bound| {
                // `arrayOf<Base>(Derived())`: the written argument decides the
                // parameter, and the value being a subtype of it is exactly
                // what the call means. Demanding equality here rejected the
                // whole instantiation and left the receiver untyped.
                if (bindingIsExplicit(bindings.items, pattern_head)) return true;
                if (bound.eql(actual)) return true;
                // Kotlin infers the parameter from every constraint together,
                // so a constraint one side already subsumes narrows nothing:
                // `m.getOrDefault(k, Derived())` on a Map<K, Base> means
                // V=Base with the value argument a subtype of it, and
                // `listOf(Derived(), base)` means T=Base by the same rule.
                // Keep the subsuming side; genuinely unrelated constraints
                // (kotlinc would compute a common supertype) still refuse.
                const lub_off = if (std.c.getenv("KLIO_BIND_LUB")) |v|
                    std.mem.eql(u8, std.mem.span(v), "0")
                else
                    false;
                // `Nothing?` is the null literal's type and the bottom of the
                // lattice, so it constrains nothing but nullability: Kotlin
                // reads `listOf(null, "foo")` as `List<String?>`. Widen to the
                // other constraint and carry the nullability across, in either
                // order. Without this the pair binds nothing, the call has no
                // return type, and every use of the result is left untyped.
                if (std.mem.eql(u8, staticTypeHead(bound.name), "Nothing")) {
                    var widened = actual;
                    widened.nullable = widened.nullable or bound.nullable;
                    widenBinding(bindings.items, pattern_head, widened);
                    return true;
                }
                if (std.mem.eql(u8, staticTypeHead(actual.name), "Nothing")) {
                    if (actual.nullable and !bound.nullable) {
                        var widened = bound;
                        widened.nullable = true;
                        widenBinding(bindings.items, pattern_head, widened);
                    }
                    return true;
                }
                const bound_plain = overrideArgs(bound).len == 0;
                const actual_plain = overrideArgs(actual).len == 0;
                if (!lub_off and bound_plain and actual_plain) {
                    const bound_head = staticTypeHead(bound.name);
                    const actual_head = staticTypeHead(actual.name);
                    if ((!actual.nullable or bound.nullable) and
                        self.classIsOrExtends(actual_head, bound_head)) return true;
                    if ((!bound.nullable or actual.nullable) and
                        self.classIsOrExtends(bound_head, actual_head))
                    {
                        widenBinding(bindings.items, pattern_head, actual);
                        return true;
                    }
                }
                return false;
            }
            try bindings.append(allocator, .{ .name = pattern_head, .ty = actual });
            return true;
        }

        const pattern_args = overrideArgs(pattern);
        if (pattern_args.len == 0) return true;
        var projected_actual = actual;
        if (!self.staticTypesShareClassifier(pattern, actual)) {
            // Same-head types with no class row behind the head (the
            // synthetic `Function{N}` family) bind structurally by
            // position: `Function1<Int, T>` against `Function1<Int, Int>`
            // binds `T` even though no classifier backs `Function1`.
            const same_head = std.mem.eql(u8, pattern_head, staticTypeHead(actual.name));
            if (!same_head or self.staticTypeClassId(pattern) != null) {
                const pattern_id = self.staticTypeClassId(pattern) orelse return false;
                projected_actual = (try self.projectTypeToClass(
                    allocator,
                    actual,
                    pattern_id,
                )) orelse return false;
            }
        }
        if (projected_actual.nullable and !pattern.nullable) return false;
        const actual_args = overrideArgs(projected_actual);
        if (pattern_args.len != actual_args.len) return false;
        for (pattern_args, actual_args) |pattern_arg, actual_arg| {
            if (!try self.bindCallType(
                allocator,
                pattern_arg,
                actual_arg,
                params,
                bindings,
                depth + 1,
            )) return false;
        }
        return true;
    }

    fn returnTypeBindingsComplete(
        ty: TypeRef,
        params: []const []const u8,
        bindings: []const TypeBinding,
    ) bool {
        const head = staticTypeHead(ty.name);
        if (callTypeRefParam(params, ty) and bindingType(bindings, head) == null) return false;
        for (overrideArgs(ty)) |arg| {
            if (!returnTypeBindingsComplete(arg, params, bindings)) return false;
        }
        return true;
    }

    fn typeContainsBoundParam(
        ty: TypeRef,
        bounds: []const ModuleRegistry.TypeParamBound,
    ) bool {
        if (typeRefIsDeclaredParam(bounds, ty)) return true;
        for (overrideArgs(ty)) |arg| {
            if (typeContainsBoundParam(arg, bounds)) return true;
        }
        return false;
    }

    fn declaredTypeParamBounds(
        self: *const Module,
        allocator: Allocator,
        fid: FuncId,
    ) Allocator.Error![]const ModuleRegistry.TypeParamBound {
        const params = self.registry.func_type_params.get(fid) orelse return &.{};
        const bounds = try allocator.alloc(ModuleRegistry.TypeParamBound, params.items.len);
        const explicit = self.registry.func_type_param_bounds.get(fid) orelse &.{};
        // The param list can carry a DUPLICATE name when a declaration
        // registered through both the header phase and body placement; one
        // record per NAME, or the multi-bound arms downstream refuse a
        // single-parameter declaration (`Iterable<T>.minus` read bounds=2
        // and staticGenericReceiverApplicable declined every candidate).
        var n: usize = 0;
        outer: for (params.items) |param| {
            for (bounds[0..n]) |seen| {
                if (std.mem.eql(u8, seen.param, param)) continue :outer;
            }
            bounds[n] = .{ .param = param, .bound = "kotlin.Any" };
            for (explicit) |bound| {
                if (std.mem.eql(u8, bound.param, param)) {
                    bounds[n].bound = bound.bound;
                    bounds[n].complete = bound.complete;
                    bounds[n].head_only = bound.head_only;
                    break;
                }
            }
            n += 1;
        }
        return bounds[0..n];
    }

    /// Instantiate the structural return type of an already-resolved call.
    /// The target identity comes from the shared call resolver; this step only
    /// binds its declaration-owned type parameters from explicit type
    /// arguments and the statically-known argument types.
    /// Whether `ty` (recursively) names any of `params` — raw source
    /// spellings, the form a declared return type carries.
    fn typeMentionsAnyParamName(ty: *const TypeRef, params: []const []const u8) bool {
        const head = staticTypeHead(std.mem.trimEnd(u8, ty.name, "?"));
        for (params) |p| {
            if (std.mem.eql(u8, head, p)) return true;
        }
        for (ty.args) |*arg| {
            if (typeMentionsAnyParamName(arg, params)) return true;
        }
        return false;
    }

    pub fn instantiatedCallReturnType(
        self: *const Module,
        allocator: Allocator,
        fid: FuncId,
        receiver: ?TypeRef,
        dispatch_receiver: ?TypeRef,
        args: []const applicability.ArgShape,
        explicit_type_args: []const TypeRef,
    ) Allocator.Error!?TypeRef {
        return self.instantiatedCallReturnTypeScoped(
            allocator,
            fid,
            receiver,
            dispatch_receiver,
            args,
            explicit_type_args,
            false,
        );
    }

    /// `owner_params_in_scope`: the CALLER's body is (lexically inside) the
    /// target's own class, so the owner's type parameters are names the
    /// caller resolves — a bare-head implicit-this projection keeps them as
    /// THEMSELVES instead of erasing to `*`: `val data = createFrom(...)`
    /// inside `IterableTests<T : Iterable<String>>` types `data: T`, which
    /// the bound-ref channel then resolves.
    /// The substitution engine's CORE: solve every callee type-parameter
    /// binding one call site offers — explicit type args, the owner
    /// projection, the receiver, named and positional/vararg arguments,
    /// and the star erasure for what stays open. Consumers substitute
    /// whatever slot they need against the result. Arena-scoped: the
    /// bindings borrow `a` and the module.
    pub const SolvedBindings = struct {
        bindings: []TypeBinding,
        type_params: []const []const u8,
    };
    pub fn solveCallBindings(
        self: *const Module,
        a: Allocator,
        fid: FuncId,
        f: *const Func,
        receiver: ?TypeRef,
        dispatch_receiver: ?TypeRef,
        args: []const applicability.ArgShape,
        explicit_type_args: []const TypeRef,
        owner_params_in_scope: bool,
    ) Allocator.Error!?SolvedBindings {
        const type_params_list = self.registry.func_type_params.get(fid);
        const function_type_params: []const []const u8 = if (type_params_list) |list|
            list.items
        else
            &.{};
        if (explicit_type_args.len > function_type_params.len) return null;

        var bindings: std.ArrayList(TypeBinding) = .empty;
        for (explicit_type_args, 0..) |ty, i| {
            try bindings.append(a, .{
                .name = function_type_params[i],
                .ty = ty,
                .explicit = true,
            });
        }

        var all_type_params: std.ArrayList([]const u8) = .empty;
        try all_type_params.appendSlice(a, function_type_params);
        const decl_sig = self.decl_sigs.get(fid.int());
        const owner_id = if (decl_sig) |sig| sig.enclosing_class else null;
        if (owner_id) |owner| {
            if (owner.int() >= self.classes.items.len) return null;
            const owner_class = &self.classes.items[owner.int()];
            for (owner_class.type_params) |param| {
                try all_type_params.append(
                    a,
                    try classTypeParamIdentity(a, owner, param),
                );
            }
            const actual_dispatch_receiver: ?TypeRef = switch (decl_sig.?.kind) {
                .instance_method => dispatch_receiver orelse receiver,
                .member_extension => dispatch_receiver,
                else => null,
            };
            if (owner_class.type_params.len != 0 and
                actual_dispatch_receiver != null)
            {
                const actual_receiver = actual_dispatch_receiver.?;
                const projected_ok = blk2: {
                    const projected = (try self.projectTypeToClass(
                        a,
                        actual_receiver,
                        owner,
                    )) orelse break :blk2 false;
                    const projected_args = overrideArgs(projected);
                    if (projected_args.len < owner_class.type_params.len) break :blk2 false;
                    for (owner_class.type_params, 0..) |param, i| {
                        try bindings.append(a, .{
                            .name = try classTypeParamIdentity(a, owner, param),
                            .ty = projected_args[i],
                        });
                    }
                    break :blk2 true;
                };
                // A bare receiver HEAD (an implicit `this` in a method body)
                // carries no type arguments to project — but a return that
                // never mentions the class's parameters is complete without
                // them (`findClause(...): ClauseData?` on a bare
                // SelectImplementation head). A param-mentioning return
                // erases the unknown parameters to star projections instead
                // of refusing: `iterator()` on a bare `Iterable` head yields
                // `Iterator<*>`, whose HEAD is what the initialized local
                // needs to bind its `hasNext()`/`next()`, and `*` is
                // applicability-neutral downstream. `KLIO_STAR_RET=0`
                // disables.
                if (!projected_ok) {
                    // The return may reference the owner's parameters by RAW
                    // name or by the class-param IDENTITY mangle (an
                    // inherited interface header's `Iterator<E>` carries
                    // `$class$ N i:E` in its args) — test both, or the star
                    // fill skips exactly the headers the completeness check
                    // then refuses (`Set.iterator` stayed underivable).
                    const mentions = blk_m: {
                        if (typeMentionsAnyParamName(&f.return_ty, owner_class.type_params)) break :blk_m true;
                        for (owner_class.type_params) |param| {
                            const ident = try classTypeParamIdentity(a, owner, param);
                            if (typeMentionsAnyParamName(&f.return_ty, &.{ident})) break :blk_m true;
                        }
                        break :blk_m false;
                    };
    if (mentions) {
                        if (std.mem.eql(u8, runtime.envOnce("KLIO_STAR_RET") orelse "1", "0")) return null;
                        for (owner_class.type_params) |param| {
                            try bindings.append(a, .{
                                .name = try classTypeParamIdentity(a, owner, param),
                                .ty = if (owner_params_in_scope)
                                    .{ .name = param, .nullable = false, .args = &.{} }
                                else
                                    .{ .name = "*", .nullable = false, .args = &.{} },
                            });
                        }
                    }
                }
            }
        }
        if (runtime.envSetOnce("KLIO_ICRT")) {
            std.debug.print("[icrt] fn={s} ret={s} ret_args={d} decl_sig={} kind={s} owner={} owner_tps={d} fn_tps={d} bindings={d}\n", .{
                f.fqn,
                f.return_ty.name,
                f.return_ty.args.len,
                decl_sig != null,
                if (decl_sig) |sig| @tagName(sig.kind) else "-",
                owner_id != null,
                if (owner_id) |o| (if (o.int() < self.classes.items.len) self.classes.items[o.int()].type_params.len else 999) else 0,
                function_type_params.len,
                bindings.items.len,
            });
        }
        if (runtime.envSetOnce("KLIO_ICRT")) {
            if (f.return_ty.args.len != 0) std.debug.print("[icrt2] {s} arg0={s}\n", .{ f.fqn, f.return_ty.args[0].name });
            if (owner_id) |o| {
                if (o.int() < self.classes.items.len) {
                    for (self.classes.items[o.int()].type_params) |tp| std.debug.print("[icrt2] {s} owner_tp={s}\n", .{ f.fqn, tp });
                }
            }
        }
        const type_params = all_type_params.items;
        const inference_type_params = if (decl_sig != null and
            decl_sig.?.kind == .member_extension)
            function_type_params
        else
            type_params;

        const first_param: usize = @intFromBool(funcHasImplicitThis(f));
        // An extension receiver written head-only (a bare implicit `this`)
        // cannot bind the declared receiver's type parameters; the erasure
        // pass below substitutes `*` for the still-unbound ones instead of
        // refusing, exactly as the owner-projection arm above does for
        // members. A receiver WITH arguments that fails to bind is a real
        // mismatch and still refuses here.
        if (first_param != 0 and
            (decl_sig == null or decl_sig.?.kind != .instance_method))
        {
            if (receiver) |actual_receiver| {
                // Project the actual receiver onto the DECLARED head first:
                // a List<String> receiver binds an Iterable<K> pattern
                // (K := String) instead of head-mismatching into a refusal —
                // the same rule the splice window and the sibling-expected
                // solve already apply.
                var recv_eff = actual_receiver;
                if (self.staticTypeClassId(f.params[0].ty)) |dcid| {
                    if (try self.projectTypeToClass(a, actual_receiver, dcid)) |projected| {
                        recv_eff = projected;
                    }
                }
                if (!try self.bindCallType(
                    a,
                    f.params[0].ty,
                    recv_eff,
                    function_type_params,
                    &bindings,
                    0,
                )) {
                    if (actual_receiver.args.len != 0 or
                        std.mem.eql(u8, runtime.envOnce("KLIO_STAR_RET") orelse "1", "0"))
                        return null;
                }
            }
        }
        const params = f.params[first_param..];
        const filled = try a.alloc(bool, params.len);
        @memset(filled, false);

        // Named arguments establish their slots before positional/vararg
        // binding, matching Kotlin's call binding order.
        for (args) |arg| {
            const name = arg.named orelse continue;
            const actual = arg.ty orelse continue;
            for (params, 0..) |param, pi| {
                if (!std.mem.eql(u8, param.name, name)) continue;
                if (filled[pi]) return null;
                if (!try self.bindCallType(
                    a,
                    param.ty,
                    actual,
                    inference_type_params,
                    &bindings,
                    0,
                )) {
                    if (runtime.envSetOnce("KLIO_ICRT")) std.debug.print("[icrt] {s}: named bind refused param={s}({s} nargs={d}) actual={s} nargs={d}\n", .{ f.fqn, param.name, param.ty.name, overrideArgs(param.ty).len, actual.name, overrideArgs(actual).len });
                    return null;
                }
                filled[pi] = true;
                break;
            }
        }

        var next_param: usize = 0;
        for (args, 0..) |arg, ai| {
            if (arg.named != null) continue;
            const actual = arg.ty orelse continue;

            // A trailing callable binds to a trailing function parameter even
            // when defaulted parameters precede it.
            var pi: usize = next_param;
            if (arg.is_lambda and ai + 1 == args.len and params.len != 0 and
                std.mem.startsWith(u8, params[params.len - 1].ty.name, "Function") and
                !filled[params.len - 1])
            {
                pi = params.len - 1;
            } else {
                while (pi < params.len and filled[pi]) pi += 1;
                while (pi < params.len and params[pi].is_vararg) {
                    var remaining_positional: usize = 0;
                    for (args[ai..]) |tail_arg| {
                        if (tail_arg.named == null) remaining_positional += 1;
                    }
                    var required_tail: usize = 0;
                    for (params[pi + 1 ..], pi + 1..) |tail_param, tail_i| {
                        if (!filled[tail_i] and !tail_param.is_vararg and
                            !tail_param.has_default) required_tail += 1;
                    }
                    if (remaining_positional > required_tail) break;
                    pi += 1;
                    while (pi < params.len and filled[pi]) pi += 1;
                }
            }
            if (pi >= params.len) return null;

            var actual_ty = actual;
            if (params[pi].is_vararg and arg.is_spread and
                std.mem.eql(u8, staticTypeHead(actual.name), "Array") and
                overrideArgs(actual).len == 1)
            {
                actual_ty = overrideArgs(actual)[0];
            }
            if (!try self.bindCallType(
                a,
                params[pi].ty,
                actual_ty,
                inference_type_params,
                &bindings,
                0,
            )) {
                if (runtime.envSetOnce("KLIO_ICRT")) std.debug.print("[icrt] {s}: positional bind refused param={s}({s} nargs={d}) actual={s} nargs={d}\n", .{ f.fqn, params[pi].name, params[pi].ty.name, overrideArgs(params[pi].ty).len, actual_ty.name, overrideArgs(actual_ty).len });
                return null;
            }
            if (!params[pi].is_vararg) {
                filled[pi] = true;
                next_param = pi + 1;
            } else {
                next_param = pi;
            }
        }

        // A function type parameter still unbound after the receiver and every
        // argument had their chance erases to `*` rather than refusing the
        // whole return: `MutableList(3) { ... }` (a receiver-less generic
        // factory whose lambda carries no inferred type) yields
        // `MutableList<*>` — the HEAD binds the local's member calls, and `*`
        // is applicability-neutral downstream. A hard bind CONFLICT still
        // refused above; this only covers absence. A result erased to a bare
        // `*` head is refused below as before.
        if (!std.mem.eql(u8, runtime.envOnce("KLIO_STAR_RET") orelse "1", "0")) {
            for (function_type_params) |tp| {
                var bound = false;
                for (bindings.items) |bd| {
                    if (std.mem.eql(u8, bd.name, tp)) {
                        bound = true;
                        break;
                    }
                }
                if (!bound) try bindings.append(a, .{
                    .name = tp,
                    .ty = .{ .name = "*", .nullable = false, .args = &.{} },
                });
            }
        }
        return .{ .bindings = bindings.items, .type_params = type_params };
    }

    pub fn instantiatedCallReturnTypeScoped(
        self: *const Module,
        allocator: Allocator,
        fid: FuncId,
        receiver: ?TypeRef,
        dispatch_receiver: ?TypeRef,
        args: []const applicability.ArgShape,
        explicit_type_args: []const TypeRef,
        owner_params_in_scope: bool,
    ) Allocator.Error!?TypeRef {
        const f = self.funcById(fid) orelse return null;
        // An unannotated source function currently carries Unit as its
        // lowering placeholder. Do not present that placeholder as static
        // receiver evidence.
        if (std.mem.eql(u8, staticTypeHead(f.return_ty.name), "Unit")) return null;

        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const a = scratch.allocator();

        const solved = (try self.solveCallBindings(
            a,
            fid,
            f,
            receiver,
            dispatch_receiver,
            args,
            explicit_type_args,
            owner_params_in_scope,
        )) orelse return null;
        const bindings_items = solved.bindings;
        const type_params = solved.type_params;
        if (!returnTypeBindingsComplete(f.return_ty, type_params, bindings_items)) {
            if (runtime.envSetOnce("KLIO_ICRT")) std.debug.print("[icrt] {s}: bindings incomplete\n", .{f.fqn});
            return null;
        }
        const substituted = try substituteType(a, f.return_ty, bindings_items);
        // A return erased to a bare `*` head names nothing a caller can bind
        // against; it would only pollute the local's declared-type record.
        if (std.mem.eql(u8, staticTypeHead(substituted.name), "*")) {
            if (runtime.envSetOnce("KLIO_ICRT")) std.debug.print("[icrt] {s}: star head\n", .{f.fqn});
            return null;
        }
        if (runtime.envSetOnce("KLIO_ICRT")) std.debug.print("[icrt] {s}: OK -> {s}\n", .{ f.fqn, substituted.name });
        return try substituted.clone(allocator);
    }

    /// Instantiate a declared type of extension `fid` from the ACTUAL
    /// receiver: bind the declaration's receiver parameter against
    /// `receiver`, then substitute into `ty`. Null when the declaration has
    /// no receiver or type parameters, nothing binds, or the substitution
    /// stays incomplete — the caller keeps its explicit-args answer.
    /// `Iterable<T>.count(predicate: (T) -> Boolean)` on an
    /// `Iterable<String>` receiver instantiates `(String) -> Boolean`.
    /// The substitution engine's receiver leg, shared by both entry
    /// points: solve the callee's type parameters from the ACTUAL
    /// receiver against the declared one, substitute into `ty`.
    /// `require_complete` demands every parameter `ty` mentions be
    /// bound (the return-type contract); without it the parameters the
    /// receiver proves substitute and the rest stay as written (the
    /// lambda-param contract — its consumer refuses leftover bare
    /// heads itself).
    fn instantiatedTypeFromReceiverImpl(
        self: *const Module,
        allocator: Allocator,
        fid: FuncId,
        ty: TypeRef,
        receiver: TypeRef,
        require_complete: bool,
    ) Allocator.Error!?TypeRef {
        const f = self.funcById(fid) orelse return null;
        if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) return null;
        const tp_list = self.registry.func_type_params.get(fid);
        const tps: []const []const u8 = if (tp_list) |list| list.items else &.{};
        if (tps.len == 0) return null;
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        var bindings: std.ArrayList(TypeBinding) = .empty;
        if (!try self.bindCallType(a, f.params[0].ty, receiver, tps, &bindings, 0)) return null;
        if (bindings.items.len == 0) return null;
        if (require_complete and !returnTypeBindingsComplete(ty, tps, bindings.items)) return null;
        const substituted = try substituteType(a, ty, bindings.items);
        return try substituted.clone(allocator);
    }

    pub fn instantiatedTypeFromReceiver(
        self: *const Module,
        allocator: Allocator,
        fid: FuncId,
        ty: TypeRef,
        receiver: TypeRef,
    ) Allocator.Error!?TypeRef {
        return self.instantiatedTypeFromReceiverImpl(allocator, fid, ty, receiver, true);
    }

    /// `instantiatedTypeFromReceiver` without the completeness requirement:
    /// substitute the parameters the receiver DOES bind and leave the rest
    /// as written. For a `minOfWith(comparator) { selector }` the receiver
    /// binds `T` but not the return-only `R`; the lambda-param consumer
    /// needs the value-param portion (`T`), and its own guard refuses any
    /// entry whose head stayed a bare parameter.
    pub fn instantiatedTypeFromReceiverPartial(
        self: *const Module,
        allocator: Allocator,
        fid: FuncId,
        ty: TypeRef,
        receiver: TypeRef,
    ) Allocator.Error!?TypeRef {
        return self.instantiatedTypeFromReceiverImpl(allocator, fid, ty, receiver, false);
    }

    /// Instantiate an arbitrary type owned by a resolved declaration from
    /// explicit call-site type arguments. Returns null while any declaration
    /// type parameter used by `ty` remains unbound.
    pub fn instantiatedDeclarationType(
        self: *const Module,
        allocator: Allocator,
        fid: FuncId,
        ty: TypeRef,
        explicit_type_args: []const TypeRef,
    ) Allocator.Error!?TypeRef {
        const type_params_list = self.registry.func_type_params.get(fid);
        const type_params: []const []const u8 = if (type_params_list) |list|
            list.items
        else
            &.{};
        if (explicit_type_args.len > type_params.len) return null;

        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        var bindings: std.ArrayList(TypeBinding) = .empty;
        for (explicit_type_args, 0..) |explicit, i| {
            try bindings.append(a, .{ .name = type_params[i], .ty = explicit });
        }
        if (!returnTypeBindingsComplete(ty, type_params, bindings.items)) return null;
        const substituted = try substituteType(a, ty, bindings.items);
        return try substituted.clone(allocator);
    }

    fn ancestorBindings(
        self: *const Module,
        allocator: Allocator,
        current: ClassId,
        target: ClassId,
        current_bindings: []const TypeBinding,
        depth: u8,
    ) Allocator.Error!?[]const TypeBinding {
        if (current.int() == target.int()) {
            var exact_count: usize = 0;
            for (current_bindings) |binding| {
                if (parseClassTypeParamIdentity(binding.name) != null) exact_count += 1;
            }
            const exact = try allocator.alloc(TypeBinding, exact_count);
            var exact_index: usize = 0;
            for (current_bindings) |binding| {
                if (parseClassTypeParamIdentity(binding.name) == null) continue;
                exact[exact_index] = binding;
                exact_index += 1;
            }
            return exact;
        }
        if (depth > 64 or current.int() >= self.classes.items.len) return null;
        const class = &self.classes.items[current.int()];
        for (class.supertypes, 0..) |super_id, edge| {
            if (super_id.int() >= self.classes.items.len) continue;
            const super = &self.classes.items[super_id.int()];
            const super_ref: ?TypeRef = if (edge < class.supertype_refs.len) class.supertype_refs[edge] else null;
            const next = try allocator.alloc(TypeBinding, super.type_params.len * 2);
            for (super.type_params, 0..) |param, i| {
                const identity_name = try classTypeParamIdentity(
                    allocator,
                    super_id,
                    param,
                );
                const supplied: TypeRef = if (super_ref) |ref|
                    (if (i < ref.args.len) ref.args[i] else .{ .name = identity_name, .nullable = false, .args = &.{} })
                else
                    .{ .name = identity_name, .nullable = false, .args = &.{} };
                const supplied_ty = try substituteType(
                    allocator,
                    supplied,
                    current_bindings,
                );
                next[i * 2] = .{ .name = param, .ty = supplied_ty };
                next[i * 2 + 1] = .{ .name = identity_name, .ty = supplied_ty };
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

    /// `KLIO_OVERRIDES_TRACE=1`: report why `overridesSlot` rejected a
    /// candidate. Called once per (own method, inherited slot) pair, so the
    /// lookup is resolved once rather than per call.
    fn overridesTraceOn() bool {
        const S = struct {
            var known: ?bool = null;
        };
        if (S.known) |k| return k;
        const k = runtime.envSetOnce("KLIO_OVERRIDES_TRACE");
        S.known = k;
        return k;
    }

    /// Class declared directly inside `scope`, matched on the full
    /// `scope.name` FQN rather than on a simple name, so an unrelated class
    /// sharing the simple name cannot answer.
    fn classIdDeclaredIn(self: *const Module, scope: []const u8, name: []const u8) ?ClassId {
        for (self.classes.items) |class| {
            if (class.fqn.len != scope.len + name.len + 1) continue;
            if (std.mem.startsWith(u8, class.fqn, scope) and
                class.fqn[scope.len] == '.' and
                std.mem.eql(u8, class.fqn[scope.len + 1 ..], name))
            {
                return class.id;
            }
        }
        return null;
    }

    fn overrideTypeClassId(self: *const Module, fid: FuncId, name: []const u8) ?ClassId {
        if (self.classIdByFqn(name) orelse self.classIdByQualifiedSuffix(name)) |id| return id;
        const sig = self.decl_sigs.get(fid.int()) orelse return null;
        const owner = sig.enclosing_class orelse return null;
        if (self.classIdNestedIn(owner, applicability.simpleName(name))) |id| return id;
        if (owner.int() >= self.classes.items.len) return null;
        // An unqualified classifier written inside a nested class resolves in
        // the enclosing classes' scopes too, so widen outwards along the
        // owner's FQN instead of stopping at the owner itself. `Key` written
        // in `CoroutineContext.Element` names `CoroutineContext.Key`; without
        // this walk the two spellings of one parameter type compare unequal
        // and an override goes unrecognised.
        var scope = self.classes.items[owner.int()].fqn;
        while (true) {
            if (self.classIdDeclaredIn(scope, name)) |id| return id;
            const dot = std.mem.lastIndexOfScalar(u8, scope, '.') orelse break;
            scope = scope[0..dot];
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
        const dbg = overridesTraceOn();
        const candidate_func = self.funcById(candidate) orelse return false;
        const base_func = self.funcById(base) orelse return false;
        if (dbg) std.debug.print("[ovr] cand={d} base={d} name={s}/{s} is_override={}\n", .{
            candidate.int(), base.int(), candidate_func.name, base_func.name, candidate_func.is_override,
        });
        if (!candidate_func.is_override or !std.mem.eql(u8, candidate_func.name, base_func.name)) return false;
        const candidate_sig = self.decl_sigs.get(candidate.int()) orelse {
            if (dbg) std.debug.print("[ovr]   no candidate sig\n", .{});
            return false;
        };
        const base_sig = self.decl_sigs.get(base.int()) orelse {
            if (dbg) std.debug.print("[ovr]   no base sig\n", .{});
            return false;
        };
        if (candidate_sig.kind != .instance_method or base_sig.kind != .instance_method) {
            if (dbg) std.debug.print("[ovr]   kind {s}/{s}\n", .{ @tagName(candidate_sig.kind), @tagName(base_sig.kind) });
            return false;
        }
        if (candidate_sig.is_suspend != base_sig.is_suspend or candidate_sig.sig.len != base_sig.sig.len) {
            if (dbg) std.debug.print("[ovr]   siglen {d}/{d}\n", .{ candidate_sig.sig.len, base_sig.sig.len });
            return false;
        }
        const base_owner = base_sig.enclosing_class orelse {
            if (dbg) std.debug.print("[ovr]   no base owner\n", .{});
            return false;
        };

        const owner_class = &self.classes.items[owner.int()];
        const identity = try allocator.alloc(TypeBinding, owner_class.type_params.len * 2);
        for (owner_class.type_params, 0..) |param, i| {
            const identity_name = try classTypeParamIdentity(
                allocator,
                owner,
                param,
            );
            const identity_ty = TypeRef{
                .name = identity_name,
                .nullable = false,
                .args = &.{},
            };
            identity[i * 2] = .{ .name = param, .ty = identity_ty };
            identity[i * 2 + 1] = .{ .name = identity_name, .ty = identity_ty };
        }
        const bindings = (try self.ancestorBindings(allocator, owner, base_owner, identity, 0)) orelse {
            if (dbg) std.debug.print("[ovr]   no ancestor bindings owner={s} base_owner={s}\n", .{
                self.classes.items[owner.int()].fqn, self.classes.items[base_owner.int()].fqn,
            });
            return false;
        };
        for (candidate_sig.sig, base_sig.sig) |candidate_ty, raw_base_ty| {
            const base_ty = try substituteType(allocator, raw_base_ty, bindings);
            if (!self.overrideTypeEql(candidate, base, candidate_ty, base_ty)) {
                if (dbg) std.debug.print("[ovr]   type mismatch {s} vs {s}\n", .{ candidate_ty.name, base_ty.name });
                return false;
            }
        }
        if (dbg) std.debug.print("[ovr]   OK\n", .{});
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
        if (std.c.getenv("KLIO_SLOT_TRACE")) |want| {
            const w = std.mem.span(want);
            const chosen = gop.value_ptr.*;
            const en = if (self.funcById(existing)) |f| f.name else "?";
            if (std.mem.eql(u8, w, "*") or std.mem.eql(u8, w, en)) {
                std.debug.print(
                    "[slot-merge] slot={d} existing={d} incoming={d} -> {d} ({s})\n",
                    .{ slot, existing.int(), incoming.int(), chosen.int(), en },
                );
            }
        }
    }

    /// Point a slot left naming a bodyless interface declaration at the bodied
    /// implementation the class holds for the same member under another slot.
    /// A redeclared interface member owns a slot of its own —
    /// `MutableList.remove` redeclares `MutableCollection.remove` — while the
    /// implementing body arrives through a different supertype edge keyed by
    /// the base declaration's slot (`AbstractMutableCollection.remove`), so
    /// nothing else connects the two and the redeclaration's slot dispatches
    /// into an unexecutable header. Class-owned bodyless declarations are left
    /// alone: those are host-linked members, not unmet requirements.
    fn unifyRedeclaredSlots(
        self: *const Module,
        allocator: Allocator,
        map: *std.AutoHashMap(u32, FuncId),
    ) Allocator.Error!void {
        if (map.count() < 2) return;
        var it = map.iterator();
        while (it.next()) |entry| {
            const target = entry.value_ptr.*;
            const sig = self.decl_sigs.get(target.int()) orelse continue;
            if (sig.has_body) continue;
            const owner = sig.enclosing_class orelse continue;
            if (owner.int() >= self.classes.items.len or
                !self.classes.items[owner.int()].is_interface) continue;
            var candidates = map.iterator();
            while (candidates.next()) |cand| {
                const impl = cand.value_ptr.*;
                if (impl.int() == target.int()) continue;
                const impl_sig = self.decl_sigs.get(impl.int()) orelse continue;
                if (!impl_sig.has_body) continue;
                if (try self.overridesSlot(allocator, owner, target, FuncId.from(cand.key_ptr.*))) {
                    entry.value_ptr.* = impl;
                    break;
                }
            }
        }
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
            if (sig.kind != .instance_method or sig.visibility == .Private) continue;
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
        try self.unifyRedeclaredSlots(allocator, &maps[cid.int()]);
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
                if (std.c.getenv("KLIO_SLOT_DUMP")) |want| {
                    const w = std.mem.span(want);
                    const fid = entry.value_ptr.*;
                    const fname = if (self.funcById(fid)) |f| f.name else "?";
                    if (std.mem.eql(u8, w, fname)) {
                        const owner = if (self.decl_sigs.get(fid.int())) |s| s.enclosing_class else null;
                        std.debug.print("[slot-dump] class={s} slot={d} -> fid={d} owner={s}\n", .{
                            self.classes.items[raw_cid].fqn,
                            entry.key_ptr.*,
                            fid.int(),
                            if (owner) |o| self.classes.items[o.int()].fqn else "?",
                        });
                    }
                }
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
        if (self.eager_call_fids) |*m| m.deinit();
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
            self.unique_simple_cache.deinit(cg);
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
            var type_it = locals.types.valueIterator();
            while (type_it.next()) |ty| ty.deinit(allocator);
            locals.types.deinit();
            locals.nullable.deinit();
            locals.call_returns.deinit();
        }
        if (self.pending_lambda_own_recv_type) |*receiver| receiver.deinit(allocator);
        if (self.pending_lambda_type_params) |params| allocator.free(params);
        if (self.pending_lambda_type_param_bounds) |bounds| allocator.free(bounds);
        if (self.pending_lambda_type_param_bound_refs) |refs| {
            for (refs) |*r| r.ref.deinit(allocator);
            allocator.free(refs);
        }
        if (self.pending_lambda_param_types) |types| {
            for (types) |*ty| ty.deinit(allocator);
            allocator.free(types);
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

    /// Resolve a simple classifier head only when it denotes one class
    /// identity across the whole module universe.
    pub fn uniqueClassIdBySimpleName(self: *const Module, name: []const u8) ?ClassId {
        if (self.class_fqn_map != null) {
            // Finalized module: the simple-name cache was completed by
            // `buildClassIdMap` and runtime lookups are concurrent, so read
            // it lock-free while it still mirrors the (append-only) class
            // list; a post-finalize class addition falls back to the scan.
            if (self.unique_simple_cache_n == self.classes.items.len) {
                const info = self.unique_simple_cache.get(name) orelse return null;
                return if (info.id == class_id_ambiguous) null else info.id;
            }
        } else if (self.lookup_cache_gpa != null) {
            const mut: *Module = @constCast(self);
            if (mut.topUpUniqueSimpleCache()) {
                const info = mut.unique_simple_cache.get(name) orelse return null;
                return if (info.id == class_id_ambiguous) null else info.id;
            } else |_| {}
        }
        var found: ?ClassId = null;
        for (self.classes.items) |class| {
            const name_match = std.mem.eql(u8, class.name, name);
            if (!name_match) {
                if (!std.mem.eql(u8, applicability.simpleName(class.fqn), name)) continue;
                // Nested classes are not bare-name-visible; see the cache
                // builder above.
                if (self.registry.enclosing_class.get(class.name) != null or
                    self.registry.enclosing_class.get(class.fqn) != null) continue;
            }
            if (found) |id| {
                if (id != class.id and
                    !std.mem.eql(u8, self.classes.items[id.int()].fqn, class.fqn)) return null;
            } else {
                found = class.id;
            }
        }
        return found;
    }

    fn topUpUniqueSimpleCache(self: *Module) Allocator.Error!void {
        const gpa = self.lookup_cache_gpa.?;
        while (self.unique_simple_cache_n < self.classes.items.len) : (self.unique_simple_cache_n += 1) {
            const c = self.classes.items[self.unique_simple_cache_n];
            const non_kotlin = !std.mem.eql(u8, c.package, "kotlin") and
                !std.mem.startsWith(u8, c.package, "kotlin.");
            try self.uniqueSimpleInsert(gpa, c.name, c.id, c.fqn, non_kotlin);
            const seg = applicability.simpleName(c.fqn);
            if (!std.mem.eql(u8, seg, c.name)) {
                // A NESTED class is not bare-name-visible outside its
                // enclosing declaration, so its trailing FQN segment must
                // not create simple-name ambiguity (the four unsigned
                // arrays each nest a private `Iterator`, which killed every
                // bare `Iterator` head lookup module-wide).
                const nested = self.registry.enclosing_class.get(c.name) != null or
                    self.registry.enclosing_class.get(c.fqn) != null;
                if (!nested) try self.uniqueSimpleInsert(gpa, seg, c.id, c.fqn, non_kotlin);
            }
        }
    }

    /// Fold one class into the simple-name cache under `key`, replicating
    /// the scans exactly: the first class wins the unique id; a later class
    /// conflicts only when both its id and its FQN differ from the winner's;
    /// one class outside the `kotlin` packages taints the name for
    /// `staticBuiltinIdentity`.
    fn uniqueSimpleInsert(self: *Module, gpa: Allocator, key: []const u8, id: ClassId, fqn: []const u8, non_kotlin: bool) Allocator.Error!void {
        const gop = try self.unique_simple_cache.getOrPut(gpa, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .id = id, .non_kotlin = non_kotlin };
            return;
        }
        gop.value_ptr.non_kotlin = gop.value_ptr.non_kotlin or non_kotlin;
        const cur = gop.value_ptr.id;
        if (cur == class_id_ambiguous or cur == id) return;
        if (!std.mem.eql(u8, self.classes.items[cur.int()].fqn, fqn)) {
            gop.value_ptr.id = class_id_ambiguous;
        }
    }

    /// The `ClassId`s registered under simple `name`, in `class_index`
    /// order — the exact candidate sequence the linear scan visits. Null
    /// when the lazy cache is unavailable (finalized module, no cache
    /// allocator, or OOM); callers then run their scan. `class_index` is
    /// append-only with immutable names, so a growth-counter top-up keeps
    /// the cache an exact mirror.
    pub fn classNameCandidates(self: *const Module, name: []const u8) ?[]const ClassId {
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

        // Complete the simple-name cache while still single-threaded, so the
        // finalized read paths (`uniqueClassIdBySimpleName`,
        // `staticBuiltinIdentity`) can consult it lock-free at run time
        // instead of linear-scanning the class list per dispatch.
        if (self.lookup_cache_gpa == null) self.lookup_cache_gpa = allocator;
        self.topUpUniqueSimpleCache() catch {
            self.unique_simple_cache.clearRetainingCapacity();
            self.unique_simple_cache_n = 0;
        };

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
    /// Typeck's static type head for the expression at `sp`, if recorded AND
    /// resolvable here.
    ///
    /// The checker names classes by their SOURCE simple name; lowering knows
    /// them under file-scoped mangles and package-qualified spellings. A head
    /// this module cannot resolve is worse than no head at all — it displaces
    /// a virtual bind that would have succeeded and lands the site in
    /// `no_class_id` (measured: 550 sites, campaign addendum 61). Builtin
    /// heads carry no class id by design and pass through.
    pub fn eagerTypeOf(self: *const Module, sp: span.Span) ?EagerTypeHead {
        const et = &(self.eager_types orelse return null);
        const head = et.get(sp) orelse return null;
        var h = std.mem.trimEnd(u8, head.name, "?");
        if (std.mem.indexOfScalar(u8, h, '<')) |lt| h = h[0..lt];
        if (h.len == 0) return null;
        if (types_mod.builtinByName(h) != null or applicability.builtinSupersOf(h).len != 0) return head;
        if (std.mem.indexOfScalar(u8, h, '.') != null) {
            if (self.classIdByFqn(h) != null) return head;
            return null;
        }
        if (self.uniqueClassIdBySimpleName(h) != null) return head;
        return null;
    }
    /// The declared shape of the fn-typed lambda param declared at `sp`.
    /// RETIRED as a consumer, deliberately. The recording side is kept for
    /// when this channel is rebuilt; the lookup answers nothing.
    ///
    /// The payload is `{has_receiver, arity}` keyed by a body SPAN, and both
    /// halves of that are unsound as they stand:
    ///
    ///   - The shape itself can be wrong. Two classes named `SlotTable`
    ///     collided in typeck's simple-name table, so callers were told
    ///     `read`'s parameter was `SlotTableReader.() -> T` when it was
    ///     `(reader: SlotReader) -> T`. Arity 0 with a receiver suppressed
    ///     the lambda's implicit `it` and 8 valid references became hard
    ///     errors.
    ///   - The KEY can collide. The compose pass gives every node it
    ///     synthesizes `gen_span = f.span`, so all the generated lambdas in
    ///     one composable share a span. A shape recorded for a real lambda
    ///     at that span is then applied to synthesized ones, rebinding their
    ///     receiver — which reached `and` with the composer as receiver
    ///     (`Vm::call_member 'and' on 'GapComposer'`) across 5 compose tests.
    ///
    /// Bisecting the four eager channels showed this one is the SOLE cause of
    /// every remaining compose failure under eager: with it declining,
    /// CompositionTests is 148/148, MovableContentTests 44/44, and the
    /// stdlib dual gate stays clean. A channel that has produced two
    /// distinct wrong answers and whose removal makes all validation pass
    /// does not get to keep guessing.
    ///
    /// Rebuilding it needs BOTH halves fixed: a payload carrying the real
    /// parameter types (not an arity), and a key that a synthesized node
    /// cannot alias.
    pub fn eagerParamShapeOf(self: *const Module, sp: span.Span) ?EagerParamShape {
        if (true) return null;
        const m = &(self.eager_param_shapes orelse return null);
        return m.get(sp);
    }
    /// Could ANY extension named `name` serve receiver head `head`?
    /// Chain-aware: the head's supertype chain and the builtin-supertype
    /// table are consulted, and generic-receiver extensions answer true
    /// for every head. Conservative on staleness: the index rebuilds when
    /// the declaration index has grown since the last build.
    /// Which part of `extCouldApply` answered yes. Diagnostic only: the answer
    /// is a single bit, but the campaign needs to know WHICH conservatism is
    /// holding a site back before it can be tightened.
    pub const ExtCouldApplyWhy = enum { none, index_stale, generic_receiver, own_head, builtin_super, declared_super };

    /// Merged value-argument counts the extensions of one name on one receiver
    /// head can accept. An extension whose declaration cannot take this call's
    /// argument count is not a candidate for it and so cannot shadow a member.
    pub const ExtArity = struct {
        min: u32 = 0,
        max: u32 = std.math.maxInt(u32),

        fn accepts(self: ExtArity, argc: usize) bool {
            return argc >= self.min and argc <= self.max;
        }

        fn merge(self: ExtArity, other: ExtArity) ExtArity {
            return .{
                .min = @min(self.min, other.min),
                .max = @max(self.max, other.max),
            };
        }
    };

    pub fn extCouldApply(
        self: *Module,
        allocator: Allocator,
        head: []const u8,
        name: []const u8,
        argc: usize,
    ) bool {
        return self.extCouldApplyWhy(allocator, head, name, argc) != .none;
    }

    pub fn extCouldApplyWhy(
        self: *Module,
        allocator: Allocator,
        head: []const u8,
        name: []const u8,
        argc: usize,
    ) ExtCouldApplyWhy {
        if (self.ext_names_by_recv_head == null or self.ext_index_decl_count != self.func_index.items.len) {
            self.rebuildExtIndex(allocator) catch return .index_stale;
        }
        if (self.generic_ext_names.?.get(name)) |arity| {
            if (arity.accepts(argc)) return .generic_receiver;
        }
        const idx = &self.ext_names_by_recv_head.?;
        if (idx.get(head)) |set| {
            if (set.get(name)) |arity| {
                if (arity.accepts(argc)) return .own_head;
            }
        }
        for (applicability.builtinSupersOf(head)) |sup| {
            if (idx.get(sup)) |set| {
                if (set.get(name)) |arity| {
                    if (arity.accepts(argc)) return .builtin_super;
                }
            }
        }
        if (self.registry.class_super_names.get(head)) |chain| {
            for (chain) |sup| {
                if (idx.get(sup)) |set| {
                    if (set.get(name)) |arity| {
                        if (arity.accepts(argc)) return .declared_super;
                    }
                }
            }
        }
        return .none;
    }

    fn mergeExtArity(map: *std.StringHashMap(ExtArity), name: []const u8, arity: ExtArity) Allocator.Error!void {
        const gop = try map.getOrPut(name);
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.merge(arity) else arity;
    }

    fn rebuildExtIndex(self: *Module, allocator: Allocator) Allocator.Error!void {
        if (self.ext_names_by_recv_head) |*m| {
            var vit = m.valueIterator();
            while (vit.next()) |v| v.deinit();
            m.deinit();
        }
        if (self.generic_ext_names) |*m| m.deinit();
        var idx = std.StringHashMap(std.StringHashMap(ExtArity)).init(allocator);
        var gen = std.StringHashMap(ExtArity).init(allocator);
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
            // A declaration without a recorded signature contributes no arity
            // bound, so it keeps the conservative answer for its name.
            const arity: ExtArity = if (ds) |sig| .{
                .min = sig.arity.required,
                .max = if (sig.arity.has_vararg) std.math.maxInt(u32) else sig.arity.total,
            } else .{};
            if (self.funcTypeParamIndex(entry.id, head) != null or
                (head.len <= 2 and headAllUpper(head)))
            {
                try mergeExtArity(&gen, entry.name, arity);
                continue;
            }
            const gop = try idx.getOrPut(head);
            if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap(ExtArity).init(allocator);
            try mergeExtArity(gop.value_ptr, entry.name, arity);
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
    /// The IMAGE-declared target the checker picked for a call, and only
    /// that. A member call must not read the span map beside it: those
    /// records name SOURCE declarations, whose candidate set the checker
    /// sees only in part on any program that loads packs.
    pub fn eagerExternCallTarget(self: *const Module, callee_span: span.Span) ?FuncId {
        const fm = &(self.eager_call_fids orelse return null);
        const fid = fm.get(callee_span) orelse return null;
        if (self.funcById(FuncId.from(fid)) == null) return null;
        return FuncId.from(fid);
    }

    pub fn eagerCallTarget(self: *const Module, callee_span: span.Span) ?FuncId {
        if (self.eager_call_fids) |*fm| {
            if (fm.get(callee_span)) |fid| {
                if (fid < self.funcs.items.len or self.funcById(FuncId.from(fid)) != null) {
                    return FuncId.from(fid);
                }
            }
        }
        const ec = &(self.eager_calls orelse return null);
        const decl = ec.get(callee_span) orelse return null;
        const got = self.funcByDeclSpan(decl);
        if (got == null and runtime.envSetOnce("KLIO_EAGER_HITS")) {
            const n: usize = if (self.func_by_decl_span) |m| m.count() else 0;
            std.debug.print("[EAGER-MISS2] decl f{d}:{d}-{d} not lowered (map n={d})\n", .{ decl.file.int(), decl.start, decl.end, n });
        }
        return got;
    }

    /// Record a lowered declaration's identity (its AST name-span).
    pub fn recordFuncDeclSpan(self: *Module, allocator: Allocator, decl_span: span.Span, id: FuncId) Allocator.Error!void {
        if (self.anon_side) return;
        if (self.func_by_decl_span == null) {
            self.func_by_decl_span = std.AutoHashMap(span.Span, FuncId).init(allocator);
        }
        try self.func_by_decl_span.?.put(decl_span, id);
    }
    /// The FuncId lowered for the declaration at `decl_span`, if any.
    pub fn funcByDeclSpan(self: *const Module, decl_span: span.Span) ?FuncId {
        if (self.anon_side) return null;
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
    pub fn classIdIndexed(self: *const Module, name: []const u8, caller_pkg_in: []const u8, caller_file: FileId) ?ClassId {
        // Scope judgments follow the FILE: a spliced inline body carries
        // donor-file spans, and the donor's own package is the
        // same-package tier for names its body wrote (the geometry
        // `Size(packFloats(...))` ctor inside the inline factory must
        // rank geometry's class, not the recipient package's view).
        const caller_pkg = self.packageOfFile(caller_file) orelse caller_pkg_in;
        var best: ?ClassId = null;
        var best_tier: u8 = 255;
        const cix_trace = blk: {
            const w = runtime.envOnce("KLIO_CIX_TRACE") orelse break :blk false;
            break :blk std.mem.eql(u8, w, name);
        };
        if (self.classNameCandidates(name)) |ids| {
            for (ids) |cid| {
                const c = idGet(Class, self.classes.items, cid.int()) orelse continue;
                const t = self.scopeTier(c.fqn, c.package, name, caller_pkg, caller_file);
                if (cix_trace) std.debug.print("[cix] {s} cand={d} fqn={s} pkg={s} tier={d} caller_pkg={s} file={d}\n", .{ name, cid.int(), c.fqn, c.package, t, caller_pkg, caller_file.int() });
                if (t < best_tier) {
                    best_tier = t;
                    best = cid;
                }
            }
            if (cix_trace) std.debug.print("[cix] {s} candidates-path best={?} tier={d}\n", .{ name, if (best) |b2| b2.int() else null, best_tier });
            if (best_tier > 3 and self.importAliasPathsIn(caller_file, name).len != 0) return null;
            return best;
        }
        if (cix_trace) std.debug.print("[cix] {s} NO candidate list (flat scan)\n", .{name});
        for (self.class_index.items) |entry| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            const c = idGet(Class, self.classes.items, entry.id.int()) orelse continue;
            const t = self.scopeTier(c.fqn, c.package, name, caller_pkg, caller_file);
            if (t < best_tier) {
                best_tier = t;
                best = entry.id;
            }
        }
        // An OUT-OF-SCOPE winner under an explicit import of this name is
        // an incomplete index (cross-pack build order), never kotlinc's
        // pick — the imported declaration would have won. Refuse, so the
        // caller defers and the runtime's complete index decides. Without
        // this the ui-unit pack baked `NewInstance androidx.annotation.Size`
        // for a bare `Size(w, h)` under `import ...geometry.Size` on some
        // bake orders.
        if (best_tier > 3 and self.importAliasPathsIn(caller_file, name).len != 0) return null;
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
                if (rankLowPriority(f)) {
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
                if (rankLowPriority(f)) {
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
            if (rankLowPriority(f)) {
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

    const BareCallCandidateIterator = struct {
        module: *const Module,
        name: []const u8,
        caller_file: FileId,
        simple: []const FuncId,
        simple_index: usize = 0,
        aliases: []const ModuleRegistry.ImportPath,
        alias_index: usize = 0,
        alias_candidates: []const FuncId = &.{},
        alias_candidate_index: usize = 0,
        alias_fqn: []const u8 = "",

        /// A `private` declaration is visible only inside its declaring file
        /// (a private member extension's whole lexical family lives there
        /// too), so a cross-file private candidate is never resolvable —
        /// admitting one let a test class's private
        /// `CoroutineScope.block(context)` shadow-defer every bare `block`
        /// in the program.
        fn visibleFrom(it: *const BareCallCandidateIterator, id: FuncId) bool {
            const decl_file = it.module.registry.private_fn_files.get(id) orelse return true;
            return decl_file.int() == it.caller_file.int();
        }

        fn next(it: *BareCallCandidateIterator) ?FuncId {
            while (it.simple_index < it.simple.len) {
                defer it.simple_index += 1;
                const id = it.simple[it.simple_index];
                if (it.visibleFrom(id)) return id;
            }
            while (true) {
                while (it.alias_candidate_index < it.alias_candidates.len) {
                    const id = it.alias_candidates[it.alias_candidate_index];
                    it.alias_candidate_index += 1;
                    const f = it.module.funcById(id) orelse continue;
                    if (std.mem.eql(u8, f.fqn, it.alias_fqn) and it.visibleFrom(id)) return id;
                }
                if (it.alias_index >= it.aliases.len) return null;

                const path_index = it.alias_index;
                const path = it.aliases[path_index];
                it.alias_index += 1;
                if (path.segs.len == 0) continue;
                const leaf = path.segs[path.segs.len - 1];
                if (std.mem.eql(u8, leaf, it.name)) continue;

                var duplicate = false;
                for (it.aliases[0..path_index]) |previous| {
                    if (std.mem.eql(u8, previous.fqn, path.fqn)) {
                        duplicate = true;
                        break;
                    }
                }
                if (duplicate) continue;

                it.alias_candidates = it.module.funcsBySimpleName(leaf);
                it.alias_candidate_index = 0;
                it.alias_fqn = path.fqn;
            }
        }
    };

    fn bareCallCandidateIterator(
        self: *const Module,
        name: []const u8,
        caller_file: FileId,
    ) BareCallCandidateIterator {
        return .{
            .module = self,
            .name = name,
            .caller_file = caller_file,
            .simple = self.funcsBySimpleName(name),
            .aliases = self.importAliasPathsIn(caller_file, name),
        };
    }

    fn renamedImportDenotesFunc(
        self: *const Module,
        name: []const u8,
        caller_file: FileId,
        target: FuncId,
    ) bool {
        const f = self.funcById(target) orelse return false;
        for (self.importAliasPathsIn(caller_file, name)) |path| {
            if (path.segs.len == 0) continue;
            const leaf = path.segs[path.segs.len - 1];
            if (std.mem.eql(u8, leaf, name)) continue;
            if (std.mem.eql(u8, path.fqn, f.fqn)) return true;
        }
        return false;
    }

    /// Every declaration denoted by a bare source name in this file. This is
    /// the canonical candidate enumeration for calls and function references:
    /// ordinary declarations enter by simple name, renamed imports by exact
    /// FQN, and each declaration identity appears once.
    pub fn bareCallCandidates(
        self: *const Module,
        allocator: Allocator,
        name: []const u8,
        caller_file: FileId,
    ) Allocator.Error![]FuncId {
        var out: std.ArrayList(FuncId) = .empty;
        errdefer out.deinit(allocator);
        var candidate_it = self.bareCallCandidateIterator(name, caller_file);
        while (candidate_it.next()) |id| try out.append(allocator, id);
        return out.toOwnedSlice(allocator);
    }

    pub fn hasBareCallCandidate(
        self: *const Module,
        name: []const u8,
        caller_file: FileId,
    ) bool {
        var candidate_it = self.bareCallCandidateIterator(name, caller_file);
        return candidate_it.next() != null;
    }

    /// Whether any bare-call candidate for `name` is a PLAIN function rather
    /// than an extension. An extension candidate cannot answer a bare call
    /// that supplies no receiver of its receiver type, so a caller deciding
    /// between "the enclosing class's member" and "a top-level function"
    /// must not be talked out of the member by an extension namesake:
    /// kotlinx-io's `Utf8Test` declares both
    /// `assertCodePointDecoded(String, vararg Int)` and
    /// `Buffer.assertCodePointDecoded(Int, String, Int)`, and the latter made
    /// the former's own bare call look like a global.
    pub fn hasNonExtensionBareCallCandidate(
        self: *const Module,
        name: []const u8,
        caller_file: FileId,
    ) bool {
        var candidate_it = self.bareCallCandidateIterator(name, caller_file);
        while (candidate_it.next()) |cand| {
            const f = self.funcById(cand) orelse continue;
            const is_ext = f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this");
            if (!is_ext) return true;
        }
        return false;
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

    /// `funcHasImplicitThis` for a candidate whose header stub carries no
    /// parameters yet (a pack's deferred inline extension): the declaration
    /// signature's receiver says it takes an implicit `this`.
    fn candidateHasImplicitThis(self: *const Module, id: FuncId, f: *const Func) bool {
        if (funcHasImplicitThis(f)) return true;
        // A header stub may list only the value parameters; its declared
        // receiver still makes it an extension, never a plain function.
        const ds = self.decl_sigs.get(id.int()) orelse return false;
        return ds.receiver_ty != null;
    }

    /// The applicability `SigView` for a candidate at LOWERING time
    /// (distinct from the module-internal `SigView` above, which the
    /// index uses only for the `sameUserSig` identity check). Strips a
    /// leading synthesized `this` so the shared scorer ranks value args
    /// against user parameters. A phase-one header whose declaration has a
    /// body is equally rankable: its params already carry the complete types,
    /// defaults, and vararg flags even though its IR blocks are not lowered
    /// yet. An `expect` header is also a valid compile-time target; linking or
    /// runtime execution decides whether an actual implementation exists.
    ///
    /// `func_defaults` lives on `ProgramImage`, not on `Module`, so the
    /// lowering adapter cannot read it; it carries defaults on the params
    /// (`paramHasDefault`'s null-`defaults` fallback).
    fn sigViewForApplicability(
        self: *const Module,
        id: FuncId,
        include_compiler_abi: bool,
    ) ?applicability.SigView {
        const f = self.funcById(id) orelse return null;
        const declared_callable = if (self.decl_sigs.get(id.int())) |ds|
            ds.has_body or ds.host_symbol != null or f.is_expect
        else
            false;
        if (!f.hasBody() and !declared_callable) return null;
        const off: usize = if (funcHasImplicitThis(f)) 1 else 0;
        var end = f.params.len;
        if (!include_compiler_abi and end >= off + 2 and
            std.mem.eql(u8, f.params[end - 2].name, "$composer") and
            std.mem.eql(u8, f.params[end - 1].name, "$changed"))
        {
            end -= 2;
        }
        return .{
            .params = f.params[off..end],
            .defaults = null,
            .has_body = true,
            .low_priority = rankLowPriority(f),
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
        var candidate_it = self.bareCallCandidateIterator(name, caller_file);
        if (candidate_it.next() == null)
            return BareCallResolution.deferred(.no_candidates);

        // Highest-priority tier among the non-extension candidates:
        // body-bearing funcs, plus header stubs with a declared-arity
        // record (rankable without a lowered body).
        var best_tier: u8 = 255;
        var all_ext = true;
        var ext_in_scope = false;
        candidate_it = self.bareCallCandidateIterator(name, caller_file);
        while (candidate_it.next()) |id| {
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
        candidate_it = self.bareCallCandidateIterator(name, caller_file);
        while (candidate_it.next()) |id| {
            const f = self.funcById(id) orelse continue;
            if (self.candidateHasImplicitThis(id, f)) continue;
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
                if (rankLowPriority(f)) {
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
                if (rankLowPriority(f)) {
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
    // `resolveCall` — the single applicability-primary, type-aware,
    // three-tier bare-call resolver.
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
        /// Resolution proved the declaration final through unique
        /// applicability, an explicit cast, an exact receiver, or eager type
        /// evidence. The emitted `Call` is exact, so runtime value types never
        /// reopen that source-level decision.
        target_final: bool = false,
    };

    /// The receiver-context bits the lowerer computes on the FuncBuilder,
    /// passed in so `resolveCall` stays a pure function of (call site, sig
    /// index, receiver context) and never reaches into FuncBuilder. Each
    /// field maps 1:1 to an existing lowering gate.
    pub const ResolveCtx = struct {
        in_receiver_context: bool = false,
        unknown_receiver: bool = false,
        /// The body's only implicit receiver is a FUNCTION-typed extension
        /// receiver (no owner class, no captured `this`), whose member
        /// surface is closed to `invoke`/`call`: no member can shadow the
        /// resolved name, so the member-shadowable gates stand down.
        /// `runSafely(completion) { … }` inside
        /// `(suspend () -> T).startCoroutineCancellable` is the canonical
        /// site — deferring it hands a private INLINE callee to the runtime
        /// walk, which cannot splice it.
        recv_cannot_shadow: bool = false,
        enclosing_has_member: bool = false,
        /// The body's receiver type is statically known (a plain method
        /// body): the member-shadow question was answered precisely by its
        /// own hierarchy in `enclosing_has_member`, so Phase C must not
        /// widen it back through the program-wide member-name universe.
        receiver_known: bool = false,
        has_type_args: bool = false,
        /// A `$composer` binding exists in the current lowering scope. Bare
        /// composable calls can resolve against their source parameter list
        /// before lowering appends the compiler ABI pair.
        has_composer: bool = false,
        cast_pick: ?FuncId = null,
        recv_ty: ?[]const u8 = null,
        recv_type: ?TypeRef = null,
        /// Bounds for type parameters appearing in `recv_type`.
        actual_type_param_bounds: []const ModuleRegistry.TypeParamBound = &.{},
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
        /// Every implicit callable receiver is represented by `recv_type`
        /// and/or `owner_class`, and each hierarchy is complete. Lambda/thunk
        /// bodies and declarations with outer or companion receivers leave
        /// this false.
        receiver_scope_complete: bool = false,
        /// The full implicit-receiver tower's heads (innermost first) when
        /// the lowering context carries one. With `receiver_scope_complete`,
        /// these are the receivers beyond `recv_type`/`owner_class` that the
        /// known-receiver applicability probe must also consult — a lambda
        /// body's scope is complete exactly when its tower enumerates every
        /// level.
        tower: []const ReceiverTowerEntry = &.{},
        /// `receiver_scope_complete` was proven by the TOWER (a lambda/thunk
        /// context), not a plain method body. A tower-unlocked static commit
        /// additionally requires a SOLE candidate: the pre-existing deferral
        /// was the runtime's overload/tier safety net for unproven argument
        /// types, and unlocking it must not let a near-tier pick beat an
        /// applicable far-tier import (`test.text.assertContentEquals(String,
        /// CharSequence)` vs the star-imported Sequence form was the live
        /// break).
        tower_scope: bool = false,
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
        // The declaration kind, not `f.kind`: a phase-1 header stub still
        // carries `.plain` on the Func while the DeclSig knows it is a member
        // extension — reading the stub admitted a test class's private
        // `CoroutineScope.block(context)` as a tier-0 candidate for every
        // bare `block` in the program.
        if (self.declarationKind(id, f) != .member_extension) return false;
        const owner = self.registry.member_ext_owner_class.get(id) orelse return false;
        for (self.registry.object_names.items) |o| {
            if (std.mem.eql(u8, o, owner)) return false;
        }
        const start = ctx_owner orelse return true;
        return !self.classIsOrExtends(start, owner);
    }

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
    /// Whether `owner` (or its hierarchy) declares a member called `name`.
    /// Gates the receiver-implausibility rule above: with no member competitor
    /// there is nothing to prefer, so the extension must stand.
    fn ownerDeclaresMember(self: *const Module, owner: []const u8, name: []const u8) bool {
        if (self.registry.hierarchy_methods.get(owner)) |set| {
            if (set.contains(name)) return true;
        }
        const simple = applicability.simpleName(owner);
        if (!std.mem.eql(u8, simple, owner)) {
            if (self.registry.hierarchy_methods.get(simple)) |set2| {
                if (set2.contains(name)) return true;
            }
        }
        return false;
    }

    fn extReceiverPlausible(self: *const Module, id: FuncId, f: *const Func, owner: ?[]const u8) bool {
        const dbg = if (runtime.envOnce("KLIO_EXT_TRACE")) |w| std.mem.eql(u8, w, f.name) else false;
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

    /// Whether a candidate's declared signature can bind the call's argument
    /// shapes.
    pub fn declSigScore(self: *const Module, fid: FuncId, args: []const applicability.ArgShape) ?applicability.Score {
        const sv = self.sigViewForApplicability(fid, callShapesHaveComposerPair(args)) orelse return .{ .points = 0 };
        const named = !allShapeNamesNull(args);
        return applicability.applicable(&sv, args, .{
            .named = named,
            .recv_external = named,
        });
    }

    pub fn declSigCompatible(self: *const Module, fid: FuncId, args: []const applicability.ArgShape) bool {
        return self.declSigScore(fid, args) != null;
    }

    const ApplicableBarePick = struct {
        target: ?FuncId = null,
        tier: u8 = 255,
        score: applicability.Score = .{ .points = std.math.minInt(i32) },
        unique: bool = false,
        static_complete: bool = false,
        tier_candidates: usize = 0,
    };

    fn bareScoreGreater(a: applicability.Score, b: applicability.Score) bool {
        if (a.points != b.points) return a.points > b.points;
        if (a.exact_arity != b.exact_arity) return a.exact_arity;
        if (a.proven_args != b.proven_args) return a.proven_args > b.proven_args;
        return a.unknown_args < b.unknown_args;
    }

    fn bareScoreEqual(a: applicability.Score, b: applicability.Score) bool {
        return a.points == b.points and
            a.exact_arity == b.exact_arity and
            a.proven_args == b.proven_args and
            a.unknown_args == b.unknown_args;
    }

    /// Compare the argument-to-parameter mapping produced by applicability
    /// against the identity-aware static type proof. Additive eager type heads
    /// are removed from this proof: they may rank candidates, but cannot reject
    /// one or make a target final.
    fn staticBareArgsCompatibility(
        self: *const Module,
        fid: FuncId,
        sig: applicability.SigView,
        args: []const applicability.ArgShape,
        score: applicability.Score,
        actual_bounds: []const ModuleRegistry.TypeParamBound,
    ) StaticCompatibility {
        var result: StaticCompatibility = .compatible;
        var vararg_pos: ?usize = null;
        for (sig.params, 0..) |param, i| {
            if (param.is_vararg) {
                vararg_pos = i;
                break;
            }
        }
        for (args, 0..) |arg_in, i| {
            const param_index: usize = if (score.binding.arg_to_param.len > i)
                score.binding.arg_to_param[i]
            else if (score.binding.trailing_lambda_param) |trailing|
                if (i + 1 == args.len) trailing else if (vararg_pos) |vp|
                    if (i >= vp) vp else i
                else
                    i
            else if (vararg_pos) |vp|
                if (i >= vp) vp else i
            else
                i;
            if (param_index >= sig.params.len) return .unknown;

            var arg = arg_in;
            if (!arg.ty_authoritative) arg.ty = null;
            var param_ty = if (self.decl_sigs.get(fid.int())) |decl|
                if (param_index < decl.sig.len)
                    decl.sig[param_index]
                else
                    sig.params[param_index].ty
            else
                sig.params[param_index].ty;
            if (sig.params[param_index].is_vararg and !arg.is_spread) {
                param_ty = applicability.varargElementRef(&param_ty);
            }
            const compatibility = self.staticArgCompatibility(
                fid,
                arg,
                param_ty,
                actual_bounds,
            );
            if (bargTraceEnv()) |w| {
                if (self.funcById(fid)) |bf| {
                    if (std.mem.eql(u8, w, bf.name)) {
                        std.debug.print("[barg] {s}#{d} arg{d} param={s} arg_ty={s} lam={} -> {s} route={s}\n", .{
                            bf.name,
                            fid.int(),
                            i,
                            param_ty.name,
                            if (arg.ty) |t| t.name else "-",
                            arg.is_lambda,
                            @tagName(compatibility),
                            sac_route,
                        });
                    }
                }
            }
            if (compatibility == .incompatible) return .incompatible;
            if (compatibility == .unknown) result = .unknown;
        }
        return result;
    }

    /// Rank one receiverless or receiver-formed candidate group directly
    /// through the shared applicability engine. Scope selection happens after
    /// applicability: an inapplicable named-import tier does not hide an
    /// applicable declaration in the caller's package.
    fn applicableBarePick(
        self: *const Module,
        name: []const u8,
        candidates: []const FuncId,
        args: []const applicability.ArgShape,
        caller_pkg: []const u8,
        caller_file: FileId,
        ctx: ResolveCtx,
        receiver_formed: bool,
    ) ApplicableBarePick {
        const named = !allShapeNamesNull(args);
        const include_compiler_abi = !ctx.has_composer or callShapesHaveComposerPair(args);
        var arg_to_param = [_]u16{0} ** 64;
        const scope = applicability.ApplicabilityScope{
            .named = named,
            .recv_external = named,
            .arg_to_param_buf = if (named) &arg_to_param else null,
            .ctx = @ptrCast(@constCast(self)),
            .ext_is_subtype_name = evidenceSubtypeCb,
            .type_var = staticTypeVar,
        };
        var best = ApplicableBarePick{};
        const drop_trace = blk: {
            const w = dropTraceEnv() orelse break :blk false;
            break :blk std.mem.eql(u8, w, name);
        };
        for (candidates) |id| {
            const f = self.funcById(id) orelse continue;
            const kind = self.declarationKind(id, f);
            const is_receiver_formed = kind != .plain;
            if (is_receiver_formed != receiver_formed or rankLowPriority(f)) {
                if (drop_trace) std.debug.print("[drop] {s}#{d} form={} lowpri={}\n", .{ name, id.int(), is_receiver_formed != receiver_formed, rankLowPriority(f) });
                continue;
            }
            if (receiver_formed) {
                if (self.memberExtOutOfScope(id, ctx.owner_class)) continue;
                if (ctx.receiver_known and
                    !self.extReceiverPlausible(id, f, ctx.owner_class)) continue;
                // The enclosing extension body's own receiver head is
                // evidence too: `get(index)` inside `Iterable<T>.elementAt`
                // never binds `Map<out K, V>.get`, whatever the owner class.
                if (kind == .top_level_extension) {
                    if (ctx.recv_ty) |rt0| {
                        var rh = applicability.simpleName(std.mem.trimEnd(u8, rt0, "?"));
                        if (std.mem.indexOfScalar(u8, rh, '<')) |lt| rh = rh[0..lt];
                        var plausible = self.extReceiverPlausible(id, f, rh);
                        if (!plausible and ctx.owner_class != null) plausible = self.extReceiverPlausible(id, f, ctx.owner_class);
                        if (!plausible) {
                            for (ctx.tower) |entry| {
                                if (self.extReceiverPlausible(id, f, entry.head)) {
                                    plausible = true;
                                    break;
                                }
                            }
                        }
                        if (!plausible) {
                            if (drop_trace) std.debug.print("[drop] {s}#{d} ext-recv-implausible-body\n", .{ name, id.int() });
                            continue;
                        }
                    }
                }
                // Inside a receiver LAMBDA the receiver types are not "known"
                // in the plain-method-body sense, so the check above is
                // skipped and an extension on an unrelated type can win over
                // the enclosing class's own member: a bare `forEachIndexed`
                // written inside `buildString { … }` bound
                // `CharSequence.forEachIndexed` and iterated the builder the
                // body was appending to.
                //
                // Narrow deliberately. This fires ONLY when the enclosing
                // class really declares a member of this name, so there is a
                // competitor to prefer. Without that guard it also
                // disqualified private stdlib extensions on `String` called
                // from inside stdlib (`parseDigits`, `uuidCheckHyphenAt`),
                // whose receiver context none of these sources capture.
                if (!ctx.receiver_known and ctx.recv_ty != null and ctx.owner_class != null and
                    self.ownerDeclaresMember(ctx.owner_class.?, name))
                {
                    const inner_head = blk_ih: {
                        var h = applicability.simpleName(std.mem.trimEnd(u8, ctx.recv_ty.?, "?"));
                        if (std.mem.indexOfScalar(u8, h, '<')) |lt| h = h[0..lt];
                        break :blk_ih h;
                    };
                    var plausible = self.extReceiverPlausible(id, f, inner_head);
                    if (!plausible) plausible = self.extReceiverPlausible(id, f, ctx.owner_class);
                    if (!plausible) {
                        for (ctx.tower) |entry| {
                            if (self.extReceiverPlausible(id, f, entry.head)) {
                                plausible = true;
                                break;
                            }
                        }
                    }
                    if (!plausible) {
                        if (drop_trace) std.debug.print("[drop] {s}#{d} ext-recv-implausible\n", .{ name, id.int() });
                        continue;
                    }
                }
            }
            const sig = self.sigViewForApplicability(id, include_compiler_abi) orelse {
                if (drop_trace) std.debug.print("[drop] {s}#{d} no-sigview\n", .{ name, id.int() });
                continue;
            };
            const score = applicability.applicable(&sig, args, scope) orelse {
                if (drop_trace) std.debug.print("[drop] {s}#{d} inapplicable-shape\n", .{ name, id.int() });
                continue;
            };
            if (drop_trace) std.debug.print("[keep] {s}#{d} params={d} args={d} recv_formed={} at={?d}\n", .{ name, id.int(), sig.params.len, args.len, receiver_formed, if (applicability.trace_call_span) |sp| sp.start else null });
            // Declared-type evidence disproves a receiver-formed candidate
            // exactly as a plain one: `decodeFromString(serializer, s)`
            // with `s: String` never binds the enclosing `(s: String, mode:
            // Mode)` member extension.
            const static_compatibility = self.staticBareArgsCompatibility(
                id,
                sig,
                args,
                score,
                ctx.actual_type_param_bounds,
            );
            if (static_compatibility == .incompatible) {
                if (drop_trace) std.debug.print("[drop] {s}#{d} static-incompatible\n", .{ name, id.int() });
                continue;
            }
            const tier: u8 = if (kind == .member_extension or kind == .instance_method)
                0
            else
                self.scopeTier(f.fqn, f.package, name, caller_pkg, caller_file);
            if (receiver_formed and tier >= other_package_tier) continue;
            if (tier < best.tier) {
                best = .{
                    .target = id,
                    .tier = tier,
                    .score = score,
                    .unique = true,
                    .static_complete = static_compatibility == .compatible,
                    .tier_candidates = 1,
                };
            } else if (tier == best.tier) {
                best.tier_candidates += 1;
                if (best.target == null or bareScoreGreater(score, best.score)) {
                    best.target = id;
                    best.score = score;
                    best.unique = true;
                    best.static_complete = static_compatibility == .compatible;
                } else if (bareScoreEqual(score, best.score)) {
                    best.unique = false;
                }
            }
        }
        return best;
    }

    /// The in-scope candidate set (scopeTier <= `tier`) in sig-index order,
    /// borrowed from `alloc`. Carried on the virtual / deferred forms for the
    /// runtime member-first walk and the ambiguity / out-of-scope diagnostics.
    fn candidateSet(
        self: *const Module,
        alloc: std.mem.Allocator,
        name: []const u8,
        candidates: []const FuncId,
        caller_pkg: []const u8,
        caller_file: FileId,
        tier: u8,
    ) std.mem.Allocator.Error![]const FuncId {
        if (tier == 255) return &.{};
        var list: std.ArrayList(FuncId) = .empty;
        for (candidates) |id| {
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
    /// `KLIO_BCC_WHY=1`: report why the scoped bare-call candidate set came
    /// back empty. Resolved once — this runs per lowered call site.
    fn bccWhyOn() bool {
        const S = struct {
            var known: ?bool = null;
        };
        if (S.known) |k| return k;
        const k = runtime.envSetOnce("KLIO_BCC_WHY");
        S.known = k;
        return k;
    }

    pub fn boundedCallCandidates(
        self: *const Module,
        alloc: std.mem.Allocator,
        name: []const u8,
        caller_pkg_in: []const u8,
        caller_file: FileId,
        user_arg_count: usize,
    ) std.mem.Allocator.Error!?[]const FuncId {
        const candidates = try self.bareCallCandidates(alloc, name, caller_file);
        defer alloc.free(candidates);
        const dbg = bccWhyOn();
        if (candidates.len == 0) {
            if (dbg) std.debug.print("[bcc] {s} no-candidates\n", .{name});
            return null;
        }
        const caller_pkg = self.packageOfFile(caller_file) orelse caller_pkg_in;
        const first_tier = self.lowestVisibleGlobalTier(
            name,
            candidates,
            caller_pkg,
            caller_file,
        );
        if (first_tier == 255) {
            if (dbg) std.debug.print("[bcc] {s} no-visible-tier n={d}\n", .{ name, candidates.len });
            return null;
        }
        if (first_tier >= other_package_tier) {
            if (dbg) std.debug.print("[bcc] {s} other-package-tier n={d}\n", .{ name, candidates.len });
            return try alloc.alloc(FuncId, 0);
        }
        var list: std.ArrayList(FuncId) = .empty;
        var any_arity_match = false;
        for (candidates) |id| {
            const f = self.funcById(id) orelse continue;
            if (self.declarationKind(id, f) != .plain) continue;
            if (self.bareCallTier(f, name, caller_pkg, caller_file) >= other_package_tier) continue;
            try list.append(alloc, id);
            if (self.globalArityCanBind(id, f, user_arg_count)) any_arity_match = true;
        }
        if (!any_arity_match) {
            if (dbg) std.debug.print("[bcc] {s} no-arity-match n={d} kept={d}\n", .{ name, candidates.len, list.items.len });
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
        const candidates = try self.bareCallCandidates(alloc, name, caller_file);
        defer alloc.free(candidates);
        if (candidates.len == 0) return null;
        const caller_pkg = self.packageOfFile(caller_file) orelse caller_pkg_in;
        const tier = self.lowestVisibleGlobalTier(
            name,
            candidates,
            caller_pkg,
            caller_file,
        );
        if (tier == 255) return null;
        if (tier >= other_package_tier) return try alloc.alloc(FuncId, 0);

        var list: std.ArrayList(FuncId) = .empty;
        for (candidates) |id| {
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
        if (self.decl_sigs.get(id.int())) |ds| {
            // A header stub registered plain but declaring a receiver
            // (`Map<out K, V>.get(key)` before its body lowers) is an
            // extension: judged receiver-formed, never as a bare
            // function of its value parameters.
            if (ds.kind == .plain and ds.receiver_ty != null) return .top_level_extension;
            return ds.kind;
        }
        if (f.kind == .plain and f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) return .top_level_extension;
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
    pub fn globalArityCanBind(self: *const Module, id: FuncId, f: *const Func, want: usize) bool {
        // The compose pass appends ($composer, $changed) to composable
        // signatures. Call sites lower with USER argument counts (the pair
        // is threaded later, or completed at runtime), so the pair never
        // counts toward the REQUIRED arity — excluding an exact-arity
        // composable here left only a vararg sibling in the bounded set and
        // committed the wrong overload. A post-pass site that already
        // carries the pair still binds through the untrimmed total.
        const has_pair = f.params.len >= 2 and
            std.mem.eql(u8, f.params[f.params.len - 1].name, "$changed") and
            std.mem.eql(u8, f.params[f.params.len - 2].name, "$composer");
        if (!has_pair) {
            if (self.decl_sigs.get(id.int())) |ds| {
                if (want < ds.arity.required) return false;
                return ds.arity.has_vararg or want <= ds.arity.total;
            }
        }
        const counted = if (has_pair) f.params[0 .. f.params.len - 2] else f.params;
        var required: usize = 0;
        var total: usize = f.params.len;
        var has_vararg = false;
        for (counted) |p| {
            if (p.is_vararg) {
                has_vararg = true;
            } else if (!p.has_default) {
                required += 1;
            }
        }
        _ = &total;
        if (want < required) return false;
        return has_vararg or want <= total;
    }

    /// The best visible tier among receiverless package-scope functions.
    /// Members and extensions are handled by the receiver leg of
    /// `CallMemberOrGlobal`; allowing them to establish this tier would let an
    /// own-class test method hide an imported top-level function from the
    /// terminal global leg.
    fn lowestVisibleGlobalTier(
        self: *const Module,
        name: []const u8,
        candidates: []const FuncId,
        caller_pkg: []const u8,
        caller_file: FileId,
    ) u8 {
        var best: u8 = 255;
        for (candidates) |id| {
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
    fn lowestVisibleTier(
        self: *const Module,
        name: []const u8,
        candidates: []const FuncId,
        caller_pkg: []const u8,
        caller_file: FileId,
    ) u8 {
        var best: u8 = 255;
        for (candidates) |id| {
            const f = self.funcById(id) orelse continue;
            if (!f.hasBody() and self.stubDeclArity(id) == null) continue;
            const t = self.bareCallTier(f, name, caller_pkg, caller_file);
            if (t < best) best = t;
        }
        return best;
    }

    /// Resolve a bare `name` call to a `Resolution{ target, confidence,
    /// emit_form, candidate_set }` — a pure function of (call site, sig index,
    /// receiver context). Candidate scope and applicability are resolved in one
    /// direction: a proven implicit-receiver extension first, then the first
    /// package/import tier containing an applicable receiverless declaration,
    /// then a conservative receiver-formed fallback. The emit form is derived
    /// from the resulting target and receiver context exactly once.
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
        const candidates = try self.bareCallCandidates(alloc, name, caller_file);
        defer alloc.free(candidates);
        return self.resolveCallCandidates(
            alloc,
            name,
            caller_pkg_in,
            caller_file,
            candidates,
            args,
            last_arg_lambda,
            ctx,
        );
    }

    /// Resolve from a candidate set already enumerated for this source name.
    /// Lowering uses this form when the same set also participates in cast
    /// selection and hidden-ABI retries.
    pub fn resolveCallCandidates(
        self: *const Module,
        alloc: std.mem.Allocator,
        name: []const u8,
        caller_pkg_in: []const u8,
        caller_file: FileId,
        candidates: []const FuncId,
        args: []const applicability.ArgShape,
        last_arg_lambda: bool,
        ctx: ResolveCtx,
    ) std.mem.Allocator.Error!Resolution {
        // Same file-follows-span package rule as `resolveBareCallIndexed`.
        const caller_pkg = self.packageOfFile(caller_file) orelse caller_pkg_in;
        // The symbol index supplies diagnostic classification and the fallback
        // scope when no complete declaration is applicable.
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
        var reason: ?ResolveDeferReason = switch (ires.outcome) {
            .resolved => null,
            .deferred => |r| r,
        };

        var target = ctx.cast_pick;
        var tier: u8 = if (target) |id|
            self.bareCallTierOf(id, name, caller_pkg, caller_file) orelse 255
        else
            255;
        var receiver_matched = false;
        var receiver_extension_applicable = false;
        var target_final = ctx.cast_pick != null;

        if (target == null) {
            const receiver = ctx.recv_type orelse if (ctx.recv_ty) |head|
                TypeRef{ .name = head, .nullable = false, .args = &.{} }
            else
                null;
            if (receiver) |recv| {
                var implicit_owners_buf: [2][]const u8 = undefined;
                var implicit_owners_len: usize = 0;
                implicit_owners_buf[implicit_owners_len] = recv.name;
                implicit_owners_len += 1;
                if (ctx.owner_class) |owner| {
                    if (!std.mem.eql(u8, owner, recv.name)) {
                        implicit_owners_buf[implicit_owners_len] = owner;
                        implicit_owners_len += 1;
                    }
                }
                const ext = self.resolveExtensionCall(name, recv, args, .{
                    .caller_file = caller_file,
                    .caller_package = caller_pkg,
                    .implicit_dispatch_owners = implicit_owners_buf[0..implicit_owners_len],
                    .lexical_owner = ctx.owner_class,
                    .call_name = name,
                    .actual_type_param_bounds = ctx.actual_type_param_bounds,
                });
                receiver_extension_applicable = ext.applicable;
                if (dropTraceEnv()) |w| {
                    if (std.mem.eql(u8, w, name)) std.debug.print("[rcc] {s} ext.target={?d} applicable={} args={d}\n", .{ name, if (ext.target) |t| t.int() else null, ext.applicable, args.len });
                }
                if (ext.target) |id| {
                    target = id;
                    receiver_matched = true;
                    if (self.funcById(id)) |f| {
                        const kind = self.declarationKind(id, f);
                        tier = if (kind == .member_extension or kind == .instance_method)
                            0
                        else
                            self.bareCallTier(f, name, caller_pkg, caller_file);
                    }
                }
            }
        }

        if (target == null) {
            const global = self.applicableBarePick(
                name,
                candidates,
                args,
                caller_pkg,
                caller_file,
                ctx,
                false,
            );
            target = global.target;
            tier = global.tier;
            target_final = global.target != null and global.unique and
                (global.static_complete or global.tier_candidates == 1);
        }
        if (target == null and ctx.in_receiver_context and
            !receiver_extension_applicable)
        {
            const receiver_formed = self.applicableBarePick(
                name,
                candidates,
                args,
                caller_pkg,
                caller_file,
                ctx,
                true,
            );
            target = receiver_formed.target;
            tier = receiver_formed.tier;
            target_final = receiver_formed.target != null and
                receiver_formed.unique and receiver_formed.tier_candidates == 1;
        }
        if (target != null) reason = null;
        if (tier == 255) {
            tier = if (ires.tier != 255)
                ires.tier
            else
                self.lowestVisibleTier(name, candidates, caller_pkg, caller_file);
        }
        if (runtime.envOnce("KLIO_EXT_TRACE")) |w| {
            if (std.mem.eql(u8, w, name)) std.debug.print(
                "[rescall] {s} target={?d} recv_match={} recv_applicable={} tier={d} owner={?s}\n",
                .{
                    name,
                    if (target) |id| id.int() else null,
                    receiver_matched,
                    receiver_extension_applicable,
                    tier,
                    ctx.owner_class,
                },
            );
        }

        // Derive the static/virtual/deferred emission form once.
        var res = try self.emitFormFor(
            alloc,
            name,
            caller_pkg,
            caller_file,
            target,
            receiver_matched,
            tier,
            reason,
            ires.tier_count,
            candidates,
            args,
            ctx,
        );
        if (res.emit_form == .Call) {
            res.target_final = res.target != null and
                (target_final or receiver_matched);
        }
        return res;
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

    /// Whether any statically known implicit receiver has an applicable member
    /// or extension named `name`. A definite false is available only when the
    /// lowerer proved that the extension/dispatch receivers form the complete
    /// receiver scope; receiver lambdas, thunks, outers, and companions keep
    /// the conservative runtime walk.
    fn knownReceiverApplicability(
        self: *const Module,
        name: []const u8,
        caller_pkg: []const u8,
        caller_file: FileId,
        args: []const applicability.ArgShape,
        ctx: ResolveCtx,
        include_extensions: bool,
    ) ?bool {
        if (!ctx.receiver_scope_complete) return null;
        var receivers: [8]TypeRef = undefined;
        var receiver_complete: [8]bool = undefined;
        var receiver_bounds: [8][]const ModuleRegistry.TypeParamBound = undefined;
        var owner_args: [32]TypeRef = undefined;
        var tower_args: [6][32]TypeRef = undefined;
        var receiver_count: usize = 0;
        if (ctx.recv_type orelse if (ctx.recv_ty) |head|
            TypeRef{ .name = head, .nullable = false, .args = &.{} }
        else
            null) |receiver|
        {
            receivers[receiver_count] = receiver;
            receiver_bounds[receiver_count] = ctx.actual_type_param_bounds;
            receiver_complete[receiver_count] = self.staticTypeClassId(receiver) != null and
                self.staticTypeProofComplete(receiver, ctx.actual_type_param_bounds);
            receiver_count += 1;
        }
        if (ctx.owner_class) |owner_name| {
            var owner_receiver = TypeRef{ .name = owner_name, .nullable = false, .args = &.{} };
            const owner_id = self.staticTypeClassId(owner_receiver);
            var owner_complete = false;
            var owner_has_type_params = false;
            var owner_bounds: []const ModuleRegistry.TypeParamBound = &.{};
            if (owner_id) |id| {
                if (id.int() < self.classes.items.len) {
                    const class = &self.classes.items[id.int()];
                    owner_has_type_params = class.type_params.len != 0;
                    if (class.type_params.len <= owner_args.len) {
                        for (class.type_params, 0..) |param, i| {
                            owner_args[i] = .{ .name = param, .nullable = false, .args = &.{} };
                        }
                        owner_receiver = .{
                            .name = class.fqn,
                            .nullable = false,
                            .args = owner_args[0..class.type_params.len],
                        };
                        owner_bounds = self.registry.class_type_param_bounds.get(class.fqn) orelse &.{};
                        owner_complete = self.staticTypeProofComplete(owner_receiver, owner_bounds);
                    }
                }
            }
            const duplicate = owner_complete and !owner_has_type_params and
                receiver_count != 0 and blk: {
                const receiver = receivers[0];
                if (!receiver_complete[0] or receiver.nullable or
                    self.staticTypeClassId(receiver).? != owner_id.?)
                {
                    break :blk false;
                }
                const receiver_args = overrideArgs(receiver);
                const dispatch_args = overrideArgs(owner_receiver);
                if (receiver_args.len != dispatch_args.len) break :blk false;
                for (receiver_args, dispatch_args) |receiver_arg, dispatch_arg| {
                    if (!receiver_arg.eql(dispatch_arg)) break :blk false;
                }
                break :blk true;
            };
            if (!duplicate) {
                receivers[receiver_count] = owner_receiver;
                receiver_complete[receiver_count] = owner_complete;
                receiver_bounds[receiver_count] = owner_bounds;
                receiver_count += 1;
            }
        }
        // Tower receivers beyond recv/owner: each head becomes a symbolic
        // instantiation exactly like the owner path. A head that resolves no
        // class, exceeds the fixed capacity, or carries an incomplete proof
        // marks the scope incomplete (the probe then abstains rather than
        // proving a negative it cannot see).
        var tower_incomplete = false;
        var tower_slot: usize = 0;
        for (ctx.tower) |tower_entry| {
            var tref = TypeRef{ .name = tower_entry.head, .nullable = false, .args = &.{} };
            const tid = self.staticTypeClassId(tref) orelse {
                tower_incomplete = true;
                continue;
            };
            var dup = false;
            var i: usize = 0;
            while (i < receiver_count) : (i += 1) {
                if (self.staticTypeClassId(receivers[i])) |seen_id| {
                    if (seen_id.int() == tid.int()) {
                        dup = true;
                        break;
                    }
                }
            }
            if (dup) continue;
            if (receiver_count >= receivers.len or tower_slot >= tower_args.len) {
                tower_incomplete = true;
                break;
            }
            var complete = false;
            var bounds: []const ModuleRegistry.TypeParamBound = &.{};
            if (tid.int() < self.classes.items.len) {
                const class = &self.classes.items[tid.int()];
                if (class.type_params.len <= tower_args[tower_slot].len) {
                    for (class.type_params, 0..) |param, k| {
                        tower_args[tower_slot][k] = .{ .name = param, .nullable = false, .args = &.{} };
                    }
                    tref = .{
                        .name = class.fqn,
                        .nullable = false,
                        .args = tower_args[tower_slot][0..class.type_params.len],
                    };
                    bounds = self.registry.class_type_param_bounds.get(class.fqn) orelse &.{};
                    complete = self.staticTypeProofComplete(tref, bounds);
                }
            }
            receivers[receiver_count] = tref;
            receiver_complete[receiver_count] = complete;
            receiver_bounds[receiver_count] = bounds;
            receiver_count += 1;
            tower_slot += 1;
        }
        if (receiver_count == 0) return null;
        var has_incomplete_receiver = tower_incomplete;
        const lexical_owner: ?ClassId = if (ctx.owner_class) |lexical|
            self.staticTypeClassId(.{ .name = lexical, .nullable = false, .args = &.{} })
        else
            null;
        for (
            receivers[0..receiver_count],
            receiver_complete[0..receiver_count],
            receiver_bounds[0..receiver_count],
        ) |receiver, complete, bounds| {
            if (!complete) {
                has_incomplete_receiver = true;
                continue;
            }
            const owner = self.staticTypeClassId(receiver).?;
            if (self.resolveMemberCall(owner, name, args, .{
                .caller_file = caller_file,
                .lexical_owner = lexical_owner,
                .actual_type_param_bounds = bounds,
                .receiver_type = receiver,
            }).applicable) return true;
        }
        if (!include_extensions) {
            if (has_incomplete_receiver) return null;
            return false;
        }
        // The static extension resolver deliberately declines named and spread
        // argument shapes. They therefore cannot prove a negative: preserve
        // the receiver walk unless a member already proved applicability.
        for (args) |arg| {
            if (arg.named != null or arg.is_spread) return null;
        }
        for (
            receivers[0..receiver_count],
            receiver_complete[0..receiver_count],
            receiver_bounds[0..receiver_count],
        ) |receiver, complete, bounds| {
            if (!complete) continue;
            if (self.resolveExtensionCall(name, receiver, args, .{
                .caller_file = caller_file,
                .caller_package = caller_pkg,
                .lexical_owner = ctx.owner_class,
                .call_name = name,
                .actual_type_param_bounds = bounds,
            }).applicable) return true;
        }
        if (has_incomplete_receiver) return null;
        return false;
    }

    fn knownReceiverCallableApplicable(
        self: *const Module,
        name: []const u8,
        caller_pkg: []const u8,
        caller_file: FileId,
        args: []const applicability.ArgShape,
        ctx: ResolveCtx,
    ) ?bool {
        return self.knownReceiverApplicability(
            name,
            caller_pkg,
            caller_file,
            args,
            ctx,
            true,
        );
    }

    fn knownReceiverMemberApplicable(
        self: *const Module,
        name: []const u8,
        caller_pkg: []const u8,
        caller_file: FileId,
        args: []const applicability.ArgShape,
        ctx: ResolveCtx,
    ) ?bool {
        return self.knownReceiverApplicability(
            name,
            caller_pkg,
            caller_file,
            args,
            ctx,
            false,
        );
    }

    /// Whether a tower-unlocked static commit is argument-PROVEN over its
    /// whole candidate set: the target judges `.compatible` on every
    /// supplied argument and every competitor is structurally inapplicable
    /// or judges `.incompatible`. An `.unknown` anywhere keeps the deferral
    /// — the runtime re-pick stays the safety net exactly where the static
    /// shapes cannot decide (a tier pick without type proof is not a
    /// commitment).
    fn towerPickProven(
        self: *const Module,
        target: FuncId,
        candidates: []const FuncId,
        args: []const applicability.ArgShape,
        bounds: []const ModuleRegistry.TypeParamBound,
    ) bool {
        // POSITIVE evidence only: `.compatible` from the judge means "not
        // refuted", so a proof additionally demands every argument carry an
        // authoritative shape (a literal kind or an authoritative type) —
        // an unjudgeable argument keeps the deferral.
        for (args) |arg| {
            if (arg.literal_kind == null and (arg.ty == null or !arg.ty_authoritative)) return false;
        }
        var saw_target = false;
        for (candidates) |cand| {
            const is_target = cand.int() == target.int();
            if (is_target) saw_target = true;
            const sv = self.sigViewForApplicability(cand, callShapesHaveComposerPair(args)) orelse {
                if (is_target) return false;
                continue;
            };
            const named = !allShapeNamesNull(args);
            const score = applicability.applicable(&sv, args, .{
                .named = named,
                .recv_external = named,
            }) orelse {
                if (is_target) return false;
                continue;
            };
            const compat = self.staticBareArgsCompatibility(cand, sv, args, score, bounds);
            if (is_target) {
                if (compat != .compatible) return false;
            } else if (compat != .incompatible) {
                return false;
            }
        }
        return saw_target;
    }

    /// The single member-vs-global decision, folding the receiver
    /// gates once. `Call → exact`, `CallMember`/`CallMemberOrGlobal → virtual`
    /// (target non-null) or `deferred` (target null), `CallValue → deferred`.
    fn emitFormFor(
        self: *const Module,
        alloc: std.mem.Allocator,
        name: []const u8,
        caller_pkg: []const u8,
        caller_file: FileId,
        target: ?FuncId,
        receiver_matched: bool,
        tier: u8,
        reason: ?ResolveDeferReason,
        tier_count: usize,
        candidates: []const FuncId,
        args: []const applicability.ArgShape,
        ctx: ResolveCtx,
    ) std.mem.Allocator.Error!Resolution {
        const known_receiver_applicable = self.knownReceiverCallableApplicable(
            name,
            caller_pkg,
            caller_file,
            args,
            ctx,
        );
        const receiver_shadowable = known_receiver_applicable orelse
            ((ctx.in_receiver_context or ctx.unknown_receiver) and !ctx.recv_cannot_shadow);
        const member_shadowable = receiver_shadowable or ctx.enclosing_has_member or
            (known_receiver_applicable == null and !ctx.receiver_known and
                !ctx.recv_cannot_shadow and
                self.registry.class_member_names.contains(name));
        const cast_static = if (ctx.cast_pick) |cp| (if (target) |t| cp.int() == t.int() else false) else false;
        if (target) |t| {
            const is_ext = if (self.funcById(t)) |f| funcHasImplicitThis(f) else false;
            if (is_ext) {
                const renamed_target = receiver_matched and
                    self.renamedImportDenotesFunc(name, caller_file, t);
                const extension_receiver_shadowable = if (renamed_target) blk: {
                    const known_member_applicable = self.knownReceiverMemberApplicable(
                        name,
                        caller_pkg,
                        caller_file,
                        args,
                        ctx,
                    );
                    break :blk (known_member_applicable orelse
                        ((ctx.in_receiver_context or ctx.unknown_receiver) and
                            !ctx.recv_cannot_shadow)) or
                        ctx.enclosing_has_member or
                        (known_member_applicable == null and !ctx.receiver_known and
                            !ctx.recv_cannot_shadow and
                            self.registry.class_member_names.contains(name));
                } else member_shadowable;
                // Extension member-first defer: in a receiver context a member of
                // the implicit receiver could shadow the extension, so it
                // dispatches member-first. Unlike the non-extension gate, a cast
                // or explicit type arguments do NOT suppress this.
                if (ctx.in_receiver_context and extension_receiver_shadowable) {
                    const cs = try self.candidateSet(
                        alloc,
                        name,
                        candidates,
                        caller_pkg,
                        caller_file,
                        tier,
                    );
                    return .{ .target = t, .confidence = .virtual, .emit_form = .CallMemberOrGlobal, .candidate_set = cs, .reason = reason, .tier = tier, .tier_count = tier_count };
                }
                // A renamed import records an exact declaration identity that
                // cannot be recovered from runtime dispatch by the alias.
                if (cast_static or renamed_target) {
                    return .{ .target = t, .confidence = .exact, .emit_form = .Call, .reason = reason, .tier = tier, .tier_count = tier_count };
                }
                // The innermost receiver type PROVABLY cannot take this
                // extension: the receiver must come from an OUTER implicit
                // receiver that only the runtime walk can supply. The
                // static `.CallMember` bind would put the wrong `this` in
                // the extension's receiver slot with no runtime recovery —
                // `read(this)` inside the `CompositionLocal.currentValue`
                // accessor resolves `PersistentCompositionLocalMap.read`,
                // whose receiver is the accessor's DISPATCH owner, present
                // only on the enclosing chain.
                if (known_receiver_applicable == false) {
                    const cs = try self.candidateSet(
                        alloc,
                        name,
                        candidates,
                        caller_pkg,
                        caller_file,
                        tier,
                    );
                    return .{ .target = t, .confidence = .virtual, .emit_form = .CallMemberOrGlobal, .candidate_set = cs, .reason = reason, .tier = tier, .tier_count = tier_count };
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
            if (runtime.envOnce("KLIO_EF_TRACE")) |w| {
                if (std.mem.eql(u8, w, name)) std.debug.print("[ef] {s} t={d} inline={} nlr={} recvctx={} shadowable={} shadow={} file={d}\n", .{ name, t.int(), self.funcIsInline(t), ctx.nonlocal_return_lambda, ctx.in_receiver_context, member_shadowable, shadow, caller_file.int() });
            }
            if (!shadow) {
                // A tower-unlocked commit also stands down for a VALUE
                // CAPTURE in scope: an outer local fn shares the name, lives
                // in a capture cell no candidate tier can see, and Kotlin
                // binds it over every global (`fun check(a, b, m) {...};
                // repeat(1000) { check(a, b) }` bound `kotlin.check`).
                if (ctx.tower_scope and (ctx.is_value_capture or
                    (candidates.len > 1 and
                        !self.towerPickProven(t, candidates, args, ctx.actual_type_param_bounds))))
                {
                    const cs = try self.candidateSet(
                        alloc,
                        name,
                        candidates,
                        caller_pkg,
                        caller_file,
                        tier,
                    );
                    return .{ .target = t, .confidence = .virtual, .emit_form = .CallMemberOrGlobal, .candidate_set = cs, .reason = reason, .tier = tier, .tier_count = tier_count };
                }
                return .{ .target = t, .confidence = .exact, .emit_form = .Call, .reason = reason, .tier = tier, .tier_count = tier_count };
            }
            const cs = try self.candidateSet(
                alloc,
                name,
                candidates,
                caller_pkg,
                caller_file,
                tier,
            );
            return .{ .target = t, .confidence = .virtual, .emit_form = .CallMemberOrGlobal, .candidate_set = cs, .reason = reason, .tier = tier, .tier_count = tier_count };
        }
        if (ctx.is_value_capture) {
            return .{ .target = null, .confidence = .deferred, .emit_form = .CallValue, .reason = reason, .tier = tier, .tier_count = tier_count };
        }
        if (ctx.in_receiver_context) {
            const cs = try self.candidateSet(
                alloc,
                name,
                candidates,
                caller_pkg,
                caller_file,
                tier,
            );
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
        var best_tier: u8 = 255;
        var candidate_it = self.bareCallCandidateIterator(name, caller_file);
        while (candidate_it.next()) |id| {
            const f = self.funcById(id) orelse continue;
            if (self.candidateHasImplicitThis(id, f)) continue;
            if (!f.hasBody() and self.stubDeclArity(id) == null) continue;
            const t = self.bareCallTier(f, name, caller_pkg, caller_file);
            if (t < best_tier) best_tier = t;
        }
        if (best_tier == 255) return null;
        var chosen: ?FuncId = null;
        var count: usize = 0;
        candidate_it = self.bareCallCandidateIterator(name, caller_file);
        while (candidate_it.next()) |id| {
            const f = self.funcById(id) orelse continue;
            if (self.candidateHasImplicitThis(id, f)) continue;
            if (!f.hasBody() and self.stubDeclArity(id) == null) continue;
            if (self.bareCallTier(f, name, caller_pkg, caller_file) != best_tier) continue;
            if (chosen == null) chosen = id;
            count += 1;
        }
        if (count == 1) return chosen;
        return null;
    }

    /// Resolve an overloaded bare callable reference from its expected
    /// function-parameter types. Candidate enumeration, scope, and static
    /// applicability are identical to a source call; no receiver is supplied,
    /// so extension declarations remain outside this unbound bare form.
    pub fn resolveBareRefExpected(
        self: *const Module,
        allocator: Allocator,
        name: []const u8,
        caller_pkg_in: []const u8,
        caller_file: FileId,
        args: []const applicability.ArgShape,
    ) Allocator.Error!?FuncId {
        const candidates = try self.bareCallCandidates(allocator, name, caller_file);
        defer allocator.free(candidates);
        if (candidates.len == 0) return null;
        const caller_pkg = self.packageOfFile(caller_file) orelse caller_pkg_in;
        const pick = self.applicableBarePick(
            name,
            candidates,
            args,
            caller_pkg,
            caller_file,
            .{},
            false,
        );
        return if (pick.unique) pick.target else null;
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
        caller_pkg_in: []const u8,
        caller_file: FileId,
    ) ?u8 {
        // Scope follows the reference span's FILE (see
        // resolveBareCallIndexed): a spliced inline body carries the donor
        // file's spans, so its bare reads rank in the donor's package.
        const caller_pkg = self.packageOfFile(caller_file) orelse caller_pkg_in;
        var best_tier: u8 = 255;
        var candidate_it = self.bareCallCandidateIterator(name, caller_file);
        while (candidate_it.next()) |id| {
            const f = self.funcById(id) orelse continue;
            if (self.candidateHasImplicitThis(id, f)) continue;
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
        caller_pkg_in: []const u8,
        caller_file: FileId,
    ) ?u8 {
        const caller_pkg = self.packageOfFile(caller_file) orelse caller_pkg_in;
        // Exact imports include renamed aliases and collision-mangled classes
        // that have no `class_index` entry under the call-site spelling.
        if (self.classIdExactImport(name, caller_file) != null) return 0;
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
        caller_pkg_in: []const u8,
        caller_file: FileId,
    ) ?u8 {
        const caller_pkg = self.packageOfFile(caller_file) orelse caller_pkg_in;
        const list = self.registry.top_level_prop_pkgs.get(name) orelse return null;
        var best_tier: u8 = 255;
        for (list.items) |pd| {
            const t = self.scopeTier(pd.fqn, pd.package, name, caller_pkg, caller_file);
            if (t < best_tier) best_tier = t;
        }
        if (best_tier == 255) return null;
        return best_tier;
    }

    /// The declared type head of the top-level property a bare read of
    /// `name` resolves to under Kotlin scoping — the best-tier declaration,
    /// and only when every declaration AT that tier agrees on the head (a
    /// cross-package name clash types nothing).
    /// The type head of one top-level property declaration: what its
    /// annotation or literal initializer stated, else what the function its
    /// initializer CALLS returns. The call is resolved here rather than at
    /// registration because only now is the whole declaration set visible.
    /// The full declared type of one top-level property declaration, where
    /// its arguments were recorded. Null leaves the head-only answer.
    pub fn topLevelPropTypeRef(
        self: *const Module,
        name: []const u8,
        caller_pkg: []const u8,
        caller_file: FileId,
    ) ?TypeRef {
        const list = self.registry.top_level_prop_pkgs.get(name) orelse return null;
        var best_tier: u8 = 255;
        var found: ?TypeRef = null;
        for (list.items) |pd| {
            const t = self.scopeTier(pd.fqn, pd.package, name, caller_pkg, caller_file);
            if (t == 255) continue;
            const r = self.registry.top_level_prop_type_refs.get(pd.fqn);
            if (t < best_tier) {
                best_tier = t;
                found = r;
            } else if (t == best_tier) {
                const cur = found orelse return null;
                const new = r orelse return null;
                if (!std.mem.eql(u8, cur.name, new.name)) return null;
            }
        }
        return found;
    }

    /// The tiered HEAD twin of `topLevelPropTypeRef`: a scalar top-level
    /// property (`private const val DAYS_PER_CYCLE = 146097L`) records only
    /// its head, and the deriver's Path arm needs it under the same
    /// caller-scope tiers.
    pub fn topLevelPropTypeHeadTiered(
        self: *const Module,
        name: []const u8,
        caller_pkg: []const u8,
        caller_file: FileId,
    ) ?[]const u8 {
        const list = self.registry.top_level_prop_pkgs.get(name) orelse {
            if (std.c.getenv("KLIO_TLP_TRACE")) |w| {
                if (std.mem.eql(u8, std.mem.span(w), name))
                    std.debug.print("[tlp] {s} NO-LIST caller_pkg={s}\n", .{ name, caller_pkg });
            }
            return null;
        };
        var best_tier: u8 = 255;
        var found: ?[]const u8 = null;
        for (list.items) |pd| {
            const t = self.scopeTier(pd.fqn, pd.package, name, caller_pkg, caller_file);
            if (std.c.getenv("KLIO_TLP_TRACE")) |w| {
                if (std.mem.eql(u8, std.mem.span(w), name))
                    std.debug.print("[tlp] {s} fqn={s} pkg={s} tier={d} head={s} caller_pkg={s}\n", .{ name, pd.fqn, pd.package, t, self.registry.top_level_prop_type_heads.get(pd.fqn) orelse "-", caller_pkg });
            }
            if (t == 255) continue;
            const h = self.registry.top_level_prop_type_heads.get(pd.fqn);
            if (t < best_tier) {
                best_tier = t;
                found = h;
            } else if (t == best_tier) {
                const cur = found orelse return null;
                const new = h orelse return null;
                if (!std.mem.eql(u8, cur, new)) return null;
            }
        }
        return found;
    }

    pub fn topLevelPropHeadFor(self: *const Module, fqn: []const u8) ?[]const u8 {
        if (self.registry.top_level_prop_type_heads.get(fqn)) |h| return h;
        const callee = self.registry.top_level_prop_init_callees.get(fqn) orelse return null;
        var head: ?[]const u8 = null;
        for (self.funcsBySimpleName(callee)) |fid| {
            const f = self.funcById(fid) orelse continue;
            if (f.kind != .plain) continue;
            if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) continue;
            var h = staticTypeHead(std.mem.trimEnd(u8, f.return_ty.name, "?"));
            if (h.len == 0) return null;
            if (std.mem.lastIndexOfScalar(u8, h, '.')) |d| h = h[d + 1 ..];
            if (head) |prev| {
                if (!std.mem.eql(u8, prev, h)) return null;
            } else head = h;
        }
        if (head) |h| {
            // Only a head that names a class the module knows: a type
            // parameter or an unresolvable name disproves candidates a null
            // would have left open.
            if (self.uniqueClassIdBySimpleName(h) == null and self.classIdByFqn(h) == null) return null;
            return h;
        }
        // A constructor call states the class outright.
        if (self.uniqueClassIdBySimpleName(callee) != null) return callee;
        return null;
    }

    pub fn topLevelPropTypeHead(
        self: *const Module,
        name: []const u8,
        caller_pkg: []const u8,
        caller_file: FileId,
    ) ?[]const u8 {
        const list = self.registry.top_level_prop_pkgs.get(name) orelse return null;
        var best_tier: u8 = 255;
        var head: ?[]const u8 = null;
        for (list.items) |pd| {
            const t = self.scopeTier(pd.fqn, pd.package, name, caller_pkg, caller_file);
            if (t == 255) continue;
            const h = self.topLevelPropHeadFor(pd.fqn);
            if (t < best_tier) {
                best_tier = t;
                head = h;
            } else if (t == best_tier) {
                const cur = head orelse return null;
                const new = h orelse return null;
                if (!std.mem.eql(u8, cur, new)) return null;
            }
        }
        return head;
    }

    /// Resolve a top-level callable extension property at an explicit
    /// receiver call site. A member function has already been ruled out by
    /// the caller; this query applies receiver, arity, visibility, and normal
    /// Kotlin import/package tiers and commits only one declaration identity.
    pub fn resolveCallableExtensionProperty(
        self: *const Module,
        name: []const u8,
        receiver_head: []const u8,
        receiver_is_class: bool,
        value_arity: usize,
        caller_pkg: []const u8,
        caller_file: FileId,
    ) ?ModuleRegistry.CallableExtensionProp {
        const Helpers = struct {
            fn outerCompanionHead(receiver: []const u8) ?[]const u8 {
                const suffix = ".Companion";
                if (!std.mem.endsWith(u8, receiver, suffix)) return null;
                return staticTypeHead(receiver[0 .. receiver.len - suffix.len]);
            }

            fn receiverMatches(
                module: *const Module,
                declared: []const u8,
                actual: []const u8,
                is_class: bool,
            ) bool {
                if (outerCompanionHead(declared)) |outer| {
                    return is_class and std.mem.eql(u8, outer, staticTypeHead(actual));
                }
                if (is_class) return false;
                return module.classIsOrExtends(actual, declared);
            }
        };

        var source_name = name;
        var list = self.registry.callable_extension_props.get(source_name);
        if (list == null) {
            for (self.importAliasPathsIn(caller_file, name)) |path| {
                source_name = staticTypeHead(path.fqn);
                list = self.registry.callable_extension_props.get(source_name);
                if (list != null) break;
            }
        }
        const candidates = list orelse return null;
        var best: ?ModuleRegistry.CallableExtensionProp = null;
        var best_tier: u8 = 255;
        var ambiguous = false;
        for (candidates.items) |candidate| {
            if (candidate.value_arity != value_arity) continue;
            if (candidate.is_private and candidate.file != caller_file) continue;
            if (!Helpers.receiverMatches(self, candidate.receiver, receiver_head, receiver_is_class)) continue;
            const tier = self.scopeTier(
                candidate.fqn,
                candidate.package,
                name,
                caller_pkg,
                caller_file,
            );
            if (tier > last_in_scope_tier) continue;
            if (tier < best_tier) {
                best = candidate;
                best_tier = tier;
                ambiguous = false;
            } else if (tier == best_tier and best != null and
                !std.mem.eql(u8, best.?.fqn, candidate.fqn))
            {
                ambiguous = true;
            }
        }
        return if (ambiguous) null else best;
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
        if (std.c.getenv("KLIO_CIDX_TRACE")) |w| {
            if (std.mem.indexOf(u8, class.name, std.mem.span(w)) != null) std.debug.print("[cidx] name={s} id={d}\n", .{ class.name, id.int() });
        }
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

    const SimpleNameInfo = struct { id: ClassId, non_kotlin: bool };

    /// The fully-qualified name of the class with id `id`, or null if out of range.
    pub fn classFqnById(self: *const Module, id: ClassId) ?[]const u8 {
        const c = idGet(Class, self.classes.items, id.int()) orelse return null;
        return c.fqn;
    }

    pub const cid_memo_slots = 64;

    /// `classIdByFqn` through the pointer-identity memo on `cid_memo_keys`
    /// (see the field docs). ONLY for static, content-stable `fqn` slices.
    pub fn classIdByStaticFqn(self: *const Module, fqn: []const u8) ?ClassId {
        const key = @intFromPtr(fqn.ptr);
        const h = (key >> 4) & (cid_memo_slots - 1);
        if (self.cid_memo_keys[h].load(.monotonic) == key) {
            const v = self.cid_memo_vals[h].load(.acquire);
            if (v == 1) return null;
            if (v >= 2) return ClassId.from(@intCast(v - 2));
        }
        const answer = self.classIdByFqn(fqn);
        const mut = @constCast(self);
        if (mut.cid_memo_keys[h].cmpxchgStrong(0, key, .acq_rel, .monotonic) == null) {
            mut.cid_memo_vals[h].store(if (answer) |a| @as(u64, a.int()) + 2 else 1, .release);
        }
        return answer;
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
        if (id.int() < self.unique_simple_cache_n) {
            self.unique_simple_cache.clearRetainingCapacity();
            self.unique_simple_cache_n = 0;
        }
    }

    /// Whether class `sub` is `super_name` itself, or transitively
    /// extends / implements it, judged over the simple-name hierarchy
    /// recorded at build time (`registry.class_super_names`). Receiver
    /// applicability for extension narrowing: an extension declared on
    /// a base class accepts a subclass receiver.
    pub fn classIsOrExtends(self: *const Module, sub: []const u8, super_name: []const u8) bool {
        if (std.mem.eql(u8, sub, super_name)) return true;
        const sub_id = if (std.mem.indexOfScalar(u8, sub, '.') != null)
            self.classIdByFqn(sub)
        else
            self.uniqueClassIdBySimpleName(staticTypeHead(sub));
        // A ROW-LESS sub with a registered name chain (a local class's
        // lowering-time typing record) answers through it even when the
        // SUPER resolves a class id.
        if (sub_id == null) {
            if (self.registry.class_super_names.get(staticTypeHead(sub))) |supers| {
                const sup_simple = applicability.simpleName(staticTypeHead(super_name));
                for (supers) |s2| {
                    if (std.mem.eql(u8, applicability.simpleName(staticTypeHead(s2)), sup_simple)) return true;
                }
            }
        }
        const super_id = if (std.mem.indexOfScalar(u8, super_name, '.') != null)
            self.classIdByFqn(super_name)
        else
            self.uniqueClassIdBySimpleName(staticTypeHead(super_name));
        if (sub_id != null or super_id != null) {
            return sub_id != null and super_id != null and
                self.classIdIsOrExtends(sub_id.?, super_id.?);
        }
        if (std.mem.indexOfScalar(u8, sub, '.') != null or
            std.mem.indexOfScalar(u8, super_name, '.') != null) return false;
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
        if (std.c.getenv("KLIO_CIDX_TRACE")) |w| {
            if (std.mem.indexOf(u8, name, std.mem.span(w)) != null) std.debug.print("[cidx] name={s} id={d}\n", .{ name, id.int() });
        }
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
        if (std.c.getenv("KLIO_CIDX_TRACE")) |w| {
            if (std.mem.indexOf(u8, name, std.mem.span(w)) != null) std.debug.print("[cidx] name={s} id={d}\n", .{ name, id.int() });
        }
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

fn callShapesHaveComposerPair(args: []const applicability.ArgShape) bool {
    if (args.len < 2) return false;
    const composer = args[args.len - 2].named orelse return false;
    const changed = args[args.len - 1].named orelse return false;
    return std.mem.eql(u8, composer, "$composer") and
        std.mem.eql(u8, changed, "$changed");
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
    /// Fqns whose installed HOST BINDING is authoritative over any
    /// interpreted body (a pack's stub declarations — atomicfu's atomics).
    /// Populated at bindings install from the non-stdlib overlay keys; a
    /// static member bind must not commit a BODY-BEARING target listed
    /// here — the runtime walk's binding preference arbitrates instead.
    host_shadowed_fqns: std.StringHashMap(void),
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
    /// The same key, carrying the property's FULL declared type rather than
    /// its head — `val items: List<Named>` records `List<Named>`, not `List`.
    /// A head alone cannot answer what iterating or indexing the property
    /// yields, which left `items[0].tag()`, `for (i in items)` and
    /// `items.map { it.tag() }` with no receiver type in ordinary code.
    /// Borrowed from the lowering arena, like every other registry string.
    class_prop_type_refs: StrPairMap(TypeRef),
    /// `(extension-receiver head, property name)` -> declared type head for
    /// TOP-LEVEL extension properties (`val IntArray.indices: IntRange`
    /// records `(IntArray, indices) -> IntRange`). Recorded in the decl
    /// scan, before any body lowers, so a bare `indices` read inside an
    /// array extension body types statically even while the stdlib itself
    /// is still lowering.
    ext_prop_type_heads: StrPairMap([]const u8),
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
    /// (class simple name, member name) → arity BITMASK (bit n = declared
    /// with n params, capped at 63) for BODYLESS member declarations
    /// (abstract interface/class members). The abstract slot lowers no
    /// func and joins no class-row method list, so overload picks that
    /// must rank members above extensions (a bare `respond(a, b)` inside
    /// an `ApplicationCall` extension binding the interface's
    /// `respond(message, typeInfo)` member, never a reified 2-arg
    /// extension splice) consult this record.
    abstract_member_arity: StrPairMap(u64),
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
    /// Structural alias targets used by static applicability proofs.
    type_alias_types: std.StringHashMap(TypeAliasShape),
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
    /// Kotlin compilation-module identity for each source file. `internal`
    /// declarations are visible across files carrying the same identity and
    /// inaccessible across dependency/program boundaries.
    file_modules: std.AutoHashMap(FileId, u32),
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
    /// Top-level property FQN -> declared type head, so a bare read used as
    /// a RECEIVER (`asserter.assertEquals(...)`) types statically. Only
    /// annotated declarations record; the head is the annotation as written.
    top_level_prop_type_heads: std.StringHashMap([]const u8),
    /// The same key, carrying the FULL declared type where it has arguments
    /// (`val topItems: List<Named>`). The head alone cannot say what
    /// iterating or indexing the property yields.
    top_level_prop_type_refs: std.StringHashMap(TypeRef),
    /// Top-level property FQN -> the simple name its UNANNOTATED initializer
    /// calls (`private val base64EncodeMap = byteArrayOf(...)`). Resolved to
    /// a head only at query time, when every declaration is registered: a
    /// user function of the same name is then visible and either agrees or
    /// makes the answer ambiguous, so a shadowed factory cannot mistype the
    /// property.
    top_level_prop_init_callees: std.StringHashMap([]const u8),
    /// Top-level extension properties whose values are directly callable.
    /// Registered before body lowering so `receiver.property(args)` can be
    /// classified as a property read followed by `invoke`.
    callable_extension_props: std.StringHashMap(std.ArrayList(CallableExtensionProp)),
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

    pub const TypeAliasShape = struct {
        type_params: []const []const u8,
        target: TypeRef,
    };

    /// One top-level property declaration's scoping identity.
    pub const PropDecl = struct {
        fqn: []const u8,
        package: []const u8,
    };

    pub const CallableExtensionProp = struct {
        fqn: []const u8,
        package: []const u8,
        receiver: []const u8,
        file: FileId,
        value_arity: u16,
        is_private: bool,
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
        /// False when the string-only record dropped intersection or
        /// structural type information and cannot support a negative proof.
        complete: bool = true,
        /// True when `bound` still names the single classifier the parameter
        /// is bounded by, even if the record dropped its type ARGUMENTS. That
        /// is enough to answer "which class owns a member call on this
        /// parameter", which is all the receiver-owner lookup asks.
        head_only: bool = true,
        /// The bound's type-argument heads, kept ONLY when every argument is
        /// concrete (`T : Iterable<String>` keeps ["String"];
        /// `C : MutableCollection<in T>` keeps nothing — an argument naming
        /// another parameter substitutes nothing). Lets a receiver typed by
        /// the parameter instantiate a generic callee's lambda params.
        args: []const []const u8 = &.{},
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
            .host_shadowed_fqns = std.StringHashMap(void).init(allocator),
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
            .class_prop_type_refs = StrPairMap(TypeRef).init(allocator),
            .ext_prop_type_heads = StrPairMap([]const u8).init(allocator),
            .member_ext_owner_class = std.AutoHashMap(FuncId, []const u8).init(allocator),
            .private_fn_files = std.AutoHashMap(FuncId, FileId).init(allocator),
            .iface_member_ext_recv = StrPairMap([]const u8).init(allocator),
            .abstract_member_arity = StrPairMap(u64).init(allocator),
            .top_level_const_vals = std.StringHashMap(Const).init(allocator),
            .local_fn_defaults = std.AutoHashMap(FuncId, std.ArrayList(?FuncId)).init(allocator),
            .abstract_member_defaults = StrPairMap(std.ArrayList(?FuncId)).init(allocator),
            .type_aliases = std.StringHashMap([]const u8).init(allocator),
            .type_alias_types = std.StringHashMap(TypeAliasShape).init(allocator),
            .recv_fn_aliases = std.StringHashMap(u8).init(allocator),
            .import_aliases = std.AutoHashMap(FileId, std.StringHashMap(std.ArrayList(ImportPath))).init(allocator),
            .import_wildcards = std.AutoHashMap(FileId, std.ArrayList([]const u8)).init(allocator),
            .file_packages = std.AutoHashMap(FileId, []const u8).init(allocator),
            .file_modules = std.AutoHashMap(FileId, u32).init(allocator),
            .nested_object_aliases = std.StringHashMap(std.StringHashMap([]const u8)).init(allocator),
            .mangled_nested = std.StringHashMap([]const u8).init(allocator),
            .class_const_inits = StrPairMap(Const).init(allocator),
            .top_level_prop_pkgs = std.StringHashMap(std.ArrayList(PropDecl)).init(allocator),
            .top_level_prop_type_heads = std.StringHashMap([]const u8).init(allocator),
            .top_level_prop_type_refs = std.StringHashMap(TypeRef).init(allocator),
            .top_level_prop_init_callees = std.StringHashMap([]const u8).init(allocator),
            .callable_extension_props = std.StringHashMap(std.ArrayList(CallableExtensionProp)).init(allocator),
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
        self.host_shadowed_fqns.deinit();
        {
            var it = self.class_super_names.valueIterator();
            while (it.next()) |names| a.free(names.*);
            self.class_super_names.deinit();
        }
        self.delegated_body_props.deinit();
        self.recv_fn_props.deinit();
        self.class_prop_type_heads.deinit();
        self.class_prop_type_refs.deinit();
        self.ext_prop_type_heads.deinit();
        self.member_ext_owner_class.deinit();
        self.private_fn_files.deinit();
        self.iface_member_ext_recv.deinit();
        self.abstract_member_arity.deinit();
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
        self.type_alias_types.deinit();
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
        self.file_modules.deinit();
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
        self.top_level_prop_type_heads.deinit();
        self.top_level_prop_type_refs.deinit();
        self.top_level_prop_init_callees.deinit();
        {
            var it = self.callable_extension_props.valueIterator();
            while (it.next()) |list| list.deinit(a);
            self.callable_extension_props.deinit();
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
            var it = self.host_shadowed_fqns.iterator();
            while (it.next()) |e| try out.host_shadowed_fqns.put(e.key_ptr.*, {});
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
            var it = self.class_prop_type_refs.iterator();
            while (it.next()) |e| try out.class_prop_type_refs.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.ext_prop_type_heads.iterator();
            while (it.next()) |e| try out.ext_prop_type_heads.put(e.key_ptr.*, e.value_ptr.*);
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
            var it = self.type_alias_types.iterator();
            while (it.next()) |e| try out.type_alias_types.put(e.key_ptr.*, e.value_ptr.*);
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
            var it = self.file_modules.iterator();
            while (it.next()) |e| try out.file_modules.put(e.key_ptr.*, e.value_ptr.*);
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
            var it = self.top_level_prop_type_heads.iterator();
            while (it.next()) |e| try out.top_level_prop_type_heads.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.top_level_prop_type_refs.iterator();
            while (it.next()) |e| try out.top_level_prop_type_refs.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.top_level_prop_init_callees.iterator();
            while (it.next()) |e| try out.top_level_prop_init_callees.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.callable_extension_props.iterator();
            while (it.next()) |e| {
                var list: std.ArrayList(CallableExtensionProp) = .empty;
                try list.appendSlice(a, e.value_ptr.items);
                try out.callable_extension_props.put(e.key_ptr.*, list);
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
        TypeRef,         Reg,            BlockId,        FuncId,
        ClassId,         ConstId,        Inst,           SpreadPart,
        BinOp,           UnOp,           Terminator,     SwitchArm,
        CatchHandler,    Block,          Func,           Param,
        Class,           Module,         ModuleRegistry, Const,
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

test "class type parameter identities are exact and unambiguous" {
    const first = try classTypeParamIdentity(
        testing.allocator,
        ClassId.from(1),
        "23X",
    );
    defer testing.allocator.free(first);
    const second = try classTypeParamIdentity(
        testing.allocator,
        ClassId.from(12),
        "3X",
    );
    defer testing.allocator.free(second);
    try testing.expect(!std.mem.eql(u8, first, second));

    const projected = try std.fmt.allocPrint(testing.allocator, "out#{s}", .{first});
    defer testing.allocator.free(projected);
    const parsed = parseClassTypeParamIdentity(projected).?;
    try testing.expectEqual(ClassId.from(1), parsed.owner);
    try testing.expectEqualStrings("23X", parsed.param);
    try testing.expect(parseClassTypeParamIdentity("$class$123X") == null);
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

    try testing.expect(m.extCouldApply(a, "IntArray", "min", 0));
    try testing.expect(!m.extCouldApply(a, "String", "min", 0));
    try testing.expect(!m.extCouldApply(a, "IntArray", "max", 0));
    // The extension declares no value parameters, so a one-argument call
    // cannot select it and it cannot shadow a member of that name.
    try testing.expect(!m.extCouldApply(a, "IntArray", "min", 1));
}

test "an unclaimed classifier header dispatches its bodied member virtually" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    // A reserved placeholder reads closed-and-final on every modifier
    // whether the class is a final class or an unlowered interface.
    const owner = try m.reserveClass(a, "Sink", false);
    try testing.expect(m.classes.items[owner.int()].is_stub);

    const accept = try pushTestFuncOpts(&m, a, "accept", "sample.Sink.accept", "sample", 1, .{ .param_ty = "String" });
    try m.decl_sigs.put(accept.int(), .{
        .enclosing_class = owner,
        .arity = .{ .required = 1, .total = 1, .has_vararg = false },
        .sig = &.{.{ .name = "String", .nullable = false, .args = &.{} }},
        .kind = .instance_method,
        .has_body = true,
    });

    // Reading the placeholder as a closed class binds the body by identity,
    // and an implementing class's override never runs.
    try testing.expectEqual(Module.MemberDispatch.virtual, m.dispatchForTarget(owner, accept).?);
}

test "member resolution uses declaration-owner visibility" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    const base = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Base",
        .fqn = "sample.Base",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
        .is_open = true,
    });
    const derived = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Derived",
        .fqn = "sample.Derived",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = try a.dupe(ClassId, &.{base}),
        .is_open = true,
    });
    const leaf = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Leaf",
        .fqn = "sample.Leaf",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = try a.dupe(ClassId, &.{derived}),
    });
    const base_nested = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Base$Nested",
        .fqn = "sample.Base.Nested",
        .package = "sample",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    const derived_nested = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Derived$Nested",
        .fqn = "sample.Derived.Nested",
        .package = "sample",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    try m.registry.enclosing_class.put("Base$Nested", "Base");
    try m.registry.enclosing_class.put("Derived$Nested", "Derived");

    const private_fn = try pushTestFuncOpts(
        &m,
        a,
        "secret",
        "sample.Base.secret",
        "sample",
        0,
        .{ .extension = true },
    );
    const protected_fn = try pushTestFuncOpts(
        &m,
        a,
        "guarded",
        "sample.Base.guarded",
        "sample",
        0,
        .{ .extension = true },
    );
    for (
        [_]FuncId{ private_fn, protected_fn },
        [_]ast.Visibility{ .Private, .Protected },
    ) |fid, visibility| {
        m.funcs.items[fid.int()].kind = .instance_method;
        try m.decl_sigs.put(fid.int(), .{
            .enclosing_class = base,
            .arity = .{ .required = 0, .total = 0, .has_vararg = false },
            .kind = .instance_method,
            .visibility = visibility,
            .has_body = true,
        });
        try m.registerMemberDecl(
            a,
            m.classes.items[base.int()].fqn,
            m.funcs.items[fid.int()].name,
            fid,
        );
    }

    const private_from_base = m.resolveMemberCall(
        derived,
        "secret",
        &.{},
        .{ .lexical_owner = base },
    );
    try testing.expectEqual(private_fn, private_from_base.target.?);
    try testing.expectEqual(Module.MemberDispatch.direct, private_from_base.dispatch);
    try testing.expectEqual(
        private_fn,
        m.resolveMemberCall(
            derived,
            "secret",
            &.{},
            .{ .lexical_owner = base_nested },
        ).target.?,
    );
    try testing.expect(m.resolveMemberCall(
        derived,
        "secret",
        &.{},
        .{ .lexical_owner = derived },
    ).target == null);

    try testing.expect(m.resolveMemberCall(
        base,
        "guarded",
        &.{},
        .{ .lexical_owner = derived },
    ).target == null);
    try testing.expectEqual(
        protected_fn,
        m.resolveMemberCall(
            derived,
            "guarded",
            &.{},
            .{ .lexical_owner = derived },
        ).target.?,
    );
    try testing.expectEqual(
        protected_fn,
        m.resolveMemberCall(
            derived,
            "guarded",
            &.{},
            .{ .lexical_owner = derived_nested },
        ).target.?,
    );
    try testing.expect(m.resolveMemberCall(
        base,
        "guarded",
        &.{},
        .{ .lexical_owner = derived_nested },
    ).target == null);
    try testing.expectEqual(
        protected_fn,
        m.resolveMemberCall(
            leaf,
            "guarded",
            &.{},
            .{ .lexical_owner = derived },
        ).target.?,
    );
    try testing.expect(m.resolveMemberCall(base, "guarded", &.{}, .{}).target == null);

    _ = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "String",
        .fqn = "other.String",
        .package = "other",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    const custom_pick = try pushTestFuncOpts(
        &m,
        a,
        "identityPick",
        "sample.Base.identityPick",
        "sample",
        1,
        .{ .extension = true, .param_ty = "String" },
    );
    const any_pick = try pushTestFuncOpts(
        &m,
        a,
        "identityPick",
        "sample.Base.identityPick",
        "sample",
        1,
        .{ .extension = true, .param_ty = "Any" },
    );
    const custom_identity = try a.alloc(TypeRef, 1);
    custom_identity[0] = .{
        .name = "#qual:other.String",
        .nullable = false,
        .args = &.{},
    };
    m.funcs.items[custom_pick.int()].params[1].ty.args = custom_identity;
    for ([_]FuncId{ custom_pick, any_pick }) |fid| {
        m.funcs.items[fid.int()].kind = .instance_method;
        try m.decl_sigs.put(fid.int(), .{
            .enclosing_class = base,
            .arity = .{ .required = 1, .total = 1, .has_vararg = false },
            .sig = try a.dupe(TypeRef, &.{m.funcs.items[fid.int()].params[1].ty}),
            .kind = .instance_method,
            .has_body = true,
        });
        try m.registerMemberDecl(a, "sample.Base", "identityPick", fid);
    }
    const kotlin_string = [_]applicability.ArgShape{.{
        .ty = .{ .name = "String", .nullable = false, .args = &.{} },
        .literal_kind = .string,
    }};
    try testing.expectEqual(
        any_pick,
        m.resolveMemberCall(base, "identityPick", &kotlin_string, .{}).target.?,
    );
}

test "internal member and extension visibility follows compilation modules" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    const declaration_file = FileId.from(10);
    const same_module_file = FileId.from(11);
    const other_module_file = FileId.from(12);
    try m.registry.file_modules.put(declaration_file, 4);
    try m.registry.file_modules.put(same_module_file, 4);
    try m.registry.file_modules.put(other_module_file, 5);
    try m.registry.file_packages.put(declaration_file, "sample");
    try m.registry.file_packages.put(same_module_file, "sample");
    try m.registry.file_packages.put(other_module_file, "sample");

    const owner = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Scope",
        .fqn = "sample.Scope",
        .package = "sample",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    const member = try pushTestFuncOpts(
        &m,
        a,
        "walk",
        "sample.Scope.walk",
        "sample",
        0,
        .{ .extension = true },
    );
    m.funcs.items[member.int()].kind = .instance_method;
    try m.decl_sigs.put(member.int(), .{
        .enclosing_class = owner,
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .kind = .instance_method,
        .visibility = .Internal,
        .has_body = true,
    });
    try m.decl_span.put(member.int(), Span.init(declaration_file, 0, 1));
    try m.registerMemberDecl(a, "sample.Scope", "walk", member);

    const extension = try pushTestFuncOpts(
        &m,
        a,
        "tag",
        "sample.tag",
        "sample",
        0,
        .{ .extension = true },
    );
    m.funcs.items[extension.int()].kind = .top_level_extension;
    try m.decl_sigs.put(extension.int(), .{
        .receiver_ty = .{ .name = "String", .nullable = false, .args = &.{} },
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .kind = .top_level_extension,
        .visibility = .Internal,
        .has_body = true,
    });
    try m.decl_span.put(extension.int(), Span.init(declaration_file, 2, 3));
    try m.rebuildFuncNameIndex(a);

    try testing.expectEqual(
        member,
        m.resolveMemberCall(owner, "walk", &.{}, .{
            .caller_file = same_module_file,
        }).target.?,
    );
    try testing.expect(!m.resolveMemberCall(owner, "walk", &.{}, .{
        .caller_file = other_module_file,
    }).applicable);
    try testing.expect(m.resolveMemberCall(owner, "walk", &.{}, .{}).target == null);

    const receiver = TypeRef{ .name = "String", .nullable = false, .args = &.{} };
    try testing.expectEqual(
        extension,
        m.resolveExtensionCall("tag", receiver, &.{}, .{
            .caller_file = same_module_file,
            .caller_package = "sample",
        }).target.?,
    );
    try testing.expect(!m.resolveExtensionCall("tag", receiver, &.{}, .{
        .caller_file = other_module_file,
        .caller_package = "sample",
    }).applicable);
}

test "member resolution separates class and caller function bounds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    const scope = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Scope",
        .fqn = "sample.Scope",
        .package = "sample",
        .type_params = &.{"T"},
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    try m.registry.class_type_param_bounds.put(
        "sample.Scope",
        try a.dupe(ModuleRegistry.TypeParamBound, &.{
            .{ .param = "T", .bound = "Number" },
        }),
    );
    const class_t = try classTypeParamIdentity(a, scope, "T");
    const owner_args = try a.dupe(TypeRef, &.{
        .{ .name = class_t, .nullable = false, .args = &.{} },
    });
    const choose = try pushTestFuncOpts(
        &m,
        a,
        "choose",
        "sample.Scope.choose",
        "sample",
        1,
        .{ .extension = true },
    );
    m.funcs.items[choose.int()].kind = .instance_method;
    m.funcs.items[choose.int()].params[0].ty = .{
        .name = "sample.Scope",
        .nullable = false,
        .args = owner_args,
    };
    m.funcs.items[choose.int()].params[1].ty = .{
        .name = class_t,
        .nullable = false,
        .args = &.{},
    };
    try m.decl_sigs.put(choose.int(), .{
        .enclosing_class = scope,
        .arity = .{ .required = 1, .total = 1, .has_vararg = false },
        .sig = try a.dupe(TypeRef, &.{m.funcs.items[choose.int()].params[1].ty}),
        .kind = .instance_method,
        .has_body = true,
    });
    try m.registerMemberDecl(a, "sample.Scope", "choose", choose);

    const args = [_]applicability.ArgShape{.{
        .ty = .{ .name = "T", .nullable = false, .args = &.{} },
    }};
    const actual_bounds = [_]ModuleRegistry.TypeParamBound{
        .{ .param = class_t, .bound = "Number" },
        .{ .param = "T", .bound = "CharSequence" },
    };
    const resolved = m.resolveMemberCall(scope, "choose", &args, .{
        .receiver_type = .{
            .name = "sample.Scope",
            .nullable = false,
            .args = owner_args,
        },
        .actual_type_param_bounds = &actual_bounds,
    });
    // The caller's `T : CharSequence` proves nothing against the class's
    // `T : Number` and refutes nothing either (one type can satisfy both
    // bounds), so the single candidate commits only as DEFERRED — the
    // runtime adjudicates. A `.virtual`/`.direct` result here means the
    // two bound records were conflated into a false proof.
    try testing.expect(resolved.target != null);
    try testing.expect(resolved.dispatch == .deferred);
}

test "method slots link generic overrides and multiple interface roots" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    const base = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Base",
        .fqn = "sample.Base",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
        .type_params = &.{"T"},
        .is_abstract = true,
    });
    const base_args = try a.alloc(TypeRef, 1);
    base_args[0] = .{ .name = "String", .nullable = false, .args = &.{} };
    const child_supers = try a.alloc(TypeRef, 1);
    child_supers[0] = .{ .name = "Base", .nullable = false, .args = base_args };
    const child_super_ids = try a.dupe(ClassId, &.{base});
    const child = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Child",
        .fqn = "sample.Child",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = child_super_ids,
        .supertype_refs = child_supers,
        .is_open = true,
    });
    const redundant_supers = try a.alloc(TypeRef, 2);
    redundant_supers[0] = .{ .name = "Child", .nullable = false, .args = &.{} };
    redundant_supers[1] = .{ .name = "Base", .nullable = false, .args = base_args };
    const redundant_super_ids = try a.dupe(ClassId, &.{ child, base });
    const redundant = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Redundant",
        .fqn = "sample.Redundant",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = redundant_super_ids,
        .supertype_refs = redundant_supers,
    });
    const left = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Left",
        .fqn = "sample.Left",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
        .is_abstract = true,
        .is_interface = true,
    });
    const right = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Right",
        .fqn = "sample.Right",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
        .is_abstract = true,
        .is_interface = true,
    });
    const both_supers = try a.alloc(TypeRef, 2);
    both_supers[0] = .{ .name = "Left", .nullable = false, .args = &.{} };
    both_supers[1] = .{ .name = "Right", .nullable = false, .args = &.{} };
    const both_super_ids = try a.dupe(ClassId, &.{ left, right });
    const both = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Both",
        .fqn = "sample.Both",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = both_super_ids,
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
    const base_t = try classTypeParamIdentity(a, base, "T");
    for (funcs, owners, types) |fid, owner, ty| {
        const declared_ty = if (fid == base_put) base_t else ty;
        m.funcs.items[fid.int()].params[0].ty.name = declared_ty;
        try m.decl_sigs.put(fid.int(), .{
            .enclosing_class = owner,
            .arity = .{ .required = 1, .total = 1, .has_vararg = false },
            .sig = &.{.{ .name = declared_ty, .nullable = false, .args = &.{} }},
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
        .id = ClassId.from(0),
        .name = "Modifier",
        .fqn = "sample.Modifier",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
        .is_abstract = true,
        .is_interface = true,
    });
    _ = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Modifier.Element",
        .fqn = "sample.Modifier.Element",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
        .is_abstract = true,
        .is_interface = true,
    });
    const combined = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Combined",
        .fqn = "sample.Combined",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = try a.dupe(ClassId, &.{modifier}),
        .supertype_refs = try a.dupe(TypeRef, &.{.{
            .name = "Modifier",
            .nullable = false,
            .args = &.{},
        }}),
    });
    const root_all = try pushTestFuncOpts(&m, a, "all", "sample.Modifier.all", "sample", 1, .{
        .stub = true,
        .param_ty = "Element",
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

    const shadow_base = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "ShadowBase",
        .fqn = "sample.ShadowBase",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
        .type_params = &.{"T"},
        .is_open = true,
    });
    const shadow_child_arg = try a.dupe(TypeRef, &.{.{
        .name = "X",
        .nullable = false,
        .args = &.{},
    }});
    const shadow_child = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "ShadowChild",
        .fqn = "sample.ShadowChild",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = try a.dupe(ClassId, &.{shadow_base}),
        .supertype_refs = try a.dupe(TypeRef, &.{.{
            .name = "ShadowBase",
            .nullable = false,
            .args = shadow_child_arg,
        }}),
        .type_params = &.{"X"},
    });
    const base_pick = try pushTestFuncOpts(
        &m,
        a,
        "pick",
        "sample.ShadowBase.pick",
        "sample",
        1,
        .{ .stub = true, .param_ty = "T" },
    );
    const child_pick = try pushTestFuncOpts(
        &m,
        a,
        "pick",
        "sample.ShadowChild.pick",
        "sample",
        1,
        .{ .param_ty = "T" },
    );
    for ([_]FuncId{ base_pick, child_pick }) |fid| {
        m.funcs.items[fid.int()].kind = .instance_method;
        var method_type_params: std.ArrayList([]const u8) = .empty;
        try method_type_params.append(a, "T");
        try m.registry.func_type_params.put(fid, method_type_params);
    }
    m.funcs.items[child_pick.int()].is_override = true;
    m.classes.items[shadow_base.int()].methods = try a.dupe(FuncId, &.{base_pick});
    m.classes.items[shadow_child.int()].methods = try a.dupe(FuncId, &.{child_pick});
    for (
        [_]FuncId{ base_pick, child_pick },
        [_]ClassId{ shadow_base, shadow_child },
    ) |fid, owner| {
        try m.decl_sigs.put(fid.int(), .{
            .enclosing_class = owner,
            .arity = .{ .required = 1, .total = 1, .has_vararg = false },
            .sig = try a.dupe(TypeRef, &.{.{
                .name = "T",
                .nullable = false,
                .args = &.{},
            }}),
            .kind = .instance_method,
            .has_body = m.funcs.items[fid.int()].hasBody(),
        });
        try m.registerMemberDecl(a, m.classes.items[owner.int()].fqn, "pick", fid);
    }
    try m.linkMethodSlots(a);
    try testing.expectEqual(
        child_pick,
        m.methodSlotTarget(shadow_child, MethodSlotId.fromFunc(base_pick)).?,
    );
}

test "a redeclared interface slot reaches the body inherited beside it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    const root = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Root",
        .fqn = "sample.Root",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
        .is_abstract = true,
        .is_interface = true,
    });
    const redecl_supers = try a.alloc(TypeRef, 1);
    redecl_supers[0] = .{ .name = "Root", .nullable = false, .args = &.{} };
    const redecl = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Redecl",
        .fqn = "sample.Redecl",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = try a.dupe(ClassId, &.{root}),
        .supertype_refs = redecl_supers,
        .is_abstract = true,
        .is_interface = true,
    });
    const impl_supers = try a.alloc(TypeRef, 1);
    impl_supers[0] = .{ .name = "Root", .nullable = false, .args = &.{} };
    const impl = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Impl",
        .fqn = "sample.Impl",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = try a.dupe(ClassId, &.{root}),
        .supertype_refs = impl_supers,
        .is_abstract = true,
    });
    const leaf_supers = try a.alloc(TypeRef, 2);
    leaf_supers[0] = .{ .name = "Impl", .nullable = false, .args = &.{} };
    leaf_supers[1] = .{ .name = "Redecl", .nullable = false, .args = &.{} };
    const leaf = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Leaf",
        .fqn = "sample.Leaf",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = try a.dupe(ClassId, &.{ impl, redecl }),
        .supertype_refs = leaf_supers,
    });

    const root_del = try pushTestFuncOpts(&m, a, "del", "sample.Root.del", "sample", 1, .{ .stub = true });
    const redecl_del = try pushTestFuncOpts(&m, a, "del", "sample.Redecl.del", "sample", 1, .{ .stub = true });
    const impl_del = try pushTestFuncOpts(&m, a, "del", "sample.Impl.del", "sample", 1, .{});
    for ([_]FuncId{ root_del, redecl_del, impl_del }) |fid| m.funcs.items[fid.int()].kind = .instance_method;
    m.funcs.items[redecl_del.int()].is_override = true;
    m.funcs.items[impl_del.int()].is_override = true;
    m.classes.items[impl.int()].methods = try a.dupe(FuncId, &.{impl_del});

    const owners = [_]ClassId{ root, redecl, impl };
    const funcs = [_]FuncId{ root_del, redecl_del, impl_del };
    for (funcs, owners) |fid, owner| {
        try m.decl_sigs.put(fid.int(), .{
            .enclosing_class = owner,
            .arity = .{ .required = 1, .total = 1, .has_vararg = false },
            .sig = try a.dupe(TypeRef, &.{.{ .name = "Int", .nullable = false, .args = &.{} }}),
            .kind = .instance_method,
            .has_body = m.funcs.items[fid.int()].hasBody(),
        });
        try m.registerMemberDecl(a, m.classes.items[owner.int()].fqn, "del", fid);
    }

    try m.linkMethodSlots(a);
    // The base family reaches the body, and the redeclaration's own slot must
    // reach the SAME body rather than the bodyless header it inherits.
    try testing.expectEqual(impl_del, m.methodSlotTarget(leaf, MethodSlotId.fromFunc(root_del)).?);
    try testing.expectEqual(impl_del, m.methodSlotTarget(leaf, MethodSlotId.fromFunc(redecl_del)).?);
    // With no body anywhere in the family, the header stays as linked.
    try testing.expectEqual(redecl_del, m.methodSlotTarget(redecl, MethodSlotId.fromFunc(redecl_del)).?);

    // Resolution over a redeclaration chain: equal-scoring redeclarations are
    // one slot family, not an overload tie, and a zero-argument call has no
    // parameter for an unprojectable bare receiver to turn unknown. Both
    // wrong answers came back as `dispatch=deferred` with no target — the
    // `Set.iterator()` shape.
    const root_size = try pushTestFuncOpts(&m, a, "size", "sample.Root.size", "sample", 0, .{ .stub = true });
    const redecl_size = try pushTestFuncOpts(&m, a, "size", "sample.Redecl.size", "sample", 0, .{ .stub = true });
    for ([_]FuncId{ root_size, redecl_size }) |fid| m.funcs.items[fid.int()].kind = .instance_method;
    m.funcs.items[redecl_size.int()].is_override = true;
    const size_owners = [_]ClassId{ root, redecl };
    const size_funcs = [_]FuncId{ root_size, redecl_size };
    for (size_funcs, size_owners) |fid, owner| {
        try m.decl_sigs.put(fid.int(), .{
            .enclosing_class = owner,
            .arity = .{ .required = 0, .total = 0, .has_vararg = false },
            .sig = &.{},
            .kind = .instance_method,
            .has_body = false,
        });
        try m.registerMemberDecl(a, m.classes.items[owner.int()].fqn, "size", fid);
    }
    const bare_recv = TypeRef{ .name = "Redecl", .nullable = false, .args = &.{} };
    const res = m.resolveMemberCall(redecl, "size", &.{}, .{
        .receiver_type = bare_recv,
    });
    try testing.expect(res.dispatch != .deferred);
    try testing.expectEqual(redecl_size, res.target.?);

    // The GENERIC owner is where the bare receiver bites: `Set<E>` cannot be
    // projected from a bare `Set` head, and that unknown must not defer a
    // call with no parameters to instantiate.
    const groot = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "GRoot",
        .fqn = "sample.GRoot",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
        .type_params = &.{"E"},
        .is_abstract = true,
        .is_interface = true,
    });
    const gredecl_args = try a.alloc(TypeRef, 1);
    gredecl_args[0] = .{ .name = "E", .nullable = false, .args = &.{} };
    const gredecl_supers = try a.alloc(TypeRef, 1);
    gredecl_supers[0] = .{ .name = "GRoot", .nullable = false, .args = gredecl_args };
    const gredecl = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "GRedecl",
        .fqn = "sample.GRedecl",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = try a.dupe(ClassId, &.{groot}),
        .supertype_refs = gredecl_supers,
        .type_params = &.{"E"},
        .is_abstract = true,
        .is_interface = true,
    });
    const groot_first = try pushTestFuncOpts(&m, a, "first", "sample.GRoot.first", "sample", 0, .{ .stub = true });
    const gredecl_first = try pushTestFuncOpts(&m, a, "first", "sample.GRedecl.first", "sample", 0, .{ .stub = true });
    for ([_]FuncId{ groot_first, gredecl_first }) |fid| m.funcs.items[fid.int()].kind = .instance_method;
    m.funcs.items[gredecl_first.int()].is_override = true;
    const first_owners = [_]ClassId{ groot, gredecl };
    const first_funcs = [_]FuncId{ groot_first, gredecl_first };
    for (first_funcs, first_owners) |fid, owner| {
        try m.decl_sigs.put(fid.int(), .{
            .enclosing_class = owner,
            .arity = .{ .required = 0, .total = 0, .has_vararg = false },
            .sig = &.{},
            .kind = .instance_method,
            .has_body = false,
        });
        try m.registerMemberDecl(a, m.classes.items[owner.int()].fqn, "first", fid);
    }
    const bare_generic = TypeRef{ .name = "GRedecl", .nullable = false, .args = &.{} };
    const gres = m.resolveMemberCall(gredecl, "first", &.{}, .{
        .receiver_type = bare_generic,
    });
    try testing.expect(gres.dispatch != .deferred);
    try testing.expectEqual(gredecl_first, gres.target.?);
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
    // `KeyframesSpecConfig`.
    const std_with = try pushTestFuncOpts(&m, a, "with", "kotlin.with", "kotlin", 2, .{ .stub = true });
    const member_with = try pushTestFuncOpts(&m, a, "with", "with", "", 1, .{ .stub = true, .extension = true });
    m.funcs.items[std_with.int()].params[0].ty.name = "Any";
    m.funcs.items[std_with.int()].params[1].ty.name = "Function1";
    m.funcs.items[member_with.int()].kind = .member_extension;
    try m.registry.member_ext_owner_class.put(member_with, "KeyframesSpecConfig");
    const std_sig = [_]TypeRef{
        .{ .name = "Any", .nullable = false, .args = &.{} },
        .{ .name = "Function1", .nullable = false, .args = &.{} },
    };
    try m.decl_sigs.put(std_with.int(), .{
        .arity = .{ .required = 2, .total = 2, .has_vararg = false },
        .sig = &std_sig,
        .kind = .plain,
        .has_body = true,
    });
    const member_sig = [_]TypeRef{
        .{ .name = "Int", .nullable = false, .args = &.{} },
    };
    try m.decl_sigs.put(member_with.int(), .{
        .arity = .{ .required = 1, .total = 1, .has_vararg = false },
        .receiver_ty = .{ .name = "String", .nullable = false, .args = &.{} },
        .sig = &member_sig,
        .kind = .member_extension,
        .has_body = true,
    });
    try m.rebuildFuncNameIndex(a);

    const global_args = [_]applicability.ArgShape{
        .{ .ty = .{ .name = "String", .nullable = false, .args = &.{} } },
        .{ .is_lambda = true, .lambda_arity = 1 },
    };
    // A caller inside an unrelated class has no `KeyframesSpecConfig`
    // receiver, so the member extension is not a candidate: `kotlin.with`.
    const res = try m.resolveCall(a, "with", "androidx.compose.ui.text", FileId.from(0), &global_args, true, .{
        .in_receiver_context = true,
        .owner_class = "MultiParagraph",
    });
    defer a.free(res.candidate_set);
    try testing.expect(res.target != null);
    try testing.expectEqual(std_with.int(), res.target.?.int());

    // Inside the declaring class the member extension IS in scope.
    const member_args = [_]applicability.ArgShape{
        .{ .ty = .{ .name = "Int", .nullable = false, .args = &.{} } },
    };
    const own = try m.resolveCall(a, "with", "androidx.compose.animation.core", FileId.from(0), &member_args, false, .{
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
    const any_arg = try pushTestFuncOpts(&m, a, "paint", "app.paint", "app", 1, .{ .extension = true, .param_ty = "Any" });
    m.funcs.items[any_arg.int()].kind = .top_level_extension;
    const int_receiver = try pushTestFuncOpts(&m, a, "paint", "app.paint", "app", 1, .{ .extension = true });
    m.funcs.items[int_receiver.int()].kind = .top_level_extension;
    m.funcs.items[int_receiver.int()].params[0].ty.name = "Int";
    _ = try pushTestFuncOpts(&m, a, "hidden", "other.hidden", "other", 0, .{ .extension = true });
    m.funcs.items[m.funcs.items.len - 1].kind = .top_level_extension;
    const repeat = try pushTestFuncOpts(&m, a, "repeat", "kotlin.text.repeat", "kotlin.text", 1, .{
        .stub = true,
        .extension = true,
    });
    m.funcs.items[repeat.int()].kind = .top_level_extension;
    m.funcs.items[repeat.int()].params[0].ty.name = "CharSequence";
    try m.decl_sigs.put(repeat.int(), .{
        .receiver_ty = .{ .name = "CharSequence", .nullable = false, .args = &.{} },
        .arity = .{ .required = 1, .total = 1, .has_vararg = false },
        .sig = &.{.{ .name = "Int", .nullable = false, .args = &.{} }},
        .kind = .top_level_extension,
        .host_symbol = "kotlin.CharSequence.repeat",
    });
    const starts_with = try pushTestFuncOpts(&m, a, "startsWith", "kotlin.text.startsWith", "kotlin.text", 2, .{
        .stub = true,
        .extension = true,
        .param_ty = "String",
    });
    m.funcs.items[starts_with.int()].kind = .top_level_extension;
    m.funcs.items[starts_with.int()].params[2].ty.name = "Boolean";
    m.funcs.items[starts_with.int()].params[2].has_default = true;
    try m.decl_sigs.put(starts_with.int(), .{
        .receiver_ty = .{ .name = "String", .nullable = false, .args = &.{} },
        .arity = .{ .required = 1, .total = 2, .has_vararg = false },
        .sig = &.{
            .{ .name = "String", .nullable = false, .args = &.{} },
            .{ .name = "Boolean", .nullable = false, .args = &.{} },
        },
        .kind = .top_level_extension,
        .host_symbol = "kotlin.String.startsWith",
    });
    const shipped_origin = try pushTestFuncOpts(&m, a, "origin", "kotlin.text.origin", "kotlin.text", 0, .{
        .extension = true,
    });
    m.funcs.items[shipped_origin.int()].kind = .top_level_extension;
    const user_origin = try pushTestFuncOpts(&m, a, "origin", "user.extensions.origin", "user.extensions", 0, .{
        .extension = true,
    });
    m.funcs.items[user_origin.int()].kind = .top_level_extension;
    m.funcs.items[user_origin.int()].params[0].ty.name = "Any";
    var origin_wildcards: std.ArrayList([]const u8) = .empty;
    try origin_wildcards.append(a, try a.dupe(u8, "kotlin.text"));
    try origin_wildcards.append(a, try a.dupe(u8, "user.extensions"));
    try m.registry.import_wildcards.put(FileId.from(1), origin_wildcards);

    const long_literal = try pushTestFuncOpts(&m, a, "literalPick", "app.literalPick", "app", 1, .{
        .extension = true,
        .param_ty = "Long",
    });
    m.funcs.items[long_literal.int()].kind = .top_level_extension;
    const any_literal = try pushTestFuncOpts(&m, a, "literalPick", "app.literalPick", "app", 1, .{
        .extension = true,
        .param_ty = "Any",
    });
    m.funcs.items[any_literal.int()].kind = .top_level_extension;

    const alias_pick = try pushTestFuncOpts(&m, a, "aliasPick", "app.aliasPick", "app", 0, .{
        .extension = true,
    });
    m.funcs.items[alias_pick.int()].kind = .top_level_extension;
    m.funcs.items[alias_pick.int()].params[0].ty.name = "Text";
    const any_alias_pick = try pushTestFuncOpts(&m, a, "aliasPick", "app.aliasPick", "app", 0, .{
        .extension = true,
    });
    m.funcs.items[any_alias_pick.int()].kind = .top_level_extension;
    m.funcs.items[any_alias_pick.int()].params[0].ty.name = "Any";
    try m.registry.type_aliases.put("Text", "String");

    const bounded_pick = try pushTestFuncOpts(&m, a, "boundedPick", "app.boundedPick", "app", 0, .{
        .extension = true,
    });
    m.funcs.items[bounded_pick.int()].kind = .top_level_extension;
    m.funcs.items[bounded_pick.int()].params[0].ty.name = "CharSequence";
    const any_bounded_pick = try pushTestFuncOpts(&m, a, "boundedPick", "app.boundedPick", "app", 0, .{
        .extension = true,
    });
    m.funcs.items[any_bounded_pick.int()].kind = .top_level_extension;
    m.funcs.items[any_bounded_pick.int()].params[0].ty.name = "Any";
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

    const host_backed = m.resolveExtensionCall("repeat", .{
        .name = "String",
        .nullable = false,
        .args = &.{},
    }, &typed_args, .{ .caller_file = FileId.from(0), .caller_package = "app" });
    try testing.expectEqual(repeat.int(), host_backed.target.?.int());

    const string_args = [_]applicability.ArgShape{.{
        .ty = .{ .name = "String", .nullable = false, .args = &.{} },
    }};
    const defaulted = m.resolveExtensionCall("startsWith", .{
        .name = "String",
        .nullable = false,
        .args = &.{},
    }, &string_args, .{ .caller_file = FileId.from(0), .caller_package = "app" });
    try testing.expectEqual(starts_with.int(), defaulted.target.?.int());

    const ordered_named_args = [_]applicability.ArgShape{.{
        .ty = .{ .name = "String", .nullable = false, .args = &.{} },
        .named = "x",
    }};
    const ordered_named = m.resolveExtensionCall("startsWith", .{
        .name = "String",
        .nullable = false,
        .args = &.{},
    }, &ordered_named_args, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
    });
    try testing.expectEqual(starts_with.int(), ordered_named.target.?.int());

    const wrong_named_args = [_]applicability.ArgShape{.{
        .ty = .{ .name = "String", .nullable = false, .args = &.{} },
        .named = "other",
    }};
    try testing.expect(m.resolveExtensionCall("startsWith", .{
        .name = "String",
        .nullable = false,
        .args = &.{},
    }, &wrong_named_args, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
    }).target == null);

    const origin = m.resolveExtensionCall("origin", .{
        .name = "String",
        .nullable = false,
        .args = &.{},
    }, &.{}, .{ .caller_file = FileId.from(1), .caller_package = "app" });
    try testing.expectEqual(shipped_origin.int(), origin.target.?.int());

    const numeric_literal = [_]applicability.ArgShape{.{
        .ty = .{ .name = "Int", .nullable = false, .args = &.{} },
        .literal_kind = .numeric,
    }};
    // kotlinc: an integer literal materializes as Long in a Long slot, and
    // the Long overload is more specific than Any — the pick is static.
    try testing.expectEqual(long_literal.int(), m.resolveExtensionCall("literalPick", .{
        .name = "String",
        .nullable = false,
        .args = &.{},
    }, &numeric_literal, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
    }).target.?.int());

    try testing.expect(m.resolveExtensionCall("aliasPick", .{
        .name = "String",
        .nullable = false,
        .args = &.{},
    }, &.{}, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
    }).target == null);

    try testing.expect(m.resolveExtensionCall("boundedPick", .{
        .name = "T",
        .nullable = false,
        .args = &.{},
    }, &.{}, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
    }).target == null);
}

test "extension resolver expands receiver aliases in their file scope" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    const compound = try pushTestFuncOpts(
        &m,
        a,
        "compoundWith",
        "app.compoundWith",
        "app",
        0,
        .{ .extension = true },
    );
    m.funcs.items[compound.int()].kind = .top_level_extension;
    m.funcs.items[compound.int()].params[0].ty.name = "Long";
    try m.decl_sigs.put(compound.int(), .{
        .receiver_ty = .{
            .name = "CompositeKeyHashCode",
            .nullable = false,
            .args = &.{},
        },
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .sig = &.{},
        .kind = .top_level_extension,
        .has_body = true,
    });
    try m.decl_span.put(
        compound.int(),
        Span.init(FileId.from(1), 0, 1),
    );
    try m.registry.file_packages.put(FileId.from(1), "app");
    try m.registry.file_packages.put(FileId.from(2), "app");
    try m.registry.type_alias_types.put("app.CompositeKeyHashCode", .{
        .type_params = &.{},
        .target = .{ .name = "Long", .nullable = false, .args = &.{} },
    });
    try m.registry.type_alias_types.put("other.CompositeKeyHashCode", .{
        .type_params = &.{},
        .target = .{ .name = "String", .nullable = false, .args = &.{} },
    });
    try m.registry.type_alias_types.put("CompositeKeyHashCode", .{
        .type_params = &.{},
        .target = .{ .name = "String", .nullable = false, .args = &.{} },
    });
    try m.registry.type_aliases.put("CompositeKeyHashCode", "String");
    try m.rebuildFuncNameIndex(a);

    const resolved = m.resolveExtensionCall(
        "compoundWith",
        .{
            .name = "CompositeKeyHashCode",
            .nullable = false,
            .args = &.{},
        },
        &.{},
        .{
            .caller_file = FileId.from(2),
            .caller_package = "app",
        },
    );
    try testing.expectEqual(compound, resolved.target.?);
}

test "extension resolver admits source bodies and defers possible member shadows" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    const source = try pushTestFuncOpts(&m, a, "sourceOnly", "kotlin.text.sourceOnly", "kotlin.text", 0, .{
        .stub = true,
        .extension = true,
    });
    m.funcs.items[source.int()].kind = .top_level_extension;
    try m.decl_sigs.put(source.int(), .{
        .receiver_ty = .{ .name = "String", .nullable = false, .args = &.{} },
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .sig = &.{},
        .kind = .top_level_extension,
        .has_body = true,
    });
    try m.decl_ast_body.put(source.int(), {});
    const stdlib = try pushTestFuncOpts(&m, a, "isBlank", "kotlin.text.isBlank", "kotlin.text", 0, .{
        .extension = true,
    });
    m.funcs.items[stdlib.int()].kind = .top_level_extension;
    const member = try pushTestFuncOpts(&m, a, "isBlank", "app.Scope.isBlank", "app", 0, .{
        .extension = true,
    });
    m.funcs.items[member.int()].kind = .member_extension;
    try m.registry.member_ext_owner_class.put(member, "Scope");
    const bodyless = try pushTestFuncOpts(&m, a, "headerOnly", "kotlin.text.headerOnly", "kotlin.text", 0, .{
        .stub = true,
        .extension = true,
    });
    m.funcs.items[bodyless.int()].kind = .top_level_extension;

    const generic_top = try pushTestFuncOpts(&m, a, "tag", "app.tag", "app", 0, .{
        .extension = true,
    });
    m.funcs.items[generic_top.int()].kind = .top_level_extension;
    const generic_member = try pushTestFuncOpts(&m, a, "tag", "app.Scope.tag", "app", 0, .{
        .extension = true,
    });
    m.funcs.items[generic_member.int()].kind = .member_extension;
    try m.registry.member_ext_owner_class.put(generic_member, "Scope");
    const string_receiver_args = try a.alloc(TypeRef, 1);
    defer a.free(string_receiver_args);
    string_receiver_args[0] = .{ .name = "String", .nullable = false, .args = &.{} };
    m.funcs.items[generic_top.int()].params[0].ty = .{
        .name = "List",
        .nullable = false,
        .args = string_receiver_args,
    };
    const type_var_receiver_args = try a.alloc(TypeRef, 1);
    defer a.free(type_var_receiver_args);
    type_var_receiver_args[0] = .{ .name = "T", .nullable = false, .args = &.{} };
    m.funcs.items[generic_member.int()].params[0].ty = .{
        .name = "List",
        .nullable = false,
        .args = type_var_receiver_args,
    };

    const starts_with = try pushTestFuncOpts(&m, a, "startsWith", "kotlin.text.startsWith", "kotlin.text", 1, .{
        .extension = true,
        .param_ty = "String",
    });
    m.funcs.items[starts_with.int()].kind = .top_level_extension;
    const hidden_starts_with = try pushTestFuncOpts(&m, a, "startsWith", "app.HiddenExtensions.startsWith", "app", 1, .{
        .extension = true,
        .param_ty = "String",
    });
    m.funcs.items[hidden_starts_with.int()].kind = .member_extension;
    try m.registry.member_ext_owner_class.put(hidden_starts_with, "HiddenExtensions");
    try m.registry.object_names.append(a, "HiddenExtensions");
    try m.rebuildFuncNameIndex(a);

    const receiver = TypeRef{ .name = "String", .nullable = false, .args = &.{} };
    const source_body = m.resolveExtensionCall("sourceOnly", receiver, &.{}, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
    });
    try testing.expectEqual(source.int(), source_body.target.?.int());

    const unshadowed = m.resolveExtensionCall("isBlank", receiver, &.{}, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
    });
    try testing.expectEqual(stdlib.int(), unshadowed.target.?.int());
    const shadowed = m.resolveExtensionCall("isBlank", receiver, &.{}, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
        .lexical_owner = "Scope",
    });
    try testing.expectEqual(member, shadowed.target.?);

    const unresolved = m.resolveExtensionCall("headerOnly", receiver, &.{}, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
    });
    try testing.expect(unresolved.target == null);

    const generic_shadow = m.resolveExtensionCall("tag", .{
        .name = "List",
        .nullable = false,
        .args = string_receiver_args,
    }, &.{}, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
    });
    try testing.expectEqual(generic_top.int(), generic_shadow.target.?.int());
    const scoped_generic_shadow = m.resolveExtensionCall("tag", .{
        .name = "List",
        .nullable = false,
        .args = string_receiver_args,
    }, &.{}, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
        .implicit_dispatch_owners = &.{"Scope"},
    });
    try testing.expect(scoped_generic_shadow.target == null);

    const string_arg = [_]applicability.ArgShape{.{
        .ty = .{ .name = "String", .nullable = false, .args = &.{} },
    }};
    const hidden_object = m.resolveExtensionCall("startsWith", receiver, &string_arg, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
    });
    try testing.expectEqual(starts_with.int(), hidden_object.target.?.int());

    const visible_object = m.resolveExtensionCall("startsWith", receiver, &string_arg, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
        .implicit_dispatch_owners = &.{"StringBuilder"},
        .lexical_owner = "HiddenExtensions",
    });
    try testing.expectEqual(hidden_starts_with, visible_object.target.?);
}

test "member extension resolution keeps qualified declaring owners distinct" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    const left_owner = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Scope",
        .fqn = "left.Scope",
        .package = "left",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    const right_owner = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Scope",
        .fqn = "right.Scope",
        .package = "right",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    const left = try pushTestFuncOpts(
        &m,
        a,
        "tag",
        "left.Scope.tag",
        "left",
        0,
        .{ .extension = true },
    );
    const right = try pushTestFuncOpts(
        &m,
        a,
        "tag",
        "right.Scope.tag",
        "right",
        0,
        .{ .extension = true },
    );
    for ([_]struct { fid: FuncId, owner: ClassId, fqn: []const u8 }{
        .{ .fid = left, .owner = left_owner, .fqn = "left.Scope" },
        .{ .fid = right, .owner = right_owner, .fqn = "right.Scope" },
    }) |entry| {
        m.funcs.items[entry.fid.int()].kind = .member_extension;
        m.funcs.items[entry.fid.int()].params[0].ty = .{
            .name = "String",
            .nullable = false,
            .args = &.{},
        };
        try m.registry.member_ext_owner_class.put(entry.fid, entry.fqn);
        try m.decl_sigs.put(entry.fid.int(), .{
            .enclosing_class = entry.owner,
            .receiver_ty = m.funcs.items[entry.fid.int()].params[0].ty,
            .arity = .{ .required = 0, .total = 0, .has_vararg = false },
            .sig = &.{},
            .kind = .member_extension,
            .has_body = true,
        });
    }
    try m.rebuildFuncNameIndex(a);

    const resolved = m.resolveExtensionCall(
        "tag",
        .{ .name = "String", .nullable = false, .args = &.{} },
        &.{},
        .{
            .caller_file = FileId.from(0),
            .caller_package = "left",
            .lexical_owner = "Scope",
        },
    );
    try testing.expectEqual(left, resolved.target.?);
    try testing.expectEqual(left_owner, resolved.dispatch_owner.?);

    const right_innermost = m.resolveExtensionCall(
        "tag",
        .{ .name = "String", .nullable = false, .args = &.{} },
        &.{},
        .{
            .caller_file = FileId.from(0),
            .caller_package = "left",
            .implicit_dispatch_owners = &.{ "right.Scope", "left.Scope" },
        },
    );
    try testing.expectEqual(right, right_innermost.target.?);
    try testing.expectEqual(right_owner, right_innermost.dispatch_owner.?);

    const left_innermost = m.resolveExtensionCall(
        "tag",
        .{ .name = "String", .nullable = false, .args = &.{} },
        &.{},
        .{
            .caller_file = FileId.from(0),
            .caller_package = "right",
            .implicit_dispatch_owners = &.{ "left.Scope", "right.Scope" },
        },
    );
    try testing.expectEqual(left, left_innermost.target.?);
    try testing.expectEqual(left_owner, left_innermost.dispatch_owner.?);
}

test "extension resolver does not erase incompatible generic receiver arguments" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    const ext = try pushTestFuncOpts(&m, a, "consume", "app.consume", "app", 0, .{
        .extension = true,
    });
    m.funcs.items[ext.int()].kind = .top_level_extension;
    const int_args = try a.alloc(TypeRef, 1);
    defer a.free(int_args);
    int_args[0] = .{ .name = "Int", .nullable = false, .args = &.{} };
    m.funcs.items[ext.int()].params[0].ty = .{
        .name = "Iterable",
        .nullable = false,
        .args = int_args,
    };
    const broad = try pushTestFuncOpts(&m, a, "consume", "app.consume", "app", 0, .{
        .extension = true,
    });
    m.funcs.items[broad.int()].kind = .top_level_extension;
    m.funcs.items[broad.int()].params[0].ty.name = "Any";
    const generic = try pushTestFuncOpts(&m, a, "genericConsume", "app.genericConsume", "app", 0, .{
        .extension = true,
    });
    m.funcs.items[generic.int()].kind = .top_level_extension;
    const generic_args = try a.alloc(TypeRef, 1);
    defer a.free(generic_args);
    generic_args[0] = .{ .name = "T", .nullable = false, .args = &.{} };
    m.funcs.items[generic.int()].params[0].ty = .{
        .name = "Iterable",
        .nullable = false,
        .args = generic_args,
    };
    var type_params: std.ArrayList([]const u8) = .empty;
    try type_params.append(a, "T");
    try m.registry.func_type_params.put(generic, type_params);
    try m.rebuildFuncNameIndex(a);

    const string_args = try a.alloc(TypeRef, 1);
    defer a.free(string_args);
    string_args[0] = .{ .name = "String", .nullable = false, .args = &.{} };
    const resolved = m.resolveExtensionCall("consume", .{
        .name = "Iterable",
        .nullable = false,
        .args = string_args,
    }, &.{}, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
    });
    try testing.expectEqual(broad.int(), resolved.target.?.int());

    const generic_proven = m.resolveExtensionCall("genericConsume", .{
        .name = "Iterable",
        .nullable = false,
        .args = string_args,
    }, &.{}, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
    });
    try testing.expectEqual(generic, generic_proven.target.?);
}

test "extension resolver retains a unique generic receiver lambda target" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    const apply = try pushTestFuncOpts(&m, a, "apply", "kotlin.apply", "kotlin", 1, .{
        .extension = true,
        .param_ty = "Function0",
    });
    m.funcs.items[apply.int()].kind = .top_level_extension;
    m.funcs.items[apply.int()].params[0].ty.name = "T";
    const function_args = try a.alloc(TypeRef, 2);
    defer a.free(function_args);
    function_args[0] = .{ .name = "T", .nullable = false, .args = &.{} };
    function_args[1] = .{ .name = "Unit", .nullable = false, .args = &.{} };
    m.funcs.items[apply.int()].params[1].ty.args = function_args;
    var type_params: std.ArrayList([]const u8) = .empty;
    try type_params.append(a, "T");
    try type_params.append(a, "R");
    try m.registry.func_type_params.put(apply, type_params);
    try m.rebuildFuncNameIndex(a);

    const args = [_]applicability.ArgShape{.{
        .is_lambda = true,
        .lambda_arity = 0,
        .lambda_is_literal = true,
    }};
    const resolved = m.resolveExtensionCall("apply", .{
        .name = "LongArray",
        .nullable = false,
        .args = &.{},
    }, &args, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
    });
    try testing.expectEqual(apply, resolved.target.?);
}

test "callable extension properties resolve instance and companion receivers" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    var actions: std.ArrayList(ModuleRegistry.CallableExtensionProp) = .empty;
    try actions.append(a, .{
        .fqn = "app.action",
        .package = "app",
        .receiver = "Widget",
        .file = FileId.from(1),
        .value_arity = 1,
        .is_private = false,
    });
    try m.registry.callable_extension_props.put("action", actions);

    const action = m.resolveCallableExtensionProperty(
        "action",
        "Widget",
        false,
        1,
        "app",
        FileId.from(0),
    ) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("app.action", action.fqn);
    try testing.expect(m.resolveCallableExtensionProperty(
        "action",
        "Widget",
        false,
        0,
        "app",
        FileId.from(0),
    ) == null);

    var insets: std.ArrayList(ModuleRegistry.CallableExtensionProp) = .empty;
    try insets.append(a, .{
        .fqn = "app.systemBars",
        .package = "app",
        .receiver = "WindowInsets.Companion",
        .file = FileId.from(1),
        .value_arity = 0,
        .is_private = false,
    });
    try m.registry.callable_extension_props.put("systemBars", insets);

    const system_bars = m.resolveCallableExtensionProperty(
        "systemBars",
        "WindowInsets",
        true,
        0,
        "app",
        FileId.from(0),
    ) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("app.systemBars", system_bars.fqn);
    try testing.expect(m.resolveCallableExtensionProperty(
        "systemBars",
        "WindowInsets",
        false,
        0,
        "app",
        FileId.from(0),
    ) == null);
}

test "extension resolver ranks proven generic argument structure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    const element = try pushTestFuncOpts(&m, a, "plus", "app.plus", "app", 1, .{
        .extension = true,
        .param_ty = "T",
    });
    const array = try pushTestFuncOpts(&m, a, "plus", "app.plus", "app", 1, .{
        .extension = true,
        .param_ty = "Array",
    });
    const sequence = try pushTestFuncOpts(&m, a, "plus", "app.plus", "app", 1, .{
        .extension = true,
        .param_ty = "Sequence",
    });
    const t_args = try a.alloc(TypeRef, 1);
    t_args[0] = .{ .name = "T", .nullable = false, .args = &.{} };
    for ([_]FuncId{ element, array, sequence }) |fid| {
        m.funcs.items[fid.int()].kind = .top_level_extension;
        m.funcs.items[fid.int()].params[0].ty = .{
            .name = "Collection",
            .nullable = false,
            .args = t_args,
        };
        var type_params: std.ArrayList([]const u8) = .empty;
        try type_params.append(a, "T");
        try m.registry.func_type_params.put(fid, type_params);
    }
    m.funcs.items[array.int()].params[1].ty.args = t_args;
    m.funcs.items[sequence.int()].params[1].ty.args = t_args;
    m.funcs.items[sequence.int()].return_ty = .{
        .name = "Sequence",
        .nullable = false,
        .args = t_args,
    };
    try m.rebuildFuncNameIndex(a);

    const int_args = try a.alloc(TypeRef, 1);
    int_args[0] = .{ .name = "Int", .nullable = false, .args = &.{} };
    const receiver = TypeRef{
        .name = "Collection",
        .nullable = false,
        .args = int_args,
    };
    const args = [_]applicability.ArgShape{.{
        .ty = .{ .name = "Sequence", .nullable = false, .args = int_args },
    }};
    const resolved = m.resolveExtensionCall("plus", receiver, &args, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
    });
    try testing.expectEqual(sequence, resolved.target.?);

    var return_ty = (try m.instantiatedCallReturnType(
        a,
        sequence,
        receiver,
        null,
        &args,
        &.{},
    )).?;
    defer return_ty.deinit(a);
    try testing.expectEqualStrings("Sequence", return_ty.name);
    try testing.expectEqual(@as(usize, 1), return_ty.args.len);
    try testing.expectEqualStrings("Int", return_ty.args[0].name);
}

test "member return instantiation separates class and function type parameters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    const box = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Box",
        .fqn = "app.Box",
        .package = "app",
        .type_params = &.{"String"},
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    const class_identity = try classTypeParamIdentity(a, box, "String");
    const class_arg = try a.dupe(TypeRef, &.{
        .{ .name = class_identity, .nullable = false, .args = &.{} },
    });
    const actual_arg = try a.dupe(TypeRef, &.{
        .{ .name = "Int", .nullable = false, .args = &.{} },
    });
    const box_pattern = TypeRef{
        .name = "app.Box",
        .nullable = false,
        .args = class_arg,
    };
    const box_int = TypeRef{
        .name = "app.Box",
        .nullable = false,
        .args = actual_arg,
    };

    const get = try pushTestFuncOpts(&m, a, "get", "app.Box.get", "app", 0, .{
        .extension = true,
    });
    m.funcs.items[get.int()].kind = .instance_method;
    m.funcs.items[get.int()].params[0].ty = box_pattern;
    m.funcs.items[get.int()].return_ty = class_arg[0];
    try m.decl_sigs.put(get.int(), .{
        .enclosing_class = box,
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .sig = &.{},
        .kind = .instance_method,
        .has_body = true,
    });

    var class_result = (try m.instantiatedCallReturnType(
        a,
        get,
        box_int,
        box_int,
        &.{},
        &.{},
    )).?;
    defer class_result.deinit(a);
    try testing.expectEqualStrings("Int", class_result.name);

    const shadow = try pushTestFuncOpts(
        &m,
        a,
        "shadow",
        "app.Box.shadow",
        "app",
        1,
        .{ .extension = true },
    );
    m.funcs.items[shadow.int()].kind = .instance_method;
    m.funcs.items[shadow.int()].params[0].ty = box_pattern;
    const function_param_ty = TypeRef{
        .name = "String",
        .nullable = false,
        .args = &.{},
    };
    m.funcs.items[shadow.int()].params[1].ty = function_param_ty;
    m.funcs.items[shadow.int()].return_ty = function_param_ty;
    var function_params: std.ArrayList([]const u8) = .empty;
    try function_params.append(a, "String");
    try m.registry.func_type_params.put(shadow, function_params);
    const shadow_sig = try a.dupe(TypeRef, &.{function_param_ty});
    try m.decl_sigs.put(shadow.int(), .{
        .enclosing_class = box,
        .arity = .{ .required = 1, .total = 1, .has_vararg = false },
        .sig = shadow_sig,
        .kind = .instance_method,
        .has_body = true,
    });
    const bool_args = [_]applicability.ArgShape{.{
        .ty = .{ .name = "Boolean", .nullable = false, .args = &.{} },
    }};
    var function_result = (try m.instantiatedCallReturnType(
        a,
        shadow,
        box_int,
        box_int,
        &bool_args,
        &.{},
    )).?;
    defer function_result.deinit(a);
    try testing.expectEqualStrings("Boolean", function_result.name);

    const qualified_args = try a.dupe(TypeRef, &.{
        .{ .name = "#qual:kotlin.String", .nullable = false, .args = &.{} },
    });
    const qualified_string = TypeRef{
        .name = "String",
        .nullable = false,
        .args = qualified_args,
    };
    const literal = try pushTestFuncOpts(
        &m,
        a,
        "literal",
        "app.Box.literal",
        "app",
        0,
        .{ .extension = true },
    );
    m.funcs.items[literal.int()].kind = .instance_method;
    m.funcs.items[literal.int()].params[0].ty = box_pattern;
    m.funcs.items[literal.int()].return_ty = qualified_string;
    try m.decl_sigs.put(literal.int(), .{
        .enclosing_class = box,
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .sig = &.{},
        .kind = .instance_method,
        .has_body = true,
    });
    var literal_result = (try m.instantiatedCallReturnType(
        a,
        literal,
        box_int,
        box_int,
        &.{},
        &.{},
    )).?;
    defer literal_result.deinit(a);
    try testing.expectEqualStrings("String", literal_result.name);
    try testing.expectEqualStrings(
        "#qual:kotlin.String",
        literal_result.args[literal_result.args.len - 1].name,
    );
}

test "extension return instantiation projects a subtype receiver" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    const parent = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Parent",
        .fqn = "app.Parent",
        .package = "app",
        .type_params = &.{"T"},
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    const t_args = try a.dupe(TypeRef, &.{
        .{ .name = "T", .nullable = false, .args = &.{} },
    });
    const supers = try a.dupe(ClassId, &.{parent});
    const super_refs = try a.dupe(TypeRef, &.{
        .{ .name = "app.Parent", .nullable = false, .args = t_args },
    });
    _ = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Child",
        .fqn = "app.Child",
        .package = "app",
        .type_params = &.{"T"},
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = supers,
        .supertype_refs = super_refs,
    });

    const wrap = try pushTestFuncOpts(&m, a, "wrap", "app.wrap", "app", 0, .{
        .extension = true,
    });
    m.funcs.items[wrap.int()].kind = .top_level_extension;
    m.funcs.items[wrap.int()].params[0].ty = .{
        .name = "app.Parent",
        .nullable = false,
        .args = t_args,
    };
    m.funcs.items[wrap.int()].return_ty = .{
        .name = "app.Child",
        .nullable = false,
        .args = t_args,
    };
    var type_params: std.ArrayList([]const u8) = .empty;
    try type_params.append(a, "T");
    try m.registry.func_type_params.put(wrap, type_params);

    const int_args = try a.dupe(TypeRef, &.{
        .{ .name = "Int", .nullable = false, .args = &.{} },
    });
    var result = (try m.instantiatedCallReturnType(
        a,
        wrap,
        .{ .name = "app.Child", .nullable = false, .args = int_args },
        null,
        &.{},
        &.{},
    )).?;
    defer result.deinit(a);
    try testing.expectEqualStrings("app.Child", result.name);
    try testing.expectEqual(@as(usize, 1), result.args.len);
    try testing.expectEqualStrings("Int", result.args[0].name);

    const shadow_parent = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "ShadowParent",
        .fqn = "app.ShadowParent",
        .package = "app",
        .type_params = &.{"T"},
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    const qualified_string_args = try a.dupe(TypeRef, &.{
        .{ .name = "#qual:kotlin.String", .nullable = false, .args = &.{} },
    });
    const shadow_supers = try a.dupe(ClassId, &.{shadow_parent});
    const shadow_super_refs = try a.dupe(TypeRef, &.{
        .{
            .name = "app.ShadowParent",
            .nullable = false,
            .args = try a.dupe(TypeRef, &.{
                .{ .name = "String", .nullable = false, .args = qualified_string_args },
            }),
        },
    });
    const shadow_child = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "ShadowChild",
        .fqn = "app.ShadowChild",
        .package = "app",
        .type_params = &.{"String"},
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = shadow_supers,
        .supertype_refs = shadow_super_refs,
    });
    const shadow_actual_args = try a.dupe(TypeRef, &.{
        .{ .name = "Int", .nullable = false, .args = &.{} },
    });
    const projected = (try m.projectTypeToClass(
        a,
        .{
            .name = m.classes.items[shadow_child.int()].fqn,
            .nullable = false,
            .args = shadow_actual_args,
        },
        shadow_parent,
    )).?;
    try testing.expectEqualStrings("app.ShadowParent", projected.name);
    try testing.expectEqual(@as(usize, 1), projected.args.len);
    try testing.expectEqualStrings("String", projected.args[0].name);
    try testing.expectEqualStrings(
        "#qual:kotlin.String",
        projected.args[0].args[projected.args[0].args.len - 1].name,
    );
}

test "member extension return instantiation uses the dispatch receiver" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    const scope = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Scope",
        .fqn = "app.Scope",
        .package = "app",
        .type_params = &.{"T"},
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    const value = try pushTestFuncOpts(&m, a, "value", "app.Scope.value", "app", 0, .{
        .extension = true,
    });
    const class_identity = try classTypeParamIdentity(a, scope, "T");
    m.funcs.items[value.int()].kind = .member_extension;
    m.funcs.items[value.int()].params[0].ty = .{
        .name = "String",
        .nullable = false,
        .args = &.{},
    };
    m.funcs.items[value.int()].return_ty = .{
        .name = class_identity,
        .nullable = false,
        .args = &.{},
    };
    try m.decl_sigs.put(value.int(), .{
        .enclosing_class = scope,
        .receiver_ty = m.funcs.items[value.int()].params[0].ty,
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .sig = &.{},
        .kind = .member_extension,
        .has_body = true,
    });
    const scope_args = try a.dupe(TypeRef, &.{
        .{ .name = "Int", .nullable = false, .args = &.{} },
    });
    try testing.expect((try m.instantiatedCallReturnType(
        a,
        value,
        .{ .name = "String", .nullable = false, .args = &.{} },
        null,
        &.{},
        &.{},
    )) == null);
    var result = (try m.instantiatedCallReturnType(
        a,
        value,
        .{ .name = "String", .nullable = false, .args = &.{} },
        .{ .name = "app.Scope", .nullable = false, .args = scope_args },
        &.{},
        &.{},
    )).?;
    defer result.deinit(a);
    try testing.expectEqualStrings("Int", result.name);
}

test "extension resolver substitutes bounded caller type parameters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    const generic = try pushTestFuncOpts(&m, a, "minOrNull", "kotlin.collections.minOrNull", "kotlin.collections", 0, .{
        .extension = true,
    });
    m.funcs.items[generic.int()].kind = .top_level_extension;
    const generic_receiver_args = try a.alloc(TypeRef, 1);
    generic_receiver_args[0] = .{ .name = "out#E", .nullable = false, .args = &.{} };
    m.funcs.items[generic.int()].params[0].ty = .{
        .name = "Array",
        .nullable = false,
        .args = generic_receiver_args,
    };
    var generic_params: std.ArrayList([]const u8) = .empty;
    try generic_params.append(a, "E");
    try m.registry.func_type_params.put(generic, generic_params);
    try m.registry.func_type_param_bounds.put(generic, &.{
        .{ .param = "E", .bound = "Comparable" },
    });

    const doubles = try pushTestFuncOpts(&m, a, "minOrNull", "kotlin.collections.minOrNull", "kotlin.collections", 0, .{
        .extension = true,
    });
    m.funcs.items[doubles.int()].kind = .top_level_extension;
    const double_receiver_args = try a.alloc(TypeRef, 1);
    double_receiver_args[0] = .{ .name = "Double", .nullable = false, .args = &.{} };
    m.funcs.items[doubles.int()].params[0].ty = .{
        .name = "Array",
        .nullable = false,
        .args = double_receiver_args,
    };
    try m.rebuildFuncNameIndex(a);

    const actual_args = try a.alloc(TypeRef, 1);
    actual_args[0] = .{ .name = "T", .nullable = false, .args = &.{} };
    const actual_receiver = TypeRef{
        .name = "Array",
        .nullable = false,
        .args = actual_args,
    };
    const actual_bounds = [_]ModuleRegistry.TypeParamBound{
        .{ .param = "T", .bound = "Comparable" },
    };
    const declared_bounds = try m.declaredTypeParamBounds(a, generic);
    try testing.expect(m.staticBoundProofComplete(
        declared_bounds[0],
        declared_bounds,
        0,
    ));
    try testing.expect(try m.staticTypeIsSubtypeWithBounds(
        a,
        .{ .name = "T", .nullable = false, .args = &.{} },
        .{ .name = "Comparable", .nullable = false, .args = &.{} },
        &actual_bounds,
    ));
    try testing.expect(try m.staticGenericReceiverApplicable(
        a,
        actual_receiver,
        m.funcs.items[generic.int()].params[0].ty,
        declared_bounds,
        &actual_bounds,
    ));
    const resolved = m.resolveExtensionCall("minOrNull", actual_receiver, &.{}, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
        .actual_type_param_bounds = &actual_bounds,
    });
    try testing.expectEqual(generic, resolved.target.?);

    const comparable_args = try a.alloc(TypeRef, 1);
    const comparable_type_args = try a.alloc(TypeRef, 1);
    comparable_type_args[0] = .{ .name = "Any", .nullable = false, .args = &.{} };
    comparable_args[0] = .{
        .name = "Comparable",
        .nullable = false,
        .args = comparable_type_args,
    };
    const concrete = m.resolveExtensionCall("minOrNull", .{
        .name = "Array",
        .nullable = false,
        .args = comparable_args,
    }, &.{}, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
    });
    try testing.expectEqual(generic, concrete.target.?);
}

test "a tie on the lambda return alone still lends the lambda param types" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    // Two `Iterable<T>.flatMapX(transform)` overloads whose lambdas differ
    // only in RETURN type (`Iterable<R>` vs `Sequence<R>`) — the
    // `flatMapIndexed` shape. The tie is genuine, but both candidates hand
    // the closure the same parameter types, so param_rep names one of them.
    const fids = [_]FuncId{
        try pushTestFuncOpts(&m, a, "flatMapX", "kotlin.collections.flatMapX", "kotlin.collections", 1, .{ .extension = true }),
        try pushTestFuncOpts(&m, a, "flatMapX", "kotlin.collections.flatMapX", "kotlin.collections", 1, .{ .extension = true }),
    };
    const lambda_return_heads = [_][]const u8{ "Iterable", "Sequence" };
    for (fids, lambda_return_heads) |fid, ret_head| {
        m.funcs.items[fid.int()].kind = .top_level_extension;
        const recv_args = try a.alloc(TypeRef, 1);
        recv_args[0] = .{ .name = "T", .nullable = false, .args = &.{} };
        m.funcs.items[fid.int()].params[0].ty = .{ .name = "Iterable", .nullable = false, .args = recv_args };
        const ret_args = try a.alloc(TypeRef, 1);
        ret_args[0] = .{ .name = "R", .nullable = false, .args = &.{} };
        const lam_args = try a.alloc(TypeRef, 3);
        lam_args[0] = .{ .name = "Int", .nullable = false, .args = &.{} };
        lam_args[1] = .{ .name = "T", .nullable = false, .args = &.{} };
        lam_args[2] = .{ .name = ret_head, .nullable = false, .args = ret_args };
        m.funcs.items[fid.int()].params[1].ty = .{ .name = "Function2", .nullable = false, .args = lam_args };
        var tps: std.ArrayList([]const u8) = .empty;
        try tps.append(a, "T");
        try tps.append(a, "R");
        try m.registry.func_type_params.put(fid, tps);
    }
    try m.rebuildFuncNameIndex(a);

    const recv_string = try a.alloc(TypeRef, 1);
    recv_string[0] = .{ .name = "String", .nullable = false, .args = &.{} };
    var shapes = [_]applicability.ArgShape{
        .{ .is_lambda = true, .lambda_arity = 2 },
    };
    const res = m.resolveExtensionCall(
        "flatMapX",
        .{ .name = "Iterable", .nullable = false, .args = recv_string },
        &shapes,
        .{ .caller_file = FileId.from(0), .caller_package = "app" },
    );
    try testing.expect(res.target == null);
    try testing.expect(res.applicable);
    try testing.expectEqual(fids[0], res.param_rep.?);

    // Overloads that also differ in a lambda PARAMETER position lend
    // nothing: whichever wins changes what the closure body sees.
    const third = try pushTestFuncOpts(&m, a, "flatMapY", "kotlin.collections.flatMapY", "kotlin.collections", 1, .{ .extension = true });
    const fourth = try pushTestFuncOpts(&m, a, "flatMapY", "kotlin.collections.flatMapY", "kotlin.collections", 1, .{ .extension = true });
    const param_heads = [_][]const u8{ "Int", "Long" };
    for ([_]FuncId{ third, fourth }, param_heads) |fid, param_head| {
        m.funcs.items[fid.int()].kind = .top_level_extension;
        const recv_args = try a.alloc(TypeRef, 1);
        recv_args[0] = .{ .name = "T", .nullable = false, .args = &.{} };
        m.funcs.items[fid.int()].params[0].ty = .{ .name = "Iterable", .nullable = false, .args = recv_args };
        const lam_args = try a.alloc(TypeRef, 3);
        lam_args[0] = .{ .name = param_head, .nullable = false, .args = &.{} };
        lam_args[1] = .{ .name = "T", .nullable = false, .args = &.{} };
        lam_args[2] = .{ .name = "Any", .nullable = false, .args = &.{} };
        m.funcs.items[fid.int()].params[1].ty = .{ .name = "Function2", .nullable = false, .args = lam_args };
        var tps: std.ArrayList([]const u8) = .empty;
        try tps.append(a, "T");
        try m.registry.func_type_params.put(fid, tps);
    }
    try m.rebuildFuncNameIndex(a);
    const res2 = m.resolveExtensionCall(
        "flatMapY",
        .{ .name = "Iterable", .nullable = false, .args = recv_string },
        &shapes,
        .{ .caller_file = FileId.from(0), .caller_package = "app" },
    );
    try testing.expect(res2.target == null);
    try testing.expect(res2.param_rep == null);
}

test "named arguments may skip defaulted parameters and still resolve" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    // The rangesDelimitedBy shape: `f(x, ignoreCase = ..., limit = ...)`
    // skips the defaulted `startIndex`, and the CharArray/Array overload
    // pair is discriminated by the first positional argument.
    const heads = [_][]const u8{ "CharArray", "IntArray" };
    var fids: [2]FuncId = undefined;
    for (heads, 0..) |head, idx| {
        const fid = try pushTestFuncOpts(&m, a, "myRanges", "app.myRanges", "app", 4, .{ .extension = true });
        m.funcs.items[fid.int()].kind = .top_level_extension;
        m.funcs.items[fid.int()].params[0].ty = .{ .name = "CharSequence", .nullable = false, .args = &.{} };
        m.funcs.items[fid.int()].params[1] = .{ .name = "delims", .ty = .{ .name = head, .nullable = false, .args = &.{} }, .default = null };
        m.funcs.items[fid.int()].params[2] = .{ .name = "startIndex", .ty = .{ .name = "Int", .nullable = false, .args = &.{} }, .default = null, .has_default = true };
        m.funcs.items[fid.int()].params[3] = .{ .name = "ignoreCase", .ty = .{ .name = "Boolean", .nullable = false, .args = &.{} }, .default = null, .has_default = true };
        m.funcs.items[fid.int()].params[4] = .{ .name = "limit", .ty = .{ .name = "Int", .nullable = false, .args = &.{} }, .default = null, .has_default = true };
        fids[idx] = fid;
    }
    try m.rebuildFuncNameIndex(a);

    var shapes = [_]applicability.ArgShape{
        .{ .ty = .{ .name = "CharArray", .nullable = false, .args = &.{} } },
        .{ .ty = .{ .name = "Boolean", .nullable = false, .args = &.{} }, .named = "ignoreCase" },
        .{ .ty = .{ .name = "Int", .nullable = false, .args = &.{} }, .named = "limit" },
    };
    const res = m.resolveExtensionCall(
        "myRanges",
        .{ .name = "CharSequence", .nullable = false, .args = &.{} },
        &shapes,
        .{ .caller_file = FileId.from(0), .caller_package = "app" },
    );
    // The skip COMMITS: the emitted call carries the names and the host
    // boundary binds them by declaration parameter.
    try testing.expectEqual(fids[0], res.target.?);

    // A named argument no parameter carries still drops the candidate.
    var wrong = [_]applicability.ArgShape{
        .{ .ty = .{ .name = "CharArray", .nullable = false, .args = &.{} } },
        .{ .ty = .{ .name = "Boolean", .nullable = false, .args = &.{} }, .named = "nope" },
    };
    const res2 = m.resolveExtensionCall(
        "myRanges",
        .{ .name = "CharSequence", .nullable = false, .args = &.{} },
        &wrong,
        .{ .caller_file = FileId.from(0), .caller_package = "app" },
    );
    try testing.expect(res2.target == null);

    // A skipped parameter WITHOUT a default keeps the strict rule: naming
    // `limit` past a required `mustGive` defers rather than committing.
    const strict = try pushTestFuncOpts(&m, a, "strictRanges", "app.strictRanges", "app", 3, .{ .extension = true });
    m.funcs.items[strict.int()].kind = .top_level_extension;
    m.funcs.items[strict.int()].params[0].ty = .{ .name = "CharSequence", .nullable = false, .args = &.{} };
    m.funcs.items[strict.int()].params[1] = .{ .name = "delims", .ty = .{ .name = "CharArray", .nullable = false, .args = &.{} }, .default = null };
    m.funcs.items[strict.int()].params[2] = .{ .name = "mustGive", .ty = .{ .name = "Int", .nullable = false, .args = &.{} }, .default = null };
    m.funcs.items[strict.int()].params[3] = .{ .name = "limit", .ty = .{ .name = "Int", .nullable = false, .args = &.{} }, .default = null, .has_default = true };
    try m.rebuildFuncNameIndex(a);
    var skip_required = [_]applicability.ArgShape{
        .{ .ty = .{ .name = "CharArray", .nullable = false, .args = &.{} } },
        .{ .ty = .{ .name = "Int", .nullable = false, .args = &.{} }, .named = "limit" },
    };
    const res3 = m.resolveExtensionCall(
        "strictRanges",
        .{ .name = "CharSequence", .nullable = false, .args = &.{} },
        &skip_required,
        .{ .caller_file = FileId.from(0), .caller_package = "app" },
    );
    try testing.expect(res3.target == null);
}

test "dependent bound with unbound referenced parameter does not refute" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    // `fun <S, T : S> Iterable<T>.reduce(op: (S, T) -> S)` against an
    // `Iterable<String>` receiver: binding produces only `T := String`, and
    // `S` (value-parameter and return positions only) stays free for the
    // call's inference, so `T <: S` cannot refute the candidate.
    const type_vars = [_]TypeRef{.{ .name = "T", .nullable = false, .args = &.{} }};
    const strings = [_]TypeRef{.{ .name = "String", .nullable = false, .args = &.{} }};
    const pattern = TypeRef{ .name = "Iterable", .nullable = false, .args = @constCast(&type_vars) };
    const actual = TypeRef{ .name = "Iterable", .nullable = false, .args = @constCast(&strings) };
    const declared = [_]ModuleRegistry.TypeParamBound{
        .{ .param = "S", .bound = "kotlin.Any" },
        .{ .param = "T", .bound = "S" },
    };
    try testing.expect(try m.staticGenericReceiverApplicable(
        a,
        actual,
        pattern,
        &declared,
        &.{},
    ));
    // A dependent bound whose referenced parameter IS bound still proves:
    // `Map<K, V>.getRid(k: K)` shapes bind both sides from the receiver.
    const bound_both = [_]ModuleRegistry.TypeParamBound{
        .{ .param = "T", .bound = "V" },
        .{ .param = "V", .bound = "kotlin.Any" },
    };
    const pair_vars = [_]TypeRef{
        .{ .name = "T", .nullable = false, .args = &.{} },
        .{ .name = "V", .nullable = false, .args = &.{} },
    };
    const int_string = [_]TypeRef{
        .{ .name = "Int", .nullable = false, .args = &.{} },
        .{ .name = "String", .nullable = false, .args = &.{} },
    };
    const pair_pattern = TypeRef{ .name = "Pair", .nullable = false, .args = @constCast(&pair_vars) };
    const pair_actual = TypeRef{ .name = "Pair", .nullable = false, .args = @constCast(&int_string) };
    try testing.expect(!(try m.staticGenericReceiverApplicable(
        a,
        pair_actual,
        pair_pattern,
        &bound_both,
        &.{},
    )));
}

test "static subtype proof respects variance, bottom, stars, and aliases" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    _ = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "List",
        .fqn = "kotlin.collections.List",
        .package = "kotlin.collections",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
        .type_params = &.{"T"},
        .type_param_variance = &.{.Out},
        .is_interface = true,
        .is_abstract = true,
    });
    _ = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "MutableList",
        .fqn = "kotlin.collections.MutableList",
        .package = "kotlin.collections",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
        .type_params = &.{"T"},
        .type_param_variance = &.{.Invariant},
        .is_interface = true,
        .is_abstract = true,
    });

    const strings = [_]TypeRef{.{ .name = "String", .nullable = false, .args = &.{} }};
    const ints = [_]TypeRef{.{ .name = "Int", .nullable = false, .args = &.{} }};
    const bottoms = [_]TypeRef{.{ .name = "Nothing", .nullable = false, .args = &.{} }};
    const stars = [_]TypeRef{.{ .name = "*", .nullable = false, .args = &.{} }};
    const list_strings = TypeRef{ .name = "List", .nullable = false, .args = @constCast(&strings) };
    try testing.expect(try m.staticTypeIsSubtype(
        a,
        .{ .name = "List", .nullable = false, .args = @constCast(&bottoms) },
        list_strings,
    ));
    try testing.expect(!(try m.staticTypeIsSubtype(
        a,
        .{ .name = "List", .nullable = false, .args = @constCast(&ints) },
        list_strings,
    )));
    try testing.expect(!(try m.staticTypeIsSubtype(
        a,
        .{ .name = "List", .nullable = false, .args = @constCast(&stars) },
        list_strings,
    )));
    const projected_strings = [_]TypeRef{
        .{ .name = "out#String", .nullable = false, .args = &.{} },
    };
    try testing.expect(try m.staticTypeIsSubtype(
        a,
        .{
            .name = "List",
            .nullable = false,
            .args = @constCast(&projected_strings),
        },
        list_strings,
    ));

    const type_vars = [_]TypeRef{.{
        .name = "T",
        .nullable = false,
        .args = &.{},
    }};
    const char_sequences = [_]TypeRef{.{
        .name = "CharSequence",
        .nullable = false,
        .args = &.{},
    }};
    try testing.expect(try m.staticTypeIsSubtypeWithBounds(
        a,
        .{ .name = "List", .nullable = false, .args = @constCast(&type_vars) },
        .{
            .name = "List",
            .nullable = false,
            .args = @constCast(&char_sequences),
        },
        &.{.{ .param = "T", .bound = "CharSequence" }},
    ));
    try testing.expect(!(try m.staticGenericReceiverApplicable(
        a,
        .{ .name = "List", .nullable = false, .args = @constCast(&ints) },
        .{ .name = "List", .nullable = false, .args = @constCast(&type_vars) },
        &.{.{ .param = "T", .bound = "CharSequence" }},
        &.{},
    )));
    try testing.expect(try m.staticGenericReceiverApplicable(
        a,
        list_strings,
        .{ .name = "List", .nullable = false, .args = @constCast(&type_vars) },
        &.{.{ .param = "T", .bound = "CharSequence" }},
        &.{},
    ));

    try m.registry.type_alias_types.put("Ints", .{
        .type_params = &.{},
        .target = .{
            .name = "MutableList",
            .nullable = false,
            .args = @constCast(&ints),
        },
    });
    try testing.expect(!(try m.staticTypeIsSubtype(
        a,
        .{ .name = "Ints", .nullable = false, .args = &.{} },
        .{
            .name = "MutableList",
            .nullable = false,
            .args = @constCast(&strings),
        },
    )));

    try m.registry.type_alias_types.put("alpha.Items", .{
        .type_params = &.{"T"},
        .target = .{
            .name = "MutableList",
            .nullable = false,
            .args = @constCast(&type_vars),
        },
    });
    try m.registry.type_alias_types.put("beta.Items", .{
        .type_params = &.{"T"},
        .target = .{
            .name = "MutableList",
            .nullable = false,
            .args = @constCast(&strings),
        },
    });
    const qualified_ints = [_]TypeRef{
        .{ .name = "Int", .nullable = false, .args = &.{} },
        .{ .name = "#qual:alpha.Items", .nullable = false, .args = &.{} },
    };
    try testing.expect(!(try m.staticTypeIsSubtype(
        a,
        .{
            .name = "Items",
            .nullable = false,
            .args = @constCast(&qualified_ints),
        },
        .{
            .name = "MutableList",
            .nullable = false,
            .args = @constCast(&strings),
        },
    )));
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

test "renamed imports enter the canonical candidate set by exact identity" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    const own = try pushTestFunc(&m, a, "hello", "app.hello", "app", 0);
    const imported = try pushTestFunc(&m, a, "greet", "lib.greet", "lib", 0);
    const imported_int = try pushTestFuncOpts(
        &m,
        a,
        "greet",
        "lib.greet",
        "lib",
        1,
        .{ .param_ty = "Int" },
    );
    _ = try pushTestFunc(&m, a, "greet", "other.greet", "other", 0);
    var paths: std.ArrayList(ModuleRegistry.ImportPath) = .empty;
    const segs = try a.alloc([]const u8, 2);
    segs[0] = "lib";
    segs[1] = "greet";
    try paths.append(a, .{ .fqn = try a.dupe(u8, "lib.greet"), .segs = segs });
    var imports = std.StringHashMap(std.ArrayList(ModuleRegistry.ImportPath)).init(a);
    try imports.put("hello", paths);
    try m.registry.import_aliases.put(FileId.from(0), imports);
    try m.rebuildFuncNameIndex(a);

    const candidates = try m.bareCallCandidates(a, "hello", FileId.from(0));
    defer a.free(candidates);
    try testing.expectEqual(@as(usize, 3), candidates.len);
    try testing.expectEqual(own, candidates[0]);
    try testing.expectEqual(imported, candidates[1]);
    try testing.expectEqual(imported_int, candidates[2]);

    const call = m.resolveBareCallIndexed("hello", "app", FileId.from(0), 0, false);
    try testing.expectEqual(imported, call.pick().?);
    try testing.expectEqual(@as(u8, 0), call.tier);
    try testing.expect(m.resolveBareRefIndexed(
        "hello",
        "app",
        FileId.from(0),
    ) == null);
    const zero_ref = try m.resolveBareRefExpected(
        a,
        "hello",
        "app",
        FileId.from(0),
        &.{},
    );
    try testing.expectEqual(imported, zero_ref.?);
    const int_ref_args = [_]applicability.ArgShape{.{
        .ty = .{ .name = "Int", .nullable = false, .args = &.{} },
        .ty_authoritative = true,
    }};
    const int_ref = try m.resolveBareRefExpected(
        a,
        "hello",
        "app",
        FileId.from(0),
        &int_ref_args,
    );
    try testing.expectEqual(imported_int, int_ref.?);

    const other_file = m.resolveBareCallIndexed("hello", "app", FileId.from(1), 0, false);
    try testing.expectEqual(own, other_file.pick().?);
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

test "bounded spread candidates retain renamed import identity" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    const imported = try pushTestFuncOpts(
        &m,
        a,
        "merge",
        "lib.merge",
        "lib",
        1,
        .{ .last_vararg = true },
    );
    _ = try pushTestFuncOpts(
        &m,
        a,
        "merge",
        "other.merge",
        "other",
        1,
        .{ .last_vararg = true },
    );
    var paths: std.ArrayList(ModuleRegistry.ImportPath) = .empty;
    const segs = try a.alloc([]const u8, 2);
    segs[0] = "lib";
    segs[1] = "merge";
    try paths.append(a, .{ .fqn = try a.dupe(u8, "lib.merge"), .segs = segs });
    var imports = std.StringHashMap(std.ArrayList(ModuleRegistry.ImportPath)).init(a);
    try imports.put("originalMerge", paths);
    try m.registry.import_aliases.put(FileId.from(0), imports);
    try m.rebuildFuncNameIndex(a);

    const scoped = (try m.boundedSpreadCandidates(
        a,
        "originalMerge",
        "app",
        FileId.from(0),
    )).?;
    defer a.free(scoped);
    try testing.expectEqualSlices(FuncId, &.{imported}, scoped);
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

test "resolveCall selects scope after applicability" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    const own = try pushTestFuncOpts(&m, a, "pick", "app.pick", "app", 1, .{
        .param_ty = "Function1",
    });
    _ = try pushTestFuncOpts(&m, a, "pick", "imports.pick", "imports", 1, .{
        .param_ty = "Int",
    });
    var paths: std.ArrayList(ModuleRegistry.ImportPath) = .empty;
    const segs = try a.alloc([]const u8, 2);
    segs[0] = "imports";
    segs[1] = "pick";
    try paths.append(a, .{
        .fqn = try a.dupe(u8, "imports.pick"),
        .segs = segs,
    });
    var inner = std.StringHashMap(std.ArrayList(ModuleRegistry.ImportPath)).init(a);
    try inner.put("pick", paths);
    try m.registry.import_aliases.put(FileId.from(0), inner);
    try m.rebuildFuncNameIndex(a);

    const args = [_]applicability.ArgShape{.{
        .is_lambda = true,
        .lambda_arity = 1,
        .lambda_is_literal = true,
    }};
    const indexed = m.resolveBareCallIndexed("pick", "app", FileId.from(0), 1, false);
    try testing.expectEqual(@as(u8, 0), indexed.tier);

    const resolved = try m.resolveCall(a, "pick", "app", FileId.from(0), &args, false, .{});
    defer a.free(resolved.candidate_set);
    try testing.expectEqual(own, resolved.target.?);
    try testing.expectEqual(@as(u8, 1), resolved.tier);
    try testing.expect(resolved.target_final);
}

test "resolveCall commits a uniquely applicable source vararg" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    const vararg = try pushTestFuncOpts(&m, a, "inspect", "app.inspect", "app", 1, .{
        .last_vararg = true,
        .param_ty = "Function1",
    });
    try m.rebuildFuncNameIndex(a);

    const args = [_]applicability.ArgShape{
        .{ .is_lambda = true, .lambda_arity = 1, .lambda_is_literal = true },
        .{ .is_lambda = true, .lambda_arity = 1, .lambda_is_literal = true },
    };
    const resolved = try m.resolveCall(a, "inspect", "app", FileId.from(0), &args, false, .{});
    defer a.free(resolved.candidate_set);
    try testing.expectEqual(vararg, resolved.target.?);
    try testing.expectEqual(Module.EmitForm.Call, resolved.emit_form);
    try testing.expect(resolved.target_final);
}

test "resolveCall keeps tied unknown overloads non-final" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    _ = try pushTestFuncOpts(&m, a, "choose", "app.choose", "app", 1, .{
        .param_ty = "Int",
    });
    _ = try pushTestFuncOpts(&m, a, "choose", "app.choose", "app", 1, .{
        .param_ty = "String",
    });
    try m.rebuildFuncNameIndex(a);

    const resolved = try m.resolveCall(
        a,
        "choose",
        "app",
        FileId.from(0),
        &.{.{}},
        false,
        .{},
    );
    defer a.free(resolved.candidate_set);
    try testing.expect(resolved.target != null);
    try testing.expectEqual(Module.EmitForm.Call, resolved.emit_form);
    try testing.expect(!resolved.target_final);
}

test "resolveCall removes a statically incompatible overload before finalizing" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    const generic = try pushTestFuncOpts(&m, a, "choose", "app.choose", "app", 1, .{
        .param_ty = "T",
    });
    _ = try pushTestFuncOpts(&m, a, "choose", "app.choose", "app", 1, .{
        .param_ty = "String",
    });
    var type_params: std.ArrayList([]const u8) = .empty;
    try type_params.append(a, "T");
    try m.registry.func_type_params.put(generic, type_params);
    try m.rebuildFuncNameIndex(a);

    const args = [_]applicability.ArgShape{.{
        .ty = .{ .name = "Any", .nullable = false, .args = &.{} },
    }};
    const resolved = try m.resolveCall(
        a,
        "choose",
        "app",
        FileId.from(0),
        &args,
        false,
        .{},
    );
    defer a.free(resolved.candidate_set);
    try testing.expectEqual(generic, resolved.target.?);
    try testing.expect(resolved.target_final);
}

test "resolveCall prefers a fixed overload for a named argument" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    _ = try pushTestFuncOpts(&m, a, "choose", "app.choose", "app", 1, .{
        .last_vararg = true,
    });
    const fixed = try pushTestFunc(&m, a, "choose", "app.choose", "app", 1);
    m.funcs.items[fixed.int()].params[0].name = "x";
    m.funcs.items[fixed.int() - 1].params[0].name = "x";
    try m.rebuildFuncNameIndex(a);

    const args = [_]applicability.ArgShape{.{
        .ty = .{ .name = "Int", .nullable = false, .args = &.{} },
        .named = "x",
    }};
    const resolved = try m.resolveCall(
        a,
        "choose",
        "app",
        FileId.from(0),
        &args,
        false,
        .{},
    );
    defer a.free(resolved.candidate_set);
    try testing.expectEqual(fixed, resolved.target.?);
    try testing.expect(resolved.target_final);
}

test "resolveCall preserves a trailing lambda before the Compose pair" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    const short = try pushTestFunc(&m, a, "Box", "app.Box", "app", 3);
    const content = try pushTestFunc(&m, a, "Box", "app.Box", "app", 6);

    const short_params = m.funcs.items[short.int()].params;
    short_params[0].name = "modifier";
    short_params[0].ty.name = "Modifier";
    short_params[1].name = "$composer";
    short_params[1].ty.name = "Composer";
    short_params[2].name = "$changed";

    const content_params = m.funcs.items[content.int()].params;
    content_params[0].name = "modifier";
    content_params[0].ty.name = "Modifier";
    content_params[0].has_default = true;
    content_params[1].name = "alignment";
    content_params[1].ty.name = "Alignment";
    content_params[1].has_default = true;
    content_params[2].name = "propagate";
    content_params[2].ty.name = "Boolean";
    content_params[2].has_default = true;
    content_params[3].name = "content";
    content_params[3].ty.name = "Function0";
    content_params[4].name = "$composer";
    content_params[4].ty.name = "Composer";
    content_params[5].name = "$changed";
    try m.rebuildFuncNameIndex(a);

    const args = [_]applicability.ArgShape{
        .{ .ty = .{ .name = "Function0", .nullable = false, .args = &.{} }, .is_lambda = true },
        .{ .ty = .{ .name = "Composer", .nullable = false, .args = &.{} }, .named = "$composer" },
        .{ .ty = .{ .name = "Int", .nullable = false, .args = &.{} }, .named = "$changed" },
    };
    const resolved = try m.resolveCall(
        a,
        "Box",
        "app",
        FileId.from(0),
        &args,
        false,
        .{},
    );
    defer a.free(resolved.candidate_set);
    try testing.expectEqual(content, resolved.target.?);
}

test "resolveCall commits a callable vararg before the Compose pair" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    const inspect = try pushTestFunc(&m, a, "inspect", "app.inspect", "app", 4);
    const params = m.funcs.items[inspect.int()].params;
    params[0].name = "item";
    params[1].name = "selectors";
    params[1].ty.name = "Function1";
    params[1].is_vararg = true;
    params[2].name = "$composer";
    params[2].ty.name = "Composer";
    params[3].name = "$changed";
    try m.rebuildFuncNameIndex(a);

    const args = [_]applicability.ArgShape{
        .{ .ty = .{ .name = "Int", .nullable = false, .args = &.{} } },
        .{
            .ty = .{ .name = "Function1", .nullable = false, .args = &.{} },
            .is_lambda = true,
            .lambda_arity = 1,
            .lambda_is_literal = true,
        },
        .{
            .ty = .{ .name = "Function1", .nullable = false, .args = &.{} },
            .is_lambda = true,
            .lambda_arity = 1,
            .lambda_is_literal = true,
        },
        .{
            .ty = .{ .name = "Composer", .nullable = false, .args = &.{} },
            .named = "$composer",
        },
        .{
            .ty = .{ .name = "Int", .nullable = false, .args = &.{} },
            .named = "$changed",
        },
    };
    const resolved = try m.resolveCall(
        a,
        "inspect",
        "app",
        FileId.from(0),
        &args,
        false,
        .{},
    );
    defer a.free(resolved.candidate_set);
    try testing.expectEqual(inspect, resolved.target.?);
    try testing.expectEqual(Module.EmitForm.Call, resolved.emit_form);
    try testing.expect(resolved.target_final);
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

test "resolveCall: an extension requires an implicit receiver context" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    const extension = try pushTestFuncOpts(
        &m,
        a,
        "contentColorFor",
        "app.contentColorFor",
        "app",
        1,
        .{ .extension = true },
    );
    m.funcs.items[extension.int()].kind = .top_level_extension;
    const composable = try pushTestFunc(
        &m,
        a,
        "contentColorFor",
        "app.contentColorFor",
        "app",
        3,
    );
    m.funcs.items[composable.int()].params[1].name = "$composer";
    m.funcs.items[composable.int()].params[1].ty.name = "Composer";
    m.funcs.items[composable.int()].params[2].name = "$changed";
    try m.rebuildFuncNameIndex(a);

    const source_args = [_]applicability.ArgShape{.{}};
    const source = try m.resolveCall(
        a,
        "contentColorFor",
        "app",
        FileId.from(0),
        &source_args,
        false,
        .{},
    );
    defer a.free(source.candidate_set);
    try testing.expect(source.target == null);

    const source_in_composition = try m.resolveCall(
        a,
        "contentColorFor",
        "app",
        FileId.from(0),
        &source_args,
        false,
        .{ .has_composer = true },
    );
    defer a.free(source_in_composition.candidate_set);
    try testing.expectEqual(composable, source_in_composition.target.?);

    const threaded_args = [_]applicability.ArgShape{ .{}, .{}, .{} };
    const threaded = try m.resolveCall(
        a,
        "contentColorFor",
        "app",
        FileId.from(0),
        &threaded_args,
        false,
        .{},
    );
    defer a.free(threaded.candidate_set);
    try testing.expectEqual(composable, threaded.target.?);
    try testing.expectEqual(Module.EmitForm.Call, threaded.emit_form);
}

test "resolveCall ignores inapplicable callables on a known receiver tower" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    _ = try pushTestClass(&m, a, "String", "kotlin.String", "kotlin");
    _ = try pushTestClass(&m, a, "FractionalParser", "kotlin.time.FractionalParser", "kotlin.time");
    const global = try pushTestFuncOpts(&m, a, "repeat", "kotlin.repeat", "kotlin", 2, .{});
    m.funcs.items[global.int()].params[1].ty.name = "Function1";

    const string_repeat = try pushTestFuncOpts(
        &m,
        a,
        "repeat",
        "kotlin.text.repeat",
        "kotlin.text",
        1,
        .{ .extension = true },
    );
    m.funcs.items[string_repeat.int()].kind = .top_level_extension;
    const string_repeat_sig = [_]TypeRef{
        .{ .name = "Int", .nullable = false, .args = &.{} },
    };
    try m.decl_sigs.put(string_repeat.int(), .{
        .receiver_ty = .{ .name = "String", .nullable = false, .args = &.{} },
        .arity = .{ .required = 1, .total = 1, .has_vararg = false },
        .sig = &string_repeat_sig,
        .kind = .top_level_extension,
        .has_body = true,
    });
    try m.rebuildFuncNameIndex(a);

    const args = [_]applicability.ArgShape{
        .{ .ty = .{ .name = "Int", .nullable = false, .args = &.{} } },
        .{
            .ty = .{ .name = "Function1", .nullable = false, .args = &.{} },
            .is_lambda = true,
            .lambda_arity = 1,
        },
    };
    const res = try m.resolveCall(a, "repeat", "app", FileId.from(0), &args, true, .{
        .in_receiver_context = true,
        .unknown_receiver = true,
        .recv_ty = "String",
        .recv_type = .{ .name = "String", .nullable = false, .args = &.{} },
        .owner_class = "FractionalParser",
        .receiver_scope_complete = true,
    });
    defer a.free(res.candidate_set);
    try testing.expectEqual(global, res.target.?);
    try testing.expectEqual(Module.EmitForm.Call, res.emit_form);
    try testing.expectEqual(Module.Confidence.exact, res.confidence);
}

test "resolveCall retains a vararg extension on a known receiver" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    _ = try pushTestClass(&m, a, "String", "kotlin.String", "kotlin");
    const global = try pushTestFunc(&m, a, "pick", "app.pick", "app", 1);
    const extension = try pushTestFuncOpts(
        &m,
        a,
        "pick",
        "app.stringPick",
        "app",
        1,
        .{ .extension = true, .last_vararg = true },
    );
    m.funcs.items[extension.int()].kind = .top_level_extension;
    try m.decl_sigs.put(extension.int(), .{
        .receiver_ty = .{ .name = "String", .nullable = false, .args = &.{} },
        .arity = .{ .required = 0, .total = 1, .has_vararg = true },
        .sig = &.{},
        .kind = .top_level_extension,
        .has_body = true,
    });
    try m.rebuildFuncNameIndex(a);

    const args = [_]applicability.ArgShape{
        .{ .ty = .{ .name = "Int", .nullable = false, .args = &.{} } },
    };
    const res = try m.resolveCall(a, "pick", "app", FileId.from(0), &args, false, .{
        .in_receiver_context = true,
        .unknown_receiver = true,
        .recv_ty = "String",
        .recv_type = .{ .name = "String", .nullable = false, .args = &.{} },
        .receiver_scope_complete = true,
    });
    defer a.free(res.candidate_set);
    try testing.expectEqual(global, res.target.?);
    try testing.expectEqual(Module.EmitForm.CallMemberOrGlobal, res.emit_form);
    try testing.expectEqual(Module.Confidence.virtual, res.confidence);
}

test "known receiver applicability keeps same-name classes distinct" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    _ = try pushTestClass(&m, a, "Scope", "left.Scope", "left");
    const owner = try pushTestClass(&m, a, "Scope", "right.Scope", "right");
    const choose = try pushTestFunc(&m, a, "choose", "right.Scope.choose", "right", 1);
    m.funcs.items[choose.int()].kind = .instance_method;
    const choose_sig = [_]TypeRef{
        .{ .name = "Int", .nullable = false, .args = &.{} },
    };
    try m.decl_sigs.put(choose.int(), .{
        .enclosing_class = owner,
        .arity = .{ .required = 1, .total = 1, .has_vararg = false },
        .sig = &choose_sig,
        .kind = .instance_method,
        .has_body = true,
    });
    try m.registerMemberDecl(a, "right.Scope", "choose", choose);

    const args = [_]applicability.ArgShape{
        .{ .ty = .{ .name = "Int", .nullable = false, .args = &.{} } },
    };
    try testing.expectEqual(true, m.knownReceiverCallableApplicable(
        "choose",
        "app",
        FileId.from(0),
        &args,
        .{
            .recv_ty = "left.Scope",
            .recv_type = .{ .name = "left.Scope", .nullable = false, .args = &.{} },
            .owner_class = "right.Scope",
            .receiver_scope_complete = true,
        },
    ).?);

    const left_qualifier = [_]TypeRef{
        .{ .name = "#qual:left.Scope", .nullable = false, .args = &.{} },
    };
    try testing.expect(m.knownReceiverCallableApplicable(
        "choose",
        "app",
        FileId.from(0),
        &args,
        .{
            .recv_ty = "Scope",
            .recv_type = .{ .name = "Scope", .nullable = false, .args = @constCast(&left_qualifier) },
            .owner_class = "Scope",
            .receiver_scope_complete = true,
        },
    ) == null);
}

test "known receiver applicability keeps nullable extension and dispatch receivers" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    _ = try pushTestClass(&m, a, "Scope", "app.Scope", "app");
    const choose = try pushTestFuncOpts(
        &m,
        a,
        "choose",
        "app.choose",
        "app",
        1,
        .{ .extension = true },
    );
    m.funcs.items[choose.int()].params[0].ty.name = "app.Scope";
    m.funcs.items[choose.int()].kind = .top_level_extension;
    const choose_sig = [_]TypeRef{
        .{ .name = "Int", .nullable = false, .args = &.{} },
    };
    try m.decl_sigs.put(choose.int(), .{
        .receiver_ty = .{ .name = "app.Scope", .nullable = false, .args = &.{} },
        .arity = .{ .required = 1, .total = 1, .has_vararg = false },
        .sig = &choose_sig,
        .kind = .top_level_extension,
        .has_body = true,
    });
    try m.rebuildFuncNameIndex(a);

    const args = [_]applicability.ArgShape{
        .{ .ty = .{ .name = "Int", .nullable = false, .args = &.{} } },
    };
    try testing.expectEqual(true, m.knownReceiverCallableApplicable(
        "choose",
        "app",
        FileId.from(0),
        &args,
        .{
            .recv_ty = "app.Scope",
            .recv_type = .{ .name = "app.Scope", .nullable = true, .args = &.{} },
            .owner_class = "app.Scope",
            .receiver_scope_complete = true,
        },
    ).?);
}

test "known receiver applicability checks exact receivers before erased generic owners" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    _ = try pushTestClass(&m, a, "String", "kotlin.String", "kotlin");
    _ = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Box",
        .fqn = "app.Box",
        .package = "app",
        .type_params = &.{"T"},
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    try m.registry.class_type_param_bounds.put("app.Box", try a.dupe(ModuleRegistry.TypeParamBound, &.{
        .{ .param = "T", .bound = "kotlin.Any" },
    }));
    const choose = try pushTestFuncOpts(
        &m,
        a,
        "choose",
        "app.stringChoose",
        "app",
        1,
        .{ .extension = true },
    );
    m.funcs.items[choose.int()].kind = .top_level_extension;
    const choose_sig = [_]TypeRef{
        .{ .name = "Int", .nullable = false, .args = &.{} },
    };
    try m.decl_sigs.put(choose.int(), .{
        .receiver_ty = .{ .name = "String", .nullable = false, .args = &.{} },
        .arity = .{ .required = 1, .total = 1, .has_vararg = false },
        .sig = &choose_sig,
        .kind = .top_level_extension,
        .has_body = true,
    });
    try m.rebuildFuncNameIndex(a);

    const args = [_]applicability.ArgShape{
        .{ .ty = .{ .name = "Int", .nullable = false, .args = &.{} } },
    };
    const ctx = Module.ResolveCtx{
        .recv_ty = "String",
        .recv_type = .{ .name = "String", .nullable = false, .args = &.{} },
        .owner_class = "Box",
        .receiver_scope_complete = true,
    };
    try testing.expectEqual(true, m.knownReceiverCallableApplicable(
        "choose",
        "app",
        FileId.from(0),
        &args,
        ctx,
    ).?);
    try testing.expectEqual(false, m.knownReceiverCallableApplicable(
        "missing",
        "app",
        FileId.from(0),
        &args,
        ctx,
    ).?);
}

test "an imported same-name upper bound cannot complete raw bound evidence" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    const left = try pushTestClass(&m, a, "Bound", "left.Bound", "left");
    _ = try pushTestClass(&m, a, "Bound", "right.Bound", "right");
    _ = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Box",
        .fqn = "app.Box",
        .package = "app",
        .type_params = &.{"T"},
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    try m.registry.class_type_param_bounds.put("app.Box", try a.dupe(ModuleRegistry.TypeParamBound, &.{
        .{ .param = "T", .bound = "Bound", .complete = true },
    }));

    var paths: std.ArrayList(ModuleRegistry.ImportPath) = .empty;
    const segs = try a.alloc([]const u8, 2);
    segs[0] = "left";
    segs[1] = "Bound";
    try paths.append(a, .{ .fqn = try a.dupe(u8, "left.Bound"), .segs = segs });
    var imports = std.StringHashMap(std.ArrayList(ModuleRegistry.ImportPath)).init(a);
    try imports.put("Bound", paths);
    try m.registry.import_aliases.put(FileId.from(0), imports);
    try testing.expectEqual(left, m.classIdIndexed("Bound", "app", FileId.from(0)).?);

    try testing.expect(m.knownReceiverCallableApplicable(
        "missing",
        "app",
        FileId.from(0),
        &.{},
        .{
            .in_receiver_context = true,
            .receiver_known = true,
            .owner_class = "Box",
            .receiver_scope_complete = true,
        },
    ) == null);

    _ = try pushTestClass(&m, a, "U", "app.U", "app");
    _ = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Wrapper",
        .fqn = "app.Wrapper",
        .package = "app",
        .type_params = &.{"T"},
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    const dependent_bounds = [_]ModuleRegistry.TypeParamBound{
        .{ .param = "T", .bound = "U", .complete = true },
        .{ .param = "U", .bound = "Comparable", .complete = false },
    };
    const wrapper_args = [_]TypeRef{
        .{ .name = "T", .nullable = false, .args = &.{} },
    };
    try testing.expect(!m.staticTypeProofComplete(.{
        .name = "Wrapper",
        .nullable = false,
        .args = @constCast(&wrapper_args),
    }, &dependent_bounds));
}

test "dependent candidate bounds use declaration bindings not caller names" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    _ = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Pair",
        .fqn = "app.Pair",
        .package = "app",
        .type_params = &.{ "First", "Second" },
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    const declared_bounds = [_]ModuleRegistry.TypeParamBound{
        .{ .param = "T", .bound = "U" },
        .{ .param = "U", .bound = "Number" },
    };
    const caller_bounds = [_]ModuleRegistry.TypeParamBound{
        .{ .param = "A", .bound = "U" },
        .{ .param = "U", .bound = "Number" },
        .{ .param = "V", .bound = "Number" },
    };
    const pattern_args = [_]TypeRef{
        .{ .name = "T", .nullable = false, .args = &.{} },
        .{ .name = "U", .nullable = false, .args = &.{} },
    };
    const pattern = TypeRef{
        .name = "Pair",
        .nullable = false,
        .args = @constCast(&pattern_args),
    };
    const invalid_args = [_]TypeRef{
        .{ .name = "A", .nullable = false, .args = &.{} },
        .{ .name = "V", .nullable = false, .args = &.{} },
    };
    try testing.expect(!(try m.staticGenericReceiverApplicable(
        a,
        .{ .name = "Pair", .nullable = false, .args = @constCast(&invalid_args) },
        pattern,
        &declared_bounds,
        &caller_bounds,
    )));
    const valid_args = [_]TypeRef{
        .{ .name = "A", .nullable = false, .args = &.{} },
        .{ .name = "U", .nullable = false, .args = &.{} },
    };
    try testing.expect(try m.staticGenericReceiverApplicable(
        a,
        .{ .name = "Pair", .nullable = false, .args = @constCast(&valid_args) },
        pattern,
        &declared_bounds,
        &caller_bounds,
    ));

    const any_declared_bounds = [_]ModuleRegistry.TypeParamBound{
        .{ .param = "T", .bound = "Any" },
        .{ .param = "Any", .bound = "Number" },
    };
    const any_caller_bounds = [_]ModuleRegistry.TypeParamBound{
        .{ .param = "A", .bound = "Any" },
        .{ .param = "Any", .bound = "Number" },
        .{ .param = "V", .bound = "Number" },
    };
    const any_pattern_args = [_]TypeRef{
        .{ .name = "T", .nullable = false, .args = &.{} },
        .{ .name = "Any", .nullable = false, .args = &.{} },
    };
    const any_pattern = TypeRef{
        .name = "Pair",
        .nullable = false,
        .args = @constCast(&any_pattern_args),
    };
    try testing.expect(!(try m.staticGenericReceiverApplicable(
        a,
        .{ .name = "Pair", .nullable = false, .args = @constCast(&invalid_args) },
        any_pattern,
        &any_declared_bounds,
        &any_caller_bounds,
    )));
    const synthetic_any_bounds = [_]ModuleRegistry.TypeParamBound{
        .{ .param = "T", .bound = "kotlin.Any" },
        .{ .param = "Any", .bound = "Number" },
    };
    try testing.expect(try m.staticGenericReceiverApplicable(
        a,
        .{ .name = "Pair", .nullable = false, .args = @constCast(&invalid_args) },
        any_pattern,
        &synthetic_any_bounds,
        &any_caller_bounds,
    ));

    const base = try pushTestClass(&m, a, "Base", "app.Base", "app");
    const supers = [_]ClassId{base};
    _ = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Sub",
        .fqn = "app.Sub",
        .package = "app",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = @constCast(&supers),
    });
    const nominal_declared_bounds = [_]ModuleRegistry.TypeParamBound{
        .{ .param = "T", .bound = "U" },
        .{ .param = "U", .bound = "kotlin.Any" },
    };
    const nominal_caller_bounds = [_]ModuleRegistry.TypeParamBound{
        .{ .param = "A", .bound = "Sub" },
        .{ .param = "Base", .bound = "kotlin.Any" },
    };
    const nominal_args = [_]TypeRef{
        .{ .name = "A", .nullable = false, .args = &.{} },
        .{ .name = "Base", .nullable = false, .args = &.{} },
    };
    try testing.expect(!(try m.staticGenericReceiverApplicable(
        a,
        .{ .name = "Pair", .nullable = false, .args = @constCast(&nominal_args) },
        pattern,
        &nominal_declared_bounds,
        &nominal_caller_bounds,
    )));
}

test "resolveCall retains a generic dispatch-owner extension" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    _ = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Box",
        .fqn = "app.Box",
        .package = "app",
        .type_params = &.{"T"},
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    try m.registry.class_type_param_bounds.put("app.Box", try a.dupe(ModuleRegistry.TypeParamBound, &.{
        .{ .param = "T", .bound = "kotlin.Any" },
    }));
    const global = try pushTestFunc(&m, a, "pick", "app.pick", "app", 0);
    const extension = try pushTestFuncOpts(
        &m,
        a,
        "pick",
        "app.boxPick",
        "app",
        0,
        .{ .extension = true },
    );
    const box_args = [_]TypeRef{
        .{ .name = "T", .nullable = false, .args = &.{} },
    };
    const box_t = TypeRef{
        .name = "Box",
        .nullable = false,
        .args = @constCast(&box_args),
    };
    m.funcs.items[extension.int()].params[0].ty = box_t;
    m.funcs.items[extension.int()].kind = .top_level_extension;
    try m.decl_sigs.put(extension.int(), .{
        .receiver_ty = box_t,
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .sig = &.{},
        .kind = .top_level_extension,
        .has_body = true,
    });
    try m.rebuildFuncNameIndex(a);

    const res = try m.resolveCall(a, "pick", "app", FileId.from(0), &.{}, false, .{
        .in_receiver_context = true,
        .receiver_known = true,
        .owner_class = "Box",
        .receiver_scope_complete = true,
    });
    defer a.free(res.candidate_set);
    try testing.expectEqual(global, res.target.?);
    try testing.expectEqual(Module.EmitForm.CallMemberOrGlobal, res.emit_form);
    try testing.expectEqual(Module.Confidence.virtual, res.confidence);

    const global_wrong = try pushTestFunc(&m, a, "wrong", "app.wrong", "app", 0);
    const concrete_extension = try pushTestFuncOpts(
        &m,
        a,
        "wrong",
        "app.stringBoxWrong",
        "app",
        0,
        .{ .extension = true },
    );
    const string_args = [_]TypeRef{
        .{ .name = "String", .nullable = false, .args = &.{} },
    };
    const box_string = TypeRef{
        .name = "Box",
        .nullable = false,
        .args = @constCast(&string_args),
    };
    m.funcs.items[concrete_extension.int()].params[0].ty = box_string;
    m.funcs.items[concrete_extension.int()].kind = .top_level_extension;
    try m.decl_sigs.put(concrete_extension.int(), .{
        .receiver_ty = box_string,
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .sig = &.{},
        .kind = .top_level_extension,
        .has_body = true,
    });
    try m.rebuildFuncNameIndex(a);

    const wrong = try m.resolveCall(a, "wrong", "app", FileId.from(0), &.{}, false, .{
        .in_receiver_context = true,
        .receiver_known = true,
        .owner_class = "Box",
        .receiver_scope_complete = true,
    });
    defer a.free(wrong.candidate_set);
    try testing.expectEqual(global_wrong, wrong.target.?);
    try testing.expectEqual(Module.EmitForm.Call, wrong.emit_form);
    try testing.expectEqual(Module.Confidence.exact, wrong.confidence);
}

test "resolveCall applies a generic dispatch-owner upper bound" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    _ = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Box",
        .fqn = "app.Box",
        .package = "app",
        .type_params = &.{"T"},
        .type_param_variance = &.{.Out},
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    try m.registry.class_type_param_bounds.put("app.Box", try a.dupe(ModuleRegistry.TypeParamBound, &.{
        .{ .param = "T", .bound = "Number" },
    }));
    const global = try pushTestFunc(&m, a, "bounded", "app.bounded", "app", 0);
    const extension = try pushTestFuncOpts(
        &m,
        a,
        "bounded",
        "app.boundedBox",
        "app",
        0,
        .{ .extension = true },
    );
    const number_args = [_]TypeRef{
        .{ .name = "Number", .nullable = false, .args = &.{} },
    };
    const box_number = TypeRef{
        .name = "Box",
        .nullable = false,
        .args = @constCast(&number_args),
    };
    m.funcs.items[extension.int()].params[0].ty = box_number;
    m.funcs.items[extension.int()].kind = .top_level_extension;
    try m.decl_sigs.put(extension.int(), .{
        .receiver_ty = box_number,
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .sig = &.{},
        .kind = .top_level_extension,
        .has_body = true,
    });
    try m.rebuildFuncNameIndex(a);

    const res = try m.resolveCall(a, "bounded", "app", FileId.from(0), &.{}, false, .{
        .in_receiver_context = true,
        .receiver_known = true,
        .owner_class = "Box",
        .receiver_scope_complete = true,
    });
    defer a.free(res.candidate_set);
    try testing.expectEqual(global, res.target.?);
    try testing.expectEqual(Module.EmitForm.CallMemberOrGlobal, res.emit_form);
    try testing.expectEqual(Module.Confidence.virtual, res.confidence);

    @constCast(m.registry.class_type_param_bounds.get("app.Box").?)[0].complete = false;
    const uncertain_global = try pushTestFunc(&m, a, "uncertain", "app.uncertain", "app", 0);
    const uncertain_extension = try pushTestFuncOpts(
        &m,
        a,
        "uncertain",
        "app.uncertainStringBox",
        "app",
        0,
        .{ .extension = true },
    );
    const string_args = [_]TypeRef{
        .{ .name = "String", .nullable = false, .args = &.{} },
    };
    const box_string = TypeRef{
        .name = "Box",
        .nullable = false,
        .args = @constCast(&string_args),
    };
    m.funcs.items[uncertain_extension.int()].params[0].ty = box_string;
    m.funcs.items[uncertain_extension.int()].kind = .top_level_extension;
    try m.decl_sigs.put(uncertain_extension.int(), .{
        .receiver_ty = box_string,
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .sig = &.{},
        .kind = .top_level_extension,
        .has_body = true,
    });
    try m.rebuildFuncNameIndex(a);
    const uncertain = try m.resolveCall(
        a,
        "uncertain",
        "app",
        FileId.from(0),
        &.{},
        false,
        .{
            .in_receiver_context = true,
            .receiver_known = true,
            .owner_class = "Box",
            .receiver_scope_complete = true,
        },
    );
    defer a.free(uncertain.candidate_set);
    try testing.expectEqual(uncertain_global, uncertain.target.?);
    try testing.expectEqual(Module.EmitForm.CallMemberOrGlobal, uncertain.emit_form);
    try testing.expectEqual(Module.Confidence.virtual, uncertain.confidence);
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
        .host_symbol = "kotlin.io.println",
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
        .host_symbol = "kotlin.intArrayOf",
    });
    try m.rebuildFuncNameIndex(a);

    const println_args = [_]applicability.ArgShape{.{
        .ty = .{ .name = "String", .nullable = false, .args = &.{} },
    }};
    const print_res = try m.resolveCall(a, "println", "app", FileId.from(0), &println_args, false, .{});
    defer a.free(print_res.candidate_set);
    try testing.expectEqual(println.int(), print_res.target.?.int());
    try testing.expectEqual(Module.EmitForm.Call, print_res.emit_form);
    try testing.expect(print_res.target_final);

    const int_args = [_]applicability.ArgShape{
        .{ .ty = .{ .name = "Int", .nullable = false, .args = &.{} } },
        .{ .ty = .{ .name = "Int", .nullable = false, .args = &.{} } },
        .{ .ty = .{ .name = "Int", .nullable = false, .args = &.{} } },
    };
    const ints_res = try m.resolveCall(a, "intArrayOf", "app", FileId.from(0), &int_args, false, .{});
    defer a.free(ints_res.candidate_set);
    try testing.expectEqual(ints.int(), ints_res.target.?.int());
    try testing.expectEqual(Module.EmitForm.Call, ints_res.emit_form);
    try testing.expect(ints_res.target_final);
}

test "resolveCall binds a bodyless expect declaration" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    const intrinsic = try pushTestFuncOpts(
        &m,
        a,
        "enumEntriesIntrinsic",
        "kotlin.enums.enumEntriesIntrinsic",
        "kotlin.enums",
        0,
        .{ .stub = true },
    );
    m.funcs.items[intrinsic.int()].is_expect = true;
    try m.decl_sigs.put(intrinsic.int(), .{
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .sig = &.{},
        .has_body = false,
    });
    try m.rebuildFuncNameIndex(a);

    const resolved = try m.resolveCall(
        a,
        "enumEntriesIntrinsic",
        "kotlin.enums",
        FileId.from(0),
        &.{},
        false,
        .{},
    );
    defer a.free(resolved.candidate_set);
    try testing.expectEqual(intrinsic, resolved.target.?);
    try testing.expectEqual(Module.EmitForm.Call, resolved.emit_form);
    try testing.expect(resolved.target_final);
}

test "resolveCall: a resolved extension in a receiver context defers to CallMemberOrGlobal" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // The only candidate is an extension; applicability resolves it and the
    // emission decision retains the member-first walk.
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
    // Two incomplete same-arity stubs of different declared types carry no
    // canonical declaration record, so applicability cannot rank either and
    // the call remains a runtime probe.

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

test "uniqueClassIdBySimpleName caches without changing scan semantics" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer m.deinit(a);
    const solo = try pushTestClass(&m, a, "Solo", "lib.Solo", "lib");
    const inner = try pushTestClass(&m, a, "Outer$Inner", "lib.Outer.Inner", "lib");
    // Unique names resolve, via both the class name and the FQN's last segment.
    try testing.expectEqual(solo.int(), m.uniqueClassIdBySimpleName("Solo").?.int());
    try testing.expectEqual(inner.int(), m.uniqueClassIdBySimpleName("Inner").?.int());
    try testing.expectEqual(inner.int(), m.uniqueClassIdBySimpleName("Outer$Inner").?.int());
    try testing.expect(m.uniqueClassIdBySimpleName("Missing") == null);
    // A class appended after the first lookup is visible to the next one,
    // and a second identity under the same simple name makes it ambiguous.
    _ = try pushTestClass(&m, a, "Solo", "app.Solo", "app");
    try testing.expect(m.uniqueClassIdBySimpleName("Solo") == null);
    try testing.expectEqual(inner.int(), m.uniqueClassIdBySimpleName("Inner").?.int());
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

test "a cross-file private declaration is not a bare-call candidate" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // A private member extension declared in file 7 (a test class's
    // `CoroutineScope.block(context)`) must not enter another file's
    // candidate set; the same-file query still sees it.
    const priv = try pushTestFuncOpts(&m, a, "block", "lib.T.block", "lib", 1, .{ .extension = true });
    m.funcs.items[priv.int()].kind = .member_extension;
    try m.registry.member_ext_owner_class.put(priv, "T");
    try m.registry.private_fn_files.put(priv, FileId.from(7));
    try m.rebuildFuncNameIndex(a);
    const cross = try m.bareCallCandidates(a, "block", FileId.from(3));
    defer a.free(cross);
    try testing.expectEqual(@as(usize, 0), cross.len);
    const same = try m.bareCallCandidates(a, "block", FileId.from(7));
    defer a.free(same);
    try testing.expectEqual(@as(usize, 1), same.len);
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
