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
use crate::{BinOp, BlockId, Const, Func, FuncId, Inst, Reg, Terminator, UnOp};

mod ast_scan;
mod for_loop;
mod inline_call;
mod inline_state;
mod lambda_body;
mod literals;
mod thunks;
mod when_expr;
use ast_scan::{
    collect_dotted_fqn, collect_path_idents, collect_path_idents_stmt,
    compute_boxed_vars, is_boxed_to_any_form,
};
use inline_state::inline_fn_ast;
use for_loop::{lower_for, lower_for_labeled};
pub use thunks::{
    lower_accessor_block, lower_accessor_expr, lower_binary_expr_as_thunk,
    lower_block_as_thunk, lower_block_as_unary_thunk, lower_empty_thunk,
    lower_expr_as_param_thunk, lower_expr_as_param_thunk_scoped,
    lower_expr_as_thunk, lower_init_block, lower_init_block_with_params,
    lower_unary_expr_as_thunk,
};
use inline_call::{
    arg_lambda_has_nonlocal_return, splice_inline_lambda,
    try_inline_call_with_type_args,
};
use lambda_body::{
    lower_lambda_body_capturing, lower_lambda_body_capturing_kind,
    lower_lambda_body_capturing_kind_with, resolve_capture,
};
use when_expr::lower_when;
pub use inline_state::{set_inline_fn_asts, set_shadowed_inline_names};
pub use literals::widen_numeric_literal;
use literals::{is_package_head, is_pkg_root};

mod helpers;
pub(crate) use helpers::*;
mod decl;
pub use decl::*;
mod expr;
pub use expr::*;
mod stmt;
pub(crate) use stmt::*;

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
