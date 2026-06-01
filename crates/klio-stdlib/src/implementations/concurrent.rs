use super::*;

/// State of one reentrant monitor: which thread (if any) currently
/// owns it and how deep its nesting is.
pub(crate) struct MonitorState {
    owner: Option<std::thread::ThreadId>,
    depth: usize,
}

/// Process-wide monitor table keyed by the lock value's object
/// identity. Value-type locks (no identity) all share a single
/// monitor under the sentinel key `0`.
pub(crate) fn monitor_for(key: usize) -> Arc<(std::sync::Mutex<MonitorState>, std::sync::Condvar)> {
    use std::collections::HashMap;
    use std::sync::OnceLock;
    type Reg = std::sync::Mutex<
        HashMap<usize, Arc<(std::sync::Mutex<MonitorState>, std::sync::Condvar)>>,
    >;
    static REGISTRY: OnceLock<Reg> = OnceLock::new();
    let reg = REGISTRY.get_or_init(|| std::sync::Mutex::new(HashMap::new()));
    let mut g = reg.lock().unwrap_or_else(|e| e.into_inner());
    g.entry(key)
        .or_insert_with(|| {
            Arc::new((
                std::sync::Mutex::new(MonitorState { owner: None, depth: 0 }),
                std::sync::Condvar::new(),
            ))
        })
        .clone()
}

/// `synchronized(lock) { body }` / `synchronized(lock, { body })`.
///
/// A real reentrant monitor keyed by the `lock` argument's object
/// identity: distinct locks run concurrently, the same lock
/// serializes, and the same thread re-entering the same lock does
/// not self-deadlock (Kotlin/JVM monitors are reentrant). The body
/// runs with the monitor held; it is released (even on a thrown
/// exception) before returning. `fence_and_publish` marks the
/// monitor enter and exit boundaries.
pub fn concurrent_synchronized(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let lock = ctx.args.first().cloned().unwrap_or(Value::Unit);
    let block = ctx
        .args
        .last()
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("synchronized expects (lock, block)".into()))?;
    let key = lock.lock_identity().unwrap_or(0);
    let mon = monitor_for(key);
    let me = std::thread::current().id();

    // Acquire (reentrant): block until the monitor is free or already
    // owned by this thread, then take/deepen ownership.
    {
        let mut st = mon.0.lock().unwrap_or_else(|e| e.into_inner());
        loop {
            match st.owner {
                Some(o) if o == me => {
                    st.depth += 1;
                    break;
                }
                None => {
                    st.owner = Some(me);
                    st.depth = 1;
                    break;
                }
                Some(_) => {
                    st = mon.1.wait(st).unwrap_or_else(|e| e.into_inner());
                }
            }
        }
    }
    klio_runtime::fence_and_publish(); // monitor enter

    let CallCtx { out, host, .. } = ctx;
    let result = host.invoke_callable(&block, &[], *out);

    klio_runtime::fence_and_publish(); // monitor exit
    // Release one level; wake a waiter when fully released.
    {
        let mut st = mon.0.lock().unwrap_or_else(|e| e.into_inner());
        if st.depth > 0 {
            st.depth -= 1;
        }
        if st.depth == 0 {
            st.owner = None;
            mon.1.notify_one();
        }
    }
    result
}

/// `kotlin.concurrent.thread(start, isDaemon, contextClassLoader,
/// name, priority) { block }`.
///
/// On a single serialized interpreter a started thread's body runs to
/// completion immediately on the calling stack: the body's every
/// action happens-before the call returns, which is exactly the
/// happens-before edge `Thread.start` would give, only stronger
/// (total order). The returned handle is a `Thread` sentinel whose
/// `join()` is a no-op (the body already completed, so its writes are
/// already visible — join-happens-before holds trivially), `isAlive`
/// is `false`, and `name` is a stable string. This is observably
/// correct for every race-free program, which is the only class
/// Kotlin defines behaviour for.
pub(crate) fn concurrent_thread(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let block = ctx
        .args
        .iter()
        .rev()
        .find(|v| {
            matches!(
                v,
                Value::Function { .. }
                    | Value::Lambda { .. }
                    | Value::IrClosure { .. }
                    | Value::Intrinsic { .. }
                    | Value::BoundMethod { .. }
                    | Value::BoundUserMethod { .. }
            )
        })
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("thread expects a block".into()))?;
    // `thread(start = false) { … }` — leading boolean positional /
    // named arg of `false` means the caller will `.start()` it
    // explicitly. Without a real deferred-start handle we still spawn
    // (the body runs concurrently regardless); a later `.start()` is
    // a no-op. Defaulting to start=true matches the common case.
    let CallCtx { out, host, .. } = ctx;
    klio_runtime::fence_and_publish(); // thread start
    let id = host.spawn_os_thread(&block, *out)?;
    Ok(Value::BoundMethod {
        fqn: "kotlin.concurrent.Thread",
        func: thread_handle_stub,
        receiver: Box::new(Value::Long(id as i64)),
    })
}

/// `Thread.sleep(millis: Long)` / `Thread.sleep(millis: Int)`.
///
/// A real `std::thread::sleep`: the calling OS thread blocks for the
/// requested duration. Combined with `kotlin.concurrent.thread`'s real
/// `std::thread::spawn`, N threads each sleeping for D run in ~D wall
/// time, not ~N·D — genuine parallel suspension, not a busy spin.
pub(crate) fn concurrent_thread_sleep(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let millis = match ctx.args.first() {
        Some(Value::Long(v)) => *v,
        Some(Value::Int(v)) => i64::from(*v),
        Some(Value::Short(v)) => i64::from(*v),
        Some(Value::Byte(v)) => i64::from(*v),
        _ => {
            return Err(RuntimeError::Type(
                "Thread.sleep expects a Long or Int millisecond argument".into(),
            ))
        }
    };
    if millis > 0 {
        std::thread::sleep(std::time::Duration::from_millis(millis as u64));
    }
    Ok(Value::Unit)
}

/// `Thread.currentThread()` — a `Thread` sentinel for the calling OS
/// thread. Its `.name` is a stable per-thread string derived from the
/// OS thread id, so two calls on the same thread report the same name
/// and distinct threads report distinct names; `.isAlive` is `true`
/// (the calling thread is, by definition, running).
pub(crate) fn concurrent_thread_current(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let raw = format!("{:?}", std::thread::current().id());
    // `ThreadId(N)` -> N; fall back to a hash of the debug string.
    let id: u64 = raw
        .trim_start_matches("ThreadId(")
        .trim_end_matches(')')
        .parse()
        .unwrap_or_else(|_| {
            use std::hash::{Hash, Hasher};
            let mut h = std::collections::hash_map::DefaultHasher::new();
            raw.hash(&mut h);
            h.finish()
        });
    Ok(Value::BoundMethod {
        fqn: "kotlin.concurrent.Thread",
        func: thread_handle_stub,
        receiver: Box::new(Value::Long(id as i64)),
    })
}
