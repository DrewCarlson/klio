//! ui's upstream skikoTest through a child `klio test`,
//! over the ui-test harness.
//! Config: `commontest_support.suites`.

const support = @import("commontest_support.zig");

test "compose ui scene skikoTest pass count holds at or above the ratchet baseline" {
    try support.runSuiteNamed("compose_ui_scene");
}
