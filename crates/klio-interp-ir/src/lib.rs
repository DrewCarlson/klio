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
    /// and eventually goes away.
    classes: std::collections::HashMap<String, Rc<klio_runtime::ClassDef>>,
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
            classes: std::collections::HashMap::new(),
            body_prop_inits: std::collections::HashMap::new(),
            instance_prop_getters: std::collections::HashMap::new(),
            closures: Vec::new(),
        }
    }

    /// Build a Vm from a fully-prepared `build::BuiltModule`. The
    /// recommended entry point for the driver — it carries both the
    /// IR module and the synthesised runtime ClassDef table.
    pub fn from_built(built: build::BuiltModule) -> (Self, Option<klio_ir::FuncId>) {
        let main = built.main;
        let mut vm = Self::new(built.module);
        vm.classes = built.classes;
        vm.body_prop_inits = built.body_prop_inits;
        vm.instance_prop_getters = built.instance_prop_getters;
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
            classes: &self.classes,
            body_prop_inits: &self.body_prop_inits,
            instance_prop_getters: &self.instance_prop_getters,
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
    classes: &'a std::collections::HashMap<String, Rc<klio_runtime::ClassDef>>,
    body_prop_inits:
        &'a std::collections::HashMap<(String, String), klio_ir::FuncId>,
    instance_prop_getters:
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
            classes: self.classes,
            body_prop_inits: self.body_prop_inits,
            instance_prop_getters: self.instance_prop_getters,
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
                let leaked: &'static str = Box::leak(fqn.clone().into_boxed_str());
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
                if let Some(def) = self.classes.get(&cur_name) {
                    for sup in &def.supertype_names {
                        queue.push_back(sup.clone());
                    }
                }
            }
        }
        // Stdlib member dispatch: probe the receiver's type FQN
        // for a `<typeFqn>.<name>` intrinsic, then for the common
        // package-extension fallbacks. The intrinsic receives the
        // receiver as its first arg followed by the user-supplied
        // args.
        let type_fqn = receiver.type_fqn();
        let probes = [
            format!("{type_fqn}.{name}"),
            format!("kotlin.collections.{name}"),
            format!("kotlin.text.{name}"),
            format!("kotlin.ranges.{name}"),
            format!("kotlin.{name}"),
        ];
        for probe in &probes {
            if let Some(func) = klio_stdlib::implementation(probe) {
                let mut all_args: Vec<klio_runtime::Value> = Vec::with_capacity(args.len() + 1);
                all_args.push(receiver.clone());
                all_args.extend_from_slice(args);
                return self.dispatch_intrinsic(func, &all_args);
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
        let class_def = self.classes.get(&ir_class.name).cloned().ok_or_else(|| {
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
        if !class_def.init_blocks.is_empty()
            || !class_def.parent_ctor_args.is_empty()
            || !class_def.secondary_ctors.is_empty()
            || !class_def.supertype_delegates.borrow().is_empty()
        {
            return Err(klio_ir::eval::EvalError::Unimplemented(format!(
                "Vm::new_instance: non-trivial ctor for `{}` (init blocks / parent ctor / secondary ctors / supertype delegates not yet native)",
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
        for (param, value) in class_def.primary_params.iter().zip(args.iter()) {
            if param.property.is_some() {
                fields.push((param.name.clone(), value.clone()));
            }
        }
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
        Ok(klio_runtime::Value::Instance(inst))
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
    classes: &'a std::collections::HashMap<String, Rc<klio_runtime::ClassDef>>,
    body_prop_inits:
        &'a std::collections::HashMap<(String, String), klio_ir::FuncId>,
    instance_prop_getters:
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
                    classes: self.classes,
                    body_prop_inits: self.body_prop_inits,
                    instance_prop_getters: self.instance_prop_getters,
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
                classes: self.classes,
                body_prop_inits: self.body_prop_inits,
                instance_prop_getters: self.instance_prop_getters,
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
        _callable: &klio_runtime::Value,
        _args: &[klio_runtime::Value],
        _this: &klio_runtime::Value,
        _out: &mut dyn Output,
    ) -> Result<klio_runtime::Value, klio_runtime::RuntimeError> {
        Err(klio_runtime::RuntimeError::Unimplemented(
            "Vm::invoke_callable_with_this".into(),
        ))
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
