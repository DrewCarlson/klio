//! kotlinx.atomicfu's own `commonTest` sources run through a child `klio test`
//! against the installed `kotlinx.atomicfu` pack. See `commontest_support.zig`.

const support = @import("commontest_support.zig");

test "kotlinx.atomicfu commonTest pass count holds at or above the ratchet baseline" {
    try support.runSuite(.{
        .name = "atomicfu",
        .test_roots = &.{
            "kotlin-klio/klio-kotlinx-atomicfu/upstream/atomicfu/src/commonTest/kotlin",
        },
        .scratch_home = "/tmp/klio_itest_atomicfu_home",
        .packs = &.{
            .{ .dir = "kotlin-klio/klio-kotlin-test", .artifact = "target/packs/kotlin.test.klio-pack" },
            .{ .dir = "kotlin-klio/klio-kotlinx-atomicfu", .artifact = "target/packs/kotlinx.atomicfu.klio-pack" },
        },
        .baseline = 63,
    });
}
