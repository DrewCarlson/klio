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
        .scratch_home = "/tmp/klio_itest_io_home",
        .packs = &.{
            .{ .dir = "kotlin-klio/klio-kotlin-test", .artifact = "target/packs/kotlin.test.klio-pack" },
            .{ .dir = "kotlin-klio/klio-kotlinx-io", .artifact = "target/packs/kotlinx.io.klio-pack" },
        },
        // Measured solo: 1157 passed / 34 failed / 0 incomplete. The floor is a minimum pass
        // count; the ceilings bound the red mass so a fixed case
        // traded for a broken one cannot pass unnoticed. Lower the
        // ceilings as fixes land, never raise them.
        .baseline = 1150,
        .max_failed = 45,
        .max_incomplete = 2,
    });
}
