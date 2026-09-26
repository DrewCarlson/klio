//! lifecycle-viewmodel's upstream commonTest through a child `klio test`.
//! Config: `commontest_support.suites`.

const support = @import("commontest_support.zig");

test "lifecycle viewmodel commonTest pass count holds at or above the ratchet baseline" {
    try support.runSuiteNamed("lifecycle_viewmodel");
}
