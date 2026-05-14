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
    /// Same as `call_value` but with named-arg metadata. Default
    /// drops the names and routes through `call_value`.
    fn call_value_named(
        &mut self,
        callee: &Value,
        args: &[Value],
        _arg_names: &[Option<String>],
    ) -> Result<Value, EvalError> {
        self.call_value(callee, args)
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
    fn call_member_named(
        &mut self,
        receiver: &Value,
        name: &str,
        args: &[Value],
        _arg_names: &[Option<String>],
    ) -> Result<Value, EvalError> {
        self.call_member(receiver, name, args)
    }
    /// Construct an instance of a class referenced by ID. The
    /// implementation looks up the corresponding ClassDef and
    /// invokes the primary constructor with the supplied args.
    fn new_instance(&mut self, _class: crate::ClassId, _args: &[Value]) -> Result<Value, EvalError> {
        Err(EvalError::Unsupported("Host::new_instance"))
    }
    fn new_instance_named(
        &mut self,
        class: crate::ClassId,
        args: &[Value],
        _arg_names: &[Option<String>],
    ) -> Result<Value, EvalError> {
        self.new_instance(class, args)
    }
    /// Read a property on the receiver. Default for instances is
    /// the raw field lookup via `InstanceData::get`; concrete
    /// hosts route through the tree walker's
    /// `eval_property_access` so getters / delegates / extension
    /// properties fire.
    fn get_field(
        &mut self,
        receiver: &Value,
        name: &str,
    ) -> Result<Value, EvalError> {
        match receiver {
            Value::Instance(inst) => Ok(inst.borrow().get(name).unwrap_or(Value::Null)),
            _ => Err(EvalError::Type(format!(
                "GetField on non-instance: {receiver:?}"
            ))),
        }
    }

    /// Write a property on the receiver. Default writes directly to
    /// the instance backing store; concrete hosts route through the
    /// tree walker's assignment path so extension-property setters
    /// fire.
    fn set_field(
        &mut self,
        receiver: &Value,
        name: &str,
        value: Value,
    ) -> Result<(), EvalError> {
        match receiver {
            Value::Instance(inst) => {
                inst.borrow_mut().define(name, value);
                Ok(())
            }
            Value::Null => Ok(()),
            _ => Err(EvalError::Type(format!(
                "SetField on non-instance: {receiver:?}"
            ))),
        }
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

    /// Build a `Value::Lambda`-compatible closure straight from an
    /// AST block. Concrete hosts populate the captured env from
    /// `captures` and produce a Value the tree walker's lambda
    /// dispatch (call_lambda etc.) can consume directly.
    fn build_ast_lambda(
        &mut self,
        _params: &[String],
        _body: &klio_ast::Block,
        _captured_names: &[String],
        _captures: Vec<Value>,
    ) -> Result<Value, EvalError> {
        Err(EvalError::Unsupported("Host::build_ast_lambda"))
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
    fn call_func_named(
        &mut self,
        module: &Module,
        func: FuncId,
        args: Vec<Value>,
        _arg_names: &[Option<String>],
    ) -> Result<Value, EvalError> {
        self.call_func(module, func, args)
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
    let mut try_stack: Vec<(BlockId, Vec<crate::CatchHandler>, Option<BlockId>)> = Vec::new();
    let mut frame = Frame::new_with_captures(module, func, args, captures);
    let _ = &mut try_stack;
    let mut cur = func.entry;
    loop {
        // Push any catch / finally metadata attached to this block.
        let (insts, term, catches, finally) = {
            let block = frame.block(cur);
            (
                block.insts.clone(),
                block.terminator.clone(),
                block.catches.clone(),
                block.finally,
            )
        };
        if !catches.is_empty() || finally.is_some() {
            try_stack.push((cur, catches, finally));
        }
        let mut thrown: Option<Value> = None;
        for inst in &insts {
            match exec_inst(&mut frame, inst, host) {
                Ok(()) => {}
                Err(EvalError::Throw(v)) => { thrown = Some(v); break; }
                Err(e) => return Err(e),
            }
        }
        if let Some(exc) = thrown {
            // Mid-block throw — same try-stack walk as Terminator::Throw.
            let mut routed = false;
            while let Some((_blk, hcatches, hfinally)) = try_stack.pop() {
                if let Some(h) = hcatches.iter().find(|h| host.instance_of(
                    &exc,
                    &TypeRef {
                        name: h.type_name.clone(),
                        nullable: false,
                        args: Vec::new(),
                    },
                )) {
                    frame.write(h.exception_reg, exc.clone());
                    cur = h.handler;
                    routed = true;
                    break;
                } else if let Some(fin) = hfinally {
                    cur = fin;
                    routed = true;
                    break;
                }
            }
            if !routed {
                return Err(EvalError::Throw(exc));
            }
            continue;
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
            Terminator::Throw(r) => {
                let exc = frame.read(r);
                // Walk the try stack for a matching handler.
                let mut routed = false;
                while let Some((_blk, hcatches, hfinally)) = try_stack.pop() {
                    if let Some(h) = hcatches.iter().find(|h| host.instance_of(
                        &exc,
                        &TypeRef {
                            name: h.type_name.clone(),
                            nullable: false,
                            args: Vec::new(),
                        },
                    )) {
                        // Bind exception, jump to handler.
                        frame.write(h.exception_reg, exc.clone());
                        cur = h.handler;
                        routed = true;
                        break;
                    } else if let Some(fin) = hfinally {
                        // No matching catch on this frame — run
                        // finally then re-throw by re-installing
                        // it as the next terminator path. For the
                        // simple model, we route to finally then
                        // propagate by returning Throw afterwards.
                        cur = fin;
                        routed = true;
                        break;
                    }
                }
                if !routed {
                    return Err(EvalError::Throw(exc));
                }
            }
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
            // User-class operator dispatch for unary +/-/inc/dec.
            if matches!(v, Value::Instance(_)) {
                let method = match op {
                    UnOp::Neg => Some("unaryMinus"),
                    UnOp::Plus => Some("unaryPlus"),
                    UnOp::Inc => Some("inc"),
                    UnOp::Dec => Some("dec"),
                };
                if let Some(m) = method {
                    let result = host.call_member(&v, m, &[])?;
                    frame.write(*dst, result);
                    return Ok(());
                }
            }
            let out = apply_unop(*op, &v)?;
            frame.write(*dst, out);
        }
        Inst::BinOp { dst, op, lhs, rhs } => {
            let l = frame.read(*lhs);
            let r = frame.read(*rhs);
            // StringConcat over a Value::Instance routes the
            // instance through toString so user-defined overrides
            // fire (e.g. `Instant.toString()` → ISO-8601).
            if matches!(op, BinOp::StringConcat) {
                let ls = stringify(host, &l)?;
                let rs = stringify(host, &r)?;
                let combined = format!("{ls}{rs}");
                frame.write(*dst, Value::String(std::rc::Rc::new(combined)));
                return Ok(());
            }
            // User-class operator dispatch: when an operand is a
            // Value::Instance, route through the host's
            // call_member for the matching operator method
            // (plus/minus/times/div/rem/compareTo/equals/etc.).
            if let Some(method) = operator_method(*op) {
                if matches!(l, Value::Instance(_)) || matches!(r, Value::Instance(_)) {
                    let result = host.call_member(&l, method, std::slice::from_ref(&r))?;
                    // compareTo wrappers (Less/LessEq/Greater/GreaterEq)
                    // need to be reduced to a Bool.
                    let final_val = match *op {
                        BinOp::Less => Value::Bool(value_to_i64(&result).map_or(false, |i| i < 0)),
                        BinOp::LessEq => Value::Bool(value_to_i64(&result).map_or(false, |i| i <= 0)),
                        BinOp::Greater => Value::Bool(value_to_i64(&result).map_or(false, |i| i > 0)),
                        BinOp::GreaterEq => Value::Bool(value_to_i64(&result).map_or(false, |i| i >= 0)),
                        _ => result,
                    };
                    frame.write(*dst, final_val);
                    return Ok(());
                }
            }
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
                let exc = Value::Exception {
                    fqn: std::rc::Rc::new("kotlin.NullPointerException".into()),
                    message: None,
                    cause: None,
                };
                return Err(EvalError::Throw(exc));
            }
            frame.write(*dst, v);
        }
        Inst::GetField { dst, receiver, field } => {
            let r = frame.read(*receiver);
            let name = match &frame.module.consts[field.0 as usize] {
                Const::String(s) => s.clone(),
                _ => return Err(EvalError::Type("GetField: name not a string const".into())),
            };
            let v = host.get_field(&r, &name)?;
            frame.write(*dst, v);
        }
        Inst::SetField { receiver, field, value } => {
            let r = frame.read(*receiver);
            let v = frame.read(*value);
            let name = match &frame.module.consts[field.0 as usize] {
                Const::String(s) => s.clone(),
                _ => return Err(EvalError::Type("SetField: name not a string const".into())),
            };
            host.set_field(&r, &name, v)?;
        }
        Inst::Call { dst, func, args, n_args, arg_names } => {
            let arg_values = read_arg_run(frame, *args, *n_args);
            let names = resolve_arg_names(frame.module, arg_names);
            let result = host.call_func_named(frame.module, *func, arg_values, &names)?;
            frame.write(*dst, result);
        }
        Inst::CallValue { dst, callee, args, n_args, arg_names } => {
            let callee_v = frame.read(*callee);
            let arg_values = read_arg_run(frame, *args, *n_args);
            let names = resolve_arg_names(frame.module, arg_names);
            let result = host.call_value_named(&callee_v, &arg_values, &names)?;
            frame.write(*dst, result);
        }
        Inst::CallMember { dst, receiver, name, args, n_args, arg_names } => {
            let recv = frame.read(*receiver);
            let name_str = match &frame.module.consts[name.0 as usize] {
                Const::String(s) => s.clone(),
                _ => return Err(EvalError::Type("CallMember: name not a string const".into())),
            };
            let arg_values = read_arg_run(frame, *args, *n_args);
            let names = resolve_arg_names(frame.module, arg_names);
            let result = host.call_member_named(&recv, &name_str, &arg_values, &names)?;
            frame.write(*dst, result);
        }
        Inst::NewInstance { dst, class, args, n_args, arg_names } => {
            let arg_values = read_arg_run(frame, *args, *n_args);
            let names = resolve_arg_names(frame.module, arg_names);
            let result = host.new_instance_named(*class, &arg_values, &names)?;
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
        Inst::AstLambda { dst, params, body_ast, captures, captured_names } => {
            let cap_values: Vec<Value> = captures.iter().map(|r| frame.read(*r)).collect();
            let v = host.build_ast_lambda(params, body_ast, captured_names, cap_values)?;
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

/// Resolve a per-call `arg_names: Vec<Option<ConstId>>` into a
/// parallel `Vec<Option<String>>`. Empty input yields an empty
/// output — callers treat that as "every arg positional".
fn resolve_arg_names(module: &Module, names: &[Option<crate::ConstId>]) -> Vec<Option<String>> {
    names
        .iter()
        .map(|opt| {
            opt.and_then(|id| match &module.consts[id.0 as usize] {
                Const::String(s) => Some(s.clone()),
                _ => None,
            })
        })
        .collect()
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

/// Render a Value to its Kotlin string representation. For
/// Value::Instance, dispatches `toString()` through the host so
/// user-defined overrides fire; primitives use `render_value`'s
/// fast path.
fn stringify(host: &mut dyn Host, v: &Value) -> Result<String, EvalError> {
    if let Value::Instance(_) = v {
        let result = host.call_member(v, "toString", &[])?;
        if let Value::String(s) = result {
            return Ok(s.as_str().to_string());
        }
        return Ok(render_value(&result));
    }
    Ok(render_value(v))
}

fn value_to_i64(v: &Value) -> Option<i64> {
    match v {
        Value::Int(i) => Some(*i as i64),
        Value::Long(l) => Some(*l),
        _ => None,
    }
}

/// Operator-name a BinOp dispatches through when one operand is a
/// user class. Returns `None` for ops that have no operator-method
/// counterpart (e.g. boolean short-circuits).
fn operator_method(op: BinOp) -> Option<&'static str> {
    Some(match op {
        BinOp::Add => "plus",
        BinOp::Sub => "minus",
        BinOp::Mul => "times",
        BinOp::Div => "div",
        BinOp::Mod => "rem",
        BinOp::Eq => "equals",
        BinOp::Less | BinOp::LessEq | BinOp::Greater | BinOp::GreaterEq => "compareTo",
        BinOp::RangeTo => "rangeTo",
        BinOp::RangeUntil => "rangeUntil",
        _ => return None,
    })
}

fn render_value(v: &Value) -> String {
    match v {
        Value::Unit => "kotlin.Unit".to_string(),
        Value::Int(i) => i.to_string(),
        Value::Long(l) => l.to_string(),
        Value::Short(s) => s.to_string(),
        Value::Byte(b) => b.to_string(),
        Value::UInt(u) => u.to_string(),
        Value::ULong(u) => u.to_string(),
        Value::UShort(u) => u.to_string(),
        Value::UByte(u) => u.to_string(),
        Value::Double(d) => {
            if d.is_finite() && d.fract() == 0.0 && !d.is_sign_negative() && d.abs() < 1e16 {
                format!("{d:.1}")
            } else if d.is_finite() && d.fract() == 0.0 && d.is_sign_negative() && d.abs() < 1e16 {
                format!("{d:.1}")
            } else {
                format!("{d}")
            }
        }
        Value::Float(f) => {
            if f.is_finite() && f.fract() == 0.0 && f.abs() < 1e7 {
                format!("{f:.1}")
            } else {
                format!("{f}")
            }
        }
        Value::Bool(b) => b.to_string(),
        Value::String(s) => s.as_str().to_string(),
        Value::Char(c) => c.to_string(),
        Value::Null => "null".to_string(),
        _ => format!("{v}"),
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
        (BinOp::Less, Long(a), Long(b)) => Ok(Bool(a < b)),
        (BinOp::LessEq, Long(a), Long(b)) => Ok(Bool(a <= b)),
        (BinOp::Greater, Long(a), Long(b)) => Ok(Bool(a > b)),
        (BinOp::GreaterEq, Long(a), Long(b)) => Ok(Bool(a >= b)),
        (BinOp::Less, Double(a), Double(b)) => Ok(Bool(a < b)),
        (BinOp::LessEq, Double(a), Double(b)) => Ok(Bool(a <= b)),
        (BinOp::Greater, Double(a), Double(b)) => Ok(Bool(a > b)),
        (BinOp::GreaterEq, Double(a), Double(b)) => Ok(Bool(a >= b)),
        (BinOp::Less, Value::String(a), Value::String(b)) => Ok(Bool(a.as_str() < b.as_str())),
        (BinOp::LessEq, Value::String(a), Value::String(b)) => Ok(Bool(a.as_str() <= b.as_str())),
        (BinOp::Greater, Value::String(a), Value::String(b)) => Ok(Bool(a.as_str() > b.as_str())),
        (BinOp::GreaterEq, Value::String(a), Value::String(b)) => Ok(Bool(a.as_str() >= b.as_str())),
        (BinOp::And, Bool(a), Bool(b)) => Ok(Bool(*a && *b)),
        (BinOp::Or, Bool(a), Bool(b)) => Ok(Bool(*a || *b)),
        (BinOp::RangeTo, Int(a), Int(b)) => Ok(Value::Range {
            start: *a as i64,
            end: *b as i64,
            step: 1,
            kind: klio_runtime::RangeKind::Int,
        }),
        (BinOp::RangeUntil, Int(a), Int(b)) => Ok(Value::Range {
            start: *a as i64,
            end: (*b as i64) - 1,
            step: 1,
            kind: klio_runtime::RangeKind::Int,
        }),
        (BinOp::RangeTo, Long(a), Long(b)) => Ok(Value::Range {
            start: *a, end: *b, step: 1, kind: klio_runtime::RangeKind::Long,
        }),
        (BinOp::StringConcat, a, b) => {
            let mut s = render_value(a);
            s.push_str(&render_value(b));
            Ok(Value::String(std::rc::Rc::new(s)))
        }
        (BinOp::Add, Value::String(a), b) => {
            let mut s = a.as_str().to_string();
            s.push_str(&render_value(b));
            Ok(Value::String(std::rc::Rc::new(s)))
        }
        (BinOp::Add, a, Value::String(b)) => {
            let mut s = render_value(a);
            s.push_str(b.as_str());
            Ok(Value::String(std::rc::Rc::new(s)))
        }
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
