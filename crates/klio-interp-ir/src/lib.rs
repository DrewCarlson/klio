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
            parent_ctor_args: std::collections::HashMap::new(),
            init_blocks: std::collections::HashMap::new(),
            extension_props: std::collections::HashMap::new(),
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
        vm.parent_ctor_args = built.parent_ctor_args;
        vm.init_blocks = built.init_blocks;
        vm.extension_props = built.extension_props;
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
            parent_ctor_args: &self.parent_ctor_args,
            init_blocks: &self.init_blocks,
            extension_props: &self.extension_props,
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
    parent_ctor_args:
        &'a std::collections::HashMap<String, Vec<klio_ir::FuncId>>,
    init_blocks: &'a std::collections::HashMap<String, Vec<klio_ir::FuncId>>,
    extension_props:
        &'a std::collections::HashMap<(String, String), klio_ir::FuncId>,
    closures: &'a mut Vec<ClosureInfo>,
}

impl<'a> VmHost<'a> {
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
            parent_ctor_args: self.parent_ctor_args,
            init_blocks: self.init_blocks,
            extension_props: self.extension_props,
            instance_id_counter: &mut *self.instance_id_counter,
        };
        let mut ctx = klio_runtime::CallCtx {
            args,
            out: self.out,
            host: &mut intrinsic_host,
        };
        func(&mut ctx).map_err(|e| klio_ir::eval::EvalError::Type(format!("{e}")))
    }
}

impl<'a> klio_ir::eval::Host for VmHost<'a> {
    fn lookup_global(&mut self, name: &str) -> Option<klio_runtime::Value> {
        if let Some(v) = self.globals.borrow().lookup(name) {
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
        None
    }

    fn store_global(
        &mut self,
        name: &str,
        value: klio_runtime::Value,
    ) -> Result<(), klio_ir::eval::EvalError> {
        self.globals.borrow_mut().define(name, value);
        Ok(())
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
            // initialises the param slot.
            let mut call_args: Vec<klio_runtime::Value> = Vec::with_capacity(info.n_params);
            for i in 0..info.n_params {
                call_args.push(args.get(i).cloned().unwrap_or(klio_runtime::Value::Null));
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
                .get(&(class_name, name.to_string()))
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
        if let klio_runtime::Value::Instance(inst) = receiver {
            inst.borrow_mut().define(name, value);
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
        Ok(())
    }

    fn register_class_captured(
        &mut self,
        class: &klio_ast::Class,
        _captured_names: &[String],
        _captures: Vec<klio_runtime::Value>,
    ) -> Result<(), klio_ir::eval::EvalError> {
        self.register_class(class)
    }

    fn build_object(
        &mut self,
        ast: &klio_ast::Expr,
        _captured_names: &[String],
        _captures: Vec<klio_runtime::Value>,
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
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
        // Look up the method on the parent's IR class.
        let parent_ir = self
            .module
            .classes
            .iter()
            .find(|c| c.name == parent_name)
            .cloned();
        if let Some(parent_ir) = parent_ir {
            for fid in &parent_ir.methods {
                if let Some(func) = self.module.funcs.get(fid.0 as usize).cloned() {
                    if func.name == name {
                        let mut all: Vec<klio_runtime::Value> = Vec::with_capacity(args.len() + 1);
                        all.push(receiver.clone());
                        all.extend_from_slice(args);
                        let module = Rc::clone(&self.module);
                        return klio_ir::eval::eval_with(&module, &func, all, self);
                    }
                }
            }
        }
        // Fall back to the regular member dispatch on the receiver.
        self.call_member(receiver, name, args)
    }

    fn qualified_this(
        &mut self,
        receiver: &klio_runtime::Value,
        qualifier: &str,
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        // Simple case: receiver's own class name (or fqn ending in
        // `.<qualifier>`) matches — return the receiver as-is.
        if let klio_runtime::Value::Instance(inst) = receiver {
            let mut cur: Option<Rc<klio_runtime::ClassDef>> =
                Some(Rc::clone(&inst.borrow().class));
            while let Some(c) = cur {
                if c.name == qualifier || c.fqn == qualifier {
                    return Ok(receiver.clone());
                }
                cur = c.parent.borrow().clone();
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
                "next" if args.is_empty() => {
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
        _arg_names: &[Option<String>],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
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
        // Trivial primary-ctor shape: each primary param with
        // `property = Some(...)` becomes an instance field, then
        // body properties with init thunks run to populate their
        // fields. Init blocks, parent ctor chain, secondary ctors,
        // and supertype delegates are not yet handled.
        if !class_def.parent_ctor_args.is_empty()
            || !class_def.secondary_ctors.is_empty()
            || !class_def.supertype_delegates.borrow().is_empty()
        {
            return Err(klio_ir::eval::EvalError::Unimplemented(format!(
                "Vm::new_instance: non-trivial ctor for `{}` (secondary ctors / supertype delegates not yet native)",
                class_def.name
            )));
        }
        let n_primary = class_def.primary_params.len();
        if args.len() != n_primary {
            return Err(klio_ir::eval::EvalError::Arity(format!(
                "{}() expects {n_primary} args, got {}",
                class_def.name,
                args.len()
            )));
        }
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
        // (Leaf-class primary params for non-property args are already
        // ignored by the loop above — only property params get fields.)
        let _ = (&class_def.primary_params, args);
        // Body properties: run each init thunk and bind the result.
        // Properties without an init expression but with a delegate
        // or getter are not yet handled — we surface a clear failure.
        for p in &class_def.body_properties {
            if let Some(fid) = self
                .body_prop_inits
                .get(&(class_def.name.clone(), p.name.clone()))
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
                let v = klio_ir::eval::eval_with(&module, &func, Vec::new(), self)?;
                fields.push((p.name.clone(), v));
            } else if p.getter.is_none() && p.delegate.is_none() {
                // Plain `var n: Int` with no init defaults to a
                // type-appropriate zero — matches Kotlin's
                // primitive defaults for explicitly-typed body
                // fields.
                fields.push((p.name.clone(), klio_runtime::Value::Null));
            }
        }
        let inst = std::rc::Rc::new(std::cell::RefCell::new(klio_runtime::InstanceData {
            class: class_def,
            fields,
            outer: None,
            identity,
            native_state: None,
        }));
        let inst_value = klio_runtime::Value::Instance(std::rc::Rc::clone(&inst));
        // Run init blocks bottom-up across the parent chain so a
        // parent's init runs before its child's. Each init block
        // takes `this` as its sole param.
        for (cls_name, _) in chain.iter().rev() {
            if let Some(fids) = self.init_blocks.get(cls_name).cloned() {
                for fid in fids {
                    let func = self.module.funcs.get(fid.0 as usize).cloned();
                    if let Some(f) = func {
                        let module = Rc::clone(&self.module);
                        klio_ir::eval::eval_with(
                            &module,
                            &f,
                            vec![inst_value.clone()],
                            self,
                        )?;
                    }
                }
            }
        }
        Ok(inst_value)
    }
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
    parent_ctor_args:
        &'a std::collections::HashMap<String, Vec<klio_ir::FuncId>>,
    init_blocks: &'a std::collections::HashMap<String, Vec<klio_ir::FuncId>>,
    extension_props:
        &'a std::collections::HashMap<(String, String), klio_ir::FuncId>,
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
                    parent_ctor_args: self.parent_ctor_args,
            init_blocks: self.init_blocks,
            extension_props: self.extension_props,
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
                parent_ctor_args: self.parent_ctor_args,
            init_blocks: self.init_blocks,
            extension_props: self.extension_props,
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
        // Receiver-typed lambda dispatch: when the lambda has a
        // single param (the parser-injected implicit-`it` shape),
        // pass the receiver as that param. \`it.foo()\` style scope
        // fn bodies work this way; bodies that rely on bare-name
        // resolution through `this` (\`apply { foo() }\`) still need
        // the lower-time receiver-binding which lands when AST/IR
        // grow a receiver-marker.
        if let klio_runtime::Value::IrClosure { id, .. } = callable {
            let info = self.closures.get(*id as usize).cloned();
            if let Some(info) = info {
                let mut all: Vec<klio_runtime::Value> = Vec::with_capacity(info.n_params);
                if info.n_params >= 1 {
                    all.push(this.clone());
                    for a in args.iter() {
                        all.push(a.clone());
                    }
                    return self.invoke_callable(callable, &all, out);
                }
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
