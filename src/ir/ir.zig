//! Compact linear IR for the klio interpreter: a flat instruction stream instead of a
//! tree walk. Each `Func` carries a `[]Block`, each `Block` a `[]Inst` plus a
//! `Terminator`, and operands are `Reg` indices rather than stack slots. The IR reuses
//! `runtime.Value` directly.
//!
//! This file is the module root: it owns the `Module` registry struct and re-exports
//! the rest of the IR from `core/`.

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

/// The eager pipeline's hand-off: the driver computes the per-call resolution before
/// the module exists and parks it here; the next module on this thread adopts it.
pub threadlocal var pending_eager_calls: ?std.AutoHashMap(span.Span, span.Span) = null;
/// Companion for picks whose declaration came from a prebuilt image: a FuncId, not a span.
pub threadlocal var pending_eager_call_fids: ?std.AutoHashMap(span.Span, u32) = null;
/// Per-expression static type heads from typeck: `Span(expr) -> {head, nullable}`.
pub threadlocal var pending_eager_types: ?std.AutoHashMap(span.Span, EagerTypeHead) = null;

pub const EagerTypeHead = struct { name: []const u8, nullable: bool };
/// Receiver-lambda channel: body-block span -> receiver class head.
pub threadlocal var pending_eager_recv_heads: ?std.AutoHashMap(span.Span, []const u8) = null;
/// Fn-typed lambda-param shapes: param ident span -> {has_receiver, arity}.
pub threadlocal var pending_eager_param_shapes: ?std.AutoHashMap(span.Span, EagerParamShape) = null;

pub const EagerParamShape = struct { has_receiver: bool, arity: u16 };

/// Context parameters of a local contextual function, threaded into its body lowering.
pub const PendingCtx = struct {
    params: []const ast.ContextParam,
    type_params: []const ast.TypeParam,
};

/// A local `fun`'s name plus the mangled overload cell a bare self-reference calls through.
pub const SelfLocalFn = struct {
    name: []const u8,
    mangled: []const u8,
};

pub const RecvHeadKV = struct { name: []const u8, head: ?[]const u8 };

/// One type-parameter bound ref with type arguments; owned by the module allocator.
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
    /// A `Module` may be written only during single-threaded setup, before any interpreter
    /// thread runs; the sole writer is the class-id overlay `linkProgramForms` builds at `Vm`
    /// init. Mutating one after execution starts needs its own synchronisation.
    pub const objref_immutable = true;

    /// Direct-mapped pointer-identity memo for `classIdByFqn` probes keyed by a STATIC
    /// string. Keys claim a slot by pointer CAS from 0; the value (0 = unset, 1 = no class,
    /// else ClassId + 2) is release-stored after the claim as the validity gate. The key
    /// pointer's content must never change, so a stack-composed FQN must not use this.
    cid_memo_keys: [cid_memo_slots]std.atomic.Value(usize) = @splat(std.atomic.Value(usize).init(0)),
    cid_memo_vals: [cid_memo_slots]std.atomic.Value(u64) = @splat(std.atomic.Value(u64).init(0)),

    funcs: std.ArrayList(Func) = .empty,
    /// Funcs appended after the module went live, each in its own allocation: an append
    /// never moves a `Func` a running frame points at, whereas `funcs` reallocates.
    late_funcs: std.ArrayList(*Func) = .empty,
    /// Route `appendFunc` to `late_funcs`: frames may hold `*const Func` while it grows.
    funcs_live: bool = false,
    /// Some declaration has a `context(...)` clause; gates the per-frame context-receiver push.
    has_context_decls: bool = false,
    /// Lowering scratch: a local contextual function's context parameters for its body prologue.
    pending_ctx: ?PendingCtx = null,
    /// Reference key for the next lowered lambda (an adapted callable reference's wrapper).
    pending_ref_key: ?[]const u8 = null,
    /// Lowering scratch: declared types of a synthesized parameter thunk's params, by position.
    pending_param_types: ?[]const ?ast.TypeRef = null,
    /// Expected type of the next parameter-thunk expression, instantiated by the supertype args.
    pending_thunk_expected: ?ast.TypeRef = null,
    /// A member extension property accessor's receiver label (the property name): `this@<prop>`
    /// binds the receiver, and a local class in the body captures `this@<Owner>`.
    pending_accessor_this_label: ?[]const u8 = null,
    pending_accessor_dispatch_owner: ?[]const u8 = null,
    /// Lowering scratch: callable arity mask of the owner class's members. A name that is only
    /// ever a property carries mask 0, so a bare call of it is not read as a companion call.
    pending_own_member_arity: ?*const std.StringHashMap(u64) = null,
    /// Implicit label of the argument lambda about to lower. Its body binds `this@<label>` so
    /// a reference from a nested scope reaches THAT receiver, not the innermost `this`.
    pending_lambda_this_label: ?[]const u8 = null,
    /// Receiver type in scope at the lambda body about to lower, carried in as `enclosing_recv_ty`.
    pending_lambda_enclosing_recv: ?[]const u8 = null,
    /// Full implicit receiver tower for the lambda body about to lower, innermost first.
    pending_lambda_receiver_tower: ?[]const ReceiverTowerEntry = null,
    /// Structural type of `pending_lambda_own_recv`, transferred into the body's builder.
    pending_lambda_own_recv_type: ?TypeRef = null,
    /// Declared extension receiver of the local function whose body is about to lower, so its
    /// bare calls resolve exactly as in a top-level extension body.
    pending_lambda_own_recv: ?[]const u8 = null,
    /// The pending body belongs to a LOCAL `fun` with a block body: fall-through returns Unit,
    /// never the tail statement's value. A lambda literal yields its last expression instead.
    pending_lambda_fn_block_body: bool = false,
    /// The pending lambda literal binds a `(...) -> Unit` parameter: its tail expression runs
    /// for effect and the lambda returns Unit. Consumed on entry so it never leaks inward.
    pending_lambda_unit: bool = false,
    /// Non-reified type-parameter names in scope, so an `x as T` inside the lambda stays erased.
    pending_lambda_type_params: ?[]const []const u8 = null,
    /// The enclosing splice's reified type-parameter substitutions, carried into a lambda body
    /// lowered inside it; the runtime's bound class value cannot carry nullability.
    pending_lambda_reified_names: ?[]const ReifiedName = null,
    /// Effective upper bounds parallel to the type-parameter names carried into the body.
    pending_lambda_type_param_bounds: ?[]const ModuleRegistry.TypeParamBound = null,
    /// Full bound refs with type arguments for the pending body; the lambda body takes ownership.
    pending_lambda_type_param_bound_refs: ?[]PendingBoundRef = null,
    /// Contextual fn-type parameters of the enclosing builder, so a nested implicit call splits contexts.
    pending_lambda_ctx_fn_shapes: ?[]PendingCtxFnShape = null,
    /// Receiver-lambda param names to the enclosing builder's declared receiver heads, so a
    /// captured receiver-fn param invoked bare re-selects by its head. Slices are borrowed.
    pending_lambda_recv_heads: ?[]RecvHeadKV = null,
    /// The caller's solved fn-type-parameter bindings for an inline splice; tys owned by the
    /// lowering allocator.
    pending_splice_solved: ?[]Module.TypeBinding = null,
    /// Instantiated value-parameter types for the pending lambda literal; the body takes ownership.
    pending_lambda_param_types: ?[]TypeRef = null,
    /// Context parameters of the anonymous function lowered next, bound from the context stack.
    pending_lambda_ctx_params: ?[]const ast.ContextParam = null,
    /// The local `fun` about to lower: its name and mangled overload cell. A bare self-reference
    /// calls through the cell, since the plain-name slot is shared with later same-named siblings.
    pending_lambda_self_fn: ?SelfLocalFn = null,
    /// The next lambda body's declared shape is KNOWN to take no receiver, so its bare calls
    /// may consult the enclosing receiver tier. A merely untyped receiver must not.
    pending_lambda_no_receiver: bool = false,
    /// Enclosing locals with definite non-callable evidence, so a bare call is not the captured value.
    pending_lambda_nonfn_locals: ?std.StringHashMap(void) = null,
    /// Vararg parameter names of the local `fun` about to lower: inside the body the static
    /// type is the materialized array, not the annotated element. Borrowed from the AST.
    pending_lambda_vararg_params: ?[]const []const u8 = null,
    /// Declared type heads of enclosing locals the lambda captures, preserving the compile-time type.
    pending_lambda_local_decl_types: ?PendingLocalDeclTypes = null,
    /// Lazy IR: byte section holding deferred functions' `blocks`, each self-contained and
    /// decoded on first execution. Borrows the image buffer; empty unless image-loaded.
    deferred_func_section: []const u8 = &.{},
    /// Process-lifetime allocator a decoded `blocks` slice must persist in.
    deferred_func_arena: Allocator = undefined,
    /// Injected decoder (`image.decodeFuncBlocks`), null until installed.
    deferred_func_decode: ?*const fn (Allocator, []const u8, u32) ?[]Block = null,
    /// Lazy IR func headers: per-func sections plus offsets (`id -> offset+1`, 0 = absent),
    /// decoded on first `funcById` and memoised in `func_cache`. Empty unless image-loaded.
    func_header_section: []const u8 = &.{},
    func_header_offsets: []const u32 = &.{},
    func_header_decode: ?*const fn (Allocator, []const u8, u32) ?Func = null,
    func_cache: []?*Func = &.{},
    func_header_lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Distinct first FQN segment of every lazy base func. Borrowed from the image.
    func_fqn_heads: []const []const u8 = &.{},
    /// Ids of the lazy base's bodyless funcs. Borrowed from the image.
    bodyless_func_ids: []const u32 = &.{},
    classes: std.ArrayList(Class) = .empty,
    consts: std.ArrayList(Const) = .empty,
    /// Top-level (file-scope) function ids, in declaration order.
    top_level: std.ArrayList(FuncId) = .empty,
    /// Top-level class declarations by simple name, so `Foo(args)` lowers to `NewInstance`.
    class_index: std.ArrayList(ClassIndexEntry) = .empty,
    /// Simple name to first `ClassId`, an O(1) overlay on `class_index`'s scan built at the link
    /// step; null until then. First-entry-wins matches the scan's duplicate-name behavior.
    class_id_map: ?std.StringHashMap(ClassId) = null,
    /// FQN to `ClassId` overlay. A duplicated FQN maps to `class_id_ambiguous` so the lookup
    /// returns null. Built with `class_id_map`; null until then.
    class_fqn_map: ?std.StringHashMap(ClassId) = null,
    /// Allocator for the lowering-phase lookup caches below; null disables them, so lookups scan.
    lookup_cache_gpa: ?Allocator = null,
    /// Lowering-phase package-head set: every dot-aligned FQN prefix of every declared func and
    /// class. Prefixes are only ever added, so the set never goes stale-positive.
    pkg_head_cache: std.StringHashMapUnmanaged(void) = .empty,
    pkg_head_funcs_n: usize = 0,
    pkg_head_classes_n: usize = 0,
    pkg_head_heads_done: bool = false,
    pkg_head_cache_dead: bool = false,
    /// Lowering-phase simple name to same-name `ClassId`s in `class_index` order, which is stable.
    class_name_cache: std.StringHashMapUnmanaged(std.ArrayList(ClassId)) = .empty,
    class_name_cache_n: usize = 0,
    /// Lowering-phase FQN to `ClassId` (or `class_id_ambiguous`). An unpatchable stub-claim
    /// rewrite kills the cache for the rest of the build rather than diverge from the scan.
    class_fqn_cache: std.StringHashMapUnmanaged(ClassId) = .empty,
    class_fqn_cache_n: usize = 0,
    class_fqn_cache_dead: bool = false,
    /// Lowering-phase simple name to what the per-name class scans would find: the `ClassId`
    /// `uniqueClassIdBySimpleName` returns (or `class_id_ambiguous`), plus whether any class
    /// under it is outside `kotlin`. Entries fold many classes, so a stub claim resets it.
    unique_simple_cache: std.StringHashMapUnmanaged(SimpleNameInfo) = .empty,
    unique_simple_cache_n: usize = 0,
    /// `internConst` dedup: const hash to the first `ConstId` with it; a collision falls back to a scan.
    const_dedup: std.AutoHashMapUnmanaged(u64, ConstId) = .empty,
    const_dedup_n: usize = 0,
    /// The classifier nesting tree, derived once from FQNs: each class's lexical parent (null
    /// for top-level) and, per parent, the children keyed by their last FQN segment.
    class_parent: ?std.AutoHashMap(ClassId, ClassId) = null,
    /// Each lowered declaration's AST name-span to its FuncId, composed with typeck's call records.
    func_by_decl_span: ?std.AutoHashMap(span.Span, FuncId) = null,
    /// A per-anon-site image clone that runtime-synthesized members lower into. Decl-span
    /// reservations are off on it: synthesized thunks share their property ident's span.
    anon_side: bool = false,
    /// The eager pipeline's per-call resolution, `Span(callee) -> Span(decl)`; absent spans go lazy.
    eager_calls: ?std.AutoHashMap(span.Span, span.Span) = null,
    eager_call_fids: ?std.AutoHashMap(span.Span, u32) = null,
    /// Typeck's per-expression static type heads.
    eager_types: ?std.AutoHashMap(span.Span, EagerTypeHead) = null,
    eager_recv_heads: ?std.AutoHashMap(span.Span, []const u8) = null,
    /// Extension-candidate index: receiver head to the extension names declared on it, plus the
    /// generic-receiver names that apply to every head. Rebuilt lazily as declarations grow.
    ext_names_by_recv_head: ?std.StringHashMap(std.StringHashMap(ExtArity)) = null,
    generic_ext_names: ?std.StringHashMap(ExtArity) = null,
    ext_index_decl_count: usize = 0,
    eager_param_shapes: ?std.AutoHashMap(span.Span, EagerParamShape) = null,
    class_children: ?std.AutoHashMap(ClassId, std.StringHashMap(ClassId)) = null,
    /// Top-level function declarations by simple name; a matching Path callee lowers to `Inst.Call`.
    func_index: std.ArrayList(FuncIndexEntry) = .empty,
    /// Simple-name index over `func_index` for O(1) name-to-FuncIds in declaration order.
    func_name_index: std.StringHashMap(std.ArrayList(FuncId)),
    package: ?[]const u8 = null,
    /// Top-level function names declared `tailrec`, populated before bodies lower so a caller
    /// can emit `TailCallFunc` into a tailrec function whose body is not lowered yet.
    tailrec_fn_names: std.ArrayList([]const u8) = .empty,
    /// Per-class and per-function side tables the build produces and the Vm reads at dispatch.
    registry: ModuleRegistry,
    /// Declared user-parameter count (excluding an implicit extension `this`) per top-level `FuncId`.
    decl_user_params: std.AutoHashMap(u32, u32),
    /// Declared user parameters' `(required, total, has_vararg)` per top-level `FuncId`.
    decl_user_arity: std.AutoHashMap(u32, DeclArity),
    /// Declared user parameters' full structural types per top-level `FuncId`, recorded at header
    /// registration so forward references can be proved. Slices owned by the module allocator.
    decl_user_sig: std.AutoHashMap(u32, []TypeRef),
    /// Source span of each top-level function declaration, for resolution diagnostics.
    decl_span: std.AutoHashMap(u32, Span),
    /// Top-level `FuncId`s whose declaration carries a source body: separates a real function
    /// from a bodyless `expect` or header stub before phase 2 places the bodies.
    decl_ast_body: std.AutoHashMap(u32, void),
    /// Unified per-`FuncId` declaration record for receiver-type membership queries and exact
    /// static binds. Top-level funcs fill at header registration, members at class-body lowering.
    decl_sigs: std.AutoHashMap(u32, DeclSig),
    /// Complete owner-scoped member overload sets, keyed `(declaring-class FQN, source name)`,
    /// retaining every declaration in source order. Image-loaded modules rebuild it from their
    /// declaration records. The authoritative candidate source for member resolution.
    member_name_index: StrPairMap(std.ArrayList(FuncId)),
    /// Link-time virtual dispatch table. Keys pack a runtime `ClassId` in the high word and a
    /// declaration-rooted `MethodSlotId` in the low word; method names never enter dispatch.
    method_dispatch: std.AutoHashMap(u64, FuncId),
    /// Ambiguous bare calls the symbol index refused to pick among, surfaced by the build
    /// driver before the program runs. Name and FQN slices borrow from the module's own data.
    resolve_diags: std.ArrayList(ResolveDiag) = .empty,

    /// `(required, total, has_vararg)` for a top-level function's declared user parameters.
    /// `has_vararg` is true for a vararg at ANY position, which Kotlin allows.
    pub const DeclArity = struct {
        required: u32,
        total: u32,
        has_vararg: bool,
    };

    /// One declaration's resolved signature record (see `decl_sigs`).
    pub const DeclSig = struct {
        /// Enclosing class for an instance method or member extension, null for top-level.
        enclosing_class: ?ClassId = null,
        /// Declared extension receiver type (structural), else null.
        receiver_ty: ?TypeRef = null,
        arity: DeclArity,
        /// Declared user-parameter structural types, excluding any implicit receiver slot.
        sig: []const TypeRef = &.{},
        kind: FuncKind = .plain,
        visibility: ast.Visibility = .Public,
        is_inline: bool = false,
        is_suspend: bool = false,
        has_body: bool = false,
        /// Exact fully-qualified host ABI symbol. A bodyless declaration with this identity uses
        /// the ordinary FuncId call ABI; link finalization attaches the host function once.
        host_symbol: ?[]const u8 = null,
    };

    pub const MemberDispatch = enum {
        /// The declaration cannot be overridden at this call site.
        direct,
        /// Resolved, but the runtime receiver selects an override: a numeric method slot in the VM.
        virtual,
        /// Static evidence did not identify one declaration.
        deferred,
    };

    pub const MemberResolution = struct {
        /// Unique declaration identity when the candidate set proves one. A deferred result may
        /// carry it as argument expected-type metadata while withholding a dispatch commitment.
        target: ?FuncId = null,
        dispatch: MemberDispatch = .deferred,
        /// At least one visible member accepts the supplied call shape. Stays true for an
        /// ambiguity, where `target` is null but the member still shadows a package function.
        applicable: bool = false,
    };

    pub const MemberResolveCtx = struct {
        /// Source file containing the call; with the declaration span it decides `internal`.
        caller_file: ?FileId = null,
        /// Innermost lexical class containing the call. Visibility walks its enclosing chain.
        lexical_owner: ?ClassId = null,
        /// Restrict the query to private declarations, for bare own-member calls.
        private_only: bool = false,
        actual_type_param_bounds: []const ModuleRegistry.TypeParamBound = &.{},
        receiver_type: ?TypeRef = null,
    };

    pub const ExtensionResolveCtx = struct {
        /// The caller's member resolution refuted every member candidate, so kotlinc's answer can
        /// only be an extension: a sole receiver-proven survivor commits even with unknown args.
        member_refuted: bool = false,
        caller_file: FileId,
        caller_package: []const u8,
        /// Implicit receiver heads that can supply a member extension's dispatch owner, innermost first.
        implicit_dispatch_owners: []const []const u8 = &.{},
        /// Lexically enclosing class or object, kept apart from an inner receiver-lambda head.
        lexical_owner: ?[]const u8 = null,
        /// Source-visible alias used for member-extension shadow checks.
        call_name: ?[]const u8 = null,
        /// Bounds of type parameters owned by the enclosing declaration, so a receiver such as
        /// `Array<T>` is fully static when `T` is the caller's bounded type parameter.
        actual_type_param_bounds: []const ModuleRegistry.TypeParamBound = &.{},
    };

    pub const ExtensionResolution = struct {
        target: ?FuncId = null,
        dispatch_owner: ?ClassId = null,
        /// At least one visible extension accepts the receiver and arguments. A tie keeps `target`
        /// null without removing the extension from the candidate scope.
        applicable: bool = false,
        /// The same argument list binds a visible extension after the Compose compiler ABI pair.
        compiler_abi_applicable: bool = false,
        /// A strict-key winner whose only weakness is an unknown argument verdict. Return-type
        /// derivation may use it; emission and dispatch commitment still require proof.
        sole_unknown: ?FuncId = null,
        /// A tied set whose candidates declare identical parameter lists except each function-typed
        /// parameter's RETURN position. Only lambda-parameter typing may read it, since every
        /// candidate hands the closure the same parameter types.
        param_rep: ?FuncId = null,
    };

    /// One ambiguous bare-call diagnostic: the call-site name and span plus the first two
    /// identical-signature candidates' FQNs and declaration spans (null with no phase-1 record).
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
            /// Every candidate lives in a package the caller neither declares, imports, nor sees by
            /// default. Kotlin does not resolve such a reference at all.
            unresolved,
            /// A simple in-scope reference resolves to nothing: notably an `it` in a lambda that
            /// declares no parameters, is not invoked with one argument, and has no enclosing `it`.
            unresolved_local,
        };

        /// Render the diagnostic with call and declaration sites located as `path:line`. Identical
        /// FQNs are conflicting overloads, fixable only declaration-side; distinct ones are a tie.
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

    /// A deferred member commits when every supplied argument is authoritative and
    /// member-compatible, and every reachable same-name extension is refuted.
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
        // The receiver's instantiation substitutes the owner's type parameters positionally, so
        // `contains(element: E)` on an `Iterable<String>` receiver proves against String. Only
        // the direct case (receiver head IS the owner) is taken; a projection keeps the raw param.
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
            // Unsubstitutable class-parameter args erase to `*` for the proof: the head adjudicates,
            // the parameter neither proves nor refutes.
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
            // Two tiers. A member proven applicable on every argument commits by Kotlin's scope order
            // alone, since members outrank extensions. A member merely non-refuted commits only when
            // every reachable extension is refuted below. A parameter still a bare type parameter
            // after substitution accepts whatever the source passed, and must not cost the proof.
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
