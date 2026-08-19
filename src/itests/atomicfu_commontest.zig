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
        // Measured solo: 63 passed / 4 failed / 0 incomplete. The floor is a minimum pass
        // count; the ceilings bound the red mass so a fixed case
        // traded for a broken one cannot pass unnoticed. Lower the
        // ceilings as fixes land, never raise them.
        // Upstream's test sources are ONE compilation unit: `C.kt` uses `D` from
        // `D.kt`, `GetArrayElementTest` uses `AtomicArrayClass`, and
        // `SetArrayElementTest` uses `IntBox` — each declared in a sibling file
        // that carries its own `@Test`s, so the default one-target-per-child
        // model cannot see them and they resolve to nothing.
        .whole_source_set = true,
        .baseline = 67,
        // Zero: with the whole source set compiled, every case that runs
        // passes (67/0/0 measured), so any failure is a real regression.
        .max_failed = 0,
        .max_incomplete = 2,
    });
}
