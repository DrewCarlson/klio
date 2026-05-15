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
}

impl Vm {
    /// Build a Vm around an already-lowered IR module. The module's
    /// top-level property initialisers + class registrations must
    /// have run before `run` is called — that happens at module
    /// load time in the driver (`klio-cli`).
    pub fn new(module: Rc<klio_ir::Module>) -> Self {
        let globals = Rc::new(RefCell::new(klio_runtime::Env::new()));
        Self { module, globals }
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
struct MinimalHost<'o> {
    globals: Rc<RefCell<klio_runtime::Env>>,
    #[allow(dead_code)]
    module: Rc<klio_ir::Module>,
    #[allow(dead_code)]
    out: &'o mut dyn Output,
}

impl<'o> klio_ir::eval::Host for MinimalHost<'o> {
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

}
