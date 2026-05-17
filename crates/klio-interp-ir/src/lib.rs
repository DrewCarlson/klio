//! IR-native interpreter.
//!
//! This crate executes a frozen `klio_ir::Module` end-to-end with no
//! AST evaluator, no callback into `klio-interp`, and no `IrHost`
//! shim that synthesises AST. The IR cutover plan replaces the tree
//! walker by growing this crate's `Vm` until every Kotlin shape we
//! support has a Vm-native execution path.
//!
//! The crate intentionally does not depend on `klio-interp`. Module
//! construction goes through `klio_ir::lower` directly; the driver
//! (`klio-cli`) parses + type-checks via the shared front-end crates
//! and hands the resulting AST to this crate's `build_module`. Until
//! W12 the legacy `klio` binary keeps the tree walker available as a
//! reference; the new Vm runs alongside under `--ir-vm`.

use std::cell::RefCell;
use std::sync::atomic::{AtomicU64, Ordering as AtomicOrdering};
use std::sync::{Arc, Mutex};

pub use klio_runtime::Output;

pub mod build;

/// Build-time-immutable program metadata. Produced once by
/// `build::build_module` and shared O(1) by `Arc` with every OS
/// thread the program spawns (`kotlin.concurrent.thread`). Nothing
/// here is mutated after construction, so sharing it across threads
/// needs no synchronization.
pub struct ProgramImage {
    module: Arc<klio_ir::Module>,
    body_prop_inits:
        std::collections::HashMap<(String, String), klio_ir::FuncId>,
    instance_prop_getters:
        std::collections::HashMap<(String, String), klio_ir::FuncId>,
    instance_prop_setters:
        std::collections::HashMap<(String, String), klio_ir::FuncId>,
    parent_ctor_args:
        std::collections::HashMap<String, Vec<klio_ir::FuncId>>,
    init_blocks: std::collections::HashMap<String, Vec<klio_ir::FuncId>>,
    extension_props:
        std::collections::HashMap<(String, String), klio_ir::FuncId>,
    extension_prop_setters:
        std::collections::HashMap<(String, String), klio_ir::FuncId>,
    secondary_ctors:
        std::collections::HashMap<String, Vec<build::SecondaryCtorEntry>>,
    class_delegates:
        std::collections::HashMap<String, Vec<(String, klio_ir::FuncId)>>,
    func_defaults:
        std::collections::HashMap<klio_ir::FuncId, Vec<Option<klio_ir::FuncId>>>,
    installed_bindings: Arc<klio_stdlib::HostBindings>,
}

/// Lambda/closure side-table shared across every OS thread of one
/// program. Indices (`Value::IrClosure { id }`) are append-stable —
/// `push` only ever extends — so a `Mutex<Vec<_>>` keeps cross-thread
/// closure creation sound while every existing id stays valid.
#[derive(Clone)]
pub struct SharedClosures(Arc<Mutex<Vec<ClosureInfo>>>);

impl SharedClosures {
    fn new() -> Self {
        Self(Arc::new(Mutex::new(Vec::new())))
    }
    fn get(&self, id: usize) -> Option<ClosureInfo> {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).get(id).cloned()
    }
    /// Append `info`, returning its stable id.
    fn push(&self, info: ClosureInfo) -> u64 {
        let mut g = self.0.lock().unwrap_or_else(|e| e.into_inner());
        let id = g.len() as u64;
        g.push(info);
        id
    }
}

/// Bounded concurrency gate for the parallel coroutine dispatchers.
///
/// `Dispatchers.Default`/`IO` realize parallelism by spawning a real
/// OS thread per dispatched coroutine body (reusing the proven
/// `spawn_os_thread` publication + cross-thread join machinery). A
/// raw thread-per-coroutine would let 1000 `async`s create 1000 live
/// threads; this counting semaphore caps how many dispatched bodies
/// run *concurrently*. A worker thread is still spawned per job
/// (cheap to create, parks immediately on the gate), but only `cap`
/// of them execute their Kotlin body at once — the rest block on the
/// `Condvar` until a permit frees. `Default`'s cap tracks
/// `available_parallelism()` (CPU-bound); `IO`'s is a large fixed cap
/// (blocking-offload, elastic in practice).
struct DispatchGate {
    inner: Mutex<usize>,
    cv: std::sync::Condvar,
}

impl DispatchGate {
    fn new(cap: usize) -> Self {
        Self {
            inner: Mutex::new(cap.max(1)),
            cv: std::sync::Condvar::new(),
        }
    }
    /// Block until a permit is free, then take it.
    fn acquire(&self) {
        let mut avail = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        while *avail == 0 {
            avail = self.cv.wait(avail).unwrap_or_else(|e| e.into_inner());
        }
        *avail -= 1;
    }
    /// Return a permit and wake one waiter.
    fn release(&self) {
        let mut avail = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        *avail += 1;
        self.cv.notify_one();
    }
}

/// Process-global Default-dispatcher gate, sized to the host's
/// hardware parallelism. CPU-bound coroutine bodies dispatched on
/// `Dispatchers.Default` contend for these permits so the machine
/// runs at most ~one busy body per core.
fn default_gate() -> &'static DispatchGate {
    static GATE: std::sync::OnceLock<DispatchGate> = std::sync::OnceLock::new();
    GATE.get_or_init(|| {
        let cap = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(4);
        DispatchGate::new(cap)
    })
}

/// Process-global IO-dispatcher gate. `Dispatchers.IO` is for
/// blocking offload, so its cap is large (an effectively-elastic
/// pool) rather than CPU-bound.
fn io_gate() -> &'static DispatchGate {
    static GATE: std::sync::OnceLock<DispatchGate> = std::sync::OnceLock::new();
    GATE.get_or_init(|| DispatchGate::new(64))
}

/// One Vm instance executes a single program against the IR module
/// produced by the front end.
pub struct Vm {
    module: Arc<klio_ir::Module>,
    globals: klio_runtime::ObjRef<klio_runtime::Env>,
    scheduler: Box<dyn klio_runtime::Scheduler>,
    /// Process-wide monotonic instance-id source. Shared (atomically)
    /// across every OS thread so ids stay unique program-wide.
    instance_id_counter: Arc<AtomicU64>,
    /// Per-class runtime metadata produced by `build::build_module`.
    /// Shared by handle with spawned threads.
    classes: klio_runtime::ObjRef<std::collections::HashMap<String, Arc<klio_runtime::ClassDef>>>,
    /// Top-level property initialiser FuncIds. Run at Vm::run start
    /// so globals see the initial values.
    top_level_props: Vec<(String, klio_ir::FuncId)>,
    /// Enum-entry ctor-arg thunks to evaluate at startup.
    enum_entry_arg_inits: Vec<(String, String, Vec<klio_ir::FuncId>)>,
    /// Default outer instance to attach to locally-registered
    /// classes. Shared by handle with spawned threads.
    class_default_outer:
        klio_runtime::ObjRef<std::collections::HashMap<String, klio_runtime::Value>>,
    /// Runtime-lowered method bodies for anonymous-object / local
    /// classes. Shared by handle with spawned threads.
    anon_methods: klio_runtime::ObjRef<std::collections::HashMap<
        (String, String),
        (Arc<klio_ir::Module>, klio_ir::FuncId, Vec<(String, klio_runtime::Value)>),
    >>,
    /// Closure side-table, shared (mutex) across threads so a thread
    /// body can create lambdas without invalidating existing ids.
    closures: SharedClosures,
    /// Build-time-immutable program metadata, shared O(1) by `Arc`
    /// with every spawned OS thread.
    prog: Arc<ProgramImage>,
    /// Shared serialized stdout sink. The root and every spawned
    /// thread write through this so concurrent `println` is
    /// serialized; single-threaded ordering is byte-identical.
    out_sink: klio_runtime::SharedOutput,
    /// Host-side registry of live spawned-thread join handles, keyed
    /// by the opaque id handed back to `Thread.join`.
    threads: Arc<Mutex<std::collections::HashMap<u64, ThreadEntry>>>,
}

/// One spawned OS thread tracked by the host. The `JoinHandle`
/// yields the thread body's terminal result (an error string carries
/// a thrown Kotlin Throwable rendered for the joiner).
struct ThreadEntry {
    handle: Option<std::thread::JoinHandle<Result<(), klio_runtime::RuntimeError>>>,
}

/// `Send` capture of the shared program state for a new OS thread.
/// Built by [`Vm::spawn_child`] on the parent, moved into the
/// `std::thread::spawn` closure, then turned back into a [`Vm`] with
/// [`SendableVmSeed::materialize`] on the new thread. Every field is
/// an owned shared handle (`Arc` / `ObjRef` / atomic), so the seed
/// outlives the spawning call and carries no borrow.
pub struct SendableVmSeed {
    module: Arc<klio_ir::Module>,
    globals: klio_runtime::ObjRef<klio_runtime::Env>,
    instance_id_counter: Arc<AtomicU64>,
    classes: klio_runtime::ObjRef<std::collections::HashMap<String, Arc<klio_runtime::ClassDef>>>,
    prog: Arc<ProgramImage>,
    anon_methods: klio_runtime::ObjRef<std::collections::HashMap<
        (String, String),
        (Arc<klio_ir::Module>, klio_ir::FuncId, Vec<(String, klio_runtime::Value)>),
    >>,
    class_default_outer:
        klio_runtime::ObjRef<std::collections::HashMap<String, klio_runtime::Value>>,
    closures: SharedClosures,
    out_sink: klio_runtime::SharedOutput,
    threads: Arc<Mutex<std::collections::HashMap<u64, ThreadEntry>>>,
}

impl SendableVmSeed {
    /// Materialize a child `Vm` on the current (new) OS thread. The
    /// child shares the parent's program image, globals, classes,
    /// closure table, id counter, and stdout sink; it gets its own
    /// fresh cooperative scheduler (coroutine state is `thread_local`
    /// already).
    pub fn materialize(self) -> Vm {
        Vm {
            module: self.module,
            globals: self.globals,
            scheduler: Box::new(klio_runtime::InProcessScheduler::new()),
            instance_id_counter: self.instance_id_counter,
            classes: self.classes,
            top_level_props: Vec::new(),
            enum_entry_arg_inits: Vec::new(),
            class_default_outer: self.class_default_outer,
            anon_methods: self.anon_methods,
            closures: self.closures,
            prog: self.prog,
            out_sink: self.out_sink,
            threads: self.threads,
        }
    }
}

const _: fn() = || {
    fn assert_send<T: Send>() {}
    assert_send::<Vm>();
    assert_send::<SendableVmSeed>();
};

#[derive(Clone)]
struct ClosureInfo {
    body_func: klio_ir::FuncId,
    n_params: usize,
    /// Capture names, in the same order as the runtime captures
    /// vec. Lets the Vm's `read_lambda_capture` host method map a
    /// name back to the captured value index.
    capture_names: Vec<String>,
    /// Live capture values. Stored behind a shared interior-mutable
    /// handle so the lambda body's StoreGlobal writes propagate (the
    /// dispatch path layers each captured name into a per-call env,
    /// then reads back into this vec). The outer-frame
    /// WritebackCaptures Inst observes the updated values via
    /// `read_lambda_capture`.
    captures: klio_runtime::ObjRef<Vec<klio_runtime::Value>>,
}

impl Vm {
    /// Build a Vm around an already-lowered IR module. Stdlib
    /// aliases (`print`, `println`, `listOf`, ...) are installed
    /// into globals up front so identifiers covered by Kotlin's
    /// default imports resolve without an explicit `import`.
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
                module,
                body_prop_inits: std::collections::HashMap::new(),
                instance_prop_getters: std::collections::HashMap::new(),
                instance_prop_setters: std::collections::HashMap::new(),
                parent_ctor_args: std::collections::HashMap::new(),
                init_blocks: std::collections::HashMap::new(),
                extension_props: std::collections::HashMap::new(),
                extension_prop_setters: std::collections::HashMap::new(),
                secondary_ctors: std::collections::HashMap::new(),
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
    pub fn set_installed_bindings(&mut self, bindings: klio_stdlib::HostBindings) {
        let prog = Arc::get_mut(&mut self.prog)
            .expect("set_installed_bindings before run / thread spawn");
        prog.installed_bindings = Arc::new(bindings);
    }

    /// Build a Vm from a fully-prepared `build::BuiltModule`. The
    /// recommended entry point for the driver — it carries both the
    /// IR module and the synthesised runtime ClassDef table.
    pub fn from_built(built: build::BuiltModule) -> (Self, Option<klio_ir::FuncId>) {
        let main = built.main;
        let mut vm = Self::new(Arc::clone(&built.module));
        vm.classes = klio_runtime::ObjRef::new(built.classes);
        vm.top_level_props = built.top_level_props;
        vm.enum_entry_arg_inits = built.enum_entry_arg_inits;
        vm.prog = Arc::new(ProgramImage {
            module: built.module,
            body_prop_inits: built.body_prop_inits,
            instance_prop_getters: built.instance_prop_getters,
            instance_prop_setters: built.instance_prop_setters,
            parent_ctor_args: built.parent_ctor_args,
            init_blocks: built.init_blocks,
            extension_props: built.extension_props,
            extension_prop_setters: built.extension_prop_setters,
            secondary_ctors: built.secondary_ctors,
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
    fn make_host<'s>(&'s mut self, out: &'s mut dyn Output) -> VmHost<'s> {
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
    fn run_thread_block(
        &mut self,
        block: &klio_runtime::Value,
    ) -> Result<klio_runtime::Value, klio_runtime::RuntimeError> {
        use klio_runtime::IntrinsicHost;
        let mut sink = self.out_sink.clone();
        let mut host = self.make_host(&mut sink);
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

    fn run_inner(
        &mut self,
        main: klio_ir::FuncId,
    ) -> Result<klio_runtime::Value, VmError> {
        let module = Arc::clone(&self.module);
        let mut out_sink = self.out_sink.clone();
        let out: &mut dyn Output = &mut out_sink;
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
                let mut host = self.make_host(out);
                let mut v = klio_ir::eval::eval_with(&module, &init_func, Vec::new(), &mut host)
                    .map_err(VmError::from)?;
                if module.registry.top_level_delegated_props.contains(name) {
                    if let klio_runtime::Value::Instance(ref inst) = v {
                        let dcls_name = inst.borrow().class.name.clone();
                        let has_provide = module
                            .classes
                            .iter()
                            .find(|c| c.name == dcls_name)
                            .map(|c| {
                                c.methods.iter().any(|fid| {
                                    module
                                        .funcs
                                        .get(fid.0 as usize)
                                        .map(|f| f.name == "provideDelegate")
                                        .unwrap_or(false)
                                })
                            })
                            .unwrap_or(false);
                        if has_provide {
                            let prop_ref = klio_runtime::Value::PropertyRef {
                                name: Arc::new(name.clone()),
                            };
                            if let Ok(replacement) =
                                <VmHost as klio_ir::eval::Host>::call_member(
                                    &mut host,
                                    &v,
                                    "provideDelegate",
                                    &[klio_runtime::Value::Null, prop_ref],
                                )
                            {
                                v = replacement;
                            }
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
            let class_def = match self.classes.borrow().get(cls_name).cloned() {
                Some(d) => d,
                None => continue,
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
            let entry_inst = match entry_inst {
                Some(klio_runtime::Value::Instance(i)) => i,
                _ => continue,
            };
            for (idx, fid) in fids.iter().enumerate() {
                let init_func = match module.funcs.get(fid.0 as usize).cloned() {
                    Some(f) => f,
                    None => continue,
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
        // Allocate one instance per `object Foo { … }` decl and
        // publish it as a global so bare-name `Foo` references
        // resolve. Each object's class is synthesised in build.rs
        // alongside regular classes; the singleton runs that class's
        // primary ctor (parent chain + body props + init blocks)
        // with zero args.
        let object_names: Vec<String> = self.module.registry.object_names.clone();
        for obj_name in &object_names {
            let class_id = match module.class_id(obj_name) {
                Some(id) => id,
                None => continue,
            };
            let inst = {
                let mut host = self.make_host(out);
                <VmHost as klio_ir::eval::Host>::new_instance(&mut host, class_id, &[])
                    .map_err(VmError::from)?
            };
            // Companion singletons get their `outer` field wired to
            // the enclosing class so method bodies that read
            // bare-name members (e.g. enum `entries`) resolve via
            // the outer-chain walk in get_field.
            if let klio_runtime::Value::Instance(i) = &inst {
                if let Some((outer_name, _)) = obj_name.split_once("$Companion$") {
                    if let Some(outer_def) =
                        self.classes.borrow().get(outer_name).cloned()
                    {
                        i.borrow_mut().outer =
                            Some(klio_runtime::Value::Class(outer_def));
                    }
                }
            }
            self.globals.borrow_mut().define(obj_name, inst);
        }
        let func = module
            .funcs
            .get(main.0 as usize)
            .ok_or(VmError::InvalidMain)?
            .clone();
        let result = {
            let mut host = self.make_host(out);
            klio_ir::eval::eval_with(&module, &func, Vec::new(), &mut host)
                .map_err(VmError::from)
        };
        // Join every still-running spawned thread before returning so
        // a program that omits an explicit `join()` does not lose a
        // child's writes (and the process does not outlive them). A
        // child that threw surfaces here only if `main` itself did
        // not already fail.
        let pending: Vec<u64> = {
            let g = self.threads.lock().unwrap_or_else(|e| e.into_inner());
            g.keys().copied().collect()
        };
        for id in pending {
            let handle = {
                let mut g = self.threads.lock().unwrap_or_else(|e| e.into_inner());
                g.get_mut(&id).and_then(|e| e.handle.take())
            };
            if let Some(h) = handle {
                match h.join() {
                    Ok(Ok(())) => {}
                    Ok(Err(e)) if result.is_ok() => {
                        return Err(VmError::Eval(format!("{e}")));
                    }
                    Ok(Err(_)) => {}
                    Err(_) if result.is_ok() => {
                        return Err(VmError::Eval(
                            "spawned thread panicked".into(),
                        ));
                    }
                    Err(_) => {}
                }
            }
        }
        result
    }
}

/// Vm-level errors.
#[derive(Debug, thiserror::Error)]
pub enum VmError {
    #[error("main function not found in module")]
    InvalidMain,
    #[error("IR eval: {0}")]
    Eval(String),
}

impl From<klio_ir::eval::EvalError> for VmError {
    fn from(e: klio_ir::eval::EvalError) -> Self {
        // Format Throw variants with the thrown exception's
        // fqn + message so the user-facing diagnostic is
        // actionable rather than the trait's generic phrase.
        if let klio_ir::eval::EvalError::Throw(v) = &e {
            if let klio_runtime::Value::Exception { fqn, message, .. } = v {
                let msg = message
                    .as_deref()
                    .map(|s| s.as_str())
                    .unwrap_or("<no message>");
                return VmError::Eval(format!("uncaught {fqn}: {msg}"));
            }
        }
        VmError::Eval(e.to_string())
    }
}

/// IR Host implementation. Every method native to the new Vm lives
/// here. Methods that have no native implementation yet raise
/// `EvalError::Unimplemented` (carrying the surface name) so the
/// failure surfaces are easy to identify and migrate one by one.
struct VmHost<'a> {
    globals: klio_runtime::ObjRef<klio_runtime::Env>,
    module: Arc<klio_ir::Module>,
    scheduler: &'a mut dyn klio_runtime::Scheduler,
    out: &'a mut dyn Output,
    instance_id_counter: Arc<AtomicU64>,
    classes: klio_runtime::ObjRef<std::collections::HashMap<String, Arc<klio_runtime::ClassDef>>>,
    prog: Arc<ProgramImage>,
    anon_methods: klio_runtime::ObjRef<std::collections::HashMap<
        (String, String),
        (Arc<klio_ir::Module>, klio_ir::FuncId, Vec<(String, klio_runtime::Value)>),
    >>,
    class_default_outer:
        klio_runtime::ObjRef<std::collections::HashMap<String, klio_runtime::Value>>,
    closures: SharedClosures,
    out_sink: klio_runtime::SharedOutput,
    threads: Arc<Mutex<std::collections::HashMap<u64, ThreadEntry>>>,
}

impl<'a> VmHost<'a> {
    /// Join the spawned OS thread `id`, propagating a thrown
    /// Throwable as a `RuntimeError`. Idempotent: a second join (or
    /// an unknown id) is a no-op since the happens-before edge was
    /// already established. `fence_and_publish` marks the boundary.
    fn join_spawned(&mut self, id: u64) -> Result<(), klio_runtime::RuntimeError> {
        let handle = {
            let mut g = self.threads.lock().unwrap_or_else(|e| e.into_inner());
            g.get_mut(&id).and_then(|e| e.handle.take())
        };
        let Some(handle) = handle else {
            return Ok(());
        };
        let res = handle.join().map_err(|_| {
            klio_runtime::RuntimeError::Type("spawned thread panicked".into())
        })?;
        klio_runtime::fence_and_publish(); // thread join
        res
    }

    /// Whether spawned thread `id` is still running.
    fn thread_alive(&self, id: u64) -> bool {
        let g = self.threads.lock().unwrap_or_else(|e| e.into_inner());
        match g.get(&id) {
            Some(e) => e.handle.as_ref().map(|h| !h.is_finished()).unwrap_or(false),
            None => false,
        }
    }

    /// Drive a lazy `Value::Sequence` to completion. Each upstream
    /// item flows through the pipeline ops by invoking the user
    /// lambdas via `self.call_value`. Sorting ops buffer-and-emit.
    /// Drive a lazy `Value::Sequence` to completion. The HOF
    /// dispatch lives in `klio-stdlib`; the Vm only supplies an
    /// `IntrinsicHost` so the op lambdas resolve back into IR
    /// closures. Building the host here mirrors `dispatch_intrinsic`.
    fn materialise_sequence(
        &mut self,
        seq_val: &klio_runtime::Value,
    ) -> Result<Vec<klio_runtime::Value>, klio_ir::eval::EvalError> {
        let mut intrinsic_host = VmIntrinsicHost {
            scheduler: &mut *self.scheduler,
            module: Arc::clone(&self.module),
            closures: self.closures.clone(),
            globals: self.globals.clone(),
            classes: self.classes.clone(),
            prog: Arc::clone(&self.prog),
            anon_methods: self.anon_methods.clone(),
            class_default_outer: self.class_default_outer.clone(),
            instance_id_counter: Arc::clone(&self.instance_id_counter),
            out_sink: self.out_sink.clone(),
            threads: Arc::clone(&self.threads),
        };
        klio_stdlib::materialise_sequence(seq_val, &mut intrinsic_host, &mut *self.out)
            .map_err(|e| match e {
                klio_runtime::RuntimeError::Thrown(v) => klio_ir::eval::EvalError::Throw(v),
                other => klio_ir::eval::EvalError::Type(format!("{other}")),
            })
    }
    /// Score an arg/param compatibility for overload resolution.
    /// Higher is better. Exact type match wins over `Any`, which
    /// wins over a type-parameter (`T`) fallback. Returning `None`
    /// disqualifies the candidate.
    fn overload_score_arg(
        &self,
        param_ty: &klio_ir::TypeRef,
        arg: &klio_runtime::Value,
    ) -> Option<i32> {
        let nm = param_ty.name.as_str();
        let owned;
        let v_ty: &str = if let klio_runtime::Value::Instance(i) = arg {
            owned = i.borrow().class.name.clone();
            owned.as_str()
        } else {
            let fqn = arg.type_fqn();
            fqn.rsplit('.').next().unwrap_or(fqn)
        };
        if nm == v_ty {
            return Some(100);
        }
        if matches!(nm, "Any" | "Any?") {
            return Some(10);
        }
        if matches!(arg, klio_runtime::Value::Null) && param_ty.nullable {
            return Some(50);
        }
        // Numeric widening: Int → Long, Int → Double, Long → Double.
        match (nm, v_ty) {
            ("Long", "Int") => return Some(40),
            ("Double", "Int") | ("Double", "Long") | ("Float", "Int") => return Some(30),
            _ => {}
        }
        // A callable argument (lambda / closure / bound method)
        // against a function-typed parameter. The lowered param type
        // doesn't preserve the arrow shape, so accept any callable at
        // a low score — concrete-type params still outrank it and
        // arity does the real disambiguation between overloads.
        let arg_arity: Option<usize> = match arg {
            klio_runtime::Value::Lambda { params, .. } => Some(params.len()),
            klio_runtime::Value::IrClosure { id, .. } => {
                self.closures.get(*id as usize).map(|c| c.n_params)
            }
            _ => None,
        };
        let is_callable = arg_arity.is_some()
            || arg.type_fqn().starts_with("kotlin.Function");
        if is_callable {
            // `FunctionN` carries the expected lambda arity. Rank an
            // exact match high so overloads differing only in the
            // functional parameter's shape are disambiguated; a
            // mismatch still scores (low) rather than disqualifying,
            // to stay tolerant of receiver-style function types.
            if let Some(expected) = nm.strip_prefix("Function") {
                if let Ok(want) = expected.parse::<usize>() {
                    return Some(match arg_arity {
                        Some(got) if got == want => 90,
                        Some(_) => 2,
                        None => 15,
                    });
                }
            }
            return Some(15);
        }
        // Generic single-letter type-parameter — accept any.
        if nm.len() <= 2 && nm.chars().all(|c| c.is_ascii_uppercase()) {
            return Some(5);
        }
        // Unit param type (no info preserved at lower time) — accept
        // anything but rank lowest so other overloads with concrete
        // type info still win.
        if nm == "Unit" {
            return Some(1);
        }
        None
    }

    fn pick_method_overload(
        &self,
        candidates: &[klio_ir::Func],
        args: &[klio_runtime::Value],
    ) -> Option<klio_ir::Func> {
        if candidates.is_empty() {
            return None;
        }
        if candidates.len() == 1 {
            return Some(candidates[0].clone());
        }
        let mut best: Option<(usize, i32)> = None;
        for (i, f) in candidates.iter().enumerate() {
            // Method params include the implicit `this` slot first;
            // skip it when scoring against the caller's args.
            let params_skip = if f.params.first().map(|p| p.name == "this").unwrap_or(false) { 1 } else { 0 };
            let effective: &[klio_ir::Param] = &f.params[params_skip..];
            // Accept an exact-arity match, or a call that supplies
            // fewer args when every unsupplied trailing parameter has
            // a default (`fun make(s, adj: Long = 0)` called as
            // `make(s)`). func_defaults is indexed by lowered-param
            // position, so probe with the implicit-`this` offset.
            if args.len() > effective.len() {
                continue;
            }
            if args.len() < effective.len() {
                let defaults = self.prog.func_defaults.get(&f.id);
                let all_defaulted = (args.len()..effective.len()).all(|k| {
                    defaults
                        .and_then(|d| d.get(params_skip + k))
                        .map(|slot| slot.is_some())
                        .unwrap_or(false)
                });
                if !all_defaulted {
                    continue;
                }
            }
            let mut total: i32 = 0;
            let mut ok = true;
            for (p, a) in effective.iter().zip(args.iter()) {
                match self.overload_score_arg(&p.ty, a) {
                    Some(s) => total += s,
                    None => {
                        ok = false;
                        break;
                    }
                }
            }
            // Prefer an exact-arity overload over one relying on
            // defaulted trailing params, all else equal.
            if ok && args.len() == effective.len() {
                total += 5;
            }
            if ok && best.map(|(_, s)| total > s).unwrap_or(true) {
                best = Some((i, total));
            }
        }
        best.map(|(i, _)| candidates[i].clone())
    }

    fn pick_overload(
        &self,
        module: &klio_ir::Module,
        func: klio_ir::FuncId,
        args: &[klio_runtime::Value],
    ) -> Option<klio_ir::FuncId> {
        let name = module.funcs.get(func.0 as usize)?.name.clone();
        let candidates: Vec<klio_ir::FuncId> = module
            .func_index
            .iter()
            .filter(|(n, _)| n == &name)
            .map(|(_, id)| *id)
            .collect();
        if candidates.len() < 2 {
            return None;
        }
        let mut best: Option<(klio_ir::FuncId, i32)> = None;
        for cand in &candidates {
            let f = module.funcs.get(cand.0 as usize)?;
            if f.params.len() != args.len() {
                continue;
            }
            let mut total: i32 = 0;
            let mut ok = true;
            for (p, a) in f.params.iter().zip(args.iter()) {
                match self.overload_score_arg(&p.ty, a) {
                    Some(s) => total += s,
                    None => {
                        ok = false;
                        break;
                    }
                }
            }
            if ok && best.map(|(_, s)| total > s).unwrap_or(true) {
                best = Some((*cand, total));
            }
        }
        best.map(|(id, _)| id)
    }

    /// Look up an intrinsic by FQN. Probes the pack-supplied
    /// `installed_bindings` overlay first so a loaded pack's binding
    /// shadows the stdlib's default implementation.
    fn lookup_intrinsic(&self, fqn: &str) -> Option<klio_runtime::StdlibFn> {
        self.prog.installed_bindings
            .resolve(fqn)
            .or_else(|| klio_stdlib::implementation(fqn))
    }

    fn dispatch_intrinsic(
        &mut self,
        func: klio_runtime::StdlibFn,
        args: &[klio_runtime::Value],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        // Build an IntrinsicHost that can recursively invoke
        // lambdas (Value::IrClosure) via the Vm's closure table +
        // module. This lets HOF stdlib bindings (`map`, `forEach`,
        // scope fns) call back into IR-lowered lambda bodies
        // natively, without bouncing through klio-interp.
        let mut intrinsic_host = VmIntrinsicHost {
            scheduler: &mut *self.scheduler,
            module: Arc::clone(&self.module),
            closures: self.closures.clone(),
            globals: self.globals.clone(),
            classes: self.classes.clone(),
            prog: Arc::clone(&self.prog),
            anon_methods: self.anon_methods.clone(),
            class_default_outer: self.class_default_outer.clone(),
            instance_id_counter: Arc::clone(&self.instance_id_counter),
            out_sink: self.out_sink.clone(),
            threads: Arc::clone(&self.threads),
        };
        let mut ctx = klio_runtime::CallCtx {
            args,
            out: &mut *self.out,
            host: &mut intrinsic_host,
        };
        func(&mut ctx).map_err(|e| match e {
            // Preserve the thrown Value so the IR evaluator's
            // try/catch can match the handler against the exception
            // class. Stringifying here would break `try { … } catch`.
            klio_runtime::RuntimeError::Thrown(v) => klio_ir::eval::EvalError::Throw(v),
            klio_runtime::RuntimeError::Return(v) => {
                klio_ir::eval::EvalError::NonLocalReturn(v)
            }
            // A suspending primitive (`delay` / `yield`) asked to
            // park. Seed a fresh SuspendState; each enclosing
            // `eval` frame snapshots itself as it unwinds, and the
            // coroutine driver parks the result under a token.
            klio_runtime::RuntimeError::Suspend(wake) => {
                klio_ir::eval::EvalError::Suspended(Box::new(
                    klio_ir::eval::SuspendState {
                        token: 0,
                        frames: Vec::new(),
                        wake_in_millis: wake,
                        pending_resume_reg: None,
                    },
                ))
            }
            other => klio_ir::eval::EvalError::Type(format!("{other}")),
        })
    }
}

impl<'a> klio_ir::eval::Host for VmHost<'a> {
    fn enclosing_this(&self) -> Option<klio_runtime::Value> {
        with_outer_this(|s| s.borrow().last().cloned())
    }

    fn lookup_global(&mut self, name: &str) -> Option<klio_runtime::Value> {
        let cached = self.globals.borrow().lookup(name);
        if self.module.registry.top_level_delegated_props.contains(name) {
            if let Some(v) = cached.clone() {
                if matches!(v, klio_runtime::Value::Instance(_)) {
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
                        match value.clone() {
                            Some(x) => return Some(x),
                            None => {
                                // Reading a `Delegates.notNull` slot
                                // before it's been written throws
                                // IllegalStateException per Kotlin.
                                let _ = name;
                                return None;
                            }
                        }
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
        // f(args)` route through Vm::call_value.
        if let Some(fid) = self.module.func_id(name) {
            // Wrap the FuncId in a closure with no captures so the
            // Vm's CallValue path dispatches through eval_with.
            let func = self.module.funcs.get(fid.0 as usize).cloned()?;
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
        // Probe stdlib by FQN for known package surfaces. Covers
        // bare references to `IntArray`, `compareBy`, `buildList`,
        // `naturalOrder`, `PI`, etc. that aren't in IMPLICIT_ALIASES.
        let direct_probes: [String; 10] = [
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
        ];
        // Loaded packs register their FQNs in `installed_bindings`.
        // For a bare-name reference, scan the overlay for a key that
        // ends with `.{name}` — this lets user code call
        // `runBlocking { … }` after `import kotlinx.coroutines.runBlocking`
        // without having to teach `direct_probes` about every kotlinx
        // package.
        {
            let suffix = format!(".{name}");
            let entry: Option<(&'static str, klio_runtime::StdlibFn)> = self.prog
                .installed_bindings
                .entries()
                .find(|(k, _)| k.ends_with(&suffix))
                .map(|(k, f)| (k, f));
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
                if looks_const {
                    if let Ok(v) = self.dispatch_intrinsic(func, &[]) {
                        return Some(v);
                    }
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
            "Int" | "Long" | "Short" | "Byte" | "Float" | "Double" | "Boolean"
                | "Char" | "String" | "Unit" | "Any" | "Nothing" | "UInt"
                | "ULong" | "UShort" | "UByte" | "Number"
        ) {
            let def = Arc::new(klio_runtime::ClassDef {
                name: name.to_string(),
                fqn: format!("kotlin.{name}"),
                annotation_names: Vec::new(),
                primary_params: Vec::new(),
                methods: Vec::new(),
                body_properties: Vec::new(),
                init_blocks: Vec::new(),
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
        if let Some((ty, member)) = name.split_once('.') {
            if let Some(v) = klio_stdlib::primitive_companion_const(ty, member) {
                return Some(v);
            }
        }
        // Package-qualified reference (not a call) to a user / pack
        // top-level class: `kotlinx.atomicfu.AtomicInt::class`. The
        // class table is keyed by simple name (the package prefix
        // lives on each decl's `fqn`), so retry the trailing segment.
        // Reached only after every other probe returned `None`, so a
        // name that already resolves is untouched. Package-qualified
        // *calls* are routed through `Inst::Call` at lower time so
        // they keep overload resolution; this only covers bare refs.
        if let Some((_, tail)) = name.rsplit_once('.') {
            if tail != name && !tail.is_empty() {
                if let Some(def) = self.classes.borrow().get(tail).cloned() {
                    return Some(klio_runtime::Value::Class(def));
                }
            }
        }
        // `typealias Alias = Target` — resolve the alias to the
        // aliased declaration for value/qualifier position
        // (`Alias.of(...)`, `Alias(...)`). Follow chains with a
        // cycle guard.
        {
            let mut cur = name.to_string();
            let mut seen: std::collections::HashSet<String> =
                std::collections::HashSet::new();
            while let Some(target) = self
                .module
                .registry
                .type_aliases
                .get(&cur)
                .cloned()
            {
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

    fn store_global(
        &mut self,
        name: &str,
        value: klio_runtime::Value,
    ) -> Result<(), klio_ir::eval::EvalError> {
        if self.module.registry.top_level_delegated_props.contains(name) {
            let existing = self.globals.borrow().lookup(name);
            if let Some(d) = existing {
                if matches!(d, klio_runtime::Value::Instance(_)) {
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
                klio_runtime::DelegateKind::Observable { value: old, on_change } => {
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
                _ => {}
            }
        }
        self.globals.borrow_mut().define(name, value);
        Ok(())
    }

    fn lookup_global_throwing(
        &mut self,
        name: &str,
    ) -> Result<Option<klio_runtime::Value>, klio_ir::eval::EvalError> {
        let raw = self.globals.borrow().lookup(name);
        if let Some(klio_runtime::Value::Delegate(d)) = &raw {
            if let klio_runtime::DelegateKind::NotNull { value: None, .. } = &*d.borrow() {
                return Err(klio_ir::eval::EvalError::Throw(
                    klio_runtime::Value::Exception {
                        fqn: Arc::new("kotlin.IllegalStateException".to_string()),
                        message: Some(Arc::new(format!(
                            "Property {} should be initialized before get.",
                            name
                        ))),
                        cause: None,
                    },
                ));
            }
        }
        Ok(self.lookup_global(name))
    }

    fn call_value(
        &mut self,
        callee: &klio_runtime::Value,
        args: &[klio_runtime::Value],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        if let klio_runtime::Value::Intrinsic { func, .. } = callee {
            return self.dispatch_intrinsic(*func, args);
        }
        // `instance()` — invoke an instance via its `operator fun
        // invoke(...)` method.
        if matches!(callee, klio_runtime::Value::Instance(_)) {
            return self.call_member(callee, "invoke", args);
        }
        // Constructor-like call on a user class value
        // (`val ctor = ::Foo; ctor(1, 2)`). Falls through to a
        // direct ClassDef-based allocation when the class isn't
        // in the IR module's class_index — covers local classes
        // declared inside a fn body and registered via
        // Inst::RegisterClass.
        if let klio_runtime::Value::Class(cls) = callee {
            // SAM conversion: `FunInterface { lambda }` constructs a
            // synthetic instance whose single abstract method
            // dispatches the lambda body. We allocate a thin
            // InstanceData whose `fields` carry the lambda under
            // `__sam_target__`; call_member on this instance routes
            // any method call back through the lambda.
            if cls.is_fun_interface && args.len() == 1 {
                let identity = self.instance_id_counter.fetch_add(1, AtomicOrdering::Relaxed) + 1;
                let inst = klio_runtime::ObjRef::new(klio_runtime::InstanceData {
                    class: Arc::clone(cls),
                    fields: vec![("__sam_target__".to_string(), args[0].clone())],
                    outer: None,
                    identity,
                    native_state: None,
                });
                return Ok(klio_runtime::Value::Instance(inst));
            }
            let class_id = self
                .module
                .class_index
                .iter()
                .find(|(n, _)| *n == cls.name)
                .map(|(_, id)| *id);
            if let Some(class_id) = class_id {
                return self.new_instance(class_id, args);
            }
            // Direct allocation for classes that aren't in the IR
            // module index. The runtime ClassDef carries enough to
            // bind primary-param properties; init blocks + custom
            // getters land when local-class lowering grows them.
            let identity = self.instance_id_counter.fetch_add(1, AtomicOrdering::Relaxed) + 1;
            let mut fields: Vec<(String, klio_runtime::Value)> =
                Vec::with_capacity(cls.primary_params.len());
            for (param, value) in cls.primary_params.iter().zip(args.iter()) {
                if param.property.is_some() {
                    fields.push((param.name.clone(), value.clone()));
                }
            }
            // Body-property defaults for runtime-registered local
            // classes — literal-only inits, since there's no
            // lowered thunk on a non-IR class.
            for p in &cls.body_properties {
                if let Some(init) = &p.init {
                    let v = simple_literal(init).unwrap_or(klio_runtime::Value::Null);
                    fields.push((p.name.clone(), v));
                } else if p.getter.is_none() && p.delegate.is_none() {
                    fields.push((p.name.clone(), klio_runtime::Value::Null));
                }
            }
            let default_outer = self
                .class_default_outer
                .borrow()
                .get(&cls.name)
                .cloned();
            let inst = klio_runtime::ObjRef::new(klio_runtime::InstanceData {
                class: Arc::clone(cls),
                fields,
                outer: default_outer,
                identity,
                native_state: None,
            });
            return Ok(klio_runtime::Value::Instance(inst));
        }
        // `propRef(receiver)` — invoking a Value::PropertyRef as a
        // callable reads the named field from the first arg.
        if let klio_runtime::Value::PropertyRef { name } = callee {
            if args.len() == 1 {
                return self.get_field(&args[0], name);
            }
        }
        // Bound method/property reference: synthetic instance
        // carrying a receiver + method name. Invocation forwards
        // through the captured receiver (or reads the property on
        // the first arg for unbound property refs).
        if let klio_runtime::Value::Instance(inst) = callee {
            let snap = inst.borrow();
            let recv = snap.get("__bound_receiver__");
            let name_v = snap.get("__bound_name__");
            drop(snap);
            if let (Some(recv), Some(klio_runtime::Value::String(name))) =
                (recv, name_v)
            {
                if matches!(&recv, klio_runtime::Value::Class(_)) && args.len() == 1
                {
                    return self.get_field(&args[0], &name);
                }
                return self.call_member(&recv, &name, args);
            }
        }
        if let klio_runtime::Value::IrClosure { id, captures } = callee {
            let info = self.closures.get(*id as usize).ok_or_else(|| {
                klio_ir::eval::EvalError::Type(format!("unknown IrClosure id {id}"))
            })?;
            let module = Arc::clone(&self.module);
            let func = module
                .funcs
                .get(info.body_func.0 as usize)
                .cloned()
                .ok_or_else(|| {
                    klio_ir::eval::EvalError::Type(format!(
                        "closure body FuncId {} out of range",
                        info.body_func.0
                    ))
                })?;
            // Pack binding overlay short-circuit for the wrapped
            // top-level fn: e.g. a closure-of `kotlinx.datetime.__kxdt_*`
            // dispatches the Rust binding instead of running the
            // shim placeholder body.
            if let Some(intrinsic) = self.prog.installed_bindings.resolve(&func.fqn) {
                return self.dispatch_intrinsic(intrinsic, args);
            }
            // Fill missing positional args from the target's
            // registered default-arg thunks (an implicit-`it` lambda
            // invoked with zero args still gets its slot as Null).
            // Pack trailing vararg args into an Array when the
            // target's last param is marked vararg.
            let defaults =
                self.prog.func_defaults.get(&info.body_func).cloned();
            let mut call_args = pad_args_with_defaults(
                &module,
                info.n_params,
                args,
                defaults.as_ref(),
                self,
            )?;
            if let Some(last) = func.params.last() {
                if last.is_vararg && args.len() > info.n_params {
                    let mut packed: Vec<klio_runtime::Value> = Vec::new();
                    let fixed = info.n_params.saturating_sub(1);
                    packed.extend(args[fixed..].iter().cloned());
                    call_args[info.n_params - 1] = klio_runtime::Value::Array {
                        items: klio_runtime::ObjRef::new(packed),
                        prim: None,
                    };
                } else if last.is_vararg
                    && !matches!(call_args.last(), Some(klio_runtime::Value::Array { .. }))
                {
                    let fixed = info.n_params.saturating_sub(1);
                    let mut packed: Vec<klio_runtime::Value> = Vec::new();
                    if args.len() > fixed {
                        packed.extend(args[fixed..].iter().cloned());
                    }
                    call_args[info.n_params - 1] = klio_runtime::Value::Array {
                        items: klio_runtime::ObjRef::new(packed),
                        prim: None,
                    };
                }
            }
            let capture_values: Vec<klio_runtime::Value> = (**captures).clone();
            return klio_ir::eval::eval_with_captures(
                &module,
                &func,
                call_args,
                capture_values,
                self,
            );
        }
        Err(klio_ir::eval::EvalError::Unimplemented(format!(
            "Vm::call_value on `{}`",
            callee.type_fqn()
        )))
    }

    fn call_value_named(
        &mut self,
        callee: &klio_runtime::Value,
        args: &[klio_runtime::Value],
        _arg_names: &[Option<String>],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        self.call_value(callee, args)
    }

    fn get_field(
        &mut self,
        receiver: &klio_runtime::Value,
        name: &str,
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        // Backing-field bypass: getter / setter bodies that reference
        // `field` lower into a member read on this synthetic name.
        // Route straight to the raw instance slot to break recursion.
        if let Some(raw) = name.strip_prefix("__klio_field__") {
            if let klio_runtime::Value::Instance(inst) = receiver {
                if let Some(v) = inst.borrow().get(raw) {
                    return Ok(v);
                }
                return Ok(klio_runtime::Value::Null);
            }
        }
        // `Thread` handle property reads (`t.name`, `t.isAlive`).
        // Mirrors the member-call interception in `call_member`.
        if let klio_runtime::Value::BoundMethod { fqn, receiver: tid, .. } = receiver {
            if *fqn == "kotlin.concurrent.Thread" {
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
        }
        // Custom getter — invoke its IR FuncId with the receiver
        // bound as `this`. Wins over the plain field read so a
        // `val full: String get() = "$first $last"` shape evaluates
        // the getter rather than returning a missing-field Null.
        // Enum: `Color.RED` / `Color.entries`. Resolves named
        // entries on a Value::Class for an enum and the
        // generated `entries` list / `values()` companion-style
        // accessor.
        if let klio_runtime::Value::Class(cls) = receiver {
            if cls.is_enum {
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
                        enum_class: Some(Arc::new(cls.name.clone())),
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
        }
        // Bound method/property reference field reads:
        // `nameRef.name` / `.simpleName` resolve to the captured
        // method name.
        if let klio_runtime::Value::Instance(inst) = receiver {
            let snap = inst.borrow();
            if snap.get("__bound_receiver__").is_some() {
                if let Some(klio_runtime::Value::String(n)) = snap.get("__bound_name__") {
                    match name {
                        "name" | "simpleName" => {
                            return Ok(klio_runtime::Value::String(Arc::clone(&n)));
                        }
                        _ => {}
                    }
                }
            }
        }
        // KFunction reflection: `::main.name`, `::main.parameters`.
        // Top-level fn refs lower as `Value::IrClosure` pointing at
        // the lowered Func; surface its metadata as field reads so
        // user code can introspect a callable.
        if let klio_runtime::Value::IrClosure { id, .. } = receiver {
            if let Some(info) = self.closures.get(*id as usize) {
                if let Some(f) = self.module.funcs.get(info.body_func.0 as usize) {
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
                                enum_class: None,
                            });
                        }
                        _ => {}
                    }
                }
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
                let suffix = format!("$Companion${}", name);
                if comp_name.ends_with(&suffix) {
                    if let Some(s) = self.globals.borrow().lookup(&comp_name) {
                        return Ok(s);
                    }
                }
                let singleton = self.globals.borrow().lookup(&comp_name);
                if let Some(singleton) = singleton {
                    if let klio_runtime::Value::Instance(inst) = &singleton {
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
                        if let Some(fid) = getter {
                            if let Some(func) = self
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
                }
            }
            // Nested singleton object: `Outer.Monotonic` /
            // `Sealed.Subclass` is a synthesised object singleton
            // published as a global. Its instance must win over the
            // synthesised class def so `Outer.Obj.member` reaches the
            // singleton rather than a bare KClass.
            if let Some(v) = self.globals.borrow().lookup(name) {
                if matches!(v, klio_runtime::Value::Instance(_)) {
                    return Ok(v);
                }
            }
            // Nested-class access on a class receiver: `Outer.Inner`
            // and `Sealed.Variant` resolve through the module's
            // global class table.
            if let Some(def) = self.classes.borrow().get(name).cloned() {
                return Ok(klio_runtime::Value::Class(def));
            }
            let _ = cls;
        }
        // Top-level extension property: `val T.name get() = ...`
        // — keyed by (receiver simple type, prop name). Falls
        // through to the standard lookup chain when the user
        // didn't declare an extension property for this combo.
        {
            let recv_simple: String = match receiver {
                klio_runtime::Value::Instance(i) => i.borrow().class.name.clone(),
                other => {
                    let f = other.type_fqn();
                    f.rsplit('.').next().unwrap_or(f).to_string()
                }
            };
            if let Some(fid) = self
                .prog.extension_props
                .get(&(recv_simple, name.to_string()))
                .copied()
            {
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
                    if cls.is_object {
                        if let Some(v) = self.globals.borrow().lookup(&cls.name) {
                            return Ok(v);
                        }
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
                        enum_class: None,
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
                        enum_class: None,
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
                        enum_class: None,
                    });
                }
                _ => {}
            },
            klio_runtime::Value::PropertyRef { name: pname } => match name {
                "name" | "simpleName" => {
                    return Ok(klio_runtime::Value::String(Arc::clone(pname)));
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
                klio_runtime::Value::String(s) => Some(s.chars().count() as i64),
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
                klio_runtime::Value::String(s) => Some(s.chars().count() as i64),
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
            if self.module.registry
                .delegated_body_props
                .contains(&(class_name.clone(), name.to_string()))
            {
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
            let getter_fid = {
                let mut found: Option<klio_ir::FuncId> = None;
                let mut cur = Some(class_name.clone());
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
                    if let Some(singleton) = singleton {
                        if let klio_runtime::Value::Instance(cinst) = &singleton {
                            if let Some(v) = cinst.borrow().get(name) {
                                return Ok(v);
                            }
                        }
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
                        enum_class: Some(Arc::new(class_def.name.clone())),
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
                if let Ok(v) = self.get_field(&d, name) {
                    if !matches!(v, klio_runtime::Value::Unit) {
                        return Ok(v);
                    }
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
                    {
                        if let Ok(v) = self.get_field(&singleton, name) {
                            if !matches!(v, klio_runtime::Value::Unit) {
                                return Ok(v);
                            }
                        }
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
        Err(klio_ir::eval::EvalError::Unimplemented(format!(
            "Vm::get_field `{name}` on `{}`",
            receiver.type_fqn()
        )))
    }

    fn set_field(
        &mut self,
        receiver: &klio_runtime::Value,
        name: &str,
        value: klio_runtime::Value,
    ) -> Result<(), klio_ir::eval::EvalError> {
        // Companion forwarding for writes: `Foo.count = 1` routes
        // to the companion singleton instance's field.
        if let klio_runtime::Value::Class(cls) = receiver {
            if let Some(comp_name) = self.module.registry.companion_singletons.get(&cls.name).cloned() {
                let singleton = self.globals.borrow().lookup(&comp_name);
                if let Some(singleton) = singleton {
                    if let klio_runtime::Value::Instance(_) = &singleton {
                        return self.set_field(&singleton, name, value);
                    }
                }
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
                            if let Some(singleton) = singleton {
                                if let klio_runtime::Value::Instance(cinst) = &singleton {
                                    if cinst.borrow().get(real_name).is_some() {
                                        return self.set_field(&singleton, real_name, value);
                                    }
                                }
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

    fn member_ref(
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

    fn register_class(
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
        let mut own_members: std::collections::HashSet<String> =
            std::collections::HashSet::new();
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
                tbl.insert(
                    (class.name.name.clone(), f.name.name.clone()),
                    entry,
                );
            }
        }
        Ok(())
    }

    fn register_class_captured(
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
            let mut extras: std::collections::HashSet<String> =
                std::collections::HashSet::new();
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
                    tbl.insert(
                        (class.name.name.clone(), f.name.name.clone()),
                        entry,
                    );
                }
            }
        }
        // Patch the just-registered method entries with the captured
        // outer-env so dispatch can layer them under globals.
        let capture_pairs: Vec<(String, klio_runtime::Value)> = captured_names
            .iter()
            .cloned()
            .zip(captures.into_iter())
            .collect();
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
                        entry.2 = capture_pairs.clone();
                    }
                }
            }
        }
        Ok(())
    }

    fn build_object(
        &mut self,
        ast: &klio_ast::Expr,
        captured_names: &[String],
        captures: Vec<klio_runtime::Value>,
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        let capture_pairs: Vec<(String, klio_runtime::Value)> = captured_names
            .iter()
            .cloned()
            .zip(captures.into_iter())
            .collect();
        // Minimal anonymous-object support: synthesise an
        // InstanceData backed by a fresh ClassDef from the AST's
        // ObjectExpr shape, with no parent ctor chain, no method
        // body lowering — primary use case is `object { val tag = X }`
        // markers and `object : SomeInterface { override fun ... }`
        // SAM-like wrappers used by tests. Full lowering lands when
        // the IR Class shape supports it.
        if let klio_ast::Expr::ObjectExpr { members, supertypes, supertype_args, .. } = ast {
            let identity = self.instance_id_counter.fetch_add(1, AtomicOrdering::Relaxed) + 1;
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
                    for me in pdef.methods.iter() {
                        own_members.insert(me.name.clone());
                    }
                }
            }
            for m in members {
                if let klio_ast::Decl::Function(f) = m {
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
                    tbl.insert(
                        (synth_class_name.clone(), f.name.name.clone()),
                        entry,
                    );
                }
            }
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
                    }),
                    _ => None,
                })
                .collect();
            let supertype_names: Vec<String> =
                supertypes.iter().map(|t| t.name.name.clone()).collect();
            let class_def = Arc::new(klio_runtime::ClassDef {
                name: format!("$anon${identity}"),
                fqn: format!("$anon${identity}"),
                annotation_names: Vec::new(),
                primary_params: Vec::new(),
                methods: Vec::new(),
                body_properties,
                init_blocks: Vec::new(),
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
            // Initialise body-property fields with literal values
            // only — anonymous-object property inits with arbitrary
            // expressions would need a thunk lowered at lower-time,
            // which the build pass already does for top-level
            // classes; extending it to anonymous expressions lands
            // when the IR grows an anon-class shape.
            let mut fields: Vec<(String, klio_runtime::Value)> = Vec::new();
            for p in &class_def.body_properties {
                if let Some(init) = &p.init {
                    if let Some(v) = simple_literal(init) {
                        fields.push((p.name.clone(), v));
                    } else {
                        fields.push((p.name.clone(), klio_runtime::Value::Null));
                    }
                } else {
                    fields.push((p.name.clone(), klio_runtime::Value::Null));
                }
            }
            // Populate parent's primary-param fields from
            // `object : Named("Anna") { … }` style supertype
            // ctor args. Best-effort: evaluate literal args via
            // `simple_literal` so subsequent `name` reads on this
            // instance see the parent's field.
            for (idx, sup) in supertypes.iter().enumerate() {
                let arg_exprs = match supertype_args.get(idx) {
                    Some(Some(v)) => v.clone(),
                    _ => continue,
                };
                let parent_def = self.classes.borrow().get(&sup.name.name).cloned();
                if let Some(pdef) = parent_def {
                    for (param, arg_expr) in
                        pdef.primary_params.iter().zip(arg_exprs.iter())
                    {
                        if param.property.is_none() {
                            continue;
                        }
                        let v =
                            simple_literal(arg_expr).unwrap_or(klio_runtime::Value::Null);
                        fields.push((param.name.clone(), v));
                    }
                }
            }
            let inst = klio_runtime::ObjRef::new(klio_runtime::InstanceData {
                class: class_def,
                fields,
                outer: None,
                identity,
                native_state: None,
            });
            return Ok(klio_runtime::Value::Instance(inst));
        }
        Err(klio_ir::eval::EvalError::Type(format!(
            "Vm::build_object: not an ObjectExpr AST node"
        )))
    }

    fn call_super(
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
                    if let Some(func) = self.module.funcs.get(fid.0 as usize).cloned() {
                        if func.name == name {
                            let mut all: Vec<klio_runtime::Value> =
                                Vec::with_capacity(args.len() + 1);
                            all.push(receiver.clone());
                            all.extend_from_slice(args);
                            let module = Arc::clone(&self.module);
                            return klio_ir::eval::eval_with(&module, &func, all, self);
                        }
                    }
                }
            }
            // Step to the next non-interface supertype.
            let next: Option<String> = self
                .classes
                .borrow()
                .get(&cname)
                .and_then(|d| d.supertype_names.first().cloned());
            current = next;
        }
        Err(klio_ir::eval::EvalError::Type(format!(
            "super.{name}: no matching method up the supertype chain from `{owner_class}`"
        )))
    }

    fn qualified_this(
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
            while let Some(c) = cur {
                if c.name == qualifier || c.fqn == qualifier {
                    return Ok(receiver.clone());
                }
                cur = c.parent.borrow().clone();
            }
            let mut outer = inst.borrow().outer.clone();
            while let Some(klio_runtime::Value::Instance(o_inst)) = outer.clone() {
                let cls = o_inst.borrow().class.clone();
                if cls.name == qualifier || cls.fqn == qualifier {
                    return Ok(klio_runtime::Value::Instance(o_inst.clone()));
                }
                let mut p = cls.parent.borrow().clone();
                while let Some(c) = p {
                    if c.name == qualifier || c.fqn == qualifier {
                        return Ok(klio_runtime::Value::Instance(o_inst.clone()));
                    }
                    p = c.parent.borrow().clone();
                }
                outer = o_inst.borrow().outer.clone();
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
        let enclosing = with_outer_this(|s| s.borrow().last().cloned());
        if let Some(klio_runtime::Value::Instance(o_inst)) = enclosing {
            let mut cur: Option<Arc<klio_runtime::ClassDef>> =
                Some(o_inst.borrow().class.clone());
            while let Some(c) = cur {
                if c.name == qualifier || c.fqn == qualifier {
                    return Ok(klio_runtime::Value::Instance(o_inst.clone()));
                }
                cur = c.parent.borrow().clone();
            }
        }
        let known_class = self.classes.borrow().contains_key(qualifier);
        if !known_class && !matches!(receiver, klio_runtime::Value::Null) {
            return Ok(receiver.clone());
        }
        Err(klio_ir::eval::EvalError::Type(format!(
            "`this@{qualifier}` is not bound in this scope"
        )))
    }

    fn instance_of(
        &mut self,
        value: &klio_runtime::Value,
        ty: &klio_ir::TypeRef,
    ) -> bool {
        // `null is T?` is true for any nullable type. `null is T`
        // (non-null T) is false.
        if matches!(value, klio_runtime::Value::Null) {
            return ty.nullable;
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
            "KProperty" | "KCallable" | "KFunction" | "KFunction0"
                | "KFunction1" | "KFunction2" | "KMutableProperty"
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
                        "KFunction" | "KFunction0" | "KFunction1" | "KFunction2" => {
                            !is_property
                        }
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
                return matches!(ty.name.as_str(), "KFunction" | "KCallable" | "KFunction0" | "KFunction1" | "KFunction2");
            }
        }
        if ty.name == "KClass" {
            return matches!(value, klio_runtime::Value::Class(_));
        }
        if ty.name == "EnumEntries" {
            return matches!(
                value,
                klio_runtime::Value::List { enum_class: Some(_), .. }
            );
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
            if let Some(rest) = ty.name.strip_prefix("Function") {
                if rest.chars().all(|c| c.is_ascii_digit()) && !rest.is_empty() {
                    return true;
                }
            }
        }
        // Dotted nested-class names (`S.A`, `Outer.Inner`) — match
        // by the last segment, which corresponds to the lifted
        // top-level class name in our module table.
        if ty.name.contains('.') {
            if let Some(last) = ty.name.rsplit('.').next() {
                let alt = klio_ir::TypeRef {
                    name: last.to_string(),
                    nullable: ty.nullable,
                    args: ty.args.clone(),
                };
                return self.instance_of(value, &alt);
            }
        }
        // Generic type-parameter casts (`x as T`) are erased at
        // runtime — Kotlin matches them unchecked. Single-letter
        // (or short uppercase) type names are conventionally
        // generic parameters and have no class entry; treat them
        // as accept-any-non-null — unless the call site bound a
        // reified type-param to a concrete `Value::Class`, in
        // which case redirect the check to that class's name.
        if matches!(ty.name.as_str(), "T" | "U" | "V" | "K" | "R" | "E" | "X" | "Y" | "Z" | "A" | "B" | "C" | "D")
        {
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
                ("IllegalArgumentException", "RuntimeException")
                    | ("IllegalStateException", "RuntimeException")
                    | ("IndexOutOfBoundsException", "RuntimeException")
                    | ("NullPointerException", "RuntimeException")
                    | ("ArithmeticException", "RuntimeException")
                    | ("ClassCastException", "RuntimeException")
                    | ("NoSuchElementException", "RuntimeException")
                    | ("NumberFormatException", "RuntimeException")
                    | ("UnsupportedOperationException", "RuntimeException")
                    | ("UninitializedPropertyAccessException", "RuntimeException")
                    | ("ConcurrentModificationException", "RuntimeException")
                    | ("NoWhenBranchMatchedException", "RuntimeException")
                    | ("AssertionError", "Error")
                    | ("RuntimeException", "Exception")
                    | ("Error", "Throwable")
                    | ("Exception", "Throwable")
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
            while let Some(c) = cur {
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
                cur = c.parent.borrow().clone();
            }
            // `Any` matches every instance.
            if ty.name == "Any" {
                return true;
            }
            return false;
        }
        let nominal = value.type_fqn();
        nominal == ty.name || nominal.ends_with(&format!(".{}", ty.name))
    }

    fn call_func(
        &mut self,
        module: &klio_ir::Module,
        func: klio_ir::FuncId,
        args: Vec<klio_runtime::Value>,
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        let f = module
            .funcs
            .get(func.0 as usize)
            .cloned()
            .ok_or_else(|| {
                klio_ir::eval::EvalError::Type(format!("unknown FuncId {}", func.0))
            })?;
        // Pack-installed binding fast path: a top-level function whose
        // package-qualified FQN matches a registered binding shadows
        // the shim body shipped in source.
        if let Some(intrinsic) = self.prog.installed_bindings.resolve(&f.fqn) {
            let v = self.dispatch_intrinsic(intrinsic, &args)?;
            return Ok(v);
        }
        // Pad missing positional args with each param's default
        // value (from the registered default-init thunks).
        let mut args = args;
        // Kotlin trailing-lambda rule: when fewer args are supplied
        // than params and the last param is a function type while a
        // default-valued param sits before it, the final supplied
        // callable is the trailing lambda and binds the *last*
        // param; the gap params fall back to their defaults. Without
        // this the lambda would slot into the first (defaulted)
        // param and the real last param would be left unbound.
        if args.len() < f.params.len() && args.len() >= 1 {
            let last_is_fn = f
                .params
                .last()
                .map(|p| is_function_type(&p.ty))
                .unwrap_or(false);
            let trailing_is_callable =
                args.last().map(value_is_callable).unwrap_or(false);
            if last_is_fn && trailing_is_callable {
                let lead = args.len() - 1;
                let last_param = f.params.len() - 1;
                if lead < last_param {
                    if let Some(defaults) = self.prog.func_defaults.get(&func).cloned() {
                        let trailing = args.pop().unwrap();
                        for idx in lead..last_param {
                            if let Some(Some(default_fid)) = defaults.get(idx) {
                                let dfid = *default_fid;
                                let dfunc = module
                                    .funcs
                                    .get(dfid.0 as usize)
                                    .cloned()
                                    .ok_or_else(|| {
                                        klio_ir::eval::EvalError::Type(format!(
                                            "default-arg FuncId {} out of range",
                                            dfid.0
                                        ))
                                    })?;
                                let v = klio_ir::eval::eval_with(
                                    module,
                                    &dfunc,
                                    args.clone(),
                                    self,
                                )?;
                                args.push(v);
                            } else {
                                args.push(klio_runtime::Value::Null);
                            }
                        }
                        args.push(trailing);
                    }
                }
            }
        }
        if args.len() < f.params.len() {
            if let Some(defaults) = self.prog.func_defaults.get(&func).cloned() {
                for idx in args.len()..f.params.len() {
                    if let Some(Some(default_fid)) = defaults.get(idx) {
                        let dfid = *default_fid;
                        let dfunc = module
                            .funcs
                            .get(dfid.0 as usize)
                            .cloned()
                            .ok_or_else(|| {
                                klio_ir::eval::EvalError::Type(format!(
                                    "default-arg FuncId {} out of range",
                                    dfid.0
                                ))
                            })?;
                        // The thunk binds the parameters preceding
                        // this one, so a default like `endIndex =
                        // s.length` can read earlier args.
                        let v = klio_ir::eval::eval_with(module, &dfunc, args.clone(), self)?;
                        args.push(v);
                    } else {
                        args.push(klio_runtime::Value::Null);
                    }
                }
            }
        }
        let args = pack_vararg_args(&f, args);
        klio_ir::eval::eval_with(module, &f, args, self)
    }

    fn call_func_named(
        &mut self,
        module: &klio_ir::Module,
        func: klio_ir::FuncId,
        args: Vec<klio_runtime::Value>,
        arg_names: &[Option<String>],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        // Reorder named args against the target function's
        // declared parameter list. Positional args fill the next
        // free slot; named args slot by name.
        if arg_names.iter().any(|n| n.is_some()) {
            if let Some(f) = module.funcs.get(func.0 as usize) {
                let params = &f.params;
                let mut slots: Vec<Option<klio_runtime::Value>> = vec![None; params.len()];
                let mut positional_idx = 0usize;
                for (i, a) in args.iter().enumerate() {
                    if let Some(Some(arg_name)) = arg_names.get(i) {
                        if let Some(pos) =
                            params.iter().position(|p| &p.name == arg_name)
                        {
                            slots[pos] = Some(a.clone());
                        }
                    } else {
                        if positional_idx < params.len() {
                            slots[positional_idx] = Some(a.clone());
                        }
                        positional_idx += 1;
                    }
                }
                // Fill omitted slots from the function's default-arg
                // thunks (left-to-right, so a default may read an
                // earlier param). A named call that skips a
                // *non-trailing* defaulted param
                // (`DateTimePeriod(months = 1, days = 2)` skipping
                // `years`) must evaluate that default, not pass Null.
                let n_params = params.len();
                let defaults = self.prog.func_defaults.get(&func).cloned();
                let mut reordered: Vec<klio_runtime::Value> =
                    Vec::with_capacity(n_params);
                let mut truncated = false;
                for (i, slot) in slots.into_iter().enumerate() {
                    if let Some(v) = slot {
                        reordered.push(v);
                        continue;
                    }
                    let dfid = defaults
                        .as_ref()
                        .and_then(|d| d.get(i).copied().flatten());
                    if let Some(dfid) = dfid {
                        let dfunc = module
                            .funcs
                            .get(dfid.0 as usize)
                            .cloned()
                            .ok_or_else(|| {
                                klio_ir::eval::EvalError::Type(format!(
                                    "default-arg FuncId {} out of range",
                                    dfid.0
                                ))
                            })?;
                        let v = klio_ir::eval::eval_with(
                            module,
                            &dfunc,
                            reordered.clone(),
                            self,
                        )?;
                        reordered.push(v);
                    } else {
                        // No value and no default: a trailing
                        // omitted param. Hand the prefix to
                        // call_func, whose own default / vararg /
                        // trailing-lambda padding finishes the job.
                        truncated = true;
                        break;
                    }
                }
                if !truncated {
                    while matches!(
                        reordered.last(),
                        Some(klio_runtime::Value::Null)
                    ) {
                        reordered.pop();
                    }
                }
                return self.call_func(module, func, reordered);
            }
        }
        self.call_func(module, func, args)
    }

    fn call_func_typed(
        &mut self,
        module: &klio_ir::Module,
        func: klio_ir::FuncId,
        args: Vec<klio_runtime::Value>,
        arg_names: &[Option<String>],
        type_args: &[String],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        // Overload resolution: when the target function shares its
        // name with siblings (typical for packs like
        // `kotlinx.atomicfu` declaring multiple `atomic(...)` shapes),
        // the IR call site bakes in the first FuncId at lower time —
        // pick the best match here using the runtime arg types.
        let func = self.pick_overload(module, func, &args).unwrap_or(func);
        // Incompatible-receiver guard (sound, narrow): a bare call
        // baked to a top-level extension (`fun R.f`, param0
        // == "this") whose declared receiver `R` is a *user / pack
        // class* — never a builtin and never an interface/Any a
        // builtin could satisfy — but whose actual receiver arg is a
        // *builtin value* (String/StringBuilder/Int/Array/…) cannot
        // be correct: a builtin value is never an instance of a user
        // class. Without this, a kotlinx-io `ByteStringBuilder.append`
        // selected for a `kotlin.text.StringBuilder` receiver
        // self-recurses. Re-dispatch as a member call so the builtin
        // member wins. Instance / Class receivers never trip this, so
        // interface- and subtype-receiver extensions are unaffected.
        if let Some(f) = module.funcs.get(func.0 as usize) {
            if f.params.first().map(|p| p.name == "this").unwrap_or(false)
                && !args.is_empty()
                && ext_decl_recv_is_user_class(&f.params[0].ty.name)
                && value_is_builtin(&args[0])
            {
                let fname = f.name.clone();
                let recv = args[0].clone();
                let rest = args[1..].to_vec();
                return self.call_member(&recv, &fname, &rest);
            }
        }
        // Bind each call-site type-arg name to a synth
        // `Value::Class` global for the duration of the call so
        // reified type-param reads (`T::class`) resolve. We
        // snapshot any pre-existing bindings, install the new
        // ones, then restore on exit so concurrent / recursive
        // calls don't see stale T values.
        let names: Vec<String> = self.module.registry
            .func_type_params
            .get(&func)
            .cloned()
            .unwrap_or_default();
        let mut saved: Vec<(String, Option<klio_runtime::Value>)> = Vec::new();
        for (idx, type_name) in names.iter().enumerate() {
            let arg_name = type_args.get(idx).cloned().unwrap_or_default();
            if arg_name.is_empty() {
                continue;
            }
            let cls_value = self.lookup_global(&arg_name);
            saved.push((type_name.clone(), self.globals.borrow().lookup(type_name)));
            if let Some(v) = cls_value {
                self.globals.borrow_mut().define(type_name.clone(), v);
            }
        }
        let result = self.call_func_named(module, func, args, arg_names);
        for (name, prev) in saved.into_iter().rev() {
            match prev {
                Some(v) => self.globals.borrow_mut().define(name, v),
                None => {
                    self.globals.borrow_mut().remove_local(&name);
                }
            }
        }
        result
    }

    fn call_named_overload(
        &mut self,
        module: &klio_ir::Module,
        name: &str,
        args: &[klio_runtime::Value],
        arg_names: &[Option<String>],
    ) -> Result<Option<klio_runtime::Value>, klio_ir::eval::EvalError> {
        // Only intercept genuine overload sets: a single top-level
        // function keeps the plain global-value path (which carries
        // default-arg + vararg packing the IrClosure branch handles).
        let mut first: Option<klio_ir::FuncId> = None;
        let mut count = 0usize;
        for (n, id) in &module.func_index {
            if n == name {
                count += 1;
                if first.is_none() {
                    first = Some(*id);
                }
            }
        }
        if count < 2 {
            return Ok(None);
        }
        let func = first.expect("count >= 2 implies a first candidate");
        let result = self.call_func_typed(
            module,
            func,
            args.to_vec(),
            arg_names,
            &[],
        )?;
        Ok(Some(result))
    }

    fn build_ast_lambda_with_flag_funcid(
        &mut self,
        params: &[String],
        _body: &klio_ast::Block,
        captured_names: &[String],
        captures: Vec<klio_runtime::Value>,
        _absorb_return: bool,
        body_func: Option<klio_ir::FuncId>,
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        let body_func = body_func.ok_or_else(|| {
            klio_ir::eval::EvalError::Unimplemented(
                "Vm: lambda lower did not provide body_func".into(),
            )
        })?;
        let cell = klio_runtime::ObjRef::new(captures.clone());
        let id = self.closures.push(ClosureInfo {
            body_func,
            n_params: params.len(),
            capture_names: captured_names.to_vec(),
            captures: cell,
        });
        Ok(klio_runtime::Value::IrClosure {
            id,
            captures: Arc::new(captures),
        })
    }

    fn read_lambda_capture(
        &mut self,
        lambda: &klio_runtime::Value,
        name: &str,
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        if let klio_runtime::Value::IrClosure { id, .. } = lambda {
            let info = self.closures.get(*id as usize).ok_or_else(|| {
                klio_ir::eval::EvalError::Type(format!("unknown IrClosure id {id}"))
            })?;
            for (idx, cap_name) in info.capture_names.iter().enumerate() {
                if cap_name == name {
                    return Ok(info
                        .captures
                        .borrow()
                        .get(idx)
                        .cloned()
                        .unwrap_or(klio_runtime::Value::Null));
                }
            }
            return Err(klio_ir::eval::EvalError::Unbound(format!(
                "capture `{name}` not found in lambda"
            )));
        }
        Err(klio_ir::eval::EvalError::Type(format!(
            "read_lambda_capture on non-lambda value `{}`",
            lambda.type_fqn()
        )))
    }

    fn call_member(
        &mut self,
        receiver: &klio_runtime::Value,
        name: &str,
        args: &[klio_runtime::Value],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        // Built-in delegate protocol: `delegate.getValue(thisRef,
        // prop)` / `setValue(thisRef, prop, v)` for a `by lazy { }`,
        // `Delegates.observable`, `notNull()`, etc. The delegated
        // class-body / top-level property read explicitly invokes
        // this, so a `Value::Delegate` receiver must honour it.
        if let klio_runtime::Value::Delegate(d) = receiver {
            match name {
                "getValue" => {
                    let state = d.borrow().clone();
                    return match state {
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
                            Ok(result)
                        }
                        klio_runtime::DelegateKind::Observable { value, .. } => Ok(value),
                        klio_runtime::DelegateKind::NotNull { value, .. } => match value {
                            Some(x) => Ok(x),
                            None => Err(klio_ir::eval::EvalError::Throw(
                                klio_runtime::Value::Exception {
                                    fqn: Arc::new("kotlin.IllegalStateException".into()),
                                    message: Some(Arc::new(
                                        "Property should be initialized before get.".into(),
                                    )),
                                    cause: None,
                                },
                            )),
                        },
                    };
                }
                "setValue" => {
                    if let Some(new_v) = args.get(2) {
                        let mut st = d.borrow_mut();
                        match &mut *st {
                            klio_runtime::DelegateKind::Lazy { cached, .. } => {
                                *cached = Some(new_v.clone());
                            }
                            klio_runtime::DelegateKind::Observable {
                                value, on_change,
                            } => {
                                let old = value.clone();
                                *value = new_v.clone();
                                let cb = on_change.clone();
                                drop(st);
                                if !matches!(cb, klio_runtime::Value::Null) {
                                    let _ = <Self as klio_ir::eval::Host>::call_value(
                                        self,
                                        &cb,
                                        &[klio_runtime::Value::Null, old, new_v.clone()],
                                    );
                                }
                            }
                            klio_runtime::DelegateKind::NotNull { value, .. } => {
                                *value = Some(new_v.clone());
                            }
                        }
                    }
                    return Ok(klio_runtime::Value::Unit);
                }
                _ => {}
            }
        }
        // Pack-installed binding overlay: when a loaded pack
        // registers `<typeFqn>.<name>` the Rust binding shadows the
        // interpreted shim body. Probe before the IR method walk so
        // the native fast path always wins.
        if let klio_runtime::Value::Instance(inst) = receiver {
            let snap = inst.borrow();
            let cls_fqn = snap.class.fqn.clone();
            let cls_name = snap.class.name.clone();
            drop(snap);
            let probes = [
                format!("{cls_fqn}.{name}"),
                format!("{cls_name}.{name}"),
            ];
            for p in &probes {
                if let Some(func) = self.prog.installed_bindings.resolve(p) {
                    let mut all_args: Vec<klio_runtime::Value> =
                        Vec::with_capacity(args.len() + 1);
                    all_args.push(receiver.clone());
                    all_args.extend_from_slice(args);
                    return self.dispatch_intrinsic(func, &all_args);
                }
            }
        }
        // `Delegates.notNull` / `Delegates.observable` /
        // `Delegates.vetoable` — synthesise the proper
        // `Value::Delegate` directly. The singleton itself is
        // surfaced via `lookup_global` as a sentinel Intrinsic.
        // `Thread` handle returned by `kotlin.concurrent.thread`. The
        // body already ran to completion on the calling stack (see
        // `concurrent_thread`), so `join()` is a no-op whose
        // happens-before guarantee already holds; `isAlive` is false
        // and `name` is a stable string. `fence_and_publish` marks the
        // join boundary.
        if let klio_runtime::Value::BoundMethod { fqn, receiver: tid, .. } = receiver {
            if *fqn == "kotlin.concurrent.Thread" {
                let id = match **tid {
                    klio_runtime::Value::Long(v) => v as u64,
                    _ => 0,
                };
                match name {
                    "join" => {
                        return self
                            .join_spawned(id)
                            .map(|()| klio_runtime::Value::Unit)
                            .map_err(|e| match e {
                                klio_runtime::RuntimeError::Thrown(v) => {
                                    klio_ir::eval::EvalError::Throw(v)
                                }
                                other => {
                                    klio_ir::eval::EvalError::Type(format!("{other}"))
                                }
                            });
                    }
                    "isAlive" => {
                        return Ok(klio_runtime::Value::Bool(self.thread_alive(id)))
                    }
                    "name" => {
                        return Ok(klio_runtime::Value::String(Arc::new(format!(
                            "klio-thread-{id}"
                        ))))
                    }
                    "start" | "interrupt" => return Ok(klio_runtime::Value::Unit),
                    _ => {}
                }
            }
        }
        if let klio_runtime::Value::Intrinsic { fqn, .. } = receiver {
            if *fqn == "kotlin.properties.Delegates" {
                match (name, args.len()) {
                    ("notNull", 0) => {
                        return Ok(klio_runtime::Value::Delegate(klio_runtime::ObjRef::new(
                            klio_runtime::DelegateKind::NotNull {
                                value: None,
                                name: String::new(),
                            },
                            )));
                    }
                    ("observable", 2) => {
                        return Ok(klio_runtime::Value::Delegate(klio_runtime::ObjRef::new(
                            klio_runtime::DelegateKind::Observable {
                                value: args[0].clone(),
                                on_change: args[1].clone(),
                            },
                            )));
                    }
                    _ => {}
                }
            }
        }
        // Static call on a class-or-intrinsic receiver: probe stdlib
        // by `<receiver-fqn>.<name>` so `Regex.escape("x")` and
        // `Color.values()` route through the matching binding. The
        // intrinsic value carries its package-qualified fqn; classes
        // surface as the simple name (matching klio-stdlib's bare
        // class-method registrations).
        if let klio_runtime::Value::Intrinsic { fqn, .. } = receiver {
            let probe = format!("{fqn}.{name}");
            if let Some(func) = self.lookup_intrinsic(&probe) {
                return self.dispatch_intrinsic(func, args);
            }
        }
        if let klio_runtime::Value::Class(cls) = receiver {
            let probe_simple = format!("{}.{}", cls.name, name);
            if let Some(func) = self.lookup_intrinsic(&probe_simple) {
                return self.dispatch_intrinsic(func, args);
            }
            let probe_fqn = format!("{}.{}", cls.fqn, name);
            if let Some(func) = self.lookup_intrinsic(&probe_fqn) {
                return self.dispatch_intrinsic(func, args);
            }
        }
        // Built-in iterator protocol for collections + ranges. The
        // IR's for-loop lowers as `receiver.iterator()` plus a
        // `hasNext` / `next` loop, so these have to dispatch
        // natively rather than through the stdlib FQN table.
        if name == "iterator" && args.is_empty() {
            match receiver {
                klio_runtime::Value::List { items, .. } => {
                    let items_clone: Vec<klio_runtime::Value> = items.borrow().clone();
                    return Ok(klio_runtime::Value::Iterator {
                        items: klio_runtime::ObjRef::new(items_clone),
                        pos: klio_runtime::ObjRef::new(0),
                        prim: None,
                    });
                }
                klio_runtime::Value::Set { items, .. } => {
                    let items_clone: Vec<klio_runtime::Value> = items.borrow().clone();
                    return Ok(klio_runtime::Value::Iterator {
                        items: klio_runtime::ObjRef::new(items_clone),
                        pos: klio_runtime::ObjRef::new(0),
                        prim: None,
                    });
                }
                klio_runtime::Value::Map { entries, .. } => {
                    let entries_clone: Vec<klio_runtime::Value> = entries
                        .borrow()
                        .iter()
                        .map(|(k, v)| klio_runtime::Value::MapEntry {
                            key: Box::new(k.clone()),
                            value: Box::new(v.clone()),
                        })
                        .collect();
                    return Ok(klio_runtime::Value::Iterator {
                        items: klio_runtime::ObjRef::new(entries_clone),
                        pos: klio_runtime::ObjRef::new(0),
                        prim: None,
                    });
                }
                klio_runtime::Value::Range { start, end, step, kind } => {
                    let items = materialise_range_items(*start, *end, *step, *kind);
                    return Ok(klio_runtime::Value::Iterator {
                        items: klio_runtime::ObjRef::new(items),
                        pos: klio_runtime::ObjRef::new(0),
                        prim: None,
                    });
                }
                klio_runtime::Value::Array { items, prim } => {
                    let items_clone: Vec<klio_runtime::Value> = items.borrow().clone();
                    return Ok(klio_runtime::Value::Iterator {
                        items: klio_runtime::ObjRef::new(items_clone),
                        pos: klio_runtime::ObjRef::new(0),
                        prim: *prim,
                    });
                }
                klio_runtime::Value::String(s) => {
                    let items: Vec<klio_runtime::Value> = s
                        .chars()
                        .map(klio_runtime::Value::Char)
                        .collect();
                    return Ok(klio_runtime::Value::Iterator {
                        items: klio_runtime::ObjRef::new(items),
                        pos: klio_runtime::ObjRef::new(0),
                        prim: None,
                    });
                }
                _ => {}
            }
        }
        // Sequence terminal ops: materialise the lazy pipeline then
        // dispatch the op against the materialised vector.
        if let klio_runtime::Value::Sequence(_) = receiver {
            let terminal = matches!(
                name,
                "toList"
                    | "toMutableList"
                    | "toSet"
                    | "count"
                    | "sum"
                    | "average"
                    | "sumOf"
                    | "first"
                    | "firstOrNull"
                    | "last"
                    | "lastOrNull"
                    | "forEach"
                    | "fold"
                    | "reduce"
                    | "iterator"
                    | "max"
                    | "maxOrNull"
                    | "min"
                    | "minOrNull"
                    | "maxBy"
                    | "minBy"
                    | "maxByOrNull"
                    | "minByOrNull"
                    | "maxOf"
                    | "minOf"
                    | "joinToString"
                    | "any"
                    | "all"
                    | "none"
                    | "contains"
                    | "groupBy"
                    | "associate"
                    | "associateBy"
                    | "associateWith"
                    | "partition"
                    | "indexOf"
                    | "indexOfFirst"
                    | "toMap"
                    | "toHashSet"
                    | "toMutableSet"
                    | "windowed"
                    | "chunked"
                    | "zipWithNext"
            );
            if terminal {
                let items = self.materialise_sequence(receiver)?;
                let as_list = klio_runtime::Value::List {
                    items: klio_runtime::ObjRef::new(items),
                    mutable: false,
                    enum_class: None,
                };
                return self.call_member(&as_list, name, args);
            }
        }
        // Sequence pipeline ops: append the op to a fresh
        // SequenceData and return a new Sequence value.
        if let klio_runtime::Value::Sequence(seq) = receiver {
            let make_seq = |new_op: klio_runtime::SeqOp| -> klio_runtime::Value {
                let mut ops = seq.ops.clone();
                ops.push(new_op);
                klio_runtime::Value::Sequence(Arc::new(klio_runtime::SequenceData {
                    source: seq.source.clone(),
                    ops,
                }))
            };
            match (name, args.len()) {
                ("map", 1) => return Ok(make_seq(klio_runtime::SeqOp::Map(args[0].clone()))),
                ("filter", 1) => {
                    return Ok(make_seq(klio_runtime::SeqOp::Filter(args[0].clone())))
                }
                ("filterNot", 1) => {
                    return Ok(make_seq(klio_runtime::SeqOp::FilterNot(args[0].clone())))
                }
                ("take", 1) => {
                    if let Some(n) = args[0].as_i64() {
                        return Ok(make_seq(klio_runtime::SeqOp::Take(n)));
                    }
                }
                ("drop", 1) => {
                    if let Some(n) = args[0].as_i64() {
                        return Ok(make_seq(klio_runtime::SeqOp::Drop(n)));
                    }
                }
                ("takeWhile", 1) => {
                    return Ok(make_seq(klio_runtime::SeqOp::TakeWhile(args[0].clone())))
                }
                ("dropWhile", 1) => {
                    return Ok(make_seq(klio_runtime::SeqOp::DropWhile(args[0].clone())))
                }
                ("flatMap", 1) => {
                    return Ok(make_seq(klio_runtime::SeqOp::FlatMap(args[0].clone())))
                }
                ("distinct", 0) => return Ok(make_seq(klio_runtime::SeqOp::Distinct)),
                ("distinctBy", 1) => {
                    return Ok(make_seq(klio_runtime::SeqOp::DistinctBy(args[0].clone())))
                }
                ("sorted", 0) => return Ok(make_seq(klio_runtime::SeqOp::Sorted(false))),
                ("sortedDescending", 0) => return Ok(make_seq(klio_runtime::SeqOp::Sorted(true))),
                ("sortedBy", 1) => {
                    return Ok(make_seq(klio_runtime::SeqOp::SortedBy(
                        args[0].clone(),
                        false,
                    )))
                }
                ("sortedByDescending", 1) => {
                    return Ok(make_seq(klio_runtime::SeqOp::SortedBy(
                        args[0].clone(),
                        true,
                    )))
                }
                ("sortedWith", 1) => {
                    return Ok(make_seq(klio_runtime::SeqOp::SortedWith(args[0].clone())))
                }
                _ => {}
            }
        }
        // Inner-class construction: `outer.Inner(args)` constructs an
        // Inner instance with the outer stored on the instance's
        // `outer` field. The lifted inner class lives at top level.
        if let klio_runtime::Value::Instance(outer_inst) = receiver {
            let def_opt = self.classes.borrow().get(name).cloned();
            if let Some(def) = def_opt {
                if def.is_inner {
                    let class_id = self.module.class_id(name);
                    if let Some(class_id) = class_id {
                        let v = <Self as klio_ir::eval::Host>::new_instance(
                            self, class_id, args,
                        )?;
                        if let klio_runtime::Value::Instance(i) = &v {
                            i.borrow_mut().outer = Some(klio_runtime::Value::Instance(outer_inst.clone()));
                        }
                        return Ok(v);
                    }
                }
            }
        }
        // Nested-class construction on a class receiver:
        // `Container.Nested(args)` or `Sealed.Variant(args)` — look
        // up the named class in the module table and construct.
        if let klio_runtime::Value::Class(_) = receiver {
            if let Some(class_id) = self.module.class_id(name) {
                return <Self as klio_ir::eval::Host>::new_instance(self, class_id, args);
            }
        }
        // Companion forwarding for method calls: `Foo.parse("…")`
        // routes through the companion singleton's method.
        if let klio_runtime::Value::Class(cls) = receiver {
            // companion_singletons is keyed by simple name; an
            // embedded-stdlib / pack class can present its fqn, so
            // probe both the name and the fqn's simple tail.
            let comp_name = self
                .module
                .registry
                .companion_singletons
                .get(&cls.name)
                .or_else(|| {
                    self.module
                        .registry
                        .companion_singletons
                        .get(&cls.fqn)
                })
                .or_else(|| {
                    cls.fqn.rsplit('.').next().and_then(|s| {
                        self.module.registry.companion_singletons.get(s)
                    })
                })
                .cloned();
            if let Some(comp_name) = comp_name {
                let singleton = self.globals.borrow().lookup(&comp_name);
                if let Some(singleton) = singleton {
                    if matches!(singleton, klio_runtime::Value::Instance(_)) {
                        // Forward to the companion instance. Only the
                        // specific "this exact member is not on the
                        // companion" Unimplemented falls through (so
                        // other resolution can try); any *other*
                        // error — including an Unimplemented from
                        // deeper inside the companion method's body —
                        // propagates rather than being masked as
                        // member-on-KClass.
                        let no_such = format!("`{name}` on");
                        match self.call_member(&singleton, name, args) {
                            Ok(v) => return Ok(v),
                            Err(klio_ir::eval::EvalError::Unimplemented(m))
                                if m.contains("Vm::call_member")
                                    && m.contains(&no_such) => {}
                            Err(e) => return Err(e),
                        }
                    }
                }
            }
            // Enum.values() — synthesise the entries list from the class.
            if cls.is_enum && (name == "values") && args.is_empty() {
                let items: Vec<klio_runtime::Value> = cls
                    .enum_entries
                    .borrow()
                    .iter()
                    .map(|(_, v)| v.clone())
                    .collect();
                return Ok(klio_runtime::Value::List {
                    items: klio_runtime::ObjRef::new(items),
                    mutable: false,
                    enum_class: Some(Arc::new(cls.name.clone())),
                });
            }
            // Enum.valueOf("X") — find entry by name.
            if cls.is_enum && name == "valueOf" && args.len() == 1 {
                if let klio_runtime::Value::String(s) = &args[0] {
                    if let Some((_, v)) = cls
                        .enum_entries
                        .borrow()
                        .iter()
                        .find(|(n, _)| n == s.as_str())
                    {
                        return Ok(v.clone());
                    }
                    return Err(klio_ir::eval::EvalError::Throw(
                        klio_runtime::Value::Exception {
                            fqn: std::sync::Arc::new(
                                "kotlin.IllegalArgumentException".to_string(),
                            ),
                            message: Some(std::sync::Arc::new(format!(
                                "No enum constant {}.{}",
                                cls.fqn, s
                            ))),
                            cause: None,
                        },
                    ));
                }
            }
        }
        // Null-receiver `equals` — `a == null` with `a: T?` lowers
        // through `equals`, which Kotlin returns `true` only when
        // both sides are null. `null.equals(x)` ≡ `x == null`.
        if matches!(receiver, klio_runtime::Value::Null) && name == "equals" && args.len() == 1
        {
            return Ok(klio_runtime::Value::Bool(matches!(
                args[0],
                klio_runtime::Value::Null
            )));
        }
        // SAM-instance dispatch: a synthetic `FunInterface { … }`
        // wrapper carries its lambda under `__sam_target__`. Any
        // method call on the receiver invokes the stored callable.
        if let klio_runtime::Value::Instance(inst) = receiver {
            let target = inst.borrow().get("__sam_target__");
            if let Some(target) = target {
                return self.call_value(&target, args);
            }
        }
        // Bound method/property-reference dispatch: a `recv::member`
        // wrapper routes calls through the captured receiver + name.
        // Property refs (receiver is a class) handle `get(arg)` as
        // a property read on `arg`. Method refs (receiver is an
        // instance) forward all args through `call_member`.
        if let klio_runtime::Value::Instance(inst) = receiver {
            let snap = inst.borrow();
            let recv_capt = snap.get("__bound_receiver__");
            let name_capt = snap.get("__bound_name__");
            drop(snap);
            if let (Some(rc), Some(klio_runtime::Value::String(n))) =
                (recv_capt, name_capt)
            {
                if matches!(name, "name" | "simpleName") {
                    // Field reads on the ref itself; handled by
                    // get_field.
                } else if matches!(&rc, klio_runtime::Value::Class(_)) {
                    // Unbound property reference: `r.get(arg)` /
                    // `r.invoke(arg)` reads `arg.<n>`.
                    if matches!(name, "get" | "call" | "invoke") && args.len() == 1 {
                        return self.get_field(&args[0], &n);
                    }
                } else {
                    // Bound method reference: forward the call.
                    return self.call_member(&rc, &n, args);
                }
            }
        }
        // SAM conversion: a callable (lambda / closure / function
        // ref) passed where a `fun interface` is expected accepts
        // any method call by forwarding to the underlying invoke.
        if matches!(
            receiver,
            klio_runtime::Value::Lambda { .. }
                | klio_runtime::Value::IrClosure { .. }
                | klio_runtime::Value::Function { .. }
                | klio_runtime::Value::Intrinsic { .. }
        ) {
            // A user extension on a function type
            // (`fun (() -> T).foo()`) lowers to a top-level fn whose
            // first param is the receiver. When one named `name`
            // exists, it must win over the SAM-invoke shortcut, which
            // would otherwise just call the receiver and discard the
            // intended dispatch. Defer to the extension-fn fallback.
            let has_ext = self.module.func_index.iter().any(|(n, fid)| {
                n == name
                    && self
                        .module
                        .funcs
                        .get(fid.0 as usize)
                        .map(|f| {
                            f.params.first().map(|p| p.name == "this").unwrap_or(false)
                                && f.params.len() >= args.len() + 1
                        })
                        .unwrap_or(false)
            });
            if name != "invoke" && !has_ext {
                if let Ok(v) = self.call_value(receiver, args) {
                    return Ok(v);
                }
            }
        }
        // KClass equality + hash + toString — structural by the
        // class's `name`. `Person::class == Person::class` is true,
        // distinct classes compare unequal.
        if let klio_runtime::Value::Class(a) = receiver {
            match (name, args.len()) {
                ("equals", 1) => {
                    let eq = if let klio_runtime::Value::Class(b) = &args[0] {
                        a.name == b.name
                    } else {
                        false
                    };
                    return Ok(klio_runtime::Value::Bool(eq));
                }
                ("hashCode", 0) => {
                    use std::hash::{Hash, Hasher};
                    let mut h = std::collections::hash_map::DefaultHasher::new();
                    a.name.hash(&mut h);
                    return Ok(klio_runtime::Value::new_int(h.finish() as i64));
                }
                ("toString", 0) => {
                    return Ok(klio_runtime::Value::String(Arc::new(format!(
                        "class {}", a.name
                    ))));
                }
                _ => {}
            }
        }
        // KFunction reflection surface on a closure / function value.
        // `f.call(a, b)` / `f.invoke(a, b)` dispatch the callable;
        // `f.name` / `f.parameters` report the lowered Func metadata.
        if matches!(
            receiver,
            klio_runtime::Value::IrClosure { .. }
                | klio_runtime::Value::Lambda { .. }
                | klio_runtime::Value::Function { .. }
        ) {
            match name {
                "invoke" | "call" => {
                    return <Self as klio_ir::eval::Host>::call_value(self, receiver, args);
                }
                _ => {}
            }
            if args.is_empty() {
                if let klio_runtime::Value::IrClosure { id, .. } = receiver {
                    if let Some(info) = self.closures.get(*id as usize) {
                        if let Some(f) = self.module.funcs.get(info.body_func.0 as usize)
                        {
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
                                            klio_runtime::Value::String(Arc::new(
                                                p.name.clone(),
                                            ))
                                        })
                                        .collect();
                                    return Ok(klio_runtime::Value::List {
                                        items: klio_runtime::ObjRef::new(items),
                                        mutable: false,
                                        enum_class: None,
                                    });
                                }
                                _ => {}
                            }
                        }
                    }
                }
            }
        }
        // PropertyRef invocation: `nameRef.get(p)` / `nameRef.call(p)`
        // reads the named property from the receiver. `hashCode`
        // and `equals` route to structural equality on the name.
        if let klio_runtime::Value::PropertyRef { name: pname } = receiver {
            match (name, args.len()) {
                ("get" | "call" | "invoke", 1) => {
                    return self.get_field(&args[0], pname);
                }
                ("hashCode", 0) => {
                    return Ok(klio_runtime::Value::new_int(
                        value_structural_hash(receiver) as i64,
                    ));
                }
                ("equals", 1) => {
                    return Ok(klio_runtime::Value::Bool(
                        klio_runtime::Value::structural_eq(receiver, &args[0]),
                    ));
                }
                ("toString", 0) => {
                    return Ok(klio_runtime::Value::String(Arc::new(format!(
                        "property {pname}"
                    ))));
                }
                _ => {}
            }
        }
        // Enum entries compare by ordinal natively. `Color.RED <
        // Color.BLUE` lowers as `RED.compareTo(BLUE)`.
        if name == "compareTo" && args.len() == 1 {
            if let (
                klio_runtime::Value::Instance(a),
                klio_runtime::Value::Instance(b),
            ) = (receiver, &args[0])
            {
                let cls = a.borrow().class.clone();
                if cls.is_enum {
                    let ord_a = a
                        .borrow()
                        .get("ordinal")
                        .and_then(|v| v.as_i64())
                        .unwrap_or(0);
                    let ord_b = b
                        .borrow()
                        .get("ordinal")
                        .and_then(|v| v.as_i64())
                        .unwrap_or(0);
                    return Ok(klio_runtime::Value::new_int(ord_a - ord_b));
                }
            }
        }
        // Natural-order sort on a list of user `Value::Instance` —
        // dispatch each pair through `compareTo` so user-overridden
        // ordering wins. Stdlib's `compare_values` rejects Instance
        // pairs; this branch wins before the stdlib probe.
        if (name == "sorted" || name == "sortedDescending") && args.is_empty() {
            if let klio_runtime::Value::List { items, .. } = receiver {
                let snap: Vec<klio_runtime::Value> = items.borrow().clone();
                if snap.iter().any(|v| matches!(v, klio_runtime::Value::Instance(_))) {
                    let mut sorted = snap;
                    let descending = name == "sortedDescending";
                    for i in 1..sorted.len() {
                        let mut j = i;
                        while j > 0 {
                            let a = sorted[j - 1].clone();
                            let b = sorted[j].clone();
                            let cmp_val = self.call_member(&a, "compareTo", &[b])?;
                            let n = cmp_val.as_i64().unwrap_or(0);
                            let greater = if descending { n < 0 } else { n > 0 };
                            if greater {
                                sorted.swap(j - 1, j);
                                j -= 1;
                            } else {
                                break;
                            }
                        }
                    }
                    return Ok(klio_runtime::Value::List {
                        items: klio_runtime::ObjRef::new(sorted),
                        mutable: false,
                        enum_class: None,
                    });
                }
            }
        }
        // Comparator chaining + reversal + compare.
        if let klio_runtime::Value::Comparator { steps, descending } = receiver {
            if name == "compare" && args.len() == 2 {
                let a = args[0].clone();
                let b = args[1].clone();
                let mut ord = std::cmp::Ordering::Equal;
                if steps.is_empty() {
                    ord = klio_stdlib::compare_values(&a, &b)
                        .map_err(|e| klio_ir::eval::EvalError::Type(format!("{e}")))?;
                } else {
                    for (sel, step_desc) in steps.iter() {
                        // Two shapes are supported:
                        //   key-selector lambda: `{ x -> key }` —
                        //     invoke with one arg per side, compare
                        //     the resulting keys.
                        //   comparator lambda: `{ a, b -> n }` —
                        //     invoke once with both values; the
                        //     return value is the comparison int.
                        let n_params = match sel {
                            klio_runtime::Value::IrClosure { id, .. } => self
                                .closures
                                .get(*id as usize)
                                .map(|c| c.n_params)
                                .unwrap_or(1),
                            _ => 1,
                        };
                        let o = if n_params >= 2 {
                            let r = self
                                .call_value(sel, &[a.clone(), b.clone()])?;
                            let n = r.as_i64().unwrap_or(0);
                            if n < 0 {
                                std::cmp::Ordering::Less
                            } else if n > 0 {
                                std::cmp::Ordering::Greater
                            } else {
                                std::cmp::Ordering::Equal
                            }
                        } else {
                            let ka =
                                self.call_value(sel, std::slice::from_ref(&a))?;
                            let kb =
                                self.call_value(sel, std::slice::from_ref(&b))?;
                            klio_stdlib::compare_values(&ka, &kb)
                                .map_err(|e| klio_ir::eval::EvalError::Type(format!("{e}")))?
                        };
                        let flipped = if *step_desc { o.reverse() } else { o };
                        if flipped != std::cmp::Ordering::Equal {
                            ord = flipped;
                            break;
                        }
                    }
                }
                if *descending {
                    ord = ord.reverse();
                }
                let n: i64 = match ord {
                    std::cmp::Ordering::Less => -1,
                    std::cmp::Ordering::Equal => 0,
                    std::cmp::Ordering::Greater => 1,
                };
                return Ok(klio_runtime::Value::new_int(n));
            }
            match name {
                "thenBy" | "thenByDescending" if args.len() == 1 => {
                    let mut chain: Vec<(klio_runtime::Value, bool)> = (**steps).clone();
                    chain.push((args[0].clone(), name == "thenByDescending"));
                    return Ok(klio_runtime::Value::Comparator {
                        steps: Arc::new(chain),
                        descending: *descending,
                    });
                }
                "then" | "thenComparing" | "thenDescending" | "thenComparator" if args.len() == 1 => {
                    let invert = name == "thenDescending";
                    match &args[0] {
                        klio_runtime::Value::Comparator { steps: other_steps, descending: other_desc } => {
                            let mut chain: Vec<(klio_runtime::Value, bool)> = (**steps).clone();
                            for (sel, d) in other_steps.iter() {
                                chain.push((sel.clone(), *d ^ other_desc ^ invert));
                            }
                            return Ok(klio_runtime::Value::Comparator {
                                steps: Arc::new(chain),
                                descending: *descending,
                            });
                        }
                        klio_runtime::Value::Lambda { .. }
                        | klio_runtime::Value::IrClosure { .. } => {
                            let mut chain: Vec<(klio_runtime::Value, bool)> = (**steps).clone();
                            chain.push((args[0].clone(), invert));
                            return Ok(klio_runtime::Value::Comparator {
                                steps: Arc::new(chain),
                                descending: *descending,
                            });
                        }
                        _ => {}
                    }
                }
                "reversed" if args.is_empty() => {
                    return Ok(klio_runtime::Value::Comparator {
                        steps: Arc::clone(steps),
                        descending: !*descending,
                    });
                }
                _ => {}
            }
        }
        // `r.contains(x)` on a Range — covers Int/Long/Char ranges
        // used in `when` arms and `x in 'a'..'z'` checks.
        if name == "contains" && args.len() == 1 {
            if let klio_runtime::Value::Range { start, end, step, kind } = receiver {
                let inside = match (&args[0], kind) {
                    (klio_runtime::Value::Char(c), klio_runtime::RangeKind::Char) => {
                        let cv = *c as i64;
                        cv >= *start && cv <= *end && (cv - *start) % step == 0
                    }
                    _ => {
                        if let Some(v) = args[0].as_i64() {
                            v >= *start && v <= *end && (v - *start) % step == 0
                        } else {
                            false
                        }
                    }
                };
                return Ok(klio_runtime::Value::Bool(inside));
            }
        }
        // `m.contains(key)` / `m.containsKey(key)` / `m.containsValue(v)` for Map.
        if let klio_runtime::Value::Map { entries, .. } = receiver {
            match (name, args.len()) {
                ("contains" | "containsKey", 1) => {
                    let needle = &args[0];
                    let has = entries
                        .borrow()
                        .iter()
                        .any(|(k, _)| klio_runtime::Value::structural_eq(k, needle));
                    return Ok(klio_runtime::Value::Bool(has));
                }
                ("containsValue", 1) => {
                    let needle = &args[0];
                    let has = entries
                        .borrow()
                        .iter()
                        .any(|(_, v)| klio_runtime::Value::structural_eq(v, needle));
                    return Ok(klio_runtime::Value::Bool(has));
                }
                _ => {}
            }
        }
        // Generic Array → List conversion + a couple of frequently
        // used array-shape methods.
        if let klio_runtime::Value::Array { items, .. } = receiver {
            match (name, args.len()) {
                ("toList", 0) => {
                    let v: Vec<klio_runtime::Value> = items.borrow().clone();
                    return Ok(klio_runtime::Value::List {
                        items: klio_runtime::ObjRef::new(v),
                        mutable: false,
                        enum_class: None,
                    });
                }
                ("toMutableList", 0) => {
                    let v: Vec<klio_runtime::Value> = items.borrow().clone();
                    return Ok(klio_runtime::Value::List {
                        items: klio_runtime::ObjRef::new(v),
                        mutable: true,
                        enum_class: None,
                    });
                }
                ("asList", 0) => {
                    let v: Vec<klio_runtime::Value> = items.borrow().clone();
                    return Ok(klio_runtime::Value::List {
                        items: klio_runtime::ObjRef::new(v),
                        mutable: false,
                        enum_class: None,
                    });
                }
                ("toSet", 0) => {
                    let v: Vec<klio_runtime::Value> = items.borrow().clone();
                    return Ok(klio_runtime::Value::Set {
                        items: klio_runtime::ObjRef::new(v),
                        mutable: false,
                    });
                }
                // `CharArray.concatToString()` /
                // `concatToString(startIndex, endIndex)` — join the
                // Char elements (used by kotlinx-io's
                // commonToUtf8String).
                ("concatToString", 0) | ("concatToString", 2) => {
                    let chars = items.borrow();
                    let (start, end) = if args.len() == 2 {
                        let s = args[0].as_i64().unwrap_or(0).max(0) as usize;
                        let e = args[1]
                            .as_i64()
                            .unwrap_or(chars.len() as i64)
                            .max(0) as usize;
                        (s.min(chars.len()), e.min(chars.len()))
                    } else {
                        (0, chars.len())
                    };
                    let s: String = chars[start..end.max(start)]
                        .iter()
                        .filter_map(|v| match v {
                            klio_runtime::Value::Char(c) => Some(*c),
                            _ => None,
                        })
                        .collect();
                    return Ok(klio_runtime::Value::String(Arc::new(s)));
                }
                _ => {}
            }
        }
        // Indexed get/set on Array variants.
        if name == "get" && args.len() == 1 {
            if let klio_runtime::Value::Array { items, .. } = receiver {
                if let Some(idx) = args[0].as_i64() {
                    if let Some(v) = items.borrow().get(idx as usize).cloned() {
                        return Ok(v);
                    }
                }
            }
        }
        if name == "set" && args.len() == 2 {
            if let klio_runtime::Value::Array { items, .. } = receiver {
                if let Some(idx) = args[0].as_i64() {
                    if let Some(slot) = items.borrow_mut().get_mut(idx as usize) {
                        *slot = args[1].clone();
                        return Ok(klio_runtime::Value::Unit);
                    }
                }
            }
        }
        // Built-in collection in-place mutation operators.
        match (receiver, name) {
            (klio_runtime::Value::List { items, mutable: true, .. }, "plusAssign")
                if args.len() == 1 =>
            {
                items.borrow_mut().push(args[0].clone());
                return Ok(klio_runtime::Value::Unit);
            }
            (klio_runtime::Value::List { items, mutable: true, .. }, "minusAssign")
                if args.len() == 1 =>
            {
                let mut v = items.borrow_mut();
                if let Some(pos) = v
                    .iter()
                    .position(|x| klio_runtime::Value::structural_eq(x, &args[0]))
                {
                    v.remove(pos);
                }
                return Ok(klio_runtime::Value::Unit);
            }
            (klio_runtime::Value::Set { items, mutable: true, .. }, "plusAssign")
                if args.len() == 1 =>
            {
                let mut v = items.borrow_mut();
                if !v
                    .iter()
                    .any(|x| klio_runtime::Value::structural_eq(x, &args[0]))
                {
                    v.push(args[0].clone());
                }
                return Ok(klio_runtime::Value::Unit);
            }
            (klio_runtime::Value::Set { items, mutable: true, .. }, "minusAssign")
                if args.len() == 1 =>
            {
                let mut v = items.borrow_mut();
                if let Some(pos) = v
                    .iter()
                    .position(|x| klio_runtime::Value::structural_eq(x, &args[0]))
                {
                    v.remove(pos);
                }
                return Ok(klio_runtime::Value::Unit);
            }
            (klio_runtime::Value::Map { entries, mutable: true, .. }, "plusAssign")
                if args.len() == 1 =>
            {
                if let klio_runtime::Value::Pair(k, val) = &args[0] {
                    let mut e = entries.borrow_mut();
                    if let Some(slot) = e
                        .iter_mut()
                        .find(|(ek, _)| klio_runtime::Value::structural_eq(ek, k))
                    {
                        slot.1 = (**val).clone();
                    } else {
                        e.push(((**k).clone(), (**val).clone()));
                    }
                }
                return Ok(klio_runtime::Value::Unit);
            }
            _ => {}
        }
        // Pair / Triple / MapEntry component / first / second / etc.
        match (receiver, name) {
            (klio_runtime::Value::Pair(a, _), "component1" | "first") => return Ok((**a).clone()),
            (klio_runtime::Value::Pair(_, b), "component2" | "second") => return Ok((**b).clone()),
            (klio_runtime::Value::Triple(a, _, _), "component1" | "first") => return Ok((**a).clone()),
            (klio_runtime::Value::Triple(_, b, _), "component2" | "second") => return Ok((**b).clone()),
            (klio_runtime::Value::Triple(_, _, c), "component3" | "third") => return Ok((**c).clone()),
            (klio_runtime::Value::MapEntry { key, .. }, "component1" | "key") => return Ok((**key).clone()),
            (klio_runtime::Value::MapEntry { value, .. }, "component2" | "value") => return Ok((**value).clone()),
            _ => {}
        }
        if let klio_runtime::Value::Iterator { items, pos, .. } = receiver {
            match name {
                "hasNext" if args.is_empty() => {
                    return Ok(klio_runtime::Value::Bool(*pos.borrow() < items.borrow().len()));
                }
                "next" | "nextInt" | "nextLong" | "nextChar" | "nextByte"
                | "nextShort" | "nextDouble" | "nextFloat" | "nextBoolean"
                    if args.is_empty() =>
                {
                    let p = *pos.borrow();
                    let v = items.borrow().get(p).cloned().ok_or_else(|| {
                        klio_ir::eval::EvalError::Throw(klio_runtime::Value::Exception {
                            fqn: Arc::new("kotlin.NoSuchElementException".to_string()),
                            message: Some(Arc::new("iterator exhausted".into())),
                            cause: None,
                        })
                    })?;
                    *pos.borrow_mut() = p + 1;
                    return Ok(v);
                }
                _ => {}
            }
        }
        // Data-class auto members (componentN, equals, hashCode,
        // toString, copy) — synthesised structurally from the
        // primary-ctor fields. Resolves before the IR method walk
        // so user-declared override-method bodies still take
        // precedence (we check find_method first).
        if let klio_runtime::Value::Instance(inst) = receiver {
            let is_data = inst.borrow().class.is_data;
            // A `value class` gets the same compiler-synthesised
            // `equals`/`hashCode`/`toString` over its single backing
            // property as a data class (but no `copy`).
            let is_value = inst.borrow().class.is_value;
            let has_user_override = {
                let start_name = inst.borrow().class.name.clone();
                let mut queue: std::collections::VecDeque<String> =
                    std::collections::VecDeque::new();
                let mut seen: std::collections::HashSet<String> =
                    std::collections::HashSet::new();
                queue.push_back(start_name);
                let mut found = false;
                while let Some(cur) = queue.pop_front() {
                    if !seen.insert(cur.clone()) {
                        continue;
                    }
                    if let Some(ir_class) =
                        self.module.classes.iter().find(|c| c.name == cur)
                    {
                        for fid in &ir_class.methods {
                            if let Some(f) = self.module.funcs.get(fid.0 as usize) {
                                if f.name == name {
                                    found = true;
                                    break;
                                }
                            }
                        }
                    }
                    if found {
                        break;
                    }
                    if let Some(def) = self.classes.borrow().get(&cur).cloned() {
                        for sup in &def.supertype_names {
                            queue.push_back(sup.clone());
                        }
                    }
                }
                found
            };
            let is_object = inst.borrow().class.is_object;
            if is_data && is_object && !has_user_override && name == "toString" {
                // `data object` renders as the bare class name even
                // though `is_data` is set. Short-circuit before the
                // structural data-class shape below.
                let i = inst.borrow();
                return Ok(klio_runtime::Value::String(Arc::new(i.class.name.clone())));
            }
            if (is_data || is_value) && !has_user_override && args.is_empty() {
                if is_data {
                  if let Some(rest) = name.strip_prefix("component") {
                    if let Ok(n) = rest.parse::<usize>() {
                        if n >= 1 {
                            let i = inst.borrow();
                            if let Some(p) = i.class.primary_params.get(n - 1) {
                                if let Some(v) = i.get(&p.name) {
                                    return Ok(v);
                                }
                            }
                        }
                    }
                  }
                }
                if name == "toString" {
                    let i = inst.borrow();
                    let mut s = String::new();
                    s.push_str(&i.class.name);
                    s.push('(');
                    for (idx, p) in i.class.primary_params.iter().enumerate() {
                        if idx > 0 {
                            s.push_str(", ");
                        }
                        s.push_str(&p.name);
                        s.push('=');
                        let v = i.get(&p.name).unwrap_or(klio_runtime::Value::Null);
                        s.push_str(&format!("{v}"));
                    }
                    s.push(')');
                    return Ok(klio_runtime::Value::String(Arc::new(s)));
                }
                if name == "hashCode" {
                    let i = inst.borrow();
                    let mut h: i32 = 0;
                    for p in &i.class.primary_params {
                        let v = i.get(&p.name).unwrap_or(klio_runtime::Value::Null);
                        h = h.wrapping_mul(31).wrapping_add(value_structural_hash(&v));
                    }
                    return Ok(klio_runtime::Value::new_int(h as i64));
                }
            }
            if is_data && !has_user_override && name == "copy" {
                let class_def = inst.borrow().class.clone();
                let n_params = class_def.primary_params.len();
                if args.len() <= n_params {
                    let mut new_args: Vec<klio_runtime::Value> = Vec::with_capacity(n_params);
                    let i = inst.borrow();
                    for (idx, p) in class_def.primary_params.iter().enumerate() {
                        let v = if idx < args.len() {
                            args[idx].clone()
                        } else {
                            i.get(&p.name).unwrap_or(klio_runtime::Value::Null)
                        };
                        new_args.push(v);
                    }
                    drop(i);
                    if let Some(class_id) = self.module.class_id(&class_def.name) {
                        return <VmHost as klio_ir::eval::Host>::new_instance(self, class_id, &new_args);
                    }
                }
            }
            if (is_data || is_value) && !has_user_override && args.len() == 1 && name == "equals" {
                let i = inst.borrow();
                let class_fqn = i.class.fqn.clone();
                let same = matches!(&args[0],
                    klio_runtime::Value::Instance(o) if o.borrow().class.fqn == class_fqn);
                if !same {
                    return Ok(klio_runtime::Value::Bool(false));
                }
                let klio_runtime::Value::Instance(o) = &args[0] else { unreachable!() };
                let names: Vec<String> = i.class.primary_params.iter().map(|p| p.name.clone()).collect();
                drop(i);
                let lhs = inst.borrow();
                let rhs = o.borrow();
                for n in &names {
                    let a = lhs.get(n).unwrap_or(klio_runtime::Value::Null);
                    let b = rhs.get(n).unwrap_or(klio_runtime::Value::Null);
                    if !klio_runtime::Value::structural_eq(&a, &b) {
                        return Ok(klio_runtime::Value::Bool(false));
                    }
                }
                return Ok(klio_runtime::Value::Bool(true));
            }
        }
        // Runtime-lowered method dispatch: anonymous-object instances
        // (class name prefixed `$anon$`) and local classes registered
        // via Inst::RegisterClass both stash methods in anon_methods.
        if let klio_runtime::Value::Instance(inst) = receiver {
            let class_name = inst.borrow().class.name.clone();
            // Anon-object / local-class methods are stored under both
            // an arity-tagged key (`name#argc`) and the plain name.
            // Prefer the arity match so overloaded members (e.g.
            // SegmentWriteContext.setUnchecked with 3/4/5/6 args)
            // dispatch correctly; fall back to the plain name.
            let arity_name = format!("{name}#{}", args.len());
            let key = (class_name, name.to_string());
            // Enum entries tagged with __enum_entry_class__ route
            // method calls to the entry-specific override class
            // first, before falling back to the enum class's own
            // members.
            let entry_tag = inst.borrow().get("__enum_entry_class__");
            if let Some(klio_runtime::Value::String(tag)) = entry_tag {
                let entry_arity_key = ((*tag).clone(), arity_name.clone());
                let entry_key = ((*tag).clone(), name.to_string());
                let entry_method = {
                    let tbl = self.anon_methods.borrow();
                    tbl.get(&entry_arity_key)
                        .or_else(|| tbl.get(&entry_key))
                        .cloned()
                };
                if let Some((module_rc, fid, _)) = entry_method {
                    let func = module_rc
                        .funcs
                        .get(fid.0 as usize)
                        .cloned()
                        .ok_or_else(|| {
                            klio_ir::eval::EvalError::Type(format!(
                                "enum-entry method FuncId {} out of range",
                                fid.0
                            ))
                        })?;
                    let mut all: Vec<klio_runtime::Value> =
                        Vec::with_capacity(args.len() + 1);
                    all.push(receiver.clone());
                    all.extend_from_slice(args);
                    let all = pack_vararg_args(&func, all);
                    return klio_ir::eval::eval_with(&module_rc, &func, all, self);
                }
            }
            let entry = {
                let tbl = self.anon_methods.borrow();
                let arity_key = (key.0.clone(), arity_name.clone());
                tbl.get(&arity_key).or_else(|| tbl.get(&key)).cloned()
            };
            if let Some((module_rc, fid, captures)) = entry {
                let func = module_rc
                    .funcs
                    .get(fid.0 as usize)
                    .cloned()
                    .ok_or_else(|| {
                        klio_ir::eval::EvalError::Type(format!(
                            "anon method FuncId {} out of range",
                            fid.0
                        ))
                    })?;
                let mut all: Vec<klio_runtime::Value> =
                    Vec::with_capacity(args.len() + 1);
                all.push(receiver.clone());
                all.extend_from_slice(args);
                let all = pack_vararg_args(&func, all);
                // Layer captured outer-env names onto globals for the
                // duration of the method call so the body's
                // bare-name globals resolve to the captured values.
                let prev = self.globals.clone();
                if !captures.is_empty() {
                    let scoped = klio_runtime::ObjRef::new(
                        klio_runtime::Env::with_parent(prev.clone()),
                    );
                    for (n, v) in &captures {
                        scoped.borrow_mut().define(n.clone(), v.clone());
                    }
                    self.globals = scoped;
                }
                let result = klio_ir::eval::eval_with(&module_rc, &func, all, self);
                self.globals = prev;
                return result;
            }
        }
        if let klio_runtime::Value::Instance(inst) = receiver {
            // Walk the IR class + its supertypes breadth-first
            // looking for a method matching `name`. The receiver's
            // runtime ClassDef.supertype_names provides the chain;
            // each name maps back to a klio_ir::Class via the
            // module's class_index.
            let class_name = inst.borrow().class.name.clone();
            let mut queue: std::collections::VecDeque<String> =
                std::collections::VecDeque::new();
            let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
            queue.push_back(class_name);
            while let Some(cur_name) = queue.pop_front() {
                if !seen.insert(cur_name.clone()) {
                    continue;
                }
                let ir_class = self
                    .module
                    .classes
                    .iter()
                    .find(|c| c.name == cur_name)
                    .cloned();
                if let Some(ir_class) = ir_class {
                    // Gather every method named `name` so we can pick
                    // an overload by scoring runtime arg types.
                    let candidates: Vec<klio_ir::Func> = ir_class
                        .methods
                        .iter()
                        .filter_map(|fid| self.module.funcs.get(fid.0 as usize).cloned())
                        .filter(|f| f.name == name)
                        .collect();
                    if let Some(f) = self.pick_method_overload(&candidates, args) {
                        let mut all_args: Vec<klio_runtime::Value> =
                            Vec::with_capacity(args.len() + 1);
                        all_args.push(receiver.clone());
                        all_args.extend_from_slice(args);
                        // Fill omitted trailing params from the
                        // method's recorded default-arg thunks, then
                        // collect a trailing `vararg`. The implicit
                        // `this` is already in `all_args`, so
                        // positions align with the lowered param list.
                        let module = Arc::clone(&self.module);
                        let defaults =
                            self.prog.func_defaults.get(&f.id).cloned();
                        let all_args = if defaults.is_some()
                            && all_args.len() < f.params.len()
                        {
                            pad_args_with_defaults(
                                &module,
                                f.params.len(),
                                &all_args,
                                defaults.as_ref(),
                                self,
                            )?
                        } else {
                            all_args
                        };
                        let all_args = pack_vararg_args(&f, all_args);
                        return klio_ir::eval::eval_with(&module, &f, all_args, self);
                    }
                }
                // Push runtime supertype names; the Vm's
                // class_table maps each name back to a ClassDef
                // whose supertype_names continues the walk.
                if let Some(def) = self.classes.borrow().get(&cur_name).cloned() {
                    for sup in &def.supertype_names {
                        queue.push_back(sup.clone());
                    }
                }
            }
        }
        // Generic Any.toString / equals / hashCode fallback —
        // structural where appropriate, reference-based for opaque
        // values. Runs after the user-method walk so override
        // bodies still win.
        if let klio_runtime::Value::Instance(inst) = receiver {
            if args.is_empty() && name == "toString" {
                let i = inst.borrow();
                // Enum entries render as the bare entry name unless
                // the user override fired (the user-method walk
                // above runs first and wins).
                if i.class.is_enum {
                    if let Some(klio_runtime::Value::String(s)) = i.get("name") {
                        return Ok(klio_runtime::Value::String(Arc::clone(&s)));
                    }
                }
                // Singleton `object` decls — including `data
                // object` — render as the bare class name.
                if i.class.is_object {
                    return Ok(klio_runtime::Value::String(Arc::new(
                        i.class.name.clone(),
                    )));
                }
                // Data classes render structurally `Name(p1=v1, …)`.
                if i.class.is_data {
                    let mut s = String::new();
                    s.push_str(&i.class.name);
                    s.push('(');
                    for (idx, p) in i.class.primary_params.iter().enumerate() {
                        if idx > 0 {
                            s.push_str(", ");
                        }
                        s.push_str(&p.name);
                        s.push('=');
                        let v = i.get(&p.name).unwrap_or(klio_runtime::Value::Null);
                        s.push_str(&format!("{v}"));
                    }
                    s.push(')');
                    return Ok(klio_runtime::Value::String(Arc::new(s)));
                }
                return Ok(klio_runtime::Value::String(Arc::new(format!(
                    "{}@{:x}",
                    i.class.fqn, i.identity
                ))));
            }
            if args.is_empty() && name == "hashCode" {
                let i = inst.borrow();
                return Ok(klio_runtime::Value::new_int(i.identity as i64));
            }
            if args.len() == 1 && name == "equals" {
                if let klio_runtime::Value::Instance(o) = &args[0] {
                    let same = klio_runtime::ObjRef::ptr_eq(inst, o);
                    return Ok(klio_runtime::Value::Bool(same));
                }
                return Ok(klio_runtime::Value::Bool(false));
            }
        }
        // Stdlib member dispatch: probe the receiver's type FQN
        // for a `<typeFqn>.<name>` intrinsic, then for the common
        // package-extension fallbacks. For 0-arg call shapes the
        // type-prefixed form (property read) wins; for n-arg call
        // shapes the package-prefixed form (extension fn) wins so
        // `1..10 step 2` resolves to `kotlin.ranges.step(...)`
        // rather than the property `IntRange.step`.
        let type_fqn = receiver.type_fqn();
        let probes: Vec<String> = if args.is_empty() {
            vec![
                format!("{type_fqn}.{name}"),
                format!("kotlin.collections.{name}"),
                format!("kotlin.text.{name}"),
                format!("kotlin.ranges.{name}"),
                format!("kotlin.{name}"),
            ]
        } else {
            vec![
                format!("kotlin.ranges.{name}"),
                format!("kotlin.collections.{name}"),
                format!("kotlin.text.{name}"),
                format!("{type_fqn}.{name}"),
                format!("kotlin.{name}"),
            ]
        };
        // A top-level stdlib function (`listOf`, `mutableListOf`,
        // `minOf`, `println`, …) is never a member or extension of an
        // arbitrary receiver. Skip the speculative receiver-prepend
        // probe for these so a bare call inside a receiver-typed
        // lambda (e.g. `runBlocking { listOf(1, 2) }`) resolves to
        // the top-level function instead of `receiver.listOf(...)`.
        if !klio_stdlib::is_toplevel_function(name) {
            for probe in &probes {
                if let Some(func) = self.lookup_intrinsic(probe) {
                    let mut all_args: Vec<klio_runtime::Value> =
                        Vec::with_capacity(args.len() + 1);
                    all_args.push(receiver.clone());
                    all_args.extend_from_slice(args);
                    return self.dispatch_intrinsic(func, &all_args);
                }
            }
        }
        // `IntRange`/`LongRange`/`CharRange` is `Iterable`. By here
        // the range-specific intrinsics (`step`, `contains`,
        // `reversed`, `toList`, …) have had their probe; anything
        // left is a generic Iterable op, so materialise to a List
        // and re-dispatch *before* the user-extension fallback. This
        // makes a range take the exact same path as a List (so
        // `(0..3).map { }` resolves to the stdlib List.map and isn't
        // hijacked by an unrelated user `fun Tree<T>.map`).
        if let klio_runtime::Value::Range { start, end, step, kind } = receiver {
            let items = materialise_range_items(*start, *end, *step, *kind);
            let as_list = klio_runtime::Value::List {
                items: klio_runtime::ObjRef::new(items),
                mutable: false,
                enum_class: None,
            };
            return self.call_member(&as_list, name, args);
        }
        // Extension fn fallback: a user-defined `fun T.name(...)`
        // lowers as a top-level fn whose first param is the
        // receiver. Look it up by simple name and dispatch with
        // receiver prepended.
        {
            // Gather every top-level fn named `name` with the right
            // arity for an extension call (receiver + args). Pick the
            // candidate whose first (receiver) parameter type best
            // matches the actual receiver, so `bytes.encodeBase64()`
            // and `byteString.encodeBase64()` resolve to their own
            // overloads rather than the first-declared one.
            let want = args.len() + 1;
            // Accept an extension whose declared arity is >= the
            // supplied (receiver + args) count when every trailing
            // unsupplied parameter has a default — kotlinx-io's
            // `fun Sink.writeString(s, startIndex = 0, endIndex =
            // s.length)` is called as `sink.writeString("x")`.
            let candidates: Vec<(klio_ir::FuncId, klio_ir::Func)> = self
                .module
                .func_index
                .iter()
                .filter(|(n, _)| n == name)
                .filter_map(|(_, fid)| {
                    self.module
                        .funcs
                        .get(fid.0 as usize)
                        .cloned()
                        .map(|f| (*fid, f))
                })
                .filter(|(_fid, f)| !f.params.is_empty() && f.params.len() >= want)
                .collect();
            let chosen = if candidates.len() <= 1 {
                candidates.into_iter().next()
            } else {
                // Score the receiver (param 0) *and* every value
                // argument against the declared parameter types, so
                // overloads that differ only in an argument type are
                // resolved correctly (`Byte.and(Int)` vs
                // `Byte.and(Long)` for `byte and 0xffL`). An exact
                // declared arity is also preferred over a
                // defaulted-tail match.
                let mut best: Option<((klio_ir::FuncId, klio_ir::Func), i32)> = None;
                for (fid, f) in candidates {
                    let mut score = self
                        .overload_score_arg(&f.params[0].ty, receiver)
                        .unwrap_or(-1);
                    for (i, a) in args.iter().enumerate() {
                        if let Some(p) = f.params.get(i + 1) {
                            score += self.overload_score_arg(&p.ty, a).unwrap_or(-1);
                        }
                    }
                    if f.params.len() == want {
                        score += 5;
                    }
                    if best.as_ref().map(|(_, s)| score > *s).unwrap_or(true) {
                        best = Some(((fid, f), score));
                    }
                }
                best.map(|(c, _)| c)
            };
            if let Some((fid, _func)) = chosen {
                let mut all: Vec<klio_runtime::Value> = Vec::with_capacity(args.len() + 1);
                all.push(receiver.clone());
                all.extend_from_slice(args);
                // call_func pads defaulted params, packs varargs and
                // honours a pack-installed binding that shadows a
                // bodyless `expect` extension.
                let module = Arc::clone(&self.module);
                return self.call_func(&module, fid, all);
            }
        }
        // Class-delegation forwarding: when the receiver instance
        // was constructed with `: I by g`, the stored
        // `__delegate__<I>` field holds the delegate; forward
        // unmatched method calls there.
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
                if let Ok(v) = self.call_member(&d, name, args) {
                    return Ok(v);
                }
            }
        }
        // Companion-method forwarding: `Foo.bar(...)` where the
        // receiver is the class itself dispatches to `bar` declared
        // in `Foo`'s companion object. Mirrors the companion-field
        // forwarding in `get_field`; needed when a top-level
        // function shares the class's name so the qualifier resolves
        // to the class value rather than the companion.
        if let klio_runtime::Value::Class(cls) = receiver {
            let simple = cls.name.rsplit('.').next().unwrap_or(&cls.name).to_string();
            let comp_name = self
                .module
                .registry
                .companion_singletons
                .get(&cls.name)
                .or_else(|| self.module.registry.companion_singletons.get(&simple))
                .cloned();
            if let Some(comp_name) = comp_name {
                let singleton = self.globals.borrow().lookup(&comp_name);
                if let Some(singleton @ klio_runtime::Value::Instance(_)) = singleton {
                    if let Ok(v) = self.call_member(&singleton, name, args) {
                        return Ok(v);
                    }
                }
            }
        }
        // Reflective `KSerializer` synthesis (the kotlinx-serialization
        // compiler-plugin replacement). `T.serializer()` /
        // `Companion.serializer()` on a `@Serializable` class with no
        // hand-written or `with=` serializer reaches here only after
        // every real dispatch (including a user-declared companion
        // `serializer()`) has missed. When the kotlinx-serialization
        // pack is loaded it registers a top-level
        // `ReflectiveKSerializer` class; build one over the target
        // class so the program gets a working serializer by
        // reflecting the primary-constructor properties.
        if name == "serializer"
            && args.is_empty()
            && matches!(
                receiver,
                klio_runtime::Value::Class(_)
                    | klio_runtime::Value::BoundInnerClass { .. }
            )
        {
            let factory = self
                .classes
                .borrow()
                .get("ReflectiveKSerializer")
                .cloned();
            if let Some(def) = factory {
                if let Some(class_id) = self.module.class_id(&def.name) {
                    let ctor_args = [receiver.clone()];
                    return <VmHost as klio_ir::eval::Host>::new_instance(
                        self, class_id, &ctor_args,
                    );
                }
            }
        }
        // Companion fallback for an instance receiver: inside a
        // class's own member body, a companion function/property is
        // in scope unqualified (`fun plus(d) = of(x + d)` where
        // `of` is on the companion). The bare call lowered as
        // `this.of(...)`; the instance has no such member, so route
        // to the class's companion singleton before failing.
        if let klio_runtime::Value::Instance(inst) = receiver {
            let mut cur = Some(inst.borrow().class.name.clone());
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
                    if let Some(singleton) = singleton {
                        if matches!(
                            singleton,
                            klio_runtime::Value::Instance(_)
                        ) {
                            if let Ok(v) =
                                self.call_member(&singleton, name, args)
                            {
                                return Ok(v);
                            }
                        }
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
        // The COROUTINE_SUSPENDED singleton has a fixed member
        // surface: it stringifies to its own name and equality is
        // identity against the sole instance.
        if matches!(receiver, klio_runtime::Value::CoroutineSuspended) {
            match name {
                "toString" => {
                    return Ok(klio_runtime::Value::String(Arc::new(
                        "COROUTINE_SUSPENDED".to_string(),
                    )))
                }
                "hashCode" => return Ok(klio_runtime::Value::Int(0)),
                "equals" => {
                    return Ok(klio_runtime::Value::Bool(matches!(
                        args.first(),
                        Some(klio_runtime::Value::CoroutineSuspended)
                    )))
                }
                _ => {}
            }
        }
        // Function-typed property invoked by name: `body()` where
        // `body: () -> T` is a (constructor) property. No method
        // `body` exists, so read the callable field and invoke it.
        if let klio_runtime::Value::Instance(inst) = receiver {
            let field = inst
                .borrow()
                .fields
                .iter()
                .find(|(n, _)| n == name)
                .map(|(_, v)| v.clone());
            if let Some(v) = field {
                if matches!(
                    v,
                    klio_runtime::Value::Lambda { .. }
                        | klio_runtime::Value::IrClosure { .. }
                        | klio_runtime::Value::Function { .. }
                        | klio_runtime::Value::BoundMethod { .. }
                        | klio_runtime::Value::Instance(_)
                ) {
                    return <Self as klio_ir::eval::Host>::call_value(self, &v, args);
                }
            }
        }
        Err(klio_ir::eval::EvalError::Unimplemented(format!(
            "Vm::call_member `{name}` on `{}`",
            receiver.type_fqn()
        )))
    }

    fn call_member_named(
        &mut self,
        receiver: &klio_runtime::Value,
        name: &str,
        args: &[klio_runtime::Value],
        arg_names: &[Option<String>],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        // data-class `copy(name = …, age = …)` — reorder named args
        // into the primary-ctor param positions, defaulting missing
        // slots to the receiver's current field values.
        if name == "copy" {
            if let klio_runtime::Value::Instance(inst) = receiver {
                let class_def = inst.borrow().class.clone();
                if class_def.is_data {
                    let n_params = class_def.primary_params.len();
                    let mut slots: Vec<Option<klio_runtime::Value>> = vec![None; n_params];
                    let mut positional_idx = 0usize;
                    for (i, a) in args.iter().enumerate() {
                        if let Some(Some(arg_name)) = arg_names.get(i) {
                            if let Some(pos) = class_def
                                .primary_params
                                .iter()
                                .position(|p| &p.name == arg_name)
                            {
                                slots[pos] = Some(a.clone());
                            }
                        } else {
                            if positional_idx < n_params {
                                slots[positional_idx] = Some(a.clone());
                            }
                            positional_idx += 1;
                        }
                    }
                    let inst_ref = inst.borrow();
                    let mut new_args: Vec<klio_runtime::Value> = Vec::with_capacity(n_params);
                    for (idx, p) in class_def.primary_params.iter().enumerate() {
                        let v = slots[idx]
                            .take()
                            .or_else(|| inst_ref.get(&p.name))
                            .unwrap_or(klio_runtime::Value::Null);
                        new_args.push(v);
                    }
                    drop(inst_ref);
                    if let Some(class_id) = self.module.class_id(&class_def.name) {
                        return <VmHost as klio_ir::eval::Host>::new_instance(
                            self, class_id, &new_args,
                        );
                    }
                }
            }
        }
        // Stdlib intrinsic dispatch with named args: reorder
        // according to the stdlib's declared param order so callers
        // can pass `padEnd(padChar = '*', length = 4)`.
        if arg_names.iter().any(|n| n.is_some()) {
            let type_fqn = receiver.type_fqn();
            let probes = [
                format!("{type_fqn}.{name}"),
                format!("kotlin.text.{name}"),
                format!("kotlin.collections.{name}"),
                format!("kotlin.{name}"),
            ];
            for probe in &probes {
                if let Some(params) = klio_stdlib::param_names(probe) {
                    let mut slots: Vec<Option<klio_runtime::Value>> =
                        vec![None; params.len()];
                    // 1. Bind every named argument to its slot.
                    let mut positionals: Vec<klio_runtime::Value> = Vec::new();
                    for (i, a) in args.iter().enumerate() {
                        if let Some(Some(arg_name)) = arg_names.get(i) {
                            if let Some(pos) =
                                params.iter().position(|p| *p == arg_name.as_str())
                            {
                                slots[pos] = Some(a.clone());
                            }
                        } else {
                            positionals.push(a.clone());
                        }
                    }
                    // 2. A trailing lambda binds to the last
                    //    parameter (Kotlin's trailing-lambda rule:
                    //    `joinToString(separator = "; ") { … }` puts
                    //    the transform in `transform`, not slot 0).
                    if matches!(
                        positionals.last(),
                        Some(klio_runtime::Value::IrClosure { .. })
                            | Some(klio_runtime::Value::Lambda { .. })
                    ) && !params.is_empty()
                        && slots[params.len() - 1].is_none()
                    {
                        slots[params.len() - 1] = positionals.pop();
                    }
                    // 3. Remaining positionals fill empty slots
                    //    left-to-right (skipping named-filled ones).
                    let mut pit = positionals.into_iter();
                    for slot in slots.iter_mut() {
                        if slot.is_none() {
                            match pit.next() {
                                Some(v) => *slot = Some(v),
                                None => break,
                            }
                        }
                    }
                    let mut reordered: Vec<klio_runtime::Value> = slots
                        .into_iter()
                        .map(|s| s.unwrap_or(klio_runtime::Value::Null))
                        .collect();
                    while matches!(
                        reordered.last(),
                        Some(klio_runtime::Value::Null)
                    ) {
                        reordered.pop();
                    }
                    if let Some(func) = self.lookup_intrinsic(probe) {
                        let mut all_args: Vec<klio_runtime::Value> =
                            Vec::with_capacity(reordered.len() + 1);
                        all_args.push(receiver.clone());
                        all_args.extend(reordered);
                        return self.dispatch_intrinsic(func, &all_args);
                    }
                    break;
                }
            }
        }
        self.call_member(receiver, name, args)
    }

    fn new_instance(
        &mut self,
        class: klio_ir::ClassId,
        args: &[klio_runtime::Value],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        let ir_class = self.module.classes.get(class.0 as usize).ok_or_else(|| {
            klio_ir::eval::EvalError::Type(format!(
                "Vm::new_instance: ClassId {} not found in module",
                class.0
            ))
        })?;
        let class_def = self.classes.borrow().get(&ir_class.name).cloned().ok_or_else(|| {
            klio_ir::eval::EvalError::Unimplemented(format!(
                "Vm::new_instance: no runtime ClassDef registered for `{}`",
                ir_class.name
            ))
        })?;
        if class_def.is_abstract {
            return Err(klio_ir::eval::EvalError::Throw(klio_runtime::Value::Exception {
                fqn: std::sync::Arc::new("kotlin.InstantiationError".to_string()),
                message: Some(std::sync::Arc::new(format!(
                    "Cannot create an instance of an abstract class: {}",
                    class_def.name
                ))),
                cause: None,
            }));
        }
        if class_def.is_interface {
            // SAM conversion: `FunInterface(lambda)` direct-call
            // path wraps the callable in a synthetic instance whose
            // `__sam_target__` field captures the lambda; method
            // calls on the result invoke the captured callable.
            if class_def.is_fun_interface && args.len() == 1 {
                let identity = self.instance_id_counter.fetch_add(1, AtomicOrdering::Relaxed) + 1;
                let inst = klio_runtime::ObjRef::new(klio_runtime::InstanceData {
                    class: Arc::clone(&class_def),
                    fields: vec![("__sam_target__".to_string(), args[0].clone())],
                    outer: None,
                    identity,
                    native_state: None,
                });
                return Ok(klio_runtime::Value::Instance(inst));
            }
            return Err(klio_ir::eval::EvalError::Throw(klio_runtime::Value::Exception {
                fqn: std::sync::Arc::new("kotlin.InstantiationError".to_string()),
                message: Some(std::sync::Arc::new(format!(
                    "Cannot create an instance of an interface: {}",
                    class_def.name
                ))),
                cause: None,
            }));
        }
        // Secondary-ctor dispatch: when the supplied arg count
        // doesn't match the primary signature, look for a
        // secondary ctor with the matching arity. Evaluate its
        // delegation arg thunks, recurse for `: this(...)`, then
        // run the optional body block.
        let n_primary = class_def.primary_params.len();
        // A class with no primary constructor (e.g. kotlinx-io's
        // `Segment`, all `private constructor(...)`) initialises its
        // fields only in a secondary constructor body. When the arg
        // count happens to equal the (empty) primary's, dispatch must
        // still route to the matching secondary so its body runs —
        // otherwise the instance is left with uninitialised fields.
        let zero_primary_secondary = n_primary == 0
            && self.prog
                .secondary_ctors
                .get(&class_def.name)
                .map_or(false, |v| v.iter().any(|e| e.param_count == args.len()));
        let shell_guarded = with_ctor_guard(|g| g.borrow().iter().any(|n| n == &class_def.name));
        if !shell_guarded && (args.len() != n_primary || zero_primary_secondary) {
            let entries = self.prog
                .secondary_ctors
                .get(&class_def.name)
                .cloned()
                .unwrap_or_default();
            if let Some(entry) = entries.iter().find(|e| e.param_count == args.len()) {
                let module = Arc::clone(&self.module);
                let mut target_args: Vec<klio_runtime::Value> =
                    Vec::with_capacity(entry.delegation_arg_thunks.len());
                for fid in &entry.delegation_arg_thunks {
                    let func = module
                        .funcs
                        .get(fid.0 as usize)
                        .cloned()
                        .ok_or_else(|| {
                            klio_ir::eval::EvalError::Type(format!(
                                "secondary ctor arg FuncId {} out of range",
                                fid.0
                            ))
                        })?;
                    let v = klio_ir::eval::eval_with(
                        &module,
                        &func,
                        args.to_vec(),
                        self,
                    )?;
                    target_args.push(v);
                }
                // For `: this(...)` recurse via new_instance with
                // the resolved args. For `: super(...)`, allocate
                // the leaf class shell directly and populate the
                // parent's primary-param fields from the resolved
                // args; the leaf's body props + init blocks run
                // through the normal path below by falling through
                // to the primary-ctor path with empty args.
                let inst_v = if entry.is_super {
                    let parent_def = class_def
                        .parent
                        .borrow()
                        .clone()
                        .or_else(|| {
                            class_def
                                .supertype_names
                                .first()
                                .and_then(|n| self.classes.borrow().get(n).cloned())
                        });
                    if let Some(pdef) = parent_def {
                        let leaf = <Self as klio_ir::eval::Host>::new_instance(
                            self,
                            class,
                            &[],
                        )?;
                        if let klio_runtime::Value::Instance(leaf_inst) = &leaf {
                            for (p, value) in pdef.primary_params.iter().zip(target_args.iter()) {
                                if p.property.is_some() {
                                    let mut i = leaf_inst.borrow_mut();
                                    i.fields.retain(|(n, _)| n != &p.name);
                                    i.fields.push((p.name.clone(), value.clone()));
                                }
                            }
                        }
                        leaf
                    } else {
                        // No user ClassDef for the parent — it's a
                        // built-in. For the Throwable hierarchy the
                        // `super(...)` args are the conventional
                        // `(message, cause)` pair, so allocate the
                        // leaf shell and bind those fields directly
                        // (mirrors the primary-ctor Throwable path).
                        // This is what makes `expect open class
                        // IOException : Exception { constructor(...) }`
                        // and friends usable.
                        let parent_name = class_def
                            .supertype_names
                            .first()
                            .cloned()
                            .unwrap_or_default();
                        let is_throwable_name = matches!(
                            parent_name.as_str(),
                            "Throwable"
                                | "Exception"
                                | "RuntimeException"
                                | "Error"
                                | "IOException"
                                | "EOFException"
                                | "IllegalArgumentException"
                                | "IllegalStateException"
                                | "IndexOutOfBoundsException"
                                | "NullPointerException"
                                | "ClassCastException"
                                | "ArithmeticException"
                                | "NumberFormatException"
                                | "NoSuchElementException"
                                | "ConcurrentModificationException"
                                | "UnsupportedOperationException"
                        );
                        if !is_throwable_name {
                            return Err(klio_ir::eval::EvalError::Unimplemented(format!(
                                "Vm::new_instance: secondary ctor super-delegation for `{}` (no parent class def)",
                                class_def.name
                            )));
                        }
                        let leaf = <Self as klio_ir::eval::Host>::new_instance(
                            self,
                            class,
                            &[],
                        )?;
                        if let klio_runtime::Value::Instance(leaf_inst) = &leaf {
                            let mut i = leaf_inst.borrow_mut();
                            // `super(message)` / `super(cause)` /
                            // `super(message, cause)`: a lone
                            // Throwable arg is the cause, a lone
                            // String/null is the message.
                            match target_args.as_slice() {
                                [only] => {
                                    let is_cause = matches!(
                                        only,
                                        klio_runtime::Value::Instance(_)
                                    );
                                    let key = if is_cause { "cause" } else { "message" };
                                    i.fields.retain(|(n, _)| n != key);
                                    i.fields.push((key.to_string(), only.clone()));
                                }
                                [msg, cause, ..] => {
                                    i.fields.retain(|(n, _)| n != "message" && n != "cause");
                                    i.fields.push(("message".to_string(), msg.clone()));
                                    i.fields.push(("cause".to_string(), cause.clone()));
                                }
                                [] => {}
                            }
                        }
                        leaf
                    }
                } else if entry.is_this {
                    // `: this(args)` — delegate to a sibling
                    // constructor with the resolved arguments.
                    <Self as klio_ir::eval::Host>::new_instance(
                        self, class, &target_args,
                    )?
                } else {
                    // `CtorDelegation::None` — implicit `super()`.
                    // Build the primary instance shell (default
                    // fields + body-prop inits + init blocks) under a
                    // recursion guard so this very constructor isn't
                    // re-dispatched.
                    with_ctor_guard(|g| g.borrow_mut().push(class_def.name.clone()));
                    let shell = <Self as klio_ir::eval::Host>::new_instance(
                        self, class, &[],
                    );
                    with_ctor_guard(|g| {
                        g.borrow_mut().pop();
                    });
                    shell?
                };
                // Body block — evaluate with `[this, ctor_params...]`.
                if let Some(body_fid) = entry.body {
                    if let Some(body_func) = module.funcs.get(body_fid.0 as usize).cloned() {
                        let mut all: Vec<klio_runtime::Value> =
                            Vec::with_capacity(1 + args.len());
                        all.push(inst_v.clone());
                        all.extend_from_slice(args);
                        klio_ir::eval::eval_with(&module, &body_func, all, self)?;
                    }
                }
                return Ok(inst_v);
            }
        }
        // Trivial primary-ctor shape: each primary param with
        // `property = Some(...)` becomes an instance field, then
        // body properties with init thunks run to populate their
        // fields. Init blocks, parent ctor chain, secondary ctors,
        // and supertype delegates are not yet handled.
        if !class_def.parent_ctor_args.is_empty()
            || !class_def.supertype_delegates.borrow().is_empty()
        {
            // parent ctor args + supertype delegates handled
            // further below — accept them as non-error here.
        }
        let _is_block = ();
        let n_primary = class_def.primary_params.len();
        let mut effective_args: Vec<klio_runtime::Value> = args.to_vec();
        if effective_args.len() < n_primary {
            // Fill missing positional args with each param's default.
            // Literal-only defaults resolve eagerly here; anything more
            // complex needs a lowered thunk and lands when class lowering
            // grows ctor-arg defaults as IR FuncIds.
            for idx in effective_args.len()..n_primary {
                let p = &class_def.primary_params[idx];
                let v = match &p.default {
                    Some(e) => simple_literal(e).unwrap_or(klio_runtime::Value::Null),
                    None => klio_runtime::Value::Null,
                };
                effective_args.push(v);
            }
        }
        if effective_args.len() != n_primary {
            return Err(klio_ir::eval::EvalError::Arity(format!(
                "{}() expects {n_primary} args, got {}",
                class_def.name,
                effective_args.len()
            )));
        }
        let args = effective_args.as_slice();
        let identity = self.instance_id_counter.fetch_add(1, AtomicOrdering::Relaxed) + 1;
        let mut fields: Vec<(String, klio_runtime::Value)> =
            Vec::with_capacity(class_def.primary_params.len() + class_def.body_properties.len());
        // Walk the parent ctor chain top-down: each parent gets
        // args computed by its child's parent_ctor_args thunks
        // (taking the child's own primary args). Properties from
        // every level land on the same instance, so a class
        // overriding `name` via the parent's primary param sees the
        // field correctly.
        let mut chain: Vec<(String, Vec<klio_runtime::Value>)> = Vec::new();
        chain.push((ir_class.name.clone(), args.to_vec()));
        let mut cur_class = ir_class.name.clone();
        let mut cur_args: Vec<klio_runtime::Value> = args.to_vec();
        // Throwable-style parent ctor handling: when this class
        // extends a built-in `RuntimeException`/`Throwable`/etc.
        // (no user ClassDef registered), evaluate the parent-ctor
        // arg thunks once and bind `message`/`cause` on the
        // instance so user-visible `e.message` works.
        let mut throwable_message: Option<klio_runtime::Value> = None;
        let mut throwable_cause: Option<klio_runtime::Value> = None;
        {
            let cur_def = self.classes.borrow().get(&cur_class).cloned();
            let parent_name = cur_def
                .as_ref()
                .and_then(|d| d.supertype_names.first().cloned());
            if let Some(pname) = parent_name {
                let is_throwable_name = matches!(
                    pname.as_str(),
                    "Throwable"
                        | "Exception"
                        | "RuntimeException"
                        | "Error"
                        | "IllegalArgumentException"
                        | "IllegalStateException"
                        | "IndexOutOfBoundsException"
                        | "NullPointerException"
                        | "ClassCastException"
                        | "ArithmeticException"
                        | "NumberFormatException"
                        | "NoSuchElementException"
                        | "ConcurrentModificationException"
                        | "UnsupportedOperationException"
                );
                let parent_def = self.classes.borrow().get(&pname).cloned();
                if is_throwable_name && parent_def.is_none() {
                    if let Some(thunks) = self.prog.parent_ctor_args.get(&cur_class).cloned() {
                        for (idx, fid) in thunks.iter().enumerate() {
                            if let Some(func) =
                                self.module.funcs.get(fid.0 as usize).cloned()
                            {
                                let v = klio_ir::eval::eval_with(
                                    &Arc::clone(&self.module),
                                    &func,
                                    cur_args.clone(),
                                    self,
                                )?;
                                match idx {
                                    0 => throwable_message = Some(v),
                                    1 => throwable_cause = Some(v),
                                    _ => {}
                                }
                            }
                        }
                    }
                }
            }
        }
        while let Some(thunks) = self.prog.parent_ctor_args.get(&cur_class).cloned() {
            let cur_def = self.classes.borrow().get(&cur_class).cloned();
            let parent_name = cur_def
                .as_ref()
                .and_then(|d| d.supertype_names.first().cloned());
            let Some(parent_name) = parent_name else { break };
            // Resolve to a non-interface parent for ctor chaining.
            let parent_def = self.classes.borrow().get(&parent_name).cloned();
            if parent_def.as_ref().map_or(true, |d| d.is_interface) {
                break;
            }
            let mut parent_args: Vec<klio_runtime::Value> = Vec::with_capacity(thunks.len());
            for fid in &thunks {
                let func = self.module.funcs.get(fid.0 as usize).cloned().ok_or_else(|| {
                    klio_ir::eval::EvalError::Type(format!(
                        "parent ctor arg FuncId {} out of range",
                        fid.0
                    ))
                })?;
                let module = Arc::clone(&self.module);
                let v = klio_ir::eval::eval_with(&module, &func, cur_args.clone(), self)?;
                parent_args.push(v);
            }
            chain.push((parent_name.clone(), parent_args.clone()));
            cur_class = parent_name;
            cur_args = parent_args;
        }
        // Apply primary-param properties from each level bottom-up
        // so child overrides win on collision.
        for (cls_name, cls_args) in chain.iter().rev() {
            let cls_def = self.classes.borrow().get(cls_name).cloned();
            if let Some(cls_def) = cls_def {
                for (param, value) in cls_def.primary_params.iter().zip(cls_args.iter()) {
                    if param.property.is_some() {
                        fields.retain(|(n, _)| n != &param.name);
                        fields.push((param.name.clone(), value.clone()));
                    }
                }
            }
        }
        let _ = (&class_def.primary_params, args);
        // Materialise the instance with primary-param fields now so
        // body-property initialisers can reference `this` (and read
        // already-bound fields). Body props get appended into the
        // same instance after the init thunks run.
        let inst = klio_runtime::ObjRef::new(klio_runtime::InstanceData {
            class: class_def.clone(),
            fields,
            outer: None,
            identity,
            native_state: None,
        });
        let inst_value = klio_runtime::Value::Instance(inst.clone());
        // Attach a stored default-outer if the class was
        // registered inside a method body via Inst::RegisterClass —
        // lets `this@Outer.X` and outer-field reads resolve.
        if inst.borrow().outer.is_none() {
            if let Some(default_outer) =
                self.class_default_outer.borrow().get(&class_def.name).cloned()
            {
                inst.borrow_mut().outer = Some(default_outer);
            }
        }
        // Publish object / companion singletons into globals *before*
        // their body-property initialisers and init blocks run, so a
        // companion whose initialiser (transitively) references the
        // companion's own members resolves to the in-progress
        // instance instead of failing forwarding. This mirrors JVM
        // `<clinit>` semantics, where the (companion) class is loaded
        // and self-referenceable while its static initialiser runs —
        // e.g. upstream `kotlin.time.Duration.Companion`'s `INFINITE`
        // / `NEG_INFINITE` / `INVALID` go through top-level
        // `durationOf*` helpers that call `Duration.fromRawValue`.
        if class_def.is_object {
            self.globals
                .borrow_mut()
                .define(&class_def.name, inst_value.clone());
        }
        // Evaluate class-delegation expressions (`: I by g`) and
        // store the resulting delegate values on the instance
        // under `__delegate__<superName>` so call_member can
        // forward unmatched methods.
        let class_delegate_thunks = self.prog
            .class_delegates
            .get(&class_def.name)
            .cloned()
            .unwrap_or_default();
        for (sup_name, fid) in &class_delegate_thunks {
            if let Some(func) = self.module.funcs.get(fid.0 as usize).cloned() {
                let module = Arc::clone(&self.module);
                let v = klio_ir::eval::eval_with(&module, &func, args.to_vec(), self)?;
                inst.borrow_mut()
                    .fields
                    .push((format!("__delegate__{sup_name}"), v));
            }
        }
        if let Some(m) = throwable_message.clone() {
            inst.borrow_mut().fields.push(("message".to_string(), m));
        }
        if let Some(c) = throwable_cause.clone() {
            inst.borrow_mut().fields.push(("cause".to_string(), c));
        }
        // Body properties: walk each class in the parent chain so a
        // subclass instance also picks up the parent's `var/val`
        // body properties. Each init thunk runs with
        // `[this, leaf-ctor-args...]`.
        let mut chain_classes: Vec<Arc<klio_runtime::ClassDef>> = Vec::new();
        {
            let mut cur = Some(Arc::clone(&class_def));
            while let Some(c) = cur {
                chain_classes.push(Arc::clone(&c));
                cur = c.parent.borrow().clone();
            }
        }
        // Bottom-up so parent fields exist before child fields can
        // override the same name.
        for cls in chain_classes.iter().rev() {
        for p in &cls.body_properties {
            if let Some(fid) = self.prog
                .body_prop_inits
                .get(&(cls.name.clone(), p.name.clone()))
                .copied()
            {
                let func = self
                    .module
                    .funcs
                    .get(fid.0 as usize)
                    .cloned()
                    .ok_or_else(|| {
                        klio_ir::eval::EvalError::Type(format!(
                            "body prop init FuncId {} out of range",
                            fid.0
                        ))
                    })?;
                let module = Arc::clone(&self.module);
                let mut all: Vec<klio_runtime::Value> = Vec::with_capacity(1 + args.len());
                all.push(inst_value.clone());
                all.extend_from_slice(args);
                let mut v = klio_ir::eval::eval_with(&module, &func, all, self)?;
                if self.module.registry
                    .delegated_body_props
                    .contains(&(cls.name.clone(), p.name.clone()))
                {
                    if let klio_runtime::Value::Instance(ref dinst) = v {
                        let dcls_name = dinst.borrow().class.name.clone();
                        let has_provide = self
                            .module
                            .classes
                            .iter()
                            .find(|c| c.name == dcls_name)
                            .map(|c| {
                                c.methods.iter().any(|fid| {
                                    self.module
                                        .funcs
                                        .get(fid.0 as usize)
                                        .map(|f| f.name == "provideDelegate")
                                        .unwrap_or(false)
                                })
                            })
                            .unwrap_or(false);
                        if has_provide {
                            let prop_ref = klio_runtime::Value::PropertyRef {
                                name: Arc::new(p.name.clone()),
                            };
                            if let Ok(rep) = <Self as klio_ir::eval::Host>::call_member(
                                self,
                                &v,
                                "provideDelegate",
                                &[inst_value.clone(), prop_ref],
                            ) {
                                v = rep;
                            }
                        }
                    }
                }
                inst.borrow_mut().define(&p.name, v);
            } else if let Some(init_expr) = p.init.as_ref() {
                // Runtime-registered class (no lowered thunk):
                // evaluate the property's init via simple_literal
                // (covers literal-only inits used in local class
                // declarations).
                let v = simple_literal(init_expr).unwrap_or(klio_runtime::Value::Null);
                inst.borrow_mut().define(&p.name, v);
            } else if p.getter.is_none() && p.delegate.is_none() {
                // Only seed a null slot when the field doesn't
                // already exist — child override inits from a
                // bottom-up walk have already populated the slot.
                if inst.borrow().get(&p.name).is_none() {
                    inst.borrow_mut()
                        .fields
                        .push((p.name.clone(), klio_runtime::Value::Null));
                }
            }
        }
        }
        // Run init blocks bottom-up across the parent chain so a
        // parent's init runs before its child's. Each init block
        // takes `this` as its sole param.
        for (cls_name, cls_args) in chain.iter().rev() {
            if let Some(fids) = self.prog.init_blocks.get(cls_name).cloned() {
                for fid in fids {
                    let func = self.module.funcs.get(fid.0 as usize).cloned();
                    if let Some(f) = func {
                        let module = Arc::clone(&self.module);
                        let mut all: Vec<klio_runtime::Value> =
                            Vec::with_capacity(1 + cls_args.len());
                        all.push(inst_value.clone());
                        all.extend(cls_args.iter().cloned());
                        klio_ir::eval::eval_with(&module, &f, all, self)?;
                    }
                }
            }
        }
        Ok(inst_value)
    }
}

/// Pack trailing positional args into a single `Value::Array` when
/// the target function's last param is marked `vararg`. Leaves
/// non-vararg signatures untouched. A single passed-in array slips
/// through as-is to support `f(*arr)` call sites.
/// True when an extension's declared receiver type name denotes a
/// user / pack class — i.e. not a builtin, an open supertype a
/// builtin satisfies (`Any`, `CharSequence`, `Comparable`, …), or a
/// bare type parameter. Such a receiver can never be a builtin
/// value, so the extension is definitively inapplicable to one.
fn ext_decl_recv_is_user_class(ty_name: &str) -> bool {
    let s = ty_name.rsplit('.').next().unwrap_or(ty_name);
    if s.is_empty() {
        return false;
    }
    if s.len() <= 2 && s.chars().all(|c| c.is_ascii_uppercase()) {
        return false; // type parameter (T, R, E, K, V, …)
    }
    !matches!(
        s,
        "String" | "StringBuilder" | "CharSequence" | "Appendable"
            | "Int" | "Long" | "Short" | "Byte" | "Double" | "Float"
            | "Char" | "Boolean" | "Number" | "Array" | "List"
            | "MutableList" | "Collection" | "Iterable" | "Map"
            | "MutableMap" | "Set" | "MutableSet" | "Sequence"
            | "Comparable" | "Any" | "Unit"
    )
}

/// True for a builtin (non-`Instance`, non-`Class`) value — one that
/// can never be an instance of a user-declared class.
fn value_is_builtin(v: &klio_runtime::Value) -> bool {
    matches!(
        v,
        klio_runtime::Value::String(_)
            | klio_runtime::Value::StringBuilder(_)
            | klio_runtime::Value::Int(_)
            | klio_runtime::Value::Long(_)
            | klio_runtime::Value::Short(_)
            | klio_runtime::Value::Byte(_)
            | klio_runtime::Value::Double(_)
            | klio_runtime::Value::Float(_)
            | klio_runtime::Value::Char(_)
            | klio_runtime::Value::Bool(_)
            | klio_runtime::Value::Array { .. }
            | klio_runtime::Value::List { .. }
            | klio_runtime::Value::Map { .. }
    )
}

fn pack_vararg_args(
    func: &klio_ir::Func,
    args: Vec<klio_runtime::Value>,
) -> Vec<klio_runtime::Value> {
    if let Some(last) = func.params.last() {
        if last.is_vararg {
            let fixed = func.params.len().saturating_sub(1);
            if args.len() == func.params.len() {
                if matches!(args.last(), Some(klio_runtime::Value::Array { .. })) {
                    return args;
                }
            }
            let mut out: Vec<klio_runtime::Value> = Vec::with_capacity(func.params.len());
            for v in args.iter().take(fixed) {
                out.push(v.clone());
            }
            let rest: Vec<klio_runtime::Value> =
                args.into_iter().skip(fixed).collect();
            out.push(klio_runtime::Value::Array {
                items: klio_runtime::ObjRef::new(rest),
                prim: None,
            });
            return out;
        }
    }
    args
}

/// Build the `n_params`-length argument vector for a closure call,
/// filling positions past the provided args from the target's
/// registered default-arg thunks (each binds the params before it),
/// falling back to `Null` when a slot has no default. This mirrors
/// the trailing-arg padding `Vm::call_func` does for top-level
/// functions so a local `fun f(a, b = a + 1)` called `f(1)` yields
/// `b == 2`.
/// A `TypeRef` denoting a Kotlin function type — `() -> T` lowers
/// to a `FunctionN` / `kotlin.FunctionN` nominal, or carries an
/// arrow in the rendered name.
fn is_function_type(ty: &klio_ir::TypeRef) -> bool {
    let n = ty.name.rsplit('.').next().unwrap_or(&ty.name);
    n.starts_with("Function") || ty.name.contains("->")
}

/// Whether a runtime value can be invoked as `f(...)`.
fn value_is_callable(v: &klio_runtime::Value) -> bool {
    matches!(
        v,
        klio_runtime::Value::IrClosure { .. }
            | klio_runtime::Value::Lambda { .. }
            | klio_runtime::Value::Function { .. }
            | klio_runtime::Value::Intrinsic { .. }
            | klio_runtime::Value::BoundMethod { .. }
            | klio_runtime::Value::PropertyRef { .. }
    )
}

fn pad_args_with_defaults<H: klio_ir::eval::Host>(
    module: &klio_ir::Module,
    n_params: usize,
    provided: &[klio_runtime::Value],
    defaults: Option<&Vec<Option<klio_ir::FuncId>>>,
    host: &mut H,
) -> Result<Vec<klio_runtime::Value>, klio_ir::eval::EvalError> {
    let mut call_args: Vec<klio_runtime::Value> = Vec::with_capacity(n_params);
    for i in 0..n_params {
        if i < provided.len() {
            call_args.push(provided[i].clone());
            continue;
        }
        let dfid = defaults.and_then(|d| d.get(i).copied().flatten());
        if let Some(dfid) = dfid {
            let dfunc = module
                .funcs
                .get(dfid.0 as usize)
                .cloned()
                .ok_or_else(|| {
                    klio_ir::eval::EvalError::Type(format!(
                        "default-arg FuncId {} out of range",
                        dfid.0
                    ))
                })?;
            let v = klio_ir::eval::eval_with(
                module,
                &dfunc,
                call_args.clone(),
                host,
            )?;
            call_args.push(v);
        } else {
            call_args.push(klio_runtime::Value::Null);
        }
    }
    Ok(call_args)
}

/// Structural value hash matching `Value::structural_eq`. Used by
/// data-class auto `hashCode`. Mirrors klio-interp's helper.
fn value_structural_hash(v: &klio_runtime::Value) -> i32 {
    use klio_runtime::Value::*;
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    match v {
        Unit => 0i32.hash(&mut h),
        Null => 1i32.hash(&mut h),
        Bool(b) => { 2i32.hash(&mut h); b.hash(&mut h); }
        Char(c) => { 3i32.hash(&mut h); c.hash(&mut h); }
        Int(i) => { 4i32.hash(&mut h); (*i as i64).hash(&mut h); }
        Long(l) => { 4i32.hash(&mut h); l.hash(&mut h); }
        Short(s) => { 4i32.hash(&mut h); (*s as i64).hash(&mut h); }
        Byte(b) => { 4i32.hash(&mut h); (*b as i64).hash(&mut h); }
        UInt(u) => { 4i32.hash(&mut h); (*u as i64).hash(&mut h); }
        ULong(u) => { 4i32.hash(&mut h); u.hash(&mut h); }
        UShort(u) => { 4i32.hash(&mut h); (*u as i64).hash(&mut h); }
        UByte(u) => { 4i32.hash(&mut h); (*u as i64).hash(&mut h); }
        Float(f) => { 5i32.hash(&mut h); f.to_bits().hash(&mut h); }
        Double(d) => { 5i32.hash(&mut h); d.to_bits().hash(&mut h); }
        String(s) => { 6i32.hash(&mut h); s.hash(&mut h); }
        _ => 7i32.hash(&mut h),
    }
    h.finish() as i32
}

/// Best-effort fold of trivially-literal AST expressions to a
/// runtime Value. Used by anonymous-object body-property
/// initialisation where the IR module's full thunk-lowering
/// hasn't run.
fn simple_literal(e: &klio_ast::Expr) -> Option<klio_runtime::Value> {
    use klio_ast::Expr::*;
    match e {
        IntLit { value, .. } => Some(klio_runtime::Value::new_int(*value)),
        FloatLit { value, .. } => Some(klio_runtime::Value::Double(*value)),
        BoolLit { value, .. } => Some(klio_runtime::Value::Bool(*value)),
        NullLit { .. } => Some(klio_runtime::Value::Null),
        CharLit { value, .. } => Some(klio_runtime::Value::Char(*value)),
        StringTemplate { parts, .. } if parts.iter().all(|p| matches!(p, klio_ast::StringPart::Text(_))) => {
            let mut s = String::new();
            for p in parts {
                if let klio_ast::StringPart::Text(t) = p {
                    s.push_str(t);
                }
            }
            Some(klio_runtime::Value::String(Arc::new(s)))
        }
        _ => None,
    }
}

fn materialise_range_items(
    start: i64,
    end: i64,
    step: i64,
    kind: klio_runtime::RangeKind,
) -> Vec<klio_runtime::Value> {
    use klio_runtime::{RangeKind, Value};
    let mut out: Vec<Value> = Vec::new();
    let mut cur = start;
    if step > 0 {
        while cur <= end {
            match kind {
                RangeKind::Int => out.push(Value::new_int(cur)),
                RangeKind::Long => out.push(Value::Long(cur)),
                RangeKind::Char => out.push(Value::Char(cur as u8 as char)),
            }
            cur = cur.saturating_add(step);
            if cur > end && step > 0 {
                break;
            }
        }
    } else if step < 0 {
        while cur >= end {
            match kind {
                RangeKind::Int => out.push(Value::new_int(cur)),
                RangeKind::Long => out.push(Value::Long(cur)),
                RangeKind::Char => out.push(Value::Char(cur as u8 as char)),
            }
            cur = cur.saturating_add(step);
            if cur < end {
                break;
            }
        }
    }
    out
}

/// Stdlib `CallCtx` host adapter for native Vm dispatch. HOF
/// bindings (`map`, `forEach`, scope fns, ...) reach back through
/// this adapter to invoke the lambda they were passed. The Vm
/// dispatches `Value::IrClosure` via the IR evaluator, reusing the
/// same closure / class / globals tables the outer Vm uses.
struct VmIntrinsicHost<'a> {
    scheduler: &'a mut dyn klio_runtime::Scheduler,
    module: Arc<klio_ir::Module>,
    closures: SharedClosures,
    globals: klio_runtime::ObjRef<klio_runtime::Env>,
    classes: klio_runtime::ObjRef<std::collections::HashMap<String, Arc<klio_runtime::ClassDef>>>,
    prog: Arc<ProgramImage>,
    anon_methods: klio_runtime::ObjRef<std::collections::HashMap<
        (String, String),
        (Arc<klio_ir::Module>, klio_ir::FuncId, Vec<(String, klio_runtime::Value)>),
    >>,
    class_default_outer:
        klio_runtime::ObjRef<std::collections::HashMap<String, klio_runtime::Value>>,
    instance_id_counter: Arc<AtomicU64>,
    out_sink: klio_runtime::SharedOutput,
    threads: Arc<Mutex<std::collections::HashMap<u64, ThreadEntry>>>,
}

/// How the default interceptor interprets a `delay` directive.
/// `Wall` (the default) consumes real wall-clock time, matching the
/// JVM. `Virtual` advances a logical clock instantly — deterministic
/// and fast, used by the test scheduler and the parity / conformance
/// harnesses.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum TimeMode {
    #[default]
    Wall,
    Virtual,
}

thread_local! {
    static COROUTINE_TIME_MODE: std::cell::Cell<TimeMode> =
        const { std::cell::Cell::new(TimeMode::Wall) };
}

/// Set the coroutine time mode for the current thread. The default
/// is [`TimeMode::Wall`]; tests and the parity/conformance harnesses
/// opt into [`TimeMode::Virtual`] for determinism.
pub fn set_coroutine_time_mode(mode: TimeMode) {
    COROUTINE_TIME_MODE.with(|m| m.set(mode));
}

/// Current coroutine time mode for this thread.
#[must_use]
pub fn coroutine_time_mode() -> TimeMode {
    COROUTINE_TIME_MODE.with(std::cell::Cell::get)
}

/// Layer 2 — the default `ContinuationInterceptor`.
///
/// This is the only place coroutine *scheduling* happens. The core
/// suspend engine (Layer 1, `klio_ir::eval`) is dispatcher- and
/// time-agnostic: it only pauses an activation into a
/// `SuspendState` and resumes one. Every decision about *when* and
/// in what order parked activations resume — the cooperative ready
/// queue and virtual-time advance — lives here, behind the named
/// seam below, so a later thread-dispatching interceptor can
/// replace it without touching Layer 1.
///
/// A stack of these supports nested `runBlocking` /
/// `coroutineScope`.
struct CooperativeInterceptor {
    mode: TimeMode,
    /// Wall-clock origin; `delay` deadlines are measured from here.
    /// Set lazily on first use so an all-virtual run never reads the
    /// clock.
    started: Option<std::time::Instant>,
    next_token: u64,
    virtual_now: i64,
    /// token → (parked activation, virtual-time wakeup; i64::MAX =
    /// indefinite — only an explicit ready entry resumes it).
    parked: std::collections::HashMap<u64, (klio_ir::eval::SuspendState, i64)>,
    /// FIFO of tokens whose wakeup is due (timer fired or yielded).
    ready: std::collections::VecDeque<u64>,
    /// Child `launch` blocks queued during the active scope.
    launched: Vec<klio_runtime::Value>,
    /// Set by `__kxco_parkSlot` immediately before the activation
    /// unwinds with an indefinite suspend; consumed by the next
    /// `intercept_suspend` to bind that token to the slot.
    pending_slot: Option<i64>,
    /// slot id → token of the activation parked on that slot. An
    /// explicit `__kxco_resumeSlot(slot)` moves the token into
    /// `ready` and clears the entry.
    slot_to_token: std::collections::HashMap<i64, u64>,
    /// token → value the activation should observe as the result of
    /// its suspending call when resumed (the `kotlin.coroutines`
    /// `Continuation.resumeWith` payload). Absent ⇒ resume with the
    /// default `Unit`.
    token_resume_value: std::collections::HashMap<u64, klio_runtime::Value>,
}

impl CooperativeInterceptor {
    /// Fresh interceptor honoring this thread's time mode.
    fn new() -> Self {
        Self {
            mode: coroutine_time_mode(),
            started: None,
            next_token: 0,
            virtual_now: 0,
            parked: std::collections::HashMap::new(),
            ready: std::collections::VecDeque::new(),
            launched: Vec::new(),
            pending_slot: None,
            slot_to_token: std::collections::HashMap::new(),
            token_resume_value: std::collections::HashMap::new(),
        }
    }

    /// Current clock reading in millis: the logical clock under
    /// `Virtual`, elapsed wall-clock since first use under `Wall`.
    fn now_millis(&mut self) -> i64 {
        match self.mode {
            TimeMode::Virtual => self.virtual_now,
            TimeMode::Wall => {
                let start = *self
                    .started
                    .get_or_insert_with(std::time::Instant::now);
                start.elapsed().as_millis() as i64
            }
        }
    }

    /// Seam: intercept a freshly-suspended activation. Assigns a
    /// token, decodes the Layer-2 resume directive carried in
    /// `wake_in_millis` (negative = park indefinitely, `0` = ready
    /// now, positive = wake that much later on the active clock),
    /// and records it. Returns the token so the driver can
    /// recognise the root's completion.
    fn intercept_suspend(&mut self, mut state: klio_ir::eval::SuspendState) -> u64 {
        self.next_token += 1;
        let token = self.next_token;
        state.token = token;
        let wake_at = if state.wake_in_millis < 0 {
            i64::MAX
        } else {
            self.now_millis() + state.wake_in_millis
        };
        if state.wake_in_millis == 0 {
            self.ready.push_back(token);
        }
        if state.wake_in_millis < 0 {
            if let Some(slot) = self.pending_slot.take() {
                self.slot_to_token.insert(slot, token);
            }
        }
        self.parked.insert(token, (state, wake_at));
        token
    }

    /// Seam: record the slot the next indefinitely-parked
    /// activation is waiting on (set by `__kxco_parkSlot`).
    fn set_pending_slot(&mut self, slot: i64) {
        self.pending_slot = Some(slot);
    }

    /// Seam: if a token is waiting on `slot`, move it into the ready
    /// queue and clear the mapping. Returns whether a waiter was
    /// found.
    fn resume_slot(&mut self, slot: i64) -> bool {
        if let Some(token) = self.slot_to_token.remove(&slot) {
            self.ready.push_back(token);
            true
        } else {
            false
        }
    }

    /// Like [`resume_slot`] but records `value` so the resumed
    /// activation observes it as its suspending call's result.
    fn resume_slot_value(&mut self, slot: i64, value: klio_runtime::Value) -> bool {
        if let Some(token) = self.slot_to_token.remove(&slot) {
            self.token_resume_value.insert(token, value);
            self.ready.push_back(token);
            true
        } else {
            false
        }
    }

    /// Take the pending resume value for `token`, if one was set by
    /// [`resume_slot_value`].
    fn take_resume_value(&mut self, token: u64) -> Option<klio_runtime::Value> {
        self.token_resume_value.remove(&token)
    }

    /// Seam: take the child `launch` blocks queued this round.
    fn drain_launched(&mut self) -> Vec<klio_runtime::Value> {
        std::mem::take(&mut self.launched)
    }

    /// Seam: queue a child `launch` block.
    fn enqueue_launch(&mut self, block: klio_runtime::Value) {
        self.launched.push(block);
    }

    /// Seam: next ready token, if any.
    fn next_ready(&mut self) -> Option<u64> {
        self.ready.pop_front()
    }

    /// Seam: take the parked activation for a token.
    fn take_parked(&mut self, token: u64) -> Option<(klio_ir::eval::SuspendState, i64)> {
        self.parked.remove(&token)
    }

    /// Seam: nothing ready — advance the clock to the soonest timer
    /// and arm every activation due then. Under `Virtual` the clock
    /// jumps instantly; under `Wall` the thread sleeps until the
    /// real deadline. Returns whether any progress was made.
    fn advance_time(&mut self) -> bool {
        let soonest = self
            .parked
            .values()
            .map(|(_, w)| *w)
            .filter(|w| *w != i64::MAX)
            .min();
        let Some(t) = soonest else { return false };
        match self.mode {
            TimeMode::Virtual => {
                if t > self.virtual_now {
                    self.virtual_now = t;
                }
            }
            TimeMode::Wall => {
                let wait = (t - self.now_millis()).max(0);
                if wait > 0 {
                    std::thread::sleep(std::time::Duration::from_millis(wait as u64));
                }
            }
        }
        let now = self.now_millis();
        let mut due: Vec<u64> = self
            .parked
            .iter()
            .filter(|(_, (_, w))| *w != i64::MAX && *w <= now)
            .map(|(k, _)| *k)
            .collect();
        due.sort_unstable();
        for tok in &due {
            self.ready.push_back(*tok);
        }
        !due.is_empty()
    }
}

/// The per-thread interpreter execution context — the single named
/// home for state that belongs to *one* interpreting thread.
///
/// This is the publication boundary. Everything in here is private
/// to the thread running the Vm; nothing in it may be shared with
/// another thread directly. When real threads land, each gets its
/// own `ExecState`, and the only legal cross-thread transfer of a
/// Kotlin value is through the fence-and-publish primitive — never
/// by reaching into another thread's `ExecState`. Process-global
/// configuration that is deliberately shared (e.g. the
/// `klio-stdlib` known-packages registry) lives *outside* this
/// boundary by design and is documented as such where it is
/// defined.
#[derive(Default)]
struct ExecState {
    /// Cooperative interceptor stack (nested `runBlocking` /
    /// `coroutineScope`).
    coro: RefCell<Vec<CooperativeInterceptor>>,
    /// Classes whose instance shell is mid-construction for a
    /// non-delegating secondary constructor. While a class is on
    /// this stack, `new_instance` skips secondary dispatch and
    /// builds the primary shell, so a `constructor() { … }` body
    /// that re-enters `new_instance` doesn't recurse forever.
    ctor_guard: RefCell<Vec<String>>,
    /// Enclosing-`this` stack for receiver lambdas. A scope function
    /// (`apply` / `with` / `buildString`) rebinds the lambda's
    /// implicit `this` to its receiver, but Kotlin keeps the
    /// lexically enclosing `this@Outer` reachable as an outer
    /// implicit receiver. Each receiver-lambda invocation pushes the
    /// instance it displaced; member / `this@Label` resolution falls
    /// back to the top of this stack when the inner receiver lacks
    /// the member.
    outer_this: RefCell<Vec<klio_runtime::Value>>,
}

thread_local! {
    static EXEC: ExecState = ExecState::default();
}

/// Run `f` against this thread's coroutine interceptor stack.
fn with_coro<R>(f: impl FnOnce(&RefCell<Vec<CooperativeInterceptor>>) -> R) -> R {
    EXEC.with(|e| f(&e.coro))
}

/// Run `f` against this thread's constructor-shell recursion guard.
fn with_ctor_guard<R>(f: impl FnOnce(&RefCell<Vec<String>>) -> R) -> R {
    EXEC.with(|e| f(&e.ctor_guard))
}

/// Run `f` against this thread's enclosing-`this` stack for receiver
/// lambdas.
fn with_outer_this<R>(f: impl FnOnce(&RefCell<Vec<klio_runtime::Value>>) -> R) -> R {
    EXEC.with(|e| f(&e.outer_this))
}

impl<'a> VmIntrinsicHost<'a> {
    /// Build a transient `VmHost` over the same shared state, bound
    /// to `out` for the duration of one delegated evaluation.
    fn vm_host<'s>(&'s mut self, out: &'s mut dyn Output) -> VmHost<'s> {
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

    /// A sibling `VmIntrinsicHost` over the same shared state, used
    /// when an intrinsic recursively dispatches another intrinsic.
    fn child_host(&mut self) -> VmIntrinsicHost<'_> {
        VmIntrinsicHost {
            scheduler: &mut *self.scheduler,
            module: Arc::clone(&self.module),
            closures: self.closures.clone(),
            globals: self.globals.clone(),
            classes: self.classes.clone(),
            prog: Arc::clone(&self.prog),
            anon_methods: self.anon_methods.clone(),
            class_default_outer: self.class_default_outer.clone(),
            instance_id_counter: Arc::clone(&self.instance_id_counter),
            out_sink: self.out_sink.clone(),
            threads: Arc::clone(&self.threads),
        }
    }

    /// Construct an instance through the full constructor pipeline.
    /// The intrinsic child host has no `new_instance` of its own, so
    /// build a transient `VmHost` over the same shared state (the
    /// pattern `eval_closure_raw` uses) and delegate. Lets a
    /// constructor reference (`::Box`, `Outer::Nested`) be invoked
    /// uniformly from stdlib higher-order ops like `map`/`fold`.
    fn construct(
        &mut self,
        class_id: klio_ir::ClassId,
        args: &[klio_runtime::Value],
        out: &mut dyn Output,
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        let mut host = self.vm_host(out);
        <VmHost as klio_ir::eval::Host>::new_instance(&mut host, class_id, args)
    }

    /// Evaluate an `IrClosure` and return the *raw* EvalError so the
    /// coroutine driver can observe `Suspended`. Mirrors the
    /// closure-setup half of `invoke_callable` (capture env, param
    /// fill, write-back) without flattening errors.
    fn eval_closure_raw(
        &mut self,
        callable: &klio_runtime::Value,
        args: &[klio_runtime::Value],
        this: Option<&klio_runtime::Value>,
        out: &mut dyn Output,
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        let klio_runtime::Value::IrClosure { id, captures } = callable else {
            return Err(klio_ir::eval::EvalError::Type(format!(
                "coroutine block is not a closure: `{}`",
                callable.type_fqn()
            )));
        };
        let live_captures: Vec<klio_runtime::Value> = (**captures).clone();
        let info = self.closures.get(*id as usize).ok_or_else(|| {
            klio_ir::eval::EvalError::Type(format!("unknown IrClosure id {id}"))
        })?;
        let func = self
            .module
            .funcs
            .get(info.body_func.0 as usize)
            .cloned()
            .ok_or_else(|| {
                klio_ir::eval::EvalError::Type(format!(
                    "closure body FuncId {} out of range",
                    info.body_func.0
                ))
            })?;
        let mut call_args: Vec<klio_runtime::Value> =
            Vec::with_capacity(info.n_params.max(args.len()));
        if let Some(t) = this {
            if info.n_params >= 1 {
                call_args.push(t.clone());
                for a in args {
                    call_args.push(a.clone());
                }
            } else {
                call_args.extend_from_slice(args);
            }
        } else {
            for i in 0..info.n_params {
                call_args.push(args.get(i).cloned().unwrap_or(klio_runtime::Value::Null));
            }
        }
        while call_args.len() < info.n_params {
            call_args.push(klio_runtime::Value::Null);
        }
        // Prefer the live captures carried on the closure Value (a
        // runtime-created closure boxes its captured bindings here);
        // fall back to the ClosureInfo cell for closures whose Value
        // carries none (e.g. top-level fn wrappers).
        let mut capture_values: Vec<klio_runtime::Value> =
            if live_captures.len() == info.capture_names.len() {
                live_captures
            } else {
                info.captures.borrow().clone()
            };
        if let Some(t) = this {
            if let Some(idx) = info.capture_names.iter().position(|n| n == "this") {
                if idx < capture_values.len() {
                    capture_values[idx] = t.clone();
                }
            }
        }
        let scoped_env = klio_runtime::ObjRef::new(klio_runtime::Env::with_parent(
            self.globals.clone(),
        ));
        for (n, v) in info.capture_names.iter().zip(capture_values.iter()) {
            scoped_env.borrow_mut().define(n.clone(), v.clone());
        }
        let module = Arc::clone(&self.module);
        let result = {
            let mut host = VmHost {
                globals: scoped_env.clone(),
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
            };
            klio_ir::eval::eval_with_captures(
                &module,
                &func,
                call_args,
                capture_values,
                &mut host,
            )
        };
        let new_captures: Vec<klio_runtime::Value> = info
            .capture_names
            .iter()
            .map(|n| scoped_env.borrow().lookup(n).unwrap_or(klio_runtime::Value::Null))
            .collect();
        *info.captures.borrow_mut() = new_captures;
        result
    }

    /// Resume a parked activation with `value`, raw EvalError out.
    fn resume_raw(
        &mut self,
        state: klio_ir::eval::SuspendState,
        value: klio_runtime::Value,
        out: &mut dyn Output,
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        let module = Arc::clone(&self.module);
        let mut host = self.vm_host(out);
        klio_ir::eval::resume_continuation(&module, state, value, &mut host)
    }

    /// Hand a freshly-suspended Layer-1 activation to the active
    /// interceptor (Layer 2). Returns the token so the driver can
    /// recognise the root's completion.
    fn park(&self, state: klio_ir::eval::SuspendState) -> u64 {
        with_coro(|s| {
            s.borrow_mut()
                .last_mut()
                .expect("park outside runBlocking")
                .intercept_suspend(state)
        })
    }

    /// Layer 2 — the default interceptor's dispatch loop, the engine
    /// behind `runBlocking`. Drives Layer-1 activations: it never
    /// inspects the suspend mechanism, only parks/resumes through
    /// the interceptor seam.
    fn drive_run_blocking(
        &mut self,
        block: &klio_runtime::Value,
        scope: &klio_runtime::Value,
        out: &mut dyn Output,
    ) -> Result<klio_runtime::Value, klio_runtime::RuntimeError> {
        /// Run `f` against the active interceptor.
        fn with_top<R>(f: impl FnOnce(&mut CooperativeInterceptor) -> R) -> R {
            with_coro(|s| f(s.borrow_mut().last_mut().expect("no active runBlocking")))
        }
        with_coro(|s| s.borrow_mut().push(CooperativeInterceptor::new()));
        let map_err = |e: klio_ir::eval::EvalError| -> klio_runtime::RuntimeError {
            match e {
                klio_ir::eval::EvalError::Throw(v) => klio_runtime::RuntimeError::Thrown(v),
                klio_ir::eval::EvalError::NonLocalReturn(v) => {
                    klio_runtime::RuntimeError::Return(v)
                }
                other => klio_runtime::RuntimeError::Type(format!("{other}")),
            }
        };
        // Root coroutine.
        let mut root_value: Option<klio_runtime::Value> = None;
        let mut root_token: Option<u64> = None;
        match self.eval_closure_raw(block, &[], Some(scope), out) {
            Ok(v) => root_value = Some(v),
            Err(klio_ir::eval::EvalError::Suspended(st)) => {
                root_token = Some(self.park(*st));
            }
            Err(e) => {
                with_coro(|s| {
                    s.borrow_mut().pop();
                });
                return Err(map_err(e));
            }
        }
        loop {
            // 1. Start any queued child launches.
            let launched: Vec<klio_runtime::Value> =
                with_top(CooperativeInterceptor::drain_launched);
            let mut progressed = !launched.is_empty();
            for child in launched {
                match self.eval_closure_raw(&child, &[], Some(scope), out) {
                    Ok(_) => {}
                    Err(klio_ir::eval::EvalError::Suspended(st)) => {
                        self.park(*st);
                    }
                    Err(e) => {
                        with_coro(|s| {
                            s.borrow_mut().pop();
                        });
                        return Err(map_err(e));
                    }
                }
            }
            // 2. Resume a ready coroutine, if any.
            let next_ready = with_top(CooperativeInterceptor::next_ready);
            if let Some(tok) = next_ready {
                let entry = with_top(|i| i.take_parked(tok));
                if let Some((st, _)) = entry {
                    progressed = true;
                    let resume_with = with_top(|i| i.take_resume_value(tok))
                        .unwrap_or(klio_runtime::Value::Unit);
                    match self.resume_raw(st, resume_with, out) {
                        Ok(v) => {
                            if Some(tok) == root_token {
                                root_value = Some(v);
                                root_token = None;
                            }
                        }
                        Err(klio_ir::eval::EvalError::Suspended(st2)) => {
                            let new_tok = self.park(*st2);
                            if Some(tok) == root_token {
                                // Root re-suspended — track its new token.
                                root_token = Some(new_tok);
                            }
                        }
                        Err(e) => {
                            with_coro(|s| {
                                s.borrow_mut().pop();
                            });
                            return Err(map_err(e));
                        }
                    }
                }
                continue;
            }
            // 3. No ready coroutine — advance virtual time to the
            //    nearest timer and arm every coroutine due then.
            let advanced = with_top(CooperativeInterceptor::advance_time);
            if advanced {
                continue;
            }
            // 4. Nothing ready, no timers: done (or deadlocked on an
            //    indefinitely-parked coroutine with no resumer).
            if !progressed {
                break;
            }
        }
        with_coro(|s| {
            s.borrow_mut().pop();
        });
        Ok(root_value.unwrap_or(klio_runtime::Value::Unit))
    }
}

impl<'a> klio_runtime::IntrinsicHost for VmIntrinsicHost<'a> {
    fn run_blocking(
        &mut self,
        block: &klio_runtime::Value,
        scope: &klio_runtime::Value,
        out: &mut dyn Output,
    ) -> Result<klio_runtime::Value, klio_runtime::RuntimeError> {
        self.drive_run_blocking(block, scope, out)
    }

    fn coroutine_launch(
        &mut self,
        block: &klio_runtime::Value,
        _scope: &klio_runtime::Value,
        _out: &mut dyn Output,
    ) -> Result<(), klio_runtime::RuntimeError> {
        let queued = with_coro(|s| {
            let mut stk = s.borrow_mut();
            if let Some(interceptor) = stk.last_mut() {
                interceptor.enqueue_launch(block.clone());
                true
            } else {
                false
            }
        });
        if queued {
            Ok(())
        } else {
            // No active runBlocking — run the child eagerly.
            self.invoke_callable(block, &[], _out).map(|_| ())
        }
    }

    fn coroutine_park_slot(&mut self, slot: i64) {
        with_coro(|s| {
            if let Some(top) = s.borrow_mut().last_mut() {
                top.set_pending_slot(slot);
            }
        });
    }

    fn coroutine_resume_slot(&mut self, slot: i64) {
        with_coro(|s| {
            let mut stk = s.borrow_mut();
            for interceptor in stk.iter_mut().rev() {
                if interceptor.resume_slot(slot) {
                    break;
                }
            }
        });
    }

    fn coroutine_resume_slot_value(&mut self, slot: i64, value: klio_runtime::Value) {
        with_coro(|s| {
            let mut stk = s.borrow_mut();
            for interceptor in stk.iter_mut().rev() {
                if interceptor.resume_slot_value(slot, value.clone()) {
                    break;
                }
            }
        });
    }

    fn invoke_callable(
        &mut self,
        callable: &klio_runtime::Value,
        args: &[klio_runtime::Value],
        out: &mut dyn Output,
    ) -> Result<klio_runtime::Value, klio_runtime::RuntimeError> {
        if let klio_runtime::Value::IrClosure { id, .. } = callable {
            let info = self
                .closures
                .get(*id as usize)
                .ok_or_else(|| klio_runtime::RuntimeError::Type(format!(
                    "unknown IrClosure id {id}"
                )))?;
            let func = self
                .module
                .funcs
                .get(info.body_func.0 as usize)
                .cloned()
                .ok_or_else(|| klio_runtime::RuntimeError::Type(format!(
                    "closure body FuncId {} out of range",
                    info.body_func.0
                )))?;
            let defaults =
                self.prog.func_defaults.get(&info.body_func).cloned();
            let capture_values: Vec<klio_runtime::Value> = info.captures.borrow().clone();
            let module = Arc::clone(&self.module);
            // Mutable-capture support: pre-define each captured name
            // in a fresh env layered on top of globals so the body's
            // StoreGlobal writes land in the env, then read back the
            // updated values into the closure's captures so the
            // outer-frame WritebackCaptures Inst sees them.
            let scoped_env = klio_runtime::ObjRef::new(klio_runtime::Env::with_parent(
                self.globals.clone(),
            ));
            for (n, v) in info.capture_names.iter().zip(capture_values.iter()) {
                scoped_env.borrow_mut().define(n.clone(), v.clone());
            }
            let result = {
                let mut host = VmHost {
                    globals: scoped_env.clone(),
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
                };
                match pad_args_with_defaults(
                    &module,
                    info.n_params,
                    args,
                    defaults.as_ref(),
                    &mut host,
                ) {
                    Ok(call_args) => klio_ir::eval::eval_with_captures(
                        &module,
                        &func,
                        call_args,
                        capture_values,
                        &mut host,
                    ),
                    Err(e) => Err(e),
                }
            };
            // Read back updated capture values into the closure's
            // captures cell so subsequent reads (and the outer
            // WritebackCaptures) see them.
            let new_captures: Vec<klio_runtime::Value> = info
                .capture_names
                .iter()
                .map(|n| {
                    scoped_env
                        .borrow()
                        .lookup(n)
                        .unwrap_or(klio_runtime::Value::Null)
                })
                .collect();
            *info.captures.borrow_mut() = new_captures;
            return result.map_err(|e| match e {
                klio_ir::eval::EvalError::Throw(v) => klio_runtime::RuntimeError::Thrown(v),
                klio_ir::eval::EvalError::NonLocalReturn(v) => {
                    klio_runtime::RuntimeError::Return(v)
                }
                other => klio_runtime::RuntimeError::Type(format!("{other}")),
            });
        }
        // A class value used as a function is a constructor
        // reference (`::Box`, `Outer::Nested`, passed to `map`/`fold`
        // etc.) — invoking it builds an instance.
        if let klio_runtime::Value::Class(def) = callable {
            if let Some(class_id) = self.module.class_id(&def.name) {
                return self.construct(class_id, args, out)
                .map_err(|e| match e {
                    klio_ir::eval::EvalError::Throw(v) => {
                        klio_runtime::RuntimeError::Thrown(v)
                    }
                    klio_ir::eval::EvalError::NonLocalReturn(v) => {
                        klio_runtime::RuntimeError::Return(v)
                    }
                    other => klio_runtime::RuntimeError::Type(format!("{other}")),
                });
            }
        }
        if let klio_runtime::Value::Intrinsic { func, .. } = callable {
            let mut child = self.child_host();
            let mut ctx = klio_runtime::CallCtx {
                args,
                out,
                host: &mut child,
            };
            return func(&mut ctx);
        }
        Err(klio_runtime::RuntimeError::Unimplemented(format!(
            "Vm::invoke_callable on `{}`",
            callable.type_fqn()
        )))
    }

    fn invoke_callable_with_this(
        &mut self,
        callable: &klio_runtime::Value,
        args: &[klio_runtime::Value],
        this: &klio_runtime::Value,
        out: &mut dyn Output,
    ) -> Result<klio_runtime::Value, klio_runtime::RuntimeError> {
        // Receiver-typed lambda dispatch: bind the receiver as the
        // lambda's implicit `this` AND as the parser-injected `it`
        // when the lambda has a single param. Bodies that use
        // `it.foo()` see args[0] = receiver; bodies that use bare
        // names like `add(1)` resolve through the captured `this`
        // slot when the IR lower emitted CallMemberOrGlobal /
        // LoadFromThisOrGlobal (it does for unresolved bare names
        // in lambda bodies). The capture is overridden via the
        // closure's captures cell before invoke.
        if let klio_runtime::Value::IrClosure { id, .. } = callable {
            let info = self.closures.get(*id as usize);
            if let Some(info) = info {
                // Override the captured `this` slot, if present.
                let prior_this: Option<klio_runtime::Value> = info
                    .capture_names
                    .iter()
                    .position(|n| n == "this")
                    .and_then(|idx| info.captures.borrow().get(idx).cloned());
                if let Some(idx) = info
                    .capture_names
                    .iter()
                    .position(|n| n == "this")
                {
                    let mut cap = info.captures.borrow_mut();
                    if idx < cap.len() {
                        cap[idx] = this.clone();
                    } else {
                        cap.resize(idx + 1, klio_runtime::Value::Null);
                        cap[idx] = this.clone();
                    }
                }
                let mut all: Vec<klio_runtime::Value> = Vec::with_capacity(info.n_params);
                if info.n_params >= 1 {
                    all.push(this.clone());
                    for a in args.iter() {
                        all.push(a.clone());
                    }
                } else {
                    all.extend_from_slice(args);
                }
                // The receiver just displaced an enclosing-class
                // `this` (e.g. `buildString { … }` written inside a
                // member). Keep that instance reachable as an outer
                // implicit receiver so bare members / `this@Outer`
                // inside the lambda still resolve, matching Kotlin's
                // nested-receiver rule.
                let pushed_outer = matches!(
                    &prior_this,
                    Some(klio_runtime::Value::Instance(_))
                ) && !matches!(
                    (&prior_this, this),
                    (Some(klio_runtime::Value::Instance(a)), klio_runtime::Value::Instance(b))
                        if klio_runtime::ObjRef::ptr_eq(a, b)
                );
                if pushed_outer {
                    if let Some(p) = &prior_this {
                        with_outer_this(|s| s.borrow_mut().push(p.clone()));
                    }
                }
                let result = self.invoke_callable(callable, &all, out);
                if pushed_outer {
                    with_outer_this(|s| {
                        s.borrow_mut().pop();
                    });
                }
                // Restore prior this so a closure reused with
                // different receivers preserves the original
                // captured value between uses.
                if let Some(idx) = info
                    .capture_names
                    .iter()
                    .position(|n| n == "this")
                {
                    if let Some(prior) = prior_this {
                        let mut cap = info.captures.borrow_mut();
                        if idx < cap.len() {
                            cap[idx] = prior;
                        }
                    }
                }
                return result;
            }
            return self.invoke_callable(callable, args, out);
        }
        Err(klio_runtime::RuntimeError::Unimplemented(format!(
            "Vm::invoke_callable_with_this on `{}`",
            callable.type_fqn()
        )))
    }

    fn scheduler(&mut self) -> &mut dyn klio_runtime::Scheduler {
        &mut *self.scheduler
    }

    fn lookup_global(&mut self, name: &str) -> Option<klio_runtime::Value> {
        self.globals.borrow().lookup(name)
    }

    fn invoke_method(
        &mut self,
        receiver: &klio_runtime::Value,
        name: &str,
        args: &[klio_runtime::Value],
        out: &mut dyn Output,
    ) -> Option<Result<klio_runtime::Value, klio_runtime::RuntimeError>> {
        // Build a VmHost that shares this IntrinsicHost's tables
        // and route through call_member so the dispatch picks up
        // user override methods (`override fun toString()` etc.).
        let mut host = self.vm_host(out);
        match <VmHost as klio_ir::eval::Host>::call_member(
            &mut host, receiver, name, args,
        ) {
            Ok(v) => Some(Ok(v)),
            Err(klio_ir::eval::EvalError::Throw(v)) => {
                Some(Err(klio_runtime::RuntimeError::Thrown(v)))
            }
            Err(_) => None,
        }
    }

    /// Spawn `block` on a real OS thread.
    ///
    /// The escaping value graph (`block` and the shared roots the
    /// child may observe) is `publish_deep`'d *before* the thread
    /// starts, which is the happens-before that `ObjRef`'s
    /// `unsafe impl Send` requires. Over-publishing is safe; cells
    /// the child creates after spawn are thread-local to it until it
    /// republishes them, which is fine.
    fn spawn_os_thread(
        &mut self,
        block: &klio_runtime::Value,
        _out: &mut dyn Output,
    ) -> Result<u64, klio_runtime::RuntimeError> {
        // Publish the escaping block and every shared root the child
        // can reach so observing them from the new thread is sound.
        block.publish_deep();
        klio_runtime::publish_env_deep(&self.globals);
        for def in self.classes.borrow().values() {
            klio_runtime::Value::Class(Arc::clone(def)).publish_deep();
        }
        for v in self.class_default_outer.borrow().values() {
            v.publish_deep();
        }
        self.classes.publish();
        self.anon_methods.publish();
        self.class_default_outer.publish();
        klio_runtime::fence_and_publish(); // thread start

        let seed = SendableVmSeed {
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
        };
        let block = block.clone();
        let time_mode = coroutine_time_mode();
        let id = self.instance_id_counter.fetch_add(1, AtomicOrdering::Relaxed);

        let handle = std::thread::Builder::new()
            .name(format!("klio-thread-{id}"))
            .spawn(move || -> Result<(), klio_runtime::RuntimeError> {
                set_coroutine_time_mode(time_mode);
                let mut vm = seed.materialize();
                let r = vm.run_thread_block(&block);
                klio_runtime::fence_and_publish(); // body completion → joiner
                match r {
                    Ok(v) => {
                        v.publish_deep();
                        Ok(())
                    }
                    Err(klio_runtime::RuntimeError::Return(v)) => {
                        v.publish_deep();
                        Ok(())
                    }
                    Err(e) => Err(e),
                }
            })
            .map_err(|e| {
                klio_runtime::RuntimeError::Type(format!(
                    "failed to spawn OS thread: {e}"
                ))
            })?;

        self.threads
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(id, ThreadEntry { handle: Some(handle) });
        Ok(id)
    }

    fn join_os_thread(&mut self, id: u64) -> Result<(), klio_runtime::RuntimeError> {
        let handle = {
            let mut g = self.threads.lock().unwrap_or_else(|e| e.into_inner());
            g.get_mut(&id).and_then(|e| e.handle.take())
        };
        let Some(handle) = handle else {
            // Already joined (idempotent) or unknown id — the
            // happens-before edge was established by the first join.
            return Ok(());
        };
        let res = handle.join().map_err(|_| {
            klio_runtime::RuntimeError::Type("spawned thread panicked".into())
        })?;
        klio_runtime::fence_and_publish(); // thread join
        res
    }

    fn os_thread_alive(&mut self, id: u64) -> bool {
        let g = self.threads.lock().unwrap_or_else(|e| e.into_inner());
        match g.get(&id) {
            Some(e) => e.handle.as_ref().map(|h| !h.is_finished()).unwrap_or(false),
            None => false,
        }
    }

    /// Dispatch a coroutine body onto the parallel worker pool.
    ///
    /// Realised as a real OS thread per job (reusing the spawned-
    /// thread publication + join machinery), but gated by a process-
    /// global counting semaphore so concurrency is bounded:
    /// `Dispatchers.Default` to the host core count, `Dispatchers.IO`
    /// to a large elastic cap. The escaping graph is `publish_deep`'d
    /// before the worker starts (the `ObjRef` `Send` happens-before);
    /// the worker parks on the gate, runs the body once a permit is
    /// free, then publishes its terminal value for the joiner.
    fn dispatch_coroutine(
        &mut self,
        block: &klio_runtime::Value,
        elastic: bool,
        _out: &mut dyn Output,
    ) -> Result<u64, klio_runtime::RuntimeError> {
        block.publish_deep();
        klio_runtime::publish_env_deep(&self.globals);
        for def in self.classes.borrow().values() {
            klio_runtime::Value::Class(Arc::clone(def)).publish_deep();
        }
        for v in self.class_default_outer.borrow().values() {
            v.publish_deep();
        }
        self.classes.publish();
        self.anon_methods.publish();
        self.class_default_outer.publish();
        klio_runtime::fence_and_publish(); // dispatch start

        let seed = SendableVmSeed {
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
        };
        let block = block.clone();
        let time_mode = coroutine_time_mode();
        let id = self.instance_id_counter.fetch_add(1, AtomicOrdering::Relaxed);
        let gate: &'static DispatchGate = if elastic { io_gate() } else { default_gate() };

        let handle = std::thread::Builder::new()
            .name(format!("klio-dispatch-{id}"))
            .spawn(move || -> Result<(), klio_runtime::RuntimeError> {
                // Bound concurrent bodies; the worker exists but only
                // executes Kotlin once it holds a pool permit.
                gate.acquire();
                set_coroutine_time_mode(time_mode);
                let mut vm = seed.materialize();
                let r = vm.run_thread_block(&block);
                klio_runtime::fence_and_publish(); // body completion → joiner
                gate.release();
                match r {
                    Ok(v) => {
                        v.publish_deep();
                        Ok(())
                    }
                    Err(klio_runtime::RuntimeError::Return(v)) => {
                        v.publish_deep();
                        Ok(())
                    }
                    Err(e) => Err(e),
                }
            })
            .map_err(|e| {
                klio_runtime::RuntimeError::Type(format!(
                    "failed to spawn dispatch worker: {e}"
                ))
            })?;

        self.threads
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(id, ThreadEntry { handle: Some(handle) });
        Ok(id)
    }

    fn join_dispatched(&mut self, id: u64) -> Result<(), klio_runtime::RuntimeError> {
        self.join_os_thread(id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use klio_ir::build::FuncBuilder;
    use klio_ir::{Const, Inst, Module, Terminator, TypeRef};

    #[derive(Default)]
    struct StringOut(String);

    impl Output for StringOut {
        fn writeln(&mut self, s: &str) {
            self.0.push_str(s);
            self.0.push('\n');
        }
        fn write(&mut self, s: &str) {
            self.0.push_str(s);
        }
    }

    #[test]
    fn vm_runs_simple_main_returns_const() {
        let mut module = Module::default();
        let mut b = FuncBuilder::new(&mut module);
        let r = b.emit_const(Const::Int(42));
        b.terminate(Terminator::Return(Some(r)));
        let main_func = b.finish("main", "main", TypeRef::int());
        let main_id = klio_ir::FuncId(module.funcs.len() as u32);
        let mut placed = main_func;
        placed.id = main_id;
        module.funcs.push(placed);
        module.func_index.push(("main".into(), main_id));
        module.top_level.push(main_id);

        let mut vm = Vm::new(Arc::new(module));
        let mut out = StringOut::default();
        let v = vm.run(main_id, &mut out).unwrap();
        match v {
            klio_runtime::Value::Int(42) => {}
            other => panic!("expected Int(42), got {other:?}"),
        }
    }

    #[test]
    fn vm_runs_println_via_intrinsic() {
        let mut module = Module::default();
        let mut b = FuncBuilder::new(&mut module);
        let callee = b.alloc_reg();
        let nm = b.module.intern_const(Const::String("println".into()));
        b.push(Inst::LoadGlobal { dst: callee, name: nm });
        let arg = b.emit_const(Const::String("hello".into()));
        let args_start = b.alloc_reg();
        b.push(Inst::Move { dst: args_start, src: arg });
        let dst = b.alloc_reg();
        b.push(Inst::CallValue {
            dst,
            callee,
            args: args_start,
            n_args: 1,
            arg_names: Vec::new(),
        });
        b.terminate(Terminator::Return(Some(dst)));
        let main_func = b.finish("main", "main", TypeRef::unit());
        let main_id = klio_ir::FuncId(module.funcs.len() as u32);
        let mut placed = main_func;
        placed.id = main_id;
        module.funcs.push(placed);
        module.func_index.push(("main".into(), main_id));
        module.top_level.push(main_id);

        let mut vm = Vm::new(Arc::new(module));
        let mut out = StringOut::default();
        vm.run(main_id, &mut out).unwrap();
        assert_eq!(out.0, "hello\n");
    }
}
