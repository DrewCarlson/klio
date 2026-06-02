use super::{FuncBuilder, Inst, widen_numeric_literal, lower_expr_as_param_thunk, lower_expr_as_param_thunk_scoped, compute_boxed_vars, lower_block, lower_expr, Terminator};

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
/// `primary_params` for instance construction). The Class becomes
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

pub(crate) fn is_lower_anon_capture(name: &str) -> bool {
    LOWER_ANON_CAPTURES
        .with(|c| c.borrow().as_ref().is_some_and(|s| s.contains(name)))
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
        if let klio_ast::Decl::Class(inner) = m
            && !inner.is_companion {
                own_member_names.insert(inner.name.name.clone());
            }
    }
    // Companion-object members are visible under their bare
    // names inside this class's method bodies.
    for m in &c.members {
        if let klio_ast::Decl::Class(inner) = m
            && inner.is_companion {
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
/// `FuncId` is reserved before its body is lowered (enabling forward
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
pub(crate) fn lowered_type_name(ty: &klio_ast::TypeRef) -> String {
    if let Some(ft) = &ty.function {
        return format!("Function{}", ft.params.len());
    }
    ty.name.name.clone()
}

pub(crate) fn lower_function_body(
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
/// body `FuncId`, so a call that omits trailing defaulted args
/// (`A().g(5)` for `fun g(x, y = 10)`) gets them filled — the same
/// padding top-level / local functions already get. Methods carry an
/// implicit leading `this`, so default slots are offset by one.
pub(crate) fn record_method_param_defaults(
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

pub(crate) fn lower_function_body_with_implicit_owner(
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

pub(crate) fn lower_function_body_with_implicit_owner_priv(
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
    // A param whose declared type is one of the function's own generic
    // type-parameters (e.g. `a: T` of `fun <T : Comparable<T>>`).
    // Comparison operators on such an operand follow Kotlin's
    // `compareTo`-based total order, not the IEEE primitive — the
    // comparison-lowering arm consults this.
    if !f.type_params.is_empty() {
        let tp_names: std::collections::HashSet<&str> =
            f.type_params.iter().map(|tp| tp.name.name.as_str()).collect();
        for p in &f.params {
            if p.ty.function.is_none()
                && !p.ty.nullable
                && tp_names.contains(p.ty.name.name.as_str())
            {
                b.mark_generic_typed_param(&p.name.name);
            }
        }
    }
    if let Some(owner) = owner_class {
        let () = b.set_owner_class(owner.to_string());
    }
    if let Some(set) = own_members {
        let () = b.set_own_members(set.clone());
    }
    if let Some(map) = private_method_fids {
        b.set_private_method_fids(map.clone());
    }
    if f.is_tailrec {
        let () = b.set_tailrec_self(f.name.name.clone());
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
    // Carry the declared return type so the evaluator can normalize a
    // bare integer-literal result to a `Long` return slot (`fun f(): Long
    // = 0`). Inferred returns (no annotation) stay `Unit` — harmless, as
    // the coercion only triggers on an explicit `Long`.
    let return_ty = f.return_type.as_ref().map_or_else(crate::TypeRef::unit, |rt| crate::TypeRef {
        name: lowered_type_name(rt),
        nullable: rt.nullable,
        args: Vec::new(),
    });
    let mut func = b.finish(f.name.name.clone(), fqn, return_ty);
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
    if let Some(rt) = &f.receiver_type
        && let Some(first) = func.params.first_mut()
            && first.name == "this" {
                first.ty = crate::TypeRef {
                    name: lowered_type_name(rt),
                    nullable: rt.nullable,
                    args: Vec::new(),
                };
            }
    func.is_suspend = f.is_suspend;
    func
}
