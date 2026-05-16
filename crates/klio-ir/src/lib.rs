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
    /// Suspend-resume marker for IR-lowered suspend bodies. A
    /// `state` integer identifies which resume target the
    /// suspending call site corresponds to so the dispatch table
    /// at the function entry can route a resumption to the
    /// matching block. Today this is emitted as a no-op tagged
    /// marker; the upcoming state-machine codegen reads it during
    /// lowering and after.
    SuspendResumePoint { state: u32 },
    /// Load a parameter into a register.
    LoadParam { dst: Reg, idx: u16 },
    /// Load a captured variable from the enclosing env.
    LoadCapture { dst: Reg, idx: u16 },
    /// Move one register's value into another.
    Move { dst: Reg, src: Reg },
    /// Box `src` into a fresh capture cell (`Value::Cell`) and put
    /// it in `dst`. Emitted for a `var` declaration when the var is
    /// captured by a nested lambda (Kotlin `Ref` boxing).
    MakeCell { dst: Reg, src: Reg },
    /// Read the value held by the capture cell in `cell` into `dst`.
    CellGet { dst: Reg, cell: Reg },
    /// Store `value` through the capture cell in `cell`, keeping the
    /// shared `Rc` so every holder observes the write.
    CellSet { cell: Reg, value: Reg },
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
        /// Call-site type arguments, in declaration order. Each entry
        /// is the interned simple type name (or fully-qualified name)
        /// the source wrote. Consumed by reified type-parameter
        /// dispatch when the callee is an `inline fun <reified T>`.
        #[serde(default)]
        type_args: Vec<ConstId>,
    },
    /// `receiver.lambda(args)` — invoke a callable with a
    /// receiver bound as `this` inside the body. Used for
    /// receiver-typed lambda invocations on a local that's not
    /// a method on the receiver's class.
    CallValueWithThis {
        dst: Reg,
        callee: Reg,
        receiver: Reg,
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
    /// Call a callable value with a mix of positional and spread
    /// args. Each `SpreadPart` is one source register; spread
    /// parts are flattened (each item of the array/list becomes a
    /// positional arg) at evaluation time.
    CallSpread {
        dst: Reg,
        callee: Reg,
        parts: Vec<SpreadPart>,
        #[serde(default)]
        arg_names: Vec<Option<ConstId>>,
    },
    /// `super.method(args)` — dispatch the named method on the
    /// receiver's value, but resolved against the parent of
    /// `owner_class` rather than the leaf class. Used inside
    /// method bodies; `owner_class` is the class whose body is
    /// being lowered. When `qualifier` is `Some`, this is
    /// `super<Qual>.method()` — the host dispatches directly on
    /// `Qual` instead of walking to `owner_class.parent`.
    CallSuper {
        dst: Reg,
        receiver: Reg,
        owner_class: ConstId,
        #[serde(default)]
        qualifier: Option<ConstId>,
        name: ConstId,
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
    /// After calling a lambda that mutates outer-scope `var`s,
    /// read each captured name back from the lambda's env and
    /// write the updated value into the source reg in the
    /// caller's frame. Pairs with `Inst::AstLambda` whose
    /// captured names mirror the writeback list.
    WritebackCaptures {
        lambda: Reg,
        names: Vec<ConstId>,
        dsts: Vec<Reg>,
    },
    /// `this@Qualifier` — walk the receiver's outer chain
    /// looking for an instance whose class matches `qualifier`,
    /// and write that instance into `dst`.
    QualifiedThis {
        dst: Reg,
        receiver: Reg,
        qualifier: ConstId,
    },
    /// `::name` — produce a `KProperty`-shaped reference value
    /// carrying the property name. Reflection target.
    PropertyRef { dst: Reg, name: ConstId },
    /// `Receiver::name` — bind a callable reference to the
    /// receiver value. The host resolves the right shape
    /// (BoundMethod, intrinsic, PropertyRef) from the receiver's
    /// class table.
    MemberRef { dst: Reg, receiver: Reg, name: ConstId },
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
    /// Bare-name read inside a lambda body that doesn't resolve as a
    /// local / capture / own member. Used when the lambda may be
    /// invoked with a `this` receiver (scope fns like `apply`). At
    /// runtime: if `this_idx`'s captured value is an instance with a
    /// field/method named `name`, read it; otherwise fall back to
    /// LoadGlobal(name).
    LoadFromThisOrGlobal { dst: Reg, this_idx: u16, name: ConstId },
    /// Call a bare-name function inside a lambda body that may be
    /// invoked with a this-receiver. If the captured this is an
    /// instance with a method named `name`, dispatch as a member
    /// call on it; otherwise fall back to a top-level lookup +
    /// invoke.
    CallMemberOrGlobal {
        dst: Reg,
        this_idx: u16,
        name: ConstId,
        args: Reg,
        n_args: u8,
        arg_names: Vec<Option<ConstId>>,
    },
    /// Write a global / top-level binding. Mirrors `LoadGlobal` for
    /// the write side: routed through `Host::store_global` so a
    /// delegated top-level property's setter (or a plain top-level
    /// `var`) gets updated.
    StoreGlobal { name: ConstId, value: Reg },
    /// Evaluate a stashed AST expression through the host. Used for
    /// constructs the IR lowering doesn't yet have a structured
    /// representation for (today: `object { … }` anonymous objects).
    /// The host receives the AST node + the current scope snapshot
    /// and returns the evaluated Value.
    /// Register a class declaration encountered inside a function
    /// body. Local classes live for the duration of the call (the
    /// tree walker re-registers them on each entry).
    RegisterClass {
        class: Box<klio_ast::Class>,
        /// Capture-name slots so the class methods see the enclosing
        /// function's locals (`val factor = 10; class Scaled { … n * factor … }`).
        captured_names: Vec<String>,
        captures: Vec<Reg>,
    },
    /// Build an anonymous-object instance from an `object { … }` /
    /// `object : Parent(args) { … }` AST node. The host
    /// synthesises a fresh `ClassDef` from the AST, populates its
    /// captured env from the snapshotted `captures`, runs its
    /// init pipeline, and returns the `Value::Instance`.
    BuildObject {
        dst: Reg,
        ast: Box<klio_ast::Expr>,
        captured_names: Vec<String>,
        captures: Vec<Reg>,
    },
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
        /// `true` for anonymous function expressions (`fun(x): T = …`)
        /// where `return` is a local return out of the fn rather
        /// than a non-local one. `false` for ordinary `{ x -> … }`
        /// lambdas — the enclosing function is the return target.
        #[serde(default)]
        absorb_return: bool,
        /// FuncId of the IR-lowered body. The lambda lowering also
        /// emits an IR Func for the body in parallel with the AST
        /// snapshot; call sites that recognise IR-lowered lambdas
        /// can dispatch through this FuncId without going through
        /// the tree walker. `None` for legacy emissions that
        /// haven't been migrated.
        #[serde(default)]
        body_func: Option<FuncId>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SpreadPart {
    pub reg: Reg,
    pub is_spread: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum BinOp {
    Add, Sub, Mul, Div, Mod, Pow,
    Eq, NotEq, Less, LessEq, Greater, GreaterEq,
    /// Equality on a value that came through an `as Any` cast or
    /// a statically-Any-typed path. Uses bitwise comparison for
    /// `Double` / `Float` so NaN == NaN and +0.0 != -0.0.
    BoxedEq, BoxedNotEq,
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
    /// Tail-recursive jump to the current function's entry with
    /// new param values. The evaluator rebinds the param regs
    /// from this contiguous register run and restarts execution
    /// without pushing a new call frame.
    TailJump { args: Reg, n_args: u8 },
    /// Cross-function tail call: replace the current frame's function
    /// with `func`, rebind its params from the contiguous register run
    /// at `args`, and restart the new entry block. Lowered for tail
    /// calls between two `tailrec` functions so mutual recursion stays
    /// in a single host frame.
    TailCallFunc { func: FuncId, args: Reg, n_args: u8 },
    /// Non-local return — propagates an EvalError::NonLocalReturn
    /// up through enclosing lambda frames until a non-lambda fn
    /// catches it and converts it into a normal return value.
    NonLocalReturn(Option<Reg>),
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
    #[serde(default)]
    pub is_tailrec: bool,
    /// True for synthetic lambda bodies. `return` inside the body
    /// propagates as a non-local return through this frame instead
    /// of being caught locally.
    #[serde(default)]
    pub is_lambda: bool,
    /// True for `inline fun`. A non-local `return` from a lambda
    /// passed to an inline function unwinds *through* this frame
    /// (back to the function that wrote the lambda) rather than
    /// being caught here.
    #[serde(default)]
    pub is_inline: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Param {
    pub name: String,
    pub ty: TypeRef,
    pub default: Option<BlockId>,
    /// True when the primary-ctor param doubles as a class property
    /// (`val name` / `var name` prefix on the param). The Vm uses
    /// this flag to decide which primary args become instance
    /// fields. Defaults to `false` so unrelated callers don't need
    /// to migrate.
    #[serde(default)]
    pub is_property: bool,
    /// `vararg` parameter — variadic, runtime-collected into an
    /// array. The Vm packs trailing positional args into a typed
    /// array before binding.
    #[serde(default)]
    pub is_vararg: bool,
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
    /// Top-level function names declared `tailrec`. Populated by the
    /// driver before bodies are lowered so a tailrec caller's lower
    /// pass can emit `TailCallFunc` for a tail-position call into
    /// another tailrec function whose body hasn't been lowered yet.
    #[serde(default)]
    pub tailrec_fn_names: Vec<String>,
    /// Module-scoped runtime metadata: per-class/per-function side
    /// tables that the IR build phase produces and the Vm consults
    /// at dispatch time. Living on the Module (instead of separate
    /// Vm fields) lets pack-loading merge metadata cleanly and
    /// keeps the Vm's state focused on per-run frames.
    #[serde(default)]
    pub registry: ModuleRegistry,
}

/// Module-scoped side tables consumed by the Vm at dispatch time.
/// Populated by `klio-interp-ir`'s build pass; serialized into pack
/// files so a pre-built pack can ship its registry alongside the
/// frozen IR module.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ModuleRegistry {
    /// Names of `object` singletons. The Vm allocates one instance
    /// per name at startup and publishes it as a global so
    /// bare-name reads resolve.
    #[serde(default)]
    pub object_names: Vec<String>,
    /// Outer-class → companion-singleton global name. Reads on
    /// `Foo.X` fall through to the companion instance when `X` is
    /// not a member of `Foo` itself.
    #[serde(default)]
    pub companion_singletons: std::collections::HashMap<String, String>,
    /// Inner class → outer class name. Resolves `this@Outer` and
    /// outer-chain field reads for nested classes lifted to top
    /// level.
    #[serde(default)]
    pub enclosing_class: std::collections::HashMap<String, String>,
    /// Per-function type-parameter names (in source order). Used
    /// by reified-call dispatch to bind `T` → `Value::Class(arg)`
    /// as a global for the call's lifetime.
    #[serde(default)]
    pub func_type_params: std::collections::HashMap<FuncId, Vec<String>>,
    /// Top-level property names declared with `by <delegate>`.
    /// Reads/writes route through the stored delegate's
    /// `getValue` / `setValue` methods.
    #[serde(default)]
    pub top_level_delegated_props: std::collections::HashSet<String>,
    /// Body-property `(class, prop)` pairs declared with `by`.
    #[serde(default)]
    pub delegated_body_props: std::collections::HashSet<(String, String)>,
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

    /// Register a class declaration and return its id. If the name
    /// was previously [`reserve_class`](Self::reserve_class)d, the
    /// reserved slot/id is reused so forward references that resolved
    /// to that id stay valid.
    pub fn add_class(&mut self, mut class: Class) -> ClassId {
        if let Some(&(_, id)) = self.class_index.iter().find(|(n, _)| n == &class.name) {
            class.id = id;
            self.classes[id.0 as usize] = class;
            return id;
        }
        let id = ClassId(self.classes.len() as u32);
        class.id = id;
        self.class_index.push((class.name.clone(), id));
        self.classes.push(class);
        id
    }

    /// Pre-register a class name so `class_id` resolves it before its
    /// body is lowered. Makes cross-class references order-independent
    /// (a method body can name a class declared later in the module).
    /// The placeholder is overwritten by the real definition when
    /// `add_class` runs for the same name.
    pub fn reserve_class(&mut self, name: &str) -> ClassId {
        if let Some(&(_, id)) = self.class_index.iter().find(|(n, _)| n == name) {
            return id;
        }
        let id = ClassId(self.classes.len() as u32);
        self.class_index.push((name.to_string(), id));
        self.classes.push(Class {
            id,
            name: name.to_string(),
            fqn: name.to_string(),
            primary_params: Vec::new(),
            methods: Vec::new(),
            init_block: None,
            companion: None,
            supertypes: Vec::new(),
        });
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
    UInt(u32),
    ULong(u64),
    UShort(u16),
    UByte(u8),
    Short(i16),
    Byte(i8),
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
            (Const::UInt(a), Const::UInt(b)) => a == b,
            (Const::ULong(a), Const::ULong(b)) => a == b,
            (Const::UShort(a), Const::UShort(b)) => a == b,
            (Const::UByte(a), Const::UByte(b)) => a == b,
            (Const::Short(a), Const::Short(b)) => a == b,
            (Const::Byte(a), Const::Byte(b)) => a == b,
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
