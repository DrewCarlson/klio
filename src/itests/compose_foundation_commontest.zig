//! foundation's upstream skikoTest and commonTest through a child `klio test`,
//! over the ui-test harness.
//! Config: `commontest_support.suites`.

const support = @import("commontest_support.zig");

test "compose foundation skikoTest pass count holds at or above the ratchet baseline" {
    try support.runSuiteNamed("compose_foundation");
}
