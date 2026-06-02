use super::{
    Accessor, AnnotationMeta, AnnotationTarget, AnnotationWalker, BinOp, Block, Checker, Class,
    Decl, DeprecationInfo, Diagnostic, DiagnosticSink, Expr, Frame, Function, FunctionBody,
    HashMap, HashSet, KotlinFile, OptInMarker, Param, PhaseFScope, Property, Resolution, Span,
    Stmt, StringPart, Type, TypeRef, UnOp, Visibility, WhenPatternKind, accessor_uses_field,
    annotation_reaches_self, annotation_simple_name, codes, collect_aliased_names,
    collect_all_classes, collect_annotation_classes, collect_deprecation_diagnostics,
    collect_deprecation_info, collect_enum_classes, collect_opt_in_diagnostics,
    collect_property_reads, collect_required_opt_ins, extract_annotation_targets,
    is_annotation_param_type, is_const_capable_type_name, parse_requires_opt_in,
    tailrec_collect_all_block, tailrec_collect_all_expr, tailrec_walk_block, tailrec_walk_expr,
    type_ref_uses,
};

impl<'a> Checker<'a> {
    pub(crate) fn new(resolution: &'a Resolution) -> Self {
        Self {
            resolution,
            types: HashMap::new(),
            expr_class: HashMap::new(),
            list_elem: HashMap::new(),
            diagnostics: DiagnosticSink::new(),
            frames: vec![Frame::default()],
            fns: HashMap::new(),
            extensions: HashMap::new(),
            extension_properties: HashMap::new(),
            classes: HashMap::new(),
            class_stack: Vec::new(),
            fn_return_stack: Vec::new(),
            label_stack: Vec::new(),
            fn_visibility: HashMap::new(),
            prop_visibility: HashMap::new(),
            setter_visibility: HashMap::new(),
            aliases: HashMap::new(),
            public_inline_stack: Vec::new(),
            suspend_context_stack: Vec::new(),
            reified_type_params: Vec::new(),
            type_params_in_scope: Vec::new(),
            fn_annotations: HashMap::new(),
            prop_annotations: HashMap::new(),
            annotation_class_names: HashSet::new(),
            enum_class_names: HashSet::new(),
            dsl_marker_annotations: HashSet::new(),
            dsl_class_markers: HashMap::new(),
            dsl_receiver_stack: Vec::new(),
            cfgs: HashMap::new(),
            lowerings: HashMap::new(),
            cfg_fn_stack: Vec::new(),
            inference_session: None,
            builder_inference_active: false,
        }
    }

    pub(crate) fn run(&mut self, file: &KotlinFile) {
        // First pass: seed signatures of top-level functions, classes and
        // top-level property types so forward references in bodies typecheck.
        for d in &file.decls {
            self.declare_top_level(d);
        }
        // §17.5.9: collect dsl-marker annotation classes and the user
        // classes that carry them so per-body DSL-scope diagnostics can
        // consult them as the lambda-receiver stack is pushed.
        {
            let mut all_classes: Vec<&Class> = Vec::new();
            collect_all_classes(&file.decls, &mut all_classes);
            for c in &all_classes {
                if !c.is_annotation {
                    continue;
                }
                for a in &c.annotations {
                    if annotation_simple_name(a) == "DslMarker" {
                        self.dsl_marker_annotations.insert(c.name.name.clone());
                        break;
                    }
                }
            }
            for c in &all_classes {
                if c.is_annotation {
                    continue;
                }
                let mut markers: HashSet<String> = HashSet::new();
                for a in &c.annotations {
                    let nm = annotation_simple_name(a);
                    if self.dsl_marker_annotations.contains(&nm) {
                        markers.insert(nm);
                    }
                }
                if !markers.is_empty() {
                    self.dsl_class_markers.insert(c.name.name.clone(), markers);
                }
            }
        }
        // Second pass: typecheck bodies.
        for d in &file.decls {
            self.check_decl(d);
        }
        // Generics-related diagnostics (reified/inline, vararg, declaration-site variance).
        for d in &file.decls {
            self.check_generics_decl(d);
        }
        // T0027: definitely-non-nullable (`T & Any`) used outside a type parameter.
        let mut tp_scope: Vec<HashSet<String>> = vec![HashSet::new()];
        for d in &file.decls {
            self.check_definitely_non_null_decl(d, &mut tp_scope);
        }
        // Phase F: `const val`, `value class`, `annotation class` shape checks.
        // Pre-seed the annotation- and enum-class name sets so the
        // annotation-class parameter-type check (T0037) can recognise other
        // annotation types and enums per spec §17.1.
        {
            let mut anns: Vec<&Class> = Vec::new();
            collect_annotation_classes(&file.decls, &mut anns);
            for c in anns {
                self.annotation_class_names.insert(c.name.name.clone());
            }
            let mut enums: Vec<&Class> = Vec::new();
            collect_enum_classes(&file.decls, &mut enums);
            for c in enums {
                self.enum_class_names.insert(c.name.name.clone());
            }
        }
        for d in &file.decls {
            self.check_phase_f_decl(d, PhaseFScope::TopLevel);
        }
        // Phase G: typealias scope + cycle checks.
        for d in &file.decls {
            self.check_phase_g_decl(d, /*at_top_level=*/ true);
        }
        self.check_typealias_cycles();
        // Phase H: extension property shape checks.
        for d in &file.decls {
            self.check_phase_h_decl(d);
        }
        // Phase J: data object, backing-field, spread, @PublishedApi.
        for d in &file.decls {
            self.check_phase_j_decl(d, /*in_accessor=*/ false);
        }
        // §17.1: annotation-class self-reference cycle detection.
        self.check_annotation_cycles(file);
        // §17.3 / §17.4: annotation @Target / @Repeatable enforcement.
        self.check_annotation_applications(file);
        // §17.5.5: emit deprecation warning/error at every reference to a
        // declaration marked `@Deprecated`.
        self.check_deprecated_references(file);
        // §17.5.4: opt-in propagation for declarations marked with an
        // annotation that itself carries `@RequiresOptIn`.
        self.check_opt_in_references(file);
        // Phase K: `tailrec` tail-call analysis.
        for d in &file.decls {
            self.check_phase_k_decl(d);
        }
        // §11.8: declaration-site conflicting-overload detection.
        self.check_conflicting_overloads();
        // T0076: top-level property initializer cycles (spec §6).
        self.check_property_initializer_cycles(file);
        // T0075: non-property primary-ctor param read from method body.
        for d in &file.decls {
            self.check_ctor_param_scope_decl(d);
        }
    }

    pub(crate) fn check_ctor_param_scope_decl(&mut self, d: &Decl) {
        match d {
            Decl::Class(c) => {
                // Names visible as members of this class — own members and
                // transitively inherited supertype members / properties — are
                // shadowed by their member binding rather than the ctor
                // param. Skip those names when computing the non-property set.
                let member_names = self.collect_member_name_set(c);
                let non_prop: std::collections::HashMap<String, Span> = c
                    .primary_params
                    .iter()
                    .filter(|p| p.property.is_none() && !member_names.contains(&p.name.name))
                    .map(|p| (p.name.name.clone(), p.name.span))
                    .collect();
                if !non_prop.is_empty() {
                    for m in &c.members {
                        match m {
                            Decl::Function(f) => {
                                if let Some(body) = &f.body {
                                    let mut local: std::collections::HashSet<String> =
                                        f.params.iter().map(|p| p.name.name.clone()).collect();
                                    self.check_ctor_param_in_body(body, &non_prop, &mut local);
                                }
                            }
                            Decl::Property(p) => {
                                // Property initializers run during instance
                                // init — non-property ctor params are visible
                                // there. Accessor bodies, however, are
                                // invoked post-construction and must not see
                                // them.
                                if let Some(getter) = &p.getter {
                                    let mut local = std::collections::HashSet::new();
                                    self.check_ctor_param_in_body(
                                        &getter.body,
                                        &non_prop,
                                        &mut local,
                                    );
                                }
                                if let Some(setter) = &p.setter {
                                    let mut local: std::collections::HashSet<String> =
                                        setter.params.iter().map(|i| i.name.clone()).collect();
                                    self.check_ctor_param_in_body(
                                        &setter.body,
                                        &non_prop,
                                        &mut local,
                                    );
                                }
                            }
                            _ => {}
                        }
                    }
                }
                for m in &c.members {
                    self.check_ctor_param_scope_decl(m);
                }
            }
            Decl::Object(o) => {
                for m in &o.members {
                    self.check_ctor_param_scope_decl(m);
                }
            }
            _ => {}
        }
    }

    /// Names that resolve as class members at any point in the class's
    /// inheritance chain — own properties / functions / property-form ctor
    /// params, plus transitively inherited equivalents via `self.classes`.
    pub(crate) fn collect_member_name_set(&self, c: &Class) -> std::collections::HashSet<String> {
        let mut out = std::collections::HashSet::new();
        for p in &c.primary_params {
            if p.property.is_some() {
                out.insert(p.name.name.clone());
            }
        }
        for m in &c.members {
            match m {
                Decl::Function(f) => {
                    out.insert(f.name.name.clone());
                }
                Decl::Property(p) => {
                    out.insert(p.name.name.clone());
                }
                _ => {}
            }
        }
        for s in &c.supertypes {
            if let Some(info) = self.classes.get(&s.name.name) {
                for k in info.members.keys() {
                    out.insert(k.clone());
                }
            }
        }
        out
    }

    pub(crate) fn check_ctor_param_in_body(
        &mut self,
        body: &FunctionBody,
        non_prop: &std::collections::HashMap<String, Span>,
        local: &mut std::collections::HashSet<String>,
    ) {
        match body {
            FunctionBody::Block(b) => self.check_ctor_param_in_block(b, non_prop, local),
            FunctionBody::Expr(e) => self.check_ctor_param_in_expr(e, non_prop, local),
        }
    }

    pub(crate) fn check_ctor_param_in_block(
        &mut self,
        b: &Block,
        non_prop: &std::collections::HashMap<String, Span>,
        local: &mut std::collections::HashSet<String>,
    ) {
        for s in &b.stmts {
            match s {
                Stmt::Expr(e) => self.check_ctor_param_in_expr(e, non_prop, local),
                Stmt::Assign { target, value, .. } => {
                    self.check_ctor_param_in_expr(target, non_prop, local);
                    self.check_ctor_param_in_expr(value, non_prop, local);
                }
                Stmt::Decl(Decl::Property(p)) => {
                    if let Some(init) = &p.init {
                        self.check_ctor_param_in_expr(init, non_prop, local);
                    }
                    local.insert(p.name.name.clone());
                }
                Stmt::Decl(Decl::Function(f)) => {
                    local.insert(f.name.name.clone());
                }
                Stmt::DestructuringDecl { names, init, .. } => {
                    self.check_ctor_param_in_expr(init, non_prop, local);
                    for n in names {
                        if n.name != "_" {
                            local.insert(n.name.clone());
                        }
                    }
                }
                Stmt::Decl(_) => {}
            }
        }
    }

    fn emit_ctor_param_out_of_scope(&mut self, name: &str, span: Span) {
        self.diagnostics.emit(
            Diagnostic::error(
                format!(
                    "`{name}` is a primary-constructor parameter (not a `val`/`var`) and is not in scope here; declare it as `val {name}` to promote it to a property"
                ),
                span,
            )
            .with_code(codes::TYPE_NON_PROPERTY_CTOR_PARAM_OUT_OF_SCOPE),
        );
    }

    pub(crate) fn check_ctor_param_in_expr(
        &mut self,
        e: &Expr,
        non_prop: &std::collections::HashMap<String, Span>,
        local: &mut std::collections::HashSet<String>,
    ) {
        match e {
            Expr::Path { segments, .. } => {
                if let Some(first) = segments.first()
                    && segments.len() == 1
                    && !local.contains(&first.name)
                    && non_prop.contains_key(&first.name)
                {
                    self.emit_ctor_param_out_of_scope(&first.name, first.span);
                }
            }
            Expr::Call { callee, args, .. } => {
                self.check_ctor_param_in_expr(callee, non_prop, local);
                for a in args {
                    self.check_ctor_param_in_expr(a, non_prop, local);
                }
            }
            Expr::Index { receiver, args, .. } => {
                self.check_ctor_param_in_expr(receiver, non_prop, local);
                for a in args {
                    self.check_ctor_param_in_expr(a, non_prop, local);
                }
            }
            Expr::Binary { lhs, rhs, .. } => {
                self.check_ctor_param_in_expr(lhs, non_prop, local);
                self.check_ctor_param_in_expr(rhs, non_prop, local);
            }
            Expr::If {
                cond,
                then_branch,
                else_branch,
                ..
            } => {
                self.check_ctor_param_in_expr(cond, non_prop, local);
                self.check_ctor_param_in_expr(then_branch, non_prop, local);
                if let Some(eb) = else_branch {
                    self.check_ctor_param_in_expr(eb, non_prop, local);
                }
            }
            Expr::While { cond, body, .. } => {
                self.check_ctor_param_in_expr(cond, non_prop, local);
                self.check_ctor_param_in_expr(body, non_prop, local);
            }
            Expr::DoWhile { body, cond, .. } => {
                if let Some(b) = body {
                    self.check_ctor_param_in_expr(b, non_prop, local);
                }
                self.check_ctor_param_in_expr(cond, non_prop, local);
            }
            Expr::For {
                iter, body, vars, ..
            } => {
                self.check_ctor_param_in_expr(iter, non_prop, local);
                let mut inner = local.clone();
                inner.extend(vars.iter().map(|v| v.name.clone()));
                self.check_ctor_param_in_expr(body, non_prop, &mut inner);
            }
            Expr::Block(b) => self.check_ctor_param_in_block(b, non_prop, local),
            Expr::Member {
                receiver: inner, ..
            }
            | Expr::Unary { expr: inner, .. }
            | Expr::Postfix { expr: inner, .. }
            | Expr::Labeled { expr: inner, .. }
            | Expr::Return {
                value: Some(inner), ..
            }
            | Expr::Throw { value: inner, .. }
            | Expr::IsCheck { expr: inner, .. }
            | Expr::As { expr: inner, .. }
            | Expr::Spread { expr: inner, .. } => {
                self.check_ctor_param_in_expr(inner, non_prop, local);
            }
            Expr::StringTemplate { parts, .. } => {
                for part in parts {
                    match part {
                        klio_ast::StringPart::ShortInterp(id) => {
                            if !local.contains(&id.name) && non_prop.contains_key(&id.name) {
                                self.emit_ctor_param_out_of_scope(&id.name, id.span);
                            }
                        }
                        klio_ast::StringPart::Interp(e) => {
                            self.check_ctor_param_in_expr(e, non_prop, local);
                        }
                        klio_ast::StringPart::Text(_) => {}
                    }
                }
            }
            Expr::Lambda { params, body, .. } => {
                let mut inner = local.clone();
                inner.extend(params.iter().map(|p| p.name.clone()));
                self.check_ctor_param_in_block(body, non_prop, &mut inner);
            }
            Expr::When {
                subject, branches, ..
            } => {
                if let Some(s) = subject {
                    self.check_ctor_param_in_expr(s, non_prop, local);
                }
                for b in branches {
                    self.check_ctor_param_in_when_branch(b, non_prop, local);
                }
            }
            Expr::Try {
                body,
                catches,
                finally,
                ..
            } => {
                self.check_ctor_param_in_try(body, catches, finally.as_ref(), non_prop, local);
            }
            _ => {}
        }
    }

    fn check_ctor_param_in_when_branch(
        &mut self,
        b: &klio_ast::WhenBranch,
        non_prop: &std::collections::HashMap<String, Span>,
        local: &mut std::collections::HashSet<String>,
    ) {
        for p in &b.patterns {
            match &p.kind {
                klio_ast::WhenPatternKind::Value(e)
                | klio_ast::WhenPatternKind::InRange(e)
                | klio_ast::WhenPatternKind::NotInRange(e) => {
                    self.check_ctor_param_in_expr(e, non_prop, local);
                }
                _ => {}
            }
        }
        self.check_ctor_param_in_expr(&b.body, non_prop, local);
    }

    fn check_ctor_param_in_try(
        &mut self,
        body: &Block,
        catches: &[klio_ast::Catch],
        finally: Option<&Block>,
        non_prop: &std::collections::HashMap<String, Span>,
        local: &mut std::collections::HashSet<String>,
    ) {
        self.check_ctor_param_in_block(body, non_prop, local);
        for c in catches {
            let mut inner = local.clone();
            inner.insert(c.binding.name.clone());
            self.check_ctor_param_in_block(&c.body, non_prop, &mut inner);
        }
        if let Some(fb) = finally {
            self.check_ctor_param_in_block(fb, non_prop, local);
        }
    }

    /// Detect cycles among top-level property initializer reads. A property
    /// whose initializer reads another property — directly or transitively
    /// back to itself — forms a cycle whose evaluation order is unspecified.
    pub(crate) fn check_property_initializer_cycles(&mut self, file: &KotlinFile) {
        use std::collections::{HashMap, HashSet};

        let mut props: Vec<(&Property, usize)> = Vec::new();
        let mut by_name: HashMap<String, usize> = HashMap::new();
        for d in &file.decls {
            if let Decl::Property(p) = d
                && p.init.is_some()
            {
                let idx = props.len();
                by_name.insert(p.name.name.clone(), idx);
                props.push((p, idx));
            }
        }
        if props.is_empty() {
            return;
        }

        let mut edges: Vec<Vec<usize>> = vec![Vec::new(); props.len()];
        for (p, idx) in &props {
            let init = p.init.as_ref().unwrap();
            let mut reads: HashSet<usize> = HashSet::new();
            collect_property_reads(init, &by_name, &mut reads);
            edges[*idx] = reads.into_iter().collect();
        }

        let sccs = tarjan_sccs(&edges);
        for comp in &sccs {
            let is_cycle = comp.len() > 1 || edges[comp[0]].contains(&comp[0]);
            if !is_cycle {
                continue;
            }
            let names: Vec<String> = comp.iter().map(|&i| props[i].0.name.name.clone()).collect();
            let chain = names.join(" -> ");
            for &i in comp {
                let p = props[i].0;
                self.diagnostics.emit(
                    Diagnostic::warning(
                        format!(
                            "Property `{}` participates in an initializer cycle: {}",
                            p.name.name, chain
                        ),
                        p.init.as_ref().unwrap().span(),
                    )
                    .with_code(codes::TYPE_PROPERTY_INITIALIZER_CYCLE),
                );
            }
        }
    }

    pub(crate) fn check_phase_k_decl(&mut self, d: &Decl) {
        match d {
            Decl::Function(f) => self.check_tailrec_function(f),
            Decl::Class(c) => {
                for m in &c.members {
                    self.check_phase_k_decl(m);
                }
            }
            Decl::Object(o) => {
                for m in &o.members {
                    self.check_phase_k_decl(m);
                }
            }
            Decl::Property(_) | Decl::TypeAlias(_) => {}
        }
    }

    pub(crate) fn check_tailrec_function(&mut self, f: &Function) {
        if !f.is_tailrec {
            return;
        }
        if f.is_open || f.is_override {
            self.diagnostics.emit(
                Diagnostic::warning(
                    "tailrec is redundant on an open or override function — virtual dispatch defeats the rewrite"
                        .to_string(),
                    f.name.span,
                )
                .with_code(codes::TYPE_TAILREC_ON_OPEN),
            );
        }
        let Some(body) = &f.body else {
            return;
        };
        let mut tail_sites = std::collections::HashSet::new();
        let mut all_sites: Vec<Span> = Vec::new();
        match body {
            FunctionBody::Block(b) => {
                tailrec_walk_block(b, true, &f.name.name, &mut tail_sites);
                tailrec_collect_all_block(b, &f.name.name, &mut all_sites);
            }
            FunctionBody::Expr(e) => {
                tailrec_walk_expr(e, true, &f.name.name, &mut tail_sites);
                tailrec_collect_all_expr(e, &f.name.name, &mut all_sites);
            }
        }
        if tail_sites.is_empty() {
            self.diagnostics.emit(
                Diagnostic::warning(
                    "a function is marked `tailrec` but no tail calls are found".to_string(),
                    f.name.span,
                )
                .with_code(codes::TYPE_NO_TAIL_CALLS_FOUND),
            );
        }
        for sp in &all_sites {
            if !tail_sites.contains(sp) {
                self.diagnostics.emit(
                    Diagnostic::warning(
                        format!("recursive call to `{}` is not a tail call", f.name.name),
                        *sp,
                    )
                    .with_code(codes::TYPE_NON_TAIL_RECURSIVE_CALL),
                );
            }
        }
    }

    pub(crate) fn check_phase_f_decl(&mut self, d: &Decl, scope: PhaseFScope) {
        match d {
            Decl::Property(p) => {
                if p.is_const {
                    self.check_const_val(p, scope);
                }
                if p.is_inline {
                    self.check_inline_property(p);
                }
                // Spec §4.3.4: a property without a backing field cannot
                // declare an initializer. Skip extension properties (T0040
                // already covers that case) and abstract properties.
                if p.init.is_some()
                    && !p.is_abstract
                    && p.receiver_type.is_none()
                    && !Self::property_has_backing_field(p)
                {
                    self.diagnostics.emit(
                        Diagnostic::error(
                            format!(
                                "property `{}` has custom accessors that don't use `field`, so it \
                                 has no backing field — initializer is not allowed",
                                p.name.name
                            ),
                            p.name.span,
                        )
                        .with_code(codes::TYPE_PROPERTY_NO_BACKING_FIELD_HAS_INITIALIZER),
                    );
                }
            }
            Decl::Class(c) => {
                if c.is_value {
                    self.check_value_class(c);
                }
                if c.is_annotation {
                    self.check_annotation_class(c);
                }
                let member_scope = if c.is_companion || matches!(scope, PhaseFScope::Object) {
                    PhaseFScope::Object
                } else {
                    PhaseFScope::Class
                };
                for m in &c.members {
                    self.check_phase_f_decl(m, member_scope);
                }
            }
            Decl::Object(o) => {
                for m in &o.members {
                    self.check_phase_f_decl(m, PhaseFScope::Object);
                }
            }
            Decl::Function(_) | Decl::TypeAlias(_) => {}
        }
    }

    pub(crate) fn check_phase_h_decl(&mut self, d: &Decl) {
        match d {
            Decl::Property(p) => {
                if p.receiver_type.is_none() {
                    return;
                }
                if p.init.is_some() {
                    self.diagnostics.emit(
                        Diagnostic::error(
                            format!(
                                "extension property `{}` cannot have an initializer; no backing field is allowed",
                                p.name.name
                            ),
                            p.name.span,
                        )
                        .with_code(codes::TYPE_EXTENSION_PROPERTY_HAS_INITIALIZER),
                    );
                }
                if p.delegate.is_some() {
                    self.diagnostics.emit(
                        Diagnostic::error(
                            format!(
                                "extension property `{}` cannot be declared with a `by` delegate",
                                p.name.name
                            ),
                            p.name.span,
                        )
                        .with_code(codes::TYPE_EXTENSION_PROPERTY_HAS_DELEGATE),
                    );
                }
                let need_setter = p.mutable;
                let getter_absent = p.getter.is_none();
                let setter_absent = need_setter && p.setter.is_none();
                // An `expect` extension property is a declaration
                // with no body; its accessors come from the `actual`.
                if (getter_absent || setter_absent)
                    && p.init.is_none()
                    && p.delegate.is_none()
                    && !p.is_expect
                {
                    let what = if getter_absent && setter_absent {
                        "explicit getter and setter"
                    } else if getter_absent {
                        "explicit getter"
                    } else {
                        "explicit setter"
                    };
                    self.diagnostics.emit(
                        Diagnostic::error(
                            format!("extension property `{}` requires {what}", p.name.name),
                            p.name.span,
                        )
                        .with_code(codes::TYPE_EXTENSION_PROPERTY_NEEDS_ACCESSOR),
                    );
                }
                if p.is_lateinit {
                    self.diagnostics.emit(
                        Diagnostic::error(
                            format!("extension property `{}` cannot be `lateinit`", p.name.name),
                            p.name.span,
                        )
                        .with_code(codes::TYPE_EXTENSION_PROPERTY_HAS_INITIALIZER),
                    );
                }
            }
            Decl::Class(c) => {
                for m in &c.members {
                    self.check_phase_h_decl(m);
                }
            }
            Decl::Object(o) => {
                for m in &o.members {
                    self.check_phase_h_decl(m);
                }
            }
            _ => {}
        }
    }

    pub(crate) fn check_phase_j_decl(&mut self, d: &Decl, in_accessor: bool) {
        match d {
            Decl::Object(o) => {
                if o.is_data {
                    for m in &o.members {
                        if let Decl::Function(f) = m
                            && (f.name.name == "equals" || f.name.name == "hashCode")
                        {
                            self.diagnostics.emit(
                                Diagnostic::error(
                                    format!(
                                        "`data object {}` cannot override `{}`",
                                        o.name.name, f.name.name
                                    ),
                                    f.name.span,
                                )
                                .with_code(codes::TYPE_DATA_OBJECT_FORBIDS_EQUALS_HASHCODE),
                            );
                        }
                    }
                }
                for m in &o.members {
                    self.check_phase_j_decl(m, false);
                }
            }
            Decl::Class(c) => {
                for m in &c.members {
                    self.check_phase_j_decl(m, false);
                }
            }
            Decl::Property(p) => {
                // Extension properties never have a backing field — any
                // `field` reference inside their accessors is invalid.
                let has_backing_field = p.receiver_type.is_none();
                if let Some(g) = &p.getter {
                    self.walk_accessor_for_phase_j(g, has_backing_field, &p.name.name);
                }
                if let Some(s) = &p.setter {
                    self.walk_accessor_for_phase_j(s, has_backing_field, &p.name.name);
                }
                if let Some(init) = &p.init {
                    self.walk_expr_for_phase_j(init, in_accessor, true, &p.name.name);
                }
            }
            Decl::Function(f) => {
                if let Some(body) = &f.body {
                    match body {
                        FunctionBody::Block(b) => {
                            self.walk_block_for_phase_j(b, in_accessor, false, "")
                        }
                        FunctionBody::Expr(e) => {
                            self.walk_expr_for_phase_j(e, in_accessor, false, "")
                        }
                    }
                }
            }
            Decl::TypeAlias(_) => {}
        }
    }

    pub(crate) fn walk_accessor_for_phase_j(
        &mut self,
        a: &Accessor,
        has_backing_field: bool,
        prop_name: &str,
    ) {
        match &a.body {
            FunctionBody::Block(b) => {
                self.walk_block_for_phase_j(b, true, has_backing_field, prop_name)
            }
            FunctionBody::Expr(e) => {
                self.walk_expr_for_phase_j(e, true, has_backing_field, prop_name)
            }
        }
    }

    pub(crate) fn walk_block_for_phase_j(
        &mut self,
        b: &Block,
        in_accessor: bool,
        has_backing_field: bool,
        prop_name: &str,
    ) {
        for s in &b.stmts {
            match s {
                Stmt::Decl(d) => self.check_phase_j_decl(d, in_accessor),
                Stmt::Expr(e) => {
                    self.walk_expr_for_phase_j(e, in_accessor, has_backing_field, prop_name)
                }
                Stmt::Assign { target, value, .. } => {
                    self.walk_expr_for_phase_j(target, in_accessor, has_backing_field, prop_name);
                    self.walk_expr_for_phase_j(value, in_accessor, has_backing_field, prop_name);
                }
                Stmt::DestructuringDecl { init, .. } => {
                    self.walk_expr_for_phase_j(init, in_accessor, has_backing_field, prop_name);
                }
            }
        }
    }

    fn check_field_reference(
        &mut self,
        span: Span,
        in_accessor: bool,
        has_backing_field: bool,
        prop_name: &str,
    ) {
        if !in_accessor {
            self.diagnostics.emit(
                Diagnostic::error(
                    "`field` can only be referenced inside a property accessor body",
                    span,
                )
                .with_code(codes::TYPE_BACKING_FIELD_OUTSIDE_ACCESSOR),
            );
        } else if !has_backing_field {
            let detail = if prop_name.is_empty() {
                "property has no backing field".to_string()
            } else {
                format!("property `{prop_name}` has no backing field")
            };
            self.diagnostics.emit(
                Diagnostic::error(format!("`field` is not available here: {detail}"), span)
                    .with_code(codes::TYPE_BACKING_FIELD_OUTSIDE_ACCESSOR),
            );
        }
    }

    pub(crate) fn walk_expr_for_phase_j(
        &mut self,
        e: &Expr,
        in_accessor: bool,
        has_backing_field: bool,
        prop_name: &str,
    ) {
        if let Expr::Path { segments, .. } = e
            && segments.len() == 1
            && segments[0].name == "field"
        {
            self.check_field_reference(segments[0].span, in_accessor, has_backing_field, prop_name);
        }
        // Recurse through children that may contain `field` references.
        match e {
            Expr::Block(b) => {
                self.walk_block_for_phase_j(b, in_accessor, has_backing_field, prop_name)
            }
            Expr::If {
                cond,
                then_branch,
                else_branch,
                ..
            } => {
                self.walk_expr_for_phase_j(cond, in_accessor, has_backing_field, prop_name);
                self.walk_expr_for_phase_j(then_branch, in_accessor, has_backing_field, prop_name);
                if let Some(eb) = else_branch {
                    self.walk_expr_for_phase_j(eb, in_accessor, has_backing_field, prop_name);
                }
            }
            Expr::While { cond, body, .. } => {
                self.walk_expr_for_phase_j(cond, in_accessor, has_backing_field, prop_name);
                self.walk_expr_for_phase_j(body, in_accessor, has_backing_field, prop_name);
            }
            Expr::DoWhile { body, cond, .. } => {
                if let Some(b) = body {
                    self.walk_expr_for_phase_j(b, in_accessor, has_backing_field, prop_name);
                }
                self.walk_expr_for_phase_j(cond, in_accessor, has_backing_field, prop_name);
            }
            Expr::For { iter, body, .. } => {
                self.walk_expr_for_phase_j(iter, in_accessor, has_backing_field, prop_name);
                self.walk_expr_for_phase_j(body, in_accessor, has_backing_field, prop_name);
            }
            Expr::Binary { lhs, rhs, .. } => {
                self.walk_expr_for_phase_j(lhs, in_accessor, has_backing_field, prop_name);
                self.walk_expr_for_phase_j(rhs, in_accessor, has_backing_field, prop_name);
            }
            Expr::Call { callee, args, .. } => {
                self.walk_expr_for_phase_j(callee, in_accessor, has_backing_field, prop_name);
                for a in args {
                    self.walk_expr_for_phase_j(a, in_accessor, has_backing_field, prop_name);
                }
            }
            Expr::Index { receiver, args, .. } => {
                self.walk_expr_for_phase_j(receiver, in_accessor, has_backing_field, prop_name);
                for a in args {
                    self.walk_expr_for_phase_j(a, in_accessor, has_backing_field, prop_name);
                }
            }
            Expr::Return {
                value: Some(inner), ..
            }
            | Expr::Unary { expr: inner, .. }
            | Expr::Postfix { expr: inner, .. }
            | Expr::Member {
                receiver: inner, ..
            }
            | Expr::Labeled { expr: inner, .. }
            | Expr::Throw { value: inner, .. }
            | Expr::IsCheck { expr: inner, .. }
            | Expr::As { expr: inner, .. }
            | Expr::Spread { expr: inner, .. } => {
                self.walk_expr_for_phase_j(inner, in_accessor, has_backing_field, prop_name);
            }
            Expr::Try {
                body,
                catches,
                finally,
                ..
            } => {
                self.walk_block_for_phase_j(body, in_accessor, has_backing_field, prop_name);
                for c in catches {
                    self.walk_block_for_phase_j(&c.body, in_accessor, has_backing_field, prop_name);
                }
                if let Some(fb) = finally {
                    self.walk_block_for_phase_j(fb, in_accessor, has_backing_field, prop_name);
                }
            }
            Expr::Lambda { body, .. } => {
                // Lambdas inside accessor bodies still see `field`.
                self.walk_block_for_phase_j(body, in_accessor, has_backing_field, prop_name);
            }
            Expr::When {
                subject, branches, ..
            } => {
                if let Some(s) = subject {
                    self.walk_expr_for_phase_j(s, in_accessor, has_backing_field, prop_name);
                }
                for b in branches {
                    for p in &b.patterns {
                        match &p.kind {
                            WhenPatternKind::Value(e)
                            | WhenPatternKind::InRange(e)
                            | WhenPatternKind::NotInRange(e) => {
                                self.walk_expr_for_phase_j(
                                    e,
                                    in_accessor,
                                    has_backing_field,
                                    prop_name,
                                );
                            }
                            _ => {}
                        }
                    }
                    self.walk_expr_for_phase_j(&b.body, in_accessor, has_backing_field, prop_name);
                }
            }
            Expr::AnonFun { body: Some(b), .. } => match b.as_ref() {
                FunctionBody::Block(blk) => {
                    self.walk_block_for_phase_j(blk, in_accessor, has_backing_field, prop_name)
                }
                FunctionBody::Expr(ex) => {
                    self.walk_expr_for_phase_j(ex, in_accessor, has_backing_field, prop_name)
                }
            },
            Expr::ObjectExpr { members, .. } => {
                for m in members {
                    self.check_phase_j_decl(m, false);
                }
            }
            _ => {}
        }
    }

    pub(crate) fn check_phase_g_decl(&mut self, d: &Decl, at_top_level: bool) {
        match d {
            Decl::TypeAlias(a) => {
                if !at_top_level {
                    self.diagnostics.emit(
                        Diagnostic::error(
                            format!("`typealias {}` is only allowed at top level", a.name.name),
                            a.name.span,
                        )
                        .with_code(codes::TYPE_TYPEALIAS_NOT_TOPLEVEL),
                    );
                }
            }
            Decl::Class(c) => {
                for m in &c.members {
                    self.check_phase_g_decl(m, /*at_top_level=*/ false);
                }
            }
            Decl::Object(o) => {
                for m in &o.members {
                    self.check_phase_g_decl(m, /*at_top_level=*/ false);
                }
            }
            Decl::Function(f) => {
                if let Some(body) = &f.body {
                    match body {
                        FunctionBody::Block(b) => self.walk_block_for_phase_g(b),
                        FunctionBody::Expr(e) => self.walk_expr_for_phase_g(e),
                    }
                }
            }
            Decl::Property(_) => {}
        }
    }

    pub(crate) fn walk_block_for_phase_g(&mut self, b: &Block) {
        for s in &b.stmts {
            match s {
                Stmt::Decl(d) => self.check_phase_g_decl(d, /*at_top_level=*/ false),
                Stmt::Expr(e) => self.walk_expr_for_phase_g(e),
                Stmt::Assign { value, .. } => self.walk_expr_for_phase_g(value),
                Stmt::DestructuringDecl { init, .. } => self.walk_expr_for_phase_g(init),
            }
        }
    }

    pub(crate) fn walk_expr_for_phase_g(&mut self, e: &Expr) {
        match e {
            Expr::Block(b) => self.walk_block_for_phase_g(b),
            Expr::If {
                cond,
                then_branch,
                else_branch,
                ..
            } => {
                self.walk_expr_for_phase_g(cond);
                self.walk_expr_for_phase_g(then_branch);
                if let Some(eb) = else_branch {
                    self.walk_expr_for_phase_g(eb);
                }
            }
            Expr::While { cond, body, .. } => {
                self.walk_expr_for_phase_g(cond);
                self.walk_expr_for_phase_g(body);
            }
            Expr::DoWhile { body, cond, .. } => {
                if let Some(b) = body {
                    self.walk_expr_for_phase_g(b);
                }
                self.walk_expr_for_phase_g(cond);
            }
            Expr::For { iter, body, .. } => {
                self.walk_expr_for_phase_g(iter);
                self.walk_expr_for_phase_g(body);
            }
            Expr::Lambda { body, .. } => self.walk_block_for_phase_g(body),
            Expr::AnonFun { body, .. } => {
                if let Some(b) = body.as_deref() {
                    match b {
                        FunctionBody::Block(blk) => self.walk_block_for_phase_g(blk),
                        FunctionBody::Expr(ex) => self.walk_expr_for_phase_g(ex),
                    }
                }
            }
            Expr::ObjectExpr { members, .. } => {
                for m in members {
                    self.check_phase_g_decl(m, /*at_top_level=*/ false);
                }
            }
            Expr::When {
                subject, branches, ..
            } => {
                if let Some(s) = subject {
                    self.walk_expr_for_phase_g(s);
                }
                for br in branches {
                    self.walk_expr_for_phase_g(&br.body);
                }
            }
            Expr::Labeled { expr, .. } => self.walk_expr_for_phase_g(expr),
            Expr::Try { body, finally, .. } => {
                self.walk_block_for_phase_g(body);
                if let Some(f) = finally {
                    self.walk_block_for_phase_g(f);
                }
            }
            _ => {}
        }
    }

    /// Detect direct / transitive `typealias` cycles. Emits T0038 once per
    /// alias on a cycle.
    pub(crate) fn check_typealias_cycles(&mut self) {
        let names: Vec<String> = self.aliases.keys().cloned().collect();
        for n in names {
            let mut seen: HashSet<String> = HashSet::new();
            if self.alias_reaches_self(&n, &n, &mut seen) {
                let span = self.aliases[&n].name_span;
                self.diagnostics.emit(
                    Diagnostic::error(format!("recursive typealias `{n}` expands to itself"), span)
                        .with_code(codes::TYPE_RECURSIVE_TYPEALIAS),
                );
            }
        }
    }

    pub(crate) fn alias_reaches_self(
        &self,
        start: &str,
        current: &str,
        seen: &mut HashSet<String>,
    ) -> bool {
        let Some(info) = self.aliases.get(current) else {
            return false;
        };
        if !seen.insert(current.to_string()) {
            return false;
        }
        // Walk every aliased name appearing anywhere in the target TypeRef.
        let mut targets: Vec<String> = Vec::new();
        collect_aliased_names(&info.target, &mut targets);
        for t in targets {
            if t == start {
                return true;
            }
            if self.alias_reaches_self(start, &t, seen) {
                return true;
            }
        }
        false
    }

    /// Spec §4.3.4 backing-field rule. A property has a backing field iff:
    ///
    /// * no custom accessors (default get/set);
    /// * any custom accessor body references `field`;
    /// * mutable property with exactly one of get/set custom (the other
    ///   defaults and needs storage).
    ///
    /// Extension properties never have a backing field.
    pub(crate) fn property_has_backing_field(p: &Property) -> bool {
        if p.receiver_type.is_some() {
            return false;
        }
        let getter = p.getter.as_ref();
        let setter = p.setter.as_ref();
        match (getter, setter) {
            (None, None) => true,
            (Some(acc), None) | (None, Some(acc)) => {
                if p.mutable {
                    true
                } else {
                    accessor_uses_field(acc)
                }
            }
            (Some(get), Some(set)) => accessor_uses_field(get) || accessor_uses_field(set),
        }
    }

    /// Spec §4.2.5: inline-param escape detection. Walk the body and at
    /// every bare-name use of an inline / crossinline parameter outside a
    /// `Call.callee` slot, emit T0055/T0056. Conservative: a Path read in
    /// a non-call context counts as an escape. Re-passing the parameter as
    /// a call argument also counts (we cannot tell whether the callee is
    /// itself inline).
    /// Spec §8.23: a non-private function that returns an anonymous
    /// object with multiple declared supertypes (and no explicit return
    /// type annotation) leaks an unnameable type out of its scope.
    /// Single-supertype anonymous objects are implicitly downcast to
    /// their supertype, so they are allowed.
    pub(crate) fn check_anonymous_object_escape(&mut self, f: &Function) {
        if matches!(f.visibility, Visibility::Private) {
            return;
        }
        if f.return_type.is_some() {
            return;
        }
        let Some(body) = &f.body else { return };
        let tail = match body {
            FunctionBody::Expr(e) => e,
            FunctionBody::Block(b) => {
                let Some(last) = b.stmts.last() else { return };
                match last {
                    klio_ast::Stmt::Expr(e) => e,
                    _ => return,
                }
            }
        };
        let Expr::ObjectExpr {
            supertypes, span, ..
        } = tail
        else {
            return;
        };
        if supertypes.len() < 2 {
            return;
        }
        self.diagnostics.emit(
            Diagnostic::error(
                format!(
                    "anonymous object with multiple supertypes escapes from non-private function `{}` — declare an explicit return type",
                    f.name.name
                ),
                *span,
            )
            .with_code(codes::TYPE_ANONYMOUS_OBJECT_ESCAPES_PUBLIC),
        );
    }

    pub(crate) fn check_inline_param_escape(&mut self, f: &Function) {
        if !f.is_inline {
            return;
        }
        // Only function-typed parameters are inlined (or crossinline /
        // noinline). Plain values (`x: Int`) on an inline fun are not
        // affected by §4.2.5.
        let is_fn_typed = |p: &Param| p.ty.function.is_some();
        let inline_params: Vec<String> = f
            .params
            .iter()
            .filter(|p| !p.is_noinline && !p.is_crossinline && is_fn_typed(p))
            .map(|p| p.name.name.clone())
            .collect();
        let crossinline_params: Vec<String> = f
            .params
            .iter()
            .filter(|p| p.is_crossinline && is_fn_typed(p))
            .map(|p| p.name.name.clone())
            .collect();
        if inline_params.is_empty() && crossinline_params.is_empty() {
            return;
        }
        if let Some(body) = &f.body {
            match body {
                FunctionBody::Block(b) => {
                    self.walk_block_for_inline_escape(b, &inline_params, &crossinline_params);
                }
                FunctionBody::Expr(e) => {
                    self.walk_expr_for_inline_escape(e, &inline_params, &crossinline_params, true);
                }
            }
        }
    }

    pub(crate) fn walk_block_for_inline_escape(
        &mut self,
        b: &Block,
        inline_params: &[String],
        crossinline_params: &[String],
    ) {
        for s in &b.stmts {
            match s {
                Stmt::Expr(e) => {
                    self.walk_expr_for_inline_escape(e, inline_params, crossinline_params, false)
                }
                Stmt::Assign { value, .. } => {
                    self.flag_inline_escape(
                        value,
                        inline_params,
                        crossinline_params,
                        "stored in a variable",
                    );
                    self.walk_expr_for_inline_escape(
                        value,
                        inline_params,
                        crossinline_params,
                        false,
                    );
                }
                Stmt::Decl(Decl::Property(p)) => {
                    if let Some(init) = &p.init {
                        self.flag_inline_escape(
                            init,
                            inline_params,
                            crossinline_params,
                            "stored in a variable",
                        );
                        self.walk_expr_for_inline_escape(
                            init,
                            inline_params,
                            crossinline_params,
                            false,
                        );
                    }
                }
                _ => {}
            }
        }
    }

    pub(crate) fn walk_expr_for_inline_escape(
        &mut self,
        e: &Expr,
        inline_params: &[String],
        crossinline_params: &[String],
        is_callee: bool,
    ) {
        match e {
            Expr::Path { segments, span } if segments.len() == 1 && !is_callee => {
                let n = &segments[0].name;
                if inline_params.iter().any(|p| p == n) {
                    self.diagnostics.emit(
                        Diagnostic::error(
                            format!(
                                "inline parameter `{n}` cannot escape the function body — only \
                                 direct invocation is allowed"
                            ),
                            *span,
                        )
                        .with_code(codes::TYPE_INLINE_PARAM_LEAK),
                    );
                }
            }
            Expr::Call { callee, args, .. } => {
                self.walk_expr_for_inline_escape(callee, inline_params, crossinline_params, true);
                for a in args {
                    // An argument position is an escape for a bare inline
                    // param reference (we cannot prove the callee is inline).
                    self.flag_inline_escape(
                        a,
                        inline_params,
                        crossinline_params,
                        "passed as an argument",
                    );
                    self.walk_expr_for_inline_escape(a, inline_params, crossinline_params, false);
                }
            }
            Expr::Return { value: Some(v), .. } => {
                self.flag_inline_escape(
                    v,
                    inline_params,
                    crossinline_params,
                    "returned from the function",
                );
                self.walk_expr_for_inline_escape(v, inline_params, crossinline_params, false);
            }
            Expr::Block(b) => {
                self.walk_block_for_inline_escape(b, inline_params, crossinline_params)
            }
            Expr::If {
                cond,
                then_branch,
                else_branch,
                ..
            } => {
                self.walk_expr_for_inline_escape(cond, inline_params, crossinline_params, false);
                self.walk_expr_for_inline_escape(
                    then_branch,
                    inline_params,
                    crossinline_params,
                    false,
                );
                if let Some(e) = else_branch {
                    self.walk_expr_for_inline_escape(e, inline_params, crossinline_params, false);
                }
            }
            Expr::Member { receiver, .. } => {
                self.walk_expr_for_inline_escape(
                    receiver,
                    inline_params,
                    crossinline_params,
                    false,
                );
            }
            _ => {}
        }
    }

    pub(crate) fn flag_inline_escape(
        &mut self,
        e: &Expr,
        inline_params: &[String],
        crossinline_params: &[String],
        action: &str,
    ) {
        let Expr::Path { segments, span } = e else {
            return;
        };
        if segments.len() != 1 {
            return;
        }
        let n = &segments[0].name;
        // crossinline: store / return are forbidden; argument-passing is
        // allowed when the action is exactly "passed as an argument" — but
        // we still flag store/return.
        if crossinline_params.iter().any(|p| p == n) && action != "passed as an argument" {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!("crossinline parameter `{n}` cannot be {action}"),
                    *span,
                )
                .with_code(codes::TYPE_CROSSINLINE_PARAM_LEAK),
            );
            return;
        }
        // inline (non-crossinline, non-noinline): any non-callee use is an
        // escape. Already flagged at the bare-Path case for non-call
        // contexts; only flag here when the bare reference is in an
        // argument list.
        if inline_params.iter().any(|p| p == n) && action == "passed as an argument" {
            self.diagnostics.emit(
                Diagnostic::error(format!("inline parameter `{n}` cannot be {action}"), *span)
                    .with_code(codes::TYPE_INLINE_PARAM_LEAK),
            );
        }
    }

    pub(crate) fn check_inline_property(&mut self, p: &Property) {
        // Spec §4.3.4: an inline property has no backing field. That means
        // no initializer, no `lateinit`, no `by` delegate, and any custom
        // accessor must avoid the `field` identifier (already enforced by
        // T0046 outside an accessor with a backing field — here we reject
        // initializer / lateinit / delegate up front).
        let mut bad = false;
        if p.init.is_some() || p.is_lateinit || p.delegate.is_some() {
            bad = true;
        }
        // An inline property must declare at least one accessor (otherwise
        // it would need a backing field to store its value).
        if p.getter.is_none() && p.setter.is_none() {
            bad = true;
        }
        if bad {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!(
                        "`inline` property `{}` must not have a backing field; declare \
                         explicit accessors that do not reference `field`",
                        p.name.name
                    ),
                    p.name.span,
                )
                .with_code(codes::TYPE_INLINE_PROPERTY_HAS_BACKING_FIELD),
            );
        }
    }

    pub(crate) fn check_const_val(&mut self, p: &Property, scope: PhaseFScope) {
        if p.mutable {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!(
                        "`const` modifier is only allowed on `val`, not `var`: `{}`",
                        p.name.name
                    ),
                    p.name.span,
                )
                .with_code(codes::TYPE_CONST_VAL_NOT_TOPLEVEL),
            );
        }
        if !matches!(scope, PhaseFScope::TopLevel | PhaseFScope::Object) {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!(
                        "`const val` is only allowed at top level or inside an `object`: `{}`",
                        p.name.name
                    ),
                    p.name.span,
                )
                .with_code(codes::TYPE_CONST_VAL_NOT_TOPLEVEL),
            );
        }
        if p.delegate.is_some() || p.getter.is_some() || p.setter.is_some() {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!(
                        "`const val` cannot have a delegate or custom accessor: `{}`",
                        p.name.name
                    ),
                    p.name.span,
                )
                .with_code(codes::TYPE_CONST_VAL_NON_CONST_INIT),
            );
        }
        if let Some(ty) = &p.ty
            && (!is_const_capable_type_name(&ty.name.name) || ty.nullable)
        {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!(
                        "`const val` must have a primitive or `String` type: `{}`",
                        p.name.name
                    ),
                    ty.span,
                )
                .with_code(codes::TYPE_CONST_VAL_NON_CONST_INIT),
            );
        }
        match &p.init {
            None => {
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!("`const val` requires an initializer: `{}`", p.name.name),
                        p.name.span,
                    )
                    .with_code(codes::TYPE_CONST_VAL_NON_CONST_INIT),
                );
            }
            Some(init) => {
                if !self.is_const_initializer(init) {
                    self.diagnostics.emit(
                        Diagnostic::error(
                            format!(
                                "`const val` initializer must be a compile-time constant: `{}`",
                                p.name.name
                            ),
                            init.span(),
                        )
                        .with_code(codes::TYPE_CONST_VAL_NON_CONST_INIT),
                    );
                }
            }
        }
    }

    /// Structural check: is this expression composed solely of literals,
    /// references to other `const val` declarations, arithmetic /
    /// comparison / string-concat operators over const-capable types, and
    /// string templates whose interpolated parts are also const?
    pub(crate) fn is_const_initializer(&self, e: &Expr) -> bool {
        // The `NullLit` arm is kept explicit to document that `null` is not
        // a const initializer here, even though it shares `_`'s body.
        #[allow(clippy::match_same_arms)]
        match e {
            Expr::IntLit { .. }
            | Expr::FloatLit { .. }
            | Expr::BoolLit { .. }
            | Expr::CharLit { .. } => true,
            Expr::NullLit { .. } => false,
            Expr::StringTemplate { parts, .. } => parts.iter().all(|p| match p {
                StringPart::Text(_) => true,
                StringPart::ShortInterp(id) => self.is_const_ref(&id.name),
                StringPart::Interp(inner) => self.is_const_initializer(inner),
            }),
            Expr::Path { segments, .. } => {
                if segments.len() == 1 {
                    self.is_const_ref(&segments[0].name)
                } else {
                    // Permit qualified references when the leaf is a const
                    // val on a known class (best-effort: trailing segment).
                    self.is_const_ref(&segments.last().unwrap().name)
                }
            }
            Expr::Member {
                receiver,
                name,
                safe,
                ..
            } => {
                if *safe {
                    return false;
                }
                // Spec §8.2: access expressions to enum entries are
                // constant expressions. Recognize `EnumClass.ENTRY`.
                if let Expr::Path { segments, .. } = receiver.as_ref()
                    && segments.len() == 1
                {
                    if let Some(info) = self.classes.get(&segments[0].name)
                        && info.is_enum
                    {
                        return true;
                    }
                    // Builtin primitive companion constants
                    // (`Long.MAX_VALUE`, `Int.MIN_VALUE`,
                    // `Double.POSITIVE_INFINITY`, `*.SIZE_BITS`,
                    // …) are compile-time constants.
                    if matches!(
                        segments[0].name.as_str(),
                        "Int"
                            | "Long"
                            | "Short"
                            | "Byte"
                            | "Double"
                            | "Float"
                            | "Char"
                            | "Boolean"
                            | "UInt"
                            | "ULong"
                            | "UShort"
                            | "UByte"
                    ) {
                        return true;
                    }
                }
                self.is_const_initializer(receiver) && self.is_const_ref(&name.name)
            }
            Expr::Unary { op, expr, .. } => {
                matches!(op, UnOp::Neg | UnOp::Pos | UnOp::Not) && self.is_const_initializer(expr)
            }
            Expr::Binary { op, lhs, rhs, .. } => {
                matches!(
                    op,
                    BinOp::Add
                        | BinOp::Sub
                        | BinOp::Mul
                        | BinOp::Div
                        | BinOp::Rem
                        | BinOp::Eq
                        | BinOp::Neq
                        | BinOp::Lt
                        | BinOp::Le
                        | BinOp::Gt
                        | BinOp::Ge
                        | BinOp::And
                        | BinOp::Or
                ) && self.is_const_initializer(lhs)
                    && self.is_const_initializer(rhs)
            }
            // Integer bitwise/shift infix functions are compile-time
            // constant in Kotlin (`const val M = 1 shl 30`,
            // `Long.MAX_VALUE / MS`): they parse as an infix call
            // `a shl b` or a member call `a.shl(b)`.
            Expr::Call {
                callee,
                args,
                is_infix,
                ..
            } => {
                const CONST_INFIX: &[&str] = &["shl", "shr", "ushr", "and", "or", "xor", "inv"];
                match callee.as_ref() {
                    Expr::Path { segments, .. }
                        if *is_infix
                            && segments.len() == 1
                            && CONST_INFIX.contains(&segments[0].name.as_str()) =>
                    {
                        args.iter().all(|a| self.is_const_initializer(a))
                    }
                    Expr::Member {
                        receiver,
                        name,
                        safe: false,
                        ..
                    } if CONST_INFIX.contains(&name.name.as_str()) => {
                        self.is_const_initializer(receiver)
                            && args.iter().all(|a| self.is_const_initializer(a))
                    }
                    _ => false,
                }
            }
            _ => false,
        }
    }

    /// Spec §17.1: annotation-class primary-ctor parameter default values
    /// must be compile-time constant. Extends `is_const_initializer` with
    /// the forms specific to annotation arguments: `T::class` literals,
    /// `arrayOf(...)` of constants, and bare enum-entry references.
    pub(crate) fn is_annotation_param_default_const(&self, e: &Expr) -> bool {
        if self.is_const_initializer(e) {
            return true;
        }
        match e {
            // `T::class` class literal.
            Expr::MemberRef { name, .. } if name.name == "class" => true,
            // `arrayOf(...)` / `intArrayOf` / similar primitive-array builders.
            Expr::Call { callee, args, .. } => {
                if let Expr::Path { segments, .. } = callee.as_ref() {
                    let leaf = &segments.last().unwrap().name;
                    let is_array_builder = matches!(
                        leaf.as_str(),
                        "arrayOf"
                            | "intArrayOf"
                            | "longArrayOf"
                            | "shortArrayOf"
                            | "byteArrayOf"
                            | "floatArrayOf"
                            | "doubleArrayOf"
                            | "booleanArrayOf"
                            | "charArrayOf"
                            | "emptyArray"
                    );
                    if is_array_builder {
                        return args
                            .iter()
                            .all(|a| self.is_annotation_param_default_const(a));
                    }
                }
                false
            }
            _ => false,
        }
    }

    pub(crate) fn is_const_ref(&self, name: &str) -> bool {
        if let Some(b) = self.frames[0].bindings.get(name)
            && !b.mutable
        {
            return matches!(
                b.ty,
                Type::Int
                    | Type::Long
                    | Type::Short
                    | Type::Byte
                    | Type::Float
                    | Type::Double
                    | Type::Boolean
                    | Type::Char
                    | Type::String
            );
        }
        false
    }

    fn check_value_class_modifiers(&mut self, c: &Class) {
        let span = c.name.span;
        let emit = |this: &mut Self, msg: String| {
            this.diagnostics
                .emit(Diagnostic::error(msg, span).with_code(codes::TYPE_VALUE_CLASS_SHAPE));
        };
        if c.is_open {
            emit(
                self,
                format!(
                    "`value class {}` must be final (cannot be `open`)",
                    c.name.name
                ),
            );
        }
        if c.is_abstract {
            emit(
                self,
                format!("`value class {}` cannot be `abstract`", c.name.name),
            );
        }
        if c.is_sealed {
            emit(
                self,
                format!("`value class {}` cannot be `sealed`", c.name.name),
            );
        }
        if c.is_inner {
            emit(
                self,
                format!("`value class {}` cannot be `inner`", c.name.name),
            );
        }
        if c.is_data {
            emit(
                self,
                format!("`value class {}` cannot be `data`", c.name.name),
            );
        }
        if c.is_enum {
            emit(
                self,
                format!("`value class {}` cannot be `enum`", c.name.name),
            );
        }
        if c.is_annotation {
            emit(
                self,
                format!("`value class {}` cannot be `annotation`", c.name.name),
            );
        }
        if !c.init_blocks.is_empty() {
            emit(
                self,
                format!("`value class {}` cannot have `init` blocks", c.name.name),
            );
        }
    }

    pub(crate) fn check_value_class(&mut self, c: &Class) {
        let span = c.name.span;
        let emit = |this: &mut Self, msg: String| {
            this.diagnostics
                .emit(Diagnostic::error(msg, span).with_code(codes::TYPE_VALUE_CLASS_SHAPE));
        };
        self.check_value_class_modifiers(c);
        for sc in &c.secondary_ctors {
            if sc.body.as_ref().is_some_and(|b| !b.stmts.is_empty()) {
                emit(
                    self,
                    format!(
                        "`value class {}` secondary constructors must have empty bodies",
                        c.name.name
                    ),
                );
                break;
            }
        }
        let immutable_count = c
            .primary_params
            .iter()
            .filter(|p| p.property == Some(false))
            .count();
        let mutable_count = c
            .primary_params
            .iter()
            .filter(|p| p.property == Some(true))
            .count();
        if mutable_count > 0 {
            emit(
                self,
                format!(
                    "`value class {}` cannot declare a `var` primary-constructor property",
                    c.name.name
                ),
            );
        }
        if immutable_count != 1 {
            emit(
                self,
                format!(
                    "`value class {}` must declare exactly one `val` primary-constructor property",
                    c.name.name
                ),
            );
        }
        for m in &c.members {
            match m {
                Decl::Property(p) => {
                    // Body properties with a backing field are forbidden: an
                    // initializer or `lateinit` implies a backing field. A
                    // body property with only a `get()` accessor is allowed.
                    let has_backing_field =
                        p.init.is_some() || p.is_lateinit || p.delegate.is_some();
                    if has_backing_field {
                        emit(
                            self,
                            format!(
                                "`value class {}` cannot declare body properties with backing fields",
                                c.name.name
                            ),
                        );
                    }
                }
                Decl::Function(f)
                    if f.is_override && (f.name.name == "equals" || f.name.name == "hashCode") =>
                {
                    emit(
                        self,
                        format!(
                            "`value class {}` cannot override `{}`",
                            c.name.name, f.name.name
                        ),
                    );
                }
                _ => {}
            }
        }
        for s in &c.supertypes {
            if let Some(info) = self.classes.get(&s.name.name)
                && !info.is_interface
            {
                emit(
                    self,
                    format!(
                        "`value class {}` cannot extend non-interface supertype `{}`",
                        c.name.name, s.name.name
                    ),
                );
            }
        }
    }

    fn check_annotation_class_shape(&mut self, c: &Class) {
        let span = c.name.span;
        let emit = |this: &mut Self, msg: String| {
            this.diagnostics
                .emit(Diagnostic::error(msg, span).with_code(codes::TYPE_ANNOTATION_CLASS_SHAPE));
        };
        if c.is_open {
            emit(
                self,
                format!("`annotation class {}` cannot be `open`", c.name.name),
            );
        }
        if c.is_abstract {
            emit(
                self,
                format!("`annotation class {}` cannot be `abstract`", c.name.name),
            );
        }
        if c.is_sealed {
            emit(
                self,
                format!("`annotation class {}` cannot be `sealed`", c.name.name),
            );
        }
        if c.is_data {
            emit(
                self,
                format!("`annotation class {}` cannot be `data`", c.name.name),
            );
        }
        if c.is_enum {
            emit(
                self,
                format!("`annotation class {}` cannot be `enum`", c.name.name),
            );
        }
        if c.is_inner {
            emit(
                self,
                format!("`annotation class {}` cannot be `inner`", c.name.name),
            );
        }
        if c.is_value {
            emit(
                self,
                format!("`annotation class {}` cannot be `value`", c.name.name),
            );
        }
        if !c.secondary_ctors.is_empty() {
            emit(
                self,
                format!(
                    "`annotation class {}` cannot have secondary constructors",
                    c.name.name
                ),
            );
        }
        if !c.init_blocks.is_empty() {
            emit(
                self,
                format!(
                    "`annotation class {}` cannot have `init` blocks",
                    c.name.name
                ),
            );
        }
        if !c.members.is_empty() {
            // A bare companion object inside an annotation class is permitted
            // by kotlinc; everything else (functions, body properties, nested
            // classes) is rejected.
            for m in &c.members {
                let allowed = matches!(m, Decl::Class(inner) if inner.is_companion);
                if !allowed {
                    emit(
                        self,
                        format!(
                            "`annotation class {}` cannot have body declarations",
                            c.name.name
                        ),
                    );
                    break;
                }
            }
        }
        if !c.supertypes.is_empty() {
            emit(
                self,
                format!(
                    "`annotation class {}` cannot declare a supertype",
                    c.name.name
                ),
            );
        }
    }

    pub(crate) fn check_annotation_class(&mut self, c: &Class) {
        self.check_annotation_class_shape(c);
        for p in &c.primary_params {
            if let Some(default) = &p.default
                && !self.is_annotation_param_default_const(default)
            {
                self.diagnostics.emit(
                        Diagnostic::error(
                            format!(
                                "annotation-class parameter `{}` default value must be a compile-time constant",
                                p.name.name
                            ),
                            default.span(),
                        )
                        .with_code(codes::TYPE_ANNOTATION_PARAM_DEFAULT_NOT_CONST),
                    );
            }
            let head = &p.ty.name.name;
            let allowed_head = is_annotation_param_type(head)
                || self.annotation_class_names.contains(head)
                || self.enum_class_names.contains(head);
            if !allowed_head || p.ty.nullable {
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!(
                            "annotation-class parameter `{}` has unsupported type `{}`",
                            p.name.name, p.ty.name.name
                        ),
                        p.ty.span,
                    )
                    .with_code(codes::TYPE_ANNOTATION_PARAM_TYPE),
                );
            } else if p.ty.name.name == "Array" {
                // Spec §4.1.4: Array element type is restricted to the same
                // allowed-type set (primitives / String / KClass / annotation /
                // enum). Look into the first type-argument; reject anything
                // that isn't a recognised allowed name. `out T` projections
                // are unwrapped via `TypeArg.ty`.
                if let Some(arg) = p.ty.type_args.first() {
                    let inner = &arg.ty.name.name;
                    let inner_ok = is_annotation_param_type(inner)
                        || self.annotation_class_names.contains(inner)
                        || self.enum_class_names.contains(inner);
                    if !inner_ok || arg.ty.nullable {
                        self.diagnostics.emit(
                            Diagnostic::error(
                                format!(
                                    "annotation-class parameter `{}` has `Array` of unsupported \
                                     element type `{}`",
                                    p.name.name, inner
                                ),
                                arg.ty.span,
                            )
                            .with_code(codes::TYPE_ANNOTATION_PARAM_TYPE),
                        );
                    }
                }
            }
        }
    }

    /// Spec §17.5.4: a declaration marked with an annotation that itself
    /// carries `@RequiresOptIn(message, level)` requires every reference
    /// site to opt in via `@OptIn(MarkerClass::class)` on an enclosing
    /// declaration. Reference sites without an active opt-in get a
    /// warning (default) or error (level = Level.ERROR).
    pub(crate) fn check_opt_in_references(&mut self, file: &KotlinFile) {
        let mut markers: HashMap<String, OptInMarker> = HashMap::new();
        let mut classes: Vec<&Class> = Vec::new();
        collect_annotation_classes(&file.decls, &mut classes);
        for c in classes {
            if let Some(info) = parse_requires_opt_in(&c.annotations) {
                markers.insert(c.name.name.clone(), info);
            }
        }
        if markers.is_empty() {
            return;
        }
        let mut required: HashMap<String, Vec<String>> = HashMap::new();
        collect_required_opt_ins(&file.decls, &markers, &mut required);
        let diags = collect_opt_in_diagnostics(file, &markers, &required);
        for d in diags {
            self.diagnostics.emit(d);
        }
    }

    /// Spec §17.5.5: emit a warning / error / hidden diagnostic at every
    /// bare-name reference to a top-level declaration carrying
    /// `@Deprecated(message, replaceWith, level)`. Only top-level
    /// functions / properties / classes / typealiases are tracked; member
    /// accesses are not flagged.
    pub(crate) fn check_deprecated_references(&mut self, file: &KotlinFile) {
        let mut info: HashMap<String, DeprecationInfo> = HashMap::new();
        collect_deprecation_info(&file.decls, &mut info);
        if info.is_empty() {
            return;
        }
        // Walk every expression in the file looking for bare-name
        // references to a deprecated declaration. Declaration sites
        // themselves are not visited (we only descend into bodies /
        // initializers / accessors / arguments / annotation args).
        let diags = collect_deprecation_diagnostics(file, &info);
        for d in diags {
            self.diagnostics.emit(d);
        }
    }

    /// Spec §17.3 / §17.4: enforce `@Target` and `@Repeatable` on
    /// annotation applications across the whole file.
    ///
    /// `@Target(AnnotationTarget.X, ...)` on an annotation class restricts
    /// the source-level entities the annotation may be applied to.
    /// `@Repeatable` opts the annotation into being applied to the same
    /// entity more than once; non-repeatable annotations (the default)
    /// applied twice to the same entity get T0109.
    pub(crate) fn check_annotation_applications(&mut self, file: &KotlinFile) {
        let mut meta: HashMap<String, AnnotationMeta> = HashMap::new();
        let mut classes: Vec<&Class> = Vec::new();
        collect_annotation_classes(&file.decls, &mut classes);
        for c in classes {
            let mut m = AnnotationMeta::default();
            for a in &c.annotations {
                let leaf = a.path.last().map_or("", |s| s.name.as_str());
                if leaf == "Repeatable" {
                    m.repeatable = true;
                } else if leaf == "Target" {
                    let mut targets: Vec<AnnotationTarget> = Vec::new();
                    for arg in &a.args {
                        extract_annotation_targets(arg, &mut targets);
                    }
                    m.targets = Some(targets);
                }
            }
            meta.insert(c.name.name.clone(), m);
        }
        let mut walker = AnnotationWalker {
            ch: self,
            meta: &meta,
        };
        walker.walk_file(file);
    }

    /// Spec §17.1: an annotation type cannot reference itself, either
    /// directly or indirectly (through another annotation type, or
    /// through `Array<T>` whose element is an annotation type).
    pub(crate) fn check_annotation_cycles(&mut self, file: &KotlinFile) {
        let mut classes: Vec<&Class> = Vec::new();
        collect_annotation_classes(&file.decls, &mut classes);
        if classes.is_empty() {
            return;
        }
        let name_set: HashSet<String> = classes.iter().map(|c| c.name.name.clone()).collect();
        let mut deps: HashMap<String, Vec<String>> = HashMap::new();
        let mut spans: HashMap<String, Span> = HashMap::new();
        for c in &classes {
            spans.insert(c.name.name.clone(), c.name.span);
            let mut out: Vec<String> = Vec::new();
            for p in &c.primary_params {
                let head = &p.ty.name.name;
                if name_set.contains(head) {
                    out.push(head.clone());
                } else if head == "Array"
                    && let Some(arg) = p.ty.type_args.first()
                {
                    let inner = &arg.ty.name.name;
                    if name_set.contains(inner) {
                        out.push(inner.clone());
                    }
                }
            }
            deps.insert(c.name.name.clone(), out);
        }
        for c in &classes {
            let start = &c.name.name;
            let mut seen: HashSet<String> = HashSet::new();
            if annotation_reaches_self(start, start, &deps, &mut seen) {
                let span = spans[start];
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!(
                            "annotation class `{start}` cannot reference itself, directly or transitively"
                        ),
                        span,
                    )
                    .with_code(codes::TYPE_ANNOTATION_CYCLE),
                );
            }
        }
    }

    pub(crate) fn check_definitely_non_null_decl(
        &mut self,
        d: &Decl,
        tp_scope: &mut Vec<HashSet<String>>,
    ) {
        match d {
            Decl::Function(f) => {
                let mut frame = HashSet::new();
                for tp in &f.type_params {
                    frame.insert(tp.name.name.clone());
                }
                tp_scope.push(frame);
                if let Some(r) = &f.receiver_type {
                    self.check_dnn_typeref(r, tp_scope);
                }
                for p in &f.params {
                    self.check_dnn_typeref(&p.ty, tp_scope);
                }
                if let Some(rt) = &f.return_type {
                    self.check_dnn_typeref(rt, tp_scope);
                }
                if let Some(body) = &f.body {
                    match body {
                        FunctionBody::Block(b) => self.walk_block_for_dnn(b, tp_scope),
                        FunctionBody::Expr(e) => self.walk_expr_for_dnn(e, tp_scope),
                    }
                }
                tp_scope.pop();
            }
            Decl::Class(c) => {
                let mut frame = HashSet::new();
                for tp in &c.type_params {
                    frame.insert(tp.name.name.clone());
                }
                tp_scope.push(frame);
                for cp in &c.primary_params {
                    self.check_dnn_typeref(&cp.ty, tp_scope);
                }
                for m in &c.members {
                    self.check_definitely_non_null_decl(m, tp_scope);
                }
                tp_scope.pop();
            }
            Decl::Property(p) => {
                if let Some(t) = &p.ty {
                    self.check_dnn_typeref(t, tp_scope);
                }
                if let Some(init) = &p.init {
                    self.walk_expr_for_dnn(init, tp_scope);
                }
            }
            Decl::Object(o) => {
                for m in &o.members {
                    self.check_definitely_non_null_decl(m, tp_scope);
                }
            }
            Decl::TypeAlias(a) => {
                let mut frame = HashSet::new();
                for tp in &a.type_params {
                    frame.insert(tp.name.name.clone());
                }
                tp_scope.push(frame);
                self.check_dnn_typeref(&a.target, tp_scope);
                tp_scope.pop();
            }
        }
    }

    pub(crate) fn check_dnn_typeref(&mut self, t: &TypeRef, tp_scope: &[HashSet<String>]) {
        if t.definitely_non_null {
            let is_tp = tp_scope.iter().any(|s| s.contains(&t.name.name));
            if !is_tp {
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!(
                            "definitely non-nullable type `{} & Any` is only allowed when `{}` is a type parameter",
                            t.name.name, t.name.name
                        ),
                        t.span,
                    )
                    .with_code(codes::TYPE_DEFINITELY_NON_NULL_NOT_TYPE_PARAM),
                );
            }
        }
        for ta in &t.type_args {
            self.check_dnn_typeref(&ta.ty, tp_scope);
        }
        if let Some(f) = &t.function {
            if let Some(r) = &f.receiver {
                self.check_dnn_typeref(r, tp_scope);
            }
            for p in &f.params {
                self.check_dnn_typeref(p, tp_scope);
            }
            self.check_dnn_typeref(&f.ret, tp_scope);
        }
    }

    pub(crate) fn walk_block_for_dnn(&mut self, b: &Block, tp_scope: &mut Vec<HashSet<String>>) {
        for s in &b.stmts {
            match s {
                Stmt::Decl(d) => self.check_definitely_non_null_decl(d, tp_scope),
                Stmt::Expr(e) => self.walk_expr_for_dnn(e, tp_scope),
                Stmt::Assign { value, .. } => self.walk_expr_for_dnn(value, tp_scope),
                Stmt::DestructuringDecl { init, .. } => self.walk_expr_for_dnn(init, tp_scope),
            }
        }
    }

    pub(crate) fn walk_expr_for_dnn(&mut self, e: &Expr, tp_scope: &mut Vec<HashSet<String>>) {
        match e {
            Expr::Block(b) => self.walk_block_for_dnn(b, tp_scope),
            Expr::If {
                cond,
                then_branch,
                else_branch,
                ..
            } => {
                self.walk_expr_for_dnn(cond, tp_scope);
                self.walk_expr_for_dnn(then_branch, tp_scope);
                if let Some(eb) = else_branch {
                    self.walk_expr_for_dnn(eb, tp_scope);
                }
            }
            Expr::While { cond, body, .. } => {
                self.walk_expr_for_dnn(cond, tp_scope);
                self.walk_expr_for_dnn(body, tp_scope);
            }
            Expr::DoWhile { body, cond, .. } => {
                if let Some(b) = body {
                    self.walk_expr_for_dnn(b, tp_scope);
                }
                self.walk_expr_for_dnn(cond, tp_scope);
            }
            Expr::For { iter, body, .. } => {
                self.walk_expr_for_dnn(iter, tp_scope);
                self.walk_expr_for_dnn(body, tp_scope);
            }
            Expr::Lambda { body, .. } => self.walk_block_for_dnn(body, tp_scope),
            Expr::IsCheck { ty, .. } => self.check_dnn_typeref(ty, tp_scope),
            Expr::When {
                subject,
                subject_binding,
                branches,
                ..
            } => {
                if let Some(s) = subject {
                    self.walk_expr_for_dnn(s, tp_scope);
                }
                if let Some(b) = subject_binding
                    && let Some(t) = &b.ty
                {
                    self.check_dnn_typeref(t, tp_scope);
                }
                for br in branches {
                    for p in &br.patterns {
                        match &p.kind {
                            WhenPatternKind::IsType(t) | WhenPatternKind::NotIsType(t) => {
                                self.check_dnn_typeref(t, tp_scope);
                            }
                            WhenPatternKind::Value(e)
                            | WhenPatternKind::InRange(e)
                            | WhenPatternKind::NotInRange(e) => {
                                self.walk_expr_for_dnn(e, tp_scope);
                            }
                            WhenPatternKind::Else => {}
                        }
                    }
                    self.walk_expr_for_dnn(&br.body, tp_scope);
                }
            }
            Expr::ObjectExpr { members, .. } => {
                for m in members {
                    self.check_definitely_non_null_decl(m, tp_scope);
                }
            }
            _ => {}
        }
    }

    // ---- Generics + inline diagnostics --------------------------------------

    pub(crate) fn check_generics_decl(&mut self, d: &Decl) {
        match d {
            Decl::Function(f) => self.check_generics_function(f),
            Decl::Class(c) => self.check_generics_class(c),
            Decl::Property(_) | Decl::Object(_) | Decl::TypeAlias(_) => {}
        }
    }

    pub(crate) fn check_generics_function(&mut self, f: &Function) {
        // T0023 — reified outside inline
        for tp in &f.type_params {
            if tp.is_reified && !f.is_inline {
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!(
                            "type parameter `{}` is `reified` but enclosing function is not `inline`",
                            tp.name.name
                        ),
                        tp.span,
                    )
                    .with_code(codes::TYPE_REIFIED_REQUIRES_INLINE),
                );
            }
        }
        // T0026 — crossinline/noinline outside inline
        for p in &f.params {
            if (p.is_crossinline || p.is_noinline) && !f.is_inline {
                let which = if p.is_crossinline {
                    "crossinline"
                } else {
                    "noinline"
                };
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!(
                            "`{}` parameter `{}` is only allowed on an `inline` function",
                            which, p.name.name
                        ),
                        p.name.span,
                    )
                    .with_code(codes::TYPE_INLINE_MODIFIER_OUTSIDE_INLINE),
                );
            }
        }
        // T0025 — vararg misuse
        let vararg_idxs: Vec<usize> = f
            .params
            .iter()
            .enumerate()
            .filter(|(_, p)| p.is_vararg)
            .map(|(i, _)| i)
            .collect();
        if vararg_idxs.len() > 1 {
            for &i in vararg_idxs.iter().skip(1) {
                self.diagnostics.emit(
                    Diagnostic::error(
                        "a function may declare at most one `vararg` parameter",
                        f.params[i].name.span,
                    )
                    .with_code(codes::TYPE_VARARG_MISUSE),
                );
            }
        }
        if let Some(&i) = vararg_idxs.first() {
            // Following params are allowed only if they have defaults.
            for (j, p) in f.params.iter().enumerate().skip(i + 1) {
                if p.default.is_none() {
                    self.diagnostics.emit(
                        Diagnostic::error(
                            format!(
                                "parameter `{}` follows a `vararg` and must have a default value",
                                p.name.name
                            ),
                            p.name.span,
                        )
                        .with_code(codes::TYPE_VARARG_MISUSE),
                    );
                }
                let _ = j;
            }
        }
        // Recurse into nested functions/classes inside the body.
        if let Some(body) = &f.body {
            match body {
                FunctionBody::Block(b) => self.walk_block_for_generics(b),
                FunctionBody::Expr(e) => self.walk_expr_for_generics(e),
            }
        }
    }

    pub(crate) fn check_generics_class(&mut self, c: &Class) {
        // T0024 — declaration-site variance positions on member functions.
        for tp in &c.type_params {
            if matches!(tp.variance, klio_ast::Variance::Invariant) {
                continue;
            }
            for m in &c.members {
                if let Decl::Function(f) = m {
                    // J5: `private` member is only accessible via `this`, so
                    // its parameter / return positions are not observable
                    // through the public API. Variance rules don't apply.
                    if matches!(f.visibility, Visibility::Private) {
                        continue;
                    }
                    self.check_member_variance_positions(&tp.name.name, tp.variance, f);
                }
            }
        }
        for m in &c.members {
            self.check_generics_decl(m);
        }
    }

    pub(crate) fn check_member_variance_positions(
        &mut self,
        param: &str,
        variance: klio_ast::Variance,
        f: &Function,
    ) {
        // A member that declares its own type parameter of the same
        // name shadows the class parameter inside its signature, so
        // the class's variance does not constrain it
        // (`class C<in T> { fun <T> get(): T }` — the method `T` is a
        // fresh invariant param; upstream
        // CancellableContinuationImpl.getSuccessfulResult).
        if f.type_params.iter().any(|tp| tp.name.name == param) {
            return;
        }
        // For `out T`: T must not appear in input positions.
        // For `in T`: T must not appear in output positions.
        match variance {
            klio_ast::Variance::Out => {
                for p in &f.params {
                    if type_ref_uses(&p.ty, param) {
                        self.diagnostics.emit(
                            Diagnostic::error(
                                format!(
                                    "type parameter `{param}` is `out` but appears in an input position of `{}`",
                                    f.name.name
                                ),
                                p.ty.span,
                            )
                            .with_code(codes::TYPE_DECLARATION_VARIANCE_VIOLATION),
                        );
                    }
                }
            }
            klio_ast::Variance::In => {
                if let Some(rt) = &f.return_type
                    && type_ref_uses(rt, param)
                {
                    self.diagnostics.emit(
                            Diagnostic::error(
                                format!(
                                    "type parameter `{param}` is `in` but appears in an output position of `{}`",
                                    f.name.name
                                ),
                                rt.span,
                            )
                            .with_code(codes::TYPE_DECLARATION_VARIANCE_VIOLATION),
                        );
                }
            }
            klio_ast::Variance::Invariant => {}
        }
    }

    pub(crate) fn walk_block_for_generics(&mut self, b: &Block) {
        for s in &b.stmts {
            match s {
                Stmt::Decl(d) => self.check_generics_decl(d),
                Stmt::Expr(e) => self.walk_expr_for_generics(e),
                Stmt::Assign { value, .. } => self.walk_expr_for_generics(value),
                Stmt::DestructuringDecl { init, .. } => self.walk_expr_for_generics(init),
            }
        }
    }

    pub(crate) fn walk_expr_for_generics(&mut self, e: &Expr) {
        match e {
            Expr::Block(b) => self.walk_block_for_generics(b),
            Expr::If {
                cond,
                then_branch,
                else_branch,
                ..
            } => {
                self.walk_expr_for_generics(cond);
                self.walk_expr_for_generics(then_branch);
                if let Some(eb) = else_branch {
                    self.walk_expr_for_generics(eb);
                }
            }
            Expr::While { cond, body, .. } => {
                self.walk_expr_for_generics(cond);
                self.walk_expr_for_generics(body);
            }
            Expr::DoWhile { body, cond, .. } => {
                if let Some(b) = body {
                    self.walk_expr_for_generics(b);
                }
                self.walk_expr_for_generics(cond);
            }
            Expr::For { iter, body, .. } => {
                self.walk_expr_for_generics(iter);
                self.walk_expr_for_generics(body);
            }
            Expr::Lambda { body, .. } => self.walk_block_for_generics(body),
            Expr::ObjectExpr { members, .. } => {
                for m in members {
                    self.check_generics_decl(m);
                }
            }
            _ => {}
        }
    }
}

/// Tarjan's strongly-connected-components over an adjacency list.
struct TarjanScc<'e> {
    edges: &'e [Vec<usize>],
    index: usize,
    idx_of: Vec<Option<usize>>,
    lowlink: Vec<usize>,
    on_stack: Vec<bool>,
    stack: Vec<usize>,
    sccs: Vec<Vec<usize>>,
}

impl TarjanScc<'_> {
    fn strongconnect(&mut self, v: usize) {
        self.idx_of[v] = Some(self.index);
        self.lowlink[v] = self.index;
        self.index += 1;
        self.stack.push(v);
        self.on_stack[v] = true;
        let edges = self.edges;
        for &w in &edges[v] {
            if self.idx_of[w].is_none() {
                self.strongconnect(w);
                self.lowlink[v] = self.lowlink[v].min(self.lowlink[w]);
            } else if self.on_stack[w] {
                self.lowlink[v] = self.lowlink[v].min(self.idx_of[w].unwrap());
            }
        }
        if self.lowlink[v] == self.idx_of[v].unwrap() {
            let mut comp = Vec::new();
            loop {
                let w = self.stack.pop().unwrap();
                self.on_stack[w] = false;
                comp.push(w);
                if w == v {
                    break;
                }
            }
            self.sccs.push(comp);
        }
    }
}

fn tarjan_sccs(edges: &[Vec<usize>]) -> Vec<Vec<usize>> {
    let n = edges.len();
    let mut t = TarjanScc {
        edges,
        index: 0,
        idx_of: vec![None; n],
        lowlink: vec![0; n],
        on_stack: vec![false; n],
        stack: Vec::new(),
        sccs: Vec::new(),
    };
    for v in 0..n {
        if t.idx_of[v].is_none() {
            t.strongconnect(v);
        }
    }
    t.sccs
}
