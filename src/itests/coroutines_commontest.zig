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
        // Upstream's commonTest files all extend `TestBase` from
        // `kotlinx.coroutines.testing` and route every case through its
        // `runTest`/`expect`/`finish` helpers. Those live in the pack's
        // `[[test]]` roots, which the child never sees — so without them
        // 84% of the suite failed on the support surface rather than on
        // coroutine behavior (350 passed / 897 failed; the payloads were
        // `runTest`, `TestException`, `hang`, `finish`, `expectUnreached`
        // and calls landing on `kotlin.Nothing`). Feeding them in as
        // support takes the same census to 1073 passed / 141 failed.
        .extra_support = &.{
            "kotlin-klio/klio-kotlinx-coroutines/upstream/test-utils/common/src/TestBase.common.kt",
            "kotlin-klio/klio-kotlinx-coroutines/upstream/test-utils/common/src/LaunchFlow.kt",
            "kotlin-klio/klio-kotlinx-coroutines/upstream/test-utils/common/src/MainDispatcherTestBase.kt",
            "kotlin-klio/klio-kotlinx-coroutines/klioTestUtils/kotlinx/coroutines/testing/TestBase.kt",
        },
        // Census floor: 1073 solo with the support surface wired. The
        // ratchet leaves headroom for the loaded `test-all`.
        .baseline = 1040,
    });
}
