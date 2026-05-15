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
use std::rc::Rc;

pub use klio_runtime::Output;

pub mod build;

/// One Vm instance executes a single program against the IR module
/// produced by the front end.
pub struct Vm {
    module: Rc<klio_ir::Module>,
    globals: Rc<RefCell<klio_runtime::Env>>,
    scheduler: Box<dyn klio_runtime::Scheduler>,
    instance_id_counter: u64,
    /// Per-class runtime metadata produced by `build::build_module`.
    /// The Vm uses these for instance allocation. As IR Class
    /// expands to carry the full runtime shape this table shrinks
    /// and eventually goes away. Wrapped in RefCell so the Vm can
    /// register local classes encountered at runtime (Inst::RegisterClass).
    classes: Rc<RefCell<std::collections::HashMap<String, Rc<klio_runtime::ClassDef>>>>,
    /// Body-property initialiser FuncIds. Invoked during instance
    /// allocation to populate fields for `val/var x: T = expr`
    /// declared in a class body (not primary-ctor params).
    body_prop_inits:
        std::collections::HashMap<(String, String), klio_ir::FuncId>,
    /// Custom getter FuncIds. `Vm::get_field` invokes one when the
    /// receiver's runtime ClassDef declares a custom getter for
    /// the named property.
    instance_prop_getters:
        std::collections::HashMap<(String, String), klio_ir::FuncId>,
    /// Custom setter FuncIds. `Vm::set_field` invokes one when the
    /// receiver's runtime ClassDef declares a custom setter for
    /// the named property.
    instance_prop_setters:
        std::collections::HashMap<(String, String), klio_ir::FuncId>,
    /// Per-class parent-ctor arg thunks. `new_instance` invokes
    /// each thunk with the class's own primary args to compute the
    /// values passed to the parent's primary ctor.
    parent_ctor_args:
        std::collections::HashMap<String, Vec<klio_ir::FuncId>>,
    /// Per-class init-block FuncIds (each takes `this` as the sole
    /// param). `new_instance` runs them in declaration order after
    /// the parent-ctor chain + body-property init.
    init_blocks: std::collections::HashMap<String, Vec<klio_ir::FuncId>>,
    /// Top-level extension property getters keyed by
    /// `(receiver-type-simple-name, prop-name)`. `Vm::get_field`
    /// invokes the FuncId with the receiver as `this`.
    extension_props:
        std::collections::HashMap<(String, String), klio_ir::FuncId>,
    /// Top-level property initialiser FuncIds. Run at Vm::run start
    /// so globals see the initial values.
    top_level_props: Vec<(String, klio_ir::FuncId)>,
    /// Names of `object Foo { … }` singletons. Vm::run allocates one
    /// instance per name at startup (using the synthesised ClassDef in
    /// `classes`) and inserts it into globals so bare-name `Foo`
    /// references resolve.
    object_names: Vec<String>,
    /// Outer-class → companion singleton global name. Vm get_field /
    /// set_field on a `Value::Class` falls back to the companion
    /// instance's field when the name isn't on the class itself.
    companion_singletons: std::collections::HashMap<String, String>,
    /// Enum-entry ctor-arg thunks to evaluate at startup.
    enum_entry_arg_inits: Vec<(String, String, Vec<klio_ir::FuncId>)>,
    /// Per-class secondary-ctor dispatch entries.
    secondary_ctors:
        std::collections::HashMap<String, Vec<build::SecondaryCtorEntry>>,
    /// Per-class delegation expressions for `: I by g` supertypes.
    class_delegates:
        std::collections::HashMap<String, Vec<(String, klio_ir::FuncId)>>,
    /// Per-function default-arg thunk table.
    func_defaults:
        std::collections::HashMap<klio_ir::FuncId, Vec<Option<klio_ir::FuncId>>>,
    /// Runtime-lowered method bodies for anonymous-object / local
    /// classes, indexed by `(class name, method name) -> (Module, FuncId)`.
    /// The IR module is immutable after build, so methods declared
    /// inside runtime-built classes lower into per-method side
    /// modules and dispatch from this table.
    anon_methods: Rc<RefCell<std::collections::HashMap<
        (String, String),
        (Rc<klio_ir::Module>, klio_ir::FuncId, Vec<(String, klio_runtime::Value)>),
    >>>,
    /// Closure side-table. Each `Value::IrClosure { id, captures }`
    /// resolves to a `(body_func, n_params)` here. `n_params` lets
    /// the dispatch fill missing positional args with `Null` (for
    /// implicit-`it` shapes that pass 0 args).
    closures: Vec<ClosureInfo>,
}

#[derive(Clone)]
struct ClosureInfo {
    body_func: klio_ir::FuncId,
    n_params: usize,
    /// Capture names, in the same order as the runtime captures
    /// vec. Lets the Vm's `read_lambda_capture` host method map a
    /// name back to the captured value index.
    capture_names: Vec<String>,
    /// Live capture values. Stored as Rc<RefCell<...>> so the
    /// lambda body's StoreGlobal writes propagate (the dispatch
    /// path layers each captured name into a per-call env, then
    /// reads back into this vec). The outer-frame
    /// WritebackCaptures Inst observes the updated values via
    /// `read_lambda_capture`.
    captures: Rc<RefCell<Vec<klio_runtime::Value>>>,
}

impl Vm {
    /// Build a Vm around an already-lowered IR module. Stdlib
    /// aliases (`print`, `println`, `listOf`, ...) are installed
    /// into globals up front so identifiers covered by Kotlin's
    /// default imports resolve without an explicit `import`.
    pub fn new(module: Rc<klio_ir::Module>) -> Self {
        let mut env = klio_runtime::Env::new();
        for (name, fqn) in klio_stdlib::IMPLICIT_ALIASES {
            if let Some(func) = klio_stdlib::implementation(fqn) {
                env.define(*name, klio_runtime::Value::Intrinsic { fqn, func });
            }
        }
        let globals = Rc::new(RefCell::new(env));
        Self {
            module,
            globals,
            scheduler: Box::new(klio_runtime::InProcessScheduler::new()),
            instance_id_counter: 0,
            classes: Rc::new(RefCell::new(std::collections::HashMap::new())),
            body_prop_inits: std::collections::HashMap::new(),
            instance_prop_getters: std::collections::HashMap::new(),
            instance_prop_setters: std::collections::HashMap::new(),
            parent_ctor_args: std::collections::HashMap::new(),
            init_blocks: std::collections::HashMap::new(),
            extension_props: std::collections::HashMap::new(),
            top_level_props: Vec::new(),
            object_names: Vec::new(),
            companion_singletons: std::collections::HashMap::new(),
            enum_entry_arg_inits: Vec::new(),
            secondary_ctors: std::collections::HashMap::new(),
            class_delegates: std::collections::HashMap::new(),
            func_defaults: std::collections::HashMap::new(),
            anon_methods: Rc::new(RefCell::new(std::collections::HashMap::new())),
            closures: Vec::new(),
        }
    }

    /// Build a Vm from a fully-prepared `build::BuiltModule`. The
    /// recommended entry point for the driver — it carries both the
    /// IR module and the synthesised runtime ClassDef table.
    pub fn from_built(built: build::BuiltModule) -> (Self, Option<klio_ir::FuncId>) {
        let main = built.main;
        let mut vm = Self::new(built.module);
        vm.classes = Rc::new(RefCell::new(built.classes));
        vm.body_prop_inits = built.body_prop_inits;
        vm.instance_prop_getters = built.instance_prop_getters;
        vm.instance_prop_setters = built.instance_prop_setters;
        vm.parent_ctor_args = built.parent_ctor_args;
        vm.init_blocks = built.init_blocks;
        vm.extension_props = built.extension_props;
        vm.top_level_props = built.top_level_props;
        vm.object_names = built.object_names;
        vm.companion_singletons = built.companion_singletons;
        vm.enum_entry_arg_inits = built.enum_entry_arg_inits;
        vm.secondary_ctors = built.secondary_ctors;
        vm.class_delegates = built.class_delegates;
        vm.func_defaults = built.func_defaults;
        (vm, main)
    }

    /// Run the program's `main` function. Stdout is routed through
    /// `out`. Returns the value `main` returned (typically Unit).
    pub fn run(
        &mut self,
        main: klio_ir::FuncId,
        out: &mut dyn Output,
    ) -> Result<klio_runtime::Value, VmError> {
        let module = Rc::clone(&self.module);
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
                let mut host = VmHost {
                    globals: Rc::clone(&self.globals),
                    module: Rc::clone(&module),
                    scheduler: &mut *self.scheduler,
                    out,
                    instance_id_counter: &mut self.instance_id_counter,
                    classes: Rc::clone(&self.classes),
                    body_prop_inits: &self.body_prop_inits,
                    instance_prop_getters: &self.instance_prop_getters,
                    instance_prop_setters: &self.instance_prop_setters,
                    parent_ctor_args: &self.parent_ctor_args,
                    init_blocks: &self.init_blocks,
                    extension_props: &self.extension_props,
                    anon_methods: Rc::clone(&self.anon_methods),
                    companion_singletons: &self.companion_singletons,
                    secondary_ctors: &self.secondary_ctors,
                    class_delegates: &self.class_delegates,
                    func_defaults: &self.func_defaults,
                    closures: &mut self.closures,
                };
                klio_ir::eval::eval_with(&module, &init_func, Vec::new(), &mut host)
                    .map_err(VmError::from)?
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
                    let mut host = VmHost {
                        globals: Rc::clone(&self.globals),
                        module: Rc::clone(&module),
                        scheduler: &mut *self.scheduler,
                        out,
                        instance_id_counter: &mut self.instance_id_counter,
                        classes: Rc::clone(&self.classes),
                        body_prop_inits: &self.body_prop_inits,
                        instance_prop_getters: &self.instance_prop_getters,
                        instance_prop_setters: &self.instance_prop_setters,
                        parent_ctor_args: &self.parent_ctor_args,
                        init_blocks: &self.init_blocks,
                        extension_props: &self.extension_props,
                        anon_methods: Rc::clone(&self.anon_methods),
                        companion_singletons: &self.companion_singletons,
                    secondary_ctors: &self.secondary_ctors,
                    class_delegates: &self.class_delegates,
                    func_defaults: &self.func_defaults,
                        closures: &mut self.closures,
                    };
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
        let object_names: Vec<String> = self.object_names.clone();
        for obj_name in &object_names {
            let class_id = match module.class_id(obj_name) {
                Some(id) => id,
                None => continue,
            };
            let inst = {
                let mut host = VmHost {
                    globals: Rc::clone(&self.globals),
                    module: Rc::clone(&module),
                    scheduler: &mut *self.scheduler,
                    out,
                    instance_id_counter: &mut self.instance_id_counter,
                    classes: Rc::clone(&self.classes),
                    body_prop_inits: &self.body_prop_inits,
                    instance_prop_getters: &self.instance_prop_getters,
                    instance_prop_setters: &self.instance_prop_setters,
                    parent_ctor_args: &self.parent_ctor_args,
                    init_blocks: &self.init_blocks,
                    extension_props: &self.extension_props,
                    anon_methods: Rc::clone(&self.anon_methods),
                    companion_singletons: &self.companion_singletons,
                    secondary_ctors: &self.secondary_ctors,
                    class_delegates: &self.class_delegates,
                    func_defaults: &self.func_defaults,
                    closures: &mut self.closures,
                };
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
        let mut host = VmHost {
            globals: Rc::clone(&self.globals),
            module: Rc::clone(&module),
            scheduler: &mut *self.scheduler,
            out,
            instance_id_counter: &mut self.instance_id_counter,
            classes: Rc::clone(&self.classes),
            body_prop_inits: &self.body_prop_inits,
            instance_prop_getters: &self.instance_prop_getters,
            instance_prop_setters: &self.instance_prop_setters,
            parent_ctor_args: &self.parent_ctor_args,
            init_blocks: &self.init_blocks,
            extension_props: &self.extension_props,
            anon_methods: Rc::clone(&self.anon_methods),
            companion_singletons: &self.companion_singletons,
            secondary_ctors: &self.secondary_ctors,
            class_delegates: &self.class_delegates,
            func_defaults: &self.func_defaults,
            closures: &mut self.closures,
        };
        klio_ir::eval::eval_with(&module, &func, Vec::new(), &mut host).map_err(VmError::from)
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
    globals: Rc<RefCell<klio_runtime::Env>>,
    module: Rc<klio_ir::Module>,
    scheduler: &'a mut dyn klio_runtime::Scheduler,
    out: &'a mut dyn Output,
    instance_id_counter: &'a mut u64,
    classes: Rc<RefCell<std::collections::HashMap<String, Rc<klio_runtime::ClassDef>>>>,
    body_prop_inits:
        &'a std::collections::HashMap<(String, String), klio_ir::FuncId>,
    instance_prop_getters:
        &'a std::collections::HashMap<(String, String), klio_ir::FuncId>,
    instance_prop_setters:
        &'a std::collections::HashMap<(String, String), klio_ir::FuncId>,
    parent_ctor_args:
        &'a std::collections::HashMap<String, Vec<klio_ir::FuncId>>,
    init_blocks: &'a std::collections::HashMap<String, Vec<klio_ir::FuncId>>,
    extension_props:
        &'a std::collections::HashMap<(String, String), klio_ir::FuncId>,
    anon_methods: Rc<RefCell<std::collections::HashMap<
        (String, String),
        (Rc<klio_ir::Module>, klio_ir::FuncId, Vec<(String, klio_runtime::Value)>),
    >>>,
    companion_singletons: &'a std::collections::HashMap<String, String>,
    secondary_ctors:
        &'a std::collections::HashMap<String, Vec<build::SecondaryCtorEntry>>,
    class_delegates:
        &'a std::collections::HashMap<String, Vec<(String, klio_ir::FuncId)>>,
    func_defaults:
        &'a std::collections::HashMap<klio_ir::FuncId, Vec<Option<klio_ir::FuncId>>>,
    closures: &'a mut Vec<ClosureInfo>,
}

impl<'a> VmHost<'a> {
    /// Drive a lazy `Value::Sequence` to completion. Each upstream
    /// item flows through the pipeline ops by invoking the user
    /// lambdas via `self.call_value`. Sorting ops buffer-and-emit.
    fn materialise_sequence(
        &mut self,
        seq_val: &klio_runtime::Value,
    ) -> Result<Vec<klio_runtime::Value>, klio_ir::eval::EvalError> {
        use klio_ir::eval::Host as _;
        let klio_runtime::Value::Sequence(seq) = seq_val else {
            return Err(klio_ir::eval::EvalError::Type(
                "materialise_sequence: not a Sequence".into(),
            ));
        };
        let mut items: Vec<klio_runtime::Value> = match &seq.source {
            klio_runtime::SequenceSource::Items(v) => (**v).clone(),
            klio_runtime::SequenceSource::Generate { seed, next } => {
                let mut out: Vec<klio_runtime::Value> = Vec::new();
                let limit = 1024usize;
                let mut cur = seed.as_ref().map(|b| (**b).clone());
                while out.len() < limit {
                    let candidate = match &cur {
                        Some(v) => v.clone(),
                        None => {
                            let r = self.call_value(next, &[])?;
                            if matches!(r, klio_runtime::Value::Null) {
                                break;
                            }
                            r
                        }
                    };
                    out.push(candidate.clone());
                    let r = self.call_value(next, std::slice::from_ref(&candidate))?;
                    if matches!(r, klio_runtime::Value::Null) {
                        break;
                    }
                    cur = Some(r);
                }
                out
            }
        };
        for op in seq.ops.iter() {
            match op {
                klio_runtime::SeqOp::Map(f) => {
                    let mut next: Vec<klio_runtime::Value> = Vec::with_capacity(items.len());
                    for v in &items {
                        next.push(self.call_value(f, std::slice::from_ref(v))?);
                    }
                    items = next;
                }
                klio_runtime::SeqOp::Filter(f) => {
                    let mut next: Vec<klio_runtime::Value> = Vec::new();
                    for v in &items {
                        if matches!(
                            self.call_value(f, std::slice::from_ref(v))?,
                            klio_runtime::Value::Bool(true)
                        ) {
                            next.push(v.clone());
                        }
                    }
                    items = next;
                }
                klio_runtime::SeqOp::FilterNot(f) => {
                    let mut next: Vec<klio_runtime::Value> = Vec::new();
                    for v in &items {
                        if !matches!(
                            self.call_value(f, std::slice::from_ref(v))?,
                            klio_runtime::Value::Bool(true)
                        ) {
                            next.push(v.clone());
                        }
                    }
                    items = next;
                }
                klio_runtime::SeqOp::Take(n) => {
                    let n = *n as usize;
                    if n < items.len() {
                        items.truncate(n);
                    }
                }
                klio_runtime::SeqOp::Drop(n) => {
                    let n = (*n as usize).min(items.len());
                    items.drain(..n);
                }
                klio_runtime::SeqOp::TakeWhile(f) => {
                    let mut cutoff = items.len();
                    for (i, v) in items.iter().enumerate() {
                        if !matches!(
                            self.call_value(f, std::slice::from_ref(v))?,
                            klio_runtime::Value::Bool(true)
                        ) {
                            cutoff = i;
                            break;
                        }
                    }
                    items.truncate(cutoff);
                }
                klio_runtime::SeqOp::DropWhile(f) => {
                    let mut start = 0usize;
                    while start < items.len() {
                        let v = items[start].clone();
                        if !matches!(
                            self.call_value(f, std::slice::from_ref(&v))?,
                            klio_runtime::Value::Bool(true)
                        ) {
                            break;
                        }
                        start += 1;
                    }
                    items.drain(..start);
                }
                klio_runtime::SeqOp::FlatMap(f) => {
                    let mut next: Vec<klio_runtime::Value> = Vec::new();
                    for v in &items {
                        let mapped = self.call_value(f, std::slice::from_ref(v))?;
                        match mapped {
                            klio_runtime::Value::List { items: xs, .. }
                            | klio_runtime::Value::Set { items: xs, .. } => {
                                next.extend(xs.borrow().iter().cloned());
                            }
                            klio_runtime::Value::Sequence(_) => {
                                let inner = self.materialise_sequence(&mapped)?;
                                next.extend(inner);
                            }
                            _ => next.push(mapped),
                        }
                    }
                    items = next;
                }
                klio_runtime::SeqOp::Distinct => {
                    let mut seen: Vec<klio_runtime::Value> = Vec::new();
                    let mut next: Vec<klio_runtime::Value> = Vec::new();
                    for v in &items {
                        if !seen.iter().any(|s| klio_runtime::Value::structural_eq(s, v)) {
                            seen.push(v.clone());
                            next.push(v.clone());
                        }
                    }
                    items = next;
                }
                klio_runtime::SeqOp::DistinctBy(f) => {
                    let mut seen: Vec<klio_runtime::Value> = Vec::new();
                    let mut next: Vec<klio_runtime::Value> = Vec::new();
                    for v in &items {
                        let key = self.call_value(f, std::slice::from_ref(v))?;
                        if !seen.iter().any(|s| klio_runtime::Value::structural_eq(s, &key)) {
                            seen.push(key);
                            next.push(v.clone());
                        }
                    }
                    items = next;
                }
                klio_runtime::SeqOp::Sorted(descending) => {
                    let descending = *descending;
                    let mut err: Option<klio_ir::eval::EvalError> = None;
                    items.sort_by(|a, b| {
                        if err.is_some() {
                            return std::cmp::Ordering::Equal;
                        }
                        match klio_stdlib::compare_values(a, b) {
                            Ok(o) => if descending { o.reverse() } else { o },
                            Err(e) => {
                                err = Some(klio_ir::eval::EvalError::Type(format!("{e}")));
                                std::cmp::Ordering::Equal
                            }
                        }
                    });
                    if let Some(e) = err {
                        return Err(e);
                    }
                }
                klio_runtime::SeqOp::SortedBy(f, descending) => {
                    let descending = *descending;
                    let mut keyed: Vec<(klio_runtime::Value, klio_runtime::Value)> =
                        Vec::with_capacity(items.len());
                    for v in items.drain(..) {
                        let k = self.call_value(f, std::slice::from_ref(&v))?;
                        keyed.push((k, v));
                    }
                    let mut err: Option<klio_ir::eval::EvalError> = None;
                    keyed.sort_by(|a, b| {
                        if err.is_some() {
                            return std::cmp::Ordering::Equal;
                        }
                        match klio_stdlib::compare_values(&a.0, &b.0) {
                            Ok(o) => if descending { o.reverse() } else { o },
                            Err(e) => {
                                err = Some(klio_ir::eval::EvalError::Type(format!("{e}")));
                                std::cmp::Ordering::Equal
                            }
                        }
                    });
                    if let Some(e) = err {
                        return Err(e);
                    }
                    items = keyed.into_iter().map(|(_, v)| v).collect();
                }
                klio_runtime::SeqOp::SortedWith(comparator) => {
                    let comp = comparator.clone();
                    let mut err: Option<klio_ir::eval::EvalError> = None;
                    // Insertion sort so the comparator callback can
                    // dispatch back through the Vm via call_member.
                    for i in 1..items.len() {
                        let mut j = i;
                        while j > 0 && err.is_none() {
                            let a = items[j - 1].clone();
                            let b = items[j].clone();
                            let ord_val = match
                                <Self as klio_ir::eval::Host>::call_member(self, &comp, "compare", &[a, b])
                            {
                                Ok(v) => v,
                                Err(e) => { err = Some(e); break; }
                            };
                            let n = ord_val.as_i64().unwrap_or(0);
                            if n > 0 {
                                items.swap(j - 1, j);
                                j -= 1;
                            } else {
                                break;
                            }
                        }
                    }
                    if let Some(e) = err {
                        return Err(e);
                    }
                }
            }
        }
        Ok(items)
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
        let module_for_intrinsic = Rc::clone(&self.module);
        let mut intrinsic_host = VmIntrinsicHost {
            scheduler: &mut *self.scheduler,
            module: module_for_intrinsic,
            closures: &mut *self.closures,
            globals: Rc::clone(&self.globals),
            classes: Rc::clone(&self.classes),
            body_prop_inits: self.body_prop_inits,
            instance_prop_getters: self.instance_prop_getters,
            instance_prop_setters: self.instance_prop_setters,
            parent_ctor_args: self.parent_ctor_args,
            init_blocks: self.init_blocks,
            extension_props: self.extension_props,
            anon_methods: Rc::clone(&self.anon_methods),
            companion_singletons: self.companion_singletons,
            secondary_ctors: self.secondary_ctors,
            class_delegates: self.class_delegates,
            func_defaults: self.func_defaults,
            instance_id_counter: &mut *self.instance_id_counter,
        };
        let mut ctx = klio_runtime::CallCtx {
            args,
            out: self.out,
            host: &mut intrinsic_host,
        };
        func(&mut ctx).map_err(|e| match e {
            // Preserve the thrown Value so the IR evaluator's
            // try/catch can match the handler against the exception
            // class. Stringifying here would break `try { … } catch`.
            klio_runtime::RuntimeError::Thrown(v) => klio_ir::eval::EvalError::Throw(v),
            other => klio_ir::eval::EvalError::Type(format!("{other}")),
        })
    }
}

impl<'a> klio_ir::eval::Host for VmHost<'a> {
    fn lookup_global(&mut self, name: &str) -> Option<klio_runtime::Value> {
        let cached = self.globals.borrow().lookup(name);
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
            let id = self.closures.len() as u64;
            self.closures.push(ClosureInfo {
                body_func: fid,
                n_params,
                capture_names: Vec::new(),
                captures: Rc::new(RefCell::new(Vec::new())),
            });
            return Some(klio_runtime::Value::IrClosure {
                id,
                captures: Rc::new(Vec::new()),
            });
        }
        // Probe stdlib by FQN for known package surfaces. Covers
        // bare references to `IntArray`, `compareBy`, `buildList`,
        // `naturalOrder`, `PI`, etc. that aren't in IMPLICIT_ALIASES.
        let direct_probes: [String; 7] = [
            name.to_string(),
            format!("kotlin.{name}"),
            format!("kotlin.collections.{name}"),
            format!("kotlin.text.{name}"),
            format!("kotlin.ranges.{name}"),
            format!("kotlin.math.{name}"),
            format!("kotlin.comparisons.{name}"),
        ];
        for fqn in &direct_probes {
            if let Some(func) = klio_stdlib::implementation(fqn) {
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
        // Primitive-companion constants (`Int.MAX_VALUE`, `Double.NaN`,
        // `Long.SIZE_BITS`, …). The IR lowers these as a single
        // dotted-name global ref; we split on `.` and consult the
        // stdlib's primitive-companion table.
        if let Some((ty, member)) = name.split_once('.') {
            if let Some(v) = klio_stdlib::primitive_companion_const(ty, member) {
                return Some(v);
            }
        }
        None
    }

    fn store_global(
        &mut self,
        name: &str,
        value: klio_runtime::Value,
    ) -> Result<(), klio_ir::eval::EvalError> {
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
                        name: Rc::new(name.to_string()),
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
                        fqn: Rc::new("kotlin.IllegalStateException".to_string()),
                        message: Some(Rc::new(format!(
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
            *self.instance_id_counter += 1;
            let identity = *self.instance_id_counter;
            let mut fields: Vec<(String, klio_runtime::Value)> =
                Vec::with_capacity(cls.primary_params.len());
            for (param, value) in cls.primary_params.iter().zip(args.iter()) {
                if param.property.is_some() {
                    fields.push((param.name.clone(), value.clone()));
                }
            }
            let inst = Rc::new(RefCell::new(klio_runtime::InstanceData {
                class: Rc::clone(cls),
                fields,
                outer: None,
                identity,
                native_state: None,
            }));
            return Ok(klio_runtime::Value::Instance(inst));
        }
        // `propRef(receiver)` — invoking a Value::PropertyRef as a
        // callable reads the named field from the first arg.
        if let klio_runtime::Value::PropertyRef { name } = callee {
            if args.len() == 1 {
                return self.get_field(&args[0], name);
            }
        }
        if let klio_runtime::Value::IrClosure { id, captures } = callee {
            let info = self.closures.get(*id as usize).cloned().ok_or_else(|| {
                klio_ir::eval::EvalError::Type(format!("unknown IrClosure id {id}"))
            })?;
            let module = Rc::clone(&self.module);
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
            // Fill missing positional args with Null so an
            // implicit-`it` lambda invoked with zero args still
            // initialises the param slot. Pack trailing vararg
            // args into an Array when the target's last param is
            // marked vararg.
            let mut call_args: Vec<klio_runtime::Value> = Vec::with_capacity(info.n_params);
            for i in 0..info.n_params {
                call_args.push(args.get(i).cloned().unwrap_or(klio_runtime::Value::Null));
            }
            if let Some(last) = func.params.last() {
                if last.is_vararg && args.len() > info.n_params {
                    let mut packed: Vec<klio_runtime::Value> = Vec::new();
                    let fixed = info.n_params.saturating_sub(1);
                    packed.extend(args[fixed..].iter().cloned());
                    call_args[info.n_params - 1] = klio_runtime::Value::Array {
                        items: Rc::new(RefCell::new(packed)),
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
                        items: Rc::new(RefCell::new(packed)),
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
                        items: Rc::new(RefCell::new(items)),
                        mutable: false,
                        enum_class: Some(Rc::new(cls.name.clone())),
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
        // Companion-object forwarding: `Foo.PI` reads `PI` from the
        // companion singleton when the receiver is the user class.
        // Enum entries (`Color.RED`) take precedence above; reaching
        // here means the name isn't an entry.
        if let klio_runtime::Value::Class(cls) = receiver {
            if let Some(comp_name) = self.companion_singletons.get(&cls.name).cloned() {
                // `Counter.Factory` — the user-declared companion
                // name resolves to the companion singleton itself.
                let suffix = format!("$Companion${}", name);
                if comp_name.ends_with(&suffix) {
                    if let Some(s) = self.globals.borrow().lookup(&comp_name) {
                        return Ok(s);
                    }
                }
                if let Some(singleton) = self.globals.borrow().lookup(&comp_name) {
                    if let klio_runtime::Value::Instance(inst) = &singleton {
                        if let Some(v) = inst.borrow().get(name) {
                            return Ok(v);
                        }
                    }
                }
            }
            // Nested-class access on a class receiver: `Outer.Inner`
            // and `Sealed.Variant` resolve through the module's
            // global class table.
            if let Some(def) = self.classes.borrow().get(name).cloned() {
                return Ok(klio_runtime::Value::Class(def));
            }
            // Nested singleton object: `Sealed.Subclass` may be a
            // synthesised object singleton stored as a global.
            if let Some(v) = self.globals.borrow().lookup(name) {
                if matches!(v, klio_runtime::Value::Instance(_)) {
                    return Ok(v);
                }
            }
            let _ = cls;
        }
        // Top-level extension property: `val T.name get() = ...`
        // — keyed by (receiver simple type, prop name). Falls
        // through to the standard lookup chain when the user
        // didn't declare an extension property for this combo.
        {
            let type_fqn = receiver.type_fqn();
            let recv_simple: String = type_fqn
                .rsplit('.')
                .next()
                .unwrap_or(type_fqn)
                .to_string();
            if let Some(fid) = self
                .extension_props
                .get(&(recv_simple, name.to_string()))
                .copied()
            {
                let func = self.module.funcs.get(fid.0 as usize).cloned().ok_or_else(|| {
                    klio_ir::eval::EvalError::Type(format!(
                        "extension prop FuncId {} out of range",
                        fid.0
                    ))
                })?;
                let module = Rc::clone(&self.module);
                return klio_ir::eval::eval_with(&module, &func, vec![receiver.clone()], self);
            }
        }
        // Reflection-style property/class accessors on the
        // synthetic KClass / KProperty values.
        match receiver {
            klio_runtime::Value::Class(cls) => match name {
                "simpleName" => {
                    return Ok(klio_runtime::Value::String(Rc::new(cls.name.clone())));
                }
                "qualifiedName" => {
                    return Ok(klio_runtime::Value::String(Rc::new(cls.fqn.clone())));
                }
                _ => {}
            },
            klio_runtime::Value::PropertyRef { name: pname } => match name {
                "name" | "simpleName" => {
                    return Ok(klio_runtime::Value::String(Rc::clone(pname)));
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
            if let Some(fid) = self
                .instance_prop_getters
                .get(&(class_name.clone(), name.to_string()))
                .copied()
            {
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
                let module = Rc::clone(&self.module);
                return klio_ir::eval::eval_with(&module, &func, vec![receiver.clone()], self);
            }
            if let Some(v) = inst.borrow().get(name) {
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
                                        fqn: Rc::new(
                                            "kotlin.IllegalStateException".into(),
                                        ),
                                        message: Some(Rc::new(format!(
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
            let mut queue: Vec<Rc<klio_runtime::ClassDef>> =
                vec![inst.borrow().class.clone()];
            let mut visited: std::collections::HashSet<String> =
                std::collections::HashSet::new();
            while let Some(c) = queue.pop() {
                if !visited.insert(c.name.clone()) {
                    continue;
                }
                if let Some(comp_name) = self.companion_singletons.get(&c.name).cloned() {
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
                    queue.push(Rc::clone(ifc));
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
                    klio_runtime::Value::Class(_) => {
                        if let Ok(v) = self.get_field(&o, name) {
                            return Ok(v);
                        }
                        cur_outer = None;
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
                        items: Rc::new(RefCell::new(items)),
                        mutable: false,
                        enum_class: Some(Rc::new(class_def.name.clone())),
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
            format!("kotlin.{name}"),
        ];
        for probe in &probes {
            if let Some(func) = klio_stdlib::implementation(probe) {
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
            if let Some(comp_name) = self.companion_singletons.get(&cls.name).cloned() {
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
        if let klio_runtime::Value::Instance(inst) = receiver {
            if !bypass_setter {
                let class_name = inst.borrow().class.name.clone();
                if let Some(fid) = self
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
                    let module = Rc::clone(&self.module);
                    klio_ir::eval::eval_with(
                        &module,
                        &func,
                        vec![receiver.clone(), value],
                        self,
                    )?;
                    return Ok(());
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
        // Foo::method / instance::method — produce a callable
        // closure that, when invoked, dispatches the named member
        // on the receiver. Bound-method closures store the
        // receiver as a capture and forward call args to
        // call_member.
        let captures = vec![receiver.clone()];
        let id = self.closures.len() as u64;
        // Synthesize a 0-Func body that's just a dispatcher.
        // Since the closure infrastructure expects an IR FuncId,
        // and we don't want to lower a new Func per ref, return
        // a Value::BoundMethod-style PropertyRef-ish handle. For
        // a usable runtime value we instead use a Value::Lambda
        // with a synthetic dispatcher body — too much. Simplest
        // is to return Value::PropertyRef as a stand-in (the
        // value implements `.name` etc.) until reflection lands.
        let _ = captures;
        let _ = id;
        Ok(klio_runtime::Value::PropertyRef {
            name: Rc::new(name.to_string()),
        })
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
                default: p.default.as_ref().map(|e| Rc::new(e.clone())),
            })
            .collect();
        let body_properties: Vec<klio_runtime::PropertyDef> = class
            .members
            .iter()
            .filter_map(|m| match m {
                klio_ast::Decl::Property(p) => Some(klio_runtime::PropertyDef {
                    name: p.name.name.clone(),
                    mutable: p.mutable,
                    init: p.init.as_ref().map(|e| Rc::new(e.clone())),
                    getter: p.getter.as_ref().map(|a| Rc::new(a.clone())),
                    setter: p.setter.as_ref().map(|a| Rc::new(a.clone())),
                    delegate: p.delegate.as_ref().map(|e| Rc::new(e.clone())),
                    is_abstract: p.is_abstract,
                    is_lateinit: p.is_lateinit,
                }),
                _ => None,
            })
            .collect();
        let def = Rc::new(klio_runtime::ClassDef {
            name: class.name.name.clone(),
            fqn: class.name.name.clone(),
            annotation_names: Vec::new(),
            primary_params,
            methods: Vec::new(),
            body_properties,
            init_blocks: Vec::new(),
            is_data: class.is_data,
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
            parent: RefCell::new(None),
            interfaces: RefCell::new(Vec::new()),
            is_interface: class.is_interface,
            is_fun_interface: class.is_fun_interface,
            parent_ctor_args: Vec::new(),
            enum_entries: RefCell::new(Vec::new()),
            companion: RefCell::new(None),
            enclosing_class: RefCell::new(None),
            nested_classes: RefCell::new(Vec::new()),
            captured_env: Rc::new(RefCell::new(klio_runtime::Env::new())),
            supertype_delegates: RefCell::new(Vec::new()),
            delegate_forwarders: RefCell::new(Vec::new()),
            object_singleton: RefCell::new(None),
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
                let module_rc = Rc::new(sub_module);
                self.anon_methods.borrow_mut().insert(
                    (class.name.name.clone(), f.name.name.clone()),
                    (module_rc, fid, Vec::new()),
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
                let key = (class.name.name.clone(), f.name.name.clone());
                if let Some(entry) = tbl.get_mut(&key) {
                    entry.2 = capture_pairs.clone();
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
        if let klio_ast::Expr::ObjectExpr { members, supertypes, .. } = ast {
            *self.instance_id_counter += 1;
            let identity = *self.instance_id_counter;
            // Lower each method body into a per-method side
            // module + FuncId. dispatch at call_member time.
            let synth_class_name = format!("$anon${identity}");
            // Collect the anon object's own member names so bare
            // identifiers inside method bodies resolve through this.
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
                    let module_rc = Rc::new(sub_module);
                    self.anon_methods.borrow_mut().insert(
                        (synth_class_name.clone(), f.name.name.clone()),
                        (module_rc, fid, capture_pairs.clone()),
                    );
                }
            }
            let body_properties: Vec<klio_runtime::PropertyDef> = members
                .iter()
                .filter_map(|m| match m {
                    klio_ast::Decl::Property(p) => Some(klio_runtime::PropertyDef {
                        name: p.name.name.clone(),
                        mutable: p.mutable,
                        init: p.init.as_ref().map(|e| Rc::new(e.clone())),
                        getter: p.getter.as_ref().map(|a| Rc::new(a.clone())),
                        setter: p.setter.as_ref().map(|a| Rc::new(a.clone())),
                        delegate: p.delegate.as_ref().map(|e| Rc::new(e.clone())),
                        is_abstract: p.is_abstract,
                        is_lateinit: p.is_lateinit,
                    }),
                    _ => None,
                })
                .collect();
            let supertype_names: Vec<String> =
                supertypes.iter().map(|t| t.name.name.clone()).collect();
            let class_def = Rc::new(klio_runtime::ClassDef {
                name: format!("$anon${identity}"),
                fqn: format!("$anon${identity}"),
                annotation_names: Vec::new(),
                primary_params: Vec::new(),
                methods: Vec::new(),
                body_properties,
                init_blocks: Vec::new(),
                is_data: false,
                is_object: false,
                is_enum: false,
                is_sealed: false,
                is_open: false,
                is_abstract: false,
                is_inner: false,
                is_anonymous: true,
                secondary_ctors: Vec::new(),
                supertype_names,
                parent: RefCell::new(None),
                interfaces: RefCell::new(Vec::new()),
                is_interface: false,
                is_fun_interface: false,
                parent_ctor_args: Vec::new(),
                enum_entries: RefCell::new(Vec::new()),
                companion: RefCell::new(None),
                enclosing_class: RefCell::new(None),
                nested_classes: RefCell::new(Vec::new()),
                captured_env: Rc::new(RefCell::new(klio_runtime::Env::new())),
                supertype_delegates: RefCell::new(Vec::new()),
                delegate_forwarders: RefCell::new(Vec::new()),
                object_singleton: RefCell::new(None),
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
            let inst = Rc::new(RefCell::new(klio_runtime::InstanceData {
                class: class_def,
                fields,
                outer: None,
                identity,
                native_state: None,
            }));
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
            Some(q.to_string())
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
                            let module = Rc::clone(&self.module);
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
            let mut cur: Option<Rc<klio_runtime::ClassDef>> =
                Some(Rc::clone(&inst.borrow().class));
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
                    return Ok(klio_runtime::Value::Instance(Rc::clone(&o_inst)));
                }
                let mut p = cls.parent.borrow().clone();
                while let Some(c) = p {
                    if c.name == qualifier || c.fqn == qualifier {
                        return Ok(klio_runtime::Value::Instance(Rc::clone(&o_inst)));
                    }
                    p = c.parent.borrow().clone();
                }
                outer = o_inst.borrow().outer.clone();
            }
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
        // `Any` is the universal supertype: every non-null value
        // is an instance of `Any` (nullable matters separately).
        if ty.name == "Any" {
            return !matches!(value, klio_runtime::Value::Null);
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
                    | ("RuntimeException", "Exception")
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
            let mut cur: Option<Rc<klio_runtime::ClassDef>> =
                Some(Rc::clone(&inst.borrow().class));
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
        // Pad missing positional args with each param's default
        // value (from the registered default-init thunks).
        let mut args = args;
        if args.len() < f.params.len() {
            if let Some(defaults) = self.func_defaults.get(&func).cloned() {
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
                        let v = klio_ir::eval::eval_with(module, &dfunc, Vec::new(), self)?;
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
        _arg_names: &[Option<String>],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        self.call_func(module, func, args)
    }

    fn call_func_typed(
        &mut self,
        module: &klio_ir::Module,
        func: klio_ir::FuncId,
        args: Vec<klio_runtime::Value>,
        arg_names: &[Option<String>],
        _type_args: &[String],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        self.call_func_named(module, func, args, arg_names)
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
        let id = self.closures.len() as u64;
        let cell = Rc::new(RefCell::new(captures.clone()));
        self.closures.push(ClosureInfo {
            body_func,
            n_params: params.len(),
            capture_names: captured_names.to_vec(),
            captures: cell,
        });
        Ok(klio_runtime::Value::IrClosure {
            id,
            captures: Rc::new(captures),
        })
    }

    fn read_lambda_capture(
        &mut self,
        lambda: &klio_runtime::Value,
        name: &str,
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        if let klio_runtime::Value::IrClosure { id, .. } = lambda {
            let info = self.closures.get(*id as usize).cloned().ok_or_else(|| {
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
        // `Delegates.notNull` / `Delegates.observable` /
        // `Delegates.vetoable` — synthesise the proper
        // `Value::Delegate` directly. The singleton itself is
        // surfaced via `lookup_global` as a sentinel Intrinsic.
        if let klio_runtime::Value::Intrinsic { fqn, .. } = receiver {
            if *fqn == "kotlin.properties.Delegates" {
                match (name, args.len()) {
                    ("notNull", 0) => {
                        return Ok(klio_runtime::Value::Delegate(Rc::new(RefCell::new(
                            klio_runtime::DelegateKind::NotNull {
                                value: None,
                                name: String::new(),
                            },
                        ))));
                    }
                    ("observable", 2) => {
                        return Ok(klio_runtime::Value::Delegate(Rc::new(RefCell::new(
                            klio_runtime::DelegateKind::Observable {
                                value: args[0].clone(),
                                on_change: args[1].clone(),
                            },
                        ))));
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
            if let Some(func) = klio_stdlib::implementation(&probe) {
                return self.dispatch_intrinsic(func, args);
            }
        }
        if let klio_runtime::Value::Class(cls) = receiver {
            let probe_simple = format!("{}.{}", cls.name, name);
            if let Some(func) = klio_stdlib::implementation(&probe_simple) {
                return self.dispatch_intrinsic(func, args);
            }
            let probe_fqn = format!("{}.{}", cls.fqn, name);
            if let Some(func) = klio_stdlib::implementation(&probe_fqn) {
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
                        items: Rc::new(RefCell::new(items_clone)),
                        pos: Rc::new(RefCell::new(0)),
                        prim: None,
                    });
                }
                klio_runtime::Value::Set { items, .. } => {
                    let items_clone: Vec<klio_runtime::Value> = items.borrow().clone();
                    return Ok(klio_runtime::Value::Iterator {
                        items: Rc::new(RefCell::new(items_clone)),
                        pos: Rc::new(RefCell::new(0)),
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
                        items: Rc::new(RefCell::new(entries_clone)),
                        pos: Rc::new(RefCell::new(0)),
                        prim: None,
                    });
                }
                klio_runtime::Value::Range { start, end, step, kind } => {
                    let items = materialise_range_items(*start, *end, *step, *kind);
                    return Ok(klio_runtime::Value::Iterator {
                        items: Rc::new(RefCell::new(items)),
                        pos: Rc::new(RefCell::new(0)),
                        prim: None,
                    });
                }
                klio_runtime::Value::Array { items, prim } => {
                    let items_clone: Vec<klio_runtime::Value> = items.borrow().clone();
                    return Ok(klio_runtime::Value::Iterator {
                        items: Rc::new(RefCell::new(items_clone)),
                        pos: Rc::new(RefCell::new(0)),
                        prim: *prim,
                    });
                }
                klio_runtime::Value::String(s) => {
                    let items: Vec<klio_runtime::Value> = s
                        .chars()
                        .map(klio_runtime::Value::Char)
                        .collect();
                    return Ok(klio_runtime::Value::Iterator {
                        items: Rc::new(RefCell::new(items)),
                        pos: Rc::new(RefCell::new(0)),
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
                    items: Rc::new(RefCell::new(items)),
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
                klio_runtime::Value::Sequence(Rc::new(klio_runtime::SequenceData {
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
                            i.borrow_mut().outer = Some(klio_runtime::Value::Instance(Rc::clone(outer_inst)));
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
            if let Some(comp_name) = self.companion_singletons.get(&cls.name).cloned() {
                let singleton = self.globals.borrow().lookup(&comp_name);
                if let Some(singleton) = singleton {
                    if matches!(singleton, klio_runtime::Value::Instance(_)) {
                        // Try the companion instance first; on
                        // unimplemented fall through so error sites
                        // still see the class receiver.
                        if let Ok(v) = self.call_member(&singleton, name, args) {
                            return Ok(v);
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
                    items: Rc::new(RefCell::new(items)),
                    mutable: false,
                    enum_class: Some(Rc::new(cls.name.clone())),
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
                            fqn: std::rc::Rc::new(
                                "kotlin.IllegalArgumentException".to_string(),
                            ),
                            message: Some(std::rc::Rc::new(format!(
                                "No enum constant {}.{}",
                                cls.name, s
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
            if name != "invoke" {
                if let Ok(v) = self.call_value(receiver, args) {
                    return Ok(v);
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
                    return Ok(klio_runtime::Value::String(Rc::new(format!(
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
                        items: Rc::new(RefCell::new(sorted)),
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
                        let ka = self.call_value(sel, std::slice::from_ref(&a))?;
                        let kb = self.call_value(sel, std::slice::from_ref(&b))?;
                        let o = klio_stdlib::compare_values(&ka, &kb)
                            .map_err(|e| klio_ir::eval::EvalError::Type(format!("{e}")))?;
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
                        steps: Rc::new(chain),
                        descending: *descending,
                    });
                }
                "reversed" if args.is_empty() => {
                    return Ok(klio_runtime::Value::Comparator {
                        steps: Rc::clone(steps),
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
                        items: Rc::new(RefCell::new(v)),
                        mutable: false,
                        enum_class: None,
                    });
                }
                ("toMutableList", 0) => {
                    let v: Vec<klio_runtime::Value> = items.borrow().clone();
                    return Ok(klio_runtime::Value::List {
                        items: Rc::new(RefCell::new(v)),
                        mutable: true,
                        enum_class: None,
                    });
                }
                ("asList", 0) => {
                    let v: Vec<klio_runtime::Value> = items.borrow().clone();
                    return Ok(klio_runtime::Value::List {
                        items: Rc::new(RefCell::new(v)),
                        mutable: false,
                        enum_class: None,
                    });
                }
                ("toSet", 0) => {
                    let v: Vec<klio_runtime::Value> = items.borrow().clone();
                    return Ok(klio_runtime::Value::Set {
                        items: Rc::new(RefCell::new(v)),
                        mutable: false,
                    });
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
                            fqn: Rc::new("kotlin.NoSuchElementException".to_string()),
                            message: Some(Rc::new("iterator exhausted".into())),
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
            let has_user_override = inst.borrow().class.methods.iter().any(|m| m.name == name);
            if is_data && !has_user_override && args.is_empty() {
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
                    return Ok(klio_runtime::Value::String(Rc::new(s)));
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
            if is_data && !has_user_override && args.len() == 1 && name == "equals" {
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
            let key = (class_name, name.to_string());
            let entry = self.anon_methods.borrow().get(&key).cloned();
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
                // Layer captured outer-env names onto globals for the
                // duration of the method call so the body's
                // bare-name globals resolve to the captured values.
                let prev = Rc::clone(&self.globals);
                if !captures.is_empty() {
                    let scoped = Rc::new(RefCell::new(
                        klio_runtime::Env::with_parent(Rc::clone(&prev)),
                    ));
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
                    for fid in &ir_class.methods {
                        if let Some(f) = self.module.funcs.get(fid.0 as usize).cloned() {
                            if f.name == name {
                                let mut all_args: Vec<klio_runtime::Value> =
                                    Vec::with_capacity(args.len() + 1);
                                all_args.push(receiver.clone());
                                all_args.extend_from_slice(args);
                                let module = Rc::clone(&self.module);
                                return klio_ir::eval::eval_with(&module, &f, all_args, self);
                            }
                        }
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
                return Ok(klio_runtime::Value::String(Rc::new(format!(
                    "{}@{:x}",
                    i.class.name, i.identity
                ))));
            }
            if args.is_empty() && name == "hashCode" {
                let i = inst.borrow();
                return Ok(klio_runtime::Value::new_int(i.identity as i64));
            }
            if args.len() == 1 && name == "equals" {
                if let klio_runtime::Value::Instance(o) = &args[0] {
                    let same = Rc::ptr_eq(inst, o);
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
        for probe in &probes {
            if let Some(func) = klio_stdlib::implementation(probe) {
                let mut all_args: Vec<klio_runtime::Value> = Vec::with_capacity(args.len() + 1);
                all_args.push(receiver.clone());
                all_args.extend_from_slice(args);
                return self.dispatch_intrinsic(func, &all_args);
            }
        }
        // Extension fn fallback: a user-defined `fun T.name(...)`
        // lowers as a top-level fn whose first param is the
        // receiver. Look it up by simple name and dispatch with
        // receiver prepended.
        if let Some(fid) = self.module.func_id(name) {
            if let Some(func) = self.module.funcs.get(fid.0 as usize).cloned() {
                if func.params.len() == args.len() + 1 {
                    let mut all: Vec<klio_runtime::Value> = Vec::with_capacity(args.len() + 1);
                    all.push(receiver.clone());
                    all.extend_from_slice(args);
                    let module = Rc::clone(&self.module);
                    return klio_ir::eval::eval_with(&module, &func, all, self);
                }
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
                fqn: std::rc::Rc::new("kotlin.InstantiationError".to_string()),
                message: Some(std::rc::Rc::new(format!(
                    "Cannot create an instance of an abstract class: {}",
                    class_def.name
                ))),
                cause: None,
            }));
        }
        if class_def.is_interface {
            return Err(klio_ir::eval::EvalError::Throw(klio_runtime::Value::Exception {
                fqn: std::rc::Rc::new("kotlin.InstantiationError".to_string()),
                message: Some(std::rc::Rc::new(format!(
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
        if args.len() != n_primary {
            let entries = self
                .secondary_ctors
                .get(&class_def.name)
                .cloned()
                .unwrap_or_default();
            if let Some(entry) = entries.iter().find(|e| e.param_count == args.len()) {
                let module = Rc::clone(&self.module);
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
                        return Err(klio_ir::eval::EvalError::Unimplemented(format!(
                            "Vm::new_instance: secondary ctor super-delegation for `{}` (no parent class def)",
                            class_def.name
                        )));
                    }
                } else {
                    <Self as klio_ir::eval::Host>::new_instance(
                        self, class, &target_args,
                    )?
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
        *self.instance_id_counter += 1;
        let identity = *self.instance_id_counter;
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
                    if let Some(thunks) = self.parent_ctor_args.get(&cur_class).cloned() {
                        for (idx, fid) in thunks.iter().enumerate() {
                            if let Some(func) =
                                self.module.funcs.get(fid.0 as usize).cloned()
                            {
                                let v = klio_ir::eval::eval_with(
                                    &Rc::clone(&self.module),
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
        while let Some(thunks) = self.parent_ctor_args.get(&cur_class).cloned() {
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
                let module = Rc::clone(&self.module);
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
        let inst = std::rc::Rc::new(std::cell::RefCell::new(klio_runtime::InstanceData {
            class: class_def.clone(),
            fields,
            outer: None,
            identity,
            native_state: None,
        }));
        let inst_value = klio_runtime::Value::Instance(std::rc::Rc::clone(&inst));
        // Evaluate class-delegation expressions (`: I by g`) and
        // store the resulting delegate values on the instance
        // under `__delegate__<superName>` so call_member can
        // forward unmatched methods.
        let class_delegate_thunks = self
            .class_delegates
            .get(&class_def.name)
            .cloned()
            .unwrap_or_default();
        for (sup_name, fid) in &class_delegate_thunks {
            if let Some(func) = self.module.funcs.get(fid.0 as usize).cloned() {
                let module = Rc::clone(&self.module);
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
        let mut chain_classes: Vec<Rc<klio_runtime::ClassDef>> = Vec::new();
        {
            let mut cur = Some(Rc::clone(&class_def));
            while let Some(c) = cur {
                chain_classes.push(Rc::clone(&c));
                cur = c.parent.borrow().clone();
            }
        }
        // Bottom-up so parent fields exist before child fields can
        // override the same name.
        for cls in chain_classes.iter().rev() {
        for p in &cls.body_properties {
            if let Some(fid) = self
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
                let module = Rc::clone(&self.module);
                let mut all: Vec<klio_runtime::Value> = Vec::with_capacity(1 + args.len());
                all.push(inst_value.clone());
                all.extend_from_slice(args);
                let v = klio_ir::eval::eval_with(&module, &func, all, self)?;
                inst.borrow_mut().fields.push((p.name.clone(), v));
            } else if p.getter.is_none() && p.delegate.is_none() {
                inst.borrow_mut()
                    .fields
                    .push((p.name.clone(), klio_runtime::Value::Null));
            }
        }
        }
        // Run init blocks bottom-up across the parent chain so a
        // parent's init runs before its child's. Each init block
        // takes `this` as its sole param.
        for (cls_name, cls_args) in chain.iter().rev() {
            if let Some(fids) = self.init_blocks.get(cls_name).cloned() {
                for fid in fids {
                    let func = self.module.funcs.get(fid.0 as usize).cloned();
                    if let Some(f) = func {
                        let module = Rc::clone(&self.module);
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
                items: Rc::new(RefCell::new(rest)),
                prim: None,
            });
            return out;
        }
    }
    args
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
            Some(klio_runtime::Value::String(Rc::new(s)))
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
    module: Rc<klio_ir::Module>,
    closures: &'a mut Vec<ClosureInfo>,
    globals: Rc<RefCell<klio_runtime::Env>>,
    classes: Rc<RefCell<std::collections::HashMap<String, Rc<klio_runtime::ClassDef>>>>,
    body_prop_inits:
        &'a std::collections::HashMap<(String, String), klio_ir::FuncId>,
    instance_prop_getters:
        &'a std::collections::HashMap<(String, String), klio_ir::FuncId>,
    instance_prop_setters:
        &'a std::collections::HashMap<(String, String), klio_ir::FuncId>,
    parent_ctor_args:
        &'a std::collections::HashMap<String, Vec<klio_ir::FuncId>>,
    init_blocks: &'a std::collections::HashMap<String, Vec<klio_ir::FuncId>>,
    extension_props:
        &'a std::collections::HashMap<(String, String), klio_ir::FuncId>,
    anon_methods: Rc<RefCell<std::collections::HashMap<
        (String, String),
        (Rc<klio_ir::Module>, klio_ir::FuncId, Vec<(String, klio_runtime::Value)>),
    >>>,
    companion_singletons: &'a std::collections::HashMap<String, String>,
    secondary_ctors:
        &'a std::collections::HashMap<String, Vec<build::SecondaryCtorEntry>>,
    class_delegates:
        &'a std::collections::HashMap<String, Vec<(String, klio_ir::FuncId)>>,
    func_defaults:
        &'a std::collections::HashMap<klio_ir::FuncId, Vec<Option<klio_ir::FuncId>>>,
    instance_id_counter: &'a mut u64,
}

impl<'a> klio_runtime::IntrinsicHost for VmIntrinsicHost<'a> {
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
                .cloned()
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
            let mut call_args: Vec<klio_runtime::Value> = Vec::with_capacity(info.n_params);
            for i in 0..info.n_params {
                call_args.push(args.get(i).cloned().unwrap_or(klio_runtime::Value::Null));
            }
            let capture_values: Vec<klio_runtime::Value> = info.captures.borrow().clone();
            let module = Rc::clone(&self.module);
            // Mutable-capture support: pre-define each captured name
            // in a fresh env layered on top of globals so the body's
            // StoreGlobal writes land in the env, then read back the
            // updated values into the closure's captures so the
            // outer-frame WritebackCaptures Inst sees them.
            let scoped_env = Rc::new(RefCell::new(klio_runtime::Env::with_parent(
                Rc::clone(&self.globals),
            )));
            for (n, v) in info.capture_names.iter().zip(capture_values.iter()) {
                scoped_env.borrow_mut().define(n.clone(), v.clone());
            }
            let result = {
                let mut host = VmHost {
                    globals: Rc::clone(&scoped_env),
                    module: Rc::clone(&self.module),
                    scheduler: &mut *self.scheduler,
                    out,
                    instance_id_counter: &mut *self.instance_id_counter,
                    classes: Rc::clone(&self.classes),
                    body_prop_inits: self.body_prop_inits,
                    instance_prop_getters: self.instance_prop_getters,
                    instance_prop_setters: self.instance_prop_setters,
                    parent_ctor_args: self.parent_ctor_args,
            init_blocks: self.init_blocks,
            extension_props: self.extension_props,
            anon_methods: Rc::clone(&self.anon_methods),
                    companion_singletons: self.companion_singletons,
                    secondary_ctors: self.secondary_ctors,
                    class_delegates: self.class_delegates,
                    func_defaults: self.func_defaults,
                    closures: &mut *self.closures,
                };
                klio_ir::eval::eval_with_captures(
                    &module,
                    &func,
                    call_args,
                    capture_values,
                    &mut host,
                )
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
            return result.map_err(|e| klio_runtime::RuntimeError::Type(format!("{e}")));
        }
        if let klio_runtime::Value::Intrinsic { func, .. } = callable {
            let mut child = VmIntrinsicHost {
                scheduler: &mut *self.scheduler,
                module: Rc::clone(&self.module),
                closures: &mut *self.closures,
                globals: Rc::clone(&self.globals),
                classes: Rc::clone(&self.classes),
                body_prop_inits: self.body_prop_inits,
                instance_prop_getters: self.instance_prop_getters,
                instance_prop_setters: self.instance_prop_setters,
                parent_ctor_args: self.parent_ctor_args,
            init_blocks: self.init_blocks,
            extension_props: self.extension_props,
            anon_methods: Rc::clone(&self.anon_methods),
                companion_singletons: self.companion_singletons,
                secondary_ctors: self.secondary_ctors,
                class_delegates: self.class_delegates,
                func_defaults: self.func_defaults,
                instance_id_counter: &mut *self.instance_id_counter,
            };
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
            let info = self.closures.get(*id as usize).cloned();
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
                let result = self.invoke_callable(callable, &all, out);
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

        let mut vm = Vm::new(Rc::new(module));
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

        let mut vm = Vm::new(Rc::new(module));
        let mut out = StringOut::default();
        vm.run(main_id, &mut out).unwrap();
        assert_eq!(out.0, "hello\n");
    }
}
