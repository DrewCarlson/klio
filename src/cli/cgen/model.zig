//! The data the emitter carries between its phases: an accepted function and
//! its register types, the resolved program tables, and the class/global
//! descriptions the caller builds and hands in.
const std = @import("std");
const ir = @import("ir");
const Reg = ir.Reg;
const Func = ir.Func;
const Module = ir.Module;
const cgen = @import("../cgen.zig");

const ThrowTable = cgen.ThrowTable;
const Ty = cgen.Ty;
const layoutFor = cgen.layoutFor;
const no = cgen.no;
const plainFieldName = cgen.plainFieldName;

/// A function accepted into the scalar core, with the machine type of every
/// register its body defines.
pub const Compiled = struct {
    f: *const Func,
    /// The values a lambda body receives ahead of its own parameters: what it
    /// captured, passed as arguments because the call site knows them. Empty
    /// for an ordinary function.
    caps: []const CapInfo,
    /// The parameters this body is compiled against. Usually the function's
    /// own, but a synthesized thunk declares none and reads its caller's
    /// positionally, so it is compiled against the signature it is handed.
    params: []const ir.Param,
    types: []Ty,
    /// The class an object register holds, where the emitter knows it. Needed
    /// to turn a field NAME into the index the compiled code addresses.
    cls: []?u32,
    /// For a register holding a lambda, the body it will run and the registers
    /// it captured. A lambda whose call site can see which body it holds is
    /// called directly, with its captures passed as leading arguments — no
    /// closure object, no dispatch.
    lam: []?LambdaInfo,
    /// For a `List` register, the machine type of its elements where the
    /// emitter knows it — a list built from a literal of one scalar kind. Unit
    /// means unknown, and reading such a list yields an untyped reference.
    elem: []Ty,
    /// For a container register, the CLASS its elements hold where the emitter
    /// knows it — written down in `List<Shape>`, or an enum's own entries.
    /// Null means unknown, and reading such a container yields a reference the
    /// emitter cannot dispatch on.
    elem_cls: []?u32,
    /// Frame slot of each object register, or -1 for a scalar in a C local.
    slot: []i32,
    n_slots: u32,
    ret: Ty,
    /// The class and element type of the returned register, where the body
    /// returns a reference. The DECLARED return type cannot say this for an
    /// inferred one — `val doubled = side * 2` lowers to a thunk carrying a
    /// placeholder — so it comes from what the body actually returns.
    ret_cls: ?u32 = null,
    ret_elem: Ty = .unit,
    /// True for a `suspend` body. Its registers live in a heap frame and it
    /// answers either its result or the SUSPENDED marker, because it can
    /// return in the middle of itself and be re-entered later.
    suspends: bool = false,
    /// How each bare-name read or write inside an inlined receiver body
    /// resolved. The interpreter searches its implicit receivers at run time;
    /// the emitter does that search once, and the answer belongs to the
    /// instruction rather than to a register.
    bare: std.AutoHashMapUnmanaged(*const ir.Inst, BareResolution) = .empty,

    pub fn deinit(self: *Compiled, gpa: std.mem.Allocator) void {
        gpa.free(self.types);
        gpa.free(self.cls);
        gpa.free(self.elem);
        gpa.free(self.elem_cls);
        gpa.free(self.lam);
        gpa.free(self.slot);
        self.bare.deinit(gpa);
    }
};

/// Where a bare name inside an inlined receiver body actually lives.
pub const BareResolution = union(enum) {
    /// A field of one of the implicit receivers, at the index resolved here.
    field: struct { recv: u32, idx: u32 },
    /// A computed property of one of them, read or written through its
    /// accessor.
    accessor: struct { recv: u32, func: ir.FuncId },
    /// Nothing owned the name, so it is the top-level property it falls back
    /// to, looked up by name where the emission knows which globals the
    /// program kept.
    global,
    /// A bare CALL that bound to a member of an implicit receiver: which body
    /// runs is the receiver's class, as for any member call.
    member: struct { recv: u32, slot: u32 },
    /// A bare call that bound to the top-level declaration the lowering
    /// resolved, because no implicit receiver declares the name.
    call: ir.FuncId,
    /// A bare call that names a CLASS: it constructs one. The lowering leaves
    /// the name open when no function of it exists, because which of the two
    /// a name means is a question about scope.
    construct: u32,
};

/// The instance fields of a class, in the order the runtime lays them out:
/// the primary-constructor parameters that double as properties. A class this
/// returns null for is one the emitter cannot lay out, and any program touching
/// it is refused.
/// Everything the emitter resolves once about the whole program and then asks
/// about repeatedly: class layouts, the inheritance links that initialize
/// them, the accessors a class declares, the throwable hierarchy, and the
/// default-argument thunks. Resolving any of these walks the module's tables,
/// so they are computed once and read from here.
pub const Program = struct {
    fields: []const ?[]const FieldInfo,
    /// The superclass each laid-out class extends, and the thunks it passes to
    /// that superclass's constructor. A class is initialized by walking this
    /// chain, so it is kept alongside the flattened field list.
    parents: []const ?Parent = &.{},
    /// The declared body properties, kept so a refusal can be re-derived and
    /// reported against the class that actually blocked a program.
    layouts: []const ClassLayout = &.{},
    /// The program's throwable hierarchy, numbered so a catch is an interval
    /// test rather than a name match.
    throws: ThrowTable = .{ .types = &.{} },
    /// Default-argument thunks per function.
    defaults: []const FuncDefaults = &.{},

    pub fn of(self: Program, cid: u32) ?[]const FieldInfo {
        if (cid >= self.fields.len) return null;
        return self.fields[cid];
    }

    pub fn parentOf(self: Program, cid: u32) ?Parent {
        if (cid >= self.parents.len) return null;
        return self.parents[cid];
    }

    /// The thunk that fills parameter `idx` of this function when a call omits
    /// it, or null when the parameter has no default.
    pub fn defaultThunk(self: Program, func: ir.FuncId, idx: usize) ?ir.FuncId {
        for (self.defaults) |d| {
            if (d.func != func) continue;
            if (idx >= d.slots.len) return null;
            return d.slots[idx];
        }
        return null;
    }

    /// The accessor a class declares for a property that has no storage of its
    /// own. Walks the superclass chain, because a computed property is
    /// inherited exactly as a stored one is.
    pub fn accessor(self: Program, m: *const Module, cid: u32, name: []const u8, comptime which: enum { get, set }) ?ir.FuncId {
        const want = plainFieldName(name);
        var cur: ?u32 = cid;
        var depth: u32 = 0;
        while (cur) |c| : (depth += 1) {
            if (depth > 32 or c >= m.classes.items.len) return null;
            const cdef9 = &m.classes.items[c];
            if (layoutFor(self.layouts, cdef9)) |l| {
                for (l.props) |bp| {
                    if (!std.mem.eql(u8, bp.name, want)) continue;
                    return switch (which) {
                        .get => bp.getter,
                        .set => bp.setter,
                    };
                }
            }
            cur = if (self.parentOf(c)) |pp| pp.cid else null;
        }
        return null;
    }
};

/// The superclass a class extends: which class, and the one thunk per
/// superclass constructor parameter that computes the argument to pass up.
pub const Parent = struct { cid: u32, args: []const ir.FuncId };

/// One field of a laid-out class: where its value comes from and what machine
/// type it holds.
pub const FieldInfo = struct {
    name: []const u8,
    ty: Ty,
    cls: ?u32,
    /// What reading THROUGH this field yields: a list's element, an array's
    /// element, the result of calling a function value.
    elem: Ty = .unit,
    /// The constructor argument that fills it, or null when a thunk does.
    arg: ?u32,
    init: ?ir.FuncId,
    /// True when a superclass declares this field. The superclass's own
    /// initializer fills it, so this class's does not.
    from_parent: bool = false,
    /// True when whoever builds the instance fills this field rather than the
    /// class's initializer: an enum entry's `name` and `ordinal` belong to the
    /// entry, not to the enum's constructor.
    preset: bool = false,
};

/// A class's flattened fields plus the superclass link used to initialize them.
/// `complete` is false while a body property's type is still unresolved: the
/// fields ahead of it are correct and can type an initializer, but the class
/// is not laid out until every property it declares has a place.
pub const Laid = struct { fields: []FieldInfo, parent: ?Parent, complete: bool = true };

pub const Error = error{ OutOfMemory, WriteFailed, NoSpaceLeft };

/// One top-level property: its storage name and the thunk that computes its
/// initial value. A compiled program keeps these in statics published to the
/// collector, and runs the thunks before `main` in declaration order, which is
/// the order the interpreter runs them in.
/// What a class contributes beyond its constructor: the properties declared in
/// its body, with the thunk that computes each one's initial value. The IR
/// does not carry these — the Vm builds them from the AST — so they arrive
/// from the built module alongside the class table.
pub const BodyProp = struct {
    name: []const u8,
    ty: ir.TypeRef,
    init: ?ir.FuncId,
    /// False for a property that stores nothing: a computed `val x get() = ...`
    /// is a getter, not a field, and must not take a slot in the layout.
    has_backing: bool = true,
    is_abstract: bool = false,
    is_lateinit: bool = false,
    /// A declared non-nullable primitive with no initializer, which starts at
    /// its type's zero rather than at a value a thunk computes.
    zero_init: bool = false,
    /// The accessors a property declares. A computed property has no storage,
    /// so reading it is a call to its getter and writing it a call to its
    /// setter.
    getter: ?ir.FuncId = null,
    setter: ?ir.FuncId = null,
};

/// One entry of an `enum class`: its name, and the thunk per constructor
/// argument the declaration writes for it.
pub const EnumEntryInfo = struct {
    name: []const u8,
    args: []const ir.FuncId = &.{},
};

pub const ClassLayout = struct {
    /// Simple class name, matching the IR class it describes.
    name: []const u8,
    props: []const BodyProp,
    /// One thunk per argument this class passes to its superclass constructor,
    /// each taking this class's own constructor arguments.
    parent_args: []const ir.FuncId = &.{},
    /// An `enum class`'s entries in declaration order, which is also their
    /// ordinal order.
    entries: []const EnumEntryInfo = &.{},
    /// The `init { … }` blocks the class declares, lowered as thunks taking
    /// the instance and the constructor's arguments, with the body-property
    /// index each one runs BEFORE. Kotlin runs them in source order
    /// interleaved with the property initializers.
    init_blocks: []const ir.FuncId = &.{},
    init_block_positions: []const usize = &.{},
    /// A `data class` renders and compares by its primary constructor's
    /// properties, which the runtime's own renderer does once it is told.
    is_data: bool = false,
    /// One thunk per primary-constructor parameter that declares a default,
    /// null for the rest. A construction that omits the parameter runs it.
    ctor_defaults: []const ?ir.FuncId = &.{},
};

/// A lambda a register holds: the body to run and the registers captured at
/// the point it was made.
/// A captured value's machine type and, when it is a reference, which class it
/// holds — a captured String is only usable as one if that travels with it.
pub const CapInfo = struct { ty: Ty, cls: ?u32 = null, elem: Ty = .unit };

pub const LambdaInfo = struct {
    body: ir.FuncId,
    captures: []const Reg,
};

pub const Global = struct {
    name: []const u8,
    func: ir.FuncId,
};

/// The default-argument thunks of one function, indexed by the parameter each
/// fills. A thunk takes the parameters ahead of its own, so a default that
/// reads an earlier argument compiles to a call with that argument in hand.
pub const FuncDefaults = struct {
    func: ir.FuncId,
    slots: []const ?ir.FuncId,
};

/// The accepted bodies of one emission, entry last so a body is always
/// declared before the definition that calls it.
pub const Accepted = struct {
    funcs: []Compiled,
    entry: *const Func,
};
