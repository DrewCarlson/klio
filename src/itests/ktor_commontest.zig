//! ktor's own `commonTest` sources through a child `klio test`.
//! Roots, packs, and ratchet bounds live in `commontest_support.suites`.

const support = @import("commontest_support.zig");

test "ktor commonTest pass count holds at or above the ratchet baseline" {
    try support.runSuiteNamed("ktor");
}
