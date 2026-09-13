//! Builders for assembling an IR `Func` block-by-block. The lowering pass in
//! `lower` emits through these; kept separate from the type definitions.

const std = @import("std");
const ast = @import("ast");
const ir = @import("ir.zig");
const span_mod = @import("span");

const Allocator = std.mem.Allocator;

const Block = ir.Block;
const BlockId = ir.BlockId;
const Const = ir.Const;
const Func = ir.Func;
const FuncId = ir.FuncId;
const Inst = ir.Inst;
const Module = ir.Module;
const Reg = ir.Reg;
const Terminator = ir.Terminator;
const TypeRef = ir.TypeRef;
const CatchHandler = ir.CatchHandler;

pub const StringSet = std.StringHashMap(void);
const StringRegMap = std.StringHashMap(Reg);

/// A mutable var's home register plus the scope depth it bound at, which lets
/// `mutableHome` hide a home a spliced inline body installed, as `resolve` does.
const MutableHome = struct { reg: Reg, depth: usize };

/// The active spliced-lambda resolution window: free names resolve in the caller
/// scopes below `caller_depth` plus the lambda's own at and above `own_base`.
pub const SpliceWindow = struct { caller_depth: usize, own_base: usize };

pub const FinallyWindow = struct {
    window: ?SpliceWindow,
    bands_len: usize,
};

/// Per inline-fn-splice frame: substitution map plus `inline_return` snapshot.
const InlineLambdaFrame = struct {
    subst: std.StringHashMap(*const ast.Expr),
    snapshot: []InlineReturn,
    /// The bare-call receiver hint active at the inline CALL SITE: a lambda
    /// argument spliced from this frame is caller code and resolves under it.
    caller_hint_active: bool = false,
    caller_hint_recv: ?[]const u8 = null,
    caller_this_narrow: ?[]const u8 = null,
    /// Scope count at the inline call site, before the inline fn bound its
    /// parameters: a lambda spliced from this frame resolves free names in
    /// `[0, caller_scope_depth)` plus its own, never the fn's scopes between.
    caller_scope_depth: usize,
};

const InlineCallFrame = struct {
    name: []const u8,
    decl: *const ast.Function,
};

/// One `(result reg, join block)` on the `inline_return` stack: a `return`
/// inside an inlined body assigns the result and jumps to the join.
pub const InlineReturn = struct {
    reg: Reg,
    join: BlockId,
    /// Depth of `finally_stack` at push: a `return` targeting this frame replays
    /// only `finally_stack[finally_base..]`, an enclosing frame's being its own.
    finally_base: usize = 0,
    /// Depth of `catch_body_stack` at push: a `return` pops only frames opened
    /// inside this one.
    catch_base: usize = 0,
    /// Name of the inline function this frame splices, so `return@thatName` in
    /// the body resolves here instead of unwinding toward an absent frame.
    label: ?[]const u8 = null,
};

/// Labeled-return target for a spliced inline-argument lambda:
/// `return@<inlineFnName>` there returns from the lambda, not the caller.
pub const InlineLambdaRet = struct {
    label: []const u8,
    reg: Reg,
    end: BlockId,
};

/// Declaring package of the decl whose body, initializer, or thunk is lowering,
/// seeded per top-level decl and read by every builder on init; `""` is none.
threadlocal var lower_self_package: []const u8 = "";

pub fn setLowerSelfPackage(pkg: []const u8) []const u8 {
    const prev = lower_self_package;
    lower_self_package = pkg;
    return prev;
}

/// Per-file top-level property renames: FileId -> (simple name -> renamed global
/// name), the flat globals table's model of Kotlin's file-scoped `private` and
/// per-package storage; a reference resolves through its own span file.
pub const FilePrivateRenames = std.AutoHashMap(u32, std.StringHashMap([]const u8));

threadlocal var lower_file_private_renames: ?*const FilePrivateRenames = null;

pub fn setLowerFilePrivateRenames(m: ?*const FilePrivateRenames) ?*const FilePrivateRenames {
    const prev = lower_file_private_renames;
    lower_file_private_renames = m;
    return prev;
}

pub fn filePrivateRename(name: []const u8, file: u32) ?[]const u8 {
    const m = lower_file_private_renames orelse return null;
    const inner = m.get(file) orelse return null;
    return inner.get(name);
}

/// Per-file renames for file-private top-level FUNCTIONS: Kotlin file-scopes a
/// `private fun`, so same-signature twins mangle per file and their calls rewrite.
threadlocal var lower_file_private_func_renames: ?*const FilePrivateRenames = null;

pub fn setLowerFilePrivateFuncRenames(m: ?*const FilePrivateRenames) ?*const FilePrivateRenames {
    const prev = lower_file_private_func_renames;
    lower_file_private_func_renames = m;
    return prev;
}

pub fn filePrivateFuncRename(name: []const u8, file: u32) ?[]const u8 {
    const m = lower_file_private_func_renames orelse return null;
    const inner = m.get(file) orelse return null;
    return inner.get(name);
}

/// Name of the REAL (named) function whose body is lowering: the lexical target
/// of a bare `return` in an argument lambda, which Kotlin returns from the
/// function the lambda is written in, so an unflattened inline callee unwinds
/// to exactly that frame.
threadlocal var current_real_fn: ?[]const u8 = null;

pub fn pushCurrentRealFn(name: []const u8) ?[]const u8 {
    const prev = current_real_fn;
    current_real_fn = name;
    return prev;
}

pub fn popCurrentRealFn(prev: ?[]const u8) void {
    current_real_fn = prev;
}

pub fn currentRealFn() ?[]const u8 {
    return current_real_fn;
}

/// LOCAL class names declared so far in the function lowering and its enclosing
/// ones: a bare constructor call on one constructs the local class, not a
/// same-simple-name module class. Overflow past the 32 slots loses the shadowing.
threadlocal var local_class_scope: [32][]const u8 = undefined;
threadlocal var local_class_scope_len: usize = 0;

pub fn pushLocalClassName(name: []const u8) void {
    if (local_class_scope_len < local_class_scope.len) {
        local_class_scope[local_class_scope_len] = name;
        local_class_scope_len += 1;
    }
}

pub fn localClassScopeMark() usize {
    return local_class_scope_len;
}

pub fn localClassScopeRestore(mark: usize) void {
    if (mark <= local_class_scope.len) local_class_scope_len = mark;
}

/// Emptied per program build: the names are slices of that program's AST, and
/// an entry left by an earlier program would be read after its AST was freed.
pub fn localClassScopeReset() void {
    local_class_scope_len = 0;
}

pub fn isLocalClassInScope(name: []const u8) bool {
    for (local_class_scope[0..local_class_scope_len]) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// Owner class of the REAL function lowering, for nested lambda builders.
threadlocal var current_owner_class: ?[]const u8 = null;

pub fn pushCurrentOwnerClass(name: ?[]const u8) ?[]const u8 {
    const prev = current_owner_class;
    current_owner_class = name;
    return prev;
}

pub fn popCurrentOwnerClass(prev: ?[]const u8) void {
    current_owner_class = prev;
}

pub fn currentOwnerClass() ?[]const u8 {
    return current_owner_class;
}

/// File-keyed type renames: FileId -> (simple type name -> mangled lift name).
/// Kotlin file-scopes a `private` top-level class or typealias, so one whose
/// simple name another file claims mangles; references rewrite by span file.
pub const FileTypeRenames = std.AutoHashMap(u32, std.StringHashMap([]const u8));

threadlocal var lower_file_type_renames: ?*const FileTypeRenames = null;

pub fn setLowerFileTypeRenames(m: ?*const FileTypeRenames) ?*const FileTypeRenames {
    const prev = lower_file_type_renames;
    lower_file_type_renames = m;
    return prev;
}

pub fn fileTypeRename(name: []const u8, file: u32) ?[]const u8 {
    const m = lower_file_type_renames orelse return null;
    const inner = m.get(file) orelse return null;
    return inner.get(name);
}

pub fn fileTypeRenamesFor(file: u32) ?*const std.StringHashMap([]const u8) {
    const m = lower_file_type_renames orelse return null;
    return m.getPtr(file);
}

/// Package-scoped type renames: a mangled `internal` classifier resolves through
/// this map in every file of its package, the file map not serving same-package
/// cross-file references. Cross-package references resolve by FQN.
pub const PkgTypeRenames = std.StringHashMap(std.StringHashMap([]const u8));

threadlocal var lower_pkg_type_renames: ?*const PkgTypeRenames = null;

pub fn setLowerPkgTypeRenames(m: ?*const PkgTypeRenames) ?*const PkgTypeRenames {
    const prev = lower_pkg_type_renames;
    lower_pkg_type_renames = m;
    return prev;
}

pub fn pkgTypeRename(name: []const u8, pkg: []const u8) ?[]const u8 {
    const m = lower_pkg_type_renames orelse return null;
    const inner = m.getPtr(pkg) orelse return null;
    return inner.get(name);
}

pub fn pkgTypeRenamesFor(pkg: []const u8) ?*const std.StringHashMap([]const u8) {
    const m = lower_pkg_type_renames orelse return null;
    return m.getPtr(pkg);
}

/// File-to-package view installed with the rename maps, so a head rename can
/// serve a same-package cross-file reference the file map does not cover.
pub const FilePkgMap = std.AutoHashMap(span_mod.FileId, []const u8);

threadlocal var lower_file_pkgs: ?*const FilePkgMap = null;

pub fn setLowerFilePkgs(m: ?*const FilePkgMap) ?*const FilePkgMap {
    const prev = lower_file_pkgs;
    lower_file_pkgs = m;
    return prev;
}

pub fn fileOrPkgTypeRename(name: []const u8, file: u32) ?[]const u8 {
    if (fileTypeRename(name, file)) |rn| return rn;
    const pkgs = lower_file_pkgs orelse return null;
    const pkg = pkgs.get(span_mod.FileId.from(file)) orelse return null;
    const r = pkgTypeRename(name, pkg);
    if (r != null and std.c.getenv("KLIO_RENAME_TRACE") != null)
        std.debug.print("[rnm-pkg] {s} pkg={s} -> {s} file={d}\n", .{ name, pkg, r.?, file });
    return r;
}

/// Flattened `BuildObject` rename snapshot, installed around an anon member body.
threadlocal var lower_anon_scope_renames: []const ir.ScopeRename = &.{};

pub fn setLowerAnonScopeRenames(rs: []const ir.ScopeRename) []const ir.ScopeRename {
    const prev = lower_anon_scope_renames;
    lower_anon_scope_renames = rs;
    return prev;
}

pub fn anonScopeRenames() []const ir.ScopeRename {
    return lower_anon_scope_renames;
}

/// First entry wins: nearer scopes were flattened first.
pub fn anonScopeRename(name: []const u8) ?[]const u8 {
    for (lower_anon_scope_renames) |r| {
        if (std.mem.eql(u8, r.name, name)) return r.renamed;
    }
    return null;
}

/// A property type head carried into a runtime anon-object member-body lowering,
/// so a sibling member's bare-receiver walk types the read. An un-annotated
/// initializer derives its head at `buildObject` from the runtime class.
pub const AnonPropHead = struct { owner: []const u8, name: []const u8, head: []const u8 };

threadlocal var lower_anon_prop_heads: []const AnonPropHead = &.{};

pub fn setLowerAnonPropHeads(hs: []const AnonPropHead) []const AnonPropHead {
    const prev = lower_anon_prop_heads;
    lower_anon_prop_heads = hs;
    return prev;
}

pub fn anonPropHead(owner: []const u8, name: []const u8) ?[]const u8 {
    for (lower_anon_prop_heads) |h| {
        if (std.mem.eql(u8, h.owner, owner) and std.mem.eql(u8, h.name, name)) return h.head;
    }
    return null;
}

/// Captured enclosing-local names carried into a runtime anon-object or
/// local-class member-body lowering. Such a name is the body's nearest binding
/// but has no local slot there, so the lowering keeps it dynamic instead of
/// const-inlining or LoadGlobal-binding a package-scope declaration.
threadlocal var lower_anon_capture_names: []const []const u8 = &.{};

pub fn setLowerAnonCaptureNames(ns: []const []const u8) []const []const u8 {
    const prev = lower_anon_capture_names;
    lower_anon_capture_names = ns;
    return prev;
}

pub fn anonCaptureBinds(name: []const u8) bool {
    for (lower_anon_capture_names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// Captured enclosing locals whose runtime value is a shared `Cell`, so a write
/// in a member body lands on the cell. Supplied by the runtime registration.
threadlocal var lower_anon_boxed_names: []const []const u8 = &.{};

pub fn setLowerAnonBoxedNames(ns: []const []const u8) []const []const u8 {
    const prev = lower_anon_boxed_names;
    lower_anon_boxed_names = ns;
    return prev;
}

pub fn anonBoxedCaptureNames() []const []const u8 {
    return lower_anon_boxed_names;
}

threadlocal var lower_anon_scope_classes: []const ir.ScopeClassRef = &.{};

pub fn setLowerAnonScopeClasses(classes: []const ir.ScopeClassRef) []const ir.ScopeClassRef {
    const prev = lower_anon_scope_classes;
    lower_anon_scope_classes = classes;
    return prev;
}

pub fn anonScopeClass(name: []const u8) ?ir.ScopeClassRef {
    for (lower_anon_scope_classes) |class_ref| {
        if (std.mem.eql(u8, class_ref.name, name)) return class_ref;
    }
    return null;
}

/// One same-named local-function declaration: its mangled binding plus the
/// signature facts a call site selects on. Slices owned by the declaring builder.
pub const LocalFnOverload = struct {
    mangled: []const u8,
    receiver_ty: ?TypeRef = null,
    /// The receiver names a type parameter of this fn, so applicability needs a
    /// substitution environment.
    receiver_has_type_params: bool = false,
    /// Type parameters and their effective upper bounds; unbounded ones `Any`.
    type_params: []const ir.ModuleRegistry.TypeParamBound = &.{},
    /// Positional param type heads, leading `this` dropped; null for a vararg.
    param_tys: []const ?[]const u8,
    param_names: []const []const u8,
    /// Parameters without defaults: a call must supply at least this many.
    n_required: usize,
    has_vararg: bool,
    /// Declared `fun R.f(...)`: needs a receiver context, which the call prepends.
    is_ext: bool = false,
};

pub const ContextFnShape = struct { n_ctx: usize, n_regular: usize, ctx_types: []const []const u8 = &.{} };

pub const HiddenBinding = struct { frame: usize, reg: Reg };

pub const FuncBuilder = struct {
    allocator: Allocator,
    module: *Module,
    /// A scratch/probe builder: its sites stay out of the dispatch census.
    census_quiet: bool = false,
    /// A lambda declared receiverless: the enclosing tier is its next receiver link.
    own_recv_known_none: bool = false,
    blocks: std.ArrayList(Block) = .empty,
    cur: BlockId,
    next_reg: u32,
    /// Forwarded splice lambda literals `finish` can nop when no read remains.
    pending_fwd_lambdas: std.ArrayList(FwdLambda) = .empty,
    /// Active spliced-subject `this` binds, innermost last, each shadowing `this`.
    subject_binds: std.ArrayList(SubjectBind) = .empty,
    /// Scope stack; the bottom frame holds parameters, one frame per block.
    scopes: std.ArrayList(StringRegMap) = .empty,
    /// Names living in an enclosing frame, seeded from the outer builder's
    /// scope chain: references lower as `LoadCapture` and record the name.
    outer_names: StringSet,
    capture_order: std.ArrayList([]const u8) = .empty,
    capture_regs: StringRegMap,
    capture_loads_emitted: StringSet,
    /// Loop context stack; `label` matches `break@label`, a bare jump the innermost.
    loops: std.ArrayList(LoopFrame) = .empty,
    /// Nesting depth of inline-fn BODY lowering; loops pushed while nonzero are the
    /// callee's, invisible to a lambda passed to it.
    lowering_inline_fn_body: u32 = 0,
    /// Nesting depth of spliced inline-lambda bodies; `loopFor` then skips the
    /// callee's own loops.
    in_spliced_lambda_body: u32 = 0,
    /// Names declared `var` in any live scope; a `val` target dispatches `plusAssign`.
    mutables: StringSet,
    /// Permanent home register per `var` local: reads resolve to it, writes Move in.
    mutable_homes: std.StringHashMap(MutableHome),
    /// Per-scope undo journal for `mutables`/`mutable_homes`: entries record the
    /// pre-declaration state and `popScope` restores it, so a block-scoped `var`
    /// stops shadowing a class property. The bottom scope has no frame.
    mutable_undo: std.ArrayList(std.ArrayList(MutableUndo)) = .empty,
    /// Names boxed into a shared `Value.Cell` for a nested lambda's capture:
    /// the home reg holds it, reads `CellGet`, writes `CellSet`, decl `MakeCell`.
    boxed_vars: StringSet,
    /// Locals annotated `: Any` or another erased type, so `==` sees a box.
    any_typed_locals: StringSet,
    /// Names typed `Iterable`, `Collection`, or a `Mutable*` form: Kotlin's
    /// `plus`/`minus` return a `List` there, so the receiver coerces to a list.
    broad_coll_locals: StringSet,
    /// Locals initialized by `object : T {}`, kept out of `local_init_exprs`.
    object_init_locals: StringSet,
    /// Simple name of the owning class; `super.method()` starts `CallSuper` here.
    owner_class: ?[]const u8 = null,
    /// Declaring package of the function lowered; a bare call prefers its sibling.
    self_package: []const u8 = "",
    /// Declared receiver-type name of the enclosing extension function, so a bare
    /// call prefers an overload whose `this`-param matches. Null for plain fns.
    recv_ty: ?[]const u8 = null,
    recv_type_ref: ?TypeRef = null,
    splice_recv_ty: ?[]const u8 = null,
    /// Depth of spliced receiver-lambda regions that pushed a subject on the chain.
    encl_tower_depth: u32 = 0,
    /// Register of the innermost pushed tower subject, telling a tower subject's
    /// `this`, which defers to the chain, from a pinned inline-EXT receiver.
    encl_tower_top: ?Reg = null,
    /// `splice_recv_ty` came from the innermost window, so it is receiver evidence.
    splice_recv_from_window: bool = false,
    /// The active splice's receiver type with its type arguments, which the
    /// head-only `splice_recv_ty` lacks. Owned by the splice that set it.
    splice_recv_ty_ref: ?TypeRef = null,
    splice_hint_active: bool = false,
    splice_hint_recv: ?[]const u8 = null,
    splice_hint_recv_ref: ?ast.TypeRef = null,
    /// Smart-cast narrowing of the implicit `this`: the branch body resolves
    /// extensions against the narrowed type, as Kotlin does. Cleared per splice.
    this_narrow: ?[]const u8 = null,
    /// Receiver type in scope as the implicit `this` at this lambda body's site:
    /// a `() -> R` block captures the enclosing `this`, a `T.() -> R` rebinds it.
    /// Distinct from `recv_ty`, which is null inside any lambda.
    enclosing_recv_ty: ?[]const u8 = null,
    /// Implicit receiver entries, innermost first; a receiver lambda prepends its
    /// head and keeps the outer tower. An entry may carry its `this@<label>`.
    implicit_receiver_tower: std.ArrayList(ir.ReceiverTowerEntry) = .empty,
    /// The label binding this body's own receiver; null when it has none.
    own_this_label: ?[]const u8 = null,
    /// The declaring class when `owner_class` names the extension receiver instead.
    dispatch_owner: ?[]const u8 = null,
    /// The LOCAL `fun` whose body this builder lowers: a bare self-call binds
    /// through its mangled cell, a later sibling rebinding the plain-name slot.
    self_local_fn: ?ir.SelfLocalFn = null,
    cur_call_trailing: bool = false,
    /// Names declared on the owning class, so method-body lowering can tell an
    /// unqualified `foo(...)` that means `this.foo(...)` from a global lookup.
    own_members: StringSet,
    /// Per own-member name, a bitmask of accepted argument counts: bit `i` some
    /// overload binds `i` user args, bit 62 one declares type parameters, bit 63
    /// a vararg overload. A name absent from the map is applicable.
    own_member_arity: std.StringHashMap(u64),
    /// Member names of the lexically enclosing class, carried into a lambda body.
    /// Unlike `own_members` these never reroute a bare reference through `this.`.
    enclosing_members: StringSet,
    /// Simple name of a `tailrec` function; self-calls lower to `TailJump`.
    tailrec_self: ?[]const u8 = null,
    /// AST name-span of the declaration lowered, which a typeck pick may not
    /// resolve a call back to.
    self_decl_span: ?span_mod.Span = null,
    body_span: ?span_mod.Span = null,
    /// The tailrec function has an implicit leading `this`; the jump leads with it.
    tailrec_self_this: bool = false,
    /// The expression lowered next sits in tail position (a `return` operand, an
    /// expression body, a tail arm): only there is a tailrec self-call a jump.
    tail_pos: bool = false,
    tail_here: bool = false,
    tail_arm: bool = false,
    call_tail: bool = false,
    tail_call_ok: bool = false,
    /// The tailrec function's parameters, for rebinding omitted defaults.
    tailrec_params: []const ast.Param = &.{},
    param_names: StringSet,
    /// Ordered value params of a compose-ABI'd function, threaded
    /// `$composer`/`$changed` excluded: `$changed` bits index the `$dirty` triple.
    compose_value_params: []const ast.Param = &.{},
    /// Names declared as local functions; a same-named `val` cannot hijack a call.
    local_fns: StringSet,
    /// A local `fun`'s declared return type, keyed by its mangled binding name.
    /// A local fn is a closure in a cell, so nothing else answers this. Owned.
    local_fn_return_tys: std.StringHashMap(TypeRef),
    /// Declared parameter type name per positional parameter of a local function,
    /// leading `this` dropped, so a numeric literal argument coerces at the call.
    local_fn_param_tys: std.StringHashMap([]const ?[]const u8),
    /// Local fns declared as extensions, whose bare call prepends the implicit
    /// receiver. The value is the value-parameter count, or -1 when unknown.
    local_ext_fns: std.StringHashMap(i8),
    /// Locals proven not callable, so a bare call of the name takes the function.
    nonfn_locals: StringSet,
    /// One entry per same-named local-fn declaration, in decl order; each closure
    /// is also bound under a mangled name, the plain name staying last-decl-wins.
    local_fn_overloads: std.StringHashMap(std.ArrayList(LocalFnOverload)),
    local_decl_types: std.StringHashMap(TypeRef),
    /// Source-annotated AST types of locals, so a later assignment lowers under the
    /// declaration's expected type. Pointers into the AST, which outlives the build.
    local_ast_tys: std.StringHashMap(*const ast.TypeRef),
    local_decl_nullable: std.StringHashMap(void),
    local_call_returns: std.StringHashMap(ir.EagerTypeHead),
    local_decl_recv_fn: std.StringHashMap(void),
    /// Initializer expression per un-annotated local; the AST outlives the pass.
    local_init_exprs: std.StringHashMap(*const ast.Expr),
    /// Locals whose name named nothing at their own declaration point: Kotlin
    /// scopes a local only after its initializer, so a bare call there ignores it.
    local_init_name_free: std.StringHashMap(void),
    /// Declaration span per recorded initializer, so a relower reads self.
    local_init_decl_spans: std.StringHashMap(ast.Span),
    /// Params whose declared type is a receiver-typed function (`block: T.() ->
    /// R`): a bare call `block(...)` dispatches with the enclosing `this`.
    receiver_lambda_params: StringSet,
    /// The `receiver_lambda_params` an inline splice added for the spliced fn's
    /// own parameters: only these may be suspended for a caller lambda body.
    splice_rlp_marks: StringSet,
    shared_rlp_marks: StringSet,
    receiver_lambda_recv_heads: std.StringHashMapUnmanaged(?[]const u8) = .empty,
    receiver_lambda_arity: std.StringHashMap(usize),
    context_fn_params: std.StringHashMap(ContextFnShape),
    /// Params and locals typed by an unconstrained generic type parameter: Kotlin
    /// desugars a comparison on one to `compareTo`, the total order, not IEEE.
    generic_typed_params: StringSet,
    plain_fn_params: StringSet,
    fn_params_take_lambda: StringSet,
    erased_recv_params: StringSet,
    /// Params typed by a concrete non-function type: not invokable, never a callee.
    non_fn_params: StringSet,
    /// Reified type-parameter names bound by an in-progress inline splice, mapped
    /// to the register holding the resolved class value; nested splices chain.
    reified_type_binds: StringRegMap,
    reified_type_names: std.StringHashMap([]const u8),
    /// Splice-scoped param name to declared type, reified substitutions applied:
    /// a nested reified call infers its type parameter from this lexical record.
    splice_param_tys: std.StringHashMap(ast.TypeRef),
    /// User `finally { … }` blocks enclosing the cursor, innermost on top: a
    /// `return` reached during inline expansion replays each before exiting.
    finally_stack: std.ArrayList(ast.Block) = .empty,
    /// Parallel to `finally_stack`: the try body-entry an inline `return` pops.
    finally_body_stack: std.ArrayList(BlockId) = .empty,
    /// Body-entry block of each enclosing catch-only try region: an inline
    /// `return` bypasses the `catch_done` exit, so it pops these `TryFrame`s too.
    catch_body_stack: std.ArrayList(BlockId) = .empty,
    /// The splice-resolve window and hidden-band depth active when each finally
    /// was pushed: a replayed body resolves names where its `try` was lowered.
    finally_window_stack: std.ArrayList(FinallyWindow) = .empty,
    is_lambda_body: bool,
    is_anon_fn_body: bool,
    is_named_local_fn: bool,
    is_inline: bool,
    /// Lowering a default-argument thunk, which runs in the declaring scope.
    is_param_thunk: bool,
    /// The lambda body was lowered without an implicit `it`, its functional type
    /// taking none, so an unresolved `it` here is a reference error, not null.
    it_suppressed: bool = false,
    /// The binding named `this` here is a backtick-quoted user parameter, not a
    /// dispatch receiver: bare calls must not member-dispatch through it.
    this_is_plain_param: bool = false,
    it_suppressed_span: ?ast.Span = null,
    /// Stack of (result reg, join block) for inline expansion; `inline_stack`
    /// guards recursion by declaration identity, so delegating overloads splice.
    inline_return: std.ArrayList(InlineReturn) = .empty,
    inline_stack: std.ArrayList(InlineCallFrame) = .empty,
    /// Entries below this index are hidden from the self-recursion check while a
    /// spliced argument literal lowers.
    inline_stack_visible_base: usize = 0,
    /// Per inline-fn-splice frame: the lambda-param substitution map and the
    /// `inline_return` snapshot an unlabeled `return` restores to localize.
    inline_lambda_subst: std.ArrayList(InlineLambdaFrame) = .empty,
    /// Resolution window for a spliced inline-argument lambda's free names:
    /// `resolve` searches `[own_base, top)` then `[0, caller_depth)`. Else null.
    lambda_splice_resolve: ?SpliceWindow = null,
    /// Scope floor for a spliced MEMBER body: its bare names resolve only at or
    /// above the splice base. Null outside one; the caller-lambda window wins.
    splice_body_floor: ?usize = null,
    /// Scope-index bands hidden by enclosing lambda-splice windows, one
    /// `[lo, hi]` per window on the splice stack: a nested window's caller region
    /// can reach past an outer splice's scopes, so the scan skips banded indices.
    splice_hidden_bands: std.ArrayList(struct { lo: usize, hi: usize }) = .empty,
    caller_member_scope: ?*MemberScopeSnapshot = null,
    inline_lambda_ret: std.ArrayList(InlineLambdaRet) = .empty,
    /// Simple name of the call whose arguments are lowering, a lambda's label.
    pending_lambda_label: ?[]const u8 = null,
    /// The enclosing call's simple name for the whole extent of its lowering,
    /// saved and restored by `lowerCall` so a nested call cannot overwrite it.
    current_call_label: ?[]const u8 = null,
    /// The lambda about to be lowered is a `suspend { … }` expression: its body
    /// `Func` is marked `is_suspend`. Consumed by the lambda lowering.
    pending_suspend_lambda: bool = false,
    /// Expected type for the expression in tail position of a typed context, so
    /// an inline `reified` call with no explicit `<…>` infers its type argument.
    pending_expected: ?ast.TypeRef = null,
    declared_return: ?ast.TypeRef = null,
    /// Expected lambda value-param count; `-1` unknown, `0` drops the injected `it`.
    pending_lambda_arity: i16 = -1,

    /// A lambda argument's expected value-parameter arity, keyed by the lambda's
    /// span and authoritative for `lowerLambda` whichever branch lowers the arg.
    lambda_arg_arity: std.AutoHashMap(span_mod.Span, i16) = undefined,
    /// Receiver type of a receiver-lambda argument, keyed by span, for deferred calls.
    lambda_arg_recv: std.AutoHashMap(span_mod.Span, TypeRef) = undefined,

    /// Bit `i` marks lambda value-parameter `i` as broad-collection-typed by the
    /// callee parameter; `pending_arg_broad_masks` is the per-argument source.
    pending_lambda_broad_mask: u32 = 0,
    pending_arg_broad_masks: ?[]const u32 = null,
    /// Sibling-solved expected type for one argument, keyed by its AST node.
    sib_expected_site: ?*const anyopaque = null,
    sib_expected_ty: ?ast.TypeRef = null,

    /// The callee parameter's function type takes only values typed by the
    /// callee's own type parameters, so a `::name` there denotes the generic
    /// overload; `pending_arg_fn_generic` is the per-argument source.
    pending_ref_fn_generic: bool = false,
    pending_arg_fn_generic: ?[]const bool = null,
    /// Instantiated lambda-argument parameter types; borrowed from the emitter.
    pending_ref_lambda_param_types: ?[]const TypeRef = null,
    pending_arg_lambda_param_types: ?[]const ?[]const TypeRef = null,
    /// Per-call `-> Unit` lambda-argument mask, freed by the argument-run consumer.
    pending_arg_lambda_unit: ?[]bool = null,
    pending_ref_lambda_unit: bool = false,

    has_own_type_params: bool = false,
    /// Non-reified type parameters in scope, own plus the enclosing class's: a
    /// cast to one is unchecked, erased to the bound, never a class check.
    type_param_names: StringSet,
    type_param_bounds: std.StringHashMap(ir.ModuleRegistry.TypeParamBound),
    /// Full lowered upper bound, keeping the type arguments the string record drops.
    type_param_bound_refs: std.StringHashMap(TypeRef),
    owned_type_param_names: std.ArrayList([]u8),

    pub fn init(allocator: Allocator, module: *Module) Allocator.Error!FuncBuilder {
        var self = FuncBuilder{
            .allocator = allocator,
            .module = module,
            .self_package = lower_self_package,
            .cur = BlockId.from(0),
            .next_reg = 0,
            .outer_names = StringSet.init(allocator),
            .capture_regs = StringRegMap.init(allocator),
            .capture_loads_emitted = StringSet.init(allocator),
            .mutables = StringSet.init(allocator),
            .mutable_homes = std.StringHashMap(MutableHome).init(allocator),
            .boxed_vars = StringSet.init(allocator),
            .any_typed_locals = StringSet.init(allocator),
            .broad_coll_locals = StringSet.init(allocator),
            .object_init_locals = StringSet.init(allocator),
            .own_members = StringSet.init(allocator),
            .type_param_names = StringSet.init(allocator),
            .type_param_bounds = std.StringHashMap(ir.ModuleRegistry.TypeParamBound).init(allocator),
            .type_param_bound_refs = std.StringHashMap(TypeRef).init(allocator),
            .owned_type_param_names = .empty,
            .own_member_arity = std.StringHashMap(u64).init(allocator),
            .lambda_arg_arity = std.AutoHashMap(span_mod.Span, i16).init(allocator),
            .lambda_arg_recv = std.AutoHashMap(span_mod.Span, TypeRef).init(allocator),
            .enclosing_members = StringSet.init(allocator),
            .param_names = StringSet.init(allocator),
            .local_fns = StringSet.init(allocator),
            .local_fn_return_tys = std.StringHashMap(TypeRef).init(allocator),
            .local_fn_param_tys = std.StringHashMap([]const ?[]const u8).init(allocator),
            .local_decl_types = std.StringHashMap(TypeRef).init(allocator),
            .local_ast_tys = std.StringHashMap(*const ast.TypeRef).init(allocator),
            .local_decl_nullable = std.StringHashMap(void).init(allocator),
            .local_call_returns = std.StringHashMap(ir.EagerTypeHead).init(allocator),
            .local_decl_recv_fn = std.StringHashMap(void).init(allocator),
            .local_init_exprs = std.StringHashMap(*const ast.Expr).init(allocator),
            .local_init_name_free = std.StringHashMap(void).init(allocator),
            .local_init_decl_spans = std.StringHashMap(ast.Span).init(allocator),
            .local_ext_fns = std.StringHashMap(i8).init(allocator),
            .nonfn_locals = StringSet.init(allocator),
            .local_fn_overloads = std.StringHashMap(std.ArrayList(LocalFnOverload)).init(allocator),
            .receiver_lambda_params = StringSet.init(allocator),
            .splice_rlp_marks = StringSet.init(allocator),
            .shared_rlp_marks = StringSet.init(allocator),
            .receiver_lambda_arity = std.StringHashMap(usize).init(allocator),
            .context_fn_params = std.StringHashMap(ContextFnShape).init(allocator),
            .generic_typed_params = StringSet.init(allocator),
            .plain_fn_params = StringSet.init(allocator),
            .fn_params_take_lambda = StringSet.init(allocator),
            .erased_recv_params = StringSet.init(allocator),
            .non_fn_params = StringSet.init(allocator),
            .reified_type_binds = StringRegMap.init(allocator),
            .reified_type_names = std.StringHashMap([]const u8).init(allocator),
            .splice_param_tys = std.StringHashMap(ast.TypeRef).init(allocator),
            .is_lambda_body = false,
            .is_anon_fn_body = false,
            .is_named_local_fn = false,
            .is_inline = false,
            .is_param_thunk = false,
        };
        const entry = Block{
            .id = BlockId.from(0),
            .insts = &.{},
            .terminator = .{ .Return = null },
        };
        try self.blocks.append(allocator, entry);
        try self.scopes.append(allocator, StringRegMap.init(allocator));
        return self;
    }

    pub fn deinit(self: *FuncBuilder) void {
        const a = self.allocator;
        for (self.blocks.items) |*b| {
            if (b.insts.len != 0) a.free(b.insts);
            if (b.catches.len != 0) a.free(b.catches);
        }
        self.blocks.deinit(a);
        self.pending_fwd_lambdas.deinit(a);
        self.subject_binds.deinit(a);
        for (self.scopes.items) |*s| s.deinit();
        self.scopes.deinit(a);
        self.lambda_arg_arity.deinit();
        {
            var it = self.lambda_arg_recv.valueIterator();
            while (it.next()) |receiver| receiver.deinit(a);
            self.lambda_arg_recv.deinit();
        }
        if (self.recv_type_ref) |receiver| {
            var owned_receiver = receiver;
            owned_receiver.deinit(a);
        }
        self.outer_names.deinit();
        self.capture_order.deinit(a);
        self.capture_regs.deinit();
        self.capture_loads_emitted.deinit();
        self.loops.deinit(a);
        self.mutables.deinit();
        self.mutable_homes.deinit();
        for (self.mutable_undo.items) |*u| u.deinit(a);
        self.mutable_undo.deinit(a);
        self.boxed_vars.deinit();
        self.any_typed_locals.deinit();
        self.broad_coll_locals.deinit();
        self.object_init_locals.deinit();
        self.own_members.deinit();
        self.type_param_names.deinit();
        self.type_param_bounds.deinit();
        {
            var it = self.type_param_bound_refs.valueIterator();
            while (it.next()) |v| v.deinit(a);
            self.type_param_bound_refs.deinit();
        }
        for (self.owned_type_param_names.items) |name| a.free(name);
        self.owned_type_param_names.deinit(a);
        self.own_member_arity.deinit();
        self.enclosing_members.deinit();
        self.param_names.deinit();
        {
            var it = self.local_fn_param_tys.valueIterator();
            while (it.next()) |v| self.allocator.free(v.*);
            self.local_fn_param_tys.deinit();
        }
        self.local_fns.deinit();
        {
            var it = self.local_fn_return_tys.valueIterator();
            while (it.next()) |t| t.deinit(a);
            self.local_fn_return_tys.deinit();
        }
        {
            // `mangled` is module-lifetime; only the builder-owned slices free.
            var it = self.local_fn_overloads.valueIterator();
            while (it.next()) |list| {
                for (list.items) |ov| {
                    if (ov.receiver_ty) |receiver| {
                        var owned_receiver = receiver;
                        owned_receiver.deinit(a);
                    }
                    a.free(ov.type_params);
                    a.free(ov.param_tys);
                    a.free(ov.param_names);
                }
                list.deinit(a);
            }
            self.local_fn_overloads.deinit();
        }
        {
            var it = self.local_decl_types.valueIterator();
            while (it.next()) |ty| ty.deinit(self.allocator);
            self.local_decl_types.deinit();
            self.local_ast_tys.deinit();
        }
        self.local_decl_nullable.deinit();
        self.local_call_returns.deinit();
        self.local_decl_recv_fn.deinit();
        self.local_init_exprs.deinit();
        self.local_init_name_free.deinit();
        self.local_init_decl_spans.deinit();
        self.local_ext_fns.deinit();
        self.nonfn_locals.deinit();
        self.receiver_lambda_params.deinit();
        self.splice_rlp_marks.deinit();
        self.shared_rlp_marks.deinit();
        self.splice_hidden_bands.deinit(a);
        self.receiver_lambda_recv_heads.deinit(self.allocator);
        self.receiver_lambda_arity.deinit();
        self.context_fn_params.deinit();
        self.generic_typed_params.deinit();
        self.plain_fn_params.deinit();
        self.fn_params_take_lambda.deinit();
        self.erased_recv_params.deinit();
        self.non_fn_params.deinit();
        self.reified_type_binds.deinit();
        self.reified_type_names.deinit();
        self.splice_param_tys.deinit();
        self.implicit_receiver_tower.deinit(a);
        self.finally_stack.deinit(a);
        self.finally_body_stack.deinit(a);
        self.catch_body_stack.deinit(a);
        self.finally_window_stack.deinit(a);
        self.inline_return.deinit(a);
        self.inline_stack.deinit(a);
        for (self.inline_lambda_subst.items) |*frame| {
            frame.subst.deinit();
            a.free(frame.snapshot);
        }
        self.inline_lambda_subst.deinit(a);
        self.inline_lambda_ret.deinit(a);
    }

    pub fn pushExpected(self: *FuncBuilder, ty: ?ast.TypeRef) ?ast.TypeRef {
        const prev = self.pending_expected;
        self.pending_expected = ty;
        return prev;
    }
    pub fn restoreExpected(self: *FuncBuilder, prev: ?ast.TypeRef) void {
        self.pending_expected = prev;
    }
    pub fn peekExpected(self: *const FuncBuilder) ?ast.TypeRef {
        return self.pending_expected;
    }
    pub fn setDeclaredReturn(self: *FuncBuilder, ty: ?ast.TypeRef) void {
        self.declared_return = ty;
    }
    pub fn declaredReturn(self: *const FuncBuilder) ?ast.TypeRef {
        return self.declared_return;
    }

    pub fn currentInlineFn(self: *const FuncBuilder) ?[]const u8 {
        if (self.inline_stack.items.len == 0) return null;
        return self.inline_stack.items[self.inline_stack.items.len - 1].name;
    }
    pub fn currentInlineDecl(self: *const FuncBuilder) ?*const ast.Function {
        if (self.inline_stack.items.len == 0) return null;
        return self.inline_stack.items[self.inline_stack.items.len - 1].decl;
    }
    pub fn pushInlineLambdaRet(self: *FuncBuilder, label: []const u8, r: Reg, end: BlockId) Allocator.Error!void {
        try self.inline_lambda_ret.append(self.allocator, .{ .label = label, .reg = r, .end = end });
    }
    pub fn popInlineLambdaRet(self: *FuncBuilder) void {
        _ = self.inline_lambda_ret.pop();
    }
    pub fn inlineLambdaRetFor(self: *const FuncBuilder, label: []const u8) ?InlineReturn {
        var i = self.inline_lambda_ret.items.len;
        while (i > 0) {
            i -= 1;
            const f = self.inline_lambda_ret.items[i];
            if (std.mem.eql(u8, f.label, label)) return .{ .reg = f.reg, .join = f.end };
        }
        return null;
    }

    pub fn inlineActiveReturn(self: *const FuncBuilder) ?InlineReturn {
        if (self.inline_return.items.len == 0) return null;
        return self.inline_return.items[self.inline_return.items.len - 1];
    }
    pub fn pushInlineReturn(self: *FuncBuilder, r: Reg, join: BlockId, label: ?[]const u8) Allocator.Error!void {
        try self.inline_return.append(self.allocator, .{ .reg = r, .join = join, .finally_base = self.finally_stack.items.len, .catch_base = self.catch_body_stack.items.len, .label = label });
    }
    /// Innermost active inline body-splice frame named `label`: a labeled return
    /// crossing only inline boundaries resolves here, the target having no frame.
    pub fn inlineReturnFor(self: *const FuncBuilder, label: []const u8) ?InlineReturn {
        var i = self.inline_return.items.len;
        while (i > 0) {
            i -= 1;
            const f = self.inline_return.items[i];
            if (f.label) |l| if (std.mem.eql(u8, l, label)) return f;
        }
        return null;
    }
    pub fn popInlineReturn(self: *FuncBuilder) void {
        _ = self.inline_return.pop();
    }
    /// Leaves the stack empty; the caller must `restoreInlineReturn` the slice.
    pub fn takeInlineReturn(self: *FuncBuilder) Allocator.Error![]InlineReturn {
        const owned = try self.inline_return.toOwnedSlice(self.allocator);
        self.inline_return = .empty;
        return owned;
    }
    pub fn restoreInlineReturn(self: *FuncBuilder, saved: []InlineReturn) Allocator.Error!void {
        self.inline_return.clearRetainingCapacity();
        try self.inline_return.appendSlice(self.allocator, saved);
        self.allocator.free(saved);
    }
    pub fn inlineDeclInProgress(self: *const FuncBuilder, decl: *const ast.Function) bool {
        // Entries below the visibility base belong to enclosing splices whose
        // argument-literal content is lowering: that is caller code, so a same-fn
        // call inside it is nesting, not self-recursion.
        for (self.inline_stack.items[self.inline_stack_visible_base..]) |frame| {
            if (frame.decl == decl) return true;
        }
        // Receiver-formed callees (`with`, `apply`) keep the full-stack check
        // even through literal content: a nested same-fn splice loses the outer
        // subject's ranking, so it stays framed for the runtime tower.
        for (decl.params) |*p| {
            const ft = p.ty.function orelse continue;
            if (ft.receiver != null) {
                for (self.inline_stack.items[0..self.inline_stack_visible_base]) |frame| {
                    if (frame.decl == decl) return true;
                }
                break;
            }
        }
        return false;
    }
    pub fn pushInlineDecl(self: *FuncBuilder, name: []const u8, decl: *const ast.Function) Allocator.Error!void {
        try self.inline_stack.append(self.allocator, .{ .name = name, .decl = decl });
    }
    pub fn popInlineDecl(self: *FuncBuilder) void {
        _ = self.inline_stack.pop();
    }
    /// Takes ownership of `m`; the current `inline_return` is duplicated in.
    pub fn pushInlineLambdaFrame(self: *FuncBuilder, m: std.StringHashMap(*const ast.Expr), caller_scope_depth: usize) Allocator.Error!void {
        try self.pushInlineLambdaFrameHinted(m, caller_scope_depth, self.splice_hint_active, self.splice_hint_recv, self.this_narrow);
    }

    /// As `pushInlineLambdaFrame`, with an explicit call-site bare-call hint.
    pub fn pushInlineLambdaFrameHinted(self: *FuncBuilder, m: std.StringHashMap(*const ast.Expr), caller_scope_depth: usize, hint_active: bool, hint_recv: ?[]const u8, this_narrow: ?[]const u8) Allocator.Error!void {
        const snap = try self.allocator.dupe(InlineReturn, self.inline_return.items);
        try self.inline_lambda_subst.append(self.allocator, .{ .subst = m, .snapshot = snap, .caller_scope_depth = caller_scope_depth, .caller_hint_active = hint_active, .caller_hint_recv = hint_recv, .caller_this_narrow = this_narrow });
    }

    pub const CallerHint = struct { active: bool, recv: ?[]const u8, this_narrow: ?[]const u8 };
    pub fn inlineLambdaCallerHint(self: *const FuncBuilder) ?CallerHint {
        if (self.inline_lambda_subst.items.len == 0) return null;
        const f = self.inline_lambda_subst.items[self.inline_lambda_subst.items.len - 1];
        return .{ .active = f.caller_hint_active, .recv = f.caller_hint_recv, .this_narrow = f.caller_this_narrow };
    }

    pub fn inlineLambdaCallerDepth(self: *const FuncBuilder) ?usize {
        if (self.inline_lambda_subst.items.len == 0) return null;
        return self.inline_lambda_subst.items[self.inline_lambda_subst.items.len - 1].caller_scope_depth;
    }

    /// Index of the outermost frame substituting this exact lambda: frames above
    /// inherited the binding, and its records describe the lambda's own scope.
    pub fn definingInlineLambdaFrame(
        self: *const FuncBuilder,
        name: []const u8,
        lam: *const ast.Expr,
    ) ?usize {
        for (self.inline_lambda_subst.items, 0..) |*fr, i| {
            const got = fr.subst.get(name) orelse continue;
            if (got == lam) return i;
        }
        return null;
    }

    pub fn inlineLambdaFrameCallerDepth(self: *const FuncBuilder, idx: usize) usize {
        return self.inline_lambda_subst.items[idx].caller_scope_depth;
    }

    pub fn inlineLambdaFrameOwnerReturn(self: *const FuncBuilder, idx: usize) []const InlineReturn {
        return self.inline_lambda_subst.items[idx].snapshot;
    }

    pub fn inlineLambdaFrameHint(self: *const FuncBuilder, idx: usize) CallerHint {
        const f = self.inline_lambda_subst.items[idx];
        return .{ .active = f.caller_hint_active, .recv = f.caller_hint_recv, .this_narrow = f.caller_this_narrow };
    }

    /// Resolve `name` only above `base`, so a spliced body cannot capture a caller
    /// local. Null when only caller scopes bind it.
    pub fn resolveSpliceLocal(self: *const FuncBuilder, name: []const u8, base: usize) ?Reg {
        var i = self.scopes.items.len;
        while (i > base) {
            i -= 1;
            if (self.scopes.items[i].get(name)) |r| return r;
        }
        return null;
    }

    pub fn scopeDepth(self: *const FuncBuilder) usize {
        return self.scopes.items.len;
    }
    pub fn popInlineLambdaFrame(self: *FuncBuilder) void {
        if (self.inline_lambda_subst.pop()) |frame| {
            var f = frame;
            f.subst.deinit();
            self.allocator.free(f.snapshot);
        }
    }
    /// Only the innermost inline frame's lambda params are in scope.
    pub fn inlineLambdaFor(self: *const FuncBuilder, name: []const u8) ?*const ast.Expr {
        if (self.inline_lambda_subst.items.len == 0) return null;
        const top = &self.inline_lambda_subst.items[self.inline_lambda_subst.items.len - 1];
        return top.subst.get(name);
    }
    /// The frame beneath the substituting one: an inline lambda param called there
    /// is the caller's, the body being caller code.
    pub fn definingInlineLambdaSubst(
        self: *const FuncBuilder,
        name: []const u8,
        lam: *const ast.Expr,
    ) ?*const std.StringHashMap(*const ast.Expr) {
        const i = self.definingInlineLambdaFrame(name, lam) orelse return null;
        if (i == 0) return null;
        return &self.inline_lambda_subst.items[i - 1].subst;
    }
    /// Borrowed until the innermost inline-lambda frame is popped.
    pub fn inlineLambdaOwnerReturn(self: *const FuncBuilder) ?[]const InlineReturn {
        if (self.inline_lambda_subst.items.len == 0) return null;
        return self.inline_lambda_subst.items[self.inline_lambda_subst.items.len - 1].snapshot;
    }

    pub fn markAnyTyped(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.any_typed_locals.put(name, {});
    }
    pub fn isAnyTyped(self: *const FuncBuilder, name: []const u8) bool {
        return self.any_typed_locals.contains(name);
    }
    pub fn markBroadCollectionLocal(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.broad_coll_locals.put(name, {});
    }
    pub fn isBroadCollectionLocal(self: *const FuncBuilder, name: []const u8) bool {
        return self.broad_coll_locals.contains(name);
    }
    pub fn markObjectInitLocal(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.object_init_locals.put(name, {});
    }
    pub fn isObjectInitLocal(self: *const FuncBuilder, name: []const u8) bool {
        return self.object_init_locals.contains(name);
    }

    /// Journal `name`'s mutability state once per scope, for `popScope`.
    fn recordMutableUndo(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        if (self.mutable_undo.items.len == 0) return;
        const top = &self.mutable_undo.items[self.mutable_undo.items.len - 1];
        for (top.items) |e| {
            if (std.mem.eql(u8, e.name, name)) return;
        }
        try top.append(self.allocator, .{
            .name = name,
            .prev_home = self.mutable_homes.get(name),
            .prev_mutable = self.mutables.contains(name),
        });
    }

    pub fn markMutable(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.recordMutableUndo(name);
        try self.mutables.put(name, {});
    }
    pub fn isMutable(self: *const FuncBuilder, name: []const u8) bool {
        return self.mutables.contains(name);
    }

    pub fn setMutableHome(self: *FuncBuilder, name: []const u8, reg: Reg) Allocator.Error!void {
        try self.recordMutableUndo(name);
        try self.mutable_homes.put(name, .{
            .reg = reg,
            .depth = self.scopes.items.len -| 1,
        });
    }
    pub fn mutableHome(self: *const FuncBuilder, name: []const u8) ?Reg {
        const e = self.mutable_homes.get(name) orelse return null;
        // The inline body's scopes are not the spliced lambda's lexical scope:
        // hide a home bound there, as `resolve` does for plain bindings.
        if (self.lambda_splice_resolve) |w| {
            if (e.depth >= w.caller_depth and e.depth < w.own_base) return null;
            for (self.splice_hidden_bands.items) |band| {
                if (e.depth >= band.lo and e.depth <= band.hi) return null;
            }
        } else if (self.splice_body_floor) |fl| {
            // A caller local's home below the member-splice floor is out of scope.
            if (e.depth < fl) return null;
        }
        return e.reg;
    }

    /// Takes ownership of `names`; the previous set is freed.
    pub fn setBoxedVars(self: *FuncBuilder, names: StringSet) void {
        self.boxed_vars.deinit();
        self.boxed_vars = names;
    }
    pub fn markBoxed(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.boxed_vars.put(name, {});
    }
    /// Removes a transient mark before it leaks onto a same-named caller local.
    pub fn unmarkBoxed(self: *FuncBuilder, name: []const u8) void {
        _ = self.boxed_vars.remove(name);
    }
    pub fn isBoxed(self: *const FuncBuilder, name: []const u8) bool {
        return self.boxed_vars.contains(name);
    }
    /// The caller owns the returned set.
    pub fn boxedVarsSnapshot(self: *const FuncBuilder) Allocator.Error!StringSet {
        return cloneStringSet(self.allocator, &self.boxed_vars);
    }

    /// Takes ownership of `names`.
    pub fn setOuterNames(self: *FuncBuilder, names: StringSet) void {
        self.outer_names.deinit();
        self.outer_names = names;
        self.is_lambda_body = true;
    }
    pub fn setOuterNamesWithoutLambda(self: *FuncBuilder, names: StringSet) void {
        self.outer_names.deinit();
        self.outer_names = names;
        // An anonymous-function expression is not a lambda for return/label
        // semantics (`return` is local), but its bare names resolve against the
        // enclosing receivers and its `this` arrives through the capture slot.
        self.is_anon_fn_body = true;
    }
    pub fn isAnonFnBody(self: *const FuncBuilder) bool {
        return self.is_anon_fn_body;
    }
    /// A body whose implicit `this` arrives through the capture slot, not a param.
    pub fn capturesThisSlot(self: *const FuncBuilder) bool {
        return self.is_lambda_body or self.is_anon_fn_body;
    }
    pub fn setInline(self: *FuncBuilder, inline_: bool) void {
        self.is_inline = inline_;
    }
    pub fn isLambdaBody(self: *const FuncBuilder) bool {
        return self.is_lambda_body;
    }
    /// A named local function has no receiver of its own and sees its enclosing
    /// body's, so the lambda-body flag is set only when that body has one.
    pub fn setOuterNamesNamedLocalFn(self: *FuncBuilder, names: StringSet, enclosing_has_receiver: bool) void {
        self.outer_names.deinit();
        self.outer_names = names;
        self.is_lambda_body = enclosing_has_receiver;
        self.is_named_local_fn = true;
    }
    pub fn isNamedLocalFn(self: *const FuncBuilder) bool {
        return self.is_named_local_fn;
    }

    /// Returns the per-lambda capture index; idempotent for the same name.
    pub fn recordCapture(self: *FuncBuilder, name: []const u8) Allocator.Error!u16 {
        if (self.capture_regs.contains(name)) {
            for (self.capture_order.items, 0..) |n, i| {
                if (std.mem.eql(u8, n, name)) return @intCast(i);
            }
            return 0;
        }
        const idx: u16 = @intCast(self.capture_order.items.len);
        try self.capture_order.append(self.allocator, name);
        const r = self.allocReg();
        try self.capture_regs.put(name, r);
        return idx;
    }

    /// Load the capture slot into its per-name register once, in the ENTRY block,
    /// so it dominates every use; a load at a reference site may not.
    pub fn loadCaptureHoisted(self: *FuncBuilder, name: []const u8) Allocator.Error!Reg {
        const idx = try self.recordCapture(name);
        const dst = self.capture_regs.get(name).?;
        if (!self.capture_loads_emitted.contains(name)) {
            try self.capture_loads_emitted.put(name, {});
            const b0 = &self.blocks.items[0];
            const old = b0.insts;
            const new = try self.allocator.alloc(Inst, old.len + 1);
            @memcpy(new[0..old.len], old);
            new[old.len] = .{ .LoadCapture = .{ .dst = dst, .idx = idx } };
            if (old.len != 0) self.allocator.free(old);
            b0.insts = new;
        }
        return dst;
    }

    pub fn knowsOuter(self: *const FuncBuilder, name: []const u8) bool {
        return self.outer_names.contains(name);
    }

    pub fn captureReg(self: *const FuncBuilder, name: []const u8) ?Reg {
        return self.capture_regs.get(name);
    }

    pub fn capturesTaken(self: *const FuncBuilder) []const []const u8 {
        return self.capture_order.items;
    }

    pub fn pushLoop(self: *FuncBuilder, label: ?[]const u8, cont_t: BlockId, brk_t: BlockId) Allocator.Error!void {
        try self.loops.append(self.allocator, .{
            .label = label,
            .from_inline_fn_body = self.lowering_inline_fn_body > 0,
            .continue_target = cont_t,
            .break_target = brk_t,
            .finally_base = self.finally_stack.items.len,
            .catch_base = self.catch_body_stack.items.len,
            .encl_tower_base = self.encl_tower_depth,
        });
    }
    pub fn popLoop(self: *FuncBuilder) void {
        _ = self.loops.pop();
    }
    pub fn loopFor(self: *const FuncBuilder, label: ?[]const u8) ?*const LoopFrame {
        // The callee's own loops are not lexically in scope for a spliced
        // lambda's `break`/`continue`: skip them for the call site's loop.
        const skip_inline = self.in_spliced_lambda_body > 0;
        if (label) |l| {
            var i = self.loops.items.len;
            while (i > 0) {
                i -= 1;
                const f = &self.loops.items[i];
                if (skip_inline and f.from_inline_fn_body) continue;
                if (f.label) |fl| {
                    if (std.mem.eql(u8, fl, l)) return f;
                }
            }
            return null;
        }
        var i = self.loops.items.len;
        while (i > 0) {
            i -= 1;
            const f = &self.loops.items[i];
            if (skip_inline and f.from_inline_fn_body) continue;
            return f;
        }
        return null;
    }

    pub fn bind(self: *FuncBuilder, name: []const u8, reg: Reg) Allocator.Error!void {
        if (std.c.getenv("KLIO_THIS_TRACE") != null and std.mem.eql(u8, name, "this")) {
            std.debug.print("[bind-this] reg={d} depth={d}\n", .{ reg.int(), self.scopes.items.len });
        }
        try self.scopes.items[self.scopes.items.len - 1].put(name, reg);
    }

    /// Update the frame already binding `name`, else bind in the current scope.
    pub fn rebind(self: *FuncBuilder, name: []const u8, reg: Reg) Allocator.Error!void {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].contains(name)) {
                try self.scopes.items[i].put(name, reg);
                return;
            }
        }
        try self.scopes.items[self.scopes.items.len - 1].put(name, reg);
    }

    pub fn setOwnerClass(self: *FuncBuilder, name: []const u8) void {
        self.owner_class = name;
    }
    pub fn ownerClass(self: *const FuncBuilder) ?[]const u8 {
        return self.owner_class;
    }
    pub fn setRecvTy(self: *FuncBuilder, name: ?[]const u8) void {
        if (self.recv_type_ref) |receiver| {
            var owned_receiver = receiver;
            owned_receiver.deinit(self.allocator);
            self.recv_type_ref = null;
        }
        self.recv_ty = name;
    }
    pub fn spliceRefDebug() bool {
        return ir.runtimeEnvSetOnce("KLIO_SPLICE_REF");
    }
    pub fn setRecvTypeRefOwned(self: *FuncBuilder, receiver: TypeRef) void {
        if (self.recv_type_ref) |previous| {
            var owned_previous = previous;
            owned_previous.deinit(self.allocator);
        }
        self.recv_type_ref = receiver;
        self.recv_ty = receiver.name;
    }
    /// The active inline splice's declared extension receiver type, distinct from
    /// `recv_ty`: it feeds receiver-evidence gates, never bare-call binding.
    pub fn setSpliceRecvTy(self: *FuncBuilder, name: ?[]const u8) void {
        self.splice_recv_ty = name;
    }

    /// Bare-call static-receiver hint: a spliced body resolves against the inline
    /// fn's own receiver, Kotlin inline bodies never seeing the caller's scope.
    pub fn setSpliceHint(self: *FuncBuilder, active: bool, recv: ?[]const u8) void {
        self.splice_hint_active = active;
        self.splice_hint_recv = recv;
    }
    pub fn spliceHintActive(self: *const FuncBuilder) bool {
        return self.splice_hint_active;
    }
    pub fn spliceHintRecv(self: *const FuncBuilder) ?[]const u8 {
        return self.splice_hint_recv;
    }
    /// The active splice's declared receiver type with type arguments, needed to
    /// rank overloads differing by element type. Borrowed from the declaration.
    pub fn setSpliceHintRecvRef(self: *FuncBuilder, ty: ?ast.TypeRef) ?ast.TypeRef {
        const prev = self.splice_hint_recv_ref;
        self.splice_hint_recv_ref = ty;
        return prev;
    }
    pub fn spliceHintRecvRef(self: *const FuncBuilder) ?ast.TypeRef {
        return self.splice_hint_recv_ref;
    }
    pub fn setThisNarrow(self: *FuncBuilder, head: ?[]const u8) ?[]const u8 {
        const prev = self.this_narrow;
        self.this_narrow = head;
        return prev;
    }
    pub fn thisNarrow(self: *const FuncBuilder) ?[]const u8 {
        return self.this_narrow;
    }
    pub fn spliceRecvTy(self: *const FuncBuilder) ?[]const u8 {
        return self.splice_recv_ty;
    }
    /// Returns the previous record; the splice restores it and frees its own.
    pub fn setSpliceRecvTyRef(self: *FuncBuilder, ty: ?TypeRef) ?TypeRef {
        const prev = self.splice_recv_ty_ref;
        self.splice_recv_ty_ref = ty;
        return prev;
    }
    pub fn spliceRecvTyRef(self: *const FuncBuilder) ?*const TypeRef {
        if (self.splice_recv_ty_ref) |*t| return t;
        return null;
    }
    pub fn recvTy(self: *const FuncBuilder) ?[]const u8 {
        return self.recv_ty;
    }
    pub fn recvTypeRef(self: *const FuncBuilder) ?TypeRef {
        if (self.recv_type_ref) |receiver| return receiver;
        const head = self.recv_ty orelse return null;
        return .{ .name = head, .nullable = false, .args = &.{} };
    }
    /// The implicit `this` here: the declaration's own receiver, else the carried one.
    pub fn enclosingRecvTy(self: *const FuncBuilder) ?[]const u8 {
        return self.recv_ty orelse self.enclosing_recv_ty;
    }
    pub fn setEnclosingRecvTy(self: *FuncBuilder, name: ?[]const u8) void {
        self.enclosing_recv_ty = name;
    }
    pub fn setImplicitReceiverTower(self: *FuncBuilder, entries: []const ir.ReceiverTowerEntry) Allocator.Error!void {
        self.implicit_receiver_tower.clearRetainingCapacity();
        try self.implicit_receiver_tower.appendSlice(self.allocator, entries);
    }
    pub fn setOwnThisLabel(self: *FuncBuilder, label: ?[]const u8) void {
        self.own_this_label = label;
    }
    pub fn setDispatchOwner(self: *FuncBuilder, owner: ?[]const u8) void {
        self.dispatch_owner = owner;
    }
    /// The class a `this@<Class>` here names: the dispatch owner, else the owner.
    pub fn dispatchClass(self: *const FuncBuilder) ?[]const u8 {
        return self.dispatch_owner orelse self.ownerClass();
    }
    /// A duplicate head backfills a missing label so the labeled one survives.
    fn appendTowerEntry(
        out: *std.ArrayList(ir.ReceiverTowerEntry),
        allocator: Allocator,
        entry: ir.ReceiverTowerEntry,
    ) Allocator.Error!void {
        for (out.items) |*existing| {
            if (std.mem.eql(u8, existing.head, entry.head)) {
                if (existing.label == null) existing.label = entry.label;
                return;
            }
        }
        try out.append(allocator, entry);
    }
    /// Mirrors `inline_call.rfsEnabled`; importing it here would cycle.
    fn rfsSpliceFirst() bool {
        return true;
    }

    /// The tower for a body nested here, innermost first; `innermost` is its own.
    pub fn collectReceiverTowerLabeled(
        self: *const FuncBuilder,
        allocator: Allocator,
        innermost: ?[]const u8,
        innermost_label: ?[]const u8,
    ) Allocator.Error![]const ir.ReceiverTowerEntry {
        var out: std.ArrayList(ir.ReceiverTowerEntry) = .empty;
        errdefer out.deinit(allocator);
        if (innermost) |head| try appendTowerEntry(&out, allocator, .{
            .head = head,
            .label = innermost_label,
        });
        // An inline splice window's receiver is an implicit receiver too, labeled
        // by the spliced function. Under the receiver-formed splice it is the
        // `with`/`apply` subject, ranked ahead of the lexical owner.
        const splice_head = self.spliceRecvTy() orelse self.spliceHintRecv();
        const splice_first = rfsSpliceFirst();
        if (splice_first) if (splice_head) |head| {
            try appendTowerEntry(&out, allocator, .{ .head = head, .label = self.currentInlineFn() });
        };
        const current = self.recv_ty orelse self.enclosing_recv_ty orelse self.owner_class;
        if (current) |head| {
            const label: ?[]const u8 = if (self.recv_ty != null) self.own_this_label else null;
            try appendTowerEntry(&out, allocator, .{ .head = head, .label = label });
        }
        if (!splice_first) if (splice_head) |head| {
            try appendTowerEntry(&out, allocator, .{ .head = head, .label = self.currentInlineFn() });
        };
        for (self.implicit_receiver_tower.items) |entry| {
            try appendTowerEntry(&out, allocator, entry);
        }
        return try out.toOwnedSlice(allocator);
    }
    pub fn collectImplicitReceiverTower(
        self: *const FuncBuilder,
        allocator: Allocator,
        innermost: ?[]const u8,
    ) Allocator.Error![]const []const u8 {
        const entries = try self.collectReceiverTowerLabeled(allocator, innermost, null);
        defer allocator.free(entries);
        const out = try allocator.alloc([]const u8, entries.len);
        for (entries, out) |entry, *head| head.* = entry.head;
        return out;
    }
    pub fn selfLocalFn(self: *const FuncBuilder) ?ir.SelfLocalFn {
        return self.self_local_fn;
    }
    pub fn setSelfLocalFn(self: *FuncBuilder, v: ?ir.SelfLocalFn) void {
        self.self_local_fn = v;
    }
    /// The call's final argument came as a trailing lambda: bind it last.
    pub fn callTrailingLambda(self: *const FuncBuilder) bool {
        return self.cur_call_trailing;
    }
    pub fn setCallTrailingLambda(self: *FuncBuilder, on: bool) bool {
        const prev = self.cur_call_trailing;
        self.cur_call_trailing = on;
        return prev;
    }
    /// Takes ownership of `set`.
    pub fn setOwnMembers(self: *FuncBuilder, set: StringSet) void {
        self.own_members.deinit();
        self.own_members = set;
    }
    /// The caller's member scope, parked while a top-level-extension splice
    /// lowers its body in its own declaration scope. A caller lambda swaps back.
    pub const MemberScopeSnapshot = struct {
        own: StringSet,
        encl: StringSet,
        owner: ?[]const u8,
        prev: ?*MemberScopeSnapshot,
    };
    pub fn beginSpliceDeclScope(self: *FuncBuilder, snap: *MemberScopeSnapshot) void {
        snap.* = .{
            .own = self.own_members,
            .encl = self.enclosing_members,
            .owner = self.owner_class,
            .prev = self.caller_member_scope,
        };
        self.own_members = StringSet.init(self.allocator);
        self.enclosing_members = StringSet.init(self.allocator);
        self.owner_class = null;
        self.caller_member_scope = snap;
    }
    pub fn endSpliceDeclScope(self: *FuncBuilder, snap: *MemberScopeSnapshot) void {
        self.own_members.deinit();
        self.enclosing_members.deinit();
        self.own_members = snap.own;
        self.enclosing_members = snap.encl;
        self.owner_class = snap.owner;
        self.caller_member_scope = snap.prev;
    }
    pub const CallerScopeRestore = struct {
        own: StringSet,
        encl: StringSet,
        owner: ?[]const u8,
        snap: *MemberScopeSnapshot,
    };
    /// Null when no extension splice is active.
    pub fn enterCallerMemberScope(self: *FuncBuilder) Allocator.Error!?CallerScopeRestore {
        const snap = self.caller_member_scope orelse return null;
        const restore = CallerScopeRestore{
            .own = self.own_members,
            .encl = self.enclosing_members,
            .owner = self.owner_class,
            .snap = snap,
        };
        var own = StringSet.init(self.allocator);
        errdefer own.deinit();
        var oit = snap.own.keyIterator();
        while (oit.next()) |k| try own.put(k.*, {});
        var encl = StringSet.init(self.allocator);
        errdefer encl.deinit();
        var eit = snap.encl.keyIterator();
        while (eit.next()) |k| try encl.put(k.*, {});
        self.own_members = own;
        self.enclosing_members = encl;
        self.owner_class = snap.owner;
        self.caller_member_scope = snap.prev;
        return restore;
    }
    pub fn exitCallerMemberScope(self: *FuncBuilder, restore: CallerScopeRestore) void {
        self.own_members.deinit();
        self.enclosing_members.deinit();
        self.own_members = restore.own;
        self.enclosing_members = restore.encl;
        self.owner_class = restore.owner;
        self.caller_member_scope = restore.snap;
    }
    pub fn ownMembers(self: *const FuncBuilder) *const StringSet {
        return &self.own_members;
    }
    /// Takes ownership of `set`.
    pub fn setEnclosingMembers(self: *FuncBuilder, set: StringSet) void {
        self.enclosing_members.deinit();
        self.enclosing_members = set;
    }
    pub fn hasEnclosingMember(self: *const FuncBuilder, name: []const u8) bool {
        return self.own_members.contains(name) or self.enclosing_members.contains(name);
    }
    /// Union of `own_members` and `enclosing_members`; the caller owns the set.
    pub fn enclosingMembersForChild(self: *const FuncBuilder) Allocator.Error!StringSet {
        var out = try cloneStringSet(self.allocator, &self.own_members);
        errdefer out.deinit();
        var it = self.enclosing_members.keyIterator();
        while (it.next()) |k| try out.put(k.*, {});
        return out;
    }
    pub fn hasOwnMember(self: *const FuncBuilder, name: []const u8) bool {
        return self.own_members.contains(name);
    }
    /// Takes ownership of `map`.
    pub fn setOwnMemberArity(self: *FuncBuilder, map: std.StringHashMap(u64)) void {
        self.own_member_arity.deinit();
        self.own_member_arity = map;
    }
    /// Whether an own member named `name` could bind a call of `want` arguments;
    /// a name with no recorded mask is conservatively applicable.
    pub fn ownMemberApplicable(self: *const FuncBuilder, name: []const u8, want: usize) bool {
        const mask = self.own_member_arity.get(name) orelse return true;
        if (mask & (@as(u64, 1) << 63) != 0) return true; // a vararg overload
        if (want >= 62) return false;
        return mask & (@as(u64, 1) << @intCast(want)) != 0;
    }

    /// Whether an own FUNCTION member takes `want` arguments; a nested class or
    /// property does not count, so a constructor call keeps its own path.
    pub fn ownFunctionApplicable(self: *const FuncBuilder, name: []const u8, want: usize) bool {
        const mask = self.own_member_arity.get(name) orelse return false;
        if (mask & (@as(u64, 1) << 63) != 0) return true;
        if (want >= 62) return false;
        return mask & (@as(u64, 1) << @intCast(want)) != 0;
    }

    pub fn ownMemberAcceptsTypeArgs(self: *const FuncBuilder, name: []const u8) bool {
        const mask = self.own_member_arity.get(name) orelse return true;
        return mask & (@as(u64, 1) << 62) != 0;
    }
    /// Whether the class hierarchy declares a callable member taking `want` args.
    pub fn callableMemberApplicable(self: *const FuncBuilder, name: []const u8, want: usize) bool {
        if (self.own_member_arity.get(name)) |mask| {
            if (mask & (@as(u64, 1) << 63) != 0) return true;
            if (want >= 62) return false;
            return mask & (@as(u64, 1) << @intCast(want)) != 0;
        }
        const owner = self.owner_class orelse return false;
        const methods = self.module.registry.hierarchy_methods.get(owner) orelse return false;
        return methods.contains(name);
    }
    /// Swap in an `owner_class`/`own_members` pair for an inline splice's body.
    /// Ownership of `own_members` passes in, of the returned set back out.
    pub fn swapOwnerContext(
        self: *FuncBuilder,
        owner_class: ?[]const u8,
        own_members: StringSet,
    ) struct { class: ?[]const u8, members: StringSet } {
        const prev_class = self.owner_class;
        const prev_members = self.own_members;
        self.owner_class = owner_class;
        self.own_members = own_members;
        return .{ .class = prev_class, .members = prev_members };
    }
    pub fn restoreOwnerContext(
        self: *FuncBuilder,
        owner_class: ?[]const u8,
        own_members: StringSet,
    ) void {
        self.owner_class = owner_class;
        self.own_members.deinit();
        self.own_members = own_members;
    }
    pub fn setParamThunk(self: *FuncBuilder, on: bool) void {
        self.is_param_thunk = on;
    }
    pub fn isParamThunk(self: *const FuncBuilder) bool {
        return self.is_param_thunk;
    }
    pub fn setSelfDeclSpan(self: *FuncBuilder, sp: span_mod.Span) void {
        self.self_decl_span = sp;
    }
    pub fn recordLambdaArgArity(self: *FuncBuilder, sp: span_mod.Span, arity: i16) void {
        self.lambda_arg_arity.put(sp, arity) catch {};
    }

    pub fn lambdaArgArity(self: *const FuncBuilder, sp: span_mod.Span) ?i16 {
        return self.lambda_arg_arity.get(sp);
    }

    pub fn recordLambdaArgRecvOwned(
        self: *FuncBuilder,
        sp: span_mod.Span,
        receiver: TypeRef,
    ) Allocator.Error!void {
        if (std.c.getenv("KLIO_LAR_TRACE") != null) {
            std.debug.print("[lar-put] f={d} s={d}..{d} ty={s}\n", .{ sp.file.int(), sp.start, sp.end, receiver.name });
        }
        var owned = receiver;
        errdefer owned.deinit(self.allocator);
        if (try self.lambda_arg_recv.fetchPut(sp, owned)) |old| {
            var owned_old = old.value;
            owned_old.deinit(self.allocator);
        }
    }

    pub fn lambdaArgRecv(self: *const FuncBuilder, sp: span_mod.Span) ?TypeRef {
        if (std.c.getenv("KLIO_LAR_TRACE") != null) {
            std.debug.print("[lar-get] f={d} s={d}..{d} hit={}\n", .{ sp.file.int(), sp.start, sp.end, self.lambda_arg_recv.get(sp) != null });
        }
        return self.lambda_arg_recv.get(sp);
    }

    pub fn setBodySpan(self: *FuncBuilder, sp: span_mod.Span) void {
        self.body_span = sp;
    }
    pub fn setTailrecSelf(self: *FuncBuilder, name: []const u8) void {
        self.tailrec_self = name;
    }
    pub fn tailrecSelf(self: *const FuncBuilder) ?[]const u8 {
        return self.tailrec_self;
    }
    pub fn setTailrecSelfHasThis(self: *FuncBuilder, on: bool) void {
        self.tailrec_self_this = on;
    }
    pub fn tailrecSelfHasThis(self: *const FuncBuilder) bool {
        return self.tailrec_self_this;
    }
    pub fn setTailrecParams(self: *FuncBuilder, params: []const ast.Param) void {
        self.tailrec_params = params;
    }
    pub fn tailrecParams(self: *const FuncBuilder) []const ast.Param {
        return self.tailrec_params;
    }
    pub fn setLocalDeclType(self: *FuncBuilder, name: []const u8, ty: []const u8) Allocator.Error!void {
        const owned = try (TypeRef{
            .name = ty,
            .nullable = false,
            .args = &.{},
        }).clone(self.allocator);
        try self.setLocalDeclTypeOwned(name, owned);
        _ = self.local_init_exprs.remove(name);
    }
    /// A rebinding shadows an inherited record: a nested `it` is not the outer one.
    pub fn clearLocalDeclType(self: *FuncBuilder, name: []const u8) void {
        if (self.local_decl_types.fetchRemove(name)) |old| {
            var cleanup = old.value;
            cleanup.deinit(self.allocator);
        }
        _ = self.local_decl_nullable.remove(name);
        _ = self.local_call_returns.remove(name);
        _ = self.local_init_exprs.remove(name);
    }
    /// Takes ownership of `ty`.
    pub fn setLocalDeclTypeOwned(self: *FuncBuilder, name: []const u8, ty: TypeRef) Allocator.Error!void {
        if (std.c.getenv("KLIO_VALTY_TRACE")) |w| {
            if (std.mem.eql(u8, std.mem.span(w), name)) {
                std.debug.print("[valty] WRITE {s} = {s}\n", .{ name, ty.name });
                if (std.c.getenv("KLIO_VALTY_STACK") != null) {
                    std.debug.dumpCurrentStackTrace(.{});
                }
            }
        }
        var owned = ty;
        errdefer owned.deinit(self.allocator);
        if (try self.local_decl_types.fetchPut(name, owned)) |old| {
            var cleanup = old.value;
            cleanup.deinit(self.allocator);
        }
        _ = self.local_init_exprs.remove(name);
    }
    /// The local's declared type is nullable, which the head-name table cannot
    /// carry: the qualified-call tag must not constrain null-receiver dispatch.
    pub fn setLocalDeclNullable(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.local_decl_nullable.put(name, {});
    }
    pub fn localDeclNullable(self: *const FuncBuilder, name: []const u8) bool {
        return self.local_decl_nullable.contains(name);
    }
    pub fn localDeclTypesSnapshot(self: *const FuncBuilder) Allocator.Error!ir.PendingLocalDeclTypes {
        var types = std.StringHashMap(TypeRef).init(self.allocator);
        errdefer {
            var cleanup_it = types.valueIterator();
            while (cleanup_it.next()) |ty| ty.deinit(self.allocator);
            types.deinit();
        }
        var type_it = self.local_decl_types.iterator();
        while (type_it.next()) |entry| {
            const cloned = try entry.value_ptr.clone(self.allocator);
            errdefer {
                var cleanup = cloned;
                cleanup.deinit(self.allocator);
            }
            try types.put(entry.key_ptr.*, cloned);
        }
        var nullable = std.StringHashMap(void).init(self.allocator);
        errdefer nullable.deinit();
        var null_it = self.local_decl_nullable.keyIterator();
        while (null_it.next()) |name| try nullable.put(name.*, {});
        var call_returns = std.StringHashMap(ir.EagerTypeHead).init(self.allocator);
        errdefer call_returns.deinit();
        var return_it = self.local_call_returns.iterator();
        while (return_it.next()) |entry| try call_returns.put(entry.key_ptr.*, entry.value_ptr.*);
        return .{ .types = types, .nullable = nullable, .call_returns = call_returns };
    }
    pub fn inheritLocalDeclTypes(self: *FuncBuilder, inherited: *const ir.PendingLocalDeclTypes) Allocator.Error!void {
        var type_it = inherited.types.iterator();
        while (type_it.next()) |entry| {
            const cloned = try entry.value_ptr.clone(self.allocator);
            try self.setLocalDeclTypeOwned(entry.key_ptr.*, cloned);
        }
        var null_it = inherited.nullable.keyIterator();
        while (null_it.next()) |name| try self.local_decl_nullable.put(name.*, {});
        var return_it = inherited.call_returns.iterator();
        while (return_it.next()) |entry| try self.local_call_returns.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    pub fn setLocalCallReturn(self: *FuncBuilder, name: []const u8, ty: []const u8, nullable: bool) Allocator.Error!void {
        try self.local_call_returns.put(name, .{ .name = ty, .nullable = nullable });
    }
    pub fn localCallReturn(self: *const FuncBuilder, name: []const u8) ?ir.EagerTypeHead {
        return self.local_call_returns.get(name);
    }
    /// The local's type is a RECEIVER function type, so a bare call binds `this`.
    pub fn setLocalDeclRecvFn(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.local_decl_recv_fn.put(name, {});
    }
    pub fn localDeclRecvFn(self: *const FuncBuilder, name: []const u8) bool {
        return self.local_decl_recv_fn.contains(name);
    }
    pub fn setLocalInitExpr(self: *FuncBuilder, name: []const u8, e: *const ast.Expr) Allocator.Error!void {
        return self.setLocalInitExprAt(name, e, null);
    }

    pub fn setLocalInitExprAt(self: *FuncBuilder, name: []const u8, e: *const ast.Expr, decl_span: ?ast.Span) Allocator.Error!void {
        // Recorded before the local is bound, the scope its initializer was
        // written in. A prior pass's binding for the same span is self.
        const self_rebind = blk: {
            const sp = decl_span orelse break :blk false;
            const prior = self.local_init_decl_spans.get(name) orelse break :blk false;
            break :blk prior.file.int() == sp.file.int() and prior.start == sp.start and prior.end == sp.end;
        };
        if (self_rebind or
            (self.resolve(name) == null and !self.isLocalFn(name) and !self.knowsOuter(name)))
        {
            try self.local_init_name_free.put(name, {});
        } else {
            _ = self.local_init_name_free.remove(name);
        }
        if (decl_span) |sp| try self.local_init_decl_spans.put(name, sp);
        try self.local_init_exprs.put(name, e);
    }
    /// A smart cast narrows the subject's static type for the branch and Kotlin
    /// resolves extensions against it, so the local narrows and is restored.
    pub const NarrowedLocal = struct {
        name: []const u8,
        prev_ty: ?TypeRef,
        prev_nullable: bool,
    };

    pub fn narrowLocal(self: *FuncBuilder, name: []const u8, ty: []const u8) Allocator.Error!NarrowedLocal {
        const saved: NarrowedLocal = .{
            .name = name,
            .prev_ty = if (self.local_decl_types.fetchRemove(name)) |old| old.value else null,
            .prev_nullable = self.local_decl_nullable.contains(name),
        };
        try self.setLocalDeclType(name, ty);
        _ = self.local_decl_nullable.remove(name);
        return saved;
    }

    pub fn narrowLocalNotNull(self: *FuncBuilder, name: []const u8) Allocator.Error!?NarrowedLocal {
        const current = self.local_decl_types.get(name) orelse return null;
        const prev_nullable = self.local_decl_nullable.contains(name);
        var replacement = try current.clone(self.allocator);
        replacement.nullable = false;
        const old = self.local_decl_types.fetchPut(name, replacement) catch |err| {
            replacement.deinit(self.allocator);
            return err;
        };
        std.debug.assert(old != null);
        _ = self.local_decl_nullable.remove(name);
        return .{
            .name = name,
            .prev_ty = old.?.value,
            .prev_nullable = prev_nullable,
        };
    }

    pub fn restoreLocal(self: *FuncBuilder, saved: NarrowedLocal) void {
        if (self.local_decl_types.fetchRemove(saved.name)) |current| {
            var cleanup = current.value;
            cleanup.deinit(self.allocator);
        }
        if (saved.prev_ty) |t| {
            self.local_decl_types.put(saved.name, t) catch {
                var cleanup = t;
                cleanup.deinit(self.allocator);
            };
        }
        if (saved.prev_nullable) {
            self.local_decl_nullable.put(saved.name, {}) catch {};
        } else {
            _ = self.local_decl_nullable.remove(saved.name);
        }
    }

    pub fn localDeclType(self: *const FuncBuilder, name: []const u8) ?[]const u8 {
        return if (self.local_decl_types.get(name)) |ty| ty.name else null;
    }
    pub fn localDeclTypeCount(self: *const FuncBuilder) usize {
        return self.local_decl_types.count();
    }
    pub fn setLocalAstTy(self: *FuncBuilder, name: []const u8, ty: *const ast.TypeRef) void {
        self.local_ast_tys.put(name, ty) catch {};
    }
    pub fn localAstTy(self: *const FuncBuilder, name: []const u8) ?*const ast.TypeRef {
        return self.local_ast_tys.get(name);
    }

    pub fn localDeclTypeRef(self: *const FuncBuilder, name: []const u8) ?TypeRef {
        return self.local_decl_types.get(name);
    }
    pub fn localInitExprIterator(self: *const FuncBuilder) std.StringHashMap(*const ast.Expr).Iterator {
        return self.local_init_exprs.iterator();
    }
    pub fn localInitExpr(self: *const FuncBuilder, name: []const u8) ?*const ast.Expr {
        return self.local_init_exprs.get(name);
    }
    pub fn localInitNameFree(self: *const FuncBuilder, name: []const u8) bool {
        return self.local_init_name_free.contains(name);
    }

    pub fn markLocalFn(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.local_fns.put(name, {});
    }
    /// Positional parameter type names, leading `this` already dropped.
    pub fn setLocalFnParamTys(self: *FuncBuilder, name: []const u8, tys: []const ?[]const u8) Allocator.Error!void {
        const owned = try self.allocator.dupe(?[]const u8, tys);
        if (self.local_fn_param_tys.fetchPut(name, owned) catch null) |old| self.allocator.free(old.value);
    }
    pub fn localFnParamTys(self: *const FuncBuilder, name: []const u8) ?[]const ?[]const u8 {
        return self.local_fn_param_tys.get(name);
    }
    pub fn isLocalFn(self: *const FuncBuilder, name: []const u8) bool {
        return self.local_fns.contains(name);
    }
    /// Takes ownership of `ty`.
    pub fn setLocalFnReturnTy(self: *FuncBuilder, mangled: []const u8, ty: TypeRef) Allocator.Error!void {
        if (try self.local_fn_return_tys.fetchPut(mangled, ty)) |old| {
            var prev = old.value;
            prev.deinit(self.allocator);
        }
    }
    pub fn localFnReturnTy(self: *const FuncBuilder, mangled: []const u8) ?TypeRef {
        return self.local_fn_return_tys.get(mangled);
    }
    /// Takes ownership of `ov`'s slices, from this builder's allocator.
    pub fn addLocalFnOverload(self: *FuncBuilder, name: []const u8, ov: LocalFnOverload) Allocator.Error!void {
        const owned = ov;
        var appended = false;
        errdefer if (!appended) {
            if (owned.receiver_ty) |receiver| {
                var cleanup = receiver;
                cleanup.deinit(self.allocator);
            }
            self.allocator.free(owned.type_params);
            self.allocator.free(owned.param_tys);
            self.allocator.free(owned.param_names);
        };
        const gop = try self.local_fn_overloads.getOrPut(name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.allocator, owned);
        appended = true;
    }
    /// Every local-function declaration for `name`, in decl order: a local fun
    /// shadows an outer same-named function only for the calls it can take.
    pub fn localFnDecls(self: *const FuncBuilder, name: []const u8) ?[]const LocalFnOverload {
        const list = self.local_fn_overloads.getPtr(name) orelse return null;
        if (list.items.len == 0) return null;
        return list.items;
    }
    /// Decl order; null unless `name` was declared at least twice.
    pub fn localFnOverloads(self: *const FuncBuilder, name: []const u8) ?[]const LocalFnOverload {
        const list = self.local_fn_overloads.getPtr(name) orelse return null;
        if (list.items.len < 2) return null;
        return list.items;
    }
    /// Seed the overload table from an enclosing scope's, so a nested lambda
    /// selects among siblings. Slices are duplicated into this allocator.
    pub fn inheritLocalFnOverloads(self: *FuncBuilder, table: *const std.StringHashMap(std.ArrayList(LocalFnOverload))) Allocator.Error!void {
        var it = table.iterator();
        while (it.next()) |e| {
            const gop = try self.local_fn_overloads.getOrPut(e.key_ptr.*);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            for (e.value_ptr.items) |ov| {
                var dup = ov;
                var appended = false;
                // `mangled` is module-lifetime, so share it.
                dup.receiver_ty = if (ov.receiver_ty) |receiver|
                    try receiver.clone(self.allocator)
                else
                    null;
                errdefer if (!appended) if (dup.receiver_ty) |receiver| {
                    var cleanup = receiver;
                    cleanup.deinit(self.allocator);
                };
                dup.param_tys = try self.allocator.dupe(?[]const u8, ov.param_tys);
                errdefer if (!appended) self.allocator.free(dup.param_tys);
                dup.param_names = try self.allocator.dupe([]const u8, ov.param_names);
                errdefer if (!appended) self.allocator.free(dup.param_names);
                dup.type_params = try self.allocator.dupe(
                    ir.ModuleRegistry.TypeParamBound,
                    ov.type_params,
                );
                errdefer if (!appended) self.allocator.free(dup.type_params);
                try gop.value_ptr.append(self.allocator, dup);
                appended = true;
            }
        }
    }
    pub fn markLocalExtFn(self: *FuncBuilder, name: []const u8, arity: i8) Allocator.Error!void {
        try self.local_ext_fns.put(name, arity);
    }
    /// Value-parameter count, receiver excluded; null when unknown.
    pub fn localExtFnArity(self: *const FuncBuilder, name: []const u8) ?i8 {
        const a = self.local_ext_fns.get(name) orelse return null;
        return if (a >= 0) a else null;
    }
    pub fn isLocalExtFn(self: *const FuncBuilder, name: []const u8) bool {
        return self.local_ext_fns.contains(name);
    }
    /// A parameter whose declared function type has no receiver: only an
    /// extension-function type competes for `recv.name(args)`, so this cannot.
    pub fn markPlainFnParam(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.plain_fn_params.put(name, {});
    }
    pub fn isPlainFnParam(self: *const FuncBuilder, name: []const u8) bool {
        return self.plain_fn_params.contains(name);
    }
    /// A function-typed param a trailing-lambda call could bind to.
    pub fn markFnParamTakesTrailingLambda(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.fn_params_take_lambda.put(name, {});
    }
    pub fn fnParamTakesTrailingLambda(self: *const FuncBuilder, name: []const u8) bool {
        return self.fn_params_take_lambda.contains(name);
    }
    pub fn markReceiverLambdaParam(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.receiver_lambda_params.put(name, {});
    }
    /// Declared receiver head of a receiver-lambda param; null when unresolvable.
    pub fn setReceiverLambdaRecvHead(self: *FuncBuilder, name: []const u8, head: ?[]const u8) Allocator.Error!void {
        try self.receiver_lambda_recv_heads.put(self.allocator, name, head);
    }
    pub fn receiverLambdaRecvHead(self: *const FuncBuilder, name: []const u8) ?[]const u8 {
        return self.receiver_lambda_recv_heads.get(name) orelse null;
    }
    /// Stash the receiver-lambda head table on the module's pending slot so a
    /// nested lambda body inherits the heads, not just the names. No-op if empty.
    pub fn stashRecvHeadsForLambda(self: *FuncBuilder) Allocator.Error!void {
        if (self.receiver_lambda_recv_heads.count() == 0) return;
        const out = try self.allocator.alloc(ir.RecvHeadKV, self.receiver_lambda_recv_heads.count());
        var it = self.receiver_lambda_recv_heads.iterator();
        var i: usize = 0;
        while (it.next()) |e| : (i += 1) {
            out[i] = .{ .name = e.key_ptr.*, .head = e.value_ptr.* };
        }
        self.module.pending_lambda_recv_heads = out;
    }
    /// Declared non-receiver arity of a receiver-lambda param, disambiguating
    /// `f(x)`: at arity 0 the argument is the receiver, at arity 1 the parameter.
    pub fn markReceiverLambdaArity(self: *FuncBuilder, name: []const u8, n: usize) Allocator.Error!void {
        try self.receiver_lambda_arity.put(name, n);
    }
    pub fn receiverLambdaArity(self: *const FuncBuilder, name: []const u8) ?usize {
        return self.receiver_lambda_arity.get(name);
    }
    /// Param `name` has type `context(C..) (A..) -> R`; a positional call
    /// supplying `n_ctx + n_regular` arguments lowers to `CtxCall`.
    pub fn markContextFnParam(self: *FuncBuilder, name: []const u8, ctx_types: []const []const u8, n_regular: usize) Allocator.Error!void {
        try self.context_fn_params.put(name, .{ .n_ctx = ctx_types.len, .n_regular = n_regular, .ctx_types = ctx_types });
    }
    pub fn contextFnParam(self: *const FuncBuilder, name: []const u8) ?ContextFnShape {
        return self.context_fn_params.get(name);
    }
    /// Every contextual function-type parameter in scope; null when none.
    pub fn contextFnShapesSlice(self: *const FuncBuilder) Allocator.Error!?[]ir.PendingCtxFnShape {
        if (self.context_fn_params.count() == 0) return null;
        var out = try self.allocator.alloc(ir.PendingCtxFnShape, self.context_fn_params.count());
        var it = self.context_fn_params.iterator();
        var i: usize = 0;
        while (it.next()) |kv| : (i += 1) {
            out[i] = .{ .name = kv.key_ptr.*, .ctx_types = kv.value_ptr.ctx_types, .n_regular = kv.value_ptr.n_regular };
        }
        return out;
    }
    /// The outermost scope's binding for `name`, ignoring inner shadowing.
    pub fn resolveOutermost(self: *const FuncBuilder, name: []const u8) ?Reg {
        for (self.scopes.items) |*scope| {
            if (scope.get(name)) |r| return r;
        }
        return null;
    }
    pub fn isReceiverLambdaParam(self: *const FuncBuilder, name: []const u8) bool {
        return self.receiver_lambda_params.contains(name);
    }
    /// The caller owns the returned set.
    pub fn receiverLambdaParamNames(self: *const FuncBuilder) Allocator.Error!StringSet {
        return cloneStringSet(self.allocator, &self.receiver_lambda_params);
    }
    /// The innermost frame's substitution map, keyed by the inline fn's lambda params.
    pub fn innermostInlineLambdaSubst(self: *const FuncBuilder) ?*const std.StringHashMap(*const ast.Expr) {
        if (self.inline_lambda_subst.items.len == 0) return null;
        return &self.inline_lambda_subst.items[self.inline_lambda_subst.items.len - 1].subst;
    }
    /// Copies the names; the caller keeps ownership of `names`.
    pub fn inheritReceiverLambdaParams(self: *FuncBuilder, names: *const StringSet) Allocator.Error!void {
        var it = names.keyIterator();
        while (it.next()) |k| try self.receiver_lambda_params.put(k.*, {});
    }
    pub fn unmarkReceiverLambdaParam(self: *FuncBuilder, name: []const u8) void {
        _ = self.receiver_lambda_params.remove(name);
    }
    pub fn noteSpliceRlpMark(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.splice_rlp_marks.put(name, {});
    }
    /// An inline splice found `name` already marked by an enclosing splice:
    /// ownership is shared, so the caller-body suspension keeps the mark.
    pub fn noteSharedRlpMark(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.shared_rlp_marks.put(name, {});
    }
    pub fn clearSharedRlpMark(self: *FuncBuilder, name: []const u8) void {
        _ = self.shared_rlp_marks.remove(name);
    }
    pub fn isSharedRlpMark(self: *const FuncBuilder, name: []const u8) bool {
        return self.shared_rlp_marks.contains(name);
    }
    pub fn clearSpliceRlpMark(self: *FuncBuilder, name: []const u8) void {
        _ = self.splice_rlp_marks.remove(name);
    }
    pub fn isSpliceRlpMark(self: *const FuncBuilder, name: []const u8) bool {
        return self.splice_rlp_marks.contains(name);
    }
    /// The caller owns the returned set.
    pub fn localExtFnNames(self: *const FuncBuilder) Allocator.Error!std.StringHashMap(i8) {
        var out = std.StringHashMap(i8).init(self.allocator);
        var it = self.local_ext_fns.iterator();
        while (it.next()) |e| try out.put(e.key_ptr.*, e.value_ptr.*);
        return out;
    }
    /// Seed from an enclosing scope's set so a captured local ext fn called bare
    /// still gets the receiver prepended. Copies names; caller keeps ownership.
    pub fn inheritLocalExtFns(self: *FuncBuilder, names: *const std.StringHashMap(i8)) Allocator.Error!void {
        var it = names.iterator();
        while (it.next()) |e| try self.local_ext_fns.put(e.key_ptr.*, e.value_ptr.*);
    }
    pub fn markNonFnLocal(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.nonfn_locals.put(name, {});
    }
    /// A nearer declaration with callable evidence clears the inherited mark.
    pub fn clearNonFnLocal(self: *FuncBuilder, name: []const u8) void {
        _ = self.nonfn_locals.remove(name);
    }
    pub fn isNonFnLocal(self: *const FuncBuilder, name: []const u8) bool {
        return self.nonfn_locals.contains(name);
    }
    pub fn nonFnLocalNames(self: *const FuncBuilder) Allocator.Error!StringSet {
        return cloneStringSet(self.allocator, &self.nonfn_locals);
    }
    /// Copies the names; the caller keeps ownership.
    pub fn inheritNonFnLocals(self: *FuncBuilder, names: *const StringSet) Allocator.Error!void {
        var it = names.keyIterator();
        while (it.next()) |k| try self.nonfn_locals.put(k.*, {});
    }
    /// The function declares its own type parameters, so a comparison on operands
    /// with no concrete static type dispatches `compareTo`, not IEEE.
    pub fn setHasOwnTypeParams(self: *FuncBuilder, on: bool) void {
        self.has_own_type_params = on;
    }
    pub fn hasOwnTypeParams(self: *const FuncBuilder) bool {
        return self.has_own_type_params;
    }
    /// A non-reified type-parameter name in scope; a cast to it is unchecked.
    pub fn addTypeParamName(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.type_param_names.put(name, {});
    }
    pub fn addTypeParamBound(
        self: *FuncBuilder,
        name: []const u8,
        bound: []const u8,
    ) Allocator.Error!void {
        return self.addTypeParamBoundEvidence(name, bound, true);
    }
    pub fn addTypeParamBoundEvidence(
        self: *FuncBuilder,
        name: []const u8,
        bound: []const u8,
        complete: bool,
    ) Allocator.Error!void {
        return self.addTypeParamBoundHead(name, bound, complete, complete);
    }
    pub fn addTypeParamBoundHead(
        self: *FuncBuilder,
        name: []const u8,
        bound: []const u8,
        complete: bool,
        head_only: bool,
    ) Allocator.Error!void {
        return self.addTypeParamBoundHeadArgs(name, bound, complete, head_only, &.{});
    }
    /// `bound_args`: the bound's concrete type-argument heads, registry-lifetime.
    pub fn addTypeParamBoundHeadArgs(
        self: *FuncBuilder,
        name: []const u8,
        bound: []const u8,
        complete: bool,
        head_only: bool,
        bound_args: []const []const u8,
    ) Allocator.Error!void {
        try self.type_param_names.put(name, {});
        try self.type_param_bounds.put(name, .{
            .param = name,
            .bound = bound,
            .complete = complete,
            .head_only = head_only,
            .args = bound_args,
        });
    }
    pub fn addOwnedTypeParamBoundEvidence(
        self: *FuncBuilder,
        name: []u8,
        bound: []const u8,
        complete: bool,
    ) Allocator.Error!void {
        try self.owned_type_param_names.append(self.allocator, name);
        errdefer {
            _ = self.owned_type_param_names.pop();
            self.allocator.free(name);
        }
        try self.addTypeParamBoundHead(name, bound, complete, complete);
    }
    pub fn ownTypeParamText(
        self: *FuncBuilder,
        text: []u8,
    ) Allocator.Error![]const u8 {
        errdefer self.allocator.free(text);
        try self.owned_type_param_names.append(self.allocator, text);
        return text;
    }
    /// Declared upper bound of type parameter `name`: Kotlin resolves a member
    /// call on a type-parameter-typed value against it, naming a class at all.
    pub fn typeParamBound(self: *const FuncBuilder, name: []const u8) ?ir.ModuleRegistry.TypeParamBound {
        return self.type_param_bounds.get(name);
    }
    /// Bind a spliced inline callee's type-parameter bound for the splice window:
    /// its param types reach the caller through `spliceParamTy`, whose head names
    /// nothing without it. Returns what the caller restores on exit.
    pub const SpliceBoundRestore = struct {
        name: []const u8,
        prev_bound: ?ir.ModuleRegistry.TypeParamBound,
        was_name: bool,
    };
    pub fn bindSpliceTypeParamBound(
        self: *FuncBuilder,
        name: []const u8,
        bound: ir.ModuleRegistry.TypeParamBound,
    ) Allocator.Error!SpliceBoundRestore {
        const prev = self.type_param_bounds.get(name);
        const was_name = self.type_param_names.contains(name);
        try self.type_param_names.put(name, {});
        try self.type_param_bounds.put(name, bound);
        return .{ .name = name, .prev_bound = prev, .was_name = was_name };
    }
    pub fn restoreSpliceTypeParamBound(self: *FuncBuilder, r: SpliceBoundRestore) void {
        if (r.prev_bound) |p| {
            self.type_param_bounds.put(r.name, p) catch {};
        } else {
            _ = self.type_param_bounds.remove(r.name);
        }
        if (!r.was_name) _ = self.type_param_names.remove(r.name);
    }
    /// Takes ownership of `ref`.
    pub fn addTypeParamBoundRef(self: *FuncBuilder, name: []const u8, ref: TypeRef) Allocator.Error!void {
        if (try self.type_param_bound_refs.fetchPut(name, ref)) |old| {
            var stale = old.value;
            stale.deinit(self.allocator);
        }
    }
    pub fn typeParamBoundRef(self: *const FuncBuilder, name: []const u8) ?*const TypeRef {
        return self.type_param_bound_refs.getPtr(name);
    }

    /// Owned snapshot, for a pending lambda or local-fn body to inherit.
    pub fn typeParamBoundRefsSlice(
        self: *const FuncBuilder,
    ) Allocator.Error!?[]ir.PendingBoundRef {
        if (self.type_param_bound_refs.count() == 0) return null;
        var out = try self.allocator.alloc(ir.PendingBoundRef, self.type_param_bound_refs.count());
        var filled: usize = 0;
        errdefer {
            for (out[0..filled]) |*r| r.ref.deinit(self.allocator);
            self.allocator.free(out);
        }
        var it = self.type_param_bound_refs.iterator();
        while (it.next()) |entry| {
            out[filled] = .{
                .param = entry.key_ptr.*,
                .ref = try entry.value_ptr.clone(self.allocator),
            };
            filled += 1;
        }
        return out;
    }

    pub fn typeParamBoundsSlice(
        self: *const FuncBuilder,
    ) Allocator.Error!?[]const ir.ModuleRegistry.TypeParamBound {
        if (self.type_param_bounds.count() == 0) return null;
        const out = try self.allocator.alloc(
            ir.ModuleRegistry.TypeParamBound,
            self.type_param_bounds.count(),
        );
        var it = self.type_param_bounds.iterator();
        var index: usize = 0;
        while (it.next()) |entry| : (index += 1) {
            out[index] = entry.value_ptr.*;
        }
        return out;
    }
    pub fn isTypeParam(self: *const FuncBuilder, name: []const u8) bool {
        return self.type_param_names.contains(name);
    }
    /// Freshly allocated; null when there are none.
    pub fn typeParamNamesSlice(self: *const FuncBuilder) Allocator.Error!?[]const []const u8 {
        if (self.type_param_names.count() == 0) return null;
        var out = try self.allocator.alloc([]const u8, self.type_param_names.count());
        var it = self.type_param_names.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| : (i += 1) out[i] = k.*;
        return out;
    }
    /// Snapshot for a lambda body lowered inside the active splice.
    pub fn reifiedTypeNamesSlice(self: *const FuncBuilder) Allocator.Error!?[]const ir.ReifiedName {
        if (self.reified_type_names.count() == 0) return null;
        var out = try self.allocator.alloc(ir.ReifiedName, self.reified_type_names.count());
        var it = self.reified_type_names.iterator();
        var i: usize = 0;
        while (it.next()) |e| : (i += 1) out[i] = .{ .name = e.key_ptr.*, .actual = e.value_ptr.* };
        return out;
    }
    pub fn markGenericTypedParam(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.generic_typed_params.put(name, {});
    }
    pub fn isGenericTypedParam(self: *const FuncBuilder, name: []const u8) bool {
        return self.generic_typed_params.contains(name);
    }
    /// A parameter typed by an unbounded type parameter: its type has no members.
    pub fn markErasedRecvParam(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.erased_recv_params.put(name, {});
    }
    pub fn isErasedRecvParam(self: *const FuncBuilder, name: []const u8) bool {
        return self.erased_recv_params.contains(name);
    }
    pub fn erasedRecvParamNames(self: *const FuncBuilder) Allocator.Error!StringSet {
        return cloneStringSet(self.allocator, &self.erased_recv_params);
    }
    pub fn inheritErasedRecvParams(self: *FuncBuilder, names: *const StringSet) Allocator.Error!void {
        var it = names.keyIterator();
        while (it.next()) |k| try self.erased_recv_params.put(k.*, {});
    }
    pub fn markNonFnParam(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.non_fn_params.put(name, {});
    }
    pub fn isNonFnParam(self: *const FuncBuilder, name: []const u8) bool {
        return self.non_fn_params.contains(name);
    }
    pub fn clearGenericTypedParam(self: *FuncBuilder, name: []const u8) void {
        _ = self.generic_typed_params.remove(name);
    }
    /// Returns the shadowed binding so the splice restores it on exit.
    pub fn bindReifiedType(self: *FuncBuilder, name: []const u8, reg: Reg) Allocator.Error!?Reg {
        const prev = self.reified_type_binds.get(name);
        try self.reified_type_binds.put(name, reg);
        return prev;
    }
    pub fn restoreReifiedType(self: *FuncBuilder, name: []const u8, prev: ?Reg) void {
        if (prev) |r| {
            self.reified_type_binds.put(name, r) catch {};
        } else {
            _ = self.reified_type_binds.remove(name);
        }
    }
    pub fn resolveReifiedType(self: *const FuncBuilder, name: []const u8) ?Reg {
        return self.reified_type_binds.get(name);
    }
    pub fn bindReifiedTypeName(self: *FuncBuilder, name: []const u8, actual: []const u8) Allocator.Error!?[]const u8 {
        const prev = self.reified_type_names.get(name);
        try self.reified_type_names.put(name, actual);
        return prev;
    }
    pub fn restoreReifiedTypeName(self: *FuncBuilder, name: []const u8, prev: ?[]const u8) void {
        if (prev) |v| {
            self.reified_type_names.put(name, v) catch {};
        } else {
            _ = self.reified_type_names.remove(name);
        }
    }
    pub fn resolveReifiedTypeName(self: *const FuncBuilder, name: []const u8) ?[]const u8 {
        return self.reified_type_names.get(name);
    }
    pub fn bindSpliceParamTy(self: *FuncBuilder, name: []const u8, ty: ast.TypeRef) Allocator.Error!?ast.TypeRef {
        const prev = self.splice_param_tys.get(name);
        try self.splice_param_tys.put(name, ty);
        return prev;
    }
    pub fn restoreSpliceParamTy(self: *FuncBuilder, name: []const u8, prev: ?ast.TypeRef) void {
        if (prev) |t| {
            self.splice_param_tys.put(name, t) catch {};
        } else {
            _ = self.splice_param_tys.remove(name);
        }
    }
    pub fn spliceParamTy(self: *const FuncBuilder, name: []const u8) ?ast.TypeRef {
        return self.splice_param_tys.get(name);
    }
    pub fn spliceParamTyIterator(self: *const FuncBuilder) std.StringHashMap(ast.TypeRef).Iterator {
        return self.splice_param_tys.iterator();
    }
    pub fn pushFinally(self: *FuncBuilder, block: ast.Block, body_entry: BlockId) Allocator.Error!void {
        try self.finally_stack.append(self.allocator, block);
        try self.finally_body_stack.append(self.allocator, body_entry);
        try self.finally_window_stack.append(self.allocator, .{
            .window = self.lambda_splice_resolve,
            .bands_len = self.splice_hidden_bands.items.len,
        });
    }
    pub fn popFinally(self: *FuncBuilder) void {
        _ = self.finally_stack.pop();
        _ = self.finally_body_stack.pop();
        _ = self.finally_window_stack.pop();
    }
    pub fn finallyWindowsSnapshot(self: *const FuncBuilder) Allocator.Error![]FinallyWindow {
        return self.allocator.dupe(FinallyWindow, self.finally_window_stack.items);
    }
    /// Try-region body-entry ids for the finallys at `finally_stack[from..]`,
    /// the frames an inline `return` based at `from` pops when it jumps.
    pub fn finallyBodiesFrom(self: *const FuncBuilder, from: usize) Allocator.Error![]BlockId {
        const items = self.finally_body_stack.items;
        const start = @min(from, items.len);
        return self.allocator.dupe(BlockId, items[start..]);
    }
    pub fn pushCatchBody(self: *FuncBuilder, body_entry: BlockId) Allocator.Error!void {
        try self.catch_body_stack.append(self.allocator, body_entry);
    }
    pub fn popCatchBody(self: *FuncBuilder) void {
        _ = self.catch_body_stack.pop();
    }
    /// Catch-only try body-entry ids opened since `from`, for an inline `return`.
    pub fn catchBodiesFrom(self: *const FuncBuilder, from: usize) Allocator.Error![]BlockId {
        const items = self.catch_body_stack.items;
        const start = @min(from, items.len);
        return self.allocator.dupe(BlockId, items[start..]);
    }
    /// Append `bodies` to a block's `pop_on_exit` list, keeping what is there.
    pub fn appendPopOnExit(self: *FuncBuilder, block: BlockId, bodies: []const BlockId) Allocator.Error!void {
        if (bodies.len == 0) return;
        const existing = self.blocks.items[block.int()].pop_on_exit;
        const merged = try self.allocator.alloc(BlockId, existing.len + bodies.len);
        @memcpy(merged[0..existing.len], existing);
        @memcpy(merged[existing.len..], bodies);
        self.blocks.items[block.int()].pop_on_exit = merged;
    }
    /// The try bodies whose `TryFrame` the runtime pops when `block` gotos out.
    pub fn setPopOnExit(self: *FuncBuilder, block: BlockId, bodies: []const BlockId) void {
        self.blocks.items[block.int()].pop_on_exit = bodies;
    }
    /// The caller owns the returned slice.
    pub fn activeFinallys(self: *const FuncBuilder) Allocator.Error![]ast.Block {
        return self.allocator.dupe(ast.Block, self.finally_stack.items);
    }
    /// Takes ownership of `replacement`; returns the previous stack, owned.
    pub fn swapFinallyStack(self: *FuncBuilder, replacement: []ast.Block) Allocator.Error![]ast.Block {
        const prev = try self.finally_stack.toOwnedSlice(self.allocator);
        self.finally_stack = .empty;
        try self.finally_stack.appendSlice(self.allocator, replacement);
        self.allocator.free(replacement);
        return prev;
    }
    pub fn markParam(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.param_names.put(name, {});
    }
    pub fn isParam(self: *const FuncBuilder, name: []const u8) bool {
        return self.param_names.contains(name);
    }

    /// Whether a plain binding of `name` shadows the delegated-local binding
    /// `dname` (`name$klio_delegate`): true when the `resolve`-order walk meets a
    /// scope holding `name` without `dname` first. The declaring scope holds both.
    pub fn plainShadowsDelegate(self: *const FuncBuilder, name: []const u8, dname: []const u8) bool {
        if (self.lambda_splice_resolve) |w| {
            const top = self.scopes.items.len;
            var i = top;
            while (i > w.own_base) {
                i -= 1;
                const m = &self.scopes.items[i];
                if (m.get(dname) != null) return false;
                if (m.get(name) != null) return true;
            }
            var j = @min(w.caller_depth, top);
            while (j > 0) {
                j -= 1;
                var banded = false;
                for (self.splice_hidden_bands.items) |band| {
                    if (j >= band.lo and j <= band.hi) {
                        banded = true;
                        break;
                    }
                }
                if (banded) continue;
                const m = &self.scopes.items[j];
                if (m.get(dname) != null) return false;
                if (m.get(name) != null) return true;
            }
            return false;
        }
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const m = &self.scopes.items[i];
            if (m.get(dname) != null) return false;
            if (m.get(name) != null) return true;
        }
        return false;
    }

    /// `resolve` without the splice body floor, reaching the receiver beneath a
    /// splice subject, which the callee body itself must not see.
    pub fn resolveIgnoringFloor(self: *const FuncBuilder, name: []const u8) ?Reg {
        if (self.lambda_splice_resolve != null) return self.resolve(name);
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].get(name)) |r| return r;
        }
        return null;
    }

    pub fn resolve(self: *const FuncBuilder, name: []const u8) ?Reg {
        // The inline fn's parameter scopes are not in a spliced lambda's
        // lexical scope: search its own scopes, then the caller scopes.
        if (self.lambda_splice_resolve) |w| {
            const top = self.scopes.items.len;
            var i = top;
            while (i > w.own_base) {
                i -= 1;
                if (self.scopes.items[i].get(name)) |r| return r;
            }
            var j = @min(w.caller_depth, top);
            while (j > 0) {
                j -= 1;
                // An index an enclosing splice window hides stays hidden here.
                var banded = false;
                for (self.splice_hidden_bands.items) |band| {
                    if (j >= band.lo and j <= band.hi) {
                        banded = true;
                        break;
                    }
                }
                if (banded) continue;
                if (self.scopes.items[j].get(name)) |r| return r;
            }
            return null;
        }
        var i = self.scopes.items.len;
        const stop = self.splice_body_floor orelse 0;
        while (i > stop) {
            i -= 1;
            if (self.scopes.items[i].get(name)) |r| return r;
        }
        return null;
    }

    /// Takes ownership of `catches`.
    pub fn attachCatches(
        self: *FuncBuilder,
        block: BlockId,
        catches: []CatchHandler,
        finally: ?BlockId,
    ) void {
        const cur = block.int();
        if (self.blocks.items[cur].catches.len != 0) self.allocator.free(self.blocks.items[cur].catches);
        self.blocks.items[cur].catches = catches;
        self.blocks.items[cur].finally = finally;
    }

    /// Mark `join` as the normal-flow exit of the catch-only try entered at
    /// `body_entry`, so the eval pops that `TryFrame` when control arrives.
    pub fn setCatchDoneFor(self: *FuncBuilder, body_entry: BlockId, join: BlockId) void {
        self.blocks.items[join.int()].catch_done_for = body_entry;
    }

    /// Arm `region` to absorb a labeled return for the inline function `label`: a
    /// `LabeledReturn` for it jumps to `handler` with the value in `value_reg`.
    /// Normal flow into `handler` pops the region's frame via `catch_done_for`.
    pub fn setLrAbsorb(self: *FuncBuilder, region: BlockId, label: []const u8, handler: BlockId, value_reg: Reg) void {
        self.blocks.items[region.int()].lr_absorb = .{ .label = label, .handler = handler, .value_reg = value_reg };
        self.blocks.items[handler.int()].catch_done_for = region;
    }

    /// Mark `done` as the post-finally sentinel for the try at `body_entry`.
    pub fn setFinallyDoneFor(self: *FuncBuilder, body_entry: BlockId, done: BlockId) void {
        self.blocks.items[body_entry.int()].finally_done = done;
        self.blocks.items[done.int()].finally_done_for = body_entry;
    }

    /// Protect a catch-handler block with the try's `finally`, so a throw from the
    /// catch runs it and re-raises past `done`, the shared post-finally sentinel.
    /// The handler keeps no catches of its own.
    pub fn protectCatchWithFinally(self: *FuncBuilder, catch_block: BlockId, finally_entry: BlockId, done: BlockId) void {
        self.blocks.items[catch_block.int()].finally = finally_entry;
        self.blocks.items[catch_block.int()].finally_done = done;
    }

    /// Ascending; the caller owns the returned slice.
    pub fn capturedRegs(self: *const FuncBuilder) Allocator.Error![]Reg {
        var out: std.ArrayList(Reg) = .empty;
        defer out.deinit(self.allocator);
        var seen = std.AutoHashMap(u32, void).init(self.allocator);
        defer seen.deinit();
        for (self.scopes.items) |*frame| {
            var it = frame.valueIterator();
            while (it.next()) |r| {
                const gop = try seen.getOrPut(r.int());
                if (!gop.found_existing) try out.append(self.allocator, r.*);
            }
        }
        const slice = try out.toOwnedSlice(self.allocator);
        std.sort.pdq(Reg, slice, {}, struct {
            fn less(_: void, a: Reg, b: Reg) bool {
                return a.int() < b.int();
            }
        }.less);
        return slice;
    }

    /// Names visible across the live scope chain. The caller owns the set.
    pub fn visibleNames(self: *const FuncBuilder) Allocator.Error!StringSet {
        var out = StringSet.init(self.allocator);
        for (self.scopes.items) |*frame| {
            var it = frame.keyIterator();
            while (it.next()) |k| try out.put(k.*, {});
        }
        // Enclosing-scope captures are reachable by walking the capture chain.
        var oit = self.outer_names.keyIterator();
        while (oit.next()) |k| try out.put(k.*, {});
        // A local class or anonymous object closes over them as well.
        for (lower_anon_capture_names) |n| try out.put(n, {});
        return out;
    }

    /// Temporarily remove `name`'s innermost binding, hiding an inline fn's own
    /// parameter from a spliced caller-lambda body. Null when unbound.
    pub fn hideBinding(self: *FuncBuilder, name: []const u8) ?HiddenBinding {
        var i: usize = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].fetchRemove(name)) |kv| {
                return .{ .frame = i, .reg = kv.value };
            }
        }
        return null;
    }
    pub fn restoreHiddenBinding(self: *FuncBuilder, name: []const u8, h: HiddenBinding) void {
        if (h.frame < self.scopes.items.len) {
            self.scopes.items[h.frame].put(name, h.reg) catch {};
        }
    }

    pub fn pushScope(self: *FuncBuilder) Allocator.Error!void {
        try self.scopes.append(self.allocator, StringRegMap.init(self.allocator));
        try self.mutable_undo.append(self.allocator, .empty);
    }

    pub fn popScope(self: *FuncBuilder) Allocator.Error!void {
        if (self.scopes.pop()) |frame| {
            var f = frame;
            f.deinit();
        }
        if (self.scopes.items.len == 0) {
            try self.scopes.append(self.allocator, StringRegMap.init(self.allocator));
        }
        if (self.mutable_undo.pop()) |undos| {
            var u = undos;
            var i = u.items.len;
            while (i > 0) {
                i -= 1;
                const e = u.items[i];
                if (e.prev_home) |h| {
                    try self.mutable_homes.put(e.name, h);
                } else {
                    _ = self.mutable_homes.remove(e.name);
                }
                if (e.prev_mutable) {
                    try self.mutables.put(e.name, {});
                } else {
                    _ = self.mutables.remove(e.name);
                }
            }
            u.deinit(self.allocator);
        }
    }

    pub fn allocReg(self: *FuncBuilder) Reg {
        const r = Reg.from(self.next_reg);
        self.next_reg += 1;
        return r;
    }

    pub fn allocBlock(self: *FuncBuilder) Allocator.Error!BlockId {
        const id = BlockId.from(@intCast(self.blocks.items.len));
        try self.blocks.append(self.allocator, .{
            .id = id,
            .insts = &.{},
            .terminator = .Unreachable,
        });
        return id;
    }

    pub fn switchTo(self: *FuncBuilder, b: BlockId) void {
        self.cur = b;
    }

    /// `KLIO_EMIT_TRACE=<name>`: report every Call/CallMember/CallMemberOrGlobal
    /// pushed for that simple name. Cached once.
    fn emitTraceWant() ?[]const u8 {
        const S = struct {
            var checked: bool = false;
            var value: ?[]const u8 = null;
        };
        if (!S.checked) {
            S.checked = true;
            if (std.c.getenv("KLIO_EMIT_TRACE")) |v| S.value = std.mem.span(v);
        }
        return S.value;
    }

    threadlocal var push_trace_checked: bool = false;
    threadlocal var gf_trace: ?[]const u8 = null;
    threadlocal var lg_trace: ?[]const u8 = null;
    fn pushTraceInit() void {
        if (push_trace_checked) return;
        push_trace_checked = true;
        if (std.c.getenv("KLIO_GF_TRACE")) |w| gf_trace = std.mem.span(w);
        if (std.c.getenv("KLIO_LG_TRACE")) |w| lg_trace = std.mem.span(w);
    }

    pub fn push(self: *FuncBuilder, inst: Inst) Allocator.Error!void {
        // KLIO_GF_TRACE=<field> / KLIO_LG_TRACE=<name>: print the emitter of a
        // field read or global load; the return address symbolizes with addr2line.
        pushTraceInit();
        if (inst == .GetField) {
            if (gf_trace) |w| {
                const cs = self.module.consts.items;
                const nm = if (inst.GetField.field.int() < cs.len and cs[inst.GetField.field.int()] == .String) cs[inst.GetField.field.int()].String else "?";
                if (std.mem.eql(u8, w, nm)) std.debug.print("[gf] {s} recv=r{d} in={s} ret=0x{x}\n", .{ nm, inst.GetField.receiver.int(), currentRealFn() orelse "-", @returnAddress() });
            }
        }
        if (inst == .LoadGlobal) {
            if (lg_trace) |w| {
                const cs = self.module.consts.items;
                const nm = if (inst.LoadGlobal.name.int() < cs.len and cs[inst.LoadGlobal.name.int()] == .String) cs[inst.LoadGlobal.name.int()].String else "?";
                if (std.mem.eql(u8, w, nm)) std.debug.print("[lg] {s} ret=0x{x}\n", .{ nm, @returnAddress() });
            }
        }
        if (emitTraceWant()) |want| {
            switch (inst) {
                .Call => |c| {
                    if (self.module.funcById(c.func)) |f| {
                        if (std.mem.eql(u8, want, "*") or std.mem.eql(u8, f.name, want)) std.debug.print("[emit] Call fqn={s} fid={d} in_fn={s}\n", .{ f.fqn, c.func.int(), currentRealFn() orelse "-" });
                    }
                },
                .CallVirtual => |c| {
                    if (self.module.funcById(FuncId.from(c.slot.int()))) |f| {
                        if (std.mem.eql(u8, want, "*") or std.mem.eql(u8, f.name, want))
                            std.debug.print("[emit] CallVirtual root={s} slot={d} in_fn={s}\n", .{ f.fqn, c.slot.int(), currentRealFn() orelse "-" });
                    }
                },
                .CallMember => |c| {
                    if (c.name.int() < self.module.consts.items.len) {
                        switch (self.module.consts.items[c.name.int()]) {
                            .String => |n| if (std.mem.eql(u8, n, want)) {
                                std.debug.print("[emit] CallMember name={s} in_fn={s}\n", .{ n, currentRealFn() orelse "-" });
                                // `KLIO_EMIT_STACK`: name the emitting arm.
                                if (std.c.getenv("KLIO_EMIT_STACK") != null) {
                                    std.debug.dumpCurrentStackTrace(.{});
                                }
                            },
                            else => {},
                        }
                    }
                },
                .CallMemberOrGlobal => |c| {
                    if (c.name.int() < self.module.consts.items.len) {
                        switch (self.module.consts.items[c.name.int()]) {
                            .String => |n| if (std.mem.eql(u8, n, want)) std.debug.print("[emit] CallMemberOrGlobal name={s} func={?d} in_fn={s}\n", .{ n, if (c.func) |ff| ff.int() else null, currentRealFn() orelse "-" }),
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }
        const cur = self.cur.int();
        const block = &self.blocks.items[cur];
        const old = block.insts;
        const new = try self.allocator.alloc(Inst, old.len + 1);
        @memcpy(new[0..old.len], old);
        new[old.len] = inst;
        if (old.len != 0) self.allocator.free(old);
        block.insts = new;
    }

    /// Copy-coalescing peephole run once at `finish`: an instruction defining a
    /// single-use, single-def temp followed by `Move{dst = H, src = temp}` in the
    /// same block writes H directly. Register counts come from `visitInstRegs`.
    fn fuseSingleUseMoves(self: *FuncBuilder, blocks: []ir.Block) void {
        const n = self.next_reg;
        if (n == 0) return;
        const uses = self.allocator.alloc(u32, n) catch return;
        defer self.allocator.free(uses);
        const defs = self.allocator.alloc(u32, n) catch return;
        defer self.allocator.free(defs);
        @memset(uses, 0);
        @memset(defs, 0);
        const Counter = struct {
            uses: []u32,
            defs: []u32,
            fn cb(c: @This(), r: ir.Reg, is_def: bool) void {
                const i = r.int();
                if (i >= c.uses.len) return;
                if (is_def) c.defs[i] += 1 else c.uses[i] += 1;
            }
        };
        const counter = Counter{ .uses = uses, .defs = defs };
        for (blocks) |*blk| {
            for (blk.insts) |*inst| ir.visitInstRegs(inst, counter, Counter.cb);
            ir.visitTerminatorRegs(&blk.terminator, counter, Counter.cb);
        }
        for (blocks) |*blk| {
            if (blk.insts.len < 2) continue;
            var w: usize = 0;
            var i: usize = 0;
            var fused_any = false;
            while (i < blk.insts.len) : (i += 1) {
                var inst = blk.insts[i];
                if (i + 1 < blk.insts.len and blk.insts[i + 1] == .Move) fuse: {
                    const mv = blk.insts[i + 1].Move;
                    const t = mv.src.int();
                    if (t >= n or uses[t] != 1 or defs[t] != 1) break :fuse;
                    if (mv.dst.int() == t) break :fuse;
                    const d = instDefOf(&inst) orelse break :fuse;
                    if (d.int() != t) break :fuse;
                    if (!ir.setInstDst(&inst, mv.dst)) break :fuse;
                    blk.insts[w] = inst;
                    w += 1;
                    i += 1; // the Move is gone
                    fused_any = true;
                    continue;
                }
                blk.insts[w] = inst;
                w += 1;
            }
            if (!fused_any) continue;
            // Exact-size reallocation: the slice frees by its allocated length,
            // so an in-place shrink would corrupt a size-checked allocator.
            const out = self.allocator.alloc(ir.Inst, w) catch continue;
            @memcpy(out, blk.insts[0..w]);
            self.allocator.free(blk.insts);
            blk.insts = out;
        }
    }

    pub fn terminate(self: *FuncBuilder, t: Terminator) void {
        const cur = self.cur.int();
        self.blocks.items[cur].terminator = t;
    }

    pub fn emitConst(self: *FuncBuilder, c: Const) Allocator.Error!Reg {
        const dst = self.allocReg();
        const id = try self.module.internConst(self.allocator, c);
        try self.push(.{ .Const = .{ .dst = dst, .value = id } });
        return dst;
    }

    /// Record a just-emitted forwarded-literal AstLambda as a dead-code candidate:
    /// the current block's tail inst whose dst is `r`. A mismatch records nothing.
    pub fn noteForwardedLambda(self: *FuncBuilder, r: Reg, sp: span_mod.Span) void {
        if (self.cur.int() >= self.blocks.items.len) return;
        const blk = &self.blocks.items[self.cur.int()];
        if (blk.insts.len == 0) return;
        const last = &blk.insts[blk.insts.len - 1];
        if (last.* != .AstLambda or last.AstLambda.dst != r) return;
        self.pending_fwd_lambdas.append(self.allocator, .{
            .block = self.cur,
            .idx = @intCast(blk.insts.len - 1),
            .reg = r,
            .span = sp,
        }) catch {};
    }

    /// Nop every recorded forwarded-literal AstLambda whose register no
    /// instruction or terminator reads, its uses having been consumed by nested
    /// call-position splices. Runs just before the blocks are sealed.
    fn elideDeadForwardedLambdas(self: *FuncBuilder) void {
        if (self.pending_fwd_lambdas.items.len == 0) return;
        const Scan = struct {
            reg: Reg,
            hit: *bool,
            fn cb(c: @This(), r: ir.Reg, is_def: bool) void {
                if (!is_def and r == c.reg) c.hit.* = true;
            }
        };
        for (self.pending_fwd_lambdas.items) |cand| {
            if (cand.block.int() >= self.blocks.items.len) continue;
            const cblk = &self.blocks.items[cand.block.int()];
            if (cand.idx >= cblk.insts.len) continue;
            const inst = &cblk.insts[cand.idx];
            if (inst.* != .AstLambda or inst.AstLambda.dst != cand.reg) continue;
            var read = false;
            outer: for (self.blocks.items, 0..) |*blk, bi| {
                for (blk.insts, 0..) |*in2, ii| {
                    if (bi == cand.block.int() and ii == cand.idx) continue;
                    ir.visitInstRegs(in2, Scan{ .reg = cand.reg, .hit = &read }, Scan.cb);
                    if (read) break :outer;
                }
                ir.visitTerminatorRegs(&blk.terminator, Scan{ .reg = cand.reg, .hit = &read }, Scan.cb);
                if (read) break :outer;
            }
            if (!read) inst.* = .{ .Trace = .{ .span = cand.span } };
        }
        self.pending_fwd_lambdas.clearRetainingCapacity();
    }

    /// The block list is handed off into the returned `Func` and the builder's
    /// `blocks` are cleared, so a later `deinit` does not double-free them.
    pub fn finish(
        self: *FuncBuilder,
        name: []const u8,
        fqn: []const u8,
        return_ty: TypeRef,
    ) Allocator.Error!Func {
        self.elideDeadForwardedLambdas();
        const n_locals = self.next_reg;
        const blocks = try self.blocks.toOwnedSlice(self.allocator);
        self.fuseSingleUseMoves(blocks);
        self.blocks = .empty;
        const capture_order = try self.allocator.dupe([]const u8, self.capture_order.items);
        return Func{
            .id = FuncId.from(0), // assigned by the caller when adding to Module
            .name = name,
            .fqn = fqn,
            .params = &.{},
            .return_ty = return_ty,
            .n_locals = n_locals,
            .blocks = blocks,
            .entry = BlockId.from(0),
            .is_suspend = false,
            .is_tailrec = self.tailrec_self != null,
            .is_lambda = false,
            .is_inline = self.is_inline,
            .capture_order = capture_order,
            .implicit_label = null,
            .low_priority = false,
            // The declaring package in effect for this lowering. Explicit decl
            // paths overwrite it after `finish`; the synthetic paths (init blocks,
            // thunks, lambda bodies) keep it and so resolve their own internals.
            .package = lower_self_package,
        };
    }
};

/// The `dst` register an instruction defines, when its variant has one.
fn instDefOf(inst: *const ir.Inst) ?ir.Reg {
    const Finder = struct {
        found: *?ir.Reg,
        fn cb(c: @This(), r: ir.Reg, is_def: bool) void {
            if (is_def and c.found.* == null) c.found.* = r;
        }
    };
    var found: ?ir.Reg = null;
    ir.visitInstRegs(inst, Finder{ .found = &found }, Finder.cb);
    return found;
}

/// One name's pre-declaration mutability state, restored when its scope pops.
pub const MutableUndo = struct {
    name: []const u8,
    prev_home: ?MutableHome,
    prev_mutable: bool,
};

pub const FwdLambda = struct {
    block: BlockId,
    idx: u32,
    reg: Reg,
    span: span_mod.Span,
};

pub const SubjectBind = struct {
    reg: Reg,
    head: ?[]const u8,
    /// The scope `this` visible just before this subject bound.
    prior_this: ?Reg,
};

pub const LoopFrame = struct {
    label: ?[]const u8,
    /// Pushed while lowering an inline function's own body, so a non-local
    /// `break`/`continue` in a lambda passed to it skips the frame.
    from_inline_fn_body: bool = false,
    continue_target: BlockId,
    /// Depth of `catch_body_stack` at loop entry; a jump out leaves those tries.
    catch_base: usize = 0,
    /// Spliced-subject tower depth at loop entry: a `break`/`continue` out of a
    /// spliced receiver-lambda region jumps past its `EnclosingPop`, so the
    /// per-iteration push must be unwound or it leaks a chain entry per pass.
    encl_tower_base: u32 = 0,
    break_target: BlockId,
    /// Depth of `finally_stack` at loop entry; a jump replays the finallys above.
    finally_base: usize = 0,
};

/// Fresh owned set sharing `src`'s borrowed key slices.
fn cloneStringSet(allocator: Allocator, src: *const StringSet) Allocator.Error!StringSet {
    var out = StringSet.init(allocator);
    var it = src.keyIterator();
    while (it.next()) |k| try out.put(k.*, {});
    return out;
}

pub fn typeUnit() TypeRef {
    return .{ .name = "kotlin.Unit", .nullable = false, .args = &.{} };
}
pub fn typeNothing() TypeRef {
    return .{ .name = "kotlin.Nothing", .nullable = false, .args = &.{} };
}
pub fn typeInt() TypeRef {
    return .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
}
pub fn typeLong() TypeRef {
    return .{ .name = "kotlin.Long", .nullable = false, .args = &.{} };
}
pub fn typeBool() TypeRef {
    return .{ .name = "kotlin.Boolean", .nullable = false, .args = &.{} };
}
pub fn typeString() TypeRef {
    return .{ .name = "kotlin.String", .nullable = false, .args = &.{} };
}

const testing = std.testing;

/// Free a test `Func`: its per-block slices, the block list, capture names.
fn freeFunc(func: Func) void {
    for (func.blocks) |b| {
        if (b.insts.len != 0) testing.allocator.free(b.insts);
        if (b.catches.len != 0) testing.allocator.free(b.catches);
    }
    testing.allocator.free(func.blocks);
    if (func.capture_order.len != 0) testing.allocator.free(func.capture_order);
}

test {
    testing.refAllDecls(@This());
}

test "alloc_reg increments" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const r0 = b.allocReg();
    const r1 = b.allocReg();
    try testing.expectEqual(@as(u32, 0), r0.int());
    try testing.expectEqual(@as(u32, 1), r1.int());
}

test "bind and resolve through scope chain" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const p = b.allocReg();
    try b.bind("x", p);
    try testing.expectEqual(p, b.resolve("x").?);
    try testing.expect(b.resolve("y") == null);
}

test "rebind updates the frame holding the name" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const r0 = b.allocReg();
    try b.bind("n", r0);
    try b.pushScope();
    const r1 = b.allocReg();
    try b.rebind("n", r1);
    try b.popScope();
    try testing.expectEqual(r1, b.resolve("n").?);
}

test "alloc_block extends the block list" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    try testing.expectEqual(@as(usize, 1), b.blocks.items.len);
    const nb = try b.allocBlock();
    try testing.expectEqual(@as(u32, 1), nb.int());
    try testing.expectEqual(@as(usize, 2), b.blocks.items.len);
}

test "push appends instructions to the current block" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const r = try b.emitConst(.{ .Int = 7 });
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "test.f", typeInt());
    defer freeFunc(func);
    try testing.expectEqual(@as(usize, 1), func.blocks[0].insts.len);
    try testing.expect(func.blocks[0].insts[0] == .Const);
}

test "record_capture is idempotent" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const idx_a = try b.recordCapture("a");
    const idx_b = try b.recordCapture("b");
    const idx_a_again = try b.recordCapture("a");
    try testing.expectEqual(@as(u16, 0), idx_a);
    try testing.expectEqual(@as(u16, 1), idx_b);
    try testing.expectEqual(@as(u16, 0), idx_a_again);
    try testing.expectEqual(@as(usize, 2), b.capturesTaken().len);
}

test "captured local type metadata transfers to a lambda builder" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var outer = try FuncBuilder.init(testing.allocator, &m);
    defer outer.deinit();
    try outer.setLocalDeclType("scope", "CoroutineScope");
    try outer.setLocalDeclNullable("scope");
    var snapshot = try outer.localDeclTypesSnapshot();
    defer {
        var type_it = snapshot.types.valueIterator();
        while (type_it.next()) |ty| ty.deinit(testing.allocator);
        snapshot.types.deinit();
        snapshot.nullable.deinit();
        snapshot.call_returns.deinit();
    }

    var inner = try FuncBuilder.init(testing.allocator, &m);
    defer inner.deinit();
    try inner.inheritLocalDeclTypes(&snapshot);
    try testing.expectEqualStrings("CoroutineScope", inner.localDeclType("scope").?);
    try testing.expect(inner.localDeclNullable("scope"));
}

test "not-null narrowing preserves and restores the declared type" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    var args = [_]TypeRef{.{ .name = "String", .nullable = false, .args = &.{} }};
    try b.setLocalDeclTypeOwned(
        "record",
        try (TypeRef{ .name = "Box", .nullable = true, .args = &args }).clone(testing.allocator),
    );
    try b.setLocalDeclNullable("record");

    const saved = (try b.narrowLocalNotNull("record")).?;
    try testing.expect(!b.localDeclTypeRef("record").?.nullable);
    try testing.expectEqualStrings("String", b.localDeclTypeRef("record").?.args[0].name);
    try testing.expect(!b.localDeclNullable("record"));

    b.restoreLocal(saved);
    try testing.expect(b.localDeclTypeRef("record").?.nullable);
    try testing.expectEqualStrings("String", b.localDeclTypeRef("record").?.args[0].name);
    try testing.expect(b.localDeclNullable("record"));
}

test "loop frame lookup by label and innermost" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const c0 = try b.allocBlock();
    const e0 = try b.allocBlock();
    try b.pushLoop("outer", c0, e0);
    const c1 = try b.allocBlock();
    const e1 = try b.allocBlock();
    try b.pushLoop(null, c1, e1);
    try testing.expectEqual(c1, b.loopFor(null).?.continue_target);
    try testing.expectEqual(c0, b.loopFor("outer").?.continue_target);
    try testing.expect(b.loopFor("missing") == null);
}

test "a block-scoped var stops shadowing mutables when its scope pops" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    try b.pushScope();
    const home = b.allocReg();
    try b.setMutableHome("x", home);
    try b.markMutable("x");
    try testing.expectEqual(home, b.mutableHome("x").?);
    try testing.expect(b.isMutable("x"));
    try b.popScope();
    try testing.expect(b.mutableHome("x") == null);
    try testing.expect(!b.isMutable("x"));
}

test "an inner shadowing var restores the outer var's home on scope pop" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    try b.pushScope();
    const outer_home = b.allocReg();
    try b.setMutableHome("x", outer_home);
    try b.markMutable("x");
    try b.pushScope();
    const inner_home = b.allocReg();
    try b.setMutableHome("x", inner_home);
    try testing.expectEqual(inner_home, b.mutableHome("x").?);
    try b.popScope();
    try testing.expectEqual(outer_home, b.mutableHome("x").?);
    try testing.expect(b.isMutable("x"));
    try b.popScope();
    try testing.expect(b.mutableHome("x") == null);
}

test "a nested splice window keeps an enclosing window's band hidden" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    // A `let` block spliced inside a spliced `fastForEach` action lambda: the
    // inner window's caller region reaches past s1, which the outer band hides.
    const fn_this = b.allocReg();
    try b.bind("this", fn_this); // s0
    try b.pushScope(); // s1: outer inline fn's receiver bind
    const outer_recv = b.allocReg();
    try b.bind("this", outer_recv);
    try b.splice_hidden_bands.append(testing.allocator, .{ .lo = 1, .hi = 1 });
    try b.pushScope(); // s2: action lambda params
    const scope_param = b.allocReg();
    try b.bind("scope", scope_param);
    try b.pushScope(); // s3: inner inline fn's receiver bind
    const inner_recv = b.allocReg();
    try b.bind("this", inner_recv);
    try b.pushScope(); // s4: let block's own scope
    b.lambda_splice_resolve = .{ .caller_depth = 3, .own_base = 4 };
    try testing.expectEqual(fn_this, b.resolve("this").?);
    try testing.expectEqual(scope_param, b.resolve("scope").?);
    b.lambda_splice_resolve = null;
    _ = b.splice_hidden_bands.pop();
    try testing.expectEqual(inner_recv, b.resolve("this").?);
}

test "finish carries tailrec and inline flags" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    b.setTailrecSelf("f");
    b.setInline(true);
    const func = try b.finish("f", "test.f", typeUnit());
    defer freeFunc(func);
    try testing.expect(func.is_tailrec);
    try testing.expect(func.is_inline);
}

