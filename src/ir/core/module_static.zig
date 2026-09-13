const std = @import("std");
const ast = @import("ast");
const runtime = @import("runtime");
const applicability = @import("applicability");
const Allocator = std.mem.Allocator;
const root_ir = @import("../ir.zig");
const core_class = @import("class.zig");
const core_func = @import("func.zig");
const core_ids = @import("ids.zig");
const core_names = @import("names.zig");
const core_registry = @import("registry.zig");

const Class = core_class.Class;
const ClassId = core_ids.ClassId;
const DeclSig = Module.DeclSig;
const ExtensionResolveCtx = Module.ExtensionResolveCtx;
const FileId = root_ir.FileId;
const Func = core_func.Func;
const FuncId = core_ids.FuncId;
const Module = root_ir.Module;
const ModuleRegistry = core_registry.ModuleRegistry;
const Param = core_func.Param;
const TypeBinding = Module.TypeBinding;
const TypeRef = core_ids.TypeRef;
const bindingType = Module.bindingType;
const classTypeParamIdentity = core_ids.classTypeParamIdentity;
const default_import_packages = Module.default_import_packages;
const eval = root_ir.eval;
const evidenceSubtypeCb = Module.evidenceSubtypeCb;
const idGet = core_names.idGet;
const overrideArgs = Module.overrideArgs;
const overrideQualifiedPath = Module.overrideQualifiedPath;
const parseClassTypeParamIdentity = core_ids.parseClassTypeParamIdentity;
const substituteType = Module.substituteType;
const typeContainsBoundParam = Module.typeContainsBoundParam;

pub const MemberCandidate = struct {
    fid: FuncId,
    depth: u16,
};

pub fn classIdIsOrExtendsDepth(
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

pub fn classHierarchyDeclaresMemberDepth(self: *const Module, cls: ClassId, name: []const u8, depth: u8) bool {
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

pub fn enclosingClassId(self: *const Module, child: ClassId) ?ClassId {
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

pub fn lexicalChainContains(self: *const Module, start: ClassId, target: ClassId) bool {
    var current: ?ClassId = start;
    var depth: u8 = 0;
    while (current) |id| : (depth += 1) {
        if (id == target) return true;
        if (depth >= 64) return false;
        current = self.enclosingClassId(id);
    }
    return false;
}

pub fn protectedAccessOwner(
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

pub fn collectMemberCandidates(
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

pub fn staticTypeHead(name: []const u8) []const u8 {
    var head = applicability.simpleName(name);
    if (std.mem.indexOfScalar(u8, head, '<')) |lt| head = head[0..lt];
    return std.mem.trimEnd(u8, head, "?");
}

pub fn staticTypeVar(raw: *anyopaque, fid: FuncId, ty: *const TypeRef) bool {
    const self: *const Module = @ptrCast(@alignCast(raw));
    for (ty.args) |arg| {
        if (std.mem.startsWith(u8, arg.name, "#qual:")) return false;
    }
    return self.funcTypeParamIndex(fid, staticTypeHead(ty.name)) != null;
}

pub fn staticTypeArgsEqual(actual: []const TypeRef, declared: []const TypeRef) bool {
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

pub fn staticDeclTypeParam(self: *const Module, fid: FuncId, ty: TypeRef) bool {
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

pub fn staticTypeContainsFuncParam(
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
pub fn staticGenericArgCompatibility(
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
pub fn erasedHeadRefutes(
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

pub fn erasedHeadProves(
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

pub fn recvRefuteOn() bool {
    const S = struct {
        var cached: ?bool = null;
    };
    if (S.cached) |v| return v;
    const on = runtime.envSetOnce("KLIO_RECV_REFUTE");
    S.cached = on;
    return on;
}

pub fn arrayVsCollectionParam(actual_head: []const u8, param_head: []const u8) bool {
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

pub const StaticAliasHead = struct {
    name: []const u8,
    changed: bool,
    structure_lost: bool,
};

pub fn staticAliasHead(self: *const Module, ty: TypeRef) StaticAliasHead {
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

pub fn staticBuiltinConcrete(head: []const u8) bool {
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

pub const StaticBuiltinIdentity = enum {
    no,
    ambiguous,
    yes,
};

pub fn staticBuiltinIdentity(
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

pub fn staticTypeClassId(self: *const Module, ty: TypeRef) ?ClassId {
    if (overrideQualifiedPath(ty)) |path| {
        return self.classIdByFqn(path) orelse self.classIdByQualifiedSuffix(path);
    }
    if (std.mem.indexOfScalar(u8, ty.name, '.') != null) {
        return self.classIdByFqn(ty.name) orelse self.classIdByQualifiedSuffix(ty.name);
    }
    return self.uniqueClassIdBySimpleName(staticTypeHead(ty.name));
}

pub fn staticTypesShareClassifier(
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

pub fn staticBoundProofComplete(
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
pub fn staticBoundProofHead(
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
pub fn staticTypeDisproofComplete(
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

pub fn staticReceiverCompatibility(
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

pub fn staticAliasType(
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

pub fn scopedTypeAliasFqn(
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

pub fn projectionType(ty: TypeRef) struct { variance: ?ast.Variance, ty: TypeRef, star: bool } {
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

pub fn staticTypeIsSubtypeInner(
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
pub fn staticBuiltinArgsNonRefuting(actual_args: []const TypeRef, declared_args: []const TypeRef) bool {
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

pub fn isDeclaredTypeParam(
    params: []const ModuleRegistry.TypeParamBound,
    name: []const u8,
) bool {
    for (params) |param| {
        if (std.mem.eql(u8, param.param, name)) return true;
    }
    return false;
}

pub fn rawBoundNamesDeclaredParam(
    params: []const ModuleRegistry.TypeParamBound,
    bound: []const u8,
) bool {
    if (std.mem.indexOfScalar(u8, bound, '.') != null or
        std.mem.startsWith(u8, bound, "#qual:")) return false;
    return isDeclaredTypeParam(params, staticTypeHead(bound));
}

pub fn typeRefIsDeclaredParam(
    params: []const ModuleRegistry.TypeParamBound,
    ty: TypeRef,
) bool {
    if (overrideQualifiedPath(ty) != null or
        std.mem.indexOfScalar(u8, ty.name, '.') != null) return false;
    return isDeclaredTypeParam(params, staticTypeHead(ty.name));
}

pub fn staticTypeProofComplete(
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

pub fn bindReceiverTypeParams(
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

pub fn staticGenericReceiverApplicableMode(
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
pub threadlocal var sac_route: []const u8 = "-";

pub fn staticArgCompatibility(
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
                // An explicit `as Any` argument fits only an `Any`
                // parameter or a type parameter.
                if (arg.cast_any) {
                    const rh = staticTypeHead(std.mem.trimEnd(u8, required.?.name, "?"));
                    const type_param = rh.len > 0 and rh.len <= 2 and std.ascii.isUpper(rh[0]);
                    if (!std.mem.eql(u8, rh, "Any") and !type_param) return .incompatible;
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

pub fn lambdaRefuteOn() bool {
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
pub fn headIsFunctionSpelling(name: []const u8) bool {
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
pub fn bargTraceEnv() ?[]const u8 {
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

pub fn dropTraceEnv() ?[]const u8 {
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

pub fn trailingGapDefaulted(params: []const Param, n_args: usize) bool {
    if (n_args == 0 or n_args > params.len) return true;
    var i = n_args - 1;
    while (i + 1 < params.len) : (i += 1) {
        if (!params[i].has_default) return false;
    }
    return true;
}

/// Builtin classifier heads no function value can convert to: the
/// definite-refutation set for a callable argument.
pub fn nonCallableBuiltinHead(head: []const u8) bool {
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

pub fn staticMemberArgsCompatibility(
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

pub fn extensionKeyGreater(a: [9]i32, b: [9]i32) bool {
    inline for (0..8) |i| {
        if (a[i] != b[i]) return a[i] > b[i];
    }
    return false;
}

pub fn extensionKeyEquivalent(a: [9]i32, b: [9]i32) bool {
    return std.mem.eql(i32, a[0..8], b[0..8]);
}

/// True when two function-typed parameter refs agree on everything a
/// closure body can observe: same arity head and same argument types in
/// every position but the LAST (the function's return).
pub fn functionParamArgsAgree(a: TypeRef, b: TypeRef) bool {
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
pub fn tiedLambdaParamRep(self: *const Module, fids: []const FuncId) ?FuncId {
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

pub fn staticReceiverCouldAccept(self: *const Module, fid: FuncId, receiver: TypeRef, param: TypeRef) bool {
    return self.staticReceiverCompatibility(fid, receiver, param) != .incompatible;
}

pub fn memberExtensionOwnerIsObject(self: *const Module, fid: FuncId) ?[]const u8 {
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

pub fn scopedClassId(
    self: *const Module,
    name: []const u8,
    ctx: ExtensionResolveCtx,
) ?ClassId {
    return if (std.mem.indexOfScalar(u8, name, '.') != null)
        self.classIdByFqn(name)
    else
        self.classIdIndexed(name, ctx.caller_package, ctx.caller_file);
}

pub fn dispatchOwnerInChain(
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

pub fn lexicalOwnerChainContains(
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

pub fn lexicalOwnerCompanionMatches(
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

pub fn memberDispatchOwnerInScope(self: *const Module, owner: []const u8, ctx: ExtensionResolveCtx) bool {
    for (ctx.implicit_dispatch_owners) |implicit| {
        if (self.dispatchOwnerInChain(implicit, owner, ctx)) return true;
    }
    if (ctx.lexical_owner) |lexical| {
        if (self.dispatchOwnerInChain(lexical, owner, ctx) or
            self.lexicalOwnerCompanionMatches(lexical, owner, ctx)) return true;
    }
    return false;
}

pub fn memberExtensionScopeTier(
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

pub fn objectMemberExtensionInScope(
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

pub fn memberExtensionInScope(
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

pub fn genericReceiverSuppliesLambdaReceiver(
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
