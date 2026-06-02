use crate::{Value, RuntimeError, Output, ToI64};

/// Function pointer signature for a Rust-native stdlib intrinsic.
///
/// `CallCtx::args` carries the call arguments. For member access (`x.f()`
/// or property `x.length`) the receiver is passed as `args[0]`, with any
/// further user arguments following.
pub type StdlibFn = fn(&mut CallCtx) -> Result<Value, RuntimeError>;

pub struct CallCtx<'a> {
    pub args: &'a [Value],
    pub out: &'a mut dyn Output,
    /// Single trait object the intrinsic uses to reach the rest of
    /// the runtime — the scheduler (for `launch { }` / parked
    /// continuations) and the lambda invoker (for `.map { }`,
    /// `.let { }`, `runCatching { }` etc.). Bundled this way so a
    /// call site can borrow `out` and the host from a single
    /// `&mut Interpreter` without conflicting field borrows.
    pub host: &'a mut dyn IntrinsicHost,
}

/// Side-channel the runtime exposes to stdlib intrinsics. Lets a
/// binding call back into the interpreter for the bits an
/// intrinsic can't carry out on its own — invoking a
/// caller-supplied lambda, posting to the cooperative scheduler.
pub trait IntrinsicHost {
    /// Cooperative scheduler. Coroutine builders post launched
    /// bodies / parked continuations here.
    fn scheduler(&mut self) -> &mut dyn Scheduler;

    /// Invoke a callable `Value` (`Value::Lambda`, `Value::IrClosure`,
    /// `Value::Function`, `Value::Intrinsic`, `Value::BoundMethod`,
    /// `Value::PropertyRef`, …) with the supplied args. Used by
    /// stdlib HOFs and scope functions to drive the user's
    /// lambda body.
    fn invoke_callable(
        &mut self,
        callable: &Value,
        args: &[Value],
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError>;

    /// Like `invoke_callable` but binds `this` inside the lambda
    /// body to `this_value` for the duration of the call. Used by
    /// `apply { … }` / `run { … }` / `with(x) { … }` — the
    /// receiver-bound scope functions.
    fn invoke_callable_with_this(
        &mut self,
        callable: &Value,
        args: &[Value],
        this_value: &Value,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError>;

    /// Invoke a named method on the given receiver value. Used by
    /// `println` / string-template formatting to dispatch user
    /// `override fun toString(): String` bodies. Default impl
    /// returns `None`, signalling the caller to fall back to the
    /// runtime's structural rendering.
    fn invoke_method(
        &mut self,
        _receiver: &Value,
        _name: &str,
        _args: &[Value],
        _out: &mut dyn Output,
    ) -> Option<Result<Value, RuntimeError>> {
        None
    }

    /// Resolve a top-level identifier (class / object / function)
    /// against the running interpreter's global environment.
    /// Bindings can use this to grab a singleton (`GlobalScope`) or
    /// look up a class for `NewInstance`-style dispatch. Default
    /// impl returns `None`, signalling the host doesn't expose a
    /// global table.
    fn lookup_global(&mut self, _name: &str) -> Option<Value> {
        None
    }

    /// Allocate a fresh `Instance.identity` value (monotonic across
    /// the interpreter run). klio-native intrinsics that synthesise
    /// `Value::Instance` (e.g. the channels factory) call this so
    /// the identity space stays disjoint from regular allocations.
    fn alloc_instance_id(&mut self) -> u64 {
        0
    }

    /// Synthesise a `Value::Instance` of class `class_fqn` (a name
    /// not declared in user IR) with the given `identity` and
    /// `fields`. Used by klio-native intrinsics that need to return
    /// an opaque user-visible handle bound to host state.
    fn new_synth_instance(
        &mut self,
        _class_fqn: &str,
        _identity: u64,
        _fields: Vec<(String, Value)>,
    ) -> Value {
        Value::Unit
    }

    /// Run `block` as the root of a cooperative coroutine and drive
    /// the scheduler to completion: launched children interleave at
    /// suspension points and `delay` advances *virtual* time so a
    /// long-running block never blocks the OS thread. Returns the
    /// block's terminal value. Default impl runs `block` straight
    /// through with no scheduling (no suspension support).
    fn run_blocking(
        &mut self,
        block: &Value,
        scope: &Value,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        self.invoke_callable_with_this(block, &[], scope, out)
    }

    /// Run `block` (a `() -> T`) as the root of a cooperative
    /// coroutine and drive the scheduler to quiescence, then return
    /// its terminal value. Backs the `kotlin.coroutines`
    /// `startCoroutine` boundary: a suspension inside the started
    /// coroutine parks in the driver and any continuation resumed
    /// while draining runs, instead of the suspension propagating to
    /// a non-coroutine caller. Default impl invokes `block` directly
    /// (no scheduling).
    fn coroutine_run_root(
        &mut self,
        block: &Value,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        self.invoke_callable(block, &[], out)
    }

    /// Spawn `block` as a child coroutine of the active
    /// `runBlocking`/coroutineScope. It interleaves with siblings at
    /// suspension points and is awaited before the root completes.
    /// Default impl runs it eagerly to completion.
    fn coroutine_launch(
        &mut self,
        block: &Value,
        scope: &Value,
        out: &mut dyn Output,
    ) -> Result<(), RuntimeError> {
        self.invoke_callable_with_this(block, &[], scope, out).map(|_| ())
    }

    /// Record that the activation about to suspend indefinitely is
    /// waiting on `slot`. The active interceptor associates the next
    /// indefinitely-parked token with this slot so a later
    /// `coroutine_resume_slot(slot)` can resume it. Default impl is a
    /// no-op (no cooperative driver).
    fn coroutine_park_slot(&mut self, _slot: i64) {}

    /// Arm `slot` so the next parked activation (even a timed one) is
    /// bound to it, without itself suspending. Default no-op.
    fn coroutine_arm_slot(&mut self, _slot: i64) {}

    /// Clear a previously-armed slot (block returned without
    /// suspending). Default no-op.
    fn coroutine_disarm_slot(&mut self) {}

    /// Make the coroutine waiting on `slot` ready, if any is parked.
    /// Searches the interceptor stack top-down so a nested scope can
    /// resume a waiter parked by an outer one. No-op if nothing is
    /// waiting on the slot (the waiter must re-check its condition
    /// after each park). Default impl is a no-op.
    fn coroutine_resume_slot(&mut self, _slot: i64) {}

    /// Like [`coroutine_resume_slot`] but the parked activation
    /// resumes with `value` delivered as the result of the call that
    /// suspended it (instead of the default `Unit`). Backs the
    /// `kotlin.coroutines` `Continuation.resumeWith` protocol, where
    /// the suspending `suspendCoroutine` site must observe the
    /// resumed value. Default impl is a no-op.
    fn coroutine_resume_slot_value(&mut self, _slot: i64, _value: Value) {}

    /// Cancel every parked timed-wait activation (a `delay()` /
    /// `withTimeout` continuation) in the active interceptor: wake
    /// each with `Result.failure(CancellationException)` so the
    /// suspended call resumes by throwing instead of returning.
    /// Indefinite parks (job joins, channel rendezvous) are not
    /// touched. Default impl is a no-op.
    fn coroutine_cancel_timed_parks(&mut self) {
        self.coroutine_cancel_timed_parks_with(None);
    }

    /// Variant of [`coroutine_cancel_timed_parks`] that lets the
    /// caller supply the exception each woken activation observes;
    /// `None` defaults to a `CancellationException`. `cancelCoroutine`
    /// in upstream Kotlin reaches this with a
    /// `TimeoutCancellationException` cause so `withTimeoutOrNull`'s
    /// `catch (e: TimeoutCancellationException)` arm fires.
    fn coroutine_cancel_timed_parks_with(&mut self, _cause: Option<Value>) {}

    /// Drive the active cooperative interceptor's queues (launched
    /// children and parked timers) until idle. Used by
    /// `coroutineScope` / `supervisorScope` to enforce the
    /// structured-concurrency wait-for-children contract for the
    /// non-suspending body case (a scope body whose final expression
    /// only queues launches, e.g. fire-and-forget event dispatch).
    /// Default impl is a no-op.
    fn coroutine_drain_to_idle(
        &mut self,
        _out: &mut dyn Output,
    ) -> Result<(), RuntimeError> {
        Ok(())
    }

    /// `Continuation.resumeWith` entry point: deliver `value` to the
    /// activation parked on `slot`. If a live cooperative driver
    /// holds it, just enqueue (the driver runs it); otherwise the
    /// coroutine parked inside a since-returned `startCoroutine`
    /// driver — drive its preserved state to completion here.
    /// Default impl delegates to [`coroutine_resume_slot_value`].
    fn coroutine_resume_external(
        &mut self,
        slot: i64,
        value: Value,
        _out: &mut dyn Output,
    ) {
        self.coroutine_resume_slot_value(slot, value);
    }

    /// Spawn `block` on a real OS thread and return an opaque thread
    /// id usable with [`join_os_thread`]. The default impl runs
    /// `block` eagerly on the calling stack (preserving the legacy
    /// serialized behaviour for hosts without a Vm) and returns `0`.
    /// The Vm overrides this with a true `std::thread::spawn`; the
    /// escaping value graph is published before the thread starts.
    fn spawn_os_thread(
        &mut self,
        block: &Value,
        out: &mut dyn Output,
    ) -> Result<u64, RuntimeError> {
        self.invoke_callable(block, &[], out).map(|_| 0)
    }

    /// Join the OS thread previously returned by [`spawn_os_thread`],
    /// propagating any error the thread body threw. Default impl is a
    /// no-op (the eager default already ran the body to completion).
    fn join_os_thread(&mut self, _id: u64) -> Result<(), RuntimeError> {
        Ok(())
    }

    /// Whether the OS thread with this id is still running. Default
    /// impl reports `false` (the eager default already completed).
    fn os_thread_alive(&mut self, _id: u64) -> bool {
        false
    }

    /// Dispatch a coroutine `block` onto a real worker thread for a
    /// parallel dispatcher (`Dispatchers.Default` / `Dispatchers.IO`)
    /// and return an opaque job id usable with [`join_dispatched`].
    /// The escaping value graph is `publish_deep`'d before the worker
    /// starts (same publication boundary as a spawned OS thread).
    /// `elastic` requests the unbounded (`IO`) pool rather than the
    /// CPU-bound (`Default`) pool. Default impl reuses
    /// [`spawn_os_thread`].
    fn dispatch_coroutine(
        &mut self,
        block: &Value,
        _elastic: bool,
        out: &mut dyn Output,
    ) -> Result<u64, RuntimeError> {
        self.spawn_os_thread(block, out)
    }

    /// Block the calling thread until the dispatched job completes,
    /// establishing the completion → joiner happens-before edge.
    /// Default impl reuses [`join_os_thread`].
    fn join_dispatched(&mut self, id: u64) -> Result<(), RuntimeError> {
        self.join_os_thread(id)
    }
}

/// Cooperative scheduler the runtime exposes to anything called
/// from inside an evaluation. A `launch { … }` builder pushes
/// onto the queue with [`Scheduler::spawn`]; a parked
/// `Continuation` records itself with [`Scheduler::schedule_resume`].
/// The interpreter pulls from these queues between rounds to
/// interleave sibling coroutines.
pub trait Scheduler: Send {
    /// Post a lambda to run as a freshly-launched task. The
    /// interpreter drives the body through the suspend state
    /// machine on the next drain pass.
    fn spawn(&mut self, block: Value);

    /// Park a continuation so the next drain pass resumes it.
    /// The interpreter calls `cont.resume(Unit)` on each parked
    /// continuation and re-drives the corresponding paused
    /// frame.
    fn schedule_resume(&mut self, cont: Value);

    /// Take and clear every queued launch. Drained FIFO.
    fn drain_launches(&mut self) -> Vec<Value>;

    /// Take and clear every parked continuation. Drained FIFO.
    fn drain_resumes(&mut self) -> Vec<Value>;
}

/// Default scheduler — keeps spawn/resume queues in a single
/// pair of Vecs. Suitable for single-threaded execution; alternate
/// backends (Godot async, custom event loops) implement the trait
/// directly.
#[derive(Default)]
pub struct InProcessScheduler {
    launches: Vec<Value>,
    resumes: Vec<Value>,
}

impl InProcessScheduler {
    #[must_use] 
    pub fn new() -> Self {
        Self::default()
    }
}

/// Bare-minimum host for unit tests of pure intrinsics (no
/// callable invocation, no scheduling). Panics if a binding under
/// test tries to call back through the host.
#[derive(Default)]
pub struct NoopHost {
    scheduler: InProcessScheduler,
}

impl IntrinsicHost for NoopHost {
    fn scheduler(&mut self) -> &mut dyn Scheduler {
        &mut self.scheduler
    }
    fn invoke_callable(
        &mut self,
        _callable: &Value,
        _args: &[Value],
        _out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        Err(RuntimeError::Unimplemented(
            "NoopHost::invoke_callable".into(),
        ))
    }
    fn invoke_callable_with_this(
        &mut self,
        _callable: &Value,
        _args: &[Value],
        _this_value: &Value,
        _out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        Err(RuntimeError::Unimplemented(
            "NoopHost::invoke_callable_with_this".into(),
        ))
    }
}

impl Scheduler for InProcessScheduler {
    fn spawn(&mut self, block: Value) {
        self.launches.push(block);
    }
    fn schedule_resume(&mut self, cont: Value) {
        self.resumes.push(cont);
    }
    fn drain_launches(&mut self) -> Vec<Value> {
        std::mem::take(&mut self.launches)
    }
    fn drain_resumes(&mut self) -> Vec<Value> {
        std::mem::take(&mut self.resumes)
    }
}
