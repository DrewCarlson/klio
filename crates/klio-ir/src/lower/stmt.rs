use super::{
    BinOp, Const, Expr, FuncBuilder, Inst, Reg, Stmt, Terminator, boxed_cell_reg,
    collect_path_idents_stmt, expr_span, lower_expr, lower_expr_as_param_thunk,
    lower_lambda_body_capturing_kind_with, lower_receiver, resolve_capture, widen_numeric_literal,
};

pub(crate) fn lower_stmt(b: &mut FuncBuilder<'_>, stmt: &Stmt) -> Option<Reg> {
    match stmt {
        Stmt::Expr(e) => Some(lower_expr(b, e)),
        Stmt::Decl(klio_ast::Decl::Property(p)) => lower_property_decl(b, p),
        Stmt::Decl(klio_ast::Decl::Function(f)) => lower_local_fn_decl(b, f),
        Stmt::Assign {
            target, op, value, ..
        } if matches!(target, Expr::Index { receiver, .. } if matches!(receiver.as_ref(), Expr::Member { safe: true, .. })) => {
            lower_safe_index_assign(b, target, *op, value)
        }
        Stmt::Assign {
            target, op, value, ..
        } if matches!(target, Expr::Member { safe: true, .. }) => {
            lower_safe_member_assign(b, target, *op, value)
        }
        Stmt::Assign {
            target, op, value, ..
        } => lower_assign(b, target, *op, value),
        Stmt::Decl(klio_ast::Decl::Class(c)) => lower_local_class_decl(b, c),
        Stmt::DestructuringDecl { names, init, .. } => lower_destructuring_decl(b, names, init),
        Stmt::Decl(_) => None,
    }
}

fn lower_property_decl(b: &mut FuncBuilder<'_>, p: &klio_ast::Property) -> Option<Reg> {
    // `val x = expr` / `var x = expr`. The init is lowered
    // into a fresh register and bound in the current scope;
    // mutability is enforced by typeck, not the IR.
    let init = if let Some(de) = &p.delegate {
        // `val x by D` — lower the delegate, then invoke its
        // `getValue(null, ::x)` once at decl time. For a
        // `lazy { producer }` this drives the producer; for
        // any custom delegate the dispatched method runs.
        // Each subsequent path read of `x` returns the bound
        // value, so this is eager-once semantics (sufficient
        // for `val`-style use; a `var x by D` mutating
        // delegate would need a true read-through dispatch
        // and is tracked separately).
        let delegate = lower_expr(b, de);
        let null_arg = b.emit_const(Const::Null);
        let prop_ref = b.alloc_reg();
        let pname = b.module.intern_const(Const::String(p.name.name.clone()));
        b.push(Inst::PropertyRef {
            dst: prop_ref,
            name: pname,
        });
        let args_start = b.alloc_reg();
        b.push(Inst::Move {
            dst: args_start,
            src: null_arg,
        });
        let _slot2 = b.alloc_reg();
        b.push(Inst::Move {
            dst: Reg(args_start.0 + 1),
            src: prop_ref,
        });
        let dst = b.alloc_reg();
        let name_c = b.module.intern_const(Const::String("getValue".to_string()));
        b.push(Inst::CallMember {
            dst,
            receiver: delegate,
            name: name_c,
            args: args_start,
            n_args: 2,
            arg_names: Vec::new(),
        });
        dst
    } else {
        match &p.init {
            Some(e) => {
                let widened = p.ty.as_ref().and_then(|ty| widen_numeric_literal(e, ty));
                // A type-annotated initializer puts its declared type in
                // tail position so a reified inline call (`val u: User =
                // resp.body()`) can infer its type argument.
                let prev = b.push_expected(p.ty.clone());
                let r = lower_expr(b, widened.as_ref().unwrap_or(e));
                b.restore_expected(prev);
                r
            }
            None => b.emit_const(Const::Unit),
        }
    };
    // Allocate a "home" register and Move the init value
    // into it for `var`, or for `val` declared without an
    // initializer (deferred init — multiple branches assign
    // before the first read). This gives reads through the
    // home reg slot semantics under the flat block IR.
    // For a `val foo = expr` the binding is fixed at decl
    // time and can skip the slot.
    // Track `: Any` annotations so subsequent `==` against
    // this var routes through the boxed-equality path.
    if let Some(ty) = &p.ty
        && ty.name.name == "Any"
    {
        b.mark_any_typed(&p.name.name);
    }
    if b.is_boxed(&p.name.name) {
        // Captured `var` — box into a shared cell so writes
        // from a nested closure / coroutine are visible
        // here (Kotlin `Ref` semantics).
        let home = b.alloc_reg();
        b.push(Inst::MakeCell {
            dst: home,
            src: init,
        });
        b.set_mutable_home(&p.name.name, home);
        b.mark_mutable(&p.name.name);
        b.bind(p.name.name.clone(), home);
    } else if p.mutable || p.init.is_none() {
        let home = b.alloc_reg();
        b.push(Inst::Move {
            dst: home,
            src: init,
        });
        b.set_mutable_home(&p.name.name, home);
        if p.mutable {
            b.mark_mutable(&p.name.name);
        }
        b.bind(p.name.name.clone(), home);
    } else {
        b.bind(p.name.name.clone(), init);
    }
    None
}

fn lower_local_fn_decl(b: &mut FuncBuilder<'_>, f: &klio_ast::Function) -> Option<Reg> {
    // Local fn: lower as a closure whose body captures the
    // enclosing scope's visible names. Bound to its
    // declared name so subsequent calls resolve to the
    // closure Value. Equivalent to `val name = { ... }`.
    // Both block-body (`fun foo() { ... }`) and
    // expression-body (`fun foo() = expr`) forms map to a
    // synthetic Block carrying the expression as its only
    // statement.
    use klio_span::{FileId, Span};
    let dummy_span = Span::new(FileId(0), 0, 0);
    let body_block: Option<klio_ast::Block> = match f.body.as_ref() {
        Some(klio_ast::FunctionBody::Block(b)) => Some(b.clone()),
        Some(klio_ast::FunctionBody::Expr(e)) => Some(klio_ast::Block {
            stmts: vec![Stmt::Expr(e.clone())],
            span: dummy_span,
        }),
        None => None,
    };
    if let Some(body) = body_block {
        let self_cell = local_fn_self_cell(b, f, &body);
        let outer_names: std::collections::HashSet<String> = b.visible_names();
        let inherited_rlp = b.receiver_lambda_param_names();
        let outer_boxed = b.boxed_vars_snapshot();
        // A local *extension* function (`fun List<T>.mid() =
        // …`) binds its receiver as the implicit first `this`
        // param, so the body's bare member refs (`sorted()`,
        // `size`) resolve. Call sites prepend the receiver.
        let is_ext = f.receiver_type.is_some();
        let mut param_idents: Vec<klio_ast::Ident> =
            f.params.iter().map(|p| p.name.clone()).collect();
        if is_ext {
            param_idents.insert(
                0,
                klio_ast::Ident {
                    name: "this".to_string(),
                    span: dummy_span,
                },
            );
        }
        let tailrec_self = if f.is_tailrec {
            Some(f.name.name.as_str())
        } else {
            None
        };
        let (body_func, captured_names) = lower_lambda_body_capturing_kind_with(
            b.module,
            &param_idents,
            &body,
            outer_names,
            true,
            &outer_boxed,
            tailrec_self,
            true,
            inherited_rlp,
        );
        let captures: Vec<Reg> = captured_names
            .iter()
            .map(|n| resolve_capture(b, n))
            .collect();
        let mut param_names: Vec<String> = f.params.iter().map(|p| p.name.name.clone()).collect();
        if is_ext {
            param_names.insert(0, "this".to_string());
        }
        register_local_fn_defaults(b, f, is_ext, &param_names, body_func);
        let dst = b.alloc_reg();
        b.push(Inst::AstLambda {
            dst,
            params: param_names,
            body_ast: body,
            captures,
            captured_names,
            absorb_return: true,
            body_func: Some(body_func),
        });
        if let Some(home) = self_cell {
            b.push(Inst::CellSet {
                cell: home,
                value: dst,
            });
        } else {
            b.bind(f.name.name.clone(), dst);
        }
        b.mark_local_fn(&f.name.name);
        if is_ext {
            b.mark_local_ext_fn(&f.name.name);
        }
    }
    None
}

// A local function that calls itself is desugared like
// `var name = null; name = { … name(…) … }`: a shared cell is created
// first so the body can capture it and the closure stores itself into
// it once built. This is the same boxed-self-reference path a recursive
// `lateinit var f = { … f(…) … }` already uses. A cell pre-hoisted by
// `lower_block` (so sibling local fns can capture each other) is reused.
fn local_fn_self_cell(
    b: &mut FuncBuilder<'_>,
    f: &klio_ast::Function,
    body: &klio_ast::Block,
) -> Option<Reg> {
    let mut self_refs = std::collections::HashSet::new();
    for s in &body.stmts {
        collect_path_idents_stmt(s, &mut self_refs);
    }
    if let Some(home) = b.mutable_home(&f.name.name) {
        Some(home)
    } else if self_refs.contains(&f.name.name) {
        let null_v = b.emit_const(Const::Null);
        let home = b.alloc_reg();
        b.push(Inst::MakeCell {
            dst: home,
            src: null_v,
        });
        b.set_mutable_home(&f.name.name, home);
        b.mark_mutable(&f.name.name);
        b.mark_boxed(&f.name.name);
        b.bind(f.name.name.clone(), home);
        Some(home)
    } else {
        None
    }
}

// Per-param defaults: lower each default expression as a thunk binding
// the lowered param prefix (so `b = a + 1` can read an earlier param)
// and register it under the body FuncId. The Vm pads missing trailing
// args from these the same way it does for top-level functions.
fn register_local_fn_defaults(
    b: &mut FuncBuilder<'_>,
    f: &klio_ast::Function,
    is_ext: bool,
    param_names: &[String],
    body_func: crate::FuncId,
) {
    if f.params.iter().any(|p| p.default.is_some()) {
        let offset = usize::from(is_ext);
        let name_refs: Vec<&str> = param_names.iter().map(String::as_str).collect();
        let mut slots: Vec<Option<crate::FuncId>> = Vec::with_capacity(param_names.len());
        for _ in 0..offset {
            slots.push(None);
        }
        for (idx, p) in f.params.iter().enumerate() {
            if let Some(default_expr) = &p.default {
                let bind_upto = (offset + idx).min(name_refs.len());
                let widened = widen_numeric_literal(default_expr, &p.ty);
                let fid = lower_expr_as_param_thunk(
                    b.module,
                    &name_refs[..bind_upto],
                    widened.as_ref().unwrap_or(default_expr),
                    &format!("__default_local_{}_{}", f.name.name, p.name.name),
                );
                slots.push(Some(fid));
            } else {
                slots.push(None);
            }
        }
        b.module.registry.local_fn_defaults.insert(body_func, slots);
    }
}

fn lower_safe_index_assign(
    b: &mut FuncBuilder<'_>,
    target: &Expr,
    op: klio_ast::AssignOp,
    value: &Expr,
) -> Option<Reg> {
    // `obj?.items[i] = v` — null-guard the outer Index
    // assignment when the receiver chain is a safe-Member.
    let Expr::Index {
        receiver,
        args: idx_args,
        span,
    } = target
    else {
        unreachable!()
    };
    let Expr::Member {
        receiver: outer,
        name: mname,
        span: mspan,
        ..
    } = receiver.as_ref()
    else {
        unreachable!()
    };
    let outer_r = lower_expr(b, outer);
    let null_r = b.emit_const(Const::Null);
    let is_null = b.alloc_reg();
    b.push(Inst::BinOp {
        dst: is_null,
        op: BinOp::Eq,
        lhs: outer_r,
        rhs: null_r,
    });
    let skip = b.alloc_block();
    let do_set = b.alloc_block();
    let join = b.alloc_block();
    b.terminate(Terminator::Branch {
        cond: is_null,
        t: skip,
        f: do_set,
    });
    b.switch_to(do_set);
    // Synthesize the non-safe equivalent and recurse.
    let inner_recv = Expr::Member {
        receiver: outer.clone(),
        name: mname.clone(),
        safe: false,
        span: *mspan,
    };
    let inner_target = Expr::Index {
        receiver: Box::new(inner_recv),
        args: idx_args.clone(),
        span: *span,
    };
    let synth = Stmt::Assign {
        target: inner_target,
        op,
        value: value.clone(),
        span: *span,
    };
    lower_stmt(b, &synth);
    b.terminate(Terminator::Goto(join));
    b.switch_to(skip);
    b.terminate(Terminator::Goto(join));
    b.switch_to(join);
    None
}

fn lower_safe_member_assign(
    b: &mut FuncBuilder<'_>,
    target: &Expr,
    op: klio_ast::AssignOp,
    value: &Expr,
) -> Option<Reg> {
    // `obj?.field = v` (or compound `?.field += v`):
    //   if obj is null → skip the assignment entirely.
    //   otherwise → fall through to the regular non-safe
    //              assign path with the safe flag cleared.
    let Expr::Member {
        receiver,
        name,
        span,
        ..
    } = target
    else {
        unreachable!()
    };
    let recv_r = lower_expr(b, receiver);
    let null_r = b.emit_const(Const::Null);
    let is_null = b.alloc_reg();
    b.push(Inst::BinOp {
        dst: is_null,
        op: BinOp::Eq,
        lhs: recv_r,
        rhs: null_r,
    });
    let skip = b.alloc_block();
    let do_set = b.alloc_block();
    let join = b.alloc_block();
    b.terminate(Terminator::Branch {
        cond: is_null,
        t: skip,
        f: do_set,
    });
    b.switch_to(do_set);
    // Synthesize an equivalent non-safe assign and recurse
    // through Stmt::Assign so compound semantics, setters,
    // and class property setters reuse the existing path.
    let inner_target = Expr::Member {
        receiver: receiver.clone(),
        name: name.clone(),
        safe: false,
        span: *span,
    };
    let synth = Stmt::Assign {
        target: inner_target,
        op,
        value: value.clone(),
        span: *span,
    };
    lower_stmt(b, &synth);
    b.terminate(Terminator::Goto(join));
    b.switch_to(skip);
    b.terminate(Terminator::Goto(join));
    b.switch_to(join);
    None
}

fn lower_assign(
    b: &mut FuncBuilder<'_>,
    target: &Expr,
    op: klio_ast::AssignOp,
    value: &Expr,
) -> Option<Reg> {
    let v = lower_expr(b, value);
    // Compound assigns first try `<op>Assign` as a member
    // call on the target — covers user types declaring
    // `operator fun plusAssign(...)` and built-in mutable
    // collections (MutableList += elem). When the call
    // raises (no method, immutable target), fall through
    // to the rebind path below. Today this fires only
    // when the target is a Path-bound local — Member /
    // Index targets need their own routing.
    // Only attempt `plusAssign`-style member dispatch when the
    // target is NOT a mutable local Path. For a `var` local the
    // primitive rebind path below is what Kotlin actually does
    // (Int has no plusAssign). For a `val` Path the value's type
    // declares plusAssign (operator on a class, or built-in
    // collection mutation), so CallMember is correct.
    // The plusAssign / minusAssign-style member dispatch only
    // fires for a Path target naming a `val` LOCAL (e.g.
    // `val h = Histogram(); h += w` or `val xs = mutableListOf<Int>(); xs += 1`).
    // A Path target whose name doesn't resolve locally is a
    // top-level binding; route it through the BinOp +
    // StoreGlobal path below so top-level `var` compound
    // assigns + delegated-property setters fire.
    // A boxed var or a captured outer binding is an
    // assignable variable, not a `val` whose value type
    // declares an `<op>Assign` operator. Excluding both
    // keeps a second compound-assign (after the first
    // rebinds the name to a plain reg) on the rebind path
    // instead of mis-dispatching `plusAssign` on the Int.
    let path_is_val = matches!(
        target,
        Expr::Path { segments, .. }
            if segments.len() == 1
                && !b.is_mutable(&segments[0].name)
                && !b.is_boxed(&segments[0].name)
                && !b.knows_outer(&segments[0].name)
                && b.resolve(&segments[0].name).is_some()
    );
    if !matches!(op, klio_ast::AssignOp::Assign) && path_is_val {
        let method_name = match op {
            klio_ast::AssignOp::Add => "plusAssign",
            klio_ast::AssignOp::Sub => "minusAssign",
            klio_ast::AssignOp::Mul => "timesAssign",
            klio_ast::AssignOp::Div => "divAssign",
            klio_ast::AssignOp::Rem => "remAssign",
            klio_ast::AssignOp::Assign => unreachable!(),
        };
        let recv = lower_expr(b, target);
        let args_start = b.alloc_reg();
        b.push(Inst::Move {
            dst: args_start,
            src: v,
        });
        let dst = b.alloc_reg();
        let nm = b.module.intern_const(Const::String(method_name.into()));
        b.push(Inst::CallMember {
            dst,
            receiver: recv,
            name: nm,
            args: args_start,
            n_args: 1,
            arg_names: Vec::new(),
        });
        return None;
    }
    let combined = match op {
        klio_ast::AssignOp::Assign => v,
        klio_ast::AssignOp::Add
        | klio_ast::AssignOp::Sub
        | klio_ast::AssignOp::Mul
        | klio_ast::AssignOp::Div
        | klio_ast::AssignOp::Rem => {
            let cur = lower_expr(b, target);
            let bin = match op {
                klio_ast::AssignOp::Add => BinOp::Add,
                klio_ast::AssignOp::Sub => BinOp::Sub,
                klio_ast::AssignOp::Mul => BinOp::Mul,
                klio_ast::AssignOp::Div => BinOp::Div,
                klio_ast::AssignOp::Rem => BinOp::Mod,
                klio_ast::AssignOp::Assign => unreachable!(),
            };
            let dst = b.alloc_reg();
            b.push(Inst::BinOp {
                dst,
                op: bin,
                lhs: cur,
                rhs: v,
            });
            dst
        }
    };
    store_combined_to_target(b, target, combined);
    None
}

// Route the already-combined value to the assignment target: a single
// Path name (local / cell / capture / member / global), a Member field,
// or an Index `set` call.
// Index-key arity is small, so the `set`-call arg count narrows to u8.
// The two `knows_outer` branches are a deliberate write-back chain.
#[allow(
    clippy::cast_possible_truncation,
    clippy::same_functions_in_if_condition
)]
fn store_combined_to_target(b: &mut FuncBuilder<'_>, target: &Expr, combined: Reg) {
    match target {
        Expr::Path { segments, .. } if segments.len() == 1 => {
            if b.is_boxed(&segments[0].name) {
                let cell = boxed_cell_reg(b, &segments[0].name);
                b.push(Inst::CellSet {
                    cell,
                    value: combined,
                });
            } else if let Some(home) = b.mutable_home(&segments[0].name) {
                b.push(Inst::Move {
                    dst: home,
                    src: combined,
                });
            } else if b.knows_outer(&segments[0].name) {
                // Lambda body writing back to an outer-frame
                // capture: emit StoreGlobal (which lands in
                // the closure's scoped env) so the enclosing
                // call site's `WritebackCaptures` syncs the
                // value to the caller. Also rebind locally
                // so subsequent reads inside the same body
                // see the new value.
                let _ = b.record_capture(&segments[0].name);
                let n = b
                    .module
                    .intern_const(Const::String(segments[0].name.clone()));
                b.push(Inst::StoreGlobal {
                    name: n,
                    value: combined,
                });
                b.rebind(&segments[0].name, combined);
            } else if b.resolve(&segments[0].name).is_some() {
                b.rebind(&segments[0].name, combined);
            } else if b.has_own_member(&segments[0].name) && b.resolve("this").is_some() {
                // Method-body `this.field` write — route
                // SetField on the receiver so the bare-
                // name assign reaches the instance, not
                // a synthetic global.
                let this_reg = b.resolve("this").unwrap();
                let field = b
                    .module
                    .intern_const(Const::String(segments[0].name.clone()));
                b.push(Inst::SetField {
                    receiver: this_reg,
                    field,
                    value: combined,
                });
            } else if b.knows_outer(&segments[0].name) {
                // Assign target is an outer-scope name
                // captured by this lambda. Record it as a
                // capture so the host's `build_ast_lambda`
                // pre-defines it in the env, then store
                // back via StoreGlobal which the tree
                // walker's eval_stmt routes through the
                // env chain. The enclosing call site's
                // `WritebackCaptures` syncs the value
                // back to the caller's reg.
                let _ = b.record_capture(&segments[0].name);
                let n = b
                    .module
                    .intern_const(Const::String(segments[0].name.clone()));
                b.push(Inst::StoreGlobal {
                    name: n,
                    value: combined,
                });
            } else if b.is_lambda_body() {
                // Unqualified write inside a lambda body whose
                // name is not a local/param/captured-outer/
                // own-member. By Kotlin scoping it is either a
                // property of the lambda's bound receiver
                // (`Sink.(Int) -> Unit` doing `sum = 99`) or a
                // genuine top-level binding. Decide at runtime,
                // symmetric to the read side's
                // LoadFromThisOrGlobal: capture `this` on
                // demand so a receiver-binding invoke populates
                // the slot, then StoreToThisOrGlobal sets the
                // receiver's member when present, else globals.
                let this_idx = b.record_capture("this");
                let name_c = b
                    .module
                    .intern_const(Const::String(segments[0].name.clone()));
                b.push(Inst::StoreToThisOrGlobal {
                    this_idx,
                    name: name_c,
                    value: combined,
                });
            } else {
                // Top-level binding: route through StoreGlobal so
                // the tree-walker setter / delegate fires.
                let n = b
                    .module
                    .intern_const(Const::String(segments[0].name.clone()));
                b.push(Inst::StoreGlobal {
                    name: n,
                    value: combined,
                });
            }
        }
        Expr::Member { receiver, name, .. } => {
            let recv = lower_receiver(b, receiver);
            let field = b.module.intern_const(Const::String(name.name.clone()));
            b.push(Inst::SetField {
                receiver: recv,
                field,
                value: combined,
            });
        }
        Expr::Index {
            receiver,
            args: idx_args,
            ..
        } => {
            // `m[k] = v` lowers to receiver.set(k, v) so
            // map / mutable-list assignment dispatches
            // through the same call_member path that
            // handles built-in collection mutation.
            let recv = lower_receiver(b, receiver);
            // Reserve a contiguous run of slots for keys +
            // value BEFORE lowering the key expressions,
            // since lowering each key may allocate auxiliary
            // registers (e.g. for Const literals) and we
            // need the run to stay tight so read_arg_run
            // picks up the value reg right after the keys.
            let n_keys = idx_args.len();
            let key_start = b.alloc_reg();
            let mut key_slots: Vec<Reg> = vec![key_start];
            for _ in 1..n_keys {
                key_slots.push(b.alloc_reg());
            }
            let val_slot = b.alloc_reg();
            for (slot, arg) in key_slots.iter().zip(idx_args.iter()) {
                let r = lower_expr(b, arg);
                b.push(Inst::Move { dst: *slot, src: r });
            }
            b.push(Inst::Move {
                dst: val_slot,
                src: combined,
            });
            let dst = b.alloc_reg();
            let nm = b.module.intern_const(Const::String("set".into()));
            b.push(Inst::CallMember {
                dst,
                receiver: recv,
                name: nm,
                args: key_start,
                n_args: (n_keys as u8) + 1,
                arg_names: Vec::new(),
            });
        }
        _ => {
            b.push(Inst::Trace {
                span: expr_span(target),
            });
        }
    }
}

fn lower_local_class_decl(b: &mut FuncBuilder<'_>, c: &klio_ast::Class) -> Option<Reg> {
    // Local class declaration inside a function body. Capture
    // the visible scope so the class methods can read names
    // from the enclosing fn (`val factor = 10; class Scaled { … n * factor … }`).
    let visible: std::collections::HashSet<String> = b.visible_names();
    let captured_names: Vec<String> = visible.iter().cloned().collect();
    let captures: Vec<Reg> = captured_names
        .iter()
        .map(|n| resolve_capture(b, n))
        .collect();
    b.push(Inst::RegisterClass {
        class: Box::new(c.clone()),
        captured_names,
        captures,
    });
    None
}

fn lower_destructuring_decl(
    b: &mut FuncBuilder<'_>,
    names: &[klio_ast::Ident],
    init: &Expr,
) -> Option<Reg> {
    // `val (a, b, ...) = expr` desugars to repeated
    // `expr.componentN()` calls. `_` placeholders skip the
    // call entirely. Tree walker handles this via
    // eval_stmt; the IR's CallMember + Host dispatch covers
    // the same surface, so we lower it inline.
    let recv = lower_expr(b, init);
    for (i, name) in names.iter().enumerate() {
        if name.name == "_" {
            continue;
        }
        let comp_name = format!("component{}", i + 1);
        let nm = b.module.intern_const(Const::String(comp_name));
        let args_start = b.alloc_reg();
        let dst = b.alloc_reg();
        b.push(Inst::CallMember {
            dst,
            receiver: recv,
            name: nm,
            args: args_start,
            n_args: 0,
            arg_names: Vec::new(),
        });
        b.bind(name.name.clone(), dst);
    }
    None
}
