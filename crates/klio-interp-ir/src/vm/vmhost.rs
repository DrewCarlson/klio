use crate::*;

impl<'a> VmHost<'a> {
    /// Drive a top-level property's initializer on demand when it is
    /// read before the in-order startup pass has reached it (an
    /// earlier top-level initializer constructs a class whose body
    /// reads a property declared later). Returns the value (also
    /// cached into `globals` so the later startup pass and subsequent
    /// reads are consistent), or `None` if `name` is not a top-level
    /// property. A thread-local guard breaks initializer cycles: a
    /// re-entrant read returns `None`, matching the JVM static-field
    /// zero/null default rather than recursing.
    pub(crate) fn ensure_top_level_inited(
        &mut self,
        name: &str,
    ) -> Result<Option<klio_runtime::Value>, klio_ir::eval::EvalError> {
        if let Some(v) = self.globals.borrow().lookup(name) {
            return Ok(Some(v));
        }
        let Some(fid) = self.prog.top_level_prop_inits.get(name).copied() else {
            return Ok(None);
        };
        let already = IN_PROGRESS.with(|s| !s.borrow_mut().insert(name.to_string()));
        if already {
            return Ok(None);
        }
        struct Guard(String);
        impl Drop for Guard {
            fn drop(&mut self) {
                IN_PROGRESS.with(|s| {
                    s.borrow_mut().remove(&self.0);
                });
            }
        }
        let _guard = Guard(name.to_string());
        let func = self
            .module
            .funcs
            .get(fid.0 as usize)
            .cloned()
            .ok_or_else(|| {
                klio_ir::eval::EvalError::Type(format!(
                    "top-level prop init FuncId {} out of range",
                    fid.0
                ))
            })?;
        let module = Arc::clone(&self.module);
        let v = klio_ir::eval::eval_with(&module, &func, Vec::new(), self)?;
        self.globals.borrow_mut().define(name, v.clone());
        Ok(Some(v))
    }

    /// Join the spawned OS thread `id`, propagating a thrown
    /// Throwable as a `RuntimeError`. Idempotent: a second join (or
    /// an unknown id) is a no-op since the happens-before edge was
    /// already established. `fence_and_publish` marks the boundary.
    pub(crate) fn join_spawned(&mut self, id: u64) -> Result<(), klio_runtime::RuntimeError> {
        let handle = {
            let mut g = self.threads.lock().unwrap_or_else(|e| e.into_inner());
            g.get_mut(&id).and_then(|e| e.handle.take())
        };
        let Some(handle) = handle else {
            return Ok(());
        };
        let res = handle.join().map_err(|_| {
            klio_runtime::RuntimeError::Type("spawned thread panicked".into())
        })?;
        klio_runtime::fence_and_publish(); // thread join
        res
    }

    /// Whether spawned thread `id` is still running.
    pub(crate) fn thread_alive(&self, id: u64) -> bool {
        let g = self.threads.lock().unwrap_or_else(|e| e.into_inner());
        match g.get(&id) {
            Some(e) => e.handle.as_ref().map(|h| !h.is_finished()).unwrap_or(false),
            None => false,
        }
    }

    /// Drive a lazy `Value::Sequence` to completion. Each upstream
    /// item flows through the pipeline ops by invoking the user
    /// lambdas via `self.call_value`. Sorting ops buffer-and-emit.
    /// Drive a lazy `Value::Sequence` to completion. The HOF
    /// dispatch lives in `klio-stdlib`; the Vm only supplies an
    /// `IntrinsicHost` so the op lambdas resolve back into IR
    /// closures. Building the host here mirrors `dispatch_intrinsic`.
    pub(crate) fn materialise_sequence(
        &mut self,
        seq_val: &klio_runtime::Value,
    ) -> Result<Vec<klio_runtime::Value>, klio_ir::eval::EvalError> {
        let mut intrinsic_host = VmIntrinsicHost {
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
        };
        klio_stdlib::materialise_sequence(seq_val, &mut intrinsic_host, &mut *self.out)
            .map_err(|e| match e {
                klio_runtime::RuntimeError::Thrown(v) => klio_ir::eval::EvalError::Throw(v),
                other => klio_ir::eval::EvalError::Type(format!("{other}")),
            })
    }
    /// Score an arg/param compatibility for overload resolution.
    /// Higher is better. Exact type match wins over `Any`, which
    /// wins over a type-parameter (`T`) fallback. Returning `None`
    /// disqualifies the candidate.
    pub(crate) fn overload_score_arg(
        &self,
        param_ty: &klio_ir::TypeRef,
        arg: &klio_runtime::Value,
    ) -> Option<i32> {
        let nm = param_ty.name.as_str();
        let owned;
        let v_ty: &str = if let klio_runtime::Value::Instance(i) = arg {
            owned = i.borrow().class.name.clone();
            owned.as_str()
        } else {
            let fqn = arg.type_fqn();
            fqn.rsplit('.').next().unwrap_or(fqn)
        };
        if nm == v_ty {
            return Some(100);
        }
        if matches!(nm, "Any" | "Any?") {
            return Some(10);
        }
        if matches!(arg, klio_runtime::Value::Null) && param_ty.nullable {
            return Some(50);
        }
        // Numeric widening: Int → Long, Int → Double, Long → Double.
        match (nm, v_ty) {
            ("Long", "Int") => return Some(40),
            ("Double", "Int") | ("Double", "Long") | ("Float", "Int") => return Some(30),
            _ => {}
        }
        // A callable argument (lambda / closure / bound method)
        // against a function-typed parameter. The lowered param type
        // doesn't preserve the arrow shape, so accept any callable at
        // a low score — concrete-type params still outrank it and
        // arity does the real disambiguation between overloads.
        let arg_arity: Option<usize> = match arg {
            klio_runtime::Value::Lambda { params, .. } => Some(params.len()),
            klio_runtime::Value::IrClosure { id, .. } => {
                self.closures.get(*id as usize).map(|c| c.n_params)
            }
            _ => None,
        };
        let is_callable = arg_arity.is_some()
            || arg.type_fqn().starts_with("kotlin.Function");
        if is_callable {
            // `FunctionN` carries the expected lambda arity. Rank an
            // exact match high so overloads differing only in the
            // functional parameter's shape are disambiguated; a
            // mismatch still scores (low) rather than disqualifying,
            // to stay tolerant of receiver-style function types.
            if let Some(expected) = nm.strip_prefix("Function") {
                if let Ok(want) = expected.parse::<usize>() {
                    return Some(match arg_arity {
                        Some(got) if got == want => 90,
                        Some(_) => 2,
                        None => 15,
                    });
                }
            }
            return Some(15);
        }
        // Subtype: an instance argument whose class transitively
        // extends / implements the parameter's nominal type matches
        // (below an exact-name match, above generic/Unit), so an
        // overload declared on a supertype (`f(s: Segment)`) is picked
        // for a subclass argument (`ChannelSegment`).
        if let klio_runtime::Value::Instance(_) = arg {
            // Distance-weighted subtype match: a parameter type that
            // is *closer* in the receiver's hierarchy outranks a more
            // distant ancestor, so `x.ensureActive()` on a value that
            // is both a `Job` and (transitively) a `CoroutineContext`
            // binds `Job.ensureActive` rather than the more general
            // `CoroutineContext.ensureActive` (which would recurse).
            let mut queue: std::collections::VecDeque<(String, i32)> =
                std::collections::VecDeque::new();
            let mut seen: std::collections::HashSet<String> =
                std::collections::HashSet::new();
            queue.push_back((v_ty.to_string(), 0));
            while let Some((cur, depth)) = queue.pop_front() {
                if !seen.insert(cur.clone()) {
                    continue;
                }
                if cur == nm {
                    // Direct match 60; each hierarchy step costs 1,
                    // floored well above generic(5)/Unit(1).
                    return Some(60 - depth.min(50));
                }
                if let Some(def) = self.classes.borrow().get(&cur).cloned() {
                    for sup in &def.supertype_names {
                        queue.push_back((sup.clone(), depth + 1));
                    }
                }
            }
        }
        // Builtin runtime types satisfy their nominal supertypes
        // (`List`/`MutableList` → `Collection`/`Iterable`, a range →
        // `Iterable`/`ClosedRange`, …). Without this a `Value::List`
        // (not a `Value::Instance`, so the subtype walk above is
        // skipped) scored equally against every same-named extension
        // receiver, so `list.asFlow()` could bind `(() -> T).asFlow`
        // instead of `Iterable<T>.asFlow`. Rank a builtin-supertype
        // match below an exact name but above a callable / generic.
        let builtin_supers: &[&str] = match v_ty {
            "List" => &[
                "Collection", "Iterable", "MutableList",
                "MutableCollection", "MutableIterable",
            ],
            "MutableList" => &[
                "List", "Collection", "Iterable", "MutableCollection",
                "MutableIterable",
            ],
            "Set" => &[
                "Collection", "Iterable", "MutableSet",
                "MutableCollection", "MutableIterable",
            ],
            "MutableSet" => &[
                "Set", "Collection", "Iterable", "MutableCollection",
                "MutableIterable",
            ],
            "Map" => &["MutableMap"],
            "MutableMap" => &["Map"],
            "IntRange" => &[
                "IntProgression", "ClosedRange", "Iterable",
                "OpenEndRange",
            ],
            "LongRange" => &[
                "LongProgression", "ClosedRange", "Iterable",
                "OpenEndRange",
            ],
            "CharRange" => &[
                "CharProgression", "ClosedRange", "Iterable",
                "OpenEndRange",
            ],
            "IntProgression" | "LongProgression" | "CharProgression" => {
                &["Iterable"]
            }
            "String" => &["CharSequence", "Comparable"],
            _ => &[],
        };
        let nm_simple = nm.rsplit('.').next().unwrap_or(nm);
        // Position in the supers list = distance from the runtime
        // type. Closer (lower index) outranks further (higher index)
        // so an exact-class match wins, then the immediate supertype,
        // then progressively further ones. Without this graduation a
        // call like `mutableList.last()` scores `Iterable.last` and
        // `List.last` identically (both 55) and the first-registered
        // candidate wins — which lets a generic shim recurse on its
        // own smart-cast-narrowed `this.last()` call.
        if let Some(pos) =
            builtin_supers.iter().position(|s| *s == nm || *s == nm_simple)
        {
            return Some(75 - (pos as i32).min(20));
        }
        // Generic single-letter type-parameter — accept any.
        if nm.len() <= 2 && nm.chars().all(|c| c.is_ascii_uppercase()) {
            return Some(5);
        }
        // Unit param type (no info preserved at lower time) — accept
        // anything but rank lowest so other overloads with concrete
        // type info still win.
        if nm == "Unit" {
            return Some(1);
        }
        None
    }

    /// Conservative "this argument provably is not that parameter
    /// type" test, usable from `&self`. Returns `true` only on a
    /// *definite* mismatch: a non-null `Value::Instance` whose own
    /// class is known and whose full supertype closure does **not**
    /// contain the parameter's (concrete user class/interface) name.
    /// Anything uncertain — `Any`/generic/`Unit`/`Function*`/builtin
    /// or collection param types, non-instance or unknown-class args,
    /// `null`, nullable params — returns `false` (not a mismatch), so
    /// valid subtype / interface / generic calls are never rejected.
    pub(crate) fn arg_definitely_not_param_type(
        &self,
        param_ty: &klio_ir::TypeRef,
        arg: &klio_runtime::Value,
    ) -> bool {
        let pn = param_ty.name.as_str();
        if matches!(pn, "Any" | "Unit") || param_ty.nullable {
            return false;
        }
        // Generic single/double uppercase type parameter, or a
        // function type — never a definite mismatch here.
        if pn.starts_with("Function")
            || (pn.len() <= 2 && pn.chars().all(|c| c.is_ascii_uppercase()))
        {
            return false;
        }
        // Only adjudicate when the parameter names a known user
        // class/interface; builtins/primitives/collections are scored
        // elsewhere and must not be rejected here.
        if self.classes.borrow().get(pn).is_none() {
            return false;
        }
        let klio_runtime::Value::Instance(inst) = arg else {
            // Non-instance values (primitives, lambdas, collections,
            // null, …) are not adjudicated conservatively.
            return false;
        };
        let start = inst.borrow().class.name.clone();
        // The arg's own class must be known so its supertype closure
        // is complete; otherwise we cannot be definite.
        if self.classes.borrow().get(&start).is_none() {
            return false;
        }
        let mut queue: std::collections::VecDeque<String> =
            std::collections::VecDeque::new();
        let mut seen: std::collections::HashSet<String> =
            std::collections::HashSet::new();
        queue.push_back(start);
        while let Some(cur) = queue.pop_front() {
            if cur == pn {
                return false; // arg IS-A param type — compatible
            }
            if !seen.insert(cur.clone()) {
                continue;
            }
            if let Some(def) = self.classes.borrow().get(&cur).cloned() {
                for sup in &def.supertype_names {
                    queue.push_back(sup.clone());
                }
            }
        }
        // Closure exhausted without reaching the parameter type.
        true
    }

    pub(crate) fn pick_method_overload(
        &self,
        candidates: &[klio_ir::Func],
        args: &[klio_runtime::Value],
    ) -> Option<klio_ir::Func> {
        if candidates.is_empty() {
            return None;
        }
        if candidates.len() == 1 {
            // Even a lone same-named member must be *applicable*: a
            // definite argument-type mismatch (e.g. the deprecated
            // `CoroutineDispatcher.plus(CoroutineDispatcher)` reached
            // for a `CoroutineName` argument) must fall through so the
            // hierarchy walk continues to the real target
            // (`CoroutineContext.plus(CoroutineContext)`), instead of
            // dispatching a non-applicable narrowing overload.
            let f = &candidates[0];
            let params_skip = if f
                .params
                .first()
                .map(|p| p.name == "this")
                .unwrap_or(false)
            {
                1
            } else {
                0
            };
            let effective = &f.params[params_skip..];
            for (p, a) in effective.iter().zip(args.iter()) {
                if self.arg_definitely_not_param_type(&p.ty, a) {
                    return None;
                }
            }
            return Some(candidates[0].clone());
        }
        let mut best: Option<(usize, i32)> = None;
        for (i, f) in candidates.iter().enumerate() {
            // Method params include the implicit `this` slot first;
            // skip it when scoring against the caller's args.
            let params_skip = if f.params.first().map(|p| p.name == "this").unwrap_or(false) { 1 } else { 0 };
            let effective: &[klio_ir::Param] = &f.params[params_skip..];
            // Accept an exact-arity match, or a call that supplies
            // fewer args when every unsupplied trailing parameter has
            // a default (`fun make(s, adj: Long = 0)` called as
            // `make(s)`). func_defaults is indexed by lowered-param
            // position, so probe with the implicit-`this` offset.
            if args.len() > effective.len() {
                continue;
            }
            if args.len() < effective.len() {
                let defaults = self.prog.func_defaults.get(&f.id);
                let all_defaulted = (args.len()..effective.len()).all(|k| {
                    defaults
                        .and_then(|d| d.get(params_skip + k))
                        .map(|slot| slot.is_some())
                        .unwrap_or(false)
                });
                if !all_defaulted {
                    continue;
                }
            }
            let mut total: i32 = 0;
            let mut ok = true;
            for (p, a) in effective.iter().zip(args.iter()) {
                match self.overload_score_arg(&p.ty, a) {
                    Some(s) => total += s,
                    None => {
                        ok = false;
                        break;
                    }
                }
            }
            // Prefer an exact-arity overload over one relying on
            // defaulted trailing params, all else equal.
            if ok && args.len() == effective.len() {
                total += 5;
            }
            if ok && best.map(|(_, s)| total > s).unwrap_or(true) {
                best = Some((i, total));
            }
        }
        best.map(|(i, _)| candidates[i].clone())
    }

    pub(crate) fn pick_overload(
        &self,
        module: &klio_ir::Module,
        func: klio_ir::FuncId,
        args: &[klio_runtime::Value],
    ) -> Option<klio_ir::FuncId> {
        let name = module.funcs.get(func.0 as usize)?.name.clone();
        let candidates = module.funcs_by_simple_name(&name);
        if candidates.len() < 2 {
            return None;
        }
        let candidates: Vec<klio_ir::FuncId> = candidates.to_vec();
        let seed = self.overload_score(module, func, args).map(|s| (func, s));
        let mut best: Option<(klio_ir::FuncId, i32)> = seed;
        let seed_func = func;
        let _ = name;
        for cand in &candidates {
            if *cand == seed_func {
                continue;
            }
            if let Some(total) = self.overload_score(module, *cand, args) {
                if best.map(|(_, s)| total > s).unwrap_or(true) {
                    best = Some((*cand, total));
                }
            }
        }
        best.map(|(id, _)| id)
    }

    /// Score a single candidate's applicability for `args`. `None`
    /// means the candidate is inapplicable (arity / param-type
    /// mismatch); a higher score means a better match. Exact arity
    /// scores baseline 0, a defaulted-trailing-param fill scores -1
    /// so a dedicated N-arg overload still outranks a defaulted one.
    pub(crate) fn overload_score(
        &self,
        module: &klio_ir::Module,
        cand: klio_ir::FuncId,
        args: &[klio_runtime::Value],
    ) -> Option<i32> {
        let f = module.funcs.get(cand.0 as usize)?;
        let last_vararg = f.params.last().map(|p| p.is_vararg).unwrap_or(false);
        if f.params.len() < args.len() && !last_vararg {
            return None;
        }
        if f.params.len() > args.len() {
            let defaults = self.prog.func_defaults.get(&cand);
            let all_defaulted = (args.len()..f.params.len()).all(|i| {
                defaults
                    .and_then(|d| d.get(i))
                    .map(|slot| slot.is_some())
                    .unwrap_or(false)
            });
            if !all_defaulted {
                return None;
            }
        }
        let mut total: i32 = if f.params.len() == args.len() { 0 } else { -1 };
        for (p, a) in f.params.iter().zip(args.iter()) {
            match self.overload_score_arg(&p.ty, a) {
                Some(s) => total += s,
                None => return None,
            }
        }
        Some(total)
    }

    /// Look up an intrinsic by FQN. Probes the pack-supplied
    /// `installed_bindings` overlay first so a loaded pack's binding
    /// shadows the stdlib's default implementation.
    pub(crate) fn lookup_intrinsic(&self, fqn: &str) -> Option<klio_runtime::StdlibFn> {
        self.prog.installed_bindings
            .resolve(fqn)
            .or_else(|| klio_stdlib::implementation(fqn))
    }

    pub(crate) fn dispatch_intrinsic(
        &mut self,
        func: klio_runtime::StdlibFn,
        args: &[klio_runtime::Value],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        // Build an IntrinsicHost that can recursively invoke
        // lambdas (Value::IrClosure) via the Vm's closure table +
        // module. This lets HOF stdlib bindings (`map`, `forEach`,
        // scope fns) call back into IR-lowered lambda bodies
        // natively, without bouncing through klio-interp.
        let mut intrinsic_host = VmIntrinsicHost {
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
        };
        let mut ctx = klio_runtime::CallCtx {
            args,
            out: &mut *self.out,
            host: &mut intrinsic_host,
        };
        func(&mut ctx).map_err(|e| match e {
            // Preserve the thrown Value so the IR evaluator's
            // try/catch can match the handler against the exception
            // class. Stringifying here would break `try { … } catch`.
            klio_runtime::RuntimeError::Thrown(v) => klio_ir::eval::EvalError::Throw(v),
            klio_runtime::RuntimeError::Return(v) => {
                klio_ir::eval::EvalError::NonLocalReturn(v)
            }
            // A suspending primitive (`delay` / `yield`) asked to
            // park. Seed a fresh SuspendState; each enclosing
            // `eval` frame snapshots itself as it unwinds, and the
            // coroutine driver parks the result under a token.
            klio_runtime::RuntimeError::Suspend(wake) => {
                klio_ir::eval::EvalError::Suspended(Box::new(
                    klio_ir::eval::SuspendState {
                        token: 0,
                        frames: Vec::new(),
                        wake_in_millis: wake,
                        pending_resume_reg: None,
                    },
                ))
            }
            other => klio_ir::eval::EvalError::Type(format!("{other}")),
        })
    }

    /// Resolve the user extension/top-level fn an unqualified
    /// `recv.name(args)` would dispatch to — identical candidate
    /// selection to the `call_member` extension-fn fallback (arity
    /// filter, unique-exact-arity, then receiver/arg type scoring).
    /// Shared so the named-argument path picks the *same* overload
    /// the positional path does.
    pub(crate) fn resolve_ext_overload(
        &self,
        name: &str,
        receiver: &klio_runtime::Value,
        args: &[klio_runtime::Value],
        arg_names: &[Option<String>],
    ) -> Option<klio_ir::FuncId> {
        // params[0] is the synthesized extension/dispatch receiver
        // (`this`); user args map onto params[1..].
        let want = args.len() + 1;
        let candidates: Vec<(klio_ir::FuncId, klio_ir::Func)> = self
            .module
            .funcs_by_simple_name(name)
            .iter()
            .filter_map(|fid| {
                self.module.funcs.get(fid.0 as usize).cloned().map(|f| (*fid, f))
            })
            // Only genuine extension fns (synthetic `this` first param)
            // are candidates for member-call resolution; a plain
            // top-level fn sharing the name is not an extension.
            .filter(|(_fid, f)| f.params.first().map_or(false, |p| p.name == "this"))
            .collect();
        // Receiver-type filter: drop candidates whose declared
        // receiver type can't accept the actual receiver. If every
        // candidate is filtered AND a type-prefixed intrinsic for
        // this receiver exists, return None so the caller falls
        // through to the intrinsic probe path. Otherwise (no class-
        // specific intrinsic — typical of an implicit / Unit
        // receiver dispatch) keep the original set so existing
        // resolution shapes are unchanged.
        let any_compat = candidates
            .iter()
            .any(|(_, f)| receiver_compatible_with_param(receiver, &f.params[0].ty));
        let candidates: Vec<(klio_ir::FuncId, klio_ir::Func)> = if any_compat {
            candidates
                .into_iter()
                .filter(|(_, f)| {
                    receiver_compatible_with_param(receiver, &f.params[0].ty)
                })
                .collect()
        } else {
            let type_fqn = receiver.type_fqn();
            let intrinsic_probe = format!("{type_fqn}.{name}");
            if self.lookup_intrinsic(&intrinsic_probe).is_some() {
                return None;
            }
            candidates
        };
        if candidates.len() <= 1 {
            return candidates.into_iter().next().map(|(fid, _)| fid);
        }
        let has_names = arg_names.iter().any(|n| n.is_some());
        // Default-/named-arg-aware applicability + scoring. A
        // candidate is viable only if every user parameter
        // (params[1..]) that is left unbound after slotting the
        // positional and named args has a default. Without this a
        // named-only call like `recv.f(h = x)` mis-bound to an
        // overload missing a required parameter (and slotted args by
        // raw position, yielding `Unit` fills) — e.g. picking
        // `f(b: Boolean, h)` over the applicable
        // `f(invokeImmediately: Boolean = true, h)`.
        let mut best: Option<(klio_ir::FuncId, i64)> = None;
        for (fid, f) in &candidates {
            let np = f.params.len();
            if np < 1 {
                continue;
            }
            let upar = np - 1; // user-facing params (excl. `this`)
            let mut filled = vec![false; upar];
            let mut score: i64 =
                self.overload_score_arg(&f.params[0].ty, receiver)
                    .unwrap_or(-2) as i64;
            let mut viable = true;
            // Named args bind by parameter name.
            for (i, an) in arg_names.iter().enumerate() {
                if let Some(nm) = an {
                    match f.params[1..]
                        .iter()
                        .position(|p| &p.name == nm)
                    {
                        Some(slot) => {
                            filled[slot] = true;
                            if let Some(a) = args.get(i) {
                                score += self
                                    .overload_score_arg(
                                        &f.params[slot + 1].ty,
                                        a,
                                    )
                                    .unwrap_or(-2)
                                    as i64;
                            }
                        }
                        None => {
                            viable = false; // unknown named arg
                            break;
                        }
                    }
                }
            }
            if !viable {
                continue;
            }
            // Positional args fill the next unfilled user slot.
            let mut next = 0usize;
            for (i, an) in arg_names.iter().enumerate() {
                if an.is_some() {
                    continue;
                }
                while next < upar && filled[next] {
                    next += 1;
                }
                if next >= upar {
                    viable = false; // too many positional args
                    break;
                }
                filled[next] = true;
                if let Some(a) = args.get(i) {
                    score += self
                        .overload_score_arg(
                            &f.params[next + 1].ty,
                            a,
                        )
                        .unwrap_or(-2) as i64;
                }
                next += 1;
            }
            if !viable {
                continue;
            }
            // Every unfilled user param must carry a default.
            let defaults = self.prog.func_defaults.get(fid);
            for (slot, done) in filled.iter().enumerate() {
                if !*done {
                    let has_default = defaults
                        .and_then(|d| d.get(slot + 1))
                        .map(|s| s.is_some())
                        .unwrap_or(false);
                    if !has_default {
                        viable = false;
                        break;
                    }
                }
            }
            if !viable {
                continue;
            }
            // Prefer exact arity and (slightly) name-supplied calls.
            if np == want {
                score += 5;
            }
            if has_names {
                score += 1;
            }
            if best.as_ref().map(|(_, s)| score > *s).unwrap_or(true) {
                best = Some((*fid, score));
            }
        }
        if let Some((fid, _)) = best {
            return Some(fid);
        }
        // No viable candidate under the strict rule — fall back to
        // the old arity-permissive pick so non-named / legacy call
        // shapes keep resolving exactly as before.
        let arity: Vec<(klio_ir::FuncId, klio_ir::Func)> = candidates
            .into_iter()
            .filter(|(_, f)| f.params.len() >= want)
            .collect();
        if arity.len() == 1 {
            return Some(arity[0].0);
        }
        let mut best: Option<(klio_ir::FuncId, i32)> = None;
        for (fid, f) in arity {
            let mut score = self
                .overload_score_arg(&f.params[0].ty, receiver)
                .unwrap_or(-1);
            for (i, a) in args.iter().enumerate() {
                if let Some(p) = f.params.get(i + 1) {
                    score += self
                        .overload_score_arg(&p.ty, a)
                        .unwrap_or(-1);
                }
            }
            if f.params.len() == want {
                score += 5;
            }
            if best.as_ref().map(|(_, s)| score > *s).unwrap_or(true) {
                best = Some((fid, score));
            }
        }
        best.map(|(fid, _)| fid)
    }
}

impl<'a> VmHost<'a> {
    /// Run the chain of secondary-constructor bodies for `class_name`
    /// with arity matching `args.len()` on an existing `leaf`
    /// instance. Resolves `: this(...)` delegation by recursing on
    /// the same class with the delegated args; `: super(...)` walks
    /// up via the leaf's class parent. Bodies run with the same
    /// `leaf` so fields accumulate across the chain.
    pub(crate) fn run_super_ctor_chain(
        &mut self,
        leaf: &klio_runtime::Value,
        class_name: &str,
        args: &[klio_runtime::Value],
    ) -> Result<(), klio_ir::eval::EvalError> {
        let entries = self
            .prog
            .secondary_ctors
            .get(class_name)
            .cloned()
            .unwrap_or_default();
        let Some(entry) = entries.iter().find(|e| e.param_count == args.len()) else {
            return Ok(());
        };
        let module = Arc::clone(&self.module);
        let mut next_args: Vec<klio_runtime::Value> =
            Vec::with_capacity(entry.delegation_arg_thunks.len());
        for fid in &entry.delegation_arg_thunks {
            let func = module
                .funcs
                .get(fid.0 as usize)
                .cloned()
                .ok_or_else(|| {
                    klio_ir::eval::EvalError::Type(format!(
                        "secondary ctor arg FuncId {} out of range",
                        fid.0
                    ))
                })?;
            let v = klio_ir::eval::eval_with(&module, &func, args.to_vec(), self)?;
            next_args.push(v);
        }
        if entry.is_this {
            self.run_super_ctor_chain(leaf, class_name, &next_args)?;
        } else if entry.is_super {
            let parent_name = if let klio_runtime::Value::Instance(inst) = leaf {
                inst.borrow()
                    .class
                    .parent
                    .borrow()
                    .clone()
                    .map(|p| p.name.clone())
            } else {
                None
            };
            if let Some(p) = parent_name {
                self.run_super_ctor_chain(leaf, &p, &next_args)?;
            }
        }
        if let Some(body_fid) = entry.body {
            if let Some(body_func) = module.funcs.get(body_fid.0 as usize).cloned() {
                let mut all: Vec<klio_runtime::Value> =
                    Vec::with_capacity(1 + args.len());
                all.push(leaf.clone());
                all.extend_from_slice(args);
                klio_ir::eval::eval_with(&module, &body_func, all, self)?;
            }
        }
        Ok(())
    }

    /// Drain a user-Instance iterable into a Value::List by invoking
    /// its iterator() / hasNext() / next() members. Used by the
    /// Iterable-extension fallback in `call_member`. Stops after
    /// 1,000,000 items to avoid runaway iterators.
    pub(crate) fn drain_iterable_to_list(
        &mut self,
        receiver: &klio_runtime::Value,
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        let iter = <Self as klio_ir::eval::Host>::call_member(self, receiver, "iterator", &[])?;
        let mut items: Vec<klio_runtime::Value> = Vec::new();
        loop {
            let has = <Self as klio_ir::eval::Host>::call_member(self, &iter, "hasNext", &[])?;
            if !matches!(has, klio_runtime::Value::Bool(true)) {
                break;
            }
            let v = <Self as klio_ir::eval::Host>::call_member(self, &iter, "next", &[])?;
            items.push(v);
            if items.len() > 1_000_000 {
                return Err(klio_ir::eval::EvalError::Type(
                    "Iterable.<extension>: iterator produced over 1,000,000 items"
                        .into(),
                ));
            }
        }
        Ok(klio_runtime::Value::List {
            items: klio_runtime::ObjRef::new(items),
            mutable: false,
            enum_class: None, backing: None,
        })
    }

    /// Run the class's `init { … }` blocks whose source position
    /// equals `before_prop_idx` (i.e. those declared between
    /// `body_properties[before_prop_idx-1]` and
    /// `body_properties[before_prop_idx]`, or trailing if
    /// `before_prop_idx == body_properties.len()`). Each block takes
    /// `this` plus the class's primary-ctor args.
    pub(crate) fn run_init_blocks_at(
        &mut self,
        cls: &Arc<klio_runtime::ClassDef>,
        before_prop_idx: usize,
        inst_value: &klio_runtime::Value,
        chain_args_by_class: &std::collections::HashMap<String, Vec<klio_runtime::Value>>,
        fallback_args: &[klio_runtime::Value],
    ) -> Result<(), klio_ir::eval::EvalError> {
        let Some(fids) = self.prog.init_blocks.get(&cls.name).cloned() else {
            return Ok(());
        };
        let cls_args: Vec<klio_runtime::Value> = chain_args_by_class
            .get(&cls.name)
            .cloned()
            .unwrap_or_else(|| fallback_args.to_vec());
        for (i, fid) in fids.iter().enumerate() {
            let pos = cls
                .init_block_property_positions
                .get(i)
                .copied()
                .unwrap_or(usize::MAX);
            // `usize::MAX` means no recorded position (runtime-synth
            // class that bypassed the build pass) — flush such blocks
            // at the trailing position so legacy classes keep their
            // prior all-end ordering.
            let effective = if pos == usize::MAX {
                cls.body_properties.len()
            } else {
                pos
            };
            if effective != before_prop_idx {
                continue;
            }
            if let Some(f) = self.module.funcs.get(fid.0 as usize).cloned() {
                let module = Arc::clone(&self.module);
                let mut all: Vec<klio_runtime::Value> =
                    Vec::with_capacity(1 + cls_args.len());
                all.push(inst_value.clone());
                all.extend(cls_args.iter().cloned());
                klio_ir::eval::eval_with(&module, &f, all, self)?;
            }
        }
        Ok(())
    }
}
