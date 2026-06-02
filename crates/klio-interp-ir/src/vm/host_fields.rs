use crate::{VmHost, Arc, active_coro_scope, with_field_resolve_pair, with_outer_this, with_field_outer_guard, AtomicOrdering};

impl VmHost<'_> {
    pub(crate) fn get_field(
        &mut self,
        receiver: &klio_runtime::Value,
        name: &str,
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        // `e::class.simpleName` / `.qualifiedName` for a builtin exception:
        // `e::class` returns the Exception value itself (klio has no ClassDef
        // for the builtin Throwable hierarchy), so resolve the reflective name
        // fields off its fqn. simpleName is the last FQN segment; qualifiedName
        // is the full kotlin.* name.
        if matches!(name, "simpleName" | "qualifiedName")
            && let klio_runtime::Value::Exception { fqn, .. } = receiver {
                let v = if name == "simpleName" {
                    fqn.rsplit('.').next().unwrap_or(fqn).to_string()
                } else {
                    (**fqn).clone()
                };
                return Ok(klio_runtime::Value::String(Arc::new(v)));
            }
        // Suspend-implicit `kotlin.coroutines.coroutineContext`
        // intrinsic: it is the *running* coroutine's context, not a
        // member of whatever `this` a suspend member carries. klio
        // lowers a bare `coroutineContext` as a field read; redirect
        // it to the active coroutine scope's context. The scope's own
        // `coroutineContext` getter (receiver == the active scope)
        // resolves normally — no redirect, no recursion.
        if name == "coroutineContext"
            && let Some(scope) = active_coro_scope() {
                let same = matches!(
                    (&scope, receiver),
                    (
                        klio_runtime::Value::Instance(a),
                        klio_runtime::Value::Instance(b)
                    ) if klio_runtime::ObjRef::ptr_eq(a, b)
                );
                if !same {
                    return self.get_field(&scope, "coroutineContext");
                }
            }
        // A bare class/interface name used as a value resolves to its
        // companion object (Kotlin). Lowering emits this sentinel read
        // on the loaded class; yield the companion singleton when the
        // class declares one, else the receiver unchanged (no
        // companion / `object` singleton — left as-is).
        if name == "<class-companion-or-self>" {
            if let klio_runtime::Value::Class(cls) = receiver {
                if let Some(comp_name) = self
                    .module
                    .registry
                    .companion_singletons
                    .get(&cls.name)
                    .cloned()
                    && let Some(s) = self.globals.borrow().lookup(&comp_name) {
                        return Ok(s);
                    }
                // A bare `object` name in value position is the
                // singleton, not the class/`KClass`. The singleton
                // registers itself as a global on first construction;
                // if a top-level property initializer (`val d = O`)
                // reaches it before that, materialize it now so the
                // value is the instance, order-independent.
                if cls.is_object {
                    if let Some(s) = self.globals.borrow().lookup(&cls.name) {
                        return Ok(s);
                    }
                    let cid = self
                        .module
                        .class_index
                        .iter()
                        .find(|(n, _)| *n == cls.name)
                        .map(|(_, id)| *id);
                    if let Some(cid) = cid {
                        return self.new_instance(cid, &[]);
                    }
                }
            }
            return Ok(receiver.clone());
        }
        // Value-class internal-field read on `kotlin.Result` /
        // `kotlinx.coroutines.channels.ChannelResult`. Both upstream
        // declarations are inline value classes wrapping a single
        // `Any?`; klio represents both as `Value::Result { ok,
        // payload }`. A bare field read on either's internal
        // `value` / `holder` slot yields the payload (success values
        // are the bare value, failures hold the `Throwable`-shaped
        // Value::Exception). The names are upstream-internal, so an
        // exact-name match is safe.
        if matches!(name, "value" | "holder")
            && let klio_runtime::Value::Result { payload, .. } = receiver {
                return Ok((**payload).clone());
            }
        // Backing-field bypass: getter / setter bodies that reference
        // `field` lower into a member read on this synthetic name.
        // Route straight to the raw instance slot to break recursion.
        if let Some(raw) = name.strip_prefix("__klio_field__")
            && let klio_runtime::Value::Instance(inst) = receiver {
                if let Some(v) = inst.borrow().get(raw) {
                    return Ok(v);
                }
                return Ok(klio_runtime::Value::Null);
            }
        // `Thread` handle property reads (`t.name`, `t.isAlive`).
        // Mirrors the member-call interception in `call_member`.
        if let klio_runtime::Value::BoundMethod { fqn, receiver: tid, .. } = receiver
            && *fqn == "kotlin.concurrent.Thread" {
                let id = match **tid {
                    klio_runtime::Value::Long(v) => v as u64,
                    _ => 0,
                };
                match name {
                    "isAlive" => {
                        return Ok(klio_runtime::Value::Bool(self.thread_alive(id)))
                    }
                    "name" => {
                        return Ok(klio_runtime::Value::String(Arc::new(format!(
                            "klio-thread-{id}"
                        ))))
                    }
                    _ => {}
                }
            }
        // Custom getter — invoke its IR FuncId with the receiver
        // bound as `this`. Wins over the plain field read so a
        // `val full: String get() = "$first $last"` shape evaluates
        // the getter rather than returning a missing-field Null.
        // Enum: `Color.RED` / `Color.entries`. Resolves named
        // entries on a Value::Class for an enum and the
        // generated `entries` list / `values()` companion-style
        // accessor.
        if let klio_runtime::Value::Class(cls) = receiver
            && cls.is_enum {
                if name == "entries" {
                    let items: Vec<klio_runtime::Value> = cls
                        .enum_entries
                        .borrow()
                        .iter()
                        .map(|(_, v)| v.clone())
                        .collect();
                    return Ok(klio_runtime::Value::List {
                        items: klio_runtime::ObjRef::new(items),
                        mutable: false,
                        enum_class: Some(Arc::new(cls.name.clone())), backing: None,
                    });
                }
                if let Some((_, v)) = cls
                    .enum_entries
                    .borrow()
                    .iter()
                    .find(|(n, _)| n == name)
                {
                    return Ok(v.clone());
                }
            }
        // Bound method/property reference field reads:
        // `nameRef.name` / `.simpleName` resolve to the captured
        // method name.
        if let klio_runtime::Value::Instance(inst) = receiver {
            let snap = inst.borrow();
            if snap.get("__bound_receiver__").is_some()
                && let Some(klio_runtime::Value::String(n)) = snap.get("__bound_name__") {
                    match name {
                        "name" | "simpleName" => {
                            return Ok(klio_runtime::Value::String(Arc::clone(&n)));
                        }
                        _ => {}
                    }
                }
        }
        // KFunction reflection: `::main.name`, `::main.parameters`.
        // Top-level fn refs lower as `Value::IrClosure` pointing at
        // the lowered Func; surface its metadata as field reads so
        // user code can introspect a callable.
        if let klio_runtime::Value::IrClosure { id, .. } = receiver
            && let Some(info) = self.closures.get(*id as usize)
                && let Some(f) = self.module.funcs.get(info.body_func.0 as usize) {
                    match name {
                        "name" => {
                            return Ok(klio_runtime::Value::String(Arc::new(
                                f.name.clone(),
                            )));
                        }
                        "parameters" => {
                            let items: Vec<klio_runtime::Value> = f
                                .params
                                .iter()
                                .map(|p| {
                                    klio_runtime::Value::String(Arc::new(p.name.clone()))
                                })
                                .collect();
                            return Ok(klio_runtime::Value::List {
                                items: klio_runtime::ObjRef::new(items),
                                mutable: false,
                                enum_class: None, backing: None,
                            });
                        }
                        _ => {}
                    }
                }
        // Companion-object forwarding: `Foo.PI` reads `PI` from the
        // companion singleton when the receiver is the user class.
        // Enum entries (`Color.RED`) take precedence above; reaching
        // here means the name isn't an entry.
        if let klio_runtime::Value::Class(cls) = receiver {
            if let Some(comp_name) = self.module.registry.companion_singletons.get(&cls.name).cloned() {
                // `Counter.Factory` — the user-declared companion
                // name resolves to the companion singleton itself.
                let suffix = format!("$Companion${name}");
                if comp_name.ends_with(&suffix)
                    && let Some(s) = self.globals.borrow().lookup(&comp_name) {
                        return Ok(s);
                    }
                let singleton = self.globals.borrow().lookup(&comp_name);
                if let Some(singleton) = singleton
                    && let klio_runtime::Value::Instance(inst) = &singleton {
                        if let Some(v) = inst.borrow().get(name) {
                            return Ok(v);
                        }
                        // No plain backing field — the companion
                        // member may be a `val` with a custom getter
                        // (`val DISTANT_PAST get() = …`). Run that
                        // getter directly against the companion
                        // singleton (mirrors the instance getter
                        // path; no recursion through get_field).
                        let comp_cls = inst.borrow().class.name.clone();
                        let getter = self
                            .prog
                            .instance_prop_getters
                            .get(&(comp_cls, name.to_string()))
                            .copied();
                        if let Some(fid) = getter
                            && let Some(func) = self
                                .module
                                .funcs
                                .get(fid.0 as usize)
                                .cloned()
                            {
                                let module = Arc::clone(&self.module);
                                return klio_ir::eval::eval_with(
                                    &module,
                                    &func,
                                    vec![singleton.clone()],
                                    self,
                                );
                            }
                    }
            }
            // Nested singleton object: `Outer.Monotonic` /
            // `Sealed.Subclass` is a synthesised object singleton
            // published as a global. Its instance must win over the
            // synthesised class def so `Outer.Obj.member` reaches the
            // singleton rather than a bare KClass.
            if let Some(v) = self.globals.borrow().lookup(name)
                && matches!(v, klio_runtime::Value::Instance(_)) {
                    return Ok(v);
                }
            // Nested-class access on a class receiver: `Outer.Inner`
            // and `Sealed.Variant` resolve through the module's
            // global class table.
            if let Some(def) = self.classes.borrow().get(name).cloned() {
                return Ok(klio_runtime::Value::Class(def));
            }
            let _ = cls;
        }
        // A member property (its getter) outranks a same-named
        // extension property (Kotlin resolution). Without this, a
        // receiver smart-cast inside an extension getter
        // (`val Incomplete.isCancelling get() = this is Finishing &&
        // isCancelling`, where `Finishing` has its own member
        // `isCancelling`) re-dispatches the extension property on
        // itself and recurses forever. Skip the extension lookup when
        // the receiver's class hierarchy declares a member getter for
        // this name.
        let member_getter_shadows = if let klio_runtime::Value::Instance(i) =
            receiver
        {
            let mut cur = Some(i.borrow().class.name.clone());
            let mut seen: std::collections::HashSet<String> =
                std::collections::HashSet::new();
            let mut found = false;
            while let Some(cn) = cur.take() {
                if !seen.insert(cn.clone()) {
                    break;
                }
                if self
                    .prog
                    .instance_prop_getters
                    .contains_key(&(cn.clone(), name.to_string()))
                {
                    found = true;
                    break;
                }
                cur = self
                    .classes
                    .borrow()
                    .get(&cn)
                    .and_then(|d| d.supertype_names.first().cloned());
            }
            found
        } else {
            false
        };
        // Top-level extension property: `val T.name get() = ...`
        // — keyed by (receiver simple type, prop name). Falls
        // through to the standard lookup chain when the user
        // didn't declare an extension property for this combo.
        if !member_getter_shadows {
            let recv_simple: String = match receiver {
                klio_runtime::Value::Instance(i) => i.borrow().class.name.clone(),
                other => {
                    let f = other.type_fqn();
                    f.rsplit('.').next().unwrap_or(f).to_string()
                }
            };
            // An extension property declared on `Any`
            // (`internal val Any.classSimpleName`) applies to every
            // receiver. Probe the receiver's own class first, then
            // fall back to an `Any` extension property.
            let ext_fid = self
                .prog
                .extension_props
                .get(&(recv_simple.clone(), name.to_string()))
                .copied()
                .or_else(|| {
                    // An extension property declared on a supertype
                    // (`val CoroutineContext.coroutineName`) applies to
                    // a receiver whose concrete class is a subtype
                    // (`CombinedContext`, `EmptyCoroutineContext`, a
                    // context element …). Walk the receiver's runtime
                    // supertype chain before the `Any` fallback.
                    if let klio_runtime::Value::Instance(i) = receiver {
                        let mut queue: std::collections::VecDeque<String> =
                            i.borrow().class.supertype_names.iter().cloned().collect();
                        let mut seen: std::collections::HashSet<String> =
                            std::collections::HashSet::new();
                        while let Some(sup) = queue.pop_front() {
                            if !seen.insert(sup.clone()) {
                                continue;
                            }
                            if let Some(fid) = self
                                .prog
                                .extension_props
                                .get(&(sup.clone(), name.to_string()))
                                .copied()
                            {
                                return Some(fid);
                            }
                            if let Some(def) =
                                self.classes.borrow().get(&sup).cloned()
                            {
                                for s in &def.supertype_names {
                                    queue.push_back(s.clone());
                                }
                            }
                        }
                    }
                    None
                })
                .or_else(|| {
                    self.prog
                        .extension_props
                        .get(&("Any".to_string(), name.to_string()))
                        .copied()
                });
            if let Some(fid) = ext_fid {
                let func = self.module.funcs.get(fid.0 as usize).cloned().ok_or_else(|| {
                    klio_ir::eval::EvalError::Type(format!(
                        "extension prop FuncId {} out of range",
                        fid.0
                    ))
                })?;
                let module = Arc::clone(&self.module);
                return klio_ir::eval::eval_with(&module, &func, vec![receiver.clone()], self);
            }
        }
        // Reflection-style property/class accessors on the
        // synthetic KClass / KProperty values.
        match receiver {
            klio_runtime::Value::Class(cls) => match name {
                "simpleName" => {
                    return Ok(klio_runtime::Value::String(Arc::new(cls.name.clone())));
                }
                "qualifiedName" => {
                    return Ok(klio_runtime::Value::String(Arc::new(cls.fqn.clone())));
                }
                "isData" => return Ok(klio_runtime::Value::Bool(cls.is_data)),
                "isOpen" => return Ok(klio_runtime::Value::Bool(cls.is_open)),
                "isAbstract" => return Ok(klio_runtime::Value::Bool(cls.is_abstract)),
                "isSealed" => return Ok(klio_runtime::Value::Bool(cls.is_sealed)),
                "isFinal" => {
                    return Ok(klio_runtime::Value::Bool(!cls.is_open && !cls.is_abstract));
                }
                "isCompanion" => {
                    return Ok(klio_runtime::Value::Bool(
                        self.module.registry.companion_singletons.values().any(|v| v == &cls.name),
                    ));
                }
                "isInner" => return Ok(klio_runtime::Value::Bool(cls.is_inner)),
                "isInterface" => return Ok(klio_runtime::Value::Bool(cls.is_interface)),
                "isFun" => return Ok(klio_runtime::Value::Bool(cls.is_fun_interface)),
                "objectInstance" => {
                    if cls.is_object
                        && let Some(v) = self.globals.borrow().lookup(&cls.name) {
                            return Ok(v);
                        }
                    return Ok(klio_runtime::Value::Null);
                }
                "members" | "declaredMembers" | "functions" | "declaredFunctions"
                | "memberFunctions" | "memberProperties" | "declaredMemberProperties" => {
                    let mut items: Vec<klio_runtime::Value> = Vec::new();
                    for fid in self
                        .module
                        .classes
                        .iter()
                        .find(|c| c.name == cls.name)
                        .map(|c| c.methods.clone())
                        .unwrap_or_default()
                    {
                        if let Some(f) = self.module.funcs.get(fid.0 as usize) {
                            items.push(klio_runtime::Value::PropertyRef {
                                name: Arc::new(f.name.clone()),
                            });
                        }
                    }
                    for p in &cls.primary_params {
                        if p.property.is_some() {
                            items.push(klio_runtime::Value::PropertyRef {
                                name: Arc::new(p.name.clone()),
                            });
                        }
                    }
                    for p in &cls.body_properties {
                        items.push(klio_runtime::Value::PropertyRef {
                            name: Arc::new(p.name.clone()),
                        });
                    }
                    return Ok(klio_runtime::Value::List {
                        items: klio_runtime::ObjRef::new(items),
                        mutable: false,
                        enum_class: None, backing: None,
                    });
                }
                "supertypes" => {
                    let items: Vec<klio_runtime::Value> = cls
                        .supertype_names
                        .iter()
                        .map(|n| {
                            if let Some(c) = self.classes.borrow().get(n).cloned() {
                                klio_runtime::Value::Class(c)
                            } else {
                                klio_runtime::Value::String(Arc::new(n.clone()))
                            }
                        })
                        .collect();
                    return Ok(klio_runtime::Value::List {
                        items: klio_runtime::ObjRef::new(items),
                        mutable: false,
                        enum_class: None, backing: None,
                    });
                }
                "sealedSubclasses" => {
                    let items: Vec<klio_runtime::Value> = self
                        .classes
                        .borrow()
                        .values()
                        .filter(|c| c.supertype_names.iter().any(|n| n == &cls.name))
                        .map(|c| klio_runtime::Value::Class(Arc::clone(c)))
                        .collect();
                    return Ok(klio_runtime::Value::List {
                        items: klio_runtime::ObjRef::new(items),
                        mutable: false,
                        enum_class: None, backing: None,
                    });
                }
                _ => {}
            },
            klio_runtime::Value::PropertyRef { name: pname } => match name {
                "name" | "simpleName" => {
                    return Ok(klio_runtime::Value::String(Arc::clone(pname)));
                }
                "isInitialized" => {
                    // `::name.isInitialized` walks the enclosing-this
                    // chain for a class that declares `name` as a
                    // lateinit property; the value is true iff the
                    // field is set to a non-Null (lateinit slots are
                    // pre-seeded with Null and only the first write
                    // replaces them).
                    let prop_name = (**pname).clone();
                    let chain: Vec<klio_runtime::Value> = self.enclosing_this_chain();
                    for o in chain {
                        if let klio_runtime::Value::Instance(inst) = o {
                            let b = inst.borrow();
                            let is_lateinit = b
                                .class
                                .body_properties
                                .iter()
                                .any(|p| p.name == prop_name && p.is_lateinit);
                            if !is_lateinit {
                                continue;
                            }
                            let initialised = b
                                .fields
                                .iter()
                                .any(|(n, v)| {
                                    n == &prop_name
                                        && !matches!(v, klio_runtime::Value::Null)
                                });
                            return Ok(klio_runtime::Value::Bool(initialised));
                        }
                    }
                    return Ok(klio_runtime::Value::Bool(false));
                }
                _ => {}
            },
            _ => {}
        }
        // `lastIndex` / `indices` on arrays + lists + strings.
        if name == "lastIndex" {
            let len_opt: Option<i64> = match receiver {
                klio_runtime::Value::Array { items, .. } => Some(items.borrow().len() as i64),
                klio_runtime::Value::List { items, .. } => Some(items.borrow().len() as i64),
                klio_runtime::Value::String(s) => Some(s.encode_utf16().count() as i64),
                _ => None,
            };
            if let Some(len) = len_opt {
                return Ok(klio_runtime::Value::new_int(len - 1));
            }
        }
        if name == "indices" {
            let len_opt: Option<i64> = match receiver {
                klio_runtime::Value::Array { items, .. } => Some(items.borrow().len() as i64),
                klio_runtime::Value::List { items, .. } => Some(items.borrow().len() as i64),
                klio_runtime::Value::String(s) => Some(s.encode_utf16().count() as i64),
                _ => None,
            };
            if let Some(len) = len_opt {
                return Ok(klio_runtime::Value::Range {
                    start: 0,
                    end: len - 1,
                    step: 1,
                    kind: klio_runtime::RangeKind::Int,
                });
            }
        }
        // `size` on arrays + collections.
        if name == "size" {
            match receiver {
                klio_runtime::Value::Array { items, .. } => {
                    return Ok(klio_runtime::Value::new_int(items.borrow().len() as i64));
                }
                klio_runtime::Value::List { items, .. } => {
                    return Ok(klio_runtime::Value::new_int(items.borrow().len() as i64));
                }
                klio_runtime::Value::Set { items, .. } => {
                    return Ok(klio_runtime::Value::new_int(items.borrow().len() as i64));
                }
                klio_runtime::Value::Map { entries, .. } => {
                    return Ok(klio_runtime::Value::new_int(entries.borrow().len() as i64));
                }
                _ => {}
            }
        }
        if let klio_runtime::Value::Instance(inst) = receiver {
            let class_name = inst.borrow().class.name.clone();
            // Walk the supertype chain looking for `(class, name)` in
            // the delegated-body-props registry. The instance's own
            // class is checked first; a hit on an ancestor means the
            // delegate was declared there, but the underlying field
            // slot is still present on this instance (instances
            // inherit superclass body fields).
            let delegate_owner: Option<String> = {
                let mut owner: Option<String> = None;
                let mut cur = Some(class_name.clone());
                let mut seen: std::collections::HashSet<String> =
                    std::collections::HashSet::new();
                while let Some(cn) = cur.take() {
                    if !seen.insert(cn.clone()) {
                        break;
                    }
                    if self
                        .module
                        .registry
                        .delegated_body_props
                        .contains(&(cn.clone(), name.to_string()))
                    {
                        owner = Some(cn);
                        break;
                    }
                    cur = self
                        .classes
                        .borrow()
                        .get(&cn)
                        .and_then(|d| d.supertype_names.first().cloned());
                }
                owner
            };
            if delegate_owner.is_some() {
                let raw = inst.borrow().get(name);
                if let Some(d) = raw {
                    let prop_ref = klio_runtime::Value::PropertyRef {
                        name: Arc::new(name.to_string()),
                    };
                    return <Self as klio_ir::eval::Host>::call_member(
                        self,
                        &d,
                        "getValue",
                        &[receiver.clone(), prop_ref],
                    );
                }
            }
            // Probe the instance's class then its supertype chain:
            // a property getter declared on a (sealed) base
            // (`DateTimePeriod.months`) is invoked on a subclass
            // instance (`DatePeriod`), so the
            // `(declaring-class, prop)` key is an ancestor's.
            let recv_fqn = inst.borrow().class.fqn.clone();
            let getter_fid = {
                let mut found: Option<klio_ir::FuncId> = None;
                // Resolve the receiver's own class by its
                // package-qualified FQN: the simple-name getter table
                // can collide across packages. When the class is
                // package-qualified, only its FQN-keyed entry may
                // bind the getter for its own properties; a miss
                // means this class has no such getter (use the raw
                // field) rather than borrowing a same-simple-name
                // sibling's. Supertype levels keep the simple-name
                // walk (their names are recorded simple).
                let own_is_qualified = recv_fqn != class_name;
                if own_is_qualified {
                    found = self
                        .prog
                        .instance_prop_getters
                        .get(&(recv_fqn.clone(), name.to_string()))
                        .copied();
                }
                if found.is_none() {
                    let mut cur = if own_is_qualified {
                        // Skip the colliding own-class simple-name
                        // probe and continue from this instance's
                        // supertypes — `self.classes` is simple-name
                        // keyed, so looking the own class up there
                        // could return a same-name sibling from
                        // another package and walk its hierarchy.
                        inst.borrow().class.supertype_names.first().cloned()
                    } else {
                        Some(class_name.clone())
                    };
                    let mut seen: std::collections::HashSet<String> =
                        std::collections::HashSet::new();
                    while let Some(cn) = cur.take() {
                        if !seen.insert(cn.clone()) {
                            break;
                        }
                        if let Some(fid) = self
                            .prog
                            .instance_prop_getters
                            .get(&(cn.clone(), name.to_string()))
                            .copied()
                        {
                            found = Some(fid);
                            break;
                        }
                        cur = self
                            .classes
                            .borrow()
                            .get(&cn)
                            .and_then(|d| d.supertype_names.first().cloned());
                    }
                }
                found
            };
            if let Some(fid) = getter_fid {
                let func = self
                    .module
                    .funcs
                    .get(fid.0 as usize)
                    .cloned()
                    .ok_or_else(|| {
                        klio_ir::eval::EvalError::Type(format!(
                            "getter FuncId {} out of range",
                            fid.0
                        ))
                    })?;
                let module = Arc::clone(&self.module);
                return klio_ir::eval::eval_with(&module, &func, vec![receiver.clone()], self);
            }
            if let Some(v) = inst.borrow().get(name) {
                // `lateinit var x: T` reads before the first write
                // throw `UninitializedPropertyAccessException` per
                // Kotlin semantics. The body-property's lateinit
                // flag pre-seeded the slot with Null.
                if matches!(v, klio_runtime::Value::Null) {
                    let is_lateinit = inst
                        .borrow()
                        .class
                        .body_properties
                        .iter()
                        .any(|p| p.name == name && p.is_lateinit);
                    if is_lateinit {
                        return Err(klio_ir::eval::EvalError::Throw(
                            klio_runtime::Value::Exception {
                                fqn: Arc::new(
                                    "kotlin.UninitializedPropertyAccessException"
                                        .to_string(),
                                ),
                                message: Some(Arc::new(format!(
                                    "lateinit property {name} has not been initialized"
                                ))),
                                cause: None,
                            },
                        ));
                    }
                }
                // Auto-unwrap instance-level delegates so
                // `val x by lazy { … }` reads return the resolved
                // value rather than the Delegate wrapper.
                if let klio_runtime::Value::Delegate(d) = &v {
                    let state = d.borrow().clone();
                    match state {
                        klio_runtime::DelegateKind::Lazy { producer, cached } => {
                            if let Some(c) = cached {
                                return Ok(c);
                            }
                            let result = <Self as klio_ir::eval::Host>::call_value(
                                self, &producer, &[],
                            )?;
                            if let klio_runtime::DelegateKind::Lazy { cached, .. } =
                                &mut *d.borrow_mut()
                            {
                                *cached = Some(result.clone());
                            }
                            return Ok(result);
                        }
                        klio_runtime::DelegateKind::Observable { value, .. } => {
                            return Ok(value);
                        }
                        klio_runtime::DelegateKind::NotNull { value, .. } => {
                            return match value {
                                Some(x) => Ok(x),
                                None => Err(klio_ir::eval::EvalError::Throw(
                                    klio_runtime::Value::Exception {
                                        fqn: Arc::new(
                                            "kotlin.IllegalStateException".into(),
                                        ),
                                        message: Some(Arc::new(format!(
                                            "Property {name} should be initialized before get."
                                        ))),
                                        cause: None,
                                    },
                                )),
                            };
                        }
                    }
                }
                return Ok(v);
            }
            // Walk the class's parent + interface chain looking for
            // a companion singleton that owns the field. Instance
            // methods referencing companion members lower as
            // `this.X`, which lands here after the instance's own
            // fields miss.
            let mut queue: Vec<Arc<klio_runtime::ClassDef>> =
                vec![inst.borrow().class.clone()];
            let mut visited: std::collections::HashSet<String> =
                std::collections::HashSet::new();
            while let Some(c) = queue.pop() {
                if !visited.insert(c.name.clone()) {
                    continue;
                }
                if let Some(comp_name) = self.module.registry.companion_singletons.get(&c.name).cloned() {
                    let singleton = self.globals.borrow().lookup(&comp_name);
                    if let Some(singleton) = singleton
                        && let klio_runtime::Value::Instance(cinst) = &singleton
                            && let Some(v) = cinst.borrow().get(name) {
                                return Ok(v);
                            }
                }
                if let Some(p) = c.parent.borrow().clone() {
                    queue.push(p);
                }
                for ifc in c.interfaces.borrow().iter() {
                    queue.push(Arc::clone(ifc));
                }
            }
            // Outer-instance chain fallback: an inner-class method
            // body referencing `x` (a field of the enclosing class)
            // lowers as `this.x`. The instance keeps a reference to
            // its outer in `InstanceData.outer`; walk the chain.
            // Companion singletons store the outer-class itself
            // (Value::Class) to resolve enum-static reads like
            // `entries` from companion method bodies.
            let mut cur_outer = inst.borrow().outer.clone();
            while let Some(o) = cur_outer.clone() {
                match &o {
                    klio_runtime::Value::Instance(outer_inst) => {
                        if let Some(v) = outer_inst.borrow().get(name) {
                            return Ok(v);
                        }
                        // Kotlin: an inner class accessing an enclosing
                        // instance's property goes through that
                        // property's accessor. A getter-only outer
                        // An outer-class property accessed through an
                        // inner instance may not exist as a raw field
                        // and only resolves through the outer's
                        // getter — bounded by the identity+name guard
                        // so mutually-forwarding instances cannot loop.
                        let oid =
                            klio_runtime::ObjRef::as_ptr(outer_inst) as usize;
                        if let Some(Ok(v)) = with_field_resolve_pair(
                            oid,
                            name,
                            || self.get_field(&o, name),
                        )
                            && !matches!(v, klio_runtime::Value::Unit) {
                                return Ok(v);
                            }
                        cur_outer = outer_inst.borrow().outer.clone();
                    }
                    klio_runtime::Value::Class(cls) => {
                        if let Ok(v) = self.get_field(&o, name) {
                            return Ok(v);
                        }
                        // Step to the enclosing class — nested
                        // companions chain `Inner` → `Outer` so
                        // bare-name lookups for outer companion
                        // statics resolve.
                        cur_outer = self.module.registry
                            .enclosing_class
                            .get(&cls.name)
                            .cloned()
                            .and_then(|n| self.classes.borrow().get(&n).cloned())
                            .map(klio_runtime::Value::Class);
                    }
                    _ => cur_outer = None,
                }
            }
            // Enum entry bare-name access: an enum method body
            // referencing `RED` lowers as `this.RED`. Resolve
            // through the class's entries table.
            let class_def = inst.borrow().class.clone();
            if class_def.is_enum {
                if let Some((_, v)) = class_def
                    .enum_entries
                    .borrow()
                    .iter()
                    .find(|(n, _)| n == name)
                {
                    return Ok(v.clone());
                }
                if name == "entries" {
                    let items: Vec<klio_runtime::Value> = class_def
                        .enum_entries
                        .borrow()
                        .iter()
                        .map(|(_, v)| v.clone())
                        .collect();
                    return Ok(klio_runtime::Value::List {
                        items: klio_runtime::ObjRef::new(items),
                        mutable: false,
                        enum_class: Some(Arc::new(class_def.name.clone())), backing: None,
                    });
                }
            }
            // Nested-class fallback: a method body referencing
            // `State` (a lifted nested class declared inside the
            // outer) lowers as `this.State`. Resolve through the
            // global class table when the instance has no field.
            if let Some(def) = self.classes.borrow().get(name).cloned() {
                return Ok(klio_runtime::Value::Class(def));
            }
            // Top-level global / module-scoped fallback. Mirrors the
            // `LoadFromThisOrGlobal` Inst path for plain `GetField`s
            // emitted on `this`.
            if let Some(v) = self.globals.borrow().lookup(name) {
                return Ok(v);
            }
        }
        // Stdlib property read on a built-in type — `"abc".length`,
        // `arr.size`, etc. The stdlib registers these as 1-arg
        // intrinsics that take the receiver as their sole arg.
        let type_fqn = receiver.type_fqn();
        let probes = [
            format!("{type_fqn}.{name}"),
            format!("kotlin.collections.{name}"),
            format!("kotlin.text.{name}"),
            format!("kotlin.math.{name}"),
            format!("kotlin.{name}"),
        ];
        for probe in &probes {
            if let Some(func) = self.lookup_intrinsic(probe) {
                let args = [receiver.clone()];
                return self.dispatch_intrinsic(func, &args);
            }
        }
        // Class-delegation forwarding for property reads: a
        // `: I by g` instance's missing fields forward to the
        // stored delegate.
        if let klio_runtime::Value::Instance(inst) = receiver {
            let delegates: Vec<klio_runtime::Value> = inst
                .borrow()
                .fields
                .iter()
                .filter_map(|(n, v)| {
                    if n.starts_with("__delegate__") {
                        Some(v.clone())
                    } else {
                        None
                    }
                })
                .collect();
            for d in delegates {
                if let Ok(v) = self.get_field(&d, name)
                    && !matches!(v, klio_runtime::Value::Unit) {
                        return Ok(v);
                    }
            }
        }
        // `Long.MAX_VALUE` / `Int.SIZE_BITS` / `Double.NaN` where the
        // qualifier resolved to the primitive's class value (e.g. a
        // bare `Long` inside a method body). Consult the stdlib
        // primitive-companion table by the class's simple name.
        if let klio_runtime::Value::Class(def) = receiver {
            let simple = def.name.rsplit('.').next().unwrap_or(&def.name);
            if let Some(v) = klio_stdlib::primitive_companion_const(simple, name) {
                return Ok(v);
            }
        }
        // Companion fallback for an instance receiver: a companion
        // `val` (incl. one with a custom getter) is in scope
        // unqualified inside the class's own member bodies
        // (`fun useMin() = MIN`). The bare read lowered as
        // `this.MIN`; the instance has no such field, so route to
        // the class's companion singleton (walking supertypes).
        // Skip when the receiver is itself a companion singleton —
        // resolving a sibling from inside the companion goes through
        // the normal field/getter path; re-forwarding here would
        // recurse into the same instance.
        if let klio_runtime::Value::Instance(inst) = receiver {
            let is_companion_recv =
                inst.borrow().class.name.contains("$Companion$");
            let mut cur = if is_companion_recv {
                None
            } else {
                Some(inst.borrow().class.name.clone())
            };
            let mut seen: std::collections::HashSet<String> =
                std::collections::HashSet::new();
            while let Some(cname) = cur.take() {
                if !seen.insert(cname.clone()) {
                    break;
                }
                let comp_name = self
                    .module
                    .registry
                    .companion_singletons
                    .get(&cname)
                    .cloned();
                if let Some(comp_name) = comp_name {
                    let singleton = self.globals.borrow().lookup(&comp_name);
                    if let Some(singleton @ klio_runtime::Value::Instance(_)) =
                        singleton
                        && let Ok(v) = self.get_field(&singleton, name)
                            && !matches!(v, klio_runtime::Value::Unit) {
                                return Ok(v);
                            }
                }
                let next = self
                    .classes
                    .borrow()
                    .get(&cname)
                    .and_then(|d| d.supertype_names.first().cloned());
                cur = next;
            }
        }
        // Bare top-level `const val` / `val` referenced inside an
        // extension-fn body lowers as `this.<name>` (the receiver is
        // a bound param). When the receiver has no such field the
        // name is really the top-level binding — resolve it as a
        // global before failing.
        if let Some(v) = self.globals.borrow().lookup(name) {
            return Ok(v);
        }
        // Also resolve stdlib const-style globals (e.g. an imported
        // `COROUTINE_SUSPENDED`) through the full global path, which
        // probes package surfaces and auto-invokes a 0-arg constant.
        if let Some(v) = <Self as klio_ir::eval::Host>::lookup_global(self, name) {
            return Ok(v);
        }
        // A top-level property read before its initializer has run in
        // startup order — e.g. an earlier top-level initializer
        // constructs a class whose body reads a property declared
        // later in the file. On the JVM the static field would read
        // its zero/null default here; klio instead drives the
        // referenced property's initializer on demand (with a
        // re-entrancy guard so a genuine init cycle degrades to the
        // default rather than recursing) and caches the result, so
        // subsequent reads — and the eventual in-order startup pass —
        // observe the same value.
        if let Some(v) = self.ensure_top_level_inited(name)? {
            return Ok(v);
        }
        // Enclosing-receiver fallback: a bare member property read
        // (`onUndeliveredElement?.…`) inside a member-extension /
        // receiver-lambda body whose `this` is the inner receiver may
        // name a member of the lexically enclosing class instance.
        // Mirrors the call-side this/enclosing/global probe so a plain
        // `Inst::GetField` resolves the same enclosing member a bare
        // call would. Guard against re-probing the same receiver.
        let enclosing = with_outer_this(|s| s.borrow().last().cloned());
        if let Some(outer) = enclosing {
            let same = matches!(
                (&outer, receiver),
                (klio_runtime::Value::Instance(a), klio_runtime::Value::Instance(b))
                    if klio_runtime::ObjRef::ptr_eq(a, b)
            );
            if !same && !matches!(outer, klio_runtime::Value::Null | klio_runtime::Value::Unit) {
                let oid = match &outer {
                    klio_runtime::Value::Instance(i) => {
                        klio_runtime::ObjRef::as_ptr(i) as usize
                    }
                    _ => 0,
                };
                if let Some(Ok(v)) = with_field_resolve_pair(oid, name, || {
                    self.get_field(&outer, name)
                })
                    && !matches!(v, klio_runtime::Value::Unit) {
                        return Ok(v);
                    }
            }
        }
        // Inner-class outer-chain fallback: a bare member property
        // read inside an `inner class` method may name a field of an
        // enclosing-class instance, reachable via the receiver's
        // captured `outer` link.
        if let Some(v) = with_field_outer_guard(|active| {
            if !active {
                return None;
            }
            let mut cur = match receiver {
                klio_runtime::Value::Instance(i) => i.borrow().outer.clone(),
                _ => None,
            };
            while let Some(o) = cur {
                if matches!(o, klio_runtime::Value::Null | klio_runtime::Value::Unit) {
                    break;
                }
                if let Ok(v) = self.get_field(&o, name)
                    && !matches!(v, klio_runtime::Value::Unit) {
                        return Some(v);
                    }
                cur = match &o {
                    klio_runtime::Value::Instance(i) => i.borrow().outer.clone(),
                    _ => None,
                };
            }
            None
        }) {
            return Ok(v);
        }
        // Bare member of the enclosing class's companion accessed
        // from inside an instance method (Kotlin: companion statics
        // are visible by bare name from class body). Lowering emits
        // a `this.<name>` GetField; fall back to looking up the
        // companion singleton by the receiver's class name and
        // reading the member from there.
        if let klio_runtime::Value::Instance(inst) = receiver {
            let cls_name = inst.borrow().class.name.clone();
            if let Some(comp_name) =
                self.module.registry.companion_singletons.get(&cls_name).cloned()
            {
                let comp = self.globals.borrow().lookup(&comp_name);
                if let Some(comp) = comp
                    && !matches!(&comp, klio_runtime::Value::Instance(c) if klio_runtime::ObjRef::ptr_eq(c, inst))
                        && let Ok(v) = self.get_field(&comp, name) {
                            return Ok(v);
                        }
            }
        }
        Err(klio_ir::eval::EvalError::Unimplemented(format!(
            "Vm::get_field `{name}` on `{}`",
            receiver.type_fqn()
        )))
    }

    pub(crate) fn set_field(
        &mut self,
        receiver: &klio_runtime::Value,
        name: &str,
        value: klio_runtime::Value,
    ) -> Result<(), klio_ir::eval::EvalError> {
        // Companion forwarding for writes: `Foo.count = 1` routes
        // to the companion singleton instance's field.
        if let klio_runtime::Value::Class(cls) = receiver
            && let Some(comp_name) = self.module.registry.companion_singletons.get(&cls.name).cloned() {
                let singleton = self.globals.borrow().lookup(&comp_name);
                if let Some(singleton) = singleton
                    && let klio_runtime::Value::Instance(_) = &singleton {
                        return self.set_field(&singleton, name, value);
                    }
            }
        let bypass_setter = name.starts_with("__klio_field__");
        let real_name = name.strip_prefix("__klio_field__").unwrap_or(name);
        // Extension-property setter — `var T.x: ... set(value) {…}`
        // — keyed by `(receiver simple type, prop name)`.
        if !bypass_setter {
            let recv_simple: String = match receiver {
                klio_runtime::Value::Instance(i) => i.borrow().class.name.clone(),
                other => {
                    let f = other.type_fqn();
                    f.rsplit('.').next().unwrap_or(f).to_string()
                }
            };
            if let Some(fid) = self.prog
                .extension_prop_setters
                .get(&(recv_simple, real_name.to_string()))
                .copied()
            {
                let func = self
                    .module
                    .funcs
                    .get(fid.0 as usize)
                    .cloned()
                    .ok_or_else(|| {
                        klio_ir::eval::EvalError::Type(format!(
                            "ext setter FuncId {} out of range",
                            fid.0
                        ))
                    })?;
                let module = Arc::clone(&self.module);
                klio_ir::eval::eval_with(
                    &module,
                    &func,
                    vec![receiver.clone(), value],
                    self,
                )?;
                return Ok(());
            }
        }
        if let klio_runtime::Value::Instance(inst) = receiver {
            if !bypass_setter {
                let class_name = inst.borrow().class.name.clone();
                if self.module.registry
                    .delegated_body_props
                    .contains(&(class_name.clone(), real_name.to_string()))
                {
                    let raw = inst.borrow().get(real_name);
                    if let Some(d) = raw {
                        let prop_ref = klio_runtime::Value::PropertyRef {
                            name: Arc::new(real_name.to_string()),
                        };
                        <Self as klio_ir::eval::Host>::call_member(
                            self,
                            &d,
                            "setValue",
                            &[receiver.clone(), prop_ref, value],
                        )?;
                        return Ok(());
                    }
                }
                if let Some(fid) = self.prog
                    .instance_prop_setters
                    .get(&(class_name, real_name.to_string()))
                    .copied()
                {
                    let func = self
                        .module
                        .funcs
                        .get(fid.0 as usize)
                        .cloned()
                        .ok_or_else(|| {
                            klio_ir::eval::EvalError::Type(format!(
                                "setter FuncId {} out of range",
                                fid.0
                            ))
                        })?;
                    let module = Arc::clone(&self.module);
                    klio_ir::eval::eval_with(
                        &module,
                        &func,
                        vec![receiver.clone(), value],
                        self,
                    )?;
                    return Ok(());
                }
            }
            if !bypass_setter {
                let has_own = inst.borrow().get(real_name).is_some();
                let is_own_member = inst
                    .borrow()
                    .class
                    .primary_params
                    .iter()
                    .any(|p| p.name == real_name)
                    || inst
                        .borrow()
                        .class
                        .body_properties
                        .iter()
                        .any(|p| p.name == real_name);
                if !has_own && !is_own_member {
                    // Walk class chain (parents + interfaces) and
                    // probe each level's companion for the field.
                    let mut queue: Vec<Arc<klio_runtime::ClassDef>> =
                        vec![inst.borrow().class.clone()];
                    let mut visited: std::collections::HashSet<String> =
                        std::collections::HashSet::new();
                    while let Some(c) = queue.pop() {
                        if !visited.insert(c.name.clone()) {
                            continue;
                        }
                        if let Some(comp_name) =
                            self.module.registry.companion_singletons.get(&c.name).cloned()
                        {
                            let singleton = self.globals.borrow().lookup(&comp_name);
                            if let Some(singleton) = singleton
                                && let klio_runtime::Value::Instance(cinst) = &singleton
                                    && cinst.borrow().get(real_name).is_some() {
                                        return self.set_field(&singleton, real_name, value);
                                    }
                        }
                        if let Some(p) = c.parent.borrow().clone() {
                            queue.push(p);
                        }
                        for ifc in c.interfaces.borrow().iter() {
                            queue.push(Arc::clone(ifc));
                        }
                    }
                    let outer = inst.borrow().outer.clone();
                    if let Some(outer_val) = outer {
                        return self.set_field(&outer_val, real_name, value);
                    }
                }
            }
            inst.borrow_mut().define(real_name, value);
            return Ok(());
        }
        Err(klio_ir::eval::EvalError::Unimplemented(format!(
            "Vm::set_field `{name}` on `{}`",
            receiver.type_fqn()
        )))
    }

    pub(crate) fn member_ref(
        &mut self,
        receiver: &klio_runtime::Value,
        name: &str,
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        // `X::class` is a class reference, not a member ref —
        // return the class itself so `.simpleName` etc. resolve.
        // For instance receivers (`obj::class`) reach into the
        // runtime ClassDef so `.isData` / `.qualifiedName` etc.
        // inspect the runtime class.
        if name == "class" {
            if let klio_runtime::Value::Instance(inst) = receiver {
                return Ok(klio_runtime::Value::Class(Arc::clone(&inst.borrow().class)));
            }
            return Ok(receiver.clone());
        }
        // `recv::method` produces a callable wrapper that, when
        // invoked, dispatches `recv.method(args)`. We synthesise a
        // tiny Instance whose `__bound_receiver__` + `__bound_name__`
        // fields drive the call_value path below.
        let identity = self.instance_id_counter.fetch_add(1, AtomicOrdering::Relaxed) + 1;
        let synth_class = Arc::new(klio_runtime::ClassDef {
            name: format!("$bound_ref${name}"),
            fqn: format!("$bound_ref${name}"),
            annotation_names: Vec::new(),
            primary_params: Vec::new(),
            methods: Vec::new(),
            body_properties: Vec::new(),
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
            supertype_names: Vec::new(),
            parent: klio_runtime::ObjRef::new(None),
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
        let inst = klio_runtime::ObjRef::new(klio_runtime::InstanceData {
            class: synth_class,
            fields: vec![
                ("__bound_receiver__".to_string(), receiver.clone()),
                (
                    "__bound_name__".to_string(),
                    klio_runtime::Value::String(Arc::new(name.to_string())),
                ),
            ],
            outer: None,
            identity,
            native_state: None,
        });
        Ok(klio_runtime::Value::Instance(inst))
    }
}
