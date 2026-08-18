//! kotlinx-datetime's own `commonTest` sources run through a child `klio test`
//! against the installed `kotlinx.datetime` pack. See `commontest_support.zig`.

const support = @import("commontest_support.zig");

test "kotlinx.datetime commonTest pass count holds at or above the ratchet baseline" {
    try support.runSuite(.{
        .name = "datetime",
        .test_roots = &.{
            "kotlin-klio/klio-kotlinx-datetime/upstream/core/common/test",
            "kotlin-klio/klio-kotlinx-datetime/upstream/core/commonKotlin/test",
        },
        .scratch_home = "/tmp/klio_itest_datetime_home",
        .packs = &.{
            .{ .dir = "kotlin-klio/klio-kotlin-test", .artifact = "target/packs/kotlin.test.klio-pack" },
            .{ .dir = "kotlin-klio/klio-kotlinx-serialization", .artifact = "target/packs/kotlinx.serialization.klio-pack" },
            .{ .dir = "kotlin-klio/klio-kotlinx-datetime", .artifact = "target/packs/kotlinx.datetime.klio-pack" },
        },
        // Measured solo: 212 passed / 291 failed / 1 incomplete. The floor is a minimum pass
        // count; the ceilings bound the red mass so a fixed case
        // traded for a broken one cannot pass unnoticed. Lower the
        // ceilings as fixes land, never raise them.
        .whole_source_set = true,
        .baseline = 210,
        .max_failed = 300,
        .max_incomplete = 5,
    });
}
