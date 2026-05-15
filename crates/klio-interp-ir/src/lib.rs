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
    closures: &'a mut Vec<ClosureInfo>,
}

impl<'a> VmHost<'a> {
    fn dispatch_intrinsic(
        &mut self,
        func: klio_runtime::StdlibFn,
        args: &[klio_runtime::Value],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        let mut intrinsic_host = VmIntrinsicHost {
            scheduler: &mut *self.scheduler,
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
        self.globals.borrow().lookup(name)
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
        if let klio_runtime::Value::Instance(inst) = receiver {
            if let Some(v) = inst.borrow().get(name) {
                return Ok(v);
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
        _captured_names: &[String],
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
        self.closures.push(ClosureInfo {
            body_func,
            n_params: params.len(),
        });
        Ok(klio_runtime::Value::IrClosure {
            id,
            captures: Rc::new(captures),
        })
    }

    fn call_member(
        &mut self,
        receiver: &klio_runtime::Value,
        name: &str,
        args: &[klio_runtime::Value],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        if let klio_runtime::Value::Instance(inst) = receiver {
            // Look up an IR-lowered method by walking the IR Class
            // for the receiver's runtime class. Each method FuncId
            // names itself, so the simple-name match is enough for
            // the trivial single-class case. Inherited methods land
            // when supertype lookup migrates.
            let class_name = inst.borrow().class.name.clone();
            let ir_class = self
                .module
                .classes
                .iter()
                .find(|c| c.name == class_name)
                .cloned();
            if let Some(ir_class) = ir_class {
                for fid in &ir_class.methods {
                    let func = self.module.funcs.get(fid.0 as usize).cloned();
                    if let Some(f) = func {
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

/// Stdlib `CallCtx` host adapter for native Vm dispatch. HOF
/// bindings (`map`, `forEach`, scope fns, ...) reach back through
/// this adapter to invoke the lambda they were passed. Implementing
/// `invoke_callable` for `Value::IrClosure` requires borrowing the
/// Vm's closure table + module recursively from inside a stdlib
/// binding — that lands once the IntrinsicHost grows the right
/// borrow shape. Today the Vm returns `Unimplemented` so the failing
/// surfaces are visible.
struct VmIntrinsicHost<'a> {
    scheduler: &'a mut dyn klio_runtime::Scheduler,
}

impl<'a> klio_runtime::IntrinsicHost for VmIntrinsicHost<'a> {
    fn invoke_callable(
        &mut self,
        callable: &klio_runtime::Value,
        _args: &[klio_runtime::Value],
        _out: &mut dyn Output,
    ) -> Result<klio_runtime::Value, klio_runtime::RuntimeError> {
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
