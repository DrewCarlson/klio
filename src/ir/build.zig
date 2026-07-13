//! Builders for assembling an IR `Func` block-by-block.
//!
//! The lowering pass in `lower` uses these to emit instructions. Kept
//! separate from the type definitions so the lowering surface is small
//! enough to skim.

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
const StringFuncIdMap = std.StringHashMap(FuncId);

/// Per inline-fn-splice frame: a lambda-param substitution map paired
/// with the `inline_return` snapshot taken when the frame was pushed.
const InlineLambdaFrame = struct {
    subst: std.StringHashMap(*const ast.Expr),
    snapshot: []InlineReturn,
    /// Scope count at the inline call site, before the inline fn's
    /// parameters were bound. A lambda argument spliced from this frame
    /// was defined in the caller, so its free names must resolve in the
    /// caller's scopes (`[0, caller_scope_depth)`) plus the spliced
    /// lambda's own params — never against the inline fn's parameter
    /// scopes, whose names would otherwise shadow a same-named caller
    /// variable the lambda body references.
    caller_scope_depth: usize,
};

/// One `(result reg, join block)` entry on the `inline_return` stack:
/// a `return` inside an inlined body assigns the result and jumps to
/// the join (the inline call's value).
pub const InlineReturn = struct {
    reg: Reg,
    join: BlockId,
};

/// One labeled-return target for a spliced inline-argument lambda:
/// `return@<inlineFnName>` inside such a lambda is a local return
/// from the lambda invocation (its value), not a return of the caller.
pub const InlineLambdaRet = struct {
    label: []const u8,
    reg: Reg,
    end: BlockId,
};

/// Per-function builder. Owns a fresh register counter, the list of
/// blocks, and a "current block" cursor that the lowering pass
/// appends to. Carries a simple scope stack so the lowering pass
/// can resolve `Path { name }` reads against function parameters
/// and locally introduced bindings.
/// Declaring package of the decl whose body/initializer/thunk is being
/// lowered. Seeded by the build driver per top-level decl (functions,
/// classes — including accessors, init blocks and ctor thunks — and
/// top-level properties) and read by every `FuncBuilder` on init, so the
/// symbol index always keys on the caller's package. `""` is the
/// no-package case.
threadlocal var lower_self_package: []const u8 = "";

/// Install the caller package for subsequently-created builders. Returns
/// the previous value so a nested lowering restores it on exit.
pub fn setLowerSelfPackage(pkg: []const u8) []const u8 {
    const prev = lower_self_package;
    lower_self_package = pkg;
    return prev;
}

/// Per-file top-level property renames: span FileId -> (simple name ->
/// renamed global name). Kotlin scopes a `private` top-level property to
/// its declaring file and gives same-named top-level properties in
/// different packages distinct storage, but the lowered globals table is
/// flat, so the build driver renames colliding declarations (per-file
/// mangle for `private`, declaring-FQN slots across packages) and bare
/// references resolve through the reference's own span file (an
/// inline-spliced body keeps its declaring file's spans, so a splice
/// still reads the right file's property).
pub const FilePrivateRenames = std.AutoHashMap(u32, std.StringHashMap([]const u8));

threadlocal var lower_file_private_renames: ?*const FilePrivateRenames = null;

/// Install the per-file property rename table for the duration of
/// a lowering pass. Returns the previous value for restoration.
pub fn setLowerFilePrivateRenames(m: ?*const FilePrivateRenames) ?*const FilePrivateRenames {
    const prev = lower_file_private_renames;
    lower_file_private_renames = m;
    return prev;
}

/// The renamed global name for `name` referenced from `file`, when that
/// file resolves it to a renamed top-level property.
pub fn filePrivateRename(name: []const u8, file: u32) ?[]const u8 {
    const m = lower_file_private_renames orelse return null;
    const inner = m.get(file) orelse return null;
    return inner.get(name);
}

/// Per-file rename table for file-private top-level FUNCTIONS: two files in one
/// package each declaring `private fun debugLog(...)` are file-scoped in Kotlin,
/// but klio's function namespace is flat, so identical signatures would look
/// like conflicting overloads. Each is mangled per file and its declaring
/// file's bare calls rewrite to it.
threadlocal var lower_file_private_func_renames: ?*const FilePrivateRenames = null;

/// Install the per-file function rename table for a lowering pass.
pub fn setLowerFilePrivateFuncRenames(m: ?*const FilePrivateRenames) ?*const FilePrivateRenames {
    const prev = lower_file_private_func_renames;
    lower_file_private_func_renames = m;
    return prev;
}

/// The renamed function name for a bare call to `name` from `file`, when that
/// file resolves it to a mangled file-private top-level function.
pub fn filePrivateFuncRename(name: []const u8, file: u32) ?[]const u8 {
    const m = lower_file_private_func_renames orelse return null;
    const inner = m.get(file) orelse return null;
    return inner.get(name);
}

/// File-keyed type renames: span FileId -> (simple type name -> mangled
/// lift name). Kotlin scopes a file-`private` top-level class or
/// typealias to its declaring file; the build driver mangles one whose
/// simple name another file also claims as a type, and references —
/// value-position heads and type positions (`as` / `is` / supertypes) —
/// rewrite through the reference's own span file.
/// The name of the REAL (named) function whose body is currently being
/// lowered — the lexical target of a bare `return` inside an argument
/// lambda. Kotlin only permits such a return toward an inline callee, and
/// its meaning is "return from the function the lambda is WRITTEN in";
/// when that inline function runs as a real frame (a cross-pack /
/// image-deferred body the splicer could not flatten), the return must
/// unwind exactly to that frame, not to whichever HOF boundary absorbs an
/// untargeted non-local return first.
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

/// The owner class of the REAL function whose body is lowering, visible to
/// nested lambda builders (which carry no owner of their own) — the
/// receiver-function-typed property flag resolves through it.
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

pub const FileTypeRenames = std.AutoHashMap(u32, std.StringHashMap([]const u8));

threadlocal var lower_file_type_renames: ?*const FileTypeRenames = null;

/// Install the per-file type rename table for the duration of a lowering
/// pass. Returns the previous value for restoration.
pub fn setLowerFileTypeRenames(m: ?*const FileTypeRenames) ?*const FileTypeRenames {
    const prev = lower_file_type_renames;
    lower_file_type_renames = m;
    return prev;
}

/// The mangled lift name for the type `name` referenced from `file`, when
/// that file declares it as a renamed file-private class or typealias.
pub fn fileTypeRename(name: []const u8, file: u32) ?[]const u8 {
    const m = lower_file_type_renames orelse return null;
    const inner = m.get(file) orelse return null;
    return inner.get(name);
}

/// The whole per-file type rename map for `file`, for callers that
/// flatten the visible renames (the `BuildObject` scope snapshot).
pub fn fileTypeRenamesFor(file: u32) ?*const std.StringHashMap([]const u8) {
    const m = lower_file_type_renames orelse return null;
    return m.getPtr(file);
}

/// Package-scoped type renames: an `internal` top-level classifier whose
/// simple name collides with another top-level in the combined image
/// lifts mangled, and every file OF ITS PACKAGE resolves the bare name
/// through this map (the file map cannot serve same-package cross-file
/// references; cross-package references name it through imports, which
/// resolve by FQN and keep the source name via the fqn override).
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

/// Scope-true renames carried into a runtime anon-object member-body
/// lowering: the lexical site's flattened rename snapshot from the
/// `BuildObject` instruction. Installed around the side-module lowering
/// and consulted by `scopeTypeRename` after the (empty) chain walk.
threadlocal var lower_anon_scope_renames: []const ir.ScopeRename = &.{};

/// Install the anon-scope rename snapshot. Returns the previous value
/// for restoration.
pub fn setLowerAnonScopeRenames(rs: []const ir.ScopeRename) []const ir.ScopeRename {
    const prev = lower_anon_scope_renames;
    lower_anon_scope_renames = rs;
    return prev;
}

/// The currently-installed anon-scope rename snapshot (empty outside an
/// anon-object member-body lowering).
pub fn anonScopeRenames() []const ir.ScopeRename {
    return lower_anon_scope_renames;
}

/// The rename for `name` in the installed anon-scope snapshot; first
/// entry wins (nearer scopes were flattened first).
pub fn anonScopeRename(name: []const u8) ?[]const u8 {
    for (lower_anon_scope_renames) |r| {
        if (std.mem.eql(u8, r.name, name)) return r.renamed;
    }
    return null;
}

/// One same-named local-function declaration: the mangled binding its
/// closure is ALSO bound under, plus the static signature facts a call
/// site selects on. Slices are owned by the declaring builder's allocator.
pub const LocalFnOverload = struct {
    mangled: []const u8,
    /// Positional param type heads, leading `this` receiver dropped;
    /// null where the parameter is a vararg.
    param_tys: []const ?[]const u8,
    param_names: []const []const u8,
    /// Parameters without defaults — a call must supply at least this many.
    n_required: usize,
    has_vararg: bool,
};

/// The split of a param's contextual function type `context(C..) (A..) -> R`
/// into its context-parameter count and ordinary-parameter count.
pub const ContextFnShape = struct { n_ctx: usize, n_regular: usize };

pub const FuncBuilder = struct {
    allocator: Allocator,
    module: *Module,
    blocks: std.ArrayList(Block) = .empty,
    cur: BlockId,
    next_reg: u32,
    /// Scope stack. The bottom frame holds the function's parameter
    /// bindings; lowering pushes a fresh frame per block expression
    /// so val/var declarations are popped correctly.
    scopes: std.ArrayList(StringRegMap) = .empty,
    /// Names visible to the function but living in an enclosing
    /// frame. Lowering a lambda body seeds these from the outer
    /// `FuncBuilder`'s scope chain; references to them lower as
    /// `LoadCapture` insts and record the capture-name so the
    /// lambda-construction site knows which outer registers to
    /// snapshot.
    outer_names: StringSet,
    capture_order: std.ArrayList([]const u8) = .empty,
    capture_regs: StringRegMap,
    /// Loop context stack. Each frame names the loop's continue
    /// target (header / latch) and break target (exit). The frame's
    /// optional `label` matches an explicit `break@label` /
    /// `continue@label`; bare jumps target the innermost frame.
    loops: std.ArrayList(LoopFrame) = .empty,
    /// Names declared as `var` (mutable) in any live scope. `val`
    /// bindings are absent. Used by compound-assignment lowering to
    /// pick between rebind (Path target on a `var`) and plusAssign
    /// dispatch (Path target on a `val`).
    mutables: StringSet,
    /// `var` locals each get a permanent "home" register. Reads of
    /// the local always resolve to this reg; writes emit a Move
    /// into it. This gives the IR's flat block model the slot
    /// semantics that mutable Kotlin locals need.
    mutable_homes: StringRegMap,
    /// Names that are boxed into a shared `Value.Cell` because a
    /// nested lambda captures them (Kotlin `Ref` boxing). Their home
    /// reg holds the `Cell`; reads emit `CellGet`, writes `CellSet`,
    /// and the declaration emits `MakeCell`.
    boxed_vars: StringSet,
    /// Locals declared with an `: Any` (or other erased) type
    /// annotation — used by the `==` lowering to detect a boxed
    /// operand the same way the tree walker does.
    any_typed_locals: StringSet,
    /// Names (params, lambda params, locals) whose declared static type is a
    /// broad read-only collection — `Iterable`, `Collection`, or their
    /// `Mutable*` forms — through which a runtime `Set` may flow. Kotlin's
    /// `Iterable`/`Collection` `plus`/`minus` return a `List` regardless of the
    /// runtime element container, so the operator lowering coerces such a
    /// receiver to a list first (a `Set` receiver would otherwise dispatch the
    /// `Set`-returning `plus`/`minus`).
    broad_coll_locals: StringSet,
    /// Locals whose initializer is an `object : T {}` expression. Kept apart
    /// from `local_init_exprs` (which feeds receiver-type inference) so that
    /// recording an object initializer for overload-applicability checks does
    /// not perturb inline receiver narrowing.
    object_init_locals: StringSet,
    /// When the function is a class method, the simple name of
    /// the owning class. Used by `super.method()` lowering to
    /// emit `Inst.CallSuper` with the right starting class.
    owner_class: ?[]const u8 = null,
    /// Declaring package of the function currently being lowered
    /// (`""` for a user script). The symbol index keys bare-call
    /// preference on this so a same-named function in the caller's
    /// own package wins over an imported / stdlib sibling.
    self_package: []const u8 = "",
    /// Declared receiver-type name of the enclosing *extension* function
    /// (`fun Source.forEach(...)` → `"Source"`). Lets bare-call resolution
    /// prefer a same-named extension overload whose `this`-param type
    /// matches the enclosing receiver instead of an arity-only pick.
    /// `null` for plain functions and class methods.
    recv_ty: ?[]const u8 = null,
    splice_recv_ty: ?[]const u8 = null,
    /// See `callTrailingLambda`.
    cur_call_trailing: bool = false,
    /// Names declared on the owning class (methods, body
    /// properties, primary-ctor properties). Used by method-
    /// body lowering to know whether an unqualified `foo(...)`
    /// is `this.foo(...)` (a class member) or a global lookup.
    own_members: StringSet,
    /// Per own-member NAME: a bitmask of the argument counts its overload
    /// set can accept (bit `i` set ⇒ some overload binds `i` user args; bit
    /// 63 ⇒ a vararg overload accepts any count at/above its fixed prefix).
    /// Lets `prefer_member` be arity-aware: a 0-arg member must not suppress
    /// a same-named 1-arg top-level function. A name absent from the map (or
    /// a non-function member like a property) stays conservatively
    /// "applicable", preserving prior behavior.
    own_member_arity: std.StringHashMap(u64),
    /// Member names of the lexically enclosing class, carried into a
    /// lambda body. Unlike `own_members` this never reroutes a bare
    /// reference through `this.<member>`; it only lets an enclosing
    /// member out-prioritise a same-named imported extension.
    enclosing_members: StringSet,
    /// Private methods of `owner_class` that have already been
    /// lowered (so their `FuncIds` are known). A bare call resolving
    /// to a name in this map binds statically to the listed `FuncId`
    /// rather than virtual-dispatching.
    private_method_fids: StringFuncIdMap,
    /// When the function is `tailrec`, the simple name of the
    /// function itself. Self-calls are lowered as `Terminator.TailJump`
    /// to keep the stack flat across recursion.
    tailrec_self: ?[]const u8 = null,
    /// The AST name-span of the declaration this builder lowers — the
    /// eager seam refuses a typeck pick that resolves a call back to the
    /// ENCLOSING declaration when the lazy engine chose otherwise (a
    /// self-delegating overload mis-picked as self recurses forever).
    self_decl_span: ?span_mod.Span = null,
    /// The AST block span of the lambda/fn body this builder lowers —
    /// the key into the eager receiver-head channel.
    body_span: ?span_mod.Span = null,
    /// Whether the tailrec function carries an implicit leading `this`
    /// param (instance method / extension). A bare recursive call keeps
    /// the same receiver, so the tail jump's arg run must lead with it.
    tailrec_self_this: bool = false,
    /// Names bound as parameters at the function entry (set by
    /// `bind_params`). Used by call-site lowering to recognise
    /// when an identifier-as-callee is a function-typed param.
    param_names: StringSet,
    /// Names declared as *local functions* (`fun foo() …` inside a
    /// body). A `recv.foo()` call resolves to such a local — but a
    /// local `val`/`var` of the same name must NOT hijack member-call
    /// syntax.
    local_fns: StringSet,
    /// Per local function: the declared parameter type-name per positional
    /// parameter (an extension's leading `this` is dropped), so a numeric
    /// literal argument can coerce to a Byte/Short/Long/Float/Double parameter
    /// at the call site, as it does for top-level functions.
    local_fn_param_tys: std.StringHashMap([]const ?[]const u8),
    /// Subset of `local_fns` declared as extensions (`fun R.f(...)`);
    /// a bare call must prepend the implicit receiver as `this`.
    local_ext_fns: StringSet,
    /// Per local-fn NAME: one entry per same-named declaration, in decl
    /// order. Each overload's closure is additionally bound under a
    /// mangled name so a call site can select the right sibling — the
    /// plain name keeps last-decl-wins binding for unresolvable calls.
    local_fn_overloads: std.StringHashMap(std.ArrayList(LocalFnOverload)),
    /// Declared type annotation per local (`val resp: HttpResponse`),
    /// used by inline-overload receiver narrowing.
    local_decl_types: std.StringHashMap([]const u8),
    local_decl_nullable: std.StringHashMap(void),
    local_decl_recv_fn: std.StringHashMap(void),
    /// Recorded initializer expression per un-annotated local, so the
    /// narrowing can infer a type from the init call's return type. The
    /// AST outlives the lowering pass.
    local_init_exprs: std.StringHashMap(*const ast.Expr),
    /// Params whose declared type is a receiver-typed function
    /// (`block: T.() -> R`). A bare call `block(...)` on one of these
    /// must dispatch with the enclosing `this` as the implicit
    /// receiver.
    receiver_lambda_params: StringSet,
    receiver_lambda_arity: std.StringHashMap(usize),
    context_fn_params: std.StringHashMap(ContextFnShape),
    /// Params (and locals) whose declared type is an unconstrained
    /// generic type-parameter (`T` of a `fun <T : Comparable<T>>`).
    /// Kotlin desugars a comparison operator on such an operand to
    /// `a.compareTo(b) <op> 0` — the total order, unlike the IEEE
    /// primitive operators.
    generic_typed_params: StringSet,
    /// See `markErasedRecvParam`.
    erased_recv_params: StringSet,
    /// Params whose declared type is a concrete NON-function type (not a
    /// function type, not a bare generic type-parameter). Such a param does
    /// NOT shadow a same-named top-level function for a *call*: kotlinc
    /// resolves `flow { … }` to the `flow {}` builder, not a `flow: Flow<T>`
    /// parameter, because a `Flow` is not invokable. A bare call to one of
    /// these names defers to the function-resolution path.
    non_fn_params: StringSet,
    /// Reified type-parameter names bound by an in-progress inline
    /// splice, each mapped to the register holding the resolved class
    /// value. A nested splice whose call-site type argument names an
    /// enclosing splice's reified parameter (`trySuspend<TaskType>(...)`
    /// inside a spliced `sleepWhile<reified TaskType>` body) chains
    /// through this instead of a global lookup of the parameter name.
    reified_type_binds: StringRegMap,
    /// Splice-scoped reified type-parameter NAME substitutions (`T` ->
    /// `E`), recorded alongside `reified_type_binds` so nested calls in
    /// the spliced body can be stamped with static type args.
    reified_type_names: std.StringHashMap([]const u8),
    /// Splice-scoped param-name -> declared type (with the splice's
    /// reified substitutions applied). A nested reified inline call whose
    /// argument is a spliced parameter (`it.dispatchForKind(type, block)`
    /// inside a spliced `visitNodes` body) infers its own type parameter
    /// from this lexical record — the argument expression alone carries
    /// no type evidence.
    splice_param_tys: std.StringHashMap(ast.TypeRef),
    /// Stack of user `finally { … }` blocks (innermost on top) whose
    /// lexical scope encloses the current cursor. A `return X` reached
    /// during inline expansion replays each finally body inline before
    /// exiting.
    finally_stack: std.ArrayList(ast.Block) = .empty,
    is_lambda_body: bool,
    is_anon_fn_body: bool,
    is_named_local_fn: bool,
    is_inline: bool,
    /// True while lowering a default-argument thunk. A default
    /// expression executes in the declaring function's scope, not as
    /// a member of the (extension) receiver.
    is_param_thunk: bool,
    /// This lambda body declared no parameters and was lowered without an
    /// implicit `it` binding, because its functional type takes zero
    /// parameters (a `() -> R` or a `T.() -> R` receiver lambda). An `it`
    /// reference that resolves to nothing here is an unresolved reference,
    /// matching kotlinc, rather than a silent null.
    it_suppressed: bool = false,
    /// The binding named `this` in this frame is an ordinary user parameter
    /// (a backtick-quoted `` `this` `` param on a receiver-less function),
    /// not a dispatch receiver: bare calls must not member-dispatch through
    /// it (kotlinc rejects them as unresolved).
    this_is_plain_param: bool = false,
    /// Span of the lambda literal whose `it` was suppressed, for the
    /// unresolved-reference diagnostic.
    it_suppressed_span: ?ast.Span = null,
    /// Inline-expansion state. `inline_return` is a stack of
    /// (result reg, join block): a `return` inside an inlined body
    /// assigns the result and jumps to the join. `inline_stack`
    /// guards recursive inline.
    inline_return: std.ArrayList(InlineReturn) = .empty,
    inline_stack: std.ArrayList([]const u8) = .empty,
    /// Per inline-fn-splice frame: the lambda-param substitution map
    /// *and* a snapshot of `inline_return` as it was when this frame
    /// was pushed. An unlabeled `return` inside a spliced lambda must
    /// localize to the owner splice (restore the snapshot).
    inline_lambda_subst: std.ArrayList(InlineLambdaFrame) = .empty,
    /// While a spliced inline-argument lambda body is being lowered, the
    /// resolution window for its free names. `resolve` searches the
    /// lambda's own scopes (`[own_base, top)` — its params plus any
    /// blocks it opens) and then the caller scopes (`[0, caller_depth)`),
    /// skipping the inline fn's parameter scopes in between whose names
    /// would otherwise shadow a same-named caller variable the lambda
    /// body references. Null when no such splice is in progress.
    lambda_splice_resolve: ?struct { caller_depth: usize, own_base: usize } = null,
    /// Labeled-return targets for spliced inline-argument lambdas.
    inline_lambda_ret: std.ArrayList(InlineLambdaRet) = .empty,
    /// Simple name of the call whose arguments are currently being
    /// lowered, so a lambda literal in argument position can record it
    /// as its implicit label (`with(n) { … }` → the lambda's body Func
    /// gets `implicit_label = "with"`).
    pending_lambda_label: ?[]const u8 = null,
    /// The lambda literal about to be lowered is a `suspend { … }`
    /// expression: its body `Func` is marked `is_suspend` so runtime
    /// overload dispatch can tell a suspend lambda value from a plain
    /// one. Consumed (reset) by the lambda lowering.
    pending_suspend_lambda: bool = false,
    /// Expected type for the expression currently in tail position of a
    /// typed context (a `val x: T = …` initializer, a `fun f(): T = …`
    /// expression body, or `return …`). Lets an inline `reified` call
    /// with no explicit `<…>` infer its type argument from context.
    pending_expected: ?ast.TypeRef = null,
    /// Declared return type of the function being lowered, used to infer
    /// the type argument of a reified inline call in `return …` position.
    declared_return: ?ast.TypeRef = null,
    /// The expected lambda parameter count for the single lambda literal
    /// about to be lowered (consumed and reset by `lowerLambda`). `-1`
    /// means unknown. A zero-`->` lambda drops its parser-injected `it`
    /// only when this is exactly `0` (a `() -> R` or a `T.() -> R` receiver
    /// lambda — neither declares an `it`), so the `it` reference belongs to
    /// the nearest enclosing lambda. Any other value (including unknown)
    /// keeps the single-`it` binding.
    pending_lambda_arity: i16 = -1,

    /// A lambda ARGUMENT's expected value-parameter arity, keyed by the lambda
    /// expression's span, recorded once at the call-lowering entry from the
    /// resolved callee's parameter type. `lowerLambda` reads it as the
    /// authoritative arity so a receiver lambda drops its `it` regardless of
    /// which emit branch lowers the argument — the per-arg `pending_lambda_arity`
    /// is only set on some paths, so a non-trailing receiver-lambda argument
    /// (`f({ member() }, other)`) would otherwise stay an `it`-lambda.
    lambda_arg_arity: std.AutoHashMap(span_mod.Span, i16) = undefined,

    /// Per-argument bitmask: bit `i` set means the lambda value-parameter `i`
    /// of the argument currently being lowered has a broad-collection declared
    /// type (`Iterable`/`Collection`) coming from the *callee parameter's*
    /// function type. `pending_lambda_broad_mask` is the mask for the lambda
    /// being lowered right now; `pending_arg_broad_masks` is the per-argument
    /// source the arg-run reads (parallel to the args), set by the call site.
    pending_lambda_broad_mask: u32 = 0,
    pending_arg_broad_masks: ?[]const u32 = null,
    /// Sibling-solved expected type for ONE nested call argument, keyed by
    /// that argument's AST node (`assertEquals(EmptyEnum.entries,
    /// enumEntries())` solves `EnumEntries<EmptyEnum>` for the nested
    /// call). The arg-lowering loops push it as THAT argument's expected
    /// type — arguments otherwise lower with no expected-type hint.
    sib_expected_site: ?*const anyopaque = null,
    sib_expected_ty: ?ast.TypeRef = null,


    /// Per-argument flags: the callee parameter's declared function type
    /// takes only values typed by the callee's own type parameters
    /// (`f2t: (T, T) -> T` on `fun <T : Comparable<T>> ...`). A `::name`
    /// reference in such a slot denotes the GENERIC overload of `name`
    /// (kotlinc substitutes the call-site type argument, so only the
    /// generic candidate applies). `pending_ref_fn_generic` is the flag
    /// for the argument being lowered right now; `pending_arg_fn_generic`
    /// the per-argument source the arg-run reads, set by the call site.
    pending_ref_fn_generic: bool = false,
    pending_arg_fn_generic: ?[]const bool = null,

    /// See `setHasOwnTypeParams`.
    has_own_type_params: bool = false,

    pub fn init(allocator: Allocator, module: *Module) Allocator.Error!FuncBuilder {
        var self = FuncBuilder{
            .allocator = allocator,
            .module = module,
            .self_package = lower_self_package,
            .cur = BlockId.from(0),
            .next_reg = 0,
            .outer_names = StringSet.init(allocator),
            .capture_regs = StringRegMap.init(allocator),
            .mutables = StringSet.init(allocator),
            .mutable_homes = StringRegMap.init(allocator),
            .boxed_vars = StringSet.init(allocator),
            .any_typed_locals = StringSet.init(allocator),
            .broad_coll_locals = StringSet.init(allocator),
            .object_init_locals = StringSet.init(allocator),
            .own_members = StringSet.init(allocator),
            .own_member_arity = std.StringHashMap(u64).init(allocator),
            .lambda_arg_arity = std.AutoHashMap(span_mod.Span, i16).init(allocator),
            .enclosing_members = StringSet.init(allocator),
            .private_method_fids = StringFuncIdMap.init(allocator),
            .param_names = StringSet.init(allocator),
            .local_fns = StringSet.init(allocator),
            .local_fn_param_tys = std.StringHashMap([]const ?[]const u8).init(allocator),
            .local_decl_types = std.StringHashMap([]const u8).init(allocator),
            .local_decl_nullable = std.StringHashMap(void).init(allocator),
            .local_decl_recv_fn = std.StringHashMap(void).init(allocator),
            .local_init_exprs = std.StringHashMap(*const ast.Expr).init(allocator),
            .local_ext_fns = StringSet.init(allocator),
            .local_fn_overloads = std.StringHashMap(std.ArrayList(LocalFnOverload)).init(allocator),
            .receiver_lambda_params = StringSet.init(allocator),
            .receiver_lambda_arity = std.StringHashMap(usize).init(allocator),
            .context_fn_params = std.StringHashMap(ContextFnShape).init(allocator),
            .generic_typed_params = StringSet.init(allocator),
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
        for (self.scopes.items) |*s| s.deinit();
        self.scopes.deinit(a);
        self.lambda_arg_arity.deinit();
        self.outer_names.deinit();
        self.capture_order.deinit(a);
        self.capture_regs.deinit();
        self.loops.deinit(a);
        self.mutables.deinit();
        self.mutable_homes.deinit();
        self.boxed_vars.deinit();
        self.any_typed_locals.deinit();
        self.broad_coll_locals.deinit();
        self.object_init_locals.deinit();
        self.own_members.deinit();
        self.own_member_arity.deinit();
        self.enclosing_members.deinit();
        self.private_method_fids.deinit();
        self.param_names.deinit();
        {
            var it = self.local_fn_param_tys.valueIterator();
            while (it.next()) |v| self.allocator.free(v.*);
            self.local_fn_param_tys.deinit();
        }
        self.local_fns.deinit();
        {
            // `mangled` is module-lifetime (it ships in AstLambda
            // captured-name lists); only the builder-owned slices free.
            var it = self.local_fn_overloads.valueIterator();
            while (it.next()) |list| {
                for (list.items) |ov| {
                    a.free(ov.param_tys);
                    a.free(ov.param_names);
                }
                list.deinit(a);
            }
            self.local_fn_overloads.deinit();
        }
        self.local_decl_types.deinit();
        self.local_decl_nullable.deinit();
        self.local_decl_recv_fn.deinit();
        self.local_init_exprs.deinit();
        self.local_ext_fns.deinit();
        self.receiver_lambda_params.deinit();
        self.receiver_lambda_arity.deinit();
        self.context_fn_params.deinit();
        self.generic_typed_params.deinit();
        self.erased_recv_params.deinit();
        self.non_fn_params.deinit();
        self.reified_type_binds.deinit();
        self.reified_type_names.deinit();
        self.splice_param_tys.deinit();
        self.finally_stack.deinit(a);
        self.inline_return.deinit(a);
        self.inline_stack.deinit(a);
        for (self.inline_lambda_subst.items) |*frame| {
            frame.subst.deinit();
            a.free(frame.snapshot);
        }
        self.inline_lambda_subst.deinit(a);
        self.inline_lambda_ret.deinit(a);
    }

    /// Set the expected (tail-position) type, returning the previous
    /// value so the caller can restore it after lowering the expression.
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
        return self.inline_stack.items[self.inline_stack.items.len - 1];
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
    pub fn pushInlineReturn(self: *FuncBuilder, r: Reg, join: BlockId) Allocator.Error!void {
        try self.inline_return.append(self.allocator, .{ .reg = r, .join = join });
    }
    pub fn popInlineReturn(self: *FuncBuilder) void {
        _ = self.inline_return.pop();
    }
    /// Take ownership of the current `inline_return` stack, leaving it
    /// empty. The caller must `restoreInlineReturn` the returned slice.
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
    pub fn inlineInProgress(self: *const FuncBuilder, name: []const u8) bool {
        for (self.inline_stack.items) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }
    pub fn pushInlineName(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.inline_stack.append(self.allocator, name);
    }
    pub fn popInlineName(self: *FuncBuilder) void {
        _ = self.inline_stack.pop();
    }
    /// Push an inline-fn-splice frame. Takes ownership of `m`; a
    /// snapshot of the current `inline_return` is duplicated into the
    /// frame.
    pub fn pushInlineLambdaFrame(self: *FuncBuilder, m: std.StringHashMap(*const ast.Expr), caller_scope_depth: usize) Allocator.Error!void {
        const snap = try self.allocator.dupe(InlineReturn, self.inline_return.items);
        try self.inline_lambda_subst.append(self.allocator, .{ .subst = m, .snapshot = snap, .caller_scope_depth = caller_scope_depth });
    }

    /// The caller scope depth recorded for the innermost inline-lambda
    /// frame (see `InlineLambdaFrame.caller_scope_depth`).
    pub fn inlineLambdaCallerDepth(self: *const FuncBuilder) ?usize {
        if (self.inline_lambda_subst.items.len == 0) return null;
        return self.inline_lambda_subst.items[self.inline_lambda_subst.items.len - 1].caller_scope_depth;
    }

    /// Current scope count — the caller depth to record before an inline
    /// fn binds its parameters.
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
    /// The `inline_return` snapshot captured when the innermost
    /// inline-lambda frame was pushed — the owner splice's localize
    /// target for an unlabeled `return` in a lambda from that frame.
    /// Borrowed; valid until the frame is popped.
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

    pub fn markMutable(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.mutables.put(name, {});
    }
    pub fn isMutable(self: *const FuncBuilder, name: []const u8) bool {
        return self.mutables.contains(name);
    }

    pub fn setMutableHome(self: *FuncBuilder, name: []const u8, reg: Reg) Allocator.Error!void {
        try self.mutable_homes.put(name, reg);
    }
    pub fn mutableHome(self: *const FuncBuilder, name: []const u8) ?Reg {
        return self.mutable_homes.get(name);
    }

    /// Replace the boxed-var set with `names`. Takes ownership of
    /// `names`; the previous set is freed.
    pub fn setBoxedVars(self: *FuncBuilder, names: StringSet) void {
        self.boxed_vars.deinit();
        self.boxed_vars = names;
    }
    pub fn markBoxed(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.boxed_vars.put(name, {});
    }
    /// Remove a boxing mark added transiently (e.g. for the duration of an
    /// inline-body splice) so it cannot leak onto a same-named caller local.
    pub fn unmarkBoxed(self: *FuncBuilder, name: []const u8) void {
        _ = self.boxed_vars.remove(name);
    }
    pub fn isBoxed(self: *const FuncBuilder, name: []const u8) bool {
        return self.boxed_vars.contains(name);
    }
    /// Snapshot the boxed-var set into a fresh owned `StringSet` the
    /// caller must `deinit`.
    pub fn boxedVarsSnapshot(self: *const FuncBuilder) Allocator.Error!StringSet {
        return cloneStringSet(self.allocator, &self.boxed_vars);
    }

    /// Seed the captured-name set for a nested function builder
    /// (lambda body). Takes ownership of `names`.
    pub fn setOuterNames(self: *FuncBuilder, names: StringSet) void {
        self.outer_names.deinit();
        self.outer_names = names;
        self.is_lambda_body = true;
    }
    pub fn setOuterNamesWithoutLambda(self: *FuncBuilder, names: StringSet) void {
        self.outer_names.deinit();
        self.outer_names = names;
        // The one body shape lowered this way is an anonymous-function
        // expression (`fun(...) { ... }`). It is not a lambda for
        // return/label semantics (`return` is local), but its bare names
        // resolve against the enclosing receivers exactly like a lambda's,
        // and its implicit `this` arrives through the capture slot.
        self.is_anon_fn_body = true;
    }
    pub fn isAnonFnBody(self: *const FuncBuilder) bool {
        return self.is_anon_fn_body;
    }
    /// A body whose implicit `this` arrives through the closure capture
    /// slot rather than a bound parameter, and whose bare names resolve
    /// against the receivers in scope at its creation site: lambda bodies,
    /// named local fns, and anonymous-function bodies.
    pub fn capturesThisSlot(self: *const FuncBuilder) bool {
        return self.is_lambda_body or self.is_anon_fn_body;
    }
    pub fn setInline(self: *FuncBuilder, inline_: bool) void {
        self.is_inline = inline_;
    }
    pub fn isLambdaBody(self: *const FuncBuilder) bool {
        return self.is_lambda_body;
    }
    /// A named local function has no implicit receiver of its own; its
    /// body sees exactly the receivers its ENCLOSING body sees. The
    /// lambda-body flag (which makes every bare call defer to the runtime
    /// member-first walk) is set only when the enclosing context actually
    /// has a receiver — a local fn in a plain function resolves bare
    /// calls statically, exactly like a top-level body.
    pub fn setOuterNamesNamedLocalFn(self: *FuncBuilder, names: StringSet, enclosing_has_receiver: bool) void {
        self.outer_names.deinit();
        self.outer_names = names;
        self.is_lambda_body = enclosing_has_receiver;
        self.is_named_local_fn = true;
    }
    pub fn isNamedLocalFn(self: *const FuncBuilder) bool {
        return self.is_named_local_fn;
    }

    /// Record a capture reference encountered during lowering.
    /// Returns the per-lambda capture index. Idempotent for the
    /// same name.
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

    /// True when a name names an outer-frame capture this builder is
    /// allowed to reference.
    pub fn knowsOuter(self: *const FuncBuilder, name: []const u8) bool {
        return self.outer_names.contains(name);
    }

    /// Capture-name list in declaration order.
    pub fn capturesTaken(self: *const FuncBuilder) []const []const u8 {
        return self.capture_order.items;
    }

    pub fn pushLoop(self: *FuncBuilder, label: ?[]const u8, cont_t: BlockId, brk_t: BlockId) Allocator.Error!void {
        try self.loops.append(self.allocator, .{
            .label = label,
            .continue_target = cont_t,
            .break_target = brk_t,
        });
    }
    pub fn popLoop(self: *FuncBuilder) void {
        _ = self.loops.pop();
    }
    pub fn loopFor(self: *const FuncBuilder, label: ?[]const u8) ?*const LoopFrame {
        if (label) |l| {
            var i = self.loops.items.len;
            while (i > 0) {
                i -= 1;
                const f = &self.loops.items[i];
                if (f.label) |fl| {
                    if (std.mem.eql(u8, fl, l)) return f;
                }
            }
            return null;
        }
        if (self.loops.items.len == 0) return null;
        return &self.loops.items[self.loops.items.len - 1];
    }

    /// Bind a name in the current scope.
    pub fn bind(self: *FuncBuilder, name: []const u8, reg: Reg) Allocator.Error!void {
        try self.scopes.items[self.scopes.items.len - 1].put(name, reg);
    }

    /// Rebind a name. If the name is already bound in some live frame,
    /// update that frame's mapping in place; otherwise bind it in the
    /// current scope.
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
        self.recv_ty = name;
    }
    /// The ACTIVE inline splice's declared extension receiver type.
    /// Distinct from `recv_ty` (the enclosing function's own receiver):
    /// it feeds receiver-EVIDENCE gates (the extensions-only inline
    /// decline) without changing bare-call receiver BINDING inside the
    /// spliced body's nested lambdas, which must keep resolving against
    /// the runtime receiver walk.
    pub fn setSpliceRecvTy(self: *FuncBuilder, name: ?[]const u8) void {
        self.splice_recv_ty = name;
    }
    pub fn spliceRecvTy(self: *const FuncBuilder) ?[]const u8 {
        return self.splice_recv_ty;
    }
    pub fn recvTy(self: *const FuncBuilder) ?[]const u8 {
        return self.recv_ty;
    }
    /// Whether the Call expression currently being lowered supplied its
    /// final argument as a TRAILING lambda (`f(x) { … }`). Set by
    /// `lowerCall` from the parser's syntax bit; consumed by the call
    /// instruction emitters so the runtime binder can bind the lambda to
    /// the LAST parameter exactly when the source syntax says so.
    pub fn callTrailingLambda(self: *const FuncBuilder) bool {
        return self.cur_call_trailing;
    }
    pub fn setCallTrailingLambda(self: *FuncBuilder, on: bool) bool {
        const prev = self.cur_call_trailing;
        self.cur_call_trailing = on;
        return prev;
    }
    /// Replace the own-members set. Takes ownership of `set`.
    pub fn setOwnMembers(self: *FuncBuilder, set: StringSet) void {
        self.own_members.deinit();
        self.own_members = set;
    }
    pub fn ownMembers(self: *const FuncBuilder) *const StringSet {
        return &self.own_members;
    }
    /// Replace the enclosing-members set. Takes ownership of `set`.
    pub fn setEnclosingMembers(self: *FuncBuilder, set: StringSet) void {
        self.enclosing_members.deinit();
        self.enclosing_members = set;
    }
    /// The lexically enclosing class declares a member named `name`.
    pub fn hasEnclosingMember(self: *const FuncBuilder, name: []const u8) bool {
        return self.own_members.contains(name) or self.enclosing_members.contains(name);
    }
    /// The enclosing-class member set to hand a lambda lowered inside
    /// this builder. A lambda body's enclosing receivers are this
    /// builder's own receiver plus whatever receivers were already
    /// enclosing it, so the child sees the union of `own_members` and
    /// `enclosing_members`. The caller owns the returned set.
    pub fn enclosingMembersForChild(self: *const FuncBuilder) Allocator.Error!StringSet {
        var out = try cloneStringSet(self.allocator, &self.own_members);
        errdefer out.deinit();
        var it = self.enclosing_members.keyIterator();
        while (it.next()) |k| try out.put(k.*, {});
        return out;
    }
    /// Replace the private-method-fid map. Takes ownership of `map`.
    pub fn setPrivateMethodFids(self: *FuncBuilder, map: StringFuncIdMap) void {
        self.private_method_fids.deinit();
        self.private_method_fids = map;
    }
    pub fn privateMethodFid(self: *const FuncBuilder, name: []const u8) ?FuncId {
        return self.private_method_fids.get(name);
    }
    /// The statically-bound private own-class method for `name`, but only
    /// when its parameter list can accept a positional call of `n_args`
    /// user arguments. The map holds one FuncId per name, so when a private
    /// method is overloaded the stored entry may be a different-arity
    /// sibling; binding it regardless would route the call to the wrong
    /// overload. A mismatch returns null so the caller defers to the
    /// arity-aware dynamic dispatch.
    pub fn privateMethodFidForArity(self: *const FuncBuilder, name: []const u8, n_args: usize) ?FuncId {
        const fid = self.private_method_fids.get(name) orelse return null;
        const f = self.module.funcById(fid) orelse return fid;
        const has_this = f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this");
        const user = if (has_this) f.params.len - 1 else f.params.len;
        var min_required: usize = 0;
        var has_vararg = false;
        for (f.params[(if (has_this) @as(usize, 1) else 0)..]) |p| {
            if (p.is_vararg) has_vararg = true;
            if (!p.has_default and !p.is_vararg) min_required += 1;
        }
        if (has_vararg) return if (n_args >= min_required) fid else null;
        return if (n_args >= min_required and n_args <= user) fid else null;
    }
    pub fn hasOwnMember(self: *const FuncBuilder, name: []const u8) bool {
        return self.own_members.contains(name);
    }
    /// Replace the own-member arity-mask map. Takes ownership of `map`.
    pub fn setOwnMemberArity(self: *FuncBuilder, map: std.StringHashMap(u64)) void {
        self.own_member_arity.deinit();
        self.own_member_arity = map;
    }
    /// Whether an own member named `name` could bind a call supplying `want`
    /// arguments. Conservative: a name with no recorded arity mask (a
    /// property, or a member not captured) is treated as applicable so
    /// resolution behaves as before; only a recorded mask that excludes
    /// `want` reports inapplicable, letting a same-named top-level function
    /// resolve instead (kotlinc resolves by applicability, not by name).
    pub fn ownMemberApplicable(self: *const FuncBuilder, name: []const u8, want: usize) bool {
        const mask = self.own_member_arity.get(name) orelse return true;
        if (mask & (@as(u64, 1) << 63) != 0) return true; // a vararg overload
        if (want >= 63) return false;
        return mask & (@as(u64, 1) << @intCast(want)) != 0;
    }
    /// Swap-in a new `owner_class` + `own_members` pair and return the
    /// previous values, so an inline splice can run the spliced body in
    /// the inline fn's enclosing-class context and then restore the
    /// caller's. Ownership of `own_members` passes in; ownership of the
    /// returned set passes back out.
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
    /// Record a lambda argument's expected value-parameter arity, keyed by the
    /// lambda expression's span (from the resolved callee at the call site).
    pub fn recordLambdaArgArity(self: *FuncBuilder, sp: span_mod.Span, arity: i16) void {
        self.lambda_arg_arity.put(sp, arity) catch {};
    }

    /// The recorded expected arity for the lambda argument at `sp`, if any.
    pub fn lambdaArgArity(self: *const FuncBuilder, sp: span_mod.Span) ?i16 {
        return self.lambda_arg_arity.get(sp);
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
    /// Record a local's declared type / initializer for inline-overload
    /// receiver narrowing.
    pub fn setLocalDeclType(self: *FuncBuilder, name: []const u8, ty: []const u8) Allocator.Error!void {
        try self.local_decl_types.put(name, ty);
        _ = self.local_init_exprs.remove(name);
    }
    /// Record that the local's DECLARED type is nullable (`Array<String>?`);
    /// the head-name table above cannot carry it without disturbing its
    /// consumers. Read by the qualified-call static-receiver tag, which must
    /// not constrain null-receiver extension dispatch.
    pub fn setLocalDeclNullable(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.local_decl_nullable.put(name, {});
    }
    pub fn localDeclNullable(self: *const FuncBuilder, name: []const u8) bool {
        return self.local_decl_nullable.contains(name);
    }
    /// Record that the local's declared type is a RECEIVER function type
    /// (`suspend Scope.() -> Unit`), so a bare invocation binds the
    /// implicit `this` as the lambda's receiver.
    pub fn setLocalDeclRecvFn(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.local_decl_recv_fn.put(name, {});
    }
    pub fn localDeclRecvFn(self: *const FuncBuilder, name: []const u8) bool {
        return self.local_decl_recv_fn.contains(name);
    }
    pub fn setLocalInitExpr(self: *FuncBuilder, name: []const u8, e: *const ast.Expr) Allocator.Error!void {
        try self.local_init_exprs.put(name, e);
        _ = self.local_decl_types.remove(name);
    }
    pub fn localDeclType(self: *const FuncBuilder, name: []const u8) ?[]const u8 {
        return self.local_decl_types.get(name);
    }
    pub fn localInitExpr(self: *const FuncBuilder, name: []const u8) ?*const ast.Expr {
        return self.local_init_exprs.get(name);
    }

    pub fn markLocalFn(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.local_fns.put(name, {});
    }
    /// Record a local function's per-parameter declared type names (caller
    /// passes the positional list with any leading `this` already dropped).
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
    /// Register one same-named local-fn declaration. Takes ownership of
    /// `ov`'s slices (they must come from this builder's allocator).
    pub fn addLocalFnOverload(self: *FuncBuilder, name: []const u8, ov: LocalFnOverload) Allocator.Error!void {
        const gop = try self.local_fn_overloads.getOrPut(name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.allocator, ov);
    }
    /// All same-named declarations seen for `name`, in decl order; null
    /// unless the name was declared at least twice (a single decl never
    /// needs selection, so it is not registered).
    pub fn localFnOverloads(self: *const FuncBuilder, name: []const u8) ?[]const LocalFnOverload {
        const list = self.local_fn_overloads.getPtr(name) orelse return null;
        if (list.items.len < 2) return null;
        return list.items;
    }
    /// Seed this builder's overload table from an enclosing scope's, so a
    /// nested lambda calling a captured local fn still selects among its
    /// siblings. Entries are shared (the enclosing builder outlives the
    /// nested body's lowering); the receiving builder must not free them.
    pub fn inheritLocalFnOverloads(self: *FuncBuilder, table: *const std.StringHashMap(std.ArrayList(LocalFnOverload))) Allocator.Error!void {
        var it = table.iterator();
        while (it.next()) |e| {
            const gop = try self.local_fn_overloads.getOrPut(e.key_ptr.*);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            for (e.value_ptr.items) |ov| {
                var dup = ov;
                // `mangled` is module-lifetime — share it.
                dup.param_tys = try self.allocator.dupe(?[]const u8, ov.param_tys);
                dup.param_names = try self.allocator.dupe([]const u8, ov.param_names);
                try gop.value_ptr.append(self.allocator, dup);
            }
        }
    }
    pub fn markLocalExtFn(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.local_ext_fns.put(name, {});
    }
    pub fn isLocalExtFn(self: *const FuncBuilder, name: []const u8) bool {
        return self.local_ext_fns.contains(name);
    }
    pub fn markReceiverLambdaParam(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.receiver_lambda_params.put(name, {});
    }
    /// The declared NON-receiver arity of a receiver-lambda param
    /// (`f: T.(A) -> R` has arity 1). Disambiguates a call `f(x)`:
    /// with arity 0 the single arg is the RECEIVER (`x.f()`), with
    /// arity 1 it is the parameter (`this.f(x)`).
    pub fn markReceiverLambdaArity(self: *FuncBuilder, name: []const u8, n: usize) Allocator.Error!void {
        try self.receiver_lambda_arity.put(name, n);
    }
    pub fn receiverLambdaArity(self: *const FuncBuilder, name: []const u8) ?usize {
        return self.receiver_lambda_arity.get(name);
    }
    /// Record that param `name` has a contextual function type
    /// `context(C..) (A..) -> R`: `n_ctx` leading context types and
    /// `n_regular` ordinary parameter types. A fully-positional call
    /// `name(c.., a..)` with `n_ctx + n_regular` args lowers to `CtxCall`.
    pub fn markContextFnParam(self: *FuncBuilder, name: []const u8, n_ctx: usize, n_regular: usize) Allocator.Error!void {
        try self.context_fn_params.put(name, .{ .n_ctx = n_ctx, .n_regular = n_regular });
    }
    pub fn contextFnParam(self: *const FuncBuilder, name: []const u8) ?ContextFnShape {
        return self.context_fn_params.get(name);
    }
    pub fn isReceiverLambdaParam(self: *const FuncBuilder, name: []const u8) bool {
        return self.receiver_lambda_params.contains(name);
    }
    /// The receiver-lambda-param names this builder knows. The caller
    /// owns the returned set.
    pub fn receiverLambdaParamNames(self: *const FuncBuilder) Allocator.Error!StringSet {
        return cloneStringSet(self.allocator, &self.receiver_lambda_params);
    }
    /// Seed this builder's receiver-lambda-param set from an enclosing
    /// scope's. Copies the names; the caller keeps ownership of `names`.
    pub fn inheritReceiverLambdaParams(self: *FuncBuilder, names: *const StringSet) Allocator.Error!void {
        var it = names.keyIterator();
        while (it.next()) |k| try self.receiver_lambda_params.put(k.*, {});
    }
    pub fn unmarkReceiverLambdaParam(self: *FuncBuilder, name: []const u8) void {
        _ = self.receiver_lambda_params.remove(name);
    }
    /// The local-extension-function names this builder knows. The caller
    /// owns the returned set.
    pub fn localExtFnNames(self: *const FuncBuilder) Allocator.Error!StringSet {
        return cloneStringSet(self.allocator, &self.local_ext_fns);
    }
    /// Seed this builder's local-extension-function set from an enclosing
    /// scope's, so a captured local ext fn called bare in a nested lambda
    /// still gets the enclosing receiver prepended. Copies the names; the
    /// caller keeps ownership of `names`.
    pub fn inheritLocalExtFns(self: *FuncBuilder, names: *const StringSet) Allocator.Error!void {
        var it = names.keyIterator();
        while (it.next()) |k| try self.local_ext_fns.put(k.*, {});
    }
    /// The function being built declares its own type parameters
    /// (`fun <T : Comparable<T>> ...`). Comparisons inside such a body on
    /// operands with no concrete static type follow Kotlin's generic
    /// typing: they dispatch `compareTo` (total order), not the primitive
    /// IEEE comparison.
    pub fn setHasOwnTypeParams(self: *FuncBuilder, on: bool) void {
        self.has_own_type_params = on;
    }
    pub fn hasOwnTypeParams(self: *const FuncBuilder) bool {
        return self.has_own_type_params;
    }
    pub fn markGenericTypedParam(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.generic_typed_params.put(name, {});
    }
    pub fn isGenericTypedParam(self: *const FuncBuilder, name: []const u8) bool {
        return self.generic_typed_params.contains(name);
    }
    /// A parameter whose declared type is an UNBOUNDED type parameter of the
    /// enclosing function: its static type declares no members at all.
    pub fn markErasedRecvParam(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.erased_recv_params.put(name, {});
    }
    pub fn isErasedRecvParam(self: *const FuncBuilder, name: []const u8) bool {
        return self.erased_recv_params.contains(name);
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
    /// Record a splice's reified type-parameter binding; returns the
    /// shadowed binding (if any) so the splice can restore it on exit.
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
    /// Record a splice's reified type-parameter NAME substitution
    /// (`T` -> the call's actual type name); returns the shadowed
    /// mapping so the splice restores it on exit.
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
    /// Record a splice parameter's declared type (post reified
    /// substitution); returns the shadowed entry so the splice restores
    /// it on exit.
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
    pub fn pushFinally(self: *FuncBuilder, block: ast.Block) Allocator.Error!void {
        try self.finally_stack.append(self.allocator, block);
    }
    pub fn popFinally(self: *FuncBuilder) void {
        _ = self.finally_stack.pop();
    }
    /// Snapshot the active finally blocks into a fresh owned slice.
    pub fn activeFinallys(self: *const FuncBuilder) Allocator.Error![]ast.Block {
        return self.allocator.dupe(ast.Block, self.finally_stack.items);
    }
    /// Replace the finally stack with `replacement`, returning the
    /// previous stack as an owned slice. Takes ownership of
    /// `replacement`.
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

    pub fn resolve(self: *const FuncBuilder, name: []const u8) ?Reg {
        // Inside a spliced inline-argument lambda body, the inline fn's
        // parameter scopes are not in the lambda's lexical scope: search
        // the lambda's own scopes and then the caller scopes, skipping
        // the inline fn's parameter scopes in between.
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
                if (self.scopes.items[j].get(name)) |r| return r;
            }
            return null;
        }
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].get(name)) |r| return r;
        }
        return null;
    }

    /// Attach catch handlers + an optional finally id to a block.
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

    /// Mark `join` as the normal-flow exit of a catch-only try whose
    /// body entry is `body_entry`, so the eval pops the body's
    /// `TryFrame` when control arrives there.
    pub fn setCatchDoneFor(self: *FuncBuilder, body_entry: BlockId, join: BlockId) void {
        self.blocks.items[join.int()].catch_done_for = body_entry;
    }

    /// Mark `done` as the post-finally sentinel for the try-region
    /// whose body's entry block is `body_entry`.
    pub fn setFinallyDoneFor(self: *FuncBuilder, body_entry: BlockId, done: BlockId) void {
        self.blocks.items[body_entry.int()].finally_done = done;
        self.blocks.items[done.int()].finally_done_for = body_entry;
    }

    /// Protect a catch-handler block with the try's `finally`: a throw from
    /// within the catch then runs the finally (and re-raises past the done
    /// sentinel) instead of skipping it. The handler keeps no catches of its
    /// own, so it never re-catches into the same try. `done` is the shared
    /// post-finally sentinel (so the re-raise fires after the finally runs);
    /// `finally_done_for` is left pointing at the body, set separately.
    pub fn protectCatchWithFinally(self: *FuncBuilder, catch_block: BlockId, finally_entry: BlockId, done: BlockId) void {
        self.blocks.items[catch_block.int()].finally = finally_entry;
        self.blocks.items[catch_block.int()].finally_done = done;
    }

    /// Snapshot every register currently bound in any live scope, in
    /// ascending register order. The caller owns the returned slice.
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

    /// Names currently visible across the live scope chain. The caller
    /// owns the returned set.
    pub fn visibleNames(self: *const FuncBuilder) Allocator.Error!StringSet {
        var out = StringSet.init(self.allocator);
        for (self.scopes.items) |*frame| {
            var it = frame.keyIterator();
            while (it.next()) |k| try out.put(k.*, {});
        }
        // Include names captured from the enclosing scope so a nested
        // lambda's body knows it can reach them by walking the capture
        // chain.
        var oit = self.outer_names.keyIterator();
        while (oit.next()) |k| try out.put(k.*, {});
        return out;
    }

    /// Push a fresh scope.
    pub fn pushScope(self: *FuncBuilder) Allocator.Error!void {
        try self.scopes.append(self.allocator, StringRegMap.init(self.allocator));
    }

    /// Pop the current scope.
    pub fn popScope(self: *FuncBuilder) Allocator.Error!void {
        if (self.scopes.pop()) |frame| {
            var f = frame;
            f.deinit();
        }
        if (self.scopes.items.len == 0) {
            try self.scopes.append(self.allocator, StringRegMap.init(self.allocator));
        }
    }

    /// Allocate a fresh register.
    pub fn allocReg(self: *FuncBuilder) Reg {
        const r = Reg.from(self.next_reg);
        self.next_reg += 1;
        return r;
    }

    /// Allocate a fresh empty block.
    pub fn allocBlock(self: *FuncBuilder) Allocator.Error!BlockId {
        const id = BlockId.from(@intCast(self.blocks.items.len));
        try self.blocks.append(self.allocator, .{
            .id = id,
            .insts = &.{},
            .terminator = .Unreachable,
        });
        return id;
    }

    /// Switch the cursor to a block.
    pub fn switchTo(self: *FuncBuilder, b: BlockId) void {
        self.cur = b;
    }

    /// Append an instruction to the current block.
    pub fn push(self: *FuncBuilder, inst: Inst) Allocator.Error!void {
        const cur = self.cur.int();
        const block = &self.blocks.items[cur];
        const old = block.insts;
        const new = try self.allocator.alloc(Inst, old.len + 1);
        @memcpy(new[0..old.len], old);
        new[old.len] = inst;
        if (old.len != 0) self.allocator.free(old);
        block.insts = new;
    }

    /// Copy-coalescing peephole, run once at `finish`: an instruction
    /// defining a single-use, single-def temp that is immediately
    /// followed by `Move{dst = H, src = temp}` in the same block writes
    /// H directly and the Move disappears. Assignment and argument-run
    /// lowering produce this shape pervasively (`x = a + b` lowers as
    /// `BinOp T; Move x <- T`), so the fused form dispatches measurably
    /// fewer instructions on expression-heavy code. Register facts come
    /// from the comptime `visitInstRegs` enumeration, so every operand
    /// position — including `args`+`n_args` contiguous runs — counts.
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
            // Exact-size reallocation: the original slice frees by its
            // allocated length, so an in-place shrink would corrupt a
            // size-checked allocator's bookkeeping.
            const out = self.allocator.alloc(ir.Inst, w) catch continue;
            @memcpy(out, blk.insts[0..w]);
            self.allocator.free(blk.insts);
            blk.insts = out;
        }
    }

    /// Finalise the current block with a terminator.
    pub fn terminate(self: *FuncBuilder, t: Terminator) void {
        const cur = self.cur.int();
        self.blocks.items[cur].terminator = t;
    }

    /// Convenience: intern a constant and emit a `Const` inst.
    pub fn emitConst(self: *FuncBuilder, c: Const) Allocator.Error!Reg {
        const dst = self.allocReg();
        const id = try self.module.internConst(self.allocator, c);
        try self.push(.{ .Const = .{ .dst = dst, .value = id } });
        return dst;
    }

    /// Finish building. The block list is handed off into the returned
    /// `Func`, and the builder's `blocks` are cleared so a subsequent
    /// `deinit` does not double-free them. Caller supplies the metadata
    /// that lives outside the per-function blocks.
    pub fn finish(
        self: *FuncBuilder,
        name: []const u8,
        fqn: []const u8,
        return_ty: TypeRef,
    ) Allocator.Error!Func {
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

pub const LoopFrame = struct {
    label: ?[]const u8,
    continue_target: BlockId,
    break_target: BlockId,
};

/// Duplicate a `StringHashMap(void)` into a fresh owned set sharing the
/// borrowed key slices.
fn cloneStringSet(allocator: Allocator, src: *const StringSet) Allocator.Error!StringSet {
    var out = StringSet.init(allocator);
    var it = src.keyIterator();
    while (it.next()) |k| try out.put(k.*, {});
    return out;
}

// -------------------------------------------------------------------------
// TypeRef builder constructors.
// -------------------------------------------------------------------------

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

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

/// Free a `Func` produced by `finish` in a test: its per-block instruction
/// / catch slices (skipping the comptime-empty sentinels), the block list,
/// and the capture-name list.
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
    // The outer frame's binding was updated in place.
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
    // Bare lookup hits the innermost frame.
    try testing.expectEqual(c1, b.loopFor(null).?.continue_target);
    // Labeled lookup finds the matching outer frame.
    try testing.expectEqual(c0, b.loopFor("outer").?.continue_target);
    try testing.expect(b.loopFor("missing") == null);
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
