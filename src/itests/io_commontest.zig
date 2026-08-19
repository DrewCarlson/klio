//! kotlinx-io's own `commonTest` sources run through a child `klio test`
//! against the installed `kotlinx.io` pack. See `commontest_support.zig`.

const support = @import("commontest_support.zig");

test "kotlinx.io commonTest pass count holds at or above the ratchet baseline" {
    try support.runSuite(.{
        .name = "io",
        .test_roots = &.{
            "kotlin-klio/klio-kotlinx-io/upstream/core/common/test",
            "kotlin-klio/klio-kotlinx-io/upstream/bytestring/common/test",
        },
        // kotlinx-io's own common test sources declare two `expect`s
        // (`tempFileName`, `String.asUtf8ToByteArray`) whose actuals live in the
        // platform test source sets upstream. klio supplies them here; without
        // them every temp-file test and every UTF-8 round-trip fails to resolve.
        .extra_support = &.{
            "kotlin-klio/klio-kotlinx-io/klioTest/kotlinx/io/TestActuals.kt",
        },
        .scratch_home = "/tmp/klio_itest_io_home",
        .packs = &.{
            .{ .dir = "kotlin-klio/klio-kotlin-test", .artifact = "target/packs/kotlin.test.klio-pack" },
            .{ .dir = "kotlin-klio/klio-kotlinx-io", .artifact = "target/packs/kotlinx.io.klio-pack" },
        },
        // Measured solo: 1157 passed / 34 failed / 0 incomplete. The floor is a minimum pass
        // count; the ceilings bound the red mass so a fixed case
        // traded for a broken one cannot pass unnoticed. Lower the
        // ceilings as fixes land, never raise them.
        .baseline = 1178,
        // 45 -> 13 once klio supplied the two `expect`s kotlinx-io's own test
        // sources declare. The remaining 13 are 11 in Utf8Test (a bare call to
        // a private vararg member read as a field), plus two singles.
        .max_failed = 13,
        .max_incomplete = 0,
    });
}
