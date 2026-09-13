//! The compose ui modules' upstream suites through a child `klio test`.
//! Config: `commontest_support.suites`.

const support = @import("commontest_support.zig");

test "compose ui commonTest pass count holds at or above the ratchet baseline" {
    try support.runSuiteNamed("compose_ui");
}
