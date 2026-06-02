use super::{CallCtx, Value, RuntimeError};

/// Wall-clock time in milliseconds since the Unix epoch. Backs the
/// `systemClockNow()` / `serializedInstant` klio `actual`s for the
/// upstream `kotlin.time` commonMain `Clock.System` / `Instant`.
pub(crate) fn time_system_millis(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let millis = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as i64);
    Ok(Value::Long(millis))
}

/// A monotonically non-decreasing reading in nanoseconds. Only
/// differences between readings are meaningful; the upstream
/// `MonotonicTimeSource` actual fixes a "zero" on first read. Backs
/// `TimeSource.Monotonic` / `markNow()`.
pub(crate) fn time_monotonic_nanos(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    use std::sync::OnceLock;
    use std::time::Instant;
    static ORIGIN: OnceLock<Instant> = OnceLock::new();
    let origin = *ORIGIN.get_or_init(Instant::now);
    let nanos = origin.elapsed().as_nanos();
    Ok(Value::Long(i64::try_from(nanos).unwrap_or(i64::MAX)))
}

/// Placeholder dispatch for a bare `Thread` sentinel value. Member
/// access (`join`, `name`, `isAlive`) is intercepted by the
/// interpreter before this is ever called; invoking the handle itself
/// is not a valid Kotlin operation.
pub(crate) fn thread_handle_stub(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Err(RuntimeError::Type(
        "Thread handle is not callable; use .join() / .name / .isAlive".into(),
    ))
}
