//! Lowering helpers that wrap an expression or block as a synthetic
//! 0/1/2-arg IR function. Used by the build pass to materialise
//! default-arg producers, accessors, init blocks, and similar
//! "expression-bodied" pieces of code without the surrounding fn /
//! method machinery.

use super::{bind_params, lower_block, lower_expr};
use crate::build::FuncBuilder;
use crate::{Const, Terminator};
use klio_ast::Expr;
use std::hash::BuildHasher;

/// Assign the next `FuncId` to `func` and append it to the module.
fn push_func(module: &mut crate::Module, mut func: crate::Func) -> crate::FuncId {
    // FuncId indexes module.funcs; the IR caps the func count at u32.
    #[allow(clippy::cast_possible_truncation)]
    let id = crate::FuncId(module.funcs.len() as u32);
    func.id = id;
    module.funcs.push(func);
    id
}

/// Lower an arbitrary expression as a 0-arg synthetic function whose
/// body returns the expression's value. The synthetic function is
/// pushed onto the module so a downstream caller can invoke it via
/// `eval_with` against `module.funcs[id]`.
pub fn lower_expr_as_thunk(module: &mut crate::Module, expr: &Expr, name: &str) -> crate::FuncId {
    let mut b = FuncBuilder::new(module);
    let v = lower_expr(&mut b, expr);
    b.terminate(Terminator::Return(Some(v)));
    let func = b.finish(name, name, crate::TypeRef::unit());
    push_func(module, func)
}

/// Lower a block as a 0-arg synthetic function. The block's trailing
/// expression becomes the implicit return value.
pub fn lower_block_as_thunk(
    module: &mut crate::Module,
    block: &klio_ast::Block,
    name: &str,
) -> crate::FuncId {
    let mut b = FuncBuilder::new(module);
    let v = lower_block(&mut b, block);
    b.terminate(Terminator::Return(Some(v)));
    let func = b.finish(name, name, crate::TypeRef::unit());
    push_func(module, func)
}

/// 1-arg block thunk for setter bodies.
pub fn lower_block_as_unary_thunk(
    module: &mut crate::Module,
    param_name: &str,
    block: &klio_ast::Block,
    name: &str,
) -> crate::FuncId {
    let mut b = FuncBuilder::new(module);
    bind_params(&mut b, &[param_name]);
    let v = lower_block(&mut b, block);
    b.terminate(Terminator::Return(Some(v)));
    let func = b.finish(name, name, crate::TypeRef::unit());
    push_func(module, func)
}

/// Lower an expression as a 2-arg synthetic function bound under
/// the supplied parameter names. Used for instance accessors whose
/// first arg is `this` and second is the new value.
pub fn lower_binary_expr_as_thunk(
    module: &mut crate::Module,
    param_a: &str,
    param_b: &str,
    expr: &Expr,
    name: &str,
) -> crate::FuncId {
    let mut b = FuncBuilder::new(module);
    bind_params(&mut b, &[param_a, param_b]);
    let v = lower_expr(&mut b, expr);
    b.terminate(Terminator::Return(Some(v)));
    let func = b.finish(name, name, crate::TypeRef::unit());
    push_func(module, func)
}

pub fn lower_expr_as_param_thunk(
    module: &mut crate::Module,
    params: &[&str],
    expr: &Expr,
    name: &str,
) -> crate::FuncId {
    lower_expr_as_param_thunk_scoped::<std::collections::hash_map::RandomState>(
        module, params, expr, name, None, None,
    )
}

/// Like [`lower_expr_as_param_thunk`] but additionally puts the
/// enclosing class's name and own-member set in scope.
pub fn lower_expr_as_param_thunk_scoped<S: BuildHasher>(
    module: &mut crate::Module,
    params: &[&str],
    expr: &Expr,
    name: &str,
    owner_class: Option<&str>,
    own_members: Option<&std::collections::HashSet<String, S>>,
) -> crate::FuncId {
    let mut b = FuncBuilder::new(module);
    bind_params(&mut b, params);
    b.set_param_thunk(true);
    if let Some(owner) = owner_class {
        let () = b.set_owner_class(owner.to_string());
    }
    if let Some(set) = own_members {
        let () = b.set_own_members(set.iter().cloned().collect());
    }
    let v = lower_expr(&mut b, expr);
    b.terminate(Terminator::Return(Some(v)));
    let func = b.finish(name, name, crate::TypeRef::unit());
    push_func(module, func)
}

/// Lower an init-style block with arbitrary bound parameter names.
pub fn lower_init_block_with_params<S: BuildHasher>(
    module: &mut crate::Module,
    owner_class: &str,
    own_members: &std::collections::HashSet<String, S>,
    params: &[&str],
    block: &klio_ast::Block,
    name: &str,
) -> crate::FuncId {
    let mut b = FuncBuilder::new(module);
    let () = b.set_owner_class(owner_class.to_string());
    let () = b.set_own_members(own_members.iter().cloned().collect());
    bind_params(&mut b, params);
    let v = lower_block(&mut b, block);
    b.terminate(Terminator::Return(Some(v)));
    let func = b.finish(name, name, crate::TypeRef::unit());
    push_func(module, func)
}

/// Lower a function shell that takes the named params and returns Unit.
pub fn lower_empty_thunk(module: &mut crate::Module, params: &[&str], name: &str) -> crate::FuncId {
    let mut b = FuncBuilder::new(module);
    bind_params(&mut b, params);
    let unit = b.emit_const(Const::Unit);
    b.terminate(Terminator::Return(Some(unit)));
    let func = b.finish(name, name, crate::TypeRef::unit());
    push_func(module, func)
}

/// Lower a class init block as a 1-arg IR function whose only
/// parameter binds `this`.
pub fn lower_init_block<S: BuildHasher>(
    module: &mut crate::Module,
    owner_class: &str,
    own_members: &std::collections::HashSet<String, S>,
    block: &klio_ast::Block,
    name: &str,
) -> crate::FuncId {
    let mut b = FuncBuilder::new(module);
    let () = b.set_owner_class(owner_class.to_string());
    let () = b.set_own_members(own_members.iter().cloned().collect());
    bind_params(&mut b, &["this"]);
    let v = lower_block(&mut b, block);
    b.terminate(Terminator::Return(Some(v)));
    let func = b.finish(name, name, crate::TypeRef::unit());
    push_func(module, func)
}

/// Lower an instance accessor body.
pub fn lower_accessor_expr<S: BuildHasher>(
    module: &mut crate::Module,
    owner_class: &str,
    own_members: &std::collections::HashSet<String, S>,
    params: &[&str],
    expr: &Expr,
    name: &str,
) -> crate::FuncId {
    lower_accessor_expr_with_expected(module, owner_class, own_members, params, expr, name, None)
}

/// Like [`lower_accessor_expr`] but seeds the tail-position expected
/// type so a reified inline call in the body (a member property
/// initializer `val key: AttributeKey<T> = AttributeKey(name)`) infers
/// its type argument from the property's declared type — the same hint
/// a local `val x: T = …` already supplies.
pub fn lower_accessor_expr_with_expected<S: BuildHasher>(
    module: &mut crate::Module,
    owner_class: &str,
    own_members: &std::collections::HashSet<String, S>,
    params: &[&str],
    expr: &Expr,
    name: &str,
    expected: Option<klio_ast::TypeRef>,
) -> crate::FuncId {
    let mut b = FuncBuilder::new(module);
    let () = b.set_owner_class(owner_class.to_string());
    // The accessor body runs with `this` of type `owner_class`, so a bare
    // call inside resolves against that receiver — record it so the
    // overload/inline resolver prefers a member of the receiver over a
    // same-named imported extension with a different receiver type (e.g.
    // `get(Job)` inside `CoroutineContext.job` binds the context's `get`
    // operator, not ktor's inline `HttpClient.get`).
    let () = b.set_recv_ty(Some(owner_class.to_string()));
    let () = b.set_own_members(own_members.iter().cloned().collect());
    bind_params(&mut b, params);
    let prev = b.push_expected(expected);
    let v = lower_expr(&mut b, expr);
    b.restore_expected(prev);
    b.terminate(Terminator::Return(Some(v)));
    let mut func = b.finish(name, name, crate::TypeRef::unit());
    func.params = accessor_params(params);
    push_func(module, func)
}

/// Record the accessor's bound parameters as `Func.params` so the eval
/// `this`-parameter fallback can recover the receiver.
fn accessor_params(params: &[&str]) -> Vec<crate::Param> {
    params
        .iter()
        .map(|n| crate::Param {
            name: (*n).to_string(),
            ty: crate::TypeRef::unit(),
            default: None,
            is_property: false,
            is_vararg: false,
            has_default: false,
        })
        .collect()
}

/// Variant of `lower_accessor_expr` for block-body accessors.
pub fn lower_accessor_block<S: BuildHasher>(
    module: &mut crate::Module,
    owner_class: &str,
    own_members: &std::collections::HashSet<String, S>,
    params: &[&str],
    block: &klio_ast::Block,
    name: &str,
) -> crate::FuncId {
    let mut b = FuncBuilder::new(module);
    let () = b.set_owner_class(owner_class.to_string());
    let () = b.set_recv_ty(Some(owner_class.to_string()));
    let () = b.set_own_members(own_members.iter().cloned().collect());
    bind_params(&mut b, params);
    let v = lower_block(&mut b, block);
    b.terminate(Terminator::Return(Some(v)));
    let func = b.finish(name, name, crate::TypeRef::unit());
    push_func(module, func)
}

pub fn lower_unary_expr_as_thunk(
    module: &mut crate::Module,
    param_name: &str,
    expr: &Expr,
    name: &str,
) -> crate::FuncId {
    let mut b = FuncBuilder::new(module);
    bind_params(&mut b, &[param_name]);
    let v = lower_expr(&mut b, expr);
    b.terminate(Terminator::Return(Some(v)));
    let func = b.finish(name, name, crate::TypeRef::unit());
    push_func(module, func)
}
