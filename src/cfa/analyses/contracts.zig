//! Contract-effect catalogue consumed by the lowering: a precondition holding
//! on the post-call path, a lambda that runs a fixed number of times, or a smart
//! cast from a runtime check. Stdlib contracts live in `stdlibContract`; a user
//! `kotlin.contracts.contract { ... }` populates the registry before lowering,
//! and a call to such a function lowers the way `let { ... }` does.

const std = @import("std");

pub const ContractEffect = union(enum) {
    /// Modeled as an `AssumeNull(eq_null=false)` on the argument's register.
    AssumeNonNull: struct { arg_idx: usize },
    /// The condition at `arg(arg_idx)` holds after a normal return: any
    /// refinement recorded for that register is replayed on the post-call block.
    AssumePredicate: struct { arg_idx: usize },

    pub fn eql(self: ContractEffect, other: ContractEffect) bool {
        if (@as(std.meta.Tag(ContractEffect), self) != @as(std.meta.Tag(ContractEffect), other)) {
            return false;
        }
        return switch (self) {
            .AssumeNonNull => |e| e.arg_idx == other.AssumeNonNull.arg_idx,
            .AssumePredicate => |e| e.arg_idx == other.AssumePredicate.arg_idx,
        };
    }
};

/// User `contract { callsInPlace(p, EXACTLY_ONCE) }` records, keyed by the
/// inline function's simple name, each value listing the parameters invoked
/// exactly once on the normal path. Lowering extends its trailing-lambda
/// inlining to them, so a `val` assigned inside the lambda is definitely
/// assigned at the call site.
pub const UserInlineContracts = std.StringHashMap([]const []const u8);

/// Module-level state under a single-build-at-a-time contract: the build driver
/// installs the registry before lowering starts.
var user_inline_contracts: ?UserInlineContracts = null;

/// Once per module build, before any per-function lowering; an empty map clears
/// it. Takes ownership of `map` and frees any prior registry.
pub fn setUserInlineContracts(map: UserInlineContracts) void {
    if (user_inline_contracts) |*old| old.deinit();
    user_inline_contracts = map;
}

/// Empty when no user contract is registered for `name`.
pub fn userExactlyOnceParams(name: []const u8) []const []const u8 {
    if (user_inline_contracts) |*c| {
        if (c.get(name)) |params| return params;
    }
    return &.{};
}

pub fn resetForTest() void {
    if (user_inline_contracts) |*m| {
        m.deinit();
        user_inline_contracts = null;
    }
}

/// Every effect to emit on the post-call path of a stdlib function.
pub fn stdlibContract(name: []const u8) []const ContractEffect {
    const nonnull = &[_]ContractEffect{.{ .AssumeNonNull = .{ .arg_idx = 0 } }};
    const require = &[_]ContractEffect{.{ .AssumePredicate = .{ .arg_idx = 0 } }};
    if (std.mem.eql(u8, name, "requireNotNull") or std.mem.eql(u8, name, "checkNotNull")) {
        return nonnull;
    }
    if (std.mem.eql(u8, name, "require") or std.mem.eql(u8, name, "check")) {
        return require;
    }
    return &.{};
}

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "stdlib contract lookup" {
    const rn = stdlibContract("requireNotNull");
    try testing.expectEqual(@as(usize, 1), rn.len);
    try testing.expect(rn[0] == .AssumeNonNull);
    try testing.expectEqual(@as(usize, 0), rn[0].AssumeNonNull.arg_idx);

    const cnn = stdlibContract("checkNotNull");
    try testing.expect(cnn[0] == .AssumeNonNull);

    const req = stdlibContract("require");
    try testing.expect(req[0] == .AssumePredicate);
    const chk = stdlibContract("check");
    try testing.expect(chk[0] == .AssumePredicate);

    try testing.expectEqual(@as(usize, 0), stdlibContract("unknown").len);
}

test "user inline contracts round-trip" {
    defer resetForTest();
    try testing.expectEqual(@as(usize, 0), userExactlyOnceParams("run").len);

    var map = UserInlineContracts.init(testing.allocator);
    const params = [_][]const u8{"block"};
    try map.put("withResource", &params);
    setUserInlineContracts(map);

    const got = userExactlyOnceParams("withResource");
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("block", got[0]);
    try testing.expectEqual(@as(usize, 0), userExactlyOnceParams("missing").len);

    setUserInlineContracts(UserInlineContracts.init(testing.allocator));
    try testing.expectEqual(@as(usize, 0), userExactlyOnceParams("withResource").len);
}

test "contract effect equality" {
    const a: ContractEffect = .{ .AssumeNonNull = .{ .arg_idx = 0 } };
    const b: ContractEffect = .{ .AssumeNonNull = .{ .arg_idx = 0 } };
    const c: ContractEffect = .{ .AssumeNonNull = .{ .arg_idx = 1 } };
    const d: ContractEffect = .{ .AssumePredicate = .{ .arg_idx = 0 } };
    try testing.expect(a.eql(b));
    try testing.expect(!a.eql(c));
    try testing.expect(!a.eql(d));
}
