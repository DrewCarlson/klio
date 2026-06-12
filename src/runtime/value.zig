//! The runtime `Value` model: the tagged union every interpreter and
//! stdlib path evaluates against, its helper enums/structs, and the
//! `RuntimeError` data type.
//!
//! Reference handles: Rust `Arc<T>` / `ObjRef<T>` both map to
//! `ObjRef(T)` (the refcounted, interior-mutable, lock-mediated cell).
//! Rust `Box<Value>` maps to `*Value`. Shared-immutable AST nodes
//! (`Arc<klio_ast::Function>` etc.) map to `*const ast.X` pointers, owned
//! by the parse/lower arena.

const std = @import("std");
const ast = @import("ast");
const objcell = @import("objcell.zig");
const float_fmt = @import("float_fmt.zig");
const class_mod = @import("class.zig");
const env_mod = @import("env.zig");

const ObjRef = objcell.ObjRef;
const ClassDef = class_mod.ClassDef;
const InstanceData = class_mod.InstanceData;
const MethodDef = class_mod.MethodDef;
const Env = env_mod.Env;

const StdlibFn = @import("host.zig").StdlibFn;

/// `Arc<String>` — a shared, refcounted, immutable string.
pub const StringRef = ObjRef([]const u8);
/// `ObjRef<Vec<Value>>` — shared, growable element storage.
pub const ValueList = ObjRef(std.ArrayList(Value));
/// `Arc<Vec<Value>>` — shared, frozen element storage.
pub const ValueSlice = ObjRef([]Value);
/// One key/value pair inside a `Map`.
pub const MapPair = struct { key: Value, value: Value };
/// `ObjRef<Vec<(Value, Value)>>` — shared, growable map entry storage.
pub const MapEntries = ObjRef(std.ArrayList(MapPair));

/// Which face of a `MutableMap` a live view exposes.
pub const MapViewKind = enum { Keys, Values, Entries };

/// Back-reference carried by a live `MutableMap.keys`/`.values`/`.entries`
/// collection so its mutators edit the originating map.
pub const MapBacking = struct {
    entries: MapEntries,
    kind: MapViewKind,
};

/// Distinguishes integer ranges (`IntRange`) from long/char ranges.
pub const RangeKind = enum {
    Int,
    Long,
    Char,

    pub const default: RangeKind = .Int;
};

/// Numeric promotion rank — wider types win in mixed arithmetic.
pub const NumericRank = enum(u8) {
    Byte = 0,
    Short = 1,
    Int = 2,
    Long = 3,
    UByte = 4,
    UShort = 5,
    UInt = 6,
    ULong = 7,
    Float = 8,
    Double = 9,
};

/// Identifies the typed Kotlin primitive-array variants.
pub const PrimitiveArrayKind = enum {
    Int,
    Long,
    Double,
    Float,
    Short,
    Byte,
    Boolean,
    Char,
    UInt,
    ULong,
    UShort,
    UByte,

    pub fn typeFqn(self: PrimitiveArrayKind) []const u8 {
        return switch (self) {
            .Int => "kotlin.IntArray",
            .Long => "kotlin.LongArray",
            .Double => "kotlin.DoubleArray",
            .Float => "kotlin.FloatArray",
            .Short => "kotlin.ShortArray",
            .Byte => "kotlin.ByteArray",
            .Boolean => "kotlin.BooleanArray",
            .Char => "kotlin.CharArray",
            .UInt => "kotlin.UIntArray",
            .ULong => "kotlin.ULongArray",
            .UShort => "kotlin.UShortArray",
            .UByte => "kotlin.UByteArray",
        };
    }

    pub fn simpleName(self: PrimitiveArrayKind) []const u8 {
        return switch (self) {
            .Int => "Int",
            .Long => "Long",
            .Double => "Double",
            .Float => "Float",
            .Short => "Short",
            .Byte => "Byte",
            .Boolean => "Boolean",
            .Char => "Char",
            .UInt => "UInt",
            .ULong => "ULong",
            .UShort => "UShort",
            .UByte => "UByte",
        };
    }
};

/// Built-in property delegates (`lazy`, `Delegates.observable`,
/// `Delegates.notNull`).
pub const DelegateKind = union(enum) {
    /// `lazy { producer }`.
    Lazy: struct { producer: Value, cached: ?Value },
    /// `Delegates.observable(initial) { property, old, new -> … }`.
    Observable: struct { value: Value, on_change: Value },
    /// `Delegates.notNull<T>()`.
    NotNull: struct { value: ?Value, name: []const u8 },
};

/// State-machine representation of a `suspend fun` body.
pub const SuspendBody = struct {
    states: []SuspendState,
};

/// One "basic block" in a suspend state machine.
pub const SuspendState = struct {
    /// Optional local to bind the resumed value to before the stmts run.
    resume_target: ?[]const u8,
    /// Statements to execute in order.
    stmts: []ast.Stmt,
    /// What to do after the last stmt finishes.
    transition: SuspendTransition,
};

pub const SuspendTransition = union(enum) {
    /// Move to the named state.
    Goto: usize,
    /// Function returns.
    Return,
    /// Branch on a boolean register: jump to `then_state` if true.
    Branch: struct { then_state: usize, else_state: usize },
};

/// Result of a previously-suspended `suspendCoroutine` call.
pub const PausedResume = union(enum) {
    Resumed: Value,
    Failed: Value,
};

/// Where a finished suspend frame hands its result.
pub const SuspendCallerCont = union(enum) {
    Frame: ObjRef(SuspendFrame),
    HostSlot: ObjRef(?HostSlotResult),
};

/// `Result<Value, Value>` payload delivered to a `runBlocking` host slot.
pub const HostSlotResult = union(enum) {
    ok: Value,
    err: Value,
};

/// A live `suspend fun` invocation.
pub const SuspendFrame = struct {
    decl: *const ast.Function,
    body: ObjRef(SuspendBody),
    env: ObjRef(Env),
    /// Locals introduced by val/var statements in earlier states.
    locals: std.ArrayList(Local),
    /// Index into `body.states` for the next state to run.
    state: usize,
    /// The caller's continuation chain, when this frame is active.
    caller: ?SuspendCallerCont,
    /// Result of a paused async `suspendCoroutine`, read on re-entry.
    paused_resume: ?PausedResume,

    pub const Local = struct { name: []const u8, value: Value };
};

pub const SequenceData = struct {
    source: SequenceSource,
    ops: []SeqOp,
};

pub const SequenceSource = union(enum) {
    /// Eager-known elements (`asSequence` / `sequenceOf`).
    Items: ValueSlice,
    /// `generateSequence(seed) { it -> next }`. `seed` is null for the
    /// nullary form.
    Generate: struct { seed: ?*Value, next: *Value },
};

pub const SeqOp = union(enum) {
    Map: Value,
    Filter: Value,
    FilterNot: Value,
    /// `onEach { }` — run the lambda for its side effect, pass through.
    OnEach: Value,
    /// `mapIndexed { index, value -> }`.
    MapIndexed: Value,
    /// `filterIndexed { index, value -> }`.
    FilterIndexed: Value,
    Take: i64,
    Drop: i64,
    TakeWhile: Value,
    DropWhile: Value,
    FlatMap: Value,
    Distinct,
    DistinctBy: Value,
    /// Sort in natural order; `descending` flips the comparison.
    Sorted: bool,
    /// Sort by a key-selector lambda; the bool flips the comparison.
    SortedBy: struct { selector: Value, descending: bool },
    /// Sort with a user-supplied `Value::Comparator`.
    SortedWith: Value,
};

/// Compiled regex + the original pattern source. The compiled engine is
/// not in the Zig std; `engine` is an opaque host-provided handle.
pub const RegexData = struct {
    pattern: StringRef,
    /// Opaque compiled-regex handle owned by the host regex binding.
    engine: ?*anyopaque,
};

pub const MatchGroupData = struct {
    value: StringRef,
    start: i64,
    end_inclusive: i64,
};

/// A single regex match outcome — full match plus capture groups, with
/// enough state to resume scanning via `MatchResult.next()`.
pub const MatchData = struct {
    input: StringRef,
    /// Index 0 is the whole match; later indices are capture groups.
    /// `null` means a group did not participate.
    groups: []?MatchGroupData,
    /// Byte offset in `input` immediately after the matched span.
    end_byte: usize,
    regex: ObjRef(RegexData),
};

/// The runtime value: a tagged union over every Kotlin value the
/// interpreter manipulates.
pub const Value = union(enum) {
    Unit,
    /// The `COROUTINE_SUSPENDED` singleton.
    CoroutineSuspended,
    Int: i32,
    Long: i64,
    Short: i16,
    Byte: i8,
    UInt: u32,
    ULong: u64,
    UShort: u16,
    UByte: u8,
    Double: f64,
    /// Kotlin `Float`, stored as `f32`.
    Float: f32,
    Bool: bool,
    String: StringRef,
    /// Kotlin `Char` is a single UTF-16 code unit (may be a lone surrogate).
    Char: u16,
    Null,
    /// Inclusive integer progression with a signed step.
    Range: struct {
        start: i64,
        end: i64,
        step: i64,
        kind: RangeKind,
    },
    Function: struct {
        decl: *const ast.Function,
        env: ObjRef(Env),
    },
    Intrinsic: struct {
        fqn: []const u8,
        func: StdlibFn,
    },
    /// IR-side closure handle.
    IrClosure: struct {
        id: u64,
        captures: ValueSlice,
    },
    /// A method intrinsic bound to a specific receiver.
    BoundMethod: struct {
        fqn: []const u8,
        func: StdlibFn,
        receiver: *Value,
    },
    /// A user-method reference bound to a specific instance.
    BoundUserMethod: struct {
        receiver: ObjRef(InstanceData),
        method: *const MethodDef,
    },
    /// A thrown value, modeled as a Kotlin Throwable.
    Exception: struct {
        fqn: StringRef,
        message: ?StringRef,
        cause: ?*Value,
    },
    /// `kotlin.collections.List` / `MutableList`.
    List: struct {
        items: ValueList,
        mutable: bool,
        /// `Some(name)` for `EnumName.entries` / `.values()`.
        enum_class: ?StringRef,
        /// Set when this is a live `MutableMap.values` view.
        backing: ?*MapBacking,
    },
    /// `kotlin.Array<T>` and primitive-array siblings.
    Array: struct {
        items: ValueList,
        prim: ?PrimitiveArrayKind,
    },
    /// `kotlin.collections.Set` / `MutableSet`.
    Set: struct {
        items: ValueList,
        mutable: bool,
        /// Set when this is a live `MutableMap.keys`/`.entries` view.
        backing: ?*MapBacking,
    },
    /// `kotlin.collections.Map` / `MutableMap`.
    Map: struct {
        entries: MapEntries,
        mutable: bool,
    },
    /// `kotlin.Pair`.
    Pair: struct { first: *Value, second: *Value },
    /// `kotlin.Triple`.
    Triple: struct { first: *Value, second: *Value, third: *Value },
    /// `kotlin.collections.Map.Entry`.
    MapEntry: struct {
        key: *Value,
        value: *Value,
        /// When set, the live map's entries: `setValue` writes through.
        backing: ?MapEntries,
    },
    /// `kotlin.Result<T>`.
    Result: struct {
        ok: bool,
        payload: *Value,
    },
    /// `kotlin.Comparator<T>`.
    Comparator: struct {
        steps: ObjRef([]ComparatorStep),
        descending: bool,
    },
    /// A user-declared class.
    Class: ObjRef(ClassDef),
    /// An `inner class` bound to a specific outer-instance.
    BoundInnerClass: struct {
        class: ObjRef(ClassDef),
        outer: ObjRef(InstanceData),
    },
    /// A live instance of a user-declared class.
    Instance: ObjRef(InstanceData),
    /// `kotlin.sequences.Sequence<T>`.
    Sequence: ObjRef(SequenceData),
    /// `kotlin.collections.Iterator<T>` and primitive specializations.
    Iterator: struct {
        items: ValueList,
        pos: ObjRef(usize),
        prim: ?PrimitiveArrayKind,
    },
    /// Lazy O(1)-memory iterator over a `Range`/progression.
    RangeIter: struct {
        cur: ObjRef(i64),
        end: i64,
        step: i64,
        kind: RangeKind,
    },
    /// A built-in property delegate.
    Delegate: ObjRef(DelegateKind),
    /// `::foo` — a lightweight property/function reference.
    PropertyRef: struct {
        name: StringRef,
    },
    /// `kotlin.text.Regex`.
    Regex: ObjRef(RegexData),
    /// `kotlin.text.MatchResult`.
    Match: ObjRef(MatchData),
    /// `kotlin.text.MatchGroup`.
    MatchGroup: struct {
        value: StringRef,
        start: i64,
        end_inclusive: i64,
    },
    /// `kotlin.text.StringBuilder` — mutable string buffer.
    StringBuilder: ObjRef(std.ArrayList(u8)),
    /// Boxed local `var` captured by a closure (`Ref.ObjectRef`).
    Cell: ObjRef(Value),

    /// Wrap a value in a fresh capture cell.
    pub fn newCell(allocator: std.mem.Allocator, v: Value) !Value {
        return .{ .Cell = try ObjRef(Value).init(allocator, v) };
    }

    /// Heap-box a `Value` so it can fill a `*Value` payload slot
    /// (`Box::new(v)` -> `*Value`).
    pub fn box(allocator: std.mem.Allocator, v: Value) std.mem.Allocator.Error!*Value {
        const p = try allocator.create(Value);
        p.* = v;
        return p;
    }

    pub fn isIntegral(self: Value) bool {
        return switch (self) {
            .Int, .Long, .Short, .Byte, .UInt, .ULong, .UShort, .UByte => true,
            else => false,
        };
    }

    pub fn isUnsigned(self: Value) bool {
        return switch (self) {
            .UInt, .ULong, .UShort, .UByte => true,
            else => false,
        };
    }

    pub fn isFloating(self: Value) bool {
        return switch (self) {
            .Double, .Float => true,
            else => false,
        };
    }

    pub fn isNumeric(self: Value) bool {
        return self.isIntegral() or self.isFloating();
    }

    /// Widen any integral variant to `i64`. Floating returns null.
    pub fn asI64(self: Value) ?i64 {
        return switch (self) {
            .Int => |v| @as(i64, v),
            .Long => |v| v,
            .Short => |v| @as(i64, v),
            .Byte => |v| @as(i64, v),
            .UInt => |v| @as(i64, v),
            .ULong => |v| @bitCast(v),
            .UShort => |v| @as(i64, v),
            .UByte => |v| @as(i64, v),
            else => null,
        };
    }

    /// Widen any integral variant to `u64`. Negative signed values wrap.
    pub fn asU64(self: Value) ?u64 {
        return switch (self) {
            .Int => |v| @bitCast(@as(i64, v)),
            .Long => |v| @bitCast(v),
            .Short => |v| @bitCast(@as(i64, v)),
            .Byte => |v| @bitCast(@as(i64, v)),
            .UInt => |v| @as(u64, v),
            .ULong => |v| v,
            .UShort => |v| @as(u64, v),
            .UByte => |v| @as(u64, v),
            else => null,
        };
    }

    /// Widen any numeric variant to `f64`.
    pub fn asF64(self: Value) ?f64 {
        return switch (self) {
            .Int => |v| @floatFromInt(v),
            .Long => |v| @floatFromInt(v),
            .Short => |v| @floatFromInt(v),
            .Byte => |v| @floatFromInt(v),
            .UInt => |v| @floatFromInt(v),
            .ULong => |v| @floatFromInt(v),
            .UShort => |v| @floatFromInt(v),
            .UByte => |v| @floatFromInt(v),
            .Double => |v| v,
            .Float => |v| @as(f64, v),
            else => null,
        };
    }

    /// Widen any numeric variant to `f32`.
    pub fn asF32(self: Value) ?f32 {
        return switch (self) {
            .Int => |v| @floatFromInt(v),
            .Long => |v| @floatFromInt(v),
            .Short => |v| @floatFromInt(v),
            .Byte => |v| @floatFromInt(v),
            .UInt => |v| @floatFromInt(v),
            .ULong => |v| @floatFromInt(v),
            .UShort => |v| @floatFromInt(v),
            .UByte => |v| @floatFromInt(v),
            .Double => |v| @floatCast(v),
            .Float => |v| v,
            else => null,
        };
    }

    /// Construct an `Int`, wrapping to 32-bit width.
    pub fn newInt(v: i64) Value {
        return .{ .Int = @truncate(v) };
    }

    pub fn newLong(v: i64) Value {
        return .{ .Long = v };
    }

    pub fn newShort(v: i64) Value {
        return .{ .Short = @truncate(v) };
    }

    pub fn newByte(v: i64) Value {
        return .{ .Byte = @truncate(v) };
    }

    /// Promotion rank used to determine a mixed-numeric result type.
    pub fn numericRank(self: Value) ?NumericRank {
        return switch (self) {
            .Byte => .Byte,
            .Short => .Short,
            .Int => .Int,
            .Long => .Long,
            .UByte => .UByte,
            .UShort => .UShort,
            .UInt => .UInt,
            .ULong => .ULong,
            .Float => .Float,
            .Double => .Double,
            else => null,
        };
    }

    /// Convert this numeric value to the variant matching `rank`.
    pub fn promoteTo(self: Value, rank: NumericRank) ?Value {
        return switch (rank) {
            .Byte => if (self.asI64()) |v| Value{ .Byte = @truncate(v) } else null,
            .Short => if (self.asI64()) |v| Value{ .Short = @truncate(v) } else null,
            .Int => if (self.asI64()) |v| Value{ .Int = @truncate(v) } else null,
            .Long => if (self.asI64()) |v| Value{ .Long = v } else null,
            .UByte => if (self.asU64()) |v| Value{ .UByte = @truncate(v) } else null,
            .UShort => if (self.asU64()) |v| Value{ .UShort = @truncate(v) } else null,
            .UInt => if (self.asU64()) |v| Value{ .UInt = @truncate(v) } else null,
            .ULong => if (self.asU64()) |v| Value{ .ULong = v } else null,
            .Float => if (self.asF32()) |v| Value{ .Float = v } else null,
            .Double => if (self.asF64()) |v| Value{ .Double = v } else null,
        };
    }

    /// Truncate an `i64` arithmetic result back to the storage range of the
    /// requested integer rank. Long is returned as-is.
    pub fn wrapInteger(rank: NumericRank, v: i64) Value {
        return switch (rank) {
            .Byte => .{ .Byte = @truncate(v) },
            .Short => .{ .Short = @truncate(v) },
            .Int => .{ .Int = @truncate(v) },
            .Long => .{ .Long = v },
            .UByte => .{ .UByte = @truncate(@as(u64, @bitCast(v))) },
            .UShort => .{ .UShort = @truncate(@as(u64, @bitCast(v))) },
            .UInt => .{ .UInt = @truncate(@as(u64, @bitCast(v))) },
            .ULong => .{ .ULong = @bitCast(v) },
            else => .{ .Long = v },
        };
    }

    /// Wrap a `u64` arithmetic result into the unsigned variant for `rank`.
    pub fn wrapUnsigned(rank: NumericRank, v: u64) Value {
        return switch (rank) {
            .UByte => .{ .UByte = @truncate(v) },
            .UShort => .{ .UShort = @truncate(v) },
            .UInt => .{ .UInt = @truncate(v) },
            .ULong => .{ .ULong = v },
            else => .{ .ULong = v },
        };
    }

    /// Fully-qualified Kotlin type name, used as the key prefix for member
    /// lookups in the stdlib registry.
    pub fn typeFqn(self: Value) []const u8 {
        return switch (self) {
            .Cell => "kotlin.Any",
            .Unit => "kotlin.Unit",
            .CoroutineSuspended => "kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED",
            .Int => "kotlin.Int",
            .Long => "kotlin.Long",
            .Short => "kotlin.Short",
            .Byte => "kotlin.Byte",
            .UInt => "kotlin.UInt",
            .ULong => "kotlin.ULong",
            .UShort => "kotlin.UShort",
            .UByte => "kotlin.UByte",
            .Double => "kotlin.Double",
            .Float => "kotlin.Float",
            .Bool => "kotlin.Boolean",
            .String => "kotlin.String",
            .Char => "kotlin.Char",
            .Null => "kotlin.Nothing",
            .Range => |r| switch (r.kind) {
                .Int => if (r.step == 1) "kotlin.ranges.IntRange" else "kotlin.ranges.IntProgression",
                .Long => if (r.step == 1) "kotlin.ranges.LongRange" else "kotlin.ranges.LongProgression",
                .Char => if (r.step == 1) "kotlin.ranges.CharRange" else "kotlin.ranges.CharProgression",
            },
            .Function, .IrClosure, .Intrinsic, .BoundMethod, .BoundUserMethod => "kotlin.Function",
            .Exception => "kotlin.Throwable",
            .List => |l| if (l.mutable) "kotlin.collections.MutableList" else "kotlin.collections.List",
            .Array => |a| if (a.prim) |k| k.typeFqn() else "kotlin.Array",
            .Set => |s| if (s.mutable) "kotlin.collections.MutableSet" else "kotlin.collections.Set",
            .Map => |m| if (m.mutable) "kotlin.collections.MutableMap" else "kotlin.collections.Map",
            .Pair => "kotlin.Pair",
            .Triple => "kotlin.Triple",
            .MapEntry => "kotlin.collections.Map.Entry",
            .Result => "kotlin.Result",
            .Comparator => "kotlin.Comparator",
            .Sequence => "kotlin.sequences.Sequence",
            .Iterator => |it| if (it.prim) |p| switch (p) {
                .Int => "kotlin.collections.IntIterator",
                .Long => "kotlin.collections.LongIterator",
                .Double => "kotlin.collections.DoubleIterator",
                .Float => "kotlin.collections.FloatIterator",
                .Short => "kotlin.collections.ShortIterator",
                .Byte => "kotlin.collections.ByteIterator",
                .Boolean => "kotlin.collections.BooleanIterator",
                .Char => "kotlin.collections.CharIterator",
                .UInt => "kotlin.collections.UIntIterator",
                .ULong => "kotlin.collections.ULongIterator",
                .UShort => "kotlin.collections.UShortIterator",
                .UByte => "kotlin.collections.UByteIterator",
            } else "kotlin.collections.Iterator",
            .RangeIter => |ri| switch (ri.kind) {
                .Int => "kotlin.collections.IntIterator",
                .Long => "kotlin.collections.LongIterator",
                .Char => "kotlin.collections.CharIterator",
            },
            .Class, .BoundInnerClass => "kotlin.reflect.KClass",
            .Instance => "<instance>",
            .Delegate => "<delegate>",
            .PropertyRef => "kotlin.reflect.KProperty",
            .Regex => "kotlin.text.Regex",
            .Match => "kotlin.text.MatchResult",
            .MatchGroup => "kotlin.text.MatchGroup",
            .StringBuilder => "kotlin.text.StringBuilder",
        };
    }

    /// Render a `Double` the way Kotlin's `Double.toString` does. Caller
    /// owns the returned string.
    pub fn renderDouble(allocator: std.mem.Allocator, d: f64) ![]u8 {
        return float_fmt.kotlinDoubleToString(allocator, d);
    }

    /// Live exception fqn — for catch-clause matching by type name.
    pub fn exceptionFqn(self: Value) ?[]const u8 {
        return switch (self) {
            .Exception => |e| {
                const g = e.fqn.borrow();
                defer g.deinit();
                return g.get().*;
            },
            else => null,
        };
    }

    /// Runtime `is` check against a simple type name.
    pub fn isRuntimeType(self: Value, name: []const u8) bool {
        return switch (self) {
            .Cell => |c| blk: {
                const g = c.borrow();
                defer g.deinit();
                break :blk g.get().isRuntimeType(name);
            },
            .CoroutineSuspended => false,
            .Int => matchesAny(name, &.{ "Int", "Number", "Any", "Comparable" }),
            .Long => matchesAny(name, &.{ "Long", "Number", "Any", "Comparable" }),
            .Short => matchesAny(name, &.{ "Short", "Number", "Any", "Comparable" }),
            .Byte => matchesAny(name, &.{ "Byte", "Number", "Any", "Comparable" }),
            .UInt => matchesAny(name, &.{ "UInt", "Number", "Any", "Comparable" }),
            .ULong => matchesAny(name, &.{ "ULong", "Number", "Any", "Comparable" }),
            .UShort => matchesAny(name, &.{ "UShort", "Number", "Any", "Comparable" }),
            .UByte => matchesAny(name, &.{ "UByte", "Number", "Any", "Comparable" }),
            .Double => matchesAny(name, &.{ "Double", "Number", "Any", "Comparable" }),
            .Float => matchesAny(name, &.{ "Float", "Number", "Any", "Comparable" }),
            .Bool => matchesAny(name, &.{ "Boolean", "Any", "Comparable" }),
            .String => matchesAny(name, &.{ "String", "CharSequence", "Any", "Comparable" }),
            .Char => matchesAny(name, &.{ "Char", "Any", "Comparable" }),
            .Unit => matchesAny(name, &.{ "Unit", "Any" }),
            .Null => false,
            .Range => |r| switch (r.kind) {
                .Int => matchesAny(name, &.{ "IntRange", "IntProgression", "ClosedRange", "Iterable", "Any" }),
                .Long => matchesAny(name, &.{ "LongRange", "LongProgression", "ClosedRange", "Iterable", "Any" }),
                .Char => matchesAny(name, &.{ "CharRange", "CharProgression", "ClosedRange", "Iterable", "Any" }),
            },
            .List => |l| blk: {
                if (std.mem.eql(u8, name, "EnumEntries")) break :blk l.enum_class != null;
                if (l.mutable) {
                    break :blk matchesAny(name, &.{ "MutableList", "List", "Collection", "MutableCollection", "Iterable", "MutableIterable", "RandomAccess", "Any" });
                } else {
                    break :blk matchesAny(name, &.{ "List", "Collection", "Iterable", "RandomAccess", "Any" });
                }
            },
            .Set => |s| if (s.mutable)
                matchesAny(name, &.{ "MutableSet", "Set", "Collection", "Iterable", "Any" })
            else
                matchesAny(name, &.{ "Set", "Collection", "Iterable", "Any" }),
            .Map => |m| if (m.mutable)
                matchesAny(name, &.{ "MutableMap", "Map", "Any" })
            else
                matchesAny(name, &.{ "Map", "Any" }),
            .Pair => matchesAny(name, &.{ "Pair", "Any" }),
            .Triple => matchesAny(name, &.{ "Triple", "Any" }),
            .MapEntry => matchesAny(name, &.{ "Entry", "MapEntry", "Map.Entry", "Any" }),
            .Result => matchesAny(name, &.{ "Result", "Any" }),
            .Sequence => matchesAny(name, &.{ "Sequence", "Any" }),
            .Iterator => |it| blk: {
                if (matchesAny(name, &.{ "Iterator", "Any" })) break :blk true;
                if (it.prim) |p| {
                    break :blk simpleNameMatchesIterator(name, p.simpleName());
                }
                break :blk false;
            },
            .RangeIter => |ri| blk: {
                if (matchesAny(name, &.{ "Iterator", "Any" })) break :blk true;
                break :blk switch (ri.kind) {
                    .Int => std.mem.eql(u8, name, "IntIterator"),
                    .Long => std.mem.eql(u8, name, "LongIterator"),
                    .Char => std.mem.eql(u8, name, "CharIterator"),
                };
            },
            .Comparator => matchesAny(name, &.{ "Comparator", "Any" }),
            .Function, .IrClosure, .Intrinsic, .BoundMethod, .BoundUserMethod => isFunctionType(self, name),
            .Exception => |e| blk: {
                const g = e.fqn.borrow();
                defer g.deinit();
                const fqn = g.get().*;
                const tail = lastSegment(fqn);
                break :blk std.mem.eql(u8, tail, name) or
                    matchesAny(name, &.{ "Throwable", "Exception", "Any" }) or
                    std.mem.eql(u8, fqn, name);
            },
            .Class, .BoundInnerClass => matchesAny(name, &.{ "KClass", "kotlin.reflect.KClass", "Any" }),
            .Instance => |i| blk: {
                if (std.mem.eql(u8, name, "Any")) break :blk true;
                const g = i.borrow();
                defer g.deinit();
                const inst = g.get();
                const cg = inst.class.borrow();
                defer cg.deinit();
                // The subtype walk needs an allocator for its frontier; use a
                // fixed buffer to avoid threading one through the predicate.
                var buf: [16 * 1024]u8 = undefined;
                var fba = std.heap.FixedBufferAllocator.init(&buf);
                const a = fba.allocator();
                if (cg.get().isSubtypeOf(a, name)) break :blk true;
                if (lastDotSegment(name)) |simple| {
                    fba.reset();
                    if (cg.get().isSubtypeOf(a, simple)) break :blk true;
                }
                break :blk false;
            },
            .Delegate => matchesAny(name, &.{"Any"}),
            .PropertyRef => matchesAny(name, &.{ "KProperty", "KProperty0", "KProperty1", "KCallable", "kotlin.reflect.KProperty", "kotlin.reflect.KProperty0", "kotlin.reflect.KProperty1", "kotlin.reflect.KCallable", "Any" }),
            .Array => |a| blk: {
                if (std.mem.eql(u8, name, "Any")) break :blk true;
                break :blk if (a.prim) |p| switch (p) {
                    .Int => std.mem.eql(u8, name, "IntArray"),
                    .Long => std.mem.eql(u8, name, "LongArray"),
                    .Double => std.mem.eql(u8, name, "DoubleArray"),
                    .Float => std.mem.eql(u8, name, "FloatArray"),
                    .Short => std.mem.eql(u8, name, "ShortArray"),
                    .Byte => std.mem.eql(u8, name, "ByteArray"),
                    .Boolean => std.mem.eql(u8, name, "BooleanArray"),
                    .Char => std.mem.eql(u8, name, "CharArray"),
                    .UInt => std.mem.eql(u8, name, "UIntArray"),
                    .ULong => std.mem.eql(u8, name, "ULongArray"),
                    .UShort => std.mem.eql(u8, name, "UShortArray"),
                    .UByte => std.mem.eql(u8, name, "UByteArray"),
                } else std.mem.eql(u8, name, "Array");
            },
            .Regex => matchesAny(name, &.{ "Regex", "Any" }),
            .Match => matchesAny(name, &.{ "MatchResult", "Any" }),
            .MatchGroup => matchesAny(name, &.{ "MatchGroup", "Any" }),
            .StringBuilder => matchesAny(name, &.{ "StringBuilder", "Appendable", "CharSequence", "Any" }),
        };
    }

    /// Equality with boxed `Number` semantics (each boxed type only matches
    /// its own type; collections compare elements boxed too).
    pub fn structuralEqBoxed(a: *const Value, b: *const Value) bool {
        switch (a.*) {
            .Double => |x| if (b.* == .Double) return @as(u64, @bitCast(x)) == @as(u64, @bitCast(b.Double)),
            .Float => |x| if (b.* == .Float) return @as(u32, @bitCast(x)) == @as(u32, @bitCast(b.Float)),
            .Int => |x| if (b.* == .Int) return x == b.Int,
            .Long => |x| if (b.* == .Long) return x == b.Long,
            .Short => |x| if (b.* == .Short) return x == b.Short,
            .Byte => |x| if (b.* == .Byte) return x == b.Byte,
            .UInt => |x| if (b.* == .UInt) return x == b.UInt,
            .ULong => |x| if (b.* == .ULong) return x == b.ULong,
            .UShort => |x| if (b.* == .UShort) return x == b.UShort,
            .UByte => |x| if (b.* == .UByte) return x == b.UByte,
            .List => |x| if (b.* == .List) return listEqBoxed(x.items, b.List.items),
            .Set => |x| if (b.* == .Set) return setEqBoxed(x.items, b.Set.items),
            .Map => |x| if (b.* == .Map) return mapEqBoxed(x.entries, b.Map.entries),
            .Pair => |x| if (b.* == .Pair)
                return structuralEqBoxed(x.first, b.Pair.first) and structuralEqBoxed(x.second, b.Pair.second),
            .Triple => |x| if (b.* == .Triple)
                return structuralEqBoxed(x.first, b.Triple.first) and
                    structuralEqBoxed(x.second, b.Triple.second) and
                    structuralEqBoxed(x.third, b.Triple.third),
            .MapEntry => |x| if (b.* == .MapEntry)
                return structuralEqBoxed(x.key, b.MapEntry.key) and structuralEqBoxed(x.value, b.MapEntry.value),
            else => {},
        }
        // Any other mix of two numerics is a cross-type boxed comparison.
        if (a.isNumeric() and b.isNumeric()) return false;
        return structuralEq(a, b);
    }

    pub fn structuralEq(a: *const Value, b: *const Value) bool {
        if (a.isNumeric() and b.isNumeric()) {
            return switch (a.*) {
                .Int => |x| b.* == .Int and x == b.Int,
                .Long => |x| b.* == .Long and x == b.Long,
                .Short => |x| b.* == .Short and x == b.Short,
                .Byte => |x| b.* == .Byte and x == b.Byte,
                .UInt => |x| b.* == .UInt and x == b.UInt,
                .ULong => |x| b.* == .ULong and x == b.ULong,
                .UShort => |x| b.* == .UShort and x == b.UShort,
                .UByte => |x| b.* == .UByte and x == b.UByte,
                .Double => |x| b.* == .Double and x == b.Double,
                .Float => |x| b.* == .Float and x == b.Float,
                else => false,
            };
        }
        return switch (a.*) {
            .Bool => |x| b.* == .Bool and x == b.Bool,
            .String => |x| b.* == .String and strEq(x, b.String),
            .Char => |x| b.* == .Char and x == b.Char,
            .Null => b.* == .Null,
            .Unit => b.* == .Unit,
            .CoroutineSuspended => b.* == .CoroutineSuspended,
            .Range => |x| b.* == .Range and
                x.start == b.Range.start and x.end == b.Range.end and
                x.step == b.Range.step and x.kind == b.Range.kind,
            .List => |x| b.* == .List and listEqBoxed(x.items, b.List.items),
            .Set => |x| b.* == .Set and setEqBoxed(x.items, b.Set.items),
            .Map => |x| b.* == .Map and mapEqBoxed(x.entries, b.Map.entries),
            .Pair => |x| b.* == .Pair and
                structuralEqBoxed(x.first, b.Pair.first) and structuralEqBoxed(x.second, b.Pair.second),
            .Triple => |x| b.* == .Triple and
                structuralEqBoxed(x.first, b.Triple.first) and
                structuralEqBoxed(x.second, b.Triple.second) and
                structuralEqBoxed(x.third, b.Triple.third),
            .MapEntry => |x| b.* == .MapEntry and
                structuralEqBoxed(x.key, b.MapEntry.key) and structuralEqBoxed(x.value, b.MapEntry.value),
            .Result => |x| b.* == .Result and x.ok == b.Result.ok and structuralEq(x.payload, b.Result.payload),
            .Class => |x| b.* == .Class and classFqnEq(x, b.Class),
            .IrClosure => |x| b.* == .IrClosure and x.id == b.IrClosure.id and ValueSlice.ptrEq(x.captures, b.IrClosure.captures),
            .BoundMethod => |x| b.* == .BoundMethod and std.mem.eql(u8, x.fqn, b.BoundMethod.fqn) and structuralEq(x.receiver, b.BoundMethod.receiver),
            .Instance => |x| b.* == .Instance and instanceEq(x, b.Instance),
            else => false,
        };
    }

    /// Kotlin referential identity (`===` / `!==`).
    pub fn referenceEq(a: *const Value, b: *const Value) bool {
        switch (a.*) {
            .Instance => |x| return b.* == .Instance and ObjRef(InstanceData).ptrEq(x, b.Instance),
            .Cell => |x| if (b.* == .Cell) return ObjRef(Value).ptrEq(x, b.Cell),
            .List => |x| if (b.* == .List) return ValueList.ptrEq(x.items, b.List.items),
            .Set => |x| if (b.* == .Set) return ValueList.ptrEq(x.items, b.Set.items),
            .Map => |x| if (b.* == .Map) return MapEntries.ptrEq(x.entries, b.Map.entries),
            .Array => |x| if (b.* == .Array) return ValueList.ptrEq(x.items, b.Array.items),
            .Intrinsic => |x| {
                if (b.* == .Intrinsic) return std.mem.eql(u8, x.fqn, b.Intrinsic.fqn);
                if (b.* == .CoroutineSuspended) return std.mem.eql(u8, x.fqn, "kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED");
            },
            .CoroutineSuspended => if (b.* == .Intrinsic) return std.mem.eql(u8, b.Intrinsic.fqn, "kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED"),
            else => {},
        }
        if (a.* == .Instance or b.* == .Instance) return false;
        return structuralEq(a, b);
    }

    /// Address-stable identity for use as a `synchronized` monitor key.
    pub fn lockIdentity(self: Value) ?usize {
        return switch (self) {
            .Instance => |i| i.identity(),
            .List => |l| l.items.identity(),
            .Array => |a| a.items.identity(),
            .Set => |s| s.items.identity(),
            .Map => |m| m.entries.identity(),
            .Cell => |c| c.identity(),
            .StringBuilder => |s| s.identity(),
            else => null,
        };
    }

    /// Render this value the way Kotlin's `toString` / string templates do,
    /// writing into `writer`. Mirrors the Rust `Display` impl.
    pub fn writeTo(self: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .Cell => |c| {
                const g = c.borrow();
                defer g.deinit();
                try g.get().writeTo(writer);
            },
            .Unit => try writer.writeAll("kotlin.Unit"),
            .CoroutineSuspended => try writer.writeAll("COROUTINE_SUSPENDED"),
            .Int => |v| try writer.print("{d}", .{v}),
            .Long => |v| try writer.print("{d}", .{v}),
            .Short => |v| try writer.print("{d}", .{v}),
            .Byte => |v| try writer.print("{d}", .{v}),
            .UInt => |v| try writer.print("{d}", .{v}),
            .ULong => |v| try writer.print("{d}", .{v}),
            .UShort => |v| try writer.print("{d}", .{v}),
            .UByte => |v| try writer.print("{d}", .{v}),
            .Double => |v| try writeFloat64(writer, v),
            .Float => |v| try writeFloat32(writer, v),
            .Bool => |v| try writer.writeAll(if (v) "true" else "false"),
            .String => |s| {
                const g = s.borrow();
                defer g.deinit();
                try writer.writeAll(g.get().*);
            },
            .Char => |v| try writeChar(writer, v),
            .Null => try writer.writeAll("null"),
            .Range => |r| {
                if (r.step == 1) {
                    try writer.print("{d}..{d}", .{ r.start, r.end });
                } else if (r.step > 0) {
                    try writer.print("{d}..{d} step {d}", .{ r.start, r.end, r.step });
                } else {
                    try writer.print("{d} downTo {d} step {d}", .{ r.start, r.end, -r.step });
                }
            },
            .Function => |fnv| try writer.print("fun {s}(...)", .{fnv.decl.name.name}),
            .IrClosure => |c| try writer.print("{{ir-closure#{d}}}", .{c.id}),
            .Intrinsic => |i| try writer.print("fun {s}(...)", .{i.fqn}),
            .BoundMethod => |m| try writer.print("fun {s}(...)", .{m.fqn}),
            .BoundUserMethod => |m| {
                const g = m.receiver.borrow();
                defer g.deinit();
                const cg = g.get().class.borrow();
                defer cg.deinit();
                try writer.print("fun {s}.{s}(...)", .{ cg.get().name, m.method.name });
            },
            .Exception => |e| {
                const fg = e.fqn.borrow();
                defer fg.deinit();
                if (e.message) |m| {
                    const mg = m.borrow();
                    defer mg.deinit();
                    try writer.print("{s}: {s}", .{ fg.get().*, mg.get().* });
                } else {
                    try writer.writeAll(fg.get().*);
                }
            },
            .List => |coll| try writeElements(writer, coll.items),
            .Set => |coll| try writeElements(writer, coll.items),
            .Array => |a| {
                const tag = if (a.prim) |k| k.typeFqn() else "kotlin.Array";
                try writer.print("{s}@<…>", .{tag});
            },
            .Map => |m| {
                const g = m.entries.borrow();
                defer g.deinit();
                try writer.writeByte('{');
                for (g.get().items, 0..) |e, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try e.key.writeTo(writer);
                    try writer.writeByte('=');
                    try e.value.writeTo(writer);
                }
                try writer.writeByte('}');
            },
            .Pair => |p| {
                try writer.writeByte('(');
                try p.first.writeTo(writer);
                try writer.writeAll(", ");
                try p.second.writeTo(writer);
                try writer.writeByte(')');
            },
            .Triple => |t| {
                try writer.writeByte('(');
                try t.first.writeTo(writer);
                try writer.writeAll(", ");
                try t.second.writeTo(writer);
                try writer.writeAll(", ");
                try t.third.writeTo(writer);
                try writer.writeByte(')');
            },
            .MapEntry => |e| {
                try e.key.writeTo(writer);
                try writer.writeByte('=');
                try e.value.writeTo(writer);
            },
            .Result => |r| {
                try writer.writeAll(if (r.ok) "Success(" else "Failure(");
                try r.payload.writeTo(writer);
                try writer.writeByte(')');
            },
            .Comparator => try writer.writeAll("Comparator"),
            .Sequence => try writer.writeAll("kotlin.sequences.Sequence"),
            .Iterator => |it| if (it.prim) |p|
                try writer.print("{s}Iterator", .{p.simpleName()})
            else
                try writer.writeAll("kotlin.collections.Iterator"),
            .RangeIter => |ri| switch (ri.kind) {
                .Int => try writer.writeAll("kotlin.ranges.IntProgressionIterator"),
                .Long => try writer.writeAll("kotlin.ranges.LongProgressionIterator"),
                .Char => try writer.writeAll("kotlin.ranges.CharProgressionIterator"),
            },
            .Class => |c| {
                const g = c.borrow();
                defer g.deinit();
                try writer.print("class {s}", .{g.get().name});
            },
            .BoundInnerClass => |b| {
                const g = b.class.borrow();
                defer g.deinit();
                try writer.print("class {s}", .{g.get().name});
            },
            .Delegate => try writer.writeAll("<delegate>"),
            .PropertyRef => |p| {
                const g = p.name.borrow();
                defer g.deinit();
                try writer.print("property {s} (Kotlin reflection is not available)", .{g.get().*});
            },
            .Regex => |r| {
                const rg = r.borrow();
                defer rg.deinit();
                const pg = rg.get().pattern.borrow();
                defer pg.deinit();
                try writer.writeAll(pg.get().*);
            },
            .Match => |m| {
                const mg = m.borrow();
                defer mg.deinit();
                const groups = mg.get().groups;
                if (groups.len > 0) {
                    if (groups[0]) |g0| {
                        const vg = g0.value.borrow();
                        defer vg.deinit();
                        try writer.writeAll(vg.get().*);
                    }
                }
            },
            .MatchGroup => |g| {
                const vg = g.value.borrow();
                defer vg.deinit();
                try writer.writeAll(vg.get().*);
            },
            .StringBuilder => |s| {
                const g = s.borrow();
                defer g.deinit();
                try writer.writeAll(g.get().items);
            },
            .Instance => |i| try writeInstance(writer, i),
        }
    }

    /// Render to an owned string via `writeTo`.
    pub fn display(self: Value, allocator: std.mem.Allocator) ![]u8 {
        var alloc_writer = std.Io.Writer.Allocating.init(allocator);
        errdefer alloc_writer.deinit();
        self.writeTo(&alloc_writer.writer) catch return error.OutOfMemory;
        return alloc_writer.toOwnedSlice();
    }
};

/// One key-selector step of a `Comparator`: a callable plus a per-step
/// descending flag.
pub const ComparatorStep = struct { selector: Value, descending: bool };

fn writeElements(writer: *std.Io.Writer, items: ValueList) std.Io.Writer.Error!void {
    const g = items.borrow();
    defer g.deinit();
    try writer.writeByte('[');
    for (g.get().items, 0..) |v, i| {
        if (i > 0) try writer.writeAll(", ");
        try v.writeTo(writer);
    }
    try writer.writeByte(']');
}

fn writeInstance(writer: *std.Io.Writer, inst_ref: ObjRef(InstanceData)) std.Io.Writer.Error!void {
    const g = inst_ref.borrow();
    defer g.deinit();
    const inst = g.get();
    const cg = inst.class.borrow();
    defer cg.deinit();
    const cls = cg.get();
    if (cls.is_enum) {
        if (inst.get("name")) |nv| {
            if (nv == .String) {
                const sg = nv.String.borrow();
                defer sg.deinit();
                try writer.writeAll(sg.get().*);
                return;
            }
        }
        try writer.writeAll(cls.name);
        return;
    }
    if (cls.is_object) {
        try writer.writeAll(cls.name);
        return;
    }
    if (cls.is_data or cls.is_value) {
        try writer.print("{s}(", .{cls.name});
        var first = true;
        for (cls.primary_params) |p| {
            if (!first) try writer.writeAll(", ");
            first = false;
            try writer.print("{s}=", .{p.name});
            if (inst.get(p.name)) |v| {
                try v.writeTo(writer);
            } else {
                try writer.writeAll("null");
            }
        }
        try writer.writeByte(')');
        return;
    }
    try writer.print("{s}@{x}", .{ cls.fqn, inst.identity });
}

fn writeFloat64(writer: *std.Io.Writer, v: f64) std.Io.Writer.Error!void {
    var buf: [float_fmt.MAX_LEN]u8 = undefined;
    try writer.writeAll(float_fmt.formatDouble(&buf, v));
}

fn writeFloat32(writer: *std.Io.Writer, v: f32) std.Io.Writer.Error!void {
    var buf: [float_fmt.MAX_LEN]u8 = undefined;
    try writer.writeAll(float_fmt.formatFloat(&buf, v));
}

fn writeChar(writer: *std.Io.Writer, unit: u16) std.Io.Writer.Error!void {
    var buf: [8]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const s = float_fmt.charUnitToString(fba.allocator(), unit) catch return;
    try writer.writeAll(s);
}

fn matchesAny(name: []const u8, candidates: []const []const u8) bool {
    for (candidates) |c| {
        if (std.mem.eql(u8, name, c)) return true;
    }
    return false;
}

fn simpleNameMatchesIterator(name: []const u8, simple: []const u8) bool {
    // name == "{simple}Iterator"
    if (!std.mem.endsWith(u8, name, "Iterator")) return false;
    const head = name[0 .. name.len - "Iterator".len];
    return std.mem.eql(u8, head, simple);
}

fn lastSegment(fqn: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, fqn, '.')) |i| return fqn[i + 1 ..];
    return fqn;
}

fn lastDotSegment(name: []const u8) ?[]const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| return name[i + 1 ..];
    return null;
}

fn isFunctionType(self: Value, name: []const u8) bool {
    if (matchesAny(name, &.{ "Function", "Any", "kotlin.Function", "KFunction", "KCallable", "kotlin.reflect.KFunction", "kotlin.reflect.KCallable" })) {
        return true;
    }
    const stripped: ?[]const u8 = if (std.mem.startsWith(u8, name, "kotlin.Function"))
        name["kotlin.Function".len..]
    else if (std.mem.startsWith(u8, name, "Function"))
        name["Function".len..]
    else
        null;
    if (stripped) |s| {
        const n = std.fmt.parseInt(usize, s, 10) catch return false;
        return switch (self) {
            .Function => |f| f.decl.params.len == n,
            else => false,
        };
    }
    return false;
}

fn strEq(a: StringRef, b: StringRef) bool {
    const ga = a.borrow();
    defer ga.deinit();
    const gb = b.borrow();
    defer gb.deinit();
    return std.mem.eql(u8, ga.get().*, gb.get().*);
}

fn classFqnEq(a: ObjRef(ClassDef), b: ObjRef(ClassDef)) bool {
    const ga = a.borrow();
    defer ga.deinit();
    const gb = b.borrow();
    defer gb.deinit();
    return std.mem.eql(u8, ga.get().fqn, gb.get().fqn);
}

fn listEqBoxed(a: ValueList, b: ValueList) bool {
    const ga = a.borrow();
    defer ga.deinit();
    const gb = b.borrow();
    defer gb.deinit();
    const xs = ga.get().items;
    const ys = gb.get().items;
    if (xs.len != ys.len) return false;
    for (xs, ys) |*x, *y| {
        if (!Value.structuralEqBoxed(x, y)) return false;
    }
    return true;
}

fn setEqBoxed(a: ValueList, b: ValueList) bool {
    const ga = a.borrow();
    defer ga.deinit();
    const gb = b.borrow();
    defer gb.deinit();
    const xs = ga.get().items;
    const ys = gb.get().items;
    if (xs.len != ys.len) return false;
    for (xs) |*x| {
        var found = false;
        for (ys) |*y| {
            if (Value.structuralEqBoxed(x, y)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn mapEqBoxed(a: MapEntries, b: MapEntries) bool {
    const ga = a.borrow();
    defer ga.deinit();
    const gb = b.borrow();
    defer gb.deinit();
    const xs = ga.get().items;
    const ys = gb.get().items;
    if (xs.len != ys.len) return false;
    for (xs) |*kv| {
        var found = false;
        for (ys) |*kv2| {
            if (Value.structuralEqBoxed(&kv.key, &kv2.key) and Value.structuralEqBoxed(&kv.value, &kv2.value)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn instanceEq(a: ObjRef(InstanceData), b: ObjRef(InstanceData)) bool {
    if (ObjRef(InstanceData).ptrEq(a, b)) return true;
    const ga = a.borrow();
    defer ga.deinit();
    const gb = b.borrow();
    defer gb.deinit();
    const ai = ga.get();
    const bi = gb.get();
    const ca = ai.class.borrow();
    defer ca.deinit();
    const cb = bi.class.borrow();
    defer cb.deinit();
    if (!std.mem.eql(u8, ca.get().fqn, cb.get().fqn)) return false;
    if (!ca.get().is_data and !ca.get().is_value) return false;
    for (ca.get().primary_params) |p| {
        const v1 = ai.get(p.name) orelse Value.Null;
        const v2 = bi.get(p.name) orelse Value.Null;
        if (!Value.structuralEq(&v1, &v2)) return false;
    }
    return true;
}

/// Runtime error data. RuntimeError is DATA, never a Zig `error`; the
/// control-flow signals (`Return`, `Break`, …) are modeled as variants
/// exactly as in Rust. Heap-owning payloads borrow the interpreter's
/// arena; the message strings are borrowed slices.
pub const RuntimeError = union(enum) {
    Unbound: []const u8,
    Type: []const u8,
    Arity: []const u8,
    NoMain,
    Unimplemented: []const u8,
    /// A function body was entered and failed to resolve an operation.
    /// Distinct from `Unimplemented` (the dispatch-miss sentinel) so a
    /// candidate that ran — possibly with side effects — is never retried
    /// or treated as inapplicable; this error always propagates.
    CalleeFailed: []const u8,

    // Control-flow signals — caught by the appropriate frame.
    Return: Value,
    /// `return@label value`.
    LabeledReturn: struct { label: []const u8, value: Value },
    Break,
    /// `break@label`.
    LabeledBreak: []const u8,
    Continue,
    /// `continue@label`.
    LabeledContinue: []const u8,
    /// A thrown Kotlin Throwable.
    Thrown: Value,
    /// `tailrec` trampoline signal: evaluated args + optional names for the
    /// next iteration.
    TailContinue: struct { args: []Value, names: []?[]const u8 },
    /// Mutual `tailrec` hop: callee value, args, optional names.
    TailJump: struct { callee: Value, args: []Value, names: []?[]const u8 },
    /// Coroutine suspension request (wake after `wake_in_millis` virtual ms).
    Suspend: i64,
};

/// `Result<Value, RuntimeError>` as data. OOM stays a Zig `error`; this
/// carries the RuntimeError data path.
pub const EvalResult = union(enum) {
    ok: Value,
    err: RuntimeError,
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "numeric type fqn and rank" {
    try testing.expectEqualStrings("kotlin.Int", (Value{ .Int = 1 }).typeFqn());
    try testing.expectEqualStrings("kotlin.Long", (Value{ .Long = 1 }).typeFqn());
    try testing.expectEqual(NumericRank.Int, (Value{ .Int = 1 }).numericRank().?);
    try testing.expectEqual(NumericRank.Double, (Value{ .Double = 1 }).numericRank().?);
}

test "as_i64 widens and ulong wraps" {
    try testing.expectEqual(@as(i64, 5), (Value{ .Int = 5 }).asI64().?);
    try testing.expectEqual(@as(i64, -1), (Value{ .ULong = std.math.maxInt(u64) }).asI64().?);
    try testing.expect((Value{ .Double = 1.0 }).asI64() == null);
}

test "structural eq is type-strict across numerics" {
    const a = Value{ .Int = 1 };
    const b = Value{ .Long = 1 };
    try testing.expect(!Value.structuralEq(&a, &b));
    const c = Value{ .Int = 1 };
    try testing.expect(Value.structuralEq(&a, &c));
}

test "is_runtime_type basic primitives" {
    try testing.expect((Value{ .Int = 1 }).isRuntimeType("Number"));
    try testing.expect((Value{ .Int = 1 }).isRuntimeType("Any"));
    try testing.expect(!(Value{ .Int = 1 }).isRuntimeType("Long"));
}

test "range display forms" {
    var buf: [64]u8 = undefined;
    {
        var w = std.Io.Writer.fixed(&buf);
        try (Value{ .Range = .{ .start = 1, .end = 10, .step = 1, .kind = .Int } }).writeTo(&w);
        try testing.expectEqualStrings("1..10", w.buffered());
    }
    {
        var w = std.Io.Writer.fixed(&buf);
        try (Value{ .Range = .{ .start = 10, .end = 1, .step = -2, .kind = .Int } }).writeTo(&w);
        try testing.expectEqualStrings("10 downTo 1 step 2", w.buffered());
    }
}

test "string value round-trips through a refcounted handle" {
    const s = try StringRef.init(testing.allocator, "hi");
    defer s.deinit();
    const v = Value{ .String = s };
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try v.writeTo(&w);
    try testing.expectEqualStrings("hi", w.buffered());
    try testing.expectEqualStrings("kotlin.String", v.typeFqn());
}

test "display produces an owned string" {
    const v = Value{ .Int = 42 };
    const s = try v.display(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("42", s);
}
