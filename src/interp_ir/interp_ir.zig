//! IR-native interpreter.
//!
//! This module executes a frozen `ir.Module` end-to-end with no AST
//! evaluator and no callback into a tree walker. The `Vm` grows until
//! every Kotlin shape we support has a Vm-native execution path.
//!
//! Module construction goes through `ir.lower` directly; the driver
//! parses + type-checks via the shared front-end modules and hands the
//! resulting AST to this module's `build_module`.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const ast = @import("ast");
const span = @import("span");
const stdlib = @import("stdlib");
const diagnostics = @import("diagnostics");

const Allocator = std.mem.Allocator;

pub const Output = runtime.Output;

pub const build = @import("build.zig");
pub const image = @import("image.zig");

const vmhost = @import("vm/vmhost.zig");
const run_mod = @import("vm/run.zig");

pub const VmHost = vmhost.VmHost;
pub const VmIntrinsicHost = vmhost.VmIntrinsicHost;

/// `@Composable` implicit-composer support: the composer-stack host intrinsics
/// (`__compose_pushComposer` / `__compose_popComposer` /
/// `__compose_currentComposer`) the loader merges into the host bindings.
pub const compose = @import("vm/compose.zig");
pub const coroutines_diag = @import("vm/coroutines.zig");

/// Assert-empty + clear the process-wide receiver/coroutine thread-locals at a
/// run boundary. Called by `Vm.deinit` and by the public runners so leaked
/// cross-run state is a loud Debug failure.
pub const resetReceiverThreadLocals = vmhost.resetReceiverThreadLocals;
pub const resetRunGlobalCaches = vmhost.resetRunGlobalCaches;
/// Drop this thread's per-function JIT state between programs (the test/parity
/// harness runs many programs in one process on recycled module memory).
pub const resetJitForTest = ir.jit_loop.resetForTest;
pub const resetLenientWarned = @import("vm/host_call_member.zig").resetLenientWarned;

const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const Env = runtime.Env;
const ClassDef = runtime.ClassDef;
const InstanceData = runtime.InstanceData;
const HostBindings = stdlib.HostBindings;
const StdlibFn = stdlib.StdlibFn;
const Module = ir.Module;
pub const FuncId = ir.FuncId;
const TypeRef = ir.TypeRef;
const RuntimeError = runtime.RuntimeError;

/// Normalized head of a declared parameter type for the type-qualified
/// anon-method key. Every function-type spelling collapses to one token: the
/// same parameter reads `(T) -> R` where it is written and `Function1` once
/// lowered, and neither form is more authoritative than the other.
pub fn anonParamTypeHead(name: []const u8) []const u8 {
    if (std.mem.indexOf(u8, name, "->") != null) return "Function";
    if (std.mem.startsWith(u8, name, "Function")) return "Function";
    if (std.mem.startsWith(u8, name, "suspend")) return "Function";
    if (std.mem.eql(u8, name, "<function>")) return "Function";
    const bare = std.mem.trimEnd(u8, name, "?");
    const dot = std.mem.lastIndexOfScalar(u8, bare, '.') orelse return bare;
    return bare[dot + 1 ..];
}

/// Whether two declarations name the same parameter types, comparing each
/// parameter's normalized head. A leading `this` is the receiver, not a
/// parameter. Two same-name, same-arity overrides on one anonymous class
/// share the arity key, so this is what tells them apart
/// (`SerializersModuleCollector.contextual` declares a serializer form and a
/// provider form, both of arity two).
pub fn anonParamsMatch(a: []const ir.Param, b: []const ir.Param) bool {
    const skip_a: usize = if (a.len != 0 and std.mem.eql(u8, a[0].name, "this")) 1 else 0;
    const skip_b: usize = if (b.len != 0 and std.mem.eql(u8, b[0].name, "this")) 1 else 0;
    const pa = a[skip_a..];
    const pb = b[skip_b..];
    if (pa.len != pb.len) return false;
    for (pa, pb) |x, y| {
        if (!std.mem.eql(u8, anonParamTypeHead(x.ty.name), anonParamTypeHead(y.ty.name))) return false;
    }
    return true;
}

/// `name#arity#<n>`: the arity key plus the declaration's occurrence index
/// among the class's same-name, same-arity members. The plain arity key holds
/// only the LAST such declaration; the indexed keys keep every one reachable.
pub fn anonOverloadMemberName(
    allocator: Allocator,
    arity_name: []const u8,
    index: usize,
) Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "{s}#{d}", .{ arity_name, index });
}

/// Runtime-lowered method bodies for anonymous-object / local classes,
/// keyed by `(class, method)`: the owning module, the body's `FuncId`,
/// and the captured-name/value pairs to bind on call.
pub const AnonMethodEntry = struct {
    module: ObjRef(Module),
    func: FuncId,
    captures: []NameValue,

    pub fn gcTrace(self: *const AnonMethodEntry, m: *runtime.gc.Marker) void {
        m.shade(&self.module.cell.hdr);
        for (self.captures) |nv| nv.value.gcMark(m);
    }
};

pub const NameValue = struct {
    name: []const u8,
    value: Value,
};

pub const ClassTable = build.ClassTable;
pub const OuterTable = std.StringHashMap(Value);
pub const AnonMethods = ObjRef(std.StringHashMap(AnonMethodEntry));

/// `(class, member)` → `FuncId` registry table (shared with `build`).
pub const PairFuncMap = build.PairFuncMap;
pub const StrPair = build.StrPair;
pub const StrFunc = build.StrFunc;
pub const NameFunc = build.NameFunc;
pub const EnumEntryArgInit = build.EnumEntryArgInit;

/// One top-level property's on-demand init entry: the 0-arg initializer
/// thunk plus the declared type's pre-init default category (`.none` when
/// the declaration carries no usable annotation).
pub const TopLevelPropInit = struct { func: FuncId, default: build.TypedDefault, file: u32 = 0 };

/// Build-time-immutable program metadata. Produced once by
/// `build.build_module` and shared by handle with every OS thread the
/// program spawns. Nothing here is mutated after construction.
pub const ProgramImage = struct {
    /// Top-level property name → initializer thunk + typed default.
    top_level_prop_inits: std.StringHashMap(TopLevelPropInit),
    /// The same top-level props in DECLARATION order (the map above is
    /// unordered). Used to drive a file's `<clinit>` in order on demand.
    /// Borrows the Vm's `top_level_props` slice (run-stable).
    top_level_props_ordered: []const NameFunc = &.{},
    body_prop_inits: PairFuncMap,
    instance_prop_getters: PairFuncMap,
    /// Property names having ANY custom getter (across all classes). Gates
    /// the member-miss accessor probe (`state.value()`), which must never
    /// pay a full property resolution for ordinary method-miss names.
    getter_prop_names: std.StringHashMap(void),
    instance_prop_setters: PairFuncMap,
    /// Getter-backed body properties declared `private` (never virtual).
    instance_prop_private: PairFuncMap,
    parent_ctor_args: std.StringHashMap([]FuncId),
    /// Argument labels parallel to `parent_ctor_args` when a super-ctor call
    /// named any argument; used to bind those arguments to the base
    /// parameters of matching name rather than by position.
    parent_ctor_arg_names: std.StringHashMap([]const ?[]const u8),
    init_blocks: std.StringHashMap([]FuncId),
    extension_props: PairFuncMap,
    /// Property names that have at least one OWNER-QUALIFIED extension-prop
    /// key (`"<Owner>\x00<recv>"`). The lexical-tower probe in
    /// `resolveExtensionPropImpl` is gated on membership so the common
    /// lookup never pays the frame-chain walk.
    owner_keyed_ext_names: std.StringHashMap(void),
    /// Nullable-receiver extension-property getters by property name (unique
    /// pick or null for ambiguous) — the dispatch key for a null receiver.
    nullable_ext_props: std.StringHashMap(?FuncId),
    extension_prop_setters: PairFuncMap,
    /// Delegated extension properties: (receiver, prop) -> delegate thunk.
    extension_prop_delegates: PairFuncMap,
    secondary_ctors: std.StringHashMap([]build.SecondaryCtorEntry),
    primary_ctor_default_thunks: std.StringHashMap([]?FuncId),
    /// Names of every top-level `object` / synthesised companion. The
    /// startup pass initializes these eagerly but defers any whose
    /// initializer throws; `lookupGlobal` initializes a deferred object
    /// on first access — matching Kotlin's lazy `object` init.
    object_names: std.StringHashMap(void),
    class_delegates: std.StringHashMap([]StrFunc),
    func_defaults: std.AutoHashMap(u32, []?FuncId),
    installed_bindings: ObjRef(HostBindings),
    /// Link-time resolved executable form per top-level `FuncId`
    /// (keyed by `FuncId.int()`). A present entry binds that symbol's
    /// single executable form to the native binding it maps to; an
    /// absent entry runs the lowered body. Populated once by
    /// `linkResolvedForms` after both the module funcs and
    /// `installed_bindings` exist, so pack-vs-source identity is settled
    /// up front, deterministically, independent of load order. The VM
    /// dispatch paths consult this directly instead of re-deciding the
    /// form per call against `installed_bindings`.
    resolved_native: std.AutoHashMap(u32, StdlibFn),
    /// Adapter classification for `resolved_native` entries whose Kotlin
    /// declaration takes a trailing `vararg`: today's intrinsics expect the
    /// SPREAD convention, so a call arriving in the SHARED SHAPE (vararg
    /// PACKED at its slot) unpacks at the dispatch boundary. This table is
    /// the vararg row of the C-transpiler's shim list.
    vararg_spread_adapters: std.AutoHashMap(u32, u32),
    /// Link-settled redirect for bodyless top-level decls (`expect` /
    /// header-only): the same-simple-name body-bearing siblings in
    /// declaration order. Dispatch picks the first sibling whose arity
    /// fits the call; replaces the per-call `funcsBySimpleName` scan.
    resolved_redirect: std.AutoHashMap(u32, []FuncId),
    /// Deterministic bare-name → FQN map over the stdlib packages a
    /// bare reference may bind into implicitly. Built once at link time
    /// from the embedded intrinsic registry plus the installed pack
    /// overlay; the first package in `bare_probe_packages` order wins a
    /// cross-package collision. Replaces the per-call prefix-probe
    /// ladder in `lookupGlobal`. Keys and values are subslices of the
    /// registry / overlay FQNs, which outlive this image.
    default_import_globals: std.StringHashMap([]const u8),
    /// Bare-name → FQN aliases for *package-level* installed pack
    /// bindings (`runBlocking` → `kotlinx.coroutines.runBlocking`).
    /// Receiver-qualified bindings (`kotlinx.coroutines.Job.join`) are
    /// member forms a bare name can never mean and are excluded. The
    /// lexicographically smallest FQN wins a collision, so the answer
    /// is independent of hash iteration order. Replaces the suffix scan
    /// over `installed_bindings`.
    pack_bare_aliases: std.StringHashMap([]const u8),
    /// Bare-name → FQN map over the builtin member-extension surfaces
    /// (`kotlin.io`, `kotlin.AutoCloseable`, `kotlin.Any`) the member
    /// dispatcher probes for an instance receiver with no user
    /// extension. Same construction as `default_import_globals`.
    any_member_globals: std.StringHashMap([]const u8),
    /// Whether `linkResolvedForms` has run for the current
    /// `installed_bindings` snapshot.
    resolved_linked: bool,
    /// Memoized builtin member-call resolution: `(receiver type, method name,
    /// args-empty)` → the intrinsic it resolves to (or `null` = no intrinsic,
    /// fall through to extension/global dispatch). Filled lazily on first call.
    /// `stdlibMemberDispatch` otherwise rebuilds ~6 probe FQNs and does ~6
    /// `lookupIntrinsic`s (each a double `prog`/bindings borrow) on EVERY member
    /// call — the dominant constant-factor cost for member-heavy code. Only
    /// non-`Instance`, non-array-builder receivers are cached (their resolution
    /// is a pure function of the key). Method names are canonicalized through
    /// `member_names` before their pointer identity enters any dispatch cache.
    member_resolve_cache: std.AutoHashMap(MemberResolveKey, MemberResolveEntry),
    /// Winning intrinsic (or confirmed "none") for `get_field`'s stdlib
    /// property probe ladder, keyed by (receiver type-fqn identity, name
    /// identity). The ladder builds five prefix FQNs and runs a
    /// `lookupIntrinsic` per probe on EVERY non-stored-field property read of
    /// a built-in receiver; the winner is a pure function of the key.
    field_probe_cache: std.AutoHashMap(MemberHasKey, MemberResolveEntry),
    /// Program-lifetime canonical storage for method names used by the dispatch
    /// caches below. Most calls carry an IR-interned name, but a callable
    /// reference reads its name from a collected runtime String. Allocator reuse
    /// can give two different such names the same temporary address; converting
    /// every name to this content-interned address keeps pointer-keyed caches
    /// both fast and exact.
    member_names: std.StringHashMap(void),
    /// Identity of the module `canonicalizeProgramNames` last processed, so
    /// the per-program prepare pass runs once per module.
    canonicalized_module_identity: usize = 0,
    /// Monomorphic inline cache for user-class instance-method dispatch. Without
    /// it, every `inst.method()` re-walks the class hierarchy (linear class +
    /// method scans, string compares) and heap-allocates a work queue + seen-set
    /// per call — the dominant cost for member-heavy code (a method called in a
    /// 1M-iteration loop pays full resolution 1M times). The resolved `FuncId`
    /// for `(class identity, method-name pointer, arity)` is invariant when the
    /// name is unambiguous at that arity, so cache it and dispatch straight to
    /// the method body. Keyed by identity: the class cell pointer and interned
    /// method-name pointer are stable for the program's lifetime.
    instance_method_cache: std.AutoHashMap(InstanceMethodKey, u32),
    /// Linked target for a numeric virtual slot on a runtime-defined class.
    /// Anonymous-object/local-class bodies still live in side modules, while
    /// inherited bodies live in the main module; settle that distinction once
    /// per `(runtime class identity, slot)` so steady-state dispatch is O(1).
    runtime_virtual_cache: std.AutoHashMap(RuntimeVirtualKey, RuntimeVirtualTarget),
    /// Inline cache for a member-miss that resolves to a top-level *extension*
    /// function. Same key as `instance_method_cache`; the value is the resolved
    /// extension `FuncId`. Only owner-independent picks (no member-extension
    /// candidate competes, no static/declared receiver override, non-strict)
    /// are stored, so a hit is a pure function of (receiver class, name, arg
    /// types) and dispatches straight through `callFuncRec` instead of the
    /// per-call candidate collection + filtering + scoring.
    ext_method_cache: std.AutoHashMap(InstanceMethodKey, u32),
    /// Inline cache for the pack-binding / stdlib-intrinsic resolution on an
    /// `Instance` receiver (the `instanceBindingProbe` path). Without it every
    /// intrinsic instance-method call rebuilds candidate FQN strings, walks the
    /// supertype chain (heap-allocating a seen-set + queue), and re-resolves
    /// against the binding table — the dominant cost for an interpreted
    /// primitive-collection (`MutableIntIntMap.set` in a 1M loop). The resolved
    /// `(func, fqn)` for `(class identity, method-name pointer, arg-sig)` is
    /// invariant for a named class (the binding table is static); a `null` func
    /// is a cached "no intrinsic" so the next call skips the probe and falls
    /// straight through. The duped `fqn` is owned by this image.
    instance_intrinsic_cache: std.AutoHashMap(InstanceMethodKey, MemberResolveEntry),
    /// Per-class ordered list of ancestor companion-singleton names (BFS over
    /// the supertype graph + lexical enclosing classes, exactly the walk
    /// `companionWithMember` performed per call). The graph and the companion
    /// registry are static, so the list is a pure function of the class; the
    /// per-name membership check stays dynamic at the call. Name slices are
    /// program-lifetime registry strings; only the spine is owned here.
    companion_chain_cache: std.AutoHashMap(usize, []const []const u8),
    /// Named-argument binding permutations for memoized named member calls
    /// (see `NamedPerm`); keyed by the same salted key as the resolution
    /// entry, so a hit replays the binding as a positional dispatch.
    named_perm_cache: std.AutoHashMap(InstanceMethodKey, NamedPerm),
    /// `hostHasMember(class, name)` decides member-vs-global for a bare call;
    /// it walks the class hierarchy (heap-allocating a seen-set + queue) every
    /// call. The answer is a pure function of `(class identity, name pointer)`,
    /// so memoize the bool — a bare top-level call inside a hot method (e.g.
    /// `hash(key)` in `MutableIntIntMap.set`) otherwise re-walks every time.
    host_has_member_cache: std.AutoHashMap(MemberHasKey, bool),
    /// Records a `CallMemberOrGlobal` site that resolved to a global (no member
    /// or receiver-extension on its single implicit-receiver candidate). A bare
    /// call to a top-level function inside a hot method (`hash(key)` /
    /// `group(...)` in `MutableIntIntMap.set`) otherwise runs the full strict +
    /// lenient member-dispatch passes — which always miss — before falling to
    /// the global. Keyed by the enclosing function (its candidate structure is
    /// fixed) plus the runtime receiver class, name pointer, and arity, so a hit
    /// is safe to skip straight to global. Only single-candidate calls are stored.
    cmg_global_cache: std.AutoHashMap(CmgGlobalKey, void),
    /// Overload-resolution cache for global function calls. `pickOverload` scans
    /// and type-scores every same-name candidate per call — the dominant cost for
    /// generic stdlib calls (`maxOf`/`minOf`/math) in a hot loop. Its result is a
    /// pure function of `(module, base func, arg types)`, so memoize it keyed by
    /// the primitive-arg-type signature (computed only when every arg is a
    /// primitive scalar, where the tag fully determines selection).
    overload_cache: std.AutoHashMap(OverloadKey, u32),
    /// Field-READ resolution memo, keyed (receiver class cell identity,
    /// interned field-name identity — see `memberNameIdentity`) so the hot
    /// probe hashes two integers instead of the class-fqn + name byte pair:
    /// whether the read runs a custom getter (`getter` FuncId) or lands in
    /// a stored slot (`stored_idx` into the instance field list, verified
    /// by name at each hit since instances can define extras dynamically).
    /// Both facts derive from the static class graph, so one probe here
    /// replaces the per-read getter BFS + linear slot scan. Entries exist
    /// only for main-module classes, whose cells the registry keeps alive
    /// for the program's life — the identity key can never alias a
    /// reclaimed cell (the same discipline as `instance_method_cache`).
    field_read_cache: std.AutoHashMap(MemberHasKey, FieldReadHit),
    /// Field-WRITE resolution memo, keyed like `field_read_cache`:
    /// whether the write runs a custom setter (`setter` FuncId) or lands in
    /// a stored slot under `store_name`. Recorded only when every consulted
    /// fact is class-static (main-module class, no delegate, no dynamic
    /// forwarding), so one probe replaces the per-write ext-setter /
    /// delegated / custom-setter / override-cell ladder.
    field_write_cache: std.AutoHashMap(MemberHasKey, FieldWriteHit),
    /// Declaring-class memo for an instance method's implicit-`this` static
    /// receiver resolution: `(module, FuncId)` → the simple name of the class
    /// whose `methods` list owns the FuncId (`null` = no owning class found).
    /// Invariant per function, so one identity scan of the class table serves
    /// every later bare call inside that method's body. The name pointer is
    /// borrowed from the (image-lifetime) module IR, never duped.
    func_owner_class_cache: std.AutoHashMap(FuncOwnerKey, ?[]const u8),
    allocator: Allocator,

    /// `file`/`argc` are 0 for a file-agnostic resolution. When an imported
    /// pack extension shadows the stdlib surface the answer depends on the
    /// call site's import scope and the call's arity, so those entries key by
    /// (file+1, argc) instead of standing down from the cache entirely.
    pub const MemberResolveKey = struct { type_p: usize, name_p: usize, args_empty: bool, file: u32 = 0, argc: u32 = 0 };
    pub const MemberResolveEntry = struct { func: ?StdlibFn, fqn: []const u8 };
    pub const InstanceMethodKey = struct { class_p: usize, name_p: usize, n_args: u32, sig: u64 };
    pub const RuntimeVirtualKey = struct { class_p: usize, slot: u32 };
    pub const RuntimeVirtualTarget = union(enum) {
        main_func: u32,
        side_func: AnonMethodEntry,
    };
    pub const MemberHasKey = struct { class_p: usize, name_p: usize };
    /// Replayable named-argument binding for a memoized named member call:
    /// `src[k]` is the caller arg index feeding user-param `k` (receiver
    /// excluded). `n == 0xFF` is the negative verdict — the shape needs the
    /// full named binder (defaults, varargs, over/under-application).
    pub const NamedPerm = struct { n: u8, src: [15]u8 };
    pub const CmgGlobalKey = struct { func_p: usize, class_p: usize, name_p: usize, sig: u64 };
    pub const OverloadKey = struct { module_p: usize, func_p: u32, sig: u64 };
    pub const FuncOwnerKey = struct { module_p: usize, func_p: u32 };
    pub const FieldReadHit = struct {
        /// Custom getter to run, `NONE` when the read is a stored slot.
        getter: u32,
        /// Stored-slot index, `NONE` when a getter serves the read.
        stored_idx: u32,
        /// For an inner-class read answered by an ENCLOSING instance's
        /// stored slot: how many `outer` links to hop before the slot
        /// read. Zero = the receiver's own slot/getter.
        outer_hops: u8 = 0,
        /// Runtime class identity of the outer instance that owned the
        /// slot, verified at serve time (different receivers of the same
        /// inner class can have outers of different classes).
        outer_cls: u64 = 0,
        pub const NONE: u32 = std.math.maxInt(u32);
    };

    pub const FieldWriteHit = struct {
        /// Custom setter to run, `NONE` when the write is a plain store.
        setter: u32,
        /// Resolved store key for the plain write (the override-cell key or
        /// the plain name), interned into `member_names` so it outlives the
        /// slice the write was resolved from.
        store_name: []const u8,
        pub const NONE: u32 = std.math.maxInt(u32);
    };

    /// Packages a bare global name may bind into implicitly, in
    /// preference order — the prefix order of the deleted `lookupGlobal`
    /// ladder (top-level packages before the receiver-extension ones so
    /// `min` resolves to `kotlin.math.min`). The deleted `callFunc`
    /// bodyless ladder probed a DIFFERENT order (io before math, text
    /// before collections, ranges before comparisons); the two were
    /// deliberately unified onto this one. `KLIO_LINK_AUDIT` re-derives
    /// the old `callFunc` order independently
    /// (`host_call_func.deleted_bodyless_prefixes`), so a name whose
    /// pick would differ between the two orders is flagged instead of
    /// silently absorbed.
    pub const bare_probe_packages = [_][]const u8{
        "kotlin",
        "kotlin.math",
        "kotlin.comparisons",
        "kotlin.io",
        "kotlin.collections",
        "kotlin.text",
        "kotlin.ranges",
        "kotlin.concurrent",
        "kotlin.coroutines",
        "kotlin.coroutines.intrinsics",
        "kotlin.internal",
    };

    /// Builtin receiver surfaces probed for a member call on an
    /// instance with no user extension, in the dispatcher's order.
    /// `kotlin.io` is NOT one: its intrinsics (`println`, `print`,
    /// `readLine`, ...) are receiver-less top-level functions, and serving
    /// them member-style prepends the receiver as the printed argument —
    /// `with(x) { println() }` printed `x` instead of a bare newline.
    pub const any_member_prefixes = [_][]const u8{
        "kotlin.AutoCloseable",
        "kotlin.Any",
    };

    pub fn init(allocator: Allocator) Allocator.Error!ProgramImage {
        return .{
            .top_level_prop_inits = std.StringHashMap(TopLevelPropInit).init(allocator),
            .body_prop_inits = PairFuncMap.init(allocator),
            .instance_prop_getters = PairFuncMap.init(allocator),
            .getter_prop_names = std.StringHashMap(void).init(allocator),
            .instance_prop_setters = PairFuncMap.init(allocator),
            .instance_prop_private = PairFuncMap.init(allocator),
            .parent_ctor_args = std.StringHashMap([]FuncId).init(allocator),
            .parent_ctor_arg_names = std.StringHashMap([]const ?[]const u8).init(allocator),
            .init_blocks = std.StringHashMap([]FuncId).init(allocator),
            .extension_props = PairFuncMap.init(allocator),
            .owner_keyed_ext_names = std.StringHashMap(void).init(allocator),
            .nullable_ext_props = std.StringHashMap(?FuncId).init(allocator),
            .extension_prop_setters = PairFuncMap.init(allocator),
            .extension_prop_delegates = PairFuncMap.init(allocator),
            .secondary_ctors = std.StringHashMap([]build.SecondaryCtorEntry).init(allocator),
            .primary_ctor_default_thunks = std.StringHashMap([]?FuncId).init(allocator),
            .object_names = std.StringHashMap(void).init(allocator),
            .class_delegates = std.StringHashMap([]StrFunc).init(allocator),
            .func_defaults = std.AutoHashMap(u32, []?FuncId).init(allocator),
            .installed_bindings = try ObjRef(HostBindings).init(allocator, HostBindings.init(allocator)),
            .resolved_native = std.AutoHashMap(u32, StdlibFn).init(allocator),
            .vararg_spread_adapters = std.AutoHashMap(u32, u32).init(allocator),
            .resolved_redirect = std.AutoHashMap(u32, []FuncId).init(allocator),
            .default_import_globals = std.StringHashMap([]const u8).init(allocator),
            .pack_bare_aliases = std.StringHashMap([]const u8).init(allocator),
            .any_member_globals = std.StringHashMap([]const u8).init(allocator),
            .resolved_linked = false,
            .member_resolve_cache = std.AutoHashMap(MemberResolveKey, MemberResolveEntry).init(allocator),
            .field_probe_cache = std.AutoHashMap(MemberHasKey, MemberResolveEntry).init(allocator),
            .member_names = std.StringHashMap(void).init(allocator),
            .instance_method_cache = std.AutoHashMap(InstanceMethodKey, u32).init(allocator),
            .runtime_virtual_cache = std.AutoHashMap(RuntimeVirtualKey, RuntimeVirtualTarget).init(allocator),
            .ext_method_cache = std.AutoHashMap(InstanceMethodKey, u32).init(allocator),
            .instance_intrinsic_cache = std.AutoHashMap(InstanceMethodKey, MemberResolveEntry).init(allocator),
            .companion_chain_cache = std.AutoHashMap(usize, []const []const u8).init(allocator),
            .named_perm_cache = std.AutoHashMap(InstanceMethodKey, NamedPerm).init(allocator),
            .host_has_member_cache = std.AutoHashMap(MemberHasKey, bool).init(allocator),
            .cmg_global_cache = std.AutoHashMap(CmgGlobalKey, void).init(allocator),
            .overload_cache = std.AutoHashMap(OverloadKey, u32).init(allocator),
            .field_read_cache = std.AutoHashMap(MemberHasKey, FieldReadHit).init(allocator),
            .field_write_cache = std.AutoHashMap(MemberHasKey, FieldWriteHit).init(allocator),
            .func_owner_class_cache = std.AutoHashMap(FuncOwnerKey, ?[]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ProgramImage) void {
        self.top_level_prop_inits.deinit();
        self.body_prop_inits.deinit();
        self.instance_prop_getters.deinit();
        self.instance_prop_setters.deinit();
        self.instance_prop_private.deinit();
        self.parent_ctor_args.deinit();
        self.parent_ctor_arg_names.deinit();
        self.init_blocks.deinit();
        self.extension_props.deinit();
        self.nullable_ext_props.deinit();
        self.extension_prop_setters.deinit();
        self.extension_prop_delegates.deinit();
        self.secondary_ctors.deinit();
        self.primary_ctor_default_thunks.deinit();
        self.object_names.deinit();
        self.class_delegates.deinit();
        self.func_defaults.deinit();
        self.installed_bindings.deinit();
        self.resolved_native.deinit();
        self.vararg_spread_adapters.deinit();
        self.clearResolvedRedirects();
        self.resolved_redirect.deinit();
        self.default_import_globals.deinit();
        self.pack_bare_aliases.deinit();
        self.any_member_globals.deinit();
        {
            var it = self.member_resolve_cache.valueIterator();
            while (it.next()) |e| if (e.fqn.len != 0) self.allocator.free(e.fqn);
        }
        self.member_resolve_cache.deinit();
        {
            var it = self.field_probe_cache.valueIterator();
            while (it.next()) |e| if (e.fqn.len != 0) self.allocator.free(e.fqn);
        }
        self.field_probe_cache.deinit();
        {
            var it = self.member_names.keyIterator();
            while (it.next()) |name| self.allocator.free(name.*);
        }
        self.member_names.deinit();
        self.instance_method_cache.deinit();
        self.runtime_virtual_cache.deinit();
        self.ext_method_cache.deinit();
        {
            var it = self.instance_intrinsic_cache.valueIterator();
            while (it.next()) |e| if (e.fqn.len != 0) self.allocator.free(e.fqn);
        }
        self.instance_intrinsic_cache.deinit();
        {
            var it = self.companion_chain_cache.valueIterator();
            while (it.next()) |chain| if (chain.len != 0) self.allocator.free(chain.*);
        }
        self.companion_chain_cache.deinit();
        self.named_perm_cache.deinit();
        self.host_has_member_cache.deinit();
        self.cmg_global_cache.deinit();
        self.overload_cache.deinit();
        self.field_read_cache.deinit();
        self.field_write_cache.deinit();
        self.func_owner_class_cache.deinit();
    }

    /// Read-only probe for an already-interned name identity, so callers
    /// holding only a shared borrow (the hot path) can resolve without the
    /// exclusive lock `memberNameIdentity`'s insert arm needs.
    pub fn memberNameIdentityExisting(self: *const ProgramImage, name: []const u8) ?usize {
        if (self.member_names.getKey(name)) |stored| return @intFromPtr(stored.ptr);
        return null;
    }

    /// Return the program-lifetime pointer identity for `name`. Cache callers
    /// must decline to cache when allocation fails rather than keying a
    /// temporary runtime string directly.
    pub fn memberNameIdentity(self: *ProgramImage, name: []const u8) ?usize {
        const c = self.memberNameCanonical(name) orelse return null;
        return @intFromPtr(c.ptr);
    }

    /// The program-lifetime copy of `name`. A cache entry that stores a name
    /// as a *value* (not just as a pointer key) must hold this copy: a name
    /// reaching the write path through a callable reference is the bytes of a
    /// runtime String, which the collector can free while the entry lives on.
    pub fn memberNameCanonical(self: *ProgramImage, name: []const u8) ?[]const u8 {
        if (self.member_names.getKey(name)) |stored| return stored;
        const owned = self.allocator.dupe(u8, name) catch return null;
        self.member_names.put(owned, {}) catch {
            self.allocator.free(owned);
            return null;
        };
        return owned;
    }

    /// Rewrite every short name-bearing string in the program to its
    /// program-lifetime canonical copy, so hot-path name compares exit on
    /// `mem.eql`'s pointer-equality check instead of scanning bytes: every
    /// field read/write compares its instruction name operand against
    /// instance-field storage names, and every string-keyed cache probe
    /// compares its key on a hit. Instance-field storage names come from
    /// `ClassDef` param/property descriptors, name operands from the const
    /// pool; canonicalizing both sides makes the pointers meet. Strings
    /// over the cap are data, not identifiers, and stay put — a non-canonical
    /// name is never wrong, only slower.
    pub fn canonicalizeProgramNames(self: *ProgramImage, module: *Module, classes: *ClassTable) void {
        for (module.consts.items) |*c| {
            if (c.* != .String) continue;
            c.String = self.canonName(c.String);
        }
        var it = classes.valueIterator();
        while (it.next()) |cell| {
            const g = cell.borrowMut();
            defer g.deinit();
            const d = g.get();
            for (d.primary_params) |*p| p.name = self.canonName(p.name);
            for (d.body_properties) |*p| p.name = self.canonName(p.name);
        }
        for (module.classes.items) |*cl| {
            cl.name = self.canonName(cl.name);
            cl.fqn = self.canonName(cl.fqn);
            cl.package = self.canonName(cl.package);
            for (cl.primary_params) |*p| p.name = self.canonName(p.name);
        }
        for (module.funcs.items) |*f| {
            f.name = self.canonName(f.name);
            f.fqn = self.canonName(f.fqn);
            f.package = self.canonName(f.package);
        }
        // Re-key the per-read/per-write accessor maps and the member-decl
        // index with canonical parts, so a successful probe's key compare
        // exits on pointer equality instead of scanning both strings.
        self.rekeyPairMap(&self.body_prop_inits);
        self.rekeyPairMap(&self.instance_prop_getters);
        self.rekeyPairMap(&self.instance_prop_setters);
        self.rekeyPairMap(&self.instance_prop_private);
        self.rekeyPairMap(&module.member_name_index);
    }

    /// The canonical copy of `s` when it is identifier-sized, else `s`
    /// unchanged (long strings are data; a non-canonical name is never
    /// wrong, only slower to compare).
    fn canonName(self: *ProgramImage, s: []const u8) []const u8 {
        if (s.len == 0 or s.len > 160) return s;
        return self.memberNameCanonical(s) orelse s;
    }

    fn rekeyPairMap(self: *ProgramImage, map: anytype) void {
        var fresh = @TypeOf(map.*).init(map.allocator);
        fresh.ensureTotalCapacity(map.count()) catch return;
        var it = map.iterator();
        while (it.next()) |e| {
            fresh.putAssumeCapacity(
                .{ .a = self.canonName(e.key_ptr.a), .b = self.canonName(e.key_ptr.b) },
                e.value_ptr.*,
            );
        }
        var old = map.*;
        map.* = fresh;
        old.deinit();
    }

    fn clearResolvedRedirects(self: *ProgramImage) void {
        var it = self.resolved_redirect.valueIterator();
        while (it.next()) |sibs| self.allocator.free(sibs.*);
        self.resolved_redirect.clearRetainingCapacity();
    }

    /// Resolve each symbol's single executable form ONCE: for every
    /// body-bearing top-level `FuncId` whose FQN maps to a native
    /// binding in `installed_bindings`, record that binding as the
    /// symbol's form. Funcs with no matching binding run their lowered
    /// body and are simply absent from the table.
    ///
    /// This is the link/finalize step of the two-phase build: it settles
    /// pack-vs-source identity deterministically, as a pure function of
    /// `(FuncId → fqn, installed_bindings)`, with no per-call FQN probe.
    /// It mirrors exactly what the per-call short-circuit in
    /// `callFunc`/`callValue` used to decide on every dispatch
    /// (`installed_bindings.resolve(func.fqn)`), but does it once.
    /// Idempotent: re-running after an `installed_bindings` change
    /// rebuilds the table.
    pub fn linkResolvedForms(self: *ProgramImage, module: *const Module) Allocator.Error!void {
        // Unpublish before touching the tables: the VM's steady-state fast
        // paths read them unguarded gated on this flag, and a relink (run
        // setup, overlay install) must push those readers back onto the
        // locked path first.
        @atomicStore(bool, &self.resolved_linked, false, .release);
        self.resolved_native.clearRetainingCapacity();
        self.vararg_spread_adapters.clearRetainingCapacity();
        self.clearResolvedRedirects();
        self.default_import_globals.clearRetainingCapacity();
        self.pack_bare_aliases.clearRetainingCapacity();
        self.any_member_globals.clearRetainingCapacity();
        const bg = self.installed_bindings.borrow();
        defer bg.deinit();
        const bindings = bg.get();

        // The declaration manifest is authoritative for bodyless declarations:
        // join each such FuncId directly to its exact host ABI symbol before
        // compatibility linking considers FQN groups or bare aliases. A
        // body-bearing receiver declaration keeps its Kotlin body because the
        // native representation may cover only builtin receiver values, while
        // Kotlin's declaration also accepts user-defined subtypes.
        {
            var decl_it = module.decl_sigs.iterator();
            while (decl_it.next()) |entry| {
                const symbol = entry.value_ptr.host_symbol orelse continue;
                if (entry.value_ptr.has_body and !intrinsicOverridesBody(symbol)) continue;
                const intrinsic = bindings.resolve(symbol) orelse
                    stdlib.implementation(symbol) orelse continue;
                try self.resolved_native.put(entry.key_ptr.*, intrinsic);
                // The vararg adapter row: the declared slot position of a
                // trailing vararg, so the boundary can unpack a
                // shared-shape (packed) frame for a spread-expecting
                // intrinsic.
                if (module.funcById(FuncId.from(entry.key_ptr.*))) |vf| {
                    if (vf.params.len != 0 and vf.params[vf.params.len - 1].is_vararg) {
                        try self.vararg_spread_adapters.put(entry.key_ptr.*, @intCast(vf.params.len - 1));
                    }
                }
            }
        }

        // Bare-name maps: one deterministic name → FQN edge per simple
        // name, settled here instead of probed per call. Sources are the
        // embedded intrinsic registry and the installed overlay; ties
        // across packages resolve by `bare_probe_packages` order, and a
        // same-package tie cannot occur (FQNs are unique per table).
        {
            var fqn_it = stdlib.implementations.allFqns();
            while (fqn_it.next()) |fqn| {
                try stdlib.noteBareNameMapping(&self.default_import_globals, &bare_probe_packages, fqn);
                try stdlib.noteBareNameMapping(&self.any_member_globals, &any_member_prefixes, fqn);
            }
            var key_it = bindings.table.keyIterator();
            while (key_it.next()) |k| {
                try stdlib.noteBareNameMapping(&self.default_import_globals, &bare_probe_packages, k.*);
                try stdlib.noteBareNameMapping(&self.any_member_globals, &any_member_prefixes, k.*);
                try notePackAlias(&self.pack_bare_aliases, k.*);
            }
        }

        if (!bindings.isEmpty()) {
            // Mark every func under an installed binding's fqn native — iterate
            // the bindings and resolve each fqn to its funcs (all overloads share
            // the receiverless fqn), touching the lazy func table only for
            // same-simple-name candidates instead of sweeping it whole.
            //
            // One exception: a body-bearing GENERIC overload (every value param
            // typed by the func's own type parameters) sharing its FQN with a
            // same-arity concrete-typed sibling keeps its body. The intrinsic
            // implements the concrete family's semantics (`kotlin.comparisons.
            // minOf(Double, Double)` propagates NaN); the generic family's
            // semantics differ (`minOf<T : Comparable<T>>` is the compareTo
            // total order), so collapsing the generic body onto the intrinsic
            // erases the distinction the overload split exists for.
            var bk = bindings.table.keyIterator();
            while (bk.next()) |fqn_k| {
                const fqn = fqn_k.*;
                const intrinsic = bindings.resolve(fqn) orelse continue;
                const simple = if (std.mem.lastIndexOfScalar(u8, fqn, '.')) |dot| fqn[dot + 1 ..] else fqn;
                for (module.funcsBySimpleName(simple)) |cand| {
                    const cf = module.funcById(cand) orelse continue;
                    if (std.mem.eql(u8, cf.fqn, fqn)) {
                        if (genericOverloadKeepsBody(module, cand, cf)) continue;
                        try self.resolved_native.put(cand.int(), intrinsic);
                    }
                }
                // A member-form binding (`<pkg>.<Class>.<name>`) names a
                // class method, which the simple-name index does not carry.
                // A statically resolved call reaches that method's FuncId
                // directly through `callFunc`, so its placeholder Kotlin
                // body must be settled to the intrinsic here exactly like a
                // top-level form (`kotlinx.atomicfu.locks.ReentrantLock.
                // lock`'s no-op body held no lock under a spliced
                // `withLock`). CONCRETE classes only: a call resolved to an
                // INTERFACE / abstract method must dispatch virtually on the
                // runtime class — its intrinsic serves host-repr builtin
                // receivers, and settling the header fid ran
                // `kotlin.collections.List.isEmpty` against an interpreted
                // `PersistentList` instance.
                if (std.mem.lastIndexOfScalar(u8, fqn, '.')) |dot| {
                    const owner_fqn = fqn[0..dot];
                    if (module.classIdByFqn(owner_fqn)) |cid| {
                        if (cid.int() < module.classes.items.len) {
                            const cls = &module.classes.items[cid.int()];
                            if (!cls.is_interface and !cls.is_abstract) {
                                for (cls.methods) |mid| {
                                    const mf = module.funcById(mid) orelse continue;
                                    if (!std.mem.eql(u8, mf.name, simple)) continue;
                                    if (genericOverloadKeepsBody(module, mid, mf)) continue;
                                    try self.resolved_native.put(mid.int(), intrinsic);
                                }
                            }
                        }
                    }
                }
            }
        }

        // Bodyless decls (`expect` / header-only): settle the executable form in
        // the dispatcher's order. Base bodyless funcs come from the baked id list
        // (no full-table scan under the lazy path); this run's own funcs are
        // scanned directly (eager `funcs.items`, ids past the base range).
        for (module.bodyless_func_ids) |bid| {
            try self.linkBodyless(module, bindings, FuncId.from(bid));
        }
        const base_n: u32 = @intCast(module.func_header_offsets.len);
        for (module.funcs.items, 0..) |*f, j| {
            if (f.hasBody()) continue;
            try self.linkBodyless(module, bindings, FuncId.from(base_n + @as(u32, @intCast(j))));
        }
        @atomicStore(bool, &self.resolved_linked, true, .release);
    }

    /// Settle one bodyless func's executable form: a same-simple-name body
    /// sibling redirect (declaration order; arity picks at the call) plus the
    /// exact-fqn / bare-name native fallback. Shared by the base (baked-id) and
    /// user (table-scan) bodyless passes.
    fn linkBodyless(self: *ProgramImage, module: *const Module, bindings: anytype, fid: FuncId) !void {
        const f = module.funcById(fid) orelse return;
        if (f.hasBody()) return;
        if (self.resolved_native.contains(fid.int())) return;
        const receiver_formed = f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this");
        var sibs: std.ArrayList(FuncId) = .empty;
        errdefer sibs.deinit(self.allocator);
        for (module.funcsBySimpleName(f.name)) |cand| {
            if (cand.int() == fid.int()) continue;
            const cf = module.funcById(cand) orelse continue;
            if (!cf.hasBody()) continue;
            // An `actual` declares the same package as its `expect`, so only a
            // same-package sibling can settle a bodyless decl. A same-named
            // function in another package is an unrelated declaration: without
            // this, a call to an `expect` klio does not implement silently ran a
            // stranger's body (`material3.internal.getString` ran
            // `foundation.text.getString`), and the caller never learned the
            // expect was missing.
            if (!std.mem.eql(u8, cf.package, f.package)) continue;
            // Same package is not enough for a MEMBER. `kotlin.Double.equals`
            // and `kotlin.String.equals` share the package `kotlin`, and
            // settling the first with the second runs an implementation that
            // rejects the receiver it is handed. A receiver-formed header is
            // settled only by a declaration of its own class — the FQN up to
            // its last component. Top-level `expect`/`actual` pairs, whose
            // owner IS their package, are unaffected.
            if (receiver_formed and
                !std.mem.eql(u8, declaringOwnerOfFqn(cf.fqn), declaringOwnerOfFqn(f.fqn))) continue;
            try sibs.append(self.allocator, cand);
        }
        if (sibs.items.len != 0) {
            try self.resolved_redirect.put(fid.int(), try sibs.toOwnedSlice(self.allocator));
        }
        if (self.bodylessNativeForm(bindings, f.fqn, f.name, receiver_formed)) |intrinsic| {
            try self.resolved_native.put(fid.int(), intrinsic);
        }
    }

    /// Symbols whose host implementation must serve even though the Kotlin
    /// declaration has a body.
    ///
    /// `Sequence.sumOf` declares five overloads that differ ONLY in the
    /// selector's return type — `(T) -> Double` first, then Int, Long, UInt,
    /// ULong — and Kotlin picks between them by the lambda's inferred return
    /// type. A lambda carries no declared return type here, so the pick falls
    /// to declaration order and `sumOf { it.length }` runs the Double body,
    /// accumulating 6 as 6.0. The host implementation reads the kind from the
    /// first value it computes, which is the answer Kotlin's typed selection
    /// reaches, and it drains a host `.Sequence` and an interpreted one alike
    /// so it covers the same receivers the Kotlin body does.
    fn intrinsicOverridesBody(symbol: []const u8) bool {
        const overrides = [_][]const u8{
            "kotlin.sequences.Sequence.sumOf",
        };
        for (overrides) |o| {
            if (std.mem.eql(u8, o, symbol)) return true;
        }
        return false;
    }

    /// The declaring scope of a fully qualified name: everything before its
    /// last component. For a member that is its class (`kotlin.Double`), for a
    /// top-level function its package (`kotlin.collections`).
    fn declaringOwnerOfFqn(fqn: []const u8) []const u8 {
        const dot = std.mem.lastIndexOfScalar(u8, fqn, '.') orelse return "";
        return fqn[0..dot];
    }

    /// User arity of a func (value params, excluding a synthesized `this`).
    fn funcValueArity(f: *const ir.Func) usize {
        if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) return f.params.len - 1;
        return f.params.len;
    }

    fn typeUsesTypeParam(ty: *const ir.TypeRef, type_params: []const []const u8) bool {
        var head = ty.name;
        if (std.mem.startsWith(u8, head, "in#")) head = head["in#".len..];
        if (std.mem.startsWith(u8, head, "out#")) head = head["out#".len..];
        for (type_params) |tp| {
            if (std.mem.eql(u8, head, tp)) return true;
        }
        for (ty.args) |*arg| {
            if (typeUsesTypeParam(arg, type_params)) return true;
        }
        return false;
    }

    /// Whether every value parameter of `f` depends on one of the function's
    /// own declared type parameters. This includes structural uses such as
    /// `Comparator<in T>`, not only a bare `T` head. The registry's
    /// `func_type_params` carries the declared type-parameter names.
    fn funcHasGenericSig(module: *const Module, fid: FuncId, f: *const ir.Func) bool {
        const tps = module.registry.func_type_params.get(fid) orelse return false;
        if (tps.items.len == 0) return false;
        const off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        if (f.params.len == off) return false;
        for (f.params[off..]) |*p| {
            if (!typeUsesTypeParam(&p.ty, tps.items)) return false;
        }
        return true;
    }

    /// The narrow native-marking escape: a body-bearing, non-extension,
    /// generic-signature overload whose FQN group also holds a same-arity
    /// NON-generic sibling keeps its Kotlin body instead of being marked
    /// `resolved_native`. Scoped tightly so intrinsic-over-body funcs stay
    /// intrinsic: bodyless stubs, extensions, all-generic families
    /// (`listOf`), and generic funcs with no concrete same-arity namesake
    /// all keep today's marking.
    fn genericOverloadKeepsBody(module: *const Module, fid: FuncId, f: *const ir.Func) bool {
        if (!f.hasBody()) return false;
        if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) return false;
        if (!funcHasGenericSig(module, fid, f)) return false;
        const arity = funcValueArity(f);
        for (module.funcsBySimpleName(f.name)) |sid| {
            if (sid.int() == fid.int()) continue;
            const g = module.funcById(sid) orelse continue;
            if (!std.mem.eql(u8, g.fqn, f.fqn)) continue;
            if (funcValueArity(g) != arity) continue;
            if (!funcHasGenericSig(module, sid, g)) return true;
        }
        return false;
    }

    /// The native form a bodyless decl's per-call ladder would have
    /// found: the declared FQN against the overlay then the embedded
    /// registry, then the bare-name map's FQN against both.
    fn bodylessNativeForm(
        self: *const ProgramImage,
        bindings: *const HostBindings,
        fqn: []const u8,
        name: []const u8,
        receiver_formed: bool,
    ) ?StdlibFn {
        if (bindings.resolve(fqn)) |i| return i;
        if (stdlib.implementation(fqn)) |i| return i;
        // The bare-name map names TOP-LEVEL functions, so it cannot settle a
        // member header: `kotlin.Double.equals` is not implemented by the
        // package-level `equals`, and running that one rejects the receiver it
        // is handed. A member's implementation is receiver-qualified and has
        // already been tried by exact FQN above.
        if (receiver_formed) return null;
        if (self.default_import_globals.get(name)) |mapped| {
            if (bindings.resolve(mapped)) |i| return i;
            if (stdlib.implementation(mapped)) |i| return i;
        }
        return null;
    }

    /// Record a package-level installed binding's bare-name alias. A
    /// binding whose parent segment starts with an uppercase letter is a
    /// receiver-qualified member form (`...Job.join`) a bare name can
    /// never mean; it is excluded. The lexicographically smallest FQN
    /// wins a collision so the alias is hash-order independent.
    fn notePackAlias(map: *std.StringHashMap([]const u8), fqn: []const u8) Allocator.Error!void {
        const dot = std.mem.lastIndexOfScalar(u8, fqn, '.') orelse return;
        const pkg = fqn[0..dot];
        const name = fqn[dot + 1 ..];
        if (name.len == 0 or pkg.len == 0) return;
        const parent_start = if (std.mem.lastIndexOfScalar(u8, pkg, '.')) |d| d + 1 else 0;
        const parent = pkg[parent_start..];
        if (parent.len == 0 or std.ascii.isUpper(parent[0])) return;
        const gop = try map.getOrPut(name);
        if (gop.found_existing) {
            if (std.mem.order(u8, fqn, gop.value_ptr.*) != .lt) return;
        }
        gop.value_ptr.* = fqn;
    }

    /// The deterministic FQN a bare global name maps to under the
    /// implicit stdlib surface, or null when the name is not part of it.
    pub fn defaultImportGlobal(self: *const ProgramImage, name: []const u8) ?[]const u8 {
        return self.default_import_globals.get(name);
    }

    /// The pack-installed package-level binding a bare name aliases.
    pub fn packBareAlias(self: *const ProgramImage, name: []const u8) ?[]const u8 {
        return self.pack_bare_aliases.get(name);
    }

    /// The builtin member-extension FQN a member name maps to on the
    /// `kotlin.io` / `kotlin.AutoCloseable` / `kotlin.Any` surfaces.
    pub fn anyMemberGlobal(self: *const ProgramImage, name: []const u8) ?[]const u8 {
        return self.any_member_globals.get(name);
    }

    /// The link-settled body siblings of a bodyless decl, declaration
    /// order, or an empty slice.
    pub fn resolvedRedirects(self: *const ProgramImage, func: FuncId) []const FuncId {
        return self.resolved_redirect.get(func.int()) orelse &.{};
    }

    /// The body sibling a call with `argc` args dispatches to for a
    /// bodyless decl: the first link-settled redirect whose user arity
    /// matches exactly or whose last param is a vararg. This is the
    /// dispatch seam `callFunc` consults — kept here so the pick is unit
    /// testable against synthetic modules.
    pub fn resolvedRedirectTarget(self: *const ProgramImage, module: *const Module, func: FuncId, argc: usize) ?FuncId {
        for (self.resolvedRedirects(func)) |cand| {
            const g = module.funcById(cand) orelse continue;
            const has_this = g.params.len != 0 and std.mem.eql(u8, g.params[0].name, "this");
            const user = if (has_this) g.params.len - 1 else g.params.len;
            const last_vararg = g.params.len != 0 and g.params[g.params.len - 1].is_vararg;
            if (user != argc and !last_vararg) continue;
            return cand;
        }
        return null;
    }

    /// Whether a runtime value can DEFINITELY not bind a parameter whose
    /// declared head is `pn`: only the unambiguous builtin scalar kinds
    /// refute. Permissive everywhere else — the filter exists to
    /// discriminate SAME-ARITY expect redirects, never to re-rank.
    fn redirectParamRefutes(pn: []const u8, v: runtime.Value) bool {
        if (v == .Null) return false;
        var h = pn;
        if (std.mem.lastIndexOfScalar(u8, h, '.')) |d| h = h[d + 1 ..];
        if (std.mem.indexOfScalar(u8, h, '<')) |lt| h = h[0..lt];
        h = std.mem.trimEnd(u8, h, "?");
        const eq = std.mem.eql;
        if (eq(u8, h, "Boolean")) return v != .Bool;
        if (eq(u8, h, "Char")) return v != .Char;
        if (eq(u8, h, "String")) return v != .String;
        if (eq(u8, h, "Int") or eq(u8, h, "Long") or eq(u8, h, "Short") or eq(u8, h, "Byte") or
            eq(u8, h, "UInt") or eq(u8, h, "ULong") or eq(u8, h, "UShort") or eq(u8, h, "UByte"))
        {
            return switch (v) {
                .Int, .Long, .Short, .Byte, .UInt, .ULong, .UShort, .UByte => false,
                else => true,
            };
        }
        if (eq(u8, h, "Float") or eq(u8, h, "Double")) {
            return switch (v) {
                .Float, .Double, .Int, .Long => false,
                else => true,
            };
        }
        return false;
    }

    /// `resolvedRedirectTarget` with the call's VALUES: among same-arity
    /// siblings the pick skips a candidate whose declared scalar param the
    /// value run definitely cannot bind. Two 9-param `ActualParagraph`
    /// actuals differ only at `(ellipsis: Boolean, width: Float)` vs
    /// `(overflow: TextOverflow, constraints: Constraints)`; the
    /// declaration-order pick fed a TextOverflow into `ellipsis` and a
    /// paragraph rendered a value class as its branch condition.
    pub fn resolvedRedirectTargetShaped(self: *const ProgramImage, module: *const Module, func: FuncId, args: []const runtime.Value) ?FuncId {
        if (runtime.envSetOnce("KLIO_REDIR_TRACE")) {
            if (module.funcById(func)) |hf| {
                std.debug.print("[redir] {s}#{d} nargs={d} nredirects={d}\n", .{ hf.fqn, func.int(), args.len, self.resolvedRedirects(func).len });
            }
        }
        var fallback: ?FuncId = null;
        for (self.resolvedRedirects(func)) |cand| {
            const g = module.funcById(cand) orelse continue;
            const has_this = g.params.len != 0 and std.mem.eql(u8, g.params[0].name, "this");
            const user = if (has_this) g.params.len - 1 else g.params.len;
            const last_vararg = g.params.len != 0 and g.params[g.params.len - 1].is_vararg;
            if (user != args.len and !last_vararg) continue;
            if (fallback == null) fallback = cand;
            const off: usize = if (has_this) 1 else 0;
            var refuted = false;
            for (args, 0..) |v, i| {
                if (off + i >= g.params.len) break;
                if (redirectParamRefutes(g.params[off + i].ty.name, v)) {
                    refuted = true;
                    break;
                }
            }
            if (!refuted) return cand;
        }
        return fallback;
    }

    /// The link-time-resolved native form for `func`, or `null` when the
    /// symbol's single form is its lowered body. Consulted by the VM
    /// dispatch paths in place of the deleted per-call FQN short-circuit.
    pub fn resolvedNativeForm(self: *const ProgramImage, func: FuncId) ?StdlibFn {
        return self.resolved_native.get(func.int());
    }
};

/// Single exclusive spin lock, re-exported from `runtime.objcell` so the
/// interpreter, the stdlib concurrency intrinsics, and the shared
/// output/closure handles all share one definition (`coroutines.zig`
/// imports it as `root.SpinMutex`).
pub const SpinMutex = runtime.SpinMutex;

/// Shared serialized stdout sink. The root and every spawned thread
/// write through this so concurrent `println` is serialized; on
/// completion the recorded calls replay into the caller's real sink.
///
/// The program's output sink, shared by every thread. A thin handle over an
/// `ObjRef` cell — the same shared cell `ThreadTable` is built on — so every
/// write takes the cell's exclusive `borrowMut` and concurrent writes serialize.
///
/// Writes STREAM to the destination as they happen. A script runtime has to:
/// `python x.py` and `node x.js` print as they go, and so must klio. Output
/// withheld until exit is output a hanging, looping, or killed program never
/// shows — and a long run would hold its entire output in memory besides.
///
/// The recording arm survives for the callers that attach no destination (the
/// in-process harnesses that compare a whole run): with `dest` null the sink
/// records, and `replayInto` drains it. `attach` flushes whatever was recorded
/// before the destination was known — a top-level initializer runs before the
/// run is handed its sink — and streams from then on.
pub const SharedOutput = struct {
    obj: ObjRef(State),

    pub const State = struct {
        /// Where writes go. Null until `attach`: record instead.
        dest: ?Output = null,
        rec: runtime.RecordingSink,

        pub fn deinit(self: *State) void {
            self.rec.deinit();
        }
    };

    pub fn new(allocator: Allocator) Allocator.Error!SharedOutput {
        const obj = try ObjRef(State).init(allocator, .{ .rec = runtime.RecordingSink.init(allocator) });
        return .{ .obj = obj };
    }

    pub fn clone(self: SharedOutput) SharedOutput {
        return .{ .obj = self.obj.clone() };
    }

    pub fn deinit(self: SharedOutput) void {
        self.obj.deinit();
    }

    /// Stream every write from here on straight to `out`, after flushing
    /// anything recorded before the destination was known.
    pub fn attach(self: SharedOutput, out: Output) void {
        const g = self.obj.borrowMut();
        defer g.deinit();
        const st = g.get();
        st.rec.replayInto(out);
        st.dest = out;
    }

    /// Drain the recording into `out`. A no-op once a destination is attached —
    /// those writes already went straight there.
    pub fn replayInto(self: SharedOutput, out: Output) void {
        const g = self.obj.borrowMut();
        defer g.deinit();
        const st = g.get();
        if (st.dest != null) return;
        st.rec.replayInto(out);
    }

    fn vtWriteln(ctx: *anyopaque, s: []const u8) void {
        const self: SharedOutput = .{ .obj = .{ .cell = @ptrCast(@alignCast(ctx)) } };
        const g = self.obj.borrowMut();
        defer g.deinit();
        const st = g.get();
        if (st.dest) |d| d.writeln(s) else st.rec.output().writeln(s);
    }
    fn vtWrite(ctx: *anyopaque, s: []const u8) void {
        const self: SharedOutput = .{ .obj = .{ .cell = @ptrCast(@alignCast(ctx)) } };
        const g = self.obj.borrowMut();
        defer g.deinit();
        const st = g.get();
        if (st.dest) |d| d.write(s) else st.rec.output().write(s);
    }

    const vtable: Output.VTable = .{ .writeln = vtWriteln, .write = vtWrite };

    pub fn output(self: SharedOutput) Output {
        return .{ .ctx = self.obj.cell, .vtable = &vtable };
    }
};

/// One element of the lambda/closure side-table.
pub const ClosureInfo = struct {
    body_func: FuncId,
    /// A function VALUE loaded from a declaration (`::f`): equal to every
    /// other load of the same function, but never the same object (a
    /// non-capturing lambda literal is; a reference is not).
    is_ref: bool = false,
    /// The module `body_func` indexes when the closure was created inside
    /// a body lowered into a per-method *sub-module* (an anonymous-object
    /// method, property-init thunk, or `init` block). Null means the main
    /// program module. Every invocation site resolves the body against
    /// this module — sub-module `FuncId`s start at 0 and must never be
    /// read through the main module's func table. The pointed-to module
    /// stays live for the whole run (its owning `ObjRef` is held by the
    /// anon-method table or the run arena).
    module: ?*const ir.Module = null,
    n_params: usize,
    /// Whether lowering supplied a declared receiver-shape answer.
    receiver_shape_known: bool = false,
    /// The callable declares an extension receiver outside `n_params`.
    /// Invocation uses this bit rather than guessing from arity or captures.
    has_receiver: bool = false,
    /// Capture names, in the same order as the runtime captures vec.
    capture_names: [][]const u8,
    /// Live capture values. Stored behind a shared interior-mutable
    /// handle so the lambda body's `StoreGlobal` writes propagate.
    captures: ObjRef(std.ArrayList(Value)),
    /// The enclosing-receiver chain at the closure's creation site
    /// (storage order, innermost last). Kotlin receiver scope is lexical:
    /// the body resolves bare names against the receivers in scope where
    /// the lambda literal was written, so every invocation — from any
    /// frame, coroutine resume, or worker thread — seeds the body frame's
    /// chain from this snapshot rather than the dynamic caller's chain.
    chain: []const ir.eval.EnclosingEntry = &.{},

    /// The collection epoch in which a live value last marked this closure
    /// (see `markClosureThunk`). The post-sweep reclamation frees a slot's owned
    /// metadata (`capture_names`, `chain`) once no live value references its id
    /// — i.e. it was not marked in the just-finished collection — so the
    /// append-only spine's per-closure bytes stay bounded by the live set rather
    /// than by total closure-creation events (a per-request leak for a server).
    mark_epoch: usize = 0,
    /// True once the slot's metadata has been reclaimed; the id is never reused
    /// (ids stay append-stable, so no value can dispatch on a stale id).
    reclaimed: bool = false,

    /// No-op tracer: a closure's capture store and receiver chain are kept alive
    /// ONLY while a live value references the closure id (see `markClosureThunk`
    /// / `runtime.gc.markClosureHook`), so the side-table spine must not pin
    /// them — that was the leak. The spine is permanent and never swept, so it
    /// needs no out-edges of its own.
    pub fn gcTrace(self: *const ClosureInfo, m: *runtime.gc.Marker) void {
        _ = self;
        _ = m;
    }
};

/// The process-wide closure side-table the GC's `markClosureHook` consults. All
/// Vms (the main run plus every dispatch/worker child) share one spine by handle
/// clone, so a single installed handle serves every thread's collector.
var active_closures: ?SharedClosures = null;

fn markClosureThunk(id: u64, m: *runtime.gc.Marker) void {
    const sc = active_closures orelse return;
    // Mark the slot live for this epoch (so the post-sweep reclamation spares
    // it), then shade its capture store + receiver chain. Runs during the
    // stop-the-world mark, so the in-place pointer is stable (no concurrent
    // push can realloc the spine).
    if (sc.getPtr(id)) |info| {
        info.mark_epoch = m.epoch;
        for (info.chain) |e| e.v.gcMark(m);
        m.shade(&info.captures.cell.hdr);
    }
}

/// Free the owned metadata of every closure slot no live value referenced in
/// the just-finished collection (`epoch`). Called once after the sweep, still
/// stop-the-world, so the spine is stable and no slot is concurrently pushed.
/// The capture-store cell is collected on its own reachability; ids are never
/// reused.
fn sweepClosuresThunk(epoch: usize) void {
    const sc = active_closures orelse return;
    sc.reclaimDead(epoch);
    if (runtime.gc.gc_debug) {
        const g = sc.obj.borrow();
        const fg = sc.free_ids.borrow();
        const mb = runtime.slab.mapped_bytes.load(.monotonic);
        std.debug.print("[clos] spine={d} free={d} slab_mapped={d}MB\n", .{ g.get().items.len, fg.get().items.len, mb / (1024 * 1024) });
        fg.deinit();
        g.deinit();
    }
}

/// Singleton identity for a closure id: non-zero and stable per (module, body
/// function) when the closure captures nothing (a Kotlin non-capturing-lambda
/// singleton), 0 otherwise. `Value.structuralEq` compares two closures by this
/// identity so two evaluations of the same non-capturing literal — which klio
/// materialises as distinct closure ids — compare equal as they do in Kotlin.
fn closureSingletonThunk(id: u64) u64 {
    const sc = active_closures orelse return 0;
    const info = sc.get(id) orelse return 0;
    // A reclaimed slot's metadata is gone; a captured closure keeps per-instance
    // identity (Kotlin makes only non-capturing lambdas singletons).
    if (info.reclaimed or info.is_ref or info.capture_names.len != 0 or info.chain.len != 0) return 0;
    const mod_bits: u64 = if (info.module) |m| @intFromPtr(m) else 0;
    var h: u64 = 1469598103934665603;
    h = (h ^ mod_bits) *% 1099511628211;
    h = (h ^ info.body_func.int()) *% 1099511628211;
    return h | 1;
}

/// Install the closure-liveness hook with this program's shared side-table.
/// Idempotent across Vms (they share the spine).
pub fn gcInstallClosureHook(closures: SharedClosures) void {
    active_closures = closures;
    runtime.gc.markClosureHook = markClosureThunk;
    runtime.gc.sweepClosureHook = sweepClosuresThunk;
    runtime.gc.closureSingletonHook = closureSingletonThunk;
    // The lazy-`sequence{}` builder holds its parked continuation as an opaque
    // `*ir.eval.SuspendState` in a `Sequence`'s `Builder` source; wire the
    // mark/free hooks so the GC roots and reclaims those frames.
    runtime.gc.markSuspendHook = ir.eval.gcMarkSuspendStateOpaque;
    runtime.gc.freeSuspendHook = ir.eval.freeSuspendStateOpaque;
}

/// Clear program-owned closure hooks before a repeated in-process runner
/// collects the completed program graph and releases its phase arena.
pub fn gcResetProgramHooks() void {
    active_closures = null;
    runtime.gc.markClosureHook = null;
    runtime.gc.sweepClosureHook = null;
    runtime.gc.closureSingletonHook = null;
}

/// Lambda/closure side-table shared across every OS thread of one
/// program. Indices (`Value.IrClosure.id`) are append-stable — `push`
/// only ever extends — so a shared mutex-guarded list keeps cross-thread
/// closure creation sound while every existing id stays valid.
pub const SharedClosures = struct {
    obj: ObjRef(std.ArrayList(ClosureInfo)),
    /// Free list of slot ids reclaimed by `reclaimDead` (no live value
    /// referenced them in the last collection). `push` reuses one before
    /// extending the spine, so the table stays bounded by the live closure set
    /// rather than growing per closure-creation event (an unbounded per-request
    /// leak for a server). Reuse is sound: a slot is freed only after a full
    /// mark proved no live value references its id, and a marked closure value
    /// always marks its slot (`markClosureThunk`), so a reused id can never
    /// alias a still-live value. Shared by handle; touched only under the spine
    /// cell's writer lock or inside the stop-the-world pause.
    free_ids: ObjRef(std.ArrayList(u64)),

    pub fn new(allocator: Allocator) Allocator.Error!SharedClosures {
        const obj = try ObjRef(std.ArrayList(ClosureInfo)).init(allocator, .empty);
        // The side-table is shared across every thread from creation, so
        // `get`/`push` go through the cell's reader/writer lock.
        const free_ids = try ObjRef(std.ArrayList(u64)).init(allocator, .empty);
        return .{ .obj = obj, .free_ids = free_ids };
    }

    pub fn clone(self: SharedClosures) SharedClosures {
        return .{ .obj = self.obj.clone(), .free_ids = self.free_ids.clone() };
    }

    pub fn deinit(self: SharedClosures) void {
        self.obj.deinit();
        self.free_ids.deinit();
    }

    pub fn get(self: SharedClosures, id: usize) ?ClosureInfo {
        const g = self.obj.borrow();
        defer g.deinit();
        const list = g.get();
        if (id >= list.items.len) return null;
        return list.items[id];
    }

    /// In-place slot pointer for the stop-the-world GC mark/sweep only. The
    /// spine only ever grows, and `push` cannot run concurrently with a
    /// collection (the world is stopped), so the returned pointer is stable.
    pub fn getPtr(self: SharedClosures, id: usize) ?*ClosureInfo {
        // A shared borrow: the mark phase reads the slot and must not run
        // the mutable borrow's write barrier (which locks the remembered
        // set the collector may hold).
        const g = self.obj.borrow();
        defer g.deinit();
        const list = g.get();
        if (id >= list.items.len) return null;
        return @constCast(&list.items[id]);
    }

    /// Free the owned metadata of every slot not marked in `epoch` (no live
    /// value references its id). The capture-store cell is swept separately by
    /// reachability; the id is never reused. STW-only.
    pub fn reclaimDead(self: SharedClosures, epoch: usize) void {
        const g = self.obj.borrowMut();
        defer g.deinit();
        const fg = self.free_ids.borrowMut();
        defer fg.deinit();
        const a = self.obj.cell.allocator;
        for (g.get().items, 0..) |*info, idx| {
            if (info.reclaimed or info.mark_epoch == epoch) continue;
            if (info.capture_names.len != 0) a.free(info.capture_names);
            if (info.chain.len != 0) a.free(info.chain);
            info.capture_names = &.{};
            info.chain = &.{};
            info.reclaimed = true;
            fg.get().append(a, @intCast(idx)) catch {};
        }
    }

    /// Bind `info` to a slot, returning its id. Reuses a reclaimed slot (its old
    /// capture-store cell was already swept by reachability, and its fields are
    /// overwritten here before any read) before extending the spine.
    pub fn push(self: SharedClosures, info: ClosureInfo) Allocator.Error!u64 {
        const g = self.obj.borrowMut();
        defer g.deinit();
        const list = g.get();
        {
            const fg = self.free_ids.borrowMut();
            defer fg.deinit();
            if (fg.get().pop()) |id| {
                list.items[@intCast(id)] = info;
                return id;
            }
        }
        const id: u64 = list.items.len;
        try list.append(self.obj.cell.allocator, info);
        return id;
    }
};

/// One spawned OS thread tracked by the host. The thread yields the
/// body's terminal result (an error carries a thrown Kotlin Throwable).
pub const ThreadEntry = struct {
    handle: ?std.Thread,
    /// Terminal result published by the thread body on exit.
    result: ?ThreadResult = null,
    finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

pub const ThreadResult = union(enum) {
    ok: void,
    err: RuntimeError,
};

pub const ThreadTable = ObjRef(std.AutoHashMap(u64, ThreadEntry));

/// First-access initialization state for one `object` / companion
/// singleton, keyed by its lifted global name in `ObjectStates`. A name
/// with no entry is either not yet initialized or already published in
/// `globals`; the gate in `host_globals.ensureObjectSingleton` checks
/// `globals` first, so the table only carries the transient and terminal
/// non-published states.
pub const ObjectInitState = union(enum) {
    /// Construction is running on `thread`. `instance` is set as soon as
    /// the instance shell is materialized, so re-entrant access from the
    /// constructing thread (an object referencing itself during its own
    /// init) observes the partially-initialized singleton, matching
    /// Kotlin. Any other thread waits for the entry to resolve.
    InProgress: struct { thread: std.Thread.Id, instance: ?Value },
    /// The first construction threw. The initializer is never retried.
    /// `cause` holds the original throwable until the first THROWING read
    /// surfaces it (a quiet resolution gate may have consumed the
    /// construction attempt itself, so the wrap-at-construction site never
    /// reached user code); every later access throws
    /// `FileFailedToInitializeException` without the cause, matching
    /// kotlinc.
    Failed: struct { cause: ?Value },

    pub fn gcTrace(self: *const ObjectInitState, m: *runtime.gc.Marker) void {
        switch (self.*) {
            .InProgress => |ip| if (ip.instance) |v| v.gcMark(m),
            .Failed => |f| if (f.cause) |v| v.gcMark(m),
        }
    }
};

/// Shared lazy-`object` init table: one entry per singleton whose
/// construction is in flight or has failed. Shared by handle with every
/// OS thread, like `ThreadTable`; the cell's writer lock serializes the
/// claim that makes first-access construction once-only across threads.
pub const ObjectStates = ObjRef(std.StringHashMap(ObjectInitState));
/// Id-keyed singleton table: `ClassId.int() -> published singleton`. The
/// authoritative read for id-committed class/object/companion value reads;
/// the name-keyed `globals` publication remains as the view user-code name
/// reads resolve through. Publication order: id table first, then names.
pub const SingletonsById = ObjRef(std.AutoHashMap(u32, runtime.Value));

/// Vm-level errors, carried as data.
pub const VmError = union(enum) {
    /// main function not found in module
    InvalidMain,
    /// IR eval: {0}
    Eval: []const u8,
};

/// `Result<Value, VmError>` carried as data.
pub const VmResult = union(enum) {
    ok: Value,
    err: VmError,
};

/// How the default interceptor interprets a `delay` directive.
pub const TimeMode = enum {
    /// Consume real wall-clock time, matching the JVM.
    Wall,
    /// Advance a logical clock instantly — deterministic and fast.
    Virtual,

    pub const default: TimeMode = .Wall;
};

threadlocal var coroutine_time_mode_tls: TimeMode = .Wall;

/// Set the coroutine time mode for the current thread.
pub fn setCoroutineTimeMode(mode: TimeMode) void {
    coroutine_time_mode_tls = mode;
}

/// Current coroutine time mode for this thread.
pub fn coroutineTimeMode() TimeMode {
    return coroutine_time_mode_tls;
}

/// One Vm instance executes a single program against the IR module
/// produced by the front end.
pub const Vm = struct {
    module: ObjRef(Module),
    globals: ObjRef(Env),
    /// Process-wide monotonic instance-id source.
    instance_id_counter: ObjRef(std.atomic.Value(u64)),
    /// Per-class runtime metadata produced by `build.build_module`.
    classes: ObjRef(ClassTable),
    /// Top-level property initialiser `FuncIds`, run at `run` start.
    top_level_props: std.ArrayList(NameFunc),
    /// Enum-entry ctor-arg thunks to evaluate at startup.
    enum_entry_arg_inits: std.ArrayList(EnumEntryArgInit),
    /// Default outer instance to attach to locally-registered classes.
    class_default_outer: ObjRef(OuterTable),
    /// Runtime-lowered method bodies for anonymous-object / local classes.
    anon_methods: AnonMethods,
    /// Closure side-table, shared across threads.
    closures: SharedClosures,
    /// Build-time-immutable program metadata, shared by handle.
    prog: ObjRef(ProgramImage),
    /// Shared serialized stdout sink.
    out_sink: SharedOutput,
    /// Host-side registry of live spawned-thread join handles.
    threads: ThreadTable,
    /// Lazy `object` / companion first-access init states.
    object_states: ObjectStates,
    singletons_by_id: SingletonsById,
    allocator: Allocator,
    /// When set, the enum-entry ctor-arg patch allocates its values and
    /// field buffers here instead of `allocator`. The parity drivers point
    /// it at the shared base cache entry's arena, because the patch writes
    /// into instances that OUTLIVE the program: a per-program value there is
    /// swept at end-of-program collect and dangles for the next program.
    patch_allocator: ?Allocator = null,
    /// Process argv for the program's `main(args: Array<String>)`. Empty
    /// under `klio run`; a bundle passes its argv[1..] through.
    program_args: []const []const u8 = &.{},

    pub const new = run_mod.vmNew;
    pub const fromBuilt = run_mod.vmFromBuilt;
    pub const setInstalledBindings = run_mod.vmSetInstalledBindings;
    pub const makeHost = run_mod.vmMakeHost;
    pub const spawnChild = run_mod.vmSpawnChild;
    pub const runThreadBlock = run_mod.vmRunThreadBlock;
    pub const run = run_mod.vmRun;
    pub const runInner = run_mod.vmRunInner;
    pub const deinit = run_mod.vmDeinit;
    // Embedder entry points for driving non-`main` functions (the test
    // runner): prepare startup, then invoke functions/methods/constructors.
    pub const prepare = run_mod.vmPrepare;
    pub const runCalls = run_mod.vmRunCalls;
    pub const callNoArg = run_mod.vmCallNoArg;
    pub const construct = run_mod.vmConstruct;
    pub const callMethod = run_mod.vmCallMethod;
};

/// Outcome of a single embedder-driven call into a prepared Vm.
pub const CallOutcome = run_mod.CallOutcome;

/// `Send` capture of the shared program state for a new OS thread.
/// Every field is an owned shared handle, so the seed outlives the
/// spawning call and carries no borrow.
pub const SendableVmSeed = struct {
    module: ObjRef(Module),
    globals: ObjRef(Env),
    instance_id_counter: ObjRef(std.atomic.Value(u64)),
    classes: ObjRef(ClassTable),
    prog: ObjRef(ProgramImage),
    anon_methods: AnonMethods,
    class_default_outer: ObjRef(OuterTable),
    closures: SharedClosures,
    out_sink: SharedOutput,
    threads: ThreadTable,
    object_states: ObjectStates,
    singletons_by_id: SingletonsById,
    allocator: Allocator,

    /// Materialize a child `Vm` on the current (new) OS thread.
    pub fn materialize(self: SendableVmSeed) Allocator.Error!Vm {
        return .{
            .module = self.module,
            .globals = self.globals,
            .instance_id_counter = self.instance_id_counter,
            .classes = self.classes,
            .top_level_props = .empty,
            .enum_entry_arg_inits = .empty,
            .class_default_outer = self.class_default_outer,
            .anon_methods = self.anon_methods,
            .closures = self.closures,
            .prog = self.prog,
            .out_sink = self.out_sink,
            .threads = self.threads,
            .object_states = self.object_states,
            .singletons_by_id = self.singletons_by_id,
            .allocator = self.allocator,
        };
    }
};

/// Whether `name` names a property (not a function) reachable on
/// `receiver`'s class. Walks the parent chain and declared supertypes.
pub fn memberIsProperty(allocator: Allocator, classes: *const ObjRef(ClassTable), receiver: *const Value, name: []const u8) bool {
    const start: ObjRef(ClassDef) = switch (receiver.*) {
        .Instance => |inst| blk: {
            const g = inst.borrow();
            defer g.deinit();
            for (g.get().fields.items) |f| {
                if (std.mem.eql(u8, f.name, name)) return true;
            }
            break :blk g.get().class.clone();
        },
        .Class => |cls| cls.clone(),
        else => return false,
    };
    defer start.deinit();

    var stack: std.ArrayList(ObjRef(ClassDef)) = .empty;
    defer {
        for (stack.items) |c| c.deinit();
        stack.deinit(allocator);
    }
    stack.append(allocator, start.clone()) catch return false;

    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(allocator);

    while (stack.pop()) |c| {
        defer c.deinit();
        const cg = c.borrow();
        defer cg.deinit();
        const cdef = cg.get();
        var already = false;
        for (seen.items) |s| {
            if (std.mem.eql(u8, s, cdef.name)) {
                already = true;
                break;
            }
        }
        if (already) continue;
        seen.append(allocator, cdef.name) catch return false;

        for (cdef.primary_params) |p| {
            if (p.property != null and std.mem.eql(u8, p.name, name)) return true;
        }
        for (cdef.body_properties) |p| {
            if (std.mem.eql(u8, p.name, name)) return true;
        }
        if (cdef.parent) |parent| {
            stack.append(allocator, parent.clone()) catch return false;
        }
        for (cdef.supertype_names) |sn| {
            const tg = classes.borrow();
            defer tg.deinit();
            if (tg.get().get(sn)) |sc| {
                stack.append(allocator, sc.clone()) catch return false;
            }
        }
    }
    return false;
}

/// Whether a body's declared primitive parameter type can accept `v`.
/// Conservative: only a definite concrete-primitive-vs-different-
/// primitive pairing rejects.
pub fn primitiveParamAccepts(type_name: []const u8, v: *const Value) bool {
    const arg_is_primitive = switch (v.*) {
        .Int, .Long, .Short, .Byte, .UInt, .ULong, .UShort, .UByte, .Double, .Float, .Char, .Bool, .String => true,
        else => false,
    };
    if (!arg_is_primitive) return true;
    const eq = std.mem.eql;
    if (eq(u8, type_name, "Int")) return v.* == .Int;
    if (eq(u8, type_name, "Long")) return v.* == .Long;
    if (eq(u8, type_name, "Short")) return v.* == .Short;
    if (eq(u8, type_name, "Byte")) return v.* == .Byte;
    if (eq(u8, type_name, "UInt")) return v.* == .UInt;
    if (eq(u8, type_name, "ULong")) return v.* == .ULong;
    if (eq(u8, type_name, "UShort")) return v.* == .UShort;
    if (eq(u8, type_name, "UByte")) return v.* == .UByte;
    if (eq(u8, type_name, "Double")) return v.* == .Double;
    if (eq(u8, type_name, "Float")) return v.* == .Float;
    if (eq(u8, type_name, "Char")) return v.* == .Char;
    if (eq(u8, type_name, "Boolean")) return v.* == .Bool;
    if (eq(u8, type_name, "String")) return v.* == .String;
    return true;
}

fn simpleName(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| return name[i + 1 ..];
    return name;
}

fn allAsciiUpper(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isUpper(c)) return false;
    }
    return true;
}

/// Permissive receiver/param-type compatibility used by extension
/// overload pickers. Returns false only when the runtime value provably
/// does not satisfy the parameter's nominal type.
pub fn receiverCompatibleWithParam(receiver: *const Value, param_ty: *const TypeRef) bool {
    if (receiver.* == .Instance) return true;
    const pn_simple = simpleName(param_ty.name);
    if (std.mem.eql(u8, pn_simple, "Any") or
        std.mem.eql(u8, pn_simple, "Any?") or
        std.mem.eql(u8, pn_simple, "Unit") or
        std.mem.startsWith(u8, pn_simple, "Function") or
        (pn_simple.len <= 2 and allAsciiUpper(pn_simple)))
    {
        return true;
    }
    return receiver.isRuntimeType(pn_simple);
}

/// True when an extension's declared receiver type name denotes a user /
/// pack class — i.e. not a builtin, an open supertype a builtin
/// satisfies, or a bare type parameter.
pub fn extDeclRecvIsUserClass(ty_name: []const u8) bool {
    const s = simpleName(ty_name);
    if (s.len == 0) return false;
    if (s.len <= 2 and allAsciiUpper(s)) return false;
    const builtins = std.StaticStringMap(void).initComptime(.{
        .{"String"},       .{"StringBuilder"},     .{"CharSequence"},  .{"Appendable"},   .{"Int"},          .{"Long"},
        .{"Short"},        .{"Byte"},              .{"Double"},        .{"Float"},        .{"Char"},         .{"Boolean"},
        .{"Number"},       .{"Array"},             .{"List"},          .{"MutableList"},  .{"Collection"},   .{"Iterable"},
        .{"Map"},          .{"MutableMap"},        .{"Set"},           .{"MutableSet"},   .{"Sequence"},     .{"Comparable"},
        .{"Any"},          .{"Unit"},              .{"UInt"},          .{"ULong"},        .{"UShort"},       .{"UByte"},
        .{"ByteArray"},    .{"ShortArray"},        .{"IntArray"},      .{"LongArray"},    .{"CharArray"},    .{"BooleanArray"},
        .{"FloatArray"},   .{"DoubleArray"},       .{"UByteArray"},    .{"UShortArray"},  .{"UIntArray"},    .{"ULongArray"},
        .{"Iterator"},     .{"MutableIterator"},   .{"ListIterator"},  .{"MutableListIterator"},             .{"MutableIterable"},
        .{"MutableCollection"},                    .{"Comparator"},    .{"Enum"},         .{"Throwable"},    .{"Nothing"},
        .{"IntRange"},     .{"LongRange"},         .{"CharRange"},     .{"ClosedRange"},  .{"Pair"},         .{"Triple"},
    });
    if (builtins.has(s)) return false;
    return true;
}

/// True when `fqn` names a builtin `kotlin.*` Throwable-hierarchy class
/// that klio constructs as a host `Value.Exception` rather than a
/// generic Instance.
pub fn isBuiltinThrowableFqn(fqn: []const u8) bool {
    const names = [_][]const u8{
        "kotlin.Throwable",                       "kotlin.Exception",
        "kotlin.Error",                           "kotlin.RuntimeException",
        "kotlin.IllegalArgumentException",        "kotlin.IllegalStateException",
        "kotlin.IndexOutOfBoundsException",       "kotlin.NullPointerException",
        "kotlin.ArithmeticException",             "kotlin.ClassCastException",
        "kotlin.NoSuchElementException",          "kotlin.NumberFormatException",
        "kotlin.UnsupportedOperationException",   "kotlin.NoWhenBranchMatchedException",
        "kotlin.ConcurrentModificationException", "kotlin.AssertionError",
        "kotlin.UninitializedPropertyAccessException",
        "kotlin.coroutines.cancellation.CancellationException",
    };
    for (names) |n| {
        if (std.mem.eql(u8, fqn, n)) return true;
    }
    return false;
}

/// True for a builtin (non-`Instance`, non-`Class`) value.
pub fn valueIsBuiltin(v: *const Value) bool {
    return switch (v.*) {
        .String, .StringBuilder, .Int, .Long, .Short, .Byte, .Double, .Float, .Char, .Bool, .Array, .List, .Map, .Result => true,
        else => false,
    };
}

/// A `TypeRef` denoting a Kotlin function type.
pub fn isFunctionType(ty: *const TypeRef) bool {
    const n = simpleName(ty.name);
    return std.mem.startsWith(u8, n, "Function") or
        std.mem.indexOf(u8, ty.name, "->") != null;
}

/// Whether a runtime value can be invoked as `f(...)`.
pub fn valueIsCallable(v: *const Value) bool {
    return switch (v.*) {
        .IrClosure, .Intrinsic, .BoundMethod, .PropertyRef => true,
        else => false,
    };
}

/// True when `v` is a `Value.Exception` whose `fqn` names a
/// `CancellationException` (including the timeout variant).
pub fn isCancellationException(v: *const Value) bool {
    switch (v.*) {
        .Exception => |e| {
            const g = e.fqn.borrow();
            defer g.deinit();
            const s = g.get().bytes;
            return std.mem.endsWith(u8, s, "CancellationException") or
                std.mem.endsWith(u8, s, "TimeoutCancellationException");
        },
        .Instance => |inst| {
            const g = inst.borrow();
            defer g.deinit();
            const cg = g.get().class.borrow();
            defer cg.deinit();
            const name = cg.get().name;
            return std.mem.endsWith(u8, name, "CancellationException") or
                std.mem.endsWith(u8, name, "TimeoutCancellationException");
        },
        else => return false,
    }
}

/// Arm the eval-loop wall-clock deadline so an in-process program that spins in
/// the eval loop aborts with "test wall-clock deadline exceeded" instead of
/// hanging the whole test binary. For the in-process itest harnesses only (the
/// CLI runs `Vm.run` directly and is never capped). Catches infinite loops in
/// the eval loop; a pure deadlock blocked off the eval loop is not covered.
/// `cap_ms <= 0` disarms.
pub fn armTestWallDeadlineMs(cap_ms: i64) void {
    if (cap_ms <= 0) {
        ir.eval.test_wall_deadline_ms.store(0, .monotonic);
        return;
    }
    ir.eval.test_wall_deadline_ms.store(ir.eval.nowMonotonicMs() + cap_ms, .monotonic);
}

pub fn clearTestWallDeadline() void {
    ir.eval.test_wall_deadline_ms.store(0, .monotonic);
}

const testing = std.testing;

test {
    testing.refAllDecls(@This());
    _ = build;
    _ = vmhost;
    _ = run_mod;
}

test "value_is_callable / value_is_builtin classification" {
    const i: Value = .{ .Int = 1 };
    try testing.expect(valueIsBuiltin(&i));
    try testing.expect(!valueIsCallable(&i));
    const p: Value = .{ .PropertyRef = .{ .name = try runtime.strInit(testing.allocator, "x") } };
    defer p.PropertyRef.name.deinit();
    try testing.expect(valueIsCallable(&p));
    try testing.expect(!valueIsBuiltin(&p));
}

test "is_builtin_throwable_fqn matches exact builtin names only" {
    try testing.expect(isBuiltinThrowableFqn("kotlin.IllegalStateException"));
    try testing.expect(!isBuiltinThrowableFqn("my.app.Error"));
}

test "ext_decl_recv_is_user_class rejects builtins and type params" {
    try testing.expect(!extDeclRecvIsUserClass("String"));
    try testing.expect(!extDeclRecvIsUserClass("T"));
    try testing.expect(extDeclRecvIsUserClass("com.example.Widget"));
    // The primitive-array and unsigned families are builtins too: classifying
    // ByteArray as a user class made the incompatible-receiver guard strip
    // the names off `decodeToString(throwOnInvalidSequence = true)`.
    try testing.expect(!extDeclRecvIsUserClass("ByteArray"));
    try testing.expect(!extDeclRecvIsUserClass("kotlin.ByteArray"));
    try testing.expect(!extDeclRecvIsUserClass("UIntArray"));
    try testing.expect(!extDeclRecvIsUserClass("ULong"));
    try testing.expect(!extDeclRecvIsUserClass("Iterator"));
    try testing.expect(!extDeclRecvIsUserClass("Comparator"));
}

fn linkTestNativeFn(ctx: *runtime.CallCtx) std.mem.Allocator.Error!runtime.EvalResult {
    _ = ctx;
    return .{ .ok = Value.Unit };
}

fn pushLinkTestFunc(m: *Module, a: Allocator, name: []const u8, fqn: []const u8) Allocator.Error!FuncId {
    return pushLinkTestFuncOpts(m, a, name, fqn, false);
}

fn pushLinkTestFuncParams(m: *Module, a: Allocator, name: []const u8, fqn: []const u8, n_params: usize, last_vararg: bool) Allocator.Error!FuncId {
    const id = try pushLinkTestFuncOpts(m, a, name, fqn, false);
    const params = try a.alloc(ir.Param, n_params);
    for (params, 0..) |*pp, i| {
        pp.* = .{
            .name = "p",
            .ty = .{ .name = "Int", .nullable = false, .args = &.{} },
            .default = null,
            .is_vararg = last_vararg and i == n_params - 1,
        };
    }
    m.funcByIdMut(id).?.params = params;
    return id;
}

fn pushLinkTestFuncPkg(m: *Module, a: Allocator, name: []const u8, fqn: []const u8, package: []const u8, bodyless: bool) Allocator.Error!FuncId {
    const id = m.nextFuncId();
    const blocks = try a.alloc(ir.Block, if (bodyless) 0 else 1);
    if (!bodyless) {
        blocks[0] = .{ .id = ir.BlockId.from(0), .insts = &.{}, .terminator = .{ .Return = null } };
    }
    try m.funcs.append(a, .{
        .id = id,
        .name = name,
        .fqn = fqn,
        .package = package,
        .params = &.{},
        .return_ty = .{ .name = "Unit", .nullable = false, .args = &.{} },
        .n_locals = 0,
        .blocks = blocks,
        .entry = ir.BlockId.from(0),
        .is_suspend = false,
        .is_expect = bodyless,
    });
    try m.func_index.append(a, .{ .name = name, .id = id });
    return id;
}

fn pushLinkTestFuncOpts(m: *Module, a: Allocator, name: []const u8, fqn: []const u8, bodyless: bool) Allocator.Error!FuncId {
    const id = m.nextFuncId();
    const blocks = try a.alloc(ir.Block, if (bodyless) 0 else 1);
    if (!bodyless) {
        blocks[0] = .{ .id = ir.BlockId.from(0), .insts = &.{}, .terminator = .{ .Return = null } };
    }
    try m.funcs.append(a, .{
        .id = id,
        .name = name,
        .fqn = fqn,
        .package = "",
        .params = &.{},
        .return_ty = .{ .name = "Unit", .nullable = false, .args = &.{} },
        .n_locals = 0,
        .blocks = blocks,
        .entry = ir.BlockId.from(0),
        .is_suspend = false,
    });
    try m.func_index.append(a, .{ .name = name, .id = id });
    return id;
}

test "linkResolvedForms binds one form per symbol from the installed overlay" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer {
        for (m.funcs.items) |f| a.free(f.blocks);
        m.deinit(a);
    }
    // Two body-bearing funcs; only the first's FQN has a native binding.
    const shimmed = try pushLinkTestFunc(&m, a, "now", "kotlinx.datetime.now");
    const plain = try pushLinkTestFunc(&m, a, "plain", "app.plain");
    // The link resolves natives by simple name through the name index (as the
    // real build does after a `rebuildFuncNameIndex`); build it for the test.
    try m.rebuildFuncNameIndex(a);

    var prog = try ProgramImage.init(a);
    defer prog.deinit();

    // Empty overlay: every symbol's form is its lowered body.
    try prog.linkResolvedForms(&m);
    try testing.expect(prog.resolved_linked);
    try testing.expect(prog.resolvedNativeForm(shimmed) == null);
    try testing.expect(prog.resolvedNativeForm(plain) == null);

    // Install a binding for the shimmed FQN, re-link, and confirm the
    // resolved form is the native binding for that symbol and the lowered
    // body (absent) for the other — exactly what the deleted per-call
    // `installed_bindings.resolve(fqn)` short-circuit would have picked.
    {
        const bg = prog.installed_bindings.borrowMut();
        defer bg.deinit();
        try bg.get().register("kotlinx.datetime.now", linkTestNativeFn);
    }
    try prog.linkResolvedForms(&m);
    const resolved = prog.resolvedNativeForm(shimmed);
    try testing.expect(resolved != null);
    try testing.expect(resolved.? == linkTestNativeFn);
    try testing.expect(prog.resolvedNativeForm(plain) == null);

    // Re-linking is idempotent and rebuilds the table from the current
    // overlay: clearing the binding drops the resolved native form.
    {
        const bg = prog.installed_bindings.borrowMut();
        defer bg.deinit();
        _ = bg.get().table.remove("kotlinx.datetime.now");
    }
    try prog.linkResolvedForms(&m);
    try testing.expect(prog.resolvedNativeForm(shimmed) == null);
}

test "linkResolvedForms settles a member-form binding onto the class method" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer {
        for (m.funcs.items) |f| a.free(f.blocks);
        m.deinit(a);
    }
    // A body-bearing method reached only through its class: member funcs
    // are not in the simple-name index, so the member leg must resolve the
    // binding key's class prefix and mark the method native (the
    // `ReentrantLock.lock` placeholder-body shape).
    const lock_m = try pushLinkTestFunc(&m, a, "lock", "kx.locks.ReentrantLock.lock");
    _ = m.func_index.pop();
    try m.rebuildFuncNameIndex(a);
    const methods = try a.alloc(FuncId, 1);
    defer a.free(methods);
    methods[0] = lock_m;
    try m.classes.append(a, .{
        .id = ir.ClassId.from(0),
        .name = "ReentrantLock",
        .fqn = "kx.locks.ReentrantLock",
        .primary_params = &.{},
        .methods = methods,
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    defer _ = m.classes.pop();

    var prog = try ProgramImage.init(a);
    defer prog.deinit();
    {
        const bg = prog.installed_bindings.borrowMut();
        defer bg.deinit();
        try bg.get().register("kx.locks.ReentrantLock.lock", linkTestNativeFn);
    }
    try prog.linkResolvedForms(&m);
    const resolved = prog.resolvedNativeForm(lock_m);
    try testing.expect(resolved != null);
    try testing.expect(resolved.? == linkTestNativeFn);
}

test "linkResolvedForms keeps a structurally generic overload body" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer {
        for (m.funcs.items) |f| {
            a.free(f.blocks);
            if (f.params.len != 0) a.free(f.params);
        }
        m.deinit(a);
    }

    const fqn = "kotlin.comparisons.choose";
    const generic = try pushLinkTestFuncParams(&m, a, "choose", fqn, 3, false);
    const concrete = try pushLinkTestFuncParams(&m, a, "choose", fqn, 3, false);
    var comparator_args = [_]ir.TypeRef{.{ .name = "in#T", .nullable = false, .args = &.{} }};
    const gp = @constCast(m.funcById(generic).?.params);
    gp[0].ty = .{ .name = "T", .nullable = false, .args = &.{} };
    gp[1].ty = .{ .name = "T", .nullable = false, .args = &.{} };
    gp[1].is_vararg = true;
    gp[2].ty = .{ .name = "Comparator", .nullable = false, .args = &comparator_args };
    var type_params: std.ArrayList([]const u8) = .empty;
    try type_params.append(a, "T");
    try m.registry.func_type_params.put(generic, type_params);
    try m.rebuildFuncNameIndex(a);

    var prog = try ProgramImage.init(a);
    defer prog.deinit();
    {
        const bg = prog.installed_bindings.borrowMut();
        defer bg.deinit();
        try bg.get().register(fqn, linkTestNativeFn);
    }
    try prog.linkResolvedForms(&m);

    try testing.expect(prog.resolvedNativeForm(generic) == null);
    try testing.expect(prog.resolvedNativeForm(concrete) != null);
}

test "a bodyless expect never links to a same-named function in another package" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer {
        for (m.funcs.items) |f| a.free(f.blocks);
        m.deinit(a);
    }
    // An `actual` declares its `expect`'s package. A same-named function in a
    // DIFFERENT package is an unrelated declaration: linking it would make a call
    // to an unimplemented `expect` silently run a stranger's body.
    const expect_fn = try pushLinkTestFuncPkg(&m, a, "getStr", "p1.getStr", "p1", true);
    const same_pkg = try pushLinkTestFuncPkg(&m, a, "getStr", "p1.getStr", "p1", false);
    _ = try pushLinkTestFuncPkg(&m, a, "getStr", "p2.getStr", "p2", false);
    try m.rebuildFuncNameIndex(a);

    var prog = try ProgramImage.init(a);
    defer prog.deinit();
    try prog.linkResolvedForms(&m);

    const redirects = prog.resolvedRedirects(expect_fn);
    for (redirects) |r| {
        const g = m.funcById(r).?;
        try testing.expectEqualStrings("p1", g.package);
    }
    try testing.expectEqual(same_pkg.int(), prog.resolvedRedirectTarget(&m, expect_fn, 0).?.int());
}

test "linkResolvedForms settles bodyless decls: sibling redirect, FQN native, map native" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer {
        for (m.funcs.items) |f| a.free(f.blocks);
        m.deinit(a);
    }
    // expect→actual shape: bodyless decl with a body-bearing sibling.
    const expect_fn = try pushLinkTestFuncOpts(&m, a, "ping", "app.ping", true);
    const actual_fn = try pushLinkTestFunc(&m, a, "ping", "app.ping.impl");
    // Bodyless decl whose declared FQN is an embedded intrinsic.
    const abs_decl = try pushLinkTestFuncOpts(&m, a, "abs", "kotlin.math.abs", true);
    // Bodyless decl whose declared FQN is unknown, but whose simple name
    // maps into the implicit stdlib surface.
    const sqrt_decl = try pushLinkTestFuncOpts(&m, a, "sqrt", "mylib.sqrt", true);
    // Body-bearing func: the embedded registry must NOT shadow its body.
    const body_abs = try pushLinkTestFunc(&m, a, "abs", "kotlin.math.abs");
    try m.rebuildFuncNameIndex(a);

    var prog = try ProgramImage.init(a);
    defer prog.deinit();
    try prog.linkResolvedForms(&m);

    // Sibling redirect recorded in declaration order; no native form.
    const redirects = prog.resolvedRedirects(expect_fn);
    try testing.expect(redirects.len >= 1);
    try testing.expectEqual(actual_fn.int(), redirects[0].int());
    try testing.expect(prog.resolvedNativeForm(actual_fn) == null);
    // The dispatch seam picks that sibling for a fitting call and
    // declines a non-fitting one (zero-param sibling, one-arg call).
    try testing.expectEqual(actual_fn.int(), prog.resolvedRedirectTarget(&m, expect_fn, 0).?.int());
    try testing.expect(prog.resolvedRedirectTarget(&m, expect_fn, 1) == null);

    // Exact-FQN embedded native bound for the bodyless decl only.
    try testing.expect(prog.resolvedNativeForm(abs_decl) != null);
    try testing.expect(prog.resolvedNativeForm(body_abs) == null);

    // Map-resolved native: `sqrt` maps to kotlin.math.sqrt.
    try testing.expect(prog.resolvedNativeForm(sqrt_decl) != null);
    try testing.expectEqualStrings("kotlin.math.sqrt", prog.defaultImportGlobal("sqrt").?);
}

test "linkResolvedForms joins a receiver declaration through its exact host symbol" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer {
        for (m.funcs.items) |f| a.free(f.blocks);
        m.deinit(a);
    }
    const repeat = try pushLinkTestFuncOpts(&m, a, "repeat", "kotlin.text.repeat", true);
    const repeat_body = try pushLinkTestFunc(&m, a, "repeat", "kotlin.text.repeat");
    try m.decl_sigs.put(repeat.int(), .{
        .receiver_ty = .{ .name = "String", .nullable = false, .args = &.{} },
        .arity = .{ .required = 1, .total = 1, .has_vararg = false },
        .sig = &.{.{ .name = "Int", .nullable = false, .args = &.{} }},
        .kind = .top_level_extension,
        .host_symbol = "kotlin.String.repeat",
    });
    try m.decl_sigs.put(repeat_body.int(), .{
        .receiver_ty = .{ .name = "String", .nullable = false, .args = &.{} },
        .arity = .{ .required = 1, .total = 1, .has_vararg = false },
        .sig = &.{.{ .name = "Int", .nullable = false, .args = &.{} }},
        .kind = .top_level_extension,
        .has_body = true,
        .host_symbol = "kotlin.String.repeat",
    });
    try m.rebuildFuncNameIndex(a);

    var prog = try ProgramImage.init(a);
    defer prog.deinit();
    try prog.linkResolvedForms(&m);

    try testing.expect(prog.resolvedNativeForm(repeat) != null);
    try testing.expect(prog.resolvedNativeForm(repeat).? ==
        stdlib.implementation("kotlin.String.repeat").?);
    try testing.expect(prog.resolvedNativeForm(repeat_body) == null);
}

test "bodyless redirect dispatch picks by exact arity, then vararg" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer {
        for (m.funcs.items) |f| {
            a.free(f.blocks);
            if (f.params.len != 0) a.free(f.params);
        }
        m.deinit(a);
    }
    const stub = try pushLinkTestFuncOpts(&m, a, "pick", "app.pick", true);
    const two = try pushLinkTestFuncParams(&m, a, "pick", "app.pick.two", 2, false);
    const vararg = try pushLinkTestFuncParams(&m, a, "pick", "app.pick.va", 1, true);
    try m.rebuildFuncNameIndex(a);

    var prog = try ProgramImage.init(a);
    defer prog.deinit();
    try prog.linkResolvedForms(&m);

    // Exact arity wins; a non-matching count falls to the vararg form;
    // the vararg form also absorbs zero extra args.
    try testing.expectEqual(two.int(), prog.resolvedRedirectTarget(&m, stub, 2).?.int());
    try testing.expectEqual(vararg.int(), prog.resolvedRedirectTarget(&m, stub, 3).?.int());
    try testing.expectEqual(vararg.int(), prog.resolvedRedirectTarget(&m, stub, 0).?.int());
    // A body-bearing func never redirects.
    try testing.expect(prog.resolvedRedirectTarget(&m, two, 2) == null);
}

test "link-time bare-name maps are deterministic and package-ranked" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer m.deinit(a);
    var prog = try ProgramImage.init(a);
    defer prog.deinit();
    {
        const bg = prog.installed_bindings.borrowMut();
        defer bg.deinit();
        // Package-level pack binding: bare-aliasable.
        try bg.get().register("kotlinx.coroutines.runBlocking", linkTestNativeFn);
        // Receiver-qualified member binding: never bare-aliasable.
        try bg.get().register("kotlinx.coroutines.Job.join", linkTestNativeFn);
        // Same leaf from two packages: smallest FQN wins, hash-order free.
        try bg.get().register("kotlinx.serialization.encode", linkTestNativeFn);
        try bg.get().register("kotlinx.io.encode", linkTestNativeFn);
    }
    try prog.linkResolvedForms(&m);

    try testing.expectEqualStrings("kotlinx.coroutines.runBlocking", prog.packBareAlias("runBlocking").?);
    try testing.expect(prog.packBareAlias("join") == null);
    try testing.expectEqualStrings("kotlinx.io.encode", prog.packBareAlias("encode").?);

    // Default-import map: the embedded registry feeds it (`min` maps to
    // kotlin.math.min; no other bare-mappable `min` exists today) and the
    // implicit surface always carries the array builders. Unconditional:
    // a dropped key must fail, not pass silently.
    try testing.expectEqualStrings("kotlin.math.min", prog.defaultImportGlobal("min").?);
    try testing.expectEqualStrings("kotlin.intArrayOf", prog.defaultImportGlobal("intArrayOf").?);

    // Member-surface map: `kotlin.io`'s receiver-less globals must NOT be
    // member edges — serving `println` member-style printed the receiver
    // (`with(x) { println() }` printed `x`). No source registers a
    // `kotlin.AutoCloseable.*` / `kotlin.Any.*` FQN today — `use` stays
    // absent too.
    try testing.expect(prog.anyMemberGlobal("println") == null);
    try testing.expect(prog.anyMemberGlobal("print") == null);
    try testing.expect(prog.anyMemberGlobal("use") == null);
}

test "link-time bare-name maps rank a cross-package collision first-package-wins" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer m.deinit(a);
    var prog = try ProgramImage.init(a);
    defer prog.deinit();
    {
        const bg = prog.installed_bindings.borrowMut();
        defer bg.deinit();
        // Same simple name registered under two `bare_probe_packages`
        // members: the earlier-ranked package must win regardless of
        // registration or hash order (kotlin.math ranks above kotlin.io).
        try bg.get().register("kotlin.io.zzzCollide", linkTestNativeFn);
        try bg.get().register("kotlin.math.zzzCollide", linkTestNativeFn);
        // Any-member surface collision: kotlin.AutoCloseable ranks above
        // kotlin.Any.
        try bg.get().register("kotlin.Any.zzzUse", linkTestNativeFn);
        try bg.get().register("kotlin.AutoCloseable.zzzUse", linkTestNativeFn);
    }
    try prog.linkResolvedForms(&m);
    try testing.expectEqualStrings("kotlin.math.zzzCollide", prog.defaultImportGlobal("zzzCollide").?);
    try testing.expectEqualStrings("kotlin.AutoCloseable.zzzUse", prog.anyMemberGlobal("zzzUse").?);
    // Production pin for the one real cross-package collision in the
    // embedded registry: StringBuilder is registered under both `kotlin`
    // and `kotlin.text`, and `kotlin` ranks first. A rank-order
    // regression flips this pick.
    try testing.expectEqualStrings("kotlin.StringBuilder", prog.defaultImportGlobal("StringBuilder").?);
}

test "shared closures push is append-stable" {
    const sc = try SharedClosures.new(testing.allocator);
    defer sc.deinit();
    const caps = try ObjRef(std.ArrayList(Value)).init(testing.allocator, .empty);
    defer caps.deinit();
    const id0 = try sc.push(.{ .body_func = .from(0), .n_params = 0, .capture_names = &.{}, .captures = caps });
    const id1 = try sc.push(.{ .body_func = .from(1), .n_params = 0, .capture_names = &.{}, .captures = caps });
    try testing.expectEqual(@as(u64, 0), id0);
    try testing.expectEqual(@as(u64, 1), id1);
    try testing.expect(sc.get(0) != null);
    try testing.expect(sc.get(2) == null);
}

test "dispatch cache method identities survive runtime string address reuse" {
    var prog = try ProgramImage.init(testing.allocator);
    defer prog.deinit();

    var runtime_name = [_]u8{ 't', 'o', 'D', 'o', 'u', 'b', 'l', 'e' };
    const double_id = prog.memberNameIdentity(&runtime_name).?;
    @memcpy(&runtime_name, "toUShort");
    const ushort_id = prog.memberNameIdentity(&runtime_name).?;
    try testing.expect(double_id != ushort_id);

    @memcpy(&runtime_name, "toDouble");
    try testing.expectEqual(double_id, prog.memberNameIdentity(&runtime_name).?);
}

test "closure singleton identity excludes lexical receiver chains" {
    const sc = try SharedClosures.new(testing.allocator);
    defer sc.deinit();
    active_closures = sc;
    defer active_closures = null;
    const caps = try ObjRef(std.ArrayList(Value)).init(testing.allocator, .empty);
    defer caps.deinit();

    const plain0 = try sc.push(.{ .body_func = .from(7), .n_params = 0, .capture_names = &.{}, .captures = caps });
    const plain1 = try sc.push(.{ .body_func = .from(7), .n_params = 0, .capture_names = &.{}, .captures = caps });
    try testing.expect(closureSingletonThunk(plain0) != 0);
    try testing.expectEqual(closureSingletonThunk(plain0), closureSingletonThunk(plain1));

    const chain = &[_]ir.eval.EnclosingEntry{.{ .v = .Unit }};
    const lexical = try sc.push(.{ .body_func = .from(7), .n_params = 0, .capture_names = &.{}, .captures = caps, .chain = chain });
    try testing.expectEqual(@as(u64, 0), closureSingletonThunk(lexical));
}

test "shared output records and replays into the real sink" {
    const shared = try SharedOutput.new(testing.allocator);
    defer shared.deinit();
    const sink = shared.output();
    sink.write("x");
    sink.writeln("y");
    sink.writeln("z");

    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    shared.replayInto(cap.output());

    try testing.expectEqual(@as(usize, 2), cap.lines.items.len);
    try testing.expectEqualStrings("xy", cap.lines.items[0]);
    try testing.expectEqualStrings("z", cap.lines.items[1]);
}

test "shared output clone shares one inner sink" {
    const shared = try SharedOutput.new(testing.allocator);
    defer shared.deinit();
    const other = shared.clone();
    defer other.deinit();
    try testing.expect(ObjRef(SharedOutput.State).ptrEq(shared.obj, other.obj));

    shared.output().writeln("a");
    other.output().writeln("b");

    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    other.replayInto(cap.output());

    try testing.expectEqual(@as(usize, 2), cap.lines.items.len);
    try testing.expectEqualStrings("a", cap.lines.items[0]);
    try testing.expectEqualStrings("b", cap.lines.items[1]);
}
