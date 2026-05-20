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
            Stmt::Decl(klio_ast::Decl::Property(p)) => {
                p.init.as_ref().map(scan).unwrap_or(false)
            }
            _ => false,
        })
    }
    fn scan(e: &Expr) -> bool {
        match e {
            Expr::Return { .. } => true,
            Expr::Lambda { .. } | Expr::AnonFun { .. } | Expr::ObjectExpr { .. } => false,
            Expr::Member { receiver, .. }
            | Expr::Unary { expr: receiver, .. }
            | Expr::Postfix { expr: receiver, .. }
            | Expr::Spread { expr: receiver, .. }
            | Expr::Throw { value: receiver, .. }
            | Expr::Labeled { expr: receiver, .. }
            | Expr::As { expr: receiver, .. }
            | Expr::IsCheck { expr: receiver, .. }
            | Expr::MemberRef { receiver, .. } => scan(receiver),
            Expr::Call { callee, args, .. } => scan(callee) || args.iter().any(scan),
            Expr::Index { receiver, args, .. } => scan(receiver) || args.iter().any(scan),
            Expr::Binary { lhs, rhs, .. } => scan(lhs) || scan(rhs),
            Expr::If { cond, then_branch, else_branch, .. } => {
                scan(cond)
                    || scan(then_branch)
                    || else_branch.as_ref().map(|e| scan(e)).unwrap_or(false)
            }
            Expr::While { cond, body, .. } => scan(cond) || scan(body),
            Expr::DoWhile { body, cond, .. } => {
                body.as_ref().map(|b| scan(b)).unwrap_or(false) || scan(cond)
            }
            Expr::For { iter, body, .. } => scan(iter) || scan(body),
            Expr::Block(b) => scan_stmts(&b.stmts),
            Expr::When { subject, branches, .. } => {
                subject.as_ref().map(|s| scan(s)).unwrap_or(false)
                    || branches.iter().any(|br| scan(&br.body))
            }
            Expr::Try { body, catches, finally, .. } => {
                scan_stmts(&body.stmts)
                    || catches.iter().any(|c| scan_stmts(&c.body.stmts))
                    || finally
                        .as_ref()
                        .map(|fb| scan_stmts(&fb.stmts))
                        .unwrap_or(false)
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
pub(super) fn splice_inline_lambda(
    b: &mut FuncBuilder<'_>,
    lam: &Expr,
    arg_exprs: &[Expr],
) -> Reg {
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
    b.push(Inst::Move { dst: result, src: unit0 });
    let end = b.alloc_block();
    let label = b.current_inline_fn();
    if let Some(lbl) = &label {
        b.push_inline_lambda_ret(lbl.clone(), result, end);
    }
    let v = lower_block(b, body);
    b.push(Inst::Move { dst: result, src: v });
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
/// the caller.
pub(super) fn try_inline_call(
    b: &mut FuncBuilder<'_>,
    fname: &str,
    args: &[Expr],
    arg_names: &[Option<String>],
    this_arg: Option<&Expr>,
) -> Option<Reg> {
    let f = inline_fn_ast(fname)?;
    if b.inline_in_progress(fname) {
        return None;
    }
    let body = f.body.as_ref()?;
    let mut ordered: Vec<Option<Expr>> = vec![None; f.params.len()];
    let mut next_pos = 0usize;
    for (i, a) in args.iter().enumerate() {
        match arg_names.get(i).and_then(|n| n.clone()) {
            Some(nm) => {
                let idx = f.params.iter().position(|p| p.name.name == nm)?;
                ordered[idx] = Some(a.clone());
            }
            None => {
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
    let mut lambda_map: std::collections::HashMap<String, Expr> =
        std::collections::HashMap::new();
    for (p, a) in f.params.iter().zip(ordered.iter()) {
        let a = a.as_ref().expect("filled above");
        let r = lower_expr(b, a);
        b.bind(p.name.name.clone(), r);
        if matches!(a, Expr::Lambda { .. }) {
            lambda_map.insert(p.name.name.clone(), a.clone());
        }
    }
    b.push_inline_lambda_frame(lambda_map);
    if f.receiver_type.is_some() {
        if let Some(recv) = this_arg {
            let rr = lower_expr(b, recv);
            b.bind("this".to_string(), rr);
        }
    }
    let result = b.alloc_reg();
    let unit0 = b.emit_const(Const::Unit);
    b.push(Inst::Move { dst: result, src: unit0 });
    let join = b.alloc_block();
    b.push_inline_return(result, join);
    let body_val = match body {
        klio_ast::FunctionBody::Expr(e) => lower_expr(b, e),
        klio_ast::FunctionBody::Block(blk) => lower_block(b, blk),
    };
    b.push(Inst::Move { dst: result, src: body_val });
    b.terminate(Terminator::Goto(join));
    b.switch_to(join);
    b.pop_inline_return();
    b.pop_inline_lambda_frame();
    b.pop_scope();
    b.pop_inline_name();
    inline_expand_leave();
    Some(result)
}
