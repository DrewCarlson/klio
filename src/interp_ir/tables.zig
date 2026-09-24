//! The table types the VM's program state keys by name: the pair maps, the
//! class table, and the constructor and property records they hold.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");

const Module = ir.Module;
const FuncId = ir.FuncId;
const ClassDef = runtime.ClassDef;
const ObjRef = runtime.ObjRef;

pub const StrPair = struct { a: []const u8, b: []const u8 };

pub const StrPairContext = struct {
    pub fn hash(_: StrPairContext, key: StrPair) u64 {
        return runtime.mixHash(runtime.hashName(key.a), runtime.hashName(key.b));
    }
    pub fn eql(_: StrPairContext, x: StrPair, y: StrPair) bool {
        return runtime.eqlName(x.a, y.a) and runtime.eqlName(x.b, y.b);
    }
};

pub const PairFuncMap = std.HashMap(StrPair, FuncId, StrPairContext, runtime.nameMaxLoadPercentage);
pub const StrPairSet = std.HashMap(StrPair, void, StrPairContext, runtime.nameMaxLoadPercentage);

pub const ClassTable = runtime.NameHashMap(ObjRef(ClassDef));

/// `(supertype simple name, thunk FuncId)` class-delegation entry.
pub const StrFunc = struct { name: []const u8, func: FuncId };

/// JVM static-field default for a top-level property's declared type. Startup runs
/// initializers in file order, so a forward read of a not-yet-initialized annotated property
/// observes this default; `.none` (unannotated, `const`, delegated) drives on demand.
pub const TypedDefault = enum(u8) {
    none,
    int,
    long,
    short,
    byte,
    uint,
    ulong,
    ushort,
    ubyte,
    boolean,
    char,
    float,
    double,
    null_ref,
};
pub const NameFunc = struct { name: []const u8, func: FuncId, default: TypedDefault = .none, file: u32 = 0 };

pub const EnumEntryArgInit = struct {
    class_name: []const u8,
    entry_name: []const u8,
    funcs: []FuncId,
};

pub const EnumEntryMethod = struct {
    module: ObjRef(Module),
    func: FuncId,
};

/// One secondary constructor. `delegation_arg_thunks` evaluate the `: this(...)` /
/// `: super(...)` arguments against the secondary's positional params, and the Vm dispatches
/// the results to the primary ctor.
pub const SecondaryCtorEntry = struct {
    param_count: usize,
    param_names: [][]const u8,
    /// Simple type-name head per parameter, disambiguating same-arity ctor overloads.
    param_type_heads: [][]const u8,
    is_super: bool,
    is_this: bool,
    delegation_arg_thunks: []FuncId,
    default_arg_thunks: []?FuncId,
    /// Optional body block lowered as a 1-arg fn taking `this`.
    body: ?FuncId,
    /// `@Deprecated(level = ERROR|HIDDEN)` / `@LowPriorityInOverloadResolution`: kotlinc
    /// never offers such a constructor to source, so it must not win over an ordinary one.
    low_priority: bool = false,
    /// Index of the `vararg` parameter, which takes any number of trailing arguments.
    vararg_index: ?usize = null,
};

pub const PairStrMap = std.HashMap(StrPair, []const u8, StrPairContext, runtime.nameMaxLoadPercentage);
