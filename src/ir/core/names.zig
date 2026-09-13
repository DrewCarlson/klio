const std = @import("std");
const applicability = @import("applicability");
const Allocator = std.mem.Allocator;

/// A stdlib host-served global alias (`min`, `listOf`, ...). A bare call to such
/// a name whose overload set has no applicable body candidate routes to the runtime
/// global rather than a declared-arity fallback. `resolveCall` and the lowerer share
/// this list so both classify the same names.
pub fn isAliasName(name: []const u8) bool {
    const names = [_][]const u8{
        "maxOf",           "minOf",      "max",                 "min",
        "print",           "println",    "listOf",              "mutableListOf",
        "arrayListOf",     "setOf",      "mutableSetOf",        "hashSetOf",
        "linkedSetOf",     "mapOf",      "mutableMapOf",        "hashMapOf",
        "linkedMapOf",     "arrayOf",    "arrayOfNulls",        "emptyArray",
        "emptyList",       "emptySet",   "emptyMap",            "listOfNotNull",
        "setOfNotNull",    "buildList",  "buildSet",            "buildMap",
        "buildString",     "TODO",       "error",               "compareValues",
        "compareValuesBy", "compareBy",  "compareByDescending", "naturalOrder",
        "reverseOrder",    "sequenceOf", "emptySequence",       "generateSequence",
        "sequence",        "iterator",   "readLine",            "sortedSetOf",
        "sortedMapOf",
    };
    for (names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

pub fn allShapeNamesNull(args: []const applicability.ArgShape) bool {
    for (args) |a| {
        if (a.named != null) return false;
    }
    return true;
}

pub fn callShapesHaveComposerPair(args: []const applicability.ArgShape) bool {
    if (args.len < 2) return false;
    const composer = args[args.len - 2].named orelse return false;
    const changed = args[args.len - 1].named orelse return false;
    return std.mem.eql(u8, composer, "$composer") and
        std.mem.eql(u8, changed, "$changed");
}

/// True when `fqn` is `head.<rest>`: `head` is a package prefix of a real symbol,
/// not the symbol's own simple name.
pub fn fqnHasHeadSegment(fqn: []const u8, head: []const u8) bool {
    return fqn.len > head.len and
        std.mem.startsWith(u8, fqn, head) and
        fqn[head.len] == '.';
}

/// Insert every dot-aligned prefix of `fqn` into `set`. Keys alias `fqn`, which
/// outlives the module's lookup caches.
pub fn insertFqnPrefixes(set: *std.StringHashMapUnmanaged(void), gpa: Allocator, fqn: []const u8) Allocator.Error!void {
    for (fqn, 0..) |ch, i| {
        if (ch == '.') try set.put(gpa, fqn[0..i], {});
    }
}

/// Declaring package of the top-level decl `fqn` whose simple name is `simple`:
/// the FQN minus its trailing `.{simple}`, or `""` when there is no package header.
pub fn packageOfFqn(fqn: []const u8, simple: []const u8) []const u8 {
    if (std.mem.eql(u8, fqn, simple)) return "";
    if (fqn.len > simple.len + 1 and
        std.mem.endsWith(u8, fqn, simple) and
        fqn[fqn.len - simple.len - 1] == '.')
    {
        return fqn[0 .. fqn.len - simple.len - 1];
    }
    if (std.mem.findScalarLast(u8, fqn, '.')) |dot| return fqn[0..dot];
    return "";
}

/// Whether `pkg` heads with `kotlin`, `kotlinx`, or `java`, the packages the runtime
/// ships. User-package candidates outrank shipped ones in the order-based fallbacks.
pub fn isShippedPackage(pkg: []const u8) bool {
    return pkgHeadIs(pkg, "kotlin") or pkgHeadIs(pkg, "kotlinx") or pkgHeadIs(pkg, "java");
}

pub fn shippedFqnHead(fqn: []const u8) bool {
    return isShippedPackage(fqn);
}

pub fn pkgHeadIs(pkg: []const u8, head: []const u8) bool {
    if (!std.mem.startsWith(u8, pkg, head)) return false;
    return pkg.len == head.len or pkg[head.len] == '.';
}

pub fn idGet(comptime T: type, items: []const T, idx: u32) ?*const T {
    if (idx >= items.len) return null;
    return &items[idx];
}
