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
        .whole_source_set = true,
        // `LocalDateTest.fromEpochDays` walks ~1.4M epoch days building a
        // LocalDate per step; interpreted that is ~3 minutes of pure compute,
        // and the default 60s budget dropped the whole file's results.
        .timeout_ms = 400_000,
        // Measured solo: 457 passed / 62 failed / 0 incomplete. The floor is a
        // minimum pass count; the ceilings bound the red mass so a fixed case
        // traded for a broken one cannot pass unnoticed. Lower the ceilings as
        // fixes land, never raise them.
        .baseline = 464,
        // 70 -> 59: a call binding by class id is now treated as a
        // construction, so `LocalDateTime(y, m, d, h, min)` reaches the
        // constructor instead of the published companion's `invoke`.
        .max_failed = 55,
        .max_incomplete = 1,
    });
}
