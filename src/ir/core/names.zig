const std = @import("std");
const applicability = @import("applicability");
const Allocator = std.mem.Allocator;

/// A known stdlib host-served global alias (`min`, `listOf`, …). A bare call
/// to such a name whose overload set has no applicable body candidate routes
/// to the runtime global rather than a declared-arity fallback. Shared by
/// `resolveCall` (the Phase-B fallback gate) and the lowerer's alias /
/// value-ref paths so both classify the same names.
///
/// This name list is a cataloged hatch (resolution-unification plan, RC-H /
/// P10). A registry-derived replacement was attempted and measured unsound
/// three ways: the intrinsic registry maps FQNs to function pointers with no
/// declaration shape, so it cannot distinguish a value-position global
/// (`kotlin.collections.listOf`) from a package-level link binding for a
/// bodyless receiver-formed declaration (`kotlin.text.nativeIndexOf` binds
/// `String.nativeIndexOf`), and the implicit-alias table covers only part of
/// this surface (`reverseOrder`, the array builders are absent). The
/// classification these call sites need lives in DECLARATIONS the current
/// pipeline drops — P10 (the no-holes symbol table) restores those
/// declarations and deletes this list outright.
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

/// Whether every argument shape is positional (no named argument) — the
/// `allNull(arg_names)` gate a tail-call / trailing-lambda binding needs.
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

/// True when `head` is the first dotted segment of `fqn` and `fqn` has
/// at least one further segment — i.e. `fqn` is `head.<rest>`, so `head`
/// is a package prefix of a real symbol rather than the symbol's own
/// simple name.
pub fn fqnHasHeadSegment(fqn: []const u8, head: []const u8) bool {
    return fqn.len > head.len and
        std.mem.startsWith(u8, fqn, head) and
        fqn[head.len] == '.';
}

/// Insert every dot-aligned prefix of `fqn` — exactly the `head` values
/// `fqnHasHeadSegment(fqn, head)` accepts — into `set`. Keys alias `fqn`,
/// which outlives the module's lookup caches.
pub fn insertFqnPrefixes(set: *std.StringHashMapUnmanaged(void), gpa: Allocator, fqn: []const u8) Allocator.Error!void {
    for (fqn, 0..) |ch, i| {
        if (ch == '.') try set.put(gpa, fqn[0..i], {});
    }
}

/// The declaring package of a top-level decl whose fully-qualified name
/// is `fqn` and whose simple name is `simple`: the FQN with its trailing
/// `.{simple}` stripped, the empty string when the FQN equals the simple
/// name (no package header). One uniform derivation — `""` is the
/// no-package case, not a separate branch.
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

/// Whether `pkg` names a package the runtime ships (the embedded stdlib,
/// the kotlinx packs, java interop): its head segment is `kotlin`,
/// `kotlinx`, or `java`. Classifies a declaration by its declaring
/// package — the same field the scope tiers rank on — so user-package
/// candidates outrank shipped ones in the order-based fallbacks.
pub fn isShippedPackage(pkg: []const u8) bool {
    return pkgHeadIs(pkg, "kotlin") or pkgHeadIs(pkg, "kotlinx") or pkgHeadIs(pkg, "java");
}

/// Whether an FQN's head segment marks a shipped declaration (stdlib,
/// kotlinx pack, java interop). The runtime class registry's simple-name
/// view ranks a user class above a shipped one for the same simple name.
pub fn shippedFqnHead(fqn: []const u8) bool {
    return isShippedPackage(fqn);
}

pub fn pkgHeadIs(pkg: []const u8, head: []const u8) bool {
    if (!std.mem.startsWith(u8, pkg, head)) return false;
    return pkg.len == head.len or pkg[head.len] == '.';
}

/// Index into a slice by a `u32` id, returning a pointer or `null`
/// when out of range.
pub fn idGet(comptime T: type, items: []const T, idx: u32) ?*const T {
    if (idx >= items.len) return null;
    return &items[idx];
}
