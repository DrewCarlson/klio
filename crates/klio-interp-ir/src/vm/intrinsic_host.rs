use crate::{
    ActiveScopeGuard, Arc, AtomicOrdering, CooperativeInterceptor, DispatchGate, DriverWakeup,
    Output, PERSISTED_PARKED, SendableVmSeed, ThreadEntry, VmHost, VmIntrinsicHost,
    active_coro_scope, coroutine_time_mode, default_gate, io_gate, is_cancellation_exception,
    lookup_slot_owner, member_is_property, pad_args_with_defaults, set_coroutine_time_mode,
    with_coro, with_outer_this, with_receiver_labels,
};

impl VmIntrinsicHost<'_> {
    /// Build a transient `VmHost` over the same shared state, bound
    /// to `out` for the duration of one delegated evaluation.
    pub(crate) fn vm_host<'s>(&'s mut self, out: &'s mut dyn Output) -> VmHost<'s> {
        VmHost {
            globals: self.globals.clone(),
            module: Arc::clone(&self.module),
            scheduler: &mut *self.scheduler,
            out,
            instance_id_counter: Arc::clone(&self.instance_id_counter),
            classes: self.classes.clone(),
            prog: Arc::clone(&self.prog),
            anon_methods: self.anon_methods.clone(),
            class_default_outer: self.class_default_outer.clone(),
            closures: self.closures.clone(),
            out_sink: self.out_sink.clone(),
            threads: Arc::clone(&self.threads),
        }
    }

    /// A sibling `VmIntrinsicHost` over the same shared state, used
    /// when an intrinsic recursively dispatches another intrinsic.
    pub(crate) fn child_host(&mut self) -> VmIntrinsicHost<'_> {
        VmIntrinsicHost {
            scheduler: &mut *self.scheduler,
            module: Arc::clone(&self.module),
            closures: self.closures.clone(),
            globals: self.globals.clone(),
            classes: self.classes.clone(),
            prog: Arc::clone(&self.prog),
            anon_methods: self.anon_methods.clone(),
            class_default_outer: self.class_default_outer.clone(),
            instance_id_counter: Arc::clone(&self.instance_id_counter),
            out_sink: self.out_sink.clone(),
            threads: Arc::clone(&self.threads),
        }
    }

    /// Construct an instance through the full constructor pipeline.
    /// The intrinsic child host has no `new_instance` of its own, so
    /// build a transient `VmHost` over the same shared state (the
    /// pattern `eval_closure_raw` uses) and delegate. Lets a
    /// constructor reference (`::Box`, `Outer::Nested`) be invoked
    /// uniformly from stdlib higher-order ops like `map`/`fold`.
    pub(crate) fn construct(
        &mut self,
        class_id: klio_ir::ClassId,
        args: &[klio_runtime::Value],
        out: &mut dyn Output,
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        let mut host = self.vm_host(out);
        <VmHost as klio_ir::eval::Host>::new_instance(&mut host, class_id, args)
    }

    /// Evaluate an `IrClosure` and return the *raw* `EvalError` so the
    /// coroutine driver can observe `Suspended`. Mirrors the
    /// closure-setup half of `invoke_callable` (capture env, param
    /// fill, write-back) without flattening errors.
    pub(crate) fn eval_closure_raw(
        &mut self,
        callable: &klio_runtime::Value,
        args: &[klio_runtime::Value],
        this: Option<&klio_runtime::Value>,
        out: &mut dyn Output,
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        let klio_runtime::Value::IrClosure { id, captures } = callable else {
            return Err(klio_ir::eval::EvalError::Type(format!(
                "coroutine block is not a closure: `{}`",
                callable.type_fqn()
            )));
        };
        let live_captures: Vec<klio_runtime::Value> = (**captures).clone();
        // Closure id indexes the closure table.
        #[allow(clippy::cast_possible_truncation)]
        let info = self
            .closures
            .get(*id as usize)
            .ok_or_else(|| klio_ir::eval::EvalError::Type(format!("unknown IrClosure id {id}")))?;
        let func = self
            .module
            .funcs
            .get(info.body_func.0 as usize)
            .cloned()
            .ok_or_else(|| {
                klio_ir::eval::EvalError::Type(format!(
                    "closure body FuncId {} out of range",
                    info.body_func.0
                ))
            })?;
        let mut call_args: Vec<klio_runtime::Value> =
            Vec::with_capacity(info.n_params.max(args.len()));
        if let Some(t) = this {
            if info.n_params >= 1 {
                call_args.push(t.clone());
                for a in args {
                    call_args.push(a.clone());
                }
            } else {
                call_args.extend_from_slice(args);
            }
        } else {
            for i in 0..info.n_params {
                call_args.push(args.get(i).cloned().unwrap_or(klio_runtime::Value::Null));
            }
        }
        while call_args.len() < info.n_params {
            call_args.push(klio_runtime::Value::Null);
        }
        // Prefer the live captures carried on the closure Value (a
        // runtime-created closure boxes its captured bindings here);
        // fall back to the ClosureInfo cell for closures whose Value
        // carries none (e.g. top-level fn wrappers).
        let mut capture_values: Vec<klio_runtime::Value> =
            if live_captures.len() == info.capture_names.len() {
                live_captures
            } else {
                info.captures.borrow().clone()
            };
        if let Some(t) = this
            && let Some(idx) = info.capture_names.iter().position(|n| n == "this")
            && idx < capture_values.len()
        {
            capture_values[idx] = t.clone();
        }
        let scoped_env =
            klio_runtime::ObjRef::new(klio_runtime::Env::with_parent(self.globals.clone()));
        for (n, v) in info.capture_names.iter().zip(capture_values.iter()) {
            scoped_env.borrow_mut().define(n.clone(), v.clone());
        }
        let module = Arc::clone(&self.module);
        let result = {
            let mut host = VmHost {
                globals: scoped_env.clone(),
                module: Arc::clone(&self.module),
                scheduler: &mut *self.scheduler,
                out,
                instance_id_counter: Arc::clone(&self.instance_id_counter),
                classes: self.classes.clone(),
                prog: Arc::clone(&self.prog),
                anon_methods: self.anon_methods.clone(),
                class_default_outer: self.class_default_outer.clone(),
                closures: self.closures.clone(),
                out_sink: self.out_sink.clone(),
                threads: Arc::clone(&self.threads),
            };
            klio_ir::eval::eval_with_captures(&module, &func, call_args, capture_values, &mut host)
        };
        let new_captures: Vec<klio_runtime::Value> = info
            .capture_names
            .iter()
            .map(|n| {
                scoped_env
                    .borrow()
                    .lookup(n)
                    .unwrap_or(klio_runtime::Value::Null)
            })
            .collect();
        *info.captures.borrow_mut() = new_captures;
        result
    }

    /// Resume a parked activation with `value`, raw `EvalError` out.
    pub(crate) fn resume_raw(
        &mut self,
        state: klio_ir::eval::SuspendState,
        value: klio_runtime::Value,
        out: &mut dyn Output,
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        let module = Arc::clone(&self.module);
        let mut host = self.vm_host(out);
        klio_ir::eval::resume_continuation(&module, state, value, &mut host)
    }

    /// Hand a freshly-suspended Layer-1 activation to the active
    /// interceptor (Layer 2). Returns the token so the driver can
    /// recognise the root's completion.
    pub(crate) fn park(state: klio_ir::eval::SuspendState) -> u64 {
        with_coro(|s| {
            s.borrow_mut()
                .last_mut()
                .expect("park outside runBlocking")
                .intercept_suspend(state)
        })
    }

    /// Layer 2 — the default interceptor's dispatch loop, the engine
    /// behind `runBlocking`. Drives Layer-1 activations: it never
    /// inspects the suspend mechanism, only parks/resumes through
    /// the interceptor seam.
    pub(crate) fn drive_run_blocking(
        &mut self,
        block: &klio_runtime::Value,
        scope: &klio_runtime::Value,
        out: &mut dyn Output,
    ) -> Result<klio_runtime::Value, klio_runtime::RuntimeError> {
        self.drive_root(block, scope, out, false)
    }

    /// `drive_run_blocking` with control over whether a coroutine
    /// that parks indefinitely (awaiting an external resume) is
    /// preserved into program-lifetime storage on driver exit
    /// (`persist = true`, the `startCoroutine` boundary) or simply
    /// abandoned (`persist = false`, `runBlocking`).
    // Core coroutine driver loop; one tightly-coupled state machine.
    #[allow(clippy::too_many_lines)]
    pub(crate) fn drive_root(
        &mut self,
        block: &klio_runtime::Value,
        scope: &klio_runtime::Value,
        out: &mut dyn Output,
        persist: bool,
    ) -> Result<klio_runtime::Value, klio_runtime::RuntimeError> {
        /// Run `f` against the active interceptor.
        fn with_top<R>(f: impl FnOnce(&mut CooperativeInterceptor) -> R) -> R {
            with_coro(|s| f(s.borrow_mut().last_mut().expect("no active runBlocking")))
        }
        with_coro(|s| s.borrow_mut().push(CooperativeInterceptor::new()));
        let _active_scope = ActiveScopeGuard::enter(scope);
        let map_err = |e: klio_ir::eval::EvalError| -> klio_runtime::RuntimeError {
            match e {
                klio_ir::eval::EvalError::Throw(v) => klio_runtime::RuntimeError::Thrown(v),
                klio_ir::eval::EvalError::NonLocalReturn(v) => {
                    klio_runtime::RuntimeError::Return(v)
                }
                other => klio_runtime::RuntimeError::Type(format!("{other}")),
            }
        };
        // Root coroutine.
        let mut root_value: Option<klio_runtime::Value> = None;
        let mut root_token: Option<u64> = None;
        match self.eval_closure_raw(block, &[], Some(scope), out) {
            Ok(v) => root_value = Some(v),
            Err(klio_ir::eval::EvalError::Suspended(st)) => {
                root_token = Some(Self::park(*st));
            }
            Err(e) => {
                with_coro(|s| {
                    s.borrow_mut().pop();
                });
                return Err(map_err(e));
            }
        }
        loop {
            // 1. Start any queued child launches.
            let launched: Vec<klio_runtime::Value> =
                with_top(CooperativeInterceptor::drain_launched);
            let progressed = !launched.is_empty();
            for child in launched {
                match self.eval_closure_raw(&child, &[], Some(scope), out) {
                    Ok(_) => {}
                    Err(klio_ir::eval::EvalError::Suspended(st)) => {
                        Self::park(*st);
                    }
                    Err(e) => {
                        with_coro(|s| {
                            s.borrow_mut().pop();
                        });
                        return Err(map_err(e));
                    }
                }
            }
            // 2. Resume a ready coroutine, if any.
            let next_ready = with_top(CooperativeInterceptor::next_ready);
            if let Some(tok) = next_ready {
                let entry = with_top(|i| i.take_parked(tok));
                if let Some((st, _)) = entry {
                    let resume_with =
                        with_top(|i| i.take_resume_value(tok)).unwrap_or(klio_runtime::Value::Unit);
                    match self.resume_raw(st, resume_with, out) {
                        Ok(v) => {
                            if Some(tok) == root_token {
                                root_value = Some(v);
                                root_token = None;
                            }
                        }
                        Err(klio_ir::eval::EvalError::Suspended(st2)) => {
                            let new_tok = Self::park(*st2);
                            if Some(tok) == root_token {
                                root_token = Some(new_tok);
                            }
                        }
                        Err(klio_ir::eval::EvalError::Throw(v))
                            if Some(tok) != root_token && is_cancellation_exception(&v) =>
                        {
                            // Child launched activation observed a
                            // CancellationException from Job.cancel /
                            // withTimeout's cooperative cancel — swallow
                            // it the same way a real Kotlin runtime
                            // does for launched coroutines whose Job
                            // was cancelled. The root keeps its throw
                            // semantics so user-visible exceptions
                            // still propagate from runBlocking.
                        }
                        Err(e) => {
                            with_coro(|s| {
                                s.borrow_mut().pop();
                            });
                            return Err(map_err(e));
                        }
                    }
                }
                continue;
            }
            // 3. No ready coroutine — advance virtual time to the
            //    nearest timer and arm every coroutine due then.
            let advanced = with_top(CooperativeInterceptor::advance_time);
            if advanced {
                continue;
            }
            // 3b. Cross-thread bridge: drain any resumes posted by
            //     worker threads (e.g. `Dispatchers.Default`) into the
            //     interceptor; if a worker is still in flight, park
            //     on the driver's condvar until it posts.
            let wakeup = with_top(|i| Arc::clone(&i.wakeup));
            let drained = wakeup.drain_mailbox();
            if !drained.is_empty() {
                for (slot, val) in drained {
                    with_top(|i| {
                        i.resume_slot_value(slot, val);
                    });
                }
                continue;
            }
            if wakeup.pending() > 0 {
                let mb = wakeup.mailbox.lock().unwrap();
                if mb.is_empty() && wakeup.pending() > 0 {
                    let (mut guard, _) = wakeup
                        .cv
                        .wait_timeout(mb, std::time::Duration::from_millis(50))
                        .unwrap();
                    let pending: Vec<(i64, klio_runtime::Value)> = std::mem::take(&mut *guard);
                    drop(guard);
                    for (slot, val) in pending {
                        with_top(|i| {
                            i.resume_slot_value(slot, val);
                        });
                    }
                }
                continue;
            }
            // 4. Nothing ready, no timers: done (or deadlocked on an
            //    indefinitely-parked coroutine with no resumer).
            if !progressed {
                break;
            }
        }
        if persist {
            // A coroutine that parked indefinitely is alive, waiting
            // on a continuation held outside this driver. Preserve it
            // so a later external `resume` can drive it to completion.
            let saved = with_top(CooperativeInterceptor::drain_indefinite_parked);
            if !saved.is_empty() {
                PERSISTED_PARKED.with(|p| {
                    let mut m = p.borrow_mut();
                    for (slot, state) in saved {
                        m.insert(slot, state);
                    }
                });
            }
        }
        // Release any global slot-owner entries still pointing at
        // this driver's wakeup so cross-thread routing doesn't leak.
        let popped_wakeup = with_coro(|s| s.borrow_mut().pop().map(|i| i.wakeup));
        if let Some(w) = popped_wakeup {
            w.release_owned_slots();
        }
        Ok(root_value.unwrap_or(klio_runtime::Value::Unit))
    }
}

impl klio_runtime::IntrinsicHost for VmIntrinsicHost<'_> {
    fn run_blocking(
        &mut self,
        block: &klio_runtime::Value,
        scope: &klio_runtime::Value,
        out: &mut dyn Output,
    ) -> Result<klio_runtime::Value, klio_runtime::RuntimeError> {
        self.drive_run_blocking(block, scope, out)
    }

    fn coroutine_run_root(
        &mut self,
        block: &klio_runtime::Value,
        out: &mut dyn Output,
    ) -> Result<klio_runtime::Value, klio_runtime::RuntimeError> {
        // Already inside a cooperative driver (e.g. a child started by
        // `launch` while a `runBlocking` loop is running): join the
        // enclosing interceptor rather than spinning an isolated root.
        // The block runs on the shared virtual clock; if it suspends,
        // its activation is parked on the active interceptor and the
        // start completes normally (the enclosing driver loop resumes
        // it when its slot/timer is due), so concurrently-launched
        // children interleave by deadline instead of launch order.
        let nested = with_coro(|s| !s.borrow().is_empty());
        if nested {
            return match self.eval_closure_raw(block, &[], None, out) {
                Ok(v) => Ok(v),
                Err(klio_ir::eval::EvalError::Suspended(st)) => {
                    Self::park(*st);
                    Ok(klio_runtime::Value::Unit)
                }
                Err(klio_ir::eval::EvalError::Throw(v)) => {
                    Err(klio_runtime::RuntimeError::Thrown(v))
                }
                Err(klio_ir::eval::EvalError::NonLocalReturn(v)) => {
                    Err(klio_runtime::RuntimeError::Return(v))
                }
                Err(e) => Err(klio_runtime::RuntimeError::Type(format!("{e}"))),
            };
        }
        self.drive_root(block, &klio_runtime::Value::Unit, out, true)
    }

    fn coroutine_resume_external(
        &mut self,
        slot: i64,
        value: klio_runtime::Value,
        out: &mut dyn Output,
    ) {
        // A live cooperative driver still holding this slot? Enqueue
        // there — its drive loop runs the activation.
        let in_driver = with_coro(|s| {
            let mut stk = s.borrow_mut();
            for interceptor in stk.iter_mut().rev() {
                if interceptor.resume_slot_value(slot, value.clone()) {
                    return true;
                }
            }
            false
        });
        if in_driver {
            return;
        }
        // Cross-thread: the slot is owned by a driver running on a
        // different OS thread (e.g. a `Dispatchers.Default` worker
        // resuming `await` back on the main `runBlocking` pump).
        // Route through the driver's mailbox + condvar so it observes
        // the resume on its next pump cycle.
        if let Some(wakeup) = lookup_slot_owner(slot) {
            wakeup.post_resume(slot, value);
            return;
        }
        // Otherwise the coroutine parked inside a `startCoroutine`
        // driver that already returned; its state was preserved.
        // Drive it to completion (or its next suspension) now.
        let saved = PERSISTED_PARKED.with(|p| p.borrow_mut().remove(&slot));
        if let Some(state) = saved {
            // `value` is already the `Result` built by
            // `__klio_co_resume`; it is injected at the parked
            // `__klio_co_park` call site.
            let _ = self.resume_raw(state, value, out);
        }
    }

    fn coroutine_launch(
        &mut self,
        block: &klio_runtime::Value,
        _scope: &klio_runtime::Value,
        out: &mut dyn Output,
    ) -> Result<(), klio_runtime::RuntimeError> {
        let queued = with_coro(|s| {
            let mut stk = s.borrow_mut();
            if let Some(interceptor) = stk.last_mut() {
                interceptor.enqueue_launch(block.clone());
                true
            } else {
                false
            }
        });
        if queued {
            Ok(())
        } else {
            // No active runBlocking — run the child eagerly.
            self.invoke_callable(block, &[], out).map(|_| ())
        }
    }

    fn coroutine_park_slot(&mut self, slot: i64) {
        with_coro(|s| {
            if let Some(top) = s.borrow_mut().last_mut() {
                top.set_pending_slot(slot);
            }
        });
    }

    fn coroutine_arm_slot(&mut self, slot: i64) {
        with_coro(|s| {
            if let Some(top) = s.borrow_mut().last_mut() {
                top.set_pending_slot(slot);
            }
        });
    }

    fn coroutine_disarm_slot(&mut self) {
        with_coro(|s| {
            if let Some(top) = s.borrow_mut().last_mut() {
                top.clear_pending_slot();
            }
        });
    }

    fn coroutine_resume_slot(&mut self, slot: i64) {
        with_coro(|s| {
            let mut stk = s.borrow_mut();
            for interceptor in stk.iter_mut().rev() {
                if interceptor.resume_slot(slot) {
                    break;
                }
            }
        });
    }

    fn coroutine_resume_slot_value(&mut self, slot: i64, value: klio_runtime::Value) {
        with_coro(|s| {
            let mut stk = s.borrow_mut();
            for interceptor in stk.iter_mut().rev() {
                if interceptor.resume_slot_value(slot, value.clone()) {
                    break;
                }
            }
        });
    }

    fn coroutine_drain_to_idle(
        &mut self,
        out: &mut dyn Output,
    ) -> Result<(), klio_runtime::RuntimeError> {
        // Pump the active interceptor's queue: start launches,
        // resume ready tokens, advance virtual time. Stop when no
        // progress remains. CancellationException is swallowed for
        // child tokens (same shape as drive_root's per-token arm).
        loop {
            let launched: Vec<klio_runtime::Value> = with_coro(|s| {
                s.borrow_mut()
                    .last_mut()
                    .map(super::super::CooperativeInterceptor::drain_launched)
                    .unwrap_or_default()
            });
            let progressed = !launched.is_empty();
            let scope = active_coro_scope().unwrap_or(klio_runtime::Value::Unit);
            for child in launched {
                match self.eval_closure_raw(&child, &[], Some(&scope), out) {
                    Ok(_) => {}
                    Err(klio_ir::eval::EvalError::Suspended(st)) => {
                        Self::park(*st);
                    }
                    Err(klio_ir::eval::EvalError::Throw(v)) if is_cancellation_exception(&v) => {}
                    Err(e) => {
                        return Err(match e {
                            klio_ir::eval::EvalError::Throw(v) => {
                                klio_runtime::RuntimeError::Thrown(v)
                            }
                            klio_ir::eval::EvalError::NonLocalReturn(v) => {
                                klio_runtime::RuntimeError::Return(v)
                            }
                            other => klio_runtime::RuntimeError::Type(format!("{other}")),
                        });
                    }
                }
            }
            let next_ready = with_coro(|s| {
                s.borrow_mut()
                    .last_mut()
                    .and_then(super::super::CooperativeInterceptor::next_ready)
            });
            if let Some(tok) = next_ready {
                let entry =
                    with_coro(|s| s.borrow_mut().last_mut().and_then(|i| i.take_parked(tok)));
                if let Some((st, _)) = entry {
                    let resume_with = with_coro(|s| {
                        s.borrow_mut()
                            .last_mut()
                            .and_then(|i| i.take_resume_value(tok))
                    })
                    .unwrap_or(klio_runtime::Value::Unit);
                    match self.resume_raw(st, resume_with, out) {
                        Ok(_) => {}
                        Err(klio_ir::eval::EvalError::Suspended(st2)) => {
                            Self::park(*st2);
                        }
                        Err(klio_ir::eval::EvalError::Throw(v))
                            if is_cancellation_exception(&v) => {}
                        Err(e) => {
                            return Err(match e {
                                klio_ir::eval::EvalError::Throw(v) => {
                                    klio_runtime::RuntimeError::Thrown(v)
                                }
                                klio_ir::eval::EvalError::NonLocalReturn(v) => {
                                    klio_runtime::RuntimeError::Return(v)
                                }
                                other => klio_runtime::RuntimeError::Type(format!("{other}")),
                            });
                        }
                    }
                }
                continue;
            }
            let advanced = with_coro(|s| {
                s.borrow_mut()
                    .last_mut()
                    .is_some_and(super::super::CooperativeInterceptor::advance_time)
            });
            if advanced {
                continue;
            }
            if !progressed {
                break;
            }
        }
        Ok(())
    }

    fn coroutine_cancel_timed_parks_with(&mut self, cause: Option<klio_runtime::Value>) {
        let exc = cause.unwrap_or_else(|| klio_runtime::Value::Exception {
            fqn: Arc::new("kotlin.coroutines.cancellation.CancellationException".into()),
            message: Some(Arc::new("StandaloneCoroutine was cancelled".into())),
            cause: None,
        });
        let failure = klio_runtime::Value::Result {
            ok: false,
            payload: Box::new(exc),
        };
        with_coro(|s| {
            let mut stk = s.borrow_mut();
            if let Some(interceptor) = stk.last_mut() {
                interceptor.cancel_timed_parks(&failure);
            }
        });
    }

    // Single callable-dispatch flow over the value variants.
    #[allow(clippy::too_many_lines)]
    fn invoke_callable(
        &mut self,
        callable: &klio_runtime::Value,
        args: &[klio_runtime::Value],
        out: &mut dyn Output,
    ) -> Result<klio_runtime::Value, klio_runtime::RuntimeError> {
        // Bound method/property reference (`recv::method`,
        // `Cls::method`): the lowering creates a synthetic Instance
        // carrying `__bound_receiver__` + `__bound_name__`. When
        // invoked through a HOF (`xs.map(f::greet)` /
        // `joinToString(transform = String::shout)`), dispatch on
        // the captured receiver. An unbound class-method ref
        // (`String::shout` where receiver is a Class) passes its
        // first arg as the receiver.
        if let klio_runtime::Value::Instance(inst) = callable {
            let snap = inst.borrow();
            let recv = snap.get("__bound_receiver__");
            let name_v = snap.get("__bound_name__");
            drop(snap);
            if let (Some(recv), Some(klio_runtime::Value::String(name))) = (recv, name_v) {
                let unbound = matches!(&recv, klio_runtime::Value::Class(_)) && !args.is_empty();
                let (target, member_args): (klio_runtime::Value, Vec<klio_runtime::Value>) =
                    if unbound {
                        (args[0].clone(), args[1..].to_vec())
                    } else {
                        (recv.clone(), args.to_vec())
                    };
                let as_property =
                    member_args.is_empty() && member_is_property(&self.classes, &target, &name);
                let mut vm_host = self.vm_host(out);
                let result = if as_property {
                    <VmHost as klio_ir::eval::Host>::get_field(&mut vm_host, &target, &name)
                } else {
                    <VmHost as klio_ir::eval::Host>::call_member(
                        &mut vm_host,
                        &target,
                        &name,
                        &member_args,
                    )
                };
                return result.map_err(|e| match e {
                    klio_ir::eval::EvalError::Throw(v) => klio_runtime::RuntimeError::Thrown(v),
                    klio_ir::eval::EvalError::NonLocalReturn(v) => {
                        klio_runtime::RuntimeError::Return(v)
                    }
                    other => klio_runtime::RuntimeError::Type(format!("{other}")),
                });
            }
        }
        if let klio_runtime::Value::IrClosure { id, .. } = callable {
            // Closure id indexes the closure table.
            #[allow(clippy::cast_possible_truncation)]
            let info = self.closures.get(*id as usize).ok_or_else(|| {
                klio_runtime::RuntimeError::Type(format!("unknown IrClosure id {id}"))
            })?;
            let func = self
                .module
                .funcs
                .get(info.body_func.0 as usize)
                .cloned()
                .ok_or_else(|| {
                    klio_runtime::RuntimeError::Type(format!(
                        "closure body FuncId {} out of range",
                        info.body_func.0
                    ))
                })?;
            let defaults = self.prog.func_defaults.get(&info.body_func).cloned();
            let capture_values: Vec<klio_runtime::Value> = info.captures.borrow().clone();
            let module = Arc::clone(&self.module);
            // Mutable-capture support: pre-define each captured name
            // in a fresh env layered on top of globals so the body's
            // StoreGlobal writes land in the env, then read back the
            // updated values into the closure's captures so the
            // outer-frame WritebackCaptures Inst sees them.
            let scoped_env =
                klio_runtime::ObjRef::new(klio_runtime::Env::with_parent(self.globals.clone()));
            for (n, v) in info.capture_names.iter().zip(capture_values.iter()) {
                scoped_env.borrow_mut().define(n.clone(), v.clone());
            }
            let result = {
                let mut host = VmHost {
                    globals: scoped_env.clone(),
                    module: Arc::clone(&self.module),
                    scheduler: &mut *self.scheduler,
                    out,
                    instance_id_counter: Arc::clone(&self.instance_id_counter),
                    classes: self.classes.clone(),
                    prog: Arc::clone(&self.prog),
                    anon_methods: self.anon_methods.clone(),
                    class_default_outer: self.class_default_outer.clone(),
                    closures: self.closures.clone(),
                    out_sink: self.out_sink.clone(),
                    threads: Arc::clone(&self.threads),
                };
                match pad_args_with_defaults(
                    &module,
                    info.n_params,
                    args,
                    defaults.as_ref(),
                    &mut host,
                ) {
                    Ok(call_args) => klio_ir::eval::eval_with_captures(
                        &module,
                        &func,
                        call_args,
                        capture_values,
                        &mut host,
                    ),
                    Err(e) => Err(e),
                }
            };
            // Read back updated capture values into the closure's
            // captures cell so subsequent reads (and the outer
            // WritebackCaptures) see them.
            let new_captures: Vec<klio_runtime::Value> = info
                .capture_names
                .iter()
                .map(|n| {
                    scoped_env
                        .borrow()
                        .lookup(n)
                        .unwrap_or(klio_runtime::Value::Null)
                })
                .collect();
            *info.captures.borrow_mut() = new_captures;
            return result.map_err(|e| match e {
                klio_ir::eval::EvalError::Throw(v) => klio_runtime::RuntimeError::Thrown(v),
                klio_ir::eval::EvalError::NonLocalReturn(v) => {
                    klio_runtime::RuntimeError::Return(v)
                }
                other => klio_runtime::RuntimeError::Type(format!("{other}")),
            });
        }
        // A class value used as a function is a constructor
        // reference (`::Box`, `Outer::Nested`, passed to `map`/`fold`
        // etc.) — invoking it builds an instance.
        if let klio_runtime::Value::Class(def) = callable
            && let Some(class_id) = self.module.class_id(&def.name)
        {
            return self.construct(class_id, args, out).map_err(|e| match e {
                klio_ir::eval::EvalError::Throw(v) => klio_runtime::RuntimeError::Thrown(v),
                klio_ir::eval::EvalError::NonLocalReturn(v) => {
                    klio_runtime::RuntimeError::Return(v)
                }
                other => klio_runtime::RuntimeError::Type(format!("{other}")),
            });
        }
        if let klio_runtime::Value::Intrinsic { func, .. } = callable {
            let mut child = self.child_host();
            let mut ctx = klio_runtime::CallCtx {
                args,
                out,
                host: &mut child,
            };
            return func(&mut ctx);
        }
        // Callable instance (a user class declaring `operator fun
        // invoke`): treat the Instance as a callable by dispatching
        // through its `invoke` member. Lets a value like
        // `Tagger("note")` pass directly as a transform (`xs.map(t)`).
        if let klio_runtime::Value::Instance(_) = callable {
            let mut vm_host = self.vm_host(out);
            let r = <VmHost as klio_ir::eval::Host>::call_member(
                &mut vm_host,
                callable,
                "invoke",
                args,
            );
            return r.map_err(|e| match e {
                klio_ir::eval::EvalError::Throw(v) => klio_runtime::RuntimeError::Thrown(v),
                klio_ir::eval::EvalError::NonLocalReturn(v) => {
                    klio_runtime::RuntimeError::Return(v)
                }
                other => klio_runtime::RuntimeError::Type(format!("{other}")),
            });
        }
        Err(klio_runtime::RuntimeError::Unimplemented(format!(
            "Vm::invoke_callable on `{}`",
            callable.type_fqn()
        )))
    }

    fn invoke_callable_with_this(
        &mut self,
        callable: &klio_runtime::Value,
        args: &[klio_runtime::Value],
        this: &klio_runtime::Value,
        out: &mut dyn Output,
    ) -> Result<klio_runtime::Value, klio_runtime::RuntimeError> {
        // Receiver-typed lambda dispatch: bind the receiver as the
        // lambda's implicit `this` AND as the parser-injected `it`
        // when the lambda has a single param. Bodies that use
        // `it.foo()` see args[0] = receiver; bodies that use bare
        // names like `add(1)` resolve through the captured `this`
        // slot when the IR lower emitted CallMemberOrGlobal /
        // LoadFromThisOrGlobal (it does for unresolved bare names
        // in lambda bodies). The capture is overridden via the
        // closure's captures cell before invoke.
        if let klio_runtime::Value::IrClosure { id, .. } = callable {
            // Closure id indexes the closure table.
            #[allow(clippy::cast_possible_truncation)]
            let info = self.closures.get(*id as usize);
            if let Some(info) = info {
                // Override the captured `this` slot, if present.
                let prior_this: Option<klio_runtime::Value> = info
                    .capture_names
                    .iter()
                    .position(|n| n == "this")
                    .and_then(|idx| info.captures.borrow().get(idx).cloned());
                if let Some(idx) = info.capture_names.iter().position(|n| n == "this") {
                    let mut cap = info.captures.borrow_mut();
                    if idx < cap.len() {
                        cap[idx] = this.clone();
                    } else {
                        cap.resize(idx + 1, klio_runtime::Value::Null);
                        cap[idx] = this.clone();
                    }
                }
                // The receiver reaches a receiver lambda one of two
                // ways. If the body captured `this` (it uses bare
                // members / `this`), the override above already
                // delivered the receiver through that capture slot —
                // the declared params are the *value* params, so pass
                // only `args` (a `Sink.(Int) -> Unit` written
                // `{ v -> … }` has one param `v`, not the receiver).
                // Without a `this` capture the receiver is the lambda's
                // sole positional (`{ it.foo() }`-style), so prepend it.
                let has_this_capture = info.capture_names.iter().any(|n| n == "this");
                let mut all: Vec<klio_runtime::Value> = Vec::with_capacity(info.n_params);
                // Deliver the receiver as the leading positional only
                // when there is an unfilled leading slot for it
                // (`{ it.foo() }`-style receiver lambda invoked with
                // fewer args than params). When the caller already
                // supplies a value for every declared parameter, the
                // lambda is an ordinary value function (`{ it * 10 }`)
                // and the receiver must not displace its parameter.
                if info.n_params >= 1 && !has_this_capture && args.len() < info.n_params {
                    all.push(this.clone());
                    for a in args {
                        all.push(a.clone());
                    }
                } else {
                    all.extend_from_slice(args);
                }
                // The receiver just displaced an enclosing-class
                // `this` (e.g. `buildString { … }` written inside a
                // member). Keep that instance reachable as an outer
                // implicit receiver so bare members / `this@Outer`
                // inside the lambda still resolve, matching Kotlin's
                // nested-receiver rule.
                // Keep any distinct prior `this` (not only an
                // Instance) reachable as an outer implicit receiver:
                // an extension-receiver lambda such as
                // `IntRange.asFlow() = flow { forEach { emit(it) } }`
                // captures the range as its `this`, which the new
                // collector receiver displaces — `forEach` must still
                // resolve against the range via the enclosing
                // fallback.
                let pushed_outer = match &prior_this {
                    None | Some(klio_runtime::Value::Null | klio_runtime::Value::Unit) => false,
                    Some(klio_runtime::Value::Instance(a)) => !matches!(
                        this,
                        klio_runtime::Value::Instance(b)
                            if klio_runtime::ObjRef::ptr_eq(a, b)
                    ),
                    Some(_) => true,
                };
                if pushed_outer && let Some(p) = &prior_this {
                    with_outer_this(|s| s.borrow_mut().push(p.clone()));
                }
                // The new receiver is bound to the lambda's captured
                // `this` slot above. The member-extension visibility
                // filter consults the runtime enclosing-this stack, not
                // closure captures, so push the receiver for the
                // duration of the lambda call: a `with(a) { … }` body
                // that calls a member-extension declared on `a`'s
                // class then sees that owner as visible.
                let pushed_receiver = matches!(this, klio_runtime::Value::Instance(_));
                if pushed_receiver {
                    with_outer_this(|s| s.borrow_mut().push(this.clone()));
                }
                // If this lambda carries an implicit label (the
                // scope-fn / HOF it was passed to), record `(label,
                // receiver)` so `this@<label>` in the body — including an
                // outer label shadowed by a nested receiver lambda —
                // resolves to this receiver, whatever its type.
                let pushed_label = self
                    .module
                    .funcs
                    .get(info.body_func.0 as usize)
                    .and_then(|f| f.implicit_label.clone());
                if let Some(label) = &pushed_label {
                    with_receiver_labels(|s| {
                        s.borrow_mut().push((label.clone(), this.clone()));
                    });
                }
                let result = self.invoke_callable(callable, &all, out);
                if pushed_label.is_some() {
                    with_receiver_labels(|s| {
                        s.borrow_mut().pop();
                    });
                }
                if pushed_receiver {
                    with_outer_this(|s| {
                        s.borrow_mut().pop();
                    });
                }
                if pushed_outer {
                    with_outer_this(|s| {
                        s.borrow_mut().pop();
                    });
                }
                // Restore prior this so a closure reused with
                // different receivers preserves the original
                // captured value between uses.
                if let Some(idx) = info.capture_names.iter().position(|n| n == "this")
                    && let Some(prior) = prior_this
                {
                    let mut cap = info.captures.borrow_mut();
                    if idx < cap.len() {
                        cap[idx] = prior;
                    }
                }
                return result;
            }
            return self.invoke_callable(callable, args, out);
        }
        Err(klio_runtime::RuntimeError::Unimplemented(format!(
            "Vm::invoke_callable_with_this on `{}`",
            callable.type_fqn()
        )))
    }

    fn scheduler(&mut self) -> &mut dyn klio_runtime::Scheduler {
        &mut *self.scheduler
    }

    fn lookup_global(&mut self, name: &str) -> Option<klio_runtime::Value> {
        self.globals.borrow().lookup(name)
    }

    fn alloc_instance_id(&mut self) -> u64 {
        self.instance_id_counter
            .fetch_add(1, AtomicOrdering::Relaxed)
            + 1
    }

    fn new_synth_instance(
        &mut self,
        class_fqn: &str,
        identity: u64,
        fields: Vec<(String, klio_runtime::Value)>,
    ) -> klio_runtime::Value {
        let simple = class_fqn
            .rsplit('.')
            .next()
            .unwrap_or(class_fqn)
            .to_string();
        let class_def = Arc::new(klio_runtime::ClassDef {
            name: simple,
            fqn: class_fqn.to_string(),
            annotation_names: Vec::new(),
            primary_params: Vec::new(),
            methods: Vec::new(),
            body_properties: Vec::new(),
            init_blocks: Vec::new(),
            init_block_property_positions: Vec::new(),
            is_data: false,
            is_value: false,
            is_object: false,
            is_enum: false,
            is_sealed: false,
            is_open: false,
            is_abstract: false,
            is_inner: false,
            is_anonymous: true,
            secondary_ctors: Vec::new(),
            supertype_names: Vec::new(),
            parent: klio_runtime::ObjRef::new(None),
            interfaces: klio_runtime::ObjRef::new(Vec::new()),
            is_interface: false,
            is_fun_interface: false,
            parent_ctor_args: Vec::new(),
            enum_entries: klio_runtime::ObjRef::new(Vec::new()),
            companion: klio_runtime::ObjRef::new(None),
            enclosing_class: klio_runtime::ObjRef::new(None),
            nested_classes: klio_runtime::ObjRef::new(Vec::new()),
            captured_env: klio_runtime::ObjRef::new(klio_runtime::Env::new()),
            supertype_delegates: klio_runtime::ObjRef::new(Vec::new()),
            delegate_forwarders: klio_runtime::ObjRef::new(Vec::new()),
            object_singleton: klio_runtime::ObjRef::new(None),
        });
        let inst = klio_runtime::ObjRef::new(klio_runtime::InstanceData {
            class: class_def,
            fields,
            outer: None,
            identity,
            native_state: None,
        });
        klio_runtime::Value::Instance(inst)
    }

    fn invoke_method(
        &mut self,
        receiver: &klio_runtime::Value,
        name: &str,
        args: &[klio_runtime::Value],
        out: &mut dyn Output,
    ) -> Option<Result<klio_runtime::Value, klio_runtime::RuntimeError>> {
        // Build a VmHost that shares this IntrinsicHost's tables
        // and route through call_member so the dispatch picks up
        // user override methods (`override fun toString()` etc.).
        let mut host = self.vm_host(out);
        match <VmHost as klio_ir::eval::Host>::call_member(&mut host, receiver, name, args) {
            Ok(v) => Some(Ok(v)),
            Err(klio_ir::eval::EvalError::Throw(v)) => {
                Some(Err(klio_runtime::RuntimeError::Thrown(v)))
            }
            Err(_) => None,
        }
    }

    /// Spawn `block` on a real OS thread.
    ///
    /// The escaping value graph (`block` and the shared roots the
    /// child may observe) is `publish_deep`'d *before* the thread
    /// starts, which is the happens-before that `ObjRef`'s
    /// `unsafe impl Send` requires. Over-publishing is safe; cells
    /// the child creates after spawn are thread-local to it until it
    /// republishes them, which is fine.
    fn spawn_os_thread(
        &mut self,
        block: &klio_runtime::Value,
        _out: &mut dyn Output,
    ) -> Result<u64, klio_runtime::RuntimeError> {
        // Publish the escaping block and every shared root the child
        // can reach so observing them from the new thread is sound.
        block.publish_deep();
        klio_runtime::publish_env_deep(&self.globals);
        for def in self.classes.borrow().values() {
            klio_runtime::Value::Class(Arc::clone(def)).publish_deep();
        }
        for v in self.class_default_outer.borrow().values() {
            v.publish_deep();
        }
        self.classes.publish();
        self.anon_methods.publish();
        self.class_default_outer.publish();
        klio_runtime::fence_and_publish(); // thread start

        let seed = SendableVmSeed {
            module: Arc::clone(&self.module),
            globals: self.globals.clone(),
            instance_id_counter: Arc::clone(&self.instance_id_counter),
            classes: self.classes.clone(),
            prog: Arc::clone(&self.prog),
            anon_methods: self.anon_methods.clone(),
            class_default_outer: self.class_default_outer.clone(),
            closures: self.closures.clone(),
            out_sink: self.out_sink.clone(),
            threads: Arc::clone(&self.threads),
        };
        let block = block.clone();
        let time_mode = coroutine_time_mode();
        let id = self
            .instance_id_counter
            .fetch_add(1, AtomicOrdering::Relaxed);

        let handle = std::thread::Builder::new()
            .name(format!("klio-thread-{id}"))
            .spawn(move || -> Result<(), klio_runtime::RuntimeError> {
                set_coroutine_time_mode(time_mode);
                let mut vm = seed.materialize();
                let r = vm.run_thread_block(&block);
                klio_runtime::fence_and_publish(); // body completion → joiner
                match r {
                    Ok(v) | Err(klio_runtime::RuntimeError::Return(v)) => {
                        v.publish_deep();
                        Ok(())
                    }
                    Err(e) => Err(e),
                }
            })
            .map_err(|e| {
                klio_runtime::RuntimeError::Type(format!("failed to spawn OS thread: {e}"))
            })?;

        self.threads
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(
                id,
                ThreadEntry {
                    handle: Some(handle),
                },
            );
        Ok(id)
    }

    fn join_os_thread(&mut self, id: u64) -> Result<(), klio_runtime::RuntimeError> {
        let handle = {
            let mut g = self
                .threads
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            g.get_mut(&id).and_then(|e| e.handle.take())
        };
        let Some(handle) = handle else {
            // Already joined (idempotent) or unknown id — the
            // happens-before edge was established by the first join.
            return Ok(());
        };
        let res = handle
            .join()
            .map_err(|_| klio_runtime::RuntimeError::Type("spawned thread panicked".into()))?;
        klio_runtime::fence_and_publish(); // thread join
        res
    }

    fn os_thread_alive(&mut self, id: u64) -> bool {
        let g = self
            .threads
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        match g.get(&id) {
            Some(e) => e.handle.as_ref().is_some_and(|h| !h.is_finished()),
            None => false,
        }
    }

    /// Dispatch a coroutine body onto the parallel worker pool.
    ///
    /// Realised as a real OS thread per job (reusing the spawned-
    /// thread publication + join machinery), but gated by a process-
    /// global counting semaphore so concurrency is bounded:
    /// `Dispatchers.Default` to the host core count, `Dispatchers.IO`
    /// to a large elastic cap. The escaping graph is `publish_deep`'d
    /// before the worker starts (the `ObjRef` `Send` happens-before);
    /// the worker parks on the gate, runs the body once a permit is
    /// free, then publishes its terminal value for the joiner.
    fn dispatch_coroutine(
        &mut self,
        block: &klio_runtime::Value,
        elastic: bool,
        _out: &mut dyn Output,
    ) -> Result<u64, klio_runtime::RuntimeError> {
        block.publish_deep();
        klio_runtime::publish_env_deep(&self.globals);
        for def in self.classes.borrow().values() {
            klio_runtime::Value::Class(Arc::clone(def)).publish_deep();
        }
        for v in self.class_default_outer.borrow().values() {
            v.publish_deep();
        }
        self.classes.publish();
        self.anon_methods.publish();
        self.class_default_outer.publish();
        klio_runtime::fence_and_publish(); // dispatch start

        let seed = SendableVmSeed {
            module: Arc::clone(&self.module),
            globals: self.globals.clone(),
            instance_id_counter: Arc::clone(&self.instance_id_counter),
            classes: self.classes.clone(),
            prog: Arc::clone(&self.prog),
            anon_methods: self.anon_methods.clone(),
            class_default_outer: self.class_default_outer.clone(),
            closures: self.closures.clone(),
            out_sink: self.out_sink.clone(),
            threads: Arc::clone(&self.threads),
        };
        let block = block.clone();
        let time_mode = coroutine_time_mode();
        let id = self
            .instance_id_counter
            .fetch_add(1, AtomicOrdering::Relaxed);
        let gate: &'static DispatchGate = if elastic { io_gate() } else { default_gate() };
        // Tag this dispatch against the currently-active driver so its
        // pump knows to wait for the worker rather than treating "no
        // local progress" as completion.
        let driver_wakeup: Option<Arc<DriverWakeup>> =
            with_coro(|s| s.borrow().last().map(|top| Arc::clone(&top.wakeup)));
        if let Some(w) = driver_wakeup.as_ref() {
            w.worker_started();
        }
        let worker_wakeup = driver_wakeup.clone();

        let handle = std::thread::Builder::new()
            .name(format!("klio-dispatch-{id}"))
            .stack_size(64 * 1024 * 1024)
            .spawn(move || -> Result<(), klio_runtime::RuntimeError> {
                gate.acquire();
                set_coroutine_time_mode(time_mode);
                let mut vm = seed.materialize();
                let r = vm.run_thread_block(&block);
                klio_runtime::fence_and_publish();
                gate.release();
                if let Some(w) = worker_wakeup.as_ref() {
                    w.worker_done();
                }
                match r {
                    Ok(v) | Err(klio_runtime::RuntimeError::Return(v)) => {
                        v.publish_deep();
                        Ok(())
                    }
                    Err(e) => Err(e),
                }
            })
            .map_err(|e| {
                klio_runtime::RuntimeError::Type(format!("failed to spawn dispatch worker: {e}"))
            })?;

        self.threads
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(
                id,
                ThreadEntry {
                    handle: Some(handle),
                },
            );
        Ok(id)
    }

    fn join_dispatched(&mut self, id: u64) -> Result<(), klio_runtime::RuntimeError> {
        self.join_os_thread(id)
    }
}
