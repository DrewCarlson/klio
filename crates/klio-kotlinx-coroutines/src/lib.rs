//! Native bindings for `kotlinx.coroutines`.
//!
//! klio runs single-threaded, so `runBlocking`, `launch`, and
//! `async` execute their blocks to completion immediately on the
//! caller's stack. The high-level API (Dispatchers, CoroutineScope,
//! Job, Channel) lives in the Kotlin shim. The only thing the host
//! needs to supply is `delay(millis: Long)` — sleeping via the
//! standard library so a long-running `runBlocking` block does not
//! spin the CPU.

use std::time::Duration;

use klio_runtime::{CallCtx, RuntimeError, Value};

klio_stdlib::host_bindings! {
    pub fn host_bindings() {
        "kotlinx.coroutines.__kxco_delayMillis" => delay_millis,
    }
}

fn delay_millis(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let ms = match ctx.args.first() {
        Some(Value::Long(l)) => *l,
        Some(Value::Int(i)) => *i as i64,
        _ => {
            return Err(RuntimeError::Type(
                "kotlinx.coroutines.delay: argument must be Long".into(),
            ))
        }
    };
    if ms > 0 {
        std::thread::sleep(Duration::from_millis(ms as u64));
    }
    Ok(Value::Unit)
}
