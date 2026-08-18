//! kotlinx-serialization's own `commonTest` sources run through a child
//! `klio test` against the installed `kotlinx.serialization` pack.
//! See `commontest_support.zig`.

const support = @import("commontest_support.zig");

test "kotlinx.serialization commonTest pass count holds at or above the ratchet baseline" {
    try support.runSuite(.{
        .name = "serialization",
        .test_roots = &.{
            "kotlin-klio/klio-kotlinx-serialization/upstream/core/commonTest",
        },
        .scratch_home = "/tmp/klio_itest_serialization_home",
        .packs = &.{
            .{ .dir = "kotlin-klio/klio-kotlin-test", .artifact = "target/packs/kotlin.test.klio-pack" },
            .{ .dir = "kotlin-klio/klio-kotlinx-serialization", .artifact = "target/packs/kotlinx.serialization.klio-pack" },
        },
        .extra_support = &.{
            "kotlin-klio/klio-kotlinx-serialization/klioTest/kotlinx/serialization/test/CurrentPlatform.kt",
        },
        .baseline = 9,
    });
}
