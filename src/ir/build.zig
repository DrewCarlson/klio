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

/// A mutable var's shared-cell register plus the scope depth it was bound
/// at. The depth lets `mutableHome` honor a splice-resolve window: a home
/// installed by a spliced inline body must be invisible to the call-site
/// lambda lowered inside that splice, exactly as `resolve` hides those
/// scopes — a body-local `var index` otherwise captures the caller lambda's
/// `index = …` write (the Duration parser's cursor never advanced).
const MutableHome = struct { reg: Reg, depth: usize };

/// The active spliced-lambda resolution window: free names resolve in the
/// caller scopes below `caller_depth` plus the lambda's own scopes at and
/// above `own_base`, skipping the spliced inline fn's scopes between.
pub const SpliceWindow = struct { caller_depth: usize, own_base: usize };

/// See `finally_window_stack`.
pub const FinallyWindow = struct {
    window: ?SpliceWindow,
    bands_len: usize,
};

/// Per inline-fn-splice frame: a lambda-param substitution map paired
/// with the `inline_return` snapshot taken when the frame was pushed.
const InlineLambdaFrame = struct {
    subst: std.StringHashMap(*const ast.Expr),
    snapshot: []InlineReturn,
    /// The bare-call static-receiver hint that was active at the inline
    /// CALL SITE (before the spliced body installed its own). A lambda
    /// argument spliced from this frame is caller code, so its bare calls
    /// must resolve under the call site's hint, not the callee body's.
    caller_hint_active: bool = false,
    caller_hint_recv: ?[]const u8 = null,
    caller_this_narrow: ?[]const u8 = null,
    /// Scope count at the inline call site, before the inline fn's
    /// parameters were bound. A lambda argument spliced from this frame
    /// was defined in the caller, so its free names must resolve in the
    /// caller's scopes (`[0, caller_scope_depth)`) plus the spliced
    /// lambda's own params — never against the inline fn's parameter
    /// scopes, whose names would otherwise shadow a same-named caller
    /// variable the lambda body references.
    caller_scope_depth: usize,
};

const InlineCallFrame = struct {
    name: []const u8,
    decl: *const ast.Function,
};

/// One `(result reg, join block)` entry on the `inline_return` stack:
/// a `return` inside an inlined body assigns the result and jumps to
/// the join (the inline call's value).
pub const InlineReturn = struct {
    reg: Reg,
    join: BlockId,
    /// Depth of `finally_stack` when this inline frame was pushed. A
    /// `return` targeting this frame replays only the finallys pushed
    /// *inside* it (`finally_stack[finally_base..]`); finallys from an
    /// enclosing inline frame belong to that frame's own return and must
    /// not run here (else a nested inline `try/finally` inside another
    /// inline `try/finally` runs the outer finally twice).
    finally_base: usize = 0,
    /// Depth of `catch_body_stack` when this inline frame was pushed: a
    /// `return` targeting it pops only the catch-only `TryFrame`s opened
    /// inside it.
    catch_base: usize = 0,
    /// Name of the inline function whose body this frame splices, so a
    /// `return@thatName` written in the body — including inside a lambda
    /// spliced from a NESTED inline call (`accept { … }.otherwise {
    /// return@tryParseTime }`) — resolves to this frame's join instead of
    /// unwinding at runtime toward a frame that was never created.
    label: ?[]const u8 = null,
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

/// LOCAL class names declared so far in the real function currently
/// lowering (and its enclosing ones). A bare constructor call on one of
/// these — from the declaring body or a nested lambda that captures the
/// binding — must construct the local class, never a same-simple-name
/// module class the index would resolve. Bounded; overflow entries are
/// dropped (those names then simply lose the shadowing, as before).
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

pub fn isLocalClassInScope(name: []const u8) bool {
    for (local_class_scope[0..local_class_scope_len]) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
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

/// File-to-package view installed with the rename maps, so a decl-time head
/// rename can serve a SAME-PACKAGE cross-file reference (the file map only
/// covers the declaring file; imports resolve by FQN separately).
pub const FilePkgMap = std.AutoHashMap(span_mod.FileId, []const u8);

threadlocal var lower_file_pkgs: ?*const FilePkgMap = null;

pub fn setLowerFilePkgs(m: ?*const FilePkgMap) ?*const FilePkgMap {
    const prev = lower_file_pkgs;
    lower_file_pkgs = m;
    return prev;
}

/// The mangled lift name for `name` referenced from `file`, over BOTH rename
/// scopes: the declaring file's own map, then the file's package map (an
/// `internal` classifier renamed for its whole package).
pub fn fileOrPkgTypeRename(name: []const u8, file: u32) ?[]const u8 {
    if (fileTypeRename(name, file)) |rn| return rn;
    const pkgs = lower_file_pkgs orelse return null;
    const pkg = pkgs.get(span_mod.FileId.from(file)) orelse return null;
    const r = pkgTypeRename(name, pkg);
    if (r != null and std.c.getenv("KLIO_RENAME_TRACE") != null)
        std.debug.print("[rnm-pkg] {s} pkg={s} -> {s} file={d}\n", .{ name, pkg, r.?, file });
    return r;
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

/// A property type head carried into a runtime anon-object member-body
/// lowering: `val iterator = sequence.iterator()` inside `object :
/// Iterator<T>` records `iterator -> Iterator` (declared annotations as
/// written, un-annotated initializers derived at `buildObject` from the
/// captured values' runtime classes), and the sibling `hasNext()` body's
/// bare-receiver walk then types the read.
pub const AnonPropHead = struct { owner: []const u8, name: []const u8, head: []const u8 };

threadlocal var lower_anon_prop_heads: []const AnonPropHead = &.{};

pub fn setLowerAnonPropHeads(hs: []const AnonPropHead) []const AnonPropHead {
    const prev = lower_anon_prop_heads;
    lower_anon_prop_heads = hs;
    return prev;
}

/// The installed head for `owner.name`, or null. Owner-keyed so a named
/// nested class lowering inside the window cannot read the anon's records.
pub fn anonPropHead(owner: []const u8, name: []const u8) ?[]const u8 {
    for (lower_anon_prop_heads) |h| {
        if (std.mem.eql(u8, h.owner, owner) and std.mem.eql(u8, h.name, name)) return h.head;
    }
    return null;
}

/// Captured enclosing-local NAMES carried into a runtime anon-object /
/// local-class member-body lowering. A captured local is the nearest
/// binding for its bare name inside the body — nearer than any top-level
/// property or const of the same simple name — but the side module has no
/// local slot for it (the value arrives through the scoped capture layer
/// at dispatch), so the lowering must keep such names DYNAMIC instead of
/// const-inlining or LoadGlobal-binding a package-scope declaration.
threadlocal var lower_anon_capture_names: []const []const u8 = &.{};

pub fn setLowerAnonCaptureNames(ns: []const []const u8) []const []const u8 {
    const prev = lower_anon_capture_names;
    lower_anon_capture_names = ns;
    return prev;
}

/// True when `name` is a captured enclosing local of the anon/local-class
/// body currently being lowered.
pub fn anonCaptureBinds(name: []const u8) bool {
    for (lower_anon_capture_names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// Classifier identities carried into runtime anonymous-object lowering.
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

/// One same-named local-function declaration: the mangled binding its
/// closure is ALSO bound under, plus the static signature facts a call
/// site selects on. Slices are owned by the declaring builder's allocator.
pub const LocalFnOverload = struct {
    mangled: []const u8,
    /// Declared extension receiver, preserving nullability and classifier
    /// identity for explicit-receiver applicability checks.
    receiver_ty: ?TypeRef = null,
    /// The receiver shape mentions a type parameter declared by this local
    /// function, so applicability requires a substitution environment.
    receiver_has_type_params: bool = false,
    /// Declared local-function type parameters and their effective upper
    /// bounds. Unbounded parameters use `Any`.
    type_params: []const ir.ModuleRegistry.TypeParamBound = &.{},
    /// Positional param type heads, leading `this` receiver dropped;
    /// null where the parameter is a vararg.
    param_tys: []const ?[]const u8,
    param_names: []const []const u8,
    /// Parameters without defaults — a call must supply at least this many.
    n_required: usize,
    has_vararg: bool,
    /// Declared with an extension receiver (`fun R.f(...)`): applicable
    /// only where a receiver context exists, and the call prepends it.
    is_ext: bool = false,
};

/// The split of a param's contextual function type `context(C..) (A..) -> R`
/// into its context-parameter count and ordinary-parameter count.
pub const ContextFnShape = struct { n_ctx: usize, n_regular: usize, ctx_types: []const []const u8 = &.{} };

pub const HiddenBinding = struct { frame: usize, reg: Reg };

pub const FuncBuilder = struct {
    allocator: Allocator,
    module: *Module,
    /// A scratch/probe builder (an overload pick lowering a lambda body to
    /// read its types): its sites are not real emissions and stay out of
    /// the dispatch census.
    census_quiet: bool = false,
    /// This body is a lambda DECLARED receiverless (shape known): the
    /// enclosing receiver tier is the next implicit-receiver link for its
    /// bare calls.
    own_recv_known_none: bool = false,
    blocks: std.ArrayList(Block) = .empty,
    cur: BlockId,
    next_reg: u32,
    /// Forwarded inline-lambda literals materialized inside a splice: the
    /// AstLambda's position and dst, so `finish` can nop the construction
    /// when NO instruction ever reads the register (every use was consumed
    /// by nested call-position splices — the compose->atomicfu->
    /// kotlin.synchronized chain otherwise registers a closure per call
    /// purely to feed forwards whose terminal only CALLS the block).
    pending_fwd_lambdas: std.ArrayList(FwdLambda) = .empty,
    /// Active spliced-subject `this` binds, innermost last: a receiver
    /// lambda's subject (`with(x) { … }`, a seated `block(current(this))`
    /// receiver) shadows the scope `this` for its region. A nested
    /// member-inline splice consults this stack to find the receiver its
    /// OWNER actually dispatches on when no subject's class reaches it.
    subject_binds: std.ArrayList(SubjectBind) = .empty,
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
    /// Capture names whose one-time entry-block `LoadCapture` has been
    /// emitted (see `loadCaptureHoisted`).
    capture_loads_emitted: StringSet,
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
    mutable_homes: std.StringHashMap(MutableHome),
    /// Per-scope undo journal for `mutables`/`mutable_homes`. A
    /// block-scoped `var` must stop shadowing when its block ends: a
    /// same-named class property written after the block would otherwise
    /// Move into the dead local's home register instead of reaching the
    /// field through SetField (reads already un-shadow via `scopes`, so
    /// the leak split writes and reads of the same name onto different
    /// storage). Entries record the pre-declaration state; `popScope`
    /// restores it. The bottom (function) scope has no frame — its
    /// declarations stay function-flat as before.
    mutable_undo: std.ArrayList(std.ArrayList(MutableUndo)) = .empty,
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
    /// Structural form of `recv_ty` when declaration/call-site metadata
    /// preserves nullability, arguments, and classifier identity.
    recv_type_ref: ?TypeRef = null,
    splice_recv_ty: ?[]const u8 = null,
    /// Depth of active spliced receiver-lambda regions that emitted an
    /// `EnclosingPush` for their subject: dispatch emissions inside such a
    /// region rely on the runtime chain (which holds every nested subject
    /// in the right order) instead of pinning one bound register.
    encl_tower_depth: u32 = 0,
    /// The register holding the INNERMOST pushed tower subject (the last
    /// `EnclosingPush`), so emission sites can tell a tower subject's
    /// bound `this` (defer to the chain) from an inline-EXT splice's
    /// bound receiver nested inside the region (must stay pinned — it is
    /// NOT on the runtime chain).
    encl_tower_top: ?Reg = null,
    /// True while `splice_recv_ty` was set by the INNERMOST spliced
    /// receiver-lambda window itself (its subject head) rather than
    /// carried over from an enclosing inline-EXT splice. Only then may a
    /// lambda-window body use it as receiver evidence — the stale ext
    /// head must keep the pre-splice hygiene contract.
    splice_recv_from_window: bool = false,
    /// The active splice's ACTUAL receiver static type WITH its type
    /// arguments, when the call site derived one (`data.count { }` on
    /// `data: T`, `T : Iterable<String>`, records `Iterable<String>`).
    /// `splice_recv_ty` keeps only the head, and iterating `this` inside
    /// the spliced body needs the arguments to type the element. Owned
    /// by the splice that set it.
    splice_recv_ty_ref: ?TypeRef = null,
    splice_hint_active: bool = false,
    splice_hint_recv: ?[]const u8 = null,
    splice_hint_recv_ref: ?ast.TypeRef = null,
    /// Smart-cast narrowing of the implicit `this` (a `when (this) { is T ->`
    /// branch): the branch body's bare/`this.` calls resolve extensions
    /// against the NARROWED static type, as kotlinc does. Cleared on inline
    /// splice entry (the spliced body has its own receiver context).
    this_narrow: ?[]const u8 = null,
    /// The receiver-type name in scope as the implicit `this` at this
    /// lambda body's construction site, carried across the lambda boundary
    /// (a plain `() -> R` block captures the enclosing `this`, and a
    /// receiver `T.() -> R` block rebinds it to `T`). `recv_ty` is only the
    /// current declaration's own extension receiver and is null inside any
    /// lambda; this fills that gap so bare-call overload disambiguation by
    /// receiver still fires inside nested lambdas. Distinct from `recv_ty`
    /// so the two never conflate a decl receiver with a captured one.
    enclosing_recv_ty: ?[]const u8 = null,
    /// Ordered implicit receiver entries, innermost first. Receiver lambdas
    /// prepend their own head and retain the complete outer tower. Each
    /// entry may carry the `this@<label>` name that reaches its value from
    /// nested scopes (see `ir.ReceiverTowerEntry`).
    implicit_receiver_tower: std.ArrayList(ir.ReceiverTowerEntry) = .empty,
    /// The label naming THIS body's own receiver (`this@<label>` bound at
    /// entry): the fn name for an extension declaration, the callee name
    /// for a receiver lambda. Null when the body owns no labeled receiver.
    own_this_label: ?[]const u8 = null,
    /// The LOCAL `fun` this builder is lowering the body of (or a lambda
    /// nested inside that body). A bare call to `self_local_fn.name` binds
    /// the fn ITSELF through its mangled cell — the shared plain-name slot
    /// may be rebound by a later same-named sibling declaration.
    self_local_fn: ?ir.SelfLocalFn = null,
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
    /// Whether the expression lowered next sits in tail position of the
    /// function — a `return` operand, an expression body, an `if`/`when`
    /// arm or elvis right side that is itself in tail position, a Unit
    /// body's last statement. Only there is a tailrec self-call a jump;
    /// `return 1 + f(x - 1)` recurses.
    tail_pos: bool = false,
    /// The tail-position flag of the node `lowerExpr` is lowering now.
    tail_here: bool = false,
    /// The flag a `when` in tail position hands its arm bodies.
    tail_arm: bool = false,
    /// The call node's tail flag, carried from `lowerCall` into the general
    /// call lowering where a tailrec self-call becomes a jump.
    call_tail: bool = false,
    /// The general call lowering's own tail flag for the call it is
    /// emitting (saved and restored across nested calls), consulted where a
    /// statically resolved tailrec-to-tailrec call becomes a tail call.
    tail_call_ok: bool = false,
    /// The tailrec function's parameters: a self-call that omits trailing
    /// defaulted arguments re-binds them from their defaults.
    tailrec_params: []const ast.Param = &.{},
    /// Names bound as parameters at the function entry (set by
    /// `bind_params`). Used by call-site lowering to recognise
    /// when an identifier-as-callee is a function-typed param.
    param_names: StringSet,
    /// The declaring function's ORDERED value params (compose-transformed
    /// AST, threaded `$composer`/`$changed` pair excluded). Set only for
    /// compose-ABI'd function lowerings; call-site `$changed` bit
    /// emission maps a bare forwarded param to its `$dirty` triple index
    /// through it.
    compose_value_params: []const ast.Param = &.{},
    /// Names declared as *local functions* (`fun foo() …` inside a
    /// body). A `recv.foo()` call resolves to such a local — but a
    /// local `val`/`var` of the same name must NOT hijack member-call
    /// syntax.
    local_fns: StringSet,
    /// A local `fun`'s DECLARED return type, keyed by its mangled binding
    /// name. A local function is a closure in a cell, not a module function,
    /// so nothing else can answer what a call to it returns. Owned.
    local_fn_return_tys: std.StringHashMap(TypeRef),
    /// Per local function: the declared parameter type-name per positional
    /// parameter (an extension's leading `this` is dropped), so a numeric
    /// literal argument can coerce to a Byte/Short/Long/Float/Double parameter
    /// at the call site, as it does for top-level functions.
    local_fn_param_tys: std.StringHashMap([]const ?[]const u8),
    /// Subset of `local_fns` declared as extensions (`fun R.f(...)`);
    /// a bare call must prepend the implicit receiver as `this`. The value
    /// is the declared VALUE-parameter count (receiver excluded), carried
    /// into nested lambda builders so a bare `::ref` to a captured local
    /// ext fn can eta-expand at the right arity; -1 when unknown.
    local_ext_fns: std.StringHashMap(i8),
    /// Locals (own or inherited from enclosing scopes) whose declared type
    /// or literal initializer proves the binding is NOT callable (`var key
    /// = 0`). A bare CALL of such a name never routes through the captured
    /// value — the same-named function wins, as in Kotlin.
    nonfn_locals: StringSet,
    /// Per local-fn NAME: one entry per same-named declaration, in decl
    /// order. Each overload's closure is additionally bound under a
    /// mangled name so a call site can select the right sibling — the
    /// plain name keeps last-decl-wins binding for unresolvable calls.
    local_fn_overloads: std.StringHashMap(std.ArrayList(LocalFnOverload)),
    /// Declared type annotation per local (`val resp: HttpResponse`),
    /// used by inline-overload receiver narrowing.
    local_decl_types: std.StringHashMap(TypeRef),
    /// Source-annotated AST types of locals (`var h: Ctx.() -> Unit`), so a
    /// later plain ASSIGNMENT to the name lowers its value under the same
    /// expected type the declaration used (a receiver-lambda reassigned to
    /// the local must keep its receiver context). Pointers into the AST,
    /// which outlives the build.
    local_ast_tys: std.StringHashMap(*const ast.TypeRef),
    local_decl_nullable: std.StringHashMap(void),
    local_call_returns: std.StringHashMap(ir.EagerTypeHead),
    local_decl_recv_fn: std.StringHashMap(void),
    /// Recorded initializer expression per un-annotated local, so the
    /// narrowing can infer a type from the init call's return type. The
    /// AST outlives the lowering pass.
    local_init_exprs: std.StringHashMap(*const ast.Expr),
    /// Locals whose name named nothing at the point of their own declaration.
    /// Kotlin does not bring a local into scope until after its initializer,
    /// so a bare call inside that initializer must ignore the local — but only
    /// when the name really was free there.
    local_init_name_free: std.StringHashMap(void),
    /// Declaration span of each recorded local initializer, so a RELOWER of
    /// the same statement recognizes the prior pass's own binding as SELF
    /// (never an outer shadow) — `val iterator = iterator()` lowered again
    /// in the same builder must stay name-free.
    local_init_decl_spans: std.StringHashMap(ast.Span),
    /// Params whose declared type is a receiver-typed function
    /// (`block: T.() -> R`). A bare call `block(...)` on one of these
    /// must dispatch with the enclosing `this` as the implicit
    /// receiver.
    receiver_lambda_params: StringSet,
    /// Which of `receiver_lambda_params` an INLINE SPLICE added for the
    /// spliced fn's own parameters. A caller binding of the same simple
    /// name keeps its own mark, so only these may be suspended while the
    /// caller's lambda body is spliced.
    splice_rlp_marks: StringSet,
    shared_rlp_marks: StringSet,
    receiver_lambda_recv_heads: std.StringHashMapUnmanaged(?[]const u8) = .empty,
    receiver_lambda_arity: std.StringHashMap(usize),
    context_fn_params: std.StringHashMap(ContextFnShape),
    /// Params (and locals) whose declared type is an unconstrained
    /// generic type-parameter (`T` of a `fun <T : Comparable<T>>`).
    /// Kotlin desugars a comparison operator on such an operand to
    /// `a.compareTo(b) <op> 0` — the total order, unlike the IEEE
    /// primitive operators.
    generic_typed_params: StringSet,
    /// See `markPlainFnParam`.
    plain_fn_params: StringSet,
    /// See `markFnParamTakesTrailingLambda`.
    fn_params_take_lambda: StringSet,
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
    /// Parallel to `finally_stack`: the try-region body-entry block of the
    /// try each finally belongs to, so an inline `return` can pop exactly
    /// those runtime `TryFrame`s when it jumps to its join.
    finally_body_stack: std.ArrayList(BlockId) = .empty,
    /// The body-entry block of each CATCH-ONLY try region currently enclosing
    /// (a try with catches and no finally). An inline `return` jumping to its
    /// join bypasses the try's normal `catch_done` exit, so it must pop these
    /// runtime `TryFrame`s too — else the catch stays armed over code that
    /// runs after the inlined call.
    catch_body_stack: std.ArrayList(BlockId) = .empty,
    /// The splice-resolve window (and hidden-band depth) active when each
    /// finally was PUSHED. A finally body replayed at a jump site re-lowers
    /// under whatever window is active THERE — but its names belong to the
    /// scope context where its `try` was lowered: the spliced
    /// `synchronized` body's `finally { __klioMonitorExit(lock) }` replayed
    /// inside a spliced lambda resolved `lock` against the lambda's caller
    /// region and found a foreign package's global instead of the body
    /// param.
    finally_window_stack: std.ArrayList(FinallyWindow) = .empty,
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
    /// guards recursive inline by declaration identity. Same-named overloads
    /// may delegate to one another and must remain spliceable.
    inline_return: std.ArrayList(InlineReturn) = .empty,
    inline_stack: std.ArrayList(InlineCallFrame) = .empty,
    /// See `inlineDeclInProgress`: entries below this index are invisible
    /// to the self-recursion check while a spliced argument literal's
    /// content (caller code) lowers.
    inline_stack_visible_base: usize = 0,
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
    lambda_splice_resolve: ?SpliceWindow = null,
    /// Scope FLOOR for a spliced MEMBER body: bare names in the body resolve
    /// only in scopes at or above the splice base — a caller local is not in
    /// the body's lexical scope, so `slots.forEachTailSlot(...)` spliced into
    /// a caller whose own parameter is named `slots` must not let the body's
    /// bare `slots` (a field on the bound receiver) bind that parameter.
    /// Null outside a member splice; the caller-lambda window (above) takes
    /// precedence while a spliced arg lambda lowers.
    splice_body_floor: ?usize = null,
    /// Scope-index bands hidden by ENCLOSING lambda-splice windows, one
    /// `[lo, hi]` per window still on the splice stack. A nested window's
    /// caller region (`[0, caller_depth)`) can reach past an outer splice's
    /// parameter scopes (a `let` block inside a spliced `fastForEach`
    /// lambda: its caller depth sits above the outer inline fn's `this`
    /// bind), so the caller scan skips any index an enclosing band hides.
    splice_hidden_bands: std.ArrayList(struct { lo: usize, hi: usize }) = .empty,
    /// See `MemberScopeSnapshot`: the caller member scope parked by an
    /// active top-level-extension splice, restored around spliced
    /// caller-lambda content.
    caller_member_scope: ?*MemberScopeSnapshot = null,
    /// Labeled-return targets for spliced inline-argument lambdas.
    inline_lambda_ret: std.ArrayList(InlineLambdaRet) = .empty,
    /// Simple name of the call whose arguments are currently being
    /// lowered, so a lambda literal in argument position can record it
    /// as its implicit label (`with(n) { … }` → the lambda's body Func
    /// gets `implicit_label = "with"`).
    pending_lambda_label: ?[]const u8 = null,
    /// The enclosing call's simple name for the whole extent of its
    /// lowering. `pending_lambda_label` is ambient state that a nested
    /// call re-arms — lowering the receiver of `Stack().apply { … }`
    /// overwrote "apply" with "Stack", so the argument lambda recorded
    /// the wrong implicit label and `return@apply` unwound past it into
    /// the `apply` frame (apply then returned Unit, not its receiver).
    /// This field is saved/restored by `lowerCall` itself, so the
    /// argument-run always labels lambdas with the call the user wrote.
    current_call_label: ?[]const u8 = null,
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
    /// The declared receiver-type head of a receiver-lambda ARGUMENT
    /// (`block: T.() -> R`), keyed by the lambda literal's span. Recorded from
    /// the resolved callee's parameter type so the lambda body owns `T` as its
    /// extension receiver even when the call is deferred and no expected type
    /// reaches `lowerLambda` (e.g. `validate { … }`).
    lambda_arg_recv: std.AutoHashMap(span_mod.Span, TypeRef) = undefined,

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
    /// Instantiated value-parameter types for the lambda argument currently
    /// lowering, plus the per-call parallel source from which it is selected.
    /// Both borrow from the active call emitter.
    pending_ref_lambda_param_types: ?[]const TypeRef = null,
    pending_arg_lambda_param_types: ?[]const ?[]const TypeRef = null,
    /// Per-call mask of lambda-literal arguments bound to a `-> Unit`
    /// function parameter, and the entry selected for the argument
    /// currently lowering. The mask is owned by the builder allocator and
    /// freed by the argument-run consumer.
    pending_arg_lambda_unit: ?[]bool = null,
    pending_ref_lambda_unit: bool = false,

    /// See `setHasOwnTypeParams`.
    has_own_type_params: bool = false,
    /// Names of NON-reified type parameters in scope (this function's own plus
    /// the enclosing class's). A cast `x as T` to such a name is UNCHECKED in
    /// Kotlin (erased to the bound), so it must not be checked against a
    /// same-named concrete class. Reified type params are excluded — they are
    /// resolved by the reified splice, which substitutes the concrete type.
    type_param_names: StringSet,
    type_param_bounds: std.StringHashMap(ir.ModuleRegistry.TypeParamBound),
    /// The full lowered upper bound of a type parameter, when it carries type
    /// ARGUMENTS the string record above drops. `M : MutableMap<in K,
    /// MutableList<T>>` needs them to instantiate a member/extension return
    /// type on a receiver typed `M`.
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
            // `mangled` is module-lifetime (it ships in AstLambda
            // captured-name lists); only the builder-owned slices free.
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
    /// Innermost active inline body-splice frame whose function name is
    /// `label`. Consulted after `inlineLambdaRetFor` misses: a labeled
    /// return crossing only inline boundaries must resolve at lowering —
    /// the target function has no runtime frame.
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
    pub fn inlineDeclInProgress(self: *const FuncBuilder, decl: *const ast.Function) bool {
        // Entries below the visibility base belong to enclosing splices
        // whose ARGUMENT-literal content is being lowered: that content is
        // caller code, and a same-fn call inside it (`repeat { repeat { } }`)
        // is nesting, not self-recursion. A genuine self-recursive body
        // re-pushes above the base and is still caught; the expand-depth
        // cap bounds pathological nesting.
        for (self.inline_stack.items[self.inline_stack_visible_base..]) |frame| {
            if (frame.decl == decl) return true;
        }
        // RECEIVER-FORMED callees (`with`, `apply`) keep the full-stack
        // check even through literal content: a nested same-fn splice
        // (`with(a) { with(b) { … } }`) loses the OUTER subject's
        // member-extension ranking in the inner static window, so the
        // inner call stays framed and the runtime tower ranks it.
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
    /// Push an inline-fn-splice frame. Takes ownership of `m`; a
    /// snapshot of the current `inline_return` is duplicated into the
    /// frame.
    pub fn pushInlineLambdaFrame(self: *FuncBuilder, m: std.StringHashMap(*const ast.Expr), caller_scope_depth: usize) Allocator.Error!void {
        try self.pushInlineLambdaFrameHinted(m, caller_scope_depth, self.splice_hint_active, self.splice_hint_recv, self.this_narrow);
    }

    /// As `pushInlineLambdaFrame`, recording an explicit call-site bare-call
    /// hint (see `InlineLambdaFrame.caller_hint_*`).
    pub fn pushInlineLambdaFrameHinted(self: *FuncBuilder, m: std.StringHashMap(*const ast.Expr), caller_scope_depth: usize, hint_active: bool, hint_recv: ?[]const u8, this_narrow: ?[]const u8) Allocator.Error!void {
        const snap = try self.allocator.dupe(InlineReturn, self.inline_return.items);
        try self.inline_lambda_subst.append(self.allocator, .{ .subst = m, .snapshot = snap, .caller_scope_depth = caller_scope_depth, .caller_hint_active = hint_active, .caller_hint_recv = hint_recv, .caller_this_narrow = this_narrow });
    }

    /// The call-site bare-call hint recorded on the innermost inline-lambda
    /// frame, for restoring while a caller lambda's body is spliced.
    pub const CallerHint = struct { active: bool, recv: ?[]const u8, this_narrow: ?[]const u8 };
    pub fn inlineLambdaCallerHint(self: *const FuncBuilder) ?CallerHint {
        if (self.inline_lambda_subst.items.len == 0) return null;
        const f = self.inline_lambda_subst.items[self.inline_lambda_subst.items.len - 1];
        return .{ .active = f.caller_hint_active, .recv = f.caller_hint_recv, .this_narrow = f.caller_this_narrow };
    }

    /// The caller scope depth recorded for the innermost inline-lambda
    /// frame (see `InlineLambdaFrame.caller_scope_depth`).
    pub fn inlineLambdaCallerDepth(self: *const FuncBuilder) ?usize {
        if (self.inline_lambda_subst.items.len == 0) return null;
        return self.inline_lambda_subst.items[self.inline_lambda_subst.items.len - 1].caller_scope_depth;
    }

    /// The index of the frame that SUBSTITUTES this exact lambda — the
    /// outermost holder, since a nested lambda body inherits the same
    /// binding into the frames above it. That frame's records (caller scope
    /// depth, call-site hint, substitution map) describe the scope the
    /// lambda was written in, which is where its free names belong.
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

    /// Resolve `name` only in scopes ABOVE `base` — the bindings the
    /// innermost inline-fn splice created (its params/receiver). Null when
    /// only caller scopes bind the name. Splice hygiene: a spliced body's
    /// bare name must not capture a caller local the callee never saw.
    pub fn resolveSpliceLocal(self: *const FuncBuilder, name: []const u8, base: usize) ?Reg {
        var i = self.scopes.items.len;
        while (i > base) {
            i -= 1;
            if (self.scopes.items[i].get(name)) |r| return r;
        }
        return null;
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
    /// The substitution frame a spliced lambda was DEFINED under: the frame
    /// beneath the one that substitutes it. The lambda body is caller code,
    /// so a call to an inline lambda parameter inside it names the CALLER's
    /// parameter — `digitAt(index) { this.onError(it) }` invokes the
    /// enclosing inline function's `onError`, not `digitAt`'s same-named one.
    /// Located at the OUTERMOST frame holding this exact lambda: the copies
    /// above it are the same binding carried into nested lambda bodies, and
    /// taking one of those would hand the lambda back to its own body.
    pub fn definingInlineLambdaSubst(
        self: *const FuncBuilder,
        name: []const u8,
        lam: *const ast.Expr,
    ) ?*const std.StringHashMap(*const ast.Expr) {
        const i = self.definingInlineLambdaFrame(name, lam) orelse return null;
        if (i == 0) return null;
        return &self.inline_lambda_subst.items[i - 1].subst;
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

    /// Journal `name`'s current mutability state into the innermost scope
    /// frame (once per scope) so `popScope` can restore it.
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
        // Inside a spliced-lambda window the inline body's scopes are not
        // the lambda's lexical scope: a home bound there is hidden, the
        // same rule `resolve` applies to plain bindings.
        if (self.lambda_splice_resolve) |w| {
            if (e.depth >= w.caller_depth and e.depth < w.own_base) return null;
            for (self.splice_hidden_bands.items) |band| {
                if (e.depth >= band.lo and e.depth <= band.hi) return null;
            }
        } else if (self.splice_body_floor) |fl| {
            // Body code under the member-splice floor: a caller local's
            // home below the base is not in the body's lexical scope.
            if (e.depth < fl) return null;
        }
        return e.reg;
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

    /// Load capture slot `idx` into its stable per-name register, ONCE, in
    /// the ENTRY block — so the value dominates every use. Emitting the
    /// load at the reference site and caching the register is unsound: the
    /// first reference may sit in a conditional branch (the LHS of an
    /// `?:`), and a later use on the other branch then reads a register no
    /// executed path ever wrote.
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
            .finally_base = self.finally_stack.items.len,
            .encl_tower_base = self.encl_tower_depth,
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
        if (std.c.getenv("KLIO_THIS_TRACE") != null and std.mem.eql(u8, name, "this")) {
            std.debug.print("[bind-this] reg={d} depth={d}\n", .{ reg.int(), self.scopes.items.len });
        }
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
    /// The ACTIVE inline splice's declared extension receiver type.
    /// Distinct from `recv_ty` (the enclosing function's own receiver):
    /// it feeds receiver-EVIDENCE gates (the extensions-only inline
    /// decline) without changing bare-call receiver BINDING inside the
    /// spliced body's nested lambdas, which must keep resolving against
    /// the runtime receiver walk.
    pub fn setSpliceRecvTy(self: *FuncBuilder, name: ?[]const u8) void {
        self.splice_recv_ty = name;
    }

    /// Bare-call static-receiver hint override. While an inline splice is
    /// active, the spliced body's bare calls resolve against the inline
    /// fn's OWN receiver (null for a receiver-less inline fn) — Kotlin
    /// inline bodies are hygienic and never see the caller's class scope.
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
    /// The active splice's declared receiver type WITH its type arguments.
    /// `spliceHintRecv` carries only the head, and a bare head cannot rank an
    /// overload set that differs by element type — which is the whole of
    /// `Collection<T>.plus(element: T)` against `plus(elements: Iterable<T>)`.
    /// Borrowed from the spliced declaration; never freed by the caller.
    pub fn setSpliceHintRecvRef(self: *FuncBuilder, ty: ?ast.TypeRef) ?ast.TypeRef {
        const prev = self.splice_hint_recv_ref;
        self.splice_hint_recv_ref = ty;
        return prev;
    }
    pub fn spliceHintRecvRef(self: *const FuncBuilder) ?ast.TypeRef {
        return self.splice_hint_recv_ref;
    }
    /// Set the smart-cast narrow of `this`, returning the previous value for
    /// restore at branch exit.
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
    /// Swap the window's full receiver record, returning the previous one
    /// so the splice restores (and frees its own) on exit.
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
    /// The receiver type in scope as the implicit `this` at this body's
    /// site: the declaration's own extension receiver, else the receiver
    /// carried across a lambda boundary. Used by bare-call disambiguation
    /// so a receiver-lambda argument's arity is recorded correctly even
    /// when the call sits inside a nested `() -> R` block.
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
    /// Append `entry` unless its head is already present; a duplicate head
    /// BACKFILLS a missing label so the labeled occurrence always survives
    /// (the current-scope head often re-appears without one).
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
    /// The tower as it stands for a body nested at this point, innermost
    /// first, with each entry's value label where one is known. `innermost`
    /// is the receiver the NEW body itself introduces (with `innermost_label`
    /// the name its `this@<label>` binds under).
    /// Mirrors `inline_call.rfsEnabled` (imported there would cycle):
    /// the receiver-formed-splice feature switch.
    fn rfsSpliceFirst() bool {
        return true;
    }

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
        // An inline SPLICE window's receiver is an implicit receiver too,
        // labeled by the spliced function: a SAM lambda built inside
        // `thenBy`'s spliced body reads `this@thenBy`, and without this
        // entry the closure's tower never carried it. Under the
        // receiver-formed splice it is the `with`/`apply` SUBJECT — the
        // INNERMOST implicit receiver, ranked ahead of the lexical owner
        // (member-extension scope tiers index this order: InnerScope's
        // `String.towerTag()` must outrank OuterScope's inside
        // `with(InnerScope()) { "receiver".towerTag() }`).
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
    /// Head-only view of `collectReceiverTowerLabeled`, for resolution
    /// contexts that rank by type alone.
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
    /// The caller's member scope, parked while a TOP-LEVEL-EXTENSION splice
    /// lowers its body: the spliced body resolves in its declaration scope,
    /// where no caller class member exists (`indices` inside a spliced
    /// `UByteArray.getOrElse` is the receiver's extension property even when
    /// the calling test class declares a METHOD named `indices`). A spliced
    /// caller-LAMBDA inside the body swaps the caller scope back in — its
    /// free names are caller code.
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
    /// Swap the parked caller member scope back in for spliced caller-lambda
    /// content. Null when no extension splice is active.
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
        if (want >= 62) return false;
        return mask & (@as(u64, 1) << @intCast(want)) != 0;
    }

    /// Whether an own member named `name` could bind a call that supplies
    /// EXPLICIT type arguments. Conservative in the same way as
    /// `ownMemberApplicable`: a name with no recorded mask is treated as
    /// applicable. Only a recorded mask saying that no same-named member
    /// declares type parameters reports inapplicable, which lets a same-named
    /// top-level generic function resolve instead — kotlinc resolves by
    /// applicability, not by name.
    /// Whether an own FUNCTION member of this name takes `want` arguments;
    /// a nested class or a property of the name does not count, so a
    /// nested-class constructor call keeps its constructor path.
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
    /// Whether the lexical class hierarchy declares a callable member that
    /// could accept `want` arguments. Unlike `ownMemberApplicable`, a stored
    /// or computed property with no same-named function is not callable.
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

    /// The declared receiver type for the receiver-lambda argument at `sp`.
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
    /// Record a local's declared type / initializer for inline-overload
    /// receiver narrowing.
    pub fn setLocalDeclType(self: *FuncBuilder, name: []const u8, ty: []const u8) Allocator.Error!void {
        const owned = try (TypeRef{
            .name = ty,
            .nullable = false,
            .args = &.{},
        }).clone(self.allocator);
        try self.setLocalDeclTypeOwned(name, owned);
        _ = self.local_init_exprs.remove(name);
    }
    /// A rebinding (a lambda's own parameter) shadows every inherited
    /// enclosing-local record under this name: the nested lambda's `it`
    /// must not read the OUTER `it`'s declared type or initializer.
    pub fn clearLocalDeclType(self: *FuncBuilder, name: []const u8) void {
        if (self.local_decl_types.fetchRemove(name)) |old| {
            var cleanup = old.value;
            cleanup.deinit(self.allocator);
        }
        _ = self.local_decl_nullable.remove(name);
        _ = self.local_call_returns.remove(name);
        _ = self.local_init_exprs.remove(name);
    }
    /// Record a complete declared type. Takes ownership of `ty`.
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
        return self.setLocalInitExprAt(name, e, null);
    }

    pub fn setLocalInitExprAt(self: *FuncBuilder, name: []const u8, e: *const ast.Expr, decl_span: ?ast.Span) Allocator.Error!void {
        // Recorded BEFORE the local is bound, which is the scope its own
        // initializer was written in. A binding left by a PRIOR LOWERING
        // PASS of this exact declaration (same span) is SELF, not an outer
        // shadow — without the span the lazy relower path saw its own
        // pass-1 binding and refused the `val iterator = iterator()` type.
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
    /// A smart cast narrows the SUBJECT's static type for the guarded branch,
    /// and Kotlin resolves extensions against the static type: inside
    /// `when (any) { is String -> … }` the call `any.isEmpty()` binds
    /// `CharSequence.isEmpty`, which the declared `Any?` head would refute.
    /// Narrow the local for the branch body and restore it on the way out.
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
    /// Whether this local's name was free at its own declaration point.
    pub fn localInitNameFree(self: *const FuncBuilder, name: []const u8) bool {
        return self.local_init_name_free.contains(name);
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
    /// Register one same-named local-fn declaration. Takes ownership of
    /// `ov`'s slices (they must come from this builder's allocator).
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
    /// Every local-function declaration seen for `name`, in decl order —
    /// including a lone one. A call site checks these for APPLICABILITY: a
    /// local fun shadows an outer same-named function only for calls it can
    /// actually take.
    pub fn localFnDecls(self: *const FuncBuilder, name: []const u8) ?[]const LocalFnOverload {
        const list = self.local_fn_overloads.getPtr(name) orelse return null;
        if (list.items.len == 0) return null;
        return list.items;
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
                var appended = false;
                // `mangled` is module-lifetime — share it.
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
    /// Declared value-parameter count of a local extension fn (receiver
    /// excluded); null when the name is not a local ext fn or the count
    /// was not recorded.
    pub fn localExtFnArity(self: *const FuncBuilder, name: []const u8) ?i8 {
        const a = self.local_ext_fns.get(name) orelse return null;
        return if (a >= 0) a else null;
    }
    pub fn isLocalExtFn(self: *const FuncBuilder, name: []const u8) bool {
        return self.local_ext_fns.contains(name);
    }
    /// A parameter whose declared type is a function type with NO receiver
    /// (`(FocusState) -> Unit`). Such a value can never serve an EXPLICIT-receiver
    /// call: Kotlin resolves `recv.name(args)` to a member or extension of `recv`,
    /// and a local only competes when its type is an EXTENSION-function type
    /// (`Modifier.() -> Unit`), which this is not.
    pub fn markPlainFnParam(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.plain_fn_params.put(name, {});
    }
    pub fn isPlainFnParam(self: *const FuncBuilder, name: []const u8) bool {
        return self.plain_fn_params.contains(name);
    }
    /// A function-typed param whose OWN last parameter is itself function-typed,
    /// i.e. one a trailing-lambda call could actually bind to. Consulted where a
    /// same-named top-level function competes with the param for a bare call.
    pub fn markFnParamTakesTrailingLambda(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.fn_params_take_lambda.put(name, {});
    }
    pub fn fnParamTakesTrailingLambda(self: *const FuncBuilder, name: []const u8) bool {
        return self.fn_params_take_lambda.contains(name);
    }
    pub fn markReceiverLambdaParam(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.receiver_lambda_params.put(name, {});
    }
    /// Declared receiver head of a receiver-lambda param, for splice
    /// bare-call hints; null when it names an unresolvable type parameter.
    pub fn setReceiverLambdaRecvHead(self: *FuncBuilder, name: []const u8, head: ?[]const u8) Allocator.Error!void {
        try self.receiver_lambda_recv_heads.put(self.allocator, name, head);
    }
    pub fn receiverLambdaRecvHead(self: *const FuncBuilder, name: []const u8) ?[]const u8 {
        return self.receiver_lambda_recv_heads.get(name) orelse null;
    }
    /// Stash this builder's receiver-lambda head table on the module's
    /// pending slot so a nested lambda body inherits the declared heads
    /// alongside the names (`inheritReceiverLambdaParams` carries names
    /// only). No-op when empty.
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
    pub fn markContextFnParam(self: *FuncBuilder, name: []const u8, ctx_types: []const []const u8, n_regular: usize) Allocator.Error!void {
        try self.context_fn_params.put(name, .{ .n_ctx = ctx_types.len, .n_regular = n_regular, .ctx_types = ctx_types });
    }
    pub fn contextFnParam(self: *const FuncBuilder, name: []const u8) ?ContextFnShape {
        return self.context_fn_params.get(name);
    }
    /// Every contextual function-type parameter in scope, for a lambda
    /// body's builder to inherit (null when there is none).
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
    /// The OUTERMOST scope's binding for `name` (a function's own entry
    /// binding), ignoring inner shadowing — for `this@<ownFn>` inside a
    /// spliced receiver lambda, where the innermost `this` is the subject.
    pub fn resolveOutermost(self: *const FuncBuilder, name: []const u8) ?Reg {
        for (self.scopes.items) |*scope| {
            if (scope.get(name)) |r| return r;
        }
        return null;
    }
    pub fn isReceiverLambdaParam(self: *const FuncBuilder, name: []const u8) bool {
        return self.receiver_lambda_params.contains(name);
    }
    /// The receiver-lambda-param names this builder knows. The caller
    /// owns the returned set.
    pub fn receiverLambdaParamNames(self: *const FuncBuilder) Allocator.Error!StringSet {
        return cloneStringSet(self.allocator, &self.receiver_lambda_params);
    }
    /// The innermost inline-lambda frame's substitution map — its keys are
    /// the enclosing inline fn's lambda-param names (the ones whose
    /// receiver-lambda marks must not leak into a spliced caller body).
    pub fn innermostInlineLambdaSubst(self: *const FuncBuilder) ?*const std.StringHashMap(*const ast.Expr) {
        if (self.inline_lambda_subst.items.len == 0) return null;
        return &self.inline_lambda_subst.items[self.inline_lambda_subst.items.len - 1].subst;
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
    /// Record that the current inline splice owns this receiver-lambda mark.
    pub fn noteSpliceRlpMark(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.splice_rlp_marks.put(name, {});
    }
    /// Record that an inline splice found `name` ALREADY marked by an
    /// enclosing splice (`kotlin.with`'s own `block` param inside
    /// `SlotTable.edit`, whose receiver-formed param is also `block`):
    /// mark ownership is shared, so the caller-body suspension must keep
    /// it — unmarking would strip the OUTER callee's receiver from the
    /// caller's bare invocation.
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
    /// The local-extension-function names this builder knows. The caller
    /// owns the returned set.
    pub fn localExtFnNames(self: *const FuncBuilder) Allocator.Error!std.StringHashMap(i8) {
        var out = std.StringHashMap(i8).init(self.allocator);
        var it = self.local_ext_fns.iterator();
        while (it.next()) |e| try out.put(e.key_ptr.*, e.value_ptr.*);
        return out;
    }
    /// Seed this builder's local-extension-function set from an enclosing
    /// scope's, so a captured local ext fn called bare in a nested lambda
    /// still gets the enclosing receiver prepended. Copies the names; the
    /// caller keeps ownership of `names`.
    pub fn inheritLocalExtFns(self: *FuncBuilder, names: *const std.StringHashMap(i8)) Allocator.Error!void {
        var it = names.iterator();
        while (it.next()) |e| try self.local_ext_fns.put(e.key_ptr.*, e.value_ptr.*);
    }
    pub fn markNonFnLocal(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.nonfn_locals.put(name, {});
    }
    /// A nearer declaration of the same name with callable evidence clears
    /// the inherited mark.
    pub fn clearNonFnLocal(self: *FuncBuilder, name: []const u8) void {
        _ = self.nonfn_locals.remove(name);
    }
    pub fn isNonFnLocal(self: *const FuncBuilder, name: []const u8) bool {
        return self.nonfn_locals.contains(name);
    }
    pub fn nonFnLocalNames(self: *const FuncBuilder) Allocator.Error!StringSet {
        return cloneStringSet(self.allocator, &self.nonfn_locals);
    }
    /// Seed from an enclosing scope's set (transitive through nested
    /// lambdas). Copies the names; the caller keeps ownership.
    pub fn inheritNonFnLocals(self: *FuncBuilder, names: *const StringSet) Allocator.Error!void {
        var it = names.keyIterator();
        while (it.next()) |k| try self.nonfn_locals.put(k.*, {});
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
    /// Record a NON-reified type-parameter name in scope (own or enclosing
    /// class). A cast to it is unchecked/erased.
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
    /// `bound_args`: the bound's concrete type-argument heads (see
    /// `ModuleRegistry.TypeParamBound.args`) — registry-lifetime slices.
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
    /// The declared upper bound of type parameter `name`, when the enclosing
    /// declaration gives one. A member call on a value typed by a type
    /// parameter resolves against that bound in Kotlin, so this is what lets
    /// such a receiver name a class at all.
    pub fn typeParamBound(self: *const FuncBuilder, name: []const u8) ?ir.ModuleRegistry.TypeParamBound {
        return self.type_param_bounds.get(name);
    }
    /// Bind a SPLICED inline callee's type-parameter bound for the splice
    /// window: the callee's param types reach the caller's builder through
    /// `spliceParamTy` (`destination: M`), and without the bound the head
    /// `M` names nothing. Returns what the caller restores on exit.
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
    /// Record the fully lowered upper bound of `name`, keeping its type
    /// arguments. Takes ownership of `ref`.
    pub fn addTypeParamBoundRef(self: *FuncBuilder, name: []const u8, ref: TypeRef) Allocator.Error!void {
        if (try self.type_param_bound_refs.fetchPut(name, ref)) |old| {
            var stale = old.value;
            stale.deinit(self.allocator);
        }
    }
    /// The full lowered upper bound of type parameter `name`, with its type
    /// arguments, when the declaration wrote any.
    pub fn typeParamBoundRef(self: *const FuncBuilder, name: []const u8) ?*const TypeRef {
        return self.type_param_bound_refs.getPtr(name);
    }

    /// Owned snapshot of the full bound refs, for carrying into a pending
    /// lambda/local-fn body.
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
    /// Whether `name` is a non-reified type parameter in scope.
    pub fn isTypeParam(self: *const FuncBuilder, name: []const u8) bool {
        return self.type_param_names.contains(name);
    }
    /// The non-reified type-parameter names in scope, as a freshly allocated
    /// slice (module allocator). Null when there are none. Used to carry them
    /// into a lambda body.
    pub fn typeParamNamesSlice(self: *const FuncBuilder) Allocator.Error!?[]const []const u8 {
        if (self.type_param_names.count() == 0) return null;
        var out = try self.allocator.alloc([]const u8, self.type_param_names.count());
        var it = self.type_param_names.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| : (i += 1) out[i] = k.*;
        return out;
    }
    /// Snapshot of the active splice's reified substitutions, for a lambda
    /// body lowered inside it.
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
    /// A parameter whose declared type is an UNBOUNDED type parameter of the
    /// enclosing function: its static type declares no members at all.
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
    /// Snapshot of the per-finally window records for a jump replay.
    pub fn finallyWindowsSnapshot(self: *const FuncBuilder) Allocator.Error![]FinallyWindow {
        return self.allocator.dupe(FinallyWindow, self.finally_window_stack.items);
    }
    /// The try-region body-entry ids for the finallys currently at
    /// `finally_stack[from..]` — the frames an inline `return` targeting a
    /// frame whose base is `from` must pop when it jumps to its join.
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
    /// The catch-only try body-entry ids opened since `from`, for an inline
    /// `return` to pop their `TryFrame`s as it jumps to its join.
    pub fn catchBodiesFrom(self: *const FuncBuilder, from: usize) Allocator.Error![]BlockId {
        const items = self.catch_body_stack.items;
        const start = @min(from, items.len);
        return self.allocator.dupe(BlockId, items[start..]);
    }
    /// Append `bodies` to a block's `pop_on_exit` list (concatenating with any
    /// already recorded there, e.g. the finally-region bodies).
    pub fn appendPopOnExit(self: *FuncBuilder, block: BlockId, bodies: []const BlockId) Allocator.Error!void {
        if (bodies.len == 0) return;
        const existing = self.blocks.items[block.int()].pop_on_exit;
        const merged = try self.allocator.alloc(BlockId, existing.len + bodies.len);
        @memcpy(merged[0..existing.len], existing);
        @memcpy(merged[existing.len..], bodies);
        self.blocks.items[block.int()].pop_on_exit = merged;
    }
    /// Record on `block` the try-region body-entry ids whose `TryFrame` the
    /// runtime pops when the block exits via `Goto` (see `Block.pop_on_exit`).
    pub fn setPopOnExit(self: *FuncBuilder, block: BlockId, bodies: []const BlockId) void {
        self.blocks.items[block.int()].pop_on_exit = bodies;
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

    /// Whether a PLAIN binding of `name` shadows the delegated-local
    /// binding `dname` (= `name$klio_delegate`): true when the walk, in
    /// `resolve` order, meets a scope holding `name` WITHOUT `dname`
    /// before any scope holding `dname`. The declaring scope holds both
    /// (the eager decl-time cache beside the hidden delegate), so a tie
    /// goes to the delegate; an inner lambda/splice parameter named like
    /// an enclosing `var x by D` sits alone in its scope and wins —
    /// `compareBy`'s `{ a, b -> … }` params must not read the caller's
    /// `var a by mutableIntStateOf(…)` through the delegate.
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

    /// `resolve` without the splice body floor: the binding a splice
    /// SUBJECT record keeps for the receiver beneath it (`this` of the
    /// frame the spliced body sits in), which the callee body itself must
    /// not see but a subject-corrected read further in must reach.
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
                // An index an ENCLOSING splice window hides (an outer
                // inline fn's parameter/receiver scopes) stays hidden for
                // this nested window's caller region too.
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

    /// Arm `region` as a labeled-return absorption region for a splice of
    /// the inline function named `label`: a `LabeledReturn` for that label
    /// unwinding through this frame while the region is armed jumps to
    /// `handler` with the value in `value_reg`. Normal flow into `handler`
    /// pops the region's frame via `catch_done_for`.
    pub fn setLrAbsorb(self: *FuncBuilder, region: BlockId, label: []const u8, handler: BlockId, value_reg: Reg) void {
        self.blocks.items[region.int()].lr_absorb = .{ .label = label, .handler = handler, .value_reg = value_reg };
        self.blocks.items[handler.int()].catch_done_for = region;
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
        // Inside a local class's or anonymous object's members the enclosing
        // function's captured locals are reachable too, so an object
        // expression or nested local class declared there closes over them.
        for (lower_anon_capture_names) |n| try out.put(n, {});
        return out;
    }

    /// Temporarily remove `name`'s innermost scope binding (an inline fn's
    /// own parameter must not be visible to a spliced CALLER-lambda body:
    /// `apply`'s `block` param shadowed a caller class's `block` member).
    /// Returns what `restoreHiddenBinding` needs, or null when unbound.
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

    /// Push a fresh scope.
    pub fn pushScope(self: *FuncBuilder) Allocator.Error!void {
        try self.scopes.append(self.allocator, StringRegMap.init(self.allocator));
        try self.mutable_undo.append(self.allocator, .empty);
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

    /// `KLIO_EMIT_TRACE=<name>`: report every Call/CallMember/
    /// CallMemberOrGlobal instruction pushed for that simple name, with
    /// the resolved target where the emission committed one. Cached once.
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

    /// Append an instruction to the current block.
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
        // KLIO_GF_TRACE=<field> / KLIO_LG_TRACE=<name>: name the emitter of a
        // field read or global load (the return address symbolizes with
        // addr2line), for a read that lands on the wrong receiver.
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
    /// Record a just-emitted forwarded-literal AstLambda as a dead-code
    /// candidate: the inst at the CURRENT block's tail whose dst is `r`.
    /// A mismatched tail (the literal's lowering emitted something after
    /// the AstLambda) records nothing — the elimination is best-effort.
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
    /// instruction or terminator reads: all its uses were consumed by
    /// nested call-position splices, so the construction (a per-call
    /// closure registration on hot paths) is dead. Runs on the builder's
    /// blocks right before they are sealed; the reg-operand walk is the
    /// same comptime-generated visitor the Move-fusion pass trusts.
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
            // The declaring package in effect for this lowering. Explicit
            // decl paths overwrite it after `finish`; the synthetic paths
            // (init blocks, delegate/property thunks, lambda bodies) keep
            // it — without the stamp every synthetic frame ran with an
            // EMPTY package and package-scoped resolution from inside one
            // treated its own package's internals as foreign (tier 5): an
            // init block's bare `rootSize(size)` skipped the same-package
            // internal and died "unresolved global".
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

/// One name's pre-declaration mutability state, restored when the scope
/// that redeclared it pops (see `FuncBuilder.mutable_undo`).
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

/// One active spliced-subject `this` bind (see `FuncBuilder.subject_binds`).
pub const SubjectBind = struct {
    reg: Reg,
    /// The subject's derived static head, when known.
    head: ?[]const u8,
    /// The scope `this` that was visible just before this subject bound —
    /// the receiver beneath the whole subject run for the outermost entry.
    prior_this: ?Reg,
};

pub const LoopFrame = struct {
    label: ?[]const u8,
    continue_target: BlockId,
    /// The frame's spliced-subject tower depth at loop entry: a
    /// `break`/`continue` from inside a spliced receiver-lambda region
    /// jumps past the region's `EnclosingPop`, and without unwinding the
    /// per-iteration push LEAKS a chain entry per retry (the snapshot
    /// map's CAS loop grew the chain unboundedly to the RSS cap).
    encl_tower_base: u32 = 0,
    break_target: BlockId,
    /// Depth of `finally_stack` when the loop was entered. A `break`/
    /// `continue` targeting this loop replays the finallys pushed above
    /// this (the try regions the jump exits) before its Goto.
    finally_base: usize = 0,
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
    // Bare lookup hits the innermost frame.
    try testing.expectEqual(c1, b.loopFor(null).?.continue_target);
    // Labeled lookup finds the matching outer frame.
    try testing.expectEqual(c0, b.loopFor("outer").?.continue_target);
    try testing.expect(b.loopFor("missing") == null);
}

test "a block-scoped var stops shadowing mutables when its scope pops" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    // A branch block declares `var x` over a class property of the same
    // name: the mutable home must vanish when the block's scope pops, or a
    // later bare-name write Moves into the dead local instead of emitting
    // SetField on the property.
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
    // Scope layout of a `let` block spliced inside a spliced `fastForEach`
    // action lambda: s0 holds the function's `this`, s1 the outer inline
    // fn's receiver bind (its window hid [1,1]), s2 the action lambda's
    // params, s3 the inner inline fn's receiver bind, s4 the let block's
    // own scope. The inner window's caller region reaches past s1; the
    // outer band must keep it hidden so `this` resolves to s0.
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

