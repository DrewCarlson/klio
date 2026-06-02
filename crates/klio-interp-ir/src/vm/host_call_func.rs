use crate::{VmHost, primitive_param_accepts, is_function_type, value_is_callable, pack_vararg_args, ext_decl_recv_is_user_class, value_is_builtin, ClosureInfo, Arc};

impl VmHost<'_> {
    pub(crate) fn call_func(
        &mut self,
        module: &klio_ir::Module,
        func: klio_ir::FuncId,
        args: Vec<klio_runtime::Value>,
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        let f = module
            .funcs
            .get(func.0 as usize)
            .cloned()
            .ok_or_else(|| {
                klio_ir::eval::EvalError::Type(format!("unknown FuncId {}", func.0))
            })?;
        // Pack-installed binding fast path: a top-level function whose
        // package-qualified FQN matches a registered binding shadows
        // the shim body shipped in source.
        if let Some(intrinsic) = self.prog.installed_bindings.resolve(&f.fqn) {
            let v = self.dispatch_intrinsic(intrinsic, &args)?;
            return Ok(v);
        }
        // Mis-bound type-specialized overload fallback. A bare call
        // (`maxOf(a, b)`) is lowered to a single FuncId with no
        // argument-type information, so it can bind to the wrong
        // type-specialized overload — e.g. `maxOf(Double, Double)`
        // binding to the `maxOf(UInt, UInt)` body, whose `if (a >= b)`
        // runs an IEEE compare on the Double args and drops NaN. When
        // the resolved body's concrete primitive parameter types
        // definitely mismatch the runtime arguments and a same-FQN
        // intrinsic exists, dispatch the intrinsic (which inspects the
        // real argument types). General across any such mis-binding; a
        // body whose params match, or that has no intrinsic, runs
        // unchanged.
        if !f.blocks.is_empty() && !args.is_empty() {
            let user_offset = usize::from(
                f.params.first().is_some_and(|p| p.name == "this"),
            );
            let mismatch = args.iter().enumerate().any(|(i, v)| {
                f.params
                    .get(user_offset + i)
                    .is_some_and(|p| !p.is_vararg && !primitive_param_accepts(&p.ty.name, v))
            });
            if mismatch
                && let Some(intrinsic) = self.lookup_intrinsic(&f.fqn) {
                    return self.dispatch_intrinsic(intrinsic, &args);
                }
        }
        // Bodyless `expect` decl: redirect to a same-name same-arity
        // sibling with a body. Source files are lowered in order, so
        // an actual declared in a later-loaded file isn't available
        // when the expect's caller is lowered; the caller's
        // `Inst::Call` was baked to the expect's FuncId.
        if f.blocks.is_empty() {
            let want = args.len();
            let cands: Vec<klio_ir::FuncId> = module
                .funcs_by_simple_name(&f.name)
                .to_vec();
            for cand in &cands {
                if *cand == func {
                    continue;
                }
                if let Some(g) = module.funcs.get(cand.0 as usize) {
                    if g.blocks.is_empty() {
                        continue;
                    }
                    let g_params = g.params.len();
                    let g_user_params = if g
                        .params
                        .first()
                        .is_some_and(|p| p.name == "this")
                    {
                        g_params - 1
                    } else {
                        g_params
                    };
                    if g_user_params != want
                        && !g.params.last().is_some_and(|p| p.is_vararg)
                    {
                        continue;
                    }
                    let new_args = args.clone();
                    return self.call_func(module, *cand, new_args);
                }
            }
            // No same-name body sibling — fall through to the
            // intrinsic table. Try the declared FQN first; if the
            // expect's fqn carries no package qualifier (the lowering
            // pass left it bare), probe the common stdlib packages by
            // simple name as a fallback so a bodyless
            // `expect fun println(message: Any?)` reaches klio's
            // `kotlin.io.println` intrinsic.
            if let Some(intrinsic) = self.lookup_intrinsic(&f.fqn) {
                return self.dispatch_intrinsic(intrinsic, &args);
            }
            let simple = f.name.as_str();
            let probes = [
                format!("kotlin.{simple}"),
                format!("kotlin.io.{simple}"),
                format!("kotlin.math.{simple}"),
                format!("kotlin.text.{simple}"),
                format!("kotlin.collections.{simple}"),
                format!("kotlin.ranges.{simple}"),
                format!("kotlin.comparisons.{simple}"),
                format!("kotlin.concurrent.{simple}"),
                format!("kotlin.coroutines.{simple}"),
                format!("kotlin.coroutines.intrinsics.{simple}"),
                format!("kotlin.internal.{simple}"),
            ];
            for p in &probes {
                if let Some(intrinsic) = self.lookup_intrinsic(p) {
                    return self.dispatch_intrinsic(intrinsic, &args);
                }
            }
        }
        // Pad missing positional args with each param's default
        // value (from the registered default-init thunks).
        let mut args = args;
        // Kotlin trailing-lambda rule: when fewer args are supplied
        // than params and the last param is a function type while a
        // default-valued param sits before it, the final supplied
        // callable is the trailing lambda and binds the *last*
        // param; the gap params fall back to their defaults. Without
        // this the lambda would slot into the first (defaulted)
        // param and the real last param would be left unbound.
        if args.len() < f.params.len() && !args.is_empty() {
            let last_is_fn = f
                .params
                .last()
                .is_some_and(|p| is_function_type(&p.ty));
            let trailing_is_callable =
                args.last().is_some_and(value_is_callable);
            if last_is_fn && trailing_is_callable {
                let lead = args.len() - 1;
                let last_param = f.params.len() - 1;
                if lead < last_param
                    && let Some(defaults) = self.prog.func_defaults.get(&func).cloned() {
                        let trailing = args.pop().unwrap();
                        for idx in lead..last_param {
                            if let Some(Some(default_fid)) = defaults.get(idx) {
                                let dfid = *default_fid;
                                let dfunc = module
                                    .funcs
                                    .get(dfid.0 as usize)
                                    .cloned()
                                    .ok_or_else(|| {
                                        klio_ir::eval::EvalError::Type(format!(
                                            "default-arg FuncId {} out of range",
                                            dfid.0
                                        ))
                                    })?;
                                let v = klio_ir::eval::eval_with(
                                    module,
                                    &dfunc,
                                    args.clone(),
                                    self,
                                )?;
                                args.push(v);
                            } else {
                                args.push(klio_runtime::Value::Null);
                            }
                        }
                        args.push(trailing);
                    }
            }
        }
        if args.len() < f.params.len()
            && let Some(defaults) = self.prog.func_defaults.get(&func).cloned() {
                for idx in args.len()..f.params.len() {
                    if let Some(Some(default_fid)) = defaults.get(idx) {
                        let dfid = *default_fid;
                        let dfunc = module
                            .funcs
                            .get(dfid.0 as usize)
                            .cloned()
                            .ok_or_else(|| {
                                klio_ir::eval::EvalError::Type(format!(
                                    "default-arg FuncId {} out of range",
                                    dfid.0
                                ))
                            })?;
                        // The thunk binds the parameters preceding
                        // this one, so a default like `endIndex =
                        // s.length` can read earlier args.
                        //
                        // A thunk lowered inside an extension fn body
                        // that references the receiver records `this`
                        // as a capture, not a param — seed capture[0]
                        // with the receiver so a bare member read like
                        // `size` resolves through it.
                        let captures: Vec<klio_runtime::Value> = if args.is_empty() {
                            Vec::new()
                        } else {
                            vec![args[0].clone()]
                        };
                        let v = klio_ir::eval::eval_with_captures(
                            module, &dfunc, args.clone(), captures, self,
                        )?;
                        args.push(v);
                    } else {
                        args.push(klio_runtime::Value::Null);
                    }
                }
            }
        let args = pack_vararg_args(&f, args);
        klio_ir::eval::eval_with(module, &f, args, self)
    }

    pub(crate) fn call_func_named(
        &mut self,
        module: &klio_ir::Module,
        func: klio_ir::FuncId,
        args: Vec<klio_runtime::Value>,
        arg_names: &[Option<String>],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        // Reorder named args against the target function's
        // declared parameter list. Positional args fill the next
        // free slot; named args slot by name.
        if arg_names.iter().any(std::option::Option::is_some)
            && let Some(f) = module.funcs.get(func.0 as usize) {
                let params = &f.params;
                let mut slots: Vec<Option<klio_runtime::Value>> = vec![None; params.len()];
                // Bind named arguments first so a following positional
                // argument fills the next slot that is *not* already
                // bound by name. Kotlin allows a positional argument
                // after a named one (`f(named = x, pos1, pos2)`) and
                // assigns the positionals to the remaining parameters
                // in declaration order — a single rolling index would
                // instead overwrite the named slot and shift every
                // later argument (dropping the last one).
                for (i, a) in args.iter().enumerate() {
                    if let Some(Some(arg_name)) = arg_names.get(i)
                        && let Some(pos) =
                            params.iter().position(|p| &p.name == arg_name)
                        {
                            slots[pos] = Some(a.clone());
                        }
                }
                // Vararg-aware positional walk: positional args that
                // land on the vararg slot (and every subsequent
                // positional before a named slot shows up) accumulate
                // into a single Array in that slot. A named arg
                // already-bound elsewhere does not affect the
                // accumulation.
                let vararg_pos: Option<usize> =
                    params.iter().position(|p| p.is_vararg);
                let mut positional_idx = 0usize;
                let mut vararg_acc: Vec<klio_runtime::Value> = Vec::new();
                let mut hit_vararg = false;
                for (i, a) in args.iter().enumerate() {
                    if matches!(arg_names.get(i), Some(Some(_))) {
                        continue;
                    }
                    while positional_idx < params.len()
                        && slots[positional_idx].is_some()
                    {
                        positional_idx += 1;
                    }
                    if Some(positional_idx) == vararg_pos {
                        if matches!(a, klio_runtime::Value::Array { .. })
                            && vararg_acc.is_empty()
                        {
                            // Spread case: a single Array argument at
                            // the vararg position is passed through
                            // untouched the same way pack_vararg_args
                            // handles `f(*arr)`.
                            slots[positional_idx] = Some(a.clone());
                            positional_idx += 1;
                            continue;
                        }
                        vararg_acc.push(a.clone());
                        hit_vararg = true;
                        continue;
                    }
                    if positional_idx < params.len() {
                        slots[positional_idx] = Some(a.clone());
                    }
                    positional_idx += 1;
                }
                if let Some(vp) = vararg_pos {
                    if hit_vararg {
                        slots[vp] = Some(klio_runtime::Value::Array {
                            items: klio_runtime::ObjRef::new(vararg_acc),
                            prim: None,
                        });
                    } else if slots[vp].is_none() {
                        // No positional landed on the vararg slot —
                        // bind an empty array so the callee sees a
                        // zero-length vararg rather than padding-Null.
                        slots[vp] = Some(klio_runtime::Value::Array {
                            items: klio_runtime::ObjRef::new(Vec::new()),
                            prim: None,
                        });
                    }
                }
                // Fill omitted slots from the function's default-arg
                // thunks (left-to-right, so a default may read an
                // earlier param). A named call that skips a
                // *non-trailing* defaulted param
                // (`DateTimePeriod(months = 1, days = 2)` skipping
                // `years`) must evaluate that default, not pass Null.
                let n_params = params.len();
                let defaults = self.prog.func_defaults.get(&func).cloned();
                let mut reordered: Vec<klio_runtime::Value> =
                    Vec::with_capacity(n_params);
                let mut truncated = false;
                for (i, slot) in slots.into_iter().enumerate() {
                    if let Some(v) = slot {
                        reordered.push(v);
                        continue;
                    }
                    let dfid = defaults
                        .as_ref()
                        .and_then(|d| d.get(i).copied().flatten());
                    if let Some(dfid) = dfid {
                        let dfunc = module
                            .funcs
                            .get(dfid.0 as usize)
                            .cloned()
                            .ok_or_else(|| {
                                klio_ir::eval::EvalError::Type(format!(
                                    "default-arg FuncId {} out of range",
                                    dfid.0
                                ))
                            })?;
                        let v = klio_ir::eval::eval_with(
                            module,
                            &dfunc,
                            reordered.clone(),
                            self,
                        )?;
                        reordered.push(v);
                    } else {
                        // No value and no default: a trailing
                        // omitted param. Hand the prefix to
                        // call_func, whose own default / vararg /
                        // trailing-lambda padding finishes the job.
                        truncated = true;
                        break;
                    }
                }
                if !truncated {
                    while matches!(
                        reordered.last(),
                        Some(klio_runtime::Value::Null)
                    ) {
                        reordered.pop();
                    }
                }
                return self.call_func(module, func, reordered);
            }
        self.call_func(module, func, args)
    }

    pub(crate) fn call_func_typed(
        &mut self,
        module: &klio_ir::Module,
        func: klio_ir::FuncId,
        args: Vec<klio_runtime::Value>,
        arg_names: &[Option<String>],
        type_args: &[String],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        // Overload resolution: when the target function shares its
        // name with siblings, the IR call site bakes in the first
        // FuncId at lower time — pick the best match here using the
        // runtime arg types.
        let func = self.pick_overload(module, func, &args).unwrap_or(func);
        // Incompatible-receiver guard (sound, narrow): a bare call
        // baked to a top-level extension (`fun R.f`, param0
        // == "this") whose declared receiver `R` is a *user / pack
        // class* — never a builtin and never an interface/Any a
        // builtin could satisfy, with an actual receiver that is a
        // builtin value (String/StringBuilder/Int/Array/…), cannot be
        // correct: a builtin value is never an instance of a user
        // class. Re-dispatch as a member call so the builtin member
        // wins. Instance / Class receivers never trip this, so
        // interface- and subtype-receiver extensions are unaffected.
        if let Some(f) = module.funcs.get(func.0 as usize)
            && f.params.first().is_some_and(|p| p.name == "this")
                && !args.is_empty()
                && ext_decl_recv_is_user_class(&f.params[0].ty.name)
                && value_is_builtin(&args[0])
            {
                let fname = f.name.clone();
                let recv = args[0].clone();
                let rest = args[1..].to_vec();
                return self.call_member(&recv, &fname, &rest);
            }
        // Bind each call-site type-arg name to a synth
        // `Value::Class` global for the duration of the call so
        // reified type-param reads (`T::class`) resolve. We
        // snapshot any pre-existing bindings, install the new
        // ones, then restore on exit so concurrent / recursive
        // calls don't see stale T values.
        let names: Vec<String> = self.module.registry
            .func_type_params
            .get(&func)
            .cloned()
            .unwrap_or_default();
        let mut saved: Vec<(String, Option<klio_runtime::Value>)> = Vec::new();
        for (idx, type_name) in names.iter().enumerate() {
            let arg_name = type_args.get(idx).cloned().unwrap_or_default();
            if arg_name.is_empty() {
                continue;
            }
            let cls_value = self.lookup_global(&arg_name);
            saved.push((type_name.clone(), self.globals.borrow().lookup(type_name)));
            if let Some(v) = cls_value {
                self.globals.borrow_mut().define(type_name.clone(), v);
            }
        }
        let result = self.call_func_named(module, func, args, arg_names);
        for (name, prev) in saved.into_iter().rev() {
            match prev {
                Some(v) => self.globals.borrow_mut().define(name, v),
                None => {
                    self.globals.borrow_mut().remove_local(&name);
                }
            }
        }
        result
    }

    pub(crate) fn call_named_overload(
        &mut self,
        module: &klio_ir::Module,
        name: &str,
        args: &[klio_runtime::Value],
        arg_names: &[Option<String>],
    ) -> Result<Option<klio_runtime::Value>, klio_ir::eval::EvalError> {
        // Only intercept genuine overload sets: a single top-level
        // function keeps the plain global-value path (which carries
        // default-arg + vararg packing the IrClosure branch handles).
        let mut first: Option<klio_ir::FuncId> = None;
        let mut count = 0usize;
        for (n, id) in &module.func_index {
            if n == name {
                count += 1;
                if first.is_none() {
                    first = Some(*id);
                }
            }
        }
        if count < 2 {
            return Ok(None);
        }
        let func = first.expect("count >= 2 implies a first candidate");
        let result = self.call_func_typed(
            module,
            func,
            args.to_vec(),
            arg_names,
            &[],
        )?;
        Ok(Some(result))
    }

    pub(crate) fn build_ast_lambda_with_flag_funcid(
        &mut self,
        params: &[String],
        _body: &klio_ast::Block,
        captured_names: &[String],
        captures: Vec<klio_runtime::Value>,
        _absorb_return: bool,
        body_func: Option<klio_ir::FuncId>,
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        let body_func = body_func.ok_or_else(|| {
            klio_ir::eval::EvalError::Unimplemented(
                "Vm: lambda lower did not provide body_func".into(),
            )
        })?;
        let cell = klio_runtime::ObjRef::new(captures.clone());
        let id = self.closures.push(ClosureInfo {
            body_func,
            n_params: params.len(),
            capture_names: captured_names.to_vec(),
            captures: cell,
        });
        Ok(klio_runtime::Value::IrClosure {
            id,
            captures: Arc::new(captures),
        })
    }

    pub(crate) fn read_lambda_capture(
        &mut self,
        lambda: &klio_runtime::Value,
        name: &str,
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        if let klio_runtime::Value::IrClosure { id, .. } = lambda {
            let info = self.closures.get(*id as usize).ok_or_else(|| {
                klio_ir::eval::EvalError::Type(format!("unknown IrClosure id {id}"))
            })?;
            for (idx, cap_name) in info.capture_names.iter().enumerate() {
                if cap_name == name {
                    return Ok(info
                        .captures
                        .borrow()
                        .get(idx)
                        .cloned()
                        .unwrap_or(klio_runtime::Value::Null));
                }
            }
            return Err(klio_ir::eval::EvalError::Unbound(format!(
                "capture `{name}` not found in lambda"
            )));
        }
        Err(klio_ir::eval::EvalError::Type(format!(
            "read_lambda_capture on non-lambda value `{}`",
            lambda.type_fqn()
        )))
    }
}
