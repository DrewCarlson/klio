const std = @import("std");
const runtime = @import("runtime");
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

/// Resolve a bare identifier read to a unique `FuncId` under the same scope tiers as
/// `resolveBareCallIndexed`, with no arity filter: a reference denotes the declaration
/// itself. Extensions never resolve, and the winning tier must hold one candidate.
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

/// Resolve an overloaded bare callable reference from its expected parameter types.
/// Scope and applicability match a source call; extensions stay out, being unbound.
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

/// Resolve a top-level callable extension property at an explicit receiver site,
/// after member functions are ruled out; commits exactly one declaration identity.
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

