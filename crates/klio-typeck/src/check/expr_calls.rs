use super::{Checker, Expr, TypeRef, Span, Type, FnSig, annotations_include, lub, Diagnostic, codes, Stmt, scan_lambda_stmts_for_return, pick_msc, describe_params, widen_score, InferenceSession, substitute_type_params, expected_changed, array_element_type, primitive_array_elem_by_name, BinOp, equality_types_compatible, type_label, is_numeric, numeric_lub, GenericArg, Variance, Block, Binding};

impl Checker<'_> {
    pub(crate) fn check_call(
        &mut self,
        callee: &Expr,
        args: &[Expr],
        arg_names: &[Option<String>],
        type_args: &[TypeRef],
        call_span: Span,
    ) -> Type {
        // Direct named-callable case: `foo(args)` where `foo` is a known
        // user fn or class. Otherwise fall back to tolerant typing.
        if let Expr::Path { segments, span: callee_span } = callee
            && segments.len() == 1 {
                let name = &segments[0].name;
                self.enforce_dsl_scope_for_member(name, *callee_span);
                if !self.fns.contains_key(name) && !self.classes.contains_key(name) {
                    if let Some(ty) = self.check_toplevel_contract_call(name, args, call_span) {
                        return ty;
                    }
                    // Tolerant bare extension-call fallback. Inside a
                    // receiver-typed lambda the implicit receiver
                    // makes an extension function callable without a
                    // qualifier (`launch { … }` / `async { … }` are
                    // `CoroutineScope` extensions). The resolver/typeck
                    // have no receiver-type context at a bare call
                    // site. Only treat it as an extension call when
                    // the call is NOT infix (infix `a ext b` is
                    // dispatched as a member on the lhs elsewhere) —
                    // detected here by the trailing arg being a
                    // lambda, which is the receiver-lambda builder
                    // shape we care about.
                    let looks_like_builder = args
                        .last()
                        .is_some_and(|a| matches!(a, Expr::Lambda { .. } | Expr::AnonFun { .. }));
                    if looks_like_builder {
                        let ext_sig: Option<FnSig> = self
                            .extensions
                            .values()
                            .flat_map(|v| v.iter())
                            .find(|e| e.name == *name)
                            .map(|e| e.sig.clone());
                        if let Some(sig) = ext_sig {
                            return self.check_overloaded_call(
                                std::slice::from_ref(&sig),
                                args,
                                arg_names,
                                type_args,
                                callee.span(),
                            );
                        }
                    }
                }
                if let Some(sigs) = self.fns.get(name).cloned() {
                    if let Some(entries) = self.fn_visibility.get(name).cloned() {
                        for (v, f) in entries {
                            self.check_top_level_visibility(name, v, f, *callee_span);
                        }
                    }
                    if let Some(entries) = self.fn_visibility.get(name).cloned() {
                        let anns_list = self.fn_annotations.get(name).cloned().unwrap_or_default();
                        for (i, (v, _)) in entries.iter().enumerate() {
                            let anns = anns_list.get(i).cloned().unwrap_or_default();
                            self.check_published_api_use(name, *v, &anns, *callee_span);
                        }
                    }
                    let is_builder = self
                        .fn_annotations
                        .get(name)
                        .is_some_and(|list| list.iter().any(|anns| annotations_include(anns, "BuilderInference")));
                    let prev_bi = self.builder_inference_active;
                    if is_builder {
                        self.builder_inference_active = true;
                    }
                    let result = self.check_overloaded_call(
                        &sigs,
                        args,
                        arg_names,
                        type_args,
                        callee.span(),
                    );
                    self.builder_inference_active = prev_bi;
                    return result;
                }
                if name == "listOf" || name == "mutableListOf" {
                    let mut acc: Option<Type> = None;
                    for a in args {
                        let t = self.check_expr(a, None);
                        acc = Some(match acc {
                            None => t,
                            Some(prev) => lub(&prev, &t),
                        });
                    }
                    let elem = acc.unwrap_or(Type::Unresolved);
                    self.list_elem.insert(call_span, elem);
                    let _ = callee_span;
                    return Type::Unresolved;
                }
                if let Some(cls) = self.classes.get(name).cloned() {
                    self.check_class_use_visibility(name, &cls, *callee_span);
                    if cls.has_secondary_ctors {
                        // Multiple constructor arities exist; the interp
                        // picks the matching one at runtime. Skip arity
                        // checking and just type each arg loosely.
                        for a in args {
                            self.check_expr(a, None);
                        }
                        return Type::Unresolved;
                    }
                    if let Some(sig) = cls.ctor.clone() {
                        self.check_arity_and_args(&sig, args, callee.span());
                    } else {
                        for a in args {
                            self.check_expr(a, None);
                        }
                    }
                    return Type::Unresolved;
                }
            }
        // Stdlib chain methods on a `List<T>` seeded by `listOf` /
        // `mutableListOf` flow the element type through `map` / `filter` /
        // `fold` / `forEach` so the lambdas they take get a concrete
        // expected parameter type.
        if let Expr::Member { receiver, name, .. } = callee {
            if matches!(name.name.as_str(), "let" | "run" | "apply" | "also")
                && let Some(ty) = self.check_member_contract_call(receiver, &name.name, args) {
                    return ty;
                }
            let recv_ty = self.check_expr(receiver, None);
            let _ = recv_ty;
            if let Some(elem) = self.list_elem.get(&receiver.span()).cloned() {
                match name.name.as_str() {
                    "map" => {
                        if let Some(arg0) = args.first() {
                            let expect = Type::Function {
                                params: vec![elem.clone()],
                                return_type: Box::new(Type::Unresolved),
                                is_suspend: false,
                            };
                            let ty = self.check_expr(arg0, Some(&expect));
                            let new_elem = match ty {
                                Type::Function { return_type, .. } => *return_type,
                                _ => Type::Unresolved,
                            };
                            self.list_elem.insert(call_span, new_elem);
                            return Type::Unresolved;
                        }
                    }
                    "filter" => {
                        if let Some(arg0) = args.first() {
                            let expect = Type::Function {
                                params: vec![elem.clone()],
                                return_type: Box::new(Type::Boolean),
                                is_suspend: false,
                            };
                            let _ = self.check_expr(arg0, Some(&expect));
                            self.list_elem.insert(call_span, elem);
                            return Type::Unresolved;
                        }
                    }
                    "forEach" => {
                        if let Some(arg0) = args.first() {
                            let expect = Type::Function {
                                params: vec![elem.clone()],
                                return_type: Box::new(Type::Unit),
                                is_suspend: false,
                            };
                            let _ = self.check_expr(arg0, Some(&expect));
                            return Type::Unit;
                        }
                    }
                    "fold" if args.len() >= 2 => {
                        let init_ty = self.check_expr(&args[0], None);
                        let expect = Type::Function {
                            params: vec![init_ty.clone(), elem.clone()],
                            return_type: Box::new(init_ty.clone()),
                            is_suspend: false,
                        };
                        let _ = self.check_expr(&args[1], Some(&expect));
                        return init_ty;
                    }
                    _ => {}
                }
            }
            // Extension-function dispatch on a user class receiver. The
            // receiver was just typed above (its `expr_class` is now in
            // the map); walk the recv class chain looking for an
            // extension matching `name` and first-fit on arg types.
            // For a nullable receiver `s: T?`, expr_class is typically not
            // set. Derive the head-class name from the receiver type so
            // extension lookup against `T?.foo` extensions still works.
            let class_from_ty: Option<String> = if let Some(cn) = self.expr_class.get(&receiver.span()).cloned() { Some(cn) } else {
                let recv_ty = self.check_expr(receiver, None);
                match recv_ty.non_null() {
                    Type::Generic { name, .. } => Some(name.clone()),
                    Type::String => Some("String".to_string()),
                    Type::Int => Some("Int".to_string()),
                    Type::Long => Some("Long".to_string()),
                    Type::Boolean => Some("Boolean".to_string()),
                    Type::Char => Some("Char".to_string()),
                    Type::Double => Some("Double".to_string()),
                    Type::Float => Some("Float".to_string()),
                    _ => None,
                }
            };
            if let Some(cn) = class_from_ty {
                // Visibility check on member method calls. Runs before
                // extension fallback so a private member on the receiver's
                // class is flagged at the use site.
                if self.lookup_member_visibility(&cn, name.name.as_str()).is_some() {
                    self.check_member_visibility(&cn, name.name.as_str(), Some(&cn), name.span);
                }
                if let Some((sig, return_class)) =
                    self.lookup_extension(&cn, name.name.as_str(), args)
                {
                    if sig.params.is_empty() {
                        for a in args {
                            self.check_expr(a, None);
                        }
                    } else {
                        let _ = self.check_overloaded_call(
                            std::slice::from_ref(&sig),
                            args,
                            arg_names,
                            type_args,
                            call_span,
                        );
                    }
                    if let Some(cn) = return_class {
                        self.expr_class.insert(call_span, cn);
                    }
                    return sig.return_ty;
                }
            }
        }
        // Lambda value call: if callee has Function type, check params.
        let callee_ty = self.check_expr(callee, None);
        if let Type::Function { params, return_type, is_suspend } = callee_ty {
            if params.len() == args.len() {
                for (a, p) in args.iter().zip(params.iter()) {
                    let at = self.check_expr(a, Some(p));
                    self.check_assignable(&at, p, a.span());
                }
            } else {
                for a in args {
                    self.check_expr(a, None);
                }
            }
            self.enforce_suspend_coloring(is_suspend, "lambda", call_span);
            return *return_type;
        }
        for a in args {
            self.check_expr(a, None);
        }
        Type::Unresolved
    }

    /// Spec §18.1: emit T0115 when a suspending callee is invoked from a
    /// non-suspending context. The suspending context is set on entry to
    /// every `suspend fun` body and inherited by enclosing lambdas; the
    /// non-suspending base case is the top of any non-suspending function
    /// or file-top-level code.
    pub(crate) fn enforce_suspend_coloring(&mut self, callee_is_suspend: bool, callee_label: &str, span: Span) {
        if !callee_is_suspend {
            return;
        }
        let in_suspend = self.suspend_context_stack.last().copied().unwrap_or(false);
        if in_suspend {
            return;
        }
        self.diagnostics.emit(
            Diagnostic::error(
                format!(
                    "suspending {callee_label} called from a non-suspending context"
                ),
                span,
            )
            .with_code(codes::TYPE_SUSPEND_CALL_FROM_NON_SUSPEND),
        );
    }

    /// Picks an overload from `sigs` by first-fit on argument types and
    /// drives arity + assignability diagnostics against the chosen
    /// signature. Falls back to the first arity-matching signature when
    /// no candidate's parameter types are a clean fit, and to the first
    /// declared signature when even arity has no match.
    /// True when `e` contains a non-local `return` — one that
    /// targets the enclosing function rather than a nested lambda /
    /// anonymous-function literal. Crossinline lambdas must not
    /// contain such a return because the spliced body lives in the
    /// inline call's frame.
    pub(crate) fn lambda_body_has_nonlocal_return(stmts: &[Stmt]) -> bool {
        scan_lambda_stmts_for_return(stmts)
    }

    /// Scan each positional lambda argument against the candidates'
    /// `is_crossinline_param` flags. Emit T0056 when a lambda
    /// argument whose corresponding parameter is `crossinline` in
    /// any candidate carries a non-local `return`. Named-arg
    /// positions are resolved against each candidate's
    /// `param_names`.
    pub(crate) fn check_crossinline_arg_returns(
        &mut self,
        sigs: &[FnSig],
        args: &[Expr],
        arg_names: &[Option<String>],
    ) {
        if sigs.is_empty() {
            return;
        }
        if !sigs.iter().any(|s| s.is_crossinline_param.iter().any(|x| *x)) {
            return;
        }
        let mut next_pos: usize = 0;
        for (i, arg) in args.iter().enumerate() {
            let param_idx = if let Some(name) = arg_names.get(i).and_then(|n| n.as_ref()) { sigs
            .iter()
            .find_map(|s| s.param_names.iter().position(|p| p == name)) } else {
                let idx = next_pos;
                next_pos += 1;
                Some(idx)
            };
            let Some(idx) = param_idx else { continue };
            let is_crossinline_here = sigs
                .iter()
                .any(|s| s.is_crossinline_param.get(idx).copied().unwrap_or(false));
            if !is_crossinline_here {
                continue;
            }
            if let Expr::Lambda { body, span, .. } = arg
                && Self::lambda_body_has_nonlocal_return(&body.stmts) {
                    self.diagnostics.emit(
                        Diagnostic::error(
                            "non-local `return` is not allowed inside a lambda passed to a `crossinline` parameter"
                                .to_string(),
                            *span,
                        )
                        .with_code(codes::TYPE_CROSSINLINE_PARAM_LEAK),
                    );
                }
        }
    }

    pub(crate) fn check_overloaded_call(
        &mut self,
        sigs: &[FnSig],
        args: &[Expr],
        arg_names: &[Option<String>],
        type_args: &[TypeRef],
        call_span: Span,
    ) -> Type {
        // Crossinline-lambda non-local-return diagnostic (spec
        // §4.2.5 / T0056). If any overload candidate marks the
        // current arg position `crossinline` and the argument is a
        // lambda literal whose body contains a non-local `return`
        // (one not nested inside another lambda), the lambda
        // violates `crossinline`'s contract — the spliced body's
        // return would target the enclosing inline fn's caller, the
        // exact escape `crossinline` forbids.
        self.check_crossinline_arg_returns(sigs, args, arg_names);
        // Spec §11.2.6 / §11.2.8: filter the candidate set before any MSC
        // procedure runs. Named-arg names must each map to some parameter
        // of every surviving candidate; explicit `<...>` must match exactly
        // the candidate's declaration-site type-parameter count.
        let named_names: Vec<&str> = arg_names
            .iter()
            .filter_map(|n| n.as_deref())
            .collect();
        let has_type_args = !type_args.is_empty();
        let mut filtered: Vec<&FnSig> = sigs
            .iter()
            .filter(|s| {
                if has_type_args && s.type_param_count != type_args.len() {
                    return false;
                }
                named_names
                    .iter()
                    .all(|n| s.param_names.iter().any(|p| p == *n))
            })
            .collect();
        if filtered.is_empty() && !sigs.is_empty() {
            // Emit T0089 / T0092 against the first named arg / call span,
            // then fall back to the unfiltered set so downstream diagnostics
            // (arity, assignability) still surface usefully.
            if has_type_args
                && !sigs.iter().any(|s| s.type_param_count == type_args.len())
            {
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!(
                            "No candidate function accepts {} type argument(s)",
                            type_args.len()
                        ),
                        call_span,
                    )
                    .with_code(codes::TYPE_TYPE_ARGUMENT_COUNT_MISMATCH),
                );
            }
            for (i, n) in arg_names.iter().enumerate() {
                if let Some(name) = n
                    && !sigs.iter().any(|s| s.param_names.iter().any(|p| p == name)) {
                        let sp = args.get(i).map_or(call_span, klio_ast::Expr::span);
                        self.diagnostics.emit(
                            Diagnostic::error(
                                format!("No parameter named `{name}` on any candidate"),
                                sp,
                            )
                            .with_code(codes::TYPE_NAMED_PARAMETER_NOT_FOUND),
                        );
                    }
            }
            filtered = sigs.iter().collect();
        }
        if filtered.len() == 1 {
            let sig = filtered[0].clone();
            if has_type_args {
                self.check_type_arg_bounds(&sig, type_args);
            }
            self.check_arity_and_args(&sig, args, call_span);
            self.enforce_suspend_coloring(sig.is_suspend, "function", call_span);
            if has_type_args || sig.type_param_count == 0 {
                return sig.return_ty.clone();
            }
            // Pre-type each argument with its declared parameter type
            // as the expected hint (type-params stay abstract and are
            // treated permissively). Critically, a lambda argument
            // whose parameter is `suspend …` is then checked in a
            // suspend context, so calls like `runBlocking { delay() }`
            // don't spuriously flag the suspend body. Checking with
            // `None` here would lose that context and break inference
            // against `suspend CoroutineScope.() -> T`.
            let trailing_idx = Self::trailing_lambda_param_idx(&sig, args);
            let arg_tys: Vec<Type> = args
                .iter()
                .enumerate()
                .map(|(i, a)| {
                    let pidx = if i + 1 == args.len() {
                        trailing_idx.unwrap_or(i)
                    } else {
                        i
                    };
                    let hint = sig.params.get(pidx);
                    self.check_expr(a, hint)
                })
                .collect();
            return self.infer_call_return_with_args(&sig, &arg_tys, args, call_span);
        }
        // Pre-type each argument once; selection consults these types,
        // and assignability checks against the chosen signature reuse them
        // without re-evaluating.
        let arg_tys: Vec<Type> = args.iter().map(|a| self.check_expr(a, None)).collect();
        let mut chosen: Option<&FnSig> = None;
        let mut arity_match: Option<&FnSig> = None;
        let mut fitting: Vec<&FnSig> = Vec::new();
        for s in &filtered {
            let min = s.has_default.iter().filter(|h| !**h).count();
            let max = s.params.len();
            if args.len() < min || args.len() > max {
                continue;
            }
            if arity_match.is_none() {
                arity_match = Some(*s);
            }
            let fits = arg_tys
                .iter()
                .zip(s.params.iter())
                .all(|(a, p)| a.is_subtype_of(p));
            if fits {
                fitting.push(*s);
            }
        }
        if !fitting.is_empty() {
            // Spec §11.4.2: full MSC pairwise forwarding test, with the
            // integer-widening rule folded into the constraint comparison.
            // Falls back to the widen-only tiebreaker when MSC reports an
            // ambiguity, so untyped corpora remain parity-stable.
            match pick_msc(&fitting, args.len(), &self.classes) {
                Ok(best) => chosen = Some(best),
                Err(frontier) => {
                    let names: Vec<String> = frontier
                        .iter()
                        .map(|s| format!("({})", describe_params(&s.params)))
                        .collect();
                    self.diagnostics.emit(
                        Diagnostic::error(
                            format!(
                                "Overload resolution ambiguity between candidates: {}",
                                names.join(", ")
                            ),
                            call_span,
                        )
                        .with_code(codes::TYPE_OVERLOAD_RESOLUTION_AMBIGUITY),
                    );
                    let best = frontier
                        .into_iter()
                        .min_by_key(|s| widen_score(&s.params))
                        .unwrap();
                    chosen = Some(best);
                }
            }
        }
        if chosen.is_none() && arity_match.is_none() {
            // Spec §11.3: no candidate is applicable for the call. The
            // single-message form here keeps the diagnostic from
            // multiplying out into one per non-matching overload.
            let arities: Vec<String> = filtered
                .iter()
                .map(|s| {
                    let min = s.has_default.iter().filter(|h| !**h).count();
                    let max = s.params.len();
                    if min == max { format!("{min}") } else { format!("{min}..{max}") }
                })
                .collect();
            self.diagnostics.emit(
                Diagnostic::error(
                    format!(
                        "No candidate accepts {} argument(s); expected {}",
                        args.len(),
                        arities.join(" or ")
                    ),
                    call_span,
                )
                .with_code(codes::TYPE_NONE_APPLICABLE),
            );
            return Type::Unresolved;
        }
        let sig = chosen.or(arity_match).unwrap().clone();
        if has_type_args {
            self.check_type_arg_bounds(&sig, type_args);
        }
        self.enforce_suspend_coloring(sig.is_suspend, "function", call_span);
        let min = sig.has_default.iter().filter(|h| !**h).count();
        let max = sig.params.len();
        if args.len() < min || args.len() > max {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!(
                        "Wrong number of arguments: expected {min}..{max}, got {}",
                        args.len()
                    ),
                    call_span,
                )
                .with_code(codes::TYPE_ARGUMENT_COUNT),
            );
        } else {
            for ((a, p), at) in args.iter().zip(sig.params.iter()).zip(arg_tys.iter()) {
                self.check_assignable(at, p, a.span());
            }
        }
        if has_type_args {
            return sig.return_ty;
        }
        self.infer_call_return_with_args(&sig, &arg_tys, args, call_span)
    }

    /// Spec §13: at a generic call with no explicit `<...>`, allocate one
    /// inference variable per declared type parameter, seed bounds from
    /// each `arg_ty <: param_ty` constraint (replacing TypeParam(name)
    /// with the corresponding inference var), solve to fixpoint, and
    /// substitute the solution into the declared return type. Emits
    /// T0097 if reduction fails. Returns `sig.return_ty` unchanged when
    /// the sig has no type parameters or the return type doesn't
    /// reference any of them.
    #[cfg(test)]
    pub(crate) fn infer_call_return(&mut self, sig: &FnSig, arg_tys: &[Type], call_span: Span) -> Type {
        self.infer_call_return_with_args(sig, arg_tys, &[], call_span)
    }

    /// Spec §13 inference, run inside a multi-call session so nested
    /// generic calls in `args` contribute to a single solver. The
    /// outermost call solves once and substitutes; inner calls
    /// return their fresh-var-bearing return type for the outer to
    /// continue constraining.
    pub(crate) fn infer_call_return_with_args(
        &mut self,
        sig: &FnSig,
        arg_tys: &[Type],
        args: &[Expr],
        call_span: Span,
    ) -> Type {
        use klio_types::constraints::{
            ConstraintKind, ConstraintSystem, Provenance, SolutionPreference,
        };
        if sig.type_param_count == 0 || sig.type_param_names.is_empty() {
            return sig.return_ty.clone();
        }
        let is_root = self.inference_session.is_none();
        if is_root {
            self.inference_session = Some(InferenceSession {
                cs: ConstraintSystem::new(),
                depth: 0,
            });
        }
        let mut local_subst: std::collections::HashMap<String, Type> =
            std::collections::HashMap::new();
        let mut vars: Vec<klio_types::constraints::InferenceVar> = Vec::new();
        {
            let session = self.inference_session.as_mut().unwrap();
            session.depth += 1;
            for name in &sig.type_param_names {
                let unique = format!("{name}@{}-{}", call_span.start, call_span.end);
                let (v, t) = session.cs.fresh(&unique);
                session.cs.set_preference(v, SolutionPreference::PullUp);
                local_subst.insert(name.clone(), t);
                vars.push(v);
            }
            // Map each argument to its parameter slot, honouring a
            // trailing lambda that binds to the last functional
            // parameter past defaulted middle params (so `async { … }`
            // constrains the lambda against `block`, not `context`).
            let trailing_idx = Self::trailing_lambda_param_idx(sig, args);
            for (i, at) in arg_tys.iter().enumerate() {
                if matches!(at, Type::Unresolved) {
                    continue;
                }
                let pidx = if i + 1 == arg_tys.len() {
                    trailing_idx.unwrap_or(i)
                } else {
                    i
                };
                let Some(p) = sig.params.get(pidx) else { continue };
                let p_with_vars = substitute_type_params(p, &local_subst);
                session.cs.add_constraint_with(
                    at.clone(),
                    p_with_vars,
                    ConstraintKind::Subtype,
                    Provenance::CallSite { span: call_span, arg_idx: i },
                );
            }
        }
        // The return type carries our fresh inference vars. Outer
        // call resolution (and the lambda re-typing pass below)
        // sees them as `TypeParam(...)` which downstream checks
        // treat permissively. When we are the root call, we solve
        // below and replace them with the concrete substitution.
        let mut returned = substitute_type_params(&sig.return_ty, &local_subst);
        // Lambda re-typing: re-check lambda args with substituted
        // expected types when the outer call has begun to refine them.
        // Works without a final solution because the partial
        // substitution maps every TypeParam(name) we own to its
        // session var, and the smart-cast walk through cfg_narrowed_at
        // returns concrete types where it can.
        let mut final_subst = local_subst.clone();
        if is_root {
            let session = self.inference_session.as_mut().unwrap();
            if let Err(_e) = session.cs.solve_to_fixpoint() {
                if !self.builder_inference_active {
                    let mut msg = "type inference failed for this call".to_string();
                    if let Some((_err, prov)) = session.cs.last_error()
                        && let Provenance::CallSite { arg_idx, .. } = prov {
                            msg = format!(
                                "type inference failed for this call; argument {} does not satisfy the inferred parameter type",
                                arg_idx + 1
                            );
                        }
                    self.diagnostics
                        .emit(Diagnostic::error(msg, call_span).with_code(codes::TYPE_INFERENCE_FAILED));
                }
                session.depth -= 1;
                if session.depth == 0 {
                    self.inference_session = None;
                }
                return sig.return_ty.clone();
            }
            let staged = session.cs.solve_staged();
            let legacy = session.cs.solve();
            for (i, name) in sig.type_param_names.iter().enumerate() {
                if let Some(v) = vars.get(i) {
                    let pick = staged.get(v).or_else(|| legacy.get(v));
                    if let Some(t) = pick
                        && !matches!(t, Type::Nothing) {
                            final_subst.insert(name.clone(), t.clone());
                        }
                }
            }
        }
        // Lambda re-typing pass — only meaningful at the root,
        // since the substitution carries the fully-solved types.
        if is_root {
            let trailing_idx = Self::trailing_lambda_param_idx(sig, args);
            for (i, arg) in args.iter().enumerate() {
                if !matches!(arg, Expr::Lambda { .. }) {
                    continue;
                }
                let pidx = if i + 1 == args.len() {
                    trailing_idx.unwrap_or(i)
                } else {
                    i
                };
                let Some(param_ty) = sig.params.get(pidx) else { continue };
                let expected = substitute_type_params(param_ty, &final_subst);
                if !expected_changed(param_ty, &expected) {
                    continue;
                }
                let refined = self.check_expr(arg, Some(&expected));
                if let (
                    Type::Function { return_type: r_expected, .. },
                    Type::Function { return_type: r_refined, .. },
                ) = (&expected, &refined)
                    && let Type::TypeParam(name) = r_expected.as_ref()
                        && !matches!(**r_refined, Type::Unresolved | Type::Nothing) {
                            final_subst.insert(name.clone(), (**r_refined).clone());
                        }
            }
            returned = substitute_type_params(&sig.return_ty, &final_subst);
        }
        let session = self.inference_session.as_mut().unwrap();
        session.depth -= 1;
        if is_root {
            // The root closes the session after substitution.
            self.inference_session = None;
        }
        returned
    }

    /// Index of the parameter a trailing-lambda argument binds to,
    /// when the call omits defaulted middle parameters. Kotlin lets
    /// `obj.async { … }` bind the lambda to the last functional
    /// parameter (`block`), skipping the defaulted `context`. Returns
    /// `Some(last_param_idx)` only for the final argument when it is
    /// a lambda, the call passed fewer args than params, and the
    /// last parameter is a functional type.
    pub(crate) fn trailing_lambda_param_idx(sig: &FnSig, args: &[Expr]) -> Option<usize> {
        if args.is_empty() || sig.params.len() <= args.len() {
            return None;
        }
        let last = args.len() - 1;
        if !matches!(args[last], Expr::Lambda { .. } | Expr::AnonFun { .. }) {
            return None;
        }
        let lp = sig.params.len() - 1;
        if matches!(sig.params.get(lp), Some(Type::Function { .. })) {
            Some(lp)
        } else {
            None
        }
    }

    pub(crate) fn check_arity_and_args(&mut self, sig: &FnSig, args: &[Expr], call_span: Span) {
        let vararg_idx = sig.is_vararg.iter().position(|v| *v);
        let trailing_lambda_idx = Self::trailing_lambda_param_idx(sig, args);
        // Spread arguments must land on a vararg parameter regardless of
        // arity. Emit T0047 up front so the diagnostic still fires when a
        // mis-spread also produces an arity mismatch.
        if vararg_idx.is_none() {
            for a in args {
                if let Expr::Spread { span, .. } = a {
                    self.diagnostics.emit(
                        Diagnostic::error(
                            "`*` spread argument requires a `vararg` parameter",
                            *span,
                        )
                        .with_code(codes::TYPE_SPREAD_REQUIRES_VARARG),
                    );
                }
            }
        }
        let min_args = sig
            .has_default
            .iter()
            .zip(sig.is_vararg.iter())
            .filter(|(h, v)| !**h && !**v)
            .count();
        let max_args = sig.params.len();
        let arity_ok = if vararg_idx.is_some() {
            args.len() >= min_args
        } else {
            args.len() >= min_args && args.len() <= max_args
        };
        if !arity_ok {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!(
                        "Wrong number of arguments: expected {min_args}..{max_args}, got {}",
                        args.len()
                    ),
                    call_span,
                )
                .with_code(codes::TYPE_ARGUMENT_COUNT),
            );
            for a in args {
                self.check_expr(a, None);
            }
            return;
        }
        // Per-arg typing. Spread args must land on a vararg parameter,
        // otherwise emit T0047.
        for (i, a) in args.iter().enumerate() {
            let is_spread = matches!(a, Expr::Spread { .. });
            // Map positional index i to a parameter slot. Past the vararg
            // index, every additional positional arg lands on the vararg.
            let target_param = if Some(i) == trailing_lambda_idx.map(|_| args.len() - 1) {
                trailing_lambda_idx.unwrap()
            } else {
                match vararg_idx {
                    Some(va_i) if i >= va_i => va_i,
                    _ => i,
                }
            };
            if is_spread {
                let is_va = sig.is_vararg.get(target_param).copied().unwrap_or(false);
                if !is_va {
                    self.diagnostics.emit(
                        Diagnostic::error(
                            "`*` spread argument requires a `vararg` parameter",
                            a.span(),
                        )
                        .with_code(codes::TYPE_SPREAD_REQUIRES_VARARG),
                    );
                }
                // Recurse into the spread expression for diagnostics.
                if let Expr::Spread { expr, .. } = a {
                    let spread_ty = self.check_expr(expr, None);
                    // §8.21.5: spread expression's element type must be a
                    // subtype of the vararg parameter's element type.
                    if is_va
                        && let Some(param_elem) = sig.params.get(target_param) {
                            let spread_elem = array_element_type(&spread_ty).or_else(|| {
                                self.expr_class
                                    .get(&expr.span())
                                    .and_then(|cn| primitive_array_elem_by_name(cn))
                            });
                            if let Some(spread_elem) = spread_elem
                                && !spread_elem.is_subtype_of(param_elem) {
                                    self.diagnostics.emit(
                                        Diagnostic::error(
                                            format!(
                                                "spread argument element type `{spread_elem}` is not a subtype of vararg parameter element type `{param_elem}`"
                                            ),
                                            expr.span(),
                                        )
                                        .with_code(codes::TYPE_SPREAD_TYPE_MISMATCH),
                                    );
                                }
                        }
                }
                continue;
            }
            let Some(p) = sig.params.get(target_param) else { continue };
            let at = self.check_expr(a, Some(p));
            if vararg_idx != Some(target_param) {
                self.check_assignable(&at, p, a.span());
            }
        }
        let _ = sig.param_names.len();
    }

    /// Spec ch.9: every function reached through a definition-by-convention
    /// dispatch site must carry the `operator` modifier. Look up the member
    /// (walking supertypes) on the receiver's user-class name and emit
    /// T0087 when found without the flag. No diagnostic when the class isn't
    /// known (built-in types, type params, generics without bound info).
    pub(crate) fn check_user_operator_keyword(&mut self, receiver_class: Option<&str>, op_name: &str, span: Span) {
        let Some(class_name) = receiver_class else { return };
        let mut visited: std::collections::HashSet<String> = std::collections::HashSet::new();
        let mut stack: Vec<String> = vec![class_name.to_string()];
        while let Some(name) = stack.pop() {
            if !visited.insert(name.clone()) {
                continue;
            }
            let Some(info) = self.classes.get(&name) else { continue };
            if let Some(flags) = info.member_flags.get(op_name) {
                if !flags.is_operator {
                    self.diagnostics.emit(
                        Diagnostic::warning(
                            format!(
                                "`{name}.{op_name}` is used as an operator-convention function but is missing the `operator` modifier"
                            ),
                            span,
                        )
                        .with_code(codes::TYPE_OPERATOR_KEYWORD_MISSING),
                    );
                }
                return;
            }
            for s in &info.supertypes {
                stack.push(s.clone());
            }
        }
    }

    pub(crate) fn check_binary(&mut self, op: BinOp, lhs: &Expr, rhs: &Expr, span: Span) -> Type {
        let l = self.check_expr(lhs, None);
        // `&&` / `||` narrowing flow is handled by the CFG: the
        // lowering emits AssumeIs / AssumeNull / AssumeRefEq on the
        // rhs block before the rhs expression evaluates, so smart-
        // cast queries at rhs spans see lhs's truthy facts.
        let _ = op;
        let r = self.check_expr(rhs, None);
        // Spec ch.9: dispatch-site `operator` modifier check. Binary arith
        // / range / comparison dispatches on the LHS class; `in` / `!in`
        // dispatches on the RHS class.
        let op_name: Option<&str> = match op {
            BinOp::Add => Some("plus"),
            BinOp::Sub => Some("minus"),
            BinOp::Mul => Some("times"),
            BinOp::Div => Some("div"),
            BinOp::Rem => Some("rem"),
            BinOp::Range => Some("rangeTo"),
            BinOp::RangeUntil => Some("rangeUntil"),
            BinOp::Lt | BinOp::Le | BinOp::Gt | BinOp::Ge => Some("compareTo"),
            _ => None,
        };
        if let Some(name) = op_name {
            let cls = self.expr_class.get(&lhs.span()).cloned();
            self.check_user_operator_keyword(cls.as_deref(), name, span);
        }
        if matches!(op, BinOp::In | BinOp::NotIn) {
            let cls = self.expr_class.get(&rhs.span()).cloned();
            self.check_user_operator_keyword(cls.as_deref(), "contains", span);
        }
        // Spec §12: comparing `x == null` / `x != null` where `x` has a
        // statically known non-nullable type always yields the same value;
        // surface it as W0003 so the user can drop the dead branch.
        if matches!(op, BinOp::Eq | BinOp::Neq | BinOp::IdentEq | BinOp::IdentNeq) {
            let null_other = if matches!(lhs, Expr::NullLit { .. }) {
                Some(&r)
            } else if matches!(rhs, Expr::NullLit { .. }) {
                Some(&l)
            } else {
                None
            };
            if let Some(other) = null_other
                && !matches!(other, Type::Nullable(_) | Type::Unresolved | Type::Nothing) {
                    let result = matches!(op, BinOp::Neq | BinOp::IdentNeq);
                    self.diagnostics.emit(
                        Diagnostic::warning(
                            format!("Condition is always '{result}'"),
                            span,
                        )
                        .with_code(codes::WARN_SENSELESS_COMPARISON)
                        .with_factory(
                            &klio_diagnostics::generated::factories::SENSELESS_COMPARISON,
                        ),
                    );
                }
        }
        // Spec §8.9.1 / §8.9.2: an equality between two definitely-distinct
        // types unrelated by subtyping is a compile-time error. Skip when
        // either side is `null` (the spec routes the null arm separately) or
        // when either side typed to `Unresolved` (we have no information).
        if matches!(op, BinOp::Eq | BinOp::Neq | BinOp::IdentEq | BinOp::IdentNeq)
            && !matches!(lhs, Expr::NullLit { .. })
            && !matches!(rhs, Expr::NullLit { .. })
            && !equality_types_compatible(&l, &r)
        {
            let (code, label) = if matches!(op, BinOp::IdentEq | BinOp::IdentNeq) {
                (
                    codes::TYPE_REFERENCE_EQUALITY_DISTINCT_TYPES,
                    "reference equality",
                )
            } else {
                (codes::TYPE_VALUE_EQUALITY_DISTINCT_TYPES, "equality")
            };
            self.diagnostics.emit(
                Diagnostic::error(
                    format!(
                        "{label} between `{}` and `{}` is impossible — types are unrelated",
                        type_label(&l),
                        type_label(&r),
                    ),
                    span,
                )
                .with_code(code),
            );
        }
        match op {
            BinOp::Add => {
                if matches!(l.non_null(), Type::String) || matches!(r.non_null(), Type::String) {
                    Type::String
                } else if is_numeric(&l) || is_numeric(&r) {
                    numeric_lub(&l, &r)
                } else {
                    Type::Unresolved
                }
            }
            BinOp::Sub | BinOp::Mul | BinOp::Div | BinOp::Rem => {
                if is_numeric(&l) || is_numeric(&r) {
                    numeric_lub(&l, &r)
                } else {
                    Type::Unresolved
                }
            }
            BinOp::Eq | BinOp::Neq | BinOp::IdentEq | BinOp::IdentNeq => Type::Boolean,
            BinOp::Lt | BinOp::Le | BinOp::Gt | BinOp::Ge => Type::Boolean,
            BinOp::In | BinOp::NotIn => Type::Boolean,
            BinOp::And | BinOp::Or => Type::Boolean,
            BinOp::Range | BinOp::RangeUntil => Type::Range(Box::new(numeric_lub(&l, &r))),
            BinOp::Elvis => {
                if !matches!(l, Type::Nullable(_) | Type::Unresolved | Type::Nothing) {
                    self.diagnostics.emit(
                        Diagnostic::warning(
                            "Elvis operator (?:) always returns the left operand of non-nullable type".to_string(),
                            span,
                        )
                        .with_code(codes::WARN_USELESS_ELVIS)
                        .with_factory(&klio_diagnostics::generated::factories::USELESS_ELVIS),
                    );
                }
                let lhs_non_null = match l {
                    Type::Nullable(inner) => (*inner).clone(),
                    other => other.clone(),
                };
                // Spec §14.1: when the rhs diverges (return / throw / continue /
                // break, all typed as `Nothing`), control falls through only when
                // the lhs was non-null. Narrow the lhs in the enclosing frame.
                // Elvis-return / elvis-throw narrowing is handled by
                // the CFG: the diverging rhs makes the null arm
                // unreachable, so the join state inherits the lhs's
                // non-null projection from the nonnull arm.
                let _ = lhs_non_null.clone();
                lub(&lhs_non_null, &r)
            }
            BinOp::Assign => Type::Unit,
        }
    }

    /// Type-check a stdlib top-level contract call like `run { ... }`,
    /// `with(x) { ... }`, `check(c)`, `require(c)`. Returns `None` if the
    /// shape does not match any known contract; the caller falls back to
    /// normal call dispatch in that case.
    pub(crate) fn check_toplevel_contract_call(
        &mut self,
        name: &str,
        args: &[Expr],
        call_span: Span,
    ) -> Option<Type> {
        let _ = call_span;
        match name {
            "run" if args.len() == 1 => {
                if let Expr::Lambda { params, body, .. } = &args[0] {
                    let ty = self.check_lambda_in_place(params, body, None, None);
                    return Some(match ty {
                        Type::Function { return_type, .. } => *return_type,
                        _ => Type::Unresolved,
                    });
                }
                None
            }
            // `suspendCoroutine<T> { cont -> … }` returns T, not the
            // lambda's body type (Unit). The lambda is invoked once
            // with a `Continuation<T>` whose `resume(v)` provides
            // the call's result. We don't have a generic-arg-aware
            // path here, so leave the call's result type
            // unresolved — assignment context drives the binding
            // type, and our solver-side handling propagates.
            "suspendCoroutine"
            | "suspendCoroutineUninterceptedOrReturn"
            | "suspendCancellableCoroutine"
                if args.len() == 1 =>
            {
                if let Expr::Lambda { params, body, .. } = &args[0] {
                    self.suspend_context_stack.push(true);
                    let _ = self.check_lambda_in_place(params, body, None, None);
                    self.suspend_context_stack.pop();
                }
                Some(Type::Unresolved)
            }
            "with" if args.len() == 2 => {
                let recv = self.check_expr(&args[0], None);
                let recv_cls = self.expr_class.get(&args[0].span()).cloned();
                if let Expr::Lambda { params, body, .. } = &args[1] {
                    let ty = self.check_lambda_in_place(
                        params,
                        body,
                        None,
                        Some((recv.clone(), recv_cls)),
                    );
                    return Some(match ty {
                        Type::Function { return_type, .. } => *return_type,
                        _ => Type::Unresolved,
                    });
                }
                None
            }
            // Spec §14.5 builder-style inference. We accept the call shape
            // (one trailing lambda, optional initial capacity for the list
            // / set / map variants) without solving a postponed type
            // variable for the element / key-value types — those would
            // require collecting `add` / `put` argument types from inside
            // the lambda body and unifying them. For now, type the body
            // permissively (lambda receiver is left Unresolved so member
            // references inside don't false-positive) and return the
            // appropriate result type.
            "buildList" | "buildSet" if (1..=2).contains(&args.len()) => {
                let lambda = args.last().unwrap();
                let mut elem = Type::Nothing;
                if let Expr::Lambda { params, body, .. } = lambda {
                    self.check_lambda_in_place(
                        params,
                        body,
                        None,
                        Some((Type::Unresolved, None)),
                    );
                    elem = self.collect_builder_call_arg_type(body, "add", 0);
                }
                if matches!(elem, Type::Nothing | Type::Unresolved) {
                    return Some(Type::Unresolved);
                }
                let head = if name == "buildList" { "List" } else { "Set" };
                Some(Type::Generic {
                    name: head.to_string(),
                    args: vec![GenericArg {
                        variance: Variance::Invariant,
                        is_star: false,
                        ty: elem,
                    }],
                })
            }
            "buildMap" if (1..=2).contains(&args.len()) => {
                let lambda = args.last().unwrap();
                let mut k_ty = Type::Nothing;
                let mut v_ty = Type::Nothing;
                if let Expr::Lambda { params, body, .. } = lambda {
                    self.check_lambda_in_place(
                        params,
                        body,
                        None,
                        Some((Type::Unresolved, None)),
                    );
                    k_ty = self.collect_builder_call_arg_type(body, "put", 0);
                    v_ty = self.collect_builder_call_arg_type(body, "put", 1);
                }
                if matches!(k_ty, Type::Nothing | Type::Unresolved)
                    || matches!(v_ty, Type::Nothing | Type::Unresolved)
                {
                    return Some(Type::Unresolved);
                }
                Some(Type::Generic {
                    name: "Map".to_string(),
                    args: vec![
                        GenericArg {
                            variance: Variance::Invariant,
                            is_star: false,
                            ty: k_ty,
                        },
                        GenericArg {
                            variance: Variance::Invariant,
                            is_star: false,
                            ty: v_ty,
                        },
                    ],
                })
            }
            "sequence" | "iterator" if args.len() == 1 => {
                let mut elem = Type::Nothing;
                if let Expr::Lambda { params, body, .. } = &args[0] {
                    // The `sequence { }` / `iterator { }` block has a
                    // `suspend SequenceScope<T>.() -> Unit` type, so
                    // `yield` / `yieldAll` (suspend funcs) inside it
                    // are in a suspending context.
                    self.suspend_context_stack.push(true);
                    self.check_lambda_in_place(
                        params,
                        body,
                        None,
                        Some((Type::Unresolved, None)),
                    );
                    self.suspend_context_stack.pop();
                    elem = self.collect_builder_call_arg_type(body, "yield", 0);
                }
                if matches!(elem, Type::Nothing | Type::Unresolved) {
                    return Some(Type::Unresolved);
                }
                let head = if name == "sequence" { "Sequence" } else { "Iterator" };
                Some(Type::Generic {
                    name: head.to_string(),
                    args: vec![GenericArg {
                        variance: Variance::Invariant,
                        is_star: false,
                        ty: elem,
                    }],
                })
            }
            "buildString" if args.len() == 1 => {
                if let Expr::Lambda { params, body, .. } = &args[0] {
                    self.check_lambda_in_place(
                        params,
                        body,
                        None,
                        Some((Type::Unresolved, Some("StringBuilder".to_string()))),
                    );
                }
                Some(Type::String)
            }
            // `public inline fun repeat(times: Int, action: (Int) ->
            // Unit)`. Being inline, `action` inherits the caller's
            // suspend context — `repeat(n) { delay() }` is legal
            // inside a coroutine builder. Routing through
            // `check_lambda_in_place` (which does not reset the
            // suspend-context stack) preserves that inheritance,
            // whereas the generic call path would force the lambda's
            // context to the non-suspend param type.
            "repeat" if args.len() == 2 => {
                let _ = self.check_expr(&args[0], Some(&Type::Int));
                if let Expr::Lambda { params, body, .. } = &args[1] {
                    self.check_lambda_in_place(
                        params,
                        body,
                        Some((Type::Int, None)),
                        None,
                    );
                } else {
                    let _ = self.check_expr(&args[1], None);
                }
                Some(Type::Unit)
            }
            "check" | "require" if (1..=2).contains(&args.len()) => {
                let cond = &args[0];
                let _ = self.check_expr(cond, Some(&Type::Boolean));
                for a in &args[1..] {
                    self.check_expr(a, None);
                }
                // The CFG's contract effect emits Assume nodes for
                // `check` / `require` after the call, picking up
                // every refinement the lowering tracked on the
                // condition register.
                Some(Type::Unit)
            }
            _ => None,
        }
    }

    /// Type-check a member-form scope-function call: `recv.let { ... }`,
    /// `recv.run { ... }`, `recv.apply { ... }`, `recv.also { ... }`.
    /// Returns `None` if `name` is not a recognized scope function.
    pub(crate) fn check_member_contract_call(
        &mut self,
        recv: &Expr,
        name: &str,
        args: &[Expr],
    ) -> Option<Type> {
        if args.len() != 1 {
            return None;
        }
        let Expr::Lambda { params, body, .. } = &args[0] else { return None };
        let recv_ty = self.check_expr(recv, None);
        let recv_cls = self.expr_class.get(&recv.span()).cloned();
        match name {
            "let" => {
                let ty = self.check_lambda_in_place(
                    params,
                    body,
                    Some((recv_ty.clone(), recv_cls.clone())),
                    None,
                );
                Some(match ty {
                    Type::Function { return_type, .. } => *return_type,
                    _ => Type::Unresolved,
                })
            }
            "run" => {
                let ty = self.check_lambda_in_place(
                    params,
                    body,
                    None,
                    Some((recv_ty.clone(), recv_cls.clone())),
                );
                Some(match ty {
                    Type::Function { return_type, .. } => *return_type,
                    _ => Type::Unresolved,
                })
            }
            "apply" => {
                self.check_lambda_in_place(
                    params,
                    body,
                    None,
                    Some((recv_ty.clone(), recv_cls.clone())),
                );
                Some(recv_ty)
            }
            "also" => {
                self.check_lambda_in_place(
                    params,
                    body,
                    Some((recv_ty.clone(), recv_cls.clone())),
                    None,
                );
                Some(recv_ty)
            }
            _ => None,
        }
    }

    /// Walk a builder lambda body collecting argument types from every
    /// implicit-this call of `target_name` (e.g. `add(x)` in `buildList`).
    /// Returns the LUB of those argument types at `arg_idx`. Used to
    /// infer the element / key / value type of `buildList` / `buildSet` /
    /// `buildMap` / `sequence` from the lambda body.
    pub(crate) fn collect_builder_call_arg_type(
        &mut self,
        body: &Block,
        target_name: &str,
        arg_idx: usize,
    ) -> Type {
        let mut acc: Option<Type> = None;
        self.walk_builder_block(body, target_name, arg_idx, &mut acc);
        acc.unwrap_or(Type::Nothing)
    }

    pub(crate) fn walk_builder_block(
        &mut self,
        body: &Block,
        target_name: &str,
        arg_idx: usize,
        acc: &mut Option<Type>,
    ) {
        for s in &body.stmts {
            match s {
                Stmt::Expr(e) => self.walk_builder_expr(e, target_name, arg_idx, acc),
                Stmt::Assign { value, .. } => {
                    self.walk_builder_expr(value, target_name, arg_idx, acc);
                }
                Stmt::DestructuringDecl { init, .. } => {
                    self.walk_builder_expr(init, target_name, arg_idx, acc);
                }
                Stmt::Decl(_) => {}
            }
        }
    }

    pub(crate) fn walk_builder_expr(
        &mut self,
        expr: &Expr,
        target_name: &str,
        arg_idx: usize,
        acc: &mut Option<Type>,
    ) {
        if let Expr::Call { callee, args, .. } = expr {
            let name = match callee.as_ref() {
                Expr::Path { segments, .. } if segments.len() == 1 => {
                    Some(segments[0].name.clone())
                }
                _ => None,
            };
            if name.as_deref() == Some(target_name)
                && let Some(a) = args.get(arg_idx) {
                    let t = self.check_expr(a, None);
                    *acc = Some(match acc.take() {
                        Some(prev) => lub(&prev, &t),
                        None => t,
                    });
                }
            for a in args {
                self.walk_builder_expr(a, target_name, arg_idx, acc);
            }
        }
    }

    /// Type-check a lambda body without saving/restoring `assigned`. Per
    /// the spec §12.2.5 calls-in-place exactly-once contract, assignments
    /// performed inside the body must propagate to the enclosing CFG.
    /// `it_binding` and `this_binding` supply implicit `it` / `this` from
    /// scope-function receivers.
    pub(crate) fn check_lambda_in_place(
        &mut self,
        params: &[klio_ast::Ident],
        body: &Block,
        it_binding: Option<(Type, Option<String>)>,
        this_binding: Option<(Type, Option<String>)>,
        ) -> Type {
        self.push_frame();
        if params.is_empty() {
            let (it_ty, it_cls) = it_binding.unwrap_or((Type::Unresolved, None));
            self.current_frame().bindings.insert(
                "it".to_string(),
                Binding {
                    ty: it_ty,
                    mutable: false,
                    decl_span: None,
                    class_name: it_cls,
                    
                    decl_type_name: None,
                },
            );
        } else {
            for p in params {
                self.current_frame().bindings.insert(
                    p.name.clone(),
                    Binding {
                        ty: Type::Unresolved,
                        mutable: false,
                        decl_span: Some(p.span),
                        class_name: None,
                        
                        decl_type_name: None,
                    },
                );
            }
        }
        if let Some((this_ty, this_cls)) = this_binding {
            self.current_frame().bindings.insert(
                "this".to_string(),
                Binding {
                    ty: this_ty,
                    mutable: false,
                    decl_span: None,
                    class_name: this_cls.clone(),
                    
                    decl_type_name: None,
                },
            );
            if let Some(cn) = this_cls {
                let markers = self
                    .dsl_class_markers
                    .get(&cn)
                    .cloned()
                    .unwrap_or_default();
                self.dsl_receiver_stack.push((cn.clone(), markers));
                self.class_stack.push(cn);
                let actual_ret = self.check_block(body, None);
                self.class_stack.pop();
                self.dsl_receiver_stack.pop();
                self.pop_frame();
                return Type::Function {
                    params: vec![],
                    return_type: Box::new(actual_ret),
                    is_suspend: false,
                };
            }
        }
        let actual_ret = self.check_block(body, None);
        self.pop_frame();
        Type::Function {
            params: vec![],
            return_type: Box::new(actual_ret),
            is_suspend: false,
        }
    }

    pub(crate) fn check_lambda(&mut self, params: &[klio_ast::Ident], body: &Block, expected: Option<&Type>) -> Type {
        // Pull param types from expected function type, if it's one.
        let (param_tys, ret_expected, is_suspend): (Vec<Type>, Type, bool) = match expected.map(Type::non_null) {
            Some(Type::Function { params: ps, return_type, is_suspend }) => {
                let ps = ps.clone();
                let r = (**return_type).clone();
                (ps, r, *is_suspend)
            }
            _ => (
                std::iter::repeat_n(Type::Unresolved, params.len().max(1)).collect(),
                Type::Unresolved,
                false,
            ),
        };
        self.push_frame();
        // Spec §18.1: a lambda assigned to a `suspend (…) -> R` slot
        // becomes a suspending lambda. A lambda passed to an `inline`
        // function (`let`/`run`/`forEach`/`map`/… and the `sequence`/
        // `iterator` builders) is inlined into the caller, so it also
        // inherits the enclosing suspending bit — e.g. `sequence { …
        // list.forEach { yield(it) } }`. Inheriting is Kotlin-correct
        // for inline lambdas and only lenient for the rare
        // non-inline case (klio favours not false-positiving on the
        // consumed upstream, which is itself valid Kotlin).
        let enclosing_suspend =
            self.suspend_context_stack.last().copied().unwrap_or(false);
        self.suspend_context_stack.push(is_suspend || enclosing_suspend);
        // Spec §14.3.2 step 3: pick zero vs one phantom `it` based on the
        // expected callable shape. The parser preemptively pushes a synthetic
        // `it` for any zero-`->` lambda body, so when the expected callable
        // is zero-arity we strip that synthetic param. Treat
        // `params == [{ name: "it" }]` with expected arity 0 as a zero-param
        // lambda — `it` is not bound and the lambda type carries no params.
        let expected_arity = match expected.map(Type::non_null) {
            Some(Type::Function { params: ps, .. }) => Some(ps.len()),
            _ => None,
        };
        let synthetic_it =
            params.len() == 1 && params[0].name == "it" && expected_arity == Some(0);
        let effective_empty = params.is_empty() || synthetic_it;
        let bind_it = effective_empty && expected_arity != Some(0);
        if bind_it {
            self.current_frame().bindings.insert(
                "it".to_string(),
                Binding {
                    ty: param_tys.first().cloned().unwrap_or(Type::Unresolved),
                    mutable: false,
                    decl_span: None, class_name: None, decl_type_name: None },
            );
        } else if !effective_empty {
            for (i, p) in params.iter().enumerate() {
                self.current_frame().bindings.insert(
                    p.name.clone(),
                    Binding {
                        ty: param_tys.get(i).cloned().unwrap_or(Type::Unresolved),
                        mutable: false,
                        decl_span: Some(p.span), class_name: None, decl_type_name: None },
                );
            }
        }
        let actual_ret = self.check_block(body, Some(&ret_expected));
        self.suspend_context_stack.pop();
        self.pop_frame();
        let return_type = if matches!(ret_expected, Type::Unresolved) {
            actual_ret
        } else {
            ret_expected
        };
        let params_out = if effective_empty {
            if expected_arity == Some(0) {
                vec![]
            } else {
                vec![param_tys.into_iter().next().unwrap_or(Type::Unresolved)]
            }
        } else {
            params
                .iter()
                .enumerate()
                .map(|(i, _)| param_tys.get(i).cloned().unwrap_or(Type::Unresolved))
                .collect::<Vec<_>>()
        };
        Type::Function {
            params: params_out,
            return_type: Box::new(return_type),
            is_suspend,
        }
    }

    // ---- smart casts -----------------------------------------------------
    //
    // Smart-cast narrowings now live in the CFG. The lowering emits
    // AssumeIs / AssumeNull / AssumeRefEq nodes, the smart-cast
    // analysis transfers them, and `cfg_narrowed_at` /
    // `cfg_narrowed_class_at` answer queries at expression spans.
    // The legacy `check_condition` / `collect_narrowings` walkers
    // and the CondNarrow struct are gone with the Frame fields.

    // ---- assignability + diagnostics ------------------------------------

    pub(crate) fn check_assignable(&mut self, src: &Type, dst: &Type, span: Span) {
        if matches!(src, Type::Unresolved) || matches!(dst, Type::Unresolved) {
            return;
        }
        if src.is_subtype_of(dst) {
            return;
        }
        // GADT-style refinement: when the dst carries a type
        // parameter that the CFG knows has been refined to a
        // concrete type at this branch (via an `is`-narrowing on a
        // declared `Super<T>` receiver), substitute and retry.
        let gadt = self.cfg_gadt_subst_at(span);
        if !gadt.is_empty() {
            let dst_refined = substitute_type_params(dst, &gadt);
            if src.is_subtype_of(&dst_refined) {
                return;
            }
        }
        self.diagnostics.emit(
            Diagnostic::error(
                format!("Type mismatch: inferred type is `{src}` but `{dst}` was expected"),
                span,
            )
            .with_code(codes::TYPE_MISMATCH),
        );
    }
}
