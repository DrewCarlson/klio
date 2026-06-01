use super::*;

impl<'r> Checker<'r> {
    // ---- statements & blocks --------------------------------------------

    pub(crate) fn check_block(&mut self, block: &Block, expected: Option<&Type>) -> Type {
        self.push_frame();
        let mut last = Type::Unit;
        let mut warned = false;
        for (i, s) in block.stmts.iter().enumerate() {
            let is_last = i + 1 == block.stmts.len();
            // Spec §12.1.5: W0002 unreachable code fires when the
            // CFG's reachability analysis classifies the block
            // containing this statement as dead. The typed
            // reachability variant picks up Nothing-returning
            // expressions in earlier statements (return / throw /
            // error("...") / TODO()).
            let cfg_dead = self
                .cfg_is_unreachable_at(stmt_span(s))
                .unwrap_or(false);
            if cfg_dead && !warned {
                self.diagnostics.emit(
                    Diagnostic::warning("Unreachable code".to_string(), stmt_span(s))
                        .with_code(codes::WARN_UNREACHABLE_CODE)
                        .with_factory(
                            &klio_diagnostics::generated::factories::UNREACHABLE_CODE,
                        ),
                );
                warned = true;
            }
            last = self.check_stmt(s, if is_last { expected } else { None });
        }
        self.pop_frame();
        last
    }

    pub(crate) fn check_stmt(&mut self, stmt: &Stmt, expected: Option<&Type>) -> Type {
        match stmt {
            Stmt::Expr(e) => self.check_expr(e, expected),
            Stmt::Decl(d) => {
                self.check_local_decl(d);
                Type::Unit
            }
            Stmt::Assign { target, op, value, span } => {
                self.check_assign(target, *op, value, *span);
                Type::Unit
            }
            Stmt::DestructuringDecl { names, init, mutable, .. } => {
                let _ = self.check_expr(init, None);
                // Spec ch.9: each non-`_` slot dispatches `componentN`.
                let init_cls = self.expr_class.get(&init.span()).cloned();
                for (idx, n) in names.iter().enumerate() {
                    if n.name == "_" {
                        continue;
                    }
                    let comp = format!("component{}", idx + 1);
                    self.check_user_operator_keyword(init_cls.as_deref(), &comp, n.span);
                    self.current_frame().bindings.insert(
                        n.name.clone(),
                        Binding {
                            ty: Type::Unresolved,
                            mutable: *mutable,
                            decl_span: Some(n.span), class_name: None, decl_type_name: None },
                    );
                }
                Type::Unit
            }
        }
    }

    pub(crate) fn check_local_decl(&mut self, decl: &Decl) {
        match decl {
            Decl::Property(p) => {
                let annot = p.ty.as_ref().map(convert_type_ref_lossy);
                let init_ty = if let Some(init) = &p.init {
                    self.check_expr(init, annot.as_ref())
                } else if let Some(d) = &p.delegate {
                    self.check_expr(d, None);
                    Type::Unresolved
                } else {
                    Type::Unresolved
                };
                let declared = annot.clone().unwrap_or_else(|| init_ty.clone());
                if let (Some(a), Some(init)) = (annot, p.init.as_ref()) {
                    self.check_assignable(&init_ty, &a, init.span());
                }
                let mut cn = p.ty.as_ref().and_then(class_name_from_typeref);
                if cn.is_none() {
                    if let Some(init) = &p.init {
                        cn = self.expr_class.get(&init.span()).cloned();
                    }
                }
                self.current_frame().bindings.insert(
                    p.name.name.clone(),
                    Binding {
                        ty: declared,
                        mutable: p.mutable,
                        decl_span: Some(p.name.span),
                        class_name: cn,
                        
                        decl_type_name: p
                            .ty
                            .as_ref()
                            .filter(|t| klio_types::builtin_by_name(&t.name.name).is_none())
                            .map(|t| t.name.name.clone()),
                    },
                );
                // Spec §14.1.5: tie `val b = a` to its source for bound
                // smart-cast propagation. Only immutable locals participate
                // (mutable bindings can be reassigned, breaking the alias).
                if !p.mutable {
                    if let Some(init) = &p.init {
                        if let Some(src) = single_path_name(init) {
                            // Require the source to be an immutable binding
                            // in some scope. Otherwise the alias may not
                            // hold (the source can be reassigned).
                            let src_is_stable = self
                                .lookup(&src)
                                .map(|b| !b.mutable)
                                .unwrap_or(false);
                            // Bound smart-cast aliasing lives in the
                            // CFG lowering's `aliases` map; consulted
                            // by cfg_narrowed_at when chasing chains.
                            let _ = src_is_stable;
                        }
                    }
                }
            }
            Decl::Function(f) => {
                let sig = self.signature_of(f);
                let fn_ty = Type::Function {
                    params: sig.params.clone(),
                    return_type: Box::new(sig.return_ty.clone()),
                    is_suspend: f.is_suspend,
                };
                self.current_frame().bindings.insert(
                    f.name.name.clone(),
                    Binding { ty: fn_ty, mutable: false, decl_span: Some(f.name.span), class_name: None, decl_type_name: None },
                );
                let nm = f.name.name.clone();
                self.push_fn_sig(&nm, sig, f.is_expect || f.is_actual);
                self.check_function(f);
            }
            Decl::Class(c) => {
                let mut info = self.class_info(c);
                info.is_local_or_anonymous = true;
                self.classes.insert(c.name.name.clone(), info);
                self.check_class(c);
            }
            Decl::Object(o) => {
                let mut info = ClassInfo::default();
                info.is_object = true;
                info.is_local_or_anonymous = true;
                info.decl_file = Some(o.name.span.file);
                self.collect_members(&o.members, &mut info);
                self.classes.insert(o.name.name.clone(), info);
                self.check_object(o);
            }
            Decl::TypeAlias(_) => {}
        }
    }

    pub(crate) fn check_assign(&mut self, target: &Expr, op: AssignOp, value: &Expr, span: Span) {
        // Spec §7.1.2: for a compound assignment, both the `*Assign` form
        // and the `*` binary form may resolve. When both apply on the LHS
        // receiver class, the call is ambiguous.
        if !matches!(op, AssignOp::Assign) {
            self.check_compound_assign_ambiguity(target, op, span);
        }
        // Reassignment-of-val check for the simple identifier case.
        if let Expr::Path { segments, span } = target {
            if segments.len() == 1 {
                let name = &segments[0].name;
                // Spec §4.6: per-accessor visibility on `var x; private set`.
                // Reject the write when use site is outside the setter's
                // declared scope.
                if let Some((sv, decl_file)) = self.setter_visibility.get(name).copied() {
                    if matches!(sv, Visibility::Private) && span.file != decl_file {
                        self.diagnostics.emit(
                            Diagnostic::error(
                                format!(
                                    "Cannot assign to `{name}`: setter is `private` in its \
                                     declaring file"
                                ),
                                *span,
                            )
                            .with_code(codes::TYPE_INVISIBLE_REFERENCE),
                        );
                    }
                }
                let info = self
                    .lookup(name)
                    .map(|b| (b.ty.clone(), b.mutable));
                if let Some((want, mutable)) = info {
                    // `val x: T` followed by `x = …` later in scope:
                    // CFG VIA reports `x` as Unassigned at the
                    // assignment span, marking this as the binding's
                    // first (and only legal) write. CFG fact `None`
                    // (no DeclLocal upstream) means the binding is
                    // already in scope as a parameter or top-level
                    // — never a first write.
                    let is_first_write = matches!(
                        self.cfg_via_unassigned_at(name, *span),
                        Some(true)
                    );
                    // §7.1.2: a compound assignment to a `val` is permitted
                    // when the LHS type carries a matching `*Assign` operator
                    // (the operator-function path mutates in place, never
                    // rebinds the name). Plain `=` reassignment still errors.
                    let compound_with_assign = !matches!(op, AssignOp::Assign)
                        && type_has_compound_assign(&want, op);
                    if !mutable && !is_first_write && !compound_with_assign {
                        self.diagnostics.emit(
                            Diagnostic::error(
                                format!("Val cannot be reassigned: `{name}`"),
                                *span,
                            )
                            .with_code(codes::TYPE_VAL_REASSIGN),
                        );
                    }
                    let got = self.check_expr(value, Some(&want));
                    self.check_assignable(&got, &want, value.span());
                    // killDataFlow lives in the CFG: Node::KillDataFlow
                    // at every loop head invalidates narrowings on
                    // reassigned places.
                    return;
                }
            }
        }
        let _ = self.check_expr(target, None);
        let _ = self.check_expr(value, None);
    }

    // ---- expression typing ----------------------------------------------

    pub(crate) fn check_expr(&mut self, expr: &Expr, expected: Option<&Type>) -> Type {
        let ty = self.compute_expr_ty(expr, expected);
        self.types.insert(expr.span(), ty.clone());
        ty
    }

    #[allow(clippy::too_many_lines)]
    pub(crate) fn compute_expr_ty(&mut self, expr: &Expr, expected: Option<&Type>) -> Type {
        match expr {
            Expr::IntLit { kind, .. } => {
                // Suffix-typed literals pin their type unconditionally:
                // `1L` is Long, `1u` is UInt, `1uL` is ULong. An
                // unsuffixed integer literal coerces to any narrow
                // integer / Long / unsigned variant when an expected
                // type drives the call site.
                match kind {
                    klio_ast::IntLitKind::Long => return Type::Long,
                    klio_ast::IntLitKind::UInt => return Type::UInt,
                    klio_ast::IntLitKind::ULong => return Type::ULong,
                    klio_ast::IntLitKind::Int => {}
                }
                if let Some(t) = expected {
                    if matches!(
                        t.non_null(),
                        Type::Long
                            | Type::Short
                            | Type::Byte
                            | Type::Int
                            | Type::UInt
                            | Type::ULong
                            | Type::UShort
                            | Type::UByte
                    ) {
                        return t.non_null().clone();
                    }
                }
                Type::Int
            }
            Expr::FloatLit { kind, .. } => {
                if matches!(kind, klio_ast::FloatLitKind::Float) {
                    return Type::Float;
                }
                if let Some(t) = expected {
                    if matches!(t.non_null(), Type::Float | Type::Double) {
                        return t.non_null().clone();
                    }
                }
                Type::Double
            }
            Expr::BoolLit { .. } => Type::Boolean,
            Expr::CharLit { .. } => Type::Char,
            Expr::NullLit { .. } => Type::Nullable(Box::new(Type::Nothing)),
            Expr::StringTemplate { parts, .. } => {
                for part in parts {
                    if let StringPart::Interp(e) = part {
                        self.check_expr(e, None);
                    }
                }
                Type::String
            }
            Expr::Path { segments, span } => {
                if segments.len() == 1 {
                    let name = &segments[0].name;
                    self.enforce_dsl_scope_for_member(name, *span);
                    if let Some(cn) = self.cfg_narrowed_class_at(name, *span) {
                        self.expr_class.insert(*span, cn);
                    }
                    if let Some(narrowed) = self.lookup_narrowed_at(name, *span) {
                        return narrowed;
                    }
                    if let Some(b) = self.lookup(name) {
                        let cn = b.class_name.clone();
                        let ty = b.ty.clone();
                        if let Some((v, f)) = self.prop_visibility.get(name).copied() {
                            self.check_top_level_visibility(name, v, f, *span);
                            let anns = self.prop_annotations.get(name).cloned().unwrap_or_default();
                            self.check_published_api_use(name, v, &anns, *span);
                        }
                        // Definite-assignment check: the CFG's VIA
                        // analysis is authoritative. It returns
                        // None when the place isn't tracked
                        // (parameter, top-level property), Some(true)
                        // when declared without an initializer and
                        // no subsequent Assign reaches this read,
                        // Some(false) when assigned along every
                        // path. T0020 fires only on Some(true).
                        if matches!(self.cfg_via_unassigned_at(name, *span), Some(true)) {
                            self.diagnostics.emit(
                                Diagnostic::error(
                                    format!(
                                        "Variable '{name}' must be initialized"
                                    ),
                                    *span,
                                )
                                .with_code(codes::TYPE_VAR_NOT_DEFINITELY_ASSIGNED),
                            );
                        }
                        if let Some(cn) = cn {
                            self.expr_class.insert(*span, cn);
                        }
                        // GADT static refinement: when this read
                        // lies inside a branch whose smart-cast
                        // narrows a generic receiver, fold the
                        // implied type-parameter substitution into
                        // the declared type. Outside any branch
                        // the substitution is empty and `ty` is
                        // returned unchanged.
                        let gadt = self.cfg_gadt_subst_at(*span);
                        if gadt.is_empty() {
                            return ty;
                        }
                        return substitute_type_params(&ty, &gadt);
                    }
                    if let Some(sigs) = self.fns.get(name) {
                        // Function reference (not a call) — pick the first
                        // declared overload to materialize a function type.
                        if let Some(sig) = sigs.first().cloned() {
                            return Type::Function {
                                params: sig.params,
                                return_type: Box::new(sig.return_ty),
                                is_suspend: sig.is_suspend,
                            };
                        }
                    }
                    if self.classes.contains_key(name) {
                        self.expr_class.insert(*span, name.clone());
                        return Type::Unresolved;
                    }
                    // Resolved by name resolver but not in our tables (e.g.
                    // stdlib). Silently stay tolerant.
                    let _ = span;
                    return Type::Unresolved;
                }
                Type::Unresolved
            }
            Expr::Member { receiver, name, safe, span } => {
                if let Some(key) = dot_path_key(expr) {
                    if let Some(cn) = self.cfg_narrowed_class_at(&key, *span) {
                        self.expr_class.insert(*span, cn);
                    }
                    if let Some(narrowed) = self.lookup_narrowed_at(&key, *span) {
                        let _ = self.check_expr(receiver, None);
                        return narrowed;
                    }
                }
                // §17.5.9: `this@Outer.b` is rejected when a closer DSL
                // receiver sharing a marker with `Outer` is also in scope
                // and itself exposes a member named `b`.
                if let Expr::This { qualifier: Some(q), .. } = receiver.as_ref() {
                    self.enforce_dsl_scope_for_qualified_this(&q.name, &name.name, name.span);
                }
                let recv_ty = self.check_expr(receiver, None);
                let recv_class = self.expr_class.get(&receiver.span()).cloned();
                self.check_member_access(
                    &recv_ty,
                    name.name.as_str(),
                    *safe,
                    receiver.span(),
                    recv_class.as_deref(),
                    *span,
                )
            }
            Expr::Call { callee, args, arg_names, type_args, span, is_infix, .. } => {
                if let Expr::Path { segments, .. } = callee.as_ref() {
                    if segments.len() == 1 {
                        let name = &segments[0].name;
                        if self.classes.contains_key(name) {
                            self.expr_class.insert(*span, name.clone());
                        }
                    }
                }
                // Spec §11.2.2: `super.f(...)` with no `<Qualifier>` must
                // resolve to a member from exactly one direct supertype.
                // Two or more contributing supertypes require the caller
                // to disambiguate via `super<Type>.f(...)`.
                if let Expr::Member { receiver, name, .. } = callee.as_ref() {
                    if let Expr::Super { qualifier, span: super_span, .. } =
                        receiver.as_ref()
                    {
                        match qualifier {
                            None => {
                                self.check_ambiguous_super(name.name.as_str(), *super_span);
                            }
                            Some(q) => {
                                self.check_super_qualifier(q, *super_span);
                            }
                        }
                    }
                }
                // Spec §4.2: implicit lambda label — bind the call's
                // callee simple name as a label visible inside any lambda
                // argument so `xs.forEach { return@forEach }` checks.
                let implicit_label = match callee.as_ref() {
                    Expr::Path { segments, .. } => segments.last().map(|s| s.name.clone()),
                    Expr::Member { name, .. } => Some(name.name.clone()),
                    _ => None,
                };
                if let Some(l) = &implicit_label {
                    self.label_stack.push(l.clone());
                }
                let result = self.check_call(callee, args, arg_names, type_args, *span);
                if implicit_label.is_some() {
                    self.label_stack.pop();
                }
                if *is_infix {
                    self.check_infix_modifier(callee, args, *span);
                }
                result
            }
            Expr::Index { receiver, args, span } => {
                let _ = self.check_expr(receiver, None);
                for a in args {
                    self.check_expr(a, None);
                }
                // Spec ch.9: `xs[i]` dispatches `operator fun get`.
                let cls = self.expr_class.get(&receiver.span()).cloned();
                self.check_user_operator_keyword(cls.as_deref(), "get", *span);
                Type::Unresolved
            }
            Expr::Binary { op, lhs, rhs, span } => self.check_binary(*op, lhs, rhs, *span),
            Expr::Unary { op, expr, span } => {
                let t = self.check_expr(expr, None);
                let cls = self.expr_class.get(&expr.span()).cloned();
                let op_name: Option<&str> = match op {
                    UnOp::Pos => Some("unaryPlus"),
                    UnOp::Neg => Some("unaryMinus"),
                    UnOp::Not => Some("not"),
                    UnOp::PreInc => Some("inc"),
                    UnOp::PreDec => Some("dec"),
                };
                if let Some(name) = op_name {
                    self.check_user_operator_keyword(cls.as_deref(), name, *span);
                }
                match op {
                    UnOp::Neg | UnOp::Pos => {
                        if is_numeric(&t) {
                            t
                        } else if matches!(t, Type::Unresolved) {
                            Type::Unresolved
                        } else {
                            Type::Unresolved
                        }
                    }
                    UnOp::Not => Type::Boolean,
                    UnOp::PreInc | UnOp::PreDec => t,
                }
            }
            Expr::Postfix { op, expr, span } => {
                let t = self.check_expr(expr, None);
                let cls = self.expr_class.get(&expr.span()).cloned();
                let op_name: Option<&str> = match op {
                    PostfixOp::Inc => Some("inc"),
                    PostfixOp::Dec => Some("dec"),
                    PostfixOp::NotNull => None,
                };
                if let Some(name) = op_name {
                    self.check_user_operator_keyword(cls.as_deref(), name, *span);
                }
                match op {
                    PostfixOp::Inc | PostfixOp::Dec => t,
                    PostfixOp::NotNull => {
                        // `expr!!` narrowing is handled by the CFG:
                        // the lowering emits AssumeNull(eq_null=false)
                        // followed by Assert, and the smart-cast
                        // analysis picks up the non-null fact.
                        match t {
                            Type::Nullable(inner) => *inner,
                            other => other,
                        }
                    }
                }
            }
            Expr::If { cond, then_branch, else_branch, .. } => {
                let _ = self.check_expr(cond, Some(&Type::Boolean));
                self.push_frame();
                // All branch narrowings and definite-assignment
                // joins flow through the CFG: each arm contributes
                // an Assume on the right branch and the smart-cast
                // / VIA analyses join at the if's join block.
                let then_ty = self.check_expr(then_branch, expected);
                self.pop_frame();
                let else_ty = if let Some(e) = else_branch {
                    self.push_frame();
                    let t = self.check_expr(e, expected);
                    self.pop_frame();
                    t
                } else {
                    Type::Unit
                };
                lub(&then_ty, &else_ty)
            }
            Expr::While { cond, body, .. } => {
                self.check_expr(cond, Some(&Type::Boolean));
                // Spec §14.1.4 propagation of body smart-cast facts
                // to the surrounding scope flows through the CFG.
                self.check_expr(body, None);
                Type::Unit
            }
            Expr::DoWhile { body, cond, .. } => {
                if let Some(b) = body {
                    self.check_expr(b, None);
                }
                self.check_expr(cond, Some(&Type::Boolean));
                Type::Unit
            }
            Expr::For { vars, iter, body, span, .. } => {
                let _ = self.check_expr(iter, None);
                // Spec ch.9: `for (x in c)` dispatches `iterator()` on `c`,
                // then `hasNext()` / `next()` on the iterator. We only know
                // the iterable's class here; the inner iterator class isn't
                // tracked, so the check is best-effort on `iterator`.
                let cls = self.expr_class.get(&iter.span()).cloned();
                self.check_user_operator_keyword(cls.as_deref(), "iterator", *span);
                self.push_frame();
                for v in vars {
                    self.current_frame().bindings.insert(
                        v.name.clone(),
                        Binding { ty: Type::Unresolved, mutable: false, decl_span: Some(v.span), class_name: None, decl_type_name: None },
                    );
                }
                self.check_expr(body, None);
                self.pop_frame();
                Type::Unit
            }
            Expr::Return { value, label, span } => {
                if let Some(v) = value {
                    let expected = self.fn_return_stack.last().cloned();
                    let _ = self.check_expr(v, expected.as_ref());
                }
                if let Some(l) = label {
                    if !self.label_stack.iter().any(|x| x == &l.name) {
                        self.diagnostics.emit(
                            Diagnostic::error(
                                format!("label `{}` is not bound here", l.name),
                                *span,
                            )
                            .with_code(codes::TYPE_UNRESOLVED_LABEL),
                        );
                    }
                }
                Type::Nothing
            }
            Expr::Break { label, span } | Expr::Continue { label, span } => {
                if let Some(l) = label {
                    if !self.label_stack.iter().any(|x| x == &l.name) {
                        self.diagnostics.emit(
                            Diagnostic::error(
                                format!("label `{}` is not bound here", l.name),
                                *span,
                            )
                            .with_code(codes::TYPE_UNRESOLVED_LABEL),
                        );
                    }
                }
                Type::Nothing
            }
            Expr::Labeled { label, expr, .. } => {
                if !is_labelable_target(expr) {
                    self.diagnostics.emit(
                        Diagnostic::error(
                            format!(
                                "Label `{}@` can only be attached to a lambda literal, a loop, or a call with a trailing lambda",
                                label.name
                            ),
                            label.span,
                        )
                        .with_code(codes::TYPE_LABEL_TARGET_NOT_LABELABLE),
                    );
                }
                self.label_stack.push(label.name.clone());
                let ty = self.check_expr(expr, expected);
                self.label_stack.pop();
                ty
            }
            Expr::Block(b) => self.check_block(b, expected),
            Expr::Throw { value, span } => {
                let vty = self.check_expr(value, None);
                if !self.type_is_throwable_subtype(&vty) {
                    self.diagnostics.emit(
                        Diagnostic::error(
                            format!(
                                "`throw` requires a value whose type is a subtype of `kotlin.Throwable`, but got `{vty}`."
                            ),
                            *span,
                        )
                        .with_code(codes::TYPE_THROW_NON_THROWABLE),
                    );
                }
                // Spec §16.2: the throw operand must be a value of a
                // runtime-available type. When the operand is a bare local
                // whose declared type names a non-reified type parameter,
                // the static type is erased at runtime and the throw is
                // unsafe.
                if let Expr::Path { segments, .. } = value.as_ref() {
                    if segments.len() == 1 {
                        let name = &segments[0].name;
                        let decl_ty_name = self
                            .frames
                            .iter()
                            .rev()
                            .find_map(|f| f.bindings.get(name))
                            .and_then(|b| b.decl_type_name.clone());
                        if let Some(tname) = decl_ty_name {
                            let is_type_param = self
                                .type_params_in_scope
                                .iter()
                                .any(|s| s.contains(&tname));
                            let is_reified = self
                                .reified_type_params
                                .iter()
                                .any(|s| s.contains(&tname));
                            if is_type_param && !is_reified {
                                self.diagnostics.emit(
                                    Diagnostic::error(
                                        format!(
                                            "Cannot throw a value of erased type parameter `{tname}` — the type must be runtime-available. Mark `{tname}` as `reified` on an `inline fun` or throw a concrete exception type."
                                        ),
                                        *span,
                                    )
                                    .with_code(codes::TYPE_RUNTIME_UNAVAILABLE_CATCH_TYPE),
                                );
                            }
                        }
                    }
                }
                Type::Nothing
            }
            Expr::Try { body, catches, finally, .. } => {
                let body_ty = self.check_block(body, expected);
                let mut acc = body_ty;
                for c in catches {
                    // Spec §15.1: exception types in `catch` must be
                    // runtime-available. A non-reified type parameter is
                    // erased at runtime, and a generic exception type with
                    // non-star arguments has erased arguments — neither
                    // can be matched by the JVM/native dispatch.
                    {
                        let tname = &c.ty.name.name;
                        let is_type_param = self
                            .type_params_in_scope
                            .iter()
                            .any(|s| s.contains(tname));
                        let is_reified = self
                            .reified_type_params
                            .iter()
                            .any(|s| s.contains(tname));
                        if is_type_param && !is_reified {
                            self.diagnostics.emit(
                                Diagnostic::error(
                                    format!(
                                        "Cannot catch by an erased type parameter `{tname}` — exception types must be runtime-available. Mark it as `reified` on an `inline fun` or use a concrete exception type."
                                    ),
                                    c.ty.span,
                                )
                                .with_code(codes::TYPE_RUNTIME_UNAVAILABLE_CATCH_TYPE),
                            );
                        }
                        if c.ty.type_args.iter().any(|a| !a.is_star) {
                            self.diagnostics.emit(
                                Diagnostic::error(
                                    format!(
                                        "Cannot catch by a generic exception type `{tname}<…>` with concrete type arguments — the arguments are erased at runtime. Use the raw form or star projections."
                                    ),
                                    c.ty.span,
                                )
                                .with_code(codes::TYPE_RUNTIME_UNAVAILABLE_CATCH_TYPE),
                            );
                        }
                    }
                    self.push_frame();
                    self.current_frame().bindings.insert(
                        c.binding.name.clone(),
                        Binding {
                            ty: convert_type_ref_lossy(&c.ty),
                            mutable: false,
                            decl_span: Some(c.binding.span), class_name: None, decl_type_name: None },
                    );
                    let cty = self.check_block(&c.body, expected);
                    self.pop_frame();
                    acc = lub(&acc, &cty);
                }
                // Spec §12.1.1 finally(1): evaluated after body+catch
                // along the normal continuation. If finally diverges
                // (return / throw inside), the try expression itself
                // diverges — the body's normal-exit path is suppressed.
                if let Some(fb) = finally {
                    let fty = self.check_block(fb, None);
                    if matches!(fty, Type::Nothing) {
                        acc = Type::Nothing;
                    }
                }
                acc
            }
            Expr::Lambda { params, body, .. } => self.check_lambda(params, body, expected),
            Expr::This { qualifier, span } => {
                let target = qualifier
                    .as_ref()
                    .map(|q| q.name.clone())
                    .or_else(|| self.class_stack.last().cloned());
                if let Some(cn) = target {
                    self.expr_class.insert(*span, cn);
                }
                Type::Unresolved
            }
            Expr::Super { .. } => Type::Unresolved,
            Expr::PropertyRef { .. } => Type::Unresolved,
            Expr::MemberRef { receiver, name, .. } => {
                // Class-literal LHS validation per spec §15 / §15.1: only
                // non-nullable runtime-available types may appear on the
                // LHS of `::class`. Type parameters are permitted only
                // when `reified`.
                if name.name == "class" {
                    if let Expr::Path { segments, .. } = receiver.as_ref() {
                        if segments.len() == 1 {
                            let tname = &segments[0].name;
                            let is_type_param = self
                                .type_params_in_scope
                                .iter()
                                .any(|s| s.contains(tname));
                            if is_type_param {
                                let is_reified = self
                                    .reified_type_params
                                    .iter()
                                    .any(|s| s.contains(tname));
                                if !is_reified {
                                    self.diagnostics.emit(
                                        Diagnostic::error(
                                            format!(
                                                "`{tname}::class` is not allowed — type parameter is erased at runtime. Mark it as `reified` on an `inline fun` to make the class literal available."
                                            ),
                                            receiver.span(),
                                        )
                                        .with_code(codes::TYPE_NON_REIFIED_CLASS_LITERAL),
                                    );
                                }
                                // Skip the receiver pass — Path[T] would
                                // otherwise emit a misleading
                                // UNRESOLVED_REFERENCE.
                                return Type::Unresolved;
                            }
                        }
                    }
                    let rty = self.check_expr(receiver, None);
                    if matches!(rty, Type::Nullable(_)) {
                        self.diagnostics.emit(
                            Diagnostic::error(
                                "LHS of `::class` cannot have a nullable type — class literals require a non-nullable runtime type.".to_string(),
                                receiver.span(),
                            )
                            .with_code(codes::TYPE_NULLABLE_CLASS_LITERAL_LHS),
                        );
                    }
                    return Type::Unresolved;
                }
                self.check_expr(receiver, None);
                Type::Unresolved
            }
            Expr::When { subject, subject_binding, branches, span } => {
                let subj_class = if let Some(s) = subject {
                    self.check_expr(s, None);
                    self.expr_class.get(&s.span()).cloned()
                } else {
                    None
                };
                // `when (val v = subject)` — register `v` as an immutable
                // local for the branch bodies.
                let pushed_binding = if let Some(b) = subject_binding {
                    self.push_frame();
                    let ty = if let Some(t) = &b.ty {
                        convert_type_ref_lossy(t)
                    } else {
                        subject.as_ref().and_then(|s| {
                            self.types.get(&s.span()).cloned()
                        }).unwrap_or(Type::Unresolved)
                    };
                    let class_name = subject
                        .as_ref()
                        .and_then(|s| self.expr_class.get(&s.span()).cloned());
                    self.frames.last_mut().unwrap().bindings.insert(
                        b.name.name.clone(),
                        Binding {
                            ty,
                            mutable: false,
                            decl_span: Some(b.name.span),
                            class_name,
                            
                            decl_type_name: None,
                        },
                    );
                    true
                } else {
                    false
                };
                let mut has_else = false;
                let mut acc: Option<Type> = None;
                // Spec §14.1: the subject of a `when` is a smart-cast sink for
                // each branch when an `is` pattern matches. Resolve the sink
                // key — the `val v = ...` binding name if present, otherwise
                // the subject expression's dot path if it has one.
                let subject_key: Option<String> = subject_binding
                    .as_ref()
                    .map(|b| b.name.name.clone())
                    .or_else(|| subject.as_ref().and_then(|s| dot_path_key(s)));
                for b in branches {
                    for p in &b.patterns {
                        match &p.kind {
                            WhenPatternKind::Value(e)
                            | WhenPatternKind::InRange(e)
                            | WhenPatternKind::NotInRange(e) => {
                                self.check_expr(e, None);
                            }
                            _ => {}
                        }
                    }
                    if b.patterns.iter().any(|p| matches!(p.kind, WhenPatternKind::Else)) {
                        has_else = true;
                    }
                    // Narrow the subject inside this branch if it's a single
                    // `is T` pattern. Multiple patterns or any `!is` / value
                    // patterns mean the branch body cannot rely on a single
                    // refinement, so we skip narrowing in those cases.
                    // `when` arm narrowings come from the CFG: each
                    // arm's body is preceded by AssumeIs / AssumeNull
                    // emitted by `lower_when_pattern`, so smart-cast
                    // queries inside the arm see the refined types
                    // without an extra frame push.
                    let _ = &subject_key;
                    let t = self.check_expr(&b.body, expected);
                    acc = Some(match acc {
                        None => t,
                        Some(a) => lub(&a, &t),
                    });
                }
                let _ = has_else;
                if let Some(cn) = subj_class {
                    self.check_when_exhaustive(&cn, branches, *span);
                }
                if pushed_binding {
                    self.pop_frame();
                }
                acc.unwrap_or(Type::Unit)
            }
            Expr::IsCheck { expr, ty, negated, span } => {
                let lhs_ty = self.check_expr(expr, None);
                // Spec §8.11.1 note: `null is T?` is always `true`; `null is
                // T` (non-nullable) is always `false`. Surface the
                // observation by recording the folded value into the
                // checker types map so downstream reachability passes can
                // pick it up. The literal `null` case fires the strongest
                // narrowing; we also handle the symmetric null-typed value
                // (Nothing? or a `val n: T? = null` after smart-cast).
                let lhs_is_null = matches!(expr.as_ref(), Expr::NullLit { .. })
                    || matches!(&lhs_ty, Type::Nullable(inner) if matches!(**inner, Type::Nothing));
                if lhs_is_null {
                    let always = if ty.nullable { !*negated } else { *negated };
                    let label = if always { "true" } else { "false" };
                    self.diagnostics.emit(
                        Diagnostic::warning(
                            format!(
                                "`{}` is always `{}` — `null` {} `{}` per spec §8.11.1",
                                if *negated { "!is" } else { "is" },
                                label,
                                if always { "is" } else { "is not" },
                                ty.name.name
                            ),
                            *span,
                        )
                        .with_code(codes::TYPE_UNCHECKED_CAST),
                    );
                }
                let target_name = &ty.name.name;
                let is_type_param = self
                    .type_params_in_scope
                    .iter()
                    .any(|s| s.contains(target_name));
                let is_reified = self
                    .reified_type_params
                    .iter()
                    .any(|s| s.contains(target_name));
                if is_type_param && !is_reified {
                    let op = if *negated { "!is" } else { "is" };
                    self.diagnostics.emit(
                        Diagnostic::error(
                            format!(
                                "Cannot check for an instance of an erased type parameter `{target_name}`. Mark it as `reified` on an `inline fun` to allow `{op}`."
                            ),
                            ty.span,
                        )
                        .with_code(codes::TYPE_CANNOT_CHECK_FOR_ERASED_TYPE_PARAMETER),
                    );
                }
                Type::Boolean
            }
            Expr::As { expr, ty, safe, span } => {
                let subj_ty = self.check_expr(expr, None);
                let target_ty = convert_type_ref_lossy(ty);
                if !matches!(subj_ty, Type::Unresolved)
                    && !matches!(target_ty, Type::Unresolved)
                    && subj_ty.is_subtype_of(&target_ty)
                {
                    self.diagnostics.emit(
                        Diagnostic::warning(
                            format!("No cast needed: `{}` is already `{}`", subj_ty, target_ty),
                            *span,
                        )
                        .with_code(codes::WARN_USELESS_CAST)
                        .with_factory(&klio_diagnostics::generated::factories::USELESS_CAST),
                    );
                }
                if ty.type_args.iter().any(|a| !a.is_star) {
                    self.diagnostics.emit(
                        Diagnostic::warning(
                            format!("Unchecked cast: target type `{}` has erased type arguments", ty.name.name),
                            ty.span,
                        )
                        .with_code(codes::TYPE_UNCHECKED_CAST),
                    );
                }
                // Spec §15.1 / §8.16: a cast to a non-reified type parameter
                // T cannot be checked at runtime. For `as?` the safe-cast can
                // never observe a failure (always succeeds when the value is
                // non-null), so we surface the dedicated T0083; for unsafe
                // `as` the cast is also unchecked — fold it under T0028.
                {
                    let target_name = &ty.name.name;
                    let is_type_param = self
                        .type_params_in_scope
                        .iter()
                        .any(|s| s.contains(target_name));
                    let is_reified = self
                        .reified_type_params
                        .iter()
                        .any(|s| s.contains(target_name));
                    if is_type_param && !is_reified {
                        if *safe {
                            self.diagnostics.emit(
                                Diagnostic::warning(
                                    format!(
                                        "Safe cast `as? {target_name}` cannot be checked at runtime — type parameter is not `reified`"
                                    ),
                                    ty.span,
                                )
                                .with_code(codes::TYPE_CAST_TO_NON_REIFIED_TYPE_PARAMETER),
                            );
                        } else {
                            self.diagnostics.emit(
                                Diagnostic::warning(
                                    format!(
                                        "Unchecked cast: target type parameter `{target_name}` is not `reified` and is erased at runtime"
                                    ),
                                    ty.span,
                                )
                                .with_code(codes::TYPE_UNCHECKED_CAST),
                            );
                        }
                    }
                }
                let target = convert_type_ref_lossy(ty);
                if let Some(cn) = class_name_from_typeref(ty) {
                    self.expr_class.insert(*span, cn);
                }
                // `expr as T` narrowing is handled by the CFG via the
                // AssumeIs node the lowering emits for the cast.
                let _ = ();
                if *safe {
                    target.as_nullable()
                } else {
                    target
                }
            }
            Expr::AnonFun { params, return_ty, body, is_suspend, .. } => {
                self.push_frame();
                for p in params {
                    let pty = convert_type_ref_lossy(&p.ty);
                    self.current_frame().bindings.insert(
                        p.name.name.clone(),
                        Binding {
                            ty: pty,
                            mutable: false,
                            decl_span: Some(p.span),
                            class_name: None,
                            
                            decl_type_name: if klio_types::builtin_by_name(&p.ty.name.name).is_none() {
                                Some(p.ty.name.name.clone())
                            } else {
                                None
                            },
                        },
                    );
                }
                let ret_expected = return_ty
                    .as_ref()
                    .map(convert_type_ref_lossy)
                    .unwrap_or(Type::Unresolved);
                if let Some(b) = body.as_deref() {
                    match b {
                        FunctionBody::Block(blk) => {
                            self.check_block(blk, Some(&ret_expected));
                        }
                        FunctionBody::Expr(e) => {
                            self.check_expr(e, Some(&ret_expected));
                        }
                    }
                }
                self.pop_frame();
                let params_out = params
                    .iter()
                    .map(|p| convert_type_ref_lossy(&p.ty))
                    .collect::<Vec<_>>();
                let r = if matches!(ret_expected, Type::Unresolved) {
                    Type::Unit
                } else {
                    ret_expected
                };
                Type::Function {
                    params: params_out,
                    return_type: Box::new(r),
                    is_suspend: *is_suspend,
                }
            }
            Expr::Spread { expr, .. } => {
                // A bare `*expr` outside a call-arg position is invalid;
                // the call-arg site handles legal use. Recurse so any
                // sub-expression diagnostics still surface.
                self.check_expr(expr, None);
                Type::Unresolved
            }
            Expr::ObjectExpr { supertypes, supertype_args, supertype_delegates, members, .. } => {
                // Spec §5.1.2: anonymous object inheriting from a sealed type
                // is rejected — sealed inheritors require a fully-qualified
                // name. Same code path also catches inherit-from-object /
                // inherit-from-final-class for anonymous objects.
                for s in supertypes {
                    let pname = &s.name.name;
                    let Some(parent) = self.classes.get(pname) else { continue };
                    if parent.is_sealed {
                        self.diagnostics.emit(
                            Diagnostic::error(
                                format!(
                                    "anonymous object cannot inherit from sealed type `{pname}`: \
                                     sealed inheritors must have a fully-qualified name"
                                ),
                                s.span,
                            )
                            .with_code(codes::TYPE_SEALED_INHERITOR_NOT_QUALIFIED),
                        );
                    }
                    if parent.is_object {
                        self.diagnostics.emit(
                            Diagnostic::error(
                                format!(
                                    "anonymous object cannot inherit from object `{pname}`: \
                                     object types cannot be inherited from"
                                ),
                                s.span,
                            )
                            .with_code(codes::TYPE_INHERIT_FROM_OBJECT),
                        );
                        continue;
                    }
                    if !parent.is_interface
                        && !parent.is_open
                        && !parent.is_abstract
                        && !parent.is_sealed
                    {
                        self.diagnostics.emit(
                            Diagnostic::error(
                                format!(
                                    "anonymous object cannot inherit from final class `{pname}`: \
                                     declare it `open`, `abstract`, or `sealed`"
                                ),
                                s.span,
                            )
                            .with_code(codes::TYPE_INHERIT_FROM_FINAL_CLASS),
                        );
                    }
                }
                for d in supertype_delegates.iter().flatten() {
                    self.check_expr(d, None);
                }
                for args in supertype_args.iter().flatten() {
                    for a in args {
                        self.check_expr(a, None);
                    }
                }
                for m in members {
                    match m {
                        Decl::Function(f) => self.check_function(f),
                        Decl::Property(p) => {
                            if let Some(init) = &p.init {
                                self.check_expr(init, None);
                            }
                            self.handle_accessors(p);
                        }
                        _ => {}
                    }
                }
                Type::Unresolved
            }
        }
    }

    pub(crate) fn check_member_access(
        &mut self,
        recv_ty: &Type,
        name: &str,
        safe: bool,
        recv_span: Span,
        recv_class: Option<&str>,
        member_span: Span,
    ) -> Type {
        // Null-safety: dereferencing a known nullable without `?.` or `!!`.
        if !safe && matches!(recv_ty, Type::Nullable(_)) {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!(
                        "Only safe (?.) or non-null asserted (!!.) calls are allowed on a nullable receiver of type `{recv_ty}`"
                    ),
                    recv_span,
                )
                .with_code(codes::TYPE_NULL_SAFETY),
            );
        }
        // Spec §11.3.2: a receiver whose static type is `Nothing` (or
        // `Nothing?`) is never applicable for member callables. Skip the
        // class-chain walk entirely so only extensions can resolve here.
        let recv_is_nothing = matches!(recv_ty, Type::Nothing)
            || matches!(recv_ty, Type::Nullable(inner) if matches!(**inner, Type::Nothing));
        let mut result = Type::Unresolved;
        let mut found_as_member = false;
        if let Some(class) = recv_class.filter(|_| !recv_is_nothing) {
            if let Some((ty, cn)) = self.lookup_member_through_chain(class, name) {
                result = ty;
                found_as_member = true;
                if let Some(cn) = cn {
                    self.expr_class.insert(member_span, cn);
                }
            }
            self.check_member_visibility(class, name, Some(class), member_span);
        }
        if !found_as_member {
            if let Some(ep) = self.lookup_extension_property(recv_ty, recv_class, name) {
                result = ep.ty.clone();
                if let Some(cn) = ep.return_class.clone() {
                    self.expr_class.insert(member_span, cn);
                }
            }
        }
        if safe {
            result.as_nullable()
        } else {
            result
        }
    }

    pub(crate) fn lookup_extension_property(
        &self,
        recv_ty: &Type,
        recv_class: Option<&str>,
        name: &str,
    ) -> Option<ExtensionPropSig> {
        let mut keys: Vec<String> = Vec::new();
        if let Some(c) = recv_class {
            keys.push(c.to_string());
            let mut seen: HashSet<String> = HashSet::new();
            seen.insert(c.to_string());
            let mut frontier: Vec<String> = vec![c.to_string()];
            let mut steps = 0;
            while let Some(cn) = frontier.pop() {
                if steps > 64 { break; }
                steps += 1;
                let Some(info) = self.classes.get(&cn) else { continue };
                for s in &info.supertypes {
                    if seen.insert(s.clone()) {
                        keys.push(s.clone());
                        frontier.push(s.clone());
                    }
                }
            }
        }
        let head: Option<String> = match recv_ty.non_null() {
            Type::Int => Some("Int".into()),
            Type::Long => Some("Long".into()),
            Type::Double => Some("Double".into()),
            Type::Float => Some("Float".into()),
            Type::Boolean => Some("Boolean".into()),
            Type::String => Some("String".into()),
            Type::Char => Some("Char".into()),
            Type::Byte => Some("Byte".into()),
            Type::Short => Some("Short".into()),
            Type::Generic { name, .. } => Some(name.clone()),
            _ => None,
        };
        if let Some(h) = head {
            if !keys.iter().any(|k| k == &h) {
                keys.push(h);
            }
        }
        keys.push("Any".to_string());
        for key in &keys {
            let Some(list) = self.extension_properties.get(key) else { continue };
            for ep in list {
                if ep.name == name {
                    return Some(ep.clone());
                }
            }
        }
        None
    }

    /// Walk a receiver class's supertype chain plus `Any` looking for a
    /// matching extension by name + arity. Returns the chosen signature
    /// and the declared return user-class name if known.
    pub(crate) fn lookup_extension(
        &self,
        recv_class: &str,
        name: &str,
        args: &[Expr],
    ) -> Option<(FnSig, Option<String>)> {
        let mut keys: Vec<String> = Vec::new();
        keys.push(recv_class.to_string());
        let mut seen: HashSet<String> = HashSet::new();
        seen.insert(recv_class.to_string());
        let mut frontier: Vec<String> = vec![recv_class.to_string()];
        let mut steps = 0;
        while let Some(c) = frontier.pop() {
            if steps > 64 {
                break;
            }
            steps += 1;
            let Some(info) = self.classes.get(&c) else { continue };
            for s in &info.supertypes {
                if seen.insert(s.clone()) {
                    keys.push(s.clone());
                    frontier.push(s.clone());
                }
            }
        }
        keys.push("Any".to_string());
        for key in &keys {
            let Some(list) = self.extensions.get(key) else { continue };
            for ext in list {
                if ext.name != name {
                    continue;
                }
                let min = ext.sig.has_default.iter().filter(|h| !**h).count();
                let max = ext.sig.params.len();
                if args.len() < min || args.len() > max {
                    continue;
                }
                return Some((ext.sig.clone(), ext.return_class.clone()));
            }
        }
        None
    }
}
