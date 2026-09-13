//! `ir` — compact linear IR for the klio interpreter.
//!
//! Replaces the tree-walking interpreter with a flat instruction
//! stream. Each `Func` carries a `[]Block`; each `Block` carries a
//! `[]Inst` plus a `Terminator`. Operands are `Reg` indices, not
//! stack slots. The IR reuses `runtime.Value` so migration can
//! happen function-by-function without forking the runtime
//! representation.
//!
//! This file is the module root: it owns the `Module` registry struct and
//! re-exports the rest of the IR from `core/`. `ids.zig` holds the register,
//! block, func and class ids plus `TypeRef`; `inst.zig` the instruction and
//! terminator sets; `func.zig` functions, blocks and params; `class.zig`,
//! `consts.zig`, `names.zig` and `registry.zig` the class, constant, name and
//! import tables; `module_*.zig` the `Module` method groups; `tests_*.zig`
//! the module's tests.

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

const core_ids = @import("core/ids.zig");
const core_inst = @import("core/inst.zig");
const core_func = @import("core/func.zig");
const core_class = @import("core/class.zig");
const core_names = @import("core/names.zig");
const core_registry = @import("core/registry.zig");
const core_consts = @import("core/consts.zig");
const m_lookup = @import("core/module_lookup.zig");
const m_static = @import("core/module_static.zig");
const m_resolve_call = @import("core/module_resolve_call.zig");
const m_methods = @import("core/module_methods.zig");
const m_bare = @import("core/module_bare.zig");
const m_calls = @import("core/module_calls.zig");
const m_refs = @import("core/module_refs.zig");

pub const TypeRef = core_ids.TypeRef;
pub const Reg = core_ids.Reg;
pub const PendingCtxFnShape = core_ids.PendingCtxFnShape;
pub const ReceiverTowerEntry = core_ids.ReceiverTowerEntry;
pub const BlockId = core_ids.BlockId;
pub const FuncId = core_ids.FuncId;
pub const VirtNativeSite = core_ids.VirtNativeSite;
pub const ReifiedName = core_ids.ReifiedName;
pub const MethodSlotId = core_ids.MethodSlotId;
pub const ClassId = core_ids.ClassId;
pub const classTypeParamIdentity = core_ids.classTypeParamIdentity;
pub const ClassTypeParamIdentity = core_ids.ClassTypeParamIdentity;
pub const parseClassTypeParamIdentity = core_ids.parseClassTypeParamIdentity;
pub const ConstId = core_ids.ConstId;
pub const ScopeRename = core_ids.ScopeRename;
pub const ScopeClassRef = core_ids.ScopeClassRef;

/// One IR instruction. Drives the per-frame evaluator switch.
pub const snapshot_fast = @import("snapshot_fast.zig");

pub const Inst = core_inst.Inst;
pub const SpreadPart = core_inst.SpreadPart;
pub const BinOp = core_inst.BinOp;
pub const UnOp = core_inst.UnOp;
pub const visitInstRegs = core_inst.visitInstRegs;
pub const visitTerminatorRegs = core_inst.visitTerminatorRegs;
pub const setInstDst = core_inst.setInstDst;
pub const Terminator = core_inst.Terminator;
pub const SwitchArm = core_inst.SwitchArm;
pub const CatchHandler = core_inst.CatchHandler;
pub const LrAbsorb = core_inst.LrAbsorb;

pub const Block = core_func.Block;
pub const FuncKind = core_func.FuncKind;
pub const FAST_CALL_EXT_FLAG = core_func.FAST_CALL_EXT_FLAG;
pub const FAST_CALL_AMBIG_FLAG = core_func.FAST_CALL_AMBIG_FLAG;
pub const setSuppressDeprecationError = core_func.setSuppressDeprecationError;
pub const rankLowPriority = core_func.rankLowPriority;
pub const Func = core_func.Func;
pub const LEAF_MAX_REGS = core_func.LEAF_MAX_REGS;
pub const FRAME_FILL_WORDS = core_func.FRAME_FILL_WORDS;
pub const FRAME_FILL_MAX_REGS = core_func.FRAME_FILL_MAX_REGS;
pub const LEAF_MAX_INSTS = core_func.LEAF_MAX_INSTS;
pub const LEAF_MAX_BLOCKS = core_func.LEAF_MAX_BLOCKS;
pub const LEAF_MAX_STEPS = core_func.LEAF_MAX_STEPS;
pub const Param = core_func.Param;

pub const Class = core_class.Class;
pub const ClassIndexEntry = core_class.ClassIndexEntry;
pub const FuncIndexEntry = core_class.FuncIndexEntry;
pub const StrPair = core_class.StrPair;
const StrPairMap = core_class.StrPairMap;

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
    /// Funcs appended after the module went live (a side module whose
    /// earlier funcs are already executing), each in its own allocation:
    /// an append never moves a `Func` a running frame points at, whereas
    /// `funcs` reallocates on growth.
    late_funcs: std.ArrayList(*Func) = .empty,
    /// Route `appendFunc` to `late_funcs` from now on. Set when frames may
    /// hold `*const Func` into this module while it still grows.
    funcs_live: bool = false,
    /// True when any declaration in this module has a `context(...)`
    /// parameter clause. Gates the per-frame receiver push that feeds the
    /// context-resolution stack, so non-context programs pay nothing.
    has_context_decls: bool = false,
    /// Lowering-only scratch: a local contextual function's context
    /// parameters, stashed just before its body lowers through the shared
    /// lambda-body path and consumed there to emit the context-load
    /// prologue. Not serialized.
    pending_ctx: ?PendingCtx = null,
    /// The reference key the next lowered lambda receives (an adapted
    /// callable reference's wrapper); consumed at that lambda's finish.
    pending_ref_key: ?[]const u8 = null,
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
    /// A member extension property accessor's own receiver label (the
    /// property name) and its dispatch owner, stashed by the declaration
    /// lowering for the accessor builder: `this@<prop>` binds the
    /// receiver, and a local class declared in the body captures
    /// `this@<Owner>`. Not serialized.
    pending_accessor_this_label: ?[]const u8 = null,
    pending_accessor_dispatch_owner: ?[]const u8 = null,
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

    pub const init = m_lookup.init;
    pub const default = m_lookup.default;
    pub const ensureFuncBody = m_lookup.ensureFuncBody;
    pub const funcById = m_lookup.funcById;
    pub const funcByIdMut = m_lookup.funcByIdMut;
    pub const appendedFuncCount = m_lookup.appendedFuncCount;
    pub const appendFunc = m_lookup.appendFunc;
    pub const nextFuncId = m_lookup.nextFuncId;
    pub const registerMemberDecl = m_lookup.registerMemberDecl;
    pub const memberDecls = m_lookup.memberDecls;
    pub const MemberDeclGroup = m_lookup.MemberDeclGroup;
    pub const memberDeclGroups = m_lookup.memberDeclGroups;

    pub const MemberCandidate = m_static.MemberCandidate;
    pub const classIdIsOrExtendsDepth = m_static.classIdIsOrExtendsDepth;
    pub const classIdIsOrExtends = m_static.classIdIsOrExtends;
    pub const classHierarchyDeclaresMember = m_static.classHierarchyDeclaresMember;
    pub const classHierarchyDeclaresMemberDepth = m_static.classHierarchyDeclaresMemberDepth;
    pub const enclosingClassId = m_static.enclosingClassId;
    pub const lexicalChainContains = m_static.lexicalChainContains;
    pub const protectedAccessOwner = m_static.protectedAccessOwner;
    pub const collectMemberCandidates = m_static.collectMemberCandidates;
    pub const staticTypeHead = m_static.staticTypeHead;
    pub const staticTypeVar = m_static.staticTypeVar;
    pub const staticTypeArgsEqual = m_static.staticTypeArgsEqual;
    pub const StaticCompatibility = m_static.StaticCompatibility;
    pub const staticDeclTypeParam = m_static.staticDeclTypeParam;
    pub const staticFuncTypeParamBound = m_static.staticFuncTypeParamBound;
    pub const staticTypeContainsFuncParam = m_static.staticTypeContainsFuncParam;
    pub const staticGenericArgCompatibility = m_static.staticGenericArgCompatibility;

    /// The promotion proof, third derivation (the first two measured zero
    /// for lack of argument authority — the typing channels now supply it):
    /// a deferred member commits when every supplied argument is
    /// AUTHORITATIVE and member-compatible, and every same-name extension
    /// reachable from the receiver's chain is refuted by arity or by an
    /// argument. Conservative everywhere: an unjudgeable candidate keeps
    /// the deferral.
    pub threadlocal var mpp_why: []const u8 = "-";

    pub const erasedHeadRefutes = m_static.erasedHeadRefutes;
    pub const erasedHeadProves = m_static.erasedHeadProves;

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

    pub const recvRefuteOn = m_static.recvRefuteOn;
    pub const arrayVsCollectionParam = m_static.arrayVsCollectionParam;
    pub const StaticAliasHead = m_static.StaticAliasHead;
    pub const staticAliasHead = m_static.staticAliasHead;
    pub const staticBuiltinConcrete = m_static.staticBuiltinConcrete;
    pub const StaticBuiltinIdentity = m_static.StaticBuiltinIdentity;
    pub const staticBuiltinIdentity = m_static.staticBuiltinIdentity;
    pub const staticTypeClassId = m_static.staticTypeClassId;
    pub const staticTypesShareClassifier = m_static.staticTypesShareClassifier;
    pub const staticBoundProofComplete = m_static.staticBoundProofComplete;
    pub const staticBoundProofHead = m_static.staticBoundProofHead;
    pub const staticTypeDisproofComplete = m_static.staticTypeDisproofComplete;
    pub const staticReceiverCompatibility = m_static.staticReceiverCompatibility;
    pub const staticTypeCompatibility = m_static.staticTypeCompatibility;
    pub const staticAliasType = m_static.staticAliasType;
    pub const scopedTypeAliasFqn = m_static.scopedTypeAliasFqn;
    pub const resolveTypeAliasAt = m_static.resolveTypeAliasAt;
    pub const projectionType = m_static.projectionType;
    pub const staticTypeIsSubtypeInner = m_static.staticTypeIsSubtypeInner;
    pub const staticTypeIsSubtype = m_static.staticTypeIsSubtype;
    pub const staticBuiltinArgsNonRefuting = m_static.staticBuiltinArgsNonRefuting;
    pub const staticTypeIsSubtypeWithBounds = m_static.staticTypeIsSubtypeWithBounds;
    pub const isDeclaredTypeParam = m_static.isDeclaredTypeParam;
    pub const rawBoundNamesDeclaredParam = m_static.rawBoundNamesDeclaredParam;
    pub const typeRefIsDeclaredParam = m_static.typeRefIsDeclaredParam;
    pub const staticTypeProofComplete = m_static.staticTypeProofComplete;
    pub const bindReceiverTypeParams = m_static.bindReceiverTypeParams;
    pub const staticGenericReceiverApplicable = m_static.staticGenericReceiverApplicable;
    pub const staticGenericReceiverCouldApply = m_static.staticGenericReceiverCouldApply;
    pub const staticGenericReceiverApplicableMode = m_static.staticGenericReceiverApplicableMode;
    pub const staticArgCompatibility = m_static.staticArgCompatibility;
    pub const lambdaRefuteOn = m_static.lambdaRefuteOn;
    pub const headIsFunctionSpelling = m_static.headIsFunctionSpelling;
    pub const bargTraceEnv = m_static.bargTraceEnv;
    pub const dropTraceEnv = m_static.dropTraceEnv;
    pub const trailingGapDefaulted = m_static.trailingGapDefaulted;
    pub const nonCallableBuiltinHead = m_static.nonCallableBuiltinHead;
    pub const staticMemberArgsCompatibility = m_static.staticMemberArgsCompatibility;
    pub const extensionKeyGreater = m_static.extensionKeyGreater;
    pub const extensionKeyEquivalent = m_static.extensionKeyEquivalent;
    pub const functionParamArgsAgree = m_static.functionParamArgsAgree;
    pub const tiedLambdaParamRep = m_static.tiedLambdaParamRep;
    pub const staticReceiverCouldAccept = m_static.staticReceiverCouldAccept;
    pub const memberExtensionOwnerIsObject = m_static.memberExtensionOwnerIsObject;
    pub const scopedClassId = m_static.scopedClassId;
    pub const dispatchOwnerInChain = m_static.dispatchOwnerInChain;
    pub const lexicalOwnerChainContains = m_static.lexicalOwnerChainContains;
    pub const lexicalOwnerCompanionMatches = m_static.lexicalOwnerCompanionMatches;
    pub const memberDispatchOwnerInScope = m_static.memberDispatchOwnerInScope;
    pub const memberExtensionScopeTier = m_static.memberExtensionScopeTier;
    pub const objectMemberExtensionInScope = m_static.objectMemberExtensionInScope;
    pub const memberExtensionInScope = m_static.memberExtensionInScope;
    pub const genericReceiverSuppliesLambdaReceiver = m_static.genericReceiverSuppliesLambdaReceiver;

    pub const resolveExtensionCall = m_resolve_call.resolveExtensionCall;
    pub const resolveMemberCall = m_resolve_call.resolveMemberCall;
    pub const dispatchForTarget = m_resolve_call.dispatchForTarget;
    pub const methodIsFinal = m_resolve_call.methodIsFinal;
    pub const internalVisibleFrom = m_resolve_call.internalVisibleFrom;
    pub const rebuildMemberNameIndex = m_resolve_call.rebuildMemberNameIndex;

    pub const methodDispatchKey = m_methods.methodDispatchKey;
    pub const methodSlotTarget = m_methods.methodSlotTarget;
    pub const MethodDispatchEntry = m_methods.MethodDispatchEntry;
    pub const methodDispatchEntries = m_methods.methodDispatchEntries;
    pub const registerMethodSlotTarget = m_methods.registerMethodSlotTarget;
    pub const TypeBinding = m_methods.TypeBinding;
    pub const bindingType = m_methods.bindingType;
    pub const bindingIsExplicit = m_methods.bindingIsExplicit;
    pub const widenBinding = m_methods.widenBinding;
    pub const substituteBoundType = m_methods.substituteBoundType;
    pub const substituteType = m_methods.substituteType;
    pub const callTypeParam = m_methods.callTypeParam;
    pub const callTypeRefParam = m_methods.callTypeRefParam;
    pub const projectTypeToClass = m_methods.projectTypeToClass;
    pub const bindCallType = m_methods.bindCallType;
    pub const returnTypeBindingsComplete = m_methods.returnTypeBindingsComplete;
    pub const typeContainsBoundParam = m_methods.typeContainsBoundParam;
    pub const declaredTypeParamBounds = m_methods.declaredTypeParamBounds;
    pub const typeMentionsAnyParamName = m_methods.typeMentionsAnyParamName;
    pub const instantiatedCallReturnType = m_methods.instantiatedCallReturnType;
    pub const SolvedBindings = m_methods.SolvedBindings;
    pub const solveCallBindings = m_methods.solveCallBindings;
    pub const instantiatedCallReturnTypeScoped = m_methods.instantiatedCallReturnTypeScoped;
    pub const instantiatedTypeFromReceiverImpl = m_methods.instantiatedTypeFromReceiverImpl;
    pub const instantiatedTypeFromReceiver = m_methods.instantiatedTypeFromReceiver;
    pub const instantiatedTypeFromReceiverPartial = m_methods.instantiatedTypeFromReceiverPartial;
    pub const instantiatedDeclarationType = m_methods.instantiatedDeclarationType;
    pub const ancestorBindings = m_methods.ancestorBindings;
    pub const funcTypeParamIndex = m_methods.funcTypeParamIndex;
    pub const overridesTraceOn = m_methods.overridesTraceOn;
    pub const classIdDeclaredIn = m_methods.classIdDeclaredIn;
    pub const overrideTypeClassId = m_methods.overrideTypeClassId;
    pub const overrideQualifiedPath = m_methods.overrideQualifiedPath;
    pub const overrideArgs = m_methods.overrideArgs;
    pub const overrideTypeEql = m_methods.overrideTypeEql;
    pub const overridesSlot = m_methods.overridesSlot;
    pub const mergeInheritedMethod = m_methods.mergeInheritedMethod;
    pub const unifyRedeclaredSlots = m_methods.unifyRedeclaredSlots;
    pub const preferredMethodSlotTarget = m_methods.preferredMethodSlotTarget;
    pub const linkMethodClass = m_methods.linkMethodClass;
    pub const linkMethodSlots = m_methods.linkMethodSlots;

    pub const funcCount = m_lookup.funcCount;
    pub const deinit = m_lookup.deinit;
    pub const cloneForExtend = m_lookup.cloneForExtend;
    pub const classId = m_lookup.classId;
    pub const uniqueClassIdBySimpleName = m_lookup.uniqueClassIdBySimpleName;
    pub const topUpUniqueSimpleCache = m_lookup.topUpUniqueSimpleCache;
    pub const uniqueSimpleInsert = m_lookup.uniqueSimpleInsert;
    pub const classNameCandidates = m_lookup.classNameCandidates;
    pub const topUpClassNameCache = m_lookup.topUpClassNameCache;
    pub const buildClassIdMap = m_lookup.buildClassIdMap;
    pub const installEagerCalls = m_lookup.installEagerCalls;
    pub const eagerTypeOf = m_lookup.eagerTypeOf;
    pub const eagerParamShapeOf = m_lookup.eagerParamShapeOf;
    pub const ExtCouldApplyWhy = m_lookup.ExtCouldApplyWhy;
    pub const ExtArity = m_lookup.ExtArity;
    pub const extCouldApply = m_lookup.extCouldApply;
    pub const extCouldApplyWhy = m_lookup.extCouldApplyWhy;
    pub const mergeExtArity = m_lookup.mergeExtArity;
    pub const rebuildExtIndex = m_lookup.rebuildExtIndex;
    pub const eagerRecvHeadOf = m_lookup.eagerRecvHeadOf;
    pub const eagerExternCallTarget = m_lookup.eagerExternCallTarget;
    pub const eagerCallTarget = m_lookup.eagerCallTarget;
    pub const recordFuncDeclSpan = m_lookup.recordFuncDeclSpan;
    pub const funcByDeclSpan = m_lookup.funcByDeclSpan;
    pub const classDirectChild = m_lookup.classDirectChild;
    pub const classIdNestedIn = m_lookup.classIdNestedIn;
    pub const classIdByQualifiedSuffix = m_lookup.classIdByQualifiedSuffix;
    pub const aliasTargetClassHead = m_lookup.aliasTargetClassHead;
    pub const classIdIndexed = m_lookup.classIdIndexed;
    pub const rebuildFuncNameIndex = m_lookup.rebuildFuncNameIndex;
    pub const funcsBySimpleName = m_lookup.funcsBySimpleName;
    pub const funcId = m_lookup.funcId;
    pub const funcIdForBareCall = m_lookup.funcIdForBareCall;
    pub const funcIdForSpreadCall = m_lookup.funcIdForSpreadCall;
    pub const hasFuncNamed = m_lookup.hasFuncNamed;
    pub const funcIdByFqn = m_lookup.funcIdByFqn;
    pub const packageHeadDeclared = m_lookup.packageHeadDeclared;
    pub const topUpPkgHeads = m_lookup.topUpPkgHeads;
    pub const packageOfFile = m_lookup.packageOfFile;
    pub const importAliasIn = m_lookup.importAliasIn;
    pub const importAliasPathsIn = m_lookup.importAliasPathsIn;

    pub const BareCallCandidateIterator = m_bare.BareCallCandidateIterator;
    pub const bareCallCandidateIterator = m_bare.bareCallCandidateIterator;
    pub const renamedImportDenotesFunc = m_bare.renamedImportDenotesFunc;
    pub const bareCallCandidates = m_bare.bareCallCandidates;
    pub const hasBareCallCandidate = m_bare.hasBareCallCandidate;
    pub const hasNonExtensionBareCallCandidate = m_bare.hasNonExtensionBareCallCandidate;
    pub const importWildcardIn = m_bare.importWildcardIn;
    pub const default_import_packages = m_bare.default_import_packages;
    pub const isDefaultImportPackage = m_bare.isDefaultImportPackage;
    pub const last_in_scope_tier = m_bare.last_in_scope_tier;
    pub const other_package_tier = m_bare.other_package_tier;
    pub const bareCallTier = m_bare.bareCallTier;
    pub const classIdExactImport = m_bare.classIdExactImport;
    pub const scopeTier = m_bare.scopeTier;
    pub const funcUserArity = m_bare.funcUserArity;
    pub const funcHasImplicitThis = m_bare.funcHasImplicitThis;
    pub const candidateHasImplicitThis = m_bare.candidateHasImplicitThis;
    pub const sigViewForApplicability = m_bare.sigViewForApplicability;
    pub const ResolveDeferReason = m_bare.ResolveDeferReason;
    pub const BareCallResolution = m_bare.BareCallResolution;
    pub const stubDeclArity = m_bare.stubDeclArity;
    pub const bareCallTierOf = m_bare.bareCallTierOf;
    pub const SigView = m_bare.SigView;
    pub const sigViewOf = m_bare.sigViewOf;
    pub const sameUserSig = m_bare.sameUserSig;
    pub const anyParamVararg = m_bare.anyParamVararg;
    pub const positionalDefaultsUsed = m_bare.positionalDefaultsUsed;
    pub const omittedPositionHasDefault = m_bare.omittedPositionHasDefault;
    pub const typeNamesFunInterface = m_bare.typeNamesFunInterface;
    pub const tlShapeMatches = m_bare.tlShapeMatches;
    pub const resolveBareCallIndexed = m_bare.resolveBareCallIndexed;

    pub const Confidence = m_calls.Confidence;
    pub const EmitForm = m_calls.EmitForm;
    pub const Resolution = m_calls.Resolution;
    pub const ResolveCtx = m_calls.ResolveCtx;
    pub const funcIsInline = m_calls.funcIsInline;
    pub const isNonExtFid = m_calls.isNonExtFid;
    pub const memberExtOutOfScope = m_calls.memberExtOutOfScope;
    pub const evidenceSubtypeCb = m_calls.evidenceSubtypeCb;
    pub const ownerDeclaresMember = m_calls.ownerDeclaresMember;
    pub const extReceiverPlausible = m_calls.extReceiverPlausible;
    pub const declSigScore = m_calls.declSigScore;
    pub const declSigCompatible = m_calls.declSigCompatible;
    pub const ApplicableBarePick = m_calls.ApplicableBarePick;
    pub const bareScoreGreater = m_calls.bareScoreGreater;
    pub const bareScoreEqual = m_calls.bareScoreEqual;
    pub const staticBareArgsCompatibility = m_calls.staticBareArgsCompatibility;
    pub const applicableBarePick = m_calls.applicableBarePick;
    pub const candidateSet = m_calls.candidateSet;
    pub const bccWhyOn = m_calls.bccWhyOn;
    pub const boundedCallCandidates = m_calls.boundedCallCandidates;
    pub const boundedSpreadCandidates = m_calls.boundedSpreadCandidates;
    pub const declarationKind = m_calls.declarationKind;
    pub const declarationHasVararg = m_calls.declarationHasVararg;
    pub const globalArityCanBind = m_calls.globalArityCanBind;
    pub const lowestVisibleGlobalTier = m_calls.lowestVisibleGlobalTier;
    pub const lowestVisibleTier = m_calls.lowestVisibleTier;
    pub const resolveCall = m_calls.resolveCall;
    pub const resolveCallCandidates = m_calls.resolveCallCandidates;
    pub const calleeIsTailrec = m_calls.calleeIsTailrec;
    pub const knownReceiverApplicability = m_calls.knownReceiverApplicability;
    pub const knownReceiverCallableApplicable = m_calls.knownReceiverCallableApplicable;
    pub const knownReceiverMemberApplicable = m_calls.knownReceiverMemberApplicable;
    pub const towerPickProven = m_calls.towerPickProven;
    pub const emitFormFor = m_calls.emitFormFor;

    pub const resolveBareRefIndexed = m_refs.resolveBareRefIndexed;
    pub const resolveBareRefExpected = m_refs.resolveBareRefExpected;
    pub const bareRefTier = m_refs.bareRefTier;
    pub const classRefTier = m_refs.classRefTier;
    pub const topLevelPropRefTier = m_refs.topLevelPropRefTier;
    pub const topLevelPropTypeRef = m_refs.topLevelPropTypeRef;
    pub const topLevelPropTypeHeadTiered = m_refs.topLevelPropTypeHeadTiered;
    pub const topLevelPropHeadFor = m_refs.topLevelPropHeadFor;
    pub const topLevelPropTypeHead = m_refs.topLevelPropTypeHead;
    pub const resolveCallableExtensionProperty = m_refs.resolveCallableExtensionProperty;
    pub const topLevelConstLiteral = m_refs.topLevelConstLiteral;
    pub const topLevelPropFqn = m_refs.topLevelPropFqn;

    pub const addClass = m_lookup.addClass;
    pub const classIndexEntryByName = m_lookup.classIndexEntryByName;
    pub const class_id_ambiguous = m_lookup.class_id_ambiguous;
    pub const SimpleNameInfo = m_lookup.SimpleNameInfo;
    pub const classFqnById = m_lookup.classFqnById;
    pub const cid_memo_slots = m_lookup.cid_memo_slots;
    pub const classIdByStaticFqn = m_lookup.classIdByStaticFqn;
    pub const classIdByFqn = m_lookup.classIdByFqn;
    pub const classFqnCacheLive = m_lookup.classFqnCacheLive;
    pub const topUpClassFqnCache = m_lookup.topUpClassFqnCache;
    pub const fixupStubClaimCaches = m_lookup.fixupStubClaimCaches;
    pub const classIsOrExtends = m_lookup.classIsOrExtends;
    pub const reserveClass = m_lookup.reserveClass;
    pub const reserveClassFqn = m_lookup.reserveClassFqn;
    pub const internConst = m_lookup.internConst;
    pub const topUpConstDedup = m_lookup.topUpConstDedup;
};

pub const isAliasName = core_names.isAliasName;

pub const packageOfFqn = core_names.packageOfFqn;
pub const shippedFqnHead = core_names.shippedFqnHead;

pub const ModuleRegistry = core_registry.ModuleRegistry;

pub const Const = core_consts.Const;

const testing = std.testing;

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(@import("core/class.zig"));
    testing.refAllDecls(@import("core/consts.zig"));
    testing.refAllDecls(@import("core/func.zig"));
    testing.refAllDecls(@import("core/ids.zig"));
    testing.refAllDecls(@import("core/inst.zig"));
    testing.refAllDecls(@import("core/module_bare.zig"));
    testing.refAllDecls(@import("core/module_calls.zig"));
    testing.refAllDecls(@import("core/module_lookup.zig"));
    testing.refAllDecls(@import("core/module_methods.zig"));
    testing.refAllDecls(@import("core/module_refs.zig"));
    testing.refAllDecls(@import("core/module_resolve_call.zig"));
    testing.refAllDecls(@import("core/module_static.zig"));
    testing.refAllDecls(@import("core/names.zig"));
    testing.refAllDecls(@import("core/registry.zig"));
    testing.refAllDecls(@import("core/tests_extensions.zig"));
    testing.refAllDecls(@import("core/tests_members.zig"));
    testing.refAllDecls(@import("core/tests_resolve.zig"));
    testing.refAllDecls(@import("core/tests_support.zig"));
}
