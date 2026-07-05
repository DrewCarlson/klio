//! Kotlin stdlib host.
//!
//! This module is the home of the Zig-native Kotlin standard library. The
//! shape of the API surface is produced by the stdlib generator from the
//! upstream Kotlin sources (`kotlin/libraries/stdlib/`) and lives in
//! `generated/`.
//!
//! # Symbol schema
//!
//! Every public symbol mined from the upstream tree is recorded as a
//! `SymbolEntry`. The slice returned by `generated.stdlibSymbols()` is the
//! canonical registry. Each entry carries:
//!
//! * `fqn`        — fully qualified name (`kotlin.collections.listOf`)
//! * `package`    — package path (`kotlin.collections`)
//! * `name`       — simple name (`listOf`)
//! * `kind`       — function / property / class / interface / typealias / object
//! * `receiver`   — extension receiver type as text, if any
//! * `signature`  — raw textual signature (trimmed source line)
//! * `param_names`— parameter names in declaration order
//! * `modifiers`  — bitset of Kotlin modifiers we care about
//! * `source`     — relative upstream path + 1-based line/column
//! * `impl_fn`    — non-null once a Zig implementation is wired up.

const std = @import("std");
const runtime = @import("runtime");

pub const generated = @import("generated/mod.zig");
pub const implementations = @import("implementations.zig");
pub const pack_builder = @import("pack_builder.zig");

// Per-area documentation shims (mirror the Rust submodule layout).
pub const collections = @import("collections.zig");
pub const exceptions = @import("exceptions.zig");
pub const io = @import("io.zig");
pub const numerics = @import("numerics.zig");
pub const ranges = @import("ranges.zig");
pub const sequences = @import("sequences.zig");
pub const text = @import("text.zig");

/// Function pointer signature for a Zig-native stdlib intrinsic.
pub const StdlibFn = runtime.StdlibFn;

pub const build_stdlib_pack = pack_builder.buildStdlibPack;

// Internal helpers the interpreter's higher-order ops use for comparisons.
pub const compare_values = implementations.compare_values;
pub const materialise_sequence = implementations.materialise_sequence;
pub const materialise_sequence_bounded = implementations.materialise_sequence_bounded;
pub const makeSeqIter = implementations.sequence.makeSeqIter;
pub const oneShotConsumeCheck = implementations.collections.oneShotConsumeCheck;
pub const resetEmptyCollectionSingletons = implementations.collections.resetEmptyCollectionSingletons;
pub const resetEmptySequenceSingleton = implementations.sequence.resetEmptySequenceSingleton;
pub const freshBuilderSeq = implementations.collections.freshBuilderSeq;
pub const primitive_companion_const = implementations.primitive_companion_const;
pub const compareUtf16 = text.compareUtf16;

/// `(name, fqn)` pair installed into globals so identifiers like `println`,
/// `listOf`, or `IllegalArgumentException` resolve without an explicit import.
pub const Alias = struct { name: []const u8, fqn: []const u8 };

/// Bare names that resolve through implicit Kotlin imports. Mirrors Kotlin's
/// `kotlin.*` / `kotlin.io.*` / `kotlin.collections.*` / `kotlin.text.*` /
/// `kotlin.ranges.*` default imports.
pub const IMPLICIT_ALIASES = [_]Alias{
    .{ .name = "print", .fqn = "kotlin.io.print" },
    .{ .name = "println", .fqn = "kotlin.io.println" },
    .{ .name = "readLine", .fqn = "kotlin.io.readLine" },
    .{ .name = "ArithmeticException", .fqn = "kotlin.ArithmeticException" },
    .{ .name = "ClassCastException", .fqn = "kotlin.ClassCastException" },
    .{ .name = "Error", .fqn = "kotlin.Error" },
    .{ .name = "Exception", .fqn = "kotlin.Exception" },
    .{ .name = "IllegalArgumentException", .fqn = "kotlin.IllegalArgumentException" },
    .{ .name = "IllegalStateException", .fqn = "kotlin.IllegalStateException" },
    .{ .name = "IndexOutOfBoundsException", .fqn = "kotlin.IndexOutOfBoundsException" },
    .{ .name = "NoSuchElementException", .fqn = "kotlin.NoSuchElementException" },
    .{ .name = "NullPointerException", .fqn = "kotlin.NullPointerException" },
    .{ .name = "RuntimeException", .fqn = "kotlin.RuntimeException" },
    .{ .name = "Throwable", .fqn = "kotlin.Throwable" },
    .{ .name = "UnsupportedOperationException", .fqn = "kotlin.UnsupportedOperationException" },
    .{ .name = "NoWhenBranchMatchedException", .fqn = "kotlin.NoWhenBranchMatchedException" },
    .{ .name = "NumberFormatException", .fqn = "kotlin.NumberFormatException" },
    .{ .name = "ConcurrentModificationException", .fqn = "kotlin.ConcurrentModificationException" },
    .{ .name = "AssertionError", .fqn = "kotlin.AssertionError" },
    .{ .name = "Pair", .fqn = "kotlin.Pair" },
    .{ .name = "Triple", .fqn = "kotlin.Triple" },
    .{ .name = "emptyList", .fqn = "kotlin.collections.emptyList" },
    .{ .name = "emptyMap", .fqn = "kotlin.collections.emptyMap" },
    .{ .name = "emptySet", .fqn = "kotlin.collections.emptySet" },
    // The inline builder factories. A bare reference must resolve to the host
    // intrinsic actual rather than to a same-named Kotlin-source overload.
    .{ .name = "buildList", .fqn = "kotlin.collections.buildList" },
    .{ .name = "buildSet", .fqn = "kotlin.collections.buildSet" },
    .{ .name = "buildMap", .fqn = "kotlin.collections.buildMap" },
    .{ .name = "buildString", .fqn = "kotlin.text.buildString" },
    .{ .name = "listOf", .fqn = "kotlin.collections.listOf" },
    .{ .name = "mapOf", .fqn = "kotlin.collections.mapOf" },
    .{ .name = "mutableListOf", .fqn = "kotlin.collections.mutableListOf" },
    .{ .name = "mutableMapOf", .fqn = "kotlin.collections.mutableMapOf" },
    .{ .name = "mutableSetOf", .fqn = "kotlin.collections.mutableSetOf" },
    .{ .name = "setOf", .fqn = "kotlin.collections.setOf" },
    // Collection factories whose Kotlin source the build drops for an intrinsic
    // (so they have no lowered FuncId): bind them as value-position globals too,
    // so `factory(*array)` spread calls and value-position references resolve.
    .{ .name = "arrayListOf", .fqn = "kotlin.collections.arrayListOf" },
    .{ .name = "hashMapOf", .fqn = "kotlin.collections.hashMapOf" },
    .{ .name = "linkedMapOf", .fqn = "kotlin.collections.linkedMapOf" },
    .{ .name = "hashSetOf", .fqn = "kotlin.collections.hashSetOf" },
    .{ .name = "linkedSetOf", .fqn = "kotlin.collections.linkedSetOf" },
    .{ .name = "sortedSetOf", .fqn = "kotlin.collections.sortedSetOf" },
    .{ .name = "sortedMapOf", .fqn = "kotlin.collections.sortedMapOf" },
    .{ .name = "listOfNotNull", .fqn = "kotlin.collections.listOfNotNull" },
    .{ .name = "setOfNotNull", .fqn = "kotlin.collections.setOfNotNull" },
    .{ .name = "to", .fqn = "kotlin.to" },
    .{ .name = "ArrayList", .fqn = "kotlin.collections.ArrayList" },
    .{ .name = "HashMap", .fqn = "kotlin.collections.HashMap" },
    .{ .name = "HashSet", .fqn = "kotlin.collections.HashSet" },
    .{ .name = "LinkedHashMap", .fqn = "kotlin.collections.LinkedHashMap" },
    .{ .name = "LinkedHashSet", .fqn = "kotlin.collections.LinkedHashSet" },
    .{ .name = "sequenceOf", .fqn = "kotlin.sequences.sequenceOf" },
    .{ .name = "emptySequence", .fqn = "kotlin.sequences.emptySequence" },
    .{ .name = "generateSequence", .fqn = "kotlin.sequences.generateSequence" },
    .{ .name = "sequence", .fqn = "kotlin.sequences.sequence" },
    .{ .name = "iterator", .fqn = "kotlin.sequences.iterator" },
    .{ .name = "downTo", .fqn = "kotlin.ranges.downTo" },
    .{ .name = "step", .fqn = "kotlin.ranges.step" },
    .{ .name = "until", .fqn = "kotlin.ranges.until" },
    .{ .name = "minOf", .fqn = "kotlin.comparisons.minOf" },
    .{ .name = "maxOf", .fqn = "kotlin.comparisons.maxOf" },
    .{ .name = "Regex", .fqn = "kotlin.text.Regex" },
    .{ .name = "StringBuilder", .fqn = "kotlin.text.StringBuilder" },
};

/// The array constructor builders. Each is a top-level global factory
/// (`arrayOf(vararg T): Array<T>`, ...) with no receiver-typed variant.
/// Member dispatch uses this to resolve a bare call inside a method / lambda
/// body to the global intrinsic instead of prepending the enclosing receiver
/// as a spurious first element.
pub const ARRAY_BUILDERS = [_][]const u8{
    "arrayOf",      "arrayOfNulls",  "emptyArray",    "byteArrayOf",
    "ubyteArrayOf", "shortArrayOf",  "ushortArrayOf", "intArrayOf",
    "uintArrayOf",  "longArrayOf",   "ulongArrayOf",  "charArrayOf",
    "floatArrayOf", "doubleArrayOf", "booleanArrayOf",
};

pub fn isArrayBuilder(name: []const u8) bool {
    for (ARRAY_BUILDERS) |b| {
        if (std.mem.eql(u8, b, name)) return true;
    }
    return false;
}

/// True when `name` is a top-level stdlib *function* (a builder / factory / IO
/// / comparison helper), as opposed to an extension or infix function on a
/// receiver, a type, or an exception. Derived from `IMPLICIT_ALIASES`: take
/// the lowercase entries (functions, not types/exceptions) and exclude the few
/// that genuinely are receiver/infix extensions.
pub fn isToplevelFunction(name: []const u8) bool {
    // `to`, `downTo`, `step`, `until` are infix extensions on a receiver.
    const receiver_infix = [_][]const u8{ "to", "downTo", "step", "until" };
    for (receiver_infix) |r| {
        if (std.mem.eql(u8, r, name)) return false;
    }
    // Top-level control / precondition intrinsics (`kotlin.error`,
    // `kotlin.check`, …). Their first parameter is a plain value, not a
    // receiver, so member dispatch must never prepend the enclosing
    // receiver as a spurious first argument — otherwise a bare
    // `error("msg")` inside a receiver context (e.g. a `runBlocking`
    // CoroutineScope lambda) would pass `this` as the message and drop the
    // literal. Same `Any`-typed-parameter trap the array builders avoid.
    for (CONTROL_INTRINSICS) |c| {
        if (std.mem.eql(u8, c, name)) return true;
    }
    for (IMPLICIT_ALIASES) |a| {
        if (std.mem.eql(u8, a.name, name) and name.len > 0 and std.ascii.isLower(name[0])) {
            return true;
        }
    }
    return false;
}

/// True when `name` is a top-level `kotlin.math` function whose two parameters
/// are both plain values (`min(a, b)` / `max(a, b)`), as opposed to a
/// single-receiver accessor. A property read probes `kotlin.math.{name}` and
/// dispatches the match with the receiver as the sole argument; for these the
/// runtime implementation returns its lone argument unchanged, which would
/// silently report the receiver itself as the property value. A property read
/// must never match them — a bare `min(x, y)` callee in a receiver context
/// resolves to the package function, not a member of the implicit receiver.
pub fn isBinaryMathFunction(name: []const u8) bool {
    return std.mem.eql(u8, name, "min") or std.mem.eql(u8, name, "max");
}

/// Top-level non-extension control / precondition functions in `kotlin`.
/// Each takes a value (not a receiver) as its first parameter, so member
/// dispatch must resolve a bare call to the global intrinsic instead of
/// prepending the enclosing receiver.
pub const CONTROL_INTRINSICS = [_][]const u8{
    "error",     "check",          "checkNotNull",
    "require",   "requireNotNull", "TODO",
    "assert",
};

/// Packages whose top-level entities are implicitly visible in every Kotlin
/// source file. The exact set the spec lists for `Kotlin/Core`.
pub const IMPLICITLY_IMPORTED_PACKAGES = [_][]const u8{
    "kotlin",
    "kotlin.annotation",
    "kotlin.collections",
    "kotlin.comparisons",
    "kotlin.io",
    "kotlin.ranges",
    "kotlin.sequences",
    "kotlin.text",
    "kotlin.math",
};

/// Returns true when `package_path` is one of the implicitly imported
/// packages (an exact match against `IMPLICITLY_IMPORTED_PACKAGES`).
pub fn isImplicitlyImportedPackage(package_path: []const u8) bool {
    for (IMPLICITLY_IMPORTED_PACKAGES) |p| {
        if (std.mem.eql(u8, p, package_path)) return true;
    }
    return false;
}

/// Record `fqn`'s simple name into `map` when its declaring package is
/// one of `packages` (exact match), keeping the mapping whose package
/// ranks earliest in the list. This is the single bare-name → FQN map
/// constructor: the link-time `default_import_globals` /
/// `any_member_globals` maps and the lowerer's inline-shadow name set
/// all derive their name domain from this one rule, so the
/// "which bare names does the shipped surface own" answer has exactly
/// one source of truth.
pub fn noteBareNameMapping(
    map: *std.StringHashMap([]const u8),
    packages: []const []const u8,
    fqn: []const u8,
) std.mem.Allocator.Error!void {
    const dot = std.mem.lastIndexOfScalar(u8, fqn, '.') orelse return;
    const pkg = fqn[0..dot];
    const name = fqn[dot + 1 ..];
    if (name.len == 0) return;
    const rank = bareNamePkgRank(packages, pkg) orelse return;
    const gop = try map.getOrPut(name);
    if (gop.found_existing) {
        const cur_dot = std.mem.lastIndexOfScalar(u8, gop.value_ptr.*, '.').?;
        const cur_rank = bareNamePkgRank(packages, gop.value_ptr.*[0..cur_dot]).?;
        if (rank >= cur_rank) return;
    }
    gop.value_ptr.* = fqn;
}

fn bareNamePkgRank(packages: []const []const u8, pkg: []const u8) ?usize {
    for (packages, 0..) |p, i| {
        if (std.mem.eql(u8, p, pkg)) return i;
    }
    return null;
}

/// Curated stdlib sources that PARSE but are not yet *consumed*. The loaders
/// skip these by `rel_path` suffix. Empty today.
pub const CONSUMPTION_DEFERRED_SOURCES = [_][]const u8{};

/// True when `rel_path` names a curated source on the consumption deferral
/// list (see `CONSUMPTION_DEFERRED_SOURCES`).
pub fn isConsumptionDeferredSource(rel_path: []const u8) bool {
    for (CONSUMPTION_DEFERRED_SOURCES) |suffix| {
        if (std.mem.endsWith(u8, rel_path, suffix)) return true;
    }
    return false;
}

/// Returns true when `package_path` names any package recognised by the stdlib
/// registry. Wider than `isImplicitlyImportedPackage` — covers every package
/// that has at least one symbol mined from upstream Kotlin (e.g.
/// `kotlin.coroutines`, `kotlin.reflect`). Used by the resolver to decide
/// whether an `import kotlin.<pkg>.*` is well-formed.
pub fn isKnownPackage(package_path: []const u8) bool {
    if (isImplicitlyImportedPackage(package_path)) return true;
    if (extra_known_packages.contains(package_path)) return true;
    // The mined symbol table and the intrinsic registry are static per
    // process; the per-query linear scan over both (thousands of string
    // compares) was a top interpreter-profile frame. Build the set of
    // every known package path — each symbol's package plus every dotted
    // prefix of every FQN — once, and answer from it.
    known_packages_lock.lock();
    if (!known_packages_built) {
        buildKnownPackages() catch {
            known_packages_lock.unlock();
            return isKnownPackageScan(package_path);
        };
        known_packages_built = true;
    }
    known_packages_lock.unlock();
    return known_packages.contains(package_path);
}

var known_packages: std.StringHashMapUnmanaged(void) = .empty;
var known_packages_built: bool = false;
var known_packages_lock: SpinLock = .{};

fn addFqnPrefixes(fqn: []const u8) !void {
    var i: usize = 0;
    while (i < fqn.len) : (i += 1) {
        if (fqn[i] == '.') {
            try known_packages.put(std.heap.page_allocator, fqn[0..i], {});
        }
    }
}

fn buildKnownPackages() !void {
    for (generated.stdlibSymbols()) |e| {
        try known_packages.put(std.heap.page_allocator, e.package, {});
        try addFqnPrefixes(e.fqn);
    }
    // Hand-written intrinsics live outside the mined symbol index. A package
    // that owns at least one such intrinsic is just as real as a mined one.
    var it = implementations.allFqns();
    while (it.next()) |fqn| {
        try addFqnPrefixes(fqn);
    }
}

/// The pre-memoization fallback, kept for the OOM path only.
fn isKnownPackageScan(package_path: []const u8) bool {
    for (generated.stdlibSymbols()) |e| {
        if (std.mem.eql(u8, e.package, package_path)) return true;
        if (startsWithPrefixDot(e.fqn, package_path)) return true;
    }
    var it = implementations.allFqns();
    while (it.next()) |fqn| {
        if (std.mem.lastIndexOfScalar(u8, fqn, '.')) |dot| {
            if (std.mem.eql(u8, fqn[0..dot], package_path)) return true;
        }
        if (startsWithPrefixDot(fqn, package_path)) return true;
    }
    return false;
}

fn startsWithPrefixDot(fqn: []const u8, package_path: []const u8) bool {
    if (fqn.len <= package_path.len) return false;
    if (!std.mem.startsWith(u8, fqn, package_path)) return false;
    return fqn[package_path.len] == '.';
}

/// Small atomic spin lock. Zig 0.16's blocking `std.Io.Mutex` is parameterised
/// on an `Io` handle; this set-up-time config has none, so it guards itself
/// with a spin lock built on `std.atomic.Value` (the same approach the runtime
/// uses for its cell locks).
const SpinLock = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn lock(self: *SpinLock) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinLock) void {
        self.state.store(0, .release);
    }
};

/// Process-global resolver configuration: package names loaded packs have
/// registered. Set-up-time configuration, not Kotlin heap state, written as
/// packs install and read-only during execution. Guarded by a spin lock.
const ExtraKnownPackages = struct {
    lock: SpinLock = .{},
    set: ?std.StringHashMapUnmanaged(void) = null,

    fn contains(self: *ExtraKnownPackages, pkg: []const u8) bool {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.set) |*s| return s.contains(pkg);
        return false;
    }

    fn insert(self: *ExtraKnownPackages, pkg: []const u8) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.set == null) self.set = .empty;
        const a = std.heap.page_allocator;
        const owned = a.dupe(u8, pkg) catch return;
        self.set.?.put(a, owned, {}) catch {};
    }
};

var extra_known_packages: ExtraKnownPackages = .{};

/// Augment the set of packages `isKnownPackage` recognises. Loaded packs call
/// this when their manifest declares packages outside the static stdlib
/// surface (e.g. `kotlinx.coroutines`). Idempotent.
pub fn registerKnownPackage(package_path: []const u8) void {
    extra_known_packages.insert(package_path);
}

pub const SymbolKind = enum {
    Function,
    Property,
    Class,
    Interface,
    Object,
    TypeAlias,

    pub fn asStr(self: SymbolKind) []const u8 {
        return switch (self) {
            .Function => "function",
            .Property => "property",
            .Class => "class",
            .Interface => "interface",
            .Object => "object",
            .TypeAlias => "typealias",
        };
    }
};

/// Modifier flags as a bitset. Stable bit assignments so the generator can
/// emit `Modifiers(0b...)` literals.
pub const Modifiers = struct {
    bits: u32 = 0,

    pub const PUBLIC: u32 = 1 << 0;
    pub const INTERNAL: u32 = 1 << 1;
    pub const PROTECTED: u32 = 1 << 2;
    pub const PRIVATE: u32 = 1 << 3;
    pub const OPEN: u32 = 1 << 4;
    pub const ABSTRACT: u32 = 1 << 5;
    pub const FINAL: u32 = 1 << 6;
    pub const SEALED: u32 = 1 << 7;
    pub const INLINE: u32 = 1 << 8;
    pub const INFIX: u32 = 1 << 9;
    pub const OPERATOR: u32 = 1 << 10;
    pub const TAILREC: u32 = 1 << 11;
    pub const EXPECT: u32 = 1 << 12;
    pub const ACTUAL: u32 = 1 << 13;
    pub const EXTERNAL: u32 = 1 << 14;
    pub const SUSPEND: u32 = 1 << 15;
    pub const OVERRIDE: u32 = 1 << 16;
    pub const DATA: u32 = 1 << 17;
    pub const VALUE: u32 = 1 << 18;
    pub const ENUM: u32 = 1 << 19;
    pub const ANNOTATION: u32 = 1 << 20;
    pub const COMPANION: u32 = 1 << 21;
    pub const CONST: u32 = 1 << 22;

    pub fn has(self: Modifiers, bit: u32) bool {
        return (self.bits & bit) != 0;
    }
};

pub const SourceLoc = struct {
    path: []const u8,
    line: u32,
    column: u32,
};

pub const SymbolEntry = struct {
    fqn: []const u8,
    package: []const u8,
    name: []const u8,
    kind: SymbolKind,
    receiver: ?[]const u8,
    signature: []const u8,
    /// Parameter names in declaration order. Empty for non-function
    /// declarations. The interpreter consults this when reordering
    /// named-argument calls before dispatching the function pointer.
    param_names: []const []const u8,
    modifiers: Modifiers,
    source: SourceLoc,
    impl_fn: ?StdlibFn,
};

/// Look up a symbol by fully qualified name. Linear scan; the registry is
/// small enough that this is fine.
pub fn lookup(fqn: []const u8) ?*const SymbolEntry {
    for (generated.stdlibSymbols()) |*e| {
        if (std.mem.eql(u8, e.fqn, fqn)) return e;
    }
    return null;
}

/// Iterates every registered stdlib symbol FQN: first the mined registry,
/// then the hand-written intrinsic table. Used by import resolution to expand
/// wildcard imports (`import kotlin.math.*`).
pub const SymbolNameIterator = struct {
    registry_i: usize = 0,
    hand: implementations.FqnIterator = .{},

    pub fn next(self: *SymbolNameIterator) ?[]const u8 {
        const syms = generated.stdlibSymbols();
        if (self.registry_i < syms.len) {
            const fqn = syms[self.registry_i].fqn;
            self.registry_i += 1;
            return fqn;
        }
        return self.hand.next();
    }
};

pub fn allSymbolNames() SymbolNameIterator {
    return .{};
}

pub const Coverage = struct {
    implemented: usize,
    total: usize,

    pub fn percent(self: Coverage) f64 {
        if (self.total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.implemented)) * 100.0 / @as(f64, @floatFromInt(self.total));
    }
};

pub fn coverage() Coverage {
    const syms = generated.stdlibSymbols();
    var registry_count: usize = 0;
    for (syms) |e| {
        if (e.impl_fn != null) registry_count += 1;
    }
    return .{
        .implemented = registry_count + implementations.COUNT,
        .total = syms.len,
    };
}

/// Look up a hand-written intrinsic by FQN. Used by the interpreter to
/// dispatch qualified calls (`kotlin.math.abs`) and member access on builtin
/// types (`<typeFQN>.<name>`).
pub fn implementation(fqn: []const u8) ?StdlibFn {
    return implementations.lookup(fqn);
}

/// Registry of native bindings — `host_symbol` -> `StdlibFn`. A pack carries
/// the FQN -> `host_symbol` mapping; the host populates this registry with the
/// actual function pointers; the interpreter joins them at load time.
pub const HostBindings = struct {
    table: std.StringHashMapUnmanaged(StdlibFn) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HostBindings {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *HostBindings) void {
        self.table.deinit(self.allocator);
        self.* = undefined;
    }

    /// Build a registry pre-populated with every FQN this build of the stdlib
    /// knows how to handle.
    pub fn withStdlibDefaults(allocator: std.mem.Allocator) std.mem.Allocator.Error!HostBindings {
        var out = HostBindings.init(allocator);
        var it = implementations.allFqns();
        while (it.next()) |fqn| {
            if (implementations.lookup(fqn)) |f| {
                try out.register(fqn, f);
            }
        }
        for (generated.stdlibSymbols()) |entry| {
            if (entry.impl_fn) |f| {
                try out.register(entry.fqn, f);
            }
        }
        return out;
    }

    pub fn register(self: *HostBindings, host_symbol: []const u8, f: StdlibFn) std.mem.Allocator.Error!void {
        try self.table.put(self.allocator, host_symbol, f);
    }

    pub fn resolve(self: *const HostBindings, host_symbol: []const u8) ?StdlibFn {
        return self.table.get(host_symbol);
    }

    pub fn len(self: *const HostBindings) usize {
        return self.table.count();
    }

    pub fn isEmpty(self: *const HostBindings) bool {
        return self.table.count() == 0;
    }
};

/// Look up the declared parameter names for a function FQN. The interpreter
/// uses this to reorder named-argument calls before dispatching the intrinsic.
/// Returns `null` when no entry exists or when the FQN names a non-function
/// symbol.
pub fn paramNames(fqn: []const u8) ?[]const []const u8 {
    // Hand-impl table wins.
    if (implementations.lookupParamNames(fqn)) |p| return p;
    if (directParamLookup(fqn)) |p| return p;
    // Our dispatch synthesizes FQNs like `kotlin.collections.List.joinToString`
    // for member calls on a `List`, but the upstream surface stores the
    // extension form `kotlin.collections.joinToString`. Strip the
    // second-to-last segment (the receiver type) and retry once.
    var parts_buf: [32][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, fqn, '.');
    while (it.next()) |p| {
        if (n >= parts_buf.len) return null;
        parts_buf[n] = p;
        n += 1;
    }
    if (n >= 3) {
        var alt_buf: [256]u8 = undefined;
        var alt_len: usize = 0;
        for (parts_buf[0..n], 0..) |p, i| {
            if (i == n - 2) continue;
            if (alt_len != 0) {
                if (alt_len >= alt_buf.len) return null;
                alt_buf[alt_len] = '.';
                alt_len += 1;
            }
            if (alt_len + p.len > alt_buf.len) return null;
            @memcpy(alt_buf[alt_len .. alt_len + p.len], p);
            alt_len += p.len;
        }
        if (directParamLookup(alt_buf[0..alt_len])) |p| return p;
    }
    return null;
}

fn directParamLookup(fqn: []const u8) ?[]const []const u8 {
    // The upstream mining produces multiple rows per FQN; the first non-empty
    // hit is correct for the common case.
    for (generated.stdlibSymbols()) |e| {
        if (std.mem.eql(u8, e.fqn, fqn) and e.param_names.len != 0) {
            return e.param_names;
        }
    }
    return null;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test {
    std.testing.refAllDecls(@This());
    _ = generated;
    _ = implementations;
    _ = pack_builder;
    _ = text;
}

test "registry is non-empty" {
    try testing.expect(generated.stdlibSymbols().len != 0);
}

test "coverage consistent with total" {
    const c = coverage();
    try testing.expectEqual(generated.stdlibSymbols().len, c.total);
    try testing.expect(c.implemented <= c.total);
}

test "lookup returns null for unknown" {
    try testing.expect(lookup("definitely.not.a.real.kotlin.symbol") == null);
}

test "implicitly imported packages match spec list" {
    const expected = [_][]const u8{
        "kotlin",
        "kotlin.annotation",
        "kotlin.collections",
        "kotlin.comparisons",
        "kotlin.io",
        "kotlin.ranges",
        "kotlin.sequences",
        "kotlin.text",
        "kotlin.math",
    };
    try testing.expectEqual(expected.len, IMPLICITLY_IMPORTED_PACKAGES.len);
    for (expected, IMPLICITLY_IMPORTED_PACKAGES) |a, b| {
        try testing.expectEqualStrings(a, b);
    }
    try testing.expect(isImplicitlyImportedPackage("kotlin.math"));
    try testing.expect(!isImplicitlyImportedPackage("kotlin.reflect"));
    try testing.expect(!isImplicitlyImportedPackage("kotlin.math.foo"));
}

test "noteBareNameMapping keeps the earliest-ranked package and ignores the rest" {
    var map = std.StringHashMap([]const u8).init(testing.allocator);
    defer map.deinit();
    const pkgs = [_][]const u8{ "kotlin", "kotlin.math" };
    try noteBareNameMapping(&map, &pkgs, "kotlin.math.abs");
    try testing.expectEqualStrings("kotlin.math.abs", map.get("abs").?);
    // An earlier-ranked package takes the name over a later one.
    try noteBareNameMapping(&map, &pkgs, "kotlin.abs");
    try testing.expectEqualStrings("kotlin.abs", map.get("abs").?);
    // A later-ranked arrival never displaces the earlier rank.
    try noteBareNameMapping(&map, &pkgs, "kotlin.math.abs");
    try testing.expectEqualStrings("kotlin.abs", map.get("abs").?);
    // Packages outside the list, and dotless names, are ignored.
    try noteBareNameMapping(&map, &pkgs, "other.pkg.abs");
    try testing.expectEqualStrings("kotlin.abs", map.get("abs").?);
    try noteBareNameMapping(&map, &pkgs, "abs");
    try testing.expectEqual(@as(usize, 1), map.count());
}

test "the inline shadow set's name domain comes from the shared constructor" {
    // The lowerer derives `shadowed_inline_names` from
    // `noteBareNameMapping` over `IMPLICITLY_IMPORTED_PACKAGES`; pin two
    // production-load-bearing members of that domain and one
    // non-implicit exclusion. `synchronized` is deliberately NOT a member:
    // it is an inline actual that splices (so its block can suspend), not a
    // host binding, so its name must remain expandable.
    var map = std.StringHashMap([]const u8).init(testing.allocator);
    defer map.deinit();
    var it = implementations.allFqns();
    while (it.next()) |fqn| {
        try noteBareNameMapping(&map, &IMPLICITLY_IMPORTED_PACKAGES, fqn);
    }
    try testing.expect(map.contains("listOf"));
    try testing.expect(map.contains("arrayOf"));
    try testing.expect(!map.contains("synchronized"));
    // kotlin.concurrent is not implicitly imported.
    try testing.expect(!map.contains("thread"));
}

test "is known package covers coroutines" {
    try testing.expect(isKnownPackage("kotlin.coroutines"));
    try testing.expect(isKnownPackage("kotlin.coroutines.intrinsics"));
    try testing.expect(!isKnownPackage("kotlin.bogus"));
}

test "coroutine core types present" {
    const fqns = [_][]const u8{
        "kotlin.coroutines.Continuation",
        "kotlin.coroutines.CoroutineContext",
        "kotlin.coroutines.EmptyCoroutineContext",
        "kotlin.coroutines.ContinuationInterceptor",
        "kotlin.coroutines.intrinsics.suspendCoroutineUninterceptedOrReturn",
        "kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED",
    };
    for (fqns) |fqn| {
        try testing.expect(lookup(fqn) != null);
    }
}

test "register known package is recognised" {
    try testing.expect(!isKnownPackage("myorg.crypto"));
    registerKnownPackage("myorg.crypto");
    try testing.expect(isKnownPackage("myorg.crypto"));
}

test "host bindings with stdlib defaults" {
    var b = try HostBindings.withStdlibDefaults(testing.allocator);
    defer b.deinit();
    try testing.expect(!b.isEmpty());
    try testing.expect(b.resolve("kotlin.math.abs") != null);
    try testing.expect(b.resolve("not.a.symbol") == null);
}

test "is array builder and toplevel function" {
    try testing.expect(isArrayBuilder("intArrayOf"));
    try testing.expect(!isArrayBuilder("listOf"));
    try testing.expect(isToplevelFunction("listOf"));
    try testing.expect(!isToplevelFunction("to"));
    try testing.expect(!isToplevelFunction("Pair"));
    // Control / precondition intrinsics are top-level functions: member
    // dispatch must not prepend a receiver to their value parameter.
    try testing.expect(isToplevelFunction("error"));
    try testing.expect(isToplevelFunction("check"));
    try testing.expect(isToplevelFunction("require"));
    try testing.expect(isToplevelFunction("requireNotNull"));
    try testing.expect(isToplevelFunction("checkNotNull"));
    try testing.expect(isToplevelFunction("TODO"));
    try testing.expect(isToplevelFunction("assert"));
}

test "binary math functions are not property accessors" {
    try testing.expect(isBinaryMathFunction("min"));
    try testing.expect(isBinaryMathFunction("max"));
    // Single-receiver math accessors stay property-eligible.
    try testing.expect(!isBinaryMathFunction("absoluteValue"));
    try testing.expect(!isBinaryMathFunction("sign"));
    try testing.expect(!isBinaryMathFunction("minOf"));
    try testing.expect(!isBinaryMathFunction("length"));
}
