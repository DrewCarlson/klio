const std = @import("std");
const applicability = @import("applicability");
const Allocator = std.mem.Allocator;
const root_ir = @import("../ir.zig");
const core_func = @import("func.zig");
const core_ids = @import("ids.zig");
const core_names = @import("names.zig");
const core_registry = @import("registry.zig");

const ClassId = core_ids.ClassId;
const DeclArity = Module.DeclArity;
const FileId = root_ir.FileId;
const Func = core_func.Func;
const FuncId = core_ids.FuncId;
const Module = root_ir.Module;
const ModuleRegistry = core_registry.ModuleRegistry;
const TypeRef = core_ids.TypeRef;
const isShippedPackage = core_names.isShippedPackage;
const rankLowPriority = core_func.rankLowPriority;

pub const BareCallCandidateIterator = struct {
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

    /// A `private` declaration is visible only inside its declaring file, its whole lexical
    /// family included, so a cross-file private candidate never resolves.
    fn visibleFrom(it: *const BareCallCandidateIterator, id: FuncId) bool {
        const decl_file = it.module.registry.private_fn_files.get(id) orelse return true;
        return decl_file.int() == it.caller_file.int();
    }

    pub fn next(it: *BareCallCandidateIterator) ?FuncId {
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

pub fn bareCallCandidateIterator(
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

pub fn renamedImportDenotesFunc(
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

/// Every declaration a bare source name denotes in this file: ordinary declarations enter by
/// simple name, renamed imports by exact FQN, and each declaration identity appears once.
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

/// Whether any bare-call candidate for `name` is a PLAIN function rather than an extension: an
/// extension namesake must not talk a caller out of the enclosing class's own member.
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

/// Whether file `file` declares `import <pkg>.*`; a wildcard import is file-scoped like a named one.
pub fn importWildcardIn(self: *const Module, file: FileId, pkg: []const u8) bool {
    if (pkg.len == 0) return false;
    if (self.registry.import_wildcards.get(file)) |list| {
        for (list.items) |path| {
            if (std.mem.eql(u8, path, pkg)) return true;
        }
    }
    return false;
}

/// Packages whose top-level entities are implicitly visible in every Kotlin source file. Mirrors
/// `stdlib.IMPLICITLY_IMPORTED_PACKAGES`, which `ir` cannot depend on; a test keeps the two in step.
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

pub fn isDefaultImportPackage(pkg: []const u8) bool {
    for (default_import_packages) |p| {
        if (std.mem.eql(u8, p, pkg)) return true;
    }
    return false;
}

/// Lowest tier whose candidates the caller can see under Kotlin scoping. An identical-signature tie
/// at or above it is a real ambiguity; below it Kotlin resolves nothing and klio's pick is lenient.
pub const last_in_scope_tier: u8 = 3;

/// Tier of a candidate in a package the caller neither declares, imports, nor sees by default:
/// Kotlin does not resolve such a reference at all.
pub const other_package_tier: u8 = 5;

/// Bare-call preference tier of a candidate: 0 = file named import, 1 = own package, 2 = file
/// wildcard import, 3 = default import, 4 = built-in stdlib, 5 = any other package, which is
/// Kotlin's resolution order for an unqualified top-level callable. `caller_pkg` is the caller's
/// declaring package, `""` for a user script.
pub fn bareCallTier(self: *const Module, f: *const Func, name: []const u8, caller_pkg: []const u8, caller_file: FileId) u8 {
    return self.scopeTier(f.fqn, f.package, name, caller_pkg, caller_file);
}

/// The class or object this file EXACT-imports under `name`, tier-0 resolution only: kotlinc gives
/// an explicit import precedence over a same-named cross-package top-level property.
pub fn classIdExactImport(self: *const Module, name: []const u8, caller_file: FileId) ?ClassId {
    // Resolve the imported FQN directly: a collision-mangled class is registered only under its
    // mangled name, so a simple-name scan misses it while its FQN still resolves.
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

/// User parameters `f` declares, excluding a leading synthesized extension/member `this`.
pub fn funcUserArity(f: *const Func) usize {
    if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) {
        return f.params.len - 1;
    }
    return f.params.len;
}

/// True for a func with a leading synthesized `this`: an instance method, a top-level extension, or
/// a member extension. A true bare call only ever binds a non-extension top-level function.
pub fn funcHasImplicitThis(f: *const Func) bool {
    return f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this");
}

/// `funcHasImplicitThis` for a candidate whose header stub carries no parameters yet (a pack's
/// deferred inline extension): the declaration signature's receiver answers instead.
pub fn candidateHasImplicitThis(self: *const Module, id: FuncId, f: *const Func) bool {
    if (funcHasImplicitThis(f)) return true;
    // A header stub may list only value parameters; its declared receiver still makes it an extension.
    const ds = self.decl_sigs.get(id.int()) orelse return false;
    return ds.receiver_ty != null;
}

/// Applicability `SigView` at LOWERING time: strips a leading synthesized `this` so the shared scorer
/// ranks value args against user params. Defaults ride the params, since `func_defaults` is image-side.
pub fn sigViewForApplicability(
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

/// Why the symbol index declined to resolve a bare call. Every deferral carries one, so an audit can
/// prove the heuristic fallback only handles classified shapes.
pub const ResolveDeferReason = enum {
    /// No top-level function with this simple name exists.
    no_candidates,
    /// Every candidate takes an implicit receiver `this`; receiver-based resolution is the heuristic's.
    extension_form,
    /// The lowerer routes this name to an intrinsic, so the index must not bind the body it skips.
    intrinsic_owned,
    /// Several exact matches in a winning tier the caller can SEE, all with the same full parameter
    /// signature, generic arguments and function-type shapes included: Kotlin rejects such a set.
    ambiguous_tier,
    /// Several exact matches in the winning tier differing in parameter types: the runtime dispatches.
    type_overload,
    /// Several identical matches, all in packages the caller neither declares, imports, nor sees by
    /// default: Kotlin resolves nothing, so the lenient cross-package pick stays with the heuristic.
    unimported_set,
    /// The winning tier has candidates, but none matches the call's arity exactly.
    arity_mismatch,
    /// Defaults exist, but the positional call cannot bind them, or a header lacks the per-param flags.
    default_param_shape,
    /// Only header stubs or bodyless decls with no declared-arity record were available.
    bodyless_only,
    /// The only exact matches are low-priority overloads.
    low_priority_only,
    /// The only near matches take a trailing vararg.
    vararg_only,
    /// The call's trailing lambda spans a default-parameter gap, a shape the index does not model.
    trailing_lambda_shape,
    /// Same-tier same-arity overload set disambiguated by an `as` cast. Assigned by the lowerer, which
    /// sees the cast; the index never produces it.
    cast_disambiguated,
};

/// Result of `resolveBareCallIndexed`: a unique `FuncId` or a reason-tagged deferral, plus the
/// winning tier and its best-match count for the resolve audit.
pub const BareCallResolution = struct {
    pub const Outcome = union(enum) {
        resolved: FuncId,
        deferred: ResolveDeferReason,
    };
    outcome: Outcome,
    /// Winning preference tier (0..5); 255 when no candidate established one.
    tier: u8 = 255,
    /// Best-ranked positional matches counted within the winning tier.
    tier_count: usize = 0,
    /// First two best-ranked matches in the winning tier; both set when the outcome is `ambiguous_tier`.
    first: ?FuncId = null,
    second: ?FuncId = null,

    /// The resolved id, or null on any deferral.
    pub fn pick(self: BareCallResolution) ?FuncId {
        return switch (self.outcome) {
            .resolved => |id| id,
            .deferred => null,
        };
    }

    /// Deferred because every match is `@LowPriorityInOverloadResolution` or a deprecated stub. Binding
    /// one statically over a same-name class constructor self-recurses, so the caller emits a dynamic call.
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

/// Whether a phase-1 header stub's DECLARED user arity matches the call exactly: no defaults
/// (`required == total`), no vararg at any position, exactly `want` parameters. Stubs carry no params.
pub fn stubDeclArity(self: *const Module, id: FuncId) ?DeclArity {
    return self.decl_user_arity.get(id.int());
}

/// Preference tier of one specific candidate at a call site. The resolve audit grades a heuristic
/// pick against the index's: an index pick that ranks strictly better is a correction, not a mis-bind.
pub fn bareCallTierOf(self: *const Module, id: FuncId, name: []const u8, caller_pkg: []const u8, caller_file: FileId) ?u8 {
    const f = self.funcById(id) orelse return null;
    return self.bareCallTier(f, name, caller_pkg, caller_file);
}

/// A candidate's user-parameter type signature: lowered params for a body-bearing func, the phase-1
/// declared record for a header stub; null when unknowable, which forfeits any identity proof.
pub const SigView = union(enum) {
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

pub fn sigViewOf(self: *const Module, id: FuncId, f: *const Func) ?SigView {
    if (f.hasBody()) return .{ .body = f };
    if (self.decl_user_sig.get(id.int())) |sig| return .{ .decl = sig };
    return null;
}

/// Whether two candidates declare the same user parameter signature (synthesized `this` excluded)
/// over head name, nullability, and recursive argument shapes. Only such a set is a true duplicate.
pub fn sameUserSig(a: SigView, b: SigView) bool {
    if (a.len() != b.len()) return false;
    var i: usize = 0;
    while (i < a.len()) : (i += 1) {
        if (!a.at(i).eql(b.at(i))) return false;
    }
    return true;
}

/// Whether any parameter is declared `vararg`, the body-side mirror of `DeclArity.has_vararg`.
pub fn anyParamVararg(f: *const Func) bool {
    for (f.params) |p| {
        if (p.is_vararg) return true;
    }
    return false;
}

/// Positional arguments omittable from the end of `f`. Kotlin allows the omission only when every
/// omitted parameter has a default, so a required parameter after a default stays required.
pub fn positionalDefaultsUsed(f: *const Func, want: usize) ?usize {
    const off: usize = if (funcHasImplicitThis(f)) 1 else 0;
    const params = f.params[off..];
    if (want > params.len) return null;
    for (params[want..]) |p| {
        if (!p.has_default) return null;
    }
    return params.len - want;
}

pub fn omittedPositionHasDefault(f: *const Func, want: usize) bool {
    const off: usize = if (funcHasImplicitThis(f)) 1 else 0;
    const params = f.params[off..];
    if (want >= params.len) return false;
    for (params[want..]) |p| {
        if (p.has_default) return true;
    }
    return false;
}

/// Whether a declared parameter type names a `fun interface`.
pub fn typeNamesFunInterface(self: *const Module, ty_name: []const u8) bool {
    const nm = std.mem.trimEnd(u8, ty_name, "?");
    const cid = self.classIdByFqn(nm) orelse self.classId(nm) orelse return false;
    if (cid.int() >= self.classes.items.len) return false;
    return self.classes.items[cid.int()].is_fun_interface;
}

pub fn tlShapeMatches(self: *const Module, f: *const Func, want: usize) bool {
    const up = funcUserArity(f);
    // A trailing lambda also fills a `fun interface` parameter by SAM conversion.
    const last_is_fn = f.params.len != 0 and
        (std.mem.startsWith(u8, f.params[f.params.len - 1].ty.name, "Function") or
            self.typeNamesFunInterface(f.params[f.params.len - 1].ty.name));
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

/// Resolve `name` (`want_arity` user args, `last_arg_lambda` for a trailing lambda) from imports and
/// package alone: the highest non-empty tier must hold one matching non-extension func, else defer.
pub fn resolveBareCallIndexed(
    self: *const Module,
    name: []const u8,
    caller_pkg_in: []const u8,
    caller_file: FileId,
    want_arity: usize,
    last_arg_lambda: bool,
) BareCallResolution {
    // Scope follows the call span's FILE: a spliced inline body carries the donor file's spans, so its
    // bare calls resolve in the donor's package.
    const caller_pkg = self.packageOfFile(caller_file) orelse caller_pkg_in;
    var candidate_it = self.bareCallCandidateIterator(name, caller_file);
    if (candidate_it.next() == null)
        return BareCallResolution.deferred(.no_candidates);

    // Highest-priority tier among non-extension candidates: bodies, plus stubs with a declared arity.
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
    // Every rankable non-extension candidate is in a package the caller cannot see while an in-scope
    // extension or member exists: Kotlin resolves against the receiver before ever reaching it.
    if (best_tier == other_package_tier and ext_in_scope) {
        return BareCallResolution.deferred(.extension_form);
    }

    // Within the best tier, find a unique positional, non-low-priority, non-extension candidate: exact
    // arity outranks consuming defaults, and fewer defaults outrank more. Track the closest miss.
    var chosen: ?FuncId = null;
    var second: ?FuncId = null;
    var count: usize = 0;
    var best_defaults_used: usize = std.math.maxInt(usize);
    // Whether every best-ranked match shares the first's signature: true ambiguity, or overload set.
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
        // Stub and body gates accept the same shapes, so resolution never depends on whether the body has
        // replaced its header.
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
            // A stub may carry only the aggregate arity; full arity needs no per-parameter default evidence.
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
                if (last_arg_lambda and self.tlShapeMatches(f, want_arity)) {
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
            // A candidate with neither lowered params nor a declared record forfeits the identity proof.
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
        // A unique match in a package the caller cannot see is no resolution, so defer as an unimported
        // set. A candidate with no recorded package is a lift artifact and keeps the lenient pick.
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

