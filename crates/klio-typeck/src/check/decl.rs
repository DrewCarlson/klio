use super::*;

impl<'r> Checker<'r> {

    // ---- top-level declaration intake -----------------------------------

    pub(crate) fn declare_top_level(&mut self, decl: &Decl) {
        match decl {
            Decl::Function(f) => {
                let sig = self.signature_of(f);
                if let Some(recv) = &f.receiver_type {
                    let return_class = f.return_type.as_ref().and_then(class_name_from_typeref);
                    self.extensions
                        .entry(recv.name.name.clone())
                        .or_default()
                        .push(ExtensionSig {
                            name: f.name.name.clone(),
                            sig,
                            return_class,
                        });
                } else {
                    let nm = f.name.name.clone();
                    self.push_fn_sig(&nm, sig, f.is_expect || f.is_actual);
                    self.fn_visibility
                        .entry(f.name.name.clone())
                        .or_default()
                        .push((f.visibility, f.name.span.file));
                    self.fn_annotations
                        .entry(f.name.name.clone())
                        .or_default()
                        .push(f.annotations.clone());
                }
            }
            Decl::Property(p) => {
                let ty = p
                    .ty
                    .as_ref()
                    .map(convert_type_ref_lossy)
                    .unwrap_or(Type::Unresolved);
                let cn = p.ty.as_ref().and_then(class_name_from_typeref);
                if let Some(recv) = &p.receiver_type {
                    self.extension_properties
                        .entry(recv.name.name.clone())
                        .or_default()
                        .push(ExtensionPropSig {
                            name: p.name.name.clone(),
                            ty,
                            mutable: p.mutable,
                            return_class: cn,
                        });
                } else {
                    self.frames[0].bindings.insert(
                        p.name.name.clone(),
                        Binding { ty, mutable: p.mutable, decl_span: Some(p.name.span), class_name: cn, decl_type_name: None },
                    );
                    self.prop_visibility
                        .insert(p.name.name.clone(), (p.visibility, p.name.span.file));
                    if let Some(sv) = p.setter_visibility {
                        self.setter_visibility
                            .insert(p.name.name.clone(), (sv, p.name.span.file));
                    } else if let Some(setter) = &p.setter {
                        if let Some(sv) = setter.visibility {
                            self.setter_visibility
                                .insert(p.name.name.clone(), (sv, p.name.span.file));
                        }
                    }
                    self.prop_annotations
                        .insert(p.name.name.clone(), p.annotations.clone());
                }
            }
            Decl::Class(c) => {
                let info = self.class_info(c);
                self.classes.insert(c.name.name.clone(), info);
            }
            Decl::Object(o) => {
                // Treat object singleton like a class with no ctor.
                let mut info = ClassInfo::default();
                info.is_object = true;
                info.decl_file = Some(o.name.span.file);
                self.collect_members(&o.members, &mut info);
                for s in &o.supertypes {
                    info.supertypes.push(s.name.name.clone());
                }
                self.classes.insert(o.name.name.clone(), info);
                // Bind the singleton name itself so `Foo.bar` reads pass.
                self.frames[0].bindings.insert(
                    o.name.name.clone(),
                    Binding {
                        ty: Type::Unresolved,
                        mutable: false,
                        decl_span: Some(o.name.span),
                        class_name: Some(o.name.name.clone()), decl_type_name: None },
                );
            }
            Decl::TypeAlias(a) => {
                self.aliases.insert(
                    a.name.name.clone(),
                    TypeAliasInfo {
                        type_params: a.type_params.iter().map(|p| p.name.name.clone()).collect(),
                        target: a.target.clone(),
                        name_span: a.name.span,
                    },
                );
            }
        }
    }

    /// Materializes the per-type-parameter upper-bound list for a
    /// declaration. The inline `<T : Foo>` bound contributes one entry;
    /// every `where T : ...` clause that names the parameter appends
    /// another. Bounds that lower to `Type::Unresolved` are dropped because
    /// they would render the subtype check vacuously true.
    pub(crate) fn collect_type_param_bounds(
        type_params: &[TypeParam],
        where_bounds: &[WhereBound],
    ) -> (Vec<String>, Vec<Vec<Type>>) {
        let mut names = Vec::with_capacity(type_params.len());
        let mut bounds: Vec<Vec<Type>> = Vec::with_capacity(type_params.len());
        for tp in type_params {
            names.push(tp.name.name.clone());
            let mut v: Vec<Type> = Vec::new();
            if let Some(b) = &tp.upper_bound {
                let ty = convert_type_ref_lossy(b);
                if !matches!(ty, Type::Unresolved) {
                    v.push(ty);
                }
            }
            for wb in where_bounds {
                if wb.name.name == tp.name.name {
                    let ty = convert_type_ref_lossy(&wb.bound);
                    if !matches!(ty, Type::Unresolved) {
                        v.push(ty);
                    }
                }
            }
            bounds.push(v);
        }
        (names, bounds)
    }

    /// Register a top-level function signature under `name`. An
    /// `expect`/`actual` pair (or the same declaration visible from
    /// two curated source roots, as with the upstream packs) is one
    /// logical function, not an overload set: when the function is
    /// `expect`/`actual` and an identical parameter signature is
    /// already registered, skip the duplicate so overload resolution
    /// does not see a spurious `(T), (T)` ambiguity. Ordinary
    /// overloads (distinct parameter types) and genuine
    /// same-signature clashes between non-expect/actual declarations
    /// are unaffected.
    pub(crate) fn push_fn_sig(&mut self, name: &str, sig: FnSig, expect_or_actual: bool) {
        let entry = self.fns.entry(name.to_string()).or_default();
        if expect_or_actual {
            let key = describe_params(&sig.params);
            if entry
                .iter()
                .any(|e| e.params.len() == sig.params.len() && describe_params(&e.params) == key)
            {
                return;
            }
        }
        entry.push(sig);
    }

    pub(crate) fn signature_of(&self, f: &Function) -> FnSig {
        let tparams: std::collections::HashSet<String> =
            f.type_params.iter().map(|tp| tp.name.name.clone()).collect();
        let mut params = Vec::with_capacity(f.params.len());
        let mut has_default = Vec::with_capacity(f.params.len());
        let mut names = Vec::with_capacity(f.params.len());
        let mut is_vararg = Vec::with_capacity(f.params.len());
        for p in &f.params {
            params.push(convert_type_ref_with_tparams(&p.ty, &tparams));
            has_default.push(p.default.is_some());
            names.push(p.name.name.clone());
            is_vararg.push(p.is_vararg);
        }
        let return_ty = f
            .return_type
            .as_ref()
            .map(|rt| convert_type_ref_with_tparams(rt, &tparams))
            .unwrap_or(Type::Unit);
        let param_class_names: Vec<Option<String>> =
            f.params.iter().map(|p| class_name_from_typeref(&p.ty)).collect();
        let (type_param_names, type_param_bounds) =
            Self::collect_type_param_bounds(&f.type_params, &f.where_bounds);
        let is_crossinline_param: Vec<bool> = if f.is_inline {
            f.params.iter().map(|p| p.is_crossinline).collect()
        } else {
            vec![false; f.params.len()]
        };
        FnSig {
            params,
            has_default,
            param_names: names,
            is_vararg,
            return_ty,
            is_infix: f.is_infix,
            type_param_count: f.type_params.len(),
            type_param_names,
            type_param_bounds,
            param_class_names,
            decl_span: Some(f.name.span),
            is_suspend: f.is_suspend,
            is_crossinline_param,
        }
    }

    pub(crate) fn class_info(&self, c: &Class) -> ClassInfo {
        let mut info = ClassInfo {
            is_abstract: c.is_abstract,
            is_interface: c.is_interface,
            is_sealed: c.is_sealed,
            is_enum: c.is_enum,
            is_open: c.is_open || c.is_abstract || c.is_sealed,
            has_secondary_ctors: !c.secondary_ctors.is_empty(),
            decl_visibility: c.visibility,
            decl_file: Some(c.name.span.file),
            primary_ctor_visibility: c.primary_ctor_visibility,
            ..ClassInfo::default()
        };
        // Primary ctor params that are properties become members.
        for p in &c.primary_params {
            let ty = convert_type_ref_lossy(&p.ty);
            if let Some(mutable) = p.property {
                info.members.insert(p.name.name.clone(), ty.clone());
                info.member_mutable.insert(p.name.name.clone(), mutable);
                info.concrete_members.push(p.name.name.clone());
                if let Some(cn) = class_name_from_typeref(&p.ty) {
                    info.member_class.insert(p.name.name.clone(), cn);
                }
                info.member_visibility.insert(p.name.name.clone(), p.visibility);
                info.member_sigs.insert(
                    p.name.name.clone(),
                    MemberSig::Property { ty: ty.clone(), mutable, visibility: p.visibility },
                );
            }
        }
        let (ctor_type_param_names, ctor_type_param_bounds) =
            Self::collect_type_param_bounds(&c.type_params, &c.where_bounds);
        let ctor_sig = FnSig {
            params: c
                .primary_params
                .iter()
                .map(|p| convert_type_ref_lossy(&p.ty))
                .collect(),
            has_default: c.primary_params.iter().map(|p| p.default.is_some()).collect(),
            param_names: c.primary_params.iter().map(|p| p.name.name.clone()).collect(),
            is_vararg: c.primary_params.iter().map(|_| false).collect(),
            return_ty: Type::Unresolved,
            is_infix: false,
            type_param_count: c.type_params.len(),
            type_param_names: ctor_type_param_names,
            type_param_bounds: ctor_type_param_bounds,
            param_class_names: c
                .primary_params
                .iter()
                .map(|p| class_name_from_typeref(&p.ty))
                .collect(),
            decl_span: None,
            is_suspend: false,
            is_crossinline_param: vec![false; c.primary_params.len()],
        };
        if !c.primary_params.is_empty() || !c.is_interface {
            info.ctor = Some(ctor_sig);
        }
        self.collect_members(&c.members, &mut info);
        info.type_param_names = c.type_params.iter().map(|tp| tp.name.name.clone()).collect();
        for s in &c.supertypes {
            info.supertypes.push(s.name.name.clone());
            let type_args: Vec<Type> = s
                .type_args
                .iter()
                .map(|ta| {
                    if ta.is_star {
                        Type::Unresolved
                    } else {
                        convert_type_ref_lossy(&ta.ty)
                    }
                })
                .collect();
            info.typed_supertypes.push((s.name.name.clone(), type_args));
        }
        info
    }

    /// GADT supertype walk: given a `subclass` and a `target` class
    /// name, find the type-arg list `subclass` declares for
    /// `target` in its supertype chain. Returns `Some(args)` when a
    /// match is found anywhere along the transitive supertype
    /// chain; `None` when the chain has no link to `target`.
    pub(crate) fn walk_supertype_args(&self, subclass: &str, target: &str) -> Option<Vec<Type>> {
        let info = self.classes.get(subclass)?;
        if subclass == target {
            return Some(
                info.type_param_names
                    .iter()
                    .map(|n| Type::TypeParam(n.clone()))
                    .collect(),
            );
        }
        for (s_name, s_args) in &info.typed_supertypes {
            if s_name == target {
                return Some(s_args.clone());
            }
            if let Some(deeper) = self.walk_supertype_args(s_name, target) {
                // Substitute the subclass's args into the deeper
                // result: if `subclass : Mid<X>` and
                // `Mid<X> : Target<f(X)>`, derive `Target<f(arg)>`
                // by replacing `X` in `deeper` with `s_args`.
                let mid_info = self.classes.get(s_name)?;
                let mut subst: HashMap<String, Type> = HashMap::new();
                for (name, arg) in mid_info.type_param_names.iter().zip(s_args.iter()) {
                    subst.insert(name.clone(), arg.clone());
                }
                let substituted: Vec<Type> = deeper
                    .iter()
                    .map(|t| substitute_type_params(t, &subst))
                    .collect();
                return Some(substituted);
            }
        }
        None
    }

    pub(crate) fn collect_members(&self, members: &[Decl], info: &mut ClassInfo) {
        for m in members {
            match m {
                Decl::Function(f) => {
                    let sig = self.signature_of(f);
                    info.member_sigs.insert(
                        f.name.name.clone(),
                        MemberSig::Function {
                            param_types: sig.params.clone(),
                            return_ty: sig.return_ty.clone(),
                            visibility: f.visibility,
                            is_suspend: f.is_suspend,
                        },
                    );
                    let ty = Type::Function {
                        params: sig.params,
                        return_type: Box::new(sig.return_ty),
                        is_suspend: f.is_suspend,
                    };
                    info.members.insert(f.name.name.clone(), ty);
                    if let Some(cn) = f.return_type.as_ref().and_then(class_name_from_typeref) {
                        info.member_class.insert(f.name.name.clone(), cn);
                    }
                    // Interface members and abstract members are implicitly
                    // `open` in Kotlin — record that here so subclass override
                    // diagnostics line up with kotlinc behavior.
                    let implicit_open =
                        info.is_interface || info.is_abstract || f.is_abstract;
                    info.member_flags.insert(
                        f.name.name.clone(),
                        MemberFlags {
                            is_open: f.is_open || implicit_open,
                            is_override: f.is_override,
                            is_abstract: f.is_abstract,
                            is_operator: f.is_operator,
                            is_infix: f.is_infix,
                            has_default_body: f.body.is_some() && !f.is_abstract,
                        },
                    );
                    if f.is_abstract {
                        info.abstract_members.push(f.name.name.clone());
                    } else {
                        info.concrete_members.push(f.name.name.clone());
                    }
                    info.member_visibility.insert(f.name.name.clone(), f.visibility);
                }
                Decl::Property(p) => {
                    let ty = p
                        .ty
                        .as_ref()
                        .map(convert_type_ref_lossy)
                        .unwrap_or(Type::Unresolved);
                    info.member_sigs.insert(
                        p.name.name.clone(),
                        MemberSig::Property {
                            ty: ty.clone(),
                            mutable: p.mutable,
                            visibility: p.visibility,
                        },
                    );
                    info.members.insert(p.name.name.clone(), ty);
                    info.member_mutable.insert(p.name.name.clone(), p.mutable);
                    if let Some(cn) = p.ty.as_ref().and_then(class_name_from_typeref) {
                        info.member_class.insert(p.name.name.clone(), cn);
                    }
                    let implicit_open =
                        info.is_interface || info.is_abstract || p.is_abstract || p.is_override;
                    info.member_flags.insert(
                        p.name.name.clone(),
                        MemberFlags {
                            is_open: p.is_open || implicit_open,
                            is_override: p.is_override,
                            is_abstract: p.is_abstract,
                            is_operator: false,
                            is_infix: false,
                            has_default_body: false,
                        },
                    );
                    if p.is_abstract {
                        info.abstract_members.push(p.name.name.clone());
                    } else {
                        info.concrete_members.push(p.name.name.clone());
                    }
                    info.member_visibility.insert(p.name.name.clone(), p.visibility);
                }
                Decl::Class(_) | Decl::Object(_) | Decl::TypeAlias(_) => {}
            }
        }
    }

    // ---- decl bodies -----------------------------------------------------

    pub(crate) fn check_decl(&mut self, decl: &Decl) {
        match decl {
            Decl::Function(f) => self.check_function(f),
            Decl::Property(p) => self.check_top_level_property(p),
            Decl::Class(c) => self.check_class(c),
            Decl::Object(o) => self.check_object(o),
            Decl::TypeAlias(_) => {}
        }
    }

    pub(crate) fn check_top_level_property(&mut self, p: &Property) {
        if let Some(init) = &p.init {
            let annot = p.ty.as_ref().map(convert_type_ref_lossy);
            let init_ty = self.check_expr(init, annot.as_ref());
            if let Some(annot) = annot {
                self.check_assignable(&init_ty, &annot, init.span());
            } else {
                // Infer from initializer.
                if let Some(b) = self.frames[0].bindings.get_mut(&p.name.name) {
                    if matches!(b.ty, Type::Unresolved) {
                        b.ty = init_ty;
                    }
                }
            }
        }
        if let Some(d) = &p.delegate {
            self.check_expr(d, None);
            self.check_delegate_operator(p, d);
        }
        self.check_lateinit(p);
        self.check_accessor_return_types(p);
    }

    /// Spec ch.9: validate the signature of an `operator fun` declaration
    /// against its name. Each well-known operator name has a fixed shape
    /// (arity / return type). Extensions add an implicit receiver "slot"
    /// to the conceptual arity; user param count is one less than for a
    /// member with the equivalent operator semantics. T0088 is a warning
    /// so existing programs keep running while authors fix shapes.
    pub(crate) fn check_operator_signature(&mut self, f: &Function) {
        if !f.is_operator {
            return;
        }
        if f.is_suspend
            && matches!(
                f.name.name.as_str(),
                "getValue" | "setValue" | "provideDelegate"
            )
        {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!(
                        "delegation operator `{}` cannot be `suspend`",
                        f.name.name
                    ),
                    f.name.span,
                )
                .with_code(codes::TYPE_SUSPEND_NOT_ALLOWED),
            );
        }
        let is_extension = f.receiver_type.is_some();
        let extra_receiver: usize = if is_extension { 0 } else { 0 };
        let _ = extra_receiver;
        let n = f.params.len();
        let name = f.name.name.as_str();
        // For each name, the expected user-param count is what a member
        // form would declare. Extensions match the same shape; the
        // receiver is the LHS.
        let (expected, returns_bool, returns_int): (Option<&str>, bool, bool) = match name {
            "inc" | "dec" => (Some("0 args"), false, false),
            "unaryPlus" | "unaryMinus" | "not" => (Some("0 args"), false, false),
            "iterator" | "hasNext" | "next" => {
                let rb = name == "hasNext";
                (Some("0 args"), rb, false)
            }
            "plus" | "minus" | "times" | "div" | "rem"
            | "rangeTo" | "rangeUntil" => (Some("1 arg"), false, false),
            "plusAssign" | "minusAssign" | "timesAssign" | "divAssign" | "remAssign" => {
                (Some("1 arg"), false, false)
            }
            "compareTo" => (Some("1 arg"), false, true),
            "contains" => (Some("1 arg"), true, false),
            "equals" => (Some("1 arg"), true, false),
            "get" => {
                // ≥1 user arg.
                if n < 1 {
                    self.emit_op_sig(f, "`get` operator requires at least 1 argument");
                }
                (None, false, false)
            }
            "set" => {
                // ≥2 user args.
                if n < 2 {
                    self.emit_op_sig(f, "`set` operator requires at least 2 arguments (last is the value)");
                }
                (None, false, false)
            }
            "invoke" => (None, false, false),
            "componentN" => (None, false, false),
            "provideDelegate" => (Some("2 args"), false, false),
            "getValue" => (Some("2 args"), false, false),
            "setValue" => (Some("3 args"), false, false),
            _ => {
                // componentN: digits after "component"
                if let Some(rest) = name.strip_prefix("component") {
                    if !rest.is_empty() && rest.chars().all(|c| c.is_ascii_digit()) {
                        if n != 0 {
                            self.emit_op_sig(f, &format!("`{name}` operator must take no arguments"));
                        }
                    }
                }
                (None, false, false)
            }
        };
        if let Some(shape) = expected {
            let want: usize = match shape {
                "0 args" => 0,
                "1 arg" => 1,
                "2 args" => 2,
                "3 args" => 3,
                _ => return,
            };
            if n != want {
                self.emit_op_sig(
                    f,
                    &format!("`{name}` operator must take exactly {shape}, got {n}"),
                );
            }
        }
        if returns_bool {
            if let Some(rt) = &f.return_type {
                let ty = convert_type_ref_lossy(rt);
                if !matches!(ty.non_null(), Type::Boolean | Type::Unresolved) {
                    self.emit_op_sig(f, &format!("`{name}` operator must return Boolean"));
                }
            }
        }
        if returns_int {
            if let Some(rt) = &f.return_type {
                let ty = convert_type_ref_lossy(rt);
                if !matches!(ty.non_null(), Type::Int | Type::Unresolved) {
                    self.emit_op_sig(f, &format!("`{name}` operator must return Int"));
                }
            }
        }
    }

    /// Head name of a type reference — i.e. the top-level classifier name,
    /// ignoring generic args. F-bounded forms like `T : Comparable<T>` are
    /// not cycles; only an edge through the *head* of a bound counts.
    pub(crate) fn head_name(t: &TypeRef) -> &str {
        &t.name.name
    }

    /// Detects cycles in the type-parameter bound graph for a declaration.
    /// An edge `T -> U` exists when any bound on `T` (either the inline
    /// `upper_bound` or a `where T : ...` entry) mentions `U`. A bare
    /// self-reference (`T : T`) and a longer cycle (`T : U, U : T`) both
    /// trip the diagnostic. Emits at most one diagnostic per declaration
    /// at the first offending type-param site.
    pub(crate) fn check_circular_bounds(
        &mut self,
        type_params: &[TypeParam],
        where_bounds: &[WhereBound],
    ) {
        if type_params.is_empty() {
            return;
        }
        let tp_set: std::collections::HashSet<&str> =
            type_params.iter().map(|tp| tp.name.name.as_str()).collect();
        let mut graph: std::collections::HashMap<String, Vec<String>> =
            std::collections::HashMap::new();
        let mut spans: std::collections::HashMap<String, Span> = std::collections::HashMap::new();
        for tp in type_params {
            spans.insert(tp.name.name.clone(), tp.name.span);
            graph.entry(tp.name.name.clone()).or_default();
            if let Some(b) = &tp.upper_bound {
                let head = Self::head_name(b);
                if tp_set.contains(head) {
                    graph
                        .entry(tp.name.name.clone())
                        .or_default()
                        .push(head.to_string());
                }
            }
        }
        for wb in where_bounds {
            if !tp_set.contains(wb.name.name.as_str()) {
                continue;
            }
            let head = Self::head_name(&wb.bound);
            if tp_set.contains(head) {
                graph
                    .entry(wb.name.name.clone())
                    .or_default()
                    .push(head.to_string());
            }
        }
        // Tarjan-lite: DFS, mark gray/black, any back-edge to gray is a cycle.
        let mut color: std::collections::HashMap<String, u8> =
            std::collections::HashMap::new();
        for tp in type_params {
            if color.get(&tp.name.name).copied().unwrap_or(0) != 0 {
                continue;
            }
            if let Some(start) =
                Self::find_cycle_dfs(&tp.name.name, &graph, &mut color)
            {
                let sp = spans.get(&start).copied().unwrap_or(tp.name.span);
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!(
                            "type parameter `{start}` has a circular bound",
                        ),
                        sp,
                    )
                    .with_code(codes::TYPE_CIRCULAR_TYPE_BOUND),
                );
                return;
            }
        }
    }

    pub(crate) fn find_cycle_dfs(
        node: &str,
        graph: &std::collections::HashMap<String, Vec<String>>,
        color: &mut std::collections::HashMap<String, u8>,
    ) -> Option<String> {
        color.insert(node.to_string(), 1);
        if let Some(succs) = graph.get(node) {
            for s in succs {
                match color.get(s).copied().unwrap_or(0) {
                    1 => return Some(s.clone()),
                    0 => {
                        if let Some(c) = Self::find_cycle_dfs(s, graph, color) {
                            return Some(c);
                        }
                    }
                    _ => {}
                }
            }
        }
        color.insert(node.to_string(), 2);
        None
    }

    /// Validates that each user-supplied explicit type argument satisfies
    /// the declared upper bounds of the corresponding type parameter.
    /// Builds a substitution `param_name -> supplied Type` and substitutes
    /// it into each bound before the subtype check so an F-bounded form
    /// like `<T : Comparable<T>>` lowers correctly. Emits T0022 once per
    /// failing pair.
    pub(crate) fn check_type_arg_bounds(&mut self, sig: &FnSig, type_args: &[TypeRef]) {
        if type_args.len() != sig.type_param_count || sig.type_param_bounds.is_empty() {
            return;
        }
        let supplied: Vec<Type> =
            type_args.iter().map(convert_type_ref_lossy).collect();
        let mut subst: std::collections::HashMap<String, Type> =
            std::collections::HashMap::new();
        for (i, name) in sig.type_param_names.iter().enumerate() {
            if let Some(ty) = supplied.get(i) {
                subst.insert(name.clone(), ty.clone());
            }
        }
        for (i, bounds) in sig.type_param_bounds.iter().enumerate() {
            if bounds.is_empty() {
                continue;
            }
            let arg_ty = match supplied.get(i) {
                Some(t) => t,
                None => continue,
            };
            for b in bounds {
                let bound = substitute_type_params(b, &subst);
                if matches!(bound, Type::Unresolved) {
                    continue;
                }
                if !arg_ty.is_subtype_of(&bound) {
                    let sp = type_args[i].span;
                    self.diagnostics.emit(
                        Diagnostic::error(
                            format!(
                                "type argument `{arg_ty}` does not satisfy upper bound `{bound}` on `{}`",
                                sig.type_param_names[i]
                            ),
                            sp,
                        )
                        .with_code(codes::TYPE_BOUND_NOT_SATISFIED),
                    );
                    break;
                }
            }
        }
    }

    pub(crate) fn emit_op_sig(&mut self, f: &Function, msg: &str) {
        self.diagnostics.emit(
            Diagnostic::warning(msg.to_string(), f.name.span)
                .with_code(codes::TYPE_OPERATOR_SIGNATURE_MISMATCH),
        );
    }

    pub(crate) fn check_function(&mut self, f: &Function) {
        self.check_inline_param_escape(f);
        self.check_anonymous_object_escape(f);
        self.check_operator_signature(f);
        self.check_circular_bounds(&f.type_params, &f.where_bounds);
        self.push_frame();
        for p in &f.params {
            let ty = convert_type_ref_lossy(&p.ty);
            let cn = class_name_from_typeref(&p.ty);
            let decl_type_name = if klio_types::builtin_by_name(&p.ty.name.name).is_none() {
                Some(p.ty.name.name.clone())
            } else {
                None
            };
            self.current_frame()
                .bindings
                .insert(p.name.name.clone(), Binding { ty, mutable: false, decl_span: Some(p.name.span), class_name: cn, decl_type_name });
            if let Some(default) = &p.default {
                let dty = self.check_expr(default, Some(&convert_type_ref_lossy(&p.ty)));
                self.check_assignable(&dty, &convert_type_ref_lossy(&p.ty), default.span());
            }
        }
        let declared_return = f
            .return_type
            .as_ref()
            .map(convert_type_ref_lossy)
            .unwrap_or(Type::Unit);
        self.fn_return_stack.push(declared_return.clone());
        self.label_stack.push(f.name.name.clone());
        let is_public_inline = f.is_inline && matches!(f.visibility, Visibility::Public);
        self.public_inline_stack.push(is_public_inline);
        self.suspend_context_stack.push(f.is_suspend);
        let reified = f
            .type_params
            .iter()
            .filter(|tp| tp.is_reified)
            .map(|tp| tp.name.name.clone())
            .collect::<std::collections::HashSet<_>>();
        self.reified_type_params.push(reified);
        let all_tps = f
            .type_params
            .iter()
            .map(|tp| tp.name.name.clone())
            .collect::<std::collections::HashSet<_>>();
        self.type_params_in_scope.push(all_tps);
        if let Some(body) = &f.body {
            // Build a CFG for the body alongside type checking. The
            // lowering's side tables (span_to_pos, aliases) feed the
            // smart-cast read sites once they switch over.
            let body_block = match body {
                FunctionBody::Block(b) => b.clone(),
                FunctionBody::Expr(e) => Block { stmts: vec![Stmt::Expr(e.clone())], span: e.span() },
            };
            let mut lowered = klio_cfa::lower::lower_function(&body_block, f.span);
            klio_cfa::dataflow::infer_kill_data_flow(&mut lowered.cfg);
            self.cfgs.insert(f.span, lowered.cfg.clone());
            self.lowerings
                .insert(f.span, std::rc::Rc::new(lowered));
            self.cfg_fn_stack.push(f.span);
            match body {
                FunctionBody::Block(b) => {
                    let body_ty = self.check_block(b, Some(&declared_return));
                    // Block-body functions with a declared non-`Unit` /
                    // non-`Nothing` return require every path to
                    // terminate in `return` / `throw` / divergence.
                    // Defer to the CFG: if the normal-completion block
                    // is unreachable (the body always throws, calls a
                    // `Nothing`-returning function such as `error(..)`
                    // or atomicfu's `loop`, or loops forever) no
                    // `return` is required — Kotlin's post-control-
                    // flow rule. `check_block` has now populated the
                    // expression types the type-aware pass consults.
                    let normal_exit_reachable = {
                        let type_map: std::collections::HashMap<(u32, u32), Type> = self
                            .types
                            .iter()
                            .map(|(s, t)| ((s.start, s.end), t.clone()))
                            .collect();
                        match self.lowerings.get(&f.span) {
                            Some(low) => {
                                let r = klio_cfa::analyses::reachable::analyse_with_types(
                                    &low.cfg,
                                    Some(&type_map),
                                );
                                low.cfg.exits.is_empty()
                                    || low.cfg.exits.iter().any(|e| r.is_reachable(*e))
                            }
                            None => true,
                        }
                    };
                    if !f.is_abstract
                        && f.return_type.is_some()
                        && !matches!(declared_return, Type::Unit | Type::Nothing | Type::Unresolved)
                        && !matches!(body_ty, Type::Nothing)
                        && normal_exit_reachable
                    {
                        let span = b.stmts.last().map(stmt_span).unwrap_or(f.name.span);
                        self.diagnostics.emit(
                            Diagnostic::error(
                                "a 'return' expression is required in a function with a block body and a non-`Unit` return type".to_string(),
                                span,
                            )
                            .with_code(codes::TYPE_MISSING_RETURN),
                        );
                    }
                }
                FunctionBody::Expr(e) => {
                    let ety = self.check_expr(e, Some(&declared_return));
                    if f.return_type.is_some() && !matches!(declared_return, Type::Unit) {
                        self.check_assignable(&ety, &declared_return, e.span());
                    }
                }
            }
        }
        self.fn_return_stack.pop();
        self.label_stack.pop();
        self.public_inline_stack.pop();
        self.suspend_context_stack.pop();
        self.reified_type_params.pop();
        self.type_params_in_scope.pop();
        self.pop_frame();
        if f.body.is_some() {
            self.cfg_fn_stack.pop();
        }
    }

    pub(crate) fn check_class(&mut self, c: &Class) {
        self.class_stack.push(c.name.name.clone());
        // Track class type parameters in the same scope as function type
        // params so spec §15 checks (`is T`, `T::class`, etc.) can see
        // them. Class type params are never `reified` per spec §13, so we
        // only push into `type_params_in_scope`; the `reified_type_params`
        // stack receives an empty set to keep depth in lock-step.
        let class_tps = c
            .type_params
            .iter()
            .map(|tp| tp.name.name.clone())
            .collect::<std::collections::HashSet<_>>();
        self.type_params_in_scope.push(class_tps);
        self.reified_type_params.push(std::collections::HashSet::new());
        self.check_circular_bounds(&c.type_params, &c.where_bounds);
        // Spec §5.1: data, enum, and annotation classes are always closed
        // and cannot be declared `open`, `abstract`, or `sealed`.
        // `value` / `annotation` shape checks fire their own diagnostics.
        if c.is_data || c.is_enum {
            let kind = if c.is_data { "data" } else { "enum" };
            for (is_set, mod_name) in [
                (c.is_open, "open"),
                (c.is_abstract, "abstract"),
                (c.is_sealed, "sealed"),
            ] {
                if is_set {
                    self.diagnostics.emit(
                        Diagnostic::error(
                            format!(
                                "`{kind} class {}` cannot be declared `{mod_name}`",
                                c.name.name
                            ),
                            c.name.span,
                        )
                        .with_code(codes::TYPE_DATA_OR_ENUM_CLASS_OPEN_OR_ABSTRACT),
                    );
                }
            }
        }
        // Spec §4.1.1: secondary constructor delegation must not form a
        // cycle. Match `this(args)` to a secondary constructor by argument
        // arity (a permissive over-approximation; primary-ctor delegation
        // terminates the chain since the primary cannot delegate further).
        if !c.secondary_ctors.is_empty() {
            let n = c.secondary_ctors.len();
            // Outgoing edges: for each ctor, indices of ctors it might
            // delegate to via `this(args)` of matching arity.
            let mut edges: Vec<Vec<usize>> = vec![Vec::new(); n];
            for (i, sc) in c.secondary_ctors.iter().enumerate() {
                if let CtorDelegation::This(args) = &sc.delegation {
                    let arity = args.len();
                    for (j, other) in c.secondary_ctors.iter().enumerate() {
                        if other.params.len() == arity {
                            edges[i].push(j);
                        }
                    }
                }
            }
            // DFS from each ctor; flag if it reaches itself through a
            // chain composed entirely of secondary-to-secondary edges.
            for start in 0..n {
                let mut stack = vec![start];
                let mut seen = vec![false; n];
                let mut hit_self = false;
                while let Some(cur) = stack.pop() {
                    for &nx in &edges[cur] {
                        if nx == start {
                            hit_self = true;
                            break;
                        }
                        if !seen[nx] {
                            seen[nx] = true;
                            stack.push(nx);
                        }
                    }
                    if hit_self {
                        break;
                    }
                }
                if hit_self {
                    self.diagnostics.emit(
                        Diagnostic::error(
                            format!(
                                "secondary constructor of `{}` participates in a delegation \
                                 cycle",
                                c.name.name
                            ),
                            c.secondary_ctors[start].span,
                        )
                        .with_code(codes::TYPE_CONSTRUCTOR_DELEGATION_CYCLE),
                    );
                }
            }
        }
        // Spec §4.1.2: `data class` shape — must have ≥1 property param,
        // and no vararg property param.
        if c.is_data {
            let n_props = c.primary_params.iter().filter(|p| p.property.is_some()).count();
            if n_props == 0 {
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!(
                            "data class `{}` must declare at least one primary-constructor \
                             property",
                            c.name.name
                        ),
                        c.name.span,
                    )
                    .with_code(codes::TYPE_DATA_CLASS_NO_PROPERTIES),
                );
            }
            for p in &c.primary_params {
                if p.is_vararg && p.property.is_some() {
                    self.diagnostics.emit(
                        Diagnostic::error(
                            format!(
                                "data class `{}` cannot declare a `vararg` property parameter",
                                c.name.name
                            ),
                            p.span,
                        )
                        .with_code(codes::TYPE_DATA_CLASS_VARARG_PROPERTY),
                    );
                }
            }
        }
        // Spec §4.1.2: `data class` cannot explicify `copy` or `componentN`.
        if c.is_data {
            let n_props = c.primary_params.iter().filter(|p| p.property.is_some()).count();
            for m in &c.members {
                if let Decl::Function(f) = m {
                    let n = f.name.name.as_str();
                    if n == "copy" {
                        self.diagnostics.emit(
                            Diagnostic::error(
                                format!(
                                    "`copy` is auto-generated for data class `{}` and cannot be \
                                     explicified",
                                    c.name.name
                                ),
                                f.name.span,
                            )
                            .with_code(codes::TYPE_DATA_CLASS_FORBIDS_COPY_OVERRIDE),
                        );
                    } else if let Some(rest) = n.strip_prefix("component") {
                        if let Ok(idx) = rest.parse::<usize>() {
                            if idx >= 1 && idx <= n_props && f.params.is_empty() {
                                self.diagnostics.emit(
                                    Diagnostic::error(
                                        format!(
                                            "`{}` is auto-generated for data class `{}` and cannot \
                                             be explicified",
                                            n, c.name.name
                                        ),
                                        f.name.span,
                                    )
                                    .with_code(
                                        codes::TYPE_DATA_CLASS_FORBIDS_COMPONENT_OVERRIDE,
                                    ),
                                );
                            }
                        }
                    }
                }
            }
        }
        // Spec §3.9: `kotlin.Enum<T>` declares `equals`, `hashCode`, and
        // `compareTo` as `final`. User-declared enum entries cannot override
        // them. `toString` remains overridable.
        if c.is_enum {
            for m in &c.members {
                if let Decl::Function(f) = m {
                    let n = f.name.name.as_str();
                    if (n == "equals" || n == "hashCode" || n == "compareTo") && f.is_override
                    {
                        self.diagnostics.emit(
                            Diagnostic::error(
                                format!(
                                    "`{}` is `final` on `kotlin.Enum` and cannot be overridden \
                                     (enum class `{}`)",
                                    n, c.name.name
                                ),
                                f.name.span,
                            )
                            .with_code(codes::TYPE_ENUM_FORBIDS_FINAL_OVERRIDE),
                        );
                    }
                }
            }
        }
        // Spec §3.12: subtypes of `kotlin.Throwable` cannot have type
        // parameters. Walk the transitive supertype chain looking for any
        // built-in or user-declared Throwable ancestor.
        if !c.type_params.is_empty() && self.is_throwable_subtype(c) {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!(
                        "Subclasses of `kotlin.Throwable` cannot declare type parameters; \
                         `{}` does",
                        c.name.name
                    ),
                    c.name.span,
                )
                .with_code(codes::TYPE_THROWABLE_TYPE_PARAMS),
            );
        }
        // Spec §5.4: `private` is mutually exclusive with `open`,
        // `abstract`, and `override` on a member declaration.
        for m in &c.members {
            match m {
                Decl::Function(f) => {
                    if matches!(f.visibility, Visibility::Private) {
                        self.check_private_open_or_override(
                            &f.name.name,
                            f.name.span,
                            f.is_open,
                            f.is_abstract,
                            f.is_override,
                        );
                    }
                }
                Decl::Property(p) => {
                    if matches!(p.visibility, Visibility::Private) {
                        self.check_private_open_or_override(
                            &p.name.name,
                            p.name.span,
                            false,
                            p.is_abstract,
                            p.is_override,
                        );
                    }
                }
                _ => {}
            }
        }
        // Spec §5.1: supertype validity. A class may inherit from at most
        // one class (open / abstract / sealed) plus any number of
        // interfaces. Inheriting from a closed (default-final) class or
        // from an `object` type is a compile-time error.
        self.check_supertype_validity(&c.name.name, &c.supertypes);
        // Soft override diagnostics — walk parents and interfaces, gather
        // their (name, MemberFlags) table, and compare against this class's
        // members. Diagnostics here are not fatal; they surface intent
        // mismatches between subclass and supertype declarations.
        let mut inherited = self.collect_inherited_member_flags(c);
        // Spec §5.1.3: function-type supertypes act like interfaces — they
        // contribute an abstract `invoke` slot. Inject it so the
        // override-walk accepts `override fun invoke(...)`.
        {
            let mut sigs_tmp: HashMap<String, MemberSig> = HashMap::new();
            self.inject_function_type_supertypes(c, &mut inherited, &mut sigs_tmp);
        }
        // A supertype whose declaration is not visible to this
        // type-check unit (e.g. an interface from the embedded stdlib
        // like `kotlin.coroutines.Continuation`) may legitimately
        // declare the overridden member. Don't false-positive
        // "overrides nothing" when such an opaque supertype is
        // present.
        let has_opaque_supertype = c.supertypes.iter().any(|s| {
            s.function.is_none()
                && !self.classes.contains_key(&s.name.name)
        });
        for m in &c.members {
            let (mname, mspan, mflags) = match m {
                Decl::Function(f) => (
                    &f.name.name,
                    f.name.span,
                    MemberFlags {
                        is_open: f.is_open,
                        is_override: f.is_override,
                        is_abstract: f.is_abstract,
                        is_operator: f.is_operator,
                        is_infix: f.is_infix,
                        has_default_body: f.body.is_some() && !f.is_abstract,
                    },
                ),
                Decl::Property(p) => (
                    &p.name.name,
                    p.name.span,
                    MemberFlags {
                        is_open: p.is_open || p.is_override || p.is_abstract,
                        is_override: p.is_override,
                        is_abstract: p.is_abstract,
                        is_operator: false,
                        is_infix: false,
                        has_default_body: false,
                    },
                ),
                _ => continue,
            };
            match inherited.get(mname).copied() {
                Some(parent_flags) => {
                    // Member exists in a parent.
                    if mflags.is_override {
                        // Parent must be open / abstract for the override
                        // to be legitimate. Suppressed when an opaque
                        // (unresolved, e.g. embedded-stdlib / cross-file
                        // pack) supertype is present: the member may be
                        // declared there as an implicitly-open interface
                        // member (upstream `Deferred.await`), which this
                        // unit cannot see.
                        if !(parent_flags.is_open || parent_flags.is_abstract)
                            && !has_opaque_supertype
                        {
                            self.diagnostics.emit(
                                Diagnostic::error(
                                    format!(
                                        "`{mname}` overrides nothing — parent member is not `open`"
                                    ),
                                    mspan,
                                )
                                .with_code(codes::TYPE_OVERRIDE_BUT_PARENT_NOT_OPEN),
                            );
                        }
                    } else {
                        // No `override`, but a same-name parent member is
                        // open / abstract — Kotlin requires the modifier.
                        if parent_flags.is_open || parent_flags.is_abstract {
                            self.diagnostics.emit(
                                Diagnostic::error(
                                    format!(
                                        "`{mname}` hides a member from a supertype; add `override` modifier"
                                    ),
                                    mspan,
                                )
                                .with_code(codes::TYPE_OVERRIDE_NEEDED),
                            );
                        }
                    }
                }
                None => {
                    if mflags.is_override
                        && !is_builtin_overridable(mname)
                        && !has_opaque_supertype
                    {
                        self.diagnostics.emit(
                            Diagnostic::error(
                                format!(
                                    "`{mname}` is marked `override` but does not override any supertype member"
                                ),
                                mspan,
                            )
                            .with_code(codes::TYPE_OVERRIDE_BUT_NO_BASE),
                        );
                    }
                }
            }
        }
        // Spec §5.4 override-rule diagnostics — for every member declared
        // with `override`, locate the matching base member by name and
        // verify return-type / property-type / mutability / visibility.
        let mut inherited_sigs = self.collect_inherited_member_sigs(c);
        self.inject_function_type_supertypes(c, &mut inherited, &mut inherited_sigs);
        for m in &c.members {
            match m {
                Decl::Function(f) if f.is_override => {
                    if let Some(MemberSig::Function {
                        return_ty: base_ret,
                        visibility: base_vis,
                        is_suspend: base_suspend,
                        ..
                    }) = inherited_sigs.get(&f.name.name)
                    {
                        if *base_suspend != f.is_suspend {
                            let msg = if f.is_suspend {
                                format!(
                                    "override `{name}` is `suspend` but the overridden function is not",
                                    name = f.name.name
                                )
                            } else {
                                format!(
                                    "override `{name}` is not `suspend` but the overridden function is",
                                    name = f.name.name
                                )
                            };
                            self.diagnostics.emit(
                                Diagnostic::error(msg, f.name.span)
                                    .with_code(codes::TYPE_OVERRIDE_SUSPEND_MISMATCH),
                            );
                        }
                        // Only check when both ends have explicit return
                        // types — an omitted return type on an expression
                        // body is inferred and may legitimately resolve to
                        // the base's type.
                        let derived_ret = f.return_type.as_ref().map(convert_type_ref_lossy);
                        let check_ret = derived_ret
                            .as_ref()
                            .map(|d| !d.is_subtype_of(base_ret))
                            .unwrap_or(false);
                        if check_ret {
                            let derived_ret = derived_ret.unwrap();
                            self.diagnostics.emit(
                                Diagnostic::error(
                                    format!(
                                        "return type `{derived_ret}` of override `{name}` \
                                         is not a subtype of overridden return type `{base_ret}`",
                                        name = f.name.name
                                    ),
                                    f.name.span,
                                )
                                .with_code(codes::TYPE_OVERRIDE_RETURN_TYPE_MISMATCH),
                            );
                        }
                        self.check_override_visibility(
                            &f.name.name,
                            f.name.span,
                            f.visibility,
                            *base_vis,
                        );
                    }
                }
                Decl::Property(p) if p.is_override => {
                    if let Some(MemberSig::Property {
                        ty: base_ty,
                        mutable: base_mut,
                        visibility: base_vis,
                    }) = inherited_sigs.get(&p.name.name)
                    {
                        let derived_ty = p
                            .ty
                            .as_ref()
                            .map(convert_type_ref_lossy)
                            .unwrap_or(Type::Unresolved);
                        // T0066: mutability cannot strengthen. var base + val
                        // override is forbidden (val is stronger than var).
                        if *base_mut && !p.mutable {
                            self.diagnostics.emit(
                                Diagnostic::error(
                                    format!(
                                        "property `{name}` overrides `var` base with `val`: \
                                         mutability cannot strengthen",
                                        name = p.name.name
                                    ),
                                    p.name.span,
                                )
                                .with_code(codes::TYPE_OVERRIDE_PROPERTY_MUTABILITY),
                            );
                        }
                        // T0067: type subtype, except both `var` requires
                        // equivalent types.
                        let type_ok = if *base_mut && p.mutable {
                            derived_ty == *base_ty
                                || matches!(derived_ty, Type::Unresolved)
                                || matches!(base_ty, Type::Unresolved)
                        } else {
                            derived_ty.is_subtype_of(base_ty)
                        };
                        if !type_ok {
                            let msg = if *base_mut && p.mutable {
                                format!(
                                    "property `{}` overrides `var` base of type `{base_ty}` with \
                                     non-equivalent type `{derived_ty}`",
                                    p.name.name
                                )
                            } else {
                                format!(
                                    "type `{derived_ty}` of override property `{}` is not a \
                                     subtype of overridden type `{base_ty}`",
                                    p.name.name
                                )
                            };
                            self.diagnostics.emit(
                                Diagnostic::error(msg, p.name.span)
                                    .with_code(codes::TYPE_OVERRIDE_PROPERTY_TYPE),
                            );
                        }
                        self.check_override_visibility(
                            &p.name.name,
                            p.name.span,
                            p.visibility,
                            *base_vis,
                        );
                    }
                }
                _ => {}
            }
        }
        // Abstract-member check for concrete classes inheriting from one
        // of our user-defined abstract/interface classes.
        if !c.is_abstract && !c.is_interface {
            let mut required: Vec<String> = Vec::new();
            for (i, s) in c.supertypes.iter().enumerate() {
                // Delegated interfaces have synthesized forwarders; the
                // abstract slots are satisfied by the delegate at runtime.
                let is_delegated = matches!(c.supertype_delegates.get(i), Some(Some(_)));
                if is_delegated {
                    continue;
                }
                if let Some(parent) = self.classes.get(&s.name.name) {
                    if parent.is_abstract || parent.is_interface {
                        for am in &parent.abstract_members {
                            required.push(am.clone());
                        }
                    }
                }
            }
            if !required.is_empty() {
                let info = self.classes.get(&c.name.name).cloned().unwrap_or_default();
                let provided: std::collections::HashSet<&String> =
                    info.concrete_members.iter().collect();
                let missing: Vec<&String> = required.iter().filter(|n| !provided.contains(n)).collect();
                if !missing.is_empty() {
                    let names: Vec<String> = missing.iter().map(|s| (*s).clone()).collect();
                    self.diagnostics.emit(
                        Diagnostic::error(
                            format!(
                                "Class `{}` is not abstract and does not implement abstract member(s): {}",
                                c.name.name,
                                names.join(", ")
                            ),
                            c.name.span,
                        )
                        .with_code(codes::TYPE_ABSTRACT_MEMBER_NOT_IMPLEMENTED),
                    );
                }
            }
        }

        // Diamond inheritance: for each member name, count distinct
        // supertypes that supply a default body. If 2+ supertypes provide
        // a default for the same name and this class does not declare an
        // explicit `override`, Kotlin requires an explicit disambiguation.
        if !c.is_interface {
            let providers = self.collect_default_providers(c);
            let class_overrides: std::collections::HashSet<&str> = c
                .members
                .iter()
                .filter_map(|m| match m {
                    Decl::Function(f) if f.is_override => Some(f.name.name.as_str()),
                    Decl::Property(p) if p.is_override => Some(p.name.name.as_str()),
                    _ => None,
                })
                .collect();
            for (member, supplying) in &providers {
                // Filter out suppliers shadowed by another supplier that is
                // a (transitive) subtype — a subclass's override hides the
                // parent's default, so only "leaf" suppliers conflict.
                let leaves: Vec<&(String, bool)> = supplying
                    .iter()
                    .filter(|(s, _)| {
                        !supplying
                            .iter()
                            .any(|(other, _)| other != s && self.is_subtype_of(other, s))
                    })
                    .collect();
                if leaves.is_empty() {
                    continue;
                }
                let concrete_leaves: Vec<&String> =
                    leaves.iter().filter(|(_, c)| *c).map(|(s, _)| s).collect();
                let abstract_leaves: Vec<&String> =
                    leaves.iter().filter(|(_, c)| !*c).map(|(s, _)| s).collect();
                // Spec §5.3 cases that require explicit override:
                //   - 2+ concrete leaves (classic diamond);
                //   - ≥1 concrete and ≥1 abstract leaf from distinct ancestors.
                // Pure-abstract conflicts are covered by T0007 elsewhere.
                let needs_override = concrete_leaves.len() >= 2
                    || (!concrete_leaves.is_empty() && !abstract_leaves.is_empty());
                if !needs_override {
                    continue;
                }
                if class_overrides.contains(member.as_str()) {
                    continue;
                }
                let names = leaves
                    .iter()
                    .map(|(s, _)| s.as_str())
                    .collect::<Vec<_>>()
                    .join(", ");
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!(
                            "Class `{}` inherits conflicting members for `{member}` from supertypes ({names}); explicit `override` required",
                            c.name.name
                        ),
                        c.name.span,
                    )
                    .with_code(codes::TYPE_DIAMOND_CONFLICT),
                );
            }
        }

        // `lateinit` compile-time rules. Runtime correctness is handled in
        // the interpreter; here we reject the four illegal shapes.
        for m in &c.members {
            if let Decl::Property(p) = m {
                self.check_lateinit(p);
            }
        }

        // Accessor return-type annotation: enforce match against the
        // property's declared type when both are present.
        for m in &c.members {
            if let Decl::Property(p) = m {
                self.check_accessor_return_types(p);
            }
        }

        self.push_frame();
        // Bind primary-ctor params (and the `this` members for any param).
        for p in &c.primary_params {
            let ty = convert_type_ref_lossy(&p.ty);
            let cn = class_name_from_typeref(&p.ty);
            self.current_frame().bindings.insert(
                p.name.name.clone(),
                Binding { ty, mutable: p.property == Some(true), decl_span: Some(p.name.span), class_name: cn, decl_type_name: None },
            );
            if let Some(default) = &p.default {
                let dty = self.check_expr(default, Some(&convert_type_ref_lossy(&p.ty)));
                self.check_assignable(&dty, &convert_type_ref_lossy(&p.ty), default.span());
            }
        }
        // Body properties bind in declaration order. Properties
        // without an initializer are collected here so the class
        // post-init walker can verify each one is definitely
        // assigned by some primary-ctor path.
        let mut uninitialized_properties: Vec<(String, Span, bool, Span)> = Vec::new();
        for m in &c.members {
            match m {
                Decl::Property(p) => {
                    if let Some(init) = &p.init {
                        let want = p.ty.as_ref().map(convert_type_ref_lossy);
                        let ity = self.check_expr(init, want.as_ref());
                        if let Some(a) = want {
                            self.check_assignable(&ity, &a, init.span());
                        }
                    }
                    let has_init = p.init.is_some()
                        || p.delegate.is_some()
                        || p.is_lateinit
                        || p.is_abstract
                        || p.getter.is_some()
                        || c.is_interface
                        || c.is_abstract;
                    if !has_init {
                        let pty = p.ty.as_ref().map(convert_type_ref_lossy).unwrap_or(Type::Unresolved);
                        self.current_frame().bindings.insert(
                            p.name.name.clone(),
                            Binding {
                                ty: pty,
                                mutable: p.mutable,
                                decl_span: Some(p.name.span),
                                class_name: p.ty.as_ref().and_then(class_name_from_typeref),
                                
                    decl_type_name: None,
                            },
                        );
                        uninitialized_properties.push((p.name.name.clone(), p.name.span, p.mutable, p.name.span));
                    }
                    let _ = self.handle_accessors(p);
                }
                _ => {}
            }
        }
        // Inheritance-delegation diagnostics: validate each `: I by expr`
        // entry — target must be an interface, delegate expression must be
        // a subtype of the named interface.
        for (i, s) in c.supertypes.iter().enumerate() {
            let Some(Some(delegate_expr)) = c.supertype_delegates.get(i) else { continue };
            let target_name = &s.name.name;
            let target_is_interface = self
                .classes
                .get(target_name)
                .map(|info| info.is_interface)
                .unwrap_or(false);
            if !target_is_interface {
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!(
                            "Only interfaces can be delegated to; `{target_name}` is not an interface"
                        ),
                        s.span,
                    )
                    .with_code(codes::TYPE_DELEGATION_TARGET_NOT_INTERFACE),
                );
            }
            let _ = self.check_expr(delegate_expr, None);
            let delegate_class = self.expr_class.get(&delegate_expr.span()).cloned();
            if target_is_interface {
                if let Some(dcn) = delegate_class {
                    if &dcn != target_name && !self.is_subtype_of(&dcn, target_name) {
                        self.diagnostics.emit(
                            Diagnostic::error(
                                format!(
                                    "Delegate expression of type `{dcn}` is not a subtype of `{target_name}`"
                                ),
                                delegate_expr.span(),
                            )
                            .with_code(codes::TYPE_DELEGATION_TYPE_MISMATCH),
                        );
                    }
                }
            }
        }
        // Build the synthetic class-init CFG before walking the
        // init blocks so check_block can consult it for
        // val-first-write and T0020 queries against the property
        // bindings declared on this class.
        let init_cfg_span = c.name.span;
        let init_body = self.synthesize_class_init_body(c);
        let mut lowered = klio_cfa::lower::lower_function(&init_body, init_cfg_span);
        klio_cfa::dataflow::infer_kill_data_flow(&mut lowered.cfg);
        self.cfgs.insert(init_cfg_span, lowered.cfg.clone());
        self.lowerings
            .insert(init_cfg_span, std::rc::Rc::new(lowered));
        self.cfg_fn_stack.push(init_cfg_span);
        for b in &c.init_blocks {
            self.check_block(b, None);
        }
        self.cfg_fn_stack.pop();
        // VIA §12.2.3: every uninitialized `val` / `var` property must be
        // definitely assigned by the time all init blocks (and the primary
        // ctor path) complete. Secondary ctors run a separate flow and
        // are checked below.
        if !c.secondary_ctors.is_empty() {
            // Secondary-ctor flow may assign properties along its own path;
            // be conservative and skip the post-init check to avoid false
            // positives until that flow is modeled.
        } else if c.is_expect {
            // An `expect class` declares members without bodies or
            // initializers; the matching `actual` supplies them.
        } else {
            for (name, span, _mutable, _decl_span) in &uninitialized_properties {
                let cfg_says_unassigned = self
                    .cfg_via_unassigned_at_exit(init_cfg_span, name)
                    .unwrap_or(true);
                if cfg_says_unassigned {
                    self.diagnostics.emit(
                        Diagnostic::error(
                            format!("Property `{name}` must be initialized"),
                            *span,
                        )
                        .with_code(codes::TYPE_VAR_NOT_DEFINITELY_ASSIGNED),
                    );
                }
            }
        }
        // Secondary ctors.
        for sc in &c.secondary_ctors {
            self.check_secondary_ctor(sc);
        }
        // Method bodies run after construction, so the class-init
        // CFG built above has already validated that every needs-
        // init property is definitely assigned by some ctor path.
        for m in &c.members {
            if let Decl::Function(f) = m {
                self.check_function(f);
            }
        }
        for entry in &c.enum_entries {
            self.check_enum_entry(entry);
        }
        self.pop_frame();
        self.class_stack.pop();
        self.type_params_in_scope.pop();
        self.reified_type_params.pop();
    }

    /// Walk every declared supertype (transitively) and gather member
    /// flags. The first-seen flags win for a given member name; that's
    /// good enough for diagnostic purposes — the override-correctness
    /// check only cares whether *some* supertype declared an open/abstract
    /// member with that name.
    /// Spec §5.4: an explicit override visibility must not be stronger
    /// than the overridden declaration's visibility. Strength order:
    /// public < internal < protected < private.
    pub(crate) fn check_override_visibility(
        &mut self,
        name: &str,
        span: Span,
        derived: Visibility,
        base: Visibility,
    ) {
        let strength = |v: Visibility| match v {
            Visibility::Public => 0u8,
            Visibility::Internal => 1,
            Visibility::Protected => 2,
            Visibility::Private => 3,
        };
        if strength(derived) > strength(base) {
            let vis_name = |v: Visibility| match v {
                Visibility::Public => "public",
                Visibility::Internal => "internal",
                Visibility::Protected => "protected",
                Visibility::Private => "private",
            };
            self.diagnostics.emit(
                Diagnostic::error(
                    format!(
                        "override `{name}` cannot weaken visibility: declared `{}` is stronger \
                         than overridden `{}`",
                        vis_name(derived),
                        vis_name(base)
                    ),
                    span,
                )
                .with_code(codes::TYPE_OVERRIDE_VISIBILITY_STRONGER),
            );
        }
    }

    pub(crate) fn check_private_open_or_override(
        &mut self,
        name: &str,
        span: Span,
        is_open: bool,
        is_abstract: bool,
        is_override: bool,
    ) {
        let modifier = if is_open {
            Some("open")
        } else if is_abstract {
            Some("abstract")
        } else if is_override {
            Some("override")
        } else {
            None
        };
        if let Some(modifier) = modifier {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!(
                        "`{name}` cannot be both `private` and `{modifier}`"
                    ),
                    span,
                )
                .with_code(codes::TYPE_PRIVATE_AND_OPEN_OR_ABSTRACT_OR_OVERRIDE),
            );
        }
    }

    /// Spec §5.1: check each declared supertype is legal to inherit from.
    /// Closed (default-final) user classes and `object` types are forbidden;
    /// interfaces, `open` / `abstract` / `sealed` classes are allowed. Built-in
    /// supertypes we don't know about (Any, Throwable, etc.) are skipped.
    pub(crate) fn check_supertype_validity(&mut self, derived_name: &str, supertypes: &[TypeRef]) {
        let derived_local = self
            .classes
            .get(derived_name)
            .map(|i| i.is_local_or_anonymous)
            .unwrap_or(false);
        for s in supertypes {
            let name = &s.name.name;
            let Some(parent) = self.classes.get(name) else { continue };
            if parent.is_sealed && derived_local {
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!(
                            "local class `{derived_name}` cannot inherit from sealed type `{name}`: \
                             sealed inheritors must have a fully-qualified name"
                        ),
                        s.span,
                    )
                    .with_code(codes::TYPE_SEALED_INHERITOR_NOT_QUALIFIED),
                );
            }
            if parent.is_object {
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!(
                            "`{derived_name}` cannot inherit from object `{name}`: \
                             object types cannot be inherited from"
                        ),
                        s.span,
                    )
                    .with_code(codes::TYPE_INHERIT_FROM_OBJECT),
                );
                continue;
            }
            if parent.is_interface {
                continue;
            }
            let open = parent.is_open || parent.is_abstract || parent.is_sealed;
            if !open {
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!(
                            "`{derived_name}` cannot inherit from final class `{name}`: \
                             declare it `open`, `abstract`, or `sealed`"
                        ),
                        s.span,
                    )
                    .with_code(codes::TYPE_INHERIT_FROM_FINAL_CLASS),
                );
            }
        }
    }

    /// Predicate used at `throw e` sites: is `ty` (the static type of `e`)
    /// known to descend from `kotlin.Throwable`? Spec §16.2 first bullet.
    /// `Nothing` is vacuously throwable (the expression diverges anyway);
    /// `Unresolved` is treated as throwable to avoid cascading reports
    /// after an upstream error. `TypeParam` is accepted because its bound
    /// may name a Throwable supertype and a stricter check would require
    /// bound tracking we don't yet wire through `check_expr`.
    pub(crate) fn type_is_throwable_subtype(&self, ty: &Type) -> bool {
        match ty {
            Type::Nothing | Type::Unresolved | Type::TypeParam(_) => true,
            Type::Nullable(_) => false,
            Type::Generic { name, .. } => self.name_is_throwable_subtype(name),
            Type::Intersection(parts) => {
                parts.iter().any(|p| self.type_is_throwable_subtype(p))
            }
            _ => false,
        }
    }

    pub(crate) fn name_is_throwable_subtype(&self, name: &str) -> bool {
        const BUILTIN_THROWABLES: &[&str] = &[
            "Throwable",
            "Exception",
            "RuntimeException",
            "Error",
            "IllegalArgumentException",
            "IllegalStateException",
            "IndexOutOfBoundsException",
            "NullPointerException",
            "ArithmeticException",
            "ClassCastException",
            "NoSuchElementException",
            "UnsupportedOperationException",
            "NumberFormatException",
            "NoWhenBranchMatchedException",
            "UninitializedPropertyAccessException",
            "AssertionError",
            "NotImplementedError",
            "ConcurrentModificationException",
        ];
        if BUILTIN_THROWABLES.contains(&name) {
            return true;
        }
        let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
        let mut stack: Vec<String> = vec![name.to_string()];
        while let Some(n) = stack.pop() {
            if !seen.insert(n.clone()) {
                continue;
            }
            if BUILTIN_THROWABLES.contains(&n.as_str()) {
                return true;
            }
            if let Some(info) = self.classes.get(&n) {
                for s in &info.supertypes {
                    stack.push(s.clone());
                }
            }
        }
        false
    }

    pub(crate) fn is_throwable_subtype(&self, c: &Class) -> bool {
        const BUILTIN_THROWABLES: &[&str] = &[
            "Throwable",
            "Exception",
            "RuntimeException",
            "Error",
            "IllegalArgumentException",
            "IllegalStateException",
            "IndexOutOfBoundsException",
            "NullPointerException",
            "ArithmeticException",
            "ClassCastException",
            "NoSuchElementException",
            "UnsupportedOperationException",
            "NumberFormatException",
            "NoWhenBranchMatchedException",
            "UninitializedPropertyAccessException",
        ];
        let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
        let mut stack: Vec<String> =
            c.supertypes.iter().map(|s| s.name.name.clone()).collect();
        while let Some(name) = stack.pop() {
            if !seen.insert(name.clone()) {
                continue;
            }
            if BUILTIN_THROWABLES.contains(&name.as_str()) {
                return true;
            }
            if let Some(info) = self.classes.get(&name) {
                for s in &info.supertypes {
                    stack.push(s.clone());
                }
            }
        }
        false
    }

    /// Synthesize the `invoke` slot for each function-type supertype, so
    /// `class C : () -> Int { override fun invoke(): Int = ... }` resolves
    /// correctly. Spec §5.1.3: function types are treated as interfaces.
    pub(crate) fn inject_function_type_supertypes(
        &self,
        c: &Class,
        flags: &mut HashMap<String, MemberFlags>,
        sigs: &mut HashMap<String, MemberSig>,
    ) {
        for s in &c.supertypes {
            let Some(fnref) = s.function.as_ref() else { continue };
            flags
                .entry("invoke".to_string())
                .or_insert(MemberFlags {
                    is_open: true,
                    is_override: false,
                    is_abstract: true,
                    is_operator: true,
                    is_infix: false,
                    has_default_body: false,
                });
            let param_types: Vec<Type> = fnref
                .params
                .iter()
                .map(convert_type_ref_lossy)
                .collect();
            let return_ty = convert_type_ref_lossy(&fnref.ret);
            sigs.entry("invoke".to_string()).or_insert(MemberSig::Function {
                param_types,
                return_ty,
                visibility: Visibility::Public,
                is_suspend: fnref.is_suspend,
            });
        }
    }

    /// Same walk as `collect_inherited_member_flags`, but collects the
    /// detailed member signatures used by T0065 / T0066 / T0067 / T0068.
    /// The first occurrence wins (closest ancestor in the supertype walk),
    /// matching the inheritance-order rule.
    pub(crate) fn collect_inherited_member_sigs(&self, c: &Class) -> HashMap<String, MemberSig> {
        let mut out: HashMap<String, MemberSig> = HashMap::new();
        let mut frontier: Vec<String> =
            c.supertypes.iter().map(|s| s.name.name.clone()).collect();
        let mut seen: Vec<String> = vec![c.name.name.clone()];
        let mut steps = 0;
        while let Some(parent_name) = frontier.pop() {
            if steps > 64 {
                break;
            }
            steps += 1;
            if seen.iter().any(|s| s == &parent_name) {
                continue;
            }
            seen.push(parent_name.clone());
            let Some(parent) = self.classes.get(&parent_name) else { continue };
            for (n, sig) in &parent.member_sigs {
                out.entry(n.clone()).or_insert_with(|| sig.clone());
            }
            for s in &parent.supertypes {
                frontier.push(s.clone());
            }
        }
        out
    }

    pub(crate) fn collect_inherited_member_flags(
        &self,
        c: &Class,
    ) -> HashMap<String, MemberFlags> {
        let mut out: HashMap<String, MemberFlags> = HashMap::new();
        let mut frontier: Vec<String> =
            c.supertypes.iter().map(|s| s.name.name.clone()).collect();
        let mut seen: Vec<String> = vec![c.name.name.clone()];
        let mut steps = 0;
        while let Some(parent_name) = frontier.pop() {
            if steps > 64 {
                break;
            }
            steps += 1;
            if seen.iter().any(|s| s == &parent_name) {
                continue;
            }
            seen.push(parent_name.clone());
            let Some(parent) = self.classes.get(&parent_name) else { continue };
            for (n, flags) in &parent.member_flags {
                let mut effective = *flags;
                // An override member without explicit `final` is itself
                // overridable in Kotlin. We don't model `final`, so treat
                // any override-marked parent as open for diagnostic purposes.
                if effective.is_override {
                    effective.is_open = true;
                }
                out.entry(n.clone()).or_insert(effective);
            }
            for s in &parent.supertypes {
                frontier.push(s.clone());
            }
        }
        out
    }

    pub(crate) fn check_enum_entry(&mut self, e: &EnumEntry) {
        for a in &e.args {
            self.check_expr(a, None);
        }
        for m in &e.body_members {
            self.check_decl(m);
        }
    }

    pub(crate) fn handle_accessors(&mut self, p: &Property) {
        if let Some(g) = &p.getter {
            self.check_accessor(g);
        }
        if let Some(s) = &p.setter {
            self.check_accessor(s);
        }
        if let Some(d) = &p.delegate {
            self.check_expr(d, None);
            self.check_delegate_operator(p, d);
        }
    }

    /// For `val/var x by EXPR`, when EXPR resolves to a constructor call on a
    /// user class, require that class's `getValue` (and `setValue` for `var`)
    /// carry the `operator` modifier. Emitted as a warning (T0012).
    pub(crate) fn check_delegate_operator(&mut self, p: &Property, delegate: &Expr) {
        let class_name = match delegate {
            Expr::Call { callee, .. } => match callee.as_ref() {
                Expr::Path { segments, .. } => segments.last().map(|s| s.name.clone()),
                _ => None,
            },
            Expr::Path { segments, .. } => segments.last().map(|s| s.name.clone()),
            _ => None,
        };
        let Some(class_name) = class_name else { return };
        let Some(info) = self.classes.get(&class_name) else { return };
        let needed: &[&str] = if p.mutable {
            &["getValue", "setValue"]
        } else {
            &["getValue"]
        };
        for member in needed {
            let Some(flags) = info.member_flags.get(*member) else { continue };
            if !flags.is_operator {
                self.diagnostics.emit(
                    Diagnostic::warning(
                        format!(
                            "`{class_name}.{member}` is used as a property-delegate convention but is missing the `operator` modifier"
                        ),
                        delegate.span(),
                    )
                    .with_code(codes::TYPE_DELEGATE_OPERATOR_REQUIRED),
                );
            }
        }
    }

    /// Compile-time rules for `lateinit`. Kotlin restricts `lateinit` to:
    /// non-null, non-primitive, `var` properties with no initializer.
    pub(crate) fn check_lateinit(&mut self, p: &Property) {
        if !p.is_lateinit {
            return;
        }
        if !p.mutable {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!("`lateinit` modifier is not allowed on `val` (use `lateinit var` for `{}`)", p.name.name),
                    p.name.span,
                )
                .with_code(codes::TYPE_LATEINIT_VAL),
            );
        }
        if let Some(init) = &p.init {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!("`lateinit` property `{}` cannot have an initializer", p.name.name),
                    init.span(),
                )
                .with_code(codes::TYPE_LATEINIT_WITH_INITIALIZER),
            );
        }
        if let Some(ty) = &p.ty {
            if ty.nullable {
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!(
                            "`lateinit` property `{}` may not have a nullable type",
                            p.name.name
                        ),
                        ty.span,
                    )
                    .with_code(codes::TYPE_LATEINIT_NULLABLE),
                );
            }
            if is_primitive_type_name(&ty.name.name) {
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!(
                            "`lateinit` modifier is not allowed on properties of primitive type `{}`",
                            ty.name.name
                        ),
                        ty.span,
                    )
                    .with_code(codes::TYPE_LATEINIT_PRIMITIVE),
                );
            }
        }
    }

    /// Enforce that an accessor's explicit return-type annotation matches
    /// the property's declared type.
    pub(crate) fn check_accessor_return_types(&mut self, p: &Property) {
        let Some(prop_ty_ref) = p.ty.as_ref() else { return };
        let prop_ty = convert_type_ref_lossy(prop_ty_ref);
        for (a, label) in [
            (p.getter.as_ref(), "getter"),
            (p.setter.as_ref(), "setter"),
        ] {
            let Some(a) = a else { continue };
            let Some(rt) = a.return_type.as_ref() else { continue };
            let rty = convert_type_ref_lossy(rt);
            if !self.types_match_for_accessor(&rty, &prop_ty) {
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!(
                            "{label} return type `{}` does not match property type `{}`",
                            type_display(&rty),
                            type_display(&prop_ty)
                        ),
                        rt.span,
                    )
                    .with_code(codes::TYPE_ACCESSOR_RETURN_TYPE_MISMATCH),
                );
            }
        }
    }

    pub(crate) fn types_match_for_accessor(&self, a: &Type, b: &Type) -> bool {
        // Skip the check entirely if either side lowered to Unresolved
        // (user types, generics, etc.) to avoid false positives.
        if matches!(a, Type::Unresolved) || matches!(b, Type::Unresolved) {
            return true;
        }
        a == b
    }

    /// True when `sub` is a transitive supertype-walk descendant of `sup`.
    pub(crate) fn is_subtype_of(&self, sub: &str, sup: &str) -> bool {
        if sub == sup {
            return false;
        }
        let mut frontier = vec![sub.to_string()];
        let mut steps = 0;
        let mut seen: Vec<String> = Vec::new();
        while let Some(name) = frontier.pop() {
            if steps > 64 {
                return false;
            }
            steps += 1;
            if seen.iter().any(|s| s == &name) {
                continue;
            }
            seen.push(name.clone());
            let Some(info) = self.classes.get(&name) else { continue };
            for s in &info.supertypes {
                if s == sup {
                    return true;
                }
                frontier.push(s.clone());
            }
        }
        false
    }

    /// For diamond detection: for every member name supplied by some
    /// supertype, list `(supertype, has_default_body)` pairs. Walks the
    /// transitive supertype set. A `has_default_body == false` entry is
    /// an abstract slot and triggers the spec §5.3 abstract-and-concrete
    /// rule.
    pub(crate) fn collect_default_providers(
        &self,
        c: &Class,
    ) -> HashMap<String, Vec<(String, bool)>> {
        let mut out: HashMap<String, Vec<(String, bool)>> = HashMap::new();
        let mut frontier: Vec<String> =
            c.supertypes.iter().map(|s| s.name.name.clone()).collect();
        let mut seen: Vec<String> = vec![c.name.name.clone()];
        let mut steps = 0;
        while let Some(parent_name) = frontier.pop() {
            if steps > 64 {
                break;
            }
            steps += 1;
            if seen.iter().any(|s| s == &parent_name) {
                continue;
            }
            seen.push(parent_name.clone());
            let Some(parent) = self.classes.get(&parent_name) else { continue };
            for (n, flags) in &parent.member_flags {
                // A supplier is either concrete (has_default_body) or
                // abstract. Body-less interface methods don't carry an
                // explicit `abstract` modifier but are abstract slots for
                // inheritance purposes; the same goes for body-less
                // interface / abstract-class properties.
                let is_abstract_slot = flags.is_abstract
                    || (parent.is_interface && !flags.has_default_body);
                if flags.has_default_body || is_abstract_slot {
                    let entry = out.entry(n.clone()).or_default();
                    if !entry.iter().any(|(s, _)| s == &parent_name) {
                        entry.push((parent_name.clone(), flags.has_default_body));
                    }
                }
            }
            for s in &parent.supertypes {
                frontier.push(s.clone());
            }
        }
        out
    }

    pub(crate) fn check_accessor(&mut self, a: &Accessor) {
        self.push_frame();
        for p in &a.params {
            self.current_frame().bindings.insert(
                p.name.clone(),
                Binding { ty: Type::Unresolved, mutable: false, decl_span: Some(p.span), class_name: None, decl_type_name: None },
            );
        }
        match &a.body {
            FunctionBody::Block(b) => {
                self.check_block(b, None);
            }
            FunctionBody::Expr(e) => {
                self.check_expr(e, None);
            }
        }
        self.pop_frame();
    }

    pub(crate) fn check_secondary_ctor(&mut self, sc: &SecondaryCtor) {
        self.push_frame();
        for p in &sc.params {
            let ty = convert_type_ref_lossy(&p.ty);
            let cn = class_name_from_typeref(&p.ty);
            self.current_frame().bindings.insert(
                p.name.name.clone(),
                Binding { ty, mutable: false, decl_span: Some(p.name.span), class_name: cn, decl_type_name: None },
            );
        }
        match &sc.delegation {
            CtorDelegation::This(args) | CtorDelegation::Super(args) => {
                for a in args {
                    self.check_expr(a, None);
                }
            }
            CtorDelegation::None => {}
        }
        if let Some(b) = &sc.body {
            self.check_block(b, None);
        }
        self.pop_frame();
    }

    pub(crate) fn check_object(&mut self, o: &ObjectDecl) {
        self.class_stack.push(o.name.name.clone());
        self.check_supertype_validity(&o.name.name, &o.supertypes);
        self.push_frame();
        for m in &o.members {
            match m {
                Decl::Property(p) => {
                    if let Some(init) = &p.init {
                        let want = p.ty.as_ref().map(convert_type_ref_lossy);
                        let ity = self.check_expr(init, want.as_ref());
                        if let Some(a) = want {
                            self.check_assignable(&ity, &a, init.span());
                        }
                    }
                    let _ = self.handle_accessors(p);
                }
                Decl::Function(f) => self.check_function(f),
                _ => {}
            }
        }
        self.pop_frame();
        self.class_stack.pop();
    }
}
