use super::lower_expr;
use crate::build::FuncBuilder;
use crate::{Const, Inst, Reg, Terminator};
use klio_ast::Expr;

pub(super) fn lower_for(
    b: &mut FuncBuilder<'_>,
    vars: &[klio_ast::Ident],
    iter: &Expr,
    body: &Expr,
) -> Reg {
    lower_for_labeled(b, vars, iter, body, None)
}

pub(super) fn lower_for_labeled(
    b: &mut FuncBuilder<'_>,
    vars: &[klio_ast::Ident],
    iter: &Expr,
    body: &Expr,
    label: Option<String>,
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
        arg_names: Vec::new(),
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
        arg_names: Vec::new(),
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
        arg_names: Vec::new(),
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
                arg_names: Vec::new(),
            });
            b.bind(v.name.clone(), comp);
        }
    }
    b.push_loop(label, header, exit);
    let _ = lower_expr(b, body);
    b.pop_loop();
    b.pop_scope();
    b.terminate(Terminator::Goto(header));

    b.switch_to(exit);
    b.emit_const(Const::Unit)
}
