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

/// Layer-2 coroutine library state for one interpreting thread —
/// the single owned per-thread context for this crate, alongside
/// `klio_interp_ir::ExecState`. It sits inside the publication
/// boundary: cancellation tokens, the scheduler queue, and
/// rendezvous-slot counter belong to the thread driving the
/// coroutines and are never shared across threads directly. One
/// grouped struct (rather than scattered statics) so each OS thread
/// gets exactly one, and so the boundary is one named thing.
struct CoroutineRegistry {
    /// Cancelled cancellation-token ids.
    cancelled_tokens: HashSet<i64>,
    /// Monotonic cancellation-token id counter.
    next_token: i64,
    /// Opaque scheduler-handle FIFO.
    sched_queue: Vec<i64>,
    /// Monotonic slot-id counter. A slot is an opaque rendezvous
    /// point: a coroutine parks indefinitely on it and an explicit
    /// event (job completion, channel item) resumes it.
    next_slot: i64,
}

impl CoroutineRegistry {
    fn new() -> Self {
        Self {
            cancelled_tokens: HashSet::new(),
            next_token: 1,
            sched_queue: Vec::new(),
            next_slot: 1,
        }
    }
}

thread_local! {
    static CORO_REG: RefCell<CoroutineRegistry> =
        RefCell::new(CoroutineRegistry::new());
}

/// Run `f` against this thread's coroutine registry.
fn with_reg<R>(f: impl FnOnce(&mut CoroutineRegistry) -> R) -> R {
    CORO_REG.with(|r| f(&mut r.borrow_mut()))
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
        "kotlinx.coroutines.__kxco_dispatch"            => dispatch_coroutine,
        "kotlinx.coroutines.__kxco_dispatchIo"          => dispatch_coroutine_io,
        "kotlinx.coroutines.__kxco_joinDispatched"      => join_dispatched,
        "kotlinx.coroutines.__kxco_scheduleResume"      => schedule_resume,
        "kotlinx.coroutines.__kxco_newSlot"             => new_slot,
        "kotlinx.coroutines.__kxco_parkSlot"            => park_slot,
        "kotlinx.coroutines.__kxco_resumeSlot"          => resume_slot,
        "kotlinx.coroutines.runBlocking"                => run_blocking,
        "kotlinx.coroutines.delay"                      => delay_top_level,
        "kotlinx.coroutines.yield"                      => yield_now,
        "kotlinx.coroutines.JobSupport.cancel"          => job_cancel,
        "kotlinx.coroutines.Job.cancel"                 => job_cancel,
        "kotlinx.coroutines.AbstractCoroutine.cancel"   => job_cancel,
        "kotlinx.coroutines.StandaloneCoroutine.cancel" => job_cancel,
        "kotlinx.coroutines.LazyStandaloneCoroutine.cancel" => job_cancel,
        "kotlinx.coroutines.DeferredCoroutine.cancel"   => job_cancel,
        "kotlinx.coroutines.LazyDeferredCoroutine.cancel" => job_cancel,
        "kotlinx.coroutines.JobImpl.cancel"             => job_cancel,
        "kotlinx.coroutines.SupervisorJobImpl.cancel"   => job_cancel,
        "kotlinx.coroutines.ScopeCoroutine.cancel"      => job_cancel,
        "kotlinx.coroutines.SupervisorCoroutine.cancel" => job_cancel,
        "kotlinx.coroutines.TimeoutCoroutine.cancel"    => job_cancel,
        "kotlinx.coroutines.CompletableJob.cancel"      => job_cancel,
        "kotlinx.coroutines.Deferred.cancel"            => job_cancel,
        "kotlinx.coroutines.CompletableDeferred.cancel" => job_cancel,
        "kotlinx.coroutines.CompletableDeferredImpl.cancel" => job_cancel,
        "kotlinx.coroutines.ReceiveChannel.cancel"      => job_cancel,
        "kotlinx.coroutines.JobSupport.cancelImpl"      => job_cancel,
        "kotlinx.coroutines.JobSupport.cancelCoroutine" => job_cancel,
        "kotlinx.coroutines.TimeoutCoroutine.cancelCoroutine" => job_cancel,
        "kotlinx.coroutines.AbstractCoroutine.cancelCoroutine" => job_cancel,
        "kotlinx.coroutines.StandaloneCoroutine.cancelCoroutine" => job_cancel,
        "kotlinx.coroutines.ScopeCoroutine.cancelCoroutine" => job_cancel,
    }
}

/// Job.cancel(...) — wake every parked timed activation (delay /
/// withTimeout suspension) with a CancellationException so user
/// `try { … } catch (e: CancellationException)` arms fire and
/// `withTimeoutOrNull` observes the timeout. Indefinite parks
/// (job-join, channel rendezvous) aren't touched.
fn job_cancel(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    // args[0] is the Job receiver. args[1], if present, is the
    // CancellationException cause supplied by the caller (e.g.
    // `TimeoutCoroutine.run` calls `cancelCoroutine(TimeoutCancellationException(...))`).
    // Surface that exception to the parked activations so a catch
    // arm typed on the cause's concrete class (TimeoutCancellationException
    // for withTimeoutOrNull) fires correctly.
    let cause = ctx
        .args
        .iter()
        .skip(1)
        .find_map(|v| match v {
            Value::Exception { .. } | Value::Instance(_) => Some(v.clone()),
            _ => None,
        });
    ctx.host.coroutine_cancel_timed_parks_with(cause);
    Ok(Value::Bool(true))
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
    let id = with_reg(|r| {
        let id = r.next_token;
        r.next_token = r.next_token.wrapping_add(1);
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
    with_reg(|r| r.cancelled_tokens.insert(id));
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
    let is_cancelled = with_reg(|r| r.cancelled_tokens.contains(&id));
    Ok(Value::Bool(is_cancelled))
}

fn scheduler_enqueue(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let h = match ctx.args.first() {
        Some(Value::Long(l)) => *l,
        Some(Value::Int(i)) => *i as i64,
        _ => return Err(RuntimeError::Type("schedulerEnqueue: argument must be Long".into())),
    };
    with_reg(|r| r.sched_queue.push(h));
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

/// `__kxco_dispatch { … }` — dispatch a coroutine body onto the
/// real parallel worker pool (`Dispatchers.Default`). Returns an
/// opaque job id the caller joins with `__kxco_joinDispatched`. The
/// body, its captures, and any value it returns cross threads; the
/// host `publish_deep`'s the escaping graph before the worker starts
/// and again on completion (mirrors the spawned-thread boundary).
fn dispatch_coroutine(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(block) = ctx.args.first().cloned() else {
        return Err(RuntimeError::Type(
            "__kxco_dispatch: expected the coroutine block as the first arg".into(),
        ));
    };
    let id = ctx.host.dispatch_coroutine(&block, false, ctx.out)?;
    Ok(Value::Long(id as i64))
}

/// `__kxco_dispatchIo { … }` — same as `__kxco_dispatch` but routes
/// to the elastic (`Dispatchers.IO`) pool for blocking offload.
fn dispatch_coroutine_io(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(block) = ctx.args.first().cloned() else {
        return Err(RuntimeError::Type(
            "__kxco_dispatchIo: expected the coroutine block as the first arg".into(),
        ));
    };
    let id = ctx.host.dispatch_coroutine(&block, true, ctx.out)?;
    Ok(Value::Long(id as i64))
}

/// `__kxco_joinDispatched(id)` — block the calling coroutine's
/// thread until the dispatched job completes, establishing the
/// completion → joiner happens-before edge.
fn join_dispatched(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let id = match ctx.args.first() {
        Some(Value::Long(l)) => *l,
        Some(Value::Int(i)) => *i as i64,
        _ => {
            return Err(RuntimeError::Type(
                "__kxco_joinDispatched: argument must be Long".into(),
            ))
        }
    };
    ctx.host.join_dispatched(id as u64)?;
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

/// `__kxco_newSlot()` — a fresh unique slot id. Slots back
/// indefinite parking: a coroutine parks on a slot and an explicit
/// event resumes it (job completion, channel handoff).
fn new_slot(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let id = with_reg(|r| {
        let id = r.next_slot;
        r.next_slot = r.next_slot.wrapping_add(1);
        id
    });
    Ok(Value::Long(id))
}

/// `__kxco_parkSlot(slot)` — record that the current coroutine is
/// waiting on `slot`, then suspend indefinitely. The active
/// interceptor binds the resulting parked token to the slot so a
/// later `__kxco_resumeSlot(slot)` can resume exactly this
/// activation.
fn park_slot(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let slot = match ctx.args.first() {
        Some(Value::Long(l)) => *l,
        Some(Value::Int(i)) => *i as i64,
        _ => {
            return Err(RuntimeError::Type(
                "__kxco_parkSlot: argument must be Long".into(),
            ))
        }
    };
    ctx.host.coroutine_park_slot(slot);
    Err(RuntimeError::Suspend(-1))
}

/// `__kxco_resumeSlot(slot)` — make the coroutine waiting on `slot`
/// ready. No-op if nothing is parked on it yet; the Kotlin waiter
/// re-checks its condition after each park so a missed resume just
/// causes a re-park.
fn resume_slot(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let slot = match ctx.args.first() {
        Some(Value::Long(l)) => *l,
        Some(Value::Int(i)) => *i as i64,
        _ => {
            return Err(RuntimeError::Type(
                "__kxco_resumeSlot: argument must be Long".into(),
            ))
        }
    };
    ctx.host.coroutine_resume_slot(slot);
    Ok(Value::Unit)
}

fn scheduler_drain_count(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let count = with_reg(|r| {
        let n = r.sched_queue.len() as i32;
        r.sched_queue.clear();
        n
    });
    Ok(Value::new_int(count as i64))
}
