//! Small, self-contained helpers for literal handling and package-head
//! classification — kept apart from the main lowering module so that bulk
//! only carries the genuinely lowering-bound code.

const std = @import("std");
const ast = @import("ast");

const Expr = ast.Expr;
const TypeRef = ast.TypeRef;

/// A bare identifier is a package head when it's lowercase (Kotlin
/// package names are lowercase by convention) or one of the primitive
/// companion roots whose `MAX_VALUE` / `MIN_VALUE` / `SIZE_BITS`
/// constants are routed through `primitive_companion_const`.
pub fn isPackageHead(name: []const u8) bool {
    if (name.len != 0 and std.ascii.isLower(name[0])) return true;
    const roots = [_][]const u8{
        "Int",   "Long",  "Short", "Byte",    "UInt",   "ULong",
        "UShort", "UByte", "Float", "Double", "Char",   "Boolean",
        "String",
    };
    for (roots) |r| {
        if (std.mem.eql(u8, name, r)) return true;
    }
    return false;
}

/// A genuine top-level package root. [`isPackageHead`] treats any
/// lowercase identifier as a package head, which misfires inside a
/// receiver lambda where an unresolved lowercase name is actually a
/// member of the lexically enclosing `this@Outer`. Restrict the
/// FQN-flattening paths to these real roots.
pub fn isPkgRoot(name: []const u8) bool {
    const roots = [_][]const u8{
        "kotlin", "kotlinx", "java", "javax", "io", "org", "com", "net",
    };
    for (roots) |r| {
        if (std.mem.eql(u8, name, r)) return true;
    }
    return false;
}

/// Widen an integer literal whose target slot is `Long` from `Int` to
/// `Long`. Kotlin lets `val n: Long = 0` take a bare `0`; the AST still
/// encodes that as an `Int` literal because the parser cannot see the
/// target type. Without this rewrite the literal keeps its `Int` runtime
/// representation and later arithmetic truncates.
pub fn widenNumericLiteral(e: *const Expr, ty: *const TypeRef) ?Expr {
    if (ty.nullable or !std.mem.eql(u8, ty.name.name, "Long")) return null;
    return switch (e.*) {
        .IntLit => |lit| if (lit.kind == .Int)
            Expr{ .IntLit = .{ .value = lit.value, .kind = .Long, .span = lit.span } }
        else
            null,
        else => null,
    };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;
const span = @import("span");

test {
    testing.refAllDecls(@This());
}

fn dummySpan() span.Span {
    return span.Span.init(span.FileId.from(0), 0, 0);
}

test "package head classification" {
    try testing.expect(isPackageHead("kotlin"));
    try testing.expect(isPackageHead("Int"));
    try testing.expect(!isPackageHead("Foo"));
}

test "pkg root is restricted set" {
    try testing.expect(isPkgRoot("kotlin"));
    try testing.expect(!isPkgRoot("twin"));
}

test "widen long literal" {
    const ty = TypeRef{
        .name = .{ .name = "Long", .span = dummySpan() },
        .nullable = false,
        .span = dummySpan(),
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
    const e = Expr{ .IntLit = .{ .value = 0, .kind = .Int, .span = dummySpan() } };
    const widened = widenNumericLiteral(&e, &ty).?;
    try testing.expectEqual(ast.IntLitKind.Long, widened.IntLit.kind);
}

test "no widen for non-long target" {
    const ty = TypeRef{
        .name = .{ .name = "Int", .span = dummySpan() },
        .nullable = false,
        .span = dummySpan(),
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
    const e = Expr{ .IntLit = .{ .value = 0, .kind = .Int, .span = dummySpan() } };
    try testing.expect(widenNumericLiteral(&e, &ty) == null);
}
