//! Layer 2 — the `kotlinx.coroutines` library.
//!
//! This crate is a *client* of the Layer-1 core suspend engine
//! (`klio_ir::eval`): the high-level API (Dispatchers,
//! CoroutineScope, Job, Channel, builders) lives in the Kotlin
//! shim, and the few host hooks here only translate library calls
//! into Layer-1 suspension. `delay`/`yield` raise a suspension
//! carrying an opaque resume directive; the default cooperative
//! interceptor (in `klio-interp-ir`) decides when the parked
//! activation resumes. The host never schedules from here — that is
//! the interceptor's sole responsibility — and the core suspend
//! engine never interprets the directive. A cancellation-token
//! registry is shared between Jobs and their bodies; the Kotlin
//! shim observes it through `__kxco_tokenIsCancelled`.

use std::cell::RefCell;
use std::collections::HashSet;

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
        "kotlinx.coroutines.yield"                      => yield_now,
    }
}

/// `yield()` — cooperative reschedule: park with a zero-ms wakeup
/// so every other ready coroutine runs before this one continues.
fn yield_now(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Err(RuntimeError::Suspend(0))
}

/// `runBlocking { ... }` — drive the block as the root of a
/// cooperative coroutine. The interpreter's scheduler interleaves
/// launched children at suspension points and advances *virtual*
/// time for `delay`, so the OS thread never sleeps.
fn run_blocking(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(block) = ctx.args.last().cloned() else {
        return Err(RuntimeError::Type(
            "runBlocking: expected the block lambda as the trailing arg".into(),
        ));
    };
    // Resolve a CoroutineScope receiver so `this.launch { … }` inside
    // the block dispatches the shim extension. GlobalScope is the
    // singleton the shim publishes; fall back to Null if the pack
    // hasn't been registered yet (e.g. unit tests with NoopHost).
    let scope = ctx
        .host
        .lookup_global("GlobalScope")
        .unwrap_or(Value::Null);
    ctx.host.run_blocking(&block, &scope, ctx.out)
}

/// Top-level `delay(ms)` mirror — satisfies the suspend shim
/// function directly so the IR doesn't run the placeholder body.
fn delay_top_level(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    delay_millis(ctx)
}

/// `delay(ms)` — suspend the calling coroutine for `ms` of virtual
/// time. The cooperative driver parks the activation and resumes it
/// once virtual time advances past the wakeup; sibling coroutines
/// run in the meantime. No OS sleep.
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
    Err(RuntimeError::Suspend(ms.max(0)))
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
    let scope = ctx.host.lookup_global("GlobalScope").unwrap_or(Value::Null);
    ctx.host.coroutine_launch(&lam, &scope, ctx.out)?;
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
