//! Control-flow graph IR for analyses on Kotlin functions.
//!
//! This crate hosts the IR (`ir`), low-level construction primitives
//! (`builder`), and a snapshot-printable form (`print`). AST → CFG
//! lowering (Phase 2) and the dataflow framework (Phase 3) build on
//! top of this without touching the types here.

pub mod builder;
pub mod ir;
pub mod print;

pub use builder::CfgBuilder;
pub use ir::{
    BasicBlock, BlockId, Cfg, Edge, EdgeKind, ExprRef, FieldId, LabelId, LoopId, Node, Pattern,
    Place, Reg, SwitchArm, Symbol, Terminator,
};
pub use print::print_cfg;
