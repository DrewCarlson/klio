use super::{Arc, CallCtx, RuntimeError, Value};

// ============================================================
// Result
// ============================================================

pub(crate) fn recv_result<'a>(
    args: &'a [Value],
    what: &str,
) -> Result<(bool, &'a Value), RuntimeError> {
    match args.first() {
        Some(Value::Result { ok, payload }) => Ok((*ok, payload.as_ref())),
        _ => Err(RuntimeError::Type(format!(
            "{what} requires a Result receiver"
        ))),
    }
}

// Result signature kept to match the builtin handler function-pointer table.
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn result_success(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = ctx.args.first().cloned().unwrap_or(Value::Unit);
    Ok(Value::Result {
        ok: true,
        payload: Box::new(v),
    })
}

// Result signature kept to match the builtin handler function-pointer table.
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn result_failure(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = ctx.args.first().cloned().unwrap_or(Value::Unit);
    Ok(Value::Result {
        ok: false,
        payload: Box::new(v),
    })
}

pub(crate) fn run_catching_impl(block: &Value, ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let CallCtx { out, host, .. } = ctx;
    match host.invoke_callable(block, &[], *out) {
        Ok(v) => Ok(Value::Result {
            ok: true,
            payload: Box::new(v),
        }),
        Err(RuntimeError::Thrown(e)) => Ok(Value::Result {
            ok: false,
            payload: Box::new(e),
        }),
        Err(e) => Err(e),
    }
}

pub(crate) fn result_run_catching(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    // Two forms:
    //   runCatching { … }    -> 1 arg (block)
    //   x.runCatching { … }  -> 2 args (receiver, block); receiver bound as `this`
    if ctx.args.len() == 1 {
        let block = ctx.args[0].clone();
        return run_catching_impl(&block, ctx);
    }
    if ctx.args.len() == 2 {
        let recv = ctx.args[0].clone();
        let block = ctx.args[1].clone();
        let CallCtx { out, host, .. } = ctx;
        return match host.invoke_callable_with_this(&block, &[], &recv, *out) {
            Ok(v) => Ok(Value::Result {
                ok: true,
                payload: Box::new(v),
            }),
            Err(RuntimeError::Thrown(e)) => Ok(Value::Result {
                ok: false,
                payload: Box::new(e),
            }),
            Err(e) => Err(e),
        };
    }
    Err(RuntimeError::Arity(
        "runCatching expects (block) or (receiver, block)".into(),
    ))
}

pub(crate) fn result_fold(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 3 {
        return Err(RuntimeError::Arity(
            "Result.fold expects (receiver, onSuccess, onFailure)".into(),
        ));
    }
    let (ok, payload) = recv_result(ctx.args, "Result.fold")?;
    let payload = payload.clone();
    let on_success = ctx.args[1].clone();
    let on_failure = ctx.args[2].clone();
    let CallCtx { out, host, .. } = ctx;
    if ok {
        host.invoke_callable(&on_success, std::slice::from_ref(&payload), *out)
    } else {
        host.invoke_callable(&on_failure, std::slice::from_ref(&payload), *out)
    }
}

pub(crate) fn result_map(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity(
            "Result.map expects (receiver, block)".into(),
        ));
    }
    let (ok, payload) = recv_result(ctx.args, "Result.map")?;
    let payload = payload.clone();
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    if !ok {
        return Ok(Value::Result {
            ok: false,
            payload: Box::new(payload),
        });
    }
    let v = host.invoke_callable(&block, std::slice::from_ref(&payload), *out)?;
    Ok(Value::Result {
        ok: true,
        payload: Box::new(v),
    })
}

pub(crate) fn result_map_catching(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity(
            "Result.mapCatching expects (receiver, block)".into(),
        ));
    }
    let (ok, payload) = recv_result(ctx.args, "Result.mapCatching")?;
    let payload = payload.clone();
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    if !ok {
        return Ok(Value::Result {
            ok: false,
            payload: Box::new(payload),
        });
    }
    match host.invoke_callable(&block, std::slice::from_ref(&payload), *out) {
        Ok(v) => Ok(Value::Result {
            ok: true,
            payload: Box::new(v),
        }),
        Err(RuntimeError::Thrown(e)) => Ok(Value::Result {
            ok: false,
            payload: Box::new(e),
        }),
        Err(e) => Err(e),
    }
}

pub(crate) fn result_on_success(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity(
            "Result.onSuccess expects (receiver, block)".into(),
        ));
    }
    let recv = ctx.args[0].clone();
    let (ok, payload) = recv_result(ctx.args, "Result.onSuccess")?;
    let payload = payload.clone();
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    if ok {
        host.invoke_callable(&block, std::slice::from_ref(&payload), *out)?;
    }
    Ok(recv)
}

pub(crate) fn result_on_failure(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity(
            "Result.onFailure expects (receiver, block)".into(),
        ));
    }
    let recv = ctx.args[0].clone();
    let (ok, payload) = recv_result(ctx.args, "Result.onFailure")?;
    let payload = payload.clone();
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    if !ok {
        host.invoke_callable(&block, std::slice::from_ref(&payload), *out)?;
    }
    Ok(recv)
}

pub(crate) fn result_is_success(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (ok, _) = recv_result(ctx.args, "Result.isSuccess")?;
    Ok(Value::Bool(ok))
}

pub(crate) fn result_is_failure(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (ok, _) = recv_result(ctx.args, "Result.isFailure")?;
    Ok(Value::Bool(!ok))
}

pub(crate) fn result_get_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (ok, payload) = recv_result(ctx.args, "Result.getOrNull")?;
    if ok {
        Ok(payload.clone())
    } else {
        Ok(Value::Null)
    }
}

pub(crate) fn result_exception_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (ok, payload) = recv_result(ctx.args, "Result.exceptionOrNull")?;
    if ok {
        Ok(Value::Null)
    } else {
        Ok(payload.clone())
    }
}

/// `kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED` — the
/// singleton a `suspendCoroutineUninterceptedOrReturn` block
/// returns to signal it parked rather than producing a value.
/// One logical instance, so `x === COROUTINE_SUSPENDED` holds for
/// any sentinel `x`.
// Result signature kept to match the builtin handler function-pointer table.
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn coroutine_suspended_sentinel(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::CoroutineSuspended)
}

/// Process-global monotonic rendezvous-slot counter for the
/// `kotlin.coroutines` language layer. Process-global so cross-thread
/// resume routing (slot → owning runBlocking driver) cannot alias a
/// slot id minted on a different thread.
pub(crate) static CO_NEXT_SLOT: std::sync::atomic::AtomicI64 = std::sync::atomic::AtomicI64::new(1);

/// `__klio_co_newSlot()` — a fresh slot id for a `suspendCoroutine`
/// rendezvous.
// Result signature kept to match the builtin handler function-pointer table.
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn coro_new_slot(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let id = CO_NEXT_SLOT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    Ok(Value::Long(id))
}

pub(crate) fn slot_arg(args: &[Value], who: &str) -> Result<i64, RuntimeError> {
    match args.first() {
        Some(Value::Long(l)) => Ok(*l),
        Some(Value::Int(i)) => Ok(i64::from(*i)),
        _ => Err(RuntimeError::Type(format!("{who}: slot must be Long"))),
    }
}

/// `__klio_co_park(slot)` — record the current activation as waiting
/// on `slot`, then suspend indefinitely. On resume the call yields
/// the `Result` delivered by `__klio_co_resume`.
pub(crate) fn coro_park(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let slot = slot_arg(ctx.args, "__klio_co_park")?;
    ctx.host.coroutine_park_slot(slot);
    Err(RuntimeError::Suspend(-1))
}

/// `__klio_co_armSlot(slot)` — bind the next suspension (even a
/// timed one) to `slot` without suspending now, so a suspend inside
/// a `suspendCoroutineUninterceptedOrReturn` block stays reachable
/// via the continuation's slot for preemptive cancellation.
pub(crate) fn coro_arm_slot(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let slot = slot_arg(ctx.args, "__klio_co_armSlot")?;
    ctx.host.coroutine_arm_slot(slot);
    Ok(Value::Unit)
}

/// `__klio_co_disarmSlot()` — cancel a pending arm (the block
/// returned a value without suspending).
// Result signature kept to match the builtin handler function-pointer table.
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn coro_disarm_slot(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    ctx.host.coroutine_disarm_slot();
    Ok(Value::Unit)
}

/// `__klio_co_resume(slot, ok, value)` — deliver a `Result` to the
/// activation parked on `slot` and make it ready.
pub(crate) fn coro_resume(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let slot = slot_arg(ctx.args, "__klio_co_resume")?;
    let ok = matches!(ctx.args.get(1), Some(Value::Bool(true)));
    let payload = ctx.args.get(2).cloned().unwrap_or(Value::Null);
    let result = Value::Result {
        ok,
        payload: Box::new(payload),
    };
    ctx.host.coroutine_resume_external(slot, result, ctx.out);
    Ok(Value::Unit)
}

/// `__klio_co_runRoot(block)` — drive `block` as a cooperative
/// coroutine root to quiescence, returning its terminal value.
pub(crate) fn coro_run_root(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let block = match ctx.args.first() {
        Some(v) => v.clone(),
        None => {
            return Err(RuntimeError::Type(
                "__klio_co_runRoot: missing block".into(),
            ));
        }
    };
    ctx.host.coroutine_run_root(&block, ctx.out)
}

/// `Result.getOrThrow()` — the success value, or rethrow the
/// captured failure. Core to `Continuation.resumeWith`.
pub(crate) fn result_get_or_throw(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (ok, payload) = recv_result(ctx.args, "Result.getOrThrow")?;
    if ok {
        Ok(payload.clone())
    } else {
        Err(RuntimeError::Thrown(payload.clone()))
    }
}

pub(crate) fn result_get_or_else(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity(
            "Result.getOrElse expects (receiver, onFailure)".into(),
        ));
    }
    let (ok, payload) = recv_result(&ctx.args[..1], "Result.getOrElse")?;
    if ok {
        return Ok(payload.clone());
    }
    let payload = payload.clone();
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    host.invoke_callable(&block, std::slice::from_ref(&payload), *out)
}

pub(crate) fn result_get_or_default(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (ok, payload) = recv_result(ctx.args, "Result.getOrDefault")?;
    let default = ctx
        .args
        .get(1)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("Result.getOrDefault requires a default".into()))?;
    if ok { Ok(payload.clone()) } else { Ok(default) }
}

pub(crate) fn result_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (ok, payload) = recv_result(ctx.args, "Result.toString")?;
    let s = if ok {
        format!("Success({payload})")
    } else {
        format!("Failure({payload})")
    };
    Ok(Value::String(Arc::new(s)))
}
