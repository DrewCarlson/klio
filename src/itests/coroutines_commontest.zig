//! kotlinx-coroutines' own `commonTest` sources run through a child `klio test`
//! against the installed `kotlinx.coroutines` pack. See `commontest_support.zig`.

const support = @import("commontest_support.zig");

test "kotlinx.coroutines commonTest pass count holds at or above the ratchet baseline" {
    try support.runSuite(.{
        .name = "coroutines",
        .test_roots = &.{
            "kotlin-klio/klio-kotlinx-coroutines/upstream/kotlinx-coroutines-core/common/test",
        },
        .scratch_home = "/tmp/klio_itest_coroutines_home",
        .packs = &.{
            .{ .dir = "kotlin-klio/klio-kotlin-test", .artifact = "target/packs/kotlin.test.klio-pack" },
            .{ .dir = "kotlin-klio/klio-kotlinx-atomicfu", .artifact = "target/packs/kotlinx.atomicfu.klio-pack" },
            .{ .dir = "kotlin-klio/klio-kotlinx-coroutines", .artifact = "target/packs/kotlinx.coroutines.klio-pack" },
        },
        // 237 pass when the suite runs alone (was 118 before `yield` reached its
        // dispatcher); the ratchet leaves headroom for the loaded `test-all`.
        .baseline = 220,
    });
}
