//! Native bindings for `kotlinx.coroutines`.
//!
//! klio runs single-threaded, so `runBlocking`, `launch`, and
//! `async` execute their blocks to completion immediately on the
//! caller's stack. The high-level API (Dispatchers, CoroutineScope,
//! Job, Channel) lives in the Kotlin shim. The only thing the host
//! needs to supply is `delay(millis: Long)` — sleeping via the
//! standard library so a long-running `runBlocking` block does not
//! spin the CPU.

//! Cooperative coroutines runtime backing the kotlinx.coroutines
//! shim.
//!
//! klio runs single-threaded, so the runtime is a small in-process
//! cooperative scheduler: a FIFO queue of opaque task handles plus a
//! cancellation-token registry shared between Jobs and their bodies.
//! Suspension points (delay, yield, withContext) can call back into
//! the scheduler; the Kotlin shim observes cancellation tokens
//! through `__kxco_tokenIsCancelled`.

use std::cell::RefCell;
use std::collections::HashSet;
use std::time::Duration;

use klio_runtime::{CallCtx, RuntimeError, Value};

thread_local! {
    static CANCELLED_TOKENS: RefCell<HashSet<i64>> = RefCell::new(HashSet::new());
    static NEXT_TOKEN: RefCell<i64> = const { RefCell::new(1) };
    static SCHED_QUEUE: RefCell<Vec<i64>> = const { RefCell::new(Vec::new()) };
    static PENDING_LAUNCHES: RefCell<Vec<Value>> = const { RefCell::new(Vec::new()) };
}

klio_stdlib::host_bindings! {
    pub fn host_bindings() {
        "kotlinx.coroutines.__kxco_delayMillis"        => delay_millis,
        "kotlinx.coroutines.__kxco_currentTimeMillis"  => current_time_millis,
        "kotlinx.coroutines.__kxco_tokenCreate"        => token_create,
        "kotlinx.coroutines.__kxco_tokenCancel"        => token_cancel,
        "kotlinx.coroutines.__kxco_tokenIsCancelled"   => token_is_cancelled,
        "kotlinx.coroutines.__kxco_schedulerEnqueue"   => scheduler_enqueue,
        "kotlinx.coroutines.__kxco_schedulerDrainCount" => scheduler_drain_count,
        "kotlinx.coroutines.__kxco_spawn"               => spawn_launch_block,
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

fn current_time_millis(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let t = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);
    Ok(Value::Long(t))
}

fn token_create(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let id = NEXT_TOKEN.with(|c| {
        let mut b = c.borrow_mut();
        let id = *b;
        *b = b.wrapping_add(1);
        id
    });
    Ok(Value::Long(id))
}

fn token_cancel(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let id = match ctx.args.first() {
        Some(Value::Long(l)) => *l,
        Some(Value::Int(i)) => *i as i64,
        _ => return Err(RuntimeError::Type("tokenCancel: argument must be Long".into())),
    };
    CANCELLED_TOKENS.with(|c| c.borrow_mut().insert(id));
    Ok(Value::Unit)
}

fn token_is_cancelled(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let id = match ctx.args.first() {
        Some(Value::Long(l)) => *l,
        Some(Value::Int(i)) => *i as i64,
        _ => return Ok(Value::Bool(false)),
    };
    if id == 0 {
        return Ok(Value::Bool(false));
    }
    let is_cancelled = CANCELLED_TOKENS.with(|c| c.borrow().contains(&id));
    Ok(Value::Bool(is_cancelled))
}

fn scheduler_enqueue(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let h = match ctx.args.first() {
        Some(Value::Long(l)) => *l,
        Some(Value::Int(i)) => *i as i64,
        _ => return Err(RuntimeError::Type("schedulerEnqueue: argument must be Long".into())),
    };
    SCHED_QUEUE.with(|q| q.borrow_mut().push(h));
    Ok(Value::Unit)
}

/// `launch { … }` builder hook: stash the block on a thread-local
/// pending-launch queue that the enclosing `runBlocking` drains
/// after its main body completes. Drives M31's "real scheduler"
/// half — launches no longer run inline on the calling stack.
fn spawn_launch_block(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(lam) = ctx.args.first().cloned() else {
        return Err(RuntimeError::Type(
            "__kxco_spawn: expected the launch block as the first arg".into(),
        ));
    };
    PENDING_LAUNCHES.with(|q| q.borrow_mut().push(lam));
    Ok(Value::Unit)
}

/// Take a snapshot of every pending launch block and clear the
/// queue. Used by the interpreter's `run_blocking` drain step to
/// pump launches without re-entering the shim path.
pub fn drain_pending_launches() -> Vec<Value> {
    PENDING_LAUNCHES.with(|q| std::mem::take(&mut *q.borrow_mut()))
}

fn scheduler_drain_count(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let count = SCHED_QUEUE.with(|q| {
        let mut b = q.borrow_mut();
        let n = b.len() as i32;
        b.clear();
        n
    });
    Ok(Value::new_int(count as i64))
}
