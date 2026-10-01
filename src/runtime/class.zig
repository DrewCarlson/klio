//! Declared Kotlin classes at runtime: `ClassDef` and its descriptors, the
//! live `InstanceData`, and the method and property resolution walks.

const std = @import("std");
const builtin = @import("builtin");
const ast = @import("ast");
const span = @import("span");
const objcell = @import("objcell.zig");
const gc_mod = @import("gc.zig");
const env_mod = @import("env.zig");
const value_mod = @import("value.zig");
const forest = @import("forest.zig");

const ObjRef = objcell.ObjRef;
const Env = env_mod.Env;
const Value = value_mod.Value;

pub const ClassDef = struct {
    /// Written only while it is made, before any other thread or the collector
    /// can reach it, so the reader lock is elided and a concurrent mark reads
    /// it freely. The cells it holds (`companion`, `object_singleton`, ...) are
    /// cells of their own, each behind its own lock.
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
    /// Whether an instance's slot accesses order as a `@Volatile` field's do:
    /// the class or an ancestor declares a `@Volatile` property, or it is a
    /// class the lowering did not lay out. Otherwise, where the build's
    /// processor copies a slot whole in one access (`plain_slots`), its
    /// instances take plain loads and stores, as a JVM field not `@Volatile`
    /// does.
    ordered_slots: bool = true,
    has_primary_ctor: bool = true,
    is_annotation: bool = false,
    is_sealed: bool,
    supertype_names: []const []const u8,
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
    companion: ObjRef(?ObjRef(InstanceData)),
    enclosing_class: ObjRef(?ObjRef(ClassDef)),
    nested_classes: []const NestedClass,
    captured_env: ObjRef(Env),
    supertype_delegates: []const SupertypeDelegate,
    delegate_forwarders: []const MethodDef,
    object_singleton: ObjRef(?ObjRef(InstanceData)),

    /// The `ClassId` of this class in code lowered from sema, which the
    /// bridge assigns; `maxInt(u32)` for a class that code never makes.
    ir_class: u32 = std.math.maxInt(u32),

    /// The slots an instance holds, base classes first; program-lifetime.
    /// Seeds are scalars or null, so they hold no cell the collector must
    /// trace.
    layout_slots: []const LayoutSlot = &.{},

    pub const EnumEntry = struct {
        name: []const u8,
        value: Value,
        annotation_records: []const AnnotationRecord = &.{},
    };
    pub const NestedClass = struct { name: []const u8, class: ObjRef(ClassDef) };

    pub const MAX_WALK = 128;

    /// A class only code lowered from sema makes: display names and its
    /// `ir_class`, every by-name table empty.
    pub fn minimal(allocator: std.mem.Allocator, name: []const u8, fqn: []const u8, ir_class: u32) !ObjRef(ClassDef) {
        return ObjRef(ClassDef).init(allocator, .{
            .name = name,
            .fqn = fqn,
            .annotation_names = &.{},
            .primary_params = &.{},
            .methods = &.{},
            .body_properties = &.{},
            .init_blocks = &.{},
            .init_block_property_positions = &.{},
            .is_data = false,
            .is_value = false,
            .is_object = false,
            .is_enum = false,
            .is_sealed = false,
            .supertype_names = &.{},
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
            .captured_env = try ObjRef(Env).init(allocator, Env.init(allocator)),
            .supertype_delegates = &.{},
            .delegate_forwarders = &.{},
            .object_singleton = try ObjRef(?ObjRef(InstanceData)).init(allocator, null),
            .ir_class = ir_class,
        });
    }

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

/// Whether this build may run on a processor that loads and stores 16 aligned
/// bytes in one access no other can split, so a slot not ordered as a
/// `@Volatile` one is read and written plainly and never torn: AArch64 with
/// LSE2, and x86-64, whose processors that enumerate AVX make an aligned SSE
/// access of 16 bytes one (`plainSlotsOn` asks the processor). The access is
/// written in inline assembly only LLVM's assembler takes (Zig's own x86-64
/// backend, a Debug build's on Linux, has no form for it). Anywhere else every
/// slot takes the ordered protocol.
pub const plain_slots: bool = builtin.zig_backend == .stage2_llvm and
    ((builtin.cpu.arch == .aarch64 and std.Target.aarch64.featureSetHas(builtin.cpu.features, .lse2)) or builtin.cpu.arch == .x86_64);

/// Whether this processor copies a slot whole in one access (`plain_slots`):
/// on x86-64, whether it enumerates AVX, which `KLIO_PLAIN_SLOTS` (`0` or
/// `1`) overrides for a test on one that does not report it.
pub fn plainSlotsOn() bool {
    if (comptime !plain_slots) return false;
    if (comptime builtin.cpu.arch != .x86_64) return true;
    return switch (x86_plain.load(.monotonic)) {
        0 => x86PlainInit(),
        1 => false,
        else => true,
    };
}

/// 0 until asked, then 1 for no and 2 for yes.
var x86_plain: std.atomic.Value(u8) = .init(0);

fn x86PlainInit() bool {
    const on = if (objcell.envOnce("KLIO_PLAIN_SLOTS")) |v| !std.mem.eql(u8, v, "0") else x86Avx();
    x86_plain.store(if (on) 2 else 1, .monotonic);
    return on;
}

/// CPUID leaf 1's AVX bit (ECX bit 28).
fn x86Avx() bool {
    if (comptime builtin.cpu.arch != .x86_64) return false;
    var ecx: u32 = undefined;
    asm volatile ("cpuid"
        : [c] "={ecx}" (ecx),
        : [leaf] "{eax}" (@as(u32, 1)),
          [sub] "{ecx}" (@as(u32, 0)),
        : .{ .rbx = true, .rdx = true, .rax = true });
    return ecx & (1 << 28) != 0;
}

/// In `InstanceData.slot_seq`: the instance's slots are plain (`plain_slots`).
/// Set when it is made and never changed; an ordered instance's sequence
/// runs in the bits below it.
pub const PLAIN_SLOTS: u32 = 1 << 31;

/// Slot `slot`'s 16 bytes in one access.
inline fn load16(slot: *const Value) Value {
    var lo: u64 = undefined;
    var hi: u64 = undefined;
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile (
            \\movdqa (%[p]), %%xmm15
            \\movq %%xmm15, %[a]
            \\punpckhqdq %%xmm15, %%xmm15
            \\movq %%xmm15, %[b]
            : [a] "=&r" (lo),
              [b] "=&r" (hi),
            : [p] "r" (slot),
            : .{ .memory = true, .xmm15 = true });
    } else asm volatile ("ldp %[a], %[b], [%[p]]"
        : [a] "=&r" (lo),
          [b] "=&r" (hi),
        : [p] "r" (slot),
        : .{ .memory = true });
    var out: Value = undefined;
    const w: *[2]u64 = @ptrCast(&out);
    w[0] = lo;
    w[1] = hi;
    return out;
}

/// `v` into slot `slot` in one access.
inline fn store16(slot: *Value, v: Value) void {
    const w: *const [2]u64 = @ptrCast(&v);
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile (
            \\movq %[a], %%xmm14
            \\movq %[b], %%xmm15
            \\punpcklqdq %%xmm15, %%xmm14
            \\movdqa %%xmm14, (%[p])
            :
            : [a] "r" (w[0]),
              [b] "r" (w[1]),
              [p] "r" (slot),
            : .{ .memory = true, .xmm14 = true, .xmm15 = true });
    } else asm volatile ("stp %[a], %[b], [%[p]]"
        :
        : [a] "r" (w[0]),
          [b] "r" (w[1]),
          [p] "r" (slot),
        : .{ .memory = true });
}

/// Orders every store before it before every store after it, as the JVM
/// orders an object's initialization before its publication: a plain slot
/// store of a reference publishes what it points to.
inline fn publishFence() void {
    // x86-64 keeps stores in order.
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile ("" ::: .{ .memory = true });
    } else asm volatile ("dmb ishst" ::: .{ .memory = true });
}

/// One slot of a class's layout: its name, and the value it holds until an
/// initializer replaces it — the JVM zero of a declared primitive, null
/// otherwise.
pub const LayoutSlot = struct {
    name: []const u8,
    seed: Value = .Null,
};

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
/// `KLIO_GC_VERIFY`: for an instance holding an edge no write barrier
/// recorded, its class and the field that holds the target.
pub fn describeGcEdge(from: *gc_mod.GcHeader, to: *gc_mod.GcHeader) void {
    const Ref = objcell.ObjRef(InstanceData);
    if (!std.mem.eql(u8, std.mem.span(from.typeName()), @typeName(InstanceData))) return;
    const cb: *Ref.Cell = @fieldParentPtr("hdr", @as(*align(16) gc_mod.GcHeader, @alignCast(from)));
    const d = &cb.data;
    const cls = d.class.asPtrConst();
    for (d.slots, 0..) |v, i| {
        if (v != .Instance) continue;
        if (&v.Instance.cell.hdr != @as(*align(16) gc_mod.GcHeader, @alignCast(to))) continue;
        const name = if (i < cls.layout_slots.len) cls.layout_slots[i].name else "?";
        const tcls = v.Instance.asPtrConst().class.asPtrConst().name;
        std.debug.print("[gc-verify]   {s}.{s} holds a {s}\n", .{ cls.name, name, tcls });
        return;
    }
    std.debug.print("[gc-verify]   {s}: the edge is outside its slots (its stack or native state)\n", .{cls.name});
}

/// The identity the last instance to take one took (`InstanceData.identityOf`).
var next_identity: std.atomic.Value(u64) = .init(0);

pub const InstanceData = struct {
    class: ObjRef(ClassDef),
    /// One value per slot of the class's layout, fixed at construction. The
    /// class's `layout_slots` names them; nothing adds a slot later.
    slots: []Value,
    /// Odd while a slot store is in flight. A read copies a slot between two
    /// equal even readings, so it never sees half of a store; stores to one
    /// instance take turns. A `Value` is two words, so an unsynchronized read
    /// could pair one store's tag with another's payload.
    slot_seq: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// The class's id in the tables of code lowered from sema, written once
    /// at construction; `maxInt` for an instance they do not cover.
    class_id: u32 = std.math.maxInt(u32),
    /// What few instances carry (`Extra`), made on the first need; null for the rest, so
    /// every instance does not pay for them.
    extra: ?*Extra = null,

    /// A host-backed instance's native state and a throwable's stack, apart from the cell.
    pub const Extra = struct {
        native_state: ?NativeState = null,
        /// For a user `Throwable` subclass, the stack captured at the first throw.
        stack: ?value_mod.StackRef = null,
    };

    /// The instance's identity, taken the first time anything asks, as the JVM
    /// takes an identity hash: an instance nothing hashes or prints takes none, and
    /// making one touches no counter every thread shares. Racing first asks agree.
    /// It lives in the header's spare word, 32 bits as `hashCode` is, 0 until taken.
    pub fn identityOf(self: *const InstanceData) u64 {
        const p = identityWord(self);
        const cur = @atomicLoad(u32, p, .monotonic);
        if (cur != 0) return cur;
        const id = takeIdentity();
        return @cmpxchgStrong(u32, p, 0, id, .monotonic, .monotonic) orelse id;
    }

    /// The identity a host numbers its own instances with, set as it makes one.
    pub fn setIdentity(self: *InstanceData, id: u64) void {
        const w: u32 = @truncate(id);
        @atomicStore(u32, identityWord(self), w, .monotonic);
    }

    fn identityWord(self: *const InstanceData) *u32 {
        const cell: *const ObjRef(InstanceData).Cell = @alignCast(@fieldParentPtr("data", self));
        return @constCast(&cell.hdr.gc_aux);
    }

    /// The next identity: the counter's low word, never 0, which means none yet.
    fn takeIdentity() u32 {
        const n: u32 = @truncate(next_identity.fetchAdd(1, .monotonic) + 1);
        return if (n == 0) 1 else n;
    }

    /// The counter `identityOf` takes from, for compiled code that takes one itself.
    pub fn identityCounter() *std.atomic.Value(u64) {
        return &next_identity;
    }

    /// The stack a throwable subclass's instance captured at its first throw.
    pub fn stackRef(self: *const InstanceData) ?value_mod.StackRef {
        return if (self.extra) |e| e.stack else null;
    }

    /// The native state a host binding keeps on the instance.
    pub fn nativeState(self: *const InstanceData) ?NativeState {
        return if (self.extra) |e| e.native_state else null;
    }

    /// Under the instance's exclusive borrow: the stack its first throw captured.
    pub fn setStack(self: *InstanceData, s: ?value_mod.StackRef) std.mem.Allocator.Error!void {
        (try self.extraOf()).stack = s;
    }

    /// The instance's `Extra`, made in its cell's allocator on the first need, under its
    /// exclusive borrow.
    fn extraOf(self: *InstanceData) std.mem.Allocator.Error!*Extra {
        if (self.extra) |e| return e;
        const cell: *ObjRef(InstanceData).Cell = @alignCast(@fieldParentPtr("data", self));
        const e = try cell.allocatorOf().create(Extra);
        e.* = .{};
        self.extra = e;
        if (objcell.gc.gc_enabled) objcell.gc.noteFinalizable(&cell.hdr);
        return e;
    }

    /// A named value a host instance is made from: the name becomes its
    /// class's slot name.
    pub const Field = struct { name: []const u8, value: Value };

    /// A call site's memo of the slot a name has in the class it last met:
    /// the class's identity above the low `cache_index_bits`, the index in
    /// them. One word, so a racing fill can never pair a class with another
    /// class's index.
    pub const SlotCache = std.atomic.Value(u64);
    const cache_index_bits = 12;
    const cache_index_mask: u64 = (1 << cache_index_bits) - 1;

    /// A new instance of `class`, whose handle it adopts, with slots holding
    /// `values`, adopting one reference to each. The caller owns the one
    /// reference returned.
    pub fn new(a: std.mem.Allocator, class: ObjRef(ClassDef), values: []const Value, identity: u64) std.mem.Allocator.Error!ObjRef(InstanceData) {
        const inst = try newTrailing(a, class, class.asPtrConst().ir_class, values.len);
        inst.cell.data.setIdentity(identity);
        @memcpy(inst.cell.data.slots, values);
        return inst;
    }

    /// An instance of one class as `new` lays it out: its cell with the
    /// class and its id, and every slot holding its seed, copied whole into
    /// a fresh region hole before its slots are set.
    pub const Template = struct {
        image: []align(16) u8,
        n_slots: u32,

        comptime {
            // A copy's slots start at a 16-byte boundary, as a plain slot needs.
            std.debug.assert(@sizeOf(ObjRef(InstanceData).Cell) % 16 == 0);
        }

        pub fn init(a: std.mem.Allocator, class: ObjRef(ClassDef), class_id: u32, seeds: []const Value) std.mem.Allocator.Error!*Template {
            const Cell = ObjRef(InstanceData).Cell;
            const bytes = @sizeOf(Cell) + seeds.len * @sizeOf(Value);
            const image = try a.alignedAlloc(u8, .of(Cell), bytes);
            errdefer a.free(image);
            ObjRef(InstanceData).regionImage(@ptrCast(image.ptr), .{
                .class = class,
                .slots = &.{},
                .slot_seq = .init(seqOf(class)),
                .class_id = class_id,
            }, bytes);
            const slots: [*]Value = @ptrCast(@alignCast(image.ptr + @sizeOf(Cell)));
            @memcpy(slots[0..seeds.len], seeds);
            // The count is the class's; `make` points the slots at the copy's.
            const made: *Cell = @ptrCast(image.ptr);
            made.data.slots = slots[0..seeds.len];
            const t = try a.create(Template);
            t.* = .{ .image = image, .n_slots = @intCast(seeds.len) };
            return t;
        }

        pub fn deinit(t: *Template, a: std.mem.Allocator) void {
            a.free(t.image);
            a.destroy(t);
        }

        /// A new instance from the template in this thread's region hole,
        /// or null when it has none to give.
        pub inline fn make(t: *const Template) ?ObjRef(InstanceData) {
            const inst = ObjRef(InstanceData).fromImage(t.image) orelse return null;
            const base: [*]u8 = @ptrCast(inst.cell);
            const slots: [*]Value = @ptrCast(@alignCast(base + @sizeOf(ObjRef(InstanceData).Cell)));
            inst.cell.data.slots = slots[0..t.n_slots];
            return inst;
        }
    };

    /// A new instance of `class` with `n` slots in its own cell, for the
    /// caller to fill before anything else sees it.
    pub fn newTrailing(a: std.mem.Allocator, class: ObjRef(ClassDef), class_id: u32, n: usize) std.mem.Allocator.Error!ObjRef(InstanceData) {
        return ObjRef(InstanceData).initTrailing(a, .{
            .class = class,
            .slots = &.{},
            .slot_seq = .init(seqOf(class)),
            .class_id = class_id,
        }, n);
    }

    /// The sequence an instance of `class` starts with: `PLAIN_SLOTS` when its
    /// slots are plain.
    pub fn seqOf(class: ObjRef(ClassDef)) u32 {
        return if (plain_slots and !class.asPtrConst().ordered_slots and plainSlotsOn()) PLAIN_SLOTS else 0;
    }

    /// Slot `i` of `inst`, or null past its slots. Takes no lock.
    pub inline fn slotGet(inst: ObjRef(InstanceData), i: usize) ?Value {
        return inst.cell.data.loadSlot(i);
    }

    /// Stores `v` in slot `i` of `inst` and answers the value it replaced,
    /// taking no reference; null, storing nothing, past its slots.
    pub inline fn slotSet(inst: ObjRef(InstanceData), i: usize, v: Value) ?Value {
        return inst.cell.data.storeSlot(i, v);
    }

    /// The header of the cell this payload lives in: every instance is a cell.
    inline fn cellHdr(self: *InstanceData) *gc_mod.GcHeader {
        const cb: *ObjRef(InstanceData).Cell = @alignCast(@fieldParentPtr("data", self));
        return &cb.hdr;
    }

    /// Slot `i`, copied whole, or null past the slots. The collector never
    /// runs inside `storeSlot`, which holds no safe point.
    pub inline fn loadSlot(self: *const InstanceData, i: usize) ?Value {
        if (i >= self.slots.len) return null;
        if (comptime plain_slots) {
            if (self.slot_seq.load(.monotonic) & PLAIN_SLOTS != 0) return load16(&self.slots[i]);
        }
        const words: *const [2]u64 = @ptrCast(&self.slots[i]);
        while (true) {
            const before = self.slot_seq.load(.acquire);
            if (before & 1 == 0) {
                // Acquire loads keep the second reading after both words, and
                // one that saw a word of a later store sees that store's odd
                // sequence.
                const w0 = @atomicLoad(u64, &words[0], .acquire);
                const w1 = @atomicLoad(u64, &words[1], .acquire);
                if (self.slot_seq.load(.monotonic) == before) {
                    var out: Value = undefined;
                    const dst: *[2]u64 = @ptrCast(&out);
                    dst[0] = w0;
                    dst[1] = w1;
                    return out;
                }
            }
            std.atomic.spinLoopHint();
        }
    }

    /// Stores `v` in slot `i` and answers the value it replaced, taking no
    /// reference; null past the slots. Slot stores take no cell lock, so each
    /// records the write barrier itself, and only for a value that holds a
    /// cell: a scalar makes no edge for a minor to find or a major to retrace.
    /// The barrier may come before the store because the remembered set is
    /// read only inside a stop, and no stop falls between the two.
    pub fn storeSlot(self: *InstanceData, i: usize, v: Value) ?Value {
        if (i >= self.slots.len) return null;
        recordStore(self.cellHdr(), v);
        if (comptime plain_slots) {
            if (self.slot_seq.load(.monotonic) & PLAIN_SLOTS != 0) {
                const old = load16(&self.slots[i]);
                if (!v.isNumberOrBool()) publishFence();
                store16(&self.slots[i], v);
                return old;
            }
        }
        const seq = self.holdStores();
        const old = self.slots[i];
        writeWhole(&self.slots[i], v);
        self.slot_seq.store(nextSeq(seq), .release);
        return old;
    }

    /// The even sequence after the store turn taken at `seq`, wrapping below
    /// `PLAIN_SLOTS`.
    inline fn nextSeq(seq: u32) u32 {
        return (seq + 2) & ~PLAIN_SLOTS;
    }

    /// The write barrier for storing `v` into the instance whose cell is `h`:
    /// a nursery instance needs none, and a number or a boolean makes no
    /// edge. That test is one compare; a char or null, which make no edge
    /// either, record the barrier as a reference does.
    inline fn recordStore(h: *gc_mod.GcHeader, v: Value) void {
        if (h.gc_gen == 0 or v.isNumberOrBool()) return;
        gc_mod.writeBarrier(h);
    }

    /// Takes the store turn: the even sequence it made odd.
    fn holdStores(self: *InstanceData) u32 {
        var seq = self.slot_seq.load(.monotonic);
        while (true) {
            if (seq & 1 == 0) {
                seq = self.slot_seq.cmpxchgWeak(seq, seq + 1, .acquire, .monotonic) orelse return seq;
            } else {
                std.atomic.spinLoopHint();
                seq = self.slot_seq.load(.monotonic);
            }
        }
    }

    /// Release stores, so a read that sees either word of this store also
    /// sees the odd sequence that precedes it.
    inline fn writeWhole(slot: *Value, v: Value) void {
        const src: *const [2]u64 = @ptrCast(&v);
        const words: *[2]u64 = @ptrCast(slot);
        @atomicStore(u64, &words[0], src[0], .release);
        @atomicStore(u64, &words[1], src[1], .release);
    }

    /// Holds off every other store to the instance's slots until `end`, for
    /// a read-modify-write no store may split. Reads on other threads wait
    /// for the end; the holder must not read the instance through
    /// `loadSlot` meanwhile, and must reach no safe point. Each store the
    /// update makes records its own barrier, as `storeSlot` does. Only for an
    /// instance whose slots are ordered, as an atomic's are: a plain store
    /// takes no turn.
    pub fn beginUpdate(self: *InstanceData) SlotUpdate {
        std.debug.assert(self.slot_seq.load(.monotonic) & PLAIN_SLOTS == 0);
        return .{ .data = self, .seq = self.holdStores() };
    }

    pub const SlotUpdate = struct {
        data: *InstanceData,
        seq: u32,

        pub fn get(self: SlotUpdate, name: []const u8) ?Value {
            return self.data.slots[self.data.slotIndex(name) orelse return null];
        }

        /// As `InstanceData.set`.
        pub fn set(self: SlotUpdate, name: []const u8, v: Value) bool {
            const slot = &self.data.slots[self.data.slotIndex(name) orelse return false];
            recordStore(self.data.cellHdr(), v);
            writeWhole(slot, v);
            return true;
        }

        /// As `InstanceData.store`.
        pub fn store(self: SlotUpdate, allocator: std.mem.Allocator, name: []const u8, v: Value) bool {
            const slot = &self.data.slots[self.data.slotIndex(name) orelse return false];
            const old = slot.*;
            recordStore(self.data.cellHdr(), v);
            writeWhole(slot, v);
            if (objcell.reclaimEnabled()) old.release(allocator);
            return true;
        }

        pub fn end(self: SlotUpdate) void {
            self.data.slot_seq.store(nextSeq(self.seq), .release);
        }
    };

    /// The slot the class's layout names `name`, or null.
    pub fn slotIndex(self: *const InstanceData, name: []const u8) ?usize {
        const layout = self.class.asPtrConst().layout_slots;
        const names = layout[0..@min(layout.len, self.slots.len)];
        // Slot names are program-lifetime strings, so the same pointer is the
        // same name; `eql` covers a name spelled elsewhere.
        for (names, 0..) |sl, i| {
            if (sl.name.ptr == name.ptr and sl.name.len == name.len) return i;
        }
        for (names, 0..) |sl, i| {
            if (std.mem.eql(u8, sl.name, name)) return i;
        }
        return null;
    }

    /// `slotIndex` through the call site's memo of the last class it met.
    pub fn slotIndexCached(self: *const InstanceData, cache: *SlotCache, name: []const u8) ?usize {
        const class_key: u64 = self.class.identity();
        const memo = cache.load(.monotonic);
        if (memo != 0 and memo >> cache_index_bits == class_key) return @intCast(memo & cache_index_mask);
        const i = self.slotIndex(name) orelse return null;
        if (i <= cache_index_mask and class_key >> (64 - cache_index_bits) == 0) {
            cache.store(class_key << cache_index_bits | i, .monotonic);
        }
        return i;
    }

    /// The value of the slot named `name`, or null when the class has none.
    pub fn get(self: *const InstanceData, name: []const u8) ?Value {
        return self.loadSlot(self.slotIndex(name) orelse return null);
    }

    /// `get` through the call site's slot memo.
    pub fn getCached(self: *const InstanceData, cache: *SlotCache, name: []const u8) ?Value {
        return self.loadSlot(self.slotIndexCached(cache, name) orelse return null);
    }

    /// Stores `v` in the slot named `name`, taking no reference and keeping
    /// none to the replaced value; false when the class has no such slot.
    pub fn set(self: *InstanceData, name: []const u8, v: Value) bool {
        const i = self.slotIndex(name) orelse return false;
        _ = self.storeSlot(i, v);
        return true;
    }

    /// Adopts one owned reference to `v` into the slot named `name` and
    /// releases the value it replaces, so the instance owns exactly one
    /// reference per slot; false, adopting nothing, when the class has no
    /// such slot.
    pub fn store(self: *InstanceData, allocator: std.mem.Allocator, name: []const u8, v: Value) bool {
        const i = self.slotIndex(name) orelse return false;
        const old = self.storeSlot(i, v).?;
        if (objcell.reclaimEnabled()) old.release(allocator);
        return true;
    }

    /// The module keeps the class alive, so this drops only the instance's own
    /// clone; `native_state` belongs to its host binding.
    pub fn deinit(self: *InstanceData, allocator: std.mem.Allocator) void {
        for (self.slots) |v| v.release(allocator);
        if (self.slots.len != 0 and !self.slotsTrail()) allocator.free(self.slots);
        if (self.extra) |e| {
            if (e.stack) |*s| s.deinit();
            allocator.destroy(e);
        }
        self.class.deinit();
    }

    /// The class cell, one reference per slot, an inner class's outer, the
    /// throwable stack and the native-state box. Slot stores take no cell lock,
    /// so a mark running beside them reads each slot as `loadSlot` does, whole;
    /// every other field is written only while the instance is made or under
    /// its exclusive borrow.
    pub fn gcTrace(self: *const InstanceData, m: *objcell.gc.Marker) void {
        m.shade(&self.class.cell.hdr);
        for (0..self.slots.len) |i| self.loadSlot(i).?.gcMark(m);
        if (self.extra) |e| {
            if (e.stack) |s| m.shade(&s.cell.hdr);
            // The box is a cell; the state it points at is the binding's own.
            if (e.native_state) |ns| m.shade(&ns.data.cell.hdr);
        }
    }

    /// Shallow: the slot values, the outer and the class are independent cells
    /// swept on their own reachability.
    pub fn gcFinalize(self: *InstanceData, allocator: std.mem.Allocator) void {
        if (self.slots.len != 0 and !self.slotsTrail()) allocator.free(self.slots);
        if (self.extra) |e| allocator.destroy(e);
    }
    /// An instance takes its extra record later through `extraOf`, which
    /// puts a region cell on the lists then.
    pub fn gcNeedsFinalize(self: *const InstanceData) bool {
        return self.extra != null or (self.slots.len != 0 and !self.slotsTrail());
    }

    /// The slots an instance made by `newTrailing` keeps in its own cell,
    /// after it (`ObjRef.initTrailing`).
    pub const Trailing = Value;

    pub fn adoptTrailing(self: *InstanceData, slots: []Value) void {
        self.slots = slots;
        // A plain slot is one access only at a 16-byte boundary.
        if (plain_slots and @intFromPtr(slots.ptr) & 15 != 0) self.slot_seq.raw &= ~PLAIN_SLOTS;
    }

    /// Whether the slots are in the instance's cell, after it.
    pub fn slotsTrail(self: *const InstanceData) bool {
        const Cell = ObjRef(InstanceData).Cell;
        const cb: *const Cell = @alignCast(@fieldParentPtr("data", self));
        return self.slots.len != 0 and @intFromPtr(self.slots.ptr) == @intFromPtr(cb) + @sizeOf(Cell);
    }

    /// The bytes the cell's allocation holds after it.
    pub fn trailingBytes(self: *const InstanceData) usize {
        return if (self.slotsTrail()) self.slots.len * @sizeOf(Value) else 0;
    }

    /// Created through `init` on first access, under the instance's exclusive
    /// borrow. `kind` is the binding's discriminator; panics when the instance
    /// already carries another kind.
    pub fn ensureNativeState(
        inst: ObjRef(InstanceData),
        allocator: std.mem.Allocator,
        comptime T: type,
        kind: []const u8,
        init: *const fn () T,
    ) std.mem.Allocator.Error!ObjRef(NativeBox) {
        const g = inst.borrowMut();
        defer g.deinit();
        const self = g.get();
        if (self.nativeState()) |ns| {
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
        (try self.extraOf()).native_state = .{ .kind = kind, .data = data.clone() };
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
    };
}

test "InstanceData reads and writes a slot by the name its class's layout gives it" {
    const allocator = testing.allocator;
    var fx = try ClassFixture.build(allocator, "Foo", &.{}, &.{}, &.{});
    defer fx.deinit(allocator);
    const layout = [_]LayoutSlot{ .{ .name = "x" }, .{ .name = "y" } };
    fx.ptr().layout_slots = &layout;

    const inst = try InstanceData.new(allocator, fx.handle.clone(), &.{ .Null, .{ .Int = 1 } }, 0);
    defer inst.deinit();
    const d = inst.asPtr();

    try testing.expect(d.get("z") == null);
    try testing.expect(!d.set("z", .{ .Int = 1 }));
    try testing.expect(!d.store(allocator, "z", .{ .Int = 1 }));
    try testing.expectEqual(@as(usize, 2), d.slots.len);

    try testing.expect(d.store(allocator, "x", .{ .Int = 7 }));
    try testing.expectEqual(@as(i32, 7), d.get("x").?.Int);
    try testing.expect(d.set("x", .{ .Int = 9 }));
    try testing.expectEqual(@as(i32, 9), InstanceData.slotGet(inst, 0).?.Int);
    try testing.expectEqual(@as(i32, 1), d.get("y").?.Int);

    // The memo answers the class it saw, and a spelling at another address.
    var cache: InstanceData.SlotCache = .init(0);
    const y: []const u8 = "yy"[0..1];
    try testing.expectEqual(@as(?usize, 1), d.slotIndexCached(&cache, y));
    try testing.expect(cache.load(.monotonic) != 0);
    try testing.expectEqual(@as(i32, 1), d.getCached(&cache, "y").?.Int);
}

test "an instance's slots are in its own cell, and go with it" {
    const allocator = testing.allocator;
    var fx = try ClassFixture.build(allocator, "Foo", &.{}, &.{}, &.{});
    defer fx.deinit(allocator);
    const layout = [_]LayoutSlot{ .{ .name = "x" }, .{ .name = "y" } };
    fx.ptr().layout_slots = &layout;
    const inst = try InstanceData.new(allocator, fx.handle.clone(), &.{ .{ .Int = 3 }, .{ .Int = 4 } }, 0);
    defer inst.deinit();
    const d = inst.asPtr();
    try testing.expect(d.slotsTrail());
    try testing.expectEqual(@intFromPtr(inst.cell) + @sizeOf(ObjRef(InstanceData).Cell), @intFromPtr(d.slots.ptr));
    try testing.expectEqual(@as(usize, 2 * @sizeOf(Value)), d.trailingBytes());
    try testing.expectEqual(@as(i32, 4), d.get("y").?.Int);
    // An instance with no slots has nothing after its cell.
    const empty = try InstanceData.new(allocator, fx.handle.clone(), &.{}, 1);
    defer empty.deinit();
    try testing.expect(!empty.asPtr().slotsTrail());
    try testing.expectEqual(@as(usize, 0), empty.asPtr().trailingBytes());
}

test "instance release recursively frees a retained instance field" {
    const allocator = testing.allocator;
    var fx = try ClassFixture.build(allocator, "Foo", &.{}, &.{}, &.{});
    defer fx.deinit(allocator);
    const layout = [_]LayoutSlot{.{ .name = "b" }};

    const b = try InstanceData.new(allocator, fx.handle.clone(), &.{}, 1);
    const b_val = Value{ .Instance = b };
    b_val.retain();
    fx.ptr().layout_slots = &layout;
    const a = try InstanceData.new(allocator, fx.handle.clone(), &.{b_val}, 2);
    const a_val = Value{ .Instance = a };

    // `testing.allocator` asserts the whole graph is reclaimed.
    a_val.release(allocator);
    b_val.release(allocator);
}

test "list release recursively frees retained instance elements" {
    const allocator = testing.allocator;
    var fx = try ClassFixture.build(allocator, "Foo", &.{}, &.{}, &.{});
    defer fx.deinit(allocator);

    const inst = try ObjRef(InstanceData).init(allocator, .{
        .class = fx.handle.clone(),
        .slots = &.{},
    });
    inst.cell.data.setIdentity(1);
    const inst_val = Value{ .Instance = inst };

    var arr: std.ArrayList(Value) = .empty;
    inst_val.retain(); // storing into the list retains the element (count 2)
    try arr.append(allocator, inst_val);
    const items = try ObjRef(std.ArrayList(Value)).init(allocator, arr);
    const list_val = try Value.newList(allocator, .{ .items = items, .mutable = true, .enum_entries = false, .backing = null });

    list_val.release(allocator);
    inst_val.release(allocator);
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

    const inst = try InstanceData.new(allocator, fx.handle.clone(), &.{}, 0);
    defer {
        if (inst.asPtrConst().nativeState()) |ns| ns.data.deinit();
        inst.deinit();
    }

    const first = try InstanceData.ensureNativeState(inst, allocator, Payload, "kotlinx.io.Buffer", mk.make);
    defer first.deinit();
    try testing.expectEqual(@as(u32, 42), InstanceData.nativeStatePtr(Payload, first).n);

    InstanceData.nativeStatePtr(Payload, first).n = 99;
    const second = try InstanceData.ensureNativeState(inst, allocator, Payload, "kotlinx.io.Buffer", mk.make);
    defer second.deinit();
    try testing.expect(ObjRef(NativeBox).ptrEq(first, second));
    try testing.expectEqual(@as(u32, 99), InstanceData.nativeStatePtr(Payload, second).n);
}

test "every slot store path records the barrier for a reference and none for a scalar" {
    const allocator = testing.allocator;
    var fx = try ClassFixture.build(allocator, "Holder", &.{}, &.{}, &.{});
    defer fx.deinit(allocator);
    const layout = [_]LayoutSlot{.{ .name = "x" }};
    fx.ptr().layout_slots = &layout;
    const text = try value_mod.strInit(allocator, "held");
    defer text.deinit();
    const Case = enum { set, store, update_set, update_store };
    for ([_]bool{ true, false }) |reference| {
        for ([_]Case{ .set, .store, .update_set, .update_store }) |case| {
            const inst = try InstanceData.new(allocator, fx.handle.clone(), &.{.Null}, 0);
            defer inst.deinit();
            const hdr = &inst.cell.hdr;
            defer gc_mod.forgetRanges(&.{.{ .start = @intFromPtr(hdr), .len = @sizeOf(gc_mod.GcHeader) }});
            hdr.gc_gen = 1;
            hdr.gc_remembered = false;
            // The payload pointer, as a host op holding no borrow has it.
            const d = &inst.cell.data;
            const name = "x";
            const v: Value = if (reference) .{ .String = text } else .{ .Int = 1 };
            switch (case) {
                .set => try testing.expect(d.set(name, v)),
                // A store releases what it replaced, so the slot starts null
                // and ends without the reference it borrowed.
                .store => {
                    try testing.expect(d.store(allocator, name, v));
                    d.slots[0] = .Null;
                },
                .update_set => {
                    const u = d.beginUpdate();
                    defer u.end();
                    try testing.expect(u.set(name, v));
                },
                .update_store => {
                    const u = d.beginUpdate();
                    defer u.end();
                    try testing.expect(u.store(allocator, name, v));
                    d.slots[0] = .Null;
                },
            }
            try testing.expectEqual(reference, hdr.gc_remembered);
        }
    }
}

test "a slot store into a tenured instance joins the remembered set" {
    const allocator = testing.allocator;
    var fx = try ClassFixture.build(allocator, "Holder", &.{}, &.{}, &.{});
    defer fx.deinit(allocator);
    const inst = try InstanceData.new(allocator, fx.handle.clone(), &.{.Null}, 0);
    defer inst.deinit();
    const hdr = &inst.cell.hdr;
    defer gc_mod.forgetRanges(&.{.{ .start = @intFromPtr(hdr), .len = @sizeOf(gc_mod.GcHeader) }});
    hdr.gc_gen = 1;
    hdr.gc_remembered = false;

    // Past the slots nothing is stored and nothing is remembered.
    try testing.expect(InstanceData.slotSet(inst, 1, .Unit) == null);
    try testing.expect(!hdr.gc_remembered);
    // A scalar makes no edge, so it is not remembered; a reference is.
    const old = InstanceData.slotSet(inst, 0, .{ .Int = 7 }) orelse return error.TestUnexpectedResult;
    try testing.expect(old == .Null);
    try testing.expect(!hdr.gc_remembered);
    try testing.expectEqual(@as(i32, 7), InstanceData.slotGet(inst, 0).?.Int);
    const other = try InstanceData.new(allocator, fx.handle.clone(), &.{}, 1);
    defer other.deinit();
    _ = InstanceData.slotSet(inst, 0, .{ .Instance = other }) orelse return error.TestUnexpectedResult;
    try testing.expect(hdr.gc_remembered);
    _ = InstanceData.slotSet(inst, 0, .Null);
    try testing.expect(InstanceData.slotGet(inst, 1) == null);
}

test "a mark tracing an instance while its slots are stored shades only whole values" {
    for ([_]bool{ true, false }) |ordered| try traceRacingStores(ordered);
}

fn traceRacingStores(ordered: bool) !void {
    const allocator = std.heap.smp_allocator;
    // The marks below tenure the class and the values, and a store into one then
    // remembers it: the remembered set lets go of them once they are freed.
    var cells: [4]objcell.gc.Range = @splat(.{ .start = 0, .len = 0 });
    defer objcell.gc.forgetRanges(&cells);
    var fx = try ClassFixture.build(allocator, "Traced", &.{}, &.{}, &.{});
    defer fx.deinit(allocator);
    fx.ptr().ordered_slots = ordered;
    const other = try InstanceData.new(allocator, fx.handle.clone(), &.{}, 7);
    defer other.deinit();
    const text = try value_mod.strInit(allocator, "whole");
    defer text.deinit();
    const kinds = [_]Value{ .{ .Int = 0x5a5a5a5a }, .{ .String = text }, .{ .Instance = other }, .Null };
    const inst = try InstanceData.new(allocator, fx.handle.clone(), &.{ kinds[0], kinds[1] }, 1);
    defer {
        inst.asPtr().slots[0] = .Null;
        inst.asPtr().slots[1] = .Null;
        inst.deinit();
    }
    for ([_]*objcell.gc.GcHeader{ &fx.handle.cell.hdr, &other.cell.hdr, &text.cell.hdr, &inst.cell.hdr }, &cells) |h, *r| {
        r.* = .{ .start = @intFromPtr(h), .len = @sizeOf(objcell.gc.GcHeader) };
    }

    const Race = struct {
        inst: ObjRef(InstanceData),
        kinds: []const Value,
        stop: std.atomic.Value(bool) = .init(false),

        fn write(self: *@This(), which: usize) void {
            var n: usize = 0;
            while (!self.stop.load(.monotonic)) : (n += 1) {
                _ = InstanceData.slotSet(self.inst, (which + n) % 2, self.kinds[(which + n) % self.kinds.len]);
            }
        }
    };
    var race: Race = .{ .inst = inst, .kinds = &kinds };
    var threads: [3]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Race.write, .{ &race, i });
    // A trace that paired one store's tag with another's payload would shade a
    // header that is none of these.
    const known = [_]*objcell.gc.GcHeader{ &fx.handle.cell.hdr, &text.cell.hdr, &other.cell.hdr };
    var epoch: usize = 1;
    while (epoch < 200_000) : (epoch += 1) {
        var m: objcell.gc.Marker = .{ .epoch = epoch, .arena = allocator };
        defer m.grey.deinit(allocator);
        inst.cell.hdr.traceCell(&m);
        for (m.grey.items) |h| {
            const ok = for (known) |k| {
                if (h == k) break true;
            } else false;
            try testing.expect(ok);
        }
    }
    race.stop.store(true, .monotonic);
    for (threads) |t| t.join();
}

test "a class with no ordered slot makes plain instances, and an ordered one's keep the sequence" {
    const allocator = testing.allocator;
    var fx = try ClassFixture.build(allocator, "Foo", &.{}, &.{}, &.{});
    defer fx.deinit(allocator);
    const layout = [_]LayoutSlot{ .{ .name = "x" }, .{ .name = "y" } };
    fx.ptr().layout_slots = &layout;
    for ([_]bool{ false, true }) |ordered| {
        fx.ptr().ordered_slots = ordered;
        const inst = try InstanceData.new(allocator, fx.handle.clone(), &.{ .{ .Int = 1 }, .Null }, 0);
        defer inst.deinit();
        const d = inst.asPtr();
        const plain = plainSlotsOn() and !ordered;
        try testing.expectEqual(plain, d.slot_seq.load(.monotonic) & PLAIN_SLOTS != 0);
        try testing.expectEqual(@as(i32, 1), d.storeSlot(0, .{ .Int = 5 }).?.Int);
        try testing.expect(d.storeSlot(1, .{ .Long = -3 }).? == .Null);
        try testing.expectEqual(@as(i32, 5), d.loadSlot(0).?.Int);
        try testing.expectEqual(@as(i64, -3), d.loadSlot(1).?.Long);
        try testing.expect(d.loadSlot(2) == null);
        if (plain) {
            // A plain store takes no turn.
            try testing.expectEqual(PLAIN_SLOTS, d.slot_seq.load(.monotonic));
            continue;
        }
        try testing.expectEqual(@as(u32, 4), d.slot_seq.load(.monotonic));
        {
            const u = d.beginUpdate();
            defer u.end();
            try testing.expectEqual(@as(i32, 5), u.get("x").?.Int);
        }
        try testing.expectEqual(@as(u32, 6), d.slot_seq.load(.monotonic));
        // The sequence wraps below the plain flag, so an ordered instance stays ordered.
        d.slot_seq.store(PLAIN_SLOTS - 2, .monotonic);
        _ = d.storeSlot(0, .{ .Int = 6 });
        try testing.expectEqual(@as(u32, 0), d.slot_seq.load(.monotonic));
        try testing.expectEqual(@as(i32, 6), d.loadSlot(0).?.Int);
    }
}

test "a slot read racing stores of every kind sees one whole stored value" {
    for ([_]bool{ true, false }) |ordered| try raceSlot(ordered);
}

fn raceSlot(ordered: bool) !void {
    const allocator = std.heap.smp_allocator;
    var fx = try ClassFixture.build(allocator, "Racy", &.{}, &.{}, &.{});
    defer fx.deinit(allocator);
    fx.ptr().ordered_slots = ordered;
    const other = try InstanceData.new(allocator, fx.handle.clone(), &.{}, 7);
    defer other.deinit();
    const text = try value_mod.strInit(allocator, "whole");
    defer text.deinit();
    // Each writer stores values of one kind whose payload names the kind, so
    // a read pairing one store's tag with another's payload is caught.
    const kinds = [_]Value{ .{ .Int = 0x5a5a5a5a }, .{ .String = text }, .{ .Instance = other }, .Null, .{ .Long = -1 } };
    const inst = try InstanceData.new(allocator, fx.handle.clone(), &.{kinds[0]}, 1);
    defer {
        inst.asPtr().slots[0] = .Null;
        inst.deinit();
    }
    try testing.expectEqual(plainSlotsOn() and !ordered, inst.asPtr().slot_seq.load(.monotonic) & PLAIN_SLOTS != 0);

    const Race = struct {
        inst: ObjRef(InstanceData),
        kinds: []const Value,
        stop: std.atomic.Value(bool) = .init(false),
        torn: std.atomic.Value(usize) = .init(0),
        reads: std.atomic.Value(usize) = .init(0),

        fn whole(self: *@This(), v: Value) bool {
            for (self.kinds) |k| {
                if (std.meta.activeTag(k) != std.meta.activeTag(v)) continue;
                return switch (v) {
                    .Int => |x| x == k.Int,
                    .Long => |x| x == k.Long,
                    .String => |x| x.cell == k.String.cell,
                    .Instance => |x| x.cell == k.Instance.cell,
                    .Null => true,
                    else => false,
                };
            }
            return false;
        }

        fn write(self: *@This(), which: usize) void {
            var n: usize = 0;
            while (!self.stop.load(.monotonic)) : (n += 1) {
                _ = InstanceData.slotSet(self.inst, 0, self.kinds[(which + n) % self.kinds.len]);
            }
        }

        fn read(self: *@This()) void {
            while (!self.stop.load(.monotonic)) {
                const v = InstanceData.slotGet(self.inst, 0).?;
                if (!self.whole(v)) _ = self.torn.fetchAdd(1, .monotonic);
                _ = self.reads.fetchAdd(1, .monotonic);
            }
        }
    };
    var race: Race = .{ .inst = inst, .kinds = &kinds };
    var threads: [6]std.Thread = undefined;
    for (threads[0..3], 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Race.write, .{ &race, i });
    for (threads[3..]) |*t| t.* = try std.Thread.spawn(.{}, Race.read, .{&race});
    while (race.reads.load(.monotonic) < 2_000_000) std.atomic.spinLoopHint();
    race.stop.store(true, .monotonic);
    for (threads) |t| t.join();
    try testing.expectEqual(@as(usize, 0), race.torn.load(.monotonic));
}

test "an identity is taken once, in the header's word, and never 0" {
    const allocator = testing.allocator;
    var fx = try ClassFixture.build(allocator, "Ided", &.{}, &.{}, &.{});
    defer fx.deinit(allocator);
    const inst = try InstanceData.new(allocator, fx.handle.clone(), &.{}, 0);
    defer inst.deinit();
    try testing.expectEqual(@as(u32, 0), inst.cell.hdr.gc_aux);
    const was = next_identity.load(.monotonic);
    defer next_identity.store(was, .monotonic);
    next_identity.store(0xFFFF_FFFF, .monotonic);
    try testing.expectEqual(@as(u64, 1), inst.cell.data.identityOf());
    try testing.expectEqual(@as(u64, 1), inst.cell.data.identityOf());
    try testing.expectEqual(@as(u32, 1), inst.cell.hdr.gc_aux);
    inst.cell.data.setIdentity(0x1_0000_0007);
    try testing.expectEqual(@as(u64, 7), inst.cell.data.identityOf());
}
