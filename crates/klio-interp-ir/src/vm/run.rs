use crate::{
    Arc, AtomicU64, Mutex, Output, ProgramImage, SendableVmSeed, SharedClosures, TlInitGuard, Vm,
    VmError, VmHost, VmIntrinsicHost, build,
};

impl Vm {
    /// Build a Vm around an already-lowered IR module. Stdlib
    /// aliases (`print`, `println`, `listOf`, ...) are installed
    /// into globals up front so identifiers covered by Kotlin's
    /// default imports resolve without an explicit `import`.
    #[must_use]
    // Takes the module Arc by value as part of the public constructor API.
    #[allow(clippy::needless_pass_by_value)]
    pub fn new(module: Arc<klio_ir::Module>) -> Self {
        let mut env = klio_runtime::Env::new();
        for (name, fqn) in klio_stdlib::IMPLICIT_ALIASES {
            if let Some(func) = klio_stdlib::implementation(fqn) {
                env.define(*name, klio_runtime::Value::Intrinsic { fqn, func });
            }
        }
        let globals = klio_runtime::ObjRef::new(env);
        Self {
            module: Arc::clone(&module),
            globals,
            scheduler: Box::new(klio_runtime::InProcessScheduler::new()),
            instance_id_counter: Arc::new(AtomicU64::new(0)),
            classes: klio_runtime::ObjRef::new(std::collections::HashMap::new()),
            top_level_props: Vec::new(),
            enum_entry_arg_inits: Vec::new(),
            class_default_outer: klio_runtime::ObjRef::new(std::collections::HashMap::new()),
            anon_methods: klio_runtime::ObjRef::new(std::collections::HashMap::new()),
            closures: SharedClosures::new(),
            prog: Arc::new(ProgramImage {
                top_level_prop_inits: std::collections::HashMap::new(),
                body_prop_inits: std::collections::HashMap::new(),
                instance_prop_getters: std::collections::HashMap::new(),
                instance_prop_setters: std::collections::HashMap::new(),
                parent_ctor_args: std::collections::HashMap::new(),
                init_blocks: std::collections::HashMap::new(),
                extension_props: std::collections::HashMap::new(),
                extension_prop_setters: std::collections::HashMap::new(),
                secondary_ctors: std::collections::HashMap::new(),
                primary_ctor_default_thunks: std::collections::HashMap::new(),
                class_delegates: std::collections::HashMap::new(),
                func_defaults: std::collections::HashMap::new(),
                installed_bindings: Arc::new(klio_stdlib::HostBindings::new()),
            }),
            out_sink: klio_runtime::SharedOutput::new(),
            threads: Arc::new(Mutex::new(std::collections::HashMap::new())),
        }
    }

    /// Install pack-provided host bindings. Probed before
    /// `klio_stdlib::implementation` during dispatch so a pack's
    /// FQN-keyed bindings shadow the stdlib's default lookup. Called
    /// before `run` (and before any thread spawn), so the program
    /// image is still uniquely owned and can be rebuilt in place.
    ///
    /// # Panics
    ///
    /// Panics if the program image is no longer uniquely owned, which
    /// happens when called after `run` or after a thread spawn has
    /// shared the image.
    pub fn set_installed_bindings(&mut self, bindings: klio_stdlib::HostBindings) {
        let prog =
            Arc::get_mut(&mut self.prog).expect("set_installed_bindings before run / thread spawn");
        prog.installed_bindings = Arc::new(bindings);
    }

    /// Build a Vm from a fully-prepared `build::BuiltModule`. The
    /// recommended entry point for the driver — it carries both the
    /// IR module and the synthesised runtime `ClassDef` table.
    #[must_use]
    pub fn from_built(built: build::BuiltModule) -> (Self, Option<klio_ir::FuncId>) {
        let main = built.main;
        let mut vm = Self::new(Arc::clone(&built.module));
        vm.classes = klio_runtime::ObjRef::new(built.classes);
        vm.top_level_props = built.top_level_props;
        vm.enum_entry_arg_inits = built.enum_entry_arg_inits;
        vm.prog = Arc::new(ProgramImage {
            top_level_prop_inits: vm.top_level_props.iter().cloned().collect(),
            body_prop_inits: built.body_prop_inits,
            instance_prop_getters: built.instance_prop_getters,
            instance_prop_setters: built.instance_prop_setters,
            parent_ctor_args: built.parent_ctor_args,
            init_blocks: built.init_blocks,
            extension_props: built.extension_props,
            extension_prop_setters: built.extension_prop_setters,
            secondary_ctors: built.secondary_ctors,
            primary_ctor_default_thunks: built.primary_ctor_default_thunks,
            class_delegates: built.class_delegates,
            func_defaults: built.func_defaults,
            installed_bindings: Arc::new(klio_stdlib::HostBindings::new()),
        });
        // Pre-populated enum-entry override methods land in the
        // same anon_methods side-table the Vm consults for
        // anon-object + local-class methods.
        for (key, value) in built.enum_entry_methods {
            vm.anon_methods
                .borrow_mut()
                .insert(key, (value.0, value.1, Vec::new()));
        }
        (vm, main)
    }

    /// Build a `VmHost` bound to this Vm's shared state for the
    /// duration of one evaluation. The immutable program image,
    /// closure table, id counter, and stdout sink are shared by
    /// handle; only the scheduler and `out` are borrowed.
    pub(crate) fn make_host<'s>(&'s mut self, out: &'s mut dyn Output) -> VmHost<'s> {
        VmHost {
            globals: self.globals.clone(),
            module: Arc::clone(&self.module),
            scheduler: &mut *self.scheduler,
            out,
            instance_id_counter: Arc::clone(&self.instance_id_counter),
            classes: self.classes.clone(),
            prog: Arc::clone(&self.prog),
            anon_methods: self.anon_methods.clone(),
            class_default_outer: self.class_default_outer.clone(),
            closures: self.closures.clone(),
            out_sink: self.out_sink.clone(),
            threads: Arc::clone(&self.threads),
        }
    }

    /// A `Send` snapshot of every handle a freshly spawned OS thread
    /// needs to materialize its own child `Vm`. Holding it does not
    /// keep the parent thread's borrows alive — every field is an
    /// owned `Arc`/`ObjRef`/atomic.
    #[must_use]
    pub fn spawn_child(&self) -> SendableVmSeed {
        SendableVmSeed {
            module: Arc::clone(&self.module),
            globals: self.globals.clone(),
            instance_id_counter: Arc::clone(&self.instance_id_counter),
            classes: self.classes.clone(),
            prog: Arc::clone(&self.prog),
            anon_methods: self.anon_methods.clone(),
            class_default_outer: self.class_default_outer.clone(),
            closures: self.closures.clone(),
            out_sink: self.out_sink.clone(),
            threads: Arc::clone(&self.threads),
        }
    }

    /// Invoke a thread-body callable on this (child) Vm, writing
    /// through the shared serialized sink. Used by the spawned-thread
    /// closure; the result is published by the caller before the
    /// joiner observes it.
    pub(crate) fn run_thread_block(
        &mut self,
        block: &klio_runtime::Value,
    ) -> Result<klio_runtime::Value, klio_runtime::RuntimeError> {
        use klio_runtime::IntrinsicHost;
        let mut sink = self.out_sink.clone();
        let host = self.make_host(&mut sink);
        let mut sink2 = host.out_sink.clone();
        let mut intrinsic = VmIntrinsicHost {
            scheduler: &mut *host.scheduler,
            module: Arc::clone(&host.module),
            closures: host.closures.clone(),
            globals: host.globals.clone(),
            classes: host.classes.clone(),
            prog: Arc::clone(&host.prog),
            anon_methods: host.anon_methods.clone(),
            class_default_outer: host.class_default_outer.clone(),
            instance_id_counter: Arc::clone(&host.instance_id_counter),
            out_sink: host.out_sink.clone(),
            threads: Arc::clone(&host.threads),
        };
        intrinsic.invoke_callable(block, &[], &mut sink2)
    }

    /// Run the program's `main` function.
    ///
    /// All evaluation — the root thread and every spawned
    /// `kotlin.concurrent.thread` child — writes through one shared
    /// serialized sink (`out_sink`). When the run (and every joined
    /// thread) completes, the accumulated output is drained into the
    /// caller's `out` in order. A single-threaded program has exactly
    /// one writer, so the drained bytes and their ordering are
    /// identical to writing `out` directly.
    pub fn run(
        &mut self,
        main: klio_ir::FuncId,
        out: &mut dyn Output,
    ) -> Result<klio_runtime::Value, VmError> {
        // Under the tracing-GC backing the globals env and the class
        // table are the live roots: every reachable Kotlin object is
        // reachable through one of them. Register them once before
        // execution (and before any thread spawn) so the collector's
        // mark phase has a complete root set — the same root set
        // `publish_env_deep` uses for cross-thread publication.
        #[cfg(feature = "gc")]
        {
            klio_runtime::gc::register_root_env(&self.globals);
            klio_runtime::gc::register_root_value(klio_runtime::Value::Map {
                entries: {
                    // The class table is `ObjRef<HashMap<..>>`, not a
                    // `Value`; wrap a clone of its entries so the
                    // tracer reaches every `ClassDef` graph too.
                    let m = self.classes.borrow();
                    let entries: Vec<(klio_runtime::Value, klio_runtime::Value)> = m
                        .values()
                        .map(|c| {
                            (
                                klio_runtime::Value::Null,
                                klio_runtime::Value::Class(Arc::clone(c)),
                            )
                        })
                        .collect();
                    klio_runtime::ObjRef::new(entries)
                },
                mutable: false,
            });
        }
        let result = self.run_inner(main);
        // Replay the recorded call sequence verbatim into the
        // caller's real sink. A single-threaded program recorded
        // exactly the calls it would have made directly, so the
        // bytes and their order are identical.
        self.out_sink.replay_into(out);
        result
    }

    // Sequential startup pipeline sharing mutable host state.
    #[allow(clippy::too_many_lines)]
    pub(crate) fn run_inner(
        &mut self,
        main: klio_ir::FuncId,
    ) -> Result<klio_runtime::Value, VmError> {
        let module = Arc::clone(&self.module);
        let mut out_sink = self.out_sink.clone();
        let out: &mut dyn Output = &mut out_sink;
        // Allocate every `object Foo { … }` singleton FIRST, so a
        // top-level property initialiser that captures the object
        // (e.g. `private object SENT; class Box { var v: Any? = SENT }`)
        // observes the same instance the main body will, preserving
        // `===` identity across init contexts.
        // Order: non-companion top-level objects first, then synth
        // companion objects. A companion's `val` initializer may
        // reference a top-level singleton (e.g. `val CURRENT =
        // SomePrivateObject.get()`), so the dependency target must be
        // bound in globals before the companion's init runs.
        // Top-level `const val`s are compile-time constants; bind them in
        // globals up front — before the object / companion initializers
        // below, which run ahead of the top-level property inits and may
        // read a top-level const. Without this an eager companion init sees
        // a not-yet-initialized `Null` global (`URLBuilder.Companion`'s
        // `val originUrl = Url(origin)`, where the URL parser does `port =
        // DEFAULT_PORT`).
        let top_level_consts: Vec<(String, klio_runtime::Value)> = self
            .module
            .registry
            .class_const_inits
            .iter()
            .filter(|((cls, _), _)| cls.is_empty())
            .map(|((_, name), c)| (name.clone(), klio_ir::eval::const_to_value(c)))
            .collect();
        for (name, v) in top_level_consts {
            self.globals.borrow_mut().define(&name, v);
        }
        let mut object_names: Vec<String> = self.module.registry.object_names.clone();
        object_names.sort_by_key(|n| n.contains("$Companion$"));
        for obj_name in &object_names {
            let Some(class_id) = module.class_id(obj_name) else {
                continue;
            };
            let inst = {
                let mut host = self.make_host(out);
                <VmHost as klio_ir::eval::Host>::new_instance(&mut host, class_id, &[])
                    .map_err(VmError::from)?
            };
            if let klio_runtime::Value::Instance(i) = &inst
                && let Some((outer_name, _)) = obj_name.split_once("$Companion$")
                && let Some(outer_def) = self.classes.borrow().get(outer_name).cloned()
            {
                i.borrow_mut().outer = Some(klio_runtime::Value::Class(outer_def));
            }
            self.globals.borrow_mut().define(obj_name, inst);
        }
        // Run top-level property initialisers before main so global
        // reads against the env see the initial values.
        let inits: Vec<(String, klio_ir::FuncId)> = self.top_level_props.clone();
        for (name, fid) in &inits {
            let init_func = module
                .funcs
                .get(fid.0 as usize)
                .cloned()
                .ok_or(VmError::InvalidMain)?;
            let v = {
                let _tl = TlInitGuard::enter();
                let mut host = self.make_host(out);
                let mut v = klio_ir::eval::eval_with(&module, &init_func, Vec::new(), &mut host)
                    .map_err(VmError::from)?;
                if module.registry.top_level_delegated_props.contains(name)
                    && let klio_runtime::Value::Instance(ref inst) = v
                {
                    let dcls_name = inst.borrow().class.name.clone();
                    let has_provide = module
                        .classes
                        .iter()
                        .find(|c| c.name == dcls_name)
                        .is_some_and(|c| {
                            c.methods.iter().any(|fid| {
                                module
                                    .funcs
                                    .get(fid.0 as usize)
                                    .is_some_and(|f| f.name == "provideDelegate")
                            })
                        });
                    if has_provide {
                        let prop_ref = klio_runtime::Value::PropertyRef {
                            name: Arc::new(name.clone()),
                        };
                        if let Ok(replacement) = <VmHost as klio_ir::eval::Host>::call_member(
                            &mut host,
                            &v,
                            "provideDelegate",
                            &[klio_runtime::Value::Null, prop_ref],
                        ) {
                            v = replacement;
                        }
                    }
                }
                v
            };
            self.globals.borrow_mut().define(name, v);
        }
        // Patch enum-entry instance fields with evaluated ctor args.
        let enum_inits: Vec<(String, String, Vec<klio_ir::FuncId>)> =
            self.enum_entry_arg_inits.clone();
        for (cls_name, entry_name, fids) in &enum_inits {
            let Some(class_def) = self.classes.borrow().get(cls_name).cloned() else {
                continue;
            };
            let param_names: Vec<String> = class_def
                .primary_params
                .iter()
                .map(|p| p.name.clone())
                .collect();
            let entry_inst = class_def
                .enum_entries
                .borrow()
                .iter()
                .find(|(n, _)| n == entry_name)
                .map(|(_, v)| v.clone());
            let Some(klio_runtime::Value::Instance(entry_inst)) = entry_inst else {
                continue;
            };
            for (idx, fid) in fids.iter().enumerate() {
                let Some(init_func) = module.funcs.get(fid.0 as usize).cloned() else {
                    continue;
                };
                let v = {
                    let mut host = self.make_host(out);
                    klio_ir::eval::eval_with(&module, &init_func, Vec::new(), &mut host)
                        .map_err(VmError::from)?
                };
                if let Some(pname) = param_names.get(idx) {
                    entry_inst.borrow_mut().define(pname, v);
                }
            }
        }
        // Object singletons were allocated upfront before the
        // top-level prop init loop above so `===` identity holds
        // across init contexts.
        let func = module
            .funcs
            .get(main.0 as usize)
            .ok_or(VmError::InvalidMain)?
            .clone();
        let result = {
            let mut host = self.make_host(out);
            klio_ir::eval::eval_with(&module, &func, Vec::new(), &mut host).map_err(VmError::from)
        };
        // Join every still-running spawned thread before returning so
        // a program that omits an explicit `join()` does not lose a
        // child's writes (and the process does not outlive them). A
        // child that threw surfaces here only if `main` itself did
        // not already fail.
        let pending: Vec<u64> = {
            let g = self
                .threads
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            g.keys().copied().collect()
        };
        for id in pending {
            let handle = {
                let mut g = self
                    .threads
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                g.get_mut(&id).and_then(|e| e.handle.take())
            };
            if let Some(h) = handle {
                match h.join() {
                    Ok(Err(e)) if result.is_ok() => {
                        return Err(VmError::Eval(format!("{e}")));
                    }
                    Err(_) if result.is_ok() => {
                        return Err(VmError::Eval("spawned thread panicked".into()));
                    }
                    _ => {}
                }
            }
        }
        result
    }
}
