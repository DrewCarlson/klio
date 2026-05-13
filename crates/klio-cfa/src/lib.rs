//! Control-flow graph IR for analyses on Kotlin functions.
//!
//! This crate hosts the IR (`ir`), low-level construction primitives
//! (`builder`), and a snapshot-printable form (`print`). The AST →
//! CFG lowering (`lower`) and the dataflow framework (`dataflow`)
//! build on top of this without touching the types here.

pub mod analyses;
pub mod builder;
pub mod dataflow;
pub mod ir;
pub mod lower;
pub mod print;

pub use builder::CfgBuilder;
pub use ir::{
    BasicBlock, BlockId, Cfg, Edge, EdgeKind, ExprRef, FieldId, LabelId, LoopId, Node, Pattern,
    Place, Reg, SwitchArm, Symbol, Terminator,
};
pub use print::print_cfg;
