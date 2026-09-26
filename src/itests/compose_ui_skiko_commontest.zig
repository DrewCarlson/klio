//! ui-graphics' and ui-text's upstream skikoTest through a child `klio test`.
//! Config: `commontest_support.suites`.

const support = @import("commontest_support.zig");

test "compose ui skikoTest pass count holds at or above the ratchet baseline" {
    try support.runSuiteNamed("compose_ui_skiko");
}
