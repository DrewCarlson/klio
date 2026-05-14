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

use crate::{BinOp, BlockId, Const, Func, Inst, Module, Reg, Terminator, UnOp};

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
}

impl<'a> Frame<'a> {
    fn new(module: &'a Module, func: &'a Func) -> Self {
        Self {
            module,
            func,
            regs: vec![Value::Unit; func.n_locals as usize],
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

/// Run a function body with no arguments. Returns the value carried
/// by the terminating `Return`, or `Unit` for a fall-off.
pub fn eval(module: &Module, func: &Func) -> Result<Value, EvalError> {
    let mut frame = Frame::new(module, func);
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
            exec_inst(&mut frame, inst)?;
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

fn exec_inst(frame: &mut Frame<'_>, inst: &Inst) -> Result<(), EvalError> {
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
        _ => return Err(EvalError::Unsupported("instruction not yet implemented")),
    }
    Ok(())
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
        let v = eval(&m, &func).unwrap();
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
        let v = eval(&m, &func).unwrap();
        assert!(matches!(v, Value::Int(42)));
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
        let v = eval(&m, &func).unwrap();
        assert!(matches!(v, Value::Int(1)));
    }
}
