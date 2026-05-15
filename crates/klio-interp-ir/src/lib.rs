//! IR-native interpreter.
//!
//! This crate is the destination of the IR cutover: it executes a
//! frozen `klio_ir::Module` end-to-end with no AST evaluator, no
//! callback into the tree-walker `klio-interp`, and no `IrHost` shim
//! that synthesises AST.
//!
//! The crate starts as a thin scaffold and grows per the IR cutover
//! plan. Today's surface is the `Vm` struct + `Vm::run` entry point.
//! New IR Insts and runtime shapes (closures, shared cells, suspend
//! state machines, reflection refs, SAM wrappers) land into this
//! crate as they're added to `klio-ir` and `klio-runtime`.

use std::cell::RefCell;
use std::rc::Rc;

pub use klio_runtime::Output;

/// One Vm instance executes a single program against the IR module
/// produced by the front end. Long-running state (globals,
/// scheduler, stacks) lives here.
pub struct Vm {
    module: Rc<klio_ir::Module>,
    globals: Rc<RefCell<klio_runtime::Env>>,
    scheduler: Box<dyn klio_runtime::Scheduler>,
}

impl Vm {
    /// Build a Vm around an already-lowered IR module. Stdlib
    /// aliases (`print`, `println`, `listOf`, ...) are installed
    /// into globals up front so a hello-world program can find them
    /// without going through klio-interp.
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
        }
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
        let mut host = MinimalHost {
            globals: Rc::clone(&self.globals),
            module: Rc::clone(&module),
            scheduler: &mut *self.scheduler,
            out,
        };
        klio_ir::eval::eval_with(&module, &func, Vec::new(), &mut host).map_err(VmError::from)
    }
}

/// Vm-level errors. The IR's `EvalError` rolls up into a single
/// `Eval` variant; surface-level driver errors get their own
/// variants as they appear.
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

/// Provisional host impl. The cutover plan replaces this with a
/// switch-on-Inst Vm that drops the `Host` trait entirely; until
/// every Inst has a Vm-native implementation we route the
/// stdlib-resolvable shapes through a small host that does *not*
/// call back into the tree walker.
struct MinimalHost<'a> {
    globals: Rc<RefCell<klio_runtime::Env>>,
    #[allow(dead_code)]
    module: Rc<klio_ir::Module>,
    scheduler: &'a mut dyn klio_runtime::Scheduler,
    out: &'a mut dyn Output,
}

impl<'a> MinimalHost<'a> {
    fn dispatch_intrinsic(
        &mut self,
        func: klio_runtime::StdlibFn,
        args: &[klio_runtime::Value],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        let mut intrinsic_host = MinimalIntrinsicHost {
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

impl<'a> klio_ir::eval::Host for MinimalHost<'a> {
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
        Err(klio_ir::eval::EvalError::Type(format!(
            "klio-interp-ir Vm: call_value not yet implemented for `{}`",
            callee.type_fqn()
        )))
    }

    fn call_value_named(
        &mut self,
        callee: &klio_runtime::Value,
        args: &[klio_runtime::Value],
        _arg_names: &[Option<String>],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        // The Vm's stdlib intrinsics handle arg names internally; for
        // the smoke-test surface (println etc.) positional dispatch is
        // enough. Real named-arg routing lands later.
        self.call_value(callee, args)
    }

    fn get_field(
        &mut self,
        receiver: &klio_runtime::Value,
        name: &str,
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        // Plain-field read on a user-class instance — no custom
        // getter, no delegate, no extension property. The accessor
        // and delegate surfaces land with the property-accessor
        // workstream; until then they raise Unimplemented.
        if let klio_runtime::Value::Instance(inst) = receiver {
            if let Some(v) = inst.borrow().get(name) {
                return Ok(v);
            }
        }
        Err(klio_ir::eval::EvalError::Unimplemented(format!(
            "klio-interp-ir Vm: get_field `{name}` on `{}`",
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
            "klio-interp-ir Vm: set_field `{name}` on `{}`",
            receiver.type_fqn()
        )))
    }
}

/// Stdlib `CallCtx` host adapter. Today it only implements the
/// methods the `println` / `print` path needs; further Vm-native
/// handlers land as features migrate.
struct MinimalIntrinsicHost<'a> {
    scheduler: &'a mut dyn klio_runtime::Scheduler,
}

impl<'a> klio_runtime::IntrinsicHost for MinimalIntrinsicHost<'a> {
    fn invoke_callable(
        &mut self,
        _callable: &klio_runtime::Value,
        _args: &[klio_runtime::Value],
        _out: &mut dyn Output,
    ) -> Result<klio_runtime::Value, klio_runtime::RuntimeError> {
        Err(klio_runtime::RuntimeError::Unimplemented(
            "Vm invoke_callable".into(),
        ))
    }

    fn invoke_callable_with_this(
        &mut self,
        _callable: &klio_runtime::Value,
        _args: &[klio_runtime::Value],
        _this: &klio_runtime::Value,
        _out: &mut dyn Output,
    ) -> Result<klio_runtime::Value, klio_runtime::RuntimeError> {
        Err(klio_runtime::RuntimeError::Unimplemented(
            "Vm invoke_callable_with_this".into(),
        ))
    }

    fn scheduler(&mut self) -> &mut dyn klio_runtime::Scheduler {
        &mut *self.scheduler
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use klio_ir::{Const, Inst, Module, Reg, Terminator, TypeRef};
    use klio_ir::build::FuncBuilder;

    /// Capture-to-string Output so the Vm's stdout can be asserted.
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
        // fun main(): Int = 42
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

        let mut vm = Vm::new(std::rc::Rc::new(module));
        let mut out = StringOut::default();
        let v = vm.run(main_id, &mut out).unwrap();
        match v {
            klio_runtime::Value::Int(42) => {}
            other => panic!("expected Int(42), got {other:?}"),
        }
    }

    #[test]
    fn vm_runs_println_via_intrinsic() {
        // fun main() { println("hello") }
        let mut module = Module::default();
        let mut b = FuncBuilder::new(&mut module);
        // LoadGlobal "println" → reg `callee`
        let callee = b.alloc_reg();
        let nm = b.module.intern_const(Const::String("println".into()));
        b.push(Inst::LoadGlobal { dst: callee, name: nm });
        // Const "hello" → reg `arg`
        let arg = b.emit_const(Const::String("hello".into()));
        // CallValue(callee, [arg])
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

        let mut vm = Vm::new(std::rc::Rc::new(module));
        let mut out = StringOut::default();
        vm.run(main_id, &mut out).unwrap();
        assert_eq!(out.0, "hello\n");
    }

    // Keep `Reg` referenced so the import doesn't dangle as builders
    // grow over the workstream sequence.
    fn _force_reg_import(_: Reg) {}
}
