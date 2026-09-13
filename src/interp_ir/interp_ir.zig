//! IR-native interpreter: `Vm` executes a frozen `ir.Module` end-to-end, with
//! no AST evaluator behind it. `build_module` lowers the driver's AST.

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

/// Composer-stack intrinsics the loader merges into the host bindings.
pub const compose = @import("vm/compose.zig");
pub const coroutines_diag = @import("vm/coroutines.zig");

/// Assert empty and clear the process-wide receiver/coroutine thread-locals at
/// a run boundary; leaked cross-run state is a loud Debug failure.
pub const resetReceiverThreadLocals = vmhost.resetReceiverThreadLocals;
pub const resetRunGlobalCaches = vmhost.resetRunGlobalCaches;
/// Drop this thread's per-function JIT state between programs.
pub const resetJitForTest = ir.jit_loop.resetForTest;
pub const resetLenientWarned = @import("vm/host_call_member.zig").resetLenientWarned;

/// Member dispatch for consumers holding a declaration rather than a live
/// interpreter: the native backend classifies call sites with `hostSlotOpOfFqn`.
pub const member_dispatch = @import("vm/host_call_member.zig");

/// Field reads for the same consumers, through `hostFreeProperty`.
pub const member_fields = @import("vm/host_fields.zig");

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

/// Normalized head of a declared parameter type. Every function-type spelling
/// collapses to `Function`: `(T) -> R` as written, `Function1` once lowered.
pub fn anonParamTypeHead(name: []const u8) []const u8 {
    if (std.mem.indexOf(u8, name, "->") != null) return "Function";
    if (std.mem.startsWith(u8, name, "Function")) return "Function";
    if (std.mem.startsWith(u8, name, "suspend")) return "Function";
    if (std.mem.eql(u8, name, "<function>")) return "Function";
    const bare = std.mem.trimEnd(u8, name, "?");
    const dot = std.mem.lastIndexOfScalar(u8, bare, '.') orelse return bare;
    return bare[dot + 1 ..];
}

/// Whether two declarations name the same parameter types, by normalized head;
/// a leading `this` is the receiver. Separates same-name, same-arity overrides.
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

/// `name#arity#<n>`: the arity key plus the declaration's index among the
/// class's same-name, same-arity members, which the plain key cannot reach.
pub fn anonOverloadMemberName(
    allocator: Allocator,
    arity_name: []const u8,
    index: usize,
) Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "{s}#{d}", .{ arity_name, index });
}

/// A runtime-lowered anon-object or local-class method body and its captures.
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

/// A top-level property's initializer thunk and pre-init default category.
pub const TopLevelPropInit = struct { func: FuncId, default: build.TypedDefault, file: u32 = 0 };

/// Program metadata built once by `build.build_module` and shared by handle
/// with every OS thread. Declaration tables are fixed; caches fill in lazily.
pub const ProgramImage = struct {
    top_level_prop_inits: std.StringHashMap(TopLevelPropInit),
    /// The same props in declaration order, borrowed from the Vm's slice.
    top_level_props_ordered: []const NameFunc = &.{},
    /// Enum-entry ctor-arg thunks, borrowed from the Vm, evaluated on first use.
    enum_entry_arg_inits: []const EnumEntryArgInit = &.{},
    /// Allocator sharing a base-cached enum entry's lifetime; null is the Vm's.
    patch_allocator: ?Allocator = null,
    body_prop_inits: PairFuncMap,
    instance_prop_getters: PairFuncMap,
    /// Every property name with a custom getter; gates the accessor probe.
    getter_prop_names: std.StringHashMap(void),
    instance_prop_setters: PairFuncMap,
    /// Getter-backed body properties declared `private`; never virtual.
    instance_prop_private: PairFuncMap,
    parent_ctor_args: std.StringHashMap([]FuncId),
    /// Labels parallel to `parent_ctor_args`, bound by name rather than position.
    parent_ctor_arg_names: std.StringHashMap([]const ?[]const u8),
    init_blocks: std.StringHashMap([]FuncId),
    extension_props: PairFuncMap,
    /// Property names with an owner-qualified extension-prop key
    /// (`"<Owner>\x00<recv>"`); gates the lexical-tower probe's frame walk.
    owner_keyed_ext_names: std.StringHashMap(void),
    /// Extension-property getters for a null receiver; null means ambiguous.
    nullable_ext_props: std.StringHashMap(?FuncId),
    extension_prop_setters: PairFuncMap,
    extension_prop_delegates: PairFuncMap,
    secondary_ctors: std.StringHashMap([]build.SecondaryCtorEntry),
    primary_ctor_default_thunks: std.StringHashMap([]?FuncId),
    /// Every top-level `object` and synthesised companion. Startup defers any
    /// whose initializer throws to `lookupGlobal`, as Kotlin's lazy init does.
    object_names: std.StringHashMap(void),
    class_delegates: std.StringHashMap([]StrFunc),
    func_defaults: std.AutoHashMap(u32, []?FuncId),
    installed_bindings: ObjRef(HostBindings),
    /// Executable form per top-level symbol, keyed by `FuncId.int()`: present
    /// is the native binding, absent runs the lowered body. Load-order free.
    resolved_native: std.AutoHashMap(u32, StdlibFn),
    /// Slot of the trailing `vararg` for `resolved_native` entries declaring
    /// one. Intrinsics take the spread convention, so a packed slot unpacks.
    vararg_spread_adapters: std.AutoHashMap(u32, u32),
    /// Body-bearing siblings of a bodyless decl, in declaration order.
    resolved_redirect: std.AutoHashMap(u32, []FuncId),
    /// Bare name → FQN over the stdlib packages an unqualified reference may
    /// bind into implicitly; the first package in `bare_probe_packages` order
    /// wins a collision. Keys and values borrow FQN bytes outliving this image.
    default_import_globals: std.StringHashMap([]const u8),
    /// Bare name → FQN for package-level pack bindings. Receiver-qualified
    /// bindings are member forms a bare name can never mean and are excluded;
    /// the smallest FQN wins a collision, so hash order cannot change the pick.
    pack_bare_aliases: std.StringHashMap([]const u8),
    /// Bare name → FQN over the `any_member_prefixes` surfaces, probed for an
    /// instance receiver with no user extension.
    any_member_globals: std.StringHashMap([]const u8),
    resolved_linked: bool,
    /// Builtin member-call resolution memo: `(receiver type, name, args-empty)`
    /// → the intrinsic, `null` meaning fall through to extension/global
    /// dispatch. Only non-`Instance`, non-array-builder receivers are cached.
    member_resolve_cache: std.AutoHashMap(MemberResolveKey, MemberResolveEntry),
    /// Winning intrinsic, or a confirmed "none", for `get_field`'s stdlib
    /// property probe ladder, keyed by (type-fqn identity, name identity).
    field_probe_cache: std.AutoHashMap(MemberHasKey, MemberResolveEntry),
    /// Program-lifetime canonical storage for the names the dispatch caches key
    /// on. A callable reference's name is a collectable runtime String whose
    /// address can be reused, so interning by content keeps pointer keys exact.
    member_names: std.StringHashMap(void),
    /// Module `canonicalizeProgramNames` last processed; the pass runs once.
    canonicalized_module_identity: usize = 0,
    /// Monomorphic inline cache for user-class instance-method dispatch. The
    /// `FuncId` for `(class identity, name pointer, arity)` is invariant when
    /// the name is unambiguous at that arity; both key pointers stay stable.
    instance_method_cache: std.AutoHashMap(InstanceMethodKey, u32),
    /// Linked target for a numeric virtual slot on a runtime-defined class.
    /// Anon-object and local-class bodies live in side modules while inherited
    /// bodies live in the main module; settling that once makes dispatch O(1).
    runtime_virtual_cache: std.AutoHashMap(RuntimeVirtualKey, RuntimeVirtualTarget),
    /// Inline cache for a member miss resolving to a top-level extension, keyed
    /// like `instance_method_cache`. Only owner-independent picks are stored:
    /// no competing member extension, no declared-receiver override, non-strict.
    ext_method_cache: std.AutoHashMap(InstanceMethodKey, u32),
    /// Inline cache for pack-binding / stdlib-intrinsic resolution on an
    /// `Instance` receiver. Invariant for a named class since the binding table
    /// is static; `null` is a cached "no intrinsic". The duped `fqn` is owned here.
    instance_intrinsic_cache: std.AutoHashMap(InstanceMethodKey, MemberResolveEntry),
    /// Per-class ancestor companion-singleton names, a BFS over the supertype
    /// graph and lexical enclosing classes. Names borrow registry strings, only
    /// the spine is owned; the per-name membership check stays dynamic.
    companion_chain_cache: std.AutoHashMap(usize, []const []const u8),
    /// Named-argument bindings, replayed as a positional dispatch on a hit.
    named_perm_cache: std.AutoHashMap(InstanceMethodKey, NamedPerm),
    /// Memoized `hostHasMember`, which decides member versus global for a bare
    /// call; a pure function of `(class identity, name pointer)`.
    host_has_member_cache: std.AutoHashMap(MemberHasKey, bool),
    /// `CallMemberOrGlobal` sites that resolved to a global, so a repeat skips
    /// the member passes that must miss. Keyed by the enclosing function plus
    /// the receiver class, name pointer, and arity; single-candidate sites only.
    cmg_global_cache: std.AutoHashMap(CmgGlobalKey, void),
    /// Overload-resolution memo for global calls, keyed by primitive-arg-type
    /// signature. That signature exists only when every argument is a primitive
    /// scalar, where the tag alone determines the pick.
    overload_cache: std.AutoHashMap(OverloadKey, u32),
    /// Field-read memo keyed by (class cell identity, interned name identity):
    /// a custom getter, or a stored slot whose index is re-verified by name
    /// because instances can define extra fields dynamically. Main-module
    /// classes only, whose cells outlive the program, so a key never aliases.
    field_read_cache: std.AutoHashMap(MemberHasKey, FieldReadHit),
    /// Field-write memo keyed like `field_read_cache`. Recorded only when every
    /// consulted fact is class-static: main module, no delegate, no forwarding.
    field_write_cache: std.AutoHashMap(MemberHasKey, FieldWriteHit),
    /// `(module, FuncId)` → simple name of the class owning the func, for an
    /// instance method's implicit-`this` receiver. The name borrows module IR.
    func_owner_class_cache: std.AutoHashMap(FuncOwnerKey, ?[]const u8),
    allocator: Allocator,

    /// `file`/`argc` are 0 for a file-agnostic resolution; an imported pack
    /// extension shadowing the stdlib surface keys by (file+1, argc) instead.
    pub const MemberResolveKey = struct { type_p: usize, name_p: usize, args_empty: bool, file: u32 = 0, argc: u32 = 0 };
    pub const MemberResolveEntry = struct { func: ?StdlibFn, fqn: []const u8 };
    pub const InstanceMethodKey = struct { class_p: usize, name_p: usize, n_args: u32, sig: u64 };
    pub const RuntimeVirtualKey = struct { class_p: usize, slot: u32 };
    pub const RuntimeVirtualTarget = union(enum) {
        main_func: u32,
        side_func: AnonMethodEntry,
    };
    pub const MemberHasKey = struct { class_p: usize, name_p: usize };
    /// Replayable named-argument binding: `src[k]` is the caller arg index
    /// feeding user param `k`, receiver excluded. `n == 0xFF` means the shape
    /// needs the full named binder (defaults, varargs, arity mismatch).
    pub const NamedPerm = struct { n: u8, src: [15]u8 };
    pub const CmgGlobalKey = struct { func_p: usize, class_p: usize, name_p: usize, sig: u64 };
    pub const OverloadKey = struct { module_p: usize, func_p: u32, sig: u64 };
    pub const FuncOwnerKey = struct { module_p: usize, func_p: u32 };
    pub const FieldReadHit = struct {
        /// Custom getter to run, `NONE` when the read is a stored slot.
        getter: u32,
        /// Stored-slot index, `NONE` when a getter serves the read.
        stored_idx: u32,
        /// `outer` links to hop first; zero is the receiver's own slot.
        outer_hops: u8 = 0,
        /// Class identity of the outer that owned the slot, verified at serve
        /// time: receivers of one inner class can have different outers.
        outer_cls: u64 = 0,
        pub const NONE: u32 = std.math.maxInt(u32);
    };

    pub const FieldWriteHit = struct {
        /// Custom setter to run, `NONE` when the write is a plain store.
        setter: u32,
        /// Store key, interned into `member_names` so it outlives the resolution.
        store_name: []const u8,
        pub const NONE: u32 = std.math.maxInt(u32);
    };

    /// Packages a bare global name may bind into implicitly, in preference
    /// order: top-level packages rank above the receiver-extension ones, so
    /// `min` resolves to `kotlin.math.min`. `KLIO_LINK_AUDIT` flags divergence.
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

    /// Builtin receiver surfaces probed for a member call on an instance with
    /// no user extension. `kotlin.io` is excluded: its intrinsics are
    /// receiver-less, so member-style service would print the receiver.
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

    /// Probe for an already-interned identity, so a caller holding only a
    /// shared borrow resolves without the lock the insert arm needs.
    pub fn memberNameIdentityExisting(self: *const ProgramImage, name: []const u8) ?usize {
        if (self.member_names.getKey(name)) |stored| return @intFromPtr(stored.ptr);
        return null;
    }

    /// Program-lifetime pointer identity; null means the caller must not cache.
    pub fn memberNameIdentity(self: *ProgramImage, name: []const u8) ?usize {
        const c = self.memberNameCanonical(name) orelse return null;
        return @intFromPtr(c.ptr);
    }

    /// The program-lifetime copy of `name`. A cache entry storing a name as a
    /// value must hold this: a callable reference's name is collectable.
    pub fn memberNameCanonical(self: *ProgramImage, name: []const u8) ?[]const u8 {
        if (self.member_names.getKey(name)) |stored| return stored;
        const owned = self.allocator.dupe(u8, name) catch return null;
        self.member_names.put(owned, {}) catch {
            self.allocator.free(owned);
            return null;
        };
        return owned;
    }

    /// Rewrite every identifier-sized string to its program-lifetime canonical
    /// copy, so hot-path compares exit on `mem.eql`'s pointer check. Longer
    /// strings are data and stay put; a non-canonical name is only slower.
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
        // Re-key with canonical parts so a probe's compare exits on pointers.
        self.rekeyPairMap(&self.body_prop_inits);
        self.rekeyPairMap(&self.instance_prop_getters);
        self.rekeyPairMap(&self.instance_prop_setters);
        self.rekeyPairMap(&self.instance_prop_private);
        self.rekeyPairMap(&module.member_name_index);
    }

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

    /// Resolve each symbol's single executable form once: a top-level `FuncId`
    /// whose FQN maps to a binding in `installed_bindings` records it, one with
    /// no match runs its lowered body. A pure function of `(FuncId → fqn,
    /// bindings)`, so it is load-order free and idempotent.
    pub fn linkResolvedForms(self: *ProgramImage, module: *const Module) Allocator.Error!void {
        // Unpublish first: the steady-state fast paths read these tables
        // unguarded behind this flag and must go back on the locked path.
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

        // The declaration manifest is authoritative for bodyless decls: join
        // each to its exact host symbol first. A body-bearing declaration keeps
        // its Kotlin body, which accepts user subtypes the native form may not.
        {
            var decl_it = module.decl_sigs.iterator();
            while (decl_it.next()) |entry| {
                const symbol = entry.value_ptr.host_symbol orelse continue;
                if (entry.value_ptr.has_body and !intrinsicOverridesBody(symbol)) continue;
                const intrinsic = bindings.resolve(symbol) orelse
                    stdlib.implementation(symbol) orelse continue;
                try self.resolved_native.put(entry.key_ptr.*, intrinsic);
                // Record the trailing vararg's slot so a packed frame unpacks.
                if (module.funcById(FuncId.from(entry.key_ptr.*))) |vf| {
                    if (vf.params.len != 0 and vf.params[vf.params.len - 1].is_vararg) {
                        try self.vararg_spread_adapters.put(entry.key_ptr.*, @intCast(vf.params.len - 1));
                    }
                }
            }
        }

        // One deterministic name → FQN edge per simple name. Cross-package ties
        // resolve by `bare_probe_packages` order; FQNs are unique per table.
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
            // Mark every func under an installed binding's fqn native, through
            // the simple-name index. One exception: a body-bearing generic
            // overload whose FQN group holds a same-arity concrete sibling keeps
            // its body, since the intrinsic implements the concrete family's
            // semantics (`minOf(Double, Double)` propagates NaN).
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
                // A member-form binding (`<pkg>.<Class>.<name>`) is not in the
                // simple-name index, so settle it here like a top-level form.
                // Concrete classes only: an interface or abstract method must
                // dispatch virtually, its intrinsic serving only host receivers.
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

        // Bodyless decls, in dispatch order. Base funcs come from the baked id
        // list so the lazy table is not swept; this run's own sit past it.
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

    /// Settle one bodyless func's form: same-simple-name body siblings in
    /// declaration order, plus the exact-fqn and bare-name native fallback.
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
            // An `actual` declares its `expect`'s package, so only a
            // same-package sibling can settle a bodyless decl; linking a
            // stranger would run its body for an unimplemented expect.
            if (!std.mem.eql(u8, cf.package, f.package)) continue;
            // Same package is not enough for a member: `kotlin.Double.equals`
            // and `kotlin.String.equals` share `kotlin` and reject each other's
            // receiver, so a receiver-formed header needs its own class's decl.
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

    /// Symbols whose host implementation serves even though the Kotlin
    /// declaration has a body. `Sequence.sumOf`'s overloads differ only in the
    /// selector's return type, which Kotlin picks by inference; the host form
    /// reads the kind from the first value it computes instead.
    fn intrinsicOverridesBody(symbol: []const u8) bool {
        const overrides = [_][]const u8{
            "kotlin.sequences.Sequence.sumOf",
        };
        for (overrides) |o| {
            if (std.mem.eql(u8, o, symbol)) return true;
        }
        return false;
    }

    /// Everything before an FQN's last component: a member's class, or a package.
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

    /// Whether every value parameter of `f` depends on one of the function's own
    /// type parameters, counting structural uses such as `Comparator<in T>`.
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

    /// A body-bearing, non-extension, generic-signature overload whose FQN group
    /// holds a same-arity non-generic sibling keeps its Kotlin body. Bodyless
    /// stubs, extensions, and all-generic families are marked as usual.
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

    /// The native form for a bodyless decl: the declared FQN against the overlay
    /// then the embedded registry, then the bare-name map's FQN against both.
    fn bodylessNativeForm(
        self: *const ProgramImage,
        bindings: *const HostBindings,
        fqn: []const u8,
        name: []const u8,
        receiver_formed: bool,
    ) ?StdlibFn {
        if (bindings.resolve(fqn)) |i| return i;
        if (stdlib.implementation(fqn)) |i| return i;
        // The bare-name map names top-level functions, so it cannot settle a
        // member header; a member's implementation is receiver-qualified.
        if (receiver_formed) return null;
        if (self.default_import_globals.get(name)) |mapped| {
            if (bindings.resolve(mapped)) |i| return i;
            if (stdlib.implementation(mapped)) |i| return i;
        }
        return null;
    }

    /// Record a package-level binding's bare-name alias. An uppercase parent
    /// segment is a member form a bare name cannot mean; smallest FQN wins.
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

    pub fn defaultImportGlobal(self: *const ProgramImage, name: []const u8) ?[]const u8 {
        return self.default_import_globals.get(name);
    }

    pub fn packBareAlias(self: *const ProgramImage, name: []const u8) ?[]const u8 {
        return self.pack_bare_aliases.get(name);
    }

    pub fn anyMemberGlobal(self: *const ProgramImage, name: []const u8) ?[]const u8 {
        return self.any_member_globals.get(name);
    }

    pub fn resolvedRedirects(self: *const ProgramImage, func: FuncId) []const FuncId {
        return self.resolved_redirect.get(func.int()) orelse &.{};
    }

    /// The body sibling a call with `argc` args dispatches to: the first settled
    /// redirect whose user arity matches exactly or whose last param is vararg.
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

    /// Whether a value definitely cannot bind a parameter headed `pn`; only
    /// builtin scalar kinds refute. This separates redirects, it does not rank.
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

    /// `resolvedRedirectTarget` using the call's values: among same-arity
    /// siblings it skips a candidate whose declared scalar parameter the
    /// arguments cannot bind, which declaration order alone gets wrong.
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

    /// The link-settled native form, or `null` when the body is the only form.
    pub fn resolvedNativeForm(self: *const ProgramImage, func: FuncId) ?StdlibFn {
        return self.resolved_native.get(func.int());
    }
};

/// Single exclusive spin lock, re-exported from `runtime.objcell` so the
/// interpreter, the intrinsics, and the shared handles share one definition.
pub const SpinMutex = runtime.SpinMutex;

/// The program's stdout sink, shared by every thread: a handle over an `ObjRef`
/// cell, so each write takes the cell's exclusive `borrowMut` and concurrent
/// `println`s serialize. Writes stream as they happen, so a hanging or killed
/// program still shows its output. With no destination attached the sink
/// records instead, and `attach` flushes that backlog before streaming.
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

    /// Stream from here on to `out`, flushing anything recorded first.
    pub fn attach(self: SharedOutput, out: Output) void {
        const g = self.obj.borrowMut();
        defer g.deinit();
        const st = g.get();
        st.rec.replayInto(out);
        st.dest = out;
    }

    /// Drain the recording into `out`; a no-op once a destination is attached.
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

pub const ClosureInfo = struct {
    body_func: FuncId,
    /// A function value loaded from a declaration (`::f`): equal to every other
    /// load but never identical, unlike Kotlin's non-capturing-lambda singleton.
    is_ref: bool = false,
    /// The module `body_func` indexes, null for the main program module. A
    /// sub-module closure must resolve against it: sub-module `FuncId`s start at
    /// 0. The module lives for the run, owned by the anon table or run arena.
    module: ?*const ir.Module = null,
    n_params: usize,
    receiver_shape_known: bool = false,
    /// The callable declares an extension receiver outside `n_params`.
    has_receiver: bool = false,
    /// Capture names, in the same order as the runtime captures vec.
    capture_names: [][]const u8,
    /// Live capture values, behind a shared handle so `StoreGlobal` propagates.
    captures: ObjRef(std.ArrayList(Value)),
    /// The enclosing-receiver chain at the creation site, innermost last. Kotlin
    /// receiver scope is lexical, so every invocation seeds the frame from this.
    chain: []const ir.eval.EnclosingEntry = &.{},

    /// Epoch in which a live value last marked this closure. Post-sweep
    /// reclamation frees an unmarked slot's `capture_names` and `chain`.
    mark_epoch: usize = 0,
    /// True once the metadata is freed and the id is back on the free list.
    reclaimed: bool = false,

    /// No-op tracer. The capture store and chain live only while a value
    /// references the closure id, so the permanent spine must not pin them.
    pub fn gcTrace(self: *const ClosureInfo, m: *runtime.gc.Marker) void {
        _ = self;
        _ = m;
    }
};

/// The process-wide closure side-table `markClosureHook` consults. Every Vm
/// shares one spine by handle clone, so one handle serves every collector.
var active_closures: ?SharedClosures = null;

fn markClosureThunk(id: u64, m: *runtime.gc.Marker) void {
    const sc = active_closures orelse return;
    // Mark the slot live for this epoch, then shade its capture store and
    // chain. Stop-the-world, so no push can realloc the spine underneath.
    if (sc.getPtr(id)) |info| {
        info.mark_epoch = m.epoch;
        for (info.chain) |e| e.v.gcMark(m);
        m.shade(&info.captures.cell.hdr);
    }
}

/// Free the owned metadata of every closure slot unreferenced in the finished
/// collection. Stop-the-world, after the sweep, so the spine is stable.
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
/// function) when the closure captures nothing, 0 otherwise. Kotlin makes a
/// non-capturing lambda a singleton, so `structuralEq` compares by this.
fn closureSingletonThunk(id: u64) u64 {
    const sc = active_closures orelse return 0;
    const info = sc.get(id) orelse return 0;
    // A capturing closure keeps per-instance identity; a reclaimed slot none.
    if (info.reclaimed or info.is_ref or info.capture_names.len != 0 or info.chain.len != 0) return 0;
    const mod_bits: u64 = if (info.module) |m| @intFromPtr(m) else 0;
    var h: u64 = 1469598103934665603;
    h = (h ^ mod_bits) *% 1099511628211;
    h = (h ^ info.body_func.int()) *% 1099511628211;
    return h | 1;
}

/// Install the closure-liveness hook; idempotent across Vms sharing a spine.
pub fn gcInstallClosureHook(closures: SharedClosures) void {
    active_closures = closures;
    runtime.gc.markClosureHook = markClosureThunk;
    runtime.gc.sweepClosureHook = sweepClosuresThunk;
    runtime.gc.closureSingletonHook = closureSingletonThunk;
    // A lazy `sequence {}` builder parks its continuation as an opaque
    // `*ir.eval.SuspendState`, which the GC needs these hooks to reach.
    runtime.gc.markSuspendHook = ir.eval.gcMarkSuspendStateOpaque;
    runtime.gc.freeSuspendHook = ir.eval.freeSuspendStateOpaque;
}

/// Clear program-owned closure hooks before the run's phase arena is released.
pub fn gcResetProgramHooks() void {
    active_closures = null;
    runtime.gc.markClosureHook = null;
    runtime.gc.sweepClosureHook = null;
    runtime.gc.closureSingletonHook = null;
}

/// Lambda/closure side-table shared across every OS thread of one program. A
/// slot id stays valid for as long as a live value references it.
pub const SharedClosures = struct {
    obj: ObjRef(std.ArrayList(ClosureInfo)),
    /// Slot ids reclaimed by `reclaimDead`; `push` reuses one before extending
    /// the spine. Sound because a slot is freed only after a full mark proved no
    /// live value references its id. Writer lock or stop-the-world only.
    free_ids: ObjRef(std.ArrayList(u64)),

    pub fn new(allocator: Allocator) Allocator.Error!SharedClosures {
        const obj = try ObjRef(std.ArrayList(ClosureInfo)).init(allocator, .empty);
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

    /// In-place slot pointer, for the stop-the-world GC mark and sweep only:
    /// `push` cannot run during a collection, so the pointer stays stable.
    pub fn getPtr(self: SharedClosures, id: usize) ?*ClosureInfo {
        // A shared borrow: the mark phase must not run the mutable borrow's
        // write barrier, which locks the remembered set the collector holds.
        const g = self.obj.borrow();
        defer g.deinit();
        const list = g.get();
        if (id >= list.items.len) return null;
        return @constCast(&list.items[id]);
    }

    /// Free the owned metadata of every slot not marked in `epoch` and free its
    /// id. The capture-store cell is swept separately. Stop-the-world only.
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

    /// Bind `info` to a slot and return its id, reusing a reclaimed slot first.
    /// A reused slot's fields are overwritten here before any read.
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

/// One spawned OS thread; an error result carries a thrown Kotlin Throwable.
pub const ThreadEntry = struct {
    handle: ?std.Thread,
    result: ?ThreadResult = null,
    finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

pub const ThreadResult = union(enum) {
    ok: void,
    err: RuntimeError,
};

pub const ThreadTable = ObjRef(std.AutoHashMap(u64, ThreadEntry));

/// First-access init state for one `object` or companion singleton, keyed by
/// its lifted global name. Only in-flight and failed states are carried here.
pub const ObjectInitState = union(enum) {
    /// Construction is running on `thread`; `instance` is set once the shell
    /// exists, so re-entrant access sees the partial singleton, as Kotlin does.
    InProgress: struct { thread: std.Thread.Id, instance: ?Value },
    /// The first construction threw and is never retried. `cause` holds the
    /// throwable until the first throwing read; later accesses carry no cause.
    Failed: struct { cause: ?Value },

    pub fn gcTrace(self: *const ObjectInitState, m: *runtime.gc.Marker) void {
        switch (self.*) {
            .InProgress => |ip| if (ip.instance) |v| v.gcMark(m),
            .Failed => |f| if (f.cause) |v| v.gcMark(m),
        }
    }
};

/// Lazy-`object` init table. The cell's writer lock serializes the claim that
/// makes first-access construction once-only across threads.
pub const ObjectStates = ObjRef(std.StringHashMap(ObjectInitState));
/// `ClassId.int()` → published singleton, authoritative for id-committed reads;
/// name reads go through `globals`. Published to the id table first.
pub const SingletonsById = ObjRef(std.AutoHashMap(u32, runtime.Value));

/// Vm-level errors, carried as data.
pub const VmError = union(enum) {
    InvalidMain,
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
    /// Advance a logical clock instantly, deterministic and fast.
    Virtual,

    pub const default: TimeMode = .Wall;
};

threadlocal var coroutine_time_mode_tls: TimeMode = .Wall;

pub fn setCoroutineTimeMode(mode: TimeMode) void {
    coroutine_time_mode_tls = mode;
}

pub fn coroutineTimeMode() TimeMode {
    return coroutine_time_mode_tls;
}

/// One Vm instance executes one program against a front-end IR module.
pub const Vm = struct {
    module: ObjRef(Module),
    globals: ObjRef(Env),
    instance_id_counter: ObjRef(std.atomic.Value(u64)),
    classes: ObjRef(ClassTable),
    /// Top-level property initialiser `FuncIds`, run at `run` start.
    top_level_props: std.ArrayList(NameFunc),
    enum_entry_arg_inits: std.ArrayList(EnumEntryArgInit),
    /// Default outer instance to attach to locally-registered classes.
    class_default_outer: ObjRef(OuterTable),
    anon_methods: AnonMethods,
    closures: SharedClosures,
    prog: ObjRef(ProgramImage),
    out_sink: SharedOutput,
    threads: ThreadTable,
    object_states: ObjectStates,
    singletons_by_id: SingletonsById,
    allocator: Allocator,
    /// Where the enum-entry ctor-arg patch allocates, defaulting to `allocator`.
    /// The parity drivers point it at the base cache arena, which outlives the
    /// program whose instances the patch writes into.
    patch_allocator: ?Allocator = null,
    /// Process argv for `main(args)`; empty under `klio run`, set by a bundle.
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
    // Embedder entry points: prepare startup, then invoke functions or methods.
    pub const prepare = run_mod.vmPrepare;
    pub const runCalls = run_mod.vmRunCalls;
    pub const callNoArg = run_mod.vmCallNoArg;
    pub const construct = run_mod.vmConstruct;
    pub const callMethod = run_mod.vmCallMethod;
};

pub const CallOutcome = run_mod.CallOutcome;

/// `Send` capture of the shared program state for a new OS thread. Every field
/// is an owned shared handle, so the seed outlives the spawning call.
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

/// Whether `name` names a property, not a function, on `receiver`'s class chain.
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

/// Whether a body's declared primitive parameter type can accept `v`. Only a
/// definite primitive-versus-different-primitive pairing rejects.
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

/// Permissive receiver/param-type compatibility for extension overload pickers:
/// false only when the value provably fails the parameter's nominal type.
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

/// True when an extension's declared receiver names a user or pack class, not a
/// builtin, an open supertype a builtin satisfies, or a bare type parameter.
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

/// True when `fqn` names a builtin `kotlin.*` Throwable class that klio
/// constructs as a host `Value.Exception` rather than a generic Instance.
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

pub fn valueIsBuiltin(v: *const Value) bool {
    return switch (v.*) {
        .String, .StringBuilder, .Int, .Long, .Short, .Byte, .Double, .Float, .Char, .Bool, .Array, .List, .Map, .Result => true,
        else => false,
    };
}

pub fn isFunctionType(ty: *const TypeRef) bool {
    const n = simpleName(ty.name);
    return std.mem.startsWith(u8, n, "Function") or
        std.mem.indexOf(u8, ty.name, "->") != null;
}

pub fn valueIsCallable(v: *const Value) bool {
    return switch (v.*) {
        .IrClosure, .Intrinsic, .BoundMethod, .PropertyRef => true,
        else => false,
    };
}

/// True when `v` is a `CancellationException`, timeout variant included.
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

/// Arm the eval-loop wall-clock deadline so an in-process program that spins
/// aborts instead of hanging the test binary. Harnesses only; the CLI is never
/// capped, and a deadlock outside the eval loop is not covered. `<= 0` disarms.
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
    try m.rebuildFuncNameIndex(a);

    var prog = try ProgramImage.init(a);
    defer prog.deinit();

    try prog.linkResolvedForms(&m);
    try testing.expect(prog.resolved_linked);
    try testing.expect(prog.resolvedNativeForm(shimmed) == null);
    try testing.expect(prog.resolvedNativeForm(plain) == null);

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
    // Member funcs are not in the simple-name index, so the member leg must
    // resolve the binding key's class prefix and mark the method native.
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
    // An `actual` declares its `expect`'s package; linking a same-named function
    // from another package would silently run a stranger's body.
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
    const expect_fn = try pushLinkTestFuncOpts(&m, a, "ping", "app.ping", true);
    const actual_fn = try pushLinkTestFunc(&m, a, "ping", "app.ping.impl");
    const abs_decl = try pushLinkTestFuncOpts(&m, a, "abs", "kotlin.math.abs", true);
    // Bodyless decl whose FQN is unknown but whose simple name maps implicitly.
    const sqrt_decl = try pushLinkTestFuncOpts(&m, a, "sqrt", "mylib.sqrt", true);
    // Body-bearing func: the embedded registry must not shadow its body.
    const body_abs = try pushLinkTestFunc(&m, a, "abs", "kotlin.math.abs");
    try m.rebuildFuncNameIndex(a);

    var prog = try ProgramImage.init(a);
    defer prog.deinit();
    try prog.linkResolvedForms(&m);

    const redirects = prog.resolvedRedirects(expect_fn);
    try testing.expect(redirects.len >= 1);
    try testing.expectEqual(actual_fn.int(), redirects[0].int());
    try testing.expect(prog.resolvedNativeForm(actual_fn) == null);
    try testing.expectEqual(actual_fn.int(), prog.resolvedRedirectTarget(&m, expect_fn, 0).?.int());
    try testing.expect(prog.resolvedRedirectTarget(&m, expect_fn, 1) == null);

    try testing.expect(prog.resolvedNativeForm(abs_decl) != null);
    try testing.expect(prog.resolvedNativeForm(body_abs) == null);

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

    try testing.expectEqual(two.int(), prog.resolvedRedirectTarget(&m, stub, 2).?.int());
    try testing.expectEqual(vararg.int(), prog.resolvedRedirectTarget(&m, stub, 3).?.int());
    try testing.expectEqual(vararg.int(), prog.resolvedRedirectTarget(&m, stub, 0).?.int());
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
        try bg.get().register("kotlinx.coroutines.runBlocking", linkTestNativeFn);
        try bg.get().register("kotlinx.coroutines.Job.join", linkTestNativeFn);
        try bg.get().register("kotlinx.serialization.encode", linkTestNativeFn);
        try bg.get().register("kotlinx.io.encode", linkTestNativeFn);
    }
    try prog.linkResolvedForms(&m);

    try testing.expectEqualStrings("kotlinx.coroutines.runBlocking", prog.packBareAlias("runBlocking").?);
    try testing.expect(prog.packBareAlias("join") == null);
    try testing.expectEqualStrings("kotlinx.io.encode", prog.packBareAlias("encode").?);

    try testing.expectEqualStrings("kotlin.math.min", prog.defaultImportGlobal("min").?);
    try testing.expectEqualStrings("kotlin.intArrayOf", prog.defaultImportGlobal("intArrayOf").?);

    // `kotlin.io`'s receiver-less globals must not become member edges: serving
    // `println` member-style would print the receiver. No `use` edge exists.
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
        try bg.get().register("kotlin.io.zzzCollide", linkTestNativeFn);
        try bg.get().register("kotlin.math.zzzCollide", linkTestNativeFn);
        try bg.get().register("kotlin.Any.zzzUse", linkTestNativeFn);
        try bg.get().register("kotlin.AutoCloseable.zzzUse", linkTestNativeFn);
    }
    try prog.linkResolvedForms(&m);
    try testing.expectEqualStrings("kotlin.math.zzzCollide", prog.defaultImportGlobal("zzzCollide").?);
    try testing.expectEqualStrings("kotlin.AutoCloseable.zzzUse", prog.anyMemberGlobal("zzzUse").?);
    // The one real cross-package collision: StringBuilder is registered under
    // both `kotlin` and `kotlin.text`, and `kotlin` ranks first.
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
