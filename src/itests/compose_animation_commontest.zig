//! animation-core's upstream commonTest through a child `klio test`.
//! Config: `commontest_support.suites`.

const support = @import("commontest_support.zig");

test "compose animation commonTest pass count holds at or above the ratchet baseline" {
    try support.runSuiteNamed("compose_animation");
}
