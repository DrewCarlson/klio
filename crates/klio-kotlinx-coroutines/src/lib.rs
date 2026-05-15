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
        "kotlinx.coroutines.__kxco_scheduleResume"      => schedule_resume,
        "kotlinx.coroutines.runBlocking"                => run_blocking,
        "kotlinx.coroutines.delay"                      => delay_top_level,
    }
}

/// `runBlocking { ... }` — single-threaded driver: invoke the block
/// lambda, then drain any tasks the block enqueued via `launch`
/// until the scheduler queue is empty.
fn run_blocking(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(block) = ctx.args.last().cloned() else {
        return Err(RuntimeError::Type(
            "runBlocking: expected the block lambda as the trailing arg".into(),
        ));
    };
    let result = ctx
        .host
        .invoke_callable_with_this(&block, &[], &Value::Null, ctx.out)?;
    // Drain any tasks `launch` enqueued during the block.
    loop {
        let launches = ctx.host.scheduler().drain_launches();
        let resumes = ctx.host.scheduler().drain_resumes();
        if launches.is_empty() && resumes.is_empty() {
            break;
        }
        for task in launches {
            ctx.host
                .invoke_callable_with_this(&task, &[], &Value::Null, ctx.out)?;
        }
        for cont in resumes {
            ctx.host
                .invoke_callable_with_this(&cont, &[], &Value::Null, ctx.out)?;
        }
    }
    Ok(result)
}

/// Top-level `delay(ms)` mirror — same as the internal helper but
/// satisfies the suspend shim function directly so the IR doesn't
/// have to run the placeholder body.
fn delay_top_level(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    delay_millis(ctx)
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

/// `launch { … }` builder hook: forward the lambda to the active
/// scheduler so the enclosing `runBlocking` pump can drive it on
/// the next drain pass. Launches no longer run inline on the
/// calling stack.
fn spawn_launch_block(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(lam) = ctx.args.first().cloned() else {
        return Err(RuntimeError::Type(
            "__kxco_spawn: expected the launch block as the first arg".into(),
        ));
    };
    ctx.host.scheduler().spawn(lam);
    Ok(Value::Unit)
}

/// Park the active `suspendCoroutine` continuation on the
/// scheduler's resume queue. The interpreter fires `cont.resume(Unit)`
/// on each parked continuation between rounds, advancing the
/// corresponding paused frame.
fn schedule_resume(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(cont) = ctx.args.first().cloned() else {
        return Err(RuntimeError::Type(
            "__kxco_scheduleResume: expected the continuation arg".into(),
        ));
    };
    ctx.host.scheduler().schedule_resume(cont);
    Ok(Value::Unit)
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
