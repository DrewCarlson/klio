//! Pure AST-walking helpers used by lowering. Kept separate from
//! the main lowering module because they only consume the AST —
//! they touch no `FuncBuilder` state and have no IR-side dependencies.

use klio_ast::{Expr, Stmt};

/// `expr as Any` (or transitively wrapped) — used by the
/// boxed-equality routing.
pub(super) fn is_boxed_to_any_form(e: &Expr) -> bool {
    fn is_any_name(name: &str) -> bool {
        matches!(name, "Any")
    }
    match e {
        Expr::As { ty, .. } => is_any_name(&ty.name.name),
        Expr::Path { segments, .. } => {
            // A var binding annotated `: Any` — the IR lowering can't
            // see types here, so be conservative.
            let _ = segments;
            false
        }
        _ => false,
    }
}

/// Recursively collect every single-segment `Path` identifier that
/// appears anywhere in an expression. Used to find which names a
/// nested lambda references.
pub(super) fn collect_path_idents(e: &Expr, out: &mut std::collections::HashSet<String>) {
    match e {
        Expr::Path { segments, .. } if segments.len() == 1 => {
            out.insert(segments[0].name.clone());
        }
        Expr::Member { receiver, .. } => collect_path_idents(receiver, out),
        Expr::MemberRef { receiver, .. } => collect_path_idents(receiver, out),
        Expr::Call { callee, args, .. } => {
            collect_path_idents(callee, out);
            for a in args {
                collect_path_idents(a, out);
            }
        }
        Expr::Index { receiver, args, .. } => {
            collect_path_idents(receiver, out);
            for a in args {
                collect_path_idents(a, out);
            }
        }
        Expr::Binary { lhs, rhs, .. } => {
            collect_path_idents(lhs, out);
            collect_path_idents(rhs, out);
        }
        Expr::Unary { expr, .. }
        | Expr::Postfix { expr, .. }
        | Expr::Spread { expr, .. }
        | Expr::Throw { value: expr, .. }
        | Expr::Labeled { expr, .. }
        | Expr::As { expr, .. }
        | Expr::IsCheck { expr, .. } => collect_path_idents(expr, out),
        Expr::If { cond, then_branch, else_branch, .. } => {
            collect_path_idents(cond, out);
            collect_path_idents(then_branch, out);
            if let Some(e) = else_branch {
                collect_path_idents(e, out);
            }
        }
        Expr::While { cond, body, .. } => {
            collect_path_idents(cond, out);
            collect_path_idents(body, out);
        }
        Expr::DoWhile { body, cond, .. } => {
            if let Some(b) = body {
                collect_path_idents(b, out);
            }
            collect_path_idents(cond, out);
        }
        Expr::For { iter, body, .. } => {
            collect_path_idents(iter, out);
            collect_path_idents(body, out);
        }
        Expr::Return { value: Some(v), .. } => collect_path_idents(v, out),
        Expr::Block(b) => {
            for s in &b.stmts {
                collect_path_idents_stmt(s, out);
            }
        }
        Expr::Lambda { body, .. } => {
            for s in &body.stmts {
                collect_path_idents_stmt(s, out);
            }
        }
        Expr::AnonFun { body: Some(fb), .. } => match fb.as_ref() {
            klio_ast::FunctionBody::Block(b) => {
                for s in &b.stmts {
                    collect_path_idents_stmt(s, out);
                }
            }
            klio_ast::FunctionBody::Expr(e) => collect_path_idents(e, out),
        },
        Expr::When { subject, branches, .. } => {
            if let Some(s) = subject {
                collect_path_idents(s, out);
            }
            for br in branches {
                collect_path_idents(&br.body, out);
            }
        }
        Expr::Try { body, catches, finally, .. } => {
            for s in &body.stmts {
                collect_path_idents_stmt(s, out);
            }
            for c in catches {
                for s in &c.body.stmts {
                    collect_path_idents_stmt(s, out);
                }
            }
            if let Some(fb) = finally {
                for s in &fb.stmts {
                    collect_path_idents_stmt(s, out);
                }
            }
        }
        Expr::StringTemplate { parts, .. } => {
            for p in parts {
                match p {
                    klio_ast::StringPart::Interp(e) => collect_path_idents(e, out),
                    klio_ast::StringPart::ShortInterp(id) => {
                        out.insert(id.name.clone());
                    }
                    klio_ast::StringPart::Text(_) => {}
                }
            }
        }
        _ => {}
    }
}

pub(super) fn collect_path_idents_stmt(s: &Stmt, out: &mut std::collections::HashSet<String>) {
    match s {
        Stmt::Expr(e) => collect_path_idents(e, out),
        Stmt::Assign { target, value, .. } => {
            collect_path_idents(target, out);
            collect_path_idents(value, out);
        }
        Stmt::DestructuringDecl { init, .. } => collect_path_idents(init, out),
        Stmt::Decl(klio_ast::Decl::Property(p)) => {
            if let Some(e) = &p.init {
                collect_path_idents(e, out);
            }
        }
        _ => {}
    }
}

/// Names referenced anywhere inside a nested `Lambda` / `AnonFun`
/// within these statements (recursing into nested lambdas too).
pub(super) fn names_referenced_in_lambdas(
    stmts: &[Stmt],
    out: &mut std::collections::HashSet<String>,
) {
    fn scan_expr(e: &Expr, out: &mut std::collections::HashSet<String>) {
        match e {
            Expr::Lambda { body, .. } => {
                for s in &body.stmts {
                    collect_path_idents_stmt(s, out);
                }
            }
            Expr::AnonFun { body: Some(fb), .. } => match fb.as_ref() {
                klio_ast::FunctionBody::Block(b) => {
                    for s in &b.stmts {
                        collect_path_idents_stmt(s, out);
                    }
                }
                klio_ast::FunctionBody::Expr(e) => collect_path_idents(e, out),
            },
            Expr::Member { receiver, .. }
            | Expr::Unary { expr: receiver, .. }
            | Expr::Postfix { expr: receiver, .. }
            | Expr::Spread { expr: receiver, .. }
            | Expr::Throw { value: receiver, .. }
            | Expr::Labeled { expr: receiver, .. }
            | Expr::As { expr: receiver, .. }
            | Expr::IsCheck { expr: receiver, .. }
            | Expr::MemberRef { receiver, .. } => scan_expr(receiver, out),
            Expr::Call { callee, args, .. } => {
                scan_expr(callee, out);
                for a in args {
                    scan_expr(a, out);
                }
            }
            Expr::Index { receiver, args, .. } => {
                scan_expr(receiver, out);
                for a in args {
                    scan_expr(a, out);
                }
            }
            Expr::Binary { lhs, rhs, .. } => {
                scan_expr(lhs, out);
                scan_expr(rhs, out);
            }
            Expr::If { cond, then_branch, else_branch, .. } => {
                scan_expr(cond, out);
                scan_expr(then_branch, out);
                if let Some(e) = else_branch {
                    scan_expr(e, out);
                }
            }
            Expr::While { cond, body, .. } => {
                scan_expr(cond, out);
                scan_expr(body, out);
            }
            Expr::DoWhile { body, cond, .. } => {
                if let Some(b) = body {
                    scan_expr(b, out);
                }
                scan_expr(cond, out);
            }
            Expr::For { iter, body, .. } => {
                scan_expr(iter, out);
                scan_expr(body, out);
            }
            Expr::Return { value: Some(v), .. } => scan_expr(v, out),
            Expr::Block(b) => names_referenced_in_lambdas(&b.stmts, out),
            Expr::When { subject, branches, .. } => {
                if let Some(s) = subject {
                    scan_expr(s, out);
                }
                for br in branches {
                    scan_expr(&br.body, out);
                }
            }
            Expr::Try { body, catches, finally, .. } => {
                names_referenced_in_lambdas(&body.stmts, out);
                for c in catches {
                    names_referenced_in_lambdas(&c.body.stmts, out);
                }
                if let Some(fb) = finally {
                    names_referenced_in_lambdas(&fb.stmts, out);
                }
            }
            Expr::StringTemplate { parts, .. } => {
                for p in parts {
                    match p {
                        klio_ast::StringPart::Interp(e) => scan_expr(e, out),
                        klio_ast::StringPart::ShortInterp(id) => {
                            out.insert(id.name.clone());
                        }
                        klio_ast::StringPart::Text(_) => {}
                    }
                }
            }
            _ => {}
        }
    }
    for s in stmts {
        match s {
            Stmt::Expr(e) => scan_expr(e, out),
            Stmt::Assign { target, value, .. } => {
                scan_expr(target, out);
                scan_expr(value, out);
            }
            Stmt::DestructuringDecl { init, .. } => scan_expr(init, out),
            Stmt::Decl(klio_ast::Decl::Property(p)) => {
                if let Some(e) = &p.init {
                    scan_expr(e, out);
                }
            }
            _ => {}
        }
    }
}

/// `var` names declared directly in these statements (not inside a
/// nested lambda — those open their own frame). Also includes a
/// deferred-init plain `val` (no initializer / delegate / accessor),
/// because a later write from a nested lambda needs the same
/// `Ref`-boxing as a captured `var` to be visible at the decl site.
pub(super) fn collect_var_decls(stmts: &[Stmt], out: &mut std::collections::HashSet<String>) {
    fn scan_expr(e: &Expr, out: &mut std::collections::HashSet<String>) {
        match e {
            Expr::Block(b) => collect_var_decls(&b.stmts, out),
            Expr::If { then_branch, else_branch, .. } => {
                scan_expr(then_branch, out);
                if let Some(e) = else_branch {
                    scan_expr(e, out);
                }
            }
            Expr::While { body, .. } => scan_expr(body, out),
            Expr::DoWhile { body: Some(b), .. } => scan_expr(b, out),
            Expr::For { body, .. } => scan_expr(body, out),
            Expr::When { branches, .. } => {
                for br in branches {
                    scan_expr(&br.body, out);
                }
            }
            Expr::Labeled { expr, .. } => scan_expr(expr, out),
            Expr::Try { body, catches, finally, .. } => {
                collect_var_decls(&body.stmts, out);
                for c in catches {
                    collect_var_decls(&c.body.stmts, out);
                }
                if let Some(fb) = finally {
                    collect_var_decls(&fb.stmts, out);
                }
            }
            _ => {}
        }
    }
    for s in stmts {
        match s {
            Stmt::Decl(klio_ast::Decl::Property(p))
                if p.mutable
                    || (p.init.is_none()
                        && p.delegate.is_none()
                        && p.getter.is_none()
                        && p.setter.is_none()) =>
            {
                out.insert(p.name.name.clone());
            }
            Stmt::DestructuringDecl { mutable: true, names, .. } => {
                for n in names {
                    out.insert(n.name.clone());
                }
            }
            Stmt::Expr(e) => scan_expr(e, out),
            _ => {}
        }
    }
}

/// `var`s declared in this frame and captured by a nested lambda
/// need to be boxed into a shared `Value::Cell` (Kotlin `Ref`
/// semantics) so a write from a coroutine / closure is visible at
/// the decl site.
pub(super) fn compute_boxed_vars(stmts: &[Stmt]) -> std::collections::HashSet<String> {
    let mut decls = std::collections::HashSet::new();
    collect_var_decls(stmts, &mut decls);
    if decls.is_empty() {
        return decls;
    }
    let mut refs = std::collections::HashSet::new();
    names_referenced_in_lambdas(stmts, &mut refs);
    decls.retain(|n| refs.contains(n));
    decls
}

/// Flatten a `Member{receiver: Member{...,Path}}` chain into a
/// dotted FQN like `kotlin.math.PI`. Returns `None` when the chain
/// is not purely identifier segments (e.g. it has a Call, Index, or
/// arbitrary expression).
pub(super) fn collect_dotted_fqn(expr: &Expr) -> Option<String> {
    let mut parts: Vec<String> = Vec::new();
    let mut cur = expr;
    loop {
        match cur {
            Expr::Member { receiver, name, .. } => {
                parts.push(name.name.clone());
                cur = receiver;
            }
            Expr::Path { segments, .. } => {
                for s in segments.iter().rev() {
                    parts.push(s.name.clone());
                }
                break;
            }
            _ => return None,
        }
    }
    parts.reverse();
    Some(parts.join("."))
}
