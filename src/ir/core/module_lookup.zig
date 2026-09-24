const std = @import("std");
const span = @import("span");
const runtime = @import("runtime");
const applicability = @import("applicability");
const Allocator = std.mem.Allocator;
const root_ir = @import("../ir.zig");
const core_class = @import("class.zig");
const core_consts = @import("consts.zig");
const core_func = @import("func.zig");
const core_ids = @import("ids.zig");
const core_names = @import("names.zig");
const core_registry = @import("registry.zig");

const Class = core_class.Class;
const ClassId = core_ids.ClassId;
const Const = core_consts.Const;
const ConstId = core_ids.ConstId;
const DeclArity = Module.DeclArity;
const DeclSig = Module.DeclSig;
const FileId = root_ir.FileId;
const Func = core_func.Func;
const FuncId = core_ids.FuncId;
const Module = root_ir.Module;
const ModuleRegistry = core_registry.ModuleRegistry;
const Span = root_ir.Span;
const StrPairMap = core_class.StrPairMap;
const TypeRef = core_ids.TypeRef;
const constHash = core_consts.constHash;
const fqnHasHeadSegment = core_names.fqnHasHeadSegment;
const headAllUpper = core_class.headAllUpper;
const idGet = core_names.idGet;
const insertFqnPrefixes = core_names.insertFqnPrefixes;
const isShippedPackage = core_names.isShippedPackage;
const rankLowPriority = core_func.rankLowPriority;
const staticTypeHead = Module.staticTypeHead;

pub fn init(allocator: Allocator) Module {
    return Module{
        .lookup_cache_gpa = allocator,
        .func_name_index = runtime.NameHashMap(std.ArrayList(FuncId)).init(allocator),
        .registry = ModuleRegistry.init(allocator),
        .decl_user_arity = std.AutoHashMap(u32, DeclArity).init(allocator),
        .decl_user_sig = std.AutoHashMap(u32, []TypeRef).init(allocator),
        .decl_span = std.AutoHashMap(u32, Span).init(allocator),
        .decl_ast_body = std.AutoHashMap(u32, void).init(allocator),
        .decl_sigs = std.AutoHashMap(u32, DeclSig).init(allocator),
        .member_name_index = StrPairMap(std.ArrayList(FuncId)).init(allocator),
        .method_dispatch = std.AutoHashMap(u64, FuncId).init(allocator),
        .prop_dispatch = std.AutoHashMap(u64, root_ir.PropTarget).init(allocator),
        .prop_slot_ids = StrPairMap(u32).init(allocator),
    };
}

pub fn default(allocator: Allocator) Module {
    return Module.init(allocator);
}

/// Materialise `func`'s deferred `blocks` from the lazy-IR section, clearing `deferred_offset`.
/// Decoded into the module's process-lifetime arena, so the patch outlives a per-program build.
pub fn ensureFuncBody(self: *const Module, func: *Func) bool {
    // `deferred_offset` is the publication flag: it clears, with release, only after
    // `blocks` is written, so a reader that sees it clear sees the blocks.
    if (@atomicLoad(u32, &func.deferred_offset, .acquire) == 0) return func.blocks.len != 0;
    const decode = self.deferred_func_decode orelse return false;
    // The header lock serializes decode and publication.
    const mut: *Module = @constCast(self);
    while (mut.func_header_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
    defer mut.func_header_lock.store(false, .release);
    if (func.deferred_offset == 0) return func.blocks.len != 0;
    if (decode(self.deferred_func_arena, self.deferred_func_section, func.deferred_offset - 1)) |blocks| {
        func.blocks = blocks;
        @atomicStore(u32, &func.deferred_offset, 0, .release);
    }
    return func.blocks.len != 0;
}

/// Look up a function by id. Eager build: direct table index. Lazy (loaded image, with
/// `func_header_offsets`): decode the header on first touch, memoised in `func_cache`.
pub fn funcById(self: *const Module, id: FuncId) ?*const Func {
    const i = id.int();
    const base_n: u32 = @intCast(self.func_header_offsets.len);
    // Ids at/after the lazy base range are this module's own appended funcs: dense
    // in `funcs.items` from id == base_n, then `late_funcs`.
    if (i >= base_n) {
        const j = i - base_n;
        if (j < self.funcs.items.len) return &self.funcs.items[j];
        const k = j - self.funcs.items.len;
        if (k < self.late_funcs.items.len) return self.late_funcs.items[k];
        return null;
    }
    // i < base_n: a base func owned by the shared lazy header section. Decode and memoise.
    if (i >= self.func_cache.len) return null;
    if (self.func_cache[i]) |f| return f;
    const off = self.func_header_offsets[i];
    if (off == 0) return null;
    const decode = self.func_header_decode orelse return null;
    const mut: *Module = @constCast(self);
    while (mut.func_header_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
    defer mut.func_header_lock.store(false, .release);
    if (self.func_cache[i]) |f| return f; // lost the race
    const f = self.deferred_func_arena.create(Func) catch return null;
    f.* = decode(self.deferred_func_arena, self.func_header_section, off - 1) orelse return null;
    mut.func_cache[i] = f;
    return f;
}

/// A mutable handle to one of THIS module's own appended funcs; base funcs are immutable.
pub fn funcByIdMut(self: *Module, id: FuncId) ?*Func {
    const i = id.int();
    const base_n: u32 = @intCast(self.func_header_offsets.len);
    if (i < base_n) return null;
    const j = i - base_n;
    if (j < self.funcs.items.len) return &self.funcs.items[j];
    const k = j - self.funcs.items.len;
    if (k < self.late_funcs.items.len) return self.late_funcs.items[k];
    return null;
}

pub fn appendedFuncCount(self: *const Module) usize {
    return self.funcs.items.len + self.late_funcs.items.len;
}

/// The id the next appended func takes: first id past the lazy base range, plus appends so far.
pub fn nextFuncId(self: *const Module) FuncId {
    return FuncId.from(@intCast(self.func_header_offsets.len + self.appendedFuncCount()));
}

/// Add one declaration to its owner-scoped overload set. Re-registering the same
/// declaration is harmless: header reservation and body placement share one id.
pub fn registerMemberDecl(
    self: *Module,
    allocator: Allocator,
    owner_fqn: []const u8,
    name: []const u8,
    id: FuncId,
) Allocator.Error!void {
    const gop = try self.member_name_index.getOrPut(.{ .a = owner_fqn, .b = name });
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    for (gop.value_ptr.items) |existing| {
        if (existing.int() == id.int()) return;
    }
    try gop.value_ptr.append(allocator, id);
}

/// Every member declaration named `name` directly owned by `owner_fqn`, in declaration order.
pub fn memberDecls(self: *const Module, owner_fqn: []const u8, name: []const u8) []const FuncId {
    const list = self.member_name_index.get(.{ .a = owner_fqn, .b = name }) orelse return &.{};
    return list.items;
}

/// Functions addressable by id: eager table length, or the lazy offset-table length.
pub fn funcCount(self: *const Module) usize {
    return self.func_header_offsets.len + self.appendedFuncCount();
}

pub fn deinit(self: *Module, allocator: Allocator) void {
    self.funcs.deinit(allocator);
    for (self.late_funcs.items) |f| allocator.destroy(f);
    self.late_funcs.deinit(allocator);
    self.classes.deinit(allocator);
    self.field_layout.deinit(allocator);
    for (self.consts.items) |c| {
        if (c == .String) allocator.free(c.String);
    }
    self.consts.deinit(allocator);
    self.top_level.deinit(allocator);
    self.class_index.deinit(allocator);
    if (self.class_id_map) |*m| m.deinit();
    if (self.class_fqn_map) |*m| m.deinit();
    if (self.class_parent) |*m| m.deinit();
    if (self.func_by_decl_span) |*m| m.deinit();
    if (self.ext_names_by_recv_head) |*m| {
        var vit = m.valueIterator();
        while (vit.next()) |v| v.deinit();
        m.deinit();
    }
    if (self.generic_ext_names) |*m| m.deinit();
    if (self.class_children) |*m| {
        var itc = m.valueIterator();
        while (itc.next()) |v| v.deinit();
        m.deinit();
    }
    self.func_index.deinit(allocator);
    if (self.lookup_cache_gpa) |cg| {
        if (self.ext_resolve_cache) |c| {
            c.arena.deinit();
            cg.destroy(c);
        }
        if (self.recv_verdict_cache) |c| {
            c.clear(cg);
            c.map.deinit(cg);
            cg.destroy(c);
        }
        self.pkg_head_cache.deinit(cg);
        var cn_it = self.class_name_cache.valueIterator();
        while (cn_it.next()) |list| list.deinit(cg);
        self.class_name_cache.deinit(cg);
        self.class_fqn_cache.deinit(cg);
        self.unique_simple_cache.deinit(cg);
        self.const_dedup.deinit(cg);
    }
    var it = self.func_name_index.valueIterator();
    while (it.next()) |list| list.deinit(allocator);
    self.func_name_index.deinit();
    self.registry.deinit();
    self.decl_user_arity.deinit();
    {
        var sig_it = self.decl_user_sig.valueIterator();
        while (sig_it.next()) |sig| {
            for (sig.*) |*ty| ty.deinit(allocator);
            allocator.free(sig.*);
        }
        self.decl_user_sig.deinit();
    }
    self.decl_span.deinit();
    self.decl_ast_body.deinit();
    self.decl_sigs.deinit();
    {
        var member_it = self.member_name_index.valueIterator();
        while (member_it.next()) |list| list.deinit(allocator);
        self.member_name_index.deinit();
    }
    self.method_dispatch.deinit();
    self.prop_dispatch.deinit();
    self.prop_slot_ids.deinit();
}

pub fn classId(self: *const Module, name: []const u8) ?ClassId {
    if (self.class_id_map) |*m| {
        if (m.get(name)) |id| return id;
    } else if (self.classNameCandidates(name)) |ids| {
        if (ids.len != 0) return ids[0];
    } else {
        for (self.class_index.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.id;
        }
    }
    return null;
}

pub fn uniqueClassIdBySimpleName(self: *const Module, name: []const u8) ?ClassId {

    if (self.class_fqn_map != null) {
        // Finalized: `buildClassIdMap` completed the cache and lookups are concurrent, so read it
        // lock-free while it mirrors the append-only class list; a later addition falls back to the scan.
        if (self.unique_simple_cache_n == self.classes.items.len) {
            const info = self.unique_simple_cache.get(name) orelse return null;
            return if (info.id == class_id_ambiguous) null else info.id;
        }
    } else if (self.lookup_cache_gpa != null) {
        const mut: *Module = @constCast(self);
        if (mut.topUpUniqueSimpleCache()) {
            const info = mut.unique_simple_cache.get(name) orelse return null;
            return if (info.id == class_id_ambiguous) null else info.id;
        } else |_| {}
    }
    var found: ?ClassId = null;
    for (self.classes.items) |class| {
        const name_match = std.mem.eql(u8, class.name, name);
        if (!name_match) {
            if (!std.mem.eql(u8, applicability.simpleName(class.fqn), name)) continue;
            // Nested classes are not bare-name-visible.
            if (self.registry.enclosing_class.get(class.name) != null or
                self.registry.enclosing_class.get(class.fqn) != null) continue;
        }
        if (found) |id| {
            if (id != class.id and
                !std.mem.eql(u8, self.classes.items[id.int()].fqn, class.fqn)) return null;
        } else {
            found = class.id;
        }
    }
    return found;
}

pub fn topUpUniqueSimpleCache(self: *Module) Allocator.Error!void {
    const gpa = self.lookup_cache_gpa.?;
    while (self.unique_simple_cache_n < self.classes.items.len) : (self.unique_simple_cache_n += 1) {
        const c = self.classes.items[self.unique_simple_cache_n];
        const non_kotlin = !std.mem.eql(u8, c.package, "kotlin") and
            !std.mem.startsWith(u8, c.package, "kotlin.");
        try self.uniqueSimpleInsert(gpa, c.name, c.id, c.fqn, non_kotlin);
        const seg = applicability.simpleName(c.fqn);
        if (!std.mem.eql(u8, seg, c.name)) {
            // A nested class is not bare-name-visible outside its enclosing declaration, so
            // its trailing FQN segment must not create simple-name ambiguity.
            const nested = self.registry.enclosing_class.get(c.name) != null or
                self.registry.enclosing_class.get(c.fqn) != null;
            if (!nested) try self.uniqueSimpleInsert(gpa, seg, c.id, c.fqn, non_kotlin);
        }
    }
}

/// Fold one class into the simple-name cache under `key`, matching the scans: first class wins the
/// id, a later one conflicts only if id AND fqn differ, and a non-`kotlin` class taints the name.
pub fn uniqueSimpleInsert(self: *Module, gpa: Allocator, key: []const u8, id: ClassId, fqn: []const u8, non_kotlin: bool) Allocator.Error!void {
    const gop = try self.unique_simple_cache.getOrPut(gpa, key);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{ .id = id, .non_kotlin = non_kotlin };
        return;
    }
    gop.value_ptr.non_kotlin = gop.value_ptr.non_kotlin or non_kotlin;
    const cur = gop.value_ptr.id;
    if (cur == class_id_ambiguous or cur == id) return;
    if (!std.mem.eql(u8, self.classes.items[cur.int()].fqn, fqn)) {
        gop.value_ptr.id = class_id_ambiguous;
    }
}

/// The `ClassId`s under simple `name` in `class_index` order, the sequence the linear scan visits.
/// Null when the cache is unavailable (finalized, no cache allocator, OOM) and the caller must scan.
pub fn classNameCandidates(self: *const Module, name: []const u8) ?[]const ClassId {
    if (self.class_id_map != null) return null;
    const gpa = self.lookup_cache_gpa orelse return null;
    const mut: *Module = @constCast(self);
    mut.topUpClassNameCache(gpa) catch return null;
    if (mut.class_name_cache.getPtr(name)) |list| return list.items;
    return &.{};
}

pub fn topUpClassNameCache(self: *Module, gpa: Allocator) Allocator.Error!void {
    while (self.class_name_cache_n < self.class_index.items.len) : (self.class_name_cache_n += 1) {
        const entry = self.class_index.items[self.class_name_cache_n];
        const gop = try self.class_name_cache.getOrPut(gpa, entry.name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(gpa, entry.id);
    }
}

/// Which conservatism made `extCouldApply` answer yes. Diagnostic only.
pub const ExtCouldApplyWhy = enum { none, index_stale, generic_receiver, own_head, builtin_super, declared_super };

/// Merged value-argument counts the extensions of one name on one receiver head accept.
/// An extension that cannot take the call's argument count cannot shadow a member.
pub const ExtArity = struct {
    min: u32 = 0,
    max: u32 = std.math.maxInt(u32),

    fn accepts(self: ExtArity, argc: usize) bool {
        return argc >= self.min and argc <= self.max;
    }

    fn merge(self: ExtArity, other: ExtArity) ExtArity {
        return .{
            .min = @min(self.min, other.min),
            .max = @max(self.max, other.max),
        };
    }
};

/// Could ANY extension named `name` serve receiver head `head`? Chain-aware over the head's
/// supertypes and the builtin-supertype table; a generic receiver answers true for every head.
pub fn extCouldApply(
    self: *Module,
    allocator: Allocator,
    head: []const u8,
    name: []const u8,
    argc: usize,
) bool {
    return self.extCouldApplyWhy(allocator, head, name, argc) != .none;
}

pub fn extCouldApplyWhy(
    self: *Module,
    allocator: Allocator,
    head: []const u8,
    name: []const u8,
    argc: usize,
) ExtCouldApplyWhy {
    if (self.ext_names_by_recv_head == null or self.ext_index_decl_count != self.func_index.items.len) {
        self.rebuildExtIndex(allocator) catch return .index_stale;
    }
    if (self.generic_ext_names.?.get(name)) |arity| {
        if (arity.accepts(argc)) return .generic_receiver;
    }
    const idx = &self.ext_names_by_recv_head.?;
    if (idx.get(head)) |set| {
        if (set.get(name)) |arity| {
            if (arity.accepts(argc)) return .own_head;
        }
    }
    for (applicability.builtinSupersOf(head)) |sup| {
        if (idx.get(sup)) |set| {
            if (set.get(name)) |arity| {
                if (arity.accepts(argc)) return .builtin_super;
            }
        }
    }
    if (self.registry.class_super_names.get(head)) |chain| {
        for (chain) |sup| {
            if (idx.get(sup)) |set| {
                if (set.get(name)) |arity| {
                    if (arity.accepts(argc)) return .declared_super;
                }
            }
        }
    }
    return .none;
}

pub fn mergeExtArity(map: *runtime.NameHashMap(ExtArity), name: []const u8, arity: ExtArity) Allocator.Error!void {
    const gop = try map.getOrPut(name);
    gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.merge(arity) else arity;
}

pub fn rebuildExtIndex(self: *Module, allocator: Allocator) Allocator.Error!void {
    if (self.ext_names_by_recv_head) |*m| {
        var vit = m.valueIterator();
        while (vit.next()) |v| v.deinit();
        m.deinit();
    }
    if (self.generic_ext_names) |*m| m.deinit();
    var idx = runtime.NameHashMap(runtime.NameHashMap(ExtArity)).init(allocator);
    var gen = runtime.NameHashMap(ExtArity).init(allocator);
    for (self.func_index.items) |entry| {
        const ds = self.decl_sigs.get(entry.id.int());
        const f = if (ds == null) self.funcById(entry.id) else null;
        const kind = if (ds) |sig| sig.kind else if (f) |func| func.kind else continue;
        const is_ext = kind == .top_level_extension or kind == .member_extension;
        if (!is_ext) continue;
        const receiver_ty = if (ds) |sig|
            sig.receiver_ty
        else if (f) |func|
            if (func.params.len != 0) func.params[0].ty else null
        else
            null;
        const raw_head = (receiver_ty orelse continue).name;
        const head = staticTypeHead(raw_head);
        // A declaration without a recorded signature contributes no arity bound.
        const arity: ExtArity = if (ds) |sig| .{
            .min = sig.arity.required,
            .max = if (sig.arity.has_vararg) std.math.maxInt(u32) else sig.arity.total,
        } else .{};
        if (self.funcTypeParamIndex(entry.id, head) != null or
            (head.len <= 2 and headAllUpper(head)))
        {
            try mergeExtArity(&gen, entry.name, arity);
            continue;
        }
        const gop = try idx.getOrPut(head);
        if (!gop.found_existing) gop.value_ptr.* = runtime.NameHashMap(ExtArity).init(allocator);
        try mergeExtArity(gop.value_ptr, entry.name, arity);
    }
    self.ext_names_by_recv_head = idx;
    self.generic_ext_names = gen;
    self.ext_index_decl_count = self.func_index.items.len;
}

/// The DIRECT child class named `name` of `owner`, with no enclosing-chain walk.
pub fn classDirectChild(self: *const Module, owner: ClassId, name: []const u8) ?ClassId {
    const cm = &(self.class_children orelse return null);
    if (cm.get(owner)) |kids| return kids.get(name);
    return null;
}

/// Resolve simple `name` against the nesting tree from `owner` outward through the lexical
/// parents, answering nested classes, objects and companions from the same FQNs.
pub fn classIdNestedIn(self: *const Module, owner: ClassId, name: []const u8) ?ClassId {
    const cm = &(self.class_children orelse return null);
    const pm = &(self.class_parent orelse return null);
    var cur: ?ClassId = owner;
    var hops: u8 = 0;
    while (cur) |cid| : (hops += 1) {
        if (hops > 16) break;
        if (cm.get(cid)) |kids| {
            if (kids.get(name)) |hit| return hit;
            // A companion's members are reachable without naming it.
            if (kids.get("Companion")) |comp| {
                if (cm.get(comp)) |ckids| {
                    if (ckids.get(name)) |hit| return hit;
                }
            }
        }
        cur = pm.get(cid);
    }
    return null;
}

/// Resolve a dotted qualifier (`Outer.Inner`) as a `.`-aligned suffix of a registered FQN, which a
/// simple-name lookup cannot disambiguate from a same-named class in scope. Shortest FQN wins.
pub fn classIdByQualifiedSuffix(self: *const Module, qualified: []const u8) ?ClassId {
    if (std.mem.findScalar(u8, qualified, '.') == null) return null;
    var best: ?ClassId = null;
    var best_len: usize = std.math.maxInt(usize);
    for (self.class_index.items) |entry| {
        const c = idGet(Class, self.classes.items, entry.id.int()) orelse continue;
        const fqn = c.fqn;
        if (!std.mem.endsWith(u8, fqn, qualified)) continue;
        // `.`-aligned so `X.Configuration` does not match `OtherX.Configuration`.
        const at = fqn.len - qualified.len;
        if (at != 0 and fqn[at - 1] != '.') continue;
        if (fqn.len < best_len) {
            best_len = fqn.len;
            best = entry.id;
        }
    }
    return best;
}

/// A `typealias` to a class is that class wherever a class name is expected. The alias resolves in
/// the reference's own scope, its file's imports then its package, never bare across packages.
pub fn aliasTargetClassHead(self: *const Module, name: []const u8, caller_pkg: []const u8, caller_file: FileId) ?[]const u8 {
    const shape: ModuleRegistry.TypeAliasShape = blk: {
        var imported: ?[]const u8 = null;
        for (self.importAliasPathsIn(caller_file, name)) |path| {
            if (!self.registry.type_alias_types.contains(path.fqn)) continue;
            if (imported != null and !std.mem.eql(u8, imported.?, path.fqn)) return null;
            imported = path.fqn;
        }
        if (imported) |path| break :blk self.registry.type_alias_types.get(path).?;
        if (caller_pkg.len != 0) {
            var buf: [512]u8 = undefined;
            const own = std.fmt.bufPrint(&buf, "{s}.{s}", .{ caller_pkg, name }) catch return null;
            if (self.registry.type_alias_types.get(own)) |s| break :blk s;
            return null;
        }
        // A default-package alias registers under its bare name, which is also its fqn.
        break :blk self.registry.type_alias_types.get(name) orelse return null;
    };
    if (self.registry.type_aliases.get(name)) |tag| {
        if (std.mem.startsWith(u8, tag, "Function")) return null;
    }
    const head = staticTypeHead(shape.target.name);
    if (std.mem.eql(u8, head, name)) return null;
    return head;
}

/// Resolve a class by simple name from the caller's scope, ranked by the bare-call tier order over
/// `Class.package` (named import, own package, wildcard, default, shipped, other); order breaks ties.
pub fn classIdIndexed(self: *const Module, name: []const u8, caller_pkg_in: []const u8, caller_file: FileId) ?ClassId {
    if (self.classNameCandidates(name) == null) {
        if (self.aliasTargetClassHead(name, self.packageOfFile(caller_file) orelse caller_pkg_in, caller_file)) |target| {
            return self.classIdIndexed(target, caller_pkg_in, caller_file);
        }
    }
    // Scope follows the FILE: a spliced inline body carries donor-file spans, so the
    // donor's package is the same-package tier for names its body wrote.
    const caller_pkg = self.packageOfFile(caller_file) orelse caller_pkg_in;
    var best: ?ClassId = null;
    var best_tier: u8 = 255;
    const cix_trace = blk: {
        const w = runtime.envOnce("KLIO_CIX_TRACE") orelse break :blk false;
        break :blk std.mem.eql(u8, w, name);
    };
    const name_imports = self.importAliasPathsIn(caller_file, name);
    if (self.classNameCandidates(name)) |ids| {
        for (ids) |cid| {
            const c = idGet(Class, self.classes.items, cid.int()) orelse continue;
            const t = self.scopeTierIn(c.fqn, c.package, caller_pkg, caller_file, name_imports);
            if (cix_trace) std.debug.print("[cix] {s} cand={d} fqn={s} pkg={s} tier={d} caller_pkg={s} file={d}\n", .{ name, cid.int(), c.fqn, c.package, t, caller_pkg, caller_file.int() });
            if (t < best_tier) {
                best_tier = t;
                best = cid;
            }
        }
        if (cix_trace) std.debug.print("[cix] {s} candidates-path best={?} tier={d}\n", .{ name, if (best) |b2| b2.int() else null, best_tier });
        if (best_tier > 3 and name_imports.len != 0) return null;
        return best;
    }
    if (cix_trace) std.debug.print("[cix] {s} NO candidate list (flat scan)\n", .{name});
    for (self.class_index.items) |entry| {
        if (!std.mem.eql(u8, entry.name, name)) continue;
        const c = idGet(Class, self.classes.items, entry.id.int()) orelse continue;
        const t = self.scopeTierIn(c.fqn, c.package, caller_pkg, caller_file, name_imports);
        if (t < best_tier) {
            best_tier = t;
            best = entry.id;
        }
    }
    // An OUT-OF-SCOPE winner under an explicit import of this name means an incomplete index
    // (cross-pack build order), not kotlinc's pick. Refuse, and let the runtime index decide.
    if (best_tier > 3 and self.importAliasPathsIn(caller_file, name).len != 0) return null;
    return best;
}

/// Rebuild `func_name_index` from the declaration-order `func_index`. Incremental writers
/// pair every `func_index` append with a name-index push, so the name index is always authoritative.
pub fn rebuildFuncNameIndex(self: *Module, allocator: Allocator) Allocator.Error!void {
    var it = self.func_name_index.valueIterator();
    while (it.next()) |list| list.deinit(allocator);
    self.func_name_index.clearRetainingCapacity();
    for (self.func_index.items) |entry| {
        const gop = try self.func_name_index.getOrPut(entry.name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(allocator, entry.id);
    }
}

/// All `FuncId`s under the given simple name, in declaration order; empty when none or unindexed.
pub fn funcsBySimpleName(self: *const Module, name: []const u8) []const FuncId {
    if (self.func_name_index.get(name)) |list| return list.items;
    return &.{};
}

/// First-wins order-based pick for a simple name over the name index, the single authority:
/// every build pipeline pairs a `func_index` append with a name-index push.
pub fn funcId(self: *const Module, name: []const u8) ?FuncId {
    const candidates = self.funcsBySimpleName(name);
    var first: ?FuncId = null;
    var first_user: ?FuncId = null;
    var first_body: ?FuncId = null;
    // A `@Deprecated(level = ERROR|HIDDEN)` or `@LowPriorityInOverloadResolution` overload is no
    // source-level candidate (a hidden form delegating by name self-recurses): last resort only.
    var first_lp: ?FuncId = null;
    for (candidates) |id| {
        if (self.funcById(id)) |f| {
            if (rankLowPriority(f)) {
                if (first_lp == null) first_lp = id;
                continue;
            }
        }
        if (first == null) first = id;
        if (self.funcById(id)) |f| {
            if (first_body == null and f.hasBody()) first_body = id;
            if (first_user != null) continue;
            if (!isShippedPackage(f.package)) first_user = id;
        }
    }
    // Prefer body over bodyless: a same-name `expect` must not hide its `actual`.
    return first_user orelse first_body orelse first orelse first_lp;
}

/// Whether any top-level function with this simple name exists, with no order-based pick.
pub fn hasFuncNamed(self: *const Module, name: []const u8) bool {
    return self.funcsBySimpleName(name).len != 0;
}

/// Look up a top-level function by fully-qualified name (`Func.fqn`), so a same-simple-name pack function cannot shadow it.
pub fn funcIdByFqn(self: *const Module, fqn: []const u8) ?FuncId {
    // Match by simple name through the name index, then confirm the fqn: only same-simple-name candidates decode.
    const simple = if (std.mem.findScalarLast(u8, fqn, '.')) |dot| fqn[dot + 1 ..] else fqn;
    for (self.funcsBySimpleName(simple)) |id| {
        const f = self.funcById(id) orelse continue;
        if (std.mem.eql(u8, f.fqn, fqn)) return id;
    }
    return null;
}

/// True when `head` is the first dotted segment of some declared top-level FQN, i.e. `head.` is a known
/// package prefix. FQN headers are complete after phase-1, so the answer ignores declaration order.
pub fn packageHeadDeclared(self: *const Module, head: []const u8) bool {
    if (head.len == 0) return false;
    if (self.class_id_map == null and !self.pkg_head_cache_dead) {
        if (self.lookup_cache_gpa != null) {
            const mut: *Module = @constCast(self);
            if (mut.topUpPkgHeads()) {
                return mut.pkg_head_cache.contains(head);
            } else |_| {}
        }
    }
    for (self.func_fqn_heads) |h| {
        if (std.mem.eql(u8, h, head)) return true;
    }
    for (self.funcs.items) |f| {
        if (fqnHasHeadSegment(f.fqn, head)) return true;
    }
    for (self.late_funcs.items) |f| {
        if (fqnHasHeadSegment(f.fqn, head)) return true;
    }
    for (self.classes.items) |c| {
        if (fqnHasHeadSegment(c.fqn, head)) return true;
    }
    return false;
}

/// Top up `pkg_head_cache`; prefix inserts are idempotent, so a partial OOM only leaves the counters short.
pub fn topUpPkgHeads(self: *Module) Allocator.Error!void {
    const gpa = self.lookup_cache_gpa.?;
    if (!self.pkg_head_heads_done) {
        for (self.func_fqn_heads) |h| try self.pkg_head_cache.put(gpa, h, {});
        self.pkg_head_heads_done = true;
    }
    while (self.pkg_head_funcs_n < self.appendedFuncCount()) : (self.pkg_head_funcs_n += 1) {
        const n = self.pkg_head_funcs_n;
        const fqn = if (n < self.funcs.items.len) self.funcs.items[n].fqn else self.late_funcs.items[n - self.funcs.items.len].fqn;
        try insertFqnPrefixes(&self.pkg_head_cache, gpa, fqn);
    }
    while (self.pkg_head_classes_n < self.classes.items.len) : (self.pkg_head_classes_n += 1) {
        try insertFqnPrefixes(&self.pkg_head_cache, gpa, self.classes.items[self.pkg_head_classes_n].fqn);
    }
}

/// The declared package of source file `file`; a spliced inline body carries donor-file spans.
pub fn packageOfFile(self: *const Module, file: FileId) ?[]const u8 {
    return self.registry.file_packages.get(file);
}

/// Every non-wildcard import in `file` binding leaf `name`, in declaration order. Kotlin keeps
/// every such import in scope, so an identical-signature pair behind two same-leaf imports is
/// an ambiguity, never a shadow.

pub fn importAliasPathsIn(self: *const Module, file: FileId, name: []const u8) []const ModuleRegistry.ImportPath {
    // The file's bloom answers first: it is keyed by file id and the bit comes
    // from the name's length and ends, so a name the file never imports costs
    // no string hash at all.
    const bloom = self.registry.import_alias_bloom.get(file) orelse return &.{};
    if ((bloom & ModuleRegistry.importAliasBit(name)) == 0) return &.{};
    const m = self.registry.import_aliases.get(file) orelse return &.{};
    if (m.get(name)) |paths| return paths.items;
    return &.{};
}

/// Register a class declaration and return its id, reusing any slot and id `reserveClass` reserved for the name.
pub fn addClass(self: *Module, allocator: Allocator, class_in: Class) Allocator.Error!ClassId {
    var class = class_in;
    // Claim the reserved stub or a prior lowering by FULLY-QUALIFIED name, so two same-simple-name
    // classes in different packages keep their own slots. A stub reserved without an FQN carries
    // `fqn == name` and is claimed only when no exact-FQN slot exists.
    if (self.classIndexEntryByName(class.name) != null) {
        var legacy_stub: ?ClassId = null;
        if (self.classNameCandidates(class.name)) |ids| {
            for (ids) |cid| {
                const existing = &self.classes.items[cid.int()];
                if (std.mem.eql(u8, existing.fqn, class.fqn)) {
                    class.is_object = class.is_object or existing.is_object;
                    class.id = cid;
                    self.classes.items[cid.int()] = class;
                    return cid;
                }
                if (legacy_stub == null and existing.is_stub and std.mem.eql(u8, existing.fqn, class.name)) {
                    legacy_stub = cid;
                }
            }
        } else for (self.class_index.items) |entry| {
            if (!std.mem.eql(u8, entry.name, class.name)) continue;
            const existing = &self.classes.items[entry.id.int()];
            if (std.mem.eql(u8, existing.fqn, class.fqn)) {
                class.is_object = class.is_object or existing.is_object;
                class.id = entry.id;
                self.classes.items[entry.id.int()] = class;
                return entry.id;
            }
            if (legacy_stub == null and existing.is_stub and std.mem.eql(u8, existing.fqn, class.name)) {
                legacy_stub = entry.id;
            }
        }
        if (legacy_stub) |id| {
            class.is_object = class.is_object or self.classes.items[id.int()].is_object;
            class.id = id;
            self.classes.items[id.int()] = class;
            self.fixupStubClaimCaches(id, class.name, class.fqn);
            return id;
        }
    }
    const id = ClassId.from(@intCast(self.classes.items.len));
    class.id = id;
    try self.class_index.append(allocator, .{ .name = class.name, .id = id });
    if (runtime.envOnce("KLIO_CIDX_TRACE")) |w| {
        if (std.mem.find(u8, class.name, w) != null) std.debug.print("[cidx] name={s} id={d}\n", .{ class.name, id.int() });
    }
    try self.classes.append(allocator, class);
    return id;
}

pub fn classIndexEntryByName(self: *const Module, name: []const u8) ?ClassId {
    if (self.classNameCandidates(name)) |ids| {
        return if (ids.len == 0) null else ids[0];
    }
    for (self.class_index.items) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.id;
    }
    return null;
}

/// Sentinel in `class_fqn_map` for a duplicated FQN: the lookup returns null, so an
/// ambiguous FQN never silently binds the wrong class.
pub const class_id_ambiguous: ClassId = @enumFromInt(std.math.maxInt(u32));

pub const SimpleNameInfo = struct { id: ClassId, non_kotlin: bool };

pub fn classFqnById(self: *const Module, id: ClassId) ?[]const u8 {
    const c = idGet(Class, self.classes.items, id.int()) orelse return null;
    return c.fqn;
}

pub const cid_memo_slots = 64;

/// `classIdByFqn` through the pointer-identity memo on `cid_memo_keys` (see the field docs).
/// ONLY for static, content-stable `fqn` slices.
pub fn classIdByStaticFqn(self: *const Module, fqn: []const u8) ?ClassId {
    const key = @intFromPtr(fqn.ptr);
    const h = (key >> 4) & (cid_memo_slots - 1);
    if (self.cid_memo_keys[h].load(.monotonic) == key) {
        const v = self.cid_memo_vals[h].load(.acquire);
        if (v == 1) return null;
        if (v >= 2) return ClassId.from(@intCast(v - 2));
    }
    const answer = self.classIdByFqn(fqn);
    const mut = @constCast(self);
    if (mut.cid_memo_keys[h].cmpxchgStrong(0, key, .acq_rel, .monotonic) == null) {
        mut.cid_memo_vals[h].store(if (answer) |a| @as(u64, a.int()) + 2 else 1, .release);
    }
    return answer;
}

/// Resolve a class by fully-qualified name, separating same-simple-name classes from different packages.
pub fn classIdByFqn(self: *const Module, fqn: []const u8) ?ClassId {
    if (self.class_fqn_map) |*m| {
        const id = m.get(fqn) orelse return null;
        return if (id == class_id_ambiguous) null else id;
    }
    if (self.classFqnCacheLive()) {
        const mut: *Module = @constCast(self);
        if (mut.topUpClassFqnCache()) {
            const id = mut.class_fqn_cache.get(fqn) orelse return null;
            return if (id == class_id_ambiguous) null else id;
        } else |_| {}
    }
    // Only resolve an unambiguous FQN; a residual collision must not bind the wrong class.
    var found: ?ClassId = null;
    for (self.classes.items) |c| {
        if (!std.mem.eql(u8, c.fqn, fqn)) continue;
        if (found != null) return null;
        found = c.id;
    }
    return found;
}

pub fn classFqnCacheLive(self: *const Module) bool {
    return self.class_fqn_map == null and !self.class_fqn_cache_dead and
        self.lookup_cache_gpa != null;
}

pub fn topUpClassFqnCache(self: *Module) Allocator.Error!void {
    const gpa = self.lookup_cache_gpa.?;
    while (self.class_fqn_cache_n < self.classes.items.len) : (self.class_fqn_cache_n += 1) {
        const c = self.classes.items[self.class_fqn_cache_n];
        const gop = try self.class_fqn_cache.getOrPut(gpa, c.fqn);
        if (gop.found_existing) {
            if (gop.value_ptr.* != c.id) gop.value_ptr.* = class_id_ambiguous;
        } else gop.value_ptr.* = c.id;
    }
}

/// Patch the lookup caches after `addClass` claims a reserved stub, the one place a slot's FQN changes:
/// the FQN map swaps the stub key (killing the cache if that key was already ambiguous) and heads grow.
pub fn fixupStubClaimCaches(self: *Module, id: ClassId, stub_fqn: []const u8, new_fqn: []const u8) void {
    if (std.mem.eql(u8, stub_fqn, new_fqn)) return;
    const gpa = self.lookup_cache_gpa orelse return;
    if (!self.class_fqn_cache_dead and id.int() < self.class_fqn_cache_n) {
        var dead = false;
        if (self.class_fqn_cache.get(stub_fqn)) |old| {
            if (old == id) {
                _ = self.class_fqn_cache.remove(stub_fqn);
            } else if (old == class_id_ambiguous) {
                dead = true;
            }
        }
        if (!dead) {
            if (self.class_fqn_cache.getOrPut(gpa, new_fqn)) |gop| {
                if (gop.found_existing) {
                    if (gop.value_ptr.* != id) gop.value_ptr.* = class_id_ambiguous;
                } else gop.value_ptr.* = id;
            } else |_| dead = true;
        }
        if (dead) {
            self.class_fqn_cache.clearRetainingCapacity();
            self.class_fqn_cache_n = 0;
            self.class_fqn_cache_dead = true;
        }
    }
    if (!self.pkg_head_cache_dead and id.int() < self.pkg_head_classes_n) {
        insertFqnPrefixes(&self.pkg_head_cache, gpa, new_fqn) catch {
            self.pkg_head_cache_dead = true;
        };
    }
    if (id.int() < self.unique_simple_cache_n) {
        self.unique_simple_cache.clearRetainingCapacity();
        self.unique_simple_cache_n = 0;
    }
}

/// Whether `sub` is `super_name` or transitively extends/implements it over the simple-name hierarchy in
/// `registry.class_super_names`. Receiver applicability: an extension on a base accepts a subclass.
pub fn classIsOrExtends(self: *const Module, sub: []const u8, super_name: []const u8) bool {
    if (std.mem.eql(u8, sub, super_name)) return true;
    const sub_id = if (std.mem.findScalar(u8, sub, '.') != null)
        self.classIdByFqn(sub)
    else
        self.uniqueClassIdBySimpleName(staticTypeHead(sub));
    // A row-less sub with a registered name chain answers through it even when the super
    // resolves to a class id.
    if (sub_id == null) {
        if (self.registry.class_super_names.get(staticTypeHead(sub))) |supers| {
            const sup_simple = applicability.simpleName(staticTypeHead(super_name));
            for (supers) |s2| {
                if (std.mem.eql(u8, applicability.simpleName(staticTypeHead(s2)), sup_simple)) return true;
            }
        }
    }
    const super_id = if (std.mem.findScalar(u8, super_name, '.') != null)
        self.classIdByFqn(super_name)
    else
        self.uniqueClassIdBySimpleName(staticTypeHead(super_name));
    if (sub_id != null or super_id != null) {
        return sub_id != null and super_id != null and
            self.classIdIsOrExtends(sub_id.?, super_id.?);
    }
    if (std.mem.findScalar(u8, sub, '.') != null or
        std.mem.findScalar(u8, super_name, '.') != null) return false;
    const supers = self.registry.class_super_names.get(sub) orelse return false;
    for (supers) |s| {
        if (std.mem.eql(u8, s, super_name)) return true;
    }
    return false;
}

/// Pre-register a class name so `classId` resolves it before its body lowers; `addClass` overwrites the
/// placeholder. `is_inner` is stamped on the stub so a bare `Inner()` captures right whatever the order.
pub fn reserveClass(self: *Module, allocator: Allocator, name: []const u8, is_inner: bool) Allocator.Error!ClassId {
    if (self.classIndexEntryByName(name)) |id| return id;
    const id = ClassId.from(@intCast(self.classes.items.len));
    try self.class_index.append(allocator, .{ .name = name, .id = id });
    if (runtime.envOnce("KLIO_CIDX_TRACE")) |w| {
        if (std.mem.find(u8, name, w) != null) std.debug.print("[cidx] name={s} id={d}\n", .{ name, id.int() });
    }
    try self.classes.append(allocator, .{
        .id = id,
        .name = name,
        .fqn = name,
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
        .is_inner = is_inner,
        .is_stub = true,
    });
    return id;
}

/// Append a constant and return its id; the pool is unsorted and not unique by structural equality.
/// String consts are OWNED: the bytes are duped into `allocator` and freed by `Module.deinit`.
pub fn internConst(self: *Module, allocator: Allocator, c: Const) Allocator.Error!ConstId {
    // Hash-keyed dedup over the append-only pool: the first id with a given hash wins the
    // slot (matching the scan's first match), and a colliding value falls back to the scan.
    if (self.topUpConstDedup(allocator)) {
        const h = constHash(c);
        if (self.const_dedup.get(h)) |id| {
            if (Const.eql(self.consts.items[id.int()], c)) return id;
        } else {
            const id = ConstId.from(@intCast(self.consts.items.len));
            try self.consts.ensureUnusedCapacity(allocator, 1);
            const owned: Const = switch (c) {
                .String => |s| .{ .String = try allocator.dupe(u8, s) },
                else => c,
            };
            self.consts.appendAssumeCapacity(owned);
            self.const_dedup_n = self.consts.items.len;
            try self.const_dedup.put(allocator, h, id);
            return id;
        }
    } else |_| {}
    for (self.consts.items, 0..) |k, i| {
        if (Const.eql(k, c)) return ConstId.from(@intCast(i));
    }
    const id = ConstId.from(@intCast(self.consts.items.len));
    try self.consts.ensureUnusedCapacity(allocator, 1);
    const owned: Const = switch (c) {
        .String => |s| .{ .String = try allocator.dupe(u8, s) },
        else => c,
    };
    self.consts.appendAssumeCapacity(owned);
    return id;
}

pub fn topUpConstDedup(self: *Module, gpa: Allocator) Allocator.Error!void {
    while (self.const_dedup_n < self.consts.items.len) : (self.const_dedup_n += 1) {
        const h = constHash(self.consts.items[self.const_dedup_n]);
        const gop = try self.const_dedup.getOrPut(gpa, h);
        if (!gop.found_existing) gop.value_ptr.* = ConstId.from(@intCast(self.const_dedup_n));
    }
}
