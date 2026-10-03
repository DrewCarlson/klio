//! Every identity code lowered from sema uses, allocated from sema's
//! symbols in symbol order before any body lowers: `FuncId`s, `ClassId`s,
//! statics, field slots, natives, and each nested body's captures. It also
//! builds the `ir.Module` skeleton and the run-time tables the VM reads.
//! Lowering only reads what this allocates.
//!
//! Order. Symbols are walked per layer (the files one `Sema.addFiles` call
//! declared): the layer's declarations in symbol order, then its init
//! units, then the local declarations its bodies made (named by committed
//! records), then its callable-reference adapters. A layer's ids therefore
//! do not depend on any later layer, so the base keeps its ids whatever
//! program follows it. Symbols sema made on demand after the last layer
//! come last.

const std = @import("std");
const ast = @import("ast");
const sema = @import("sema");
const runtime = @import("runtime");

const ir = @import("../ir.zig");
const resolved = @import("resolved.zig");

const Allocator = std.mem.Allocator;
const Sym = sema.Sym;
const TypeId = sema.TypeId;
const ImplicitKind = sema.records.ImplicitKind;
const Receiver = sema.records.Receiver;
const Ref = sema.records.Ref;
const LambdaRec = sema.records.LambdaRec;
const FileRecords = sema.output.FileRecords;
const NodeId = ast.NodeId;
const ClassId = ir.ClassId;
const FuncId = ir.FuncId;
const MethodSlotId = ir.MethodSlotId;
const NativeId = ir.NativeId;
const StaticId = ir.StaticId;
const SlotSeed = ir.SlotSeed;
const ObjRef = runtime.ObjRef;

pub const Error = error{ OutOfMemory, Unsupported };

/// Binds a bodyless declaration, by its FQN, to a host function.
pub const NativeResolver = *const fn (fqn: []const u8) ?runtime.StdlibFn;

/// The host symbol implementing a bodyless declaration: its FQN, or for an
/// extension the receiver-qualified form the host registers
/// (`stdlib.declarationHostSymbol`). `receiver` is the receiver type as
/// written.
pub const HostSymbolResolver = *const fn (fqn: []const u8, receiver: ?[]const u8, name: []const u8) ?[]const u8;

/// Where one `Sema.addFiles` call ended: the symbol count and file count
/// after it.
pub const Layer = struct { syms: u32, files: u32 };

/// How many ids of each kind the layers up to and including one hold.
pub const LayerEnd = struct { funcs: u32, classes: u32, statics: u32 };

pub const Options = struct {
    /// The files whose declarations get bodies; empty means all of them.
    files: []const u32 = &.{},
    natives: NativeResolver,
    /// Finds an extension's receiver-qualified host symbol; null binds by
    /// FQN alone.
    host_symbol: ?HostSymbolResolver = null,
    /// The host makes values of the base's host-backed classes (a list, a
    /// range, a pair): their properties and constructors are the host's,
    /// the compiler intrinsics it answers bind, and a bodyless member binds
    /// to what the VM implements (`host_fns`).
    host_members: bool = false,
    /// The natives take a vararg's elements in its place and no reified
    /// type values (`NativeRt.reified`, `vararg_back`), as the host's do.
    spread_varargs: bool = false,
    /// The host's constructor of a host-backed class, by class FQN, before
    /// the native registered under the class's name.
    constructors: ?NativeResolver = null,
    /// The members the VM implements over host values, by `resolved.hostKey`:
    /// a bodyless member of a host-backed class binds to one before the
    /// host serves it by name, and a host value answers a slot its class
    /// does not implement with one (`Resolved.host_slot`).
    host_fns: ?resolved.HostFnResolver = null,
    /// The fast paths the VM puts in front of declarations with bodies, by
    /// `resolved.hostKey` (`Resolved.func_try`).
    host_tries: ?resolved.HostTryResolver = null,
    /// By file: sema's records (`sema.output.build`), which lowering reads
    /// through the bridge.
    records: []const FileRecords,
    /// The layers in the order they were added; empty means one layer
    /// holding everything.
    layers: []const Layer = &.{},
};

/// What a `FuncId`'s body is made from. A `FuncId` whose
/// `Resolved.func_native` entry is set runs its native and has no body to
/// lower.
pub const FuncOrigin = union(enum) {
    /// A function or constructor with a body, or a member sema synthesized
    /// (data, enum and `by` members, an implicit constructor).
    decl: Sym,
    /// A property's accessors.
    getter: Sym,
    setter: Sym,
    /// The declaration whose defaults it evaluates.
    defaults: Sym,
    /// Index into `Bridge.units`.
    init_unit: u32,
    /// A lambda, anonymous function or local function.
    lambda: Sym,
    /// The constructor of a fun interface's SAM class, `(this, function)`.
    /// Sema's SAM constructor function is allocated to it.
    sam_ctor: Sym,
    /// The SAM class's implementation of the interface's abstract method.
    sam_method: Sym,
    /// Index into `Bridge.adapters`.
    adapter: u32,
    /// The slot of a family it roots; never runs. A property's accessors
    /// carry the property.
    abstract: Sym,
    /// A restartable composable's recompose lambda, `(composer, changed)`,
    /// which calls it again with the values it was called with: the
    /// function passes them as the closure's captures.
    restart: Sym,
    /// The SAM class's `equals(other)` and `hashCode()`, over its function.
    sam_equals: Sym,
    sam_hash_code: Sym,
};

/// The functions of a fun interface's SAM class beside its constructor.
pub const SamFuncs = struct {
    /// Its implementation of the interface's abstract method.
    method: FuncId,
    /// `equals` and `hashCode`: a wrapper equals another wrapper of the
    /// interface over an equal function, and hashes as its function.
    equals: FuncId,
    hash_code: FuncId,
};

/// What a `ClassId` stands for.
pub const ClassOrigin = union(enum) {
    decl: Sym,
    /// The SAM class of this fun interface.
    sam: Sym,
};

/// An init unit: what its body initializes.
pub const Unit = union(enum) {
    /// The file's top-level properties with storage, in source order, but
    /// for its eager ones: what the first access to the file runs.
    file: u32,
    /// The enum class's entries.
    enum_class: Sym,
    /// The file's `@EagerInitialization` properties, in source order, which
    /// the program's start runs (`Resolved.eager_units`).
    eager_file: u32,
};

/// The host symbol an `external` function's `@ExternalSymbolName("S")`
/// names: an annotation of that simple name, as Kotlin/Native and the
/// libraries declaring their own copy of it write it, with one constant
/// string argument. Null for any other declaration.
pub fn externalSymbolName(s: *sema.Sema, f: Sym) ?[]const u8 {
    if (!s.syms.flags(f).external) return null;
    // A base image's externals were bound at the bake.
    const fd = switch (s.syms.get(f).decl) {
        .function => |fd| fd orelse return null,
        else => return null,
    };
    for (fd.annotations) |ann| {
        if (ann.path.len == 0 or !std.mem.eql(u8, ann.path[ann.path.len - 1].name, "ExternalSymbolName")) continue;
        if (ann.args.len != 1) continue;
        const parts = switch (ann.args[0]) {
            .StringTemplate => |t| t.parts,
            else => continue,
        };
        if (parts.len == 1 and parts[0] == .Text) return parts[0].Text;
        if (parts.len == 0) return "";
    }
    return null;
}

/// Whether `p` is a top-level property Kotlin/Native initializes when the
/// program starts: one annotated `@kotlin.native.EagerInitialization`.
pub fn eagerProperty(s: *sema.Sema, p: Sym) Error!bool {
    const owner = s.syms.owner(p);
    if (owner == .none or s.syms.kind(owner) != .package) return false;
    if (s.syms.get(p).decl != .property) return false;
    return sema.headers.hasAnnotation(s, p, .decl, s.classByFqn("kotlin.native.EagerInitialization"));
}

/// A value a nested body captures from an enclosing one. A read of `field`
/// captures the enclosing class's `this`; `super` is captured as
/// `class_this`.
pub const CaptureKey = union(enum) {
    local: Sym,
    receiver: struct { kind: ImplicitKind, owner: Sym },

    pub fn eql(x: CaptureKey, y: CaptureKey) bool {
        return switch (x) {
            .local => |l| y == .local and y.local == l,
            .receiver => |r| y == .receiver and y.receiver.kind == r.kind and y.receiver.owner == r.owner,
        };
    }

    /// The symbol whose scope the value belongs to.
    pub fn sym(k: CaptureKey) Sym {
        return switch (k) {
            .local => |l| l,
            .receiver => |r| r.owner,
        };
    }
};

/// A callable reference's adapter: one per target, function type and kind
/// of bound receiver.
pub const Adapter = struct {
    target: Sym,
    ty: TypeId,
    bound: std.meta.Tag(Receiver),
};

/// One field slot of a class's layout.
pub const Slot = struct {
    /// For display.
    name: []const u8,
    seed: SlotSeed = .null_ref,
    /// A `@Volatile` property's: every access orders as the JMM orders a
    /// volatile field's (`runtime.ClassDef.ordered_slots`).
    volatile_: bool = false,
};

/// A slot or index left empty.
pub const NONE: u32 = std.math.maxInt(u32);

pub const Bridge = struct {
    s: *sema.Sema,
    m: *ir.Module,
    /// By file: sema's records.
    records: []const FileRecords = &.{},
    /// By file: its declarations get bodies.
    body_files: std.DynamicBitSetUnmanaged = .{},
    /// By FuncId.
    origin: []FuncOrigin = &.{},
    // By Sym index; `NONE` where the symbol has none.
    func_of: []FuncId = &.{},
    getter_of: []FuncId = &.{},
    setter_of: []FuncId = &.{},
    /// For an override: the bridge of the declaration that declares the defaults.
    defaults_of: []FuncId = &.{},
    /// By restartable composable: its recompose lambda.
    restart_of: []FuncId = &.{},
    /// By literal: the static a composable literal returning `Unit` keeps
    /// its runtime lambda in when it captures nothing, the Compose
    /// compiler's composable singleton.
    singleton_of: []StaticId = &.{},
    class_of: []ClassId = &.{},
    /// Top-level properties with storage (a delegated one's static holds
    /// its delegate) and enum entries.
    static_of: []StaticId = &.{},
    /// By property: its slot in the owning class.
    field_of: []u32 = &.{},
    /// By delegated member property: the slot holding its delegate.
    delegate_field_of: []u32 = &.{},
    /// By function, or by property for a native getter.
    native_of: []NativeId = &.{},
    /// By fun interface.
    sam_class_of: []ClassId = &.{},
    /// By fun interface: its SAM class's functions.
    sam_funcs_of: std.AutoHashMapUnmanaged(Sym, SamFuncs) = .empty,
    // By ClassId.
    class_origin: []ClassOrigin = &.{},
    /// An inner class's outer instance.
    outer_slot: []u32 = &.{},
    /// Local classes and object expressions: the captured values, stored from
    /// slot `capture_base[class]` on, in this order.
    class_captures: []const []const CaptureKey = &.{},
    capture_base: []u32 = &.{},
    /// Every slot of an instance, the superclass's first.
    layout: []const []const Slot = &.{},
    /// Per written supertype, the slot holding its `by` delegate, `NONE`
    /// where it has none.
    by_slots: []const []const u32 = &.{},
    // By FuncId.
    /// The root's id, for a virtual or interface call.
    slot_of: []MethodSlotId = &.{},
    /// Lambdas, anonymous functions, local functions and their defaults
    /// bridges, and adapters of references to local functions or local
    /// classes: what each captures, in order. An adapter's bound receiver
    /// is capture 0 and these follow it.
    captures_of: []const []const CaptureKey = &.{},
    /// By adapter index.
    adapters: []const Adapter = &.{},
    /// By callable reference, keyed `refKey(file, node)`: its adapter.
    adapter_at: std.AutoHashMapUnmanaged(u64, FuncId) = .empty,
    /// By init unit index.
    units: []const Unit = &.{},
    /// Per layer, the ids allocated through its end, then one entry for
    /// everything; ids below a layer's counts do not depend on any later
    /// layer.
    layer_ends: []const LayerEnd = &.{},
    /// By Sym: the locals that live in a cell.
    cells: std.DynamicBitSetUnmanaged = .{},
    /// Over a base image: the base's function count and its header symbol
    /// prefix. A base function's own symbol names the same declaration in
    /// this sema only below the prefix; the base's body-level symbols
    /// (lambdas, local functions) were the bake's.
    image_funcs: u32 = 0,
    image_prefix: u32 = 0,
    /// How many symbols past their end the by-symbol tables have room for:
    /// a base image decodes them with space for its program's, which
    /// `buildOver` takes in place.
    sym_room: u32 = 0,
    /// Frame names, made on first ask (`frameName`).
    frame_names: FrameNames = .{},

    /// Asserts `s` has one.
    pub fn funcOf(self: *const Bridge, s: Sym) FuncId {
        const f = self.func_of[s.int()];
        std.debug.assert(f.int() != NONE);
        return f;
    }

    /// Null where `s` has no function id.
    pub fn funcOfOpt(self: *const Bridge, s: Sym) ?FuncId {
        if (s.int() >= self.func_of.len) return null;
        const f = self.func_of[s.int()];
        return if (f.int() == NONE) null else f;
    }

    pub fn classOf(self: *const Bridge, s: Sym) ClassId {
        const c = self.class_of[s.int()];
        std.debug.assert(c.int() != NONE);
        return c;
    }

    pub fn classOfOpt(self: *const Bridge, s: Sym) ?ClassId {
        if (s.int() >= self.class_of.len) return null;
        const c = self.class_of[s.int()];
        return if (c.int() == NONE) null else c;
    }

    pub fn getterOf(self: *const Bridge, prop: Sym) FuncId {
        const f = self.getter_of[prop.int()];
        std.debug.assert(f.int() != NONE);
        return f;
    }

    pub fn setterOf(self: *const Bridge, prop: Sym) ?FuncId {
        if (prop.int() >= self.setter_of.len) return null;
        const f = self.setter_of[prop.int()];
        return if (f.int() == NONE) null else f;
    }

    /// Null: no backing field.
    pub fn fieldOf(self: *const Bridge, prop: Sym) ?u32 {
        if (prop.int() >= self.field_of.len) return null;
        const f = self.field_of[prop.int()];
        return if (f == NONE) null else f;
    }

    pub fn delegateFieldOf(self: *const Bridge, prop: Sym) ?u32 {
        if (prop.int() >= self.delegate_field_of.len) return null;
        const f = self.delegate_field_of[prop.int()];
        return if (f == NONE) null else f;
    }

    pub fn staticOf(self: *const Bridge, s: Sym) ?StaticId {
        if (s.int() >= self.static_of.len) return null;
        const st = self.static_of[s.int()];
        return if (st.int() == NONE) null else st;
    }

    pub fn nativeOf(self: *const Bridge, f: Sym) NativeId {
        if (f.int() >= self.native_of.len) return .none;
        return self.native_of[f.int()];
    }

    pub fn defaultsOf(self: *const Bridge, f: Sym) ?FuncId {
        if (f.int() >= self.defaults_of.len) return null;
        const d = self.defaults_of[f.int()];
        return if (d.int() == NONE) null else d;
    }

    pub fn singletonOf(self: *const Bridge, f: Sym) ?StaticId {
        if (f.int() >= self.singleton_of.len) return null;
        const st = self.singleton_of[f.int()];
        return if (st.int() == NONE) null else st;
    }

    pub fn restartOf(self: *const Bridge, f: Sym) ?FuncId {
        if (f.int() >= self.restart_of.len) return null;
        const r = self.restart_of[f.int()];
        return if (r.int() == NONE) null else r;
    }

    pub fn samClassOf(self: *const Bridge, iface: Sym) ?ClassId {
        if (iface.int() >= self.sam_class_of.len) return null;
        const c = self.sam_class_of[iface.int()];
        return if (c.int() == NONE) null else c;
    }

    /// The SAM class's constructor: sema's SAM constructor of `iface`.
    pub fn samCtorOf(self: *const Bridge, iface: Sym) ?FuncId {
        const ctor = self.s.sam_ctors.get(iface) orelse return null;
        if (ctor == .none) return null;
        return self.funcOfOpt(ctor);
    }

    pub fn samMethodOf(self: *const Bridge, iface: Sym) ?FuncId {
        return if (self.sam_funcs_of.get(iface)) |f| f.method else null;
    }

    /// The slot holding the `by` delegate of `cls`'s written supertype
    /// `supertype` (`FunctionInfo.delegation`).
    pub fn delegateSlot(self: *const Bridge, cls: Sym, supertype: u16) ?u32 {
        const c = self.classOfOpt(cls) orelse return null;
        const slots = self.by_slots[c.int()];
        if (supertype >= slots.len or slots[supertype] == NONE) return null;
        return slots[supertype];
    }

    /// Whether class `c` keeps a `by` delegate in a slot of its own.
    pub fn hasDelegates(self: *const Bridge, c: ClassId) bool {
        if (c.int() >= self.by_slots.len) return false;
        for (self.by_slots[c.int()]) |sl| if (sl != NONE) return true;
        return false;
    }

    pub fn outerSlot(self: *const Bridge, c: ClassId) ?u32 {
        const o = self.outer_slot[c.int()];
        return if (o == NONE) null else o;
    }

    /// The root slot a virtual or interface call of `f` goes through.
    pub fn slotOf(self: *const Bridge, f: FuncId) ?MethodSlotId {
        if (f.int() >= self.slot_of.len) return null;
        const sl = self.slot_of[f.int()];
        return if (sl.int() == NONE) null else sl;
    }

    pub fn capturesOf(self: *const Bridge, f: FuncId) []const CaptureKey {
        if (f.int() >= self.captures_of.len) return &.{};
        return self.captures_of[f.int()];
    }

    pub fn slotCount(self: *const Bridge, c: ClassId) u32 {
        return @intCast(self.layout[c.int()].len);
    }

    /// The adapter of the callable reference at `node` in `file`.
    pub fn adapterFor(self: *const Bridge, file: u32, node: NodeId) FuncId {
        return self.adapter_at.get(refKey(file, node)) orelse FuncId.from(NONE);
    }

    pub fn isCell(self: *const Bridge, local: Sym) bool {
        return local.int() < self.cells.bit_length and self.cells.isSet(local.int());
    }

    /// Whether `file`'s declarations get bodies.
    pub fn lowersFile(self: *const Bridge, file: u32) bool {
        return file < self.body_files.bit_length and self.body_files.isSet(file);
    }

    pub fn funcCount(self: *const Bridge) u32 {
        return @intCast(self.origin.len);
    }

    pub fn classCount(self: *const Bridge) u32 {
        return @intCast(self.class_origin.len);
    }
};

pub fn refKey(file: u32, node: NodeId) u64 {
    return (@as(u64, file) << 32) | node.int();
}

/// Allocates every identity and builds the module skeleton and the
/// run-time tables. The module and the tables live in `a`; `Module.resolved`
/// points at the tables.
pub fn build(a: Allocator, s: *sema.Sema, opts: Options) Error!*Bridge {
    const m = try a.create(ir.Module);
    m.* = ir.Module.init(a);
    const br = try a.create(Bridge);
    br.* = .{ .s = s, .m = m, .records = opts.records };
    var b: Build = .{ .a = a, .s = s, .br = br, .opts = opts };
    try b.prepare();
    try b.sizeTables();
    if (opts.host_members) try b.markHostBacked();
    try b.allocateAll();
    try b.linkDefaults();
    try b.computeCaptures();
    try b.computeLayouts();
    try b.computeDispatch();
    try b.computeAncestors();
    try b.buildFuncs();
    try b.buildClasses();
    try b.buildResolved();
    return br;
}

/// Extends `base`, a bridge `build` made over the base alone and loaded
/// for this run, with the program `opts.layers[1]` adds: the program's
/// symbols get ids after every id the base holds, and the module and its
/// run-time tables grow in place. `s` holds the base's symbols below
/// `opts.layers[0].syms` numbered as the bake had them; a symbol at or
/// past it that a base entry names was a base local and is never read.
/// The base's growable tables are extended with `a`, which must be the
/// allocator they came from or an arena.
pub fn buildOver(a: Allocator, s: *sema.Sema, base: *Bridge, opts: Options) Error!*Bridge {
    if (opts.layers.len == 0) return error.Unsupported;
    const r = base.m.resolved orelse return error.Unsupported;
    var b: Build = .{ .a = a, .s = s, .br = base, .opts = opts };
    try b.startOver(r);
    base.s = s;
    base.records = opts.records;
    try b.prepare();
    try b.sizeTables();
    if (opts.host_members) try b.markHostBacked();
    try b.allocateAll();
    try b.linkDefaults();
    try b.computeCaptures();
    try b.computeLayouts();
    try b.computeDispatch();
    try b.computeAncestors();
    try b.buildFuncs();
    try b.buildClasses();
    try b.buildResolved();
    return base;
}

// ------------------------------------------------------------ the build ----

/// A loaded base `buildOver` extends: its symbols, files and ids, and
/// the tables it had before the extension replaced them.
const Over = struct {
    prefix: u32,
    files: u32,
    funcs: u32,
    classes: u32,
    statics: u32,
    old: Bridge,
    rt: ir.Resolved,
};

const StaticOwner = union(enum) { file: u32, enum_class: Sym, eager_file: u32 };

const Scope = struct {
    sym: Sym,
    file: u32,
    start: u32,
    end: u32,
    parent: u32 = NONE,
    caps: std.ArrayList(CaptureKey) = .empty,
};

const Use = struct { scope: u32, used: u32 };

const DispatchEntry = struct { slot: u32, func: FuncId };

const Build = struct {
    a: Allocator,
    s: *sema.Sema,
    br: *Bridge,
    opts: Options,
    /// Symbol count the tables are sized to.
    n: u32 = 0,
    /// Declarations reachable from a package: top-level ones, class members,
    /// SAM constructors.
    global: std.DynamicBitSetUnmanaged = .{},
    /// Declarations a body made that a committed record names, and the
    /// members of local classes.
    local: std.DynamicBitSetUnmanaged = .{},
    /// Indexed as a member of its class.
    member: std.DynamicBitSetUnmanaged = .{},
    /// Properties an accessor reads `field` of.
    field_used: std.DynamicBitSetUnmanaged = .{},
    /// Locals some committed record writes.
    written: std.DynamicBitSetUnmanaged = .{},
    /// Classes whose instances natives make as host values (a range, a
    /// pair) and their superclasses: their properties are the host's, their
    /// constructors the native under the class's name (`host_members`).
    host_backed: std.DynamicBitSetUnmanaged = .{},
    marked_locals: bool = false,
    /// SAM constructor function to its fun interface.
    sam_iface: std.AutoHashMapUnmanaged(Sym, Sym) = .empty,
    lambda_rec: std.AutoHashMapUnmanaged(Sym, *const LambdaRec) = .empty,
    origins: std.ArrayList(FuncOrigin) = .empty,
    class_origins: std.ArrayList(ClassOrigin) = .empty,
    /// By ClassId: its members with ids, in symbol order.
    class_members: std.ArrayList(std.ArrayList(Sym)) = .empty,
    statics: std.ArrayList(resolved.StaticRt) = .empty,
    static_owner: std.ArrayList(StaticOwner) = .empty,
    /// Statics before this index have their unit.
    statics_united: usize = 0,
    /// Enum classes allocated since the last units pass.
    pending_enums: std.ArrayList(Sym) = .empty,
    units: std.ArrayList(Unit) = .empty,
    unit_funcs: std.ArrayList(FuncId) = .empty,
    natives: std.ArrayList(resolved.NativeRt) = .empty,
    /// By FuncId, filled when bound.
    func_native: std.AutoHashMapUnmanaged(u32, NativeId) = .empty,
    /// By FuncId, filled when a fast path fronts it.
    func_try: std.AutoHashMapUnmanaged(u32, NativeId) = .empty,
    adapters: std.ArrayList(Adapter) = .empty,
    /// A declaration's qualified name once made (`qualName`): each member
    /// asks for its owners', and a name is asked for again by every native
    /// and host lookup of it.
    qual_names: std.AutoHashMapUnmanaged(Sym, []const u8) = .empty,
    adapter_ids: std.AutoHashMapUnmanaged(Adapter, FuncId) = .empty,
    scopes: std.ArrayList(Scope) = .empty,
    scope_of: std.AutoHashMapUnmanaged(Sym, u32) = .empty,
    uses: std.ArrayList(Use) = .empty,
    layer_ends: std.ArrayList(LayerEnd) = .empty,
    layouts: std.ArrayList(?[]const Slot) = .empty,
    dispatch: std.ArrayList(?[]const DispatchEntry) = .empty,
    /// By ClassId: `ClassRt.host_slot`, filled with the layouts.
    host_slots: std.ArrayList(u32) = .empty,
    /// Extending a loaded base (`buildOver`).
    over: ?Over = null,

    /// The first symbol this build gives ids to: past the base's when
    /// extending one.
    fn firstSym(b: *const Build) u32 {
        return if (b.over) |o| o.prefix else 1;
    }

    /// Ids below these are the base's, which this build keeps.
    fn baseFuncCount(b: *const Build) u32 {
        return if (b.over) |o| o.funcs else 0;
    }

    fn baseClassCount(b: *const Build) u32 {
        return if (b.over) |o| o.classes else 0;
    }

    // ------------------------------------------------------ extending ----

    /// Starts the id lists from the loaded base's, so the program's ids
    /// follow every base id.
    fn startOver(b: *Build, r: *const ir.Resolved) Error!void {
        const a = b.a;
        const old = b.br.*;
        const layer = b.opts.layers[0];
        // The module holds exactly the base's functions and classes.
        if (old.m.funcs.items.len != old.origin.len or old.m.classes.items.len != old.class_origin.len) return error.Unsupported;
        if (old.m.class_ancestors.items.len != old.class_origin.len or old.layout.len != old.class_origin.len) return error.Unsupported;
        b.over = .{
            .prefix = layer.syms,
            .files = layer.files,
            .funcs = @intCast(old.origin.len),
            .classes = @intCast(old.class_origin.len),
            .statics = @intCast(r.statics.len),
            .old = old,
            .rt = r.*,
        };
        try b.origins.appendSlice(a, old.origin);
        try b.class_origins.appendSlice(a, old.class_origin);
        try b.class_members.appendNTimes(a, .empty, old.class_origin.len);
        try b.statics.appendSlice(a, r.statics);
        // Base statics already have their units; no owner matches them.
        try b.static_owner.appendNTimes(a, .{ .file = NONE }, r.statics.len);
        b.statics_united = r.statics.len;
        try b.units.appendSlice(a, old.units);
        for (r.init_units) |u| try b.unit_funcs.append(a, u.func);
        try b.natives.appendSlice(a, r.natives);
        for (r.classes) |c| try b.host_slots.append(a, c.host_slot);
        try b.adapters.appendSlice(a, old.adapters);
        for (old.layout) |l| try b.layouts.append(a, l);
        // The base's fun interfaces keep their SAM methods; the base's
        // references keep their adapters.
        b.br.sam_funcs_of = .empty;
        var sit = old.sam_funcs_of.iterator();
        while (sit.next()) |e| {
            if (e.key_ptr.int() < layer.syms) try b.br.sam_funcs_of.put(a, e.key_ptr.*, e.value_ptr.*);
        }
        b.br.adapter_at = try old.adapter_at.clone(a);
    }

    /// Each base class's dispatch entries, from the module's table.
    fn baseDispatch(b: *Build) Error!void {
        const nb = b.baseClassCount();
        const lists = try b.a.alloc(std.ArrayList(DispatchEntry), nb);
        @memset(lists, .empty);
        var it = b.br.m.method_dispatch.iterator();
        while (it.next()) |e| {
            const c: u32 = @intCast(e.key_ptr.* >> 32);
            if (c >= nb) continue;
            try lists[c].append(b.a, .{ .slot = @truncate(e.key_ptr.*), .func = e.value_ptr.* });
        }
        for (lists, 0..) |*l, c| {
            std.mem.sort(DispatchEntry, l.items, {}, struct {
                fn lt(_: void, x: DispatchEntry, y: DispatchEntry) bool {
                    return x.slot < y.slot;
                }
            }.lt);
            b.dispatch.items[c] = l.items;
        }
    }

    /// A by-Sym table sized to this build's symbols: the base's entries
    /// below its prefix, `none` past it.
    fn extended(b: *Build, comptime T: type, old: []const T, none: T) Error![]T {
        const keep = @min(@min(old.len, b.firstSym()), b.n);
        if (b.over) |o| if (keep == old.len and b.n <= old.len + o.old.sym_room) {
            const out = @constCast(old.ptr)[0..b.n];
            @memset(out[old.len..], none);
            return out;
        };
        const out = try filled(b.a, T, b.n, none);
        @memcpy(out[0..keep], old[0..keep]);
        return out;
    }

    /// A by-id table of `n` entries: the base's first, then `none`.
    fn grown(b: *Build, comptime T: type, old: []const T, n: usize, none: T) Error![]T {
        const out = try filled(b.a, T, n, none);
        const keep = @min(old.len, n);
        @memcpy(out[0..keep], old[0..keep]);
        return out;
    }

    // ------------------------------------------------------ marking ----

    /// Marks every declaration that gets an id and resolves the headers
    /// allocation reads, until resolving makes no new symbol.
    fn prepare(b: *Build) Error!void {
        // Resolving the headers works in sema's scratch, emptied after each
        // declaration: what it keeps goes to sema's own tables.
        const opened = !b.s.scratch_open;
        if (opened) b.s.openScratch();
        defer if (opened) b.s.closeScratch();
        while (true) {
            const n0: u32 = @intCast(b.s.syms.count());
            try b.growBits(n0);
            try b.markGlobals();
            if (!b.marked_locals) {
                try b.markLocals();
                b.marked_locals = true;
            }
            var i: u32 = b.firstSym();
            while (i < n0) : (i += 1) {
                const sym = Sym.from(i);
                if (!b.global.isSet(i) and !b.local.isSet(i)) continue;
                try b.resolveHeader(sym);
                b.s.resetScratch();
            }
            if (b.s.syms.count() == n0) break;
        }
        b.n = @intCast(b.s.syms.count());
    }

    fn growBits(b: *Build, n: u32) Error!void {
        inline for (.{ "global", "local", "member", "field_used", "written" }) |f| {
            if (@field(b, f).bit_length < n) try @field(b, f).resize(b.a, n, false);
        }
    }

    fn resolveHeader(b: *Build, sym: Sym) Error!void {
        const s = b.s;
        switch (s.syms.kind(sym)) {
            .class => _ = try sema.headers.supertypes(s, sym),
            .function, .constructor => {
                if (!isLambda(s, sym)) try sema.headers.functionHeader(s, sym);
                if (b.member.isSet(sym.int())) _ = try sema.members.overridden(s, sym);
            },
            .property => {
                try sema.headers.propertyHeader(s, sym);
                _ = try sema.headers.propertyType(s, sym);
                if (b.member.isSet(sym.int())) _ = try sema.members.overridden(s, sym);
            },
            else => {},
        }
    }

    fn markGlobals(b: *Build) Error!void {
        const s = b.s;
        if (b.over) |o| {
            // Past a loaded base, the top-level declarations are the ones a
            // package indexes; each class marks its members.
            var i: u32 = o.prefix;
            while (i < s.syms.count()) : (i += 1) {
                const d = Sym.from(i);
                const owner = s.syms.owner(d);
                if (owner == .none or s.syms.kind(owner) != .package) continue;
                const listed = sema.symbols.Symbols.members(&s.syms.packageInfo(owner).members, s.syms.name(d));
                if (std.mem.indexOfScalar(Sym, listed, d) == null) continue;
                try b.markDecl(d, false);
            }
        } else {
            var i: u32 = 1;
            while (i < s.syms.count()) : (i += 1) {
                const p = Sym.from(i);
                if (s.syms.kind(p) != .package) continue;
                var it = s.syms.packageInfo(p).members.iterator();
                while (it.next()) |e| for (e.value_ptr.items) |d| try b.markDecl(d, false);
            }
        }
        var it = s.sam_ctors.iterator();
        while (it.next()) |e| {
            const ctor = e.value_ptr.*;
            if (ctor == .none or ctor.int() >= b.global.bit_length or ctor.int() < b.firstSym()) continue;
            // A base interface's SAM constructor made at run.
            if (!b.global.isSet(e.key_ptr.int()) and e.key_ptr.int() >= b.firstSym()) continue;
            b.global.set(ctor.int());
            try b.sam_iface.put(b.a, ctor, e.key_ptr.*);
        }
    }

    fn markDecl(b: *Build, d: Sym, is_member: bool) Error!void {
        const s = b.s;
        if (d.int() >= b.global.bit_length or b.global.isSet(d.int())) return;
        if (d.int() < b.firstSym()) return;
        if (s.syms.flags(d).superseded) return;
        switch (s.syms.kind(d)) {
            .class => {
                b.global.set(d.int());
                if (is_member) b.member.set(d.int());
                var it = s.syms.classInfo(d).members.iterator();
                while (it.next()) |e| for (e.value_ptr.items) |x| {
                    if (s.syms.owner(x) == d) try b.markDecl(x, true);
                };
            },
            .function, .constructor, .property, .enum_entry => {
                b.global.set(d.int());
                if (is_member) b.member.set(d.int());
            },
            else => {},
        }
    }

    /// The local declarations committed records name, the lambda records,
    /// the properties whose `field` is read, and the locals written.
    fn markLocals(b: *Build) Error!void {
        const s = b.s;
        for (b.opts.records) |fr| {
            for (fr.refs) |r| {
                const t = r.target;
                if (t == .none or t.int() >= b.global.bit_length) continue;
                switch (r.kind) {
                    .decl => switch (s.syms.kind(t)) {
                        .function => {
                            if (b.global.isSet(t.int())) continue;
                            b.local.set(t.int());
                            switch (r.detail) {
                                .lambda => |l| try b.lambda_rec.put(b.a, t, l),
                                else => {},
                            }
                        },
                        .class => if (!b.global.isSet(t.int())) try b.markLocalClass(t),
                        else => {},
                    },
                    .read, .write => {
                        if (s.backing_fields.get(t)) |prop| {
                            b.field_used.set(prop.int());
                        } else if (r.kind == .write and s.syms.kind(t) == .local) {
                            b.written.set(t.int());
                        }
                    },
                    else => {},
                }
            }
        }
    }

    fn markLocalClass(b: *Build, c: Sym) Error!void {
        const s = b.s;
        b.local.set(c.int());
        var it = s.syms.classInfo(c).members.iterator();
        while (it.next()) |e| for (e.value_ptr.items) |x| {
            if (s.syms.owner(x) != c) continue;
            switch (s.syms.kind(x)) {
                .class => {
                    b.member.set(x.int());
                    try b.markLocalClass(x);
                },
                .function, .constructor, .property, .enum_entry => {
                    b.local.set(x.int());
                    b.member.set(x.int());
                },
                else => {},
            }
        };
    }

    // --------------------------------------------------- allocation ----

    fn sizeTables(b: *Build) Error!void {
        const a = b.a;
        const br = b.br;
        const n = b.n;
        if (b.over) |o| {
            const old = &o.old;
            br.func_of = try b.extended(FuncId, old.func_of, FuncId.from(NONE));
            br.getter_of = try b.extended(FuncId, old.getter_of, FuncId.from(NONE));
            br.setter_of = try b.extended(FuncId, old.setter_of, FuncId.from(NONE));
            br.defaults_of = try b.extended(FuncId, old.defaults_of, FuncId.from(NONE));
            br.restart_of = try b.extended(FuncId, old.restart_of, FuncId.from(NONE));
            br.singleton_of = try b.extended(StaticId, old.singleton_of, StaticId.from(NONE));
            br.class_of = try b.extended(ClassId, old.class_of, ClassId.from(NONE));
            br.static_of = try b.extended(StaticId, old.static_of, StaticId.from(NONE));
            br.field_of = try b.extended(u32, old.field_of, NONE);
            br.delegate_field_of = try b.extended(u32, old.delegate_field_of, NONE);
            br.native_of = try b.extended(NativeId, old.native_of, .none);
            br.sam_class_of = try b.extended(ClassId, old.sam_class_of, ClassId.from(NONE));
            br.cells = try std.DynamicBitSetUnmanaged.initEmpty(a, n);
            var i: usize = 0;
            while (i < @min(o.prefix, old.cells.bit_length, n)) : (i += 1) {
                if (old.cells.isSet(i)) br.cells.set(i);
            }
        } else {
            br.func_of = try filled(a, FuncId, n, FuncId.from(NONE));
            br.getter_of = try filled(a, FuncId, n, FuncId.from(NONE));
            br.setter_of = try filled(a, FuncId, n, FuncId.from(NONE));
            br.defaults_of = try filled(a, FuncId, n, FuncId.from(NONE));
            br.restart_of = try filled(a, FuncId, n, FuncId.from(NONE));
            br.singleton_of = try filled(a, StaticId, n, StaticId.from(NONE));
            br.class_of = try filled(a, ClassId, n, ClassId.from(NONE));
            br.static_of = try filled(a, StaticId, n, StaticId.from(NONE));
            br.field_of = try filled(a, u32, n, NONE);
            br.delegate_field_of = try filled(a, u32, n, NONE);
            br.native_of = try filled(a, NativeId, n, .none);
            br.sam_class_of = try filled(a, ClassId, n, ClassId.from(NONE));
            br.cells = try std.DynamicBitSetUnmanaged.initEmpty(a, n);
        }
        const nfiles = b.s.files.items.len;
        br.body_files = try std.DynamicBitSetUnmanaged.initEmpty(a, nfiles);
        // A loaded base's bodies are lowered already.
        const first_file = if (b.over) |o| @min(o.files, nfiles) else 0;
        if (b.opts.files.len == 0) {
            br.body_files.setRangeValue(.{ .start = first_file, .end = nfiles }, true);
        } else for (b.opts.files) |f| {
            if (f < nfiles and f >= first_file) br.body_files.set(f);
        }
    }

    fn allocateAll(b: *Build) Error!void {
        const nfiles: u32 = @intCast(b.s.files.items.len);
        if (b.over) |o| {
            // The base's ids end its layer; the program's follow.
            try b.layer_ends.append(b.a, .{ .funcs = o.funcs, .classes = o.classes, .statics = o.statics });
            try b.allocRange(o.prefix, b.n, &b.global, null);
            try b.finishUnits();
            try b.allocRange(o.prefix, b.n, &b.local, .{ o.files, nfiles });
            try b.finishUnits();
            try b.allocAdapters(o.files, nfiles);
            try b.layer_ends.append(b.a, b.endHere());
            try b.layer_ends.append(b.a, b.endHere());
            b.br.layer_ends = b.layer_ends.items;
            b.br.image_funcs = o.funcs;
            b.br.image_prefix = o.prefix;
            return;
        }
        var lo_sym: u32 = 1;
        var lo_file: u32 = 0;
        for (b.opts.layers) |layer| {
            const hi_sym = @min(layer.syms, b.n);
            const hi_file = @min(layer.files, nfiles);
            try b.allocRange(lo_sym, hi_sym, &b.global, null);
            try b.finishUnits();
            try b.allocRange(1, b.n, &b.local, .{ lo_file, hi_file });
            try b.finishUnits();
            try b.allocAdapters(lo_file, hi_file);
            try b.layer_ends.append(b.a, b.endHere());
            lo_sym = @max(lo_sym, hi_sym);
            lo_file = @max(lo_file, hi_file);
        }
        try b.allocRange(lo_sym, b.n, &b.global, null);
        try b.finishUnits();
        try b.allocRange(1, b.n, &b.local, .{ lo_file, nfiles });
        try b.finishUnits();
        try b.allocAdapters(lo_file, nfiles);
        try b.layer_ends.append(b.a, b.endHere());
        b.br.layer_ends = b.layer_ends.items;
    }

    fn endHere(b: *const Build) LayerEnd {
        return .{
            .funcs = @intCast(b.origins.items.len),
            .classes = @intCast(b.class_origins.items.len),
            .statics = @intCast(b.statics.items.len),
        };
    }

    /// Allocates the symbols of `set` in `[lo, hi)`, in symbol order; with
    /// `files`, only those declared in a file of that range.
    fn allocRange(b: *Build, lo: u32, hi: u32, set: *const std.DynamicBitSetUnmanaged, files: ?[2]u32) Error!void {
        var i = lo;
        while (i < hi) : (i += 1) {
            if (!set.isSet(i)) continue;
            const sym = Sym.from(i);
            if (files) |fr| {
                const f = b.s.syms.get(sym).file;
                if (f < fr[0] or f >= fr[1]) continue;
            }
            try b.allocSym(sym);
        }
    }

    fn newFunc(b: *Build, origin: FuncOrigin) Error!FuncId {
        const id = FuncId.from(@intCast(b.origins.items.len));
        try b.origins.append(b.a, origin);
        return id;
    }

    fn newClass(b: *Build, origin: ClassOrigin) Error!ClassId {
        const id = ClassId.from(@intCast(b.class_origins.items.len));
        try b.class_origins.append(b.a, origin);
        try b.class_members.append(b.a, .empty);
        return id;
    }

    fn allocSym(b: *Build, sym: Sym) Error!void {
        const s = b.s;
        switch (s.syms.kind(sym)) {
            .class => {
                const c = try b.newClass(.{ .decl = sym });
                b.br.class_of[sym.int()] = c;
                if (s.syms.classInfo(sym).kind == .enum_class) try b.pending_enums.append(b.a, sym);
                try b.addMember(sym);
            },
            .function => {
                if (b.sam_iface.get(sym)) |iface| return b.allocSam(sym, iface);
                try b.allocFunction(sym);
            },
            .constructor => try b.allocFunction(sym),
            .property => try b.allocProperty(sym),
            .enum_entry => {
                const cls = s.syms.entryInfo(sym).enum_class;
                b.br.static_of[sym.int()] = try b.newStatic(.{ .enum_class = cls }, .null_ref, s.str(s.syms.name(sym)));
            },
            else => {},
        }
    }

    /// Records `sym` among its class's members when it is one.
    fn addMember(b: *Build, sym: Sym) Error!void {
        if (!b.member.isSet(sym.int())) return;
        const owner = b.s.syms.owner(sym);
        const c = b.br.classOfOpt(owner) orelse return;
        try b.class_members.items[c.int()].append(b.a, sym);
    }

    fn allocFunction(b: *Build, f: Sym) Error!void {
        const s = b.s;
        const fl = s.syms.flags(f);
        const abstract = isAbstract(s, f);
        const origin: FuncOrigin = if (b.isNested(f)) .{ .lambda = f } else if (abstract) .{ .abstract = f } else .{ .decl = f };
        const id = try b.newFunc(origin);
        b.br.func_of[f.int()] = id;
        try b.addMember(f);
        const host_op = s.syms.kind(f) == .function and b.opts.host_members and try b.bindHostOp(f, id);
        if (!host_op and s.syms.kind(f) == .function and !fl.has_body and !abstract and !isLambda(s, f)) {
            try b.bindNative(f, id, f, .function);
        }
        if (!host_op and s.syms.kind(f) == .function and fl.has_body and b.opts.host_members and try b.hostSupersedes(f)) {
            try b.bindNative(f, id, f, .function);
        }
        if (s.syms.kind(f) == .function and fl.has_body and !b.func_native.contains(id.int())) try b.bindHostTry(f, id);
        // A synthesized member of a host-backed class (a data class's
        // `componentN`, `copy`) is the host's.
        if (s.syms.kind(f) == .function and fl.synthetic and !abstract and b.isHostBacked(s.syms.owner(f))) {
            try b.bindNative(f, id, f, .function);
        }
        // The constructors of an `expect` class no `actual` supersedes, and
        // of a host-backed class, are the host's constructor of the class or
        // the native registered under its name, which makes the host value.
        if (s.syms.kind(f) == .constructor) {
            const cls = s.syms.owner(f);
            const fqn = s.str(s.syms.classInfo(cls).fqn);
            const host_ctor = if (b.opts.constructors) |c| c(fqn) else null;
            if (host_ctor != null or (s.syms.flags(cls).expect and !s.syms.flags(cls).superseded) or b.isHostBacked(cls)) {
                if (host_ctor orelse b.opts.natives(fqn)) |func| {
                    const nid = NativeId.from(@intCast(b.natives.items.len));
                    const table: resolved.NativeTable = if (host_ctor != null) .constructors else .natives;
                    var rt: resolved.NativeRt = .{ .func = func, .name = fqn, .table = table, .key = fqn };
                    b.nativeShape(f, &rt);
                    try b.natives.append(b.a, rt);
                    try b.func_native.put(b.a, id.int(), nid);
                }
            }
        }
        // A composable taking `$default` fills its defaults itself.
        if (hasDefaults(s, f) and !composableDefaults(s, f)) b.br.defaults_of[f.int()] = try b.newFunc(.{ .defaults = f });
        if (try restartable(s, f)) b.br.restart_of[f.int()] = try b.newFunc(.{ .restart = f });
        // A static of no file, which nothing initializes: the first
        // evaluation of the literal fills it.
        if (b.lambda_rec.get(f)) |rec| if (composableType(s, rec.fn_type) and returnsUnit(s, rec.fn_type)) {
            b.br.singleton_of[f.int()] = try b.newStatic(.{ .file = NONE }, .null_ref, "composable lambda");
        };
    }

    fn allocProperty(b: *Build, p: Sym) Error!void {
        const s = b.s;
        const abstract = isAbstract(s, p);
        const g = try b.newFunc(if (abstract) .{ .abstract = p } else .{ .getter = p });
        b.br.getter_of[p.int()] = g;
        if (s.syms.flags(p).mutable) {
            b.br.setter_of[p.int()] = try b.newFunc(if (abstract) .{ .abstract = p } else .{ .setter = p });
        }
        try b.addMember(p);
        const host_op = b.opts.host_members and try b.bindHostOp(p, g);
        if (!host_op and (b.nativeGetterCandidate(p) or b.hostProperty(p))) {
            try b.bindNative(p, g, p, .getter);
            // A host-served property is set on the host value too.
            if (b.br.setter_of[p.int()].int() != NONE and b.br.native_of[p.int()] != .none) {
                try b.bindNative(p, b.br.setter_of[p.int()], p, .setter);
            }
        }
        // A top-level property the host implements under its FQN reads the
        // host's value (`COROUTINE_SUSPENDED`, the sentinel the natives
        // return), as the name-resolving interpreter binds it.
        if (b.opts.host_members and b.br.native_of[p.int()] == .none and s.syms.propertyInfo(p).receiver == .none) {
            const owner = s.syms.owner(p);
            if (owner != .none and s.syms.kind(owner) == .package and b.opts.natives(try b.qualName(p)) != null) {
                try b.bindNative(p, g, p, .getter);
            }
        }
        const owner = s.syms.owner(p);
        if (owner != .none and s.syms.kind(owner) == .package and b.br.native_of[p.int()] == .none) {
            if (s.syms.propertyInfo(p).has_delegate or try b.hasStorage(p)) {
                const seed = if (s.syms.propertyInfo(p).has_delegate) SlotSeed.null_ref else try b.seedOf(p);
                const file = s.syms.get(p).file;
                const static_owner: StaticOwner = if (try eagerProperty(s, p)) .{ .eager_file = file } else .{ .file = file };
                b.br.static_of[p.int()] = try b.newStatic(static_owner, seed, s.str(s.syms.name(p)));
            }
        }
        // An enum class's `entries` is made once, after the entries, by the
        // class's init unit.
        if (owner != .none and s.syms.kind(owner) == .class and s.syms.classInfo(owner).kind == .enum_class and
            s.syms.flags(p).synthetic and s.syms.flags(p).static and s.syms.name(p) == sema.wk.entries)
        {
            b.br.static_of[p.int()] = try b.newStatic(.{ .enum_class = owner }, .null_ref, s.str(s.syms.name(p)));
        }
    }

    fn allocSam(b: *Build, ctor: Sym, iface: Sym) Error!void {
        const c = try b.newClass(.{ .sam = iface });
        b.br.sam_class_of[iface.int()] = c;
        b.br.func_of[ctor.int()] = try b.newFunc(.{ .sam_ctor = iface });
        try b.br.sam_funcs_of.put(b.a, iface, .{
            .method = try b.newFunc(.{ .sam_method = iface }),
            .equals = try b.newFunc(.{ .sam_equals = iface }),
            .hash_code = try b.newFunc(.{ .sam_hash_code = iface }),
        });
    }

    fn newStatic(b: *Build, owner: StaticOwner, seed: SlotSeed, name: []const u8) Error!StaticId {
        const id = StaticId.from(@intCast(b.statics.items.len));
        try b.statics.append(b.a, .{ .unit = NONE, .seed = seed, .name = name });
        try b.static_owner.append(b.a, owner);
        return id;
    }

    /// Gives the statics allocated since the last pass their init units:
    /// one per file in file order, then one per file for its eager
    /// properties, then one per enum class in symbol order.
    fn finishUnits(b: *Build) Error!void {
        const from = b.statics_united;
        var files: std.ArrayList(u32) = .empty;
        var eager_files: std.ArrayList(u32) = .empty;
        // A static of no file (`.file = NONE`) has no unit: nothing
        // initializes it but its own stores.
        for (b.static_owner.items[from..]) |o| switch (o) {
            .file => |f| if (f != NONE and std.mem.indexOfScalar(u32, files.items, f) == null) try files.append(b.a, f),
            .eager_file => |f| if (std.mem.indexOfScalar(u32, eager_files.items, f) == null) try eager_files.append(b.a, f),
            .enum_class => {},
        };
        std.mem.sort(u32, files.items, {}, std.sort.asc(u32));
        std.mem.sort(u32, eager_files.items, {}, std.sort.asc(u32));
        for (files.items) |f| {
            const u = try b.newUnit(.{ .file = f });
            for (b.static_owner.items[from..], b.statics.items[from..]) |o, *st| {
                if (o == .file and o.file == f) st.unit = u;
            }
        }
        // An eager property read before the start ran its unit (by another
        // file's eager initializer) runs it then, as its guard.
        for (eager_files.items) |f| {
            const u = try b.newUnit(.{ .eager_file = f });
            for (b.static_owner.items[from..], b.statics.items[from..]) |o, *st| {
                if (o == .eager_file and o.eager_file == f) st.unit = u;
            }
        }
        for (b.pending_enums.items) |e| {
            const u = try b.newUnit(.{ .enum_class = e });
            for (b.static_owner.items, b.statics.items) |o, *st| {
                if (o == .enum_class and o.enum_class == e) st.unit = u;
            }
        }
        b.pending_enums.clearRetainingCapacity();
        b.statics_united = b.statics.items.len;
    }

    fn newUnit(b: *Build, unit: Unit) Error!u32 {
        const u: u32 = @intCast(b.units.items.len);
        try b.units.append(b.a, unit);
        try b.unit_funcs.append(b.a, try b.newFunc(.{ .init_unit = u }));
        return u;
    }

    fn allocAdapters(b: *Build, lo_file: u32, hi_file: u32) Error!void {
        const s = b.s;
        var file = lo_file;
        while (file < hi_file and file < b.opts.records.len) : (file += 1) {
            for (b.opts.records[file].refs) |r| {
                const rr = switch (r.detail) {
                    .ref => |x| x,
                    else => continue,
                };
                const k = s.syms.kind(rr.target);
                if (k != .function and k != .constructor) continue;
                const key: Adapter = .{ .target = rr.target, .ty = rr.ty, .bound = std.meta.activeTag(rr.bound) };
                const gop = try b.adapter_ids.getOrPut(b.a, key);
                if (!gop.found_existing) {
                    const idx: u32 = @intCast(b.adapters.items.len);
                    try b.adapters.append(b.a, key);
                    gop.value_ptr.* = try b.newFunc(.{ .adapter = idx });
                }
                try b.br.adapter_at.put(b.a, refKey(file, r.node), gop.value_ptr.*);
            }
        }
    }

    /// An override without defaults of its own takes the bridge of the
    /// declaration it overrides that has them.
    fn linkDefaults(b: *Build) Error!void {
        const s = b.s;
        var i: u32 = b.firstSym();
        while (i < b.n) : (i += 1) {
            const f = Sym.from(i);
            if (b.br.func_of[i].int() == NONE) continue;
            if (s.syms.kind(f) != .function or b.br.defaults_of[i].int() != NONE) continue;
            if (!b.member.isSet(i)) continue;
            if (try b.inheritedDefaults(f, 0)) |d| b.br.defaults_of[i] = d;
        }
    }

    fn inheritedDefaults(b: *Build, f: Sym, depth: u32) Error!?FuncId {
        if (depth > 64) return null;
        for (try sema.members.overridden(b.s, f)) |q| {
            if (q.int() >= b.n) continue;
            if (b.br.defaults_of[q.int()].int() != NONE) return b.br.defaults_of[q.int()];
            if (try b.inheritedDefaults(q, depth + 1)) |d| return d;
        }
        return null;
    }

    // ------------------------------------------------------ natives ----

    /// Binds bodyless `decl` (its function, getter or setter `id`) to the
    /// native the resolver has under its FQN or, for an extension, its
    /// receiver-qualified host symbol. A member of a class no native binds
    /// is served by the host's member of that name (`host_members`).
    fn bindNative(b: *Build, decl: Sym, id: FuncId, key: Sym, kind: MemberKind) Error!void {
        const s = b.s;
        const fqn = try b.qualName(decl);
        if (kind == .function and s.syms.kind(decl) == .function) if (externalSymbolName(s, decl)) |symbol| {
            return b.bindExternalSymbol(decl, id, key, fqn, symbol);
        };
        // A setter never shares its getter's native under the property's
        // FQN, and a property its declaration stores (a constructor
        // property, one with an initializer) is read from the host value
        // by name: the table's entry under the same FQN is a function's
        // (`IntProgression.first()` beside the property `first`).
        const by_name = kind == .setter or (kind == .getter and !b.nativeGetterCandidate(decl));
        var lookup = fqn;
        var f = if (by_name) null else b.opts.natives(fqn);
        // A companion's member is the host's under its class's name, the
        // static (`klio.Thread.currentThread`).
        if (f == null and !by_name) if (companionStatic(s, decl)) |outer| {
            lookup = try std.fmt.allocPrint(b.a, "{s}.{s}", .{ s.str(s.syms.classInfo(outer).fqn), s.str(s.syms.name(decl)) });
            f = b.opts.natives(lookup);
        };
        // A host native of a companion member takes no companion.
        const static_ = f != null and companionStatic(s, decl) != null;
        if (f == null and !by_name) if (b.opts.host_symbol) |hs| {
            if (receiverWritten(s, decl)) |recv| {
                if (hs(fqn, recv, s.str(s.syms.name(decl)))) |sym| {
                    lookup = try b.a.dupe(u8, sym);
                    f = b.opts.natives(lookup);
                }
            }
        };
        var rt: resolved.NativeRt = undefined;
        if (f) |func| {
            rt = .{ .func = func, .name = fqn, .table = .natives, .key = lookup, .static_ = static_ };
        } else {
            if (!b.opts.host_members) return;
            // A member of a host-backed class, or an extension of the base
            // (`CharArray.concatToString`), that the VM implements; any
            // other bodyless declaration has no implementation here.
            rt = (try b.hostFnBinding(fqn, kind)) orelse return;
        }
        if (kind == .function and s.syms.kind(decl) == .function) b.nativeShape(decl, &rt);
        rt.receiver = (isInstanceMember(s, decl) and !static_) or receiverFirst(s, decl);
        const nid = NativeId.from(@intCast(b.natives.items.len));
        try b.natives.append(b.a, rt);
        if (b.br.native_of[key.int()] == .none) b.br.native_of[key.int()] = nid;
        try b.func_native.put(b.a, id.int(), nid);
    }

    /// Binds `external` function `decl` to the host function registered
    /// under `symbol`, its `@ExternalSymbolName`, as Kotlin/Native binds it,
    /// whatever its own name: private names repeat across files. A symbol
    /// no binding registers binds a native that fails the call naming the
    /// function and the symbol.
    fn bindExternalSymbol(b: *Build, decl: Sym, id: FuncId, key: Sym, fqn: []const u8, symbol: []const u8) Error!void {
        const s = b.s;
        var rt: resolved.NativeRt = if (b.opts.natives(symbol)) |func|
            .{ .func = func, .name = fqn, .table = .natives, .key = symbol }
        else
            .{ .func = hostMemberUnbound, .name = fqn, .key = symbol, .op = .missing_symbol };
        b.nativeShape(decl, &rt);
        rt.static_ = companionStatic(s, decl) != null;
        rt.receiver = (isInstanceMember(s, decl) and !rt.static_) or receiverFirst(s, decl);
        const nid = NativeId.from(@intCast(b.natives.items.len));
        try b.natives.append(b.a, rt);
        if (b.br.native_of[key.int()] == .none) b.br.native_of[key.int()] = nid;
        try b.func_native.put(b.a, id.int(), nid);
    }

    /// Puts the fast path the VM has for `f` in front of its body.
    fn bindHostTry(b: *Build, f: Sym, id: FuncId) Error!void {
        const ht = b.opts.host_tries orelse return;
        const fqn = try b.qualName(f);
        var buf: [512]u8 = undefined;
        const key = resolved.hostKey(&buf, fqn, .function) orelse return;
        const t = ht(key) orelse return;
        const nid = NativeId.from(@intCast(b.natives.items.len));
        try b.natives.append(b.a, .{ .func = hostMemberUnbound, .name = fqn, .table = .tries, .key = try b.a.dupe(u8, key), .host_try = t, .receiver = isInstanceMember(b.s, f) });
        try b.func_try.put(b.a, id.int(), nid);
    }

    /// The native of the member the VM implements under `fqn` and `kind`,
    /// or null when it implements none.
    fn hostFnBinding(b: *Build, fqn: []const u8, kind: MemberKind) Error!?resolved.NativeRt {
        const hf = b.opts.host_fns orelse return null;
        var buf: [512]u8 = undefined;
        const key = resolved.hostKey(&buf, fqn, kind) orelse return null;
        const f = hf(key) orelse return null;
        return .{ .func = hostMemberUnbound, .name = fqn, .table = .members, .key = try b.a.dupe(u8, key), .host_fn = f };
    }

    /// The class whose companion declares `decl`, or null.
    fn companionStatic(s: *sema.Sema, decl: Sym) ?Sym {
        const owner = s.syms.owner(decl);
        if (owner == .none or s.syms.kind(owner) != .class or s.syms.classInfo(owner).kind != .companion) return null;
        const outer = s.syms.owner(owner);
        if (outer == .none or s.syms.kind(outer) != .class) return null;
        return outer;
    }

    /// Binds `decl`'s function `id` to the compiler intrinsic the host
    /// answers, when it is one (`kotlin.coroutines.coroutineContext`, the
    /// serialization plugin's lookup of a class's generated serializer).
    fn bindHostOp(b: *Build, decl: Sym, id: FuncId) Error!bool {
        const ops = std.StaticStringMap(resolved.HostOp).initComptime(.{
            .{ "kotlin.coroutines.coroutineContext", .coroutine_context },
            .{ "kotlinx.serialization.__klsx_companionSerializer", .generated_serializer },
            .{ "kotlin.stackTrace", .stack_frames },
            .{ "kotlin.__klioStackFrames", .stack_frames },
            .{ "kotlin.__klioPrintErr", .print_err },
        });
        const fqn = try b.qualName(decl);
        const op = ops.get(fqn) orelse return false;
        const nid = NativeId.from(@intCast(b.natives.items.len));
        try b.natives.append(b.a, .{ .func = hostMemberUnbound, .name = fqn, .op = op });
        if (b.br.native_of[decl.int()] == .none) b.br.native_of[decl.int()] = nid;
        try b.func_native.put(b.a, id.int(), nid);
        return true;
    }

    /// Where function or constructor `decl`'s vararg sits and how many
    /// reified type values its run ends with, for natives that take them
    /// spread (`spread_varargs`).
    fn nativeShape(b: *const Build, decl: Sym, rt: *resolved.NativeRt) void {
        if (!b.opts.spread_varargs) return;
        const s = b.s;
        const info = s.syms.functionInfo(decl);
        for (info.type_params) |tp| {
            if (s.syms.flags(tp).reified) rt.reified += 1;
        }
        for (info.params, 0..) |p, i| {
            if (s.syms.flags(p).vararg) rt.vararg_back = @intCast(info.params.len - 1 - i);
        }
    }

    /// Marks the classes of the host value kinds and their superclasses.
    fn markHostBacked(b: *Build) Error!void {
        const s = b.s;
        b.host_backed = try std.DynamicBitSetUnmanaged.initEmpty(b.a, b.n);
        var fqns: std.ArrayList([]const u8) = .empty;
        // Throwables and `Result` are classes of the base's own, which their
        // Kotlin bodies make; only the host kinds whose values natives make
        // are marked.
        for (host_kinds) |k| switch (k.tag) {
            .Exception, .Result => {},
            else => try fqns.append(b.a, k.fqn),
        };
        inline for (@typeInfo(runtime.RangeKind).@"enum".fields) |f| {
            try fqns.append(b.a, "kotlin.ranges." ++ f.name ++ "Range");
            try fqns.append(b.a, "kotlin.ranges." ++ f.name ++ "Progression");
        }
        for (fqns.items) |fqn| {
            var cls = s.classByFqn(fqn);
            var depth: u32 = 0;
            while (cls != .none and cls != s.builtins.any and depth < 32) : (depth += 1) {
                if (s.syms.kind(cls) != .class or s.syms.classInfo(cls).kind == .interface) break;
                if (cls.int() < b.n) b.host_backed.set(cls.int());
                var next: Sym = .none;
                for (try sema.headers.supertypes(s, cls)) |st| {
                    const sc = s.types.classSym(st);
                    if (sc == .none or s.syms.kind(sc) != .class) continue;
                    if (s.syms.classInfo(sc).kind == .interface) continue;
                    next = sc;
                }
                cls = next;
            }
        }
    }

    fn isHostBacked(b: *const Build, cls: Sym) bool {
        return cls.int() < b.host_backed.bit_length and b.host_backed.isSet(cls.int());
    }

    /// A property of a host-backed class whose getter only returns its
    /// value: the host holds it.
    fn hostProperty(b: *const Build, p: Sym) bool {
        const s = b.s;
        const owner = s.syms.owner(p);
        if (owner == .none or s.syms.kind(owner) != .class or !b.isHostBacked(owner)) return false;
        if (isAbstract(s, p)) return false;
        return switch (s.syms.get(p).decl) {
            .class_param => true,
            .property => !s.syms.propertyInfo(p).written.getter and !s.syms.propertyInfo(p).has_delegate,
            else => false,
        };
    }

    /// The class member function or property accessor `id` is, with which
    /// of them.
    fn memberOf(b: *Build, origin: FuncOrigin, id: FuncId) ?struct { Sym, MemberKind } {
        const s = b.s;
        const sym, const kind: MemberKind = switch (origin) {
            .decl => |d| .{ d, .function },
            .getter => |p| .{ p, .getter },
            .setter => |p| .{ p, .setter },
            .abstract => |x| switch (s.syms.kind(x)) {
                .function => .{ x, .function },
                .property => .{ x, if (b.br.setter_of[x.int()] == id) .setter else .getter },
                else => return null,
            },
            else => return null,
        };
        if (s.syms.kind(sym) != .function and s.syms.kind(sym) != .property) return null;
        const owner = s.syms.owner(sym);
        if (owner == .none or s.syms.kind(owner) != .class) return null;
        return .{ sym, kind };
    }

    /// A property declared with no initializer, accessor or delegate that
    /// is not abstract: a builtin's member, answered by a native when the
    /// resolver has one.
    fn nativeGetterCandidate(b: *Build, p: Sym) bool {
        const s = b.s;
        const fl = s.syms.flags(p);
        if (fl.has_body or fl.lateinit or fl.synthetic or isAbstract(s, p)) return false;
        if (s.syms.get(p).decl != .property) return false;
        if (s.syms.propertyInfo(p).written.explicit_field) return false;
        const owner = s.syms.owner(p);
        if (owner != .none and s.syms.kind(owner) == .class and s.syms.classInfo(owner).kind == .interface) return false;
        return true;
    }

    // ------------------------------------------------ declarations ----

    /// A lambda, anonymous function or local function: a function a body
    /// declares.
    /// Whether the host's native under top-level function `f`'s FQN runs in
    /// place of its body, as the host binds it: a klio actual's placeholder
    /// body (`__klioMonitorEnter`) or a stdlib function the host serves. A
    /// generic overload with a concrete sibling of its arity keeps its
    /// body, since the native implements the concrete family.
    fn hostSupersedes(b: *Build, f: Sym) Error!bool {
        const s = b.s;
        const owner = s.syms.owner(f);
        if (owner == .none or s.syms.kind(owner) != .package) return false;
        if (b.local.isSet(f.int())) return false;
        const info = s.syms.functionInfo(f);
        if (info.receiver != .none or s.syms.flags(f).expect) return false;
        // An inline function's body is its meaning: a lambda passed to it
        // may return from the caller, which no native can do.
        if (s.syms.flags(f).inline_) return false;
        if (b.opts.natives(try b.qualName(f)) == null) return false;
        if (info.type_params.len == 0) return true;
        // Where the name has non-generic overloads, the native serves those
        // (`maxOf(Int, Int)`), and each generic one (`maxOf(a, b, c,
        // comparator)`) is its own algorithm.
        for (sema.scope.membersOf(s, owner, s.syms.name(f))) |g| {
            if (g == f or s.syms.kind(g) != .function) continue;
            const gi = s.syms.functionInfo(g);
            if (gi.receiver == .none and gi.type_params.len == 0) return false;
        }
        return true;
    }

    fn isNested(b: *const Build, f: Sym) bool {
        const s = b.s;
        if (s.syms.kind(f) != .function) return false;
        return switch (s.syms.get(f).decl) {
            .lambda, .anon_fun => true,
            .function => b.local.isSet(f.int()) and !b.member.isSet(f.int()),
            else => false,
        };
    }

    /// Whether a property has a backing field: not abstract, not in an
    /// interface, not an extension, not delegated or forwarded, and a
    /// constructor property, or with an initializer, `lateinit`, an
    /// explicit field, a default getter, a default setter of a `var`, or
    /// an accessor that reads `field`.
    fn hasStorage(b: *Build, p: Sym) Error!bool {
        const s = b.s;
        const fl = s.syms.flags(p);
        const info = s.syms.propertyInfo(p);
        if (isAbstract(s, p) or fl.static) return false;
        if (info.has_delegate or info.forwards != .none) return false;
        if (b.br.native_of[p.int()] != .none) return false;
        const owner = s.syms.owner(p);
        if (owner != .none and s.syms.kind(owner) == .class and s.syms.classInfo(owner).kind == .interface) return false;
        try sema.headers.propertyHeader(s, p);
        if (s.syms.propertyInfo(p).receiver != .none) return false;
        if (info.from_ctor) return true;
        if (s.syms.get(p).decl != .property) return false;
        const written = info.written;
        if (written.init or fl.lateinit or written.explicit_field) return true;
        if (!written.getter) return true;
        if (fl.mutable and !written.setter) return true;
        return b.field_used.isSet(p.int());
    }

    /// The seed of a slot holding `p`: the zero of a non-null primitive,
    /// else null.
    fn seedOf(b: *Build, p: Sym) Error!SlotSeed {
        const s = b.s;
        const t = try sema.headers.propertyType(s, p);
        return seedOfType(s, t);
    }

    /// The function `Any` declares by `name` (`equals`, `hashCode`): the
    /// root of that slot.
    fn anyMember(b: *Build, name: sema.Name) ?FuncId {
        const s = b.s;
        const any = s.builtins.any;
        if (any == .none) return null;
        for (sema.symbols.Symbols.members(&s.syms.classInfo(any).members, name)) |m| {
            if (s.syms.kind(m) == .function) if (b.br.funcOfOpt(m)) |f| return f;
        }
        return null;
    }

    fn qualName(b: *Build, sym: Sym) Error![]const u8 {
        const s = b.s;
        if (s.syms.kind(sym) == .class) return s.str(s.syms.classInfo(sym).fqn);
        const nm = s.str(s.syms.name(sym));
        const owner = s.syms.owner(sym);
        if (owner == .none) return nm;
        if (b.qual_names.get(sym)) |q| return q;
        const q = switch (s.syms.kind(owner)) {
            .package => blk: {
                const pf = s.str(s.syms.packageInfo(owner).fqn);
                if (pf.len == 0) return nm;
                break :blk try std.fmt.allocPrint(b.a, "{s}.{s}", .{ pf, nm });
            },
            else => try std.fmt.allocPrint(b.a, "{s}.{s}", .{ try b.qualName(owner), nm }),
        };
        try b.qual_names.put(b.a, sym, q);
        return q;
    }

    // ----------------------------------------------------- captures ----

    /// Each nested body's captures and each local class's captured values,
    /// from the records its source range holds, and the locals that live in
    /// cells. A body also needs what the local functions it calls and the
    /// local classes it constructs capture; that closes to a fixpoint.
    fn computeCaptures(b: *Build) Error!void {
        const s = b.s;
        // Scopes: every nested function and local class, by file.
        var i: u32 = b.firstSym();
        while (i < b.n) : (i += 1) {
            if (!b.local.isSet(i)) continue;
            const sym = Sym.from(i);
            const k = s.syms.kind(sym);
            const is_scope = (k == .function and b.isNested(sym)) or k == .class;
            if (!is_scope) continue;
            const sp = declSpan(s, sym) orelse continue;
            try b.scope_of.put(b.a, sym, @intCast(b.scopes.items.len));
            try b.scopes.append(b.a, .{ .sym = sym, .file = s.syms.get(sym).file, .start = sp.start, .end = sp.end });
        }
        // Per file, the scopes by start, and each one's enclosing scope.
        const nfiles = s.files.items.len;
        const by_file = try b.a.alloc(std.ArrayList(u32), nfiles);
        @memset(by_file, .empty);
        for (b.scopes.items, 0..) |sc, idx| {
            if (sc.file < nfiles) try by_file[sc.file].append(b.a, @intCast(idx));
        }
        for (by_file) |*list| {
            std.mem.sort(u32, list.items, b.scopes.items, struct {
                fn lt(scs: []const Scope, x: u32, y: u32) bool {
                    const sx = scs[x];
                    const sy = scs[y];
                    if (sx.start != sy.start) return sx.start < sy.start;
                    return sx.end > sy.end;
                }
            }.lt);
            var stack: std.ArrayList(u32) = .empty;
            for (list.items) |idx| {
                const sc = &b.scopes.items[idx];
                while (stack.items.len != 0) {
                    const top = b.scopes.items[stack.items[stack.items.len - 1]];
                    if (top.start <= sc.start and sc.end <= top.end) break;
                    _ = stack.pop();
                }
                if (stack.items.len != 0) sc.parent = stack.items[stack.items.len - 1];
                try stack.append(b.a, idx);
            }
        }
        // What each record in a scope reads, and which scopes it needs.
        for (b.opts.records, 0..) |fr, file| {
            if (file >= nfiles) break;
            const list = by_file[file].items;
            if (list.len == 0) continue;
            for (fr.refs) |r| {
                if (r.kind == .decl or r.kind == .return_) continue;
                const at = b.innermost(list, r.anchor.start, r.anchor.end) orelse continue;
                if (r.kind == .read or r.kind == .write) {
                    if (b.nameKey(r.target)) |k| _ = try b.addUp(at, k);
                }
                // A reified type parameter a type test or a call's type
                // arguments name is a value of its function, captured like
                // a local.
                switch (r.detail) {
                    .type_test => |t| try b.reifiedKeys(t.ty, at, 0),
                    .call => |c| for (c.type_args) |ta| try b.reifiedKeys(ta, at, 0),
                    else => {},
                }
                try b.receiverKeys(r, at);
                try b.noteUses(r, at);
            }
        }
        // Close over the local functions called and local classes made.
        var changed = true;
        while (changed) {
            changed = false;
            for (b.uses.items) |u| {
                var j: usize = 0;
                while (j < b.scopes.items[u.used].caps.items.len) : (j += 1) {
                    const k = b.scopes.items[u.used].caps.items[j];
                    if (try b.addUp(u.scope, k)) changed = true;
                }
            }
        }
        // Cells: a captured `var`, or a `val` written after its declaration.
        for (b.scopes.items) |sc| {
            for (sc.caps.items) |k| switch (k) {
                .local => |l| {
                    if (s.syms.kind(l) != .local) continue;
                    if (s.syms.flags(l).mutable or b.written.isSet(l.int())) b.br.cells.set(l.int());
                },
                .receiver => {},
            };
        }
    }

    /// The innermost scope of `list` (sorted by start) holding
    /// `[start, end)`.
    fn innermost(b: *const Build, list: []const u32, start: u32, end: u32) ?u32 {
        const scs = b.scopes.items;
        var lo: usize = 0;
        var hi: usize = list.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (scs[list[mid]].start <= start) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return null;
        var cur: u32 = list[lo - 1];
        while (true) {
            const sc = scs[cur];
            if (sc.start <= start and end <= sc.end) return cur;
            if (sc.parent == NONE) return null;
            cur = sc.parent;
        }
    }

    /// What a read or write of `t` captures: the local or parameter, or for
    /// a backing field its class's `this`.
    /// Whether class `cls` is an object or companion, whose `this` is its
    /// singleton.
    fn isSingleton(b: *const Build, cls: Sym) bool {
        if (cls == .none or b.s.syms.kind(cls) != .class) return false;
        return switch (b.s.syms.classInfo(cls).kind) {
            .object, .companion => true,
            else => false,
        };
    }

    fn nameKey(b: *const Build, t: Sym) ?CaptureKey {
        const s = b.s;
        if (t == .none) return null;
        if (s.backing_fields.get(t)) |prop| {
            const owner = s.syms.owner(prop);
            // An object's or companion's field is reached through its
            // singleton, which no body captures.
            if (owner != .none and s.syms.kind(owner) == .class and !b.isSingleton(owner)) return .{ .receiver = .{ .kind = .class_this, .owner = owner } };
            return null;
        }
        return switch (s.syms.kind(t)) {
            .local, .value_param => .{ .local = t },
            else => null,
        };
    }

    /// The reified type parameters type `t` mentions, as captures of scope
    /// `at`.
    fn reifiedKeys(b: *Build, t_in: TypeId, at: u32, depth: u32) Error!void {
        const s = b.s;
        if (t_in == .none or depth > 16) return;
        // A call's type arguments are recorded before an enclosing call
        // fixes them (`println(make<R>(x))`): read them solved.
        const t = try sema.infer.zonk(s, t_in);
        switch (s.types.get(t)) {
            .param => |p| if (s.syms.flags(p.sym).reified) {
                _ = try b.addUp(at, .{ .local = p.sym });
            },
            else => for (s.types.argsOf(t)) |arg| try b.reifiedKeys(arg.ty, at, depth + 1),
        }
    }

    fn receiverKeys(b: *Build, r: Ref, at: u32) Error!void {
        try b.addReceiver(r.dispatch, at);
        try b.addReceiver(r.extension, at);
        for (r.contexts) |c| try b.addReceiver(c, at);
        switch (r.detail) {
            .call => |c| {
                try b.addReceiver(c.dispatch, at);
                try b.addReceiver(c.extension, at);
                for (c.contexts) |x| try b.addReceiver(x, at);
            },
            .ref => |rr| {
                try b.addReceiver(rr.bound, at);
                try b.addReceiver(rr.extension, at);
            },
            else => {},
        }
    }

    fn addReceiver(b: *Build, recv: Receiver, at: u32) Error!void {
        switch (recv) {
            .implicit => |im| {
                const kind: ImplicitKind = switch (im.kind) {
                    .object => return,
                    // `super` of an object or companion is its singleton.
                    .super_ => if (b.isSingleton(im.owner)) return else .class_this,
                    else => im.kind,
                };
                _ = try b.addUp(at, .{ .receiver = .{ .kind = kind, .owner = im.owner } });
            },
            else => {},
        }
    }

    /// The local functions and local classes a record in scope `at` needs
    /// the captures of.
    fn noteUses(b: *Build, r: Ref, at: u32) Error!void {
        const s = b.s;
        var targets: [3]Sym = .{ r.target, .none, .none };
        switch (r.detail) {
            .call => |c| targets[1] = c.callee,
            .ref => |rr| targets[2] = rr.target,
            else => {},
        }
        for (targets) |t| {
            if (t == .none or t.int() >= b.n) continue;
            var used = b.scope_of.get(t);
            if (used == null and s.syms.kind(t) == .constructor) used = b.scope_of.get(s.syms.owner(t));
            const u = used orelse continue;
            // A class's own members and nested bodies use it from inside.
            if (u == at) continue;
            for (b.uses.items) |e| {
                if (e.scope == at and e.used == u) break;
            } else try b.uses.append(b.a, .{ .scope = at, .used = u });
        }
    }

    /// Adds `k` to scope `at` and each enclosing scope it is foreign to;
    /// true when any scope gained it.
    fn addUp(b: *Build, at: u32, k: CaptureKey) Error!bool {
        var added = false;
        var cur = at;
        while (cur != NONE) {
            const sc = &b.scopes.items[cur];
            if (b.within(k.sym(), sc.sym)) break;
            // An inner class reaches what its outer class captures, and the
            // outer classes' `this`, through its outer instance: the outer
            // class captures it instead.
            if (b.isInnerClass(sc.sym)) {
                cur = sc.parent;
                continue;
            }
            for (sc.caps.items) |x| {
                if (x.eql(k)) break;
            } else {
                try sc.caps.append(b.a, k);
                added = true;
            }
            cur = sc.parent;
        }
        return added;
    }

    /// Whether `sym` is an inner class of a class.
    fn isInnerClass(b: *const Build, sym: Sym) bool {
        const s = b.s;
        if (s.syms.kind(sym) != .class or !s.syms.flags(sym).inner) return false;
        const outer = s.syms.owner(sym);
        return outer != .none and s.syms.kind(outer) == .class;
    }

    /// Whether `x` is `scope` or declared inside it.
    fn within(b: *const Build, x: Sym, scope: Sym) bool {
        var cur = x;
        var depth: u32 = 0;
        while (cur != .none and depth < 256) : (depth += 1) {
            if (cur == scope) return true;
            const k = b.s.syms.kind(cur);
            if (k == .package) return false;
            cur = b.s.syms.owner(cur);
        }
        return false;
    }

    fn scopeCaptures(b: *const Build, sym: Sym) []const CaptureKey {
        const idx = b.scope_of.get(sym) orelse return &.{};
        return b.scopes.items[idx].caps.items;
    }

    // ------------------------------------------------------ layouts ----

    fn computeLayouts(b: *Build) Error!void {
        const nc = b.class_origins.items.len;
        // A loaded base's layouts are in place already.
        try b.layouts.appendNTimes(b.a, null, nc - b.layouts.items.len);
        try b.host_slots.appendNTimes(b.a, NONE, nc - b.host_slots.items.len);
        const old: Bridge = if (b.over) |o| o.old else .{ .s = b.s, .m = b.br.m };
        b.br.outer_slot = try b.grown(u32, old.outer_slot, nc, NONE);
        b.br.capture_base = try b.grown(u32, old.capture_base, nc, NONE);
        b.br.class_captures = try b.grown([]const CaptureKey, old.class_captures, nc, &.{});
        b.br.by_slots = try b.grown([]const u32, old.by_slots, nc, &.{});
        var c: u32 = b.baseClassCount();
        while (c < nc) : (c += 1) _ = try b.layoutOf(ClassId.from(c), 0);
        const out = try b.a.alloc([]const Slot, nc);
        for (out, b.layouts.items) |*o, l| o.* = l.?;
        b.br.layout = out;
    }

    /// Whether property `p` is `@Volatile` (`kotlin.concurrent.Volatile`, or
    /// `kotlin.jvm.Volatile` on the JVM's side of a shared source).
    fn isVolatile(b: *Build, p: Sym) Error!bool {
        const s = b.s;
        inline for (.{ "kotlin.concurrent.Volatile", "kotlin.jvm.Volatile" }) |fqn| {
            if (try sema.headers.hasAnnotation(s, p, .decl, s.classByFqn(fqn))) return true;
        }
        return false;
    }

    fn layoutOf(b: *Build, c: ClassId, depth: u32) Error![]const Slot {
        if (b.layouts.items[c.int()]) |l| return l;
        const s = b.s;
        var slots: std.ArrayList(Slot) = .empty;
        switch (b.class_origins.items[c.int()]) {
            .sam => try slots.append(b.a, .{ .name = "function" }),
            .decl => |cls| {
                if (depth < 64) {
                    if (b.superClass(cls)) |sup| {
                        try slots.appendSlice(b.a, try b.layoutOf(sup, depth + 1));
                        b.host_slots.items[c.int()] = b.host_slots.items[sup.int()];
                        // Below a class the host constructs, the value its
                        // constructor makes.
                        if (b.host_slots.items[sup.int()] == NONE and b.hostConstructed(sup)) {
                            b.host_slots.items[c.int()] = @intCast(slots.items.len);
                            try slots.append(b.a, .{ .name = "$host" });
                        }
                    }
                }
                const owner = s.syms.owner(cls);
                if (s.syms.flags(cls).inner and owner != .none and s.syms.kind(owner) == .class) {
                    b.br.outer_slot[c.int()] = @intCast(slots.items.len);
                    try slots.append(b.a, .{ .name = "$outer" });
                }
                const members = b.class_members.items[c.int()].items;
                for (members) |p| {
                    if (s.syms.kind(p) != .property) continue;
                    if (!try b.hasStorage(p)) continue;
                    b.br.field_of[p.int()] = @intCast(slots.items.len);
                    try slots.append(b.a, .{ .name = s.str(s.syms.name(p)), .seed = try b.seedOf(p), .volatile_ = try b.isVolatile(p) });
                }
                for (members) |p| {
                    if (s.syms.kind(p) != .property or !s.syms.propertyInfo(p).has_delegate) continue;
                    b.br.delegate_field_of[p.int()] = @intCast(slots.items.len);
                    try slots.append(b.a, .{ .name = try std.fmt.allocPrint(b.a, "{s}$delegate", .{s.str(s.syms.name(p))}) });
                }
                const delegates = supertypeDelegates(s, cls);
                if (delegates.len != 0) {
                    const bys = try b.a.alloc(u32, delegates.len);
                    for (delegates, bys, 0..) |d, *o, i| {
                        if (!d) {
                            o.* = NONE;
                            continue;
                        }
                        o.* = @intCast(slots.items.len);
                        try slots.append(b.a, .{ .name = try std.fmt.allocPrint(b.a, "$$delegate_{d}", .{i}) });
                    }
                    @constCast(b.br.by_slots)[c.int()] = bys;
                }
                if (b.scope_of.contains(cls)) {
                    const keys = b.scopeCaptures(cls);
                    b.br.capture_base[c.int()] = @intCast(slots.items.len);
                    @constCast(b.br.class_captures)[c.int()] = keys;
                    for (keys) |k| try slots.append(b.a, .{ .name = try b.captureName(k) });
                }
            },
        }
        b.layouts.items[c.int()] = slots.items;
        return slots.items;
    }

    /// Whether a constructor of class `c` is a native, which makes a host
    /// value rather than initializing an instance.
    fn hostConstructed(b: *Build, c: ClassId) bool {
        const s = b.s;
        const cls = switch (b.class_origins.items[c.int()]) {
            .decl => |d| d,
            .sam => return false,
        };
        if (c.int() < b.baseClassCount()) {
            // A loaded base's class: its symbol is below the prefix.
            if (cls.int() >= b.firstSym()) return false;
        }
        for (sema.symbols.Symbols.members(&s.syms.classInfo(cls).members, sema.wk.init)) |ctor| {
            if (s.syms.kind(ctor) != .constructor) continue;
            const f = b.br.funcOfOpt(ctor) orelse continue;
            if (c.int() < b.baseClassCount()) {
                const r = b.over.?.rt;
                if (f.int() < r.func_native.len and r.func_native[f.int()] != .none) return true;
            } else if (b.func_native.contains(f.int())) return true;
        }
        return false;
    }

    fn captureName(b: *Build, k: CaptureKey) Error![]const u8 {
        return switch (k) {
            .local => |l| std.fmt.allocPrint(b.a, "$cap${s}", .{b.s.str(b.s.syms.name(l))}),
            .receiver => |r| std.fmt.allocPrint(b.a, "$cap$this@{s}", .{b.s.str(b.s.syms.name(r.owner))}),
        };
    }

    /// The class's non-interface supertype, when it has an id.
    fn superClass(b: *Build, cls: Sym) ?ClassId {
        const s = b.s;
        const sts = s.syms.classInfo(cls).supertypes;
        for (sts) |st| {
            const sc = s.types.classSym(st);
            if (sc == .none or s.syms.kind(sc) != .class) continue;
            if (s.syms.classInfo(sc).kind == .interface) continue;
            return b.br.classOfOpt(sc);
        }
        return null;
    }

    /// The direct supertypes with ids, the class supertype last.
    fn supersOf(b: *Build, c: ClassId) Error![]const ClassId {
        const s = b.s;
        var out: std.ArrayList(ClassId) = .empty;
        switch (b.class_origins.items[c.int()]) {
            .sam => |iface| if (b.br.classOfOpt(iface)) |ic| try out.append(b.a, ic),
            .decl => |cls| {
                var class_super: ?ClassId = null;
                for (s.syms.classInfo(cls).supertypes) |st| {
                    const sc = s.types.classSym(st);
                    if (sc == .none or s.syms.kind(sc) != .class) continue;
                    const id = b.br.classOfOpt(sc) orelse continue;
                    if (s.syms.classInfo(sc).kind == .interface) {
                        if (std.mem.indexOfScalar(ClassId, out.items, id) == null) try out.append(b.a, id);
                    } else class_super = id;
                }
                if (class_super) |id| try out.append(b.a, id);
            },
        }
        return out.items;
    }

    // ----------------------------------------------------- dispatch ----

    /// `(class, root slot) -> implementation`: each class inherits its
    /// supertypes' entries (the class supertype last, so a class
    /// implementation wins over an interface default), then its own
    /// members answer every root they override. A member overriding two
    /// roots answers both; an abstract member removes what it overrides.
    fn computeDispatch(b: *Build) Error!void {
        const nf = b.origins.items.len;
        const old_slots: []const MethodSlotId = if (b.over) |o| o.old.slot_of else &.{};
        b.br.slot_of = try b.grown(MethodSlotId, old_slots, nf, MethodSlotId.from(NONE));
        // Every member's slot: its first root.
        var i: u32 = b.firstSym();
        while (i < b.n) : (i += 1) {
            if (!b.member.isSet(i)) continue;
            const m = Sym.from(i);
            switch (b.s.syms.kind(m)) {
                .function => {
                    const f = b.br.funcOfOpt(m) orelse continue;
                    if (b.s.syms.flags(m).static) continue;
                    const roots = try b.fnRoots(m);
                    if (roots.len != 0) b.br.slot_of[f.int()] = MethodSlotId.fromFunc(b.br.funcOf(roots[0]));
                },
                .property => {
                    if (b.s.syms.flags(m).static) continue;
                    const g = b.br.getter_of[i];
                    if (g.int() == NONE) continue;
                    const roots = try b.propRoots(m);
                    if (roots.len != 0) b.br.slot_of[g.int()] = MethodSlotId.fromFunc(b.br.getterOf(roots[0]));
                    if (b.br.setterOf(m)) |st| {
                        const sroots = try b.setterRoots(m);
                        if (sroots.len != 0) b.br.slot_of[st.int()] = MethodSlotId.fromFunc(b.br.setterOf(sroots[0]).?);
                    }
                },
                else => {},
            }
        }
        var it = b.br.sam_funcs_of.iterator();
        while (it.next()) |e| {
            const sf = e.value_ptr.*;
            if (sf.method.int() < b.baseFuncCount()) continue;
            if (try b.samAbstract(e.key_ptr.*)) |am| {
                const roots = try b.fnRoots(am);
                if (roots.len != 0) b.br.slot_of[sf.method.int()] = MethodSlotId.fromFunc(b.br.funcOf(roots[0]));
            }
            if (b.anyMember(sema.wk.equals)) |f| b.br.slot_of[sf.equals.int()] = MethodSlotId.fromFunc(f);
            if (b.anyMember(sema.wk.hashCode)) |f| b.br.slot_of[sf.hash_code.int()] = MethodSlotId.fromFunc(f);
        }
        const nc = b.class_origins.items.len;
        try b.dispatch.appendNTimes(b.a, null, nc);
        if (b.over != null) try b.baseDispatch();
        var c: u32 = b.baseClassCount();
        while (c < nc) : (c += 1) _ = try b.dispatchOf(ClassId.from(c), 0);
        const md = &b.br.m.method_dispatch;
        c = b.baseClassCount();
        while (c < nc) : (c += 1) {
            for (b.dispatch.items[c].?) |e| try md.put((@as(u64, c) << 32) | e.slot, e.func);
        }
    }

    fn dispatchOf(b: *Build, c: ClassId, depth: u32) Error![]const DispatchEntry {
        if (b.dispatch.items[c.int()]) |d| return d;
        const s = b.s;
        var map: std.AutoArrayHashMapUnmanaged(u32, FuncId) = .empty;
        if (depth < 64) {
            for (try b.supersOf(c)) |sup| {
                for (try b.dispatchOf(sup, depth + 1)) |e| {
                    const gop = try map.getOrPut(b.a, e.slot);
                    if (!gop.found_existing or try b.inheritedWins(e.func, gop.value_ptr.*)) gop.value_ptr.* = e.func;
                }
            }
        }
        switch (b.class_origins.items[c.int()]) {
            .sam => |iface| {
                const sf = b.br.sam_funcs_of.get(iface).?;
                if (try b.samAbstract(iface)) |am| {
                    for (try b.fnRoots(am)) |r| try map.put(b.a, b.br.funcOf(r).int(), sf.method);
                }
                if (b.anyMember(sema.wk.equals)) |f| try map.put(b.a, f.int(), sf.equals);
                if (b.anyMember(sema.wk.hashCode)) |f| try map.put(b.a, f.int(), sf.hash_code);
            },
            .decl => for (b.class_members.items[c.int()].items) |m| {
                const fl = s.syms.flags(m);
                if (fl.static or fl.visibility == .private) continue;
                const abstract = isAbstract(s, m);
                switch (s.syms.kind(m)) {
                    .function => {
                        const f = b.br.funcOfOpt(m) orelse continue;
                        for (try b.fnRoots(m)) |r| {
                            const slot = b.br.funcOf(r).int();
                            if (abstract) _ = map.swapRemove(slot) else try map.put(b.a, slot, f);
                        }
                    },
                    .property => {
                        const g = b.br.getter_of[m.int()];
                        for (try b.propRoots(m)) |r| {
                            const slot = b.br.getterOf(r).int();
                            if (abstract) _ = map.swapRemove(slot) else try map.put(b.a, slot, g);
                        }
                        if (b.br.setterOf(m)) |st| for (try b.setterRoots(m)) |r| {
                            const slot = b.br.setterOf(r).?.int();
                            if (abstract) _ = map.swapRemove(slot) else try map.put(b.a, slot, st);
                        };
                    },
                    else => {},
                }
            },
        }
        switch (b.class_origins.items[c.int()]) {
            .decl => |cls| if (s.syms.classInfo(cls).kind != .interface) try b.inheritedImplementations(cls, &map),
            .sam => {},
        }
        const out = try b.a.alloc(DispatchEntry, map.count());
        for (map.keys(), map.values(), out) |k, v, *o| o.* = .{ .slot = k, .func = v };
        std.mem.sort(DispatchEntry, out, {}, struct {
            fn lt(_: void, x: DispatchEntry, y: DispatchEntry) bool {
                return x.slot < y.slot;
            }
        }.lt);
        b.dispatch.items[c.int()] = out;
        return out;
    }

    /// A data or value class's primary-constructor properties, in parameter
    /// order.
    fn primaryProperties(b: *Build, cls: Sym) Error![]const PrimaryProperty {
        const s = b.s;
        const fl = s.syms.flags(cls);
        const ctor = s.syms.classInfo(cls).primary_ctor;
        if (!(fl.data or fl.value) or ctor == .none) return &.{};
        var out: std.ArrayList(PrimaryProperty) = .empty;
        for (s.syms.functionInfo(ctor).params) |p| {
            const name = s.syms.name(p);
            for (sema.scope.membersOf(s, cls, name)) |m| {
                if (s.syms.kind(m) != .property or !s.syms.propertyInfo(m).from_ctor) continue;
                try out.append(b.a, .{ .name = s.str(name), .mutable = s.syms.flags(m).mutable });
                break;
            }
        }
        return out.items;
    }

    /// Whether implementation `new`, which a later supertype passes down,
    /// replaces `old` for one slot. A class's member wins over an
    /// interface's default; between two defaults, the one overriding the
    /// other wins, as the most specific implementation does in Kotlin
    /// (`class B : A(), J` takes `J.f` over the `I.f` `A` inherits).
    fn inheritedWins(b: *Build, new: FuncId, old: FuncId) Error!bool {
        if (new == old) return false;
        const s = b.s;
        const ns = b.implSym(new) orelse return true;
        const os = b.implSym(old) orelse return true;
        const n_iface = b.inInterface(ns);
        const o_iface = b.inInterface(os);
        if (!n_iface) return true;
        if (!o_iface) return false;
        if (try sema.members.overridesTransitively(s, os, ns)) return false;
        return true;
    }

    /// The function or property implementation `f` is the body of.
    fn implSym(b: *const Build, f: FuncId) ?Sym {
        if (f.int() >= b.origins.items.len) return null;
        return switch (b.origins.items[f.int()]) {
            .decl => |d| d,
            .getter, .setter => |p| p,
            else => null,
        };
    }

    fn inInterface(b: *const Build, m: Sym) bool {
        const s = b.s;
        const owner = s.syms.owner(m);
        return owner != .none and s.syms.kind(owner) == .class and s.syms.classInfo(owner).kind == .interface;
    }

    /// A class inherits from its superclass a member with the signature of
    /// an abstract member of one of its interfaces that the superclass's
    /// member does not override (`class Impl : Base(), Named`): the
    /// inherited member answers the interface member's roots, as kotlinc's
    /// fake override does.
    fn inheritedImplementations(b: *Build, cls: Sym, map: *std.AutoArrayHashMapUnmanaged(u32, FuncId)) Error!void {
        const s = b.s;
        const self_t = try sema.headers.selfType(s, cls);
        var ifaces: std.ArrayList(Sym) = .empty;
        try b.interfacesOf(cls, &ifaces, 0);
        for (ifaces.items) |iface| {
            const view = (try sema.subtyping.supertypeWithClass(s, self_t, iface)) orelse continue;
            const iface_subst = try s.arena.create(sema.types.Subst);
            iface_subst.* = try sema.subtyping.classSubst(s, view);
            var it = s.syms.classInfo(iface).members.iterator();
            while (it.next()) |e| for (e.value_ptr.items) |m| {
                if (s.syms.owner(m) != iface or !isAbstract(s, m)) continue;
                switch (s.syms.kind(m)) {
                    .function => {
                        const roots = try b.fnRoots(m);
                        if (b.answered(map, roots, .function)) continue;
                        const impl = (try b.classImplementation(self_t, m, iface_subst)) orelse continue;
                        const f = b.br.funcOfOpt(impl) orelse continue;
                        for (roots) |r| try map.put(b.a, b.br.funcOf(r).int(), f);
                    },
                    .property => {
                        const roots = try b.propRoots(m);
                        if (b.answered(map, roots, .property)) continue;
                        const impl = (try b.classImplementation(self_t, m, iface_subst)) orelse continue;
                        const g = b.br.getter_of[impl.int()];
                        if (g.int() == NONE) continue;
                        for (roots) |r| try map.put(b.a, b.br.getterOf(r).int(), g);
                        if (b.br.setterOf(m) != null) {
                            if (b.br.setterOf(impl)) |st| for (try b.setterRoots(m)) |r| try map.put(b.a, b.br.setterOf(r).?.int(), st);
                        }
                    },
                    else => {},
                }
            };
        }
    }

    fn answered(b: *Build, map: *const std.AutoArrayHashMapUnmanaged(u32, FuncId), roots: []const Sym, kind: RootKind) bool {
        for (roots) |r| {
            const f = switch (kind) {
                .function => b.br.funcOf(r),
                else => b.br.getterOf(r),
            };
            if (map.contains(f.int())) return true;
        }
        return false;
    }

    /// Every interface among `cls`'s supertypes, transitively.
    fn interfacesOf(b: *Build, cls: Sym, out: *std.ArrayList(Sym), depth: u32) Error!void {
        const s = b.s;
        if (depth > 64) return;
        for (s.syms.classInfo(cls).supertypes) |st| {
            const sc = s.types.classSym(st);
            if (sc == .none or s.syms.kind(sc) != .class) continue;
            if (s.syms.classInfo(sc).kind == .interface and std.mem.indexOfScalar(Sym, out.items, sc) == null) try out.append(b.a, sc);
            try b.interfacesOf(sc, out, depth + 1);
        }
    }

    /// The nearest member of a class (not an interface) a value of type
    /// `self_t` has that is not abstract and has the signature of interface
    /// member `m`. The superclass chain is walked itself: a member lookup
    /// lets the interface's declaration, nearer than a grandparent class,
    /// hide the member that implements it. A member whose parameter types
    /// equal `m`'s once both are seen through the class's supertype
    /// arguments wins over one that only erases alike: in
    /// `class B : A<A<String>>(), C<A<String>>`, `C.foo(x: A<E>)` is
    /// `A.foo(x: A<T>)`, not the `A.foo(x: T)` that also takes an `A`.
    fn classImplementation(b: *Build, self_t: TypeId, m: Sym, m_subst: *const sema.types.Subst) Error!?Sym {
        if (b.s.syms.kind(m) == .function) {
            if (try b.classImplementationBy(self_t, m, m_subst, true)) |f| return f;
        }
        return b.classImplementationBy(self_t, m, m_subst, false);
    }

    fn classImplementationBy(b: *Build, self_t: TypeId, m: Sym, m_subst: *const sema.types.Subst, exact: bool) Error!?Sym {
        const s = b.s;
        var t = self_t;
        var depth: u32 = 0;
        while (depth < 64) : (depth += 1) {
            const cls = s.types.classSym(t);
            if (cls == .none or s.syms.kind(cls) != .class or s.syms.classInfo(cls).kind == .interface) return null;
            const subst = try s.arena.create(sema.types.Subst);
            subst.* = try sema.subtyping.classSubst(s, t);
            for (sema.scope.membersOf(s, cls, s.syms.name(m))) |cand| {
                if (s.syms.kind(cand) != s.syms.kind(m) or isAbstract(s, cand) or !sema.scope.visible(s, cand)) continue;
                const fl = s.syms.flags(cand);
                if (fl.static or (depth != 0 and fl.visibility == .private)) continue;
                if (s.syms.kind(m) == .function) {
                    if (!try sema.members.sameSignature(s, cand, subst, m, m_subst)) continue;
                    // `subst` is `cls`'s own view, so a member it inherits
                    // is compared exactly at its declaring class.
                    if (exact and (s.syms.owner(cand) != cls or !try sameParamTypes(s, cand, subst, m, m_subst))) continue;
                }
                return cand;
            }
            t = for (try sema.headers.supertypes(s, cls)) |st| {
                const sc = s.types.classSym(st);
                if (sc != .none and s.syms.kind(sc) == .class and s.syms.classInfo(sc).kind != .interface) break try s.types.substitute(st, subst);
            } else return null;
        }
        return null;
    }

    /// The declarations `m`'s override chain starts from, in the order the
    /// links name them; `m` itself when it overrides nothing with an id.
    fn fnRoots(b: *Build, m: Sym) Error![]const Sym {
        var out: std.ArrayList(Sym) = .empty;
        try b.collectRoots(m, &out, 0, .function);
        if (out.items.len == 0) try out.append(b.a, m);
        return out.items;
    }

    fn propRoots(b: *Build, p: Sym) Error![]const Sym {
        var out: std.ArrayList(Sym) = .empty;
        try b.collectRoots(p, &out, 0, .property);
        if (out.items.len == 0) try out.append(b.a, p);
        return out.items;
    }

    const RootKind = enum { function, property, setter };

    fn collectRoots(b: *Build, m: Sym, out: *std.ArrayList(Sym), depth: u32, kind: RootKind) Error!void {
        const s = b.s;
        var any = false;
        if (depth < 64) {
            for (try sema.members.overridden(s, m)) |q| {
                if (q.int() >= b.n) continue;
                const has = switch (kind) {
                    .function => b.br.func_of[q.int()].int() != NONE,
                    .property => b.br.getter_of[q.int()].int() != NONE,
                    .setter => b.br.setter_of[q.int()].int() != NONE,
                };
                if (!has) continue;
                any = true;
                try b.collectRoots(q, out, depth + 1, kind);
            }
        }
        if (!any and std.mem.indexOfScalar(Sym, out.items, m) == null) try out.append(b.a, m);
    }

    /// The roots of a `var`'s setter: the topmost mutable properties it
    /// overrides; itself when it overrides only `val`s.
    fn setterRoots(b: *Build, p: Sym) Error![]const Sym {
        var out: std.ArrayList(Sym) = .empty;
        try b.collectRoots(p, &out, 0, .setter);
        if (out.items.len == 0) try out.append(b.a, p);
        return out.items;
    }

    /// The abstract function a fun interface's SAM class implements,
    /// declared on it or inherited (`fun interface I : Base`).
    fn samAbstract(b: *Build, iface: Sym) Error!?Sym {
        return b.samAbstractIn(iface, 0);
    }

    fn samAbstractIn(b: *Build, iface: Sym, depth: u32) Error!?Sym {
        const s = b.s;
        var best: ?Sym = null;
        var it = s.syms.classInfo(iface).members.iterator();
        while (it.next()) |e| for (e.value_ptr.items) |m| {
            if (s.syms.kind(m) != .function or s.syms.owner(m) != iface) continue;
            if (!isAbstract(s, m)) continue;
            if (best == null or m.int() < best.?.int()) best = m;
        };
        if (best != null or depth > 16) return best;
        for (try sema.headers.supertypes(s, iface)) |st| {
            const sc = s.types.classSym(st);
            if (sc == .none or s.syms.classInfo(sc).kind != .interface) continue;
            if (try b.samAbstractIn(sc, depth + 1)) |am| return am;
        }
        return null;
    }

    // ---------------------------------------------------- ancestors ----

    fn computeAncestors(b: *Build) Error!void {
        const nc = b.class_origins.items.len;
        const anc = &b.br.m.class_ancestors;
        const nb = b.baseClassCount();
        anc.shrinkRetainingCapacity(@min(anc.items.len, nb));
        try anc.appendNTimes(b.a, &.{}, nc - anc.items.len);
        var c: u32 = nb;
        while (c < nc) : (c += 1) {
            var seen: std.ArrayList(ClassId) = .empty;
            try b.closure(ClassId.from(c), &seen, 0);
            std.mem.sort(ClassId, seen.items, {}, struct {
                fn lt(_: void, x: ClassId, y: ClassId) bool {
                    return x.int() < y.int();
                }
            }.lt);
            anc.items[c] = seen.items;
        }
    }

    fn closure(b: *Build, c: ClassId, seen: *std.ArrayList(ClassId), depth: u32) Error!void {
        if (std.mem.indexOfScalar(ClassId, seen.items, c) != null) return;
        // A loaded base class's closure is in the module already.
        if (c.int() < b.baseClassCount()) {
            for (b.br.m.class_ancestors.items[c.int()]) |x| {
                if (std.mem.indexOfScalar(ClassId, seen.items, x) == null) try seen.append(b.a, x);
            }
            return;
        }
        try seen.append(b.a, c);
        if (depth > 64) return;
        for (try b.supersOf(c)) |sup| try b.closure(sup, seen, depth + 1);
    }

    // ----------------------------------------------- module skeleton ----

    fn buildFuncs(b: *Build) Error!void {
        const s = b.s;
        const nf = b.origins.items.len;
        const old_caps: []const []const CaptureKey = if (b.over) |o| o.old.captures_of else &.{};
        const caps = try b.grown([]const CaptureKey, old_caps, nf, &.{});
        try b.br.m.funcs.ensureTotalCapacity(b.a, nf);
        const first = b.baseFuncCount();
        for (b.origins.items[first..], first..) |origin, idx| {
            const id = FuncId.from(@intCast(idx));
            switch (origin) {
                .lambda => |f| caps[idx] = b.scopeCaptures(f),
                .defaults => |d| if (b.isNested(d)) {
                    caps[idx] = b.scopeCaptures(d);
                },
                .adapter => |ai| {
                    const t = b.adapters.items[ai].target;
                    const scope_sym = if (s.syms.kind(t) == .constructor) s.syms.owner(t) else t;
                    caps[idx] = b.scopeCaptures(scope_sym);
                },
                else => {},
            }
            var params: std.ArrayList(ir.Param) = .empty;
            try b.paramsOf(origin, caps[idx], &params);
            const f: ir.Func = .{
                .id = id,
                .name = try b.funcName(origin),
                .fqn = try b.funcFqn(origin),
                .params = params.items,
                .return_ty = .{ .name = "", .nullable = true, .args = &.{} },
                .n_locals = 0,
                .blocks = &.{},
                .entry = ir.BlockId.from(0),
                .is_suspend = b.isSuspend(origin),
            };
            b.br.m.funcs.appendAssumeCapacity(f);
        }
        b.br.captures_of = caps;
        b.br.origin = b.origins.items;
        b.br.adapters = b.adapters.items;
        b.br.units = b.units.items;
    }

    fn pushParam(b: *Build, out: *std.ArrayList(ir.Param), name: []const u8, is_vararg: bool) Error!void {
        try out.append(b.a, .{ .name = name, .ty = .{ .name = "", .nullable = true, .args = &.{} }, .default = null, .is_vararg = is_vararg });
    }

    /// The parameters a body of `origin` receives, in the calling
    /// convention's order.
    fn paramsOf(b: *Build, origin: FuncOrigin, caps: []const CaptureKey, out: *std.ArrayList(ir.Param)) Error!void {
        const s = b.s;
        switch (origin) {
            .decl, .abstract => |d| switch (s.syms.kind(d)) {
                .property => try b.accessorParams(d, false, out),
                else => {
                    try b.declParams(d, isInstanceMember(s, d), out);
                    try b.primitiveParams(d, out.items);
                },
            },
            .getter => |p| try b.accessorParams(p, false, out),
            .setter => |p| try b.accessorParams(p, true, out),
            .defaults => |d| {
                const nested = b.isNested(d);
                if (nested) for (caps) |_| try b.pushParam(out, "$cap", false);
                try b.declParams(d, !nested and isInstanceMember(s, d), out);
                const nv = s.syms.functionInfo(d).params.len;
                var masks = (nv + 31) / 32;
                if (masks == 0) masks = 1;
                while (masks > 0) : (masks -= 1) try b.pushParam(out, "$mask", false);
            },
            .init_unit => {},
            .lambda => |f| {
                if (b.lambda_rec.get(f)) |rec| {
                    const pair = composableType(s, rec.fn_type);
                    const ints: usize = if (pair) lambdaChangedInts(fnArity(s, rec.fn_type)) else 0;
                    const arity = fnArity(s, rec.fn_type) + @as(usize, if (pair) 1 + ints else 0);
                    var names: std.ArrayList([]const u8) = .empty;
                    for (rec.contexts) |c| try names.append(b.a, s.str(s.syms.name(c)));
                    if (rec.has_receiver) try names.append(b.a, "$receiver");
                    if (rec.it != .none) {
                        try names.append(b.a, "it");
                    } else {
                        for (rec.params) |p| try names.append(b.a, if (p == .none) "_" else s.str(s.syms.name(p)));
                    }
                    if (pair) {
                        try names.append(b.a, composer_param);
                        var k: usize = 0;
                        while (k < ints) : (k += 1) try names.append(b.a, try changedName(b.a, k));
                    }
                    var i: usize = 0;
                    while (i < arity) : (i += 1) try b.pushParam(out, if (i < names.items.len) names.items[i] else "_", false);
                } else {
                    for (caps) |_| try b.pushParam(out, "$cap", false);
                    try b.declParams(f, false, out);
                }
            },
            .sam_ctor => {
                try b.pushParam(out, "this", false);
                try b.pushParam(out, "function", false);
            },
            .sam_method => |iface| {
                if (try b.samAbstract(iface)) |am| try b.declParams(am, true, out) else try b.pushParam(out, "this", false);
            },
            .sam_equals => {
                try b.pushParam(out, "this", false);
                try b.pushParam(out, "other", false);
            },
            .sam_hash_code => try b.pushParam(out, "this", false),
            .adapter => |ai| {
                const arity = fnArity(s, b.adapters.items[ai].ty);
                var i: usize = 0;
                while (i < arity) : (i += 1) try b.pushParam(out, "p", false);
            },
            .restart => {
                try b.pushParam(out, "$rc", false);
                try b.pushParam(out, "$rf", false);
            },
        }
    }

    /// Names the type of each of `d`'s value parameters, and of its extension
    /// receiver, declared a non-null primitive, the last of `params` being its
    /// value parameters as `declParams` pushed them (after the receiver). A
    /// body's argument there always holds that type (`kinds.zig`).
    fn primitiveParams(b: *Build, d: Sym, params: []ir.Param) Error!void {
        const s = b.s;
        const info = s.syms.functionInfo(d);
        if (composableFunction(s, d) or info.type_params.len != 0) return;
        const n = info.params.len;
        const has_recv = info.receiver != .none;
        const first = params.len -| (n + @intFromBool(has_recv));
        if (params.len < n + @intFromBool(has_recv)) return;
        if (has_recv) params[first].ty = primitiveType(seedOfType(s, info.receiver));
        for (info.params, params[first + @intFromBool(has_recv) ..][0..n]) |p, *out| {
            if (s.syms.flags(p).vararg) continue;
            out.ty = primitiveType(seedOfType(s, try sema.headers.paramType(s, p)));
        }
    }

    /// A function's or constructor's parameters; `instance`: a leading `this`.
    fn declParams(b: *Build, d: Sym, instance: bool, out: *std.ArrayList(ir.Param)) Error!void {
        const s = b.s;
        const info = s.syms.functionInfo(d);
        if (s.syms.kind(d) == .constructor) {
            const cls = s.syms.owner(d);
            try b.pushParam(out, "this", false);
            const owner = s.syms.owner(cls);
            if (s.syms.flags(cls).inner and owner != .none and s.syms.kind(owner) == .class) try b.pushParam(out, "$outer", false);
            const ck = s.syms.classInfo(cls).kind;
            if (ck == .enum_class or ck == .enum_entry) {
                try b.pushParam(out, "name", false);
                try b.pushParam(out, "ordinal", false);
            }
            if (b.br.classOfOpt(cls)) |c| {
                for (b.br.class_captures[c.int()]) |k| try b.pushParam(out, try b.captureName(k), false);
            }
        } else if (instance) {
            try b.pushParam(out, "this", false);
        }
        for (info.context_params) |cp| try b.pushParam(out, s.str(s.syms.name(cp)), false);
        if (info.receiver != .none) try b.pushParam(out, "$receiver", false);
        for (info.params) |p| try b.pushParam(out, s.str(s.syms.name(p)), s.syms.flags(p).vararg);
        if (composableFunction(s, d)) {
            try b.pushParam(out, composer_param, false);
            try b.pushChanged(out, declChangedInts(s, d, instance));
            if (composableDefaults(s, d)) {
                var k: usize = 0;
                while (k < defaultInts(info.params.len)) : (k += 1) {
                    try b.pushParam(out, if (k == 0) default_param else try std.fmt.allocPrint(b.a, "{s}{d}", .{ default_param, k }), false);
                }
            }
        }
        for (info.type_params) |tp| {
            if (s.syms.flags(tp).reified) try b.pushParam(out, try std.fmt.allocPrint(b.a, "$reified${s}", .{s.str(s.syms.name(tp))}), false);
        }
    }

    fn accessorParams(b: *Build, p: Sym, setter: bool, out: *std.ArrayList(ir.Param)) Error!void {
        const s = b.s;
        const info = s.syms.propertyInfo(p);
        if (isInstanceMember(s, p)) try b.pushParam(out, "this", false);
        for (info.context_params) |cp| try b.pushParam(out, s.str(s.syms.name(cp)), false);
        if (info.receiver != .none) try b.pushParam(out, "$receiver", false);
        if (setter) try b.pushParam(out, "value", false);
        if (!setter and composableGetter(s, p)) {
            try b.pushParam(out, composer_param, false);
            try b.pushChanged(out, getterChangedInts(s, p));
        }
    }

    fn pushChanged(b: *Build, out: *std.ArrayList(ir.Param), n: u16) Error!void {
        var k: usize = 0;
        while (k < n) : (k += 1) try b.pushParam(out, try changedName(b.a, k), false);
    }

    fn isSuspend(b: *Build, origin: FuncOrigin) bool {
        const s = b.s;
        return switch (origin) {
            .decl, .abstract, .defaults => |d| s.syms.kind(d) != .property and s.syms.flags(d).suspend_,
            .lambda => |f| if (b.lambda_rec.get(f)) |rec| rec.suspend_ else s.syms.flags(f).suspend_,
            .sam_method => |iface| blk: {
                const am = (b.samAbstract(iface) catch null) orelse break :blk false;
                break :blk s.syms.flags(am).suspend_;
            },
            .adapter => |ai| s.syms.flags(b.adapters.items[ai].target).suspend_ or isSuspendFunctionType(s, b.adapters.items[ai].ty),
            else => false,
        };
    }

    fn funcName(b: *Build, origin: FuncOrigin) Error![]const u8 {
        const s = b.s;
        return switch (origin) {
            .decl, .abstract, .lambda => |d| s.str(s.syms.name(d)),
            .getter => |p| std.fmt.allocPrint(b.a, "<get-{s}>", .{s.str(s.syms.name(p))}),
            .setter => |p| std.fmt.allocPrint(b.a, "<set-{s}>", .{s.str(s.syms.name(p))}),
            .defaults => |d| std.fmt.allocPrint(b.a, "{s}$default", .{s.str(s.syms.name(d))}),
            .init_unit => |u| switch (b.units.items[u]) {
                .file, .eager_file => "<init>",
                .enum_class => "<init-entries>",
            },
            .sam_ctor => "<init>",
            .sam_method => |iface| if (try b.samAbstract(iface)) |am| s.str(s.syms.name(am)) else "invoke",
            .sam_equals => "equals",
            .sam_hash_code => "hashCode",
            .adapter => "<reference>",
            .restart => "<restart>",
        };
    }

    fn funcFqn(b: *Build, origin: FuncOrigin) Error![]const u8 {
        const s = b.s;
        return switch (origin) {
            .decl, .abstract, .lambda => |d| b.qualName(d),
            .getter => |p| std.fmt.allocPrint(b.a, "{s}.<get>", .{try b.qualName(p)}),
            .setter => |p| std.fmt.allocPrint(b.a, "{s}.<set>", .{try b.qualName(p)}),
            .defaults => |d| std.fmt.allocPrint(b.a, "{s}$default", .{try b.qualName(d)}),
            .init_unit => |u| switch (b.units.items[u]) {
                .file, .eager_file => |f| std.fmt.allocPrint(b.a, "{s}.<init>", .{try kotlinFileName(s, b.a, f)}),
                .enum_class => |e| std.fmt.allocPrint(b.a, "{s}.<init-entries>", .{try b.qualName(e)}),
            },
            .sam_ctor => |iface| std.fmt.allocPrint(b.a, "{s}$sam.<init>", .{try b.qualName(iface)}),
            .sam_method, .sam_equals, .sam_hash_code => |iface| std.fmt.allocPrint(b.a, "{s}$sam.{s}", .{ try b.qualName(iface), try b.funcName(origin) }),
            .adapter => |ai| std.fmt.allocPrint(b.a, "{s}$ref", .{try b.qualName(b.adapters.items[ai].target)}),
            .restart => |f| std.fmt.allocPrint(b.a, "{s}$restart", .{try b.qualName(f)}),
        };
    }

    fn buildClasses(b: *Build) Error!void {
        const s = b.s;
        const nc = b.class_origins.items.len;
        try b.br.m.classes.ensureTotalCapacity(b.a, nc);
        const first = b.baseClassCount();
        for (b.class_origins.items[first..], first..) |origin, idx| {
            const id = ClassId.from(@intCast(idx));
            const supers = try b.supersOf(id);
            var cls: ir.Class = .{
                .id = id,
                .name = "",
                .fqn = "",
                .primary_params = &.{},
                .methods = &.{},
                .init_block = null,
                .companion = null,
                .supertypes = @constCast(supers),
            };
            switch (origin) {
                .decl => |c| {
                    const info = s.syms.classInfo(c);
                    const fl = s.syms.flags(c);
                    cls.name = s.str(s.syms.name(c));
                    cls.fqn = s.str(info.fqn);
                    if (info.companion != .none) cls.companion = b.br.classOfOpt(info.companion);
                    cls.is_interface = info.kind == .interface;
                    cls.is_abstract = fl.modality == .abstract or fl.modality == .sealed or info.kind == .interface;
                    cls.is_open = fl.modality == .open;
                    cls.is_enum = info.kind == .enum_class;
                    cls.is_object = info.kind == .object or info.kind == .companion;
                    cls.is_inner = fl.inner;
                    cls.is_value = fl.value;
                    cls.is_fun_interface = fl.fun_iface;
                    cls.is_annotation = info.kind == .annotation;
                },
                .sam => |iface| {
                    cls.name = try std.fmt.allocPrint(b.a, "{s}$sam", .{s.str(s.syms.name(iface))});
                    cls.fqn = try std.fmt.allocPrint(b.a, "{s}$sam", .{s.str(s.syms.classInfo(iface).fqn)});
                },
            }
            b.br.m.classes.appendAssumeCapacity(cls);
        }
        b.br.class_origin = b.class_origins.items;
    }

    fn buildResolved(b: *Build) Error!void {
        const s = b.s;
        const a = b.a;
        // A loaded base's tables grow in place: its entries are kept.
        const r = b.br.m.resolved orelse blk: {
            const nr = try a.create(ir.Resolved);
            nr.* = .{};
            break :blk nr;
        };
        const base: ir.Resolved = if (b.over) |o| o.rt else .{};
        const nc = b.class_origins.items.len;
        const nf = b.origins.items.len;
        const first_class = b.baseClassCount();
        r.classes = try a.alloc(resolved.ClassRt, nc);
        @memcpy(r.classes[0..first_class], base.classes[0..first_class]);
        const throwable = b.br.classOfOpt(s.classByFqn("kotlin.Throwable"));
        for (r.classes[first_class..], first_class..) |*rt, idx| {
            const layout = b.br.layout[idx];
            const seeds = try a.alloc(SlotSeed, layout.len);
            for (layout, seeds) |sl, *sd| sd.* = sl.seed;
            var object_ctor: u32 = ir.NO_FUNC;
            var init_name: []const u8 = "";
            var flags: ClassDefFlags = .{};
            switch (b.class_origins.items[idx]) {
                .decl => |c| {
                    const info = s.syms.classInfo(c);
                    if ((info.kind == .object or info.kind == .companion) and info.primary_ctor != .none) {
                        if (b.br.funcOfOpt(info.primary_ctor)) |f| object_ctor = f.int();
                    }
                    if (info.kind == .object or info.kind == .companion) init_name = try std.fmt.allocPrint(b.a, "object {s}", .{try kotlinName(s, b.a, c)});
                    flags.is_data = s.syms.flags(c).data;
                    flags.is_sealed = s.syms.flags(c).modality == .sealed;
                    flags.is_anonymous = info.kind == .anonymous;
                    flags.primary = try b.primaryProperties(c);
                },
                .sam => flags.is_anonymous = true,
            }
            const def = try classDefOf(a, b.br.m, idx, layout, flags);
            rt.* = .{ .def = def, .seeds = seeds, .object_ctor = object_ctor, .init_name = init_name, .host_slot = b.host_slots.items[idx], .throwable = throwable != null and
                std.mem.indexOfScalar(ClassId, b.br.m.class_ancestors.items[idx], throwable.?) != null };
        }
        r.statics = b.statics.items;
        r.frame_namer = .{ .ctx = b.br, .name = frameName };
        const units = try a.alloc(resolved.InitUnitRt, b.unit_funcs.items.len);
        for (units, b.unit_funcs.items, 0..) |*u, f, i| {
            const name = if (i < base.init_units.len) base.init_units[i].name else try b.unitName(@intCast(i));
            u.* = .{ .func = f, .name = name };
        }
        r.init_units = units;
        var eager: std.ArrayList(u32) = .empty;
        for (b.units.items, 0..) |u, i| if (u == .eager_file) try eager.append(a, @intCast(i));
        r.eager_units = eager.items;
        // Appends natives, so ahead of taking them.
        r.host_slot = try b.hostSlots(base.host_slot, nf);
        r.natives = b.natives.items;
        try b.denseDispatch(r, base);
        const fnat = try b.grown(NativeId, base.func_native, nf, .none);
        var it = b.func_native.iterator();
        while (it.next()) |e| {
            fnat[e.key_ptr.*] = e.value_ptr.*;
            // An instance member's native names its slot (`NativeRt.slot`).
            const n = &b.natives.items[e.value_ptr.int()];
            const f = e.key_ptr.*;
            if (n.receiver and f < b.br.slot_of.len and b.br.slot_of[f].int() != NONE) n.slot = b.br.slot_of[f].int();
        }
        r.func_native = fnat;
        const ftry = try b.grown(NativeId, base.func_try, nf, .none);
        var tit = b.func_try.iterator();
        while (tit.next()) |e| ftry[e.key_ptr.*] = e.value_ptr.*;
        r.func_try = ftry;
        r.facade_unit = try b.facadeUnits(base.facade_unit, nf, b.baseFuncCount());
        r.well_known = try b.wellKnown();
        for (std.enums.values(runtime.WellKnownObject)) |o| {
            r.well_known_objects.set(o, b.br.classOfOpt(s.classByFqn(o.fqn())));
        }
        for (std.enums.values(runtime.WellKnownClass)) |c| r.well_known_classes.set(c, b.primaryOf(c.fqn()));
        for (std.enums.values(runtime.WellKnownStatic)) |w| r.well_known_statics.set(w, b.wellKnownStatic(w));
        r.host_class = try b.hostClasses();
        r.exceptions = try b.exceptions(base.exceptions);
        r.base = b.baseClasses();
        r.serializers = try b.serializers(base.serializers);
        b.br.m.resolved = r;
    }

    /// The static of the top-level property `w` names, declared in its file.
    fn wellKnownStatic(b: *const Build, w: runtime.WellKnownStatic) ?StaticId {
        const s = b.s;
        const d = w.declaration();
        const pn = s.names.lookup(d.package) orelse return null;
        const pkg = s.syms.package_by_fqn.get(pn) orelse return null;
        const n = s.names.lookup(d.name) orelse return null;
        for (sema.scope.membersOf(s, pkg, n)) |p| {
            if (s.syms.kind(p) != .property) continue;
            const f = s.syms.get(p).file;
            if (f >= s.files.items.len or !std.mem.endsWith(u8, s.files.items[f].path, d.file)) continue;
            return b.br.staticOf(p);
        }
        return null;
    }

    /// Each new class's vtable and interface tables, from its dispatch
    /// entries. A slot a class declares sits after its superclass's slots,
    /// so every subclass has it at the same index; a slot an interface
    /// declares sits at its place among that interface's, in the table each
    /// class implementing it keeps.
    fn denseDispatch(b: *Build, r: *ir.Resolved, base: ir.Resolved) Error!void {
        const nf = b.origins.items.len;
        const nc = b.class_origins.items.len;
        const first_class = b.baseClassCount();
        const index = try b.grown(u32, base.slot_index, nf, NONE);
        const iface = try b.grown(u32, base.slot_iface, nf, NONE);
        const vlen = try b.a.alloc(u32, nc);
        @memset(vlen, NONE);
        for (r.classes[0..first_class], 0..) |rt, c| vlen[c] = @intCast(rt.vtable.len);
        for (first_class..nc) |c| _ = try b.slotsOf(ClassId.from(@intCast(c)), vlen, index, iface, 0);
        for (r.classes[first_class..], first_class..) |*rt, c| {
            const entries = b.dispatch.items[c] orelse &.{};
            const vt = try b.a.alloc(resolved.VSlot, vlen[c]);
            @memset(vt, .{});
            var sizes: std.AutoArrayHashMapUnmanaged(u32, u32) = .empty;
            for (entries) |e| {
                if (e.slot >= nf or index[e.slot] == NONE or iface[e.slot] == NONE) continue;
                const gop = try sizes.getOrPut(b.a, iface[e.slot]);
                const want = index[e.slot] + 1;
                if (!gop.found_existing or gop.value_ptr.* < want) gop.value_ptr.* = want;
            }
            const tables = try b.a.alloc(resolved.ITable, sizes.count());
            const cells = try b.a.alloc([]u32, sizes.count());
            for (sizes.keys(), sizes.values(), tables, cells) |k, n, *t, *cell| {
                cell.* = try b.a.alloc(u32, n);
                @memset(cell.*, ir.NO_FUNC);
                t.* = .{ .iface = ClassId.from(k), .entries = cell.* };
            }
            for (entries) |e| {
                if (e.slot >= nf) continue;
                const idx = index[e.slot];
                if (idx == NONE) continue;
                if (iface[e.slot] == NONE) {
                    if (idx < vt.len) vt[idx] = .{ .root = e.slot, .func = e.func.int() };
                } else {
                    cells[sizes.getIndex(iface[e.slot]).?][idx] = e.func.int();
                }
            }
            rt.vtable = vt;
            rt.itables = tables;
        }
        r.slot_index = index;
        r.slot_iface = iface;
    }

    /// Gives each slot class `c` declares its index, after its
    /// superclass's slots, or at its place among an interface's; the
    /// length of `c`'s vtable, `Any`'s for an interface.
    fn slotsOf(b: *Build, c: ClassId, vlen: []u32, index: []u32, iface: []u32, depth: u32) Error!u32 {
        if (vlen[c.int()] != NONE) return vlen[c.int()];
        const s = b.s;
        const cls = switch (b.class_origins.items[c.int()]) {
            .decl => |d| d,
            .sam => null,
        };
        const is_iface = if (cls) |d| s.syms.classInfo(d).kind == .interface else false;
        var n: u32 = 0;
        if (depth < 64) {
            if (try b.superclassOf(c)) |sup| n = try b.slotsOf(sup, vlen, index, iface, depth + 1);
        }
        var own: u32 = 0;
        if (cls) |d| {
            _ = d;
            for (b.class_members.items[c.int()].items) |m| {
                const fl = s.syms.flags(m);
                if (fl.static or fl.visibility == .private) continue;
                switch (s.syms.kind(m)) {
                    .function => if (declaresSlot(try b.fnRoots(m), m)) {
                        if (b.br.funcOfOpt(m)) |f| b.placeSlot(f, c, is_iface, n, &own, index, iface);
                    },
                    .property => {
                        if (declaresSlot(try b.propRoots(m), m)) {
                            const g = b.br.getter_of[m.int()];
                            if (g.int() != NONE) b.placeSlot(g, c, is_iface, n, &own, index, iface);
                        }
                        if (b.br.setterOf(m)) |st| if (declaresSlot(try b.setterRoots(m), m)) {
                            b.placeSlot(st, c, is_iface, n, &own, index, iface);
                        };
                    },
                    else => {},
                }
            }
        }
        vlen[c.int()] = if (is_iface) n else n + own;
        return vlen[c.int()];
    }

    fn placeSlot(b: *Build, f: FuncId, c: ClassId, is_iface: bool, n: u32, own: *u32, index: []u32, iface: []u32) void {
        _ = b;
        if (index[f.int()] != NONE) return;
        index[f.int()] = if (is_iface) own.* else n + own.*;
        if (is_iface) iface[f.int()] = c.int();
        own.* += 1;
    }

    /// The class `c` extends: its class supertype, else `Any`, as an
    /// interface's members include `Any`'s; null for `Any` itself.
    fn superclassOf(b: *Build, c: ClassId) Error!?ClassId {
        const s = b.s;
        for (try b.supersOf(c)) |sup| {
            switch (b.class_origins.items[sup.int()]) {
                .decl => |d| if (s.syms.classInfo(d).kind != .interface) return sup,
                .sam => return sup,
            }
        }
        const any = b.br.classOfOpt(s.builtins.any) orelse return null;
        return if (any == c) null else any;
    }

    /// By FuncId: the native the VM answers a virtual call through the slot
    /// that function roots with on a host value, from the members it
    /// implements.
    fn hostSlots(b: *Build, base: []const NativeId, nf: usize) Error![]const NativeId {
        const out = try b.grown(NativeId, base, nf, .none);
        if (b.opts.host_fns == null) return out;
        const first_func = b.baseFuncCount();
        for (b.origins.items[first_func..], first_func..) |o, i| {
            const id = FuncId.from(@intCast(i));
            const sym, const kind = b.memberOf(o, id) orelse continue;
            var rt = (try b.hostFnBinding(try b.qualName(sym), kind)) orelse continue;
            rt.receiver = true;
            out[i] = NativeId.from(@intCast(b.natives.items.len));
            try b.natives.append(b.a, rt);
        }
        return out;
    }

    /// By FuncId from `first`: the init unit of the file whose facade
    /// declares the function (a top-level function, accessor or defaults
    /// bridge), `NONE` for any other function or a file with no unit.
    fn facadeUnits(b: *Build, old: []const u32, n: usize, first: usize) Error![]const u32 {
        const s = b.s;
        const out = try b.grown(u32, old, n, NONE);
        var by_file: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        for (b.units.items, 0..) |u, i| switch (u) {
            .file => |f| try by_file.put(b.a, f, @intCast(i)),
            // Entering a file's function runs its lazy unit only.
            .enum_class, .eager_file => {},
        };
        for (b.origins.items[first..], out[first..]) |o, *unit| {
            const sym: Sym = switch (o) {
                .decl, .getter, .setter, .defaults => |x| x,
                else => continue,
            };
            const owner = s.syms.owner(sym);
            if (owner == .none or s.syms.kind(owner) != .package) continue;
            unit.* = by_file.get(s.syms.get(sym).file) orelse NONE;
        }
        return out;
    }

    fn baseClasses(b: *Build) resolved.BaseClasses {
        return .{
            .empty_coroutine_context = b.br.classOfOpt(b.s.classByFqn("kotlin.coroutines.EmptyCoroutineContext")),
            .result = b.primaryOf("kotlin.Result"),
            .result_failure = b.primaryOf("kotlin.Result.Failure"),
            .init_failed = b.primaryOf("klio.ExceptionInInitializerError"),
            .no_class_def = b.primaryOf("klio.NoClassDefFoundError"),
            .match_groups = b.primaryOf("kotlin.text.KlioMatchGroups"),
            .ktype = b.ktypeLayout(),
            .coroutine_suspended = b.entryStatic("kotlin.coroutines.intrinsics.CoroutineSingletons", "COROUTINE_SUSPENDED"),
        };
    }

    /// The static of enum class `fqn`'s entry `name`.
    fn entryStatic(b: *Build, fqn: []const u8, name: []const u8) ?StaticId {
        const s = b.s;
        const cls = s.classByFqn(fqn);
        if (cls == .none) return null;
        for (s.syms.classInfo(cls).enum_entries) |e| {
            if (std.mem.eql(u8, s.str(s.syms.name(e)), name)) return b.br.staticOf(e);
        }
        return null;
    }

    fn ktypeLayout(b: *Build) ?resolved.KTypeLayout {
        const s = b.s;
        const cls = s.classByFqn("kotlin.reflect.KlioType");
        if (cls == .none) return null;
        const c = b.br.classOfOpt(cls) orelse return null;
        const slotOf = struct {
            fn at(bb: *Build, owner: Sym, name: []const u8) ?u32 {
                const n = bb.s.names.lookup(name) orelse return null;
                for (sema.symbols.Symbols.members(&bb.s.syms.classInfo(owner).members, n)) |m| {
                    if (bb.s.syms.kind(m) == .property) return bb.br.fieldOf(m);
                }
                return null;
            }
        }.at;
        return .{
            .class = c,
            .classifier = slotOf(b, cls, "classifier") orelse return null,
            .nullable = slotOf(b, cls, "isMarkedNullable") orelse return null,
        };
    }

    /// What init unit `u` initializes, as a failure names it: `file
    /// cfg.limits.kt` or `enum class pkg.Color`.
    fn unitName(b: *Build, u: u32) Error![]const u8 {
        return switch (b.units.items[u]) {
            .enum_class => |e| std.fmt.allocPrint(b.a, "enum class {s}", .{try kotlinName(b.s, b.a, e)}),
            .file, .eager_file => |f| std.fmt.allocPrint(b.a, "file {s}", .{try kotlinFileName(b.s, b.a, f)}),
        };
    }

    /// Class `fqn` and its primary constructor, when the base declares both.
    fn primaryOf(b: *Build, fqn: []const u8) ?resolved.ClassCtor {
        const cls = b.s.classByFqn(fqn);
        if (cls == .none) return null;
        const c = b.br.classOfOpt(cls) orelse return null;
        const ctor = b.br.funcOfOpt(b.s.syms.classInfo(cls).primary_ctor) orelse return null;
        return .{ .class = c, .ctor = ctor };
    }

    fn hostClasses(b: *Build) Error!resolved.HostClasses {
        const s = b.s;
        const bi = s.builtins;
        var h: resolved.HostClasses = .{
            .unit = b.optClass(bi.unit),
            .boolean = b.optClass(bi.boolean),
            .char = b.optClass(bi.char),
            .byte = b.optClass(bi.byte),
            .short = b.optClass(bi.short),
            .int = b.optClass(bi.int),
            .long = b.optClass(bi.long),
            .float = b.optClass(bi.float),
            .double = b.optClass(bi.double),
            .ubyte = b.optClass(bi.ubyte),
            .ushort = b.optClass(bi.ushort),
            .uint = b.optClass(bi.uint),
            .ulong = b.optClass(bi.ulong),
            .string = b.optClass(bi.string),
            .array = b.optClass(bi.array),
        };
        var max: u32 = 0;
        var it = s.function_classes.iterator();
        while (it.next()) |e| max = @max(max, e.key_ptr.* + 1);
        const fns = try filled(b.a, ClassId, max, ClassId.from(NONE));
        const slots = try filled(b.a, MethodSlotId, max, MethodSlotId.from(NONE));
        it = s.function_classes.iterator();
        while (it.next()) |e| {
            const cls = e.value_ptr.*;
            const c = b.br.classOfOpt(cls) orelse continue;
            fns[e.key_ptr.*] = c;
            for (sema.symbols.Symbols.members(&s.syms.classInfo(cls).members, sema.wk.invoke)) |inv| {
                if (b.br.funcOfOpt(inv)) |f| slots[e.key_ptr.*] = MethodSlotId.fromFunc(f);
            }
        }
        h.function = fns;
        h.invoke_slot = slots;
        const sfns = try filled(b.a, ClassId, max, ClassId.from(NONE));
        const sslots = try filled(b.a, MethodSlotId, max, MethodSlotId.from(NONE));
        var sit = s.suspend_function_classes.iterator();
        while (sit.next()) |e| {
            if (e.key_ptr.* >= max) continue;
            const c = b.br.classOfOpt(e.value_ptr.*) orelse continue;
            sfns[e.key_ptr.*] = c;
            for (sema.symbols.Symbols.members(&s.syms.classInfo(e.value_ptr.*).members, sema.wk.invoke)) |inv| {
                if (b.br.funcOfOpt(inv)) |f| sslots[e.key_ptr.*] = MethodSlotId.fromFunc(f);
            }
        }
        h.suspend_function = sfns;
        h.suspend_invoke_slot = sslots;
        inline for (@typeInfo(runtime.PrimitiveArrayKind).@"enum".fields, 0..) |f, k| {
            h.prim_array[k] = b.classByFqn("kotlin." ++ f.name ++ "Array");
            h.prim_iterator[k] = b.classByFqn("kotlin.collections." ++ f.name ++ "Iterator");
        }
        for (host_kinds) |k| h.by_tag[@intFromEnum(k.tag)] = b.classByFqn(k.fqn);
        // The host's `COROUTINE_SUSPENDED` is the entry of that name.
        h.by_tag[@intFromEnum(std.meta.Tag(runtime.Value).CoroutineSuspended)] = b.classByFqn("kotlin.coroutines.intrinsics.CoroutineSingletons");
        inline for (@typeInfo(runtime.RangeKind).@"enum".fields, 0..) |f, k| {
            h.range[k] = b.classByFqn("kotlin.ranges." ++ f.name ++ "Range");
            h.progression[k] = b.classByFqn("kotlin.ranges." ++ f.name ++ "Progression");
        }
        h.property = try b.byArity("kotlin.reflect.KProperty");
        h.mutable_property = try b.byArity("kotlin.reflect.KMutableProperty");
        h.property_get = try b.slotsByArity(h.property, "get");
        h.property_set = try b.slotsByArity(h.mutable_property, "set");
        if (s.builtins.any != .none) {
            const any_members = &s.syms.classInfo(s.builtins.any).members;
            for (sema.symbols.Symbols.members(any_members, sema.wk.equals)) |m| {
                if (b.br.funcOfOpt(m)) |f| h.equals_slot = b.br.slotOf(f);
            }
            for (sema.symbols.Symbols.members(any_members, sema.wk.hashCode)) |m| {
                if (b.br.funcOfOpt(m)) |f| h.hash_code_slot = b.br.slotOf(f);
            }
            for (sema.symbols.Symbols.members(any_members, sema.wk.toString)) |m| {
                if (b.br.funcOfOpt(m)) |f| h.to_string_slot = b.br.slotOf(f);
            }
        }
        h.list = b.classByFqn("kotlin.collections.List");
        h.set = b.classByFqn("kotlin.collections.Set");
        h.map = b.classByFqn("kotlin.collections.Map");
        h.mutable_iterator = b.classByFqn("kotlin.collections.MutableIterator");
        h.mutable_list_iterator = b.classByFqn("kotlin.collections.MutableListIterator");
        const entry = s.classByFqn("kotlin.collections.Map.Entry");
        if (entry != .none) {
            h.map_entry = b.br.classOfOpt(entry);
            h.entry_key_slot = b.getterSlot(entry, "key");
            h.entry_value_slot = b.getterSlot(entry, "value");
        }
        const callable = s.classByFqn("kotlin.reflect.KCallable");
        if (callable != .none) {
            if (s.names.lookup("name")) |n| {
                for (sema.symbols.Symbols.members(&s.syms.classInfo(callable).members, n)) |p| {
                    if (s.syms.kind(p) != .property) continue;
                    const g = b.br.getter_of[p.int()];
                    if (g.int() != NONE) h.callable_name = b.br.slotOf(g);
                }
            }
        }
        return h;
    }

    /// The root slot of the getter of `cls`'s property `name`.
    fn getterSlot(b: *const Build, cls: Sym, name: []const u8) ?MethodSlotId {
        const s = b.s;
        const n = s.names.lookup(name) orelse return null;
        for (sema.symbols.Symbols.members(&s.syms.classInfo(cls).members, n)) |p| {
            if (s.syms.kind(p) != .property) continue;
            const g = b.br.getter_of[p.int()];
            if (g.int() != NONE) return b.br.slotOf(g);
        }
        return null;
    }

    fn classByFqn(b: *const Build, fqn: []const u8) ?ClassId {
        const c = b.s.classByFqn(fqn);
        if (c == .none) return null;
        return b.br.classOfOpt(c);
    }

    /// `<prefix>0`, `<prefix>1`, ... while the base declares them.
    fn byArity(b: *Build, prefix: []const u8) Error![]const ClassId {
        var out: std.ArrayList(ClassId) = .empty;
        while (true) {
            const fqn = try std.fmt.allocPrint(b.a, "{s}{d}", .{ prefix, out.items.len });
            const c = b.classByFqn(fqn) orelse break;
            try out.append(b.a, c);
        }
        return out.items;
    }

    /// Per class of `classes`, the root slot of its own member `name`.
    fn slotsByArity(b: *Build, classes: []const ClassId, name: []const u8) Error![]const MethodSlotId {
        const s = b.s;
        const out = try filled(b.a, MethodSlotId, classes.len, MethodSlotId.from(NONE));
        const n = s.names.lookup(name) orelse return out;
        for (classes, out) |c, *o| {
            const cls = switch (b.class_origins.items[c.int()]) {
                .decl => |d| d,
                .sam => continue,
            };
            for (sema.symbols.Symbols.members(&s.syms.classInfo(cls).members, n)) |m| {
                if (s.syms.kind(m) != .function or s.syms.owner(m) != cls) continue;
                const f = b.br.funcOfOpt(m) orelse continue;
                if (b.br.slotOf(f)) |sl| o.* = sl;
            }
        }
        return out;
    }

    /// The exceptions the VM raises itself: each class with its
    /// `(message: String?)` constructor, where the base declares both.
    /// The base members natives call back into Kotlin through: `Any`'s,
    /// comparisons, iteration, collections' size and lookups, and each
    /// `FunctionN.invoke`.
    fn wellKnown(b: *Build) Error!resolved.WellKnownSlots {
        const s = b.s;
        var out: resolved.WellKnownSlots = .initFill(null);
        for (std.enums.values(runtime.WellKnown)) |member| {
            // One slot per arity: `HostClasses.invoke_slot`.
            if (member == .invoke) continue;
            const w = wellKnownDeclaration(member);
            const cls = s.classByFqn(w.class);
            if (cls == .none) continue;
            const n = s.names.lookup(member.memberName()) orelse continue;
            for (sema.symbols.Symbols.members(&s.syms.classInfo(cls).members, n)) |m| {
                const f = if (member.isProperty())
                    (if (s.syms.kind(m) == .property) b.br.getter_of[m.int()] else continue)
                else
                    (if (s.syms.kind(m) == .function and s.syms.functionInfo(m).params.len == w.arity) b.br.funcOfOpt(m) orelse continue else continue);
                if (f.int() == NONE) continue;
                out.set(member, MethodSlotId.fromFunc(f));
                break;
            }
        }
        return out;
    }

    /// Each class's generated `serializer(...)`: an object's own taking no
    /// arguments, or its companion's taking one serializer per type
    /// parameter, as the serialization pass declares them.
    fn serializers(b: *Build, base: []const ?resolved.SerializerRt) Error![]const ?resolved.SerializerRt {
        const s = b.s;
        const out = try b.grown(?resolved.SerializerRt, base, b.br.m.classes.items.len, null);
        const n = s.names.lookup("serializer") orelse return out;
        var i: u32 = b.firstSym();
        while (i < b.n) : (i += 1) {
            const cls = Sym.from(i);
            if (s.syms.kind(cls) != .class) continue;
            const c = b.br.classOfOpt(cls) orelse continue;
            const info = s.syms.classInfo(cls);
            const holder, const arity: usize = switch (info.kind) {
                .object => .{ cls, 0 },
                .companion => continue,
                else => .{ info.companion, info.type_params.len },
            };
            if (holder == .none) continue;
            const hc = b.br.classOfOpt(holder) orelse continue;
            for (sema.symbols.Symbols.members(&s.syms.classInfo(holder).members, n)) |m| {
                if (s.syms.kind(m) != .function or s.syms.functionInfo(m).params.len != arity) continue;
                const f = b.br.funcOfOpt(m) orelse continue;
                out[c.int()] = .{ .holder = hc, .func = f, .arity = @intCast(arity) };
                break;
            }
        }
        return out;
    }

    /// The base's by-FQN entries are `base`'s, which a loaded base keeps.
    fn exceptions(b: *Build, base: resolved.Exceptions) Error!resolved.Exceptions {
        var e: resolved.Exceptions = .{};
        e.by_fqn = try base.by_fqn.clone(b.a);
        e.null_pointer = try b.raised("kotlin.NullPointerException");
        e.class_cast = try b.raised("kotlin.ClassCastException");
        e.arithmetic = try b.raised("kotlin.ArithmeticException");
        e.uninitialized_property = try b.raised("kotlin.UninitializedPropertyAccessException");
        e.index_out_of_bounds = try b.raised("kotlin.IndexOutOfBoundsException");
        e.array_index_out_of_bounds = try b.raised("klio.ArrayIndexOutOfBoundsException");
        e.string_index_out_of_bounds = try b.raised("klio.StringIndexOutOfBoundsException");
        const s = b.s;
        const throwable = s.builtins.throwable;
        const tc = if (throwable != .none) b.br.classOfOpt(throwable) else null;
        if (tc) |t| {
            var i: u32 = b.firstSym();
            while (i < b.n) : (i += 1) {
                const sym = Sym.from(i);
                if (s.syms.kind(sym) != .class or s.syms.flags(sym).superseded) continue;
                const c = b.br.classOfOpt(sym) orelse continue;
                if (c != t and !b.br.m.classIsA(c, t)) continue;
                const fqn = s.str(s.syms.classInfo(sym).fqn);
                if (try b.raised(fqn)) |r| try e.by_fqn.put(b.a, fqn, r);
            }
        }
        return e;
    }

    fn raised(b: *Build, fqn: []const u8) Error!?resolved.Raised {
        const s = b.s;
        const cls = s.classByFqn(fqn);
        if (cls == .none) return null;
        const c = b.br.classOfOpt(cls) orelse return null;
        const string_q = try s.types.makeNullable(s.t.string);
        for (sema.symbols.Symbols.members(&s.syms.classInfo(cls).members, sema.wk.init)) |ctor| {
            if (s.syms.kind(ctor) != .constructor) continue;
            const params = s.syms.functionInfo(ctor).params;
            if (params.len != 1) continue;
            if (try sema.headers.paramType(s, params[0]) != string_q) continue;
            const f = b.br.funcOfOpt(ctor) orelse continue;
            return .{ .class = c, .ctor = f };
        }
        return null;
    }

    fn optClass(b: *const Build, sym: Sym) ?ClassId {
        if (sym == .none) return null;
        return b.br.classOfOpt(sym);
    }
};

// ------------------------------------------------------------- helpers ----

fn filled(a: Allocator, comptime T: type, n: usize, v: T) Allocator.Error![]T {
    const out = try a.alloc(T, n);
    @memset(out, v);
    return out;
}

fn isLambda(s: *sema.Sema, f: Sym) bool {
    return switch (s.syms.get(f).decl) {
        .lambda, .anon_fun => true,
        else => false,
    };
}

fn isAbstract(s: *sema.Sema, sym: Sym) bool {
    const fl = s.syms.flags(sym);
    return fl.modality == .abstract and !fl.has_body;
}

fn hasDefaults(s: *sema.Sema, f: Sym) bool {
    for (s.syms.functionInfo(f).params) |p| {
        if (s.syms.flags(p).has_default) return true;
    }
    return false;
}

/// A member called on an instance: owned by a class and not static.
/// A top-level extension without context parameters: its receiver is the
/// first argument.
fn receiverFirst(s: *sema.Sema, decl: Sym) bool {
    const owner = s.syms.owner(decl);
    if (owner == .none or s.syms.kind(owner) != .package) return false;
    return switch (s.syms.kind(decl)) {
        .function => s.syms.functionInfo(decl).receiver != .none and s.syms.functionInfo(decl).context_params.len == 0,
        .property => s.syms.propertyInfo(decl).receiver != .none and s.syms.propertyInfo(decl).context_params.len == 0,
        else => false,
    };
}

/// The parameters a composable body takes last, as the Compose compiler
/// adds them: the composer it composes into and the caller's change bits,
/// `$changed`, `$changed1`, ... as many as its tracked parameters need.
pub const composer_param = "$composer";
pub const changed_param = "$changed";

fn changedName(a: Allocator, k: usize) Allocator.Error![]const u8 {
    if (k == 0) return changed_param;
    return std.fmt.allocPrint(a, "{s}{d}", .{ changed_param, k });
}

/// The `$changed` ints over `slots` tracked parameters: each holds ten
/// 3-bit slots above the forced bit, and there is always one.
pub fn changedInts(slots: usize) u16 {
    if (slots == 0) return 1;
    return @intCast((slots + 9) / 10);
}

/// A composable function's `$changed` ints: its slots are its contexts,
/// extension receiver, value parameters and, when `instance`, its
/// dispatch receiver.
pub fn declChangedInts(s: *sema.Sema, f: Sym, instance: bool) u16 {
    const info = s.syms.functionInfo(f);
    return changedInts(info.context_params.len + @intFromBool(info.receiver != .none) + info.params.len + @intFromBool(instance));
}

/// A composable getter's `$changed` ints: its receivers' slots.
pub fn getterChangedInts(s: *sema.Sema, p: Sym) u16 {
    const info = s.syms.propertyInfo(p);
    return changedInts(info.context_params.len + @intFromBool(info.receiver != .none) + @intFromBool(isInstanceMember(s, p)));
}

/// The mask a composable with defaults takes after its change bits, as
/// the Compose compiler adds it: a bit per value parameter the caller
/// omitted, 31 to an int.
pub const default_param = "$default";

pub fn defaultInts(values: usize) u16 {
    return @intCast((values + 30) / 31);
}

/// A composable whose defaults its own body fills from `$default`: one
/// with defaults of its own that a call reaches directly, not inline and
/// not overridable. An overridable one keeps its defaults bridge.
pub fn composableDefaults(s: *sema.Sema, f: Sym) bool {
    if (!composableFunction(s, f)) return false;
    const fl = s.syms.flags(f);
    if (fl.inline_ or !fl.has_body) return false;
    if (isInstanceMember(s, f)) {
        const owner = s.syms.owner(f);
        if (fl.modality != .final or s.syms.classInfo(owner).kind == .interface) return false;
    }
    return hasDefaults(s, f);
}

/// A composable function type's `$changed` ints over its `arity` values:
/// the lambda itself takes the slot after them.
pub fn lambdaChangedInts(arity: usize) u16 {
    return changedInts(arity + 1);
}

/// A `@Composable` function, which takes the composer pair after its value
/// parameters.
pub fn composableFunction(s: *sema.Sema, f: Sym) bool {
    return s.syms.kind(f) == .function and s.syms.flags(f).composable;
}

/// A property whose getter is `@Composable`, which takes the composer pair
/// last.
pub fn composableGetter(s: *sema.Sema, p: Sym) bool {
    return s.syms.kind(p) == .property and s.syms.flags(p).composable;
}

/// A composable that owns a recompose scope: not inline, returning `Unit`,
/// and not marked to recompose with its caller or to manage its own groups.
pub fn restartable(s: *sema.Sema, f: Sym) Allocator.Error!bool {
    if (!composableFunction(s, f)) return false;
    const fl = s.syms.flags(f);
    if (fl.inline_ or !fl.has_body or isAbstract(s, f)) return false;
    if (s.syms.get(f).decl != .function) return false;
    if (try sema.headers.returnType(s, f) != s.t.unit) return false;
    inline for (.{ "NonRestartableComposable", "ReadOnlyComposable", "ExplicitGroupsComposable" }) |n| {
        if (try sema.headers.hasAnnotation(s, f, .decl, s.classByFqn("androidx.compose.runtime." ++ n))) return false;
    }
    return true;
}

/// A `@Composable` function type: its values take the composer pair after
/// their parameters.
pub fn composableType(s: *sema.Sema, t: TypeId) bool {
    if (t == .none) return false;
    return switch (s.types.get(t)) {
        .class => |c| c.attrs.composable,
        else => false,
    };
}

fn isInstanceMember(s: *sema.Sema, sym: Sym) bool {
    const owner = s.syms.owner(sym);
    if (owner == .none or s.syms.kind(owner) != .class) return false;
    return !s.syms.flags(sym).static;
}

/// Whether a function type returns `Unit`.
fn returnsUnit(s: *sema.Sema, t: TypeId) bool {
    if (t == .none) return false;
    const args = s.types.argsOf(t);
    return args.len != 0 and args[args.len - 1].ty == s.t.unit;
}

/// The number of value parameters a function type takes: its class's type
/// arguments less the result.
fn fnArity(s: *sema.Sema, t: TypeId) usize {
    if (t == .none) return 0;
    return switch (s.types.get(t)) {
        .class => |c| if (c.args.len == 0) 0 else c.args.len - 1,
        else => 0,
    };
}

fn isSuspendFunctionType(s: *sema.Sema, t: TypeId) bool {
    if (t == .none) return false;
    const cls = switch (s.types.get(t)) {
        .class => |c| c.sym,
        else => return false,
    };
    const n: u32 = @intCast(fnArity(s, t));
    return s.suspend_function_classes.get(n) == cls or s.ksuspend_function_classes.get(n) == cls;
}

fn seedOfType(s: *sema.Sema, t: TypeId) SlotSeed {
    if (t == .none) return .null_ref;
    const c = switch (s.types.get(t)) {
        .class => |c| c,
        else => return .null_ref,
    };
    if (c.nullable) return .null_ref;
    const bi = s.builtins;
    if (c.sym == .none) return .null_ref;
    if (c.sym == bi.int) return .int;
    if (c.sym == bi.long) return .long;
    if (c.sym == bi.short) return .short;
    if (c.sym == bi.byte) return .byte;
    if (c.sym == bi.float) return .float;
    if (c.sym == bi.double) return .double;
    if (c.sym == bi.boolean) return .boolean;
    if (c.sym == bi.char) return .char;
    return .null_ref;
}

/// The type a parameter of seed `seed` is declared, named as `kinds.zig`
/// reads it: a primitive's Kotlin name, or none.
fn primitiveType(seed: SlotSeed) ir.TypeRef {
    const name: []const u8 = switch (seed) {
        .null_ref => "",
        .int => "kotlin.Int",
        .long => "kotlin.Long",
        .short => "kotlin.Short",
        .byte => "kotlin.Byte",
        .float => "kotlin.Float",
        .double => "kotlin.Double",
        .boolean => "kotlin.Boolean",
        .char => "kotlin.Char",
    };
    return .{ .name = name, .nullable = seed == .null_ref, .args = &.{} };
}

/// Per written supertype of a class, whether it is delegated with `by`.
fn supertypeDelegates(s: *sema.Sema, cls: Sym) []const bool {
    // A class laid out here is one this build analyzed: a base image's
    // layouts are in place already.
    const ds: []const ?ast.Expr = switch (s.syms.get(cls).decl) {
        .class => |c| c.?.supertype_delegates,
        .object => |o| o.?.supertype_delegates,
        .object_literal => |o| o.?.supertype_delegates,
        else => return &.{},
    };
    var any = false;
    for (ds) |d| any = any or d != null;
    if (!any) return &.{};
    const out = s.arena.alloc(bool, ds.len) catch return &.{};
    for (ds, out) |d, *o| o.* = d != null;
    return out;
}

/// The source range of a nested function or local class.
/// Null for a declaration read back from a base image, whose captures are
/// in the image.
fn declSpan(s: *sema.Sema, sym: Sym) ?@import("span").Span {
    return switch (s.syms.get(sym).decl) {
        .lambda => |l| (l orelse return null).span,
        .anon_fun => |f| (f orelse return null).span,
        .function => |f| (f orelse return null).span,
        .class => |c| (c orelse return null).span,
        .object => |o| (o orelse return null).span,
        .object_literal => |o| (o orelse return null).span,
        else => null,
    };
}

/// A class def naming the class and nothing else: code lowered from sema
/// reads a class by its id, never through the def's member lists.
/// Each host value kind and the class its values are instances of.
const HostKind = struct { tag: std.meta.Tag(runtime.Value), fqn: []const u8 };
const host_kinds = [_]HostKind{
    .{ .tag = .List, .fqn = "kotlin.collections.ArrayList" },
    .{ .tag = .Set, .fqn = "kotlin.collections.LinkedHashSet" },
    .{ .tag = .Map, .fqn = "kotlin.collections.LinkedHashMap" },
    // Every entry the host makes is a `MutableEntry`, as a JVM map's is.
    .{ .tag = .MapEntry, .fqn = "kotlin.collections.MutableMap.MutableEntry" },
    .{ .tag = .Pair, .fqn = "kotlin.Pair" },
    .{ .tag = .Triple, .fqn = "kotlin.Triple" },
    .{ .tag = .Result, .fqn = "kotlin.Result" },
    .{ .tag = .Comparator, .fqn = "kotlin.Comparator" },
    .{ .tag = .Exception, .fqn = "kotlin.Throwable" },
    .{ .tag = .Class, .fqn = "kotlin.reflect.KClass" },
    .{ .tag = .Sequence, .fqn = "kotlin.sequences.Sequence" },
    .{ .tag = .Iterator, .fqn = "kotlin.collections.Iterator" },
    .{ .tag = .RangeIter, .fqn = "kotlin.collections.Iterator" },
    .{ .tag = .SeqIter, .fqn = "kotlin.collections.Iterator" },
    .{ .tag = .Regex, .fqn = "kotlin.text.Regex" },
    .{ .tag = .Match, .fqn = "kotlin.text.MatchResult" },
    .{ .tag = .MatchGroup, .fqn = "kotlin.text.MatchGroup" },
    .{ .tag = .StringBuilder, .fqn = "kotlin.text.StringBuilder" },
    // The host's thread handles (`thread`, `klio.Thread.currentThread`) are
    // its only bound methods.
    .{ .tag = .BoundMethod, .fqn = "klio.Thread" },
};

const MemberKind = resolved.MemberKind;

/// The receiver type of extension `decl` as written (a qualified path when
/// one is written), which the host keys receiver-qualified symbols by.
fn receiverWritten(s: *sema.Sema, decl: Sym) ?[]const u8 {
    // A base image's natives were bound at the bake.
    const rt = switch (s.syms.get(decl).decl) {
        .function => |fd| (fd orelse return null).receiver_type orelse return null,
        .property => |pd| (pd orelse return null).receiver_type orelse return null,
        else => return null,
    };
    return rt.x().qualified_path orelse rt.name.name;
}

/// What a host-member binding runs when something calls its function
/// directly instead of through `NativeRt.member`.
fn hostMemberUnbound(ctx: *runtime.CallCtx) Allocator.Error!runtime.EvalResult {
    _ = ctx;
    return .{ .err = .{ .Unimplemented = "a host member binding was called without its member" } };
}

/// Whether `m` is one of the roots its override walk found: it declares a
/// slot of its own.
fn declaresSlot(roots: []const Sym, m: Sym) bool {
    for (roots) |r| if (r == m) return true;
    return false;
}

/// Whether functions `a` and `b`, whose signatures `sema.members.sameSignature`
/// matched, take equal parameter and receiver types seen through `a_subst`
/// and `b_subst`, type arguments included.
fn sameParamTypes(s: *sema.Sema, a: Sym, a_subst: *const sema.types.Subst, b: Sym, b_subst: *const sema.types.Subst) Error!bool {
    const ai = s.syms.functionInfo(a);
    const bi = s.syms.functionInfo(b);
    // `b`'s own type parameters read as `a`'s.
    var bs: sema.types.Subst = .empty;
    var it = b_subst.iterator();
    while (it.next()) |e| try bs.put(s.arena, e.key_ptr.*, e.value_ptr.*);
    for (ai.type_params, bi.type_params) |atp, btp| try bs.put(s.arena, btp, try s.types.param(atp, false));
    if (ai.receiver != .none) {
        const ar = try s.types.substitute(ai.receiver, a_subst);
        const br = try s.types.substitute(bi.receiver, &bs);
        if (!try sema.subtyping.equivalent(s, ar, br)) return false;
    }
    for (ai.params, bi.params) |ap, bp| {
        const at = try s.types.substitute(try sema.headers.paramType(s, ap), a_subst);
        const bt = try s.types.substitute(try sema.headers.paramType(s, bp), &bs);
        if (!try sema.subtyping.equivalent(s, at, bt)) return false;
    }
    return true;
}

/// The class declaring well-known `member`, and the value arguments a
/// function member takes.
fn wellKnownDeclaration(member: runtime.WellKnown) struct { class: []const u8, arity: u8 = 0 } {
    return switch (member) {
        .to_string, .hash_code => .{ .class = "kotlin.Any" },
        .equals => .{ .class = "kotlin.Any", .arity = 1 },
        .compare_to => .{ .class = "kotlin.Comparable", .arity = 1 },
        .compare => .{ .class = "kotlin.Comparator", .arity = 2 },
        .iterator => .{ .class = "kotlin.collections.Iterable" },
        .sequence_iterator => .{ .class = "kotlin.sequences.Sequence" },
        .has_next, .next => .{ .class = "kotlin.collections.Iterator" },
        .size, .is_empty => .{ .class = "kotlin.collections.Collection" },
        .contains => .{ .class = "kotlin.collections.Collection", .arity = 1 },
        .to_array => .{ .class = "kotlin.collections.AbstractCollection" },
        .list_get => .{ .class = "kotlin.collections.List", .arity = 1 },
        .map_size, .entries, .keys, .values => .{ .class = "kotlin.collections.Map" },
        .map_get, .contains_key => .{ .class = "kotlin.collections.Map", .arity = 1 },
        .entry_key, .entry_value => .{ .class = "kotlin.collections.Map.Entry" },
        .length => .{ .class = "kotlin.CharSequence" },
        .char_at => .{ .class = "kotlin.CharSequence", .arity = 1 },
        .source_iterator => .{ .class = "kotlin.collections.Grouping" },
        .key_of => .{ .class = "kotlin.collections.Grouping", .arity = 1 },
        .context => .{ .class = "kotlin.coroutines.Continuation" },
        .coroutine_context => .{ .class = "kotlinx.coroutines.CoroutineScope" },
        .next_int => .{ .class = "kotlin.random.Random", .arity = 1 },
        .context_get => .{ .class = "kotlin.coroutines.CoroutineContext", .arity = 1 },
        .handle_exception => .{ .class = "kotlinx.coroutines.CoroutineExceptionHandler", .arity = 2 },
        // Declared once per arity, by `kotlin.jvm.functions.FunctionN`.
        .invoke => .{ .class = "" },
    };
}

/// What a class's run-time def records beyond its `ir.Class`.
pub const ClassDefFlags = struct {
    is_data: bool = false,
    is_sealed: bool = false,
    is_anonymous: bool = false,
    /// A data or value class's primary-constructor properties in parameter
    /// order: the host's structural equality and display read an
    /// instance's fields by these names.
    primary: []const PrimaryProperty = &.{},
};

pub const PrimaryProperty = struct { name: []const u8, mutable: bool };

/// The run-time def of class `c` of module `m`, whose instances have
/// `layout`. Its supertype names are every ancestor's name and FQN, so the
/// host's by-name subtype tests (`Map.Entry` for an entry's equality)
/// answer for classes lowered from sema.
pub fn classDefOf(a: Allocator, m: *const ir.Module, c: usize, layout: []const Slot, flags: ClassDefFlags) Allocator.Error!ObjRef(runtime.ClassDef) {
    const ic = &m.classes.items[c];
    const lslots = try a.alloc(runtime.LayoutSlot, layout.len);
    for (layout, lslots) |sl, *ls| ls.* = .{ .name = sl.name, .seed = resolved.seedValue(sl.seed) };
    var def = try minimalClassDef(a, ic.name, ic.fqn);
    if (c < m.class_ancestors.items.len) {
        var names: std.ArrayList([]const u8) = .empty;
        for (m.class_ancestors.items[c]) |anc| {
            if (anc.int() == c or anc.int() >= m.classes.items.len) continue;
            const ac = &m.classes.items[anc.int()];
            try names.append(a, ac.name);
            if (!std.mem.eql(u8, ac.fqn, ac.name)) try names.append(a, ac.fqn);
        }
        def.supertype_names = names.items;
    }
    def.is_data = flags.is_data;
    def.ordered_slots = for (layout) |sl| {
        if (sl.volatile_) break true;
    } else false;
    def.is_value = ic.is_value;
    def.is_object = ic.is_object;
    def.is_enum = ic.is_enum;
    def.is_sealed = flags.is_sealed;
    def.is_interface = ic.is_interface;
    def.is_fun_interface = ic.is_fun_interface;
    def.is_open = ic.is_open;
    def.is_abstract = ic.is_abstract;
    def.is_inner = ic.is_inner;
    def.is_anonymous = flags.is_anonymous;
    def.is_annotation = ic.is_annotation;
    if (flags.primary.len != 0) {
        const params = try a.alloc(runtime.ClassParamDef, flags.primary.len);
        for (flags.primary, params) |pp, *p| p.* = .{ .property = pp.mutable, .name = pp.name, .default = null, .declared_type = null, .declared_shape = null };
        def.primary_params = params;
    }
    def.ir_class = @intCast(ic.id.int());
    def.layout_slots = lslots;
    def.map_view = mapViewMark(ic.fqn, layout);
    return ObjRef(runtime.ClassDef).init(a, def);
}

/// A map view class's kind and the slot of its `backing` map (`MapViews.kt`); null for
/// any other class.
fn mapViewMark(fqn: []const u8, layout: []const Slot) ?runtime.ClassDef.MapViewMark {
    const kind: runtime.MapViewKind = for ([_]runtime.WellKnownClass{ .hash_map_keys, .hash_map_values, .hash_map_entry_set }, [_]runtime.MapViewKind{ .Keys, .Values, .Entries }) |c, k| {
        if (std.mem.eql(u8, fqn, c.fqn())) break k;
    } else return null;
    for (layout, 0..) |sl, i| if (std.mem.eql(u8, sl.name, "backing")) return .{ .kind = kind, .slot = @intCast(i) };
    return null;
}

/// Binds a loaded native to the host function its table has under its
/// key, as the bridge found it; false when the binding no longer has it.
pub fn rebindNative(rt: *resolved.NativeRt, natives: NativeResolver, constructors: ?NativeResolver, host_fns: ?resolved.HostFnResolver, host_tries: ?resolved.HostTryResolver) bool {
    const f = switch (rt.table) {
        .natives => natives(rt.key),
        .constructors => if (constructors) |c| c(rt.key) else null,
        .members => blk: {
            const hf = host_fns orelse return false;
            rt.host_fn = hf(rt.key) orelse return false;
            break :blk hostMemberUnbound;
        },
        .tries => blk: {
            const ht = host_tries orelse return false;
            rt.host_try = ht(rt.key) orelse return false;
            break :blk hostMemberUnbound;
        },
        .unbound => hostMemberUnbound,
    };
    rt.func = f orelse return false;
    return true;
}

/// The Kotlin qualified name of declaration `sym`: its package, then the
/// classes and functions that enclose it, then its own name. A constructor
/// is `<init>` and a lambda literal or anonymous function `<anonymous>`, so
/// `pkg.Outer.Inner.f`, `pkg.Box.<init>`, `pkg.outer.local` and
/// `pkg.main.<anonymous>`. A declaration of the root package has no prefix.
pub fn kotlinName(s: *sema.Sema, a: Allocator, sym: Sym) Allocator.Error![]const u8 {
    const own: []const u8 = switch (s.syms.get(sym).decl) {
        .lambda, .anon_fun => "<anonymous>",
        else => switch (s.syms.kind(sym)) {
            .package => return s.str(s.syms.packageInfo(sym).fqn),
            .constructor => "<init>",
            else => s.str(s.syms.name(sym)),
        },
    };
    const owner = s.syms.owner(sym);
    if (owner == .none) return own;
    const prefix = try kotlinName(s, a, owner);
    if (prefix.len == 0) return own;
    return std.fmt.allocPrint(a, "{s}.{s}", .{ prefix, own });
}

/// File `f` as Kotlin names it: its package, then its file name
/// (`cfg.limits.kt`), the file name alone in the root package.
pub fn kotlinFileName(s: *sema.Sema, a: Allocator, f: u32) Allocator.Error![]const u8 {
    if (f >= s.files.items.len) return "";
    const fc = s.files.items[f];
    const base = std.fs.path.basename(fc.path);
    const pkg = if (fc.package != .none) s.str(s.syms.packageInfo(fc.package).fqn) else "";
    if (pkg.len == 0) return base;
    return std.fmt.allocPrint(a, "{s}.{s}", .{ pkg, base });
}

/// The frame names a bridge has made.
pub const FrameNames = struct {
    lock: runtime.SpinMutex = .{},
    names: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
};

/// Function `f` as a stack frame names it, its Kotlin qualified
/// declaration: `pkg.run` for a top-level function, `pkg.Box.member` and
/// `pkg.Box.<init>`, `pkg.Box.<get-prop>` and `<set-prop>` for accessors,
/// `pkg.main.<anonymous>` for a lambda, `pkg.outer.local` for a local
/// function, `pkg.f$default` for the stub that fills `f`'s defaults. An
/// object's or companion's initialization runs in its `<init>`, an enum
/// class's entries in its `<init-entries>`, and a file's top-level
/// initializers in `pkg.main.kt.<init>`. Null where the bridge cannot say
/// (a SAM class's or an adapter's function, a base lambda loaded from its
/// image).
pub fn frameName(ctx: *anyopaque, f: FuncId) ?[]const u8 {
    const br: *Bridge = @ptrCast(@alignCast(ctx));
    const fn_ = &br.frame_names;
    fn_.lock.lock();
    defer fn_.lock.unlock();
    if (fn_.names.get(f.int())) |n| return n;
    const a = std.heap.smp_allocator;
    const n = (frameNameOf(br, a, f) catch return null) orelse return null;
    fn_.names.put(a, f.int(), n) catch {};
    return n;
}

fn frameNameOf(br: *Bridge, a: Allocator, f: FuncId) Allocator.Error!?[]const u8 {
    if (f.int() >= br.origin.len) return null;
    const s = br.s;
    switch (br.origin[f.int()]) {
        .decl => |d| {
            if (!frameSymValid(br, f, d)) return null;
            return switch (s.syms.kind(d)) {
                .constructor, .function => try kotlinName(s, a, d),
                else => null,
            };
        },
        .getter, .setter => |p| {
            if (!frameSymValid(br, f, p)) return null;
            const kind = if (br.origin[f.int()] == .getter) "get" else "set";
            const owner = try kotlinName(s, a, s.syms.owner(p));
            const accessor = try std.fmt.allocPrint(a, "<{s}-{s}>", .{ kind, s.str(s.syms.name(p)) });
            if (owner.len == 0) return accessor;
            return try std.fmt.allocPrint(a, "{s}.{s}", .{ owner, accessor });
        },
        .defaults => |d| {
            if (!frameSymValid(br, f, d)) return null;
            if (s.syms.kind(d) == .constructor) return try kotlinName(s, a, d);
            return try std.fmt.allocPrint(a, "{s}$default", .{try kotlinName(s, a, d)});
        },
        .init_unit => |u| {
            if (u >= br.units.len) return null;
            return switch (br.units[u]) {
                .file, .eager_file => |file| try std.fmt.allocPrint(a, "{s}.<init>", .{try kotlinFileName(s, a, file)}),
                .enum_class => |e| try std.fmt.allocPrint(a, "{s}.<init-entries>", .{try kotlinName(s, a, e)}),
            };
        },
        .lambda => |l| {
            if (!frameSymValid(br, f, l)) return null;
            return try kotlinName(s, a, l);
        },
        // A fun interface's wrapper class stands for the interface: its
        // constructor and members are the interface's.
        .sam_ctor => |iface| return try std.fmt.allocPrint(a, "{s}.<init>", .{try kotlinName(s, a, iface)}),
        .sam_method, .sam_equals, .sam_hash_code => |iface| {
            const method = br.m.funcs.items[f.int()].name;
            return try std.fmt.allocPrint(a, "{s}.{s}", .{ try kotlinName(s, a, iface), method });
        },
        // A reference's adapter forwards to the function it references.
        .adapter => |ai| {
            if (ai >= br.adapters.len) return null;
            const target = br.adapters[ai].target;
            if (!frameSymValid(br, f, target)) return null;
            return try kotlinName(s, a, target);
        },
        // A composable's restart runs it again from the lambda its scope keeps.
        .restart => |r| {
            if (!frameSymValid(br, f, r)) return null;
            return try std.fmt.allocPrint(a, "{s}.<anonymous>", .{try kotlinName(s, a, r)});
        },
        else => return null,
    }
}

/// Whether `sym`, the origin of function `f`, names its declaration in
/// this sema: a base function's body-level symbol is the bake's.
fn frameSymValid(br: *const Bridge, f: FuncId, sym: Sym) bool {
    if (br.image_funcs == 0 or f.int() >= br.image_funcs) return true;
    return sym.int() < br.image_prefix;
}

fn minimalClassDef(a: Allocator, name: []const u8, fqn: []const u8) Allocator.Error!runtime.ClassDef {
    return .{
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
        .companion = try ObjRef(?ObjRef(runtime.InstanceData)).init(a, null),
        .enclosing_class = try ObjRef(?ObjRef(runtime.ClassDef)).init(a, null),
        .nested_classes = &.{},
        .captured_env = try ObjRef(runtime.Env).init(a, runtime.Env.init(a)),
        .supertype_delegates = &.{},
        .delegate_forwarders = &.{},
        .object_singleton = try ObjRef(?ObjRef(runtime.InstanceData)).init(a, null),
    };
}
