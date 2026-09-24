const std = @import("std");
const runtime = @import("runtime");
const root_ir = @import("../ir.zig");
const core_ids = @import("ids.zig");

const BlockId = core_ids.BlockId;
const ClassId = core_ids.ClassId;
const ConstId = core_ids.ConstId;
const FuncId = core_ids.FuncId;
const MethodSlotId = core_ids.MethodSlotId;
const NativeId = core_ids.NativeId;
const StaticId = core_ids.StaticId;
const NO_FUNC = core_ids.NO_FUNC;
const Reg = core_ids.Reg;
const Span = root_ir.Span;
const TypeRef = core_ids.TypeRef;

/// Call a callable value with mixed positional and spread args; each spread part's
/// array or list items are flattened into positional args at evaluation time.
pub const CallSpreadInst = struct {
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

    /// Owned by the instruction out of line; the walkers follow the pointer.
    pub const hashed_by_content = {};
};

/// Bare-name call inside a lambda body that may run with a this-receiver: dispatch as
/// a member when the captured `this` has one, else fall back to a top-level lookup.
pub const CallMemberOrGlobalInst = struct {
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
    /// No receiver in scope at this site can answer the name, so only the
    /// global leg can win and the hedge is dead. Set by a link pass from
    /// whole-program knowledge; `KLIO_XORY_AUDIT` reports any site marked
    /// this way whose member leg wins anyway.
    global_only: bool = false,
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

    /// Owned by the instruction out of line; the walkers follow the pointer.
    pub const hashed_by_content = {};
};

/// The lowering facts a member call rarely carries, out of line so the
/// instruction stays 64 bytes: the hot path reads the receiver, the name,
/// the argument run and the site memo inline.
/// What a `GetField`'s `own_cls`/`own_slot` pair resolved to.
/// `Cast.cls_raw` when the site named no class.
pub const NO_CLASS: u32 = std.math.maxInt(u32);

pub const OwnKind = enum(u8) {
    /// Nothing yet. `own_cls` may still name the receiver's static class, which
    /// is what a link pass needs to resolve the read.
    none,
    /// `own_slot` is a declared field-layout index.
    slot,
    /// `own_cls` names an enum and `own_slot` is an entry index.
    enum_entry,
    /// `own_slot` is the `FuncId` of the property getter that answers the read.
    getter,
    /// `own_slot` is a `PropSlotId`: the receiver's runtime class indexes the
    /// property table with it, so an interface or abstract receiver resolves
    /// without the site knowing which implementation answers.
    prop_slot,
    /// The read is the `<class-companion-or-self>` sentinel: a bare class name
    /// in value position, answered from the class's own companion memo. The
    /// spelling is fixed at lowering, so the runtime should not be comparing
    /// the string on every field read to find out.
    companion_or_self,
    /// `super.<prop>` (or `super.<prop> = v`) whose answer is not known
    /// while the body lowers: `own_cls` is the class the reference resolves
    /// against, `own_slot` is 1 when the reference named that class itself
    /// (`super<K>`) and 0 when it means the class's supertypes. The link
    /// pass settles it into a direct accessor call or `super_slot`; it must
    /// never reach execution, because the only by-name answer is a virtual
    /// one and that re-enters the override making the super access.
    super_target,
    /// `own_slot` is a declared field-layout index of `own_cls`, a base of
    /// the receiver's class, and the cell is served WITHOUT dispatch and
    /// without the value-kind declines a claimed slot makes: `super.x` on a
    /// stored property is the base's cell whatever it holds.
    super_slot,
};

/// The sentinel field name a bare class name in value position reads through.
pub const COMPANION_OR_SELF = "<class-companion-or-self>";

/// Set in a pending super write's `own_slot` when the reference named the
/// class itself (`super<K>.prop = v`) rather than its supertypes; the low
/// bits are the result register the settled call writes.
pub const SUPER_WRITE_QUALIFIED: u32 = 1 << 31;

pub const CallMemberExtra = struct {
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
    /// Dispatch receiver for a resolved member-extension target, picked by the implicit
    /// receiver tower; the extension receiver stays in `receiver`. Null for plain members.
    dispatch_receiver: ?Reg = null,
    /// The extension declaration the resolver ranked first and then withheld, carried so
    /// the runtime can say whether committing it here would name what the by-name walk
    /// serves. Filled only under `KLIO_EXT_AUDIT`; null in every normal lowering.
    audit_pick: ?FuncId = null,
    /// Which resolver withheld `audit_pick`, so the audit can judge each criterion on
    /// its own rows: 0 an extension pick, 1 an extension pick that is the sole candidate
    /// at the best applicability tier over a named receiver head, 2 the member gate's
    /// named-but-undispatched declaration.
    audit_pick_kind: u8 = 0,

    pub const hashed_by_content = {};

    pub fn isDefault(self: *const CallMemberExtra) bool {
        return self.arg_names.len == 0 and !self.trailing_lambda and self.static_recv == null and
            self.declared_recv == null and self.resolved == null and self.dispatch_receiver == null and
            self.audit_pick == null;
    }
};

pub const no_member_extra: CallMemberExtra = .{};

/// A member the interpreter answers itself rather than through a `FuncId`.
///
/// An indexed read on an array is the shape: `kotlin.FloatArray.get` runs
/// 19 572 times in one compose program and there is no function to name, so
/// the site carried a string and `fastSubscript` interned and compared it on
/// every one of the 939 154 subscripts the corpus executes. The operation is
/// a property of the SITE — the name and the argument count both fix it — so
/// it belongs on the instruction.
pub const BuiltinMember = enum(u8) {
    none,
    /// `recv[i]`, one argument.
    get,
    /// `recv[i] = v`, two.
    set,
    compare_to,
    is_empty,
    to_int,
    to_long,
    inv,
    shl,
    shr,
    ushr,
    bit_and,
    bit_or,
    bit_xor,
    /// Appended, not inserted: the tag is serialized, so an existing value
    /// keeps its number.
    to_string,
    /// `super.toString()`, `super.hashCode()` and `super.equals(x)` where no
    /// supertype declares the member: the language names `Any`'s
    /// implementation, and it runs on the receiver WITHOUT dispatch, since
    /// the override that would answer a virtual call is the very body
    /// making the super call. Never bound from a name by `of`; only the
    /// super-call emitter sets them, and `builtin_proven` goes with them
    /// because the operation cannot fall through to the by-name walk.
    any_to_string,
    any_hash_code,
    any_equals,

    /// The operation a member call names, from the two things that decide it.
    /// The receiver's own shape is checked where the operation runs: an
    /// `Instance` declaring `operator fun get` is a real call, not this, and a
    /// `List` with a live backing computes its own length.
    pub fn of(name: []const u8, n_args: u32) BuiltinMember {
        return switch (n_args) {
            0 => if (std.mem.eql(u8, name, "isEmpty")) .is_empty
                else if (std.mem.eql(u8, name, "toInt")) .to_int
                else if (std.mem.eql(u8, name, "toLong")) .to_long
                else if (std.mem.eql(u8, name, "inv")) .inv
                else if (std.mem.eql(u8, name, "toString")) .to_string
                else .none,
            1 => if (std.mem.eql(u8, name, "get")) .get
                else if (std.mem.eql(u8, name, "compareTo")) .compare_to
                else if (std.mem.eql(u8, name, "shl")) .shl
                else if (std.mem.eql(u8, name, "shr")) .shr
                else if (std.mem.eql(u8, name, "ushr")) .ushr
                else if (std.mem.eql(u8, name, "and")) .bit_and
                else if (std.mem.eql(u8, name, "or")) .bit_or
                else if (std.mem.eql(u8, name, "xor")) .bit_xor
                else .none,
            2 => if (std.mem.eql(u8, name, "set")) .set else .none,
            else => .none,
        };
    }
};

/// A property the interpreter answers from the receiver's own representation
/// rather than through a declaration.
///
/// `arr.size` on a primitive array and `s.length` on a String are declared
/// MEMBERS of a host-backed classifier, so no user extension can shadow them
/// and there is no function to name. Bound from the field name where the
/// instruction is pushed; `builtin_proven` is what lets the census call the
/// site resolved, and a link pass sets it once the receiver's static head is
/// known to be one of those classifiers.
pub const BuiltinField = enum(u8) {
    none,
    /// `size` on an array.
    array_size,
    /// `length` on a String.
    string_length,
    /// `lastIndex` on an array: the stdlib extension property.
    array_last_index,
    /// `indices` on an array: the stdlib extension property.
    array_indices,
    /// `storage` on an unsigned array: the signed buffer the view is over.
    array_storage,
    /// `data` on an unsigned scalar: its signed counterpart.
    scalar_data,

    pub fn of(name: []const u8) BuiltinField {
        if (std.mem.eql(u8, name, "size")) return .array_size;
        if (std.mem.eql(u8, name, "length")) return .string_length;
        if (std.mem.eql(u8, name, "lastIndex")) return .array_last_index;
        if (std.mem.eql(u8, name, "indices")) return .array_indices;
        if (std.mem.eql(u8, name, "storage")) return .array_storage;
        if (std.mem.eql(u8, name, "data")) return .scalar_data;
        return .none;
    }
};

pub const CallMemberInst = struct {
    dst: Reg,
    receiver: Reg,
    name: ConstId,
    args: Reg,
    n_args: u32,
    /// The builtin operation `name` denotes, bound where the instruction is
    /// pushed so no emitter can leave it unset.
    builtin: BuiltinMember = .none,
    /// `builtin` is set AND the site's static receiver head names a type no
    /// interpreted instance can wear, so the operation cannot fall through to
    /// the by-name walk. Set by a link pass, because it needs the receiver
    /// head resolved against the class table. This is the bit that lets the
    /// census call such a site resolved: the runtime's tag test is then an
    /// assertion, not a derivation.
    builtin_proven: bool = false,
    /// Site memo, single-fill (see `GetField.site_cls`): the first Instance class whose
    /// by-name dispatch flat-resolved claims it, `site_sig` the argument signature it was
    /// keyed under, `site_route` the packed target (`FuncId << 1 | 1`, never 0 if filled).
    site_cls: u64 = 0,
    site_sig: u64 = 0,
    site_route: u64 = 0,
    /// Null when every lowering fact is at its default; read through `x()`.
    extra: ?*const CallMemberExtra = null,

    pub inline fn x(self: *const CallMemberInst) *const CallMemberExtra {
        return self.extra orelse &no_member_extra;
    }
};

/// The lowering facts a resolved virtual call rarely carries, out of line.
pub const CallVirtualExtra = struct {
    /// Declaration parameter index filled by each source-order argument (receiver
    /// excluded). Null selects positional binding; a non-null empty map is an indexed
    /// zero-argument call such as an empty vararg. Resolved against the slot root.
    arg_params: ?[]u32 = null,
    arg_names: []?ConstId = &.{},
    trailing_lambda: bool = false,

    pub const hashed_by_content = {};

    pub fn isDefault(self: *const CallVirtualExtra) bool {
        return self.arg_params == null and self.arg_names.len == 0 and !self.trailing_lambda;
    }
};

pub const no_virtual_extra: CallVirtualExtra = .{};

/// Virtual member call whose overload was resolved statically; `slot` names the selected
/// override family. Runtime work is one `(ClassId, slot) -> FuncId` lookup, which a
/// host-backed receiver lacks, so it walks by member name.
pub const CallVirtualInst = struct {
    dst: Reg,
    receiver: Reg,
    slot: MethodSlotId,
    args: Reg,
    n_args: u32,
    /// Site memo, single-fill (see `GetField.site_cls`), for a host-backed receiver:
    /// `site_cls` interns the receiver type FQN pointer (CAS from 0), `site_name_*` the
    /// member name, `site_native` the native form, stored LAST with release as the gate.
    site_cls: u64 = 0,
    site_native: u64 = 0,
    site_name_ptr: u64 = 0,
    site_name_len: u32 = 0,
    /// Null when every lowering fact is at its default; read through `x()`.
    extra: ?*const CallVirtualExtra = null,

    pub inline fn x(self: *const CallVirtualInst) *const CallVirtualExtra {
        return self.extra orelse &no_virtual_extra;
    }
};

/// `NewInstance.ctor_pick` when lowering named no constructor.
pub const CTOR_PICK_NONE: u16 = std.math.maxInt(u16);

/// `CallStatic.init` when the call runs no init unit first.
pub const NO_UNIT: u32 = std.math.maxInt(u32);

pub const Inst = union(enum) {
    Const: struct { dst: Reg, value: ConstId },
    /// Suspend-resume marker: `state` picks the resume block from the entry dispatch table.
    SuspendResumePoint: struct { state: u32 },
    LoadParam: struct { dst: Reg, idx: u16 },
    /// The dispatch receiver of a member-extension frame: the owner instance the
    /// caller handed over for this call, which the body names `this@Owner`.
    LoadDispatchThis: struct { dst: Reg },
    /// The outer instance an inner-class instance at `src` was constructed in:
    /// one hop out along the instance's outer link, by structure, not by name.
    LoadOuterThis: struct { dst: Reg, src: Reg },
    /// The `idx`th context parameter of a contextual frame: the value the caller
    /// handed over for this call, in declaration order.
    LoadContextParam: struct { dst: Reg, idx: u16 },
    /// Hand the contextual callee its `n` context arguments from the run at
    /// `args`, in its declaration order, ahead of the call; `ContextPop` retracts them.
    ContextPush: struct { args: Reg, n: u32 },
    ContextPop: struct { n: u32 },
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
        /// Lowering's claim: the receiver holds this read at declared slot
        /// `own_slot` of `own_cls`'s published layout. A HINT, never an index
        /// taken on trust — the runtime proves it by reading the slot's name,
        /// so a stale claim costs a miss and not a wrong answer. Only a
        /// DECLARED slot is claimed: its index is the same in the class and in
        /// every subclass, where a capture's is not.
        own_cls: ?ClassId = null,
        own_slot: u32 = 0,
        /// What `own_cls` and `own_slot` mean, so the class can be recorded
        /// before anything is resolved from it: a read whose receiver class
        /// lowering knows but whose answer is a getter cannot be settled while
        /// the class body is still lowering, and a later link pass fills it.
        own_kind: OwnKind = .none,
        /// The builtin property the field name denotes, bound where the
        /// instruction is pushed so no emitter can leave it unset.
        builtin: BuiltinField = .none,
        /// `builtin` is set AND the receiver's static head names the host
        /// classifier that declares it, so the read cannot fall through to the
        /// by-name ladder. Set by a link pass, because it needs the head.
        builtin_proven: bool = false,
    },
    SetField: struct {
        receiver: Reg,
        field: ConstId,
        value: Reg,
        /// The declared slot lowering proved this write lands in, and the class whose layout
        /// fixed it, on `GetField.own_cls`'s conditions. A plain slot has no setter, so the
        /// store is the whole operation. Re-proved against the receiver before use, so a
        /// stale claim costs a miss and not a write to the wrong cell.
        own_cls: ?ClassId = null,
        own_slot: u32 = 0,
        /// `.none` with an `own_cls` is the claim above. `.super_target` is a
        /// `super.prop = v` the link pass settles: into a direct setter call,
        /// for which `own_slot` carries the pre-allocated result register
        /// under `SUPER_WRITE_QUALIFIED` and `value` is the register after
        /// `receiver`, or into `.super_slot`.
        own_kind: OwnKind = .none,
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
    /// `recv.name(args)`, resolved by name at run time; `resolved` in the extra box names a
    /// monomorphic target lowering proved. Named so the union stays 64 bytes.
    CallMember: CallMemberInst,
    CallVirtual: CallVirtualInst,
    /// Boxed: rare and large.
    CallSpread: *CallSpreadInst,
    CallMemberOrGlobal: *CallMemberOrGlobalInst,
    NewInstance: struct {
        dst: Reg,
        class: ClassId,
        args: Reg,
        n_args: u32,
        arg_names: []?ConstId = &.{},
        /// Declared type head of each argument where lowering knows one. Kotlin picks a
        /// constructor overload from static types, which an interpreted value cannot supply.
        arg_static_heads: []?ConstId = &.{},
        /// The constructor this construction reaches, numbered 0 for the
        /// primary and 1 + i for the i'th secondary, or `CTOR_PICK_NONE` where
        /// lowering could not settle it and the runtime's scoring decides.
        ctor_pick: u16 = CTOR_PICK_NONE,
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
        /// The class `ty` names, on the same terms as `InstanceOf.cls`: the
        /// cast's first question is whether the value already IS that class.
        /// A raw id with a sentinel rather than an optional — `ClassId` fills
        /// its integer, so `?ClassId` has no niche and costs eight bytes here,
        /// which is more than the union has left.
        cls_raw: u32 = NO_CLASS,

        pub fn cls(self: @This()) ?ClassId {
            return if (self.cls_raw == NO_CLASS) null else ClassId.from(self.cls_raw);
        }
    },
    InstanceOf: struct {
        dst: Reg,
        src: Reg,
        ty: TypeRef,
        /// The class `ty` names, when it names exactly one and the test is the
        /// plain identity question — not `is T?`, which admits null, and not
        /// `is List<String>`, whose argument is erased. Null leaves the test to
        /// the by-name walk.
        cls: ?ClassId = null,
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
    /// `type_qualifier`: the CLASS value, never the object's singleton — `Alias<T>::m`
    /// writes a type, so the reference it qualifies is unbound.
    /// A slotted top-level property carries its index in the root scope's slot table, so the read
    /// addresses the binding without its name; the name stays for the read that initialises it.
    LoadGlobal: struct { dst: Reg, name: ConstId, func: ?FuncId = null, class: ?ClassId = null, ctor_ref: bool = false, type_qualifier: bool = false, slot: ?u32 = null },
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
    /// Write a top-level binding, routed through `Host.store_global` so a delegated
    /// top-level property's setter (or a plain top-level `var`) is updated.
    /// `slot`: the same index for a plain stored `var`, whose write has no setter or delegate to run.
    StoreGlobal: struct { name: ConstId, value: Reg, slot: ?u32 = null },
    /// Materialise a lambda value: `captures` lists the registers the evaluator snapshots
    /// into a closure env, and `body_func` is the body lowered as a separate Func.
    Lambda: struct {
        dst: Reg,
        body_func: FuncId,
        captures: []Reg,
    },

    // Lowered from sema: every operand is an id, and nothing here is looked
    // up by name. The `R` variants replace same-named ones of another shape.

    /// Run `func` over the argument run: its native when it has one, else its body.
    /// `init`: the init unit the call runs first, the file of the facade that
    /// declares `func` when the caller is not code of that facade; `NO_UNIT`
    /// for none.
    CallStatic: struct { dst: Reg, func: FuncId, args: Reg, n_args: u32, init: u32 = NO_UNIT },
    /// Run the implementation of `slot` for the class of `args[0]`.
    RCallVirtual: struct { dst: Reg, slot: MethodSlotId, args: Reg, n_args: u32 },
    /// As `RCallVirtual`, through a member of interface `iface`.
    CallInterface: struct { dst: Reg, iface: ClassId, slot: MethodSlotId, args: Reg, n_args: u32 },
    /// Run host function `native` over the argument run.
    /// `direct`: a `super` call, which runs the native as it is. Otherwise a
    /// Kotlin receiver whose class overrides the member the native
    /// implements runs its override (`resolved.NativeRt.slot`).
    CallNative: struct { dst: Reg, native: NativeId, args: Reg, n_args: u32, direct: bool = false },
    /// Invoke the function value in `callee` with the argument run.
    RCallValue: struct { dst: Reg, callee: Reg, args: Reg, n_args: u32 },
    /// Allocate an instance of `class` with its slots seeded, then run `ctor`
    /// with the instance prepended; `dst` receives the constructor's `this`.
    RNewInstance: struct { dst: Reg, class: ClassId, ctor: FuncId, args: Reg, n_args: u32 },
    GetFieldSlot: struct { dst: Reg, obj: Reg, slot: u32 },
    SetFieldSlot: struct { obj: Reg, slot: u32, value: Reg },
    /// Read a static, running its init unit on first touch.
    LoadStatic: struct { dst: Reg, static: StaticId },
    StoreStatic: struct { static: StaticId, value: Reg },
    /// The singleton of an object or companion, constructed on first use.
    LoadObject: struct { dst: Reg, class: ClassId },
    /// A closure over `func` capturing the registers' values.
    MakeClosure: struct { dst: Reg, func: FuncId, captures: []const Reg },
    /// A callable reference: a closure over `adapter` with `bound` as capture
    /// 0; equality and `name` answer from `target`.
    FunctionRef: struct { dst: Reg, adapter: FuncId, target: FuncId, bound: ?Reg },
    /// A property reference; `setter` is `NO_FUNC` for a read-only property.
    RPropertyRef: struct { dst: Reg, getter: FuncId, setter: u32 = NO_FUNC, bound: ?Reg, name: ConstId },
    /// The `KClass` of `class`.
    ClassLiteral: struct { dst: Reg, class: ClassId },
    /// The `KClass` of the run-time class of `src`.
    ClassOf: struct { dst: Reg, src: Reg },
    RInstanceOf: struct { dst: Reg, src: Reg, class: ClassId, nullable: bool },
    /// A failed cast throws `ClassCastException`, or gives null when `safe`.
    RCast: struct { dst: Reg, src: Reg, class: ClassId, nullable: bool, safe: bool },
    /// As `RInstanceOf`, against the reified type value in `ty`.
    InstanceOfDyn: struct { dst: Reg, src: Reg, ty: Reg, nullable: bool },
    CastDyn: struct { dst: Reg, src: Reg, ty: Reg, nullable: bool, safe: bool },
    ArrayGet: struct { dst: Reg, array: Reg, index: Reg },
    ArraySet: struct { array: Reg, index: Reg, value: Reg },
    /// An array of `class` holding the argument run.
    NewArray: struct { dst: Reg, class: ClassId, args: Reg, n_args: u32 },
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
        // A boxed payload: the registers sit behind the pointer.
        .pointer => |p| if (p.size == .one) visitPayloadRegs(payload.*, ctx, cb),
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
                } else if (@typeInfo(f.type) == .optional and @typeInfo(@typeInfo(f.type).optional.child) == .pointer and @typeInfo(@typeInfo(f.type).optional.child).pointer.size == .one) {
                    // An `extra` box may carry a register (`dispatch_receiver`).
                    if (@field(payload, f.name)) |boxed| visitPayloadRegs(boxed, ctx, cb);
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
            // A boxed payload keeps its `dst` behind the pointer.
            if (@typeInfo(P) == .pointer and @typeInfo(P).pointer.size == .one) {
                const C = @typeInfo(P).pointer.child;
                if (@typeInfo(C) == .@"struct" and @hasField(C, "dst")) {
                    if (@FieldType(C, "dst") == Reg) {
                        payload.*.dst = new_dst;
                        return true;
                    }
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
    /// The caught class, for a handler lowered from sema: it matches by
    /// `Module.classIsA` and `type_name` is not read. `NO_CLASS` otherwise.
    class_raw: u32 = NO_CLASS,
};

/// Absorption point for a labeled return targeting an inline function spliced into the
/// enclosing one: a `return@name` crossing a real frame unwinds as a `LabeledReturn`,
/// and the splice's frame catches it and resumes at `handler` with `value_reg`.
pub const LrAbsorb = struct {
    label: []const u8,
    handler: BlockId,
    value_reg: Reg,
};

test "the instruction union stays 64 bytes" {
    // The evaluator's dispatch loop reads instructions linearly, so a union
    // that outgrows a cache line costs every arm and not just the one that
    // grew it. `represent/field-slots` adds a slot claim to `GetField`; this
    // is the budget it has to fit in, and it does.
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Inst));
}
