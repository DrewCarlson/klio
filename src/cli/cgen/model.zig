//! Data carried between emitter phases: an accepted function with its register
//! types, the resolved program tables, and the class and global descriptions.
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

/// A function accepted into the scalar core, with each register's machine type.
pub const Compiled = struct {
    f: *const Func,
    /// Captured values, passed as arguments ahead of the body's own parameters.
    caps: []const CapInfo,
    /// Signature this body is compiled against: usually the function's own, but a
    /// synthesized thunk declares none and reads its caller's positionally.
    params: []const ir.Param,
    types: []Ty,
    /// Class an object register holds, to turn a field name into an index.
    cls: []?u32,
    /// Body and captures of a lambda register. A call site that can see the body
    /// calls it directly with the captures as leading arguments, no closure object.
    lam: []?LambdaInfo,
    /// Element machine type of a `List` register; `.unit` means unknown.
    elem: []Ty,
    /// Class held by a container register's elements; null means unknown.
    elem_cls: []?u32,
    /// Frame slot of each object register, or -1 for a scalar in a C local.
    slot: []i32,
    n_slots: u32,
    ret: Ty,
    /// Class and element type of the returned register, taken from what the body
    /// returns because an inferred return type lowers to a placeholder.
    ret_cls: ?u32 = null,
    ret_elem: Ty = .unit,
    /// A `suspend` body: its registers live in a heap frame and it answers either
    /// its result or the SUSPENDED marker.
    suspends: bool = false,
    /// Where each bare name in an inlined receiver body resolved, searched once here.
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
    field: struct { recv: u32, idx: u32 },
    accessor: struct { recv: u32, func: ir.FuncId },
    /// Nothing owned the name: the top-level property it falls back to, by name.
    global,
    /// Bound to a member of implicit receiver `recv`, dispatched on its class.
    member: struct { recv: u32, slot: u32 },
    call: ir.FuncId,
    /// A bare call that names a class: it constructs one.
    construct: u32,
};

/// Everything resolved once about the whole program and asked about repeatedly:
/// class layouts, inheritance links, accessors, throwables, default thunks.
pub const Program = struct {
    fields: []const ?[]const FieldInfo,
    /// Superclass of each laid-out class; initialization walks this chain.
    parents: []const ?Parent = &.{},
    /// Declared body properties, kept so a refusal can name the blocking class.
    layouts: []const ClassLayout = &.{},
    /// Throwable hierarchy, numbered so a catch is an interval test, not a name match.
    throws: ThrowTable = .{ .types = &.{} },
    defaults: []const FuncDefaults = &.{},

    pub fn of(self: Program, cid: u32) ?[]const FieldInfo {
        if (cid >= self.fields.len) return null;
        return self.fields[cid];
    }

    pub fn parentOf(self: Program, cid: u32) ?Parent {
        if (cid >= self.parents.len) return null;
        return self.parents[cid];
    }

    pub fn defaultThunk(self: Program, func: ir.FuncId, idx: usize) ?ir.FuncId {
        for (self.defaults) |d| {
            if (d.func != func) continue;
            if (idx >= d.slots.len) return null;
            return d.slots[idx];
        }
        return null;
    }

    /// Accessor for a property with no storage of its own, inherited like a stored one.
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

/// Superclass link: the class, and one thunk per superclass constructor parameter.
pub const Parent = struct { cid: u32, args: []const ir.FuncId };

pub const FieldInfo = struct {
    name: []const u8,
    ty: Ty,
    cls: ?u32,
    /// What reading THROUGH this field yields: a list's element, a call's result.
    elem: Ty = .unit,
    /// The constructor argument that fills it, or null when a thunk does.
    arg: ?u32,
    init: ?ir.FuncId,
    /// A superclass declares this field, so its initializer, not this class's, fills it.
    from_parent: bool = false,
    /// Filled by the instance's builder, not the class initializer (enum `name`/`ordinal`).
    preset: bool = false,
};

/// Flattened fields plus the superclass link. `complete` is false while a body
/// property's type is unresolved: fields ahead of it are usable, the class is not.
pub const Laid = struct { fields: []FieldInfo, parent: ?Parent, complete: bool = true };

pub const Error = error{ OutOfMemory, WriteFailed, NoSpaceLeft };

/// What a class contributes beyond its constructor: each body-declared property
/// with the thunk computing its initial value. Built from the AST, not the IR.
pub const BodyProp = struct {
    name: []const u8,
    ty: ir.TypeRef,
    init: ?ir.FuncId,
    /// False for a computed `val x get() = ...`, which takes no slot in the layout.
    has_backing: bool = true,
    is_abstract: bool = false,
    is_lateinit: bool = false,
    /// Non-nullable primitive with no initializer: starts at its type's zero.
    zero_init: bool = false,
    /// Reading a computed property calls its getter, writing it calls its setter.
    getter: ?ir.FuncId = null,
    setter: ?ir.FuncId = null,
};

/// One `enum class` entry: its name and a thunk per constructor argument.
pub const EnumEntryInfo = struct {
    name: []const u8,
    args: []const ir.FuncId = &.{},
};

pub const ClassLayout = struct {
    name: []const u8,
    props: []const BodyProp,
    /// One thunk per superclass constructor argument, over this class's own arguments.
    parent_args: []const ir.FuncId = &.{},
    /// Entries in declaration order, which is ordinal order.
    entries: []const EnumEntryInfo = &.{},
    /// `init { … }` blocks as thunks over the instance and constructor arguments, with
    /// the body-property index each runs before: Kotlin interleaves them in source order.
    init_blocks: []const ir.FuncId = &.{},
    init_block_positions: []const usize = &.{},
    /// A `data class` renders and compares by its primary-constructor properties.
    is_data: bool = false,
    /// One thunk per primary-constructor parameter that declares a default, else null.
    ctor_defaults: []const ?ir.FuncId = &.{},
};

/// A captured value's machine type and, for a reference, the class it holds.
pub const CapInfo = struct { ty: Ty, cls: ?u32 = null, elem: Ty = .unit };

pub const LambdaInfo = struct {
    body: ir.FuncId,
    captures: []const Reg,
};

pub const Global = struct {
    name: []const u8,
    func: ir.FuncId,
};

/// Default-argument thunks of one function, indexed by the parameter each fills.
/// A thunk takes the parameters ahead of its own.
pub const FuncDefaults = struct {
    func: ir.FuncId,
    slots: []const ?ir.FuncId,
};

/// Accepted bodies of one emission, entry last so a body precedes its callers.
pub const Accepted = struct {
    funcs: []Compiled,
    entry: *const Func,
};
