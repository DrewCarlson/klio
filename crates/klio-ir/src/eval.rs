//! IR evaluator.
//!
//! Walks a `Func`'s `Vec<Block>` and produces a `Value`. Today
//! supports the subset of `Inst`s the lowering pass emits: `Const`,
//! `BinOp`, `UnOp`, `Not`, `Move`, plus `Goto` / `Branch` / `Return`
//! / `Throw` / `Unreachable` terminators. Other ops trap as
//! `EvalError::Unsupported`.
//!
//! The evaluator does not yet replace `klio-interp`. It exists so
//! the IR shape can be exercised end-to-end on hand-built or
//! lowered modules; as the lowering pass grows, the evaluator
//! grows alongside it, and the cutover lands once parity holds
//! across the corpus.

use klio_runtime::Value;

use crate::{BinOp, BlockId, Const, Func, FuncId, Inst, Module, Reg, Terminator, TypeRef, UnOp};

/// Pluggable callbacks the evaluator delegates non-trivial dispatch
/// through. The IR is intentionally agnostic about how user
/// classes and top-level functions are resolved; a real frontend
/// supplies a host implementation that ties into the interpreter's
/// class table / dispatch machinery. A default no-op `NullHost`
/// exists for unit tests.
pub trait Host {
    /// Resolve a CallValue invocation against a runtime value.
    /// Default rejects so wiring is visible.
    fn call_value(&mut self, _callee: &Value, _args: &[Value]) -> Result<Value, EvalError> {
        Err(EvalError::Unsupported("Host::call_value"))
    }
    /// Resolve a CallMember invocation against the receiver.
    fn call_member(
        &mut self,
        _receiver: &Value,
        _name: &str,
        _args: &[Value],
    ) -> Result<Value, EvalError> {
        Err(EvalError::Unsupported("Host::call_member"))
    }
    /// Construct an instance of a class referenced by ID. The
    /// implementation looks up the corresponding ClassDef and
    /// invokes the primary constructor with the supplied args.
    fn new_instance(&mut self, _class: crate::ClassId, _args: &[Value]) -> Result<Value, EvalError> {
        Err(EvalError::Unsupported("Host::new_instance"))
    }
    /// Test whether `value` is an instance of `ty`. The default
    /// implementation handles the primitive nominal types via
    /// `Value::type_fqn`; complex types defer to the host.
    fn instance_of(&mut self, value: &Value, ty: &TypeRef) -> bool {
        // Primitive name-match suffices for the simple shapes the
        // IR evaluator can reason about standalone.
        let nominal = value.type_fqn();
        nominal == ty.name || nominal.ends_with(&format!(".{}", ty.name))
    }
    /// Resolve a bare global identifier (top-level fn, intrinsic,
    /// imported symbol). Default returns Unit which surfaces as a
    /// runtime "value not callable" error if the caller tries to
    /// call it; concrete hosts route through the interpreter's
    /// global env.
    fn lookup_global(&mut self, _name: &str) -> Option<Value> {
        None
    }

    /// Materialise a closure value capturing the supplied snapshot
    /// of register values. `body_func` is a FuncId in the active
    /// module; concrete hosts build a `Value::Lambda` (or
    /// equivalent) wrapping the body + env so it can be invoked
    /// through `call_value`.
    fn build_closure(
        &mut self,
        _module: &Module,
        _body_func: FuncId,
        _captures: Vec<Value>,
    ) -> Result<Value, EvalError> {
        Err(EvalError::Unsupported("Host::build_closure"))
    }

    /// Resolve a function call by FuncId. The default routes
    /// through `eval()` recursively, so a single-module IR program
    /// stays self-contained.
    fn call_func(
        &mut self,
        module: &Module,
        func: FuncId,
        args: Vec<Value>,
    ) -> Result<Value, EvalError> {
        let f = module
            .funcs
            .get(func.0 as usize)
            .ok_or_else(|| EvalError::Type(format!("unknown FuncId {}", func.0)))?;
        eval(module, f, args)
    }
}

/// No-op host for unit tests and IR-shape exercises.
#[derive(Default)]
pub struct NullHost;
impl Host for NullHost {}

#[derive(Debug, thiserror::Error)]
pub enum EvalError {
    #[error("IR evaluator does not yet support: {0}")]
    Unsupported(&'static str),
    #[error("IR type error: {0}")]
    Type(String),
    #[error("uncaught throw inside IR evaluator")]
    Throw(Value),
}

/// Per-call evaluation frame.
struct Frame<'a> {
    module: &'a Module,
    func: &'a Func,
    regs: Vec<Value>,
    params: Vec<Value>,
    captures: Vec<Value>,
}

impl<'a> Frame<'a> {
    fn new(module: &'a Module, func: &'a Func, params: Vec<Value>) -> Self {
        Self {
            module,
            func,
            regs: vec![Value::Unit; func.n_locals as usize],
            params,
            captures: Vec::new(),
        }
    }

    fn new_with_captures(
        module: &'a Module,
        func: &'a Func,
        params: Vec<Value>,
        captures: Vec<Value>,
    ) -> Self {
        Self {
            module,
            func,
            regs: vec![Value::Unit; func.n_locals as usize],
            params,
            captures,
        }
    }

    fn read(&self, r: Reg) -> Value {
        self.regs.get(r.0 as usize).cloned().unwrap_or(Value::Unit)
    }

    fn write(&mut self, r: Reg, v: Value) {
        let idx = r.0 as usize;
        if idx >= self.regs.len() {
            self.regs.resize(idx + 1, Value::Unit);
        }
        self.regs[idx] = v;
    }

    fn block(&self, b: BlockId) -> &crate::Block {
        &self.func.blocks[b.0 as usize]
    }
}

/// Run a function body with the given positional arguments.
/// Returns the value carried by the terminating `Return`, or
/// `Unit` for a fall-off. Uses `NullHost` for delegated calls.
pub fn eval(module: &Module, func: &Func, args: Vec<Value>) -> Result<Value, EvalError> {
    let mut host = NullHost;
    eval_with(module, func, args, &mut host)
}

/// Run a function body, routing non-trivial dispatch (CallValue /
/// CallMember / NewInstance / InstanceOf) through the supplied
/// host implementation.
pub fn eval_with(
    module: &Module,
    func: &Func,
    args: Vec<Value>,
    host: &mut dyn Host,
) -> Result<Value, EvalError> {
    eval_with_captures(module, func, args, Vec::new(), host)
}

/// Like `eval_with` but seeds the frame with a captured-values
/// vector. Used by closure invocation so `Inst::LoadCapture` reads
/// from the closure's snapshotted env rather than the call args.
pub fn eval_with_captures(
    module: &Module,
    func: &Func,
    args: Vec<Value>,
    captures: Vec<Value>,
    host: &mut dyn Host,
) -> Result<Value, EvalError> {
    let mut frame = Frame::new_with_captures(module, func, args, captures);
    let mut cur = func.entry;
    loop {
        // Clone the per-block instruction slice + terminator so the
        // mutable frame borrow does not alias the read borrow on
        // the block's vec while we execute.
        let (insts, term) = {
            let block = frame.block(cur);
            (block.insts.clone(), block.terminator.clone())
        };
        for inst in &insts {
            exec_inst(&mut frame, inst, host)?;
        }
        match term {
            Terminator::Goto(next) => cur = next,
            Terminator::Branch { cond, t, f } => {
                let v = frame.read(cond);
                cur = if value_truthy(&v)? { t } else { f };
            }
            Terminator::Return(r) => {
                return Ok(r.map(|r| frame.read(r)).unwrap_or(Value::Unit));
            }
            Terminator::Throw(r) => return Err(EvalError::Throw(frame.read(r))),
            Terminator::Unreachable => {
                return Err(EvalError::Type("reached Terminator::Unreachable".into()));
            }
            Terminator::Switch { reg, arms, default } => {
                let v = frame.read(reg);
                let next = arms
                    .iter()
                    .find_map(|(c, b)| if const_matches(frame.module, *c, &v) { Some(*b) } else { None })
                    .unwrap_or(default);
                cur = next;
            }
        }
    }
}

fn exec_inst(
    frame: &mut Frame<'_>,
    inst: &Inst,
    host: &mut dyn Host,
) -> Result<(), EvalError> {
    match inst {
        Inst::Const { dst, value } => {
            let v = const_to_value(&frame.module.consts[value.0 as usize]);
            frame.write(*dst, v);
        }
        Inst::Move { dst, src } => {
            let v = frame.read(*src);
            frame.write(*dst, v);
        }
        Inst::Not { dst, src } => {
            let v = frame.read(*src);
            let b = match v {
                Value::Bool(b) => !b,
                _ => return Err(EvalError::Type("Not on non-bool".into())),
            };
            frame.write(*dst, Value::Bool(b));
        }
        Inst::UnOp { dst, op, operand } => {
            let v = frame.read(*operand);
            let out = apply_unop(*op, &v)?;
            frame.write(*dst, out);
        }
        Inst::BinOp { dst, op, lhs, rhs } => {
            let l = frame.read(*lhs);
            let r = frame.read(*rhs);
            let out = apply_binop(*op, &l, &r)?;
            frame.write(*dst, out);
        }
        Inst::Trace { .. } => {}
        Inst::LoadParam { dst, idx } => {
            let v = frame
                .params
                .get(*idx as usize)
                .cloned()
                .unwrap_or(Value::Unit);
            frame.write(*dst, v);
        }
        Inst::NotNullAssert { dst, src } => {
            let v = frame.read(*src);
            if matches!(v, Value::Null) {
                return Err(EvalError::Type("null-pointer assertion failed".into()));
            }
            frame.write(*dst, v);
        }
        Inst::GetField { dst, receiver, field } => {
            let r = frame.read(*receiver);
            let name = match &frame.module.consts[field.0 as usize] {
                Const::String(s) => s.clone(),
                _ => return Err(EvalError::Type("GetField: name not a string const".into())),
            };
            let v = match r {
                Value::Instance(inst) => inst.borrow().get(&name).unwrap_or(Value::Null),
                _ => return Err(EvalError::Type(format!("GetField on non-instance: {r:?}"))),
            };
            frame.write(*dst, v);
        }
        Inst::SetField { receiver, field, value } => {
            let r = frame.read(*receiver);
            let v = frame.read(*value);
            let name = match &frame.module.consts[field.0 as usize] {
                Const::String(s) => s.clone(),
                _ => return Err(EvalError::Type("SetField: name not a string const".into())),
            };
            match r {
                Value::Instance(inst) => {
                    inst.borrow_mut().define(&name, v);
                }
                _ => return Err(EvalError::Type(format!("SetField on non-instance: {r:?}"))),
            }
        }
        Inst::Call { dst, func, args, n_args } => {
            let arg_values = read_arg_run(frame, *args, *n_args);
            let result = host.call_func(frame.module, *func, arg_values)?;
            frame.write(*dst, result);
        }
        Inst::CallValue { dst, callee, args, n_args } => {
            let callee_v = frame.read(*callee);
            let arg_values = read_arg_run(frame, *args, *n_args);
            let result = host.call_value(&callee_v, &arg_values)?;
            frame.write(*dst, result);
        }
        Inst::CallMember { dst, receiver, name, args, n_args } => {
            let recv = frame.read(*receiver);
            let name_str = match &frame.module.consts[name.0 as usize] {
                Const::String(s) => s.clone(),
                _ => return Err(EvalError::Type("CallMember: name not a string const".into())),
            };
            let arg_values = read_arg_run(frame, *args, *n_args);
            let result = host.call_member(&recv, &name_str, &arg_values)?;
            frame.write(*dst, result);
        }
        Inst::NewInstance { dst, class, args, n_args } => {
            let arg_values = read_arg_run(frame, *args, *n_args);
            let result = host.new_instance(*class, &arg_values)?;
            frame.write(*dst, result);
        }
        Inst::InstanceOf { dst, src, ty } => {
            let v = frame.read(*src);
            let is = host.instance_of(&v, ty);
            frame.write(*dst, Value::Bool(is));
        }
        Inst::Cast { dst, src, ty, safe } => {
            let v = frame.read(*src);
            if host.instance_of(&v, ty) {
                frame.write(*dst, v);
            } else if *safe {
                frame.write(*dst, Value::Null);
            } else {
                return Err(EvalError::Type(format!(
                    "cast to `{}` failed for value {:?}",
                    ty.name, v
                )));
            }
        }
        Inst::Lambda { dst, body_func, captures } => {
            let cap_values: Vec<Value> = captures.iter().map(|r| frame.read(*r)).collect();
            let v = host.build_closure(frame.module, *body_func, cap_values)?;
            frame.write(*dst, v);
        }
        Inst::LoadGlobal { dst, name } => {
            let name_str = match &frame.module.consts[name.0 as usize] {
                Const::String(s) => s.clone(),
                _ => return Err(EvalError::Type("LoadGlobal: name not a string const".into())),
            };
            let v = host
                .lookup_global(&name_str)
                .ok_or_else(|| EvalError::Type(format!("unresolved global `{name_str}`")))?;
            frame.write(*dst, v);
        }
        Inst::LoadCapture { dst, idx } => {
            // Captures live in the frame's separate captures vec —
            // distinct from positional params so the closure body
            // can index by its own capture order.
            let v = frame
                .captures
                .get(*idx as usize)
                .cloned()
                .unwrap_or(Value::Unit);
            frame.write(*dst, v);
        }
        Inst::Index { dst, receiver, index } => {
            let r = frame.read(*receiver);
            let i = frame.read(*index);
            let result = host.call_member(&r, "get", &[i])?;
            frame.write(*dst, result);
        }
        Inst::IndexSet { receiver, index, value } => {
            let r = frame.read(*receiver);
            let i = frame.read(*index);
            let v = frame.read(*value);
            let _ = host.call_member(&r, "set", &[i, v])?;
        }
        Inst::NewList { dst, args, n_args } => {
            let items: Vec<Value> = read_arg_run(frame, *args, *n_args);
            frame.write(
                *dst,
                Value::List {
                    items: std::rc::Rc::new(std::cell::RefCell::new(items)),
                    mutable: false,
                    enum_class: None,
                },
            );
        }
    }
    Ok(())
}

/// Pull `n_args` register values starting at `args_start` into a
/// fresh Vec. Args are laid out contiguously by the lowering pass
/// in a `Move`-sequence, so reading the run is straight indexing.
fn read_arg_run(frame: &Frame<'_>, args_start: Reg, n: u8) -> Vec<Value> {
    let mut out = Vec::with_capacity(n as usize);
    for i in 0..n as u32 {
        let reg = Reg(args_start.0 + i);
        out.push(frame.read(reg));
    }
    out
}

fn value_truthy(v: &Value) -> Result<bool, EvalError> {
    match v {
        Value::Bool(b) => Ok(*b),
        _ => Err(EvalError::Type(format!("non-bool in branch: {v:?}"))),
    }
}

fn const_matches(module: &Module, id: crate::ConstId, v: &Value) -> bool {
    let lhs = const_to_value(&module.consts[id.0 as usize]);
    Value::structural_eq(&lhs, v)
}

fn const_to_value(c: &Const) -> Value {
    match c {
        Const::Unit => Value::Unit,
        Const::Int(i) => Value::Int(*i),
        Const::Long(l) => Value::Long(*l),
        Const::Double(d) => Value::Double(*d),
        Const::Float(f) => Value::Float(*f),
        Const::Bool(b) => Value::Bool(*b),
        Const::Char(c) => Value::Char(*c),
        Const::String(s) => Value::String(std::rc::Rc::new(s.clone())),
        Const::Null => Value::Null,
    }
}

fn apply_unop(op: UnOp, v: &Value) -> Result<Value, EvalError> {
    match (op, v) {
        (UnOp::Neg, Value::Int(i)) => Ok(Value::Int(-i)),
        (UnOp::Neg, Value::Long(l)) => Ok(Value::Long(-l)),
        (UnOp::Neg, Value::Double(d)) => Ok(Value::Double(-d)),
        (UnOp::Plus, v) => Ok(v.clone()),
        (UnOp::Inc, Value::Int(i)) => Ok(Value::Int(i.wrapping_add(1))),
        (UnOp::Inc, Value::Long(l)) => Ok(Value::Long(l.wrapping_add(1))),
        (UnOp::Dec, Value::Int(i)) => Ok(Value::Int(i.wrapping_sub(1))),
        (UnOp::Dec, Value::Long(l)) => Ok(Value::Long(l.wrapping_sub(1))),
        _ => Err(EvalError::Type(format!("UnOp::{op:?} on {v:?}"))),
    }
}

fn apply_binop(op: BinOp, l: &Value, r: &Value) -> Result<Value, EvalError> {
    use Value::{Bool, Double, Int, Long};
    match (op, l, r) {
        (BinOp::Add, Int(a), Int(b)) => Ok(Int(a.wrapping_add(*b))),
        (BinOp::Sub, Int(a), Int(b)) => Ok(Int(a.wrapping_sub(*b))),
        (BinOp::Mul, Int(a), Int(b)) => Ok(Int(a.wrapping_mul(*b))),
        (BinOp::Div, Int(_), Int(0)) => Err(EvalError::Type("division by zero".into())),
        (BinOp::Div, Int(a), Int(b)) => Ok(Int(a.wrapping_div(*b))),
        (BinOp::Mod, Int(_), Int(0)) => Err(EvalError::Type("mod by zero".into())),
        (BinOp::Mod, Int(a), Int(b)) => Ok(Int(a.wrapping_rem(*b))),
        (BinOp::Add, Long(a), Long(b)) => Ok(Long(a.wrapping_add(*b))),
        (BinOp::Sub, Long(a), Long(b)) => Ok(Long(a.wrapping_sub(*b))),
        (BinOp::Mul, Long(a), Long(b)) => Ok(Long(a.wrapping_mul(*b))),
        (BinOp::Add, Double(a), Double(b)) => Ok(Double(a + b)),
        (BinOp::Sub, Double(a), Double(b)) => Ok(Double(a - b)),
        (BinOp::Mul, Double(a), Double(b)) => Ok(Double(a * b)),
        (BinOp::Div, Double(a), Double(b)) => Ok(Double(a / b)),
        (BinOp::Eq, a, b) => Ok(Bool(Value::structural_eq(a, b))),
        (BinOp::NotEq, a, b) => Ok(Bool(!Value::structural_eq(a, b))),
        (BinOp::Less, Int(a), Int(b)) => Ok(Bool(a < b)),
        (BinOp::LessEq, Int(a), Int(b)) => Ok(Bool(a <= b)),
        (BinOp::Greater, Int(a), Int(b)) => Ok(Bool(a > b)),
        (BinOp::GreaterEq, Int(a), Int(b)) => Ok(Bool(a >= b)),
        (BinOp::And, Bool(a), Bool(b)) => Ok(Bool(*a && *b)),
        (BinOp::Or, Bool(a), Bool(b)) => Ok(Bool(*a || *b)),
        _ => Err(EvalError::Type(format!(
            "BinOp::{op:?} on {l:?} and {r:?}"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::build::FuncBuilder;
    use crate::{Const, Inst, TypeRef};

    fn lit(b: &mut FuncBuilder<'_>, v: i32) -> Reg {
        b.emit_const(Const::Int(v))
    }

    #[test]
    fn eval_int_const() {
        let mut m = Module::default();
        let mut b = FuncBuilder::new(&mut m);
        let r = lit(&mut b, 7);
        b.terminate(Terminator::Return(Some(r)));
        let func = b.finish("f", "test.f", TypeRef::int());
        let v = eval(&m, &func, Vec::new()).unwrap();
        assert!(matches!(v, Value::Int(7)));
    }

    #[test]
    fn eval_int_add() {
        let mut m = Module::default();
        let mut b = FuncBuilder::new(&mut m);
        let l = lit(&mut b, 2);
        let r = lit(&mut b, 40);
        let dst = b.alloc_reg();
        b.push(Inst::BinOp { dst, op: BinOp::Add, lhs: l, rhs: r });
        b.terminate(Terminator::Return(Some(dst)));
        let func = b.finish("f", "test.f", TypeRef::int());
        let v = eval(&m, &func, Vec::new()).unwrap();
        assert!(matches!(v, Value::Int(42)));
    }

    #[test]
    fn eval_load_param() {
        let mut m = Module::default();
        let mut b = FuncBuilder::new(&mut m);
        let p = b.alloc_reg();
        b.push(Inst::LoadParam { dst: p, idx: 0 });
        b.terminate(Terminator::Return(Some(p)));
        let func = b.finish("f", "test.f", TypeRef::int());
        let v = eval(&m, &func, vec![Value::Int(99)]).unwrap();
        assert!(matches!(v, Value::Int(99)));
    }

    #[test]
    fn eval_branch() {
        let mut m = Module::default();
        let mut b = FuncBuilder::new(&mut m);
        let cond = b.emit_const(Const::Bool(true));
        let t_blk = b.alloc_block();
        let f_blk = b.alloc_block();
        b.terminate(Terminator::Branch { cond, t: t_blk, f: f_blk });

        b.switch_to(t_blk);
        let t_val = lit(&mut b, 1);
        b.terminate(Terminator::Return(Some(t_val)));

        b.switch_to(f_blk);
        let f_val = lit(&mut b, 0);
        b.terminate(Terminator::Return(Some(f_val)));

        let func = b.finish("f", "test.f", TypeRef::int());
        let v = eval(&m, &func, Vec::new()).unwrap();
        assert!(matches!(v, Value::Int(1)));
    }
}
