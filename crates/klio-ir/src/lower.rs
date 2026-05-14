//! AST → IR lowering.
//!
//! Initial slice. Covers literals, binary / unary primitive
//! operations, paths (as parameter / local reads), if-expression,
//! and block expressions. The remaining expression forms
//! (lambda, when, try, for, anonymous-object, etc.) are tracked in
//! `plans/REFINEMENTS.md` and will be filled in incrementally —
//! every lowering addition should be paired with a snapshot test
//! against the produced IR.

use klio_ast::{BinOp as AstBinOp, Block as AstBlock, Expr, Stmt, UnOp as AstUnOp};

use crate::build::FuncBuilder;
use crate::{BinOp, Const, Inst, Reg, Terminator, UnOp};

/// Bind function parameters into the current scope. Each param is
/// loaded into a fresh register via `Inst::LoadParam` so subsequent
/// `Path { name }` reads route through the same register.
pub fn bind_params(b: &mut FuncBuilder<'_>, names: &[&str]) {
    for (i, name) in names.iter().enumerate() {
        let dst = b.alloc_reg();
        b.push(Inst::LoadParam { dst, idx: i as u16 });
        b.bind(*name, dst);
    }
}

/// Lower one AST function into an IR Func. The function body is
/// lowered into the entry block; parameters are bound via
/// `bind_params`; the trailing implicit return falls through to a
/// `Return` terminator.
pub fn lower_function(module: &mut crate::Module, f: &klio_ast::Function) -> crate::Func {
    let mut b = FuncBuilder::new(module);
    let names: Vec<&str> = f.params.iter().map(|p| p.name.name.as_str()).collect();
    bind_params(&mut b, &names);

    let result = match &f.body {
        Some(klio_ast::FunctionBody::Block(blk)) => Some(lower_block(&mut b, blk)),
        Some(klio_ast::FunctionBody::Expr(e)) => Some(lower_expr(&mut b, e)),
        None => None,
    };
    b.terminate(Terminator::Return(result));
    let fqn = f.name.name.clone();
    let mut func = b.finish(f.name.name.clone(), fqn, crate::TypeRef::unit());
    // Parameter metadata for downstream consumers; types are
    // unresolved at this stage.
    func.params = f
        .params
        .iter()
        .map(|p| crate::Param {
            name: p.name.name.clone(),
            ty: crate::TypeRef::unit(),
            default: None,
        })
        .collect();
    func.is_suspend = f.is_suspend;
    func
}

/// Lower one expression into the current block. Returns the
/// register holding the result. Statements that do not produce a
/// value (assignments, declarations) return a synthetic `Unit`
/// register so downstream code stays uniform.
pub fn lower_expr(b: &mut FuncBuilder<'_>, expr: &Expr) -> Reg {
    match expr {
        Expr::IntLit { value, .. } => {
            if *value >= i32::MIN as i64 && *value <= i32::MAX as i64 {
                b.emit_const(Const::Int(*value as i32))
            } else {
                b.emit_const(Const::Long(*value))
            }
        }
        Expr::FloatLit { value, .. } => b.emit_const(Const::Double(*value)),
        Expr::BoolLit { value, .. } => b.emit_const(Const::Bool(*value)),
        Expr::NullLit { .. } => b.emit_const(Const::Null),
        Expr::CharLit { value, .. } => b.emit_const(Const::Char(*value)),

        Expr::Binary { op, lhs, rhs, .. } => {
            let l = lower_expr(b, lhs);
            let r = lower_expr(b, rhs);
            let dst = b.alloc_reg();
            b.push(Inst::BinOp { dst, op: ast_binop(*op), lhs: l, rhs: r });
            dst
        }
        Expr::Unary { op, expr, .. } => {
            let operand = lower_expr(b, expr);
            let dst = b.alloc_reg();
            match op {
                AstUnOp::Not => b.push(Inst::Not { dst, src: operand }),
                AstUnOp::Neg => b.push(Inst::UnOp { dst, op: UnOp::Neg, operand }),
                AstUnOp::Pos => b.push(Inst::UnOp { dst, op: UnOp::Plus, operand }),
                AstUnOp::PreInc => b.push(Inst::UnOp { dst, op: UnOp::Inc, operand }),
                AstUnOp::PreDec => b.push(Inst::UnOp { dst, op: UnOp::Dec, operand }),
            }
            dst
        }
        Expr::If { cond, then_branch, else_branch, .. } => {
            let cond_r = lower_expr(b, cond);
            let t_block = b.alloc_block();
            let f_block = b.alloc_block();
            let join = b.alloc_block();
            b.terminate(Terminator::Branch { cond: cond_r, t: t_block, f: f_block });
            // Then arm.
            b.switch_to(t_block);
            let t_val = lower_expr(b, then_branch);
            b.terminate(Terminator::Goto(join));
            // Else arm.
            b.switch_to(f_block);
            let f_val = match else_branch {
                Some(e) => lower_expr(b, e),
                None => b.emit_const(Const::Unit),
            };
            b.terminate(Terminator::Goto(join));
            // Join — pick whichever branch's value landed via a Move.
            b.switch_to(join);
            let dst = b.alloc_reg();
            // The evaluator picks the actually-taken branch's value;
            // we emit a Move from both arms via the trailing copy.
            // For the initial lowering this is approximate — the real
            // IR needs phi nodes; until then the evaluator can
            // reconstruct via block-predecessor inspection.
            b.push(Inst::Move { dst, src: t_val });
            let _ = f_val;
            dst
        }
        Expr::Block(block) => lower_block(b, block),
        Expr::Path { segments, .. } => {
            if segments.len() == 1 {
                if let Some(r) = b.resolve(&segments[0].name) {
                    return r;
                }
            }
            // Unresolved path — emit a Trace so the gap is visible
            // and return Unit so the lowering pass stays total.
            b.push(Inst::Trace { span: expr_span(expr) });
            b.emit_const(Const::Unit)
        }
        Expr::StringTemplate { parts, .. } => {
            let mut cur = b.emit_const(Const::String(String::new()));
            for part in parts {
                let piece = match part {
                    klio_ast::StringPart::Text(s) => b.emit_const(Const::String(s.clone())),
                    klio_ast::StringPart::ShortInterp(ident) => {
                        b.resolve(&ident.name)
                            .unwrap_or_else(|| b.emit_const(Const::String(String::new())))
                    }
                    klio_ast::StringPart::Interp(e) => lower_expr(b, e),
                };
                let dst = b.alloc_reg();
                b.push(Inst::BinOp { dst, op: BinOp::StringConcat, lhs: cur, rhs: piece });
                cur = dst;
            }
            cur
        }
        Expr::While { cond, body, .. } => {
            let header = b.alloc_block();
            let body_blk = b.alloc_block();
            let exit = b.alloc_block();
            b.terminate(Terminator::Goto(header));

            b.switch_to(header);
            let c = lower_expr(b, cond);
            b.terminate(Terminator::Branch { cond: c, t: body_blk, f: exit });

            b.switch_to(body_blk);
            b.push_loop(None, header, exit);
            let _ = lower_expr(b, body);
            b.pop_loop();
            b.terminate(Terminator::Goto(header));

            b.switch_to(exit);
            b.emit_const(Const::Unit)
        }
        Expr::Member { receiver, name, .. } => {
            // Bare member read. `recv.method(...)` is handled by
            // Expr::Call below; here we treat it as a field read,
            // which the evaluator resolves at run time against the
            // receiver's class table.
            let recv = lower_expr(b, receiver);
            let dst = b.alloc_reg();
            let field = b.module.intern_const(Const::String(name.name.clone()));
            b.push(Inst::GetField { dst, receiver: recv, field });
            dst
        }
        Expr::Call { callee, args, .. } => {
            // Lower the callee's receiver / value separately so the
            // dispatcher knows whether to emit CallMember or
            // CallValue.
            match callee.as_ref() {
                Expr::Member { receiver, name, .. } => {
                    let recv = lower_expr(b, receiver);
                    let args_start = b.alloc_reg();
                    let mut next = args_start;
                    let mut count = 0u8;
                    for (i, a) in args.iter().enumerate() {
                        let r = lower_expr(b, a);
                        if i == 0 {
                            // First arg overwrites the reserved slot.
                            b.push(Inst::Move { dst: args_start, src: r });
                        } else {
                            next = b.alloc_reg();
                            b.push(Inst::Move { dst: next, src: r });
                        }
                        count += 1;
                    }
                    let _ = next;
                    let dst = b.alloc_reg();
                    let nm = b.module.intern_const(Const::String(name.name.clone()));
                    b.push(Inst::CallMember {
                        dst,
                        receiver: recv,
                        name: nm,
                        args: args_start,
                        n_args: count,
                    });
                    dst
                }
                _ => {
                    let callee_r = lower_expr(b, callee);
                    let args_start = b.alloc_reg();
                    let mut count = 0u8;
                    for (i, a) in args.iter().enumerate() {
                        let r = lower_expr(b, a);
                        if i == 0 {
                            b.push(Inst::Move { dst: args_start, src: r });
                        } else {
                            let nx = b.alloc_reg();
                            b.push(Inst::Move { dst: nx, src: r });
                        }
                        count += 1;
                    }
                    let dst = b.alloc_reg();
                    b.push(Inst::CallValue {
                        dst,
                        callee: callee_r,
                        args: args_start,
                        n_args: count,
                    });
                    dst
                }
            }
        }
        Expr::DoWhile { body, cond, .. } => {
            let body_blk = b.alloc_block();
            let exit = b.alloc_block();
            b.terminate(Terminator::Goto(body_blk));

            b.switch_to(body_blk);
            b.push_loop(None, body_blk, exit);
            if let Some(body) = body {
                let _ = lower_expr(b, body);
            }
            b.pop_loop();
            let c = lower_expr(b, cond);
            b.terminate(Terminator::Branch { cond: c, t: body_blk, f: exit });

            b.switch_to(exit);
            b.emit_const(Const::Unit)
        }
        Expr::Return { value, .. } => {
            let r = match value {
                Some(e) => Some(lower_expr(b, e)),
                None => None,
            };
            b.terminate(Terminator::Return(r));
            // The post-return path is unreachable; allocate a fresh
            // block so caller code that emits anything after sees a
            // distinct cursor.
            let dead = b.alloc_block();
            b.switch_to(dead);
            b.emit_const(Const::Unit)
        }
        Expr::Throw { value, .. } => {
            let r = lower_expr(b, value);
            b.terminate(Terminator::Throw(r));
            let dead = b.alloc_block();
            b.switch_to(dead);
            b.emit_const(Const::Unit)
        }
        Expr::When { subject, branches, .. } => {
            lower_when(b, subject.as_deref(), branches, expr_span(expr))
        }
        Expr::Try { body, catches, finally, .. } => {
            // The IR does not yet carry explicit exception edges,
            // so today this lowers as straight-line execution of
            // the body. Catches and finally branches are still
            // lowered for completeness — the evaluator's Throw
            // terminator will leak past them until exception edges
            // land. Tracking item: slice 4d in REFINEMENTS.md.
            let r = lower_block(b, body);
            for c in catches {
                let _ = lower_block(b, &c.body);
            }
            if let Some(f) = finally {
                let _ = lower_block(b, f);
            }
            r
        }
        Expr::Lambda { params, body, .. } => {
            // Lower the lambda body as its own Func added to the
            // enclosing module. The Lambda inst at the call site
            // carries the produced FuncId plus the captured-reg
            // list; the evaluator snapshots the values at the
            // capture site.
            let captures: Vec<Reg> = b.captured_regs();
            let body_func = lower_lambda_body(b.module, params, body);
            let dst = b.alloc_reg();
            b.push(Inst::Lambda { dst, body_func, captures });
            dst
        }
        Expr::Break { label, .. } => {
            if let Some(frame) = b.loop_for(label.as_ref().map(|i| i.name.as_str())).cloned() {
                b.terminate(Terminator::Goto(frame.break_target));
                let dead = b.alloc_block();
                b.switch_to(dead);
            } else {
                b.push(Inst::Trace { span: expr_span(expr) });
            }
            b.emit_const(Const::Unit)
        }
        Expr::Continue { label, .. } => {
            if let Some(frame) = b.loop_for(label.as_ref().map(|i| i.name.as_str())).cloned() {
                b.terminate(Terminator::Goto(frame.continue_target));
                let dead = b.alloc_block();
                b.switch_to(dead);
            } else {
                b.push(Inst::Trace { span: expr_span(expr) });
            }
            b.emit_const(Const::Unit)
        }
        Expr::For { vars, iter, body, .. } => lower_for(b, vars, iter, body),
        Expr::IsCheck { expr: inner, ty, negated, .. } => {
            let s = lower_expr(b, inner);
            let dst = b.alloc_reg();
            b.push(Inst::InstanceOf {
                dst,
                src: s,
                ty: crate::TypeRef {
                    name: ty.name.name.clone(),
                    nullable: ty.nullable,
                    args: Vec::new(),
                },
            });
            if *negated {
                let neg = b.alloc_reg();
                b.push(Inst::Not { dst: neg, src: dst });
                neg
            } else {
                dst
            }
        }
        Expr::As { expr: inner, ty, safe, .. } => {
            let s = lower_expr(b, inner);
            let dst = b.alloc_reg();
            b.push(Inst::Cast {
                dst,
                src: s,
                ty: crate::TypeRef {
                    name: ty.name.name.clone(),
                    nullable: ty.nullable,
                    args: Vec::new(),
                },
                safe: *safe,
            });
            dst
        }
        Expr::Postfix { op, expr: inner, .. } => match op {
            klio_ast::PostfixOp::NotNull => {
                let s = lower_expr(b, inner);
                let dst = b.alloc_reg();
                b.push(Inst::NotNullAssert { dst, src: s });
                dst
            }
            klio_ast::PostfixOp::Inc | klio_ast::PostfixOp::Dec => {
                let s = lower_expr(b, inner);
                let op = match op {
                    klio_ast::PostfixOp::Inc => UnOp::Inc,
                    klio_ast::PostfixOp::Dec => UnOp::Dec,
                    _ => unreachable!(),
                };
                let new = b.alloc_reg();
                b.push(Inst::UnOp { dst: new, op, operand: s });
                if let Expr::Path { segments, .. } = inner.as_ref() {
                    if segments.len() == 1 {
                        b.bind(segments[0].name.clone(), new);
                    }
                }
                s
            }
        },
        Expr::Labeled { label, expr: inner, .. } => match inner.as_ref() {
            Expr::While { cond, body, .. } => {
                let header = b.alloc_block();
                let body_blk = b.alloc_block();
                let exit = b.alloc_block();
                b.terminate(Terminator::Goto(header));
                b.switch_to(header);
                let c = lower_expr(b, cond);
                b.terminate(Terminator::Branch { cond: c, t: body_blk, f: exit });
                b.switch_to(body_blk);
                b.push_loop(Some(label.name.clone()), header, exit);
                let _ = lower_expr(b, body);
                b.pop_loop();
                b.terminate(Terminator::Goto(header));
                b.switch_to(exit);
                b.emit_const(Const::Unit)
            }
            _ => lower_expr(b, inner),
        },
        _ => {
            // Remaining expression forms not yet lowered. Emit a
            // placeholder Trace so the gap is visible in printouts
            // and tests can assert which forms still need work.
            b.push(Inst::Trace { span: expr_span(expr) });
            b.emit_const(Const::Unit)
        }
    }
}

fn lower_lambda_body(
    module: &mut crate::Module,
    params: &[klio_ast::Ident],
    body: &klio_ast::Block,
) -> crate::FuncId {
    let mut b = FuncBuilder::new(module);
    let names: Vec<&str> = params.iter().map(|p| p.name.as_str()).collect();
    bind_params(&mut b, &names);
    let result = lower_block(&mut b, body);
    b.terminate(Terminator::Return(Some(result)));
    let func = b.finish("<lambda>", "<lambda>", crate::TypeRef::unit());
    let id = crate::FuncId(module.funcs.len() as u32);
    let mut placed = func;
    placed.id = id;
    module.funcs.push(placed);
    id
}

fn lower_for(
    b: &mut FuncBuilder<'_>,
    vars: &[klio_ast::Ident],
    iter: &Expr,
    body: &Expr,
) -> Reg {
    let recv = lower_expr(b, iter);
    let it_reg = b.alloc_reg();
    let zero = b.alloc_reg();
    b.push(Inst::Move { dst: zero, src: recv });
    let name = b.module.intern_const(Const::String("iterator".into()));
    let args_start = b.alloc_reg();
    b.push(Inst::CallMember {
        dst: it_reg,
        receiver: zero,
        name,
        args: args_start,
        n_args: 0,
    });
    let header = b.alloc_block();
    let body_blk = b.alloc_block();
    let exit = b.alloc_block();
    b.terminate(Terminator::Goto(header));

    b.switch_to(header);
    let has_next = b.alloc_reg();
    let hn_name = b.module.intern_const(Const::String("hasNext".into()));
    let hn_args = b.alloc_reg();
    b.push(Inst::CallMember {
        dst: has_next,
        receiver: it_reg,
        name: hn_name,
        args: hn_args,
        n_args: 0,
    });
    b.terminate(Terminator::Branch {
        cond: has_next,
        t: body_blk,
        f: exit,
    });

    b.switch_to(body_blk);
    b.push_scope();
    let next_reg = b.alloc_reg();
    let next_name = b.module.intern_const(Const::String("next".into()));
    let nargs = b.alloc_reg();
    b.push(Inst::CallMember {
        dst: next_reg,
        receiver: it_reg,
        name: next_name,
        args: nargs,
        n_args: 0,
    });
    if vars.len() == 1 {
        b.bind(vars[0].name.clone(), next_reg);
    } else {
        for (i, v) in vars.iter().enumerate() {
            let comp = b.alloc_reg();
            let nm = b
                .module
                .intern_const(Const::String(format!("component{}", i + 1)));
            let cargs = b.alloc_reg();
            b.push(Inst::CallMember {
                dst: comp,
                receiver: next_reg,
                name: nm,
                args: cargs,
                n_args: 0,
            });
            b.bind(v.name.clone(), comp);
        }
    }
    b.push_loop(None, header, exit);
    let _ = lower_expr(b, body);
    b.pop_loop();
    b.pop_scope();
    b.terminate(Terminator::Goto(header));

    b.switch_to(exit);
    b.emit_const(Const::Unit)
}

fn lower_when(
    b: &mut FuncBuilder<'_>,
    subject: Option<&Expr>,
    branches: &[klio_ast::WhenBranch],
    _span: klio_span::Span,
) -> Reg {
    // The lowering models `when` as a chain of conditional branches:
    //
    //     entry  ─cond0─►  body0 ─►  join
    //       │
    //      next ─cond1─►  body1 ─►  join
    //       │
    //      ...
    //      ─else→ default_body ─► join
    //
    // The result register is filled by each body's `Move`-equivalent
    // store; the join sees whichever branch ran. (Phis are an
    // upcoming refinement; for now we leave the join's incoming
    // wiring approximate and rely on the evaluator's reach analysis.)
    let subject_r = subject.map(|s| lower_expr(b, s));
    let join = b.alloc_block();
    let result = b.alloc_reg();
    for branch in branches {
        // Compose this branch's condition over its patterns.
        let body_blk = b.alloc_block();
        let next_blk = b.alloc_block();
        let cond = match (subject_r, branch.patterns.as_slice()) {
            // Else branch: unconditional.
            (_, [p]) if matches!(p.kind, klio_ast::WhenPatternKind::Else) => {
                b.terminate(Terminator::Goto(body_blk));
                b.switch_to(body_blk);
                let v = lower_expr(b, &branch.body);
                b.push(Inst::Move { dst: result, src: v });
                b.terminate(Terminator::Goto(join));
                b.switch_to(next_blk);
                continue;
            }
            (Some(subj), patterns) => or_chain(b, |b| {
                patterns.iter().map(|p| match &p.kind {
                    klio_ast::WhenPatternKind::Value(e) => {
                        let v = lower_expr(b, e);
                        let dst = b.alloc_reg();
                        b.push(Inst::BinOp { dst, op: BinOp::Eq, lhs: subj, rhs: v });
                        dst
                    }
                    klio_ast::WhenPatternKind::IsType(ty) => {
                        let dst = b.alloc_reg();
                        b.push(Inst::InstanceOf {
                            dst,
                            src: subj,
                            ty: crate::TypeRef {
                                name: ty.name.name.clone(),
                                nullable: ty.nullable,
                                args: Vec::new(),
                            },
                        });
                        dst
                    }
                    _ => {
                        // InRange/NotInRange/NotIsType need operator dispatch
                        // that's not yet wired. Trace + emit always-false.
                        b.push(Inst::Trace { span: p.span });
                        b.emit_const(Const::Bool(false))
                    }
                }).collect()
            }),
            (None, patterns) => or_chain(b, |b| {
                patterns.iter().map(|p| match &p.kind {
                    klio_ast::WhenPatternKind::Value(e) => lower_expr(b, e),
                    _ => {
                        b.push(Inst::Trace { span: p.span });
                        b.emit_const(Const::Bool(false))
                    }
                }).collect()
            }),
        };
        b.terminate(Terminator::Branch { cond, t: body_blk, f: next_blk });
        b.switch_to(body_blk);
        let v = lower_expr(b, &branch.body);
        b.push(Inst::Move { dst: result, src: v });
        b.terminate(Terminator::Goto(join));
        b.switch_to(next_blk);
    }
    // Fall-through with no matching branch: leave `result` at its
    // default. A real impl would throw NoWhenBranchMatchedException.
    b.terminate(Terminator::Goto(join));
    b.switch_to(join);
    result
}

fn or_chain(b: &mut FuncBuilder<'_>, mk: impl FnOnce(&mut FuncBuilder<'_>) -> Vec<Reg>) -> Reg {
    let regs = mk(b);
    if regs.is_empty() {
        return b.emit_const(Const::Bool(false));
    }
    let mut acc = regs[0];
    for r in &regs[1..] {
        let dst = b.alloc_reg();
        b.push(Inst::BinOp { dst, op: BinOp::Or, lhs: acc, rhs: *r });
        acc = dst;
    }
    acc
}

fn lower_block(b: &mut FuncBuilder<'_>, block: &AstBlock) -> Reg {
    b.push_scope();
    let mut last: Option<Reg> = None;
    for stmt in &block.stmts {
        last = lower_stmt(b, stmt);
    }
    let result = last.unwrap_or_else(|| b.emit_const(Const::Unit));
    b.pop_scope();
    result
}

fn lower_stmt(b: &mut FuncBuilder<'_>, stmt: &Stmt) -> Option<Reg> {
    match stmt {
        Stmt::Expr(e) => Some(lower_expr(b, e)),
        Stmt::Decl(klio_ast::Decl::Property(p)) => {
            // `val x = expr` / `var x = expr`. The init is lowered
            // into a fresh register and bound in the current scope;
            // mutability is enforced by typeck, not the IR.
            let init = match &p.init {
                Some(e) => lower_expr(b, e),
                None => b.emit_const(Const::Unit),
            };
            b.bind(p.name.name.clone(), init);
            None
        }
        Stmt::Assign { target, op, value, .. } => {
            let v = lower_expr(b, value);
            let combined = match op {
                klio_ast::AssignOp::Assign => v,
                klio_ast::AssignOp::Add | klio_ast::AssignOp::Sub
                | klio_ast::AssignOp::Mul | klio_ast::AssignOp::Div
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
                    b.push(Inst::BinOp { dst, op: bin, lhs: cur, rhs: v });
                    dst
                }
            };
            match target {
                Expr::Path { segments, .. } if segments.len() == 1 => {
                    b.bind(segments[0].name.clone(), combined);
                }
                Expr::Member { receiver, name, .. } => {
                    let recv = lower_expr(b, receiver);
                    let field = b.module.intern_const(Const::String(name.name.clone()));
                    b.push(Inst::SetField { receiver: recv, field, value: combined });
                }
                _ => {
                    b.push(Inst::Trace { span: expr_span(target) });
                }
            }
            None
        }
        Stmt::Decl(_) | Stmt::DestructuringDecl { .. } => None,
    }
}

fn ast_binop(op: AstBinOp) -> BinOp {
    match op {
        AstBinOp::Add => BinOp::Add,
        AstBinOp::Sub => BinOp::Sub,
        AstBinOp::Mul => BinOp::Mul,
        AstBinOp::Div => BinOp::Div,
        AstBinOp::Rem => BinOp::Mod,
        AstBinOp::Eq | AstBinOp::IdentEq => BinOp::Eq,
        AstBinOp::Neq | AstBinOp::IdentNeq => BinOp::NotEq,
        AstBinOp::Lt => BinOp::Less,
        AstBinOp::Le => BinOp::LessEq,
        AstBinOp::Gt => BinOp::Greater,
        AstBinOp::Ge => BinOp::GreaterEq,
        AstBinOp::And => BinOp::And,
        AstBinOp::Or => BinOp::Or,
        AstBinOp::Range => BinOp::RangeTo,
        AstBinOp::RangeUntil => BinOp::RangeUntil,
        AstBinOp::Elvis => BinOp::Elvis,
        // in / !in / assign not lowered as plain binops; they need
        // dedicated IR instructions (Call to operator contains /
        // SetField for assign). Fall back to Add so the lowering
        // pass remains total; the dedicated forms land in the next
        // pass.
        AstBinOp::In | AstBinOp::NotIn | AstBinOp::Assign => BinOp::Add,
    }
}

fn expr_span(e: &Expr) -> klio_span::Span {
    match e {
        Expr::IntLit { span, .. }
        | Expr::FloatLit { span, .. }
        | Expr::BoolLit { span, .. }
        | Expr::NullLit { span }
        | Expr::CharLit { span, .. }
        | Expr::StringTemplate { span, .. }
        | Expr::Path { span, .. }
        | Expr::Member { span, .. }
        | Expr::Call { span, .. }
        | Expr::Index { span, .. }
        | Expr::Binary { span, .. }
        | Expr::Unary { span, .. }
        | Expr::Postfix { span, .. }
        | Expr::If { span, .. }
        | Expr::While { span, .. }
        | Expr::DoWhile { span, .. }
        | Expr::For { span, .. }
        | Expr::Return { span, .. }
        | Expr::Break { span, .. }
        | Expr::Continue { span, .. }
        | Expr::Labeled { span, .. }
        | Expr::Throw { span, .. }
        | Expr::Try { span, .. }
        | Expr::Lambda { span, .. }
        | Expr::This { span, .. }
        | Expr::Super { span, .. }
        | Expr::PropertyRef { span, .. }
        | Expr::MemberRef { span, .. }
        | Expr::When { span, .. }
        | Expr::IsCheck { span, .. }
        | Expr::As { span, .. }
        | Expr::AnonFun { span, .. }
        | Expr::Spread { span, .. }
        | Expr::ObjectExpr { span, .. } => *span,
        Expr::Block(b) => b.span,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Module, TypeRef};
    use klio_ast::{BinOp as AstBinOp, Expr};
    use klio_span::{FileId, Span};

    fn dummy_span() -> Span {
        Span::new(FileId(0), 0, 0)
    }

    fn int_lit(v: i64) -> Expr {
        Expr::IntLit {
            value: v,
            kind: klio_ast::IntLitKind::default(),
            span: dummy_span(),
        }
    }

    #[test]
    fn lowers_int_literal_to_const() {
        let mut m = Module::default();
        let mut b = FuncBuilder::new(&mut m);
        let r = lower_expr(&mut b, &int_lit(7));
        b.terminate(Terminator::Return(Some(r)));
        let func = b.finish("f", "test.f", TypeRef::int());
        assert_eq!(func.blocks[0].insts.len(), 1);
        assert!(matches!(func.blocks[0].insts[0], Inst::Const { .. }));
    }

    #[test]
    fn lowers_binary_add() {
        let mut m = Module::default();
        let mut b = FuncBuilder::new(&mut m);
        let expr = Expr::Binary {
            op: AstBinOp::Add,
            lhs: Box::new(int_lit(1)),
            rhs: Box::new(int_lit(2)),
            span: dummy_span(),
        };
        let r = lower_expr(&mut b, &expr);
        b.terminate(Terminator::Return(Some(r)));
        let func = b.finish("f", "test.f", TypeRef::int());
        // 2 consts + 1 binop
        assert_eq!(func.blocks[0].insts.len(), 3);
        assert!(matches!(func.blocks[0].insts[2], Inst::BinOp { op: BinOp::Add, .. }));
    }

    #[test]
    fn lowers_path_through_scope() {
        let mut m = Module::default();
        let mut b = FuncBuilder::new(&mut m);
        let p = b.alloc_reg();
        b.bind("x", p);
        let path = Expr::Path {
            segments: vec![klio_ast::Ident { name: "x".into(), span: dummy_span() }],
            span: dummy_span(),
        };
        let r = lower_expr(&mut b, &path);
        assert_eq!(r, p, "path should resolve to bound param register");
    }

    #[test]
    fn lowers_member_get_field() {
        let mut m = Module::default();
        let mut b = FuncBuilder::new(&mut m);
        let recv = b.alloc_reg();
        b.bind("o", recv);
        let expr = Expr::Member {
            receiver: Box::new(Expr::Path {
                segments: vec![klio_ast::Ident { name: "o".into(), span: dummy_span() }],
                span: dummy_span(),
            }),
            name: klio_ast::Ident { name: "field".into(), span: dummy_span() },
            safe: false,
            span: dummy_span(),
        };
        let _ = lower_expr(&mut b, &expr);
        let func = b.finish("f", "test.f", TypeRef::unit());
        assert!(func.blocks[0]
            .insts
            .iter()
            .any(|i| matches!(i, Inst::GetField { .. })));
    }

    #[test]
    fn lowers_member_call_emits_call_member() {
        let mut m = Module::default();
        let mut b = FuncBuilder::new(&mut m);
        let recv = b.alloc_reg();
        b.bind("o", recv);
        let expr = Expr::Call {
            callee: Box::new(Expr::Member {
                receiver: Box::new(Expr::Path {
                    segments: vec![klio_ast::Ident { name: "o".into(), span: dummy_span() }],
                    span: dummy_span(),
                }),
                name: klio_ast::Ident { name: "doit".into(), span: dummy_span() },
                safe: false,
                span: dummy_span(),
            }),
            args: vec![int_lit(1), int_lit(2)],
            arg_names: vec![None, None],
            type_args: vec![],
            is_infix: false,
            span: dummy_span(),
        };
        let _ = lower_expr(&mut b, &expr);
        let func = b.finish("f", "test.f", TypeRef::unit());
        assert!(func.blocks[0]
            .insts
            .iter()
            .any(|i| matches!(i, Inst::CallMember { n_args: 2, .. })));
    }

    #[test]
    fn lowers_while_loop_shape() {
        let mut m = Module::default();
        let mut b = FuncBuilder::new(&mut m);
        let cond = Expr::BoolLit { value: true, span: dummy_span() };
        let body = Expr::Block(klio_ast::Block { stmts: Vec::new(), span: dummy_span() });
        let w = Expr::While {
            cond: Box::new(cond),
            body: Box::new(body),
            span: dummy_span(),
        };
        let _ = lower_expr(&mut b, &w);
        let func = b.finish("f", "test.f", TypeRef::unit());
        // header, body, exit, plus entry — 4 blocks at least.
        assert!(func.blocks.len() >= 4);
    }

    #[test]
    fn lowers_if_with_two_arms() {
        let mut m = Module::default();
        let mut b = FuncBuilder::new(&mut m);
        let expr = Expr::If {
            cond: Box::new(Expr::BoolLit { value: true, span: dummy_span() }),
            then_branch: Box::new(int_lit(1)),
            else_branch: Some(Box::new(int_lit(2))),
            span: dummy_span(),
        };
        let _ = lower_expr(&mut b, &expr);
        let func = b.finish("f", "test.f", TypeRef::int());
        // Entry, then, else, join — 4 blocks.
        assert!(func.blocks.len() >= 4);
        let entry_term = &func.blocks[0].terminator;
        assert!(matches!(entry_term, Terminator::Branch { .. }));
    }
}
