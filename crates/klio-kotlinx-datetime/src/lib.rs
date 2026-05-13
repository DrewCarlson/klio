//! Native bindings for `kotlinx-datetime`.
//!
//! The full library surface decomposes into `Instant`, `LocalDate`,
//! `LocalDateTime`, `LocalTime`, `TimeZone`, `Clock`, and the
//! arithmetic operations on each. The native bindings registered
//! here back the wall-clock and time-zone-resolution entry points
//! with the `chrono` crate, which already covers calendar maths,
//! leap-year handling, and IANA tz-data parsing. The interpreted
//! Kotlin from the pack covers the high-level API surface and DSL.

use klio_stdlib::HostBindings;

#[must_use]
pub fn host_bindings() -> HostBindings {
    HostBindings::new()
}
