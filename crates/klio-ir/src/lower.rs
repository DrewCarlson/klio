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
use crate::{BinOp, BlockId, Const, Inst, Reg, Terminator, UnOp};

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

fn is_boxed_to_any_form(e: &Expr) -> bool {
    fn is_any_name(name: &str) -> bool {
        matches!(name, "Any")
    }
    match e {
        Expr::As { ty, .. } => is_any_name(&ty.name.name),
        Expr::Path { segments, .. } => {
            // A var binding annotated `: Any` — handled at use site
            // via expr_types in tree walker; the IR lowering can't
            // see types here, so just be conservative.
            let _ = segments;
            false
        }
        _ => false,
    }
}

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

fn is_package_head(name: &str) -> bool {
    if name.chars().next().map_or(false, |c| c.is_lowercase()) {
        return true;
    }
    // Primitive types' companion accesses (`Int.MAX_VALUE`, …)
    // also flatten through the FQN-flattening path so the host
    // can dispatch them via primitive_companion_const.
    matches!(
        name,
        "Int" | "Long" | "Short" | "Byte" | "UInt" | "ULong" | "UShort" | "UByte"
            | "Float" | "Double" | "Char" | "Boolean" | "String"
    )
}

/// Flatten a `Member{receiver: Member{...,Path}}` chain into a
/// dotted FQN like `kotlin.math.PI`. Returns `None` when the chain
/// is not purely identifier segments (e.g. it has a Call, Index, or
/// arbitrary expression).
fn collect_dotted_fqn(expr: &Expr) -> Option<String> {
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

pub fn bind_params(b: &mut FuncBuilder<'_>, names: &[&str]) {
    for (i, name) in names.iter().enumerate() {
        let dst = b.alloc_reg();
        b.push(Inst::LoadParam { dst, idx: i as u16 });
        b.bind(*name, dst);
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
    let primary_params: Vec<crate::Param> = c
        .primary_params
        .iter()
        .map(|p| crate::Param {
            name: p.name.name.clone(),
            ty: crate::TypeRef::unit(),
            default: None,
        })
        .collect();
    // Register the class shell first so the class name resolves
    // inside its own method bodies (`class Foo { fun copy() = Foo(...) }`).
    let class_id = module.add_class(crate::Class {
        id: crate::ClassId(0),
        name: c.name.name.clone(),
        fqn: c.name.name.clone(),
        primary_params,
        methods: Vec::new(),
        init_block: None,
        companion: None,
        supertypes: Vec::new(),
    });
    // Collect this class's own member names so method-body
    // lowering can tell `someMember()` (this.someMember) apart
    // from `topLevelFn()` (LoadGlobal).
    let mut own_member_names: std::collections::HashSet<String> =
        std::collections::HashSet::new();
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
        own_member_names.insert("entries".to_string());
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
    for m in &c.members {
        if let klio_ast::Decl::Function(f) = m {
            let _ = lower_method(module, f, &c.name.name, &own_member_names);
            let last_id = crate::FuncId((module.funcs.len() - 1) as u32);
            methods.push(last_id);
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
    module.func_index.push((f.name.name.clone(), id));
    module.funcs.push(placed.clone());
    placed
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
pub fn lower_method(
    module: &mut crate::Module,
    f: &klio_ast::Function,
    owner_class: &str,
    own_members: &std::collections::HashSet<String>,
) -> crate::Func {
    let func = lower_function_body_with_implicit_owner(
        module,
        f,
        &["this"],
        Some(owner_class),
        Some(own_members),
    );
    let id = crate::FuncId(module.funcs.len() as u32);
    let mut placed = func;
    placed.id = id;
    module.funcs.push(placed.clone());
    placed
}

fn lower_function_body_with_implicit_owner(
    module: &mut crate::Module,
    f: &klio_ast::Function,
    implicit_params: &[&str],
    owner_class: Option<&str>,
    own_members: Option<&std::collections::HashSet<String>>,
) -> crate::Func {
    let mut b = FuncBuilder::new(module);
    let mut names: Vec<&str> = Vec::with_capacity(implicit_params.len() + f.params.len());
    names.extend_from_slice(implicit_params);
    names.extend(f.params.iter().map(|p| p.name.name.as_str()));
    bind_params(&mut b, &names);
    if let Some(owner) = owner_class {
        let _ = b.set_owner_class(owner.to_string());
    }
    if let Some(set) = own_members {
        let _ = b.set_own_members(set.clone());
    }
    if f.is_tailrec {
        let _ = b.set_tailrec_self(f.name.name.clone());
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
        })
        .collect();
    params.extend(f.params.iter().map(|p| crate::Param {
        name: p.name.name.clone(),
        ty: crate::TypeRef::unit(),
        default: None,
    }));
    func.params = params;
    func.is_suspend = f.is_suspend;
    func
}

/// Lower one expression into the current block. Returns the
/// register holding the result. Statements that do not produce a
/// value (assignments, declarations) return a synthetic `Unit`
/// register so downstream code stays uniform.
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
                        if let Some(home) = b.mutable_home(&segments[0].name) {
                            b.push(Inst::Move { dst: home, src: dst });
                        } else {
                            b.rebind(&segments[0].name, dst);
                        }
                    }
                    Expr::Member { receiver, name, safe: false, .. } => {
                        let recv = lower_expr(b, receiver);
                        let field = b.module.intern_const(Const::String(name.name.clone()));
                        b.push(Inst::SetField { receiver: recv, field, value: dst });
                    }
                    Expr::Index { receiver, args: idx_args, .. } => {
                        let recv = lower_expr(b, receiver);
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
        Expr::Path { segments, .. } => {
            if segments.len() == 1 {
                if let Some(r) = b.resolve(&segments[0].name) {
                    return r;
                }
                // Lambda-body capture: name lives in an enclosing
                // frame but not as a top-level global.
                if b.knows_outer(&segments[0].name) {
                    let idx = b.record_capture(&segments[0].name);
                    let dst = b.alloc_reg();
                    b.push(Inst::LoadCapture { dst, idx });
                    // Bind the capture name to the freshly-loaded
                    // reg so subsequent Path reads hit the local
                    // path instead of re-emitting LoadCapture.
                    b.bind(segments[0].name.clone(), dst);
                    return dst;
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
                }
                // Not a local and not a known capture — emit
                // LoadGlobal so the host resolves against the
                // interpreter's globals env.
                let dst = b.alloc_reg();
                let name = b.module.intern_const(Const::String(segments[0].name.clone()));
                b.push(Inst::LoadGlobal { dst, name });
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
                let dst = b.alloc_reg();
                let n = b.module.intern_const(Const::String(first.name.clone()));
                b.push(Inst::LoadGlobal { dst, name: n });
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
                        } else {
                            let dst = b.alloc_reg();
                            let n = b.module.intern_const(Const::String(ident.name.clone()));
                            b.push(Inst::LoadGlobal { dst, name: n });
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
            let recv = lower_expr(b, receiver);
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
            // Flatten chains like `kotlin.math.PI` into a single FQN
            // lookup against the host when the head is an unresolved
            // identifier (i.e. not a local). Stdlib package roots
            // (`kotlin`, `kotlinx`, etc.) aren't real values, so the
            // chained-GetField fallback would fail at `kotlin` itself.
            if let Some(fqn) = collect_dotted_fqn(expr) {
                if let Some(head) = fqn.split('.').next() {
                    if is_package_head(head)
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
            let recv = lower_expr(b, receiver);
            let dst = b.alloc_reg();
            let field = b.module.intern_const(Const::String(name.name.clone()));
            b.push(Inst::GetField { dst, receiver: recv, field });
            dst
        }
        Expr::Index { receiver, args, .. } => {
            // `r[a, b, ...]` → r.get(a, b, ...). Evaluator's
            // CallMember + host.call_member route dispatches to
            // Value::Map / List / Array / user classes uniformly.
            let recv = lower_expr(b, receiver);
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
            let recv = lower_expr(b, receiver);
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
        Expr::Call { callee, args, arg_names: ast_arg_names, .. }
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
            let Expr::Path { segments, .. } = callee.as_ref() else { unreachable!() };
            if segments.len() == 1 {
                if let Some(func_id) = b.module.func_id(&segments[0].name) {
                    b.push(Inst::Call {
                        dst,
                        func: func_id,
                        args: args_start,
                        n_args: args.len() as u8,
                        arg_names,
                    });
                } else {
                    let callee_r = lower_expr(b, callee);
                    b.push(Inst::CallValue {
                        dst,
                        callee: callee_r,
                        args: args_start,
                        n_args: args.len() as u8,
                        arg_names,
                    });
                }
            } else {
                let callee_r = lower_expr(b, callee);
                b.push(Inst::CallValue {
                    dst,
                    callee: callee_r,
                    args: args_start,
                    n_args: args.len() as u8,
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
        Expr::Call { callee, args, arg_names: ast_arg_names, is_infix, .. } => {
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
            // Path-callee with a registered top-level fn → Call{func}.
            if let Expr::Path { segments, .. } = callee.as_ref() {
                if segments.len() == 1 {
                    if let Some(func_id) = b.module.func_id(&segments[0].name) {
                        let (args_start, count) = lower_arg_run(b, args);
                        let arg_names = intern_arg_names(b.module, ast_arg_names);
                        let dst = b.alloc_reg();
                        b.push(Inst::Call {
                            dst,
                            func: func_id,
                            args: args_start,
                            n_args: count,
                            arg_names,
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
                if segments.len() == 1
                    && b.resolve(&segments[0].name).is_none()
                    && !b.knows_outer(&segments[0].name)
                    // Only emit this.name(...) when the owning
                    // class declares this name (method or
                    // property); otherwise it's a global call
                    // and the normal CallValue path should fire.
                    && b.has_own_member(&segments[0].name)
                {
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
            }
            // Built-in stdlib companion shortcuts: `Result.success(x)`,
            // `Result.failure(e)`, etc. The callee parses as
            // Member { Path("Result"), "success" }; rewrite to a
            // direct stdlib FQN dispatch since `Result` isn't a
            // value in the runtime globals.
            if let Expr::Member { receiver: recv_box, name: mname, .. } = callee.as_ref() {
                if let Expr::Path { segments, .. } = recv_box.as_ref() {
                    if segments.len() == 1
                        && b.resolve(&segments[0].name).is_none()
                        && !b.knows_outer(&segments[0].name)
                        && b.module.class_id(&segments[0].name).is_none()
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
            // Fully-qualified callee like `kotlin.math.abs(x)` →
            // resolve the FQN as a global and CallValue against the
            // resulting intrinsic / function value. Avoids the
            // chained-GetField that would fail at `kotlin` itself.
            if let Expr::Member { .. } = callee.as_ref() {
                if let Some(fqn) = collect_dotted_fqn(callee) {
                    if let Some(head) = fqn.split('.').next() {
                        if is_package_head(head)
                            && b.resolve(head).is_none()
                            && !b.knows_outer(head)
                            && b.module.class_id(head).is_none()
                            // When `this` is bound (we're inside a
                            // method body) the head could be a
                            // field on `this`; don't treat it as a
                            // package FQN unless that field doesn't
                            // exist on the receiver class.
                            && b.resolve("this").is_none()
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
                    // `super.method(...)` — emit `CallSuper` so the
                    // host walks the parent class chain rather
                    // than re-entering the leaf class's override.
                    // `super<Klazz>.method()` passes Klazz so the
                    // host dispatches against that specific
                    // supertype.
                    if let Expr::Super { qualifier, .. } = receiver.as_ref() {
                        if let Some(this_reg) = b.resolve("this") {
                            if let Some(owner) = b.owner_class().map(|s| s.to_string()) {
                                let (args_start, count) = lower_arg_run(b, args);
                                let arg_names = intern_arg_names(b.module, ast_arg_names);
                                let dst = b.alloc_reg();
                                let nm = b.module.intern_const(Const::String(name.name.clone()));
                                let oc = b.module.intern_const(Const::String(owner));
                                let qual_const = qualifier
                                    .as_ref()
                                    .map(|t| b.module.intern_const(Const::String(t.name.name.clone())));
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
                    let recv = lower_expr(b, receiver);
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
            let result = b.alloc_reg();
            let exit = b.alloc_block();
            let finally_blk = finally.as_ref().map(|_| b.alloc_block());

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
            b.attach_catches(cur_id, catch_handlers, finally_blk);
            let body_val = lower_block(b, body);
            b.push(Inst::Move { dst: result, src: body_val });
            if let Some(fin) = finally_blk {
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
                if let Some(fin) = finally_blk {
                    b.terminate(Terminator::Goto(fin));
                } else {
                    b.terminate(Terminator::Goto(exit));
                }
            }

            // Finally body (if present): lower then fall through
            // to exit. (Re-throw on uncaught propagation is a
            // future refinement; the simple model runs finally
            // once on caught + normal-exit paths.)
            if let Some(fin) = finally_blk {
                b.switch_to(fin);
                if let Some(blk) = finally {
                    let _ = lower_block(b, blk);
                }
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
            let (_body_func, captured_names) =
                lower_lambda_body_capturing(b.module, params, body, outer_names);
            let captures: Vec<Reg> = captured_names
                .iter()
                .filter_map(|n| b.resolve(n))
                .collect();
            let param_names: Vec<String> =
                params.iter().map(|p| p.name.clone()).collect();
            let dst = b.alloc_reg();
            b.push(Inst::AstLambda {
                dst,
                params: param_names,
                body_ast: body.clone(),
                captures,
                captured_names,
                absorb_return: false,
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
                    let recv = lower_expr(b, receiver);
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
                        if let Some(home) = b.mutable_home(&segments[0].name) {
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
                        } else {
                            b.rebind(&segments[0].name, new);
                        }
                    }
                    Expr::Member { receiver, name, safe: false, .. } => {
                        // `obj.field++` — write the incremented value
                        // back through the same SetField path the
                        // host's set_field uses for class setters.
                        let recv = lower_expr(b, receiver);
                        let field = b.module.intern_const(Const::String(name.name.clone()));
                        b.push(Inst::SetField { receiver: recv, field, value: new });
                    }
                    Expr::Index { receiver, args: idx_args, .. } => {
                        // `xs[i]++` — read above, write back via .set(i, new).
                        let recv = lower_expr(b, receiver);
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
            let recv = lower_expr(b, receiver);
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
                .filter_map(|n| b.resolve(n))
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
            let (_body_func, captured_names) = lower_lambda_body_capturing(
                b.module, &param_idents, &body_block, outer_names,
            );
            let captures: Vec<Reg> = captured_names
                .iter()
                .filter_map(|n| b.resolve(n))
                .collect();
            let dst = b.alloc_reg();
            b.push(Inst::AstLambda {
                dst,
                params: param_names,
                body_ast: body_block,
                captures,
                captured_names,
                absorb_return: true,
            });
            dst
        }
        Expr::This { .. } => {
            // `this` bare resolves to the implicit first param
            // bound by `lower_method` / extension lowering.
            if let Some(this_reg) = b.resolve("this") {
                this_reg
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

/// Lower a lambda body, threading the enclosing builder's
/// visible-name set so Path references that hit it lower to
/// `LoadCapture`. Returns the body's `FuncId` plus the ordered
/// list of captured names — the caller resolves each to an outer
/// reg and ships it through `Inst::Lambda::captures`.
fn lower_lambda_body_capturing(
    module: &mut crate::Module,
    params: &[klio_ast::Ident],
    body: &klio_ast::Block,
    outer: std::collections::HashSet<String>,
) -> (crate::FuncId, Vec<String>) {
    let mut b = FuncBuilder::new(module);
    b.set_outer_names(outer);
    let names: Vec<&str> = params.iter().map(|p| p.name.as_str()).collect();
    bind_params(&mut b, &names);
    let result = lower_block(&mut b, body);
    b.terminate(Terminator::Return(Some(result)));
    let captured = b.captures_taken().to_vec();
    let func = b.finish("<lambda>", "<lambda>", crate::TypeRef::unit());
    let id = crate::FuncId(module.funcs.len() as u32);
    let mut placed = func;
    placed.id = id;
    module.funcs.push(placed);
    (id, captured)
}

fn lower_for(
    b: &mut FuncBuilder<'_>,
    vars: &[klio_ast::Ident],
    iter: &Expr,
    body: &Expr,
) -> Reg {
    lower_for_labeled(b, vars, iter, body, None)
}

fn lower_for_labeled(
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

/// Try to lower a `when (subject)` as a Switch terminator. Returns
/// the (case-arms, optional default body block, per-branch body
/// blocks) tuple when every non-else branch carries a single
/// literal pattern. Returns None for the general Branch-chain
/// fallback. Each branch index in the input maps 1:1 to the
/// per-branch body-block vec — None for the else branch (whose
/// block is the default), Some(blk) otherwise.
fn collect_switch_arms(
    b: &mut FuncBuilder<'_>,
    branches: &[klio_ast::WhenBranch],
) -> Option<(Vec<(crate::ConstId, BlockId)>, Option<BlockId>, Vec<Option<BlockId>>)> {
    let mut cases: Vec<(crate::ConstId, BlockId)> = Vec::new();
    let mut body_blocks: Vec<Option<BlockId>> = Vec::with_capacity(branches.len());
    let mut default: Option<BlockId> = None;
    for branch in branches {
        let blk = b.alloc_block();
        // Else branch: take it as the default. Only one is valid.
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
            let value_expr = match &pat.kind {
                klio_ast::WhenPatternKind::Value(e) => e,
                _ => return None,
            };
            let const_id = match value_expr {
                Expr::IntLit { value, .. } if *value >= i32::MIN as i64 && *value <= i32::MAX as i64 => {
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
    // Empty / trivial when expressions aren't worth a Switch.
    if cases.is_empty() && default.is_none() {
        return None;
    }
    Some((cases, default, body_blocks))
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
    // Switch fast path: when the subject is present and every
    // non-else branch matches a single literal pattern, emit a
    // single Switch terminator. Avoids the cascade of Eq/Branch
    // ops at runtime and gives sealed-when / enum-when an O(1)
    // dispatch shape. Falls through to the Branch-chain lowering
    // when any pattern is non-literal (Is, InRange, NotIs, etc.).
    if let Some(subj) = subject_r {
        if let Some(arms) = collect_switch_arms(b, branches) {
            let (cases, default_blk, body_block_for_branch) = arms;
            let default = default_blk.unwrap_or(join);
            b.terminate(Terminator::Switch { reg: subj, arms: cases, default });
            // Emit each branch body, including the optional else
            // branch landing on default_blk.
            for (branch, body_blk) in branches.iter().zip(body_block_for_branch.iter()) {
                if let Some(blk) = body_blk {
                    b.switch_to(*blk);
                    let v = lower_expr(b, &branch.body);
                    b.push(Inst::Move { dst: result, src: v });
                    b.terminate(Terminator::Goto(join));
                }
            }
            b.switch_to(join);
            return result;
        }
    }
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
                        // `in r` lowers to r.contains(subject).
                        let range_r = lower_expr(b, e);
                        let args_start = b.alloc_reg();
                        b.push(Inst::Move { dst: args_start, src: subj });
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
                        b.push(Inst::Move { dst: args_start, src: subj });
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
                    _ => {
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
            if p.mutable || p.init.is_none() {
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
                let outer_names: std::collections::HashSet<String> = b.visible_names();
                let param_idents: Vec<klio_ast::Ident> =
                    f.params.iter().map(|p| p.name.clone()).collect();
                let (_body_func, captured_names) = lower_lambda_body_capturing(
                    b.module,
                    &param_idents,
                    &body,
                    outer_names,
                );
                let captures: Vec<Reg> = captured_names
                    .iter()
                    .filter_map(|n| b.resolve(n))
                    .collect();
                let param_names: Vec<String> =
                    f.params.iter().map(|p| p.name.name.clone()).collect();
                let dst = b.alloc_reg();
                b.push(Inst::AstLambda {
                    dst,
                    params: param_names,
                    body_ast: body,
                    captures,
                    captured_names,
                    absorb_return: true,
                });
                b.bind(f.name.name.clone(), dst);
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
            let path_is_val = matches!(
                target,
                Expr::Path { segments, .. }
                    if segments.len() == 1
                        && !b.is_mutable(&segments[0].name)
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
                    if let Some(home) = b.mutable_home(&segments[0].name) {
                        b.push(Inst::Move { dst: home, src: combined });
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
                    } else {
                        // Top-level binding: route through StoreGlobal so
                        // the tree-walker setter / delegate fires.
                        let n = b.module.intern_const(Const::String(segments[0].name.clone()));
                        b.push(Inst::StoreGlobal { name: n, value: combined });
                    }
                }
                Expr::Member { receiver, name, .. } => {
                    let recv = lower_expr(b, receiver);
                    let field = b.module.intern_const(Const::String(name.name.clone()));
                    b.push(Inst::SetField { receiver: recv, field, value: combined });
                }
                Expr::Index { receiver, args: idx_args, .. } => {
                    // `m[k] = v` lowers to receiver.set(k, v) so
                    // map / mutable-list assignment dispatches
                    // through the same call_member path that
                    // handles built-in collection mutation.
                    let recv = lower_expr(b, receiver);
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
                .filter_map(|n| b.resolve(n))
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
