//! Contract-effect catalogue consumed by the lowering. Contracts
//! describe a function's effect on the surrounding flow: a
//! precondition that holds on the post-call path, a lambda that runs
//! a specific number of times, or a smart-cast established by a
//! runtime check.
//!
//! Stdlib contracts live in `stdlibContract` (hardcoded by simple
//! name). User contracts declared via `kotlin.contracts.contract { … }`
//! populate the user-inline-contract registry before lowering — the
//! build pass walks every `inline fun` body once for the contract
//! block and records each `callsInPlace(blockName, EXACTLY_ONCE)` it
//! finds. The lowering then treats a call to that user fn the same
//! way it treats a `let { … }` call.

const std = @import("std");

/// One effect a contract imposes on the call site's post-call state.
/// Multiple effects can apply to the same call (e.g. a function that
/// both narrows its first argument and propagates the second
/// argument's refinement).
pub const ContractEffect = union(enum) {
    /// `arg(arg_idx)` is non-null after this call returns normally.
    /// Modeled as an `AssumeNull(eq_null=false)` on the arg's reg.
    AssumeNonNull: struct { arg_idx: usize },
    /// The condition expression at `arg(arg_idx)` holds after the
    /// call returns normally. Any `AssumeIs` / `AssumeNull` /
    /// `AssumeRefEq` refinement the lowering recorded for that
    /// register is replayed on the post-call block.
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

/// User-declared `contract { callsInPlace(p, EXACTLY_ONCE) }`
/// records, keyed by the inline fn's simple name. Each value lists
/// the parameter names that are invoked exactly once on the normal
/// path. The lowering uses this to extend its trailing-lambda inline
/// scheme to user contracts.
pub const UserInlineContracts = std.StringHashMap([]const []const u8);

/// User-declared `contract { callsInPlace(p, EXACTLY_ONCE) }` records,
/// keyed by the inline fn's simple name. Each value lists the parameter
/// names that are invoked exactly once on the normal path (Kotlin's
/// `InvocationKind.EXACTLY_ONCE`). The lowering uses this to extend its
/// trailing-lambda inline scheme to user contracts so a `val` assigned
/// inside the lambda is observed as definitely assigned at the call site.
///
/// Rust modelled this as a `thread_local!` cell installed by the build
/// driver before lowering; the port keeps the same single-build-at-a-time
/// contract with module-level state.
var user_inline_contracts: ?UserInlineContracts = null;

/// Replace the user-contract registry. Called once per module build,
/// before any per-function lowering starts. Passing an empty map
/// effectively clears the registry between modules. Takes ownership of
/// `map`; any previously-installed registry is freed.
pub fn setUserInlineContracts(map: UserInlineContracts) void {
    if (user_inline_contracts) |*old| old.deinit();
    user_inline_contracts = map;
}

/// Lookup the param names of the user inline fn `name` whose contract
/// declares `callsInPlace(p, EXACTLY_ONCE)`. Empty when no user
/// contract is registered for that name.
pub fn userExactlyOnceParams(name: []const u8) []const []const u8 {
    if (user_inline_contracts) |*c| {
        if (c.get(name)) |params| return params;
    }
    return &.{};
}

/// Release the installed user-contract registry. Used by tests and by a
/// build driver tearing down between builds.
pub fn resetForTest() void {
    if (user_inline_contracts) |*m| {
        m.deinit();
        user_inline_contracts = null;
    }
}

/// Lookup table for stdlib functions that participate in contract
/// effects. The returned slice lists every effect to emit on the
/// post-call path.
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
    // Empty registry yields no params.
    try testing.expectEqual(@as(usize, 0), userExactlyOnceParams("run").len);

    var map = UserInlineContracts.init(testing.allocator);
    const params = [_][]const u8{"block"};
    try map.put("withResource", &params);
    setUserInlineContracts(map);

    const got = userExactlyOnceParams("withResource");
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("block", got[0]);
    try testing.expectEqual(@as(usize, 0), userExactlyOnceParams("missing").len);

    // Replacing with an empty map clears the registry.
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
