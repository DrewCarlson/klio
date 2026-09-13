//! Declared Kotlin classes at runtime: `ClassDef` and its descriptors, the
//! live `InstanceData`, and the method and property resolution walks.

const std = @import("std");
const ast = @import("ast");
const span = @import("span");
const objcell = @import("objcell.zig");
const env_mod = @import("env.zig");
const value_mod = @import("value.zig");
const forest = @import("forest.zig");

const ObjRef = objcell.ObjRef;
const Env = env_mod.Env;
const Value = value_mod.Value;

/// Storage order is outermost first, innermost last.
pub const ImplicitReceiver = struct {
    v: Value,
    kind: Kind = .receiver,

    pub const Kind = enum { receiver, subject, access };

    pub fn isSubject(self: ImplicitReceiver) bool {
        return self.kind == .subject;
    }
};

pub const ClassDef = struct {
    /// Immutable after two-phase linking backpatches `parent`, `interfaces` and
    /// `enum_entries` at single-threaded startup. The one later write, an enum
    /// installing its constructed entries, runs under the enum's initialization
    /// claim, and nothing else takes an exclusive borrow, so the reader lock is
    /// elided.
    pub const objref_immutable = true;

    name: []const u8,
    fqn: []const u8,
    annotation_names: []const []const u8,
    annotation_records: []const AnnotationRecord = &.{},
    type_params: []const []const u8 = &.{},
    /// Parallel to `type_params`: each declared upper bound's simple head.
    type_param_bounds: []const []const u8 = &.{},
    primary_params: []ClassParamDef,
    methods: []MethodDef,
    /// Body properties, not primary-constructor ones.
    body_properties: []PropertyDef,
    init_blocks: []const forest.ForestField(ast.Block),
    /// For each `init_blocks` entry, the `body_properties` index it runs
    /// before: Kotlin's source-order initialization rule.
    init_block_property_positions: []usize,
    is_data: bool,
    is_value: bool,
    is_object: bool,
    is_enum: bool,
    has_primary_ctor: bool = true,
    is_annotation: bool = false,
    is_sealed: bool,
    supertype_names: []const []const u8,
    /// Parallel to `supertype_names`: the dotted source qualifier when one was
    /// written qualified. Parent resolution uses it to tell a nested base from a
    /// same-simple-name class in scope.
    supertype_paths: []const ?[]const u8 = &.{},
    /// Backpatched once during linking, then immutable and read lock-free.
    parent: ?ObjRef(ClassDef),
    interfaces: []const ObjRef(ClassDef),
    is_interface: bool,
    is_fun_interface: bool,
    parent_ctor_args: []const forest.ForestField(ast.Expr),
    is_open: bool,
    is_abstract: bool,
    is_inner: bool,
    is_anonymous: bool,
    secondary_ctors: []const forest.ForestField(ast.SecondaryCtor),
    /// Linking fills the table with one shell per entry; the enum's first use
    /// constructs them in place.
    enum_entries: []const EnumEntry,
    /// 0 = not started, 1 = in progress, 2 = entries and companion ready.
    enum_init_state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    companion: ObjRef(?ObjRef(InstanceData)),
    enclosing_class: ObjRef(?ObjRef(ClassDef)),
    nested_classes: []const NestedClass,
    captured_env: ObjRef(Env),
    supertype_delegates: []const SupertypeDelegate,
    delegate_forwarders: []const MethodDef,
    object_singleton: ObjRef(?ObjRef(InstanceData)),
    /// Synthesized at runtime from a class declaration inside a function body.
    /// Such a def is the class itself: a constructor call on its `.Class` value
    /// must never be redirected through the module class index, where an
    /// unrelated same-simple-name class can shadow it.
    is_local_runtime: bool = false,
    /// The scope a runtime-local declaration captured. One registration is one
    /// scope, so an instance keeps the scope it was declared in.
    local_captures: []const InstanceData.Capture = &.{},
    /// The implicit receivers where a runtime-local declaration ran; its member
    /// bodies resolve bare names against them.
    local_enclosing: []const ImplicitReceiver = &.{},

    /// Memo for the constructor chain's first non-interface supertype.
    /// 0 = uncomputed, 1 = none, 2 = filled with `first_super_index` and
    /// `first_super_fqn`, null for a builtin parent.
    first_super_state: u8 = 0,
    first_super_index: u8 = 0,
    first_super_fqn: ?[]const u8 = null,

    /// Memo for the ir-module `ClassId` this class resolves to, so virtual
    /// dispatch skips the string-keyed probe. `resolve_mod` is claimed by the
    /// first resolving module's pointer identity, and `resolve_cid`, the id plus
    /// 1, is the validity gate; another module keeps the slow path.
    resolve_mod: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    resolve_cid: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Memo for the `<class-companion-or-self>` read: 0 = unresolved, 1 = the
    /// class value itself, 2 = `companion_read_value`, a borrowed copy of a
    /// process-stable singleton the shared registry keeps alive.
    companion_read_state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    companion_read_value: Value = .Null,

    pub const EnumEntry = struct {
        name: []const u8,
        value: Value,
        annotation_records: []const AnnotationRecord = &.{},
    };
    pub const NestedClass = struct { name: []const u8, class: ObjRef(ClassDef) };

    pub const MAX_WALK = 128;

    /// Method, property and init bodies are AST-backed and hold no Value
    /// cells.
    pub fn gcTrace(self: *const ClassDef, m: *objcell.gc.Marker) void {
        if (self.parent) |p| m.shade(&p.cell.hdr);
        for (self.interfaces) |i| m.shade(&i.cell.hdr);
        for (self.nested_classes) |nc| m.shade(&nc.class.cell.hdr);
        for (self.enum_entries) |e| e.value.gcMark(m);
        for (self.supertype_delegates) |d| if (d.interface) |i| m.shade(&i.cell.hdr);
        m.shade(&self.companion.cell.hdr);
        m.shade(&self.enclosing_class.cell.hdr);
        m.shade(&self.captured_env.cell.hdr);
        m.shade(&self.object_singleton.cell.hdr);
        for (self.local_captures) |c| c.value.gcMark(m);
        for (self.local_enclosing) |e| e.v.gcMark(m);
    }

    /// Walks self, then parent. The handles are clones the caller owns.
    pub fn findMethod(self: ObjRef(ClassDef), allocator: std.mem.Allocator, name: []const u8) ?MethodHit {
        var seen: std.ArrayList(*const ClassDef) = .empty;
        defer seen.deinit(allocator);
        return findMethodWalk(allocator, self, name, &seen);
    }

    pub fn findMethodForArg(
        self: ObjRef(ClassDef),
        allocator: std.mem.Allocator,
        name: []const u8,
        arg_type_name: ?[]const u8,
    ) ?MethodHit {
        if (arg_type_name) |arg| {
            var seen: std.ArrayList(*const ClassDef) = .empty;
            defer seen.deinit(allocator);
            if (findMethodForArgWalk(allocator, self, name, arg, &seen)) |found| {
                return found;
            }
        }
        return findMethod(self, allocator, name);
    }

    pub fn findBodyProperty(self: ObjRef(ClassDef), allocator: std.mem.Allocator, name: []const u8) ?PropertyHit {
        var seen: std.ArrayList(*const ClassDef) = .empty;
        defer seen.deinit(allocator);
        return findBodyPropertyWalk(allocator, self, name, &seen);
    }

    /// The caller owns the slice.
    pub fn interfaceRefs(self: *const ClassDef, allocator: std.mem.Allocator) ![]ObjRef(ClassDef) {
        return allocator.dupe(ObjRef(ClassDef), self.interfaces);
    }

    /// The caller owns the slice.
    pub fn allCompanions(self: ObjRef(ClassDef), allocator: std.mem.Allocator) ![]ObjRef(InstanceData) {
        var out: std.ArrayList(ObjRef(InstanceData)) = .empty;
        errdefer out.deinit(allocator);
        var seen: std.ArrayList(*const ClassDef) = .empty;
        defer seen.deinit(allocator);
        try collectCompanionsWalk(allocator, self, &out, &seen);
        return out.toOwnedSlice(allocator);
    }

    /// Matches the class or any named supertype.
    pub fn isSubtypeOf(self: *const ClassDef, allocator: std.mem.Allocator, name: []const u8) bool {
        if (std.mem.eql(u8, self.name, name) or std.mem.eql(u8, self.fqn, name)) {
            return true;
        }
        var frontier: std.ArrayList([]const u8) = .empty;
        defer frontier.deinit(allocator);
        var seen: std.ArrayList([]const u8) = .empty;
        defer seen.deinit(allocator);
        for (self.supertype_names) |n| frontier.append(allocator, n) catch return false;
        seen.append(allocator, self.name) catch return false;
        var steps: usize = 0;
        while (frontier.pop()) |parent_name| {
            if (steps > 64) return false;
            steps += 1;
            if (std.mem.eql(u8, parent_name, name)) return true;
            if (containsStr(seen.items, parent_name)) continue;
            seen.append(allocator, parent_name) catch return false;
            const g = self.captured_env.borrow();
            defer g.deinit();
            const v = g.get().lookup(parent_name) orelse continue;
            switch (v) {
                .Class => |c| {
                    const cg = c.borrow();
                    defer cg.deinit();
                    const cd = cg.get();
                    if (std.mem.eql(u8, cd.name, name) or std.mem.eql(u8, cd.fqn, name)) return true;
                    for (cd.supertype_names) |p| frontier.append(allocator, p) catch return false;
                },
                else => {},
            }
        }
        return false;
    }
};

pub const MethodHit = struct { method: MethodDef, class: ObjRef(ClassDef) };
pub const PropertyHit = struct { property: PropertyDef, class: ObjRef(ClassDef) };

pub const SupertypeDelegate = struct {
    interface_name: []const u8,
    /// Null when it does not resolve at registration time.
    interface: ?ObjRef(ClassDef),
    /// Evaluated in the primary constructor's parameter scope.
    expr: forest.ForestField(ast.Expr),
    field_key: []const u8,
};

pub const ClassParamDef = struct {
    /// `true` for `var`, `false` for `val`, null if not a property.
    property: ?bool,
    name: []const u8,
    default: ?forest.ForestField(ast.Expr),
    declared_type: ?[]const u8,
    declared_shape: ?TypeShape,
    anchors: PropertyAnchors = .{},
};

/// Retained at runtime so reflection can read annotation values.
pub const AnnotationArg = union(enum) {
    Str: []const u8,
    Int: i64,
    Bool: bool,
    /// `AnnotationTarget.PROPERTY` records `"PROPERTY"`.
    EnumEntry: []const u8,
    /// `@Serializer(forClass = Foo::class)` records `"Foo"`.
    ClassRef: []const u8,
    Other,
};

pub const AnnotationRecord = struct {
    /// Import-expanded, always ending with the source spelling.
    names: []const []const u8,
    args: []const AnnotationArg = &.{},
    arg_names: []const ?[]const u8 = &.{},

    pub fn is(self: *const AnnotationRecord, name: []const u8) bool {
        for (self.names) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }

    /// Falls back to the first positional string when none are named.
    pub fn stringArg(self: *const AnnotationRecord, param: []const u8) ?[]const u8 {
        for (self.args, 0..) |arg, i| {
            if (arg != .Str) continue;
            const nm: ?[]const u8 = if (i < self.arg_names.len) self.arg_names[i] else null;
            if (nm == null or std.mem.eql(u8, nm.?, param)) return arg.Str;
        }
        return null;
    }
};

/// After use-site target assignment. Arena-owned and immutable.
pub const PropertyAnchors = struct {
    param: []const AnnotationRecord = &.{},
    property: []const AnnotationRecord = &.{},
    field: []const AnnotationRecord = &.{},
    get: []const AnnotationRecord = &.{},
    set: []const AnnotationRecord = &.{},
    setparam: []const AnnotationRecord = &.{},
    delegate: []const AnnotationRecord = &.{},

    pub fn propertyRecord(self: *const PropertyAnchors, name: []const u8) ?*const AnnotationRecord {
        for (self.property) |*rec| {
            if (rec.is(name)) return rec;
        }
        return null;
    }
};

pub const TypeShape = struct {
    name: []const u8,
    nullable: bool,
    args: []TypeShape,

    /// Skips star projections. The caller's allocator owns `args`.
    pub fn fromTypeRef(allocator: std.mem.Allocator, t: *const ast.TypeRef) std.mem.Allocator.Error!TypeShape {
        var args: std.ArrayList(TypeShape) = .empty;
        errdefer args.deinit(allocator);
        for (t.type_args) |a| {
            if (a.is_star) continue;
            try args.append(allocator, try fromTypeRef(allocator, &a.ty));
        }
        return .{
            .name = t.name.name,
            .nullable = t.nullable,
            .args = try args.toOwnedSlice(allocator),
        };
    }
};

pub const MethodDef = struct {
    name: []const u8,
    /// Eager as `.ptr` or lazily image-backed as `.ref`.
    decl: forest.ForestField(ast.Function),
    is_operator: bool,
    is_open: bool,
    is_override: bool,
    is_abstract: bool,
    sam_lambda: ?Value,
    /// A delegation forwarder routes calls to the delegate instance under this
    /// field key.
    delegate_field: ?[]const u8,
    ir_fn_id: ?u32,
    annotation_names: []const []const u8 = &.{},
};

pub const PropertyDef = struct {
    name: []const u8,
    mutable: bool,
    /// A loaded image never reads these; the lowered side-tables come from the
    /// built program.
    init: ?forest.ForestField(ast.Expr),
    getter: ?forest.ForestField(ast.Accessor),
    setter: ?forest.ForestField(ast.Accessor),
    delegate: ?forest.ForestField(ast.Expr),
    is_abstract: bool,
    is_lateinit: bool,
    /// For a declared non-nullable primitive with no initializer.
    primitive_zero: ?Value,
    anchors: PropertyAnchors = .{},
    /// By kotlinc's rule: an initializer, a defaulted accessor, or one reading
    /// `field`. Serialization treats exactly these as elements.
    has_backing: bool = true,
    /// Null for an inferred type, where consumers use the dynamic descriptor.
    type_head: ?[]const u8 = null,
    /// The type is a non-nullable scalar, so a read of the stored field can
    /// never produce null. `type_head` keeps only the head, so `Int?` and `Int`
    /// both read as "Int", and the JIT needs the distinction.
    scalar_nn: bool = false,
};

/// Interned instance-layout identity. Two instances share a shape id iff their
/// field lists hold the same name pointers in the same order; field names are
/// canonicalized program-lifetime strings, so a matching id proves "field
/// `name` is at index i" without reading a name. Ids are addresses in a
/// program-lifetime arena bounded by `shape_cap`, past which layouts degrade to
/// the unshaped sentinel.
pub const SHAPE_UNSET: usize = 0;
pub const SHAPE_NONE: usize = 1;

const ShapeRec = struct {
    /// Hashed on both, compared on the pointers: an identical pointer vector is
    /// an identical layout.
    ptrs: [][*]const u8,
    lens: []u32,
};

/// Held only for the intern-table probe on a shape miss.
const ShapeLock = struct {
    state: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    fn lock(self: *ShapeLock) void {
        while (self.state.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *ShapeLock) void {
        self.state.store(false, .release);
    }
};
var shape_lock: ShapeLock = .{};
var shape_table: std.HashMapUnmanaged(u64, std.ArrayListUnmanaged(*ShapeRec), std.hash_map.AutoContext(u64), 80) = .empty;
var shape_count: usize = 0;
const shape_cap: usize = 1 << 16;
var shape_arena_state: ?std.heap.ArenaAllocator = null;

fn shapeHash(fields: []const InstanceData.Field) u64 {
    var h = std.hash.Wyhash.init(0x5a5a);
    for (fields) |f| {
        h.update(std.mem.asBytes(&f.name.ptr));
        h.update(std.mem.asBytes(&f.name.len));
    }
    return h.final();
}

fn shapeMatches(rec: *const ShapeRec, fields: []const InstanceData.Field) bool {
    if (rec.ptrs.len != fields.len) return false;
    for (rec.ptrs, fields) |p, f| {
        if (p != f.name.ptr) return false;
    }
    return true;
}

/// Never SHAPE_UNSET; SHAPE_NONE once the table is at capacity.
fn internShape(fields: []const InstanceData.Field) usize {
    const h = shapeHash(fields);
    shape_lock.lock();
    defer shape_lock.unlock();
    const arena = blk: {
        if (shape_arena_state == null)
            shape_arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        break :blk shape_arena_state.?.allocator();
    };
    const gop = shape_table.getOrPut(std.heap.page_allocator, h) catch return SHAPE_NONE;
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    for (gop.value_ptr.items) |rec| {
        if (shapeMatches(rec, fields)) return @intFromPtr(rec);
    }
    if (shape_count >= shape_cap) return SHAPE_NONE;
    const rec = arena.create(ShapeRec) catch return SHAPE_NONE;
    const ptrs = arena.alloc([*]const u8, fields.len) catch return SHAPE_NONE;
    const lens = arena.alloc(u32, fields.len) catch return SHAPE_NONE;
    for (fields, 0..) |f, i| {
        ptrs[i] = f.name.ptr;
        lens[i] = @intCast(f.name.len);
    }
    rec.* = .{ .ptrs = ptrs, .lens = lens };
    gop.value_ptr.append(std.heap.page_allocator, rec) catch return SHAPE_NONE;
    shape_count += 1;
    return @intFromPtr(rec);
}

pub const InstanceData = struct {
    class: ObjRef(ClassDef),
    fields: std.ArrayList(Field),
    /// `SHAPE_UNSET` until computed, reset by any field append. Racing fillers
    /// compute the same id.
    shape: std.atomic.Value(usize) = std.atomic.Value(usize).init(SHAPE_UNSET),
    outer: ?Value,
    identity: u64,
    native_state: ?NativeState,
    /// `fields` points into a baked image's arena, so growing or freeing it
    /// with the runtime allocator would cross allocators. The first growth
    /// re-buffers and clears this, and teardown skips the arena-owned spine.
    fields_foreign: bool = false,
    /// For an anonymous-object instance, the values it captured, seeding the
    /// method-body env at dispatch. Held per instance, so they are reclaimed
    /// with it; names are borrowed, the slice and values owned.
    anon_captures: []Capture = &.{},
    /// Lexical implicit receivers where the anonymous-object expression was
    /// created, so nested receiver lambdas do not hide an outer receiver.
    anon_enclosing: []ImplicitReceiver = &.{},
    /// For a user `Throwable` subclass, the stack captured at the first throw.
    stack: ?value_mod.StackRef = null,

    pub const Field = struct { name: []const u8, value: Value };
    pub const Capture = struct { name: []const u8, value: Value };

    pub fn get(self: *const InstanceData, name: []const u8) ?Value {
        for (self.fields.items) |f| {
            // Field names are canonicalized program-lifetime strings, so an
            // identical pointer is an identical name; `eql` covers a name that
            // bypassed canonicalization.
            if (f.name.ptr == name.ptr or std.mem.eql(u8, f.name, name)) return f.value;
        }
        return null;
    }

    /// An instance's class is written once at construction, so a dispatch key
    /// needing only that pointer pays no atomics.
    pub fn classIdentityUnlocked(inst: objcell.ObjRef(InstanceData)) usize {
        return inst.asPtrConst().class.identity();
    }

    /// For a non-interned literal name, where the pointer fast path can never
    /// hit. The caller passes a per-name cache slot the first hit fills.
    pub fn getCached(self: *const InstanceData, slot: *std.atomic.Value(?[*]const u8), name: []const u8) ?Value {
        if (slot.load(.monotonic)) |p| {
            for (self.fields.items) |f| {
                if (f.name.ptr == p) return f.value;
            }
        }
        for (self.fields.items) |f| {
            if (std.mem.eql(u8, f.name, name)) {
                slot.store(f.name.ptr, .monotonic);
                return f.value;
            }
        }
        return null;
    }

    pub fn set(self: *InstanceData, name: []const u8, v: Value) bool {
        for (self.fields.items) |*f| {
            if (f.name.ptr == name.ptr or std.mem.eql(u8, f.name, name)) {
                f.value = v;
                return true;
            }
        }
        return false;
    }

    /// Adopts one owned reference to `v`; a caller passing an alias retains
    /// first. A replaced value is released, so the instance owns exactly one
    /// reference per field.
    pub fn define(self: *InstanceData, allocator: std.mem.Allocator, name: []const u8, v: Value) !void {
        for (self.fields.items) |*f| {
            if (f.name.ptr == name.ptr or std.mem.eql(u8, f.name, name)) {
                if (objcell.reclaimEnabled()) f.value.release(allocator);
                f.value = v;
                return;
            }
        }
        try self.ensureFieldsOwned(allocator, 1);
        try self.fields.append(allocator, .{ .name = name, .value = v });
        // The layout changed, so the memoized shape id no longer describes it.
        self.shape.store(SHAPE_UNSET, .release);
    }

    /// Any out-of-band field-list mutation must drop the memoized layout id.
    pub fn invalidateShape(self: *InstanceData) void {
        self.shape.store(SHAPE_UNSET, .release);
    }

    /// The caller must hold a borrow: the field list must not grow mid-read.
    pub fn shapeOf(self: *const InstanceData) usize {
        const cached = self.shape.load(.acquire);
        if (cached != SHAPE_UNSET) return cached;
        const id = internShape(self.fields.items);
        @constCast(self).shape.store(id, .release);
        return id;
    }

    /// The arena keeps the original buffer.
    pub fn ensureFieldsOwned(self: *InstanceData, allocator: std.mem.Allocator, extra: usize) !void {
        if (!self.fields_foreign) return;
        var fresh: std.ArrayList(Field) = .empty;
        try fresh.ensureTotalCapacity(allocator, self.fields.items.len + extra);
        fresh.appendSliceAssumeCapacity(self.fields.items);
        self.fields = fresh;
        self.fields_foreign = false;
    }

    /// The module keeps the class alive, so this drops only the instance's own
    /// clone; `native_state` belongs to its host binding.
    pub fn deinit(self: *InstanceData, allocator: std.mem.Allocator) void {
        for (self.fields.items) |f| f.value.release(allocator);
        if (self.outer) |o| o.release(allocator);
        for (self.anon_captures) |c| c.value.release(allocator);
        if (self.anon_captures.len != 0) allocator.free(self.anon_captures);
        for (self.anon_enclosing) |e| e.v.release(allocator);
        if (self.anon_enclosing.len != 0) allocator.free(self.anon_enclosing);
        if (self.stack) |*s| s.deinit();
        if (!self.fields_foreign) self.fields.deinit(allocator);
        self.class.deinit();
    }

    /// The class cell, one reference per field, and an inner class's outer.
    pub fn gcTrace(self: *const InstanceData, m: *objcell.gc.Marker) void {
        m.shade(&self.class.cell.hdr);
        for (self.fields.items) |f| f.value.gcMark(m);
        if (self.outer) |o| o.gcMark(m);
        for (self.anon_captures) |c| c.value.gcMark(m);
        for (self.anon_enclosing) |e| e.v.gcMark(m);
        if (self.stack) |s| m.shade(&s.cell.hdr);
        // `native_state` is host-owned; a value-bearing binding installs its
        // own tracer.
    }

    /// Shallow: the field values, the outer and the class are independent cells
    /// swept on their own reachability.
    pub fn gcFinalize(self: *InstanceData, allocator: std.mem.Allocator) void {
        if (self.anon_captures.len != 0) allocator.free(self.anon_captures);
        if (self.anon_enclosing.len != 0) allocator.free(self.anon_enclosing);
        if (!self.fields_foreign) self.fields.deinit(allocator);
    }

    /// Created through `init` on first access. `kind` is the binding's
    /// discriminator; panics when the instance already carries another kind.
    pub fn ensureNativeState(
        self: *InstanceData,
        allocator: std.mem.Allocator,
        comptime T: type,
        kind: []const u8,
        init: *const fn () T,
    ) std.mem.Allocator.Error!ObjRef(NativeBox) {
        if (self.native_state) |ns| {
            if (!std.mem.eql(u8, ns.kind, kind)) {
                @panic("native_state kind mismatch: instance carries one binding's state, another binding asked for a different kind");
            }
            return ns.data.clone();
        }
        const Boxed = struct {
            fn destroy(ptr: *anyopaque, a: std.mem.Allocator) void {
                const typed: *T = @ptrCast(@alignCast(ptr));
                if (comptime hasDeinit(T)) typed.deinit();
                a.destroy(typed);
            }
        };
        const payload = try allocator.create(T);
        payload.* = init();
        const data = try ObjRef(NativeBox).init(allocator, .{
            .ptr = payload,
            .destroy = Boxed.destroy,
        });
        self.native_state = .{ .kind = kind, .data = data.clone() };
        return data;
    }

    /// The caller must request the `T` the cell was created with; `kind` guards
    /// mismatches at the site that produced it.
    pub fn nativeStatePtr(comptime T: type, data: ObjRef(NativeBox)) *T {
        const g = data.borrow();
        defer g.deinit();
        return @ptrCast(@alignCast(g.get().ptr));
    }
};

fn hasDeinit(comptime U: type) bool {
    return switch (@typeInfo(U)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(U, "deinit"),
        else => false,
    };
}

/// `kind` is the FQN of the owning binding, which guards downcasts.
pub const NativeState = struct {
    kind: []const u8,
    data: ObjRef(NativeBox),
};

/// Only the binding knows `ptr`'s concrete type and how to free it, through
/// `destroy`, run when the last clone drops.
pub const NativeBox = struct {
    ptr: *anyopaque,
    destroy: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,

    pub fn deinit(self: *NativeBox, allocator: std.mem.Allocator) void {
        self.destroy(self.ptr, allocator);
    }
};

fn containsStr(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

fn containsPtr(haystack: []const *const ClassDef, needle: *const ClassDef) bool {
    for (haystack) |p| {
        if (p == needle) return true;
    }
    return false;
}

fn collectCompanionsWalk(
    allocator: std.mem.Allocator,
    cls: ObjRef(ClassDef),
    out: *std.ArrayList(ObjRef(InstanceData)),
    seen: *std.ArrayList(*const ClassDef),
) !void {
    const ptr: *const ClassDef = cls.asPtr();
    if (containsPtr(seen.items, ptr) or seen.items.len > ClassDef.MAX_WALK) return;
    try seen.append(allocator, ptr);
    {
        const g = ptr.companion.borrow();
        defer g.deinit();
        if (g.get().*) |c| try out.append(allocator, c.clone());
    }
    if (parentClone(ptr)) |parent| {
        defer parent.deinit();
        try collectCompanionsWalk(allocator, parent, out, seen);
    }
    for (ptr.interfaces) |iface| {
        try collectCompanionsWalk(allocator, iface, out, seen);
    }
    if (enclosingClone(ptr)) |encl| {
        defer encl.deinit();
        try collectCompanionsWalk(allocator, encl, out, seen);
    }
}

fn findMethodWalk(
    allocator: std.mem.Allocator,
    cls: ObjRef(ClassDef),
    name: []const u8,
    seen: *std.ArrayList(*const ClassDef),
) ?MethodHit {
    const ptr: *const ClassDef = cls.asPtr();
    if (containsPtr(seen.items, ptr) or seen.items.len > ClassDef.MAX_WALK) return null;
    seen.append(allocator, ptr) catch return null;
    for (ptr.methods) |m| {
        if (std.mem.eql(u8, m.name, name) and
            (m.decl.get().body != null or m.sam_lambda != null or m.delegate_field != null))
        {
            return .{ .method = m, .class = cls.clone() };
        }
    }
    for (ptr.delegate_forwarders) |m| {
        if (std.mem.eql(u8, m.name, name)) return .{ .method = m, .class = cls.clone() };
    }
    if (parentClone(ptr)) |parent| {
        defer parent.deinit();
        if (findMethodWalk(allocator, parent, name, seen)) |found| return found;
    }
    for (ptr.interfaces) |iface| {
        if (findMethodWalk(allocator, iface, name, seen)) |found| return found;
    }
    for (ptr.methods) |m| {
        if (std.mem.eql(u8, m.name, name)) return .{ .method = m, .class = cls.clone() };
    }
    return null;
}

fn findMethodForArgWalk(
    allocator: std.mem.Allocator,
    cls: ObjRef(ClassDef),
    name: []const u8,
    arg_type_name: []const u8,
    seen: *std.ArrayList(*const ClassDef),
) ?MethodHit {
    const ptr: *const ClassDef = cls.asPtr();
    if (containsPtr(seen.items, ptr) or seen.items.len > ClassDef.MAX_WALK) return null;
    seen.append(allocator, ptr) catch return null;
    for (ptr.methods) |m| {
        if (std.mem.eql(u8, m.name, name) and m.decl.get().body != null and firstParamTypeMatches(m, arg_type_name)) {
            return .{ .method = m, .class = cls.clone() };
        }
    }
    if (parentClone(ptr)) |parent| {
        defer parent.deinit();
        if (findMethodForArgWalk(allocator, parent, name, arg_type_name, seen)) |found| return found;
    }
    for (ptr.interfaces) |iface| {
        if (findMethodForArgWalk(allocator, iface, name, arg_type_name, seen)) |found| return found;
    }
    return null;
}

fn firstParamTypeMatches(m: MethodDef, arg_type_name: []const u8) bool {
    if (m.decl.get().params.len == 0) return false;
    return std.mem.eql(u8, m.decl.get().params[0].ty.name.name, arg_type_name);
}

fn findBodyPropertyWalk(
    allocator: std.mem.Allocator,
    cls: ObjRef(ClassDef),
    name: []const u8,
    seen: *std.ArrayList(*const ClassDef),
) ?PropertyHit {
    const ptr: *const ClassDef = cls.asPtr();
    if (containsPtr(seen.items, ptr) or seen.items.len > ClassDef.MAX_WALK) return null;
    seen.append(allocator, ptr) catch return null;
    for (ptr.body_properties) |p| {
        if (std.mem.eql(u8, p.name, name)) return .{ .property = p, .class = cls.clone() };
    }
    if (parentClone(ptr)) |parent| {
        defer parent.deinit();
        if (findBodyPropertyWalk(allocator, parent, name, seen)) |found| return found;
    }
    for (ptr.interfaces) |iface| {
        if (findBodyPropertyWalk(allocator, iface, name, seen)) |found| return found;
    }
    return null;
}

fn parentClone(cls: *const ClassDef) ?ObjRef(ClassDef) {
    return if (cls.parent) |p| p.clone() else null;
}

fn enclosingClone(cls: *const ClassDef) ?ObjRef(ClassDef) {
    const g = cls.enclosing_class.borrow();
    defer g.deinit();
    return if (g.get().*) |e| e.clone() else null;
}

const testing = std.testing;

/// A `ClassDef` plus the inner cells it owns, so a test tears everything down
/// with one `deinit`. `ClassDef` is arena-owned and has no destructor.
const ClassFixture = struct {
    handle: ObjRef(ClassDef),
    env: ObjRef(Env),
    methods: []MethodDef,
    body_properties: []PropertyDef,

    fn build(
        allocator: std.mem.Allocator,
        name: []const u8,
        supertype_names: []const []const u8,
        methods: []MethodDef,
        body_properties: []PropertyDef,
    ) !ClassFixture {
        const env = try ObjRef(Env).init(allocator, Env.init(allocator));
        const cd: ClassDef = .{
            .name = name,
            .fqn = name,
            .annotation_names = &.{},
            .primary_params = &.{},
            .methods = methods,
            .body_properties = body_properties,
            .init_blocks = &.{},
            .init_block_property_positions = &.{},
            .is_data = false,
            .is_value = false,
            .is_object = false,
            .is_enum = false,
            .is_sealed = false,
            .supertype_names = supertype_names,
            .parent = null,
            .interfaces = &.{},
            .is_interface = false,
            .is_fun_interface = false,
            .parent_ctor_args = &.{},
            .is_open = false,
            .is_abstract = false,
            .is_inner = false,
            .is_anonymous = false,
            .secondary_ctors = &.{},
            .enum_entries = &.{},
            .companion = try ObjRef(?ObjRef(InstanceData)).init(allocator, null),
            .enclosing_class = try ObjRef(?ObjRef(ClassDef)).init(allocator, null),
            .nested_classes = &.{},
            .captured_env = env.clone(),
            .supertype_delegates = &.{},
            .delegate_forwarders = &.{},
            .object_singleton = try ObjRef(?ObjRef(InstanceData)).init(allocator, null),
        };
        return .{
            .handle = try ObjRef(ClassDef).init(allocator, cd),
            .env = env,
            .methods = methods,
            .body_properties = body_properties,
        };
    }

    fn ptr(self: *const ClassFixture) *ClassDef {
        return self.handle.asPtr();
    }

    fn setParent(self: *const ClassFixture, parent: ObjRef(ClassDef)) void {
        self.ptr().parent = parent.clone();
    }

    fn deinit(self: *ClassFixture, allocator: std.mem.Allocator) void {
        _ = allocator;
        const cd = self.ptr();
        // The fixture's supertype slices are empty.
        if (cd.parent) |p| p.deinit();
        for (cd.interfaces) |iface| iface.deinit();
        {
            const g = cd.companion.borrow();
            defer g.deinit();
            if (g.get().*) |c| c.deinit();
        }
        cd.companion.deinit();
        cd.enclosing_class.deinit();
        cd.captured_env.deinit();
        cd.object_singleton.deinit();
        self.handle.deinit();
        self.env.deinit();
    }
};

fn dummySpan() ast.Span {
    return ast.Span.init(span.FileId.from(0), 0, 0);
}

fn ident(name: []const u8) ast.Ident {
    return .{ .name = name, .span = dummySpan() };
}

fn typeRef(name: []const u8, nullable: bool, args: []ast.TypeArg) ast.TypeRef {
    return .{
        .name = ident(name),
        .nullable = nullable,
        .span = dummySpan(),
        .type_args = args,
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
}

/// With a body, so `findMethod` treats a `MethodDef` over it as concrete.
fn fnWithBody(name: []const u8, params: []ast.Param, body: *ast.Block) ast.Function {
    return .{
        .name = ident(name),
        .receiver_type = null,
        .type_params = &.{},
        .where_bounds = &.{},
        .params = params,
        .return_type = null,
        .body = .{ .Block = body.* },
        .is_open = false,
        .is_override = false,
        .is_abstract = false,
        .is_operator = false,
        .is_inline = false,
        .is_infix = false,
        .is_tailrec = false,
        .is_suspend = false,
        .is_expect = false,
        .is_actual = false,
        .visibility = .Public,
        .annotations = &.{},
        .span = dummySpan(),
    };
}

fn methodDef(name: []const u8, decl: *const ast.Function) MethodDef {
    return .{
        .name = name,
        .decl = .{ .ptr = decl },
        .is_operator = false,
        .is_open = false,
        .is_override = false,
        .is_abstract = false,
        .sam_lambda = null,
        .delegate_field = null,
        .ir_fn_id = null,
    };
}

fn propertyDef(name: []const u8) PropertyDef {
    return .{
        .name = name,
        .mutable = false,
        .init = null,
        .getter = null,
        .setter = null,
        .delegate = null,
        .is_abstract = false,
        .is_lateinit = false,
        .primitive_zero = null,
    };
}

test "InstanceData get/set/define round-trip" {
    const allocator = testing.allocator;
    var fx = try ClassFixture.build(allocator, "Foo", &.{}, &.{}, &.{});
    defer fx.deinit(allocator);

    var inst: InstanceData = .{
        .class = fx.handle.clone(),
        .fields = .empty,
        .outer = null,
        .identity = 0,
        .native_state = null,
    };
    defer {
        inst.fields.deinit(allocator);
        inst.class.deinit();
    }

    try testing.expect(inst.get("x") == null);
    try testing.expect(!inst.set("x", .{ .Int = 1 }));

    try inst.define(allocator, "x", .{ .Int = 7 });
    try testing.expectEqual(@as(i32, 7), inst.get("x").?.Int);

    try inst.define(allocator, "x", .{ .Int = 8 });
    try testing.expectEqual(@as(usize, 1), inst.fields.items.len);
    try testing.expectEqual(@as(i32, 8), inst.get("x").?.Int);

    try testing.expect(inst.set("x", .{ .Int = 9 }));
    try testing.expectEqual(@as(i32, 9), inst.get("x").?.Int);
}

test "instance release recursively frees a retained instance field" {
    const allocator = testing.allocator;
    var fx = try ClassFixture.build(allocator, "Foo", &.{}, &.{}, &.{});
    defer fx.deinit(allocator);

    const b = try objcell.ObjRef(InstanceData).init(allocator, .{
        .class = fx.handle.clone(),
        .fields = .empty,
        .outer = null,
        .identity = 1,
        .native_state = null,
    });
    const b_val = Value{ .Instance = b };

    var a_data: InstanceData = .{
        .class = fx.handle.clone(),
        .fields = .empty,
        .outer = null,
        .identity = 2,
        .native_state = null,
    };
    b_val.retain();
    try a_data.define(allocator, "b", b_val);
    const a = try objcell.ObjRef(InstanceData).init(allocator, a_data);
    const a_val = Value{ .Instance = a };

    // `testing.allocator` asserts the whole graph is reclaimed.
    a_val.release(allocator);
    b_val.release(allocator);
}

test "instance release frees its anonymous lexical receiver snapshot" {
    const allocator = testing.allocator;
    var fx = try ClassFixture.build(allocator, "Foo", &.{}, &.{}, &.{});
    defer fx.deinit(allocator);

    const outer = try objcell.ObjRef(InstanceData).init(allocator, .{
        .class = fx.handle.clone(),
        .fields = .empty,
        .outer = null,
        .identity = 1,
        .native_state = null,
    });
    const outer_value = Value{ .Instance = outer };
    const chain = try allocator.alloc(ImplicitReceiver, 1);
    outer_value.retain();
    chain[0] = .{ .v = outer_value, .kind = .receiver };

    const anon = try objcell.ObjRef(InstanceData).init(allocator, .{
        .class = fx.handle.clone(),
        .fields = .empty,
        .outer = null,
        .identity = 2,
        .native_state = null,
        .anon_enclosing = chain,
    });
    const anon_value = Value{ .Instance = anon };
    anon_value.release(allocator);
    outer_value.release(allocator);
}

test "list release recursively frees retained instance elements" {
    const allocator = testing.allocator;
    var fx = try ClassFixture.build(allocator, "Foo", &.{}, &.{}, &.{});
    defer fx.deinit(allocator);

    const inst = try ObjRef(InstanceData).init(allocator, .{
        .class = fx.handle.clone(),
        .fields = .empty,
        .outer = null,
        .identity = 1,
        .native_state = null,
    });
    const inst_val = Value{ .Instance = inst };

    var arr: std.ArrayList(Value) = .empty;
    inst_val.retain(); // storing into the list retains the element (count 2)
    try arr.append(allocator, inst_val);
    const items = try ObjRef(std.ArrayList(Value)).init(allocator, arr);
    const list_val = try Value.newList(allocator, .{ .items = items, .mutable = true, .enum_entries = false, .backing = null });

    list_val.release(allocator);
    inst_val.release(allocator);
}

test "findMethod walks the parent chain and prefers concrete bodies" {
    const allocator = testing.allocator;

    var blk: ast.Block = .{ .stmts = &.{}, .span = dummySpan() };
    var parent_fn = fnWithBody("greet", &.{}, &blk);
    var child_fn = fnWithBody("speak", &.{}, &blk);

    var parent_methods = [_]MethodDef{methodDef("greet", &parent_fn)};
    var parent_fx = try ClassFixture.build(allocator, "Base", &.{}, &parent_methods, &.{});
    defer parent_fx.deinit(allocator);

    var child_methods = [_]MethodDef{methodDef("speak", &child_fn)};
    var child_fx = try ClassFixture.build(allocator, "Derived", &.{"Base"}, &child_methods, &.{});
    defer child_fx.deinit(allocator);
    child_fx.setParent(parent_fx.handle);

    const own = ClassDef.findMethod(child_fx.handle, allocator, "speak").?;
    var own_hit = own;
    defer own_hit.class.deinit();
    try testing.expectEqualStrings("speak", own_hit.method.name);
    {
        const g = own_hit.class.borrow();
        defer g.deinit();
        try testing.expectEqualStrings("Derived", g.get().name);
    }

    const inherited = ClassDef.findMethod(child_fx.handle, allocator, "greet").?;
    var inh_hit = inherited;
    defer inh_hit.class.deinit();
    try testing.expectEqualStrings("greet", inh_hit.method.name);
    {
        const g = inh_hit.class.borrow();
        defer g.deinit();
        try testing.expectEqualStrings("Base", g.get().name);
    }

    try testing.expect(ClassDef.findMethod(child_fx.handle, allocator, "missing") == null);
}

test "findMethodForArg prefers the matching first-param overload" {
    const allocator = testing.allocator;

    var blk: ast.Block = .{ .stmts = &.{}, .span = dummySpan() };

    const int_arg_ty = typeRef("Int", false, &.{});
    const bag_arg_ty = typeRef("Bag", false, &.{});
    var int_params = [_]ast.Param{.{ .name = ident("o"), .ty = int_arg_ty, .default = null, .is_vararg = false, .is_crossinline = false, .is_noinline = false, .annotations = &.{}, .span = dummySpan() }};
    var bag_params = [_]ast.Param{.{ .name = ident("o"), .ty = bag_arg_ty, .default = null, .is_vararg = false, .is_crossinline = false, .is_noinline = false, .annotations = &.{}, .span = dummySpan() }};

    var plus_int = fnWithBody("plus", &int_params, &blk);
    var plus_bag = fnWithBody("plus", &bag_params, &blk);

    var methods = [_]MethodDef{ methodDef("plus", &plus_int), methodDef("plus", &plus_bag) };
    var fx = try ClassFixture.build(allocator, "Bag", &.{}, &methods, &.{});
    defer fx.deinit(allocator);

    const hit = ClassDef.findMethodForArg(fx.handle, allocator, "plus", "Bag").?;
    var h = hit;
    defer h.class.deinit();
    try testing.expectEqualStrings("Bag", h.method.decl.get().params[0].ty.name.name);

    const fallback = ClassDef.findMethodForArg(fx.handle, allocator, "plus", "Other").?;
    var fb = fallback;
    defer fb.class.deinit();
    try testing.expectEqualStrings("plus", fb.method.name);
}

test "findBodyProperty walks self then parent" {
    const allocator = testing.allocator;

    var parent_props = [_]PropertyDef{propertyDef("base")};
    var parent_fx = try ClassFixture.build(allocator, "Base", &.{}, &.{}, &parent_props);
    defer parent_fx.deinit(allocator);

    var child_props = [_]PropertyDef{propertyDef("own")};
    var child_fx = try ClassFixture.build(allocator, "Derived", &.{"Base"}, &.{}, &child_props);
    defer child_fx.deinit(allocator);
    child_fx.setParent(parent_fx.handle);

    const own = ClassDef.findBodyProperty(child_fx.handle, allocator, "own").?;
    own.class.deinit();
    try testing.expectEqualStrings("own", own.property.name);

    const inherited = ClassDef.findBodyProperty(child_fx.handle, allocator, "base").?;
    var inh = inherited;
    defer inh.class.deinit();
    {
        const g = inh.class.borrow();
        defer g.deinit();
        try testing.expectEqualStrings("Base", g.get().name);
    }

    try testing.expect(ClassDef.findBodyProperty(child_fx.handle, allocator, "nope") == null);
}

test "isSubtypeOf matches self, fqn, and named supertypes via captured env" {
    const allocator = testing.allocator;

    var base_fx = try ClassFixture.build(allocator, "Base", &.{}, &.{}, &.{});
    defer base_fx.deinit(allocator);

    var derived_fx = try ClassFixture.build(allocator, "Derived", &.{"Base"}, &.{}, &.{});
    defer derived_fx.deinit(allocator);

    // Bind `Base` in the derived class's captured env for the name walk.
    {
        const g = derived_fx.env.borrowMut();
        defer g.deinit();
        try g.get().define("Base", .{ .Class = base_fx.handle.clone() });
    }
    defer {
        const g = derived_fx.env.borrow();
        defer g.deinit();
        if (g.get().lookup("Base")) |v| v.Class.deinit();
    }

    try testing.expect(derived_fx.ptr().isSubtypeOf(allocator, "Derived"));
    try testing.expect(derived_fx.ptr().isSubtypeOf(allocator, "Base"));
    try testing.expect(!derived_fx.ptr().isSubtypeOf(allocator, "Unrelated"));
}

test "allCompanions collects self and parent companions" {
    const allocator = testing.allocator;

    var parent_fx = try ClassFixture.build(allocator, "Base", &.{}, &.{}, &.{});
    defer parent_fx.deinit(allocator);
    var child_fx = try ClassFixture.build(allocator, "Derived", &.{"Base"}, &.{}, &.{});
    defer child_fx.deinit(allocator);
    child_fx.setParent(parent_fx.handle);

    const parent_comp = try ObjRef(InstanceData).init(allocator, .{
        .class = parent_fx.handle.clone(),
        .fields = .empty,
        .outer = null,
        .identity = 1,
        .native_state = null,
    });
    defer parent_comp.deinit();
    const child_comp = try ObjRef(InstanceData).init(allocator, .{
        .class = child_fx.handle.clone(),
        .fields = .empty,
        .outer = null,
        .identity = 2,
        .native_state = null,
    });
    defer child_comp.deinit();
    {
        const g = parent_fx.ptr().companion.borrowMut();
        defer g.deinit();
        g.get().* = parent_comp.clone();
    }
    {
        const g = child_fx.ptr().companion.borrowMut();
        defer g.deinit();
        g.get().* = child_comp.clone();
    }

    const comps = try ClassDef.allCompanions(child_fx.handle, allocator);
    defer {
        for (comps) |c| c.deinit();
        allocator.free(comps);
    }
    try testing.expectEqual(@as(usize, 2), comps.len);
    try testing.expect(ObjRef(InstanceData).ptrEq(comps[0], child_comp));
    try testing.expect(ObjRef(InstanceData).ptrEq(comps[1], parent_comp));
}

test "TypeShape from a generic, nullable type ref" {
    const allocator = testing.allocator;

    // The star-projected argument must be skipped.
    const string_ty = typeRef("String", false, &.{});
    const item_ty = typeRef("Item", true, &.{});
    var args = [_]ast.TypeArg{
        .{ .variance = .Invariant, .is_star = false, .ty = string_ty, .span = dummySpan() },
        .{ .variance = .Invariant, .is_star = false, .ty = item_ty, .span = dummySpan() },
        .{ .variance = .Invariant, .is_star = true, .ty = string_ty, .span = dummySpan() },
    };
    const map_ty = typeRef("Map", true, &args);

    const shape = try TypeShape.fromTypeRef(allocator, &map_ty);
    defer {
        for (shape.args) |a| allocator.free(a.args);
        allocator.free(shape.args);
    }

    try testing.expectEqualStrings("Map", shape.name);
    try testing.expect(shape.nullable);
    try testing.expectEqual(@as(usize, 2), shape.args.len); // star arg skipped
    try testing.expectEqualStrings("String", shape.args[0].name);
    try testing.expect(!shape.args[0].nullable);
    try testing.expectEqualStrings("Item", shape.args[1].name);
    try testing.expect(shape.args[1].nullable);
}

test "shape ids: intern by layout, reset on append, distinct layouts differ" {
    const allocator = testing.allocator;
    var fx = try ClassFixture.build(allocator, "S", &.{}, &.{}, &.{});
    defer fx.deinit(allocator);

    var a: InstanceData = .{ .class = fx.handle.clone(), .fields = .empty, .outer = null, .identity = 0, .native_state = null };
    defer {
        a.fields.deinit(allocator);
        a.class.deinit();
    }
    var b: InstanceData = .{ .class = fx.handle.clone(), .fields = .empty, .outer = null, .identity = 1, .native_state = null };
    defer {
        b.fields.deinit(allocator);
        b.class.deinit();
    }
    const n1: []const u8 = "alpha";
    const n2: []const u8 = "beta";
    try a.fields.append(allocator, .{ .name = n1, .value = .Unit });
    try b.fields.append(allocator, .{ .name = n1, .value = .{ .Int = 7 } });

    const sa = a.shapeOf();
    try testing.expect(sa != SHAPE_UNSET and sa != SHAPE_NONE);
    // Same name pointers in the same order is the same id.
    try testing.expectEqual(sa, b.shapeOf());
    try testing.expectEqual(sa, a.shapeOf());

    // Append changes the layout: the id resets and re-interns differently.
    try b.fields.append(allocator, .{ .name = n2, .value = .Unit });
    b.shape.store(SHAPE_UNSET, .release);
    const sb2 = b.shapeOf();
    try testing.expect(sb2 != sa and sb2 != SHAPE_UNSET and sb2 != SHAPE_NONE);
    try a.fields.append(allocator, .{ .name = n2, .value = .Unit });
    a.shape.store(SHAPE_UNSET, .release);
    try testing.expectEqual(sb2, a.shapeOf());
}

test "ensureNativeState creates once and returns the same payload" {
    const allocator = testing.allocator;
    var fx = try ClassFixture.build(allocator, "Buf", &.{}, &.{}, &.{});
    defer fx.deinit(allocator);

    const Payload = struct { n: u32 };
    const mk = struct {
        fn make() Payload {
            return .{ .n = 42 };
        }
    };

    var inst: InstanceData = .{
        .class = fx.handle.clone(),
        .fields = .empty,
        .outer = null,
        .identity = 0,
        .native_state = null,
    };
    defer {
        if (inst.native_state) |ns| ns.data.deinit();
        inst.fields.deinit(allocator);
        inst.class.deinit();
    }

    const first = try inst.ensureNativeState(allocator, Payload, "kotlinx.io.Buffer", mk.make);
    defer first.deinit();
    try testing.expectEqual(@as(u32, 42), InstanceData.nativeStatePtr(Payload, first).n);

    InstanceData.nativeStatePtr(Payload, first).n = 99;
    const second = try inst.ensureNativeState(allocator, Payload, "kotlinx.io.Buffer", mk.make);
    defer second.deinit();
    try testing.expect(ObjRef(NativeBox).ptrEq(first, second));
    try testing.expectEqual(@as(u32, 99), InstanceData.nativeStatePtr(Payload, second).n);
}
