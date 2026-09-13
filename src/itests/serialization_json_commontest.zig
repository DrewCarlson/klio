//! kotlinx-serialization's JSON suite (`formats/json-tests`) through a child
//! `klio test` with the pack's `json` feature. Config: `commontest_support.suites`.

const support = @import("commontest_support.zig");

test "kotlinx.serialization json-tests pass count holds at or above the ratchet baseline" {
    try support.runSuiteNamed("serialization_json");
}
