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
};

pub const ClassIndexEntry = struct { name: []const u8, id: ClassId };

pub const FuncIndexEntry = struct { name: []const u8, id: FuncId };

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
