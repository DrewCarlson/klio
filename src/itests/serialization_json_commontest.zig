//! kotlinx-serialization's own JSON test suite (`formats/json-tests`) run
//! through a child `klio test` against the installed `kotlinx.serialization`
//! pack with its `json` feature — the real upstream json module plus klio's
//! generated serializers. See `commontest_support.zig`; the suite CONFIG
//! (roots, packs, support shims, ratchet) lives in its shared registry.

const support = @import("commontest_support.zig");

test "kotlinx.serialization json-tests pass count holds at or above the ratchet baseline" {
    try support.runSuiteNamed("serialization_json");
}
