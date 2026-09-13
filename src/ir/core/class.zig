const std = @import("std");
const ast = @import("ast");
const runtime = @import("runtime");
const core_func = @import("func.zig");
const core_ids = @import("ids.zig");

const ClassId = core_ids.ClassId;
const FuncId = core_ids.FuncId;
const Param = core_func.Param;
const TypeRef = core_ids.TypeRef;

/// Class declaration.
pub const Class = struct {
    id: ClassId,
    name: []const u8,
    fqn: []const u8,
    /// Declaring package path (`"foo.bar"`), the empty string for a
    /// user script with no package header. Uniform on every class.
    package: []const u8 = "",
    primary_params: []Param,
    methods: []FuncId,
    init_block: ?FuncId,
    companion: ?ClassId,
    supertypes: []ClassId,
    /// Declared class type parameters, in source order. Virtual-slot linking
    /// uses declaration position rather than a simple-name lookup when it
    /// substitutes an inherited generic member signature.
    type_params: []const []const u8 = &.{},
    /// Declaration-site variance parallel to `type_params`.
    type_param_variance: []const ast.Variance = &.{},
    /// Declared supertype references parallel to `supertypes`, retaining their
    /// type arguments. The resolved `ClassId` supplies nominal identity; this
    /// structural half supplies the substitution along each inheritance edge.
    supertype_refs: []TypeRef = &.{},
    /// `inner class` — instances capture an enclosing-class instance.
    /// Construction-site lowering consults this so a lambda building a
    /// bare `Inner()` captures the enclosing `this` it depends on.
    is_inner: bool = false,
    /// `abstract class` / `interface` / `sealed class` — cannot be
    /// constructed directly. A bare `Name(args)` call against such a class
    /// is therefore never construction; it must resolve to a same-named
    /// factory function, so bare-call lowering must not treat it as a ctor.
    is_abstract: bool = false,
    /// `interface` specifically: its member set is exactly its declared
    /// (+ inherited) AST members, so a static-receiver walk can trust the
    /// registry's transitive method-name set for visibility decisions.
    is_interface: bool = false,
    /// A Kotlin `fun interface`. Its classifier call with one callable
    /// argument is a statically known SAM conversion, not a constructor or
    /// same-simple-name global lookup.
    is_fun_interface: bool = false,
    /// `open` modifier — the class can be subclassed. A class that is neither
    /// `open` nor `is_abstract` (which folds in `abstract`/`interface`/`sealed`)
    /// is final: it can never be subclassed, so its members cannot be overridden.
    is_open: bool = false,
    /// An enum class: its entries' bodies may override its `open`/`abstract`
    /// members, so member dispatch stays virtual for those.
    is_enum: bool = false,
    /// Whether the declaration has a primary constructor; a class without one
    /// that declares secondary constructors has no implicit zero-argument
    /// constructor.
    has_primary_ctor: bool = true,
    /// An `annotation class`: instances compare, hash, and render by value.
    is_annotation: bool = false,
    /// A named Kotlin `object`. Calling its classifier name resolves the
    /// singleton value and dispatches `operator fun invoke`; it is never a
    /// constructor call despite sharing the class table representation.
    is_object: bool = false,
    /// A Kotlin value class. Its receiver uses a specialized runtime
    /// representation, so ordinary instance-call ABI assumptions do not apply.
    is_value: bool = false,
    /// Runtime representation of values observed through this classifier.
    /// Only `instance` classifiers can use the numeric virtual-call ABI.
    receiver_abi: runtime.ReceiverAbi = .instance,
    /// True only for an as-yet-unfilled `reserveClass` placeholder. A real
    /// class is registered with `methods`/`supertypes`/`init_block` not yet
    /// backpatched, so it is structurally indistinguishable from a stub;
    /// this flag lets `addClass` tell a reserved slot (which the real
    /// declaration overwrites in place) from a genuine same-simple-name
    /// twin in another package (which must keep its own id).
    is_stub: bool = false,
};

/// `class_index` / `func_index` entry: simple name → id.
pub const ClassIndexEntry = struct { name: []const u8, id: ClassId };

pub const FuncIndexEntry = struct { name: []const u8, id: FuncId };

/// `(String, String)` pair key used by several `ModuleRegistry`
/// tables. Hashed/compared structurally.
pub const StrPair = struct {
    a: []const u8,
    b: []const u8,
};

pub const StrPairContext = struct {
    pub fn hash(_: StrPairContext, key: StrPair) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(key.a);
        h.update(&.{0});
        h.update(key.b);
        return h.final();
    }
    pub fn eql(_: StrPairContext, x: StrPair, y: StrPair) bool {
        return std.mem.eql(u8, x.a, y.a) and std.mem.eql(u8, x.b, y.b);
    }
};

pub fn StrPairMap(comptime V: type) type {
    return std.HashMap(StrPair, V, StrPairContext, std.hash_map.default_max_load_percentage);
}

pub const StrPairSet = StrPairMap(void);

pub const FuncIdMap = std.AutoHashMap;

pub fn headAllUpper(s_: []const u8) bool {
    for (s_) |c| {
        if (!std.ascii.isUpper(c)) return false;
    }
    return true;
}
