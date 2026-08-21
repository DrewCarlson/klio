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
        //
        // 1105 -> 1185 and 106 -> 58 after the harness stopped starving a
        // test file of the base class / helper file it extends, and six
        // interpreter roots landed (nested-class references, file-private
        // function binding, inferred receiver-function parameters, the
        // function-shape extension overload, the flow context-preservation
        // invariant, null channel elements). Measured on the gate:
        // 1192 passed, 52 failed, 6 did not complete.
        // 1070 -> 1105 alongside the ceiling below. Measured solo: 1110.
        .baseline = 1185,
        // Bound the red mass too: a floor alone cannot see a fixed case
        // traded for a broken one. Measured solo: 137 failing, 6 not
        // completing. Lower these as fixes land, never raise them.
        // 150 -> 141. Measured 1075 passed / 139 failed / 6 did not complete
        // after bare calls stopped splicing a receiverless inline candidate
        // when a non-inline extension fits the receiver in scope. Held two
        // above the measurement: this suite's dispatched tests vary by a
        // couple between runs.
        // 141 -> 106. Two roots: a bare call inside an extension no longer
        // binds a same-named extension via the enclosing receiver (combine's
        // Iterable overload), and a call no longer reaches a same-named local
        // whose initializer is an ordinary function call (`val flow =
        // flowOf(...)` beside the `flow { … }` builder). Measured solo: 1110
        // passed, 104 failed, 6 did not complete. Held two above.
        .max_failed = 58,
        .max_incomplete = 8,
    });
}
