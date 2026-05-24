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

/// Bind function parameters into the current scope. Each param is
/// loaded into a fresh register via `Inst::LoadParam` so subsequent
/// `Path { name }` reads route through the same register.
/// Materialise a contiguous run of argument registers for a Call /
/// CallMember / CallValue / NewInstance instruction.
///
/// The lowering pass otherwise produces non-contiguous register
/// numbering when sub-expressions allocate intermediate temporaries.
/// We reserve `args.len()` contiguous registers up front (so the
/// run [args_start, args_start + n_args) is dense), lower each arg
/// into its own scratch reg, then `Move` the scratch into the
/// matching arg slot. Returns `(args_start, n_args)`.
/// Treat a path segment as a package-root identifier when it starts
/// with a lowercase letter — Kotlin convention reserves lowercase
/// roots for packages (`kotlin`, `kotlinx`, `java`, …) and capital
/// initials for class / object names. Limiting FQN-flattening to
/// lowercase heads keeps `Status.Active` / `Foo.Companion` member
/// access routed through GetField on the actual class value.
/// True when `arg` is a lambda whose body assigns to a name that
/// the IR's current scope shadows or knows as an outer capture.
/// True when `e` is `expr as Any` (or transitively wraps one through
/// trivial parens / binding) — mirrors tree walker's
/// `is_boxed_to_any_form` heuristic.
fn is_any_typed_path(b: &FuncBuilder<'_>, e: &Expr) -> bool {
    matches!(e, Expr::Path { segments, .. } if segments.len() == 1 && b.is_any_typed(&segments[0].name))
}

// `is_boxed_to_any_form` lives in `ast_scan.rs`.

/// Collect every outer-scope variable name a lambda's body
/// directly mutates (assignment / `++` / `--`). Returns an empty
/// vec for non-lambda args. Used by the closure-mutation
/// writeback path to know which captured names to sync back to
/// the caller's regs after a HOF call returns.
fn lambda_mutated_outer_vars(b: &FuncBuilder<'_>, arg: &Expr) -> Vec<String> {
    let Expr::Lambda { body, .. } = arg else { return Vec::new(); };
    let visible = b.visible_names();
    let mut out: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    fn walk(
        stmt: &klio_ast::Stmt,
        visible: &std::collections::HashSet<String>,
        out: &mut std::collections::BTreeSet<String>,
    ) {
        match stmt {
            klio_ast::Stmt::Assign { target, .. } => {
                if let Expr::Path { segments, .. } = target {
                    if segments.len() == 1 && visible.contains(&segments[0].name) {
                        out.insert(segments[0].name.clone());
                    }
                }
            }
            klio_ast::Stmt::Expr(e) => walk_expr(e, visible, out),
            _ => {}
        }
    }
    fn visit_path(
        e: &Expr,
        visible: &std::collections::HashSet<String>,
        out: &mut std::collections::BTreeSet<String>,
    ) {
        if let Expr::Path { segments, .. } = e {
            if segments.len() == 1 && visible.contains(&segments[0].name) {
                out.insert(segments[0].name.clone());
            }
        }
    }
    fn walk_expr(
        e: &Expr,
        visible: &std::collections::HashSet<String>,
        out: &mut std::collections::BTreeSet<String>,
    ) {
        match e {
            Expr::Postfix { op, expr, .. } => {
                if matches!(op, klio_ast::PostfixOp::Inc | klio_ast::PostfixOp::Dec) {
                    visit_path(expr, visible, out);
                }
            }
            Expr::Unary { op, expr, .. } => {
                if matches!(op, klio_ast::UnOp::PreInc | klio_ast::UnOp::PreDec) {
                    visit_path(expr, visible, out);
                }
            }
            Expr::Block(b) => { for s in &b.stmts { walk(s, visible, out); } }
            Expr::If { cond, then_branch, else_branch, .. } => {
                walk_expr(cond, visible, out);
                walk_expr(then_branch, visible, out);
                if let Some(e) = else_branch { walk_expr(e, visible, out); }
            }
            Expr::While { cond, body, .. } => {
                walk_expr(cond, visible, out);
                walk_expr(body, visible, out);
            }
            Expr::DoWhile { body, cond, .. } => {
                if let Some(b) = body { walk_expr(b, visible, out); }
                walk_expr(cond, visible, out);
            }
            Expr::For { body, .. } => walk_expr(body, visible, out),
            Expr::When { branches, .. } => {
                for br in branches { walk_expr(&br.body, visible, out); }
            }
            Expr::Try { body, catches, finally, .. } => {
                for s in &body.stmts { walk(s, visible, out); }
                for c in catches { for s in &c.body.stmts { walk(s, visible, out); } }
                if let Some(b) = finally { for s in &b.stmts { walk(s, visible, out); } }
            }
            _ => {}
        }
    }
    for s in &body.stmts {
        walk(s, &visible, &mut out);
    }
    out.into_iter().collect()
}

fn lambda_writes_outer_var(b: &FuncBuilder<'_>, arg: &Expr) -> bool {
    let body = match arg {
        Expr::Lambda { body, .. } => body,
        _ => return false,
    };
    let visible = b.visible_names();
    fn walk(stmt: &klio_ast::Stmt, visible: &std::collections::HashSet<String>) -> bool {
        match stmt {
            klio_ast::Stmt::Assign { target, .. } => {
                if let Expr::Path { segments, .. } = target {
                    if segments.len() == 1 && visible.contains(&segments[0].name) {
                        return true;
                    }
                }
                false
            }
            klio_ast::Stmt::Expr(e) => walk_expr(e, visible),
            _ => false,
        }
    }
    // Postfix `x++` / `x--` and prefix `++x` / `--x` on a Path
    // visible from the outer scope mutate that var. Also count
    // `return` from inside the lambda body: when the bare `return`
    // resolves to a non-local return (e.g. `forEach` lambda
    // returning from the enclosing function), the IR's lambda
    // would translate it as a local return and lose the semantics.
    fn is_path_outer(e: &Expr, visible: &std::collections::HashSet<String>) -> bool {
        matches!(e, Expr::Path { segments, .. } if segments.len() == 1 && visible.contains(&segments[0].name))
    }
    fn walk_expr(e: &Expr, visible: &std::collections::HashSet<String>) -> bool {
        match e {
            Expr::Postfix { op, expr, .. } => {
                matches!(op, klio_ast::PostfixOp::Inc | klio_ast::PostfixOp::Dec)
                    && is_path_outer(expr, visible)
            }
            Expr::Unary { op, expr, .. } => {
                matches!(op, klio_ast::UnOp::PreInc | klio_ast::UnOp::PreDec)
                    && is_path_outer(expr, visible)
            }
            Expr::Return { .. } => {
                // Non-local return from inside the lambda body
                // propagates as `EvalError::NonLocalReturn` through
                // the host's `call_value_named`; the enclosing IR
                // fn frame catches it. No EvalAst fallback needed.
                false
            }
            Expr::Block(b) => b.stmts.iter().any(|s| walk(s, visible)),
            Expr::If { cond, then_branch, else_branch, .. } => {
                walk_expr(cond, visible)
                    || walk_expr(then_branch, visible)
                    || else_branch.as_ref().map_or(false, |e| walk_expr(e, visible))
            }
            Expr::While { cond, body, .. } => {
                walk_expr(cond, visible) || walk_expr(body, visible)
            }
            Expr::DoWhile { body, cond, .. } => {
                body.as_ref().map_or(false, |b| walk_expr(b, visible))
                    || walk_expr(cond, visible)
            }
            Expr::For { body, .. } => walk_expr(body, visible),
            Expr::When { branches, .. } => branches.iter().any(|br| walk_expr(&br.body, visible)),
            Expr::Try { body, catches, finally, .. } => {
                body.stmts.iter().any(|s| walk(s, visible))
                    || catches
                        .iter()
                        .any(|c| c.body.stmts.iter().any(|s| walk(s, visible)))
                    || finally
                        .as_ref()
                        .map_or(false, |b| b.stmts.iter().any(|s| walk(s, visible)))
            }
            _ => false,
        }
    }
    body.stmts.iter().any(|s| walk(s, &visible))
}

// `collect_path_idents{,_stmt}`, `names_referenced_in_lambdas`,
// `collect_var_decls`, `compute_boxed_vars`, and `collect_dotted_fqn`
// live in `ast_scan.rs`.

/// Resolve the register holding the shared `Value::Cell` for a boxed
/// `var`. In the declaring scope the cell lives in the var's
/// `mutable_home`; once a capturing lambda has loaded it the name is
/// rebound to that reg; otherwise it is captured from the enclosing
/// frame so every closure shares the same cell.
fn boxed_cell_reg(b: &mut FuncBuilder, name: &str) -> Reg {
    if let Some(r) = b.mutable_home(name) {
        r
    } else if let Some(r) = b.resolve(name) {
        r
    } else {
        let idx = b.record_capture(name);
        let c = b.alloc_reg();
        b.push(Inst::LoadCapture { dst: c, idx });
        b.bind(name.to_string(), c);
        c
    }
}

fn lower_arg_run(b: &mut FuncBuilder<'_>, args: &[Expr]) -> (Reg, u8) {
    let n = args.len();
    if n == 0 {
        // Reserve a sentinel slot so the n_args=0 reads do not
        // alias an unrelated register.
        return (b.alloc_reg(), 0);
    }
    let first = b.alloc_reg();
    let mut slots = Vec::with_capacity(n);
    slots.push(first);
    for _ in 1..n {
        slots.push(b.alloc_reg());
    }
    for (slot, arg) in slots.iter().zip(args.iter()) {
        let r = lower_expr(b, arg);
        b.push(Inst::Move { dst: *slot, src: r });
    }
    (first, n as u8)
}

/// Intern an `arg_names` slice into a parallel `Vec<Option<ConstId>>`
/// suitable for Inst::Call / CallMember / CallValue / NewInstance.
/// Returns an empty vec when every entry is None (positional-only).
fn intern_arg_names(
    module: &mut crate::Module,
    arg_names: &[Option<String>],
) -> Vec<Option<crate::ConstId>> {
    if arg_names.iter().all(|o| o.is_none()) {
        return Vec::new();
    }
    arg_names
        .iter()
        .map(|opt| opt.as_ref().map(|s| module.intern_const(Const::String(s.clone()))))
        .collect()
}

fn intern_type_args(
    module: &mut crate::Module,
    type_args: &[klio_ast::TypeRef],
) -> Vec<crate::ConstId> {
    if type_args.is_empty() {
        return Vec::new();
    }
    type_args
        .iter()
        .map(|t| module.intern_const(Const::String(t.name.name.clone())))
        .collect()
}

/// Lower an arbitrary expression as a 0-arg synthetic function whose
/// body returns the expression's value. The synthetic function is
/// pushed onto the module so a downstream caller can invoke it via
/// `eval_with` against `module.funcs[id]`.
pub fn bind_params(b: &mut FuncBuilder<'_>, names: &[&str]) {
    for (i, name) in names.iter().enumerate() {
        let dst = b.alloc_reg();
        b.push(Inst::LoadParam { dst, idx: i as u16 });
        b.bind(*name, dst);
        b.mark_param(name);
    }
}

/// Lower a Kotlin class declaration into an IR Class. Methods are
/// lowered as Funcs with a synthetic `<receiver>` first parameter
/// (the constructor params are lifted onto the Class's
/// primary_params for instance construction). The Class becomes
/// reachable through `module.class_id` so Path-callees that name
/// the class lower to `NewInstance`.
pub fn lower_class(module: &mut crate::Module, c: &klio_ast::Class) -> crate::ClassId {
    let empty = std::collections::HashMap::new();
    lower_class_with_file(module, c, &empty)
}

pub fn lower_class_with_file(
    module: &mut crate::Module,
    c: &klio_ast::Class,
    file_classes: &std::collections::HashMap<String, &klio_ast::Class>,
) -> crate::ClassId {
    lower_class_with_extras(module, c, file_classes, &std::collections::HashSet::new())
}

/// Like [`lower_class_with_extras`] but stamps the IR class with a
/// caller-supplied package-qualified FQN. Two packages may declare
/// the same simple class name; a distinct FQN lets `add_class` keep
/// them as separate definitions instead of collapsing one onto the
/// other.
pub fn lower_class_with_extras_fqn(
    module: &mut crate::Module,
    c: &klio_ast::Class,
    file_classes: &std::collections::HashMap<String, &klio_ast::Class>,
    extra_members: &std::collections::HashSet<String>,
    class_fqn: &str,
) -> crate::ClassId {
    LOWER_CLASS_FQN.with(|f| *f.borrow_mut() = Some(class_fqn.to_string()));
    let id = lower_class_with_extras(module, c, file_classes, extra_members);
    LOWER_CLASS_FQN.with(|f| *f.borrow_mut() = None);
    id
}

thread_local! {
    /// Package-qualified FQN for the class currently being lowered by
    /// `lower_class_with_extras_fqn`. Read once where the IR `Class`
    /// shell is created. A thread-local keeps the existing public
    /// signatures (and their other callers/tests) unchanged.
    static LOWER_CLASS_FQN: std::cell::RefCell<Option<String>> =
        const { std::cell::RefCell::new(None) };
}

thread_local! {
    /// Names captured by the anonymous object whose method is being
    /// lowered (`object : Flow { collect(c) { c.block() } }` where
    /// `block` is an enclosing inline fn's crossinline param). These
    /// reach the method body as runtime-injected scoped globals, so a
    /// `recv.name()` whose `name` is one of them must dispatch as
    /// CallMemberOrValue with a `LoadGlobal(name)` fallback (the
    /// receiver's member wins if present, else the captured callable
    /// is invoked with the receiver bound). A thread-local keeps
    /// `lower_method`'s public signature (and its other callers)
    /// unchanged.
    static LOWER_ANON_CAPTURES: std::cell::RefCell<Option<std::collections::HashSet<String>>> =
        const { std::cell::RefCell::new(None) };
}

/// Set (or clear) the anon-object captured-name set consulted while
/// lowering that object's method bodies.
pub fn set_lower_anon_captures(
    names: Option<std::collections::HashSet<String>>,
) {
    LOWER_ANON_CAPTURES.with(|c| *c.borrow_mut() = names);
}

fn is_lower_anon_capture(name: &str) -> bool {
    LOWER_ANON_CAPTURES
        .with(|c| c.borrow().as_ref().map(|s| s.contains(name)).unwrap_or(false))
}

/// Same as `lower_class_with_file` but mixes an additional set of
/// member names into the class's `own_members`. Used when a nested
/// class is lifted to top level: the outer's property + method
/// names are added so bare references inside the inner's body
/// lower as `this.X` (resolved against the captured outer at
/// runtime) instead of `LoadGlobal(X)`.
pub fn lower_class_with_extras(
    module: &mut crate::Module,
    c: &klio_ast::Class,
    file_classes: &std::collections::HashMap<String, &klio_ast::Class>,
    extra_members: &std::collections::HashSet<String>,
) -> crate::ClassId {
    let primary_params: Vec<crate::Param> = c
        .primary_params
        .iter()
        .map(|p| crate::Param {
            name: p.name.name.clone(),
            ty: crate::TypeRef::unit(),
            default: None,
            is_property: p.property.is_some(),
            is_vararg: p.is_vararg,
        })
        .collect();
    // Register the class shell first so the class name resolves
    // inside its own method bodies (`class Foo { fun copy() = Foo(...) }`).
    let class_fqn = LOWER_CLASS_FQN
        .with(|f| f.borrow().clone())
        .unwrap_or_else(|| c.name.name.clone());
    let class_id = module.add_class(crate::Class {
        id: crate::ClassId(0),
        name: c.name.name.clone(),
        fqn: class_fqn,
        primary_params,
        methods: Vec::new(),
        init_block: None,
        companion: None,
        supertypes: Vec::new(),
    });
    // Collect this class's own member names so method-body
    // lowering can tell `someMember()` (this.someMember) apart
    // from `topLevelFn()` (LoadGlobal).
    let mut own_member_names: std::collections::HashSet<String> = extra_members.clone();
    // Walk this class + every supertype reachable through the
    // file's class registry so inherited member names also
    // route as `this.<name>` in method-body lowering.
    fn collect_members(
        c: &klio_ast::Class,
        file_classes: &std::collections::HashMap<String, &klio_ast::Class>,
        out: &mut std::collections::HashSet<String>,
        seen: &mut std::collections::HashSet<String>,
    ) {
        if !seen.insert(c.name.name.clone()) {
            return;
        }
        for m in &c.members {
            match m {
                klio_ast::Decl::Function(f) => {
                    out.insert(f.name.name.clone());
                }
                klio_ast::Decl::Property(p) => {
                    out.insert(p.name.name.clone());
                }
                klio_ast::Decl::Class(inner) if inner.is_companion => {
                    for cm in &inner.members {
                        match cm {
                            klio_ast::Decl::Function(f) => {
                                out.insert(f.name.name.clone());
                            }
                            klio_ast::Decl::Property(p) => {
                                out.insert(p.name.name.clone());
                            }
                            _ => {}
                        }
                    }
                    for p in &inner.primary_params {
                        if p.property.is_some() {
                            out.insert(p.name.name.clone());
                        }
                    }
                }
                _ => {}
            }
        }
        for p in &c.primary_params {
            if p.property.is_some() {
                out.insert(p.name.name.clone());
            }
        }
        for sup in &c.supertypes {
            if let Some(parent) = file_classes.get(&sup.name.name) {
                collect_members(parent, file_classes, out, seen);
            }
        }
    }
    let mut seen_for_collect: std::collections::HashSet<String> = std::collections::HashSet::new();
    collect_members(c, file_classes, &mut own_member_names, &mut seen_for_collect);
    // Enum entry names are visible under their bare names
    // inside the enum's method bodies (e.g. `RED` in a
    // `Color.hex()` method). `entries` resolves to the
    // built-in synthesized list of all entries.
    if c.is_enum {
        for entry in &c.enum_entries {
            own_member_names.insert(entry.name.name.clone());
        }
        // Built-in members on every enum entry: synthesised
        // `name` (entry simple name) and `ordinal` (declaration
        // index). Bare access from method bodies resolves to
        // `this.name` / `this.ordinal`.
        own_member_names.insert("entries".to_string());
        own_member_names.insert("name".to_string());
        own_member_names.insert("ordinal".to_string());
    }
    // Nested class / enum / object names are visible under
    // their bare names inside the enclosing class's method
    // bodies (e.g. `TrafficLight.State.RED` reachable as
    // `State.RED` from a TrafficLight method).
    for m in &c.members {
        if let klio_ast::Decl::Class(inner) = m {
            if !inner.is_companion {
                own_member_names.insert(inner.name.name.clone());
            }
        }
    }
    // Companion-object members are visible under their bare
    // names inside this class's method bodies.
    for m in &c.members {
        if let klio_ast::Decl::Class(inner) = m {
            if inner.is_companion {
                for cm in &inner.members {
                    match cm {
                        klio_ast::Decl::Function(f) => {
                            own_member_names.insert(f.name.name.clone());
                        }
                        klio_ast::Decl::Property(p) => {
                            own_member_names.insert(p.name.name.clone());
                        }
                        _ => {}
                    }
                }
                for p in &inner.primary_params {
                    if p.property.is_some() {
                        own_member_names.insert(p.name.name.clone());
                    }
                }
            }
        }
    }
    let mut methods: Vec<crate::FuncId> = Vec::new();
    // Track private methods lowered so far in declaration order so a
    // later method's body can statically bind to an earlier private
    // sibling's FuncId rather than virtual-dispatching it (Kotlin:
    // private members are invisible to subclasses, so the dispatch
    // is fixed to the declaring class). Forward-references would
    // need a reservation pass; the common case (helper declared
    // before its caller) is covered.
    let mut private_method_fids: std::collections::HashMap<String, crate::FuncId> =
        std::collections::HashMap::new();
    for m in &c.members {
        if let klio_ast::Decl::Function(f) = m {
            // Skip bodyless methods (abstract decls in
            // interfaces / abstract classes). They'd lower to a
            // func that just returns Unit; the IR-native member
            // dispatch must fall through to the real override
            // on a concrete subclass, not the abstract slot.
            if f.body.is_none() {
                // The abstract slot itself is skipped, but a concrete
                // `override` inherits this declaration's default-arg
                // values. Lower the default thunks and stash them by
                // (class, method) so the build pass can fold them onto
                // the override's own (default-less) parameter slots.
                if f.params.iter().any(|p| p.default.is_some()) {
                    let mut names: Vec<String> =
                        Vec::with_capacity(f.params.len() + 1);
                    names.push("this".to_string());
                    names.extend(
                        f.params.iter().map(|p| p.name.name.clone()),
                    );
                    let name_refs: Vec<&str> =
                        names.iter().map(String::as_str).collect();
                    let mut slots: Vec<Option<crate::FuncId>> =
                        Vec::with_capacity(names.len());
                    slots.push(None); // implicit `this`
                    for (idx, p) in f.params.iter().enumerate() {
                        if let Some(de) = &p.default {
                            let bind_upto =
                                (1 + idx).min(name_refs.len());
                            let widened =
                                widen_numeric_literal(de, &p.ty);
                            let fid = lower_expr_as_param_thunk(
                                module,
                                &name_refs[..bind_upto],
                                widened.as_ref().unwrap_or(de),
                                &format!(
                                    "__default_abstract_{}_{}",
                                    f.name.name, p.name.name
                                ),
                            );
                            slots.push(Some(fid));
                        } else {
                            slots.push(None);
                        }
                    }
                    module
                        .registry
                        .abstract_member_defaults
                        .insert(
                            (c.name.name.clone(), f.name.name.clone()),
                            slots,
                        );
                }
                continue;
            }
            // Use the method's own FuncId, not `funcs.len() - 1`:
            // lowering a method also pushes its default-arg thunk
            // funcs, so the last slot is no longer the method body.
            let placed = lower_method_with_private(
                module, f, &c.name.name, &own_member_names, &private_method_fids,
            );
            methods.push(placed.id);
            if matches!(f.visibility, klio_ast::Visibility::Private) {
                private_method_fids.insert(f.name.name.clone(), placed.id);
            }
        }
    }
    let supertypes: Vec<crate::ClassId> = c
        .supertypes
        .iter()
        .filter_map(|t| module.class_id(&t.name.name))
        .collect();
    // Patch the registered class with its now-known method list
    // and resolved supertypes.
    if let Some(slot) = module.classes.get_mut(class_id.0 as usize) {
        slot.methods = methods;
        slot.supertypes = supertypes;
    }
    class_id
}

/// Lower one AST function into an IR Func. The function body is
/// lowered into the entry block; parameters are bound via
/// `bind_params`; the trailing implicit return falls through to a
/// `Return` terminator.
pub fn lower_function(module: &mut crate::Module, f: &klio_ast::Function) -> crate::Func {
    let empty = std::collections::HashMap::new();
    lower_function_with_file(module, f, &empty)
}

pub fn lower_function_with_file(
    module: &mut crate::Module,
    f: &klio_ast::Function,
    file_classes: &std::collections::HashMap<String, &klio_ast::Class>,
) -> crate::Func {
    let func = lower_function_body(module, f, file_classes);
    let id = crate::FuncId(module.funcs.len() as u32);
    let mut placed = func;
    placed.id = id;
    let nm = f.name.name.clone();
    module.func_index.push((nm.clone(), id));
    module.func_name_index.entry(nm).or_default().push(id);
    module.funcs.push(placed.clone());
    placed
}

/// Lower a function body without registering it in `module.func_index`.
/// Used by the interpreter's pre-pass-then-fill driver so a function's
/// FuncId is reserved before its body is lowered (enabling forward
/// references and mutual recursion).
pub fn lower_function_body_into(
    module: &mut crate::Module,
    f: &klio_ast::Function,
    file_classes: &std::collections::HashMap<String, &klio_ast::Class>,
) -> crate::Func {
    lower_function_body(module, f, file_classes)
}

/// Lowered name for a parameter's declared type. A function type
/// `(A, B) -> R` is tagged `Function2` (arity = number of parameters,
/// receiver excluded) so runtime overload resolution can match a
/// lambda argument by its parameter count — the only way to tell
/// apart overloads that differ solely in the shape of a functional
/// parameter.
fn lowered_type_name(ty: &klio_ast::TypeRef) -> String {
    if let Some(ft) = &ty.function {
        return format!("Function{}", ft.params.len());
    }
    ty.name.name.clone()
}

fn lower_function_body(
    module: &mut crate::Module,
    f: &klio_ast::Function,
    file_classes: &std::collections::HashMap<String, &klio_ast::Class>,
) -> crate::Func {
    // Extension functions (`fun T.foo(...)`) need `this` bound
    // as the implicit first param so the body's references to
    // `this` and `this.x` resolve through the receiver reg
    // rather than as a free global. Plain top-level functions
    // have no receiver, so no implicit params.
    if let Some(recv) = &f.receiver_type {
        let mut members: std::collections::HashSet<String> = std::collections::HashSet::new();
        if let Some(parent_cls) = file_classes.get(&recv.name.name) {
            let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
            fn collect_recv_members(
                c: &klio_ast::Class,
                file_classes: &std::collections::HashMap<String, &klio_ast::Class>,
                out: &mut std::collections::HashSet<String>,
                seen: &mut std::collections::HashSet<String>,
            ) {
                if !seen.insert(c.name.name.clone()) {
                    return;
                }
                for m in &c.members {
                    match m {
                        klio_ast::Decl::Function(f) => {
                            out.insert(f.name.name.clone());
                        }
                        klio_ast::Decl::Property(p) => {
                            out.insert(p.name.name.clone());
                        }
                        _ => {}
                    }
                }
                for p in &c.primary_params {
                    if p.property.is_some() {
                        out.insert(p.name.name.clone());
                    }
                }
                for sup in &c.supertypes {
                    if let Some(parent) = file_classes.get(&sup.name.name) {
                        collect_recv_members(parent, file_classes, out, seen);
                    }
                }
            }
            collect_recv_members(parent_cls, file_classes, &mut members, &mut seen);
        }
        lower_function_body_with_implicit_owner(
            module,
            f,
            &["this"],
            None,
            Some(&members),
        )
    } else {
        lower_function_body_with_implicit_owner(module, f, &[], None, None)
    }
}

/// Lower a method body with `this` bound as the implicit first
/// parameter. Used by `lower_class` so method bodies' references
/// to `this`, `this.x`, etc. resolve correctly in the IR.
/// Unlike `lower_function`, this does NOT register the func in
/// `func_index` — method names live in the class's method table,
/// not the top-level fn namespace, so a top-level Path-callee
/// lookup must not surface a class method.
/// Record a class method's per-parameter default-arg thunks under its
/// body FuncId, so a call that omits trailing defaulted args
/// (`A().g(5)` for `fun g(x, y = 10)`) gets them filled — the same
/// padding top-level / local functions already get. Methods carry an
/// implicit leading `this`, so default slots are offset by one.
fn record_method_param_defaults(
    module: &mut crate::Module,
    f: &klio_ast::Function,
    body_func: crate::FuncId,
    owner_class: Option<&str>,
    own_members: Option<&std::collections::HashSet<String>>,
) {
    if !f.params.iter().any(|p| p.default.is_some()) {
        return;
    }
    let mut names: Vec<String> = Vec::with_capacity(f.params.len() + 1);
    names.push("this".to_string());
    names.extend(f.params.iter().map(|p| p.name.name.clone()));
    let name_refs: Vec<&str> = names.iter().map(String::as_str).collect();
    let mut slots: Vec<Option<crate::FuncId>> = Vec::with_capacity(names.len());
    slots.push(None); // implicit `this`
    for (idx, p) in f.params.iter().enumerate() {
        if let Some(default_expr) = &p.default {
            let bind_upto = (1 + idx).min(name_refs.len());
            let widened = widen_numeric_literal(default_expr, &p.ty);
            // Pass the owner class + own-member set so a default
            // expression that references an enclosing-class member
            // (`fun mix(a, b=a*2, c=base+b)` where `base` is a class
            // member) routes the bare name through `this.<member>`
            // instead of an unresolved global lookup.
            let fid = lower_expr_as_param_thunk_scoped(
                module,
                &name_refs[..bind_upto],
                widened.as_ref().unwrap_or(default_expr),
                &format!("__default_method_{}_{}", f.name.name, p.name.name),
                owner_class,
                own_members,
            );
            slots.push(Some(fid));
        } else {
            slots.push(None);
        }
    }
    module.registry.local_fn_defaults.insert(body_func, slots);
}

pub fn lower_method(
    module: &mut crate::Module,
    f: &klio_ast::Function,
    owner_class: &str,
    own_members: &std::collections::HashSet<String>,
) -> crate::Func {
    lower_method_with_private(module, f, owner_class, own_members, &std::collections::HashMap::new())
}

pub fn lower_method_with_private(
    module: &mut crate::Module,
    f: &klio_ast::Function,
    owner_class: &str,
    own_members: &std::collections::HashSet<String>,
    private_method_fids: &std::collections::HashMap<String, crate::FuncId>,
) -> crate::Func {
    // A member extension function (`class C { fun R.f(p) { … } }`)
    // binds its *extension* receiver as `this`, like a top-level
    // extension fn. A bare member reference in its body may be a
    // member of the extension receiver `R` *or* of the enclosing
    // class `C` (`this@C`). Passing `C`'s `own_members` here would
    // force every such reference into a `this.member` access on the
    // *extension* receiver, so `C` members fail. Pass no own-members
    // instead: bare references then lower through the dynamic
    // `this` → enclosing-`this` → global probe, which tries `R`,
    // then the lexically enclosing `C` instance (kept reachable by
    // the caller via the enclosing-`this` stack), then a global.
    // It is also registered in `func_index` so a bare call resolves
    // through the same extension-call lowering top-level extensions
    // use (the receiver is prepended as the implicit `this`).
    if f.receiver_type.is_some() {
        let func = lower_function_body_with_implicit_owner(
            module,
            f,
            &["this"],
            None,
            None,
        );
        let id = crate::FuncId(module.funcs.len() as u32);
        let mut placed = func;
        placed.id = id;
        module.funcs.push(placed.clone());
        let nm = f.name.name.clone();
        module.func_index.push((nm.clone(), id));
        module.func_name_index.entry(nm).or_default().push(id);
        // Tag this member-extension with its declaring class so the
        // runtime extension-fallback dispatch can filter it out at
        // call sites whose enclosing class chain doesn't include
        // the declaring class.
        module
            .registry
            .member_ext_owner_class
            .insert(id, owner_class.to_string());
        // Extension member: no enclosing-class own-members in scope
        // (the receiver is `this`, not the declaring class), so the
        // thunk runs with no owner_class context.
        record_method_param_defaults(module, f, id, None, None);
        return placed;
    }
    let func = lower_function_body_with_implicit_owner_priv(
        module,
        f,
        &["this"],
        Some(owner_class),
        Some(own_members),
        Some(private_method_fids),
    );
    let id = crate::FuncId(module.funcs.len() as u32);
    let mut placed = func;
    placed.id = id;
    module.funcs.push(placed.clone());
    record_method_param_defaults(module, f, id, Some(owner_class), Some(own_members));
    placed
}

fn lower_function_body_with_implicit_owner(
    module: &mut crate::Module,
    f: &klio_ast::Function,
    implicit_params: &[&str],
    owner_class: Option<&str>,
    own_members: Option<&std::collections::HashSet<String>>,
) -> crate::Func {
    lower_function_body_with_implicit_owner_priv(
        module, f, implicit_params, owner_class, own_members, None,
    )
}

fn lower_function_body_with_implicit_owner_priv(
    module: &mut crate::Module,
    f: &klio_ast::Function,
    implicit_params: &[&str],
    owner_class: Option<&str>,
    own_members: Option<&std::collections::HashSet<String>>,
    private_method_fids: Option<&std::collections::HashMap<String, crate::FuncId>>,
) -> crate::Func {
    let mut b = FuncBuilder::new(module);
    let mut names: Vec<&str> = Vec::with_capacity(implicit_params.len() + f.params.len());
    names.extend_from_slice(implicit_params);
    names.extend(f.params.iter().map(|p| p.name.name.as_str()));
    bind_params(&mut b, &names);
    // A param whose declared type is a receiver-typed function
    // (`block: T.() -> R`) carries that fact so a bare call
    // `block(...)` inside the body lowers to a member-call with
    // the enclosing `this` as receiver. Implicit params (like the
    // class `this` injected for methods) never come in this shape,
    // so we only walk the source params.
    for p in &f.params {
        if p.ty
            .function
            .as_ref()
            .and_then(|ft| ft.receiver.as_ref())
            .is_some()
        {
            b.mark_receiver_lambda_param(&p.name.name);
        }
    }
    if let Some(owner) = owner_class {
        let _ = b.set_owner_class(owner.to_string());
    }
    if let Some(set) = own_members {
        let _ = b.set_own_members(set.clone());
    }
    if let Some(map) = private_method_fids {
        b.set_private_method_fids(map.clone());
    }
    if f.is_tailrec {
        let _ = b.set_tailrec_self(f.name.name.clone());
    }
    b.set_inline(f.is_inline);
    if let Some(klio_ast::FunctionBody::Block(blk)) = &f.body {
        b.set_boxed_vars(compute_boxed_vars(&blk.stmts));
    }
    let result = match &f.body {
        Some(klio_ast::FunctionBody::Block(blk)) => Some(lower_block(&mut b, blk)),
        Some(klio_ast::FunctionBody::Expr(e)) => Some(lower_expr(&mut b, e)),
        None => None,
    };
    b.terminate(Terminator::Return(result));
    let fqn = f.name.name.clone();
    let mut func = b.finish(f.name.name.clone(), fqn, crate::TypeRef::unit());
    let mut params: Vec<crate::Param> = implicit_params
        .iter()
        .map(|n| crate::Param {
            name: (*n).to_string(),
            ty: crate::TypeRef::unit(),
            default: None,
            is_property: false,
            is_vararg: false,
        })
        .collect();
    params.extend(f.params.iter().map(|p| crate::Param {
        name: p.name.name.clone(),
        ty: crate::TypeRef {
            name: lowered_type_name(&p.ty),
            nullable: p.ty.nullable,
            args: Vec::new(),
        },
        default: None,
        is_property: false,
        is_vararg: p.is_vararg,
    }));
    func.params = params;
    // An extension fn's synthetic receiver param (`this`) carries
    // the declared receiver type, not the `Unit` placeholder, so
    // runtime overload resolution can pick the right receiver
    // overload (`fun Int.f()` vs `fun Long.f()`) instead of falling
    // back to declaration order.
    if let Some(rt) = &f.receiver_type {
        if let Some(first) = func.params.first_mut() {
            if first.name == "this" {
                first.ty = crate::TypeRef {
                    name: lowered_type_name(rt),
                    nullable: rt.nullable,
                    args: Vec::new(),
                };
            }
        }
    }
    func.is_suspend = f.is_suspend;
    func
}

/// Lower one expression into the current block. Returns the
/// register holding the result. Statements that do not produce a
/// value (assignments, declarations) return a synthetic `Unit`
/// register so downstream code stays uniform.
/// Lower an expression that appears as the *receiver / qualifier
/// head* of a member access or call (`recv.member`, `recv.m()`,
/// `recv::ref`, `recv.x = v`). A bare single-segment class/interface
/// name here is a *qualifier* — it must stay the `Value::Class` so
/// nested-class (`Outer.Inner`) and companion-member forwarding work
/// — unlike the same Path in value position, which resolves to the
/// companion object. Everything else defers to `lower_expr`.
pub fn lower_receiver(b: &mut FuncBuilder<'_>, expr: &Expr) -> Reg {
    if let Expr::Path { segments, .. } = expr {
        if segments.len() == 1 {
            let n = &segments[0].name;
            if b.resolve(n).is_none()
                && !b.knows_outer(n)
                && b.module.class_id(n).is_some()
            {
                let dst = b.alloc_reg();
                let nm = b.module.intern_const(Const::String(n.clone()));
                b.push(Inst::LoadGlobal { dst, name: nm });
                return dst;
            }
        }
    }
    lower_expr(b, expr)
}

pub fn lower_expr(b: &mut FuncBuilder<'_>, expr: &Expr) -> Reg {
    match expr {
        Expr::IntLit { value, kind, .. } => {
            // Honour the literal's declared kind (`1L`, `1U`, `1uL`)
            // rather than letting the value range pick. The suffix
            // is what tells `is Long` apart from `is Int` for small
            // values.
            match kind {
                klio_ast::IntLitKind::Long => b.emit_const(Const::Long(*value)),
                klio_ast::IntLitKind::UInt => b.emit_const(Const::UInt(*value as u32)),
                klio_ast::IntLitKind::ULong => b.emit_const(Const::ULong(*value as u64)),
                klio_ast::IntLitKind::Int => {
                    if *value >= i32::MIN as i64 && *value <= i32::MAX as i64 {
                        b.emit_const(Const::Int(*value as i32))
                    } else {
                        b.emit_const(Const::Long(*value))
                    }
                }
            }
        }
        Expr::FloatLit { value, kind, .. } => match kind {
            klio_ast::FloatLitKind::Float => b.emit_const(Const::Float(*value as f32)),
            klio_ast::FloatLitKind::Double => b.emit_const(Const::Double(*value)),
        },
        Expr::BoolLit { value, .. } => b.emit_const(Const::Bool(*value)),
        Expr::NullLit { .. } => b.emit_const(Const::Null),
        Expr::CharLit { value, .. } => b.emit_const(Const::Char(*value)),

        Expr::Binary { op, lhs, rhs, .. }
            if matches!(op, AstBinOp::Eq | AstBinOp::Neq)
                && (is_boxed_to_any_form(lhs)
                    || is_boxed_to_any_form(rhs)
                    || is_any_typed_path(b, lhs)
                    || is_any_typed_path(b, rhs)) =>
        {
            // `==` on a boxed `Any` operand uses bitwise equality
            // for Double/Float (NaN == NaN true, +0.0 != -0.0)
            // per spec. Emit the dedicated `BoxedEq` / `BoxedNotEq`
            // BinOp so the evaluator picks bitwise FP comparison.
            let l = lower_expr(b, lhs);
            let r = lower_expr(b, rhs);
            let dst = b.alloc_reg();
            let ir_op = match op {
                AstBinOp::Eq => BinOp::BoxedEq,
                AstBinOp::Neq => BinOp::BoxedNotEq,
                _ => unreachable!(),
            };
            b.push(Inst::BinOp { dst, op: ir_op, lhs: l, rhs: r });
            return dst;
        }
        Expr::Binary { op, lhs, rhs, .. } => {
            // `x in haystack` / `x !in haystack` desugar to
            // `haystack.contains(x)` (negated for !in). The right
            // operand is the haystack so dispatch through CallMember.
            if matches!(op, AstBinOp::In | AstBinOp::NotIn) {
                let recv = lower_expr(b, rhs);
                let arg_slot = b.alloc_reg();
                let l = lower_expr(b, lhs);
                b.push(Inst::Move { dst: arg_slot, src: l });
                let contains = b.alloc_reg();
                let nm = b.module.intern_const(Const::String("contains".into()));
                b.push(Inst::CallMember {
                    dst: contains,
                    receiver: recv,
                    name: nm,
                    args: arg_slot,
                    n_args: 1,
                    arg_names: Vec::new(),
                });
                if matches!(op, AstBinOp::NotIn) {
                    let dst = b.alloc_reg();
                    b.push(Inst::Not { dst, src: contains });
                    return dst;
                }
                return contains;
            }
            // Elvis `a ?: b` short-circuits — when `a` is non-null
            // the right operand must not evaluate. Lower as a
            // conditional branch with phi-style merge.
            if matches!(op, AstBinOp::Elvis) {
                let l = lower_expr(b, lhs);
                let null_r = b.emit_const(Const::Null);
                let is_null = b.alloc_reg();
                b.push(Inst::BinOp { dst: is_null, op: BinOp::Eq, lhs: l, rhs: null_r });
                let then_b = b.alloc_block();
                let else_b = b.alloc_block();
                let join = b.alloc_block();
                let dst = b.alloc_reg();
                b.terminate(Terminator::Branch { cond: is_null, t: then_b, f: else_b });
                b.switch_to(then_b);
                let rv = lower_expr(b, rhs);
                b.push(Inst::Move { dst, src: rv });
                b.terminate(Terminator::Goto(join));
                b.switch_to(else_b);
                b.push(Inst::Move { dst, src: l });
                b.terminate(Terminator::Goto(join));
                b.switch_to(join);
                return dst;
            }
            // Logical `&&` / `||` short-circuit similarly.
            if matches!(op, AstBinOp::And | AstBinOp::Or) {
                let l = lower_expr(b, lhs);
                let then_b = b.alloc_block();
                let else_b = b.alloc_block();
                let join = b.alloc_block();
                let dst = b.alloc_reg();
                b.terminate(Terminator::Branch { cond: l, t: then_b, f: else_b });
                let is_and = matches!(op, AstBinOp::And);
                // `&&`: if l is true → evaluate rhs; else → false.
                // `||`: if l is true → true; else → evaluate rhs.
                if is_and {
                    b.switch_to(then_b);
                    let rv = lower_expr(b, rhs);
                    b.push(Inst::Move { dst, src: rv });
                    b.terminate(Terminator::Goto(join));
                    b.switch_to(else_b);
                    let false_r = b.emit_const(Const::Bool(false));
                    b.push(Inst::Move { dst, src: false_r });
                    b.terminate(Terminator::Goto(join));
                } else {
                    b.switch_to(then_b);
                    let true_r = b.emit_const(Const::Bool(true));
                    b.push(Inst::Move { dst, src: true_r });
                    b.terminate(Terminator::Goto(join));
                    b.switch_to(else_b);
                    let rv = lower_expr(b, rhs);
                    b.push(Inst::Move { dst, src: rv });
                    b.terminate(Terminator::Goto(join));
                }
                b.switch_to(join);
                return dst;
            }
            let l = lower_expr(b, lhs);
            let r = lower_expr(b, rhs);
            let dst = b.alloc_reg();
            b.push(Inst::BinOp { dst, op: ast_binop(*op), lhs: l, rhs: r });
            dst
        }
        Expr::Unary { op, expr, .. }
            if matches!(op, AstUnOp::Neg)
                && matches!(
                    expr.as_ref(),
                    Expr::IntLit { value, kind: klio_ast::IntLitKind::Int, .. }
                        if *value == (i32::MAX as i64 + 1)
                ) =>
        {
            // `-2147483648` parses as Neg(IntLit(2147483648)); the
            // operand's value doesn't fit in i32 so general
            // IntLit-lowering would widen to Long. Special-case
            // Int.MIN_VALUE so it stays Int and arithmetic wraps
            // at the 32-bit boundary.
            b.emit_const(Const::Int(i32::MIN))
        }
        Expr::Unary { op, expr, .. } => {
            // Prefix ++ / -- need both an Inc/Dec UnOp AND a
            // write-back to the lvalue. Delegate to a helper that
            // mirrors postfix's Path/Member/Index branches and
            // returns the NEW value (not the old, per Kotlin's
            // pre-inc/pre-dec semantics).
            if matches!(op, AstUnOp::PreInc | AstUnOp::PreDec) {
                let operand = lower_expr(b, expr);
                let dst = b.alloc_reg();
                let u = if matches!(op, AstUnOp::PreInc) { UnOp::Inc } else { UnOp::Dec };
                b.push(Inst::UnOp { dst, op: u, operand });
                match expr.as_ref() {
                    Expr::Path { segments, .. } if segments.len() == 1 => {
                        if b.is_boxed(&segments[0].name) {
                            let cell = boxed_cell_reg(b, &segments[0].name);
                            b.push(Inst::CellSet { cell, value: dst });
                        } else if let Some(home) = b.mutable_home(&segments[0].name) {
                            b.push(Inst::Move { dst: home, src: dst });
                        } else if b.knows_outer(&segments[0].name) {
                            let _ = b.record_capture(&segments[0].name);
                            let n = b
                                .module
                                .intern_const(Const::String(segments[0].name.clone()));
                            b.push(Inst::StoreGlobal { name: n, value: dst });
                            b.rebind(&segments[0].name, dst);
                        } else {
                            b.rebind(&segments[0].name, dst);
                        }
                    }
                    Expr::Member { receiver, name, safe: false, .. } => {
                        let recv = lower_receiver(b, receiver);
                        let field = b.module.intern_const(Const::String(name.name.clone()));
                        b.push(Inst::SetField { receiver: recv, field, value: dst });
                    }
                    Expr::Index { receiver, args: idx_args, .. } => {
                        let recv = lower_receiver(b, receiver);
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
                        b.push(Inst::Move { dst: val_slot, src: dst });
                        let ret = b.alloc_reg();
                        let nm = b.module.intern_const(Const::String("set".into()));
                        b.push(Inst::CallMember {
                            dst: ret,
                            receiver: recv,
                            name: nm,
                            args: key_start,
                            n_args: (n_keys as u8) + 1,
                            arg_names: Vec::new(),
                        });
                    }
                    _ => {}
                }
                return dst;
            }
            let operand = lower_expr(b, expr);
            let dst = b.alloc_reg();
            match op {
                AstUnOp::Not => b.push(Inst::Not { dst, src: operand }),
                AstUnOp::Neg => b.push(Inst::UnOp { dst, op: UnOp::Neg, operand }),
                AstUnOp::Pos => b.push(Inst::UnOp { dst, op: UnOp::Plus, operand }),
                AstUnOp::PreInc | AstUnOp::PreDec => unreachable!(),
            }
            dst
        }
        Expr::If { cond, then_branch, else_branch, .. } => {
            // Use a single destination register that both arms
            // write into via Move before jumping to the join.
            // Equivalent to a phi-node-driven SSA result without
            // requiring SSA infrastructure: the evaluator sees the
            // last write at the join site.
            let cond_r = lower_expr(b, cond);
            let t_block = b.alloc_block();
            let f_block = b.alloc_block();
            let join = b.alloc_block();
            let dst = b.alloc_reg();
            b.terminate(Terminator::Branch { cond: cond_r, t: t_block, f: f_block });
            // Then arm.
            b.switch_to(t_block);
            let t_val = lower_expr(b, then_branch);
            b.push(Inst::Move { dst, src: t_val });
            b.terminate(Terminator::Goto(join));
            // Else arm.
            b.switch_to(f_block);
            let f_val = match else_branch {
                Some(e) => lower_expr(b, e),
                None => b.emit_const(Const::Unit),
            };
            b.push(Inst::Move { dst, src: f_val });
            b.terminate(Terminator::Goto(join));
            b.switch_to(join);
            dst
        }
        Expr::Block(block) => lower_block(b, block),
        Expr::Path { segments, span } => {
            // Inline a bare reference to an enclosing class's (or its
            // companion's) `const val name = <literal>` directly as a
            // constant load — Kotlin's `const val` is compile-time
            // inlined, sidestepping companion-singleton init order
            // (relevant when the companion `object Default : Outer(…)`
            // inherits the outer class and the outer's ctor reads a
            // companion const before the Default singleton is ready).
            if segments.len() == 1 {
                if let Some(owner) = b.owner_class().map(str::to_string) {
                    if b.resolve(&segments[0].name).is_none() {
                        let key = (owner, segments[0].name.clone());
                        if let Some(c) = b.module.registry.class_const_inits.get(&key).cloned() {
                            return b.emit_const(c);
                        }
                    }
                }
            }
            // Nested-object alias rewrite: when inside an outer class
            // whose lift renamed a `private object Inner` to
            // `Outer$Inner` (to avoid colliding with a same-named user
            // top-level), bare references to `Inner` in the outer's
            // method bodies redirect to the renamed lifted class.
            if let Some(owner) = b.owner_class().map(str::to_string) {
                let renamed = b
                    .module
                    .registry
                    .nested_object_aliases
                    .get(&owner)
                    .and_then(|m| m.get(&segments[0].name))
                    .cloned();
                if let Some(renamed) = renamed {
                    if b.resolve(&segments[0].name).is_none() {
                        let mut new_segs = segments.clone();
                        new_segs[0] = klio_ast::Ident {
                            name: renamed,
                            span: segments[0].span,
                        };
                        let rewritten = Expr::Path { segments: new_segs, span: *span };
                        return lower_expr(b, &rewritten);
                    }
                }
            }
            if segments.len() == 1 {
                // Bare `Unit` is the Unit singleton value (`fun
                // hintEmit(): Unit = Unit`), not a member read — it
                // must not fall through to a `this.Unit` field probe
                // inside a method/extension body.
                if segments[0].name == "Unit" && b.resolve("Unit").is_none() {
                    return b.emit_const(Const::Unit);
                }
                if let Some(r) = b.resolve(&segments[0].name) {
                    if b.is_boxed(&segments[0].name) {
                        // `r` holds the shared `Value::Cell`; read
                        // its current contents.
                        let dst = b.alloc_reg();
                        b.push(Inst::CellGet { dst, cell: r });
                        return dst;
                    }
                    return r;
                }
                // Lambda-body capture: name lives in an enclosing
                // frame but not as a top-level global.
                if b.knows_outer(&segments[0].name) {
                    let idx = b.record_capture(&segments[0].name);
                    let cell = b.alloc_reg();
                    b.push(Inst::LoadCapture { dst: cell, idx });
                    // Do NOT cache the loaded reg under the capture
                    // name: a later reference in a sibling branch
                    // would reuse a reg whose defining `LoadCapture`
                    // is in a non-dominating block (its value would be
                    // the uninitialized `Unit`). `LoadCapture` reads
                    // the frame-global captures vector, so re-emitting
                    // it at every use is always correct and cheap.
                    if b.is_boxed(&segments[0].name) {
                        let dst = b.alloc_reg();
                        b.push(Inst::CellGet { dst, cell });
                        return dst;
                    }
                    return cell;
                }
                // Inside a method / extension fn body `this` is
                // bound as the implicit first param. An unqualified
                // identifier that didn't resolve as a local /
                // capture / known outer is most likely a field
                // read on the instance — try `this.<name>` via
                // GetField when the owning class declares this
                // name. Otherwise fall through to LoadGlobal.
                if b.has_own_member(&segments[0].name) {
                    if let Some(this_reg) = b.resolve("this") {
                        let dst = b.alloc_reg();
                        let nm = b.module.intern_const(Const::String(segments[0].name.clone()));
                        b.push(Inst::GetField {
                            dst,
                            receiver: this_reg,
                            field: nm,
                        });
                        return dst;
                    }
                    // A superclass-constructor delegation argument
                    // thunk runs with the companion initialized but
                    // no `this`. A bare own-member name there is a
                    // companion access: load the enclosing class and
                    // read the member off it (get_field forwards a
                    // Class receiver to its companion singleton). This
                    // must beat the global-class step below so an
                    // unrelated interface/class of the same name (e.g.
                    // a `companion object Key` vs `CoroutineContext.Key`)
                    // does not shadow the class's own companion.
                    if b.is_param_thunk() {
                        if let Some(owner) = b.owner_class().map(str::to_string) {
                            let cls = b.alloc_reg();
                            let on =
                                b.module.intern_const(Const::String(owner));
                            b.push(Inst::LoadGlobal { dst: cls, name: on });
                            let dst = b.alloc_reg();
                            let nm = b.module.intern_const(Const::String(
                                segments[0].name.clone(),
                            ));
                            b.push(Inst::GetField {
                                dst,
                                receiver: cls,
                                field: nm,
                            });
                            return dst;
                        }
                    }
                }
                // A bare name that is a known class is a class
                // reference (`Segment.SIZE`, `Segment.new()`), not an
                // implicit `this.<name>` member read. This must beat
                // the `this`-prefix probe below: inside an instance
                // or object method `this` is bound, and without this
                // check `Segment` would lower to `this.Segment` and
                // miss. The class value flows into get_field /
                // call_member which forward to the companion.
                if b.module.class_id(&segments[0].name).is_some() {
                    let cls = b.alloc_reg();
                    let n = b
                        .module
                        .intern_const(Const::String(segments[0].name.clone()));
                    b.push(Inst::LoadGlobal { dst: cls, name: n });
                    // A bare class/interface name in *value* position
                    // (Kotlin: only well-formed when it declares a
                    // companion) is the companion object, not the
                    // class. Qualifier heads (`Foo.member`, `Foo(..)`,
                    // `Foo::class`) lower their receiver via
                    // `lower_receiver` / NewInstance / ClassLiteral and
                    // never reach here. The sentinel read yields the
                    // companion when one exists, else the class value
                    // unchanged (objects / no-companion classes are
                    // untouched).
                    let dst = b.alloc_reg();
                    let sentinel = b.module.intern_const(Const::String(
                        "<class-companion-or-self>".to_string(),
                    ));
                    b.push(Inst::GetField { dst, receiver: cls, field: sentinel });
                    return dst;
                }
                // A bare builtin type name used as a qualifier
                // (`Long.MAX_VALUE`, `Int.SIZE_BITS`) is a
                // type/companion reference, not `this.<Type>`. Skip
                // the hard `this`-prefix GetField below and use the
                // this-or-global probe so it resolves the same way it
                // does at top level (the primitive-companion table).
                if matches!(
                    segments[0].name.as_str(),
                    "Int" | "Long" | "Short" | "Byte" | "Double" | "Float"
                        | "Char" | "Boolean" | "String" | "UInt" | "ULong"
                        | "UShort" | "UByte"
                ) {
                    let this_idx = b.record_capture("this");
                    let dst = b.alloc_reg();
                    let name = b
                        .module
                        .intern_const(Const::String(segments[0].name.clone()));
                    b.push(Inst::LoadFromThisOrGlobal { dst, this_idx, name });
                    return dst;
                }
                // Not a local and not a known capture. Inside a
                // method / extension fn with `this` bound as a
                // param, try `this.<name>` first via GetField so
                // smart-casted member reads (`when (this) { is X ->
                // "$x" }`) resolve through the receiver instance.
                // Outside that scope fall through to the
                // LoadFromThisOrGlobal probe. A default-arg thunk
                // runs in the declaring scope, not as a member of
                // the receiver, so a bare name there must take the
                // this-or-global probe (resolving top-level objects
                // like `EmptyCoroutineContext`) instead.
                // An imported member of a (possibly named) companion
                // object — `import a.b.C.Factory.RENDEZVOUS` then a
                // bare `RENDEZVOUS` — has no import context in the IR,
                // so rewrite it to the qualified `C.RENDEZVOUS`
                // companion access (companion name is optional in
                // Kotlin) and lower that. Only fires when the import
                // path names a class the module actually declares, so
                // a coincidental same-named local/global is untouched.
                if b.resolve(&segments[0].name).is_none() {
                    if let Some(rewrite) = b
                        .module
                        .registry
                        .import_aliases
                        .get(&segments[0].name)
                        .and_then(|segs| {
                            let cls_idx = segs
                                .iter()
                                .rposition(|s| b.module.class_id(s).is_some())?;
                            (cls_idx + 1 < segs.len()).then(|| {
                                (segs[cls_idx].clone(), segs[segs.len() - 1].clone())
                            })
                        })
                    {
                        let sp = segments[0].span;
                        let qualified = Expr::Path {
                            segments: vec![
                                klio_ast::Ident { name: rewrite.0, span: sp },
                                klio_ast::Ident { name: rewrite.1, span: sp },
                            ],
                            span: sp,
                        };
                        return lower_expr(b, &qualified);
                    }
                }
                if !b.is_param_thunk() {
                if let Some(this_reg) = b.resolve("this") {
                    let dst = b.alloc_reg();
                    let nm = b
                        .module
                        .intern_const(Const::String(segments[0].name.clone()));
                    b.push(Inst::GetField {
                        dst,
                        receiver: this_reg,
                        field: nm,
                    });
                    return dst;
                }
                }
                let this_idx = b.record_capture("this");
                let dst = b.alloc_reg();
                let name = b.module.intern_const(Const::String(segments[0].name.clone()));
                b.push(Inst::LoadFromThisOrGlobal { dst, this_idx, name });
                return dst;
            }
            // Multi-segment paths (`a.b.c`) lower as a chain of
            // GetFields starting from a top-level lookup. The
            // alternative — synthesize a fully-qualified LoadGlobal
            // — is faster but requires more import-resolution
            // context than the lowering pass has today.
            // Try the full FQN first (e.g. `kotlin.math.PI`) — the
            // host's lookup_global knows the package-resolved name
            // for stdlib intrinsics + properties and the IR doesn't
            // carry import context. Fall back to a chain of GetFields
            // off a head LoadGlobal when the FQN doesn't resolve.
            if segments.len() >= 2
                && is_package_head(&segments[0].name)
                && (is_pkg_root(&segments[0].name) || !b.is_lambda_body())
                && b.resolve(&segments[0].name).is_none()
                && b.module.class_id(&segments[0].name).is_none()
            {
                let fqn = segments
                    .iter()
                    .map(|s| s.name.as_str())
                    .collect::<Vec<_>>()
                    .join(".");
                let dst = b.alloc_reg();
                let n = b.module.intern_const(Const::String(fqn));
                b.push(Inst::LoadGlobal { dst, name: n });
                return dst;
            }
            let mut iter = segments.iter();
            let first = iter.next().expect("Path has at least one segment");
            let head = if let Some(r) = b.resolve(&first.name) {
                r
            } else {
                // Unresolved head: route through `this` / the
                // enclosing receiver before a bare global so a bare
                // member of `this@Outer` (e.g. inside a receiver
                // lambda) resolves instead of failing as a missing
                // global. Falls back to the global when neither has
                // it.
                let this_idx = b.record_capture("this");
                let dst = b.alloc_reg();
                let n = b.module.intern_const(Const::String(first.name.clone()));
                b.push(Inst::LoadFromThisOrGlobal {
                    dst,
                    this_idx,
                    name: n,
                });
                dst
            };
            let mut cur = head;
            for seg in iter {
                let next = b.alloc_reg();
                let field = b.module.intern_const(Const::String(seg.name.clone()));
                b.push(Inst::GetField { dst: next, receiver: cur, field });
                cur = next;
            }
            cur
        }
        Expr::StringTemplate { parts, .. } => {
            let mut cur = b.emit_const(Const::String(String::new()));
            for part in parts {
                let piece = match part {
                    klio_ast::StringPart::Text(s) => b.emit_const(Const::String(s.clone())),
                    klio_ast::StringPart::ShortInterp(ident) => {
                        if let Some(r) = b.resolve(&ident.name) {
                            r
                        } else if b.knows_outer(&ident.name) {
                            let idx = b.record_capture(&ident.name);
                            let dst = b.alloc_reg();
                            b.push(Inst::LoadCapture { dst, idx });
                            b.bind(ident.name.clone(), dst);
                            dst
                        } else if b.has_own_member(&ident.name)
                            && b.resolve("this").is_some()
                        {
                            // Inside a method body, unqualified
                            // `$name` resolves through `this.name`.
                            let this_reg = b.resolve("this").unwrap();
                            let dst = b.alloc_reg();
                            let nm = b.module.intern_const(Const::String(ident.name.clone()));
                            b.push(Inst::GetField { dst, receiver: this_reg, field: nm });
                            dst
                        } else if let Some(this_reg) = b.resolve("this") {
                            // `$name` inside an extension fn /
                            // method whose receiver param holds the
                            // referenced field — emit GetField on
                            // the bound `this` reg. Host get_field
                            // falls through to globals when the
                            // field isn't on the instance.
                            let dst = b.alloc_reg();
                            let n =
                                b.module.intern_const(Const::String(ident.name.clone()));
                            b.push(Inst::GetField {
                                dst,
                                receiver: this_reg,
                                field: n,
                            });
                            dst
                        } else {
                            // Fall back through the captured `this`
                            // slot — the dispatcher may supply a
                            // this-binding (scope fns). Reduces to a
                            // plain global lookup when the captured
                            // this is null.
                            let this_idx = b.record_capture("this");
                            let dst = b.alloc_reg();
                            let n = b.module.intern_const(Const::String(ident.name.clone()));
                            b.push(Inst::LoadFromThisOrGlobal {
                                dst,
                                this_idx,
                                name: n,
                            });
                            dst
                        }
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
        Expr::Member { receiver, name, safe, .. } if *safe => {
            // `recv?.x` — null-guard: if recv is null, the whole
            // expression is null; otherwise read the field.
            let recv = lower_receiver(b, receiver);
            let null_r = b.emit_const(Const::Null);
            let is_null = b.alloc_reg();
            b.push(Inst::BinOp { dst: is_null, op: BinOp::Eq, lhs: recv, rhs: null_r });
            let then_b = b.alloc_block();
            let else_b = b.alloc_block();
            let join = b.alloc_block();
            let dst = b.alloc_reg();
            b.terminate(Terminator::Branch { cond: is_null, t: then_b, f: else_b });
            // null branch: dst = null
            b.switch_to(then_b);
            let n = b.emit_const(Const::Null);
            b.push(Inst::Move { dst, src: n });
            b.terminate(Terminator::Goto(join));
            // non-null: dst = recv.field
            b.switch_to(else_b);
            let field = b.module.intern_const(Const::String(name.name.clone()));
            let v = b.alloc_reg();
            b.push(Inst::GetField { dst: v, receiver: recv, field });
            b.push(Inst::Move { dst, src: v });
            b.terminate(Terminator::Goto(join));
            b.switch_to(join);
            dst
        }
        Expr::Member { receiver, name, .. } => {
            // `super.<prop>` is a property read on the superclass —
            // dispatch its getter via the parent chain (a 0-arg
            // `CallSuper`), never `this.<prop>` (which would re-enter
            // an overriding getter, e.g. `override val isActive get()
            // = super.isActive`, and recurse forever). Mirrors the
            // `super.method(...)` CallSuper path.
            if let Expr::Super { qualifier, label, .. } = receiver.as_ref() {
                if let Some(this_reg) = b.resolve("this") {
                    if let Some(owner) = b.owner_class().map(|s| s.to_string()) {
                        let dst = b.alloc_reg();
                        let nm = b.module.intern_const(Const::String(name.name.clone()));
                        let oc = b.module.intern_const(Const::String(owner));
                        let qual_const = qualifier
                            .as_ref()
                            .map(|t| b.module.intern_const(Const::String(t.name.name.clone())))
                            .or_else(|| {
                                label.as_ref().map(|id| {
                                    b.module.intern_const(Const::String(id.name.clone()))
                                })
                            });
                        let args_start = b.alloc_reg();
                        b.push(Inst::CallSuper {
                            dst,
                            receiver: this_reg,
                            owner_class: oc,
                            qualifier: qual_const,
                            name: nm,
                            args: args_start,
                            n_args: 0,
                            arg_names: Vec::new(),
                        });
                        return dst;
                    }
                }
            }
            // Flatten chains like `kotlin.math.PI` into a single FQN
            // lookup against the host when the head is an unresolved
            // identifier (i.e. not a local). Stdlib package roots
            // (`kotlin`, `kotlinx`, etc.) aren't real values, so the
            // chained-GetField fallback would fail at `kotlin` itself.
            if let Some(fqn) = collect_dotted_fqn(expr) {
                if let Some(head) = fqn.split('.').next() {
                    if is_package_head(head)
                        // Only a genuine package root (`kotlin`,
                        // `kotlinx`, …) flattens inside a lambda body:
                        // there `this` is a captured outer (not
                        // locally resolvable), so an arbitrary
                        // lowercase head like a member field
                        // (`resumeMode.isCancellableMode`) must NOT be
                        // mistaken for an FQN — it is a `this.<field>`
                        // access then an extension-property read.
                        // Mirrors the call-site guards below.
                        && (is_pkg_root(head) || !b.is_lambda_body())
                        && b.resolve(head).is_none()
                        && !b.knows_outer(head)
                        && b.module.class_id(head).is_none()
                        // Inside a method / extension body, the
                        // head could be `this.<head>`; don't
                        // shortcut to a global FQN.
                        && b.resolve("this").is_none()
                    {
                        let dst = b.alloc_reg();
                        let n = b.module.intern_const(Const::String(fqn));
                        b.push(Inst::LoadGlobal { dst, name: n });
                        return dst;
                    }
                }
            }
            let recv = lower_receiver(b, receiver);
            let dst = b.alloc_reg();
            let field = b.module.intern_const(Const::String(name.name.clone()));
            b.push(Inst::GetField { dst, receiver: recv, field });
            dst
        }
        Expr::Index { receiver, args, .. } => {
            // `r[a, b, ...]` → r.get(a, b, ...). Evaluator's
            // CallMember + host.call_member route dispatches to
            // Value::Map / List / Array / user classes uniformly.
            let recv = lower_receiver(b, receiver);
            let (args_start, count) = lower_arg_run(b, args);
            let dst = b.alloc_reg();
            let nm = b.module.intern_const(Const::String("get".into()));
            b.push(Inst::CallMember {
                dst,
                receiver: recv,
                name: nm,
                args: args_start,
                n_args: count,
                arg_names: Vec::new(),
            });
            dst
        }
        // `repeat(n) { … }` — inline-desugar to a counted loop so
        // the body runs in the caller's eval frame. This must win
        // over the closure-mutating-lambda arms below (the body
        // commonly mutates an outer `var`) and over the generic
        // stdlib-dispatch arm, because dispatching `repeat` to its
        // Rust binding would run a suspending body in a
        // non-resumable Rust frame.
        Expr::Call { callee, args, arg_names: ast_arg_names, .. }
            if matches!(callee.as_ref(), Expr::Member { safe: true, .. }) =>
        {
            // `recv?.m(args)` — null-guard the whole call: if the
            // receiver is null the call expression is null, otherwise
            // dispatch the member. Mirrors the safe-field path.
            let Expr::Member { receiver, name, .. } = callee.as_ref() else {
                unreachable!()
            };
            let recv = lower_receiver(b, receiver);
            let null_r = b.emit_const(Const::Null);
            let is_null = b.alloc_reg();
            b.push(Inst::BinOp { dst: is_null, op: BinOp::Eq, lhs: recv, rhs: null_r });
            let then_b = b.alloc_block();
            let else_b = b.alloc_block();
            let join = b.alloc_block();
            let dst = b.alloc_reg();
            b.terminate(Terminator::Branch { cond: is_null, t: then_b, f: else_b });
            b.switch_to(then_b);
            let n = b.emit_const(Const::Null);
            b.push(Inst::Move { dst, src: n });
            b.terminate(Terminator::Goto(join));
            b.switch_to(else_b);
            let (args_start, n_args) = lower_arg_run(b, args);
            let arg_names = intern_arg_names(b.module, ast_arg_names);
            let nm = b.module.intern_const(Const::String(name.name.clone()));
            let v = b.alloc_reg();
            b.push(Inst::CallMember {
                dst: v,
                receiver: recv,
                name: nm,
                args: args_start,
                n_args,
                arg_names,
            });
            b.push(Inst::Move { dst, src: v });
            b.terminate(Terminator::Goto(join));
            b.switch_to(join);
            return dst;
        }
        Expr::Call { callee, args, is_infix, .. }
            if !*is_infix
                && args.len() == 2
                && matches!(&args[1], Expr::Lambda { .. })
                && matches!(callee.as_ref(), Expr::Path { segments, .. }
                    if segments.len() == 1
                        && segments[0].name == "repeat"
                        && b.resolve("repeat").is_none()
                        && b.module.func_id("repeat").is_none()) =>
        {
            let Expr::Lambda { params, body, .. } = &args[1] else { unreachable!() };
            let n_reg = lower_expr(b, &args[0]);
            let i_reg = b.alloc_reg();
            let zero = b.emit_const(Const::Int(0));
            b.push(Inst::Move { dst: i_reg, src: zero });
            let header = b.alloc_block();
            let body_blk = b.alloc_block();
            let exit = b.alloc_block();
            b.terminate(Terminator::Goto(header));
            b.switch_to(header);
            let cond = b.alloc_reg();
            b.push(Inst::BinOp { dst: cond, op: BinOp::Less, lhs: i_reg, rhs: n_reg });
            b.terminate(Terminator::Branch { cond, t: body_blk, f: exit });
            b.switch_to(body_blk);
            b.push_scope();
            let pname = params
                .first()
                .map(|p| p.name.clone())
                .unwrap_or_else(|| "it".to_string());
            b.bind(pname, i_reg);
            b.push_loop(None, header, exit);
            let _ = lower_block(b, body);
            b.pop_loop();
            b.pop_scope();
            let one = b.emit_const(Const::Int(1));
            let nexti = b.alloc_reg();
            b.push(Inst::BinOp { dst: nexti, op: BinOp::Add, lhs: i_reg, rhs: one });
            b.push(Inst::Move { dst: i_reg, src: nexti });
            b.terminate(Terminator::Goto(header));
            b.switch_to(exit);
            b.emit_const(Const::Unit)
        }
        Expr::Call { callee, args, arg_names: ast_arg_names, is_infix, .. }
            if args.iter().any(|a| lambda_writes_outer_var(b, a))
                && matches!(callee.as_ref(), Expr::Member { .. })
                && !*is_infix =>
        {
            // Call passing a lambda that assigns to an outer-scope
            // variable. Emit a normal CallMember and a
            // WritebackCaptures Inst for each closure-mutating
            // lambda so the env's mutations are synced back to
            // the caller's regs after the call returns.
            let Expr::Member { receiver, name, .. } = callee.as_ref() else { unreachable!() };
            let recv = lower_receiver(b, receiver);
            // Lower args individually so we can remember each
            // lambda's reg for writeback.
            let mut arg_regs: Vec<Reg> = Vec::with_capacity(args.len());
            for a in args {
                let r = lower_expr(b, a);
                arg_regs.push(r);
            }
            // Compact into a contiguous run for the CallMember
            // arg-slot convention.
            let args_start = if arg_regs.is_empty() {
                Reg(0)
            } else {
                let start = b.alloc_reg();
                b.push(Inst::Move { dst: start, src: arg_regs[0] });
                for r in &arg_regs[1..] {
                    let slot = b.alloc_reg();
                    b.push(Inst::Move { dst: slot, src: *r });
                }
                start
            };
            let arg_names = intern_arg_names(b.module, ast_arg_names);
            let dst = b.alloc_reg();
            let nm = b.module.intern_const(Const::String(name.name.clone()));
            b.push(Inst::CallMember {
                dst,
                receiver: recv,
                name: nm,
                args: args_start,
                n_args: args.len() as u8,
                arg_names,
            });
            // Emit writebacks for each closure-mutating lambda
            // argument: read the captured names back out of the
            // lambda's env into the caller's source regs.
            for (i, a) in args.iter().enumerate() {
                let mutated = lambda_mutated_outer_vars(b, a);
                if mutated.is_empty() {
                    continue;
                }
                let lambda_reg = arg_regs[i];
                let mut names: Vec<crate::ConstId> = Vec::with_capacity(mutated.len());
                let mut dsts: Vec<Reg> = Vec::with_capacity(mutated.len());
                for name in &mutated {
                    if let Some(src_reg) = b.resolve(name) {
                        let n = b.module.intern_const(Const::String(name.clone()));
                        names.push(n);
                        dsts.push(src_reg);
                    }
                }
                if !names.is_empty() {
                    b.push(Inst::WritebackCaptures { lambda: lambda_reg, names, dsts });
                }
            }
            return dst;
        }
        Expr::Call { callee, args, arg_names: ast_arg_names, type_args: ast_type_args, .. }
            if args.iter().any(|a| lambda_writes_outer_var(b, a))
                && matches!(callee.as_ref(), Expr::Path { .. }) =>
        {
            // Top-level fn call passing a closure-mutating lambda.
            // Lower as Call{func}/CallValue against the resolved
            // callable, then emit WritebackCaptures for each
            // mutating lambda arg.
            let mut arg_regs: Vec<Reg> = Vec::with_capacity(args.len());
            for a in args {
                let r = lower_expr(b, a);
                arg_regs.push(r);
            }
            // An extension/member fn lowers `this` as its implicit
            // first param. A bare call to one (`proc(a, b) { … }`
            // from inside another extension) must prepend the active
            // receiver, exactly like the non-lambda Call path —
            // otherwise the args shift by one and a lambda argument
            // lands in a value parameter.
            let mut run_regs: Vec<Reg> = Vec::with_capacity(arg_regs.len() + 1);
            if let Expr::Path { segments, .. } = callee.as_ref() {
                if segments.len() == 1 {
                    let needs_this = b
                        .module
                        .func_id(&segments[0].name)
                        .and_then(|fid| b.module.funcs.get(fid.0 as usize))
                        .map(|f| {
                            f.params.first().map(|p| p.name == "this").unwrap_or(false)
                        })
                        .unwrap_or(false);
                    if needs_this {
                        let this_reg = b.resolve("this").or_else(|| {
                            if b.knows_outer("this") || b.is_lambda_body() {
                                let idx = b.record_capture("this");
                                let d = b.alloc_reg();
                                b.push(Inst::LoadCapture { dst: d, idx });
                                b.bind("this".to_string(), d);
                                Some(d)
                            } else {
                                None
                            }
                        });
                        if let Some(tr) = this_reg {
                            run_regs.push(tr);
                        }
                    }
                }
            }
            run_regs.extend_from_slice(&arg_regs);
            let n_args = run_regs.len() as u8;
            let args_start = if run_regs.is_empty() {
                Reg(0)
            } else {
                let start = b.alloc_reg();
                b.push(Inst::Move { dst: start, src: run_regs[0] });
                for r in &run_regs[1..] {
                    let slot = b.alloc_reg();
                    b.push(Inst::Move { dst: slot, src: *r });
                }
                start
            };
            let mut arg_names = intern_arg_names(b.module, ast_arg_names);
            // Keep arg-name slots aligned with the (possibly
            // this-prepended) positional run.
            while arg_names.len() < run_regs.len() {
                arg_names.insert(0, None);
            }
            let dst = b.alloc_reg();
            let Expr::Path { segments, .. } = callee.as_ref() else { unreachable!() };
            if segments.len() == 1 {
                if let Some(func_id) = b.module.func_id(&segments[0].name) {
                    let type_args = intern_type_args(b.module, ast_type_args);
                    b.push(Inst::Call {
                        dst,
                        func: func_id,
                        args: args_start,
                        n_args,
                        arg_names,
                        type_args,
                    });
                } else {
                    // Not a user module fn. A bound local of this
                    // name is the callable (a local lambda var);
                    // otherwise it is a global / scope-fn intrinsic
                    // (`run`, `let`, …) — resolve it as a global
                    // directly. `lower_expr` would prepend an
                    // implicit `this.` inside a method body, turning
                    // `run { … }` into `this.run` and invoking the
                    // receiver instance.
                    let callee_r = if b.resolve(&segments[0].name).is_some()
                    {
                        lower_expr(b, callee)
                    } else {
                        let r = b.alloc_reg();
                        let n = b.module.intern_const(Const::String(
                            segments[0].name.clone(),
                        ));
                        b.push(Inst::LoadGlobal { dst: r, name: n });
                        r
                    };
                    b.push(Inst::CallValue {
                        dst,
                        callee: callee_r,
                        args: args_start,
                        n_args,
                        arg_names,
                    });
                }
            } else {
                let callee_r = lower_expr(b, callee);
                b.push(Inst::CallValue {
                    dst,
                    callee: callee_r,
                    args: args_start,
                    n_args,
                    arg_names,
                });
            }
            for (i, a) in args.iter().enumerate() {
                let mutated = lambda_mutated_outer_vars(b, a);
                if mutated.is_empty() {
                    continue;
                }
                let lambda_reg = arg_regs[i];
                let mut names: Vec<crate::ConstId> = Vec::with_capacity(mutated.len());
                let mut dsts: Vec<Reg> = Vec::with_capacity(mutated.len());
                for name in &mutated {
                    if let Some(src_reg) = b.resolve(name) {
                        let n = b.module.intern_const(Const::String(name.clone()));
                        names.push(n);
                        dsts.push(src_reg);
                    }
                }
                if !names.is_empty() {
                    b.push(Inst::WritebackCaptures { lambda: lambda_reg, names, dsts });
                }
            }
            return dst;
        }
        Expr::Call { callee, args, arg_names: ast_arg_names, .. }
            if args.iter().any(|a| matches!(a, Expr::Spread { .. })) =>
        {
            // Calls containing a `*spread` argument: emit a
            // `CallSpread` Inst whose `parts` list flags each arg
            // as positional or spread. The evaluator flattens the
            // spread sources at call time.
            let callee_reg = lower_expr(b, callee);
            let mut parts: Vec<crate::SpreadPart> = Vec::with_capacity(args.len());
            for a in args {
                match a {
                    Expr::Spread { expr: inner, .. } => {
                        let r = lower_expr(b, inner);
                        parts.push(crate::SpreadPart { reg: r, is_spread: true });
                    }
                    _ => {
                        let r = lower_expr(b, a);
                        parts.push(crate::SpreadPart { reg: r, is_spread: false });
                    }
                }
            }
            let arg_names = intern_arg_names(b.module, ast_arg_names);
            let dst = b.alloc_reg();
            b.push(Inst::CallSpread {
                dst,
                callee: callee_reg,
                parts,
                arg_names,
            });
            dst
        }
        Expr::Call { callee, args, arg_names: ast_arg_names, type_args: ast_type_args, is_infix, .. } => {
            // Inline expansion (suspend-inline only). A bare `Path`
            // callee that names a lambda parameter of the enclosing
            // inline frame is spliced; one that names a registered
            // `suspend inline fun` is expanded so its
            // `suspendCoroutineUninterceptedOrReturn` captures the
            // caller's continuation. Any unsafe shape falls back to a
            // normal call via `None`.
            if !*is_infix {
                if let Expr::Path { segments, .. } = callee.as_ref() {
                    if segments.len() == 1 {
                        let nm = &segments[0].name;
                        if let Some(lam) = b.inline_lambda_for(nm) {
                            return splice_inline_lambda(b, &lam, args);
                        }
                        // Upstream `suspendCoroutineUninterceptedOrReturn(block)`
                        // ships with a body that throws NotImplementedError
                        // (compiler-intrinsic placeholder). Substitute the
                        // call with a direct invocation of `block` —
                        // klio's runtime treats a returned
                        // COROUTINE_SUSPENDED sentinel as the suspend
                        // request and any other value as the immediate
                        // resume value.
                        if nm == "suspendCoroutineUninterceptedOrReturn"
                            && args.len() == 1
                        {
                            return lower_expr(
                                b,
                                &Expr::Call {
                                    callee: Box::new(args[0].clone()),
                                    args: Vec::new(),
                                    arg_names: Vec::new(),
                                    type_args: Vec::new(),
                                    is_infix: false,
                                    span: expr_span(callee.as_ref()),
                                },
                            );
                        }
                        if let Some(f) = inline_fn_ast(nm) {
                            // Inline a suspending builder (continuation
                            // capture), an inline fn whose lambda arg
                            // does a non-local `return` (must target
                            // the caller's frame), or any `inline fun
                            // <reified T>` (`T::class` / `is T` reads
                            // in the body need the call-site type
                            // argument substituted at splice time —
                            // the non-splice path has no `Inst` to
                            // bind a runtime type-parameter value).
                            // Other inline calls keep the normal call
                            // path so the splice graph cannot expand
                            // combinatorially through Flow / Channel
                            // operator chains.
                            let has_reified =
                                f.type_params.iter().any(|tp| tp.is_reified);
                            let needs_inline = f.is_suspend
                                || arg_lambda_has_nonlocal_return(args)
                                || has_reified;
                            if needs_inline {
                                if let Some(r) = try_inline_call_with_type_args(
                                    b,
                                    nm,
                                    args,
                                    ast_arg_names,
                                    None,
                                    ast_type_args,
                                ) {
                                    return r;
                                }
                            }
                        }
                    }
                }
            }
            // Infix call `a fn b` lowers as `a.fn(b)` — the
            // dispatch site is a member call on the receiver
            // even when `fn` is a top-level extension.
            if *is_infix && args.len() == 2 {
                if let Expr::Path { segments, .. } = callee.as_ref() {
                    if segments.len() == 1 {
                        let recv = lower_expr(b, &args[0]);
                        let (args_start, count) = lower_arg_run(b, &args[1..]);
                        let arg_names = intern_arg_names(b.module, ast_arg_names);
                        let dst = b.alloc_reg();
                        let nm = b
                            .module
                            .intern_const(Const::String(segments[0].name.clone()));
                        b.push(Inst::CallMember {
                            dst,
                            receiver: recv,
                            name: nm,
                            args: args_start,
                            n_args: count,
                            arg_names,
                        });
                        return dst;
                    }
                }
            }
            // `suspend { … }` builder — the `suspend` keyword in
            // expression position is just a marker that the lambda
            // is suspending. Lower the lambda as-is; the IR's
            // existing lambda evaluator handles suspend bodies.
            if let Expr::Path { segments, .. } = callee.as_ref() {
                if segments.len() == 1
                    && segments[0].name == "suspend"
                    && args.len() == 1
                    && matches!(args[0], Expr::Lambda { .. })
                {
                    return lower_expr(b, &args[0]);
                }
            }
            // `contract { … }` (kotlin.contracts) is a compile-time
            // marker with no runtime effect. Its lambda is a DSL of
            // `returns()/implies(...)` calls that must NOT execute, so
            // drop the whole call and yield Unit.
            if let Expr::Path { segments, .. } = callee.as_ref() {
                if segments.len() == 1
                    && segments[0].name == "contract"
                    && args.len() == 1
                    && matches!(args[0], Expr::Lambda { .. })
                {
                    return b.emit_const(Const::Unit);
                }
            }
            // Self-call inside a tailrec fn → TailJump terminator
            // instead of a regular Call. Re-binds params and
            // restarts the function's entry block.
            if let Expr::Path { segments, .. } = callee.as_ref() {
                if segments.len() == 1
                    && b.tailrec_self().map_or(false, |n| n == segments[0].name)
                {
                    let (args_start, count) = lower_arg_run(b, args);
                    b.terminate(Terminator::TailJump { args: args_start, n_args: count });
                    // Start a dead block so subsequent lowering
                    // has a valid current block (unreachable).
                    let dead = b.alloc_block();
                    b.switch_to(dead);
                    return b.emit_const(Const::Unit);
                }
            }
            // A single-name callee that resolves to a local binding
            // or parameter is a value invocation — the local
            // shadows any same-named top-level function — a lambda
            // parameter named `yield` (or any other top-level fn name)
            // must bind to the parameter at the call site, not to the
            // global function.
            if let Expr::Path { segments, .. } = callee.as_ref() {
                if segments.len() == 1 {
                    // Kotlin keeps the function and property namespaces
                    // separate: in call position `name(args)` resolves
                    // to a member function of the enclosing class (own
                    // or inherited) even when a same-named value/param
                    // is in scope (`init { if (flag) flag(x) }` where
                    // `flag` is both a ctor param and a method). Only a
                    // genuine local function shadows; a same-named
                    // member function outranks the value, so skip the
                    // value-invocation path and fall through to member
                    // dispatch. A bare param that is not a hierarchy
                    // member still invokes the value.
                    let redirect_to_member = {
                        let n = &segments[0].name;
                        let is_hierarchy_method = b
                            .owner_class()
                            .and_then(|oc| {
                                b.module.registry.hierarchy_methods.get(oc)
                            })
                            .map_or(false, |s| s.contains(n));
                        // Only intervene when a value/param actually
                        // shadows the method name — otherwise the
                        // normal member/function dispatch below is
                        // already correct and must not be rerouted.
                        is_hierarchy_method
                            && b.resolve(n).is_some()
                            && !b.is_local_fn(n)
                            && !b.is_local_ext_fn(n)
                            && b.resolve("this").is_some()
                    };
                    if redirect_to_member {
                        // `name(args)` where `name` names both a
                        // hierarchy member function and an in-scope
                        // value. Kotlin's choice depends on whether
                        // the value is invocable — known only at
                        // runtime — so emit `CallValueOrMember`: the
                        // value is invoked if invocable (a function
                        // type / `operator fun invoke`, the closer
                        // scope), otherwise the member function runs.
                        let this_reg = b.resolve("this").expect("this bound");
                        let callee_reg =
                            b.resolve(&segments[0].name).expect("shadowing value");
                        let callee_reg = if b.is_boxed(&segments[0].name) {
                            let c = b.alloc_reg();
                            b.push(Inst::CellGet { dst: c, cell: callee_reg });
                            c
                        } else {
                            callee_reg
                        };
                        let (args_start, count) = lower_arg_run(b, args);
                        let arg_names = intern_arg_names(b.module, ast_arg_names);
                        let dst = b.alloc_reg();
                        let nm = b
                            .module
                            .intern_const(Const::String(segments[0].name.clone()));
                        b.push(Inst::CallValueOrMember {
                            dst,
                            callee: callee_reg,
                            this_recv: this_reg,
                            name: nm,
                            args: args_start,
                            n_args: count,
                            arg_names,
                        });
                        return dst;
                    }
                    if let Some(reg) = b.resolve(&segments[0].name) {
                        // A boxed `var` (captured + reassigned, e.g. a
                        // recursive `lateinit var f = { … f(…) … }`)
                        // holds a shared Cell; unwrap it to the
                        // current callable before invoking.
                        let callee_reg = if b.is_boxed(&segments[0].name) {
                            let c = b.alloc_reg();
                            b.push(Inst::CellGet { dst: c, cell: reg });
                            c
                        } else {
                            reg
                        };
                        // A bare call to a parameter whose declared
                        // type is a receiver-typed function
                        // (`block: T.() -> R`) dispatches with the
                        // enclosing `this` as the receiver — matching
                        // kotlinc's rewrite of `block()` to
                        // `this.block()` inside such a fn.
                        if b.is_receiver_lambda_param(&segments[0].name) {
                            let this_reg = b.resolve("this").or_else(|| {
                                if b.knows_outer("this") || b.is_lambda_body() {
                                    let idx = b.record_capture("this");
                                    let d = b.alloc_reg();
                                    b.push(Inst::LoadCapture { dst: d, idx });
                                    Some(d)
                                } else {
                                    None
                                }
                            });
                            if let Some(this_reg) = this_reg {
                                let (args_start, count) = lower_arg_run(b, args);
                                let arg_names =
                                    intern_arg_names(b.module, ast_arg_names);
                                let dst = b.alloc_reg();
                                b.push(Inst::CallValueWithThis {
                                    dst,
                                    callee: callee_reg,
                                    receiver: this_reg,
                                    args: args_start,
                                    n_args: count,
                                    arg_names,
                                });
                                return dst;
                            }
                        }
                        // A bare call to a *local extension* function
                        // (`fun Appendable.two(x)` declared in this
                        // scope, called `two(n)`) takes the enclosing
                        // implicit receiver as its first `this` param;
                        // prepend it so the user args don't slot into
                        // the receiver position.
                        if b.is_local_ext_fn(&segments[0].name) {
                            let this_reg = b.resolve("this").or_else(|| {
                                if b.knows_outer("this") || b.is_lambda_body() {
                                    let idx = b.record_capture("this");
                                    let d = b.alloc_reg();
                                    b.push(Inst::LoadCapture { dst: d, idx });
                                    Some(d)
                                } else {
                                    None
                                }
                            });
                            if let Some(this_reg) = this_reg {
                                let recv = b.alloc_reg();
                                b.push(Inst::Move { dst: recv, src: this_reg });
                                let mut vals: Vec<Reg> =
                                    Vec::with_capacity(args.len() + 1);
                                vals.push(recv);
                                for a in args {
                                    vals.push(lower_expr(b, a));
                                }
                                let args_start = b.alloc_reg();
                                b.push(Inst::Move { dst: args_start, src: vals[0] });
                                for v in &vals[1..] {
                                    let slot = b.alloc_reg();
                                    b.push(Inst::Move { dst: slot, src: *v });
                                }
                                let arg_names =
                                    intern_arg_names(b.module, ast_arg_names);
                                let dst = b.alloc_reg();
                                b.push(Inst::CallValue {
                                    dst,
                                    callee: callee_reg,
                                    args: args_start,
                                    n_args: (vals.len()) as u8,
                                    arg_names,
                                });
                                return dst;
                            }
                        }
                        let (args_start, count) = lower_arg_run(b, args);
                        let arg_names = intern_arg_names(b.module, ast_arg_names);
                        let dst = b.alloc_reg();
                        b.push(Inst::CallValue {
                            dst,
                            callee: callee_reg,
                            args: args_start,
                            n_args: count,
                            arg_names,
                        });
                        return dst;
                    }
                }
            }
            // Path-callee with a registered top-level fn → Call{func}.
            if let Expr::Path { segments, .. } = callee.as_ref() {
                if segments.len() == 1 {
                    // When a class and a top-level function share
                    // this name (a class plus a same-named factory
                    // function), the call is a constructor
                    // invocation whenever the function isn't
                    // applicable to the supplied argument count.
                    // Defer to the NewInstance path below so the
                    // Vm's ctor overload resolution picks the right
                    // (possibly private/secondary) constructor.
                    // Only kicks in on the class+function name
                    // clash, so ordinary default/vararg calls are
                    // unaffected.
                    // The factory function is applicable whenever it
                    // can accept the supplied positional count —
                    // fewer args than params is fine (trailing params
                    // are defaulted, e.g. the all-default
                    // `fun DateTimePeriod(years=0, months=0, …)`
                    // factory beside `sealed class DateTimePeriod`).
                    // Only treat the call as a constructor when the
                    // function genuinely cannot take that many args.
                    let shadowed_by_class = b
                        .module
                        .class_id(&segments[0].name)
                        .is_some()
                        && b
                            .module
                            .func_id(&segments[0].name)
                            .and_then(|fid| b.module.funcs.get(fid.0 as usize))
                            .map(|f| {
                                let last_vararg = f
                                    .params
                                    .last()
                                    .map(|p| p.is_vararg)
                                    .unwrap_or(false);
                                !last_vararg && args.len() > f.params.len()
                            })
                            .unwrap_or(false);
                    // A bound local / parameter / captured outer of
                    // this name shadows a same-named top-level function
                    // (Kotlin scoping). e.g. a Flow operator's
                    // `crossinline transform` parameter shadows the
                    // top-level `Flow.transform` operator: a bare
                    // `transform(v)` inside the operator's lambda must
                    // invoke the parameter, not recurse into the
                    // operator. Route it through the captured value.
                    // Only the captured-outer gap: a name captured
                    // from an enclosing scope but not locally bound.
                    // Bound locals already route correctly through the
                    // resolved-callee path below, and forcing those
                    // through `CallValue` mis-invokes a non-callable
                    // local of the same name as a top-level fn.
                    // Fire only on a genuine shadowing conflict: the
                    // name is a captured outer *and* also a registered
                    // top-level function. Without the top-level fn the
                    // existing capture/global handling is already
                    // correct (ordinary captured local funs/lambdas
                    // like a recursive `fib`); intercepting those
                    // mis-invokes a not-yet-initialised capture.
                    let name0 = &segments[0].name;
                    let shadowed_by_local = b.knows_outer(name0)
                        && b.resolve(name0).is_none()
                        && b.module.func_id(name0).is_some();
                    if shadowed_by_local {
                        // Bind the lexically-enclosing `flow { }`
                        // collector as the receiver so a captured
                        // receiver-function lambda (Flow `map`'s
                        // `{ v -> emit(transform(v)) }`) targets the
                        // right downstream collector. A non-receiver
                        // value lambda (`{ it * 10 }`) ignores the
                        // bound receiver — `invoke_callable_with_this`
                        // only delivers it through a `this` capture or
                        // a zero-param positional, never displacing a
                        // declared value parameter.
                        let callee_r = resolve_capture(b, name0);
                        let this_reg = if b.knows_outer("this")
                            || b.is_lambda_body()
                        {
                            Some(resolve_capture(b, "this"))
                        } else {
                            b.resolve("this")
                        };
                        let (args_start, count) = lower_arg_run(b, args);
                        let arg_names =
                            intern_arg_names(b.module, ast_arg_names);
                        let dst = b.alloc_reg();
                        if let Some(recv) = this_reg {
                            b.push(Inst::CallValueWithThis {
                                dst,
                                callee: callee_r,
                                receiver: recv,
                                args: args_start,
                                n_args: count,
                                arg_names,
                            });
                        } else {
                            b.push(Inst::CallValue {
                                dst,
                                callee: callee_r,
                                args: args_start,
                                n_args: count,
                                arg_names,
                            });
                        }
                        return dst;
                    }
                    // FQN-precedence for the bare call: when this
                    // module declares multiple functions sharing the
                    // simple name (i.e. cross-package collision), an
                    // explicit `import a.b.foo` routes `foo()` to
                    // `a.b.foo` instead of whichever candidate landed
                    // first in `func_index`. Matches Kotlin's
                    // resolver where an explicit import beats any
                    // wildcard / default candidate. Limited to the
                    // collision case so single-candidate lookups stay
                    // on their existing path (pack-internal calls
                    // would otherwise be diverted by stray imports
                    // they neither own nor expect to honour).
                    let collision = b
                        .module
                        .funcs_by_simple_name(&segments[0].name)
                        .len()
                        > 1;
                    let imported_func_id = if collision {
                        b.module
                            .registry
                            .import_aliases
                            .get(&segments[0].name)
                            .filter(|segs| segs.len() >= 2)
                            .and_then(|segs| {
                                b.module.func_id_by_fqn(&segs.join("."))
                            })
                    } else {
                        None
                    };
                    if let Some(func_id) = imported_func_id.filter(|_| !shadowed_by_class) {
                        // Skip the redirect when the resolved
                        // candidate is itself an extension whose
                        // dispatch the regular func_id path
                        // (this-prepended) handles correctly — the
                        // bare-call branch would lose the receiver.
                        let needs_this = b
                            .module
                            .funcs
                            .get(func_id.0 as usize)
                            .map(|f| f.params.first().map(|p| p.name == "this").unwrap_or(false))
                            .unwrap_or(false);
                        if !needs_this {
                            let (args_start, count) = lower_arg_run(b, args);
                            let arg_names = intern_arg_names(b.module, ast_arg_names);
                            let type_args = intern_type_args(b.module, ast_type_args);
                            let dst = b.alloc_reg();
                            b.push(Inst::Call {
                                dst,
                                func: func_id,
                                args: args_start,
                                n_args: count,
                                arg_names,
                                type_args,
                            });
                            return dst;
                        }
                    }
                    // Arity-aware bare-call lookup. The legacy
                    // `Module::func_id` returns the first user-FQN or
                    // first overall — when multiple same-named
                    // overloads exist (e.g. `CharSequence.maxOf(selector)`
                    // and the top-level `kotlin.comparisons.maxOf(a, b)`)
                    // it can return one whose arity doesn't fit the
                    // call. Prefer a candidate that matches arity.
                    let want = args.len();
                    let cands: Vec<FuncId> = b
                        .module
                        .funcs_by_simple_name(&segments[0].name)
                        .to_vec();
                    let user_params = |f: &Func| {
                        if f.params.first().map_or(false, |p| p.name == "this") {
                            f.params.len() - 1
                        } else {
                            f.params.len()
                        }
                    };
                    let arity_match = |fid: &FuncId| -> bool {
                        b.module
                            .funcs
                            .get(fid.0 as usize)
                            .map_or(false, |f| {
                                // A bodyless `expect` decl can't be
                                // called directly — its actual lives
                                // in the host's intrinsic table.
                                // Skip it so the binding falls through
                                // to the implicit-alias / global
                                // path that resolves the actual.
                                !f.blocks.is_empty() && user_params(f) == want
                            })
                    };
                    let non_ext = |fid: &FuncId| {
                        b.module
                            .funcs
                            .get(fid.0 as usize)
                            .map_or(false, |f| {
                                f.params
                                    .first()
                                    .map(|p| p.name != "this")
                                    .unwrap_or(true)
                            })
                    };
                    // Names known to be backed by an intrinsic /
                    // implicit-alias (kotlin.* top-level). When no
                    // arity-matching IR func exists for these, decline
                    // the bind so the call routes through the global
                    // intrinsic path that the interp host populates.
                    // Mirrors a subset of `klio_stdlib::IMPLICIT_ALIASES`;
                    // klio-ir can't depend on klio-stdlib so the list
                    // is duplicated here.
                    let name_is_alias = matches!(
                        segments[0].name.as_str(),
                        "maxOf"
                            | "minOf"
                            | "max"
                            | "min"
                            | "print"
                            | "println"
                            | "listOf"
                            | "mutableListOf"
                            | "arrayListOf"
                            | "setOf"
                            | "mutableSetOf"
                            | "hashSetOf"
                            | "linkedSetOf"
                            | "mapOf"
                            | "mutableMapOf"
                            | "hashMapOf"
                            | "linkedMapOf"
                            | "arrayOf"
                            | "emptyList"
                            | "emptySet"
                            | "emptyMap"
                            | "listOfNotNull"
                            | "setOfNotNull"
                            | "buildList"
                            | "buildSet"
                            | "buildMap"
                            | "buildString"
                            | "TODO"
                            | "error"
                            | "compareValues"
                            | "compareValuesBy"
                            | "compareBy"
                            | "compareByDescending"
                            | "naturalOrder"
                            | "reverseOrder"
                    );
                    let bare_func_id: Option<FuncId> = cands
                        .iter()
                        .find(|fid| non_ext(fid) && arity_match(fid))
                        .copied()
                        .or_else(|| {
                            cands.iter().find(|fid| !non_ext(fid) && arity_match(fid)).copied()
                        })
                        .or_else(|| {
                            if name_is_alias {
                                None
                            } else {
                                b.module.func_id(&segments[0].name)
                            }
                        });
                    if let Some(func_id) =
                        bare_func_id.filter(|_| !shadowed_by_class)
                    {
                        // Extension fn called by its bare name from inside
                        // a receiver-typed scope: prepend the active
                        // `this` reg so `this.launch(block)` flows through
                        // the same Call inst the qualified form would
                        // emit. Detected by the resolved func declaring
                        // `this` as its first param.
                        let needs_this = b
                            .module
                            .funcs
                            .get(func_id.0 as usize)
                            .map(|f| f.params.first().map(|p| p.name == "this").unwrap_or(false))
                            .unwrap_or(false);
                        if needs_this {
                            // Resolve a `this` reg even from a lambda
                            // body that hasn't bound it locally — fall
                            // back to a capture so the eval frame
                            // loads the receiver value populated by
                            // `invoke_callable_with_this`.
                            let this_reg_opt: Option<Reg> = b
                                .resolve("this")
                                .or_else(|| {
                                    if b.knows_outer("this") || b.is_lambda_body() {
                                        let idx = b.record_capture("this");
                                        let dst = b.alloc_reg();
                                        b.push(Inst::LoadCapture { dst, idx });
                                        b.bind("this".to_string(), dst);
                                        Some(dst)
                                    } else {
                                        None
                                    }
                                });
                            if let Some(this_reg) = this_reg_opt {
                                let mut all: Vec<Expr> =
                                    Vec::with_capacity(args.len() + 1);
                                // Synthesise a Path("this") arg expr; the
                                // existing arg-run path resolves it back
                                // to the bound reg.
                                let synth = Expr::Path {
                                    segments: vec![klio_ast::Ident {
                                        name: "this".to_string(),
                                        span: expr_span(callee.as_ref()),
                                    }],
                                    span: expr_span(callee.as_ref()),
                                };
                                all.push(synth);
                                all.extend(args.iter().cloned());
                                let (args_start, count) = lower_arg_run(b, &all);
                                // Trailing-lambda routing for extension
                                // fns with default-valued middle params
                                // (`fun T.launch(context = …, block)` —
                                // `obj.launch { … }` skips the default
                                // context, assigns the lambda to `block`).
                                // Build per-arg names by aligning user-
                                // supplied args with the func's tail
                                // params and emitting an explicit
                                // arg-name for the last user-supplied
                                // arg so call_func_named slots it
                                // correctly.
                                let mut arg_names = intern_arg_names(b.module, ast_arg_names);
                                let target_params: Vec<String> = b
                                    .module
                                    .funcs
                                    .get(func_id.0 as usize)
                                    .map(|f| {
                                        f.params.iter().map(|p| p.name.clone()).collect()
                                    })
                                    .unwrap_or_default();
                                let user_arg_count = all.len() - 1;
                                if !target_params.is_empty()
                                    && user_arg_count >= 1
                                    && (1 + user_arg_count) < target_params.len()
                                    && ast_arg_names.iter().all(|n| n.is_none())
                                {
                                    // Synthesise arg_names: positional for
                                    // injected `this` + each user arg,
                                    // then re-tag the last user arg with
                                    // the last param's name so it routes
                                    // to that slot.
                                    let mut names: Vec<Option<crate::ConstId>> =
                                        vec![None; all.len()];
                                    let last_param = target_params.last().cloned();
                                    if let Some(p_name) = last_param {
                                        let cid = b.module.intern_const(Const::String(p_name));
                                        let last_idx = names.len() - 1;
                                        names[last_idx] = Some(cid);
                                    }
                                    arg_names = names;
                                }
                                let type_args = intern_type_args(b.module, ast_type_args);
                                // Unqualified call inside a receiver
                                // scope: a member of the (possibly
                                // smart-cast) implicit receiver outranks
                                // a same-named top-level extension. Route
                                // through `call_member` on `this` so the
                                // full precedence applies: receiver
                                // member (using the runtime subtype),
                                // then the builtin/stdlib intrinsic,
                                // then the best-by-receiver extension
                                // fallback.
                                // A direct `Call` to one resolved
                                // `func_id` bypassed all of that and
                                // could recurse (`resumeCancellableWith`)
                                // or mis-bind on a builtin receiver. The
                                // defaulted-middle-param trailing-lambda
                                // arg-name synthesis is extension-fn
                                // specific, so keep the direct `Call`
                                // there.
                                let synth_names_needed = !target_params
                                    .is_empty()
                                    && user_arg_count >= 1
                                    && (1 + user_arg_count)
                                        < target_params.len()
                                    && ast_arg_names
                                        .iter()
                                        .all(|n| n.is_none());
                                if !synth_names_needed {
                                    // Kotlin: a member of the
                                    // (smart-cast) implicit receiver
                                    // outranks a same-named top-level
                                    // extension. Route through
                                    // `call_member` on `this` so the
                                    // full precedence applies —
                                    // receiver member (incl. a runtime
                                    // subtype's), then builtin/stdlib
                                    // intrinsic, then the
                                    // best-by-receiver extension-fn
                                    // fallback. A direct `Call` to one
                                    // by-name `func_id` bypassed this
                                    // (recursed for
                                    // `resumeCancellableWith`,
                                    // mis-bound on `Result`).
                                    let (uargs_start, ucount) =
                                        lower_arg_run(b, args);
                                    let uarg_names = intern_arg_names(
                                        b.module,
                                        ast_arg_names,
                                    );
                                    let nmc = b.module.intern_const(
                                        Const::String(
                                            segments[0].name.clone(),
                                        ),
                                    );
                                    let dst = b.alloc_reg();
                                    // In a receiver-lambda body the
                                    // implicit `this` is a capture that
                                    // a `this`-binding invoke may have
                                    // displaced (e.g. `flow { forEach {
                                    // emit(it) } }` inside
                                    // `List.asFlow()`: `this` is the
                                    // FlowCollector, but `forEach`
                                    // targets the enclosing `this@asFlow`
                                    // receiver). CallMemberOrGlobal adds
                                    // the enclosing-`this` and global /
                                    // extension fallbacks that plain
                                    // CallMember lacks, so the call
                                    // resolves against the lexically
                                    // enclosing receiver when the lambda
                                    // receiver has no such member.
                                    if b.is_lambda_body() {
                                        let this_idx =
                                            b.record_capture("this");
                                        b.push(Inst::CallMemberOrGlobal {
                                            dst,
                                            this_idx,
                                            name: nmc,
                                            args: uargs_start,
                                            n_args: ucount,
                                            arg_names: uarg_names,
                                        });
                                        return dst;
                                    }
                                    b.push(Inst::CallMember {
                                        dst,
                                        receiver: this_reg,
                                        name: nmc,
                                        args: uargs_start,
                                        n_args: ucount,
                                        arg_names: uarg_names,
                                    });
                                    return dst;
                                }
                                let dst = b.alloc_reg();
                                let _ = this_reg;
                                b.push(Inst::Call {
                                    dst,
                                    func: func_id,
                                    args: args_start,
                                    n_args: count,
                                    arg_names,
                                    type_args,
                                });
                                return dst;
                            }
                            // No `this` in scope — fall through to the
                            // unmodified Call below; runtime will error
                            // with a clearer "missing receiver" diag.
                        }
                        let callee_is_tailrec = b
                            .module
                            .funcs
                            .get(func_id.0 as usize)
                            .map_or(false, |f| f.is_tailrec)
                            || b.module.tailrec_fn_names.iter().any(|n| n == &segments[0].name);
                        if b.tailrec_self().is_some() && callee_is_tailrec && ast_arg_names.iter().all(|n| n.is_none()) {
                            let (args_start, count) = lower_arg_run(b, args);
                            b.terminate(Terminator::TailCallFunc {
                                func: func_id,
                                args: args_start,
                                n_args: count,
                            });
                            let dead = b.alloc_block();
                            b.switch_to(dead);
                            return b.emit_const(Const::Unit);
                        }
                        let (args_start, count) = lower_arg_run(b, args);
                        let arg_names = intern_arg_names(b.module, ast_arg_names);
                        let type_args = intern_type_args(b.module, ast_type_args);
                        let dst = b.alloc_reg();
                        b.push(Inst::Call {
                            dst,
                            func: func_id,
                            args: args_start,
                            n_args: count,
                            arg_names,
                            type_args,
                        });
                        return dst;
                    }
                }
            }
            // Path-callee with a registered class name → NewInstance.
            if let Expr::Path { segments, .. } = callee.as_ref() {
                if segments.len() == 1 {
                    if let Some(class_id) = b.module.class_id(&segments[0].name) {
                        let (args_start, count) = lower_arg_run(b, args);
                        let arg_names = intern_arg_names(b.module, ast_arg_names);
                        let dst = b.alloc_reg();
                        b.push(Inst::NewInstance {
                            dst,
                            class: class_id,
                            args: args_start,
                            n_args: count,
                            arg_names,
                        });
                        return dst;
                    }
                }
            }
            // Inside a method/extension body: unqualified `name(...)`
            // that didn't match a local / top-level fn / class is
            // most likely a method call on `this`. Emit
            // `this.name(args)` via CallMember so the receiver's
            // class dispatch (including IR-native FuncId lookup)
            // fires.
            if let Expr::Path { segments, .. } = callee.as_ref() {
                // A bare contract call carrying a trailing
                // lazy-message lambda — `require(cond) { "msg" }` /
                // `check(...) { ... }` — is the stdlib contract,
                // not a same-named user member. Kotlin resolves
                // this by applicability; here the trailing lambda
                // is the discriminator.
                let contract_with_msg = segments.len() == 1
                    && matches!(
                        segments[0].name.as_str(),
                        "require" | "check" | "checkNotNull"
                    )
                    && matches!(args.last(), Some(Expr::Lambda { .. }));
                if segments.len() == 1
                    && !contract_with_msg
                    && b.resolve(&segments[0].name).is_none()
                    && !b.knows_outer(&segments[0].name)
                    // Only emit this.name(...) when the owning
                    // class declares this name (method or
                    // property); otherwise it's a global call
                    // and the normal CallValue path should fire.
                    && b.has_own_member(&segments[0].name)
                {
                    if let Some(this_reg) = b.resolve("this") {
                        // Private own-class methods bind statically:
                        // a `private fun` is invisible to subclasses,
                        // so a bare call to one must reach the
                        // declaring-class implementation rather than
                        // a same-named override in a subclass that
                        // happens to be the runtime receiver.
                        if let Some(fid) =
                            b.private_method_fid(&segments[0].name)
                        {
                            // Prepend `this` as the first positional
                            // argument; the static call's param[0] is
                            // the implicit receiver. The arg-names
                            // vector also gets a leading None so a
                            // named-arg call (`pick(b = 5)`) doesn't
                            // mis-bind the `this` slot to the user's
                            // first named parameter.
                            let args_start = b.alloc_reg();
                            b.push(Inst::Move {
                                dst: args_start,
                                src: this_reg,
                            });
                            for (i, a) in args.iter().enumerate() {
                                let r = lower_expr(b, a);
                                b.push(Inst::Move {
                                    dst: Reg(args_start.0 + i as u32 + 1),
                                    src: r,
                                });
                            }
                            let mut user_arg_names: Vec<Option<String>> =
                                vec![None];
                            user_arg_names.extend(ast_arg_names.iter().cloned());
                            let arg_names = intern_arg_names(b.module, &user_arg_names);
                            let dst = b.alloc_reg();
                            b.push(Inst::Call {
                                dst,
                                func: fid,
                                args: args_start,
                                n_args: args.len() as u8 + 1,
                                arg_names,
                                type_args: Vec::new(),
                            });
                            return dst;
                        }
                        let (args_start, count) = lower_arg_run(b, args);
                        let arg_names = intern_arg_names(b.module, ast_arg_names);
                        let dst = b.alloc_reg();
                        let nm = b
                            .module
                            .intern_const(Const::String(segments[0].name.clone()));
                        b.push(Inst::CallMember {
                            dst,
                            receiver: this_reg,
                            name: nm,
                            args: args_start,
                            n_args: count,
                            arg_names,
                        });
                        return dst;
                    }
                }
            }
            // Unresolved bare-name call. Inside a lambda body that
            // may be invoked with a this-binding, dispatch through
            // CallMemberOrGlobal so a method on the captured this
            // wins over a top-level lookup. For non-lambda frames
            // (or lambdas not this-bound) the captured this is
            // Null and the inst falls back to a regular global
            // call.
            if let Expr::Path { segments, .. } = callee.as_ref() {
                if segments.len() == 1
                    && b.resolve(&segments[0].name).is_none()
                    && !b.knows_outer(&segments[0].name)
                    && b.module.class_id(&segments[0].name).is_none()
                    && b.module.func_id(&segments[0].name).is_none()
                {
                    // Inside a method / extension body `this` is a
                    // bound param (not a capture). A bare primitive
                    // conversion call — `toInt()` in `fun Byte.and(o)
                    // = toInt() and o` — is a member call on the
                    // receiver. The receiver is a primitive with no
                    // class member table, and CallMemberOrGlobal only
                    // sees a *captured* `this` (Null for a param), so
                    // dispatch straight on the `this` reg. Limited to
                    // the fixed set of stdlib conversion names, none
                    // of which is ever a top-level function, so
                    // ordinary global calls are unaffected.
                    // A bare call to a name the enclosing anon object
                    // closes over invokes that lexically-captured
                    // value. Read it via `LoadCapture` (this instance's
                    // snapshot) and `CallValue` so a captured closure
                    // keeps its own captures and cannot recurse onto a
                    // same-named capture of an enclosing anon method.
                    if is_lower_anon_capture(&segments[0].name) {
                        let idx = b.record_capture(&segments[0].name);
                        let callee_r = b.alloc_reg();
                        b.push(Inst::LoadCapture { dst: callee_r, idx });
                        let (args_start, count) = lower_arg_run(b, args);
                        let arg_names =
                            intern_arg_names(b.module, ast_arg_names);
                        let dst = b.alloc_reg();
                        b.push(Inst::CallValue {
                            dst,
                            callee: callee_r,
                            args: args_start,
                            n_args: count,
                            arg_names,
                        });
                        return dst;
                    }
                    let is_primitive_conv = matches!(
                        segments[0].name.as_str(),
                        "toInt"
                            | "toLong"
                            | "toByte"
                            | "toShort"
                            | "toDouble"
                            | "toFloat"
                            | "toChar"
                            | "toBoolean"
                            | "toUInt"
                            | "toULong"
                            | "toUByte"
                            | "toUShort"
                    );
                    if is_primitive_conv {
                        if let Some(this_reg) = b.resolve("this") {
                            let (args_start, count) = lower_arg_run(b, args);
                            let arg_names = intern_arg_names(b.module, ast_arg_names);
                            let dst = b.alloc_reg();
                            let nm = b
                                .module
                                .intern_const(Const::String(segments[0].name.clone()));
                            b.push(Inst::CallMember {
                                dst,
                                receiver: this_reg,
                                name: nm,
                                args: args_start,
                                n_args: count,
                                arg_names,
                            });
                            return dst;
                        }
                    }
                    let this_idx = b.record_capture("this");
                    let (args_start, count) = lower_arg_run(b, args);
                    let arg_names = intern_arg_names(b.module, ast_arg_names);
                    let dst = b.alloc_reg();
                    let nm = b.module.intern_const(Const::String(segments[0].name.clone()));
                    b.push(Inst::CallMemberOrGlobal {
                        dst,
                        this_idx,
                        name: nm,
                        args: args_start,
                        n_args: count,
                        arg_names,
                    });
                    return dst;
                }
            }
            // Built-in stdlib companion shortcuts: `Result.success(x)`,
            // `Result.failure(e)`, etc. The callee parses as
            // Member { Path("Result"), "success" }; rewrite to a
            // direct stdlib FQN dispatch. The class_id check is
            // intentionally omitted for these specific names — once
            // upstream `kotlin/util/Result.kt` is shipped, klio's
            // class table contains a `Result` entry and the shortcut
            // would otherwise be skipped, causing the call to fall
            // through to a member-dispatch path that doesn't know
            // about the Companion.
            if let Expr::Member { receiver: recv_box, name: mname, .. } = callee.as_ref() {
                if let Expr::Path { segments, .. } = recv_box.as_ref() {
                    if segments.len() == 1
                        && b.resolve(&segments[0].name).is_none()
                        && !b.knows_outer(&segments[0].name)
                    {
                        let head = &segments[0].name;
                        let companion_fqns: &[(&str, &str, &str)] = &[
                            ("Result", "success", "kotlin.Result.Companion.success"),
                            ("Result", "failure", "kotlin.Result.Companion.failure"),
                        ];
                        for (cls, method, fqn) in companion_fqns {
                            if head == cls && mname.name == *method {
                                let callee_r = b.alloc_reg();
                                let n = b.module.intern_const(Const::String((*fqn).to_string()));
                                b.push(Inst::LoadGlobal { dst: callee_r, name: n });
                                let (args_start, count) = lower_arg_run(b, args);
                                let arg_names = intern_arg_names(b.module, ast_arg_names);
                                let dst = b.alloc_reg();
                                b.push(Inst::CallValue {
                                    dst,
                                    callee: callee_r,
                                    args: args_start,
                                    n_args: count,
                                    arg_names,
                                });
                                return dst;
                            }
                        }
                    }
                }
            }
            // Package-qualified call to a user / pack top-level
            // function. `func_index` is keyed by simple name (the
            // package prefix lives on the decl's `fqn`), so resolve
            // the trailing segment and emit the same `Inst::Call`
            // the bare-name form uses; eval's `pick_overload` then
            // selects the right shape by runtime arg types. Only
            // fires when the tail names a module function, so
            // intrinsic FQNs still take the LoadGlobal path below.
            if let Expr::Member { .. } = callee.as_ref() {
                if let Some(fqn) = collect_dotted_fqn(callee) {
                    if let (Some(head), Some(tail)) =
                        (fqn.split('.').next(), fqn.rsplit('.').next())
                    {
                        // A real package root (`kotlin.…`, `kotlinx.…`,
                        // …) is never a member of an enclosing
                        // receiver, even when `this` is bound — Kotlin
                        // resolves the qualified call against the
                        // package, not the receiver. Allow the FQN
                        // flattening through in that case so a
                        // `kotlin.synchronized(this, block)` call
                        // inside an extension function body doesn't
                        // get misread as `this.kotlin.synchronized`.
                        let head_is_real_pkg = is_pkg_root(head);
                        if tail != fqn
                            && is_package_head(head)
                            && (head_is_real_pkg || !b.is_lambda_body())
                            && b.resolve(head).is_none()
                            && !b.knows_outer(head)
                            && b.module.class_id(head).is_none()
                            && (head_is_real_pkg || b.resolve("this").is_none())
                        {
                            // Arity-aware lookup for FQN-flatten calls:
                            // `kotlin.math.max(3, 9)` must bind to the
                            // 2-arg `max` (`kotlin.comparisons.max` /
                            // `kotlin.math.max`), not the 1-param
                            // `CharSequence.max()` from `_Strings.kt`.
                            // Prefer an FQN match, then arity-matched
                            // non-extension, then any FQN match.
                            let want = args.len();
                            let prefix = &fqn;
                            let cands: Vec<FuncId> = b
                                .module
                                .funcs_by_simple_name(tail)
                                .to_vec();
                            let pick = cands
                                .iter()
                                .find(|fid| {
                                    let f = match b
                                        .module
                                        .funcs
                                        .get(fid.0 as usize)
                                    {
                                        Some(f) => f,
                                        None => return false,
                                    };
                                    f.fqn == *prefix && f.params.len() == want
                                })
                                .or_else(|| {
                                    cands.iter().find(|fid| {
                                        let f = match b
                                            .module
                                            .funcs
                                            .get(fid.0 as usize)
                                        {
                                            Some(f) => f,
                                            None => return false,
                                        };
                                        let first_is_this = f
                                            .params
                                            .first()
                                            .map(|p| p.name == "this")
                                            .unwrap_or(false);
                                        !first_is_this && f.params.len() == want
                                    })
                                })
                                .copied();
                            if let Some(func_id) = pick {
                                let (args_start, n_args) = lower_arg_run(b, args);
                                let arg_names =
                                    intern_arg_names(b.module, ast_arg_names);
                                let type_args =
                                    intern_type_args(b.module, ast_type_args);
                                let dst = b.alloc_reg();
                                b.push(Inst::Call {
                                    dst,
                                    func: func_id,
                                    args: args_start,
                                    n_args,
                                    arg_names,
                                    type_args,
                                });
                                return dst;
                            }
                        }
                    }
                }
            }
            // Fully-qualified callee like `kotlin.math.abs(x)` →
            // resolve the FQN as a global and CallValue against the
            // resulting intrinsic / function value. Avoids the
            // chained-GetField that would fail at `kotlin` itself.
            if let Expr::Member { .. } = callee.as_ref() {
                if let Some(fqn) = collect_dotted_fqn(callee) {
                    if let Some(head) = fqn.split('.').next() {
                        let head_is_real_pkg = is_pkg_root(head);
                        if is_package_head(head)
                            && (head_is_real_pkg || !b.is_lambda_body())
                            && b.resolve(head).is_none()
                            && !b.knows_outer(head)
                            && b.module.class_id(head).is_none()
                            // When `this` is bound (we're inside a
                            // method body) the head could be a
                            // field on `this`; don't treat it as a
                            // package FQN unless that field doesn't
                            // exist on the receiver class. A real
                            // package root (`kotlin.…`, `kotlinx.…`)
                            // is never a member of `this`, so allow
                            // it through unconditionally.
                            && (head_is_real_pkg || b.resolve("this").is_none())
                        {
                            let callee_r = b.alloc_reg();
                            let n = b.module.intern_const(Const::String(fqn));
                            b.push(Inst::LoadGlobal { dst: callee_r, name: n });
                            let (args_start, count) = lower_arg_run(b, args);
                            let arg_names = intern_arg_names(b.module, ast_arg_names);
                            let dst = b.alloc_reg();
                            b.push(Inst::CallValue {
                                dst,
                                callee: callee_r,
                                args: args_start,
                                n_args: count,
                                arg_names,
                            });
                            return dst;
                        }
                    }
                }
            }
            // Lower the callee's receiver / value separately so the
            // dispatcher knows whether to emit CallMember or
            // CallValue.
            match callee.as_ref() {
                Expr::Member { receiver, name, .. } => {
                    // Receiver-typed lambda invocation: `list.block()`
                    // where `block: T.() -> R` is a local. Lower
                    // as CallValueWithThis so the host binds the
                    // receiver as `this` inside the lambda body.
                    // Gated tight so stdlib member calls like
                    // `xs.sorted()` aren't hijacked by a shared
                    // name.
                    // Only fire when the local name is bound AND
                    // the local has a function-like type. We
                    // can't check types at IR-lowering time, but
                    // most class methods aren't shadowed by
                    // locals — gate the arm narrowly on "name is
                    // a known param of the enclosing fn".
                    // A bound local named `name` shadows any member:
                    // `recv.name(args)` invokes that local. This
                    // covers a local extension function (`fun
                    // List<T>.mid() = …`, whose closure takes the
                    // receiver as its implicit `this` param) and a
                    // receiver-typed lambda parameter (`block: T.() ->
                    // R`). In both cases the receiver is the first
                    // positional argument (the closure's param 0 is
                    // `this`), so a plain CallValue suffices and we
                    // avoid the unsupported call_value_with_this.
                    // Only a local *function* (or function-typed
                    // param like `block: T.() -> R`) shadows
                    // `recv.name()` — a local `val`/`var` of the same
                    // name must NOT hijack a stdlib/member call
                    // (`val sorted = …; xs.sorted()` is the member).
                    // A captured outer name that holds a callable
                    // (e.g. a `Sink.(Int) -> Unit` parameter closed
                    // over by a returned lambda, invoked as
                    // `sink.g(v)`) shadows a member exactly like a
                    // local param/fn. CallMemberOrValue still tries
                    // the receiver's member first, so a captured
                    // non-callable can't hijack a real member call.
                    let anon_cap = is_lower_anon_capture(&name.name)
                        && b.resolve(&name.name).is_none()
                        && !b.is_local_fn(&name.name)
                        && !b.is_param(&name.name)
                        && !b.knows_outer(&name.name);
                    let local_callable = b.is_local_fn(&name.name)
                        || b.is_param(&name.name)
                        || b.knows_outer(&name.name)
                        || anon_cap;
                    if local_callable {
                        // For an anon-object method a captured name
                        // reaches the body as a lexical capture: record
                        // it and emit `LoadCapture` so it reads this
                        // instance's snapshot (a captured closure keeps
                        // its own captures and cannot collide with a
                        // same-named capture of an enclosing anon
                        // method). Otherwise capture on demand.
                        let local_reg = if anon_cap {
                            let idx = b.record_capture(&name.name);
                            let r = b.alloc_reg();
                            b.push(Inst::LoadCapture { dst: r, idx });
                            r
                        } else {
                            resolve_capture(b, &name.name)
                        };
                        // `recv.name(args)` where `name` is also a
                        // callable local/param. Kotlin dispatches the
                        // member when `recv`'s type has it, and only
                        // the local (a local extension fn, or a
                        // `T.() -> R` param invoked as `recv.block()`)
                        // when it does not. That needs the receiver's
                        // runtime type, so emit CallMemberOrValue: the
                        // member wins if present, else the local is
                        // invoked with `recv` prepended.
                        let recv = lower_receiver(b, receiver);
                        let (args_start, count) = lower_arg_run(b, args);
                        let arg_names = intern_arg_names(b.module, ast_arg_names);
                        let nm =
                            b.module.intern_const(Const::String(name.name.clone()));
                        let dst = b.alloc_reg();
                        b.push(Inst::CallMemberOrValue {
                            dst,
                            receiver: recv,
                            name: nm,
                            fallback: local_reg,
                            args: args_start,
                            n_args: count,
                            arg_names,
                        });
                        return dst;
                    }
                    // `super.method(...)` — emit `CallSuper` so the
                    // host walks the parent class chain rather
                    // than re-entering the leaf class's override.
                    // `super<Klazz>.method()` passes Klazz so the
                    // host dispatches against that specific
                    // supertype.
                    if let Expr::Super { qualifier, label, .. } = receiver.as_ref() {
                        if let Some(this_reg) = b.resolve("this") {
                            if let Some(owner) = b.owner_class().map(|s| s.to_string()) {
                                let (args_start, count) = lower_arg_run(b, args);
                                let arg_names = intern_arg_names(b.module, ast_arg_names);
                                let dst = b.alloc_reg();
                                let nm = b.module.intern_const(Const::String(name.name.clone()));
                                let oc = b.module.intern_const(Const::String(owner));
                                // `super<Q>` uses `qualifier` (type
                                // ref); `super@Q` uses `label` (an
                                // identifier).
                                let qual_const = qualifier
                                    .as_ref()
                                    .map(|t| {
                                        b.module.intern_const(Const::String(t.name.name.clone()))
                                    })
                                    .or_else(|| {
                                        label.as_ref().map(|id| {
                                            b.module
                                                .intern_const(Const::String(id.name.clone()))
                                        })
                                    });
                                b.push(Inst::CallSuper {
                                    dst,
                                    receiver: this_reg,
                                    owner_class: oc,
                                    qualifier: qual_const,
                                    name: nm,
                                    args: args_start,
                                    n_args: count,
                                    arg_names,
                                });
                                return dst;
                            }
                        }
                    }
                    // Statically rebind `(e as T).f(args)` to the `f`
                    // overload whose first-param type is `T`. Upstream
                    // bodies (`String.padStart` → `(this as CharSequence).
                    // padStart(...).toString()`) rely on JVM-style
                    // static-receiver dispatch; klio dispatches by
                    // the runtime value's type, so without this the
                    // call rebinds to the `String` overload and
                    // recurses. Only fires for non-safe `as`-casts —
                    // safe `as?` semantics need a null branch.
                    if let Expr::As { ty: cast_ty, safe: false, .. } =
                        receiver.as_ref()
                    {
                        let want_user = args.len();
                        let chosen = b
                            .module
                            .funcs_by_simple_name(&name.name)
                            .iter()
                            .filter_map(|fid| {
                                let f = b.module.funcs.get(fid.0 as usize)?;
                                if f.blocks.is_empty() {
                                    return None;
                                }
                                let p0 = f.params.first()?;
                                if p0.name != "this" || p0.ty.name != cast_ty.name.name {
                                    return None;
                                }
                                let user = f.params.len() - 1;
                                let arity_ok = user == want_user
                                    || (want_user < user
                                        && f.params[(1 + want_user)..]
                                            .iter()
                                            .all(|p| p.default.is_some() || p.is_vararg))
                                    || (want_user > user
                                        && f.params
                                            .last()
                                            .map_or(false, |p| p.is_vararg));
                                if arity_ok { Some(*fid) } else { None }
                            })
                            .next();
                        if let Some(func_id) = chosen {
                            // Build a contiguous arg run: receiver at
                            // slot 0, user args following. lower the
                            // receiver expression (the `as`-cast is a
                            // no-op on klio runtime values, but the
                            // emitted `Inst::Cast` keeps the schema
                            // honest), then lower each user arg.
                            let recv_reg = lower_receiver(b, receiver);
                            let mut arg_regs: Vec<Reg> =
                                Vec::with_capacity(args.len() + 1);
                            arg_regs.push(recv_reg);
                            for a in args {
                                arg_regs.push(lower_expr(b, a));
                            }
                            let n = arg_regs.len() as u8;
                            let start = b.alloc_reg();
                            b.push(Inst::Move { dst: start, src: arg_regs[0] });
                            for r in &arg_regs[1..] {
                                let slot = b.alloc_reg();
                                b.push(Inst::Move { dst: slot, src: *r });
                            }
                            let arg_names =
                                intern_arg_names(b.module, ast_arg_names);
                            let type_args =
                                intern_type_args(b.module, ast_type_args);
                            let dst = b.alloc_reg();
                            b.push(Inst::Call {
                                dst,
                                func: func_id,
                                args: start,
                                n_args: n,
                                arg_names,
                                type_args,
                            });
                            return dst;
                        }
                    }
                    let recv = lower_receiver(b, receiver);
                    let (args_start, count) = lower_arg_run(b, args);
                    let arg_names = intern_arg_names(b.module, ast_arg_names);
                    let dst = b.alloc_reg();
                    let nm = b.module.intern_const(Const::String(name.name.clone()));
                    b.push(Inst::CallMember {
                        dst,
                        receiver: recv,
                        name: nm,
                        args: args_start,
                        n_args: count,
                        arg_names,
                    });
                    dst
                }
                _ => {
                    let callee_r = lower_expr(b, callee);
                    let (args_start, count) = lower_arg_run(b, args);
                    let arg_names = intern_arg_names(b.module, ast_arg_names);
                    let dst = b.alloc_reg();
                    b.push(Inst::CallValue {
                        dst,
                        callee: callee_r,
                        args: args_start,
                        n_args: count,
                        arg_names,
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
        Expr::Return { value, label, .. } => {
            let r = match value {
                Some(e) => Some(lower_expr(b, e)),
                None => None,
            };
            // An unlabeled `return` inside an inlined body returns
            // from that inline fn — which, inlined, is the call's
            // value. Spliced lambda-arg bodies clear the inline-return
            // target, so their non-local `return` falls through to
            // the caller path below (Kotlin non-local semantics).
            if label.is_none() {
                if let Some((res, join)) = b.inline_active_return() {
                    if let Some(rr) = r {
                        b.push(Inst::Move { dst: res, src: rr });
                    }
                    // Replay every active `finally { … }` block
                    // inline before exiting, matching JVM `try-
                    // finally` bytecode shape: each non-fallthrough
                    // exit from the try body copies the finally body
                    // at the exit point. Lower top-down (innermost
                    // first); each replay's own statements run with
                    // the remaining (outer) finallys still active so
                    // a `return` inside a finally body skips its own
                    // finally but still threads any further outers.
                    let pending = b.active_finallys();
                    if !pending.is_empty() {
                        let prior = b.swap_finally_stack(Vec::new());
                        for (idx, blk) in pending.iter().rev().enumerate() {
                            let outer = prior[..prior.len() - (idx + 1)].to_vec();
                            b.swap_finally_stack(outer);
                            let _ = lower_block(b, blk);
                        }
                        b.swap_finally_stack(prior);
                    }
                    b.terminate(Terminator::Goto(join));
                    let dead = b.alloc_block();
                    b.switch_to(dead);
                    return b.emit_const(Const::Unit);
                }
            }
            // `return@<inlineFnName>` inside a spliced inline-argument
            // lambda is a local return from that lambda invocation.
            if let Some(lbl) = label.as_ref() {
                if let Some((res, end)) = b.inline_lambda_ret_for(&lbl.name) {
                    if let Some(rr) = r {
                        b.push(Inst::Move { dst: res, src: rr });
                    }
                    b.terminate(Terminator::Goto(end));
                    let dead = b.alloc_block();
                    b.switch_to(dead);
                    return b.emit_const(Const::Unit);
                }
            }
            if let Some(lbl) = label.as_ref() {
                if b.current_inline_fn().is_some() {
                    // Inside a spliced inline body: a plain `Return`
                    // would exit the caller's whole function, not the
                    // labeled frame. `LabeledReturn` walks until the
                    // function whose name matches `lbl` catches it.
                    b.terminate(Terminator::LabeledReturn(lbl.name.clone(), r));
                } else {
                    // Non-spliced closure body: `return@label` here is
                    // a local return from the lambda invocation.
                    b.terminate(Terminator::Return(r));
                }
            } else if b.is_lambda_body() && !b.is_named_local_fn() {
                b.terminate(Terminator::NonLocalReturn(r));
            } else {
                b.terminate(Terminator::Return(r));
            }
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
        Expr::When { subject, subject_binding, branches, .. } => {
            // `when (val v = subject) { ... }` binds `v` to the
            // subject's value so pattern arms can refer to it. Push
            // a scope so the binding pops after the when.
            if let (Some(s), Some(bind)) = (subject.as_deref(), subject_binding) {
                b.push_scope();
                let sv = lower_expr(b, s);
                b.bind(bind.name.name.clone(), sv);
                let r = lower_when(b, subject.as_deref(), branches, expr_span(expr));
                b.pop_scope();
                r
            } else {
                lower_when(b, subject.as_deref(), branches, expr_span(expr))
            }
        }
        Expr::Try { body, catches, finally, .. } => {
            // Exception-edge model: the body block carries a list
            // of CatchHandlers (one per catch arm) and an optional
            // finally block. The evaluator's Throw terminator walks
            // the active block chain, matches the throw against
            // each handler's type_name, jumps to the matching
            // handler with the exception bound to its
            // exception_reg, and runs finally on every exit.
            //
            let result = b.alloc_reg();
            let exit = b.alloc_block();
            let finally_entry = finally.as_ref().map(|_| b.alloc_block());

            // Pre-allocate each catch handler's entry block + the
            // exception register. We'll fill in their bodies after
            // recording the handler metadata.
            let handlers: Vec<(klio_ast::Catch, BlockId, Reg)> = catches
                .iter()
                .map(|c| {
                    let blk = b.alloc_block();
                    let exc = b.alloc_reg();
                    (c.clone(), blk, exc)
                })
                .collect();

            // Body block: stitch CatchHandlers onto the cursor
            // block before lowering the body so any Throw fired
            // during body evaluation routes through them.
            let body_entry = b.alloc_block();
            b.terminate(Terminator::Goto(body_entry));
            b.switch_to(body_entry);
            let cur_id = b.cur;
            let catch_handlers: Vec<crate::CatchHandler> = handlers
                .iter()
                .map(|(c, blk, exc)| crate::CatchHandler {
                    type_name: c.ty.name.name.clone(),
                    handler: *blk,
                    exception_reg: *exc,
                })
                .collect();
            b.attach_catches(cur_id, catch_handlers, finally_entry);
            if let Some(blk) = finally {
                b.push_finally(blk.clone());
            }
            let body_val = lower_block(b, body);
            b.push(Inst::Move { dst: result, src: body_val });
            if let Some(fin) = finally_entry {
                b.terminate(Terminator::Goto(fin));
            } else {
                b.terminate(Terminator::Goto(exit));
            }

            // Each handler body: bind the exception, lower the
            // catch body, fall through to finally (or exit).
            for (c, blk, exc) in &handlers {
                b.switch_to(*blk);
                b.push_scope();
                b.bind(c.binding.name.clone(), *exc);
                let v = lower_block(b, &c.body);
                b.push(Inst::Move { dst: result, src: v });
                b.pop_scope();
                if let Some(fin) = finally_entry {
                    b.terminate(Terminator::Goto(fin));
                } else {
                    b.terminate(Terminator::Goto(exit));
                }
            }

            // Finally body (if present): lower it inside
            // `finally_entry`. Pop the active-finally stack first
            // so a `return` inside the finally body doesn't replay
            // itself.
            //
            // Routing every path out of the finally through a
            // separate sentinel `finally_done` block is what makes
            // the eval's pop-on-Goto check robust: the user finally
            // body may contain its own control flow (an `if`, a
            // `when`) so its last basic block isn't necessarily
            // `finally_entry`. We pin every fallthrough exit to
            // `finally_done` so the eval can pop the try-stack
            // entry when (and only when) `cur == finally_done` —
            // without that, a later `Return` walking outer scopes
            // would re-enter this finally a second time.
            if let Some(fin) = finally_entry {
                if finally.is_some() {
                    b.pop_finally();
                }
                let finally_done = b.alloc_block();
                b.switch_to(fin);
                if let Some(blk) = finally {
                    let _ = lower_block(b, blk);
                }
                b.terminate(Terminator::Goto(finally_done));
                b.switch_to(finally_done);
                b.set_finally_done_for(cur_id, finally_done);
                b.terminate(Terminator::Goto(exit));
            }

            b.switch_to(exit);
            result
        }
        Expr::Lambda { params, body, .. } => {
            // Lower a Kotlin lambda to a tree-walker-compatible
            // Value::Lambda by emitting Inst::AstLambda. The host
            // (klio-interp's IrHost) populates the captured env
            // from the snapshotted reg values + names — letting
            // existing dispatch paths (call_lambda, invoke_lambda)
            // call IR-lowered lambdas without each pattern-match
            // site adding a separate IrClosure branch.
            //
            // Free-variable analysis: collect every local name
            // visible in the enclosing scope, then walk the
            // lambda body via lower_lambda_body_capturing's
            // FuncBuilder to discover which ones get referenced.
            // Names not bound in the outer scope (top-level fns /
            // stdlib intrinsics) fall through to the tree walker's
            // global lookup at call time.
            let outer_names: std::collections::HashSet<String> = b.visible_names();
            let outer_boxed = b.boxed_vars_snapshot();
            let (body_func, captured_names) =
                lower_lambda_body_capturing(b.module, params, body, outer_names, &outer_boxed);
            let captures: Vec<Reg> = captured_names
                .iter()
                .map(|n| resolve_capture(b, n))
                .collect();
            let mut param_names: Vec<String> =
                params.iter().map(|p| p.name.clone()).collect();
            if param_names.is_empty() {
                param_names.push("it".to_string());
            }
            let dst = b.alloc_reg();
            b.push(Inst::AstLambda {
                dst,
                params: param_names,
                body_ast: body.clone(),
                captures,
                captured_names,
                absorb_return: false,
                body_func: Some(body_func),
            });
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
                let op = match op {
                    klio_ast::PostfixOp::Inc => UnOp::Inc,
                    klio_ast::PostfixOp::Dec => UnOp::Dec,
                    _ => unreachable!(),
                };
                // For Index targets, evaluate receiver + keys ONCE,
                // read via get(...), inc/dec, write via set(...),
                // returning the snapshot. Otherwise fall through to
                // the generic "evaluate inner once, write back via
                // Path / Member" path.
                if let Expr::Index { receiver, args: idx_args, .. } = inner.as_ref() {
                    let recv = lower_receiver(b, receiver);
                    let n_keys = idx_args.len();
                    let key_start = b.alloc_reg();
                    let mut key_slots: Vec<Reg> = vec![key_start];
                    for _ in 1..n_keys {
                        key_slots.push(b.alloc_reg());
                    }
                    // Reserve val slot for the write-back contig.
                    let val_slot = b.alloc_reg();
                    for (slot, arg) in key_slots.iter().zip(idx_args.iter()) {
                        let r = lower_expr(b, arg);
                        b.push(Inst::Move { dst: *slot, src: r });
                    }
                    // Read current: get(key…) into `old`.
                    let old = b.alloc_reg();
                    let get_nm = b.module.intern_const(Const::String("get".into()));
                    b.push(Inst::CallMember {
                        dst: old,
                        receiver: recv,
                        name: get_nm,
                        args: key_start,
                        n_args: n_keys as u8,
                        arg_names: Vec::new(),
                    });
                    // new = unop(old)
                    let new = b.alloc_reg();
                    b.push(Inst::UnOp { dst: new, op, operand: old });
                    b.push(Inst::Move { dst: val_slot, src: new });
                    // Write back: set(key…, new). Reuses the SAME
                    // key slots so idx() isn't called twice.
                    let set_dst = b.alloc_reg();
                    let set_nm = b.module.intern_const(Const::String("set".into()));
                    b.push(Inst::CallMember {
                        dst: set_dst,
                        receiver: recv,
                        name: set_nm,
                        args: key_start,
                        n_args: (n_keys as u8) + 1,
                        arg_names: Vec::new(),
                    });
                    return old;
                }
                let s = lower_expr(b, inner);
                // Snapshot the old value into a fresh reg before
                // mutating the storage slot — `c++` returns the
                // pre-increment value, and for a `var` local `s` is
                // the home reg, so a later Move into home would
                // overwrite the value we want to return.
                let old = b.alloc_reg();
                b.push(Inst::Move { dst: old, src: s });
                let new = b.alloc_reg();
                b.push(Inst::UnOp { dst: new, op, operand: old });
                match inner.as_ref() {
                    Expr::Path { segments, .. } if segments.len() == 1 => {
                        if b.is_boxed(&segments[0].name) {
                            let cell = boxed_cell_reg(b, &segments[0].name);
                            b.push(Inst::CellSet { cell, value: new });
                        } else if let Some(home) = b.mutable_home(&segments[0].name) {
                            b.push(Inst::Move { dst: home, src: new });
                        } else if b.has_own_member(&segments[0].name)
                            && b.resolve("this").is_some()
                        {
                            // Method-body `field++` write — route
                            // through SetField on this so the
                            // mutation reaches the instance.
                            let this_reg = b.resolve("this").unwrap();
                            let field = b.module.intern_const(Const::String(segments[0].name.clone()));
                            b.push(Inst::SetField { receiver: this_reg, field, value: new });
                        } else if b.knows_outer(&segments[0].name) {
                            // Lambda-body postfix inc/dec on a
                            // captured outer var: rebind locally
                            // and emit StoreGlobal so the caller's
                            // WritebackCaptures Inst syncs the
                            // mutation back to the outer reg.
                            let _ = b.record_capture(&segments[0].name);
                            let n = b
                                .module
                                .intern_const(Const::String(segments[0].name.clone()));
                            b.push(Inst::StoreGlobal { name: n, value: new });
                            b.rebind(&segments[0].name, new);
                        } else {
                            b.rebind(&segments[0].name, new);
                        }
                    }
                    Expr::Member { receiver, name, safe: false, .. } => {
                        // `obj.field++` — write the incremented value
                        // back through the same SetField path the
                        // host's set_field uses for class setters.
                        let recv = lower_receiver(b, receiver);
                        let field = b.module.intern_const(Const::String(name.name.clone()));
                        b.push(Inst::SetField { receiver: recv, field, value: new });
                    }
                    Expr::Index { receiver, args: idx_args, .. } => {
                        // `xs[i]++` — read above, write back via .set(i, new).
                        let recv = lower_receiver(b, receiver);
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
                        b.push(Inst::Move { dst: val_slot, src: new });
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
                    _ => {}
                }
                old
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
            Expr::For { vars, iter, body, .. } => {
                lower_for_labeled(b, vars, iter, body, Some(label.name.clone()))
            }
            Expr::DoWhile { body, cond, .. } => {
                let body_blk = b.alloc_block();
                let exit = b.alloc_block();
                b.terminate(Terminator::Goto(body_blk));
                b.switch_to(body_blk);
                b.push_loop(Some(label.name.clone()), body_blk, exit);
                if let Some(body) = body {
                    let _ = lower_expr(b, body);
                }
                b.pop_loop();
                let c = lower_expr(b, cond);
                b.terminate(Terminator::Branch { cond: c, t: body_blk, f: exit });
                b.switch_to(exit);
                b.emit_const(Const::Unit)
            }
            _ => lower_expr(b, inner),
        },
        Expr::PropertyRef { name, .. } => {
            // `::greet` — if the name is a registered top-level
            // function, load the function value so the result is
            // callable. Otherwise emit a `KProperty`-shaped
            // PropertyRef metadata value.
            let dst = b.alloc_reg();
            let nm = b.module.intern_const(Const::String(name.name.clone()));
            if b.module.func_id(&name.name).is_some()
                || b.module.class_id(&name.name).is_some()
            {
                b.push(Inst::LoadGlobal { dst, name: nm });
            } else {
                b.push(Inst::PropertyRef { dst, name: nm });
            }
            dst
        }
        Expr::MemberRef { receiver, name, .. } => {
            // `Outer::Nested` where `Nested` is a (nested) class is a
            // constructor reference, not a bound member ref — load
            // the class value so it is callable, exactly like the
            // no-receiver `::Ctor` form. The receiver here is just a
            // type qualifier with no runtime value.
            if name.name != "class"
                && matches!(receiver.as_ref(), Expr::Path { .. })
                && b.module.class_id(&name.name).is_some()
            {
                let dst = b.alloc_reg();
                let nm = b.module.intern_const(Const::String(name.name.clone()));
                b.push(Inst::LoadGlobal { dst, name: nm });
                return dst;
            }
            let recv = lower_receiver(b, receiver);
            let dst = b.alloc_reg();
            let nm = b.module.intern_const(Const::String(name.name.clone()));
            b.push(Inst::MemberRef { dst, receiver: recv, name: nm });
            dst
        }
        Expr::ObjectExpr { .. } => {
            // Anonymous-object expressions (`object { … }` /
            // `object : Foo { … }`) carry rich AST shape (a body of
            // declarations, supertypes, init blocks) that the IR
            // doesn't model structurally yet. Emit a dedicated
            // `BuildObject` Inst whose host synthesises a fresh
            // `ClassDef` with the snapshotted env on each call.
            let outer_names: std::collections::HashSet<String> = b.visible_names();
            let captured_names: Vec<String> = outer_names.iter().cloned().collect();
            let captures: Vec<Reg> = captured_names
                .iter()
                .map(|n| resolve_capture(b, n))
                .collect();
            let dst = b.alloc_reg();
            b.push(Inst::BuildObject {
                dst,
                ast: Box::new(expr.clone()),
                captured_names,
                captures,
            });
            dst
        }
        Expr::AnonFun { params, body, .. } => {
            // Lower an anonymous function the same way as a lambda:
            // synthesise an AstLambda with the body packed into a
            // `Block`. `fun (x): T = expr` carries `FunctionBody::Expr`
            // — wrap that as a single-statement block whose last
            // expression is the return value.
            let body_block: klio_ast::Block = match body.as_deref() {
                Some(klio_ast::FunctionBody::Block(blk)) => blk.clone(),
                Some(klio_ast::FunctionBody::Expr(e)) => klio_ast::Block {
                    stmts: vec![klio_ast::Stmt::Expr(e.clone())],
                    span: expr_span(expr),
                },
                None => klio_ast::Block { stmts: Vec::new(), span: expr_span(expr) },
            };
            let param_names: Vec<String> =
                params.iter().map(|p| p.name.name.clone()).collect();
            let param_idents: Vec<klio_ast::Ident> =
                params.iter().map(|p| p.name.clone()).collect();
            let outer_names: std::collections::HashSet<String> = b.visible_names();
            let outer_boxed = b.boxed_vars_snapshot();
            let (body_func, captured_names) = lower_lambda_body_capturing_kind(
                b.module, &param_idents, &body_block, outer_names, false, &outer_boxed,
                None,
            );
            let captures: Vec<Reg> = captured_names
                .iter()
                .map(|n| resolve_capture(b, n))
                .collect();
            let dst = b.alloc_reg();
            b.push(Inst::AstLambda {
                dst,
                params: param_names,
                body_ast: body_block,
                captures,
                captured_names,
                absorb_return: true,
                body_func: Some(body_func),
            });
            dst
        }
        Expr::This { qualifier, .. } => {
            // `this` bare resolves to the implicit first param
            // bound by `lower_method` / extension lowering. Inside
            // a lambda body that hasn't bound `this` locally, fall
            // back to the captured `this` slot — populated by the
            // dispatcher when the lambda is called with a
            // this-binding (scope fns like `apply` / `with`).
            // Note: when `this` resolves through a capture (a scope-fn
            // / receiver lambda body), we deliberately do NOT bind it
            // as a local. Binding poisoned later bare-member reads:
            // they would resolve `this` to the captured lambda
            // receiver and emit a raw GetField with no
            // enclosing-receiver fallback, so `this@Outer` followed by
            // a bare enclosing member failed. Leaving `this` unbound
            // keeps subsequent bare names on the this-or-global probe,
            // which tries the lambda receiver, then the enclosing
            // `this@Outer`, then globals — Kotlin's nested-receiver
            // order. Re-emitting LoadCapture per `this` is cheap.
            let this_reg = b.resolve("this").or_else(|| {
                let idx = b.record_capture("this");
                let dst = b.alloc_reg();
                b.push(Inst::LoadCapture { dst, idx });
                Some(dst)
            });
            if let Some(this_reg) = this_reg {
                if let Some(q) = qualifier {
                    let nm = b.module.intern_const(Const::String(q.name.clone()));
                    let dst = b.alloc_reg();
                    b.push(Inst::QualifiedThis {
                        dst,
                        receiver: this_reg,
                        qualifier: nm,
                    });
                    dst
                } else {
                    this_reg
                }
            } else {
                b.push(Inst::Trace { span: expr_span(expr) });
                b.emit_const(Const::Unit)
            }
        }
        Expr::Super { .. } => {
            // `super` bare or `super.member` reads the same
            // instance value as `this`; the method-dispatch site
            // would normally walk to the parent class's body.
            // The IR has no native super-dispatch yet, so we
            // return `this` and let the host's call_member fall
            // back to the tree walker's `super.foo()` machinery
            // via `dispatch_member_via_ast` when a method-on-
            // super resolves to a different parent override.
            if let Some(this_reg) = b.resolve("this") {
                this_reg
            } else {
                b.push(Inst::Trace { span: expr_span(expr) });
                b.emit_const(Const::Unit)
            }
        }
        _ => {
            // Remaining expression forms not yet lowered. Emit a
            // placeholder Trace so the gap is visible in printouts
            // and tests can assert which forms still need work.
            b.push(Inst::Trace { span: expr_span(expr) });
            b.emit_const(Const::Unit)
        }
    }
}

/// Materialise a register holding the value captured by a child
/// lambda. If `name` resolves locally we use its reg directly. Else
/// when the enclosing scope knows it as an outer capture, record it
/// on the current builder + emit a `LoadCapture` so the value flows
/// through the chain (the outer scope's lambda already captured it
/// or will need to, via the same mechanism, when its own enclosing
/// lambda lowers).


/// Try to lower a `when (subject)` as a Switch terminator. Returns
/// the (case-arms, optional default body block, per-branch body
/// blocks) tuple when every non-else branch carries a single
/// literal pattern. Returns None for the general Branch-chain
/// fallback. Each branch index in the input maps 1:1 to the


pub(super) fn lower_block(b: &mut FuncBuilder<'_>, block: &AstBlock) -> Reg {
    b.push_scope();
    // Hoist only the local fn names that an *earlier-declared* local
    // fn in this same block references — that is the strict subset of
    // names that require a shared cell so mutually-recursive sibling
    // fns can resolve a forward reference. Hoisting more names changes
    // the binding of unrelated locals from a direct value to a boxed
    // cell, which then interacts with member-/extension-dispatch in
    // ways that regress unrelated programs (a local-fn-by-value direct
    // bind is what code without forward references is built on).
    let local_fn_decls: Vec<(usize, &klio_ast::Function)> = block
        .stmts
        .iter()
        .enumerate()
        .filter_map(|(i, s)| {
            if let Stmt::Decl(klio_ast::Decl::Function(f)) = s {
                Some((i, f))
            } else {
                None
            }
        })
        .collect();
    for (k_idx, _) in local_fn_decls.iter().enumerate() {
        let (k_pos, k_fn) = local_fn_decls[k_idx];
        let mut needs_hoist = false;
        for (i_pos, i_fn) in &local_fn_decls {
            if *i_pos >= k_pos {
                break;
            }
            // Only an EARLIER local fn referencing `k_fn` justifies a
            // pre-hoist; later references already see `k_fn` bound.
            if let Some(body) = i_fn.body.as_ref() {
                let mut refs = std::collections::HashSet::new();
                match body {
                    klio_ast::FunctionBody::Block(blk) => {
                        for s in &blk.stmts {
                            collect_path_idents_stmt(s, &mut refs);
                        }
                    }
                    klio_ast::FunctionBody::Expr(e) => {
                        collect_path_idents(e, &mut refs);
                    }
                }
                if refs.contains(&k_fn.name.name) {
                    needs_hoist = true;
                    break;
                }
            }
        }
        if needs_hoist && b.mutable_home(&k_fn.name.name).is_none() {
            let null_v = b.emit_const(Const::Null);
            let home = b.alloc_reg();
            b.push(Inst::MakeCell { dst: home, src: null_v });
            b.set_mutable_home(&k_fn.name.name, home);
            b.mark_mutable(&k_fn.name.name);
            b.mark_boxed(&k_fn.name.name);
            b.bind(k_fn.name.name.clone(), home);
        }
    }
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
                b.push(Inst::PropertyRef { dst: prop_ref, name: pname });
                let args_start = b.alloc_reg();
                b.push(Inst::Move { dst: args_start, src: null_arg });
                let _slot2 = b.alloc_reg();
                b.push(Inst::Move { dst: Reg(args_start.0 + 1), src: prop_ref });
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
                        let widened = p
                            .ty
                            .as_ref()
                            .and_then(|ty| widen_numeric_literal(e, ty));
                        lower_expr(b, widened.as_ref().unwrap_or(e))
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
            if let Some(ty) = &p.ty {
                if ty.name.name == "Any" {
                    b.mark_any_typed(&p.name.name);
                }
            }
            if b.is_boxed(&p.name.name) {
                // Captured `var` — box into a shared cell so writes
                // from a nested closure / coroutine are visible
                // here (Kotlin `Ref` semantics).
                let home = b.alloc_reg();
                b.push(Inst::MakeCell { dst: home, src: init });
                b.set_mutable_home(&p.name.name, home);
                b.mark_mutable(&p.name.name);
                b.bind(p.name.name.clone(), home);
            } else if p.mutable || p.init.is_none() {
                let home = b.alloc_reg();
                b.push(Inst::Move { dst: home, src: init });
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
        Stmt::Decl(klio_ast::Decl::Function(f)) => {
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
                // A local function that calls itself is desugared like
                // `var name = null; name = { … name(…) … }`: a shared
                // cell is created first so the body can capture it and
                // the closure stores itself into it once built. This
                // is the same boxed-self-reference path a recursive
                // `lateinit var f = { … f(…) … }` already uses.
                let mut self_refs = std::collections::HashSet::new();
                for s in &body.stmts {
                    collect_path_idents_stmt(s, &mut self_refs);
                }
                // Pre-hoisted by `lower_block`: every local fn declared
                // at the block level already has a shared cell so
                // siblings can capture each other. Reuse it. Falls back
                // to the per-fn self-cell path for any local fn lowered
                // outside `lower_block`'s pre-pass.
                let self_cell: Option<Reg> = if let Some(home) =
                    b.mutable_home(&f.name.name)
                {
                    Some(home)
                } else if self_refs.contains(&f.name.name) {
                    let null_v = b.emit_const(Const::Null);
                    let home = b.alloc_reg();
                    b.push(Inst::MakeCell { dst: home, src: null_v });
                    b.set_mutable_home(&f.name.name, home);
                    b.mark_mutable(&f.name.name);
                    b.mark_boxed(&f.name.name);
                    b.bind(f.name.name.clone(), home);
                    Some(home)
                } else {
                    None
                };
                let outer_names: std::collections::HashSet<String> = b.visible_names();
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
                        klio_ast::Ident { name: "this".to_string(), span: dummy_span },
                    );
                }
                let tailrec_self =
                    if f.is_tailrec { Some(f.name.name.as_str()) } else { None };
                let (body_func, captured_names) = lower_lambda_body_capturing_kind_with(
                    b.module,
                    &param_idents,
                    &body,
                    outer_names,
                    true,
                    &outer_boxed,
                    tailrec_self,
                    true,
                );
                let captures: Vec<Reg> = captured_names
                    .iter()
                    .map(|n| resolve_capture(b, n))
                    .collect();
                let mut param_names: Vec<String> =
                    f.params.iter().map(|p| p.name.name.clone()).collect();
                if is_ext {
                    param_names.insert(0, "this".to_string());
                }
                // Per-param defaults: lower each default expression as
                // a thunk binding the lowered param prefix (so `b =
                // a + 1` can read an earlier param) and register it
                // under the body FuncId. The Vm pads missing trailing
                // args from these the same way it does for top-level
                // functions.
                if f.params.iter().any(|p| p.default.is_some()) {
                    let offset = usize::from(is_ext);
                    let name_refs: Vec<&str> =
                        param_names.iter().map(String::as_str).collect();
                    let mut slots: Vec<Option<crate::FuncId>> =
                        Vec::with_capacity(param_names.len());
                    for _ in 0..offset {
                        slots.push(None);
                    }
                    for (idx, p) in f.params.iter().enumerate() {
                        if let Some(default_expr) = &p.default {
                            let bind_upto = (offset + idx).min(name_refs.len());
                            let widened =
                                widen_numeric_literal(default_expr, &p.ty);
                            let fid = lower_expr_as_param_thunk(
                                b.module,
                                &name_refs[..bind_upto],
                                widened.as_ref().unwrap_or(default_expr),
                                &format!(
                                    "__default_local_{}_{}",
                                    f.name.name, p.name.name
                                ),
                            );
                            slots.push(Some(fid));
                        } else {
                            slots.push(None);
                        }
                    }
                    b.module
                        .registry
                        .local_fn_defaults
                        .insert(body_func, slots);
                }
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
                    b.push(Inst::CellSet { cell: home, value: dst });
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
        Stmt::Assign { target, op, value, .. }
            if matches!(target, Expr::Index { receiver, .. } if matches!(receiver.as_ref(), Expr::Member { safe: true, .. })) =>
        {
            // `obj?.items[i] = v` — null-guard the outer Index
            // assignment when the receiver chain is a safe-Member.
            let Expr::Index { receiver, args: idx_args, span } = target else { unreachable!() };
            let Expr::Member { receiver: outer, name: mname, span: mspan, .. } = receiver.as_ref() else { unreachable!() };
            let outer_r = lower_expr(b, outer);
            let null_r = b.emit_const(Const::Null);
            let is_null = b.alloc_reg();
            b.push(Inst::BinOp { dst: is_null, op: BinOp::Eq, lhs: outer_r, rhs: null_r });
            let skip = b.alloc_block();
            let do_set = b.alloc_block();
            let join = b.alloc_block();
            b.terminate(Terminator::Branch { cond: is_null, t: skip, f: do_set });
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
                op: *op,
                value: value.clone(),
                span: *span,
            };
            lower_stmt(b, &synth);
            b.terminate(Terminator::Goto(join));
            b.switch_to(skip);
            b.terminate(Terminator::Goto(join));
            b.switch_to(join);
            return None;
        }
        Stmt::Assign { target, op, value, .. }
            if matches!(target, Expr::Member { safe: true, .. }) =>
        {
            // `obj?.field = v` (or compound `?.field += v`):
            //   if obj is null → skip the assignment entirely.
            //   otherwise → fall through to the regular non-safe
            //              assign path with the safe flag cleared.
            let Expr::Member { receiver, name, span, .. } = target else { unreachable!() };
            let recv_r = lower_expr(b, receiver);
            let null_r = b.emit_const(Const::Null);
            let is_null = b.alloc_reg();
            b.push(Inst::BinOp { dst: is_null, op: BinOp::Eq, lhs: recv_r, rhs: null_r });
            let skip = b.alloc_block();
            let do_set = b.alloc_block();
            let join = b.alloc_block();
            b.terminate(Terminator::Branch { cond: is_null, t: skip, f: do_set });
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
                op: *op,
                value: value.clone(),
                span: *span,
            };
            lower_stmt(b, &synth);
            b.terminate(Terminator::Goto(join));
            b.switch_to(skip);
            b.terminate(Terminator::Goto(join));
            b.switch_to(join);
            return None;
        }
        Stmt::Assign { target, op, value, .. } => {
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
                b.push(Inst::Move { dst: args_start, src: v });
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
                    if b.is_boxed(&segments[0].name) {
                        let cell = boxed_cell_reg(b, &segments[0].name);
                        b.push(Inst::CellSet { cell, value: combined });
                    } else if let Some(home) = b.mutable_home(&segments[0].name) {
                        b.push(Inst::Move { dst: home, src: combined });
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
                        b.push(Inst::StoreGlobal { name: n, value: combined });
                        b.rebind(&segments[0].name, combined);
                    } else if b.resolve(&segments[0].name).is_some() {
                        b.rebind(&segments[0].name, combined);
                    } else if b.has_own_member(&segments[0].name)
                        && b.resolve("this").is_some()
                    {
                        // Method-body `this.field` write — route
                        // SetField on the receiver so the bare-
                        // name assign reaches the instance, not
                        // a synthetic global.
                        let this_reg = b.resolve("this").unwrap();
                        let field = b.module.intern_const(Const::String(segments[0].name.clone()));
                        b.push(Inst::SetField { receiver: this_reg, field, value: combined });
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
                        let n = b.module.intern_const(Const::String(segments[0].name.clone()));
                        b.push(Inst::StoreGlobal { name: n, value: combined });
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
                        let name_c = b.module.intern_const(Const::String(
                            segments[0].name.clone(),
                        ));
                        b.push(Inst::StoreToThisOrGlobal {
                            this_idx,
                            name: name_c,
                            value: combined,
                        });
                    } else {
                        // Top-level binding: route through StoreGlobal so
                        // the tree-walker setter / delegate fires.
                        let n = b.module.intern_const(Const::String(segments[0].name.clone()));
                        b.push(Inst::StoreGlobal { name: n, value: combined });
                    }
                }
                Expr::Member { receiver, name, .. } => {
                    let recv = lower_receiver(b, receiver);
                    let field = b.module.intern_const(Const::String(name.name.clone()));
                    b.push(Inst::SetField { receiver: recv, field, value: combined });
                }
                Expr::Index { receiver, args: idx_args, .. } => {
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
                    b.push(Inst::Move { dst: val_slot, src: combined });
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
                    b.push(Inst::Trace { span: expr_span(target) });
                }
            }
            None
        }
        Stmt::Decl(klio_ast::Decl::Class(c)) => {
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
        Stmt::DestructuringDecl { names, init, .. } => {
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
        Stmt::Decl(_) => None,
    }
}

fn ast_binop(op: AstBinOp) -> BinOp {
    match op {
        AstBinOp::Add => BinOp::Add,
        AstBinOp::Sub => BinOp::Sub,
        AstBinOp::Mul => BinOp::Mul,
        AstBinOp::Div => BinOp::Div,
        AstBinOp::Rem => BinOp::Mod,
        AstBinOp::Eq => BinOp::Eq,
        AstBinOp::Neq => BinOp::NotEq,
        AstBinOp::IdentEq => BinOp::IdentEq,
        AstBinOp::IdentNeq => BinOp::IdentNeq,
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
