//! The compose ui modules' upstream conformance suites (ui-util,
//! ui-geometry, ui-unit, ui-graphics, ui-text, ui commonTest) run through
//! a child `klio test` against the installed compose ui packs. See
//! `commontest_support.zig`; the suite CONFIG (roots, packs, support
//! stand-ins, ratchet) lives in its shared registry.

const support = @import("commontest_support.zig");

test "compose ui commonTest pass count holds at or above the ratchet baseline" {
    try support.runSuiteNamed("compose_ui");
}
