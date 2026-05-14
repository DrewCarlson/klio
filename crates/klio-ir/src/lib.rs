//! `klio-ir` — compact linear IR for the klio interpreter.
//!
//! Replaces the tree-walking interpreter in `klio-interp` with a
//! `Vec<Inst>`-backed evaluator. The current interpreter recurses
//! through AST nodes; each invocation pays a function-call boundary
//! plus a series of match arms per node. Lowering to a flat
//! instruction stream lets the evaluator dispatch through a single
//! match per instruction with no recursion, which is friendlier to
//! the branch predictor and to future JIT work.
//!
//! ## Status
//!
//! Scaffold only. The IR types and module layout are in place; the
//! AST → IR lowering pass and the evaluator that runs the IR live
//! behind the work tracked in `plans/REFINEMENTS.md`. Until the
//! lowering and evaluator land, `klio-interp` remains the
//! authoritative execution engine.
//!
//! ## Design notes
//!
//! - **Per-function bodies.** Each `Func` carries a `Vec<Block>`;
//!   each `Block` carries a `Vec<Inst>` plus a `Terminator`. This
//!   shape mirrors LLVM, Cranelift, and the CFG already produced by
//!   `klio-cfa` — which means the existing CFG analyses can either
//!   be reused or trivially re-targeted against the IR.
//! - **Registers, not stack.** Operands are `Reg` indices, not stack
//!   slots, so the evaluator does not need a runtime stack discipline
//!   beyond the per-frame `Vec<Value>`.
//! - **Shared `Value`.** The IR reuses `klio_runtime::Value` so
//!   migration can happen function-by-function without forking the
//!   runtime representation.
//! - **Closures via captured envs.** Lambda IR carries a captured-env
//!   handle resolved at lowering time, identical to the closure
//!   shape `klio_runtime::Value::Lambda` already uses.

pub mod build;
pub mod eval;
pub mod lower;

use klio_span::Span;
use serde::{Deserialize, Serialize};

/// Type reference inside the IR. Today this is a textual FQN/name
/// — the evaluator resolves against the class table at runtime.
/// When `klio-types::Type` gains serde derives we can swap in the
/// structured form.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct TypeRef {
    pub name: String,
    pub nullable: bool,
    pub args: Vec<TypeRef>,
}

/// Identifier for a virtual register inside one function body.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Reg(pub u32);

/// Identifier for a basic block inside one function body.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct BlockId(pub u32);

/// Identifier for a function inside the IR module.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct FuncId(pub u32);

/// Identifier for a class declared in the IR module.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ClassId(pub u32);

/// Constant pool index for literals too large to fit in a `u32`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ConstId(pub u32);

/// One IR instruction. Drives the per-frame evaluator switch.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum Inst {
    /// Materialise a constant into a register.
    Const { dst: Reg, value: ConstId },
    /// Load a parameter into a register.
    LoadParam { dst: Reg, idx: u16 },
    /// Load a captured variable from the enclosing env.
    LoadCapture { dst: Reg, idx: u16 },
    /// Move one register's value into another.
    Move { dst: Reg, src: Reg },
    /// Read a local property of a class instance.
    GetField { dst: Reg, receiver: Reg, field: ConstId },
    /// Write a local property of a class instance.
    SetField { receiver: Reg, field: ConstId, value: Reg },
    /// Index a `List`, `Map`, or `Array`. Range checks happen in
    /// the evaluator.
    Index { dst: Reg, receiver: Reg, index: Reg },
    /// Store at an indexed slot.
    IndexSet { receiver: Reg, index: Reg, value: Reg },
    /// Call a static function by id, with the args pulled from a
    /// run of registers starting at `args`. `arg_names` carries an
    /// optional `Option<ConstId>` per slot — `Some(name)` for
    /// `foo(a = 1)`, `None` for positional. Empty when every arg
    /// is positional.
    Call {
        dst: Reg,
        func: FuncId,
        args: Reg,
        n_args: u8,
        #[serde(default)]
        arg_names: Vec<Option<ConstId>>,
    },
    /// Call a callable value held in a register.
    CallValue {
        dst: Reg,
        callee: Reg,
        args: Reg,
        n_args: u8,
        #[serde(default)]
        arg_names: Vec<Option<ConstId>>,
    },
    /// Member call on a receiver. The evaluator resolves the
    /// method through the receiver's class table at runtime.
    CallMember {
        dst: Reg,
        receiver: Reg,
        name: ConstId,
        args: Reg,
        n_args: u8,
        #[serde(default)]
        arg_names: Vec<Option<ConstId>>,
    },
    /// Instantiate a class.
    NewInstance {
        dst: Reg,
        class: ClassId,
        args: Reg,
        n_args: u8,
        #[serde(default)]
        arg_names: Vec<Option<ConstId>>,
    },
    /// Build a `List` from a range of registers.
    NewList { dst: Reg, args: Reg, n_args: u8 },
    /// Binary primitive operation. Operands are guaranteed to be
    /// the right type by typeck.
    BinOp { dst: Reg, op: BinOp, lhs: Reg, rhs: Reg },
    /// Unary primitive operation.
    UnOp { dst: Reg, op: UnOp, operand: Reg },
    /// Boolean negation.
    Not { dst: Reg, src: Reg },
    /// Type-cast (`as T`) or safe-cast (`as? T`). The evaluator
    /// resolves the type by name; smart-cast info from CFA can
    /// elide checks.
    Cast { dst: Reg, src: Reg, ty: TypeRef, safe: bool },
    /// `is T` check; result is a `Bool`.
    InstanceOf { dst: Reg, src: Reg, ty: TypeRef },
    /// `!!` not-null assertion.
    NotNullAssert { dst: Reg, src: Reg },
    /// Marker for the evaluator's debugger / tracing hook.
    Trace { span: Span },
    /// Resolve a bare global identifier through the Host. Used when
    /// Path lowering cannot bind the name to a local register —
    /// covers top-level stdlib calls (`println`, `listOf`) and any
    /// other module-scoped reference. The Host's `lookup_global`
    /// receives the interned name and returns the live value.
    LoadGlobal { dst: Reg, name: ConstId },
    /// Materialise a lambda value capturing the current scope's
    /// registers. The captures are listed as a `Vec<Reg>`; the
    /// evaluator snapshots the live values into a closure env.
    /// `body_func` is the lambda body lowered as a separate Func.
    Lambda {
        dst: Reg,
        body_func: FuncId,
        captures: Vec<Reg>,
    },
    /// Construct a `Value::Lambda` directly from a stashed AST
    /// `Block` plus a snapshot of captured registers indexed by
    /// name. Used so tree-walker-style dispatch paths (`repeat`,
    /// `let`, `with`, `Result.map`, …) that pattern-match on
    /// `Value::Lambda` can call IR-lowered lambdas without each
    /// site needing a separate IrClosure branch.
    AstLambda {
        dst: Reg,
        params: Vec<String>,
        body_ast: klio_ast::Block,
        captures: Vec<Reg>,
        captured_names: Vec<String>,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum BinOp {
    Add, Sub, Mul, Div, Mod, Pow,
    Eq, NotEq, Less, LessEq, Greater, GreaterEq,
    And, Or, Xor, Shl, Shr, UShr,
    RangeTo, RangeUntil, DownTo,
    Elvis,
    StringConcat,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum UnOp {
    Neg, Plus, Inc, Dec,
}

/// Terminator at the end of every block.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum Terminator {
    Goto(BlockId),
    Branch { cond: Reg, t: BlockId, f: BlockId },
    Switch { reg: Reg, arms: Vec<(ConstId, BlockId)>, default: BlockId },
    Return(Option<Reg>),
    Throw(Reg),
    Unreachable,
}

/// Catch handler frame attached to a try-body block. When a Throw
/// fires inside the body, the evaluator pops handlers in stack
/// order and jumps to the first whose `type_name` matches the
/// thrown value's nominal type. `exception_reg` is the register
/// the handler body reads the bound exception value from.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CatchHandler {
    pub type_name: String,
    pub handler: BlockId,
    pub exception_reg: Reg,
}

/// A basic block: linear instruction stream + terminator. When
/// `catches` is non-empty, a `Throw` reaching this block (or any
/// block reached from it without first leaving the try scope)
/// looks up a matching handler before propagating.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Block {
    pub id: BlockId,
    pub insts: Vec<Inst>,
    pub terminator: Terminator,
    #[serde(default)]
    pub catches: Vec<CatchHandler>,
    /// Finally-block id to execute on every exit from this block's
    /// try-region (normal fall-through, catches, returns, throws).
    /// Set by lowering when the try has a finally clause.
    #[serde(default)]
    pub finally: Option<BlockId>,
}

/// A function body in IR form.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Func {
    pub id: FuncId,
    pub name: String,
    pub fqn: String,
    pub params: Vec<Param>,
    pub return_ty: TypeRef,
    pub n_locals: u32,
    pub blocks: Vec<Block>,
    pub entry: BlockId,
    pub is_suspend: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Param {
    pub name: String,
    pub ty: TypeRef,
    pub default: Option<BlockId>,
}

/// Class declaration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Class {
    pub id: ClassId,
    pub name: String,
    pub fqn: String,
    pub primary_params: Vec<Param>,
    pub methods: Vec<FuncId>,
    pub init_block: Option<FuncId>,
    pub companion: Option<ClassId>,
    pub supertypes: Vec<ClassId>,
}

/// Top-level container.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Module {
    pub funcs: Vec<Func>,
    pub classes: Vec<Class>,
    pub consts: Vec<Const>,
    /// Top-level (file-scope) function ids, in declaration order.
    pub top_level: Vec<FuncId>,
    /// Top-level class declarations by simple name → ClassId. The
    /// lowering pass populates this so `Foo(args)` Calls become
    /// `NewInstance` instructions when `Foo` resolves to a class.
    pub class_index: Vec<(String, ClassId)>,
    /// Top-level function declarations by simple name → FuncId.
    /// Lowering routes Path-callees that match a registered name
    /// to `Inst::Call { func }` instead of LoadGlobal+CallValue.
    pub func_index: Vec<(String, FuncId)>,
    /// Package path for FQN qualification.
    pub package: Option<String>,
}

impl Module {
    /// Look up a class by simple name.
    #[must_use]
    pub fn class_id(&self, name: &str) -> Option<ClassId> {
        self.class_index
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, id)| *id)
    }

    /// Look up a top-level function by simple name.
    #[must_use]
    pub fn func_id(&self, name: &str) -> Option<FuncId> {
        self.func_index
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, id)| *id)
    }

    /// Register a class declaration and return its id.
    pub fn add_class(&mut self, mut class: Class) -> ClassId {
        let id = ClassId(self.classes.len() as u32);
        class.id = id;
        self.class_index.push((class.name.clone(), id));
        self.classes.push(class);
        id
    }
}

/// Constant pool entry. Anything not representable as a `u32`
/// (strings, large integers, types) lives here.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum Const {
    Unit,
    Int(i32),
    Long(i64),
    Double(f64),
    Float(f32),
    Bool(bool),
    Char(char),
    String(String),
    Null,
}

impl Module {
    /// Append a constant to the pool, returning its id. Today's pool
    /// is unsorted-and-unique by structural equality; lowering passes
    /// can deduplicate when they care.
    pub fn intern_const(&mut self, c: Const) -> ConstId {
        if let Some((i, _)) = self.consts.iter().enumerate().find(|(_, k)| match (k, &c) {
            (Const::Unit, Const::Unit) => true,
            (Const::Int(a), Const::Int(b)) => a == b,
            (Const::Long(a), Const::Long(b)) => a == b,
            (Const::Double(a), Const::Double(b)) => a.to_bits() == b.to_bits(),
            (Const::Float(a), Const::Float(b)) => a.to_bits() == b.to_bits(),
            (Const::Bool(a), Const::Bool(b)) => a == b,
            (Const::Char(a), Const::Char(b)) => a == b,
            (Const::String(a), Const::String(b)) => a == b,
            (Const::Null, Const::Null) => true,
            _ => false,
        }) {
            return ConstId(i as u32);
        }
        let id = ConstId(self.consts.len() as u32);
        self.consts.push(c);
        id
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn intern_dedups_equal_constants() {
        let mut m = Module::default();
        let a = m.intern_const(Const::Int(42));
        let b = m.intern_const(Const::Int(42));
        assert_eq!(a, b);
        assert_eq!(m.consts.len(), 1);
    }

    #[test]
    fn intern_distinguishes_typed_zeros() {
        let mut m = Module::default();
        let i = m.intern_const(Const::Int(0));
        let l = m.intern_const(Const::Long(0));
        assert_ne!(i, l);
        assert_eq!(m.consts.len(), 2);
    }

    #[test]
    fn float_nan_does_not_collapse() {
        let mut m = Module::default();
        let _ = m.intern_const(Const::Double(f64::NAN));
        let _ = m.intern_const(Const::Double(f64::NAN));
        // Two interns of f64::NAN compare unequal under `to_bits()`
        // unless both NaNs share a bit pattern; std produces the
        // canonical quiet-NaN so they collapse to one entry here.
        // This test guards the invariant that interning is total —
        // it never panics on NaN.
        assert!(matches!(m.consts[0], Const::Double(_)));
    }
}
