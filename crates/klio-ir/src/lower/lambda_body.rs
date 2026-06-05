use super::ast_scan::{collect_path_idents_stmt, compute_boxed_vars};
use super::{bind_params, lower_block};
use crate::build::FuncBuilder;
use crate::{Const, Inst, Reg, Terminator};

pub(super) fn resolve_capture(b: &mut FuncBuilder<'_>, name: &str) -> Reg {
    if let Some(r) = b.resolve(name) {
        return r;
    }
    // A lambda body's implicit `this` (the receiver of an `apply` /
    // `with` / extension-receiver lambda) is bound at invoke time
    // through the closure's capture slot rather than a scope binding
    // or an `outer_names` entry — so `knows_outer("this")` is false
    // even though `this` is reachable. The `Expr::This` lowering uses
    // the same `is_lambda_body()` signal. Mirror it here so a *nested*
    // lambda can capture the enclosing receiver: forward `this`
    // through this builder's own capture slot rather than collapsing
    // it to `Unit`.
    if name == "this" && b.is_lambda_body() {
        let idx = b.record_capture("this");
        let dst = b.alloc_reg();
        b.push(Inst::LoadCapture { dst, idx });
        b.bind("this".to_string(), dst);
        return dst;
    }
    if b.knows_outer(name) {
        let idx = b.record_capture(name);
        let dst = b.alloc_reg();
        b.push(Inst::LoadCapture { dst, idx });
        b.bind(name.to_string(), dst);
        return dst;
    }
    let dst = b.alloc_reg();
    let unit = b.module.intern_const(Const::Unit);
    b.push(Inst::Const { dst, value: unit });
    dst
}

/// Lower a lambda body, threading the enclosing builder's
/// visible-name set so Path references that hit it lower to
/// `LoadCapture`. Returns the body's `FuncId` plus the ordered
/// list of captured names — the caller resolves each to an outer
/// reg and ships it through `Inst::Lambda::captures`.
pub(super) fn lower_lambda_body_capturing(
    module: &mut crate::Module,
    params: &[klio_ast::Ident],
    body: &klio_ast::Block,
    outer: std::collections::HashSet<String>,
    outer_boxed: &std::collections::HashSet<String>,
    inherited_rlp: std::collections::HashSet<String>,
) -> (crate::FuncId, Vec<String>) {
    lower_lambda_body_capturing_kind(
        module,
        params,
        body,
        outer,
        true,
        outer_boxed,
        None,
        inherited_rlp,
    )
}

#[allow(clippy::too_many_arguments)]
pub(super) fn lower_lambda_body_capturing_kind(
    module: &mut crate::Module,
    params: &[klio_ast::Ident],
    body: &klio_ast::Block,
    outer: std::collections::HashSet<String>,
    is_lambda: bool,
    outer_boxed: &std::collections::HashSet<String>,
    tailrec_self: Option<&str>,
    inherited_rlp: std::collections::HashSet<String>,
) -> (crate::FuncId, Vec<String>) {
    lower_lambda_body_capturing_kind_with(
        module,
        params,
        body,
        outer,
        is_lambda,
        outer_boxed,
        tailrec_self,
        false,
        inherited_rlp,
    )
}

// Innermost rung of the lambda-body lowering wrapper chain; each flag/ref
// is threaded straight from the AST and bundling them would only obscure it.
#[allow(clippy::too_many_arguments)]
#[allow(clippy::too_many_arguments)]
pub(super) fn lower_lambda_body_capturing_kind_with(
    module: &mut crate::Module,
    params: &[klio_ast::Ident],
    body: &klio_ast::Block,
    outer: std::collections::HashSet<String>,
    is_lambda: bool,
    outer_boxed: &std::collections::HashSet<String>,
    tailrec_self: Option<&str>,
    is_named_local_fn: bool,
    inherited_rlp: std::collections::HashSet<String>,
) -> (crate::FuncId, Vec<String>) {
    let mut b = FuncBuilder::new(module);
    if is_named_local_fn {
        b.set_outer_names_named_local_fn(outer);
    } else if is_lambda {
        b.set_outer_names(outer);
    } else {
        b.set_outer_names_without_lambda(outer);
    }
    // A captured `block: T.() -> R` from an enclosing scope must still
    // dispatch a bare `block()` here as `this.block()` — carry the
    // enclosing receiver-lambda-param names so `is_receiver_lambda_param`
    // sees them across the capture boundary.
    b.inherit_receiver_lambda_params(inherited_rlp);
    if let Some(name) = tailrec_self {
        let () = b.set_tailrec_self(name.to_string());
    }
    let mut boxed = compute_boxed_vars(&body.stmts);
    if !outer_boxed.is_empty() {
        let mut refs = std::collections::HashSet::new();
        for s in &body.stmts {
            collect_path_idents_stmt(s, &mut refs);
        }
        for n in outer_boxed {
            if refs.contains(n) {
                boxed.insert(n.clone());
            }
        }
    }
    b.set_boxed_vars(boxed);
    let mut names: Vec<&str> = params.iter().map(|p| p.name.as_str()).collect();
    if params.is_empty() {
        names.push("it");
    }
    bind_params(&mut b, &names);
    let result = lower_block(&mut b, body);
    b.terminate(Terminator::Return(Some(result)));
    let captured = b.captures_taken().to_vec();
    let func = b.finish("<lambda>", "<lambda>", crate::TypeRef::unit());
    // Function count is bounded well below u32::MAX; the index is the new FuncId.
    #[allow(clippy::cast_possible_truncation)]
    let id = crate::FuncId(module.funcs.len() as u32);
    let mut placed = func;
    placed.id = id;
    placed.is_lambda = is_lambda;
    placed.params = names
        .iter()
        .map(|n| crate::Param {
            name: (*n).to_string(),
            ty: crate::TypeRef::unit(),
            default: None,
            is_property: false,
            is_vararg: false,
            has_default: false,
        })
        .collect();
    module.funcs.push(placed);
    (id, captured)
}
