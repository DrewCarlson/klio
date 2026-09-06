//! Declared Kotlin classes as the interpreter sees them at runtime:
//! `ClassDef`, its parameter/method/property descriptors, the live
//! `InstanceData`, and the method/property resolution walks.

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

/// One implicit receiver captured from a lexical scope. Storage order is
/// outermost first, innermost last.
pub const ImplicitReceiver = struct {
    v: Value,
    kind: Kind = .receiver,

    pub const Kind = enum { receiver, subject, access };

    pub fn isSubject(self: ImplicitReceiver) bool {
        return self.kind == .subject;
    }
};

/// A declared Kotlin class as the interpreter sees it at runtime.
pub const ClassDef = struct {
    /// A class definition is built once and, after two-phase linking backpatches
    /// `parent`/`interfaces`/`enum_entries` at single-threaded startup, is
    /// immutable — the dispatch path already reads it lock-free. Nothing takes an
    /// exclusive borrow of a class cell (lazily-initialized bits like `companion`
    /// live in their own nested cells with their own locks), so its reader lock is
    /// pure overhead; elide it (see `objcell.LockFor`).
    pub const objref_immutable = true;

    name: []const u8,
    fqn: []const u8,
    /// Runtime-retained annotation class names applied to this declaration.
    annotation_names: []const []const u8,
    /// The same annotations with their resolved constructor ARGUMENTS, which
    /// `annotation_names` alone cannot carry. Reflective consumers that read
    /// an argument off a class annotation (`@SerialName("...")`) need these.
    annotation_records: []const AnnotationRecord = &.{},
    /// Declared type-parameter names, in declaration order. A reflective
    /// consumer handed one serializer per type argument matches them against
    /// the rendered declared types of the properties to know which element a
    /// given argument describes.
    type_params: []const []const u8 = &.{},
    primary_params: []ClassParamDef,
    /// Member functions keyed by simple name.
    methods: []MethodDef,
    /// Body `val`/`var` properties (not primary-ctor properties).
    body_properties: []PropertyDef,
    init_blocks: []const forest.ForestField(ast.Block),
    /// For each entry in `init_blocks`, the index of `body_properties` it
    /// runs before — matching Kotlin's source-order init rule.
    init_block_property_positions: []usize,
    is_data: bool,
    /// `true` for a `value class` / `@JvmInline value class`.
    is_value: bool,
    is_object: bool,
    /// `true` for an `enum class`.
    is_enum: bool,
    /// Whether the declaration has a primary constructor (see `ir.Class`).
    has_primary_ctor: bool = true,
    /// `true` when the declaration carried the `sealed` modifier.
    is_sealed: bool,
    /// Simple supertype names recorded from `class Foo : Bar(), Baz`.
    supertype_names: []const []const u8,
    /// Parallel to `supertype_names`: the dotted source qualifier when a
    /// supertype was written qualified (`Outer.Inner`), else null. Lets
    /// parent resolution disambiguate a nested base from a same-simple-name
    /// class in scope — including a subtype named like its base. Empty when
    /// no supertype carried a qualifier (the common case).
    supertype_paths: []const ?[]const u8 = &.{},
    /// Resolved parent class for method-resolution chain walking.
    /// Backpatched once during two-phase class linking, then immutable for
    /// the rest of the process; read lock-free on the dispatch path.
    parent: ?ObjRef(ClassDef),
    /// Resolved interface supertypes (any number). Arena slice filled once
    /// during linking; immutable and lock-free thereafter.
    interfaces: []const ObjRef(ClassDef),
    /// `true` for a class declared with the `interface` keyword.
    is_interface: bool,
    /// `true` for a `fun interface`.
    is_fun_interface: bool,
    /// Constructor argument expressions for the parent class.
    parent_ctor_args: []const forest.ForestField(ast.Expr),
    /// `true` when the declaration carried the `open` modifier.
    is_open: bool,
    /// `true` for an `abstract class`.
    is_abstract: bool,
    /// `true` for an `inner class`.
    is_inner: bool,
    /// `true` for the synthetic `ClassDef` built from an `object { … }`.
    is_anonymous: bool,
    /// Secondary constructors in source-declared order.
    secondary_ctors: []const forest.ForestField(ast.SecondaryCtor),
    /// Eagerly-constructed enum entries in source order. Arena slice filled
    /// once during linking; immutable and lock-free thereafter.
    enum_entries: []const EnumEntry,
    /// Companion object instance, if any.
    companion: ObjRef(?ObjRef(InstanceData)),
    /// For a companion-object class, the enclosing class.
    enclosing_class: ObjRef(?ObjRef(ClassDef)),
    /// Nested classes by simple name. Immutable arena slice.
    nested_classes: []const NestedClass,
    /// Captured env in which the class was declared.
    captured_env: ObjRef(Env),
    /// Inheritance-delegation table. Immutable arena slice.
    supertype_delegates: []const SupertypeDelegate,
    /// Synthesized forwarder methods for delegated interfaces. Immutable
    /// arena slice.
    delegate_forwarders: []const MethodDef,
    /// Lazily-constructed singleton for nested `is_object` classes.
    object_singleton: ObjRef(?ObjRef(InstanceData)),
    /// `true` for a def synthesized at runtime from a LOCAL class declaration
    /// (a `class`/`data class` inside a function body). Such a def is the
    /// class — a constructor call on its `.Class` value must never be
    /// redirected through the module class index, where an unrelated
    /// same-simple-name class (a nested class of another owner) can shadow it.
    is_local_runtime: bool = false,

    /// Single-fill memo for the ctor chain's first non-interface supertype
    /// (`host_instances.firstNonInterfaceSuper`): the per-call string
    /// resolution of every supertype name priced every instance
    /// construction. 0 = uncomputed, 1 = none, 2 = filled with
    /// `first_super_index` (into `supertype_names`) and `first_super_fqn`
    /// (the resolved def's fqn, null for a builtin parent with no runtime
    /// def). Benign-race: concurrent fillers compute identical values.
    first_super_state: u8 = 0,
    first_super_index: u8 = 0,
    first_super_fqn: ?[]const u8 = null,

    /// Single-fill memo: the ir-module `ClassId` this runtime class resolves
    /// to, so the virtual-dispatch fast path skips the string-keyed
    /// `classIdByFqn` probe it was paying per call. `resolve_mod` is claimed
    /// by the first resolving module's pointer identity (CAS from 0);
    /// `resolve_cid` (the id + 1, release-stored after the claim) is the
    /// validity gate. A class consulted under a different module than the
    /// one that claimed the memo just keeps the slow path.
    resolve_mod: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    resolve_cid: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Single-fill memo for the `<class-companion-or-self>` value read:
    /// whether this class resolves to a companion/object singleton and,
    /// when it does, the singleton value itself (process-stable once
    /// constructed — the shared singleton registry keeps it alive, so the
    /// memo holds a borrowed copy). 0 = unresolved, 1 = the class value
    /// itself (no companion, not an object), 2 = `companion_read_value`.
    /// Benign-race: concurrent fillers store the same singleton.
    companion_read_state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    companion_read_value: Value = .Null,

    /// One eager enum entry: its name and the `Value::Instance` for it.
    pub const EnumEntry = struct {
        name: []const u8,
        value: Value,
        /// Annotations written on the entry declaration, with their arguments.
        /// A reflective consumer reports these per element the way the class's
        /// own `annotation_records` are reported for the declaration.
        annotation_records: []const AnnotationRecord = &.{},
    };
    /// One nested class binding: simple name -> resolved `ClassDef`.
    pub const NestedClass = struct { name: []const u8, class: ObjRef(ClassDef) };

    pub const MAX_WALK = 128;

    /// GC tracer for the class graph. Marks every cell a class reaches:
    /// supertypes, nested/companion/enclosing/object-singleton, the captured
    /// definition environment, and enum-entry singleton instances. (Method/
    /// property/init bodies are AST-backed and hold no runtime Value cells.)
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
    }

    /// Walk the class chain (self, then parent, then grandparent, …) and
    /// return the first method matching `name`, paired with its declaring
    /// class. Caller owns nothing extra; the returned handles are clones.
    pub fn findMethod(self: ObjRef(ClassDef), allocator: std.mem.Allocator, name: []const u8) ?MethodHit {
        var seen: std.ArrayList(*const ClassDef) = .empty;
        defer seen.deinit(allocator);
        return findMethodWalk(allocator, self, name, &seen);
    }

    /// Like `findMethod`, but among overloads with this name, prefers one
    /// whose first declared parameter type name matches `arg_type_name`.
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

    /// Walk the class chain searching for a body property of `name`.
    pub fn findBodyProperty(self: ObjRef(ClassDef), allocator: std.mem.Allocator, name: []const u8) ?PropertyHit {
        var seen: std.ArrayList(*const ClassDef) = .empty;
        defer seen.deinit(allocator);
        return findBodyPropertyWalk(allocator, self, name, &seen);
    }

    /// The list of declared interface supertypes (resolved). Caller owns
    /// the returned slice.
    pub fn interfaceRefs(self: *const ClassDef, allocator: std.mem.Allocator) ![]ObjRef(ClassDef) {
        return allocator.dupe(ObjRef(ClassDef), self.interfaces);
    }

    /// Collect companions reachable from this class. Caller owns the slice.
    pub fn allCompanions(self: ObjRef(ClassDef), allocator: std.mem.Allocator) ![]ObjRef(InstanceData) {
        var out: std.ArrayList(ObjRef(InstanceData)) = .empty;
        errdefer out.deinit(allocator);
        var seen: std.ArrayList(*const ClassDef) = .empty;
        defer seen.deinit(allocator);
        try collectCompanionsWalk(allocator, self, &out, &seen);
        return out.toOwnedSlice(allocator);
    }

    /// True when this class or any of its named supertypes matches `name`.
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

/// A method paired with the class that declared it.
pub const MethodHit = struct { method: MethodDef, class: ObjRef(ClassDef) };
/// A property paired with the class that declared it.
pub const PropertyHit = struct { property: PropertyDef, class: ObjRef(ClassDef) };

pub const SupertypeDelegate = struct {
    /// Simple name of the delegated interface (written before `by`).
    interface_name: []const u8,
    /// Resolved interface class, if it resolves at registration time.
    interface: ?ObjRef(ClassDef),
    /// Delegate expression — evaluated in the primary-ctor parameter scope.
    expr: forest.ForestField(ast.Expr),
    /// Field key on the instance where the resolved delegate value lives.
    field_key: []const u8,
};

pub const ClassParamDef = struct {
    /// `true` for `var`, `false` for `val`, `null` if not a property.
    property: ?bool,
    name: []const u8,
    default: ?forest.ForestField(ast.Expr),
    /// Declared type's simple name (e.g. `"Long"`).
    declared_type: ?[]const u8,
    /// The full declared-type shape, including generic args and nullability.
    declared_shape: ?TypeShape,
    /// Per-anchor annotation records for a constructor property, after
    /// use-site target assignment (`@all:` expansion / defaulting).
    anchors: PropertyAnchors = .{},
};

/// One resolved constructor argument of an annotation application.
/// Runtime-retained so reflection-driven consumers (the serializer's
/// `@SerialName`, validation libraries) can read annotation values.
pub const AnnotationArg = union(enum) {
    /// A string literal (`@SerialName("years")`).
    Str: []const u8,
    Int: i64,
    Bool: bool,
    /// The trailing segment of a dotted path (`AnnotationTarget.PROPERTY`
    /// records `"PROPERTY"`).
    EnumEntry: []const u8,
    /// A class literal argument (`@Serializer(forClass = Foo::class)` records
    /// `"Foo"`), which names a declaration rather than a value.
    ClassRef: []const u8,
    /// Any argument shape the lowering does not resolve to a value.
    Other,
};

/// One annotation application recorded against a specific anchor.
pub const AnnotationRecord = struct {
    /// Resolved fully-qualified candidate names for the annotation class
    /// (import-expanded, always ending with the source spelling).
    names: []const []const u8,
    /// Resolved constructor arguments in source order.
    args: []const AnnotationArg = &.{},
    /// Parallel to `args`: the argument name for named arguments.
    arg_names: []const ?[]const u8 = &.{},

    /// Whether any resolved candidate matches `name` exactly.
    pub fn is(self: *const AnnotationRecord, name: []const u8) bool {
        for (self.names) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }

    /// The value of the string argument named `param`, or the first
    /// positional string argument when no argument names were written.
    pub fn stringArg(self: *const AnnotationRecord, param: []const u8) ?[]const u8 {
        for (self.args, 0..) |arg, i| {
            if (arg != .Str) continue;
            const nm: ?[]const u8 = if (i < self.arg_names.len) self.arg_names[i] else null;
            if (nm == null or std.mem.eql(u8, nm.?, param)) return arg.Str;
        }
        return null;
    }
};

/// The distinct anchors annotations of one property land on after
/// use-site target assignment. Slices are arena-owned and immutable.
pub const PropertyAnchors = struct {
    param: []const AnnotationRecord = &.{},
    property: []const AnnotationRecord = &.{},
    field: []const AnnotationRecord = &.{},
    get: []const AnnotationRecord = &.{},
    set: []const AnnotationRecord = &.{},
    setparam: []const AnnotationRecord = &.{},
    delegate: []const AnnotationRecord = &.{},

    /// The first record on the property anchor matching `name`.
    pub fn propertyRecord(self: *const PropertyAnchors, name: []const u8) ?*const AnnotationRecord {
        for (self.property) |*rec| {
            if (rec.is(name)) return rec;
        }
        return null;
    }
};

/// A structural view of a declared type retained for reflection.
pub const TypeShape = struct {
    name: []const u8,
    nullable: bool,
    args: []TypeShape,

    /// Build a `TypeShape` from a parsed AST type reference, recursing into
    /// generic arguments and skipping star projections. Caller's allocator
    /// owns the recursively-built `args` slices.
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
    /// The method's AST function — eager (`.ptr`, build/runtime/test) or lazy
    /// (`.ref`, image-backed forest). Read via `decl.get()`.
    decl: forest.ForestField(ast.Function),
    is_operator: bool,
    is_open: bool,
    is_override: bool,
    /// `true` when the source carried the `abstract` modifier.
    is_abstract: bool,
    /// When non-null, calls dispatch through this SAM-converted lambda.
    sam_lambda: ?Value,
    /// When non-null, a synthesized inheritance-delegation forwarder routing
    /// calls to the delegate instance stored under this field key.
    delegate_field: ?[]const u8,
    /// IR `FuncId` of the lowered method body, if lowered.
    ir_fn_id: ?u32,
    /// Resolved fully-qualified candidate names for each source annotation
    /// on this method, so a test runner can discover `@Test`/etc.
    annotation_names: []const []const u8 = &.{},
};

pub const PropertyDef = struct {
    name: []const u8,
    mutable: bool,
    /// Initializer / accessor / delegate AST — eager (`.ptr`, build/bake) or lazy
    /// (`.ref`, image-backed forest). A loaded image never reads these (the
    /// lowered side-tables come from the built program), so the `.ref` form keeps
    /// them out of the eager forest decode. Read via `.get()`.
    init: ?forest.ForestField(ast.Expr),
    /// Custom getter body, if declared.
    getter: ?forest.ForestField(ast.Accessor),
    /// Custom setter body, if declared.
    setter: ?forest.ForestField(ast.Accessor),
    /// `val foo by expr` — the delegate expression.
    delegate: ?forest.ForestField(ast.Expr),
    /// `true` when the property was declared `abstract`.
    is_abstract: bool,
    /// `true` for a `lateinit var`.
    is_lateinit: bool,
    /// Declared non-nullable primitive zero value for a property with no
    /// initializer.
    primitive_zero: ?Value,
    /// Per-anchor annotation records after use-site target assignment.
    anchors: PropertyAnchors = .{},
    /// Whether the property stores a backing field (kotlinc's rule:
    /// initializer, defaulted accessor, or an accessor that reads `field`).
    /// Serialization treats exactly the backing-field properties as
    /// elements.
    has_backing: bool = true,
    /// Declared type head, when the source annotates one. Null for an
    /// inferred type — descriptor consumers fall back to the dynamic
    /// element descriptor.
    type_head: ?[]const u8 = null,
};

/// Interned instance-LAYOUT identity. Two instances carry the same shape id
/// iff their field lists hold the same name POINTERS in the same order (field
/// names are canonicalized program-lifetime strings, so pointer identity is
/// name identity). A matching shape id therefore proves "field `name` is at
/// index i" without reading any name — the field site memos and the JIT's
/// per-entry name re-verify become one integer compare.
///
/// Ids are addresses of interned records in a program-lifetime arena; the
/// table is bounded (`shape_cap`) so a pathological workload minting
/// per-instance name buffers degrades to the UNSHAPED sentinel, never to
/// unbounded growth. 0 = not computed yet, 1 = unshapeable.
pub const SHAPE_UNSET: usize = 0;
pub const SHAPE_NONE: usize = 1;

const ShapeRec = struct {
    /// (ptr, len) per field name, in field order. Hashed on both; equality
    /// on the POINTERS (identical ptr vector => identical layout).
    ptrs: [][*]const u8,
    lens: []u32,
};

/// Test-and-set spinlock (Zig 0.16 std has no blocking Thread.Mutex); held
/// only for the intern-table probe on a shape MISS.
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

/// Intern the layout of `fields` and return its shape id (never SHAPE_UNSET;
/// SHAPE_NONE when the table is at capacity).
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
    /// Field name -> value. Insertion ordered.
    fields: std.ArrayList(Field),
    /// Interned layout identity (`SHAPE_UNSET` until computed; reset on any
    /// field APPEND). Benign-race fill: every filler computes the same id
    /// for the same layout. Read via `shapeOf`.
    shape: std.atomic.Value(usize) = std.atomic.Value(usize).init(SHAPE_UNSET),
    /// For an `inner class` instance, the captured enclosing-class instance.
    outer: ?Value,
    /// Per-instance identity, assigned at construction from a monotonic
    /// counter.
    identity: u64,
    /// Opaque per-instance state owned by a native host binding.
    native_state: ?NativeState,
    /// True when `fields` points into a baked image's arena rather than the
    /// runtime allocator. Growing or freeing that buffer with the runtime
    /// allocator crosses allocators; the first growth re-buffers and clears
    /// this, and teardown skips the spine free (the arena owns it).
    fields_foreign: bool = false,
    /// For an anonymous-object instance, the values it captured from its
    /// enclosing scope, used to seed the method-body env at dispatch. Held here
    /// (per instance) rather than in a global registry so they are reclaimed
    /// with the instance — the registry's anon method/class entries are
    /// site-stable and shared across instances. Names are borrowed
    /// (program-lifetime); the slice and the values are owned by the instance.
    anon_captures: []Capture = &.{},
    /// Lexical implicit receivers visible where an anonymous-object expression
    /// was created. Anonymous method frames are seeded from this snapshot so
    /// nested receiver lambdas do not hide an outer dispatch receiver.
    anon_enclosing: []ImplicitReceiver = &.{},
    /// For a user `Throwable` subclass instance, the call stack captured when it
    /// was first thrown (`fillInStackTrace`). Null for every non-throwable
    /// instance and until the throwable is thrown.
    stack: ?value_mod.StackRef = null,

    pub const Field = struct { name: []const u8, value: Value };
    pub const Capture = struct { name: []const u8, value: Value };

    pub fn get(self: *const InstanceData, name: []const u8) ?Value {
        for (self.fields.items) |f| {
            // Field names are canonicalized program-lifetime strings, so an
            // identical pointer is an identical name — a cheap integer compare
            // that skips the byte scan on the common hit. The `eql` keeps
            // correctness for a name that bypassed canonicalization (a runtime
            // string, a late side-module).
            if (f.name.ptr == name.ptr or std.mem.eql(u8, f.name, name)) return f.value;
        }
        return null;
    }

    /// `get` for a host-side probe with a NON-interned literal name: the
    /// ptr fast path can never hit, so every call pays a byte-compare per
    /// field. The caller passes a per-name cache slot; the first hit
    /// stores the field's interned pointer and later calls ride the
    /// integer compare. A class whose intern differs just re-fills.
    /// The instance's class WITHOUT taking its reader lock. An instance's
    /// class is written once at construction and never changes, so a
    /// dispatch key or a site guard that needs only that pointer must not
    /// pay two atomics for it — a recomposition takes ~380 such reads per
    /// composable.
    pub fn classIdentityUnlocked(inst: objcell.ObjRef(InstanceData)) usize {
        return inst.asPtrConst().class.identity();
    }

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

    /// Store `v` into field `name` (creating it if absent), **adopting** one
    /// owned reference to `v` (the caller hands off a fresh/owned ref; an alias
    /// caller retains first). The value replaced on an existing field is
    /// released — `InstanceData.deinit` releases every field value, so the
    /// instance owns exactly one ref per field. No refcount traffic under the
    /// arena fast path.
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
        // The layout changed: any memoized shape id no longer describes it.
        self.shape.store(SHAPE_UNSET, .release);
    }

    /// Any out-of-band field-list mutation (host-side appends, removes) must
    /// drop the memoized layout id.
    pub fn invalidateShape(self: *InstanceData) void {
        self.shape.store(SHAPE_UNSET, .release);
    }

    /// The instance's interned layout identity, computing and memoizing it on
    /// first use (and after any field append reset it). The caller must hold
    /// a borrow on the instance (the field list must not grow mid-read).
    pub fn shapeOf(self: *const InstanceData) usize {
        const cached = self.shape.load(.acquire);
        if (cached != SHAPE_UNSET) return cached;
        const id = internShape(self.fields.items);
        @constCast(self).shape.store(id, .release);
        return id;
    }

    /// Re-buffer an image-arena field list with the runtime allocator before
    /// its first growth. The arena keeps the original buffer; the in-place
    /// replace and read paths never needed this.
    pub fn ensureFieldsOwned(self: *InstanceData, allocator: std.mem.Allocator, extra: usize) !void {
        if (!self.fields_foreign) return;
        var fresh: std.ArrayList(Field) = .empty;
        try fresh.ensureTotalCapacity(allocator, self.fields.items.len + extra);
        fresh.appendSliceAssumeCapacity(self.fields.items);
        self.fields = fresh;
        self.fields_foreign = false;
    }

    /// Reference-counting teardown: run when an instance's strong count
    /// reaches zero. Releases the field values, the captured outer
    /// instance, and the (cloned) class handle, then frees the field list.
    /// The class is part of the immutable program graph and is held alive by
    /// the module, so this only drops the instance's own clone of it;
    /// `native_state` is owned by its host binding.
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

    /// GC tracer: an instance references its class cell, owns one ref per field
    /// value, and (for an inner class) its captured outer.
    pub fn gcTrace(self: *const InstanceData, m: *objcell.gc.Marker) void {
        m.shade(&self.class.cell.hdr);
        for (self.fields.items) |f| f.value.gcMark(m);
        if (self.outer) |o| o.gcMark(m);
        for (self.anon_captures) |c| c.value.gcMark(m);
        for (self.anon_enclosing) |e| e.v.gcMark(m);
        if (self.stack) |s| m.shade(&s.cell.hdr);
        // `native_state` is host-owned; value-bearing bindings install a
        // NativeBox gc_trace (none today — kotlinx.io.Buffer is value-free).
    }

    /// GC finalizer (shallow): free only the field-list spine. Field values,
    /// the outer, and the class cell are independent cells swept on their own
    /// reachability, so they are NOT released here.
    pub fn gcFinalize(self: *InstanceData, allocator: std.mem.Allocator) void {
        if (self.anon_captures.len != 0) allocator.free(self.anon_captures);
        if (self.anon_enclosing.len != 0) allocator.free(self.anon_enclosing);
        if (!self.fields_foreign) self.fields.deinit(allocator);
    }

    /// Fetch the instance's native-state cell, creating it via `init` on
    /// first access. `T` is the host binding's concrete payload type and
    /// `kind` is its discriminator (convention: the binding's FQN). On a
    /// repeat call the cached cell is cloned and returned; the boxed
    /// payload can be reached through `nativeStatePtr`.
    ///
    /// Panics when the instance already carries native state under a
    /// different `kind`, which indicates two host bindings are fighting
    /// over the same instance.
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

    /// Downcast a native-state cell's boxed payload to `*T`. The caller
    /// must request the same `T` the cell was created with; mismatches
    /// are guarded by the cell's `kind` at the call site that produced it.
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

/// Native-side data attached to a `Value::Instance`. The `kind`
/// discriminator is the FQN of the owning native binding (e.g.
/// `"kotlinx.io.Buffer"`); the runtime guards downcasts against a kind
/// mismatch. The payload is an opaque, refcounted, lock-protected handle.
pub const NativeState = struct {
    kind: []const u8,
    data: ObjRef(NativeBox),
};

/// Opaque, lock-protected native payload. `ptr` is the host binding's
/// boxed value; the binding alone knows its concrete type and how to
/// free it via `destroy`, which runs when the last `ObjRef` clone drops.
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

/// Return a fresh clone of the resolved parent `ClassDef` handle, or null.
fn parentClone(cls: *const ClassDef) ?ObjRef(ClassDef) {
    return if (cls.parent) |p| p.clone() else null;
}

/// Return a fresh clone of the enclosing `ClassDef` handle, or null.
fn enclosingClone(cls: *const ClassDef) ?ObjRef(ClassDef) {
    const g = cls.enclosing_class.borrow();
    defer g.deinit();
    return if (g.get().*) |e| e.clone() else null;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

/// A `ClassDef` wrapped in an `ObjRef` plus the inner cells it owns, so a
/// test can tear everything down with `deinit`. The owned `methods` and
/// `body_properties` slices are kept here for the same reason — `ClassDef`
/// has no destructor; it is arena-owned.
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

    /// Link `parent` as this class's resolved superclass.
    fn setParent(self: *const ClassFixture, parent: ObjRef(ClassDef)) void {
        self.ptr().parent = parent.clone();
    }

    fn deinit(self: *ClassFixture, allocator: std.mem.Allocator) void {
        _ = allocator;
        const cd = self.ptr();
        // `parent`/`interfaces`/`enum_entries`/`nested_classes`/
        // `supertype_delegates`/`delegate_forwarders` are now plain immutable
        // slices/optionals (arena-owned in the runtime). Release only the
        // resolved-handle clones the fixture installed; the empty slices own
        // no backing buffer.
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
        // The `Env` cell is shared with `captured_env`; its last `deinit`
        // runs `Env.deinit` automatically.
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

/// A `Function` AST node with a body, so `findMethod` treats a `MethodDef`
/// built over it as concrete.
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

    // define on an existing name overwrites without growing the list.
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

    // Inner instance B (strong count 1, holding one clone of the class).
    const b = try objcell.ObjRef(InstanceData).init(allocator, .{
        .class = fx.handle.clone(),
        .fields = .empty,
        .outer = null,
        .identity = 1,
        .native_state = null,
    });
    const b_val = Value{ .Instance = b };

    // Outer instance A storing B as a field. The store retains B (count 2).
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

    // Releasing A drops to zero → its deinit releases field B (2 → 1) and
    // A's class clone. Releasing the local B handle drops it to zero → freed.
    // `testing.allocator` asserts the whole graph is reclaimed with no leak
    // and no double-free.
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

    // Releasing the list (its last owner) releases the element (2 → 1) and
    // frees the backing array; releasing the local handle frees the instance.
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

    // Own method resolves to the declaring class.
    const own = ClassDef.findMethod(child_fx.handle, allocator, "speak").?;
    var own_hit = own;
    defer own_hit.class.deinit();
    try testing.expectEqualStrings("speak", own_hit.method.name);
    {
        const g = own_hit.class.borrow();
        defer g.deinit();
        try testing.expectEqualStrings("Derived", g.get().name);
    }

    // Inherited method resolves through the parent link.
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

    // Unknown arg type falls back to the first matching name.
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

    // Bind `Base` in the derived class's captured env so the name walk
    // can resolve it to a `Value::Class`.
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

    // Give each class a companion instance.
    const parent_comp = try ObjRef(InstanceData).init(allocator, .{
        .class = parent_fx.handle.clone(),
        .fields = .empty,
        .outer = null,
        .identity = 1,
        .native_state = null,
    });
    // `InstanceData.deinit` releases the instance's class clone, so the
    // ObjRef drop reclaims the whole instance.
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
    // Self first, then parent.
    try testing.expect(ObjRef(InstanceData).ptrEq(comps[0], child_comp));
    try testing.expect(ObjRef(InstanceData).ptrEq(comps[1], parent_comp));
}

test "TypeShape from a generic, nullable type ref" {
    const allocator = testing.allocator;

    // Build `Map<String, Item?>` with a star-projected arg to verify it is
    // skipped: `Map<String, *>`-style mixing is collapsed.
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
    // Same name POINTERS in the same order => same id, values irrelevant.
    try testing.expectEqual(sa, b.shapeOf());
    // Memoized.
    try testing.expectEqual(sa, a.shapeOf());

    // Append changes the layout: id resets and re-interns differently.
    try b.fields.append(allocator, .{ .name = n2, .value = .Unit });
    b.shape.store(SHAPE_UNSET, .release);
    const sb2 = b.shapeOf();
    try testing.expect(sb2 != sa and sb2 != SHAPE_UNSET and sb2 != SHAPE_NONE);
    // And the two-field layout interns stably too.
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

    // Mutate through the boxed payload, then re-ensure: same cell, same data.
    InstanceData.nativeStatePtr(Payload, first).n = 99;
    const second = try inst.ensureNativeState(allocator, Payload, "kotlinx.io.Buffer", mk.make);
    defer second.deinit();
    try testing.expect(ObjRef(NativeBox).ptrEq(first, second));
    try testing.expectEqual(@as(u32, 99), InstanceData.nativeStatePtr(Payload, second).n);
}
