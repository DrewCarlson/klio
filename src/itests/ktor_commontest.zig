//! ktor's own `commonTest` sources (self-contained library modules) run through
//! a child `klio test` against the installed ktor pack + deps.
//! See `commontest_support.zig`.

const support = @import("commontest_support.zig");

test "ktor commonTest pass count holds at or above the ratchet baseline" {
    try support.runSuite(.{
        .name = "ktor",
        .test_roots = &.{
            "kotlin-klio/klio-ktor/upstream/ktor-io/common/test",
            "kotlin-klio/klio-ktor/upstream/ktor-utils/common/test",
            "kotlin-klio/klio-ktor/upstream/ktor-http/common/test",
        },
        .scratch_home = "/tmp/klio_itest_ktor_home",
        .packs = &.{
            .{ .dir = "kotlin-klio/klio-kotlin-test", .artifact = "target/packs/kotlin.test.klio-pack" },
            .{ .dir = "kotlin-klio/klio-kotlinx-atomicfu", .artifact = "target/packs/kotlinx.atomicfu.klio-pack" },
            .{ .dir = "kotlin-klio/klio-kotlinx-io", .artifact = "target/packs/kotlinx.io.klio-pack" },
            .{ .dir = "kotlin-klio/klio-kotlinx-coroutines", .artifact = "target/packs/kotlinx.coroutines.klio-pack" },
            .{ .dir = "kotlin-klio/klio-ktor", .artifact = "target/packs/io.ktor.klio-pack" },
        },
        // Measured solo: 448 passed / 2 failed / 0 incomplete. The floor is a minimum pass
        // count; the ceilings bound the red mass so a fixed case
        // traded for a broken one cannot pass unnoticed. Lower the
        // ceilings as fixes land, never raise them.
        .baseline = 448,
        // Measured 2. Both are `URLBuilderTest.testParseSchemeWith{Digits,
        // DotsPlusAndMinusSigns}`, and both are UPSTREAM VERSION SKEW in the
        // sparse checkout rather than interpreter gaps: the tests expect a
        // scheme to admit digits and `.+-` (RFC 3986:
        // ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )), while the checked-out
        // `URLProtocol.kt` still carries the older
        // `require(name.all { it.isLowerCase() })`, which rejects them.
        // klio's `Char.isLowerCase()` is correct — `'1'.isLowerCase()` is
        // false, as on kotlinc — so the require genuinely throws. Aligning the
        // submodule pin is the fix; do NOT touch the test or the source.
        // Held one above the stable count. Three consecutive censuses gave
        // 2, 2, then 3: `WriterReaderTest` fails intermittently (the known
        // writer/reader stall), while the two URLBuilderTest cases below are
        // deterministic. A ceiling at 2 would red the gate on roughly a
        // third of runs; failing test names are printed, so a genuine new
        // failure is still identifiable rather than absorbed.
        .max_failed = 3,
        .max_incomplete = 2,
    });
}
