//! The per-class field layout a class WOULD have if its storage were fixed at
//! link time, and an audit that compares it against the layout construction
//! actually produces.
//!
//! A field slot used to be no property of a class at all: `materialize.zig`
//! appended fields in construction order, the order depended on how many
//! constructor arguments were passed and on which initializers ran, and every
//! field read re-verifies its memoized index against a shape word or a name.
//! `plans/resolved-interpreter.md`'s `represent/class-layout` fixes that by
//! reserving every declared slot before construction fills any of them.
//!
//! Construction now reserves the predicted layout up front, so the audit is
//! the check that the two still agree. It prints one line per divergence at
//! the end of every construction, under `KLIO_LAYOUT_AUDIT=1`:
//!
//!   [KLIO_LAYOUT_AUDIT] class=<fqn> kind=<...> slot=<i> want=<name> got=<name> divergent=1
//!
//! The layout itself now comes from `Module.field_layout`, which the build
//! composes from what each class publishes, so a lowering that never sees a
//! `ClassDef` can name a slot by index. A class the build did not describe —
//! one declared inside a function body, an object expression's — keeps the walk
//! below as its answer. The same switch compares the two whenever both exist
//! (`kind=published-*`, `kind=unpublished`), because a table that disagrees
//! with the walk is silent corruption.
//!
//! `scripts/layout_audit_sweep.py` drives it over the corpus and requires the
//! divergence set to be empty but for the classes that cannot have a static
//! layout at all, which it lists by name.
//!
//! The predicted order, for a class with a layout:
//!
//!   layout(C) = layout(super(C)) ++ own(C)
//!   own(C) = [name, ordinal]                 if C is the enum class
//!         ++ [message, cause]                if C heads a throwable chain
//!         ++ [__delegate__<Base>]            if C extends a builtin collection
//!         ++ primary-ctor properties         in declaration order
//!         ++ body properties with storage    in declaration order
//!         ++ [__delegate__<Iface>...]        one per `by`-delegated supertype
//!
//! and then, once for the whole chain and after every declared slot, the
//! plain constructor parameters a member body captures, base classes first.
//!
//! Interfaces contribute nothing: they hold no storage and are skipped by the
//! constructor chain.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("ir");
const ast = @import("ast");

const Allocator = std.mem.Allocator;
const ClassDef = runtime.ClassDef;
const InstanceData = runtime.InstanceData;
const ObjRef = runtime.ObjRef;
const Value = runtime.Value;

/// Why a class has no predicted layout. Each is a real property of the
/// declaration, not a gap in this code: a class in one of these states builds
/// its fields somewhere other than the primary-constructor path, or does not
/// exist until the program runs.
pub const NoLayout = enum {
    /// An interface holds no storage.
    interface,
    /// Built by `build_object.zig` in a different order entirely.
    anonymous,
    /// A supertype that does not resolve, so the base layout is unknown.
    unresolved_super,
    /// The chain is deeper than the walk allows, which means a cycle.
    chain_too_deep,
};

/// The value a published seed kind stands for.
pub fn seedValue(kind: ir.SlotSeed) Value {
    return switch (kind) {
        .null_ref => .Null,
        .int => .{ .Int = 0 },
        .long => .{ .Long = 0 },
        .short => .{ .Short = 0 },
        .byte => .{ .Byte = 0 },
        .float => .{ .Float = 0.0 },
        .double => .{ .Double = 0.0 },
        .boolean => .{ .Bool = false },
        .char => .{ .Char = 0 },
    };
}

/// A slot key plus the value it holds before an initializer replaces it.
pub const Slot = runtime.LayoutSlot;

pub const Predicted = struct {
    /// Slots in order, base classes first.
    slots: []const Slot,
    /// How many of `slots` come from the superclass layout.
    base_count: usize,
    /// False when `slots` is the class's memo, which outlives every caller.
    owned: bool = true,

    pub fn deinit(self: *Predicted, a: Allocator) void {
        if (self.owned) a.free(@constCast(self.slots));
        self.* = undefined;
    }
};

pub const Result = union(enum) {
    ok: Predicted,
    no_layout: NoLayout,
};

const max_depth: usize = 64;

/// The key a property's storage uses: the owner-mangled registry key when the
/// class privately shadows or overrides a supertype's same-named property,
/// else the plain name. Mirrors `ctor_select.shadowFieldKey`, which is what
/// construction stores under; taking the mangled key from the same registry
/// keeps the two in step rather than in parallel.
pub const ShadowKeyFn = *const fn (ctx: ?*anyopaque, cls: []const u8, prop: []const u8) []const u8;

/// Appends the `__delegate__<Iface>` key of every `by`-delegated supertype the
/// class declares. `ClassDef.supertype_delegates` is empty on a live class: the
/// delegation expressions live in the program's side table, so the keys come
/// from whoever owns that table.
pub const DelegateKeysFn = *const fn (
    ctx: ?*anyopaque,
    def: *const ClassDef,
    out: *std.ArrayList(Slot),
    a: Allocator,
) Allocator.Error!void;

/// The layout the module published for this class, when it has one. Null means
/// no module answer at all, and the prediction walks the declaration instead.
pub const PublishedFn = *const fn (ctx: ?*anyopaque, def: *const ClassDef) ?Result;

pub const Ctx = struct {
    allocator: Allocator,
    /// Resolves a property's storage key; null keys everything by plain name.
    shadow_key: ?ShadowKeyFn = null,
    shadow_ctx: ?*anyopaque = null,
    /// Supplies the class-delegation slots; null contributes none.
    delegate_keys: ?DelegateKeysFn = null,
    delegate_ctx: ?*anyopaque = null,
    /// Reads the link-time table; null makes every prediction walk.
    published: ?PublishedFn = null,
    published_ctx: ?*anyopaque = null,

    fn key(self: *const Ctx, cls: []const u8, prop: []const u8) []const u8 {
        const f = self.shadow_key orelse return prop;
        return f(self.shadow_ctx, cls, prop);
    }
};

/// Whether a body property occupies a slot.
///
/// An abstract property declares no storage. Past that, an initializer or a
/// delegate always produces one, even beside a custom getter: `var n: Int = 7
/// get() = field * 2` stores `n`, and `val x by lazy { }` stores the delegate
/// under `x`. Only an accessor-only property, which computes on every read,
/// has nothing to store.
///
/// Two neighbouring predicates answer this differently: the stored-null probe
/// (`read_paths.zig`, which also requires `has_backing` and excludes
/// `lateinit`) and the native emitter (`cgen/layout.zig`, `has_backing and
/// !is_abstract`). This one is what construction stores, which is what a slot
/// index has to describe.
pub fn bodyPropertyHasSlot(p: *const runtime.PropertyDef) bool {
    if (p.is_abstract) return false;
    return p.init != null or p.delegate != null or p.getter == null;
}

/// Whether this class owns `message` and `cause`. The builtin throwable roots
/// have no `ClassDef`, so the first declared class under one holds the slots
/// and every subclass inherits them through the base layout.
fn headsThrowableChain(has_parent: bool, supertype_names: []const []const u8) bool {
    if (has_parent) return false;
    for (supertype_names) |s| {
        if (isThrowableRootName(simpleOf(s))) return true;
    }
    return false;
}

fn isThrowableRootName(name: []const u8) bool {
    const roots = [_][]const u8{
        "Throwable",     "Exception",          "RuntimeException",     "Error",
        "IllegalStateException", "IllegalArgumentException", "IndexOutOfBoundsException",
        "NoSuchElementException", "UnsupportedOperationException", "ClassCastException",
        "NullPointerException", "ArithmeticException", "ConcurrentModificationException",
        "NumberFormatException", "AssertionError", "OutOfMemoryError", "StackOverflowError",
    };
    for (roots) |r| {
        if (std.mem.eql(u8, r, name)) return true;
    }
    return false;
}

/// The bare classifier name of a supertype spelling: the type arguments come
/// off first, then the package qualifier.
fn simpleOf(n: []const u8) []const u8 {
    var s = std.mem.trimEnd(u8, n, "?");
    if (std.mem.findScalar(u8, s, '<')) |lt| s = s[0..lt];
    if (std.mem.findScalarLast(u8, s, '.')) |d| return s[d + 1 ..];
    return s;
}

/// The builtin collection key a class extending one carries, if any.
fn builtinBaseKey(supertype_names: []const []const u8) ?[]const u8 {
    for (supertype_names) |s| {
        const simple = simpleOf(s);
        const bases = [_]struct { n: []const u8, k: []const u8 }{
            .{ .n = "ArrayList", .k = "__delegate__ArrayList" },
            .{ .n = "HashMap", .k = "__delegate__HashMap" },
            .{ .n = "LinkedHashMap", .k = "__delegate__LinkedHashMap" },
            .{ .n = "HashSet", .k = "__delegate__HashSet" },
            .{ .n = "LinkedHashSet", .k = "__delegate__LinkedHashSet" },
            .{ .n = "ArrayDeque", .k = "__delegate__ArrayDeque" },
        };
        for (bases) |b| {
            if (std.mem.eql(u8, simple, b.n)) return b.k;
        }
    }
    return null;
}

fn pushSlot(a: Allocator, out: *std.ArrayList(Slot), name: []const u8, seed: Value) Allocator.Error!void {
    try out.append(a, .{ .name = name, .seed = seed, .plain = false, .ctor = false, .plain_write = false });
}

/// A synthesized or accessor-backed slot that still declares a type.
fn pushSlotTyped(a: Allocator, out: *std.ArrayList(Slot), name: []const u8, seed: Value, type_head: []const u8) Allocator.Error!void {
    try out.append(a, .{ .name = name, .seed = seed, .plain = false, .ctor = false, .plain_write = false, .type_head = type_head });
}

/// A slot whose value answers a read directly: a constructor property, or a
/// body property with neither accessor nor delegate. The synthesized slots
/// (`name`, `ordinal`, `message`, a delegate key) are not plain, because what
/// reads them is not an ordinary property read.
fn pushPlainSlot(a: Allocator, out: *std.ArrayList(Slot), name: []const u8, seed: Value, ctor: bool, plain_write: bool, type_head: []const u8) Allocator.Error!void {
    try out.append(a, .{ .name = name, .seed = seed, .plain = true, .ctor = ctor, .plain_write = plain_write, .type_head = type_head });
}

/// The slots `def` adds beyond its superclass's layout, appended to `out`. This
/// is the one statement of the rule: the build calls it to fill
/// `ir.Class.field_layout.own`, the walk below calls it per chain level.
pub fn appendOwnSlots(ctx: *const Ctx, def: *const ClassDef, out: *std.ArrayList(Slot)) Allocator.Error!void {
    const a = ctx.allocator;
    if (def.is_enum) {
        try pushSlot(a, out, "name", .Null);
        try pushSlot(a, out, "ordinal", .Null);
    }
    if (headsThrowableChain(def.parent != null, def.supertype_names)) {
        try pushSlot(a, out, "message", .Null);
        try pushSlot(a, out, "cause", .Null);
    }
    if (builtinBaseKey(def.supertype_names)) |k| try pushSlot(a, out, k, .Null);
    for (def.primary_params) |p| {
        if (p.property == null) continue;
        // A constructor property never has an accessor, and its slot is
        // written before any user code runs.
        try pushPlainSlot(a, out, ctx.key(def.name, p.name), .Null, true, true, p.declared_type orelse "");
    }
    for (def.body_properties) |*p| {
        if (!bodyPropertyHasSlot(p)) continue;
        // A declared non-nullable primitive reads as its JVM zero before the
        // initializer runs, which is what an override called from a base
        // `init` sees.
        const plain = p.getter == null and p.delegate == null and !p.is_lateinit;
        const seed = p.primitive_zero orelse .Null;
        if (plain) {
            try pushPlainSlot(a, out, ctx.key(def.name, p.name), seed, false, p.setter == null, p.type_head orelse "");
        } else {
            try pushSlotTyped(a, out, ctx.key(def.name, p.name), seed, p.type_head orelse "");
        }
    }
    for (def.supertype_delegates) |d| try pushSlot(a, out, d.field_key, .Null);
    if (ctx.delegate_keys) |f| try f(ctx.delegate_ctx, def, out, a);
}

/// The layout `def` would have if storage were fixed at link time. The answer
/// is a function of the declaration chain, so the class memoizes it: the first
/// construction reads the published table (or walks, where there is none), every
/// later one reads the stored slice.
pub fn predict(ctx: *const Ctx, def_ref: ObjRef(ClassDef)) Allocator.Error!Result {
    const dptr = def_ref.asPtrConst();
    switch (@atomicLoad(u8, &@constCast(dptr).layout_state, .acquire)) {
        2 => return .{ .ok = .{
            .slots = dptr.layout_slots,
            .base_count = dptr.layout_base_count,
            .owned = false,
        } },
        3 => return .{ .no_layout = @enumFromInt(dptr.layout_no) },
        else => {},
    }
    return publish(dptr, try resolveLayout(ctx, dptr, def_ref));
}

/// The published layout when the module has one, else the declaration walk.
///
/// Under `KLIO_LAYOUT_AUDIT` both are computed and compared, because a published
/// layout that disagrees with the walk is silent corruption: nothing downstream
/// would notice a slot index that means one thing here and another there.
fn resolveLayout(ctx: *const Ctx, dptr: *const ClassDef, def_ref: ObjRef(ClassDef)) Allocator.Error!Result {
    const from_table: ?Result = if (ctx.published) |f| f(ctx.published_ctx, dptr) else null;
    if (!auditOn()) return from_table orelse try computeLayout(ctx, def_ref);

    var walked = try computeLayout(ctx, def_ref);
    auditPublished(dptr.fqn, from_table, walked);
    const table = from_table orelse return walked;
    if (walked == .ok) walked.ok.deinit(ctx.allocator);
    return table;
}

/// Hand the computed layout to the class. The first writer wins and its slice
/// becomes the shared answer; a loser keeps the copy it made and frees it.
fn publish(dptr: *const ClassDef, computed: Result) Result {
    const d = @constCast(dptr);
    if (@cmpxchgStrong(u8, &d.layout_state, 0, 1, .acq_rel, .acquire) != null) return computed;
    switch (computed) {
        .no_layout => |why| {
            d.layout_no = @intFromEnum(why);
            @atomicStore(u8, &d.layout_state, 3, .release);
            return computed;
        },
        .ok => |p| {
            d.layout_slots = p.slots;
            d.layout_base_count = @intCast(p.base_count);
            @atomicStore(u8, &d.layout_state, 2, .release);
            return .{ .ok = .{ .slots = p.slots, .base_count = p.base_count, .owned = false } };
        },
    }
}

fn computeLayout(ctx: *const Ctx, def_ref: ObjRef(ClassDef)) Allocator.Error!Result {
    const a = ctx.allocator;
    // Collect the chain leaf-first, then emit it base-first.
    var chain: std.ArrayList(ObjRef(ClassDef)) = .empty;
    defer {
        for (chain.items) |c| c.deinit();
        chain.deinit(a);
    }
    var cur: ?ObjRef(ClassDef) = def_ref.clone();
    while (cur) |c| {
        if (chain.items.len >= max_depth) {
            c.deinit();
            return .{ .no_layout = .chain_too_deep };
        }
        const g = c.borrow();
        const d = g.get();
        const bad: ?NoLayout = if (d.is_interface)
            .interface
        else if (d.is_anonymous)
            .anonymous
        else
            null;
        const next = if (d.parent) |p| p.clone() else null;
        g.deinit();
        if (bad) |b| {
            c.deinit();
            if (next) |n| n.deinit();
            return .{ .no_layout = b };
        }
        try chain.append(a, c);
        cur = next;
    }

    var slots: std.ArrayList(Slot) = .empty;
    errdefer slots.deinit(a);
    var base_count: usize = 0;
    var i = chain.items.len;
    while (i > 0) {
        i -= 1;
        if (i == 0) base_count = slots.items.len;
        const g = chain.items[i].borrow();
        defer g.deinit();
        try appendOwnSlots(ctx, g.get(), &slots);
    }
    try appendCaptureSlots(a, chain.items, &slots);
    return .{ .ok = .{ .slots = try slots.toOwnedSlice(a), .base_count = base_count } };
}

/// Kotlin gives a plain primary-constructor parameter a member body reads a
/// synthesized field. Whether one exists depends on the whole chain, not on
/// one declaration: a subclass property of the same name claims the name and
/// the parameter keeps none. So the captures cannot sit inside a level's own
/// slots without a subclass changing where its base's slots land; they go
/// after every declared slot instead, which leaves a declared slot's index
/// the same in a base and in a subclass.
fn appendCaptureSlots(a: Allocator, chain: []const ObjRef(ClassDef), out: *std.ArrayList(Slot)) Allocator.Error!void {
    var i = chain.len;
    while (i > 0) {
        i -= 1;
        const g = chain[i].borrow();
        defer g.deinit();
        const d = g.get();
        next: for (d.primary_params) |p| {
            if (p.property != null) continue;
            for (out.items) |s| {
                if (std.mem.eql(u8, s.name, p.name)) continue :next;
            }
            for (d.body_properties) |*bp| {
                if (std.mem.eql(u8, bp.name, p.name)) continue :next;
            }
            try out.append(a, .{ .name = p.name, .seed = .Null });
        }
    }
}

var audit_state: u8 = 0;

/// `KLIO_LAYOUT_AUDIT=1`: compare every constructed instance's field order
/// against the predicted layout. Diagnostic only; nothing reads the prediction.
pub fn auditOn() bool {
    if (audit_state == 0) {
        audit_state = if (runtime.envOnce("KLIO_LAYOUT_AUDIT") != null) 2 else 1;
    }
    return audit_state == 2;
}

var audit_seen: ?runtime.NameHashMap(void) = null;
var audit_mutex: runtime.SpinMutex = .{};
var audit_divergent: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var audit_agreed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var pub_agreed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var pub_divergent: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var pub_absent: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Report the link-time table against the declaration walk for one class. The
/// walk is `want`, the table is `got`: the walk is what construction produced
/// before the table existed, so any difference is the table's to explain.
fn auditPublished(fqn: []const u8, table: ?Result, walked: Result) void {
    const t = table orelse {
        // A class the build never described falls back to the walk, which costs
        // a chain walk per class and leaves its slots unaddressable by index.
        if (walked == .ok) {
            _ = pub_absent.fetchAdd(1, .monotonic);
            std.debug.print("[KLIO_LAYOUT_AUDIT] class={s} kind=unpublished divergent=1\n", .{fqn});
        }
        return;
    };
    var diverged = false;
    switch (t) {
        .no_layout => |tw| switch (walked) {
            .no_layout => |ww| if (tw != ww) {
                diverged = true;
                std.debug.print(
                    "[KLIO_LAYOUT_AUDIT] class={s} kind=published-nolayout slot=0 want={s} got={s} divergent=1\n",
                    .{ fqn, @tagName(ww), @tagName(tw) },
                );
            },
            .ok => {
                diverged = true;
                std.debug.print(
                    "[KLIO_LAYOUT_AUDIT] class={s} kind=published-nolayout slot=0 want=layout got={s} divergent=1\n",
                    .{ fqn, @tagName(tw) },
                );
            },
        },
        .ok => |tp| switch (walked) {
            .no_layout => |ww| {
                diverged = true;
                std.debug.print(
                    "[KLIO_LAYOUT_AUDIT] class={s} kind=published-nolayout slot=0 want={s} got=layout divergent=1\n",
                    .{ fqn, @tagName(ww) },
                );
            },
            .ok => |wp| {
                if (tp.base_count != wp.base_count) {
                    diverged = true;
                    std.debug.print(
                        "[KLIO_LAYOUT_AUDIT] class={s} kind=published-base slot=0 want={d} got={d} divergent=1\n",
                        .{ fqn, wp.base_count, tp.base_count },
                    );
                }
                var slot: usize = 0;
                while (slot < @max(tp.slots.len, wp.slots.len)) : (slot += 1) {
                    const want: ?Slot = if (slot < wp.slots.len) wp.slots[slot] else null;
                    const got: ?Slot = if (slot < tp.slots.len) tp.slots[slot] else null;
                    const kind: []const u8 = k: {
                        if (want == null) break :k "published-extra";
                        if (got == null) break :k "published-missing";
                        if (!std.mem.eql(u8, want.?.name, got.?.name)) break :k "published-misordered";
                        if (!seedEql(want.?.seed, got.?.seed)) break :k "published-seed";
                        continue;
                    };
                    diverged = true;
                    std.debug.print(
                        "[KLIO_LAYOUT_AUDIT] class={s} kind={s} slot={d} want={s} got={s} divergent=1\n",
                        .{ fqn, kind, slot, if (want) |w| w.name else "-", if (got) |g| g.name else "-" },
                    );
                }
            },
        },
    }
    if (diverged) {
        _ = pub_divergent.fetchAdd(1, .monotonic);
    } else {
        _ = pub_agreed.fetchAdd(1, .monotonic);
    }
}

/// Seeds are scalars or null, so identity is the tag plus the bits.
fn seedEql(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .Null, .Unit => true,
        .Bool => |x| x == b.Bool,
        .Int => |x| x == b.Int,
        .Long => |x| x == b.Long,
        .Short => |x| x == b.Short,
        .Byte => |x| x == b.Byte,
        .UInt => |x| x == b.UInt,
        .ULong => |x| x == b.ULong,
        .UShort => |x| x == b.UShort,
        .UByte => |x| x == b.UByte,
        .Float => |x| x == b.Float,
        .Double => |x| x == b.Double,
        .Char => |x| x == b.Char,
        else => false,
    };
}

/// Report one constructed instance against its class's predicted layout. One
/// report per class: two instances of the same class diverging the same way is
/// one fact, and the sweep reads a set, not a histogram.
pub fn audit(ctx_in: *const Ctx, inst: ObjRef(InstanceData)) void {
    if (!auditOn()) return;
    const allocator = ctx_in.allocator;
    const ig = inst.borrow();
    defer ig.deinit();
    const class_ref = ig.get().class.clone();
    defer class_ref.deinit();
    const fqn = blk: {
        const cg = class_ref.borrow();
        defer cg.deinit();
        break :blk cg.get().fqn;
    };
    {
        audit_mutex.lock();
        defer audit_mutex.unlock();
        if (audit_seen == null) audit_seen = runtime.NameHashMap(void).init(std.heap.page_allocator);
        const gop = audit_seen.?.getOrPut(fqn) catch return;
        if (gop.found_existing) return;
    }

    var r = predict(ctx_in, class_ref) catch return;
    switch (r) {
        .no_layout => |why| {
            _ = audit_divergent.fetchAdd(1, .monotonic);
            std.debug.print("[KLIO_LAYOUT_AUDIT] class={s} kind=no-layout why={s} divergent=1\n", .{ fqn, @tagName(why) });
            return;
        },
        .ok => |*p| {
            defer p.deinit(allocator);
            const actual = ig.get().fields.items;
            var diverged = false;
            var slot: usize = 0;
            while (slot < @max(p.slots.len, actual.len)) : (slot += 1) {
                const want: ?[]const u8 = if (slot < p.slots.len) p.slots[slot].name else null;
                const got: ?[]const u8 = if (slot < actual.len) actual[slot].name else null;
                if (want != null and got != null and std.mem.eql(u8, want.?, got.?)) continue;
                const kind: []const u8 = if (want == null)
                    "extra"
                else if (got == null)
                    "missing"
                else
                    "misordered";
                std.debug.print("[KLIO_LAYOUT_AUDIT] class={s} kind={s} slot={d} want={s} got={s} divergent=1\n", .{
                    fqn, kind, slot, want orelse "-", got orelse "-",
                });
                diverged = true;
            }
            if (diverged) {
                _ = audit_divergent.fetchAdd(1, .monotonic);
            } else {
                _ = audit_agreed.fetchAdd(1, .monotonic);
            }
        },
    }
}

const testing = std.testing;

test "a slot goes to everything construction stores, and to nothing else" {
    const ref: runtime.forest.ForestRef = .{ .decl = 0, .ord = 0 };
    var p = runtime.PropertyDef{
        .name = "x",
        .mutable = false,
        .init = null,
        .getter = null,
        .setter = null,
        .delegate = null,
        .is_abstract = false,
        .is_lateinit = false,
        .primitive_zero = null,
    };
    try testing.expect(bodyPropertyHasSlot(&p));
    // A `lateinit var` and a property the emitter reads as backing-field-less
    // both store: the read-side probe and the native emitter disagree, and the
    // audit is what makes that disagreement visible.
    p.is_lateinit = true;
    try testing.expect(bodyPropertyHasSlot(&p));
    p.is_lateinit = false;
    p.has_backing = false;
    try testing.expect(bodyPropertyHasSlot(&p));
    p.has_backing = true;
    p.is_abstract = true;
    try testing.expect(!bodyPropertyHasSlot(&p));
    p.is_abstract = false;

    // An accessor-only property computes on every read and stores nothing.
    p.getter = runtime.forest.ForestField(ast.Accessor).fromRef(ref);
    try testing.expect(!bodyPropertyHasSlot(&p));
    // `var n: Int = 7 get() = field * 2` still stores `n`.
    p.init = runtime.forest.ForestField(ast.Expr).fromRef(ref);
    try testing.expect(bodyPropertyHasSlot(&p));
    // `val x by lazy { }` stores the delegate under `x`.
    p.init = null;
    p.getter = null;
    p.delegate = runtime.forest.ForestField(ast.Expr).fromRef(ref);
    try testing.expect(bodyPropertyHasSlot(&p));
}

test "a builtin collection supertype contributes one delegate slot" {
    try testing.expectEqualStrings(
        "__delegate__ArrayList",
        builtinBaseKey(&.{"kotlin.collections.ArrayList<String>"}).?,
    );
    try testing.expect(builtinBaseKey(&.{"kotlin.collections.List"}) == null);
}

test "only the first declared class under a builtin throwable owns its slots" {
    try testing.expect(headsThrowableChain(false, &.{"RuntimeException"}));
    try testing.expect(headsThrowableChain(false, &.{"kotlin.IllegalStateException"}));
    try testing.expect(!headsThrowableChain(true, &.{"RuntimeException"}));
    try testing.expect(!headsThrowableChain(false, &.{"Any"}));
}

test "a simple name is taken from a qualified or generic supertype" {
    try testing.expectEqualStrings("ArrayList", simpleOf("kotlin.collections.ArrayList"));
    try testing.expectEqualStrings("ArrayList", simpleOf("kotlin.collections.ArrayList<String>"));
    try testing.expectEqualStrings("Foo", simpleOf("Foo<Bar.Baz>"));
    try testing.expectEqualStrings("Foo", simpleOf("Foo"));
}
