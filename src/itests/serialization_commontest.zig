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
        // Every bound below TIGHTENS the gate. The floor rises 9 -> 60 as the
        // pack widened to upstream's own serializer lookup; the two ceilings
        // are new (the suite was floor-only before), so a run that clears the
        // floor while growing failures or hangs now fails.
        //
        // 60 -> 62 and 78 -> 76: the reflective element descriptor now hands
        // back the builtin serializers' own descriptors instead of minting a
        // `PrimitiveSerialDescriptor` with a primitive's serial name, which
        // upstream rejects outright.
        //
        // 62 -> 67 and 76 -> 71: the runtime class now retains its
        // annotations' ARGUMENTS, so `@SerialName` on the class replaces the
        // qualified-name default. Measured solo: 67 passed, 71 failed, 0 did
        // not complete.
        .baseline = 67,
        .max_failed = 71,
        .max_incomplete = 0,
    });
}
