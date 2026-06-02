use super::lower_expr;
use crate::build::FuncBuilder;
use crate::{BinOp, BlockId, Const, Inst, Reg, Terminator};
use klio_ast::Expr;

/// Switch-lowering layout for a subject-bound `when`: the constant cases
/// and their target blocks, the optional `else` block, and the body block
/// per branch in branch order.
type SwitchArms = (
    Vec<(crate::ConstId, BlockId)>,
    Option<BlockId>,
    Vec<Option<BlockId>>,
);

pub(super) fn collect_switch_arms(
    b: &mut FuncBuilder<'_>,
    branches: &[klio_ast::WhenBranch],
) -> Option<SwitchArms> {
    let mut cases: Vec<(crate::ConstId, BlockId)> = Vec::new();
    let mut body_blocks: Vec<Option<BlockId>> = Vec::with_capacity(branches.len());
    let mut default: Option<BlockId> = None;
    for branch in branches {
        let blk = b.alloc_block();
        if branch.patterns.len() == 1
            && matches!(branch.patterns[0].kind, klio_ast::WhenPatternKind::Else)
        {
            if default.is_some() {
                return None;
            }
            default = Some(blk);
            body_blocks.push(Some(blk));
            continue;
        }
        for pat in &branch.patterns {
            let klio_ast::WhenPatternKind::Value(value_expr) = &pat.kind else {
                return None;
            };
            let const_id = match value_expr {
                // i32-representable literal narrows to Int (guarded above).
                #[allow(clippy::cast_possible_truncation)]
                Expr::IntLit { value, .. } if i32::try_from(*value).is_ok() => {
                    b.module.intern_const(Const::Int(*value as i32))
                }
                Expr::IntLit { value, .. } => b.module.intern_const(Const::Long(*value)),
                Expr::StringTemplate { parts, .. } if parts.len() == 1 => {
                    if let klio_ast::StringPart::Text(s) = &parts[0] {
                        b.module.intern_const(Const::String(s.clone()))
                    } else {
                        return None;
                    }
                }
                Expr::BoolLit { value, .. } => b.module.intern_const(Const::Bool(*value)),
                Expr::CharLit { value, .. } => b.module.intern_const(Const::Char(*value)),
                Expr::NullLit { .. } => b.module.intern_const(Const::Null),
                _ => return None,
            };
            cases.push((const_id, blk));
        }
        body_blocks.push(Some(blk));
    }
    if cases.is_empty() && default.is_none() {
        return None;
    }
    Some((cases, default, body_blocks))
}

pub(super) fn lower_when(
    b: &mut FuncBuilder<'_>,
    subject: Option<&Expr>,
    branches: &[klio_ast::WhenBranch],
    _span: klio_span::Span,
) -> Reg {
    let subject_r = subject.map(|s| lower_expr(b, s));
    let join = b.alloc_block();
    let result = b.alloc_reg();
    if let Some(subj) = subject_r
        && let Some(arms) = collect_switch_arms(b, branches)
    {
        let (cases, default_blk, body_block_for_branch) = arms;
        let default = if let Some(blk) = default_blk {
            blk
        } else {
            let dflt = b.alloc_block();
            let saved = b.cur;
            b.switch_to(dflt);
            let u = b.emit_const(Const::Unit);
            b.push(Inst::Move {
                dst: result,
                src: u,
            });
            b.terminate(Terminator::Goto(join));
            b.switch_to(saved);
            dflt
        };
        b.terminate(Terminator::Switch {
            reg: subj,
            arms: cases,
            default,
        });
        for (branch, body_blk) in branches.iter().zip(body_block_for_branch.iter()) {
            if let Some(blk) = body_blk {
                b.switch_to(*blk);
                let v = lower_expr(b, &branch.body);
                b.push(Inst::Move {
                    dst: result,
                    src: v,
                });
                b.terminate(Terminator::Goto(join));
            }
        }
        b.switch_to(join);
        return result;
    }
    for branch in branches {
        let body_blk = b.alloc_block();
        let next_blk = b.alloc_block();
        let cond = match (subject_r, branch.patterns.as_slice()) {
            (_, [p]) if matches!(p.kind, klio_ast::WhenPatternKind::Else) => {
                b.terminate(Terminator::Goto(body_blk));
                b.switch_to(body_blk);
                let v = lower_expr(b, &branch.body);
                b.push(Inst::Move {
                    dst: result,
                    src: v,
                });
                b.terminate(Terminator::Goto(join));
                b.switch_to(next_blk);
                continue;
            }
            (Some(subj), patterns) => or_chain(b, |b| {
                patterns
                    .iter()
                    .map(|p| lower_subject_pattern_cond(b, p, subj))
                    .collect()
            }),
            (None, patterns) => or_chain(b, |b| {
                patterns
                    .iter()
                    .map(|p| {
                        if let klio_ast::WhenPatternKind::Value(e) = &p.kind {
                            lower_expr(b, e)
                        } else {
                            b.push(Inst::Trace { span: p.span });
                            b.emit_const(Const::Bool(false))
                        }
                    })
                    .collect()
            }),
        };
        b.terminate(Terminator::Branch {
            cond,
            t: body_blk,
            f: next_blk,
        });
        b.switch_to(body_blk);
        let v = lower_expr(b, &branch.body);
        b.push(Inst::Move {
            dst: result,
            src: v,
        });
        b.terminate(Terminator::Goto(join));
        b.switch_to(next_blk);
    }
    let u = b.emit_const(Const::Unit);
    b.push(Inst::Move {
        dst: result,
        src: u,
    });
    b.terminate(Terminator::Goto(join));
    b.switch_to(join);
    result
}

/// Lower one `when` pattern of a subject-bound branch into a Boolean
/// condition register comparing it against `subj`.
fn lower_subject_pattern_cond(
    b: &mut FuncBuilder<'_>,
    p: &klio_ast::WhenPattern,
    subj: Reg,
) -> Reg {
    match &p.kind {
        klio_ast::WhenPatternKind::Value(e) => {
            let v = lower_expr(b, e);
            let dst = b.alloc_reg();
            b.push(Inst::BinOp {
                dst,
                op: BinOp::Eq,
                lhs: subj,
                rhs: v,
            });
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
        klio_ast::WhenPatternKind::NotIsType(ty) => {
            let raw = b.alloc_reg();
            b.push(Inst::InstanceOf {
                dst: raw,
                src: subj,
                ty: crate::TypeRef {
                    name: ty.name.name.clone(),
                    nullable: ty.nullable,
                    args: Vec::new(),
                },
            });
            let neg = b.alloc_reg();
            b.push(Inst::Not { dst: neg, src: raw });
            neg
        }
        klio_ast::WhenPatternKind::InRange(e) => {
            let range_r = lower_expr(b, e);
            let args_start = b.alloc_reg();
            b.push(Inst::Move {
                dst: args_start,
                src: subj,
            });
            let dst = b.alloc_reg();
            let nm = b.module.intern_const(Const::String("contains".into()));
            b.push(Inst::CallMember {
                dst,
                receiver: range_r,
                name: nm,
                args: args_start,
                n_args: 1,
                arg_names: Vec::new(),
            });
            dst
        }
        klio_ast::WhenPatternKind::NotInRange(e) => {
            let range_r = lower_expr(b, e);
            let args_start = b.alloc_reg();
            b.push(Inst::Move {
                dst: args_start,
                src: subj,
            });
            let raw = b.alloc_reg();
            let nm = b.module.intern_const(Const::String("contains".into()));
            b.push(Inst::CallMember {
                dst: raw,
                receiver: range_r,
                name: nm,
                args: args_start,
                n_args: 1,
                arg_names: Vec::new(),
            });
            let neg = b.alloc_reg();
            b.push(Inst::Not { dst: neg, src: raw });
            neg
        }
        klio_ast::WhenPatternKind::Else => {
            b.push(Inst::Trace { span: p.span });
            b.emit_const(Const::Bool(false))
        }
    }
}

pub(super) fn or_chain(
    b: &mut FuncBuilder<'_>,
    mk: impl FnOnce(&mut FuncBuilder<'_>) -> Vec<Reg>,
) -> Reg {
    let regs = mk(b);
    if regs.is_empty() {
        return b.emit_const(Const::Bool(false));
    }
    let mut acc = regs[0];
    for r in &regs[1..] {
        let dst = b.alloc_reg();
        b.push(Inst::BinOp {
            dst,
            op: BinOp::Or,
            lhs: acc,
            rhs: *r,
        });
        acc = dst;
    }
    acc
}
