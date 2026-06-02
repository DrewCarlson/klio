use super::inline_state::{inline_expand_enter, inline_expand_leave, inline_fn_ast};
use super::{lower_block, lower_expr};
use crate::build::FuncBuilder;
use crate::{Const, Inst, Reg, Terminator};
use klio_ast::{Expr, Stmt};

/// Does any argument that is a lambda literal contain a non-local
/// `return` in its own body (not descending into nested lambdas /
/// local functions, whose returns are their own)?
pub(super) fn arg_lambda_has_nonlocal_return(args: &[Expr]) -> bool {
    fn scan_stmts(stmts: &[Stmt]) -> bool {
        stmts.iter().any(|s| match s {
            Stmt::Expr(e) => scan(e),
            Stmt::Assign { target, value, .. } => scan(target) || scan(value),
            Stmt::DestructuringDecl { init, .. } => scan(init),
            Stmt::Decl(klio_ast::Decl::Property(p)) => p.init.as_ref().is_some_and(scan),
            Stmt::Decl(_) => false,
        })
    }
    // The explicit Lambda/AnonFun/ObjectExpr arm documents that a
    // non-local return inside a nested scope is its own and must not
    // count here; keep it distinct from the catch-all default.
    #[allow(clippy::match_same_arms)]
    fn scan(e: &Expr) -> bool {
        match e {
            Expr::Return { .. } => true,
            Expr::Lambda { .. } | Expr::AnonFun { .. } | Expr::ObjectExpr { .. } => false,
            Expr::Member { receiver, .. }
            | Expr::Unary { expr: receiver, .. }
            | Expr::Postfix { expr: receiver, .. }
            | Expr::Spread { expr: receiver, .. }
            | Expr::Throw {
                value: receiver, ..
            }
            | Expr::Labeled { expr: receiver, .. }
            | Expr::As { expr: receiver, .. }
            | Expr::IsCheck { expr: receiver, .. }
            | Expr::MemberRef { receiver, .. } => scan(receiver),
            Expr::Call { callee, args, .. } => scan(callee) || args.iter().any(scan),
            Expr::Index { receiver, args, .. } => scan(receiver) || args.iter().any(scan),
            Expr::Binary { lhs, rhs, .. } => scan(lhs) || scan(rhs),
            Expr::If {
                cond,
                then_branch,
                else_branch,
                ..
            } => scan(cond) || scan(then_branch) || else_branch.as_ref().is_some_and(|e| scan(e)),
            Expr::While { cond, body, .. } => scan(cond) || scan(body),
            Expr::DoWhile { body, cond, .. } => {
                body.as_ref().is_some_and(|b| scan(b)) || scan(cond)
            }
            Expr::For { iter, body, .. } => scan(iter) || scan(body),
            Expr::Block(b) => scan_stmts(&b.stmts),
            Expr::When {
                subject, branches, ..
            } => {
                subject.as_ref().is_some_and(|s| scan(s))
                    || branches.iter().any(|br| scan(&br.body))
            }
            Expr::Try {
                body,
                catches,
                finally,
                ..
            } => {
                scan_stmts(&body.stmts)
                    || catches.iter().any(|c| scan_stmts(&c.body.stmts))
                    || finally.as_ref().is_some_and(|fb| scan_stmts(&fb.stmts))
            }
            _ => false,
        }
    }
    args.iter().any(|a| {
        if let Expr::Lambda { body, .. } = a {
            scan_stmts(&body.stmts)
        } else {
            false
        }
    })
}

/// Splice an `inline fun` argument lambda where the inlined body
/// invokes the corresponding lambda parameter.
pub(super) fn splice_inline_lambda(b: &mut FuncBuilder<'_>, lam: &Expr, arg_exprs: &[Expr]) -> Reg {
    let Expr::Lambda { params, body, .. } = lam else {
        return lower_expr(b, lam);
    };
    let arg_regs: Vec<Reg> = arg_exprs.iter().map(|a| lower_expr(b, a)).collect();
    let counted = inline_expand_enter();
    b.push_scope();
    if params.is_empty() {
        if let Some(r) = arg_regs.first() {
            b.bind("it".to_string(), *r);
        }
    } else {
        for (p, r) in params.iter().zip(arg_regs.iter()) {
            b.bind(p.name.clone(), *r);
        }
    }
    let owner_ret = b.inline_lambda_owner_return();
    b.push_inline_lambda_frame(std::collections::HashMap::new());
    let saved = b.take_inline_return();
    if let Some(o) = owner_ret {
        b.restore_inline_return(o);
    }
    let result = b.alloc_reg();
    let unit0 = b.emit_const(Const::Unit);
    b.push(Inst::Move {
        dst: result,
        src: unit0,
    });
    let end = b.alloc_block();
    let label = b.current_inline_fn();
    if let Some(lbl) = &label {
        b.push_inline_lambda_ret(lbl.clone(), result, end);
    }
    let v = lower_block(b, body);
    b.push(Inst::Move {
        dst: result,
        src: v,
    });
    b.terminate(Terminator::Goto(end));
    b.switch_to(end);
    if label.is_some() {
        b.pop_inline_lambda_ret();
    }
    b.restore_inline_return(saved);
    b.pop_inline_lambda_frame();
    b.pop_scope();
    if counted {
        inline_expand_leave();
    }
    result
}

/// Expand a call to a `suspend inline fun` by splicing its body into
/// the caller. `type_args` carries the call-site `<T = SomeType>` for
/// reified type parameters so the splice can bind each reified
/// parameter's name to the resolved class value before lowering the
/// body — `T::class` and `is T` reads inside the spliced body then
/// resolve to the call site's type.
pub(super) fn try_inline_call_with_type_args(
    b: &mut FuncBuilder<'_>,
    fname: &str,
    args: &[Expr],
    arg_names: &[Option<String>],
    this_arg: Option<&Expr>,
    type_args: &[klio_ast::TypeRef],
) -> Option<Reg> {
    let f = inline_fn_ast(fname)?;
    if b.inline_in_progress(fname) {
        return None;
    }
    let body = f.body.as_ref()?;
    let mut ordered: Vec<Option<Expr>> = vec![None; f.params.len()];
    let mut next_pos = 0usize;
    for (i, a) in args.iter().enumerate() {
        if let Some(nm) = arg_names.get(i).and_then(std::clone::Clone::clone) {
            let idx = f.params.iter().position(|p| p.name.name == nm)?;
            ordered[idx] = Some(a.clone());
        } else {
            while next_pos < ordered.len() && ordered[next_pos].is_some() {
                next_pos += 1;
            }
            if next_pos >= ordered.len() {
                return None;
            }
            ordered[next_pos] = Some(a.clone());
            next_pos += 1;
        }
    }
    for (i, slot) in ordered.iter_mut().enumerate() {
        if slot.is_none() {
            slot.clone_from(&f.params[i].default);
            if slot.is_none() {
                return None;
            }
        }
    }
    if !inline_expand_enter() {
        return None;
    }
    b.push_inline_name(fname.to_string());
    b.push_scope();
    let mut lambda_map: std::collections::HashMap<String, Expr> = std::collections::HashMap::new();
    for (p, a) in f.params.iter().zip(ordered.iter()) {
        let a = a.as_ref().expect("filled above");
        let r = lower_expr(b, a);
        b.bind(p.name.name.clone(), r);
        // `noinline` parameters opt out of the inline-lambda
        // splicing path. Their argument value still flows through
        // the binding above, but a call to that parameter inside
        // the inlined body lowers as a normal CallValue against
        // the reg instead of inlining the lambda literal. Without
        // this gate, every inline call would splice every lambda
        // argument's body — defeating `noinline`'s point of
        // letting the lambda be passed on or stored.
        //
        // `crossinline` keeps the inline-lambda path, but a bare
        // `return` in the lambda body is illegal: the inlined
        // body's return targets the enclosing inline fn's caller,
        // and `crossinline` promises that the lambda will not
        // perform such a non-local return. Klio doesn't currently
        // emit a parser-level diagnostic for the violation; the
        // runtime semantics still match Kotlin (the lambda's body
        // executes inside the inline call's scope and a `return`
        // would jump too far), but a future change should add the
        // typeck diagnostic.
        if !p.is_noinline && matches!(a, Expr::Lambda { .. }) {
            lambda_map.insert(p.name.name.clone(), a.clone());
        }
    }
    // Mark params whose declared type is one of this inline fn's own
    // generic type-parameters, so a comparison operator on such an
    // operand inside the spliced body lowers to `compareTo` (total
    // order for Double/Float) — matching the reference compiler. The
    // splice binds the body in the caller's builder, so record which
    // names we add and remove them once the body is lowered to avoid
    // leaking the mark onto a same-named caller local.
    let mut marked_generic: Vec<String> = Vec::new();
    if !f.type_params.is_empty() {
        let tp_names: std::collections::HashSet<&str> = f
            .type_params
            .iter()
            .map(|tp| tp.name.name.as_str())
            .collect();
        for p in &f.params {
            if p.ty.function.is_none()
                && !p.ty.nullable
                && tp_names.contains(p.ty.name.name.as_str())
                && !b.is_generic_typed_param(&p.name.name)
            {
                b.mark_generic_typed_param(&p.name.name);
                marked_generic.push(p.name.name.clone());
            }
        }
    }
    b.push_inline_lambda_frame(lambda_map);
    if f.receiver_type.is_some()
        && let Some(recv) = this_arg
    {
        let rr = lower_expr(b, recv);
        b.bind("this".to_string(), rr);
    }
    // Bind each reified type parameter to the resolved class value
    // at the call site. Two bindings are needed:
    //
    //   * Local: `T` resolves as a value (the spliced body's
    //     `T::class` read lowers as a bare `T` Path → MemberRef
    //     `.class`, the Path resolves through the local bind).
    //   * Global: `Inst::InstanceOf { ty: TypeRef "T" }` checks
    //     the value against the global named "T" (mirroring how
    //     `call_func_typed` binds runtime type-args). Without the
    //     global, `x is T` would test against a non-existent
    //     class `T` and silently fall through to `true`.
    //
    // The global isn't saved/restored — same shape klio uses for
    // type-arg binding in non-inline calls. A nested splice
    // overwrites it; a later restore happens implicitly when the
    // enclosing call returns.
    for (tp_idx, tp) in f.type_params.iter().enumerate() {
        if !tp.is_reified {
            continue;
        }
        let Some(arg) = type_args.get(tp_idx) else {
            continue;
        };
        let cls_reg = b.alloc_reg();
        let arg_name = b.module.intern_const(Const::String(arg.name.name.clone()));
        b.push(Inst::LoadGlobal {
            dst: cls_reg,
            name: arg_name,
        });
        b.bind(tp.name.name.clone(), cls_reg);
        let tp_global = b.module.intern_const(Const::String(tp.name.name.clone()));
        b.push(Inst::StoreGlobal {
            name: tp_global,
            value: cls_reg,
        });
    }
    let result = b.alloc_reg();
    let unit0 = b.emit_const(Const::Unit);
    b.push(Inst::Move {
        dst: result,
        src: unit0,
    });
    let join = b.alloc_block();
    b.push_inline_return(result, join);
    let body_val = match body {
        klio_ast::FunctionBody::Expr(e) => lower_expr(b, e),
        klio_ast::FunctionBody::Block(blk) => lower_block(b, blk),
    };
    b.push(Inst::Move {
        dst: result,
        src: body_val,
    });
    b.terminate(Terminator::Goto(join));
    b.switch_to(join);
    b.pop_inline_return();
    b.pop_inline_lambda_frame();
    b.pop_scope();
    b.pop_inline_name();
    inline_expand_leave();
    Some(result)
}
