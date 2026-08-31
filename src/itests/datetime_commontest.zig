//! kotlinx-datetime's own `commonTest` sources run through a child `klio test`
//! against the installed `kotlinx.datetime` pack. See `commontest_support.zig`.
//!
//! The suite CONFIG (roots, packs, ratchet floors/ceilings) lives in the
//! shared registry `commontest_support.suites` — one source of truth for
//! this CI gate and the link-free `klio-census` driver. The ratchet
//! history that used to live here is in git; tighten floors there only.

const support = @import("commontest_support.zig");

test "kotlinx.datetime commonTest pass count holds at or above the ratchet baseline" {
    try support.runSuiteNamed("datetime");
}
