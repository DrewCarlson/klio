use super::{FuncBuilder, Expr, Reg, Inst, lower_expr, Const, AstBinOp, BinOp};

/// Bind function parameters into the current scope. Each param is
/// loaded into a fresh register via `Inst::LoadParam` so subsequent
/// `Path { name }` reads route through the same register.
/// Materialise a contiguous run of argument registers for a Call /
/// `CallMember` / `CallValue` / `NewInstance` instruction.
///
/// The lowering pass otherwise produces non-contiguous register
/// numbering when sub-expressions allocate intermediate temporaries.
/// We reserve `args.len()` contiguous registers up front (so the
/// run [`args_start`, `args_start` + `n_args`) is dense), lower each arg
/// into its own scratch reg, then `Move` the scratch into the
/// matching arg slot. Returns `(args_start, n_args)`.
/// Treat a path segment as a package-root identifier when it starts
/// with a lowercase letter — Kotlin convention reserves lowercase
/// roots for packages (`kotlin`, `kotlinx`, `java`, …) and capital
/// initials for class / object names. Limiting FQN-flattening to
/// lowercase heads keeps `Status.Active` / `Foo.Companion` member
/// access routed through `GetField` on the actual class value.
/// True when `arg` is a lambda whose body assigns to a name that
/// the IR's current scope shadows or knows as an outer capture.
/// True when `e` is `expr as Any` (or transitively wraps one through
/// trivial parens / binding) — mirrors tree walker's
/// `is_boxed_to_any_form` heuristic.
pub(crate) fn is_any_typed_path(b: &FuncBuilder<'_>, e: &Expr) -> bool {
    matches!(e, Expr::Path { segments, .. } if segments.len() == 1 && b.is_any_typed(&segments[0].name))
}

// `is_boxed_to_any_form` lives in `ast_scan.rs`.

/// Collect every outer-scope variable name a lambda's body
/// directly mutates (assignment / `++` / `--`). Returns an empty
/// vec for non-lambda args. Used by the closure-mutation
/// writeback path to know which captured names to sync back to
/// the caller's regs after a HOF call returns.
pub(crate) fn lambda_mutated_outer_vars(b: &FuncBuilder<'_>, arg: &Expr) -> Vec<String> {
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
                if let Expr::Path { segments, .. } = target
                    && segments.len() == 1 && visible.contains(&segments[0].name) {
                        out.insert(segments[0].name.clone());
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
        if let Expr::Path { segments, .. } = e
            && segments.len() == 1 && visible.contains(&segments[0].name) {
                out.insert(segments[0].name.clone());
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

pub(crate) fn lambda_writes_outer_var(b: &FuncBuilder<'_>, arg: &Expr) -> bool {
    let body = match arg {
        Expr::Lambda { body, .. } => body,
        _ => return false,
    };
    let visible = b.visible_names();
    fn walk(stmt: &klio_ast::Stmt, visible: &std::collections::HashSet<String>) -> bool {
        match stmt {
            klio_ast::Stmt::Assign { target, .. } => {
                if let Expr::Path { segments, .. } = target
                    && segments.len() == 1 && visible.contains(&segments[0].name) {
                        return true;
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
                    || else_branch.as_ref().is_some_and(|e| walk_expr(e, visible))
            }
            Expr::While { cond, body, .. } => {
                walk_expr(cond, visible) || walk_expr(body, visible)
            }
            Expr::DoWhile { body, cond, .. } => {
                body.as_ref().is_some_and(|b| walk_expr(b, visible))
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
                        .is_some_and(|b| b.stmts.iter().any(|s| walk(s, visible)))
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
pub(crate) fn boxed_cell_reg(b: &mut FuncBuilder, name: &str) -> Reg {
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

/// Simple name of a call's callee, used as the implicit label of a
/// lambda literal in its argument list: `with(x) { … }` → `"with"`,
/// `sb.apply { … }` → `"apply"`. `None` when the callee has no simple
/// name (a call on an arbitrary value expression).
pub(crate) fn callee_label(callee: &Expr) -> Option<String> {
    match callee {
        Expr::Path { segments, .. } if segments.len() == 1 => {
            Some(segments[0].name.clone())
        }
        Expr::Member { name, .. } => Some(name.name.clone()),
        _ => None,
    }
}

pub(crate) fn lower_arg_run(b: &mut FuncBuilder<'_>, args: &[Expr]) -> (Reg, u8) {
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
    // The call's simple name (set by the Call lowering just before this)
    // is the implicit label of any lambda literal directly in this
    // argument list. Re-arm it before each argument so a trailing lambda
    // records it, then clear it so it never leaks past this run.
    let call_label = b.pending_lambda_label.take();
    for (slot, arg) in slots.iter().zip(args.iter()) {
        b.pending_lambda_label = call_label.clone();
        let r = lower_expr(b, arg);
        b.pending_lambda_label = None;
        b.push(Inst::Move { dst: *slot, src: r });
    }
    (first, n as u8)
}

/// Intern an `arg_names` slice into a parallel `Vec<Option<ConstId>>`
/// suitable for `Inst::Call` / `CallMember` / `CallValue` / `NewInstance`.
/// Returns an empty vec when every entry is None (positional-only).
pub(crate) fn intern_arg_names(
    module: &mut crate::Module,
    arg_names: &[Option<String>],
) -> Vec<Option<crate::ConstId>> {
    if arg_names.iter().all(std::option::Option::is_none) {
        return Vec::new();
    }
    arg_names
        .iter()
        .map(|opt| opt.as_ref().map(|s| module.intern_const(Const::String(s.clone()))))
        .collect()
}

pub(crate) fn intern_type_args(
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

pub(crate) fn ast_binop(op: AstBinOp) -> BinOp {
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

pub(crate) fn expr_span(e: &Expr) -> klio_span::Span {
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
