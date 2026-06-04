use crate::{
    Arc, AtomicOrdering, VmHost, VmIntrinsicHost, member_is_property, pad_args_with_defaults,
    simple_literal,
};

impl VmHost<'_> {
    // Single callable-value dispatch over the value variants.
    #[allow(clippy::too_many_lines)]
    pub(crate) fn call_value(
        &mut self,
        callee: &klio_runtime::Value,
        args: &[klio_runtime::Value],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        if let klio_runtime::Value::Intrinsic { func, .. } = callee {
            return self.dispatch_intrinsic(*func, args);
        }
        // `instance()` — bound-member-reference invocation
        // (`recv::method`, `String::plus`) wins over `operator fun
        // invoke`. A `$bound_ref$` synth carries `__bound_receiver__`
        // and `__bound_name__`; dispatch through them so an unbound
        // class-method ref consumes its first arg as the receiver.
        if let klio_runtime::Value::Instance(inst) = callee {
            let snap = inst.borrow();
            let recv = snap.get("__bound_receiver__");
            let name_v = snap.get("__bound_name__");
            drop(snap);
            if let (Some(recv), Some(klio_runtime::Value::String(name))) = (recv, name_v) {
                if matches!(&recv, klio_runtime::Value::Class(_)) && !args.is_empty() {
                    let first = args[0].clone();
                    let rest: Vec<klio_runtime::Value> = args[1..].to_vec();
                    if rest.is_empty() && member_is_property(&self.classes, &first, &name) {
                        return self.get_field(&first, &name);
                    }
                    return self.call_member(&first, &name, &rest);
                }
                if args.is_empty() && member_is_property(&self.classes, &recv, &name) {
                    return self.get_field(&recv, &name);
                }
                return self.call_member(&recv, &name, args);
            }
            return self.call_member(callee, "invoke", args);
        }
        // Constructor-like call on a user class value
        // (`val ctor = ::Foo; ctor(1, 2)`). Falls through to a
        // direct ClassDef-based allocation when the class isn't
        // in the IR module's class_index — covers local classes
        // declared inside a fn body and registered via
        // Inst::RegisterClass.
        if let klio_runtime::Value::Class(cls) = callee {
            // SAM conversion: `FunInterface { lambda }` constructs a
            // synthetic instance whose single abstract method
            // dispatches the lambda body. We allocate a thin
            // InstanceData whose `fields` carry the lambda under
            // `__sam_target__`; call_member on this instance routes
            // any method call back through the lambda.
            if cls.is_fun_interface && args.len() == 1 {
                let identity = self
                    .instance_id_counter
                    .fetch_add(1, AtomicOrdering::Relaxed)
                    + 1;
                let inst = klio_runtime::ObjRef::new(klio_runtime::InstanceData {
                    class: Arc::clone(cls),
                    fields: vec![("__sam_target__".to_string(), args[0].clone())],
                    outer: None,
                    identity,
                    native_state: None,
                });
                return Ok(klio_runtime::Value::Instance(inst));
            }
            let class_id = self
                .module
                .class_index
                .iter()
                .find(|(n, _)| *n == cls.name)
                .map(|(_, id)| *id);
            if let Some(class_id) = class_id {
                return self.new_instance(class_id, args);
            }
            // Direct allocation for classes that aren't in the IR
            // module index. The runtime ClassDef carries enough to
            // bind primary-param properties; init blocks + custom
            // getters land when local-class lowering grows them.
            let identity = self
                .instance_id_counter
                .fetch_add(1, AtomicOrdering::Relaxed)
                + 1;
            let mut fields: Vec<(String, klio_runtime::Value)> =
                Vec::with_capacity(cls.primary_params.len());
            for (param, value) in cls.primary_params.iter().zip(args.iter()) {
                if param.property.is_some() {
                    fields.push((param.name.clone(), value.clone()));
                }
            }
            // Body-property defaults for runtime-registered local
            // classes — literal-only inits, since there's no
            // lowered thunk on a non-IR class.
            for p in &cls.body_properties {
                if let Some(init) = &p.init {
                    let v = simple_literal(init).unwrap_or(klio_runtime::Value::Null);
                    fields.push((p.name.clone(), v));
                } else if p.getter.is_none() && p.delegate.is_none() {
                    let v = p
                        .primitive_zero
                        .clone()
                        .unwrap_or(klio_runtime::Value::Null);
                    fields.push((p.name.clone(), v));
                }
            }
            let default_outer = self.class_default_outer.borrow().get(&cls.name).cloned();
            let inst = klio_runtime::ObjRef::new(klio_runtime::InstanceData {
                class: Arc::clone(cls),
                fields,
                outer: default_outer,
                identity,
                native_state: None,
            });
            return Ok(klio_runtime::Value::Instance(inst));
        }
        // `propRef(receiver)` — invoking a Value::PropertyRef as a
        // callable reads the named field from the first arg.
        if let klio_runtime::Value::PropertyRef { name } = callee
            && args.len() == 1
        {
            return self.get_field(&args[0], name);
        }
        // Bound method/property reference: synthetic instance
        // carrying a receiver + method name. Invocation forwards
        // through the captured receiver (or reads the property on
        // the first arg for unbound property refs).
        if let klio_runtime::Value::Instance(inst) = callee {
            let snap = inst.borrow();
            let recv = snap.get("__bound_receiver__");
            let name_v = snap.get("__bound_name__");
            drop(snap);
            if let (Some(recv), Some(klio_runtime::Value::String(name))) = (recv, name_v) {
                if matches!(&recv, klio_runtime::Value::Class(_)) && args.len() == 1 {
                    return self.get_field(&args[0], &name);
                }
                return self.call_member(&recv, &name, args);
            }
        }
        if let klio_runtime::Value::IrClosure { id, captures } = callee {
            // Closure id indexes the closure table.
            #[allow(clippy::cast_possible_truncation)]
            let info = self.closures.get(*id as usize).ok_or_else(|| {
                klio_ir::eval::EvalError::Type(format!("unknown IrClosure id {id}"))
            })?;
            let module = Arc::clone(&self.module);
            let func = module
                .funcs
                .get(info.body_func.0 as usize)
                .cloned()
                .ok_or_else(|| {
                    klio_ir::eval::EvalError::Type(format!(
                        "closure body FuncId {} out of range",
                        info.body_func.0
                    ))
                })?;
            // Pack binding overlay short-circuit for the wrapped
            // top-level fn: e.g. a closure-of `kotlinx.datetime.__kxdt_*`
            // dispatches the Rust binding instead of running the
            // shim placeholder body.
            if let Some(intrinsic) = self.prog.installed_bindings.resolve(&func.fqn) {
                return self.dispatch_intrinsic(intrinsic, args);
            }
            // Value-style invocation of a receiver lambda
            // (`block.invoke(receiver, p)` / `block(receiver, p)` for a
            // `R.(P) -> T`): the lambda's value params are `[p]`, so being
            // called with exactly one *extra* leading arg means arg0 is the
            // extension receiver. Bind it into the closure's `this` capture
            // and re-run on this same (main-evaluator) path — which snapshots
            // frames so a suspension inside the body (`delay`) parks
            // correctly, unlike the intrinsic-host invoke. The body resolves
            // its receiver through the `this` capture slot
            // (`func.capture_order`), so overriding the closure value's
            // captures (not the side-table `info.captures`, which this path
            // ignores) is what reaches the evaluator. Valid Kotlin never
            // over-supplies a non-receiver lambda, so the `+1` arity is
            // unambiguous; vararg targets (legitimately variadic) are
            // excluded; and a `this` capture must exist (a genuine receiver
            // lambda) so a 2-param lambda invoked with 3 args isn't misread.
            let last_vararg = func.params.last().is_some_and(|p| p.is_vararg);
            let this_cap_idx = info.capture_names.iter().position(|n| n == "this");
            if !last_vararg
                && args.len() == info.n_params + 1
                && let Some(this_idx) = this_cap_idx
            {
                let mut new_caps: Vec<klio_runtime::Value> = (**captures).clone();
                if this_idx >= new_caps.len() {
                    new_caps.resize(this_idx + 1, klio_runtime::Value::Null);
                }
                new_caps[this_idx] = args[0].clone();
                let bound = klio_runtime::Value::IrClosure {
                    id: *id,
                    captures: Arc::new(new_caps),
                };
                let rest: Vec<klio_runtime::Value> = args[1..].to_vec();
                let pushed = matches!(args[0], klio_runtime::Value::Instance(_));
                if pushed {
                    self.push_access_enclosing(&args[0].clone());
                }
                let r = self.call_value(&bound, &rest);
                if pushed {
                    self.pop_access_enclosing();
                }
                return r;
            }
            // Fill missing positional args from the target's
            // registered default-arg thunks (an implicit-`it` lambda
            // invoked with zero args still gets its slot as Null).
            // Pack trailing vararg args into an Array when the
            // target's last param is marked vararg.
            let defaults = self.prog.func_defaults.get(&info.body_func).cloned();
            let mut call_args =
                pad_args_with_defaults(&module, info.n_params, args, defaults.as_ref(), self)?;
            if let Some(last) = func.params.last() {
                if last.is_vararg && args.len() > info.n_params {
                    let mut packed: Vec<klio_runtime::Value> = Vec::new();
                    let fixed = info.n_params.saturating_sub(1);
                    packed.extend(args[fixed..].iter().cloned());
                    call_args[info.n_params - 1] = klio_runtime::Value::Array {
                        items: klio_runtime::ObjRef::new(packed),
                        prim: None,
                    };
                } else if last.is_vararg
                    && !matches!(call_args.last(), Some(klio_runtime::Value::Array { .. }))
                {
                    let fixed = info.n_params.saturating_sub(1);
                    let mut packed: Vec<klio_runtime::Value> = Vec::new();
                    if args.len() > fixed {
                        packed.extend(args[fixed..].iter().cloned());
                    }
                    call_args[info.n_params - 1] = klio_runtime::Value::Array {
                        items: klio_runtime::ObjRef::new(packed),
                        prim: None,
                    };
                }
            }
            let capture_values: Vec<klio_runtime::Value> = (**captures).clone();
            return klio_ir::eval::eval_with_captures(
                &module,
                &func,
                call_args,
                capture_values,
                self,
            );
        }
        Err(klio_ir::eval::EvalError::Unimplemented(format!(
            "Vm::call_value on `{}`",
            callee.type_fqn()
        )))
    }

    pub(crate) fn call_value_named(
        &mut self,
        callee: &klio_runtime::Value,
        args: &[klio_runtime::Value],
        _arg_names: &[Option<String>],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        self.call_value(callee, args)
    }

    pub(crate) fn call_value_with_this(
        &mut self,
        callee: &klio_runtime::Value,
        this_value: &klio_runtime::Value,
        args: &[klio_runtime::Value],
        _arg_names: &[Option<String>],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        use klio_runtime::IntrinsicHost as _;
        let mut sink = self.out_sink.clone();
        let r = {
            let mut intrinsic = VmIntrinsicHost {
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
            intrinsic.invoke_callable_with_this(callee, args, this_value, &mut sink)
        };
        r.map_err(|e| match e {
            klio_runtime::RuntimeError::Thrown(v) => klio_ir::eval::EvalError::Throw(v),
            klio_runtime::RuntimeError::Return(v) => klio_ir::eval::EvalError::NonLocalReturn(v),
            klio_runtime::RuntimeError::Suspend(wake) => {
                klio_ir::eval::EvalError::Suspended(Box::new(klio_ir::eval::SuspendState {
                    token: 0,
                    frames: Vec::new(),
                    wake_in_millis: wake,
                    pending_resume_reg: None,
                }))
            }
            other => klio_ir::eval::EvalError::Type(format!("{other}")),
        })
    }
}
