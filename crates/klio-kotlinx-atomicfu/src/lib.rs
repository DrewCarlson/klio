//! Native bindings for `kotlinx.atomicfu`.
//!
//! atomicfu's runtime surface is small: `AtomicRef`, `AtomicInt`,
//! `AtomicLong`, `AtomicBoolean` and a handful of factory functions
//! per primitive (`atomic(value)`). The bindings registered here back
//! each constructor and the `compareAndSet` / `getAndSet` operations
//! with `Rc<RefCell<T>>`-style cells, matching klio's threading
//! model. The interpreted Kotlin in the pack covers the rest of the
//! surface (operators, `value` accessor, etc.).

use klio_stdlib::HostBindings;

#[must_use]
pub fn host_bindings() -> HostBindings {
    HostBindings::new()
}
