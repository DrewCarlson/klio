use crate::*;

impl DriverWakeup {
    pub(crate) fn new() -> Arc<Self> {
        Arc::new(Self {
            mailbox: std::sync::Mutex::new(Vec::new()),
            pending_workers: std::sync::atomic::AtomicUsize::new(0),
            cv: std::sync::Condvar::new(),
            owned_slots: std::sync::Mutex::new(std::collections::HashSet::new()),
        })
    }

    pub(crate) fn post_resume(&self, slot: i64, value: klio_runtime::Value) {
        self.mailbox.lock().unwrap().push((slot, value));
        self.cv.notify_all();
    }

    pub(crate) fn drain_mailbox(&self) -> Vec<(i64, klio_runtime::Value)> {
        std::mem::take(&mut *self.mailbox.lock().unwrap())
    }

    pub(crate) fn pending(&self) -> usize {
        self.pending_workers.load(std::sync::atomic::Ordering::Acquire)
    }

    pub(crate) fn worker_started(&self) {
        self.pending_workers.fetch_add(1, std::sync::atomic::Ordering::AcqRel);
    }

    pub(crate) fn worker_done(&self) {
        self.pending_workers.fetch_sub(1, std::sync::atomic::Ordering::AcqRel);
        self.cv.notify_all();
    }

    pub(crate) fn add_owned_slot(&self, slot: i64) {
        self.owned_slots.lock().unwrap().insert(slot);
    }

    pub(crate) fn release_owned_slots(self: &Arc<Self>) {
        let mut owned = self.owned_slots.lock().unwrap();
        let slots: Vec<i64> = owned.drain().collect();
        drop(owned);
        let mut map = SLOT_OWNERS.lock().unwrap();
        for s in slots {
            map.remove(&s);
        }
    }
}

impl CooperativeInterceptor {
    /// Fresh interceptor honoring this thread's time mode.
    pub(crate) fn new() -> Self {
        Self {
            wakeup: DriverWakeup::new(),
            mode: coroutine_time_mode(),
            started: None,
            next_token: 0,
            virtual_now: 0,
            parked: std::collections::HashMap::new(),
            ready: std::collections::VecDeque::new(),
            launched: Vec::new(),
            pending_slot: None,
            slot_to_token: std::collections::HashMap::new(),
            token_resume_value: std::collections::HashMap::new(),
        }
    }

    /// Current clock reading in millis: the logical clock under
    /// `Virtual`, elapsed wall-clock since first use under `Wall`.
    pub(crate) fn now_millis(&mut self) -> i64 {
        match self.mode {
            TimeMode::Virtual => self.virtual_now,
            TimeMode::Wall => {
                let start = *self
                    .started
                    .get_or_insert_with(std::time::Instant::now);
                start.elapsed().as_millis() as i64
            }
        }
    }

    /// Seam: intercept a freshly-suspended activation. Assigns a
    /// token, decodes the Layer-2 resume directive carried in
    /// `wake_in_millis` (negative = park indefinitely, `0` = ready
    /// now, positive = wake that much later on the active clock),
    /// and records it. Returns the token so the driver can
    /// recognise the root's completion.
    pub(crate) fn intercept_suspend(&mut self, mut state: klio_ir::eval::SuspendState) -> u64 {
        self.next_token += 1;
        let token = self.next_token;
        state.token = token;
        let wake_at = if state.wake_in_millis < 0 {
            i64::MAX
        } else {
            self.now_millis() + state.wake_in_millis
        };
        if state.wake_in_millis == 0 {
            self.ready.push_back(token);
        }
        // Bind an armed slot to *any* parked activation, not only
        // indefinite parks. `suspendCoroutineUninterceptedOrReturn`
        // arms its slot before running its block; if the block
        // suspends on a *timed* `delay` (e.g. inside `withTimeout`),
        // the activation must stay reachable through the slot so a
        // later cancellation can resume it early with the exception
        // instead of waiting out the timer.
        if let Some(slot) = self.pending_slot.take() {
            self.slot_to_token.insert(slot, token);
        }
        self.parked.insert(token, (state, wake_at));
        token
    }

    /// Seam: record the slot the next indefinitely-parked
    /// activation is waiting on (set by `__kxco_parkSlot`). Also
    /// publishes the slot → driver mapping so a worker thread can
    /// route its completion resume back through the driver's mailbox.
    pub(crate) fn set_pending_slot(&mut self, slot: i64) {
        self.pending_slot = Some(slot);
        register_slot_owner(slot, &self.wakeup);
    }

    pub(crate) fn clear_pending_slot(&mut self) {
        self.pending_slot = None;
    }

    /// Seam: if a token is waiting on `slot`, move it into the ready
    /// queue and clear the mapping. Returns whether a waiter was
    /// found.
    pub(crate) fn resume_slot(&mut self, slot: i64) -> bool {
        if let Some(token) = self.slot_to_token.remove(&slot) {
            unregister_slot(slot);
            self.ready.push_back(token);
            true
        } else {
            false
        }
    }

    /// Like [`resume_slot`] but records `value` so the resumed
    /// activation observes it as its suspending call's result.
    pub(crate) fn resume_slot_value(&mut self, slot: i64, value: klio_runtime::Value) -> bool {
        if let Some(token) = self.slot_to_token.remove(&slot) {
            unregister_slot(slot);
            self.token_resume_value.insert(token, value);
            self.ready.push_back(token);
            true
        } else {
            false
        }
    }

    /// Take the pending resume value for `token`, if one was set by
    /// [`resume_slot_value`].
    pub(crate) fn take_resume_value(&mut self, token: u64) -> Option<klio_runtime::Value> {
        self.token_resume_value.remove(&token)
    }

    /// Remove every indefinitely-parked activation still waiting on a
    /// slot, returning `(slot, state)` pairs. Used by the
    /// `startCoroutine` driver to hand a coroutine that parked
    /// awaiting an external `resume` to program-lifetime storage so
    /// it survives the driver's return.
    pub(crate) fn drain_indefinite_parked(
        &mut self,
    ) -> Vec<(i64, klio_ir::eval::SuspendState)> {
        let slots: Vec<(i64, u64)> = self
            .slot_to_token
            .iter()
            .map(|(s, t)| (*s, *t))
            .collect();
        let mut out = Vec::new();
        for (slot, token) in slots {
            let is_indefinite = self
                .parked
                .get(&token)
                .map(|(_, wake)| *wake == i64::MAX)
                .unwrap_or(false);
            if is_indefinite {
                if let Some((state, _)) = self.parked.remove(&token) {
                    self.slot_to_token.remove(&slot);
                    out.push((slot, state));
                }
            }
        }
        out
    }

    /// Seam: take the child `launch` blocks queued this round.
    pub(crate) fn drain_launched(&mut self) -> Vec<klio_runtime::Value> {
        std::mem::take(&mut self.launched)
    }

    /// Seam: queue a child `launch` block.
    pub(crate) fn enqueue_launch(&mut self, block: klio_runtime::Value) {
        self.launched.push(block);
    }

    /// Seam: next ready token, if any.
    pub(crate) fn next_ready(&mut self) -> Option<u64> {
        self.ready.pop_front()
    }

    /// Seam: take the parked activation for a token.
    pub(crate) fn take_parked(&mut self, token: u64) -> Option<(klio_ir::eval::SuspendState, i64)> {
        self.parked.remove(&token)
    }

    /// Wake every parked activation whose wake-at is a finite
    /// virtual-time deadline (i.e. parked on a `delay`/`withTimeout`).
    /// Each is removed from `parked`, its resume value is set to the
    /// supplied `failure` (a `Value::Result { ok: false, … }` that
    /// the resume path in `klio_ir::eval` routes as a throw at the
    /// suspension point), and the token is queued ready. Indefinite
    /// parks (wake_at == i64::MAX) such as join/await/channel-receive
    /// are not touched.
    pub(crate) fn cancel_timed_parks(&mut self, failure: klio_runtime::Value) {
        let due: Vec<u64> = self
            .parked
            .iter()
            .filter(|(_, (_, w))| *w != i64::MAX)
            .map(|(k, _)| *k)
            .collect();
        for tok in due {
            if let Some(entry) = self.parked.get_mut(&tok) {
                entry.1 = 0;
            }
            self.token_resume_value.insert(tok, failure.clone());
            self.ready.push_back(tok);
        }
    }

    /// Seam: nothing ready — advance the clock to the soonest timer
    /// and arm every activation due then. Under `Virtual` the clock
    /// jumps instantly; under `Wall` the thread sleeps until the
    /// real deadline. Returns whether any progress was made.
    pub(crate) fn advance_time(&mut self) -> bool {
        let soonest = self
            .parked
            .values()
            .map(|(_, w)| *w)
            .filter(|w| *w != i64::MAX)
            .min();
        let Some(t) = soonest else { return false };
        match self.mode {
            TimeMode::Virtual => {
                if t > self.virtual_now {
                    self.virtual_now = t;
                }
            }
            TimeMode::Wall => {
                let wait = (t - self.now_millis()).max(0);
                if wait > 0 {
                    std::thread::sleep(std::time::Duration::from_millis(wait as u64));
                }
            }
        }
        let now = self.now_millis();
        let mut due: Vec<u64> = self
            .parked
            .iter()
            .filter(|(_, (_, w))| *w != i64::MAX && *w <= now)
            .map(|(k, _)| *k)
            .collect();
        due.sort_unstable();
        for tok in &due {
            self.ready.push_back(*tok);
        }
        !due.is_empty()
    }
}
