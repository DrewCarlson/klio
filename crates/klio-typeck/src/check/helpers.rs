use super::*;

pub(crate) fn type_ref_uses(t: &TypeRef, name: &str) -> bool {
    // `@UnsafeVariance` annotation on the TypeRef itself suppresses the
    // declaration-site variance position check at this occurrence.
    if has_unsafe_variance(&t.annotations) {
        return false;
    }
    if t.name.name == name && t.type_args.is_empty() && t.function.is_none() {
        return true;
    }
    for a in &t.type_args {
        if !a.is_star && type_ref_uses(&a.ty, name) {
            return true;
        }
    }
    if let Some(f) = &t.function {
        if let Some(r) = &f.receiver {
            if type_ref_uses(r, name) {
                return true;
            }
        }
        for p in &f.params {
            if type_ref_uses(p, name) {
                return true;
            }
        }
        if type_ref_uses(&f.ret, name) {
            return true;
        }
    }
    false
}

pub(crate) fn has_unsafe_variance(anns: &[klio_ast::Annotation]) -> bool {
    anns.iter().any(|a| {
        a.path
            .last()
            .map(|seg| seg.name == "UnsafeVariance")
            .unwrap_or(false)
    })
}

pub(crate) fn annotations_include(anns: &[klio_ast::Annotation], simple_name: &str) -> bool {
    anns.iter().any(|a| {
        a.path
            .last()
            .map(|seg| seg.name == simple_name)
            .unwrap_or(false)
    })
}

pub(crate) fn has_published_api(anns: &[klio_ast::Annotation]) -> bool {
    anns.iter().any(|a| {
        a.path
            .last()
            .map(|seg| seg.name == "PublishedApi")
            .unwrap_or(false)
    })
}

/// Returns the user-class name a `TypeRef` refers to, ignoring nullability.
/// `None` for builtins, function types, and (for now) generic positions
/// where we'd lose precision.
/// Collect every named type reference appearing inside `t` (head name plus
/// every type-argument head, plus function-type receivers, params, and
/// return). Used by the typealias cycle detector to find every potential
/// alias name reachable from the target.
pub(crate) fn collect_aliased_names(t: &TypeRef, out: &mut Vec<String>) {
    if let Some(f) = &t.function {
        if let Some(r) = &f.receiver {
            collect_aliased_names(r, out);
        }
        for p in &f.params {
            collect_aliased_names(p, out);
        }
        collect_aliased_names(&f.ret, out);
    } else {
        out.push(t.name.name.clone());
    }
    for ta in &t.type_args {
        if !ta.is_star {
            collect_aliased_names(&ta.ty, out);
        }
    }
}

/// Replaces every `Type::TypeParam(name)` whose `name` is a key in `subst`
/// with the corresponding concrete type. Recurses into nullable, function,
/// range, and generic forms. Leaves unrelated type-params untouched so a
/// nested generic-class declaration's type parameters survive substitution
/// at an outer call site.
/// True when `before` and `after` differ structurally — i.e. the
/// substitution actually replaced some `TypeParam`. Drives the
/// post-inference lambda re-type loop so we only re-check lambdas
/// whose expected type was refined.
pub(crate) fn expected_changed(before: &Type, after: &Type) -> bool {
    before != after
}

pub(crate) fn substitute_type_params(t: &Type, subst: &std::collections::HashMap<String, Type>) -> Type {
    use klio_types::GenericArg;
    match t {
        Type::TypeParam(n) => subst.get(n).cloned().unwrap_or_else(|| t.clone()),
        Type::Nullable(inner) => {
            substitute_type_params(inner, subst).as_nullable()
        }
        Type::Function { params, return_type, is_suspend } => Type::Function {
            params: params.iter().map(|p| substitute_type_params(p, subst)).collect(),
            return_type: Box::new(substitute_type_params(return_type, subst)),
            is_suspend: *is_suspend,
        },
        Type::Range(inner) => Type::Range(Box::new(substitute_type_params(inner, subst))),
        Type::Generic { name, args } => Type::Generic {
            name: name.clone(),
            args: args
                .iter()
                .map(|a| GenericArg {
                    variance: a.variance,
                    is_star: a.is_star,
                    ty: if a.is_star {
                        a.ty.clone()
                    } else {
                        substitute_type_params(&a.ty, subst)
                    },
                })
                .collect(),
        },
        _ => t.clone(),
    }
}

/// Lowers a `TypeRef` while preserving references to declared type
/// parameters as `Type::TypeParam(name)` so the constraint-system pass
/// can identify them. Outside of `tparams`, falls back to
/// `convert_type_ref_lossy`. Nested generic arguments and function
/// receiver / params / return are walked recursively.
pub(crate) fn convert_type_ref_with_tparams(t: &TypeRef, tparams: &std::collections::HashSet<String>) -> Type {
    use klio_types::GenericArg;
    if t.name.name == "*" {
        return Type::Any;
    }
    if tparams.contains(t.name.name.as_str()) && t.type_args.is_empty() && t.function.is_none() {
        let inner = Type::TypeParam(t.name.name.clone());
        return if t.nullable { inner.as_nullable() } else { inner };
    }
    if let Some(ft) = &t.function {
        let params: Vec<Type> = ft
            .params
            .iter()
            .map(|p| convert_type_ref_with_tparams(p, tparams))
            .collect();
        let ret = convert_type_ref_with_tparams(&ft.ret, tparams);
        let func = Type::Function {
            params,
            return_type: Box::new(ret),
            is_suspend: ft.is_suspend,
        };
        return if t.nullable { func.as_nullable() } else { func };
    }
    if !t.type_args.is_empty() {
        if let Some(builtin) = builtin_by_name(&t.name.name) {
            let _ = builtin;
        }
        let args: Vec<GenericArg> = t
            .type_args
            .iter()
            .map(|a| {
                if a.is_star {
                    GenericArg { variance: a.variance.into(), is_star: true, ty: Type::Any }
                } else {
                    GenericArg {
                        variance: a.variance.into(),
                        is_star: false,
                        ty: convert_type_ref_with_tparams(&a.ty, tparams),
                    }
                }
            })
            .collect();
        let g = Type::Generic { name: t.name.name.clone(), args };
        return if t.nullable { g.as_nullable() } else { g };
    }
    convert_type_ref_lossy(t)
}

pub(crate) fn class_name_from_typeref(t: &TypeRef) -> Option<String> {
    if t.function.is_some() {
        return None;
    }
    if builtin_by_name(&t.name.name).is_some() {
        return None;
    }
    Some(t.name.name.clone())
}

/// Walk a lambda body for a non-local `return`. A `return` inside a
/// nested lambda / anon-fun / object-expression targets that nested
/// frame and is fine; one at the top level targets the enclosing
/// function frame, which is the escape `crossinline` forbids.
pub(crate) fn scan_lambda_stmts_for_return(stmts: &[Stmt]) -> bool {
    stmts.iter().any(|s| match s {
        Stmt::Expr(e) => scan_lambda_expr_for_return(e),
        Stmt::Assign { target, value, .. } => {
            scan_lambda_expr_for_return(target) || scan_lambda_expr_for_return(value)
        }
        Stmt::DestructuringDecl { init, .. } => scan_lambda_expr_for_return(init),
        Stmt::Decl(klio_ast::Decl::Property(p)) => p
            .init
            .as_ref()
            .map(scan_lambda_expr_for_return)
            .unwrap_or(false),
        _ => false,
    })
}

pub(crate) fn scan_lambda_expr_for_return(e: &Expr) -> bool {
    match e {
        Expr::Return { .. } => true,
        Expr::Lambda { .. } | Expr::AnonFun { .. } | Expr::ObjectExpr { .. } => false,
        Expr::Block(b) => scan_lambda_stmts_for_return(&b.stmts),
        Expr::If { cond, then_branch, else_branch, .. } => {
            scan_lambda_expr_for_return(cond)
                || scan_lambda_expr_for_return(then_branch)
                || else_branch.as_ref().map(|e| scan_lambda_expr_for_return(e)).unwrap_or(false)
        }
        Expr::While { cond, body, .. } => {
            scan_lambda_expr_for_return(cond) || scan_lambda_expr_for_return(body)
        }
        Expr::DoWhile { body, cond, .. } => {
            body.as_ref().map(|b| scan_lambda_expr_for_return(b)).unwrap_or(false)
                || scan_lambda_expr_for_return(cond)
        }
        Expr::For { iter, body, .. } => {
            scan_lambda_expr_for_return(iter) || scan_lambda_expr_for_return(body)
        }
        Expr::When { subject, branches, .. } => {
            subject.as_ref().map(|s| scan_lambda_expr_for_return(s)).unwrap_or(false)
                || branches.iter().any(|br| scan_lambda_expr_for_return(&br.body))
        }
        Expr::Try { body, catches, finally, .. } => {
            scan_lambda_stmts_for_return(&body.stmts)
                || catches.iter().any(|c| scan_lambda_stmts_for_return(&c.body.stmts))
                || finally
                    .as_ref()
                    .map(|fb| scan_lambda_stmts_for_return(&fb.stmts))
                    .unwrap_or(false)
        }
        Expr::Labeled { expr, .. }
        | Expr::Unary { expr, .. }
        | Expr::Postfix { expr, .. }
        | Expr::Throw { value: expr, .. }
        | Expr::Spread { expr, .. }
        | Expr::As { expr, .. }
        | Expr::IsCheck { expr, .. } => scan_lambda_expr_for_return(expr),
        Expr::Member { receiver, .. } | Expr::MemberRef { receiver, .. } => {
            scan_lambda_expr_for_return(receiver)
        }
        Expr::Call { callee, args, .. } => {
            scan_lambda_expr_for_return(callee) || args.iter().any(scan_lambda_expr_for_return)
        }
        Expr::Index { receiver, args, .. } => {
            scan_lambda_expr_for_return(receiver) || args.iter().any(scan_lambda_expr_for_return)
        }
        Expr::Binary { lhs, rhs, .. } => {
            scan_lambda_expr_for_return(lhs) || scan_lambda_expr_for_return(rhs)
        }
        _ => false,
    }
}

/// Member names that always have a base in the built-in shape hierarchy
/// (`Any` / `Comparable` etc.) — we can't see those bases at type-check
/// time, so an `override` on a member of one of these names with no user
/// supertype-member match isn't necessarily wrong.
pub(crate) fn stmt_span(s: &Stmt) -> Span {
    match s {
        Stmt::Expr(e) => e.span(),
        Stmt::Decl(d) => match d {
            Decl::Function(f) => f.name.span,
            Decl::Property(p) => p.name.span,
            Decl::Class(c) => c.name.span,
            Decl::Object(o) => o.name.span,
            Decl::TypeAlias(t) => t.name.span,
        },
        Stmt::Assign { span, .. } | Stmt::DestructuringDecl { span, .. } => *span,
    }
}

pub(crate) fn is_builtin_overridable(name: &str) -> bool {
    matches!(
        name,
        "toString"
            | "equals"
            | "hashCode"
            | "compareTo"
            | "iterator"
            | "next"
            | "hasNext"
            | "get"
            | "set"
            | "size"
            | "length"
    )
}

/// The eight actual Kotlin primitive types. `String` is NOT a primitive,
/// so `lateinit var s: String` remains legal.
pub(crate) fn is_primitive_type_name(name: &str) -> bool {
    matches!(
        name,
        "Int" | "Long" | "Short" | "Byte" | "Float" | "Double" | "Boolean" | "Char"
    )
}

pub(crate) fn is_const_capable_type_name(name: &str) -> bool {
    is_primitive_type_name(name) || name == "String"
}

pub(crate) fn accessor_uses_field(a: &Accessor) -> bool {
    match &a.body {
        FunctionBody::Block(b) => block_uses_field(b),
        FunctionBody::Expr(e) => expr_uses_field(e),
    }
}

pub(crate) fn block_uses_field(b: &Block) -> bool {
    b.stmts.iter().any(|s| match s {
        Stmt::Expr(e) => expr_uses_field(e),
        Stmt::Assign { target, value, .. } => expr_uses_field(target) || expr_uses_field(value),
        Stmt::Decl(Decl::Property(p)) => p.init.as_ref().map_or(false, expr_uses_field),
        _ => false,
    })
}

/// Walk `e` and record any bare-name path segment whose first identifier
/// maps to an entry in `by_name` (the set of top-level properties with
/// initializers). Used by the T0076 cycle detector.
pub(crate) fn collect_property_reads(
    e: &Expr,
    by_name: &std::collections::HashMap<String, usize>,
    out: &mut std::collections::HashSet<usize>,
) {
    match e {
        Expr::Path { segments, .. } => {
            if let Some(first) = segments.first() {
                if let Some(&idx) = by_name.get(&first.name) {
                    out.insert(idx);
                }
            }
        }
        Expr::Member { receiver, .. } => collect_property_reads(receiver, by_name, out),
        Expr::Call { callee, args, .. } => {
            collect_property_reads(callee, by_name, out);
            for a in args {
                collect_property_reads(a, by_name, out);
            }
        }
        Expr::Index { receiver, args, .. } => {
            collect_property_reads(receiver, by_name, out);
            for a in args {
                collect_property_reads(a, by_name, out);
            }
        }
        Expr::Binary { lhs, rhs, .. } => {
            collect_property_reads(lhs, by_name, out);
            collect_property_reads(rhs, by_name, out);
        }
        Expr::Unary { expr, .. } | Expr::Postfix { expr, .. } => {
            collect_property_reads(expr, by_name, out);
        }
        Expr::If { cond, then_branch, else_branch, .. } => {
            collect_property_reads(cond, by_name, out);
            collect_property_reads(then_branch, by_name, out);
            if let Some(eb) = else_branch {
                collect_property_reads(eb, by_name, out);
            }
        }
        Expr::When { subject, branches, .. } => {
            if let Some(s) = subject {
                collect_property_reads(s, by_name, out);
            }
            for b in branches {
                for p in &b.patterns {
                    match &p.kind {
                        klio_ast::WhenPatternKind::Value(e)
                        | klio_ast::WhenPatternKind::InRange(e)
                        | klio_ast::WhenPatternKind::NotInRange(e) => {
                            collect_property_reads(e, by_name, out);
                        }
                        _ => {}
                    }
                }
                collect_property_reads(&b.body, by_name, out);
            }
        }
        Expr::Labeled { expr, .. } => collect_property_reads(expr, by_name, out),
        Expr::Block(b) => {
            for s in &b.stmts {
                if let Stmt::Expr(e) = s {
                    collect_property_reads(e, by_name, out);
                }
            }
        }
        Expr::StringTemplate { parts, .. } => {
            for part in parts {
                match part {
                    klio_ast::StringPart::ShortInterp(id) => {
                        if let Some(&idx) = by_name.get(&id.name) {
                            out.insert(idx);
                        }
                    }
                    klio_ast::StringPart::Interp(e) => collect_property_reads(e, by_name, out),
                    klio_ast::StringPart::Text(_) => {}
                }
            }
        }
        Expr::Return { value: Some(v), .. } | Expr::Throw { value: v, .. } => {
            collect_property_reads(v, by_name, out);
        }
        Expr::IsCheck { expr, .. } | Expr::As { expr, .. } | Expr::Spread { expr, .. } => {
            collect_property_reads(expr, by_name, out);
        }
        _ => {}
    }
}

/// Spec §6.3: labels may only be attached to lambda literals, loop
/// statements, or a call whose trailing argument is a lambda literal.
/// Spec §7.1.2: does the LHS type carry a built-in or stdlib-shipped
/// matching `*Assign` operator function? This is the conservative
/// allowlist that the typeck consults to decide whether a compound
/// assignment to a `val`-bound name should be allowed. User classes that
/// declare their own `operator fun plusAssign` are accepted at runtime
/// through the interpreter's dispatch path; here we only need to greenlight
/// the well-known stdlib shapes so the canonical `val xs = mutableListOf(...);
/// xs += elem` form typechecks. Unresolved or wildcard types are accepted
/// to avoid cascading errors when generics aren't fully reconstructed.
pub(crate) fn type_has_compound_assign(ty: &Type, op: AssignOp) -> bool {
    if matches!(op, AssignOp::Assign) {
        return false;
    }
    // Be permissive when the static type is unknown — runtime can still
    // produce a precise error if no method exists.
    if matches!(ty, Type::Unresolved | Type::TypeParam(_)) {
        return true;
    }
    let head = match ty {
        Type::Generic { name, .. } => name.as_str(),
        Type::Nullable(inner) => return type_has_compound_assign(inner, op),
        _ => return false,
    };
    // Stdlib mutable collections accept `+=` / `-=`. Atomics accept the
    // same plus `*=` (timesAssign) via the kotlin.concurrent.atomics
    // extension surface. Conservative: only emit `true` for ops we know
    // are defined; primitives and immutable collections fall through.
    let allow_plus_minus = matches!(
        head,
        "MutableList"
            | "MutableSet"
            | "MutableMap"
            | "MutableCollection"
            | "MutableIterable"
            | "ArrayList"
            | "HashMap"
            | "HashSet"
            | "LinkedHashMap"
            | "LinkedHashSet"
            | "StringBuilder"
            | "AtomicInt"
            | "AtomicLong"
    );
    match op {
        AssignOp::Add | AssignOp::Sub => allow_plus_minus,
        _ => matches!(head, "AtomicInt" | "AtomicLong"),
    }
}

pub(crate) fn is_labelable_target(e: &Expr) -> bool {
    match e {
        Expr::Lambda { .. } => true,
        Expr::For { .. } | Expr::While { .. } | Expr::DoWhile { .. } => true,
        Expr::Call { args, .. } => matches!(args.last(), Some(Expr::Lambda { .. })),
        _ => false,
    }
}

pub(crate) fn expr_uses_field(e: &Expr) -> bool {
    match e {
        Expr::Path { segments, .. } => {
            segments.len() == 1 && segments[0].name == "field"
        }
        Expr::Block(b) => block_uses_field(b),
        Expr::If { cond, then_branch, else_branch, .. } => {
            expr_uses_field(cond)
                || expr_uses_field(then_branch)
                || else_branch.as_ref().map_or(false, |e| expr_uses_field(e))
        }
        Expr::When { subject, branches, .. } => {
            subject.as_ref().map_or(false, |s| expr_uses_field(s))
                || branches.iter().any(|b| expr_uses_field(&b.body))
        }
        Expr::Call { callee, args, .. } => {
            expr_uses_field(callee) || args.iter().any(expr_uses_field)
        }
        Expr::Member { receiver, .. } => expr_uses_field(receiver),
        Expr::Index { receiver, args, .. } => {
            expr_uses_field(receiver) || args.iter().any(expr_uses_field)
        }
        Expr::Binary { lhs, rhs, .. } => expr_uses_field(lhs) || expr_uses_field(rhs),
        Expr::Unary { expr, .. } => expr_uses_field(expr),
        Expr::Postfix { expr, .. } => expr_uses_field(expr),
        Expr::Return { value, .. } => value.as_ref().map_or(false, |e| expr_uses_field(e)),
        Expr::As { expr, .. } => expr_uses_field(expr),
        Expr::IsCheck { expr, .. } => expr_uses_field(expr),
        Expr::Spread { expr, .. } => expr_uses_field(expr),
        Expr::Labeled { expr, .. } => expr_uses_field(expr),
        _ => false,
    }
}


#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PhaseFScope {
    TopLevel,
    Object,
    Class,
}

pub(crate) fn type_display(t: &Type) -> String {
    format!("{t}")
}

/// Dot-path identity for an `Expr`: returns `Some("a.b.c")` for `Path` /
/// `Member` chains over plain identifiers, `None` for anything containing
/// a call, index, safe-call, or non-identifier prefix. Used as the key
/// for smart-cast narrowings so a check like `n.shape is Circle`
/// narrows the same chain when it's read again.
pub(crate) fn dot_path_key(e: &Expr) -> Option<String> {
    match e {
        Expr::Path { segments, .. } if segments.len() == 1 => Some(segments[0].name.clone()),
        Expr::Member { receiver, name, safe, .. } if !*safe => {
            let lhs = dot_path_key(receiver)?;
            Some(format!("{lhs}.{}", name.name))
        }
        _ => None,
    }
}

pub(crate) fn single_path_name(e: &Expr) -> Option<String> {
    if let Expr::Path { segments, .. } = e {
        if segments.len() == 1 {
            return Some(segments[0].name.clone());
        }
    }
    None
}

/// Element type of a primitive-array class name (`IntArray` → `Int`).
pub(crate) fn primitive_array_elem_by_name(name: &str) -> Option<Type> {
    let short = name.strip_prefix("kotlin.").unwrap_or(name);
    match short {
        "IntArray" => Some(Type::Int),
        "LongArray" => Some(Type::Long),
        "ShortArray" => Some(Type::Short),
        "ByteArray" => Some(Type::Byte),
        "DoubleArray" => Some(Type::Double),
        "FloatArray" => Some(Type::Float),
        "BooleanArray" => Some(Type::Boolean),
        "CharArray" => Some(Type::Char),
        _ => None,
    }
}

/// Extract the element type of an array-shaped value type. Recognizes
/// `Array<T>`, the primitive `IntArray` / `LongArray` / … specializations,
/// and their nullable forms.
pub(crate) fn array_element_type(t: &Type) -> Option<Type> {
    let t = t.non_null();
    match t {
        Type::Generic { name, args } if name == "Array" => {
            args.first().filter(|a| !a.is_star).map(|a| a.ty.clone())
        }
        Type::Generic { name, .. } => match name.as_str() {
            "IntArray" => Some(Type::Int),
            "LongArray" => Some(Type::Long),
            "ShortArray" => Some(Type::Short),
            "ByteArray" => Some(Type::Byte),
            "DoubleArray" => Some(Type::Double),
            "FloatArray" => Some(Type::Float),
            "BooleanArray" => Some(Type::Boolean),
            "CharArray" => Some(Type::Char),
            _ => None,
        },
        _ => None,
    }
}

/// True if `a` and `b` are statically compatible enough that an equality
/// comparison is meaningful (one is a subtype of the other, both are
/// numeric, either is `Unresolved` / `Any` / `Nothing` / a type parameter,
/// or both are user classes whose relationship we cannot decide at typeck).
pub(crate) fn equality_types_compatible(a: &Type, b: &Type) -> bool {
    if matches!(a, Type::Unresolved) || matches!(b, Type::Unresolved) {
        return true;
    }
    if matches!(a, Type::Nothing) || matches!(b, Type::Nothing) {
        return true;
    }
    if matches!(a, Type::Any | Type::Nullable(_)) || matches!(b, Type::Any | Type::Nullable(_)) {
        // Comparing through a nullable / Any reference is always legal.
        if matches!(a.non_null(), Type::Any) || matches!(b.non_null(), Type::Any) {
            return true;
        }
    }
    // Type parameters and generics with unresolved bounds: stay permissive.
    if matches!(a, Type::TypeParam(_)) || matches!(b, Type::TypeParam(_)) {
        return true;
    }
    if a.is_subtype_of(b) || b.is_subtype_of(a) {
        return true;
    }
    // Both numeric: cross-type comparison is allowed (Kotlin's `Number`
    // equality compares mathematical values, `1 == 1L` is true).
    if is_numeric(a) && is_numeric(b) {
        return true;
    }
    // User-class generics where we cannot resolve subtyping precisely: be
    // permissive to avoid false positives on instances flowing through
    // `Type::Generic { name, .. }` whose hierarchy isn't known here.
    if matches!(a, Type::Generic { .. }) || matches!(b, Type::Generic { .. }) {
        return true;
    }
    false
}

pub(crate) fn type_label(t: &Type) -> String {
    format!("{t}")
}

pub(crate) fn is_numeric(t: &Type) -> bool {
    matches!(
        t.non_null(),
        Type::Int | Type::Long | Type::Short | Type::Byte | Type::Double | Type::Float
    )
}

pub(crate) fn numeric_rank(t: &Type) -> Option<u8> {
    Some(match t.non_null() {
        Type::Byte => 1,
        Type::Short => 2,
        Type::Int => 3,
        Type::Long => 4,
        Type::Float => 5,
        Type::Double => 6,
        _ => return None,
    })
}

pub(crate) fn numeric_lub(a: &Type, b: &Type) -> Type {
    match (numeric_rank(a), numeric_rank(b)) {
        (Some(ra), Some(rb)) => {
            let max_rank = ra.max(rb);
            let winner = if ra >= rb { a.non_null().clone() } else { b.non_null().clone() };
            // Byte/Short arithmetic promotes to Int (Kotlin spec).
            if max_rank <= 3 && matches!(winner, Type::Byte | Type::Short) {
                Type::Int
            } else {
                winner
            }
        }
        _ => Type::Unresolved,
    }
}

/// Least upper bound for if/when/try branch unification. Conservative: for
/// non-trivial class types we fall back to `Any`/`Any?`.
pub(crate) fn lub(a: &Type, b: &Type) -> Type {
    if matches!(a, Type::Unresolved) || matches!(b, Type::Unresolved) {
        return Type::Unresolved;
    }
    if a == b {
        return a.clone();
    }
    if matches!(a, Type::Nothing) {
        return b.clone();
    }
    if matches!(b, Type::Nothing) {
        return a.clone();
    }
    if a.is_subtype_of(b) {
        return b.clone();
    }
    if b.is_subtype_of(a) {
        return a.clone();
    }
    // Nullable promotion.
    if a.is_nullable() || b.is_nullable() {
        let na = match a {
            Type::Nullable(i) => (**i).clone(),
            other => other.clone(),
        };
        let nb = match b {
            Type::Nullable(i) => (**i).clone(),
            other => other.clone(),
        };
        return lub(&na, &nb).as_nullable();
    }
    if matches!(a, Type::Unit) || matches!(b, Type::Unit) {
        return Type::Unit;
    }
    if is_numeric(a) && is_numeric(b) {
        return numeric_lub(a, b);
    }
    Type::Any
}

/// Score a parameter list by Widen-rank — lower is more specific. Spec
/// §3.5.1: prefer `Int` over `Short`/`Byte`/`Long` and `Short` over `Byte`
/// when the same literal applies to both overloads. Non-integer types score
/// zero so overloads that don't mix integer parameters are unaffected.
pub(crate) fn widen_score(params: &[Type]) -> u32 {
    params.iter().map(int_widen_rank).sum()
}

pub(crate) fn describe_params(params: &[Type]) -> String {
    params
        .iter()
        .map(|t| format!("{t:?}"))
        .collect::<Vec<_>>()
        .join(", ")
}

/// Lower rank = wider integer type per Kotlin's literal-widening rule.
/// `Int` is the spec-preferred default for an integer literal, so it gets
/// rank 0; `Short` / `Long` / `Byte` rank above it. Non-int types collapse
/// to 0 — they're handled by ordinary subtyping in the MSC test, never by
/// the widening rule.
pub(crate) fn int_widen_rank(t: &Type) -> u32 {
    match t {
        Type::Int => 0,
        Type::Short => 1,
        Type::Long => 2,
        Type::Byte => 3,
        _ => 0,
    }
}

pub(crate) fn is_builtin_integer(t: &Type) -> bool {
    matches!(t, Type::Int | Type::Long | Type::Short | Type::Byte)
}

pub(crate) fn is_builtin_numeric(t: &Type) -> bool {
    is_builtin_integer(t) || matches!(t, Type::Float | Type::Double)
}

/// Position in Kotlin's numeric widening tower (Byte ⊂ Short ⊂ Int ⊂
/// Long ⊂ Float ⊂ Double). A *narrower* type is the more specific
/// overload target for a given numeric argument, so a smaller rank is
/// more specific. Used only for the mixed integer/floating
/// specificity case; integer-vs-integer keeps `int_widen_rank`'s
/// literal-widening preference untouched.
pub(crate) fn num_tower_rank(t: &Type) -> u32 {
    match t {
        Type::Byte => 0,
        Type::Short => 1,
        Type::Int => 2,
        Type::Long => 3,
        Type::Float => 4,
        Type::Double => 5,
        _ => 0,
    }
}

/// Class-aware subtype check used by the MSC pairwise test. Walks `sub`'s
/// supertype chain in `classes` looking for `sup`. Returns true on a hit
/// or on `sub == sup`. Anonymous / not-in-table classes fall through.
pub(crate) fn class_is_subtype_of(
    classes: &HashMap<String, ClassInfo>,
    sub: &str,
    sup: &str,
) -> bool {
    if sub == sup { return true; }
    let mut stack: Vec<String> = vec![sub.to_string()];
    let mut seen: HashSet<String> = HashSet::new();
    while let Some(n) = stack.pop() {
        if !seen.insert(n.clone()) { continue; }
        if let Some(info) = classes.get(&n) {
            for s in &info.supertypes {
                if s == sup { return true; }
                stack.push(s.clone());
            }
        }
    }
    false
}

/// Spec §11.4.2: returns true when F1 is equally or more applicable than
/// F2 as an overload candidate for a call providing `arg_count` arguments.
/// Builds the conceptual constraint system Xk <: Yk over the first
/// `arg_count` non-vararg slots (Widen(Xk) <: Widen(Yk) when both are
/// built-in integer types) and reports soundness as a bool. Type
/// parameters of F1 are treated as free wildcards via `Type::Unresolved`
/// (which `is_subtype_of` already permits to subtype anything), modeling
/// the spec's "F1's type params bound to fresh variables, F2's free".
pub(crate) fn at_least_as_applicable(
    f1: &FnSig,
    f2: &FnSig,
    arg_count: usize,
    classes: &HashMap<String, ClassInfo>,
) -> bool {
    let n = arg_count.min(f1.params.len()).min(f2.params.len());
    for k in 0..n {
        let x = &f1.params[k];
        let y = &f2.params[k];
        if is_builtin_integer(x) && is_builtin_integer(y) {
            // Widen(X) <: Widen(Y) iff X's widening set is a subset of Y's.
            // Encoded compactly via the rank: a *smaller* rank means a
            // narrower widening set (Int has the smallest set, Byte the
            // largest). F1 is at-least-as-applicable iff rank(X) <= rank(Y).
            if int_widen_rank(x) > int_widen_rank(y) {
                return false;
            }
        } else if is_builtin_numeric(x) && is_builtin_numeric(y) {
            // Mixed integer/floating (or floating/floating): the
            // narrower numeric param is the more specific target, so
            // `f(Long)` dominates `f(Double)` for an integer argument.
            // Long is not a Kotlin subtype of Double, so without this
            // both would land in the fitting set and report a bogus
            // ambiguity.
            if num_tower_rank(x) > num_tower_rank(y) {
                return false;
            }
        } else if matches!(x, Type::Unresolved) && matches!(y, Type::Unresolved) {
            // Both params are user-class slots collapsed to `Unresolved`.
            // Compare via the class hierarchy when both names are known;
            // otherwise treat the pair as a tie (wildcard ≡ wildcard) and
            // fall through to subsequent slots.
            if let (Some(xn), Some(yn)) = (
                f1.param_class_names.get(k).and_then(|n| n.as_deref()),
                f2.param_class_names.get(k).and_then(|n| n.as_deref()),
            ) {
                if !class_is_subtype_of(classes, xn, yn) {
                    return false;
                }
            }
        } else if !x.is_subtype_of(y) {
            return false;
        }
    }
    true
}

/// Spec §11.4.2: pick the most specific candidate among `fitting`. Returns
/// `Ok(&FnSig)` when a unique most-specific candidate exists, `Err(set)`
/// when the call is ambiguous (the returned set is the equally-specific
/// frontier — caller chooses how to report it).
pub(crate) fn pick_msc<'a>(
    fitting: &[&'a FnSig],
    arg_count: usize,
    classes: &HashMap<String, ClassInfo>,
) -> Result<&'a FnSig, Vec<&'a FnSig>> {
    if fitting.is_empty() {
        return Err(Vec::new());
    }
    if fitting.len() == 1 {
        return Ok(fitting[0]);
    }
    // Frontier: every candidate that is at-least-as-applicable as every
    // other candidate. Spec §11.4.2 case 1 picks a unique frontier member.
    let mut frontier: Vec<&FnSig> = Vec::new();
    for (i, f1) in fitting.iter().enumerate() {
        let dominates_all = fitting.iter().enumerate().all(|(j, f2)| {
            i == j || at_least_as_applicable(f1, f2, arg_count, classes)
        });
        if dominates_all {
            frontier.push(*f1);
        }
    }
    if frontier.is_empty() {
        // §11.4.2 case 2: nobody dominates everyone. Fall to case-3
        // tiebreakers over the original set.
        frontier = fitting.to_vec();
    }
    if frontier.len() == 1 {
        return Ok(frontier[0]);
    }
    // Tiebreakers, in order: non-parameterized > parameterized; then
    // fewer unspecified defaults; then no-vararg > has-vararg.
    let any_non_param = frontier.iter().any(|s| s.type_param_count == 0);
    if any_non_param {
        frontier.retain(|s| s.type_param_count == 0);
    }
    if frontier.len() == 1 {
        return Ok(frontier[0]);
    }
    let min_defaults = frontier
        .iter()
        .map(|s| {
            let supplied = arg_count.min(s.params.len());
            s.has_default[..supplied].iter().filter(|h| **h).count()
                + s.has_default.iter().skip(supplied).filter(|h| **h).count()
        })
        .min()
        .unwrap();
    frontier.retain(|s| {
        let supplied = arg_count.min(s.params.len());
        let used_defaults = s.has_default[..supplied].iter().filter(|h| **h).count()
            + s.has_default.iter().skip(supplied).filter(|h| **h).count();
        used_defaults == min_defaults
    });
    if frontier.len() == 1 {
        return Ok(frontier[0]);
    }
    let any_no_vararg = frontier.iter().any(|s| !s.is_vararg.iter().any(|v| *v));
    if any_no_vararg {
        frontier.retain(|s| !s.is_vararg.iter().any(|v| *v));
    }
    if frontier.len() == 1 {
        return Ok(frontier[0]);
    }
    Err(frontier)
}

// === Phase K tailrec analysis helpers ===

pub(crate) fn tailrec_is_self_call(callee: &Expr, fn_name: &str) -> bool {
    matches!(callee, Expr::Path { segments, .. }
        if segments.len() == 1 && segments[0].name == fn_name)
}

pub(crate) fn tailrec_walk_block(
    b: &Block,
    tail: bool,
    fn_name: &str,
    sites: &mut std::collections::HashSet<Span>,
) {
    let n = b.stmts.len();
    for (i, s) in b.stmts.iter().enumerate() {
        let is_last = i + 1 == n;
        let stmt_tail = tail && is_last;
        match s {
            Stmt::Expr(e) => tailrec_walk_expr(e, stmt_tail, fn_name, sites),
            Stmt::Decl(_) => {}
            Stmt::Assign { target, value, .. } => {
                tailrec_walk_expr(target, false, fn_name, sites);
                tailrec_walk_expr(value, false, fn_name, sites);
            }
            Stmt::DestructuringDecl { init, .. } => {
                tailrec_walk_expr(init, false, fn_name, sites);
            }
        }
    }
}

pub(crate) fn tailrec_walk_expr(
    e: &Expr,
    tail: bool,
    fn_name: &str,
    sites: &mut std::collections::HashSet<Span>,
) {
    match e {
        Expr::Call { callee, args, span, .. } => {
            if tail && tailrec_is_self_call(callee, fn_name) {
                sites.insert(*span);
            }
            tailrec_walk_expr(callee, false, fn_name, sites);
            for a in args {
                tailrec_walk_expr(a, false, fn_name, sites);
            }
        }
        Expr::If { cond, then_branch, else_branch, .. } => {
            tailrec_walk_expr(cond, false, fn_name, sites);
            tailrec_walk_expr(then_branch, tail, fn_name, sites);
            if let Some(eb) = else_branch {
                tailrec_walk_expr(eb, tail, fn_name, sites);
            }
        }
        Expr::When { subject, branches, .. } => {
            if let Some(s) = subject {
                tailrec_walk_expr(s, false, fn_name, sites);
            }
            for br in branches {
                for p in &br.patterns {
                    match &p.kind {
                        WhenPatternKind::Value(ex)
                        | WhenPatternKind::InRange(ex)
                        | WhenPatternKind::NotInRange(ex) => {
                            tailrec_walk_expr(ex, false, fn_name, sites);
                        }
                        _ => {}
                    }
                }
                tailrec_walk_expr(&br.body, tail, fn_name, sites);
            }
        }
        Expr::Block(b) => tailrec_walk_block(b, tail, fn_name, sites),
        Expr::Return { value, label, .. } => {
            let returns_to_self = match label {
                None => true,
                Some(l) => l.name == fn_name,
            };
            if let Some(v) = value {
                tailrec_walk_expr(v, returns_to_self, fn_name, sites);
            }
        }
        Expr::Labeled { expr, .. } => tailrec_walk_expr(expr, tail, fn_name, sites),
        Expr::Try { body, catches, finally, .. } => {
            tailrec_walk_block(body, false, fn_name, sites);
            for c in catches {
                tailrec_walk_block(&c.body, false, fn_name, sites);
            }
            if let Some(fb) = finally {
                tailrec_walk_block(fb, false, fn_name, sites);
            }
        }
        Expr::While { cond, body, .. } => {
            tailrec_walk_expr(cond, false, fn_name, sites);
            tailrec_walk_expr(body, false, fn_name, sites);
        }
        Expr::DoWhile { body, cond, .. } => {
            if let Some(b) = body {
                tailrec_walk_expr(b, false, fn_name, sites);
            }
            tailrec_walk_expr(cond, false, fn_name, sites);
        }
        Expr::For { iter, body, .. } => {
            tailrec_walk_expr(iter, false, fn_name, sites);
            tailrec_walk_expr(body, false, fn_name, sites);
        }
        Expr::Binary { lhs, rhs, .. } => {
            tailrec_walk_expr(lhs, false, fn_name, sites);
            tailrec_walk_expr(rhs, false, fn_name, sites);
        }
        Expr::Unary { expr, .. } | Expr::Postfix { expr, .. } => {
            tailrec_walk_expr(expr, false, fn_name, sites);
        }
        Expr::Member { receiver, .. } => tailrec_walk_expr(receiver, false, fn_name, sites),
        Expr::Index { receiver, args, .. } => {
            tailrec_walk_expr(receiver, false, fn_name, sites);
            for a in args {
                tailrec_walk_expr(a, false, fn_name, sites);
            }
        }
        Expr::Throw { value, .. } => tailrec_walk_expr(value, false, fn_name, sites),
        Expr::IsCheck { expr, .. } | Expr::As { expr, .. } => {
            tailrec_walk_expr(expr, false, fn_name, sites);
        }
        Expr::Spread { expr, .. } => tailrec_walk_expr(expr, false, fn_name, sites),
        Expr::Lambda { .. } | Expr::AnonFun { .. } | Expr::ObjectExpr { .. } => {}
        _ => {}
    }
}

pub(crate) fn tailrec_collect_all_block(b: &Block, fn_name: &str, out: &mut Vec<Span>) {
    for s in &b.stmts {
        match s {
            Stmt::Expr(e) => tailrec_collect_all_expr(e, fn_name, out),
            Stmt::Assign { target, value, .. } => {
                tailrec_collect_all_expr(target, fn_name, out);
                tailrec_collect_all_expr(value, fn_name, out);
            }
            Stmt::DestructuringDecl { init, .. } => {
                tailrec_collect_all_expr(init, fn_name, out);
            }
            Stmt::Decl(_) => {}
        }
    }
}

pub(crate) fn tailrec_collect_all_expr(e: &Expr, fn_name: &str, out: &mut Vec<Span>) {
    match e {
        Expr::Call { callee, args, span, .. } => {
            if tailrec_is_self_call(callee, fn_name) {
                out.push(*span);
            }
            tailrec_collect_all_expr(callee, fn_name, out);
            for a in args {
                tailrec_collect_all_expr(a, fn_name, out);
            }
        }
        Expr::If { cond, then_branch, else_branch, .. } => {
            tailrec_collect_all_expr(cond, fn_name, out);
            tailrec_collect_all_expr(then_branch, fn_name, out);
            if let Some(eb) = else_branch {
                tailrec_collect_all_expr(eb, fn_name, out);
            }
        }
        Expr::When { subject, branches, .. } => {
            if let Some(s) = subject {
                tailrec_collect_all_expr(s, fn_name, out);
            }
            for br in branches {
                for p in &br.patterns {
                    match &p.kind {
                        WhenPatternKind::Value(ex)
                        | WhenPatternKind::InRange(ex)
                        | WhenPatternKind::NotInRange(ex) => {
                            tailrec_collect_all_expr(ex, fn_name, out);
                        }
                        _ => {}
                    }
                }
                tailrec_collect_all_expr(&br.body, fn_name, out);
            }
        }
        Expr::Block(b) => tailrec_collect_all_block(b, fn_name, out),
        Expr::Return { value, .. } => {
            if let Some(v) = value {
                tailrec_collect_all_expr(v, fn_name, out);
            }
        }
        Expr::Labeled { expr, .. } => tailrec_collect_all_expr(expr, fn_name, out),
        Expr::Try { body, catches, finally, .. } => {
            tailrec_collect_all_block(body, fn_name, out);
            for c in catches {
                tailrec_collect_all_block(&c.body, fn_name, out);
            }
            if let Some(fb) = finally {
                tailrec_collect_all_block(fb, fn_name, out);
            }
        }
        Expr::While { cond, body, .. } => {
            tailrec_collect_all_expr(cond, fn_name, out);
            tailrec_collect_all_expr(body, fn_name, out);
        }
        Expr::DoWhile { body, cond, .. } => {
            if let Some(b) = body {
                tailrec_collect_all_expr(b, fn_name, out);
            }
            tailrec_collect_all_expr(cond, fn_name, out);
        }
        Expr::For { iter, body, .. } => {
            tailrec_collect_all_expr(iter, fn_name, out);
            tailrec_collect_all_expr(body, fn_name, out);
        }
        Expr::Binary { lhs, rhs, .. } => {
            tailrec_collect_all_expr(lhs, fn_name, out);
            tailrec_collect_all_expr(rhs, fn_name, out);
        }
        Expr::Unary { expr, .. } | Expr::Postfix { expr, .. } => {
            tailrec_collect_all_expr(expr, fn_name, out);
        }
        Expr::Member { receiver, .. } => tailrec_collect_all_expr(receiver, fn_name, out),
        Expr::Index { receiver, args, .. } => {
            tailrec_collect_all_expr(receiver, fn_name, out);
            for a in args {
                tailrec_collect_all_expr(a, fn_name, out);
            }
        }
        Expr::Throw { value, .. } => tailrec_collect_all_expr(value, fn_name, out),
        Expr::IsCheck { expr, .. } | Expr::As { expr, .. } => {
            tailrec_collect_all_expr(expr, fn_name, out);
        }
        Expr::Spread { expr, .. } => tailrec_collect_all_expr(expr, fn_name, out),
        Expr::Lambda { .. } | Expr::AnonFun { .. } | Expr::ObjectExpr { .. } => {}
        _ => {}
    }
}
