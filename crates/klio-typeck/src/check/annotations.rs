use super::{Expr, Decl, HashMap, KotlinFile, Diagnostic, FunctionBody, Block, Stmt, WhenPatternKind, StringPart, Span, codes, DiagnosticSink, Checker, Function, Property, Class, HashSet, is_primitive_type_name};

/// Severity of an opt-in requirement; parallels `DeprecationLevel`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum OptInLevel {
    Warning,
    Error,
}

#[derive(Debug, Clone)]
pub(crate) struct OptInMarker {
    pub(crate) level: OptInLevel,
    pub(crate) message: Option<String>,
}

pub(crate) fn parse_requires_opt_in(anns: &[klio_ast::Annotation]) -> Option<OptInMarker> {
    for a in anns {
        let leaf = a.path.last().map_or("", |s| s.name.as_str());
        if leaf != "RequiresOptIn" {
            continue;
        }
        let mut info = OptInMarker { level: OptInLevel::Error, message: None };
        let mut positional = 0usize;
        for (i, arg) in a.args.iter().enumerate() {
            let name = a.arg_names.get(i).cloned().flatten();
            let slot = match name.as_deref() {
                Some("message") => "message",
                Some("level") => "level",
                Some(_) => continue,
                None => match positional {
                    0 => {
                        positional += 1;
                        "message"
                    }
                    1 => {
                        positional += 1;
                        "level"
                    }
                    _ => continue,
                },
            };
            match slot {
                "message" => info.message = extract_string_literal(arg),
                "level" => {
                    if let Some(lv) = extract_opt_in_level(arg) {
                        info.level = lv;
                    }
                }
                _ => {}
            }
        }
        return Some(info);
    }
    None
}

pub(crate) fn extract_opt_in_level(e: &Expr) -> Option<OptInLevel> {
    let name = match e {
        Expr::Path { segments, .. } => segments.last().map(|s| s.name.as_str()),
        Expr::Member { name, .. } => Some(name.name.as_str()),
        _ => None,
    }?;
    match name {
        "WARNING" => Some(OptInLevel::Warning),
        "ERROR" => Some(OptInLevel::Error),
        _ => None,
    }
}

/// Build the per-declaration map of opt-in markers applied at the
/// declaration site. Only markers known in `markers` count.
pub(crate) fn collect_required_opt_ins(
    decls: &[Decl],
    markers: &HashMap<String, OptInMarker>,
    out: &mut HashMap<String, Vec<String>>,
) {
    for d in decls {
        match d {
            Decl::Function(f) => {
                let m = marker_names_in(&f.annotations, markers);
                if !m.is_empty() {
                    out.insert(f.name.name.clone(), m);
                }
            }
            Decl::Property(p) => {
                let m = marker_names_in(&p.annotations, markers);
                if !m.is_empty() {
                    out.insert(p.name.name.clone(), m);
                }
            }
            Decl::Class(c) => {
                let m = marker_names_in(&c.annotations, markers);
                if !m.is_empty() {
                    out.insert(c.name.name.clone(), m);
                }
                collect_required_opt_ins(&c.members, markers, out);
            }
            Decl::Object(o) => {
                collect_required_opt_ins(&o.members, markers, out);
            }
            Decl::TypeAlias(a) => {
                let m = marker_names_in(&a.annotations, markers);
                if !m.is_empty() {
                    out.insert(a.name.name.clone(), m);
                }
            }
        }
    }
}

pub(crate) fn marker_names_in(
    anns: &[klio_ast::Annotation],
    markers: &HashMap<String, OptInMarker>,
) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for a in anns {
        if let Some(leaf) = a.path.last()
            && markers.contains_key(&leaf.name) {
                out.push(leaf.name.clone());
            }
    }
    out
}

/// Read marker classes named in `@OptIn(M1::class, M2::class)` on the
/// given annotation set. Returns the set of marker simple names.
pub(crate) fn opt_in_markers_in(anns: &[klio_ast::Annotation]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for a in anns {
        let leaf = a.path.last().map_or("", |s| s.name.as_str());
        if leaf != "OptIn" {
            continue;
        }
        for arg in &a.args {
            if let Expr::MemberRef { receiver, name, .. } = arg
                && name.name == "class"
                    && let Expr::Path { segments, .. } = receiver.as_ref()
                        && let Some(seg) = segments.last() {
                            out.push(seg.name.clone());
                        }
        }
    }
    out
}

pub(crate) fn collect_opt_in_diagnostics(
    file: &KotlinFile,
    markers: &HashMap<String, OptInMarker>,
    required: &HashMap<String, Vec<String>>,
) -> Vec<Diagnostic> {
    let mut out: Vec<Diagnostic> = Vec::new();
    let mut scope: Vec<String> = Vec::new();
    for d in &file.decls {
        walk_decl_for_opt_in(d, markers, required, &mut scope, &mut out);
    }
    out
}

pub(crate) fn walk_decl_for_opt_in(
    d: &Decl,
    markers: &HashMap<String, OptInMarker>,
    required: &HashMap<String, Vec<String>>,
    scope: &mut Vec<String>,
    out: &mut Vec<Diagnostic>,
) {
    match d {
        Decl::Function(f) => {
            let added = push_scope(scope, &f.annotations);
            // A function annotated with the marker itself also "opts
            // in" to the marker for its own body.
            let self_markers = marker_names_in(&f.annotations, markers);
            for m in &self_markers {
                scope.push(m.clone());
            }
            if let Some(body) = &f.body {
                match body {
                    FunctionBody::Expr(e) => {
                        walk_expr_for_opt_in(e, markers, required, scope, out);
                    }
                    FunctionBody::Block(b) => {
                        walk_block_for_opt_in(b, markers, required, scope, out);
                    }
                }
            }
            for p in &f.params {
                if let Some(def) = &p.default {
                    walk_expr_for_opt_in(def, markers, required, scope, out);
                }
            }
            for _ in 0..self_markers.len() {
                scope.pop();
            }
            for _ in 0..added {
                scope.pop();
            }
        }
        Decl::Property(p) => {
            let added = push_scope(scope, &p.annotations);
            let self_markers = marker_names_in(&p.annotations, markers);
            for m in &self_markers {
                scope.push(m.clone());
            }
            if let Some(init) = &p.init {
                walk_expr_for_opt_in(init, markers, required, scope, out);
            }
            for acc in [p.getter.as_ref(), p.setter.as_ref()].into_iter().flatten() {
                match &acc.body {
                    FunctionBody::Expr(e) => {
                        walk_expr_for_opt_in(e, markers, required, scope, out);
                    }
                    FunctionBody::Block(b) => {
                        walk_block_for_opt_in(b, markers, required, scope, out);
                    }
                }
            }
            for _ in 0..self_markers.len() {
                scope.pop();
            }
            for _ in 0..added {
                scope.pop();
            }
        }
        Decl::Class(c) => {
            let added = push_scope(scope, &c.annotations);
            let self_markers = marker_names_in(&c.annotations, markers);
            for m in &self_markers {
                scope.push(m.clone());
            }
            for ib in &c.init_blocks {
                walk_block_for_opt_in(ib, markers, required, scope, out);
            }
            for p in &c.primary_params {
                if let Some(def) = &p.default {
                    walk_expr_for_opt_in(def, markers, required, scope, out);
                }
            }
            for sc in &c.secondary_ctors {
                if let Some(body) = &sc.body {
                    walk_block_for_opt_in(body, markers, required, scope, out);
                }
            }
            for ee in &c.enum_entries {
                for a in &ee.args {
                    walk_expr_for_opt_in(a, markers, required, scope, out);
                }
                for m in &ee.body_members {
                    walk_decl_for_opt_in(m, markers, required, scope, out);
                }
            }
            for m in &c.members {
                walk_decl_for_opt_in(m, markers, required, scope, out);
            }
            for _ in 0..self_markers.len() {
                scope.pop();
            }
            for _ in 0..added {
                scope.pop();
            }
        }
        Decl::Object(o) => {
            for m in &o.members {
                walk_decl_for_opt_in(m, markers, required, scope, out);
            }
        }
        Decl::TypeAlias(_) => {}
    }
}

pub(crate) fn push_scope(scope: &mut Vec<String>, anns: &[klio_ast::Annotation]) -> usize {
    let added = opt_in_markers_in(anns);
    let n = added.len();
    for a in added {
        scope.push(a);
    }
    n
}

pub(crate) fn walk_block_for_opt_in(
    b: &Block,
    markers: &HashMap<String, OptInMarker>,
    required: &HashMap<String, Vec<String>>,
    scope: &mut Vec<String>,
    out: &mut Vec<Diagnostic>,
) {
    for s in &b.stmts {
        match s {
            Stmt::Expr(e) => walk_expr_for_opt_in(e, markers, required, scope, out),
            Stmt::Decl(d) => walk_decl_for_opt_in(d, markers, required, scope, out),
            Stmt::Assign { target, value, .. } => {
                walk_expr_for_opt_in(target, markers, required, scope, out);
                walk_expr_for_opt_in(value, markers, required, scope, out);
            }
            Stmt::DestructuringDecl { init, .. } => {
                walk_expr_for_opt_in(init, markers, required, scope, out);
            }
        }
    }
}

pub(crate) fn walk_expr_for_opt_in(
    e: &Expr,
    markers: &HashMap<String, OptInMarker>,
    required: &HashMap<String, Vec<String>>,
    scope: &mut Vec<String>,
    out: &mut Vec<Diagnostic>,
) {
    match e {
        Expr::Path { segments, span }
            if segments.len() == 1 => {
                emit_opt_in_at(&segments[0].name, *span, markers, required, scope, out);
            }
        Expr::Call { callee, args, span, .. } => {
            let mut emitted = false;
            if let Expr::Path { segments, .. } = callee.as_ref()
                && segments.len() == 1 {
                    emitted = emit_opt_in_at(
                        &segments[0].name,
                        *span,
                        markers,
                        required,
                        scope,
                        out,
                    );
                }
            if !emitted {
                walk_expr_for_opt_in(callee, markers, required, scope, out);
            }
            for a in args {
                walk_expr_for_opt_in(a, markers, required, scope, out);
            }
        }
        Expr::Member { receiver, .. } => walk_expr_for_opt_in(receiver, markers, required, scope, out),
        Expr::MemberRef { receiver, .. } => walk_expr_for_opt_in(receiver, markers, required, scope, out),
        Expr::Binary { lhs, rhs, .. } => {
            walk_expr_for_opt_in(lhs, markers, required, scope, out);
            walk_expr_for_opt_in(rhs, markers, required, scope, out);
        }
        Expr::Unary { expr, .. } | Expr::Postfix { expr, .. } => {
            walk_expr_for_opt_in(expr, markers, required, scope, out);
        }
        Expr::Index { receiver, args, .. } => {
            walk_expr_for_opt_in(receiver, markers, required, scope, out);
            for a in args {
                walk_expr_for_opt_in(a, markers, required, scope, out);
            }
        }
        Expr::Return { value, .. } => {
            if let Some(v) = value {
                walk_expr_for_opt_in(v, markers, required, scope, out);
            }
        }
        Expr::As { expr, .. } | Expr::IsCheck { expr, .. } => {
            walk_expr_for_opt_in(expr, markers, required, scope, out);
        }
        Expr::Spread { expr, .. } | Expr::Labeled { expr, .. } => {
            walk_expr_for_opt_in(expr, markers, required, scope, out);
        }
        Expr::If { cond, then_branch, else_branch, .. } => {
            walk_expr_for_opt_in(cond, markers, required, scope, out);
            walk_expr_for_opt_in(then_branch, markers, required, scope, out);
            if let Some(eb) = else_branch {
                walk_expr_for_opt_in(eb, markers, required, scope, out);
            }
        }
        Expr::While { cond, body, .. } | Expr::DoWhile { cond, body: Some(body), .. } => {
            walk_expr_for_opt_in(cond, markers, required, scope, out);
            walk_expr_for_opt_in(body, markers, required, scope, out);
        }
        Expr::DoWhile { cond, body: None, .. } => {
            walk_expr_for_opt_in(cond, markers, required, scope, out);
        }
        Expr::For { iter, body, .. } => {
            walk_expr_for_opt_in(iter, markers, required, scope, out);
            walk_expr_for_opt_in(body, markers, required, scope, out);
        }
        Expr::When { subject, branches, .. } => {
            if let Some(s) = subject {
                walk_expr_for_opt_in(s, markers, required, scope, out);
            }
            for br in branches {
                for p in &br.patterns {
                    match &p.kind {
                        WhenPatternKind::Value(e)
                        | WhenPatternKind::InRange(e)
                        | WhenPatternKind::NotInRange(e) => {
                            walk_expr_for_opt_in(e, markers, required, scope, out);
                        }
                        _ => {}
                    }
                }
                walk_expr_for_opt_in(&br.body, markers, required, scope, out);
            }
        }
        Expr::Try { body, catches, finally, .. } => {
            walk_block_for_opt_in(body, markers, required, scope, out);
            for c in catches {
                walk_block_for_opt_in(&c.body, markers, required, scope, out);
            }
            if let Some(f) = finally {
                walk_block_for_opt_in(f, markers, required, scope, out);
            }
        }
        Expr::Throw { value, .. } => walk_expr_for_opt_in(value, markers, required, scope, out),
        Expr::Block(b) => walk_block_for_opt_in(b, markers, required, scope, out),
        Expr::Lambda { body, .. } => walk_block_for_opt_in(body, markers, required, scope, out),
        Expr::AnonFun { body, .. } => {
            if let Some(b) = body {
                match b.as_ref() {
                    FunctionBody::Expr(e) => walk_expr_for_opt_in(e, markers, required, scope, out),
                    FunctionBody::Block(blk) => walk_block_for_opt_in(blk, markers, required, scope, out),
                }
            }
        }
        Expr::ObjectExpr { members, supertype_args, supertype_delegates, .. } => {
            for m in members {
                walk_decl_for_opt_in(m, markers, required, scope, out);
            }
            for args in supertype_args.iter().flatten() {
                for a in args {
                    walk_expr_for_opt_in(a, markers, required, scope, out);
                }
            }
            for d in supertype_delegates.iter().flatten() {
                walk_expr_for_opt_in(d, markers, required, scope, out);
            }
        }
        Expr::StringTemplate { parts, .. } => {
            for p in parts {
                if let StringPart::Interp(inner) = p {
                    walk_expr_for_opt_in(inner, markers, required, scope, out);
                }
            }
        }
        _ => {}
    }
}

pub(crate) fn emit_opt_in_at(
    name: &str,
    span: Span,
    markers: &HashMap<String, OptInMarker>,
    required: &HashMap<String, Vec<String>>,
    scope: &[String],
    out: &mut Vec<Diagnostic>,
) -> bool {
    let Some(needed) = required.get(name) else { return false };
    let mut emitted = false;
    for marker in needed {
        if scope.iter().any(|m| m == marker) {
            continue;
        }
        let info = match markers.get(marker) {
            Some(i) => i,
            None => continue,
        };
        let suffix = match &info.message {
            Some(m) if !m.is_empty() => format!(": {m}"),
            _ => String::new(),
        };
        let body = format!(
            "`{name}` requires opt-in via `@OptIn({marker}::class)`{suffix}"
        );
        match info.level {
            OptInLevel::Warning => out.push(
                Diagnostic::warning(body, span).with_code(codes::WARN_OPT_IN),
            ),
            OptInLevel::Error => {
                out.push(Diagnostic::error(body, span).with_code(codes::TYPE_OPT_IN_REQUIRED));
            }
        }
        emitted = true;
    }
    emitted
}

/// Spec §17.5.6: a `@Suppress("code", ...)` annotation on a declaration
/// silences each named diagnostic emitted anywhere inside that
/// declaration's span. Scope is lexical: an inner `@Suppress` adds to
/// the enclosing one.
pub(crate) fn apply_suppress_annotations(file: &KotlinFile, diagnostics: &mut DiagnosticSink) {
    let mut regions: Vec<SuppressRegion> = Vec::new();
    collect_suppress_regions(file, &mut regions);
    if regions.is_empty() {
        return;
    }
    diagnostics.retain(|d| {
        let code = match d.code() {
            Some(c) => c,
            None => return true,
        };
        let span = d.primary.span;
        for r in &regions {
            if r.span.file != span.file {
                continue;
            }
            if r.span.start <= span.start && span.end <= r.span.end
                && r.codes.iter().any(|c| c == code) {
                    return false;
                }
        }
        true
    });
}

pub(crate) struct SuppressRegion {
    pub(crate) span: Span,
    pub(crate) codes: Vec<String>,
}

pub(crate) fn collect_suppress_regions(file: &KotlinFile, out: &mut Vec<SuppressRegion>) {
    // `@file:Suppress(...)` on the KotlinFile covers the whole file.
    // The parser currently lifts `@file:` annotations onto the
    // top-level declaration that follows, so file-level suppression is
    // handled via the decls below.
    for d in &file.decls {
        collect_suppress_decl(d, out);
    }
}

pub(crate) fn collect_suppress_decl(d: &Decl, out: &mut Vec<SuppressRegion>) {
    match d {
        Decl::Function(f) => {
            push_suppress(&f.annotations, f.span, out);
            for p in &f.params {
                push_suppress(&p.annotations, p.span, out);
            }
        }
        Decl::Property(p) => {
            push_suppress(&p.annotations, p.span, out);
        }
        Decl::Class(c) => {
            push_suppress(&c.annotations, c.span, out);
            for cp in &c.primary_params {
                push_suppress(&cp.annotations, cp.span, out);
            }
            for sc in &c.secondary_ctors {
                push_suppress(&sc.annotations, sc.span, out);
            }
            for ee in &c.enum_entries {
                push_suppress(&ee.annotations, ee.span, out);
            }
            for m in &c.members {
                collect_suppress_decl(m, out);
            }
        }
        Decl::Object(o) => {
            for m in &o.members {
                collect_suppress_decl(m, out);
            }
        }
        Decl::TypeAlias(a) => {
            push_suppress(&a.annotations, a.span, out);
        }
    }
}

pub(crate) fn push_suppress(
    anns: &[klio_ast::Annotation],
    span: Span,
    out: &mut Vec<SuppressRegion>,
) {
    for a in anns {
        let leaf = a.path.last().map_or("", |s| s.name.as_str());
        if leaf != "Suppress" {
            continue;
        }
        let mut codes: Vec<String> = Vec::new();
        for arg in &a.args {
            if let Some(s) = extract_string_literal(arg) {
                codes.push(s);
            }
        }
        if !codes.is_empty() {
            out.push(SuppressRegion { span, codes });
        }
    }
}

/// Spec §17.5.5 deprecation levels.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DeprecationLevel {
    Warning,
    Error,
    Hidden,
}

#[derive(Debug, Clone)]
pub(crate) struct DeprecationInfo {
    pub(crate) level: DeprecationLevel,
    pub(crate) message: Option<String>,
}

pub(crate) fn parse_deprecation(anns: &[klio_ast::Annotation]) -> Option<DeprecationInfo> {
    for a in anns {
        let leaf = a.path.last().map_or("", |s| s.name.as_str());
        if leaf != "Deprecated" {
            continue;
        }
        let mut info = DeprecationInfo { level: DeprecationLevel::Warning, message: None };
        // Positional first arg is `message: String` unless an explicit
        // `message = ...` named arg is also given. ReplaceWith / level
        // can appear in any position by name.
        let mut positional_idx = 0usize;
        for (i, arg) in a.args.iter().enumerate() {
            let name = a.arg_names.get(i).cloned().flatten();
            let slot = match name.as_deref() {
                Some("message") => "message",
                Some("level") => "level",
                Some("replaceWith") => "replaceWith",
                Some(_) => continue,
                None => match positional_idx {
                    0 => {
                        positional_idx += 1;
                        "message"
                    }
                    1 => {
                        positional_idx += 1;
                        "replaceWith"
                    }
                    2 => {
                        positional_idx += 1;
                        "level"
                    }
                    _ => continue,
                },
            };
            match slot {
                "message" => info.message = extract_string_literal(arg),
                "level" => {
                    if let Some(lv) = extract_deprecation_level(arg) {
                        info.level = lv;
                    }
                }
                _ => {}
            }
        }
        return Some(info);
    }
    None
}

pub(crate) fn extract_string_literal(e: &Expr) -> Option<String> {
    if let Expr::StringTemplate { parts, .. } = e {
        let mut out = String::new();
        for p in parts {
            match p {
                StringPart::Text(t) => out.push_str(t),
                _ => return None,
            }
        }
        return Some(out);
    }
    None
}

pub(crate) fn extract_deprecation_level(e: &Expr) -> Option<DeprecationLevel> {
    let name = match e {
        Expr::Path { segments, .. } => segments.last().map(|s| s.name.as_str()),
        Expr::Member { name, .. } => Some(name.name.as_str()),
        _ => None,
    }?;
    match name {
        "WARNING" => Some(DeprecationLevel::Warning),
        "ERROR" => Some(DeprecationLevel::Error),
        "HIDDEN" => Some(DeprecationLevel::Hidden),
        _ => None,
    }
}

pub(crate) fn collect_deprecation_info(decls: &[Decl], out: &mut HashMap<String, DeprecationInfo>) {
    for d in decls {
        match d {
            Decl::Function(f) => {
                if let Some(info) = parse_deprecation(&f.annotations) {
                    out.insert(f.name.name.clone(), info);
                }
            }
            Decl::Property(p) => {
                if let Some(info) = parse_deprecation(&p.annotations) {
                    out.insert(p.name.name.clone(), info);
                }
            }
            Decl::Class(c) => {
                if let Some(info) = parse_deprecation(&c.annotations) {
                    out.insert(c.name.name.clone(), info);
                }
            }
            Decl::Object(o) => {
                // Object name acts as a value reference; recurse into
                // members for top-level-like decls.
                for m in &o.members {
                    collect_deprecation_info(std::slice::from_ref(m), out);
                }
            }
            Decl::TypeAlias(a) => {
                if let Some(info) = parse_deprecation(&a.annotations) {
                    out.insert(a.name.name.clone(), info);
                }
            }
        }
    }
}

pub(crate) fn collect_deprecation_diagnostics(
    file: &KotlinFile,
    info: &HashMap<String, DeprecationInfo>,
) -> Vec<Diagnostic> {
    let mut out: Vec<Diagnostic> = Vec::new();
    for d in &file.decls {
        walk_decl_for_deprecation(d, info, &mut out);
    }
    out
}

pub(crate) fn walk_decl_for_deprecation(
    d: &Decl,
    info: &HashMap<String, DeprecationInfo>,
    out: &mut Vec<Diagnostic>,
) {
    match d {
        Decl::Function(f) => {
            if let Some(body) = &f.body {
                match body {
                    FunctionBody::Expr(e) => walk_expr_for_deprecation(e, info, out),
                    FunctionBody::Block(b) => walk_block_for_deprecation(b, info, out),
                }
            }
            for p in &f.params {
                if let Some(def) = &p.default {
                    walk_expr_for_deprecation(def, info, out);
                }
            }
        }
        Decl::Property(p) => {
            if let Some(init) = &p.init {
                walk_expr_for_deprecation(init, info, out);
            }
            for acc in [p.getter.as_ref(), p.setter.as_ref()].into_iter().flatten() {
                match &acc.body {
                    FunctionBody::Expr(e) => walk_expr_for_deprecation(e, info, out),
                    FunctionBody::Block(b) => walk_block_for_deprecation(b, info, out),
                }
            }
        }
        Decl::Class(c) => {
            for ib in &c.init_blocks {
                walk_block_for_deprecation(ib, info, out);
            }
            for p in &c.primary_params {
                if let Some(def) = &p.default {
                    walk_expr_for_deprecation(def, info, out);
                }
            }
            for sc in &c.secondary_ctors {
                if let Some(body) = &sc.body {
                    walk_block_for_deprecation(body, info, out);
                }
            }
            for ee in &c.enum_entries {
                for a in &ee.args {
                    walk_expr_for_deprecation(a, info, out);
                }
                for m in &ee.body_members {
                    walk_decl_for_deprecation(m, info, out);
                }
            }
            for m in &c.members {
                walk_decl_for_deprecation(m, info, out);
            }
        }
        Decl::Object(o) => {
            for m in &o.members {
                walk_decl_for_deprecation(m, info, out);
            }
        }
        Decl::TypeAlias(_) => {}
    }
}

pub(crate) fn walk_block_for_deprecation(
    b: &Block,
    info: &HashMap<String, DeprecationInfo>,
    out: &mut Vec<Diagnostic>,
) {
    for s in &b.stmts {
        walk_stmt_for_deprecation(s, info, out);
    }
}

pub(crate) fn walk_stmt_for_deprecation(
    s: &Stmt,
    info: &HashMap<String, DeprecationInfo>,
    out: &mut Vec<Diagnostic>,
) {
    match s {
        Stmt::Expr(e) => walk_expr_for_deprecation(e, info, out),
        Stmt::Decl(d) => walk_decl_for_deprecation(d, info, out),
        Stmt::Assign { target, value, .. } => {
            walk_expr_for_deprecation(target, info, out);
            walk_expr_for_deprecation(value, info, out);
        }
        Stmt::DestructuringDecl { init, .. } => {
            walk_expr_for_deprecation(init, info, out);
        }
    }
}

pub(crate) fn walk_expr_for_deprecation(
    e: &Expr,
    info: &HashMap<String, DeprecationInfo>,
    out: &mut Vec<Diagnostic>,
) {
    match e {
        Expr::Path { segments, span }
            if segments.len() == 1 => {
                emit_deprecation_at(&segments[0].name, *span, info, out);
            }
        Expr::Call { callee, args, span, .. } => {
            // Recurse into the callee unless it's a bare-name reference
            // to a deprecated symbol — we emit once for the call as a
            // whole using the call's span.
            let mut emitted_at_call = false;
            if let Expr::Path { segments, .. } = callee.as_ref()
                && segments.len() == 1
                    && info.contains_key(&segments[0].name) {
                        emit_deprecation_at(&segments[0].name, *span, info, out);
                        emitted_at_call = true;
                    }
            if !emitted_at_call {
                walk_expr_for_deprecation(callee, info, out);
            }
            for a in args {
                walk_expr_for_deprecation(a, info, out);
            }
        }
        Expr::Member { receiver, .. } => walk_expr_for_deprecation(receiver, info, out),
        Expr::MemberRef { receiver, .. } => walk_expr_for_deprecation(receiver, info, out),
        Expr::Binary { lhs, rhs, .. } => {
            walk_expr_for_deprecation(lhs, info, out);
            walk_expr_for_deprecation(rhs, info, out);
        }
        Expr::Unary { expr, .. } => walk_expr_for_deprecation(expr, info, out),
        Expr::Postfix { expr, .. } => walk_expr_for_deprecation(expr, info, out),
        Expr::Index { receiver, args, .. } => {
            walk_expr_for_deprecation(receiver, info, out);
            for a in args {
                walk_expr_for_deprecation(a, info, out);
            }
        }
        Expr::Return { value, .. } => {
            if let Some(v) = value {
                walk_expr_for_deprecation(v, info, out);
            }
        }
        Expr::As { expr, .. } => walk_expr_for_deprecation(expr, info, out),
        Expr::IsCheck { expr, .. } => walk_expr_for_deprecation(expr, info, out),
        Expr::Spread { expr, .. } => walk_expr_for_deprecation(expr, info, out),
        Expr::Labeled { expr, .. } => walk_expr_for_deprecation(expr, info, out),
        Expr::If { cond, then_branch, else_branch, .. } => {
            walk_expr_for_deprecation(cond, info, out);
            walk_expr_for_deprecation(then_branch, info, out);
            if let Some(eb) = else_branch {
                walk_expr_for_deprecation(eb, info, out);
            }
        }
        Expr::While { cond, body, .. } | Expr::DoWhile { cond, body: Some(body), .. } => {
            walk_expr_for_deprecation(cond, info, out);
            walk_expr_for_deprecation(body, info, out);
        }
        Expr::DoWhile { cond, body: None, .. } => {
            walk_expr_for_deprecation(cond, info, out);
        }
        Expr::For { iter, body, .. } => {
            walk_expr_for_deprecation(iter, info, out);
            walk_expr_for_deprecation(body, info, out);
        }
        Expr::When { subject, branches, .. } => {
            if let Some(s) = subject {
                walk_expr_for_deprecation(s, info, out);
            }
            for br in branches {
                for p in &br.patterns {
                    match &p.kind {
                        WhenPatternKind::Value(e)
                        | WhenPatternKind::InRange(e)
                        | WhenPatternKind::NotInRange(e) => {
                            walk_expr_for_deprecation(e, info, out);
                        }
                        _ => {}
                    }
                }
                walk_expr_for_deprecation(&br.body, info, out);
            }
        }
        Expr::Try { body, catches, finally, .. } => {
            walk_block_for_deprecation(body, info, out);
            for c in catches {
                walk_block_for_deprecation(&c.body, info, out);
            }
            if let Some(f) = finally {
                walk_block_for_deprecation(f, info, out);
            }
        }
        Expr::Throw { value, .. } => walk_expr_for_deprecation(value, info, out),
        Expr::Block(b) => walk_block_for_deprecation(b, info, out),
        Expr::Lambda { body, .. } => walk_block_for_deprecation(body, info, out),
        Expr::AnonFun { body, .. } => {
            if let Some(b) = body {
                match b.as_ref() {
                    FunctionBody::Expr(e) => walk_expr_for_deprecation(e, info, out),
                    FunctionBody::Block(blk) => walk_block_for_deprecation(blk, info, out),
                }
            }
        }
        Expr::ObjectExpr { members, supertype_args, supertype_delegates, .. } => {
            for m in members {
                walk_decl_for_deprecation(m, info, out);
            }
            for args in supertype_args.iter().flatten() {
                for a in args {
                    walk_expr_for_deprecation(a, info, out);
                }
            }
            for d in supertype_delegates.iter().flatten() {
                walk_expr_for_deprecation(d, info, out);
            }
        }
        Expr::StringTemplate { parts, .. } => {
            for p in parts {
                if let StringPart::Interp(inner) = p {
                    walk_expr_for_deprecation(inner, info, out);
                }
            }
        }
        _ => {}
    }
}

pub(crate) fn emit_deprecation_at(
    name: &str,
    span: Span,
    info: &HashMap<String, DeprecationInfo>,
    out: &mut Vec<Diagnostic>,
) {
    let Some(d) = info.get(name) else { return };
    let suffix = match &d.message {
        Some(m) if !m.is_empty() => format!(": {m}"),
        _ => String::new(),
    };
    let body = format!("`{name}` is deprecated{suffix}");
    match d.level {
        DeprecationLevel::Warning => {
            out.push(
                Diagnostic::warning(body, span).with_code(codes::WARN_DEPRECATED),
            );
        }
        DeprecationLevel::Error | DeprecationLevel::Hidden => {
            out.push(Diagnostic::error(body, span).with_code(codes::TYPE_DEPRECATED_ERROR));
        }
    }
}

/// Spec §17.3 annotation target kinds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum AnnotationTarget {
    Class,
    AnnotationClass,
    TypeParameter,
    Property,
    Field,
    LocalVariable,
    ValueParameter,
    Constructor,
    Function,
    PropertyGetter,
    PropertySetter,
    Type,
    Expression,
    File,
    TypeAlias,
}

impl AnnotationTarget {
    pub(crate) fn from_name(name: &str) -> Option<Self> {
        Some(match name {
            "CLASS" => Self::Class,
            "ANNOTATION_CLASS" => Self::AnnotationClass,
            "TYPE_PARAMETER" => Self::TypeParameter,
            "PROPERTY" => Self::Property,
            "FIELD" => Self::Field,
            "LOCAL_VARIABLE" => Self::LocalVariable,
            "VALUE_PARAMETER" => Self::ValueParameter,
            "CONSTRUCTOR" => Self::Constructor,
            "FUNCTION" => Self::Function,
            "PROPERTY_GETTER" => Self::PropertyGetter,
            "PROPERTY_SETTER" => Self::PropertySetter,
            "TYPE" => Self::Type,
            "EXPRESSION" => Self::Expression,
            "FILE" => Self::File,
            "TYPEALIAS" => Self::TypeAlias,
            _ => return None,
        })
    }

    pub(crate) fn display(self) -> &'static str {
        match self {
            Self::Class => "CLASS",
            Self::AnnotationClass => "ANNOTATION_CLASS",
            Self::TypeParameter => "TYPE_PARAMETER",
            Self::Property => "PROPERTY",
            Self::Field => "FIELD",
            Self::LocalVariable => "LOCAL_VARIABLE",
            Self::ValueParameter => "VALUE_PARAMETER",
            Self::Constructor => "CONSTRUCTOR",
            Self::Function => "FUNCTION",
            Self::PropertyGetter => "PROPERTY_GETTER",
            Self::PropertySetter => "PROPERTY_SETTER",
            Self::Type => "TYPE",
            Self::Expression => "EXPRESSION",
            Self::File => "FILE",
            Self::TypeAlias => "TYPEALIAS",
        }
    }
}

#[derive(Debug, Clone, Default)]
pub(crate) struct AnnotationMeta {
    /// `@Repeatable` set on the annotation class.
    pub(crate) repeatable: bool,
    /// `@Target(...)` set on the annotation class. `None` means no
    /// explicit `@Target` — application sites are not restricted.
    pub(crate) targets: Option<Vec<AnnotationTarget>>,
}

pub(crate) fn extract_annotation_targets(e: &Expr, out: &mut Vec<AnnotationTarget>) {
    match e {
        Expr::Path { segments, .. } => {
            if let Some(seg) = segments.last()
                && let Some(t) = AnnotationTarget::from_name(&seg.name) {
                    out.push(t);
                }
        }
        Expr::Member { name, .. } => {
            if let Some(t) = AnnotationTarget::from_name(&name.name) {
                out.push(t);
            }
        }
        _ => {}
    }
}

pub(crate) struct AnnotationWalker<'a, 'r> {
    pub(crate) ch: &'a mut Checker<'r>,
    pub(crate) meta: &'a HashMap<String, AnnotationMeta>,
}

impl AnnotationWalker<'_, '_> {
    pub(crate) fn walk_file(&mut self, file: &KotlinFile) {
        self.check_set(&[], AnnotationTarget::File);
        for d in &file.decls {
            self.walk_decl(d);
        }
    }

    pub(crate) fn walk_decl(&mut self, d: &Decl) {
        match d {
            Decl::Function(f) => self.walk_function(f),
            Decl::Property(p) => self.walk_property(p, /*local=*/ false),
            Decl::Class(c) => self.walk_class(c),
            Decl::Object(o) => {
                for m in &o.members {
                    self.walk_decl(m);
                }
            }
            Decl::TypeAlias(a) => {
                self.check_set(&a.annotations, AnnotationTarget::TypeAlias);
            }
        }
    }

    pub(crate) fn walk_function(&mut self, f: &Function) {
        self.check_set(&f.annotations, AnnotationTarget::Function);
        for tp in &f.type_params {
            self.check_set(&tp.annotations, AnnotationTarget::TypeParameter);
        }
        for p in &f.params {
            self.check_set(&p.annotations, AnnotationTarget::ValueParameter);
        }
    }

    pub(crate) fn walk_property(&mut self, p: &Property, local: bool) {
        let site = if local {
            AnnotationTarget::LocalVariable
        } else {
            AnnotationTarget::Property
        };
        self.check_set(&p.annotations, site);
        if let Some(g) = &p.getter {
            self.check_set(&g.annotations, AnnotationTarget::PropertyGetter);
        }
        if let Some(s) = &p.setter {
            self.check_set(&s.annotations, AnnotationTarget::PropertySetter);
        }
    }

    pub(crate) fn walk_class(&mut self, c: &Class) {
        let site = if c.is_annotation {
            AnnotationTarget::AnnotationClass
        } else {
            AnnotationTarget::Class
        };
        self.check_set(&c.annotations, site);
        for tp in &c.type_params {
            self.check_set(&tp.annotations, AnnotationTarget::TypeParameter);
        }
        for p in &c.primary_params {
            self.check_set(&p.annotations, AnnotationTarget::ValueParameter);
        }
        for sc in &c.secondary_ctors {
            self.check_set(&sc.annotations, AnnotationTarget::Constructor);
            for p in &sc.params {
                self.check_set(&p.annotations, AnnotationTarget::ValueParameter);
            }
        }
        for e in &c.enum_entries {
            self.check_set(&e.annotations, AnnotationTarget::Property);
        }
        for m in &c.members {
            self.walk_decl(m);
        }
    }

    pub(crate) fn check_set(&mut self, anns: &[klio_ast::Annotation], site: AnnotationTarget) {
        use std::collections::HashMap as Map;
        let mut counts: Map<String, (Span, &klio_ast::Annotation)> = Map::new();
        for a in anns {
            let leaf = match a.path.last() {
                Some(s) => s.name.clone(),
                None => continue,
            };
            // §17.3 @Target check — only when we know the annotation
            // class and it carries a @Target list.
            if let Some(m) = self.meta.get(&leaf)
                && let Some(targets) = &m.targets
                    && !targets.contains(&site) {
                        self.ch.diagnostics.emit(
                            Diagnostic::error(
                                format!(
                                    "annotation `@{}` cannot be applied to {} — declared @Target list is {{{}}}",
                                    leaf,
                                    site.display(),
                                    targets
                                        .iter()
                                        .map(|t| t.display())
                                        .collect::<Vec<_>>()
                                        .join(", ")
                                ),
                                a.span,
                            )
                            .with_code(codes::TYPE_ANNOTATION_TARGET_MISMATCH),
                        );
                    }
            // §17.4 duplicate detection — only when the annotation class
            // is known to be non-repeatable (it lives in `self.meta` and
            // its `repeatable` flag is `false`).
            if let Some((prev_span, _)) = counts.get(&leaf) {
                if let Some(m) = self.meta.get(&leaf)
                    && !m.repeatable {
                        self.ch.diagnostics.emit(
                            Diagnostic::error(
                                format!(
                                    "annotation `@{leaf}` is not repeatable but is applied more than once"
                                ),
                                a.span,
                            )
                            .with_code(codes::TYPE_ANNOTATION_NOT_REPEATABLE)
                            .with_label(*prev_span, "previously applied here"),
                        );
                    }
            } else {
                counts.insert(leaf, (a.span, a));
            }
        }
    }
}

pub(crate) fn collect_annotation_classes<'a>(decls: &'a [Decl], out: &mut Vec<&'a Class>) {
    for d in decls {
        if let Decl::Class(c) = d {
            if c.is_annotation {
                out.push(c);
            }
            collect_annotation_classes(&c.members, out);
        }
    }
}

pub(crate) fn collect_all_classes<'a>(decls: &'a [Decl], out: &mut Vec<&'a Class>) {
    for d in decls {
        if let Decl::Class(c) = d {
            out.push(c);
            collect_all_classes(&c.members, out);
        }
    }
}

pub(crate) fn annotation_simple_name(a: &klio_ast::Annotation) -> String {
    a.path.last().map(|s| s.name.clone()).unwrap_or_default()
}

pub(crate) fn collect_enum_classes<'a>(decls: &'a [Decl], out: &mut Vec<&'a Class>) {
    for d in decls {
        if let Decl::Class(c) = d {
            if c.is_enum {
                out.push(c);
            }
            collect_enum_classes(&c.members, out);
        }
    }
}

pub(crate) fn annotation_reaches_self(
    start: &str,
    current: &str,
    deps: &HashMap<String, Vec<String>>,
    seen: &mut HashSet<String>,
) -> bool {
    if !seen.insert(current.to_string()) {
        return false;
    }
    let Some(targets) = deps.get(current) else {
        return false;
    };
    for t in targets {
        if t == start {
            return true;
        }
        if annotation_reaches_self(start, t, deps, seen) {
            return true;
        }
    }
    false
}

pub(crate) fn is_annotation_param_type(name: &str) -> bool {
    is_primitive_type_name(name)
        || matches!(
            name,
            "String" | "KClass" | "kotlin.reflect.KClass" | "Array"
        )
}
