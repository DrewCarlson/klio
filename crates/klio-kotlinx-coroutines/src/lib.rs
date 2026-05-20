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
use std::collections::{HashMap, HashSet, VecDeque};

use klio_runtime::{CallCtx, RuntimeError, Value};

/// State for a klio-native Channel: a bounded FIFO with optional
/// suspend-waiters. Stored per-instance keyed on the synthesised
/// `Instance.identity` so the Rust intrinsic seam can find it from
/// any binding entry-point. `closed` short-circuits future receives
/// to throw `ClosedReceiveChannelException` after the buffer drains.
struct ChannelState {
    buffer: VecDeque<Value>,
    capacity: usize,
    closed: bool,
    /// Slot ids of `receive()` callers currently parked because the
    /// buffer was empty. The next `send` resumes the head waiter.
    receive_waiters: VecDeque<i64>,
    /// Iterator-style waiters: a parked `for (v in ch)` hasNext()
    /// caller plus a handle to its iterator instance, so the next
    /// send can stash the value in `__pending__` on the iterator
    /// and resume hasNext with `Bool(true)` (instead of the value).
    receive_iter_waiters: VecDeque<(i64, klio_runtime::ObjRef<klio_runtime::InstanceData>)>,
    /// Slot ids of `send(v)` callers parked because the buffer was
    /// full. The next `receive()` resumes the head and admits its
    /// pending value into the buffer.
    send_waiters: VecDeque<(i64, Value)>,
}

impl ChannelState {
    fn new(capacity: usize) -> Self {
        Self {
            buffer: VecDeque::new(),
            capacity,
            closed: false,
            receive_waiters: VecDeque::new(),
            receive_iter_waiters: VecDeque::new(),
            send_waiters: VecDeque::new(),
        }
    }
}

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
    /// klio-native channel registry keyed on the synthesised
    /// channel `Instance.identity`. Lets the channel send/receive
    /// bindings find their state from any entry-point without
    /// threading a host handle through the call stack.
    channels: HashMap<u64, ChannelState>,
}

impl CoroutineRegistry {
    fn new() -> Self {
        Self {
            cancelled_tokens: HashSet::new(),
            next_token: 1,
            sched_queue: Vec::new(),
            next_slot: 1,
            channels: HashMap::new(),
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
        "kotlinx.coroutines.channels.Channel"           => channel_create,
        "kotlinx.coroutines.channels.KlioChannel.send"  => channel_send,
        "kotlinx.coroutines.channels.KlioChannel.trySend" => channel_try_send,
        "kotlinx.coroutines.channels.KlioChannel.receive" => channel_receive,
        "kotlinx.coroutines.channels.KlioChannel.tryReceive" => channel_try_receive,
        "kotlinx.coroutines.channels.KlioChannel.close" => channel_close,
        "kotlinx.coroutines.channels.KlioChannel.isClosedForSend" => channel_is_closed_for_send,
        "kotlinx.coroutines.channels.KlioChannel.isClosedForReceive" => channel_is_closed_for_receive,
        "kotlinx.coroutines.channels.KlioChannel.isEmpty" => channel_is_empty,
        "kotlinx.coroutines.channels.KlioChannel.iterator" => channel_iterator,
        "kotlinx.coroutines.channels.KlioChannelIterator.hasNext" => channel_iter_has_next,
        "kotlinx.coroutines.channels.KlioChannelIterator.next" => channel_iter_next,
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
/// `Channel(capacity)` — klio-native factory. Bypasses upstream
/// `BufferedChannel`'s CAS-loop allocation (klio's `kotlinx.atomicfu`
/// shims don't implement real CAS, so the upstream impl spins).
/// Returns a synthesised `Value::Instance` whose `identity` keys a
/// `ChannelState` in this thread's registry; every channel member
/// binding finds the state by that key.
fn channel_create(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    // First arg is the capacity (Int / Long). Defaults / overloads
    // ship `0` (RENDEZVOUS) and `-1` (UNLIMITED) as sentinel ints.
    let cap_arg = ctx.args.first().cloned().unwrap_or(Value::new_int(0));
    let capacity: i64 = match cap_arg {
        Value::Int(n) => n as i64,
        Value::Long(n) => n,
        _ => 0,
    };
    let effective_cap = if capacity < 0 {
        usize::MAX // UNLIMITED / BUFFERED
    } else if capacity == 0 {
        1 // rendezvous degenerate: one-slot buffer in our model
    } else {
        capacity as usize
    };
    let id = ctx.host.alloc_instance_id();
    with_reg(|r| {
        r.channels.insert(id, ChannelState::new(effective_cap));
    });
    let inst = ctx.host.new_synth_instance(
        "kotlinx.coroutines.channels.KlioChannel",
        id,
        Vec::new(),
    );
    Ok(inst)
}

fn channel_id(arg0: &Value) -> Option<u64> {
    if let Value::Instance(i) = arg0 {
        Some(i.borrow().identity)
    } else {
        None
    }
}

fn channel_send(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let recv = ctx.args.first().cloned().ok_or_else(|| {
        RuntimeError::Arity("Channel.send expects a receiver".into())
    })?;
    let value = ctx.args.get(1).cloned().unwrap_or(Value::Unit);
    let id = channel_id(&recv).ok_or_else(|| {
        RuntimeError::Type("Channel.send: bad receiver".into())
    })?;
    // Direct rendezvous: if a receiver is parked, hand the value
    // straight to it without buffering. Else if buffer has room,
    // push and return. Else park this sender and suspend.
    let outcome = with_reg(|r| -> Result<ChannelSendOutcome, RuntimeError> {
        let action = {
            let state = r.channels.get_mut(&id).ok_or_else(|| {
                RuntimeError::Type("Channel.send: missing state".into())
            })?;
            if state.closed {
                return Err(RuntimeError::Thrown(closed_send_exc()));
            }
            // Iterator waiters take priority — write the value into
            // the iter's `__pending__` field and resume with Bool(true).
            if let Some((slot, iter_inst)) =
                state.receive_iter_waiters.pop_front()
            {
                ChannelSendDispatch::HandToIter(slot, iter_inst, value.clone())
            } else if let Some(slot) = state.receive_waiters.pop_front() {
                ChannelSendDispatch::HandToReceiver(slot, value.clone())
            } else if state.buffer.len() < state.capacity {
                state.buffer.push_back(value.clone());
                ChannelSendDispatch::Buffered
            } else {
                ChannelSendDispatch::ParkSender
            }
        };
        let outcome = match action {
            ChannelSendDispatch::HandToIter(slot, iter, v) => {
                iter.borrow_mut().define("__pending__", v);
                ChannelSendOutcome::HandToIter(slot)
            }
            ChannelSendDispatch::HandToReceiver(slot, v) => {
                ChannelSendOutcome::HandToReceiver(slot, v)
            }
            ChannelSendDispatch::Buffered => ChannelSendOutcome::Buffered,
            ChannelSendDispatch::ParkSender => {
                let slot = r.next_slot;
                r.next_slot = r.next_slot.wrapping_add(1);
                if let Some(state) = r.channels.get_mut(&id) {
                    state.send_waiters.push_back((slot, value.clone()));
                }
                ChannelSendOutcome::ParkOnSlot(slot)
            }
        };
        Ok(outcome)
    })?;
    match outcome {
        ChannelSendOutcome::HandToReceiver(slot, v) => {
            ctx.host.coroutine_resume_slot_value(slot, v);
            Ok(Value::Unit)
        }
        ChannelSendOutcome::HandToIter(slot) => {
            ctx.host
                .coroutine_resume_slot_value(slot, Value::Bool(true));
            Ok(Value::Unit)
        }
        ChannelSendOutcome::Buffered => Ok(Value::Unit),
        ChannelSendOutcome::ParkOnSlot(slot) => {
            ctx.host.coroutine_arm_slot(slot);
            Err(RuntimeError::Suspend(-1))
        }
    }
}

enum ChannelSendOutcome {
    HandToReceiver(i64, Value),
    HandToIter(i64),
    Buffered,
    ParkOnSlot(i64),
}

enum ChannelSendDispatch {
    HandToIter(i64, klio_runtime::ObjRef<klio_runtime::InstanceData>, Value),
    HandToReceiver(i64, Value),
    Buffered,
    ParkSender,
}

fn channel_try_send(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let recv = ctx.args.first().cloned().ok_or_else(|| {
        RuntimeError::Arity("Channel.trySend expects a receiver".into())
    })?;
    let value = ctx.args.get(1).cloned().unwrap_or(Value::Unit);
    let id = channel_id(&recv).ok_or_else(|| {
        RuntimeError::Type("Channel.trySend: bad receiver".into())
    })?;
    let outcome = with_reg(|r| -> Result<ChannelTrySendOutcome, RuntimeError> {
        let state = r.channels.get_mut(&id).ok_or_else(|| {
            RuntimeError::Type("Channel.trySend: missing state".into())
        })?;
        if state.closed {
            return Ok(ChannelTrySendOutcome::Closed);
        }
        if let Some(slot) = state.receive_waiters.pop_front() {
            return Ok(ChannelTrySendOutcome::HandToReceiver(slot, value.clone()));
        }
        if state.buffer.len() < state.capacity {
            state.buffer.push_back(value.clone());
            return Ok(ChannelTrySendOutcome::Success);
        }
        Ok(ChannelTrySendOutcome::Full)
    })?;
    let result = match outcome {
        ChannelTrySendOutcome::HandToReceiver(slot, v) => {
            ctx.host.coroutine_resume_slot_value(slot, v);
            Value::Bool(true)
        }
        ChannelTrySendOutcome::Success => Value::Bool(true),
        ChannelTrySendOutcome::Full | ChannelTrySendOutcome::Closed => {
            Value::Bool(false)
        }
    };
    Ok(result)
}

enum ChannelTrySendOutcome {
    HandToReceiver(i64, Value),
    Success,
    Full,
    Closed,
}

fn channel_receive(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let recv = ctx.args.first().cloned().ok_or_else(|| {
        RuntimeError::Arity("Channel.receive expects a receiver".into())
    })?;
    let id = channel_id(&recv).ok_or_else(|| {
        RuntimeError::Type("Channel.receive: bad receiver".into())
    })?;
    let outcome = with_reg(|r| -> Result<ChannelReceiveOutcome, RuntimeError> {
        let (got, closed) = {
            let state = r.channels.get_mut(&id).ok_or_else(|| {
                RuntimeError::Type("Channel.receive: missing state".into())
            })?;
            if let Some(v) = state.buffer.pop_front() {
                let resumed_sender = state.send_waiters.pop_front();
                if let Some((_, pending)) = &resumed_sender {
                    state.buffer.push_back(pending.clone());
                }
                return Ok(ChannelReceiveOutcome::Got(
                    v,
                    resumed_sender.map(|(s, _)| s),
                ));
            }
            (None::<Value>, state.closed)
        };
        let _ = got;
        if closed {
            return Err(RuntimeError::Thrown(closed_receive_exc()));
        }
        let slot = r.next_slot;
        r.next_slot = r.next_slot.wrapping_add(1);
        if let Some(state) = r.channels.get_mut(&id) {
            state.receive_waiters.push_back(slot);
        }
        Ok(ChannelReceiveOutcome::ParkOnSlot(slot))
    })?;
    match outcome {
        ChannelReceiveOutcome::Got(v, resumed) => {
            if let Some(slot) = resumed {
                ctx.host.coroutine_resume_slot(slot);
            }
            Ok(v)
        }
        ChannelReceiveOutcome::ParkOnSlot(slot) => {
            ctx.host.coroutine_arm_slot(slot);
            Err(RuntimeError::Suspend(-1))
        }
    }
}

enum ChannelReceiveOutcome {
    Got(Value, Option<i64>),
    ParkOnSlot(i64),
}

fn channel_try_receive(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let recv = ctx.args.first().cloned().ok_or_else(|| {
        RuntimeError::Arity("Channel.tryReceive expects a receiver".into())
    })?;
    let id = channel_id(&recv).ok_or_else(|| {
        RuntimeError::Type("Channel.tryReceive: bad receiver".into())
    })?;
    let outcome = with_reg(|r| {
        let state = r.channels.get_mut(&id)?;
        if let Some(v) = state.buffer.pop_front() {
            let resumed_sender = state.send_waiters.pop_front();
            if let Some((_, pending)) = &resumed_sender {
                state.buffer.push_back(pending.clone());
            }
            Some((Some(v), resumed_sender.map(|(s, _)| s), false))
        } else if state.closed {
            Some((None, None, true))
        } else {
            Some((None, None, false))
        }
    });
    if let Some((value, resumed_slot, closed)) = outcome {
        if let Some(slot) = resumed_slot {
            ctx.host.coroutine_resume_slot(slot);
        }
        let _ = closed;
        Ok(value.unwrap_or(Value::Null))
    } else {
        Ok(Value::Null)
    }
}

fn channel_close(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let recv = ctx.args.first().cloned().ok_or_else(|| {
        RuntimeError::Arity("Channel.close expects a receiver".into())
    })?;
    let id = channel_id(&recv).ok_or_else(|| {
        RuntimeError::Type("Channel.close: bad receiver".into())
    })?;
    let waiters = with_reg(|r| {
        let state = r.channels.get_mut(&id)?;
        state.closed = true;
        let recvs: Vec<i64> = state.receive_waiters.drain(..).collect();
        let iters: Vec<(
            i64,
            klio_runtime::ObjRef<klio_runtime::InstanceData>,
        )> = state.receive_iter_waiters.drain(..).collect();
        let sends: Vec<(i64, Value)> =
            state.send_waiters.drain(..).collect();
        Some((recvs, iters, sends))
    });
    if let Some((recvs, iters, sends)) = waiters {
        let exc = closed_receive_exc();
        for slot in recvs {
            let failure = Value::Result {
                ok: false,
                payload: Box::new(exc.clone()),
            };
            ctx.host.coroutine_resume_slot_value(slot, failure);
        }
        // Iterator-style waiters resume with `Bool(false)` so the
        // for-loop hasNext() returns false and the loop exits.
        for (slot, _iter) in iters {
            ctx.host
                .coroutine_resume_slot_value(slot, Value::Bool(false));
        }
        let send_exc = closed_send_exc();
        for (slot, _v) in sends {
            let failure = Value::Result {
                ok: false,
                payload: Box::new(send_exc.clone()),
            };
            ctx.host.coroutine_resume_slot_value(slot, failure);
        }
    }
    Ok(Value::Bool(true))
}

fn channel_is_closed_for_send(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let recv = ctx.args.first().cloned().ok_or_else(|| {
        RuntimeError::Arity("isClosedForSend expects a receiver".into())
    })?;
    let id = channel_id(&recv).ok_or_else(|| {
        RuntimeError::Type("isClosedForSend: bad receiver".into())
    })?;
    let closed = with_reg(|r| r.channels.get(&id).map(|s| s.closed).unwrap_or(true));
    Ok(Value::Bool(closed))
}

fn channel_is_closed_for_receive(
    ctx: &mut CallCtx,
) -> Result<Value, RuntimeError> {
    let recv = ctx.args.first().cloned().ok_or_else(|| {
        RuntimeError::Arity("isClosedForReceive expects a receiver".into())
    })?;
    let id = channel_id(&recv).ok_or_else(|| {
        RuntimeError::Type("isClosedForReceive: bad receiver".into())
    })?;
    let drained_closed = with_reg(|r| {
        r.channels
            .get(&id)
            .map(|s| s.closed && s.buffer.is_empty())
            .unwrap_or(true)
    });
    Ok(Value::Bool(drained_closed))
}

fn channel_iterator(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let recv = ctx.args.first().cloned().ok_or_else(|| {
        RuntimeError::Arity("Channel.iterator expects a receiver".into())
    })?;
    let ch_id = channel_id(&recv).ok_or_else(|| {
        RuntimeError::Type("Channel.iterator: bad receiver".into())
    })?;
    let id = ctx.host.alloc_instance_id();
    let inst = ctx.host.new_synth_instance(
        "kotlinx.coroutines.channels.KlioChannelIterator",
        id,
        vec![
            (
                "__channel_id__".to_string(),
                Value::Long(ch_id as i64),
            ),
            ("__pending__".to_string(), Value::Null),
        ],
    );
    Ok(inst)
}

fn channel_iter_has_next(
    ctx: &mut CallCtx,
) -> Result<Value, RuntimeError> {
    let recv = ctx.args.first().cloned().ok_or_else(|| {
        RuntimeError::Arity("hasNext expects a receiver".into())
    })?;
    let (iter_inst, ch_id) = match &recv {
        Value::Instance(i) => {
            let b = i.borrow();
            let ch_id = b
                .get("__channel_id__")
                .and_then(|v| match v {
                    Value::Long(n) => Some(n as u64),
                    Value::Int(n) => Some(n as u64),
                    _ => None,
                })
                .ok_or_else(|| {
                    RuntimeError::Type("hasNext: missing channel id".into())
                })?;
            (i.clone(), ch_id)
        }
        _ => return Err(RuntimeError::Type("hasNext: bad receiver".into())),
    };
    // Already have a cached pending value? Report true without
    // touching the channel.
    let pending = iter_inst.borrow().get("__pending__");
    if let Some(c) = pending {
        if !matches!(c, Value::Null) {
            return Ok(Value::Bool(true));
        }
    }
    // Try a synchronous pull. If the buffer holds a value, cache it
    // and return true; if the channel is drained-and-closed, return
    // false; otherwise queue an iterator-style waiter and suspend.
    let outcome = with_reg(|r| {
        let state = r.channels.get_mut(&ch_id)?;
        if let Some(v) = state.buffer.pop_front() {
            let resumed_sender = state.send_waiters.pop_front();
            if let Some((_, pending)) = &resumed_sender {
                state.buffer.push_back(pending.clone());
            }
            return Some((Some(v), resumed_sender.map(|(s, _)| s), false));
        }
        Some((None, None, state.closed))
    });
    if let Some((maybe_v, resumed_slot, closed)) = outcome {
        if let Some(slot) = resumed_slot {
            ctx.host.coroutine_resume_slot(slot);
        }
        if let Some(v) = maybe_v {
            iter_inst.borrow_mut().define("__pending__", v);
            return Ok(Value::Bool(true));
        }
        if closed {
            return Ok(Value::Bool(false));
        }
    }
    let slot = with_reg(|r| {
        let s = r.next_slot;
        r.next_slot = r.next_slot.wrapping_add(1);
        if let Some(state) = r.channels.get_mut(&ch_id) {
            state.receive_iter_waiters.push_back((s, iter_inst.clone()));
        }
        s
    });
    ctx.host.coroutine_arm_slot(slot);
    Err(RuntimeError::Suspend(-1))
}

fn channel_iter_next(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let recv = ctx.args.first().cloned().ok_or_else(|| {
        RuntimeError::Arity("next expects a receiver".into())
    })?;
    let inst = match &recv {
        Value::Instance(i) => i.clone(),
        _ => return Err(RuntimeError::Type("next: bad receiver".into())),
    };
    let pending = inst.borrow().get("__pending__");
    if let Some(v) = pending {
        if !matches!(v, Value::Null) {
            inst.borrow_mut()
                .define("__pending__", Value::Null);
            return Ok(v);
        }
    }
    Err(RuntimeError::Thrown(Value::Exception {
        fqn: std::sync::Arc::new(
            "kotlin.NoSuchElementException".into(),
        ),
        message: Some(std::sync::Arc::new(
            "ChannelIterator.next called before hasNext".into(),
        )),
        cause: None,
    }))
}

fn channel_is_empty(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let recv = ctx.args.first().cloned().ok_or_else(|| {
        RuntimeError::Arity("isEmpty expects a receiver".into())
    })?;
    let id = channel_id(&recv).ok_or_else(|| {
        RuntimeError::Type("isEmpty: bad receiver".into())
    })?;
    let empty = with_reg(|r| {
        r.channels
            .get(&id)
            .map(|s| s.buffer.is_empty())
            .unwrap_or(true)
    });
    Ok(Value::Bool(empty))
}

fn closed_receive_exc() -> Value {
    Value::Exception {
        fqn: std::sync::Arc::new(
            "kotlinx.coroutines.channels.ClosedReceiveChannelException".into(),
        ),
        message: Some(std::sync::Arc::new("Channel was closed".into())),
        cause: None,
    }
}

fn closed_send_exc() -> Value {
    Value::Exception {
        fqn: std::sync::Arc::new(
            "kotlinx.coroutines.channels.ClosedSendChannelException".into(),
        ),
        message: Some(std::sync::Arc::new("Channel was closed".into())),
        cause: None,
    }
}

fn next_slot() -> i64 {
    with_reg(|r| {
        let s = r.next_slot;
        r.next_slot = r.next_slot.wrapping_add(1);
        s
    })
}

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
