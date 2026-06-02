use crate::{
    Arc, ClosureInfo, MEMBER_ONLY_PROBE, VmHost, in_top_level_init, with_inner_outer_hint,
    with_outer_this,
};

impl VmHost<'_> {
    // Thread-local enclosing-`this` stack accessors; `self` is kept to
    // mirror the Host trait method signatures these forward to.
    #[allow(clippy::unused_self)]
    pub(crate) fn enclosing_this(&self) -> Option<klio_runtime::Value> {
        with_outer_this(|s| s.borrow().last().cloned())
    }

    #[allow(clippy::unused_self)]
    pub(crate) fn enclosing_this_chain(&self) -> Vec<klio_runtime::Value> {
        with_outer_this(|s| s.borrow().iter().rev().cloned().collect())
    }

    // Closure ids index the side-table; the u64 id narrows to usize.
    #[allow(clippy::cast_possible_truncation)]
    pub(crate) fn callable_receiver_shape(&self, v: &klio_runtime::Value) -> Option<(usize, bool)> {
        if let klio_runtime::Value::IrClosure { id, .. } = v {
            let info = self.closures.get(*id as usize)?;
            let func = self.module.funcs.get(info.body_func.0 as usize)?;
            let first_is_this = func.params.first().is_some_and(|p| p.name == "this");
            return Some((info.n_params, first_is_this));
        }
        None
    }

    // Closure ids index the side-table; the u64 id narrows to usize.
    #[allow(clippy::cast_possible_truncation)]
    pub(crate) fn closure_needs_this_capture(&self, v: &klio_runtime::Value) -> bool {
        if let klio_runtime::Value::IrClosure { id, captures } = v {
            let Some(info) = self.closures.get(*id as usize) else {
                return false;
            };
            let Some(idx) = info.capture_names.iter().position(|n| n == "this") else {
                return false;
            };
            let snap = captures.get(idx);
            !matches!(snap, Some(klio_runtime::Value::Instance(_)))
        } else {
            false
        }
    }

    // Closure ids index the side-table; the u64 id narrows to usize.
    #[allow(clippy::cast_possible_truncation)]
    pub(crate) fn override_closure_this(
        &mut self,
        v: &klio_runtime::Value,
        new_this: &klio_runtime::Value,
    ) {
        if let klio_runtime::Value::IrClosure { id, .. } = v
            && let Some(info) = self.closures.get(*id as usize)
            && let Some(idx) = info.capture_names.iter().position(|n| n == "this")
        {
            let captures = info.captures.clone();
            let mut cap = captures.borrow_mut();
            if idx < cap.len() {
                cap[idx] = new_this.clone();
            } else {
                cap.resize(idx + 1, klio_runtime::Value::Null);
                cap[idx] = new_this.clone();
            }
        }
    }

    pub(crate) fn call_member_only(
        &mut self,
        receiver: &klio_runtime::Value,
        name: &str,
        args: &[klio_runtime::Value],
        arg_names: &[Option<String>],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        let prev = MEMBER_ONLY_PROBE.with(|c| {
            let p = c.get();
            c.set(true);
            p
        });
        let r = self.call_member_named(receiver, name, args, arg_names);
        MEMBER_ONLY_PROBE.with(|c| c.set(prev));
        r
    }

    pub(crate) fn is_shadowing_capture(&self, name: &str) -> bool {
        let g = self.globals.borrow();
        if !g.has_parent() {
            return false;
        }
        matches!(
            g.lookup_local(name),
            Some(
                klio_runtime::Value::Lambda { .. }
                    | klio_runtime::Value::IrClosure { .. }
                    | klio_runtime::Value::Function { .. }
            )
        )
    }

    // Thread-local hint/enclosing-stack mutators; `self` is kept to mirror
    // the Host trait method signatures these forward to.
    #[allow(clippy::unused_self)]
    pub(crate) fn push_inner_outer_hint(&mut self, v: &klio_runtime::Value) {
        with_inner_outer_hint(|s| s.borrow_mut().push(v.clone()));
    }

    #[allow(clippy::unused_self)]
    pub(crate) fn pop_inner_outer_hint(&mut self) {
        with_inner_outer_hint(|s| {
            s.borrow_mut().pop();
        });
    }

    #[allow(clippy::unused_self)]
    pub(crate) fn push_access_enclosing(&self, v: &klio_runtime::Value) {
        with_outer_this(|s| s.borrow_mut().push(v.clone()));
    }

    #[allow(clippy::unused_self)]
    pub(crate) fn pop_access_enclosing(&self) {
        with_outer_this(|s| {
            s.borrow_mut().pop();
        });
    }

    // One ordered name-resolution probe chain (cached global, delegate
    // auto-resolve, user class/function, stdlib FQN probes, synthetic class
    // names, typealias follow); splitting it would fragment the fallthrough.
    #[allow(clippy::too_many_lines)]
    pub(crate) fn lookup_global(&mut self, name: &str) -> Option<klio_runtime::Value> {
        let cached = self.globals.borrow().lookup(name);
        // Forward reference to a top-level property whose own
        // initializer has not run yet (it is declared after the
        // initializer currently executing). The slot is still its
        // pre-init `Null` placeholder; drive the initializer on demand
        // so the real value — not `Null` — is observed (a cycle
        // degrades to the placeholder via the re-entrancy guard).
        if in_top_level_init()
            && matches!(&cached, None | Some(klio_runtime::Value::Null))
            && self.prog.top_level_prop_inits.contains_key(name)
            && let Ok(Some(v)) = self.ensure_top_level_inited(name)
            && !matches!(v, klio_runtime::Value::Null)
        {
            return Some(v);
        }
        if self
            .module
            .registry
            .top_level_delegated_props
            .contains(name)
            && let Some(v) = cached.clone()
            && matches!(v, klio_runtime::Value::Instance(_))
        {
            let prop_ref = klio_runtime::Value::PropertyRef {
                name: Arc::new(name.to_string()),
            };
            if let Ok(result) = <Self as klio_ir::eval::Host>::call_member(
                self,
                &v,
                "getValue",
                &[klio_runtime::Value::Null, prop_ref],
            ) {
                return Some(result);
            }
        }
        if let Some(v) = cached {
            // Delegate auto-resolve for top-level `var/val X by <delegate>`.
            if let klio_runtime::Value::Delegate(d) = &v {
                let state = d.borrow();
                match &*state {
                    klio_runtime::DelegateKind::Lazy { producer, cached } => {
                        if let Some(c) = cached.clone() {
                            return Some(c);
                        }
                        let prod = producer.clone();
                        drop(state);
                        if let Ok(result) =
                            <Self as klio_ir::eval::Host>::call_value(self, &prod, &[])
                        {
                            if let klio_runtime::DelegateKind::Lazy { cached, .. } =
                                &mut *d.borrow_mut()
                            {
                                *cached = Some(result.clone());
                            }
                            return Some(result);
                        }
                        return Some(v);
                    }
                    klio_runtime::DelegateKind::NotNull { value, name: _ } => {
                        if let Some(x) = value.clone() {
                            return Some(x);
                        }
                        // Reading a `Delegates.notNull` slot
                        // before it's been written throws
                        // IllegalStateException per Kotlin.
                        let _ = name;
                        return None;
                    }
                    klio_runtime::DelegateKind::Observable { value, .. } => {
                        return Some(value.clone());
                    }
                }
            }
            return Some(v);
        }
        // User-class lookup: returning Value::Class lets call sites
        // like `Foo(args)` dispatch through new_instance and lets
        // reflection (`Foo::class`) resolve.
        if let Some(def) = self.classes.borrow().get(name).cloned() {
            return Some(klio_runtime::Value::Class(def));
        }
        // User-declared top-level function: surface its body via
        // a synthetic Function value so calls like `val f = ::name;
        // f(args)` route through Vm::call_value. Skip bodyless
        // `expect` declarations — their `actual` lives in the host's
        // intrinsic table and the implicit-alias / direct-probe path
        // below resolves it.
        //
        // A bare (unqualified, receiverless) reference must never
        // resolve to an extension function (`fun T.name(...)`, lowered
        // with a synthetic `this` first param): an extension is only
        // callable on a receiver, so binding one here would consume a
        // positional argument as the receiver — e.g. bare `min(a, b)`
        // (an `import kotlin.math.min`) hijacked by the same-named
        // `IntArray.min()` collection extension, whose `this.size`
        // then ran against the `Int` argument. When `func_id` lands on
        // an extension, prefer a non-extension same-named sibling and
        // otherwise fall through to the intrinsic probes below.
        let is_ext_fid = |fid: klio_ir::FuncId, m: &klio_ir::Module| {
            m.funcs
                .get(fid.0 as usize)
                .and_then(|f| f.params.first())
                .is_some_and(|p| p.name == "this")
        };
        let chosen = self.module.func_id(name).and_then(|fid| {
            if is_ext_fid(fid, &self.module) {
                self.module
                    .funcs_by_simple_name(name)
                    .iter()
                    .copied()
                    .find(|&c| {
                        !is_ext_fid(c, &self.module)
                            && self
                                .module
                                .funcs
                                .get(c.0 as usize)
                                .is_some_and(|f| !f.blocks.is_empty())
                    })
            } else {
                Some(fid)
            }
        });
        if let Some(fid) = chosen {
            let func = self.module.funcs.get(fid.0 as usize).cloned()?;
            if !func.blocks.is_empty() {
                let n_params = func.params.len();
                let id = self.closures.push(ClosureInfo {
                    body_func: fid,
                    n_params,
                    capture_names: Vec::new(),
                    captures: klio_runtime::ObjRef::new(Vec::new()),
                });
                return Some(klio_runtime::Value::IrClosure {
                    id,
                    captures: Arc::new(Vec::new()),
                });
            }
        }
        // Probe stdlib by FQN for known package surfaces. Covers
        // bare references to `IntArray`, `compareBy`, `buildList`,
        // `naturalOrder`, `PI`, etc. that aren't in IMPLICIT_ALIASES.
        let direct_probes: [String; 12] = [
            name.to_string(),
            format!("kotlin.{name}"),
            format!("kotlin.collections.{name}"),
            format!("kotlin.text.{name}"),
            format!("kotlin.ranges.{name}"),
            format!("kotlin.math.{name}"),
            format!("kotlin.comparisons.{name}"),
            format!("kotlin.concurrent.{name}"),
            format!("kotlin.coroutines.{name}"),
            format!("kotlin.coroutines.intrinsics.{name}"),
            format!("kotlin.internal.{name}"),
            format!("kotlin.io.{name}"),
        ];
        // Loaded packs register their FQNs in `installed_bindings`.
        // For a bare-name reference, scan the overlay for a key that
        // ends with `.{name}` so user code can call an imported
        // function by simple name without having to teach
        // `direct_probes` about every pack's package.
        {
            let suffix = format!(".{name}");
            let entry: Option<(&'static str, klio_runtime::StdlibFn)> = self
                .prog
                .installed_bindings
                .entries()
                .find(|(k, _)| k.ends_with(&suffix));
            if let Some((fqn, func)) = entry {
                return Some(klio_runtime::Value::Intrinsic { fqn, func });
            }
        }
        for fqn in &direct_probes {
            if let Some(func) = self.lookup_intrinsic(fqn) {
                // Property-style intrinsic: a 0-arg constant whose
                // final segment is all uppercase + underscores
                // (PI, MAX_VALUE, NaN-ish names like NaN itself
                // would be lowercase-friendly — Kotlin convention
                // uses all-caps for constants). Auto-invoke so the
                // value flows through.
                let tail = fqn.rsplit('.').next().unwrap_or(fqn.as_str());
                let looks_const = !tail.is_empty()
                    && tail
                        .chars()
                        .all(|c| c.is_ascii_uppercase() || c == '_' || c.is_ascii_digit());
                let leaked: &'static str = Box::leak(fqn.clone().into_boxed_str());
                if looks_const && let Ok(v) = self.dispatch_intrinsic(func, &[]) {
                    return Some(v);
                }
                return Some(klio_runtime::Value::Intrinsic { fqn: leaked, func });
            }
        }
        // `Thread` static surface — a synthetic intrinsic value that
        // exposes `Thread.sleep(ms)` and `Thread.currentThread()`. The
        // static-call probe routes `Thread.sleep` / `Thread.currentThread`
        // through the `kotlin.concurrent.Thread.*` stdlib bindings; the
        // BoundMethod sentinel returned by `currentThread` reuses the
        // same `.name`/`.isAlive`/`.join` member interception as the
        // handle from `kotlin.concurrent.thread`.
        if name == "Thread" {
            return Some(klio_runtime::Value::Intrinsic {
                fqn: "kotlin.concurrent.Thread",
                func: |_ctx| {
                    Err(klio_runtime::RuntimeError::Type(
                        "Thread: use Thread.sleep(ms) / Thread.currentThread()".into(),
                    ))
                },
            });
        }
        // `Delegates` singleton — a synthetic intrinsic value that
        // exposes `notNull`, `observable`, and `vetoable` member
        // calls. The Vm intercepts those in call_member when the
        // receiver is this singleton.
        if name == "Delegates" {
            return Some(klio_runtime::Value::Intrinsic {
                fqn: "kotlin.properties.Delegates",
                func: |_ctx| {
                    Err(klio_runtime::RuntimeError::Type(
                        "Delegates: use Delegates.notNull / Delegates.observable / Delegates.vetoable"
                            .into(),
                    ))
                },
            });
        }
        // Primitive type names — `Int`, `Long`, `String`, etc. —
        // resolve to a synthetic `Value::Class` so `Int::class` and
        // `Int.MAX_VALUE` work. The synthetic ClassDef has the
        // simple name + a kotlin.* fqn for reflection-style reads.
        if matches!(
            name,
            "Int"
                | "Long"
                | "Short"
                | "Byte"
                | "Float"
                | "Double"
                | "Boolean"
                | "Char"
                | "String"
                | "Unit"
                | "Any"
                | "Nothing"
                | "UInt"
                | "ULong"
                | "UShort"
                | "UByte"
                | "Number"
        ) {
            let def = Arc::new(klio_runtime::ClassDef {
                name: name.to_string(),
                fqn: format!("kotlin.{name}"),
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
                is_anonymous: false,
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
            return Some(klio_runtime::Value::Class(def));
        }
        // Primitive-companion constants (`Int.MAX_VALUE`, `Double.NaN`,
        // `Long.SIZE_BITS`, …). The IR lowers these as a single
        // dotted-name global ref; we split on `.` and consult the
        // stdlib's primitive-companion table.
        if let Some((ty, member)) = name.split_once('.')
            && let Some(v) = klio_stdlib::primitive_companion_const(ty, member)
        {
            return Some(v);
        }
        // Package-qualified reference (not a call) to a user / pack
        // top-level class. The class table is keyed by simple name
        // (the package prefix lives on each decl's `fqn`), so retry
        // the trailing segment. Reached only after every other probe
        // returned `None`, so a name that already resolves is
        // untouched. Package-qualified *calls* are routed through
        // `Inst::Call` at lower time so they keep overload
        // resolution; this only covers bare refs.
        if let Some((_, tail)) = name.rsplit_once('.')
            && tail != name
            && !tail.is_empty()
            && let Some(def) = self.classes.borrow().get(tail).cloned()
        {
            return Some(klio_runtime::Value::Class(def));
        }
        // `typealias Alias = Target` — resolve the alias to the
        // aliased declaration for value/qualifier position
        // (`Alias.of(...)`, `Alias(...)`). Follow chains with a
        // cycle guard.
        {
            let mut cur = name.to_string();
            let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
            while let Some(target) = self.module.registry.type_aliases.get(&cur).cloned() {
                if !seen.insert(cur.clone()) {
                    break;
                }
                if let Some(v) = self.lookup_global(&target) {
                    return Some(v);
                }
                cur = target;
            }
        }
        None
    }

    pub(crate) fn store_global(
        &mut self,
        name: &str,
        value: klio_runtime::Value,
    ) -> Result<(), klio_ir::eval::EvalError> {
        if self
            .module
            .registry
            .top_level_delegated_props
            .contains(name)
        {
            let existing = self.globals.borrow().lookup(name);
            if let Some(d) = existing
                && matches!(d, klio_runtime::Value::Instance(_))
            {
                let prop_ref = klio_runtime::Value::PropertyRef {
                    name: Arc::new(name.to_string()),
                };
                <Self as klio_ir::eval::Host>::call_member(
                    self,
                    &d,
                    "setValue",
                    &[klio_runtime::Value::Null, prop_ref, value],
                )?;
                return Ok(());
            }
        }
        // Delegate-aware write: if the slot currently holds a
        // `Value::Delegate(NotNull/Observable)`, route the write
        // through the delegate's setValue semantics. Observable
        // fires its on_change callback (oldValue, newValue).
        let existing = self.globals.borrow().lookup(name);
        if let Some(klio_runtime::Value::Delegate(d)) = existing {
            let kind = d.borrow().clone();
            match kind {
                klio_runtime::DelegateKind::NotNull { .. } => {
                    *d.borrow_mut() = klio_runtime::DelegateKind::NotNull {
                        value: Some(value),
                        name: name.to_string(),
                    };
                    return Ok(());
                }
                klio_runtime::DelegateKind::Observable {
                    value: old,
                    on_change,
                } => {
                    *d.borrow_mut() = klio_runtime::DelegateKind::Observable {
                        value: value.clone(),
                        on_change: on_change.clone(),
                    };
                    let prop_ref = klio_runtime::Value::PropertyRef {
                        name: Arc::new(name.to_string()),
                    };
                    let _ = <Self as klio_ir::eval::Host>::call_value(
                        self,
                        &on_change,
                        &[prop_ref, old, value],
                    )?;
                    return Ok(());
                }
                klio_runtime::DelegateKind::Lazy { .. } => {}
            }
        }
        // Assign through the scope chain so a write to an existing
        // (top-level) binding from inside a child scope — a closure
        // or the coroutine-driver env — mutates the real global
        // instead of shadowing it with a transient local. Only a
        // genuinely new name defines here.
        if self
            .globals
            .borrow_mut()
            .assign(name, value.clone())
            .is_err()
        {
            self.globals.borrow_mut().define(name, value);
        }
        Ok(())
    }

    pub(crate) fn lookup_global_throwing(
        &mut self,
        name: &str,
    ) -> Result<Option<klio_runtime::Value>, klio_ir::eval::EvalError> {
        let raw = self.globals.borrow().lookup(name);
        if let Some(klio_runtime::Value::Delegate(d)) = &raw
            && let klio_runtime::DelegateKind::NotNull { value: None, .. } = &*d.borrow()
        {
            return Err(klio_ir::eval::EvalError::Throw(
                klio_runtime::Value::Exception {
                    fqn: Arc::new("kotlin.IllegalStateException".to_string()),
                    message: Some(Arc::new(format!(
                        "Property {name} should be initialized before get."
                    ))),
                    cause: None,
                },
            ));
        }
        // Top-level delegated property backed by an Instance delegate
        // (e.g. `by Delegates.notNull()` which inlines to a
        // NotNullProperty instance): dispatch getValue and PROPAGATE its
        // throw. `lookup_global` calls getValue too but swallows the
        // error and falls back to returning the delegate instance, so a
        // NotNullProperty read-before-init silently yielded the delegate
        // instead of throwing IllegalStateException.
        if self
            .module
            .registry
            .top_level_delegated_props
            .contains(name)
            && let Some(v @ klio_runtime::Value::Instance(_)) = raw.clone()
        {
            let prop_ref = klio_runtime::Value::PropertyRef {
                name: Arc::new(name.to_string()),
            };
            let result = <Self as klio_ir::eval::Host>::call_member(
                self,
                &v,
                "getValue",
                &[klio_runtime::Value::Null, prop_ref],
            )?;
            return Ok(Some(result));
        }
        Ok(self.lookup_global(name))
    }
}
