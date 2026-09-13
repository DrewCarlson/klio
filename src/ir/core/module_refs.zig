const std = @import("std");
const applicability = @import("applicability");
const Allocator = std.mem.Allocator;
const root_ir = @import("../ir.zig");
const core_class = @import("class.zig");
const core_consts = @import("consts.zig");
const core_ids = @import("ids.zig");
const core_names = @import("names.zig");
const core_registry = @import("registry.zig");

const Class = core_class.Class;
const Const = core_consts.Const;
const FileId = root_ir.FileId;
const FuncId = core_ids.FuncId;
const Module = root_ir.Module;
const ModuleRegistry = core_registry.ModuleRegistry;
const TypeRef = core_ids.TypeRef;
const idGet = core_names.idGet;
const last_in_scope_tier = Module.last_in_scope_tier;
const staticTypeHead = Module.staticTypeHead;

/// Value-position bare-reference resolution: resolve `name` (a bare
/// identifier read, not a call) to a unique `FuncId` under the same
/// scope tiers as `resolveBareCallIndexed`, with no arity filter — a
/// reference denotes the declaration itself, so a vararg or
/// defaulted signature is as referenceable as any other. Extension
/// forms never resolve (a bare read cannot supply the receiver),
/// intrinsic-owned names defer to the lowerer's intrinsic routing,
/// and the winning tier must hold exactly one candidate. A phase-1
/// header stub resolves too: its FQN is final and phase-2 fills the
/// same slot, so the answer is declaration-order independent.
pub fn resolveBareRefIndexed(
    self: *const Module,
    name: []const u8,
    caller_pkg: []const u8,
    caller_file: FileId,
) ?FuncId {
    var best_tier: u8 = 255;
    var candidate_it = self.bareCallCandidateIterator(name, caller_file);
    while (candidate_it.next()) |id| {
        const f = self.funcById(id) orelse continue;
        if (self.candidateHasImplicitThis(id, f)) continue;
        if (!f.hasBody() and self.stubDeclArity(id) == null) continue;
        const t = self.bareCallTier(f, name, caller_pkg, caller_file);
        if (t < best_tier) best_tier = t;
    }
    if (best_tier == 255) return null;
    var chosen: ?FuncId = null;
    var count: usize = 0;
    candidate_it = self.bareCallCandidateIterator(name, caller_file);
    while (candidate_it.next()) |id| {
        const f = self.funcById(id) orelse continue;
        if (self.candidateHasImplicitThis(id, f)) continue;
        if (!f.hasBody() and self.stubDeclArity(id) == null) continue;
        if (self.bareCallTier(f, name, caller_pkg, caller_file) != best_tier) continue;
        if (chosen == null) chosen = id;
        count += 1;
    }
    if (count == 1) return chosen;
    return null;
}

/// Resolve an overloaded bare callable reference from its expected
/// function-parameter types. Candidate enumeration, scope, and static
/// applicability are identical to a source call; no receiver is supplied,
/// so extension declarations remain outside this unbound bare form.
pub fn resolveBareRefExpected(
    self: *const Module,
    allocator: Allocator,
    name: []const u8,
    caller_pkg_in: []const u8,
    caller_file: FileId,
    args: []const applicability.ArgShape,
) Allocator.Error!?FuncId {
    const candidates = try self.bareCallCandidates(allocator, name, caller_file);
    defer allocator.free(candidates);
    if (candidates.len == 0) return null;
    const caller_pkg = self.packageOfFile(caller_file) orelse caller_pkg_in;
    const pick = self.applicableBarePick(
        name,
        candidates,
        args,
        caller_pkg,
        caller_file,
        .{},
        false,
    );
    return if (pick.unique) pick.target else null;
}

/// The best (lowest) scope tier among the value-referenceable
/// non-extension funcs of `name` at a reference site, or `null` when
/// no such func exists. A value reference (`::name` / a bare read)
/// denotes the declaration itself, so this ranks under the same
/// scoping order as `resolveBareRefIndexed` but ignores arity and
/// uniqueness. `other_package_tier` means every candidate lives in a
/// package the caller neither declares, imports, nor sees by default
/// or via the shipped surface — Kotlin does not resolve such a
/// reference at all, so the lowerer rejects it (kotlinc:
/// `unresolved reference`).
pub fn bareRefTier(
    self: *const Module,
    name: []const u8,
    caller_pkg_in: []const u8,
    caller_file: FileId,
) ?u8 {
    // Scope follows the reference span's FILE (see
    // resolveBareCallIndexed): a spliced inline body carries the donor
    // file's spans, so its bare reads rank in the donor's package.
    const caller_pkg = self.packageOfFile(caller_file) orelse caller_pkg_in;
    var best_tier: u8 = 255;
    var candidate_it = self.bareCallCandidateIterator(name, caller_file);
    while (candidate_it.next()) |id| {
        const f = self.funcById(id) orelse continue;
        if (self.candidateHasImplicitThis(id, f)) continue;
        if (!f.hasBody() and self.stubDeclArity(id) == null) continue;
        const t = self.bareCallTier(f, name, caller_pkg, caller_file);
        if (t < best_tier) best_tier = t;
    }
    if (best_tier == 255) return null;
    return best_tier;
}

/// The best (lowest) scope tier among the classes named `name` at a
/// reference site, or `null` when no such class exists. Mirrors
/// `bareRefTier` for `::Ctor` callable references and bare type-name
/// value reads; `other_package_tier` means the only matching class is
/// in an unimported package.
pub fn classRefTier(
    self: *const Module,
    name: []const u8,
    caller_pkg_in: []const u8,
    caller_file: FileId,
) ?u8 {
    const caller_pkg = self.packageOfFile(caller_file) orelse caller_pkg_in;
    // Exact imports include renamed aliases and collision-mangled classes
    // that have no `class_index` entry under the call-site spelling.
    if (self.classIdExactImport(name, caller_file) != null) return 0;
    var best_tier: u8 = 255;
    for (self.class_index.items) |entry| {
        if (!std.mem.eql(u8, entry.name, name)) continue;
        const c = idGet(Class, self.classes.items, entry.id.int()) orelse continue;
        const t = self.scopeTier(c.fqn, c.package, name, caller_pkg, caller_file);
        if (t < best_tier) best_tier = t;
    }
    if (best_tier == 255) return null;
    return best_tier;
}

/// The best (lowest) scope tier among the top-level property
/// declarations named `name` at a reference site, or `null` when no
/// such property is known. A bare property read resolves under the
/// same Kotlin scoping order as a call; `other_package_tier` means
/// every declaration is in an unimported package, so kotlinc rejects
/// the read as unresolved.
pub fn topLevelPropRefTier(
    self: *const Module,
    name: []const u8,
    caller_pkg_in: []const u8,
    caller_file: FileId,
) ?u8 {
    const caller_pkg = self.packageOfFile(caller_file) orelse caller_pkg_in;
    const list = self.registry.top_level_prop_pkgs.get(name) orelse return null;
    var best_tier: u8 = 255;
    for (list.items) |pd| {
        const t = self.scopeTier(pd.fqn, pd.package, name, caller_pkg, caller_file);
        if (t < best_tier) best_tier = t;
    }
    if (best_tier == 255) return null;
    return best_tier;
}

/// The declared type head of the top-level property a bare read of
/// `name` resolves to under Kotlin scoping — the best-tier declaration,
/// and only when every declaration AT that tier agrees on the head (a
/// cross-package name clash types nothing).
/// The type head of one top-level property declaration: what its
/// annotation or literal initializer stated, else what the function its
/// initializer CALLS returns. The call is resolved here rather than at
/// registration because only now is the whole declaration set visible.
/// The full declared type of one top-level property declaration, where
/// its arguments were recorded. Null leaves the head-only answer.
pub fn topLevelPropTypeRef(
    self: *const Module,
    name: []const u8,
    caller_pkg: []const u8,
    caller_file: FileId,
) ?TypeRef {
    const list = self.registry.top_level_prop_pkgs.get(name) orelse return null;
    var best_tier: u8 = 255;
    var found: ?TypeRef = null;
    for (list.items) |pd| {
        const t = self.scopeTier(pd.fqn, pd.package, name, caller_pkg, caller_file);
        if (t == 255) continue;
        const r = self.registry.top_level_prop_type_refs.get(pd.fqn);
        if (t < best_tier) {
            best_tier = t;
            found = r;
        } else if (t == best_tier) {
            const cur = found orelse return null;
            const new = r orelse return null;
            if (!std.mem.eql(u8, cur.name, new.name)) return null;
        }
    }
    return found;
}

/// The tiered HEAD twin of `topLevelPropTypeRef`: a scalar top-level
/// property (`private const val DAYS_PER_CYCLE = 146097L`) records only
/// its head, and the deriver's Path arm needs it under the same
/// caller-scope tiers.
pub fn topLevelPropTypeHeadTiered(
    self: *const Module,
    name: []const u8,
    caller_pkg: []const u8,
    caller_file: FileId,
) ?[]const u8 {
    const list = self.registry.top_level_prop_pkgs.get(name) orelse {
        if (std.c.getenv("KLIO_TLP_TRACE")) |w| {
            if (std.mem.eql(u8, std.mem.span(w), name))
                std.debug.print("[tlp] {s} NO-LIST caller_pkg={s}\n", .{ name, caller_pkg });
        }
        return null;
    };
    var best_tier: u8 = 255;
    var found: ?[]const u8 = null;
    for (list.items) |pd| {
        const t = self.scopeTier(pd.fqn, pd.package, name, caller_pkg, caller_file);
        if (std.c.getenv("KLIO_TLP_TRACE")) |w| {
            if (std.mem.eql(u8, std.mem.span(w), name))
                std.debug.print("[tlp] {s} fqn={s} pkg={s} tier={d} head={s} caller_pkg={s}\n", .{ name, pd.fqn, pd.package, t, self.registry.top_level_prop_type_heads.get(pd.fqn) orelse "-", caller_pkg });
        }
        if (t == 255) continue;
        const h = self.registry.top_level_prop_type_heads.get(pd.fqn);
        if (t < best_tier) {
            best_tier = t;
            found = h;
        } else if (t == best_tier) {
            const cur = found orelse return null;
            const new = h orelse return null;
            if (!std.mem.eql(u8, cur, new)) return null;
        }
    }
    return found;
}

pub fn topLevelPropHeadFor(self: *const Module, fqn: []const u8) ?[]const u8 {
    if (self.registry.top_level_prop_type_heads.get(fqn)) |h| return h;
    const callee = self.registry.top_level_prop_init_callees.get(fqn) orelse return null;
    var head: ?[]const u8 = null;
    for (self.funcsBySimpleName(callee)) |fid| {
        const f = self.funcById(fid) orelse continue;
        if (f.kind != .plain) continue;
        if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) continue;
        var h = staticTypeHead(std.mem.trimEnd(u8, f.return_ty.name, "?"));
        if (h.len == 0) return null;
        if (std.mem.findScalarLast(u8, h, '.')) |d| h = h[d + 1 ..];
        if (head) |prev| {
            if (!std.mem.eql(u8, prev, h)) return null;
        } else head = h;
    }
    if (head) |h| {
        // Only a head that names a class the module knows: a type
        // parameter or an unresolvable name disproves candidates a null
        // would have left open.
        if (self.uniqueClassIdBySimpleName(h) == null and self.classIdByFqn(h) == null) return null;
        return h;
    }
    // A constructor call states the class outright.
    if (self.uniqueClassIdBySimpleName(callee) != null) return callee;
    return null;
}

pub fn topLevelPropTypeHead(
    self: *const Module,
    name: []const u8,
    caller_pkg: []const u8,
    caller_file: FileId,
) ?[]const u8 {
    const list = self.registry.top_level_prop_pkgs.get(name) orelse return null;
    var best_tier: u8 = 255;
    var head: ?[]const u8 = null;
    for (list.items) |pd| {
        const t = self.scopeTier(pd.fqn, pd.package, name, caller_pkg, caller_file);
        if (t == 255) continue;
        const h = self.topLevelPropHeadFor(pd.fqn);
        if (t < best_tier) {
            best_tier = t;
            head = h;
        } else if (t == best_tier) {
            const cur = head orelse return null;
            const new = h orelse return null;
            if (!std.mem.eql(u8, cur, new)) return null;
        }
    }
    return head;
}

/// Resolve a top-level callable extension property at an explicit
/// receiver call site. A member function has already been ruled out by
/// the caller; this query applies receiver, arity, visibility, and normal
/// Kotlin import/package tiers and commits only one declaration identity.
pub fn resolveCallableExtensionProperty(
    self: *const Module,
    name: []const u8,
    receiver_head: []const u8,
    receiver_is_class: bool,
    value_arity: usize,
    caller_pkg: []const u8,
    caller_file: FileId,
) ?ModuleRegistry.CallableExtensionProp {
    const Helpers = struct {
        fn outerCompanionHead(receiver: []const u8) ?[]const u8 {
            const suffix = ".Companion";
            if (!std.mem.endsWith(u8, receiver, suffix)) return null;
            return staticTypeHead(receiver[0 .. receiver.len - suffix.len]);
        }

        fn receiverMatches(
            module: *const Module,
            declared: []const u8,
            actual: []const u8,
            is_class: bool,
        ) bool {
            if (outerCompanionHead(declared)) |outer| {
                return is_class and std.mem.eql(u8, outer, staticTypeHead(actual));
            }
            if (is_class) return false;
            return module.classIsOrExtends(actual, declared);
        }
    };

    var source_name = name;
    var list = self.registry.callable_extension_props.get(source_name);
    if (list == null) {
        for (self.importAliasPathsIn(caller_file, name)) |path| {
            source_name = staticTypeHead(path.fqn);
            list = self.registry.callable_extension_props.get(source_name);
            if (list != null) break;
        }
    }
    const candidates = list orelse return null;
    var best: ?ModuleRegistry.CallableExtensionProp = null;
    var best_tier: u8 = 255;
    var ambiguous = false;
    for (candidates.items) |candidate| {
        if (candidate.value_arity != value_arity) continue;
        if (candidate.is_private and candidate.file != caller_file) continue;
        if (!Helpers.receiverMatches(self, candidate.receiver, receiver_head, receiver_is_class)) continue;
        const tier = self.scopeTier(
            candidate.fqn,
            candidate.package,
            name,
            caller_pkg,
            caller_file,
        );
        if (tier > last_in_scope_tier) continue;
        if (tier < best_tier) {
            best = candidate;
            best_tier = tier;
            ambiguous = false;
        } else if (tier == best_tier and best != null and
            !std.mem.eql(u8, best.?.fqn, candidate.fqn))
        {
            ambiguous = true;
        }
    }
    return if (ambiguous) null else best;
}

/// The literal value of the top-level `const val` a bare reference to
/// `name` resolves to at this site, or null when the best-scoped
/// declaration is not a recorded compile-time constant (or the pick is
/// ambiguous). Kotlin inlines const vals at every reference; emitting
/// the literal keeps the read immune to the flat runtime global table,
/// where a same-simple-name value from another module can win.
pub fn topLevelConstLiteral(
    self: *const Module,
    name: []const u8,
    caller_pkg: []const u8,
    caller_file: FileId,
) ?Const {
    const list = self.registry.top_level_prop_pkgs.get(name) orelse return null;
    var best_tier: u8 = 255;
    var best_fqn: ?[]const u8 = null;
    var ambiguous = false;
    for (list.items) |pd| {
        const t = self.scopeTier(pd.fqn, pd.package, name, caller_pkg, caller_file);
        if (t < best_tier) {
            best_tier = t;
            best_fqn = pd.fqn;
            ambiguous = false;
        } else if (t == best_tier and best_fqn != null and !std.mem.eql(u8, best_fqn.?, pd.fqn)) {
            ambiguous = true;
        }
    }
    if (ambiguous or best_tier == 255) return null;
    const fqn = best_fqn orelse return null;
    return self.registry.top_level_const_vals.get(fqn);
}

/// The FQN of the first known top-level property declaration named
/// `name`, for an out-of-scope value-reference diagnostic.
pub fn topLevelPropFqn(self: *const Module, name: []const u8) ?[]const u8 {
    const list = self.registry.top_level_prop_pkgs.get(name) orelse return null;
    if (list.items.len == 0) return null;
    return list.items[0].fqn;
}
