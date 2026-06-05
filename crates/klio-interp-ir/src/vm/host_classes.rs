use crate::{Arc, AtomicOrdering, VmHost, receiver_for_label, simple_literal, with_outer_this};

impl VmHost<'_> {
    // Result kept for symmetry with the `Host::register_class` trait method.
    #[allow(clippy::too_many_lines, clippy::unnecessary_wraps)]
    pub(crate) fn register_class(
        &mut self,
        class: &klio_ast::Class,
    ) -> Result<(), klio_ir::eval::EvalError> {
        // Local classes declared inside fn bodies arrive here at
        // runtime. Synthesise the same ClassDef shape build_module
        // produces for top-level classes and stash in the Vm's
        // class table. Body-property + getter lowering for local
        // classes lives in IR's class registration; here we just
        // build the runtime shape needed for instance allocation.
        let primary_params: Vec<klio_runtime::ClassParamDef> = class
            .primary_params
            .iter()
            .map(|p| klio_runtime::ClassParamDef {
                property: p.property,
                name: p.name.name.clone(),
                default: p.default.as_ref().map(|e| Arc::new(e.clone())),
                declared_type: Some(p.ty.name.name.clone()),
                declared_shape: Some(klio_runtime::TypeShape::from_type_ref(&p.ty)),
            })
            .collect();
        let body_properties: Vec<klio_runtime::PropertyDef> = class
            .members
            .iter()
            .filter_map(|m| match m {
                klio_ast::Decl::Property(p) => Some(klio_runtime::PropertyDef {
                    name: p.name.name.clone(),
                    mutable: p.mutable,
                    init: p.init.as_ref().map(|e| Arc::new(e.clone())),
                    getter: p.getter.as_ref().map(|a| Arc::new(a.clone())),
                    setter: p.setter.as_ref().map(|a| Arc::new(a.clone())),
                    delegate: p.delegate.as_ref().map(|e| Arc::new(e.clone())),
                    is_abstract: p.is_abstract,
                    is_lateinit: p.is_lateinit,
                    primitive_zero: crate::build::primitive_zero_for(p),
                }),
                _ => None,
            })
            .collect();
        let def = Arc::new(klio_runtime::ClassDef {
            name: class.name.name.clone(),
            fqn: class.name.name.clone(),
            annotation_names: Vec::new(),
            primary_params,
            methods: Vec::new(),
            body_properties,
            init_blocks: Vec::new(),
            init_block_property_positions: Vec::new(),
            is_data: class.is_data,
            is_value: class.is_value,
            is_object: false,
            is_enum: class.is_enum,
            is_sealed: class.is_sealed,
            is_open: class.is_open,
            is_abstract: class.is_abstract,
            is_inner: class.is_inner,
            is_anonymous: false,
            secondary_ctors: Vec::new(),
            supertype_names: class
                .supertypes
                .iter()
                .map(|t| t.name.name.clone())
                .collect(),
            parent: klio_runtime::ObjRef::new(None),
            interfaces: klio_runtime::ObjRef::new(Vec::new()),
            is_interface: class.is_interface,
            is_fun_interface: class.is_fun_interface,
            parent_ctor_args: Vec::new(),
            enum_entries: klio_runtime::ObjRef::new(Vec::new()),
            companion: klio_runtime::ObjRef::new(None),
            enclosing_class: klio_runtime::ObjRef::new(None),
            nested_classes: klio_runtime::ObjRef::new(Vec::new()),
            captured_env: klio_runtime::ObjRef::new(klio_runtime::Env::new()),
            supertype_delegates: klio_runtime::ObjRef::new(Vec::new()),
            delegate_forwarders: klio_runtime::ObjRef::new(Vec::new()),
            object_singleton: klio_runtime::ObjRef::new(None),
        });
        self.classes
            .borrow_mut()
            .insert(class.name.name.clone(), def);
        // Lower local-class methods into per-method side modules
        // and stash in anon_methods so call_member can dispatch
        // them. The synth class name is the user-declared name; if
        // it collides with a top-level class, the local lookup
        // wins (the runtime classes table is updated in-place).
        let mut own_members: std::collections::HashSet<String> = std::collections::HashSet::new();
        for p in &class.primary_params {
            if p.property.is_some() {
                own_members.insert(p.name.name.clone());
            }
        }
        for m in &class.members {
            match m {
                klio_ast::Decl::Property(p) => {
                    own_members.insert(p.name.name.clone());
                }
                klio_ast::Decl::Function(f) => {
                    own_members.insert(f.name.name.clone());
                }
                _ => {}
            }
        }
        for m in &class.members {
            if let klio_ast::Decl::Function(f) = m {
                if f.body.is_none() {
                    continue;
                }
                let mut sub_module = klio_ir::Module::default();
                let func = klio_ir::lower::lower_method(
                    &mut sub_module,
                    f,
                    &class.name.name,
                    &own_members,
                );
                let fid = func.id;
                let module_rc = Arc::new(sub_module);
                let entry = (module_rc, fid, Vec::new());
                let mut tbl = self.anon_methods.borrow_mut();
                tbl.insert(
                    (
                        class.name.name.clone(),
                        format!("{}#{}", f.name.name, f.params.len()),
                    ),
                    entry.clone(),
                );
                tbl.insert((class.name.name.clone(), f.name.name.clone()), entry);
            }
        }
        Ok(())
    }

    pub(crate) fn register_class_captured(
        &mut self,
        class: &klio_ast::Class,
        captured_names: &[String],
        captures: Vec<klio_runtime::Value>,
    ) -> Result<(), klio_ir::eval::EvalError> {
        self.register_class(class)?;
        // Snapshot `this` from the captured outer env (when
        // present) so instances of this local class get an `outer`
        // pointing back at the enclosing scope's receiver.
        let captured_this: Option<klio_runtime::Value> = captured_names
            .iter()
            .position(|n| n == "this")
            .and_then(|i| captures.get(i).cloned());
        if let Some(this_val) = captured_this.clone() {
            self.class_default_outer
                .borrow_mut()
                .insert(class.name.name.clone(), this_val.clone());
        }
        // Re-lower the local class's methods with the captured
        // outer's field + member names merged into own_members,
        // so bare references to outer properties lower as
        // `this.X` and resolve via the outer chain at runtime.
        if let Some(klio_runtime::Value::Instance(this_inst)) = captured_this {
            let outer_class = this_inst.borrow().class.clone();
            let mut extras: std::collections::HashSet<String> = std::collections::HashSet::new();
            for p in &outer_class.primary_params {
                extras.insert(p.name.clone());
            }
            for p in &outer_class.body_properties {
                extras.insert(p.name.clone());
            }
            let mut own_members: std::collections::HashSet<String> = extras.clone();
            for p in &class.primary_params {
                if p.property.is_some() {
                    own_members.insert(p.name.name.clone());
                }
            }
            for m in &class.members {
                match m {
                    klio_ast::Decl::Property(p) => {
                        own_members.insert(p.name.name.clone());
                    }
                    klio_ast::Decl::Function(f) => {
                        own_members.insert(f.name.name.clone());
                    }
                    _ => {}
                }
            }
            for m in &class.members {
                if let klio_ast::Decl::Function(f) = m {
                    if f.body.is_none() {
                        continue;
                    }
                    let mut sub_module = klio_ir::Module::default();
                    let func = klio_ir::lower::lower_method(
                        &mut sub_module,
                        f,
                        &class.name.name,
                        &own_members,
                    );
                    let fid = func.id;
                    let module_rc = Arc::new(sub_module);
                    let entry = (module_rc, fid, Vec::new());
                    let mut tbl = self.anon_methods.borrow_mut();
                    tbl.insert(
                        (
                            class.name.name.clone(),
                            format!("{}#{}", f.name.name, f.params.len()),
                        ),
                        entry.clone(),
                    );
                    tbl.insert((class.name.name.clone(), f.name.name.clone()), entry);
                }
            }
        }
        // Patch the just-registered method entries with the captured
        // outer-env so dispatch can layer them under globals.
        let capture_pairs: Vec<(String, klio_runtime::Value)> =
            captured_names.iter().cloned().zip(captures).collect();
        if capture_pairs.is_empty() {
            return Ok(());
        }
        let mut tbl = self.anon_methods.borrow_mut();
        for m in &class.members {
            if let klio_ast::Decl::Function(f) = m {
                for key in [
                    (
                        class.name.name.clone(),
                        format!("{}#{}", f.name.name, f.params.len()),
                    ),
                    (class.name.name.clone(), f.name.name.clone()),
                ] {
                    if let Some(entry) = tbl.get_mut(&key) {
                        entry.2.clone_from(&capture_pairs);
                    }
                }
            }
        }
        Ok(())
    }

    // One cohesive anonymous-object build flow over shared state.
    #[allow(clippy::too_many_lines)]
    pub(crate) fn build_object(
        &mut self,
        ast: &klio_ast::Expr,
        captured_names: &[String],
        captures: Vec<klio_runtime::Value>,
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        let capture_pairs: Vec<(String, klio_runtime::Value)> =
            captured_names.iter().cloned().zip(captures).collect();
        // Minimal anonymous-object support: synthesise an
        // InstanceData backed by a fresh ClassDef from the AST's
        // ObjectExpr shape, with no parent ctor chain, no method
        // body lowering — primary use case is `object { val tag = X }`
        // markers and `object : SomeInterface { override fun ... }`
        // SAM-like wrappers used by tests. Full lowering lands when
        // the IR Class shape supports it.
        if let klio_ast::Expr::ObjectExpr {
            members,
            supertypes,
            supertype_args,
            ..
        } = ast
        {
            let identity = self
                .instance_id_counter
                .fetch_add(1, AtomicOrdering::Relaxed)
                + 1;
            // Lower each method body into a per-method side
            // module + FuncId. dispatch at call_member time.
            let synth_class_name = format!("$anon${identity}");
            // Collect the anon object's own member names so bare
            // identifiers inside method bodies resolve through this.
            // Pulls in supertype members too: an `object : Named(...)`
            // body that references `name` resolves through this.name
            // and the field bound below from the parent's primary
            // ctor args.
            let mut own_members: std::collections::HashSet<String> =
                std::collections::HashSet::new();
            for m in members {
                match m {
                    klio_ast::Decl::Property(p) => {
                        own_members.insert(p.name.name.clone());
                    }
                    klio_ast::Decl::Function(f) => {
                        own_members.insert(f.name.name.clone());
                    }
                    _ => {}
                }
            }
            for sup in supertypes {
                if let Some(pdef) = self.classes.borrow().get(&sup.name.name).cloned() {
                    for p in &pdef.primary_params {
                        own_members.insert(p.name.clone());
                    }
                    for p in &pdef.body_properties {
                        own_members.insert(p.name.clone());
                    }
                    for me in &pdef.methods {
                        own_members.insert(me.name.clone());
                    }
                }
            }
            // Enclosing-class members are reachable from an anon-
            // object method body via the captured outer `this`. Add
            // them to `own_members` so bare identifiers lower as
            // `GetField(this, …)`; the runtime's outer-chain walk in
            // `get_field` then resolves them on the captured outer
            // instance. Without this, a name that happens to match a
            // top-level intrinsic (e.g. `to` matches `kotlin.to`)
            // falls through to a `LoadGlobal` of the intrinsic.
            for (n, v) in &capture_pairs {
                if n == "this" {
                    if let klio_runtime::Value::Instance(outer_inst) = v {
                        let cls = outer_inst.borrow().class.clone();
                        for p in &cls.primary_params {
                            own_members.insert(p.name.clone());
                        }
                        for p in &cls.body_properties {
                            own_members.insert(p.name.clone());
                        }
                        for me in &cls.methods {
                            own_members.insert(me.name.clone());
                        }
                    }
                    break;
                }
            }
            // Names the object closes over reach its method bodies as
            // runtime-injected scoped globals; make them visible to
            // method lowering so a `recv.name()` whose `name` is one
            // of them (e.g. `c.block()` where `block` is an enclosing
            // inline fn's crossinline param) dispatches as
            // CallMemberOrValue instead of mis-SAM-dispatching the
            // receiver's abstract method.
            let anon_cap_set: std::collections::HashSet<String> =
                captured_names.iter().cloned().collect();
            klio_ir::lower::set_lower_anon_captures(Some(anon_cap_set));
            // Property inits that aren't a literal or a bare captured name
            // are lowered as zero-arg thunks (a synthetic method body) and
            // run after the instance exists, so e.g.
            // `object : Iterator { val it = src.iterator() … }` evaluates
            // the call with the captures (and `this`) in scope instead of
            // falling back to Null.
            let mut complex_prop_inits: Vec<(String, Arc<klio_ir::Module>, klio_ir::FuncId)> =
                Vec::new();
            for m in members {
                match m {
                    klio_ast::Decl::Function(f) => {
                        if f.body.is_none() {
                            continue;
                        }
                        let mut sub_module = klio_ir::Module::default();
                        let func = klio_ir::lower::lower_method(
                            &mut sub_module,
                            f,
                            &synth_class_name,
                            &own_members,
                        );
                        let fid = func.id;
                        let module_rc = Arc::new(sub_module);
                        let entry = (module_rc, fid, capture_pairs.clone());
                        let mut tbl = self.anon_methods.borrow_mut();
                        tbl.insert(
                            (
                                synth_class_name.clone(),
                                format!("{}#{}", f.name.name, f.params.len()),
                            ),
                            entry.clone(),
                        );
                        tbl.insert((synth_class_name.clone(), f.name.name.clone()), entry);
                    }
                    klio_ast::Decl::Property(p) => {
                        // A getter-only property (`override val context get()
                        // = context`) is lowered as a 0-arg anon method under
                        // the property name, *inside* the capture window, so a
                        // read invokes it with the closed-over names in scope
                        // (the `Continuation(ctx) { … }` factory's `context`).
                        if let Some(getter) = &p.getter {
                            let thunk = klio_ast::Function {
                                name: p.name.clone(),
                                receiver_type: None,
                                type_params: Vec::new(),
                                where_bounds: Vec::new(),
                                params: Vec::new(),
                                return_type: getter.return_type.clone(),
                                body: Some(getter.body.clone()),
                                is_open: false,
                                is_override: p.is_override,
                                is_abstract: false,
                                is_operator: false,
                                is_inline: false,
                                is_infix: false,
                                is_tailrec: false,
                                is_suspend: false,
                                is_expect: false,
                                is_actual: false,
                                visibility: klio_ast::Visibility::Public,
                                annotations: Vec::new(),
                                span: p.name.span,
                            };
                            let mut sub_module = klio_ir::Module::default();
                            let func = klio_ir::lower::lower_method(
                                &mut sub_module,
                                &thunk,
                                &synth_class_name,
                                &own_members,
                            );
                            let fid = func.id;
                            let entry = (Arc::new(sub_module), fid, capture_pairs.clone());
                            let mut tbl = self.anon_methods.borrow_mut();
                            tbl.insert(
                                (synth_class_name.clone(), format!("$get${}", p.name.name)),
                                entry,
                            );
                        }
                        let Some(init) = &p.init else { continue };
                        let is_bare_path = matches!(
                            init,
                            klio_ast::Expr::Path { segments, .. } if segments.len() == 1
                        );
                        if simple_literal(init).is_some() || is_bare_path {
                            continue;
                        }
                        let thunk = klio_ast::Function {
                            name: klio_ast::Ident {
                                name: format!("$init${}", p.name.name),
                                span: p.name.span,
                            },
                            receiver_type: None,
                            type_params: Vec::new(),
                            where_bounds: Vec::new(),
                            params: Vec::new(),
                            return_type: None,
                            body: Some(klio_ast::FunctionBody::Expr(init.clone())),
                            is_open: false,
                            is_override: false,
                            is_abstract: false,
                            is_operator: false,
                            is_inline: false,
                            is_infix: false,
                            is_tailrec: false,
                            is_suspend: false,
                            is_expect: false,
                            is_actual: false,
                            visibility: klio_ast::Visibility::Public,
                            annotations: Vec::new(),
                            span: p.name.span,
                        };
                        let mut sub_module = klio_ir::Module::default();
                        let func = klio_ir::lower::lower_method(
                            &mut sub_module,
                            &thunk,
                            &synth_class_name,
                            &own_members,
                        );
                        complex_prop_inits.push((p.name.name.clone(), Arc::new(sub_module), func.id));
                    }
                    _ => {}
                }
            }
            klio_ir::lower::set_lower_anon_captures(None);
            let body_properties: Vec<klio_runtime::PropertyDef> = members
                .iter()
                .filter_map(|m| match m {
                    klio_ast::Decl::Property(p) => Some(klio_runtime::PropertyDef {
                        name: p.name.name.clone(),
                        mutable: p.mutable,
                        init: p.init.as_ref().map(|e| Arc::new(e.clone())),
                        getter: p.getter.as_ref().map(|a| Arc::new(a.clone())),
                        setter: p.setter.as_ref().map(|a| Arc::new(a.clone())),
                        delegate: p.delegate.as_ref().map(|e| Arc::new(e.clone())),
                        is_abstract: p.is_abstract,
                        is_lateinit: p.is_lateinit,
                        primitive_zero: crate::build::primitive_zero_for(p),
                    }),
                    _ => None,
                })
                .collect();
            let supertype_names: Vec<String> =
                supertypes.iter().map(|t| t.name.name.clone()).collect();
            // Resolve the first non-interface supertype as the parent
            // class so inherited concrete methods reach the call_member
            // chain walker. `object : Base() { … }` would otherwise
            // have parent=None and call_member would only see the
            // anon's own (override) methods.
            let mut anon_parent: Option<Arc<klio_runtime::ClassDef>> = None;
            {
                let classes = self.classes.borrow();
                for n in &supertype_names {
                    if let Some(def) = classes.get(n).cloned()
                        && !def.is_interface
                    {
                        anon_parent = Some(def);
                        break;
                    }
                }
            }
            let class_def = Arc::new(klio_runtime::ClassDef {
                name: format!("$anon${identity}"),
                fqn: format!("$anon${identity}"),
                annotation_names: Vec::new(),
                primary_params: Vec::new(),
                methods: Vec::new(),
                body_properties,
                init_blocks: Vec::new(),
                init_block_property_positions: Vec::new(),
                is_data: false,
                is_value: false,
                is_object: false,
                is_enum: false,
                is_sealed: false,
                is_open: false,
                is_abstract: false,
                is_inner: false,
                is_anonymous: true,
                secondary_ctors: Vec::new(),
                supertype_names,
                parent: klio_runtime::ObjRef::new(anon_parent),
                interfaces: klio_runtime::ObjRef::new(Vec::new()),
                is_interface: false,
                is_fun_interface: false,
                parent_ctor_args: Vec::new(),
                enum_entries: klio_runtime::ObjRef::new(Vec::new()),
                companion: klio_runtime::ObjRef::new(None),
                enclosing_class: klio_runtime::ObjRef::new(None),
                nested_classes: klio_runtime::ObjRef::new(Vec::new()),
                captured_env: klio_runtime::ObjRef::new(klio_runtime::Env::new()),
                supertype_delegates: klio_runtime::ObjRef::new(Vec::new()),
                delegate_forwarders: klio_runtime::ObjRef::new(Vec::new()),
                object_singleton: klio_runtime::ObjRef::new(None),
            });
            // Initialise body-property fields. Literal values via
            // `simple_literal`; a bare-name reference to one of the
            // captured outer names (e.g. `var cur = from` in
            // `object : Iterator<Int> { var cur = from … }` inside
            // a method of a `class Down(val from: Int, val to: Int)`)
            // is resolved against the captured env. Arbitrary
            // expressions still fall back to `Null` — a fuller
            // solution would lower the init as a thunk, but the
            // single-capture-Path case covers most realistic shapes.
            let mut fields: Vec<(String, klio_runtime::Value)> = Vec::new();
            for p in &class_def.body_properties {
                if let Some(init) = &p.init {
                    let v = if let Some(v) = simple_literal(init) {
                        v
                    } else if let klio_ast::Expr::Path { segments, .. } = init.as_ref() {
                        if segments.len() == 1 {
                            let nm = &segments[0].name;
                            // First: captured-by-name (a local/param of
                            // the enclosing scope).
                            let direct = capture_pairs
                                .iter()
                                .find(|(n, _)| n == nm)
                                .map(|(_, v)| v.clone());
                            // Then: an enclosing-class member reached
                            // through the captured outer `this`. The
                            // runtime `get_field` walks the outer chain
                            // for arbitrary later reads, but the body-
                            // property init runs before the instance
                            // exists, so the lookup happens here.
                            direct
                                .or_else(|| {
                                    let outer_inst = capture_pairs
                                        .iter()
                                        .find(|(n, _)| n == "this")
                                        .and_then(|(_, v)| match v {
                                            klio_runtime::Value::Instance(i) => Some(i.clone()),
                                            _ => None,
                                        });
                                    outer_inst.and_then(|i| i.borrow().get(nm))
                                })
                                .unwrap_or(klio_runtime::Value::Null)
                        } else {
                            klio_runtime::Value::Null
                        }
                    } else {
                        klio_runtime::Value::Null
                    };
                    fields.push((p.name.clone(), v));
                } else {
                    let v = p
                        .primitive_zero
                        .clone()
                        .unwrap_or(klio_runtime::Value::Null);
                    fields.push((p.name.clone(), v));
                }
            }
            // Evaluate a supertype ctor-arg expression to a value:
            // literals via `simple_literal`, else a bare captured
            // name (a local/param of the enclosing scope, e.g. the
            // `initial` in `object : ObservableProperty<T>(initial)`),
            // else a field reached through the captured outer `this`.
            let eval_super_arg = |expr: &klio_ast::Expr| -> klio_runtime::Value {
                if let Some(v) = simple_literal(expr) {
                    return v;
                }
                if let klio_ast::Expr::Path { segments, .. } = expr
                    && segments.len() == 1
                {
                    let nm = &segments[0].name;
                    if let Some((_, v)) = capture_pairs.iter().find(|(n, _)| n == nm) {
                        return v.clone();
                    }
                    if let Some((_, klio_runtime::Value::Instance(i))) =
                        capture_pairs.iter().find(|(n, _)| n == "this")
                        && let Some(v) = i.borrow().get(nm)
                    {
                        return v;
                    }
                }
                klio_runtime::Value::Null
            };
            // Populate parent's primary-param fields from
            // `object : Named("Anna") { … }` style supertype ctor args.
            // Also stash each supertype's evaluated ctor args so the
            // parent body-property initializers (run after the instance
            // is materialised) see the parent's primary params.
            let mut super_args_by_class: std::collections::HashMap<
                String,
                Vec<klio_runtime::Value>,
            > = std::collections::HashMap::new();
            for (idx, sup) in supertypes.iter().enumerate() {
                let arg_exprs = match supertype_args.get(idx) {
                    Some(Some(v)) => v.clone(),
                    _ => continue,
                };
                let vals: Vec<klio_runtime::Value> =
                    arg_exprs.iter().map(&eval_super_arg).collect();
                let parent_def = self.classes.borrow().get(&sup.name.name).cloned();
                if let Some(pdef) = parent_def {
                    for (param, val) in pdef.primary_params.iter().zip(vals.iter()) {
                        if param.property.is_none() {
                            continue;
                        }
                        fields.push((param.name.clone(), val.clone()));
                    }
                }
                super_args_by_class.insert(sup.name.name.clone(), vals);
            }
            // Register the anon ClassDef in the runtime class table
            // so the call_member_named walker that resolves inherited
            // methods through `supertype_names` can find this entry
            // and follow the chain to the concrete superclass body.
            self.classes
                .borrow_mut()
                .insert(class_def.name.clone(), class_def.clone());
            // Wire the captured outer `this` (if any) as the anon
            // instance's `outer`, so the runtime's outer-chain walk
            // can resolve enclosing-class member references emitted
            // as `GetField(this, …)` against the right instance.
            let outer = capture_pairs
                .iter()
                .find(|(n, _)| n == "this")
                .map(|(_, v)| v.clone());
            let inst = klio_runtime::ObjRef::new(klio_runtime::InstanceData {
                class: class_def,
                fields,
                outer,
                identity,
                native_state: None,
            });
            let inst_value = klio_runtime::Value::Instance(inst.clone());
            // Run the concrete superclass chain's body-property
            // initializers so inherited `var/val` fields are populated
            // — an `object : Super(args) { … }` must run the parent
            // constructor like a named subclass does (new_instance's
            // chain walk). Without this, e.g. `ObservableProperty.value
            // = initialValue` never runs and the inherited getValue/
            // setValue read a missing `value` field. Only runs when a
            // concrete (non-interface) superclass exists; pure
            // interface object literals keep the existing fast path.
            let parent_chain: Vec<Arc<klio_runtime::ClassDef>> = {
                let mut v = Vec::new();
                let mut cur = inst.borrow().class.parent.borrow().clone();
                while let Some(c) = cur.take() {
                    cur.clone_from(&c.parent.borrow());
                    v.push(c);
                }
                v
            };
            // Bottom-up so a parent's field exists before a nearer
            // ancestor overrides the same name.
            for cls in parent_chain.iter().rev() {
                let cls_args: Vec<klio_runtime::Value> = super_args_by_class
                    .get(&cls.name)
                    .cloned()
                    .unwrap_or_default();
                for p in &cls.body_properties {
                    let Some(fid) = self
                        .prog
                        .body_prop_inits
                        .get(&(cls.name.clone(), p.name.clone()))
                        .copied()
                    else {
                        continue;
                    };
                    let Some(func) = self.module.funcs.get(fid.0 as usize).cloned() else {
                        continue;
                    };
                    let module = Arc::clone(&self.module);
                    let mut all: Vec<klio_runtime::Value> = Vec::with_capacity(1 + cls_args.len());
                    all.push(inst_value.clone());
                    all.extend_from_slice(&cls_args);
                    let v = klio_ir::eval::eval_with(&module, &func, all, self)?;
                    // Don't clobber a field the anon body (or a nearer
                    // class) already set.
                    if inst.borrow().get(&p.name).is_none() {
                        inst.borrow_mut().define(&p.name, v);
                    }
                }
            }
            // Run the anon object's own complex property inits (the
            // thunks lowered above) now that the instance + inherited
            // fields exist, with the captured names and `this` in scope —
            // mirroring the anon-method capture binding.
            for (prop_name, module_rc, fid) in &complex_prop_inits {
                let Some(func) = module_rc.funcs.get(fid.0 as usize).cloned() else {
                    continue;
                };
                let prev = self.globals.clone();
                if !capture_pairs.is_empty() {
                    let scoped =
                        klio_runtime::ObjRef::new(klio_runtime::Env::with_parent(prev.clone()));
                    for (n, v) in &capture_pairs {
                        scoped.borrow_mut().define(n.clone(), v.clone());
                    }
                    self.globals = scoped;
                }
                let cap_vec: Vec<klio_runtime::Value> = func
                    .capture_order
                    .iter()
                    .map(|n| {
                        if n == "this" {
                            inst_value.clone()
                        } else {
                            capture_pairs
                                .iter()
                                .find(|(cn, _)| cn == n)
                                .map_or(klio_runtime::Value::Null, |(_, v)| v.clone())
                        }
                    })
                    .collect();
                let res = klio_ir::eval::eval_with_captures(
                    module_rc,
                    &func,
                    vec![inst_value.clone()],
                    cap_vec,
                    self,
                );
                self.globals = prev;
                let v = res?;
                inst.borrow_mut().define(prop_name, v);
            }
            return Ok(inst_value);
        }
        Err(klio_ir::eval::EvalError::Type(
            "Vm::build_object: not an ObjectExpr AST node".to_string(),
        ))
    }

    // Single supertype-chain dispatch walk; splitting fragments it.
    #[allow(clippy::too_many_lines)]
    pub(crate) fn call_super(
        &mut self,
        receiver: &klio_runtime::Value,
        owner_class: &str,
        qualifier: Option<&str>,
        name: &str,
        args: &[klio_runtime::Value],
        _arg_names: &[Option<String>],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        // Find the parent class of owner_class — `super.method()`
        // walks one step up the inheritance chain. With `super<Q>`,
        // dispatch on Q directly.
        let parent_name: Option<String> = if let Some(q) = qualifier {
            // Two cases share the `qualifier` slot:
            //   * `super<A>.member()` — A is one of the owner's
            //     supertypes; dispatch directly on A.
            //   * `super@Q.member()` — Q is an enclosing class
            //     name; dispatch on Q's own parent.
            let owner_supers: Vec<String> = self
                .classes
                .borrow()
                .get(owner_class)
                .map(|d| d.supertype_names.clone())
                .unwrap_or_default();
            if owner_supers.iter().any(|s| s == q) {
                Some(q.to_string())
            } else {
                self.classes
                    .borrow()
                    .get(q)
                    .and_then(|d| d.supertype_names.first().cloned())
            }
        } else if let Some(owner_def) = self.classes.borrow().get(owner_class).cloned() {
            owner_def.supertype_names.first().cloned()
        } else {
            None
        };
        let Some(parent_name) = parent_name else {
            return Err(klio_ir::eval::EvalError::Type(format!(
                "super.{name}: owner_class `{owner_class}` has no parent"
            )));
        };
        // Walk the supertype chain starting at `parent_name` and
        // dispatch the *first* class on the chain that declares the
        // method. Falling through to `call_member` would re-enter
        // virtual dispatch on the original receiver and recurse
        // forever for overriding methods.
        let mut current: Option<String> = Some(parent_name);
        while let Some(cname) = current.take() {
            let cls_ir = self
                .module
                .classes
                .iter()
                .find(|c| c.name == cname)
                .cloned();
            if let Some(cls_ir) = cls_ir {
                for fid in &cls_ir.methods {
                    if let Some(func) = self.module.funcs.get(fid.0 as usize).cloned()
                        && func.name == name
                    {
                        let mut all: Vec<klio_runtime::Value> = Vec::with_capacity(args.len() + 1);
                        all.push(receiver.clone());
                        all.extend_from_slice(args);
                        let module = Arc::clone(&self.module);
                        return klio_ir::eval::eval_with(&module, &func, all, self);
                    }
                }
            }
            // `super.<prop>` (a property read, lowered as a 0-arg
            // CallSuper): no method named `name` on this class — look
            // for its property getter. Walking from the parent skips
            // the overriding subclass's getter, so `override val x
            // get() = super.x` reads the base getter instead of
            // recursing into itself.
            if args.is_empty()
                && let Some(fid) = self
                    .prog
                    .instance_prop_getters
                    .get(&(cname.clone(), name.to_string()))
                    .copied()
                && let Some(func) = self.module.funcs.get(fid.0 as usize).cloned()
            {
                let module = Arc::clone(&self.module);
                return klio_ir::eval::eval_with(&module, &func, vec![receiver.clone()], self);
            }
            // Step to the next non-interface supertype.
            let next: Option<String> = self
                .classes
                .borrow()
                .get(&cname)
                .and_then(|d| d.supertype_names.first().cloned());
            current = next;
        }
        // `super.<prop>` where the base property has no custom getter
        // (a stored val/var): read the backing field off the receiver
        // instance directly rather than failing.
        if args.is_empty()
            && let klio_runtime::Value::Instance(inst) = receiver
            && let Some(v) = inst.borrow().get(name)
        {
            return Ok(v);
        }
        // The chain bottomed out at a builtin (`Any` / `Throwable`),
        // which declares no IR method. Supply the inherited
        // `Any`/`Throwable` semantics so `override fun toString() =
        // "${super.toString()} …"` works through the exception
        // hierarchy.
        if let klio_runtime::Value::Instance(inst) = receiver {
            match (name, args.len()) {
                ("toString", 0) => {
                    let i = inst.borrow();
                    let is_throwable = {
                        let classes = self.classes.borrow();
                        let mut stack: Vec<String> = vec![i.class.name.clone()];
                        let mut seen = std::collections::HashSet::new();
                        let mut found = false;
                        while let Some(cn) = stack.pop() {
                            if !seen.insert(cn.clone()) {
                                continue;
                            }
                            if matches!(
                                cn.as_str(),
                                "Throwable"
                                    | "Exception"
                                    | "RuntimeException"
                                    | "Error"
                                    | "CancellationException"
                            ) {
                                found = true;
                                break;
                            }
                            if let Some(d) = classes.get(&cn) {
                                stack.extend(d.supertype_names.iter().cloned());
                            }
                        }
                        found
                    };
                    if is_throwable {
                        let msg = match i.get("message") {
                            Some(klio_runtime::Value::String(s)) => Some((*s).clone()),
                            _ => None,
                        };
                        let s = match msg {
                            Some(m) => format!("{}: {m}", i.class.fqn),
                            None => i.class.fqn.clone(),
                        };
                        return Ok(klio_runtime::Value::String(Arc::new(s)));
                    }
                    return Ok(klio_runtime::Value::String(Arc::new(format!(
                        "{}@{:x}",
                        i.class.fqn, i.identity
                    ))));
                }
                ("hashCode", 0) => {
                    // Kotlin hashCode() reinterprets the identity bits as Int.
                    #[allow(clippy::cast_possible_wrap)]
                    let hash = inst.borrow().identity as i64;
                    return Ok(klio_runtime::Value::new_int(hash));
                }
                ("equals", 1) => {
                    let same = matches!(
                        &args[0],
                        klio_runtime::Value::Instance(o)
                            if klio_runtime::ObjRef::ptr_eq(inst, o)
                    );
                    return Ok(klio_runtime::Value::Bool(same));
                }
                _ => {}
            }
        }
        Err(klio_ir::eval::EvalError::Type(format!(
            "super.{name}: no matching method up the supertype chain from `{owner_class}`"
        )))
    }

    pub(crate) fn qualified_this(
        &mut self,
        receiver: &klio_runtime::Value,
        qualifier: &str,
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        // Walk parent chain on the receiver's class for direct
        // matches, then traverse the `outer` chain for inner-class
        // and local-class scenarios. `this@Outer` from an Inner
        // method walks to the captured outer instance.
        if let klio_runtime::Value::Instance(inst) = receiver {
            let mut cur: Option<Arc<klio_runtime::ClassDef>> =
                Some(Arc::clone(&inst.borrow().class));
            while let Some(c) = cur.take() {
                if c.name == qualifier || c.fqn == qualifier {
                    return Ok(receiver.clone());
                }
                cur.clone_from(&c.parent.borrow());
            }
            let mut outer = inst.borrow().outer.clone();
            while let Some(klio_runtime::Value::Instance(o_inst)) = outer.clone() {
                let cls = o_inst.borrow().class.clone();
                if cls.name == qualifier || cls.fqn == qualifier {
                    return Ok(klio_runtime::Value::Instance(o_inst.clone()));
                }
                let mut p = cls.parent.borrow().clone();
                while let Some(c) = p.take() {
                    if c.name == qualifier || c.fqn == qualifier {
                        return Ok(klio_runtime::Value::Instance(o_inst.clone()));
                    }
                    p.clone_from(&c.parent.borrow());
                }
                outer.clone_from(&o_inst.borrow().outer);
            }
        }
        // No class match — `this@<fn-name>` (extension fn label) or
        // `this@<lambda-label>` resolves to the immediate receiver
        // if the qualifier isn't a known class. The IR emits this
        // form for scope-fn lambdas + extension fns whose receiver
        // is already in `this`.
        // Receiver-lambda case: `this@Outer` written inside
        // `buildString { … }` (or another scope fn) in an `Outer`
        // member. The lambda receiver displaced the enclosing
        // instance; recover it from the enclosing-`this` stack and
        // match the qualifier against its class chain.
        // Walk the FULL enclosing-this chain (innermost first), not
        // just the top: nested scope-fn / receiver lambdas each
        // displace `this` and push a new entry, so the qualifier may
        // match an older entry deeper in the stack.
        let enclosing_chain: Vec<klio_runtime::Value> =
            with_outer_this(|s| s.borrow().iter().rev().cloned().collect());
        for encl_v in &enclosing_chain {
            if let klio_runtime::Value::Instance(o_inst) = encl_v {
                let mut cur: Option<Arc<klio_runtime::ClassDef>> =
                    Some(o_inst.borrow().class.clone());
                while let Some(c) = cur.take() {
                    if c.name == qualifier || c.fqn == qualifier {
                        return Ok(klio_runtime::Value::Instance(o_inst.clone()));
                    }
                    cur.clone_from(&c.parent.borrow());
                }
            }
        }
        let enclosing = enclosing_chain.into_iter().next();
        let known_class = self.classes.borrow().contains_key(qualifier);
        // An active receiver lambda whose implicit label is the qualifier
        // binds `this@<label>` to the receiver it was invoked with — the
        // precise, non-heuristic answer. This is what makes a nested
        // `with(n) { sb.apply { this@with } }` resolve `this@with` to `n`
        // rather than the inner `apply` receiver. Only consulted for
        // non-class qualifiers so `this@ClassName` keeps binding the class.
        if !known_class && let Some(v) = receiver_for_label(qualifier) {
            return Ok(v);
        }
        if !known_class && !matches!(receiver, klio_runtime::Value::Null) {
            // `this@<fn-label>` — the qualifier is an extension/fn
            // label, not a class. Inside a receiver lambda whose own
            // `this` displaced the enclosing extension receiver
            // (`IntRange.asFlow() = flow { forEach { emit(it) } }`:
            // `this@asFlow` is the range, not the FlowCollector), the
            // displaced receiver is the top of the enclosing-`this`
            // stack. Prefer it over the lambda receiver when distinct.
            // Prefer the displaced enclosing receiver only when the
            // lambda's own `this` (the receiver here) is NOT itself a
            // bound, usable value — i.e. when the captured `this` is a
            // builtin/intrinsic value standing in for a real receiver.
            // When the receiver IS a proper Instance, it is the labeled
            // extension's own receiver (the inline splice bound it), so
            // returning the enclosing-stack guess would mis-bind — this
            // is what broke `this@thenBy.compare` inside the stdlib
            // `Comparator<T>.thenBy { … }` SAM, where the enclosing
            // stack held an unrelated instance from the sort driver.
            // Only a real user `Instance` standing in `this` is the labeled
            // extension's own receiver (bound by an inline splice — the
            // `this@thenBy.compare` case). A builtin lambda receiver
            // (a `StringBuilder` from `buildString { … }`, etc.) is NOT the
            // labeled fn's receiver — `this@probe` inside `fun String.probe()
            // = buildString { … this@probe … }` must reach the enclosing
            // String, not the StringBuilder — so defer to the enclosing
            // receiver in that case.
            let receiver_is_bound_instance =
                matches!(receiver, klio_runtime::Value::Instance(_));
            if !receiver_is_bound_instance && let Some(encl) = enclosing {
                let same = match (&encl, receiver) {
                    (klio_runtime::Value::Instance(a), klio_runtime::Value::Instance(b)) => {
                        klio_runtime::ObjRef::ptr_eq(a, b)
                    }
                    _ => false,
                };
                if !same && !matches!(encl, klio_runtime::Value::Null | klio_runtime::Value::Unit) {
                    return Ok(encl);
                }
            }
            return Ok(receiver.clone());
        }
        Err(klio_ir::eval::EvalError::Type(format!(
            "`this@{qualifier}` is not bound in this scope"
        )))
    }

    // Single type-check dispatch over runtime value shapes.
    #[allow(clippy::too_many_lines)]
    /// Whether `name` denotes a concrete type a checked cast can test
    /// against (user/pack class, a reified type-param bound to a class,
    /// or a builtin). Anything else is an erased type parameter, for
    /// which `x as <that>` is an unchecked, non-throwing cast.
    pub(crate) fn is_concrete_cast_target(&mut self, name: &str) -> bool {
        let n = name.trim_end_matches('?');
        if n.is_empty() {
            return false;
        }
        // A user / pack class declaration.
        if self.module.class_id(n).is_some() || self.classes.borrow().contains_key(n) {
            return true;
        }
        // A reified type parameter bound to a concrete class value at
        // the call site (`Value::Class` whose name differs from the
        // bare param name) — the cast can be checked against it.
        if let Some(klio_runtime::Value::Class(c)) = self.globals.borrow().lookup(n) {
            if c.name != n {
                return true;
            }
        }
        is_builtin_type_name(n)
    }

    pub(crate) fn instance_of(
        &mut self,
        value: &klio_runtime::Value,
        ty: &klio_ir::TypeRef,
    ) -> bool {
        // `null is T?` is true for any nullable type. `null is T`
        // (non-null T) is false.
        if matches!(value, klio_runtime::Value::Null) {
            return ty.nullable;
        }
        // Reified type parameter resolution: the inline-fn splice
        // binds the reified type-param name (e.g. `T`) to the
        // call-site type argument's class value as a global. An
        // `x is T` check against the unresolved type-param name
        // redirects to a check against that bound class's simple
        // name. Without this, the body's `is T` would test
        // against a non-existent class `T` and always fall
        // through to `true`. Only fires when the type name is
        // not already a class in the module — otherwise a
        // legitimate `is Foo` check where `Foo` happens to be
        // registered as a global would recurse forever resolving
        // its own name.
        if self.module.class_id(&ty.name).is_none()
            && let Some(bound) = self.lookup_global(&ty.name)
            && let klio_runtime::Value::Class(cls) = bound
            && cls.name != ty.name
        {
            let resolved = klio_ir::TypeRef {
                name: cls.name.clone(),
                nullable: ty.nullable,
                args: ty.args.clone(),
            };
            return self.instance_of(value, &resolved);
        }
        // `Any` is the universal supertype for non-null values.
        if ty.name == "Any" {
            return true;
        }
        // Reflection-style checks against synth bound refs.
        // `Box::v` lowers as an Instance with `__bound_receiver__`
        // (a Class for unbound prop refs, an Instance for bound
        // method refs). Match KProperty / KFunction / KCallable
        // accordingly so `is`-checks return what kotlinc produces.
        if matches!(
            ty.name.as_str(),
            "KProperty"
                | "KCallable"
                | "KFunction"
                | "KFunction0"
                | "KFunction1"
                | "KFunction2"
                | "KMutableProperty"
        ) {
            if let klio_runtime::Value::Instance(inst) = value {
                let snap = inst.borrow();
                if snap.get("__bound_receiver__").is_some() {
                    let is_property = matches!(
                        snap.get("__bound_receiver__"),
                        Some(klio_runtime::Value::Class(_))
                    );
                    return match ty.name.as_str() {
                        "KProperty" | "KMutableProperty" => is_property,
                        "KFunction" | "KFunction0" | "KFunction1" | "KFunction2" => !is_property,
                        "KCallable" => true,
                        _ => false,
                    };
                }
            }
            // `::greet` for a top-level fn surfaces as a
            // Value::IrClosure (or Function). Treat those as
            // KFunction / KCallable.
            if matches!(
                value,
                klio_runtime::Value::IrClosure { .. }
                    | klio_runtime::Value::Lambda { .. }
                    | klio_runtime::Value::Function { .. }
            ) {
                return matches!(
                    ty.name.as_str(),
                    "KFunction" | "KCallable" | "KFunction0" | "KFunction1" | "KFunction2"
                );
            }
        }
        if ty.name == "KClass" {
            return matches!(value, klio_runtime::Value::Class(_));
        }
        if ty.name == "EnumEntries" {
            return matches!(
                value,
                klio_runtime::Value::List {
                    enum_class: Some(_),
                    ..
                }
            );
        }
        // Builtin collection / array / range values match their Kotlin
        // supertype names. klio represents these as host value variants
        // (not user Instances), so without this an `is`/`as` against
        // List/Collection/Iterable/Array/Set/Map/range fails — notably the
        // `(toTypedArray() as Array<T>)` cast inside upstream Iterable.sorted
        // and the `as List`/`as Collection` in many stdlib bodies, which
        // surfaced as "cast to `Array` failed". Mutable views match the
        // Mutable* supertypes only when the value is actually mutable.
        match value {
            klio_runtime::Value::Array { .. } if ty.name == "Array" => {
                return true;
            }
            // The read-only/mutable distinction is erased on the JVM (both map
            // to java.util.List/Set/Map), so kotlinc reports `listOf(…) is
            // MutableList` as true. Match that — our parity oracle is JVM
            // kotlinc — rather than gating on klio's mutability flag.
            klio_runtime::Value::List { .. } => {
                if matches!(
                    ty.name.as_str(),
                    "List"
                        | "Collection"
                        | "Iterable"
                        | "AbstractList"
                        | "AbstractCollection"
                        | "MutableList"
                        | "MutableCollection"
                        | "MutableIterable"
                        | "ArrayList"
                        | "AbstractMutableList"
                ) {
                    return true;
                }
            }
            klio_runtime::Value::Set { .. } => {
                if matches!(
                    ty.name.as_str(),
                    "Set"
                        | "Collection"
                        | "Iterable"
                        | "AbstractSet"
                        | "MutableSet"
                        | "MutableCollection"
                        | "MutableIterable"
                        | "HashSet"
                        | "LinkedHashSet"
                ) {
                    return true;
                }
            }
            klio_runtime::Value::Map { .. } => {
                if matches!(
                    ty.name.as_str(),
                    "Map" | "AbstractMap" | "MutableMap" | "HashMap" | "LinkedHashMap"
                ) {
                    return true;
                }
            }
            klio_runtime::Value::Range { .. } => {
                if matches!(
                    ty.name.as_str(),
                    "IntRange"
                        | "LongRange"
                        | "CharRange"
                        | "IntProgression"
                        | "LongProgression"
                        | "CharProgression"
                        | "ClosedRange"
                        | "OpenEndRange"
                        | "Iterable"
                ) {
                    return true;
                }
            }
            _ => {}
        }
        // Lambda / function values match `Function<R>`, `Function0`,
        // `Function1`, `Function2`, … (the arity-indexed `FunctionN`
        // hierarchy from kotlin.jvm.functions).
        if matches!(
            value,
            klio_runtime::Value::IrClosure { .. }
                | klio_runtime::Value::Lambda { .. }
                | klio_runtime::Value::Function { .. }
        ) {
            if ty.name == "Function" {
                return true;
            }
            if let Some(rest) = ty.name.strip_prefix("Function")
                && rest.chars().all(|c| c.is_ascii_digit())
                && !rest.is_empty()
            {
                return true;
            }
        }
        // Dotted nested-class names (`S.A`, `Outer.Inner`) — match
        // by the last segment, which corresponds to the lifted
        // top-level class name in our module table.
        if ty.name.contains('.')
            && let Some(last) = ty.name.rsplit('.').next()
        {
            let alt = klio_ir::TypeRef {
                name: last.to_string(),
                nullable: ty.nullable,
                args: ty.args.clone(),
            };
            return self.instance_of(value, &alt);
        }
        // Generic type-parameter casts (`x as T`) are erased at
        // runtime — Kotlin matches them unchecked. Single-letter
        // (or short uppercase) type names are conventionally
        // generic parameters and have no class entry; treat them
        // as accept-any-non-null — unless the call site bound a
        // reified type-param to a concrete `Value::Class`, in
        // which case redirect the check to that class's name.
        if matches!(
            ty.name.as_str(),
            "T" | "U" | "V" | "K" | "R" | "E" | "X" | "Y" | "Z" | "A" | "B" | "C" | "D"
        ) {
            let bound = self.globals.borrow().lookup(&ty.name);
            if let Some(klio_runtime::Value::Class(c)) = bound {
                let alt = klio_ir::TypeRef {
                    name: c.name.clone(),
                    nullable: ty.nullable,
                    args: ty.args.clone(),
                };
                return self.instance_of(value, &alt);
            }
            let is_user_class = self.classes.borrow().contains_key(&ty.name)
                || self.module.class_id(&ty.name).is_some();
            if !is_user_class {
                return !matches!(value, klio_runtime::Value::Null);
            }
        }
        // Exception values match by walking the builtin Throwable
        // hierarchy. The default impl returns "kotlin.Throwable" for
        // every Exception which loses the specific class name —
        // override so `catch (e: IllegalArgumentException)` matches
        // the throw site's actual fqn.
        if let klio_runtime::Value::Exception { fqn, .. } = value {
            let tail = fqn.rsplit('.').next().unwrap_or(fqn.as_str());
            if tail == ty.name {
                return true;
            }
            if matches!(ty.name.as_str(), "Throwable" | "Exception" | "Any") {
                return true;
            }
            // Walk the known parent chain (best-effort — full
            // multi-level walk lives in the runtime). The common
            // case here is the immediate parent.
            if matches!(
                (tail, ty.name.as_str()),
                (
                    "IllegalArgumentException"
                        | "IllegalStateException"
                        | "IndexOutOfBoundsException"
                        | "ArrayIndexOutOfBoundsException"
                        | "StringIndexOutOfBoundsException"
                        | "NullPointerException"
                        | "ArithmeticException"
                        | "ClassCastException"
                        | "NoSuchElementException"
                        | "NumberFormatException"
                        | "UnsupportedOperationException"
                        | "UninitializedPropertyAccessException"
                        | "ConcurrentModificationException"
                        | "NoWhenBranchMatchedException",
                    "RuntimeException"
                ) | (
                    "ArrayIndexOutOfBoundsException" | "StringIndexOutOfBoundsException",
                    "IndexOutOfBoundsException"
                ) | ("AssertionError", "Error")
                    | ("RuntimeException", "Exception")
                    | ("Error" | "Exception", "Throwable")
            ) {
                return true;
            }
            return false;
        }
        // User-class instance: walk the runtime ClassDef chain.
        if let klio_runtime::Value::Instance(inst) = value {
            let builtin_exception_names = [
                "Throwable",
                "Exception",
                "RuntimeException",
                "Error",
                "IllegalArgumentException",
                "IllegalStateException",
                "IndexOutOfBoundsException",
                "NoSuchElementException",
                "NullPointerException",
                "ArithmeticException",
                "ClassCastException",
                "NumberFormatException",
                "UnsupportedOperationException",
                "Any",
            ];
            let mut cur: Option<Arc<klio_runtime::ClassDef>> =
                Some(Arc::clone(&inst.borrow().class));
            while let Some(c) = cur.take() {
                if c.name == ty.name || c.fqn == ty.name {
                    return true;
                }
                if c.interfaces
                    .borrow()
                    .iter()
                    .any(|i| i.name == ty.name || i.fqn == ty.name)
                {
                    return true;
                }
                // Walk transitive interface supertypes:
                // `class Robot : FormalGreeter` where
                // `interface FormalGreeter : Greeter` matches both.
                {
                    let mut iq: std::collections::VecDeque<Arc<klio_runtime::ClassDef>> =
                        c.interfaces.borrow().iter().cloned().collect();
                    let mut iseen: std::collections::HashSet<String> =
                        std::collections::HashSet::new();
                    while let Some(iface) = iq.pop_front() {
                        if !iseen.insert(iface.name.clone()) {
                            continue;
                        }
                        if iface.name == ty.name || iface.fqn == ty.name {
                            return true;
                        }
                        for sup in &iface.supertype_names {
                            if sup == &ty.name {
                                return true;
                            }
                            if let Some(d) = self.classes.borrow().get(sup).cloned() {
                                iq.push_back(d);
                            }
                        }
                        for sup in iface.interfaces.borrow().iter() {
                            iq.push_back(Arc::clone(sup));
                        }
                    }
                }
                // Walk supertype names — covers chains where the
                // direct parent is a built-in exception class
                // that isn't itself in the user class table.
                for sup in &c.supertype_names {
                    if sup == &ty.name {
                        return true;
                    }
                    // A supertype that's a known builtin
                    // exception promotes to Throwable / Exception
                    // / Any matches as well.
                    if builtin_exception_names.contains(&sup.as_str())
                        && builtin_exception_names.contains(&ty.name.as_str())
                    {
                        return true;
                    }
                }
                if c.is_anonymous {
                    // Anonymous-object instances match their declared
                    // supertype interface name(s).
                    if c.supertype_names.iter().any(|n| n == &ty.name) {
                        return true;
                    }
                }
                cur.clone_from(&c.parent.borrow());
            }
            // `Any` matches every instance.
            if ty.name == "Any" {
                return true;
            }
            return false;
        }
        let nominal = value.type_fqn();
        if nominal == ty.name || nominal.ends_with(&format!(".{}", ty.name)) {
            return true;
        }
        // Builtin runtime types satisfy their nominal supertypes.
        value.is_runtime_type(&ty.name)
    }
}

/// Recognise the builtin / stdlib type names that are not registered as
/// user classes but are still concrete cast targets (so `x as String`
/// against a non-String still throws). Used to distinguish a real
/// checked cast from an erased type-parameter cast (`x as TBuilder`).
fn is_builtin_type_name(name: &str) -> bool {
    matches!(
        name,
        // Primitives + their boxed/number forms.
        "Int" | "Long" | "Short" | "Byte" | "Double" | "Float" | "Char" | "Boolean"
            | "UInt" | "ULong" | "UShort" | "UByte" | "Number" | "Unit" | "Nothing" | "Any"
            // Strings / char sequences.
            | "String" | "CharSequence" | "StringBuilder"
            // Comparison / common interfaces.
            | "Comparable" | "Comparator" | "Pair" | "Triple"
            // Collections + arrays (read-only and mutable).
            | "Array" | "IntArray" | "LongArray" | "ShortArray" | "ByteArray" | "DoubleArray"
            | "FloatArray" | "CharArray" | "BooleanArray" | "UIntArray" | "ULongArray"
            | "UShortArray" | "UByteArray"
            | "List" | "MutableList" | "ArrayList" | "AbstractList" | "AbstractMutableList"
            | "Collection" | "MutableCollection" | "AbstractCollection"
            | "Iterable" | "MutableIterable" | "Iterator" | "MutableIterator" | "ListIterator"
            | "Set" | "MutableSet" | "HashSet" | "LinkedHashSet" | "AbstractSet"
            | "Map" | "MutableMap" | "HashMap" | "LinkedHashMap" | "AbstractMap"
            | "Sequence" | "EnumEntries"
            // Ranges / progressions.
            | "IntRange" | "LongRange" | "CharRange" | "IntProgression" | "LongProgression"
            | "CharProgression" | "ClosedRange" | "OpenEndRange"
            // Reflection.
            | "KClass" | "KProperty" | "KCallable" | "KFunction" | "KMutableProperty"
            // Throwable hierarchy.
            | "Throwable" | "Exception" | "RuntimeException" | "Error"
            | "IllegalArgumentException" | "IllegalStateException" | "IndexOutOfBoundsException"
            | "ArrayIndexOutOfBoundsException" | "StringIndexOutOfBoundsException"
            | "NullPointerException" | "ArithmeticException" | "ClassCastException"
            | "NoSuchElementException" | "NumberFormatException" | "UnsupportedOperationException"
            | "UninitializedPropertyAccessException" | "ConcurrentModificationException"
            | "NoWhenBranchMatchedException" | "AssertionError"
    ) || name.starts_with("Function")
}
