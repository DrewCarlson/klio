const std = @import("std");
const ast = @import("ast");
const runtime = @import("runtime");
const core_func = @import("func.zig");
const core_ids = @import("ids.zig");

const ClassId = core_ids.ClassId;
const FuncId = core_ids.FuncId;
const Param = core_func.Param;
const TypeRef = core_ids.TypeRef;

pub const Class = struct {
    id: ClassId,
    name: []const u8,
    fqn: []const u8,
    /// Declaring package path; empty for a script with no package header.
    package: []const u8 = "",
    primary_params: []Param,
    methods: []FuncId,
    init_block: ?FuncId,
    companion: ?ClassId,
    supertypes: []ClassId,
    /// Type parameters in source order; inherited generic signatures substitute by position.
    type_params: []const []const u8 = &.{},
    /// Declaration-site variance parallel to `type_params`.
    type_param_variance: []const ast.Variance = &.{},
    /// Parallel to `supertypes`, retaining type arguments: the `ClassId` gives
    /// nominal identity, this gives the substitution along each inheritance edge.
    supertype_refs: []TypeRef = &.{},
    is_inner: bool = false,
    /// `abstract`, `interface`, or `sealed`: cannot be constructed directly, so a
    /// bare `Name(args)` against it resolves to a same-named factory, never a ctor.
    is_abstract: bool = false,
    /// `interface` specifically; `is_abstract` also covers abstract and sealed.
    is_interface: bool = false,
    /// A `fun interface`: a classifier call with one callable argument is a SAM conversion.
    is_fun_interface: bool = false,
    /// `open`: the class can be subclassed. Neither `open` nor `is_abstract` means
    /// final, so its members can never be overridden.
    is_open: bool = false,
    is_enum: bool = false,
    /// A class with no primary constructor gets no implicit zero-argument constructor.
    has_primary_ctor: bool = true,
    /// An `annotation class`: instances compare, hash, and render by value.
    is_annotation: bool = false,
    /// A named `object`: a classifier call dispatches `operator fun invoke` on the
    /// singleton; it is never a constructor call.
    is_object: bool = false,
    is_value: bool = false,
    /// Only `instance` classifiers can use the numeric virtual-call ABI.
    receiver_abi: runtime.ReceiverAbi = .instance,
    /// True only for an unfilled `reserveClass` placeholder: the real declaration
    /// overwrites it in place, while a same-name class elsewhere gets its own id.
    is_stub: bool = false,
    /// Construction routes through a host intrinsic rather than the
    /// interpreted constructor. A property of the class, answered once at link
    /// time: the runtime used to ask it by scanning a thirty-entry name table
    /// on every construction, for every class, intrinsic or not.
    is_intrinsic_backed: bool = false,
    /// How many secondary constructors the class declares. Answered once at
    /// link time: the runtime asked whether there were ANY by building a
    /// side-table key from the FQN and probing a name-keyed map, on every
    /// construction of every class, and the answer is zero for most. The count
    /// rather than a flag, because a class with no primary and one secondary
    /// also offers a construction no choice.
    secondary_ctor_count: u16 = 0,
    /// Entry names in declaration order, so `EnumClass.Entry` is an index at
    /// lowering rather than a scan of the entry table per read. Empty for
    /// anything that is not an enum. Filled at link time beside the layouts.
    enum_entry_names: []const []const u8 = &.{},
    /// One entry per secondary constructor, in declaration order: the argument
    /// counts it accepts. Recorded where the class is lowered, beside
    /// `declared_props`, because nothing downstream carries a secondary
    /// constructor's signature.
    secondary_ctor_arities: []const CtorArity = &.{},
    /// The primary constructor's signature, recorded from the class's own AST
    /// rather than derived from `primary_params`, so every constructor of the
    /// class spells its parameter heads the same way.
    primary_ctor_sig: ?CtorArity = null,
    /// Every property this class's body declares, in source order. Recorded
    /// where the class is lowered because that is the only point the AST is in
    /// hand: a layout holds no slot for an accessor-only property, and the
    /// `__get_<Class>_<prop>` contract holds no function for an abstract one,
    /// so neither proxy can reconstruct the declaration set afterwards.
    declared_props: []const DeclaredProp = &.{},
    /// What this class contributes to its instances' field layout. Composed into
    /// `Module.field_layout` by `linkFieldSlots`.
    field_layout: FieldLayout = .{},

    /// The argument counts this class's PRIMARY constructor accepts, or null
    /// when it declares none.
    pub fn primaryArity(self: *const Class) ?CtorArity {
        // `has_primary_ctor` records whether the header spelled a parameter
        // list. A class that spelled none still has the no-argument
        // constructor Kotlin gives it, unless a secondary replaces it.
        if (!self.has_primary_ctor) {
            if (self.secondary_ctor_count != 0) return null;
            return .{ .required = 0, .total = 0 };
        }
        if (self.primary_ctor_sig) |sig| return sig;
        var required: u16 = 0;
        var vararg = false;
        for (self.primary_params) |p| {
            if (p.is_vararg) {
                vararg = true;
                continue;
            }
            if (!p.has_default) required += 1;
        }
        return .{
            .required = required,
            .total = @intCast(self.primary_params.len),
            .vararg = vararg,
        };
    }

    /// This class's constructors, numbered the way a pick numbers them: 0 is
    /// the primary, 1 + i the i'th secondary. Null where the slot holds no
    /// constructor, which is slot 0 of a class that declares no primary.
    pub fn ctorSig(self: *const Class, index: u16) ?CtorArity {
        if (index == 0) return self.primaryArity();
        const i = index - 1;
        if (i >= self.secondary_ctor_arities.len) return null;
        return self.secondary_ctor_arities[i];
    }

    /// One past the highest constructor index this class offers.
    pub fn ctorSlotCount(self: *const Class) u16 {
        return 1 + @as(u16, @intCast(self.secondary_ctor_arities.len));
    }

    /// Whether a construction of this class has exactly one constructor to
    /// reach, so naming the class names the target.
    pub fn hasSoleCtor(self: *const Class) bool {
        const secondaries: u32 = self.secondary_ctor_count;
        const primaries: u32 = if (self.has_primary_ctor or secondaries == 0) 1 else 0;
        return primaries + secondaries == 1;
    }

    /// The index of `name` among this class's entries, or null.
    pub fn enumEntryIndex(self: *const Class, name: []const u8) ?u32 {
        for (self.enum_entry_names, 0..) |e, i| {
            if (std.mem.eql(u8, e, name)) return @intCast(i);
        }
        return null;
    }
};

/// One constructor's static signature, as constructor selection at lowering
/// reads it.
pub const CtorArity = struct {
    /// Parameters with no default and no `vararg`: the fewest arguments.
    required: u16,
    /// Every declared parameter: the most, unless `vararg` lifts the cap.
    total: u16,
    vararg: bool = false,
    /// `@Deprecated(level = ERROR|HIDDEN)` / `@LowPriorityInOverloadResolution`:
    /// never offered to source, so it cannot take a call an ordinary
    /// constructor accepts.
    low_priority: bool = false,
    /// Declared type head per parameter, in declaration order, spelled the way
    /// the runtime's constructor entry spells it so a pick made here and the
    /// value scoring compare the same strings.
    param_heads: []const []const u8 = &.{},
    /// Parameter names, for a call that passes arguments by name.
    param_names: []const []const u8 = &.{},
    /// Parallel to the parameters: whether each declares a default.
    param_defaults: []const bool = &.{},

    pub fn accepts(self: CtorArity, n: u16) bool {
        if (n < self.required) return false;
        return self.vararg or n <= self.total;
    }
};

/// One property a class's body declares, as the property-slot linker reads it.
pub const DeclaredProp = struct {
    name: []const u8,
    /// An accessor answers a read; otherwise the class's cell does.
    has_getter: bool = false,
    /// Declared with no accessor body, no initializer and no delegate: the
    /// class NAMES the property without answering it, which is what makes its
    /// declaration a slot root rather than an implementation.
    is_abstract: bool = false,
};

/// The value a field slot holds until an initializer fills it: the JVM zero of a
/// declared non-nullable primitive, `null_ref` for everything else. Kotlin has no
/// other seed — a declared primitive reads as its zero, a reference as null — so
/// the kind alone reconstructs the value.
pub const SlotSeed = enum(u8) {
    null_ref,
    int,
    long,
    short,
    byte,
    float,
    double,
    boolean,
    char,
};

/// One slot of a class's field layout: the registry key construction stores
/// under — owner-mangled where the class privately shadows or override-cells a
/// supertype's same-named property, else the plain name — and its seed.
pub const FieldSlot = struct {
    name: []const u8,
    seed: SlotSeed = .null_ref,
    /// A plain stored property: no accessor, no delegate. Only a plain slot's
    /// value answers a read; a property with a getter has a backing slot too,
    /// and reading it must run the getter.
    plain: bool = false,
    /// A primary-constructor property, written before any user code runs. A
    /// body property's slot can be read while it still holds its seed.
    ctor: bool = false,
    /// A plain stored WRITE: no custom setter, so storing the value is the
    /// whole operation. Separate from `plain`, which is about reads — a
    /// property can read straight from its slot while its setter runs code,
    /// and a write claim that ignored that stored the raw value past it.
    plain_write: bool = false,
    /// Declared type head of the property this slot holds, empty where the
    /// declaration left the type to inference. What a chained field read needs
    /// to name its own receiver.
    type_head: []const u8 = "",
};

/// Whether a class has a layout, and if not, why.
pub const FieldLayoutState = enum(u8) {
    /// No build has written this class's layout. A class slot claimed by a later
    /// build's same-FQN declaration resets to this, which is how the linker knows
    /// its inherited table entry is stale.
    unpublished,
    /// The build could not describe this class; the runtime walks the class
    /// declaration instead. Distinct from `unpublished`: the build did look.
    unavailable,
    /// `own` holds the slots this class adds to its superclass's layout.
    ok,
    /// An interface holds no storage.
    interface,
    /// An object expression's class, whose fields are built in a different order.
    anonymous,
    /// Declared inside a function body and registered at execution, so its layout
    /// cannot be baked.
    local_runtime,
};

/// What a class adds to its superclass's field layout.
///
/// A DECLARED slot's index is the same in this class and in every subclass:
/// `own[i]` lives at index `base + i` wherever the class appears in a chain,
/// which is the whole point of publishing the table — a base class's slot index
/// can be burned into a field read that a subclass instance also answers.
///
/// A CAPTURE does not have that property. Kotlin gives a plain primary-constructor
/// parameter that a member body reads a synthesized field, but whether one exists
/// depends on the whole chain: a subclass property of the same name claims the
/// name and the parameter keeps none. So captures cannot sit inside a level's own
/// slots; the linker appends them, base classes first, AFTER every declared slot
/// in the chain. `captures` names the parameters that are candidates here — those
/// this class's own body declares no property for — and the composition drops the
/// ones some class in the chain claims.
pub const FieldLayout = struct {
    /// Slots this class adds beyond its superclass's layout, in order.
    own: []const FieldSlot = &.{},
    /// Plain primary-constructor parameters that may become capture slots.
    captures: []const []const u8 = &.{},
    /// How many declared slots the superclass layout holds, so `own[i]` is at
    /// layout index `base + i`. Filled by `linkFieldSlots`.
    base: u32 = 0,
    /// The superclass whose layout this one extends; null at a chain root.
    super: ?ClassId = null,
    state: FieldLayoutState = .unpublished,
};

