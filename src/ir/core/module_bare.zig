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

    /// A `private` declaration is visible only inside its declaring file
    /// (a private member extension's whole lexical family lives there
    /// too), so a cross-file private candidate is never resolvable —
    /// admitting one let a test class's private
    /// `CoroutineScope.block(context)` shadow-defer every bare `block`
    /// in the program.
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

/// Every declaration denoted by a bare source name in this file. This is
/// the canonical candidate enumeration for calls and function references:
/// ordinary declarations enter by simple name, renamed imports by exact
/// FQN, and each declaration identity appears once.
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

/// Whether any bare-call candidate for `name` is a PLAIN function rather
/// than an extension. An extension candidate cannot answer a bare call
/// that supplies no receiver of its receiver type, so a caller deciding
/// between "the enclosing class's member" and "a top-level function"
/// must not be talked out of the member by an extension namesake:
/// kotlinx-io's `Utf8Test` declares both
/// `assertCodePointDecoded(String, vararg Int)` and
/// `Buffer.assertCodePointDecoded(Int, String, Int)`, and the latter made
/// the former's own bare call look like a global.
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

/// Whether source file `file` declares `import <pkg>.*`. A wildcard
/// import is file-scoped like a named one.
pub fn importWildcardIn(self: *const Module, file: FileId, pkg: []const u8) bool {
    if (pkg.len == 0) return false;
    if (self.registry.import_wildcards.get(file)) |list| {
        for (list.items) |path| {
            if (std.mem.eql(u8, path, pkg)) return true;
        }
    }
    return false;
}

/// Packages whose top-level entities are implicitly visible in every
/// Kotlin source file. Mirrors the canonical
/// `stdlib.IMPLICITLY_IMPORTED_PACKAGES` (the `ir` module cannot
/// depend on `stdlib`); an interp-side test keeps the two in
/// lockstep.
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

/// The lowest tier whose candidates are visible to the caller under
/// Kotlin scoping (named import / own package / wildcard import /
/// default import). An identical-signature tie above this line is a
/// real ambiguity; below it Kotlin would not resolve the call at all
/// and klio's lenient pick stays heuristic.
pub const last_in_scope_tier: u8 = 3;

/// The tier of a candidate in a package the caller neither
/// declares, imports, nor sees by default or via the shipped
/// surface — Kotlin does not resolve such a reference at all.
pub const other_package_tier: u8 = 5;

/// Bare-call preference tier of a candidate func, ranked low-to-high
/// urgency: 0 = file-named-import, 1 = own package, 2 = file-
/// wildcard-import package, 3 = default-import package, 4 = built-in
/// stdlib, 5 = any other package. This is Kotlin's resolution order
/// for an unqualified top-level callable: the file's explicit
/// imports outrank even a same-file declaration, then the declaring
/// package's own scope, then star imports, then the implicitly
/// imported packages. `caller_pkg` is the caller's declaring package
/// (`""` for a user script). A non-wildcard import of `name` in
/// `caller_file` whose full path equals the candidate's FQN matches
/// tier 0; a wildcard import of the candidate's package matches
/// tier 2.
pub fn bareCallTier(self: *const Module, f: *const Func, name: []const u8, caller_pkg: []const u8, caller_file: FileId) u8 {
    return self.scopeTier(f.fqn, f.package, name, caller_pkg, caller_file);
}

/// The scope tier of one declared symbol (function or class) at a
/// reference site, over its FQN and declaring package. Shared by
/// `bareCallTier` and `classIdIndexed` so both kinds rank under the
/// same Kotlin scoping order.
/// The class/object this file EXACT-imports under `name` (tier-0
/// resolution only). A read where a same-named top-level property would
/// otherwise win by default still binds an explicitly imported
/// classifier — kotlinc gives the exact import precedence over a
/// cross-package property (ktor: `import ...server...ContentNegotiation`
/// must not read the client package's same-named top-level val).
pub fn classIdExactImport(self: *const Module, name: []const u8, caller_file: FileId) ?ClassId {
    // Resolve the imported FQN directly rather than requiring a
    // `class_index` entry whose SIMPLE name is `name`: a collision-mangled
    // class (`import a.Widget` where a same-named `b.Widget` mangled both
    // to `Widget$fN`) is registered only under its mangled name, so the
    // simple-name scan misses it — but its FQN still resolves.
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

/// Number of *user* parameters a func declares (excluding a leading
/// synthesized extension/member `this`).
pub fn funcUserArity(f: *const Func) usize {
    if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) {
        return f.params.len - 1;
    }
    return f.params.len;
}

/// True for a func declared with a leading synthesized `this`
/// param — an instance method, a top-level extension, or a member
/// extension. A true bare call (no qualifier) only ever binds a
/// *non-extension* top-level function; receiver-based resolution of
/// the extension forms is the heuristic's domain, not the index's.
pub fn funcHasImplicitThis(f: *const Func) bool {
    return f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this");
}

/// `funcHasImplicitThis` for a candidate whose header stub carries no
/// parameters yet (a pack's deferred inline extension): the declaration
/// signature's receiver says it takes an implicit `this`.
pub fn candidateHasImplicitThis(self: *const Module, id: FuncId, f: *const Func) bool {
    if (funcHasImplicitThis(f)) return true;
    // A header stub may list only the value parameters; its declared
    // receiver still makes it an extension, never a plain function.
    const ds = self.decl_sigs.get(id.int()) orelse return false;
    return ds.receiver_ty != null;
}

/// The applicability `SigView` for a candidate at LOWERING time
/// (distinct from the module-internal `SigView` above, which the
/// index uses only for the `sameUserSig` identity check). Strips a
/// leading synthesized `this` so the shared scorer ranks value args
/// against user parameters. A phase-one header whose declaration has a
/// body is equally rankable: its params already carry the complete types,
/// defaults, and vararg flags even though its IR blocks are not lowered
/// yet. An `expect` header is also a valid compile-time target; linking or
/// runtime execution decides whether an actual implementation exists.
///
/// `func_defaults` lives on `ProgramImage`, not on `Module`, so the
/// lowering adapter cannot read it; it carries defaults on the params
/// (`paramHasDefault`'s null-`defaults` fallback).
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

/// Why the symbol index declined to resolve a bare call. Every
/// deferral carries one of these so an audit sweep can prove that
/// the heuristic fallback only ever handles classified structural
/// shapes, never an unclassified pick.
pub const ResolveDeferReason = enum {
    /// No top-level function with this simple name exists.
    no_candidates,
    /// Every candidate takes an implicit receiver `this` (instance
    /// method, top-level or member extension); receiver-based
    /// resolution is the heuristic's domain.
    extension_form,
    /// The lowerer always routes this bare name to an intrinsic; the
    /// index defers so it never binds the body the lowerer skips.
    intrinsic_owned,
    /// More than one exact match in a winning tier the caller can
    /// SEE (named import, own package, wildcard import, or default
    /// import), every match with the SAME full parameter type
    /// signature — generic arguments and function-type shapes
    /// included — so nothing can tell them apart, at lowering or at
    /// runtime. Kotlin rejects such a set as conflicting overloads.
    ambiguous_tier,
    /// More than one exact match in the winning tier, but the
    /// matches differ in parameter types: an overload set the
    /// runtime resolves by argument type.
    type_overload,
    /// More than one identical exact match, but every match lives in
    /// a package the caller neither declares, imports, nor sees by
    /// default — Kotlin would not resolve the call at all, so klio's
    /// lenient cross-package pick stays with the heuristic.
    unimported_set,
    /// The winning tier has candidates, but none matches the call's
    /// arity exactly.
    arity_mismatch,
    /// Candidates have defaults, but the positional call cannot bind
    /// them, or a legacy header lacks per-parameter default flags.
    default_param_shape,
    /// Only header stubs / bodyless decls with no declared-arity
    /// record were available.
    bodyless_only,
    /// The only exact matches are low-priority overloads.
    low_priority_only,
    /// The only near matches take a trailing vararg.
    vararg_only,
    /// The call's trailing lambda spans a default-parameter gap, a
    /// shape the index does not model.
    trailing_lambda_shape,
    /// Same-tier same-arity overload set disambiguated by an `as`
    /// cast at the call site. Assigned by the lowerer (which sees
    /// the cast), never produced by the index itself.
    cast_disambiguated,
};

/// Result of `resolveBareCallIndexed`: either a unique `FuncId` or a
/// reason-tagged deferral to the heuristic, plus the winning tier and
/// its best-match count for the resolve audit's readout.
pub const BareCallResolution = struct {
    pub const Outcome = union(enum) {
        resolved: FuncId,
        deferred: ResolveDeferReason,
    };
    outcome: Outcome,
    /// Winning preference tier (0..5), or 255 when no candidate
    /// established one.
    tier: u8 = 255,
    /// Best-ranked positional matches counted within the winning tier.
    tier_count: usize = 0,
    /// First two best-ranked matches in the winning tier; both set when
    /// the outcome is `ambiguous_tier`.
    first: ?FuncId = null,
    second: ?FuncId = null,

    /// The resolved id, or null on any deferral.
    pub fn pick(self: BareCallResolution) ?FuncId {
        return switch (self.outcome) {
            .resolved => |id| id,
            .deferred => null,
        };
    }

    /// Deferred because every candidate that matched is
    /// `@LowPriorityInOverloadResolution` / a deprecated stub. Binding the
    /// heuristic here would statically pick such a stub over a same-name
    /// class constructor (kotlinx-datetime's `fun LocalDateTime`), which
    /// self-recurses; the caller must emit a dynamic call instead.
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

/// Whether a phase-1 header stub's *declared* user arity exactly
/// matches the call: no defaults (`required == total`), no vararg at
/// any position, and exactly `want` parameters. Stubs carry no
/// lowered params, so this is the order-independent arity source for
/// ranking forward references; defaults/vararg/trailing-lambda
/// shapes on a stub stay deferred to the heuristic.
pub fn stubDeclArity(self: *const Module, id: FuncId) ?DeclArity {
    return self.decl_user_arity.get(id.int());
}

/// Preference tier of one specific candidate at a call site. The
/// resolve audit uses this to grade a heuristic pick against the
/// index's: a divergence where the index pick ranks strictly better
/// is a package-preference correction, not a mis-bind.
pub fn bareCallTierOf(self: *const Module, id: FuncId, name: []const u8, caller_pkg: []const u8, caller_file: FileId) ?u8 {
    const f = self.funcById(id) orelse return null;
    return self.bareCallTier(f, name, caller_pkg, caller_file);
}

/// A candidate's user-parameter type signature: lowered params for
/// a body-bearing func, the phase-1 declared record for a header
/// stub. Both render through `lower.decl.loweredTypeRef`, so a stub
/// and its later-lowered body expose identical structures. `null`
/// when the signature is unknowable (a bodyless func with no
/// declared record), which forfeits any identity proof.
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

/// Whether two candidates declare the same user parameter type
/// signature (leading synthesized `this` excluded), compared over
/// the FULL declared structure: head name, nullability, and the
/// recursive argument shapes — generic arguments, and a function
/// type's suspend marker, receiver, parameter, and return types.
/// Only a set equal at this granularity is a true duplicate that
/// Kotlin rejects as conflicting overloads; any structural
/// difference leaves a type-dispatched overload set.
pub fn sameUserSig(a: SigView, b: SigView) bool {
    if (a.len() != b.len()) return false;
    var i: usize = 0;
    while (i < a.len()) : (i += 1) {
        if (!a.at(i).eql(b.at(i))) return false;
    }
    return true;
}

/// Whether any parameter is declared `vararg`, at any position —
/// the body-side mirror of `DeclArity.has_vararg`, so the stub and
/// body gates skip the same candidate shapes.
pub fn anyParamVararg(f: *const Func) bool {
    for (f.params) |p| {
        if (p.is_vararg) return true;
    }
    return false;
}

/// Number of positional arguments omitted from the end of `f` while still
/// producing a valid call. Kotlin permits the omission only when every
/// omitted parameter has a default; a required parameter after an earlier
/// default therefore remains required for a positional call.
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

/// Whether the call's trailing lambda can bind `f`'s last (function-
/// typed) parameter with every gap parameter defaulted — the shape
/// the heuristic's trailing-lambda rung accepts and the index defers.
/// Whether a declared parameter type names a `fun interface`.
pub fn typeNamesFunInterface(self: *const Module, ty_name: []const u8) bool {
    const nm = std.mem.trimEnd(u8, ty_name, "?");
    const cid = self.classIdByFqn(nm) orelse self.classId(nm) orelse return false;
    if (cid.int() >= self.classes.items.len) return false;
    return self.classes.items[cid.int()].is_fun_interface;
}

pub fn tlShapeMatches(self: *const Module, f: *const Func, want: usize) bool {
    const up = funcUserArity(f);
    // A trailing lambda also fills a `fun interface` parameter (SAM
    // conversion): `g { A("K") }` for `fun g(unit: Unit = Unit, b: B)`.
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

/// Principled bare-call resolution: resolve `name` (called with
/// `want_arity` user args, `last_arg_lambda` set when a trailing
/// lambda is supplied) to a UNIQUE `FuncId` as a function of the
/// caller's package + imports + the complete header set, independent
/// of declaration order. Phase-1 header stubs (forward references,
/// `expect` decls) rank by their recorded declared arity, so the
/// answer does not depend on whether a candidate's body has been
/// lowered yet.
///
/// Preference order — file-named imports, then the caller's own
/// package, then wildcard imports, then the default-import packages,
/// then built-in stdlib (Kotlin's scoping order) — picks the highest
/// non-empty tier; within that tier the candidate is returned only when
/// exactly one non-extension func matches the positional call. Exact
/// arity outranks a call that consumes defaults, then fewer consumed
/// defaults wins. Extension funcs (a leading
/// synthesized `this`) are never index-resolved: a bare call to one
/// needs a receiver the index does not model, so it is left to the
/// order-based heuristic. A name the index cannot resolve to a
/// single non-extension target defers with a reason classifying
/// why. Where the index and the heuristic both resolve, they agree
/// — except when the heuristic's declaration-order pick sits in a
/// strictly worse preference tier or matches the call less exactly
/// (a vararg/default/arity-mismatched fallback where the index found
/// an exact overload); the resolve audit grades every divergence as
/// one of those corrections, a receiver-preference the heuristic
/// retains, or a bug.
pub fn resolveBareCallIndexed(
    self: *const Module,
    name: []const u8,
    caller_pkg_in: []const u8,
    caller_file: FileId,
    want_arity: usize,
    last_arg_lambda: bool,
) BareCallResolution {
    // Scope follows the call span's FILE: a spliced inline body carries
    // the donor file's spans, so its bare calls resolve in the donor's
    // package (`withFrameNanos` inside `withFrameMillis`'s body is a
    // same-package call wherever the splice lands).
    const caller_pkg = self.packageOfFile(caller_file) orelse caller_pkg_in;
    var candidate_it = self.bareCallCandidateIterator(name, caller_file);
    if (candidate_it.next() == null)
        return BareCallResolution.deferred(.no_candidates);

    // Highest-priority tier among the non-extension candidates:
    // body-bearing funcs, plus header stubs with a declared-arity
    // record (rankable without a lowered body).
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
    // Every rankable non-extension candidate lives in a package the
    // caller cannot see, while an in-scope extension (or member) form
    // exists. Kotlin resolves the call against an implicit receiver's
    // extension long before it would even consider the invisible
    // package, so receiver-based resolution — the heuristic's
    // domain — decides; binding (or rejecting) the invisible
    // function here would be wrong on both counts.
    if (best_tier == other_package_tier and ext_in_scope) {
        return BareCallResolution.deferred(.extension_form);
    }

    // Within the best tier, look for a unique positional,
    // non-low-priority, non-extension candidate. Exact arity outranks a
    // candidate that consumes defaults; among defaulted candidates, the
    // one consuming fewer defaults outranks one consuming more. Track the
    // closest miss so a zero-match tier defers with the blocking shape.
    var chosen: ?FuncId = null;
    var second: ?FuncId = null;
    var count: usize = 0;
    var best_defaults_used: usize = std.math.maxInt(usize);
    // Whether every best-ranked match has the same user
    // parameter type signature as the first one. Distinguishes a
    // true ambiguity from a type-dispatched overload set.
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
        // The stub and body gates accept the same positional/default
        // shapes so resolution never depends on whether the body has
        // already replaced its phase-1 header.
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
            // Legacy/test stubs may carry only the aggregate declared
            // arity. Full arity needs no per-parameter default evidence.
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
            // Identity is proven over lowered params for bodies and
            // the phase-1 declared record for stubs; a candidate
            // with neither forfeits the proof.
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
        // A unique match in a package the caller cannot see is not a
        // resolution: kotlinc rejects the reference outright. Defer as
        // an unimported set — the diagnostic layer reports it and the
        // dynamic path keeps klio's lenient last resort. A candidate
        // with no recorded package is a lift artifact with unreliable
        // scoping metadata and keeps the lenient resolution.
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

// -----------------------------------------------------------------
// `resolveCall` — the single applicability-primary, type-aware,
// three-tier bare-call resolver.
// -----------------------------------------------------------------
