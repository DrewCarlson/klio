//! CFG IR shared across analyses. The shapes here follow Kotlin
//! spec §12.1.1: every interesting program point is either an `Eval`
//! of a sub-expression into a virtual register, an `Assume` that
//! refines a register on a particular control-flow edge, or an
//! assignment to a `Place`. Blocks end in a `Terminator` that names
//! the successor blocks. Edges between blocks carry an `EdgeKind`
//! so analyses can distinguish exception edges, finally entry/exit,
//! and normal control flow.

use klio_span::Span;
use klio_types::Type;

/// Stable index for a basic block within a single CFG.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct BlockId(pub u32);

/// Virtual register holding the result of an `Eval` node. SSA-free;
/// registers are produced once and consumed at any later point in
/// the same CFG.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Reg(pub u32);

/// Stable identifier for a labeled loop. Used by `Backedge` nodes
/// and by `break@l` / `continue@l` lowerings.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct LoopId(pub u32);

/// Stable identifier for a user-visible label (`outer@`, `lambda@foo`).
/// Distinct from `LoopId` so labeled non-loop blocks can be addressed
/// without inventing fake loops.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct LabelId(pub u32);

/// Identifier for a named local, parameter, property, or
/// `this`-bound receiver. The same symbol space as the resolver.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Symbol(pub String);

/// Identifier for a structural field projection used by smart-cast
/// dot paths (`p.x.y`). Carries the unresolved name; the smart-cast
/// analysis matches by name within an enclosing `val`-stable chain.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct FieldId(pub String);

/// Assignable / narrowable location. Smart casts attach to `Place`,
/// not `Reg` — registers are short-lived expression slots while
/// places persist across the CFG.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Place {
    /// Named local or parameter.
    Local(Symbol),
    /// Dotted access onto another place: `receiver.field`.
    Field {
        receiver: Box<Place>,
        field: FieldId,
    },
    /// `this` of the enclosing class/lambda receiver.
    This,
}

/// Per-node `Eval` payload. Holds the AST span so analyses can map
/// results back to source for diagnostics; the expression kind is
/// preserved through `ExprRef` so transfer functions can reason
/// about the producing form (constants, calls, member access).
#[derive(Debug, Clone)]
pub struct ExprRef {
    pub span: Span,
    /// Static type assigned by the typechecker. Carried so reachability
    /// can spot `Nothing`-typed evaluations without re-running typeck.
    pub ty: Type,
}

/// A single CFG node within a block. Order inside a block matters:
/// nodes execute top-to-bottom. Control transfer happens only at
/// the block's `Terminator`.
#[derive(Debug, Clone)]
pub enum Node {
    /// Compute an expression into a fresh register.
    Eval { reg: Reg, expr: ExprRef },
    /// Write a register into a place.
    Assign { lhs: Place, rhs: Reg, span: Span },
    /// Declare a fresh local; VIA seeds this place as `Unassigned`.
    DeclLocal {
        place: Symbol,
        declared_ty: Type,
        span: Span,
    },
    /// Assume `reg` is true (false). Emitted on `Branch::True` /
    /// `Branch::False` arms after lowering `if`/`when`/`&&`/`||`.
    Assume { reg: Reg, polarity: bool },
    /// Assume the runtime type of `reg` is (is not) `ty`. Emitted on
    /// the arms of `is` / `!is` checks; smart-cast lattice consumes
    /// both polarities. `class_name` carries the source type-ref's
    /// simple name so the typechecker can recover a user-class
    /// narrowing — `ty` itself is `Type::Unresolved` for any name
    /// not in `builtin_by_name`.
    AssumeIs {
        reg: Reg,
        ty: Type,
        class_name: Option<String>,
        polarity: bool,
        span: Span,
    },
    /// Assume `reg == null` (or `reg != null`). Distinct from
    /// `AssumeIs Nothing?` because nullability is its own axis on
    /// the smart-cast lattice.
    AssumeNull { reg: Reg, eq_null: bool, span: Span },
    /// Assume that two registers refer to the same runtime value.
    /// Produced by `a === b` (and the structural-equality form when
    /// at least one side is non-nullable) and consumed by smart-
    /// cast: both registers' places narrow to the intersection of
    /// their facts on the truthy branch.
    AssumeRefEq {
        reg_a: Reg,
        reg_b: Reg,
        polarity: bool,
        span: Span,
    },
    /// Assert `reg` is true; if it is not, control diverges (the
    /// containing block ends in `Terminator::Unreachable` along the
    /// false edge). Used for `!!`, `as`, and contract `require`.
    Assert { reg: Reg, span: Span },
    /// Invalidate every smart-cast bound on `place` because a loop
    /// back-edge may have reassigned it. Inserted by the `killDataFlow`
    /// pass after the dataflow framework reaches fixpoint.
    KillDataFlow { place: Place },
    /// Loop back-jump marker. Holds the loop's id so the dataflow
    /// solver can identify backedges without re-deriving the loop
    /// nest from the CFG.
    Backedge { loop_id: LoopId },
    /// Source-visible label position; consumed by `break@l` and
    /// `continue@l` lowering and by diagnostics that want to point
    /// at the labeled site.
    LabelMark { label: LabelId },
    /// Marker the lowering inserts whenever it knows a point is
    /// statically dead (e.g. after `Nothing`-returning calls). The
    /// reachability analysis treats this as an authoritative bottom.
    Unreachable,
}

/// How control leaves a block. Every block has exactly one.
#[derive(Debug, Clone)]
pub enum Terminator {
    /// Fall through to one successor.
    Goto(BlockId),
    /// Two-way branch on a boolean register.
    Branch {
        cond: Reg,
        then_blk: BlockId,
        else_blk: BlockId,
    },
    /// N-way switch driven by a register and a list of patterns.
    /// Used for `when (subject)` lowerings; arms are exclusive,
    /// `default` is taken if none match.
    Switch {
        reg: Reg,
        arms: Vec<SwitchArm>,
        default: BlockId,
    },
    /// Throw a value; control transfers to the nearest matching
    /// catch handler (resolved by exception edges on this block).
    Throw(Reg),
    /// Return from the enclosing function. `None` for `Unit`.
    Return(Option<Reg>),
    /// Block is statically unreachable past this point. Equivalent
    /// to a divergent terminator; the reachability analysis prunes
    /// successors.
    Unreachable,
}

/// One arm of a `Switch` terminator.
#[derive(Debug, Clone)]
pub struct SwitchArm {
    pub pattern: Pattern,
    pub target: BlockId,
}

/// Pattern shapes the lowering produces for `when` arms. Conditions
/// inside an arm (`is T`, `in r`, equality) are emitted as `AssumeIs`
/// / `AssumeNull` / `Assume` nodes in the arm's body, not in the
/// pattern itself; this keeps the switch table cheap to walk.
#[derive(Debug, Clone)]
pub enum Pattern {
    /// Match by structural equality with a register.
    Equal(Reg),
    /// Match by `is`-check against a type.
    Is { ty: Type, polarity: bool },
    /// Always-match arm (used for the desugared `else`).
    Wildcard,
}

/// Kind of edge between two blocks. Analyses route differently
/// depending on the kind — exception edges skip normal joins, and
/// finally edges feed both the normal-exit and exception-path
/// summaries.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum EdgeKind {
    Normal,
    /// Edge from a `Branch` terminator's true arm.
    True,
    /// Edge from a `Branch` terminator's false arm.
    False,
    /// Edge that may be taken when the source block throws a value
    /// whose runtime type is a subtype of `ty`. Lowered for every
    /// statement inside a `try` whose handler matches.
    Exception {
        ty: Option<Type>,
    },
    /// Edge into the `finally` block from the normal exit of a `try`
    /// body or its handler.
    FinallyEntry,
    /// Edge out of the `finally` block back to the original
    /// continuation (normal exit or rethrow).
    FinallyExit,
}

/// One block in a CFG. `preds` / `succs` carry the kind of each
/// edge so analyses can pick the appropriate transfer function.
#[derive(Debug, Clone)]
pub struct BasicBlock {
    pub id: BlockId,
    pub nodes: Vec<Node>,
    pub term: Terminator,
    pub preds: Vec<Edge>,
    pub succs: Vec<Edge>,
}

/// Reference to a neighbouring block plus the kind of edge.
#[derive(Debug, Clone)]
pub struct Edge {
    pub block: BlockId,
    pub kind: EdgeKind,
}

/// The CFG of one function / property accessor / init block.
///
/// `entry` is always present; `exits` lists every block whose
/// terminator is `Return` or whose continuation falls off the end
/// of the body (for `Unit`-typed bodies).
#[derive(Debug, Clone)]
pub struct Cfg {
    pub blocks: Vec<BasicBlock>,
    pub entry: BlockId,
    pub exits: Vec<BlockId>,
    /// Source span of the function/accessor/init this CFG covers.
    pub source: Span,
    /// Next register id to allocate during further IR manipulation.
    pub next_reg: u32,
}

impl Cfg {
    #[must_use]
    pub fn block(&self, id: BlockId) -> &BasicBlock {
        &self.blocks[id.0 as usize]
    }

    pub fn block_mut(&mut self, id: BlockId) -> &mut BasicBlock {
        &mut self.blocks[id.0 as usize]
    }
}
